import AppKit
import Foundation
import PreferencesTestSupport
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// W2A-2 (#432): mirrors Windows `windowsTriggerGating.test.ts` on macOS — statically audits that
/// every trigger in `AutomationTrigger.macOSTriggerSources` is wired to a real production source
/// and deterministically exercises notification, arbitration, display, and context dispatch paths.
@MainActor
struct AutomationTriggerSourceGuardTests {
    private static let lightId = "light_study"

    private func makeStore(lightOn: Bool = true) async throws -> (HomeStore, MockHomeProvider) {
        let light = SmartDevice(
            id: Self.lightId,
            name: "书房台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: lightOn))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [light]))
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    private func makeCenters() -> (
        centers: AutomationNotificationCenters,
        workspace: NotificationCenter,
        distributed: NotificationCenter,
        app: NotificationCenter
    ) {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let app = NotificationCenter()
        return (
            AutomationNotificationCenters(workspace: workspace, distributed: distributed, app: app),
            workspace,
            distributed,
            app
        )
    }

    private struct NotificationHarness {
        let engine: AutomationEngine
        let store: HomeStore
        let mock: MockHomeProvider
        let workspace: NotificationCenter
        let distributed: NotificationCenter
        let app: NotificationCenter
    }

    private func makeNotificationHarness(
        rules: [AutomationRule],
        lightOn: Bool = true,
        isLidClosed: Bool = false,
        displays: @escaping @MainActor () -> Int = { 0 },
        now: @escaping @MainActor () -> Date
    ) async throws -> NotificationHarness {
        let defaults = InMemoryUserDefaults()
        AutomationRuleStore(defaults: defaults).save(rules)
        let (store, mock) = try await makeStore(lightOn: lightOn)
        let (centers, workspace, distributed, app) = makeCenters()
        let engine = AutomationEngine(
            defaults: defaults,
            environment: AutomationEnvironmentProbe(
                isLidClosed: { isLidClosed },
                currentWiFi: { (nil, true) },
                isScreenLocked: { false },
                externalDisplayCount: displays
            ),
            notificationCenters: centers,
            now: now
        )
        engine.start(with: store)
        return NotificationHarness(
            engine: engine,
            store: store,
            mock: mock,
            workspace: workspace,
            distributed: distributed,
            app: app
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "AutomationTriggerSourceGuardTests", code: 1)
    }

    @Test("Every macOS trigger source and supported trigger maps to live production wiring")
    func productionSourceWiringMatchesRegistry() throws {
        let root = try repoRoot()
        let engineSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MenuBarMijiaApp/AutomationEngine.swift"),
            encoding: .utf8
        )
        let observerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MenuBarMijiaApp/MacContextObserver.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MenuBarMijiaApp/AutomationSettingsSection.swift"),
            encoding: .utf8
        )
        let contextAutomationSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MijiaCore/MacContextAutomation.swift"),
            encoding: .utf8
        )
        let arbitratorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MijiaCore/AwayArbitrator.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("AutomationTrigger.macOSSupportedTriggers"))
        #expect(!settingsSource.contains("ForEach(AutomationTrigger.allCases)"))

        let requiredSourceMarkers: [AutomationTriggerSource: (String, String)] = [
            .workspaceWillSleep: (engineSource, "NSWorkspace.willSleepNotification"),
            .workspaceScreensDidSleep: (engineSource, "NSWorkspace.screensDidSleepNotification"),
            .workspaceDidWake: (engineSource, "NSWorkspace.didWakeNotification"),
            .workspaceScreensDidWake: (engineSource, "NSWorkspace.screensDidWakeNotification"),
            .distributedScreenLocked: (engineSource, "com.apple.screenIsLocked"),
            .distributedScreenUnlocked: (engineSource, "com.apple.screenIsUnlocked"),
            .awayArbitrator: (arbitratorSource, "public struct AwayArbitrator"),
            .screenParametersChanged: (engineSource, "NSApplication.didChangeScreenParametersNotification"),
            .macContextObserver: (observerSource, "final class MacContextObserver: MacContextProviding"),
            .workspaceDidActivateApplication: (engineSource, "NSWorkspace.didActivateApplicationNotification"),
        ]
        for source in AutomationTriggerSource.allCases {
            let pair = try #require(requiredSourceMarkers[source])
            #expect(pair.0.contains(pair.1), "Missing production wiring for \(source.rawValue)")
        }

        for trigger in AutomationTrigger.macOSSupportedTriggers {
            let sources = try #require(AutomationTrigger.macOSTriggerSources[trigger])
            #expect(!sources.isEmpty)
            let rule = AutomationRule(trigger: trigger, action: .devices(ids: [Self.lightId], isOn: false))
            #expect(
                AutomationEngine.needsContextPolling([rule]) == trigger.usesMacContextObserver,
                "needsContextPolling disagrees with registry for \(trigger.rawValue)"
            )
            if trigger.usesMacContextObserver {
                #expect(
                    contextAutomationSource.contains(".\(trigger.rawValue)"),
                    "MacContextAutomation must evaluate \(trigger.rawValue)"
                )
            } else if sources.contains(.awayArbitrator) {
                #expect(
                    arbitratorSource.contains(".\(trigger.rawValue)"),
                    "AwayArbitrator must map \(trigger.rawValue)"
                )
            } else if sources.contains(.screenParametersChanged) || sources.contains(.workspaceDidActivateApplication) {
                #expect(
                    engineSource.contains(".\(trigger.rawValue)"),
                    "AutomationEngine must dispatch \(trigger.rawValue)"
                )
            } else {
                #expect(
                    engineSource.contains(", .\(trigger.rawValue)"),
                    "AutomationEngine notification observers must dispatch \(trigger.rawValue)"
                )
            }
        }
    }

    @Test("Notification, arbitration, and display sources dispatch their exact triggers end-to-end")
    func notificationArbitrationAndDisplaySourcesDispatch() async throws {
        // Test each notification/arbitrator entry path independently with a fresh clock and store.
        let baseClock = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. NSWorkspace.willSleepNotification -> .away + .lidClosedSleep (lid closed)
        do {
            let defaults = InMemoryUserDefaults()
            let lidLightId = "light_lid"
            let awayLight = SmartDevice(
                id: Self.lightId,
                name: "书房台灯",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.study", isOn: true))
            )
            let lidLight = SmartDevice(
                id: lidLightId,
                name: "卧室台灯",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.lid", isOn: true))
            )
            let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [awayLight, lidLight]))
            let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
            try await store.waitForTestSnapshot()
            defer { store.stop() }
            AutomationRuleStore(defaults: defaults).save([
                AutomationRule(trigger: .away, action: .devices(ids: [Self.lightId], isOn: false)),
                AutomationRule(trigger: .lidClosedSleep, action: .devices(ids: [lidLightId], isOn: false)),
            ])
            let (centers, workspace, _, _) = makeCenters()
            let engine = AutomationEngine(
                defaults: defaults,
                environment: AutomationEnvironmentProbe(
                    isLidClosed: { true },
                    currentWiFi: { (nil, true) },
                    isScreenLocked: { false }
                ),
                notificationCenters: centers,
                now: { baseClock }
            )
            engine.start(with: store)
            defer { withExtendedLifetime(engine) {} }
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(await waitUntil { store.automationRunHistory.count { $0.result == .executed } == 2 })
            let executed = Set(store.automationRunHistory.filter { $0.result == .executed }.map(\.trigger))
            #expect(executed == [.away, .lidClosedSleep])
            #expect(await mock.executedCommands.count == 2)
        }

        // 2. NSWorkspace.willSleepNotification -> .systemSleep (lid open)
        do {
            let h = try await makeNotificationHarness(
                rules: [AutomationRule(trigger: .systemSleep, action: .devices(ids: [Self.lightId], isOn: false))],
                now: { baseClock }
            )
            defer { withExtendedLifetime(h.engine) { h.store.stop() } }
            h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(await waitUntil { await h.mock.executedCommands.count == 1 })
            #expect(h.store.automationRunHistory.first?.trigger == .systemSleep)
        }

        // 3. NSWorkspace.screensDidSleepNotification -> .away
        do {
            let h = try await makeNotificationHarness(
                rules: [AutomationRule(trigger: .away, action: .devices(ids: [Self.lightId], isOn: false))],
                now: { baseClock }
            )
            defer { withExtendedLifetime(h.engine) { h.store.stop() } }
            h.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            #expect(await waitUntil { await h.mock.executedCommands.count == 1 })
        }

        // 4. NSWorkspace.didWakeNotification & screensDidWakeNotification -> .back
        for wakeName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let h = try await makeNotificationHarness(
                rules: [AutomationRule(trigger: .back, action: .devices(ids: [Self.lightId], isOn: true))],
                lightOn: false,
                now: { baseClock }
            )
            defer { withExtendedLifetime(h.engine) { h.store.stop() } }
            h.workspace.post(name: wakeName, object: nil)
            #expect(await waitUntil { await h.mock.executedCommands.count == 1 })
        }

        // 5. com.apple.screenIsLocked -> .away immediately, and .screenLocked after arbitration debounce;
        //    com.apple.screenIsUnlocked -> .back (and cancels pending lock when unlocked in time).
        do {
            let defaults = InMemoryUserDefaults()
            let lockLightId = "light_lock"
            let awayLight = SmartDevice(
                id: Self.lightId,
                name: "书房台灯",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.study", isOn: true))
            )
            let lockLight = SmartDevice(
                id: lockLightId,
                name: "卧室台灯",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.lock", isOn: true))
            )
            let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [awayLight, lockLight]))
            let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
            try await store.waitForTestSnapshot()
            defer { store.stop() }
            let awayRule = AutomationRule(trigger: .away, action: .devices(ids: [Self.lightId], isOn: false))
            let lockRule = AutomationRule(trigger: .screenLocked, action: .devices(ids: [lockLightId], isOn: false))
            let backRule = AutomationRule(trigger: .back, action: .devices(ids: [Self.lightId], isOn: true))
            AutomationRuleStore(defaults: defaults).save([awayRule, lockRule, backRule])

            // Keep pending lock deadline in the future relative to real time while advancing injected clock on flush.
            let future = Date().addingTimeInterval(3600)
            var currentNow = future
            let (centers, _, distributed, _) = makeCenters()
            let engine = AutomationEngine(
                defaults: defaults,
                environment: AutomationContextEngineTests.unlockedEnvironment,
                notificationCenters: centers,
                now: { currentNow }
            )
            engine.start(with: store)

            distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            #expect(await waitUntil {
                store.automationRunHistory.contains { $0.trigger == .away && $0.result == .executed }
            })
            #expect(!store.automationRunHistory.contains { $0.trigger == .screenLocked })

            // Unlock before debounce expires cancels .screenLocked and triggers .back.
            currentNow = future.addingTimeInterval(1)
            distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
            #expect(await waitUntil {
                store.automationRunHistory.contains { $0.trigger == .back && $0.result == .executed }
            })
            await engine.flushArbitration(at: future.addingTimeInterval(AwayArbitrator.lockDebounce + 1))
            #expect(!store.automationRunHistory.contains { $0.trigger == .screenLocked })

            // A lone lock that persists through the debounce fires .screenLocked.
            currentNow = future.addingTimeInterval(120)
            distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            #expect(await waitUntil {
                store.automationRunHistory.count { $0.trigger == .away && $0.result == .executed } == 2
            })
            await engine.flushArbitration(at: currentNow.addingTimeInterval(AwayArbitrator.lockDebounce))
            #expect(store.automationRunHistory.contains { $0.trigger == .screenLocked && $0.result == .executed })
            #expect(await mock.executedCommands.count == 4)
        }

        // 6. Lock followed by lid-closed sleep suppresses .screenLocked and fires .lidClosedSleep
        do {
            let future = Date().addingTimeInterval(3600)
            var currentNow = future
            let h = try await makeNotificationHarness(
                rules: [
                    AutomationRule(trigger: .screenLocked, action: .devices(ids: [Self.lightId], isOn: false)),
                    AutomationRule(trigger: .lidClosedSleep, action: .devices(ids: [Self.lightId], isOn: false)),
                ],
                isLidClosed: true,
                now: { currentNow }
            )
            defer { h.store.stop() }
            h.distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            #expect(await waitUntil { h.engine.hasPendingAwayLock })
            currentNow = future.addingTimeInterval(0.5)
            h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(await waitUntil {
                h.store.automationRunHistory.contains { $0.trigger == .lidClosedSleep && $0.result == .executed }
            })
            await h.engine.flushArbitration(at: future.addingTimeInterval(AwayArbitrator.lockDebounce + 1))
            #expect(!h.store.automationRunHistory.contains { $0.trigger == .screenLocked })
        }

        // 7. NSApplication.didChangeScreenParametersNotification -> externalDisplayConnected / Disconnected
        do {
            @MainActor final class DisplayCountBox { var count = 1 }
            let displays = DisplayCountBox()
            let h = try await makeNotificationHarness(
                rules: [
                    AutomationRule(trigger: .externalDisplayConnected, action: .devices(ids: [Self.lightId], isOn: false)),
                    AutomationRule(trigger: .externalDisplayDisconnected, action: .devices(ids: [Self.lightId], isOn: true)),
                ],
                displays: { displays.count },
                now: { baseClock }
            )
            defer { withExtendedLifetime(h.engine) { h.store.stop() } }

            // Same count on screen-parameter notification must stay silent (primed baseline = 1).
            h.app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await Task.yield()
            #expect(await h.mock.executedCommands.isEmpty)

            displays.count = 2
            h.app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(await waitUntil {
                h.store.automationRunHistory.contains { $0.trigger == .externalDisplayConnected && $0.result == .executed }
            })

            displays.count = 1
            h.app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(await waitUntil {
                h.store.automationRunHistory.contains { $0.trigger == .externalDisplayDisconnected && $0.result == .executed }
            })
        }
    }

    @Test("All MacContextObserver triggers including scheduledTime dispatch via FakeMacContextProvider")
    func contextObserverTriggersDispatchEndToEnd() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let baselineAt = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 23, minute: 0, second: 0
        )))
        let fireAt = baselineAt.addingTimeInterval(60) // 23:01

        let triggers: [(AutomationTrigger, AutomationTriggerOptions, Bool)] = [
            (.scheduledTime, AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 23, minute: 1)), false),
            (.cameraInUse, AutomationTriggerOptions(), false),
            (.cameraNotInUse, AutomationTriggerOptions(), true),
            (.microphoneInUse, AutomationTriggerOptions(), false),
            (.microphoneNotInUse, AutomationTriggerOptions(), true),
            (.powerConnected, AutomationTriggerOptions(), false),
            (.powerDisconnected, AutomationTriggerOptions(), true),
            (.batteryBelowThreshold, AutomationTriggerOptions(batteryThresholdPercent: 20), false),
            (.wifiNetworkJoined, AutomationTriggerOptions(wifiSSID: "Home"), false),
            (.wifiNetworkLeft, AutomationTriggerOptions(wifiSSID: "Home"), true),
            (.focusModeEnabled, AutomationTriggerOptions(), false),
            (.focusModeDisabled, AutomationTriggerOptions(), true),
            (.calendarMeetingStartingSoon, AutomationTriggerOptions(calendarLeadMinutes: 5), false),
            (.lateNightUsage, AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6), false),
        ]
        let expectedContextTriggers = Set(AutomationTrigger.macOSSupportedTriggers.filter(\.usesMacContextObserver))
        #expect(Set(triggers.map(\.0)) == expectedContextTriggers)

        let defaults = InMemoryUserDefaults()
        let devices = triggers.enumerated().map { index, entry in
            SmartDevice(
                id: "light_\(index)",
                name: "灯\(index)",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.d\(index)", isOn: !entry.2))
            )
        }
        let rules = triggers.enumerated().map { index, entry in
            AutomationRule(
                trigger: entry.0,
                action: .devices(ids: ["light_\(index)"], isOn: entry.2),
                triggerOptions: entry.1
            )
        }
        AutomationRuleStore(defaults: defaults).save(rules)

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        defer { store.stop() }
        let provider = FakeMacContextProvider()
        let (centers, _, _, _) = makeCenters()
        var currentNow = baselineAt
        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            calendar: calendar,
            environment: AutomationContextEngineTests.unlockedEnvironment,
            notificationCenters: centers,
            now: { currentNow }
        )
        engine.start(with: store)
        #expect(provider.isStarted)

        // Baseline snapshot at 23:00 (not matching 23:01, no late-night rule check fails? Wait: lateNight fires here).
        await provider.emit(MacContextSnapshot(
            cameraInUse: false,
            microphoneInUse: false,
            powerSource: .battery,
            batteryPercent: 80,
            wifiSSID: "Office",
            isWiFiAuthorized: true,
            isFocusActive: false,
            isUserPresent: true,
            meetings: []
        ), at: baselineAt)

        // Transition snapshot 1 at 23:01: turns ON camera/mic/AC/Focus, joins Home, adds meeting, matches 23:01.
        currentNow = fireAt
        let meeting = CalendarMeeting(
            id: "standup",
            title: "Standup",
            startDate: fireAt.addingTimeInterval(120),
            endDate: fireAt.addingTimeInterval(1800)
        )
        await provider.emit(MacContextSnapshot(
            cameraInUse: true,
            microphoneInUse: true,
            powerSource: .ac,
            batteryPercent: 80,
            wifiSSID: "Home",
            isWiFiAuthorized: true,
            isFocusActive: true,
            isUserPresent: true,
            meetings: [meeting]
        ), at: fireAt)

        // Transition snapshot 2 at 23:02: turns OFF camera/mic/Focus, disconnects power below 20%, leaves Home.
        let secondFire = fireAt.addingTimeInterval(60)
        currentNow = secondFire
        await provider.emit(MacContextSnapshot(
            cameraInUse: false,
            microphoneInUse: false,
            powerSource: .battery,
            batteryPercent: 10,
            wifiSSID: "Office",
            isWiFiAuthorized: true,
            isFocusActive: false,
            isUserPresent: true,
            meetings: []
        ), at: secondFire)

        let executedTriggers = Set(store.automationRunHistory.filter { $0.result == .executed }.map(\.trigger))
        #expect(executedTriggers == expectedContextTriggers)
    }

    @Test("Sources stay stopped when no enabled rule needs them, warm up baselines, and block unavailable signals")
    func lifecycleWarmupAndAvailabilityGuards() async throws {
        let defaults = InMemoryUserDefaults()
        let (store, mock) = try await makeStore()
        defer { store.stop() }
        let provider = FakeMacContextProvider()
        let (centers, workspace, _, _) = makeCenters()
        var currentNow = Date(timeIntervalSince1970: 1_800_000_000)

        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            environment: AutomationContextEngineTests.unlockedEnvironment,
            notificationCenters: centers,
            now: { currentNow }
        )
        engine.start(with: store)
        #expect(!engine.isObservingSystem)
        #expect(!provider.isStarted)

        // Notification-only rule starts system observers, NOT context polling.
        let awayRule = AutomationRule(trigger: .away, action: .devices(ids: [Self.lightId], isOn: false))
        AutomationRuleStore(defaults: defaults).save([awayRule])
        engine.rulesDidChange()
        #expect(engine.isObservingSystem)
        #expect(!provider.isStarted)

        // Adding a camera rule starts context polling; first snapshot only warms up baseline (camera already in use).
        let camRule = AutomationRule(trigger: .cameraInUse, action: .devices(ids: [Self.lightId], isOn: false))
        let camOffRule = AutomationRule(trigger: .cameraNotInUse, action: .devices(ids: [Self.lightId], isOn: true))
        let batteryRule = AutomationRule(
            trigger: .batteryBelowThreshold,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(batteryThresholdPercent: 20)
        )
        AutomationRuleStore(defaults: defaults).save([awayRule, camRule, camOffRule, batteryRule])
        engine.rulesDidChange()
        #expect(provider.isStarted)

        await provider.emit(MacContextSnapshot(
            cameraInUse: true,
            powerSource: .battery,
            batteryPercent: 10,
            isCameraUsageAvailable: true
        ), at: currentNow)
        #expect(await mock.executedCommands.isEmpty)

        // Unavailable camera or unknown power must not trigger cameraNotInUse / batteryBelowThreshold.
        currentNow = currentNow.addingTimeInterval(10)
        await provider.emit(MacContextSnapshot(
            cameraInUse: false,
            powerSource: .unknown,
            batteryPercent: nil,
            isCameraUsageAvailable: false
        ), at: currentNow)
        #expect(await mock.executedCommands.isEmpty)

        // Recovering while camera is still in use / battery already low must not fabricate cameraInUse or batteryBelowThreshold.
        currentNow = currentNow.addingTimeInterval(10)
        await provider.emit(MacContextSnapshot(
            cameraInUse: true,
            powerSource: .battery,
            batteryPercent: 10,
            isCameraUsageAvailable: true
        ), at: currentNow)
        #expect(await mock.executedCommands.isEmpty)

        // Removing context rules stops context polling immediately.
        AutomationRuleStore(defaults: defaults).save([awayRule])
        engine.rulesDidChange()
        #expect(engine.isObservingSystem)
        #expect(!provider.isStarted)

        // Disabling event automation stops system observers too and ignores notifications.
        #expect(store.setEventAutomationEnabled(false))
        #expect(!engine.isObservingSystem)
        #expect(!provider.isStarted)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        #expect(await mock.executedCommands.isEmpty)

        // Re-enabling event automation warms up baseline so already-active signals and current-minute schedules stay quiet.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let scheduleNow = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 8, minute: 30)))
        currentNow = scheduleNow
        let schedRule = AutomationRule(
            trigger: .scheduledTime,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 8, minute: 30))
        )
        AutomationRuleStore(defaults: defaults).save([camRule, schedRule])
        let utcEngine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            calendar: utc,
            environment: AutomationContextEngineTests.unlockedEnvironment,
            notificationCenters: centers,
            now: { currentNow }
        )
        utcEngine.start(with: store)
        #expect(store.setEventAutomationEnabled(false))
        #expect(store.setEventAutomationEnabled(true))
        #expect(provider.isStarted)

        // First observation right after re-enable: camera already in use and schedule already in minute 08:30 -> both suppressed.
        await provider.emit(MacContextSnapshot(cameraInUse: true, isCameraUsageAvailable: true), at: scheduleNow.addingTimeInterval(5))
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("FrontmostApp source stays stopped when unused, warms up baseline, restores on leave, and stops when disabled")
    func frontmostAppGuardsWarmupAndRestore() async throws {
        let defaults = InMemoryUserDefaults()
        let (store, mock) = try await makeStore(lightOn: true)
        defer { store.stop() }
        let provider = FakeMacContextProvider()
        let (centers, workspace, _, _) = makeCenters()
        var currentNow = Date(timeIntervalSince1970: 1_800_000_000)

        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            environment: AutomationEnvironmentProbe(
                isLidClosed: { false },
                currentWiFi: { (nil, true) },
                isScreenLocked: { false },
                frontmostAppBundleID: { nil }
            ),
            notificationCenters: centers,
            now: { currentNow }
        )
        engine.start(with: store)
        defer { withExtendedLifetime(engine) {} }

        // Off when no enabled rule uses FrontmostApp (even if another rule is enabled).
        let awayRule = AutomationRule(trigger: .away, action: .devices(ids: [Self.lightId], isOn: false))
        AutomationRuleStore(defaults: defaults).save([awayRule])
        engine.rulesDidChange()
        #expect(!engine.isObservingFrontmostApp)
        #expect(!provider.isStarted)

        // Enabling a movie rule starts FrontmostApp observation without starting context polling.
        var movieRule = try #require(AutomationRuleTemplate.movie.makeRules().first)
        movieRule.action = .devices(ids: [Self.lightId], isOn: false)
        movieRule.isEnabled = true
        AutomationRuleStore(defaults: defaults).save([movieRule])
        engine.rulesDidChange()
        #expect(engine.isObservingFrontmostApp)
        #expect(!provider.isStarted)

        func postActivate(_ bundleID: String) {
            workspace.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [AutomationEngine.frontmostAppBundleIDUserInfoKey: bundleID]
            )
        }

        // First observation only warms up baseline, even when it matches the chosen app.
        postActivate("com.colliderli.iina")
        await Task.yield()
        #expect(await mock.executedCommands.isEmpty)

        // Switching to an unrelated app does not fire frontmostAppBecame.
        currentNow = currentNow.addingTimeInterval(5)
        postActivate("com.apple.finder")
        await Task.yield()
        #expect(await mock.executedCommands.isEmpty)

        // Switching to IINA fires the movie rule and turns off the study light.
        currentNow = currentNow.addingTimeInterval(5)
        postActivate("com.colliderli.iina")
        #expect(await waitUntil { await mock.executedCommands.count == 1 })
        #expect(store.devices.first(where: { $0.id == Self.lightId })?.isActiveOn == false)

        // Leaving IINA triggers context restore and turns the study light back on.
        currentNow = currentNow.addingTimeInterval(5)
        postActivate("com.apple.finder")
        #expect(await waitUntil { await mock.executedCommands.count == 2 })
        #expect(store.devices.first(where: { $0.id == Self.lightId })?.isActiveOn == true)

        // The same exit may also arrive through the generic trigger observer. Restoration is
        // deduped at the shared restore entry point.
        await engine.handle(trigger: .frontmostAppLeft, at: currentNow.addingTimeInterval(1))
        #expect(await mock.executedCommands.count == 2)

        // Disabling the FrontmostApp rule stops the source immediately.
        movieRule.isEnabled = false
        AutomationRuleStore(defaults: defaults).save([awayRule, movieRule])
        engine.rulesDidChange()
        #expect(!engine.isObservingFrontmostApp)
    }

    @Test("Meeting template camera rule restores context when camera stops being used")
    func meetingTemplateRestoresOnCameraStop() async throws {
        let defaults = InMemoryUserDefaults()
        let (store, mock) = try await makeStore(lightOn: false)
        defer { store.stop() }
        let provider = FakeMacContextProvider()
        let (centers, _, _, _) = makeCenters()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        var camRule = try #require(AutomationRuleTemplate.meeting.makeRules().first { $0.trigger == .cameraInUse })
        camRule.action = .devices(ids: [Self.lightId], isOn: true)
        camRule.isEnabled = true
        AutomationRuleStore(defaults: defaults).save([camRule])

        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            environment: AutomationContextEngineTests.unlockedEnvironment,
            notificationCenters: centers,
            now: { start }
        )
        engine.start(with: store)
        defer { withExtendedLifetime(engine) {} }

        // Baseline: camera off, light off.
        await provider.emit(MacContextSnapshot(cameraInUse: false, isCameraUsageAvailable: true), at: start)
        #expect(await mock.executedCommands.isEmpty)

        // Camera turns on -> study light turns on.
        await provider.emit(MacContextSnapshot(cameraInUse: true, isCameraUsageAvailable: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.count == 1)
        #expect(store.devices.first(where: { $0.id == Self.lightId })?.isActiveOn == true)

        // Camera turns off -> context stack restores study light back off.
        await provider.emit(MacContextSnapshot(cameraInUse: false, isCameraUsageAvailable: true), at: start.addingTimeInterval(20))
        #expect(await mock.executedCommands.count == 2)
        #expect(store.devices.first(where: { $0.id == Self.lightId })?.isActiveOn == false)
    }
}
