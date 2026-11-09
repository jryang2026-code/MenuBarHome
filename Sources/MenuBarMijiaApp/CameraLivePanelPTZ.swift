import AppKit
import MijiaCore
import SwiftUI

// PTZ drag driver, split from CameraLivePanelController.swift to keep that file under the
// project's 1500-line guidance.
extension CameraLivePanelController {
    // MARK: - PTZ Drag

    public var isPTZEnabled: Bool {
        ptzClientReady
            && ptzBinding != nil
            && hasLiveVideoFrame
            && !isPictureInPictureActive
    }

    var ptzTime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func ptzDragBegan(at point: CameraPTZPoint) {
        guard isPTZEnabled, let client = ptzClient, let deviceId = activeDeviceId else { return }
        finishPTZMove()
        let dragID = UUID()
        ptzDragID = dragID
        ptzDeviceId = deviceId
        ptzPlanner = CameraPTZDragPlanner()
        ptzPlanner.began(at: point, time: ptzTime)
        ptzSeq = 0
        ptzPendingDirection = nil
        let previousStop = ptzStopTask
        ptzBeginTask = Task { @MainActor [weak self] in
            // A new drag must not begin before the previous stop reached the bridge; otherwise
            // begin sees the old session active and fails (or races its stop).
            await previousStop?.value
            do {
                // Never cancelled: a cancelled request can throw after the bridge opened the
                // session, leaving no token to stop it. A finished drag stops it below instead.
                let begin = try await client.begin()
                guard let self, self.ptzDragID == dragID else {
                    try? await client.stop(token: begin.token)
                    return
                }
                self.ptzToken = begin.token
                self.ptzBeginTask = nil
                self.dismissStopRecovery()
                if let direction = self.ptzPendingDirection {
                    self.ptzPendingDirection = nil
                    self.enqueueMove(direction)
                }
            } catch {
                guard let self, self.ptzDragID == dragID else { return }
                self.showPTZNotice(error.localizedDescription)
                self.finishPTZMove(notify: false)
            }
        }
    }

    public func ptzDragMoved(to point: CameraPTZPoint) {
        guard let capability = ptzBinding?.capability, ptzDragID != nil else { return }
        let commands = ptzPlanner.moved(to: point, time: ptzTime, capability: capability)
        for command in commands {
            switch command {
            case .move(let direction):
                if ptzToken == nil {
                    ptzPendingDirection = direction
                } else {
                    ptzPendingDirection = nil
                    enqueueMove(direction)
                }
                startPTZHeartbeat()
            case .heartbeat:
                if ptzToken != nil {
                    enqueueHeartbeat()
                }
            case .stop:
                finishPTZMove()
            }
        }
    }

    public func ptzDragEnded() {
        finishPTZMove()
    }

    public func ptzDragCancelled() {
        finishPTZMove()
    }

    func enqueueMove(_ direction: CameraPTZDirection) {
        ptzSeq &+= 1
        enqueue(.move(direction, ptzSeq))
    }

    func enqueueHeartbeat() {
        ptzSeq &+= 1
        enqueue(.heartbeat(ptzSeq))
    }

    /// One request in flight and only the newest pending intent. A slow network coalesces the
    /// drag instead of replaying old directions after the user already released.
    func enqueue(_ command: CameraPTZQueuedCommand) {
        guard let next = ptzQueue.submit(command) else { return }
        run(next)
    }

    func run(_ command: CameraPTZQueuedCommand) {
        guard let client = ptzClient, let token = ptzToken, let dragID = ptzDragID else { return }
        Task { @MainActor [weak self] in
            do {
                switch command {
                case .move(let direction, let seq):
                    try await client.move(direction: direction, token: token, seq: seq)
                case .heartbeat(let seq):
                    try await client.heartbeat(token: token, seq: seq)
                }
            } catch {
                guard let self, self.ptzDragID == dragID else { return }
                self.showPTZNotice(error.localizedDescription)
                self.finishPTZMove()
            }
            guard let self, self.ptzDragID == dragID else { return }
            if let next = self.ptzQueue.complete() {
                self.run(next)
            }
        }
    }

