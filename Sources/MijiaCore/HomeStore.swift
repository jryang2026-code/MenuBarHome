import Foundation
import Observation

public struct ToastAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case presentMiReauth
        case openConnectionSettings
    }

    public var title: String
    public var kind: Kind

    public init(title: String, kind: Kind) {
        self.title = title
        self.kind = kind
    }
}

public struct ToastNotice: Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var isError: Bool
    public var action: ToastAction?
    public var persistent: Bool

    public init(
        id: UUID = UUID(),
        message: String,
        isError: Bool = false,
        action: ToastAction? = nil,
        persistent: Bool = false
    ) {
        self.id = id
        self.message = message
        self.isError = isError
        self.action = action
        self.persistent = persistent
    }
}

public struct UndoBanner: Equatable, Sendable {
    public let id: UUID
    /// Logical action identity shared with `lastAssistantUndo` only when both entries were recorded
    /// by the same execution, so a partial or refused undo never cross-pollinates independent stacks.
    public let actionId: UUID
    public var title: String
    public var restoreCommands: [DeviceCommand]
    public var previousDevices: [SmartDevice]
    /// Devices the action reached. The 10/15 s window follows it, and a bulk action that fails
    /// part way lowers it before a hover-resume re-arms the timer.
    public var deviceCount: Int
    /// Habit records written while executing this action; undoing the banner takes them back (#34).
    public var habitReceipt: UserHabitMemory.RecordingReceipt?
    /// Explicit window for actions outside the panel (automation, #59); nil uses the device-count rule.
    public var duration: TimeInterval?
    /// True only for 全关, so the onboarding marker records an undo of the all-off lesson (#180).
    public var isAllOff: Bool
    /// Devices the action's batch actually sent to. `nil` when no batch reported them (assistant
    /// plans), where undo sends every restore command it carries. A device a newer write took
    /// before its send is missing here, and its restore command is dropped.
    public var attemptedDeviceIds: Set<String>?

    public init(
        id: UUID = UUID(),
        actionId: UUID = UUID(),
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        deviceCount: Int = 1,
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil,
        isAllOff: Bool = false,
        attemptedDeviceIds: Set<String>? = nil
    ) {
        self.id = id
        self.actionId = actionId
        self.title = title
        self.restoreCommands = restoreCommands
        self.previousDevices = previousDevices
        self.deviceCount = deviceCount
        self.habitReceipt = habitReceipt
        self.duration = duration
        self.isAllOff = isAllOff
        self.attemptedDeviceIds = attemptedDeviceIds
    }
}

struct AssistantUndoEntry: Equatable, Sendable {
    var actionId: UUID
    var reply: String
    var restore: [DeviceCommand]
    var previous: [SmartDevice]
    var at: Date
    var habitReceipt: UserHabitMemory.RecordingReceipt?

    init(
        actionId: UUID = UUID(),
        reply: String,
        restore: [DeviceCommand],
        previous: [SmartDevice],
        at: Date,
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil
    ) {
        self.actionId = actionId
        self.reply = reply
        self.restore = restore
        self.previous = previous
        self.at = at
        self.habitReceipt = habitReceipt
    }
}

/// Work only the 主动建议 branch does (P5b-M): ambient signatures, habit rankings and reads of
/// the AI suggestion cache.
struct ProactiveWorkCounters: Equatable {
    var signatures = 0
    var rankings = 0
    var cacheReads = 0
}

@Observable
@MainActor
public final class HomeStore {
    public static let shared = HomeStore()

