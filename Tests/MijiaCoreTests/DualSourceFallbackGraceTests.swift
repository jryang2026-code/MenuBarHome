import Dispatch
import Foundation
import KeychainTestSupport
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

    /// Deterministic `FallbackRecheckTimer` for tests: records armed delays and fire callbacks
    /// synchronously under a lock without spawning any sleeping `Task` (#25, #274).
    private final class GraceTimerGate: FallbackRecheckTimer, @unchecked Sendable {
        private struct Entry {
            let onFire: @Sendable () -> Void
            let ignoreCancel: Bool
        }

        private let lock = NSLock()
        private var entries: [Entry] = []
        private var ignoreCancelOnNextSchedule = false
        private var isInvalidated = false
        private var storedScheduleCount = 0
        private var storedCancelledCount = 0
        private var storedRecordedDelays: [Duration] = []

        var waiting: Int { lock.withLock { entries.count } }
        var parkCount: Int { lock.withLock { storedScheduleCount } }
        var cancelledWakeCount: Int { lock.withLock { storedCancelledCount } }
        var recordedDelays: [Duration] { lock.withLock { storedRecordedDelays } }

        func ignoreCancellationOnNextSleep() {
            lock.withLock { ignoreCancelOnNextSchedule = true }
        }

        func schedule(after delay: Duration, onFire: @escaping @Sendable () -> Void) {
            lock.withLock {
                guard !isInvalidated else { return }
                cancelCancellableEntriesLocked()
                let ignoreCancel = ignoreCancelOnNextSchedule
                ignoreCancelOnNextSchedule = false
                storedRecordedDelays.append(delay)
                storedScheduleCount += 1
                entries.append(Entry(onFire: onFire, ignoreCancel: ignoreCancel))
            }
        }

        func cancelPending() {
            lock.withLock {
                cancelCancellableEntriesLocked()
            }
        }

        func invalidate() {
            lock.withLock {
                isInvalidated = true
                entries.removeAll()
            }
        }

        func shutdown() {
            invalidate()
        }

        func releaseLatest() {
            let entry = lock.withLock { entries.popLast() }
            entry?.onFire()
        }

        /// Simulates an older timer firing right as a newer recompute has already replaced it,
        /// verifying actor-side generation token ownership.
        func releaseOldestNormally() {
            let entry = lock.withLock { entries.isEmpty ? nil : entries.removeFirst() }
            entry?.onFire()
        }

        private func cancelCancellableEntriesLocked() {
            var kept: [Entry] = []
            for entry in entries {
                if entry.ignoreCancel {
                    kept.append(entry)
                } else {
                    storedCancelledCount += 1
                }
            }
            entries = kept
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
        let gate: GraceTimerGate
        let pump: Task<Void, Never>
    }

    private actor RouteCollector {
        private(set) var latestHome: SynthesizedHome?
        private(set) var latestSourceStatuses: [HomeBackend: ConnectionStatus] = [:]
        private(set) var snapshotCount = 0
        private(set) var snapshots: [SynthesizedHome] = []
        private(set) var expiredSessions: [MiSession] = []

        func append(_ event: HomeProviderEvent) {
            switch event {
            case .snapshotUpdated(let home):
                latestHome = home
                latestSourceStatuses = home.sourceStatuses
                snapshotCount += 1
                snapshots.append(home)
            case .sourceStatusesChanged(let statuses):
                latestSourceStatuses = statuses
            case .sessionExpired(let session):
                expiredSessions.append(session)
            case .statusChanged, .doorbellRang, .localNetworkPermissionChanged, .miotTypePruneChanged, .haTypePruneChanged:
                break
            }
        }

        func clearSnapshots() {
            snapshots.removeAll()
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
        _ teardown: Teardown,
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
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miMock,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
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
        track(teardown, rig)
        await waitUntil {
            guard let latest = await collector.latestHome else { return false }
            return latest.deviceBackends[Self.haID] != nil
                && latest.pairedDeviceIDs.contains(Self.haID)
                && latest.sourceStatuses[.homeAssistant]?.isConnected == true
                && latest.sourceStatuses[.xiaomiCloud]?.isConnected == true
        }
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

    /// The providers, timer gates and event pumps one test builds, drained before the test returns
    /// (including when `#require` throws) so no forwarding task outlives the test (#274).
    private final class Teardown {
        private var steps: [() async -> Void] = []
        private var finishes: [() -> Void] = []

        /// Runs first: a provider parked on an `AsyncStream` must see it finished before the
        /// provider itself is shut down.
        func addFinish(_ finish: @escaping () -> Void) {
            finishes.append(finish)
        }

        func add(_ step: @escaping () async -> Void) {
            steps.append(step)
        }

        func drain() async {
            let pendingFinishes = finishes
            finishes.removeAll()
            for finish in pendingFinishes { finish() }
            let pendingSteps = steps
            steps.removeAll()
            for step in pendingSteps.reversed() { await step() }
        }
    }

    /// Runs `body` and always drains its teardown, including when `#require` throws.
    private func withTeardown(_ body: (Teardown) async throws -> Void) async throws {
        let teardown = Teardown()
        do {
            try await body(teardown)
        } catch {
            await teardown.drain()
            throw error
        }
        await teardown.drain()
    }

    /// Invalidates the timer gate, shuts down the provider (which drains its forwarding loops),
    /// and drains the event pump.
    private func shutdownRig(_ rig: Rig) async {
        rig.gate.shutdown()
        await rig.provider.shutdown()
        rig.pump.cancel()
        await rig.pump.value
    }

    private func track(_ teardown: Teardown, _ rig: Rig) {
        teardown.add { await self.shutdownRig(rig) }
    }

    /// Registers a hand-built provider/gate/pump triple, torn down exactly like a rig.
    private func track(
        _ teardown: Teardown,
        provider: DualSourceHomeProvider,
        gate: GraceTimerGate,
        pump: Task<Void, Never>
    ) {
        teardown.add {
            gate.shutdown()
            await provider.shutdown()
            pump.cancel()
            await pump.value
        }
    }

    @Test("A brief Home Assistant blip keeps the paired card and its live camera on HA")
    func briefHABlipHoldsRoutingAndLiveView() async throws {
        try await withTeardown { teardown in
            try await briefHABlipHoldsRoutingAndLiveViewBody(teardown)
        }
    }

    private func briefHABlipHoldsRoutingAndLiveViewBody(_ teardown: Teardown) async throws {
        let rig = await makeRig(teardown)

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
        try await withTeardown { teardown in
            try await realHAOutageFlipsAfterGraceAndClosesOldStreamBody(teardown)
        }
    }

    private func realHAOutageFlipsAfterGraceAndClosesOldStreamBody(_ teardown: Teardown) async throws {
        let rig = await makeRig(teardown)

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
        try await withTeardown { teardown in
            try await briefMiBlipHoldsRoutingBody(teardown)
        }
    }

    private func briefMiBlipHoldsRoutingBody(_ teardown: Teardown) async throws {
        // HA knows the camera but has no stream, so Mi wins the paired card.
        let rig = await makeRig(teardown, haStream: nil)

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
        try await withTeardown { teardown in
            try await miAccountsProviderBlipHoldsPairedCameraAndLiveStreamBody(teardown)
        }
    }

    private func miAccountsProviderBlipHoldsPairedCameraAndLiveStreamBody(_ teardown: Teardown) async throws {
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
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)

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
            let waiting = gate.waiting
            return disconnected && waiting == 1
        }
        clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        gate.releaseLatest()
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

    @Test("Shared camera keeps Mi routing and live stream when streaming account transiently drops while connected co-owner reports it offline")
    func sharedCameraGracedOwnerBeatsOfflineCoOwnerOnTransientDrop() async throws {
        try await withTeardown { teardown in
            try await sharedCameraGracedOwnerBeatsOfflineCoOwnerOnTransientDropBody(teardown)
        }
    }

    private func sharedCameraGracedOwnerBeatsOfflineCoOwnerOnTransientDropBody(_ teardown: Teardown) async throws {
        let cameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:3","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]},{"iid":2,"type":"urn:miot-spec-v2:property:night-shot:00000057:chuangmi-061a01:1","format":"uint8","access":["read","write","notify"],"value-list":[{"value":0,"description":"Off"},{"value":1,"description":"On"},{"value":2,"description":"Auto"}]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let camSpec = MiotFixtures.decode(cameraSpecJSON)
        struct CameraSpecSource: MiotSpecSource {
            let spec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                model == "chuangmi.camera.061a01" ? spec : nil
            }
        }

        let accountA = MiAccount(session: MiSession(
            userId: "10010011", cUserId: "c-a", ssecurity: "ssec-a", serviceToken: "tok-a", region: "cn"
        ))
        let accountB = MiAccount(session: MiSession(
            userId: "10010022", cUserId: "c-b", ssecurity: "ssec-b", serviceToken: "tok-b", region: "cn"
        ))
        let apiA = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rA", name: "门口", dids: [Self.did], homeId: "hA", homeName: "家A")],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: Self.did, siid: 2, piid: 2): .number(2),
            ]
        )
        // Co-owner B stays connected throughout, but always reports the shared camera offline.
        let apiB = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: false,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rB", name: "门口", dids: [Self.did], homeId: "hB", homeName: "家B")],
            values: [:]
        )
        let bridge = StubXiaomiCameraBridge()
        let miAccounts = MiAccountsProvider(
            accounts: [accountA, accountB],
            apiFactory: { session in
                session.userId == accountA.session.userId ? apiA : apiB
            },
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
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)

        await waitUntil {
            let backend = await collector.backend(forCard: Self.haID)
            let aConnected = await collector.accountIsConnected(accountA.id)
            let bConnected = await collector.accountIsConnected(accountB.id)
            return backend == .xiaomiCloud && aConnected && bConnected
        }
        let initialCard = try #require(
            await collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await provider.resolveCameraStream(for: initialCard)
        #expect(await bridge.startCalls.count == 1)
        #expect(await bridge.stopCalls.isEmpty)

        // Start recording every merged snapshot across A's transient drop and recovery.
        await collector.clearSnapshots()

        // Account A transiently drops while B stays connected and reports the shared camera offline.
        // MiAccountsProvider overwrites the DID with B's offline copy, so grace must restore A's
        // pre-drop online copy by DID rather than letting HA take over and kill the stream.
        await apiA.setGetPropsFailure(.http(502))
        await miAccounts.refreshNow()
        await waitUntil {
            let aDisconnected = await collector.accountIsDisconnected(accountA.id)
            let bConnected = await collector.accountIsConnected(accountB.id)
            let waiting = gate.waiting
            return aDisconnected && bConnected && waiting == 1
        }
        #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge.stopCalls.isEmpty, "Transient drop of streaming owner A must not stop the live stream")

        // A subsequent refresh while A is still within grace and B still reports offline must also hold.
        let snapshotsBeforeMidGraceRefresh = await collector.snapshotCount
        clock.advance(5)
        await miAccounts.refreshNow()
        await waitUntil { await collector.snapshotCount > snapshotsBeforeMidGraceRefresh }
        #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge.stopCalls.isEmpty)

        // Account A recovers within grace: zero stream stops and zero card flips throughout.
        await apiA.setGetPropsFailure(nil)
        await miAccounts.refreshNow()
        await waitUntil {
            let aConnected = await collector.accountIsConnected(accountA.id)
            return aConnected && gate.waiting == 0
        }
        let recordedSnapshots = await collector.snapshots
        #expect(!recordedSnapshots.isEmpty)
        for snap in recordedSnapshots {
            #expect(snap.deviceBackends[Self.haID] == .xiaomiCloud)
        }
        #expect(await bridge.stopCalls.isEmpty)

        // If A later suffers a real outage past grace while B remains offline, HA takes over and
        // closes the dead Xiaomi stream.
        await apiA.setGetPropsFailure(.http(502))
        await miAccounts.refreshNow()
        await waitUntil {
            let aDisconnected = await collector.accountIsDisconnected(accountA.id)
            let waiting = gate.waiting
            return aDisconnected && waiting == 1
        }
        clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
        await waitUntil {
            if gate.waiting > 0 {
                gate.releaseLatest()
            }
            return await collector.backend(forCard: Self.haID) == .homeAssistant
        }
        await waitUntil { await bridge.stopCalls.contains(Self.did) }
        #expect(Set(await bridge.stopCalls) == [Self.did])
    }

    @Test("Other source events during grace cancel superseded fallback tasks without recompute loops")
    func cancelledFallbackTaskDoesNotRecomputeOrReschedule() async throws {
        try await withTeardown { teardown in
            try await cancelledFallbackTaskDoesNotRecomputeOrRescheduleBody(teardown)
        }
    }

    private func cancelledFallbackTaskDoesNotRecomputeOrRescheduleBody(_ teardown: Teardown) async throws {
        let rig = await makeRig(teardown)

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let baseline = try #require(await rig.collector.latestHome)
        #expect(baseline.pairedDeviceIDs.contains(Self.haID))
        #expect(baseline.sourceStatuses[.homeAssistant]?.isConnected == true)
        #expect(baseline.sourceStatuses[.xiaomiCloud]?.isConnected == true)
        let card = try #require(baseline.devices.first { $0.id == Self.haID })
        _ = try await rig.provider.resolveCameraStream(for: card)
        let initialParks = rig.gate.parkCount
        #expect(initialParks == 0)

        // HA drops: first fallback sleeper parks for the full 15s grace window.
        await rig.haMock.sendStatus(.disconnected("blip"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let parks = rig.gate.parkCount
            let waiting = rig.gate.waiting
            return disconnected && parks == initialParks + 1 && waiting == 1
        }

        // Four seconds in, a Xiaomi snapshot arrives while HA is still inside grace.
        // The first sleeper must wake via cancellation and exit without recomputing or rescheduling;
        // only the single replacement sleeper (11s remaining) stays parked.
        let snapshotsBeforeFirstMiUpdate = await rig.collector.snapshotCount
        rig.clock.advance(4)
        rig.gate.ignoreCancellationOnNextSleep()
        let updatedMiHome = home(
            [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")],
            identityID: Self.did
        )
        await rig.miMock.updateSnapshot(updatedMiHome)
        await waitUntil {
            let cancelled = rig.gate.cancelledWakeCount
            let parks = rig.gate.parkCount
            let waiting = rig.gate.waiting
            let snapshots = await rig.collector.snapshotCount
            return cancelled == 1 && parks == 2 && waiting == 1 && snapshots > snapshotsBeforeFirstMiUpdate
        }
        #expect(rig.gate.recordedDelays == [.seconds(15), .seconds(11)])

        // Simulate a second recompute at +6s where sleeper #2 finishes its sleep just as #3
        // supersedes it (without throwing CancellationError): token check must still make #2 a no-op.
        let snapshotsBeforeSecondMiUpdate = await rig.collector.snapshotCount
        rig.clock.advance(2)
        await rig.miMock.updateSnapshot(updatedMiHome)
        await waitUntil {
            let parks = rig.gate.parkCount
            let waiting = rig.gate.waiting
            let snapshots = await rig.collector.snapshotCount
            return parks == 3 && waiting == 2 && snapshots > snapshotsBeforeSecondMiUpdate
        }
        let snapshotsBeforeStaleWake = await rig.collector.snapshotCount
        rig.gate.releaseOldestNormally()
        await waitUntil { await rig.provider.discardedFallbackWakeCountForTesting == 1 }
        let markerAfterStaleWake = await rig.collector.snapshotCount
        #expect(markerAfterStaleWake == snapshotsBeforeStaleWake)
        #expect(rig.gate.parkCount == 3)
        #expect(rig.gate.waiting == 1)
        #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        // Silent line from here on: once the remaining 9s expire and sleeper #3 fires, the card
        // flips to Mi Cloud and closes the dead HA stream without `requestRecompute()`.
        rig.clock.advance(10)
        rig.gate.releaseLatest()
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }
        #expect(await rig.haMock.stoppedCameraIDs == [Self.haID])
    }

    @Test("System sleep pauses the fallback grace so wake does not immediately flip paired cards")
    func systemSleepFreezesGraceUntilWake() async throws {
        try await withTeardown { teardown in
            try await systemSleepFreezesGraceUntilWakeBody(teardown)
        }
    }

    private func systemSleepFreezesGraceUntilWakeBody(_ teardown: Teardown) async throws {
        let rig = await makeRig(teardown)

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)

        // HA drops 3 seconds before the Mac goes to sleep.
        await rig.haMock.sendStatus(.disconnected("lid closing"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let waiting = rig.gate.waiting
            return disconnected && waiting == 1
        }
        rig.clock.advance(3)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { rig.gate.waiting == 0 }

        // Sixty seconds pass while asleep — far longer than the 15-second grace.
        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace * 4)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        await waitUntil { rig.gate.waiting == 1 }
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
        rig.gate.releaseLatest()
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
        try await withTeardown { teardown in
            try await wakeAdoptsFallbackWhenGraceAlreadyExpiredBeforeSleepBody(teardown)
        }
    }

    private func wakeAdoptsFallbackWhenGraceAlreadyExpiredBeforeSleepBody(_ teardown: Teardown) async throws {
        // 1. Source-level boundary: Mac enters sleep right at the 15s grace boundary before the
        // parked sleeper executes its recompute, and no backend events arrive after wake.
        let rig = await makeRig(teardown)

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
        let card = try #require(
            await rig.collector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await rig.provider.resolveCameraStream(for: card)
        #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitUntil {
            let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
            let waiting = rig.gate.waiting
            return disconnected && waiting == 1
        }

        rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { rig.gate.waiting == 0 }

        rig.clock.advance(30)
        await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))

        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud, timeout: .seconds(2))
        await waitUntil(timeout: .seconds(2)) { await rig.haMock.stoppedCameraIDs == [Self.haID] }
        #expect(rig.gate.waiting == 0)

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
        let gate2 = GraceTimerGate()
        let provider2 = DualSourceHomeProvider(
            homeAssistant: haMock2,
            xiaomiCloud: miMock2,
            graceNow: { clock2.now },
            fallbackRecheckTimer: gate2
        )
        let collector2 = RouteCollector()
        let pump2 = Task {
            for await event in provider2.events() {
                await collector2.append(event)
            }
        }
        track(teardown, provider: provider2, gate: gate2, pump: pump2)

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
            let waiting = gate2.waiting
            return accDisconnected && waiting == 1
        }
        #expect(await collector2.sourceIsConnected(.xiaomiCloud))

        clock2.advance(DualSourceHomeProvider.sourceFallbackGrace + 2)
        await provider2.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await waitUntil { gate2.waiting == 0 }

        clock2.advance(20)
        await provider2.setPollingContext(PollingContext(panelVisible: false, systemActive: true))

        await waitUntil(timeout: .seconds(2)) { await collector2.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await miMock2.stoppedCameraIDs == [Self.did] }
        #expect(await collector2.sourceIsConnected(.xiaomiCloud))
    }

    @Test("sessionExpired immediately skips grace even when the last snapshot still lists Xiaomi as connected")
    func sessionExpiredSkipsGraceWithoutTrailingSnapshotOrStatus() async throws {
        try await withTeardown { teardown in
            try await sessionExpiredSkipsGraceWithoutTrailingSnapshotOrStatusBody(teardown)
        }
    }

    private func sessionExpiredSkipsGraceWithoutTrailingSnapshotOrStatusBody(_ teardown: Teardown) async throws {
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
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)

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
        let singleRig = await makeRig(teardown, haStream: nil)

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
        try await withTeardown { teardown in
            try await invalidationSkipsGraceBody(teardown)
        }
    }

    private func invalidationSkipsGraceBody(_ teardown: Teardown) async throws {
        let rig = await makeRig(teardown)

        await waitForBackend(rig, cardID: Self.haID, .homeAssistant)

        // A credential change invalidates the snapshot: the fallback is immediate, not deferred.
        await rig.haMock.sendStatus(.disconnected("connection lost"))
        await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
        await rig.provider.invalidateSnapshot(for: .homeAssistant)
        await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
    }

    @Test("Expired Xiaomi account drops its candidates so paired devices route to HA immediately including nil-accountId devices while healthy accounts keep winning")
    func sessionExpiredDropsCandidatesAcrossTieBreakersAndNilAccountID() async throws {
        try await withTeardown { teardown in
            try await sessionExpiredDropsCandidatesAcrossTieBreakersAndNilAccountIDBody(teardown)
        }
    }

    private func sessionExpiredDropsCandidatesAcrossTieBreakersAndNilAccountIDBody(_ teardown: Teardown) async throws {
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
        let studyMiDID = "2205610385"
        let studyHAID = "ha-study-cam"

        // 1. Multi-account MiAccountsProvider: HA's copy of account1's paired camera is currently
        // offline (`isOnline == false`, no stream) and pinned to `.xiaomiCloud`, which previously
        // let the expired Xiaomi candidate keep winning via `hasLiveView` / `pinnedBackends`.
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
            devices: [
                MiDeviceRecord(
                    did: studyMiDID,
                    name: "书房摄像机",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.46"
                ),
                MiDeviceRecord(
                    did: "de-plug-1",
                    name: "书房插座",
                    model: "cuco.plug.v3",
                    isOnline: true
                ),
            ],
            rooms: [MiRoom(id: "r2", name: "书房", dids: [studyMiDID, "de-plug-1"], homeId: "h2", homeName: "Office")],
            values: [
                MiotPropKey(did: studyMiDID, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "de-plug-1", siid: 2, piid: 1): .bool(true),
            ]
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
        var offlineHADoorCam = camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)
        offlineHADoorCam.isOnline = false
        let onlineHAStudyCam = SmartDevice(
            id: studyHAID,
            name: "书房摄像机",
            roomId: "study",
            roomName: "书房",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "switch.study_cam_power", isOn: true, streamEntityId: nil))
        )
        var haMultiHome = SynthesizedHome(devices: [offlineHADoorCam, onlineHAStudyCam])
        haMultiHome.deviceIdentities = [
            Self.haID: DeviceSourceIdentity(
                dids: [Self.did],
                model: "chuangmi.camera.061a01",
                name: "门口",
                roomName: "门口",
                kindTag: .camera
            ),
            studyHAID: DeviceSourceIdentity(
                dids: [studyMiDID],
                model: "chuangmi.camera.061a01",
                name: "书房摄像机",
                roomName: "书房",
                kindTag: .camera
            ),
        ]
        let haMock = MockHomeProvider(snapshot: haMultiHome)
        let clock = TestClock()
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            pinnedBackends: { [Self.haID: .xiaomiCloud] },
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)

        await waitUntil {
            let doorBackend = await collector.backend(forCard: Self.haID)
            let studyBackend = await collector.backend(forCard: studyHAID)
            let plugBackend = await collector.backend(forCard: "de-plug-1")
            return doorBackend == .xiaomiCloud && studyBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        let doorCard = try #require(await collector.latestHome?.devices.first { $0.id == Self.haID })
        let studyCard = try #require(await collector.latestHome?.devices.first { $0.id == studyHAID })
        _ = try await provider.resolveCameraStream(for: doorCard)
        _ = try await provider.resolveCameraStream(for: studyCard)
        #expect(await bridge.startCalls.count == 2)

        await api1.setGetPropsFailure(.sessionExpired)
        try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: true))
        await waitUntil { await collector.expiredSessions.count == 1 }

        await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await bridge.stopCalls == [Self.did] }
        #expect(await collector.backend(forCard: studyHAID) == .xiaomiCloud)
        #expect(await collector.backend(forCard: "de-plug-1") == .xiaomiCloud)
        #expect(await collector.accountIsDisconnected(account1.id))
        #expect(await collector.accountIsConnected(account2.id))
        #expect(await collector.sourceIsConnected(.xiaomiCloud))

        // 2. Single-session MiCloudProvider (`account == nil`) leaves `SmartDevice.accountId == nil`
        // and `accountStatuses` empty; `.sessionExpired` on `execute` must still drop the expired
        // candidate immediately even when HA's paired camera is offline and pinned to Xiaomi.
        let singleAPI = StubMiCloudAPI(
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
        let singleBridge = StubXiaomiCameraBridge()
        let singleMi = MiCloudProvider(
            sessionLoader: { session1 },
            apiFactory: { _ in singleAPI },
            specSource: DualSpecSource(camSpec: camSpec, plugSpec: plugSpec),
            cameraBridge: singleBridge,
            localClient: nil,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil }
        )
        var singleHAHome = home([offlineHADoorCam], identityID: Self.haID)
        singleHAHome.devices[0].isOnline = false
        let singleHAMock = MockHomeProvider(snapshot: singleHAHome)
        let singleDual = DualSourceHomeProvider(
            homeAssistant: singleHAMock,
            xiaomiCloud: singleMi,
            pinnedBackends: { [Self.haID: .xiaomiCloud] },
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let singleCollector = RouteCollector()
        let singlePump = Task {
            for await event in singleDual.events() {
                await singleCollector.append(event)
            }
        }
        track(teardown, provider: singleDual, gate: gate, pump: singlePump)

        await waitUntil { await singleCollector.backend(forCard: Self.haID) == .xiaomiCloud }
        let singleInitialCard = try #require(
            await singleCollector.latestHome?.devices.first { $0.id == Self.haID }
        )
        #expect(singleInitialCard.accountId == nil)
        _ = try await singleDual.resolveCameraStream(for: singleInitialCard)
        #expect(await singleBridge.startCalls.count == 1)

        await singleAPI.setSetPropsFailure(.sessionExpired)
        await #expect(throws: MiCloudError.sessionExpired) {
            try await singleDual.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
        }
        await waitUntil(timeout: .seconds(2)) { await singleCollector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await singleBridge.stopCalls == [Self.did] }

        // 3. Multi-account snapshot where a device has `accountId == nil` (room-scoped to account1)
        // while account2 stays connected must also demote only account1's device immediately.
        var unscopedOwnerCam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        unscopedOwnerCam.accountId = nil
        unscopedOwnerCam.roomId = MiAccountScope.id("door", account: account1.id)
        let acc2Plug = SmartDevice(
            id: "de-plug-2",
            name: "客卧插座",
            roomId: MiAccountScope.id("r2", account: account2.id),
            roomName: "客卧",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-2:2", isOn: true)),
            accountId: account2.id
        )
        var scopedMiHome = home([unscopedOwnerCam, acc2Plug], identityID: Self.did)
        scopedMiHome.accountStatuses = [account1.id: .connected, account2.id: .connected]
        let onlineHADoorHome = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)],
            identityID: Self.haID
        )
        let scopedHAMock = MockHomeProvider(snapshot: onlineHADoorHome)
        let scopedMiMock = MockHomeProvider(snapshot: scopedMiHome)
        let scopedDual = DualSourceHomeProvider(
            homeAssistant: scopedHAMock,
            xiaomiCloud: scopedMiMock,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let scopedCollector = RouteCollector()
        let scopedPump = Task {
            for await event in scopedDual.events() {
                await scopedCollector.append(event)
            }
        }
        track(teardown, provider: scopedDual, gate: gate, pump: scopedPump)

        await waitUntil {
            let camBackend = await scopedCollector.backend(forCard: Self.haID)
            let plugBackend = await scopedCollector.backend(forCard: "de-plug-2")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        let scopedCard = try #require(
            await scopedCollector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await scopedDual.resolveCameraStream(for: scopedCard)

        await scopedMiMock.sendSessionExpired(session1)
        await waitUntil { await scopedCollector.expiredSessions.count == 1 }
        await waitUntil(timeout: .seconds(2)) { await scopedCollector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await scopedMiMock.stoppedCameraIDs == [Self.did] }
        #expect(await scopedCollector.backend(forCard: "de-plug-2") == .xiaomiCloud)

        // 4. Multi-account snapshot with a completely unattributed device (`accountId == nil` and
        // unscoped `roomId`) plus MIoT `deviceFacets` and canonical ID preserved as `did`: expiry
        // must still drop the unattributed Xiaomi candidate and strip its dead MIoT facets while
        // keeping `account2`'s tagged device untouched.
        var unattributedCam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        unattributedCam.accountId = nil
        unattributedCam.roomId = "door"
        var unattributedMiHome = home([unattributedCam, acc2Plug], identityID: Self.did)
        unattributedMiHome.accountStatuses = [account1.id: .connected, account2.id: .connected]
        unattributedMiHome.deviceFacets = [
            Self.did: [
                FacetControl(
                    id: "3.1",
                    kind: .toggle,
                    name: "led",
                    title: "状态指示灯",
                    serviceName: "indicator-light",
                    value: .bool(true),
                    isWritable: true,
                    writesByDefault: true,
                    isHighValue: false,
                    target: .property(entityId: "miot:\(Self.did):3", piid: 1)
                )
            ]
        ]
        let unattributedHAMock = MockHomeProvider(snapshot: onlineHADoorHome)
        let unattributedMiMock = MockHomeProvider(snapshot: unattributedMiHome)
        let unattributedDual = DualSourceHomeProvider(
            homeAssistant: unattributedHAMock,
            xiaomiCloud: unattributedMiMock,
            knownPreferenceIDs: { [Self.did] },
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let unattributedCollector = RouteCollector()
        let unattributedPump = Task {
            for await event in unattributedDual.events() {
                await unattributedCollector.append(event)
            }
        }
        track(teardown, provider: unattributedDual, gate: gate, pump: unattributedPump)

        await waitUntil {
            let camBackend = await unattributedCollector.backend(forCard: Self.did)
            let plugBackend = await unattributedCollector.backend(forCard: "de-plug-2")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        #expect(await unattributedCollector.latestHome?.deviceFacets[Self.did]?.isEmpty == false)

        await unattributedMiMock.sendSessionExpired(session1)
        await waitUntil { await unattributedCollector.expiredSessions.count == 1 }
        await waitUntil(timeout: .seconds(2)) { await unattributedCollector.backend(forCard: Self.did) == .homeAssistant }
        #expect(await unattributedCollector.latestHome?.deviceFacets[Self.did] == nil)
        #expect(await unattributedCollector.backend(forCard: "de-plug-2") == .xiaomiCloud)
    }

    @Test("Shared Xiaomi devices stay uninterrupted on surviving co-owner when another account's session expires")
    func sharedXiaomiDevicesSurviveCoOwnerSessionExpiry() async throws {
        try await withTeardown { teardown in
            try await sharedXiaomiDevicesSurviveCoOwnerSessionExpiryBody(teardown)
        }
    }

    private func sharedXiaomiDevicesSurviveCoOwnerSessionExpiryBody(_ teardown: Teardown) async throws {
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
        let sharedPlugDID = "shared-plug-1"
        let exclusiveCamDID = "2205610999"
        let exclusiveHAID = "ha-exclusive-cam"

        // 1. End-to-end MiAccountsProvider + DualSourceHomeProvider (`setProps` -> `.sessionExpired`
        // followed by `.statusChanged(.disconnected)` on `account1`):
        // - `Self.did` (paired with `Self.haID`, HA lacks stream) and `sharedPlugDID` (unpaired) are
        //   shared by `account1` and `account2`, initially deduplicated to `account1`.
        // - `exclusiveCamDID` (paired with `exclusiveHAID`) belongs only to `account1`.
        // When `account1` expires, exclusive devices must immediately fail over to HA without
        // parking a grace sleeper, while shared devices promote to `account2` with zero frames
        // missing and zero frames bouncing to HA (keeping the live camera bridge uninterrupted).
        let api1 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(
                    did: Self.did,
                    name: "门口",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.45"
                ),
                MiDeviceRecord(
                    did: sharedPlugDID,
                    name: "共享插座",
                    model: "cuco.plug.v3",
                    isOnline: true
                ),
                MiDeviceRecord(
                    did: exclusiveCamDID,
                    name: "玄关独享摄像机",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.47"
                ),
            ],
            rooms: [
                MiRoom(
                    id: "r1",
                    name: "门口",
                    dids: [Self.did, sharedPlugDID, exclusiveCamDID],
                    homeId: "h1",
                    homeName: "主家庭"
                )
            ],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: sharedPlugDID, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: exclusiveCamDID, siid: 2, piid: 1): .bool(true),
            ]
        )
        let api2 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(
                    did: Self.did,
                    name: "门口",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.45"
                ),
                MiDeviceRecord(
                    did: sharedPlugDID,
                    name: "共享插座",
                    model: "cuco.plug.v3",
                    isOnline: true
                ),
            ],
            rooms: [
                MiRoom(
                    id: "r1-shared",
                    name: "门口",
                    dids: [Self.did, sharedPlugDID],
                    homeId: "h2",
                    homeName: "共享家庭"
                )
            ],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: sharedPlugDID, siid: 2, piid: 1): .bool(true),
            ]
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
        let haSharedDoorCam = camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)
        let haExclusiveCam = SmartDevice(
            id: exclusiveHAID,
            name: "玄关独享摄像机",
            roomId: "door",
            roomName: "门口",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "switch.exclusive_cam_power", isOn: true, streamEntityId: nil))
        )
        var haMultiHome = SynthesizedHome(devices: [haSharedDoorCam, haExclusiveCam])
        haMultiHome.deviceIdentities = [
            Self.haID: DeviceSourceIdentity(
                dids: [Self.did],
                model: "chuangmi.camera.061a01",
                name: "门口",
                roomName: "门口",
                kindTag: .camera
            ),
            exclusiveHAID: DeviceSourceIdentity(
                dids: [exclusiveCamDID],
                model: "chuangmi.camera.061a01",
                name: "玄关独享摄像机",
                roomName: "门口",
                kindTag: .camera
            ),
        ]
        let haMock = MockHomeProvider(snapshot: haMultiHome)
        let clock = TestClock()
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)

        await waitUntil {
            let sharedCamBackend = await collector.backend(forCard: Self.haID)
            let sharedPlugBackend = await collector.backend(forCard: sharedPlugDID)
            let exclusiveBackend = await collector.backend(forCard: exclusiveHAID)
            let acc1Connected = await collector.accountIsConnected(account1.id)
            let acc2Connected = await collector.accountIsConnected(account2.id)
            return sharedCamBackend == .xiaomiCloud
                && sharedPlugBackend == .xiaomiCloud
                && exclusiveBackend == .xiaomiCloud
                && acc1Connected
                && acc2Connected
        }

        let initialHome = try #require(await collector.latestHome)
        let initialSharedCam = try #require(initialHome.devices.first { $0.id == Self.haID })
        let initialSharedPlug = try #require(initialHome.devices.first { $0.id == sharedPlugDID })
        let initialExclusiveCam = try #require(initialHome.devices.first { $0.id == exclusiveHAID })
        #expect(initialSharedCam.accountId == account1.id)
        #expect(initialSharedPlug.accountId == account1.id)
        #expect(initialExclusiveCam.accountId == account1.id)

        _ = try await provider.resolveCameraStream(for: initialSharedCam)
        _ = try await provider.resolveCameraStream(for: initialExclusiveCam)
        #expect(await bridge.startCalls.count == 2)

        await collector.clearSnapshots()
        await api1.setSetPropsFailure(.sessionExpired)
        try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))

        await waitUntil { await collector.expiredSessions.count == 1 }
        await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: exclusiveHAID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await bridge.stopCalls == [exclusiveCamDID] }
        await waitUntil(timeout: .seconds(2)) {
            await collector.latestHome?.devices.first { $0.id == Self.haID }?.accountId == account2.id
        }

        let postExpiryFrames = await collector.snapshots
        #expect(!postExpiryFrames.isEmpty)
        for frame in postExpiryFrames {
            #expect(frame.deviceBackends[Self.haID] == .xiaomiCloud)
            #expect(frame.devices.contains { $0.id == Self.haID })
            let plugInFrame = frame.devices.first { $0.id == sharedPlugDID }
            #expect(plugInFrame != nil)
            #expect(plugInFrame?.isOnline == true)
            #expect(plugInFrame?.telemetryStale == false)
            #expect(frame.deviceBackends[sharedPlugDID] == .xiaomiCloud)
        }
        let stoppedAfterExpiry = await bridge.stopCalls
        #expect(!stoppedAfterExpiry.contains(Self.did))
        #expect(stoppedAfterExpiry == [exclusiveCamDID])
        #expect(gate.parkCount == 0)

        let promotedHome = try #require(await collector.latestHome)
        #expect(promotedHome.expiredAccountIDs == [account1.id])
        let promotedCam = try #require(promotedHome.devices.first { $0.id == Self.haID })
        let promotedPlug = try #require(promotedHome.devices.first { $0.id == sharedPlugDID })
        #expect(promotedCam.accountId == account2.id)
        #expect(promotedCam.accountLabel == account2.maskedUserId)
        #expect(promotedPlug.accountId == account2.id)
        #expect(promotedPlug.accountLabel == account2.maskedUserId)
        #expect(promotedHome.rooms.contains { $0.id == promotedPlug.roomId })

        // 2. Follow-up poll `.sessionExpired` path (`MiCloudProvider.followUpPoll` emits ONLY
        // `.sessionExpired(session1)` via `latchRejection` without `.statusChanged(.disconnected)`):
        // MiAccountsProvider must still publish the promoted snapshot ahead of `.sessionExpired`.
        let followUpAPI1 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(
                    did: Self.did,
                    name: "门口",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.45"
                ),
                MiDeviceRecord(
                    did: sharedPlugDID,
                    name: "共享插座",
                    model: "cuco.plug.v3",
                    isOnline: true
                ),
            ],
            rooms: [MiRoom(id: "r1", name: "门口", dids: [Self.did, sharedPlugDID], homeId: "h1", homeName: "主家庭")],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: sharedPlugDID, siid: 2, piid: 1): .bool(true),
            ]
        )
        let followUpAPI2 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(
                    did: Self.did,
                    name: "门口",
                    model: "chuangmi.camera.061a01",
                    isOnline: true,
                    localIp: "192.0.2.45"
                ),
                MiDeviceRecord(
                    did: sharedPlugDID,
                    name: "共享插座",
                    model: "cuco.plug.v3",
                    isOnline: true
                ),
            ],
            rooms: [MiRoom(id: "r2", name: "门口", dids: [Self.did, sharedPlugDID], homeId: "h2", homeName: "共享家庭")],
            values: [
                MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: sharedPlugDID, siid: 2, piid: 1): .bool(true),
            ]
        )
        let followUpBridge = StubXiaomiCameraBridge()
        let followUpAccounts = MiAccountsProvider(
            accounts: [account1, account2],
            apiFactory: { session in session.userId == session1.userId ? followUpAPI1 : followUpAPI2 },
            specSource: DualSpecSource(camSpec: camSpec, plugSpec: plugSpec),
            cameraBridge: followUpBridge,
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let followUpHAMock = MockHomeProvider(snapshot: home([haSharedDoorCam], identityID: Self.haID))
        let followUpGate = GraceTimerGate()
        let followUpDual = DualSourceHomeProvider(
            homeAssistant: followUpHAMock,
            xiaomiCloud: followUpAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: followUpGate
        )
        let followUpCollector = RouteCollector()
        let followUpPump = Task {
            for await event in followUpDual.events() {
                await followUpCollector.append(event)
            }
        }
        track(teardown, provider: followUpDual, gate: followUpGate, pump: followUpPump)

        await waitUntil {
            let camBackend = await followUpCollector.backend(forCard: Self.haID)
            let plugBackend = await followUpCollector.backend(forCard: sharedPlugDID)
            let acc1Connected = await followUpCollector.accountIsConnected(account1.id)
            let acc2Connected = await followUpCollector.accountIsConnected(account2.id)
            return camBackend == .xiaomiCloud
                && plugBackend == .xiaomiCloud
                && acc1Connected
                && acc2Connected
        }
        let followUpDoorCard = try #require(
            await followUpCollector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await followUpDual.resolveCameraStream(for: followUpDoorCard)
        #expect(await followUpBridge.startCalls.map(\.did) == [Self.did])

        await followUpCollector.clearSnapshots()
        await followUpAPI1.setGetPropsFailure(.sessionExpired)
        try await followUpDual.execute(.setSwitch(entityId: "miot:\(sharedPlugDID):2", isOn: false))
        await waitUntil { await followUpCollector.expiredSessions.count == 1 }
        await waitUntil(timeout: .seconds(2)) {
            await followUpCollector.latestHome?.devices.first { $0.id == Self.haID }?.accountId == account2.id
        }

        let followUpFrames = await followUpCollector.snapshots
        #expect(!followUpFrames.isEmpty)
        for frame in followUpFrames {
            #expect(frame.deviceBackends[Self.haID] == .xiaomiCloud)
            let plugInFrame = frame.devices.first { $0.id == sharedPlugDID }
            #expect(plugInFrame != nil)
            #expect(plugInFrame?.isOnline == true)
            #expect(plugInFrame?.telemetryStale == false)
        }
        #expect(await followUpBridge.stopCalls.isEmpty)
        #expect(followUpGate.parkCount == 0)

        // 3. Direct DualSourceHomeProvider defense: even if `.sessionExpired(session1)` arrives on a
        // multi-account snapshot before a re-synthesized snapshot is published, `deviceAccountIDs`
        // promotes the surviving co-owner in-place instead of dropping shared devices; once the last
        // surviving co-owner also expires, failover to HA happens immediately.
        var directSharedCam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        directSharedCam.roomId = MiAccountScope.id("door", account: account1.id)
        directSharedCam.accountId = account1.id
        directSharedCam.accountLabel = account1.maskedUserId
        let directSharedPlug = SmartDevice(
            id: sharedPlugDID,
            name: "共享插座",
            roomId: MiAccountScope.id("balcony", account: account1.id),
            roomName: "阳台",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:\(sharedPlugDID):2", isOn: true)),
            accountId: account1.id,
            accountLabel: account1.maskedUserId
        )
        var directMiHome = home([directSharedCam, directSharedPlug], identityID: Self.did)
        directMiHome.rooms = [
            RoomArea(id: MiAccountScope.id("door", account: account1.id), name: "门口"),
            RoomArea(id: MiAccountScope.id("balcony", account: account1.id), name: "阳台"),
            RoomArea(id: MiAccountScope.id("door-shared", account: account2.id), name: "门口"),
            RoomArea(id: MiAccountScope.id("balcony-shared", account: account2.id), name: "阳台"),
        ]
        directMiHome.homes = [
            HomeOption(
                id: MiAccountScope.id("h1", account: account1.id),
                name: "主家庭",
                deviceCount: 2,
                accountId: account1.id,
                accountLabel: account1.maskedUserId
            ),
            HomeOption(
                id: MiAccountScope.id("h2", account: account2.id),
                name: "共享家庭",
                deviceCount: 2,
                accountId: account2.id,
                accountLabel: account2.maskedUserId
            ),
        ]
        directMiHome.accountStatuses = [account1.id: .connected, account2.id: .connected]
        directMiHome.deviceAccountIDs = [
            Self.did: [account1.id, account2.id],
            sharedPlugDID: [account1.id, account2.id],
        ]
        let directHAMock = MockHomeProvider(snapshot: home([haSharedDoorCam], identityID: Self.haID))
        let directMiMock = MockHomeProvider(snapshot: directMiHome)
        let directGate = GraceTimerGate()
        let directDual = DualSourceHomeProvider(
            homeAssistant: directHAMock,
            xiaomiCloud: directMiMock,
            graceNow: { clock.now },
            fallbackRecheckTimer: directGate
        )
        let directCollector = RouteCollector()
        let directPump = Task {
            for await event in directDual.events() {
                await directCollector.append(event)
            }
        }
        track(teardown, provider: directDual, gate: directGate, pump: directPump)

        await waitUntil {
            let camBackend = await directCollector.backend(forCard: Self.haID)
            let plugBackend = await directCollector.backend(forCard: sharedPlugDID)
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        let directDoorCard = try #require(
            await directCollector.latestHome?.devices.first { $0.id == Self.haID }
        )
        _ = try await directDual.resolveCameraStream(for: directDoorCard)

        await directCollector.clearSnapshots()
        await directMiMock.sendSessionExpired(session1)
        await waitUntil { await directCollector.expiredSessions.count == 1 }

        let directFramesAfterFirstExpiry = await directCollector.snapshots
        #expect(!directFramesAfterFirstExpiry.isEmpty)
        for frame in directFramesAfterFirstExpiry {
            #expect(frame.deviceBackends[Self.haID] == .xiaomiCloud)
            let camInFrame = frame.devices.first { $0.id == Self.haID }
            #expect(camInFrame?.accountId == account2.id)
            #expect(camInFrame?.accountLabel == account2.maskedUserId)
            let plugInFrame = frame.devices.first { $0.id == sharedPlugDID }
            #expect(plugInFrame != nil)
            #expect(plugInFrame?.accountId == account2.id)
            #expect(plugInFrame?.accountLabel == account2.maskedUserId)
            #expect(plugInFrame?.roomId == MiAccountScope.id("balcony-shared", account: account2.id))
            #expect(frame.rooms.contains { $0.id == MiAccountScope.id("balcony-shared", account: account2.id) })
            #expect(!frame.rooms.contains { $0.id == MiAccountScope.id("balcony", account: account1.id) })
        }
        #expect(await directMiMock.stoppedCameraIDs.isEmpty)
        #expect(directGate.parkCount == 0)

        await directMiMock.sendSessionExpired(session2)
        await waitUntil { await directCollector.expiredSessions.count == 2 }
        await waitUntil(timeout: .seconds(2)) { await directCollector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await directMiMock.stoppedCameraIDs == [Self.did] }
        #expect(await directCollector.latestHome?.devices.contains { $0.id == sharedPlugDID } == false)
    }

    @Test("Single-account sessionExpired keeps cached devices stripped across premature connecting/connected statuses and stale snapshots until a fresh post-relogin snapshot arrives")
    func singleAccountSessionExpiredWaitsForFreshPostReloginSnapshot() async throws {
        try await withTeardown { teardown in
            try await singleAccountSessionExpiredWaitsForFreshPostReloginSnapshotBody(teardown)
        }
    }

    private func singleAccountSessionExpiredWaitsForFreshPostReloginSnapshotBody(_ teardown: Teardown) async throws {
        let cameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:3","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let camSpec = MiotFixtures.decode(cameraSpecJSON)
        struct CameraOnlySpecSource: MiotSpecSource {
            let camSpec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                model == "chuangmi.camera.061a01" ? camSpec : nil
            }
        }

        let session1 = MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn-old", region: "cn"
        )
        let rescannedSession1 = MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1-new", serviceToken: "tok-cn-new", region: "cn"
        )
        let account1 = MiAccount(session: session1)

        // 1. Deterministic interleaving: HA's paired camera is offline + streamless and pinned to
        // `.xiaomiCloud`, so any premature recovery would immediately hand routing back to the
        // cached Xiaomi device from the rejected session.
        var offlineHADoorCam = camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)
        offlineHADoorCam.isOnline = false
        let haHome = home([offlineHADoorCam], identityID: Self.haID)
        let miPlug = SmartDevice(
            id: "mi-plug-1",
            name: "客厅插座",
            roomId: "door",
            roomName: "门口",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:mi-plug-1:2", isOn: true))
        )
        let miCam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        let initialMiHome = home([miCam, miPlug], identityID: Self.did)
        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: initialMiHome)
        let clock = TestClock()
        let gate = GraceTimerGate()
        let dual = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miMock,
            pinnedBackends: { [Self.haID: .xiaomiCloud] },
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let collector = RouteCollector()
        let pump = Task {
            for await event in dual.events() {
                await collector.append(event)
            }
        }
        track(teardown, provider: dual, gate: gate, pump: pump)

        await waitUntil {
            let camBackend = await collector.backend(forCard: Self.haID)
            let plugBackend = await collector.backend(forCard: "mi-plug-1")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        let liveCard = try #require(await collector.latestHome?.devices.first { $0.id == Self.haID })
        _ = try await dual.resolveCameraStream(for: liveCard)
        #expect(await miMock.stoppedCameraIDs.isEmpty)

        await miMock.sendSessionExpired(session1)
        await waitUntil { await collector.expiredSessions.count == 1 }
        await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await miMock.stoppedCameraIDs == [Self.did] }
        #expect(await collector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await collector.latestHome?.devices.contains { $0.id == "mi-plug-1" } == false)
        #expect(await collector.sourceIsDisconnected(.xiaomiCloud))

        // Child emits `.statusChanged(.connecting)` before a fresh snapshot: Xiaomi shows connecting,
        // while `miExpiredAccountIDs` remains active and cached rejected devices stay stripped.
        await miMock.sendStatus(.connecting)
        await waitUntil(timeout: .seconds(2)) {
            if case .connecting = await collector.latestSourceStatuses[.xiaomiCloud] ?? .disconnected("") {
                return true
            }
            return false
        }
        #expect(await collector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await collector.latestHome?.devices.contains { $0.id == "mi-plug-1" } == false)
        #expect(await miMock.stoppedCameraIDs == [Self.did])

        // Premature `.statusChanged(.connected)` BEFORE a fresh post-relogin snapshot must neither
        // clear `miExpiredAccountIDs` nor mark Xiaomi `.connected`.
        let beforePrematureConnected = await collector.snapshotCount
        await miMock.sendStatus(.connected)
        await waitUntil(timeout: .seconds(2)) { await collector.snapshotCount > beforePrematureConnected }
        #expect(await collector.sourceIsConnected(.xiaomiCloud) == false)
        #expect(await collector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await collector.latestHome?.devices.contains { $0.id == "mi-plug-1" } == false)
        #expect(await miMock.stoppedCameraIDs == [Self.did])

        // Stale/partial snapshot (`closesAwayGap == false`) after `.connecting` also cannot revive
        // cached devices from the rejected session.
        var stalePartialMiHome = initialMiHome
        stalePartialMiHome.closesAwayGap = false
        let beforeStaleSnapshot = await collector.snapshotCount
        await miMock.updateSnapshot(stalePartialMiHome)
        await waitUntil(timeout: .seconds(2)) { await collector.snapshotCount > beforeStaleSnapshot }
        #expect(await collector.sourceIsConnected(.xiaomiCloud) == false)
        #expect(await collector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await collector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await collector.latestHome?.devices.contains { $0.id == "mi-plug-1" } == false)

        // Fresh post-relogin full-poll snapshot (`closesAwayGap == true`, `expiredAccountIDs == []`)
        // cleanly clears `miExpiredAccountIDs`, marks Xiaomi `.connected`, and reclaims routing.
        var freshPostReloginHome = initialMiHome
        freshPostReloginHome.closesAwayGap = true
        freshPostReloginHome.expiredAccountIDs = []
        await miMock.updateSnapshot(freshPostReloginHome)
        await waitUntil(timeout: .seconds(2)) {
            let camBackend = await collector.backend(forCard: Self.haID)
            let plugBackend = await collector.backend(forCard: "mi-plug-1")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }
        #expect(await collector.sourceIsConnected(.xiaomiCloud))
        #expect(await collector.latestHome?.expiredAccountIDs.isEmpty == true)

        // 2. End-to-end single-session `MiCloudProvider` (`account == nil`): rejected session stamps
        // `expiredAccountIDs` on snapshots, holds HA routing across `.connecting` during re-login
        // poll, and recovers once the rescanned credential's full poll finishes.
        final class SessionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: MiSession
            init(_ session: MiSession) { value = session }
            func get() -> MiSession { lock.withLock { value } }
            func set(_ next: MiSession) { lock.withLock { value = next } }
        }
        let sessionBox = SessionBox(session1)
        let oldAPI = StubMiCloudAPI(
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
        let rescannedAPI = StubMiCloudAPI(
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
        let (pollReleaseStream, pollReleaseCont) = AsyncStream<Void>.makeStream()
        let (enteredPollStream, enteredPollCont) = AsyncStream<Void>.makeStream()
        await rescannedAPI.setGetPropsHook {
            enteredPollCont.yield(())
            var iter = pollReleaseStream.makeAsyncIterator()
            _ = await iter.next()
        }
        let bridge = StubXiaomiCameraBridge()
        let singleMi = MiCloudProvider(
            sessionLoader: { sessionBox.get() },
            apiFactory: { $0.serviceToken == rescannedSession1.serviceToken ? rescannedAPI : oldAPI },
            specSource: CameraOnlySpecSource(camSpec: camSpec),
            cameraBridge: bridge,
            localClient: nil,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil }
        )
        let e2eHAMock = MockHomeProvider(snapshot: haHome)
        let e2eDual = DualSourceHomeProvider(
            homeAssistant: e2eHAMock,
            xiaomiCloud: singleMi,
            pinnedBackends: { [Self.haID: .xiaomiCloud] },
            graceNow: { clock.now },
            fallbackRecheckTimer: gate
        )
        let e2eCollector = RouteCollector()
        let e2ePump = Task {
            for await event in e2eDual.events() {
                await e2eCollector.append(event)
            }
        }
        teardown.addFinish {
            pollReleaseCont.finish()
            enteredPollCont.finish()
        }
        track(teardown, provider: e2eDual, gate: gate, pump: e2ePump)

        await waitUntil { await e2eCollector.backend(forCard: Self.haID) == .xiaomiCloud }
        let e2eInitialCard = try #require(await e2eCollector.latestHome?.devices.first { $0.id == Self.haID })
        _ = try await e2eDual.resolveCameraStream(for: e2eInitialCard)
        #expect(await bridge.startCalls.count == 1)

        await oldAPI.setSetPropsFailure(.sessionExpired)
        await #expect(throws: MiCloudError.sessionExpired) {
            try await e2eDual.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
        }
        await waitUntil(timeout: .seconds(2)) { await e2eCollector.backend(forCard: Self.haID) == .homeAssistant }
        await waitUntil(timeout: .seconds(2)) { await bridge.stopCalls == [Self.did] }

        // User scans a fresh token for the same account; while the post-relogin poll is in flight
        // (`.connecting`), cached devices from the rejected session stay stripped.
        sessionBox.set(rescannedSession1)
        let refreshTask = Task { await e2eDual.refreshNow() }
        var enteredIter = enteredPollStream.makeAsyncIterator()
        _ = await enteredIter.next()
        await waitUntil(timeout: .seconds(2)) {
            if case .connecting = await e2eCollector.latestSourceStatuses[.xiaomiCloud] ?? .disconnected("") {
                return true
            }
            return false
        }
        #expect(await e2eCollector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await e2eCollector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(await bridge.stopCalls == [Self.did])

        await rescannedAPI.setGetPropsHook(nil)
        pollReleaseCont.yield(())
        pollReleaseCont.finish()
        await refreshTask.value

        await waitUntil(timeout: .seconds(2)) { await e2eCollector.backend(forCard: Self.haID) == .xiaomiCloud }
        #expect(await e2eCollector.sourceIsConnected(.xiaomiCloud))
        #expect(await e2eCollector.latestHome?.expiredAccountIDs.isEmpty == true)
    }

    @Test("Multi-account sessionExpired re-login immediately surfaces connecting and clears miExpiredAccountIDs without waiting for connected")
    func multiAccountReloginSurfacesConnectingAndClearsExpiredImmediately() async throws {
        try await withTeardown { teardown in
            try await multiAccountReloginSurfacesConnectingAndClearsExpiredImmediatelyBody(teardown)
        }
    }

    private func multiAccountReloginSurfacesConnectingAndClearsExpiredImmediatelyBody(_ teardown: Teardown) async throws {
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
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn-old", region: "cn"
        )
        let refreshedSession1 = MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1-new", serviceToken: "tok-cn-new", region: "cn"
        )
        let session2 = MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-2", serviceToken: "tok-de", region: "de"
        )
        let account1 = MiAccount(session: session1)
        let refreshedAccount1 = MiAccount(session: refreshedSession1)
        let account2 = MiAccount(session: session2)

        // 1. Direct multi-account snapshot check: a stale snapshot still carrying
        // `expiredAccountIDs: [account1.id]` stays demoted to `expiredStatus`, whereas a post-relogin
        // `.connecting` snapshot with `expiredAccountIDs == []` immediately surfaces `.connecting`,
        // clears `account1.id` from `miExpiredAccountIDs`, and lets any fresh device from `account1`
        // participate without waiting for `.connected`.
        var acc1Cam = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
        acc1Cam.accountId = account1.id
        acc1Cam.roomId = MiAccountScope.id("door", account: account1.id)
        let acc2Plug = SmartDevice(
            id: "de-plug-1",
            name: "书房插座",
            roomId: MiAccountScope.id("r2", account: account2.id),
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-1:2", isOn: true)),
            accountId: account2.id
        )
        var initialMultiHome = home([acc1Cam, acc2Plug], identityID: Self.did)
        initialMultiHome.accountStatuses = [account1.id: .connected, account2.id: .connected]
        let haHome = home(
            [camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)],
            identityID: Self.haID
        )
        let clock = TestClock()
        let directGate = GraceTimerGate()
        let directHAMock = MockHomeProvider(snapshot: haHome)
        let directMiMock = MockHomeProvider(snapshot: initialMultiHome)
        let directDual = DualSourceHomeProvider(
            homeAssistant: directHAMock,
            xiaomiCloud: directMiMock,
            graceNow: { clock.now },
            fallbackRecheckTimer: directGate
        )
        let directCollector = RouteCollector()
        let directPump = Task {
            for await event in directDual.events() {
                await directCollector.append(event)
            }
        }
        track(teardown, provider: directDual, gate: directGate, pump: directPump)

        await waitUntil { await directCollector.backend(forCard: Self.haID) == .xiaomiCloud }
        await directMiMock.sendSessionExpired(session1)
        await waitUntil(timeout: .seconds(2)) { await directCollector.backend(forCard: Self.haID) == .homeAssistant }
        #expect(await directCollector.accountIsDisconnected(account1.id))
        #expect(await directCollector.latestHome?.expiredAccountIDs == [account1.id])

        // Stale snapshot still marked expired keeps `account1` demoted and in `expiredAccountIDs`.
        var staleExpiredConnecting = initialMultiHome
        staleExpiredConnecting.accountStatuses = [account1.id: .connecting, account2.id: .connected]
        staleExpiredConnecting.expiredAccountIDs = [account1.id]
        let beforeStaleMulti = await directCollector.snapshotCount
        await directMiMock.updateSnapshot(staleExpiredConnecting)
        await waitUntil(timeout: .seconds(2)) { await directCollector.snapshotCount > beforeStaleMulti }
        #expect(await directCollector.accountIsDisconnected(account1.id))
        #expect(await directCollector.latestHome?.expiredAccountIDs == [account1.id])
        #expect(await directCollector.backend(forCard: Self.haID) == .homeAssistant)

        // Post-relogin `.connecting` snapshot (`expiredAccountIDs == []`) immediately clears
        // `account1.id` from `miExpiredAccountIDs` and surfaces `.connecting`.
        var reloginConnectingSnapshot = home([acc2Plug], identityID: Self.did)
        reloginConnectingSnapshot.deviceIdentities = [:]
        reloginConnectingSnapshot.accountStatuses = [account1.id: .connecting, account2.id: .connected]
        reloginConnectingSnapshot.expiredAccountIDs = []
        await directMiMock.updateSnapshot(reloginConnectingSnapshot)
        await waitUntil(timeout: .seconds(2)) {
            await directCollector.latestHome?.accountStatuses[account1.id] == .connecting
        }
        #expect(await directCollector.latestHome?.expiredAccountIDs.isEmpty == true)
        #expect(await directCollector.backend(forCard: Self.haID) == .homeAssistant)
        #expect(directGate.parkCount == 0)

        // 2. Real `MiAccountsProvider.updateAccounts` flow: while `refreshedAccount1`'s first poll
        // is parked in `.connecting`, `accountStatuses[account1.id]` immediately surfaces `.connecting`
        // and `expiredAccountIDs` clears `account1.id` before `.connected` arrives.
        let api1Old = StubMiCloudAPI(
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
        let api1Refreshed = StubMiCloudAPI(
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
        let (reloginGateStream, reloginGateCont) = AsyncStream<Void>.makeStream()
        let (reloginEnteredStream, reloginEnteredCont) = AsyncStream<Void>.makeStream()
        await api1Refreshed.setGetPropsHook {
            reloginEnteredCont.yield(())
            var iter = reloginGateStream.makeAsyncIterator()
            _ = await iter.next()
        }
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
        let miAccounts = MiAccountsProvider(
            accounts: [account1, account2],
            apiFactory: { session in
                if session.userId == session2.userId { return api2 }
                return session.serviceToken == refreshedSession1.serviceToken ? api1Refreshed : api1Old
            },
            specSource: DualSpecSource(camSpec: camSpec, plugSpec: plugSpec),
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let e2eHAMock = MockHomeProvider(snapshot: haHome)
        let e2eGate = GraceTimerGate()
        let e2eDual = DualSourceHomeProvider(
            homeAssistant: e2eHAMock,
            xiaomiCloud: miAccounts,
            graceNow: { clock.now },
            fallbackRecheckTimer: e2eGate
        )
        let e2eCollector = RouteCollector()
        let e2ePump = Task {
            for await event in e2eDual.events() {
                await e2eCollector.append(event)
            }
        }
        teardown.addFinish {
            reloginGateCont.finish()
            reloginEnteredCont.finish()
        }
        track(teardown, provider: e2eDual, gate: e2eGate, pump: e2ePump)

        await waitUntil {
            let camBackend = await e2eCollector.backend(forCard: Self.haID)
            let plugBackend = await e2eCollector.backend(forCard: "de-plug-1")
            return camBackend == .xiaomiCloud && plugBackend == .xiaomiCloud
        }

        await api1Old.setSetPropsFailure(.sessionExpired)
        await #expect(throws: MiCloudError.sessionExpired) {
            try await e2eDual.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
        }
        await waitUntil(timeout: .seconds(2)) { await e2eCollector.backend(forCard: Self.haID) == .homeAssistant }
        #expect(await e2eCollector.accountIsDisconnected(account1.id))
        #expect(await e2eCollector.latestHome?.expiredAccountIDs == [account1.id])

        await miAccounts.updateAccounts([refreshedAccount1, account2])
        var enteredIter = reloginEnteredStream.makeAsyncIterator()
        _ = await enteredIter.next()
        await waitUntil(timeout: .seconds(2)) {
            await e2eCollector.latestHome?.accountStatuses[account1.id] == .connecting
        }
        #expect(await e2eCollector.latestHome?.expiredAccountIDs.contains(account1.id) == false)
        #expect(await e2eCollector.latestHome?.expiredAccountIDs.isEmpty == true)
        #expect(await e2eCollector.accountIsConnected(account2.id))
        #expect(await e2eCollector.backend(forCard: "de-plug-1") == .xiaomiCloud)
        #expect(e2eGate.parkCount == 0)

        await api1Refreshed.setGetPropsHook(nil)
        reloginGateCont.yield(())
        reloginGateCont.finish()

        await waitUntil(timeout: .seconds(2)) {
            let connected = await e2eCollector.accountIsConnected(account1.id)
            let backend = await e2eCollector.backend(forCard: Self.haID)
            return connected && backend == .xiaomiCloud
        }
    }

    @Test("DispatchFallbackRecheckTimer re-arms in place, suppresses cancelled deadlines, and stays silent after invalidate")
    func dispatchFallbackRecheckTimerRearmsCancelsAndInvalidatesCleanly() async throws {
        final class TagLog: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [String] = []

            func record(_ tag: String) {
                lock.withLock { stored.append(tag) }
            }

            var tags: [String] { lock.withLock { stored } }
        }

        func drain(_ queue: DispatchQueue) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async { cont.resume() }
            }
        }

        func whileHolding(_ queue: DispatchQueue, _ body: () -> Void) async {
            let release = DispatchSemaphore(value: 0)
            await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
                queue.async {
                    entered.resume()
                    release.wait()
                }
            }
            defer { release.signal() }
            body()
        }

        let queue = DispatchQueue(label: "test.DispatchFallbackRecheckTimer")
        let timer = DispatchFallbackRecheckTimer(queue: queue)
        defer { timer.invalidate() }
        let log = TagLog()

        // 1. Both an already-armed timer and a queued schedule stay silent after cancelPending;
        //    a later schedule fires once.
        timer.schedule(after: .seconds(60)) { log.record("armed-cancelled") }
        await drain(queue)
        timer.cancelPending()
        await drain(queue)

        await whileHolding(queue) {
            timer.schedule(after: .zero) { log.record("queued-cancelled") }
            timer.cancelPending()
            timer.schedule(after: .milliseconds(5)) { log.record("after-cancel") }
        }
        await waitUntil(timeout: .seconds(5)) { log.tags.contains("after-cancel") }
        await drain(queue)
        #expect(log.tags == ["after-cancel"])

        // 2. High-frequency re-arming with the timer queue held cannot be preempted mid-burst and
        //    fires only the latest callback once released.
        await whileHolding(queue) {
            for index in 0..<200 {
                timer.schedule(after: .zero) { log.record("stale-\(index)") }
            }
            timer.schedule(after: .milliseconds(5)) { log.record("latest") }
        }
        await waitUntil(timeout: .seconds(5)) { log.tags.contains("latest") }
        await drain(queue)
        #expect(log.tags == ["after-cancel", "latest"])

        // 3. Invalidate permanently disarms pending and future schedules.
        await whileHolding(queue) {
            timer.schedule(after: .zero) { log.record("before-invalidate") }
            timer.invalidate()
            timer.schedule(after: .zero) { log.record("after-invalidate") }
        }
        await drain(queue)
        let probe = DispatchFallbackRecheckTimer(queue: queue)
        defer { probe.invalidate() }
        probe.schedule(after: .milliseconds(10)) { log.record("probe") }
        await waitUntil(timeout: .seconds(5)) { log.tags.contains("probe") }
        await drain(queue)
        #expect(log.tags == ["after-cancel", "latest", "probe"])
    }

    @Test("A late fallback wake arriving after shutdown is discarded without recomputing")
    func shutdownDiscardsLateFallbackWake() async throws {
        try await withTeardown { teardown in
            let haHome = home(
                [camera(id: Self.haID, entity: "switch.door_cam_power", stream: "camera.door_stream")],
                identityID: Self.haID
            )
            let miHome = home(
                [camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")],
                identityID: Self.did
            )
            let haMock = MockHomeProvider(snapshot: haHome)
            let miMock = MockHomeProvider(snapshot: miHome)
            let clock = TestClock()
            final class CapturingTimer: FallbackRecheckTimer, @unchecked Sendable {
                private let lock = NSLock()
                private var storedCallback: (@Sendable () -> Void)?
                private var storedInvalidated = false
                var hasCallback: Bool { lock.withLock { storedCallback != nil } }
                var wasInvalidated: Bool { lock.withLock { storedInvalidated } }
                func schedule(after delay: Duration, onFire: @escaping @Sendable () -> Void) {
                    lock.withLock { storedCallback = onFire }
                }
                func cancelPending() {
                    lock.withLock { storedCallback = nil }
                }
                func invalidate() {
                    lock.withLock { storedInvalidated = true }
                }
                func fireRetainedCallback() {
                    let cb = lock.withLock { storedCallback }
                    cb?()
                }
            }
            let timer = CapturingTimer()
            let provider = DualSourceHomeProvider(
                homeAssistant: haMock,
                xiaomiCloud: miMock,
                graceNow: { clock.now },
                fallbackRecheckTimer: timer
            )
            let collector = RouteCollector()
            let pump = Task {
                for await event in provider.events() {
                    await collector.append(event)
                }
            }
            teardown.add {
                await provider.shutdown()
                pump.cancel()
                await pump.value
            }

            await waitUntil { await collector.backend(forCard: Self.haID) == .homeAssistant }
            await haMock.sendStatus(.disconnected("blip"))
            await waitUntil {
                let disconnected = await collector.sourceIsDisconnected(.homeAssistant)
                return disconnected && timer.hasCallback
            }

            let snapshotsBeforeShutdown = await collector.snapshotCount
            await provider.shutdown()
            #expect(timer.wasInvalidated)

            // Simulate a timer callback that was already in flight right as shutdown ran.
            timer.fireRetainedCallback()
            await waitUntil { await provider.discardedFallbackWakeCountForTesting == 1 }
            #expect(await collector.snapshotCount == snapshotsBeforeShutdown)
            #expect(await provider.isShutDownForTesting)
        }
    }

    @Test("Graced display account keeps live stream alive while writes route only to enabled online writable sessions")
    func gracedDisplayAccountSeparatesFromWriteRouting() async throws {
        try await withTeardown { teardown in
            try await gracedDisplayAccountSeparatesFromWriteRoutingBody(teardown)
        }
    }

    private func gracedDisplayAccountSeparatesFromWriteRoutingBody(_ teardown: Teardown) async throws {
        let writableCameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:writable","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let viewOnlyCameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:readonly","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","notify"]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
        let writableSpec = MiotFixtures.decode(writableCameraSpecJSON)
        let viewOnlySpec = MiotFixtures.decode(viewOnlyCameraSpecJSON)
        struct PermissionedCameraSpecSource: MiotSpecSource {
            let writableSpec: MiotDeviceSpec
            let viewOnlySpec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                guard model == "chuangmi.camera.061a01" else { return nil }
                return specType == viewOnlySpec.type ? viewOnlySpec : writableSpec
            }
        }
        let specSource = PermissionedCameraSpecSource(writableSpec: writableSpec, viewOnlySpec: viewOnlySpec)

        // 1. Account A (streaming owner) drops into grace while co-owner B stays connected but
        // reports the camera offline (and in part 2, online with read-only permissions): live
        // stream grace holds on Xiaomi, yet writes must not hit disconnected A or non-writable B
        // and must fail with `.noWritableSession`.
        let accountA = MiAccount(session: MiSession(
            userId: "10020011", cUserId: "c-a1", ssecurity: "ssec-a1", serviceToken: "tok-a1", region: "cn"
        ))
        let accountB = MiAccount(session: MiSession(
            userId: "10020022", cUserId: "c-b1", ssecurity: "ssec-b1", serviceToken: "tok-b1", region: "cn"
        ))
        let apiA = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                specType: writableSpec.type,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rA", name: "门口", dids: [Self.did], homeId: "hA", homeName: "家A")],
            values: [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)]
        )
        let apiBOffline = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: false,
                specType: viewOnlySpec.type,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rB", name: "门口", dids: [Self.did], homeId: "hB", homeName: "家B")],
            values: [:]
        )
        let bridge1 = StubXiaomiCameraBridge()
        let miAccounts1 = MiAccountsProvider(
            accounts: [accountA, accountB],
            apiFactory: { session in session.userId == accountA.session.userId ? apiA : apiBOffline },
            specSource: specSource,
            cameraBridge: bridge1,
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
        let haMock1 = MockHomeProvider(snapshot: haHome)
        let clock1 = TestClock()
        let gate1 = GraceTimerGate()
        let provider1 = DualSourceHomeProvider(
            homeAssistant: haMock1,
            xiaomiCloud: miAccounts1,
            graceNow: { clock1.now },
            fallbackRecheckTimer: gate1
        )
        let collector1 = RouteCollector()
        let pump1 = Task {
            for await event in provider1.events() {
                await collector1.append(event)
            }
        }
        track(teardown, provider: provider1, gate: gate1, pump: pump1)

        await waitUntil {
            let backend = await collector1.backend(forCard: Self.haID)
            let aConnected = await collector1.accountIsConnected(accountA.id)
            let bConnected = await collector1.accountIsConnected(accountB.id)
            return backend == .xiaomiCloud && aConnected && bConnected
        }
        let card1 = try #require(await collector1.latestHome?.devices.first { $0.id == Self.haID })
        _ = try await provider1.resolveCameraStream(for: card1)
        #expect(await bridge1.startCalls.count == 1)

        await apiA.setGetPropsFailure(.http(502))
        await miAccounts1.refreshNow()
        await waitUntil {
            let aDisconnected = await collector1.accountIsDisconnected(accountA.id)
            let bConnected = await collector1.accountIsConnected(accountB.id)
            return aDisconnected && bConnected && gate1.waiting == 1
        }
        #expect(await collector1.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge1.stopCalls.isEmpty, "Live stream grace must remain active while A is transiently dropped")

        await #expect(throws: MiotCommandError.noWritableSession(Self.did)) {
            try await provider1.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
        }
        #expect(await apiA.setPropsCalls.isEmpty, "Disconnected graced owner A must not receive writes")
        #expect(await apiBOffline.setPropsCalls.isEmpty, "Offline co-owner B must not receive writes")

        // 2. Account A drops into grace, co-owner B is online with view-only spec (cannot write),
        // and co-owner C is online and writable: writes must route exclusively to C (never A or B),
        // then return to A after A recovers.
        let accountC = MiAccount(session: MiSession(
            userId: "10020033", cUserId: "c-c1", ssecurity: "ssec-c1", serviceToken: "tok-c1", region: "cn"
        ))
        let apiA2 = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                specType: writableSpec.type,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rA2", name: "门口", dids: [Self.did], homeId: "hA2", homeName: "家A")],
            values: [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)]
        )
        let apiBViewOnly = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                specType: viewOnlySpec.type,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rB2", name: "门口", dids: [Self.did], homeId: "hB2", homeName: "家B")],
            values: [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)]
        )
        let apiCWritable = StubMiCloudAPI(
            devices: [MiDeviceRecord(
                did: Self.did,
                name: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: true,
                specType: writableSpec.type,
                localIp: "192.0.2.45"
            )],
            rooms: [MiRoom(id: "rC2", name: "门口", dids: [Self.did], homeId: "hC2", homeName: "家C")],
            values: [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)]
        )
        let bridge2 = StubXiaomiCameraBridge()
        let miAccounts2 = MiAccountsProvider(
            accounts: [accountA, accountB, accountC],
            apiFactory: { session in
                switch session.userId {
                case accountA.session.userId: return apiA2
                case accountB.session.userId: return apiBViewOnly
                default: return apiCWritable
                }
            },
            specSource: specSource,
            cameraBridge: bridge2,
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            cameraSessionReleaseDelay: .zero,
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let haMock2 = MockHomeProvider(snapshot: haHome)
        let clock2 = TestClock()
        let gate2 = GraceTimerGate()
        let provider2 = DualSourceHomeProvider(
            homeAssistant: haMock2,
            xiaomiCloud: miAccounts2,
            graceNow: { clock2.now },
            fallbackRecheckTimer: gate2
        )
        let collector2 = RouteCollector()
        let pump2 = Task {
            for await event in provider2.events() {
                await collector2.append(event)
            }
        }
        track(teardown, provider: provider2, gate: gate2, pump: pump2)

        await waitUntil {
            let backend = await collector2.backend(forCard: Self.haID)
            let aConnected = await collector2.accountIsConnected(accountA.id)
            let bConnected = await collector2.accountIsConnected(accountB.id)
            let cConnected = await collector2.accountIsConnected(accountC.id)
            return backend == .xiaomiCloud && aConnected && bConnected && cConnected
        }
        let card2 = try #require(await collector2.latestHome?.devices.first { $0.id == Self.haID })
        _ = try await provider2.resolveCameraStream(for: card2)

        // Drop A into grace while B (online, view-only) and C (online, writable) stay connected.
        await apiA2.setGetPropsFailure(.http(502))
        await miAccounts2.refreshNow()
        await waitUntil {
            let aDisconnected = await collector2.accountIsDisconnected(accountA.id)
            let bConnected = await collector2.accountIsConnected(accountB.id)
            let cConnected = await collector2.accountIsConnected(accountC.id)
            return aDisconnected && bConnected && cConnected
        }
        #expect(await collector2.backend(forCard: Self.haID) == .xiaomiCloud)
        #expect(await bridge2.stopCalls.isEmpty)

        // Write must bypass disconnected A and view-only B and land on writable C.
        try await provider2.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
        #expect(await apiA2.setPropsCalls.isEmpty, "Disconnected owner A must not receive the write")
        #expect(await apiBViewOnly.setPropsCalls.isEmpty, "View-only co-owner B must not receive the write")
        #expect(await apiCWritable.setPropsCalls == [[MiotPropWrite(did: Self.did, siid: 2, piid: 1, value: .bool(false))]])

        // If C is also disabled synchronously, no writable session remains and B still receives nothing.
        miAccounts2.markAccountDisabled(accountC.id)
        await #expect(throws: MiotCommandError.noWritableSession(Self.did)) {
            try await provider2.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: true))
        }
        #expect(await apiA2.setPropsCalls.isEmpty)
        #expect(await apiBViewOnly.setPropsCalls.isEmpty)
        #expect(await apiCWritable.setPropsCalls.count == 1)

        // Once A recovers, writes route back to A.
        await apiA2.setGetPropsFailure(nil)
        await miAccounts2.refreshNow()
        await waitUntil { await collector2.accountIsConnected(accountA.id) }
        try await provider2.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: true))
        #expect(await apiA2.setPropsCalls == [[MiotPropWrite(did: Self.did, siid: 2, piid: 1, value: .bool(true))]])
        #expect(await apiBViewOnly.setPropsCalls.isEmpty)
        #expect(await apiCWritable.setPropsCalls.count == 1)
    }

    @MainActor
    @Test("Signing out or disabling a Xiaomi account during grace revokes its cached copy and never keeps its content on paired cards")
    func revokingOrDisablingMiAccountDuringGraceEvictsCachedCopyAndFailsOverToHA() async throws {
        let accountA = MiAccount(session: MiSession(
            userId: "10030011", cUserId: "c-grace-a", ssecurity: "ssec-a", serviceToken: "tok-a", region: "cn"
        ))
        let accountB = MiAccount(session: MiSession(
            userId: "10030022", cUserId: "c-grace-b", ssecurity: "ssec-b", serviceToken: "tok-b", region: "de"
        ))

        @MainActor
        func runScenario(signOut: Bool) async throws {
            let suite = "com.jryang1997.MenuBarMijia.grace-revoke.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let defaults = try #require(UserDefaults(suiteName: suite))
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            MiSessionStore.saveAccounts([accountA, accountB], defaults: defaults, vault: vault)
            defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
            defaults.set("http://192.168.1.10:8123", forKey: "ha_server_url")
            _ = KeychainHelper.saveToken("test-ha-token", defaults: defaults, vault: vault)

            var camA = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
            camA.name = "A账号门禁摄像机"
            camA.accountId = accountA.id
            camA.accountLabel = accountA.maskedUserId
            camA.roomId = MiAccountScope.id("door", account: accountA.id)
            let plugB = SmartDevice(
                id: "de-plug-grace",
                name: "B账号书房插座",
                roomId: MiAccountScope.id("study", account: accountB.id),
                roomName: "书房",
                model: "cuco.plug.v3",
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-grace:2", isOn: true)),
                accountId: accountB.id,
                accountLabel: accountB.maskedUserId
            )
            var miConnected = home([camA, plugB], identityID: Self.did)
            miConnected.isInitialLoadComplete = true
            miConnected.accountStatuses = [accountA.id: .connected, accountB.id: .connected]
            miConnected.deviceAccountIDs = [Self.did: [accountA.id], "de-plug-grace": [accountB.id]]

            var haCam = camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)
            haCam.name = "HA门口摄像机"
            var haInitial = home([haCam], identityID: Self.haID)
            haInitial.isInitialLoadComplete = true

            let haMock = MockHomeProvider(snapshot: haInitial)
            let miMock = MockHomeProvider(snapshot: miConnected)
            let clock = TestClock()
            let gate = GraceTimerGate()
            let dual = DualSourceHomeProvider(
                homeAssistant: haMock,
                xiaomiCloud: miMock,
                graceNow: { clock.now },
                fallbackRecheckTimer: gate
            )
            let store = HomeStore(provider: dual, defaultsSuiteName: suite, credentialVault: vault)

            @MainActor
            func cleanup() async {
                store.eventTask?.cancel()
                await store.providerShutdownTask?.value
                gate.shutdown()
                await dual.shutdown()
            }

            do {
                await waitUntil {
                    store.deviceBackends[Self.haID] == .xiaomiCloud
                        && store.pairedDeviceIDs.contains(Self.haID)
                        && store.devices.contains(where: { $0.id == "de-plug-grace" })
                }
                let initialCard = try #require(store.devices.first { $0.id == Self.haID })
                #expect(initialCard.accountId == accountA.id)
                _ = try await dual.resolveCameraStream(for: initialCard)

                // Account A drops into grace while B stays connected; paired card stays on A's cached copy.
                var miADropped = miConnected
                miADropped.accountStatuses = [accountA.id: .disconnected("HTTP 502"), accountB.id: .connected]
                var staleCamA = camA
                staleCamA.isOnline = false
                staleCamA.telemetryStale = true
                miADropped.devices = [staleCamA, plugB]
                await miMock.updateSnapshot(miADropped)
                await waitUntil {
                    let disconnected: Bool
                    if case .disconnected = store.miAccountStatuses[accountA.id] ?? .connecting {
                        disconnected = true
                    } else {
                        disconnected = false
                    }
                    return disconnected && gate.waiting == 1
                }
                #expect(store.deviceBackends[Self.haID] == .xiaomiCloud)

                // Sign out or disable A while A is still inside its grace window.
                if signOut {
                    store.logoutMiAccount(id: accountA.id)
                } else {
                    let verdict = store.setMiAccountEnabled(false, id: accountA.id)
                    #expect(verdict.disposition == .allowed)
                }

                // Another source event triggers `recompute()` while `miMock` still holds A's snapshot:
                // A's cached grace copy must be revoked and never selected again.
                var haRefreshedCam = haCam
                haRefreshedCam.name = "HA门口摄像机(更新)"
                var haUpdated = home([haRefreshedCam], identityID: Self.haID)
                haUpdated.isInitialLoadComplete = true
                await haMock.updateSnapshot(haUpdated)

                await waitUntil(timeout: .seconds(5)) {
                    guard let card = store.devices.first(where: { $0.id == Self.haID }) else { return false }
                    if case .camera(let spec) = card.kind {
                        return store.deviceBackends[Self.haID] == .homeAssistant
                            && spec.entityId == "switch.door_cam_power"
                            && card.accountId == nil
                            && card.name == "HA门口摄像机(更新)"
                    }
                    return false
                }
                await waitUntil(timeout: .seconds(5)) { await miMock.stoppedCameraIDs.contains(Self.did) }
                #expect(store.devices.contains(where: { $0.id == "de-plug-grace" }))

                // Even if an older Xiaomi-backed paired snapshot carrying A's device arrives late,
                // HomeStore must drop A's device content rather than keeping it under `.homeAssistant`.
                var lateStalePaired = SynthesizedHome(devices: [camA, plugB])
                lateStalePaired.isInitialLoadComplete = true
                lateStalePaired.deviceBackends = [Self.did: .xiaomiCloud, "de-plug-grace": .xiaomiCloud]
                lateStalePaired.pairedDeviceIDs = [Self.did]
                lateStalePaired.accountStatuses = [accountA.id: .connected, accountB.id: .connected]
                store.handleProviderEvent(.snapshotUpdated(lateStalePaired))
                #expect(!store.devices.contains(where: { $0.id == Self.did }))
                #expect(!store.devices.contains(where: { $0.accountId == accountA.id }))
                #expect(store.devices.contains(where: { $0.id == "de-plug-grace" }))

                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }

        try await runScenario(signOut: true)
        try await runScenario(signOut: false)
    }

    @Test("Closing the HA disabled gate prevents a queued grace timer from selecting the stale HA snapshot before provider teardown")
    func disabledHAGatePreventsQueuedTimerFromSelectingStaleHASnapshot() async throws {
        try await withTeardown { teardown in
            let rig = await makeRig(teardown)

            await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
            let card = try #require(await rig.collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await rig.provider.resolveCameraStream(for: card)
            #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

            // HA drops into grace and parks a fallback timer while keeping the card on HA.
            await rig.haMock.sendStatus(.disconnected("blip"))
            await waitUntil {
                let disconnected = await rig.collector.sourceIsDisconnected(.homeAssistant)
                return disconnected && rig.gate.waiting == 1
            }
            #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)

            // Exact sequence:
            // 1. Close the HA gate first (without clearing the source provider or expiring grace).
            rig.provider.markBackendDisabled(.homeAssistant)
            // 2. Release the parked fallback timer while `homeAssistant` provider is still attached.
            let snapshotsBeforeTimer = await rig.collector.snapshotCount
            rig.gate.releaseLatest()
            await waitUntil(timeout: .seconds(5)) {
                let count = await rig.collector.snapshotCount
                let backend = await rig.collector.backend(forCard: Self.haID)
                return count > snapshotsBeforeTimer && backend == .xiaomiCloud
            }
            #expect(await rig.collector.latestHome?.sourceStatuses[.homeAssistant] == nil)
            await waitUntil(timeout: .seconds(5)) { await rig.haMock.stoppedCameraIDs == [Self.haID] }

            // 3. Clear the HA provider last; routing remains cleanly on Xiaomi Cloud.
            await rig.provider.setSourceProvider(nil, for: .homeAssistant)
            #expect(await rig.collector.backend(forCard: Self.haID) == .xiaomiCloud)
            #expect(await rig.collector.latestHome?.sourceStatuses[.homeAssistant] == nil)
        }
    }

    @Test("Selecting a cached graced Xiaomi copy with nil identity clears the original copy's identity entry")
    func cachedGracedCopyWithNilIdentityClearsOriginalIdentityEntry() async throws {
        try await withTeardown { teardown in
            let accAID = "cn:10040011"
            let accBID = "cn:10040022"
            var camA = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
            camA.accountId = accAID
            camA.roomId = MiAccountScope.id("door", account: accAID)
            // Initial connected snapshot has A as primary owner with NO identity entry for `Self.did`.
            var miInitial = SynthesizedHome(devices: [camA])
            miInitial.accountStatuses = [accAID: .connected, accBID: .connected]
            miInitial.deviceAccountIDs = [Self.did: [accAID, accBID]]
            miInitial.deviceIdentities = [:]

            let haMock = MockHomeProvider(snapshot: SynthesizedHome(devices: []))
            let miMock = MockHomeProvider(snapshot: miInitial)
            let clock = TestClock()
            let gate = GraceTimerGate()
            let provider = DualSourceHomeProvider(
                homeAssistant: haMock,
                xiaomiCloud: miMock,
                graceNow: { clock.now },
                fallbackRecheckTimer: gate
            )
            let collector = RouteCollector()
            let pump = Task {
                for await event in provider.events() {
                    await collector.append(event)
                }
            }
            track(teardown, provider: provider, gate: gate, pump: pump)

            await waitUntil {
                let latest = await collector.latestHome
                return latest?.devices.first(where: { $0.id == Self.did })?.accountId == accAID
                    && latest?.deviceIdentities[Self.did] == nil
            }

            // Account A transiently drops; B's offline copy overwrites `Self.did` and attaches an
            // identity entry. Grace restores A's cached copy (which had `identity == nil`), so the
            // stale identity entry from B's copy must be removed.
            var camBOffline = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")
            camBOffline.isOnline = false
            camBOffline.accountId = accBID
            camBOffline.roomId = MiAccountScope.id("door", account: accBID)
            var miADropped = SynthesizedHome(devices: [camBOffline])
            miADropped.accountStatuses = [accAID: .disconnected("HTTP 502"), accBID: .connected]
            miADropped.deviceAccountIDs = [Self.did: [accBID, accAID]]
            miADropped.deviceIdentities = [
                Self.did: DeviceSourceIdentity(
                    dids: [Self.did],
                    model: "chuangmi.camera.061a01",
                    name: "B副本",
                    roomName: "门口",
                    kindTag: .camera
                )
            ]
            let snapshotsBeforeDrop = await collector.snapshotCount
            await miMock.updateSnapshot(miADropped)
            await waitUntil(timeout: .seconds(5)) {
                let count = await collector.snapshotCount
                let disconnected = await collector.accountIsDisconnected(accAID)
                return count > snapshotsBeforeDrop && disconnected && gate.waiting == 1
            }

            let latest = try #require(await collector.latestHome)
            let restored = try #require(latest.devices.first(where: { $0.id == Self.did }))
            #expect(restored.accountId == accAID)
            #expect(restored.isOnline)
            #expect(latest.deviceIdentities[Self.did] == nil)
        }
    }

    @Test("The grace window is bounded and documented")
    func graceWindowIsBounded() {
        #expect(DualSourceHomeProvider.sourceFallbackGrace > 0)
        #expect(DualSourceHomeProvider.sourceFallbackGrace <= 60, "A real outage must fall back within a minute")
    }
}
