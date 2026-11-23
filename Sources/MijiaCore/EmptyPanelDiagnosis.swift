import Foundation

/// Session state of the Xiaomi Cloud account used by `EmptyPanelDiagnosis`.
public enum MiAccountSessionState: String, Codable, Equatable, Sendable {
    /// No signed-in, enabled Xiaomi Cloud session is present.
    case missing
    /// Signed-in session is present and has not expired or been rejected.
    case active
    /// Session is expired or was rejected by Xiaomi Cloud (including post-upgrade/rename invalidation).
    case expired
}

/// Outcome of the most recent Xiaomi Cloud sync attempt.
public enum EmptyPanelSyncOutcome: String, Codable, Equatable, Sendable {
    /// Initial sync has not completed yet.
    case pending
    /// Last sync completed without an error.
    case succeeded
    /// Last sync failed due to an authentication / session rejection.
    case authFailed
    /// Last sync failed due to a non-auth error (network, gateway, rate-limit, etc.).
    case failed
}

/// Actionable reason why a signed-in Xiaomi Cloud panel shows 0 devices.
public enum EmptyPanelReason: String, Codable, Equatable, CaseIterable, Sendable {
    /// Session expired/rejected or invalidated after upgrade/rename migration (#67).
    case sessionReauthRequired
    /// Last sync failed with a non-auth error (#76).
    case syncFailed
    /// Sync succeeded with 0 homes on a non-default server region.
    case possibleWrongRegion
    /// Sync succeeded with 0 homes on the default region.
    case noHomes
    /// Sync succeeded with one or more homes, yet 0 displayable devices were returned.
    case homesWithoutDevices

    /// The single primary recovery action to surface in the empty panel.
    public var suggestedAction: EmptyPanelSuggestedAction {
        switch self {
        case .sessionReauthRequired:
            return .reauth
        case .possibleWrongRegion:
            return .switchRegion
        case .noHomes:
            return .confirmMiHome
        case .homesWithoutDevices, .syncFailed:
            return .copyDiagnostics
        }
    }
}

/// Primary recovery button shown in the empty panel. Reuses existing entry points only.
public enum EmptyPanelSuggestedAction: String, Codable, Equatable, Sendable {
    case reauth
    case switchRegion
    case confirmMiHome
    case copyDiagnostics
}

/// Pure inputs for diagnosing a 0-device Xiaomi Cloud panel.
public struct EmptyPanelDiagnosisInput: Equatable, Sendable {
    public var isDemoMode: Bool
    public var sessionState: MiAccountSessionState
    public var homeCount: Int
    public var deviceCount: Int
    public var lastSyncOutcome: EmptyPanelSyncOutcome
    public var region: String
    public var hasOtherHomesWithDevices: Bool

    public init(
        isDemoMode: Bool,
        sessionState: MiAccountSessionState,
        homeCount: Int,
        deviceCount: Int,
        lastSyncOutcome: EmptyPanelSyncOutcome,
        region: String,
        hasOtherHomesWithDevices: Bool = false
    ) {
        self.isDemoMode = isDemoMode
        self.sessionState = sessionState
        self.homeCount = homeCount
        self.deviceCount = deviceCount
        self.lastSyncOutcome = lastSyncOutcome
        self.region = region
        self.hasOtherHomesWithDevices = hasOtherHomesWithDevices
    }
}

/// Pure, cross-platform diagnosis for the "signed in to Xiaomi Cloud, 0 devices" empty panel (#67, #76).
///
/// Mirrors `windows/src/core/emptyPanelDiagnosis.ts` and is locked to `Tests/Fixtures/empty_panel_diagnosis_golden.json`.
public enum EmptyPanelDiagnosis {
    public static func normalizeRegion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MiCloudRegion(rawValue: trimmed)?.rawValue ?? MiCloudRegion.cn.rawValue
    }

    public static func diagnose(_ input: EmptyPanelDiagnosisInput) -> EmptyPanelReason? {
        if input.isDemoMode { return nil }
        if input.deviceCount > 0 { return nil }
        if input.hasOtherHomesWithDevices { return nil }
        if input.sessionState == .missing { return nil }

        if input.sessionState == .expired || input.lastSyncOutcome == .authFailed {
            return .sessionReauthRequired
        }
        if input.lastSyncOutcome == .pending {
            return nil
        }
        if input.lastSyncOutcome == .failed {
            return .syncFailed
        }

        if input.homeCount <= 0 {
            let region = normalizeRegion(input.region)
            return region == MiCloudRegion.cn.rawValue ? .noHomes : .possibleWrongRegion
        }
        return .homesWithoutDevices
    }
}
