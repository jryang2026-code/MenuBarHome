import Foundation

extension HomeStore {
    public var hasPendingHARemoval: Bool {
        hasCorruptConnectionRemovalState || pendingConnectionRemovals.contains { $0.kind == .ha }
    }

    public var pendingMiRemovalScopes: Set<String> {
        Set(pendingConnectionRemovals.filter { $0.kind == .mi }.map(\.scope))
    }

    public func isMiAccountPendingRemoval(_ accountId: String) -> Bool {
        hasCorruptConnectionRemovalState
            || pendingMiRemovalScopes.contains(ConnectionRemovalStore.miScope(accountId: accountId))
    }

    func syncPendingConnectionRemovals() {
        let state = ConnectionRemovalStore.readState(defaults: userDefaults)
        if state.readError { ConnectionRemovalStore.quarantineCorruptPayloadIfNeeded(defaults: userDefaults) }
        if hasCorruptConnectionRemovalState != state.readError { hasCorruptConnectionRemovalState = state.readError }
        if pendingConnectionRemovals != state.records { pendingConnectionRemovals = state.records }
    }

    func loadActiveMiAccounts() -> [MiAccount] {
        guard !hasCorruptConnectionRemovalState else { return [] }
        let blocked = pendingMiRemovalScopes
        let loaded = MiSessionStore.loadAccounts(defaults: userDefaults, vault: credentialVault)
        return blocked.isEmpty ? loaded : loaded.filter { !blocked.contains($0.id) }
    }

    // MARK: - Removal Scope Previews

