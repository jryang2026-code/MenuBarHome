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
    private var stopErrorCount = 0
    private var stopHold: (@Sendable () async -> Void)?
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
        if let stopHold {
            await stopHold()
        }
        if stopErrorCount > 0 {
            stopErrorCount -= 1
            throw CameraPTZClientError.network
        }
        if !scriptedStops.isEmpty {
            return scriptedStops.removeFirst()
        }
        return stopResult
    }

    func recordedStops() -> [CameraPTZSessionToken] { stopTokens }

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

    /// A production camera switch closes the stream (which keeps a sticky stop warning), then
    /// attaches the new camera's bridge client.
    private func switchCamera(
        _ controller: CameraLivePanelController,
        to deviceId: String,
        client: FakePTZClient
    ) {
        controller.clearPTZ()
        controller.activeDeviceId = deviceId
        controller.ptzBinding = binding()
        controller.ptzClientReady = true
        controller.ptzClient = client
        controller.streamSource = .demo(deviceId: deviceId)
        controller.hasLiveVideoFrame = true
    }

    private func failStopTwice(
        _ controller: CameraLivePanelController,
        client: FakePTZClient,
        token: CameraPTZSessionToken,
        deviceId: String,
        gate: PTZRetryGate
    ) async throws {
        controller.ptzToken = token
        controller.ptzDeviceId = deviceId
        controller.finishPTZMove(notify: false)
        _ = try #require(await client.waitForStops(), "the first stop was never attempted")
        gate.release()
        _ = try #require(await client.waitForStops(minimum: 2), "the automatic retry was never written")
        for _ in 0..<5000 where controller.offersPTZStopRetry == false {
            await Task.yield()
        }
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
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
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

    @Test("Stop again does not clear a failed write when the old session reports a step no-op")
    func oldSessionRetryDoesNotClearAFailedStop() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        let oldSession = CameraPTZStopResult(sent: false, confirmed: false, mode: .step)
        await client.setStopScript([failed, failed, oldSession])
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
        for _ in 0..<5000 where controller.ptzManualStopInFlight {
            await Task.yield()
        }
        #expect(controller.ptzManualStopInFlight == false)
        #expect(controller.ptzNotice == "停止指令写入失败，云台可能仍在转动")
        #expect(controller.offersPTZStopRetry == true)
    }

    @Test("A thrown stop retries once and clears the warning when the retry succeeds")
    func thrownStopRetriesOnceAndSuccessClearsTheWarning() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        await client.setStopErrorCount(1)
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
        _ = try #require(await client.waitForStops(), "the first stop was never attempted")
        #expect(controller.ptzNotice == nil)

        gate.release()
        let stops = try #require(await client.waitForStops(minimum: 2), "a thrown stop was not retried")
        #expect(stops.count == 2)
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("A stop that throws twice stays on the manual warning, and the button can still stop it")
    func thrownStopTwiceStaysOnTheManualWarning() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        await client.setStopErrorCount(2)
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
        _ = try #require(await client.waitForStops(), "the first stop was never attempted")
        gate.release()
        _ = try #require(await client.waitForStops(minimum: 2), "a thrown stop was not retried")
        for _ in 0..<5000 where controller.ptzNotice == nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        _ = try #require(await client.waitForStops(minimum: 3), "the stop-again button wrote nothing")
        for _ in 0..<5000 where controller.ptzNotice != nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("A successful begin and a panel close keep the stop-write warning until a stop succeeds")
    func warningSurvivesBeginAndPanelClose() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        configure(controller, deviceId: "cam-a", client: client)
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        let attempt = CameraPTZStopAttempt(
            token: CameraPTZSessionToken(epoch: "e1", session: 9),
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: client
        )
        controller.ptzUnresolvedStops = [attempt]
        controller.showPTZNotice(CameraLivePanelController.stopWriteFailedNotice, sticky: true)
        controller.showPTZNotice("a transient move error")
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        #expect(await client.waitForBegin(), "the controller never called begin")
        await client.releaseBegin(CameraPTZSessionToken(epoch: "e1", session: 10))
        for _ in 0..<5000 where controller.ptzToken == nil {
            await Task.yield()
        }
        #expect(controller.ptzToken != nil)
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)

        controller.clearPTZ()
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)
    }

    @Test("The automatic retry stops the captured session after the panel lifecycle changed and stays retryable")
    func automaticRetrySurvivesLifecycleChange() async throws {
        let controller = CameraLivePanelController.shared
        let client = FakePTZClient()
        await client.setStopResult(CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        ))
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let token = CameraPTZSessionToken(epoch: "e1", session: 9)
        controller.ptzToken = token
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = try #require(await client.waitForStops(), "the first stop was never written")

        // Closing, reloading or switching cameras bumps the lifecycle while the retry waits.
        controller.ptzLifecycleID = UUID()
        gate.release()
        let stops = try #require(await client.waitForStops(minimum: 2), "the retry was skipped after the lifecycle changed")
        #expect(stops == [token, token])
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil, "the old session's failure must not paint the new lifecycle")
        #expect(controller.ptzUnresolvedStops.count == 1, "a finally failed stop must stay retryable")
        #expect(controller.ptzVisibleNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)
    }

    @Test("A successful stop on another camera leaves the older failed stop and its retry untouched")
    func successfulStopOnAnotherCameraKeepsOlderRecovery() async throws {
        let controller = CameraLivePanelController.shared
        let clientA = FakePTZClient()
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        await clientA.setStopScript([failed, failed, CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)])
        configure(controller, deviceId: "cam-a", client: clientA)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let tokenA = CameraPTZSessionToken(epoch: "e1", session: 1)
        let attemptA = CameraPTZStopAttempt(
            token: tokenA,
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: clientA
        )
        try await failStopTwice(controller, client: clientA, token: tokenA, deviceId: "cam-a", gate: gate)
        #expect(controller.ptzUnresolvedStops == [attemptA])
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        controller.ptzStopRetryHold = nil

        let clientB = FakePTZClient()
        switchCamera(controller, to: "cam-b", client: clientB)
        #expect(controller.ptzUnresolvedStops == [attemptA])

        let tokenB = CameraPTZSessionToken(epoch: "e1", session: 2)
        controller.ptzToken = tokenB
        controller.ptzDeviceId = "cam-b"
        controller.finishPTZMove(notify: false)
        _ = try #require(await clientB.waitForStops(), "camera B never wrote its stop")
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops == [attemptA], "B's success replaced A's unresolved record")
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)

        controller.retryFailedPTZStop()
        let retried = try #require(await clientA.waitForStops(minimum: 3), "the stop-again button did not reach A's client")
        #expect(retried.count == 3)
        for _ in 0..<5000 where controller.ptzNotice != nil {
            await Task.yield()
        }
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("Identical session tokens on two cameras keep two unresolved stops, and retry resolves each")
    func identicalTokensOnTwoCamerasStayIndependent() async throws {
        let controller = CameraLivePanelController.shared
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        let succeeded = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)
        // The bridge epoch is per process and the session counter is per stream, so two cameras
        // can legitimately hand out the same token.
        let sharedToken = CameraPTZSessionToken(epoch: "e1", session: 1)

        let clientA = FakePTZClient()
        await clientA.setStopScript([failed, failed, succeeded])
        configure(controller, deviceId: "cam-a", client: clientA)
        let gateA = PTZRetryGate()
        controller.ptzStopRetryHold = { await gateA.wait() }
        defer {
            gateA.release()
            controller.ptzStopRetryHold = nil
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let attemptA = CameraPTZStopAttempt(
            token: sharedToken,
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: clientA
        )
        try await failStopTwice(controller, client: clientA, token: sharedToken, deviceId: "cam-a", gate: gateA)
        #expect(controller.ptzUnresolvedStops == [attemptA])

        let clientB = FakePTZClient()
        await clientB.setStopScript([failed, failed, failed, succeeded])
        switchCamera(controller, to: "cam-b", client: clientB)
        let attemptB = CameraPTZStopAttempt(
            token: sharedToken,
            deviceId: "cam-b",
            lifecycleID: controller.ptzLifecycleID,
            client: clientB
        )
        let gateB = PTZRetryGate()
        controller.ptzStopRetryHold = { await gateB.wait() }
        defer { gateB.release() }

        controller.ptzToken = sharedToken
        controller.ptzDeviceId = "cam-b"
        controller.finishPTZMove(notify: false)
        _ = try #require(await clientB.waitForStops(), "camera B never wrote its first stop")
        gateB.release()
        _ = try #require(await clientB.waitForStops(minimum: 2), "camera B's automatic retry was never written")
        for _ in 0..<5000 where controller.ptzUnresolvedStops.count < 2 {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops == [attemptA, attemptB], "identical tokens collapsed into one record")
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice)
        controller.ptzStopRetryHold = nil

        // A's stop recovers, B's third write fails again: only A leaves the list.
        controller.retryFailedPTZStop()
        let bStops = try #require(await clientB.waitForStops(minimum: 3), "the stop-again button skipped B's client")
        #expect(bStops.count == 3)
        for _ in 0..<5000 where controller.ptzUnresolvedStops != [attemptB] {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops == [attemptB], "B's failed retry did not stay listed")
        #expect(await clientA.recordedStops().count == 3)
        #expect(controller.ptzNotice == CameraLivePanelController.stopWriteFailedNotice, "B never stopped")
        #expect(controller.offersPTZStopRetry == true)

        // The next press resolves B and must not touch A's already resolved client again.
        controller.retryFailedPTZStop()
        _ = try #require(await clientB.waitForStops(minimum: 4), "the second stop-again press did not reach B")
        for _ in 0..<5000 where controller.offersPTZStopRetry {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops.isEmpty)
        #expect(await clientA.recordedStops().count == 3)
        #expect(controller.ptzNotice == nil)
        #expect(controller.offersPTZStopRetry == false)
    }

    @Test("A retry that fails after the panel closed stays retryable on reopening")
    func retryFailureAfterCloseStaysRetryable() async throws {
        let controller = CameraLivePanelController.shared
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        let succeeded = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)
        let clientA = FakePTZClient()
        await clientA.setStopScript([failed, failed, succeeded])
        configure(controller, deviceId: "cam-a", client: clientA)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.ptzStopRetryHold = nil
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let tokenA = CameraPTZSessionToken(epoch: "e1", session: 3)
        let attemptA = CameraPTZStopAttempt(
            token: tokenA,
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: clientA
        )
        controller.ptzToken = tokenA
        controller.ptzDeviceId = "cam-a"
        controller.finishPTZMove(notify: false)
        _ = try #require(await clientA.waitForStops(), "the first stop was never written")

        // The panel closes while the automatic retry is still waiting.
        controller.clearPTZ()
        gate.release()
        _ = try #require(await clientA.waitForStops(minimum: 2), "the retry was skipped after the close")
        for _ in 0..<5000 where controller.ptzUnresolvedStops.isEmpty {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops == [attemptA], "a finally failed stop was dropped after the close")
        #expect(controller.ptzNotice == nil, "the closed panel must not have painted a notice")
        #expect(controller.offersPTZStopRetry == true)
        #expect(controller.ptzVisibleNotice == CameraLivePanelController.stopWriteFailedNotice)

        // Reopening the same camera shows the warning and retries the captured client, not the
        // new panel's client.
        let reopened = FakePTZClient()
        switchCamera(controller, to: "cam-a", client: reopened)
        #expect(controller.ptzVisibleNotice == CameraLivePanelController.stopWriteFailedNotice)
        #expect(controller.offersPTZStopRetry == true)

        controller.ptzStopRetryHold = nil
        controller.retryFailedPTZStop()
        let retried = try #require(await clientA.waitForStops(minimum: 3), "the retry did not reach the captured client")
        #expect(retried.count == 3)
        for _ in 0..<5000 where !controller.ptzUnresolvedStops.isEmpty {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops.isEmpty)
        #expect(controller.ptzVisibleNotice == nil)
        #expect(await reopened.recordedStops().isEmpty)
    }

    @Test("A new failed stop for the same camera replaces the older unresolved attempt")
    func newerFailureReplacesTheOlderAttemptForTheSameCamera() async throws {
        let controller = CameraLivePanelController.shared
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        let succeeded = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)

        let clientOld = FakePTZClient()
        await clientOld.setStopResult(failed)
        configure(controller, deviceId: "cam-a", client: clientOld)
        let gateOld = PTZRetryGate()
        controller.ptzStopRetryHold = { await gateOld.wait() }
        defer {
            gateOld.release()
            controller.ptzStopRetryHold = nil
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let tokenOld = CameraPTZSessionToken(epoch: "e1", session: 4)
        let attemptOld = CameraPTZStopAttempt(
            token: tokenOld,
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: clientOld
        )
        try await failStopTwice(controller, client: clientOld, token: tokenOld, deviceId: "cam-a", gate: gateOld)
        #expect(controller.ptzUnresolvedStops == [attemptOld])

        let clientNew = FakePTZClient()
        await clientNew.setStopScript([failed, failed, succeeded])
        switchCamera(controller, to: "cam-a", client: clientNew)
        let gateNew = PTZRetryGate()
        controller.ptzStopRetryHold = { await gateNew.wait() }
        defer { gateNew.release() }

        let tokenNew = CameraPTZSessionToken(epoch: "e1", session: 5)
        let attemptNew = CameraPTZStopAttempt(
            token: tokenNew,
            deviceId: "cam-a",
            lifecycleID: controller.ptzLifecycleID,
            client: clientNew
        )
        try await failStopTwice(controller, client: clientNew, token: tokenNew, deviceId: "cam-a", gate: gateNew)
        #expect(controller.ptzUnresolvedStops == [attemptNew], "a newer failure grew the list instead of replacing")
        #expect(controller.ptzUnresolvedStops.count == 1)

        controller.ptzStopRetryHold = nil
        controller.retryFailedPTZStop()
        let retried = try #require(await clientNew.waitForStops(minimum: 3), "the retry did not use the newer attempt")
        #expect(retried.count == 3)
        #expect(await clientOld.recordedStops().count == 2, "the replaced attempt must not be retried")
        for _ in 0..<5000 where !controller.ptzUnresolvedStops.isEmpty {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops.isEmpty)
    }

    @Test("Reopening the panel during a retry batch does not start an overlapping batch")
    func reopeningDoesNotStartOverlappingRetryBatches() async throws {
        let controller = CameraLivePanelController.shared
        let failed = CameraPTZStopResult(
            sent: false,
            confirmed: false,
            mode: .continuous,
            errorReason: "write_failed"
        )
        let succeeded = CameraPTZStopResult(sent: true, confirmed: false, mode: .continuous)
        let client = FakePTZClient()
        await client.setStopScript([failed, failed, succeeded])
        configure(controller, deviceId: "cam-a", client: client)
        let gate = PTZRetryGate()
        controller.ptzStopRetryHold = { await gate.wait() }
        defer {
            gate.release()
            controller.ptzStopRetryHold = nil
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let token = CameraPTZSessionToken(epoch: "e1", session: 6)
        try await failStopTwice(controller, client: client, token: token, deviceId: "cam-a", gate: gate)
        controller.ptzStopRetryHold = nil
        #expect(controller.ptzUnresolvedStops.count == 1)

        let retryGate = PTZRetryGate()
        await client.setStopHold { await retryGate.wait() }
        controller.retryFailedPTZStop()
        _ = try #require(await client.waitForStops(minimum: 3), "the retry batch never started")

        // Close and reopen while the batch is still in flight; a second press must be ignored.
        controller.clearPTZ()
        switchCamera(controller, to: "cam-a", client: client)
        controller.retryFailedPTZStop()
        for _ in 0..<500 {
            await Task.yield()
        }
        #expect(await client.recordedStops().count == 3, "a reopened panel started a second retry batch")

        await client.setStopHold(nil)
        retryGate.release()
        for _ in 0..<5000 where !controller.ptzUnresolvedStops.isEmpty {
            await Task.yield()
        }
        #expect(controller.ptzUnresolvedStops.isEmpty)
    }

    @Test("The automatic stop retry waits about half a second")
    func automaticStopRetryWaitsHalfASecond() async throws {
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
        controller.ptzDeviceId = "cam-a"
        let start = ContinuousClock.now
        controller.finishPTZMove(notify: false)
        _ = try #require(await client.waitForStops(minimum: 2), "the automatic retry was never written")
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(450), "the retry fired after \(elapsed)")
    }

    @Test("Releasing PTZ before begin resolves retries a failed stop and raises the sticky stop warning")
    func quickClickCancelledBeginRetriesFailedStop() async throws {
        let controller = CameraLivePanelController.shared
        let client = UncancelledBeginFailingStopPTZClient()
        controller.configurePTZPreview(
            deviceId: "cam-quick",
            binding: binding(),
            stream: .demo(deviceId: "cam-quick"),
            notice: nil,
            ready: true,
            client: client,
            hasFrame: true
        )
        controller.ptzStopRetryHold = {}
        defer {
            controller.ptzStopRetryHold = nil
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        controller.ptzDragBegan(at: .init(x: 0, y: 0))
        let began = await client.waitForBegin()
        #expect(began)
        controller.ptzDragEnded()
        await client.releaseBegin(CameraPTZSessionToken(epoch: "e1", session: 42))

        let stops = await client.waitForStops(minimum: 2)
        let recorded = try #require(stops)
        #expect(recorded.count == 2, "cancelled begin must retry a failed stop instead of swallowing it")
        let deadline = ContinuousClock.now + .seconds(2)
        while !controller.offersPTZStopRetry, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.offersPTZStopRetry)
    }
}

