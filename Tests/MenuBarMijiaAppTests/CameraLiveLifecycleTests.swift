import AppKit
import AVFoundation
import Darwin
import Dispatch
import Foundation
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor MockCameraLifecycleProvider: HomeProvider {
    private var resolveEnterWaiter: CheckedContinuation<Void, Never>?
    private var resolveReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondResolveWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: (deviceID: String, continuation: CheckedContinuation<Void, Never>)?
    private var stopHoldContinuation: CheckedContinuation<Void, Never>?
    private var stopHungWaiter: CheckedContinuation<Bool, Never>?
    private var pauseFirstResolve = false
    private var hangStop = false
    private(set) var resolveCallOrder: [Int] = []
    private(set) var resolveAudioFlags: [Bool] = []
    private(set) var stoppedDeviceIDs: [String] = []
    private var resolveCount = 0
    private var resolveErrorOnAudioEnabled: (any Error)?
    var streamToReturn: CameraStreamSource

    init(
        pauseFirstResolve: Bool = false,
        hangStop: Bool = false,
        streamToReturn: CameraStreamSource = .demo(deviceId: "cam-default")
    ) {
        self.pauseFirstResolve = pauseFirstResolve
        self.hangStop = hangStop
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
        try await resolveCameraStream(for: device, quality: quality, channel: channel, audioEnabled: false)
    }

    func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int,
        audioEnabled: Bool
    ) async throws -> CameraStreamSource {
        resolveAudioFlags.append(audioEnabled)
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
        if audioEnabled, let resolveErrorOnAudioEnabled {
            throw resolveErrorOnAudioEnabled
        }
        return streamToReturn
    }

    func stopCameraStream(for device: SmartDevice) async {
        stoppedDeviceIDs.append(device.id)
        if let waiter = stopWaiter, waiter.deviceID == device.id {
            stopWaiter = nil
            waiter.continuation.resume()
        }
        if hangStop {
            stopHungWaiter?.resume(returning: true)
            stopHungWaiter = nil
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                stopHoldContinuation = cont
            }
        }
    }

    func releaseHungStop() {
        stopHoldContinuation?.resume()
        stopHoldContinuation = nil
    }

    /// True once `stopCameraStream` is parked. False if that does not happen within 30 seconds.
    func waitUntilStopHung() async -> Bool {
        if stopHoldContinuation != nil { return true }
        return await withCheckedContinuation { continuation in
            stopHungWaiter = continuation
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.expireStopHungWait()
            }
        }
    }

    private func expireStopHungWait() {
        stopHungWaiter?.resume(returning: false)
        stopHungWaiter = nil
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
    private var nextSession: UInt64 = 0
    private(set) var begunTokens: [CameraPTZSessionToken] = []
    private(set) var moves: [(direction: CameraPTZDirection, token: CameraPTZSessionToken, seq: UInt64)] = []
    private(set) var stoppedTokens: [CameraPTZSessionToken] = []
    private var moveWaiter: (minimum: Int, continuation: CheckedContinuation<Void, Never>)?
    private var stopWaiter: (minimum: Int, continuation: CheckedContinuation<Void, Never>)?

    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        nextSession &+= 1
        let token = CameraPTZSessionToken(epoch: "e1", session: nextSession)
        begunTokens.append(token)
        return (token, .continuous)
    }

    func move(direction: CameraPTZDirection, token: CameraPTZSessionToken, seq: UInt64) async throws {
        moves.append((direction, token, seq))
        if let waiter = moveWaiter, moves.count >= waiter.minimum {
            moveWaiter = nil
            waiter.continuation.resume()
        }
    }

    func heartbeat(token: CameraPTZSessionToken, seq: UInt64) async throws {}

    func stop(token: CameraPTZSessionToken) async throws -> CameraPTZStopResult {
        stoppedTokens.append(token)
        if let waiter = stopWaiter, stoppedTokens.count >= waiter.minimum {
            stopWaiter = nil
            waiter.continuation.resume()
        }
        return CameraPTZStopResult(sent: true, confirmed: true, mode: .continuous)
    }

    func waitForMoves(minimum: Int) async {
        if moves.count >= minimum { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            moveWaiter = (minimum, cont)
        }
    }

    func waitForStops(minimum: Int) async {
        if stoppedTokens.count >= minimum { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stopWaiter = (minimum, cont)
        }
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
        playback.stallTimeout = .milliseconds(30)
        playback.watchdogInterval = .milliseconds(10)
        playback.maxFailedAttempts = 1
        playback.maxReconnectAttempts = 1

        var stalledDuringPause = false
        var pauseWindowFinished = false
        let (doneStream, doneCont) = AsyncStream<Void>.makeStream()
        let (tickStream, tickCont) = AsyncStream<Void>.makeStream()

        playback.onWatchdogTick = {
            tickCont.yield()
        }
        playback.onFailure = { _ in
            tickCont.finish()
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
            var pausedTicks = 0
            for await _ in tickStream {
                pausedTicks += 1
                if pausedTicks >= 5 {
                    break
                }
            }
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
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        defer {
            controller.closePanel()
            controller.consumeMJPEGOverride = nil
            controller.bridgeShutdownOverride = nil
        }

        // One instance for the store and for anything reading the same domain: a second
        // `UserDefaults(suiteName:)` reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()

        let cam = Self.makeCameraDevice(id: "cam-reload-1")
        let provider = MockCameraLifecycleProvider(
            pauseFirstResolve: true,
            streamToReturn: .demo(deviceId: cam.id)
        )
        let store = HomeStore(provider: provider, defaults: defaults)
        store.devices = [cam]
        controller.install(with: store)
        controller.activeDeviceId = cam.id

        controller.reloadStream()
        await provider.waitForFirstResolveEntered()

        controller.reloadStream()
        await Task.yield()
        await Task.yield()
        #expect(await provider.resolveCallOrder == [1])

        await provider.releaseFirstResolve()
        await provider.waitForSecondResolve()
        #expect(await provider.resolveCallOrder == [1, -1, 2])
    }

    @Test("MJPEG retry exhaustion after flapping frames schedules stopCameraStream")
    func mjpegFlappingExhaustionSchedulesStopStream() async throws {
        let controller = CameraLivePanelController()
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

        controller.mjpegRetryBackoff = .milliseconds(5)
        controller.mjpegStableWindow = .seconds(5)
        controller.mjpegStallTimeout = .seconds(5)
        controller.mjpegWatchdogInterval = .seconds(1)
        controller.mjpegMaxAttempts = 3

        let mjpegURL = try #require(URL(string: "http://192.0.2.10:43123/api/stream.mjpeg?src=cam_mjpeg_1"))
        let cam = Self.makeCameraDevice(id: "cam-mjpeg-1")
        let provider = MockCameraLifecycleProvider(pauseFirstResolve: false, streamToReturn: .mjpeg(mjpegURL))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        store.devices = [cam]
        controller.install(with: store)
        controller.activeDeviceId = cam.id

        var mjpegConnects = 0
        controller.consumeMJPEGOverride = { _, onFrame in
            mjpegConnects += 1
            onFrame(NSImage(size: NSSize(width: 2, height: 2)))
        }

        controller.reloadStream()
        await provider.waitForStop(deviceID: cam.id)

        #expect(mjpegConnects == 3)
        #expect(await provider.stoppedDeviceIDs.contains(cam.id))
        #expect(controller.errorMessage != nil)
    }

    @Test("Held PTZ drag across the center deadzone pauses motor session and resumes in opposite direction")
    func ptzHeldDragCrossesDeadzoneAndResumesOppositeDirection() async throws {
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        let ptzClient = MockTerminationPTZClient()
        let capability = CameraPTZCapability(
            model: "chuangmi.camera.061a01",
            vendor: "cs2",
            mode: .continuous,
            confidence: .verified
        )
        let binding = CameraPTZBinding(capability: capability, streamName: "cam_raw_ptz_cross")
        controller.configurePTZPreview(
            deviceId: "cam-ptz-cross",
            binding: binding,
            stream: .demo(deviceId: "cam-ptz-cross"),
            notice: nil,
            ready: true,
            client: ptzClient,
            hasFrame: true
        )
        defer {
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        controller.ptzDragBegan(at: .init(x: 100, y: 100))
        let heldDragID = try #require(controller.ptzDragID)

        controller.ptzDragMoved(to: .init(x: 130, y: 100))
        await ptzClient.waitForMoves(minimum: 1)
        let firstToken = try #require(await ptzClient.begunTokens.first)
        #expect(await ptzClient.moves.map(\.direction) == [.right])

        controller.ptzDragMoved(to: .init(x: 100, y: 100))
        await ptzClient.waitForStops(minimum: 1)
        #expect(await ptzClient.stoppedTokens == [firstToken])
        #expect(controller.ptzDragID == heldDragID)

        controller.ptzDragMoved(to: .init(x: 70, y: 100))
        await ptzClient.waitForMoves(minimum: 2)
        let begun = await ptzClient.begunTokens
        #expect(begun.count == 2)
        #expect(await ptzClient.moves.map(\.direction) == [.right, .left])

        controller.ptzDragEnded()
        await ptzClient.waitForStops(minimum: 2)
        #expect(await ptzClient.stoppedTokens == begun)
        #expect(controller.ptzDragID == nil)
    }

    @Test("prepareForTermination defers app exit until PTZ stop, stream release, and bridge shutdown complete")
    func prepareForTerminationCleansUpPTZStreamAndBridge() async throws {
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        let oldTimeout = controller.terminationTimeout
        defer {
            controller.terminationTimeout = oldTimeout
            controller.bridgeShutdownOverride = nil
            controller.hasLiveOwnedProcessOverride = nil
            controller.closePanel()
        }
        controller.hasLiveOwnedProcessOverride = { false }

        let defaults = InMemoryUserDefaults()

        let cam = Self.makeCameraDevice(id: "cam-term-1")
        let provider = MockCameraLifecycleProvider(
            pauseFirstResolve: false,
            streamToReturn: .demo(deviceId: cam.id)
        )
        let store = HomeStore(provider: provider, defaults: defaults)
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
            var count = 0
            func mark() { count += 1 }
            func currentCount() -> Int { count }
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
        #expect(await bridgeShutdown.currentCount() == 1)
        #expect(controller.activeDeviceId == nil)

        controller.bridgeShutdownOverride = nil
        await controller.terminationTask?.value
        #expect(controller.prepareForTermination() == .terminateNow)

        let hungCam = Self.makeCameraDevice(id: "cam-term-hung")
        let hungProvider = MockCameraLifecycleProvider(
            pauseFirstResolve: false,
            hangStop: true,
            streamToReturn: .demo(deviceId: hungCam.id)
        )
        let hungStore = HomeStore(provider: hungProvider, defaults: defaults)
        hungStore.devices = [hungCam]
        controller.install(with: hungStore)
        controller.activeDeviceId = hungCam.id
        let timeoutGate = TerminationSleepGate()
        controller.terminationSleep = { _ in await timeoutGate.park() }
        controller.bridgeShutdownOverride = {
            await bridgeShutdown.mark()
        }

        var completionCount = 0
        let (hungStream, hungCont) = AsyncStream<Void>.makeStream()
        let hungReply = controller.prepareForTermination {
            completionCount += 1
            hungCont.yield()
            hungCont.finish()
        }
        #expect(hungReply == .terminateLater)
        #expect(await hungProvider.waitUntilStopHung(), "the hung stop never parked")
        await timeoutGate.release()
        for await _ in hungStream { break }

        #expect(completionCount == 1)
        #expect(await bridgeShutdown.currentCount() == 2)
        await hungProvider.releaseHungStop()
        await controller.terminationTask?.value
        #expect(completionCount == 1)
    }

    @Test("MJPEG wait copy is not the P2P sentence")
    func mjpegWaitCopyDiffersFromP2P() {
        for language in [AppLanguage.zhHans, .zhHant, .en] {
            L10n.$overrideLanguage.withValue(language) {
                #expect(CameraStreamWaitCopy.mjpeg != CameraStreamWaitCopy.encryptedP2P)
            }
        }
    }

    @MainActor
    @Test("Listen-only camera audio starts muted, detects HLS and go2rtc audio capability, requests audio on opt-in, and resets on close")
    func listenOnlyAudioLifecycleForHLSAndGo2RTC() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "CameraAudioLifecycle-\(UUID().uuidString)")!
        let cam = Self.makeCameraDevice(id: "cam-audio-1")

        // 1. HLS stream: starts muted, hides capability until tracks report, exposes audio or videoOnly accurately
        let hlsURL = try #require(URL(string: "http://192.0.2.10:43123/live.m3u8"))
        let hlsProvider = MockCameraLifecycleProvider(streamToReturn: .hls(hlsURL))
        let hlsStore = HomeStore(provider: hlsProvider, defaults: defaults)
        hlsStore.devices = [cam]
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        controller.frameDefaults = defaults
        controller.install(with: hlsStore)
        defer { controller.closePanel() }

        controller.present(device: cam)
        for _ in 0..<200 where controller.streamSource == nil { await Task.yield() }
        #expect(controller.isMuted == true)
        #expect(await hlsProvider.resolveAudioFlags == [false])
        #expect(controller.currentAudioStatus == .hidden)

        controller.updateActiveStreamAudioAvailable(true)
        #expect(controller.currentAudioStatus == .audio(isMuted: true))
        controller.toggleMute()
        #expect(controller.isMuted == false)
        #expect(controller.currentAudioStatus == .audio(isMuted: false))

        controller.updateActiveStreamAudioAvailable(false)
        #expect(controller.currentAudioStatus == .videoOnly)

        controller.closePanel()
        #expect(controller.isMuted == true)
        #expect(controller.detectedAudioTrack == nil)
        await hlsProvider.waitForStop(deviceID: cam.id)

        // 2. go2rtc fMP4 muted preview (&audio=0) -> opt-in listen-only re-resolves with audioEnabled: true
        let mutedMP4 = try #require(URL(string: "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4&audio=0"))
        let listenMP4 = try #require(URL(string: "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4=all"))
        let go2rtcProvider = MockCameraLifecycleProvider(streamToReturn: .liveMP4(mutedMP4, mjpegFallback: nil, ptz: nil))
        let go2rtcStore = HomeStore(provider: go2rtcProvider, defaults: defaults)
        go2rtcStore.devices = [cam]
        controller.install(with: go2rtcStore)

        controller.present(device: cam)
        for _ in 0..<200 where controller.streamSource == nil { await Task.yield() }
        #expect(controller.isMuted == true)
        #expect(controller.currentAudioStatus == .audio(isMuted: true))
        #expect(await go2rtcProvider.resolveAudioFlags == [false])

        await go2rtcProvider.setStreamToReturn(.liveMP4(listenMP4, mjpegFallback: nil, ptz: nil))
        controller.toggleMute()
        let listenSource = CameraStreamSource.liveMP4(listenMP4, mjpegFallback: nil, ptz: nil)
        try await awaitState { controller.streamSource == listenSource }
        #expect(controller.isMuted == false)
        #expect(await go2rtcProvider.resolveAudioFlags == [false, true])

        controller.updateActiveStreamAudioAvailable(true)
        #expect(controller.currentAudioStatus == .audio(isMuted: false))

        // 2b. If listen-only renegotiation fails on a video-only Xiaomi camera, restore audio=0 preview
        let mutedSource = CameraStreamSource.liveMP4(mutedMP4, mjpegFallback: nil, ptz: nil)
        await go2rtcProvider.setStreamToReturn(mutedSource)
        controller.closePanel()
        controller.present(device: cam)
        try await awaitState { controller.streamSource == mutedSource }
        struct MissingAudioError: Error {}
        await go2rtcProvider.setResolveErrorOnAudioEnabled(MissingAudioError())
        controller.toggleMute()
        try await awaitState { controller.currentAudioStatus == .videoOnly && controller.isMuted && controller.streamSource == mutedSource }
        #expect(controller.errorMessage == nil)
        await go2rtcProvider.setResolveErrorOnAudioEnabled(nil)

        controller.closePanel()
        #expect(controller.isMuted == true)

        // 3. Custom URL containing audio=0 must not re-negotiate or expose fake opt-in when video-only
        let customDefaults = UserDefaults(suiteName: "CameraCustomAudio-\(UUID().uuidString)")!
        let customProvider = MockCameraLifecycleProvider(streamToReturn: .demo(deviceId: cam.id))
        let customStore = HomeStore(provider: customProvider, defaults: customDefaults)
        customStore.devices = [cam]
        customStore.setCameraCustomStreamURL("http://192.168.1.10:1984/api/stream.mp4?src=cam&audio=0", for: cam.id)
        controller.install(with: customStore)
        controller.present(device: cam)
        for _ in 0..<200 where controller.streamSource == nil { await Task.yield() }
        #expect(controller.currentAudioStatus == .hidden)
        controller.updateActiveStreamAudioAvailable(false)
        #expect(controller.currentAudioStatus == .videoOnly)
        controller.toggleMute()
        #expect(await customProvider.resolveAudioFlags.isEmpty)
        controller.closePanel()
    }

    @Test("Prohibited HLS and MJPEG URLs are blocked before mounting playback or opening a session")
    func blocksProhibitedCameraStreamURLsBeforePlayback() async throws {
        let prohibitedHLS = try #require(URL(string: "http://169.254.169.254/latest/meta-data/master.m3u8"))
        let prohibitedNAT64 = try #require(URL(string: "http://[64:ff9b::127.0.0.1]:8123/api/stream.mjpeg"))
        let prohibitedLoopback = try #require(URL(string: "http://127.0.0.1:8080/live.m3u8"))
        #expect(!HAPlaintextConsent.allowsImmediatePlaybackURL(prohibitedHLS))
        #expect(!HAPlaintextConsent.allowsImmediatePlaybackURL(prohibitedNAT64))
        #expect(!HAPlaintextConsent.allowsImmediatePlaybackURL(prohibitedLoopback, allowsLoopback: false))
        #expect(HAPlaintextConsent.allowsImmediatePlaybackURL(prohibitedLoopback, allowsLoopback: true))
        #expect(!HAPlaintextConsent.allowsImmediatePlaybackURL(prohibitedHLS, allowsLoopback: true))

        for source in [CameraStreamSource.hls(prohibitedHLS), .hls(prohibitedLoopback), .mjpeg(prohibitedNAT64)] {
            let controller = CameraLivePanelController()
            controller.presentsActively = false
            defer { controller.closePanel() }
            let cam = Self.makeCameraDevice(id: "cam-blocked-\(UUID().uuidString)")
            let provider = MockCameraLifecycleProvider(streamToReturn: source)
            let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
            store.devices = [cam]
            controller.install(with: store)
            controller.activeDeviceId = cam.id

            controller.reloadStream()
            try await awaitState { !controller.isLoadingStream && controller.errorMessage != nil }
            #expect(controller.streamSource == nil)
        }
    }

    @Test("Custom loopback Basic Auth MJPEG URL is allowed when configured on the camera device")
    func allowsConfiguredCustomLoopbackBasicAuthMJPEG() async throws {
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        defer {
            controller.consumeMJPEGOverride = nil
            controller.closePanel()
        }
        let cam = Self.makeCameraDevice(id: "cam-loopback-basic-\(UUID().uuidString)")
        let provider = MockCameraLifecycleProvider(streamToReturn: .demo(deviceId: cam.id))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        store.devices = [cam]
        let customRaw = "http://user:pass@127.0.0.1:8080/mjpeg"
        let customURL = try #require(URL(string: customRaw))
        store.setCameraCustomStreamURL(customRaw, for: cam.id)
        controller.install(with: store)
        controller.activeDeviceId = cam.id

        let (connectedStream, connectedCont) = AsyncStream<URL>.makeStream()
        controller.consumeMJPEGOverride = { url, _ in
            connectedCont.yield(url)
            connectedCont.finish()
        }

        controller.reloadStream()
        var receivedURL: URL?
        for await url in connectedStream {
            receivedURL = url
            break
        }
        #expect(receivedURL == customURL)
        #expect(controller.streamSource == .mjpeg(customURL))
        #expect(controller.streamAllowsLoopback == true)
    }

    @Test("Non-managed HLS routes through CameraHLSLoopbackRelay, enforces token/origin/DNS/redirect/Content-Range boundaries, and registers helper port", .timeLimit(.minutes(1)))
    func hardenedHLSLoopbackRelayEnforcesNetworkBoundary() async throws {
        let originURL = try #require(URL(string: "http://192.168.1.10:8123/api/hls/tok/master_playlist.m3u8"))
        let loopbackURL = try #require(URL(string: "http://127.0.0.1:43123/api/stream.m3u8?src=cam"))

        // 1. Factory routes remote/HA HLS through authenticated loopback relay, leaving explicit loopback direct.
        let hardened = try #require(CameraHLSPlayerFactory.makePlayerItem(url: originURL, allowsLoopback: false))
        let hardenedRelay = try #require(hardened.relay)
        let hardenedAsset = try #require(hardened.item.asset as? AVURLAsset)
        #expect(hardenedAsset.url == hardenedRelay.entryURL)
        #expect(hardenedAsset.url.scheme == "http")
        #expect(hardenedAsset.url.host == "127.0.0.1")
        #expect(hardenedAsset.url.port == Int(hardenedRelay.port))
        #expect(hardenedRelay.token.count == HAHLSPlaylistPolicy.tokenHexLength)
        #expect(HAPlaintextConsent.isInternalLoopbackPort(hardenedRelay.port))
        #expect(!HAPlaintextConsent.allowsImmediatePlaybackURL(hardenedRelay.entryURL, allowsLoopback: true))
        hardenedRelay.stop()
        #expect(!HAPlaintextConsent.isInternalLoopbackPort(hardenedRelay.port))

        let managed = try #require(CameraHLSPlayerFactory.makePlayerItem(url: loopbackURL, allowsLoopback: true))
        let managedAsset = try #require(managed.item.asset as? AVURLAsset)
        #expect(managedAsset.url == loopbackURL)
        #expect(managed.relay == nil)

        // 2. End-to-end loopback relay verification over real local TCP + stubbed upstream URLProtocol.
        let requestedPaths = LockedHLSTestBox([String]())
        let forwardedAuthHeaders = LockedHLSTestBox([String]())
        let playlistRangeHeaders = LockedHLSTestBox([String]())
        let validatedURLs = LockedHLSTestBox([URL]())
        let blockedSecretFetched = LockedHLSTestBox(false)
        let shouldFailDNS = LockedHLSTestBox(false)

        StubHLSURLProtocol.setHandler { request in
            let url = try #require(request.url)
            requestedPaths.withValue { $0.append("\(request.httpMethod ?? "GET") \(url.path)") }
            if let auth = request.value(forHTTPHeaderField: "Authorization") {
                forwardedAuthHeaders.withValue { $0.append(auth) }
            }
            if let cookie = request.value(forHTTPHeaderField: "Cookie") {
                forwardedAuthHeaders.withValue { $0.append("Cookie:\(cookie)") }
            }
            if url.host == "127.0.0.1" || url.host == "169.254.169.254" {
                blockedSecretFetched.withValue { $0 = true }
                return .response(statusCode: 200, url: url, headers: [:], body: Data("SECRET".utf8))
            }
            switch url.path {
            case "/api/hls/tok/master_playlist.m3u8":
                if let range = request.value(forHTTPHeaderField: "Range") {
                    playlistRangeHeaders.withValue { $0.append(range) }
                }
                let body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nplaylist.m3u8\n"
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "application/x-mpegurl"],
                    body: Data(body.utf8)
                )
            case "/api/hls/tok/playlist.m3u8":
                let body = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=key.bin\n#EXTINF:2.0,\nseg0.ts\n"
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                    body: Data(body.utf8)
                )
            case "/api/hls/tok/full_206_playlist.m3u8":
                let body = Data("#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n".utf8)
                return .response(
                    statusCode: 206,
                    url: url,
                    headers: [
                        "Content-Type": "application/vnd.apple.mpegurl",
                        "Content-Range": "bytes 0-\(body.count - 1)/\(body.count)",
                    ],
                    body: body
                )
            case "/api/hls/tok/partial_206_playlist.m3u8":
                let body = Data("#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n".utf8)
                return .response(
                    statusCode: 206,
                    url: url,
                    headers: [
                        "Content-Type": "application/vnd.apple.mpegurl",
                        "Content-Range": "bytes 1-\(body.count)/\(body.count + 1)",
                    ],
                    body: body
                )
            case "/api/hls/tok/key.bin":
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "application/octet-stream"],
                    body: Data(repeating: 0xAB, count: 16)
                )
            case "/api/hls/tok/seg0.ts":
                let full = Data([0x47, 0x40, 0x11, 0x10, 0x01, 0x02, 0x03, 0x04])
                if request.httpMethod == "HEAD" {
                    return .response(
                        statusCode: 200,
                        url: url,
                        headers: [
                            "Content-Type": "video/mp2t",
                            "Accept-Ranges": "bytes",
                            "Content-Length": "\(full.count)",
                        ],
                        body: Data()
                    )
                }
                if request.value(forHTTPHeaderField: "Range") == "bytes=2-5" {
                    return .response(
                        statusCode: 206,
                        url: url,
                        headers: [
                            "Content-Type": "video/mp2t",
                            "Content-Range": "bytes 2-5/8",
                        ],
                        body: full.subdata(in: 2..<6)
                    )
                }
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "video/mp2t", "Accept-Ranges": "bytes"],
                    body: full
                )
            case "/api/hls/tok/overflow_range.ts":
                return .response(
                    statusCode: 206,
                    url: url,
                    headers: [
                        "Content-Type": "video/mp2t",
                        "Content-Range": "bytes 0-9223372036854775807/*",
                    ],
                    body: Data([0x47, 0x40, 0x11, 0x10])
                )
            case "/api/hls/tok/evil_playlist.m3u8":
                let body = "#EXTM3U\n#EXTINF:2.0,\rhttp://169.254.169.254/latest/meta-data/\n"
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                    body: Data(body.utf8)
                )
            case "/api/hls/tok/redirect_to_loopback.ts":
                let target = try #require(URL(string: "http://127.0.0.1:8080/admin"))
                return .redirect(from: url, to: target)
            case "/api/hls/tok/redirect_same_origin.ts":
                let target = try #require(URL(string: "http://192.168.1.10:8123/api/hls/tok/seg0.ts"))
                return .redirect(from: url, to: target)
            default:
                return .response(statusCode: 404, url: url, headers: [:], body: Data())
            }
        }
        defer { StubHLSURLProtocol.setHandler(nil) }

        let upstreamCfg = URLSessionConfiguration.ephemeral
        upstreamCfg.protocolClasses = [StubHLSURLProtocol.self]

        let createdRelay = CameraHLSLoopbackRelay(
            originURL: originURL,
            sessionConfiguration: upstreamCfg,
            validateAddress: { url in
                validatedURLs.withValue { $0.append(url) }
                if shouldFailDNS.value {
                    throw HAEndpointResolutionError.prohibitedAddress
                }
            }
        )
        let relay = try #require(createdRelay)
        defer { relay.stop() }

        let clientCfg = URLSessionConfiguration.ephemeral
        clientCfg.connectionProxyDictionary = [:]
        let client = URLSession(configuration: clientCfg)
        defer { client.invalidateAndCancel() }

        let relayPrefix = "http://127.0.0.1:\(relay.port)/\(relay.token)"

        // Wrong token and non-GET/HEAD methods are rejected with zero upstream calls.
        let wrongTokenURL = try #require(URL(string: "http://127.0.0.1:\(relay.port)/\(String(repeating: "0", count: 32))/api/hls/tok/master_playlist.m3u8"))
        let (_, wrongTokenResp) = try await client.data(from: wrongTokenURL)
        #expect((wrongTokenResp as? HTTPURLResponse)?.statusCode == 403)
        #expect(requestedPaths.value.isEmpty)

        var postReq = URLRequest(url: relay.entryURL)
        postReq.httpMethod = "POST"
        let (_, postResp) = try await client.data(for: postReq)
        #expect((postResp as? HTTPURLResponse)?.statusCode == 405)
        #expect(requestedPaths.value.isEmpty)

        // Master playlist strips client Range + Authorization/Cookie headers and rewrites URIs onto the loopback relay.
        var masterReq = URLRequest(url: relay.entryURL)
        masterReq.setValue("bytes=0-10", forHTTPHeaderField: "Range")
        masterReq.setValue("Bearer must-not-leak", forHTTPHeaderField: "Authorization")
        masterReq.setValue("session=must-not-leak", forHTTPHeaderField: "Cookie")
        let (masterData, masterResp) = try await client.data(for: masterReq)
        let masterHTTP = try #require(masterResp as? HTTPURLResponse)
        #expect(masterHTTP.statusCode == 200)
        #expect(masterHTTP.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(playlistRangeHeaders.value.isEmpty)
        #expect(forwardedAuthHeaders.value.isEmpty)
        let masterText = String(decoding: masterData, as: UTF8.self)
        #expect(masterText.contains("\(relayPrefix)/api/hls/tok/playlist.m3u8"))

        // Media playlist, key, segment (HEAD, 200, and 206 byte-range) all relay cleanly.
        let mediaURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/playlist.m3u8"))
        let (mediaData, mediaResp) = try await client.data(from: mediaURL)
        #expect((mediaResp as? HTTPURLResponse)?.statusCode == 200)
        let mediaText = String(decoding: mediaData, as: UTF8.self)
        #expect(mediaText.contains("URI=\"\(relayPrefix)/api/hls/tok/key.bin\""))
        #expect(mediaText.contains("\n\(relayPrefix)/api/hls/tok/seg0.ts\n"))

        let keyURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/key.bin"))
        let (keyData, keyResp) = try await client.data(from: keyURL)
        #expect((keyResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(keyData == Data(repeating: 0xAB, count: 16))

        let segURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/seg0.ts"))
        var headReq = URLRequest(url: segURL)
        headReq.httpMethod = "HEAD"
        let (headData, headResp) = try await client.data(for: headReq)
        let headHTTP = try #require(headResp as? HTTPURLResponse)
        #expect(headHTTP.statusCode == 200)
        #expect(headHTTP.value(forHTTPHeaderField: "Content-Length") == "8")
        #expect(headData.isEmpty)

        var rangeReq = URLRequest(url: segURL)
        rangeReq.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (rangeData, rangeResp) = try await client.data(for: rangeReq)
        let rangeHTTP = try #require(rangeResp as? HTTPURLResponse)
        #expect(rangeHTTP.statusCode == 206)
        #expect(rangeHTTP.value(forHTTPHeaderField: "Content-Range") == "bytes 2-5/8")
        #expect(rangeHTTP.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
        #expect(rangeData == Data([0x11, 0x10, 0x01, 0x02]))

        // Full-from-zero 206 playlist is rewritten & returned as 200 OK; non-zero partial 206 playlist is rejected.
        let full206URL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/full_206_playlist.m3u8"))
        let (full206Data, full206Resp) = try await client.data(from: full206URL)
        let full206HTTP = try #require(full206Resp as? HTTPURLResponse)
        #expect(full206HTTP.statusCode == 200)
        #expect(full206HTTP.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(full206HTTP.value(forHTTPHeaderField: "Content-Length") == "\(full206Data.count)")
        #expect(String(decoding: full206Data, as: UTF8.self).contains("\(relayPrefix)/api/hls/tok/seg0.ts"))

        let partial206URL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/partial_206_playlist.m3u8"))
        let (_, partial206Resp) = try await client.data(from: partial206URL)
        #expect((partial206Resp as? HTTPURLResponse)?.statusCode == 502)

        // Regression [P1-2]: hostile Int64.max Content-Range from upstream is rejected cleanly with 502 (no crash).
        var overflowReq = URLRequest(url: try #require(URL(string: "\(relayPrefix)/api/hls/tok/overflow_range.ts")))
        overflowReq.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (_, overflowResp) = try await client.data(for: overflowReq)
        #expect((overflowResp as? HTTPURLResponse)?.statusCode == 502)

        // Bare-CR smuggled cross-origin URI inside playlist fails closed.
        let evilPlaylistURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/evil_playlist.m3u8"))
        let (_, evilResp) = try await client.data(from: evilPlaylistURL)
        #expect((evilResp as? HTTPURLResponse)?.statusCode == 502)

        // Validated same-origin 302 redirect is followed cleanly, while loopback 302 redirect is blocked.
        let sameOriginRedirectURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/redirect_same_origin.ts"))
        let (redirectedSeg, sameOriginResp) = try await client.data(from: sameOriginRedirectURL)
        #expect((sameOriginResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(redirectedSeg == Data([0x47, 0x40, 0x11, 0x10, 0x01, 0x02, 0x03, 0x04]))

        let redirectLoopbackURL = try #require(URL(string: "\(relayPrefix)/api/hls/tok/redirect_to_loopback.ts"))
        let (_, blockedRedirectResp) = try await client.data(from: redirectLoopbackURL)
        #expect((blockedRedirectResp as? HTTPURLResponse)?.statusCode == 502)
        #expect(blockedSecretFetched.value == false)

        // Fresh DNS rebinding failure on a sub-request blocks with 403 before making the HTTP call.
        shouldFailDNS.withValue { $0 = true }
        let countBeforeRebind = requestedPaths.value.count
        let (_, rebindResp) = try await client.data(from: segURL)
        #expect((rebindResp as? HTTPURLResponse)?.statusCode == 403)
        #expect(requestedPaths.value.count == countBeforeRebind)
        #expect(validatedURLs.value.count == 12)
    }

    @Test("Real AVPlayer enters readyToPlay on relayed MPEG-TS HLS stream and blocks cross-origin segment URIs with zero forbidden requests", .timeLimit(.minutes(1)))
    func realAVPlayerPlaysRelayedMPEGTSAndBlocksCrossOriginSegments() async throws {
        // Minimal valid 2068-byte MPEG-TS H.264 segment (PAT + PMT + 2 baseline 64x64 frames, 1.0s).
        let tsBase64 =
            "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "/0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgIAFIQAH2GEAAAABCfAAAAAB"
            + "Z0LAHtkEJsBEAAADAAQAAAMAEDxYuSAAAAABaMuDyyAAAAEGBf//adxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMy"
            + "MjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVv"
            + "bGFHAQARbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4"
            + "MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21l"
            + "PTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLEcBABIxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNl"
            + "dD0tMiB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxh"
            + "Y2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MiBrZXlp"
            + "bnRfRwEAMxUA//////////////////////////9taW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFk"
            + "PTIgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0x"
            + "LjQwIGFxPTE6MS4wMACAAAABZYiEBTyYoAA/vycnJ1111111111114BHQBERAELwJQABwQAA/wH/AAH8gBRIEgEGRkZtcGVnCVNl"
            + "cnZpY2UwMXd8Q8r/////////////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "/////0dAABEAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////R1AAEQACsBIAAcEAAOEA8AAb4QDwABW9TVb/////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "//////9HQQA0mRAAANLwfgD/////////////////////////////////////////////////////////////////////////////"
            + "////////////////////////////////////////////////////////////////////////////////////////////////////"
            + "/////////////////wAAAeAAAICABSEACzfxAAAAAQnwAAAAAUGaOAl4Rg=="
        let validTSSegment = try #require(Data(base64Encoded: tsBase64))
        #expect(validTSSegment.count == 2068)
        #expect(validTSSegment.first == 0x47)

        let forbiddenHits = LockedHLSTestBox(0)
        let forbiddenServer = try LocalHLSStubHTTPServer { _ in
            forbiddenHits.withValue { $0 += 1 }
            return .init(statusCode: 200, reason: "OK", contentType: "video/mp2t", body: validTSSegment)
        }
        defer { forbiddenServer.stop() }
        let forbiddenPort = forbiddenServer.port

        let servedPaths = LockedHLSTestBox([String]())
        let originServer = try LocalHLSStubHTTPServer { request in
            servedPaths.withValue { $0.append(request.path) }
            switch request.path {
            case "/api/hls/tok/master_playlist.m3u8":
                let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nplaylist.m3u8\n"
                return .init(statusCode: 200, reason: "OK", contentType: "application/vnd.apple.mpegurl", body: Data(playlist.utf8))
            case "/api/hls/tok/playlist.m3u8":
                let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
                return .init(statusCode: 200, reason: "OK", contentType: "application/vnd.apple.mpegurl", body: Data(playlist.utf8))
            case "/api/hls/tok/seg0.ts":
                return .init(statusCode: 200, reason: "OK", contentType: "video/mp2t", body: validTSSegment, acceptRanges: true)
            case "/api/hls/tok/evil_playlist.m3u8":
                let evil = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.0,\nhttp://127.0.0.1:\(forbiddenPort)/secret.ts\n#EXT-X-ENDLIST\n"
                return .init(statusCode: 200, reason: "OK", contentType: "application/vnd.apple.mpegurl", body: Data(evil.utf8))
            default:
                return .init(statusCode: 404, reason: "Not Found", contentType: "text/plain", body: Data())
            }
        }
        defer { originServer.stop() }

        // 1. Valid same-origin HLS stream played by real AVPlayer through CameraHLSLoopbackRelay reaches .readyToPlay (no -12881).
        let masterURL = try #require(URL(string: "http://127.0.0.1:\(originServer.port)/api/hls/tok/master_playlist.m3u8"))
        let createdBuilt = CameraHLSPlayerFactory.makeRelayedPlayerItem(
            originURL: masterURL,
            validateAddress: { _ in }
        )
        let built = try #require(createdBuilt)
        defer { built.relay.stop() }

        let player = AVPlayer(playerItem: built.item)
        player.isMuted = true
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let status = await Self.waitForAVPlayerItemStatus(built.item)
        #expect(status == .readyToPlay, "expected AVPlayerItem .readyToPlay without CoreMedia -12881, got error: \(String(describing: built.item.error))")
        #expect(built.item.error == nil)
        let fetched = servedPaths.value
        #expect(fetched.contains("/api/hls/tok/master_playlist.m3u8"))
        #expect(fetched.contains("/api/hls/tok/playlist.m3u8"))
        #expect(fetched.contains("/api/hls/tok/seg0.ts"))

        // 2. Playlist with cross-origin/prohibited segment URI fails closed in real AVPlayer with zero requests to forbidden server.
        let evilURL = try #require(URL(string: "http://127.0.0.1:\(originServer.port)/api/hls/tok/evil_playlist.m3u8"))
        let createdEvilBuilt = CameraHLSPlayerFactory.makeRelayedPlayerItem(
            originURL: evilURL,
            validateAddress: { _ in }
        )
        let evilBuilt = try #require(createdEvilBuilt)
        defer { evilBuilt.relay.stop() }

        let evilPlayer = AVPlayer(playerItem: evilBuilt.item)
        evilPlayer.isMuted = true
        defer {
            evilPlayer.pause()
            evilPlayer.replaceCurrentItem(with: nil)
        }
        let evilStatus = await Self.waitForAVPlayerItemStatus(evilBuilt.item)
        #expect(evilStatus == .failed)
        #expect(forbiddenHits.value == 0)
    }

    @Test("CameraHLSLoopbackRelay enforces an overall header deadline against slow-trickle clients and stays safe across concurrent stop", .timeLimit(.minutes(1)))
    func hlsLoopbackRelayEnforcesSlowlorisHeaderDeadlineAndConcurrentStopSafety() async throws {
        // 1. Unit assertions on remainingReceiveTimeval helper (never emits 0/0 infinite timeout).
        let base = ContinuousClock.now
        let fiveSec = try #require(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base + .seconds(5), now: base))
        #expect(fiveSec.tv_sec == 5 && fiveSec.tv_usec == 0)

        let subSec = try #require(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base + .milliseconds(250), now: base))
        #expect(subSec.tv_sec == 0 && subSec.tv_usec == 250_000)

        let tiny = try #require(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base + .nanoseconds(1), now: base))
        #expect(tiny.tv_sec == 0 && tiny.tv_usec == 1)

        let carry = try #require(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base + .nanoseconds(999_999_999), now: base))
        #expect(carry.tv_sec == 1 && carry.tv_usec == 0)

        #expect(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base, now: base) == nil)
        #expect(CameraHLSLoopbackRelay.remainingReceiveTimeval(until: base - .milliseconds(1), now: base) == nil)

        // 2. Slowloris trickle (1 byte every 50ms < 250ms budget) is aborted once overall header deadline expires.
        let originURL = try #require(URL(string: "http://192.168.1.10:8123/api/hls/tok/master_playlist.m3u8"))
        let upstreamHits = LockedHLSTestBox(0)
        StubHLSURLProtocol.setHandler { request in
            let url = try #require(request.url)
            upstreamHits.withValue { $0 += 1 }
            return .response(
                statusCode: 200,
                url: url,
                headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                body: Data("#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n".utf8)
            )
        }
        defer { StubHLSURLProtocol.setHandler(nil) }

        let upstreamCfg = URLSessionConfiguration.ephemeral
        upstreamCfg.protocolClasses = [StubHLSURLProtocol.self]
        let createdRelay = CameraHLSLoopbackRelay(
            originURL: originURL,
            sessionConfiguration: upstreamCfg,
            requestHeaderTimeout: .milliseconds(250),
            validateAddress: { _ in }
        )
        let relay = try #require(createdRelay)
        defer { relay.stop() }

        let port = relay.port
        let trickleResult: (closedByPeer: Bool, bytesSent: Int, responseBytes: Int) = await Task.detached {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return (false, 0, -1) }
            defer { Darwin.close(fd) }
            var one: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return (false, 0, -1) }

            var sent = 0
            var received = 0
            var closed = false
            var byte: UInt8 = 0x58 // 'X'
            var readBuf = [UInt8](repeating: 0, count: 64)
            for _ in 0..<80 {
                let n = Darwin.write(fd, &byte, 1)
                if n <= 0 {
                    closed = true
                    break
                }
                sent += 1
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 50)
                if ready > 0 {
                    let r = Darwin.read(fd, &readBuf, readBuf.count)
                    if r <= 0 {
                        closed = true
                        break
                    }
                    received += r
                }
            }
            return (closed, sent, received)
        }.value

        #expect(trickleResult.closedByPeer == true)
        #expect(trickleResult.bytesSent < 60)
        #expect(trickleResult.responseBytes == 0)
        #expect(upstreamHits.value == 0)

        // Relay remains healthy after aborting the slow client.
        let clientCfg = URLSessionConfiguration.ephemeral
        clientCfg.connectionProxyDictionary = [:]
        let client = URLSession(configuration: clientCfg)
        defer { client.invalidateAndCancel() }
        let (_, okResp) = try await client.data(from: relay.entryURL)
        #expect((okResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(upstreamHits.value == 1)

        // 3. Concurrent in-flight requests raced against stop() never crash on URLSession invalidation or socket close.
        for _ in 0..<8 {
            let created = CameraHLSLoopbackRelay(
                originURL: originURL,
                sessionConfiguration: upstreamCfg,
                validateAddress: { _ in await Task.yield() }
            )
            let racedRelay = try #require(created)
            let entry = racedRelay.entryURL
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        _ = try? await client.data(from: entry)
                    }
                }
                group.addTask {
                    await Task.yield()
                    racedRelay.stop()
                }
                await group.waitForAll()
            }
            racedRelay.stop()
            #expect(!HAPlaintextConsent.isInternalLoopbackPort(racedRelay.port))
        }
    }

    private static func waitForAVPlayerItemStatus(
        _ item: AVPlayerItem,
        timeout: Duration = .seconds(15)
    ) async -> AVPlayerItem.Status {
        if item.status != .unknown {
            return item.status
        }
        return await withCheckedContinuation { continuation in
            let state = LockedHLSTestBox<(resumed: Bool, observation: NSKeyValueObservation?, timer: Task<Void, Never>?)>(
                (false, nil, nil)
            )
            let finish: @Sendable (AVPlayerItem.Status) -> Void = { resolved in
                let cleanup: (NSKeyValueObservation?, Task<Void, Never>?)? = state.withValue { current in
                    guard !current.resumed else { return nil }
                    current.resumed = true
                    let obs = current.observation
                    let timer = current.timer
                    current.observation = nil
                    current.timer = nil
                    return (obs, timer)
                }
                guard let (obs, timer) = cleanup else { return }
                obs?.invalidate()
                timer?.cancel()
                continuation.resume(returning: resolved)
            }
            let obs = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                let current = observed.status
                if current != .unknown {
                    finish(current)
                }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                finish(await MainActor.run { item.status })
            }
            let alreadyDone = state.withValue { current -> Bool in
                if current.resumed { return true }
                current.observation = obs
                current.timer = timer
                return false
            }
            if alreadyDone {
                obs.invalidate()
                timer.cancel()
            }
        }
    }

    @Test("Camera audio player and controller never touch microphone capture or input audio APIs")
    func cameraAudioNeverOpensMicrophoneInput() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            "Sources/MenuBarMijiaApp/CameraLiveVideoPlayer.swift",
            "Sources/MenuBarMijiaApp/CameraLivePanelController.swift",
            "Sources/MenuBarMijiaApp/CameraLivePlayback.swift",
        ] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(!text.contains("AVCapture"))
            #expect(!text.contains("AVAudioEngine"))
            #expect(!text.contains("AVAudioInputNode"))
            #expect(!text.contains("AVAudioSession"))
        }
    }
}

