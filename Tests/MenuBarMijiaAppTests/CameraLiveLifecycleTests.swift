import AppKit
import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor MockCameraLifecycleProvider: HomeProvider {
    private var resolveEnterWaiter: CheckedContinuation<Void, Never>?
    private var resolveReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondResolveWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: (deviceID: String, continuation: CheckedContinuation<Void, Never>)?
    private var pauseFirstResolve = false
    private(set) var resolveCallOrder: [Int] = []
    private(set) var stoppedDeviceIDs: [String] = []
    private var resolveCount = 0
    var streamToReturn: CameraStreamSource

    init(pauseFirstResolve: Bool = false, streamToReturn: CameraStreamSource = .demo(deviceId: "cam-default")) {
        self.pauseFirstResolve = pauseFirstResolve
        self.streamToReturn = streamToReturn
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { $0.finish() }
    }

    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}

    func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        resolveCount += 1
        let index = resolveCount
        resolveCallOrder.append(index)
        if index == 1, pauseFirstResolve {
            resolveEnterWaiter?.resume()
            resolveEnterWaiter = nil
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                resolveReleaseContinuation = cont
            }
            resolveCallOrder.append(-1)
        }
        if index >= 2 {
            secondResolveWaiter?.resume()
            secondResolveWaiter = nil
        }
        return streamToReturn
    }

    func stopCameraStream(for device: SmartDevice) async {
        stoppedDeviceIDs.append(device.id)
        if let waiter = stopWaiter, waiter.deviceID == device.id {
            stopWaiter = nil
            waiter.continuation.resume()
        }
    }

    func waitForFirstResolveEntered() async {
        if resolveCount >= 1 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            resolveEnterWaiter = cont
        }
    }

    func waitForSecondResolve() async {
        if resolveCount >= 2 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            secondResolveWaiter = cont
        }
    }

    func waitForStop(deviceID: String) async {
        if stoppedDeviceIDs.contains(deviceID) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stopWaiter = (deviceID, cont)
        }
    }

    func releaseFirstResolve() {
        resolveReleaseContinuation?.resume()
        resolveReleaseContinuation = nil
    }
}

private actor MockTerminationPTZClient: CameraPTZControlling {
    private(set) var stoppedTokens: [CameraPTZSessionToken] = []
    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        (CameraPTZSessionToken(epoch: "e1", session: 1), .continuous)
    }
    func move(direction: CameraPTZDirection, token: CameraPTZSessionToken, seq: UInt64) async throws {}
    func heartbeat(token: CameraPTZSessionToken, seq: UInt64) async throws {}
    func stop(token: CameraPTZSessionToken) async throws -> CameraPTZStopResult {
        stoppedTokens.append(token)
        return CameraPTZStopResult(sent: true, confirmed: true, mode: .continuous)
    }
}

