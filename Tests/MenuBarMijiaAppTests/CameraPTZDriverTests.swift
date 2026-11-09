import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor FakePTZClient: CameraPTZControlling {
    private var beginContinuation: CheckedContinuation<(token: CameraPTZSessionToken, mode: CameraPTZMotionMode?), Error>?
    private var stopTokens: [CameraPTZSessionToken] = []
    private var scriptedStops: [CameraPTZStopResult] = []
    var stopResult = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)

    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginContinuation = continuation
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
        if !scriptedStops.isEmpty {
            return scriptedStops.removeFirst()
        }
        return stopResult
    }

    func recordedStops() -> [CameraPTZSessionToken] { stopTokens }
    func hasPendingBegin() -> Bool { beginContinuation != nil }
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

    private func waitForStops(_ client: FakePTZClient, count: Int = 1) async -> [CameraPTZSessionToken] {
        for _ in 0..<5000 {
            let stops = await client.recordedStops()
            if stops.count >= count { return stops }
            await Task.yield()
        }
        return await client.recordedStops()
    }

    @Test("A cancelled begin releases the bridge token instead of leaking it")
    func cancelledBeginReleasesToken() async {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        for _ in 0..<2000 where await !client.hasPendingBegin() {
            await Task.yield()
        }
        controller.ptzDragCancelled()
        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = await waitForStops(client)
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil)
    }

    @Test("A begin that resolves after a device switch stops its old token and does not touch the new camera")
    func lateBeginAfterDeviceSwitchIsIsolated() async {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        for _ in 0..<2000 where await !client.hasPendingBegin() {
            await Task.yield()
        }
        configure(controller, deviceId: "cam-b", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = await waitForStops(client)
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil, "the old stream's error must not paint the new camera")
    }

    @Test("A stop write failure retries once, then the stop-again button sends one more stop")
    func stopWriteFailureRetriesOnceThenTheButtonSendsStopAgain() async {
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
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
            L10n.currentLanguage = previousLanguage
            gate.release()
        }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzToken = token
        controller.ptzDeviceId = "cam-a"
        controller.ptzDragID = UUID()
        controller.finishPTZMove(notify: false)

        let first = await waitForStops(client, count: 1)
        #expect(first == [token])
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)

        gate.release()
        let second = await waitForStops(client, count: 2)
        #expect(second == [token, token])
        for _ in 0..<5000 where controller.ptzNotice == nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == "停止指令写入失败，云台可能仍在转动")
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        let third = await waitForStops(client, count: 3)
        #expect(third == [token, token, token])
        #expect(controller.ptzNotice == "停止指令写入失败，云台可能仍在转动")
        #expect(controller.offersPTZStopRetry == true)
    }

    @Test("A stop that succeeds on the automatic retry clears the warning")
    func automaticStopRetrySuccessClearsTheWarning() async {
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
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
            gate.release()
        }

        controller.ptzToken = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = await waitForStops(client, count: 1)
        #expect(controller.ptzNotice == nil)

        gate.release()
        let stops = await waitForStops(client, count: 2)
        #expect(stops.count == 2)
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("Pressing stop again after a failed stop clears the warning when the write succeeds")
    func manualStopSuccessClearsTheWarning() async {
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
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
            gate.release()
        }

        controller.ptzToken = CameraPTZSessionToken(epoch: "e1", session: 4)
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = await waitForStops(client, count: 1)
        gate.release()
        _ = await waitForStops(client, count: 2)
        for _ in 0..<5000 where controller.offersPTZStopRetry == false {
            await Task.yield()
        }
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        _ = await waitForStops(client, count: 3)
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
