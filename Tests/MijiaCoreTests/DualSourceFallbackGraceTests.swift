import Foundation
import Testing
@testable import MijiaCore

/// #25：配对卡的胜出来源在瞬断时不能来回翻转——短暂断线保持磁滞窗口内的路由与正在观看的
/// 直播；源真正不可用（超过窗口）才切换并明确关闭旧流，之后由新来源恢复播放。
@Suite(.serialized)
struct DualSourceFallbackGraceTests {
    private static let did = "1105610385"
    private static let haID = "ha-door-cam"

    /// A settable clock the provider reads; tests advance it instead of sleeping.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func advance(_ interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(interval)
        }
    }

    private func camera(id: String, entity: String, stream: String?) -> SmartDevice {
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

    private struct Rig {
        let haMock: MockHomeProvider
        let miMock: MockHomeProvider
        let provider: DualSourceHomeProvider
        let collector: RouteCollector
        let clock: TestClock
        let pump: Task<Void, Never>
    }

    private actor RouteCollector {
        private(set) var latestHome: SynthesizedHome?

        func append(_ event: HomeProviderEvent) {
            if case .snapshotUpdated(let home) = event {
                latestHome = home
            }
        }

        func backend(forCard cardID: String) -> HomeBackend? {
            latestHome?.deviceBackends[cardID]
        }

        /// True once a merged snapshot reports the source as disconnected, so a test can gate its
        /// clock advance on the drop actually being recorded (#25).
        func sourceIsDisconnected(_ backend: HomeBackend) -> Bool {
            if case .disconnected = latestHome?.sourceStatuses[backend] ?? .connecting { return true }
            return false
        }
    }

    private func makeRig(
        haStream: String? = "camera.door_stream",
        miStream: String = "miot:\(Self.did):5"
    ) async -> Rig {
        let haHome = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: haStream)],
            identityID: Self.haID
        )
        let miHome = home(
            [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: miStream)],
            identityID: Self.did
        )
        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miMock,
            now: { clock.now }
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        let rig = Rig(haMock: haMock, miMock: miMock, provider: provider, collector: collector, clock: clock, pump: pump)
        await waitUntil { await collector.backend(forCard: Self.haID) != nil }
        return rig
    }

    private func waitForBackend(
        _ rig: Rig,
        cardID: String,
        _ expected: HomeBackend,
        timeout: Duration = .seconds(15)
    ) async {
        await waitUntil(timeout: timeout) {
            await rig.collector.backend(forCard: cardID) == expected
        }
    }

    @Test("A brief Home Assistant blip keeps the paired card and its live camera on HA")
    func briefHABlipHoldsRoutingAndLiveView() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        // Both sources can stream; the tie prefers the low-latency Home Assistant copy.
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // The websocket drops for a moment. Within the grace window the winner must not flip and
        // the live view must keep playing on the old route.
        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty, "A brief blip must not kill the live view")

        // The source comes back before the window ends: nothing ever flipped, nothing closed.
        await rig.haMock.sendStatus(.connected)
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)
        #expect(await rig.miMock.stoppedCameraIDs.isEmpty)
    }

    @Test("A real Home Assistant outage flips the card after the grace window and closes the old stream")
    func realHAOutageFlipsAfterGraceAndClosesOldStream() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)

        await rig.haMock.sendStatus(.disconnected("connection lost"))
        // Still inside the window: routing holds.
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // The outage outlasts the window: the fallback to Mi cloud is adopted and the truly
        // unavailable HA stream is closed explicitly. The clock only advances once a merged
        // snapshot has recorded the drop, so the window cannot start at the advanced time.
        await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        rig.provider.requestRecompute()
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        #expect(await rig.haMock.stoppedCameraIDs == [Self.haID], "The dead source's stream must be closed")

        // Recovery: the next resolve routes the same card onto the Mi cloud copy.
        let miCard = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: miCard)
        #expect(await rig.miMock.requestedCameraQualities.isEmpty == false)
        #expect(await rig.haMock.stoppedCameraIDs == [Self.haID], "The old stream is not stopped twice")
    }

    @Test("A brief Mi cloud blip holds its winning card too")
    func briefMiBlipHoldsRouting() async throws {
        // HA knows the camera but has no stream, so Mi wins the paired card.
        let rig = await makeRig(haStream: nil)
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)
        #expect(await rig.miMock.stoppedCameraIDs.isEmpty)

        await rig.miMock.sendStatus(.disconnected("poll failed"))
        await waitUntil { await rig.collector.sourceIsDisconnected(.xiaomiCloud) }
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        #expect(await rig.miMock.stoppedCameraIDs.isEmpty, "A brief Mi blip must not kill the live view")

        await waitUntil { await rig.collector.sourceIsDisconnected(.xiaomiCloud) }
        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        rig.provider.requestRecompute()
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.miMock.stoppedCameraIDs == [Self.did])
    }

    @Test("A source reconfigured or invalidated skips the grace entirely")
    func invalidationSkipsGrace() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)

        // A credential change invalidates the snapshot: the fallback is immediate, not deferred.
        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await rig.provider.invalidateSnapshot(for: .homeAssistant)
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
    }

    @Test("The grace window is bounded and documented")
    func graceWindowIsBounded() {
        #expect(DualSourceHomeProvider.sourceFallbackGrace > 0)
        #expect(DualSourceHomeProvider.sourceFallbackGrace <= 60, "A real outage must fall back within a minute")
    }
}
