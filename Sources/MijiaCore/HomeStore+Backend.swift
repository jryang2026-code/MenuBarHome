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
        if hasHASource && hasMiSource {
            return "Home Assistant (\(haHost)) + \(miSummary)"
        }
        if hasMiSource {
            return miSummary
        }
        if hasHASource {
            return haHost
        }
        if homeBackend == .xiaomiCloud {
            return miSummary
        }
        return haHost
    }

    // MARK: - LG TV & Provider Events

    func startLGWebOSIfNeeded() {
        guard homeBackend != .demo else { return }
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
            }
        )
        let previousLG = self.lgWebOSClient
        if let previousLG {
            Task { await previousLG.shutdown() }
        }
        self.lgWebOSClient = client
        self.lgWebOSClientID = clientID
        if lgConfig.isEnabled && lgConfig.hasConfiguredHost {
            Task { await client.start() }
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

    func applyLGDeviceUpdate(_ dev: SmartDevice, fromClientID clientID: UUID? = nil) {
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
            if favoriteDeviceIds.contains(dev.id) == false && favoriteOrder.count < 8 {
                favoriteDeviceIds.insert(dev.id)
                favoriteOrder.insert(dev.id, at: 0)
            }
        }
        applyDeviceAliases()
        if !rooms.contains(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            rooms.append(RoomArea(id: dev.roomId, name: dev.roomName, sortOrder: 1))
        }
    }

    public func startListening() {
        hasReceivedInitialSnapshot = false
        connectedBackends = []
        deviceBackends = [:]
        deviceTransportDiagnostics = [:]
        localNetworkBlocks = []
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
        updatePollingContext { $0.panelVisible = visible }
    }

    /// False while the Mac or display sleeps, the screen is locked, or another user is active.
    public func setSystemActive(_ active: Bool) {
        if !active {
            awayGap.includesAway = true
            userDefaults.set(true, forKey: MacAwayGap.storageKey)
        }
        updatePollingContext { $0.systemActive = active }
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
        guard next != pollingContext else { return }
        pollingContext = next
        pushPollingContext()
    }

    /// Chained so quick open/close changes reach the provider in order.
    private func pushPollingContext() {
        let previous = pollingContextSync
        let target = provider
        let context = pollingContext
        pollingContextSync = Task {
            await previous?.value
            await target.setPollingContext(context)
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
        miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
        refreshMiAccountsAfterRejection()
    }

    /// Hands the live provider the list the rejection just changed, so that account's child is
    /// rebuilt around the stored end instead of waking on the dead token forever. The update rides
    /// the same serialized chain as a provider swap; every other account keeps its child and data.
    private func refreshMiAccountsAfterRejection() {
        guard let provider = activeMiAccountsProvider else { return }
        let accounts = miAccounts
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
            if connectionStatus != status { connectionStatus = status }
            if case .disconnected = status {
                connectedBackends = []
            } else if case .connected = status {
                if connectedBackends.isEmpty { connectedBackends = homeBackend == .demo ? [.demo] : [homeBackend] }
                if !hasMiSource { localNetworkBlocks.remove(.homeAssistant) }
            }

        case .sourceStatusesChanged(let statuses):
            if sourceStatuses != statuses { sourceStatuses = statuses }
            if case .connected = statuses[.homeAssistant],
               connectedBackends.contains(.homeAssistant) || (!hasMiSource && connectionStatus.isConnected) {
                localNetworkBlocks.remove(.homeAssistant)
            }

        case .localNetworkPermissionChanged(let blocked):
            if localNetworkBlocks != blocked { localNetworkBlocks = blocked }

        case .doorbellRang(let ring):
            handleDoorbellRing(ring)

        case .sessionExpired(let rejected):
            handleMiSessionRejected(rejected)

        case .snapshotUpdated(let snapshot):
            isApplyingProviderSnapshot = true
            snapshotGeneration &+= 1
            if selectedMiHomeId != nil, userDefaults.string(forKey: MiCloudProvider.selectedHomeKey) == nil {
                invalidateUndoContext()
                selectedMiHomeId = nil
                selectRoom(nil)
            }
            if !hasReceivedInitialSnapshot, snapshot.isInitialLoadComplete { hasReceivedInitialSnapshot = true }
            if !snapshot.accountStatuses.isEmpty, miAccountStatuses != snapshot.accountStatuses {
                miAccountStatuses = snapshot.accountStatuses
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
            if deviceBackends != snapshot.deviceBackends { deviceBackends = snapshot.deviceBackends }
            if pairedDeviceIDs != snapshot.pairedDeviceIDs { pairedDeviceIDs = snapshot.pairedDeviceIDs }
            if lightGroupOwners != snapshot.lightGroupOwners { lightGroupOwners = snapshot.lightGroupOwners }
            if sourceStatuses != snapshot.sourceStatuses { sourceStatuses = snapshot.sourceStatuses }
            if deviceTransportDiagnostics != snapshot.deviceTransportDiagnostics {
                deviceTransportDiagnostics = snapshot.deviceTransportDiagnostics
            }
            if localNetworkBlocks != snapshot.localNetworkBlockedFeatures {
                localNetworkBlocks = snapshot.localNetworkBlockedFeatures
            }
            var nextRooms = snapshot.rooms
            if var lgDev = latestLGDevice, lgConfig.isEnabled {
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

            for device in snapshot.devices {
                var incoming = device
                if case .cover(var cover) = incoming.kind {
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
                    for field in OptimisticField.primaryPowerFields(for: incoming.kind) {
                        optimisticFieldLocks.removeValue(forKey: .field(incoming.id, field))
                    }
                }
                var lockedFields = activeLockedFields(for: incoming.id, at: now)
                if lockedFields.contains(.coverPosition),
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
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
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
            var nextReportedDevices = Dictionary(
                snapshot.devices.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            if let lgDev = latestLGDevice, lgConfig.isEnabled, nextReportedDevices[lgDev.id] == nil {
                nextReportedDevices[lgDev.id] = lgDev
            }
            lastReportedDevices = nextReportedDevices
            lastReportedFacets = snapshot.deviceFacets
            var nextFacets: [String: [FacetControl]] = [:]
            for device in snapshot.devices {
                var lockedControlIds = activeLockedFacetControlIds(for: device.id, at: now)
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
            if deviceFacets != nextFacets { deviceFacets = nextFacets }

            // Compare the displayed names so aliases do not cause two observable writes per snapshot.
            let nextDevices = devicesWithAliases(merged)
            if devices != nextDevices { devices = nextDevices }
            removeActivitiesForMissingDevices()
            seedDefaultFavoritesIfNeeded()
            isApplyingProviderSnapshot = false
            let sampleNow = Date()
            scheduleRaycastSnapshotExport()
            energyHistory.record(devices: devices, deviceBackends: deviceBackends, now: sampleNow)
            sensorHistory.record(devices: devices, now: sampleNow)
            offlineHistory.record(devices: devices, now: sampleNow)

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

    func makeHAProvider(baseURLString: String, token: String) -> HAWebSocketProvider {
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
        return HAWebSocketProvider(
            baseURLString: baseURLString,
            token: token,
            onAddressSuggestion: callback,
            allowsToken: { HAPlaintextConsent.allowsToken(to: $0, defaults: defaults.defaults) },
            onPlaintextConsentNeeded: { @Sendable [weak self] url in
                Task { @MainActor [weak self] in
                    self?.askHAPlaintext(url)
                }
            },
            isNetworkSatisfied: { @MainActor [weak self] in self?.isNetworkSatisfiedForResume ?? true }
        )
    }

    /// Ignores a late callback from a provider that was already replaced, and keeps a declined
    /// answer so a refresh does not ask again until the address or the provider changes.
    func askHAPlaintext(_ url: String) {
        guard homeBackend != .demo,
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

    func makeLiveProvider() -> any HomeProvider {
        let token = loadHAToken()
        let active = activeBackends
        let wantsHA = active.contains(.homeAssistant)
        let wantsMi = active.contains(.xiaomiCloud)
        let ha: HAWebSocketProvider? = if wantsHA {
            makeHAProvider(baseURLString: serverURLString, token: token)
        } else {
            nil
        }
        activeHAProvider = ha
        activeHAConfig = wantsHA ? (url: HAWebSocketProvider.normalizeBaseURL(serverURLString), token: token) : nil
        let mi: MiAccountsProvider? = wantsMi ? makeMiAccountsProvider() : nil
        activeMiAccountsProvider = mi
        let composite = Self.makeComposite(
            homeAssistant: ha,
            xiaomiCloud: mi,
            defaults: userDefaults,
            pinBox: pinnedDeviceSourcesBox
        )
        activeDualProvider = composite
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

    private func rebuildLiveProvider(forceHAReconnect: Bool = false) {
        haPlaintextPrompt = nil
        guard let dual = activeDualProvider,
              provider as AnyObject === dual,
              homeBackend != .demo else {
            eventTask?.cancel()
            shutdownCurrentProvider()
            self.provider = makeLiveProvider()
            startListening()
            return
        }

        let token = loadHAToken()
        let active = activeBackends
        let wantsHA = active.contains(.homeAssistant)
        let wantsMi = active.contains(.xiaomiCloud)
        var nextHAReplacement: (shouldReplace: Bool, provider: HAWebSocketProvider?) = (false, nil)
        var haCredentialUpdate: (provider: HAWebSocketProvider, url: String, token: String)?
        if wantsHA {
            let normalizedURL = HAWebSocketProvider.normalizeBaseURL(serverURLString)
            if let existingHA = activeHAProvider {
                if forceHAReconnect || activeHAConfig?.url != normalizedURL || activeHAConfig?.token != token {
                    activeHAConfig = (url: normalizedURL, token: token)
                    haCredentialUpdate = (existingHA, serverURLString, token)
                }
            } else {
                let createdHA = makeHAProvider(baseURLString: serverURLString, token: token)
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
        var miAccountsUpdate: (provider: MiAccountsProvider, accounts: [MiAccount], invalidateSnapshot: Bool)?
        var miAccountsChanged = false
        if wantsMi {
            let latestAccounts = MiSessionStore.loadAccounts(defaults: userDefaults, vault: credentialVault)
            let previousAccounts = activeMiProviderAccounts
            miAccountsChanged = latestAccounts.count != previousAccounts.count
                || !zip(latestAccounts, previousAccounts).allSatisfy { $0.id == $1.id && $0.session == $1.session }
            let keptAnyAccount = latestAccounts.contains { next in
                previousAccounts.contains { $0.id == next.id && $0.session == next.session }
            }
            miAccounts = latestAccounts
            if let existingMi = activeMiAccountsProvider {
                if miAccountsChanged {
                    activeMiProviderAccounts = latestAccounts
                    miAccountsUpdate = (existingMi, latestAccounts, !keptAnyAccount && !latestAccounts.isEmpty)
                }
            } else {
                let createdMi = makeMiAccountsProvider()
                activeMiAccountsProvider = createdMi
                nextMiReplacement = (true, createdMi)
            }
        } else if activeMiAccountsProvider != nil {
            activeMiAccountsProvider = nil
            nextMiReplacement = (true, nil)
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
                await dual.setSourceProvider(ha, for: .homeAssistant)
            }
            if nextMiReplacement.shouldReplace, let mi = nextMiReplacement.provider {
                await dual.setSourceProvider(mi, for: .xiaomiCloud)
            }
            if nextHAReplacement.shouldReplace, nextHAReplacement.provider == nil {
                await dual.setSourceProvider(nil, for: .homeAssistant)
            }
            if nextMiReplacement.shouldReplace, nextMiReplacement.provider == nil {
                await dual.setSourceProvider(nil, for: .xiaomiCloud)
            }
            if let u = miAccountsUpdate {
                if u.invalidateSnapshot { await dual.invalidateSnapshot(for: .xiaomiCloud) }
                await u.provider.updateAccounts(u.accounts)
            }
        }
    }

    /// Shows a found address as a question instead of switching to it (#18). An address whose instance id
    /// differs from the Home Assistant the user chose before is ignored.
    public func offerHAAddress(_ instance: HADiscoveredInstance) {
        guard homeBackend != .demo else { return }
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
        self.homeBackend = backend
        if backend == .demo {
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
        guard wasDemo, homeBackend != .demo else { return }
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

    public func completeMiLogin(_ session: MiSession) {
        guard MiSessionStore.upsert(session, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        // The primary (first) account drives the summary and the history scope, so signing in a
        // second account must not relabel the panel with the newcomer.
        miAccounts = MiSessionStore.loadAccounts(defaults: userDefaults, vault: credentialVault)
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
        self.isShowingMiReauth = false
        self.miSessionScopeIdentifier = miAccounts.first?.session.historyScopeIdentifier
        let previousRegion = miCloudRegion
        if let region = MiCloudRegion(rawValue: session.region.lowercased()) {
            self.miCloudRegion = region
        }
        let regionChanged = miCloudRegion != previousRegion
        let superseded = miLoginStartBackend.map { $0 != homeBackend } ?? false
        miLoginStartBackend = nil
        if superseded { return }
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
    }

    /// Returns false when the Keychain/vault refused to delete the stored Mi session; the in-memory
    /// account is still signed out so the UI does not keep showing it.
    @discardableResult
    public func logoutMiAccount() -> Bool {
        let cleared = MiSessionStore.clear(defaults: userDefaults, vault: credentialVault)
        topologyCache?.removeAll()
        miAccounts = []
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
        showToast(L10n.tr("已退出米家账号", "Signed out of Xiaomi Home"))
        return cleared
    }

    /// The single destructive entry point behind Settings → 隐私 → 退出并吊销令牌 (#143): signs out
    /// every Mi account, deletes the Home Assistant token and drops that connection, forgets saved AI
    /// keys and cloud-consent records. Local preferences, aliases and history stay untouched.
    /// Returns false and shows an error when any credential survived the deletion.
    @discardableResult
    public func signOutAndRevokeAll() -> Bool {
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
        if complete {
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
        guard KeychainHelper.saveToken("", defaults: userDefaults, vault: credentialVault) else {
            return false
        }
        hasHASource = false
        pendingHAAddressSuggestion = nil
        haPlaintextPrompt = nil
        localNetworkBlocks.remove(.homeAssistant)
        guard homeBackend != .demo,
              (provider is DualSourceHomeProvider || provider is HAWebSocketProvider) else { return true }
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
        return true
    }

    /// Removes one account and keeps the rest: its devices, readings, rooms and homes leave the panel
    /// right away instead of waiting for the next merged snapshot.
    public func logoutMiAccount(id: String) {
        guard MiSessionStore.remove(accountID: id, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法更新钥匙串，请授权钥匙串访问后重试", "Could not update Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        topologyCache?.remove(accountID: id)
        invalidateUndoContext()
        miAccounts = MiSessionStore.loadAccounts(defaults: userDefaults, vault: credentialVault)
        miAccountStatuses.removeValue(forKey: id)
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = miAccounts.first?.session.historyScopeIdentifier
        if let home = selectedMiHomeId, MiAccountScope.isOwned(home, by: id) {
            selectedMiHomeId = nil
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
        if homeBackend == .xiaomiCloud || provider is DualSourceHomeProvider {
            let removedDeviceIds = Set(devices.filter { $0.accountId == id }.map(\.id))
            devices.removeAll { $0.accountId == id }
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
            rebuildLiveProvider()
        }
        showToast(miAccounts.isEmpty
            ? L10n.tr("已退出米家账号", "Signed out of Xiaomi Home")
            : L10n.tr("已移除米家账号", "Removed Xiaomi account"))
    }

    private func shutdownCurrentProvider() {
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

    public func updateConnection(serverURL: String, token: String) {
        // A refused Keychain write must not report "Saved": the token would be gone after relaunch.
        guard KeychainHelper.saveToken(token, defaults: userDefaults, vault: credentialVault) else {
            showToast(
                L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        let wasDemo = homeBackend == .demo
        invalidateUndoContext()
        let normalized = HAWebSocketProvider.normalizeBaseURL(serverURL)
        if normalized != HAWebSocketProvider.normalizeBaseURL(serverURLString) {
            rememberHAInstanceId(forURL: normalized)
        }
        pendingHAAddressSuggestion = nil
        self.serverURLString = normalized
        self.hasHASource = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.homeBackend = preferredLiveBackend
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.completeOnboarding()
        }
        rebuildLiveProvider()
        resumeLGWebOSAfterLeavingDemoIfNeeded(wasDemo: wasDemo)
        showToast(L10n.tr("已保存并重新连接 Home Assistant", "Saved and reconnecting to Home Assistant"))
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
        if reconnectProvider {
            if let haProvider = provider as? HAWebSocketProvider {
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
        guard homeBackend != .demo, homeBackend != .xiaomiCloud else { return false }
        guard !hasHASource, !hasMiSource else { return false }
        if let lastAutoHADiscoveryAt,
           ContinuousClock.now - lastAutoHADiscoveryAt < Self.autoHADiscoveryCooldown {
            return false
        }
        return true
    }

    @discardableResult
    public func discoverHomeAssistantOnLAN(autoApplyIfDefault: Bool = false) async -> [HADiscoveredInstance] {
        // Demo mode is strictly offline: no LAN discovery, no network probe (#47).
        guard homeBackend != .demo else { return [] }
        if autoApplyIfDefault {
            guard shouldAutoDiscoverHomeAssistantOnLAN else { return discoveredHAInstances }
            lastAutoHADiscoveryAt = ContinuousClock.now
        }
        guard !isDiscoveringHA else { return discoveredHAInstances }
        isDiscoveringHA = true
        defer { isDiscoveringHA = false }
        let discoverer = haLANDiscoverer
        let found = await discoverer(serverURLString)
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
        if let lgClient = lgWebOSClient {
            Task {
                await lgClient.updateConfig(newConfig)
            }
        } else {
            startLGWebOSIfNeeded()
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
        guard lgConfig.hasConfiguredHost, let client = lgWebOSClient else { return nil }
        let host = lgConfig.host
        return Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            guard !Task.isCancelled, self.lgWebOSClient === client, self.lgConfig.host == host else { return false }
            let previousConfig = self.lgConfig
            var cleared = previousConfig
            cleared.clientKey = ""
            let pairingVault: CredentialVault? = self.credentialVault
                ?? (self.userDefaults === UserDefaults.standard ? .shared : nil)

            // When trust and pairing key share a CredentialVault, clear both in one atomic Keychain
            // commit before stopping the client. Otherwise persist the cleared config first, then
            // reset trust (rolling back on error) so no failure leaves a split state.
            let clearedKeyAtomically: Bool
            if let pairingVault, await client.trustStoreSharesVault(pairingVault) {
                do {
                    clearedKeyAtomically = try await client.resetTrust(
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
                guard cleared.save(to: self.userDefaults, vault: self.credentialVault) else {
                    self.lgConfigSaveFailed = true
                    self.showToast(Self.lgKeychainSaveErrorMessage, isError: true)
                    return false
                }
                do {
                    clearedKeyAtomically = try await client.resetTrust(expectedHost: host)
                } catch {
                    _ = previousConfig.save(to: self.userDefaults, vault: self.credentialVault)
                    self.lgConfigSaveFailed = true
                    let message: String = (error as? LGCertificateTrust.Failure == .unavailable)
                        ? Self.lgKeychainSaveErrorMessage
                        : error.localizedDescription
                    self.showToast(message, isError: true)
                    return false
                }
            }

            guard self.lgConfig.host == host, self.lgWebOSClient === client else { return false }
            if clearedKeyAtomically {
                // Keep UserDefaults metadata / legacy cleanup in sync; the vault slot is already nil,
                // so `save` returns immediately without performing a second Keychain write.
                guard cleared.save(to: self.userDefaults, vault: self.credentialVault) else {
                    _ = previousConfig.save(to: self.userDefaults, vault: self.credentialVault)
                    self.lgConfigSaveFailed = true
                    self.showToast(Self.lgKeychainSaveErrorMessage, isError: true)
                    return false
                }
            }

            self.lgConfigSaveFailed = false
            self.suppressNextLGConfigDidSetSave = true
            self.lgConfig = cleared
            self.suppressNextLGConfigDidSetSave = false
            await client.updateConfig(cleared)
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
        Task {
            await provider.refreshNow()
            if homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost, let lgClient = lgWebOSClient {
                await lgClient.start()
            }
        }
    }
}

// MARK: - Mi Session Expiry (#181)

extension HomeStore {
    public var miSessionExpiryState: MiSessionExpiryState {
        let _ = miSessionExpiryRevision
        return MiSessionExpiryPolicy.state(expiresAt: miSessionExpiresAt, now: Date())
    }

    /// Schedules a one-shot wake at the next boundary (`expiresAt - warningLeadTime` or `expiresAt`)
    /// so `@Observable` views update when a live session crosses into `.expiringSoon` or `.expired`.
    func scheduleMiSessionExpiryTransition(now: Date = Date()) {
        miSessionExpiryTimerTask?.cancel()
        miSessionExpiryTimerTask = nil
        let accountEnds = miAccounts.compactMap(\.session.expiresAt)
        let candidateEnds = accountEnds.isEmpty ? [miSessionExpiresAt].compactMap { $0 } : accountEnds
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
        homeBackend != .demo && (homeBackend == .xiaomiCloud || hasMiSource)
    }

    public var miSessionShowsExpired: Bool {
        usesMiSessionLifecycle && miSessionExpiryState == .expired
    }

    /// True when Xiaomi Cloud is the only configured source and every signed-in account has expired,
    /// so no live device can be controlled until the user scans again.
    public var miSessionBlocksControl: Bool {
        let _ = miSessionExpiryRevision
        guard miSessionShowsExpired, !hasHASource else { return false }
        guard !miAccounts.isEmpty else { return true }
        let now = Date()
        return miAccounts.allSatisfy { $0.session.expiryState(at: now) == .expired }
    }

    public var miSessionExpiringSoonDate: Date? {
        guard usesMiSessionLifecycle,
              case .expiringSoon(let expiresAt) = miSessionExpiryState else { return nil }
        return expiresAt
    }

    public func presentMiReauth() {
        guard usesMiSessionLifecycle,
              miSessionMaskedUserId != nil || !miAccounts.isEmpty else { return }
        if let target = miAccounts.first(where: { $0.session.expiresAt == miSessionExpiresAt }) ?? miAccounts.first {
            miCloudRegion = target.region
        }
        isShowingMiReauth = true
    }

    public func dismissMiReauth() {
        isShowingMiReauth = false
    }

    public var effectiveLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> {
        guard homeBackend != .demo else { return [] }
        var blocks = localNetworkBlocks
        if !hasHASource { blocks.remove(.homeAssistant) }
        if !hasMiSource { blocks.remove(.xiaomiLAN) }
        if !lgConfig.isEnabled || !lgConfig.hasConfiguredHost { blocks.remove(.lgWebOS) }
        return blocks
    }

    /// The one connection verdict the footer, the settings badge and the menu-bar tooltip share.
    public var panelHealth: PanelHealth {
        PanelHealthResolver.resolve(PanelHealthInput(
            isDemo: homeBackend == .demo,
            hasHASource: hasHASource,
            hasMiSource: hasMiSource,
            miSessionBlocksControl: miSessionBlocksControl,
            miSessionShowsExpired: miSessionShowsExpired,
            haPlaintextDeclined: {
                if case .declined = haPlaintextPrompt { return true }
                return false
            }(),
            haStatus: sourceStatuses[.homeAssistant]
                ?? (connectedBackends.contains(.homeAssistant) ? .connected : .connecting),
            anotherMiAccountSignedIn: miAccounts.contains { account in
                account.session.expiryState(at: Date()) != .expired
            },
            deviceValuesAreStale: deviceValuesAreStale,
            connectionStatus: connectionStatus,
            localNetworkBlocks: effectiveLocalNetworkBlocks
        ))
    }
}

/// What the user can do from a blocked connection label or an error toast.
public enum PanelHealthAction: Equatable, Sendable {
    case presentMiReauth
    case openConnectionSettings
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
    var miSessionBlocksControl: Bool
    var miSessionShowsExpired: Bool
    var haPlaintextDeclined: Bool
    /// Home Assistant's own connection state, not the merged aggregate: one healthy Mi account can
    /// keep the aggregate `.connected` while HA is offline.
    var haStatus: ConnectionStatus
    var anotherMiAccountSignedIn: Bool
    var deviceValuesAreStale: Bool
    var connectionStatus: ConnectionStatus
    var localNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
}

/// Priority is the thing the user must deal with first.
/// A blocked Mi login hides a declined Home Assistant address, and a declined address hides
/// "nothing configured", because each of those has its own recovery.
enum PanelHealthResolver {
    static func resolve(_ input: PanelHealthInput) -> PanelHealth {
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
        if !input.hasHASource && !input.hasMiSource {
            return .notConfigured
        }
        if !input.localNetworkBlocks.isEmpty {
            let haBlocked = input.hasHASource && input.localNetworkBlocks.contains(.homeAssistant)
            let miLANBlocked = input.hasMiSource && input.localNetworkBlocks.contains(.xiaomiLAN)
            let miWorking = input.hasMiSource && input.anotherMiAccountSignedIn && input.connectionStatus.isConnected
            let haWorking = input.hasHASource && !haBlocked && (input.haStatus.isConnected || (!input.hasMiSource && input.connectionStatus.isConnected))
            let blockedVerdict = PanelHealth.blocked(reason: L10n.tr("本地网络权限受阻 · 点此检查设置", "Local network access blocked · Check Settings"), action: .openConnectionSettings)
            if haBlocked && miLANBlocked {
                return miWorking ? .degraded(reason: L10n.tr("本地网络权限受阻，当前仅米家云端可用", "Local network access is blocked. Using Xiaomi Cloud fallback")) : blockedVerdict
            }
            if haBlocked {
                return miWorking ? .degraded(reason: L10n.tr("Home Assistant 本地网络权限受阻，米家云端仍可用", "Home Assistant local network access is blocked. Xiaomi Cloud still works")) : blockedVerdict
            }
            if miLANBlocked {
                return (miWorking || haWorking) ? .degraded(reason: L10n.tr("米家局域网直连权限受阻，已回退云端", "Xiaomi LAN access is blocked. Using cloud fallback")) : blockedVerdict
            }
            if input.localNetworkBlocks.contains(.lgWebOS) {
                return (miWorking || haWorking) ? .degraded(reason: L10n.tr("电视本地网络权限受阻", "TV local network access is blocked")) : blockedVerdict
            }
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
