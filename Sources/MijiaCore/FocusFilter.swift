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
// The one invariant: **safety alerts and the doorbell are never suppressed.** `NotificationDeliveryPolicy`
// owns that rule, and the tests assert it against every profile shape, including a hostile one.

/// What one Focus mode asked the app to do, as written by `MenuBarHomeFocusFilter`.
public struct FocusFilterProfile: Codable, Equatable, Sendable {
    /// True while a Focus carrying this app's filter is on.
    public var isEnabled: Bool
    /// "睡眠专注时不推送非安全通知" — the switch this feature exists for.
    public var suppressNonSafetyNotifications: Bool

    public init(isEnabled: Bool = false, suppressNonSafetyNotifications: Bool = false) {
        self.isEnabled = isEnabled
        self.suppressNonSafetyNotifications = suppressNonSafetyNotifications
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

public enum FocusFilterStorage {
    public static let key = "focus_filter_profile_v1"

    public static func load(defaults: UserDefaults = .standard) -> FocusFilterProfile {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(FocusFilterProfile.self, from: data) else {
            return .inactive
        }
        return profile
    }

    public static func save(_ profile: FocusFilterProfile, defaults: UserDefaults = .standard) {
        guard profile != .inactive, let data = try? JSONEncoder().encode(profile) else {
            clear(defaults: defaults)
            return
        }
        defaults.set(data, forKey: key)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
    }
}
