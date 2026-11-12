import CryptoKit
import Foundation
import Testing
@testable import MijiaCore

// MARK: - Local Test Doubles (RFC 5737 TEST-NET-1: 192.0.2.0/24 only)

private actor MockUDPTransport: MiIOUDPTransport {
    struct RecordedSend: Sendable {
        let packet: Data
        let host: String
        let port: UInt16
    }

    private var handler: @Sendable (Data, String, UInt16) async throws -> Data
    private(set) var sends: [RecordedSend] = []
    private(set) var shutdownCount = 0

    init(handler: @escaping @Sendable (Data, String, UInt16) async throws -> Data) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping @Sendable (Data, String, UInt16) async throws -> Data) {
        self.handler = handler
    }

    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        sends.append(RecordedSend(packet: packet, host: host, port: port))
        return try await handler(packet, host, port)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor HybridMockCloudAPI: MiCloudAPI {
    var devicesList: [MiDeviceRecord]
    var roomsList: [MiRoom]
    var propsByKey: [MiotPropKey: JSONValue]
    var doorbellLatest: [String: Date] = [:]

    private(set) var getPropsCalls: [[MiotPropKey]] = []
    private(set) var setPropsCalls: [[MiotPropWrite]] = []
    private(set) var actionCalls: [MiotActionCall] = []
    private(set) var doorbellQueries: [(did: String, eventKey: String, since: Date, now: Date)] = []
    private(set) var shutdownCount = 0

    init(
        devices: [MiDeviceRecord],
        rooms: [MiRoom],
        props: [MiotPropKey: JSONValue] = [:]
    ) {
        self.devicesList = devices
        self.roomsList = rooms
        self.propsByKey = props
    }

    func setDoorbellLatest(did: String, eventKey: String, date: Date?) {
        let key = "\(did)#\(eventKey)"
        doorbellLatest[key] = date
    }

    func setCloudProp(_ key: MiotPropKey, value: JSONValue) {
        propsByKey[key] = value
    }

    func deviceList() async throws -> [MiDeviceRecord] { devicesList }
    func homeRooms() async throws -> [MiRoom] { roomsList }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        getPropsCalls.append(keys)
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

private struct HybridMockSpecSource: MiotSpecSource {
    let specs: [String: MiotDeviceSpec]
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        specs[model]
    }
}

