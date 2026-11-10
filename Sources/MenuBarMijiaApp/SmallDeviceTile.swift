import SwiftUI
import MijiaCore

/// The device orb shared by full-row headers and the 1×1 `.small` round tile: a family-tinted disc
/// when on, a neutral well when off, with the device's SF Symbol in the middle.
struct DeviceIconOrb: View {
    @Environment(\.colorScheme) private var colorScheme

    let device: SmartDevice
    let accent: Color
    let diameter: CGFloat

    private var isOn: Bool { device.isActiveOn && device.isOnline }

    private var symbolName: String {
        if case .vacuum = device.kind { return "circle.dotted.circle.fill" }
        return device.sfSymbolName
    }

    var body: some View {
        let offFill = colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        let offInk = colorScheme == .dark ? Color.white.opacity(0.68) : Color.secondary
        ZStack {
            Circle()
                .fill(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(offFill))
            Circle()
                .strokeBorder(
                    Color.white.opacity(isOn ? 0.32 : (colorScheme == .dark ? 0.16 : 0.28)),
                    lineWidth: DesignTokens.hairline
                )
            Image(systemName: symbolName)
                .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : offInk)
                .symbolEffect(.bounce, value: isOn)
        }
        .frame(width: diameter, height: diameter)
        .shadowIf(isOn, color: accent.opacity(0.38), radius: 6, y: 2)
        .animation(AppleMotion.control, value: isOn)
    }
}

/// The Option-key quick-switch number, shared by every tile size.
struct QuickIndexPill: View {
    let index: Int
    let tint: Color

    var body: some View {
        Text("\(index)")
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.label, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

/// The 1×1 round tile's fixed geometry: a 58 pt circle in the 82 pt span, around the same 42 pt
/// orb the compact capsule wears.
private enum SmallTileMetrics {
    static let diameter: CGFloat = 58
    static let orbDiameter: CGFloat = 42
}

/// A `.small` favorite: one 58 pt glass circle holding the device orb, with no label to squeeze
/// into the 82 pt quarter-row span. Hover lifts the glass and a press scales it like every other
/// card. The tooltip and VoiceOver carry the name, state and click meaning the icon cannot show.
struct SmallDeviceTile<MenuContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEditingLayout) private var isEditingLayout

    let device: SmartDevice
    let store: HomeStore
    /// The card's one spoken sentence (name, state, reading), built by `DeviceCardView`.
    let accessibilitySummary: String
    /// Pre-filtered by the Option-key/focus rule, so the tile never re-derives it.
    let quickIndex: Int?

    private let menuContent: () -> MenuContent

    init(
        device: SmartDevice,
        store: HomeStore,
        accessibilitySummary: String,
        quickIndex: Int?,
        @ViewBuilder contextMenu: @escaping () -> MenuContent
    ) {
        self.device = device
        self.store = store
        self.accessibilitySummary = accessibilitySummary
        self.quickIndex = quickIndex
        self.menuContent = contextMenu
    }

    private var accent: Color { DevicePalette.accentColor(for: device) }

    /// The same presentation state as the card surface, so the circle and the orb flip together.
    private var isLit: Bool { store.presentsAsActive(device) }

    private var isKeyboardFocused: Bool { store.focusedDeviceId == device.id }

    private var statusColor: Color {
        TileSurface(isActive: isLit, tint: nil, scheme: colorScheme).secondaryInk
    }

