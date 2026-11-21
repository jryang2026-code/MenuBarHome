import SwiftUI

/// Drawing, layout reservation and swipe decisions share these dimensions.
enum ClassicStackedCardGeometry {
    static let maxVisible = 3
    static let peekReserve: CGFloat = 15

    static func transform(depth: Int) -> (scale: CGFloat, offsetY: CGFloat, opacity: Double) {
        switch min(max(depth, 0), maxVisible - 1) {
        case 0: (1, 0, 1)
        case 1: (0.94, 8, 0.78)
        default: (0.88, 15, 0.55)
        }
    }
}

/// GeometryReader supplies the front card's current bounds in the same layout pass.
struct ClassicStackedCardBackplate: View {
    let depth: Int
    let size: CGSize

    var body: some View {
        if size.width > 0, size.height > 0 {
            let transform = ClassicStackedCardGeometry.transform(depth: depth)
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
            shape.fill(.clear)
                .frame(width: size.width, height: size.height)
                .classicAdaptiveGlass(in: shape)
                .mask(alignment: .bottom) { Rectangle().frame(height: ClassicStackedCardGeometry.peekReserve) }
                .scaleEffect(transform.scale, anchor: .bottom)
                .offset(y: transform.offsetY)
                .opacity(transform.opacity)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
