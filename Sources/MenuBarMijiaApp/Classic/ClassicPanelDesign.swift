import SwiftUI
import AppKit
import MijiaCore

// MARK: - Classic Tile Surface

/// The classic panel's tile surface: a quiet well when the device is off, one step lighter when it
/// is on, and a family-colour wash when an active device carries a tint. The classic look keeps a
/// flat fill plus the one specular edge, so it never asks the system for liquid glass.
public struct ClassicTileSurface: Equatable, Sendable {
    public var isActive: Bool
    public var tint: Color?
    public var scheme: ColorScheme

    public init(isActive: Bool, tint: Color? = nil, scheme: ColorScheme) {
        self.isActive = isActive
        self.tint = tint
        self.scheme = scheme
    }

    /// Text ink follows the window scheme in every state. An active tile earns its emphasis from
    /// the orb, a heavier weight and the fill — never from inverting the ink.
    public var ink: Color { .primary }

    public var secondaryInk: Color { .secondary }

    /// The well: translucent white over the panel glass in both appearances, or a family-colour
    /// wash when the device is on and carries a tint (contract §1.2).
    public var fill: AnyShapeStyle {
        if isActive, let tint {
            return scheme == .dark
                ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.20), Color.white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.14), Color.white.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if scheme == .dark {
            return AnyShapeStyle(Color.white.opacity(isActive ? 0.13 : 0.07))
        }
        return AnyShapeStyle(Color.white.opacity(isActive ? 0.72 : 0.42))
    }
}

// MARK: - Hold-to-Confirm All Off

/// "All Off" control: press and hold 0.6s to fire, with a filling progress sweep. It wears the
/// same quiet chip surface as its header neighbours; the sweep is the only accent.
struct ClassicHoldToConfirmButton: View {
    let title: String
    let count: Int
    let helpText: String
    let onConfirm: () -> Void
    let onTap: () -> Void

    @State private var holding = false

    var body: some View {
        let capsule = Capsule(style: .continuous)
        HStack(spacing: 4) {
            Image(systemName: "power").font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(Color.primary.opacity(0.88))
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: holding ? geo.size.width : 0)
            }
            .clipShape(capsule)
        }
        .modifier(ClassicChipSurface(shape: capsule, tint: nil, interactive: true, clear: false))
        .scaleEffect(holding ? 0.95 : 1)
        .contentShape(capsule)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 20) {
            holding = false
            // #54: a confirm that turns off the whole room deserves a level-change tap.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: 0.6) : .easeOut(duration: 0.2)) { holding = pressing }
        }
        .panelHelp(helpText)
        // VoiceOver cannot long-press easily; give it an explicit, clearly named action instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(L10n.tr("按住 0.6 秒关闭", "Hold 0.6 seconds to turn off")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.tr("关闭这 \(count) 台设备", "Turn off these \(count) devices"))) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm()
        }
    }
}

// MARK: - Classic Panel Root

/// The classic panel root: one system material behind every state, with the forced appearance and
/// the "Reduce transparency" fallback (#41). On macOS 26 the material is the system's glass slab;
/// on 14 and 15 it is `ultraThinMaterial`. Either way a scrim pins the chosen appearance, because a
/// bare material follows the wallpaper and would turn a dark panel light.
public struct ClassicPanelRoot: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    public func body(content: Content) -> some View {
        let scheme = (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme ?? systemScheme
        content
            .background {
                if reduceTransparency {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else if #available(macOS 26.0, *) {
                    // Native glass slab, kept inside the shared `adaptiveGlass` wrapper: it is the
                    // same `.regular` glass the classic panel asked for before the two themes split,
                    // and new files never touch the macOS 26 API directly.
                    Color.clear
                        .classicAdaptiveGlass(in: Rectangle())
                    Rectangle().fill(scheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.18))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.32))
                }
            }
            .environment(\.colorScheme, scheme)
    }
}

extension View {
    /// The classic panel's background, appearance pin and Reduce Transparency fallback.
    func classicPanelRoot() -> some View { modifier(ClassicPanelRoot()) }
}
