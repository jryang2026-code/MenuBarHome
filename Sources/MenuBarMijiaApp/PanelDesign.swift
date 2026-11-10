import SwiftUI
import AppKit
import MijiaCore

// MARK: - Panel Height

/// User-chosen panel height; `.max` fills the screen below the menu bar.
///
/// Only the classic panel reads this: the Liquid Glass column always runs to the bottom of the
/// screen. The storage key predates the themes, so the choice survives a theme switch.
public enum PanelHeight: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, tall, max

    public static let storageKey = "panel_height"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: return L10n.tr("紧凑", "Compact")
        case .standard: return L10n.tr("标准", "Standard")
        case .tall: return L10n.tr("加高", "Tall")
        case .max: return L10n.tr("最大", "Max")
        }
    }

    @MainActor
    public var points: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        switch self {
        case .compact: return 460
        case .standard: return Swift.min(560, screen)
        case .tall: return Swift.min(680, screen)
        case .max: return Swift.max(460, screen)
        }
    }
}

// MARK: - Appearance

/// Panel appearance: follow the system, or force light/dark.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let storageKey = "app_appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .light: return L10n.tr("浅色", "Light")
        case .dark: return L10n.tr("深色", "Dark")
        }
    }

    /// `nil` means "use the system colour scheme".
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// `nil` inherits the system appearance on `NSWindow` / `NSView`.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Panel Theme

/// The panel's layout family.
///
/// The two themes are structural, not skins: `classic` is the compact card panel that hangs under
/// the menu-bar item, `liquidGlass` is the full-height column that slides in from the right edge.
/// The Liquid Glass theme is designed around macOS 26's native glass, so it is unavailable before
/// macOS 26. Every macOS version keeps the classic panel.
public enum PanelTheme: String, CaseIterable, Identifiable, Sendable {
    case classic
    case liquidGlass

    public static let storageKey = "panel_theme"
    public static let defaultValue: PanelTheme = .classic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return L10n.tr("常规", "Classic")
        case .liquidGlass: return L10n.tr("液态玻璃", "Liquid Glass")
        }
    }

    /// The Liquid Glass panel is built on native glass, which macOS 26 introduced.
    public static var isLiquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Resolves a stored value against platform support. Older systems always get `.classic`, and
    /// an unknown value falls back to the default. Tests pass `liquidGlassAvailable` so the
    /// fallback is exercised without a macOS 26 host.
    public static func resolved(
        from raw: String?,
        liquidGlassAvailable: Bool = isLiquidGlassAvailable
    ) -> PanelTheme {
        guard liquidGlassAvailable, let raw else { return .classic }
        return PanelTheme(rawValue: raw) ?? .classic
    }

    /// The theme the next panel presentation builds.
    public static var current: PanelTheme {
        resolved(from: UserDefaults.standard.string(forKey: storageKey))
    }
}

// MARK: - System Panel Look

/// One system design, no skins. A tile is always the same glass: a quiet well when off, one step
/// lighter when on, and a family-colour wash when on with a tint. Nothing paints an opaque slab, so
/// the ink inside a tile never has to flip against the window scheme.
public struct TileSurface: Equatable, Sendable {
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

    /// Fallback fill for Reduce Transparency and macOS 14/15 Material mode. On macOS 26 with native
    /// Liquid Glass enabled, `GlassShapeBackground` delegates directly to `ThemeAndMotion` without
    /// painting a background fill over the glass.
    public var fill: AnyShapeStyle {
        if scheme == .dark {
            return AnyShapeStyle(Color.white.opacity(isActive ? 0.14 : 0.08))
        }
        return AnyShapeStyle(Color.white.opacity(isActive ? 0.56 : 0.42))
    }
}

// MARK: - Motion Helpers

/// Status dot that breathes slowly while connected.
struct BreathingDot: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let color: Color
    let animate: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard animate, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct NoticeToastBanner: View {
    let notice: ToastNotice
    var onAction: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
                .font(.system(size: DesignTokens.TypeSize.caption))
            Text(notice.message)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(notice.isError ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: notice.isError ? 280 : nil, alignment: .leading)
            if let action = notice.action {
                Button(action.title, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    // Only a failure earns alarm red; a plain call to action stays the accent (§2.5).
                    .foregroundStyle(notice.isError ? Color.red : Color.accentColor)
            }
            if notice.isError {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
            }
        }
    }
}

@MainActor
enum ToastNoticeActions {
    /// The QR sign-in view lives inside the control-center panel, which the Settings window does
    /// not host. Tests replace this to observe the reveal without a running app.
    static var revealPanel: () -> Void = {
        MenuBarPanelController.shared.showPanel()
    }

    static func perform(_ action: ToastAction, store: HomeStore) {
        switch action.kind {
        case .presentMiReauth:
            store.presentMiReauth()
            // The QR view lives in the panel, not in Settings. Re-showing an open panel is a no-op
            // for the drop-in animation, so the panel's own toast can take this path too.
            revealPanel()
        case .openConnectionSettings:
            SettingsWindowOpener.shared.show(tab: .connection)
        }
    }
}

extension View {
    /// Adds a shadow only when `active`; a clear shadow still costs an offscreen pass per frame.
    @ViewBuilder
    func shadowIf(_ active: Bool, color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        if active { self.shadow(color: color, radius: radius, x: x, y: y) } else { self }
    }

    /// System tooltip. Kept as one wrapper so the panel can drop tooltips in one place.
    func panelHelp(_ text: String) -> some View { help(text) }
}

// MARK: - Hold-to-Confirm All Off

/// "All Off" control: press and hold 0.6s to fire, with a filling progress sweep. It wears the
/// same quiet chip surface as its header neighbours; the sweep is the only accent.
struct HoldToConfirmButton: View {
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
        .frame(height: 30)
        .overlay {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: holding ? geo.size.width : 0)
            }
            .clipShape(capsule)
            .allowsHitTesting(false)
        }
        .modifier(ChipSurface(shape: capsule, tint: nil, interactive: true, clear: false))
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

// MARK: - Panel Root

/// Transparent module host, with an opaque accessibility fallback and forced appearance.
public struct PanelRoot: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    public func body(content: Content) -> some View {
        let scheme = (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme ?? systemScheme
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .environment(\.colorScheme, scheme)
    }
}

extension View {
    public func panelRoot() -> some View { modifier(PanelRoot()) }
}

// MARK: - Panel Preferences

/// Storage keys that are not a user-visible choice but still persist between launches.
public enum PanelPrefs {
    public static let climatePanelKey = "climate_panel_module"
}
