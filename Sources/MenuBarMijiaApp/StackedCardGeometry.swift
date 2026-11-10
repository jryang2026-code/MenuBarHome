import SwiftUI

/// Drawing, layout reservation and swipe decisions share these dimensions. The peek follows
/// macOS Notification Center as measured on 27.2: each layer shows 7 pt below the one in front and
/// sits 14 pt, then 25 pt, in from each side; deeper layers read a step darker.
enum StackedCardGeometry {
    static let maxVisible = 3
    static let peekStep: CGFloat = 7
    static let peekReserve: CGFloat = peekStep * CGFloat(maxVisible - 1)
    static let dismissDistanceFraction: CGFloat = 0.4
    static let dismissVelocity: CGFloat = 800
    private static let sideInsets: [CGFloat] = [0, 14, 25]
    private static let opacities: [Double] = [1, 0.82, 0.62]

    private static func clamped(_ depth: Int) -> Int { min(max(depth, 0), maxVisible - 1) }

    static func offsetY(depth: Int) -> CGFloat { CGFloat(clamped(depth)) * peekStep }

    /// Width-relative, so the side inset stays 14 / 25 pt whatever the card width.
    static func scale(depth: Int, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return max(0, width - 2 * sideInsets[clamped(depth)]) / width
    }

    static func opacity(depth: Int) -> Double { opacities[clamped(depth)] }

    static func shouldDismiss(translation: CGFloat, predictedTranslation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        abs(translation) > width * dismissDistanceFraction
            || abs(predictedTranslation) > width * dismissDistanceFraction
            || abs(velocity) > dismissVelocity
    }
    static func rubberBand(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return translation * width * 0.55 / (width + 0.55 * abs(translation))
    }
}

extension AppleMotion {
    static let stack = Animation.spring(response: 0.38, dampingFraction: 0.84)
    static let dismiss = Animation.spring(response: 0.28, dampingFraction: 1)
}

/// GeometryReader supplies the front card's current bounds in the same layout pass.
struct StackedCardBackplate: View {
    let depth: Int
    let size: CGSize

    var body: some View {
        if size.width > 0, size.height > 0 {
            let offset = StackedCardGeometry.offsetY(depth: depth)
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
            shape.fill(.clear)
                .frame(width: size.width, height: size.height)
                .adaptiveGlass(in: shape)
                // Only the strip below the card in front shows, so a translucent front card never
                // reveals a second outline through its own glass.
                .mask(alignment: .bottom) { Rectangle().frame(height: offset) }
                .scaleEffect(StackedCardGeometry.scale(depth: depth, width: size.width), anchor: .bottom)
                .offset(y: offset)
                .opacity(StackedCardGeometry.opacity(depth: depth))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
