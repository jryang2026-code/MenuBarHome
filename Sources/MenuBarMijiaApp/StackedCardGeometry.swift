import SwiftUI

/// Drawing, layout reservation and swipe decisions share these dimensions.
enum StackedCardGeometry {
    static let maxVisible = 3
    static let peekReserve: CGFloat = 15
    static let dismissDistanceFraction: CGFloat = 0.4
    static let dismissVelocity: CGFloat = 800

    static func transform(depth: Int) -> (scale: CGFloat, offsetY: CGFloat, opacity: Double) {
        switch min(max(depth, 0), maxVisible - 1) {
        case 0: (1, 0, 1)
        case 1: (0.94, 8, 0.78)
        default: (0.88, 15, 0.55)
        }
    }

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
            let transform = StackedCardGeometry.transform(depth: depth)
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
            shape.fill(.clear)
                .frame(width: size.width, height: size.height)
                .adaptiveGlass(in: shape)
                .mask(alignment: .bottom) { Rectangle().frame(height: StackedCardGeometry.peekReserve) }
                .scaleEffect(transform.scale, anchor: .bottom)
                .offset(y: transform.offsetY)
                .opacity(transform.opacity)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
