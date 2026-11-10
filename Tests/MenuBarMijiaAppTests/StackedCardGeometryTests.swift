import Testing
import SwiftUI
@testable import MenuBarMijiaApp

struct StackedCardGeometryTests {
    @Test func visibleDepthsAndClamping() {
        let front = StackedCardGeometry.transform(depth: 0)
        #expect(front.scale == 1 && front.offsetY == 0 && front.opacity == 1)
        let middle = StackedCardGeometry.transform(depth: 1)
        #expect(middle.scale == 0.94 && middle.offsetY == 8 && middle.opacity == 0.78)
        let back = StackedCardGeometry.transform(depth: 2)
        #expect(back.scale == 0.88 && back.offsetY == 15 && back.opacity == 0.55)
        let overflow = StackedCardGeometry.transform(depth: 8)
        #expect(overflow.scale == back.scale && overflow.offsetY == back.offsetY && overflow.opacity == back.opacity)
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
