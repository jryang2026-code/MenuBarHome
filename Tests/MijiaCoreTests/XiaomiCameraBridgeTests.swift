import Foundation
import Testing
@testable import MijiaCore

@Suite("XiaomiCameraBridge Lifecycle")
struct XiaomiCameraBridgeTests {
    private static func makeSampleOwnerRecord(pid: Int32, binaryPath: String = "/usr/local/bin/go2rtc") -> Go2RTCOwnerRecord {
        Go2RTCOwnerRecord(
            pid: pid,
            session: Go2RTCSession(
                apiListen: "127.0.0.1:43123",
                rtspListen: "127.0.0.1:43124",
                username: "muser0001",
                password: "mpass0001",
                nonce: "mnonce0001"
            ),
            binaryPath: binaryPath,
            binarySize: 1024,
            binaryModifiedAt: 1_700_000_000
        )
    }

    @Test("Startup stale config scrub strips persisted streams when no live owner PID exists")
    func startupStaleConfigScrub() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cfgURL = dir.appendingPathComponent("go2rtc.yaml")
        let ownerURL = dir.appendingPathComponent("go2rtc.owner")
        let rawConfig = """
        api:
          listen: 127.0.0.1:43123
          local_auth: true
        menubarmijia:
          nonce: "mnonce0001"
        streams:
          cam_raw_123: xiaomi://127.0.0.1:51234?sign=secret_token&client_private=priv_key
        """
        try XiaomiCameraBridge.writeSecretFile(rawConfig, to: cfgURL)

        let deadRecord = Self.makeSampleOwnerRecord(pid: 999_999)
        try XiaomiCameraBridge.writeSecretFile(deadRecord.serialized(), to: ownerURL)

        #expect(XiaomiCameraBridge.scrubStaleConfigInDirectory(dir) == true)
        let cleaned = try String(contentsOf: cfgURL, encoding: .utf8)
        #expect(!cleaned.contains("streams:"))
        #expect(!cleaned.contains("secret_token"))
        #expect(cleaned.contains("local_auth: true"))

        try XiaomiCameraBridge.writeSecretFile(rawConfig, to: cfgURL)
        let recycledRecord = Self.makeSampleOwnerRecord(pid: getpid(), binaryPath: "/nonexistent/go2rtc")
        try XiaomiCameraBridge.writeSecretFile(recycledRecord.serialized(), to: ownerURL)
        #expect(XiaomiCameraBridge.scrubStaleConfigInDirectory(dir) == true)

