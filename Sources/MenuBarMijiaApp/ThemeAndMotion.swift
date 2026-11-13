import SwiftUI
import AppKit
import MijiaCore

// MARK: - Overridable Accessibility Environment

// macOS 26 SDK 把 accessibilityReduceMotion/Transparency 的环境键改成了只读，也没有等效修饰符；
// 快照测试需要在进程级系统设置之外强制它们的值，所以提供可写入的覆盖键：
// 默认 nil = 跟随系统，`effective*` 是所有视图统一的读取口。

private struct ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct ReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

public extension EnvironmentValues {
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }

    var reduceTransparencyOverride: Bool? {
        get { self[ReduceTransparencyOverrideKey.self] }
        set { self[ReduceTransparencyOverrideKey.self] = newValue }
    }

    var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? accessibilityReduceMotion
    }

    var effectiveReduceTransparency: Bool {
        reduceTransparencyOverride ?? accessibilityReduceTransparency
    }
}

// MARK: - Apple Design Motion Curves & Springs

public enum AppleMotion {
    /// Critically damped spring (damping ~ 0.94, response 0.26s) — smooth, interruptible, no distracting overshoot
    public static let snappySpring = Animation.spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.08)

    /// Switches, orbs and selection lenses (contract §1.6). Short enough that a toggle answers the
    /// click instead of performing for it.
    public static let control = Animation.spring(response: 0.24, dampingFraction: 0.86)

    /// Drawer expansion and grid reflow: the same character as `control`, one beat slower, because
    /// a surface that changes the layout must not snap.
    public static let reveal = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Fast ease-out for press feedback (120ms)
    public static let pressFeedback = Animation.easeOut(duration: 0.12)

    /// Liquid glass thumb expansion spring (200ms response, critically damped)
    public static let glassLensSpring = Animation.spring(response: 0.20, dampingFraction: 0.88, blendDuration: 0.05)

    /// Origin-aware drawer reveal transition (never scales from 0)
    public static var drawerTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Pressable Button Styles (Scale 0.97 on active press)

public struct PressableCardButtonStyle: ButtonStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    public var scaleAmount: CGFloat = 0.972

    public init(scaleAmount: CGFloat = 0.972) {
        self.scaleAmount = scaleAmount
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? -0.015 : 0)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Native Liquid Glass Pill Button Style