    func startPTZHeartbeat() {
        guard ptzHeartbeatTask == nil else { return }
        let dragID = ptzDragID
        ptzHeartbeatTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.ptzDragID == dragID {
                    self.ptzHeartbeatTask = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.ptzDragID == dragID else { return }
                let commands = self.ptzPlanner.heartbeat(time: self.ptzTime)
                if commands.contains(.stop) {
                    self.finishPTZMove()
                    return
                }
                if commands.contains(.heartbeat), self.ptzToken != nil {
                    self.enqueueHeartbeat()
                }
            }
        }
    }

    /// Cancels the heartbeat and releases the bridge session first, then stops. The stop is
    /// attempted even when the move task failed. Any result is guarded by the device that
    /// started the drag, so an old stop cannot put a notice over a newly opened camera.
    func finishPTZMove(notify: Bool = true) {
        let pendingBegin = ptzBeginTask
        ptzBeginTask = nil
        ptzHeartbeatTask?.cancel()
        ptzHeartbeatTask = nil
        ptzQueue.reset()
        ptzPendingDirection = nil
        ptzDragID = nil
        let token = ptzToken
        ptzToken = nil
        let deviceId = ptzDeviceId
        ptzDeviceId = nil
        let lifecycleID = ptzLifecycleID
        _ = ptzPlanner.cancel()
        guard let token, let client = ptzClient else {
            // The begin task stops its own session; the next drag must wait for that first.
            if let pendingBegin { ptzStopTask = pendingBegin }
            return
        }
        ptzStopRecovery = .idle
        clearStopWriteFailureNotice()
        let attempt = CameraPTZStopAttempt(token: token, deviceId: deviceId, lifecycleID: lifecycleID)
        let stopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completePTZStop(client: client, attempt: attempt, notify: notify)
        }
        ptzStopTask = stopTask
    }

    func completePTZStop(
        client: any CameraPTZControlling,
        attempt: CameraPTZStopAttempt,
        notify: Bool
    ) async {
        do {
            let first = try await client.stop(token: attempt.token)
            guard stillOwns(attempt) else { return }
            if first.errorReason == nil {
                dismissStopRecovery()
                reportStopThatWasNotSent(first, notify: notify)
                return
            }
        } catch {
            guard stillOwns(attempt) else { return }
            showPTZNotice(error.localizedDescription)
            return
        }

        ptzStopRecovery = .retrying(attempt)
        await waitForAutomaticPTZStopRetry()
        guard stillOwns(attempt) else {
            if case .retrying = ptzStopRecovery { ptzStopRecovery = .idle }
            return
        }

        do {
            let second = try await client.stop(token: attempt.token)
            guard stillOwns(attempt) else { return }
            if second.errorReason == nil {
                dismissStopRecovery()
                reportStopThatWasNotSent(second, notify: notify)
                return
            }
            ptzStopRecovery = .needsManualStop(attempt)
            showPTZNotice(Self.stopWriteFailedNotice, sticky: true)
        } catch {
            guard stillOwns(attempt) else { return }
            ptzStopRecovery = .idle
            showPTZNotice(error.localizedDescription)
        }
    }

    func reportStopThatWasNotSent(_ result: CameraPTZStopResult, notify: Bool) {
        guard notify, ptzDragID == nil else { return }
        if result.mode != .step, !result.sent {
            showPTZNotice(L10n.tr("松手后未发出停止指令", "Release stop was not sent"))
        }
    }

    func waitForAutomaticPTZStopRetry() async {
        if let hold = ptzStopRetryHold {
            await hold()
            return
        }
        try? await Task.sleep(for: Self.ptzStopRetryDelay)
    }

    func stillOwns(_ attempt: CameraPTZStopAttempt) -> Bool {
        activeDeviceId == attempt.deviceId && ptzLifecycleID == attempt.lifecycleID
    }

    func retryFailedPTZStop() {
        guard !ptzManualStopInFlight, ptzDragID == nil, ptzBeginTask == nil else { return }
        guard case .needsManualStop(let attempt) = ptzStopRecovery else { return }
        guard let client = ptzClient else { return }
        ptzManualStopInFlight = true
        let task = Task { @MainActor [weak self] in
            defer { self?.ptzManualStopInFlight = false }
            let result = try? await client.stop(token: attempt.token)
            guard let self, self.stillOwns(attempt) else { return }
            guard case .needsManualStop = self.ptzStopRecovery else { return }
            if let result, result.errorReason == nil {
                self.dismissStopRecovery()
            }
        }
        ptzStopTask = task
    }

    func dismissStopRecovery() {
        ptzStopRecovery = .idle
        clearStopWriteFailureNotice()
    }

    func clearStopWriteFailureNotice() {
        guard ptzNotice == Self.stopWriteFailedNotice else { return }
        ptzNoticeTask?.cancel()
        ptzNoticeTask = nil
        ptzNotice = nil
    }

    func showPTZNotice(_ text: String?, sticky: Bool = false) {
        guard let text else { return }
        ptzNotice = text
        ptzNoticeTask?.cancel()
        ptzNoticeTask = nil
        guard !sticky else { return }
        ptzNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.ptzNotice = nil
        }
    }

    /// Losing key focus, entering PiP or hiding the panel must not leave a held motor running.
    public func windowDidResignKey(_ notification: Notification) {
        finishPTZMove()
    }

    /// Snapshot/test seam: puts the panel into a PTZ state without a bridge, a stream or any
    /// network request. Production only reaches these states through `startLiveVideo`.
    func configurePTZPreview(
        store: HomeStore? = nil,
        deviceId: String?,
        binding: CameraPTZBinding?,
        stream: CameraStreamSource?,
        notice: String?,
        ready: Bool,
        client: (any CameraPTZControlling)? = nil,
        hasFrame: Bool = true
    ) {
        ptzBeginTask = nil
        ptzHeartbeatTask?.cancel()
        ptzHeartbeatTask = nil
        ptzNoticeTask?.cancel()
        ptzNoticeTask = nil
        ptzQueue.reset()
        ptzDragID = nil
        ptzToken = nil
        ptzDeviceId = nil
        ptzStopRecovery = .idle
        ptzStopRetryHold = nil
        ptzManualStopInFlight = false
        ptzClient = client
        if let store {
            self.store = store
        }
        activeDeviceId = deviceId
        streamSource = stream
        hasLiveVideoFrame = hasFrame && stream != nil
        ptzBinding = binding
        ptzClientReady = ready
        ptzNotice = notice
        ptzLifecycleID = UUID()
        demoTimestampOverride = deviceId == nil ? nil : Date(timeIntervalSince1970: 1_700_000_000)
    }

    func clearPTZ() {
        finishPTZMove(notify: false)
        ptzLifecycleID = UUID()
        ptzBinding = nil
        ptzClient = nil
        ptzClientReady = false
        ptzNoticeTask?.cancel()
        ptzNoticeTask = nil
        ptzNotice = nil
        ptzStopRecovery = .idle
        ptzManualStopInFlight = false
    }

    static var ptzStopRetryDelay: Duration { .milliseconds(500) }

    static var stopWriteFailedNotice: String {
        L10n.tr("停止指令写入失败，云台可能仍在转动", "Stop write failed; the camera may still be moving")
    }

    var offersPTZStopRetry: Bool {
        if case .needsManualStop = ptzStopRecovery { return true }
        return ptzNotice == Self.stopWriteFailedNotice
    }

}

