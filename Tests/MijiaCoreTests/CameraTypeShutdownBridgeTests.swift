import Foundation
import Testing
@testable import MijiaCore

/// P3c-CM on the bridge: closing the camera type stops relays and the helper in order, a start
/// caught mid-way gets nothing back, and a reopen builds exactly one set of handles.
@Suite("Camera type shutdown bridge", .serialized, .timeLimit(.minutes(1)))
struct CameraTypeShutdownBridgeTests {
    private actor Recorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    }

    /// One-shot gate: `wait` parks until `open` is called; `entered` resumes once something parked.
    private final class Gate: Sendable {
        let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        private let released: AsyncStream<Void>
        private let releasedContinuation: AsyncStream<Void>.Continuation

        init() {
            (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            (released, releasedContinuation) = AsyncStream<Void>.makeStream()
        }

        func wait() async {
            enteredContinuation.yield()
            enteredContinuation.finish()
            for await _ in released { break }
        }

        func waitUntilEntered() async {
            for await _ in entered { break }
        }

        func open() {
            releasedContinuation.yield()
            releasedContinuation.finish()
        }
    }

    private static func owner() -> Go2RTCOwnerRecord {
        Go2RTCOwnerRecord(
            pid: getpid(),
            session: Go2RTCSession(
                apiListen: "127.0.0.1:43123",
                rtspListen: "127.0.0.1:43124",
                username: "muser0001",
                password: "mpass0001",
                nonce: "mnonce0001"
            ),
            binaryPath: "/nonexistent/go2rtc",
            binarySize: 1024,
            binaryModifiedAt: 1_700_000_000
        )
    }

    private static func start(_ bridge: XiaomiCameraBridge, did: String = "cam_type") async throws -> XiaomiCameraStreamEndpoints {
        try await bridge.startBridge(
            did: did, model: "isa.camera.hlc7", localIP: "127.0.0.1",
            clientPublic: "aa", clientPrivate: "bb", devicePublic: "cc", sign: "dd",
            vendor: "cs2", uid: nil, quality: .hd, channel: 0, subdid: nil
        )
    }

    @Test("A start caught by the shutdown keeps no relay, and the reopen builds exactly one")
    func shutdownDropsTheInFlightStartAndReopenBuildsOneSet() async throws {
        let bridge = XiaomiCameraBridge()
        let recorder = Recorder()
        let parked = Gate()
        await bridge.setEnsureRunningOverride({ await recorder.record("ensure") })
        await bridge.setProcessShutdownOverride({ await recorder.record("kill") })
        await bridge.setTestBridgeHooks(activeOwner: Self.owner(), relayPortOverride: { 41_901 }) { name, _ in
            await recorder.record("put:\(name)")
            if name.hasPrefix("cam_raw_"), await recorder.count("put:\(name)") == 1 { await parked.wait() }
        }

        let first = Task { try await Self.start(bridge) }
        await parked.waitUntilEntered()
        #expect(await bridge.activeRelayCount == 1)

        await bridge.shutdown()
        #expect(await bridge.activeRelayCount == 0)
        #expect(await bridge.relayPort(for: "cam_type") == nil)

        parked.open()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await bridge.activeRelayCount == 0)
        #expect(await bridge.relayPort(for: "cam_type") == nil)

        await bridge.setTestBridgeHooks(activeOwner: Self.owner(), relayPortOverride: { 41_902 }) { name, _ in
            await recorder.record("put:\(name)")
        }
        _ = try await Self.start(bridge)
        #expect(await bridge.activeRelayCount == 1)
        #expect(await bridge.relayPort(for: "cam_type") == 41_902)
        #expect(await recorder.count("ensure") == 2)
        #expect(await recorder.count("kill") == 1)

        await bridge.shutdown()
        #expect(await bridge.activeRelayCount == 0)
    }

    @Test("A reopen during the shutdown waits for the helper to stop before starting a new one")
    func reopenWaitsForTheShutdownInFlight() async throws {
        let bridge = XiaomiCameraBridge()
        let recorder = Recorder()
        let killing = Gate()
        let reopenWaiting = Gate()
        let owner = Self.owner()
        await bridge.setEnsureRunningOverride({
            await recorder.record("ensure")
            await bridge.setTestBridgeHooks(activeOwner: owner, relayPortOverride: { 41_903 }) { _, _ in }
        })
        await bridge.setProcessShutdownOverride({
            await recorder.record("kill-begin")
            await killing.wait()
            await recorder.record("kill-end")
        }, onStartWaiting: {
            await recorder.record("reopen-waiting")
            reopenWaiting.open()
        })
        await bridge.setTestBridgeHooks(activeOwner: owner, relayPortOverride: { 41_903 }) { _, _ in }

        let closing = Task { await bridge.shutdown() }
        await killing.waitUntilEntered()
        let reopen = Task { try await Self.start(bridge) }
        await reopenWaiting.wait()

        killing.open()
        await closing.value
        _ = try await reopen.value

        #expect(await recorder.events == ["kill-begin", "reopen-waiting", "kill-end", "ensure"])
        #expect(await bridge.activeRelayCount == 1)

        await bridge.shutdown()
        #expect(await bridge.activeRelayCount == 0)
    }
}