    public internal(set) var connectionStatus: ConnectionStatus = .connecting {
        didSet { updateValueFreshness() }
    }
    public internal(set) var rooms: [RoomArea] = [] {
        didSet { scheduleRaycastSnapshotExport() }
    }
    /// Mi Home 家庭 list from the cloud backend; empty elsewhere.
    public internal(set) var homes: [HomeOption] = []
    public internal(set) var selectedMiHomeId: String? = UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)

    /// Devices held by the other Mi Homes while the selected home shows none, or nil when the
    /// panel is not in that state.
    ///
    /// The selected-home filter is remembered across launches, so an account whose chosen home has
    /// no supported devices comes back to an empty panel with no hint that anything is there. This
    /// is the number the empty state offers to reveal (#76, #67).
    public var otherMiHomesDeviceCountWhenSelectedEmpty: Int? {
        guard hasReceivedInitialSnapshot, devices.isEmpty, let selected = selectedMiHomeId else {
            return nil
        }
        let total = homes.reduce(0) { sum, home in
            home.id == selected ? sum : sum + home.deviceCount
        }
        return total > 0 ? total : nil
    }
    public internal(set) var devices: [SmartDevice] = [] {
        didSet {
            syncIndexedDevices(from: devices)
            scheduleRaycastSnapshotExport()
        }
    }
    /// Generic drawer rows under 更多设置, keyed by card id (#5). Values follow the snapshot except
    /// while an optimistic write is locked.
    public internal(set) var deviceFacets: [String: [FacetControl]] = [:] {
        didSet {
            if !isApplyingProviderSnapshot, deviceFacets != oldValue {
                syncIndexedDevices(from: devices)
            }
        }
    }
    public internal(set) var deviceTransportDiagnostics: [String: DeviceTransportDiagnostics] = [:]
    public internal(set) var localNetworkBlocks: Set<LocalNetworkBlockedFeature> = [] {
        didSet {
            syncLocalNetworkBlockedNoticeDismissal(from: effectiveLocalNetworkBlocks(for: oldValue))
        }
    }
    /// Member did → Mi light-group did from the current snapshot; folding reads it (#189).
    public internal(set) var lightGroupOwners: [String: String] = [:]
    public internal(set) var environmentReadings: [EnvironmentReading] = [] {
        didSet { scheduleRaycastSnapshotExport() }
    }
    public internal(set) var scenes: [HomeScene] = [] {
        didSet {
            if !scenes.isEmpty {
                syncIndexedScenes(from: scenes)
            }
            scheduleRaycastSnapshotExport()
        }
    }
    public internal(set) var hasReceivedInitialSnapshot = false
    /// Read-back tickets for primary toggles; see `ReadBackTickets`.
    var readBackTickets = ReadBackTickets()
    /// Devices whose toggle is waiting for the device to answer.
    public var waitingDeviceIds: Set<String> { readBackTickets.waitingDeviceIds }
    /// True after the cloud drops once a snapshot has been shown. Cleared only by a later connect.
    /// A retry that is still `.connecting` leaves this set, so the last reading stays unmarked as current.
    public internal(set) var deviceValuesAreStale = false {
        didSet {
            if deviceValuesAreStale != oldValue {
                scheduleRaycastSnapshotExport()
            }
        }
    }
    /// Bumped on every snapshot so a toggle can tell a read-back from the row it already had.
    @ObservationIgnored var snapshotGeneration: UInt64 = 0
    /// How long to wait before a second property poll when the first read still shows the old power.
    var readBackEchoDelay: Duration = .milliseconds(800)
    struct ReadBackEchoHoldKey: Hashable {
        let deviceId: String
        let ticket: UInt64
    }

    /// Test latch: the echo retry waits until `releaseReadBackEcho` instead of sleeping.
    var holdReadBackEcho = false
    var readBackEchoHolds: [ReadBackEchoHoldKey: CheckedContinuation<Void, Never>] = [:]
    var isHoldingReadBackEcho: Bool { !readBackEchoHolds.isEmpty }

    func isHoldingReadBackEcho(for deviceId: String) -> Bool {
        readBackEchoHolds.keys.contains { $0.deviceId == deviceId }
    }

    func releaseReadBackEcho(for deviceId: String? = nil) {
        if let deviceId {
            let keys = readBackEchoHolds.keys.filter { $0.deviceId == deviceId }
            for key in keys {
                readBackEchoHolds.removeValue(forKey: key)?.resume()
            }
        } else {
            let holds = readBackEchoHolds
            readBackEchoHolds.removeAll()
            for cont in holds.values {
                cont.resume()
            }
        }
    }

    public internal(set) var listCut: DeviceListCut = .all
    public var expandedDeviceId: String? = nil
    public var focusedDeviceId: String? = nil
    public var isOptionKeyPressed: Bool = false
    public var isShowingSettings: Bool = false
    /// Transient flag for the QR re-auth overlay (#181).
    public var isShowingMiReauth: Bool = false
    /// The backend a QR login started on. A completion after the user moved elsewhere still saves
    /// the session, but it must not pull the panel back to a backend the user left.
    var miLoginStartBackend: HomeBackend?

    public func loadHAToken() -> String {
        guard !hasPendingHARemoval else { return "" }
        return KeychainHelper.loadToken(defaults: userDefaults, vault: credentialVault)
    }

    public func storedAssistantAPIKey(forBaseURL baseURL: String) -> String {
        AssistantConfig.userStoredAPIKey(forBaseURL: baseURL, defaults: userDefaults, vault: credentialVault)
    }

    public let userDefaults: UserDefaults

    public var hideOfflineDevices: Bool {
        didSet {
            HomePreferences.hideOfflineDevices.save(hideOfflineDevices, to: userDefaults)
            scheduleRaycastSnapshotExport()
        }
    }

    /// Hide lights that belong to a Mi light group while the group card itself is on screen (#189).
    public var hideGroupedLights: Bool {
        didSet {
            HomePreferences.hideGroupedLights.save(hideGroupedLights, to: userDefaults)
            scheduleRaycastSnapshotExport()
        }
    }

    /// Allow 更多设置 writes outside the low-risk whitelist (#5). Off by default: the facet engine
    /// only opens brightness, mode and fan-level until the owner opts in.
    public var allowAdvancedFacetWrites: Bool {
        didSet { HomePreferences.allowAdvancedFacetWrites.save(allowAdvancedFacetWrites, to: userDefaults) }
    }

    public var enableGlobalHotkey: Bool {
        didSet {
            HomePreferences.enableGlobalHotkey.save(enableGlobalHotkey, to: userDefaults)
            onGlobalHotkeyPreferenceChanged?(enableGlobalHotkey)
        }
    }

    public var enableVoiceInput: Bool {
        didSet {
            HomePreferences.enableVoiceInput.save(enableVoiceInput, to: userDefaults)
            if enableVoiceInput != oldValue {
                onVoiceInputPreferenceChanged?(enableVoiceInput)
                for observer in voiceInputPreferenceObservers.values {
                    observer(enableVoiceInput)
                }
            }
        }
    }

    public var isCompactGridMode: Bool {
        didSet { HomePreferences.isCompactGridMode.save(isCompactGridMode, to: userDefaults) }
    }

    public var showQuickActionsBar: Bool {
        didSet { HomePreferences.showQuickActionsBar.save(showQuickActionsBar, to: userDefaults) }
    }

    public var favoriteDeviceIds: Set<String> {
        didSet {
            HomePreferences.favoriteDeviceIds.save(favoriteDeviceIds, to: userDefaults)
            // 收藏设备离线提醒 reads favourites, so a hidden type keeps or drops their reads here.
            syncMiotTypePrunePolicy()
            scheduleRaycastSnapshotExport()
        }
    }

    public var favoriteOrder: [String] {
        didSet {
            HomePreferences.favoriteOrder.save(favoriteOrder, to: userDefaults)
            scheduleRaycastSnapshotExport()
        }
    }

    public var hiddenDeviceIds: Set<String> {
        didSet {
            HomePreferences.hiddenDeviceIds.save(hiddenDeviceIds, to: userDefaults)
            scheduleRaycastSnapshotExport()
        }
    }

    /// Per-device choice for 全关; a missing entry means the default from `joinsAllOffByDefault` (#23).
    public var allOffOverrides: [String: Bool] {
        didSet {
            HomePreferences.allOffOverrides.save(allOffOverrides, to: userDefaults)
            scheduleRaycastSnapshotExport()
        }
    }

    public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { userDefaults.set(menuBarDisplayMode.rawValue, forKey: "menubar_display_mode") }
    }

    public var menuBarTargetId: String {
        didSet { HomePreferences.menuBarTargetId.save(menuBarTargetId, to: userDefaults) }
    }

    public var enableSafetyAlerts: Bool {
        didSet {
            HomePreferences.enableSafetyAlerts.save(enableSafetyAlerts, to: userDefaults)
            syncMiotTypePrunePolicy()
        }
    }

    /// Weekly home health report notification (#182). Off by default: a new recurring notification.
    public var enableWeeklyHealthReport: Bool {
        didSet { HomePreferences.enableWeeklyHealthReport.save(enableWeeklyHealthReport, to: userDefaults) }
    }

    /// Open the doorbell's live camera when it rings (#308). Off by default: privacy and interruption.
    public var doorbellAutoPopup: Bool {
        didSet {
            HomePreferences.doorbellAutoPopup.save(doorbellAutoPopup, to: userDefaults)
            syncMiotTypePrunePolicy()
        }
    }

    /// Play a chime when a doorbell popup opens (#308). Off by default.
    public var doorbellChime: Bool {
        didSet {
            HomePreferences.doorbellChime.save(doorbellChime, to: userDefaults)
            syncMiotTypePrunePolicy()
        }
    }

    /// Seconds before a doorbell popup closes itself (#308).
    public var doorbellPopupSeconds: Int {
        didSet { HomePreferences.doorbellPopupSeconds.save(doorbellPopupSeconds, to: userDefaults) }
    }

    /// Recent doorbell presses, newest first, including ones that did not open a window (#308).
    /// Cleared by `invalidateUndoContext`; a press whose card leaves the home drops out of
    /// `panelActivities`.
    public internal(set) var recentDoorbellRings: [DoorbellRing] = []
    /// Safety alerts the panel's activity stack shows, newest first, at most
    /// `recentSafetyAlertLimit`. Written by the snapshot path in `HomeStore+Backend.swift`, which is
    /// also where the notification handler fires, so the panel keeps its copy when no handler is
    /// installed. Cleared by `invalidateUndoContext`; an alert whose card leaves the home drops out
    /// of `panelActivities`.
    public internal(set) var recentSafetyAlerts: [RecordedSafetyAlert] = []
    /// Activity ids the user cleared from the stack. Ignored for the notices that cannot be cleared.
    /// In memory only, and cleared by `invalidateUndoContext` with the previous home's prompts.
    public internal(set) var dismissedActivityIds: Set<String> = []
    /// Installed by the app to play the chime and open the live camera window for a ring.
    public var onDoorbellRing: (@MainActor (DoorbellResponse) -> Void)?

    /// Refuse user-initiated device control while the Mac screen is locked (#143). Defaults on:
    /// the only paths that can still fire while locked are external ones (URL links, App Intents,
    /// assistant commands), and automation/scheduled rules stay exempt. Settings can turn it off.
    public var blockControlWhileLocked: Bool {
        didSet { HomePreferences.blockControlWhileLocked.save(blockControlWhileLocked, to: userDefaults) }
    }

    /// Set by `SystemActivityMonitor` from the distributed screen-lock notifications, not persisted.
    public internal(set) var isScreenLocked = false {
        didSet {
            if isScreenLocked != oldValue {
                syncResumeScreenLocked(isScreenLocked)
            }
        }
    }

    /// Presents the second confirmation for a manual high-risk action. The app installs an AppKit
    /// alert; tests inject a closure so no window is needed.
    @ObservationIgnored public var manualControlConfirmationHandler: ((ManualControlConfirmation) -> Bool)?
    /// Stack of active confirmation modal contexts while `manualControlConfirmationHandler` runs.
    @ObservationIgnored var activeModalContexts: [ModalDeviceContext] = []

    /// Credential storage shared by the store and its views. An explicit vault takes precedence
    /// over suite storage; nil uses the Keychain for standard defaults and isolated suite storage otherwise.
    @ObservationIgnored public internal(set) var credentialVault: CredentialVault?
    @ObservationIgnored let topologyCache: MiTopologyCache?

    public var sensorAlertsOnlyWhenAway: Bool {
        didSet { HomePreferences.sensorAlertsOnlyWhenAway.save(sensorAlertsOnlyWhenAway, to: userDefaults) }
    }

    /// Explicit per-kind overrides. Reading this from `isSensorAlertEnabled` lets SwiftUI
    /// observe toggles that previously only reached `UserDefaults` (#199).
    public internal(set) var sensorAlertPreferences: [SensorAlertKind: Bool] = [:]

    public var homeName: String {
        didSet { HomePreferences.homeName.save(homeName, to: userDefaults) }
    }

    public var appLanguagePreference: AppLanguagePreference = .system {
        didSet {
            userDefaults.set(appLanguagePreference.rawValue, forKey: "app_language")
            syncEffectiveLanguage()
        }
    }

    public private(set) var effectiveLanguage: AppLanguage = .zhHans

    public var miCloudRegion: MiCloudRegion = .cn {
        didSet {
            userDefaults.set(miCloudRegion.rawValue, forKey: "mi_cloud_region")
        }
    }

    public var isHabitLearningEnabled: Bool = true {
        didSet { userDefaults.set(isHabitLearningEnabled, forKey: "assistant_habit_learning_enabled") }
    }

    public var habitSharing: HabitSharing = .off {
        didSet { userDefaults.set(habitSharing == .on, forKey: "assistant_habit_share_enabled") }
    }

    /// Test seam for the manual-control debounce window (sliders fire continuously, #113).
    var controlDebounceInterval: Duration = .milliseconds(280)

    /// Test seam for the debounce wait itself. A test parks a drag here, delivers the provider
    /// snapshot that would take the row over, and only then releases it, so the ordering is fixed
    /// instead of raced against a wall clock.
    @ObservationIgnored var controlDebounceSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    /// How long a cover command keeps its optimistic row. The product value is 8 seconds.
    /// Tests set a shorter value instead of waiting out that lock.
    var coverOptimisticLockDuration: Duration = .seconds(8)

    /// How long a success toast stays. Errors use `errorToastDismissInterval` unless they are persistent.
    public static let successToastDismissInterval: Duration = .seconds(2.8)
    /// An error toast stays at least this long, and can be dismissed sooner by the × button.
    public static let errorToastDismissInterval: Duration = .seconds(8)
    /// Test seam for the toast lifetime. `nil` keeps every toast up until the test reads it.
    var toastAutoDismissInterval: Duration? = successToastDismissInterval
    /// The delay `showToast` armed for the toast on screen. `nil` means it will not auto-dismiss.
    var activeToastDismissInterval: Duration?
    /// True while an ordinary toast hides the persistent expired-session prompt. When that toast
    /// ends the prompt comes back, unless the session recovered or a context change cleared it.
    var isSessionToastSuspended = false

    /// Ask macOS to keep speech recognition on this Mac (no audio sent to Apple) when the language supports it.
    /// Defaults on for privacy; an explicitly saved `false` still wins (#50).
    public var prefersOnDeviceSpeech: Bool = true {
        didSet { userDefaults.set(prefersOnDeviceSpeech, forKey: "assistant_on_device_speech") }
    }

    /// Persisted flag set once the user finishes or dismisses the first-launch onboarding guide.
    public var hasCompletedOnboarding: Bool = false {
        didSet { userDefaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }

    /// First-run guide's launch-at-login checkbox. Checked until the user clears it (#281).
    public var launchAtLoginOnboardingChoice: Bool = true {
        didSet {
            userDefaults.set(
                launchAtLoginOnboardingChoice,
                forKey: Self.launchAtLoginOnboardingChoiceKey
            )
        }
    }

    /// True once the guide left the connect step and applied that checkbox to macOS (#281).
    public internal(set) var hasAppliedLaunchAtLoginOnboardingChoice: Bool = false {
        didSet {
            userDefaults.set(
                hasAppliedLaunchAtLoginOnboardingChoice,
                forKey: Self.launchAtLoginChoiceAppliedKey
            )
        }
    }

    /// True when the user skipped the dashboard checklist's launch-at-login row (#281).
    public internal(set) var hasDismissedLaunchAtLoginSuggestion: Bool = false {
        didSet {
            userDefaults.set(
                hasDismissedLaunchAtLoginSuggestion,
                forKey: Self.launchAtLoginSuggestionDismissedKey
            )
        }
    }

    /// The app injects its real login-item adapter here. Core owns the onboarding rule, the app
    /// owns the ServiceManagement call (#281, ADR-0003).
    public var launchAtLoginSystem: LaunchAtLoginSystem?

    /// Last observed `SMAppService` state. Never persisted, so Settings cannot show a remembered
    /// preference as the system's real state (#281).
    public var launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered

    /// Result of the last register/unregister attempt. Persisted so the manual hint survives a
    /// relaunch until macOS reports the item enabled (#281).
    public var launchAtLoginRegistrationFailed: Bool = false {
        didSet {
            userDefaults.set(
                launchAtLoginRegistrationFailed,
                forKey: Self.launchAtLoginRegistrationFailedKey
            )
        }
    }

    /// Steps the guide has seen the user try (#180). Persisted so the checkmarks survive a relaunch.
    /// Connecting is deliberately not stored here: it is derived from the live connection state.
    public internal(set) var onboardingMilestones: Set<OnboardingMilestone> = []

    /// Plain-language "不确定时先问我" switch (#180). On by default, matching the shared
    /// confirmation rules both platforms ship with; the numeric threshold lives in advanced settings.
    public var askWhenUnsureBeforeAIActions: Bool = true {
        didSet { userDefaults.set(askWhenUnsureBeforeAIActions, forKey: Self.askWhenUnsureKey) }
    }

    /// Transient flag allowing the user to reopen the onboarding guide from Settings at any time.
    public var isShowingOnboarding: Bool = false

    /// Keeps the onboarding guide visible after a first source connects so the user can optionally
    /// add a second platform (dual-source) before entering the dashboard.
    public var isKeepingOnboardingGuideOpenForDualSource: Bool = false

    /// Which onboarding surface to draw. The full guide only replaces the dashboard while nothing
    /// is configured; after connecting, the remaining lessons ride above the dashboard so search and
    /// All Off/Undo can be tried while the instructions stay visible (#180 review).
    public var onboardingPresentation: OnboardingPresentation {
        OnboardingPresentation.resolve(
            checklist: onboardingChecklist,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isReopened: isShowingOnboarding,
            isIdentityUncertain: identityMigrationDiagnostic != nil,
            keepFullGuideOpen: isKeepingOnboardingGuideOpenForDualSource
        )
    }

    /// Any onboarding surface is on screen: the full guide or the dashboard checklist.
    public var shouldShowOnboarding: Bool {
        onboardingPresentation != .hidden
    }

    /// The full-screen guide replaces the dashboard. Only true before a source is configured.
    public var showsFullOnboardingGuide: Bool {
        onboardingPresentation == .fullGuide
    }

    /// The compact next-steps card rides above the live dashboard.
    public var showsOnboardingChecklist: Bool {
        onboardingPresentation == .dashboardChecklist
    }

    /// A genuine first completion applies the guide's launch-at-login checkbox. Reopening the guide
    /// or closing an old install's checklist must not register anything by itself (#281).
    public func completeOnboarding() {
        guard identityMigrationDiagnostic == nil else { return }
        if !hasCompletedOnboarding, let launchAtLoginSystem {
            LaunchAtLoginCoordinator(system: launchAtLoginSystem, store: self)
                .applyOnboardingChoiceIfNeeded()
        }
        hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    /// Leaves the onboarding guide cleanly, cancelling any in-flight HA verification and rolling back
    /// pending dual-source onboarding state.
    public func finishOnboardingGuide() {
        cancelPendingHAOnboardingVerification()
        isKeepingOnboardingGuideOpenForDualSource = false
        completeOnboarding()
    }

    public func reopenOnboarding() {
        isShowingSettings = false
        isShowingOnboarding = true
    }

    public var serverURLString: String {
        didSet {
            migrateHomeAssistantScope(from: oldValue)
            userDefaults.set(serverURLString, forKey: "ha_server_url")
            syncHistoryConnectionScopes()
        }
    }

    public internal(set) var homeBackend: HomeBackend {
        didSet {
            userDefaults.set(homeBackend.rawValue, forKey: "home_backend")
            syncHistoryConnectionScopes()
            if homeBackend == .demo { deviceValuesAreStale = false }
            let previousEffective = oldValue == .demo ? [] : effectiveLocalNetworkBlocks(for: localNetworkBlocks, backend: oldValue)
            syncLocalNetworkBlockedNoticeDismissal(from: previousEffective)
        }
    }

    public internal(set) var miSessionMaskedUserId: String? {
        didSet {
            // Computed before `syncInMemoryConfiguredCapabilities()` so it reflects the pre-change
            // capability state.
            let previousEffective = effectiveLocalNetworkBlocks(
                for: localNetworkBlocks,
                hasMi: oldValue != nil
            )
            syncInMemoryConfiguredCapabilities()
            syncLocalNetworkBlockedNoticeDismissal(from: previousEffective)
        }
    }
    /// Every signed-in Mi account, primary (first) first. The panel groups by account when there is
    /// more than one, and adding an account never replaces the ones already signed in.
    public internal(set) var miAccounts: [MiAccount] = [] {
        didSet {
            syncInMemoryConfiguredCapabilities()
            if !miAccounts.isEmpty {
                miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
            }
            miAccountStatuses = miAccountStatuses.filter { id, _ in isMiAccountEnabled(id) }
        }
    }
    /// Per-account connection state reported by `MiAccountsProvider` so Settings can flag an
    /// expired/disconnected account even while another account keeps `connectionStatus == .connected`.
    public internal(set) var miAccountStatuses: [String: ConnectionStatus] = [:]
    /// The session's one absolute end: carried by the login response, or the last rejection time (#181).
    public internal(set) var miSessionExpiresAt: Date? {
        didSet {
            if miSessionExpiresAt != oldValue {
                scheduleMiSessionExpiryTransition()
            }
        }
    }
    var miSessionExpiryRevision: UInt64 = 0
    var miSessionExpiryTimerTask: Task<Void, Never>?
    var miSessionScopeIdentifier: String? {
        didSet {
            syncInMemoryConfiguredCapabilities()
            syncHistoryConnectionScopes()
        }
    }

    /// Whether an HA token is saved. The chosen `homeBackend` no longer implies the only live source.
    public internal(set) var hasHASource: Bool = false {
        didSet {
            let previousEffective = effectiveLocalNetworkBlocks(
                for: localNetworkBlocks,
                hasHA: oldValue
            )
            syncInMemoryConfiguredCapabilities()
            syncLocalNetworkBlockedNoticeDismissal(from: previousEffective)
        }
    }
    public var hasMiSource: Bool { miSessionMaskedUserId != nil }
    public var isDualSourceActive: Bool {
        homeBackend != .demo && hasHASource && hasMiSource
    }
    public var preferredLiveBackend: HomeBackend {
        if hasHASource { return .homeAssistant }
        if hasMiSource { return .xiaomiCloud }
        return .homeAssistant
    }
    /// Which provider currently drives each merged card.
    public internal(set) var deviceBackends: [String: HomeBackend] = [:] {
        didSet {
            if !isApplyingProviderSnapshot, deviceBackends != oldValue {
                syncIndexedDevices(from: devices)
            }
        }
    }
    /// Cards that exist in both sources; only these offer a source pin (#111).
    public internal(set) var pairedDeviceIDs: Set<String> = [] {
        didSet {
            if !isApplyingProviderSnapshot, pairedDeviceIDs != oldValue {
                syncIndexedDevices(from: devices)
            }
        }
    }
    /// Per-source state from the latest merged snapshot; drives the dual-source footer summary (#111).
    public internal(set) var sourceStatuses: [HomeBackend: ConnectionStatus] = [:]
    /// Explicit per-card source choices, keyed by canonical card id (#111).
    public internal(set) var pinnedDeviceSources: [String: HomeBackend] = [:] {
        didSet {
            pinnedDeviceSourcesBox.set(pinnedDeviceSources)
            DeviceSourcePinStorage.save(pinnedDeviceSources, defaults: userDefaults)
            if !devices.isEmpty {
                syncIndexedDevices(from: devices)
            }
            scheduleRaycastSnapshotExport()
        }
    }
    @ObservationIgnored let pinnedDeviceSourcesBox: DeviceSourcePinBox
    /// Host's enabled device types and safety switches, read by the Mi provider off the main actor
    /// (P3a-M). Updated by `syncMiotTypePrunePolicy()`.
    @ObservationIgnored let miotTypePruneBox = MiotTypePrunePolicyBox()
    /// The same policy for the Home Assistant provider, scoped to its address (P3b-M).
    @ObservationIgnored let haTypePruneBox = HATypePrunePolicyBox()
    /// One entry per Mi account that currently hides cards: the identities a closed type keeps for
    /// the write gate and the hidden devices whose enabled alerts still need evaluating.
    var miotTypePruneReports: [String: MiotTypePruneReport] = [:]
    /// Sources that contributed the latest merged snapshot.
    public internal(set) var connectedBackends: Set<HomeBackend> = []

    public func deviceBackend(for deviceId: String) -> HomeBackend {
        deviceBackends[deviceId] ?? homeBackend
    }

    /// Header shown in the card context menu for dual-source cards; explains temporary fallback when
    /// the user's pinned source is offline and the other source is serving the card instead, or when
    /// the pinned source was turned off and control is paused.
    public func currentSourceMenuTitle(for deviceId: String) -> String {
        if let pinned = pinnedSource(for: deviceId) {
            if pinned == .homeAssistant,
               (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)),
               !isHAConnectionEnabled {
                return L10n.tr(
                    "当前来源：HA 已停用（已固定来源，暂停控制）",
                    "Current source: HA turned off (pinned source; control paused)"
                )
            }
            if pinned == .xiaomiCloud,
               (hasMiSource || !miAccounts.isEmpty || explicitlyDisabledConnections.contains(.xiaomiCloud)),
               !hasEnabledMiSource {
                return L10n.tr(
                    "当前来源：米家云已停用（已固定来源，暂停控制）",
                    "Current source: Xiaomi Cloud turned off (pinned source; control paused)"
                )
            }
        }
        let active = deviceBackend(for: deviceId)
        if let pinned = pinnedSource(for: deviceId), pinned != active {
            return L10n.format(
                "当前来源：%@（%@离线，临时兜底）",
                "Current source: %@ (%@ offline, fallback)",
                active.shortTitle,
                pinned.shortTitle
            )
        }
        return L10n.format("当前来源：%@", "Current source: %@", active.shortTitle)
    }

    /// A card is pinnable when both sources supplied the same physical device, or when a dual-source
    /// card already carries an explicit pin while one configured source is temporarily turned off.
    public func isPairedDualSourceDevice(_ deviceId: String) -> Bool {
        if isDualSourceActive && pairedDeviceIDs.contains(deviceId) {
            return true
        }
        return homeBackend != .demo
            && hasHASource
            && (hasMiSource || !miAccounts.isEmpty)
            && pinnedSource(for: deviceId) != nil
    }

    public func pinnedSource(for deviceId: String) -> HomeBackend? {
        pinnedDeviceSources[deviceId]
    }

    /// `nil` restores automatic online → capability → Home Assistant selection.
    public func pinDeviceSource(_ deviceId: String, to backend: HomeBackend?) {
        var next = pinnedDeviceSources
        if let backend, backend != .demo {
            next[deviceId] = backend
        } else {
            next.removeValue(forKey: deviceId)
        }
        guard next != pinnedDeviceSources else { return }
        pinnedDeviceSources = next
        (provider as? any DualSourceRecomputing)?.requestRecompute()
    }

    private enum SourceState {
        case connected, connecting, offline
    }

    private func sourceState(_ backend: HomeBackend) -> SourceState {
        if let status = sourceStatuses[backend] {
            switch status {
            case .connected: return .connected
            case .connecting: return .connecting
            case .disconnected: return .offline
            }
        }
        return connectedBackends.contains(backend) ? .connected : .connecting
    }

    /// Bottom-bar summary while both sources are configured. `nil` on a single source, where the
    /// existing footer already names it.
    public var dualSourceStatusSummary: String? {
        guard isDualSourceActive else { return nil }
        if allConfiguredSourcesTurnedOff {
            return L10n.tr("HA 与米家云均已停用", "Home Assistant and Xiaomi Cloud are turned off")
        }
        if !isHAConnectionEnabled {
            switch sourceState(.xiaomiCloud) {
            case .connected:
                return L10n.tr("米家云已连接（HA 已停用）", "Xiaomi Cloud connected (HA turned off)")
            case .connecting:
                return L10n.tr("米家云连接中（HA 已停用）", "Xiaomi Cloud connecting (HA turned off)")
            case .offline:
                return L10n.tr("米家云未连接（HA 已停用）", "Xiaomi Cloud offline (HA turned off)")
            }
        }
        if !hasEnabledMiSource {
            switch sourceState(.homeAssistant) {
            case .connected:
                return L10n.tr("HA 已连接（米家云已停用）", "HA connected (Xiaomi Cloud turned off)")
            case .connecting:
                return L10n.tr("HA 连接中（米家云已停用）", "HA connecting (Xiaomi Cloud turned off)")
            case .offline:
                return L10n.tr("HA 未连接（米家云已停用）", "HA offline (Xiaomi Cloud turned off)")
            }
        }
        if case .disconnected = connectionStatus {
            return L10n.tr("HA 与 米家云均未连接", "Home Assistant and Xiaomi Cloud are both offline")
        }
        let ha = sourceState(.homeAssistant)
        let mi = sourceState(.xiaomiCloud)
        switch (ha, mi) {
        case (.connected, .connected):
            return L10n.tr("HA + 米家云已连接", "HA + Xiaomi Cloud connected")
        case (.connected, .offline):
            return L10n.tr("HA 已连接（米家云离线已自动兜底）", "HA connected (Xiaomi Cloud offline, automatic fallback)")
        case (.offline, .connected):
            return L10n.tr("米家云已连接（HA 离线已自动兜底）", "Xiaomi Cloud connected (HA offline, automatic fallback)")
        case (.connected, .connecting):
            return L10n.tr("HA 已连接 · 米家云连接中", "HA connected · Xiaomi Cloud connecting")
        case (.connecting, .connected):
            return L10n.tr("米家云已连接 · HA 连接中", "Xiaomi Cloud connected · HA connecting")
        case (.connecting, .offline):
            return L10n.tr("HA 连接中 · 米家云未连接", "HA connecting · Xiaomi Cloud offline")
        case (.offline, .connecting):
            return L10n.tr("米家云连接中 · HA 未连接", "Xiaomi Cloud connecting · HA offline")
        case (.connecting, .connecting):
            return L10n.tr("HA 与 米家云连接中…", "Home Assistant and Xiaomi Cloud connecting…")
        case (.offline, .offline):
            return L10n.tr("HA 与 米家云均未连接", "Home Assistant and Xiaomi Cloud are both offline")
        }
    }

    public var connectionSourceSummary: String {
        if homeBackend == .demo { return L10n.tr("演示模式", "Demo Mode") }
        if hasHASource && hasMiSource {
            return L10n.tr("Home Assistant + 米家云端", "Home Assistant + Xiaomi Cloud")
        }
        if hasMiSource { return L10n.tr("米家云端", "Xiaomi Cloud") }
        if hasHASource { return "Home Assistant" }
        return L10n.tr("尚未配置数据源", "No data source configured")
    }

    public private(set) var toastNotice: ToastNotice?
    public internal(set) var undoBanner: UndoBanner? {
        didSet {
            if let undoBanner, undoBanner.id != oldValue?.id {
                bannerUndoRevision &+= 1
            }
            scheduleRaycastSnapshotExport()
        }
    }
    var bannerUndoRevision: UInt64 = 0
    var assistantUndoRevision: UInt64 = 0
    /// Delivers a newly fired safety alert to the app's notifier. Optional: the panel's activity
    /// stack records the alert in `recentSafetyAlerts` whether or not this is installed.
    public var onSafetyAlert: ((SafetyAlert) -> Void)?
    public var onGlobalHotkeyPreferenceChanged: ((Bool) -> Void)?
    public var onVoiceInputPreferenceChanged: ((Bool) -> Void)?
    @ObservationIgnored private var voiceInputPreferenceObservers: [UUID: (Bool) -> Void] = [:]

    @discardableResult
    public func addVoiceInputPreferenceObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        voiceInputPreferenceObservers[id] = observer
        return id
    }

    public func removeVoiceInputPreferenceObserver(_ id: UUID) {
        voiceInputPreferenceObservers.removeValue(forKey: id)
    }

    public var onOpenCameraLiveView: ((SmartDevice) -> Void)?
    public internal(set) var activeLiveCameraDeviceId: String?
    public static let cameraStreamURLsKey = ViewPreferenceKeys.cameraStreamURLs
    public static let cameraStreamQualityKey = ViewPreferenceKeys.cameraStreamQuality
    public static let automaticUpdateCheckInterval: TimeInterval = 6 * 3600
    public internal(set) var updateState: AppUpdateState = .idle
    public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            userDefaults.set(automaticallyChecksForUpdates, forKey: "automatically_checks_for_updates")
            if automaticallyChecksForUpdates && !oldValue {
                Task { @MainActor [weak self] in
                    await self?.checkForUpdatesIfNeeded()
                }
            }
        }
    }
    public var onTerminateForUpdate: (() -> Void)?
    public var updater: AppUpdater
    /// Local energy history fed by provider snapshots (#62).
    public let energyHistory: EnergyHistory
    /// Days each device was seen offline, for the weekly report (#182).
    public let offlineHistory: OfflineHistory
    /// Local + cloud merged history for temperature and humidity sensors.
    public let sensorHistory: SensorHistory
    var updateTask: Task<Void, Never>?
    var activeUpdateAttemptID: UUID?
    /// Set while the detached swap script owns the staged bundle; a cancel is refused in this window.
    public var isInstallingUpdate: Bool {
        if case .installing = updateState { return true }
        return false
    }
    /// How long a relaunch may take before checking whether the detached swap process is still running.
    /// Longer than the swap script's nominal 15 s wait for this process to exit; the watchdog also
    /// defers while the swap process is alive. `nil` disables the watchdog (tests).
    public var updateRelaunchWatchdogInterval: Duration? = .seconds(30)
    var updateRelaunchWatchdogTask: Task<Void, Never>?

    static var lgKeychainSaveErrorMessage: String {
        L10n.tr(
            "无法把电视配对密钥写入钥匙串，请授权钥匙串访问后重试",
            "Could not save the TV pairing key to Keychain; allow Keychain access and try again"
        )
    }

    public var lgConfig: LGWebOSConfig {
        didSet {
            let previousEffective = effectiveLocalNetworkBlocks(
                for: localNetworkBlocks,
                lgConfig: oldValue
            )
            syncLocalNetworkBlockedNoticeDismissal(from: previousEffective)
            guard !suppressNextLGConfigDidSetSave else { return }
            lgConfigSaveFailed = !lgConfig.save(to: userDefaults, vault: credentialVault)
            if lgConfigSaveFailed {
                showToast(Self.lgKeychainSaveErrorMessage, isError: true)
            }
        }
    }
    @ObservationIgnored var lgConfigSaveFailed = false
    @ObservationIgnored var suppressNextLGConfigDidSetSave = false
    @ObservationIgnored var lgTrustResetInFlight = false
    /// Suspends `resetLGWebOSTrustAndPair` after the trust store was cleared and before the result is
    /// committed, so tests can change LG settings exactly inside that window (#262).
    @ObservationIgnored var lgTrustResetSuspensionHookForTesting: (@MainActor () async -> Void)?

    public internal(set) var discoveredHAInstances: [HADiscoveredInstance] = []
    /// Another Home Assistant address found after disconnects; only used if the user taps 切换 (#18).
    public internal(set) var pendingHAAddressSuggestion: HADiscoveredInstance?
    var dismissedHAAddressURLs: Set<String> = []
    /// The question about a public plain-http Home Assistant address, or its declined answer (#276).
    public internal(set) var haPlaintextPrompt: HAPlaintextPrompt?
    public internal(set) var isDiscoveringHA: Bool = false

    var provider: any HomeProvider {
        didSet {
            providerGeneration &+= 1
        }
    }
    var providerGeneration: UInt64 = 0
    var controlContextID = UUID()
    var lgWebOSClient: LGWebOSClient? {
        didSet {
            if lgWebOSClient !== oldValue {
                lgWebOSClientID = nil
            }
        }
    }
    var lgWebOSClientID: UUID?
    let isTestEnvironment: Bool
    var latestLGDevice: SmartDevice?
    var eventTask: Task<Void, Never>?
    var providerShutdownTask: Task<Void, Never>?
    /// True while a disabled Home Assistant connection is still tearing down its live provider.
    public internal(set) var isDisablingHAConnection: Bool = false
    /// Awaitable handle for the active Home Assistant disable teardown, if any.
    @ObservationIgnored public internal(set) var capabilityTeardownTask: Task<Void, Never>?
    @ObservationIgnored var haTeardownToken: UInt64 = 0
    var activeDualProvider: DualSourceHomeProvider?
    var activeHAProvider: (any HomeProvider)?
    var activeHAConfig: (url: String, token: String)?
    var activeMiAccountsProvider: MiAccountsProvider? {
        didSet {
            if activeMiAccountsProvider == nil { activeMiProviderAccounts = [] }
        }
    }
    var activeMiProviderAccounts: [MiAccount] = []
    @ObservationIgnored var miAccountsConfigEpoch: Int = 0
    static let autoHADiscoveryCooldown: Duration = .seconds(300)
    var lastAutoHADiscoveryAt: ContinuousClock.Instant?
    var isPerformingResumeRefresh = false
    @ObservationIgnored var haLANDiscoverer: @Sendable (String) async -> [HADiscoveredInstance] = {
        await HADiscovery.discoverOnLAN(currentURLHint: $0)
    }
    /// Panel open, Mac awake, Low Power Mode; the provider paces polling with it (#26).
    public internal(set) var pollingContext = PollingContext() {
        didSet {
            if pollingContext.systemActive != oldValue.systemActive {
                syncResumeSystemActive(pollingContext.systemActive)
            }
        }
    }
    var pollingContextSync: Task<Void, Never>?
    var debounceTasks: [String: Task<Void, Never>] = [:]
    struct DebouncedWriteState {
        let token: UUID
        let deviceId: String
        var origin: SmartDevice
        /// The revision this drag owns and the fields it changed, kept so a patch that can no
        /// longer be sent can put back exactly what it showed.
        let revision: UInt64
        let fields: Set<OptimisticField>
    }
    var debouncedWrites: [String: DebouncedWriteState] = [:]
    struct ManualWritePatch {
        enum Phase {
            case debouncing
            case inFlight
            case succeeded
        }
        let slotKey: String
        let token: UUID
        var phase: Phase
        let fields: Set<OptimisticField>
        var lockEntry: OptimisticLockEntry?
        /// For a cover position write: what it commands and the hazard answer that covers it.
        var coverDrag: CoverDragPlan?
        let apply: @Sendable (inout SmartDevice) -> Void
    }
    struct ManualWriteSession {
        var revision: UInt64
        var base: SmartDevice
        var baseCoverOrigin: Int?
        var baseFieldLocks: [OptimisticField: OptimisticLockEntry]
        var patches: [ManualWritePatch]
    }
    var manualWriteSessions: [String: ManualWriteSession] = [:]
    struct FacetWriteState {
        enum Phase {
            case debouncing
            case inFlight
        }
        let token: UUID
        let origin: JSONValue?
        let originSnapshotGeneration: UInt64
        let value: JSONValue?
        /// Confirmation kind covering this tick's value when `dispatchFacetWrite` rechecks before sending.
        let approval: FacetDragApproval?
        /// Confirmation kinds the user already approved during this still-debouncing slider drag.
        var confirmedApprovals: Set<FacetDragApproval>
        var phase: Phase
        var bannerID: UUID?
    }
    var facetWrites: [String: FacetWriteState] = [:]
    /// Latest provider- or LAN-reported device rows before optimistic locks merge local values on top.
    /// Written only by real device reports (`snapshotUpdated`, `applyLGDeviceUpdate`) and cleared in
    /// `invalidateUndoContext()` and per-account in `logoutMiAccount(id:)` (§13).
    @ObservationIgnored var lastReportedDevices: [String: SmartDevice] = [:]
    /// Latest provider-reported facet rows before `optimisticFacetLocks` preserve local values.
    /// Written only by `snapshotUpdated` and cleared in `invalidateUndoContext()` and per-account in
    /// `logoutMiAccount(id:)` (§13), so local `deviceFacets` mutations can never poison baselines.
    @ObservationIgnored var lastReportedFacets: [String: [FacetControl]] = [:]
    var undoTimerTask: Task<Void, Never>?
    /// Bulk actions whose commands are still being sent, keyed by the banner they created.
    /// 撤销 stops the entry here and waits on its task before restoring (`HomeStore+Undo.swift`).
    var runningBatches: [UUID: RunningBatch] = [:]
    /// Undo tasks currently suspended on an in-flight batch. Tests wait on this instead of yielding.
    var undoInFlightWaiters = 0
    private var toastTimerTask: Task<Void, Never>?
    var optimisticFieldLocks: [OptimisticLockKey: OptimisticLockEntry] = [:]
    var optimisticFacetLocks: [String: OptimisticLockEntry] = [:]
    var optimisticLockRevision: [String: UInt64] = [:]
    var optimisticFieldRevisions: [OptimisticLockKey: UInt64] = [:]
    var optimisticFacetRevisions: [String: UInt64] = [:]
    @ObservationIgnored var hasCustomOptimisticNow = false
    @ObservationIgnored var optimisticNow: @Sendable () -> Date = { Date() } {
        didSet { hasCustomOptimisticNow = true }
    }
    @ObservationIgnored let optimisticClockAnchorInstant = ContinuousClock.now
    @ObservationIgnored let optimisticClockAnchorDate = Date()
    var coverCommandOrigins: [String: Int] = [:]
    /// The cover position hazard prompt the user answered, per debounce slot: the confirmation kind
    /// that was approved and the slot token carrying it. A direction answer and an unknown-start
    /// answer are different kinds, so a drag whose start becomes known or unknown cannot reuse the
    /// other kind. `setCoverPosition` honours it only while that slot is still accumulating the same
    /// drag and the tick needs the same kind, so a reversal or a second drag after the command went
    /// out asks again.
    var confirmedCoverDragAnswers: [String: (token: UUID, approval: CoverDragApproval)] = [:]
    /// Last position each cover reported. Inferred travel survives only while this value changes,
    /// so an obstructed motor with a stale target stops showing "opening" (#298).
    @ObservationIgnored var lastCoverPositions: [String: Int] = [:]
    public static let deviceAliasesKey = ViewPreferenceKeys.deviceAliases
    @ObservationIgnored var rawDeviceNames: [String: String] = [:]
    @ObservationIgnored var lastHistoryRecordAt: Date?

    @ObservationIgnored var safetyMonitor: SafetyMonitor
    var awayGap = MacAwayGap(includesAway: false)

    static let lastManualLightIdKey = ViewPreferenceKeys.lastManualLightId
    /// Last light the user switched on by hand; the 柔和夜灯 fallback uses it instead of "主卧" (#36).
    var lastManuallyUsedLightId: String?
    /// A legacy 主卧/阳台 menu-bar mode was migrated; pick the first temperature sensor when readings arrive.
    var pendingLegacyMenuBarTargetMigration = false
    public internal(set) var capabilitySelection = CapabilitySelection(
        enabledConnections: [],
        enabledConnectionScopes: [],
        enabledFeatures: Set(FeatureID.allCases),
        enabledCategories: Set(DeviceCategoryID.allCases)
    ) {
        didSet {
            if !isPersistingCompanionToggle, !companionRevokedForSession,
               oldValue.enabledFeatures.contains(.companionIntegration) != companionIntegrationEnabled {
                applyCompanionIntegrationTransition(enabled: companionIntegrationEnabled)
            }
            if oldValue.enabledFeatures.contains(.eventAutomation) != eventAutomationEnabled {
                automationGeneration &+= 1
                let generation = automationGeneration
                Task { @MainActor [weak self] in
                    guard let self, self.automationGeneration == generation else { return }
                    self.automationAvailabilityDidChange()
                }
            }
            if oldValue.enabledCategories.contains(.tv) != capabilitySelection.enabledCategories.contains(.tv),
               let lgDev = latestLGDevice {
                // Restoring a card the type toggle hid keeps the user's favorite choice.
                applyLGDeviceUpdate(lgDev, favoritesNewCard: false)
            }
            if oldValue.enabledCategories != capabilitySelection.enabledCategories {
                scheduleRaycastSnapshotExport()
            }
            guard oldValue.enabledCategories.contains(.camera),
                  !capabilitySelection.enabledCategories.contains(.camera) else { return }
            // The cards are still in `devices` here; the next refresh prunes them, so the stop requests
            // have to carry the devices themselves.
            onCameraCategoryDisabled?(devices.filter { if case .camera = $0.kind { true } else { false } })
        }
    }
    public internal(set) var capabilityResolutionMode: CapabilityInstallResolutionMode = .freshInstall
    public internal(set) var identityMigrationDiagnostic: String?
    public internal(set) var capabilityGeneration: Int = 0
    public internal(set) var capabilityMergeConflictCount: Int = 0
    public internal(set) var lastCapabilityMergeDiagnostic: String?
    public internal(set) var isVerifyingHAOnboarding: Bool = false
    /// Unfinished single-connection removal records (P2c-M); surfaced in Settings for retry.
    public internal(set) var pendingConnectionRemovals: [ConnectionRemovalRecord] = []
    /// True when `connection_removal_v1` failed strict parsing (fail-closed, never treated as empty).
    public internal(set) var hasCorruptConnectionRemovalState: Bool = false
    /// Last failure while persisting/verifying the quarantine backup before discarding a corrupt removal record (#381).
    public internal(set) var corruptRemovalDiscardFailure: ConnectionRemovalQuarantineFailure?
    /// Test seam overriding quarantine directory & sync primitives so tests never touch real Application Support.
    @ObservationIgnored var corruptRemovalQuarantineHooks: ConnectionRemovalStore.QuarantinePersistenceHooks = .live
    /// Scopes currently executing drain + slot deletion on this instance.
    public internal(set) var isRemovingConnectionScopes: Set<String> = []
    /// Test seam invoked right after drain completes and before credential slots are mutated.
    @ObservationIgnored var connectionRemovalBeforeSlotDeleteHook: (@MainActor (ConnectionRemovalRecord) async -> Void)?
    @ObservationIgnored var lgWebOSConnectionOverrideForTesting: (@Sendable () async throws -> Void)?
    @ObservationIgnored var capabilityStoreRevision: Int?
    @ObservationIgnored let usesInjectedProvider: Bool
    @ObservationIgnored var preDemoBackend: HomeBackend?
    @ObservationIgnored var haOnboardingVerifier: (@Sendable (String, String) async throws -> Void)?
    @ObservationIgnored var activeHAOnboardingAttemptID: UUID?
    @ObservationIgnored var activeHAOnboardingTask: Task<HAOnboardingConnectOutcome, Never>?
    public var onMiAccountDisabled: (@MainActor (String, Set<String>) -> Void)?
    public var onHAConnectionDisabled: (@MainActor (Set<String>) -> Void)?
    /// Fires once when the camera type closes, with the camera cards still on the panel (P3c-CM).
    public var onCameraCategoryDisabled: (@MainActor ([SmartDevice]) -> Void)?
    @ObservationIgnored var automationGeneration: UInt64 = 0
    @ObservationIgnored var reconciledAutomationGeneration: UInt64 = 0
    public var onAutomationRulesChanged: (@MainActor () -> Void)?
    /// Monotonic generation for companion integration (Raycast / CLI / MCP / external links).
    public internal(set) var companionGeneration: UInt64 = 0
    @TaskLocal static var companionCommandContext: (owner: ObjectIdentifier, generation: UInt64)?
    public var activeCompanionCommandGeneration: UInt64? {
        guard let context = Self.companionCommandContext, context.owner == ObjectIdentifier(self) else { return nil }
        return context.generation
    }
    var companionRevokedForSession = false
    @ObservationIgnored var isPersistingCompanionToggle = false
    public var onCompanionIntegrationChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var miAccountsProviderFactory: (@MainActor ([MiAccount]) -> MiAccountsProvider)?
    @ObservationIgnored var haProviderFactory: (@MainActor (String, String) -> any HomeProvider)?
    @ObservationIgnored var explicitlyDisabledConnections: Set<ConnectionCapabilityID> = []
    @ObservationIgnored var explicitlyDisabledScopes: Set<String> = []
    @ObservationIgnored var lastPersistedCapabilitySelection: CapabilitySelection?
    @ObservationIgnored var lastPersistedDisabledConnections: Set<ConnectionCapabilityID> = []
    @ObservationIgnored var lastPersistedDisabledScopes: Set<String> = []
    @ObservationIgnored var revokedMiAccountScopes: Set<String> = []
    @ObservationIgnored var indexedDevicesById: [String: CapabilityIndexedDevice] = [:]
    @ObservationIgnored var indexedScenesById: [String: SceneReference] = [:]
    @ObservationIgnored var miotDidToAccountScopes: [String: Set<String>] = [:]
    /// Timers paused by an account/connection disable. Observed so the assistant bar can list them;
    /// they stay cancellable while paused.
    public internal(set) var pausedScheduledCommands: [PausedScheduledCommand] = []
    public internal(set) var scheduledCommandsEnabled = true
    @ObservationIgnored var scheduledCommandsGeneration: UInt64 = 0
    @ObservationIgnored var pausedQuickActionIDs: Set<String> = []
    /// Scopes each paused quick action lost, so its resume decision can be per-item instead of
    /// waiting for every account.
    @ObservationIgnored var pausedQuickActionScopes: [String: [String]] = [:]
    @ObservationIgnored var pendingRevalidationScopes: Set<String> = []

    public init(
        provider: (any HomeProvider)? = nil,
        dualSource: (homeAssistant: any HomeProvider, xiaomiCloud: any HomeProvider)? = nil,
        defaultsSuiteName: String? = nil,
        updater: AppUpdater? = nil,
        credentialVault: CredentialVault? = nil,
        topologyCache: MiTopologyCache? = nil,
        miAccountsProviderFactory: (@MainActor ([MiAccount]) -> MiAccountsProvider)? = nil,
        haProviderFactory: (@MainActor (String, String) -> any HomeProvider)? = nil,
        defaults: UserDefaults? = nil
    ) {
        let ud = defaults ?? defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.userDefaults = ud
        self.usesInjectedProvider = (provider != nil || dualSource != nil)
        self.credentialVault = credentialVault
        self.miAccountsProviderFactory = miAccountsProviderFactory
        self.haProviderFactory = haProviderFactory
        self.topologyCache = topologyCache ?? (ud === UserDefaults.standard ? .shared : nil)
        let initialPins = DeviceSourcePinStorage.load(defaults: ud)
        self.pinnedDeviceSourcesBox = DeviceSourcePinBox(initialPins)
        self.pinnedDeviceSources = initialPins
        let isTestEnvironment = (provider != nil || dualSource != nil || defaultsSuiteName != nil || defaults != nil)
        self.isTestEnvironment = isTestEnvironment
        self.updater = updater ?? AppUpdater()
        self.energyHistory = EnergyHistory(defaults: ud)
        self.offlineHistory = OfflineHistory(defaults: ud)
        self.sensorHistory = SensorHistory(defaults: ud)
        // ≤1.0.6 mirrored credentials into plain `UserDefaults`; move them into the Keychain before any read (#16).
        if !isTestEnvironment && ud === UserDefaults.standard {
            KeychainHelper.migratePlaintextCredentialsToKeychain(defaults: ud, vault: credentialVault ?? .shared)
        }
        let boolOrDefaultTrue = { (key: String) -> Bool in
            ud.object(forKey: key) == nil ? true : ud.bool(forKey: key)
        }
        self.automaticallyChecksForUpdates = boolOrDefaultTrue("automatically_checks_for_updates")

        let savedLangPref = ud.string(forKey: "app_language").flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        self.appLanguagePreference = savedLangPref
        let initialEffective: AppLanguage = (self.isTestEnvironment && savedLangPref == .system)
            ? .zhHans
            : savedLangPref.resolved()
        self.effectiveLanguage = initialEffective
        if !self.isTestEnvironment {
            L10n.currentLanguage = initialEffective
        }

        let initialRemovalState = ConnectionRemovalStore.readState(defaults: ud)
        if initialRemovalState.readError {
            ConnectionRemovalStore.quarantineCorruptPayloadIfNeeded(defaults: ud)
        }
        self.hasCorruptConnectionRemovalState = initialRemovalState.readError
        self.pendingConnectionRemovals = initialRemovalState.records
        let pendingMiScopesAtLaunch = Set(initialRemovalState.records.filter { $0.kind == .mi }.map(\.scope))
        let hasPendingHAAtLaunch = initialRemovalState.readError
            || initialRemovalState.records.contains { $0.kind == .ha }

        let initialAccountsResult = MiSessionStore.loadAccountsResult(defaults: ud, vault: credentialVault)
        let initialAccounts = initialRemovalState.readError
            ? []
            : initialAccountsResult.accounts.filter { !pendingMiScopesAtLaunch.contains($0.id) }
        self.miAccounts = initialAccounts
        let initialMiSession = initialAccounts.first?.session
        let savedRegion = ud.string(forKey: "mi_cloud_region").flatMap(MiCloudRegion.init(rawValue:))
            ?? initialMiSession.flatMap { MiCloudRegion(rawValue: $0.region.lowercased()) }
            ?? .cn
        self.miCloudRegion = savedRegion

        let savedURL = ud.string(forKey: "ha_server_url") ?? KeychainHelper.defaultNASURL
        self.serverURLString = savedURL
        let initialBackend = ud.string(forKey: "home_backend").flatMap(HomeBackend.init(rawValue:)) ?? .homeAssistant
        self.homeBackend = initialBackend
        // Demo mode and injected providers without a dedicated test vault must not touch the system Keychain.
        let needsInitialHAToken = initialBackend != .demo && ((provider == nil && dualSource == nil) || credentialVault != nil)
        let initialHAToken = (!hasPendingHAAtLaunch && needsInitialHAToken)
            ? KeychainHelper.loadToken(defaults: ud, vault: credentialVault)
            : ""
        self.hasHASource = !initialHAToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.miSessionMaskedUserId = initialMiSession?.maskedUserId
        self.miSessionExpiresAt = initialAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = initialMiSession?.historyScopeIdentifier
        // Defer legacy bare home ID migration until `resolveLaunchCapabilities` confirms Keychain/account
        // readability so a transient Keychain failure never deletes `mi_selected_home_id` (P1-1).
        self.selectedMiHomeId = ud.string(forKey: MiCloudProvider.selectedHomeKey)
        let initialLGConfig = LGWebOSConfig.load(from: ud, vault: credentialVault)
        self.lgConfig = initialLGConfig
        self.homeName = HomePreferences.homeName.load(from: ud)
        self.isHabitLearningEnabled = boolOrDefaultTrue("assistant_habit_learning_enabled")
        let habitShareKey = "assistant_habit_share_enabled"
        let storedHabitShare: StoredHabitShare
        if let object = ud.object(forKey: habitShareKey) {
            if let flag = object as? Bool {
                storedHabitShare = flag ? .on : .off
            } else {
                storedHabitShare = .absent
            }
        } else {
            storedHabitShare = .absent
        }
        let habitShare = resolveHabitSharing(storedHabitShare)
        if habitShare.persistOff {
            ud.set(false, forKey: habitShareKey)
        }
        self.habitSharing = habitShare.sharing
        // Privacy-first default: ask for on-device recognition unless the user explicitly opted out (#50).
        self.prefersOnDeviceSpeech = boolOrDefaultTrue("assistant_on_device_speech")
        self.hasCompletedOnboarding = ud.bool(forKey: "has_completed_onboarding")
        self.launchAtLoginOnboardingChoice = boolOrDefaultTrue(Self.launchAtLoginOnboardingChoiceKey)
        self.hasAppliedLaunchAtLoginOnboardingChoice = ud.bool(forKey: Self.launchAtLoginChoiceAppliedKey)
        self.hasDismissedLaunchAtLoginSuggestion = ud.bool(forKey: Self.launchAtLoginSuggestionDismissedKey)
        self.launchAtLoginRegistrationFailed = ud.bool(forKey: Self.launchAtLoginRegistrationFailedKey)
        self.onboardingMilestones = Set(
            (ud.stringArray(forKey: Self.onboardingMilestonesKey) ?? [])
                .compactMap(OnboardingMilestone.init(rawValue:))
        )
        self.askWhenUnsureBeforeAIActions = boolOrDefaultTrue(Self.askWhenUnsureKey)
        self.hideOfflineDevices = HomePreferences.hideOfflineDevices.load(from: ud)
        self.hideGroupedLights = HomePreferences.hideGroupedLights.load(from: ud)
        self.allowAdvancedFacetWrites = HomePreferences.allowAdvancedFacetWrites.load(from: ud)
        self.enableGlobalHotkey = HomePreferences.enableGlobalHotkey.load(from: ud)
        self.enableVoiceInput = HomePreferences.enableVoiceInput.load(from: ud)
        self.enableSafetyAlerts = HomePreferences.enableSafetyAlerts.load(from: ud)
        self.doorbellAutoPopup = HomePreferences.doorbellAutoPopup.load(from: ud)
        self.enableWeeklyHealthReport = HomePreferences.enableWeeklyHealthReport.load(from: ud)
        self.doorbellChime = HomePreferences.doorbellChime.load(from: ud)
        self.doorbellPopupSeconds = HomePreferences.doorbellPopupSeconds.load(from: ud)
        self.blockControlWhileLocked = HomePreferences.blockControlWhileLocked.load(from: ud)
        self.sensorAlertsOnlyWhenAway = HomePreferences.sensorAlertsOnlyWhenAway.load(from: ud)
        self.sensorAlertPreferences = SensorAlertKind.allCases.reduce(into: [SensorAlertKind: Bool]()) { preferences, kind in
            if ud.object(forKey: kind.defaultsKey) != nil {
                preferences[kind] = ud.bool(forKey: kind.defaultsKey)
            }
        }
        self.awayGap = MacAwayGap(includesAway: ud.bool(forKey: MacAwayGap.storageKey))
        self.isCompactGridMode = HomePreferences.isCompactGridMode.load(from: ud)
        self.showQuickActionsBar = HomePreferences.showQuickActionsBar.load(from: ud)
        self.menuBarTargetId = HomePreferences.menuBarTargetId.load(from: ud)
        self.lastManuallyUsedLightId = ud.string(forKey: Self.lastManualLightIdKey)
        self.safetyMonitor = SafetyMonitor(defaults: ud)

        let savedModeRaw = ud.string(forKey: "menubar_display_mode")
        if let savedModeRaw, let mode = MenuBarDisplayMode(rawValue: savedModeRaw) {
            self.menuBarDisplayMode = mode
        } else if let savedModeRaw, MenuBarDisplayMode.legacyTemperatureRawValues.contains(savedModeRaw) {
            // ≤1.0.x stored 主卧/阳台 modes. Keep the user on a temperature readout, but let the
            // generic sensor option pick whichever sensor exists in this home (#36).
            self.menuBarDisplayMode = .sensorTemperature
            ud.set(MenuBarDisplayMode.sensorTemperature.rawValue, forKey: "menubar_display_mode")
            let savedTarget = ud.string(forKey: "menubar_target_id")
            self.pendingLegacyMenuBarTargetMigration = savedTarget == nil || savedTarget == "auto:primary"
        } else {
            self.menuBarDisplayMode = .sensorTemperature
        }

        self.favoriteDeviceIds = HomePreferences.favoriteDeviceIds.load(from: ud)
        self.favoriteOrder = HomePreferences.favoriteOrder.load(from: ud)
        self.hiddenDeviceIds = HomePreferences.hiddenDeviceIds.load(from: ud)
        self.allOffOverrides = HomePreferences.allOffOverrides.load(from: ud)

        let initialHasHASource = !initialHAToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasExplicitOnboardingFlag = ud.object(forKey: "has_completed_onboarding") != nil
        let capResolution = Self.resolveLaunchCapabilities(
            defaults: ud,
            vault: credentialVault,
            accountsResult: initialAccountsResult,
            hasHASource: initialHasHASource,
            serverURLString: savedURL,
            lgHasConfiguredHost: initialLGConfig.hasConfiguredHost,
            isTestEnvironment: isTestEnvironment,
            checkHATokenVault: needsInitialHAToken,
            legacyVoiceInput: HomePreferences.enableVoiceInput.load(from: ud),
            pendingMiRemovalScopes: pendingMiScopesAtLaunch,
            connectionRemovalReadError: initialRemovalState.readError
        )
        self.capabilitySelection = capResolution.selection
        self.capabilityResolutionMode = capResolution.mode
        self.identityMigrationDiagnostic = capResolution.retryDiagnostic
        self.capabilityStoreRevision = CapabilitySelectionStore.currentRevision(defaults: ud)
        self.selectedMiHomeId = Self.resolveSelectedMiHomeId(
            defaults: ud,
            accountsResult: initialAccountsResult,
            canMigrateLegacySelection: capResolution.retryDiagnostic == nil
        )
        switch capResolution.mode {
        case .freshInstall:
            // Record explicit `false` so a second launch before connecting/skipping still opens
            // first-run onboarding even after `capability_selection_v1` seals `migrationComplete`.
            if !hasExplicitOnboardingFlag {
                ud.set(false, forKey: "has_completed_onboarding")
            }
        case .legacyPreserved, .explicit:
            // Upgraded installs (including demo-only or capability-selection-only records) migrate
            // silently without popping onboarding or registering launch-at-login.
            if !hasExplicitOnboardingFlag {
                self.hasCompletedOnboarding = true
                ud.set(true, forKey: "has_completed_onboarding")
            }
        case .uncertainFallback:
            // Fail-closed: never seal onboarding or migration state while reads are uncertain.
            break
        }
        // Bookkeeping is loaded whenever the envelope is readable, including `uncertainFallback`
        // caused by an unavailable credential slot: dropping the explicit disables there would
        // re-enable an account the user turned off as soon as `miAccounts` loads (H4).
        self.explicitlyDisabledConnections = CapabilitySelectionStore.explicitlyDisabledConnections(defaults: ud)
        self.explicitlyDisabledScopes = CapabilitySelectionStore.explicitlyDisabledScopes(defaults: ud)
        self.lastPersistedCapabilitySelection = capResolution.selection
        self.lastPersistedDisabledConnections = self.explicitlyDisabledConnections
        self.lastPersistedDisabledScopes = self.explicitlyDisabledScopes
        let initialEnabledAccounts = initialAccounts.filter {
            capResolution.selection.enabledConnections.contains(.xiaomiCloud)
                && capResolution.selection.enabledConnectionScopes.contains($0.id)
        }
        self.miSessionExpiresAt = initialEnabledAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = initialEnabledAccounts.first?.session.historyScopeIdentifier

        let initialProvider: any HomeProvider
        if let provider {
            initialProvider = provider
        } else if let dualSource {
            initialProvider = Self.makeComposite(
                homeAssistant: dualSource.homeAssistant,
                xiaomiCloud: dualSource.xiaomiCloud,
                defaults: ud,
                pinBox: pinnedDeviceSourcesBox
            )
        } else if initialBackend == .demo {
            initialProvider = DemoHomeProvider()
        } else if capResolution.retryDiagnostic != nil {
            initialProvider = Self.makeComposite(
                homeAssistant: nil,
                xiaomiCloud: nil,
                defaults: ud,
                pinBox: pinnedDeviceSourcesBox
            )
        } else {
            initialProvider = DemoHomeProvider()
        }
        self.provider = initialProvider
        loadPersistedCapabilityState()
        if provider == nil, dualSource == nil, initialBackend != .demo, !isIdentityUncertain {
            self.provider = makeLiveProvider()
        }
        syncHistoryConnectionScopes()
        scheduleMiSessionExpiryTransition()
        if !isIdentityUncertain || usesInjectedProvider || initialBackend == .demo {
            startListening()
        }
        restoreScheduledCommands()
        // Demo mode, uncertain identity launches, and unconfigured fresh installs are strictly offline:
        // no LAN discovery at launch, and LG webOS only starts when identity is confirmed and a host is configured (#47, P4a-M).
        if provider == nil, dualSource == nil, initialBackend != .demo, !isIdentityUncertain {
            startLGWebOSIfNeeded()
        }
        let interruptedRemovals = initialRemovalState.records.filter { $0.stage != .failed }
        if !isIdentityUncertain, !interruptedRemovals.isEmpty {
            Task { @MainActor [weak self] in
                for record in interruptedRemovals {
                    _ = await self?.retryConnectionRemoval(scope: record.scope)
                }
            }
        }
    }

    /// One `MiCloudProvider` per account behind a single `HomeProvider`, so a second sign-in merges
    /// into the panel instead of replacing the first account.
    private static func makeMiAccountsProvider(
        accounts: [MiAccount],
        defaults: UserDefaults,
        topologyCache: MiTopologyCache?,
        typePrunePolicyLoader: @escaping @Sendable () -> MiotTypePrunePolicy
    ) -> MiAccountsProvider {
        nonisolated(unsafe) let ud = defaults
        return MiAccountsProvider(
            accounts: accounts,
            topologyCache: topologyCache,
            selectedHomeLoader: { ud.string(forKey: MiCloudProvider.selectedHomeKey) },
            clearSelectedHome: { ud.removeObject(forKey: MiCloudProvider.selectedHomeKey) },
            typePrunePolicyLoader: typePrunePolicyLoader
        )
    }

    /// Re-reads the stored accounts (a login, a removal or a sign-out changed them) and rebuilds the
    /// provider around the enabled list.
    func makeMiAccountsProvider(migrateLegacyMiEnvelope: Bool = true) -> MiAccountsProvider {
        miAccounts = loadActiveMiAccounts(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope)
        let enabled = enabledMiAccounts
        activeMiProviderAccounts = enabled
        if let factory = miAccountsProviderFactory {
            return factory(enabled)
        }
        let box = miotTypePruneBox
        return Self.makeMiAccountsProvider(
            accounts: enabled,
            defaults: userDefaults,
            topologyCache: topologyCache,
            typePrunePolicyLoader: { box.get() }
        )
    }

    /// Re-resolves `effectiveLanguage` and pushes it to `L10n`; also called from the language
    /// preference setter and from localization extensions (#52).
    func syncEffectiveLanguage() {
        let next: AppLanguage = (isTestEnvironment && appLanguagePreference == .system)
            ? .zhHans
            : appLanguagePreference.resolved()
        effectiveLanguage = next
        if !isTestEnvironment {
            L10n.currentLanguage = next
        }
        if homeName == "我的家" || homeName == "My Home" {
            let localizedDefault = next == .en ? "My Home" : "我的家"
            if homeName != localizedDefault {
                homeName = localizedDefault
            }
        }
        scheduleRaycastSnapshotExport()
    }

    public func showToast(
        _ message: String,
        isError: Bool = false,
        action: ToastAction? = nil,
        persistent: Bool = false
    ) {
        let notice = ToastNotice(message: message, isError: isError, action: action, persistent: persistent)
        if notice.persistent,
           let current = toastNotice,
           current.persistent,
           current.message == notice.message,
           current.isError == notice.isError,
           current.action == notice.action {
            return
        }
        // A suspension from an old session must not hide a fresh prompt after the session came back.
        if isSessionToastSuspended, !miSessionBlocksControl {
            isSessionToastSuspended = false
        }
        // Another blocked write while the prompt is behind an ordinary toast must neither stack a
        // copy nor steal that ordinary message; the prompt returns when the ordinary toast ends.
        if notice.persistent, isSessionToastSuspended {
            return
        }
        // An ordinary toast may replace the prompt, so its message is never swallowed. Remember
        // the prompt so the end of that toast can put it back.
        if !notice.persistent,
           miSessionBlocksControl,
           let current = toastNotice,
           current.persistent,
           current.action?.kind == .presentMiReauth {
            isSessionToastSuspended = true
        }
        toastNotice = notice
        toastTimerTask?.cancel()
        toastTimerTask = nil
        let interval = toastDismissInterval(for: notice)
        activeToastDismissInterval = interval
        guard let interval else { return }
        toastTimerTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            if self?.toastNotice?.id == notice.id {
                self?.toastNotice = nil
                self?.activeToastDismissInterval = nil
                self?.restoreSuspendedSessionToast()
            }
        }
    }

    public func dismissToast() {
        toastTimerTask?.cancel()
        toastTimerTask = nil
        toastNotice = nil
        activeToastDismissInterval = nil
        restoreSuspendedSessionToast()
    }

    /// The ordinary toast in front of the expired-session prompt ended. Put the prompt back while
    /// the session is still blocked. A recovered session or a context change cleared the flag, so
    /// nothing is restored then. Restoring goes through `showToast`, which never re-enters here:
    /// a persistent toast has no timer and is not itself preceded by a persistent prompt.
    private func restoreSuspendedSessionToast() {
        guard isSessionToastSuspended else { return }
        isSessionToastSuspended = false
        guard miSessionBlocksControl else { return }
        showSessionExpiryToast()
    }

    /// Success stays for `toastAutoDismissInterval` (2.8 s). An error stays for 8 s.
    /// A persistent toast, and any toast while the test seam is `nil`, stays until dismissed.
    func toastDismissInterval(for notice: ToastNotice) -> Duration? {
        if notice.persistent { return nil }
        guard toastAutoDismissInterval != nil else { return nil }
        if notice.isError { return Self.errorToastDismissInterval }
        return toastAutoDismissInterval
    }

    // MARK: - Command Execution & Optimistic Locks

    func updateValueFreshness() {
        switch connectionStatus {
        case .disconnected where hasReceivedInitialSnapshot && homeBackend != .demo:
            deviceValuesAreStale = true
        case .connected:
            deviceValuesAreStale = false
        case .connecting, .disconnected:
            break
        }
    }

    // MARK: - Assistant Commands & Personalized Jev Context

    public var isShowingAssistantBar: Bool = false
    /// Bumped to ask an already-visible command bar to take keyboard focus.
    public internal(set) var assistantFocusRequest: Int = 0
    /// Bumped to ask the command bar to start or toggle live speech recognition.
    public internal(set) var assistantVoiceRequest: Int = 0
    public internal(set) var assistantState: AssistantState = .idle
    /// Receipt for the latest command, cleared as soon as the reply resets (#93).
    public internal(set) var lastAssistantReceipt: AssistantExecutionReceipt?
    /// A command or suggestion request waiting for the user to allow sending it to a cloud AI service (#20).
    public internal(set) var pendingCloudConsent: PendingCloudConsent?
    public internal(set) var assistantSuggestions: [AssistantSuggestion] = []
    /// Cached model proactive recommendations for `lastProactiveRefreshSignature` (#113).
    var aiProactiveSuggestions: [AssistantSuggestion]?
    public internal(set) var isProactiveRecommending: Bool = false
    /// Ambient signature (time bucket + rounded readings) the suggestion cache was built from (#113).
    var lastProactiveRefreshSignature: String?
    /// Earliest moment a failed background refresh may retry (Codex #116 review).
    var proactiveRetryEarliest: Date?
    /// Cooldown before a failed background refresh retries; test seam.
    var proactiveRetryCooldown: TimeInterval = 300
    /// The running silent refresh, exposed so tests can await it.
    var proactiveRefreshTask: Task<Void, Never>?
    var assistantResetTask: Task<Void, Never>?
    /// Test seam replacing the network resolver built from `assistantConfig`.
    var assistantResolverOverride: ModelIntentResolver?
    /// Test seam replacing only the HTTP transport while still resolving `assistantConfig` from `userDefaults`.
    var assistantTransportOverride: ModelIntentResolver.Transport?
    /// Generation of the AI feature's request surface (P5a-M). Bumped when the AI switch flips,
    /// the provider config changes, or a provider is removed. A request captures the value
    /// before its first await and discards anything that arrives under a newer generation, so a
    /// late result can neither drive a device nor claim the suggestion cache — the macOS mirror
    /// of Windows' `assistantEpoch`.
    @ObservationIgnored public internal(set) var assistantEpoch: Int = 0
    /// `assistantEpoch` of the command that put the bar into `.thinking`, so a discarded older
    /// command clears only its own spinner, never a newer command's (#322).
    @ObservationIgnored var assistantThinkingEpoch: Int?
    /// Generation of the 主动建议 branch alone (P5b-M). Bumped when the suggestions switch flips,
    /// so a closed switch drops in-flight suggestion runs without touching `assistantEpoch` and
    /// therefore without cancelling a command the user started.
    @ObservationIgnored var proactiveEpoch: Int = 0
    /// Suggestion-only work done so far (P5b-M test seam): with the switch off every count stays 0.
    @ObservationIgnored var proactiveWorkCounters = ProactiveWorkCounters()
    /// Test seam replacing the on-device resolver built by `localCommandResolver(for:)`.
    var localAssistantResolverOverride: (any AssistantCommandResolving)?
    /// Test seam overriding whether Apple's on-device model is usable on this machine.
    var localAssistantAvailabilityOverride: AssistantLocalModelAvailability?
    /// Commands waiting on a spoken delay ("10 分钟后关灯"), soonest first. Persisted across launches.
    /// Holds timers whose captured sources still match the connected ones (ADR-0019).
    public internal(set) var scheduledCommands: [ScheduledCommand] = []
    /// Timers that came due while the app was closed or the Mac slept. Never auto-executed without user confirmation.
    public internal(set) var missedScheduledCommands: [ScheduledCommand] = []
    /// Timers created on another connection source. Kept so a save of the current sources never deletes
    /// them and switching back finds them again; not armed and not shown.
    var foreignScheduledCommands: [ScheduledCommand] = []
    /// The source scopes `scheduledCommands` and `missedScheduledCommands` were partitioned under.
    var scheduledCommandsScope: Set<String> = []
    /// `snapshotGeneration` at the last `startListening()`. Scheduling compares against it so a timer
    /// is never created against the previous source's stale device list (ADR-0019).
    var listeningSnapshotGeneration: UInt64 = 0
    public var onMissedScheduledCommand: ((ScheduledCommand) -> Void)?
    var notifiedMissedTimerIds: Set<UUID> = []
    var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    /// Token of the run currently owning each handle, so a completed run cannot clear a re-armed one.
    var scheduledTaskTokens: [UUID: UUID] = [:]
    /// Calls to `waitForInitialSnapshotIfNeeded` that are inside the wait. Tests wait on this
    /// instead of a fixed `Task.yield` count.
    var initialSnapshotWaiters = 0
    /// Scheduled-command tasks that have left, including cancellation.
    var scheduledTaskExits = 0
    /// Card writes that have finished, including a cancellation that shows no toast.
    @ObservationIgnored var manualWriteExits = 0
    /// The most recent assistant action, kept so "撤销" can restore it after the 5 s banner is gone.
    var lastAssistantUndo: AssistantUndoEntry? {
        didSet {
            if lastAssistantUndo != nil {
                assistantUndoRevision &+= 1
            }
            scheduleRaycastSnapshotExport()
        }
    }
    public var lastAssistantActionAt: Date? { lastAssistantUndo?.at }
    /// How long a spoken "撤销" can still reach back.
    static let voiceUndoWindow: TimeInterval = 10 * 60
    /// Test seam for the delay before a scheduled command fires.
    var assistantSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Test seam for "now" when a timer wakes up, so a Mac that slept through it can be simulated.
    var assistantNow: @Sendable () -> Date = { Date() }
    /// A timer that wakes up later than this (the Mac slept, the app was frozen) waits for the user (#22).
    static let lateTimerGrace: TimeInterval = 60

    // MARK: - Raycast Companion Bridge State

    public internal(set) var lastRaycastCommandFeedback: RaycastCommandFeedback?
    @ObservationIgnored public var raycastSnapshotTestURL: URL?
    @ObservationIgnored var isApplyingProviderSnapshot: Bool = false
    /// Pending coalesced export; see `scheduleRaycastSnapshotExport()`.
    @ObservationIgnored var raycastExportTask: Task<Void, Never>?
    /// Test seam for the quiet period before a coalesced Raycast export.
    @ObservationIgnored var raycastExportSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Last snapshot written to disk, compared without `updatedAt` to skip identical writes.
    @ObservationIgnored var lastExportedRaycastSnapshot: RaycastSnapshot?

    // MARK: - Debounced Resume State

    @ObservationIgnored var debouncedResumeCoordinator: DebouncedResumeCoordinator?
    @ObservationIgnored var resumeSyncTask: Task<Void, Never>?
    @ObservationIgnored var isNetworkSatisfiedForResume: Bool = true
    @ObservationIgnored var knownNetworkSatisfied: Bool?
    @ObservationIgnored var isResumeShutdown: Bool = false
    @ObservationIgnored var resumeDebounceInterval: Duration = .milliseconds(300)
    @ObservationIgnored var resumeMaxDelay: Duration = .seconds(5)
    @ObservationIgnored var resumeScheduler: DebouncedResumeScheduler = .live
    @ObservationIgnored var lastWakeIdentityReadAt: ContinuousClock.Instant?
    @ObservationIgnored var wakeIdentityProviderGeneration: UInt64?
    @ObservationIgnored var onDebouncedResumeHook: (@MainActor (Set<ResumeReason>) async -> Void)?
}