enum CameraPTZStopRecovery: Equatable {
    case idle
    case retrying(CameraPTZStopAttempt)
    case needsManualStop(CameraPTZStopAttempt)
}

struct CameraPTZStopAttempt: Equatable {
    var token: CameraPTZSessionToken
    var deviceId: String?
    var lifecycleID: UUID
}

struct CameraTitleBarSplit: Equatable {
    var leadingWidth: CGFloat
    var trailingWidth: CGFloat

    static func split(barWidth: CGFloat, trailingIdeal: CGFloat, spacing: CGFloat) -> CameraTitleBarSplit {
        let gap = min(max(0, spacing), max(0, barWidth))
        let available = max(0, barWidth - gap)
        let half = available / 2
        let trailing = min(max(0, trailingIdeal), half)
        let leading = available - trailing
        return CameraTitleBarSplit(leadingWidth: leading, trailingWidth: trailing)
    }
}

struct CameraTitleBarLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let compactWidth = CameraLivePanelController.compactSize.width
        let width = proposal.width ?? compactWidth
        let split = split(for: width, subviews: subviews)
        let leadingHeight = subviews.first.map {
            $0.sizeThatFits(ProposedViewSize(width: split.leadingWidth, height: proposal.height)).height
        } ?? 0
        let trailingHeight = subviews.count > 1
            ? subviews[1].sizeThatFits(ProposedViewSize(width: split.trailingWidth, height: proposal.height)).height
            : 0
        return CGSize(width: width, height: max(leadingHeight, trailingHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let split = split(for: bounds.width, subviews: subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: split.leadingWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: split.trailingWidth, height: bounds.height)
        )
    }

    private func split(for width: CGFloat, subviews: Subviews) -> CameraTitleBarSplit {
        let trailingIdeal = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified).width : 0
        return CameraTitleBarSplit.split(barWidth: width, trailingIdeal: trailingIdeal, spacing: spacing)
    }
}

