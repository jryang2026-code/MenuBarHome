import Dispatch
import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

@Suite(.serialized)
struct DualSourceFallbackGraceTests {
    private static let did = "1105610385"
    private static let haID = "ha-door-cam"

    private static let cameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:3","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]},{"iid":2,"type":"urn:miot-spec-v2:property:night-shot:00000057:chuangmi-061a01:1","format":"uint8","access":["read","write","notify"],"value-list":[{"value":0,"description":"Off"},{"value":1,"description":"On"},{"value":2,"description":"Auto"}]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
    private static let viewOnlyCameraSpecJSON = #"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:readonly","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","notify"]}]},{"iid":9,"type":"urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-061a01:1","actions":[{"iid":1,"type":"urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-061a01:1"},{"iid":2,"type":"urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-061a01:1"}]}]}"#
    private static let plugSpecJSON = #"{"type":"urn:miot-spec-v2:device:outlet:0000A002:cuco-v3:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:switch:0000780C:cuco-v3:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:cuco-v3:1","format":"bool","access":["read","write","notify"]}]}]}"#

    private static let camSpec = MiotFixtures.decode(cameraSpecJSON)
    private static let viewOnlyCamSpec = MiotFixtures.decode(viewOnlyCameraSpecJSON)
    private static let plugSpec = MiotFixtures.decode(plugSpecJSON)

    private struct SharedSpecSource: MiotSpecSource {
        func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
            switch model {
            case "chuangmi.camera.061a01":
                return specType == DualSourceFallbackGraceTests.viewOnlyCamSpec.type
                    ? DualSourceFallbackGraceTests.viewOnlyCamSpec
                    : DualSourceFallbackGraceTests.camSpec
            case "cuco.plug.v3":
                return DualSourceFallbackGraceTests.plugSpec
            default:
                return nil
            }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SuspendingClock.Instant
        init(_ start: SuspendingClock.Instant = SuspendingClock.now) { current = start }
        var now: SuspendingClock.Instant { lock.withLock { current } }
        func advance(_ interval: TimeInterval) {
            lock.withLock {
                current = current.advanced(by: .milliseconds(Int((interval * 1000).rounded())))
            }
        }
    }

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

        func cancelPending() { lock.withLock { cancelCancellableEntriesLocked() } }
        func invalidate() { lock.withLock { isInvalidated = true; entries.removeAll() } }
        func shutdown() { invalidate() }
        func releaseLatest() { lock.withLock({ entries.popLast() })?.onFire() }
        func releaseOldestNormally() { lock.withLock({ entries.isEmpty ? nil : entries.removeFirst() })?.onFire() }

        private func cancelCancellableEntriesLocked() {
            var kept: [Entry] = []
            for entry in entries {
                if entry.ignoreCancel { kept.append(entry) } else { storedCancelledCount += 1 }
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
            identityID: DeviceSourceIdentity(dids: [Self.did], model: "chuangmi.camera.061a01", name: "门口", roomName: "门口", kindTag: .camera)
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

        func clearSnapshots() { snapshots.removeAll() }
        func backend(forCard cardID: String) -> HomeBackend? { latestHome?.deviceBackends[cardID] }
        func sourceIsDisconnected(_ backend: HomeBackend) -> Bool {
            if case .disconnected = latestHome?.sourceStatuses[backend] ?? .connecting { return true }
            return false
        }
        func sourceIsConnected(_ backend: HomeBackend) -> Bool { latestHome?.sourceStatuses[backend]?.isConnected == true }
        func accountIsDisconnected(_ accountID: String) -> Bool {
            if case .disconnected = latestHome?.accountStatuses[accountID] ?? .connecting { return true }
            return false
        }
        func accountIsConnected(_ accountID: String) -> Bool { latestHome?.accountStatuses[accountID]?.isConnected == true }
    }

    private final class Teardown {
        private var steps: [() async -> Void] = []
        private var finishes: [() -> Void] = []
        func addFinish(_ finish: @escaping () -> Void) { finishes.append(finish) }
        func add(_ step: @escaping () async -> Void) { steps.append(step) }
        func drain() async {
            let pendingFinishes = finishes; finishes.removeAll()
            for finish in pendingFinishes { finish() }
            let pendingSteps = steps; steps.removeAll()
            for step in pendingSteps.reversed() { await step() }
        }
    }

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

    private func track(_ teardown: Teardown, provider: DualSourceHomeProvider, gate: GraceTimerGate, pump: Task<Void, Never>) {
        teardown.add {
            gate.shutdown()
            await provider.shutdown()
            pump.cancel()
            await pump.value
        }
    }

    private func makeRig(
        _ teardown: Teardown,
        haStream: String? = "camera.door_stream",
        miStream: String = "miot:\(Self.did):5"
    ) async -> Rig {
        let haHome = home([camera(id: Self.haID, entity: "switch.door_cam_power", stream: haStream)], identityID: Self.haID)
        let miHome = home([camera(id: Self.did, entity: "miot:\(Self.did):2", stream: miStream)], identityID: Self.did)
        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let clock = TestClock()
        let gate = GraceTimerGate()
        let provider = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miMock, graceNow: { clock.now }, fallbackRecheckTimer: gate)
        let collector = RouteCollector()
        let pump = Task {
            for await event in provider.events() { await collector.append(event) }
        }
        track(teardown, provider: provider, gate: gate, pump: pump)
        let rig = Rig(haMock: haMock, miMock: miMock, provider: provider, collector: collector, clock: clock, gate: gate, pump: pump)
        await waitUntil {
            guard let latest = await collector.latestHome else { return false }
            return latest.deviceBackends[Self.haID] != nil
                && latest.pairedDeviceIDs.contains(Self.haID)
                && latest.sourceStatuses[.homeAssistant]?.isConnected == true
                && latest.sourceStatuses[.xiaomiCloud]?.isConnected == true
        }
        return rig
    }

    private func waitForBackend(_ rig: Rig, cardID: String, _ expected: HomeBackend, timeout: Duration = .seconds(15)) async {
        await waitUntil(timeout: timeout) { await rig.collector.backend(forCard: cardID) == expected }
    }

    private func makeCamAPI(isOnline: Bool = true, specType: String? = nil, includePlug: Bool = false) -> StubMiCloudAPI {
        var devices = [
            MiDeviceRecord(did: Self.did, name: "门口", model: "chuangmi.camera.061a01", isOnline: isOnline, specType: specType, localIp: "192.0.2.45")
        ]
        var dids = [Self.did]
        var values: [MiotPropKey: JSONValue] = isOnline ? [MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true)] : [:]
        if includePlug {
            devices.append(MiDeviceRecord(did: "shared-plug-1", name: "共享插座", model: "cuco.plug.v3", isOnline: true))
            dids.append("shared-plug-1")
            values[MiotPropKey(did: "shared-plug-1", siid: 2, piid: 1)] = .bool(true)
        }
        return StubMiCloudAPI(
            devices: devices,
            rooms: [MiRoom(id: "r1", name: "门口", dids: dids, homeId: "h1", homeName: "家")],
            values: values
        )
    }

    @Test(arguments: [HomeBackend.homeAssistant, .xiaomiCloud])
    func attachingToDisabledBackendRequiresCurrentGeneration(backend: HomeBackend) async throws {
        let provider = DualSourceHomeProvider(homeAssistant: nil, xiaomiCloud: nil)
        let entityID = backend == .homeAssistant ? "switch.test" : "miot:\(Self.did):2"
        let command = DeviceCommand.setSwitch(entityId: entityID, isOn: true)
        let initial = MockHomeProvider()
        await provider.setSourceProvider(initial, for: backend)
        try await provider.execute(command)
        #expect(await initial.executedCommands == [command])

        let generationA = provider.markBackendDisabled(backend)
        let generationB = provider.markBackendDisabled(backend)
        let unversioned = MockHomeProvider()
        await provider.setSourceProvider(unversioned, for: backend)
        await #expect(throws: HomeProviderError.backendNotConfigured(backend)) {
            try await provider.execute(command)
        }
        #expect(await unversioned.executedCommands.isEmpty)

        let stale = MockHomeProvider()
        await provider.setSourceProvider(stale, for: backend, expectedDisableGeneration: generationA)
        await #expect(throws: HomeProviderError.backendNotConfigured(backend)) {
            try await provider.execute(command)
        }
        #expect(await stale.executedCommands.isEmpty)

        let current = MockHomeProvider()
        await provider.setSourceProvider(current, for: backend, expectedDisableGeneration: generationB)
        try await provider.execute(command)
        #expect(await current.executedCommands == [command])
        await provider.shutdown()
    }

    @Test(arguments: [
        (AppLanguage.zhHans, "Home Assistant 未配置", "Home Assistant 已停用", "米家云端未配置", "米家已停用"),
        (.zhHant, "Home Assistant 未配置", "Home Assistant 已停用", "米家雲端未配置", "米家已停用"),
        (.en, "Home Assistant is not configured", "Home Assistant is turned off",
         "Xiaomi Cloud is not configured", "Xiaomi Home is turned off")
    ])
    func cameraRejectionNamesMissingOrDisabledSource(
        expected: (AppLanguage, String, String, String, String)
    ) async {
        let (language, haMissing, haDisabled, miMissing, miDisabled) = expected
        await L10n.$overrideLanguage.withValue(language) {
            let ha = MockHomeProvider()
            let mi = MockHomeProvider()
            let haOnly = DualSourceHomeProvider(homeAssistant: ha, xiaomiCloud: nil)
            let miOnly = DualSourceHomeProvider(homeAssistant: nil, xiaomiCloud: mi)
            let haCamera = camera(id: Self.haID, entity: "camera.door", stream: "camera.door")
            let miCamera = camera(id: Self.did, entity: "miot:\(Self.did):2", stream: nil)
            await #expect(throws: HomeProviderError.serviceCallFailed(501, haMissing)) {
                try await miOnly.resolveCameraStream(for: haCamera)
            }
            await #expect(throws: HomeProviderError.serviceCallFailed(501, miMissing)) {
                try await haOnly.resolveCameraStream(for: miCamera)
            }
            #expect(await ha.requestedCameraQualities.isEmpty)
            #expect(await mi.requestedCameraQualities.isEmpty)
            await haOnly.shutdown()
            await miOnly.shutdown()

            let disabledHA = MockHomeProvider()
            let disabledMi = MockHomeProvider()
            let dual = DualSourceHomeProvider(homeAssistant: disabledHA, xiaomiCloud: disabledMi)
            dual.markBackendDisabled(.homeAssistant)
            dual.markBackendDisabled(.xiaomiCloud)
            await #expect(throws: HomeProviderError.serviceCallFailed(501, haMissing)) {
                try await dual.resolveCameraStream(for: haCamera)
            }
            await #expect(throws: HomeProviderError.serviceCallFailed(501, miMissing)) {
                try await dual.resolveCameraStream(for: miCamera)
            }
            await #expect(throws: HomeProviderError.serviceCallFailed(501, haDisabled)) {
                try await dual.resolveCameraStream(
                    for: haCamera, quality: .auto, channel: 0, explicitlyDisabledBackends: [.homeAssistant]
                )
            }
            await #expect(throws: HomeProviderError.serviceCallFailed(501, miDisabled)) {
                try await dual.resolveCameraStream(
                    for: miCamera, quality: .auto, channel: 0, explicitlyDisabledBackends: [.xiaomiCloud]
                )
            }
            #expect(await disabledHA.requestedCameraQualities.isEmpty)
            #expect(await disabledMi.requestedCameraQualities.isEmpty)
            await dual.shutdown()
        }
    }

    @Test
    func rejectedUnversionedAttachmentLeavesSnapshotCleanupToDetach() async throws {
        try await withTeardown { teardown in
            let rig = await makeRig(teardown)
            await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
            let card = try #require(await rig.collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await rig.provider.resolveCameraStream(for: card)

            rig.provider.markBackendDisabled(.homeAssistant)
            await rig.provider.setSourceProvider(MockHomeProvider(), for: .homeAssistant)
            #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

            await rig.provider.setSourceProvider(nil, for: .homeAssistant)
            #expect(await rig.haMock.stoppedCameraIDs == [Self.haID])
            await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
        }
    }

    @Test("Transient HA or Mi blips hold routing and live stream within grace, flip and close stream past grace, and skip grace on invalidation")
    func haAndMiTransientBlipsAndRealOutages() async throws {
        #expect(DualSourceHomeProvider.sourceFallbackGrace > 0 && DualSourceHomeProvider.sourceFallbackGrace <= 60)

        try await withTeardown { teardown in
            let rig = await makeRig(teardown)
            await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
            let card = try #require(await rig.collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await rig.provider.resolveCameraStream(for: card)

            await rig.haMock.sendStatus(.disconnected("connection lost"))
            await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
            await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
            #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

            await rig.haMock.sendStatus(.connected)
            await waitUntil { await rig.collector.sourceIsConnected(.homeAssistant) }
            #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

            await rig.haMock.sendStatus(.disconnected("real outage"))
            await waitUntil { await rig.collector.sourceIsDisconnected(.homeAssistant) }
            rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
            rig.provider.requestRecompute()
            await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
            await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }

            let miRig = await makeRig(teardown, haStream: nil)
            await waitForBackend(miRig, cardID: Self.haID, .xiaomiCloud)
            let miCard = try #require(await miRig.collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await miRig.provider.resolveCameraStream(for: miCard)
            await miRig.miMock.sendStatus(.disconnected("poll failed"))
            await waitUntil { await miRig.collector.sourceIsDisconnected(.xiaomiCloud) }
            await waitForBackend(miRig, cardID: Self.haID, .xiaomiCloud)
            #expect(await miRig.miMock.stoppedCameraIDs.isEmpty)

            await miRig.provider.invalidateSnapshot(for: .xiaomiCloud)
            await waitForBackend(miRig, cardID: Self.haID, .homeAssistant)
        }
    }

    @Test("MiAccountsProvider account-level grace holds paired camera over offline co-owner and clears stale identity on restore")
    func miAccountsProviderBlipAndSharedCoOwnerGrace() async throws {
        try await withTeardown { teardown in
            let accountA = MiAccount(session: MiSession(userId: "10010011", cUserId: "c-a", ssecurity: "ssec-a", serviceToken: "tok-a", region: "cn"))
            let accountB = MiAccount(session: MiSession(userId: "10010022", cUserId: "c-b", ssecurity: "ssec-b", serviceToken: "tok-b", region: "cn"))
            let apiA = makeCamAPI(isOnline: true)
            let apiB = makeCamAPI(isOnline: false)
            let bridge = StubXiaomiCameraBridge()
            let miAccounts = MiAccountsProvider(
                accounts: [accountA, accountB],
                apiFactory: { $0.userId == accountA.session.userId ? apiA : apiB },
                specSource: SharedSpecSource(),
                cameraBridge: bridge,
                localClientFactory: { nil },
                pollInterval: .seconds(3600),
                closedPollInterval: .seconds(3600),
                cameraSessionReleaseDelay: .milliseconds(5),
                selectedHomeLoader: { nil },
                clearSelectedHome: {}
            )
            let haMock = MockHomeProvider(snapshot: home([camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)], identityID: Self.haID))
            let clock = TestClock()
            let gate = GraceTimerGate()
            let provider = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miAccounts, graceNow: { clock.now }, fallbackRecheckTimer: gate)
            let collector = RouteCollector()
            let pump = Task { for await event in provider.events() { await collector.append(event) } }
            track(teardown, provider: provider, gate: gate, pump: pump)

            await waitUntil {
                let backend = await collector.backend(forCard: Self.haID)
                let a = await collector.accountIsConnected(accountA.id)
                let b = await collector.accountIsConnected(accountB.id)
                return backend == .xiaomiCloud && a && b
            }
            let initialCard = try #require(await collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await provider.resolveCameraStream(for: initialCard)
            #expect(await bridge.startCalls.count == 1)

            await collector.clearSnapshots()
            await apiA.setGetPropsFailure(.http(502))
            await miAccounts.refreshNow()
            await waitUntil {
                let disc = await collector.accountIsDisconnected(accountA.id)
                return disc && gate.waiting == 1
            }
            #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
            #expect(await bridge.stopCalls.isEmpty)

            await apiA.setGetPropsFailure(nil)
            await miAccounts.refreshNow()
            await waitUntil {
                let conn = await collector.accountIsConnected(accountA.id)
                return conn && gate.waiting == 0
            }
            #expect((await collector.snapshots).allSatisfy { $0.deviceBackends[Self.haID] == .xiaomiCloud })
            #expect(await bridge.stopCalls.isEmpty)

            await apiA.setGetPropsFailure(.http(502))
            await miAccounts.refreshNow()
            await waitUntil {
                let disc = await collector.accountIsDisconnected(accountA.id)
                return disc && gate.waiting == 1
            }
            clock.advance(DualSourceHomeProvider.sourceFallbackGrace + 1)
            gate.releaseLatest()
            await waitUntil { await collector.backend(forCard: Self.haID) == .homeAssistant }
            await waitUntil { await bridge.stopCalls.contains(Self.did) }
        }
    }

    @Test("Superseded fallback cancellation, system sleep/wake grace freeze, DispatchFallbackRecheckTimer re-arm, and shutdown/disabled timer guards")
    func timerCancellationSleepWakeAndShutdownGuards() async throws {
        try await withTeardown { teardown in
            let rig = await makeRig(teardown)
            await waitForBackend(rig, cardID: Self.haID, .homeAssistant)
            let card = try #require(await rig.collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await rig.provider.resolveCameraStream(for: card)

            await rig.haMock.sendStatus(.disconnected("blip"))
            await waitUntil {
                let disc = await rig.collector.sourceIsDisconnected(.homeAssistant)
                return disc && rig.gate.waiting == 1
            }

            let beforeFirstMiUpdate = await rig.collector.snapshotCount
            rig.clock.advance(4)
            rig.gate.ignoreCancellationOnNextSleep()
            let updatedMiHome = home([camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5")], identityID: Self.did)
            await rig.miMock.updateSnapshot(updatedMiHome)
            await waitUntil {
                let count = await rig.collector.snapshotCount
                return rig.gate.cancelledWakeCount == 1 && rig.gate.parkCount == 2 && count > beforeFirstMiUpdate
            }
            #expect(rig.gate.recordedDelays == [.seconds(15), .seconds(11)])

            rig.clock.advance(2)
            await rig.miMock.updateSnapshot(updatedMiHome)
            await waitUntil { rig.gate.parkCount == 3 && rig.gate.waiting == 2 }
            let beforeStaleWake = await rig.collector.snapshotCount
            rig.gate.releaseOldestNormally()
            await waitUntil { await rig.provider.discardedFallbackWakeCountForTesting == 1 }
            #expect(await rig.collector.snapshotCount == beforeStaleWake && rig.gate.waiting == 1)

            await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
            await waitUntil { rig.gate.waiting == 0 }
            rig.clock.advance(DualSourceHomeProvider.sourceFallbackGrace * 4)
            await rig.provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
            await waitUntil { rig.gate.waiting == 1 }
            #expect(await rig.collector.backend(forCard: Self.haID) == .homeAssistant)
            #expect(await rig.haMock.stoppedCameraIDs.isEmpty)

            rig.provider.markBackendDisabled(.homeAssistant)
            rig.gate.releaseLatest()
            await waitForBackend(rig, cardID: Self.haID, .xiaomiCloud)
            await waitUntil { await rig.haMock.stoppedCameraIDs == [Self.haID] }

            let queue = DispatchQueue(label: "test.DispatchFallbackRecheckTimer")
            let timer = DispatchFallbackRecheckTimer(queue: queue)
            defer { timer.invalidate() }
            final class TagLog: @unchecked Sendable {
                private let lock = NSLock()
                private var stored: [String] = []
                func record(_ tag: String) { lock.withLock { stored.append(tag) } }
                var tags: [String] { lock.withLock { stored } }
            }
            let log = TagLog()
            timer.schedule(after: .seconds(60)) { log.record("cancelled") }
            timer.cancelPending()
            timer.schedule(after: .milliseconds(5)) { log.record("fired") }
            await waitUntil(timeout: .seconds(5)) { log.tags == ["fired"] }
            timer.invalidate()
            timer.schedule(after: .zero) { log.record("after-invalidate") }
            #expect(log.tags == ["fired"])
        }
    }

    @Test("sessionExpired immediately skips grace, drops expired candidates across tie-breakers and nil accountId, and promotes surviving co-owner")
    func sessionExpiredSkipsGraceAndPromotesSurvivingCoOwner() async throws {
        try await withTeardown { teardown in
            let session1 = MiSession(userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn", region: "cn")
            let session2 = MiSession(userId: "20020002", cUserId: "c-de", ssecurity: "ssec-2", serviceToken: "tok-de", region: "de")
            let account1 = MiAccount(session: session1)
            let account2 = MiAccount(session: session2)
            let sharedPlugDID = "shared-plug-1"
            let exclusiveCamDID = "2205610999"
            let exclusiveHAID = "ha-exclusive-cam"

            let api1 = StubMiCloudAPI(
                devices: [
                    MiDeviceRecord(did: Self.did, name: "门口", model: "chuangmi.camera.061a01", isOnline: true, localIp: "192.0.2.45"),
                    MiDeviceRecord(did: sharedPlugDID, name: "共享插座", model: "cuco.plug.v3", isOnline: true),
                    MiDeviceRecord(did: exclusiveCamDID, name: "玄关独享摄像机", model: "chuangmi.camera.061a01", isOnline: true, localIp: "192.0.2.47"),
                ],
                rooms: [MiRoom(id: "r1", name: "门口", dids: [Self.did, sharedPlugDID, exclusiveCamDID], homeId: "h1", homeName: "主家庭")],
                values: [
                    MiotPropKey(did: Self.did, siid: 2, piid: 1): .bool(true),
                    MiotPropKey(did: sharedPlugDID, siid: 2, piid: 1): .bool(true),
                    MiotPropKey(did: exclusiveCamDID, siid: 2, piid: 1): .bool(true),
                ]
            )
            let api2 = makeCamAPI(isOnline: true, includePlug: true)
            let bridge = StubXiaomiCameraBridge()
            let miAccounts = MiAccountsProvider(
                accounts: [account1, account2],
                apiFactory: { $0.userId == session1.userId ? api1 : api2 },
                specSource: SharedSpecSource(),
                cameraBridge: bridge,
                localClientFactory: { nil },
                pollInterval: .seconds(3600),
                closedPollInterval: .seconds(3600),
                followUpDelay: .zero,
                cameraSessionReleaseDelay: .zero,
                selectedHomeLoader: { nil },
                clearSelectedHome: {}
            )

            let offlineHAExclusiveCam = SmartDevice(
                id: exclusiveHAID,
                name: "玄关独享摄像机",
                roomId: "door",
                roomName: "门口",
                model: "chuangmi.camera.061a01",
                isOnline: false,
                kind: .camera(CameraSpec(entityId: "switch.exclusive_cam_power", isOn: true, streamEntityId: nil))
            )
            var haMultiHome = SynthesizedHome(devices: [
                camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil),
                offlineHAExclusiveCam,
            ])
            haMultiHome.deviceIdentities = [
                Self.haID: DeviceSourceIdentity(dids: [Self.did], model: "chuangmi.camera.061a01", name: "门口", roomName: "门口", kindTag: .camera),
                exclusiveHAID: DeviceSourceIdentity(dids: [exclusiveCamDID], model: "chuangmi.camera.061a01", name: "玄关独享摄像机", roomName: "门口", kindTag: .camera),
            ]
            let haMock = MockHomeProvider(snapshot: haMultiHome)
            let clock = TestClock()
            let gate = GraceTimerGate()
            let provider = DualSourceHomeProvider(
                homeAssistant: haMock,
                xiaomiCloud: miAccounts,
                pinnedBackends: { [exclusiveHAID: .xiaomiCloud] },
                graceNow: { clock.now },
                fallbackRecheckTimer: gate
            )
            let collector = RouteCollector()
            let pump = Task { for await event in provider.events() { await collector.append(event) } }
            track(teardown, provider: provider, gate: gate, pump: pump)

            await waitUntil {
                let b1 = await collector.backend(forCard: Self.haID)
                let b2 = await collector.backend(forCard: sharedPlugDID)
                let b3 = await collector.backend(forCard: exclusiveHAID)
                return b1 == .xiaomiCloud && b2 == .xiaomiCloud && b3 == .xiaomiCloud
            }
            let sharedCam = try #require(await collector.latestHome?.devices.first { $0.id == Self.haID })
            let exclusiveCam = try #require(await collector.latestHome?.devices.first { $0.id == exclusiveHAID })
            _ = try await provider.resolveCameraStream(for: sharedCam)
            _ = try await provider.resolveCameraStream(for: exclusiveCam)

            await collector.clearSnapshots()
            await api1.setSetPropsFailure(.sessionExpired)
            try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))

            await waitUntil { await collector.expiredSessions.count == 1 }
            await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: exclusiveHAID) == .homeAssistant }
            await waitUntil(timeout: .seconds(2)) { await bridge.stopCalls == [exclusiveCamDID] }
            await waitUntil(timeout: .seconds(2)) {
                await collector.latestHome?.devices.first { $0.id == Self.haID }?.accountId == account2.id
            }
            #expect((await collector.snapshots).allSatisfy { $0.deviceBackends[Self.haID] == .xiaomiCloud })
            #expect(gate.parkCount == 0)
        }
    }

    @Test("Single and multi-account sessionExpired keep rejected devices stripped across connecting/stale snapshots until relogin completes")
    func sessionExpiredReloginAndMultiAccountConnecting() async throws {
        try await withTeardown { teardown in
            let session1 = MiSession(userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn-old", region: "cn")
            let account1 = MiAccount(session: session1)
            let account2 = MiAccount(session: MiSession(userId: "20020002", cUserId: "c-de", ssecurity: "ssec-2", serviceToken: "tok-de", region: "de"))

            var offlineHADoorCam = camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)
            offlineHADoorCam.isOnline = false
            let haHome = home([offlineHADoorCam], identityID: Self.haID)
            let miPlug = SmartDevice(id: "mi-plug-1", name: "客厅插座", roomId: "door", roomName: "门口", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "miot:mi-plug-1:2", isOn: true)))
            let initialMiHome = home([camera(id: Self.did, entity: "miot:\(Self.did):2", stream: "miot:\(Self.did):5"), miPlug], identityID: Self.did)
            let haMock = MockHomeProvider(snapshot: haHome)
            let miMock = MockHomeProvider(snapshot: initialMiHome)
            let clock = TestClock()
            let gate = GraceTimerGate()
            let dual = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miMock, pinnedBackends: { [Self.haID: .xiaomiCloud] }, graceNow: { clock.now }, fallbackRecheckTimer: gate)
            let collector = RouteCollector()
            let pump = Task { for await event in dual.events() { await collector.append(event) } }
            track(teardown, provider: dual, gate: gate, pump: pump)

            await waitUntil { await collector.backend(forCard: Self.haID) == .xiaomiCloud }
            await miMock.sendSessionExpired(session1)
            await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: Self.haID) == .homeAssistant }
            #expect(await collector.latestHome?.expiredAccountIDs == [account1.id])

            let beforePremature = await collector.snapshotCount
            await miMock.sendStatus(.connected)
            await waitUntil(timeout: .seconds(2)) { await collector.snapshotCount > beforePremature }
            #expect(await collector.sourceIsConnected(.xiaomiCloud) == false)
            #expect(await collector.backend(forCard: Self.haID) == .homeAssistant)

            var stalePartial = initialMiHome
            stalePartial.closesAwayGap = false
            let beforeStale = await collector.snapshotCount
            await miMock.updateSnapshot(stalePartial)
            await waitUntil(timeout: .seconds(2)) { await collector.snapshotCount > beforeStale }
            #expect(await collector.backend(forCard: Self.haID) == .homeAssistant)

            var freshRelogin = initialMiHome
            freshRelogin.closesAwayGap = true
            freshRelogin.expiredAccountIDs = []
            await miMock.updateSnapshot(freshRelogin)
            await waitUntil(timeout: .seconds(2)) { await collector.backend(forCard: Self.haID) == .xiaomiCloud }
            #expect(await collector.sourceIsConnected(.xiaomiCloud))

            var multiSnapshots = home([miPlug], identityID: Self.did)
            multiSnapshots.deviceIdentities = [:]
            multiSnapshots.accountStatuses = [account1.id: .connecting, account2.id: .connected]
            multiSnapshots.expiredAccountIDs = []
            await miMock.updateSnapshot(multiSnapshots)
            await waitUntil(timeout: .seconds(2)) {
                await collector.latestHome?.accountStatuses[account1.id] == .connecting
            }
            #expect(await collector.latestHome?.expiredAccountIDs.isEmpty == true)
        }
    }

    @Test("Graced display account keeps live stream alive while writes route only to enabled online writable sessions")
    func gracedDisplayAccountSeparatesFromWriteRouting() async throws {
        try await withTeardown { teardown in
            let accountA = MiAccount(session: MiSession(userId: "10020011", cUserId: "c-a1", ssecurity: "ssec-a1", serviceToken: "tok-a1", region: "cn"))
            let accountB = MiAccount(session: MiSession(userId: "10020022", cUserId: "c-b1", ssecurity: "ssec-b1", serviceToken: "tok-b1", region: "cn"))
            let accountC = MiAccount(session: MiSession(userId: "10020033", cUserId: "c-c1", ssecurity: "ssec-c1", serviceToken: "tok-c1", region: "cn"))
            let apiA = makeCamAPI(isOnline: true, specType: Self.camSpec.type)
            let apiBViewOnly = makeCamAPI(isOnline: true, specType: Self.viewOnlyCamSpec.type)
            let apiCWritable = makeCamAPI(isOnline: true, specType: Self.camSpec.type)
            let bridge = StubXiaomiCameraBridge()
            let miAccounts = MiAccountsProvider(
                accounts: [accountA, accountB, accountC],
                apiFactory: { session in
                    switch session.userId {
                    case accountA.session.userId: return apiA
                    case accountB.session.userId: return apiBViewOnly
                    default: return apiCWritable
                    }
                },
                specSource: SharedSpecSource(),
                cameraBridge: bridge,
                localClientFactory: { nil },
                pollInterval: .seconds(3600),
                closedPollInterval: .seconds(3600),
                followUpDelay: .zero,
                cameraSessionReleaseDelay: .zero,
                selectedHomeLoader: { nil },
                clearSelectedHome: {}
            )
            let haMock = MockHomeProvider(snapshot: home([camera(id: Self.haID, entity: "switch.door_cam_power", stream: nil)], identityID: Self.haID))
            let clock = TestClock()
            let gate = GraceTimerGate()
            let provider = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miAccounts, graceNow: { clock.now }, fallbackRecheckTimer: gate)
            let collector = RouteCollector()
            let pump = Task { for await event in provider.events() { await collector.append(event) } }
            track(teardown, provider: provider, gate: gate, pump: pump)

            await waitUntil {
                let backend = await collector.backend(forCard: Self.haID)
                let a = await collector.accountIsConnected(accountA.id)
                let b = await collector.accountIsConnected(accountB.id)
                let c = await collector.accountIsConnected(accountC.id)
                return backend == .xiaomiCloud && a && b && c
            }
            let card = try #require(await collector.latestHome?.devices.first { $0.id == Self.haID })
            _ = try await provider.resolveCameraStream(for: card)

            await apiA.setGetPropsFailure(.http(502))
            await miAccounts.refreshNow()
            await waitUntil { await collector.accountIsDisconnected(accountA.id) }
            #expect(await collector.backend(forCard: Self.haID) == .xiaomiCloud)
            #expect(await bridge.stopCalls.isEmpty)

            try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: false))
            #expect(await apiA.setPropsCalls.isEmpty)
            #expect(await apiBViewOnly.setPropsCalls.isEmpty)
            #expect(await apiCWritable.setPropsCalls == [[MiotPropWrite(did: Self.did, siid: 2, piid: 1, value: .bool(false))]])

            miAccounts.markAccountDisabled(accountC.id)
            await #expect(throws: MiotCommandError.noWritableSession(Self.did)) {
                try await provider.execute(.setSwitch(entityId: "miot:\(Self.did):2", isOn: true))
            }
        }
    }

    @MainActor
    @Test("Signing out or disabling a Xiaomi account during grace revokes its cached copy and fails over to HA")
    func revokingOrDisablingMiAccountDuringGraceEvictsCachedCopyAndFailsOverToHA() async throws {

        let accountA = MiAccount(session: MiSession(userId: "10030011", cUserId: "c-grace-a", ssecurity: "ssec-a", serviceToken: "tok-a", region: "cn"))
        let accountB = MiAccount(session: MiSession(userId: "10030022", cUserId: "c-grace-b", ssecurity: "ssec-b", serviceToken: "tok-b", region: "de"))
        for signOut in [true, false] {
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
            camA.roomId = MiAccountScope.id("door", account: accountA.id)
            let plugB = SmartDevice(id: "de-plug-grace", name: "B账号书房插座", roomId: MiAccountScope.id("study", account: accountB.id), roomName: "书房", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-grace:2", isOn: true)), accountId: accountB.id)
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
            let dual = DualSourceHomeProvider(homeAssistant: haMock, xiaomiCloud: miMock, graceNow: { clock.now }, fallbackRecheckTimer: gate)
            let store = HomeStore(provider: dual, defaultsSuiteName: suite, credentialVault: vault)

            await waitUntil { store.deviceBackends[Self.haID] == .xiaomiCloud }
            let initialCard = try #require(store.devices.first { $0.id == Self.haID })
            _ = try await dual.resolveCameraStream(for: initialCard)

            var miADropped = miConnected
            miADropped.accountStatuses = [accountA.id: .disconnected("HTTP 502"), accountB.id: .connected]
            await miMock.updateSnapshot(miADropped)
            await waitUntil { gate.waiting == 1 }

            if signOut {
                store.logoutMiAccount(id: accountA.id)
            } else {
                #expect(store.setMiAccountEnabled(false, id: accountA.id).disposition == .allowed)
            }
            await haMock.updateSnapshot(haInitial)
            await waitUntil(timeout: .seconds(5)) { store.deviceBackends[Self.haID] == .homeAssistant }
            await waitUntil(timeout: .seconds(5)) { await miMock.stoppedCameraIDs.contains(Self.did) }

            store.eventTask?.cancel()
            await store.providerShutdownTask?.value
            gate.shutdown()
            await dual.shutdown()
        }
    }
}
