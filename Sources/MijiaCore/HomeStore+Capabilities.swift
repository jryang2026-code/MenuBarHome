import Foundation

public struct CapabilityControlBlockedError: LocalizedError, Equatable, Sendable {
    public let reason: ControlTargetRejectionReason
    public init(reason: ControlTargetRejectionReason) { self.reason = reason }
    public var errorDescription: String? { reason.userMessage }
}

private extension CapabilityDeactivationVerdict {
    /// Same preview, but refused: the capability selection store refused a write.
    func withBlockingReason(_ reason: CapabilityBlockingReason) -> CapabilityDeactivationVerdict {
        CapabilityDeactivationVerdict(
            disposition: .blocked, cascadedCapabilities: cascadedCapabilities, itemsToPause: itemsToPause,
            softNotices: softNotices, blockingReasons: [reason],
            preservedPreferenceDeviceIds: preservedPreferenceDeviceIds, partition: partition
        )
    }
}

extension HomeStore {
    static let capabilityDeviceIndexKey = "capability_device_index_v1"
    static let capabilitySceneIndexKey = "capability_scene_index_v1"
    static let capabilityMiotDidScopesKey = "capability_miot_did_scopes_v1"
    static let pausedQuickActionsKey = "paused_quick_actions_v1"
    static let pausedQuickActionScopesKey = "paused_quick_action_scopes_v1"
    /// Device groups were quick actions in older releases, so their pause markers share this store.
    static let pausedQuickActionGroupIDPrefix = "group:"

    private struct StoredDeviceGroupItem: Decodable {
        let id: String
        let name: String
    }

    // MARK: - Connection & Account Enablement Queries

    public func isMiAccountEnabled(_ accountId: String) -> Bool {
        guard !isMiAccountPendingRemoval(accountId) else { return false }
        return capabilitySelection.enabledConnections.contains(.xiaomiCloud)
            && capabilitySelection.enabledConnectionScopes.contains(accountId)
    }

    public var enabledMiAccounts: [MiAccount] {
        miAccounts.filter { isMiAccountEnabled($0.id) }
    }

    public var hasEnabledMiSource: Bool {
        if !miAccounts.isEmpty { return !enabledMiAccounts.isEmpty }
        if let scope = miSessionScopeIdentifier { return isMiAccountEnabled(scope) }
        return hasMiSource && !explicitlyDisabledConnections.contains(.xiaomiCloud)
    }

    public var isAnyMiAccountEnabled: Bool {
        hasEnabledMiSource
    }

    public var isHAConnectionEnabled: Bool {
        if hasPendingHARemoval { return false }
        if explicitlyDisabledConnections.contains(.homeAssistant) { return false }
        guard hasHASource else {
            return !explicitlyDisabledScopes.contains(homeAssistantScopeIdentifier)
        }
        return capabilitySelection.isSourceEnabled(connection: .homeAssistant, scope: homeAssistantScopeIdentifier)
    }

    public var hasEnabledHASource: Bool {
        hasHASource && isHAConnectionEnabled
    }

    public var hasConfiguredLGTVSource: Bool {
        lgConfig.isEnabled && lgConfig.hasConfiguredHost
    }

    public var hasEnabledConfiguredSource: Bool {
        hasEnabledMiSource || hasEnabledHASource || hasConfiguredLGTVSource
    }

    public var allConfiguredSourcesTurnedOff: Bool {
        homeBackend != .demo
            && (hasHASource || hasMiSource || !miAccounts.isEmpty)
            && !hasEnabledConfiguredSource
    }

    func isPairedCardServedByEnabledHA(_ deviceId: String) -> Bool {
        hasEnabledHASource
            && pairedDeviceIDs.contains(deviceId)
            && pinnedSource(for: deviceId) != .xiaomiCloud
    }

    func enabledMiFailoverScope(for deviceId: String, accountHint: String?) -> String? {
        guard hasEnabledMiSource,
              pairedDeviceIDs.contains(deviceId),
              pinnedSource(for: deviceId) != .homeAssistant else {
            return nil
        }
        if let accountHint, !accountHint.isEmpty, isMiAccountEnabled(accountHint) {
            return accountHint
        }
        return enabledMiAccounts.first?.id ?? miSessionScopeIdentifier
    }

    var isMiOnboardingBackendEnabled: Bool {
        !explicitlyDisabledConnections.contains(.xiaomiCloud)
    }

    func syncInMemoryConfiguredCapabilities() {
        var next = capabilitySelection
        if (!miAccounts.isEmpty || miSessionScopeIdentifier != nil || hasMiSource),
           !explicitlyDisabledConnections.contains(.xiaomiCloud) {
            next.enabledConnections.insert(.xiaomiCloud)
            for account in miAccounts where !explicitlyDisabledScopes.contains(account.id) {
                next.enabledConnectionScopes.insert(account.id)
            }
            if miAccounts.isEmpty, let scope = miSessionScopeIdentifier, !explicitlyDisabledScopes.contains(scope) {
                next.enabledConnectionScopes.insert(scope)
            }
        }
        if hasHASource, !explicitlyDisabledConnections.contains(.homeAssistant) {
            next.enabledConnections.insert(.homeAssistant)
            let haScope = homeAssistantScopeIdentifier
            if !explicitlyDisabledScopes.contains(haScope) {
                next.enabledConnectionScopes.insert(haScope)
            }
        }
        let normalized = next.normalized(with: .shared)
        if normalized != capabilitySelection { capabilitySelection = normalized }
        syncMiotTypePrunePolicy()
    }

    func configuredConnectionScopes() -> Set<String> {
        var scopes = Set(miAccounts.map(\.id))
        if scopes.isEmpty, let singleMi = miSessionScopeIdentifier { scopes.insert(singleMi) }
        if hasHASource { scopes.insert(homeAssistantScopeIdentifier) }
        return scopes
    }

    /// Publishes the enabled types and safety switches to the Mi and Home Assistant providers. Mi
    /// reads its box before every plan, so a closed type stops being polled on the next refresh
    /// (P3a-M); Home Assistant reads its box for every frame (P3b-M). In dual-source mode, starred
    /// canonical IDs are expanded with each source's native IDs so paired cards keep their offline
    /// alerts even when the canonical ID belongs to the other source (#303, #325).
    func syncMiotTypePrunePolicy() {
        let baseSafetyPolicy = effectiveSafetyRetentionPolicy()
        let dual = activeDualProvider ?? (provider as? DualSourceHomeProvider)
        var miSafetyPolicy = baseSafetyPolicy
        var haSafetyPolicy = baseSafetyPolicy
        if let dual, !baseSafetyPolicy.starredDeviceIds.isEmpty {
            miSafetyPolicy.starredDeviceIds.formUnion(dual.miSourceIDs(forCanonicalIDs: baseSafetyPolicy.starredDeviceIds))
            haSafetyPolicy.starredDeviceIds.formUnion(dual.haSourceIDs(forCanonicalIDs: baseSafetyPolicy.starredDeviceIds))
        }
        miotTypePruneBox.update(MiotTypePrunePolicy(
            selection: capabilitySelection,
            safetyPolicy: miSafetyPolicy,
            sourceScope: miSessionScopeIdentifier ?? ""
        ))
        haTypePruneBox.update(HATypePrunePolicy(
            selection: capabilitySelection,
            safetyPolicy: haSafetyPolicy,
            sourceScope: homeAssistantScopeIdentifier
        ))
    }

    /// A closed Mi type keeps its hidden identities in the index so every write entry answers
    /// 「该设备类型已关闭」 instead of「设备不存在」, and keeps the hidden devices whose enabled alerts
    /// still need evaluating. Keyed by account scope: one account's empty report never clears another.
    func applyMiotTypePruneReport(_ report: MiotTypePruneReport) {
        let key = report.scope.isEmpty ? (miSessionScopeIdentifier ?? "") : report.scope
        guard !key.isEmpty else { return }
        let previousSafetyDevices = miotTypePruneReports[key]?.safetyDevices ?? []
        if report.isEmpty {
            miotTypePruneReports.removeValue(forKey: key)
        } else {
            miotTypePruneReports[key] = report
        }
        var changed = false
        for entry in report.hiddenIndexedDevices {
            let mergedEntry = Self.mergedHiddenIndexedDevice(entry, existing: indexedDevicesById[entry.id])
            if indexedDevicesById[entry.id] != mergedEntry {
                indexedDevicesById[entry.id] = mergedEntry
                changed = true
            }
        }
        if changed { persistIndexedDevices() }
        if enableSafetyAlerts,
           !report.safetyDevices.isEmpty,
           report.safetyDevices != previousSafetyDevices {
            let alerts = evaluateSafetyAlerts(now: Date())
            if let handler = onSafetyAlert {
                for alert in alerts {
                    handler(alert)
                }
            }
        }
    }

    private static func mergedHiddenIndexedDevice(
        _ incoming: CapabilityIndexedDevice,
        existing: CapabilityIndexedDevice?
    ) -> CapabilityIndexedDevice {
        guard let existing, existing.connection != incoming.connection else { return incoming }
        var readKeys = incoming.readKeys
        for key in existing.readKeys where !readKeys.contains(key) { readKeys.append(key) }
        var safetyReadKeys = incoming.safetyReadKeys
        for key in existing.safetyReadKeys where !safetyReadKeys.contains(key) { safetyReadKeys.append(key) }
        return CapabilityIndexedDevice(
            id: incoming.id,
            name: incoming.name,
            category: incoming.category,
            connection: incoming.connection,
            sourceScope: incoming.sourceScope,
            isSourceAvailable: incoming.isSourceAvailable || existing.isSourceAvailable,
            upstreamHiddenOrDisabled: incoming.upstreamHiddenOrDisabled && existing.upstreamHiddenOrDisabled,
            participatesInAllOff: incoming.participatesInAllOff || existing.participatesInAllOff,
            safetySignals: existing.safetySignals.union(incoming.safetySignals),
            readKeys: readKeys,
            safetyReadKeys: safetyReadKeys
        )
    }

    /// Drops one account's (or the Home Assistant address's) retained safety set. Its index entries
    /// stay: a disabled source must keep answering「该米家账号已停用」 for its devices.
    func dropMiotTypePruneReport(scope: String) {
        miotTypePruneReports.removeValue(forKey: scope)
    }

    /// Drops every account's retained set; called when the Mi provider is rebuilt or replaced, and
    /// when the store leaves for Home Assistant or the demo home.
    func clearMiotTypePruneReports() {
        guard !miotTypePruneReports.isEmpty else { return }
        miotTypePruneReports.removeAll()
    }

    /// Devices a closed type keeps only for enabled alerts: evaluated for safety, never drawn, listed
    /// or controlled (architecture.md §D 安全保留集).
    public var typeHiddenSafetyDevices: [SmartDevice] {
        let visible = Set(devices.map(\.id))
        // A closed TV type hides the LAN LG card, but a favorited TV still raises its offline alert.
        var hiddenLG: [SmartDevice] = []
        if let lg = latestLGDevice, !visible.contains(lg.id), favoriteDeviceIds.contains(lg.id),
           homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost {
            hiddenLG = [lg]
        }
        guard !miotTypePruneReports.isEmpty else { return hiddenLG }
        var order: [String] = []
        var freshest: [String: SmartDevice] = [:]
        for scope in miotTypePruneReports.keys.sorted() {
            guard let report = miotTypePruneReports[scope] else { continue }
            for device in report.safetyDevices where !visible.contains(device.id) {
                guard let kept = freshest[device.id] else {
                    freshest[device.id] = device
                    order.append(device.id)
                    continue
                }
                // One shared home can hand the same device to two accounts; the stale account must not
                // shadow a fresh reading, or a live alarm is never evaluated (same rule as
                // `MiAccountsProvider.deviceFreshnessRank` for visible cards).
                if Self.hiddenSafetyFreshnessRank(device) < Self.hiddenSafetyFreshnessRank(kept) {
                    freshest[device.id] = device
                }
            }
        }
        return order.compactMap { freshest[$0] } + hiddenLG.filter { freshest[$0.id] == nil }
    }

    /// Lower is fresher: unverified telemetry first, then an offline card.
    private static func hiddenSafetyFreshnessRank(_ device: SmartDevice) -> Int {
        (device.telemetryStale ? 2 : 0) + (device.isOnline ? 0 : 1)
    }

    @discardableResult
    func persistCapabilitySelection(
        proposed: CapabilitySelection? = nil,
        removingScopes: Set<String> = [],
        patch: CapabilitySelectionPatch? = nil
    ) -> Bool {
        let selection = proposed ?? capabilitySelection
        let configured = configuredConnectionScopes()
        let effectivePatch: CapabilitySelectionPatch = if let patch {
            patch
        } else {
            CapabilitySelectionPatch.diff(
                from: lastPersistedCapabilitySelection ?? capabilitySelection,
                baseDisabledConnections: lastPersistedDisabledConnections,
                baseDisabledScopes: lastPersistedDisabledScopes,
                to: selection,
                targetDisabledConnections: explicitlyDisabledConnections,
                targetDisabledScopes: explicitlyDisabledScopes,
                configuredScopes: configured,
                removingScopes: removingScopes
            )
        }
        let result = CapabilitySelectionStore.saveMergingConflicts(
            selection: selection,
            configuredScopes: configured,
            explicitlyDisabledConnections: explicitlyDisabledConnections,
            removingScopes: removingScopes,
            patch: effectivePatch,
            expectedRevision: capabilityStoreRevision,
            defaults: userDefaults
        )
        if result.succeeded {
            capabilityStoreRevision = result.revision
            if let persisted = result.persistedState {
                applyPersistedCapabilityState(
                    persisted,
                    candidateScopes: configured.union(selection.enabledConnectionScopes)
                )
            } else {
                lastPersistedCapabilitySelection = capabilitySelection
                lastPersistedDisabledConnections = explicitlyDisabledConnections
                lastPersistedDisabledScopes = explicitlyDisabledScopes
            }
            if result.hadConflict {
                capabilityMergeConflictCount &+= 1
                lastCapabilityMergeDiagnostic = result.diagnostic
            }
            syncMiotTypePrunePolicy()
        } else if let diagnostic = result.diagnostic {
            lastCapabilityMergeDiagnostic = diagnostic
        }
        return result.succeeded
    }

