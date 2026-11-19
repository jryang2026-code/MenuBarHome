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
    static let pausedQuickActionsKey = "paused_quick_actions_v1"
    static let pausedQuickActionScopesKey = "paused_quick_action_scopes_v1"

    private struct StoredDeviceGroupItem: Decodable {
        let id: String
        let name: String
    }

    // MARK: - Connection & Account Enablement Queries

    public func isMiAccountEnabled(_ accountId: String) -> Bool {
        capabilitySelection.enabledConnections.contains(.xiaomiCloud)
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

    var isHAConnectionEnabled: Bool {
        !hasHASource || capabilitySelection.isSourceEnabled(connection: .homeAssistant, scope: homeAssistantScopeIdentifier)
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
    }

    func configuredConnectionScopes() -> Set<String> {
        var scopes = Set(miAccounts.map(\.id))
        if scopes.isEmpty, let singleMi = miSessionScopeIdentifier { scopes.insert(singleMi) }
        if hasHASource { scopes.insert(homeAssistantScopeIdentifier) }
        return scopes
    }

    @discardableResult
    private func persistCapabilitySelection(removingScopes: Set<String> = []) -> Bool {
        CapabilitySelectionStore.save(
            selection: capabilitySelection,
            configuredScopes: configuredConnectionScopes(),
            explicitlyDisabledConnections: explicitlyDisabledConnections,
            removingScopes: removingScopes,
            defaults: userDefaults
        )
    }

    /// Commit order for a disable: the selection must be writable before any reference is paused, or
    /// a refused write would leave paused timers and rules behind for an account that stays enabled (M2).
    private func canPersistCapabilitySelection() -> Bool {
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
            let next = proposedSelectionForMiAccount(id: id, enabled: true).normalized(with: .shared)
            guard next != capabilitySelection else { return allowedDeactivationVerdict(for: capabilitySelection) }
            explicitlyDisabledConnections.remove(.xiaomiCloud)
            explicitlyDisabledScopes.remove(id)
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
        if !verdict.itemsToPause.isEmpty { pauseAffectedReferences(verdict.itemsToPause) }
        pendingRevalidationScopes.remove(id)
        explicitlyDisabledScopes.insert(id)
        capabilitySelection = proposed.normalized(with: .shared)
        capabilityGeneration &+= 1
        persistCapabilitySelection()
        applyMiAccountDisabledRuntimeState(id: id)
        return verdict
    }

    func registerNewlyConfiguredScope(_ scope: String, connection: ConnectionCapabilityID) {
        // A scope the user had explicitly turned off and now re-enables (a second QR scan, or
        // connecting the same account again) still owns the paused timers, rules and quick actions
        // recorded before, so it has to go through the same fresh-snapshot revalidation as
        // `setMiAccountEnabled(true, ...)`. Without that the pause markers survive forever.
        explicitlyDisabledConnections.remove(connection)
        explicitlyDisabledScopes.remove(scope)
        var next = capabilitySelection
        next.enabledConnections.insert(connection)
        next.enabledConnectionScopes.insert(scope)
        capabilitySelection = next.normalized(with: .shared)
        capabilityGeneration &+= 1
        // Always wait for this scope's first fresh snapshot before deciding about paused items: it may
        // be a re-added account whose paused quick actions lost their targets when it was removed, and
        // that removal already cleared the explicit-disable marker this check used to look at.
        pendingRevalidationScopes.insert(scope)
        persistCapabilitySelection()
    }

    /// Carries the Home Assistant scope over when the saved address changes. The stored selection
    /// names addresses, so without this the freshly accepted address is absent from
    /// `enabledConnectionScopes`: `isHAConnectionEnabled` reads false and the next write records the
    /// new address as explicitly disabled (H1).
    func migrateHomeAssistantScope(from oldServerURL: String) {
        let oldScope = "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(oldServerURL))"
        let newScope = homeAssistantScopeIdentifier
        guard oldScope != newScope else { return }
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

    private func blockedSelectionVerdict(proposed: CapabilitySelection, storeKey: String) -> CapabilityDeactivationVerdict {
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

    /// A paired card copies the Xiaomi `accountId` even when Home Assistant drives it (ADR-0008).
    /// Only rows the Mi account actually controls may be torn down or hidden with it.
    private func isMiOwnedRow(_ device: SmartDevice, accountId: String) -> Bool {
        device.accountId == accountId && deviceBackends[device.id] != .homeAssistant
    }

    private func applyMiAccountDisabledRuntimeState(id: String) {
        invalidateUndoContext()
        var disabledDeviceIds = Set(devices.filter { isMiOwnedRow($0, accountId: id) }.map(\.id))
        for (devId, indexed) in indexedDevicesById where indexed.sourceScope == id {
            disabledDeviceIds.insert(devId)
        }
        miAccountStatuses.removeValue(forKey: id)
        miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
        if !hasEnabledMiSource {
            isShowingMiReauth = false
            localNetworkBlocks.remove(.xiaomiLAN)
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
        devices.removeAll { disabledDeviceIds.contains($0.id) || isMiOwnedRow($0, accountId: id) }
        environmentReadings.removeAll { disabledDeviceIds.contains($0.id) }
        rooms.removeAll { MiAccountScope.isOwned($0.id, by: id) }
        homes.removeAll { $0.accountId == id }
        if let roomId = selectedRoomId, MiAccountScope.isOwned(roomId, by: id) { selectRoom(nil) }

        onMiAccountDisabled?(id, disabledDeviceIds)

        if provider is DualSourceHomeProvider || provider is MiAccountsProvider {
            rebuildLiveProvider()
            if activeBackends.isEmpty {
                connectionStatus = .disconnected(L10n.tr("连接已停用", "Connection turned off"))
                connectedBackends = []
                sourceStatuses = [:]
            }
        } else {
            syncHistoryConnectionScopes()
            syncScheduledCommandScopeIfNeeded()
        }
    }

    // MARK: - Host Control Write Gate

    public func evaluateDeviceControlGate(deviceId: String, expectedGeneration: Int? = nil) -> ControlTargetGateVerdict {
        CapabilityReferenceEngine.evaluateControlTargetGate(
            targetKind: .device, targetId: deviceId, expectedGeneration: expectedGeneration,
            currentGeneration: capabilityGeneration, selection: capabilitySelection,
            devices: currentIndexedDevicesList(), scenes: currentSceneReferences()
        )
    }

    public func evaluateSceneControlGate(sceneId: String, expectedGeneration: Int? = nil) -> ControlTargetGateVerdict {
        CapabilityReferenceEngine.evaluateControlTargetGate(
            targetKind: .scene, targetId: sceneId, expectedGeneration: expectedGeneration,
            currentGeneration: capabilityGeneration, selection: capabilitySelection,
            devices: currentIndexedDevicesList(), scenes: currentSceneReferences()
        )
    }

    /// Capability rejection for a command target, resolved from the live rows as well as the persisted
    /// index. A stale index entry must not let a command slip past the gate that the panel applies
    /// (Bugbot #275: write gate skipped without index entry).
    func capabilityWriteRejection(forDeviceId deviceId: String) -> ControlTargetRejectionReason? {
        guard resolvedIndexedDevice(for: deviceId) != nil else { return nil }
        let verdict = evaluateDeviceControlGate(deviceId: deviceId)
        return verdict.allowed ? nil : verdict.rejectionReason
    }

    @discardableResult
    func rejectDeviceWriteIfCapabilityDisabled(deviceId: String) -> ControlTargetRejectionReason? {
        guard let indexed = resolvedIndexedDevice(for: deviceId),
              indexed.connection != nil || !capabilitySelection.enabledCategories.contains(indexed.category) else { return nil }
        let verdict = evaluateDeviceControlGate(deviceId: deviceId)
        guard !verdict.allowed, let reason = verdict.rejectionReason else { return nil }
        showToast(reason.userMessage, isError: true)
        return reason
    }

    func owningDeviceIdForCommand(_ command: DeviceCommand) -> String? {
        let entityId = command.targetEntityId
        if LGWebOSProtocol.isLGEntity(entityId) { return LGWebOSProtocol.deviceId }
        if let live = devices.first(where: { $0.referencedEntityIds.contains(entityId) }) { return live.id }
        if let parsed = MiotAddress.parse(entityId) {
            if indexedDevicesById[parsed.did] != nil { return parsed.did }
            let splitId = "\(parsed.did).s\(parsed.siid)"
            if indexedDevicesById[splitId] != nil { return splitId }
            return parsed.did
        }
        return nil
    }

    // MARK: - Device Indexing & Reference Graph

    func loadPersistedCapabilityState() {
        if let data = userDefaults.data(forKey: Self.capabilityDeviceIndexKey),
           let decoded = try? JSONDecoder().decode([String: CapabilityIndexedDevice].self, from: data) {
            indexedDevicesById = decoded
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
            || rules.contains { !$0.pausedCapabilities.isEmpty }
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
    }

    func shouldSuppressMiAccountInSnapshot(_ accountId: String, snapshotEpoch: Int?) -> Bool {
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
        var completedScopes: Set<String> = []
        for scope in pendingRevalidationScopes {
            // Covers every connection kind: a Mi account the user turned off again, or a Home
            // Assistant address that is no longer enabled, needs no revalidation anymore.
            if !capabilitySelection.isSourceEnabled(connection: nil, scope: scope) {
                completedScopes.insert(scope)
                continue
            }
            let accountReady: Bool
            if CapabilityReferenceEngine.connectionCapability(forScope: scope) != .xiaomiCloud {
                // No Mi account owns this scope (a Home Assistant address, or a LAN source): the
                // Mi-only freshness signals below can never name it, so its first complete snapshot is
                // the authority instead.
                accountReady = snapshot.isInitialLoadComplete
            } else if selectedHomeHidesScope(scope) {
                // Another account's home is selected, so this child intentionally hides its devices.
                // A connected, fresh snapshot is not an inventory of the account in that state.
                accountReady = false
            } else if activeMiAccountsProvider != nil || snapshot.miAccountsEpoch != nil {
                // A buffered pre-rebuild snapshot, or one whose account never connected (expired
                // session, failed refresh), proves nothing about that account's targets (H3).
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
            completedScopes.insert(scope)
        }
        guard !completedScopes.isEmpty else { return }
        pendingRevalidationScopes.subtract(completedScopes)
        revalidatePausedItems(snapshot: snapshot)
    }

    /// True while another account's Mi home is selected: the provider hides this account's devices
    /// even when it polls fine, so its snapshot cannot prove anything about them.
    private func selectedHomeHidesScope(_ scope: String) -> Bool {
        guard CapabilityReferenceEngine.connectionCapability(forScope: scope) == .xiaomiCloud,
              let home = selectedMiHomeId, let owner = MiAccountScope.owner(of: home) else { return false }
        return owner != scope
    }

    /// The scope still exists in the user's configuration, whether or not it is turned on.
    private func isCapabilityScopeConfigured(_ connection: ConnectionCapabilityID, scope: String) -> Bool {
        switch connection {
        case .xiaomiCloud:
            return miAccounts.isEmpty ? miSessionScopeIdentifier == scope : miAccounts.contains { $0.id == scope }
        case .homeAssistant:
            return hasHASource && homeAssistantScopeIdentifier == scope
        }
    }

    /// One rule for every paused reference (timer, automation, quick action): only the scopes it
    /// actually lost decide when it may resume. A scope that is still enabled but waiting for its
    /// first fresh snapshot keeps the item paused, and so does a scope the user turned off. A scope
    /// that is no longer configured needs no snapshot at all: the item moves on through the normal
    /// missing/foreign flow. Nothing here looks at *other* accounts.
    private func pausedItemScopesAreSettled(_ scopes: [String]) -> Bool {
        scopes.allSatisfy { scope in
            guard let connection = CapabilityReferenceEngine.connectionCapability(forScope: scope) else { return true }
            guard isCapabilityScopeConfigured(connection, scope: scope) else { return true }
            return capabilitySelection.isSourceEnabled(connection: connection, scope: scope)
                && !pendingRevalidationScopes.contains(scope)
        }
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

    private func currentIndexedDevicesList() -> [CapabilityIndexedDevice] {
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
        // A paired card copies the Xiaomi `accountId` from either side, while `deviceBackends` records
        // which backend actually drives it (ADR-0008). Reading `accountId` first would classify an
        // HA-controlled card as a Mi target and pause its references when that account is disabled.
        // Only a source the host manages carries a capability scope; a provider injected by a test or
        // older launch has none and keeps the pre-P2a write path.
        switch deviceBackends[device.id] {
        case .homeAssistant where hasHASource:
            return (.homeAssistant, homeAssistantScopeIdentifier)
        case .xiaomiCloud where !miAccounts.isEmpty || hasMiSource:
            if let accountId = device.accountId, !accountId.isEmpty { return (.xiaomiCloud, accountId) }
            if let scope = enabledMiAccounts.first?.id ?? miSessionScopeIdentifier { return (.xiaomiCloud, scope) }
        case .demo:
            return (nil, "demo")
        default:
            break
        }
        if homeBackend == .demo { return (nil, "demo") }
        if let accountId = device.accountId, !accountId.isEmpty { return (.xiaomiCloud, accountId) }
        if hasHASource && (homeBackend == .homeAssistant || activeHAProvider != nil) {
            return (.homeAssistant, homeAssistantScopeIdentifier)
        }
        return (nil, "local")
    }

    private func isScopeConfiguredAndAvailable(connection: ConnectionCapabilityID?, scope: String) -> Bool {
        switch connection ?? CapabilityReferenceEngine.connectionCapability(forScope: scope) {
        case .xiaomiCloud:
            return !miAccounts.isEmpty ? miAccounts.contains { $0.id == scope } : (miSessionScopeIdentifier == scope)
        case .homeAssistant:
            return hasHASource && homeAssistantScopeIdentifier == scope
        case nil:
            return true
        }
    }

    private func safetySignals(for device: SmartDevice) -> Set<SafetySignalKind> {
        var signals: Set<SafetySignalKind> = [.starredOffline]
        switch device.kind {
        case .plug: signals.formUnion([.longRunningPlug, .highPower])
        case .climate: signals.insert(.longRunningClimate)
        case .camera: signals.insert(.doorbell)
        case .sensor(let spec) where spec.battery != nil: signals.insert(.lowBattery)
        default: break
        }
        return signals
    }

    private func currentSafetyRetentionPolicy() -> SafetyRetentionPolicy {
        guard enableSafetyAlerts else { return SafetyRetentionPolicy() }
        var enabled: Set<SafetySignalKind> = [.lowBattery, .longRunningPlug, .longRunningClimate, .highPower, .starredOffline]
        for kind in SensorAlertKind.allCases where sensorAlertPreferences[kind] ?? true {
            enabled.insert(SafetySignalKind(sensorAlertKind: kind))
        }
        if doorbellAutoPopup || doorbellChime { enabled.insert(.doorbell) }
        return SafetyRetentionPolicy(enabledSignals: enabled, starredDeviceIds: favoriteDeviceIds)
    }

    private func currentSceneReferences() -> [SceneReference] {
        scenes.map { scene in
            let conn: ConnectionCapabilityID? = hasHASource ? .homeAssistant : nil
            let scope = hasHASource ? homeAssistantScopeIdentifier : (homeBackend == .demo ? "demo" : "local")
            return SceneReference(
                id: scene.id, name: scene.name, connection: conn, sourceScope: scope,
                isSourceAvailable: isScopeConfiguredAndAvailable(connection: conn, scope: scope)
            )
        }
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

    private func evaluateCapabilityDeactivation(
        proposed: CapabilitySelection,
        expectedGeneration: Int?
    ) -> CapabilityDeactivationVerdict {
        let indexed = currentIndexedDevicesList()
        let graph = buildCapabilityReferenceGraph(indexedDevices: indexed, expectedGeneration: expectedGeneration)
        return CapabilityReferenceEngine.evaluateDeactivation(
            current: capabilitySelection, proposed: proposed, manifest: .shared,
            devices: indexed, safetyPolicy: currentSafetyRetentionPolicy(), references: graph
        )
    }

    private func buildCapabilityReferenceGraph(
        indexedDevices: [CapabilityIndexedDevice],
        expectedGeneration: Int?
    ) -> CapabilityReferenceGraph {
        var corrupted: [String] = []
        let indexedById = Dictionary(uniqueKeysWithValues: indexedDevices.map { ($0.id, $0) })
        let timers = scheduledCommands.map { makeTimerReference(for: $0, partition: .waiting, indexedById: indexedById) }
            + missedScheduledCommands.map { makeTimerReference(for: $0, partition: .missed, indexedById: indexedById) }
            + foreignScheduledCommands.map { makeTimerReference(for: $0, partition: .foreign, indexedById: indexedById) }

        if let rawRulesData = userDefaults.data(forKey: AutomationRuleStore.storageKey),
           (try? JSONSerialization.jsonObject(with: rawRulesData) as? [Any]) == nil {
            corrupted.append(AutomationRuleStore.storageKey)
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
                if hasHASource { scopes.insert(homeAssistantScopeIdentifier) }
            case .quickAction(let qa):
                refAction = .quickAction(QuickActionReferenceKind(rawValue: qa.rawValue) ?? .lightsOff)
            }
            if scopes.isEmpty { scopes = configuredConnectionScopes() }
            let summary = "\(rule.trigger.title) · \(rule.action.summary(devices: devices, scenes: scenes))"
            return AutomationReference(
                // A paused rule is inspected too: another disable can take away more of its targets,
                // and its pause markers have to grow instead of being resumed by the first account
                // that comes back (review #275).
                id: rule.id.uuidString, name: summary,
                isEnabled: rule.isEnabled || !rule.pausedCapabilities.isEmpty,
                action: refAction, sourceScopes: scopes.sorted()
            )
        }

        // Custom layout groups only expand timer and rule targets; they are not quick actions of their
        // own, and a damaged group preference must not block turning a connection off (M4).
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
            scenes: currentSceneReferences(), deviceGroups: groups,
            preferences: .fromUserDefaults(userDefaults), corruptedStoreReasons: corrupted,
            expectedGeneration: expectedGeneration, currentGeneration: capabilityGeneration
        )
    }

    // MARK: - Pause & Re-Enable Revalidation

    private func pauseAffectedReferences(_ items: [AffectedReferenceItem]) {
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
            func extractPaused(from list: inout [ScheduledCommand], partition: TimerPartition) {
                var kept: [ScheduledCommand] = []
                for entry in list {
                    if let pause = timerPauseById[entry.id] {
                        scheduledTasks.removeValue(forKey: entry.id)?.cancel()
                        scheduledTaskTokens.removeValue(forKey: entry.id)
                        notifiedMissedTimerIds.remove(entry.id)
                        pausedScheduledCommands.append(
                            PausedScheduledCommand(
                                command: entry, originalPartition: partition,
                                pausedCapabilities: pause.caps, pausedScopes: pause.scopes
                            )
                        )
                    } else {
                        kept.append(entry)
                    }
                }
                list = kept
            }
            extractPaused(from: &scheduledCommands, partition: .waiting)
            extractPaused(from: &missedScheduledCommands, partition: .missed)
            extractPaused(from: &foreignScheduledCommands, partition: .foreign)
            PausedScheduledCommand.save(pausedScheduledCommands, to: userDefaults)
            persistScheduledCommandsFromCapabilities()
        }

        if !rulePauseById.isEmpty {
            let store = AutomationRuleStore(defaults: userDefaults)
            var rules = store.load()
            var changed = false
            for idx in rules.indices {
                // Already-paused rules merge the newly lost scopes instead of being skipped.
                guard let pause = rulePauseById[rules[idx].id] else { continue }
                rules[idx].isEnabled = false
                rules[idx].pausedCapabilities = Array(
                    Set(rules[idx].pausedCapabilities + (pause.caps.isEmpty ? [.connection(.xiaomiCloud)] : pause.caps))
                ).sorted { $0.rawValue < $1.rawValue }
                // Which scopes were lost, not just which connection: with lights on two accounts,
                // turning the surviving one off and on again must not resume this rule while the
                // account that owned the missing targets stays disabled.
                rules[idx].pausedScopes = Array(Set(rules[idx].pausedScopes + pause.scopes)).sorted()
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
                pausedQuickActionScopes[id] = Array(Set(pausedQuickActionScopes[id] ?? []).union(scopes)).sorted()
            }
            userDefaults.set(pausedQuickActionIDs.sorted(), forKey: Self.pausedQuickActionsKey)
            persistPausedQuickActionScopes()
        }
    }

    /// Whether the state on screen can prove a target no longer exists. A disconnected or expired
    /// account, a buffered pre-rebuild snapshot, a still-pending fresh snapshot, or another account's
    /// selected home (which hides the other accounts' devices) all look like "target gone" without
    /// being one, so they must never clear a pause marker (H3).
    private func revalidationIsAuthoritative(_ snapshot: SynthesizedHome?) -> Bool {
        if let snapshot {
            guard snapshot.isInitialLoadComplete, snapshot.closesAwayGap else { return false }
            for account in enabledMiAccounts {
                if snapshot.miAccountsEpoch != nil, snapshot.miAccountsEpoch != miAccountsConfigEpoch { return false }
                if let status = snapshot.accountStatuses[account.id], !status.isConnected { return false }
                if let home = selectedMiHomeId, !MiAccountScope.isOwned(home, by: account.id) { return false }
            }
            return true
        }
        guard hasReceivedInitialSnapshot, pendingRevalidationScopes.isEmpty else { return false }
        for account in enabledMiAccounts {
            guard miAccountStatuses[account.id]?.isConnected == true else { return false }
            if let home = selectedMiHomeId, !MiAccountScope.isOwned(home, by: account.id) { return false }
        }
        return true
    }

    func revalidatePausedItems(snapshot: SynthesizedHome? = nil) {
        let authoritative = revalidationIsAuthoritative(snapshot)
        let indexed = currentIndexedDevicesList()
        let indexedById = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
        let sceneRefs = currentSceneReferences()
        let (groups, _) = loadDeviceGroupReferences()
        let groupById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let now = assistantNow()
        let nowEpoch = Int(now.timeIntervalSince1970.rounded(.down))

        if !pausedScheduledCommands.isEmpty {
            var stillPaused: [PausedScheduledCommand] = []
            var timersChanged = false
            for paused in pausedScheduledCommands {
                if !pausedItemScopesAreSettled(pausedTimerScopes(paused)) {
                    stillPaused.append(paused)
                    continue
                }
                let cmd = paused.command
                let ref = makeTimerReference(
                    for: cmd, partition: paused.originalPartition,
                    pausedCapabilities: paused.pausedCapabilities, indexedById: indexedById
                )
                let disposition = CapabilityReferenceEngine.revalidatePausedTimer(
                    timer: ref, fireAtEpochSeconds: Int(cmd.fireDate.timeIntervalSince1970.rounded(.down)),
                    nowEpochSeconds: nowEpoch, activeConnectionScopes: activeConnectionScopes,
                    selection: capabilitySelection, devices: indexed, scenes: sceneRefs, deviceGroups: groups
                )
                switch disposition {
                case .keepPaused:
                    stillPaused.append(paused)
                case .armWaiting:
                    timersChanged = true
                    if !scheduledCommands.contains(where: { $0.id == cmd.id }) {
                        scheduledCommands.append(cmd)
                        scheduledCommands.sort { $0.fireDate < $1.fireDate }
                        startScheduledTaskFromCapabilities(for: cmd, delay: cmd.fireDate.timeIntervalSince(now))
                    }
                case .moveToMissed:
                    timersChanged = true
                    if !missedScheduledCommands.contains(where: { $0.id == cmd.id }) {
                        missedScheduledCommands.append(cmd)
                        missedScheduledCommands.sort { $0.fireDate < $1.fireDate }
                    }
                case .partitionForeign:
                    timersChanged = true
                    if !foreignScheduledCommands.contains(where: { $0.id == cmd.id }) {
                        foreignScheduledCommands.append(cmd)
                        foreignScheduledCommands.sort { $0.fireDate < $1.fireDate }
                    }
                }
            }
            if stillPaused != pausedScheduledCommands {
                pausedScheduledCommands = stillPaused
                PausedScheduledCommand.save(pausedScheduledCommands, to: userDefaults)
            }
            if timersChanged {
                if !missedScheduledCommands.isEmpty {
                    isShowingAssistantBar = true
                    notifyMissedScheduledCommandsIfNeeded()
                }
                persistScheduledCommandsFromCapabilities()
            }
        }

        let ruleStore = AutomationRuleStore(defaults: userDefaults)
        var rules = ruleStore.load()
        var rulesChanged = false
        let availableSet = Set(CapabilityReferenceEngine.partitionDevices(
            devices: indexed, selection: capabilitySelection, safetyPolicy: currentSafetyRetentionPolicy()
        ).availableDeviceIds)

        for idx in rules.indices where !rules[idx].isEnabled
            && (!rules[idx].pausedCapabilities.isEmpty || !rules[idx].pausedScopes.isEmpty) {
            // The scopes the rule lost have to be back and settled before it may run again; a
            // different surviving account supplying one target is not the same thing.
            guard pausedItemScopesAreSettled(rules[idx].pausedScopes) else { continue }
            let capsSatisfied = rules[idx].pausedCapabilities.allSatisfy { cap in
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
                // Only an authoritative snapshot may turn "targets are missing" into "this rule is no
                // longer paused". A failed refresh must leave the markers so a reconnect retries.
                if authoritative, expanded.contains(where: { indexedById[$0] == nil }) {
                    rules[idx].pausedCapabilities = []
                    rules[idx].pausedScopes = []
                    rulesChanged = true
                }
            case .scene(let sceneId):
                canResume = CapabilityReferenceEngine.evaluateControlTargetGate(
                    targetKind: .scene, targetId: sceneId, selection: capabilitySelection, devices: indexed, scenes: sceneRefs
                ).allowed
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
                // Same per-item rule: a quick action resumes only once the scopes it lost are settled.
                guard pausedItemScopesAreSettled(pausedQuickActionScopes[qaId] ?? []) else {
                    remainingQA.insert(qaId)
                    continue
                }
                if qaId.hasPrefix("group:") {
                    let grpId = String(qaId.dropFirst("group:".count))
                    guard let grp = groupById[grpId], !grp.memberDeviceIds.isEmpty,
                          grp.memberDeviceIds.allSatisfy(availableSet.contains) else {
                        remainingQA.insert(qaId)
                        continue
                    }
                } else if let kind = QuickActionReferenceKind(rawValue: qaId) {
                    let cats = kind.targetCategories
                    guard cats.allSatisfy(capabilitySelection.enabledCategories.contains),
                          indexed.contains(where: { availableSet.contains($0.id) && cats.contains($0.category) }) else {
                        remainingQA.insert(qaId)
                        continue
                    }
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
            devices: currentIndexedDevicesList(), selection: selection, safetyPolicy: currentSafetyRetentionPolicy()
        )
        return CapabilityDeactivationVerdict(
            disposition: .allowed, cascadedCapabilities: [], itemsToPause: [],
            softNotices: [], blockingReasons: [], preservedPreferenceDeviceIds: [], partition: partition
        )
    }
}