public struct PillActionButtonStyle: ButtonStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    public var isSelected: Bool = false
    public var tintColor: Color = .accentColor

    public init(isSelected: Bool = false, tintColor: Color = .accentColor) {
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        let capsule = Capsule(style: .continuous)
        return configuration.label
            .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(Color.primary.opacity(isSelected ? 0.96 : 0.88))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .modifier(
                ClassicGlass(
                    shape: capsule,
                    tint: isSelected ? tintColor.opacity(0.24) : nil,
                    interactive: true,
                    clear: false
                )
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Device Semantic Colours

public enum DevicePalette {
    /// Semantic orb colour per device family. The tile surface carries the on/off contrast, so the
    /// orb keeps its identity in both states instead of fading to grey when the device is off.
    public static func accentColor(for device: SmartDevice) -> Color {
        switch device.kind {
        case .light: return DesignTokens.Orb.light
        case .climate: return DesignTokens.Orb.climate
        case .plug: return DesignTokens.Orb.plug
        case .fan: return DesignTokens.Orb.fan
        case .vacuum: return DesignTokens.Orb.vacuum
        case .speaker: return DesignTokens.Orb.speaker
        case .tv: return DesignTokens.Orb.tv
        case .fridge: return DesignTokens.Orb.fridge
        case .camera: return DesignTokens.Orb.camera
        case .sensor: return DesignTokens.Orb.sensor
        case .cover: return DesignTokens.Orb.cover
        case .appliance: return DesignTokens.Orb.appliance
        case .generic: return DesignTokens.Orb.generic
        case .humidifier: return DesignTokens.Orb.fan
        case .valve: return DesignTokens.Orb.plug
        }
    }
}

// MARK: - Scene Semantic Colours

public enum ScenePalette {
    /// Scene pill icon tint per visual family; the model owns the category, this owns the colour.
    /// Unrecognised scene icons fall into `.light` — scene strips read as "actions" first.
    public static func tint(for category: SceneVisualCategory) -> Color {
        switch category {
        case .night: return DesignTokens.Orb.vacuum
        case .climate: return DesignTokens.Orb.fan
        case .water: return DesignTokens.Orb.climate
        case .heat: return DesignTokens.Orb.light
        case .media: return DesignTokens.Orb.speaker
        case .light: return DesignTokens.Orb.light
        }
    }
}

// MARK: - Specular Rim

/// The panel's one edge treatment (contract §1.3): a bright band on the top and bottom, a dark one
/// on the left and right, both squeezed into a 1 pt border so the rounded corners blend them without
/// special-casing. The gradient stop fractions are what keep each side band from reaching the middle
/// of the edge, which is why the corners read lit and the sides read shaded.
struct SpecularRim<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let strength: Double

    private var litEdge: Color {
        Color.white.opacity((colorScheme == .dark ? 0.34 : 0.75) * strength)
    }

    private var shadedEdge: Color {
        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content.overlay {
            if reduceTransparency || contrast == .increased {
                // A translucent edge is the first thing those modes erase; one solid hairline keeps
                // the shape's boundary visible instead. Use an exact half-height circular rounded
                // rectangle on capsules to avoid SwiftUI's 1x `Capsule` stroke tangent artifact.
                if shape is Capsule {
                    GeometryReader { geo in
                        let r = min(geo.size.width, geo.size.height) / 2
                        RoundedRectangle(cornerRadius: r, style: .circular)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: DesignTokens.hairline)
                    }
                    .allowsHitTesting(false)
                } else {
                    shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: DesignTokens.hairline)
                        .allowsHitTesting(false)
                }
            } else if shape is Capsule {
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2
                    RoundedRectangle(cornerRadius: r, style: .circular).strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: litEdge, location: 0.0),
                                .init(color: litEdge.opacity(0.25), location: 0.28),
                                .init(color: shadedEdge, location: 0.50),
                                .init(color: litEdge.opacity(0.25), location: 0.72),
                                .init(color: litEdge, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: DesignTokens.hairline
                    )
                }
                .allowsHitTesting(false)
            } else {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: litEdge, location: 0.0),
                            .init(color: litEdge.opacity(0.25), location: 0.28),
                            .init(color: shadedEdge, location: 0.50),
                            .init(color: litEdge.opacity(0.25), location: 0.72),
                            .init(color: litEdge, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: DesignTokens.hairline
                )
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// The shared edge for every glass surface. Pass `strength` to lift a control that floats above
    /// its own track.
    func specularRim<S: InsettableShape>(_ shape: S, strength: Double = 1) -> some View {
        modifier(SpecularRim(shape: shape, strength: strength))
    }
}

// MARK: - Glass Hover Highlight

