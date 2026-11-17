import AppKit
import Foundation
import SwiftUI
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
    private(set) var stoppedDeviceIDs: [String] = []
    private var resolveCount = 0
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
        let hungStore = HomeStore(provider: hungProvider, defaultsSuiteName: suiteName)
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

    @Test("Camera toolbar icon buttons expose localized accessibility labels")
    func cameraToolbarIconButtonsExposeAccessibilityLabels() throws {
        let suiteName = "MenuBarMijiaTests.CameraA11y.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let camera = Self.makeCameraDevice(id: "cam-a11y")
        let store = HomeStore(provider: MockCameraLifecycleProvider(), defaultsSuiteName: suiteName)
        store.devices = [camera]
        let previewURL = try #require(URL(string: "http://127.0.0.1:9/camera"))
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        controller.isExpandedSize = false
        controller.configurePTZPreview(
            store: store,
            deviceId: camera.id,
            binding: nil,
            stream: .mjpeg(previewURL),
            notice: nil,
            ready: false,
            hasFrame: false
        )
        defer {
            controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false)
        }

        let compact = CGSize(
            width: CameraLivePanelController.compactSize.width,
            height: CameraLivePanelController.compactSize.height
        )
        let languages: [(AppLanguage, [String], String, String, String, String)] = [
            (.zhHans, ["仅画面", "旋转画面", "最大化画面窗口", "关闭摄像头小窗", "画面操作"], "取消置顶", "置顶小窗", "开启声音", "关闭声音"),
            (.zhHant, ["僅畫面", "旋轉畫面", "最大化畫面視窗", "關閉攝影機小窗", "畫面操作"], "取消置頂", "置頂小窗", "開啟聲音", "關閉聲音"),
            (.en, ["Video only", "Rotate picture", "Maximize camera window", "Close camera window", "Picture controls"], "Unpin", "Pin window", "Unmute audio", "Mute audio"),
        ]
        for (language, shared, pinned, unpinned, unmute, mute) in languages {
            controller.isPinnedOnTop = true
            let pinnedLabels = L10n.$overrideLanguage.withValue(language) {
                self.accessibilityLabels(
                    of: CameraLivePanelView(controller: controller, store: store),
                    size: compact
                )
            }
            for text in shared + [pinned] {
                #expect(pinnedLabels.contains(text), "\(language.rawValue) missing \(text); saw \(pinnedLabels)")
            }

            controller.isPinnedOnTop = false
            let unpinnedLabels = L10n.$overrideLanguage.withValue(language) {
                self.accessibilityLabels(
                    of: CameraLivePanelView(controller: controller, store: store),
                    size: compact
                )
            }
            #expect(unpinnedLabels.contains(unpinned), "\(language.rawValue) missing \(unpinned); saw \(unpinnedLabels)")

            let unmuteLabels = L10n.$overrideLanguage.withValue(language) {
                self.accessibilityLabels(
                    of: CameraLiveAudioStatusView(status: .audio(isMuted: true)) {},
                    size: CGSize(width: 44, height: 44)
                )
            }
            #expect(unmuteLabels.contains(unmute), "\(language.rawValue) missing \(unmute); saw \(unmuteLabels)")

            let muteLabels = L10n.$overrideLanguage.withValue(language) {
                self.accessibilityLabels(
                    of: CameraLiveAudioStatusView(status: .audio(isMuted: false)) {},
                    size: CGSize(width: 44, height: 44)
                )
            }
            #expect(muteLabels.contains(mute), "\(language.rawValue) missing \(mute); saw \(muteLabels)")
        }
    }

    private func accessibilityLabels<V: View>(of view: V, size: CGSize) -> [String] {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let labels = Self.collectAccessibilityLabels(from: hosting)
        window.contentView = nil
        window.orderOut(nil)
        return labels
    }

    private static func collectAccessibilityLabels(from root: NSObject) -> [String] {
        var labels: [String] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let raw = object.accessibilityLabel() ?? object.accessibilityTitle() {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    labels.append(trimmed)
                }
            }
            for case let child as NSObject in object.accessibilityChildren() ?? [] {
                walk(child)
            }
        }
        walk(root)
        return labels
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
