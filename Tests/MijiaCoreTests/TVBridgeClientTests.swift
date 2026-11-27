#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    func testTerminateAllEscalatesFromSigtermToSigkillWhenChildIgnoresSigterm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tv-bridge-sigkill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("stubborn-bridge.sh")
        try Data("#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' \"$$\" > \"$MBH_DATA_DIR/pid.tmp\"\nmv \"$MBH_DATA_DIR/pid.tmp\" \"$MBH_DATA_DIR/pid\"\nwhile true; do sleep 0.2; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let transport = try StdioTVBridgeTransport.launch(binaryPath: script.path, dataDir: dir, manifestPath: dir.appendingPathComponent("adapter-manifest.json"))
        defer {
            let childPID = transport.childProcess.processIdentifier
            if childPID > 1, transport.childProcess.isRunning {
                _ = kill(childPID, SIGKILL)
                transport.childProcess.waitUntilExit()
            }
        }
        let pidFile = dir.appendingPathComponent("pid")
        let waitDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < waitDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "stubborn child did not finish installing SIGTERM trap")
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(pid, transport.childProcess.processIdentifier)
        XCTAssertEqual(kill(pid, 0), 0)
        StdioTVBridgeTransport.terminateAllImmediately(gracePeriod: 0.05)
        XCTAssertFalse(transport.childProcess.isRunning, "child must be reaped before terminateAllImmediately returns")
        XCTAssertEqual(transport.childProcess.terminationReason, .uncaughtSignal)
        XCTAssertEqual(transport.childProcess.terminationStatus, SIGKILL)
        XCTAssertNotEqual(kill(pid, 0), 0, "SIGTERM-ignoring child must be escalated to SIGKILL and reaped")
    }

    func testCloseEscalatesToSigkillAfterExecReplacesChildImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tv-bridge-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("exec-wrapper.sh")
        let body = """
        #!/bin/sh
        while [ ! -f "$MBH_DATA_DIR/go" ]; do sleep 0.01; done
        if [ -x /bin/zsh ]; then NEXT=/bin/zsh; else NEXT=/bin/bash; fi
        exec "$NEXT" -c 'trap "" TERM; printf "%s\\n" "$$" > "$1.tmp" && mv "$1.tmp" "$1"; while true; do sleep 0.2; done' bridge "$MBH_DATA_DIR/pid"
        """
        try Data((body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let transport = try StdioTVBridgeTransport.launch(binaryPath: script.path, dataDir: dir, manifestPath: dir.appendingPathComponent("adapter-manifest.json"))
        defer {
            let childPID = transport.childProcess.processIdentifier
            if childPID > 1, transport.childProcess.isRunning {
                _ = kill(childPID, SIGKILL)
                transport.childProcess.waitUntilExit()
            }
        }
        try Data().write(to: dir.appendingPathComponent("go"))
        let pidFile = dir.appendingPathComponent("pid")
        let waitDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "exec-replaced child did not finish installing SIGTERM trap")
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(pid, transport.childProcess.processIdentifier)
        XCTAssertEqual(kill(pid, 0), 0)
        await transport.close()
        XCTAssertFalse(transport.childProcess.isRunning, "exec-replaced child must be reaped before close returns")
        XCTAssertEqual(transport.childProcess.terminationReason, .uncaughtSignal)
        XCTAssertEqual(transport.childProcess.terminationStatus, SIGKILL)
        XCTAssertNotEqual(kill(pid, 0), 0, "exec-replaced SIGTERM-ignoring child must be escalated to SIGKILL and reaped")
    }
}
