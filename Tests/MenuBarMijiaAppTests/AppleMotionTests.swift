import Testing
import SwiftUI
import AppKit
@testable import MenuBarMijiaApp

@Suite("AppleMotion token & reduce-motion resolution")
struct AppleMotionTests {
    @Test("Every token resolves to a non-spring animation under Reduce Motion")
    func reduceMotionNeverReturnsSpring() {
        for token in AppleMotion.Token.allCases {
            let reduced = AppleMotion.resolve(token, reduceMotion: true)
            let behavior = AppleMotion.reducedBehavior(for: token)
            #expect(reduced == behavior.animation, "Reduced animation mismatch for \(token.rawValue)")

            if let anim = reduced {
                let description = String(describing: anim).lowercased()
                #expect(!description.contains("spring"), "Token \(token.rawValue) returned spring under Reduce Motion: \(description)")

                switch behavior {
                case .none:
                    Issue.record("Token \(token.rawValue) has .none behavior but returned non-nil animation")
                case .crossfade(let duration):
                    #expect(anim == .easeOut(duration: duration))
                case .linear(let duration):
                    #expect(anim == .linear(duration: duration))
                }
            } else {
                #expect(behavior == .none, "Token \(token.rawValue) returned nil but behavior is \(behavior)")
            }

            // Standard spring tokens must never equal their reduced-motion fallback.
            let standard = AppleMotion.standardAnimation(for: token)
            if String(describing: standard).lowercased().contains("spring") {
                #expect(reduced != standard, "Spring token \(token.rawValue) must not keep spring under Reduce Motion")
            }
        }
    }

    @Test("Standard mode resolves each token to its standard animation")
    func standardModeMatchesTokenCurves() {
        for token in AppleMotion.Token.allCases {
            #expect(AppleMotion.resolve(token, reduceMotion: false) == AppleMotion.standardAnimation(for: token))
        }
    }

    @Test("The no-argument resolve follows the test override and otherwise the system setting")
    @MainActor
    func noArgumentResolveFollowsTestOverride() {
        let previous = AppleMotion.reduceMotionOverrideForTesting
        defer { AppleMotion.reduceMotionOverrideForTesting = previous }

        // The hook is what panel/snapshot harnesses set in place of the SwiftUI environment, so the
        // non-View callers (stores, the status-item controller) answer like the views do.
        AppleMotion.reduceMotionOverrideForTesting = true
        #expect(AppleMotion.resolve(.surface) == AppleMotion.resolve(.surface, reduceMotion: true))
        #expect(AppleMotion.resolve(.surface) == .easeOut(duration: 0.20))
        #expect(AppleMotion.resolve(.snappy) == nil)

        AppleMotion.reduceMotionOverrideForTesting = false
        #expect(AppleMotion.resolve(.snappy) == AppleMotion.standardAnimation(for: .snappy))

        // Production never sets the hook: the system setting is the fallback, unchanged.
        AppleMotion.reduceMotionOverrideForTesting = nil
        #expect(AppleMotion.resolve(.reveal) == AppleMotion.resolve(
            .reveal, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ))
    }

    @Test("Slider progress animates ~180 ms on click and has zero delay while dragging")
    func sliderClickVsDragMotion() {
        #expect(AppleMotion.sliderProgressAnimation(isPointerTracking: false, reduceMotion: false) == AppleMotion.valueChange)
        #expect(AppleMotion.sliderProgressAnimation(isPointerTracking: true, reduceMotion: false) == nil)
        #expect(AppleMotion.sliderProgressAnimation(isPointerTracking: false, reduceMotion: true) == nil)
        #expect(AppleMotion.sliderProgressAnimation(isPointerTracking: true, reduceMotion: true) == nil)

        // Track click away from thumb with zero translation animates (isPointerTracking == false).
        #expect(AppleMotion.sliderIsPointerTracking(
            wasTracking: false,
            translation: .zero,
            touchDistanceFromThumb: 60,
            thumbHalfWidth: 11
        ) == false)

        // Touch-down on the thumb immediately tracks with zero delay.
        #expect(AppleMotion.sliderIsPointerTracking(
            wasTracking: false,
            translation: .zero,
            touchDistanceFromThumb: 5,
            thumbHalfWidth: 11
        ) == true)

        // First movement beyond 1 pt tracks with zero delay even on the initial onChanged event.
        #expect(AppleMotion.sliderIsPointerTracking(
            wasTracking: false,
            translation: CGSize(width: 4, height: 0),
            touchDistanceFromThumb: 60,
            thumbHalfWidth: 11
        ) == true)

        // Once tracking, subsequent events stay in zero-delay tracking mode.
        #expect(AppleMotion.sliderIsPointerTracking(
            wasTracking: true,
            translation: .zero,
            touchDistanceFromThumb: 60,
            thumbHalfWidth: 11
        ) == true)
    }
}
