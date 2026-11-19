import Foundation
import Testing
@testable import MijiaCore

/// #25：配对卡的胜出来源在瞬断时不能来回翻转——短暂断线保持磁滞窗口内的路由与正在观看的
/// 直播；源真正不可用（超过窗口）才切换并明确关闭旧流，之后由新来源恢复播放。
@Suite(.serialized)
struct DualSourceFallbackGraceTests {
    private static let did = "1105610385"
    private static let haID = "ha-door-cam"

    /// A settable suspending clock the provider reads; tests advance it instead of sleeping.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SuspendingClock.Instant
        init(_ start: SuspendingClock.Instant = SuspendingClock.now) { current = start }
        var now: SuspendingClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func advance(_ interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            let millis = Int((interval * 1000).rounded())
            current = current.advanced(by: .milliseconds(millis))
        }
    }

    /// Deterministic gate for `graceSleep`: parks scheduled fallback sleepers without wall-clock
    /// waits, throws `CancellationError` when cancelled, and lets tests release sleepers on cue.
    private actor GraceSleepGate {
        private var sleepers: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        private var cancelledBeforeParking: Set<UUID> = []
        private var ignoreCancelOnNextPark = false
        private var ignoreCancelIds: Set<UUID> = []
        private(set) var parkCount = 0
        private(set) var cancelledWakeCount = 0
        private(set) var recordedDelays: [Duration] = []

        var waiting: Int { sleepers.count }

        func ignoreCancellationOnNextSleep() {
            ignoreCancelOnNextPark = true
        }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if ignoreCancelOnNextPark {
                        ignoreCancelOnNextPark = false
                        ignoreCancelIds.insert(id)
                    }
                    if !ignoreCancelIds.contains(id), cancelledBeforeParking.remove(id) != nil {
                        cancelledWakeCount += 1
                        continuation.resume(throwing: CancellationError())
                    } else {
                        recordedDelays.append(duration)
                        parkCount += 1
                        sleepers.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func releaseLatest() {
            guard !sleepers.isEmpty else { return }
            sleepers.removeLast().continuation.resume()
        }

        /// Simulates an older sleeper returning right as a newer recompute has already replaced it
        /// (without throwing `CancellationError`), verifying actor-side token ownership.
        func releaseOldestNormally() {
            guard !sleepers.isEmpty else { return }
            sleepers.removeFirst().continuation.resume()
        }

        private func cancel(_ id: UUID) {
            guard !ignoreCancelIds.contains(id) else { return }
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                cancelledWakeCount += 1
                sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
            } else {
                cancelledBeforeParking.insert(id)
            }
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
        let gate: GraceSleepGate
        let pump: Task<Void, Never>
    }

    private actor RouteCollector {
        private(set) var latestHome: SynthesizedHome?
        private(set) var latestSourceStatuses: [HomeBackend: ConnectionStatus] = [:]
        private(set) var snapshotCount = 0
        private(set) var expiredSessions: [MiSession] = []

        func append(_ event: HomeProviderEvent) {
            switch event {
            case .snapshotUpdated(let home):
                latestHome = home
                latestSourceStatuses = home.sourceStatuses
                snapshotCount += 1
            case .sourceStatusesChanged(let statuses):
                latestSourceStatuses = statuses
            case .sessionExpired(let session):
                expiredSessions.append(session)
            case .statusChanged, .doorbellRang, .localNetworkPermissionChanged:
                break
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

        func sourceIsConnected(_ backend: HomeBackend) -> Bool {
            latestHome?.sourceStatuses[backend]?.isConnected == true
        }

        func accountIsDisconnected(_ accountID: String) -> Bool {
            if case .disconnected = latestHome?.accountStatuses[accountID] ?? .connecting { return true }
            return false
        }

        func accountIsConnected(_ accountID: String) -> Bool {
            latestHome?.accountStatuses[accountID]?.isConnected == true
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
        let clock = TestClock()
        let gate = GraceSleepGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miMock,
            graceNow: { clock.now },
            graceSleep: { duration in try await gate.sleep(duration) }
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        let rig = Rig(
            haMock: haMock,
            miMock: miMock,
            provider: provider,
            collector: collector,
            clock: clock,
            gate: gate,
            pump: pump
        )
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

        // The websocket drops for a moment. Observe the disconnect snapshot first so assertions do
        // not pass against the pre-drop snapshot.
        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty, "A brief blip must not kill the live view")

        // The source comes back before the window ends: nothing ever flipped, nothing closed.
        await rig.haMock.sendStatus(.connected)
        await waitUntil { await rig.collector.sourceIsConnected(.homeAssistant) }
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
        await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
        // Still inside the window after the drop is recorded: routing holds.
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // The outage outlasts the window: the fallback to Mi cloud is adopted and the truly
        // unavailable HA stream is closed explicitly.
        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        rig.provider.requestRecompute()
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }
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

        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        rig.provider.requestRecompute()
        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        await waitUntil { await rig.miMock.stoppedCameraIDs == [Self.did] }
        #expect(await rig.miMock.stoppedCameraIDs == [Self.did])
    }

    @Test("A brief MiAccountsProvider account disconnect holds the paired camera and live stream through grace, then fails over on real outage")
    func miAccountsProviderBlipHoldsPairedCameraAndLiveStream() async throws {
        let cameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:3","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]},{"iid":2,"type":"urn:miot-spec-v2:property:night-shot:00000057:chuangmi-061a01:1","format":"uint8","access":["read","write","notify"],"value-list":[{"value":0,"description":"Off"},{"value":1,"description":"On"},{"value":2,"description":"Auto"}]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let camSpec = MiotFixtures.decode(cameraSpecJSON)
        struct CameraSpecSource: MiotSpecSource {
            let spec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                model == "chuangmi.camera.061a01" ? spec : nil
            }
        }

        let account = MiAccount(session: MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec", serviceToken: "tok-cn", region: "cn"
        ))
        let api = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "r1", name: "门口", dids: [Self.did], homeId: "h1", homeName: "家")],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: Self.did, siid: 2, piid: 2): .number(2),
            ]
        )
        let bridge = StubXiaomiCameraBridge()
        let miAccounts = MiAccountsProvider(
            accounts: [account],
            apiFactory: { _ in api },
            specSource: CameraSpecSource(spec: camSpec),
            cameraBridge: bridge,
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            cameraSessionReleaseDelay: .milliseconds(5),
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let haHome = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)],
            identityID: Self.haID
        )
        let haMock = MockHomeProvider(snapshot: haHome)
        let clock = TestClock()
        let gate = GraceSleepGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            graceSleep: { duration in try await gate.sleep(duration) }
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        defer {
            pump.cancel()
            Task { await provider.shutdown() }
        }

        await waitUntil { await collector.backend(forCard: Self.haID) == .xiaomiCloud }
        let initialCard = try #require(
            await collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await provider.resolveCameraStream(for: initialCard)
        #expect(await bridge.startCalls.count == 1)
        #expect(await bridge.stopCalls.isEmpty)

        // Single poll failure: MiAccountsProvider emits both `.statusChanged(.disconnected)` and a
        // disconnect snapshot marking the account's devices offline+stale.
        await api.setGetPropsFailure(.http(502))
        await miAccounts.refreshNow()
        await waitUntil { await collector.accountIsDisconnected(account.id) }
        #expect(await collector.sourceIsDisconnected(.xiaomiCloud))
        #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge.stopCalls.isEmpty, "A brief account-level Mi blip must not stop the live stream")

        // Recovery within grace keeps the stream alive without ever flipping.
        await api.setGetPropsFailure(nil)
        await miAccounts.refreshNow()
        await waitUntil { await collector.accountIsConnected(account.id) }
        #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge.stopCalls.isEmpty)

        // A second outage that outlasts the grace window fails over automatically via the scheduled
        // fallback recheck (without external events) and closes the dead Mi camera stream.
        await api.setGetPropsFailure(.http(502))
        await miAccounts.refreshNow()
        await waitUntil {
            let disconnected = await collector.accountIsDisconnected(account.id)
            let waiting = await gate.waiting
            return disconnected && waiting == 1
        }
        clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        await gate.releaseLatest()
        await waitUntil { await collector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil { await bridge.stopCalls == [Self.did] }

        // Auth expiry (`sessionExpired`) after recovery skips the grace window immediately.
        await api.setGetPropsFailure(nil)
        await miAccounts.refreshNow()
        await waitUntil {
            let connected = await collector.accountIsConnected(account.id)
            let backend = await collector.backend(forCard: Self.haID)
            return connected && backend == .xiaomiCloud
        }
        await api.setGetPropsFailure(.sessionExpired)
        await miAccounts.refreshNow()
        await waitUntil { await collector.backend(forCard: Self.haID) == .homeAssistant }
    }

    @Test("Other source events during grace cancel superseded fallback tasks without recompute loops")
    func cancelledFallbackTaskDoesNotRecomputeOrReschedule() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)

        // HA drops: first fallback sleeper parks for the full 15s grace window.
        await rig.haMock.sendStatus(.disconnected("blip"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let parks = await rig.gate.parkCount
            let waiting = await rig.gate.waiting
            return disconnected && parks == 1 && waiting == 1
        }

        // Four seconds in, a Xiaomi snapshot arrives while HA is still inside grace.
        // The first sleeper must wake via cancellation and exit without recomputing or rescheduling;
        // only the single replacement sleeper (11s remaining) stays parked.
        rig.clock.advance(4)
        await rig.gate.ignoreCancellationOnNextSleep()
        let updatedMiHome = home(
            [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")],
            identityID: Self.did
        )
        await rig.miMock.updateSnapshot(updatedMiHome)
        await waitUntil {
            let cancelled = await rig.gate.cancelledWakeCount
            let parks = await rig.gate.parkCount
            let waiting = await rig.gate.waiting
            return cancelled == 1 && parks == 2 && waiting == 1
        }
        #expect(await rig.gate.recordedDelays == [.seconds(15), .seconds(11)])

        // Simulate a second recompute at +6s where sleeper #2 finishes its sleep just as #3
        // supersedes it (without throwing CancellationError): token check must still make #2 a no-op.
        rig.clock.advance(2)
        await rig.miMock.updateSnapshot(updatedMiHome)
        await waitUntil {
            let parks = await rig.gate.parkCount
            let waiting = await rig.gate.waiting
            return parks == 3 && waiting == 2
        }
        let snapshotsBeforeStaleWake = await rig.collector.snapshotCount
        await rig.gate.releaseOldestNormally()
        await waitUntil { await rig.provider.discardedFallbackWakeCountForTesting == 1 }
        let markerAfterStaleWake = await rig.collector.snapshotCount
        #expect(markerAfterStaleWake == snapshotsBeforeStaleWake)
        #expect(await rig.gate.parkCount == 3)
        #expect(await rig.gate.waiting == 1)
        #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // Silent line from here on: once the remaining 9s expire and sleeper #3 fires, the card
        // flips to Mi Cloud and closes the dead HA stream without `requestRecompute()`.
        rig.clock.advance(10)
        await rig.gate.releaseLatest()
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }
        #expect(await rig.haMock.stoppedCameraIDs == [Self.haID])
    }

    @Test("System sleep pauses the fallback grace so wake does not immediately flip paired cards")
    func systemSleepFreezesGraceUntilWake() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)

        // HA drops 3 seconds before the Mac goes to sleep.
        await rig.haMock.sendStatus(.disconnected("lid closing"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let waiting = await rig.gate.waiting
            return disconnected && waiting == 1
        }
        rig.clock.advance(3)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { await rig.gate.waiting == 0 }

        // Sixty seconds pass while asleep — far longer than the 15-second grace.
        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace * 4)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        await waitUntil { await rig.gate.waiting == 1 }
        let beforeWakeRecompute = await rig.collector.snapshotCount
        rig.provider.requestRecompute()
        await waitUntil { await rig.collector.snapshotCount > beforeWakeRecompute }

        // On wake only 3 active seconds have elapsed, so HA keeps the card and live camera.
        #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty, "Wake must not immediately flip or stop the camera")

        // Eleven more active seconds (14s total awake < 15s grace) still keep HA active.
        rig.clock.advance(11)
        let beforeNearExpiry = await rig.collector.snapshotCount
        rig.provider.requestRecompute()
        await waitUntil { await rig.collector.snapshotCount > beforeNearExpiry }
        #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // Two more active seconds (16s total awake > 15s grace) let the post-wake sleeper flip to Mi.
        rig.clock.advance(2)
        await rig.gate.releaseLatest()
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }
        #expect(await rig.haMock.stoppedCameraIDs == [Self.haID])

        // A later sleep/wake cycle must not resurrect an outage whose grace already expired.
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        rig.clock.advance(30)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        let beforePostExpiryWake = await rig.collector.snapshotCount
        rig.provider.requestRecompute()
        await waitUntil { await rig.collector.snapshotCount > beforePostExpiryWake }
        #expect(await rig.collector.backend(forCard: Self.haID) == .xiaomiCloud)
    }

    @Test("Wake adopts fallback immediately when grace expired at or before system sleep")
    func wakeAdoptsFallbackWhenGraceAlreadyExpiredBeforeSleep() async throws {
        // 1. Source-level boundary: Mac enters sleep right at the 15s grace boundary before the
        // parked sleeper executes its recompute, and no backend events arrive after wake.
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let waiting = await rig.gate.waiting
            return disconnected && waiting == 1
        }

        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { await rig.gate.waiting == 0 }

        rig.clock.advance(30)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))

        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud, timeout: .seconds(2))
        await waitUntil(timeout: .seconds(2)) { await rig.haMock.stoppedCameraIDs == [Self.haID] }
        #expect(await rig.gate.waiting == 0)

        // 2. Per-account boundary while aggregate Xiaomi stays connected: one of two accounts
        // drops, passes the grace window before sleep cancels its sleeper, and wakes onto a silent line.
        let acc1ID = "cn:1001"
        let acc2ID = "de:2002"
        var miCam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        miCam.accountId = acc1ID
        let miPlug = SmartDevice(
            id: "de-plug-1",
            name: "书房插座",
            roomId: "\(acc2ID)/r2",
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-1:2", isOn: true)),
            accountId: acc2ID
        )
        var miConnected = home([miCam, miPlug], identityID: Self.did)
        miConnected.accountStatuses = [acc1ID: .connected, acc2ID: .connected]
        let haNoStream = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)],
            identityID: Self.haID
        )
        let haMock2 = MockHomeProvider(snapshot: haNoStream)
        let miMock2 = MockHomeProvider(snapshot: miConnected)
        let clock2 = TestClock()
        let gate2 = GraceSleepGate()
        let provider2 = DualSourceHomeProvider(
            homeAssistant: haMock2,
            xiaomiCloud: miMock2,
            graceNow: { clock2.now },
            graceSleep: { duration in try await gate2.sleep(duration) }
        )
        let collector2 = RouteCollector()
        let pump2 = Task {
            for await event in provider2.events() {
                await collector2.append(event)
            }
        }
        defer { pump2.cancel() }

        await waitUntil { await collector2.backend(forCard: Self.haID) == .xiaomiCloud }
        let miCard = try #require(
            await collector2.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await provider2.resolveCameraStream(for: miCard)

        var miAcc1Dropped = miConnected
        miAcc1Dropped.accountStatuses = [acc1ID: .disconnected("HTTP 502"), acc2ID: .connected]
        await miMock2.updateSnapshot(miAcc1Dropped)
        await waitUntil {
            let accDisconnected = await collector2.accountIsDisconnected(acc1ID)
            let waiting = await gate2.waiting
            return accDisconnected && waiting == 1
        }
        #expect(await collector2.sourceIsConnected(.xiaomiCloud))

        clock2.advance(DualSourceHomeProvider.sourceFallbackGrace + 2)
        await provider2.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { await gate2.waiting == 0 }

        clock2.advance(20)
        await provider2.setPollingContext(PollingContext(panelVisible: false, systemActive: true))

        await waitUntil(timeout: .seconds(2)) { await collector2.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await miMock2.stoppedCameraIDs == [Self.did] }
        #expect(await collector2.sourceIsConnected(.xiaomiCloud))
    }

    @Test("sessionExpired immediately skips grace even when the last snapshot still lists Xiaomi as connected")
    func sessionExpiredSkipsGraceWithoutTrailingSnapshotOrStatus() async throws {
        // 1. Multi-account production path: MiAccountsProvider forwards `.sessionExpired` from a
        // follow-up poll without publishing a snapshot or status event, while the second account
        // stays connected.
        let cameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:3","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let plugSpecJSON = #"{"type":"urn:miot-spec-v2:device:outlet:0000A002:cuco-v3:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:switch:0000780C:cuco-v3:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:cuco-v3:1","format":"bool","access":["read","write","notify"]}]}]}"#
        let camSpec = MiotFixtures.decode(cameraSpecJSON)
        let plugSpec = MiotFixtures.decode(plugSpecJSON)
        struct DualSpecSource: MiotSpecSource {
            let camSpec: MiotDeviceSpec
            let plugSpec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                switch model {
                case "chuangmi.camera.061a01": return camSpec
                case "cuco.plug.v3": return plugSpec
                default: return nil
                }
            }
        }

        let session1 = MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn", region: "cn"
        )
        let session2 = MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-2", serviceToken: "tok-de", region: "de"
        )
        let account1 = MiAccount(session: session1)
        let account2 = MiAccount(session: session2)
        let api1 = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "r1", name: "门口", dids: [Self.did], homeId: "h1", homeName: "家")],
            values: [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)]
        )
        let api2 = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: "de-plug-1",
                name: "书房插座",
                model: "cuco.plug.v3",
                isOnline: true
            )],
            rooms: [MiRoom(id: "r2", name: "书房", dids: ["de-plug-1"], homeId: "h2", homeName: "Office")],
            values: [MiotPropKey(did: "de-plug-1", siid: 2, piid: 1): .bool(true)]
        )
        let bridge = StubXiaomiCameraBridge()
        let miAccounts = MiAccountsProvider(
            accounts: [account1, account2],
            apiFactory: { session in session.userId == session1.userId ? api1 : api2 },
            specSource: DualSpecSource(camSpec: camSpec, plugSpec: plugSpec),
            cameraBridge: bridge,
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let haHome = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)],
            identityID: Self.haID
        )
        let haMock = MockHomeProvider(snapshot: haHome)
        let clock = TestClock()
        let gate = GraceSleepGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            graceSleep: { duration in try await gate.sleep(duration) }
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        defer {
            pump.cancel()
            Task { await provider.shutdown() }
        }

        await waitUntil {
            let camBackend = await collector.backend(forCard: Self.haID)
            let plugBackend = await collector.backend(forCard: "de-plug-1")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        let initialCard = try #require(
            await collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await provider.resolveCameraStream(for: initialCard)
        #expect(await bridge.startCalls.count == 1)

        // Make only `getProps` fail with `.sessionExpired`, then execute a write so the immediate
        // follow-up poll latches rejection and yields `.sessionExpired` without a new snapshot.
        await api1.setGetPropsFailure(.sessionExpired)
        try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: true))
        await waitUntil { await collector.expiredSessions.count == 1 }

        await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await bridge.stopCalls == [Self.did] }
        #expect(await collector.accountIsDisconnected(account1.id))
        #expect(await collector.accountIsConnected(account2.id))
        #expect(await collector.sourceIsConnected(.xiaomiCloud))
        let plugAfterExpiry = try #require(
            await collector.latestHome?.devices.first { $0.id == "de-plug-1" }
        )
        #expect(plugAfterExpiry.isOnline)
        #expect(!plugAfterExpiry.telemetryStale)

        // 2. Single-source snapshot (`accountStatuses.isEmpty`): `.sessionExpired` arriving while
        // `miStatus` is still `.connected` must also fail over immediately without waiting for status/snapshot.
        let singleRig = await makeRig(haStream: nil)
        defer { singleRig.pump.cancel() }

        await waitForBackend(singleRig, cardID: Self.haID, .xiaomiCloud)
        let singleCard = try #require(
            await singleRig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await singleRig.provider.resolveCameraStream(for: singleCard)

        await singleRig.miMock.sendSessionExpired(session1)
        await waitUntil { await singleRig.collector.expiredSessions.count == 1 }

        await waitForBackend(singleRig, cardID: Self.haID, .homeAssistant, timeout: .seconds(2))
        await waitUntil(timeout: .seconds(2)) { await singleRig.miMock.stoppedCameraIDs == [Self.did] }
        #expect(await singleRig.collector.sourceIsDisconnected(.xiaomiCloud))
    }

    @Test("A source reconfigured or invalidated skips the grace entirely")
    func invalidationSkipsGrace() async throws {
        let rig = await makeRig()
        defer { rig.pump.cancel() }

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)

        // A credential change invalidates the snapshot: the fallback is immediate, not deferred.
        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
        await rig.provider.invalidateSnapshot(for: .homeAssistant)
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
    }

    @Test("The grace window is bounded and documented")
    func graceWindowIsBounded() {
        #expect(DualSourceHomeProvider.sourceFallbackGrace > 0)
        #expect(DualSourceHomeProvider.sourceFallbackGrace <= 60, "A real outage must fall back within a minute")
    }
}
