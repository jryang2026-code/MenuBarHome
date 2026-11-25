import AppKit
import AVFoundation
import Foundation
import PreferencesTestSupport
import StateTestSupport
import Testing
import UniformTypeIdentifiers
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

    @Test("Non-managed HLS routes through CameraHLSResourceLoader, validates sub-requests, rewrites playlists, and blocks redirects")
    func hardenedHLSResourceLoaderEnforcesNetworkBoundary() async throws {
        let originURL = try #require(URL(string: "http://192.168.1.10:8123/api/hls/tok/master_playlist.m3u8"))
        let loopbackURL = try #require(URL(string: "http://127.0.0.1:43123/api/stream.m3u8?src=cam"))

        // 1. Factory routes remote/HA HLS through custom proxy scheme + delegate, leaving loopback direct.
        let hardened = try #require(CameraHLSPlayerFactory.makePlayerItem(url: originURL, allowsLoopback: false))
        let hardenedAsset = try #require(hardened.item.asset as? AVURLAsset)
        #expect(hardenedAsset.url.scheme == HAHLSPlaylistPolicy.httpProxyScheme)
        #expect(hardened.loader != nil)
        #expect(hardenedAsset.resourceLoader.delegate === hardened.loader)
        hardened.loader?.invalidate()

        let managed = try #require(CameraHLSPlayerFactory.makePlayerItem(url: loopbackURL, allowsLoopback: true))
        let managedAsset = try #require(managed.item.asset as? AVURLAsset)
        #expect(managedAsset.url == loopbackURL)
        #expect(managed.loader == nil)

        // 2. End-to-end loader verification with real URLSession + HARedirectBlockingDelegate + stubbed URLProtocol.
        let requestedPaths = LockedHLSTestBox([String]())
        let validatedURLs = LockedHLSTestBox([URL]())
        let blockedSecretFetched = LockedHLSTestBox(false)
        let shouldFailDNS = LockedHLSTestBox(false)

        StubHLSURLProtocol.setHandler { request in
            let url = try #require(request.url)
            requestedPaths.withValue { $0.append(url.path) }
            if url.host == "127.0.0.1" || url.host == "169.254.169.254" {
                blockedSecretFetched.withValue { $0 = true }
                return .response(statusCode: 200, url: url, headers: [:], body: Data("SECRET".utf8))
            }
            switch url.path {
            case "/api/hls/tok/master_playlist.m3u8":
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
            case "/api/hls/tok/key.bin":
                return .response(
                    statusCode: 200,
                    url: url,
                    headers: ["Content-Type": "application/octet-stream"],
                    body: Data(repeating: 0xAB, count: 16)
                )
            case "/api/hls/tok/seg0.ts":
                let full = Data([0x47, 0x40, 0x11, 0x10, 0x01, 0x02, 0x03, 0x04])
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

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubHLSURLProtocol.self]
        let testSession = URLSession(configuration: cfg, delegate: HARedirectBlockingDelegate.shared, delegateQueue: nil)
        defer { testSession.invalidateAndCancel() }

        let loader = CameraHLSResourceLoader(
            originURL: originURL,
            session: testSession,
            validateAddress: { url in
                validatedURLs.withValue { $0.append(url) }
                if shouldFailDNS.value {
                    throw HAEndpointResolutionError.prohibitedAddress
                }
            }
        )

        // Same-origin master -> media -> key -> segment (including 206 byte range and Int.max length) all succeed.
        let proxiedMaster = try #require(HAHLSPlaylistPolicy.proxiedURL(from: originURL))
        let masterRes = try await loader.loadResource(proxiedURL: proxiedMaster)
        #expect(masterRes.isPlaylist)
        #expect(masterRes.contentType == UTType.m3uPlaylist.identifier)
        #expect(String(decoding: masterRes.data, as: UTF8.self).contains("menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/playlist.m3u8"))

        let proxiedMedia = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/playlist.m3u8"))
        let mediaRes = try await loader.loadResource(proxiedURL: proxiedMedia)
        let mediaText = String(decoding: mediaRes.data, as: UTF8.self)
        #expect(mediaText.contains("URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/key.bin\""))
        #expect(mediaText.contains("\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/tok/seg0.ts\n"))

        let proxiedKey = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/key.bin"))
        let keyRes = try await loader.loadResource(proxiedURL: proxiedKey)
        #expect(!keyRes.isPlaylist && keyRes.data == Data(repeating: 0xAB, count: 16))

        let proxiedSeg = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/seg0.ts"))
        let rangeRes = try await loader.loadResource(
            proxiedURL: proxiedSeg,
            requestedOffset: 2,
            requestedLength: 4,
            requestsAllDataToEnd: false
        )
        #expect(rangeRes.contentType == UTType.mpeg2TransportStream.identifier)
        #expect(rangeRes.contentLength == 8)
        #expect(rangeRes.isByteRangeAccessSupported)
        #expect(rangeRes.data == Data([0x11, 0x10, 0x01, 0x02]))

        // AVFoundation passes Int.max requestedLength on some requests; offset + Int.max must never overflow.
        let openRangeRes = try await loader.loadResource(
            proxiedURL: proxiedSeg,
            requestedOffset: 4,
            requestedLength: Int.max,
            requestsAllDataToEnd: false
        )
        #expect(openRangeRes.data == Data([0x01, 0x02, 0x03, 0x04]))

        // Cross-origin sub-request directly to loader is rejected before hitting the network.
        let evilSubURL = try #require(URL(string: "menubarhome-hls-http://169.254.169.254/latest/meta-data/"))
        await #expect(throws: HAHLSPlaylistError.crossOriginURI) {
            _ = try await loader.loadResource(proxiedURL: evilSubURL)
        }

        // Bare-CR smuggled cross-origin URI inside playlist fails closed.
        let evilPlaylistURL = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/evil_playlist.m3u8"))
        await #expect(throws: HAHLSPlaylistError.crossOriginURI) {
            _ = try await loader.loadResource(proxiedURL: evilPlaylistURL)
        }

        // Validated same-origin 302 redirect is followed cleanly, while loopback 302 redirect is blocked.
        let sameOriginRedirectURL = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/redirect_same_origin.ts"))
        let redirectedSeg = try await loader.loadResource(proxiedURL: sameOriginRedirectURL)
        #expect(redirectedSeg.data == Data([0x47, 0x40, 0x11, 0x10, 0x01, 0x02, 0x03, 0x04]))

        let redirectURL = try #require(URL(string: "menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/redirect_to_loopback.ts"))
        await #expect(throws: URLError(.badServerResponse)) {
            _ = try await loader.loadResource(proxiedURL: redirectURL)
        }
        #expect(blockedSecretFetched.value == false)

        // Fresh DNS rebinding failure on a sub-request blocks before making the HTTP call.
        shouldFailDNS.withValue { $0 = true }
        let countBeforeRebind = requestedPaths.value.count
        await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
            _ = try await loader.loadResource(proxiedURL: proxiedSeg)
        }
        #expect(requestedPaths.value.count == countBeforeRebind)
        #expect(validatedURLs.value.count == 9)
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
