import Foundation
import Testing
@testable import MijiaCore

/// Mi cloud polls every 6 s only while the panel is open, once a minute otherwise, and not at all
/// while the Mac sleeps or is locked (#26).
struct MiCloudPollingTests {
    private static let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")

    private func start(_ provider: MiCloudProvider) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = provider.events()
        let task = Task { for await e in stream { await log.append(e) } }
        return (log, task)
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Policy: 6 s open, 60 s closed, 180 s closed on Low Power, nothing while asleep or locked")
    func policyTable() {
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true)) == .seconds(6))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false)) == .seconds(60))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false, lowPower: true)) == .seconds(180))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true, lowPower: true)) == .seconds(6))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true, systemActive: false)) == nil)
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false, systemActive: false)) == nil)
    }

    @Test("Policy: an untouched closed panel stretches 60 s → 120 s after 30 min → 300 s after 2 h")
    func policyIdleDecay() {
        let touched = Date(timeIntervalSince1970: 1_000_000)

        func makeContext(
            idle: TimeInterval,
            panelVisible: Bool = false,
            systemActive: Bool = true,
            lowPower: Bool = false,
            safetyAlertsRelyOnPolling: Bool = false,
            menuBarShowsLiveReading: Bool = false
        ) -> (PollingContext, Date) {
            (PollingContext(
                panelVisible: panelVisible,
                systemActive: systemActive,
                lowPower: lowPower,
                lastPanelInteractionAt: touched,
                safetyAlertsRelyOnPolling: safetyAlertsRelyOnPolling,
                menuBarShowsLiveReading: menuBarShowsLiveReading
            ), touched.addingTimeInterval(idle))
        }

        let ladder: [(TimeInterval, Duration)] = [
            (0, .seconds(60)),
            (29 * 60, .seconds(60)),
            (30 * 60, .seconds(120)),
            (60 * 60, .seconds(120)),
            (2 * 60 * 60 - 1, .seconds(120)),
            (2 * 60 * 60, .seconds(300)),
            (5 * 60 * 60, .seconds(300)),
        ]
        for (idle, expected) in ladder {
            let (idleContext, idleNow) = makeContext(idle: idle)
            #expect(PollingPolicy.interval(for: idleContext, now: idleNow) == expected)
            // Low Power takes the longer of the two and never their product.
            let (lowPowerContext, lowPowerNow) = makeContext(idle: idle, lowPower: true)
            let lowPowerExpected: Duration = expected == .seconds(300) ? .seconds(300) : .seconds(180)
            #expect(PollingPolicy.interval(for: lowPowerContext, now: lowPowerNow) == lowPowerExpected)
        }

        // An enabled safety alert (ADR-0023 §4) or a label the user keeps on screen holds 60 s.
        let fiveHours: TimeInterval = 5 * 60 * 60
        let (safety, safetyNow) = makeContext(idle: fiveHours, safetyAlertsRelyOnPolling: true)
        #expect(PollingPolicy.interval(for: safety, now: safetyNow) == .seconds(60))
        let (reading, readingNow) = makeContext(idle: fiveHours, menuBarShowsLiveReading: true)
        #expect(PollingPolicy.interval(for: reading, now: readingNow) == .seconds(60))
        let (both, bothNow) = makeContext(
            idle: fiveHours,
            safetyAlertsRelyOnPolling: true,
            menuBarShowsLiveReading: true
        )
        #expect(PollingPolicy.interval(for: both, now: bothNow) == .seconds(60))

        // An open panel stays at 6 s however long the idle clock says, and sleep still stops polling.
        let (open, openNow) = makeContext(idle: fiveHours, panelVisible: true, lowPower: true)
        #expect(PollingPolicy.interval(for: open, now: openNow) == .seconds(6))
        let (asleep, asleepNow) = makeContext(idle: fiveHours, systemActive: false)
        #expect(PollingPolicy.interval(for: asleep, now: asleepNow) == nil)

        // Untracked interaction time keeps the old flat cadence.
        #expect(PollingPolicy.interval(for: PollingContext(), now: touched.addingTimeInterval(fiveHours)) == .seconds(60))
    }

    @Test("Closed panel waits; opening it polls at once and then often; sleep stops polling; waking polls again")
    func pacesWithContext() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .milliseconds(20),
            closedPollInterval: .seconds(60),
            deviceRefreshEveryPolls: 1000,
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await api.getPropsCalls.count == 1, "panel closed: no second poll within a minute")

        await provider.setPollingContext(PollingContext(panelVisible: true))
        #expect(await waitFor { await api.getPropsCalls.count >= 2 }, "opening the panel polls right away")
        #expect(await waitFor { await api.getPropsCalls.count >= 5 }, "panel open: polls on the short interval")

        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false))
        try await Task.sleep(for: .milliseconds(50))
        let whileAsleep = await api.getPropsCalls.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(await api.getPropsCalls.count == whileAsleep, "asleep or locked: zero requests")

        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        #expect(await waitFor { await api.getPropsCalls.count > whileAsleep }, "waking polls right away")
        let afterWake = await api.getPropsCalls.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(await api.getPropsCalls.count == afterWake, "then back to the one-minute rhythm")
        #expect(await api.deviceListCalls == 1)
        await provider.shutdown()
    }

    @Test("With a home selected, only that home's devices are polled")
    func pollsSelectedHomeOnly() async throws {
        let plug = MiDeviceRecord(did: "456", name: "插座", model: "cuco.plug.v3", isOnline: true)
        let rooms = [
            MiRoom(id: "r1", name: "书房", dids: ["123"], homeId: "home-a", homeName: "我家"),
            MiRoom(id: "r2", name: "客厅", dids: ["456"], homeId: "home-b", homeName: "爸妈家"),
        ]
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord, plug], rooms: rooms, values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { "home-a" }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let firstPoll = await api.getPropsCalls.first ?? []
        #expect(!firstPoll.isEmpty)
        #expect(Set(firstPoll.map(\.did)) == ["123"])
        #expect(await log.snapshots.first?.devices.map(\.id) == ["123"])
        #expect(await log.snapshots.first?.homes.map(\.id) == ["home-a", "home-b"])
        await provider.shutdown()
    }

    @Test("A split card reads properties from its parent MIoT did")
    func splitCardReadsParentProperties() async throws {
        let split = MiDeviceRecord(
            did: "123.s2",
            name: "书房开关",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            splitParentDid: "123",
            splitSiid: 2
        )
        let api = StubMiCloudAPI(devices: [split], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        let read = await provider.readBack(deviceId: "123.s2")
        if case .published = read {} else {
            Issue.record("Expected a published read-back")
        }
        let keys = await api.getPropsCalls.last ?? []
        #expect(!keys.isEmpty)
        #expect(Set(keys.map(\.did)) == ["123"])
        await provider.shutdown()
    }

    @Test("Read-back requires fresh power but does not require brightness")
    func readBackRequiresFreshPower() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(sessionLoader: { Self.session }, apiFactory: { _ in api },
                                       specSource: StubSpecSource(), pollInterval: .seconds(60), selectedHomeLoader: { nil })
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await $0.statuses.contains(.connected) })
        let power = MiotPropKey(did: "123", siid: 2, piid: 1)
        await api.removeValue(power)
        if case .failed = await provider.readBack(deviceId: "123") {} else {
            Issue.record("Missing power must fail despite cached power and fresh brightness")
        }
        await api.setValue(power, .bool(true))
        if case .published = await provider.readBack(deviceId: "123") {} else {
            Issue.record("Complete properties must publish")
        }
        await api.removeValue(MiotPropKey(did: "123", siid: 2, piid: 2))
        if case .published = await provider.readBack(deviceId: "123") {} else {
            Issue.record("Fresh power alone must publish")
        }
        await provider.shutdown()
    }

    @Test("A failed read-back disconnect clears after the next successful poll")
    func readBackFailureRecoversConnection() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            closedPollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await $0.statuses.contains(.connected) })

        await api.setGetPropsFailure(.http(500))
        let read = await provider.readBack(deviceId: "123")
        if case .failed = read {} else {
            Issue.record("Expected a failed read-back")
        }
        let message = MiCloudError.http(500).errorDescription ?? ""
        #expect(await log.wait { await $0.statuses.contains(.disconnected(message)) })

        await api.setGetPropsFailure(nil)
        await provider.refreshNow()
        #expect(await log.wait { events in
            let statuses = await events.statuses
            return statuses.filter { $0 == .connected }.count >= 2
        })
        await provider.shutdown()
    }

    @Test("HTTP 429 shows a rate-limit message and waits at least a minute before retrying")
    func rateLimitBacksOff() async throws {
        let api = StubMiCloudAPI(devices: [], rooms: [], values: [:], failure: .http(429))
        let provider = MiCloudProvider(sessionLoader: { Self.session }, apiFactory: { _ in api }, specSource: StubSpecSource())
        let (log, task) = start(provider)
        defer { task.cancel() }

        let message = MiCloudError.http(429).errorDescription ?? ""
        #expect(message.contains("太频繁") || message.contains("rate limiting"))
        #expect(await log.wait { await $0.statuses.contains(.disconnected(message)) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await api.deviceListCalls == 1)
        await provider.shutdown()
    }

    @MainActor
    @Test("HomeStore forwards panel, sleep and Low Power changes to the provider, in order, without repeats")
    func storeForwardsContext() async throws {
        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.polling.\(UUID().uuidString)")
        store.setPanelVisible(true)
        store.setPanelVisible(true)
        store.setSystemActive(false)
        store.setSystemActive(true)
        store.setLowPowerMode(true)
        store.setPanelVisible(false)
        #expect(!store.pollingContext.panelVisible)
        #expect(store.pollingContext.systemActive)
        #expect(store.pollingContext.lowPower)
        // The store stamps the decay inputs itself: the idle clock moved off the launch stamp, the
        // default menu-bar reading keeps the gate closed, and alerts are on by default.
        #expect(store.pollingContext.lastPanelInteractionAt != nil)
        #expect(store.pollingContext.menuBarShowsLiveReading)
        #expect(store.pollingContext.safetyAlertsRelyOnPolling)

        // Forwarding is what this test covers. The idle clock is a `Date` stamped at each call, so
        // compare the paced fields and check the gates on their own.
        let expected: [[Bool]] = [
            [true, true, false],
            [true, false, false],
            [true, true, false],
            [true, true, true],
            [false, true, true],
        ]
        var receivedStyles: [[Bool]] = []
        for _ in 0..<300 {
            let received = await mock.pollingContexts
            receivedStyles = received.suffix(expected.count).map {
                [$0.panelVisible, $0.systemActive, $0.lowPower]
            }
            if receivedStyles == expected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receivedStyles == expected)
    }

    @MainActor
    @Test("Decay gates follow the safety switches and the menu-bar display mode")
    func storeDecayGates() throws {
        let defaults = "test.polling.gates.\(UUID().uuidString)"
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: defaults)
        defer { UserDefaults().removePersistentDomain(forName: defaults) }

        #expect(store.safetyAlertsRelyOnPolling)
        #expect(store.menuBarShowsLiveReading)

        store.menuBarDisplayMode = .iconOnly
        #expect(!store.menuBarShowsLiveReading)
        #expect(!store.pollingContext.menuBarShowsLiveReading)

        store.menuBarDisplayMode = .sensorTemperature
        #expect(store.pollingContext.menuBarShowsLiveReading)

        store.enableSafetyAlerts = false
        #expect(!store.safetyAlertsRelyOnPolling)
        #expect(!store.pollingContext.safetyAlertsRelyOnPolling)

        // Turning the switch back on re-arms the full-speed cadence at once.
        store.enableSafetyAlerts = true
        #expect(store.pollingContext.safetyAlertsRelyOnPolling)

        // Every alert kind off is what finally lets an idle poll stretch.
        for kind in SensorAlertKind.allCases {
            store.setSensorAlertEnabled(kind, false)
        }
        #expect(!store.pollingContext.safetyAlertsRelyOnPolling)
    }
}
