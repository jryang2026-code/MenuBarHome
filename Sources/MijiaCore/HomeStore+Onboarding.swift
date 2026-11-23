import Foundation

/// Outcome of verifying and connecting Home Assistant from the onboarding guide.
public enum HAOnboardingConnectOutcome: Equatable, Sendable {
    case connected
    case cancelled
    case failed(reason: String, impact: String, action: String)
}

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

    /// Whether launch identity/capability reads failed closed and have not yet recovered.
    var isIdentityUncertain: Bool {
        identityMigrationDiagnostic != nil
    }

    /// Whether passive background network work (auto update checks, debounced resume refresh) must
    /// stay silent: true on uncertain identity reads and on unconfigured live installs (P4a-M).
    var shouldSuppressBackgroundNetworkWork: Bool {
        if isIdentityUncertain || wakeIdentityProviderGeneration != nil { return true }
        if usesInjectedProvider { return false }
        return !hasEnabledConfiguredSource
    }

    /// Resolves the persisted Xiaomi home selection. A bare home ID saved before multi-account has
    /// no account prefix; only migrate or drop it once account reads are confirmed reliable
    /// (`canMigrateLegacySelection == true` and `accountsResult` is `.loaded`), so a transient
    /// Keychain failure never deletes it.
    static func resolveSelectedMiHomeId(
        defaults: UserDefaults,
        accountsResult: MiSessionStore.AccountsLoadResult,
        canMigrateLegacySelection: Bool
    ) -> String? {
        let stored = defaults.string(forKey: MiCloudProvider.selectedHomeKey)
        guard let selection = stored, MiAccountScope.owner(of: selection) == nil else {
            return stored
        }
        guard canMigrateLegacySelection, case .loaded(let accounts) = accountsResult else {
            return stored
        }
        if accounts.count == 1, let onlyAccount = accounts.first {
            let scoped = MiAccountScope.id(selection, account: onlyAccount.id)
            defaults.set(scoped, forKey: MiCloudProvider.selectedHomeKey)
            return scoped
        }
        defaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        return nil
    }

    /// #144: leave the offline demo for a real home. A configured source takes over directly
    /// (restoring the source active before demo when still configured); with none configured the
    /// guide's connect form opens, so the virtual devices do not linger.
    @discardableResult
    public func leaveDemo() -> Bool {
        guard homeBackend == .demo else { return false }
        let prior = preDemoBackend
        preDemoBackend = nil
        if hasHASource || hasMiSource || !miAccounts.isEmpty {
            let target: HomeBackend = if let prior,
                (prior == .homeAssistant && hasHASource)
                    || (prior == .xiaomiCloud && (hasMiSource || !miAccounts.isEmpty)) {
                prior
            } else {
                preferredLiveBackend
            }
            switchBackend(target)
            return true
        }
        switchBackend(.xiaomiCloud)
        reopenOnboarding()
        return false
    }

    static func resolveLaunchCapabilities(
        defaults: UserDefaults,
        vault: CredentialVault?,
        accountsResult: MiSessionStore.AccountsLoadResult,
        hasHASource: Bool,
        serverURLString: String,
        lgHasConfiguredHost: Bool,
        isTestEnvironment: Bool,
        checkHATokenVault: Bool,
        legacyVoiceInput: Bool,
        pendingMiRemovalScopes: Set<String> = [],
        connectionRemovalReadError: Bool = false
    ) -> CapabilityInstallResolution {
        var scopes = accountsResult.accounts.map(\.id).filter { !pendingMiRemovalScopes.contains($0) }
        if hasHASource {
            scopes.append("ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(serverURLString))")
        }
        let hasLegacySettings = defaults.bool(forKey: "has_completed_onboarding")
            || defaults.object(forKey: "home_backend") != nil
            || defaults.object(forKey: "ha_server_url") != nil
            || defaults.object(forKey: "mi_cloud_region") != nil
            || defaults.object(forKey: Self.onboardingMilestonesKey) != nil
            || defaults.object(forKey: "home_name") != nil
            || defaults.object(forKey: ConnectionRemovalStore.storageKey) != nil
            || defaults.object(forKey: RaycastSnapshotExporter.integrationEnabledKey) != nil
            || defaults.object(forKey: URLDirectControl.allowDirectControlKey) != nil
            || lgHasConfiguredHost
        let hasLocalData = !DevicePreferenceIndex.referencedIDs(defaults: defaults).isEmpty
            || defaults.object(forKey: ScheduledCommand.storageKey) != nil
            || defaults.object(forKey: AutomationRuleStore.storageKey) != nil
        let checkMiVault = vault != nil || (!isTestEnvironment && defaults === UserDefaults.standard)
        return CapabilitySelectionStore.resolveAtLaunch(
            defaults: defaults,
            vault: vault,
            configuredScopes: scopes,
            miAccountsResult: accountsResult,
            checkMiVault: checkMiVault,
            checkHATokenVault: checkHATokenVault,
            hasLegacySettingsOrOnboarding: hasLegacySettings,
            hasPersistedLocalData: hasLocalData,
            legacyFeatureFlags: [
                .voiceInput: legacyVoiceInput,
                // macOS shipped Raycast integration off by default; upgrades keep the old switch.
                .companionIntegration: defaults.bool(forKey: RaycastSnapshotExporter.integrationEnabledKey),
            ],
            connectionRemovalReadError: connectionRemovalReadError
        )
    }

    /// Retries reading persisted capability selection and Keychain credentials after a fail-closed
    /// `uncertainFallback` launch. Returns true once reads succeed and migration/state are resolved.
    @discardableResult
    public func retryIdentityMigration() -> Bool {
        retryIdentityMigration(migrateLegacyMiEnvelope: true)
    }

    func retryIdentityMigration(migrateLegacyMiEnvelope: Bool) -> Bool {
        retryIdentityMigration(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope, fromWake: false)
    }

    func rereadIdentityOnWake() {
        _ = retryIdentityMigration(migrateLegacyMiEnvelope: false, fromWake: true)
    }

    private func retryIdentityMigration(migrateLegacyMiEnvelope: Bool, fromWake: Bool) -> Bool {
        syncPendingConnectionRemovals(quarantineCorruptPayload: !fromWake)
        let vault = credentialVault ?? (userDefaults === UserDefaults.standard ? .shared : nil)
        if fromWake {
            if let vault, !vault.reloadForIdentityRecovery() { return false }
            if let vault {
                // A failed launch migration can leave a plaintext credential in its old slot.
                // Leave that credential for the explicit recovery path.
                if userDefaults.object(forKey: KeychainHelper.legacyPlaintextTokenKey) != nil,
                   vault.lookup(KeychainHelper.tokenAccount) == .missing { return false }
                if userDefaults.object(forKey: LGWebOSConfig.clientKeyDefaultsKey) != nil,
                   vault.lookup(LGWebOSConfig.clientKeyAccount) == .missing { return false }
                if userDefaults.object(forKey: MiSessionStore.fallbackDefaultsKey) != nil,
                   vault.lookup(MiSessionStore.keychainAccount) == .missing { return false }
            }
        } else if let vault = credentialVault {
            _ = vault.lookup(CredentialVault.vaultAccount, retryingUnavailable: true)
        } else if !isTestEnvironment && userDefaults === UserDefaults.standard {
            _ = CredentialVault.shared.lookup(CredentialVault.vaultAccount, retryingUnavailable: true)
        }
        let reloadedAccountsResult = MiSessionStore.loadAccountsResult(
            defaults: userDefaults,
            vault: credentialVault,
            retryingUnavailable: false,
            migrateLegacyEnvelope: migrateLegacyMiEnvelope
        )
        let pendingMi = pendingMiRemovalScopes
        let reloadedAccounts = hasCorruptConnectionRemovalState
            ? []
            : reloadedAccountsResult.accounts.filter { !pendingMi.contains($0.id) }
        let needsHAToken = homeBackend != .demo && (!usesInjectedProvider || credentialVault != nil)
        if fromWake, needsHAToken, !hasPendingHARemoval, let vault,
           case .value(let data) = vault.lookup(KeychainHelper.tokenAccount),
           String(data: data, encoding: .utf8) == nil {
            return false
        }
        let reloadedHAToken = (!hasPendingHARemoval && needsHAToken)
            ? KeychainHelper.loadToken(defaults: userDefaults, vault: credentialVault)
            : ""
        let reloadedHasHA = !reloadedHAToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let reloadedLGConfig = fromWake ? LGWebOSConfig.load(from: userDefaults, vault: vault) : lgConfig
        if fromWake, reloadedLGConfig.isEnabled, reloadedLGConfig.hasConfiguredHost, let vault,
           case .value(let data) = vault.lookup(LGWebOSConfig.clientKeyAccount),
           String(data: data, encoding: .utf8) == nil {
            return false
        }
        let hasExplicitOnboardingFlag = userDefaults.object(forKey: "has_completed_onboarding") != nil
        let resolution = Self.resolveLaunchCapabilities(
            defaults: userDefaults,
            vault: credentialVault,
            accountsResult: reloadedAccountsResult,
            hasHASource: reloadedHasHA,
            serverURLString: serverURLString,
            lgHasConfiguredHost: reloadedLGConfig.hasConfiguredHost,
            isTestEnvironment: isTestEnvironment,
            checkHATokenVault: needsHAToken,
            legacyVoiceInput: enableVoiceInput,
            pendingMiRemovalScopes: pendingMi,
            connectionRemovalReadError: hasCorruptConnectionRemovalState
        )
        if fromWake, resolution.retryDiagnostic == nil {
            wakeIdentityProviderGeneration = providerGeneration
            if reloadedLGConfig != lgConfig {
                suppressNextLGConfigDidSetSave = true
                lgConfig = reloadedLGConfig
                suppressNextLGConfigDidSetSave = false
            }
        }
        capabilitySelection = resolution.selection
        capabilityResolutionMode = resolution.mode
        identityMigrationDiagnostic = resolution.retryDiagnostic
        capabilityStoreRevision = CapabilitySelectionStore.currentRevision(defaults: userDefaults)
        explicitlyDisabledConnections = CapabilitySelectionStore.explicitlyDisabledConnections(defaults: userDefaults)
        explicitlyDisabledScopes = CapabilitySelectionStore.explicitlyDisabledScopes(defaults: userDefaults)
        lastPersistedCapabilitySelection = capabilitySelection
        lastPersistedDisabledConnections = explicitlyDisabledConnections
        lastPersistedDisabledScopes = explicitlyDisabledScopes

        guard resolution.retryDiagnostic == nil else {
            if fromWake { return false }
            showToast(
                L10n.tr(
                    "仍无法读取历史配置或凭据，请检查钥匙串授权后重试",
                    "Still unable to read settings or credentials; check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }

        miAccounts = reloadedAccounts
        hasHASource = reloadedHasHA
        selectedMiHomeId = Self.resolveSelectedMiHomeId(
            defaults: userDefaults,
            accountsResult: reloadedAccountsResult,
            canMigrateLegacySelection: true
        )
        miSessionMaskedUserId = reloadedAccounts.first?.maskedUserId
        miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
        switch resolution.mode {
        case .freshInstall:
            if !hasExplicitOnboardingFlag {
                userDefaults.set(false, forKey: "has_completed_onboarding")
            }
        case .legacyPreserved, .explicit:
            if !hasExplicitOnboardingFlag {
                hasCompletedOnboarding = true
            }
        case .uncertainFallback:
            break
        }
        syncHistoryConnectionScopes()
        syncMiotTypePrunePolicy()
        scheduleMiSessionExpiryTransition()
        if fromWake { return true }
        wakeIdentityProviderGeneration = nil
        if !usesInjectedProvider && homeBackend != .demo {
            rebuildLiveProvider(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope)
            startLGWebOSIfNeeded()
        }
        showToast(L10n.tr("已恢复历史配置与凭据读取", "Restored settings and credential access"))
        return true
    }

    /// Cancels any in-flight Home Assistant onboarding verification so closing or navigating back
    /// while verification is pending never commits credentials or flips dual-source.
    public func cancelPendingHAOnboardingVerification() {
        activeHAOnboardingAttemptID = nil
        activeHAOnboardingTask?.cancel()
        activeHAOnboardingTask = nil
        isVerifyingHAOnboarding = false
    }

    /// Verifies a Home Assistant URL and token against a live HA snapshot (not total device count)
    /// before committing via `updateConnection`, rolling back cleanly on failure or cancellation
    /// without overwriting any previously saved valid token.
    public func connectHomeAssistantForOnboarding(
        serverURL: String,
        token: String
    ) async -> HAOnboardingConnectOutcome {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let impact = hasEnabledMiSource
            ? L10n.tr("原有米家连接与已保存令牌保持不变，双源未启用。", "Your Xiaomi Home connection and saved token are unchanged; dual-source was not enabled.")
            : L10n.tr("未写入令牌，原有连接配置保持不变。", "No token was saved; your existing connection settings are unchanged.")
        guard !hasPendingHARemoval else {
            return .failed(
                reason: L10n.tr(
                    "有一个 Home Assistant 连接还没移除完，请先重试清理再保存连接",
                    "A Home Assistant removal is still unfinished; retry the cleanup before saving this connection"
                ),
                impact: impact,
                action: L10n.tr("请到「设置 › 家居连接」重试未完成的移除后再连接。", "Go to Settings › Connections and retry the unfinished removal first.")
            )
        }
        guard !trimmedURL.isEmpty else {
            return .failed(
                reason: L10n.tr("请填写 Home Assistant 地址", "Enter your Home Assistant address"),
                impact: impact,
                action: L10n.tr("填写完整的 http:// 或 https:// 地址后重试。", "Enter a full http:// or https:// address and try again.")
            )
        }
        let normalized = HAWebSocketProvider.normalizeBaseURL(trimmedURL)
        guard let parsed = URL(string: normalized),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = parsed.host, !host.isEmpty else {
            return .failed(
                reason: L10n.tr("Home Assistant 地址格式无效", "Invalid Home Assistant address"),
                impact: impact,
                action: L10n.tr("请检查地址（例如 https://your-home.ui.nabu.casa）后重试。", "Check the address (for example https://your-home.ui.nabu.casa) and try again.")
            )
        }
        guard !trimmedToken.isEmpty else {
            return .failed(
                reason: L10n.tr("请粘贴 Home Assistant 长期访问令牌", "Paste your Home Assistant Long-Lived Access Token"),
                impact: impact,
                action: L10n.tr("在 Home Assistant 个人资料 → 安全页面生成长期访问令牌后重试。", "Create a Long-Lived Access Token on Home Assistant Profile → Security and try again.")
            )
        }
        guard HAPlaintextConsent.allowsToken(to: normalized, defaults: userDefaults) else {
            return .failed(
                reason: HAPlaintextConsent.waitingMessage(normalized),
                impact: impact,
                action: L10n.tr("请改用 https:// 或局域网地址，或在连接设置中确认后连接。", "Use an https:// or local-network address, or confirm in Connection Settings.")
            )
        }

        cancelPendingHAOnboardingVerification()
        let attemptID = UUID()
        activeHAOnboardingAttemptID = attemptID
        isVerifyingHAOnboarding = true
        let verifier: @Sendable (String, String) async throws -> Void = haOnboardingVerifier ?? { url, tok in
            try await Self.verifyHomeAssistantSnapshot(baseURLString: url, token: tok)
        }
        let task = Task<HAOnboardingConnectOutcome, Never> { @MainActor [weak self] in
            do {
                try await verifier(normalized, trimmedToken)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(
                    reason: error.localizedDescription,
                    impact: impact,
                    action: L10n.tr("请核对地址、网络连通性与长期访问令牌后重试。", "Verify the address, network reachability, and Long-Lived Access Token, then retry.")
                )
            }
            guard let self,
                  !Task.isCancelled,
                  self.activeHAOnboardingAttemptID == attemptID else {
                return .cancelled
            }
            let saved = self.updateConnection(serverURL: normalized, token: trimmedToken)
            guard saved else {
                return .failed(
                    reason: L10n.tr("无法写入钥匙串", "Could not save to Keychain"),
                    impact: impact,
                    action: L10n.tr("请授权钥匙串访问后重试。", "Allow Keychain access and try again.")
                )
            }
            if !self.isHAConnectionEnabled {
                _ = self.setHAConnectionEnabled(true)
                if !self.usesInjectedProvider && self.homeBackend != .demo && !self.hasManagedHAProvider {
                    self.rebuildLiveProvider()
                }
            }
            return .connected
        }
        activeHAOnboardingTask = task
        let outcome = await task.value
        if activeHAOnboardingAttemptID == attemptID {
            activeHAOnboardingAttemptID = nil
            activeHAOnboardingTask = nil
            isVerifyingHAOnboarding = false
        }
        return outcome
    }

    enum HAOnboardingVerifyError: LocalizedError, Equatable {
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message
            case .timedOut:
                return L10n.tr("连接 Home Assistant 超时，未收到状态快照", "Timed out waiting for a Home Assistant snapshot")
            }
        }
    }

    nonisolated static func verifyHomeAssistantSnapshot(
        baseURLString: String,
        token: String,
        probeFactory: @Sendable (String, String) async -> HAWebSocketProvider = { url, tok in
            HAWebSocketProvider(baseURLString: url, token: tok)
        },
        timeoutSleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(12))
        }
    ) async throws {
        let probe = await probeFactory(baseURLString, token)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let stream = probe.events()
                        for await event in stream {
                            try Task.checkCancellation()
                            switch event {
                            case .snapshotUpdated:
                                return
                            case .statusChanged(.disconnected(let reason)):
                                let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !detail.isEmpty {
                                    throw HAOnboardingVerifyError.failed(detail)
                                }
                            case .statusChanged(.connecting),
                                 .statusChanged(.connected),
                                 .sourceStatusesChanged,
                                 .localNetworkPermissionChanged,
                                 .sessionExpired,
                                 .doorbellRang,
                                 .miotTypePruneChanged,
                                 .haTypePruneChanged:
                                break
                            }
                        }
                        try Task.checkCancellation()
                        throw HAOnboardingVerifyError.failed(
                            L10n.tr("Home Assistant 连接提前中断", "Home Assistant connection closed before sending a snapshot")
                        )
                    }
                    group.addTask {
                        try await timeoutSleep()
                        throw HAOnboardingVerifyError.timedOut
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } onCancel: {
                Task { await probe.shutdown() }
            }
            await probe.shutdown()
        } catch {
            await probe.shutdown()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
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

    /// Every pending notice in priority order: a blocked session, then the plaintext-token
    /// decision, then a local-network permission block, then an address suggestion, then a session
    /// that is only expiring. Each one is its own row in the panel's activity stack.
    public var panelNoticeKinds: [PanelNoticeSlot.Kind] {
        PanelNotice.kinds(
            miExpired: miSessionShowsExpired,
            expiringSoon: miSessionExpiringSoonDate,
            plaintext: haPlaintextPrompt,
            localNetworkBlocks: effectiveLocalNetworkBlocks,
            address: pendingHAAddressSuggestion
        )
    }

    /// Whether a header All Off hold is a dry-run onboarding rehearsal or a real shutdown.
    public enum AllOffHoldMode: Equatable, Sendable {
        case rehearsal
        case live
    }

    /// Captures the All Off mode at press-down so asynchronous notices arriving during the 0.6s
    /// hold cannot turn a promised rehearsal into real device writes.
    public func beginAllOffHold() -> AllOffHoldMode {
        allOffLessonIsActive ? .rehearsal : .live
    }

    /// Completes a header All Off hold using the mode captured when the hold started.
    @discardableResult
    public func confirmAllOffHold(mode: AllOffHoldMode) -> Task<BulkWriteOutcome, Never>? {
        switch mode {
        case .rehearsal:
            _ = performAllOffRehearsal()
            return nil
        case .live:
            return turnAllOff()
        }
    }

    /// Header hold during the All Off lesson. Every other caller, including URL, Raycast, and
    /// App Intent scenes, uses `turnAllOff()` and really switches devices off.
    @discardableResult
    public func rehearseAllOff() -> Task<BulkWriteOutcome, Never>? {
        confirmAllOffHold(mode: beginAllOffHold())
    }

    /// Whether a currently visible activity-stack notice hides the getting-started checklist.
    /// Dismissing `.haPlaintext(.declined)` removes it from `panelActivities` while leaving it in
    /// `panelNoticeKinds`, so row visibility and rehearsal eligibility must share this check.
    public var hasChecklistHidingNotice: Bool {
        panelActivities.contains { activity in
            if case .notice(let kind) = activity.kind { return kind.hidesChecklist }
            return false
        }
    }

    /// Whether the getting-started or launch-at-login card is currently shown in the panel.
    public var showsLessonRow: Bool {
        showsOnboardingChecklistCard && !hasChecklistHidingNotice
    }

    /// The All Off lesson is on screen and is the next step, so a hold must not change the home.
    /// `showsOnboardingChecklist` and not `showsOnboardingChecklistCard`: the card also appears for
    /// the standalone launch-at-login reminder, and that row is not the lesson.
    var allOffLessonIsActive: Bool {
        guard showsOnboardingChecklist, !hasChecklistHidingNotice else { return false }
        return onboardingChecklist.nextStep == .allOffAndUndo
    }

    /// Runs the dry-run All Off rehearsal without re-checking `allOffLessonIsActive`, so a hold
    /// that started during the lesson never falls through to `turnAllOff()` if a notice arrives
    /// mid-hold.
    @discardableResult
    func performAllOffRehearsal() -> Bool {
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

    /// Shows the rehearsal banner and marks the lesson done. Returns false when this hold should
    /// really turn devices off.
    func rehearseAllOffLessonIfNeeded() -> Bool {
        guard allOffLessonIsActive else { return false }
        return performAllOffRehearsal()
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

/// The system notice kinds and their activity-stack visibility and dismissal rules.
public enum PanelNoticeSlot {
    public enum Kind: Equatable, Sendable {
        case miBlocked
        case haPlaintext(HAPlaintextPrompt)
        case localNetworkBlocked(Set<LocalNetworkBlockedFeature>)
        case haAddress(HADiscoveredInstance)
        case miExpiringSoon(Date)

        /// A blocked session or a plaintext-token decision hides the getting-started row.
        /// Advisory notices — including local-network permission refusals — coexist with onboarding
        /// so background probes never yank away an active lesson.
        public var hidesChecklist: Bool {
            switch self {
            case .miBlocked, .haPlaintext: true
            case .localNetworkBlocked, .haAddress, .miExpiringSoon: false
            }
        }

        /// The activity stack's identity for this notice. The expiring-soon warning names the expiry
        /// it warns about, so the next session state is a new row rather than a cleared one.
        public var activityID: String {
            switch self {
            case .miBlocked: "notice.miBlocked"
            case .haPlaintext(.asking): "notice.haPlaintext.asking"
            case .haPlaintext(.declined): "notice.haPlaintext.declined"
            case .localNetworkBlocked: "notice.localNetworkBlocked"
            case .haAddress: "notice.haAddress"
            case .miExpiringSoon(let expiry): "notice.miExpiringSoon.\(Int(expiry.timeIntervalSince1970))"
            }
        }

        /// A blocked session and the plaintext-token decision wait for the user; clearing them would
        /// take away the only way to answer.
        public var isDismissible: Bool {
            switch self {
            case .miBlocked, .haPlaintext(.asking): false
            case .haPlaintext(.declined), .localNetworkBlocked, .haAddress, .miExpiringSoon: true
            }
        }

        /// The time the stack prints for this notice, when it has a time of its own.
        public var announcedDate: Date? {
            guard case .miExpiringSoon(let expiry) = self else { return nil }
            return expiry
        }

        /// #47's persistent expiry toast says what the blocked banner already says and carries the
        /// same Scan action. Showing both makes one expired session read as two alerts.
        public func repeats(_ toast: ToastNotice) -> Bool {
            switch self {
            case .miBlocked:
                return toast.persistent && toast.action?.kind == .presentMiReauth
            case .haPlaintext, .localNetworkBlocked, .haAddress, .miExpiringSoon:
                return false
            }
        }
    }
}

public enum PanelNotice {
    /// Every pending notice, highest priority first. A missing input is not a notice.
    public static func kinds(
        miExpired: Bool,
        expiringSoon: Date?,
        plaintext: HAPlaintextPrompt?,
        localNetworkBlocks: Set<LocalNetworkBlockedFeature> = [],
        address: HADiscoveredInstance?
    ) -> [PanelNoticeSlot.Kind] {
        var kinds: [PanelNoticeSlot.Kind] = []
        if miExpired { kinds.append(.miBlocked) }
        if let plaintext { kinds.append(.haPlaintext(plaintext)) }
        if !localNetworkBlocks.isEmpty { kinds.append(.localNetworkBlocked(localNetworkBlocks)) }
        if let address { kinds.append(.haAddress(address)) }
        if let expiringSoon { kinds.append(.miExpiringSoon(expiringSoon)) }
        return kinds
    }
}