/// The subtle additive lift a native macOS Control Center Liquid Glass module shows under the
/// pointer: +7/255 (~0.03 white `.plusLighter`) across the body and a faint top/bottom 2 pt rim
/// boost (+4/255 at the outer edge, fading to 0 across the middle third of the side arcs).
/// Strictly an overlay on top of the `.glassEffect` surface so the system glass slab is never
/// occluded; never changes size or shadow. Disabled while editing the layout, under Reduce
/// Transparency, or on full-row cards that host an inline slider.
struct GlassHoverHighlight<S: InsettableShape>: ViewModifier {
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.isEditingLayout) private var isEditingLayout

    let shape: S
    var isEnabled: Bool = true
    @State private var isHovering = false

    private var isLit: Bool { isEnabled && isHovering && !isEditingLayout && !reduceTransparency }

    /// Symmetric top/bottom edge boost measured from ControlCenter.app; middle third is clear.
    private var rimGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.05), location: 0.00),
                .init(color: .white.opacity(0.02), location: 0.12),
                .init(color: .clear, location: 0.33),
                .init(color: .clear, location: 0.67),
                .init(color: .white.opacity(0.02), location: 0.88),
                .init(color: .white.opacity(0.05), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay {
                highlight
                    .opacity(isLit ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.30),
                        value: isLit
                    )
                    .allowsHitTesting(false)
            }
    }

    private var highlight: some View {
        ZStack {
            fill
            rim
        }
    }

    @ViewBuilder
    private var fill: some View {
        if shape is Capsule {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: min(geo.size.width, geo.size.height) / 2, style: .circular)
                    .fill(Color.white.opacity(0.03))
            }
            .blendMode(.plusLighter)
        } else {
            shape.fill(Color.white.opacity(0.03))
                .blendMode(.plusLighter)
        }
    }

    /// `Capsule`'s 1x stroke leaves a tangent artifact; an exact half-height circular rounded
    /// rectangle draws the same outline cleanly (same workaround as `SpecularRim`).
    @ViewBuilder
    private var rim: some View {
        if shape is Capsule {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: min(geo.size.width, geo.size.height) / 2, style: .circular)
                    .strokeBorder(rimGradient, lineWidth: 1.5)
            }
            .blendMode(.plusLighter)
        } else {
            shape.strokeBorder(rimGradient, lineWidth: 1.5)
                .blendMode(.plusLighter)
        }
    }
}

extension View {
    func glassHoverHighlight<S: InsettableShape>(in shape: S, isEnabled: Bool = true) -> some View {
        modifier(GlassHoverHighlight(shape: shape, isEnabled: isEnabled))
    }

    /// Same shape choice as `glassTile`, so the highlight always matches the card's own glass.
    @ViewBuilder
    func glassHoverHighlight(cornerRadius: CGFloat, isCapsule: Bool = false, isEnabled: Bool = true) -> some View {
        if isCapsule {
            glassHoverHighlight(in: Capsule(style: .circular), isEnabled: isEnabled)
        } else {
            glassHoverHighlight(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), isEnabled: isEnabled)
        }
    }
}

// MARK: - Panel Tile Surface

/// Independent refractive module, including an opaque accessibility fallback.
public struct GlassShapeBackground<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    public var shape: S
    public var isActive: Bool
    public var tint: Color?

    public func body(content: Content) -> some View {
        surfaceBody(content)
            .animation(AppleMotion.control, value: isActive)
    }

    @ViewBuilder
    private func fillShape<Style: ShapeStyle>(_ style: Style) -> some View {
        if shape is Capsule {
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                RoundedRectangle(cornerRadius: r, style: .circular).fill(style)
            }
        } else {
            shape.fill(style)
        }
    }
    @ViewBuilder
    private func surfaceBody(_ content: Content) -> some View {
        let surface = TileSurface(isActive: isActive, tint: tint, scheme: colorScheme)
        if reduceTransparency {
            content
                .background {
                    fillShape(Color(nsColor: .controlBackgroundColor))
                    fillShape(surface.fill)
                }
                .specularRim(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 7, y: 2)
        } else if #available(macOS 26.0, *) {
            // Pure native Liquid Glass: never paint a `.background` fill before `.glassEffect`, or
            // the view's own fill sits in front of the system glass slab and blocks both desktop
            // refraction and System Settings (Tinted / Clear) adaptation.
            if let tint {
                content.glassEffect(.regular.interactive().tint(tint), in: shape)
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content
                .background {
                    ZStack {
                        fillShape(.ultraThinMaterial)
                        fillShape(surface.fill)
                        if let tint {
                            fillShape(tint.opacity(0.16))
                        }
                    }
                }
                .specularRim(shape, strength: isActive ? 1.25 : 1.0)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 8, y: 3)
        }
    }
}