    /// A sensor never has an on/off phase; speak its reading instead of claiming it is off.
    private var spokenSummary: String {
        guard case .sensor(let spec) = device.kind else { return accessibilitySummary }
        switch store.readout(for: device.id) {
        case .waiting:
            return L10n.tr("\(device.name)，等待中", "\(device.name), waiting")
        case .possiblyStale:
            return L10n.tr("\(device.name)，可能过期", "\(device.name), possibly stale")
        case .live:
            break
        }
        guard device.isOnline else {
            return L10n.tr("\(device.name)，离线", "\(device.name), offline")
        }
        var parts: [String] = [device.name]
        if let t = spec.temperature {
            parts.append(L10n.format("温度 %@", "temperature %@", L10n.temperature(t, fractionDigits: 1)))
        }
        if let h = spec.humidity {
            parts.append(String(format: L10n.tr("湿度 %.0f%%", "humidity %.0f%%"), h))
        }
        if let b = spec.battery {
            parts.append(L10n.tr("电量 \(b)%", "battery \(b)%"))
        }
        if parts.count == 1 {
            let status = store.presentedStatus(for: device)
                .replacingOccurrences(of: " · ", with: L10n.tr("，", ", "))
            parts.append(status)
        }
        return parts.joined(separator: L10n.tr("，", ", "))
    }

    /// The round tile's one click keeps the wider cards' meanings: a primary switch still goes
    /// through `togglePrimary`, a camera wakes and opens its live view, a sensor opens its chart,
    /// and a card whose only control is a drawer opens that drawer.
    private func performAction() {
        guard !isEditingLayout else { return }
        if case .camera(let cam) = device.kind {
            withAnimation(AppleMotion.snappySpring) {
                if device.kind.canTogglePower, !cam.isOn {
                    _ = store.togglePrimary(device)
                }
                store.openCameraLiveView(device.id)
            }
            if device.isOnline, device.kind.canTogglePower { SoundFeedback.playSuccess() }
            return
        }
        withAnimation(AppleMotion.snappySpring) {
            if case .sensor(let spec) = device.kind, spec.temperature != nil || spec.humidity != nil {
                store.toggleExpanded(device.id)
            } else if device.isPrimaryToggleable {
                _ = store.togglePrimary(device)
            } else if store.hasDetailDrawer(for: device) {
                store.toggleExpanded(device.id)
            }
        }
        if device.isOnline, device.isPrimaryToggleable { SoundFeedback.playSuccess() }
    }

    private var helpText: String {
        if case .camera = device.kind {
            return L10n.tr("点击打开摄像头实时小窗", "Click to open live camera window")
        }
        if case .sensor(let spec) = device.kind, spec.temperature != nil || spec.humidity != nil {
            return L10n.tr("点击展开温湿度折线", "Click to expand temperature & humidity chart")
        }
        if device.isPrimaryToggleable {
            return L10n.tr("点击直接切换开关", "Click to toggle power")
        }
        if store.hasDetailDrawer(for: device) {
            return L10n.tr("点击展开详细控制", "Click to expand controls")
        }
        return L10n.tr("只读状态", "Read only")
    }

    /// The circle shows no label, so the hover tooltip names the device and its state before the
    /// action; two identical-looking tiles otherwise cannot be told apart by hovering.
    private var tooltipText: String {
        spokenSummary.isEmpty ? helpText : "\(spokenSummary) · \(helpText)"
    }

    var body: some View {
        Button(action: performAction) {
            DeviceIconOrb(device: device, accent: accent, diameter: SmallTileMetrics.orbDiameter)
                .frame(width: SmallTileMetrics.diameter, height: SmallTileMetrics.diameter)
                .glassShape(Circle(), isActive: isLit)
                .glassHoverHighlight(in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        isKeyboardFocused ? accent.opacity(0.85) : Color.clear,
                        lineWidth: 1.6
                    )
                )
                // The span is wider than the circle: centre the 58 pt tile in its column and let
                // the quick-switch hint sit in the corner without shrinking the tile.
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let quickIndex {
                        QuickIndexPill(index: quickIndex, tint: statusColor)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableCardButtonStyle())
        .opacity(device.isOnline ? 1 : 0.58)
        .accessibilityLabel(Text(spokenSummary))
        .accessibilityHint(Text(helpText))
        .panelHelp(tooltipText)
        .contextMenu { menuContent() }
    }
}
