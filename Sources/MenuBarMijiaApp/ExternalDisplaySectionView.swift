import SwiftUI
import MijiaCore

/// Panel card for external monitors controlled over DDC/CI. The panel only mounts it when
/// `ExternalDisplayStore.showsPanelCard` is true, so a disabled feature leaves the panel unchanged.
/// There is intentionally no power button (VCP 0xD6).
struct ExternalDisplaySectionView: View {
    @Bindable var store: ExternalDisplayStore
    let theme: PanelTheme

    @Environment(\.effectiveReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.displays) { display in
                ExternalDisplayCard(display: display, store: store, theme: theme, showsRefresh: display.id == store.displays.first?.id)
                    .transition(.opacity)
            }
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("external-display-error")
            }
        }
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: store.displays.map(\.id))
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: store.errorMessage)
        .accessibilityIdentifier("panel-external-displays")
    }
}

private struct ExternalDisplayCard: View {
    let display: ExternalDisplayEntry
    let store: ExternalDisplayStore
    let theme: PanelTheme
    let showsRefresh: Bool

    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private var accent: Color { .indigo }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            header
            if let brightness = display.brightnessPercent {
                slider(
                    value: brightness,
                    icon: "sun.max.fill",
                    label: L10n.tr("亮度", "Brightness")
                ) { store.setBrightness(displayId: display.id, percent: $0) }
            }
            if !display.inputSources.isEmpty {
                inputPicker
            }
            if let volume = display.volumePercent {
                HStack(spacing: 8) {
                    slider(
                        value: volume,
                        icon: display.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        label: L10n.tr("音量", "Volume")
                    ) { store.setVolume(displayId: display.id, percent: $0) }
                    muteButton
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)

        switch theme {
        case .liquidGlass:
            card.glassTile(isActive: false, cornerRadius: DesignTokens.Radius.module)
        case .classic:
            card.classicTile(isActive: false, cornerRadius: DesignTokens.Radius.module)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(display.descriptor.name)
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .lineLimit(1)
                    if display.isRedmiOrXiaomi {
                        ExternalDisplayBadge()
                    }
                }
                Text(subtitle)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if showsRefresh {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .rotationEffect(.degrees(store.isRefreshing && !reduceMotion ? 180 : 0))
                        .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.isRefreshing)
                .accessibilityLabel(Text(L10n.tr("刷新外接显示器", "Refresh external displays")))
                .panelHelp(L10n.tr("刷新外接显示器", "Refresh external displays"))
                .animation(AppleMotion.resolve(.control, reduceMotion: reduceMotion), value: store.isRefreshing)
            }
        }
    }

    private var subtitle: String {
        if let source = display.inputSource {
            return L10n.format("外接显示器 · 当前 %@", "External display · on %@", source.displayTitle)
        }
        return L10n.tr("外接显示器 · DDC/CI", "External display · DDC/CI")
    }

    private func slider(value: Int, icon: String, label: String, onChange: @escaping (Int) -> Void) -> some View {
        let binding = Binding<Double>(get: { Double(value) }, set: { onChange(Int($0.rounded())) })
        let fill = LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.92)], startPoint: .leading, endPoint: .trailing)
        return Group {
            switch theme {
            case .liquidGlass:
                LiquidGlassSlider(value: binding, in: 0...100, step: 1, iconName: icon, iconColor: accent,
                                  trackFill: fill, formattedValue: "\(value)%")
            case .classic:
                ClassicLiquidGlassSlider(value: binding, in: 0...100, step: 1, iconName: icon, iconColor: accent,
                                         trackFill: fill, formattedValue: "\(value)%")
            }
        }
        .accessibilityLabel(Text(label))
    }

    private var inputPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(display.inputSources, id: \.rawValue) { source in
                    let selected = display.inputSource == source
                    Button {
                        store.setInputSource(displayId: display.id, source: source)
                    } label: {
                        Text(source.displayTitle)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 24)
                            .background(Capsule(style: .continuous).fill(selected ? accent : Color.primary.opacity(0.07)))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.format("切换到 %@", "Switch to %@", source.displayTitle)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .animation(AppleMotion.resolve(.control, reduceMotion: reduceMotion), value: selected)
                }
            }
        }
        .accessibilityIdentifier("external-display-inputs")
    }

    private var muteButton: some View {
        let muted = display.isMuted == true
        return Button {
            store.setMute(displayId: display.id, muted: !muted)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(muted ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(muted ? accent : Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(muted ? L10n.tr("取消静音", "Unmute") : L10n.tr("静音", "Mute")))
    }
}

/// "Redmi / Xiaomi" recognition badge shared by the panel card and the settings scan summary.
struct ExternalDisplayBadge: View {
    var body: some View {
        Text(L10n.tr("小米显示器", "Xiaomi"))
            .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(Color.orange.opacity(0.14)))
            .accessibilityLabel(Text(L10n.tr("已识别为小米/Redmi 显示器", "Recognized as a Xiaomi/Redmi monitor")))
    }
}