    private func applyPersistedCapabilityState(
        _ persisted: CapabilitySelectionPersistedState,
        candidateScopes: Set<String>
    ) {
        explicitlyDisabledConnections = persisted.disabledConnections
        explicitlyDisabledScopes = persisted.disabledScopes
        for scope in persisted.disabledScopes {
            dropMiotTypePruneReport(scope: scope)
        }
        let enabledConnections = persisted.enabledConnections.subtracting(persisted.disabledConnections)
        let enabledScopes = candidateScopes.subtracting(persisted.disabledScopes).filter { scope in
            CapabilityReferenceEngine.connectionCapability(forScope: scope)
                .map { enabledConnections.contains($0) && !persisted.disabledConnections.contains($0) } ?? true
        }
        let synced = CapabilitySelection(
            enabledConnections: enabledConnections,
            enabledConnectionScopes: enabledScopes,
            enabledFeatures: persisted.enabledFeatures,
            enabledCategories: persisted.enabledCategories
        ).normalized(with: .shared)
        if synced != capabilitySelection {
            capabilitySelection = synced
            capabilityGeneration &+= 1
        }
        lastPersistedCapabilitySelection = capabilitySelection
        lastPersistedDisabledConnections = explicitlyDisabledConnections
        lastPersistedDisabledScopes = explicitlyDisabledScopes
    }

    /// Commit order for a disable: the selection must be writable before any reference is paused, or
    /// a refused write would leave paused timers and rules behind for an account that stays enabled (M2).
    func canPersistCapabilitySelection() -> Bool {
        CapabilitySelectionStore.canPersist(defaults: userDefaults)
    }

    // MARK: - Preview & Apply Xiaomi Account Enablement

    public func previewSetMiAccountEnabled(_ enabled: Bool, id: String) -> CapabilityDeactivationVerdict {
        guard !enabled, isMiAccountEnabled(id) else {
            return allowedDeactivationVerdict(for: proposedSelectionForMiAccount(id: id, enabled: enabled))
        }
        return evaluateCapabilityDeactivation(proposed: proposedSelectionForMiAccount(id: id, enabled: false), expectedGeneration: nil)
    }

    @discardableResult
    public func setMiAccountEnabled(
        _ enabled: Bool,
        id: String,
        pauseConfirmed: Bool = false,
        expectedGeneration: Int? = nil,
        expectedPauseItemKeys: Set<String>? = nil
    ) -> CapabilityDeactivationVerdict {
        if enabled {
            guard !isMiAccountPendingRemoval(id) else { return allowedDeactivationVerdict(for: capabilitySelection) }
            let next = proposedSelectionForMiAccount(id: id, enabled: true).normalized(with: .shared)
            guard next != capabilitySelection else { return allowedDeactivationVerdict(for: capabilitySelection) }
            explicitlyDisabledConnections.remove(.xiaomiCloud)
            explicitlyDisabledScopes.remove(id)
            revokedMiAccountScopes.remove(id)
            (activeDualProvider ?? (provider as? DualSourceHomeProvider))?.markXiaomiAccountEnabled(id)
            activeMiAccountsProvider?.markAccountEnabled(id)
            capabilitySelection = next
            capabilityGeneration &+= 1
            persistCapabilitySelection()
            miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
            miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
            if provider is DualSourceHomeProvider || provider is MiAccountsProvider {
                pendingRevalidationScopes.insert(id)
                rebuildLiveProvider()
            } else {
                syncHistoryConnectionScopes()
                syncScheduledCommandScopeIfNeeded()
                revalidatePausedItems()
            }
            return allowedDeactivationVerdict(for: capabilitySelection)
        }

        guard isMiAccountEnabled(id) else { return allowedDeactivationVerdict(for: capabilitySelection) }
        let proposed = proposedSelectionForMiAccount(id: id, enabled: false)
        let verdict = evaluateCapabilityDeactivation(proposed: proposed, expectedGeneration: expectedGeneration)
        if verdict.disposition == .blocked { return verdict }
        if !canPersistCapabilitySelection() {
            return blockedSelectionVerdict(proposed: proposed, storeKey: CapabilitySelectionStore.storageKey)
        }
        let freshPauseKeys = Set(verdict.itemsToPause.map(\.pauseKey))
        if pauseConfirmed {
            // The user confirmed a specific list. If a timer, rule or quick action appeared since the
            // preview, returning the fresh verdict re-previews instead of silently pausing a
            // different set (M3). An empty fresh list has nothing to pause, so the disable proceeds.
            if let expectedPauseItemKeys, !freshPauseKeys.isEmpty, expectedPauseItemKeys != freshPauseKeys {
                return verdict
            }
        } else if verdict.disposition == .requiresPauseConfirmation {
            return verdict
        }
        if !verdict.itemsToPause.isEmpty {
            pauseAffectedReferences(verdict.itemsToPause, fallbackCapabilities: [.connection(.xiaomiCloud)])
        }
        pendingRevalidationScopes.remove(id)
        explicitlyDisabledScopes.insert(id)
        capabilitySelection = proposed.normalized(with: .shared)
        capabilityGeneration &+= 1
        persistCapabilitySelection()
        applyMiAccountDisabledRuntimeState(id: id)
        return verdict
    }

    // MARK: - Preview & Apply Home Assistant Connection Enablement

    public func previewSetHAConnectionEnabled(_ enabled: Bool) -> CapabilityDeactivationVerdict {
        guard !enabled, isHAConnectionEnabled else {
            return allowedDeactivationVerdict(for: proposedSelectionForHAConnection(enabled: enabled))
        }
        return evaluateCapabilityDeactivation(
            proposed: proposedSelectionForHAConnection(enabled: false),
            expectedGeneration: nil
        )
    }

    var hasManagedHAProvider: Bool {
        activeDualProvider != nil
            || provider is HAWebSocketProvider
            || haProviderFactory != nil
            || provider is DualSourceHomeProvider
    }

    @discardableResult
    public func setHAConnectionEnabled(
        _ enabled: Bool,
        pauseConfirmed: Bool = false,
        expectedGeneration: Int? = nil,
        expectedPauseItemKeys: Set<String>? = nil
    ) -> CapabilityDeactivationVerdict {
        let haScope = homeAssistantScopeIdentifier
        if enabled {
            guard !hasPendingHARemoval else { return allowedDeactivationVerdict(for: capabilitySelection) }
            let next = proposedSelectionForHAConnection(enabled: true).normalized(with: .shared)
            let wasDisabled = explicitlyDisabledConnections.contains(.homeAssistant)
                || explicitlyDisabledScopes.contains(haScope)
            guard next != capabilitySelection || wasDisabled else {
                return allowedDeactivationVerdict(for: capabilitySelection)
            }
            clearHATeardownState()
            explicitlyDisabledConnections.remove(.homeAssistant)
            explicitlyDisabledScopes.remove(haScope)
            capabilitySelection = next
            capabilityGeneration &+= 1
            persistCapabilitySelection(removingScopes: [haScope])
            if homeBackend != .demo, hasManagedHAProvider {
                pendingRevalidationScopes.insert(haScope)
                if activeDualProvider != nil || provider is HAWebSocketProvider || haProviderFactory != nil {
                    rebuildLiveProvider()
                } else {
                    // `provider is DualSourceHomeProvider` is the only remaining way into
                    // `hasManagedHAProvider`, so this branch mirrors it: nothing to rebuild here, but
                    // the paused references must still get the same revalidation as the neighbours.
                    syncHistoryConnectionScopes()
                    syncScheduledCommandScopeIfNeeded()
                    revalidatePausedItems()
                }
            } else {
                syncHistoryConnectionScopes()
                syncScheduledCommandScopeIfNeeded()
                revalidatePausedItems()
            }
            return allowedDeactivationVerdict(for: capabilitySelection)
        }

        guard isHAConnectionEnabled else { return allowedDeactivationVerdict(for: capabilitySelection) }
        let proposed = proposedSelectionForHAConnection(enabled: false)
        let verdict = evaluateCapabilityDeactivation(proposed: proposed, expectedGeneration: expectedGeneration)
        if verdict.disposition == .blocked { return verdict }
        if !canPersistCapabilitySelection() {
            return blockedSelectionVerdict(proposed: proposed, storeKey: CapabilitySelectionStore.storageKey)
        }
        let freshPauseKeys = Set(verdict.itemsToPause.map(\.pauseKey))
        if pauseConfirmed {
            if let expectedPauseItemKeys, !freshPauseKeys.isEmpty, expectedPauseItemKeys != freshPauseKeys {
                return verdict
            }
        } else if verdict.disposition == .requiresPauseConfirmation {
            return verdict
        }
        // Snapshot live device and scene indexes before mutating selection or clearing rows so post-disable
        // control gates recognize every HA device and scene ID immediately.
        if !devices.isEmpty { syncIndexedDevices(from: devices) }
        if !scenes.isEmpty { syncIndexedScenes(from: scenes) }
        if !verdict.itemsToPause.isEmpty {
            pauseAffectedReferences(verdict.itemsToPause, fallbackCapabilities: [.connection(.homeAssistant)])
        }
        pendingRevalidationScopes.remove(haScope)
        explicitlyDisabledConnections.insert(.homeAssistant)
        explicitlyDisabledScopes.remove(haScope)
        capabilitySelection = proposed.normalized(with: .shared)
        capabilityGeneration &+= 1
        persistCapabilitySelection(removingScopes: [haScope])
        applyHADisabledRuntimeState()
        return verdict
    }

    func registerNewlyConfiguredScope(_ scope: String, connection: ConnectionCapabilityID) {
        // A scope the user had explicitly turned off and now re-enables (a second QR scan, or
        // connecting the same account again) still owns the paused timers, rules and quick actions
        // recorded before, so it has to go through the same fresh-snapshot revalidation as
        // `setMiAccountEnabled(true, ...)`. Without that the pause markers survive forever.
        explicitlyDisabledConnections.remove(connection)
        explicitlyDisabledScopes.remove(scope)
        if connection == .xiaomiCloud {
            revokedMiAccountScopes.remove(scope)
            (activeDualProvider ?? (provider as? DualSourceHomeProvider))?.markXiaomiAccountEnabled(scope)
            activeMiAccountsProvider?.markAccountEnabled(scope)
        }
        var next = capabilitySelection
        next.enabledConnections.insert(connection)
        next.enabledConnectionScopes.insert(scope)
        capabilitySelection = next.normalized(with: .shared)
        capabilityGeneration &+= 1
        // Always wait for this scope's first fresh snapshot before deciding about paused items: it may
        // be a re-added account whose paused quick actions lost their targets when it was removed, and
        // that removal already cleared the explicit-disable marker this check used to look at.
        pendingRevalidationScopes.insert(scope)
        // Explicit re-login/re-connect must emit a non-empty re-enable patch even when the local
        // baseline already had this scope enabled, so a cross-store revision conflict after another
        // store disabled the scope still re-enables it.
        persistCapabilitySelection(
            patch: CapabilitySelectionPatch(
                addedConnections: [connection],
                removedDisabledConnections: [connection],
                enabledScopes: [scope]
            )
        )
    }

    /// Carries the Home Assistant scope over when the saved address changes. The stored selection
    /// names addresses, so without this the freshly accepted address is absent from
    /// `enabledConnectionScopes`: `isHAConnectionEnabled` reads false and the next write records the
    /// new address as explicitly disabled (H1).
    func migrateHomeAssistantScope(from oldServerURL: String) {
        let oldScope = "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(oldServerURL))"
        let newScope = homeAssistantScopeIdentifier
        guard oldScope != newScope else { return }
        dropMiotTypePruneReport(scope: oldScope)
        let carriesEnablement = capabilitySelection.enabledConnections.contains(.homeAssistant)
        var next = capabilitySelection
        next.enabledConnectionScopes.remove(oldScope)
        if carriesEnablement, !explicitlyDisabledScopes.contains(newScope) {
            next.enabledConnectionScopes.insert(newScope)
        }
        explicitlyDisabledScopes.remove(oldScope)
        if carriesEnablement { explicitlyDisabledScopes.remove(newScope) }
        let selectionChanged = next != capabilitySelection
        if selectionChanged { capabilitySelection = next; capabilityGeneration &+= 1 }
        // Never leave either address behind as an explicit scope disable: the connection-level flag
        // carries the user's decision, and `save` skips scopes of an explicitly disabled connection.
        persistCapabilitySelection(removingScopes: [oldScope, newScope])
    }