/// The panel's one small glass chip: macOS 26 glass, or the material stack on 14 and 15.
struct ChipSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool
    let clear: Bool
    var isHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isHidden {
            content
        } else if #available(macOS 26.0, *), !reduceTransparency {
            if let tint {
                content.glassEffect(glassStyle.tint(tint), in: shape)
            } else {
                content.glassEffect(glassStyle, in: shape)
            }
        } else {
            content.modifier(ClassicGlass(shape: shape, tint: tint, interactive: interactive, clear: clear))
        }
    }

    @available(macOS 26.0, *)
    private var glassStyle: Glass {
        let base: Glass = clear ? .clear : .regular
        return interactive ? base.interactive() : base
    }
}
struct ClassicGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool
    let clear: Bool
    var translucentOnly = false

    @ViewBuilder
    private func fillShape<Style: ShapeStyle>(_ style: Style) -> some View {
        if shape is Capsule {
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                RoundedRectangle(cornerRadius: r, style: .circular).fill(style)
            }
        } else {
            shape.fill(style)
        }
    }
    func body(content: Content) -> some View {
        if translucentOnly {
            content
                .background { fillShape(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .white.opacity(0.14)); if let tint { fillShape(tint) } }
                .specularRim(shape)
        } else {
            content
                .background {
                    if clear {
                        fillShape(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial))
                    } else {
                        ZStack {
                            fillShape(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                            fillShape(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06)
                                    : Color.white.opacity(0.45)
                            )
                            if let tint {
                                fillShape(tint)
                            }
                        }
                    }
                }
                .specularRim(shape)
        }
    }
}

extension View {
    @ViewBuilder
    public func glassTile(isActive: Bool, cornerRadius: CGFloat, isCapsule: Bool = false, tint: Color? = nil) -> some View {
        if isCapsule {
            glassShape(Capsule(style: .circular), isActive: isActive, tint: tint)
        } else {
            glassShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), isActive: isActive, tint: tint)
        }
    }

    public func glassShape<S: InsettableShape>(_ shape: S, isActive: Bool, tint: Color? = nil) -> some View {
        modifier(GlassShapeBackground(shape: shape, isActive: isActive, tint: tint))
    }

    /// The panel's one glass chip (glass on macOS 26, thin material before it).
    public func adaptiveGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        modifier(ChipSurface(shape: shape, tint: tint, interactive: interactive, clear: clear))
    }
}

public struct AdaptiveGlassContainer<Content: View>: View {
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    /// Edit badges are drawn over the cards; a container composites its merged glass above every
    /// overlay, so while the layout is being edited the cards stand alone.
    @Environment(\.isEditingLayout) private var isEditingLayout
    public var spacing: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    public var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency, !isEditingLayout {
            // Adjacent glass shapes merge their edges only inside a container; without it every chip
            // draws its own rim and a row of buttons reads as a pile of separate panes.
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Settings Category Selection

/// One raised selection lens, shared by the settings tab rail and any picked option so both read as
/// the same object. `tint` carries the option's own colour; `isOn == false` leaves the view flat.
private struct SettingsSelectionGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let isOn: Bool

    private var selectionFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.95)
    }

    private var rimColor: Color { DesignTokens.separator.opacity(0.6) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isOn {
            content
        } else if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(selectionFill)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay { shape.strokeBorder(rimColor, lineWidth: DesignTokens.hairline) }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive().tint(tint), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.regularMaterial)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay { shape.strokeBorder(rimColor, lineWidth: DesignTokens.hairline) }
        }
    }
}

private struct SettingsGlassContainer: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}


extension View {
    func settingsGlassContainer() -> some View {
        modifier(SettingsGlassContainer())
    }

    /// The tab rail's moving lens: a plain glass capsule.
    func settingsSelectionGlass() -> some View {
        settingsSelectionGlass(in: Capsule())
    }

