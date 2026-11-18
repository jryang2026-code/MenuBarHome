import AppKit
import Foundation

enum SnapshotAssertion {
    /// How far a render may drift from its baseline and still count as the same picture.
    ///
    /// CI records and compares baselines on one pinned runner (macos-26-intel, Xcode 26.6, zh_CN).
    /// The numbers below were measured on a Mac with a second display attached. 78 of 92 baselines
    /// differed by at most 3 of 255 in any channel (invisible rounding), and the other 14 differed in
    /// at most 71 pixels, all SF Symbol and glyph edges. A byte-exact comparison called all 92 failures.
    /// This budget covers that edge rounding. It is not room for a different OS or Xcode.
    /// Re-record when the runner image or Xcode pin changes. Do not raise the budget instead.
    ///
    /// - `channel`: a pixel whose every channel is within this of the baseline is the same pixel.
    /// - `pixelBudget`: this many pixels beyond that may differ freely, for anti-aliased symbol edges.
    ///   A fixed count rather than a fraction, so a large window does not buy a larger allowance. A real
    ///   change (a different label, icon, colour or layout) moves far more pixels than this.
    enum Tolerance {
        static let channel = 3
        static let pixelBudget = 96
    }

    /// How many pixels differ by more than `channelTolerance` in at least one RGBA channel.
    static func differingPixelCount(
        reference: UnsafeRawPointer,
        snapshot: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        channelTolerance: Int = Tolerance.channel
    ) -> Int {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return Int.max }
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                var exceeds = false
                for channel in 0..<4 {
                    let a = Int(reference.load(fromByteOffset: offset + channel, as: UInt8.self))
                    let b = Int(snapshot.load(fromByteOffset: offset + channel, as: UInt8.self))
                    if abs(a - b) > channelTolerance { exceeds = true; break }
                }
                if exceeds { count += 1 }
            }
        }
        return count
    }

    static func sanitizePathComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private static func rasterContext(for cgImage: CGImage) -> CGContext? {
        let space = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context
    }

    static func compare(_ old: NSImage, _ new: NSImage, newPNG: Data) -> String? {
        guard let oldCG = old.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Reference image could not be loaded."
        }
        guard let newCG = new.cgImage(forProposedRect: nil, context: nil, hints: nil),
              newCG.width != 0, newCG.height != 0
        else {
            return "Newly-taken snapshot is empty."
        }
        guard new.size == old.size else {
            return "Newly-taken snapshot@\(new.size) does not match reference@\(old.size)."
        }
        guard oldCG.width == newCG.width, oldCG.height == newCG.height else {
            return "Newly-taken snapshot@(\(newCG.width)x\(newCG.height)px) does not match reference@(\(oldCG.width)x\(oldCG.height)px)."
        }
        guard let oldCtx = rasterContext(for: oldCG), let oldBytes = oldCtx.data,
              let newCtx = rasterContext(for: newCG), let newBytes = newCtx.data
        else {
            return "Snapshot pixel data could not be loaded."
        }
        let byteCount = oldCtx.height * oldCtx.bytesPerRow
        if memcmp(oldBytes, newBytes, byteCount) == 0 { return nil }
        if let roundTripped = NSImage(data: newPNG)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let rtCtx = rasterContext(for: roundTripped),
           let rtBytes = rtCtx.data,
           rtCtx.width == oldCtx.width,
           rtCtx.height == oldCtx.height {
            let rtCount = rtCtx.height * rtCtx.bytesPerRow
            if rtCount == byteCount, memcmp(oldBytes, rtBytes, rtCount) == 0 {
                return nil
            }
            if rtCount == byteCount,
               differingPixelCount(
                   reference: UnsafeRawPointer(oldBytes),
                   snapshot: UnsafeRawPointer(rtBytes),
                   width: rtCtx.width,
                   height: rtCtx.height,
                   bytesPerRow: rtCtx.bytesPerRow
               ) <= Tolerance.pixelBudget {
                return nil
            }
            let detail = firstDifferingPixel(
                reference: UnsafeRawPointer(oldBytes),
                snapshot: UnsafeRawPointer(rtBytes),
                width: rtCtx.width,
                height: rtCtx.height,
                bytesPerRow: rtCtx.bytesPerRow
            )
            let beyond = rtCount == byteCount
                ? differingPixelCount(
                    reference: UnsafeRawPointer(oldBytes),
                    snapshot: UnsafeRawPointer(rtBytes),
                    width: rtCtx.width,
                    height: rtCtx.height,
                    bytesPerRow: rtCtx.bytesPerRow
                )
                : -1
            return "Newly-taken snapshot does not match reference: \(beyond) pixels differ by more than "
                + "\(Tolerance.channel)/255 (budget \(Tolerance.pixelBudget)). \(detail)"
        }
        let detail = firstDifferingPixel(
            reference: UnsafeRawPointer(oldBytes),
            snapshot: UnsafeRawPointer(newBytes),
            width: newCtx.width,
            height: newCtx.height,
            bytesPerRow: newCtx.bytesPerRow
        )
        return "Newly-taken snapshot does not match reference. \(detail)"
    }

    private static func firstDifferingPixel(
        reference: UnsafeRawPointer,
        snapshot: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> String {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            return "Pixel buffers differ, but the bitmap stride is too small to name a pixel."
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let referenceRed = reference.load(fromByteOffset: offset, as: UInt8.self)
                let referenceGreen = reference.load(fromByteOffset: offset + 1, as: UInt8.self)
                let referenceBlue = reference.load(fromByteOffset: offset + 2, as: UInt8.self)
                let referenceAlpha = reference.load(fromByteOffset: offset + 3, as: UInt8.self)
                let snapshotRed = snapshot.load(fromByteOffset: offset, as: UInt8.self)
                let snapshotGreen = snapshot.load(fromByteOffset: offset + 1, as: UInt8.self)
                let snapshotBlue = snapshot.load(fromByteOffset: offset + 2, as: UInt8.self)
                let snapshotAlpha = snapshot.load(fromByteOffset: offset + 3, as: UInt8.self)
                if referenceRed != snapshotRed || referenceGreen != snapshotGreen
                    || referenceBlue != snapshotBlue || referenceAlpha != snapshotAlpha {
                    return "First differing pixel is (\(x), \(y)): reference rgba(\(referenceRed), \(referenceGreen), \(referenceBlue), \(referenceAlpha)), snapshot rgba(\(snapshotRed), \(snapshotGreen), \(snapshotBlue), \(snapshotAlpha))."
                }
            }
        }
        return "Pixel buffers differ, but no RGBA sample differs."
    }

    static func verifyImage(
        _ image: NSImage,
        named name: String,
        recordAll: Bool,
        snapshotDirectory: URL? = nil,
        artifactsDirectory: String? = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"],
        file: StaticString = #filePath,
        testName: String = #function
    ) -> String? {
        let fileURL = URL(fileURLWithPath: "\(file)", isDirectory: false)
        let suiteName = fileURL.deletingPathExtension().lastPathComponent
        let dirURL = snapshotDirectory ?? fileURL.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        let filename = "\(sanitizePathComponent(testName)).\(sanitizePathComponent(name)).png"
        let snapshotURL = dirURL.appendingPathComponent(filename, isDirectory: false)
        guard let newPNG = pngData(for: image) else { return "Could not encode PNG snapshot." }
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let referenceData = try Data(contentsOf: snapshotURL)
                guard let referenceImage = NSImage(data: referenceData) else {
                    // Record mode is how a corrupt baseline gets replaced, so it must not stop here.
                    if recordAll {
                        try newPNG.write(to: snapshotURL)
                        return "Record mode is on. Replaced an unreadable snapshot: \(snapshotURL.path)"
                    }
                    return "Reference image could not be loaded."
                }
                if let reason = compare(referenceImage, image, newPNG: newPNG) {
                    if recordAll {
                        try newPNG.write(to: snapshotURL)
                        return "Record mode is on. Automatically recorded snapshot: \(snapshotURL.path)\n\(reason)"
                    }
                    let artifactsRoot = URL(fileURLWithPath: artifactsDirectory ?? NSTemporaryDirectory(), isDirectory: true)
                        .appendingPathComponent(suiteName, isDirectory: true)
                    try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
                    let failedURL = artifactsRoot.appendingPathComponent(filename, isDirectory: false)
                    try newPNG.write(to: failedURL)
                    return "Snapshot \"\(name)\" does not match reference.\n\nksdiff \"\(snapshotURL.path)\" \"\(failedURL.path)\"\n\n\(reason)"
                }
                return nil
            }
            try newPNG.write(to: snapshotURL)
            return recordAll
                ? "Record mode is on. Automatically recorded snapshot: \(snapshotURL.path)"
                : "No reference was found on disk. Automatically recorded snapshot: \(snapshotURL.path)"
        } catch {
            return error.localizedDescription
        }
    }
}
