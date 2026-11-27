import CryptoKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Network)
import Network
#endif
@testable import MijiaCore

actor MockUDPTransport: MiIOUDPTransport {
    struct RecordedSend: Sendable {
        let packet: Data
        let host: String
        let port: UInt16
    }

    private var handler: @Sendable (Data, String, UInt16) async throws -> Data
    private var broadcastHandler: @Sendable (Data, UInt16, Duration) async throws -> [MiIOBroadcastReply] = { _, _, _ in [] }
    private(set) var sends: [RecordedSend] = []
    private(set) var broadcastCalls = 0
    private(set) var shutdownCount = 0

    init(handler: @escaping @Sendable (Data, String, UInt16) async throws -> Data) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping @Sendable (Data, String, UInt16) async throws -> Data) {
        self.handler = handler
    }

    func setBroadcastHandler(_ handler: @escaping @Sendable (Data, UInt16, Duration) async throws -> [MiIOBroadcastReply]) {
        self.broadcastHandler = handler
    }

    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        sends.append(RecordedSend(packet: packet, host: host, port: port))
        return try await handler(packet, host, port)
    }

    func probeBroadcast(_ packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply] {
        broadcastCalls += 1
        return try await broadcastHandler(packet, port, timeout)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

/// Rendezvous for a bounded-concurrency assertion. Unresponsive probes park here until the sampling
/// probe has observed them, and the sampler waits until every parked probe has arrived, so neither side
/// depends on which task the cooperative pool runs first and no test needs to sleep against a product timer.
actor ProbeConcurrencyGate {
    private let expectedParkedProbes: Int
    private var parkedProbes = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var isAbandoned = false

    init(expectedParkedProbes: Int) {
        self.expectedParkedProbes = max(1, expectedParkedProbes)
    }

    /// Counts the caller as in flight and holds it until the sampler releases it.
    func park() async {
        parkedProbes += 1
        if parkedProbes >= expectedParkedProbes {
            resumeAll(&arrivalWaiters)
        }
        guard !isReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseWaiters.append($0) }
        } onCancel: {
            Task { await self.release() }
        }
    }

    /// Blocks until every expected probe is parked, so the caller samples a complete in-flight set.
    /// Returns early when the caller is cancelled; the count assertion then fails instead of hanging.
    func waitUntilAllParked() async {
        while parkedProbes < expectedParkedProbes && !isAbandoned {
            await withTaskCancellationHandler {
                await withCheckedContinuation { arrivalWaiters.append($0) }
            } onCancel: {
                Task { await self.abandon() }
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        resumeAll(&releaseWaiters)
    }

    private func abandon() {
        isAbandoned = true
        resumeAll(&arrivalWaiters)
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor HybridMockCloudAPI: MiCloudAPI {
    var devicesList: [MiDeviceRecord]
    var roomsList: [MiRoom]
    var propsByKey: [MiotPropKey: JSONValue]
    var homeDevicesByHomeId: [String: [MiDeviceRecord]]
    var doorbellLatest: [String: Date] = [:]
    var getPropsError: (any Error)?
    var discoveryError: (any Error)?
    private var getPropsHook: (@Sendable ([MiotPropKey]) async throws -> Void)?

    private(set) var deviceListCalls = 0
    private(set) var homeRoomsCalls = 0
    private(set) var getPropsCalls: [[MiotPropKey]] = []
    private(set) var setPropsCalls: [[MiotPropWrite]] = []
    private(set) var actionCalls: [MiotActionCall] = []
    private(set) var doorbellQueries: [(did: String, eventKey: String, since: Date, now: Date)] = []
    private(set) var shutdownCount = 0

    init(
        devices: [MiDeviceRecord],
        rooms: [MiRoom],
        props: [MiotPropKey: JSONValue] = [:],
        homeDevicesByHomeId: [String: [MiDeviceRecord]] = [:]
    ) {
        self.devicesList = devices
        self.roomsList = rooms
        self.propsByKey = props
        self.homeDevicesByHomeId = homeDevicesByHomeId
    }

    func setDoorbellLatest(did: String, eventKey: String, date: Date?) {
        let key = "\(did)#\(eventKey)"
        doorbellLatest[key] = date
    }

    func setCloudProp(_ key: MiotPropKey, value: JSONValue) {
        propsByKey[key] = value
    }

    func setGetPropsError(_ error: (any Error)?) {
        getPropsError = error
    }

    func setGetPropsHook(_ hook: (@Sendable ([MiotPropKey]) async throws -> Void)?) {
        getPropsHook = hook
    }

    func setDiscoveryError(_ error: (any Error)?) {
        discoveryError = error
    }

    func setTopology(devices: [MiDeviceRecord], rooms: [MiRoom]) {
        devicesList = devices
        roomsList = rooms
    }

    func deviceList() async throws -> [MiDeviceRecord] {
        deviceListCalls += 1
        if let discoveryError { throw discoveryError }
        return devicesList
    }

    func homeRooms() async throws -> [MiRoom] {
        homeRoomsCalls += 1
        if let discoveryError { throw discoveryError }
        return roomsList
    }
    func homeDevices(homeId: String, ownerUid: String) async throws -> [MiDeviceRecord] {
        homeDevicesByHomeId[homeId] ?? []
    }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        getPropsCalls.append(keys)
        if let getPropsHook {
            try await getPropsHook(keys)
        }
        if let getPropsError {
            throw getPropsError
        }
        var result: [MiotPropKey: JSONValue] = [:]
        for key in keys {
            if let value = propsByKey[key] {
                result[key] = value
            }
        }
        return result
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {
        setPropsCalls.append(writes)
        for write in writes {
            propsByKey[MiotPropKey(did: write.did, siid: write.siid, piid: write.piid)] = write.value
        }
    }

    func action(_ call: MiotActionCall) async throws {
        actionCalls.append(call)
    }

    func doorbellLatestEventTimestamp(did: String, eventKey: String, since: Date, now: Date) async throws -> Date? {
        doorbellQueries.append((did: did, eventKey: eventKey, since: since, now: now))
        return doorbellLatest["\(did)#\(eventKey)"]
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

struct HybridMockSpecSource: MiotSpecSource {
    let specs: [String: MiotDeviceSpec]
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        specs[model]
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        self.current = initial
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

actor EventCollector {
    struct State: Sendable {
        var snapshots: [SynthesizedHome] = []
        var doorbellRings: [DoorbellRing] = []
        var statuses: [ConnectionStatus] = []
        var localNetworkPermissions: [Set<LocalNetworkBlockedFeature>] = []
        var isFinished = false
    }

    private struct Waiter {
        let id: UUID
        let predicate: @Sendable (State) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var state = State()
    private var waiters: [Waiter] = []

    var snapshots: [SynthesizedHome] { state.snapshots }
    var doorbellRings: [DoorbellRing] { state.doorbellRings }
    var statuses: [ConnectionStatus] { state.statuses }
    var localNetworkPermissions: [Set<LocalNetworkBlockedFeature>] { state.localNetworkPermissions }

    func append(_ event: HomeProviderEvent) {
        switch event {
        case .snapshotUpdated(let home):
            state.snapshots.append(home)
        case .doorbellRang(let ring):
            state.doorbellRings.append(ring)
        case .statusChanged(let status):
            state.statuses.append(status)
        case .localNetworkPermissionChanged(let blocked):
            state.localNetworkPermissions.append(blocked)
        case .miotTypePruneChanged, .haTypePruneChanged:
            break
        case .sessionExpired, .sourceStatusesChanged:
            break
        }
        resolveMatchingWaiters()
    }

    func finish() {
        state.isFinished = true
        resolveMatchingWaiters()
        let remaining = waiters
        waiters.removeAll()
        for waiter in remaining {
            waiter.continuation.resume(returning: waiter.predicate(state))
        }
    }

    /// Parks deterministically on a continuation until `predicate` holds (zero wall-clock polling).
    func wait(until predicate: @escaping @Sendable (State) -> Bool) async -> Bool {
        if predicate(state) { return true }
        if state.isFinished { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if predicate(state) {
                    continuation.resume(returning: true)
                    return
                }
                if state.isFinished {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func resolveMatchingWaiters() {
        var stillWaiting: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(state) {
                waiter.continuation.resume(returning: true)
            } else {
                stillWaiting.append(waiter)
            }
        }
        waiters = stillWaiting
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }
}

private actor MirrorHTTPStub: MiHTTPTransport {
    private var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private(set) var requestedURLs: [String] = []

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestedURLs.append(request.url?.absoluteString ?? "")
        return try await handler(request)
    }
}

func makeHelloResponse(deviceId: UInt32, stamp: UInt32) -> Data {
    makeHelloResponse64(unknown: 0, deviceId: deviceId, stamp: stamp)
}

func makeHelloResponse64(
    unknown: UInt32,
    deviceId: UInt32,
    stamp: UInt32,
    tokenForChecksum: Data? = nil
) -> Data {
    var packet = Data([0x21, 0x31, 0x00, 0x20])
    var unkBE = unknown.bigEndian
    var didBE = deviceId.bigEndian
    var stampBE = stamp.bigEndian
    packet.append(Data(bytes: &unkBE, count: 4))
    packet.append(Data(bytes: &didBE, count: 4))
    packet.append(Data(bytes: &stampBE, count: 4))
    if let tokenForChecksum {
        packet.append(Data(Insecure.MD5.hash(data: packet + tokenForChecksum)))
    } else {
        packet.append(Data(repeating: 0xFF, count: 16))
    }
    return packet
}

func lightSpec() -> MiotDeviceSpec {
    MiotDeviceSpec(
        type: "urn:miot-spec-v2:device:light:0000A001:yeelink-color4:1",
        services: [
            MiotService(
                iid: 2,
                type: "urn:miot-spec-v2:service:light:00007802:yeelink-color4:1",
                properties: [
                    MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-color4:1", format: "bool", access: ["read", "write", "notify"]),
                    MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-color4:1", format: "uint8", access: ["read", "write", "notify"], valueRange: [1, 100, 1]),
                ]
            )
        ]
    )
}

private func lightWithNotifyActionSpec() -> MiotDeviceSpec {
    var spec = lightSpec()
    spec.services.append(
        MiotService(
            iid: 7,
            type: "urn:miot-spec-v2:service:intelligent-speaker:0000789B:yeelink-color4:1",
            properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:text-content:000000FA:yeelink-color4:1", format: "string", access: [])
            ],
            actions: [
                MiotAction(iid: 3, type: "urn:miot-spec-v2:action:play-text:00002841:yeelink-color4:1", description: "Play Text", inputProperties: [1])
            ]
        )
    )
    return spec
}

private func doorbellSpec() -> MiotDeviceSpec {
    MiotDeviceSpec(
        type: "urn:miot-spec-v2:device:video-doorbell:0000A03A:madv-mjml06:1",
        services: [
            MiotService(
                iid: 2,
                type: "urn:miot-spec-v2:service:video-doorbell:00007867:madv-mjml06:1",
                properties: [
                    MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:madv-mjml06:1", format: "bool", access: ["read", "notify"]),
                ],
                events: [
                    MiotEvent(iid: 1, type: "urn:miot-spec-v2:event:doorbell-ring:00005013:madv-mjml06:1", description: "Doorbell Ring"),
                ]
            )
        ]
    )
}

// MARK: - Packet & Crypto Tests

@Suite("miIO Packet, Crypto, Sanitizer & Chunking")
struct MiIOPacketAndCryptoTests {
    private let sampleTokenHex = "00112233445566778899aabbccddeeff"

    @Test("HELLO packet matches 32-byte miIO discovery wire format")
    func helloPacketLayout() {
        let hello = MiIOPacket.helloPacket
        #expect(hello.count == 32)
        #expect([UInt8](hello.prefix(4)) == [0x21, 0x31, 0x00, 0x20])
        #expect(hello.dropFirst(4).allSatisfy { $0 == 0xFF })
    }

    @Test("Token validation accepts valid 32-hex tokens and rejects bad/all-00/all-ff tokens")
    func tokenValidation() throws {
        let valid = try #require(MiIOPacket.validateToken("  \(sampleTokenHex.uppercased()) \n"))
        #expect(valid.count == 16)
        #expect(MiIOPacket.validateToken("00000000000000000000000000000000") == nil)
        #expect(MiIOPacket.validateToken("ffffffffffffffffffffffffffffffff") == nil)
        #expect(MiIOPacket.validateToken("0011223344556677") == nil)
        #expect(MiIOPacket.validateToken("00112233445566778899aabbccddeefz") == nil)
    }

    @Test("MD5 key/IV derivation and AES-128-CBC roundtrip match pure-Swift FIPS-197 fallback")
    func keyDerivationAndPureSwiftParity() throws {
        let token = try #require(MiIOPacket.validateToken(sampleTokenHex))
        let (key, iv) = try MiIOCrypto.deriveKeyAndIV(token: token)
        #expect(key == Data(Insecure.MD5.hash(data: token)))
        var expectedIVInput = key
        expectedIVInput.append(token)
        #expect(iv == Data(Insecure.MD5.hash(data: expectedIVInput)))

        let plaintexts: [Data] = [
            Data("{}".utf8),
            Data("0123456789abcdef".utf8), // exact 16-byte block boundary
            Data(#"{"id":1,"method":"get_properties","params":[{"did":"123","siid":2,"piid":1}]}"#.utf8),
        ]
        for pt in plaintexts {
            let platformCipher = try MiIOCrypto.encryptAES128CBC(pt, key: key, iv: iv)
            let pureSwiftCipher = try MiIOCrypto.pureSwiftEncryptAES128CBC(pt, key: key, iv: iv)
            #expect(platformCipher == pureSwiftCipher)
            #expect(try MiIOCrypto.decryptAES128CBC(platformCipher, key: key, iv: iv) == pt)
            #expect(try MiIOCrypto.pureSwiftDecryptAES128CBC(platformCipher, key: key, iv: iv) == pt)
        }
    }

    @Test("NIST SP 800-38A F.2.1 AES-128-CBC vector matches pure-Swift AES implementation")
    func nistAES128CBCVector() throws {
        // First 16-byte plaintext block from NIST SP 800-38A F.2.1 (with PKCS7 second block appended).
        let key = Data([
            0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
            0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
        ])
        let iv = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        ])
        let block1 = Data([
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
            0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        ])
        let expectedFirstCipherBlock = Data([
            0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46,
            0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d,
        ])
        let cipher = try MiIOCrypto.pureSwiftEncryptAES128CBC(block1, key: key, iv: iv)
        #expect(cipher.prefix(16) == expectedFirstCipherBlock)
        #expect(try MiIOCrypto.pureSwiftDecryptAES128CBC(cipher, key: key, iv: iv) == block1)
    }

    @Test("miIO binary packet encode/decode verifies header, payload, and tamper detection")
    func packetEncodeDecodeAndChecksum() throws {
        let token = try #require(MiIOPacket.validateToken(sampleTokenHex))
        let payload = Data(#"{"id":101,"result":[{"did":"987654","siid":2,"piid":1,"value":true,"code":0}]}"#.utf8)
        let packet = try MiIOPacket.encode(deviceId: 0x1234_5678, stamp: 42, token: token, payload: payload)
        let decoded = try MiIOPacket.decode(packet, token: token)
        #expect(decoded.header.magic == 0x2131)
        #expect(decoded.header.length == UInt16(packet.count))
        #expect(decoded.header.deviceId == 0x1234_5678)
        #expect(decoded.header.stamp == 42)
        #expect(decoded.payload == payload)

        var tampered = packet
        tampered[packet.count - 1] ^= 0x01
        #expect(throws: MiIOError.checksumMismatch) {
            _ = try MiIOPacket.decode(tampered, token: token)
        }
    }

    @Test("UDP batch chunking splits 29 items into 12, 12, 5")
    func batchChunking() {
        let keys = (1...29).map { MiotPropKey(did: "123", siid: 2, piid: $0) }
        let chunks = MiIOPacket.chunked(keys)
        #expect(chunks.map(\.count) == [12, 12, 5])
        #expect(chunks.flatMap { $0 } == keys)
    }

    @Test("cleanMalformedFirmwareJSON repairs firmware defects without corrupting valid string literals")
    func malformedFirmwareJSONSanitizer() throws {
        let dirty = "{\"name\":\"time 12:00,, ok,\",\"empty\":,,\"obj\":{\"a\":1,,\"b\":2,},\"arr\":[1,,2,],\"bad\":00,\"num\":007,\"tail\":1,}\u{00}\u{01}"
        let cleaned = cleanMalformedFirmwareJSON(dirty)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(cleaned.utf8))
        #expect(parsed["name"] == .string("time 12:00,, ok,"))
        #expect(parsed["empty"] == .null)
        #expect(parsed["obj"] == .object(["a": .number(1), "b": .number(2)]))
        #expect(parsed["arr"] == .array([.number(1), .null, .number(2)]))
        #expect(parsed["bad"] == .number(0))
        #expect(parsed["num"] == .number(7))
        #expect(parsed["tail"] == .number(1))

        let stringOnlyQuirks = #"{"msg":"keep 00, :00, ,, and ,] verbatim","nested":["a,,b",":00"]}"#
        #expect(cleanMalformedFirmwareJSON(stringOnlyQuirks) == stringOnlyQuirks)
    }

    @Test("Seeded property fuzz test preserves arbitrary string literals and produces no crashes")
    func cleanMalformedFirmwareJSONFuzz() throws {
        let fragments = ["a", ":00", ",,", ",}", ",]", "\\\"", "00", "hello:00,,world", "{", "}"]
        for iteration in 0..<60 {
            let seed = FuzzSupport.iterationSeed(FuzzSupport.baseSeed, iteration)
            var rng = SeededFuzzGenerator(seed: seed)

            var rawString = ""
            let fragCount = rng.int(in: 1...5)
            for _ in 0..<fragCount {
                rawString += fragments[rng.int(in: 0...(fragments.count - 1))]
            }
            let escaped = rawString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let malformedDoc = "{\"s\":\"\(escaped)\",\"arr\":[1,,2,],\"z\":00,}\0"
            let cleaned = cleanMalformedFirmwareJSON(malformedDoc)
            do {
                let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(cleaned.utf8))
                guard decoded["s"] == .string(rawString) else {
                    Issue.record("seed=\(FuzzSupport.baseSeed) iteration=\(iteration) input=\(FuzzSupport.hex(Data(malformedDoc.utf8))) decoded=\(decoded)")
                    return
                }
            } catch {
                Issue.record("seed=\(FuzzSupport.baseSeed) iteration=\(iteration) input=\(FuzzSupport.hex(Data(malformedDoc.utf8))) error=\(error)")
                return
            }

            // Arbitrary byte/UTF-8 noise must never trap.
            let rawBytes = rng.bytes(count: rng.int(in: 1...32))
            let noisy = String(decoding: rawBytes, as: UTF8.self)
            _ = cleanMalformedFirmwareJSON(noisy)
        }
    }
}

// MARK: - LocalMiIOClient Tests

@Suite("LocalMiIOClient UDP Protocol", .timeLimit(.minutes(2)))
struct LocalMiIOClientTests {
    private let validTokenHex = "00112233445566778899aabbccddeeff"
    private let testEndpoint = MiIODeviceEndpoint(did: "12345678", ip: "192.168.1.10", token: "00112233445566778899aabbccddeeff")

    private static func frozenDiscoveryClock(
        now: LockedBox<ContinuousClock.Instant> = LockedBox(ContinuousClock.now)
    ) -> LocalMiIOClient.DiscoveryClock {
        LocalMiIOClient.DiscoveryClock(
            now: { now.withValue { $0 } },
            sleep: { _ in
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in stream {}
            }
        )
    }

    @Test("Handshake tracks stamp skew + monotonic increments, encodes integer JSON values, and chunks >12 props")
    func handshakePropsChunkingAndCompactJSON() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(validTokenHex))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let capturedPackets = LockedBox<[Data]>([])
        let capturedRequests = LockedBox<[String]>([])

        let transport = MockUDPTransport { packet, host, port in
            #expect(host == "192.168.1.10")
            #expect(port == 54321)
            capturedPackets.withValue { $0.append(packet) }

            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x0102_0304, stamp: 500)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqText = String(data: plaintext, encoding: .utf8) ?? ""
            capturedRequests.withValue { $0.append(reqText) }
            let reqJSON = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = reqJSON["id"]?.intValue ?? 0
            let method = reqJSON["method"]?.stringValue ?? ""

            let replyJSON: String
            switch method {
            case "get_properties":
                let params = reqJSON["params"]?.arrayValue ?? []
                let items: [String] = params.compactMap { item in
                    guard let did = item["did"]?.stringValue,
                          let siid = item["siid"]?.intValue,
                          let piid = item["piid"]?.intValue else { return nil }
                    return #"{"did":"\#(did)","siid":\#(siid),"piid":\#(piid),"value":\#(piid * 10),"code":0}"#
                }
                // Deliberately include firmware trailing comma to verify sanitizer path in LocalMiIOClient.
                replyJSON = #"{"id":\#(reqId),"result":[\#(items.joined(separator: ",")),]}"# + "\0"
            case "set_properties":
                let params = reqJSON["params"]?.arrayValue ?? []
                let items: [String] = params.compactMap { item in
                    guard let did = item["did"]?.stringValue,
                          let siid = item["siid"]?.intValue,
                          let piid = item["piid"]?.intValue else { return nil }
                    return #"{"did":"\#(did)","siid":\#(siid),"piid":\#(piid),"code":0}"#
                }
                replyJSON = #"{"id":\#(reqId),"result":[\#(items.joined(separator: ","))]}"#
            case "action":
                replyJSON = #"{"id":\#(reqId),"result":{"code":0,"out":["ok"]}}"#
            default:
                replyJSON = #"{"id":\#(reqId),"error":{"code":-32601,"message":"unknown"}}"#
            }
            return try MiIOPacket.encode(
                deviceId: header.deviceId,
                stamp: header.stamp,
                token: tokenData,
                payload: Data(replyJSON.utf8)
            )
        }

        let client = LocalMiIOClient(
            transport: transport,
            maxRetries: 1,
            maxBatchSize: 12,
            now: { clock.now() }
        )

        let info = try await client.handshake(for: testEndpoint)
        #expect(info.deviceId32 == 0x0102_0304)
        #expect(info.deviceStamp == 500)

        // Advance clock by 0s for first 14 props -> 2 chunks (12 + 2), stamps must be monotonic (500, 501).
        let keys = (1...14).map { MiotPropKey(did: "12345678", siid: 2, piid: $0) }
        let readValues = try await client.getProps(keys, endpoint: testEndpoint)
        #expect(readValues.count == 14)
        #expect(readValues[MiotPropKey(did: "12345678", siid: 2, piid: 14)] == .number(140))

        // Advance clock by 5s -> stamp jumps to 505, and compactJSONString sends "40" (not "40.0").
        clock.advance(by: 5)
        try await client.setProps([MiotPropWrite(did: "12345678", siid: 2, piid: 2, value: .number(40))], endpoint: testEndpoint)

        let actionOut = try await client.callAction(MiotActionCall(did: "12345678", siid: 2, aiid: 1, inputs: [.number(7)]), endpoint: testEndpoint)
        #expect(actionOut["code"] == .number(0))

        let headers = try capturedPackets.withValue { packets in
            try packets.dropFirst().map { try MiIOPacket.decodeHeader($0) }
        }
        #expect(headers.map(\.stamp) == [500, 501, 505, 506])

        let sentSetRequest = capturedRequests.withValue { $0.first { $0.contains("set_properties") } } ?? ""
        #expect(sentSetRequest.contains(#""value":40"#))
        #expect(!sentSetRequest.contains("40.0"))

        await client.shutdown()
        await client.shutdown() // idempotent
        #expect(await transport.shutdownCount == 1)
    }

    @Test("Token rejection and bounded retry with re-handshake on timeout")
    func invalidTokenAndRetryOnTimeout() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(validTokenHex))
        let attemptCounter = LockedBox(0)

        let transport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x0A0B_0C0D, stamp: 100)
            }
            let attempt = attemptCounter.withValue { val -> Int in
                val += 1
                return val
            }
            if attempt == 1 {
                throw MiIOError.timeout
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqJSON = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = reqJSON["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"12345678","siid":2,"piid":1,"value":true,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let client = LocalMiIOClient(transport: transport, maxRetries: 1)

        await #expect(throws: MiIOError.invalidToken) {
            _ = try await client.getProps(
                [MiotPropKey(did: "12345678", siid: 2, piid: 1)],
                endpoint: MiIODeviceEndpoint(did: "12345678", ip: "192.168.1.10", token: "00000000000000000000000000000000")
            )
        }

        let result = try await client.getProps([MiotPropKey(did: "12345678", siid: 2, piid: 1)], endpoint: testEndpoint)
        #expect(result[MiotPropKey(did: "12345678", siid: 2, piid: 1)] == .bool(true))
        #expect(await transport.sends.count == 4)
        await client.shutdown()
    }

    @Test("Rejects non-private IPv4, loopback, and hostname targets before sending UDP packets")
    func rejectsNonPrivateAddresses() async throws {
        let transport = MockUDPTransport { _, _, _ in
            Issue.record("Unexpected UDP send to non-private target")
            throw MiIOError.timeout
        }
        let client = LocalMiIOClient(transport: transport, maxRetries: 0)
        #if canImport(Network)
        let bsdTransport = BSDMiIOUDPTransport()
        #endif
        let rejectedHosts = ["192.0.2.10", "8.8.8.8", "127.0.0.1", "example.com"]

        for host in rejectedHosts {
            let endpoint = MiIODeviceEndpoint(did: "12345678", ip: host, token: validTokenHex)
            await #expect(throws: MiIOError.invalidAddress(host)) {
                _ = try await client.handshake(for: endpoint)
            }
            await #expect(throws: MiIOError.invalidAddress(host)) {
                _ = try await client.getProps([MiotPropKey(did: "12345678", siid: 2, piid: 1)], endpoint: endpoint)
            }
            await #expect(throws: MiIOError.invalidAddress(host)) {
                try await client.setProps([MiotPropWrite(did: "12345678", siid: 2, piid: 1, value: .bool(true))], endpoint: endpoint)
            }
            #if canImport(Network)
            await #expect(throws: MiIOError.invalidAddress(host)) {
                _ = try await bsdTransport.send(MiIOPacket.helloPacket, to: host, port: 54321, timeout: .milliseconds(50))
            }
            #endif
        }
        #expect(await transport.sends.isEmpty)
        #if canImport(Network)
        await bsdTransport.shutdown()
        #endif
        await client.shutdown()

        #expect(LocalMiIOClient.isPrivateRFC1918IPv4("192.168.1.0") == true)
        #expect(LocalMiIOClient.isPrivateRFC1918IPv4("172.16.0.255") == true)
        #expect(LocalMiIOClient.isPrivateRFC1918IPv4("172.32.0.1") == false)

        let wideSubnetTransport = MockUDPTransport { _, _, _ in
            makeHelloResponse(deviceId: 0x00BC_614E, stamp: 77)
        }
        let wideSubnetClient = LocalMiIOClient(transport: wideSubnetTransport, maxRetries: 0)
        for wideHost in ["192.168.1.0", "172.16.0.255"] {
            let endpoint = MiIODeviceEndpoint(did: "12345678", ip: wideHost, token: validTokenHex)
            let state = try await wideSubnetClient.handshake(for: endpoint)
            #expect(state.deviceId32 == 0x00BC_614E)
        }
        let wideSends = await wideSubnetTransport.sends
        #expect(wideSends.map { $0.host } == ["192.168.1.0", "172.16.0.255"])
        await wideSubnetClient.shutdown()
    }

    private func encodeRPCReply(_ packet: Data, token: Data, resultOrError: String, checkHeader: ((MiIOPacketHeader) -> Void)? = nil) throws -> Data {
        let (header, plaintext) = try MiIOPacket.decode(packet, token: token)
        checkHeader?(header)
        let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
        let reply = #"{"id":\#(req["id"]?.intValue ?? 0),\#(resultOrError)}"#
        return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: token, payload: Data(reply.utf8), unknown: header.unknown)
    }

    @Test("Broadcast discovery matches 64-bit DIDs, retained non-numeric hardware IDs across session evictions, and cold-start non-numeric responders with token verification")
    func broadcastDiscovery64BitRetainedHardwareIDsAndTokenVerification() async throws {
        let (token1Hex, token2Hex, token3Hex, wrongTokenHex) = ("00112233445566778899aabbccddeeff", "112233445566778899aabbccddeeff00", "2233445566778899aabbccddeeff0011", "ffeeddccbbaa99887766554433221100")
        let token1 = try #require(MiIOPacket.validateToken(token1Hex)), token2 = try #require(MiIOPacket.validateToken(token2Hex))
        let token3 = try #require(MiIOPacket.validateToken(token3Hex)), wrongToken = try #require(MiIOPacket.validateToken(wrongTokenHex))
        let did64Value: UInt64 = 1_099_511_628_211, did64String = String(did64Value)
        let did64Upper = UInt32(truncatingIfNeeded: did64Value >> 32), did64Lower = UInt32(truncatingIfNeeded: did64Value)

        #expect(MiIOPacket.helloChecksumMatches(makeHelloResponse64(unknown: did64Upper, deviceId: did64Lower, stamp: 10), token: token1) == nil)
        let keyedHello = makeHelloResponse64(unknown: 0, deviceId: 0x0A0B_0C0D, stamp: 20, tokenForChecksum: token2)
        #expect(MiIOPacket.helloChecksumMatches(keyedHello, token: token2) == true)
        #expect(MiIOPacket.helloChecksumMatches(keyedHello, token: wrongToken) == false)

        let lumiOldHostFails = LockedBox(false)
        let transport = MockUDPTransport { packet, host, _ in
            switch host {
            case "192.168.1.20":
                if lumiOldHostFails.withValue({ $0 }) { throw MiIOError.timeout }
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 0x0A0B_0C0D, stamp: 50) }
                return try self.encodeRPCReply(packet, token: token2, resultOrError: #""result":[{"did":"lumi.gateway.v3","siid":2,"piid":1,"value":true,"code":0}]"#)
            case "192.168.1.99": return try self.encodeRPCReply(packet, token: wrongToken, resultOrError: #""result":[]"#)
            case "192.168.1.101":
                return try self.encodeRPCReply(packet, token: token1, resultOrError: #""error":{"code":-4004,"message":"prop unsupported"}"#) { h in
                    #expect(h.unknown == did64Upper); #expect(h.deviceId == did64Lower)
                }
            case "192.168.1.102": return try self.encodeRPCReply(packet, token: token2, resultOrError: #""result":[{"did":"lumi.gateway.v3","siid":1,"piid":1,"value":"ok","code":0}]"#)
            case "192.168.1.103": return try self.encodeRPCReply(packet, token: token3, resultOrError: #""result":[{"did":"blt.cold.start","siid":1,"piid":1,"value":1,"code":0}]"#)
            default: throw MiIOError.timeout
            }
        }
        let client = LocalMiIOClient(transport: transport, maxRetries: 1)
        let lumiOldEndpoint = MiIODeviceEndpoint(did: "lumi.gateway.v3", ip: "192.168.1.20", token: token2Hex)
        let initialLumi = try await client.getProps([MiotPropKey(did: "lumi.gateway.v3", siid: 2, piid: 1)], endpoint: lumiOldEndpoint)
        #expect(initialLumi[MiotPropKey(did: "lumi.gateway.v3", siid: 2, piid: 1)] == .bool(true))
        #expect(await client.lastRoundTripMs(for: "lumi.gateway.v3") != nil)

        lumiOldHostFails.withValue { $0 = true }
        await #expect(throws: MiIOError.handshakeFailed) {
            _ = try await client.getProps([MiotPropKey(did: "lumi.gateway.v3", siid: 2, piid: 1)], endpoint: lumiOldEndpoint)
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.99", packet: makeHelloResponse64(unknown: did64Upper, deviceId: did64Lower, stamp: 300)),
                MiIOBroadcastReply(sourceIP: "192.168.1.101", packet: makeHelloResponse64(unknown: did64Upper, deviceId: did64Lower, stamp: 301)),
                MiIOBroadcastReply(sourceIP: "192.168.1.102", packet: makeHelloResponse(deviceId: 0x0A0B_0C0D, stamp: 400)),
                MiIOBroadcastReply(sourceIP: "192.168.1.103", packet: makeHelloResponse(deviceId: 0x0F0E_0D0C, stamp: 500)),
            ]
        }
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: did64String, token: token1Hex),
                MiIODeviceCandidate(did: "lumi.gateway.v3", token: token2Hex),
                MiIODeviceCandidate(did: "blt.cold.start", token: token3Hex),
            ],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == [did64String: "192.168.1.101", "lumi.gateway.v3": "192.168.1.102", "blt.cold.start": "192.168.1.103"])
        await client.shutdown()
    }

    @Test("Unauthenticated HELLO from a reassigned stale IP does not poison retained hardware IDs before encrypted auth succeeds")
    func unauthenticatedHelloDoesNotPoisonHardwareIdentity() async throws {
        let (tokenKnownHex, tokenColdHex, tokenStrangerHex) = ("112233445566778899aabbccddeeff00", "2233445566778899aabbccddeeff0011", "ffeeddccbbaa99887766554433221100")
        let tokenKnown = try #require(MiIOPacket.validateToken(tokenKnownHex)), tokenCold = try #require(MiIOPacket.validateToken(tokenColdHex))
        let tokenStranger = try #require(MiIOPacket.validateToken(tokenStrangerHex))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000)), staleHostReassigned = LockedBox(false)
        let transport = MockUDPTransport { packet, host, _ in
            switch host {
            case "192.168.1.20":
                if staleHostReassigned.withValue({ $0 }) {
                    if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 0xDEAD_BEEF, stamp: 60) }
                    return try MiIOPacket.encode(deviceId: 0xDEAD_BEEF, stamp: 61, token: tokenStranger, payload: Data(#"{"id":1,"result":[]}"#.utf8))
                }
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 0x0A0B_0C0D, stamp: 50) }
                return try self.encodeRPCReply(packet, token: tokenKnown, resultOrError: #""result":[{"did":"lumi.gateway.v3","siid":2,"piid":1,"value":true,"code":0}]"#)
            case "192.168.1.21":
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 0xCAFE_BABE, stamp: 70) }
                throw MiIOError.timeout
            case "192.168.1.102": return try self.encodeRPCReply(packet, token: tokenKnown, resultOrError: #""result":[{"did":"lumi.gateway.v3","siid":1,"piid":1,"value":"ok","code":0}]"#)
            case "192.168.1.103": return try self.encodeRPCReply(packet, token: tokenCold, resultOrError: #""result":[{"did":"blt.cold.reassigned","siid":1,"piid":1,"value":1,"code":0}]"#)
            default: throw MiIOError.timeout
            }
        }
        let client = LocalMiIOClient(transport: transport, maxRetries: 0, handshakeTTL: 10, now: { clock.now() })
        _ = try await client.getProps([MiotPropKey(did: "lumi.gateway.v3", siid: 2, piid: 1)], endpoint: MiIODeviceEndpoint(did: "lumi.gateway.v3", ip: "192.168.1.20", token: tokenKnownHex))
        clock.advance(by: 20); staleHostReassigned.withValue { $0 = true }
        await #expect(throws: MiIOError.checksumMismatch) {
            _ = try await client.getProps([MiotPropKey(did: "lumi.gateway.v3", siid: 2, piid: 1)], endpoint: MiIODeviceEndpoint(did: "lumi.gateway.v3", ip: "192.168.1.20", token: tokenKnownHex))
        }
        await #expect(throws: MiIOError.timeout) {
            _ = try await client.getProps([MiotPropKey(did: "blt.cold.reassigned", siid: 2, piid: 1)], endpoint: MiIODeviceEndpoint(did: "blt.cold.reassigned", ip: "192.168.1.21", token: tokenColdHex))
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.20", packet: makeHelloResponse(deviceId: 0xDEAD_BEEF, stamp: 80)),
                MiIOBroadcastReply(sourceIP: "192.168.1.21", packet: makeHelloResponse(deviceId: 0xCAFE_BABE, stamp: 81)),
                MiIOBroadcastReply(sourceIP: "192.168.1.102", packet: makeHelloResponse(deviceId: 0x0A0B_0C0D, stamp: 82)),
                MiIOBroadcastReply(sourceIP: "192.168.1.103", packet: makeHelloResponse(deviceId: 0x0F0E_0D0C, stamp: 83)),
            ]
        }
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "lumi.gateway.v3", token: tokenKnownHex),
                MiIODeviceCandidate(did: "blt.cold.reassigned", token: tokenColdHex),
            ],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == ["lumi.gateway.v3": "192.168.1.102", "blt.cold.reassigned": "192.168.1.103"])
        await client.shutdown()
    }

    @Test("64-bit numeric DIDs match unknown=0 or 0xFFFFFFFF low-32-bit HELLO replies only after encrypted token probe disambiguates collisions")
    func broadcastDiscovery64BitLow32TruncationAndCollisionSafety() async throws {
        let (tokenAHex, tokenBHex, tokenUnmatchedHex, tokenStrangerHex) = ("00112233445566778899aabbccddeeff", "112233445566778899aabbccddeeff00", "2233445566778899aabbccddeeff0011", "ffeeddccbbaa99887766554433221100")
        let tokenA = try #require(MiIOPacket.validateToken(tokenAHex)), tokenB = try #require(MiIOPacket.validateToken(tokenBHex))
        let tokenStranger = try #require(MiIOPacket.validateToken(tokenStrangerHex))
        let sharedLow32: UInt32 = 0x0000_01B3
        let didA = String((UInt64(2) << 32) | UInt64(sharedLow32)), didB = String((UInt64(5) << 32) | UInt64(sharedLow32)), didUnmatched = String((UInt64(9) << 32) | UInt64(sharedLow32))
        let transport = MockUDPTransport { packet, host, _ in
            let hostToken: Data = switch host {
            case "192.168.1.90": tokenStranger
            case "192.168.1.91": tokenB
            case "192.168.1.92": tokenA
            default: throw MiIOError.timeout
            }
            return try self.encodeRPCReply(packet, token: hostToken, resultOrError: #""result":[]"#)
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.90", packet: makeHelloResponse64(unknown: 0, deviceId: sharedLow32, stamp: 10)),
                MiIOBroadcastReply(sourceIP: "192.168.1.91", packet: makeHelloResponse64(unknown: 0, deviceId: sharedLow32, stamp: 11)),
                MiIOBroadcastReply(sourceIP: "192.168.1.92", packet: makeHelloResponse64(unknown: UInt32.max, deviceId: sharedLow32, stamp: 12)),
            ]
        }
        let client = LocalMiIOClient(transport: transport, maxRetries: 0)
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: didA, token: tokenAHex), MiIODeviceCandidate(did: didB, token: tokenBHex), MiIODeviceCandidate(did: didUnmatched, token: tokenUnmatchedHex),
            ],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == [didA: "192.168.1.92", didB: "192.168.1.91"])
        await client.shutdown()
    }

    @Test("Legacy HELLO with plaintext token checksum is not rejected early and still requires encrypted probe to bind")
    func legacyPlaintextTokenHelloAllowedToEncryptedProbe() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(validTokenHex))
        let legacyHello = Data(makeHelloResponse(deviceId: 501, stamp: 77).prefix(16)) + tokenData
        #expect(MiIOPacket.helloChecksumMatches(legacyHello, token: tokenData) == nil)
        #expect(MiIOPacket.helloChecksumMatches(legacyHello, token: Data(repeating: 0xAA, count: 16)) == false)
        let transport = MockUDPTransport { packet, host, _ in
            guard host == "192.168.1.95" else { throw MiIOError.timeout }
            return try self.encodeRPCReply(packet, token: tokenData, resultOrError: #""result":[]"#)
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.94", packet: Data(makeHelloResponse(deviceId: 502, stamp: 77).prefix(16)) + tokenData),
                MiIOBroadcastReply(sourceIP: "192.168.1.95", packet: legacyHello),
            ]
        }
        let client = LocalMiIOClient(transport: transport, maxRetries: 0)
        let discovered = try await client.discoverEndpoints(
            for: [MiIODeviceCandidate(did: "501", token: validTokenHex), MiIODeviceCandidate(did: "502", token: validTokenHex)],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == ["501": "192.168.1.95"])
        await client.shutdown()
    }

    @Test("Cold-start broadcast discovery recovers multiple non-numeric DIDs past crowded unrelated replies while bounding probe count and total duration and enforcing token verification")
    func crowdedColdStartNonNumericDiscoveryAndBoundedBudget() async throws {
        let tokenLumiHex = "00112233445566778899aabbccddeeff"
        let tokenBltHex = "fedcba98765432100123456789abcdef"
        let tokenLumi = try #require(MiIOPacket.validateToken(tokenLumiHex))
        let tokenBlt = try #require(MiIOPacket.validateToken(tokenBltHex))
        let wrongToken = Data(repeating: 0x5A, count: 16)

        let transport = MockUDPTransport { packet, host, _ in
            switch host {
            case "192.168.1.180":
                return try self.encodeRPCReply(packet, token: tokenLumi, resultOrError: #""result":[{"did":"lumi.curtain.v1","siid":1,"piid":1,"value":"aqara","code":0}]"#)
            case "192.168.1.181":
                return try self.encodeRPCReply(packet, token: tokenBlt, resultOrError: #""result":[{"did":"blt.3.sensor","siid":1,"piid":1,"value":"xiaomi","code":0}]"#)
            case "192.168.1.182":
                // Spoofed/wrong-token reply must never bind.
                return try self.encodeRPCReply(packet, token: wrongToken, resultOrError: #""result":[{"did":"lumi.curtain.v1","siid":1,"piid":1,"value":"spoof","code":0}]"#)
            default:
                throw MiIOError.timeout
            }
        }
        await transport.setBroadcastHandler { _, _, _ in
            var replies: [MiIOBroadcastReply] = []
            // 12 unrelated modern 0xFF-checksum devices precede the moved non-numeric devices.
            for idx in 1...12 {
                replies.append(MiIOBroadcastReply(sourceIP: "192.168.1.\(20 + idx)", packet: makeHelloResponse(deviceId: UInt32(1000 + idx), stamp: UInt32(50 + idx))))
            }
            replies.append(MiIOBroadcastReply(sourceIP: "192.168.1.182", packet: makeHelloResponse(deviceId: 0x0AAA_0003, stamp: 90)))
            replies.append(MiIOBroadcastReply(sourceIP: "192.168.1.180", packet: makeHelloResponse(deviceId: 0x0AAA_0001, stamp: 91)))
            replies.append(MiIOBroadcastReply(sourceIP: "192.168.1.181", packet: makeHelloResponse(deviceId: 0x0AAA_0002, stamp: 92)))
            return replies
        }

        let client = LocalMiIOClient(transport: transport, maxRetries: 0)
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "lumi.curtain.v1", token: tokenLumiHex),
                MiIODeviceCandidate(did: "blt.3.sensor", token: tokenBltHex),
            ],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == [
            "lumi.curtain.v1": "192.168.1.180",
            "blt.3.sensor": "192.168.1.181",
        ])
        await client.shutdown()

        // Also verify flood protection: 90 slow unresponsive replies must hit the duration budget
        // without exceeding the probe-count cap, driven by an injected virtual clock instead of sleeps.
        let floodStart = ContinuousClock.now
        let floodTime = LockedBox(floodStart)
        let floodProbes = LockedBox(0)
        let floodTransport = MockUDPTransport { _, _, _ in
            floodProbes.withValue { $0 += 1 }
            floodTime.withValue { $0 = $0.advanced(by: .milliseconds(120)) }
            throw MiIOError.timeout
        }
        await floodTransport.setBroadcastHandler { _, _, _ in
            (1...90).map { idx in
                MiIOBroadcastReply(sourceIP: "10.0.1.\(idx)", packet: makeHelloResponse(deviceId: UInt32(5000 + idx), stamp: 10))
            }
        }
        let floodClient = LocalMiIOClient(transport: floodTransport, handshakeTimeout: .milliseconds(500), maxRetries: 0)
        let floodResult = try await floodClient.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "lumi.flood.1", token: tokenLumiHex),
                MiIODeviceCandidate(did: "blt.flood.2", token: tokenBltHex),
            ],
            discoveryClock: Self.frozenDiscoveryClock(now: floodTime)
        )
        let floodElapsed = floodTime.withValue { $0 } - floodStart
        #expect(floodResult.isEmpty)
        #expect(floodProbes.withValue { $0 } > 0 && floodProbes.withValue { $0 } <= 64)
        #expect(floodElapsed < .seconds(4))
        await floodClient.shutdown()
    }

    @Test("Probe replies are never cancelled by a duplicate client-side timer, so scheduling latency cannot lose a device")
    func probeRepliesAreNotPreemptedByADuplicateClientTimeout() async throws {
        let tokenHex = "00112233445566778899aabbccddeeff"
        let token = try #require(MiIOPacket.validateToken(tokenHex))

        // The transport owns the per-probe timeout (`send(..., timeout:)`): a real transport fails the call
        // itself when the deadline passes. The client must not race a second timer against it, because that
        // timer cancels probes the cooperative pool has merely not scheduled yet, which is how a loaded
        // runner used to lose a device that had already answered. A reply that arrives after the client's
        // `handshakeTimeout` but inside the discovery budget therefore still binds.
        let probeTime = LockedBox(ContinuousClock.now)
        let waveSleepBudgets = LockedBox<[Duration]>([])
        let sleepStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let probeClock = LocalMiIOClient.DiscoveryClock(
            now: { probeTime.withValue { $0 } },
            sleep: { budget in
                waveSleepBudgets.withValue { $0.append(budget) }
                sleepStarted.continuation.yield(())
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in stream {}
            }
        )
        let transport = MockUDPTransport { packet, host, _ in
            guard host == "192.168.1.180" else { throw MiIOError.timeout }
            var started = sleepStarted.stream.makeAsyncIterator()
            _ = await started.next()
            probeTime.withValue { $0 = $0.advanced(by: .milliseconds(150)) }
            return try self.encodeRPCReply(
                packet,
                token: token,
                resultOrError: #""result":[{"did":"lumi.curtain.v1","siid":1,"piid":1,"value":"aqara","code":0}]"#
            )
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.30", packet: makeHelloResponse(deviceId: 900, stamp: 40)),
                MiIOBroadcastReply(sourceIP: "192.168.1.180", packet: makeHelloResponse(deviceId: 0x0AAA_0001, stamp: 41)),
            ]
        }

        let client = LocalMiIOClient(transport: transport, handshakeTimeout: .milliseconds(60), maxRetries: 0)
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "lumi.curtain.v1", token: tokenHex),
            ],
            discoveryClock: probeClock
        )
        #expect(discovered == ["lumi.curtain.v1": "192.168.1.180"])
        #expect(waveSleepBudgets.withValue { !$0.isEmpty && $0.allSatisfy { $0 > .milliseconds(60) } })
        await client.shutdown()
    }

    @Test("Matching probes cannot spend the whole unclaimed probe cap and starve non-numeric recovery")
    func matchingProbeCapReservesProbesForNonNumericRecovery() async throws {
        let tokenHexes = ["00112233445566778899aabbccddeeff", "112233445566778899aabbccddeeff00", "2233445566778899aabbccddeeff0011", "33445566778899aabbccddeeff001122"]
        let tokenLumiHex = "445566778899aabbccddeeff00112233"
        let tokens = try tokenHexes.map { try #require(MiIOPacket.validateToken($0)) }
        let tokenLumi = try #require(MiIOPacket.validateToken(tokenLumiHex))

        // Three numeric candidates, one retired non-numeric candidate, and a cap of four probes. Matching
        // replies are abundant, so unless the cap keeps a probe back for the reserved non-numeric slice the
        // `lumi.*` device is never probed even though the discovery budget still has time for it.
        let probedHosts = LockedBox<[String]>([])
        let transport = MockUDPTransport { packet, host, _ in
            probedHosts.withValue { $0.append(host) }
            switch host {
            case "192.168.1.41", "192.168.1.42", "192.168.1.43", "192.168.1.44":
                let index = Int(host.suffix(1)).map { $0 - 1 } ?? 0
                let did = String(101 + index)
                return try self.encodeRPCReply(packet, token: tokens[index], resultOrError: #""result":[{"did":"\#(did)","siid":1,"piid":1,"value":true,"code":0}]"#)
            case "192.168.1.45":
                return try self.encodeRPCReply(packet, token: tokenLumi, resultOrError: #""result":[{"did":"lumi.sensor.v1","siid":1,"piid":1,"value":1,"code":0}]"#)
            default:
                throw MiIOError.timeout
            }
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.41", packet: makeHelloResponse(deviceId: 101, stamp: 10)),
                MiIOBroadcastReply(sourceIP: "192.168.1.42", packet: makeHelloResponse(deviceId: 102, stamp: 11)),
                MiIOBroadcastReply(sourceIP: "192.168.1.43", packet: makeHelloResponse(deviceId: 103, stamp: 12)),
                MiIOBroadcastReply(sourceIP: "192.168.1.44", packet: makeHelloResponse(deviceId: 104, stamp: 13)),
                MiIOBroadcastReply(sourceIP: "192.168.1.45", packet: makeHelloResponse(deviceId: 0x0AAA_0009, stamp: 14)),
            ]
        }

        let client = LocalMiIOClient(
            transport: transport,
            handshakeTimeout: .milliseconds(200),
            maxRetries: 0,
            maxTotalUnclaimedProbes: 4
        )
        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "101", token: tokenHexes[0]),
                MiIODeviceCandidate(did: "102", token: tokenHexes[1]),
                MiIODeviceCandidate(did: "103", token: tokenHexes[2]),
                MiIODeviceCandidate(did: "104", token: tokenHexes[3]),
                MiIODeviceCandidate(did: "lumi.sensor.v1", token: tokenLumiHex),
            ],
            broadcastTimeout: .milliseconds(20),
            discoveryClock: Self.frozenDiscoveryClock()
        )

        #expect(discovered["lumi.sensor.v1"] == "192.168.1.45")
        #expect(probedHosts.withValue { $0.contains("192.168.1.45") })
        #expect(probedHosts.withValue { $0.count } <= 4)
        #expect(discovered.count == 4)
        await client.shutdown()
    }

    @Test("Token-echo HELLOs outrank unknown checksums so a truncated unclaimed probe queue keeps the real device")
    func tokenEchoHelloRanksAboveUnknownChecksumsInUnclaimedProbeQueue() async throws {
        let tokenLumiHex = "112233445566778899aabbccddeeff00"
        let tokenLumi = try #require(MiIOPacket.validateToken(tokenLumiHex))

        // Legacy miIO HELLOs echo the token in the 16-byte checksum field instead of carrying an MD5 digest.
        // That is the strongest per-candidate evidence a cold-start reply can hold, so the unclaimed probe
        // queue must rank it above unknown 0xFF/0x00 HELLOs and keep it when the per-candidate cap truncates.
        let tokenEchoHello = Data(makeHelloResponse(deviceId: 0x0AAA_0101, stamp: 70).prefix(16)) + tokenLumi
        let fillerReplies = (1...4).map { idx in
            MiIOBroadcastReply(sourceIP: "192.168.1.\(40 + idx)", packet: makeHelloResponse(deviceId: UInt32(7000 + idx), stamp: UInt32(10 + idx)))
        }

        let probedHosts = LockedBox<[String]>([])
        let transport = MockUDPTransport { packet, host, _ in
            probedHosts.withValue { $0.append(host) }
            guard host == "192.168.1.77" else { throw MiIOError.timeout }
            return try self.encodeRPCReply(packet, token: tokenLumi, resultOrError: #""result":[{"did":"lumi.sensor.v1","siid":1,"piid":1,"value":1,"code":0}]"#)
        }
        await transport.setBroadcastHandler { _, _, _ in
            fillerReplies + [MiIOBroadcastReply(sourceIP: "192.168.1.77", packet: tokenEchoHello)]
        }

        // A two-slot queue only keeps two replies, and the token-echo device is published last.
        let client = LocalMiIOClient(
            transport: transport,
            handshakeTimeout: .milliseconds(200),
            maxRetries: 0,
            maxUnclaimedProbesPerCandidate: 2
        )
        let discovered = try await client.discoverEndpoints(
            for: [MiIODeviceCandidate(did: "lumi.sensor.v1", token: tokenLumiHex)],
            discoveryClock: Self.frozenDiscoveryClock()
        )
        #expect(discovered == ["lumi.sensor.v1": "192.168.1.77"])
        #expect(probedHosts.withValue { $0.contains("192.168.1.77") })
        await client.shutdown()
    }

    @Test("Broadcast matching probes use bounded concurrency and preserve budget for non-numeric discovery without duplicate IP binding", .timeLimit(.minutes(1)))
    func broadcastDiscoveryMatchingConcurrencyAndNonNumericBudgetPreservation() async throws {
        let token1Hex = "00112233445566778899aabbccddeeff"
        let token2Hex = "112233445566778899aabbccddeeff00"
        let token3Hex = "2233445566778899aabbccddeeff0011"
        let token4Hex = "33445566778899aabbccddeeff001122"
        let tokenLumiHex = "445566778899aabbccddeeff00112233"
        let tokenCollisionHex = "5566778899aabbccddeeff0011223344"

        let token4 = try #require(MiIOPacket.validateToken(token4Hex))
        let tokenLumi = try #require(MiIOPacket.validateToken(tokenLumiHex))

        let sharedLow32: UInt32 = 0x0000_0404
        let did4 = String((UInt64(1) << 32) | UInt64(sharedLow32))
        let didCollision = String((UInt64(2) << 32) | UInt64(sharedLow32))

        // Concurrency is observed through a rendezvous gate, never a sleep: the three unresponsive matching
        // probes park on it, and the probe aimed at 192.168.1.14 waits until all three are parked before it
        // samples the in-flight count. Task-group children are not guaranteed to reach the transport in
        // creation order, so an ungated sample could legitimately see one or two of them.
        let concurrencyGate = ProbeConcurrencyGate(expectedParkedProbes: 3)
        let activeUnresponsiveProbes = LockedBox(0)
        let concurrentUnresponsiveObservedByFourth = LockedBox(0)
        let sentHosts = LockedBox<[String]>([])

        let transport = MockUDPTransport { packet, host, _ in
            sentHosts.withValue { $0.append(host) }
            switch host {
            case "192.168.1.11", "192.168.1.12", "192.168.1.13":
                activeUnresponsiveProbes.withValue { $0 += 1 }
                defer { activeUnresponsiveProbes.withValue { $0 -= 1 } }
                await concurrencyGate.park()
                throw MiIOError.timeout
            case "192.168.1.14":
                await concurrencyGate.waitUntilAllParked()
                concurrentUnresponsiveObservedByFourth.withValue {
                    $0 = activeUnresponsiveProbes.withValue { count in count }
                }
                await concurrencyGate.release()
                return try self.encodeRPCReply(
                    packet,
                    token: token4,
                    resultOrError: #""result":[{"did":"\#(did4)","siid":1,"piid":1,"value":true,"code":0}]"#
                )
            case "192.168.1.20":
                return try self.encodeRPCReply(
                    packet,
                    token: tokenLumi,
                    resultOrError: #""result":[{"did":"lumi.sensor.v1","siid":1,"piid":1,"value":1,"code":0}]"#
                )
            default:
                throw MiIOError.timeout
            }
        }

        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.11", packet: makeHelloResponse(deviceId: 101, stamp: 10)),
                MiIOBroadcastReply(sourceIP: "192.168.1.12", packet: makeHelloResponse(deviceId: 102, stamp: 11)),
                MiIOBroadcastReply(sourceIP: "192.168.1.13", packet: makeHelloResponse(deviceId: 103, stamp: 12)),
                // Low-32-bit header shared by both did4 and didCollision to exercise same-IP claim exclusivity.
                MiIOBroadcastReply(sourceIP: "192.168.1.14", packet: makeHelloResponse64(unknown: 0, deviceId: sharedLow32, stamp: 13)),
                MiIOBroadcastReply(sourceIP: "192.168.1.20", packet: makeHelloResponse(deviceId: 0x0BEE_F001, stamp: 14)),
            ]
        }

        let discoveryTime = LockedBox(ContinuousClock.now)
        let discoveryClock = Self.frozenDiscoveryClock(now: discoveryTime)
        let client = LocalMiIOClient(
            transport: transport,
            handshakeTimeout: .milliseconds(200),
            maxRetries: 0,
            maxDiscoveryDuration: .milliseconds(500),
            discoveryConcurrency: 6
        )

        let discovered = try await client.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "101", token: token1Hex),
                MiIODeviceCandidate(did: "102", token: token2Hex),
                MiIODeviceCandidate(did: "103", token: token3Hex),
                MiIODeviceCandidate(did: did4, token: token4Hex),
                MiIODeviceCandidate(did: didCollision, token: tokenCollisionHex),
                MiIODeviceCandidate(did: "lumi.sensor.v1", token: tokenLumiHex),
            ],
            broadcastTimeout: .milliseconds(20),
            discoveryClock: discoveryClock
        )

        #expect(discovered[did4] == "192.168.1.14")
        #expect(discovered["lumi.sensor.v1"] == "192.168.1.20")
        #expect(discovered[didCollision] == nil)
        #expect(Set(discovered.values).count == discovered.values.count)
        #expect(concurrentUnresponsiveObservedByFourth.withValue { $0 } == 3)
        // 192.168.1.14 is claimed by did4 in the first wave and must not be probed again or claimed by didCollision.
        #expect(sentHosts.withValue { $0.filter { $0 == "192.168.1.14" }.count } == 1)

        await client.shutdown()

        // Four unresponsive matching probes consume the 320 ms matching slice across two waves.
        let matchingHosts = LockedBox<[String]>([])
        await transport.setHandler { packet, host, _ in
            if host == "192.168.1.20" {
                return try self.encodeRPCReply(packet, token: tokenLumi, resultOrError: #""result":[]"#)
            }
            matchingHosts.withValue { $0.append(host) }
            discoveryTime.withValue { $0 = $0.advanced(by: .milliseconds(80)) }
            throw MiIOError.timeout
        }
        await transport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.11", packet: makeHelloResponse(deviceId: 101, stamp: 10)),
                MiIOBroadcastReply(sourceIP: "192.168.1.12", packet: makeHelloResponse(deviceId: 102, stamp: 11)),
                MiIOBroadcastReply(sourceIP: "192.168.1.13", packet: makeHelloResponse(deviceId: 103, stamp: 12)),
                MiIOBroadcastReply(sourceIP: "192.168.1.53", packet: makeHelloResponse(deviceId: 105, stamp: 13)),
                MiIOBroadcastReply(sourceIP: "192.168.1.20", packet: makeHelloResponse(deviceId: 0x0BEE_F001, stamp: 14)),
            ]
        }
        let multiWaveClient = LocalMiIOClient(
            transport: transport,
            handshakeTimeout: .milliseconds(160),
            maxRetries: 0,
            maxDiscoveryDuration: .milliseconds(500),
            discoveryConcurrency: 2
        )
        let multiWaveDiscovered = try await multiWaveClient.discoverEndpoints(
            for: [
                MiIODeviceCandidate(did: "101", token: token1Hex),
                MiIODeviceCandidate(did: "102", token: token2Hex),
                MiIODeviceCandidate(did: "103", token: token3Hex),
                MiIODeviceCandidate(did: "105", token: tokenCollisionHex),
                MiIODeviceCandidate(did: "lumi.sensor.v1", token: tokenLumiHex),
            ],
            broadcastTimeout: .milliseconds(20),
            discoveryClock: discoveryClock
        )
        #expect(multiWaveDiscovered["lumi.sensor.v1"] == "192.168.1.20")
        #expect(Set(matchingHosts.withValue { $0 }) == ["192.168.1.11", "192.168.1.12", "192.168.1.13", "192.168.1.53"])
        await multiWaveClient.shutdown()

    }

    @Test("A discovery wave keeps a reply the transport received before cancellation", .timeLimit(.minutes(1)))
    func discoveryKeepsReceivedReplyWhenWaveExpires() async throws {
        let token = try #require(MiIOPacket.validateToken(validTokenHex))
        let host = "192.168.1.20"
        let did = "lumi.sensor.v1"
        let replyReceived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let transport = MockUDPTransport { packet, _, _ in
            let reply = try self.encodeRPCReply(packet, token: token, resultOrError: #""result":[]"#)
            // Model a completed receive whose continuation resumes after the wave cancels.
            let (waitForCancellation, holdReply) = AsyncStream<Void>.makeStream()
            defer { holdReply.finish() }
            replyReceived.continuation.yield(())
            for await _ in waitForCancellation {}
            return reply
        }
        await transport.setBroadcastHandler { _, _, _ in
            [MiIOBroadcastReply(sourceIP: host, packet: makeHelloResponse(deviceId: 101, stamp: 10))]
        }
        let start = ContinuousClock.now
        let clock = LocalMiIOClient.DiscoveryClock(
            now: { start },
            sleep: { _ in
                var events = replyReceived.stream.makeAsyncIterator()
                await events.next()
            }
        )
        let client = LocalMiIOClient(transport: transport)
        let discovered = try await client.discoverEndpoints(
            for: [MiIODeviceCandidate(did: did, token: validTokenHex)],
            discoveryClock: clock
        )
        #expect(discovered == [did: host])
        await client.shutdown()
    }

    @Test("LocalNetworkDenied is non-retryable and bypasses ambiguousActionOutcome when occurring before packet send")
    func localNetworkDeniedFastFailAndPreSendActionBypass() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(validTokenHex))
        let failWithDenied = LockedBox(true)
        let sendAttempts = LockedBox(0)

        let transport = MockUDPTransport { packet, _, _ in
            sendAttempts.withValue { $0 += 1 }
            if failWithDenied.withValue({ $0 }) { throw MiIOError.localNetworkDenied }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 0x1234_5678, stamp: 90) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"12345678","siid":2,"piid":1,"value":true,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await transport.setBroadcastHandler { _, _, _ in throw MiIOError.localNetworkDenied }

        let client = LocalMiIOClient(transport: transport, maxRetries: 2)

        await #expect(throws: MiIOError.localNetworkDenied) {
            _ = try await client.getProps([MiotPropKey(did: "12345678", siid: 2, piid: 1)], endpoint: testEndpoint)
        }
        #expect(sendAttempts.withValue { $0 } == 1)

        await #expect(throws: MiIOError.localNetworkDenied) {
            _ = try await client.callAction(MiotActionCall(did: "12345678", siid: 2, aiid: 1, inputs: []), endpoint: testEndpoint)
        }
        #expect(sendAttempts.withValue { $0 } == 2)

        await #expect(throws: MiIOError.localNetworkDenied) {
            _ = try await client.discoverEndpoints(for: [MiIODeviceCandidate(did: "12345678", token: validTokenHex)])
        }

        failWithDenied.withValue { $0 = false }
        _ = try await client.getProps([MiotPropKey(did: "12345678", siid: 2, piid: 1)], endpoint: testEndpoint)

        failWithDenied.withValue { $0 = true }
        let beforeCachedActionAttempts = sendAttempts.withValue { $0 }
        await #expect(throws: MiIOError.localNetworkDenied) {
            _ = try await client.callAction(MiotActionCall(did: "12345678", siid: 2, aiid: 1, inputs: []), endpoint: testEndpoint)
        }
        #expect(sendAttempts.withValue { $0 } == beforeCachedActionAttempts + 1)

        await client.shutdown()
    }

    @Test("LocalNetworkPermissionClassifier, RTT quantization, and Darwin broadcast subnet filters classify deterministically")
    func permissionClassifierAndTransportDiagnosticsSummary() {
        #expect(LocalNetworkPermissionClassifier.isDeniedPOSIXCode(EPERM) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedPOSIXCode(EACCES) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedPOSIXCode(EHOSTUNREACH) == false)
        #expect(LocalNetworkPermissionClassifier.isDeniedDNSCode(-65570) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedDNSCode(-65555) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedDNSCode(0) == false)

        #if canImport(Network)
        #expect(LocalNetworkPermissionClassifier.isDeniedNWConnection(error: .posix(.EPERM), unsatisfiedReason: nil) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedNWConnection(error: .posix(.EACCES), unsatisfiedReason: nil) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedNWConnection(error: .dns(-65570), unsatisfiedReason: nil) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedNWConnection(error: nil, unsatisfiedReason: .localNetworkDenied) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedNWConnection(error: .posix(.ECONNREFUSED), unsatisfiedReason: nil) == false)
        #endif

        let urlOfflineErr = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(urlOfflineErr, targetHost: "192.168.1.50", isGeneralNetworkSatisfied: true) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(urlOfflineErr, targetHost: "homeassistant.local", isGeneralNetworkSatisfied: true) == true)
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(urlOfflineErr, targetHost: ".local", isGeneralNetworkSatisfied: true) == false)
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(urlOfflineErr, targetHost: "192.168.1.50", isGeneralNetworkSatisfied: false) == false)
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(urlOfflineErr, targetHost: "example.com", isGeneralNetworkSatisfied: true) == false)

        let wrappedPosix = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(wrappedPosix, targetHost: "example.com", isGeneralNetworkSatisfied: false) == true)

        let cfPosixDenied = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": Int(EPERM)]
        )
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(cfPosixDenied, targetHost: "192.168.1.50", isGeneralNetworkSatisfied: true) == true)

        let cfNetDBCodeOne = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotFindHost.rawValue,
            userInfo: ["_kCFStreamErrorDomainKey": 12, "_kCFStreamErrorCodeKey": 1]
        )
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(cfNetDBCodeOne, targetHost: "192.168.1.50", isGeneralNetworkSatisfied: true) == false)

        let cfDNSPolicyDenied = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotFindHost.rawValue,
            userInfo: ["_kCFStreamErrorDomainKey": 12, "_kCFStreamErrorCodeKey": Int(LocalNetworkPermissionClassifier.dnsPolicyDeniedCode)]
        )
        #expect(LocalNetworkPermissionClassifier.isDeniedConnectionError(cfDNSPolicyDenied, targetHost: "homeassistant.local", isGeneralNetworkSatisfied: true) == true)

        #expect(DeviceTransportDiagnostics.quantizeRTT(1) == 1)
        #expect(DeviceTransportDiagnostics.quantizeRTT(4) == 4)
        #expect(DeviceTransportDiagnostics.quantizeRTT(17) == 15)
        #expect(DeviceTransportDiagnostics.quantizeRTT(18) == 20)

        let summary = DeviceTransportSummary.summarize(
            [
                "d1": DeviceTransportDiagnostics(route: .lan, rttMs: 10, consecutiveFailures: 0, usedBroadcastRecovery: true),
                "d2": DeviceTransportDiagnostics(route: .lan, rttMs: 20, consecutiveFailures: 0, usedBroadcastRecovery: false),
                "d3": DeviceTransportDiagnostics(route: .cloud, rttMs: nil, consecutiveFailures: 0, usedBroadcastRecovery: false),
                "d4": DeviceTransportDiagnostics(route: .cooldown, rttMs: nil, consecutiveFailures: 3, usedBroadcastRecovery: false),
            ],
            localNetworkBlocks: []
        )
        #expect(summary?.lanDeviceCount == 2)
        #expect(summary?.cloudDeviceCount == 1)
        #expect(summary?.cooldownDeviceCount == 1)
        #expect(summary?.broadcastRecoveredCount == 1)
        #expect(summary?.medianLANRTTMs == 15)
        #expect(summary?.isLocalNetworkBlocked == false)

        #if canImport(Darwin)
        #expect(DarwinBSDMiIOBroadcastScanner.directedBroadcastIP(address: "192.168.1.42", netmask: "255.255.255.0") == "192.168.1.255")
        #expect(DarwinBSDMiIOBroadcastScanner.directedBroadcastIP(address: "192.168.2.15", netmask: "255.255.252.0") == "192.168.3.255")
        let locals: Set<String> = ["192.168.2.15"]
        let bcasts: Set<String> = ["255.255.255.255", "192.168.3.255"]
        #expect(DarwinBSDMiIOBroadcastScanner.isValidBroadcastResponderIP("192.168.2.255", localIPs: locals, broadcastIPs: bcasts) == true)
        #expect(DarwinBSDMiIOBroadcastScanner.isValidBroadcastResponderIP("192.168.3.255", localIPs: locals, broadcastIPs: bcasts) == false)
        #expect(DarwinBSDMiIOBroadcastScanner.isValidBroadcastResponderIP("192.168.2.15", localIPs: locals, broadcastIPs: bcasts) == false)
        #expect(DarwinBSDMiIOBroadcastScanner.isValidBroadcastResponderIP("255.255.255.255", localIPs: locals, broadcastIPs: bcasts) == false)
        #endif
    }
}