    /// A selection lens in any shape; pass `tint` to mark the option's own colour and
    /// `isOn: false` to leave an unselected option flat.
    func settingsSelectionGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        isOn: Bool = true
    ) -> some View {
        modifier(SettingsSelectionGlass(shape: shape, tint: tint, isOn: isOn))
    }
}

// MARK: - Apple Control Center Liquid Glass Slider

enum SliderStepSnap {
    /// Snaps `raw` onto `range.lowerBound + k * step` while keeping `range.upperBound` reachable
    /// when `(upperBound - lowerBound)` is not an exact multiple of `step` (e.g. `2000...6535`, step `100`).
    static func snap(_ raw: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let clampedRaw = min(max(raw, range.lowerBound), range.upperBound)
        guard let step, step > 0, step.isFinite else { return clampedRaw }
        let maxSteps = ((range.upperBound - range.lowerBound) / step).rounded(.down)
        let lastGrid = range.lowerBound + maxSteps * step
        if clampedRaw > lastGrid {
            let midpoint = lastGrid + (range.upperBound - lastGrid) * 0.5
            return clampedRaw >= midpoint ? range.upperBound : lastGrid
        }
        let steps = ((clampedRaw - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
    }
}

public struct LiquidGlassSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency

    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let iconName: String
    public let iconColor: Color
    public let trackFill: AnyShapeStyle
    public let isSpectrumTrack: Bool
    public let formattedValue: String

    @State private var isDragging: Bool = false
    @FocusState private var isFocused: Bool

    public init<S: ShapeStyle>(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        iconName: String,
        iconColor: Color = .secondary,
        trackFill: S,
        isSpectrumTrack: Bool = false,
        formattedValue: String
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.iconName = iconName
        self.iconColor = iconColor
        self.trackFill = AnyShapeStyle(trackFill)
        self.isSpectrumTrack = isSpectrumTrack
        self.formattedValue = formattedValue
    }

    private var normalizedProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    public var body: some View {
        bodyWithChrome
    }

    private var bodyWithChrome: some View {
        classicBody
        // #41: VoiceOver can read and adjust the custom drag slider; keyboard users can too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.tr("调节滑块", "Adjustment slider")))
        .accessibilityValue(Text(formattedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: unitStep)
            case .decrement: adjust(by: -unitStep)
            @unknown default: break
            }
        }
        .focusable()
        .focused($isFocused)
        // The capsule draws its own visible keyboard focus ring.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { adjust(by: unitStep); return .handled }
        .onKeyPress(.rightArrow) { adjust(by: unitStep); return .handled }
        .onKeyPress(.downArrow) { adjust(by: -unitStep); return .handled }
        .onKeyPress(.leftArrow) { adjust(by: -unitStep); return .handled }
    }

    /// Ten percent of the range, snapped to the declared step when there is one.
    private var unitStep: Double {
        if let step, step > 0 { return step }
        let span = range.upperBound - range.lowerBound
        return max(span * 0.1, 0.1)
    }

