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
}
