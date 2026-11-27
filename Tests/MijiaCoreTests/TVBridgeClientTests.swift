import XCTest
@testable import MijiaCore

final class TVBridgeClientTests: XCTestCase {
    func testDisabledByDefaultRejectsStartAndWrites() async {
        let manager = TVBridgePluginManager(config: TVBridgeConfig())
        do { try await manager.startIfNeeded(); XCTFail("disabled bridge started") } catch TVBridgeError.disabled {} catch { XCTFail("unexpected error \(error)") }
    }
    func testProjectsNamespacedTV() async throws {
        let descriptor = TVBridgeDeviceDescriptor(nativeId: "tv-1", name: "客厅电视", kind: "kodi", online: true, state: "playing", volume: 30, muted: false, source: "HDMI")
        let payload = try JSONEncoder().encode([descriptor])
        let transport = MockTVBridgeTransport { frame in
            if frame.method == "initialize" { return TVBridgeFrame(id: frame.id, result: Data("{\"manifestDigest\":null}".utf8)) }
            return TVBridgeFrame(id: frame.id, result: Data("{\"capturedAt\":\"now\",\"devices\":".utf8) + payload + Data("}".utf8))
        }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        let devices = try await manager.snapshot()
        XCTAssertEqual(devices.first?.id, "adapter:com.menubarhome.tv-bridge:tv-1")
        if case .tv(let spec) = devices.first?.kind { XCTAssertEqual(spec.state, "playing") } else { XCTFail("not tv") }
    }
    func testConfigDoesNotPersistCredential() throws {
        let defaults = UserDefaults(suiteName: "tv-bridge-test")!
        defaults.removePersistentDomain(forName: "tv-bridge-test")
        let config = TVBridgeConfig(isEnabled: true, devices: [.init(nativeId: "x", driver: .kodi_jsonrpc, host: "127.0.0.1", name: "TV", roomName: "Room", credentialSlot: "slot")])
        try config.save(to: defaults)
        let raw = defaults.data(forKey: TVBridgeConfig.userDefaultsKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(raw.contains("psk")); XCTAssertFalse(raw.contains("clientKey")); XCTAssertTrue(raw.contains("credentialSlot"))
    }
}

extension TVBridgeClientTests {
    func testInitializeSerializesConfiguredDeviceAndCredential() async throws {
        let transport = MockTVBridgeTransport { frame in
            XCTAssertEqual(frame.method, "initialize")
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame.params!) as? [String: Any])
            XCTAssertEqual(object["capabilityGeneration"] as? Int, 1)
            let config = try XCTUnwrap(object["config"] as? [String: Any])
            let devices = try XCTUnwrap(config["devices"] as? [[String: Any]])
            XCTAssertEqual(devices.first?["driver"] as? String, "kodi_jsonrpc")
            XCTAssertEqual(devices.first?["credential"] as? String, "secret-in-memory")
            return TVBridgeFrame(id: frame.id, result: Data("{}".utf8))
        }
        let device = TVBridgeDeviceConfig(nativeId: "n", driver: .kodi_jsonrpc, host: "127.0.0.1", port: 8080, name: "TV", roomName: "Room", macAddress: "aa", credentialSlot: "slot")
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true, devices: [device]), transport: transport, credentialResolver: { _ in "secret-in-memory" })
        try await manager.startIfNeeded()
    }

    func testStructuredRPCErrorIsThrown() async {
        let transport = MockTVBridgeTransport { frame in TVBridgeFrame(id: frame.id, error: TVBridgeRPCError(code: -32004, message: "offline")) }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        do { try await manager.healthPing(); XCTFail("expected RPC error") } catch TVBridgeError.rpcError(let code, let message) { XCTAssertEqual(code, -32004); XCTAssertEqual(message, "offline") } catch { XCTFail("unexpected error \(error)") }
    }
}

extension TVBridgeClientTests {
    func testInvalidJSONRPCVersionIsRejected() throws {
        XCTAssertThrowsError(try TVBridgeFrame.decodeForTesting(Data("{\"jsonrpc\":\"1.0\",\"id\":\"x\"}".utf8)))
    }
}

