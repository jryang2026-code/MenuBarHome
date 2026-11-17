import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #59: the engine maps an observed Mac-state trigger to the stored rule, runs it through
/// `HomeStore`, and never performs network work itself.
@MainActor
struct AutomationEngineTests {
    static let studyLight = SmartDevice(
        id: "light_study",
        name: "书房台灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )
    static let scenes = [
        HomeScene(id: "scene_home", name: "回家模式", entityId: "scene.home"),
        HomeScene(id: "scene_work", name: "办公模式", entityId: "scene.work")
    ]

    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: [Self.studyLight],
            scenes: Self.scenes
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.automation.engine.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.automation.engine.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @Test("Away rule turns the light off once per minute and leaves an undo banner")
    func awayRuleExecutesAndDedupes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .away,
                action: .devices(ids: [Self.studyLight.id], isOn: false)
            )
        ])

        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)

        let start = Date()
        await engine.handle(trigger: .away, at: start)

        #expect(store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false)
        #expect(store.undoBanner != nil)
        #expect(store.userHabitMemory.entries.isEmpty)
        let firstCommands = await mock.executedCommands
        #expect(firstCommands == [.setLightPower(entityId: "light.study", isOn: false)])

        // A second lock/wake flap within the cooldown must not dispatch again.
        await engine.handle(trigger: .away, at: start.addingTimeInterval(30))
        let afterSecond = await mock.executedCommands
        #expect(afterSecond.count == firstCommands.count)
    }

    @Test("Rules added while the cooldown clock is idle still fire immediately")
    func emptyRuleListDoesNotBurnCooldown() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)
        let start = Date()

        await engine.handle(trigger: .away, at: start)
        #expect(await mock.executedCommands.isEmpty)

        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .away,
                action: .devices(ids: [Self.studyLight.id], isOn: false)
            )
        ])
        await engine.handle(trigger: .away, at: start.addingTimeInterval(5))
        #expect(store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false)
    }

    @Test("A panel created after automation can offer undo without observing the execution")
    func undoAvailableAfterAutomation() async throws {
        let (store, mock) = try await makeStore()
        await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.studyLight.id, operation: .power(false))],
            title: "关闭书房台灯"
        )

        let tracker = UndoAvailabilityTracker()
        tracker.syncAction(at: store.lastAssistantActionAt)
        #expect(tracker.isAvailable)
        #expect(store.devices.first?.isActiveOn == false)
        await tracker.performUndo(store: store)
        #expect(store.devices.first?.isActiveOn == true)
        #expect(!tracker.isAvailable)
        #expect(store.lastAssistantActionAt == nil)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.study", isOn: true)
        ])
        #expect(store.userHabitMemory.entries.isEmpty)
    }

    @Test("Reopening the panel preserves the original ten-minute undo deadline", arguments: [360.0, 601.0])
    func undoKeepsOriginalDeadline(elapsed: TimeInterval) {
        let date = Date().addingTimeInterval(-elapsed)
        let tracker = UndoAvailabilityTracker()
        tracker.syncAction(at: date)
        #expect(tracker.isAvailable == (elapsed < 600))
        #expect(tracker.lastActionAt == (elapsed < 600 ? date : nil))
        tracker.syncAction(at: nil)
        #expect(!tracker.isAvailable)
    }

    @Test("Connecting an external display can run the configured scene")
    func displayConnectRunsScene() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .externalDisplayConnected,
                action: .scene(sceneId: "scene_work")
            )
        ])

        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)

        await engine.handle(trigger: .externalDisplayConnected, at: Date())
        let commands = await mock.executedCommands
        #expect(commands == [.activateScene(entityId: "scene.work")])
        #expect(store.userHabitMemory.entries.isEmpty)
    }

    @Test("A quick-action rule uses the built-in action path and leaves an undo banner")
    func quickActionRule() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(trigger: .away, action: .quickAction(.lightsOff))
        ])

        let (store, _) = try await makeStore()
        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)

        await engine.handle(trigger: .away, at: Date())
        #expect(store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false)
        #expect(store.undoBanner != nil)
        #expect(store.userHabitMemory.entries.isEmpty)
    }

    @Test("AutomationEngine surfaces partial and repeated failures via typed execution outcomes")
    func engineSurfacesPartialAndRepeatedFailures() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let secondLight = SmartDevice(
            id: "light_corridor",
            name: "走廊灯",
            roomId: "corridor",
            roomName: "走廊",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.corridor", isOn: true))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.studyLight, secondLight]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.automation.engine.fail.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .away,
                action: .devices(ids: [Self.studyLight.id, secondLight.id], isOn: false)
            )
        ])

        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)
        let start = Date()

        await mock.setFailingCommands { $0 == .setLightPower(entityId: "light.corridor", isOn: false) }
        await engine.handle(trigger: .away, at: start)
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("1") == true)
        #expect(store.toastNotice?.message.contains("走廊灯") == true)

        await mock.setFailingCommands { _ in true }
        await engine.handle(trigger: .away, at: start.addingTimeInterval(65))
        #expect(store.toastNotice?.isError == true)
    }

    @Test("Legacy unapproved high-risk automation rules are blocked and disabled until re-confirmed")
    func legacyUnapprovedHighRiskRuleBlocked() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let heaterPlug = SmartDevice(
            id: "plug_heater",
            name: "卧室取暖器插座",
            roomId: "bedroom",
            roomName: "卧室",
            model: "chuangmi.plug.212a01",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: false))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [heaterPlug]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.automation.engine.highrisk.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        let ruleStore = AutomationRuleStore(defaults: defaults)
        let unapprovedRule = AutomationRule(
            trigger: .back,
            action: .devices(ids: [heaterPlug.id], isOn: true),
            highRiskApproved: false
        )
        ruleStore.save([unapprovedRule])

        let engine = AutomationEngine(defaults: defaults)
        engine.attach(store: store)
        let start = Date()

        await engine.handle(trigger: .back, at: start)
        #expect(await mock.executedCommands.isEmpty)
        #expect(ruleStore.load().first?.isEnabled == false)
        #expect(store.toastNotice?.isError == true)

        var approvedRule = unapprovedRule
        approvedRule.isEnabled = true
        approvedRule.highRiskApproved = true
        ruleStore.save([approvedRule])

        await engine.handle(trigger: .back, at: start.addingTimeInterval(65))
        #expect(await mock.executedCommands == [.setSwitch(entityId: "switch.heater", isOn: true)])
    }

    @Test("Device cards guard inverted Kelvin ranges, offline drawers, and room-prefixed Classic room pills")
    func deviceCardSafetyAndRoomBadgeGuards() async throws {
        let invertedLight = SmartDevice(
            id: "light_inverted",
            name: "书房台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.inverted",
                isOn: true,
                brightnessPercent: 50,
                colorTempKelvin: 4000,
                minKelvin: 6500,
                maxKelvin: 2700,
                colorWritable: true
            ))
        )
        let offlineFridge = SmartDevice(
            id: "fridge_1",
            name: "厨房冰箱",
            roomId: "kitchen",
            roomName: "厨房",
            model: "midjd6.fridge.v1",
            isOnline: false,
            kind: .fridge(FridgeSpec(
                modeEntityId: nil,
                currentMode: "auto",
                availableModes: [],
                fridgeCurrentTemp: 4,
                fridgeTargetTemp: 4,
                fridgeTargetEntityId: nil,
                freezerCurrentTemp: -18,
                freezerTargetTemp: -18,
                freezerTargetEntityId: nil
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [invertedLight, offlineFridge]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.cards.guards.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.expandedDeviceId = invertedLight.id

        #expect(DeviceRoomBadge.label(roomName: "书房", title: "书房台灯", showRoomBadge: true) == nil)
        #expect(DeviceRoomBadge.label(roomName: "书房", title: "台灯", showRoomBadge: true) == "书房")

        let modernLightCard = DeviceCardView(device: invertedLight, store: store, showRoomBadge: true)
        let classicLightCard = ClassicDeviceCardView(device: invertedLight, store: store, showRoomBadge: true)
        let modernFridgeCard = DeviceCardView(device: offlineFridge, store: store, showRoomBadge: true)
        let classicFridgeCard = ClassicDeviceCardView(device: offlineFridge, store: store, showRoomBadge: true)
        _ = modernLightCard.body
        _ = classicLightCard.body
        _ = modernFridgeCard.body
        _ = classicFridgeCard.body
    }

    @Test("A saved window blocks a notification outside it and leaves the cooldown unused")
    func timeWindowBlocksTriggerWithoutConsumingCooldown() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Self.utcCalendar()
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .back,
                action: .devices(ids: [Self.studyLight.id], isOn: false),
                conditions: Self.nightWindow()
            )
        ])
        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(defaults: defaults, calendar: calendar)
        engine.attach(store: store)

        let noon = try Self.date(calendar, year: 2026, hour: 12, minute: 0)
        await engine.handle(trigger: .back, at: noon)
        #expect(await mock.executedCommands.isEmpty)
        #expect(Self.cooldownStamps(defaults).isEmpty)
        #expect(store.devices.first?.isActiveOn == true)

        let outside = try Self.date(calendar, year: 2026, hour: 21, minute: 59, second: 30)
        let inside = try Self.date(calendar, year: 2026, hour: 22, minute: 0, second: 20)
        await engine.handle(trigger: .back, at: outside)
        #expect(await mock.executedCommands.isEmpty)
        #expect(Self.cooldownStamps(defaults).isEmpty)

        await engine.handle(trigger: .back, at: inside)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study", isOn: false)])
        #expect(Self.cooldownStamps(defaults).count == 1)
    }

    @Test("A lone screen lock at 21:59:59 stays outside a 22:00 window after the debounce flush")
    func screenLockAt215959DoesNotEnterTheWindowOrTheCooldown() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Self.utcCalendar()
        // Next year keeps the engine's debounce sleep in the future. A past deadline would
        // flush immediately at the wall clock and race this assertion.
        let year = calendar.component(.year, from: Date()) + 1
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .screenLocked,
                action: .devices(ids: [Self.studyLight.id], isOn: false),
                conditions: Self.nightWindow()
            )
        ])
        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(
            defaults: defaults,
            calendar: calendar,
            environment: Self.quietEnvironment()
        )
        engine.attach(store: store)

        let lock = try Self.date(calendar, year: year, hour: 21, minute: 59, second: 59)
        await engine.ingestAway(.screenLocked, at: lock)
        await engine.flushArbitration(at: lock.addingTimeInterval(AwayArbitrator.lockDebounce))
        #expect(await mock.executedCommands.isEmpty)
        #expect(Self.cooldownStamps(defaults).isEmpty)
        #expect(store.devices.first?.isActiveOn == true)

        let later = try Self.date(calendar, year: year, hour: 22, minute: 0, second: 30)
        await engine.ingestAway(.screenLocked, at: later)
        await engine.flushArbitration(at: later.addingTimeInterval(AwayArbitrator.lockDebounce))
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study", isOn: false)])
        #expect(Self.cooldownStamps(defaults).count == 1)
    }

    @Test("Sleep is judged at the event instant, so 21:59:59 stays outside a 22:00 window")
    func sleepAt215959StaysOutsideTheWindow() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Self.utcCalendar()
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(
                trigger: .systemSleep,
                action: .devices(ids: [Self.studyLight.id], isOn: false),
                conditions: Self.nightWindow()
            )
        ])
        let (store, mock) = try await makeStore()
        let engine = AutomationEngine(
            defaults: defaults,
            calendar: calendar,
            environment: Self.quietEnvironment()
        )
        engine.attach(store: store)

        let outside = try Self.date(calendar, year: 2026, hour: 21, minute: 59, second: 59)
        await engine.ingestAway(.willSleep, at: outside)
        #expect(await mock.executedCommands.isEmpty)
        #expect(Self.cooldownStamps(defaults).isEmpty)

        let inside = try Self.date(calendar, year: 2026, hour: 22, minute: 0)
        await engine.ingestAway(.willSleep, at: inside)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study", isOn: false)])
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func nightWindow() -> AutomationConditions {
        AutomationConditions(
            timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        )
    }

    private static func cooldownStamps(_ defaults: UserDefaults) -> [String: Any] {
        defaults.dictionary(forKey: AutomationTriggerDeduper.storageKey) ?? [:]
    }

    private static func quietEnvironment() -> AutomationEnvironmentProbe {
        AutomationEnvironmentProbe(
            isLidClosed: { false },
            currentWiFi: { (ssid: nil, isAuthorized: true) }
        )
    }

    private static func date(
        _ calendar: Calendar,
        year: Int,
        hour: Int,
        minute: Int,
        second: Int = 0
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: year, month: 11, day: 12, hour: hour, minute: minute, second: second
        )))
    }
}
