import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor FakePTZClient: CameraPTZControlling {
    private var beginContinuation: CheckedContinuation<(token: CameraPTZSessionToken, mode: CameraPTZMotionMode?), Error>?
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopTokens: [CameraPTZSessionToken] = []
    private var stopWaiters: [CheckedContinuation<[CameraPTZSessionToken], Never>] = []
    var stopResult = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)

    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginContinuation = continuation
                let waiters = beginWaiters
                beginWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
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
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: stopTokens) }
        return stopResult
    }

    /// Suspends until the controller actually called `begin`. The fake has no timer, so the wait
    /// ends on the signal the path produces instead of after a fixed number of yields.
    func waitForBegin() async {
        guard beginContinuation == nil else { return }
        await withCheckedContinuation { beginWaiters.append($0) }
    }

    /// Suspends until a stop was written; returns at once when one already landed, so a stop that
    /// arrived before the wait cannot strand it.
    func waitForStops() async -> [CameraPTZSessionToken] {
        guard stopTokens.isEmpty else { return stopTokens }
        return await withCheckedContinuation { stopWaiters.append($0) }
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
    func cancelledBeginReleasesToken() async {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        await client.waitForBegin()
        controller.ptzDragCancelled()
        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = await client.waitForStops()
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil)
    }

    @Test("A begin that resolves after a device switch stops its old token and does not touch the new camera")
    func lateBeginAfterDeviceSwitchIsIsolated() async {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        await client.waitForBegin()
        configure(controller, deviceId: "cam-b", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        await client.releaseBegin(token)

        let stops = await client.waitForStops()
        #expect(stops == [token])
        #expect(controller.ptzNotice == nil, "the old stream's error must not paint the new camera")
    }

    @Test("A stop write failure is visible even when the caller asked for a silent close")
    func stopFailureIsVisibleOnTheSameCamera() async {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        await client.setStopResult(CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        ))
        configure(controller, deviceId: "cam-a", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        controller.ptzToken = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzDragID = UUID()
        controller.finishPTZMove(notify: false)
        // The stop task is the signal that produces the notice: wait for it, not for a fixed
        // number of yields, which a loaded runner can outrun.
        await controller.ptzStopTask?.value
        let stops = await client.waitForStops()
        #expect(stops.count == 1)
        #expect(controller.ptzNotice?.contains("停止指令写入失败") == true)
    }
}

private extension FakePTZClient {
    func setStopResult(_ result: CameraPTZStopResult) {
        stopResult = result
    }
}
