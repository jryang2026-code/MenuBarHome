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

    /// Every pending notice in priority order. The panel shows the first unless the user cycles.
    public var panelNoticeKinds: [PanelNoticeSlot.Kind] {
        PanelNotice.kinds(
            miExpired: miSessionShowsExpired,
            expiringSoon: miSessionExpiringSoonDate,
            plaintext: haPlaintextPrompt,
            address: pendingHAAddressSuggestion
        )
    }

    /// The one system notice the panel may show. Blocked outranks security, then a suggestion,
    /// then a session that is only expiring. `extraCount` is how many notices are waiting behind it.
    public var panelNoticeSlot: PanelNoticeSlot? {
        PanelNotice.slot(panelNoticeKinds, at: 0)
    }

    /// Header hold during the All Off lesson. Every other caller, including URL, Raycast, and
    /// App Intent scenes, uses `turnAllOff()` and really switches devices off.
    @discardableResult
    public func rehearseAllOff() -> Task<BulkWriteOutcome, Never>? {
        if rehearseAllOffLessonIfNeeded() { return nil }
        return turnAllOff()
    }

    /// The All Off lesson is on screen and is the next step, so a hold must not change the home.
    /// `showsOnboardingChecklist` and not `showsOnboardingChecklistCard`: the card also appears for
    /// the standalone launch-at-login reminder, and that row is not the lesson.
    var allOffLessonIsActive: Bool {
        guard showsOnboardingChecklist else { return false }
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

        /// A blocked session or a plaintext-token decision hides the getting-started row.
        public var hidesChecklist: Bool {
            switch self {
            case .miBlocked, .haPlaintext: true
            case .haAddress, .miExpiringSoon: false
            }
        }
    }

    public var kind: Kind
    public var extraCount: Int

    /// Whether this notice hides the getting-started row while it is the one on screen.
    public var hidesChecklist: Bool { kind.hidesChecklist }

    /// #47's persistent expiry toast says what the blocked banner already says and carries the
    /// same Scan action. Showing both makes one expired session read as two alerts.
    public func repeats(_ toast: ToastNotice) -> Bool {
        switch kind {
        case .miBlocked:
            return toast.persistent && toast.action?.kind == .presentMiReauth
        case .haPlaintext, .haAddress, .miExpiringSoon:
            return false
        }
    }

    public init(kind: Kind, extraCount: Int) {
        self.kind = kind
        self.extraCount = extraCount
    }
}

public enum PanelNotice {
    /// Every pending notice, highest priority first. A missing input is not a notice. The panel
    /// shows the first by default and the 「还有 N 条提醒」 button walks the rest.
    public static func kinds(
        miExpired: Bool,
        expiringSoon: Date?,
        plaintext: HAPlaintextPrompt?,
        address: HADiscoveredInstance?
    ) -> [PanelNoticeSlot.Kind] {
        var kinds: [PanelNoticeSlot.Kind] = []
        if miExpired { kinds.append(.miBlocked) }
        if let plaintext { kinds.append(.haPlaintext(plaintext)) }
        if let address { kinds.append(.haAddress(address)) }
        if let expiringSoon { kinds.append(.miExpiringSoon(expiringSoon)) }
        return kinds
    }

    /// The notice at `index` in `kinds`, wrapping so the last step returns to the highest priority.
    /// `extraCount` stays the number waiting behind, whichever notice is on screen.
    public static func slot(_ kinds: [PanelNoticeSlot.Kind], at index: Int) -> PanelNoticeSlot? {
        guard !kinds.isEmpty else { return nil }
        let wrapped = ((index % kinds.count) + kinds.count) % kinds.count
        return PanelNoticeSlot(kind: kinds[wrapped], extraCount: kinds.count - 1)
    }

    /// Highest priority first. A missing input is not a notice.
    public static func slot(
        miExpired: Bool,
        expiringSoon: Date?,
        plaintext: HAPlaintextPrompt?,
        address: HADiscoveredInstance?
    ) -> PanelNoticeSlot? {
        slot(
            kinds(
                miExpired: miExpired,
                expiringSoon: expiringSoon,
                plaintext: plaintext,
                address: address
            ),
            at: 0
        )
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
