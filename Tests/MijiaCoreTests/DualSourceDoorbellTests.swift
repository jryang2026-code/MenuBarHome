import Foundation
import Testing
@testable import MijiaCore

/// #23: in dual-source mode both sources' doorbell presses land on the merged card, and one
/// physical press that both sources report prompts and pops the camera once.
@Suite(.serialized)
struct DualSourceDoorbellTests {
    private static let did = "1105610385"
    private static let haID = "ha-door-cam"
    private static let haRingEntity = "event.door_ring"
    private static let miRingEntity = "miot-event:1105610385:6:1"
    private static let t0 = "2026-11-18T08:00:00.000+00:00"
    private static let t0Mi = "2026-11-18T08:00:00.400Z"
    private static let t1 = "2026-11-18T08:00:12.000+00:00"
    private static let t1Mi = "2026-11-18T08:00:12.250Z"

    private func camera(id: String, entity: String, stream: String? = nil) -> SmartDevice {
        SmartDevice(
            id: id,
            name: "门口",
            roomId: "door",
            roomName: "门口",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: entity, isOn: true, streamEntityId: stream))
        )
    }

    private func home(_ devices: [SmartDevice], identityID: String) -> SynthesizedHome {
        var home = SynthesizedHome(devices: devices)
        home.deviceIdentities = [
            identityID: DeviceSourceIdentity(
                dids: [Self.did],
                model: "chuangmi.camera.061a01",
                name: "门口",
                roomName: "门口",
                kindTag: .camera
            )
        ]
        return home
    }

    private var haHome: SynthesizedHome {
        home([camera(id: Self.haID, entity: "switch.door_cam_power")], identityID: Self.haID)
    }

    /// The Mi copy can stream, so Mi wins the merged card while HA owns the canonical id.
    private var miHome: SynthesizedHome {
        home(
            [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")],
            identityID: Self.did
        )
    }

    // MARK: - Deduplicator export

    @Test("DeviceMergeResult exports the Mi canonical map so both doorbell sides can translate (#23)")
    func mergeExportsMiCanonicalIDs() throws {
        let result = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        let card = try #require(result.home.devices.first)
        #expect(result.home.devices.count == 1)
        #expect(result.routes[card.id]?.backend == .xiaomiCloud)
        #expect(result.haCanonicalIDs[Self.haID] == card.id)
        #expect(result.miCanonicalIDs[Self.did] == card.id)
    }

    // MARK: - firedAt parsing

    @Test("DoorbellRing parses each source's ISO-8601 shape and rejects non-timestamps")
    func firedAtParsesBothShapes() {
        #expect(DoorbellRing(deviceId: "d", entityId: "e", firedAt: Self.t0).firedAtDate != nil)
        #expect(DoorbellRing(deviceId: "d", entityId: "e", firedAt: Self.t0Mi).firedAtDate != nil)
        #expect(
            DoorbellRing(deviceId: "d", entityId: "e", firedAt: "2026-11-18T08:00:00Z").firedAtDate != nil,
            "HA also writes whole-second Z timestamps"
        )
        #expect(
            DoorbellRing(deviceId: "d", entityId: "e", firedAt: "2026-11-18T08:00:00.000456+00:00").firedAtDate != nil,
            "Python isoformat writes microseconds"
        )
        #expect(DoorbellRing(deviceId: "d", entityId: "e", firedAt: "unavailable").firedAtDate == nil)
        #expect(DoorbellRing(deviceId: "d", entityId: "e", firedAt: "").firedAtDate == nil)
    }

    // MARK: - Dual-source provider

    private actor DoorbellEventCollector {
        private(set) var snapshotCount = 0
        private(set) var lastDeviceCount = 0
        private(set) var rings: [DoorbellRing] = []
        private(set) var latestHome: SynthesizedHome?

        func append(_ event: HomeProviderEvent) {
            switch event {
            case .snapshotUpdated(let home):
                snapshotCount += 1
                lastDeviceCount = home.devices.count
                latestHome = home
            case .doorbellRang(let ring):
                rings.append(ring)
            case .statusChanged, .sessionExpired, .sourceStatusesChanged, .localNetworkPermissionChanged:
                break
            }
        }

        func hasBothMarkers(ha: String, mi: String) -> Bool {
            guard let home = latestHome else { return false }
            return home.scenes.contains { $0.id == ha } && home.homes.contains { $0.id == mi }
        }
    }

    private struct DualRig {
        let haMock: MockHomeProvider
        let miMock: MockHomeProvider
        let haBaseHome: SynthesizedHome
        let miBaseHome: SynthesizedHome
        let provider: DualSourceHomeProvider
        let collector: DoorbellEventCollector
        let pump: Task<Void, Never>
    }

    private func makeRig(
        haDevices: [SmartDevice]? = nil,
        miDevices: [SmartDevice]? = nil,
        expectedDeviceCount: Int = 1
    ) async -> DualRig {
        let haBase = haDevices.map { home($0, identityID: Self.haID) } ?? haHome
        let miBase = miDevices.map { home($0, identityID: Self.did) } ?? miHome
        let haMock = MockHomeProvider(snapshot: haBase)
        let miMock = MockHomeProvider(snapshot: miBase)
        let provider = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miMock)
        let collector = DoorbellEventCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        let rig = DualRig(
            haMock: haMock,
            miMock: miMock,
            haBaseHome: haBase,
            miBaseHome: miBase,
            provider: provider,
            collector: collector,
            pump: pump
        )
        await settleAfterRings(rig)
        let settled = await pollUntil { await collector.lastDeviceCount == expectedDeviceCount }
        #expect(settled, "dual provider never published the merged card")
        return rig
    }

    /// The deadline is the only bound: no fixed yield counts, no product timers.
    private func pollUntil(
        timeout: Duration = .seconds(15),
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Both mocks re-deliver their snapshot with distinct marker content after the rings.
    /// Each source's event stream is FIFO, so once both markers have passed through the
    /// provider and merged into the collector's latest snapshot, both rings were already
    /// handled and the collected rings are final.
    private func settleAfterRings(_ rig: DualRig) async {
        let token = UUID().uuidString
        let haMarker = "ha-marker-\(token)"
        let miMarker = "mi-marker-\(token)"

        var haWithMarker = rig.haBaseHome
        haWithMarker.scenes = [
            HomeScene(id: haMarker, name: "marker", entityId: "scene.\(haMarker)")
        ]

        var miWithMarker = rig.miBaseHome
        miWithMarker.homes = [
            HomeOption(id: miMarker, name: "marker", deviceCount: 0)
        ]

        await rig.haMock.updateSnapshot(haWithMarker)
        await rig.miMock.updateSnapshot(miWithMarker)

        let settled = await pollUntil {
            await rig.collector.hasBothMarkers(ha: haMarker, mi: miMarker)
        }
        #expect(settled, "snapshot markers never reached the collector")
    }

    @Test("One press reported by both sources reaches the store once, on the merged card")
    func pairedPressRingsOnce() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.t0Mi)
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 1, "the same physical press reported by both sources rings once")
        #expect(rings.first?.deviceId == Self.haID, "the ring lands on the merged card id")
    }

    @Test("A second genuine press still rings; each press is delivered once")
    func secondPressStillRings() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.t0Mi)
        )
        await settleAfterRings(rig)

        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.t1Mi)
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t1)
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 2, "a press 12 s later is a new press, not a duplicate")
        #expect(rings.allSatisfy { $0.deviceId == Self.haID })
    }

    @Test("The dedupe window is deterministic: the edge suppresses, one step past it rings")
    func windowEdgeIsDeterministic() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        // Exactly at the 2 s window edge: still the same press.
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.did,
                entityId: Self.miRingEntity,
                firedAt: "2026-11-18T08:00:02.000Z"
            )
        )
        await settleAfterRings(rig)
        #expect((await rig.collector.rings).count == 1, "a press at the window edge is a duplicate")

        // One step past the window: a real second press, delivered.
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t1)
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.did,
                entityId: Self.miRingEntity,
                firedAt: "2026-11-18T08:00:12.600Z"
            )
        )
        await settleAfterRings(rig)
        #expect((await rig.collector.rings).count == 2, "a press past the window is new")
    }

    @Test("A fast double-press on one source still rings twice: only cross-source pairs dedupe")
    func sameSourceDoublePressStillRingsTwice() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.haID,
                entityId: Self.haRingEntity,
                firedAt: "2026-11-18T08:00:01.000+00:00"
            )
        )
        await settleAfterRings(rig)
        #expect((await rig.collector.rings).count == 2)
    }

    @Test("An unpaired device's ring keeps its source id and never suppresses another card")
    func unpairedDevicesKeepTheirIDs() async throws {
        let loneMi = camera(id: "770099", entity: "miot:770099:2", stream: "miot:770099:5")
        let rig = await makeRig(
            miDevices: [
                camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5"),
                loneMi,
            ],
            expectedDeviceCount: 2
        )
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: "770099", entityId: "miot-event:770099:6:1", firedAt: Self.t0)
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 2, "two different physical devices are two presses")
        #expect(rings.contains { $0.deviceId == Self.haID && $0.entityId == Self.haRingEntity })
        #expect(rings.contains { $0.deviceId == "770099" }, "the unpaired Mi device keeps its own did")
    }

    private static let baseDate = ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z")!

    private static func timestamp(offsetSeconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: baseDate.addingTimeInterval(offsetSeconds))
    }

    @Test("A delayed Mi report for an earlier press still matches history after a newer HA press")
    func delayedMiReportMatchesHistoryAfterNewerPress() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        // HA reports two presses at t=0 and t=3 before an in-flight Mi poll returns t=0.4.
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 3))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 3.25))
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 2, "two physical presses must prompt twice even when Mi's first report arrives after HA's second")
        #expect(rings.allSatisfy { $0.deviceId == Self.haID })
    }

    @Test("A delayed HA report for an earlier press still matches history after a newer Mi press")
    func delayedHAReportMatchesMiHistoryAfterNewerPress() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 3.25))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 3))
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 2)
        #expect(rings.allSatisfy { $0.deviceId == Self.haID })
    }

    @Test("A genuine second press within the window still rings after the first press was paired")
    func genuineSecondPressWithinWindowStillRingsAfterFirstPressPaired() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        // Second press 1.5s later arrives on Mi first (e.g. HA missed or lagged), then HA.
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 1.5))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 1.6))
        )
        await settleAfterRings(rig)

        let rings = await rig.collector.rings
        #expect(rings.count == 2, "pairing press 1 must not swallow a genuine fast second press on the other source")
    }

    @Test("A fast double-press reported by both sources rings twice without leaking extras")
    func fastDoublePressAcrossBothSourcesRingsTwice() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 1.5))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 1.8))
        )
        await settleAfterRings(rig)

        #expect((await rig.collector.rings).count == 2)
    }

    @Test("A fast second press reported only by the other source is not swallowed once press 1 is paired")
    func unmatchedSecondPressWithinWindowOnOtherSourceStillRings() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        // Press 1 pairs HA and Mi (consuming HA's entry).
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        // Press 2 occurs 1.5s later, within 2s of press 1, and only Mi reports it.
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 1.5))
        )
        await settleAfterRings(rig)

        #expect((await rig.collector.rings).count == 2)
    }

    @Test("Per-source history is bounded: oldest presses evict while newer ones still match")
    func historyIsBoundedByPerSourceLimit() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        let totalPresses = DualSourceHomeProvider.crossSourceDoorbellHistoryLimit + 2
        for index in 0..<totalPresses {
            await rig.haMock.sendDoorbellRing(
                DoorbellRing(
                    deviceId: Self.haID,
                    entityId: Self.haRingEntity,
                    firedAt: Self.timestamp(offsetSeconds: TimeInterval(index * 3))
                )
            )
        }
        await settleAfterRings(rig)

        #expect((await rig.collector.rings).count == totalPresses)
        let retainedCount = await rig.provider.doorbellPressHistoryCountForTesting(
            cardID: Self.haID,
            backend: .homeAssistant
        )
        #expect(retainedCount == DualSourceHomeProvider.crossSourceDoorbellHistoryLimit)

        // Press 0 was evicted by the cap, so a delayed Mi report for press 0 is no longer suppressed;
        // press 2 is still within the cap and must still match and suppress.
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.did,
                entityId: Self.miRingEntity,
                firedAt: Self.timestamp(offsetSeconds: 2 * 3 + 0.4)
            )
        )
        await settleAfterRings(rig)
        #expect((await rig.collector.rings).count == totalPresses, "retained press still suppresses delayed Mi report")

        await rig.miMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.did,
                entityId: Self.miRingEntity,
                firedAt: Self.timestamp(offsetSeconds: 0.4)
            )
        )
        await settleAfterRings(rig)
        #expect((await rig.collector.rings).count == totalPresses + 1, "evicted oldest press is no longer in history")
    }

    @Test("Old unmatched presses expire after the retention window and stale delayed reports do not linger")
    func historyExpiresOldUnmatchedPresses() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        await rig.haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.timestamp(offsetSeconds: 0))
        )
        await rig.haMock.sendDoorbellRing(
            DoorbellRing(
                deviceId: Self.haID,
                entityId: Self.haRingEntity,
                firedAt: Self.timestamp(offsetSeconds: DualSourceHomeProvider.crossSourceDoorbellHistoryRetention + 5)
            )
        )
        await settleAfterRings(rig)

        let haCount = await rig.provider.doorbellPressHistoryCountForTesting(
            cardID: Self.haID,
            backend: .homeAssistant
        )
        #expect(haCount == 1, "press at t=0 expired once a press past the retention horizon arrived")

        // A severely delayed Mi report for t=0.4 falls past retention and must neither match nor linger.
        await rig.miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.timestamp(offsetSeconds: 0.4))
        )
        await settleAfterRings(rig)

        let miCount = await rig.provider.doorbellPressHistoryCountForTesting(
            cardID: Self.haID,
            backend: .xiaomiCloud
        )
        #expect(miCount == 0, "an already-expired delayed report is pruned instead of lingering")
    }

    @Test("Tracked card count is capped so history never grows unboundedly across cards")
    func trackedCardCountIsBounded() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel(); Task { await rig.provider.shutdown() } }

        let totalCards = DualSourceHomeProvider.crossSourceDoorbellCardLimit + 10
        for index in 0..<totalCards {
            await rig.miMock.sendDoorbellRing(
                DoorbellRing(
                    deviceId: "unpaired-\(index)",
                    entityId: "miot-event:unpaired-\(index):6:1",
                    firedAt: Self.timestamp(offsetSeconds: TimeInterval(index))
                )
            )
        }
        await settleAfterRings(rig)

        let trackedCards = await rig.provider.doorbellTrackedCardCountForTesting
        #expect(trackedCards == DualSourceHomeProvider.crossSourceDoorbellCardLimit)
    }

    // MARK: - Store level (the popup itself)

    @MainActor
    @Test("A paired press opens the merged camera card once (#23 end to end)")
    func pairedPressPopsUpOnce() async throws {
        let suite = "test.dual.doorbell.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )
        await waitUntil {
            store.devices.count == 1 &&
            store.devices.first?.id == Self.haID &&
            store.deviceBackends[Self.haID] == .xiaomiCloud &&
            store.devices.first?.isOnline == true
        }
        store.doorbellAutoPopup = true
        store.doorbellChime = true
        let popups = PopupLog()
        store.onDoorbellRing = { popups.items.append($0) }

        await haMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.haID, entityId: Self.haRingEntity, firedAt: Self.t0)
        )
        await miMock.sendDoorbellRing(
            DoorbellRing(deviceId: Self.did, entityId: Self.miRingEntity, firedAt: Self.t0Mi)
        )
        await waitUntil { store.recentDoorbellRings.count == 1 && popups.items.count == 1 }

        let token = UUID().uuidString
        let haMarker = "ha-marker-\(token)"
        let miMarker = "mi-marker-\(token)"
        var haWithMarker = haHome
        haWithMarker.scenes = [HomeScene(id: haMarker, name: "marker", entityId: "scene.\(haMarker)")]
        var miWithMarker = miHome
        miWithMarker.homes = [HomeOption(id: miMarker, name: "marker", deviceCount: 0)]

        await haMock.updateSnapshot(haWithMarker)
        await miMock.updateSnapshot(miWithMarker)
        await waitUntil {
            store.scenes.contains { $0.id == haMarker } &&
            store.homes.contains { $0.id == miMarker }
        }

        #expect(popups.items == [DoorbellResponse(cameraDeviceId: Self.haID, playsChime: true, dismissAfter: .seconds(60))])
        #expect(store.recentDoorbellRings.count == 1)
    }
}
