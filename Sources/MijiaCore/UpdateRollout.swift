import CryptoKit
import Foundation

/// Staged rollout evaluation and metadata parsing for automatic update checks (#30).
///
/// Each installation generates a local random UUID once and keeps it in `UserDefaults`.
/// The ID is never derived from hardware or account data and never leaves the device.
public enum UpdateRollout {
    public static let installIDKey = "update_rollout_install_id"
    private static let hashDomain = "menubarhome-update-rollout-v1"

    /// Returns the locally stored random install ID, generating and persisting one if absent.
    public static func installID(
        in defaults: UserDefaults,
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) -> String {
        if let existing = defaults.string(forKey: installIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = makeID().trimmingCharacters(in: .whitespacesAndNewlines)
        let finalID = generated.isEmpty ? UUID().uuidString.lowercased() : generated
        defaults.set(finalID, forKey: installIDKey)
        return finalID
    }

    /// Deterministically maps `(installID, version)` to a bucket in `0..<100`.
    ///
    /// Including the normalized version shuffles cohorts across releases while keeping a single
    /// release's cohort stable as its rollout percentage ramps from 0% to 100%.
    public static func bucket(installID: String, version: String) -> Int {
        let normalizedVersion = normalizeVersion(version)
        let trimmedID = installID.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = "\(hashDomain):\(normalizedVersion):\(trimmedID)"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int(value % 100)
    }

    /// Returns whether this installation should be offered `version` at `rolloutPercentage`.
    ///
    /// Missing percentage defaults to 100 (full rollout). Manual checks always bypass gating.
    public static func isEligible(
        installID: String,
        version: String,
        rolloutPercentage: Int?,
        manual: Bool = false
    ) -> Bool {
        if manual { return true }
        let percentage = clampPercentage(rolloutPercentage ?? 100)
        if percentage <= 0 { return false }
        if percentage >= 100 { return true }
        return bucket(installID: installID, version: version) < percentage
    }

    /// Parses an optional rollout percentage (0–100) from GitHub release metadata JSON.
    ///
    /// Checks top-level `rollout_percentage` / `rolloutPercentage` first, then falls back to an
    /// HTML comment directive (`<!-- rollout_percentage: N -->` or `<!-- rollout: N -->`) in `body`.
    public static func parseRolloutPercentage(fromReleaseObject object: [String: Any]) -> Int? {
        for key in ["rollout_percentage", "rolloutPercentage"] {
            if let raw = object[key], let parsed = parseInteger(raw) {
                return clampPercentage(parsed)
            }
        }
        if let body = object["body"] as? String {
            return parseRolloutPercentage(fromReleaseNotes: body)
        }
        return nil
    }

    /// Parses `<!-- rollout_percentage: N -->` or `<!-- rollout: N -->` (optional `%`) from release notes.
    public static func parseRolloutPercentage(fromReleaseNotes notes: String) -> Int? {
        let pattern = #"<!--\s*rollout(?:_percentage)?\s*:\s*(-?\d+)\s*%?\s*-->"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        guard let match = regex.firstMatch(in: notes, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: notes),
              let parsed = Int(notes[valueRange]) else {
            return nil
        }
        return clampPercentage(parsed)
    }

    public static func clampPercentage(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    private static func normalizeVersion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") {
            text.removeFirst()
        }
        return text
    }

    private static func parseInteger(_ raw: Any) -> Int? {
        if raw is Bool { return nil }
        if let number = raw as? NSNumber {
            #if canImport(CoreFoundation)
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            #endif
            return Int(exactly: number)
        }
        return raw as? Int
    }
}
