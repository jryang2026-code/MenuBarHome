import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct OfflineLANReachabilityTests {
    private static let token = "00112233445566778899aabbccddeeff"
    private static let offlineDID = "102"

    private static func record(
        _ did: String, online: Bool = false, ip: String? = "192.168.1.20",
        token: String? = OfflineLANReachabilityTests.token, shared: Bool? = false, pid: Int? = 0, splitParent: String? = nil
    ) -> MiDeviceRecord {
        MiDeviceRecord(
            did: did, name: did, model: "yeelink.light.color4", isOnline: online,
            splitParentDid: splitParent, localIp: ip, token: token, isShared: shared, pid: pid
        )
    }

    private struct Fixture {
        let online = OfflineLANReachabilityTests.record("101", online: true, ip: "192.168.1.21")
        let offline = OfflineLANReachabilityTests.record(offlineDID)
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let home = TestBox<String?>("mine")
        let session = TestBox<MiSession?>(MiSession(
            userId: "10001", cUserId: "c1", ssecurity: Data(repeating: 1, count: 16).base64EncodedString(),
            serviceToken: "tok", region: "cn"
        ))
        let collector = EventCollector()
        let normalTransport: MockUDPTransport
        let probeTransport: MockUDPTransport
        let cloud: HybridMockCloudAPI
        let provider: MiCloudProvider
        let events: Task<Void, Never>

        init(
            candidates: [MiDeviceRecord]? = nil,
            includeOnline: Bool = true,
            authorization: MiIOError? = nil,
            probeReply: @escaping @Sendable (Data, String, UInt16) async throws -> Data = { _, _, _ in
                makeHelloResponse(deviceId: 102, stamp: 10)
            }
        ) throws {
            let tokenData = try #require(MiIOPacket.validateToken(OfflineLANReachabilityTests.token))
            normalTransport = MockUDPTransport { packet, _, _ in
                if let authorization { throw authorization }
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
                let (header, request) = try MiIOPacket.decode(packet, token: tokenData)
                let json = try JSONDecoder().decode(JSONValue.self, from: request)
                #expect(json["method"]?.stringValue == "get_properties")
                let id = try #require(json["id"]?.intValue)
                return try MiIOPacket.encode(
                    deviceId: header.deviceId, stamp: header.stamp, token: tokenData,
                    payload: Data("{\"id\":\(id),\"result\":[]}".utf8)
                )
            }
            probeTransport = MockUDPTransport(handler: probeReply)
            let records = (includeOnline ? [online] : []) + (candidates ?? [offline])
            cloud = HybridMockCloudAPI(devices: records, rooms: Self.rooms(records))
            let localClient = LocalMiIOClient(
                transport: normalTransport, maxRetries: 0, reachabilityTransport: probeTransport
            )
            provider = MiCloudProvider(
                sessionLoader: { [session] in session.withValue { $0 } },
                apiFactory: { [cloud] _ in cloud },
                specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
                localClient: localClient, now: { [clock] in clock.now() },
                pollInterval: .seconds(3600), closedPollInterval: .seconds(3600),
                selectedHomeLoader: { [home] in home.withValue { $0 } }
            )
            events = Task { [provider, collector] in
                for await event in provider.events() { await collector.append(event) }
                await collector.finish()
            }
        }

        static func rooms(_ records: [MiDeviceRecord]) -> [MiRoom] {
            [MiRoom(id: "room", name: "Room", dids: records.map(\.did), homeId: "mine"),
             MiRoom(id: "other-room", name: "Other room", dids: [], homeId: "other")]
        }

        func replaceRecords(_ records: [MiDeviceRecord]) async {
            await cloud.setTopology(devices: records, rooms: Self.rooms(records))
        }

        func waitForInitialPoll() async throws {
            let connected = await collector.wait { $0.statuses.last == .connected }
            try #require(connected)
        }

        func stop() async {
            await provider.shutdown()
            await events.value
        }
    }

    @Test func publishesReadOnlyHelloWithoutEnablingControlAndLimitsRepeatProbes() async throws {
        let fixture = try Fixture()
        try await fixture.waitForInitialPoll()
        let snapshot = try #require(await fixture.collector.snapshots.last)
        let diagnostics = try #require(snapshot.deviceTransportDiagnostics[Self.offlineDID])
        #expect(diagnostics.route == .cloud)
        #expect(diagnostics.offlineLANReachability?.expiresAt == fixture.clock.now().addingTimeInterval(300))
        #expect(snapshot.devices.first { $0.id == Self.offlineDID }?.isOnline == false)
        let eligibility = await fixture.provider.writeEligibility(
            for: .setLightPower(entityId: "miot:102:2:1", isOn: true), did: Self.offlineDID
        )
        #expect(eligibility.confirmed)
        #expect(!eligibility.canExecute)
        #expect(await fixture.provider.lanTransportState(for: Self.offlineDID).lastRTTMs == nil)

        fixture.clock.advance(by: 299)
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.count == 1)
        fixture.clock.advance(by: 1)
        await fixture.provider.refreshNow()
        let sends = await fixture.probeTransport.sends
        #expect(sends.map(\.packet) == [MiIOPacket.helloPacket, MiIOPacket.helloPacket])
        #expect(sends.allSatisfy { $0.host == fixture.offline.localIp && $0.port == 54321 })
        #expect(await fixture.probeTransport.broadcastCalls == 0)
        #expect(await fixture.cloud.setPropsCalls.isEmpty)
        #expect(await fixture.cloud.actionCalls.isEmpty)
        await fixture.stop()
    }

    @Test func skipsUnownedSharedSplitAndInvalidEndpoints() async throws {
        let candidates = [
            Self.record("102", token: nil), Self.record("103", ip: nil),
            Self.record("104", ip: "8.8.8.8"), Self.record("105", token: "bad"),
            Self.record("106", shared: true), Self.record("107", shared: nil),
            Self.record("108", splitParent: "110"), Self.record("109", pid: 6),
            Self.record("group.102"), Self.record("lumi.102")
        ]
        let fixture = try Fixture(candidates: candidates)
        try await fixture.waitForInitialPoll()
        #expect(await fixture.probeTransport.sends.isEmpty)
        await fixture.stop()
    }

    @Test(arguments: [nil, MiIOError.localNetworkDenied] as [MiIOError?])
    func skipsUnknownOrDeniedPermission(authorization: MiIOError?) async throws {
        let fixture = try Fixture(includeOnline: false, authorization: authorization)
        try await fixture.waitForInitialPoll()
        #expect(await fixture.probeTransport.sends.isEmpty)
        await fixture.stop()
    }

    @Test(arguments: [MiIOError.timeout, MiIOError.malformedPacket, MiIOError.localNetworkDenied])
    func unsuccessfulProbesKeepUnknownAndAreRateLimited(error: MiIOError) async throws {
        let fixture = try Fixture { _, _, _ in
            if error == .malformedPacket { return makeHelloResponse(deviceId: 222, stamp: 10) }
            throw error
        }
        try await fixture.waitForInitialPoll()
        await fixture.replaceRecords([fixture.offline])
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.map(\.packet) == [MiIOPacket.helloPacket])
        #expect(await fixture.collector.snapshots.allSatisfy {
            $0.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability == nil
        })
        if error == .localNetworkDenied {
            fixture.clock.advance(by: 301)
            await fixture.provider.refreshNow()
            #expect(await fixture.probeTransport.sends.count == 1)
        }
        await fixture.stop()
    }

    @Test func onlineRecoveryAndHomeSwitchDiscardEvidence() async throws {
        let fixture = try Fixture()
        try await fixture.waitForInitialPoll()
        let reachable = await fixture.collector.snapshots.last?.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability
        #expect(reachable != nil)

        fixture.home.withValue { $0 = "other" }
        await fixture.provider.refreshNow()
        fixture.home.withValue { $0 = "mine" }
        await fixture.provider.refreshNow()
        let afterHomeSwitch = await fixture.collector.snapshots.count
        let switched = await fixture.collector.wait {
            $0.snapshots.count >= afterHomeSwitch && $0.snapshots.last?.devices.contains { $0.id == Self.offlineDID } == true
        }
        #expect(switched)
        #expect(await fixture.collector.snapshots.last?.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability == nil)
        #expect(await fixture.probeTransport.sends.count == 1)

        fixture.clock.advance(by: 301)
        await fixture.provider.refreshNow()
        let probedAgain = await fixture.collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability != nil
        }
        #expect(probedAgain)
        let recovered = Self.record(Self.offlineDID, online: true)
        await fixture.replaceRecords([fixture.online, recovered])
        await fixture.provider.refreshNow()
        let online = await fixture.collector.wait {
            $0.snapshots.last?.devices.contains { $0.id == Self.offlineDID && $0.isOnline } == true
        }
        #expect(online)
        #expect(await fixture.collector.snapshots.last?.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability == nil)
        #expect(await fixture.probeTransport.sends.count == 2)
        await fixture.stop()
    }

    @Test(arguments: ["network", "account", "sleep"])
    func discardsInFlightResultsOnContextChangeWithoutDuplicateRequests(change: String) async throws {
        let gate = ProbeConcurrencyGate(expectedParkedProbes: 1)
        let fixture = try Fixture { _, _, _ in
            await gate.park()
            return makeHelloResponse(deviceId: 102, stamp: 10)
        }
        await gate.waitUntilAllParked()
        await fixture.provider.refreshNow()
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.count == 1)
        switch change {
        case "network":
            var context = PollingContext()
            context.haTransportRevision = 1
            await fixture.provider.setPollingContext(context)
        case "account":
            fixture.session.withValue { $0 = nil }
        default:
            await fixture.provider.setPollingContext(PollingContext(systemActive: false))
        }
        await gate.release()
        try await fixture.waitForInitialPoll()
        #expect(await fixture.probeTransport.sends.map(\.packet) == [MiIOPacket.helloPacket])
        #expect(await fixture.collector.snapshots.allSatisfy {
            $0.deviceTransportDiagnostics[Self.offlineDID]?.offlineLANReachability == nil
        })
        await fixture.stop()
    }

    @Test func skipsProbingDuringCloudRateLimit() async throws {
        let fixture = try Fixture(candidates: [])
        try await fixture.waitForInitialPoll()
        await fixture.replaceRecords([fixture.online, fixture.offline])
        await fixture.cloud.setGetPropsError(MiCloudError.http(429))
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.isEmpty)
        await fixture.cloud.setGetPropsError(nil)
        fixture.clock.advance(by: 59)
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.isEmpty)
        fixture.clock.advance(by: 1)
        await fixture.provider.refreshNow()
        #expect(await fixture.probeTransport.sends.count == 1)
        await fixture.stop()
    }
}


private final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}
