import Foundation

extension HomeStore {
    static let onboardingMilestonesKey = "onboarding_milestones"
    static let askWhenUnsureKey = "assistant_ask_when_unsure"
    static let launchAtLoginOnboardingChoiceKey = "launch_at_login_onboarding_choice"
    static let launchAtLoginChoiceAppliedKey = "launch_at_login_onboarding_choice_applied"
    static let launchAtLoginSuggestionDismissedKey = "launch_at_login_suggestion_dismissed"
    static let launchAtLoginRegistrationFailedKey = "launch_at_login_registration_failed"

    /// Whether a real account or the offline demo is currently usable. The onboarding guide's first
    /// step and its demo escape hatch share this definition so they cannot disagree.
    public var hasConnectedHomeSource: Bool {
        if homeBackend == .demo { return true }
        if case .connected = connectionStatus { return true }
        return homeBackend == .xiaomiCloud && miSessionMaskedUserId != nil
    }

    /// Whether an account, token or the demo is configured, connected or not. Once this is true the
    /// full-screen connect form would be redundant, so onboarding moves to the dashboard checklist.
    public var hasConfiguredHomeSource: Bool {
        if homeBackend == .demo { return true }
        if hasHASource || miSessionMaskedUserId != nil || !miAccounts.isEmpty { return true }
        if case .connected = connectionStatus { return true }
        return false
    }

    /// The three-step checklist shown by the guide and the dashboard card (#180).
    public var onboardingChecklist: OnboardingChecklist {
        OnboardingChecklist(hasConfiguredSource: hasConfiguredHomeSource, milestones: onboardingMilestones)
    }

    /// Marks a step the user actually tried. Idempotent; the set is persisted for the next launch.
    public func recordOnboardingMilestone(_ milestone: OnboardingMilestone) {
        guard onboardingMilestones.insert(milestone).inserted else { return }
        userDefaults.set(
            onboardingMilestones.map(\.rawValue).sorted(),
            forKey: Self.onboardingMilestonesKey
        )
    }

    /// Launch-at-login state for the guide, the dashboard checklist and Settings (#281).
    public var launchAtLoginPolicy: LaunchAtLoginPolicy {
        LaunchAtLoginPolicy(
            status: launchAtLoginStatus,
            onboardingChoice: launchAtLoginOnboardingChoice,
            appliedOnboardingChoice: hasAppliedLaunchAtLoginOnboardingChoice,
            dismissedSuggestion: hasDismissedLaunchAtLoginSuggestion,
            registrationFailed: launchAtLoginRegistrationFailed
        )
    }

    /// Upgraded installs get one skippable row in the dashboard checklist, without opening the panel.
    public var shouldShowLaunchAtLoginSuggestion: Bool {
        launchAtLoginPolicy.showsChecklistSuggestion(
            hasCompletedOnboarding: hasCompletedOnboarding
        )
    }

    /// The panel draws the checklist card for the normal lessons or for that one launch-at-login row.
    public var showsOnboardingChecklistCard: Bool {
        showsOnboardingChecklist || shouldShowLaunchAtLoginSuggestion
    }

    public func markLaunchAtLoginOnboardingChoiceApplied() {
        hasAppliedLaunchAtLoginOnboardingChoice = true
    }

    public func dismissLaunchAtLoginSuggestion() {
        hasDismissedLaunchAtLoginSuggestion = true
    }

    /// The confirmation policy handed to `ModelActionPolicy`, so the advanced threshold and the
    /// plain-language switch stay one source of truth.
    public var aiConfirmationPolicy: ModelActionPolicy.ConfirmationPolicy {
        ModelActionPolicy.ConfirmationPolicy(
            askWhenUnsure: askWhenUnsureBeforeAIActions,
            threshold: ModelActionPolicy.autoRunThreshold
        )
    }

