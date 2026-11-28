import SwiftUI
import AppKit
import MijiaCore

// MARK: - Classic Edge

/// The classic panel's one edge treatment (DESIGN.md §2): a single even hairline. The former
/// lit-top / shaded-side rim vanished against the light panel, so only the sides read as an edge.
struct ClassicSpecularRim<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let strength: Double

    func body(content: Content) -> some View {
        content.overlay {
            shape
                .strokeBorder(
                    contrast == .increased
                        ? Color.primary.opacity(0.25)
                        : ClassicDesign.hairline(colorScheme).opacity(min(strength, 1.5)),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
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

/// The classic pill: a flat neutral chip. A selected pill (the row's primary action) swaps it for a
/// soft well in its tint with tinted ink.
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
            // A selected pill is the row's primary action: the one place its accent is spent.
            .foregroundStyle(isSelected ? tintColor : Color.primary.opacity(0.88))
            .padding(.horizontal, ClassicDesign.Space.m)
            .padding(.vertical, ClassicDesign.Space.xs)
            .background {
                if isSelected {
                    capsule.fill(tintColor.opacity(colorScheme == .dark ? 0.24 : 0.14))
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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(AppleMotion.resolve(.pressFeedback, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Classic Panel Tile Surface

/// Classic tile surface: a flat well when the device is off, one step lighter when it is on, plus
/// the one hairline edge. The orb and the weight carry the state; there is no shadow.
struct ClassicGlassTileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceMotion) private var reduceMotion
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
            .animation(AppleMotion.resolve(.valueChange, reduceMotion: reduceMotion), value: isActive)
    }
}

extension View {
    /// The classic card well: flat fill and one hairline edge.
    func classicTile(isActive: Bool, cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        modifier(ClassicGlassTileBackground(isActive: isActive, cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Classic Chip Surface

/// The classic panel's small chip: one flat neutral fill (or the caller's tint), no glass, no rim
/// and no shadow (DESIGN.md §2). The fill has no see-through material, so Reduce Transparency keeps it.
struct ClassicChipSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let tint: Color?
    let interactive: Bool
    var clear: Bool = false
    var isHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isHidden {
            content
        } else {
            content.background {
                if let tint {
                    shape.fill(tint)
                } else {
                    shape.fill(ClassicDesign.controlFill(colorScheme))
                }
            }
        }
    }
}

extension View {
    /// The classic chip: one flat neutral fill.
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
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let iconName: String
    public let iconColor: Color
    public let trackFill: AnyShapeStyle
    public let isSpectrumTrack: Bool
    public let formattedValue: String

    @State private var isDragging: Bool = false
    @State private var isPointerTracking: Bool = false
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
        guard span > 0, span.isFinite else { return 0 }
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
        if let step, step > 0, step.isFinite { return step }
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return 0 }
        return max(span * 0.1, 0.1)
    }

    private func adjust(by delta: Double) {
        let span = range.upperBound - range.lowerBound
        guard isEnabled, span > 0, span.isFinite, delta != 0 else { return }
        let clamped = SliderStepSnap.step(from: value, by: delta, in: range, step: step)
        guard clamped != value else { return }
        value = clamped
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// One `.alignment` tick every 10 % of the track (0 %, 50 % and 100 % included), not per pixel.
    private func hapticTick(from old: Double, to new: Double) {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return }
        let oldScaled = ((old - range.lowerBound) / span) * 10
        let newScaled = ((new - range.lowerBound) / span) * 10
        guard oldScaled.isFinite, newScaled.isFinite else { return }
        let oldBucket = Int(oldScaled.rounded(.down))
        let newBucket = Int(newScaled.rounded(.down))
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
                let progressAnimation = AppleMotion.sliderProgressAnimation(
                    isPointerTracking: isPointerTracking,
                    reduceMotion: reduceMotion
                )

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
                                    .animation(progressAnimation, value: normalizedProgress)
                            }
                            .clipShape(Capsule(style: .continuous))
                        }

                    // 2. Thumb
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color(white: 0.92) : Color.white)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .shadow(color: Color.black.opacity(isDragging ? 0.22 : 0.16), radius: isDragging ? 3 : 1.5, y: 1)
                        .position(x: thumbCenterX, y: geo.size.height / 2)
                        .animation(progressAnimation, value: normalizedProgress)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isFocused ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isEnabled else { return }
                            let tracking = AppleMotion.sliderIsPointerTracking(
                                wasTracking: isPointerTracking,
                                translation: drag.translation,
                                touchDistanceFromThumb: abs(drag.location.x - thumbCenterX),
                                thumbHalfWidth: thumbWidth / 2
                            )
                            isPointerTracking = tracking
                            if !isDragging {
                                withAnimation(AppleMotion.resolve(.glassLens, reduceMotion: reduceMotion)) {
                                    isDragging = true
                                }
                            }
                            updateValue(at: drag.location.x, in: width, thumbWidth: thumbWidth)
                        }
                        .onEnded { _ in
                            isPointerTracking = false
                            withAnimation(AppleMotion.resolve(.glassLens, reduceMotion: reduceMotion)) {
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
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return }
        let minX = 2 + thumbWidth / 2
        let maxX = max(totalWidth - 2 - thumbWidth / 2, minX + 1)
        let clampedX = min(max(x, minX), maxX)
        let ratio = Double((clampedX - minX) / (maxX - minX))
        let raw = range.lowerBound + ratio * span
        let finalValue = SliderStepSnap.snap(raw, in: range, step: step)
        if finalValue != value {
            let previous = value
            value = finalValue
            hapticTick(from: previous, to: finalValue)
        }
    }
}
