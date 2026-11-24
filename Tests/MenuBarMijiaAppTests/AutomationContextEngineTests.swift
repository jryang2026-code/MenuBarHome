import Foundation
import PreferencesTestSupport
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #174: the engine consumes snapshots from an injected observer, evaluates every enabled rule and
/// reuses the normal dispatch/undo path. Each Mac-only signal has a behavior test, plus the
/// disabled-by-default contract.
@MainActor
final class FakeMacContextProvider: MacContextProviding {
    private var handler: (@MainActor (MacContextSnapshot, Date) async -> Void)?
    private(set) var isStarted = false

    func start(_ handler: @escaping @MainActor (MacContextSnapshot, Date) async -> Void) {
        self.handler = handler
        isStarted = true
    }

    func stop() {
        handler = nil
        isStarted = false
    }

    func emit(_ snapshot: MacContextSnapshot, at now: Date = Date()) async {
        await handler?(snapshot, now)
    }
}

@MainActor
struct AutomationContextEngineTests {
    static let lightId = "light_study"
    static let workScene = HomeScene(id: "scene_work", name: "办公模式", entityId: "scene.work")

    static func studyLight(isOn: Bool = true) -> SmartDevice {
        SmartDevice(
            id: lightId,
            name: "书房台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: isOn))
        )
    }

