import SwiftUI
import MijiaCore

// MARK: - Category Glyphs

/// The settings panes' glyphs, drawn as paths instead of SF Symbols.
///
/// System Settings draws its category badges from a bespoke pictogram set, and an SF Symbol at 11 pt
/// inside a 19 pt tile reads as a different family beside them: a symbol's stroke weight is fixed, so
/// whatever fills its box at 22 pt smudges at half that. These paths are authored on a 24-unit grid
/// and stroked at a weight derived from the frame, so one shape serves both the sidebar's 11 pt and
/// the pane header's 22 pt.
///
/// They are also load-free: no asset catalogue, no image decode when the window opens. Native paths
/// were chosen over external SVG icon packs to avoid extra runtime dependencies.
enum SettingsGlyph: Sendable {
    case general
    case connection
    case assistant
    case appearance
    case privacy
    case about

    /// Glyph for the pane, so the sidebar row and the header it selects cannot drift apart.
    init(_ tab: SettingsTab) {
        switch tab {
        case .general: self = .general
        case .connection: self = .connection
        case .assistant: self = .assistant
        case .appearance: self = .appearance
        case .privacy: self = .privacy
        case .about: self = .about
        }
    }
}

/// One glyph on a 24×24 grid, split into the part that is stroked and the part that is filled.
///
/// The split exists because two of the glyphs are silhouettes (the sparkles, the half-filled disc);
/// everything else is pure stroke. Keeping both in one `Shape` means the geometry is written once and
/// the caller picks how to paint it.
struct SettingsGlyphShape: Shape {
    let glyph: SettingsGlyph
    /// `true` builds the silhouette; `false` builds the stroked lines.
    var filled: Bool = false

    /// Stroke weight as a fraction of the box; 0.085 matches System Settings' visual weight.
    static let strokeRatio: CGFloat = 0.085

    func path(in rect: CGRect) -> Path {
        let builder = Grid(rect: rect)
        return filled ? builder.fillPath(for: glyph) : builder.strokePath(for: glyph)
    }

    /// Maps the 24-unit design grid onto the frame and offers the drawing verbs the glyphs use.
    private struct Grid {
        let rect: CGRect
        let scale: CGFloat