struct CameraControlBar: Equatable {
    struct Power: Equatable {
        var title: String
        var isSelected: Bool
        var symbol: String
    }

    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        var isSelected: Bool
        var action: Action
    }

    enum Action: Equatable {
        case setQuality(XiaomiCameraStreamQuality)
        case toggleMotion
        case setNightShot(String)
    }

    var power: Power?
    var qualityMenuTitle: String?
    var qualityItems: [Item]
    var moreItems: [Item]

    init(spec: CameraSpec, showsQuality: Bool, currentQuality: XiaomiCameraStreamQuality) {
        if spec.powerWritable {
            power = Power(
                title: spec.isOn ? L10n.tr("镜头 开", "Lens on") : L10n.tr("镜头 关", "Lens off"),
                isSelected: spec.isOn,
                symbol: spec.isOn ? "video.fill" : "video.slash"
            )
        } else {
            power = nil
        }
        if showsQuality {
            qualityMenuTitle = "\(Self.qualityTitle(currentQuality)) ▾"
            qualityItems = XiaomiCameraStreamQuality.allCases.map { quality in
                Item(
                    id: "quality.\(quality.rawValue)",
                    title: Self.qualityTitle(quality),
                    isSelected: quality == currentQuality,
                    action: .setQuality(quality)
                )
            }
        } else {
            qualityMenuTitle = nil
            qualityItems = []
        }
        var more: [Item] = []
        if spec.motionDetectionEntityId != nil {
            more.append(Item(
                id: "motion",
                title: L10n.tr("移动侦测", "Motion detection"),
                isSelected: spec.isMotionDetectionOn == true,
                action: .toggleMotion
            ))
        }
        for mode in spec.availableNightShots {
            more.append(Item(
                id: "night.\(mode)",
                title: SmartDevice.localizeNightShot(mode),
                isSelected: spec.nightShot == mode,
                action: .setNightShot(mode)
            ))
        }
        moreItems = more
    }

    static func qualityTitle(_ quality: XiaomiCameraStreamQuality) -> String {
        switch quality {
        case .auto: return L10n.tr("自动", "Auto")
        case .sd: return L10n.tr("流畅", "SD")
        case .hd: return L10n.tr("高清", "HD")
        case .max: return L10n.tr("超清", "Ultra")
        }
    }
}

struct CameraControlBarView: View {
    let spec: CameraSpec
    let device: SmartDevice?
    let store: HomeStore
    let controller: CameraLivePanelController

    private var model: CameraControlBar {
        let deviceId = device?.id ?? ""
        let showsQuality = device != nil
            && store.deviceBackend(for: deviceId) == .xiaomiCloud
            && (store.cameraCustomStreamURL(for: deviceId) ?? "").isEmpty
        return CameraControlBar(
            spec: spec,
            showsQuality: showsQuality,
            currentQuality: store.cameraStreamQuality(for: deviceId)
        )
    }

    var body: some View {
        let bar = model
        let motion = bar.moreItems.filter { item in
            if case .toggleMotion = item.action { return true }
            return false
        }
        let night = bar.moreItems.filter { item in
            if case .setNightShot = item.action { return true }
            return false
        }
        AdaptiveGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                if let power = bar.power {
                    Button {
                        guard let device else { return }
                        _ = store.togglePrimary(device)
                    } label: {
                        Label(power.title, systemImage: power.symbol)
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: power.isSelected, tintColor: .cyan))
                    .accessibilityAddTraits(power.isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    .accessibilityRemoveTraits(power.isSelected ? AccessibilityTraits() : AccessibilityTraits.isSelected)
                }

                if let qualityMenuTitle = bar.qualityMenuTitle {
                    Menu {
                        ForEach(bar.qualityItems) { item in
                            menuButton(item)
                        }
                    } label: {
                        CameraMenuPillLabel(title: qualityMenuTitle)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !bar.moreItems.isEmpty {
                    Menu {
                        ForEach(motion) { item in
                            menuButton(item)
                        }
                        if !motion.isEmpty, !night.isEmpty {
                            Divider()
                        }
                        ForEach(night) { item in
                            menuButton(item)
                        }
                    } label: {
                        CameraMenuPillLabel(title: L10n.tr("更多 ▾", "More ▾"))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.45))
    }

    private func menuButton(_ item: CameraControlBar.Item) -> some View {
        Button {
            perform(item)
        } label: {
            if item.isSelected {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    private func perform(_ item: CameraControlBar.Item) {
        guard let device else { return }
        switch item.action {
        case .setQuality(let quality):
            store.setCameraStreamQuality(quality, for: device.id)
            controller.reloadStream()
        case .toggleMotion:
            store.setCameraMotionDetection(device.id, enabled: !item.isSelected)
        case .setNightShot(let mode):
            store.setCameraNightShot(device.id, mode: mode)
        }
    }
}

struct CameraMenuPillLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.88))
            .lineLimit(1)
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.14))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: DesignTokens.hairline)
            }
    }
}

struct CameraPTZFailureNotice: View {
    let text: String
    var retryTitle: String?
    var onRetry: () -> Void

    var body: some View {
        if let retryTitle {
            HStack(alignment: .center, spacing: 8) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.92))
            )
        } else {
            CameraPTZNoticeBanner(text: text)
        }
    }
}