private actor UncancelledBeginFailingStopPTZClient: CameraPTZControlling {
    private var beginContinuation: CheckedContinuation<(token: CameraPTZSessionToken, mode: CameraPTZMotionMode?), Error>?
    private var beginWaiter: CheckedContinuation<Bool, Never>?
    private var stopTokens: [CameraPTZSessionToken] = []
    private var stopWaiter: (minimum: Int, continuation: CheckedContinuation<[CameraPTZSessionToken]?, Never>)?

    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        try await withCheckedThrowingContinuation { continuation in
            beginContinuation = continuation
            if let waiter = beginWaiter {
                beginWaiter = nil
                waiter.resume(returning: true)
            }
        }
    }

    func releaseBegin(_ token: CameraPTZSessionToken) {
        beginContinuation?.resume(returning: (token, .continuous))
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
        return CameraPTZStopResult(sent: false, confirmed: false, mode: .continuous, errorReason: "write_failed")
    }

    func waitForBegin() async -> Bool {
        if beginContinuation != nil { return true }
        return await withCheckedContinuation { continuation in
            beginWaiter = continuation
        }
    }

    func waitForStops(minimum: Int) async -> [CameraPTZSessionToken]? {
        if stopTokens.count >= minimum { return stopTokens }
        return await withCheckedContinuation { continuation in
            stopWaiter = (minimum, continuation)
        }
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

    func setStopErrorCount(_ count: Int) {
        stopErrorCount = count
    }

    func setStopHold(_ hold: (@Sendable () async -> Void)?) {
        stopHold = hold
    }
}