private extension MockCameraLifecycleProvider {
    func setStreamToReturn(_ source: CameraStreamSource) {
        streamToReturn = source
    }

    func setResolveErrorOnAudioEnabled(_ error: (any Error)?) {
        resolveErrorOnAudioEnabled = error
    }
}

/// Parks the quit-timeout sleep until the test releases it. Cancellation still has to be able to
/// leave, because a drain that wins the race cancels this task.
private actor TerminationSleepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park() async {
        if released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if released {
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedHLSTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult
    func withValue<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&storage) }
}

private final class StubHLSURLProtocol: URLProtocol, @unchecked Sendable {
    enum Action {
        case response(statusCode: Int, url: URL, headers: [String: String], body: Data)
        case redirect(from: URL, to: URL)
    }

    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> Action)?

    static func setHandler(_ newHandler: (@Sendable (URLRequest) throws -> Action)?) {
        handlerLock.lock()
        handler = newHandler
        handlerLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handlerLock.lock()
        let current = Self.handler
        Self.handlerLock.unlock()
        guard let current else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            switch try current(request) {
            case .response(let statusCode, let url, let headers, let body):
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !body.isEmpty {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let from, let to):
                guard let response = HTTPURLResponse(
                    url: from,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": to.absoluteString]
                ) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Minimal real loopback HTTP server for deterministic `AVPlayer` HLS end-to-end tests.
private final class LocalHLSStubHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let rangeHeader: String?
    }

    struct Response: Sendable {
        let statusCode: Int
        let reason: String
        let contentType: String
        let body: Data
        var acceptRanges: Bool = false
    }

    let port: UInt16
    private let acceptQueue = DispatchQueue(label: "com.menubarhome.test-hls-stub.accept")
    private let workerQueue = DispatchQueue(label: "com.menubarhome.test-hls-stub.worker", attributes: .concurrent)
    private let handler: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var listenSource: (any DispatchSourceRead)?

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: name.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptAll(listenFD: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        self.listenSource = source
        source.resume()
    }

    deinit {
        stop()
    }

    func stop() {
        let source: (any DispatchSourceRead)? = {
            lock.lock()
            defer { lock.unlock() }
            let current = listenSource
            listenSource = nil
            return current
        }()
        source?.cancel()
    }

    private func acceptAll(listenFD: Int32) {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 { break }
            _ = Darwin.fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            let flags = Darwin.fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 { _ = Darwin.fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK) }
            var one: Int32 = 1
            _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let handler = self.handler
            workerQueue.async {
                defer { Darwin.close(clientFD) }
                Self.serve(clientFD: clientFD, handler: handler)
            }
        }
    }

    private static func serve(clientFD: Int32, handler: @Sendable (Request) -> Response) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while data.count < 16_384 {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(clientFD, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.range(of: sep) != nil { break }
        }
        guard let head = String(data: data, encoding: .isoLatin1),
              let firstLine = head.components(separatedBy: "\r\n").first else {
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var rangeHeader: String?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":"),
               line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                rangeHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let resp = handler(Request(method: method, path: path, rangeHeader: rangeHeader))

        var statusCode = resp.statusCode
        var reason = resp.reason
        var payload = resp.body
        var extra = ""
        if statusCode == 200,
           resp.acceptRanges,
           let rangeHeader,
           let normalized = HAHLSPlaylistPolicy.sanitizedRangeHeader(rangeHeader),
           normalized.hasPrefix("bytes=") {
            let spec = normalized.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2, let start = Int(spec[0]), start >= 0, start < resp.body.count {
                let end = spec[1].isEmpty ? (resp.body.count - 1) : min(resp.body.count - 1, Int(spec[1]) ?? (resp.body.count - 1))
                if end >= start {
                    statusCode = 206
                    reason = "Partial Content"
                    payload = resp.body.subdata(in: start..<(end + 1))
                    extra += "Content-Range: bytes \(start)-\(end)/\(resp.body.count)\r\n"
                }
            }
        }
        if resp.acceptRanges {
            extra += "Accept-Ranges: bytes\r\n"
        }
        let wireHead = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            + "Content-Type: \(resp.contentType)\r\n"
            + extra
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var wire = Data(wireHead.utf8)
        if method != "HEAD" {
            wire.append(payload)
        }
        wire.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(clientFD, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