    private func adjust(by delta: Double) {
        guard isEnabled else { return }
        let clamped = SliderStepSnap.snap(value + delta, in: range, step: step)
        guard clamped != value else { return }
        value = clamped
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// One `.alignment` tick every 10 % of the track (0 %, 50 % and 100 % included), not per pixel.
    private func hapticTick(from old: Double, to new: Double) {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let oldBucket = Int((((old - range.lowerBound) / span) * 10).rounded(.down))
        let newBucket = Int((((new - range.lowerBound) / span) * 10).rounded(.down))
        guard oldBucket != newBucket else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private var classicBody: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let thumbWidth: CGFloat = isDragging ? 28 : 22
            let thumbHeight: CGFloat = 22
            let trackHeight: CGFloat = 28
            let usableTravel = max(width - thumbWidth - 4, 1)
            let thumbCenterX = 2 + thumbWidth / 2 + normalizedProgress * usableTravel
            let fillWidth = isSpectrumTrack ? width : max(thumbCenterX + thumbWidth / 2 - 1, trackHeight)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(trackFill)
                            .frame(width: min(fillWidth, width))
                    }
                    .clipShape(Capsule(style: .continuous))

                RoundedRectangle(cornerRadius: thumbHeight / 2, style: .circular)
                    .fill(
                        reduceTransparency
                            ? AnyShapeStyle(Color.white.opacity(colorScheme == .dark ? 0.90 : 0.96))
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isDragging ? 0.36 : (colorScheme == .dark ? 0.88 : 0.92)),
                                        Color.white.opacity(isDragging ? 0.16 : (colorScheme == .dark ? 0.58 : 0.68))
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .specularRim(Capsule(style: .circular), strength: 1.4)
                    .shadow(color: .black.opacity(isDragging ? 0.26 : 0.18), radius: isDragging ? 5 : 2.5, y: isDragging ? 2 : 1)
                    .position(x: thumbCenterX, y: geo.size.height / 2)

                HStack {
                    Image(systemName: iconName)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.leading, 9)
                    Spacer(minLength: 4)
                    Text(formattedValue)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.78))
                        .padding(.trailing, 10)
                }
                .allowsHitTesting(false)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if !isDragging {
                            withAnimation(AppleMotion.glassLensSpring) { isDragging = true }
                        }
                        updateValue(at: drag.location.x, in: width, thumbWidth: thumbWidth)
                    }
                    .onEnded { _ in
                        withAnimation(AppleMotion.glassLensSpring) { isDragging = false }
                    }
            )
        }
        .frame(height: 28)
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private func updateValue(at x: CGFloat, in totalWidth: CGFloat, thumbWidth: CGFloat) {
        let minX = 2 + thumbWidth / 2
        let maxX = max(totalWidth - 2 - thumbWidth / 2, minX + 1)
        let clampedX = min(max(x, minX), maxX)
        let ratio = Double((clampedX - minX) / (maxX - minX))
        let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        let finalValue = SliderStepSnap.snap(raw, in: range, step: step)
        if finalValue != value {
            let previous = value
            value = finalValue
            hapticTick(from: previous, to: finalValue)
        }
    }
}

// MARK: - Horizontal Strip Wheel & Trackpad Scroll

/// Routes mouse scroll-wheel and trackpad scroll gestures over registered horizontal `ScrollView`s
/// into horizontal scrolling of their backing `NSScrollView`.
@MainActor
public final class HorizontalWheelScrollMonitor {
    public static let shared = HorizontalWheelScrollMonitor()

    private let scrollViews = NSHashTable<NSScrollView>.weakObjects()
    private var localMonitor: Any?
    private weak var activeGestureScrollView: NSScrollView?
    private var isTrackingGesture = false
    private var gesturePhaseEnded = false

    private init() {}

    public func register(_ scrollView: NSScrollView) {
        if !scrollViews.contains(scrollView) {
            scrollViews.add(scrollView)
        }
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    /// Picks the dominant scroll axis (`scrollingDeltaX` when horizontal magnitude is at least
    /// vertical magnitude, otherwise `scrollingDeltaY`).
    public static func dominantDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    }

    /// Converts a raw `NSEvent` scrolling delta into a horizontal point step.
    /// Trackpads and Magic Mice report precise point deltas; notched mouse wheels report line deltas.
    public static func horizontalStep(delta: CGFloat, hasPreciseDeltas: Bool) -> CGFloat {
        guard abs(delta) > 0.001 else { return 0 }
        if hasPreciseDeltas {
            return delta
        }
        let scaled = delta * 16
        if abs(scaled) < 18 {
            return delta > 0 ? 18 : -18
        }
        return scaled
    }

    /// Clamps the next horizontal scroll offset into `0...maxOffsetX`.
    public static func clampedTargetOffset(currentX: CGFloat, step: CGFloat, maxOffsetX: CGFloat) -> CGFloat {
        guard maxOffsetX > 0 else { return 0 }
        return min(max(0, currentX - step), maxOffsetX)
    }

