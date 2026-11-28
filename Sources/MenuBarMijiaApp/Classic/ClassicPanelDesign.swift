import SwiftUI
import AppKit
import MijiaCore

// MARK: - Classic Design Tokens

/// The classic panel's design tokens (DESIGN.md). Spacing sits on a 4 pt grid, ink has three
/// levels, and every surface is one flat neutral layer: colour is kept for selection, lit devices
/// and alerts.
enum ClassicDesign {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// The panel's side gutter for the header, filters, list and footer.
        static let gutter: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 16
    }

    /// Device icon circle and toolbar button frames, shared so a row of icons keeps one centre line.
    static let orbSize: CGFloat = 32
    static let iconButton: CGFloat = 28

    static let secondaryInk = Color.primary.opacity(0.6)
    static let tertiaryInk = Color.primary.opacity(0.35)

    /// Neutral fill for chips, buttons and the selected filter pill.
    static func controlFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func selectedFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    }

    /// The one even outline every classic surface wears.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
}

// MARK: - Classic Tile Surface

/// The classic panel's tile surface: a quiet well when the device is off and one step lighter when
/// it is on. The family colour lives on the icon circle, never on the well.
public struct ClassicTileSurface: Equatable, Sendable {
    public var isActive: Bool
    public var tint: Color?
    public var scheme: ColorScheme

    public init(isActive: Bool, tint: Color? = nil, scheme: ColorScheme) {
        self.isActive = isActive
        self.tint = tint
        self.scheme = scheme
    }

    public var ink: Color { .primary }

    public var secondaryInk: Color { ClassicDesign.secondaryInk }

    public var fill: AnyShapeStyle {
        if scheme == .dark {
            return AnyShapeStyle(Color.white.opacity(isActive ? 0.11 : 0.06))
        }
        return AnyShapeStyle(Color.white.opacity(isActive ? 0.85 : 0.55))
    }
}

// MARK: - Hold-to-Confirm All Off

/// "All Off" control: press and hold 0.6s to fire, with a filling progress sweep. It wears the
/// same quiet chip surface as its header neighbours; the sweep is the only accent.
struct ClassicHoldToConfirmButton: View {
    let title: String
    let count: Int
    let helpText: String
    let onBeginHold: () -> HomeStore.AllOffHoldMode
    let onConfirm: (HomeStore.AllOffHoldMode) -> Void
    let onTap: () -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var holding = false
    /// Rehearsal-or-live decision, latched at press-down: SwiftUI can deliver
    /// `onPressingChanged(false)` immediately before `perform`.
    @State private var holdLatch = AllOffHoldLatch()
    /// The panel-wide hold session: Esc, focus loss and hiding invalidate it so a cancelled press
    /// cannot confirm, and `shouldSuppressTap` keeps the mouse-up from becoming a tap.
    @State private var holdSessionId: UInt64?

    var body: some View {
        let capsule = Capsule(style: .continuous)
        HStack(spacing: ClassicDesign.Space.xs) {
            Image(systemName: "power").font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(Color.primary.opacity(0.88))
        .padding(.horizontal, ClassicDesign.Space.m)
        .padding(.vertical, ClassicDesign.Space.xs)
        .frame(minHeight: ClassicDesign.iconButton)
        .background {
            // Scaling (not resizing) the fill keeps the 0.6 s sweep on the compositor.
            Rectangle()
                .fill(Color.accentColor.opacity(0.28))
                .scaleEffect(x: holding ? 1 : 0, y: 1, anchor: .leading)
                .clipShape(capsule)
        }
        .modifier(ClassicChipSurface(shape: capsule, tint: nil, interactive: true, clear: false))
        // The press dip answers at once; only the fill runs at hold speed.
        .animation(AppleMotion.resolve(.pressFeedback, reduceMotion: reduceMotion)) {
            $0.scaleEffect(holding && !reduceMotion ? 0.96 : 1)
        }
        // The fill is the hold's progress readout, so it keeps its linear sweep under Reduce Motion.
        .transaction { if reduceMotion { $0.disablesAnimations = false } }
        .contentShape(capsule)
        .onTapGesture {
            guard !PanelTransientUIState.shared.shouldSuppressTap() else { return }
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 20) {
            holding = false
            let session = holdSessionId
            holdSessionId = nil
            // A release kept the session consumable; only Esc, focus loss or hiding void it.
            guard PanelTransientUIState.shared.consumeConfirmedHold(session: session) else {
                holdLatch.reset()
                return
            }
            let mode = holdLatch.consumeOnConfirm(fallback: onBeginHold)
            // #54: a confirm that turns off the whole room deserves a level-change tap.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm(mode)
        } onPressingChanged: { pressing in
            holdLatch.pressingChanged(pressing, beginHold: onBeginHold)
            if pressing {
                holdSessionId = PanelTransientUIState.shared.beginAllOffHold {
                    holdSessionId = nil
                    holdLatch.reset()
                    withAnimation(AppleMotion.resolve(.pressFeedback, reduceMotion: reduceMotion)) { holding = false }
                }
            } else {
                // A release is not a cancel: `perform` still needs the session.
                PanelTransientUIState.shared.releaseAllOffHold(session: holdSessionId)
            }
            withAnimation(AppleMotion.resolve(pressing ? .holdProgress : .valueChange, reduceMotion: reduceMotion)) { holding = pressing }
        }
        .onDisappear {
            // Leaving the tree is an explicit cancel: a late `perform` must not fire.
            PanelTransientUIState.shared.cancelAllOffHold()
            holdSessionId = nil
            holding = false
            holdLatch.reset()
        }
        .panelHelp(helpText)
        // VoiceOver cannot long-press easily; give it an explicit, clearly named action instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(L10n.tr("按住 0.6 秒关闭", "Hold 0.6 seconds to turn off")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.tr("关闭这 \(count) 台设备", "Turn off these \(count) devices"))) {
            holdLatch.reset()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm(onBeginHold())
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
                        .adaptiveGlass(in: Rectangle())
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
