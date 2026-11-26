import XCTest
@testable import MijiaCore

final class TVBridgeClientTests: XCTestCase {
    func testDisabledByDefaultRejectsStartAndWrites() async {
        let manager = TVBridgePluginManager(config: TVBridgeConfig())
        do { try await manager.startIfNeeded(); XCTFail("disabled bridge started") } catch TVBridgeError.disabled {} catch { XCTFail("unexpected error \(error)") }
    }
    func testProjectsNamespacedTV() async throws {
        let descriptor = TVBridgeDeviceDescriptor(nativeId: "tv-1", model: "kodi", name: "客厅电视", roomName: "客厅", isOnline: true, playback: .init(state: "playing", volumePercent: 30, currentSource: "HDMI"))
        let payload = try JSONEncoder().encode([descriptor])
        let transport = MockTVBridgeTransport { frame in
            if frame.method == "initialize" { return TVBridgeFrame(id: frame.id, result: Data("{\"manifestDigest\":null}".utf8)) }
            return TVBridgeFrame(id: frame.id, result: payload)
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