@Suite("Camera Live Lifecycle", .serialized)
@MainActor
struct CameraLiveLifecycleTests {
    private static func makeCameraDevice(id: String = "cam-life-1") -> SmartDevice {
        SmartDevice(
            id: id,
            name: "客厅摄像机",
            roomId: "living",
            roomName: "客厅",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(
                entityId: "camera.\(id)",
                isOn: true
            ))
        )
    }

    @Test("Post-first-frame stream stall triggers watchdog and flapping stream stops after bounded retries")
    func postFirstFrameWatchdogAndFlappingRetryCap() async throws {
        let mp4URL = try #require(URL(string: "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4"))
        let source = CameraStreamSource.liveMP4(mp4URL, mjpegFallback: nil, ptz: nil)
        let playback = try #require(CameraLivePlayback(deviceID: "cam-1", lensID: "main", source: source))
        playback.stallTimeout = .milliseconds(80)
        playback.watchdogInterval = .milliseconds(20)
        playback.stablePlaybackThreshold = .milliseconds(40)
        playback.reconnectBackoff = .milliseconds(10)
        playback.failureBackoff = .milliseconds(10)
        playback.maxFailedAttempts = 3
        playback.maxReconnectAttempts = 3

        var playCalls = 0
        var terminalFailure: String?
        let (doneStream, doneCont) = AsyncStream<Void>.makeStream()

        playback.onFailure = { detail in
            terminalFailure = detail ?? "failed"
            doneCont.yield()
            doneCont.finish()
        }

        var stopContinuation: CheckedContinuation<String?, Never>?
        playback.player.stopOverride = { reason in
            stopContinuation?.resume(returning: reason)
            stopContinuation = nil
        }
        playback.player.playOverride = { _, player in
            playCalls += 1
            player.notifyDecodedFrame(1)
            let reason = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                stopContinuation = cont
            }
            return CameraLiveVideoPlayer.Outcome(framesDecoded: 1, failure: reason ?? "stream stalled")
        }

        playback.start()
        for await _ in doneStream { break }

        #expect(playCalls == 3)
        #expect(terminalFailure == "stream stalled")
        #expect(playback.failure != nil)
    }

    @Test("Paused playback suspends stall watchdog and resets lastFrameAt on resume")
    func pausedPlaybackSuspendsWatchdogAndResumesCleanly() async throws {
        let mp4URL = try #require(URL(string: "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_pause&mp4"))
        let source = CameraStreamSource.liveMP4(mp4URL, mjpegFallback: nil, ptz: nil)
        let playback = try #require(CameraLivePlayback(deviceID: "cam-pause", lensID: "main", source: source))
        playback.stallTimeout = .milliseconds(60)
        playback.watchdogInterval = .milliseconds(15)
        playback.maxFailedAttempts = 1
        playback.maxReconnectAttempts = 1

        var stalledDuringPause = false
        var pauseWindowFinished = false
        let (doneStream, doneCont) = AsyncStream<Void>.makeStream()

        playback.onFailure = { _ in
            doneCont.yield()
            doneCont.finish()
        }

        var stopContinuation: CheckedContinuation<String?, Never>?
        playback.player.stopOverride = { reason in
            if !pauseWindowFinished {
                stalledDuringPause = true
            }
            stopContinuation?.resume(returning: reason)
            stopContinuation = nil
        }
        playback.player.playOverride = { _, player in
            player.notifyDecodedFrame(1)
            player.setPlaybackPaused(true)
            try? await Task.sleep(for: .milliseconds(110))
            pauseWindowFinished = true
            player.setPlaybackPaused(false)
            let reason = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                stopContinuation = cont
            }
            return CameraLiveVideoPlayer.Outcome(framesDecoded: 1, failure: reason)
        }

        playback.start()
        for await _ in doneStream { break }

        #expect(stalledDuringPause == false)
        #expect(pauseWindowFinished == true)
        #expect(playback.failure != nil)
    }

    @Test("reloadStream awaits a cancelled resolveTask before starting the next resolveCameraStream")
    func reloadStreamAwaitsCancelledResolveTask() async throws {
        let controller = CameraLivePanelController.shared
        controller.presentsActively = false
        defer {
            controller.closePanel()
            controller.consumeMJPEGOverride = nil
            controller.bridgeShutdownOverride = nil
        }

        let suiteName = "MenuBarMijiaTests.CameraReload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cam = Self.makeCameraDevice(id: "cam-reload-1")
        let provider = MockCameraLifecycleProvider(
            pauseFirstResolve: true,
            streamToReturn: .demo(deviceId: cam.id)
        )
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        store.devices = [cam]
        controller.install(with: store)
        controller.activeDeviceId = cam.id

        controller.reloadStream()
        await provider.waitForFirstResolveEntered()

        controller.reloadStream()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await provider.resolveCallOrder == [1])

        await provider.releaseFirstResolve()
        await provider.waitForSecondResolve()
        #expect(await provider.resolveCallOrder == [1, -1, 2])
    }

    @Test("MJPEG retry exhaustion after flapping frames schedules stopCameraStream")
    func mjpegFlappingExhaustionSchedulesStopStream() async throws {
        let controller = CameraLivePanelController.shared
        controller.presentsActively = false
        let oldBackoff = controller.mjpegRetryBackoff
        let oldStable = controller.mjpegStableWindow
        let oldStall = controller.mjpegStallTimeout
        let oldWatchdog = controller.mjpegWatchdogInterval
        let oldMaxAttempts = controller.mjpegMaxAttempts
        defer {
            controller.mjpegRetryBackoff = oldBackoff
            controller.mjpegStableWindow = oldStable
            controller.mjpegStallTimeout = oldStall
            controller.mjpegWatchdogInterval = oldWatchdog
            controller.mjpegMaxAttempts = oldMaxAttempts
            controller.consumeMJPEGOverride = nil
            controller.closePanel()
        }

        controller.mjpegRetryBackoff = .milliseconds(10)
        controller.mjpegStableWindow = .milliseconds(30)
        controller.mjpegStallTimeout = .milliseconds(80)
        controller.mjpegWatchdogInterval = .milliseconds(20)
        controller.mjpegMaxAttempts = 3

        let suiteName = "MenuBarMijiaTests.CameraMJPEG.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mjpegURL = try #require(URL(string: "http://127.0.0.1:43123/api/stream.mjpeg?src=cam_mjpeg_1"))
        let cam = Self.makeCameraDevice(id: "cam-mjpeg-1")
        let provider = MockCameraLifecycleProvider(pauseFirstResolve: false, streamToReturn: .mjpeg(mjpegURL))
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        store.devices = [cam]
        controller.install(with: store)
        controller.activeDeviceId = cam.id

        var mjpegConnects = 0
        controller.consumeMJPEGOverride = { _, onFrame in
            mjpegConnects += 1
            onFrame(NSImage(size: NSSize(width: 2, height: 2)))
            try? await Task.sleep(for: .milliseconds(45))
        }

        controller.reloadStream()
        await provider.waitForStop(deviceID: cam.id)

        #expect(mjpegConnects == 3)
        #expect(await provider.stoppedDeviceIDs.contains(cam.id))
        #expect(controller.errorMessage != nil)
    }

    @Test("prepareForTermination defers app exit until PTZ stop, stream release, and bridge shutdown complete")
    func prepareForTerminationCleansUpPTZStreamAndBridge() async throws {
        let controller = CameraLivePanelController.shared
        controller.presentsActively = false
        defer {
            controller.bridgeShutdownOverride = nil
            controller.hasLiveOwnedProcessOverride = nil
            controller.closePanel()
        }
        controller.hasLiveOwnedProcessOverride = { false }

        let suiteName = "MenuBarMijiaTests.CameraTerminate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cam = Self.makeCameraDevice(id: "cam-term-1")
        let provider = MockCameraLifecycleProvider(
            pauseFirstResolve: false,
            streamToReturn: .demo(deviceId: cam.id)
        )
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        store.devices = [cam]
        controller.install(with: store)

        let ptzClient = MockTerminationPTZClient()
        let capability = CameraPTZCapability(
            model: cam.model,
            vendor: "cs2",
            mode: .continuous,
            confidence: .verified
        )
        let binding = CameraPTZBinding(capability: capability, streamName: "cam_raw_term")
        controller.configurePTZPreview(
            store: store,
            deviceId: cam.id,
            binding: binding,
            stream: .demo(deviceId: cam.id),
            notice: nil,
            ready: true,
            client: ptzClient,
            hasFrame: true
        )
        let activeToken = CameraPTZSessionToken(epoch: "e1", session: 42)
        controller.ptzToken = activeToken
        controller.ptzDragID = UUID()

        actor ShutdownFlag {
            var called = false
            func mark() { called = true }
            func isCalled() -> Bool { called }
        }
        let bridgeShutdown = ShutdownFlag()
        controller.bridgeShutdownOverride = {
            await bridgeShutdown.mark()
        }

        let (replyStream, replyCont) = AsyncStream<Void>.makeStream()
        let reply = controller.prepareForTermination {
            replyCont.yield()
            replyCont.finish()
        }
        #expect(reply == .terminateLater)
        for await _ in replyStream { break }

        #expect(await ptzClient.stoppedTokens == [activeToken])
        #expect(await provider.stoppedDeviceIDs.contains(cam.id))
        #expect(await bridgeShutdown.isCalled())
        #expect(controller.activeDeviceId == nil)

        controller.bridgeShutdownOverride = nil
        await controller.terminationTask?.value
        #expect(controller.prepareForTermination() == .terminateNow)
    }
}
