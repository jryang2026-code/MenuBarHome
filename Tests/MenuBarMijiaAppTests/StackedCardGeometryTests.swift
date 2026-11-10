import Testing
import SwiftUI
@testable import MenuBarMijiaApp

struct StackedCardGeometryTests {
    /// Notification Center's peek: 7 pt per layer, 14 then 25 pt in from each side, deeper clamps.
    @Test func peekLayersKeepFixedSideInsetsAndClamp() {
        let width: CGFloat = 350
        #expect(StackedCardGeometry.offsetY(depth: 0) == 0)
        #expect(StackedCardGeometry.scale(depth: 0, width: width) == 1)
        #expect(StackedCardGeometry.offsetY(depth: 1) == 7)
        #expect(abs(StackedCardGeometry.scale(depth: 1, width: width) * width - (width - 28)) < 0.001)
        #expect(StackedCardGeometry.offsetY(depth: 2) == 14)
        #expect(abs(StackedCardGeometry.scale(depth: 2, width: width) * width - (width - 50)) < 0.001)
        #expect(StackedCardGeometry.offsetY(depth: 8) == StackedCardGeometry.offsetY(depth: 2))
        #expect(StackedCardGeometry.scale(depth: 1, width: 0) == 1)
        #expect(StackedCardGeometry.peekReserve == 14)
    }

    @Test func unmeasuredCardHasFiniteRubberBandOffset() {
        #expect(StackedCardGeometry.rubberBand(0, width: 0) == 0)
        #expect(StackedCardGeometry.rubberBand(20, width: 0) == 0)
        #expect(StackedCardGeometry.rubberBand(-20, width: 350) < 0)
    }

    @Test func distanceOrMomentumDismissesInEitherDirection() {
        #expect(StackedCardGeometry.shouldDismiss(translation: 141, predictedTranslation: 141, velocity: 0, width: 350))
        #expect(StackedCardGeometry.shouldDismiss(translation: -20, predictedTranslation: -160, velocity: 0, width: 350))
        #expect(StackedCardGeometry.shouldDismiss(translation: 10, predictedTranslation: 10, velocity: 900, width: 350))
        #expect(!StackedCardGeometry.shouldDismiss(translation: 100, predictedTranslation: 120, velocity: 100, width: 350))
    }
}