        init(rect: CGRect) {
            self.rect = rect
            self.scale = min(rect.width, rect.height) / 24
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX - 12 * scale + x * scale,
                    y: rect.midY - 12 * scale + y * scale)
        }

        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.midX - 12 * scale + x * scale,
                   y: rect.midY - 12 * scale + y * scale,
                   width: width * scale,
                   height: height * scale)
        }

        /// A round dot of the given diameter, centred.
        func dot(_ center: (CGFloat, CGFloat), _ diameter: CGFloat) -> CGRect {
            box(center.0 - diameter / 2, center.1 - diameter / 2, diameter, diameter)
        }

        /// A sparkle: a four-point star with concave curves between the points.
        func spark(center: (CGFloat, CGFloat), radius: CGFloat, waist: CGFloat) -> Path {
            let w = radius * waist
            var path = Path()
            path.move(to: point(center.0, center.1 - radius))
            path.addQuadCurve(to: point(center.0 + radius, center.1),
                              control: point(center.0 + w, center.1 - w))
            path.addQuadCurve(to: point(center.0, center.1 + radius),
                              control: point(center.0 + w, center.1 + w))
            path.addQuadCurve(to: point(center.0 - radius, center.1),
                              control: point(center.0 - w, center.1 + w))
            path.addQuadCurve(to: point(center.0, center.1 - radius),
                              control: point(center.0 - w, center.1 - w))
            path.closeSubpath()
            return path
        }

        // MARK: Filled silhouettes

        func fillPath(for glyph: SettingsGlyph) -> Path {
            var path = Path()
            switch glyph {
            case .assistant:
                path.addPath(spark(center: (10.4, 10.4), radius: 6.4, waist: 0.28))
                path.addPath(spark(center: (18.0, 6.6), radius: 3.2, waist: 0.28))
                path.addPath(spark(center: (16.4, 17.6), radius: 2.5, waist: 0.28))
            case .appearance:
                // The right half of the disc, so light/dark reads at any size.
                path.move(to: point(12, 3.8))
                path.addArc(center: point(12, 12), radius: 8.2 * scale,
                            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                path.closeSubpath()
            default:
                break
            }
            return path
        }

        // MARK: Stroked lines

        func strokePath(for glyph: SettingsGlyph) -> Path {
            var path = Path()
            switch glyph {
            case .assistant:
                // Same silhouettes, stroked, so the weight matches its neighbours when both are drawn.
                path.addPath(spark(center: (10.4, 10.4), radius: 6.4, waist: 0.28))
                path.addPath(spark(center: (18.0, 6.6), radius: 3.2, waist: 0.28))
                path.addPath(spark(center: (16.4, 17.6), radius: 2.5, waist: 0.28))

            case .general:
                // Three sliders: one rail each, knobs staggered so the trio reads as a list.
                for index in 0..<3 {
                    let y: CGFloat = 6 + CGFloat(index) * 6
                    path.move(to: point(4, y))
                    path.addLine(to: point(20, y))
                }
                path.addEllipse(in: dot((9, 6), 5.2))
                path.addEllipse(in: dot((15, 12), 5.2))
                path.addEllipse(in: dot((8.6, 18), 5.2))

            case .connection:
                // A globe: a circle, one meridian and the equator. A link or Wi-Fi arc collapses
                // below 12 pt; a circle plus two lines survives 9.
                path.addEllipse(in: box(3.8, 3.8, 16.4, 16.4))
                path.addEllipse(in: box(7.9, 3.8, 8.2, 16.4))
                path.move(to: point(3.8, 12))
                path.addLine(to: point(20.2, 12))

            case .appearance:
                path.addEllipse(in: box(3.8, 3.8, 16.4, 16.4))

            case .privacy:
                // A padlock: shackle, body, keyhole.
                path.move(to: point(8.2, 10.4))
                path.addLine(to: point(8.2, 8.6))
                path.addArc(center: point(12, 8.6), radius: 3.8 * scale,
                            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                path.addLine(to: point(15.8, 10.4))
                path.addRoundedRect(in: box(5.6, 10.4, 12.8, 9.6),
                                    cornerSize: CGSize(width: 2.4 * scale, height: 2.4 * scale),
                                    style: .continuous)
                path.addEllipse(in: dot((12, 14.3), 3.0))
                path.move(to: point(12, 15.8))
                path.addLine(to: point(12, 17.3))

            case .about:
                path.addEllipse(in: box(3.8, 3.8, 16.4, 16.4))
                path.addEllipse(in: dot((12, 7.9), 2.6))
                path.move(to: point(12, 11.3))
                path.addLine(to: point(12, 16.3))
            }
            return path
        }
    }
}

// MARK: - Category Tile

/// The rounded, colour-filled badge System Settings puts at the head of every sidebar row and
/// repeats large in the pane header.
///
/// One component draws both sizes, so the header is literally the row's tile scaled up — that is what
/// makes selecting a row feel continuous instead of like two different controls.
struct SettingsCategoryTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let tab: SettingsTab
    var size: CGFloat = DesignTokens.Settings.sidebarIconSize

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * (DesignTokens.Settings.sidebarIconRadius
                                               / DesignTokens.Settings.sidebarIconSize),
                         style: .continuous)
    }

    private var glyphSize: CGFloat {
        size * (DesignTokens.Settings.sidebarIconGlyph / DesignTokens.Settings.sidebarIconSize)
    }

    private var stroke: CGFloat { glyphSize * SettingsGlyphShape.strokeRatio }

    private var tint: Color {
        switch tab {
        case .general: return DesignTokens.Category.general
        case .connection: return DesignTokens.Category.connection
        case .assistant: return DesignTokens.Category.assistant
        case .appearance: return DesignTokens.Category.appearance
        case .privacy: return DesignTokens.Category.privacy
        case .about: return DesignTokens.Category.about
        }
    }

    var body: some View {
        ZStack {
            shape.fill(tint)
            // One top-lit gradient stops the tile reading as flat paint on a bright sidebar without
            // turning it into a glossy button.
            shape.fill(
                LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                                        Color.white.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
            )
            glyph
                .frame(width: glyphSize, height: glyphSize)
        }
        .frame(width: size, height: size)
        .overlay {
            // A hairline of white keeps two adjacent tiles from merging on a dark sidebar.
            shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.18),
                               lineWidth: DesignTokens.hairline)
        }
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        let glyph = SettingsGlyph(tab)
        return ZStack {
            SettingsGlyphShape(glyph: glyph)
                .stroke(.white, style: StrokeStyle(lineWidth: stroke,
                                                   lineCap: .round, lineJoin: .round))
            SettingsGlyphShape(glyph: glyph, filled: true)
                .fill(.white)
        }
    }
}
