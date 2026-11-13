import Foundation
import Testing
@testable import MijiaCore

/// The activity stack's order and its dismiss rules (§2.2–2.4 of the control-center spec).
struct PanelActivityFeedTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let soon = Date(timeIntervalSince1970: 1_700_003_600)
    private let asking = HAPlaintextPrompt.asking("http://203.0.113.5:8123")
    private let declined = HAPlaintextPrompt.declined("http://192.0.2.10:8123")
    private let address = HADiscoveredInstance(baseURL: "http://192.0.2.11:8123", locationName: "客厅")

    @Test("Notices keep their order, then safety alerts and rings run newest first")
    func nestsNoticesAboveNewestFirstEvents() {
        let olderRing = ring("event.front_ring", at: "2026-11-10T08:00:00.000+00:00")
        let newerRing = ring("event.back_ring", at: "2026-11-10T09:00:00.000+00:00")
        let activities = PanelActivityFeed.items(
            notices: [.miBlocked, .miExpiringSoon(soon)],
            safety: [
                recorded("battery:sink", at: start),
                recorded("leak:sink", at: start.addingTimeInterval(60))
            ],
            doorbells: [olderRing, newerRing],
            dismissedIds: []
        )

        #expect(activities.map(\.id) == [
            "notice.miBlocked",
            "notice.miExpiringSoon.1700003600",
            "leak:sink",
            "battery:sink",
            newerRing.key,
            olderRing.key
        ])

        // The times the cards print: the alert's record time and the press time HA reported.
        #expect(activities[2].date == start.addingTimeInterval(60))
        #expect(activities[3].date == start)
        let newerPress = activities[4].date
        let olderPress = activities[5].date
        #expect(newerPress != nil)
        #expect(olderPress != nil)
        #expect((newerPress ?? .distantPast) > (olderPress ?? .distantPast))
        #expect(activities[0].date == nil)
        #expect(activities[1].date == soon)
    }

    @Test("Ids are stable per row, and the expiring warning is scoped to the expiry it announces")
    func idsAreStableAndScopedToTheAnnouncedExpiry() {
        let first = PanelActivityFeed.items(
            notices: [.miBlocked, .haPlaintext(asking), .haPlaintext(declined), .haAddress(address)],
            safety: [],
            doorbells: [],
            dismissedIds: []
        )
        #expect(first.map(\.id) == [
            "notice.miBlocked",
            "notice.haPlaintext.asking",
            "notice.haPlaintext.declined",
            "notice.haAddress"
        ])

        let repeated = PanelActivityFeed.items(
            notices: [.miBlocked, .haPlaintext(asking), .haPlaintext(declined), .haAddress(address)],
            safety: [],
            doorbells: [],
            dismissedIds: []
        )
        #expect(repeated.map(\.id) == first.map(\.id))

        let expiring = PanelActivityFeed.items(
            notices: [.miExpiringSoon(start), .miExpiringSoon(soon)],
            safety: [],
            doorbells: [],
            dismissedIds: []
        )
        #expect(expiring.map(\.id) == [
            "notice.miExpiringSoon.1700000000",
            "notice.miExpiringSoon.1700003600"
        ])
    }

    @Test("Cleared rows disappear, except the two the user still has to answer")
    func dismissedIdsHideOnlyDismissibleRows() {
        let blockedOrAsking = Set(["notice.miBlocked", "notice.haPlaintext.asking"])
        let others: Set<String> = [
            "notice.haPlaintext.declined",
            "notice.haAddress",
            "notice.miExpiringSoon.1700003600",
            "battery:sink",
            "event.front_ring@2026-11-10T08:00:00.000+00:00"
        ]
        let activities = PanelActivityFeed.items(
            notices: [.miBlocked, .haPlaintext(asking), .haPlaintext(declined), .haAddress(address), .miExpiringSoon(soon)],
            safety: [recorded("battery:sink", at: start)],
            doorbells: [ring("event.front_ring", at: "2026-11-10T08:00:00.000+00:00")],
            dismissedIds: blockedOrAsking.union(others)
        )

        #expect(activities.map(\.id) == ["notice.miBlocked", "notice.haPlaintext.asking"])
        #expect(activities.allSatisfy { !$0.isDismissible })
    }

    @Test("A cleared expiring warning comes back when the session names a new expiry")
    func dismissedExpiringWarningReturnsWithANewExpiry() {
        let cleared = PanelActivityFeed.items(
            notices: [.miExpiringSoon(start)],
            safety: [],
            doorbells: [],
            dismissedIds: ["notice.miExpiringSoon.1700000000"]
        )
        #expect(cleared.isEmpty)

        let renewed = PanelActivityFeed.items(
            notices: [.miExpiringSoon(soon)],
            safety: [],
            doorbells: [],
            dismissedIds: ["notice.miExpiringSoon.1700000000"]
        )
        #expect(renewed.map(\.id) == ["notice.miExpiringSoon.1700003600"])
    }

    @Test("A ring whose press time cannot be read still shows, behind the ones that can")
    func unreadablePressTimeSinksToTheEnd() {
        let readable = ring("event.door_ring", at: "2026-11-10T08:00:00.000+00:00")
        let unknown = ring("event.door_ring", at: "unknown")
        let activities = PanelActivityFeed.items(
            notices: [],
            safety: [],
            doorbells: [unknown, readable],
            dismissedIds: []
        )
        #expect(activities.map(\.id) == [readable.key, unknown.key])
        #expect(activities[0].date != nil)
        #expect(activities[1].date == nil)
    }

    private func recorded(
        _ id: String,
        deviceId: String = "sink",
        at date: Date
    ) -> RecordedSafetyAlert {
        RecordedSafetyAlert(alert: safetyAlert(id, deviceId: deviceId), scope: "demo", date: date)
    }

    private func safetyAlert(_ id: String, deviceId: String = "sink") -> SafetyAlert {
        SafetyAlert(
            id: id,
            deviceId: deviceId,
            title: "水浸传感器 报警",
            body: "厨房的水浸传感器触发",
            turnOffCommand: nil
        )
    }

    private func ring(_ entityId: String, at firedAt: String) -> DoorbellRing {
        DoorbellRing(deviceId: "door", entityId: entityId, firedAt: firedAt)
    }
}