    private func makeStore(
        lightOn: Bool = true,
        scenes: [HomeScene] = []
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: [Self.studyLight(isOn: lightOn)],
            scenes: scenes
        ))
        let store = HomeStore(
            provider: mock,
            defaults: InMemoryUserDefaults()
        )
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    static let unlockedEnvironment = AutomationEnvironmentProbe(
        isLidClosed: { false },
        currentWiFi: { (ssid: nil, isAuthorized: true) },
        isScreenLocked: { false }
    )

    static let lockedEnvironment = AutomationEnvironmentProbe(
        isLidClosed: { false },
        currentWiFi: { (ssid: nil, isAuthorized: true) },
        isScreenLocked: { true }
    )

    private func makeEngine(
        rules: [AutomationRule],
        defaults: UserDefaults,
        lightOn: Bool = true,
        scenes: [HomeScene] = [],
        calendar: Calendar = .current,
        environment: AutomationEnvironmentProbe = Self.unlockedEnvironment,
        elapsedTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> (AutomationEngine, HomeStore, MockHomeProvider, FakeMacContextProvider) {
        let (store, mock) = try await makeStore(lightOn: lightOn, scenes: scenes)
        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save(rules)
        try #require(ruleStore.load() == rules)

        let provider = FakeMacContextProvider()
        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            calendar: calendar,
            environment: environment,
            elapsedTime: elapsedTime
        )
        engine.attach(store: store)
        engine.startContextObservation()
        #expect(provider.isStarted)
        return (engine, store, mock, provider)
    }

    private func offCommand() -> DeviceCommand {
        .setLightPower(entityId: "light.study", isOn: false)
    }

    private func onCommand() -> DeviceCommand {
        .setLightPower(entityId: "light.study", isOn: true)
    }

    @Test("A sleep-missed schedule is skipped, and a repeated DST minute fires only once")
    func scheduledSleepAndRepeatedMinute() async throws {
        let defaults = InMemoryUserDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let rule = AutomationRule(
            trigger: .scheduledTime,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 1, minute: 30))
        )
        let (engine, store, mock, provider) = try await makeEngine(rules: [rule], defaults: defaults, calendar: calendar)
        defer { store.stop() }
        let formatter = ISO8601DateFormatter()
        let missed = try #require(formatter.date(from: "2026-10-31T08:30:00Z"))
        engine.setSystemSleeping(true)
        await provider.emit(MacContextSnapshot(), at: missed)
        engine.setSystemSleeping(false)
        await provider.emit(MacContextSnapshot(), at: missed.addingTimeInterval(120))
        #expect(await mock.executedCommands.isEmpty)

        let first = try #require(formatter.date(from: "2026-11-01T08:30:00Z"))
        let second = first.addingTimeInterval(3600)
        await provider.emit(MacContextSnapshot(), at: first.addingTimeInterval(5))
        await provider.emit(MacContextSnapshot(), at: second)
        await provider.emit(MacContextSnapshot(), at: first)
        #expect(await mock.executedCommands == [offCommand()])
        let runs = store.automationRunHistory.filter { $0.ruleId == rule.id }
        #expect(runs.map(\.reason) == [.cooldown, .cooldown, nil])

        let (relaunched, secondStore, secondMock, secondProvider) = try await makeEngine(
            rules: [rule], defaults: defaults, calendar: calendar
        )
        defer { withExtendedLifetime(relaunched) { secondStore.stop() } }
        await secondProvider.emit(MacContextSnapshot(), at: second)
        #expect(await secondMock.executedCommands.isEmpty)
        #expect(secondStore.automationRunHistory.first?.reason == .cooldown)
    }

    @Test("Wake in the scheduled minute runs once and locked schedules log a skip")
    func scheduledWakeInMinuteAndLockGate() async throws {
        let rule = AutomationRule(
            trigger: .scheduledTime,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 0, minute: 0))
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let instant = Date(timeIntervalSince1970: 0)
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule], defaults: InMemoryUserDefaults(), calendar: calendar
        )
        defer { store.stop() }
        engine.setSystemSleeping(true)
        await provider.emit(MacContextSnapshot(), at: instant)
        engine.setSystemSleeping(false)
        await provider.emit(MacContextSnapshot(), at: instant.addingTimeInterval(10))
        await provider.emit(MacContextSnapshot(), at: instant.addingTimeInterval(20))
        #expect(await mock.executedCommands == [offCommand()])

        let (lockedEngine, lockedStore, lockedMock, lockedProvider) = try await makeEngine(
            rules: [rule], defaults: InMemoryUserDefaults(), calendar: calendar, environment: Self.lockedEnvironment
        )
        defer { withExtendedLifetime(lockedEngine) { lockedStore.stop() } }
        await lockedProvider.emit(MacContextSnapshot(), at: instant)
        #expect(await lockedMock.executedCommands.isEmpty)
        #expect(lockedStore.automationRunHistory.first?.reason == .screenLocked)
    }

    @Test("Five-minute state resets on interruption, fires exactly on the boundary and fires only once")
    func lastingResetsAndFiresOnce() async throws {
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false),
            conditions: AutomationConditions(lastingMinutes: 5)
        )
        var elapsed: TimeInterval = 0
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule], defaults: InMemoryUserDefaults(), elapsedTime: { elapsed }
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func emit(_ seconds: Int, active: Bool = true, available: Bool = true) async {
            elapsed = TimeInterval(seconds)
            let snapshot = MacContextSnapshot(cameraInUse: active, isCameraUsageAvailable: available)
            await provider.emit(snapshot, at: now.addingTimeInterval(elapsed))
        }
        for second in stride(from: 0, to: 240, by: 10) { await emit(second) }
        await emit(240, active: false)
        #expect(store.automationRunHistory.first?.reason == .conditionFalse)
        for second in stride(from: 250, to: 550, by: 10) { await emit(second) }
        await emit(549, available: false)
        #expect(store.automationRunHistory.first?.reason == .conditionFalse)
        for second in stride(from: 550, to: 850, by: 10) { await emit(second) }
        await emit(849)
        #expect(await mock.executedCommands.isEmpty)
        await emit(850)
        await emit(860)
        #expect(await mock.executedCommands == [offCommand()])
        #expect(store.automationRunHistory.filter { $0.ruleId == rule.id && $0.reason == nil }.count == 1)
    }

    @Test("A gap or sleep clears the observation interval, while a night can span midnight")
    func lastingNightAcrossMidnightAndGap() async throws {
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .devices(ids: [Self.lightId], isOn: false),
            conditions: AutomationConditions(lastingMinutes: 5)
        )
        var elapsed: TimeInterval = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule], defaults: InMemoryUserDefaults(), calendar: calendar, elapsedTime: { elapsed }
        )
        defer { store.stop() }
        let midnight = Date(timeIntervalSince1970: 86_400)
        func emit(_ seconds: Int) async {
            elapsed = TimeInterval(seconds)
            await provider.emit(MacContextSnapshot(), at: midnight.addingTimeInterval(elapsed - 450))
        }
        await emit(0)
        for second in stride(from: 60, through: 300, by: 10) { await emit(second) }
        #expect(await mock.executedCommands.isEmpty)
        engine.setSystemSleeping(true)
        engine.setSystemSleeping(false)
        for second in stride(from: 310, through: 600, by: 10) { await emit(second) }
        #expect(await mock.executedCommands.isEmpty)
        await emit(610)
        #expect(await mock.executedCommands == [offCommand()])
    }

    @Test("No rules means every Mac context signal stays inert")
    func noRulesIsInert() async throws {
        let defaults = InMemoryUserDefaults()
        let (engine, store, mock, provider) = try await makeEngine(rules: [], defaults: defaults)
        defer { withExtendedLifetime(engine) { store.stop() } }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(
            id: "event",
            title: "Meeting",
            startDate: start.addingTimeInterval(60),
            endDate: start.addingTimeInterval(3600)
        )
        await provider.emit(MacContextSnapshot(
            cameraInUse: true,
            microphoneInUse: true,
            powerSource: .ac,
            batteryPercent: 5,
            wifiSSID: "Home",
            isWiFiAuthorized: true,
            isFocusActive: true,
            isUserPresent: true,
            meetings: [meeting]
        ), at: start)

        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.first?.isActiveOn == true)
    }

    @Test("A disabled Mac context rule never runs")
    func disabledRuleNeverRuns() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false),
            isEnabled: false
        )
        let (engine, store, mock, provider) = try await makeEngine(rules: [rule], defaults: defaults)
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(), at: start)
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Camera and microphone rules fire on use / stop and coalesce flaps")
    func cameraAndMicrophoneRules() async throws {
        let defaults = InMemoryUserDefaults()
        let cameraOn = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let cameraOff = AutomationRule(
            trigger: .cameraNotInUse,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let micOn = AutomationRule(
            trigger: .microphoneInUse,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [cameraOn, cameraOff, micOn],
            defaults: defaults
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(), at: start)
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands == [offCommand()])
        #expect(store.devices.first?.isActiveOn == false)

        // Camera off, then back on within the one-minute cooldown: no extra dispatch.
        await provider.emit(MacContextSnapshot(), at: start.addingTimeInterval(20))
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(30))
        #expect(await mock.executedCommands.count == 2)

        await provider.emit(
            MacContextSnapshot(microphoneInUse: true),
            at: start.addingTimeInterval(40)
        )
        #expect(await mock.executedCommands == [offCommand(), onCommand(), offCommand()])
    }

    @Test("Power, disconnect and battery-threshold rules each run")
    func powerAndBatteryRules() async throws {
        let defaults = InMemoryUserDefaults()
        let powerConnected = AutomationRule(
            trigger: .powerConnected,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let powerDisconnected = AutomationRule(
            trigger: .powerDisconnected,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let lowBattery = AutomationRule(
            trigger: .batteryBelowThreshold,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(batteryThresholdPercent: 20)
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [powerConnected, powerDisconnected, lowBattery],
            defaults: defaults
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryHigh = MacContextSnapshot(powerSource: .battery, batteryPercent: 80)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)
        let batteryLow = MacContextSnapshot(powerSource: .battery, batteryPercent: 10)

        await provider.emit(batteryHigh, at: start)
        await provider.emit(ac, at: start.addingTimeInterval(10))
        await provider.emit(batteryHigh, at: start.addingTimeInterval(20))
        await provider.emit(batteryLow, at: start.addingTimeInterval(30))

        #expect(await mock.executedCommands == [offCommand(), onCommand(), offCommand()])
    }

    @Test("A time window gates Mac context rules and leaves the trigger for an in-window event")
    func timeWindowGatesContextRules() async throws {
        let defaults = InMemoryUserDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let nightOnly = AutomationRule(
            trigger: .powerConnected,
            action: .devices(ids: [Self.lightId], isOn: false),
            conditions: AutomationConditions(
                timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
            )
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [nightOnly],
            defaults: defaults,
            calendar: calendar
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12)))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23)))
        let battery = MacContextSnapshot(powerSource: .battery, batteryPercent: 80)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)

        await provider.emit(battery, at: noon)
        await provider.emit(ac, at: noon.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)

        await provider.emit(battery, at: night)
        await provider.emit(ac, at: night.addingTimeInterval(10))
        #expect(await mock.executedCommands == [offCommand()])
    }

    @Test("A camera rule outside its window runs nothing and does not start the cooldown")
    func timeWindowBlocksContextWithoutConsumingCooldown() async throws {
        let defaults = InMemoryUserDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false),
            conditions: AutomationConditions(
                timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
            )
        )
        let (engine, store, mock, _) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            calendar: calendar
        )
        defer { withExtendedLifetime(engine) { store.stop() } }

        func at(hour: Int, minute: Int, second: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: 11, day: 12, hour: hour, minute: minute, second: second
            )))
        }

        let noon = try at(hour: 12, minute: 0)
        await engine.handle(context: MacContextSnapshot(), at: noon.addingTimeInterval(-10))
        await engine.handle(context: MacContextSnapshot(cameraInUse: true), at: noon)
        #expect(await mock.executedCommands.isEmpty)
        #expect((defaults.dictionary(forKey: AutomationTriggerDeduper.storageKey) ?? [:]).isEmpty)

        let outside = try at(hour: 21, minute: 59, second: 30)
        let inside = try at(hour: 22, minute: 0, second: 20)
        await engine.handle(context: MacContextSnapshot(), at: outside.addingTimeInterval(-5))
        await engine.handle(context: MacContextSnapshot(cameraInUse: true), at: outside)
        #expect(await mock.executedCommands.isEmpty)
        #expect((defaults.dictionary(forKey: AutomationTriggerDeduper.storageKey) ?? [:]).isEmpty)

        await engine.handle(context: MacContextSnapshot(), at: inside.addingTimeInterval(-5))
        await engine.handle(context: MacContextSnapshot(cameraInUse: true), at: inside)
        #expect(await mock.executedCommands == [offCommand()])
        #expect((defaults.dictionary(forKey: AutomationTriggerDeduper.storageKey) ?? [:]).count == 1)
    }

    @Test("Wi-Fi rules target a SSID and ignore unauthorized SSID reads")
    func wifiRules() async throws {
        let defaults = InMemoryUserDefaults()
        let joined = AutomationRule(
            trigger: .wifiNetworkJoined,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(wifiSSID: "Home")
        )
        let left = AutomationRule(
            trigger: .wifiNetworkLeft,
            action: .devices(ids: [Self.lightId], isOn: true),
            triggerOptions: AutomationTriggerOptions(wifiSSID: "Home")
        )
        let (engine, store, mock, provider) = try await makeEngine(rules: [joined, left], defaults: defaults)
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start)
        // Permission denied: a nil SSID must not look like leaving Home.
        await provider.emit(
            MacContextSnapshot(wifiSSID: nil, isWiFiAuthorized: false),
            at: start.addingTimeInterval(5)
        )
        #expect(await mock.executedCommands.isEmpty)

        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start.addingTimeInterval(7))
        await provider.emit(MacContextSnapshot(wifiSSID: "Home"), at: start.addingTimeInterval(10))
        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start.addingTimeInterval(20))
        #expect(await mock.executedCommands == [offCommand(), onCommand()])
    }

    @Test("Focus on/off rules run only when the observer exposes focus state")
    func focusRules() async throws {
        let defaults = InMemoryUserDefaults()
        let enabled = AutomationRule(
            trigger: .focusModeEnabled,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let disabled = AutomationRule(
            trigger: .focusModeDisabled,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [enabled, disabled],
            defaults: defaults,
            lightOn: false
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(isFocusActive: nil), at: start)
        await provider.emit(MacContextSnapshot(isFocusActive: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)

        await provider.emit(MacContextSnapshot(isFocusActive: false), at: start.addingTimeInterval(20))
        await provider.emit(MacContextSnapshot(isFocusActive: true), at: start.addingTimeInterval(30))
        await provider.emit(MacContextSnapshot(isFocusActive: false), at: start.addingTimeInterval(40))
        // Focus-off at +20 (turn on), Focus-on at +30 (turn off), second Focus-off at +40 is
        // coalesced by the one-minute rule cooldown.
        #expect(await mock.executedCommands == [onCommand(), offCommand()])
    }

    @Test("Focus mode-name rules trigger on direct Focus A -> Focus B switches and ignore unknown mode names")
    func focusModeNameRuleEndToEnd() async throws {
        let defaults = InMemoryUserDefaults()
        let sleepEnabled = AutomationRule(
            trigger: .focusModeEnabled,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(focusModeName: "睡眠")
        )
        let sleepDisabled = AutomationRule(
            trigger: .focusModeDisabled,
            action: .devices(ids: [Self.lightId], isOn: true),
            triggerOptions: AutomationTriggerOptions(focusModeName: "睡眠")
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [sleepEnabled, sleepDisabled],
            defaults: defaults,
            lightOn: true
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(isFocusActive: false, focusModeName: nil), at: start)
        // Unknown mode name does not trigger the "睡眠" rule.
        await provider.emit(MacContextSnapshot(isFocusActive: true, focusModeName: "未知模式"), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)

        // Direct switch: unknown Focus -> "睡眠" triggers sleepEnabled (turns light off).
        await provider.emit(MacContextSnapshot(isFocusActive: true, focusModeName: "睡眠"), at: start.addingTimeInterval(20))
        // Direct switch: "睡眠" -> "工作" triggers sleepDisabled (turns light on).
        await provider.emit(MacContextSnapshot(isFocusActive: true, focusModeName: "工作"), at: start.addingTimeInterval(30))
        #expect(await mock.executedCommands == [offCommand(), onCommand()])
    }

    @Test("A calendar meeting runs once and leaves the normal undo banner")
    func calendarMeetingRule() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 5)
        )
        let (engine, store, mock, provider) = try await makeEngine(rules: [rule], defaults: defaults)
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(
            id: "event-42",
            title: "Standup",
            startDate: start.addingTimeInterval(4 * 60),
            endDate: start.addingTimeInterval(34 * 60)
        )

        await provider.emit(MacContextSnapshot(meetings: [meeting]), at: start)
        #expect(await mock.executedCommands == [offCommand()])
        #expect(store.undoBanner != nil)

        // The same event must not re-run while its dedupe window is open.
        await provider.emit(MacContextSnapshot(meetings: [meeting]), at: start.addingTimeInterval(30))
        #expect(await mock.executedCommands == [offCommand()])
    }

    @Test("Calendar fallback runs a later meeting when the earliest already fired")
    func calendarFallbackAfterFiredMeeting() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .scene(sceneId: Self.workScene.id),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 60)
        )
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            scenes: [Self.workScene]
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CalendarMeeting(
            id: "first",
            title: "First",
            startDate: start.addingTimeInterval(30 * 60),
            endDate: start.addingTimeInterval(60 * 60)
        )
        let second = CalendarMeeting(
            id: "second",
            title: "Second",
            startDate: start.addingTimeInterval(59 * 60),
            endDate: start.addingTimeInterval(89 * 60)
        )

        await provider.emit(MacContextSnapshot(meetings: [first, second]), at: start)
        #expect(await mock.executedCommands == [.activateScene(entityId: "scene.work")])

        // Both meetings are still inside the lead window; the earliest key is now deduped and the
        // second meeting must get its own chance instead of being masked.
        await provider.emit(
            MacContextSnapshot(meetings: [first, second]),
            at: start.addingTimeInterval(10)
        )
        #expect(await mock.executedCommands == [
            .activateScene(entityId: "scene.work"),
            .activateScene(entityId: "scene.work")
        ])
    }

    @Test("After re-enabling, a meeting added later still runs while one already due stays quiet")
    func calendarMeetingCreatedAfterResumeRuns() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .scene(sceneId: Self.workScene.id),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 5)
        )
        AutomationRuleStore(defaults: defaults).save([rule])
        let (store, mock) = try await makeStore(scenes: [Self.workScene])
        defer { store.stop() }
        let resumedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = FakeMacContextProvider()
        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            environment: Self.unlockedEnvironment,
            now: { resumedAt }
        )
        engine.start(with: store)
        #expect(store.setEventAutomationEnabled(false))
        #expect(store.setEventAutomationEnabled(true))
        #expect(provider.isStarted)

        let dueAtResume = CalendarMeeting(
            id: "due",
            title: "Due",
            startDate: resumedAt.addingTimeInterval(3 * 60),
            endDate: resumedAt.addingTimeInterval(30 * 60)
        )
        await provider.emit(MacContextSnapshot(meetings: [dueAtResume]), at: resumedAt.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)

        let addedLater = CalendarMeeting(
            id: "later",
            title: "Later",
            startDate: resumedAt.addingTimeInterval(5 * 60),
            endDate: resumedAt.addingTimeInterval(35 * 60)
        )
        await provider.emit(
            MacContextSnapshot(meetings: [dueAtResume, addedLater]),
            at: resumedAt.addingTimeInterval(60)
        )
        let command = DeviceCommand.activateScene(entityId: Self.workScene.entityId)
        #expect(await mock.executedCommands == [command])

        let nextDay = resumedAt.addingTimeInterval(24 * 60 * 60)
        var nextOccurrence = dueAtResume
        nextOccurrence.startDate = nextDay.addingTimeInterval(3 * 60)
        nextOccurrence.endDate = nextDay.addingTimeInterval(30 * 60)
        await provider.emit(MacContextSnapshot(meetings: [nextOccurrence]), at: nextDay)
        #expect(await mock.executedCommands == [command, command])
        withExtendedLifetime(engine) {}
    }

    @Test("Late-night use runs once per night, not once per observer tick")
    func lateNightRule() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            calendar: calendar
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let firstNight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 23, minute: 30
        ))!
        let afterMidnight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 3, minute: 30
        ))!
        let nextNight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 23, minute: 30
        ))!

        await provider.emit(MacContextSnapshot(), at: firstNight)
        await provider.emit(MacContextSnapshot(), at: firstNight.addingTimeInterval(600))
        // The shrinking remaining window must not let the same night fire again at 03:30.
        await provider.emit(MacContextSnapshot(), at: afterMidnight)
        #expect(await mock.executedCommands == [offCommand()])

        await provider.emit(MacContextSnapshot(), at: nextNight)
        #expect(await mock.executedCommands.count == 2)
    }

    @Test("Late-night use stays suppressed when the app launches while locked and fires after unlock")
    func lateNightRuleSuppressedWhenLaunchedLockedUntilUnlock() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            calendar: calendar,
            environment: Self.lockedEnvironment
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let night = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 23, minute: 30
        )))

        // Display lit on the lock screen at relaunch: must not count as present or burn the night cooldown.
        await provider.emit(MacContextSnapshot(isUserPresent: true), at: night)
        #expect(await mock.executedCommands.isEmpty)

        // Unlocking restores presence so the next poll in the same night runs the rule.
        await engine.handle(trigger: .back, at: night.addingTimeInterval(60))
        await provider.emit(MacContextSnapshot(isUserPresent: true), at: night.addingTimeInterval(70))
        #expect(await mock.executedCommands == [offCommand()])
    }

    @Test("Arbitrated screen lock and unlock signals immediately toggle presence for late-night rules")
    func arbitratedScreenLockAndUnlockUpdatePresence() async throws {
        let defaults = InMemoryUserDefaults()
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Next year keeps the lock debounce deadline in the future so the background sleep cannot race.
        let year = calendar.component(.year, from: Date()) + 1
        let (engine, store, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            calendar: calendar,
            environment: Self.unlockedEnvironment
        )
        defer { withExtendedLifetime(engine) { store.stop() } }
        let night = try #require(calendar.date(from: DateComponents(
            year: year, month: 6, day: 15, hour: 23, minute: 30
        )))

        await engine.ingestAway(.screenLocked, at: night)
        // Even before the 2 s lock debounce flushes, a poll arriving while locked must not fire.
        await provider.emit(MacContextSnapshot(isUserPresent: true), at: night.addingTimeInterval(1))
        #expect(await mock.executedCommands.isEmpty)

        await engine.ingestAway(.screenUnlocked, at: night.addingTimeInterval(10))
        await provider.emit(MacContextSnapshot(isUserPresent: true), at: night.addingTimeInterval(20))
        #expect(await mock.executedCommands == [offCommand()])
    }
}
