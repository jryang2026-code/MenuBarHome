import AppKit
import AVFoundation
import AVKit
import MijiaCore
import Observation
import SwiftUI

// MARK: - Floating Live Camera Window Controller (#97)

/// Borderless, resizable floating `NSPanel` that stays visible across Spaces and full-screen apps.
final class CameraFloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A nonactivating panel ignores the click that would make it key, so the first click on
    /// the close button never reached the SwiftUI action.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class WarmCameraPlayback {
    let playback: CameraLivePlayback
    let deviceID: String
    let lensID: String
    let identity: CameraWarmIdentity
    var expiryTask: Task<Void, Never>?

    init(playback: CameraLivePlayback, deviceID: String, lensID: String, identity: CameraWarmIdentity) {
        self.playback = playback
        self.deviceID = deviceID
        self.lensID = lensID
        self.identity = identity
    }
}

extension CameraWindowFrame {
    init(_ rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

@Observable
@MainActor
public final class CameraLivePanelController: NSObject, NSWindowDelegate {
    public static let shared = CameraLivePanelController()

    public static let compactSize = NSSize(
        width: CameraLivePanelMetrics.compactWidth,
        height: CameraLivePanelMetrics.compactHeight
    )
    public static let expandedSize = NSSize(width: 640, height: 420)
    private static let frameStorageKey = "camera_live_panel_frame_v1"
    private static let maxWarmPlaybacks = 2
    private static let warmPlaybackLifetime: Duration = .seconds(90)

    public internal(set) var activeDeviceId: String?
    public internal(set) var activeLensID: String?
    public internal(set) var streamSource: CameraStreamSource?
    public private(set) var isLoadingStream = false
    public private(set) var errorMessage: String?
    public private(set) var snapshotImage: NSImage?
    /// Native H.264/H.265 player for `.liveMP4` streams; nil for every other source.
    private(set) var videoPlayer: CameraLiveVideoPlayer?
    public internal(set) var hasLiveVideoFrame = false
    /// Native Picture-in-Picture for the live video layer.
    @ObservationIgnored private var pictureInPicture: CameraPictureInPicture?
    public private(set) var isPictureInPictureActive = false
    public var isPinnedOnTop = true {
        didSet { syncWindowLevel() }
    }
    /// Rotation is a mounting preference per camera, so switching cameras keeps each one upright.
    public private(set) var videoRotations: [String: Int] = [:]
    /// HLS streams can carry an audio track; every other source is video only. The player still
    /// starts muted, so sound is an explicit opt-in (#29).
    public var isMuted = true
    public var isExpandedSize = true
    /// The window fills the screen's visible frame until the user restores it.
    public private(set) var isMaximized = false
    private var frameBeforeMaximize: NSRect?
    public var isShowingURLConfig = false
    public var customURLInput = ""

    /// Set only when a camera has an evidence-backed motor and the running bridge exposes the
    /// motor endpoint. Nil keeps the plain viewer and the window-drag gesture.
    public internal(set) var ptzBinding: CameraPTZBinding?
    public internal(set) var ptzClientReady = false
    /// Transient failure text; nil when the local bridge accepted every command.
    public internal(set) var ptzNotice: String?
    /// Shown inside the picture when the user asks why the video-only stream has no mute control.
    public internal(set) var videoOnlyNotice: String?
    var videoOnlyNoticeTask: Task<Void, Never>?

    var ptzClient: (any CameraPTZControlling)?
    var ptzPlanner = CameraPTZDragPlanner()
    var ptzDragID: UUID?
    var ptzToken: CameraPTZSessionToken?
    var ptzDeviceId: String?
    var ptzSeq: UInt64 = 0
    var ptzBeginTask: Task<Void, Never>?
    var ptzHeartbeatTask: Task<Void, Never>?
    var ptzQueue = CameraPTZCommandQueue()
    var ptzPendingDirection: CameraPTZDirection?
    var ptzNoticeTask: Task<Void, Never>?
    var ptzStopTask: Task<Void, Never>?
    var ptzLifecycleID = UUID()
    var ptzUnresolvedStops: [CameraPTZStopAttempt] = []
    var ptzStopRetryHold: (@MainActor () async -> Void)?
    var ptzManualStopInFlight = false
    /// Fixed clock for deterministic previews; nil in production.
    var demoTimestampOverride: Date?

    /// Disabled in unit tests so opening the camera panel does not steal focus from the terminal.
    public var presentsActively = true

    weak var store: HomeStore?
    private(set) var panelWindow: CameraFloatingPanel?
    private var resolveTask: Task<Void, Never>?
    private var snapshotLoopTask: Task<Void, Never>?
    private var mjpegSession: URLSession?
    private var activePlayback: CameraLivePlayback?
    private var warmPlaybacks: [WarmCameraPlayback] = []
    private var selectedLensByDevice: [String: CameraLens.Role] = [:]
    private var closeReleaseTask: Task<Void, Never>?
    private var closeReleaseGeneration = 0
    private var pendingStopTasks: [String: Task<Void, Never>] = [:]
    private var pendingStopGenerations: [String: Int] = [:]
    private var activeCameraEntityID: String?
    private var doorbellDismissTask: Task<Void, Never>?
    /// The window sits where a ring put it, so closing it must not overwrite the user's saved position.
    private(set) var isDoorbellPlacement = false
    /// The ring still owns this window's closing; the user taking it over (moving, resizing, PiP,
    /// interacting, reopening) ends that.
    private(set) var doorbellOwnsClose = false
    var hasPendingDoorbellAutoDismiss: Bool { doorbellDismissTask != nil && doorbellOwnsClose }
    private var isClosing = false
    private let snapshotSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    override private init() {
        super.init()
    }

    public func install(with store: HomeStore) {
        self.store = store
        store.onOpenCameraLiveView = { [weak self] device in
            self?.present(device: device)
        }
        store.onDoorbellRing = { [weak self] response in
            self?.respondToDoorbell(response)
        }
    }

    /// Plays the chime and opens the ringing doorbell's camera at the top right (#308). A camera
    /// view or picture-in-picture session already on screen is left alone; a window the ring opened
    /// closes after the user's delay unless they reopened it, switched camera or went picture-in-picture.
    private func respondToDoorbell(_ response: DoorbellResponse) {
        if response.playsChime { NSSound(named: "Glass")?.play() }
        guard let store, let deviceId = response.cameraDeviceId, !isPictureInPictureActive else { return }
        if isVisible {
            // A later press while the ring's own window is up keeps it open for another full delay.
            if doorbellOwnsClose, activeDeviceId == deviceId { scheduleDoorbellDismiss(deviceId, after: response.dismissAfter) }
            return
        }
        store.openCameraLiveView(deviceId)
        guard activeDeviceId == deviceId, let panel = panelWindow, panel.isVisible else { return }
        panel.setFrame(Self.topRightFrame(for: panel.frame.size), display: true)
        isMaximized = false
        frameBeforeMaximize = nil
        isDoorbellPlacement = true
        doorbellOwnsClose = true
        scheduleDoorbellDismiss(deviceId, after: response.dismissAfter)
    }

    private func scheduleDoorbellDismiss(_ deviceId: String, after delay: Duration) {
        doorbellDismissTask?.cancel()
        doorbellDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.doorbellDismissTask = nil
            guard self.isVisible, self.doorbellOwnsClose, self.activeDeviceId == deviceId, !self.isPictureInPictureActive else { return }
            self.closePanel()
        }
    }

    func claimDoorbellWindowForUser(claimsPlacement: Bool) {
        doorbellDismissTask?.cancel()
        doorbellDismissTask = nil
        doorbellOwnsClose = false
        if claimsPlacement {
            isDoorbellPlacement = false
        }
    }

    public func windowWillMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) == nil || (notification.object as? NSWindow) === panelWindow else { return }
        claimDoorbellWindowForUser(claimsPlacement: true)
    }

    public func windowWillStartLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) == nil || (notification.object as? NSWindow) === panelWindow else { return }
        claimDoorbellWindowForUser(claimsPlacement: true)
    }

    private static func topRightFrame(for size: NSSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(origin: NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 48), size: size)
    }

    public var isVisible: Bool {
        panelWindow?.isVisible == true
    }

    public var currentDevice: SmartDevice? {
        guard let id = activeDeviceId else { return nil }
        return store?.devices.first(where: { $0.id == id })
    }

    private static func cameraEntityID(for device: SmartDevice) -> String? {
        guard case .camera(let spec) = device.kind else { return nil }
        return spec.entityId
    }

    /// A backend handoff can change the entity id while the canonical device id stays the
    /// same. Reload only when that replacement did not come from the camera switcher itself.
    public func handleCameraEntityChange(_ entityID: String?) {
        guard let entityID, entityID != activeCameraEntityID else { return }
        reloadStream()
    }

    /// Every camera in the current home, including offline ones so a camera that drops off
    /// the network does not disappear from the switcher while it is being watched.
    public var cameraDevices: [SmartDevice] {
        guard let store else { return [] }
        return store.devices.filter {
            guard !store.hiddenDeviceIds.contains($0.id) else { return false }
            if case .camera = $0.kind { return true }
            return false
        }
    }

    public func selectedLens(for device: SmartDevice) -> CameraLens? {
        guard case .camera(let spec) = device.kind, !spec.lenses.isEmpty else { return nil }
        let role = selectedLensByDevice[device.id] ?? .main
        return spec.lenses.first { $0.role == role } ?? spec.lenses.first
    }

    public func selectLens(_ lens: CameraLens, for device: SmartDevice) {
        selectedLensByDevice[device.id] = lens.role
        guard activeDeviceId == device.id else { return }
        claimDoorbellWindowForUser(claimsPlacement: false)
        reloadStream()
    }

    public func presentNextCamera() {
        guard let store else { return }
        let online = cameraDevices.filter(\.isOnline)
        guard online.count > 1 else { return }
        claimDoorbellWindowForUser(claimsPlacement: false)
        let index = online.firstIndex { $0.id == activeDeviceId } ?? -1
        let next = online[(index + 1) % online.count]
        store.openCameraLiveView(next.id)
    }

    public func present(device: SmartDevice) {
        guard let store else { return }
        guard case .camera = device.kind else { return }
        guard device.isOnline else {
            store.showToast(
                L10n.tr("\(device.name) 当前离线", "\(device.name) is offline"),
                isError: true
            )
            return
        }
        finishPTZMove()
        closeReleaseGeneration &+= 1
        closeReleaseTask?.cancel()
        closeReleaseTask = nil
        doorbellDismissTask?.cancel()
        doorbellDismissTask = nil
        isDoorbellPlacement = false
        doorbellOwnsClose = false
        if isPictureInPictureActive {
            pictureInPicture?.stop()
        }

        let previousDeviceId = activeDeviceId
        let previousLensID = activeLensID
        let targetLens = selectedLens(for: device)
        let targetLensID = targetLens?.id ?? "main"
        let canReuseHotStream = (
            previousDeviceId == device.id
            && previousLensID == targetLensID
            && errorMessage == nil
            && (activePlayback != nil || streamSource != nil || isLoadingStream)
        )
        let reservedWarm = canReuseHotStream
            ? nil
            : takeWarmPlayback(deviceID: device.id, lensID: targetLensID)
        if let previousDeviceId, !canReuseHotStream {
            let oldId = previousDeviceId
            if previousDeviceId != device.id,
               let playback = activePlayback,
               playback.failure == nil,
               case .liveMP4 = playback.source {
                tearDownPictureInPicture()
                warmActivePlayback(
                    playback,
                    deviceID: previousDeviceId,
                    lensID: previousLensID ?? "main",
                    identity: warmIdentity(for: previousDeviceId, entityID: activeCameraEntityID)
                )
            } else {
                stopStreamTasks()
                if oldId != device.id {
                    scheduleStopCameraStream(for: oldId)
                }
            }
            isMuted = true
        }

        activeDeviceId = device.id
        activeLensID = targetLensID
        activeCameraEntityID = Self.cameraEntityID(for: device)
        customURLInput = store.cameraCustomStreamURL(for: device.id) ?? ""
        isShowingURLConfig = false

        let panel = panelWindow ?? makePanel()
        panelWindow = panel
        panel.appearance = MenuBarPanelController.preferredAppearance()
        if !(panel.contentView is NSHostingView<CameraLivePanelView>) {
            let hosting = NSHostingView(rootView: CameraLivePanelView(controller: self, store: store))
            hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 14
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
        }
        syncWindowLevel()
        if !panel.isVisible {
            let initialSize = isExpandedSize ? Self.expandedSize : Self.compactSize
            panel.setFrame(initialFrame(for: initialSize), display: true)
            // The frame is no longer the maximized rect, so the flag and the saved
            // small rect leave together. Order-out does not do this: the frame is unchanged.
            isMaximized = false
            frameBeforeMaximize = nil
        }
        if presentsActively {
            panel.alphaValue = 1
            panel.hasShadow = true
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.hasShadow = false
            panel.orderFront(nil)
        }
        if !canReuseHotStream {
            if let warm = reservedWarm {
                let currentIdentity = warmIdentity(for: device.id, entityID: Self.cameraEntityID(for: device))
                if CameraWarmReuse.accepts(
                    failure: warm.playback.failure,
                    identityMatches: warm.identity.matches(currentIdentity)
                ) {
                    tearDownPictureInPicture()
                    activePlayback = warm.playback
                    streamSource = warm.playback.source
                    videoPlayer = warm.playback.player
                    hasLiveVideoFrame = warm.playback.hasFrame
                    isLoadingStream = false
                    errorMessage = nil
                    configurePTZ(for: warm.playback.source)
                } else {
                    releaseWarmPlayback(warm)
                    reloadStream()
                }
            } else {
                reloadStream()
            }
        }
    }

    public func closePanel() {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }

        closeReleaseTask?.cancel()
        doorbellDismissTask?.cancel()
        doorbellDismissTask = nil
        setURLFieldActive(false)
        storePanelFrame()
        isMaximized = false
        frameBeforeMaximize = nil
        isDoorbellPlacement = false
        doorbellOwnsClose = false
        closeReleaseGeneration &+= 1
        let releaseGeneration = closeReleaseGeneration
        let closingDeviceId = activeDeviceId
        let activePlaybackIDs = warmPlaybacks.map(\.deviceID)
        let store = self.store
        stopStreamTasks()
        for warm in warmPlaybacks {
            warm.expiryTask?.cancel()
            warm.playback.stop()
        }
        warmPlaybacks.removeAll()
        isMuted = true
        panelWindow?.orderOut(nil)

        closeReleaseTask = Task { @MainActor [weak self] in
            guard let store else { return }
            var deviceIDs = Set(activePlaybackIDs)
            if let closingDeviceId { deviceIDs.insert(closingDeviceId) }
            for deviceID in deviceIDs {
                guard let self else { return }
                let generationMatches = self.closeReleaseGeneration == releaseGeneration
                guard CameraCloseRelease.shouldStop(
                    deviceID: deviceID,
                    activeDeviceID: self.activeDeviceId,
                    generationMatches: generationMatches
                ) else { continue }
                await store.stopCameraStream(for: deviceID)
            }
            self?.closeReleaseTask = nil
        }
    }

    private func stopStreamTasks() {
        clearPTZ()
        videoOnlyNoticeTask?.cancel()
        videoOnlyNoticeTask = nil
        videoOnlyNotice = nil
        resolveTask?.cancel()
        resolveTask = nil
        snapshotLoopTask?.cancel()
        snapshotLoopTask = nil
        mjpegSession?.invalidateAndCancel()
        mjpegSession = nil
        activePlayback?.stop()
        activePlayback = nil
        videoPlayer = nil
        tearDownPictureInPicture()
        hasLiveVideoFrame = false
        snapshotImage = nil
        streamSource = nil
        isLoadingStream = false
    }

    private func warmIdentity(for deviceID: String, entityID: String?) -> CameraWarmIdentity {
        CameraWarmIdentity(
            entityID: entityID,
            backend: store?.deviceBackend(for: deviceID) ?? .demo,
            pinnedBackend: store?.pinnedSource(for: deviceID)
        )
    }

    /// The system PiP window is showing the same frame. Ordering the panel out
    /// does not change that rect, so the maximize flag and the saved small frame stay.
    func suspendPanelForPictureInPicture() {
        doorbellDismissTask?.cancel()
        doorbellDismissTask = nil
        doorbellOwnsClose = false
        setURLFieldActive(false)
        storePanelFrame()
        panelWindow?.orderOut(nil)
    }

    func storePanelFrame() {
        guard !isDoorbellPlacement, let panel = panelWindow else { return }
        let frame = CameraWindowFrames.frameToRemember(
            isMaximized: isMaximized,
            saved: frameBeforeMaximize.map { CameraWindowFrame($0) },
            current: CameraWindowFrame(panel.frame)
        )
        guard let frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame.nsRect), forKey: Self.frameStorageKey)
    }

    private func warmActivePlayback(
        _ playback: CameraLivePlayback,
        deviceID: String,
        lensID: String,
        identity: CameraWarmIdentity
    ) {
        tearDownPictureInPicture()
        activePlayback = nil
        videoPlayer = nil
        hasLiveVideoFrame = false
        streamSource = nil
        isLoadingStream = false
        errorMessage = nil
        clearPTZ()

        let warm = WarmCameraPlayback(playback: playback, deviceID: deviceID, lensID: lensID, identity: identity)
        warmPlaybacks.append(warm)
        while warmPlaybacks.count > Self.maxWarmPlaybacks {
            releaseWarmPlayback(warmPlaybacks.removeFirst())
        }
        warm.expiryTask = Task { @MainActor [weak self, weak warm] in
            try? await Task.sleep(for: Self.warmPlaybackLifetime)
            guard !Task.isCancelled, let self, let warm else { return }
            self.releaseWarmPlayback(warm)
        }
    }

    private func takeWarmPlayback(deviceID: String, lensID: String) -> WarmCameraPlayback? {
        guard let index = warmPlaybacks.firstIndex(where: {
            $0.deviceID == deviceID && $0.lensID == lensID
        }) else {
            return nil
        }
        let warm = warmPlaybacks.remove(at: index)
        warm.expiryTask?.cancel()
        warm.expiryTask = nil
        return warm
    }

    private func releaseWarmPlayback(_ warm: WarmCameraPlayback) {
        warm.expiryTask?.cancel()
        warm.expiryTask = nil
        warmPlaybacks.removeAll { $0 === warm }
        warm.playback.stop()
        guard activeDeviceId != warm.deviceID else { return }
        scheduleStopCameraStream(for: warm.deviceID)
    }

    private func scheduleStopCameraStream(for deviceID: String) {
        guard let store else { return }
        let prior = pendingStopTasks[deviceID]
        let generation = (pendingStopGenerations[deviceID] ?? 0) &+ 1
        pendingStopGenerations[deviceID] = generation
        pendingStopTasks[deviceID] = Task { @MainActor [weak self] in
            await prior?.value
            await store.stopCameraStream(for: deviceID)
            if self?.pendingStopGenerations[deviceID] == generation {
                self?.pendingStopTasks.removeValue(forKey: deviceID)
            }
        }
    }

    // MARK: - Picture in Picture

    public func togglePictureInPicture() {
        if pictureInPicture == nil, let player = videoPlayer {
            setUpPictureInPicture(for: player)
        }
        guard let pictureInPicture else { return }
        if isPictureInPictureActive {
            pictureInPicture.stop()
        } else {
            finishPTZMove()
            pictureInPicture.start()
        }
    }

    private func setUpPictureInPicture(for player: CameraLiveVideoPlayer) {
        tearDownPictureInPicture()
        let pip = CameraPictureInPicture(displayLayer: player.displayLayer)
        pip.onStateChange = { [weak self, weak pip] in
            guard let self, let pip, self.pictureInPicture === pip else { return }
            let wasActive = self.isPictureInPictureActive
            self.isPictureInPictureActive = pip.isActive
            if pip.isActive, !wasActive {
                // The system PiP window replaces the floating panel; the stream stays live. Taking
                // a ring's window into PiP means the user wants it, so it no longer closes itself.
                self.suspendPanelForPictureInPicture()
            }
        }
        pip.onPlaybackPaused = { [weak player] paused in
            player?.setPlaybackPaused(paused)
        }
        pip.onRestore = { [weak self] in
            self?.panelWindow?.orderFrontRegardless()
        }
        pip.onClosed = { [weak self] in
            self?.closePanel()
        }
        pictureInPicture = pip
    }

    private func tearDownPictureInPicture() {
        pictureInPicture?.invalidate()
        pictureInPicture = nil
        isPictureInPictureActive = false
    }

    public func toggleMute() {
        claimDoorbellWindowForUser(claimsPlacement: false)
        isMuted.toggle()
    }

    public func togglePinnedOnTop() {
        claimDoorbellWindowForUser(claimsPlacement: false)
        isPinnedOnTop.toggle()
    }

    public func userReloadStream() {
        claimDoorbellWindowForUser(claimsPlacement: false)
        reloadStream()
    }

    public func showVideoOnlyNotice() {
        claimDoorbellWindowForUser(claimsPlacement: false)
        videoOnlyNotice = L10n.tr(
            "此画面流仅传输视频，没有音轨；自定义 HLS 流可开启声音",
            "This stream is video only; a custom HLS stream can carry sound"
        )
        videoOnlyNoticeTask?.cancel()
        videoOnlyNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.videoOnlyNotice = nil
        }
    }

    public func videoRotation(for deviceID: String?) -> Int {
        guard let deviceID else { return 0 }
        return videoRotations[deviceID] ?? 0
    }

    public func rotateVideo() {
        guard let deviceID = activeDeviceId else { return }
        claimDoorbellWindowForUser(claimsPlacement: false)
        videoRotations[deviceID] = CameraVideoRotation.next(videoRotations[deviceID] ?? 0)
    }

    public func toggleExpandedSize() {
        claimDoorbellWindowForUser(claimsPlacement: true)
        guard let panel = panelWindow else {
            isMaximized = false
            frameBeforeMaximize = nil
            isExpandedSize.toggle()
            return
        }
        let anchor = CameraWindowFrames.anchorBeforeSizeToggle(
            isMaximized: isMaximized,
            saved: frameBeforeMaximize.map { CameraWindowFrame($0) },
            current: CameraWindowFrame(panel.frame)
        )
        isMaximized = false
        frameBeforeMaximize = nil
        isExpandedSize.toggle()
        let targetSize = isExpandedSize ? Self.expandedSize : Self.compactSize
        let newOrigin = NSPoint(
            x: anchor.x + anchor.width - targetSize.width,
            y: anchor.y + anchor.height - targetSize.height
        )
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedX = min(max(newOrigin.x, screenFrame.minX + 12), screenFrame.maxX - targetSize.width - 12)
        let clampedY = min(max(newOrigin.y, screenFrame.minY + 12), screenFrame.maxY - targetSize.height - 12)
        let nextFrame = NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: targetSize)
        panel.setFrame(nextFrame, display: true, animate: presentsActively)
    }

    public func toggleMaximized() {
        guard let panel = panelWindow else { return }
        claimDoorbellWindowForUser(claimsPlacement: true)
        if isMaximized {
            if let frameBeforeMaximize {
                panel.setFrame(frameBeforeMaximize, display: true, animate: presentsActively)
            }
            isMaximized = false
            frameBeforeMaximize = nil
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        frameBeforeMaximize = panel.frame
        panel.setFrame(screen.visibleFrame, display: true, animate: presentsActively)
        isMaximized = true
    }

    public func setURLFieldActive(_ active: Bool) {
        if active {
            claimDoorbellWindowForUser(claimsPlacement: false)
        }
        if active, presentsActively {
            panelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    public func saveCustomStreamURL() {
        guard let store, let id = activeDeviceId else { return }
        store.setCameraCustomStreamURL(customURLInput, for: id)
        isShowingURLConfig = false
        setURLFieldActive(false)
        reloadStream()
    }

    public func clearCustomStreamURL() {
        guard let store, let id = activeDeviceId else { return }
        customURLInput = ""
        store.setCameraCustomStreamURL(nil, for: id)
        isShowingURLConfig = false
        setURLFieldActive(false)
        reloadStream()
    }

    public func reloadStream() {
        stopStreamTasks()
        errorMessage = nil

        guard let store, let device = currentDevice, case .camera(let spec) = device.kind else {
            return
        }
        activeCameraEntityID = spec.entityId
        guard spec.isOn else {
            scheduleStopCameraStream(for: device.id)
            return
        }

        isLoadingStream = true
        let deviceId = device.id
        let lens = selectedLens(for: device)
        activeLensID = lens?.id ?? "main"
        let channel = lens?.channel ?? 0
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.closeReleaseTask?.value
            await self.pendingStopTasks[deviceId]?.value
            guard !Task.isCancelled else { return }
            do {
                let resolved = try await store.resolveCameraStream(for: deviceId, channel: channel)
                guard !Task.isCancelled else { return }
                self.streamSource = resolved
                self.isLoadingStream = false
                switch resolved {
                case .snapshot(let url):
                    self.startSnapshotLoop(url: url)
                case .liveMP4:
                    self.startLiveVideo(
                        source: resolved,
                        deviceID: deviceId,
                        lensID: lens?.id ?? "main"
                    )
                case .mjpeg(let url):
                    self.startMJPEGStream(url: url)
                case .hls, .demo:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoadingStream = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startSnapshotLoop(url: URL) {
        snapshotLoopTask?.cancel()
        snapshotLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isVisible {
                if let img = await self.fetchSnapshotFrame(from: url) {
                    self.snapshotImage = img
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func configurePTZ(for source: CameraStreamSource) {
        clearPTZ()
        guard case .liveMP4(_, _, let ptz) = source, let ptz else { return }
        ptzBinding = ptz
        let lifecycle = ptzLifecycleID
        Task { @MainActor [weak self] in
            guard let client = await XiaomiCameraBridge.shared.makePTZClient(streamName: ptz.streamName) else {
                return
            }
            guard let self,
                  self.ptzLifecycleID == lifecycle,
                  self.ptzBinding == ptz,
                  self.streamSource != nil else { return }
            self.ptzClient = client
            self.ptzClientReady = true
        }
    }

    /// Plays the camera's own bitstream through VideoToolbox. The playback object owns the
    /// reconnect loop so it can stay warm while another camera is on screen.
    private func startLiveVideo(source: CameraStreamSource, deviceID: String, lensID: String) {
        guard let playback = CameraLivePlayback(deviceID: deviceID, lensID: lensID, source: source) else {
            return
        }
        snapshotLoopTask?.cancel()
        snapshotLoopTask = nil
        videoPlayer?.stop()
        videoPlayer = nil
        tearDownPictureInPicture()
        hasLiveVideoFrame = false
        snapshotImage = nil
        activePlayback = playback
        videoPlayer = playback.player
        configurePTZ(for: source)

        playback.onFirstFrame = { [weak self, weak playback] in
            guard let self, let playback, self.activePlayback === playback else { return }
            self.hasLiveVideoFrame = true
        }

        playback.onFallback = { [weak self, weak playback] url in
            guard let self, let playback, self.activePlayback === playback else { return }
            self.clearPTZ()
            self.activePlayback = nil
            self.videoPlayer = nil
            self.hasLiveVideoFrame = false
            self.tearDownPictureInPicture()
            self.streamSource = .mjpeg(url)
            self.startMJPEGStream(url: url)
        }

        playback.onFailure = { [weak self, weak playback] detail in
            guard let self, let playback, self.activePlayback === playback else { return }
            self.clearPTZ()
            self.activePlayback = nil
            self.videoPlayer = nil
            self.hasLiveVideoFrame = false
            self.streamSource = nil
            self.errorMessage = L10n.tr(
                "实时画面中断：\(detail ?? "无数据")",
                "Live video stopped: \(detail ?? "no data")"
            )
            self.tearDownPictureInPicture()
        }
        playback.start()
    }

    private func startMJPEGStream(url: URL) {
        snapshotLoopTask?.cancel()
        snapshotLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, attempts < 4 {
                attempts += 1
                var receivedFrame = false
                await self.consumeMJPEGConnection(url: url) { [weak self] image in
                    receivedFrame = true
                    self?.snapshotImage = image
                }
                if Task.isCancelled { break }
                if receivedFrame {
                    attempts = 0
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
            guard !Task.isCancelled else { return }
            self.mjpegSession?.invalidateAndCancel()
            self.mjpegSession = nil
            self.snapshotImage = nil
            self.streamSource = nil
            self.errorMessage = L10n.tr(
                "实时画面连接中断，请检查摄像机与电脑是否在同一局域网或点击重试",
                "Live stream disconnected. Check that the camera and Mac are on the same LAN, or click Retry"
            )
        }
    }

    public func desensitizedDiagnosticsReport() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let dev = currentDevice
        let backend = store.map { $0.deviceBackend(for: dev?.id ?? "").rawValue } ?? "unknown"
        let region = backend == HomeBackend.xiaomiCloud.rawValue ? (store?.miCloudRegion.rawValue ?? "cn") : "n/a"
        let model = (dev?.model ?? "").isEmpty ? "unknown" : (dev?.model ?? "unknown")
        let hasStreamEntity: Bool
        let hasSnapshotPath: Bool
        let isAwake: Bool
        if let dev, case .camera(let spec) = dev.kind {
            hasStreamEntity = !(spec.streamEntityId ?? "").isEmpty
            hasSnapshotPath = !(spec.snapshotPath ?? "").isEmpty
            isAwake = spec.isOn
        } else {
            hasStreamEntity = false
            hasSnapshotPath = false
            isAwake = false
        }
        let hasCustomURL = !(store?.cameraCustomStreamURL(for: activeDeviceId ?? "") ?? "").isEmpty
        let streamMode: String
        switch streamSource {
        case .hls?: streamMode = "hls"
        case .liveMP4?: streamMode = "live-mp4"
        case .mjpeg?: streamMode = "mjpeg"
        case .snapshot?: streamMode = "snapshot"
        case .demo?: streamMode = "demo"
        case nil: streamMode = "none"
        }
        let audioSupport: String
        if case .hls = streamSource {
            audioSupport = isMuted ? "hls-muted" : "hls-unmuted"
        } else {
            audioSupport = "video-only"
        }
        let rawError = errorMessage ?? "none"
        let redactedError = rawError
            .replacingOccurrences(of: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, with: "<ip>", options: .regularExpression)
            .replacingOccurrences(of: #"https?://[^\s\)]+"#, with: "<url>", options: .regularExpression)
            .replacingOccurrences(of: #"\b[0-9a-fA-F]{16,}\b"#, with: "<redacted>", options: .regularExpression)
        return [
            "MenuBarHome Camera Diagnostics",
            "version: \(version) (macOS \(arch))",
            "backend: \(backend) (region: \(region))",
            "camera_info: \(model)",
            "online: \(dev?.isOnline ?? false), awake: \(isAwake)",
            "stream_entity: \(hasStreamEntity), snapshot_path: \(hasSnapshotPath), custom_url: \(hasCustomURL)",
            "stream_mode: \(streamMode), audio_support: \(audioSupport)",
            "error: \(redactedError)",
        ].joined(separator: "\n")
    }

    public func copyDesensitizedDiagnostics() {
        claimDoorbellWindowForUser(claimsPlacement: false)
        let report = desensitizedDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        store?.showToast(
            L10n.tr("已复制脱敏摄像机诊断报告", "Copied desensitized camera diagnostics")
        )
    }

    private func consumeMJPEGConnection(
        url: URL,
        onFrame: @escaping @MainActor (NSImage) -> Void
    ) async {
        mjpegSession?.invalidateAndCancel()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = false

        let resumeGuard = MJPEGContinuationGuard()
        let delegate = MJPEGStreamDelegate(
            onFrame: { image in
                Task { @MainActor in
                    onFrame(image)
                }
            },
            onComplete: { _ in
                resumeGuard.resumeOnce()
            }
        )
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.mjpegSession = session
        var req = XiaomiCameraBridge.authorizedURLRequest(for: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: req)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumeGuard.install(continuation)
                task.resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
            resumeGuard.resumeOnce()
        }
    }

    private func fetchSnapshotFrame(from url: URL) async -> NSImage? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps?.queryItems = items
        let targetURL = comps?.url ?? url

        var req = XiaomiCameraBridge.authorizedURLRequest(for: targetURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if req.value(forHTTPHeaderField: "Authorization") == nil,
           let store, store.deviceBackend(for: currentDevice?.id ?? "") == .homeAssistant,
           targetURL.query?.contains("token=") != true,
           HAPlaintextConsent.allowsToken(to: targetURL.absoluteString, defaults: store.userDefaults) {
            let token = store.loadHAToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        guard let (data, resp) = try? await snapshotSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func makePanel() -> CameraFloatingPanel {
        let panel = CameraFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: CameraLivePanelMetrics.compactWidth, height: 204)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = nil
        panel.onCancel = { [weak self] in
            self?.closePanel()
        }
        return panel
    }

    private func syncWindowLevel() {
        let pinnedLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        guard let panel = panelWindow else { return }
        panel.isFloatingPanel = isPinnedOnTop
        panel.level = isPinnedOnTop ? pinnedLevel : .normal
        panel.collectionBehavior = isPinnedOnTop
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
    }

    private func initialFrame(for size: NSSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved = UserDefaults.standard.string(forKey: Self.frameStorageKey) {
            let rect = NSRectFromString(saved)
            if rect.width >= CameraLivePanelMetrics.compactWidth, rect.height >= 200 {
                let x = min(max(rect.minX, visible.minX + 12), visible.maxX - size.width - 12)
                let y = min(max(rect.minY, visible.minY + 12), visible.maxY - size.height - 12)
                let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
                if let menuPanel = MenuBarPanelController.shared.panelWindow,
                   menuPanel.isVisible,
                   candidate.intersects(menuPanel.frame) {
                    let leftX = max(visible.minX + 12, menuPanel.frame.minX - size.width - 12)
                    return NSRect(origin: NSPoint(x: leftX, y: y), size: size)
                }
                return candidate
            }
        }
        if let menuPanel = MenuBarPanelController.shared.panelWindow, menuPanel.isVisible {
            let x = max(visible.minX + 12, menuPanel.frame.minX - size.width - 12)
            let y = min(max(menuPanel.frame.maxY - size.height, visible.minY + 12), visible.maxY - size.height - 12)
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
        let x = visible.maxX - size.width - 24
        let y = visible.maxY - size.height - 48
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

private final class MJPEGContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didResume = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if didResume {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resumeOnce() {
        lock.lock()
        didResume = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

private final class MJPEGStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onFrame: @Sendable (NSImage) -> Void
    private let onComplete: @Sendable (Error?) -> Void

    init(
        onFrame: @escaping @Sendable (NSImage) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.onFrame = onFrame
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var latestImage: NSImage?
        lock.lock()
        buffer.append(data)
        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])
        while let startRange = buffer.range(of: soi),
              let endRange = buffer.range(of: eoi, in: startRange.upperBound..<buffer.endIndex) {
            let frameData = buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
            if let image = NSImage(data: frameData) {
                latestImage = image
            }
        }
        if buffer.count > 4_000_000 {
            buffer.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if let latestImage {
            onFrame(latestImage)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }
}

// MARK: - AVPlayerView Wrapper (HLS + Native macOS PiP)

struct CameraHLSPlayerView: NSViewRepresentable {
    let url: URL
    let isMuted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        view.player = player
        context.coordinator.currentURL = url
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player?.isMuted = isMuted
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        nsView.player?.pause()
        nsView.player = player
        player.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    final class Coordinator {
        var currentURL: URL?
    }
}

// MARK: - Live HUD Audio Status (#29)

enum CameraVideoRotation {
    static func next(_ degrees: Int) -> Int {
        ((degrees % 360) + 360 + 90) % 360
    }

    /// A quarter turn swaps width and height; scaling by this factor keeps the picture inside
    /// the viewport instead of letting the rotated bounds clip.
    static func fitScale(degrees: Int, in size: CGSize) -> CGFloat {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized == 90 || normalized == 270, size.width > 0, size.height > 0 else {
            return 1
        }
        return min(size.width / size.height, size.height / size.width)
    }
}

/// What the live HUD can say about sound for the stream on screen. Only an HLS stream can carry
/// an audio track; P2P, MJPEG, snapshot and demo sources are video only.
enum CameraLiveAudioStatus: Equatable {
    case hidden
    case videoOnly
    case audio(isMuted: Bool)

    init(streamSource: CameraStreamSource?, isMuted: Bool) {
        switch streamSource {
        case .hls?: self = .audio(isMuted: isMuted)
        case nil: self = .hidden
        default: self = .videoOnly
        }
    }
}

/// Mute toggle for an HLS stream, or the "video only" status for every frame-based source.
/// The status is clickable only to explain why there is no audio. Split from the panel so the
/// two states can be snapshotted without an AVPlayerView (#29).
struct CameraLiveAudioStatusView: View {
    let status: CameraLiveAudioStatus
    var isCompact: Bool = false
    var onExplainVideoOnly: () -> Void = {}
    let onToggleMute: () -> Void

    var body: some View {
        switch status {
        case .hidden:
            EmptyView()
        case .videoOnly:
            if isCompact {
                CameraHUDIconButton(
                    symbol: "speaker.slash",
                    isActive: false,
                    help: videoOnlyHelp,
                    action: onExplainVideoOnly
                )
            } else {
                Button(action: onExplainVideoOnly) {
                    videoOnlyBadge
                }
                .buttonStyle(.plain)
                .help(videoOnlyHelp)
            }
        case .audio(let isMuted):
            CameraHUDIconButton(
                symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                isActive: !isMuted,
                help: isMuted ? L10n.tr("开启声音", "Unmute audio") : L10n.tr("关闭声音", "Mute audio"),
                action: onToggleMute
            )
        }
    }

    private var videoOnlyBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 9, weight: .semibold))
            Text(L10n.tr("仅画面", "Video only"))
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
    }

    private var videoOnlyHelp: String {
        L10n.tr(
            "当前视频流仅传输画面，不含音轨；点击查看说明",
            "This stream is video only and has no audio track; click for details"
        )
    }
}

/// Shared 24 pt HUD glyph so the circular button and the overflow menu label draw and measure
/// identically.
struct CameraHUDGlyph: View {
    let symbol: String
    var isActive = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isActive ? Color.cyan : Color.white.opacity(0.82))
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(isActive ? Color.cyan.opacity(0.20) : Color.white.opacity(0.10))
            )
    }
}

/// Circular HUD button shared by the live-window controls.
private struct CameraHUDIconButton: View {
    let symbol: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CameraHUDGlyph(symbol: symbol, isActive: isActive)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Floating Camera Panel SwiftUI Content

struct CameraLivePanelView: View {
    @Bindable var controller: CameraLivePanelController
    let store: HomeStore
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var demoTick: Int = 0

    private var device: SmartDevice? {
        controller.currentDevice
    }

    private var cameraSpec: CameraSpec? {
        guard let dev = device, case .camera(let spec) = dev.kind else { return nil }
        return spec
    }

    private var cameras: [SmartDevice] {
        controller.cameraDevices
    }

    /// HA has no video for this camera and no Mi account is signed in (#97).
    private var offersMiSignIn: Bool {
        guard let device, let cameraSpec else { return false }
        return cameraSpec.offersMiSignInForVideo(
            backend: store.deviceBackend(for: device.id),
            hasMiSource: store.hasMiSource
        )
    }

    var body: some View {
        let _ = store.effectiveLanguage
        VStack(spacing: 0) {
            topHUDBar

            if controller.isShowingURLConfig {
                customURLBar
            }

            ZStack {
                Color(red: 0.05, green: 0.07, blue: 0.11)
                // Below the content so buttons in empty/error states stay clickable; video and
                // still frames ignore hits and let drags fall through to it.
                WindowDragArea(onDoubleClick: { controller.toggleExpandedSize() })
                viewportContent
                if controller.isPTZEnabled {
                    CameraPTZDragSurface(
                        rotationDegrees: videoRotationDegrees,
                        onBegan: { controller.ptzDragBegan(at: $0) },
                        onMoved: { controller.ptzDragMoved(to: $0) },
                        onEnded: { controller.ptzDragEnded() },
                        onDoubleClick: { controller.toggleExpandedSize() }
                    )
                }
                VStack(spacing: 6) {
                    if let notice = controller.ptzVisibleNotice {
                        CameraPTZFailureNotice(
                            text: notice,
                            retryTitle: controller.offersPTZStopRetry
                                ? L10n.tr("再次停止", "Stop again")
                                : nil,
                            onRetry: { controller.retryFailedPTZStop() }
                        )
                    }
                    if let notice = controller.videoOnlyNotice {
                        videoOnlyNoticeBanner(notice)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controller.videoOnlyNotice)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if controller.isExpandedSize, cameras.count > 1 {
                cameraSwitcherRail
            }

            if let spec = cameraSpec {
                bottomControlsBar(spec: spec)
            }
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onChange(of: cameraSpec?.isOn) { _, _ in
            controller.reloadStream()
        }
        .onChange(of: cameraSpec?.entityId) { _, newValue in
            controller.handleCameraEntityChange(newValue)
        }
    }

    private var topHUDBar: some View {
        CameraTitleBarLayout(spacing: 6) {
            titleCluster
            toolbarTrailing
        }
        .padding(.vertical, 8)
        .background {
            ZStack {
                Color.black.opacity(0.42)
                WindowDragArea()
            }
        }
    }

    private var titleCluster: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.75), radius: 4)

            cameraTitle
                .layoutPriority(1)

            if controller.isExpandedSize, let room = device?.roomName, !room.isEmpty {
                Text(L10n.displayRoomName(room))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbarTrailing: some View {
        HStack(spacing: 4) {
            CameraLiveAudioStatusView(
                status: CameraLiveAudioStatus(streamSource: controller.streamSource, isMuted: controller.isMuted),
                isCompact: !controller.isExpandedSize,
                onExplainVideoOnly: { controller.showVideoOnlyNotice() }
            ) {
                controller.toggleMute()
            }

            CameraHUDIconButton(
                symbol: controller.isPinnedOnTop ? "pin.fill" : "pin.slash",
                isActive: controller.isPinnedOnTop,
                help: controller.isPinnedOnTop
                    ? L10n.tr("已置顶（全屏看电视时保持最前）", "Pinned on top (stays above full-screen video)")
                    : L10n.tr("点击置顶小窗", "Pin window on top")
            ) {
                controller.togglePinnedOnTop()
            }

            CameraHUDIconButton(
                symbol: "rotate.right",
                isActive: controller.videoRotation(for: device?.id) != 0,
                help: controller.videoRotation(for: device?.id) == 0
                    ? L10n.tr("顺时针旋转画面 90°（四次恢复）", "Rotate picture 90° clockwise (four clicks restore)")
                    : L10n.tr(
                        "再旋转 90°（当前 \(controller.videoRotation(for: device?.id))°）",
                        "Rotate another 90° (now \(controller.videoRotation(for: device?.id))°)"
                    )
            ) {
                controller.rotateVideo()
            }

            CameraHUDIconButton(
                symbol: controller.isMaximized
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                isActive: controller.isMaximized,
                help: controller.isMaximized
                    ? L10n.tr("恢复窗口大小", "Restore window size")
                    : L10n.tr("最大化画面窗口", "Maximize camera window")
            ) {
                controller.toggleMaximized()
            }

            toolbarOverflowMenu

            CameraHUDIconButton(
                symbol: "xmark",
                isActive: false,
                help: L10n.tr("关闭摄像头小窗", "Close camera window")
            ) {
                controller.closePanel()
            }
        }
        .padding(.trailing, 12)
    }

    private func videoOnlyNoticeBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .allowsHitTesting(false)
    }

    private var toolbarOverflowMenu: some View {
        let hasCustomURL = !(store.cameraCustomStreamURL(for: device?.id ?? "") ?? "").isEmpty
        return Menu {
            Button {
                controller.toggleExpandedSize()
            } label: {
                Label(
                    controller.isExpandedSize
                        ? L10n.tr("切换为角落迷你小窗", "Switch to compact mini window")
                        : L10n.tr("放大实时画面窗口", "Expand live view window"),
                    systemImage: controller.isExpandedSize
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
            }
            if case .liveMP4 = controller.streamSource {
                Button {
                    controller.togglePictureInPicture()
                } label: {
                    Label(
                        L10n.tr("画中画", "Picture in Picture"),
                        systemImage: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                    )
                }
                .disabled(!controller.hasLiveVideoFrame && !controller.isPictureInPictureActive)
            }
            Button {
                controller.isShowingURLConfig.toggle()
                controller.setURLFieldActive(controller.isShowingURLConfig)
            } label: {
                Label(
                    L10n.tr("配置流地址", "Stream address"),
                    systemImage: hasCustomURL || controller.isShowingURLConfig ? "checkmark" : "link"
                )
            }
            Button {
                controller.userReloadStream()
            } label: {
                Label(L10n.tr("重新连接", "Reconnect"), systemImage: "arrow.clockwise")
            }
        } label: {
            CameraHUDGlyph(symbol: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.tr("画面操作", "Picture controls"))
    }

    @ViewBuilder
    private var cameraTitle: some View {
        if cameras.count > 1 {
            Button {
                controller.presentNextCamera()
            } label: {
                Text(device?.name ?? L10n.tr("智能摄像机", "Smart Camera"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("点击切换下一台摄像机", "Click to switch to the next camera"))
        } else {
            Text(device?.name ?? L10n.tr("智能摄像机", "Smart Camera"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var cameraSwitcherRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(cameras) { camera in
                    Button {
                        store.openCameraLiveView(camera.id)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(camera.id == device?.id ? Color.cyan : Color.white.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text(camera.name)
                                .lineLimit(1)
                            if !camera.isOnline {
                                Text(L10n.tr("离线", "Offline"))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(camera.isOnline ? 0.92 : 0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                camera.id == device?.id
                                    ? Color.cyan.opacity(0.20)
                                    : Color.white.opacity(0.08)
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                camera.id == device?.id
                                    ? Color.cyan.opacity(0.55)
                                    : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!camera.isOnline)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.black.opacity(0.38))
    }

    private var customURLBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                L10n.tr("输入 HLS (.m3u8) / go2rtc / 抓拍 URL，例如 http://127.0.0.1:<port>/api/stream.m3u8?src=cam", "Enter HLS (.m3u8) / go2rtc / snapshot URL"),
                text: $controller.customURLInput
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white)
            .onSubmit {
                controller.saveCustomStreamURL()
            }

            Button(L10n.tr("连接", "Connect")) {
                controller.saveCustomStreamURL()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .cyan))

            if !(store.cameraCustomStreamURL(for: device?.id ?? "") ?? "").isEmpty {
                Button(L10n.tr("清除", "Clear")) {
                    controller.clearCustomStreamURL()
                }
                .buttonStyle(PillActionButtonStyle(tintColor: .secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08))
    }

    @ViewBuilder
    private var viewportContent: some View {
        if let spec = cameraSpec, !spec.isOn {
            VStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(L10n.tr("摄像机处于物理休眠状态", "Camera is in sleep mode"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if spec.powerWritable {
                    Button {
                        if let dev = device {
                            controller.claimDoorbellWindowForUser(claimsPlacement: false)
                            _ = store.togglePrimary(dev)
                        }
                    } label: {
                        Label(L10n.tr("唤醒镜头并观看实时画面", "Wake Camera & Watch Live"), systemImage: "video.fill")
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .cyan))
                }
            }
            .padding(20)
        } else if controller.isLoadingStream {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.tr("正在连接摄像机实时流…", "Connecting to live camera stream…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        } else if let source = controller.streamSource {
            switch source {
            case .hls(let url):
                rotatedMedia {
                    CameraHLSPlayerView(url: url, isMuted: controller.isMuted)
                }
            case .liveMP4:
                ZStack {
                    if let player = controller.videoPlayer {
                        rotatedMedia {
                            CameraLiveVideoSurface(player: player)
                                .allowsHitTesting(false)
                        }
                    }
                    if !controller.hasLiveVideoFrame {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("正在建立 P2P 加密通道并解码实时画面…", "Establishing P2P encrypted channel & decoding live video…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .mjpeg:
                if let img = controller.snapshotImage {
                    rotatedMedia {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.tr("正在建立 P2P 加密通道并解码实时画面…", "Establishing P2P encrypted channel & decoding live video…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .snapshot:
                if let img = controller.snapshotImage {
                    rotatedMedia {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.tr("正在拉取实时抓拍帧…", "Fetching live snapshot frames…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .demo:
                rotatedMedia {
                    demoLiveCanvas
                }
            }
        } else if let err = controller.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                HStack(spacing: 8) {
                    if offersMiSignIn {
                        Button {
                            controller.claimDoorbellWindowForUser(claimsPlacement: false)
                            SettingsWindowOpener.shared.show(tab: .connection)
                        } label: {
                            Label(L10n.tr("登录米家观看", "Sign in to Mi Home to Watch"), systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    }

                    Button {
                        controller.isShowingURLConfig = true
                        controller.setURLFieldActive(true)
                    } label: {
                        Label(L10n.tr("填写 go2rtc / HLS 流地址", "Set go2rtc / HLS Stream URL"), systemImage: "link.badge.plus")
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: !offersMiSignIn, tintColor: .cyan))

                    Button {
                        controller.userReloadStream()
                    } label: {
                        Label(L10n.tr("重试", "Retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillActionButtonStyle(tintColor: .secondary))

                    Button {
                        controller.copyDesensitizedDiagnostics()
                    } label: {
                        Label(L10n.tr("复制诊断", "Copy Diagnostics"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(PillActionButtonStyle(tintColor: .secondary))
                }
            }
            .padding(16)
        }
    }

    private var videoRotationDegrees: Int {
        controller.videoRotation(for: device?.id)
    }

    /// Rotates only the picture. Loading and error states stay upright so their text remains
    /// readable while a P2P stream is still connecting.
    private func rotatedMedia<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let media = content()
        return GeometryReader { proxy in
            media
                .frame(width: proxy.size.width, height: proxy.size.height)
                .rotationEffect(.degrees(Double(videoRotationDegrees)))
                .scaleEffect(
                    CameraVideoRotation.fitScale(degrees: videoRotationDegrees, in: proxy.size)
                )
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: videoRotationDegrees)
    }

    private var demoLiveCanvas: some View {
        let isNight = cameraSpec?.nightShot?.lowercased() == "on"
        return ZStack {
            LinearGradient(
                colors: isNight
                    ? [Color(red: 0.04, green: 0.14, blue: 0.10), Color(red: 0.02, green: 0.08, blue: 0.06)]
                    : [Color(red: 0.09, green: 0.16, blue: 0.28), Color(red: 0.05, green: 0.09, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Stylized room/crib silhouette & live scanline pulse
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(isNight ? "LIVE · IR NIGHT 2K" : "LIVE · 2K HDR · 25fps")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.black.opacity(0.45)))

                    Spacer()

                    Text(Self.timestampString(controller: controller, tick: demoTick))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }

                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: isNight ? "moon.stars.fill" : "video.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(isNight ? Color.green.opacity(0.85) : Color.cyan.opacity(0.85))

                    Text(
                        L10n.tr(
                            "\(device?.name ?? "客厅摄像机") · 实时看护小窗预览",
                            "\(device?.name ?? "Living Room Camera") · Live Floating Monitor"
                        )
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                    Text(
                        cameraSpec?.isMotionDetectionOn == true
                            ? L10n.tr("AI 移动与看护侦测中 · 画面正常", "AI Motion & Baby Watch Active · Clear")
                            : L10n.tr("实时画面流已就绪 · 支持跨桌面全屏置顶", "Live feed active · Pinned above full-screen apps")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.70))
                }

                Spacer()
            }
            .padding(14)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                demoTick &+= 1
            }
        }
    }

    private func bottomControlsBar(spec: CameraSpec) -> some View {
        CameraControlBarView(spec: spec, device: device, store: store, controller: controller)
    }

    private var statusDotColor: Color {
        guard let spec = cameraSpec, spec.isOn else { return .gray }
        if controller.isLoadingStream { return .orange }
        if controller.streamSource != nil { return .green }
        return .orange
    }

    private static func timestampString(controller: CameraLivePanelController, tick: Int) -> String {
        let _ = tick
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: controller.demoTimestampOverride ?? Date())
    }
}