/// The store side of the stack: who writes it, what it hides, and where it ends (§2.4, §13).
@MainActor
struct PanelActivityStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A snapshot records safety alerts even when no notification handler is installed")
    func snapshotRecordsWithoutAHandler() async throws {
        let suite = try makeSuite("record")
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [leak(alarming: false)]))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        #expect(store.enableSafetyAlerts)
        #expect(store.recentSafetyAlerts.isEmpty)
        if case .some = store.onSafetyAlert {
            Issue.record("this test must run with no notification handler installed")
        }

        await mock.updateSnapshot(SynthesizedHome(devices: [leak(alarming: true)]))
        for _ in 0..<100 where store.recentSafetyAlerts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let recorded = try #require(store.recentSafetyAlerts.first)
        #expect(recorded.alert.id.hasPrefix("sensor:leak:sink#miot:2:"))
        #expect(recorded.alert.deviceId == "sink")
        #expect(recorded.scope == "demo")
        #expect(store.panelActivities.map(\.id) == [recorded.id])
    }

    @Test("Recording keeps one row per alert id, newest first, and stops at ten")
    func recordingDedupesAndCapsAtTen() async throws {
        let store = try await makeStore()
        let alerts = (0..<12).map { index in
            SafetyAlert(id: "battery:lamp-\(index)", deviceId: "lamp", title: "Low", body: "Battery low")
        }
        store.recordSafetyAlerts(alerts, now: start)
        #expect(store.recentSafetyAlerts.count == 10)
        #expect(store.recentSafetyAlerts.map(\.id) == (2..<12).reversed().map { "battery:lamp-\($0)" })

        let repeated = SafetyAlert(id: "battery:lamp-11", deviceId: "lamp", title: "Low", body: "Still low")
        store.recordSafetyAlerts([repeated], now: start.addingTimeInterval(60))
        #expect(store.recentSafetyAlerts.count == 10)
        #expect(store.recentSafetyAlerts.filter { $0.id == "battery:lamp-11" }.count == 1)
        #expect(store.recentSafetyAlerts.first?.alert.body == "Still low")
        #expect(store.recentSafetyAlerts.first?.date == start.addingTimeInterval(60))
    }

    @Test("The stack leaves out alerts from another home and rows whose card is gone")
    func stackLeavesOutForeignAndOrphanedRows() async throws {
        let store = try await makeStore(devices: [lamp])
        let scope = store.connectionScopeIdentifier
        store.recentSafetyAlerts = [
            RecordedSafetyAlert(alert: alert("battery:lamp"), scope: scope, date: start),
            RecordedSafetyAlert(alert: alert("battery:unplugged", deviceId: "unplugged"), scope: scope, date: start),
            RecordedSafetyAlert(alert: alert("battery:elsewhere"), scope: "mi:other-account", date: start)
        ]
        store.handleDoorbellRing(DoorbellRing(
            deviceId: "unplugged",
            entityId: "event.old_door",
            firedAt: "2026-11-10T08:00:00.000+00:00"
        ))
        store.handleDoorbellRing(DoorbellRing(
            deviceId: "lamp",
            entityId: "event.lamp_door",
            firedAt: "2026-11-10T08:01:00.000+00:00"
        ))

        #expect(store.panelActivities.map(\.id) == [
            "battery:lamp",
            "event.lamp_door@2026-11-10T08:01:00.000+00:00"
        ])
    }

    @Test("Clearing one alert hides only that row and keeps the record")
    func dismissingASafetyAlertHidesOnlyItsRow() async throws {
        let store = try await makeStore(devices: [lamp])
        store.recordSafetyAlerts([alert("battery:lamp")], now: start)
        let activity = try #require(store.panelActivities.first)

        store.dismissActivity(activity)
        #expect(store.panelActivities.isEmpty)
        #expect(store.dismissedActivityIds == ["battery:lamp"])
        #expect(store.recentSafetyAlerts.count == 1, "the alert stays recorded; only the row is hidden")
    }

    @Test("A dismissal finishing after a replacement cannot hide the new address")
    func staleAddressDismissalKeepsReplacement() async throws {
        let store = try await makeStore()
        store.pendingHAAddressSuggestion = HADiscoveredInstance(baseURL: "http://192.0.2.11:8123")
        let old = try #require(store.panelActivities.first)
        let replacement = HADiscoveredInstance(baseURL: "http://192.0.2.12:8123")
        store.pendingHAAddressSuggestion = replacement
        store.dismissActivity(old)
        #expect(store.pendingHAAddressSuggestion == replacement)
        #expect(store.panelActivities.map(\.id) == ["notice.haAddress"])
    }

    @Test("A newly fired alert reappears after the same alert id was cleared")
    func recurringAlertReappearsAfterDismissal() async throws {
        let store = try await makeStore(devices: [lamp])
        store.recordSafetyAlerts([alert("battery:lamp")], now: start)
        store.dismissActivity(try #require(store.panelActivities.first))
        store.recordSafetyAlerts([alert("battery:lamp")], now: start.addingTimeInterval(60))
        #expect(store.panelActivities.map(\.id) == ["battery:lamp"])
        #expect(!store.dismissedActivityIds.contains("battery:lamp"))
    }

    @Test("A swipe finishing after a new alert cannot clear its replacement")
    func staleAlertDismissalKeepsNewOccurrence() async throws {
        let store = try await makeStore(devices: [lamp])
        store.recordSafetyAlerts([alert("battery:lamp")], now: start)
        let swiped = try #require(store.panelActivities.first)
        store.recordSafetyAlerts([alert("battery:lamp")], now: start.addingTimeInterval(60))
        store.dismissActivity(swiped)
        #expect(store.panelActivities.first?.date == start.addingTimeInterval(60))
        #expect(!store.dismissedActivityIds.contains("battery:lamp"))
    }

    @Test("A removed device cannot revive its previous alert when it returns")
    func removedDeviceDoesNotReviveOldAlert() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp]))
        let store = HomeStore(provider: mock, defaultsSuiteName: try makeSuite("removal"))
        try await store.waitForTestSnapshot()
        store.enableSafetyAlerts = false
        store.recordSafetyAlerts([alert("battery:lamp")], now: start)
        store.dismissActivity(try #require(store.panelActivities.first))
        await mock.updateSnapshot(SynthesizedHome(devices: []))
        try #require(await waitForDevicePresence(store, present: false))
        #expect(store.recentSafetyAlerts.isEmpty)
        #expect(!store.dismissedActivityIds.contains("battery:lamp"))
        await mock.updateSnapshot(SynthesizedHome(devices: [lamp]))
        try #require(await waitForDevicePresence(store, present: true))
        #expect(store.panelActivities.isEmpty)
    }

    private func waitForDevicePresence(_ store: HomeStore, present: Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while store.devices.contains(where: { $0.id == lamp.id }) != present {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("Clearing the address suggestion dismisses the suggestion itself")
    func dismissingTheAddressSuggestionDismissesIt() async throws {
        let store = try await makeStore()
        let instance = HADiscoveredInstance(baseURL: "http://192.0.2.11:8123", locationName: "客厅")
        store.pendingHAAddressSuggestion = instance
        let activity = try #require(store.panelActivities.first { $0.id == "notice.haAddress" })

        store.dismissActivity(activity)
        #expect(store.pendingHAAddressSuggestion == nil)
        #expect(store.panelActivities.isEmpty)
        #expect(store.dismissedActivityIds.isEmpty, "the suggestion itself is the source of truth for this notice")
    }

    @Test("Clear all keeps the blocked session and the plaintext decision on screen")
    func clearAllKeepsTheNoticesTheUserMustAnswer() async throws {
        let store = try await makeExpiredMiStore(devices: [doorCamera])
        store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        let ring = DoorbellRing(deviceId: "door", entityId: "event.door_ring", firedAt: "2026-11-10T08:00:00.000+00:00")
        store.handleDoorbellRing(ring)
        #expect(store.panelActivities.map(\.id) == ["notice.miBlocked", "notice.haPlaintext.asking", ring.key])

        store.clearDismissibleActivities()
        #expect(store.panelActivities.map(\.id) == ["notice.miBlocked", "notice.haPlaintext.asking"])
        #expect(store.dismissedActivityIds == [ring.key])
    }

    @Test("Switching the backend ends the previous home's alerts and cleared rows")
    func switchingBackendClearsActivities() async throws {
        let store = try await makeExpiredMiStore()
        store.recordSafetyAlerts([alert("battery:lamp")], now: start)
        store.dismissedActivityIds.insert("notice.miExpiringSoon.1700000000")
        #expect(store.recentSafetyAlerts.count == 1)
        #expect(!store.dismissedActivityIds.isEmpty)

        store.switchBackend(.demo)
        #expect(store.recentSafetyAlerts.isEmpty)
        #expect(store.dismissedActivityIds.isEmpty)
    }

    @Test("Periodic safety evaluation records long-run alerts into the activity stack without a new snapshot")
    func periodicSafetyEvaluationRecordsLongRunAlert() async throws {
        let plug = SmartDevice(
            id: "heater_plug",
            name: "取暖器插座",
            roomId: "room",
            roomName: "书房",
            model: "cuco.plug.cp1",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater_plug", isOn: true, powerWatts: 1800))
        )
        let store = try await makeStore(devices: [plug])
        store.favoriteDeviceIds = [plug.id]
        store.enableSafetyAlerts = true

        let baseNow = Date()
        #expect(store.evaluateSafetyAlerts(now: baseNow).isEmpty)
        #expect(store.recentSafetyAlerts.isEmpty)

        let fireAt = baseNow.addingTimeInterval(46 * 60)
        let emitted = store.evaluateSafetyAlerts(now: fireAt)
        #expect(emitted.count == 1)
        #expect(store.recentSafetyAlerts.count == 1)
        #expect(store.panelActivities.map(\.id) == [emitted[0].id])
        #expect(store.panelActivities.first?.date == fireAt)
    }

    private let lamp = SmartDevice(
        id: "lamp",
        name: "台灯",
        roomId: "room",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.lamp", isOn: true))
    )

    private let doorCamera = SmartDevice(
        id: "door",
        name: "门口猫眼",
        roomId: "room",
        roomName: "玄关",
        model: "test.camera",
        isOnline: true,
        kind: .camera(CameraSpec(entityId: "camera.door", isOn: true))
    )

    private func alert(_ id: String, deviceId: String = "lamp") -> SafetyAlert {
        SafetyAlert(id: id, deviceId: deviceId, title: "台灯 电量低", body: "请更换电池")
    }

    private func leak(alarming: Bool) -> SmartDevice {
        SmartDevice(
            id: "sink",
            name: "水浸传感器",
            roomId: "room",
            roomName: "厨房",
            model: "test.sensor",
            isOnline: true,
            kind: .sensor(SensorSpec(
                battery: nil,
                observations: [SensorObservation(sourceId: "sink#miot:2", kind: .leak, alarming: alarming)]
            ))
        )
    }

    private func makeSuite(_ name: String) throws -> String {
        let suite = "test.panel.activities.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
        return suite
    }

    private func makeStore(devices: [SmartDevice] = []) async throws -> HomeStore {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: try makeSuite("store"))
        try await store.waitForTestSnapshot()
        return store
    }

    private func makeExpiredMiStore(devices: [SmartDevice] = []) async throws -> HomeStore {
        let suite = "test.panel.activities.mi.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        #expect(MiSessionStore.save(
            MiSession(
                userId: "42",
                cUserId: "c",
                ssecurity: "s",
                serviceToken: "tok",
                expiresAt: start
            ),
            defaults: defaults
        ))
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: devices)),
            defaultsSuiteName: suite
        )
        try await store.waitForTestSnapshot()
        return store
    }
}
