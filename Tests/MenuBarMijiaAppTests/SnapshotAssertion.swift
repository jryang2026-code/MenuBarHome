import AppKit
import Foundation

enum SnapshotAssertion {
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
            let detail = firstDifferingPixel(
                reference: UnsafeRawPointer(oldBytes),
                snapshot: UnsafeRawPointer(rtBytes),
                width: rtCtx.width,
                height: rtCtx.height,
                bytesPerRow: rtCtx.bytesPerRow
            )
            return "Newly-taken snapshot does not match reference. \(detail)"
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