    /// The one system notice the panel may show. Blocked outranks security, then a suggestion,
    /// then a session that is only expiring. `extraCount` is how many notices are waiting behind it.
    public var panelNoticeSlot: PanelNoticeSlot? {
        PanelNotice.slot(
            miExpired: miSessionShowsExpired,
            expiringSoon: miSessionExpiringSoonDate,
            plaintext: haPlaintextPrompt,
            address: pendingHAAddressSuggestion
        )
    }

    /// The All Off lesson is on screen and is the next step, so a hold must not change the home.
    var allOffLessonIsActive: Bool {
        guard showsOnboardingChecklistCard else { return false }
        if panelNoticeSlot?.hidesChecklist == true { return false }
        return onboardingChecklist.nextStep == .allOffAndUndo
    }

    /// Shows the rehearsal banner and marks the lesson done. Returns false when this hold should
    /// really turn devices off.
    func rehearseAllOffLessonIfNeeded() -> Bool {
        guard allOffLessonIsActive else { return false }
        let targets = allOffTargets
        guard !targets.isEmpty else { return false }
        scheduleUndoBanner(
            title: Self.rehearsalBannerTitle(names: targets.map(\.name)),
            restoreCommands: [],
            previousDevices: devices,
            deviceCount: targets.count,
            isAllOff: false
        )
        recordOnboardingMilestone(.rehearsedAllOff)
        return true
    }

    static func rehearsalBannerTitle(names: [String]) -> String {
        let count = names.count
        let separator = L10n.isEnglish ? ", " : "、"
        let shown = names.prefix(5)
        let list = shown.joined(separator: separator)
        let more = names.count > shown.count ? L10n.tr("等", "…") : ""
        let detail = list.isEmpty ? "" : " \(list)\(more)"
        return L10n.tr(
            "演练：将关闭 \(count) 台（未实际执行）\(detail)",
            "Practice: would turn off \(count) (not sent)\(detail)"
        )
    }
}

/// One system notice, plus how many others are waiting. The panel draws `kind` and nothing else.
public struct PanelNoticeSlot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case miBlocked
        case haPlaintext(HAPlaintextPrompt)
        case haAddress(HADiscoveredInstance)
        case miExpiringSoon(Date)
    }

    public var kind: Kind
    public var extraCount: Int

    /// A blocked session or a plaintext-token decision hides the getting-started row.
    public var hidesChecklist: Bool {
        switch kind {
        case .miBlocked, .haPlaintext: true
        case .haAddress, .miExpiringSoon: false
        }
    }

    public init(kind: Kind, extraCount: Int) {
        self.kind = kind
        self.extraCount = extraCount
    }
}

public enum PanelNotice {
    /// Highest priority first. A missing input is not a notice.
    public static func slot(
        miExpired: Bool,
        expiringSoon: Date?,
        plaintext: HAPlaintextPrompt?,
        address: HADiscoveredInstance?
    ) -> PanelNoticeSlot? {
        let pending = (miExpired ? 1 : 0)
            + (plaintext == nil ? 0 : 1)
            + (address == nil ? 0 : 1)
            + (expiringSoon == nil ? 0 : 1)
        guard pending > 0 else { return nil }

        let kind: PanelNoticeSlot.Kind
        if miExpired {
            kind = .miBlocked
        } else if let plaintext {
            kind = .haPlaintext(plaintext)
        } else if let address {
            kind = .haAddress(address)
        } else if let expiringSoon {
            kind = .miExpiringSoon(expiringSoon)
        } else {
            return nil
        }
        return PanelNoticeSlot(kind: kind, extraCount: pending - 1)
    }

    public static func extraReminderLabel(count: Int) -> String {
        L10n.tr("还有 \(count) 条提醒", count == 1 ? "1 more reminder" : "\(count) more reminders")
    }
}

/// The kind-chip row stays hidden until the user asks for it, or a kind filter is already on.
public enum KindChipRowPolicy {
    public static func isShown(listCut: DeviceListCut, revealed: Bool) -> Bool {
        switch listCut {
        case .kind: return true
        case .all: return revealed
        case .room: return false
        }
    }
}
