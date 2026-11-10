import SwiftUI
import AppKit
import MijiaCore

// MARK: - Classic Specular Rim

/// The classic panel's one edge treatment (contract §1.3): a bright band on the top and bottom, a
/// dark one on the left and right, both squeezed into a 1 pt border so the rounded corners blend
/// them without special-casing. The gradient stop fractions are what keep each side band from
/// reaching the middle of the edge, which is why the corners read lit and the sides read shaded.
struct ClassicSpecularRim<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let strength: Double

    private var litEdge: Color {
        Color.white.opacity((colorScheme == .dark ? 0.22 : 0.65) * strength)
    }

    private var shadedEdge: Color {
        Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content.overlay {
            if reduceTransparency || contrast == .increased {
                // A translucent edge is the first thing those modes erase; one solid hairline keeps
                // the shape's boundary visible instead.
                shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            } else {
                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: litEdge, location: 0),
                            .init(color: .clear, location: 0.14),
                            .init(color: .clear, location: 0.86),
                            .init(color: litEdge, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    LinearGradient(
                        stops: [
                            .init(color: shadedEdge, location: 0),
                            .init(color: .clear, location: 0.06),
                            .init(color: .clear, location: 0.94),
                            .init(color: shadedEdge, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .mask { shape.strokeBorder(Color.white, lineWidth: 1) }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// The classic edge for every flat glass surface.
    func classicSpecularRim<S: InsettableShape>(_ shape: S, strength: Double = 1) -> some View {
        modifier(ClassicSpecularRim(shape: shape, strength: strength))
    }
}

// MARK: - Classic Pill Button Style

/// The classic pill: a quiet glass chip with one specular edge. A selected pill swaps the chip for
/// a tinted well so the row reads as one control rather than a stack of floating capsules.
public struct ClassicPillActionButtonStyle: ButtonStyle {
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
            .foregroundStyle(Color.primary.opacity(0.88))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    capsule.fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.09))
                }
            }
            .modifier(
                ClassicChipSurface(
                    shape: capsule,
                    tint: nil,
                    interactive: true,
                    clear: false,
                    isHidden: isSelected
                )
            )
            .classicSpecularRim(capsule)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Classic Panel Tile Surface

/// Classic tile surface: a flat well when the device is off, one step lighter when it is on, plus
/// the classic specular edge. The family colour, the orb and the weight carry the state; the
/// surface itself never turns opaque and never asks the system for a glass slab.
struct ClassicGlassTileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public var isActive: Bool
    public var cornerRadius: CGFloat
    public var tint: Color?

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = ClassicTileSurface(isActive: isActive, tint: tint, scheme: colorScheme)
        content
            .background {
                shape.fill(surface.fill)
            }
            .classicSpecularRim(shape)
            // One shadow carries the depth: a lit module sits above the panel, a quiet one lies flat.
            .shadowIf(
                isActive,
                color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
                radius: 10,
                y: 3
            )
            .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

extension View {
    /// The classic card well: flat fill, one specular edge, a shadow only when the device is lit.
    func classicTile(isActive: Bool, cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        modifier(ClassicGlassTileBackground(isActive: isActive, cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Classic Chip Surface

/// The classic panel's small glass chip. macOS 26 keeps the system glass (the native branch goes
/// through the shared `adaptiveGlass` wrapper); Reduce Transparency and macOS 14/15 paint the
/// historical material stack with `shape.fill` and the classic rim, so a capsule keeps the edge and
/// geometry the classic snapshots recorded instead of the liquid-glass revision.
struct ClassicChipSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool
    var clear: Bool = false
    var isHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isHidden {
            content
        } else if #available(macOS 26.0, *), !reduceTransparency {
            // The classic chip asked for regular glass on 26 even when it passed `clear`; the
            // shared wrapper is what keeps the native API out of this folder.
            content.adaptiveGlass(in: shape, tint: tint, interactive: interactive)
        } else {
            content
                .background {
                    if clear {
                        shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial))
                    } else {
                        ZStack {
                            shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                            shape.fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06)
                                    : Color.white.opacity(0.45)
                            )
                            if let tint {
                                shape.fill(tint)
                            }
                        }
                    }
                }
                .classicSpecularRim(shape)
        }
    }
}