    func purgeRemovedAccountCapabilities(scopes: Set<String>) {
        guard !scopes.isEmpty else { return }
        for scope in scopes { dropMiotTypePruneReport(scope: scope) }
        pendingRevalidationScopes.subtract(scopes)
        explicitlyDisabledScopes.subtract(scopes)
        var next = capabilitySelection
        next.enabledConnectionScopes.subtract(scopes)
        capabilitySelection = next.normalized(with: .shared)
        capabilityGeneration &+= 1
        persistCapabilitySelection(removingScopes: scopes)
        let beforeCount = indexedDevicesById.count
        indexedDevicesById = indexedDevicesById.filter { !scopes.contains($0.value.sourceScope) }
        if indexedDevicesById.count != beforeCount { persistIndexedDevices() }
        let beforeSceneCount = indexedScenesById.count
        indexedScenesById = indexedScenesById.filter { !scopes.contains($0.value.sourceScope) }
        if indexedScenesById.count != beforeSceneCount { persistIndexedScenes() }
        var didScopesChanged = false
        var updatedDidScopes: [String: Set<String>] = [:]
        for (did, ownerScopes) in miotDidToAccountScopes {
            let kept = ownerScopes.subtracting(scopes)
            if kept != ownerScopes { didScopesChanged = true }
            if !kept.isEmpty { updatedDidScopes[did] = kept }
        }
        if didScopesChanged {
            miotDidToAccountScopes = updatedDidScopes
            persistMiotDidScopes()
        }
        // Paused references outlive the account they were paused for. Drop the removed scopes from
        // their pause markers now; revalidation runs once the removed devices left the panel.
        let ruleStore = AutomationRuleStore(defaults: userDefaults)
        var rules = ruleStore.load()
        var rulesChanged = false
        for idx in rules.indices where !rules[idx].pausedScopes.isEmpty {
            let kept = rules[idx].pausedScopes.filter { !scopes.contains($0) }
            if kept != rules[idx].pausedScopes { rules[idx].pausedScopes = kept; rulesChanged = true }
        }
        if rulesChanged { ruleStore.save(rules); onAutomationRulesChanged?() }
    }

    func requireManualResumeAfterHARemoval() {
        let ruleStore = AutomationRuleStore(defaults: userDefaults)
        var rules = ruleStore.load()
        var rulesChanged = false
        for index in rules.indices where !rules[index].isEnabled {
            guard rules[index].pausedScopes.contains(where: { $0.hasPrefix("ha:") })
                || rules[index].pausedCapabilities.contains(.connection(.homeAssistant)) else { continue }
            // Clear every auto-resume marker together, including pauses from prior HA addresses.
            rules[index].pausedCapabilities = []
            rules[index].pausedScopes = []
            rulesChanged = true
        }
        if rulesChanged {
            ruleStore.save(rules)
            onAutomationRulesChanged?()
        }

        var groupsChanged = false
        for id in pausedQuickActionIDs where id.hasPrefix("group:") {
            guard pausedQuickActionScopes[id]?.contains(where: { $0.hasPrefix("ha:") }) == true else { continue }
            // Keep the group paused without an eligible source for automatic recovery.
            pausedQuickActionScopes[id] = []
            groupsChanged = true
        }
        if groupsChanged { persistPausedQuickActionScopes() }
    }

    func blockedSelectionVerdict(proposed: CapabilitySelection, storeKey: String) -> CapabilityDeactivationVerdict {
        allowedDeactivationVerdict(for: proposed).withBlockingReason(
            CapabilityBlockingReason(kind: .corruptedReferenceStore, referenceId: storeKey, detail: storeKey)
        )
    }

    private func proposedSelectionForMiAccount(id: String, enabled: Bool) -> CapabilitySelection {
        var next = capabilitySelection
        next.enabledConnections.insert(.xiaomiCloud)
        if enabled { next.enabledConnectionScopes.insert(id) } else { next.enabledConnectionScopes.remove(id) }
        return next
    }

    private func proposedSelectionForHAConnection(enabled: Bool) -> CapabilitySelection {
        var next = capabilitySelection
        let haScope = homeAssistantScopeIdentifier
        if enabled {
            next.enabledConnections.insert(.homeAssistant)
            next.enabledConnectionScopes.insert(haScope)
        } else {
            next.enabledConnections.remove(.homeAssistant)
            next.enabledConnectionScopes = next.enabledConnectionScopes.filter {
                CapabilityReferenceEngine.connectionCapability(forScope: $0) != .homeAssistant
            }
        }
        return next
    }

    /// A paired card copies the Xiaomi `accountId` even when Home Assistant drives it or can take over
    /// seamlessly (ADR-0008). Only rows exclusively controlled by the disabled Mi account are torn down.
    private func isMiOwnedRow(_ device: SmartDevice, accountId: String) -> Bool {
        guard deviceBackends[device.id] != .homeAssistant,
              !isPairedCardServedByEnabledHA(device.id) else {
            return false
        }
        return device.accountId == accountId
    }

    private func isHAExclusivelyOwnedRow(_ device: SmartDevice) -> Bool {
        if homeBackend == .demo { return false }
        if lgClientServes(device) || device.id == LGWebOSProtocol.deviceId { return false }
        if hasEnabledMiSource && pairedDeviceIDs.contains(device.id) { return false }
        if deviceBackends[device.id] == .homeAssistant { return true }
        if deviceBackends[device.id] == .xiaomiCloud { return false }
        if device.accountId != nil { return false }
        return homeBackend == .homeAssistant || indexedDevicesById[device.id]?.connection == .homeAssistant
    }

    func clearHATeardownState() {
        haTeardownToken &+= 1
        isDisablingHAConnection = false
        capabilityTeardownTask = nil
    }

    func collectHADisabledDeviceIds() -> (disabledDeviceIds: Set<String>, cameraTeardownIds: Set<String>) {
        let haCameraIds = Set(devices.compactMap { device -> String? in
            guard case .camera = device.kind else { return nil }
            if deviceBackends[device.id] == .homeAssistant
                || pinnedSource(for: device.id) == .homeAssistant
                || isHAExclusivelyOwnedRow(device) {
                return device.id
            }
            return nil
        })

        var disabledDeviceIds = Set(devices.filter { isHAExclusivelyOwnedRow($0) }.map(\.id))
        for (devId, indexed) in indexedDevicesById where indexed.connection == .homeAssistant {
            if !(hasEnabledMiSource && pairedDeviceIDs.contains(devId)) {
                disabledDeviceIds.insert(devId)
            }
        }
        return (disabledDeviceIds, disabledDeviceIds.union(haCameraIds))
    }

    func tearDownHACameras(_ cameraTeardownIds: Set<String>) {
        if let activeCam = activeLiveCameraDeviceId, cameraTeardownIds.contains(activeCam) {
            activeLiveCameraDeviceId = nil
        }
        onHAConnectionDisabled?(cameraTeardownIds)
    }

    private func trackHATeardownIfNeeded(before previousShutdownTask: Task<Void, Never>?) {
        guard let shutdownTask = providerShutdownTask, shutdownTask != previousShutdownTask else {
            clearHATeardownState()
            return
        }
        haTeardownToken &+= 1
        let token = haTeardownToken
        isDisablingHAConnection = true
        capabilityTeardownTask = Task { @MainActor [weak self] in
            await shutdownTask.value
            guard let self, self.haTeardownToken == token else { return }
            self.isDisablingHAConnection = false
            self.capabilityTeardownTask = nil
        }
    }

