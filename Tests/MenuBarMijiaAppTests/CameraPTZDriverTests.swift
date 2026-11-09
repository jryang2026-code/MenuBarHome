import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor FakePTZClient: CameraPTZControlling {
    private struct StopWaiter {
        var minimum: Int
        var id: UInt64
        var continuation: CheckedContinuation<[CameraPTZSessionToken]?, Never>
    }

    private var beginContinuation: CheckedContinuation<(token: CameraPTZSessionToken, mode: CameraPTZMotionMode?), Error>?
    private var beginWaiter: (id: UInt64, continuation: CheckedContinuation<Bool, Never>)?
    private var stopTokens: [CameraPTZSessionToken] = []
    private var stopWaiter: StopWaiter?
    private var scriptedStops: [CameraPTZStopResult] = []
    private var nextWaiterID: UInt64 = 0
    var stopResult = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)

    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginContinuation = continuation
                if let waiter = beginWaiter {
                    beginWaiter = nil
                    waiter.continuation.resume(returning: true)
                }
            }
        } onCancel: {
            Task { await self.failBegin() }
        }
    }

    /// `URLSession` throws as soon as its task is cancelled, even after the bridge accepted `begin`.
    private func failBegin() {
        beginContinuation?.resume(throwing: CancellationError())
        beginContinuation = nil
    }

    func releaseBegin(_ token: CameraPTZSessionToken, mode: CameraPTZMotionMode = .unknown) {
        beginContinuation?.resume(returning: (token, mode))
        beginContinuation = nil
    }

    func move(direction: CameraPTZDirection, token: CameraPTZSessionToken, seq: UInt64) async throws {}
    func heartbeat(token: CameraPTZSessionToken, seq: UInt64) async throws {}

    func stop(token: CameraPTZSessionToken) async throws -> CameraPTZStopResult {
        stopTokens.append(token)
        if let waiter = stopWaiter, stopTokens.count >= waiter.minimum {
            stopWaiter = nil
            waiter.continuation.resume(returning: stopTokens)
        }
        if !scriptedStops.isEmpty {
            return scriptedStops.removeFirst()
        }
        return stopResult
    }

    /// Waits until the controller actually called `begin`. The deadline removes the waiter and
    /// resumes it with `false`, so a regression fails the test instead of hanging the run.
    func waitForBegin(timeout: Duration = .seconds(30)) async -> Bool {
        guard beginContinuation == nil else { return true }
        nextWaiterID &+= 1
        let id = nextWaiterID
        return await withCheckedContinuation { continuation in
            beginWaiter = (id, continuation)
            Task {
                try? await Task.sleep(for: timeout)
                self.expireBeginWaiter(id)
            }
        }
    }

    /// Waits until at least `minimum` stops were written; nil when the deadline expired. A stop
    /// that arrived before the wait cannot strand it.
    func waitForStops(minimum: Int = 1, timeout: Duration = .seconds(30)) async -> [CameraPTZSessionToken]? {
        guard stopTokens.count < minimum else { return stopTokens }
        nextWaiterID &+= 1
        let id = nextWaiterID
        return await withCheckedContinuation { continuation in
            stopWaiter = StopWaiter(minimum: minimum, id: id, continuation: continuation)
            Task {
                try? await Task.sleep(for: timeout)
                self.expireStopWaiter(id)
            }
        }
    }

    private func expireBeginWaiter(_ id: UInt64) {
        guard let waiter = beginWaiter, waiter.id == id else { return }
        beginWaiter = nil
        waiter.continuation.resume(returning: false)
    }

    private func expireStopWaiter(_ id: UInt64) {
        guard let waiter = stopWaiter, waiter.id == id else { return }
        stopWaiter = nil
        waiter.continuation.resume(returning: nil)
    }
}

@MainActor
@Suite("Camera PTZ driver lifecycle (#97)", .serialized)
struct CameraPTZDriverTests {
    private func binding() -> CameraPTZBinding {
        CameraPTZBinding(
            capability: CameraPTZCapability(
                model: "chuangmi.camera.061a01",
                vendor: "cs2",
                mode: .unknown,
                confidence: .pendingRealDevice
            ),
            streamName: "cam_raw_test"
        )
    }

