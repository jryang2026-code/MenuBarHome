import AppKit
import MijiaCore
import SwiftUI

/// Now Playing and the remote pad for a TV drawer. Renders nothing when the TV reports neither,
/// so drawers without them stay exactly as before.
struct TVDetailDrawer: View {
    let device: SmartDevice
    let spec: TVSpec
    let store: HomeStore
    let accent: Color
    let classic: Bool

    static func hasContent(_ spec: TVSpec) -> Bool {
        spec.playback?.hasContent == true || spec.supportsRemotePad
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let playback = spec.playback, playback.hasContent {
                TVNowPlayingView(device: device, spec: spec, playback: playback, store: store, accent: accent, classic: classic)
            }
            if spec.supportsRemotePad {
                TVRemotePadView(device: device, spec: spec, store: store, accent: accent, classic: classic)
            }
        }
    }
}

// MARK: - Now Playing

private struct TVNowPlayingView: View {
    let device: SmartDevice
    let spec: TVSpec
    let playback: MediaPlaybackState
    let store: HomeStore
    let accent: Color
    let classic: Bool

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var seekGuard = MediaSeekGuard()
    @State private var artwork: NSImage?
    @State private var isHoveringBar = false

    private var isPlaying: Bool { playback.state == .playing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                artworkView
                VStack(alignment: .leading, spacing: 3) {
                    Text(playback.title ?? playback.appName ?? L10n.tr("正在播放", "Now Playing"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        if let subtitle = playback.subtitle {
                            Text(subtitle)
                                .font(.system(size: DesignTokens.TypeSize.footnote))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let app = playback.appName, playback.title != nil {
                            Text(app)
                                .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                transportControls
            }
            progressSection
        }
        .task(id: playback.artworkURL) { await loadArtwork() }
    }

    // MARK: Artwork

    private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(
                colors: [accent.opacity(0.32), accent.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: playback.title == nil ? "tv" : "play.rectangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            LinearGradient(colors: [.white.opacity(0.35), .primary.opacity(0.08)], startPoint: .top, endPoint: .bottom),
            lineWidth: 0.75
        ))
        .shadow(color: .black.opacity(artwork == nil ? 0 : 0.18), radius: 4, y: 2)
        .animation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion), value: artwork != nil)
        .accessibilityHidden(true)
    }

    private func loadArtwork() async {
        guard let path = playback.artworkURL, spec.mediaEntityId.hasPrefix("media_player.") else {
            artwork = nil
            return
        }
        let base = store.serverURLString
        let needsBearer = !path.contains("token=")
        let data = await MediaArtworkLoader.shared.load(
            artworkPath: path,
            serverBaseURL: base,
            bearerToken: needsBearer ? store.loadHAToken() : nil,
            allowsBearer: needsBearer && HAPlaintextConsent.allowsToken(to: base, defaults: store.userDefaults)
        )
        guard !Task.isCancelled else { return }
        artwork = data.flatMap(NSImage.init(data:))
    }

    // MARK: Transport

    private var transportControls: some View {
        HStack(spacing: 2) {
            if playback.canSkipTrack {
                transportButton("backward.fill", label: L10n.tr("上一个", "Previous"), size: 12) {
                    store.sendMediaTransport(device.id, .previous)
                }
            }
            if playback.canPlayPause {
                transportButton(isPlaying ? "pause.fill" : "play.fill",
                                label: isPlaying ? L10n.tr("暂停", "Pause") : L10n.tr("播放", "Play"),
                                size: 17) {
                    store.sendMediaTransport(device.id, .playPause)
                }
                .contentTransition(.symbolEffect(.replace))
            }
            if playback.canSkipTrack {
                transportButton("forward.fill", label: L10n.tr("下一个", "Next"), size: 12) {
                    store.sendMediaTransport(device.id, .next)
                }
            }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text(label))
        .panelHelp(label)
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        switch playback.progressStyle {
        case .hidden:
            EmptyView()
        case .seekable, .readOnly:
            // Ticks only while playing, visible and not dragging; a closed panel stops the clock (#208).
            let paused = !isPlaying || seekGuard.isDragging || !store.pollingContext.panelVisible
            TimelineView(.animation(minimumInterval: 0.25, paused: paused)) { context in
                progressBar(now: context.date)
            }
        }
    }

