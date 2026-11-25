import Foundation
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChannelWriteBatchTests {
    private static let did = "101"
    private static let model = "test.switch.strip"

    private static func stripSpec(channelIDs: [Int]) -> MiotDeviceSpec {
        let services = channelIDs.map { siid in
            MiotService(iid: siid, type: "urn:miot-spec-v2:service:outlet:00007805:test:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test:1",
                             format: "bool", access: ["read", "write"])
            ])
        }
        return MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:test:1", services: services)
    }

    @Test(arguments: [false, true])
    func fourOutletBatchRechecksScreenLock(lockWhilePending: Bool) async throws {
        let did = Self.did
        let model = Self.model
        let channelIDs = Array(2...5)
        let spec = Self.stripSpec(channelIDs: channelIDs)
        let parent = MiDeviceRecord(did: did, name: "Strip", model: model, isOnline: true)
        let channels = channelIDs.map { siid in
            MiDeviceRecord(did: "\(did).s\(siid)", name: "Outlet \(siid)", model: model, isOnline: true,
                           splitParentDid: did, splitSiid: siid)
        }
        let properties = Dictionary(uniqueKeysWithValues: channelIDs.map {
            (MiotPropKey(did: did, siid: $0, piid: 1), JSONValue.bool(true))
        })
        let api = HybridMockCloudAPI(devices: [parent] + channels, rooms: [], props: properties)
        let session = MiSession(userId: "test", cUserId: "test", ssecurity: "test", serviceToken: "test", region: "cn")
        let provider = MiCloudProvider(
            sessionLoader: { session }, apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: [model: spec]), localClient: nil,
            pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), selectedHomeLoader: { nil }
        )
        let sleepGate = ScheduledCommandTestSupport.SleepGate()
        await provider.setChannelWriteSleepForTesting { delay in
            #expect(delay == .milliseconds(100))
            await sleepGate.sleep()
        }
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = true
        for channel in channels { store.setJoinsAllOff(true, deviceId: channel.did) }
        #expect(store.allOffTargets.count == 4)
        let allOff = try #require(store.turnAllOff())
        await waitUntil { await provider.pendingChannelWriteCountForTesting(did: did) == 4 && sleepGate.waiting == 1 }
        #expect(await api.setPropsCalls.isEmpty)
        if lockWhilePending { store.setScreenLocked(true) }
        sleepGate.release()

        if lockWhilePending {
            #expect(await allOff.value == .partial)
            #expect(await api.setPropsCalls.isEmpty)
            await provider.shutdown()
            return
        }
        #expect(await allOff.value == .completed)
        let requests = await api.setPropsCalls
        let propertiesWritten = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(propertiesWritten.sorted { $0.siid < $1.siid } == channelIDs.map {
            MiotPropWrite(did: did, siid: $0, piid: 1, value: .bool(false))
        })
        await provider.shutdown()
    }

    @Test(arguments: [false, true])
    func singleOutletFallbackRechecksScreenLock(lockDuringLANWrite: Bool) async throws {
        let lanWrite = ProbeConcurrencyGate(expectedParkedProbes: 1)
        let token = "00112233445566778899aabbccddeeff"
        let tokenData = try #require(MiIOPacket.validateToken(token))
        let udp = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 50) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let request = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            if request["method"]?.stringValue == "set_properties" {
                await lanWrite.park()
                throw MiIOError.timeout
            }
            let id = try #require(request["id"]?.intValue)
            let reply = #"{"id":\#(id),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":3,"piid":1,"value":true,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        let (provider, store, transport, _, _) = Self.cloudBackedStrip(
            localClient: LocalMiIOClient(transport: udp, maxRetries: 0), token: token
        )
        try await awaitState { store.hasReceivedInitialSnapshot }
        await provider.setChannelWriteSleepForTesting { _ in }
        store.blockControlWhileLocked = true
        let requestCount = transport.requests.count
        let write = Task {
            try await MiCloudProvider.$channelWriteStillAllowed.withValue({ await !store.isControlBlockedByScreenLock }) {
                try await provider.execute(.setSwitch(entityId: "miot:101:2", isOn: false))
            }
        }
        defer { write.cancel() }
        await lanWrite.waitUntilAllParked()
        store.setScreenLocked(lockDuringLANWrite)
        await lanWrite.release()

        if lockDuringLANWrite {
            await #expect(throws: CancellationError.self) { try await write.value }
        } else {
            try await write.value
        }
        await provider.shutdown()
        #expect(transport.requests.dropFirst(requestCount).map { $0.url?.path } ==
                (lockDuringLANWrite ? [] : ["/app/miotspec/prop/set"]))
    }

    @Test
    func manualReserveSurvivesMixedPriorityWindow() async throws {
        let (provider, store, transport, limiter, session) = Self.cloudBackedStrip()
        try await awaitState { store.hasReceivedInitialSnapshot }
        let account = session.historyScopeIdentifier
        for _ in 0..<7 {
            #expect(limiter.admit(account: account, write: true) == .admitted(generation: 0))
        }
        limiter.recordLimit(account: account, retryAfter: "30")

        let window = ProbeConcurrencyGate(expectedParkedProbes: 1)
        let (queued, onEnqueue) = AsyncStream<Void>.makeStream()
        var enqueues = queued.makeAsyncIterator()
        await provider.setChannelWriteSleepForTesting(onEnqueue: { onEnqueue.yield(()) }) { _ in
            await window.park()
        }
        let background = Task {
            try await MiCloudClient.$isBackgroundWrite.withValue(true) {
                try await provider.execute(.setSwitch(entityId: "miot:101:3", isOn: false))
            }
        }
        defer { background.cancel() }
        _ = await enqueues.next()
        async let manual: Void = provider.execute(.setSwitch(entityId: "miot:101:2", isOn: false))
        _ = await enqueues.next()
        onEnqueue.finish()
        await window.release()

        try await manual
        await #expect(throws: MiCloudError.http(429)) { try await background.value }
        await provider.shutdown()
        #expect(transport.requests.filter { $0.url?.path == "/app/miotspec/prop/set" }.count == 1)
        #expect(limiter.admit(account: account, write: true) == .limited)
    }

    private static func cloudBackedStrip(
        localClient: LocalMiIOClient? = nil, token: String = ""
    ) -> (MiCloudProvider, HomeStore, ScriptedTransport, MiCloudRateLimiter, MiSession) {
        let session = MiSession(userId: "test", cUserId: "test", ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==", serviceToken: "test")
        let limiter = MiCloudRateLimiter(uptime: { 0 }, jitter: { 0 })
        let transport = ScriptedTransport { request in
            let body: String
            switch request.url?.path {
            case "/app/v2/home/device_list_page":
                body = #"{"code":0,"result":{"list":[{"did":"101","model":"test.switch.strip","localip":"192.168.1.60","token":"\#(token)"}]}}"#
            case "/app/miotspec/prop/get":
                body = #"{"code":0,"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":3,"piid":1,"value":true,"code":0}]}"#
            case "/app/miotspec/prop/set":
                body = #"{"code":0,"result":[{"did":"101","siid":2,"piid":1,"code":0},{"did":"101","siid":3,"piid":1,"code":0}]}"#
            default:
                body = #"{"code":0,"result":{}}"#
            }
            return (200, [:], body)
        }
        let provider = MiCloudProvider(
            sessionLoader: { session },
            apiFactory: { MiCloudClient(session: $0, transport: transport, rateLimiter: limiter) },
            specSource: HybridMockSpecSource(specs: [model: stripSpec(channelIDs: [2, 3])]),
            localClient: localClient,
            pollInterval: .seconds(3600), closedPollInterval: .seconds(3600),
            followUpDelay: .seconds(3600), selectedHomeLoader: { nil }
        )
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        return (provider, store, transport, limiter, session)
    }

    @Test
    func acknowledgementMustIdentifyTheChannel() {
        let writes = [2, 3, 4].map { MiotPropWrite(did: "101", siid: $0, piid: 1, value: .bool(false)) }
        let result: JSONValue = .array([
            .object(["did": .string("101"), "siid": .number(3), "piid": .number(1), "code": .number(-1)]),
            .object(["did": .string("101"), "siid": .number(2), "piid": .number(1), "code": .number(0)]),
            .object(["did": .string("102"), "siid": .number(4), "piid": .number(1), "code": .number(0)]),
        ])
        let verdicts = MiCloudClient.propertyVerdicts(result, for: writes)
        #expect(throws: Never.self) { try verdicts[0].get() }
        guard case .failure(.deviceError(let code, _)) = verdicts[1],
              case .failure(.badResponse) = verdicts[2] else {
            Issue.record("Expected one explicit refusal and one missing acknowledgement")
            return
        }
        #expect(code == -1)
    }
}
