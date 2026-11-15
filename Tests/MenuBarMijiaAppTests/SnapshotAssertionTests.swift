import AppKit
import Foundation
import Testing
@testable import MenuBarMijiaApp

/// The snapshot comparator tolerates display-dependent noise and still catches real UI changes.
struct SnapshotAssertionTests {
    private static let side = 40

    /// A flat grey image; `edit` can change individual pixels.
    private static func image(edit: (_ x: Int, _ y: Int) -> UInt8? = { _, _ in nil }) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for y in 0..<side {
            for x in 0..<side {
                let v = edit(x, y).map { CGFloat($0) / 255 } ?? 200.0 / 255
                rep.setColor(NSColor(deviceRed: v, green: v, blue: v, alpha: 1), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    private static func compare(_ reference: NSImage, _ candidate: NSImage) -> String? {
        SnapshotAssertion.compare(reference, candidate, newPNG: SnapshotAssertion.pngData(for: candidate)!)
    }

    @Test("An identical render matches")
    func identicalMatches() {
        #expect(Self.compare(Self.image(), Self.image()) == nil)
    }

    @Test("Rounding noise of a few levels in every pixel still matches")
    func smallNoiseMatches() {
        #expect(Self.compare(Self.image(), Self.image { _, _ in 202 }) == nil, "2 of 255 is invisible")
        #expect(Self.compare(Self.image(), Self.image { _, _ in 203 }) == nil, "3 of 255 is the edge of the tolerance")
    }

    @Test("A handful of badly different pixels (a glyph edge) still matches")
    func fewOutliersMatch() {
        let outliers = Self.image { x, y in y == 5 && x < 40 ? 0 : nil }     // 40 pixels, far from the baseline
        #expect(Self.compare(Self.image(), outliers) == nil)
    }

    @Test("A real change that moves hundreds of pixels is caught")
    func realChangeFails() {
        let changed = Self.image { _, y in y < 8 ? 0 : nil }                  // 320 pixels
        let reason = Self.compare(Self.image(), changed)
        #expect(reason != nil)
        #expect(reason?.contains("320 pixels") == true, "the failure says how far over budget it was")
    }

    @Test("A subtle but widespread colour shift (4 levels everywhere) is caught")
    func widespreadShiftFails() {
        #expect(Self.compare(Self.image(), Self.image { _, _ in 204 }) != nil)
    }

    @Test("A different size never matches")
    func sizeMismatchFails() {
        let wider = NSImage(size: NSSize(width: 80, height: 40))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        wider.addRepresentation(rep)
        #expect(Self.compare(Self.image(), wider) != nil)
    }

    @Test("The pixel counter honours the per-channel tolerance")
    func counterHonoursTolerance() {
        let a = [UInt8](repeating: 100, count: 4 * 4 * 4)
        var b = a
        b[0] = 103                                  // within tolerance
        b[4 * 5] = 120                              // outside tolerance
        let count = a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                SnapshotAssertion.differingPixelCount(
                    reference: ap.baseAddress!, snapshot: bp.baseAddress!, width: 4, height: 4, bytesPerRow: 16
                )
            }
        }
        #expect(count == 1)
    }
}