extension TVBridgeClientTests {
    func testRPCErrorPreservesRunningTransport() async throws {
        let transport = MockTVBridgeTransport { frame in
            if frame.method == "initialize" { return TVBridgeFrame(id: frame.id, result: Data("{}".utf8)) }
            return TVBridgeFrame(id: frame.id, error: TVBridgeRPCError(code: -32005, message: "device unavailable"))
        }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        try await manager.startIfNeeded()
        do { try await manager.healthPing(); XCTFail("expected rpc error") } catch TVBridgeError.rpcError { } catch { XCTFail("unexpected error") }
        let closeCount = await transport.closeCount; let running = await manager.isRunning; XCTAssertEqual(closeCount, 0); XCTAssertTrue(running)
    }
}

extension TVBridgeClientTests {
    func testMismatchedResponseIdTearsDownTransport() async throws {
        let transport = MockTVBridgeTransport { frame in
            if frame.method == "initialize" { return TVBridgeFrame(id: frame.id, result: Data("{}".utf8)) }
            return TVBridgeFrame(id: "someone-else", result: Data("{}".utf8))
        }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        try await manager.startIfNeeded()
        do { try await manager.healthPing(); XCTFail("expected invalid frame") } catch TVBridgeError.invalidFrame { } catch { XCTFail("unexpected error \(error)") }
        let closeCount = await transport.closeCount
        let running = await manager.isRunning
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(running)
    }

    func testTransportFailureTearsDownTransport() async throws {
        struct Broken: Error {}
        let transport = MockTVBridgeTransport { frame in
            if frame.method == "initialize" { return TVBridgeFrame(id: frame.id, result: Data("{}".utf8)) }
            throw Broken()
        }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        try await manager.startIfNeeded()
        do { try await manager.healthPing(); XCTFail("expected transport error") } catch is Broken { } catch { XCTFail("unexpected error \(error)") }
        let closeCount = await transport.closeCount
        let running = await manager.isRunning
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(running)
    }

    func testLegacyDriverAliasesDecodeToCanonicalCatalogIDs() throws {
        let json = Data("""
        {"isEnabled":true,"idleShutdownSeconds":900,"devices":[
          {"nativeId":"a","driver":"lg_webos","host":"192.168.1.2","name":"LG","roomName":""},
          {"nativeId":"b","driver":"xiaomi_6095","host":"192.168.1.3","name":"Mi","roomName":""},
          {"nativeId":"c","driver":"hisense_vidaa_mqtt","host":"192.168.1.4","name":"Hisense","roomName":""}
        ]}
        """.utf8)
        let decoded = try JSONDecoder().decode(TVBridgeConfig.self, from: json)
        XCTAssertEqual(decoded.devices.map(\.driver), [.lg_webos_ssap, .xiaomi_mitv_6095, .hisense_vidaa_mqtt])
        XCTAssertEqual(TVBridgeDeviceConfig.Driver.primaryCases, [.lg_webos_ssap, .xiaomi_mitv_6095, .hisense_vidaa_mqtt])
    }

    func testExecuteEmitsCanonicalADR0026VerbsAndArgs() async throws {
        let transport = MockTVBridgeTransport { frame in
            TVBridgeFrame(id: frame.id, result: Data("{}".utf8))
        }
        let manager = TVBridgePluginManager(config: TVBridgeConfig(isEnabled: true), transport: transport)
        try await manager.execute(deviceId: "adapter:com.menubarhome.tv-bridge:tv-1", command: .power(false), capabilityGeneration: 2)
        try await manager.execute(deviceId: "adapter:com.menubarhome.tv-bridge:tv-1", command: .setVolume(0.35), capabilityGeneration: 2)
        try await manager.execute(deviceId: "adapter:com.menubarhome.tv-bridge:tv-1", command: .setMute(true), capabilityGeneration: 2)
        try await manager.execute(deviceId: "adapter:com.menubarhome.tv-bridge:tv-1", command: .selectSource("HDMI1"), capabilityGeneration: 2)
        try await manager.execute(deviceId: "adapter:com.menubarhome.tv-bridge:tv-1", command: .seek(42), capabilityGeneration: 2)
        let requests = await transport.requests.filter { $0.method == "control.execute" }
        let pairs = try requests.map { frame -> (String, [String: Any]) in
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame.params!) as? [String: Any])
            return (try XCTUnwrap(obj["verb"] as? String), try XCTUnwrap(obj["args"] as? [String: Any]))
        }
        XCTAssertEqual(pairs.map(\.0), ["power.set", "volume.set", "mute.set", "input.select", "media.seek"])
        XCTAssertEqual(pairs[1].1["level"] as? Int, 35)
        XCTAssertEqual(pairs[2].1["isMuted"] as? Bool, true)
        XCTAssertEqual(pairs[4].1["positionSec"] as? Double, 42)
    }
}
