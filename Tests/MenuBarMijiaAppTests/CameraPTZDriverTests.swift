import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor FakePTZClient: CameraPTZControlling {
    private var beginContinuation: CheckedContinuation<(token: CameraPTZSessionToken, mode: CameraPTZMotionMode?), Error>?
    private var beginWaiter: (id: UInt64, continuation: CheckedContinuation<Bool, Never>)?
    private var stopTokens: [CameraPTZSessionToken] = []
    private var stopWaiter: (id: UInt64, continuation: CheckedContinuation<[CameraPTZSessionToken]?, Never>)?
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
        if let waiter = stopWaiter {
            stopWaiter = nil
            waiter.continuation.resume(returning: stopTokens)
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

    /// Waits until a stop was written; nil when the deadline expired. A stop that arrived before
    /// the wait cannot strand it.
    func waitForStops(timeout: Duration = .seconds(30)) async -> [CameraPTZSessionToken]? {
        guard stopTokens.isEmpty else { return stopTokens }
        nextWaiterID &+= 1
        let id = nextWaiterID
        return await withCheckedContinuation { continuation in
            stopWaiter = (id, continuation)
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

    @Test("A stop write failure is visible even when the caller asked for a silent close")
    func stopFailureIsVisibleOnTheSameCamera() async throws {
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
        // The stop is recorded before the task sets the notice; wait for each with a deadline that
        // fails the test instead of hanging it.
        let stops = try #require(await client.waitForStops(), "the controller never wrote a stop")
        #expect(stops.count == 1)
        for _ in 0..<250 where controller.ptzNotice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.ptzNotice?.contains("停止指令写入失败") == true)
    }
}

private extension FakePTZClient {
    func setStopResult(_ result: CameraPTZStopResult) {
        stopResult = result
    }
}