    @discardableResult
    public static func applyHorizontalScroll(
        to scrollView: NSScrollView,
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOffsetX = max(0, documentView.bounds.width - clipView.bounds.width)
        guard maxOffsetX > 0.5 else { return false }

        let dominant = dominantDelta(deltaX: deltaX, deltaY: deltaY)
        let step = horizontalStep(delta: dominant, hasPreciseDeltas: hasPreciseDeltas)
        guard abs(step) > 0.001 else { return false }

        let currentX = clipView.bounds.origin.x
        let targetX = clampedTargetOffset(currentX: currentX, step: step, maxOffsetX: maxOffsetX)
        guard abs(targetX - currentX) > 0.01 else { return false }

        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func hitScrollView(for event: NSEvent) -> NSScrollView? {
        guard let eventWindow = event.window else { return nil }
        let location = event.locationInWindow
        for scrollView in scrollViews.allObjects {
            guard scrollView.window === eventWindow,
                  !scrollView.isHiddenOrHasHiddenAncestor,
                  let documentView = scrollView.documentView
            else { continue }
            let maxOffsetX = documentView.bounds.width - scrollView.contentView.bounds.width
            guard maxOffsetX > 0.5 else { continue }
            let localPoint = scrollView.convert(location, from: nil)
            if scrollView.bounds.contains(localPoint) {
                return scrollView
            }
        }
        return nil
    }

    func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        let targetScrollView: NSScrollView?
        if phase.isEmpty && momentumPhase.isEmpty {
            activeGestureScrollView = nil
            isTrackingGesture = false
            gesturePhaseEnded = false
            targetScrollView = hitScrollView(for: event)
        } else {
            if phase.contains(.began) || phase.contains(.mayBegin) {
                activeGestureScrollView = hitScrollView(for: event)
                isTrackingGesture = true
                gesturePhaseEnded = false
            } else if phase.contains(.changed) {
                if !isTrackingGesture || gesturePhaseEnded {
                    activeGestureScrollView = hitScrollView(for: event)
                    isTrackingGesture = true
                    gesturePhaseEnded = false
                }
            }

            targetScrollView = activeGestureScrollView

            if phase.contains(.ended) {
                gesturePhaseEnded = true
            }
            if phase.contains(.cancelled) || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                activeGestureScrollView = nil
                isTrackingGesture = false
                gesturePhaseEnded = false
            }
        }

        guard let scrollView = targetScrollView else { return event }
        _ = Self.applyHorizontalScroll(
            to: scrollView,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        return nil
    }
}

private struct HorizontalWheelScrollAttachment: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalWheelProbeView {
        HorizontalWheelProbeView()
    }

    func updateNSView(_ nsView: HorizontalWheelProbeView, context: Context) {
        nsView.registerEnclosingScrollView()
    }
}

final class HorizontalWheelProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerEnclosingScrollView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerEnclosingScrollView()
    }

    override func layout() {
        super.layout()
        registerEnclosingScrollView()
    }

    func registerEnclosingScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        HorizontalWheelScrollMonitor.shared.register(scrollView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    /// Enables horizontal scrolling via vertical or horizontal mouse wheel / trackpad gestures
    /// when placed on the content inside a `ScrollView(.horizontal)`.
    public func horizontalWheelScroll() -> some View {
        background(HorizontalWheelScrollAttachment())
    }
}

// MARK: - Glass Controls (settings)

/// A glass switch: translucent track (tinted while on) with a white knob. Built on the system
/// `glassEffect` material so it matches Liquid Glass in both schemes and when Reduce Transparency
/// is on it falls back to a flat tinted capsule.
struct GlassSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var trackFill: Color {
        isOn ? Color.accentColor.opacity(0.78)
             : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.10)
    }

    var body: some View {
        let track = Capsule(style: .continuous)
            .fill(trackFill)
            .frame(width: 40, height: 23)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(2.5)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            }

        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                track.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            } else {
                track.overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: DesignTokens.hairline)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: isOn)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard isEnabled else { return }
            isOn.toggle()
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct GlassSwitchToggleStyle: ToggleStyle {
    static func showsLabel(glassLabelHidden: Bool, labelsHidden: Bool) -> Bool {
        !glassLabelHidden && !labelsHidden
    }

    func makeBody(configuration: Configuration) -> some View {
        GlassSwitchLabelHost(configuration: configuration)
    }
}

