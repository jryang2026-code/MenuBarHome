import Foundation

// MARK: - Focus Filter (#575)
//
// `menumijia://` links and the panel are not the only way a Focus mode can talk to the app. macOS lets
// a Focus mode carry an app filter, configured in System Settings → 专注模式 → 添加过滤条件 →
// MenuBarHome, and the system runs `MenuBarHomeFocusFilter` when that Focus turns on. Before this,
// the app could only ask `INFocusStatusCenter` for a boolean ("some Focus is on"), which cannot tell
// 睡眠 from 工作.
//
// The filter writes this profile. Notification delivery reads it, so "睡眠专注时不要推送非安全通知"
// is a per-Focus decision the user made in System Settings rather than a global switch.
//
// The one invariant: **safety alerts and the doorbell are never dropped.** A quiet filter only
// removes routine notifications (missed timers, external-action banners, the weekly report); a
// safety alert's interruption level still follows the sensor severity table.
// `NotificationDeliveryPolicy` owns that rule, and the tests assert it for every profile shape.

/// What one Focus mode asked the app to do, as written by `MenuBarHomeFocusFilter`.
public struct FocusFilterProfile: Codable, Equatable, Sendable {
    /// True while a Focus carrying this app's filter is on.
    public var isEnabled: Bool
    /// "睡眠专注时不推送非安全通知" — the switch this feature exists for.
    public var suppressNonSafetyNotifications: Bool
    /// Optional user-assigned Focus mode label from `MenuBarHomeFocusFilter` (for example "睡眠"
    /// or "工作"), trimmed and `nil` when omitted or blank.
    public var focusModeName: String?

    public init(
        isEnabled: Bool = false,
        suppressNonSafetyNotifications: Bool = false,
        focusModeName: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.suppressNonSafetyNotifications = suppressNonSafetyNotifications
        self.focusModeName = isEnabled ? Self.normalizedModeName(focusModeName) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case suppressNonSafetyNotifications
        case focusModeName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            suppressNonSafetyNotifications: try container.decodeIfPresent(
                Bool.self,
                forKey: .suppressNonSafetyNotifications
            ) ?? false,
            focusModeName: try container.decodeIfPresent(String.self, forKey: .focusModeName)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(suppressNonSafetyNotifications, forKey: .suppressNonSafetyNotifications)
        try container.encodeIfPresent(focusModeName, forKey: .focusModeName)
    }

    /// Trims whitespace and treats empty labels as `nil`.
    public static func normalizedModeName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Mode label only while this filter is enabled.
    public var activeFocusModeName: String? {
        isEnabled ? focusModeName : nil
    }

    /// No filter configured, or no Focus carrying it is on.
    public static let inactive = FocusFilterProfile()

    /// Whether ordinary (non-safety) notifications should be dropped right now.
    ///
    /// `isFocusActive` comes from `INFocusStatusCenter`. It is part of the decision because the filter
    /// only records that a Focus with this filter *can* run: if no Focus is on at all — system Focus
    /// off, permission revoked, or the filter left enabled by an earlier Focus — nothing is quietened.
    public func suppressesNonSafetyNotifications(isFocusActive: Bool) -> Bool {
        isEnabled && suppressNonSafetyNotifications && isFocusActive
    }
}

/// Outcome of asking the system (`SetFocusFilterIntent.current`) which Focus filter is active.
public enum FocusFilterQueryResult: Equatable, Sendable {
    /// A Focus mode carrying this app's filter is active with this profile.
    case active(FocusFilterProfile)
    /// No active Focus carries this app's filter (`SetFocusFilterIntentError.notFound`).
    case notFound
    /// System query failed for another reason (transient IPC error or missing parameter).
    case unavailable
}

public enum FocusFilterStorage {
    public static let key = "focus_filter_profile_v1"
    private static let sequenceKey = "focus_filter_write_sequence_v1"
    private static let lock = NSLock()

    public static func load(defaults: UserDefaults = .standard) -> FocusFilterProfile {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(defaults: defaults)
    }

    public static func save(_ profile: FocusFilterProfile, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(profile, defaults: defaults)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(defaults: defaults)
    }

    /// Reconciles stored Focus filter state with the system's active Focus and `SetFocusFilterIntent.current`.
    ///
    /// Switching directly from Focus A (with filter) to Focus B (without filter) leaves `isFocusActive`
    /// at `true` and never triggers `perform()` again. Querying `currentFilter` surfaces `.notFound`
    /// so Focus A's quiet profile is cleared immediately instead of silencing notifications under Focus B.
    /// A write sequence check ensures a slow system query never overwrites a newer `perform()` run.
    @discardableResult
    public static func reconcile(
        isolation: isolated (any Actor)? = #isolation,
        isFocusActive: Bool?,
        currentFilter: () async -> FocusFilterQueryResult,
        defaults: UserDefaults = .standard
    ) async -> FocusFilterProfile {
        guard isFocusActive == true else {
            clear(defaults: defaults)
            return .inactive
        }

        let startSequence = currentSequence(defaults: defaults)
        let queryResult = await currentFilter()
        return applyReconcileResult(queryResult, expectedSequence: startSequence, defaults: defaults)
    }

    private static func applyReconcileResult(
        _ queryResult: FocusFilterQueryResult,
        expectedSequence: Int,
        defaults: UserDefaults
    ) -> FocusFilterProfile {
        lock.withLock {
            guard sequenceUnlocked(defaults: defaults) == expectedSequence else {
                // A `perform()` write landed while `currentFilter()` was in flight; keep the newer state.
                return loadUnlocked(defaults: defaults)
            }

            switch queryResult {
            case .active(let profile):
                saveUnlocked(profile, defaults: defaults)
                return profile
            case .notFound:
                clearUnlocked(defaults: defaults)
                return .inactive
            case .unavailable:
                return loadUnlocked(defaults: defaults)
            }
        }
    }

    private static func currentSequence(defaults: UserDefaults) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sequenceUnlocked(defaults: defaults)
    }

    private static func sequenceUnlocked(defaults: UserDefaults) -> Int {
        defaults.integer(forKey: sequenceKey)
    }

    private static func bumpSequenceUnlocked(defaults: UserDefaults) {
        defaults.set(sequenceUnlocked(defaults: defaults) &+ 1, forKey: sequenceKey)
    }

    private static func loadUnlocked(defaults: UserDefaults) -> FocusFilterProfile {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(FocusFilterProfile.self, from: data) else {
            return .inactive
        }
        return profile
    }

    private static func saveUnlocked(_ profile: FocusFilterProfile, defaults: UserDefaults) {
        guard profile != .inactive, let data = try? JSONEncoder().encode(profile) else {
            clearUnlocked(defaults: defaults)
            return
        }
        bumpSequenceUnlocked(defaults: defaults)
        defaults.set(data, forKey: key)
    }

    private static func clearUnlocked(defaults: UserDefaults) {
        // Advance the sequence even when storage is already empty so an older in-flight
        // reconciliation cannot resurrect a stale profile after an authoritative `.notFound` clear.
        bumpSequenceUnlocked(defaults: defaults)
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
    }
}
