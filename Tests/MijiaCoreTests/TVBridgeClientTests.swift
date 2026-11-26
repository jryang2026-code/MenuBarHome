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