private struct GlassLabelHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassLabelHidden: Bool {
        get { self[GlassLabelHiddenKey.self] }
        set { self[GlassLabelHiddenKey.self] = newValue }
    }
}

extension View {
    /// Hides the label `ToggleStyle.glass` draws for a row that already shows its own title.
    /// macOS 14 exposes no `labelsVisibility`, so the style reads this value on every OS.
    func glassLabelHidden() -> some View {
        environment(\.glassLabelHidden, true)
    }
}

private struct GlassSwitchLabelHost: View {
    @Environment(\.glassLabelHidden) private var glassLabelHidden
    var configuration: ToggleStyleConfiguration

    var body: some View {
        if #available(macOS 15.0, *) {
            GlassSwitchSystemVisibilityBody(
                configuration: configuration,
                glassLabelHidden: glassLabelHidden
            )
        } else {
            GlassSwitchLabeledBody(
                configuration: configuration,
                showsLabel: GlassSwitchToggleStyle.showsLabel(
                    glassLabelHidden: glassLabelHidden,
                    labelsHidden: false
                )
            )
        }
    }
}

@available(macOS 15.0, *)
private struct GlassSwitchSystemVisibilityBody: View {
    @Environment(\.labelsVisibility) private var labelsVisibility
    var configuration: ToggleStyleConfiguration
    var glassLabelHidden: Bool

    var body: some View {
        GlassSwitchLabeledBody(
            configuration: configuration,
            showsLabel: GlassSwitchToggleStyle.showsLabel(
                glassLabelHidden: glassLabelHidden,
                labelsHidden: labelsVisibility == .hidden
            )
        )
    }
}

private struct GlassSwitchLabeledBody: View {
    @Environment(\.isEnabled) private var isEnabled
    var configuration: ToggleStyleConfiguration
    var showsLabel: Bool

    var body: some View {
        Group {
            if showsLabel {
                HStack(alignment: .center, spacing: 0) {
                    configuration.label
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .opacity(isEnabled ? 1 : 0.45)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                    Spacer(minLength: 8)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                    GlassSwitch(isOn: configuration.$isOn)
                        .layoutPriority(2)
                }
            } else {
                GlassSwitch(isOn: configuration.$isOn)
            }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func toggle() {
        guard isEnabled else { return }
        configuration.isOn.toggle()
    }
}

extension ToggleStyle where Self == GlassSwitchToggleStyle {
    static var glass: GlassSwitchToggleStyle { GlassSwitchToggleStyle() }
}

/// One glass capsule holding equal-width segments; the selected segment is a white lens.
/// Used for the settings' horizontal choices so they match the panel's room strip.
struct GlassSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct GlassSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [GlassSegment<Value>]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                row
                    .padding(3)
                    // Glass over a white card stays white; the tint under it keeps the track
                    // distinguishable from the selected lens in light mode.
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.065))
                    }
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            } else {
                row
                    .padding(3)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(DesignTokens.separator.opacity(0.5), lineWidth: DesignTokens.hairline)
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = selection == segment.value
                Button {
                    guard !isSelected else { return }
                    withAnimation(reduceMotion ? nil : AppleMotion.snappySpring) { selection = segment.value }
                } label: {
                    Text(segment.title)
                        .font(.system(
                            size: DesignTokens.TypeSize.caption,
                            weight: isSelected ? .semibold : .medium
                        ))
                        .foregroundStyle(isSelected ? DesignTokens.Ink.onLens : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
            }
        }
    }
}