private final class MutableClock: @unchecked Sendable {
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

private actor EventCollector {
    var snapshots: [SynthesizedHome] = []
    var doorbellRings: [DoorbellRing] = []

    func append(_ event: HomeProviderEvent) {
        switch event {
        case .snapshotUpdated(let home):
            snapshots.append(home)
        case .doorbellRang(let ring):
            doorbellRings.append(ring)
        case .statusChanged, .sessionExpired, .sourceStatusesChanged:
            break
        }
    }

    func wait(timeoutSeconds: Double = 3.0, until predicate: @Sendable (EventCollector) async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if await predicate(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate(self)
    }
}

private actor MirrorHTTPStub: MiHTTPTransport {
    private var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private(set) var requestedURLs: [String] = []
    private(set) var maxConcurrent = 0
    private var currentConcurrent = 0

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestedURLs.append(request.url?.absoluteString ?? "")
        currentConcurrent += 1
        if currentConcurrent > maxConcurrent {
            maxConcurrent = currentConcurrent
        }
        defer { currentConcurrent -= 1 }
        return try await handler(request)
    }
}

private func makeHelloResponse(deviceId: UInt32, stamp: UInt32) -> Data {
    var packet = Data([0x21, 0x31, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00])
    var didBE = deviceId.bigEndian
    var stampBE = stamp.bigEndian
    packet.append(Data(bytes: &didBE, count: 4))
    packet.append(Data(bytes: &stampBE, count: 4))
    packet.append(Data(repeating: 0xFF, count: 16))
    return packet
}

private func lightSpec() -> MiotDeviceSpec {
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

@Suite("LocalMiIOClient UDP Protocol")
struct LocalMiIOClientTests {
    private let validTokenHex = "00112233445566778899aabbccddeeff"
    private let testEndpoint = MiIODeviceEndpoint(did: "12345678", ip: "192.0.2.10", token: "00112233445566778899aabbccddeeff")

    @Test("Handshake tracks stamp skew + monotonic increments, encodes integer JSON values, and chunks >12 props")
    func handshakePropsChunkingAndCompactJSON() async throws {
        let tokenData = try #require(MiIOPacket.validateToken(validTokenHex))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let capturedPackets = LockedBox<[Data]>([])
        let capturedRequests = LockedBox<[String]>([])

        let transport = MockUDPTransport { packet, host, port in
            #expect(host == "192.0.2.10")
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
                endpoint: MiIODeviceEndpoint(did: "12345678", ip: "192.0.2.10", token: "00000000000000000000000000000000")
            )
        }

        let result = try await client.getProps([MiotPropKey(did: "12345678", siid: 2, piid: 1)], endpoint: testEndpoint)
        #expect(result[MiotPropKey(did: "12345678", siid: 2, piid: 1)] == .bool(true))
        // 1st HELLO + failed attempt 1 + 2nd HELLO (reset on retry) + retry success = 4 sends.
        #expect(await transport.sends.count == 4)
        await client.shutdown()
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
            {"did":"100","name":"Own Bulb","model":"yeelink.light.color4","isOnline":true,"localip":"192.0.2.20","token":"00112233445566778899aabbccddeeff","share_flag":0},
            {"did":"200","name":"Shared Lamp","model":"yeelink.light.color4","isOnline":true,"localip":"192.0.2.21","token":"ffeeddccbbaa99887766554433221100","share_flag":1},
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

    @Test("MiotSpecStore falls back to secondary mirror, applies TTL jitter, and prefetches concurrently")
    func specStoreMirrorFallbackJitterAndPrefetch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = MirrorHTTPStub { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://miot-spec.org") {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            if url.contains("/instances?status=released") {
                let body = Data(#"""
                {"instances":[
                    {"model":"acme.bulb.v1","type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:1","status":"released"},
                    {"model":"acme.bulb.v2","type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:2","status":"released"},
                    {"model":"acme.bulb.v3","type":"urn:miot-spec-v2:device:light:0000A001:acme-bulb:3","status":"released"}
                ]}
                """#.utf8)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
            try? await Task.sleep(for: .milliseconds(30))
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

        let prefetched = await store.getSpecs(for: ["acme.bulb.v1", "acme.bulb.v2", "acme.bulb.v3", "acme.bulb.v1"], maxConcurrency: 2)
        #expect(prefetched.count == 3)
        #expect(await transport.maxConcurrent <= 2)
        let urls = await transport.requestedURLs
        #expect(urls.contains { $0.hasPrefix("https://spec.miot-spec.com/") })
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

        let ownWifi = MiDeviceRecord(did: "101", name: "Own Wifi Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.0.2.10", token: tokenHex, isShared: false)
        let sharedWifi = MiDeviceRecord(did: "202", name: "Shared Wifi Light", model: "yeelink.light.color4", isOnline: true, localIp: "192.0.2.11", token: tokenHex, isShared: true)
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
        }
        defer { task.cancel() }

        let initialReady = await collector.wait { await !$0.snapshots.isEmpty }
        #expect(initialReady)

        // Own Wi-Fi device received LAN values (brightness 75, on true); shared/BLE came from cloud.
        let snap1 = await collector.snapshots.last
        let ownDev1 = snap1?.devices.first { $0.id == "101" }
        #expect(lightBrightness(ownDev1) == 75)
        // Shared IP 192.0.2.11 must NEVER be contacted over LAN.
        #expect(lanHostCalls.withValue { !$0.contains("192.0.2.11") })
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
            await lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 33
        }
        #expect(gotCooldownSnapshot)

        // Advance past 60s cooldown and restore LAN -> recovers to LAN direct (75).
        clock.advance(by: 61)
        lanModeShouldFail.withValue { $0 = false }
        await provider.refreshNow()
        let gotRecoveredSnapshot = await collector.wait {
            await lightBrightness($0.snapshots.last?.devices.first { $0.id == "101" }) == 75
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
        }
        defer { task.cancel() }

        let launched = await collector.wait { await !$0.snapshots.isEmpty }
        #expect(launched)
        #expect(await collector.doorbellRings.isEmpty)

        // Newer doorbell ring arrives -> bridged out through MiAccountsProvider.
        let ringDate = Date(timeIntervalSince1970: 1_700_000_050)
        await api.setDoorbellLatest(did: "db-1", eventKey: "2.1", date: ringDate)
        await accountsProvider.refreshNow()

        let gotRing = await collector.wait { await $0.doorbellRings.count == 1 }
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
}

private func lightBrightness(_ device: SmartDevice?) -> Int? {
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
