import Foundation

// Backend connections, discovery, provider events, device naming and polling rhythm (#48).
extension HomeStore {
    // MARK: - Backend Summary

    public var serverHostSummary: String {
        let _ = effectiveLanguage
        if homeBackend == .demo {
            return L10n.tr("演示模式（虚拟设备）", "Demo Mode (Virtual Devices)")
        }
        let haHost = URL(string: serverURLString)?.host()
            ?? serverURLString
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        let miSummary: String = if miAccounts.count > 1 {
            L10n.tr(
                "米家云端 (\(miAccounts.count) 个账号)",
                "Xiaomi Cloud (\(miAccounts.count) accounts)"
            )
        } else if let masked = miSessionMaskedUserId {
            L10n.tr("米家云端 (\(masked))", "Xiaomi Cloud (\(masked))")
        } else {
            L10n.tr("米家云端 (未登录)", "Xiaomi Cloud (Signed Out)")
        }
        if hasEnabledHASource && hasEnabledMiSource {
            return "Home Assistant (\(haHost)) + \(miSummary)"
        }
        if hasEnabledMiSource {
            return miSummary
        }
        if hasEnabledHASource {
            return haHost
        }
        if allConfiguredSourcesTurnedOff {
            return L10n.tr("连接已停用", "Connections turned off")
        }
        if homeBackend == .xiaomiCloud {
            return miSummary
        }
        return haHost
    }

    // MARK: - LG TV & Provider Events