        try XiaomiCameraBridge.writeSecretFile(rawConfig, to: cfgURL)
        let selfExe = try #require(XiaomiCameraBridge.executablePath(for: getpid()))
        let liveRecord = Self.makeSampleOwnerRecord(pid: getpid(), binaryPath: selfExe)
        try XiaomiCameraBridge.writeSecretFile(liveRecord.serialized(), to: ownerURL)
        #expect(XiaomiCameraBridge.scrubStaleConfigInDirectory(dir) == false)
        let preserved = try String(contentsOf: cfgURL, encoding: .utf8)
        #expect(preserved.contains("streams:"))
    }

    @Test("Stale relay generation cannot tear down a newer generation's relay")
    func relayGenerationGuardsTeardown() async throws {
        let bridge = XiaomiCameraBridge()
        let first = try await bridge.beginSharedRelayWithGeneration(relayKey: "cam_1") { 41001 }
        let second = try await bridge.beginSharedRelayWithGeneration(relayKey: "cam_1") { 41002 }
        #expect(first.generation != second.generation)
        #expect(await bridge.relayPort(for: "cam_1") == 41002)

        await bridge.endSharedRelay(relayKey: "cam_1", generation: first.generation)
        #expect(await bridge.relayPort(for: "cam_1") == 41002)

        await bridge.endSharedRelay(relayKey: "cam_1", generation: second.generation)
        #expect(await bridge.relayPort(for: "cam_1") == nil)
    }

    @Test("Concurrent startBridge and stopBridge calls serialize per streamKey and cancelled startBridge does not clobber newer relay")
    func startAndStopBridgeSerializePerStreamKey() async throws {
        let bridge = XiaomiCameraBridge()
        let owner = Self.makeSampleOwnerRecord(pid: getpid())
        let (firstEnteredStream, firstEnteredCont) = AsyncStream<Void>.makeStream()
        let (releaseFirstStream, releaseFirstCont) = AsyncStream<Void>.makeStream()

        actor CallRecorder {
            var events: [String] = []
            var firstCall = true
            func record(_ event: String) { events.append(event) }
            func takeFirstCall() -> Bool {
                defer { firstCall = false }
                return firstCall
            }
            func allEvents() -> [String] { events }
        }
        let recorder = CallRecorder()

        await bridge.setEnsureRunningOverride({})
        await bridge.setTestBridgeHooks(activeOwner: owner, relayPortOverride: { 41999 }) { name, _ in
            await recorder.record("put:\(name)")
            if name.hasPrefix("cam_raw_"), await recorder.takeFirstCall() {
                firstEnteredCont.yield()
                firstEnteredCont.finish()
                for await _ in releaseFirstStream { break }
            }
        }

        let firstTask = Task {
            try await bridge.startBridge(
                did: "cam_race",
                model: "isa.camera.hlc7",
                localIP: "127.0.0.1",
                clientPublic: "aa",
                clientPrivate: "bb",
                devicePublic: "cc",
                sign: "dd",
                vendor: "cs2",
                uid: nil,
                quality: .hd,
                channel: 0,
                subdid: nil
            )
        }

        for await _ in firstEnteredStream { break }

        let secondTask = Task {
            try await bridge.startBridge(
                did: "cam_race",
                model: "isa.camera.hlc7",
                localIP: "127.0.0.1",
                clientPublic: "aa",
                clientPrivate: "bb",
                devicePublic: "cc",
                sign: "dd",
                vendor: "cs2",
                uid: nil,
                quality: .hd,
                channel: 0,
                subdid: nil
            )
        }

        firstTask.cancel()
        releaseFirstCont.yield()
        releaseFirstCont.finish()

        let firstResult = await firstTask.result
        #expect(throws: (any Error).self) {
            _ = try firstResult.get()
        }

        let secondEndpoints = try await secondTask.value
        #expect(secondEndpoints.mp4.absoluteString.contains("cam_raw_cam_race"))
        #expect(await bridge.relayPort(for: "cam_race") != nil)

        await bridge.stopBridge(did: "cam_race", subdid: nil)
        #expect(await bridge.relayPort(for: "cam_race") == nil)
    }

    @Test("decideGo2RTCAction restarts an alive owned PID when API stalls and escalates SIGTERM to SIGKILL")
    func stalledOwnedProcessRestartsAndEscalatesToSIGKILL() async throws {
        #expect(XiaomiCameraBridge.decideGo2RTCAction(Go2RTCOwnershipProbe(
            pidAlive: true,
            authenticated: false,
            nonceMatches: false,
            configChanged: false,
            processVerified: true
        )) == .restartOwned)
        #expect(XiaomiCameraBridge.decideGo2RTCAction(Go2RTCOwnershipProbe(
            pidAlive: true,
            authenticated: false,
            nonceMatches: false,
            configChanged: false,
            processVerified: false
        )) == .spawnFresh)
        #expect(XiaomiCameraBridge.decideGo2RTCAction(Go2RTCOwnershipProbe(
            pidAlive: true,
            authenticated: true,
            nonceMatches: false,
            configChanged: false,
            processVerified: true
        )) == .spawnFresh)

        let selfExe = try #require(XiaomiCameraBridge.executablePath(for: getpid()))
        #expect(XiaomiCameraBridge.processMatchesBinary(pid: getpid(), expectedBinaryPath: selfExe))
        #expect(!XiaomiCameraBridge.processMatchesBinary(pid: getpid(), expectedBinaryPath: "/nonexistent/go2rtc"))

        let readyFile = FileManager.default.temporaryDirectory.appendingPathComponent("trap-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyFile) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "trap '' TERM; : > \"$1\"; while true; do sleep 1; done", "sh", readyFile.path]
        try proc.run()
        let pid = proc.processIdentifier
        defer {
            if proc.isRunning {
                XiaomiCameraBridge.terminateProcess(pid, force: true)
            }
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: readyFile.path), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path))
        #expect(XiaomiCameraBridge.processIsAlive(pid))

        await XiaomiCameraBridge.terminateOwnedPID(pid, pollInterval: .milliseconds(15), maxPolls: 4)
        proc.waitUntilExit()
        #expect(!XiaomiCameraBridge.processIsAlive(pid))
    }
}