// MARK: - MiCloudClient & MiotSpecStore Enhancements

@Suite("MiCloudClient & MiotSpecStore Enhancements")
struct MiCloudAndSpecEnhancementsTests {
    private let stubSession = MiSession(
        userId: "10001",
        cUserId: "c1",
        ssecurity: Data(repeating: 0x01, count: 16).base64EncodedString(),
        serviceToken: "tok",
        region: "cn"
    )

    @Test("parseDeviceList extracts token & share_flag while keeping defaults compatible")
    func parseDeviceListTokensAndSharedFlags() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"list":[
            {"did":"100","name":"Own Bulb","model":"yeelink.light.color4","isOnline":true,"localip":"192.168.1.20","token":"00112233445566778899aabbccddeeff","share_flag":0},
            {"did":"200","name":"Shared Lamp","model":"yeelink.light.color4","isOnline":true,"localip":"192.168.1.21","token":"ffeeddccbbaa99887766554433221100","share_flag":1},
            {"did":"300","name":"Legacy Item","model":"lumi.sensor_ht.v1","isOnline":true,"isShared":true}
        ]}
        """#.utf8))
        let parsed = MiCloudClient.parseDeviceList(json)
        #expect(parsed.count == 3)
        #expect(parsed[0].token == "00112233445566778899aabbccddeeff")
        #expect(parsed[0].isShared == false)
        #expect(parsed[1].token == "ffeeddccbbaa99887766554433221100")
        #expect(parsed[1].isShared == true)
        #expect(parsed[2].token == nil)
        #expect(parsed[2].isShared == true)
    }

    @Test("MiCloudClient decodes malformed decrypted JSON and queries doorbell event timestamps")
    func cloudClientMalformedJSONAndDoorbellEvent() async throws {
        let transport = MirrorHTTPStub { req in
            let form = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            let signed = try MiCloudCrypto.signedNonce(ssecurity: self.stubSession.ssecurity, nonce: fields["_nonce"] ?? "")
            // Malformed firmware/cloud payload with trailing comma + null byte inside encrypted envelope.
            let reply = #"{"code":0,"message":"ok","result":{"list":[{"time":1700000123,"value":"ring",},]}}"# + "\0"
            let encrypted = try MiCloudCrypto.encrypt(reply, signedNonce: signed)
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(encrypted.utf8), response)
        }

        let client = MiCloudClient(session: stubSession, transport: transport)
        let latest = try await client.doorbellLatestEventTimestamp(
            did: "doorbell-1",
            eventKey: "2.1",
            since: Date(timeIntervalSince1970: 1_700_000_000),
            now: Date(timeIntervalSince1970: 1_700_000_200)
        )
        #expect(latest == Date(timeIntervalSince1970: 1_700_000_123))
    }

    @Test("Doorbell event timestamps reject out-of-range numbers without trapping under seeded fuzzing")
    func doorbellEventTimestampOverflowAndSeededFuzz() async throws {
        let outOfRangePayload: JSONValue = .object([
            "list": .array([
                .object(["time": .number(1e300)]),
                .object(["time": .number(1e25)]),
                .object(["time": .number(Double.greatestFiniteMagnitude)]),
                .object(["time": .number(.infinity)]),
                .object(["time": .number(.nan)]),
                .object(["time": .number(-100)]),
                .object(["time": .number(0)]),
                .object(["time": .number(0.5)]),
            ])
        ])
        #expect(MiCloudClient.parseLatestEventTimestamp(outOfRangePayload) == nil)

        let mixedPayload: JSONValue = .object([
            "list": .array([
                .object(["time": .number(1e300)]),
                .object(["time": .number(1_700_000_999)]),
                .object(["time": .number(Double.greatestFiniteMagnitude)]),
            ])
        ])
        #expect(MiCloudClient.parseLatestEventTimestamp(mixedPayload) == Date(timeIntervalSince1970: 1_700_000_999))

        let transport = MirrorHTTPStub { req in
            let form = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            let signed = try MiCloudCrypto.signedNonce(ssecurity: self.stubSession.ssecurity, nonce: fields["_nonce"] ?? "")
            let reply = #"{"code":0,"message":"ok","result":{"list":[{"time":1700000123}]}}"#
            let encrypted = try MiCloudCrypto.encrypt(reply, signedNonce: signed)
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(encrypted.utf8), response)
        }
        let client = MiCloudClient(session: stubSession, transport: transport)

        #expect(try await client.doorbellLatestEventTimestamp(
            did: "doorbell-1",
            eventKey: "2.1",
            since: Date(timeIntervalSince1970: 1e100),
            now: Date(timeIntervalSince1970: 1_700_000_200)
        ) == nil)
        #expect(try await client.doorbellLatestEventTimestamp(
            did: "doorbell-1",
            eventKey: "2.1",
            since: Date(timeIntervalSince1970: 1_700_000_000),
            now: Date(timeIntervalSince1970: 1e100)
        ) == nil)
        #expect(await transport.requestedURLs.isEmpty)

        // Negative finite `since` clamps `time_start` to 0 and proceeds safely.
        let clampedResult = try await client.doorbellLatestEventTimestamp(
            did: "doorbell-1",
            eventKey: "2.1",
            since: Date(timeIntervalSince1970: -500),
            now: Date(timeIntervalSince1970: 1_700_000_200)
        )
        #expect(clampedResult == Date(timeIntervalSince1970: 1_700_000_123))
        #expect(await transport.requestedURLs.count == 1)

        // Seeded IEEE-754 bit-pattern fuzzing never produces a timestamp that can trap on next-poll query.
        for iteration in 0..<64 {
            let seed = FuzzSupport.iterationSeed(FuzzSupport.baseSeed, iteration)
            var rng = SeededFuzzGenerator(seed: seed)
            let rawBytes = rng.bytes(count: 8)
            var bits: UInt64 = 0
            for byte in rawBytes {
                bits = (bits << 8) | UInt64(byte)
            }
            let candidate = Double(bitPattern: bits)
            let payload: JSONValue = .object(["list": .array([.object(["time": .number(candidate)])])])
            if let parsed = MiCloudClient.parseLatestEventTimestamp(payload) {
                let nextPollSince = parsed.addingTimeInterval(-1).timeIntervalSince1970
                guard MiCloudClient.checkedEpochSeconds(nextPollSince) != nil else {
                    Issue.record("seed=\(FuzzSupport.baseSeed) iteration=\(iteration) input=\(FuzzSupport.hex(rawBytes)) candidate=\(candidate)")
                    return
                }
            }
        }
    }

    @Test("MiotSpecStore falls back to secondary mirror and applies TTL jitter")
    func specStoreMirrorFallbackJitterAndPrefetch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = MirrorHTTPStub { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://miot-spec.org") {
                if url.contains("/instances?status=released") {
                    // HTTP 200 with wrong JSON shape ({}) must be rejected, not memoized/cached as fresh.
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data("{}".utf8), resp)
                }
                let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            if url.contains("/instances?status=released") {
                let body = Data(#"""
                {"instances":[
                    {"model":"acme.bulb.v1","version":1,"type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:1","status":"released"},
                    {"model":"acme.bulb.v2","version":1,"type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:2","status":"released"},
                    {"model":"acme.bulb.v3","version":1,"type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:3","status":"released"}
                ]}
                """#.utf8)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
            let body = Data(#"""
            {"type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:1","services":[
                {"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:acme-bulb:1","properties":[
                    {"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:acme-bulb:1","format":"bool","access":["read","write"]}
                ]}
            ]}
            """#.utf8)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }

        let store = MiotSpecStore(
            transport: transport,
            cacheDirectory: tempDir,
            indexMaxAge: 100,
            specMaxAge: 100,
            ttlJitterFraction: 0.2,
            now: { clock.now() },
            jitterRandom: { 0.5 } // +10% jitter -> 110s TTL
        )

        let effective = await store.effectiveTTL(forKey: "test", base: 100)
        #expect(abs(effective - 110.0) < 0.001)

        let loaded = try await store.spec(model: "acme.bulb.v1", specType: nil)
        #expect(loaded?.services.count == 1)
        let urls = await transport.requestedURLs
        #expect(urls.contains { $0.hasPrefix("https://spec.miot-spec.com/") })

        // If all mirrors return 200 {}, no index file should be written to disk.
        let badDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecBadIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: badDir) }
        let badTransport = MirrorHTTPStub { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), resp)
        }
        let badStore = MiotSpecStore(transport: badTransport, cacheDirectory: badDir)
        await #expect(throws: MiCloudError.badResponse("invalid spec payload")) {
            _ = try await badStore.spec(model: "acme.bulb.v1", specType: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: badDir.appendingPathComponent("miot-instances.json").path))
    }

    @Test("Expired cached spec and index fall back to stale disk cache when all mirrors fail, then refresh once mirrors recover")
    func staleCacheFallbackWhenMirrorsFail() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecStaleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MutableClock(Date())
        let failMirrors = LockedBox(false)
        let serveUpdatedSpec = LockedBox(false)
        let transport = MirrorHTTPStub { req in
            if failMirrors.withValue({ $0 }) {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            let url = req.url!.absoluteString
            if url.contains("/instances?status=released") {
                let body = Data(#"""
                {"instances":[
                    {"model":"acme.bulb.v1","type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:1","version":1,"status":"released"}
                ]}
                """#.utf8)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
            let extraBrightness = serveUpdatedSpec.withValue({ $0 })
                ? #",{"iid":2,"type":"urn:miot-spec-v2:property:brightness:0000000D:acme-bulb:1","format":"uint8","access":["read","write"]}"#
                : ""
            let body = Data(#"""
            {"type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:1","services":[
                {"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:acme-bulb:1","properties":[
                    {"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:acme-bulb:1","format":"bool","access":["read","write"]}\#(extraBrightness)
                ]},
                {"iid":7,"type":"urn:miot-spec-v2:service:notify:000078FF:acme-bulb:1","actions":[
                    {"iid":3,"type":"urn:miot-spec-v2:action:notify:000028FF:acme-bulb:1","in":[1]}
                ]}
            ]}
            """#.utf8)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }

        // Prime disk cache while fresh.
        let primer = MiotSpecStore(
            transport: transport,
            cacheDirectory: tempDir,
            indexMaxAge: 100,
            specMaxAge: 100,
            ttlJitterFraction: 0.0,
            now: { clock.now() }
        )
        let primed = try await primer.spec(model: "acme.bulb.v1", specType: nil)
        #expect(primed?.services.first(where: { $0.iid == 7 }) != nil)
        #expect(primed?.services.first(where: { $0.iid == 2 })?.properties.contains(where: { $0.iid == 2 }) == false)

        // Expire both index and spec TTLs while all mirrors return 503.
        clock.advance(by: 200)
        failMirrors.withValue { $0 = true }

        let offlineStore = MiotSpecStore(
            transport: transport,
            cacheDirectory: tempDir,
            indexMaxAge: 100,
            specMaxAge: 100,
            ttlJitterFraction: 0.0,
            now: { clock.now() }
        )
        let staleSpec = try await offlineStore.spec(model: "acme.bulb.v1", specType: nil)
        #expect(staleSpec?.services.first(where: { $0.iid == 7 }) != nil)
        #expect(staleSpec?.services.first(where: { $0.iid == 2 })?.properties.contains(where: { $0.iid == 2 }) == false)

        // Once mirrors recover, the same store must still refresh rather than pinning stale data forever.
        failMirrors.withValue { $0 = false }
        serveUpdatedSpec.withValue { $0 = true }
        let refreshedSpec = try await offlineStore.spec(model: "acme.bulb.v1", specType: nil)
        #expect(refreshedSpec?.services.first(where: { $0.iid == 2 })?.properties.contains(where: { $0.iid == 2 }) == true)
    }
}

// MARK: - Hybrid Provider & Doorbell Bridging Tests

@Suite("Hybrid LAN + Cloud Provider & Doorbell Bridging")
struct HybridProviderAndDoorbellTests {
    private let tokenHex = "00112233445566778899aabbccddeeff"
    private let stubSession = MiSession(
        userId: "10001",
        cUserId: "c1",
        ssecurity: Data(repeating: 0x01, count: 16).base64EncodedString(),
        serviceToken: "tok",
        region: "cn"
    )

    @Test("Direct Wi-Fi uses LAN, shared/BLE stay cloud, repeated LAN failures trigger cooldown fallback")
    func hybridRoutingAndCooldownFallback() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let lanModeShouldFail = LockedBox(false)
        let lanHostCalls = LockedBox<[String]>([])

        let udpTransport = MockUDPTransport { packet, host, _ in
            lanHostCalls.withValue { $0.append(host) }
            if lanModeShouldFail.withValue({ $0 }) {
                throw MiIOError.timeout
            }
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x1111_2222, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let method = req["method"]?.stringValue ?? ""
            let reply: String
            if method == "get_properties" {
                reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":75,"code":0}]}"#
            } else {
                reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"code":0}]}"#
            }
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })

        let ownWifi = MiDeviceRecord(did: "101", name: "Own Wifi Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.10", token: tokenHex, isShared: false)
        let sharedWifi = MiDeviceRecord(did: "202", name: "Shared Wifi Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.11", token: tokenHex, isShared: true)
        let bleLight = MiDeviceRecord(did: "303", name: "BLE Mesh Light", model: "yeelink.light.color4", isOnline: true, localIp: nil, token: nil, isShared: false)

        let api = HybridMockCloudAPI(
            devices: [ownWifi, sharedWifi, bleLight],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "202", "303"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(false),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(10),
                MiotPropKey(did: "202", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "202", siid: 2, piid: 2): .number(50),
                MiotPropKey(did: "303", siid: 2, piid: 1): .bool(false),
                MiotPropKey(did: "303", siid: 2, piid: 2): .number(25),
            ]
        )

        let specSource = HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()])
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: specSource,
            localClient: localClient,
            lanFailureThreshold: 2,
            lanCooldownDuration: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        let initialReady = await collector.wait { !$0.snapshots.isEmpty }
        #expect(initialReady)

        // Own Wi-Fi device received LAN values (brightness 75, on true); shared/BLE came from cloud.
        let snap1 = await collector.snapshots.last
        let ownDev1 = snap1?.devices.first { $0.id == "101" }
        #expect(lightBrightness(ownDev1) == 75)
        #expect(lanHostCalls.withValue { !$0.contains("192.168.1.11") })
        // Cloud getProps must NOT have included did 101 during healthy LAN poll.
        let firstCloudGetDids = Set((await api.getPropsCalls.first ?? []).map(\.did))
        #expect(!firstCloudGetDids.contains("101"))
        #expect(firstCloudGetDids == Set(["202", "303"]))

        // Trigger 2 consecutive LAN failures -> enters 60s cooldown + falls back to cloud.
        lanModeShouldFail.withValue { $0 = true }
        await api.setCloudProp(MiotPropKey(did: "101", siid: 2, piid: 2), value: .number(33))
        await provider.refreshNow() // failure #1
        await provider.refreshNow() // failure #2 -> activates cooldown

        let sendCountAtCooldown = await udpTransport.sends.count
        await provider.refreshNow() // during cooldown: skips LAN entirely, reads from cloud
        #expect(await udpTransport.sends.count == sendCountAtCooldown)

        let gotCooldownSnapshot = await collector.wait {
            lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 33
        }
        #expect(gotCooldownSnapshot)

        // Advance past 60s cooldown and restore LAN -> recovers to LAN direct (75).
        clock.advance(by: 61)
        lanModeShouldFail.withValue { $0 = false }
        await provider.refreshNow()
        let gotRecoveredSnapshot = await collector.wait {
            lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 75
        }
        #expect(gotRecoveredSnapshot)

        await provider.shutdown()
        #expect(await api.shutdownCount == 1)
        #expect(await udpTransport.shutdownCount == 1)
    }

    @Test("Doorbell ring event bridges from MiCloudProvider through MiAccountsProvider without launch spam")
    func doorbellEventBridgingThroughAccountsProvider() async throws {
        let doorbellDevice = MiDeviceRecord(did: "db-1", name: "Front Doorbell", model: "madv.bell.mjml06", isOnline: true)
        let api = HybridMockCloudAPI(
            devices: [doorbellDevice],
            rooms: [MiRoom(id: "r1", name: "Entry", dids: ["db-1"])],
            props: [MiotPropKey(did: "db-1", siid: 2, piid: 1): .bool(true)]
        )
        // Historical event before startup -> sets baseline, must NOT emit on launch.
        await api.setDoorbellLatest(did: "db-1", eventKey: "2.1", date: Date(timeIntervalSince1970: 1_699_999_900))

        let specSource = HybridMockSpecSource(specs: ["madv.bell.mjml06": doorbellSpec()])
        let account = MiAccount(session: stubSession)
        let accountsProvider = MiAccountsProvider(
            accounts: [account],
            apiFactory: { _ in api },
            specSource: specSource,
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )

        let collector = EventCollector()
        let stream = accountsProvider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        let launched = await collector.wait { !$0.snapshots.isEmpty }
        #expect(launched)
        #expect(await collector.doorbellRings.isEmpty)

        // Newer doorbell ring arrives -> bridged out through MiAccountsProvider.
        let ringDate = Date(timeIntervalSince1970: 1_700_000_050)
        await api.setDoorbellLatest(did: "db-1", eventKey: "2.1", date: ringDate)
        await accountsProvider.refreshNow()

        let gotRing = await collector.wait { $0.doorbellRings.count == 1 }
        #expect(gotRing)
        let ring = await collector.doorbellRings.first
        #expect(ring?.deviceId == "db-1")
        #expect(ring?.entityId == "miot-event:db-1:2:1")

        // Repeated poll with same timestamp must not duplicate the ring event.
        await accountsProvider.refreshNow()
        #expect(await collector.doorbellRings.count == 1)

        await accountsProvider.shutdown()
        #expect(await api.shutdownCount == 1)
    }

    @Test("Incomplete LAN get_properties sends missing/nonzero keys through cloud fallback")
    func partialLANReadFallsBackToCloudForMissingKeys() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x2222_3333, stamp: 20)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            // Return code 0 for piid 1 (`on = true`), but nonzero code -4004 for piid 2 (`brightness`).
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"code":-4004}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0)
        let ownWifi = MiDeviceRecord(did: "101", name: "Partial Bulb", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.30", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(false),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(64),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { !$0.snapshots.isEmpty })
        let light = await collector.snapshots.last?.devices.first { $0.id == "101" }
        #expect(light?.isActiveOn == true)
        #expect(lightBrightness(light) == 64)

        // Cloud fallback must have been asked ONLY for the missing key (2.2), never the satisfied LAN key (2.1).
        let cloudKeysRequested = await api.getPropsCalls.first ?? []
        #expect(cloudKeysRequested == [MiotPropKey(did: "101", siid: 2, piid: 2)])
        await provider.shutdown()
    }

    @Test("Ambiguous post-send MIoT action does not retry or fall back to cloud, while pre-send timeout falls back")
    func ambiguousActionOutcomeVsPreSendFallback() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let dropAfterSend = LockedBox(false)
        let dropHandshake = LockedBox(false)
        let actionPacketCount = LockedBox(0)

        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                if dropHandshake.withValue({ $0 }) {
                    throw MiIOError.timeout
                }
                return makeHelloResponse(deviceId: 0x3333_4444, stamp: 30)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let method = req["method"]?.stringValue ?? ""
            if method == "action" {
                actionPacketCount.withValue { $0 += 1 }
                if dropAfterSend.withValue({ $0 }) {
                    throw MiIOError.timeout
                }
                let reply = #"{"id":\#(reqId),"result":{"code":0}}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":50,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        // maxRetries: 2 proves action never retries even when retries are configured.
        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 2)
        let ownWifi = MiDeviceRecord(did: "101", name: "Living Room Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.31", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(50),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { !$0.snapshots.isEmpty })

        // Case 1: Action UDP datagram is sent, reply times out -> ambiguousActionOutcome, 1 UDP send total, 0 cloud calls.
        dropAfterSend.withValue { $0 = true }
        await #expect(throws: MiIOError.ambiguousActionOutcome) {
            try await provider.execute(.sendNotifyMessage(entityId: "miot-action:101:7:3", message: "hello"))
        }
        #expect(actionPacketCount.withValue { $0 } == 1)
        #expect(await api.actionCalls.isEmpty)

        // Case 2: Pre-send HELLO fails -> 0 new UDP action datagrams sent, safe fallback to cloud action.
        dropAfterSend.withValue { $0 = false }
        dropHandshake.withValue { $0 = true }
        try await provider.execute(.sendNotifyMessage(entityId: "miot-action:101:7:3", message: "fallback"))
        #expect(actionPacketCount.withValue { $0 } == 1)
        #expect(await api.actionCalls == [MiotActionCall(did: "101", siid: 7, aiid: 3, inputs: [.string("fallback")])])

        await provider.shutdown()
    }

    @Test("Shutdown overlapping or preceding LAN action never falls back to cloud")
    func shutDownActionNeverFallsBackToCloud() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let dropActionWithShutDown = LockedBox(false)
        let actionPacketCount = LockedBox(0)

        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x3333_4445, stamp: 31)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let method = req["method"]?.stringValue ?? ""
            if method == "action" {
                actionPacketCount.withValue { $0 += 1 }
                if dropActionWithShutDown.withValue({ $0 }) {
                    throw MiIOError.shutDown
                }
                let reply = #"{"id":\#(reqId),"result":{"code":0}}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":50,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 2)
        let ownWifi = MiDeviceRecord(did: "101", name: "Living Room Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.32", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(50),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { !$0.snapshots.isEmpty })

        // Case 1: Post-dispatch .shutDown during action -> ambiguousActionOutcome, 1 UDP send, 0 cloud calls.
        dropActionWithShutDown.withValue { $0 = true }
        await #expect(throws: MiIOError.ambiguousActionOutcome) {
            try await provider.execute(.sendNotifyMessage(entityId: "miot-action:101:7:3", message: "in-flight"))
        }
        #expect(actionPacketCount.withValue { $0 } == 1)
        #expect(await api.actionCalls.isEmpty)

        // Case 2: localClient already shut down before action -> throws .shutDown, 0 new UDP sends, 0 cloud calls.
        await localClient.shutdown()
        await #expect(throws: MiIOError.shutDown) {
            try await provider.execute(.sendNotifyMessage(entityId: "miot-action:101:7:3", message: "after-shutdown"))
        }
        #expect(actionPacketCount.withValue { $0 } == 1)
        #expect(await api.actionCalls.isEmpty)

        await provider.shutdown()
    }

    @Test("Shared-home homeFallback devices never route polling or actions over LAN even if share_flag is omitted")
    func sharedHomeFallbackDevicesNeverRouteOverLAN() async throws {
        let udpTransport = MockUDPTransport { _, _, _ in
            Issue.record("Unexpected LAN UDP send for shared-home device")
            throw MiIOError.timeout
        }

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0)
        let sharedHomeDevice = MiDeviceRecord(
            did: "505",
            name: "Shared Home Light",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.55",
            token: tokenHex,
            isShared: false
        )
        let sharedRoom = MiRoom(
            id: "r-shared",
            name: "Shared Living",
            dids: [],
            homeId: "h-shared",
            homeName: "Family Home",
            isSharedHome: true,
            ownerUid: "99999"
        )
        let api = HybridMockCloudAPI(
            devices: [],
            rooms: [sharedRoom],
            props: [
                MiotPropKey(did: "505", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "505", siid: 2, piid: 2): .number(88),
            ],
            homeDevicesByHomeId: ["h-shared": [sharedHomeDevice]]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { !$0.snapshots.isEmpty })
        let light = await collector.snapshots.last?.devices.first { $0.id == "505" }
        #expect(lightBrightness(light) == 88)
        #expect(await udpTransport.sends.isEmpty)
        #expect((await api.getPropsCalls.first ?? []).map(\.did) == ["505", "505"])

        try await provider.execute(.sendNotifyMessage(entityId: "miot-action:505:7:3", message: "cloud-only"))
        #expect(await udpTransport.sends.isEmpty)
        #expect(await api.actionCalls == [MiotActionCall(did: "505", siid: 7, aiid: 3, inputs: [.string("cloud-only")])])

        await provider.shutdown()
    }

    @Test("Successful LAN reads are applied and emitted even when cloud getProps fallback throws")
    func lanValuesPreservedWhenCloudFallbackFails() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let lanBrightness = LockedBox(75)
        let lanOn = LockedBox(true)
        let partialMissingBrightness = LockedBox(false)

        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x4444_5555, stamp: 40)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let onValue = lanOn.withValue { $0 }
            let brightnessItem: String
            if partialMissingBrightness.withValue({ $0 }) {
                brightnessItem = #"{"did":"101","siid":2,"piid":2,"code":-4004}"#
            } else {
                let brightnessValue = lanBrightness.withValue { $0 }
                brightnessItem = #"{"did":"101","siid":2,"piid":2,"value":\#(brightnessValue),"code":0}"#
            }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":\#(onValue),"code":0},\#(brightnessItem)]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0)
        let ownWifi = MiDeviceRecord(did: "101", name: "Own Wifi Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.40", token: tokenHex, isShared: false)
        let cloudOnly = MiDeviceRecord(did: "303", name: "Cloud Light", model: "yeelink.light.color4", isOnline: true, localIp: nil, token: nil, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi, cloudOnly],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "303"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(false),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(10),
                MiotPropKey(did: "303", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "303", siid: 2, piid: 2): .number(25),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        let initialSnap = await collector.snapshots.last
        #expect(lightBrightness(initialSnap?.devices.first { $0.id == "101" }) == 75)
        #expect(lightBrightness(initialSnap?.devices.first { $0.id == "303" }) == 25)
        #expect(initialSnap?.closesAwayGap == true)

        // Cloud fails with 503 while LAN succeeds with brightness 92.
        lanBrightness.withValue { $0 = 92 }
        await api.setCloudProp(MiotPropKey(did: "303", siid: 2, piid: 2), value: .number(60))
        await api.setGetPropsError(MiCloudError.http(503))

        await provider.refreshNow()
        #expect(await collector.wait { state in
            lightBrightness(state.snapshots.last?.devices.first { $0.id == "101" }) == 92
        })
        #expect(await collector.statuses.last == .connected)
        let partialSnap = await collector.snapshots.last
        #expect(lightBrightness(partialSnap?.devices.first { $0.id == "101" }) == 92)
        #expect(partialSnap?.devices.first { $0.id == "101" }?.telemetryStale == false)
        #expect(lightBrightness(partialSnap?.devices.first { $0.id == "303" }) == 25)
        #expect(partialSnap?.devices.first { $0.id == "303" }?.telemetryStale == true)
        #expect(partialSnap?.closesAwayGap == false)

        // Partial LAN readBack succeeds for device 101's answered power key even when missing piid 2 causes cloud fallback to throw.
        lanOn.withValue { $0 = false }
        partialMissingBrightness.withValue { $0 = true }
        let lanReadBack = await provider.readBack(deviceId: "101")
        #expect(lanReadBack == .published)
        #expect(await collector.wait { $0.snapshots.last?.devices.first { $0.id == "101" }?.isActiveOn == false })
        #expect(await provider.readBack(deviceId: "303") == .failed)

        // Once cloud recovers, cloud-only device 303 updates and status returns to .connected with closesAwayGap == true.
        partialMissingBrightness.withValue { $0 = false }
        await api.setGetPropsError(nil)
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.statuses.last == .connected && lightBrightness($0.snapshots.last?.devices.first { $0.id == "303" }) == 60
        })
        #expect(await collector.snapshots.last?.closesAwayGap == true)

        await provider.shutdown()
    }

    @Test("Non-private localIp values skip LAN UDP and route through cloud")
    func nonPrivateLocalIpsRouteThroughCloudOnly() async throws {
        let udpTransport = MockUDPTransport { _, _, _ in
            Issue.record("Unexpected UDP packet sent to non-private localIp")
            throw MiIOError.timeout
        }
        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0)
        let rejected = [
            ("d1", "192.0.2.10"),
            ("d2", "8.8.8.8"),
            ("d3", "127.0.0.1"),
            ("d4", "example.com"),
        ]
        let devices = rejected.map { did, ip in
            MiDeviceRecord(did: did, name: "Light \(did)", model: "yeelink.light.color4", isOnline: true, localIp: ip, token: tokenHex, isShared: false)
        }
        var props: [MiotPropKey: JSONValue] = [:]
        for (did, _) in rejected {
            props[MiotPropKey(did: did, siid: 2, piid: 1)] = .bool(true)
            props[MiotPropKey(did: did, siid: 2, piid: 2)] = .number(45)
        }
        let api = HybridMockCloudAPI(
            devices: devices,
            rooms: [MiRoom(id: "r1", name: "Study", dids: rejected.map(\.0))],
            props: props
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient,
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { !$0.snapshots.isEmpty })
        #expect(await udpTransport.sends.isEmpty)
        let cloudPolledDids = Set((await api.getPropsCalls.first ?? []).map(\.did))
        #expect(cloudPolledDids == Set(["d1", "d2", "d3", "d4"]))

        try await provider.execute(.setLightPower(entityId: "miot:d1:2", isOn: false))
        #expect(await udpTransport.sends.isEmpty)
        #expect(await api.setPropsCalls == [[MiotPropWrite(did: "d1", siid: 2, piid: 1, value: .bool(false))]])

        await provider.shutdown()
    }

    @Test("Multi-key split Wi-Fi wall switch routes getProps, execute, and readBack over LAN in both unscoped and selected-home modes")
    func splitWallSwitchRoutesOverLANWithAndWithoutSelectedHome() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let onProp = MiotProperty(
            iid: 1,
            type: "urn:miot-spec-v2:property:on:00000006:lemesh-sw2f12:1",
            format: "bool",
            access: ["read", "write", "notify"]
        )
        let wallSwitchSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:switch:0000A003:lemesh-sw2f12:1",
            services: [
                MiotService(iid: 2, type: "urn:miot-spec-v2:service:switch:0000780C:lemesh-sw2f12:1", properties: [onProp]),
                MiotService(iid: 3, type: "urn:miot-spec-v2:service:switch:0000780C:lemesh-sw2f12:1", properties: [onProp]),
            ]
        )
        let model = "lemesh.switch.sw2f12"
        let parent = MiDeviceRecord(
            did: "100",
            name: "二键开关",
            model: model,
            isOnline: true,
            localIp: "192.168.1.60",
            token: tokenHex,
            isShared: false
        )
        let key2 = MiDeviceRecord(did: "100.s2", name: "筒灯", model: model, isOnline: true, splitParentDid: "100", splitSiid: 2)
        let key3 = MiDeviceRecord(did: "100.s3", name: "氛围灯", model: model, isOnline: true, splitParentDid: "100", splitSiid: 3)

        for selectedHome in [nil, "h1"] as [String?] {
            let key2On = LockedBox(false)
            let key3On = LockedBox(true)
            let udpTransport = MockUDPTransport { packet, _, _ in
                if packet == MiIOPacket.helloPacket {
                    return makeHelloResponse(deviceId: 0x5555_6666, stamp: 50)
                }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
                let reqId = req["id"]?.intValue ?? 0
                let method = req["method"]?.stringValue ?? ""
                let reply: String
                if method == "set_properties" {
                    let params = req["params"]?.arrayValue ?? []
                    for item in params {
                        if item["siid"]?.intValue == 2, let b = item["value"]?.boolValue {
                            key2On.withValue { $0 = b }
                        } else if item["siid"]?.intValue == 3, let b = item["value"]?.boolValue {
                            key3On.withValue { $0 = b }
                        }
                    }
                    reply = #"{"id":\#(reqId),"result":[{"did":"100","siid":2,"piid":1,"code":0}]}"#
                } else {
                    let v2 = key2On.withValue { $0 }
                    let v3 = key3On.withValue { $0 }
                    reply = #"{"id":\#(reqId),"result":[{"did":"100","siid":2,"piid":1,"value":\#(v2),"code":0},{"did":"100","siid":3,"piid":1,"value":\#(v3),"code":0}]}"#
                }
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }

            let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0)
            let orderedDevices = selectedHome == nil ? [key2, key3, parent] : [parent, key2, key3]
            let api = HybridMockCloudAPI(
                devices: orderedDevices,
                rooms: [
                    MiRoom(
                        id: "r1",
                        name: "主卧",
                        dids: ["100.s2", "100.s3"],
                        homeId: "h1",
                        homeName: "Home 1"
                    )
                ]
            )
            let provider = MiCloudProvider(
                sessionLoader: { self.stubSession },
                apiFactory: { _ in api },
                specSource: HybridMockSpecSource(specs: [model: wallSwitchSpec]),
                localClient: localClient,
                pollInterval: .seconds(3600),
                closedPollInterval: .seconds(3600),
                selectedHomeLoader: { selectedHome }
            )

            let collector = EventCollector()
            let stream = provider.events()
            let task = Task {
                for await event in stream {
                    await collector.append(event)
                }
                await collector.finish()
            }

            #expect(await collector.wait { !$0.snapshots.isEmpty })
            let initialSnap = await collector.snapshots.last
            #expect(initialSnap?.devices.map(\.id).sorted() == ["100.s2", "100.s3"])
            #expect(initialSnap?.devices.first { $0.id == "100.s2" }?.isActiveOn == false)
            #expect(initialSnap?.devices.first { $0.id == "100.s3" }?.isActiveOn == true)
            #expect(await api.getPropsCalls.isEmpty)

            try await provider.execute(.setSwitch(entityId: "miot:100:2", isOn: true))
            #expect(await api.setPropsCalls.isEmpty)

            let rb = await provider.readBack(deviceId: "100.s2")
            #expect(rb == .published)
            if rb == .published {
                #expect(await collector.wait { $0.snapshots.last?.devices.first { $0.id == "100.s2" }?.isActiveOn == true })
            }
            #expect(await api.getPropsCalls.isEmpty)
            #expect(await api.setPropsCalls.isEmpty)

            await provider.shutdown()
            task.cancel()
        }
    }

    @Test("Offline cold-start from encrypted MiTopologyCache under URLError and HTTP 429 keeps LAN alive, marks BLE sensor offline+stale, and recovers when WAN returns")
    func offlineColdStartFromTopologyCacheAndRecovery() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let htSensorSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:lumi-v1:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:lumi-v1:1",
                    properties: [
                        MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:lumi-v1:1", format: "float", access: ["read", "notify"]),
                        MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:lumi-v1:1", format: "uint8", access: ["read", "notify"]),
                    ]
                )
            ]
        )

        let ownWifi = MiDeviceRecord(
            did: "101",
            name: "Desk Light",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.45",
            token: tokenHex,
            isShared: false
        )
        let bleSensor = MiDeviceRecord(
            did: "ble-sensor-1",
            name: "Bedroom Sensor",
            model: "lumi.sensor_ht.v1",
            isOnline: true
        )
        let rooms = [MiRoom(id: "r1", name: "Bedroom", dids: ["101", "ble-sensor-1"])]

        for outageError in [URLError(.notConnectedToInternet) as any Error, MiCloudError.http(429) as any Error] {
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiOfflineColdStart-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cacheDir) }
            let topologyCache = MiTopologyCache(directory: cacheDir)
            let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))

            topologyCache.save(
                CachedMiTopology(savedAt: clock.now(), devices: [ownWifi, bleSensor], rooms: []),
                for: stubSession
            )

            let lanOn = LockedBox(true)
            let lanBrightness = LockedBox(80)
            let udpTransport = MockUDPTransport { packet, _, _ in
                if packet == MiIOPacket.helloPacket {
                    return makeHelloResponse(deviceId: 0x7777_8888, stamp: 70)
                }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
                let reqId = req["id"]?.intValue ?? 0
                let method = req["method"]?.stringValue ?? ""
                let reply: String
                if method == "set_properties" {
                    let params = req["params"]?.arrayValue ?? []
                    for item in params {
                        if item["siid"]?.intValue == 2, item["piid"]?.intValue == 1, let b = item["value"]?.boolValue {
                            lanOn.withValue { $0 = b }
                        }
                    }
                    reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"code":0}]}"#
                } else {
                    let onVal = lanOn.withValue { $0 }
                    let brVal = lanBrightness.withValue { $0 }
                    reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":\#(onVal),"code":0},{"did":"101","siid":2,"piid":2,"value":\#(brVal),"code":0}]}"#
                }
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }

            let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
            let api = HybridMockCloudAPI(
                devices: [ownWifi, bleSensor],
                rooms: rooms,
                props: [
                    MiotPropKey(did: "ble-sensor-1", siid: 2, piid: 1): .number(24.5),
                    MiotPropKey(did: "ble-sensor-1", siid: 2, piid: 2): .number(55),
                ]
            )
            await api.setDiscoveryError(outageError)
            await api.setGetPropsError(outageError)

            let provider = MiCloudProvider(
                sessionLoader: { self.stubSession },
                apiFactory: { _ in api },
                specSource: HybridMockSpecSource(specs: [
                    "yeelink.light.color4": lightSpec(),
                    "lumi.sensor_ht.v1": htSensorSpec,
                ]),
                localClient: localClient,
                topologyCache: topologyCache,
                now: { clock.now() },
                pollInterval: .seconds(3600),
                closedPollInterval: .seconds(3600),
                selectedHomeLoader: { nil }
            )

            let collector = EventCollector()
            let stream = provider.events()
            let task = Task {
                for await event in stream {
                    await collector.append(event)
                }
                await collector.finish()
            }

            #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
            let coldSnap = await collector.snapshots.last
            #expect(coldSnap?.closesAwayGap == false)
            let lanDev = coldSnap?.devices.first { $0.id == "101" }
            let bleDev = coldSnap?.devices.first { $0.id == "ble-sensor-1" }
            #expect(lanDev?.isOnline == true)
            #expect(lanDev?.telemetryStale == false)
            #expect(lightBrightness(lanDev) == 80)
            #expect(bleDev?.isOnline == false)
            #expect(bleDev?.telemetryStale == true)
            #expect(coldSnap?.environmentReadings.isEmpty == true)
            #expect(await api.getPropsCalls.isEmpty)

            try await provider.execute(.setLightPower(entityId: "miot:101:2", isOn: false))
            #expect(await api.setPropsCalls.isEmpty)
            #expect(await provider.readBack(deviceId: "101") == .published)
            #expect(await collector.wait { $0.snapshots.last?.devices.first { $0.id == "101" }?.isActiveOn == false })

            if (outageError as? MiCloudError) == .http(429) {
                let devCallsBefore = await api.deviceListCalls
                clock.advance(by: 10)
                lanBrightness.withValue { $0 = 85 }
                await provider.refreshNow()
                #expect(await collector.wait {
                    lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 85
                })
                #expect(await api.deviceListCalls == devCallsBefore)
                #expect(await api.getPropsCalls.isEmpty)
            }

            clock.advance(by: 65)
            await api.setDiscoveryError(nil)
            await api.setGetPropsError(nil)
            await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
            await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

            #expect(await collector.wait {
                guard let snap = $0.snapshots.last,
                      let sensor = snap.devices.first(where: { $0.id == "ble-sensor-1" }) else { return false }
                return sensor.isOnline
                    && !sensor.telemetryStale
                    && snap.closesAwayGap
                    && snap.rooms.map(\.name) == ["Bedroom"]
            })

            await provider.shutdown()
            task.cancel()
        }
    }

    @Test("Offline cold start with cached topology but zero online LAN keys reports disconnected")
    func offlineColdStartWithNoOnlineLANKeysReportsDisconnected() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x7777_8888, stamp: 70)
            }
            let (header, _) = try MiIOPacket.decode(packet, token: tokenData)
            let reply = #"{"id":1,"result":[]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiOfflineEmptyKeys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let topologyCache = MiTopologyCache(directory: cacheDir)
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))

        let offlineWifi = MiDeviceRecord(
            did: "101",
            name: "Offline Bulb",
            model: "yeelink.light.color4",
            isOnline: false,
            localIp: "192.168.1.45",
            token: tokenHex,
            isShared: false
        )
        topologyCache.save(
            CachedMiTopology(savedAt: clock.now(), devices: [offlineWifi], rooms: []),
            for: stubSession
        )

        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let api = HybridMockCloudAPI(devices: [offlineWifi], rooms: [])
        await api.setDiscoveryError(URLError(.notConnectedToInternet))

        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient,
            topologyCache: topologyCache,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait {
            $0.statuses.contains {
                if case .disconnected = $0 { return true }
                return false
            }
        })
        #expect(await !collector.statuses.contains(.connected))

        await provider.shutdown()
    }

    @Test("Periodic refreshDeviceList failure on poll #N does not break active LAN polling and recovers closesAwayGap on next poll")
    func periodicTopologyRefreshFailureKeepsLANConnected() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let lanBrightness = LockedBox(70)
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x8888_9999, stamp: 80)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let brVal = lanBrightness.withValue { $0 }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(brVal),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let ownWifi = MiDeviceRecord(
            did: "101",
            name: "LAN Bulb",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.48",
            token: tokenHex,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            deviceRefreshEveryPolls: 2,
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })

        await api.setDiscoveryError(URLError(.timedOut))
        lanBrightness.withValue { $0 = 95 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 95 && !snap.closesAwayGap
        })
        #expect(await collector.statuses.last == .connected)
        #expect(await api.deviceListCalls >= 2)

        clock.advance(by: 5)
        await api.setDiscoveryError(nil)
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            $0.snapshots.last?.closesAwayGap == true
        })

        await provider.shutdown()
    }

    @Test("Periodic topology refresh honors cloudRetryNotBefore backoff across multiple polls")
    func periodicTopologyRefreshHonorsCloudBackoff() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let lanBrightness = LockedBox(60)
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x8888_999A, stamp: 81)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let brVal = lanBrightness.withValue { $0 }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(brVal),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let ownWifi = MiDeviceRecord(
            did: "101",
            name: "LAN Bulb",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.48",
            token: tokenHex,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            deviceRefreshEveryPolls: 2,
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        #expect(await api.deviceListCalls == 1)
        #expect(await api.homeRoomsCalls == 1)

        await api.setDiscoveryError(MiCloudError.http(429))
        lanBrightness.withValue { $0 = 65 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 65 && !snap.closesAwayGap
        })
        let deviceListCallsAtBackoffStart = await api.deviceListCalls
        let homeRoomsCallsAtBackoffStart = await api.homeRoomsCalls
        #expect(deviceListCallsAtBackoffStart == 2)
        #expect(homeRoomsCallsAtBackoffStart == 1)

        for targetBrightness in [70, 75, 80] {
            clock.advance(by: 10)
            lanBrightness.withValue { $0 = targetBrightness }
            await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
            await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
            #expect(await collector.wait {
                lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == targetBrightness
            })
            #expect(await api.deviceListCalls == deviceListCallsAtBackoffStart)
            #expect(await api.homeRoomsCalls == homeRoomsCallsAtBackoffStart)
        }

        clock.advance(by: 40)
        await api.setDiscoveryError(nil)
        lanBrightness.withValue { $0 = 85 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 85 && snap.closesAwayGap
        })
        #expect(await api.deviceListCalls == deviceListCallsAtBackoffStart + 1)
        #expect(await api.homeRoomsCalls == homeRoomsCallsAtBackoffStart + 1)

        await provider.shutdown()
    }

    @Test("Live empty device list invalidates cached topology so subsequent offline cold start does not resurrect removed devices")
    func emptyLiveDiscoveryInvalidatesCachedTopology() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x8888_999B, stamp: 82)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":60,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiEmptyDiscoveryCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let topologyCache = MiTopologyCache(directory: cacheDir)
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))

        let ownWifi = MiDeviceRecord(
            did: "101",
            name: "LAN Bulb",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.49",
            token: tokenHex,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])]
        )
        let localClient1 = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let provider1 = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient1,
            topologyCache: topologyCache,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector1 = EventCollector()
        let stream1 = provider1.events()
        let task1 = Task {
            for await event in stream1 {
                await collector1.append(event)
            }
            await collector1.finish()
        }

        #expect(await collector1.wait { $0.statuses.last == .connected && $0.snapshots.last?.devices.count == 1 })
        #expect(topologyCache.load(for: stubSession)?.devices.map(\.did) == ["101"])

        await api.setTopology(devices: [], rooms: [])
        await provider1.refreshNow()
        #expect(await collector1.wait { $0.snapshots.last?.devices.isEmpty == true })
        #expect(topologyCache.load(for: stubSession) == nil)

        await provider1.shutdown()
        task1.cancel()

        await api.setDiscoveryError(URLError(.notConnectedToInternet))
        await api.setGetPropsError(URLError(.notConnectedToInternet))
        let sendsBeforeColdStart = await udpTransport.sends.count

        let localClient2 = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let provider2 = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient2,
            topologyCache: topologyCache,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector2 = EventCollector()
        let stream2 = provider2.events()
        let task2 = Task {
            for await event in stream2 {
                await collector2.append(event)
            }
            await collector2.finish()
        }
        defer { task2.cancel() }

        #expect(await collector2.wait {
            $0.statuses.contains {
                if case .disconnected = $0 { return true }
                return false
            }
        })
        #expect(await collector2.snapshots.isEmpty)
        #expect(await udpTransport.sends.count == sendsBeforeColdStart)

        await provider2.shutdown()
    }

    @Test("Cloud getProps 429 escalates backoff across successful deviceList refreshes and 100%-LAN recovery resets backoff")
    func getProps429EscalatesBackoffAcrossSuccessfulDiscoveryAndLANRecoveryResetsBackoff() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let lanBrightness = LockedBox(60)
        let udpTransport = MockUDPTransport { packet, _, _ in
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 0x8888_999C, stamp: 83)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let brVal = lanBrightness.withValue { $0 }
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(brVal),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let localClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let ownWifi = MiDeviceRecord(
            did: "101",
            name: "LAN Bulb",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.48",
            token: tokenHex,
            isShared: false
        )
        let cloudOnly = MiDeviceRecord(
            did: "303",
            name: "Cloud Light",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: nil,
            token: nil,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [ownWifi, cloudOnly],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "303"])],
            props: [
                MiotPropKey(did: "303", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "303", siid: 2, piid: 2): .number(50),
            ]
        )
        await api.setGetPropsError(MiCloudError.http(429))

        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: localClient,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            deviceRefreshEveryPolls: 2,
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        #expect(await api.deviceListCalls == 1)
        #expect(await api.getPropsCalls.count == 1)
        #expect(await collector.snapshots.last?.closesAwayGap == false)

        clock.advance(by: 60)
        lanBrightness.withValue { $0 = 65 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 65
        })
        #expect(await api.deviceListCalls == 2)
        #expect(await api.getPropsCalls.count == 2)
        #expect(await collector.snapshots.last?.closesAwayGap == false)

        clock.advance(by: 65)
        lanBrightness.withValue { $0 = 70 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 70
        })
        #expect(await api.deviceListCalls == 2)
        #expect(await api.getPropsCalls.count == 2)

        clock.advance(by: 55)
        lanBrightness.withValue { $0 = 75 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 75
        })
        #expect(await api.deviceListCalls == 3)
        #expect(await api.getPropsCalls.count == 3)

        await api.setTopology(devices: [ownWifi], rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])])
        await api.setGetPropsError(nil)
        clock.advance(by: 240)
        lanBrightness.withValue { $0 = 80 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 80 && snap.closesAwayGap
        })
        #expect(await api.deviceListCalls == 4)
        #expect(await api.getPropsCalls.count == 3)

        await api.setDiscoveryError(URLError(.timedOut))
        lanBrightness.withValue { $0 = 85 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 85 && !snap.closesAwayGap
        })
        #expect(await api.deviceListCalls == 5)

        clock.advance(by: 3)
        await api.setDiscoveryError(nil)
        lanBrightness.withValue { $0 = 90 }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        #expect(await collector.wait {
            guard let snap = $0.snapshots.last else { return false }
            return lightBrightness(snap.devices.first { $0.id == "101" }) == 90 && snap.closesAwayGap
        })
        #expect(await api.deviceListCalls == 6)

        await provider.shutdown()
    }

    @Test("DHCP IP change triggers rate-limited broadcast self-heal with inline same-poll retry, persists effectiveIP to MiTopologyCache, and preserves override against stale cloud localIp")
    func dhcpIPChangeBroadcastRecoveryInlineRetryAndStaleCloudProtection() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex)), token2Hex = "112233445566778899aabbccddeeff00"
        let activeIP = LockedBox("192.168.1.40"), lanBrightness = LockedBox(70), d2ShouldFail = LockedBox(false)
        let udpTransport = MockUDPTransport { packet, host, _ in
            if host == "192.168.1.41", d2ShouldFail.withValue({ $0 }) { throw MiIOError.timeout }
            guard host == activeIP.withValue({ $0 }) else { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 100) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reply = #"{"id":\#(req["id"]?.intValue ?? 0),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(lanBrightness.withValue { $0 }),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await udpTransport.setBroadcastHandler { _, _, _ in [MiIOBroadcastReply(sourceIP: activeIP.withValue({ $0 }), packet: makeHelloResponse(deviceId: 101, stamp: 200))] }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("MiBroadcastSelfHeal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let topologyCache = MiTopologyCache(directory: cacheDir), clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let d1 = MiDeviceRecord(did: "101", name: "Lamp 1", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.40", token: tokenHex, isShared: false)
        let d2 = MiDeviceRecord(did: "102", name: "Lamp 2", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.41", token: token2Hex, isShared: false)
        let api = HybridMockCloudAPI(devices: [d1, d2], rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "102"])], props: [MiotPropKey(did: "102", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "102", siid: 2, piid: 2): .number(50)])
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession }, apiFactory: { _ in api }, specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }), topologyCache: topologyCache,
            lanFailureThreshold: 1, lanCooldownDuration: 30, broadcastSweepMinInterval: 60, now: { clock.now() },
            pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), deviceRefreshEveryPolls: 1, selectedHomeLoader: { nil }
        )
        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        let initialD1 = await provider.lanTransportState(for: "101"), initialD2 = await provider.lanTransportState(for: "102")
        #expect(initialD1.transportSucceeded && !initialD1.usedBroadcastRecovery && initialD2.isCoolingDown); #expect(await udpTransport.broadcastCalls == 1)

        d2ShouldFail.withValue { $0 = true }; activeIP.withValue { $0 = "192.168.1.88" }; lanBrightness.withValue { $0 = 88 }; clock.advance(by: 5)
        _ = await provider.readBack(deviceId: "101")
        #expect(await udpTransport.broadcastCalls == 1); #expect(await provider.lanTransportState(for: "101").isCoolingDown)

        clock.advance(by: 65)
        #expect(await provider.readBack(deviceId: "101") == .published); #expect(await udpTransport.broadcastCalls == 2)
        #expect(await collector.wait { lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 88 })
        let recoveredD1 = await provider.lanTransportState(for: "101")
        #expect(recoveredD1.transportSucceeded && !recoveredD1.isCoolingDown && recoveredD1.usedBroadcastRecovery && recoveredD1.lastRTTMs != nil && recoveredD1.effectiveIP == "192.168.1.88")
        #expect(topologyCache.load(for: stubSession)?.devices.first { $0.did == "101" }?.localIp == "192.168.1.40")
        #expect(topologyCache.load(for: stubSession)?.discoveredLANIPsByDid["101"] == "192.168.1.88")

        let broadcastsAfterHeal = await udpTransport.broadcastCalls
        clock.advance(by: 10); lanBrightness.withValue { $0 = 92 }; await provider.refreshNow()
        #expect(await collector.wait { lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 92 })
        #expect(await udpTransport.broadcastCalls == broadcastsAfterHeal + 1)
        #expect(topologyCache.load(for: stubSession)?.devices.first { $0.did == "101" }?.localIp == "192.168.1.40")
        #expect(topologyCache.load(for: stubSession)?.discoveredLANIPsByDid["101"] == "192.168.1.88")
        await provider.shutdown()
    }

    @Test("All-nonzero LAN reply during cloud failure records LAN transport health but leaves telemetryStale true")
    func allNonzeroLANReplyDuringCloudFailurePreservesLANRouteWithoutValidatingStaleTelemetry() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let secondDeviceFailTimeout = LockedBox(false), secondDeviceAllNonzero = LockedBox(false), firstDeviceAllNonzero = LockedBox(false)
        let udpTransport = MockUDPTransport { packet, host, _ in
            if host == "192.168.1.51", secondDeviceFailTimeout.withValue({ $0 }) { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: (host == "192.168.1.51") ? 102 : 101, stamp: 10) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let did = (host == "192.168.1.51") ? "102" : "101"
            let allNonzero = (did == "102") ? secondDeviceAllNonzero.withValue({ $0 }) : firstDeviceAllNonzero.withValue({ $0 })
            let br = (did == "102") ? 45 : 65
            let reply = allNonzero
                ? #"{"id":\#(reqId),"result":[{"did":"\#(did)","siid":2,"piid":1,"code":-4004},{"did":"\#(did)","siid":2,"piid":2,"code":-4004}]}"#
                : #"{"id":\#(reqId),"result":[{"did":"\#(did)","siid":2,"piid":1,"value":true,"code":0},{"did":"\#(did)","siid":2,"piid":2,"value":\#(br),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bulb1 = MiDeviceRecord(did: "101", name: "Healthy Bulb", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let bulb2 = MiDeviceRecord(did: "102", name: "Error Code Bulb", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.51", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(devices: [bulb1, bulb2], rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "102"])], props: [MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(65), MiotPropKey(did: "102", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "102", siid: 2, piid: 2): .number(45)])
        let provider = MiCloudProvider(sessionLoader: { self.stubSession }, apiFactory: { _ in api }, specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]), localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }), lanFailureThreshold: 3, now: { clock.now() }, pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), selectedHomeLoader: { nil })
        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait { $0.snapshots.last?.devices.count == 2 })
        secondDeviceFailTimeout.withValue { $0 = true }; _ = await provider.readBack(deviceId: "102")
        #expect(await provider.lanTransportState(for: "102").consecutiveFailures == 1)

        secondDeviceFailTimeout.withValue { $0 = false }; secondDeviceAllNonzero.withValue { $0 = true }
        await api.setGetPropsError(MiCloudError.http(429)); await provider.refreshNow()
        #expect(await collector.wait { ($0.snapshots.last?.closesAwayGap == false) && ($0.snapshots.last?.devices.first { $0.id == "102" }?.telemetryStale == true) })
        let snap = try #require(await collector.snapshots.last)
        #expect(try #require(snap.devices.first { $0.id == "101" }).telemetryStale == false)
        #expect(snap.deviceTransportDiagnostics["101"]?.route == .lan)
        #expect(try #require(snap.devices.first { $0.id == "102" }).telemetryStale == true)
        #expect(snap.deviceTransportDiagnostics["102"]?.route == .lan)
        let secondState = await provider.lanTransportState(for: "102")
        #expect(secondState.transportSucceeded && secondState.consecutiveFailures == 0)

        firstDeviceAllNonzero.withValue { $0 = true }; clock.advance(by: 65); await provider.refreshNow()
        #expect(await collector.wait { if case .disconnected = $0.statuses.last { return true }; return false })
        await provider.shutdown()
    }

    @Test("Pre-send localNetworkDenied on action falls back to cloud without ambiguous outcome, skips broadcast sweep while blocked, and recovers on refreshNow")
    func localNetworkDeniedActionFallbackSweepSkipAndRefreshRecovery() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let denyLocalNetwork = LockedBox(false)

        let udpCalls = LockedBox(0)
        let udpTransport = MockUDPTransport { packet, _, _ in
            udpCalls.withValue { $0 += 1 }
            if denyLocalNetwork.withValue({ $0 }) { throw MiIOError.localNetworkDenied }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":65,"code":0},{"did":"102","siid":2,"piid":1,"value":true,"code":0},{"did":"102","siid":2,"piid":2,"value":70,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await udpTransport.setBroadcastHandler { _, _, _ in throw MiIOError.localNetworkDenied }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let ownWifi1 = MiDeviceRecord(did: "101", name: "Speaker Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let ownWifi2 = MiDeviceRecord(did: "102", name: "Desk Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.51", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi1, ownWifi2],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "102"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(55),
                MiotPropKey(did: "102", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "102", siid: 2, piid: 2): .number(60),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightWithNotifyActionSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 1, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 1,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["102"]?.route == .lan
        })

        denyLocalNetwork.withValue { $0 = true }
        try await provider.execute(.sendNotifyMessage(entityId: "miot-action:101:7:3", message: "tcc-fallback"))
        #expect(await api.actionCalls == [MiotActionCall(did: "101", siid: 7, aiid: 3, inputs: [.string("tcc-fallback")])])
        #expect(await collector.wait { $0.localNetworkPermissions.last == [.xiaomiLAN] })
        let blockedStateAfterAction = await provider.lanTransportState(for: "101")
        #expect(blockedStateAfterAction.consecutiveFailures == 0)
        #expect(blockedStateAfterAction.isCoolingDown == false)

        // While permission is denied, another command skips LAN UDP completely and goes straight to cloud.
        let callsBeforeSecondExecute = udpCalls.withValue { $0 }
        try await provider.execute(.sendNotifyMessage(entityId: "miot-action:102:7:3", message: "tcc-fallback-2"))
        #expect(udpCalls.withValue({ $0 }) == callsBeforeSecondExecute)

        clock.advance(by: 5)
        _ = await provider.readBack(deviceId: "101")
        #expect(await udpTransport.broadcastCalls == 0)
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked
                && $0.snapshots.last?.deviceTransportDiagnostics["101"]?.consecutiveFailures == 0
                && $0.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN]
        })

        // Grant Local Network permission while still inside the 30s cooldown window; even a
        // regular poll / readBack (before refreshNow) must immediately retry LAN and recover.
        denyLocalNetwork.withValue { $0 = false }
        clock.advance(by: 5)
        let readBackAfterGrant = await provider.readBack(deviceId: "101")
        #expect(readBackAfterGrant == .published)
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.localNetworkBlockedFeatures.isEmpty == true
                && $0.localNetworkPermissions.last == []
        })

        // Verify refreshNow also clears a blocked state and recovers all LAN devices immediately.
        denyLocalNetwork.withValue { $0 = true }
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked
                && $0.snapshots.last?.deviceTransportDiagnostics["102"]?.route == .localNetworkBlocked
                && $0.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN]
        })
        denyLocalNetwork.withValue { $0 = false }
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["102"]?.route == .lan
                && $0.snapshots.last?.localNetworkBlockedFeatures.isEmpty == true
                && $0.localNetworkPermissions.last == []
        })

        await provider.shutdown()
    }

    @Test("Non-denied LAN errors clear localNetworkDenied and allow broadcast recovery when device IP changed after granting permission")
    func nonDeniedLANErrorClearsLocalNetworkDeniedAndRecoversViaBroadcast() async throws {
        enum UDPMode: Sendable {
            case healthy
            case denied
            case ipMovedTo180
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpMode = LockedBox(UDPMode.healthy)
        let udpTransport = MockUDPTransport { packet, host, _ in
            switch udpMode.withValue({ $0 }) {
            case .denied:
                throw MiIOError.localNetworkDenied
            case .ipMovedTo180:
                guard host == "192.168.1.180" else { throw MiIOError.timeout }
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":65,"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            case .healthy:
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":65,"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            switch udpMode.withValue({ $0 }) {
            case .denied:
                throw MiIOError.localNetworkDenied
            case .ipMovedTo180:
                return [MiIOBroadcastReply(sourceIP: "192.168.1.180", packet: makeHelloResponse(deviceId: 101, stamp: 15))]
            case .healthy:
                return []
            }
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let ownWifi1 = MiDeviceRecord(did: "101", name: "Speaker Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi1],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(55),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
        })

        // Enter localNetworkDenied state.
        udpMode.withValue { $0 = .denied }
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN]
                && $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked
        })

        // Refresh while still denied must NOT emit an intermediate [] permission event or clear snapshot flags.
        let permsBeforeDeniedRefresh = await collector.localNetworkPermissions.count
        let snapsBeforeDeniedRefresh = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count >= snapsBeforeDeniedRefresh + 2 })
        let permsDuringDeniedRefresh = await collector.localNetworkPermissions.dropFirst(permsBeforeDeniedRefresh)
        let snapsDuringDeniedRefresh = await collector.snapshots.dropFirst(snapsBeforeDeniedRefresh)
        #expect(!permsDuringDeniedRefresh.contains([]))
        #expect(snapsDuringDeniedRefresh.allSatisfy { $0.localNetworkBlockedFeatures == [.xiaomiLAN] })

        // User grants Local Network permission, but device IP moved from .50 to .180.
        // Unicast to .50 times out (passing TCC), so provider must clear localNetworkDenied,
        // increment consecutiveFailures to reach threshold, run broadcast sweep, and self-heal to .180!
        udpMode.withValue { $0 = .ipMovedTo180 }
        clock.advance(by: 2)
        let snapsBeforeRecovery = await collector.snapshots.count
        _ = await provider.readBack(deviceId: "101")
        #expect(await collector.wait { $0.snapshots.count > snapsBeforeRecovery })
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures.isEmpty == true)
        #expect(await collector.localNetworkPermissions.last == [])
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan)
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["101"]?.usedBroadcastRecovery == true)
        #expect(await provider.lanTransportState(for: "101").effectiveIP == "192.168.1.180")

        await provider.shutdown()
    }

    @Test("Broadcast sweep localNetworkDenied does not leave devices trapped in cooldown on subsequent refreshNow")
    func broadcastSweepLocalNetworkDeniedDoesNotTrapDeviceInCooldown() async throws {
        enum UDPMode: Sendable {
            case healthy
            case timeoutUnicastDeniedBroadcast
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpMode = LockedBox(UDPMode.healthy)
        let udpTransport = MockUDPTransport { packet, _, _ in
            switch udpMode.withValue({ $0 }) {
            case .timeoutUnicastDeniedBroadcast:
                throw MiIOError.timeout
            case .healthy:
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":65,"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            if udpMode.withValue({ $0 }) == .timeoutUnicastDeniedBroadcast {
                throw MiIOError.localNetworkDenied
            }
            return []
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let ownWifi = MiDeviceRecord(did: "101", name: "Speaker Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [ownWifi],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(55)]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 1,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait { $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan })

        udpMode.withValue { $0 = .timeoutUnicastDeniedBroadcast }
        clock.advance(by: 2)
        let snapsBeforeSweep = await collector.snapshots.count
        _ = await provider.readBack(deviceId: "101")
        #expect(await collector.wait { $0.snapshots.count > snapsBeforeSweep })
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN])
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked)
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == false)

        // Grant permission while still inside the 30s cooldown window; refreshNow must immediately probe and recover.
        udpMode.withValue { $0 = .healthy }
        clock.advance(by: 2)
        let snapsBeforeRecovery = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count >= snapsBeforeRecovery + 2 })
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan)
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures.isEmpty == true)
        #expect(await collector.localNetworkPermissions.last == [])

        await provider.shutdown()
    }

    @Test("Manual refresh and system wake trigger broadcast discovery for devices in LAN cooldown while preserving sweep rate limit")
    func refreshAndWakeSweepCoolingDownDevicesWithRateLimit() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let d1IP = LockedBox("192.168.1.40")
        let d1OnlineOnLAN = LockedBox(false)
        let lanBrightness = LockedBox(75)

        let udpTransport = MockUDPTransport { packet, host, _ in
            guard d1OnlineOnLAN.withValue({ $0 }), host == d1IP.withValue({ $0 }) else {
                throw MiIOError.timeout
            }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 100) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reply = #"{"id":\#(req["id"]?.intValue ?? 0),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(lanBrightness.withValue { $0 }),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            guard d1OnlineOnLAN.withValue({ $0 }) else { return [] }
            return [MiIOBroadcastReply(sourceIP: d1IP.withValue({ $0 }), packet: makeHelloResponse(deviceId: 101, stamp: 200))]
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let d1 = MiDeviceRecord(did: "101", name: "Study Lamp", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.40", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [d1],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(40)]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 300,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )
        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        // Initial poll: device fails unicast, runs cold-start sweep (#1), and enters 300s LAN cooldown.
        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)
        #expect(await udpTransport.broadcastCalls == 1)

        // Manual refresh at t=5 while device is still offline and cooling down triggers ONE sweep (#2),
        // then repeated manual refreshes within broadcastSweepMinInterval (60s) stay rate-limited!
        clock.advance(by: 5)
        await provider.refreshNow()
        #expect(await udpTransport.broadcastCalls == 2)
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)

        clock.advance(by: 5)
        await provider.refreshNow()
        #expect(await udpTransport.broadcastCalls == 2)

        // Once broadcastSweepMinInterval (60s) has elapsed, device is STILL inside 300s cooldown,
        // and comes back on a new DHCP IP (.188). Manual refresh sweeps (#3) and heals inline!
        d1IP.withValue { $0 = "192.168.1.188" }
        d1OnlineOnLAN.withValue { $0 = true }
        lanBrightness.withValue { $0 = 84 }
        clock.advance(by: 60)
        await provider.refreshNow()
        #expect(await udpTransport.broadcastCalls == 3)
        #expect(await collector.wait { lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 84 })
        let healedAfterRefresh = await provider.lanTransportState(for: "101")
        #expect(healedAfterRefresh.transportSucceeded && !healedAfterRefresh.isCoolingDown && healedAfterRefresh.effectiveIP == "192.168.1.188")

        // Now test system wake: move device again so it enters 300s cooldown at t=140, then wake at t=145.
        d1OnlineOnLAN.withValue { $0 = false }
        clock.advance(by: 70)
        _ = await provider.readBack(deviceId: "101")
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)
        let broadcastsBeforeWake = await udpTransport.broadcastCalls

        // Advance past manual-refresh rate limit from t=70 (now at t=145 -> 75s >= 60s), bring device online at .199,
        // and transition systemActive false -> true: wake poll must sweep cooling-down device once and heal!
        d1IP.withValue { $0 = "192.168.1.199" }
        d1OnlineOnLAN.withValue { $0 = true }
        lanBrightness.withValue { $0 = 91 }
        clock.advance(by: 5)
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 91 })
        #expect(await udpTransport.broadcastCalls == broadcastsBeforeWake + 1)
        #expect(await provider.lanTransportState(for: "101").effectiveIP == "192.168.1.199")

        await provider.shutdown()
    }

    @Test("Pre-send errors and mixed-denial batches keep Local Network blocked until a packet crosses the permission boundary")
    func preSendAndMixedBatchErrorsDoNotClearLocalNetworkDenied() async throws {
        enum Mode: Sendable {
            case healthy
            case denied
            case preSendUnreachable
            case preSendTransportUnavailable
            case mixedDenialAndTimeout
            case postSendTimeoutMovedIP
        }
        actor Gate {
            private var opened = false
            private var waiters: [CheckedContinuation<Void, Never>] = []
            func open() {
                opened = true
                let list = waiters
                waiters.removeAll()
                for waiter in list { waiter.resume() }
            }
            func wait() async {
                if opened { return }
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let mode = LockedBox(Mode.denied)
        let mixedGate = Gate()
        let lanBrightness = LockedBox(72)

        let udpTransport = MockUDPTransport { packet, host, _ in
            switch mode.withValue({ $0 }) {
            case .denied:
                throw MiIOError.localNetworkDenied
            case .preSendUnreachable:
                throw POSIXError(.ENETUNREACH)
            case .preSendTransportUnavailable:
                throw MiIOError.transportUnavailable
            case .mixedDenialAndTimeout:
                if host == "192.168.1.50" {
                    await mixedGate.open()
                    throw MiIOError.localNetworkDenied
                }
                await mixedGate.wait()
                throw MiIOError.timeout
            case .postSendTimeoutMovedIP:
                guard host == "192.168.1.150" || host == "192.168.1.151" else {
                    throw MiIOError.timeout
                }
                let devId: UInt32 = host == "192.168.1.150" ? 101 : 102
                let didStr = host == "192.168.1.150" ? "101" : "102"
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: devId, stamp: 20) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let bri = lanBrightness.withValue { $0 }
                let reply = #"{"id":\#(reqId),"result":[{"did":"\#(didStr)","siid":2,"piid":1,"value":true,"code":0},{"did":"\#(didStr)","siid":2,"piid":2,"value":\#(bri),"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            case .healthy:
                let devId: UInt32 = host == "192.168.1.50" ? 101 : 102
                let didStr = host == "192.168.1.50" ? "101" : "102"
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: devId, stamp: 10) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let bri = lanBrightness.withValue { $0 }
                let reply = #"{"id":\#(reqId),"result":[{"did":"\#(didStr)","siid":2,"piid":1,"value":true,"code":0},{"did":"\#(didStr)","siid":2,"piid":2,"value":\#(bri),"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            guard mode.withValue({ $0 }) == .postSendTimeoutMovedIP else { return [] }
            return [
                MiIOBroadcastReply(sourceIP: "192.168.1.150", packet: makeHelloResponse(deviceId: 101, stamp: 21)),
                MiIOBroadcastReply(sourceIP: "192.168.1.151", packet: makeHelloResponse(deviceId: 102, stamp: 22)),
            ]
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let d1 = MiDeviceRecord(did: "101", name: "Lamp 1", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let d2 = MiDeviceRecord(did: "102", name: "Lamp 2", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.51", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [d1, d2],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "102"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(40),
                MiotPropKey(did: "102", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "102", siid: 2, piid: 2): .number(40),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream { await collector.append(event) }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN] })

        // Pre-send socket failure (ENETUNREACH) must NOT clear Local Network blocked state.
        mode.withValue { $0 = .preSendUnreachable }
        clock.advance(by: 65)
        let beforePreSend1 = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count >= beforePreSend1 + 2 })
        #expect(await collector.localNetworkPermissions.last == [.xiaomiLAN])
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN])

        // Pre-send transportUnavailable must NOT clear Local Network blocked state either.
        mode.withValue { $0 = .preSendTransportUnavailable }
        clock.advance(by: 65)
        let beforePreSend2 = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count >= beforePreSend2 + 2 })
        #expect(await collector.localNetworkPermissions.last == [.xiaomiLAN])
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN])

        // Healthy LAN poll crosses permission boundary and clears [.xiaomiLAN].
        mode.withValue { $0 = .healthy }
        clock.advance(by: 65)
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.last?.localNetworkBlockedFeatures == [] })
        #expect(await collector.localNetworkPermissions.last == [])

        #expect(MiIOError.provesPacketCrossedPermissionBoundary(MiIOError.sendFailed) == false)
        #expect(MiIOError.provesPacketCrossedPermissionBoundary(MiIOError.transportUnavailable) == false)
        #expect(MiIOError.provesPacketCrossedPermissionBoundary(MiIOError.timeout) == true)
        #expect(MiIOError.provesPacketCrossedPermissionBoundary(MiIOError.handshakeFailed) == true)

        // Mixed parallel poll: 101 fails with localNetworkDenied first, 102 finishes after with timeout.
        // The batch denial must win and keep [.xiaomiLAN] active without clearing it!
        mode.withValue { $0 = .mixedDenialAndTimeout }
        clock.advance(by: 65)
        let beforeMixed = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count >= beforeMixed + 2 })
        #expect(await collector.localNetworkPermissions.last == [.xiaomiLAN])
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN])

        // Once permission is granted and devices moved IP, a real post-send timeout crosses the
        // permission boundary, clears [.xiaomiLAN], and heals via broadcast sweep.
        mode.withValue { $0 = .postSendTimeoutMovedIP }
        lanBrightness.withValue { $0 = 88 }
        clock.advance(by: 65)
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.snapshots.last?.localNetworkBlockedFeatures == []
                && lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 88
        })
        #expect(await collector.localNetworkPermissions.last == [])

        await provider.shutdown()

        // Also verify HAWebSocketProvider does not clear [.homeAssistant] on pre-send offline -1009,
        // and clears it once a server frame (e.g. unauthorized) proves packets crossed the boundary.
        let haMode = LockedBox(0) // 0 = EPERM, 1 = offline -1009, 2 = unauthorized
        let haProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.50:8123",
            token: "ha-tok",
            allowsToken: { _ in true },
            isNetworkSatisfied: { haMode.withValue({ $0 }) != 1 }
        )
        await haProvider.setTestSeams(
            connectOverride: {
                switch haMode.withValue({ $0 }) {
                case 0:
                    return .failedBeforeAuth(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
                case 1:
                    return .failedBeforeAuth(URLError(.notConnectedToInternet))
                default:
                    return .failedBeforeAuth(HomeProviderError.unauthorized)
                }
            },
            reconnectSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let haCollector = EventCollector()
        let haStream = haProvider.events()
        let haTask = Task {
            for await event in haStream { await haCollector.append(event) }
            await haCollector.finish()
        }
        defer { haTask.cancel() }

        #expect(await haCollector.wait {
            $0.localNetworkPermissions.last == [.homeAssistant]
                && $0.statuses.filter { if case .disconnected = $0 { return true }; return false }.count >= 1
        })

        haMode.withValue { $0 = 1 }
        await haProvider.refreshNow()
        #expect(await haCollector.wait {
            $0.statuses.filter { if case .disconnected = $0 { return true }; return false }.count >= 2
        })
        #expect(await haCollector.localNetworkPermissions.last == [.homeAssistant])

        haMode.withValue { $0 = 2 }
        await haProvider.refreshNow()
        #expect(await haCollector.wait {
            $0.statuses.filter { if case .disconnected = $0 { return true }; return false }.count >= 3
        })
        #expect(await haCollector.localNetworkPermissions.last == [])

        await haProvider.shutdown()
    }

    @Test("Mixed-batch pre-send errors record as blocked without cooldown, broadcast retry stops on localNetworkDenied, and probe gate only skips on localNetworkDenied")
    func lanSelfHealFollowUpsMixedBatchBroadcastBreakAndProbeGate() async throws {
        enum Mode: Sendable {
            case mixedDeniedPreSendAndTimeout
            case probeDenied
            case probeSendFailedOthersHealthyAndSweepHeals101
            case probeTimeoutOthersHealthy
            case timeoutThenBroadcastRetryDeniedOnFirst
            case healthy
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let mode = LockedBox(Mode.mixedDeniedPreSendAndTimeout)
        let hostAttempts = LockedBox<[String]>([])
        let postDiscoveryRetryHosts = LockedBox<[String]>([])

        let udpTransport = MockUDPTransport { packet, host, _ in
            hostAttempts.withValue { $0.append(host) }
            let replyForHost: (String, UInt32) throws -> Data = { did, devId in
                if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: devId, stamp: 30) }
                let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
                let reply = #"{"id":\#(reqId),"result":[{"did":"\#(did)","siid":2,"piid":1,"value":true,"code":0},{"did":"\#(did)","siid":2,"piid":2,"value":77,"code":0}]}"#
                return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
            }
            switch mode.withValue({ $0 }) {
            case .mixedDeniedPreSendAndTimeout:
                switch host {
                case "192.168.1.50": throw MiIOError.localNetworkDenied
                case "192.168.1.51": throw MiIOError.sendFailed
                default: throw MiIOError.timeout
                }
            case .probeDenied:
                throw MiIOError.localNetworkDenied
            case .probeSendFailedOthersHealthyAndSweepHeals101:
                switch host {
                case "192.168.1.50": throw MiIOError.sendFailed
                case "192.168.1.181": return try replyForHost("101", 101)
                case "192.168.1.51": return try replyForHost("102", 102)
                case "192.168.1.183": return try replyForHost("103", 103)
                default: throw MiIOError.timeout
                }
            case .probeTimeoutOthersHealthy:
                switch host {
                case "192.168.1.181": throw MiIOError.timeout
                case "192.168.1.51": return try replyForHost("102", 102)
                case "192.168.1.52", "192.168.1.183": return try replyForHost("103", 103)
                default: throw MiIOError.timeout
                }
            case .timeoutThenBroadcastRetryDeniedOnFirst:
                switch host {
                case "192.168.1.191", "192.168.1.192", "192.168.1.193":
                    let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
                    let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
                    let firstSiid = req["params"]?.arrayValue?.first?["siid"]?.intValue ?? 0
                    if firstSiid == 1 {
                        // Broadcast discovery verification probe succeeds for all 3 candidates.
                        let reqId = req["id"]?.intValue ?? 0
                        return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(#"{"id":\#(reqId),"result":[]}"#.utf8))
                    }
                    // Post-discovery retry getProps (siid == 2) fails with localNetworkDenied.
                    postDiscoveryRetryHosts.withValue { $0.append(host) }
                    throw MiIOError.localNetworkDenied
                default:
                    throw MiIOError.timeout
                }
            case .healthy:
                switch host {
                case "192.168.1.50", "192.168.1.181", "192.168.1.191": return try replyForHost("101", 101)
                case "192.168.1.51", "192.168.1.192": return try replyForHost("102", 102)
                default: return try replyForHost("103", 103)
                }
            }
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            switch mode.withValue({ $0 }) {
            case .probeSendFailedOthersHealthyAndSweepHeals101:
                return [
                    MiIOBroadcastReply(sourceIP: "192.168.1.181", packet: makeHelloResponse(deviceId: 101, stamp: 40)),
                    MiIOBroadcastReply(sourceIP: "192.168.1.183", packet: makeHelloResponse(deviceId: 103, stamp: 40)),
                ]
            case .timeoutThenBroadcastRetryDeniedOnFirst:
                return [
                    MiIOBroadcastReply(sourceIP: "192.168.1.191", packet: makeHelloResponse(deviceId: 101, stamp: 41)),
                    MiIOBroadcastReply(sourceIP: "192.168.1.192", packet: makeHelloResponse(deviceId: 102, stamp: 42)),
                    MiIOBroadcastReply(sourceIP: "192.168.1.193", packet: makeHelloResponse(deviceId: 103, stamp: 43)),
                ]
            default:
                return []
            }
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let d1 = MiDeviceRecord(did: "101", name: "Lamp 1", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.50", token: tokenHex, isShared: false)
        let d2 = MiDeviceRecord(did: "102", name: "Lamp 2", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.51", token: tokenHex, isShared: false)
        let d3 = MiDeviceRecord(did: "103", name: "Lamp 3", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.52", token: tokenHex, isShared: false)
        let api = HybridMockCloudAPI(
            devices: [d1, d2, d3],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "102", "103"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(40),
                MiotPropKey(did: "102", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "102", siid: 2, piid: 2): .number(40),
                MiotPropKey(did: "103", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "103", siid: 2, piid: 2): .number(40),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        // 1. Mixed batch: 101 throws .localNetworkDenied, 102 throws pre-send .sendFailed, 103 throws post-send .timeout.
        // 101 and 102 must both record as .localNetworkBlocked without entering cooldown; 103 must NOT be mislabeled as blocked.
        #expect(await collector.wait { $0.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN] })
        let snap1 = try #require(await collector.snapshots.last)
        #expect(snap1.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked)
        #expect(snap1.deviceTransportDiagnostics["102"]?.route == .localNetworkBlocked)
        #expect(snap1.deviceTransportDiagnostics["103"]?.route == .cooldown)
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "102").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "102").consecutiveFailures == 0)
        #expect(await provider.lanTransportState(for: "103").isCoolingDown == true)

        // 3a. While denied, if probe (101) fails with .localNetworkDenied, remaining devices (102, 103) must be skipped (no request storm).
        mode.withValue { $0 = .probeDenied }
        hostAttempts.withValue { $0.removeAll() }
        clock.advance(by: 2)
        let beforeDeniedProbeSnaps = await collector.snapshots.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { $0.snapshots.count >= beforeDeniedProbeSnaps + 1 })
        #expect(hostAttempts.withValue { $0 } == ["192.168.1.50"])
        #expect(await provider.lanTransportState(for: "103").isCoolingDown == true)

        // 3b. System wake while still denied and still inside 103's 30s cooldown (clock + 5s), with permission restored and 101/103 moved to .181/.183:
        // Probe (101) fails with pre-send .transportUnavailable (or .sendFailed), remaining non-cooling-down device (102) succeeds and clears denied state,
        // and the wake broadcast sweep must include BOTH failed 101 AND cooling-down 103 so both heal to .181 and .183 in the same wake poll!
        mode.withValue { $0 = .probeSendFailedOthersHealthyAndSweepHeals101 }
        hostAttempts.withValue { $0.removeAll() }
        clock.advance(by: 5) // still inside 103's 30s cooldown!
        let beforeWakeHealSnaps = await collector.snapshots.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { $0.snapshots.count >= beforeWakeHealSnaps + 1 })
        let snapAfterWakeHeal = try #require(await collector.snapshots.last)
        #expect(snapAfterWakeHeal.localNetworkBlockedFeatures == [])
        #expect(snapAfterWakeHeal.deviceTransportDiagnostics["101"]?.route == .lan)
        #expect(snapAfterWakeHeal.deviceTransportDiagnostics["102"]?.route == .lan)
        #expect(snapAfterWakeHeal.deviceTransportDiagnostics["103"]?.route == .lan)
        #expect(await provider.lanTransportState(for: "101").effectiveIP == "192.168.1.181")
        #expect(await provider.lanTransportState(for: "103").effectiveIP == "192.168.1.183")

        // 3c. Re-enter denied state, then probe (101) times out (.timeout): remaining devices (102, 103) must still run and succeed.
        mode.withValue { $0 = .probeDenied }
        clock.advance(by: 2)
        let beforeReDenySnaps = await collector.snapshots.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { $0.snapshots.count >= beforeReDenySnaps + 1 })
        #expect(await collector.snapshots.last?.localNetworkBlockedFeatures == [.xiaomiLAN])

        mode.withValue { $0 = .probeTimeoutOthersHealthy }
        hostAttempts.withValue { $0.removeAll() }
        clock.advance(by: 2)
        let beforeTimeoutProbeSnaps = await collector.snapshots.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { $0.snapshots.count >= beforeTimeoutProbeSnaps + 1 })
        let snapAfterTimeoutProbe = try #require(await collector.snapshots.last)
        #expect(snapAfterTimeoutProbe.localNetworkBlockedFeatures == [])
        #expect(snapAfterTimeoutProbe.deviceTransportDiagnostics["102"]?.route == .lan)
        #expect(snapAfterTimeoutProbe.deviceTransportDiagnostics["103"]?.route == .lan)

        // 2. Broadcast discovery recovers 101/102/103 to .191/.192/.193, then the post-discovery retry loop
        // hits .localNetworkDenied on the first candidate: it must break immediately without retrying the other two,
        // and mark all remaining candidates as .localNetworkBlocked without cooldown!
        mode.withValue { $0 = .timeoutThenBroadcastRetryDeniedOnFirst }
        hostAttempts.withValue { $0.removeAll() }
        postDiscoveryRetryHosts.withValue { $0.removeAll() }
        clock.advance(by: 65) // allow broadcast sweep
        let beforeRetryBreakSnaps = await collector.snapshots.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        #expect(await collector.wait { $0.snapshots.count >= beforeRetryBreakSnaps + 1 })
        #expect(postDiscoveryRetryHosts.withValue { $0.count } == 1)
        let snapAfterRetryBreak = try #require(await collector.snapshots.last)
        #expect(snapAfterRetryBreak.localNetworkBlockedFeatures == [.xiaomiLAN])
        #expect(snapAfterRetryBreak.deviceTransportDiagnostics["101"]?.route == .localNetworkBlocked)
        #expect(snapAfterRetryBreak.deviceTransportDiagnostics["102"]?.route == .localNetworkBlocked)
        #expect(snapAfterRetryBreak.deviceTransportDiagnostics["103"]?.route == .localNetworkBlocked)
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "102").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "103").isCoolingDown == false)

        await provider.shutdown()
    }
    @Test("retryLAN and HomeStore.retryDeviceLAN clear ordinary LAN failure cooldowns immediately without waiting for cooldown or wake windows")
    func retryLANClearsOrdinaryCooldownImmediately() async throws {
        enum UDPMode: Sendable {
            case healthy
            case timeout
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let onProp = MiotProperty(
            iid: 1,
            type: "urn:miot-spec-v2:property:on:00000006:lemesh-sw2f12:1",
            format: "bool",
            access: ["read", "write", "notify"]
        )
        let wallSwitchSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:switch:0000A003:lemesh-sw2f12:1",
            services: [
                MiotService(iid: 2, type: "urn:miot-spec-v2:service:switch:0000780C:lemesh-sw2f12:1", properties: [onProp]),
            ]
        )
        let udpMode = LockedBox(UDPMode.healthy)
        let udpTransport = MockUDPTransport { packet, host, _ in
            guard udpMode.withValue({ $0 }) == .healthy else { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: host == "192.168.1.50" ? 101 : 100, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let reply: String
            if host == "192.168.1.50" {
                reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":65,"code":0}]}"#
            } else {
                reply = #"{"id":\#(reqId),"result":[{"did":"100","siid":2,"piid":1,"value":true,"code":0}]}"#
            }
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let light = MiDeviceRecord(
            did: "101",
            name: "Desk Lamp",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.50",
            mac: "AA:BB:CC:DD:EE:01",
            token: tokenHex,
            isShared: false
        )
        let splitParent = MiDeviceRecord(
            did: "100",
            name: "Wall Switch",
            model: "lemesh.switch.sw2f12",
            isOnline: true,
            localIp: "192.168.1.60",
            token: tokenHex,
            isShared: false
        )
        let splitChild = MiDeviceRecord(
            did: "100.s2",
            name: "Ceiling Key",
            model: "lemesh.switch.sw2f12",
            isOnline: true,
            splitParentDid: "100",
            splitSiid: 2
        )
        let api = HybridMockCloudAPI(
            devices: [light, splitParent, splitChild],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "100.s2"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(55),
                MiotPropKey(did: "100", siid: 2, piid: 1): .bool(true),
            ]
        )
        let specSource = HybridMockSpecSource(specs: [
            "yeelink.light.color4": lightSpec(),
            "lemesh.switch.sw2f12": wallSwitchSpec,
        ])
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: specSource,
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .lan
        })

        // Trigger ordinary LAN timeouts so both devices enter `.cooldown` (not `.localNetworkBlocked`).
        udpMode.withValue { $0 = .timeout }
        await provider.refreshNow()
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown
                && $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .cooldown
                && $0.snapshots.last?.localNetworkBlockedFeatures.isEmpty == true
        })

        // Network recovers while still inside the 30s LAN cooldown. Plain `refreshNow()` polls cloud
        // and emits snapshots, but must NOT clear ordinary LAN failure cooldowns.
        udpMode.withValue { $0 = .healthy }
        clock.advance(by: 2)
        let snapsBeforePlainRefresh = await collector.snapshots.count
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.count > snapsBeforePlainRefresh })
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown)
        #expect(await collector.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .cooldown)

        // Explicit per-device `retryLAN(deviceId: "101")` clears `"101"`'s cooldown right away and
        // leaves `"100.s2"`'s cooldown intact.
        await provider.retryLAN(deviceId: "101")
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .cooldown
        })
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "101").consecutiveFailures == 0)

        // Put `"101"` back into `.cooldown` via system wake (arming `lastWakePollAt` on `ContinuousClock`),
        // then verify `retryLAN` bypasses `withinWakeCooldown` AND resolves split child `"100.s2"` -> `"100"`.
        udpMode.withValue { $0 = .timeout }
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false))
        clock.advance(by: 1)
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true))
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown
                && $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .cooldown
        })
        udpMode.withValue { $0 = .healthy }
        clock.advance(by: 1)
        await provider.refreshNow()
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)

        await provider.retryLAN(deviceId: "100.s2")
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown
        })

        // `retryLAN(deviceId: nil)` clears all remaining LAN failure cooldowns.
        await provider.retryLAN(deviceId: nil)
        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["100.s2"]?.route == .lan
        })

        await provider.shutdown()

        // End-to-end check through HomeStore.retryDeviceLAN -> DualSourceHomeProvider (canonical HA ID)
        // -> MiAccountsProvider -> MiCloudProvider without waiting for the 30s cooldown to expire.
        let haLight = SmartDevice(
            id: "ha-desk-lamp",
            name: "Desk Lamp",
            roomId: "ha-r1",
            roomName: "Study",
            model: "yeelink.light.color4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.desk_lamp", isOn: true, brightnessPercent: 55))
        )
        var haSnapshot = SynthesizedHome(devices: [haLight], scenes: [])
        haSnapshot.deviceIdentities = [
            "ha-desk-lamp": DeviceSourceIdentity(
                dids: [],
                macAddresses: ["AA:BB:CC:DD:EE:01"],
                uniqueIds: ["ha-desk-lamp"],
                model: "yeelink.light.color4",
                name: "Desk Lamp",
                roomName: "Study",
                kindTag: .light
            ),
        ]
        let haMock = MockHomeProvider(snapshot: haSnapshot)
        let accounts = MiAccountsProvider(
            accounts: [MiAccount(session: self.stubSession)],
            apiFactory: { _ in api },
            specSource: specSource,
            localClientFactory: { LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }) },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )
        let dual = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: accounts,
            pinnedBackends: { ["ha-desk-lamp": .xiaomiCloud] }
        )
        let suiteName = "test.retrylan.store.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = await MainActor.run { HomeStore(provider: dual, defaultsSuiteName: suiteName) }
        try await store.waitForTestSnapshot()
        await waitUntil {
            store.deviceTransportDiagnostics["ha-desk-lamp"]?.route == DeviceTransportRoute.lan
        }

        // Default child `lanFailureThreshold` is 3: three failed polls enter `.cooldown`.
        udpMode.withValue { $0 = .timeout }
        await dual.refreshNow()
        await dual.refreshNow()
        await dual.refreshNow()
        await waitUntil {
            store.deviceTransportDiagnostics["ha-desk-lamp"]?.route == DeviceTransportRoute.cooldown
        }
        #expect(await MainActor.run { store.effectiveLocalNetworkBlocks.isEmpty })

        // Recover via `store.retryDeviceLAN("ha-desk-lamp")` (canonical HA card ID mapped to Mi `"101"`).
        udpMode.withValue { $0 = .healthy }
        let retryTask = await MainActor.run { store.retryDeviceLAN("ha-desk-lamp") }
        _ = await retryTask.result
        await waitUntil {
            store.deviceTransportDiagnostics["ha-desk-lamp"]?.route == DeviceTransportRoute.lan
        }
        #expect(await MainActor.run { store.deviceTransportDiagnostics["ha-desk-lamp"]?.route == DeviceTransportRoute.lan })

        await store.shutdown()
    }

    @Test("In-flight poll finishing late or throwing never flickers device route to cloud or drops manual retryLAN")
    func retryLANDuringInFlightPollAvoidsFlickerAndSurvivesOldPollFailure() async throws {
        enum UDPMode: Sendable {
            case healthy
            case timeout
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpMode = LockedBox(UDPMode.healthy)
        let udpTransport = MockUDPTransport { packet, _, _ in
            guard udpMode.withValue({ $0 }) == .healthy else { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 101, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":88,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let light = MiDeviceRecord(
            did: "101",
            name: "Desk Lamp",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.50",
            mac: "AA:BB:CC:DD:EE:01",
            token: tokenHex,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [light],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(40),
            ]
        )
        let specSource = HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()])
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: specSource,
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait { $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan })

        // Part A: Put "101" into `.cooldown`, then pause an in-flight cloud refresh in `getProps`.
        udpMode.withValue { $0 = .timeout }
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown })

        udpMode.withValue { $0 = .healthy }
        let latePollGate = ProbeConcurrencyGate(expectedParkedProbes: 1)
        await api.setGetPropsHook { _ in
            await latePollGate.park()
        }
        let inFlightRefresh = Task { await provider.refreshNow() }
        await latePollGate.waitUntilAllParked()

        // Tap manual retry while the old poll is still parked in cloud `getProps`.
        let snapCountBeforeRetry = await collector.snapshots.count
        await provider.retryLAN(deviceId: "101")
        // Cooldown must stay intact until the in-flight poll finishes so it cannot emit `.cloud`.
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)

        await api.setGetPropsHook(nil)
        await latePollGate.release()
        await inFlightRefresh.value

        #expect(await collector.wait { $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan })
        let allSnapsAfterLate = await collector.snapshots
        let routesAfterRetry = allSnapsAfterLate.dropFirst(snapCountBeforeRetry).compactMap {
            $0.deviceTransportDiagnostics["101"]?.route
        }
        #expect(!routesAfterRetry.contains(.cloud), "late in-flight poll must not flicker 101 to .cloud before queued LAN retry runs")
        #expect(routesAfterRetry.last == .lan)

        // Part B: Put "101" back into `.cooldown`, pause an in-flight refresh that will THROW,
        // queue manual `retryLAN("101")`, and verify the error path still executes the queued retry.
        udpMode.withValue { $0 = .timeout }
        await provider.refreshNow()
        #expect(await collector.wait { $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .cooldown })

        udpMode.withValue { $0 = .healthy }
        let failingPollGate = ProbeConcurrencyGate(expectedParkedProbes: 1)
        await api.setGetPropsHook { _ in
            await failingPollGate.park()
            throw MiCloudError.http(503)
        }
        let failingRefresh = Task { await provider.refreshNow() }
        await failingPollGate.waitUntilAllParked()

        await provider.retryLAN(deviceId: "101")
        await api.setGetPropsHook(nil)
        await failingPollGate.release()
        await failingRefresh.value

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.statuses.last == .connected
        })
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == false)

        await provider.shutdown()
    }

    @Test("retryLAN uses existing LAN bindings when LAN recovers while WAN cloud discovery is still down")
    func retryLANRecoversWhenLANReturnsWhileWANIsDown() async throws {
        enum UDPMode: Sendable {
            case healthy
            case timeout
        }
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let udpMode = LockedBox(UDPMode.healthy)
        let udpTransport = MockUDPTransport { packet, _, _ in
            guard udpMode.withValue({ $0 }) == .healthy else { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket {
                return makeHelloResponse(deviceId: 101, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let reqId = (try JSONDecoder().decode(JSONValue.self, from: plaintext))["id"]?.intValue ?? 0
            let reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":77,"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let lanLight = MiDeviceRecord(
            did: "101",
            name: "Desk Lamp",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: "192.168.1.50",
            mac: "AA:BB:CC:DD:EE:01",
            token: tokenHex,
            isShared: false
        )
        let cloudOnlyLight = MiDeviceRecord(
            did: "202",
            name: "Hallway Lamp",
            model: "yeelink.light.color4",
            isOnline: true,
            localIp: nil,
            token: nil,
            isShared: false
        )
        let api = HybridMockCloudAPI(
            devices: [lanLight, cloudOnlyLight],
            rooms: [MiRoom(id: "r1", name: "Study", dids: ["101", "202"])],
            props: [
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "101", siid: 2, piid: 2): .number(50),
                MiotPropKey(did: "202", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "202", siid: 2, piid: 2): .number(30),
            ]
        )
        let specSource = HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()])
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession },
            apiFactory: { _ in api },
            specSource: specSource,
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1,
            lanCooldownDuration: 30,
            broadcastSweepMinInterval: 60,
            now: { clock.now() },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = EventCollector()
        let task = Task { for await event in provider.events() { await collector.append(event) }; await collector.finish() }
        defer { task.cancel() }

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.snapshots.last?.deviceTransportDiagnostics["202"]?.route == .cloud
        })

        // Both LAN and WAN go down: "101" enters `.cooldown`, `lanSucceededDids` empties, and cloud backs off.
        udpMode.withValue { $0 = .timeout }
        await api.setDiscoveryError(URLError(.notConnectedToInternet))
        await api.setGetPropsError(URLError(.notConnectedToInternet))
        await provider.refreshNow()
        #expect(await collector.wait {
            if case .disconnected = $0.statuses.last { return true }
            return false
        })
        #expect(await provider.lanTransportState(for: "101").isCoolingDown == true)

        // LAN recovers while WAN is STILL completely down. Per-device `retryLAN("101")` must use
        // the existing IP/token binding directly without calling cloud discovery.
        udpMode.withValue { $0 = .healthy }
        let discoveryCallsBefore = await api.deviceListCalls
        await provider.retryLAN(deviceId: "101")

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.statuses.last == .connected
        })
        #expect(await api.deviceListCalls == discoveryCallsBefore)
        let afterDeviceRetry = try #require(await collector.snapshots.last)
        #expect(afterDeviceRetry.devices.first { $0.id == "101" }?.telemetryStale == false)
        #expect(lightBrightness(afterDeviceRetry.devices.first { $0.id == "101" }) == 77)
        #expect(afterDeviceRetry.devices.first { $0.id == "202" }?.telemetryStale == true)

        // Repeat with global `retryLAN(deviceId: nil)` while WAN is still down.
        udpMode.withValue { $0 = .timeout }
        await provider.refreshNow()
        #expect(await collector.wait {
            if case .disconnected = $0.statuses.last { return true }
            return false
        })

        udpMode.withValue { $0 = .healthy }
        let discoveryCallsBeforeAllRetry = await api.deviceListCalls
        await provider.retryLAN(deviceId: nil)

        #expect(await collector.wait {
            $0.snapshots.last?.deviceTransportDiagnostics["101"]?.route == .lan
                && $0.statuses.last == .connected
        })
        #expect(await api.deviceListCalls == discoveryCallsBeforeAllRetry)
        let afterAllRetry = try #require(await collector.snapshots.last)
        #expect(afterAllRetry.devices.first { $0.id == "101" }?.telemetryStale == false)
        #expect(afterAllRetry.devices.first { $0.id == "202" }?.telemetryStale == true)

        await provider.shutdown()
    }

    @Test("Shared miio_protocol_golden.json: packet encode/decode, HELLO verdicts, tokens, RFC1918, firmware JSON")
    func miioProtocolGoldenCorpusMatchesSwiftImplementation() throws {
        struct PacketVector: Decodable {
            let name: String
            let deviceId: UInt32
            let stamp: UInt32
            let unknown: UInt32
            let token: String
            let key: String
            let iv: String
            let payload: String
            let checksum: String
            let packet: String
        }
        struct HelloCase: Decodable {
            let name: String
            let token: String
            let packet: String
            let verdict: String
        }
        struct TokenCase: Decodable {
            let raw: String
            let valid: Bool
        }
        struct PrivateIPCase: Decodable {
            let ip: String
            let valid: Bool
        }
        struct MalformedJSONCase: Decodable {
            let name: String
            let input: String
            let expected: String
        }
        struct GoldenCorpus: Decodable {
            let helloPacket: String
            let packetVectors: [PacketVector]
            let helloChecksumCases: [HelloCase]
            let tokenCases: [TokenCase]
            let privateIpCases: [PrivateIPCase]
            let malformedJsonCases: [MalformedJSONCase]
        }

        func hexEncode(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }
        func hexDecode(_ hex: String) -> Data {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                bytes.append(UInt8(hex[idx..<next], radix: 16)!)
                idx = next
            }
            return Data(bytes)
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/miio_protocol_golden.json")
        let corpus = try JSONDecoder().decode(GoldenCorpus.self, from: Data(contentsOf: fixtureURL))

        #expect(hexEncode(MiIOPacket.helloPacket) == corpus.helloPacket)

        for vector in corpus.packetVectors {
            let token = try #require(MiIOPacket.validateToken(vector.token), "\(vector.name)")
            let (key, iv) = try MiIOCrypto.deriveKeyAndIV(token: token)
            #expect(hexEncode(key) == vector.key, "\(vector.name) key")
            #expect(hexEncode(iv) == vector.iv, "\(vector.name) iv")

            let payloadData = Data(vector.payload.utf8)
            let encoded = try MiIOPacket.encode(
                deviceId: vector.deviceId,
                stamp: vector.stamp,
                token: token,
                payload: payloadData,
                unknown: vector.unknown
            )
            #expect(hexEncode(encoded) == vector.packet, "\(vector.name) encode")

            let (header, decoded) = try MiIOPacket.decode(encoded, token: token)
            #expect(header.deviceId == vector.deviceId, "\(vector.name) deviceId")
            #expect(header.stamp == vector.stamp, "\(vector.name) stamp")
            #expect(header.unknown == vector.unknown, "\(vector.name) unknown")
            #expect(hexEncode(header.checksum) == vector.checksum, "\(vector.name) checksum")
            #expect(decoded == payloadData, "\(vector.name) decode")
        }

        for item in corpus.helloChecksumCases {
            let token = try #require(MiIOPacket.validateToken(item.token), "\(item.name)")
            let packet = hexDecode(item.packet)
            let expected: MiIOPacket.HelloChecksumVerdict
            switch item.verdict {
            case "md5Match": expected = .md5Match
            case "tokenEcho": expected = .tokenEcho
            case "inconclusive": expected = .inconclusive
            case "mismatch": expected = .mismatch
            default: Issue.record("Unknown verdict \(item.verdict)"); continue
            }
            #expect(MiIOPacket.helloChecksumVerdict(packet, token: token) == expected, "\(item.name)")
        }

        for item in corpus.tokenCases {
            #expect((MiIOPacket.validateToken(item.raw) != nil) == item.valid, "\(item.raw)")
        }

        for item in corpus.privateIpCases {
            #expect(LocalMiIOClient.isPrivateRFC1918IPv4(item.ip) == item.valid, "\(item.ip)")
        }

        for item in corpus.malformedJsonCases {
            #expect(cleanMalformedFirmwareJSON(item.input) == item.expected, "\(item.name)")
        }
    }

    @Test("Legacy pre-MIoT Wi-Fi air purifiers (-32601 / -5001 command error) skip broadcast recovery and fall back to cloud for polls, writes, and external power controls (#570)")
    func legacyNonMiotAirPurifiersFallBackToCloudForPollsAndExternalWrites() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let ma2Spec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-ma2:1",
            services: [MiotService(
                iid: 2, type: "urn:miot-spec-v2:service:air-purifier:00007811:zhimi-ma2:1",
                properties: [
                    MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:zhimi-ma2:1", format: "bool", access: ["read", "write", "notify"]),
                    MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:fan-level:00000016:zhimi-ma2:1", format: "uint8", access: ["read", "write", "notify"], valueRange: [1, 3, 1]),
                    MiotProperty(iid: 3, type: "urn:miot-spec-v2:property:mode:00000008:zhimi-ma2:1", format: "uint8", access: ["read", "write", "notify"],
                                 valueList: [MiotValueListItem(value: 0, description: "Auto"), MiotValueListItem(value: 1, description: "Sleep"), MiotValueListItem(value: 2, description: "Favorite")]),
                ]
            )]
        )
        let rejectMiotRpc = LockedBox(true), perPropError = LockedBox(false)
        let udpTransport = MockUDPTransport { packet, host, _ in
            if packet == MiIOPacket.helloPacket {
                let id: UInt32 = host == "192.168.1.70" ? 357_621_783 : host == "192.168.1.71" ? 70_849_337 : 101
                return makeHelloResponse(deviceId: id, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0, method = req["method"]?.stringValue ?? ""
            let reply: String
            if host == "192.168.1.70", rejectMiotRpc.withValue({ $0 }) {
                reply = #"{"id":\#(reqId),"error":{"code":-32601,"message":"Method not found"}}"#
            } else if host == "192.168.1.71", rejectMiotRpc.withValue({ $0 }) {
                reply = #"{"id":\#(reqId),"error":{"code":-5001,"message":"command error"}}"#
            } else if host == "192.168.1.72", method == "set_properties", perPropError.withValue({ $0 }) {
                reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"code":-704002000}]}"#
            } else if method == "get_properties" {
                let did = host == "192.168.1.70" ? "357621783" : host == "192.168.1.71" ? "70849337" : "101"
                reply = #"{"id":\#(reqId),"result":[{"did":"\#(did)","siid":2,"piid":1,"value":true,"code":0},{"did":"\#(did)","siid":2,"piid":2,"value":1,"code":0},{"did":"\#(did)","siid":2,"piid":3,"value":0,"code":0}]}"#
            } else {
                reply = #"{"id":\#(reqId),"result":[{"did":"101","siid":2,"piid":1,"code":0}]}"#
            }
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await udpTransport.setBroadcastHandler { _, _, _ in
            [
                MiIOBroadcastReply(sourceIP: "192.168.1.70", packet: makeHelloResponse(deviceId: 357_621_783, stamp: 10)),
                MiIOBroadcastReply(sourceIP: "192.168.1.71", packet: makeHelloResponse(deviceId: 70_849_337, stamp: 10)),
            ]
        }

        // Broadcast discovery must reject legacy -32601 / -5001 command-error replies instead of wiping LAN health.
        let discoveryClient = LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() })
        let discovered = try await discoveryClient.discoverEndpoints(
            for: [MiIODeviceCandidate(did: "357621783", token: tokenHex), MiIODeviceCandidate(did: "70849337", token: tokenHex)],
            broadcastTimeout: .milliseconds(20)
        )
        #expect(discovered.isEmpty)
        await discoveryClient.shutdown()

        let ma2 = MiDeviceRecord(did: "357621783", name: "空气净化器2", model: "zhimi.airpurifier.ma2", isOnline: true, localIp: "192.168.1.70", token: tokenHex, isShared: false, pid: 0)
        let v6 = MiDeviceRecord(did: "70849337", name: "空气净化器", model: "zhimi.airpurifier.v6", isOnline: true, localIp: "192.168.1.71", token: tokenHex, isShared: false, pid: 0)
        let modernLight = MiDeviceRecord(did: "101", name: "Modern Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.72", token: tokenHex, isShared: false, pid: 0)
        let api = HybridMockCloudAPI(
            devices: [ma2, v6, modernLight],
            rooms: [MiRoom(id: "r1", name: "Living", dids: ["357621783", "70849337", "101"])],
            props: [
                MiotPropKey(did: "357621783", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "357621783", siid: 2, piid: 2): .number(1), MiotPropKey(did: "357621783", siid: 2, piid: 3): .number(0),
                MiotPropKey(did: "70849337", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "70849337", siid: 2, piid: 2): .number(1), MiotPropKey(did: "70849337", siid: 2, piid: 3): .number(0),
                MiotPropKey(did: "101", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "101", siid: 2, piid: 2): .number(50),
            ]
        )
        let provider = MiCloudProvider(
            sessionLoader: { self.stubSession }, apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: ["zhimi.airpurifier.ma2": ma2Spec, "zhimi.airpurifier.v6": ma2Spec, "yeelink.light.color4": lightSpec()]),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }),
            lanFailureThreshold: 1, lanCooldownDuration: 30, now: { clock.now() },
            pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), selectedHomeLoader: { nil }
        )
        let suiteName = "test.legacy.miot.fallback.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = await MainActor.run { HomeStore(provider: provider, defaultsSuiteName: suiteName) }
        try await store.waitForTestSnapshot()

        // Both legacy air purifiers report `.cloud` (not `.cooldown`) without triggering a broadcast sweep.
        #expect(await MainActor.run { store.deviceTransportDiagnostics["357621783"]?.route } == .cloud)
        #expect(await MainActor.run { store.deviceTransportDiagnostics["70849337"]?.route } == .cloud)
        #expect(await provider.lanTransportState(for: "357621783").isCoolingDown == false)
        #expect(await provider.lanTransportState(for: "70849337").isCoolingDown == false)
        #expect(await udpTransport.broadcastCalls == 1)

        // External Raycast/URL power off + preset mode commands succeed via Xiaomi Cloud with 0 extra LAN packets.
        let udpSendsBeforeCommands = await udpTransport.sends.count
        let powerResult = await store.executeRaycastPower(deviceId: "357621783", isOn: false)
        #expect(powerResult.handled == true && powerResult.isError == false)
        try await provider.execute(.setFanPresetMode(entityId: "miot:70849337:2", presetMode: "Sleep"))
        #expect(await udpTransport.sends.count == udpSendsBeforeCommands)
        let cloudWrites = await api.setPropsCalls
        #expect(cloudWrites.contains([MiotPropWrite(did: "357621783", siid: 2, piid: 1, value: .bool(false))]))
        #expect(cloudWrites.contains([MiotPropWrite(did: "70849337", siid: 2, piid: 3, value: .number(1))]))

        // Genuine MIoT per-property rejection still throws deviceError without cloud replay.
        perPropError.withValue { $0 = true }
        let cloudWritesBeforePerPropError = await api.setPropsCalls.count
        await #expect(throws: MiCloudError.self) {
            try await provider.execute(.setLightPower(entityId: "miot:101:2", isOn: false))
        }
        #expect(await api.setPropsCalls.count == cloudWritesBeforePerPropError)

        // Direct cold write hitting -32601 BEFORE a failed poll also falls back immediately to cloud.
        rejectMiotRpc.withValue { $0 = false }
        await provider.retryLAN(deviceId: "357621783")
        #expect(await provider.lanTransportState(for: "357621783").transportSucceeded == true)
        rejectMiotRpc.withValue { $0 = true }
        let cloudWritesBeforeColdWrite = await api.setPropsCalls.count
        try await provider.execute(.setFanPower(entityId: "miot:357621783:2", isOn: true))
        #expect(await api.setPropsCalls.count == cloudWritesBeforeColdWrite + 1)
        let sendsAfterColdWrite = await udpTransport.sends.count
        try await provider.execute(.setFanPower(entityId: "miot:357621783:2", isOn: false))
        #expect(await udpTransport.sends.count == sendsAfterColdWrite)

        await store.shutdown()
    }
}

func lightBrightness(_ device: SmartDevice?) -> Int? {
    guard case .light(let spec) = device?.kind else { return nil }
    return spec.brightnessPercent
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