    func startLGWebOSIfNeeded(startImmediately: Bool = true) {
        guard homeBackend != .demo, !isIdentityUncertain else { return }
        let trustStore: LGCertificateTrust = if let credentialVault {
            LGCertificateTrust(vault: credentialVault)
        } else if userDefaults !== UserDefaults.standard {
            LGCertificateTrust(defaults: userDefaults)
        } else {
            .shared
        }
        let clientID = UUID()
        let client = LGWebOSClient(
            config: lgConfig,
            trustStore: trustStore,
            onDeviceUpdated: { [weak self] dev in
                Task { @MainActor [weak self] in
                    self?.applyLGDeviceUpdate(dev, fromClientID: clientID)
                }
            },
            onClientKeyRegistered: { [weak self] key in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The pairing only counts once the key is actually in the Keychain (#7);
                    // `applyLGClientKey` owns both the success toast and the error.
                    self.applyLGClientKey(key, fromClientID: clientID)
                }
            },
            onSecurityFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.applyLGSecurityFailure(message, fromClientID: clientID)
                }
            },
            connectionOverrideForTesting: lgWebOSConnectionOverrideForTesting
        )
        let previousLG = self.lgWebOSClient
        if let previousLG {
            Task { await previousLG.shutdown() }
        }
        self.lgWebOSClient = client
        self.lgWebOSClientID = clientID
        let currentPollingContext = pollingContext
        if startImmediately && !shouldSuppressBackgroundNetworkWork && lgConfig.isEnabled && lgConfig.hasConfiguredHost {
            Task {
                await client.setPollingContext(currentPollingContext)
                await client.start()
            }
        }
    }

    func applyLGSecurityFailure(_ message: String, fromClientID clientID: UUID? = nil) {
        if let clientID {
            guard !isResumeShutdown, homeBackend != .demo, clientID == lgWebOSClientID else { return }
        }
        showToast(message, isError: true)
    }

    /// Applies a freshly registered LG pairing key. Returns false when the Keychain refused to store it,
    /// rolling the live client back to the persisted `lgConfig` so client and store never diverge and the
    /// caller never sees a "Paired" toast for a key that will be gone after relaunch (#7).
    @discardableResult
    func applyLGClientKey(_ key: String, fromClientID clientID: UUID? = nil) -> Bool {
        if let clientID {
            guard !isResumeShutdown, homeBackend != .demo, clientID == lgWebOSClientID else { return false }
            // A key registered by the connection a trust reset is discarding must not restore trust (#262).
            guard !lgTrustResetInFlight else { return false }
        }
        var updated = lgConfig
        updated.clientKey = key
        // Write before swapping the in-memory config so a refused write keeps the old pairing key.
        guard updated.save(to: userDefaults, vault: credentialVault) else {
            lgConfigSaveFailed = true
            let persistedConfig = lgConfig
            if let lgClient = lgWebOSClient {
                Task { await lgClient.updateConfig(persistedConfig) }
            }
            showToast(
                L10n.tr(
                    "电视已确认配对，但配对密钥无法写入钥匙串；请授权钥匙串访问后重新配对",
                    "The TV confirmed pairing, but the key could not be saved to Keychain; allow access and pair again"
                ),
                isError: true
            )
            return false
        }
        lgConfigSaveFailed = false
        suppressNextLGConfigDidSetSave = true
        defer { suppressNextLGConfigDidSetSave = false }
        lgConfig = updated
        showToast(L10n.tr("已成功配对 \(lgConfig.name)", "Paired with \(lgConfig.name)"))
        return true
    }

    func applyLGDeviceUpdate(_ dev: SmartDevice, fromClientID clientID: UUID? = nil, favoritesNewCard: Bool = true) {
        if let clientID {
            guard !isResumeShutdown, clientID == lgWebOSClientID else { return }
        }
        // Demo mode never shows the LAN TV tile (#47), and a disabled or unconfigured TV drops it too.
        guard homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost else {
            latestLGDevice = nil
            lastReportedDevices.removeValue(forKey: dev.id)
            devices.removeAll { $0.id == dev.id }
            return
        }
        // A closed TV type drops the card but keeps the report, so reopening the type restores it (#342).
        guard capabilitySelection.enabledCategories.contains(.tv) else {
            latestLGDevice = dev
            lastReportedDevices.removeValue(forKey: dev.id)
            devices.removeAll { $0.id == dev.id }
            return
        }
        var dev = dev
        if let matchedRoom = rooms.first(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            dev.roomId = matchedRoom.id
        }
        latestLGDevice = dev
        rawDeviceNames[dev.id] = dev.name
        lastReportedDevices[dev.id] = dev
        let now = optimisticNow()
        pruneExpiredOptimisticLocks(for: dev.id, at: now)
        let lockedFields = activeLockedFields(for: dev.id, at: now)
        let nextDev: SmartDevice
        if !lockedFields.isEmpty, let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            nextDev = dev.mergingOptimisticFields(from: devices[idx], lockedFields: lockedFields)
        } else {
            nextDev = dev
        }
        if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[idx] = nextDev
        } else {
            devices.append(nextDev)
            if favoritesNewCard, favoriteDeviceIds.contains(dev.id) == false, favoriteOrder.count < 8 {
                favoriteDeviceIds.insert(dev.id)
                favoriteOrder.insert(dev.id, at: 0)
            }
        }
        applyDeviceAliases()
        if !rooms.contains(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            rooms.append(RoomArea(id: dev.roomId, name: dev.roomName, sortOrder: 1))
        }
        if dev.isOnline, pausedScheduledCommands.contains(where: \.requiresTimerRevalidation) {
            revalidatePausedTimers()
        }
    }

    public func startListening() {
        hasReceivedInitialSnapshot = false
        connectedBackends = []
        deviceBackends = [:]
        deviceTransportDiagnostics = [:]
        localNetworkBlocks = []
        // The new provider owns the read plan from scratch: the previous connection's retained
        // safety set must not outlive it, and this connection refills it on its first snapshot.
        clearMiotTypePruneReports()
        syncMiotTypePrunePolicy()
        // The devices on screen belong to the previous connection until the next snapshot lands;
        // scheduling refuses that window instead of stamping a stale list with the new sources.
        listeningSnapshotGeneration = snapshotGeneration
        eventTask?.cancel()
        let pendingShutdown = providerShutdownTask
        let stream = provider.events()
        eventTask = Task { [weak self] in
            await pendingShutdown?.value
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleProviderEvent(event)
            }
        }
        // Stamped first, then handed to the new provider: a bare `PollingContext()` default would
        // keep 60 s forever and never learn the idle clock or the decay gates.
        refreshPollingContext()
        pushPollingContext()
        // The provider swap has taken effect here, which is the only point where the new connection
        // scope is final. `invalidateUndoContext()` runs before `homeBackend` and the sessions change,
        // so it cannot decide which source now owns the timers.
        syncScheduledCommandScopeIfNeeded()
    }

    public func waitForInitialSnapshot(timeout: Duration = .seconds(4)) async throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasReceivedInitialSnapshot {
            guard ContinuousClock.now < deadline else {
                throw HomeProviderError.networkError(L10n.tr(
                    "家居数据尚未加载，请稍后重试",
                    "Home data has not loaded yet. Try again shortly."
                ))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Polling Rhythm (#26)

    /// The control center panel opened or closed.
    public func setPanelVisible(_ visible: Bool) {
        // Opening or closing the panel is the user touching it: the idle clock that stretches the
        // closed-panel interval restarts here, so the stretch never covers a moment the user is here.
        lastPanelInteractionAt = Date()
        updatePollingContext { $0.panelVisible = visible }
    }

    /// False while the Mac or display sleeps, the screen is locked, or another user is active.
    public func setSystemActive(_ active: Bool) {
        if !active { recordSystemAway() }
        updatePollingContext { $0.systemActive = active }
    }

    public func setHATransportSuspended(_ suspended: Bool, topologyChanged: Bool, systemActive: Bool? = nil) {
        if systemActive == false { recordSystemAway() }
        updatePollingContext {
            if let systemActive { $0.systemActive = systemActive }
            $0.haTransportSuspended = suspended
            if topologyChanged { $0.haTransportRevision &+= 1 }
        }
    }

    private func recordSystemAway() {
        awayGap.includesAway = true
        userDefaults.set(true, forKey: MacAwayGap.storageKey)
    }

    func finishPresenceSnapshot() {
        guard pollingContext.systemActive, awayGap.includesAway else { return }
        awayGap.includesAway = false
        userDefaults.set(false, forKey: MacAwayGap.storageKey)
    }

    public func setLowPowerMode(_ enabled: Bool) {
        updatePollingContext { $0.lowPower = enabled }
    }

    private func updatePollingContext(_ change: (inout PollingContext) -> Void) {
        var next = pollingContext
        change(&next)
        // The idle clock and the two decay gates are derived inputs: stamp them on every change so a
        // caller can never push a context that decays while a poll still feeds a safety alert or a
        // live menu-bar reading.
        next.lastPanelInteractionAt = lastPanelInteractionAt
        next.safetyAlertsRelyOnPolling = safetyAlertsRelyOnPolling
        next.menuBarShowsLiveReading = menuBarShowsLiveReading
        guard next != pollingContext else { return }
        pollingContext = next
        pushPollingContext()
    }

    /// Re-derives the context after a preference that decides one of its decay inputs changes, and
    /// hands a fresh provider the stamped context instead of the bare `PollingContext()` default.
    func refreshPollingContext() {
        updatePollingContext { _ in }
    }

    /// Chained so quick open/close changes reach the provider in order.
    private func pushPollingContext() {
        let previous = pollingContextSync
        let target = provider
        let lgClient = lgWebOSClient
        let context = pollingContext
        pollingContextSync = Task {
            await previous?.value
            await target.setPollingContext(context)
            await lgClient?.setPollingContext(context)
        }
    }

    /// A cover that reports the same travel the command started has confirmed the command, so it
    /// supersedes the optimistic lock instead of waiting for a fixed duration to run out (#298).
    /// The reported position must also have reached the commanded position in the travel
    /// direction, so a status word that arrives before the position/target read-back cannot pull
    /// the card back to an intermediate value.
    private func coverTravelTakesOver(deviceId: String, local: SmartDevice, incoming: SmartDevice) -> Bool {
        guard case .cover(let localSpec) = local.kind,
              case .cover(let incomingSpec) = incoming.kind else { return false }
        // `positionPercent` is the display target while a MIoT cover travels. The reported
        // position is what proves the motor moved; target-only devices fall back to the target.
        guard let localPosition = localSpec.positionPercent,
              let incomingPosition = incomingSpec.reportedPositionPercent ?? incomingSpec.positionPercent else {
            return incomingSpec.motion == localSpec.motion
        }
        if incomingSpec.motion == .stopped {
            if incomingPosition == localPosition { return true }
            // A stop at the position held before the command is the stale pre-travel snapshot.
            if let origin = coverCommandOrigins[deviceId], incomingPosition == origin { return false }
            return true
        }
        guard localSpec.isMoving else {
            // A pause is confirmed by the device reporting that it stopped, not by another
            // moving snapshot.
            return false
        }
        return localSpec.motion == .opening
            ? incomingPosition >= localPosition
            : incomingPosition <= localPosition
    }

    /// Records a server rejection as the stored session's end and keeps `miAccounts`/`miSessionExpiresAt`
    /// in step. Split out of the event switch so the rejection path is testable without a live provider.
    func handleMiSessionRejected(_ rejected: MiSession) {
        guard let updated = MiSessionStore.markRejected(
            rejected,
            defaults: userDefaults,
            vault: credentialVault
        ) else { return }
        if let idx = miAccounts.firstIndex(where: {
            $0.session.userId == updated.userId && $0.session.serviceToken == updated.serviceToken
        }) {
            miAccounts[idx].session = updated
        }
        miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        refreshMiAccountsAfterRejection()
    }

    /// Hands the live provider the list the rejection just changed, so that account's child is
    /// rebuilt around the stored end instead of waking on the dead token forever. The update rides
    /// the same serialized chain as a provider swap; every other account keeps its child and data.
    private func refreshMiAccountsAfterRejection() {
        guard let provider = activeMiAccountsProvider else { return }
        let accounts = enabledMiAccounts
        activeMiProviderAccounts = accounts
        let previous = providerShutdownTask
        providerShutdownTask = Task {
            await previous?.value
            await provider.updateAccounts(accounts)
        }
    }

    func handleProviderEvent(_ event: HomeProviderEvent) {
        switch event {
        case .statusChanged(let status):
            if allConfiguredSourcesTurnedOff {
                let disabledStatus = ConnectionStatus.disconnected(L10n.tr("连接已停用", "Connection turned off"))
                if connectionStatus != disabledStatus { connectionStatus = disabledStatus }
                connectedBackends = []
                break
            }
            if connectionStatus != status { connectionStatus = status }
            if case .disconnected = status {
                connectedBackends = []
            } else if case .connected = status {
                if connectedBackends.isEmpty {
                    if homeBackend == .demo {
                        connectedBackends = [.demo]
                    } else if homeBackend == .homeAssistant {
                        if isHAConnectionEnabled { connectedBackends = [.homeAssistant] }
                    } else if hasEnabledMiSource {
                        connectedBackends = [.xiaomiCloud]
                    }
                }
                if !hasMiSource { localNetworkBlocks.remove(.homeAssistant) }
            }

        case .sourceStatusesChanged(let statuses):
            var effective = statuses
            if !isHAConnectionEnabled { effective.removeValue(forKey: .homeAssistant) }
            if !hasEnabledMiSource { effective.removeValue(forKey: .xiaomiCloud) }
            if sourceStatuses != effective { sourceStatuses = effective }
            if case .connected = effective[.homeAssistant],
               connectedBackends.contains(.homeAssistant) || (!hasMiSource && connectionStatus.isConnected) {
                localNetworkBlocks.remove(.homeAssistant)
            }

        case .localNetworkPermissionChanged(let blocked):
            var effective = blocked
            if !isHAConnectionEnabled { effective.remove(.homeAssistant) }
            if !hasEnabledMiSource { effective.remove(.xiaomiLAN) }
            if localNetworkBlocks != effective { localNetworkBlocks = effective }

        case .doorbellRang(let ring):
            if homeBackend != .demo,
               !isHAConnectionEnabled,
               (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant)) {
                let isBackedByHA = deviceBackends[ring.deviceId] == .homeAssistant
                    || (deviceBackends[ring.deviceId] != .xiaomiCloud && indexedDevicesById[ring.deviceId]?.connection == .homeAssistant)
                if isBackedByHA,
                   enabledMiFailoverScope(
                       for: ring.deviceId,
                       accountHint: devices.first(where: { $0.id == ring.deviceId })?.accountId
                   ) == nil {
                    return
                }
            }
            if deviceBackends[ring.deviceId] != .homeAssistant,
               !isPairedCardServedByEnabledHA(ring.deviceId),
               let indexed = indexedDevicesById[ring.deviceId],
               indexed.connection == .xiaomiCloud,
               !isMiAccountEnabled(indexed.sourceScope) {
                return
            }
            handleDoorbellRing(ring)

        case .sessionExpired(let rejected):
            guard isMiAccountEnabled(rejected.historyScopeIdentifier) else { return }
            handleMiSessionRejected(rejected)

        case .miotTypePruneChanged(let report):
            // A provider that is mid-teardown can still deliver a buffered report; a scope the user
            // has since disabled must not resurrect its retained safety set (P3a-M).
            guard report.scope.isEmpty || isMiAccountEnabled(report.scope) else { return }
            applyMiotTypePruneReport(report)

        case .haTypePruneChanged(let report):
            // Only the connection and address in use own a retained set; a late report from a
            // disabled connection or a replaced address is dropped (P3b-M).
            guard isHAConnectionEnabled, report.scope == homeAssistantScopeIdentifier else { return }
            applyMiotTypePruneReport(report)

        case .snapshotUpdated(let rawSnapshot):
            var snapshot = rawSnapshot
            let snapshotEpoch = rawSnapshot.miAccountsEpoch
            _ = recordMiotDidAccountScopes(from: rawSnapshot.devices, facetsByDeviceId: rawSnapshot.deviceFacets)
            let suppressHA = homeBackend != .demo
                && !isHAConnectionEnabled
                && (hasHASource || explicitlyDisabledConnections.contains(.homeAssistant))
            if suppressHA {
                let disabledHADeviceIds = Set(snapshot.devices.compactMap { device -> String? in
                    let effectiveBackend = snapshot.deviceBackends[device.id] ?? deviceBackends[device.id]
                    let isPairedWithEnabledMi = hasEnabledMiSource
                        && (snapshot.pairedDeviceIDs.contains(device.id) || pairedDeviceIDs.contains(device.id))
                    if isPairedWithEnabledMi {
                        return nil
                    }
                    if effectiveBackend == .homeAssistant {
                        return device.id
                    }
                    if effectiveBackend == nil,
                       device.accountId == nil,
                       !lgClientServes(device),
                       device.id != LGWebOSProtocol.deviceId,
                       (homeBackend == .homeAssistant || indexedDevicesById[device.id]?.connection == .homeAssistant) {
                        return device.id
                    }
                    return nil
                })
                snapshot.devices.removeAll { disabledHADeviceIds.contains($0.id) }
                snapshot.scenes.removeAll { MiCloudScene.accountID(for: $0.entityId) == nil }
                snapshot.sourceStatuses.removeValue(forKey: .homeAssistant)
                snapshot.localNetworkBlockedFeatures.remove(.homeAssistant)
                snapshot.activeBackends.remove(.homeAssistant)
                snapshot.environmentReadings.removeAll { disabledHADeviceIds.contains($0.id) }
                for id in disabledHADeviceIds {
                    snapshot.deviceFacets.removeValue(forKey: id)
                    snapshot.deviceBackends.removeValue(forKey: id)
                    snapshot.deviceTransportDiagnostics.removeValue(forKey: id)
                }
                for surviving in snapshot.devices {
                    let isPaired = snapshot.pairedDeviceIDs.contains(surviving.id) || pairedDeviceIDs.contains(surviving.id)
                    if snapshot.deviceBackends[surviving.id] == .homeAssistant,
                       hasEnabledMiSource,
                       isPaired,
                       pinnedSource(for: surviving.id) != .homeAssistant {
                        snapshot.deviceBackends[surviving.id] = .xiaomiCloud
                    }
                    if let existingFacets = snapshot.deviceFacets[surviving.id] {
                        let kept = existingFacets.filter { !shouldSuppressHAFacet($0) }
                        if kept.isEmpty {
                            snapshot.deviceFacets.removeValue(forKey: surviving.id)
                        } else if kept.count != existingFacets.count {
                            snapshot.deviceFacets[surviving.id] = kept
                        }
                    }
                }
            }
            let hasSuppressedMiScope = !revokedMiAccountScopes.isEmpty
                || miAccounts.contains {
                    shouldSuppressMiAccountInSnapshot($0.id, snapshotEpoch: snapshotEpoch)
                }
                || (!hasEnabledMiSource && (hasMiSource || !miAccounts.isEmpty))
            if hasSuppressedMiScope {
                // Some MIoT rows carry no `accountId`; the persisted index still knows which account
                // unites them, so a disabled or signed-out account's devices cannot come back through
                // them. Only paired cards genuinely driven by Home Assistant in this snapshot survive;
                // a Xiaomi-backed paired row carrying a suppressed account's device content is dropped
                // rather than relabeled to Home Assistant.
                let disabledDeviceIds = Set(snapshot.devices.compactMap { device -> String? in
                    if snapshot.deviceBackends[device.id] == .homeAssistant {
                        return nil
                    }
                    if let acc = device.accountId {
                        return shouldSuppressMiAccountInSnapshot(acc, snapshotEpoch: snapshotEpoch) ? device.id : nil
                    }
                    if let roomOwner = MiAccountScope.owner(of: device.roomId),
                       shouldSuppressMiAccountInSnapshot(roomOwner, snapshotEpoch: snapshotEpoch) {
                        return device.id
                    }
                    if let indexed = indexedDevicesById[device.id],
                       CapabilityReferenceEngine.connectionCapability(forScope: indexed.sourceScope) == .xiaomiCloud,
                       shouldSuppressMiAccountInSnapshot(indexed.sourceScope, snapshotEpoch: snapshotEpoch) {
                        return device.id
                    }
                    return nil
                })
                snapshot.devices.removeAll { disabledDeviceIds.contains($0.id) }
                snapshot.rooms.removeAll {
                    MiAccountScope.owner(of: $0.id).map { shouldSuppressMiAccountInSnapshot($0, snapshotEpoch: snapshotEpoch) } ?? false
                }
                snapshot.homes.removeAll {
                    $0.accountId.map { shouldSuppressMiAccountInSnapshot($0, snapshotEpoch: snapshotEpoch) } ?? false
                }
                snapshot.accountStatuses = snapshot.accountStatuses.filter {
                    !shouldSuppressMiAccountInSnapshot($0.key, snapshotEpoch: snapshotEpoch)
                }
                snapshot.freshAccountIds = snapshot.freshAccountIds.filter {
                    !shouldSuppressMiAccountInSnapshot($0, snapshotEpoch: snapshotEpoch)
                }
                snapshot.environmentReadings.removeAll { disabledDeviceIds.contains($0.id) }
                for id in disabledDeviceIds {
                    snapshot.deviceFacets.removeValue(forKey: id)
                    snapshot.deviceBackends.removeValue(forKey: id)
                    snapshot.deviceTransportDiagnostics.removeValue(forKey: id)
                }
                for index in snapshot.devices.indices {
                    let survivingId = snapshot.devices[index].id
                    if snapshot.deviceBackends[survivingId] == .homeAssistant,
                       let acc = snapshot.devices[index].accountId,
                       shouldSuppressMiAccountInSnapshot(acc, snapshotEpoch: snapshotEpoch) {
                        snapshot.devices[index].accountId = nil
                        snapshot.devices[index].accountLabel = nil
                    }
                    if let existingFacets = snapshot.deviceFacets[survivingId] {
                        let kept = existingFacets.filter { !shouldSuppressMiotFacet($0, snapshotEpoch: snapshotEpoch) }
                        if kept.isEmpty {
                            snapshot.deviceFacets.removeValue(forKey: survivingId)
                        } else if kept.count != existingFacets.count {
                            snapshot.deviceFacets[survivingId] = kept
                        }
                    }
                }
            }
            isApplyingProviderSnapshot = true
            snapshotGeneration &+= 1
            if selectedMiHomeId != nil, userDefaults.string(forKey: MiCloudProvider.selectedHomeKey) == nil {
                invalidateUndoContext()
                selectedMiHomeId = nil
                selectRoom(nil)
            }
            if !hasReceivedInitialSnapshot, snapshot.isInitialLoadComplete { hasReceivedInitialSnapshot = true }
            if !rawSnapshot.accountStatuses.isEmpty {
                if miAccountStatuses != snapshot.accountStatuses {
                    miAccountStatuses = snapshot.accountStatuses
                }
            } else if !miAccountStatuses.isEmpty {
                let enabledOnly = miAccountStatuses.filter { isMiAccountEnabled($0.key) }
                if miAccountStatuses != enabledOnly {
                    miAccountStatuses = enabledOnly
                }
            }
            let previousBackends = deviceBackends
            let nextConnected: Set<HomeBackend>
            if !snapshot.sourceStatuses.isEmpty {
                nextConnected = snapshot.activeBackends
            } else if snapshot.activeBackends.isEmpty {
                nextConnected = [homeBackend]
            } else {
                nextConnected = snapshot.activeBackends
            }
            if connectedBackends != nextConnected { connectedBackends = nextConnected }
            let backendsChanged = deviceBackends != snapshot.deviceBackends
            if backendsChanged { deviceBackends = snapshot.deviceBackends }
            let pairedChanged = pairedDeviceIDs != snapshot.pairedDeviceIDs
            if pairedChanged { pairedDeviceIDs = snapshot.pairedDeviceIDs }
            if lightGroupOwners != snapshot.lightGroupOwners { lightGroupOwners = snapshot.lightGroupOwners }
            if sourceStatuses != snapshot.sourceStatuses { sourceStatuses = snapshot.sourceStatuses }
            if deviceTransportDiagnostics != snapshot.deviceTransportDiagnostics {
                deviceTransportDiagnostics = snapshot.deviceTransportDiagnostics
            }
            if localNetworkBlocks != snapshot.localNetworkBlockedFeatures {
                localNetworkBlocks = snapshot.localNetworkBlockedFeatures
            }
            var nextRooms = snapshot.rooms
            if var lgDev = latestLGDevice, lgConfig.isEnabled, capabilitySelection.enabledCategories.contains(.tv) {
                if let matchedRoom = nextRooms.first(where: { $0.id == lgDev.roomId || $0.name == lgDev.roomName }) {
                    lgDev.roomId = matchedRoom.id
                    latestLGDevice = lgDev
                } else {
                    nextRooms.append(RoomArea(id: lgDev.roomId, name: lgDev.roomName, sortOrder: 1))
                }
            }
            if rooms != nextRooms { rooms = nextRooms }
            if homes != snapshot.homes { homes = snapshot.homes }
            if environmentReadings != snapshot.environmentReadings {
                environmentReadings = snapshot.environmentReadings
                maybeRefreshProactiveSuggestionsInBackground()
            }
            if pendingLegacyMenuBarTargetMigration,
               let first = snapshot.environmentReadings.first(where: { $0.temperature != nil }) {
                self.menuBarTargetId = "temp:\(first.id)"
                pendingLegacyMenuBarTargetMigration = false
            }
            if scenes != snapshot.scenes { scenes = snapshot.scenes }

            let now = optimisticNow()
            var merged: [SmartDevice] = []
            let existingById = Dictionary(self.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var reportedDevices: [String: SmartDevice] = [:]
            var reportedFacets = snapshot.deviceFacets
            for device in snapshot.devices {
                var incoming = device
                rawDeviceNames[incoming.id] = incoming.name
                let backendChanged = previousBackends[incoming.id] != nil
                    && previousBackends[incoming.id] != snapshot.deviceBackends[incoming.id]
                if backendChanged {
                    cancelFacetWrites(for: incoming.id)
                    clearOptimisticLockEntries(for: incoming.id)
                    clearOptimisticRevisions(for: incoming.id)
                    coverCommandOrigins.removeValue(forKey: incoming.id)
                    lastCoverPositions.removeValue(forKey: incoming.id)
                    manualWriteSessions.removeValue(forKey: incoming.id)
                    optimisticLockRevision[incoming.id, default: 0] &+= 1
                    cancelDebouncedWrites(for: incoming.id, recomputeRow: false)
                    let prefix = "\(incoming.id)."
                    for key in debounceTasks.keys where key == incoming.id || key.hasPrefix(prefix) {
                        debounceTasks.removeValue(forKey: key)?.cancel()
                    }
                }
                let captured = snapshot.devicePollCapturedEpochs[incoming.id]
                let staleFields = Set(fieldWriteEpochs.compactMap { key, epoch -> OptimisticField? in
                    guard key.deviceId == incoming.id, let captured, captured < epoch else { return nil }
                    return key.field
                })
                if !staleFields.contains(.coverPosition), case .cover(var cover) = incoming.kind {
                    let reported = cover.reportedPositionPercent ?? cover.positionPercent
                    let previousPosition = lastCoverPositions[incoming.id]
                    lastCoverPositions[incoming.id] = reported
                    if cover.motionIsInferred, previousPosition == reported {
                        // The position did not move between reports, so the difference against the
                        // target is not travel. Clear the inferred label and show where the motor
                        // actually stopped instead of latching the target.
                        cover.positionPercent = reported
                        cover.motion = .stopped
                        cover.motionIsInferred = false
                        incoming.kind = .cover(cover)
                    }
                }
                if let baseline = lastReportedDevices[incoming.id] {
                    reportedDevices[incoming.id] = device.mergingOptimisticFields(from: baseline, lockedFields: staleFields)
                } else {
                    reportedDevices[incoming.id] = device
                }
                pruneExpiredOptimisticLocks(for: incoming.id, at: now)
                // A primary power toggle is waiting for this read-back, so an older primary-power
                // lock must not hide the device's own property snapshot while unrelated field locks
                // stay intact. A cover tap has no property read-back to wait for: its commanded
                // row and travel origin survive until `coverTravelTakesOver` confirms travel.
                let readBackNeedsSnapshot: Bool
                if case .cover = incoming.kind {
                    readBackNeedsSnapshot = false
                } else {
                    readBackNeedsSnapshot = waitingDeviceIds.contains(incoming.id)
                        || readBackTickets.isInFlight(incoming.id)
                }
                if readBackNeedsSnapshot {
                    for field in OptimisticField.primaryPowerFields(for: incoming.kind).subtracting(staleFields) {
                        optimisticFieldLocks.removeValue(forKey: .field(incoming.id, field))
                    }
                }
                var lockedFields = activeLockedFields(for: incoming.id, at: now)
                if lockedFields.contains(.coverPosition), !staleFields.contains(.coverPosition),
                   let local = existingById[incoming.id],
                   coverTravelTakesOver(deviceId: incoming.id, local: local, incoming: incoming) {
                    // The motor has confirmed the command, so its own report is authoritative.
                    // Keeping the timed lock here would hide it and make the card jump when
                    // the lock expired (#298). A drag still waiting in its debounce has not
                    // reached the provider, so this report cannot have confirmed it; that patch
                    // and its row stay, and the command still goes out when the debounce ends.
                    if !adoptCoverTravelReport(deviceId: incoming.id, incoming: incoming) {
                        optimisticFieldLocks.removeValue(forKey: .field(incoming.id, .coverPosition))
                        coverCommandOrigins.removeValue(forKey: incoming.id)
                        lockedFields.remove(.coverPosition)
                    }
                }
                lockedFields.formUnion(staleFields)
                if !lockedFields.contains(.coverPosition) {
                    coverCommandOrigins.removeValue(forKey: incoming.id)
                }
                merged.append(
                    reconcileManualWriteSessionWithSnapshot(
                        incoming,
                        local: existingById[incoming.id],
                        lockedFields: lockedFields
                    )
                )
            }
            if let lgDev = latestLGDevice, lgConfig.isEnabled, capabilitySelection.enabledCategories.contains(.tv),
               !merged.contains(where: { $0.id == lgDev.id }) {
                rawDeviceNames[lgDev.id] = lgDev.name
                pruneExpiredOptimisticLocks(for: lgDev.id, at: now)
                let lockedFields = activeLockedFields(for: lgDev.id, at: now)
                if !lockedFields.isEmpty, let local = existingById[lgDev.id] {
                    merged.insert(lgDev.mergingOptimisticFields(from: local, lockedFields: lockedFields), at: 0)
                } else {
                    merged.insert(lgDev, at: 0)
                }
            }
            // 更多设置 rows lock independently per controlId: a write in flight keeps only that
            // facet's local value until the lock expires or a read-back confirms it (#5).

            if let lgDev = latestLGDevice, lgConfig.isEnabled, capabilitySelection.enabledCategories.contains(.tv),
               reportedDevices[lgDev.id] == nil {
                reportedDevices[lgDev.id] = lgDev
            }
            lastReportedDevices = reportedDevices
            var nextFacets: [String: [FacetControl]] = [:]
            for device in snapshot.devices {
                var lockedControlIds = activeLockedFacetControlIds(for: device.id, at: now)
                let captured = snapshot.facetPollCapturedEpochs[device.id]
                let staleControls = Set((snapshot.deviceFacets[device.id] ?? []).compactMap { facet -> String? in
                    guard let captured, let epoch = facetWriteEpochs[Self.facetLockKey(device.id, facet.id)],
                          captured < epoch else { return nil }
                    return facet.id
                })
                lockedControlIds.formUnion(staleControls)
                if !staleControls.isEmpty {
                    let baseline = lastReportedFacets[device.id] ?? []
                    reportedFacets[device.id] = snapshot.deviceFacets[device.id]?.compactMap { facet in
                        staleControls.contains(facet.id) ? baseline.first { $0.id == facet.id } : facet
                    }
                }
                if case .generic(let spec) = device.kind,
                   let powerControlId = spec.powerControl?.id,
                   activeLockedFields(for: device.id, at: now).contains(.power) {
                    lockedControlIds.insert(powerControlId)
                }
                if let incoming = snapshot.deviceFacets[device.id] {
                    if lockedControlIds.isEmpty {
                        nextFacets[device.id] = incoming
                    } else {
                        let localById = Dictionary(
                            (deviceFacets[device.id] ?? []).map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        nextFacets[device.id] = incoming.map { facet in
                            guard lockedControlIds.contains(facet.id), let local = localById[facet.id] else {
                                return facet
                            }
                            var updated = facet
                            updated.value = local.value
                            return updated
                        }
                    }
                } else if !lockedControlIds.isEmpty, let local = deviceFacets[device.id] {
                    nextFacets[device.id] = local
                }
            }
            lastReportedFacets = reportedFacets
            let facetsChanged = deviceFacets != nextFacets
            if facetsChanged { deviceFacets = nextFacets }

            let nextDevices = devicesWithAliases(merged)
            let devicesChanged = devices != nextDevices
            if devicesChanged {
                devices = nextDevices
            } else if backendsChanged || pairedChanged || facetsChanged {
                syncIndexedDevices(from: devices)
            }
            adoptPairedDevicePreferences(snapshot.preferenceAdoptions)
            if let expandedId = expandedDeviceId,
               devices.first(where: { $0.id == expandedId })?.isOnline != true {
                expandedDeviceId = nil
            }
            reconcileReenabledScopesAfterSnapshot(snapshot)
            if snapshot.isInitialLoadComplete, snapshot.closesAwayGap,
               pausedScheduledCommands.contains(where: \.requiresTimerRevalidation) {
                revalidatePausedTimers()
            }
            removeActivitiesForMissingDevices()
            seedDefaultFavoritesIfNeeded()
            if activeDualProvider != nil || provider is DualSourceHomeProvider {
                syncMiotTypePrunePolicy()
            }
            isApplyingProviderSnapshot = false
            let sampleNow = Date()
            scheduleRaycastSnapshotExport()
            let shouldRecordHistory = devicesChanged
                || backendsChanged
                || lastHistoryRecordAt == nil
                || sampleNow.timeIntervalSince(lastHistoryRecordAt!) >= 30
            if shouldRecordHistory {
                lastHistoryRecordAt = sampleNow
                energyHistory.record(devices: devices, deviceBackends: deviceBackends, now: sampleNow)
                sensorHistory.record(devices: devices, now: sampleNow)
                offlineHistory.record(devices: devices, now: sampleNow)
            }

            if enableSafetyAlerts {
                // `evaluateSafetyAlerts` records into the activity stack whether or not the app
                // installed a notification handler, so the panel still shows every fired alert.
                let alerts = evaluateSafetyAlerts(now: Date())
                if let handler = onSafetyAlert {
                    for alert in alerts {
                        handler(alert)
                    }
                }
            }
            if snapshot.closesAwayGap {
                finishPresenceSnapshot()
            }
            notifyMissedScheduledCommandsIfNeeded()
        }
    }

    /// Folds the orphaned side's stored preferences onto each paired card's canonical id (#24).
    /// The dedup reports pairs whose other source id also holds history; hidden wins, favorites
    /// merge by union, and aliases / tile sizes only fill a canonical id without its own. Each pair
    /// merges once (`DevicePreferenceMigrator`), so a later snapshot repeating the same report
    /// leaves the user's unhide, unstar or cleared alias on the merged card alone.
    func adoptPairedDevicePreferences(_ adoptions: [String: String]) {
        guard !adoptions.isEmpty else { return }
        var aliasesChanged = false
        for (canonicalID, orphanedID) in adoptions.sorted(by: { $0.key < $1.key }) {
            let outcome = DevicePreferenceMigrator.adopt(
                canonicalID: canonicalID,
                orphanedID: orphanedID,
                defaults: userDefaults
            )
            if outcome.hidden { hiddenDeviceIds.insert(canonicalID) }
            if outcome.favorite {
                favoriteDeviceIds.insert(canonicalID)
                if !favoriteOrder.contains(canonicalID) {
                    if let index = favoriteOrder.firstIndex(of: orphanedID) {
                        favoriteOrder.insert(canonicalID, at: index + 1)
                    } else {
                        favoriteOrder.append(canonicalID)
                    }
                }
            }
            aliasesChanged = aliasesChanged || outcome.alias
        }
        if aliasesChanged {
            devices = devicesWithAliases(devices)
        }
    }

    private func seedDefaultFavoritesIfNeeded() {
        guard favoriteDeviceIds.isEmpty,
              userDefaults.object(forKey: "favorite_device_ids") == nil,
              !devices.isEmpty else {
            return
        }
        // Automatically star online controllable devices on first launch, putting full-row
        // climate strips after compact capsules so 2×1 capsules pair cleanly side by side.
        let candidates = devices.filter { $0.isOnline && ($0.isPrimaryToggleable || $0.hasDetailDrawer) }
        let nonClimate = candidates.filter { if case .climate = $0.kind { return false } else { return true } }
        let climate = candidates.filter { if case .climate = $0.kind { return true } else { return false } }
        let initial = (nonClimate + climate).prefix(6).map(\.id)
        if !initial.isEmpty {
            self.favoriteDeviceIds = Set(initial)
            self.favoriteOrder = initial
        }
    }

    public func originalDeviceName(for deviceId: String) -> String? {
        rawDeviceNames[deviceId] ?? devices.first(where: { $0.id == deviceId })?.name
    }

    /// Identifies the connected home source for sensor history and safety alerts: `demo`, `ha:<url>` or
    /// `mi:<scope>`. Nil while a live source has no resolved session (signed out), so nothing may be
    /// adopted on it. Scheduled commands no longer share this single primary value: each timer records
    /// the whole `activeConnectionScopes` set and matches against it (ADR-0019).
    public var connectionScopeIdentifier: String? {
        if homeBackend == .demo { return HomeBackend.demo.descriptor.primaryScopeIdentifier(self) }
        for backend in [HomeBackend.homeAssistant, .xiaomiCloud] where backend.descriptor.isConfigured(self) {
            return backend.descriptor.primaryScopeIdentifier(self)
        }
        return homeBackend.descriptor.primaryScopeIdentifier(self)
    }

    /// The Home Assistant scope value, shaped like the `ha:` entry `syncHistoryConnectionScopes()` writes, so
    /// stored timer stamps stay comparable with history scopes and with entries written by older builds.
    var homeAssistantScopeIdentifier: String {
        "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(serverURLString))"
    }

    /// Every source configured right now: `demo`; Home Assistant when a token is saved plus each signed-in
    /// Xiaomi account. Timers record this set when created and arm while it still matches, so a source can
    /// be removed without stranding timers owned by the sources that remain. With no saved source
    /// (injected test providers, signed out) the primary scope keeps the old behavior.
    public var activeConnectionScopes: Set<String> {
        if homeBackend == .demo { return HomeBackend.demo.descriptor.activeScopeIdentifiers(self) }
        var scopes: Set<String> = []
        for backend in [HomeBackend.homeAssistant, .xiaomiCloud] where backend.descriptor.isConfigured(self) {
            scopes.formUnion(backend.descriptor.activeScopeIdentifiers(self))
        }
        if scopes.isEmpty, let scope = connectionScopeIdentifier { scopes.insert(scope) }
        return scopes
    }

    func syncHistoryConnectionScopes() {
        let scope = connectionScopeIdentifier ?? "mi:signed-out"
        sensorHistory.setConnectionScope(scope)
        energyHistory.setConnectionScope(scope)
    }

    /// Triggers an on-demand provider fetch for `deviceId`'s historical readings when due.
    public func requestSensorHistory(
        for deviceId: String,
        window: SensorHistoryWindow,
        force: Bool = false,
        now: Date = Date()
    ) {
        if allConfiguredSourcesTurnedOff { return }
        if homeBackend != .demo, !isHAConnectionEnabled,
           deviceBackends[deviceId] == .homeAssistant
               || (deviceBackends[deviceId] != .xiaomiCloud && indexedDevicesById[deviceId]?.connection == .homeAssistant),
           enabledMiFailoverScope(
               for: deviceId,
               accountHint: devices.first(where: { $0.id == deviceId })?.accountId
           ) == nil {
            return
        }
        if !force {
            guard sensorHistory.shouldFetchCloud(deviceId: deviceId, window: window, now: now) else { return }
        }
        let activeProvider = provider
        let requestScope = sensorHistory.connectionScope
        sensorHistory.setLoading(true, deviceId: deviceId, window: window)
        Task { @MainActor [weak self] in
            let samples = await activeProvider.fetchSensorHistory(deviceId: deviceId, window: window, now: now)
            guard let self else { return }
            guard self.sensorHistory.connectionScope == requestScope else { return }
            self.sensorHistory.setLoading(false, deviceId: deviceId, window: window)
            self.sensorHistory.mergeCloudSamples(deviceId: deviceId, window: window, samples: samples, now: now)
        }
    }

    public func applyDeviceAliases(_ overrides: [String: String]? = nil) {
        let nextDevices = devicesWithAliases(devices, overrides: overrides)
        if devices != nextDevices { devices = nextDevices }
    }

    // MARK: - Wall-switch «this is a light» marks (#104)

    public func isSwitchMarkedAsLight(_ deviceId: String) -> Bool {
        SwitchLightMarks.isMarked(deviceId, defaults: userDefaults)
    }

    /// Marks a wall switch as an ordinary light so its power control stops the high-risk
    /// confirmation (#104). The confirmation policy reads the mark at its single decision point;
    /// no UI layer skips the gate. Guarded by the same wall-switch rule the rename hint uses, so a
    /// stray id can never silence a plug, cover, lock or heater.
    public func markSwitchAsLight(_ deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }),
              ManualControlPolicy.wallSwitchMayControlLight(device) else { return }
        var ids = SwitchLightMarks.load(defaults: userDefaults)
        guard ids.insert(deviceId).inserted else { return }
        SwitchLightMarks.save(ids, defaults: userDefaults)
        scheduleRaycastSnapshotExport()
    }

    /// Restores the confirmation for a marked wall switch, from the device menu (#104).
    public func unmarkSwitchAsLight(_ deviceId: String) {
        var ids = SwitchLightMarks.load(defaults: userDefaults)
        guard ids.remove(deviceId) != nil else { return }
        SwitchLightMarks.save(ids, defaults: userDefaults)
        scheduleRaycastSnapshotExport()
    }

    func devicesWithAliases(_ input: [SmartDevice], overrides: [String: String]? = nil) -> [SmartDevice] {
        var result = input
        let aliases: [String: String]
        if let overrides {
            aliases = overrides
            if let data = try? JSONEncoder().encode(overrides),
               let raw = String(data: data, encoding: .utf8) {
                userDefaults.set(raw, forKey: Self.deviceAliasesKey)
            }
        } else if let raw = userDefaults.string(forKey: Self.deviceAliasesKey),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            aliases = decoded
        } else {
            aliases = [:]
        }
        for idx in result.indices {
            let id = result[idx].id
            let baseName = rawDeviceNames[id] ?? result[idx].name
            rawDeviceNames[id] = baseName
            if let alias = aliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty,
               alias != baseName {
                result[idx].name = alias
            } else {
                result[idx].name = baseName
            }
        }
        return result
    }

    // MARK: - Connection & Settings Management

    func makeHAProvider(baseURLString: String, token: String) -> HAHomeAdapter {
        let callback: (@Sendable (HADiscoveredInstance) -> Void)?
        if isTestEnvironment {
            callback = nil
        } else {
            callback = { @Sendable [weak self] instance in
                Task { @MainActor [weak self] in
                    self?.offerHAAddress(instance)
                }
            }
        }
        let defaults = UncheckedUserDefaults(userDefaults)
        let pruneBox = haTypePruneBox
        syncMiotTypePrunePolicy()
        let provider = HAWebSocketProvider(
            baseURLString: baseURLString,
            token: token,
            onAddressSuggestion: callback,
            allowsToken: { HAPlaintextConsent.allowsToken(to: $0, defaults: defaults.defaults) },
            onPlaintextConsentNeeded: { @Sendable [weak self] url in
                Task { @MainActor [weak self] in
                    self?.askHAPlaintext(url)
                }
            },
            isNetworkSatisfied: { @MainActor [weak self] in self?.knownNetworkSatisfied == true },
            typePrunePolicyLoader: { pruneBox.get() }
        )
        return HAHomeAdapter(provider: provider)
    }

    private func makeConfiguredHAProvider(baseURLString: String, token: String) -> any HomeProvider {
        if let factory = haProviderFactory {
            return factory(baseURLString, token)
        }
        return makeHAProvider(baseURLString: baseURLString, token: token)
    }

    /// Ignores a late callback from a provider that was already replaced, and keeps a declined
    /// answer so a refresh does not ask again until the address or the provider changes.
    func askHAPlaintext(_ url: String) {
        guard homeBackend != .demo,
              isHAConnectionEnabled,
              HAWebSocketProvider.normalizeBaseURL(url) == HAWebSocketProvider.normalizeBaseURL(serverURLString),
              haPlaintextPrompt != .declined(url) else { return }
        haPlaintextPrompt = .asking(url)
    }

    /// 仍然连接: remembers consent for this address only, then connects.
    public func allowHAPlaintext() {
        guard homeBackend != .demo, let url = haPlaintextPrompt?.address else { return }
        haPlaintextPrompt = nil
        HAPlaintextConsent.approve(url, defaults: userDefaults)
        rebuildLiveProvider(forceHAReconnect: true)
    }

    /// 不连接: nothing is sent; the banner keeps the reason and still offers to connect.
    public func declineHAPlaintext() {
        guard case .asking(let url) = haPlaintextPrompt else { return }
        haPlaintextPrompt = .declined(url)
    }

    func makeLiveProvider(migrateLegacyMiEnvelope: Bool = true) -> any HomeProvider {
        guard !isIdentityUncertain else {
            activeHAProvider = nil
            activeHAConfig = nil
            activeMiAccountsProvider = nil
            activeDualProvider = nil
            return Self.makeComposite(
                homeAssistant: nil,
                xiaomiCloud: nil,
                defaults: userDefaults,
                pinBox: pinnedDeviceSourcesBox
            )
        }
        let token = loadHAToken()
        let active = activeBackends
        let wantsHA = active.contains(.homeAssistant)
        let wantsMi = active.contains(.xiaomiCloud)
        let ha: (any HomeProvider)? = if wantsHA {
            makeConfiguredHAProvider(baseURLString: serverURLString, token: token)
        } else {
            nil
        }
        activeHAProvider = ha
        activeHAConfig = wantsHA ? (url: HAWebSocketProvider.normalizeBaseURL(serverURLString), token: token) : nil
        let mi: MiAccountsProvider? = wantsMi ? makeMiAccountsProvider(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope) : nil
        activeMiAccountsProvider = mi
        let composite = Self.makeComposite(
            homeAssistant: ha,
            xiaomiCloud: mi,
            defaults: userDefaults,
            pinBox: pinnedDeviceSourcesBox
        )
        activeDualProvider = composite
        syncMiotTypePrunePolicy()
        return composite
    }

    static func makeComposite(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        defaults: UserDefaults,
        pinBox: DeviceSourcePinBox? = nil
    ) -> DualSourceHomeProvider {
        let box = UncheckedUserDefaults(defaults)
        let stored = defaults.dictionary(forKey: ViewPreferenceKeys.canonicalDeviceIds) as? [String: String] ?? [:]
        return DualSourceHomeProvider(
            homeAssistant: homeAssistant,
            xiaomiCloud: xiaomiCloud,
            initialCanonicalIDs: stored,
            knownPreferenceIDs: {
                var ids = DevicePreferenceIndex.referencedIDs(defaults: box.defaults)
                if let pinBox {
                    ids.formUnion(pinBox.get().keys)
                }
                return ids
            },
            pinnedBackends: {
                if let pinBox {
                    return pinBox.get()
                }
                return DeviceSourcePinStorage.load(defaults: box.defaults)
            },
            persistCanonicalIDs: { assignments in
                box.defaults.set(assignments, forKey: ViewPreferenceKeys.canonicalDeviceIds)
            }
        )
    }

    func rebuildLiveProvider(forceHAReconnect: Bool = false, migrateLegacyMiEnvelope: Bool = true) {
        haPlaintextPrompt = nil
        guard !isIdentityUncertain else {
            eventTask?.cancel()
            eventTask = nil
            shutdownCurrentProvider()
            activeHAProvider = nil
            activeHAConfig = nil
            activeMiAccountsProvider = nil
            activeDualProvider = nil
            miAccountsConfigEpoch = 0
            self.provider = Self.makeComposite(
                homeAssistant: nil,
                xiaomiCloud: nil,
                defaults: userDefaults,
                pinBox: pinnedDeviceSourcesBox
            )
            return
        }
        guard let dual = activeDualProvider,
              provider as AnyObject === dual,
              homeBackend != .demo else {
            eventTask?.cancel()
            shutdownCurrentProvider()
            miAccountsConfigEpoch = 0
            self.provider = makeLiveProvider(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope)
            startListening()
            return
        }

        let token = loadHAToken()
        let active = activeBackends
        let wantsHA = active.contains(.homeAssistant)
        let wantsMi = active.contains(.xiaomiCloud)
        if !wantsHA {
            dual.markBackendDisabled(.homeAssistant)
        }
        if !wantsMi {
            dual.markBackendDisabled(.xiaomiCloud)
        }
        let haEnableGeneration = wantsHA ? dual.disableGeneration(for: .homeAssistant) : nil
        let miEnableGeneration = wantsMi ? dual.disableGeneration(for: .xiaomiCloud) : nil
        var nextHAReplacement: (shouldReplace: Bool, provider: (any HomeProvider)?) = (false, nil)
        var haCredentialUpdate: (provider: HAWebSocketProvider, url: String, token: String)?
        if wantsHA {
            let normalizedURL = HAWebSocketProvider.normalizeBaseURL(serverURLString)
            if let existingHA = activeHAProvider {
                if forceHAReconnect || activeHAConfig?.url != normalizedURL || activeHAConfig?.token != token {
                    activeHAConfig = (url: normalizedURL, token: token)
                    if let wsProvider = existingHA.haWebSocketProvider {
                        haCredentialUpdate = (wsProvider, serverURLString, token)
                    } else {
                        let createdHA = makeConfiguredHAProvider(baseURLString: serverURLString, token: token)
                        activeHAProvider = createdHA
                        nextHAReplacement = (true, createdHA)
                    }
                }
            } else {
                let createdHA = makeConfiguredHAProvider(baseURLString: serverURLString, token: token)
                activeHAProvider = createdHA
                activeHAConfig = (url: normalizedURL, token: token)
                nextHAReplacement = (true, createdHA)
            }
        } else if activeHAProvider != nil {
            activeHAProvider = nil
            activeHAConfig = nil
            nextHAReplacement = (true, nil)
        }
        var nextMiReplacement: (shouldReplace: Bool, provider: MiAccountsProvider?) = (false, nil)
        var miAccountsUpdate: (provider: MiAccountsProvider, accounts: [MiAccount], invalidateSnapshot: Bool, revocations: [String: UInt64])?
        var miAccountsChanged = false
        if wantsMi {
            let latestAccounts = loadActiveMiAccounts(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope)
            miAccounts = latestAccounts
            let enabledAccounts = enabledMiAccounts
            let previousAccounts = activeMiProviderAccounts
            for account in enabledAccounts {
                dual.markXiaomiAccountEnabled(account.id)
                activeMiAccountsProvider?.markAccountEnabled(account.id)
            }
            let revokedIDs = Set(previousAccounts.map(\.id)).subtracting(enabledAccounts.map(\.id))
            let revocations = dual.markXiaomiAccountsDisabled(revokedIDs)
            if !revokedIDs.isEmpty {
                activeMiAccountsProvider?.markAccountsDisabled(revokedIDs)
            }
            miAccountsChanged = enabledAccounts.count != previousAccounts.count
                || !zip(enabledAccounts, previousAccounts).allSatisfy { $0.id == $1.id && $0.session == $1.session }
            let keptAnyAccount = enabledAccounts.contains { next in
                previousAccounts.contains { $0.id == next.id && $0.session == next.session }
            }
            if let existingMi = activeMiAccountsProvider {
                if miAccountsChanged {
                    activeMiProviderAccounts = enabledAccounts
                    miAccountsUpdate = (existingMi, enabledAccounts, !keptAnyAccount && !enabledAccounts.isEmpty, revocations)
                }
            } else {
                let createdMi = makeMiAccountsProvider(migrateLegacyMiEnvelope: migrateLegacyMiEnvelope)
                activeMiAccountsProvider = createdMi
                nextMiReplacement = (true, createdMi)
            }
        } else if activeMiAccountsProvider != nil {
            let revokedIDs = Set(activeMiProviderAccounts.map(\.id))
            if !revokedIDs.isEmpty {
                dual.markXiaomiAccountsDisabled(revokedIDs)
                activeMiAccountsProvider?.markAccountsDisabled(revokedIDs)
            }
            activeMiAccountsProvider = nil
            nextMiReplacement = (true, nil)
        }
        var targetMiEpoch: Int?
        if nextMiReplacement.shouldReplace || miAccountsUpdate != nil {
            miAccountsConfigEpoch &+= 1
            targetMiEpoch = miAccountsConfigEpoch
        }
        if haCredentialUpdate != nil || nextHAReplacement.shouldReplace || nextMiReplacement.shouldReplace || miAccountsChanged {
            hasReceivedInitialSnapshot = false
            listeningSnapshotGeneration = snapshotGeneration
        }
        syncScheduledCommandScopeIfNeeded()
        let previousShutdown = providerShutdownTask
        providerShutdownTask = Task {
            await previousShutdown?.value
            if let u = haCredentialUpdate {
                await dual.invalidateSnapshot(for: .homeAssistant)
                await u.provider.updateCredentials(baseURLString: u.url, token: u.token)
            }
            if nextHAReplacement.shouldReplace, let ha = nextHAReplacement.provider {
                await dual.setSourceProvider(ha, for: .homeAssistant, expectedDisableGeneration: haEnableGeneration)
            }
            if nextMiReplacement.shouldReplace, let mi = nextMiReplacement.provider {
                if let targetMiEpoch { await mi.setConfigEpoch(targetMiEpoch) }
                await dual.setSourceProvider(mi, for: .xiaomiCloud, expectedDisableGeneration: miEnableGeneration)
            }
            if nextHAReplacement.shouldReplace, nextHAReplacement.provider == nil {
                await dual.setSourceProvider(nil, for: .homeAssistant)
            }
            if nextMiReplacement.shouldReplace, nextMiReplacement.provider == nil {
                await dual.setSourceProvider(nil, for: .xiaomiCloud)
            }
            if let u = miAccountsUpdate {
                await dual.revokeXiaomiAccountsGrace(u.revocations)
                if u.invalidateSnapshot { await dual.invalidateSnapshot(for: .xiaomiCloud) }
                await u.provider.updateAccounts(u.accounts, configEpoch: targetMiEpoch)
            }
        }
    }

    /// Shows a found address as a question instead of switching to it (#18). An address whose instance id
    /// differs from the Home Assistant the user chose before is ignored.
    public func offerHAAddress(_ instance: HADiscoveredInstance) {
        guard homeBackend != .demo, isHAConnectionEnabled else { return }
        guard HAAddressPolicy.canOffer(
            instance,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey),
            dismissedURLs: dismissedHAAddressURLs
        ) else { return }
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        pendingHAAddressSuggestion = instance
    }

    public func acceptHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        applyDiscoveredHAInstance(instance, reconnectProvider: true)
    }

    public func dismissHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        dismissedHAAddressURLs.insert(HAWebSocketProvider.normalizeBaseURL(instance.baseURL))
    }

    /// Remembers which Home Assistant the user picked so a look-alike elsewhere is not offered later.
    private func rememberHAInstanceId(forURL url: String) {
        let normalized = HAWebSocketProvider.normalizeBaseURL(url)
        if let uuid = discoveredHAInstances.first(where: { $0.baseURL == normalized })?.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        } else {
            userDefaults.removeObject(forKey: HAAddressPolicy.rememberedUUIDKey)
        }
    }

    public func switchBackend(_ backend: HomeBackend) {
        if backend != .xiaomiCloud { dismissMiReauth() }
        if backend == .demo, homeBackend == .demo, provider is DemoHomeProvider { return }
        if backend != .demo, homeBackend == backend, provider is DualSourceHomeProvider { return }
        invalidateUndoContext()

        let previousBackend = homeBackend
        if backend == .demo, previousBackend != .demo {
            preDemoBackend = (hasHASource || hasMiSource || !miAccounts.isEmpty) ? previousBackend : nil
        } else if backend != .demo {
            preDemoBackend = nil
        }
        self.homeBackend = backend
        if backend == .demo {
            clearHATeardownState()
            eventTask?.cancel()
            shutdownCurrentProvider()
            haPlaintextPrompt = nil
            // `offerHAAddress` refuses in demo; an offer made before the switch must not stay on screen.
            pendingHAAddressSuggestion = nil
            // Strictly offline: stop any LAN TV and update work started by the previous backend (#47).
            if let lgClient = lgWebOSClient {
                Task { await lgClient.stop() }
            }
            latestLGDevice = nil
            updateTask?.cancel()
            updateTask = nil
            activeUpdateAttemptID = nil
            updateRelaunchWatchdogTask?.cancel()
            updateRelaunchWatchdogTask = nil
            if case .readyToRelaunch(let staged) = updateState {
                updater.cleanupStagedApp(staged)
            }
            updateState = .idle
            self.provider = DemoHomeProvider()
            startListening()
        } else {
            if previousBackend == .demo {
                self.hasHASource = !loadHAToken()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            rebuildLiveProvider()
            resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: previousBackend == .demo)
        }
    }

    /// Leaving demo mode resumes the LAN TV link that demo stopped; `start()` no-ops when the
    /// config is disabled or has no host. A launch in demo mode never created the client, so
    /// create it now instead of leaving a configured TV missing until relaunch.
    private func resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: Bool) {
        guard wasDemo, homeBackend != .demo, !isIdentityUncertain else { return }
        if let lgClient = lgWebOSClient {
            Task { await lgClient.start() }
        } else {
            startLGWebOSIfNeeded()
        }
    }

    /// Records the backend a QR login starts on. A completion after the user switched away only
    /// saves the session and leaves the chosen backend alone.
    public func beginMiLogin() {
        miLoginStartBackend = homeBackend
    }

    @discardableResult
    public func completeMiLogin(_ session: MiSession) -> Bool {
        if identityMigrationDiagnostic != nil, !retryIdentityMigration() {
            showToast(
                L10n.tr(
                    "无法确认现有配置或凭据，未保存本次米家登录，请检查钥匙串授权后重试",
                    "Could not verify existing settings or credentials; sign-in was not saved. Check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }
        let candidateScope = MiAccount(session: session).id
        if isMiAccountPendingRemoval(candidateScope) {
            showToast(
                L10n.tr(
                    "该米家账号仍有未完成的移除，请先重试清理再重新登录",
                    "This Xiaomi account still has an unfinished removal; retry the cleanup before signing in again"
                ),
                isError: true
            )
            return false
        }
        guard MiSessionStore.upsert(session, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                isError: true
            )
            return false
        }
        // The primary (first) account drives the summary and the history scope, so signing in a
        // second account must not relabel the panel with the newcomer.
        miAccounts = loadActiveMiAccounts()
        if let added = miAccounts.first(where: {
            $0.session.userId == session.userId && $0.session.region.caseInsensitiveCompare(session.region) == .orderedSame
        }) ?? miAccounts.first {
            revokedMiAccountScopes.remove(added.id)
            (activeDualProvider ?? (provider as? DualSourceHomeProvider))?.markXiaomiAccountEnabled(added.id)
            activeMiAccountsProvider?.markAccountEnabled(added.id)
            registerNewlyConfiguredScope(added.id, connection: .xiaomiCloud)
        }
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        self.isShowingMiReauth = false
        self.miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
        let previousRegion = miCloudRegion
        if let region = MiCloudRegion(rawValue: session.region.lowercased()) {
            self.miCloudRegion = region
        }
        let regionChanged = miCloudRegion != previousRegion
        let superseded = miLoginStartBackend.map { $0 != homeBackend } ?? false
        miLoginStartBackend = nil
        if superseded { return true }
        let wasDemo = homeBackend == .demo
        invalidateUndoContext()
        self.hasHASource = !loadHAToken()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        self.homeBackend = .xiaomiCloud
        self.completeOnboarding()
        rebuildLiveProvider()
        resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: wasDemo)
        showToast(
            regionChanged
                ? L10n.tr(
                    "已登录米家账号 (\(session.maskedUserId))，已切换到账号地区 \(miCloudRegion.label)",
                    "Signed in to Xiaomi Home (\(session.maskedUserId)); switched to the account's region \(miCloudRegion.label)"
                )
                : L10n.tr("已登录米家账号 (\(session.maskedUserId))", "Signed in to Xiaomi Home (\(session.maskedUserId))")
        )
        return true
    }

    /// Returns false when the Keychain/vault refused to delete the stored Mi session; the in-memory
    /// account is still signed out so the UI does not keep showing it.
    @discardableResult
    public func logoutMiAccount() -> Bool {
        guard !isIdentityUncertain else { return false }
        let removedScopes = Set(miAccounts.map(\.id))
        let cleared = MiSessionStore.clear(defaults: userDefaults, vault: credentialVault)
        topologyCache?.removeAll()
        revokedMiAccountScopes.formUnion(removedScopes)
        if let dual = activeDualProvider ?? (provider as? DualSourceHomeProvider) {
            if !removedScopes.isEmpty {
                dual.markXiaomiAccountsDisabled(removedScopes)
            }
            dual.markBackendDisabled(.xiaomiCloud)
        }
        if !removedScopes.isEmpty {
            activeMiAccountsProvider?.markAccountsDisabled(removedScopes)
        }
        miAccounts = []
        purgeRemovedAccountCapabilities(scopes: removedScopes)
        miAccountStatuses = [:]
        self.miSessionMaskedUserId = nil
        self.miSessionExpiresAt = nil
        self.isShowingMiReauth = false
        self.miSessionScopeIdentifier = nil
        self.homes = []
        self.selectedMiHomeId = nil
        userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        if homeBackend == .xiaomiCloud || provider is DualSourceHomeProvider {
            invalidateUndoContext()
            self.devices = []
            self.deviceFacets = [:]
            self.deviceTransportDiagnostics = [:]
            self.localNetworkBlocks.remove(.xiaomiLAN)
            self.rooms = []
            self.environmentReadings = []
            self.scenes = []
            selectRoom(nil)
            if hasHASource { self.homeBackend = .homeAssistant }
            rebuildLiveProvider()
        }
        // Removing a source is exactly the moment its paused timers/rules lose their targets; run the
        // revalidation now that the rows are gone instead of leaving the pause markers stuck (H2).
        revalidatePausedItems()
        showToast(L10n.tr("已退出米家账号", "Signed out of Xiaomi Home"))
        return cleared
    }

    /// The single destructive entry point behind Settings → 关于与诊断 → 高级排障与重置 → 退出并清除所有账号与密钥 (#143): signs out
    /// every Mi account, deletes the Home Assistant token and drops that connection, forgets saved AI
    /// keys and cloud-consent records. Local preferences, aliases and history stay untouched.
    /// Returns false and shows an error when any credential survived the deletion.
    @discardableResult
    public func signOutAndRevokeAll() -> Bool {
        guard !isIdentityUncertain else {
            showToast(
                L10n.tr(
                    "无法确认现有配置或凭据，未执行退出与清除，请检查钥匙串授权后重试",
                    "Could not verify existing settings or credentials; no credentials were deleted. Check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }
        invalidateUndoContext()
        topologyCache?.removeAll()
        var complete = true
        if !logoutMiAccount() { complete = false }
        if !disconnectHomeAssistant() { complete = false }
        if !AssistantConfig.removeAllStoredAPIKeys(defaults: userDefaults, vault: credentialVault) {
            complete = false
        }
        revokeCloudConsent()
        HAPlaintextConsent.revokeAll(defaults: userDefaults)
        haPlaintextPrompt = nil
        // The Spotlight index must not outlive the credentials that produced it (#575).
        clearSpotlightIndex()
        if complete {
            _ = ConnectionRemovalStore.clearAll(defaults: userDefaults)
            syncPendingConnectionRemovals()
            showToast(L10n.tr("已退出并吊销本地保存的令牌", "Signed out and removed saved tokens"))
        } else {
            showToast(
                L10n.tr(
                    "部分凭据未能删除，请在钥匙串授权后重试",
                    "Some credentials could not be removed. Allow Keychain access and try again."
                ),
                isError: true
            )
        }
        return complete
    }

    /// Deletes the Home Assistant long-lived token and closes the live connection, keeping the saved
    /// instance URL so the user can reconnect by entering only a new token. A remaining Mi source
    /// keeps serving the panel after the composite provider is rebuilt. Returns false when the token
    /// could not be deleted, leaving the current connection untouched.
    @discardableResult
    public func disconnectHomeAssistant() -> Bool {
        guard !isIdentityUncertain else { return false }
        guard KeychainHelper.saveToken("", defaults: userDefaults, vault: credentialVault) else {
            return false
        }
        haCredentialGeneration &+= 1
        (activeDualProvider ?? (provider as? DualSourceHomeProvider))?.markBackendDisabled(.homeAssistant)
        clearHATeardownState()
        let (_, cameraTeardownIds) = homeBackend == .demo ? (Set<String>(), Set<String>()) : collectHADisabledDeviceIds()
        let removedScope = homeAssistantScopeIdentifier
        hasHASource = false
        explicitlyDisabledConnections.remove(.homeAssistant)
        capabilitySelection.enabledConnections.insert(.homeAssistant)
        requireManualResumeAfterHARemoval()
        purgeRemovedAccountCapabilities(scopes: [removedScope])
        pendingHAAddressSuggestion = nil
        haPlaintextPrompt = nil
        localNetworkBlocks.remove(.homeAssistant)
        sourceStatuses.removeValue(forKey: .homeAssistant)
        connectedBackends.remove(.homeAssistant)
        if homeBackend != .demo {
            scenes.removeAll { MiCloudScene.accountID(for: $0.entityId) == nil }
            tearDownHACameras(cameraTeardownIds)
        }
        if homeBackend != .demo, hasManagedHAProvider {
            invalidateUndoContext()
            if hasMiSource {
                homeBackend = .xiaomiCloud
            } else {
                devices = []
                deviceFacets = [:]
                deviceTransportDiagnostics = [:]
                rooms = []
                environmentReadings = []
                scenes = []
                selectRoom(nil)
            }
            rebuildLiveProvider()
        } else if homeBackend != .demo, !hasMiSource {
            connectionStatus = .disconnected(L10n.tr("未配置", "Not configured"))
        }
        revalidatePausedItems()
        return true
    }

    /// Removes one account and keeps the rest: its devices, readings, rooms and homes leave the panel
    /// right away instead of waiting for the next merged snapshot.
    public func logoutMiAccount(id: String) {
        guard !isIdentityUncertain else { return }
        guard MiSessionStore.remove(accountID: id, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法更新钥匙串，请授权钥匙串访问后重试", "Could not update Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        topologyCache?.remove(accountID: id)
        invalidateUndoContext()
        revokedMiAccountScopes.insert(id)
        miAccounts = loadActiveMiAccounts()
        purgeRemovedAccountCapabilities(scopes: [id])
        let dual = activeDualProvider ?? (provider as? DualSourceHomeProvider)
        let revocations = dual?.markXiaomiAccountDisabled(id) ?? [:]
        if !hasEnabledMiSource {
            dual?.markBackendDisabled(.xiaomiCloud)
        }
        activeMiAccountsProvider?.markAccountDisabled(id)
        miAccountStatuses.removeValue(forKey: id)
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = enabledMiAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = enabledMiAccounts.first?.session.historyScopeIdentifier
        if let home = selectedMiHomeId, MiAccountScope.isOwned(home, by: id) {
            selectedMiHomeId = nil
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
        if homeBackend == .xiaomiCloud || provider is DualSourceHomeProvider {
            // Home Assistant keeps driving its paired cards: their copied `accountId` must not take
            // them off the panel with the account they were paired with (ADR-0008), but the signed-out
            // account's copied metadata and MIoT facets must be scrubbed immediately.
            let removedDeviceIds = Set(devices.filter {
                $0.accountId == id && deviceBackends[$0.id] != .homeAssistant
            }.map(\.id))
            devices.removeAll { $0.accountId == id && deviceBackends[$0.id] != .homeAssistant }
            for index in devices.indices {
                let deviceId = devices[index].id
                if deviceBackends[deviceId] == .homeAssistant, devices[index].accountId == id {
                    devices[index].accountId = nil
                    devices[index].accountLabel = nil
                }
                if let existingFacets = deviceFacets[deviceId] {
                    let kept = existingFacets.filter { !shouldSuppressMiotFacet($0) }
                    if kept.count != existingFacets.count {
                        cancelFacetWrites(for: deviceId)
                        if kept.isEmpty {
                            deviceFacets.removeValue(forKey: deviceId)
                        } else {
                            deviceFacets[deviceId] = kept
                        }
                    }
                }
            }
            for removedId in removedDeviceIds {
                cancelFacetWrites(for: removedId)
                deviceFacets.removeValue(forKey: removedId)
                deviceTransportDiagnostics.removeValue(forKey: removedId)
                lastReportedDevices.removeValue(forKey: removedId)
                lastReportedFacets.removeValue(forKey: removedId)
            }
            if miAccounts.isEmpty {
                localNetworkBlocks.remove(.xiaomiLAN)
            }
            environmentReadings.removeAll { removedDeviceIds.contains($0.id) }
            rooms.removeAll { MiAccountScope.isOwned($0.id, by: id) }
            // Its homes leave too, so the home menu cannot offer a home nobody owns any more.
            homes.removeAll { $0.accountId == id }
            // A room pill pointing at the removed account would show an empty panel.
            if let roomId = selectedRoomId, MiAccountScope.isOwned(roomId, by: id) {
                selectRoom(nil)
            }
            if miAccounts.isEmpty, hasHASource {
                self.homeBackend = .homeAssistant
            }
            if activeDualProvider != nil || !(provider is DualSourceHomeProvider) {
                rebuildLiveProvider()
            } else if let injectedDual = provider as? DualSourceHomeProvider {
                let shouldRemoveMiSource = !hasEnabledMiSource
                let previousShutdown = providerShutdownTask
                providerShutdownTask = Task {
                    await previousShutdown?.value
                    await injectedDual.revokeXiaomiAccountsGrace(revocations)
                    if shouldRemoveMiSource {
                        await injectedDual.setSourceProvider(nil, for: .xiaomiCloud)
                    }
                }
            }
        }
        // The removed account's rows are gone; let its paused references move on (missed, foreign or
        // still paused for a remaining scope) instead of staying paused forever (H2).
        revalidatePausedItems()
        showToast(miAccounts.isEmpty
            ? L10n.tr("已退出米家账号", "Signed out of Xiaomi Home")
            : L10n.tr("已移除米家账号", "Removed Xiaomi account"))
    }

    func shutdownCurrentProvider() {
        eventTask?.cancel()
        eventTask = nil
        pollingContextSync?.cancel()
        pollingContextSync = nil
        activeDualProvider = nil
        activeHAProvider = nil
        activeHAConfig = nil
        activeMiAccountsProvider = nil
        let old = provider
        let previousShutdown = providerShutdownTask
        providerShutdownTask = Task {
            await previousShutdown?.value
            await old.shutdown()
        }
    }

    @discardableResult
    public func updateConnection(serverURL: String, token: String) -> Bool {
        if identityMigrationDiagnostic != nil, !retryIdentityMigration() {
            return false
        }
        if hasPendingHARemoval {
            showToast(
                L10n.tr(
                    "有一个 Home Assistant 连接还没移除完，请先重试清理再保存连接",
                    "A Home Assistant removal is still unfinished; retry the cleanup before saving this connection"
                ),
                isError: true
            )
            return false
        }
        // A refused Keychain write must not report "Saved": the token would be gone after relaunch.
        guard KeychainHelper.saveToken(token, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                isError: true
            )
            return false
        }
        haCredentialGeneration &+= 1
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadHASource = hasHASource
        if trimmedToken.isEmpty { requireManualResumeAfterHARemoval() }
        // Only the connection-level flag carries the user's decision. `isHAConnectionEnabled` also
        // reads false for a scope-level turn-off left over from an earlier address, while adopting
        // the address below migrates the `ha:` scope back into `enabledConnectionScopes`. Taking the
        // settings-only path there would leave an enabled connection with no provider, and
        // 「启用连接」could not rebuild it either because everything already reads enabled.
        let keepHADisabled = hadHASource
            && explicitlyDisabledConnections.contains(.homeAssistant)
            && !trimmedToken.isEmpty
        let (_, cameraTeardownIds) = (hadHASource && trimmedToken.isEmpty && homeBackend != .demo)
            ? collectHADisabledDeviceIds()
            : (Set<String>(), Set<String>())
        let wasDemo = homeBackend == .demo
        let normalized = HAWebSocketProvider.normalizeBaseURL(serverURL)
        let addressChanged = normalized != HAWebSocketProvider.normalizeBaseURL(serverURLString)
        if addressChanged {
            rememberHAInstanceId(forURL: normalized)
        }
        pendingHAAddressSuggestion = nil
        self.serverURLString = normalized
        self.hasHASource = !trimmedToken.isEmpty
        // Re-read after the write above: migrating the scope can restore enablement on its own, so
        // only the connection that is still turned off skips the reconnect.
        if keepHADisabled, !isHAConnectionEnabled {
            // A saved address decides which instance the paused rows and the banner belong to.
            if addressChanged { invalidateUndoContext() }
            persistCapabilitySelection(removingScopes: [homeAssistantScopeIdentifier])
            self.completeOnboarding()
            if wasDemo {
                invalidateUndoContext()
                self.homeBackend = preferredLiveBackend
                rebuildLiveProvider()
                resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: true)
            } else {
                syncHistoryConnectionScopes()
                syncScheduledCommandScopeIfNeeded()
            }
            showToast(L10n.tr(
                "已保存 Home Assistant 配置（连接仍处于停用状态）",
                "Saved Home Assistant settings (connection remains turned off)"
            ))
            return true
        }
        invalidateUndoContext()
        if self.hasHASource {
            clearHATeardownState()
            registerNewlyConfiguredScope(homeAssistantScopeIdentifier, connection: .homeAssistant)
        } else {
            clearHATeardownState()
            explicitlyDisabledConnections.remove(.homeAssistant)
            capabilitySelection.enabledConnections.insert(.homeAssistant)
            persistCapabilitySelection(removingScopes: [homeAssistantScopeIdentifier])
            if hadHASource, homeBackend != .demo {
                tearDownHACameras(cameraTeardownIds)
            }
        }
        self.homeBackend = preferredLiveBackend
        if !trimmedToken.isEmpty {
            self.completeOnboarding()
        }
        rebuildLiveProvider()
        resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: wasDemo)
        showToast(L10n.tr("已保存并重新连接 Home Assistant", "Saved and reconnecting to Home Assistant"))
        return true
    }

    /// The user chose `instance` (a tap in setup or settings, or 切换 on a suggestion).
    public func applyDiscoveredHAInstance(_ instance: HADiscoveredInstance, reconnectProvider: Bool = true) {
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        if let uuid = instance.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
        if userDefaults.string(forKey: "home_name") == nil,
           !instance.locationName.isEmpty,
           instance.locationName != "Home Assistant" {
            self.homeName = instance.locationName
        }
        guard normalizedCurrent != instance.baseURL else { return }
        invalidateUndoContext()
        self.serverURLString = instance.baseURL
        if reconnectProvider, isHAConnectionEnabled {
            if let haProvider = provider.haWebSocketProvider {
                let token = loadHAToken()
                Task {
                    await haProvider.updateCredentials(baseURLString: instance.baseURL, token: token)
                }
            } else if provider is DualSourceHomeProvider {
                rebuildLiveProvider()
            }
        }
    }

    public var shouldAutoDiscoverHomeAssistantOnLAN: Bool {
        guard capabilityResolutionMode != .freshInstall,
              identityMigrationDiagnostic == nil,
              wakeIdentityProviderGeneration == nil,
              hasCompletedOnboarding else { return false }
        guard homeBackend != .demo, homeBackend != .xiaomiCloud, isHAConnectionEnabled else { return false }
        guard !hasHASource, !hasMiSource else { return false }
        if let lastAutoHADiscoveryAt,
           ContinuousClock.now - lastAutoHADiscoveryAt < Self.autoHADiscoveryCooldown {
            return false
        }
        return true
    }

    @discardableResult
    public func discoverHomeAssistantOnLAN(autoApplyIfDefault: Bool = false) async -> [HADiscoveredInstance] {
        // Demo mode and explicitly disabled HA connections do not run LAN discovery probes.
        guard homeBackend != .demo, isHAConnectionEnabled else { return [] }
        if autoApplyIfDefault {
            guard shouldAutoDiscoverHomeAssistantOnLAN else { return discoveredHAInstances }
            lastAutoHADiscoveryAt = ContinuousClock.now
        }
        guard !isDiscoveringHA else { return discoveredHAInstances }
        isDiscoveringHA = true
        defer { isDiscoveringHA = false }
        let discoverer = haLANDiscoverer
        let found = await discoverer(serverURLString)
        guard homeBackend != .demo, isHAConnectionEnabled else { return [] }
        self.discoveredHAInstances = found
        // A user who typed the address by hand never went through a suggestion; the moment LAN
        // discovery identifies the instance the app is connected to, pin its id so look-alikes
        // elsewhere are filtered later (#18).
        if let uuid = HAAddressPolicy.uuidToPin(
            discovered: found,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey)
        ) {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        // Only pre-fills the address during first setup. With a token already saved, the user picks the
        // address, because connecting sends the token to it (#18).
        if autoApplyIfDefault, let first = found.first {
            let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
            let isDefaultURL = (normalizedCurrent == KeychainHelper.defaultNASURL)
                || (userDefaults.string(forKey: "ha_server_url") == nil)
            let hasToken = !loadHAToken().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isDefaultURL && !hasToken && first.baseURL != normalizedCurrent {
                applyDiscoveredHAInstance(first, reconnectProvider: false)
            }
        }
        return found
    }

    @discardableResult
    public func updateLGWebOSConfig(_ newConfig: LGWebOSConfig) -> Bool {
        // Write before swapping `lgConfig` or updating `lgWebOSClient` so a refused Keychain write
        // never leaves unsaved config in memory, never connects with it, and never shows a success toast (#7).
        guard newConfig.save(to: userDefaults, vault: credentialVault) else {
            lgConfigSaveFailed = true
            showToast(Self.lgKeychainSaveErrorMessage, isError: true)
            return false
        }
        if newConfig.host != lgConfig.host || newConfig.isEnabled != lgConfig.isEnabled || newConfig.clientKey != lgConfig.clientKey {
            invalidateUndoContext()
        }
        lgConfigSaveFailed = false
        suppressNextLGConfigDidSetSave = true
        self.lgConfig = newConfig
        suppressNextLGConfigDidSetSave = false
        if !newConfig.isEnabled || !newConfig.hasConfiguredHost {
            latestLGDevice = nil
            lastReportedDevices.removeValue(forKey: LGWebOSProtocol.deviceId)
            devices.removeAll { $0.id == LGWebOSProtocol.deviceId }
            localNetworkBlocks.remove(.lgWebOS)
        }
        // Demo mode persists the preference but never connects to the LAN (#47).
        guard homeBackend != .demo else {
            showToast(
                newConfig.isEnabled
                    ? L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs")
                    : L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection")
            )
            return true
        }
        var lgStartedDuringRetry = false
        if identityMigrationDiagnostic != nil {
            guard retryIdentityMigration() else {
                return true
            }
            lgStartedDuringRetry = lgWebOSClient != nil
        }
        if !lgStartedDuringRetry {
            if let lgClient = lgWebOSClient {
                Task {
                    await lgClient.updateConfig(newConfig)
                }
            } else {
                startLGWebOSIfNeeded()
            }
        }
        if newConfig.isEnabled {
            showToast(
                newConfig.hasConfiguredHost
                    ? L10n.tr("已保存并重连 \(newConfig.name)", "Saved and reconnecting to \(newConfig.name)")
                    : L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"),
                isError: !newConfig.hasConfiguredHost
            )
        } else {
            showToast(L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection"))
        }
        return true
    }

    public func triggerLGWebOSPairing() {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return
        }
        guard lgConfig.hasConfiguredHost else {
            showToast(L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"), isError: true)
            return
        }
        if lgWebOSClient == nil {
            startLGWebOSIfNeeded()
        }
        guard let lgClient = lgWebOSClient else { return }
        showToast(L10n.tr("已向电视发送配对请求，请在电视屏幕点击「接受」", "Pairing request sent; accept the prompt on your TV screen"))
        Task {
            await lgClient.triggerPairing()
        }
    }

    /// Called only after Settings confirms discarding the saved TV identity.
    @discardableResult
    public func resetLGWebOSTrustAndPair() -> Task<Bool, Never>? {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return nil
        }
        guard lgConfig.hasConfiguredHost, let client = lgWebOSClient, !lgTrustResetInFlight else { return nil }
        let host = lgConfig.host
        // Closed synchronously with the task below: key callbacks from the pre-reset connection must
        // not restore trust while the reset is suspended (#262).
        lgTrustResetInFlight = true
        return Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.lgTrustResetInFlight = false }
            guard !Task.isCancelled, self.lgWebOSClient === client, self.lgConfig.host == host else { return false }
            let pairingVault: CredentialVault? = self.credentialVault
                ?? (self.userDefaults === UserDefaults.standard ? .shared : nil)

            // When trust and pairing key share a CredentialVault, clear both in one atomic Keychain
            // commit before stopping the client. Otherwise persist the cleared key first, then
            // reset trust (re-syncing storage to memory on error) so no failure leaves a split state.
            // Neither branch touches `lgConfig` in memory: every await below can interleave with a
            // Settings edit, so the final result is derived from the latest config after the last await.
            if let pairingVault, await client.trustStoreSharesVault(pairingVault) {
                do {
                    _ = try await client.resetTrust(
                        expectedHost: host,
                        clearingPairingKeyInVault: pairingVault
                    )
                } catch {
                    self.lgConfigSaveFailed = true
                    self.showToast(Self.lgKeychainSaveErrorMessage, isError: true)
                    return false
                }
            } else {
                guard !Task.isCancelled, self.lgWebOSClient === client, self.lgConfig.host == host else { return false }
                var clearedNow = self.lgConfig
                clearedNow.clientKey = ""
                guard clearedNow.save(to: self.userDefaults, vault: self.credentialVault) else {
                    self.lgConfigSaveFailed = true
                    self.showToast(Self.lgKeychainSaveErrorMessage, isError: true)
                    return false
                }
                do {
                    _ = try await client.resetTrust(expectedHost: host)
                } catch {
                    // Memory still holds the live config (including any edit made meanwhile).
                    _ = self.lgConfig.save(to: self.userDefaults, vault: self.credentialVault)
                    self.lgConfigSaveFailed = true
                    let message: String = (error as? LGCertificateTrust.Failure == .unavailable)
                        ? Self.lgKeychainSaveErrorMessage
                        : error.localizedDescription
                    self.showToast(message, isError: true)
                    return false
                }
            }

            await self.lgTrustResetSuspensionHookForTesting?()

            // Apply only the pairing-key change to the latest config, so a newer Settings edit
            // (disabled, renamed, moved to another TV) survives and a stale key is never written back.
            let sameTV = self.lgWebOSClient === client && self.lgConfig.host == host
            var final = self.lgConfig
            final.clientKey = ""
            guard final.save(to: self.userDefaults, vault: self.credentialVault) else {
                _ = self.lgConfig.save(to: self.userDefaults, vault: self.credentialVault)
                self.lgConfigSaveFailed = true
                self.showToast(Self.lgKeychainSaveErrorMessage, isError: true)
                return false
            }
            self.lgConfigSaveFailed = false
            self.suppressNextLGConfigDidSetSave = true
            self.lgConfig = final
            self.suppressNextLGConfigDidSetSave = false

            // The client must follow the store's latest config, never the snapshot taken before the
            // await: re-push until no edit slipped in during the hop.
            if let current = self.lgWebOSClient {
                var pushed = final
                await current.updateConfig(pushed)
                while self.lgWebOSClient === current, self.lgConfig != pushed {
                    pushed = self.lgConfig
                    await current.updateConfig(pushed)
                }
            }

            guard sameTV else {
                self.showToast(
                    L10n.tr(
                        "电视设置在重置期间已更改，旧电视身份已清除；请确认当前电视后重新重置并配对",
                        "TV settings changed during the reset; the old TV identity was cleared. Check the current TV, then reset and pair again"
                    ),
                    isError: true
                )
                return false
            }
            self.showToast(L10n.tr("旧电视身份已清除，请在电视上确认重新配对", "Saved TV identity cleared; confirm the new pairing on your TV"))
            return true
        }
    }

    public func lgWebOSDiscoveryFailureMessage(hostHint: String? = nil) -> String {
        guard homeBackend != .demo else {
            return L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs")
        }
        let hint = (hostHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = hint.isEmpty ? lgConfig.host : hint
        return LGWebOSClient.discoveryFailureMessage(hostHint: effectiveHint)
    }

    public func discoverLGWebOSTVs(hostHint: String? = nil) async -> [LGWebOSDiscoveredTV] {
        // Demo mode is strictly offline: no LAN discovery (#47).
        guard homeBackend != .demo else { return [] }
        let hint = (hostHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = hint.isEmpty ? lgConfig.host : hint
        return await LGWebOSClient.discoverOnLAN(hostHint: effectiveHint)
    }

    /// Switches the visible Mi Home; nil shows every home's devices.
    public func selectMiHome(_ id: String?) {
        guard selectedMiHomeId != id else { return }
        invalidateUndoContext()
        if let id {
            userDefaults.set(id, forKey: MiCloudProvider.selectedHomeKey)
        } else {
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
        selectedMiHomeId = id
        selectRoom(nil)
        refreshNow()
    }

    public func refreshNow() {
        guard !allConfiguredSourcesTurnedOff, !isIdentityUncertain else { return }
        Task {
            await provider.refreshNow()
            if homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost, let lgClient = lgWebOSClient {
                await lgClient.start()
            }
        }
    }

    @discardableResult
    public func retryDeviceLAN(_ deviceId: String) -> Task<Void, Never> {
        let targetProvider = provider
        let lgClient = (homeBackend != .demo && lgConfig.isEnabled && lgConfig.hasConfiguredHost && deviceId == LGWebOSProtocol.deviceId)
            ? lgWebOSClient
            : nil
        return Task {
            await targetProvider.retryLAN(deviceId: deviceId)
            if let lgClient {
                await lgClient.start()
            }
        }
    }
}

// MARK: - Mi Session Expiry (#181)

extension HomeStore {
    private var effectiveMiSessionExpiresAt: Date? {
        if !miAccounts.isEmpty {
            return enabledMiAccounts.compactMap(\.session.expiresAt).min()
        }
        return miSessionExpiresAt
    }

    public var miSessionExpiryState: MiSessionExpiryState {
        let _ = miSessionExpiryRevision
        return MiSessionExpiryPolicy.state(expiresAt: effectiveMiSessionExpiresAt, now: Date())
    }

    /// Schedules a one-shot wake at the next boundary (`expiresAt - warningLeadTime` or `expiresAt`)
    /// so `@Observable` views update when a live session crosses into `.expiringSoon` or `.expired`.
    func scheduleMiSessionExpiryTransition(now: Date = Date()) {
        miSessionExpiryTimerTask?.cancel()
        miSessionExpiryTimerTask = nil
        let candidateEnds: [Date]
        if !miAccounts.isEmpty {
            candidateEnds = enabledMiAccounts.compactMap(\.session.expiresAt)
        } else {
            candidateEnds = [miSessionExpiresAt].compactMap { $0 }
        }
        let nextBoundary = candidateEnds
            .flatMap { [$0.addingTimeInterval(-MiSessionExpiryPolicy.warningLeadTime), $0] }
            .filter { $0 > now }
            .min()
        guard let nextBoundary else { return }
        let delay = max(0.05, nextBoundary.timeIntervalSince(now) + 0.05)
        miSessionExpiryTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.miSessionExpiryRevision &+= 1
            self.scheduleMiSessionExpiryTransition()
        }
    }

    /// Any active Xiaomi Cloud source (pure or dual-source) can name a session end; HA-only and demo never show this warning.
    private var usesMiSessionLifecycle: Bool {
        homeBackend != .demo
            && (hasEnabledMiSource || (!hasMiSource && homeBackend == .xiaomiCloud && isMiOnboardingBackendEnabled))
    }

    public var miSessionShowsExpired: Bool {
        guard usesMiSessionLifecycle else { return false }
        let _ = miSessionExpiryRevision
        if !miAccounts.isEmpty {
            let now = Date()
            return enabledMiAccounts.contains { $0.session.expiryState(at: now) == .expired }
        }
        return miSessionExpiryState == .expired
    }

    /// True when Xiaomi Cloud is the only enabled cloud source and every enabled account has expired,
    /// so no live cloud device can be controlled until the user scans again.
    public var miSessionBlocksControl: Bool {
        let _ = miSessionExpiryRevision
        guard miSessionShowsExpired, !hasEnabledHASource else { return false }
        let enabled = enabledMiAccounts
        guard !enabled.isEmpty else { return miAccounts.isEmpty }
        let now = Date()
        return enabled.allSatisfy { $0.session.expiryState(at: now) == .expired }
    }

    public var miSessionExpiringSoonDate: Date? {
        guard usesMiSessionLifecycle,
              case .expiringSoon(let expiresAt) = miSessionExpiryState else { return nil }
        return expiresAt
    }

    public func presentMiReauth() {
        guard usesMiSessionLifecycle,
              miSessionMaskedUserId != nil || !enabledMiAccounts.isEmpty else { return }
        let targetExpiry = effectiveMiSessionExpiresAt
        if let target = enabledMiAccounts.first(where: { $0.session.expiresAt == targetExpiry }) ?? enabledMiAccounts.first {
            miCloudRegion = target.region
        }
        isShowingMiReauth = true
    }

    public func dismissMiReauth() {
        isShowingMiReauth = false
    }

    public var effectiveLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> {
        effectiveLocalNetworkBlocks(for: localNetworkBlocks)
    }

    /// Resolves the raw blocked set against the sources that are actually switched on. The optional
    /// overrides let a `didSet` recompute the *previous* verdict after the stored value already
    /// changed (#268).
    func effectiveLocalNetworkBlocks(
        for rawBlocks: Set<LocalNetworkBlockedFeature>,
        backend: HomeBackend? = nil,
        hasHA: Bool? = nil,
        hasMi: Bool? = nil,
        lgConfig: LGWebOSConfig? = nil
    ) -> Set<LocalNetworkBlockedFeature> {
        let resolvedBackend = backend ?? homeBackend
        guard resolvedBackend != .demo else { return [] }
        let resolvedHasHA = hasHA ?? hasHASource
        let resolvedHasMi = hasMi ?? hasEnabledMiSource
        let resolvedLG = lgConfig ?? self.lgConfig
        var blocks = rawBlocks
        // `isHAConnectionEnabled` already folds in `hasHASource`, so it stays meaningful when the
        // caller overrides the source flag with the pre-change value.
        if !resolvedHasHA || !isHAConnectionEnabled { blocks.remove(.homeAssistant) }
        if !resolvedHasMi { blocks.remove(.xiaomiLAN) }
        if !resolvedLG.isEnabled || !resolvedLG.hasConfiguredHost { blocks.remove(.lgWebOS) }
        return blocks
    }

    func syncLocalNetworkBlockedNoticeDismissal(from oldEffective: Set<LocalNetworkBlockedFeature>) {
        let current = effectiveLocalNetworkBlocks
        if current.isEmpty || !current.isSubset(of: oldEffective) {
            dismissedActivityIds.remove("notice.localNetworkBlocked")
        }
    }

    /// The one connection verdict the footer, the settings badge and the menu-bar tooltip share.
    public var panelHealth: PanelHealth {
        let now = Date()
        let miStatus: ConnectionStatus = {
            if let explicit = sourceStatuses[.xiaomiCloud] {
                return explicit
            }
            if !hasEnabledHASource {
                return connectionStatus
            }
            if !miAccountStatuses.isEmpty {
                let activeIDs = Set(enabledMiAccounts.filter { $0.session.expiryState(at: now) != .expired }.map(\.id))
                if activeIDs.contains(where: { miAccountStatuses[$0]?.isConnected == true }) {
                    return .connected
                }
                for id in activeIDs {
                    if case .disconnected(let reason) = miAccountStatuses[id] {
                        return .disconnected(reason)
                    }
                }
                return .connecting
            }
            return connectedBackends.contains(.xiaomiCloud) ? .connected : .connecting
        }()
        return PanelHealthResolver.resolve(PanelHealthInput(
            isDemo: homeBackend == .demo,
            hasHASource: hasEnabledHASource,
            hasMiSource: hasEnabledMiSource,
            hasLGSource: hasConfiguredLGTVSource,
            miSessionBlocksControl: miSessionBlocksControl,
            miSessionShowsExpired: miSessionShowsExpired,
            haPlaintextDeclined: {
                guard isHAConnectionEnabled else { return false }
                if case .declined = haPlaintextPrompt { return true }
                return false
            }(),
            haStatus: sourceStatuses[.homeAssistant]
                ?? (connectedBackends.contains(.homeAssistant) ? .connected : .connecting),
            miStatus: miStatus,
            anotherMiAccountSignedIn: enabledMiAccounts.contains { account in
                account.session.expiryState(at: now) != .expired
            },
            deviceValuesAreStale: deviceValuesAreStale,
            connectionStatus: connectionStatus,
            localNetworkBlocks: effectiveLocalNetworkBlocks,
            allConfiguredSourcesTurnedOff: allConfiguredSourcesTurnedOff,
            identityMigrationDiagnostic: identityMigrationDiagnostic
        ))
    }
}

/// What the user can do from a blocked connection label or an error toast.
public enum PanelHealthAction: Equatable, Sendable {
    case presentMiReauth
    case openConnectionSettings
    case openLocalNetworkSettings
    case retryIdentityMigration
}

/// Connection health for every status surface. Derived, never stored.
public enum PanelHealth: Equatable, Sendable {
    case ok
    case connecting
    case degraded(reason: String)
    case blocked(reason: String, action: PanelHealthAction)
    case notConfigured
}

struct PanelHealthInput: Equatable, Sendable {
    var isDemo: Bool
    var hasHASource: Bool
    var hasMiSource: Bool
    var hasLGSource: Bool = false
    var miSessionBlocksControl: Bool
    var miSessionShowsExpired: Bool
    var haPlaintextDeclined: Bool
    /// Home Assistant's own connection state, not the merged aggregate: one healthy Mi account can
    /// keep the aggregate `.connected` while HA is offline.
    var haStatus: ConnectionStatus
    /// Xiaomi Cloud's own connection state, so a connected HA instance does not mask an offline or
    /// still-connecting Xiaomi Cloud source when reporting Local Network fallback.
    var miStatus: ConnectionStatus
    var anotherMiAccountSignedIn: Bool
    var deviceValuesAreStale: Bool
    var connectionStatus: ConnectionStatus
    var localNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    /// Every configured source exists but the user turned it off. Distinct from "nothing connected
    /// yet": the panel must not claim the user never configured anything (L1).
    var allConfiguredSourcesTurnedOff: Bool = false
    /// Non-nil when persisted capability selection or Keychain credentials failed to read at launch.
    /// Surfaces a retryable blocked state instead of claiming "nothing connected".
    var identityMigrationDiagnostic: String? = nil
}

/// Priority is the thing the user must deal with first.
/// An uncertain identity read fails closed ahead of demo and "nothing configured"; a blocked Mi
/// login hides a declined Home Assistant address, because each has its own recovery.
enum PanelHealthResolver {
    static func resolve(_ input: PanelHealthInput) -> PanelHealth {
        if input.identityMigrationDiagnostic != nil {
            return .blocked(
                reason: L10n.tr("配置或凭据读取受阻 · 点此重试", "Could not read settings or credentials · Retry"),
                action: .retryIdentityMigration
            )
        }
        if input.miSessionBlocksControl {
            return .blocked(
                reason: L10n.tr("米家登录已过期 · 点此扫码", "Xiaomi Home session expired · Scan to sign in"),
                action: .presentMiReauth
            )
        }
        if input.haPlaintextDeclined {
            let reason = L10n.tr(
                "Home Assistant 未连接（已拒绝明文）",
                "Home Assistant is not connected (plaintext declined)"
            )
            // Another signed-in Mi account is a working source even when one account expired;
            // `miSessionShowsExpired` covers any account, so it must not stand in for "all dead".
            let miStillWorks = input.hasMiSource && input.anotherMiAccountSignedIn && !input.isDemo
            if miStillWorks {
                return .degraded(reason: reason)
            }
            return .blocked(reason: reason, action: .openConnectionSettings)
        }
        if input.isDemo {
            return .ok
        }
        if input.allConfiguredSourcesTurnedOff {
            return .blocked(
                reason: L10n.tr("连接已停用 · 点此重新启用", "Connections turned off · Turn one back on"),
                action: .openConnectionSettings
            )
        }
        if !input.hasHASource && !input.hasMiSource && !input.hasLGSource {
            return .notConfigured
        }
        if !input.localNetworkBlocks.isEmpty {
            let haBlocked = input.hasHASource && input.localNetworkBlocks.contains(.homeAssistant)
            let miLANBlocked = input.hasMiSource && input.localNetworkBlocks.contains(.xiaomiLAN)
            let miWorking = input.hasMiSource && input.anotherMiAccountSignedIn && input.miStatus.isConnected && input.connectionStatus.isConnected
            let haWorking = input.hasHASource && !haBlocked && (input.haStatus.isConnected || (!input.hasMiSource && input.connectionStatus.isConnected))
            let blockedVerdict = PanelHealth.blocked(reason: L10n.tr("本地网络权限受阻 · 点此检查设置", "Local network access blocked · Check Settings"), action: .openLocalNetworkSettings)
            if haBlocked && miLANBlocked {
                return miWorking ? .degraded(reason: L10n.tr("本地网络权限受阻，当前仅米家云端可用", "Local network access is blocked. Using Xiaomi Cloud fallback")) : blockedVerdict
            }
            if haBlocked {
                return miWorking ? .degraded(reason: L10n.tr("Home Assistant 本地网络权限受阻，米家云端仍可用", "Home Assistant local network access is blocked. Xiaomi Cloud still works")) : blockedVerdict
            }
            if miLANBlocked {
                if miWorking {
                    return .degraded(reason: L10n.tr("米家局域网直连权限受阻，已回退云端", "Xiaomi LAN access is blocked. Using cloud fallback"))
                }
                if haWorking {
                    return .degraded(reason: L10n.tr("米家局域网直连权限受阻，当前仅 Home Assistant 可用", "Xiaomi LAN access is blocked. Only Home Assistant is available"))
                }
                return blockedVerdict
            }
            if input.localNetworkBlocks.contains(.lgWebOS) {
                return (miWorking || haWorking) ? .degraded(reason: L10n.tr("电视本地网络权限受阻", "TV local network access is blocked")) : blockedVerdict
            }
        }
        if !input.hasHASource && !input.hasMiSource && input.hasLGSource {
            return .ok
        }
        if input.miSessionShowsExpired, input.hasHASource,
           case .connected = input.connectionStatus, case .connected = input.haStatus {
            return .degraded(reason: L10n.tr(
                "米家登录已过期，Home Assistant 仍可用",
                "Xiaomi Home session expired. Home Assistant still works"
            ))
        }
        if input.miSessionShowsExpired, input.anotherMiAccountSignedIn {
            return .degraded(reason: L10n.tr(
                "有米家账号已过期，其他账号仍保持登录",
                "A Xiaomi Home account expired. Another account is still signed in."
            ))
        }
        if input.deviceValuesAreStale, case .connected = input.connectionStatus {
            return .degraded(reason: L10n.tr("设备状态可能过期", "Device states may be out of date"))
        }
        switch input.connectionStatus {
        case .connecting:
            return .connecting
        case .disconnected(let reason):
            let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = text.isEmpty
                ? L10n.tr("未连接", "Disconnected")
                : L10n.tr("未连接：\(text)", "Disconnected: \(text)")
            return .blocked(reason: label, action: .openConnectionSettings)
        case .connected:
            return .ok
        }
    }
}

public struct AllOffHeaderCopy: Equatable, Sendable {
    public var title: String
    public var helper: String?
    public var tooltip: String

    public static func make(
        activeDeviceCount: Int,
        targetNames: [String],
        scopeName: String?,
        excludedIncludesPlug: Bool
    ) -> AllOffHeaderCopy {
        let count = targetNames.count
        let title: String
        if let scopeName, !scopeName.isEmpty {
            title = L10n.tr("全关 \(scopeName) \(count) 台", "All Off \(count) in \(scopeName)")
        } else {
            title = L10n.tr("全关 \(count) 台", "All Off \(count)")
        }
        let excluded = activeDeviceCount - count
        let helper: String?
        if excluded > 0, excludedIncludesPlug {
            helper = L10n.tr("保留 \(excluded) 台开启（含插座）", "\(excluded) stay on (incl. plugs)")
        } else if excluded > 0 {
            helper = L10n.tr("保留 \(excluded) 台开启", "\(excluded) stay on")
        } else {
            helper = nil
        }
        let shown = targetNames.prefix(5)
        let list = shown.joined(separator: L10n.tr("、", ", "))
        let more = targetNames.count > 5 ? L10n.tr(" 等", "…") : ""
        let tooltip = list.isEmpty
            ? L10n.tr("按住 0.6 秒关闭这 \(count) 台", "Hold 0.6s to turn off these \(count)")
            : L10n.tr("按住 0.6 秒关闭：\(list)\(more)", "Hold 0.6s to turn off: \(list)\(more)")
        return AllOffHeaderCopy(title: title, helper: helper, tooltip: tooltip)
    }
}