    private func applyHADisabledRuntimeState() {
        // Synchronously seal off reads, writes, and events on the active dual provider before any
        // async shutdown task runs so no refresh or history fetch can slip through the window.
        (activeDualProvider ?? (provider as? DualSourceHomeProvider))?.markBackendDisabled(.homeAssistant)
        // A disabled connection evaluates nothing; its retained safety set goes with it (P3b-M).
        dropMiotTypePruneReport(scope: homeAssistantScopeIdentifier)

        guard homeBackend != .demo else {
            clearHATeardownState()
            scheduleRaycastSnapshotExport()
            return
        }

        _ = recordMiotDidAccountScopes(from: devices, facetsByDeviceId: deviceFacets)
        let survivingBanner: UndoBanner? = if hasEnabledMiSource, let banner = undoBanner,
            !partitionUndoCommandsByCapability(
                banner.restoreCommands,
                previousDevices: banner.previousDevices
            ).eligibleCommands.isEmpty {
            banner
        } else {
            nil
        }
        let survivingAssistantUndo: AssistantUndoEntry? = if hasEnabledMiSource, let entry = lastAssistantUndo,
            !partitionUndoCommandsByCapability(
                entry.restore,
                previousDevices: entry.previous
            ).eligibleCommands.isEmpty {
            entry
        } else {
            nil
        }
        invalidateUndoContext()
        if let survivingBanner {
            scheduleUndoBanner(
                actionId: survivingBanner.actionId,
                title: survivingBanner.title,
                restoreCommands: survivingBanner.restoreCommands,
                previousDevices: survivingBanner.previousDevices,
                deviceCount: survivingBanner.deviceCount,
                habitReceipt: survivingBanner.habitReceipt,
                duration: survivingBanner.duration,
                isAllOff: survivingBanner.isAllOff,
                attemptedDeviceIds: survivingBanner.attemptedDeviceIds
            )
        }
        if let survivingAssistantUndo {
            lastAssistantUndo = survivingAssistantUndo
        }

        let (disabledDeviceIds, cameraTeardownIds) = collectHADisabledDeviceIds()

        pendingHAAddressSuggestion = nil
        haPlaintextPrompt = nil
        localNetworkBlocks.remove(.homeAssistant)
        sourceStatuses.removeValue(forKey: .homeAssistant)
        connectedBackends.remove(.homeAssistant)
        scenes = []

        for removedId in disabledDeviceIds {
            releaseReadBackEcho(for: removedId)
            cancelFacetWrites(for: removedId)
            cancelDebouncedWrites(for: removedId, recomputeRow: false)
            clearOptimisticLockEntries(for: removedId)
            clearOptimisticRevisions(for: removedId)
            manualWriteSessions.removeValue(forKey: removedId)
            deviceFacets.removeValue(forKey: removedId)
            deviceTransportDiagnostics.removeValue(forKey: removedId)
            deviceBackends.removeValue(forKey: removedId)
            lastReportedDevices.removeValue(forKey: removedId)
            lastReportedFacets.removeValue(forKey: removedId)
        }

        let retainedPairedIds = pairedDeviceIDs.subtracting(disabledDeviceIds)
        for pairedId in retainedPairedIds {
            let canFailOverToMi = hasEnabledMiSource && pinnedSource(for: pairedId) != .homeAssistant
            if deviceBackends[pairedId] == .homeAssistant || pinnedSource(for: pairedId) == .homeAssistant {
                releaseReadBackEcho(for: pairedId)
                cancelFacetWrites(for: pairedId)
                cancelDebouncedWrites(for: pairedId, recomputeRow: false)
                clearOptimisticLockEntries(for: pairedId)
                clearOptimisticRevisions(for: pairedId)
                manualWriteSessions.removeValue(forKey: pairedId)
                if canFailOverToMi {
                    deviceBackends[pairedId] = .xiaomiCloud
                }
            }
            if let existingFacets = deviceFacets[pairedId] {
                let keptFacets = existingFacets.filter { !shouldSuppressHAFacet($0) }
                if keptFacets.count != existingFacets.count {
                    cancelFacetWrites(for: pairedId)
                    if keptFacets.isEmpty {
                        deviceFacets.removeValue(forKey: pairedId)
                    } else {
                        deviceFacets[pairedId] = keptFacets
                    }
                }
            }
        }

        devices.removeAll { disabledDeviceIds.contains($0.id) || isHAExclusivelyOwnedRow($0) }
        if !devices.isEmpty { syncIndexedDevices(from: devices) }
        environmentReadings.removeAll { disabledDeviceIds.contains($0.id) }
        if !hasEnabledMiSource {
            rooms = []
            selectRoom(nil)
        } else if let selectedRoomId,
                  !rooms.contains(where: { $0.id == selectedRoomId })
                      || (!devices.contains(where: { $0.roomId == selectedRoomId }) && MiAccountScope.owner(of: selectedRoomId) == nil) {
            if MiAccountScope.owner(of: selectedRoomId) == nil,
               !devices.contains(where: { $0.roomId == selectedRoomId }) {
                rooms.removeAll { $0.id == selectedRoomId }
                selectRoom(nil)
            }
        }

        tearDownHACameras(cameraTeardownIds)

        let shutdownBefore = providerShutdownTask
        if activeDualProvider != nil || provider is HAWebSocketProvider || haProviderFactory != nil {
            rebuildLiveProvider()
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        } else if let dual = provider as? DualSourceHomeProvider {
            syncHistoryConnectionScopes()
            syncScheduledCommandScopeIfNeeded()
            let previousShutdown = providerShutdownTask
            providerShutdownTask = Task {
                await previousShutdown?.value
                await dual.setSourceProvider(nil, for: .homeAssistant)
            }
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        } else {
            syncHistoryConnectionScopes()
            syncScheduledCommandScopeIfNeeded()
            if activeBackends.isEmpty {
                eventTask?.cancel()
                shutdownCurrentProvider()
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        }
        trackHATeardownIfNeeded(before: shutdownBefore)
        scheduleRaycastSnapshotExport()
    }

    private func applyMiAccountDisabledRuntimeState(id: String) {
        dropMiotTypePruneReport(scope: id)
        let dual = activeDualProvider ?? (provider as? DualSourceHomeProvider)
        let revocations = dual?.markXiaomiAccountDisabled(id) ?? [:]
        if !hasEnabledMiSource {
            dual?.markBackendDisabled(.xiaomiCloud)
        }
        activeMiAccountsProvider?.markAccountDisabled(id)
        // Record any live MIoT DIDs before tearing down rows or facets so late writes stay fail-closed.
        _ = recordMiotDidAccountScopes(from: devices, facetsByDeviceId: deviceFacets)
        invalidateUndoContext()
        var disabledDeviceIds = Set(devices.filter { isMiOwnedRow($0, accountId: id) }.map(\.id))
        for (devId, indexed) in indexedDevicesById where indexed.sourceScope == id {
            if deviceBackends[devId] != .homeAssistant && !isPairedCardServedByEnabledHA(devId) {
                disabledDeviceIds.insert(devId)
            }
        }
        miAccountStatuses.removeValue(forKey: id)
        miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
        scheduleMiSessionExpiryTransition()
        if !hasEnabledMiSource {
            isShowingMiReauth = false
            localNetworkBlocks.remove(.xiaomiLAN)
        } else if !miSessionShowsExpired {
            isShowingMiReauth = false
        }
        if !miSessionBlocksControl, toastNotice?.action?.kind == .presentMiReauth {
            dismissToast()
        }
        if let home = selectedMiHomeId, MiAccountScope.isOwned(home, by: id) { selectedMiHomeId = nil }

        for removedId in disabledDeviceIds {
            releaseReadBackEcho(for: removedId)
            cancelFacetWrites(for: removedId)
            cancelDebouncedWrites(for: removedId, recomputeRow: false)
            clearOptimisticLockEntries(for: removedId)
            clearOptimisticRevisions(for: removedId)
            manualWriteSessions.removeValue(forKey: removedId)
            deviceFacets.removeValue(forKey: removedId)
            deviceTransportDiagnostics.removeValue(forKey: removedId)
            lastReportedDevices.removeValue(forKey: removedId)
            lastReportedFacets.removeValue(forKey: removedId)
        }

        // Surviving dual-source paired cards fail over to Home Assistant; cancel in-flight MIoT writes
        // and strip any Xiaomi-contributed drawer facets belonging to the disabled account.
        let retainedPairedIds = pairedDeviceIDs.subtracting(disabledDeviceIds)
        for pairedId in retainedPairedIds {
            if deviceBackends[pairedId] == .xiaomiCloud, isPairedCardServedByEnabledHA(pairedId) {
                releaseReadBackEcho(for: pairedId)
                cancelFacetWrites(for: pairedId)
                cancelDebouncedWrites(for: pairedId, recomputeRow: false)
                clearOptimisticLockEntries(for: pairedId)
                clearOptimisticRevisions(for: pairedId)
                manualWriteSessions.removeValue(forKey: pairedId)
                deviceBackends[pairedId] = .homeAssistant
            }
            if let existingFacets = deviceFacets[pairedId] {
                let keptFacets = existingFacets.filter { !shouldSuppressMiotFacet($0) }
                if keptFacets.count != existingFacets.count {
                    cancelFacetWrites(for: pairedId)
                    if keptFacets.isEmpty {
                        deviceFacets.removeValue(forKey: pairedId)
                    } else {
                        deviceFacets[pairedId] = keptFacets
                    }
                }
            }
        }

        devices.removeAll { disabledDeviceIds.contains($0.id) || isMiOwnedRow($0, accountId: id) }
        for index in devices.indices where devices[index].accountId == id && deviceBackends[devices[index].id] == .homeAssistant {
            devices[index].accountId = nil
            devices[index].accountLabel = nil
        }
        if !devices.isEmpty { syncIndexedDevices(from: devices) }
        environmentReadings.removeAll { disabledDeviceIds.contains($0.id) }
        rooms.removeAll { MiAccountScope.isOwned($0.id, by: id) }
        homes.removeAll { $0.accountId == id }
        if let roomId = selectedRoomId, MiAccountScope.isOwned(roomId, by: id) { selectRoom(nil) }

        onMiAccountDisabled?(id, disabledDeviceIds)

        if activeDualProvider != nil || provider is MiAccountsProvider {
            rebuildLiveProvider()
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        } else if let dual = provider as? DualSourceHomeProvider {
            syncHistoryConnectionScopes()
            syncScheduledCommandScopeIfNeeded()
            let shouldRemoveMiSource = !hasEnabledMiSource
            let previousShutdown = providerShutdownTask
            providerShutdownTask = Task {
                await previousShutdown?.value
                await dual.revokeXiaomiAccountsGrace(revocations)
                if shouldRemoveMiSource {
                    await dual.setSourceProvider(nil, for: .xiaomiCloud)
                }
            }
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        } else {
            syncHistoryConnectionScopes()
            syncScheduledCommandScopeIfNeeded()
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        }
        scheduleRaycastSnapshotExport()
    }

    // MARK: - Host Control Write Gate

    public func evaluateDeviceControlGate(deviceId: String, expectedGeneration: Int? = nil) -> ControlTargetGateVerdict {
        deviceControlGate(for: resolvedIndexedDevice(for: deviceId), deviceId: deviceId, expectedGeneration: expectedGeneration)
    }

    private func deviceControlGate(
        for indexed: CapabilityIndexedDevice?, deviceId: String, expectedGeneration: Int? = nil
    ) -> ControlTargetGateVerdict {
        var selection = capabilitySelection
        if let indexed, homeBackend == .demo, provider is DemoHomeProvider,
           indexed.sourceScope == "demo", deviceBackends[indexed.id] == .demo {
            selection.enabledCategories.insert(indexed.category)
        }
        return CapabilityReferenceEngine.evaluateControlTargetGate(
            targetKind: .device, targetId: deviceId, expectedGeneration: expectedGeneration,
            currentGeneration: capabilityGeneration, selection: selection,
            devices: indexed.map { [$0] } ?? [], scenes: []
        )
    }

    public func evaluateSceneControlGate(sceneId: String, expectedGeneration: Int? = nil) -> ControlTargetGateVerdict {
        let scene = resolvedSceneReference(for: sceneId)
        return CapabilityReferenceEngine.evaluateControlTargetGate(
            targetKind: .scene, targetId: sceneId, expectedGeneration: expectedGeneration,
            currentGeneration: capabilityGeneration, selection: capabilitySelection,
            devices: [], scenes: scene.map { [$0] } ?? []
        )
    }

    public func capabilityControlRejectionMessage(forDeviceId deviceId: String, allowNameMatch: Bool = false) -> String? {
        let gate = evaluateDeviceControlGate(deviceId: deviceId)
        if !gate.allowed, let reason = gate.rejectionReason, reason != .deviceNotFound {
            return reason.userMessage
        }
        guard allowNameMatch else { return nil }
        let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matched = currentIndexedDevicesList().filter { $0.name == trimmed }
        guard matched.count == 1, let single = matched.first else { return nil }
        let byNameGate = evaluateDeviceControlGate(deviceId: single.id)
        guard !byNameGate.allowed, let reason = byNameGate.rejectionReason, reason != .deviceNotFound else { return nil }
        return reason.userMessage
    }

    public func capabilitySceneControlRejectionMessage(forSceneIdOrName sceneIdOrName: String) -> String? {
        guard homeBackend != .demo else { return nil }
        let needle = sceneIdOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let normalizedNeedle = IntentValidator.normalizedSceneName(needle)
        let refs = currentSceneReferences()
        if let matched = refs.first(where: {
            $0.id.caseInsensitiveCompare(needle) == .orderedSame
                || IntentValidator.normalizedSceneName($0.name).caseInsensitiveCompare(normalizedNeedle) == .orderedSame
                || "scene.\($0.name)".caseInsensitiveCompare(needle) == .orderedSame
        }) {
            let gate = evaluateSceneControlGate(sceneId: matched.id)
            guard !gate.allowed, let reason = gate.rejectionReason, reason != .sceneNotFound else { return nil }
            return reason.userMessage
        }
        return nil
    }

    func firstPlanCapabilityRejectionMessage(for intents: [DeviceIntent]) -> String? {
        for intent in intents {
            if intent.operation == .activateScene {
                if let msg = capabilitySceneControlRejectionMessage(forSceneIdOrName: intent.targetId) {
                    return msg
                }
            } else if let reason = capabilityWriteRejection(forDeviceId: intent.targetId) {
                return reason.userMessage
            }
        }
        return nil
    }

    /// O(1) single-device write gate for hot list loops (`allOffTargets`, `controllableDevices`,
    /// `buildRaycastSnapshot`) without scanning `devices` or sorting the full device index.
    func capabilityWriteRejection(for device: SmartDevice) -> ControlTargetRejectionReason? {
        deviceControlGate(for: makeIndexedDevice(from: device), deviceId: device.id).rejectionReason
    }

    /// Capability rejection for a command target, resolved from the live rows as well as the persisted
    /// index. A stale index entry must not let a command slip past the gate that the panel applies
    /// (Bugbot #275: write gate skipped without index entry).
    func capabilityWriteRejection(forDeviceId deviceId: String) -> ControlTargetRejectionReason? {
        guard let indexed = resolvedIndexedDevice(for: deviceId) else { return nil }
        return deviceControlGate(for: indexed, deviceId: deviceId).rejectionReason
    }

    /// Fail-closed write gate for Home Assistant domain entities (`light.*`, `switch.*`, `scene.*`,
    /// `script.*`, `button.*`, etc.) when Home Assistant is disabled.
    func haCommandWriteRejection(for entityId: String) -> ControlTargetRejectionReason? {
        guard homeBackend != .demo,
              (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)),
              !isHAConnectionEnabled else {
            return nil
        }
        if MiotAddress.parse(entityId) != nil || LGWebOSProtocol.isLGEntity(entityId) {
            return nil
        }
        guard let dot = entityId.firstIndex(of: ".") else { return nil }
        let domain = entityId[..<dot]
        guard !domain.isEmpty, domain.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        return .connectionDisabled(.homeAssistant, scope: homeAssistantScopeIdentifier)
    }