    private func configure(
        _ controller: CameraLivePanelController,
        deviceId: String,
        client: FakePTZClient
    ) {
        controller.configurePTZPreview(
            deviceId: deviceId,
            binding: binding(),
            stream: .demo(deviceId: deviceId),
            notice: nil,
            ready: true,
            client: client,
            hasFrame: true
        )
    }

    @Test("A cancelled begin releases the bridge token instead of leaking it")
    func cancelledBeginReleasesToken() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        #expect(await client.waitForBegin(), "the controller never called begin")
        controller.ptzDragCancelled()
        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = try #require(await client.waitForStops(), "the controller never wrote a stop")
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil)
    }

    @Test("A begin that resolves after a device switch stops its old token and does not touch the new camera")
    func lateBeginAfterDeviceSwitchIsIsolated() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        #expect(await client.waitForBegin(), "the controller never called begin")
        configure(controller, deviceId: "cam-b", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = try #require(await client.waitForStops(), "the controller never wrote a stop")
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil, "the old stream's error must not paint the new camera")
    }

    @Test("A stop write failure retries once, then the stop-again button sends one more stop")
    func stopWriteFailureRetriesOnceThenTheButtonSendsStopAgain() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        await client.setStopResult(failed)
        let previousLanguage = L10n.currentLanguage
        L10n.currentLanguage = .zhHans
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
            L10n.currentLanguage = previousLanguage
        }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzToken = token
        controller.ptzDeviceId = "cam-a"
        controller.ptzDragID = UUID()
        controller.finishPTZMove(notify: false)

        let first = try #require(await client.waitForStops(), "the first stop was never written")
        #expect(first == [token])
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)

        gate.release()
        let second = try #require(await client.waitForStops(minimum: 2), "the automatic retry was never written")
        #expect(second == [token, token])
        for _ in 0..<5000 where controller.ptzNotice == nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == "停止指令写入失败，云台可能仍在转动")
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        let third = try #require(await client.waitForStops(minimum: 3), "the stop-again button wrote nothing")
        #expect(third == [token, token, token])
        #expect(controller.ptzNotice == "停止指令写入失败，云台可能仍在转动")
        #expect(controller.offersPTZStopRetry == true)
    }

    @Test("A stop that succeeds on the automatic retry clears the warning")
    func automaticStopRetrySuccessClearsTheWarning() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        await client.setStopScript([
            CameraPTZStopResult(sent: false, confirmed: false, mode: .continuous, errorReason: "write_failed"),
            CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)
        ])
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        controller.ptzToken = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = try #require(await client.waitForStops(), "the first stop was never written")
        #expect(controller.ptzNotice == nil)

        gate.release()
        let stops = try #require(await client.waitForStops(minimum: 2), "the automatic retry was never written")
        #expect(stops.count == 2)
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("Pressing stop again after a failed stop clears the warning when the write succeeds")
    func manualStopSuccessClearsTheWarning() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        await client.setStopScript([failed, failed, CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)])
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        controller.ptzToken = CameraPTZSessionToken(epoch: "e1", session: 4)
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = try #require(await client.waitForStops(), "the first stop was never written")
        gate.release()
        _ = try #require(await client.waitForStops(minimum: 2), "the automatic retry was never written")
        for _ in 0..<5000 where controller.offersPTZStopRetry == false {
            await Task.yield()
        }
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        _ = try #require(await client.waitForStops(minimum: 3), "the stop-again button wrote nothing")
        for _ in 0..<5000 where controller.ptzNotice != nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("The automatic stop retry waits 500 ms unless a test holds it")
    func automaticStopRetryDelayIsHalfASecond() {
        #expect(CameraLivePanelController.ptzStopRetryDelay == .milliseconds(500))
    }
}

@MainActor
private final class PTZRetryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
                return
            }
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private extension FakePTZClient {
    func setStopResult(_ result: CameraPTZStopResult) {
        stopResult = result
    }

    func setStopScript(_ results: [CameraPTZStopResult]) {
        scriptedStops = results
    }
}