    public func previewHomeAssistantRemoval() -> ConnectionRemovalPreview {
        let normalizedURL = HAWebSocketProvider.normalizeBaseURL(serverURLString)
        let clearsConsent = HAPlaintextConsent.isApproved(normalizedURL, defaults: userDefaults)
        let clearsBinding = userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey) != nil
        var details: [String] = [
            L10n.format("凭据槽：Home Assistant 连接钥匙（%@）", "Credential slot: Home Assistant token (%@)", KeychainHelper.tokenAccount),
            L10n.format("连接地址：%@", "Server address: %@", normalizedURL),
        ]
        if clearsBinding { details.append(L10n.tr("地址绑定：清除已记住的 Home Assistant 实例标识", "Address binding: clears remembered Home Assistant instance ID")) }
        if clearsConsent { details.append(L10n.tr("明文同意：撤销该地址的明文令牌传输同意", "Plaintext consent: revokes plaintext token approval for this address")) }
        details.append(L10n.tr("保留项：用电、温湿度与离线历史、房间排序与偏好、米家账号与 AI 密钥均不受影响。", "Kept: energy, climate & offline history, room/device preferences, Xiaomi accounts, and AI keys stay intact."))
        return ConnectionRemovalPreview(
            kind: .ha, scope: homeAssistantScopeIdentifier, displayName: HAPlaintextConsent.host(normalizedURL),
            credentialSlotsToClear: [KeychainHelper.tokenAccount], serverURL: normalizedURL,
            clearsServerURLBinding: clearsBinding, clearsPlaintextConsent: clearsConsent,
            clearsTopologyCache: false, clearsSelectedHome: false, clearsSharedItems: true,
            remainingMiAccountCount: miAccounts.count, preservesHistory: true,
            summaryText: L10n.tr("移除本机保存的钥匙与连接信息。用电和温湿度历史会保留。", "Removes the saved access token and connection data from this Mac. Energy and temperature/humidity history will be kept."),
            detailItems: details,
            platformRevocationHint: L10n.tr("远端令牌仍由 Home Assistant 管理；如需彻底作废，请在 Home Assistant「个人资料 → 安全」中撤销该长期访问令牌。", "Remote tokens are managed by Home Assistant. To revoke it permanently, delete the Long-Lived Access Token under Profile → Security.")
        )
    }

    public func previewMiAccountRemoval(id: String) -> ConnectionRemovalPreview? {
        let scope = ConnectionRemovalStore.miScope(accountId: id)
        let account = miAccounts.first { $0.id == scope }
        let pending = pendingConnectionRemovals.first { $0.scope == scope }
        guard account != nil || pending != nil else { return nil }
        let displayName = account?.displayName ?? pending?.displayName ?? scope
        let remainingCount = miAccounts.filter { $0.id != scope }.count
        let clearsShared = remainingCount == 0
        let clearsSelectedHome = selectedMiHomeId.map { MiAccountScope.isOwned($0, by: scope) } ?? false
        var details: [String] = [
            clearsShared
                ? L10n.format("凭据槽：清除米家会话槽（%@）", "Credential slot: clears Xiaomi session slot (%@)", MiSessionStore.keychainAccount)
                : L10n.format("凭据槽：仅移除「%@」（槽 %@），保留其余 %@ 个米家账号", "Credential slot: removes only \"%@\" (slot %@), keeping %@ other account(s)", displayName, MiSessionStore.keychainAccount, String(remainingCount)),
            L10n.tr("本地缓存：清除该账号的设备拓扑缓存", "Local cache: clears this account's cached device topology"),
        ]
        if clearsSelectedHome { details.append(L10n.tr("家庭选择：清除指向该账号的默认家庭筛选", "Selected home: clears the default home filter pointing to this account")) }
        details.append(L10n.tr("保留项：用电、温湿度与离线历史、本地偏好、Home Assistant 连接与 AI 密钥均不受影响。", "Kept: energy, climate & offline history, local preferences, Home Assistant, and AI keys stay intact."))
        return ConnectionRemovalPreview(
            kind: .mi, scope: scope, displayName: displayName,
            credentialSlotsToClear: [MiSessionStore.keychainAccount], serverURL: nil,
            clearsServerURLBinding: false, clearsPlaintextConsent: false,
            clearsTopologyCache: true, clearsSelectedHome: clearsSelectedHome, clearsSharedItems: clearsShared,
            remainingMiAccountCount: remainingCount, preservesHistory: true,
            summaryText: L10n.tr("移除本机保存的钥匙与连接信息。用电和温湿度历史会保留。", "Removes the saved session and connection data from this Mac. Energy and temperature/humidity history will be kept."),
            detailItems: details,
            platformRevocationHint: L10n.tr("远端登录态由小米账号管理；如需撤销设备授权，请在小米账号安全中心或「米家」App 中操作。", "Remote sign-in is managed by Xiaomi Account. Manage or revoke authorizations in Xiaomi Account Security or the Mi Home app.")
        )
    }

    // MARK: - Two-Phase Retryable Removal

    @discardableResult
    public func removeHomeAssistantConnection(
        pauseConfirmed: Bool = false, expectedGeneration: Int? = nil, expectedPauseItemKeys: Set<String>? = nil
    ) async -> ConnectionRemovalOutcome {
        guard !isIdentityUncertain, !hasCorruptConnectionRemovalState else { return .blockedByUncertainIdentity }
        if isHAConnectionEnabled, let stop = preflightDeactivation(
            preview: previewSetHAConnectionEnabled(false), pauseConfirmed: pauseConfirmed,
            expectedPauseItemKeys: expectedPauseItemKeys,
            blockedFallback: { setHAConnectionEnabled(false, pauseConfirmed: pauseConfirmed, expectedGeneration: expectedGeneration, expectedPauseItemKeys: expectedPauseItemKeys) }
        ) { return stop }

        let normalizedURL = HAWebSocketProvider.normalizeBaseURL(serverURLString)
        let token = KeychainHelper.loadToken(defaults: userDefaults, vault: credentialVault)
        guard let record = ConnectionRemovalStore.beginRemoval(
            kind: .ha, scope: homeAssistantScopeIdentifier, displayName: HAPlaintextConsent.host(normalizedURL),
            serverURL: normalizedURL, slotNames: [KeychainHelper.tokenAccount],
            credentialFingerprint: ConnectionRemovalStore.fingerprint(haToken: token),
            stage: .draining, defaults: userDefaults
        ) else {
            return .incomplete(reason: "removal_record_write_failed", remainingSlots: [KeychainHelper.tokenAccount])
        }
        if isHAConnectionEnabled {
            let applied = setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: expectedGeneration, expectedPauseItemKeys: expectedPauseItemKeys)
            if applied.disposition == .blocked {
                _ = ConnectionRemovalStore.completeRemoval(scope: record.scope, ownerVersion: record.ownerVersion, defaults: userDefaults)
                syncPendingConnectionRemovals()
                return .blockedByDeactivation(applied)
            }
        }
        syncPendingConnectionRemovals()
        return await drainAndCleanRemoval(record)
    }

    @discardableResult
    public func removeMiAccount(
        id: String, pauseConfirmed: Bool = false, expectedGeneration: Int? = nil, expectedPauseItemKeys: Set<String>? = nil
    ) async -> ConnectionRemovalOutcome {
        guard !isIdentityUncertain, !hasCorruptConnectionRemovalState else { return .blockedByUncertainIdentity }
        let scope = ConnectionRemovalStore.miScope(accountId: id)
        if isMiAccountEnabled(scope), let stop = preflightDeactivation(
            preview: previewSetMiAccountEnabled(false, id: scope), pauseConfirmed: pauseConfirmed,
            expectedPauseItemKeys: expectedPauseItemKeys,
            blockedFallback: { setMiAccountEnabled(false, id: scope, pauseConfirmed: pauseConfirmed, expectedGeneration: expectedGeneration, expectedPauseItemKeys: expectedPauseItemKeys) }
        ) { return stop }

        let account = miAccounts.first { $0.id == scope }
        guard let record = ConnectionRemovalStore.beginRemoval(
            kind: .mi, scope: scope, accountId: scope, displayName: account?.displayName ?? scope,
            slotNames: [MiSessionStore.keychainAccount],
            credentialFingerprint: account.map { ConnectionRemovalStore.fingerprint(miSession: $0.session) },
            stage: .draining, defaults: userDefaults
        ) else {
            return .incomplete(reason: "removal_record_write_failed", remainingSlots: [MiSessionStore.keychainAccount])
        }
        if isMiAccountEnabled(scope) {
            let applied = setMiAccountEnabled(false, id: scope, pauseConfirmed: true, expectedGeneration: expectedGeneration, expectedPauseItemKeys: expectedPauseItemKeys)
            if applied.disposition == .blocked {
                _ = ConnectionRemovalStore.completeRemoval(scope: record.scope, ownerVersion: record.ownerVersion, defaults: userDefaults)
                syncPendingConnectionRemovals()
                return .blockedByDeactivation(applied)
            }
        }
        syncPendingConnectionRemovals()
        return await drainAndCleanRemoval(record)
    }

    @discardableResult
    public func retryConnectionRemoval(scope: String) async -> ConnectionRemovalOutcome {
        guard !isIdentityUncertain, !hasCorruptConnectionRemovalState else { return .blockedByUncertainIdentity }
        guard let existing = ConnectionRemovalStore.find(scope: scope, defaults: userDefaults) else {
            syncPendingConnectionRemovals()
            return .completed
        }
        guard let refreshed = ConnectionRemovalStore.beginRemoval(
            kind: existing.kind, scope: existing.scope, accountId: existing.accountId,
            displayName: existing.displayName, serverURL: existing.serverURL,
            slotNames: existing.slotNames, credentialFingerprint: existing.credentialFingerprint,
            stage: .draining, defaults: userDefaults
        ) else {
            return .incomplete(reason: "removal_record_write_failed", remainingSlots: existing.slotNames)
        }
        syncPendingConnectionRemovals()
        return await drainAndCleanRemoval(refreshed)
    }

    private func preflightDeactivation(
        preview: CapabilityDeactivationVerdict,
        pauseConfirmed: Bool,
        expectedPauseItemKeys: Set<String>?,
        blockedFallback: () -> CapabilityDeactivationVerdict
    ) -> ConnectionRemovalOutcome? {
        if preview.disposition == .blocked { return .blockedByDeactivation(preview) }
        if !CapabilitySelectionStore.canPersist(defaults: userDefaults) {
            return .blockedByDeactivation(blockedFallback())
        }
        let freshKeys = Set(preview.itemsToPause.map(\.pauseKey))
        if pauseConfirmed {
            if let expectedPauseItemKeys, !freshKeys.isEmpty, expectedPauseItemKeys != freshKeys {
                return .requiresPauseConfirmation(preview)
            }
        } else if preview.disposition == .requiresPauseConfirmation {
            return .requiresPauseConfirmation(preview)
        }
        return nil
    }

    private func drainAndCleanRemoval(_ record: ConnectionRemovalRecord) async -> ConnectionRemovalOutcome {
        let scope = record.scope
        isRemovingConnectionScopes.insert(scope)
        defer { isRemovingConnectionScopes.remove(scope) }

        if record.kind == .ha { await capabilityTeardownTask?.value }
        await providerShutdownTask?.value
        await connectionRemovalBeforeSlotDeleteHook?(record)

        guard !isIdentityUncertain else {
            _ = ConnectionRemovalStore.markStage(scope: scope, ownerVersion: record.ownerVersion, stage: .failed, error: "identity_uncertain", defaults: userDefaults)
            syncPendingConnectionRemovals()
            return .blockedByUncertainIdentity
        }
        guard let live = ConnectionRemovalStore.find(scope: scope, defaults: userDefaults),
              live.ownerVersion == record.ownerVersion else {
            syncPendingConnectionRemovals()
            return .completed
        }
        _ = ConnectionRemovalStore.markStage(scope: scope, ownerVersion: record.ownerVersion, stage: .cleaning, defaults: userDefaults)
        syncPendingConnectionRemovals()

        switch ConnectionRemovalStore.executeSlotDeletion(record: record, defaults: userDefaults, vault: credentialVault) {
        case .incomplete(let reason, let remaining):
            _ = ConnectionRemovalStore.markStage(scope: scope, ownerVersion: record.ownerVersion, stage: .failed, error: reason, defaults: userDefaults)
            syncPendingConnectionRemovals()
            showToast(L10n.tr("未完成移除 · 重试", "Removal not finished · Retry"), isError: true)
            return .incomplete(reason: reason, remainingSlots: remaining)

        case .completed(let reboundPreserved):
            if !reboundPreserved { finalizeLocalStateAfterSlotDeletion(record: record) }
            let cleared = ConnectionRemovalStore.completeRemoval(scope: scope, ownerVersion: record.ownerVersion, defaults: userDefaults)
            if !cleared, ConnectionRemovalStore.find(scope: scope, defaults: userDefaults)?.ownerVersion == record.ownerVersion {
                _ = ConnectionRemovalStore.markStage(scope: scope, ownerVersion: record.ownerVersion, stage: .failed, error: "removal_record_not_cleared", defaults: userDefaults)
                syncPendingConnectionRemovals()
                showToast(L10n.tr("未完成移除 · 重试", "Removal not finished · Retry"), isError: true)
                return .incomplete(reason: "removal_record_not_cleared", remainingSlots: record.slotNames)
            }
            syncPendingConnectionRemovals()
            showToast(record.kind == .ha
                ? L10n.tr("已移除 Home Assistant 连接", "Removed Home Assistant connection")
                : L10n.tr("已移除米家账号", "Removed Xiaomi account"))
            return .completed
        }
    }

    private func finalizeLocalStateAfterSlotDeletion(record: ConnectionRemovalRecord) {
        switch record.kind {
        case .ha:
            let removedURL = record.serverURL ?? serverURLString
            HAPlaintextConsent.revoke(removedURL, defaults: userDefaults)
            if HAWebSocketProvider.normalizeBaseURL(serverURLString) == HAWebSocketProvider.normalizeBaseURL(removedURL) {
                userDefaults.removeObject(forKey: HAAddressPolicy.rememberedUUIDKey)
            }
            clearHATeardownState()
            hasHASource = false
            explicitlyDisabledConnections.remove(.homeAssistant)
            capabilitySelection.enabledConnections.insert(.homeAssistant)
            purgeRemovedAccountCapabilities(scopes: [record.scope])
            pendingHAAddressSuggestion = nil
            haPlaintextPrompt = nil
            localNetworkBlocks.remove(.homeAssistant)
            sourceStatuses.removeValue(forKey: .homeAssistant)
            connectedBackends.remove(.homeAssistant)
            if homeBackend != .demo {
                if hasMiSource { homeBackend = .xiaomiCloud }
                else if !hasManagedHAProvider { connectionStatus = .disconnected(L10n.tr("未配置", "Not configured")) }
            }
            revalidatePausedItems()

        case .mi:
            let accountId = record.accountId ?? record.scope
            topologyCache?.remove(accountID: accountId)
            revokedMiAccountScopes.insert(accountId)
            miAccounts = loadActiveMiAccounts()
            purgeRemovedAccountCapabilities(scopes: [accountId])
            miAccountStatuses.removeValue(forKey: accountId)
            miSessionMaskedUserId = miAccounts.first?.maskedUserId
            miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
            miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
            if let home = selectedMiHomeId, MiAccountScope.isOwned(home, by: accountId) {
                selectedMiHomeId = nil
                userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
            }
            if miAccounts.isEmpty {
                localNetworkBlocks.remove(.xiaomiLAN)
                if homeBackend == .xiaomiCloud, hasHASource { homeBackend = .homeAssistant }
            }
            revalidatePausedItems()
        }
    }
}
