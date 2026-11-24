import Foundation

/// Policy and preference helpers for camera PiP auto-open on doorbell/alarm events
/// and pinning 1–2 related switches inside the PiP window (P1-2).
public enum CameraPipWatchPolicy {
    public static let maxPinnedSwitches = 2
    public static let defaultAutoCloseSeconds = 30
    public static let autoCloseSecondsRange = 10...300

    /// Decides whether a camera event should auto-open the floating PiP window.
    ///
    /// - Off by default: requires explicit per-camera opt-in (or global doorbell auto-popup
    ///   for `.doorbell` events).
    /// - Screen lock: never auto-opens when screen-lock control blocking is active.
    /// - Focus / Do Not Disturb (#475): mirrors `NotificationDeliveryPolicy`:
    ///   - `.doorbell` is NEVER suppressed by Focus/DND.
    ///   - Non-doorbell camera events (`.motion`, `.person`, `.package`) are suppressed
    ///     whenever Focus/DND silences non-safety notifications.
    public static func shouldAutoOpen(
        eventKind: CameraEvent.Kind,
        cameraOptIn: Bool,
        globalDoorbellAutoPopup: Bool = false,
        isScreenLocked: Bool,
        isFocusActive: Bool,
        focusFilter: FocusFilterProfile = .inactive
    ) -> Bool {
        guard !isScreenLocked else { return false }
        let optedIn: Bool = switch eventKind {
        case .doorbell:
            cameraOptIn || globalDoorbellAutoPopup
        case .motion, .person, .package:
            cameraOptIn
        }
        guard optedIn else { return false }

        switch eventKind {
        case .doorbell:
            let policy = NotificationDeliveryPolicy.resolve(
                for: .doorbell,
                isFocusActive: isFocusActive,
                focusFilter: focusFilter
            )
            return !policy.isSuppressed
        case .motion, .person, .package:
            let policy = NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: isFocusActive,
                focusFilter: focusFilter
            )
            return !policy.isSuppressed
        }
    }

    /// Deduplicates and clamps pinned switch IDs to at most `maxPinnedSwitches` (2).
    public static func sanitizePinnedSwitchIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in ids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count >= maxPinnedSwitches { break }
        }
        return result
    }

    /// Whether a device can be pinned as a quick-toggle switch button inside the camera PiP.
    /// All writes still go through `HomeStore.toggleDevice(_:)` (high-risk confirmation & lock-screen block).
    public static func isPinnableSwitch(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .light, .plug, .cover, .fan, .valve:
            return true
        default:
            return false
        }
    }

    public static func isSwitchOn(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .light(let s): return s.isOn
        case .plug(let s): return s.isOn
        case .fan(let s): return s.isOn
        case .cover(let s): return (s.positionPercent ?? 0) > 0
        case .valve(let s): return s.isOpen
        default: return false
        }
    }

    /// Whether a camera model/name represents a 3:4 portrait doorbell/cateye sensor.
    public static func isPortraitDoorbell(model: String, name: String) -> Bool {
        let m = model.lowercased()
        let modelTokens = ["doorbell", "cateye", "mjbell", "g400"]
        if modelTokens.contains(where: { m.contains($0) }) {
            return true
        }
        let n = name.lowercased()
        return n.contains("门铃") || n.contains("門鈴") || n.contains("猫眼") || n.contains("貓眼") || n.contains("doorbell")
    }
}