    func shouldSuppressHAFacet(_ control: FacetControl) -> Bool {
        guard homeBackend != .demo,
              (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)),
              !isHAConnectionEnabled else {
            return false
        }
        switch control.target {
        case .haProperty, .haAction:
            return true
        case .property, .action:
            return false
        case nil:
            if LGWebOSProtocol.isLGEntity(control.id) || MiotAddress.parse(control.id) != nil {
                return false
            }
            guard let dot = control.id.firstIndex(of: ".") else { return false }
            let prefix = control.id[..<dot]
            return !prefix.isEmpty && prefix.allSatisfy { $0.isLetter || $0 == "_" }
        }
    }

    /// Fail-closed write gate for any MIoT property or action entity (`miot:<did>:...` / `miot-action:<did>:...`),
    /// including drawer facets on split-channel rows and Xiaomi-contributed facets merged onto HA paired cards.
    func miotCommandWriteRejection(for entityId: String) -> ControlTargetRejectionReason? {
        guard let parsed = MiotAddress.parse(entityId) else { return nil }
        let isXiaomiManaged = !miAccounts.isEmpty
            || miSessionScopeIdentifier != nil
            || explicitlyDisabledConnections.contains(.xiaomiCloud)
        guard isXiaomiManaged else { return nil }

        if !capabilitySelection.enabledConnections.contains(.xiaomiCloud) {
            let fallbackScope = miAccounts.first?.id ?? miSessionScopeIdentifier ?? "xiaomi"
            return .connectionDisabled(.xiaomiCloud, scope: fallbackScope)
        }

        var candidateScopes = miotDidToAccountScopes[parsed.did] ?? []
        if let scopedOwner = MiAccountScope.owner(of: parsed.did),
           isCapabilityScopeConfigured(.xiaomiCloud, scope: scopedOwner) {
            candidateScopes.insert(scopedOwner)
        }
        for dev in devices where dev.id == parsed.did || dev.id.hasPrefix("\(parsed.did).s") || dev.miotCommandDids.contains(parsed.did) {
            if let acc = dev.accountId, isCapabilityScopeConfigured(.xiaomiCloud, scope: acc) {
                candidateScopes.insert(acc)
            }
        }
        for (devId, facets) in deviceFacets where facets.contains(where: {
            $0.referencedEntityIds.contains(entityId)
                || $0.referencedEntityIds.contains { MiotAddress.parse($0)?.did == parsed.did }
        }) {
            if let dev = devices.first(where: { $0.id == devId }),
               let acc = dev.accountId, isCapabilityScopeConfigured(.xiaomiCloud, scope: acc) {
                candidateScopes.insert(acc)
            }
        }
        for (devId, indexed) in indexedDevicesById
        where (devId == parsed.did || devId.hasPrefix("\(parsed.did).s")) && indexed.connection == .xiaomiCloud {
            if isCapabilityScopeConfigured(.xiaomiCloud, scope: indexed.sourceScope) {
                candidateScopes.insert(indexed.sourceScope)
            }
        }
        candidateScopes = candidateScopes.filter { isCapabilityScopeConfigured(.xiaomiCloud, scope: $0) }

        if !hasEnabledMiSource {
            if let scope = candidateScopes.sorted().first ?? miAccounts.first?.id ?? miSessionScopeIdentifier {
                return .connectionScopeDisabled(.xiaomiCloud, scope: scope)
            }
            return .connectionDisabled(.xiaomiCloud, scope: "xiaomi")
        }

        if !candidateScopes.isEmpty {
            if candidateScopes.contains(where: { isMiAccountEnabled($0) }) {
                return nil
            }
            return .connectionScopeDisabled(.xiaomiCloud, scope: candidateScopes.sorted().first!)
        }

        // Fail-closed when `parsed.did` has no recorded owner while at least one configured Xiaomi
        // account is disabled (cannot prove the target belongs to an enabled account).
        if let firstDisabled = miAccounts.first(where: { !isMiAccountEnabled($0.id) }) {
            return .connectionScopeDisabled(.xiaomiCloud, scope: firstDisabled.id)
        }
        if miAccounts.isEmpty, let singleScope = miSessionScopeIdentifier, !isMiAccountEnabled(singleScope) {
            return .connectionScopeDisabled(.xiaomiCloud, scope: singleScope)
        }
        return nil
    }

    func shouldSuppressMiotFacet(_ control: FacetControl, snapshotEpoch: Int? = nil) -> Bool {
        let miotDids = control.referencedEntityIds.compactMap { MiotAddress.parse($0)?.did }
        guard !miotDids.isEmpty else { return false }
        let isXiaomiManaged = !miAccounts.isEmpty
            || miSessionScopeIdentifier != nil
            || explicitlyDisabledConnections.contains(.xiaomiCloud)
        guard isXiaomiManaged else { return false }
        if !hasEnabledMiSource { return true }
        for did in miotDids {
            var scopes = miotDidToAccountScopes[did] ?? []
            if let owner = MiAccountScope.owner(of: did), isCapabilityScopeConfigured(.xiaomiCloud, scope: owner) {
                scopes.insert(owner)
            }
            scopes = scopes.filter { isCapabilityScopeConfigured(.xiaomiCloud, scope: $0) }
            if !scopes.isEmpty {
                let anyActive = scopes.contains { scope in
                    if let snapshotEpoch {
                        return !shouldSuppressMiAccountInSnapshot(scope, snapshotEpoch: snapshotEpoch)
                    }
                    return isMiAccountEnabled(scope)
                }
                if !anyActive { return true }
            } else if miAccounts.contains(where: { shouldSuppressMiAccountInSnapshot($0.id, snapshotEpoch: snapshotEpoch) }) {
                return true
            }
        }
        return false
    }

    @discardableResult
    func rejectDeviceWriteIfCapabilityDisabled(deviceId: String) -> ControlTargetRejectionReason? {
        guard let indexed = resolvedIndexedDevice(for: deviceId),
              indexed.connection != nil || !capabilitySelection.enabledCategories.contains(indexed.category) else { return nil }
        let verdict = deviceControlGate(for: indexed, deviceId: deviceId)
        guard !verdict.allowed, let reason = verdict.rejectionReason else { return nil }
        showToast(reason.userMessage, isError: true)
        return reason
    }

    func owningDeviceIdForCommand(_ command: DeviceCommand) -> String? {
        let entityId = command.targetEntityId
        if LGWebOSProtocol.isLGEntity(entityId) { return LGWebOSProtocol.deviceId }
        if let live = devices.first(where: { $0.referencedEntityIds.contains(entityId) }) { return live.id }
        if let facetOwner = deviceFacets.first(where: { $0.value.contains { $0.referencedEntityIds.contains(entityId) } })?.key {
            return facetOwner
        }
        if let parsed = MiotAddress.parse(entityId) {
            if let liveByDid = devices.first(where: {
                $0.id == parsed.did || $0.id.hasPrefix("\(parsed.did).s") || $0.miotCommandDids.contains(parsed.did)
            }) {
                return liveByDid.id
            }
            if indexedDevicesById[parsed.did] != nil { return parsed.did }
            let splitId = "\(parsed.did).s\(parsed.siid)"
            if indexedDevicesById[splitId] != nil { return splitId }
            if let anySplit = indexedDevicesById.keys.sorted().first(where: { $0.hasPrefix("\(parsed.did).s") }) {
                return anySplit
            }
            if let dual = activeDualProvider ?? (provider as? DualSourceHomeProvider) {
                if let canonical = dual.canonicalID(forSourceID: splitId, backend: .xiaomiCloud),
                   indexedDevicesById[canonical] != nil {
                    return canonical
                }
                if let canonical = dual.canonicalID(forSourceID: parsed.did, backend: .xiaomiCloud),
                   indexedDevicesById[canonical] != nil {
                    return canonical
                }
            }
            return parsed.did
        }
        if indexedDevicesById[entityId] != nil { return entityId }
        // A closed Home Assistant type keeps its cards' entities as read keys (P3b-M), so a stored
        // entity command still meets「该设备类型已关闭」 instead of slipping past the gate.
        return indexedDevicesById.values
            .filter { $0.readKeys.contains(entityId) }
            .map(\.id).min()
    }

    // MARK: - Device Indexing & Reference Graph

    func loadPersistedCapabilityState() {
        if let data = userDefaults.data(forKey: Self.capabilityDeviceIndexKey),
           let decoded = try? JSONDecoder().decode([String: CapabilityIndexedDevice].self, from: data) {
            indexedDevicesById = decoded
        }
        if let data = userDefaults.data(forKey: Self.capabilitySceneIndexKey),
           let decoded = try? JSONDecoder().decode([String: SceneReference].self, from: data) {
            indexedScenesById = decoded
        }
        if let data = userDefaults.data(forKey: Self.capabilityMiotDidScopesKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            miotDidToAccountScopes = decoded.mapValues(Set.init)
        }
        pausedScheduledCommands = PausedScheduledCommand.load(from: userDefaults)
        pausedQuickActionIDs = Set(userDefaults.stringArray(forKey: Self.pausedQuickActionsKey) ?? [])
        if let data = userDefaults.data(forKey: Self.pausedQuickActionScopesKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            pausedQuickActionScopes = decoded.filter { pausedQuickActionIDs.contains($0.key) }
        }
        // `pendingRevalidationScopes` is in memory only, so a relaunch between "enable" and the first
        // fresh snapshot would leave paused items paused forever. Rebuild the work from the pause
        // markers themselves: every enabled scope is revalidated once it is fresh again.
        let rules = AutomationRuleStore(defaults: userDefaults).load()
        let hasPausedReferences = !pausedScheduledCommands.isEmpty
            || !pausedQuickActionIDs.isEmpty
            || rules.contains { !$0.pausedCapabilities.isEmpty || !$0.pausedScopes.isEmpty }
        if hasPausedReferences { pendingRevalidationScopes.formUnion(capabilitySelection.enabledConnectionScopes) }
    }

    func syncIndexedDevices(from currentDevices: [SmartDevice]) {
        guard !currentDevices.isEmpty else { return }
        var changed = false
        for device in currentDevices {
            let entry = makeIndexedDevice(from: device)
            if indexedDevicesById[device.id] != entry {
                indexedDevicesById[device.id] = entry
                changed = true
            }
        }
        if changed { persistIndexedDevices() }
        _ = recordMiotDidAccountScopes(from: currentDevices, facetsByDeviceId: deviceFacets)
    }

    func syncIndexedScenes(from currentScenes: [HomeScene]) {
        guard !currentScenes.isEmpty else { return }
        var changed = false
        for scene in currentScenes {
            let entry = makeSceneReference(from: scene)
            if indexedScenesById[scene.id] != entry {
                indexedScenesById[scene.id] = entry
                changed = true
            }
        }
        if changed { persistIndexedScenes() }
    }

    @discardableResult
    func recordMiotDidAccountScopes(
        from candidateDevices: [SmartDevice],
        facetsByDeviceId: [String: [FacetControl]]
    ) -> Bool {
        var didScopesChanged = false
        for device in candidateDevices {
            let miScope: String? = {
                if let acc = device.accountId, !acc.isEmpty, isCapabilityScopeConfigured(.xiaomiCloud, scope: acc) {
                    return acc
                }
                let (conn, scope) = inferSource(for: device)
                if conn == .xiaomiCloud, isCapabilityScopeConfigured(.xiaomiCloud, scope: scope) {
                    return scope
                }
                if let existing = indexedDevicesById[device.id],
                   existing.connection == .xiaomiCloud,
                   isCapabilityScopeConfigured(.xiaomiCloud, scope: existing.sourceScope) {
                    return existing.sourceScope
                }
                if miAccounts.count == 1, isCapabilityScopeConfigured(.xiaomiCloud, scope: miAccounts[0].id) {
                    let hasMiotFacet = (facetsByDeviceId[device.id] ?? []).contains {
                        $0.referencedEntityIds.contains { MiotAddress.parse($0) != nil }
                    }
                    if hasMiotFacet { return miAccounts[0].id }
                }
                return nil
            }()
            guard let miScope else { continue }

            var dids = Set(device.miotCommandDids)
            if let splitRange = device.id.range(of: ".s", options: .backwards),
               device.id[splitRange.upperBound...].allSatisfy(\.isNumber) {
                dids.insert(String(device.id[..<splitRange.lowerBound]))
            } else if device.accountId != nil || deviceBackends[device.id] == .xiaomiCloud,
                      !device.id.contains(".") {
                dids.insert(device.id)
            }
            for facet in facetsByDeviceId[device.id] ?? [] {
                for entityId in facet.referencedEntityIds {
                    if let parsed = MiotAddress.parse(entityId) {
                        dids.insert(parsed.did)
                    }
                }
            }
            for did in dids where !did.isEmpty {
                var set = miotDidToAccountScopes[did] ?? []
                if set.insert(miScope).inserted {
                    miotDidToAccountScopes[did] = set
                    didScopesChanged = true
                }
            }
        }
        if didScopesChanged { persistMiotDidScopes() }
        return didScopesChanged
    }

    func shouldSuppressMiAccountInSnapshot(_ accountId: String, snapshotEpoch: Int?) -> Bool {
        if revokedMiAccountScopes.contains(accountId) { return true }
        if !isMiAccountEnabled(accountId) { return true }
        if pendingRevalidationScopes.contains(accountId),
           let snapshotEpoch,
           snapshotEpoch != miAccountsConfigEpoch {
            return true
        }
        return false
    }

    func reconcileReenabledScopesAfterSnapshot(_ snapshot: SynthesizedHome) {
        guard !pendingRevalidationScopes.isEmpty else { return }
        let presentIds = Set(snapshot.devices.map(\.id))
        let presentSceneIds = Set(snapshot.scenes.map(\.id))
        var completedScopes: Set<String> = []
        for scope in pendingRevalidationScopes {
            if !capabilitySelection.isSourceEnabled(connection: nil, scope: scope) {
                completedScopes.insert(scope)
                continue
            }
            let accountReady: Bool
            if CapabilityReferenceEngine.connectionCapability(forScope: scope) != .xiaomiCloud {
                let haConnected: Bool
                if let status = snapshot.sourceStatuses[.homeAssistant] ?? sourceStatuses[.homeAssistant] {
                    haConnected = status.isConnected
                } else if case .disconnected = connectionStatus {
                    haConnected = false
                } else {
                    haConnected = true
                }
                // A merged snapshot may arrive after HA reports connected but before HA supplies data,
                // or still carry an older HA instance's snapshot across a URL change.
                let includesHA = snapshot.sourceStatuses[.homeAssistant] == nil
                    || snapshot.activeBackends.contains(.homeAssistant)
                let matchesHAScope = snapshot.homeAssistantScope == nil || snapshot.homeAssistantScope == scope
                accountReady = snapshot.isInitialLoadComplete
                    && snapshot.closesAwayGap
                    && haConnected
                    && includesHA
                    && matchesHAScope
            } else if selectedHomeHidesScope(scope) {
                accountReady = false
            } else if activeMiAccountsProvider != nil || snapshot.miAccountsEpoch != nil {
                accountReady = snapshot.miAccountsEpoch == miAccountsConfigEpoch
                    && snapshot.freshAccountIds.contains(scope)
                    && (snapshot.accountStatuses[scope]?.isConnected ?? true)
            } else {
                accountReady = snapshot.isInitialLoadComplete && snapshot.closesAwayGap
            }
            guard accountReady else { continue }
            let beforeCount = indexedDevicesById.count
            indexedDevicesById = indexedDevicesById.filter { $0.value.sourceScope != scope || presentIds.contains($0.key) }
            if indexedDevicesById.count != beforeCount { persistIndexedDevices() }
            if CapabilityReferenceEngine.connectionCapability(forScope: scope) == .homeAssistant {
                let beforeSceneCount = indexedScenesById.count
                indexedScenesById = indexedScenesById.filter { $0.value.sourceScope != scope || presentSceneIds.contains($0.key) }
                if indexedScenesById.count != beforeSceneCount { persistIndexedScenes() }
            }
            completedScopes.insert(scope)
        }
        guard !completedScopes.isEmpty else { return }
        pendingRevalidationScopes.subtract(completedScopes)
        revalidatePausedItems(snapshot: snapshot)
    }

    /// True while any Mi home is selected. A selected home filters the provider's device list to that
    /// home — for the owning account and (with everything) for the others — so its snapshot is not an
    /// inventory of the account. Only "all homes" can prune targets or finish pending revalidation.
    private func selectedHomeHidesScope(_ scope: String) -> Bool {
        guard CapabilityReferenceEngine.connectionCapability(forScope: scope) == .xiaomiCloud else { return false }
        return selectedMiHomeId != nil
    }

    /// The scope still exists in the user's configuration, whether or not it is turned on.
    private func isCapabilityScopeConfigured(_ connection: ConnectionCapabilityID, scope: String) -> Bool {
        switch connection {
        case .xiaomiCloud:
            return miAccounts.isEmpty ? miSessionScopeIdentifier == scope : miAccounts.contains { $0.id == scope }
        case .homeAssistant:
            return (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant))
                && homeAssistantScopeIdentifier == scope
        }
    }

    /// Timers classify foreign ownership separately. Manual quick actions use the current connections.
    private func pausedItemScopesAreSettled(_ scopes: [String], requiresOriginalHA: Bool = false) -> Bool {
        scopes.allSatisfy { scope in
            guard let connection = CapabilityReferenceEngine.connectionCapability(forScope: scope) else { return true }
            guard isCapabilityScopeConfigured(connection, scope: scope) else {
                return !requiresOriginalHA || connection != .homeAssistant
            }
            return capabilitySelection.isSourceEnabled(connection: connection, scope: scope)
                && !pendingRevalidationScopes.contains(scope)
        }
    }

    func pausedQuickActionMessage(for action: QuickAction) -> String {
        pausedQuickActionMessage(forPausedID: action.rawValue, title: action.title)
    }

    /// The toast a paused quick action or device group shows when someone runs it. A pause that no
    /// automatic pass can clear names the manual resume instead of a cause the user cannot act on.
    func pausedQuickActionMessage(forPausedID id: String, title: String) -> String {
        if pausedQuickActionRequiresManualResume(id) {
            return L10n.format(
                "「%@」已暂停且不再记录原连接，需要手动恢复：设置 › 常规 › 自动化与外部控制",
                "“%@” stays paused without the connection it lost, so it cannot resume on its own; resume it manually in Settings › General › Automation & External Control",
                title
            )
        }
        let categories = QuickActionReferenceKind(rawValue: id)?.targetCategories ?? []
        let hasDisabledScope = (pausedQuickActionScopes[id] ?? []).contains { scope in
            guard let connection = CapabilityReferenceEngine.connectionCapability(forScope: scope),
                  isCapabilityScopeConfigured(connection, scope: scope) else { return false }
            return !capabilitySelection.isSourceEnabled(connection: connection, scope: scope)
        }
        if !hasDisabledScope, !categories.isSubset(of: capabilitySelection.enabledCategories) {
            return L10n.tr("该快捷动作因设备类型关闭已暂停", "This quick action is paused while a device type is turned off")
        }
        return L10n.tr("该快捷动作因连接停用已暂停", "This quick action is paused while its connection is disabled")
    }

    /// A paused group or quick action that no automatic pass can clear. `requireManualResumeAfterHARemoval`
    /// writes a group with no scope so it never resumes against an HA server it was never paused for,
    /// and releases before #389 left the same shape behind; either way only the user can release it.
    func pausedQuickActionRequiresManualResume(_ id: String) -> Bool {
        guard pausedQuickActionIDs.contains(id), id.hasPrefix(Self.pausedQuickActionGroupIDPrefix) else {
            return false
        }
        let scopes = pausedQuickActionScopes[id] ?? []
        return scopes.isEmpty || scopes.contains { scope in
            guard let connection = CapabilityReferenceEngine.connectionCapability(forScope: scope) else { return false }
            // A configured HA scope is only waiting for its connection, which settles on its own.
            return connection == .homeAssistant && !isCapabilityScopeConfigured(connection, scope: scope)
        }
    }

    /// A paused rule that no automatic pass can resume: it was paused for HA but no longer records
    /// the `ha:` scope it lost, so the automation switch is the manual path.
    public func pausedRuleRequiresManualResume(_ rule: AutomationRule) -> Bool {
        !rule.isEnabled
            && rule.pausedCapabilities.contains(.connection(.homeAssistant))
            && !rule.pausedScopes.contains { $0.hasPrefix("ha:") }
    }

    /// A paused quick action keeps its raw id: `QuickAction` cases and legacy `group:` ids share the store.
    public struct PausedQuickAction: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Paused quick actions and groups the user has to release by hand; the settings list shows them.
    public var pausedQuickActionsRequiringManualResume: [PausedQuickAction] {
        pausedQuickActionIDs
            .filter(pausedQuickActionRequiresManualResume)
            .sorted()
            .map { PausedQuickAction(id: $0, title: pausedQuickActionTitle($0)) }
    }

    private func pausedQuickActionTitle(_ id: String) -> String {
        guard id.hasPrefix(Self.pausedQuickActionGroupIDPrefix) else {
            return QuickAction(rawValue: id)?.title ?? id
        }
        let groupId = String(id.dropFirst(Self.pausedQuickActionGroupIDPrefix.count))
        return loadDeviceGroupReferences().groups.first { $0.id == groupId }?.name ?? groupId
    }

    /// Resumes one paused quick action or group on the user's word. Its pause markers cannot settle
    /// once the connection they were paused for is gone, so the user replaces them; the targets are
    /// still re-checked with the availability rule auto-resume uses, never a fresh write gate.
    @discardableResult
    public func resumePausedQuickAction(id: String) -> Bool {
        guard pausedQuickActionIDs.contains(id) else { return false }
        let indexed = currentIndexedDevicesList()
        let groupById = Dictionary(
            loadDeviceGroupReferences().groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let availableSet = Set(CapabilityReferenceEngine.partitionDevices(
            devices: indexed, selection: capabilitySelection, safetyPolicy: effectiveSafetyRetentionPolicy()
        ).availableDeviceIds)
        let title = pausedQuickActionTitle(id)
        guard pausedQuickActionTargetsAreAvailable(
            id, indexed: indexed, availableSet: availableSet, groupById: groupById
        ) else {
            showToast(
                L10n.format(
                    "「%@」的目标仍不可用，暂时无法恢复",
                    "“%@” cannot resume yet; its targets are still unavailable",
                    title
                ),
                isError: true
            )
            return false
        }
        pausedQuickActionIDs.remove(id)
        pausedQuickActionScopes.removeValue(forKey: id)
        if pausedQuickActionIDs.isEmpty {
            userDefaults.removeObject(forKey: Self.pausedQuickActionsKey)
        } else {
            userDefaults.set(pausedQuickActionIDs.sorted(), forKey: Self.pausedQuickActionsKey)
        }
        persistPausedQuickActionScopes()
        return true
    }

    /// One availability rule for paused quick actions and groups: auto-resume and the manual resume
    /// button share it, so a manual resume cannot revive a target the automatic path still refuses.
    private func pausedQuickActionTargetsAreAvailable(
        _ id: String,
        indexed: [CapabilityIndexedDevice],
        availableSet: Set<String>,
        groupById: [String: DeviceGroupReference]
    ) -> Bool {
        if id.hasPrefix(Self.pausedQuickActionGroupIDPrefix) {
            let groupId = String(id.dropFirst(Self.pausedQuickActionGroupIDPrefix.count))
            guard let group = groupById[groupId], !group.memberDeviceIds.isEmpty else { return false }
            return group.memberDeviceIds.allSatisfy(availableSet.contains)
        }
        guard let kind = QuickActionReferenceKind(rawValue: id) else { return true }
        let categories = kind.targetCategories
        return categories.allSatisfy(capabilitySelection.enabledCategories.contains)
            && indexed.contains { availableSet.contains($0.id) && categories.contains($0.category) }
    }

    private func persistPausedQuickActionScopes() {
        if pausedQuickActionScopes.isEmpty {
            userDefaults.removeObject(forKey: Self.pausedQuickActionScopesKey)
            return
        }
        if let data = try? JSONEncoder().encode(pausedQuickActionScopes) {
            userDefaults.set(data, forKey: Self.pausedQuickActionScopesKey)
        }
    }

    /// The scopes actually lost by a paused timer; older records only stamped their source set.
    private func pausedTimerScopes(_ paused: PausedScheduledCommand) -> [String] {
        paused.pausedScopes.isEmpty ? (paused.command.effectiveSourceScopes ?? []) : paused.pausedScopes
    }

    private func persistIndexedDevices() {
        if let data = try? JSONEncoder().encode(indexedDevicesById) {
            userDefaults.set(data, forKey: Self.capabilityDeviceIndexKey)
        }
    }

    func persistIndexedScenes() {
        if indexedScenesById.isEmpty {
            userDefaults.removeObject(forKey: Self.capabilitySceneIndexKey)
            return
        }
        if let data = try? JSONEncoder().encode(indexedScenesById) {
            userDefaults.set(data, forKey: Self.capabilitySceneIndexKey)
        }
    }

    private func persistMiotDidScopes() {
        if miotDidToAccountScopes.isEmpty {
            userDefaults.removeObject(forKey: Self.capabilityMiotDidScopesKey)
            return
        }
        let serializable = miotDidToAccountScopes.mapValues { $0.sorted() }
        if let data = try? JSONEncoder().encode(serializable) {
            userDefaults.set(data, forKey: Self.capabilityMiotDidScopesKey)
        }
    }

    private func materializeIndexedDevice(_ stored: CapabilityIndexedDevice) -> CapabilityIndexedDevice {
        CapabilityIndexedDevice(
            id: stored.id, name: stored.name, category: stored.category,
            connection: stored.connection, sourceScope: stored.sourceScope,
            isSourceAvailable: isScopeConfiguredAndAvailable(connection: stored.connection, scope: stored.sourceScope),
            upstreamHiddenOrDisabled: stored.upstreamHiddenOrDisabled,
            participatesInAllOff: allOffOverrides[stored.id] ?? stored.participatesInAllOff,
            safetySignals: stored.safetySignals, readKeys: stored.readKeys, safetyReadKeys: stored.safetyReadKeys
        )
    }

    private func resolvedIndexedDevice(for deviceId: String) -> CapabilityIndexedDevice? {
        if let live = devices.first(where: { $0.id == deviceId }) { return makeIndexedDevice(from: live) }
        return indexedDevicesById[deviceId].map(materializeIndexedDevice)
    }

    func currentIndexedDevicesList() -> [CapabilityIndexedDevice] {
        var map = indexedDevicesById.mapValues(materializeIndexedDevice)
        for live in devices { map[live.id] = makeIndexedDevice(from: live) }
        return map.values.sorted { $0.id < $1.id }
    }

    private func makeIndexedDevice(from device: SmartDevice) -> CapabilityIndexedDevice {
        let (connection, scope) = inferSource(for: device)
        return CapabilityIndexedDevice(
            id: device.id, name: device.name, category: device.capabilityCategoryID,
            connection: connection, sourceScope: scope,
            isSourceAvailable: isScopeConfiguredAndAvailable(connection: connection, scope: scope),
            upstreamHiddenOrDisabled: false, participatesInAllOff: joinsAllOff(device),
            safetySignals: safetySignals(for: device), readKeys: [device.id], safetyReadKeys: []
        )
    }

    func inferSource(for device: SmartDevice) -> (ConnectionCapabilityID?, String) {
        if lgClientServes(device) || device.id == LGWebOSProtocol.deviceId { return (nil, "lan:lg-webos") }
        let haManaged = hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)
        let miManaged = !miAccounts.isEmpty || hasMiSource || explicitlyDisabledConnections.contains(.xiaomiCloud)
        if homeBackend != .demo {
            // Preserve explicit user source pins across child provider teardown: when HA or Xiaomi
            // is turned off, DualSourceHomeProvider merges only the surviving child, which would
            // otherwise re-attribute a pinned paired card to the unpinned side.
            if pinnedSource(for: device.id) == .homeAssistant, haManaged, !isHAConnectionEnabled {
                return (.homeAssistant, homeAssistantScopeIdentifier)
            }
            if pinnedSource(for: device.id) == .xiaomiCloud, miManaged, !hasEnabledMiSource {
                if let accountId = device.accountId, !accountId.isEmpty,
                   isCapabilityScopeConfigured(.xiaomiCloud, scope: accountId) {
                    return (.xiaomiCloud, accountId)
                }
                if let scope = miAccounts.first?.id ?? miSessionScopeIdentifier {
                    return (.xiaomiCloud, scope)
                }
            }
        }
        switch deviceBackends[device.id] {
        case .homeAssistant where haManaged:
            if !isHAConnectionEnabled,
               let miScope = enabledMiFailoverScope(for: device.id, accountHint: device.accountId) {
                return (.xiaomiCloud, miScope)
            }
            return (.homeAssistant, homeAssistantScopeIdentifier)
        case .xiaomiCloud where miManaged:
            if let accountId = device.accountId, !accountId.isEmpty,
               isCapabilityScopeConfigured(.xiaomiCloud, scope: accountId) {
                if !isMiAccountEnabled(accountId), isPairedCardServedByEnabledHA(device.id) {
                    return (.homeAssistant, homeAssistantScopeIdentifier)
                }
                return (.xiaomiCloud, accountId)
            }
            if !hasEnabledMiSource, isPairedCardServedByEnabledHA(device.id) {
                return (.homeAssistant, homeAssistantScopeIdentifier)
            }
            if let scope = enabledMiAccounts.first?.id ?? miAccounts.first?.id ?? miSessionScopeIdentifier {
                return (.xiaomiCloud, scope)
            }
        case .demo:
            return (nil, "demo")
        default:
            break
        }
        if homeBackend == .demo { return (nil, "demo") }
        if let accountId = device.accountId, !accountId.isEmpty,
           isCapabilityScopeConfigured(.xiaomiCloud, scope: accountId) {
            if !isMiAccountEnabled(accountId), isPairedCardServedByEnabledHA(device.id) {
                return (.homeAssistant, homeAssistantScopeIdentifier)
            }
            return (.xiaomiCloud, accountId)
        }
        if haManaged && (
            homeBackend == .homeAssistant
                || activeHAProvider != nil
                || isPairedCardServedByEnabledHA(device.id)
                || indexedDevicesById[device.id]?.connection == .homeAssistant
        ) {
            return (.homeAssistant, homeAssistantScopeIdentifier)
        }
        return (nil, "local")
    }

    private func isScopeConfiguredAndAvailable(connection: ConnectionCapabilityID?, scope: String) -> Bool {
        switch connection ?? CapabilityReferenceEngine.connectionCapability(forScope: scope) {
        case .xiaomiCloud:
            return !miAccounts.isEmpty ? miAccounts.contains { $0.id == scope } : (miSessionScopeIdentifier == scope)
        case .homeAssistant:
            return (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant))
                && homeAssistantScopeIdentifier == scope
        case nil:
            return true
        }
    }

    private func safetySignals(for device: SmartDevice) -> Set<SafetySignalKind> {
        if let providerSignals = device.providerSafetySignals { return providerSignals }
        var signals: Set<SafetySignalKind> = [.starredOffline]
        switch device.kind {
        case .plug: signals.formUnion([.longRunningPlug, .highPower])
        case .climate: signals.insert(.longRunningClimate)
        case .sensor(let spec):
            if spec.battery != nil { signals.insert(.lowBattery) }
        default: break
        }
        for observation in device.safetyObservations {
            signals.insert(SafetySignalKind(sensorAlertKind: observation.kind))
        }
        return signals
    }

    func effectiveSafetyRetentionPolicy() -> SafetyRetentionPolicy {
        var enabled: Set<SafetySignalKind> = []
        if enableSafetyAlerts {
            enabled = [.lowBattery, .longRunningPlug, .longRunningClimate, .highPower, .starredOffline]
            for kind in SensorAlertKind.allCases where isSensorAlertEnabled(kind) {
                enabled.insert(SafetySignalKind(sensorAlertKind: kind))
            }
        }
        if doorbellAutoPopup || doorbellChime { enabled.insert(.doorbell) }
        return SafetyRetentionPolicy(enabledSignals: enabled, starredDeviceIds: favoriteDeviceIds)
    }

    private func makeSceneReference(from scene: HomeScene) -> SceneReference {
        let haManaged = hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)
        let conn: ConnectionCapabilityID? = (homeBackend != .demo && haManaged) ? .homeAssistant : nil
        let scope = (homeBackend != .demo && haManaged)
            ? homeAssistantScopeIdentifier
            : (homeBackend == .demo ? "demo" : "local")
        return SceneReference(
            id: scene.id, name: scene.name, connection: conn, sourceScope: scope,
            isSourceAvailable: isScopeConfiguredAndAvailable(connection: conn, scope: scope)
        )
    }

    private func materializeSceneReference(_ stored: SceneReference) -> SceneReference {
        SceneReference(
            id: stored.id, name: stored.name, connection: stored.connection, sourceScope: stored.sourceScope,
            isSourceAvailable: isScopeConfiguredAndAvailable(connection: stored.connection, scope: stored.sourceScope)
        )
    }

    private func resolvedSceneReference(for sceneId: String) -> SceneReference? {
        if let live = scenes.first(where: { $0.id == sceneId }) { return makeSceneReference(from: live) }
        return indexedScenesById[sceneId].map(materializeSceneReference)
    }

    private func currentSceneReferences() -> [SceneReference] {
        var map = indexedScenesById.mapValues(materializeSceneReference)
        for scene in scenes { map[scene.id] = makeSceneReference(from: scene) }
        return map.values.sorted { $0.id < $1.id }
    }

    private func loadDeviceGroupReferences() -> (groups: [DeviceGroupReference], corrupted: [String]) {
        var corrupted: [String] = []
        var rawGroups: [StoredDeviceGroupItem] = []
        if let raw = userDefaults.string(forKey: "device_groups") {
            if let decoded = try? JSONDecoder().decode([StoredDeviceGroupItem].self, from: Data(raw.utf8)) {
                rawGroups = decoded
            } else {
                corrupted.append("device_groups")
            }
        }
        var groupMap: [String: String] = [:]
        if let rawMap = userDefaults.string(forKey: ViewPreferenceKeys.groupMap) {
            if let decoded = try? JSONDecoder().decode([String: String].self, from: Data(rawMap.utf8)) {
                groupMap = decoded
            } else {
                corrupted.append(ViewPreferenceKeys.groupMap)
            }
        }
        let groups = rawGroups.map { item in
            DeviceGroupReference(
                id: item.id, name: item.name,
                memberDeviceIds: groupMap.compactMap { $1 == item.id ? $0 : nil }.sorted()
            )
        }
        return (groups, corrupted)
    }

    /// True when every target of the plan is an LG LAN card. These rows are driven by the LAN client,
    /// so no cloud scope can strand them (ADR-0023); the raw id check also covers a card the index has
    /// not seen yet.
    func timerTargetsAreAllLGLan(_ plan: IntentPlan, indexedById: [String: CapabilityIndexedDevice]? = nil) -> Bool {
        let targets = plan.intents.map(\.targetId)
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { target in
            target == LGWebOSProtocol.deviceId
                || (indexedById ?? indexedDevicesById)[target]?.sourceScope == "lan:lg-webos"
                || devices.first(where: { $0.id == target }).map { lgClientServes($0) } == true
        }
    }

    private func makeTimerReference(
        for cmd: ScheduledCommand,
        partition: TimerPartition,
        pausedCapabilities: [CapabilityID] = [],
        indexedById: [String: CapabilityIndexedDevice]
    ) -> TimerReference {
        let targets = cmd.plan.intents.map(\.targetId)
        let scopes = cmd.effectiveSourceScopes ?? (connectionScopeIdentifier.map { [$0] } ?? [])
        let allLG = timerTargetsAreAllLGLan(cmd.plan, indexedById: indexedById)
        return TimerReference(
            id: cmd.id.uuidString, name: cmd.reply, partition: partition,
            targetIds: targets, sourceScopes: scopes, allTargetsLGLan: allLG,
            pausedCapabilities: pausedCapabilities
        )
    }

    private func proposedMiFailoverScope(for deviceId: String, proposed: CapabilitySelection) -> String? {
        guard pairedDeviceIDs.contains(deviceId),
              pinnedSource(for: deviceId) != .homeAssistant else {
            return nil
        }
        if let hint = devices.first(where: { $0.id == deviceId })?.accountId,
           !hint.isEmpty,
           isCapabilityScopeConfigured(.xiaomiCloud, scope: hint),
           proposed.isSourceEnabled(connection: .xiaomiCloud, scope: hint) {
            return hint
        }
        if let enabledAcc = miAccounts.first(where: { proposed.isSourceEnabled(connection: .xiaomiCloud, scope: $0.id) }) {
            return enabledAcc.id
        }
        if miAccounts.isEmpty,
           let singleScope = miSessionScopeIdentifier,
           proposed.isSourceEnabled(connection: .xiaomiCloud, scope: singleScope) {
            return singleScope
        }
        return nil
    }

    func evaluateCapabilityDeactivation(
        proposed: CapabilitySelection,
        expectedGeneration: Int?
    ) -> CapabilityDeactivationVerdict {
        let haScope = homeAssistantScopeIdentifier
        let haServesFailover = hasEnabledHASource
            && proposed.isSourceEnabled(connection: .homeAssistant, scope: haScope)
        let indexed = currentIndexedDevicesList().map { dev -> CapabilityIndexedDevice in
            if haServesFailover,
               pairedDeviceIDs.contains(dev.id),
               pinnedSource(for: dev.id) != .xiaomiCloud,
               dev.connection == .xiaomiCloud,
               !proposed.isSourceEnabled(connection: dev.connection, scope: dev.sourceScope) {
                return CapabilityIndexedDevice(
                    id: dev.id,
                    name: dev.name,
                    category: dev.category,
                    connection: .homeAssistant,
                    sourceScope: haScope,
                    isSourceAvailable: true,
                    upstreamHiddenOrDisabled: dev.upstreamHiddenOrDisabled,
                    participatesInAllOff: dev.participatesInAllOff,
                    safetySignals: dev.safetySignals,
                    readKeys: dev.readKeys,
                    safetyReadKeys: dev.safetyReadKeys
                )
            }
            if dev.connection == .homeAssistant,
               !proposed.isSourceEnabled(connection: .homeAssistant, scope: dev.sourceScope),
               let miScope = proposedMiFailoverScope(for: dev.id, proposed: proposed) {
                return CapabilityIndexedDevice(
                    id: dev.id,
                    name: dev.name,
                    category: dev.category,
                    connection: .xiaomiCloud,
                    sourceScope: miScope,
                    isSourceAvailable: true,
                    upstreamHiddenOrDisabled: dev.upstreamHiddenOrDisabled,
                    participatesInAllOff: dev.participatesInAllOff,
                    safetySignals: dev.safetySignals,
                    readKeys: dev.readKeys,
                    safetyReadKeys: dev.safetyReadKeys
                )
            }
            return dev
        }
        let graph = buildCapabilityReferenceGraph(indexedDevices: indexed, expectedGeneration: expectedGeneration)
        return CapabilityReferenceEngine.evaluateDeactivation(
            current: capabilitySelection, proposed: proposed, manifest: .shared,
            devices: indexed, safetyPolicy: effectiveSafetyRetentionPolicy(), references: graph
        )
    }

    private func buildCapabilityReferenceGraph(
        indexedDevices: [CapabilityIndexedDevice],
        expectedGeneration: Int?
    ) -> CapabilityReferenceGraph {
        var corrupted: [String] = []
        let indexedById = Dictionary(uniqueKeysWithValues: indexedDevices.map { ($0.id, $0) })
        let sceneRefs = currentSceneReferences()
        let sceneById = Dictionary(uniqueKeysWithValues: sceneRefs.map { ($0.id, $0) })
        let timers = scheduledCommands.map { makeTimerReference(for: $0, partition: .waiting, indexedById: indexedById) }
            + missedScheduledCommands.map { makeTimerReference(for: $0, partition: .missed, indexedById: indexedById) }
            + foreignScheduledCommands.map { makeTimerReference(for: $0, partition: .foreign, indexedById: indexedById) }
            + pausedScheduledCommands.map {
                makeTimerReference(
                    for: $0.command, partition: $0.originalPartition,
                    pausedCapabilities: $0.pausedCapabilities, indexedById: indexedById
                )
            }

        if let rawRulesData = userDefaults.data(forKey: AutomationRuleStore.storageKey),
           (try? JSONSerialization.jsonObject(with: rawRulesData) as? [Any]) == nil {
            corrupted.append(AutomationRuleStore.storageKey)
        }
        let liveScenesForSummary: [HomeScene] = if !scenes.isEmpty {
            scenes
        } else {
            sceneRefs.map { HomeScene(id: $0.id, name: $0.name, entityId: $0.id, iconName: "sparkles") }
        }
        let automations = AutomationRuleStore(defaults: userDefaults).load().map { rule -> AutomationReference in
            let refAction: AutomationReferenceAction
            var scopes: Set<String> = []
            switch rule.action {
            case .devices(let ids, _):
                refAction = .devices(ids)
                for id in ids { if let scope = indexedById[id]?.sourceScope { scopes.insert(scope) } }
            case .scene(let sceneId):
                refAction = .scene(sceneId)
                if let scope = sceneById[sceneId]?.sourceScope {
                    scopes.insert(scope)
                } else if hasHASource || explicitlyDisabledConnections.contains(.homeAssistant) {
                    scopes.insert(homeAssistantScopeIdentifier)
                }
            case .quickAction(let qa):
                refAction = .quickAction(QuickActionReferenceKind(rawValue: qa.rawValue) ?? .lightsOff)
            }
            if scopes.isEmpty { scopes = configuredConnectionScopes() }
            let summary = "\(rule.trigger.title) · \(rule.action.summary(devices: devices, scenes: liveScenesForSummary))"
            return AutomationReference(
                id: rule.id.uuidString, name: summary,
                isEnabled: rule.isEnabled || !rule.pausedCapabilities.isEmpty,
                action: refAction, sourceScopes: scopes.sorted()
            )
        }

        let (groups, _) = loadDeviceGroupReferences()
        let quickActions = QuickAction.allCases.map { qa in
            QuickActionReference(
                id: qa.rawValue, name: qa.title,
                kind: QuickActionReferenceKind(rawValue: qa.rawValue) ?? .lightsOff,
                targetIds: [], isEnabled: !pausedQuickActionIDs.contains(qa.rawValue)
            )
        }

        return CapabilityReferenceGraph(
            timers: timers, automations: automations, quickActions: quickActions,
            scenes: sceneRefs, deviceGroups: groups,
            preferences: .fromUserDefaults(userDefaults), corruptedStoreReasons: corrupted,
            expectedGeneration: expectedGeneration, currentGeneration: capabilityGeneration
        )
    }

    // MARK: - Pause & Re-Enable Revalidation

    /// Preserves an existing `ha:` pause scope when an already-paused item is paused again under a
    /// different HA address, avoiding an unsatisfiable multi-HA scope set while still merging non-HA scopes.
    private func mergePausedScopes(existing: [String], adding: [String]) -> [String] {
        let hasExistingHA = existing.contains { $0.hasPrefix("ha:") }
        let filteredAdding = hasExistingHA ? adding.filter { !$0.hasPrefix("ha:") } : adding
        return Array(Set(existing).union(filteredAdding)).sorted()
    }

    func pauseAffectedReferences(
        _ items: [AffectedReferenceItem],
        fallbackCapabilities: [CapabilityID] = [.connection(.xiaomiCloud)]
    ) {
        var timerPauseById: [UUID: (caps: [CapabilityID], scopes: [String])] = [:]
        var rulePauseById: [UUID: (caps: [CapabilityID], scopes: [String])] = [:]
        var quickActionScopes: [String: [String]] = [:]
        for item in items {
            switch item.kind {
            case .waitingTimer, .missedTimer, .foreignTimer:
                if let uuid = UUID(uuidString: item.id) {
                    timerPauseById[uuid] = (item.affectedCapabilities, item.connectionScopes)
                }
            case .automationRule:
                if let uuid = UUID(uuidString: item.id) {
                    rulePauseById[uuid] = (item.affectedCapabilities, item.connectionScopes)
                }
            case .quickAction:
                quickActionScopes[item.id] = item.connectionScopes
            }
        }

        if !timerPauseById.isEmpty {
            var paused = pausedScheduledCommands
            func kept(_ queue: [ScheduledCommand], partition: TimerPartition) -> [ScheduledCommand] {
                queue.filter { entry in
                    guard let pause = timerPauseById[entry.id] else { return true }
                    if let index = paused.firstIndex(where: { $0.command.id == entry.id }) {
                        paused[index].originalPartition = partition
                    } else {
                        paused.append(PausedScheduledCommand(
                            command: entry, originalPartition: partition,
                            pausedCapabilities: [], pausedScopes: pause.scopes
                        ))
                    }
                    return false
                }
            }
            let waiting = kept(scheduledCommands, partition: .waiting)
            let missed = kept(missedScheduledCommands, partition: .missed)
            let foreign = kept(foreignScheduledCommands, partition: .foreign)
            for idx in paused.indices {
                guard let pause = timerPauseById[paused[idx].command.id] else { continue }
                paused[idx].pausedCapabilities = Set(paused[idx].pausedCapabilities).union(
                    pause.caps.isEmpty ? fallbackCapabilities : pause.caps
                ).sorted { $0.rawValue < $1.rawValue }
                paused[idx].pausedScopes = mergePausedScopes(existing: paused[idx].pausedScopes, adding: pause.scopes)
            }
            if commitScheduledCommands(waiting: waiting, missed: missed, foreign: foreign, paused: paused) {
                for id in timerPauseById.keys { disarmScheduledCommand(id) }
            }
        }

        if !rulePauseById.isEmpty {
            let store = AutomationRuleStore(defaults: userDefaults)
            var rules = store.load()
            var changed = false
            for idx in rules.indices {
                guard let pause = rulePauseById[rules[idx].id] else { continue }
                rules[idx].isEnabled = false
                rules[idx].pausedCapabilities = Array(
                    Set(rules[idx].pausedCapabilities + (pause.caps.isEmpty ? fallbackCapabilities : pause.caps))
                ).sorted { $0.rawValue < $1.rawValue }
                rules[idx].pausedScopes = mergePausedScopes(existing: rules[idx].pausedScopes, adding: pause.scopes)
                changed = true
            }
            if changed {
                store.save(rules)
                onAutomationRulesChanged?()
            }
        }

        if !quickActionScopes.isEmpty {
            pausedQuickActionIDs.formUnion(quickActionScopes.keys)
            for (id, scopes) in quickActionScopes {
                pausedQuickActionScopes[id] = mergePausedScopes(
                    existing: pausedQuickActionScopes[id] ?? [],
                    adding: scopes
                )
            }
            userDefaults.set(pausedQuickActionIDs.sorted(), forKey: Self.pausedQuickActionsKey)
            persistPausedQuickActionScopes()
        }
    }

    private func revalidationIsAuthoritative(_ snapshot: SynthesizedHome?) -> Bool {
        if let snapshot {
            guard snapshot.isInitialLoadComplete, snapshot.closesAwayGap else { return false }
            if hasEnabledHASource {
                if let haStatus = snapshot.sourceStatuses[.homeAssistant] ?? sourceStatuses[.homeAssistant] {
                    if !haStatus.isConnected { return false }
                } else if case .disconnected = connectionStatus {
                    return false
                }
                if let snapshotHAScope = snapshot.homeAssistantScope,
                   snapshotHAScope != homeAssistantScopeIdentifier {
                    return false
                }
            }
            for account in enabledMiAccounts {
                if snapshot.miAccountsEpoch != nil, snapshot.miAccountsEpoch != miAccountsConfigEpoch { return false }
                if let status = snapshot.accountStatuses[account.id], !status.isConnected { return false }
                if let home = selectedMiHomeId, !MiAccountScope.isOwned(home, by: account.id) { return false }
            }
            return true
        }
        guard hasReceivedInitialSnapshot, pendingRevalidationScopes.isEmpty else { return false }
        if hasEnabledHASource {
            if let haStatus = sourceStatuses[.homeAssistant] {
                if !haStatus.isConnected { return false }
            } else if case .disconnected = connectionStatus {
                return false
            }
        }
        for account in enabledMiAccounts {
            guard miAccountStatuses[account.id]?.isConnected == true else { return false }
            if let home = selectedMiHomeId, !MiAccountScope.isOwned(home, by: account.id) { return false }
        }
        return true
    }

    @discardableResult
    func revalidatePausedTimers(enabling: Bool = false) -> Bool {
        guard scheduledCommandsEnabled || enabling else { return true }
        if pausedScheduledCommands.isEmpty { return !enabling || commitScheduledCommands(enabled: true) }
        let indexed = currentIndexedDevicesList()
        let indexedById = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
        let sceneRefs = currentSceneReferences()
        let (groups, _) = loadDeviceGroupReferences()
        let now = assistantNow()
        let nowEpoch = Int(now.timeIntervalSince1970.rounded(.down))
        let activeScopes = activeConnectionScopes.filter { scope in
            guard let conn = CapabilityReferenceEngine.connectionCapability(forScope: scope) else { return true }
            return isCapabilityScopeConfigured(conn, scope: scope)
        }
        var stillPaused: [PausedScheduledCommand] = []
        var waiting = scheduledCommands
        var missed = missedScheduledCommands
        var foreign = foreignScheduledCommands
        var resumed: [ScheduledCommand] = []
        for paused in pausedScheduledCommands {
            let cmd = paused.command
            let hasCapabilityPause = !paused.requiresTimerRevalidation
                || !paused.pausedCapabilities.isEmpty || !paused.pausedScopes.isEmpty
            if hasCapabilityPause, !pausedItemScopesAreSettled(pausedTimerScopes(paused)) {
                stillPaused.append(paused)
                continue
            }
            let disposition: PausedTimerResumeDisposition
            if paused.requiresTimerRevalidation {
                let knownSource = cmd.effectiveSourceScopes != nil || timerTargetsAreAllLGLan(cmd.plan, indexedById: indexedById)
                // Foreign entries wait for their own home to return and pass the live checks.
                guard knownSource ? timerScopeMatches(cmd) : connectionScopeIdentifier != nil,
                      timerPlanCanResume(cmd.plan),
                      paused.pausedCapabilities.allSatisfy({ cap in
                          if case .connection = cap { return true } // The affected scopes were checked above.
                          return capabilitySelection.contains(cap)
                      }) else {
                    stillPaused.append(paused)
                    continue
                }
                disposition = knownSource && paused.originalPartition != .missed && cmd.fireDate > now
                    ? .armWaiting : .moveToMissed
            } else {
                let ref = makeTimerReference(
                    for: cmd, partition: paused.originalPartition,
                    pausedCapabilities: paused.pausedCapabilities, indexedById: indexedById
                )
                disposition = CapabilityReferenceEngine.revalidatePausedTimer(
                    timer: ref, fireAtEpochSeconds: Int(cmd.fireDate.timeIntervalSince1970.rounded(.down)),
                    nowEpochSeconds: nowEpoch, activeConnectionScopes: activeScopes,
                    selection: capabilitySelection, devices: indexed, scenes: sceneRefs, deviceGroups: groups
                )
            }
            switch disposition {
            case .keepPaused:
                stillPaused.append(paused)
            case .armWaiting:
                if !waiting.contains(where: { $0.id == cmd.id }) {
                    waiting.append(cmd)
                    resumed.append(cmd)
                }
            case .moveToMissed:
                if !missed.contains(where: { $0.id == cmd.id }) { missed.append(cmd) }
            case .partitionForeign:
                if !foreign.contains(where: { $0.id == cmd.id }) { foreign.append(cmd) }
            }
        }
        guard enabling || stillPaused != pausedScheduledCommands else { return true }
        let addedMissed = missed.count > missedScheduledCommands.count
        guard commitScheduledCommands(waiting: waiting, missed: missed, foreign: foreign, paused: stillPaused, enabled: true)
        else { return false }
        for cmd in resumed { startScheduledTask(for: cmd, delay: cmd.fireDate.timeIntervalSince(now)) }
        if addedMissed {
            isShowingAssistantBar = true
            notifyMissedScheduledCommandsIfNeeded()
        }
        return true
    }

    func revalidatePausedItems(snapshot: SynthesizedHome? = nil) {
        revalidatePausedTimers()
        let authoritative = revalidationIsAuthoritative(snapshot)
        let indexed = currentIndexedDevicesList()
        let indexedById = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
        let sceneRefs = currentSceneReferences()
        let (groups, _) = loadDeviceGroupReferences()
        let groupById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let ruleStore = AutomationRuleStore(defaults: userDefaults)
        var rules = ruleStore.load()
        var rulesChanged = false
        let availableSet = Set(CapabilityReferenceEngine.partitionDevices(
            devices: indexed, selection: capabilitySelection, safetyPolicy: effectiveSafetyRetentionPolicy()
        ).availableDeviceIds)

        for idx in rules.indices where !rules[idx].isEnabled
            && (!rules[idx].pausedCapabilities.isEmpty || !rules[idx].pausedScopes.isEmpty) {
            let scopes = rules[idx].pausedScopes
            let capabilities = rules[idx].pausedCapabilities
            guard !capabilities.contains(.connection(.homeAssistant)) || scopes.contains(where: { $0.hasPrefix("ha:") }),
                  pausedItemScopesAreSettled(scopes, requiresOriginalHA: true) else { continue }
            let capsSatisfied = capabilities.allSatisfy { cap in
                switch cap {
                case .connection(let conn): capabilitySelection.enabledConnections.contains(conn)
                case .feature, .deviceCategory: capabilitySelection.contains(cap)
                }
            }
            guard capsSatisfied else { continue }
            let canResume: Bool
            switch rules[idx].action {
            case .devices(let ids, _):
                let expanded = ids.flatMap { groupById[$0]?.memberDeviceIds ?? [$0] }
                canResume = !expanded.isEmpty && expanded.allSatisfy {
                    CapabilityReferenceEngine.evaluateControlTargetGate(
                        targetKind: .device, targetId: $0, selection: capabilitySelection, devices: indexed, scenes: sceneRefs
                    ).allowed
                }
                if authoritative, expanded.contains(where: { indexedById[$0] == nil }) {
                    rules[idx].pausedCapabilities = []
                    rules[idx].pausedScopes = []
                    rulesChanged = true
                }
            case .scene(let sceneId):
                canResume = CapabilityReferenceEngine.evaluateControlTargetGate(
                    targetKind: .scene, targetId: sceneId, selection: capabilitySelection, devices: indexed, scenes: sceneRefs
                ).allowed
                if authoritative, !sceneRefs.contains(where: { $0.id == sceneId }) {
                    rules[idx].pausedCapabilities = []
                    rules[idx].pausedScopes = []
                    rulesChanged = true
                }
            case .quickAction(let qa):
                let cats = (QuickActionReferenceKind(rawValue: qa.rawValue) ?? .lightsOff).targetCategories
                canResume = cats.allSatisfy(capabilitySelection.enabledCategories.contains)
                    && indexed.contains { availableSet.contains($0.id) && cats.contains($0.category) }
            }
            if canResume {
                rules[idx].isEnabled = true
                rules[idx].pausedCapabilities = []
                rules[idx].pausedScopes = []
                rulesChanged = true
            }
        }
        if rulesChanged {
            ruleStore.save(rules)
            onAutomationRulesChanged?()
        }

        if !pausedQuickActionIDs.isEmpty {
            var remainingQA: Set<String> = []
            for qaId in pausedQuickActionIDs {
                let isGroup = qaId.hasPrefix(Self.pausedQuickActionGroupIDPrefix)
                let scopes = pausedQuickActionScopes[qaId] ?? []
                guard (!isGroup || !scopes.isEmpty),
                      pausedItemScopesAreSettled(scopes, requiresOriginalHA: isGroup),
                      pausedQuickActionTargetsAreAvailable(
                          qaId, indexed: indexed, availableSet: availableSet, groupById: groupById
                      ) else {
                    remainingQA.insert(qaId)
                    continue
                }
            }
            if remainingQA != pausedQuickActionIDs {
                pausedQuickActionIDs = remainingQA
                pausedQuickActionScopes = pausedQuickActionScopes.filter { remainingQA.contains($0.key) }
                if remainingQA.isEmpty {
                    userDefaults.removeObject(forKey: Self.pausedQuickActionsKey)
                } else {
                    userDefaults.set(remainingQA.sorted(), forKey: Self.pausedQuickActionsKey)
                }
                persistPausedQuickActionScopes()
            }
        }
    }

    private func allowedDeactivationVerdict(for selection: CapabilitySelection) -> CapabilityDeactivationVerdict {
        let partition = CapabilityReferenceEngine.partitionDevices(
            devices: currentIndexedDevicesList(), selection: selection, safetyPolicy: effectiveSafetyRetentionPolicy()
        )
        return CapabilityDeactivationVerdict(
            disposition: .allowed, cascadedCapabilities: [], itemsToPause: [],
            softNotices: [], blockingReasons: [], preservedPreferenceDeviceIds: [], partition: partition
        )
    }
}