extension View {
    /// The classic chip: system glass on macOS 26, the historical material stack before it.
    func classicAdaptiveGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        modifier(ClassicChipSurface(shape: shape, tint: tint, interactive: interactive, clear: clear))
    }
}

// MARK: - Classic Slider

/// The classic panel's slider: a 22 pt track with a 16 pt resting lens that grows to 20 pt while
/// dragging. The classic cards keep this geometry and the classic rim; the liquid-glass panel has
/// its own taller revision.
public struct ClassicLiquidGlassSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let iconName: String
    public let iconColor: Color
    public let trackFill: AnyShapeStyle
    public let isSpectrumTrack: Bool
    public let formattedValue: String

    @State private var isDragging: Bool = false

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
        // The classic lens draws its own rim; the system focus ring would fight the card.
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
        var next = value + delta
        if let step, step > 0 {
            next = (next / step).rounded() * step
        }
        let clamped = min(max(next, range.lowerBound), range.upperBound)
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
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let thumbWidth: CGFloat = isDragging ? 29 : 23
                let thumbHeight: CGFloat = isDragging ? 20 : 16
                let trackHeight: CGFloat = 22
                let usableTravel = max(width - thumbWidth - 4, 1)
                let thumbCenterX = 2 + thumbWidth / 2 + normalizedProgress * usableTravel
                let fillWidth = isSpectrumTrack ? width : max(thumbCenterX + thumbWidth / 2 - 1, trackHeight)

                ZStack(alignment: .leading) {
                    // 1. Recessed track capsule
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        .frame(height: trackHeight)
                        .overlay {
                            // Active progress fill bar or full Kelvin spectrum inside the track
                            GeometryReader { trackGeo in
                                Capsule(style: .continuous)
                                    .fill(trackFill)
                                    .frame(
                                        width: isSpectrumTrack ? trackGeo.size.width : min(fillWidth, trackGeo.size.width),
                                        height: trackHeight
                                    )
                            }
                            .clipShape(Capsule(style: .continuous))
                        }
                        .classicAdaptiveGlass(in: Capsule(style: .continuous))
                        .classicSpecularRim(Capsule(style: .continuous))

                    // 2. Refractive thumb lens
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDragging ? 0.30 : (colorScheme == .dark ? 0.78 : 0.84)),
                                    Color.white.opacity(isDragging ? 0.10 : (colorScheme == .dark ? 0.42 : 0.52))
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: thumbWidth, height: thumbHeight)
                        .classicAdaptiveGlass(in: Capsule(style: .continuous), interactive: true, clear: true)
                        .classicSpecularRim(Capsule(style: .continuous), strength: 1.4)
                        .shadow(
                            color: Color.black.opacity(isDragging ? 0.26 : 0.18),
                            radius: isDragging ? 5 : 2.5,
                            x: 0,
                            y: isDragging ? 2 : 1
                        )
                        .position(x: thumbCenterX, y: geo.size.height / 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isEnabled else { return }
                            if !isDragging {
                                withAnimation(AppleMotion.glassLensSpring) {
                                    isDragging = true
                                }
                            }
                            updateValue(at: drag.location.x, in: width, thumbWidth: thumbWidth)
                        }
                        .onEnded { _ in
                            withAnimation(AppleMotion.glassLensSpring) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: 24)

            Text(formattedValue)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.80))
                .frame(width: 42, alignment: .trailing)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private func updateValue(at x: CGFloat, in totalWidth: CGFloat, thumbWidth: CGFloat) {
        let minX = 2 + thumbWidth / 2
        let maxX = max(totalWidth - 2 - thumbWidth / 2, minX + 1)
        let clampedX = min(max(x, minX), maxX)
        let ratio = Double((clampedX - minX) / (maxX - minX))
        var raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            raw = (raw / step).rounded() * step
        }
        let finalValue = min(max(raw, range.lowerBound), range.upperBound)
        if finalValue != value {
            let previous = value
            value = finalValue
            hapticTick(from: previous, to: finalValue)
        }
    }
}