    private func progressBar(now: Date) -> some View {
        let duration = playback.durationSec ?? 0
        let remote = playback.extrapolatedPosition(at: now)
        let shown = min(max(seekGuard.displayedPosition(remote: remote, at: now) ?? 0, 0), duration)
        let fraction = duration > 0 ? shown / duration : 0
        let seekable = playback.progressStyle == .seekable
        let thick = seekable && (isHoveringBar || seekGuard.isDragging)
        return VStack(spacing: 3) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.70), accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(thick ? 7 : 4, width * fraction))
                }
                .frame(height: thick ? 7 : (seekable ? 4 : 3))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekable ? scrubGesture(width: width, duration: duration, current: shown) : nil)
            }
            .frame(height: 14)
            .onHover { isHoveringBar = $0 }
            .animation(AppleMotion.resolve(.control, reduceMotion: reduceMotion), value: thick)
            .accessibilityElement()
            .accessibilityLabel(Text(L10n.tr("播放进度", "Playback position")))
            .accessibilityValue(Text("\(Self.format(shown)) / \(Self.format(duration))"))
            .accessibilityAdjustableAction { direction in
                guard seekable else { return }
                let step = direction == .increment ? 10.0 : -10.0
                store.seekMedia(device.id, toSeconds: shown + step)
            }

            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.system(size: DesignTokens.TypeSize.micro, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Local preview while dragging; exactly one seek on release, then a 2 s hold against snap-back.
    private func scrubGesture(width: CGFloat, duration: Double, current: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let target = Double(min(max(value.location.x / width, 0), 1)) * duration
                if seekGuard.isDragging {
                    seekGuard.updateDrag(to: target)
                } else {
                    seekGuard.beginDrag(at: target)
                }
            }
            .onEnded { _ in
                if let target = seekGuard.endDrag(now: Date()) {
                    store.seekMedia(device.id, toSeconds: target)
                }
            }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Remote pad

private struct TVRemotePadView: View {
    let device: SmartDevice
    let spec: TVSpec
    let store: HomeStore
    let accent: Color
    let classic: Bool

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private func available(_ key: TVRemoteKey) -> Bool {
        spec.remoteEntityId != nil || spec.miotRemoteActions[key.rawValue] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "appletvremote.gen4")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(L10n.tr("遥控器", "Remote"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isExpanded ? L10n.tr("已展开", "Expanded") : L10n.tr("已收起", "Collapsed")))

            if isExpanded {
                HStack(alignment: .center, spacing: 18) {
                    dPad
                    VStack(spacing: 8) {
                        sideKey(.back, symbol: "arrow.uturn.backward", label: L10n.tr("返回", "Back"))
                        sideKey(.home, symbol: "house.fill", label: L10n.tr("主页", "Home"))
                        sideKey(.menu, symbol: "line.3.horizontal", label: L10n.tr("菜单", "Menu"))
                    }
                    VStack(spacing: 8) {
                        sideKey(.volumeUp, symbol: "plus", label: L10n.tr("音量加", "Volume Up"))
                        sideKey(.mute, symbol: "speaker.slash.fill", label: L10n.tr("静音", "Mute"))
                        sideKey(.volumeDown, symbol: "minus", label: L10n.tr("音量减", "Volume Down"))
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    private var dPad: some View {
        let size: CGFloat = 104
        return ZStack {
            Circle()
                .fill(Color.primary.opacity(classic ? 0.07 : 0.05))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
            padArrow(.up, symbol: "chevron.up", label: L10n.tr("上", "Up")).offset(y: -size * 0.33)
            padArrow(.down, symbol: "chevron.down", label: L10n.tr("下", "Down")).offset(y: size * 0.33)
            padArrow(.left, symbol: "chevron.left", label: L10n.tr("左", "Left")).offset(x: -size * 0.33)
            padArrow(.right, symbol: "chevron.right", label: L10n.tr("右", "Right")).offset(x: size * 0.33)
            Button { send(.select) } label: {
                Text("OK")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .bold, design: .rounded))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(accent.opacity(0.18)))
                    .overlay(Circle().strokeBorder(accent.opacity(0.35), lineWidth: 0.75))
                    .contentShape(Circle())
            }
            .buttonStyle(RemoteKeyPressStyle(reduceMotion: reduceMotion))
            .disabled(!available(.select))
            .accessibilityLabel(Text(L10n.tr("确认", "OK")))
        }
        .frame(width: size, height: size)
    }

    private func padArrow(_ key: TVRemoteKey, symbol: String, label: String) -> some View {
        Button { send(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyPressStyle(reduceMotion: reduceMotion))
        .foregroundStyle(.primary.opacity(available(key) ? 0.85 : 0.25))
        .disabled(!available(key))
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func sideKey(_ key: TVRemoteKey, symbol: String, label: String) -> some View {
        let button = Button { send(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .frame(width: 18, height: 14)
        }
        .disabled(!available(key))
        .accessibilityLabel(Text(label))
        .panelHelp(label)
        if classic {
            button.buttonStyle(ClassicPillActionButtonStyle(tintColor: accent))
        } else {
            button.buttonStyle(PillActionButtonStyle(tintColor: accent))
        }
    }

    private func send(_ key: TVRemoteKey) {
        store.sendTVRemoteKey(device.id, key: key)
    }
}

private struct RemoteKeyPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(AppleMotion.resolve(.pressFeedback, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
