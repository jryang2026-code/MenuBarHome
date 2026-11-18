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

        func append(_ event: HomeProviderEvent) {
            switch event {
            case .snapshotUpdated(let home):
                snapshotCount += 1
                lastDeviceCount = home.devices.count
            case .doorbellRang(let ring):
                rings.append(ring)
            case .statusChanged, .sessionExpired, .sourceStatusesChanged:
                break
            }
        }
    }

    private struct DualRig {
        let haMock: MockHomeProvider
        let miMock: MockHomeProvider
        let provider: DualSourceHomeProvider
        let collector: DoorbellEventCollector
        let pump: Task<Void, Never>
    }

    private func makeRig(
        haDevices: [SmartDevice]? = nil,
        miDevices: [SmartDevice]? = nil,
        expectedDeviceCount: Int = 1
    ) async -> DualRig {
        let haMock = MockHomeProvider(
            snapshot: haDevices.map { home($0, identityID: Self.haID) } ?? haHome
        )
        let miMock = MockHomeProvider(
            snapshot: miDevices.map { home($0, identityID: Self.did) } ?? miHome
        )
        let provider = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miMock)
        let collector = DoorbellEventCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        let settled = await pollUntil { await collector.lastDeviceCount == expectedDeviceCount }
        #expect(settled, "dual provider never published the merged card")
        return DualRig(haMock: haMock, miMock: miMock, provider: provider, collector: collector, pump: pump)
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

    /// Both mocks re-deliver their snapshot after the rings. Each source's event stream is FIFO,
    /// so once both markers have passed through the provider, both rings were already handled
    /// and the collected rings are final.
    private func settleAfterRings(_ rig: DualRig) async {
        let baseline = await rig.collector.snapshotCount
        await rig.haMock.updateSnapshot(
            home([camera(id: Self.haID, entity: "switch.door_cam_power")], identityID: Self.haID)
        )
        await rig.miMock.updateSnapshot(
            home(
                [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")],
                identityID: Self.did
            )
        )
        let settled = await pollUntil { await rig.collector.snapshotCount >= baseline + 2 }
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
        await waitUntil { store.devices.count == 1 && store.devices.first?.isOnline == true }
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

        let generationBeforeMarkers = store.snapshotGeneration
        await haMock.updateSnapshot(haHome)
        await miMock.updateSnapshot(miHome)
        await waitUntil { store.snapshotGeneration >= generationBeforeMarkers + 2 }

        #expect(popups.items == [DoorbellResponse(cameraDeviceId: Self.haID, playsChime: true, dismissAfter: .seconds(60))])
        #expect(store.recentDoorbellRings.count == 1)
    }
}
