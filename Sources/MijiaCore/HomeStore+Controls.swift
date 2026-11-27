import Foundation

// Primary toggle and detail-drawer controls backed by optimistic state (#48).
extension HomeStore {
    @discardableResult
    func confirmManualControl(intents: [DeviceIntent]) -> UserHabitMemory.RecordingReceipt? {
        guard isHabitLearningEnabled, !intents.isEmpty else { return nil }
        var memory = userHabitMemory
        let receipt = memory.record(utterance: nil, intents: intents, devices: devices, scenes: scenes)
        userHabitMemory = memory
        return receipt
    }

    // MARK: - Primary Toggle & Manual Light Memory

    /// Copy for the persistent expired-session toast and for external callers reporting it.
    public nonisolated static var miSessionBlockedMessage: String {
        L10n.tr("米家登录已过期", "Xiaomi Home session expired")
    }

    /// Shows the persistent expiry toast and returns true when the write must be refused.
    /// `needsMi` is false for a command the LAN LG client answers, which needs no Mi session.
    @discardableResult
    func rejectWritesBlockedByMiSession(needsMi: Bool = true) -> Bool {
        guard needsMi, miSessionBlocksControl else { return false }
        showSessionExpiryToast()
        return true
    }

    /// True when a primary toggle of this row would be sent over the Mi provider, so the expired
    /// session refuses it. Mirrors the gate at the top of `togglePrimary`.
    public func primaryToggleNeedsMiSession(_ device: SmartDevice) -> Bool {
        !lgClientServes(device)
    }

    /// The external error for a failed toggle. The session refusal is decided by the session and
    /// the command's route, not by which toast happens to be on screen: the prompt can be suspended
    /// behind an earlier result, and a second blocked tap creates no new toast.
    public func primaryToggleFailureMessage(_ fallback: String, for device: SmartDevice) -> String {
        if miSessionBlocksControl, primaryToggleNeedsMiSession(device) {
            return Self.miSessionBlockedMessage
        }
        return fallback
    }

    /// The persistent prompt that carries the only way back into the blocked account.
    func showSessionExpiryToast() {
        showToast(
            Self.miSessionBlockedMessage,
            isError: true,
            action: ToastAction(title: L10n.tr("扫码", "Scan"), kind: .presentMiReauth),
            persistent: true
        )
    }

    private enum ConfirmedPrimaryAction: Equatable {
        case lightPower(entityId: String, isOn: Bool)
        case climatePower(entityId: String, isOn: Bool)
        case fanPower(entityId: String, isOn: Bool)
        case plugButton(entityId: String)
        case plugPower(entityId: String, isOn: Bool)
        case vacuum(entityId: String, startCleaning: Bool)
        case tv(mediaEntityId: String, turnOn: Bool)
        case cameraPower(entityId: String, isOn: Bool)
        case coverPause(entityId: String)
        case coverMove(entityId: String, shouldOpen: Bool)
        case appliancePower(powerEntityId: String, isOn: Bool)
        case genericPower(controlId: String, target: FacetTarget, isOn: Bool)
        case humidifierPower(entityId: String, isOn: Bool)
        case valvePower(entityId: String, open: Bool)
    }

    private func primaryPlan(for device: SmartDevice) -> (ConfirmedPrimaryAction, IntentOperation?)? {
        let planned: ConfirmedPrimaryAction
        let promptOperation: IntentOperation?
        switch device.kind {
        case .light(let s):
            let nextOn = !s.isOn
            planned = .lightPower(entityId: s.entityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .climate(let s):
            let nextOn = !s.isOn
            planned = .climatePower(entityId: s.entityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .fan(let s):
            let nextOn = !s.isOn
            planned = .fanPower(entityId: s.entityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .plug(let s):
            if s.switchEntityId.hasPrefix("button.") {
                // A momentary plug button may toggle or trigger something; treat it as an activation.
                planned = .plugButton(entityId: s.switchEntityId)
                promptOperation = .power(true)
            } else {
                let nextOn = !s.isOn
                planned = .plugPower(entityId: s.switchEntityId, isOn: nextOn)
                promptOperation = .power(nextOn)
            }
        case .vacuum(let s):
            let startCleaning = !s.isCleaning
            planned = .vacuum(entityId: s.entityId, startCleaning: startCleaning)
            promptOperation = .power(startCleaning)
        case .tv(let s):
            let turnOn = (s.state == "off" || s.state == "standby")
            planned = .tv(mediaEntityId: s.mediaEntityId, turnOn: turnOn)
            promptOperation = .power(turnOn)
        case .camera(let s):
            let nextOn = !s.isOn
            planned = .cameraPower(entityId: s.entityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .cover(let s):
            if s.isMoving {
                // Stopping a moving cover is a de-escalation action (or expands the drawer if
                // pause is unavailable) and never asks for hazard confirmation (#298).
                planned = .coverPause(entityId: s.entityId)
                promptOperation = nil
            } else if let pos = s.positionPercent,
                      (pos == 0 ? s.openDescription : s.closeDescription) != nil {
                let shouldOpen = pos == 0
                planned = .coverMove(entityId: s.entityId, shouldOpen: shouldOpen)
                promptOperation = .power(shouldOpen)
            } else {
                return nil
            }
        case .appliance(let s):
            let nextOn = !s.isOn
            planned = .appliancePower(powerEntityId: s.powerEntityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .generic(let s):
            guard let control = s.powerControl,
                  let target = control.target,
                  case .property = target else {
                return nil
            }
            let nextOn = !s.isOn
            planned = .genericPower(controlId: control.id, target: target, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .humidifier(let s):
            let nextOn = !s.isOn
            planned = .humidifierPower(entityId: s.entityId, isOn: nextOn)
            promptOperation = .power(nextOn)
        case .valve(let s):
            let opening = !s.isOpen
            guard opening ? s.openWritable : s.closeWritable else { return nil }
            planned = .valvePower(entityId: s.entityId, open: opening)
            promptOperation = .power(opening)
        case .speaker, .fridge, .sensor:
            return nil
        }

        return (planned, promptOperation)
    }

    @discardableResult
    public func togglePrimary(_ device: SmartDevice, offersSwitchLightMark: Bool = true) -> Task<Bool, Never>? {
        togglePrimary(device, offersSwitchLightMark: offersSwitchLightMark, panelConfirmed: false)
    }

    private func togglePrimary(
        _ device: SmartDevice, offersSwitchLightMark: Bool, panelConfirmed: Bool
    ) -> Task<Bool, Never>? {
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: device.id) != nil { return nil }
        // A tap on an LG TV is answered over the LAN, so the expired Mi session does not refuse it.
        guard !rejectWritesBlockedByMiSession(needsMi: !servedWithoutMiSession(device)) else { return nil }
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return nil }
        let initial = devices[idx]
        guard initial.isOnline else {
            showToast(L10n.tr("\(initial.name) 当前离线（可能断电）", "\(initial.name) is offline (unplugged)"), isError: true)
            return nil
        }
        guard device.isPrimaryToggleable else {
            if hasDetailDrawer(for: device) { toggleExpanded(device.id) }
            return nil
        }
        guard !rejectControlWhileLocked() else { return nil }

        guard let (planned, promptOperation) = primaryPlan(for: initial) else {
            if case .valve = initial.kind { return nil }
            toggleExpanded(device.id)
            return nil
        }

        let modalContext = captureModalDeviceContext(for: initial)
        var didPresentModal = false
        if let promptOperation {
            let marks = SwitchLightMarks.load(defaults: userDefaults)
            if ManualControlPolicy.requiresConfirmation(promptOperation, for: initial, markedLightIds: marks) {
                didPresentModal = true
            }
            guard panelConfirmed || allowManualControl(promptOperation, for: initial, offersMarkAsLight: offersSwitchLightMark) else { return nil }
        }

        let current: SmartDevice
        if didPresentModal {
            guard let resolved = resolvePostModalDevice(
                modalContext,
                requireOnline: true,
                showOfflineToast: true
            ) else { return nil }
            guard resolved.isPrimaryToggleable else {
                showPostModalDeviceChangedToast()
                return nil
            }
            if let promptOperation,
               rejectChangedPostModalHazard(
                   promptOperation,
                   on: resolved,
                   captured: modalContext,
                   didPresentModal: true
               ) {
                return nil
            }
            current = resolved
        } else {
            current = initial
        }

        var updated = current
        var command: DeviceCommand?
        // The cover travel origin this tap writes before the send. A tap that never reaches the
        // device must put it back, or a genuine report at that position is rejected later.
        var coverOrigin: (prior: Int?, written: Int)?
        let lockRevision = optimisticLockRevision[current.id]

        switch (planned, updated.kind) {
        case (.lightPower(let eid, let isOn), .light(var s)) where s.entityId == eid && s.powerWritable:
            s.isOn = isOn
            updated.kind = .light(s)
            command = .setLightPower(entityId: s.entityId, isOn: isOn)

        case (.climatePower(let eid, let isOn), .climate(var s)) where s.entityId == eid && s.powerWritable:
            s.isOn = isOn
            let targetMode = isOn ? (s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode) : "off"
            s.hvacMode = targetMode
            updated.kind = .climate(s)
            command = .setClimatePower(entityId: s.entityId, isOn: isOn, fallbackMode: targetMode)

        case (.fanPower(let eid, let isOn), .fan(var s)) where s.entityId == eid && s.powerWritable:
            s.isOn = isOn
            updated.kind = .fan(s)
            command = .setFanPower(entityId: s.entityId, isOn: isOn)

        case (.plugButton(let eid), .plug(let s)) where s.switchEntityId == eid && s.powerWritable:
            command = .pressButton(entityId: s.switchEntityId)

        case (.plugPower(let eid, let isOn), .plug(var s)) where s.switchEntityId == eid && s.powerWritable:
            s.isOn = isOn
            updated.kind = .plug(s)
            command = .setSwitch(entityId: s.switchEntityId, isOn: isOn)

        case (.vacuum(let eid, let startCleaning), .vacuum(var s)) where s.entityId == eid:
            s.status = startCleaning ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            command = .vacuumAction(entityId: s.entityId, action: startCleaning ? .start : .returnToBase)

        case (.tv(let mediaEid, let turnOn), .tv(var s)) where s.mediaEntityId == mediaEid && s.powerWritable:
            s.state = turnOn ? "on" : "standby"
            if turnOn { s.isScreenOff = false }
            updated.kind = .tv(s)
            if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
                command = .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: turnOn)
            } else if turnOn, let btnId = s.turnOnButtonId {
                command = .pressButton(entityId: btnId)
            } else if turnOn, let actionId = s.powerOnActionId {
                command = .pressButton(entityId: actionId)
            } else if !turnOn, let actionId = s.powerOffActionId {
                command = .pressButton(entityId: actionId)
            } else if MiotAddress.parse(s.mediaEntityId) != nil || s.mediaEntityId.hasPrefix("media_player.") {
                command = .setSwitch(entityId: s.mediaEntityId, isOn: turnOn)
            } else {
                toggleExpanded(current.id)
                return nil
            }

        case (.cameraPower(let eid, let isOn), .camera(var s)) where s.entityId == eid && s.powerWritable:
            s.isOn = isOn
            updated.kind = .camera(s)
            command = .setSwitch(entityId: s.entityId, isOn: isOn)

        case (.coverPause(let eid), .cover(var s)) where s.entityId == eid:
            // A cover tap is a three-way control: travel stops, otherwise open/close. Pause needs
            // no position reading, so a moving cover stops before the position guard (#298).
            // The stored origin is kept before `activeCoverOrigin` can drop a stale one: a tap whose
            // claim fails has to leave the in-flight tap's origin in place.
            let priorOrigin = coverCommandOrigins[current.id]
            let origin = activeCoverOrigin(for: current.id, fallback: s.positionPercent)
            guard let pause = s.pauseDescription else {
                toggleExpanded(current.id)
                return nil
            }
            s.motion = .stopped
            s.motionIsInferred = false
            updated.kind = .cover(s)
            if let origin {
                coverOrigin = (priorOrigin, origin)
                coverCommandOrigins[current.id] = origin
            }
            command = .setSelectOption(entityId: s.entityId, option: pause)

        case (.coverMove(let eid, let shouldOpen), .cover(var s)) where s.entityId == eid:
            let priorOrigin = coverCommandOrigins[current.id]
            let latestPos = lastCoverPositions[current.id] ?? s.reportedPositionPercent ?? s.positionPercent
            _ = activeCoverOrigin(for: current.id, fallback: latestPos)
            guard let action = (shouldOpen ? s.openDescription : s.closeDescription) else {
                if didPresentModal {
                    showPostModalDeviceChangedToast()
                } else {
                    toggleExpanded(current.id)
                }
                return nil
            }
            if let latestPos {
                coverOrigin = (priorOrigin, latestPos)
                coverCommandOrigins[current.id] = latestPos
            }
            s.positionPercent = shouldOpen ? 100 : 0
            s.motion = shouldOpen ? .opening : .closing
            s.motionIsInferred = false
            updated.kind = .cover(s)
            command = .setSelectOption(entityId: s.entityId, option: action)

        case (.appliancePower(let powerEid, let isOn), .appliance(var s))
            where s.powerEntityId == powerEid && s.powerPresent && s.powerWritable:
            s.isOn = isOn
            updated.kind = .appliance(s)
            command = .setSwitch(entityId: s.powerEntityId, isOn: isOn)

        case (.genericPower(let cid, let expectedTarget, let isOn), .generic(var s)):
            guard let control = s.powerControl,
                  control.id == cid,
                  control.target == expectedTarget,
                  case .property(let entityId, let piid) = control.target else {
                if didPresentModal {
                    showPostModalDeviceChangedToast()
                } else {
                    toggleExpanded(current.id)
                }
                return nil
            }
            s.isOn = isOn
            s.powerControl?.value = .bool(isOn)
            updated.kind = .generic(s)
            command = .setMiotProperty(entityId: entityId, piid: piid, value: .bool(isOn))

        case (.humidifierPower(let eid, let isOn), .humidifier(var s)) where s.entityId == eid && s.powerWritable:
            s.isOn = isOn
            updated.kind = .humidifier(s)
            command = .setSwitch(entityId: s.entityId, isOn: isOn)

        case (.valvePower(let eid, let open), .valve(var s))
            where s.entityId == eid && (open ? s.openWritable : s.closeWritable):
            s.isOpen = open
            s.motion = nil
            updated.kind = .valve(s)
            command = .setSwitch(entityId: s.entityId, isOn: open)

        default:
            if didPresentModal { showPostModalDeviceChangedToast() }
            return nil
        }

        guard let cmd = command else { return nil }
        let context = modalContext.controlContextID
        let deviceId = current.id
        let isMomentaryButton = current.isMomentaryButton
        if isMomentaryButton {
            return Task {
                guard self.matchesModalDeviceContext(modalContext) else { return false }
                do {
                    try await self.executeDeviceCommand(cmd)
                    guard self.controlContextID == context else { return false }
                    let displayName = self.devices.first(where: { $0.id == deviceId })?.name ?? current.name
                    self.showToast(L10n.tr("已触发 \(displayName)", "Triggered \(displayName)"), isError: false)
                    return true
                } catch {
                    guard self.controlContextID == context else { return false }
                    let displayName = self.devices.first(where: { $0.id == deviceId })?.name ?? current.name
                    self.showToast(L10n.tr("\(displayName) 触发失败", "Failed to trigger \(displayName)"), isError: true)
                    return false
                }
            }
        }

        guard let ticket = self.readBackTickets.claim(deviceId) else {
            // An earlier tap still owns the read-back, so this one never sends; it must not leave
            // its own travel origin behind.
            self.discardCoverOrigin(coverOrigin, deviceId: deviceId, revision: lockRevision)
            return nil
        }
        self.clearManualWriteSession(for: deviceId, bumpRevision: coverOrigin == nil)
        let writeEpoch = writeEpochNow()
        for field in OptimisticField.primaryPowerFields(for: current.kind) {
            fieldWriteEpochs[.field(deviceId, field)] = writeEpoch
        }

        // A cover is write-only: the motor reports its position only after it moves, so the
        // commanded row and travel origin are shown and locked before the send. A snapshot that
        // lands while the command is in flight is then held instead of replacing the row and
        // dropping the origin the takeover rule needs (#298 follow-up). The unexpired lock this
        // tap replaces is kept so a failed send can put it back.
        var coverWrite: OptimisticWrite?
        var coverPriorLockEntry: OptimisticLockEntry?
        if case .cover = updated.kind {
            let now = optimisticNow()
            let continuousNow = ContinuousClock.now
            coverPriorLockEntry = optimisticFieldLocks[.field(deviceId, .coverPosition)]
                .flatMap { isOptimisticEntryActive($0, at: now, continuousNow: continuousNow) ? $0 : nil }
            coverWrite = beginOptimisticWrite(from: current, to: updated, lock: coverOptimisticLockDuration)
        }

        return Task {
            defer { self.readBackTickets.finish(deviceId, ticket: ticket) }
            guard self.matchesModalDeviceContext(modalContext) else {
                if self.controlContextID == context, self.readBackTickets.isLatest(deviceId, ticket: ticket) {
                    if let coverWrite {
                        if self.ownsRow(coverWrite) {
                            if self.optimisticFieldLocks[.field(deviceId, .coverPosition)] != nil {
                                self.revert(coverWrite, restoring: self.reportedDevice(for: deviceId))
                            } else {
                                self.coverCommandOrigins.removeValue(forKey: deviceId)
                            }
                        }
                    } else {
                        self.discardCoverOrigin(coverOrigin, deviceId: deviceId, revision: lockRevision)
                    }
                }
                return false
            }
            do {
                try await self.executeDeviceCommand(cmd)
                guard self.matchesModalDeviceContext(modalContext) else {
                    if self.controlContextID == context, self.readBackTickets.isLatest(deviceId, ticket: ticket),
                       let coverWrite, self.ownsRow(coverWrite) {
                        if self.optimisticFieldLocks[.field(deviceId, .coverPosition)] != nil {
                            self.revert(coverWrite, restoring: self.reportedDevice(for: deviceId))
                        } else {
                            self.coverCommandOrigins.removeValue(forKey: deviceId)
                        }
                    }
                    return false
                }
                if let coverWrite, !self.ownsRow(coverWrite) {
                    return true
                }
                let confirmation = await self.confirmToggleReadBack(deviceId: deviceId, requested: updated, ticket: ticket, context: context)
                guard self.matchesModalDeviceContext(modalContext) else { return false }
                switch confirmation {
                case .matched:
                    let shown = self.devices.first(where: { $0.id == deviceId }) ?? updated
                    self.confirmManualControl(intents: [DeviceIntent(targetId: deviceId, operation: .power(updated.isActiveOn))])
                    if case .light = shown.kind, shown.isActiveOn {
                        self.recordManualLightUse(deviceId)
                    }
                    return true
                case .unmatched:
                    let displayName = self.devices.first(where: { $0.id == deviceId })?.name ?? current.name
                    self.showToast(
                        L10n.tr("\(displayName) 未能读回状态", "\(displayName) state was not read back"),
                        isError: true
                    )
                    return false
                case .superseded:
                    return true
                }
            } catch {
                guard self.controlContextID == context else { return false }
                // A newer tap may own the device by now; only an unclaimed failure drops what
                // this tap showed. A cover tap restores the pre-tap row and releases its early
                // lock; the origin it wrote goes back to the value it displaced.
                if self.readBackTickets.isLatest(deviceId, ticket: ticket) {
                    if let coverWrite {
                        // A report that confirmed travel removes the lock entry without bumping
                        // the revision, so the entry must still exist for this write to own the
                        // row; the same rule guards the batch rollback. Only then does the tap
                        // restore its pre-tap row, the lock it displaced, and that lock's origin.
                        if self.ownsRow(coverWrite), self.optimisticFieldLocks[.field(deviceId, .coverPosition)] != nil {
                            self.revert(coverWrite)
                            if var coverPriorLockEntry {
                                coverPriorLockEntry.revision = self.optimisticLockRevision[deviceId] ?? coverPriorLockEntry.revision
                                self.optimisticFieldLocks[.field(deviceId, .coverPosition)] = coverPriorLockEntry
                                if let prior = coverOrigin?.prior {
                                    self.coverCommandOrigins[deviceId] = prior
                                }
                            }
                        }
                    } else {
                        self.discardCoverOrigin(coverOrigin, deviceId: deviceId, revision: lockRevision)
                    }
                }
                let displayName = self.devices.first(where: { $0.id == deviceId })?.name ?? current.name
                self.showToast(L10n.tr("\(displayName) 响应失败", "\(displayName) failed to respond"), isError: true)
                return false
            }
        }
    }

    private enum ReadBackConfirm {
        case matched
        case unmatched
        case superseded
    }

    /// Applies a provider snapshot when one was published. Providers with no property read
    /// keep the accepted power and leave every other field on the current row. A published
    /// read that still shows the old power is polled once more, because a device often
    /// reports the previous value immediately after a write. That second wait releases the
    /// tap so a newer toggle, such as the next keyboard press, is not discarded.
    private func confirmToggleReadBack(deviceId: String, requested: SmartDevice, ticket: UInt64, context: UUID) async -> ReadBackConfirm {
        guard controlContextID == context else { return .superseded }
        if case .cover = requested.kind {
            // Motor control is write-only. Position is reported after the sash moves, so a
            // successful write is the confirmation rather than an instant 0 or 100 reading. The
            // lock holds the accepted state until the device reports the same travel (or a stop
            // after a pause), then `coverTravelTakesOver` ends it.
            applyConfirmedPower(from: requested, deviceId: deviceId)
            lockOptimistic(deviceId, fields: [.coverPosition], duration: coverOptimisticLockDuration)
            return .matched
        }
        if case .tv(let spec) = requested.kind, LGWebOSProtocol.isLGEntity(spec.mediaEntityId) {
            // The LAN client confirms TV writes; the cloud has no row for this device, and a
            // stale provider snapshot must not revert the accepted power.
            applyConfirmedPower(from: requested, deviceId: deviceId)
            lockOptimistic(deviceId, fields: OptimisticField.primaryPowerFields(for: requested.kind), duration: .seconds(2.0))
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        }
        let before = snapshotGeneration
        let read = await provider.readBack(deviceId: deviceId)
        guard controlContextID == context else { return .superseded }
        await settleSnapshot(after: before)
        guard controlContextID == context else { return .superseded }
        switch read {
        case .failed:
            return .unmatched
        case .unavailable:
            applyConfirmedPower(from: requested, deviceId: deviceId)
            // HA rebuilds the whole home on every state_changed event, so an unrelated sensor
            // update could restore the old power before the device's own update arrives.
            lockOptimistic(deviceId, fields: OptimisticField.primaryPowerFields(for: requested.kind), duration: .seconds(2.0))
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        case .published:
            guard snapshotGeneration != before else { return .unmatched }
            if powerMatches(deviceId, requested: requested) { return .matched }
            readBackTickets.releaseTap(deviceId, ticket: ticket)
            if holdReadBackEcho {
                let key = ReadBackEchoHoldKey(deviceId: deviceId, ticket: ticket)
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.readBackEchoHolds.removeValue(forKey: key)?.resume()
                    self.readBackEchoHolds[key] = cont
                }
            } else {
                try? await Task.sleep(for: readBackEchoDelay)
            }
            guard !isResumeShutdown, controlContextID == context else { return .superseded }
            if !readBackTickets.isLatest(deviceId, ticket: ticket) { return .superseded }
            let again = snapshotGeneration
            let second = await provider.readBack(deviceId: deviceId)
            guard !isResumeShutdown, controlContextID == context else { return .superseded }
            if !readBackTickets.isLatest(deviceId, ticket: ticket) { return .superseded }
            if case .failed = second { return .unmatched }
            await settleSnapshot(after: again)
            guard !isResumeShutdown, controlContextID == context else { return .superseded }
            // A newer toggle may have started and even finished during the second read.
            if !readBackTickets.isLatest(deviceId, ticket: ticket) { return .superseded }
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        }
    }

    private func powerMatches(_ deviceId: String, requested: SmartDevice) -> Bool {
        devices.first(where: { $0.id == deviceId })?.isActiveOn == requested.isActiveOn
    }

    private func applyConfirmedPower(from requested: SmartDevice, deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx] = devices[idx].applyingConfirmedPower(from: requested)
        syncGenericPowerFacet(devices[idx])
    }

    private func settleSnapshot(after generation: UInt64) async {
        guard snapshotGeneration == generation else { return }
        for _ in 0..<20 where snapshotGeneration == generation {
            await Task.yield()
            if snapshotGeneration != generation { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func recordManualLightUse(_ deviceId: String) {
        if let current = lastManuallyUsedLightId, current == deviceId { return }
        lastManuallyUsedLightId = deviceId
        userDefaults.set(deviceId, forKey: Self.lastManualLightIdKey)
    }

    // MARK: - Detail Drawer Controls (Debounced & Optimistic)

    public func setLightBrightness(_ deviceId: String, percent: Int) {
        guard let previous = controllableDevice(deviceId),
              case .light(var s) = previous.kind,
              s.brightnessWritable else { return }
        let isOn = percent > 0
        var updated = previous
        s.isOn = isOn
        s.brightnessPercent = percent
        updated.kind = .light(s)
        if isOn { recordManualLightUse(deviceId) }
        commitManualWrite(
            from: previous, to: updated,
            command: .setLightBrightness(entityId: s.entityId, percent: percent),
            lock: .seconds(2.5), debounceKey: "\(deviceId).brightness",
            powersOffDevice: !isOn,
            habitIntents: [.init(targetId: deviceId, operation: .brightness(percent))],
            mutate: { device in
                guard case .light(var spec) = device.kind else { return }
                spec.isOn = isOn
                spec.brightnessPercent = percent
                device.kind = .light(spec)
            }
        )
    }

    public func setLightColorTemp(_ deviceId: String, kelvin: Int) {
        guard let previous = controllableDevice(deviceId),
              case .light(var s) = previous.kind,
              s.colorWritable else { return }
        var updated = previous
        s.isOn = true
        s.colorTempKelvin = kelvin
        s.currentEffect = nil
        updated.kind = .light(s)
        recordManualLightUse(deviceId)
        commitManualWrite(
            from: previous, to: updated,
            command: .setLightColorTemp(entityId: s.entityId, kelvin: kelvin),
            lock: .seconds(2.5), debounceKey: "\(deviceId).colortemp",
            habitIntents: [.init(targetId: deviceId, operation: .colorTemperature(kelvin))],
            mutate: { device in
                guard case .light(var spec) = device.kind else { return }
                spec.isOn = true
                spec.colorTempKelvin = kelvin
                spec.currentEffect = nil
                device.kind = .light(spec)
            }
        )
    }

    public func setLightEffect(_ deviceId: String, effect: String) {
        guard let check = controllableDevice(deviceId), case .light = check.kind else { return }
        cancelDebouncedWrites(for: deviceId, keys: ["\(deviceId).colortemp"])
        guard let previous = devices.first(where: { $0.id == deviceId }),
              case .light(var s) = previous.kind else { return }
        var updated = previous
        s.isOn = true
        s.currentEffect = effect
        updated.kind = .light(s)
        recordManualLightUse(deviceId)
        commitManualWrite(
            from: previous, to: updated,
            command: .setLightEffect(entityId: s.entityId, effect: effect),
            lock: .seconds(2.2),
            habitIntents: [.init(targetId: deviceId, operation: .lightEffect(effect))],
            mutate: { device in
                guard case .light(var spec) = device.kind else { return }
                spec.isOn = true
                spec.currentEffect = effect
                device.kind = .light(spec)
            }
        )
    }

    public func stepClimateTemperature(_ deviceId: String, delta: Double) {
        stepClimateTemperature(deviceId, delta: delta, panelConfirmed: false)
    }

    private func stepClimateTemperature(_ deviceId: String, delta: Double, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId),
              case .climate(let initialSpec) = initial.kind,
              initialSpec.temperatureWritable else { return }
        let nextTemp = max(initialSpec.minTemp, min(initialSpec.maxTemp, initialSpec.targetTemperature + delta))
        guard let confirmed = confirmAndResolveManualControl(
            .targetTemperature(nextTemp), for: initial, requireOnline: true, showOfflineToast: true,
            panelConfirmed: panelConfirmed
        ) else { return }
        guard case .climate(var s) = confirmed.device.kind,
              s.entityId == initialSpec.entityId,
              s.temperatureWritable else {
            if confirmed.didPresentModal { showPostModalDeviceChangedToast() }
            return
        }
        let previous = confirmed.device
        var updated = previous
        s.targetTemperature = nextTemp
        updated.kind = .climate(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateTemperature(entityId: s.entityId, temperature: nextTemp),
            lock: .seconds(2.5), debounceKey: "\(deviceId).temp",
            habitIntents: [.init(targetId: deviceId, operation: .targetTemperature(nextTemp))],
            mutate: { device in
                guard case .climate(var spec) = device.kind else { return }
                spec.targetTemperature = nextTemp
                device.kind = .climate(spec)
            }
        )
    }

    public func setClimateMode(_ deviceId: String, mode: String) {
        setClimateMode(deviceId, mode: mode, panelConfirmed: false)
    }

    private func setClimateMode(_ deviceId: String, mode: String, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId),
              case .climate(let initialSpec) = initial.kind else { return }
        guard let confirmed = confirmAndResolveManualControl(.hvacMode(mode), for: initial, panelConfirmed: panelConfirmed),
              case .climate(var s) = confirmed.device.kind,
              s.entityId == initialSpec.entityId else { return }
        let previous = confirmed.device
        let isOn = (mode != "off")
        var updated = previous
        s.hvacMode = mode
        s.isOn = isOn
        updated.kind = .climate(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateMode(entityId: s.entityId, hvacMode: mode),
            lock: .seconds(2.2),
            powersOffDevice: !isOn,
            habitIntents: [.init(targetId: deviceId, operation: .hvacMode(mode))],
            mutate: { device in
                guard case .climate(var spec) = device.kind else { return }
                spec.hvacMode = mode
                spec.isOn = isOn
                device.kind = .climate(spec)
            }
        )
    }

    /// Appliance writes record no habit: appliances are not assistant-controllable yet, so a
    /// learned appliance habit would surface a suggestion that cannot run (#300).
    public func setApplianceMode(_ deviceId: String, mode: String) {
        setApplianceMode(deviceId, mode: mode, panelConfirmed: false)
    }

    private func setApplianceMode(_ deviceId: String, mode: String, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId),
              case .appliance(let initialSpec) = initial.kind,
              initialSpec.modeWritable, initialSpec.availableModes.contains(mode) else { return }
        let modalContext = captureModalDeviceContext(for: initial)
        var didPresentModal = false
        // Picking a heat mode from standby starts the heater, so it takes the same confirmation
        // as the power button. Idle/off modes and appliances without heat stay direct (#4).
        if initialSpec.heats, !initialSpec.isOn, ApplianceSpec.modeStartsHeating(mode) {
            didPresentModal = ManualControlPolicy.requiresConfirmation(.power(true), for: initial)
            guard panelConfirmed || allowManualControl(.power(true), for: initial) else { return }
        }
        guard let previous = resolvePostModalDevice(modalContext),
              case .appliance(var s) = previous.kind,
              s.modeEntityId == initialSpec.modeEntityId,
              s.modeWritable, s.availableModes.contains(mode) else { return }
        if (didPresentModal || (s.heats && !s.isOn && ApplianceSpec.modeStartsHeating(mode))),
           rejectChangedPostModalHazard(
               .power(true),
               on: previous,
               captured: modalContext,
               didPresentModal: didPresentModal
           ) {
            return
        }
        var updated = previous
        s.currentMode = mode
        updated.kind = .appliance(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSelectOption(entityId: s.modeEntityId, option: mode),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .appliance(var spec) = device.kind else { return }
                spec.currentMode = mode
                device.kind = .appliance(spec)
            }
        )
    }

    private static func applianceStepTarget(_ spec: ApplianceSpec, target: Double, delta: Double) -> Double {
        let step = spec.step > 0 ? spec.step : 1
        let raw = max(spec.minTemp, min(spec.maxTemp, target + delta))
        // A Fahrenheit tap is 5/9 °C, smaller than a coarse step. Round to the nearest step so a
        // small decimal step keeps its adjacent value, then move one step when that is the target.
        var units = ((raw - spec.minTemp) / step).rounded()
        if spec.minTemp + units * step == target {
            units += delta > 0 ? 1 : -1
        }
        let stepped = spec.minTemp + units * step
        return max(spec.minTemp, min(spec.maxTemp, stepped))
    }

    public func stepApplianceTemperature(_ deviceId: String, delta: Double) {
        stepApplianceTemperature(deviceId, delta: delta, panelConfirmed: false)
    }

    private func stepApplianceTemperature(_ deviceId: String, delta: Double, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId),
              case .appliance(let initialSpec) = initial.kind,
              initialSpec.temperatureWritable, let target = initialSpec.targetTemperature else { return }
        let nextTemp = Self.applianceStepTarget(initialSpec, target: target, delta: delta)
        guard nextTemp != target,
              let confirmed = confirmAndResolveManualControl(.targetTemperature(nextTemp), for: initial, panelConfirmed: panelConfirmed),
              case .appliance(var s) = confirmed.device.kind,
              s.temperatureEntityId == initialSpec.temperatureEntityId,
              s.temperatureWritable else { return }
        let previous = confirmed.device
        var updated = previous
        s.targetTemperature = nextTemp
        updated.kind = .appliance(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateTemperature(entityId: s.temperatureEntityId, temperature: nextTemp),
            lock: .seconds(2.5), debounceKey: "\(deviceId).appliance-temp",
            mutate: { device in
                guard case .appliance(var spec) = device.kind else { return }
                spec.targetTemperature = nextTemp
                device.kind = .appliance(spec)
            }
        )
    }

    public func setApplianceLightPower(_ deviceId: String, isOn: Bool) {
        guard let previous = controllableDevice(deviceId), case .appliance(var s) = previous.kind,
              var light = s.light, light.writable, light.isOn != isOn else { return }
        light.isOn = isOn
        s.light = light
        var updated = previous
        updated.kind = .appliance(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: light.entityId, isOn: isOn),
            lock: .seconds(2),
            mutate: { device in
                guard case .appliance(var spec) = device.kind, var lightSpec = spec.light else { return }
                lightSpec.isOn = isOn
                spec.light = lightSpec
                device.kind = .appliance(spec)
            }
        )
    }

    public func setApplianceFanLevel(_ deviceId: String, level: String) {
        guard let previous = controllableDevice(deviceId), case .appliance(var s) = previous.kind,
              let fan = s.fanLevel, fan.writable, fan.options.contains(level), fan.current != level else { return }
        var updatedFan = fan
        updatedFan.current = level
        s.fanLevel = updatedFan
        var updated = previous
        updated.kind = .appliance(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateFanMode(entityId: fan.entityId, fanMode: level),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .appliance(var spec) = device.kind, var fanSpec = spec.fanLevel else { return }
                fanSpec.current = level
                spec.fanLevel = fanSpec
                device.kind = .appliance(spec)
            }
        )
    }

    public func runApplianceAction(_ deviceId: String, action: ApplianceAction) {
        runApplianceAction(deviceId, action: action, panelConfirmed: false)
    }

    private func runApplianceAction(_ deviceId: String, action: ApplianceAction, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId), case .appliance(let initialSpec) = initial.kind,
              initialSpec.startAction == action || initialSpec.pauseAction == action || initialSpec.stopAction == action else { return }
        // Starting a cycle is the hazardous direction; pausing and stopping wind it down.
        let operation: IntentOperation = action.kind == .start ? .power(true) : .power(false)
        guard let confirmed = confirmAndResolveManualControl(operation, for: initial, panelConfirmed: panelConfirmed),
              case .appliance(let s) = confirmed.device.kind,
              s.startAction == action || s.pauseAction == action || s.stopAction == action else { return }
        // The program state is reported by the device; nothing is shown ahead of it.
        commitManualWrite(from: confirmed.device, to: nil, command: .pressButton(entityId: action.entityId), lock: nil)
    }

    public func setHumidifierMode(_ deviceId: String, mode: String) {
        guard let previous = controllableDevice(deviceId), case .humidifier(var s) = previous.kind,
              s.modeWritable, s.availableModes.contains(mode) else { return }
        var updated = previous
        s.currentMode = mode
        updated.kind = .humidifier(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSelectOption(entityId: s.entityId, option: mode),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .humidifier(var spec) = device.kind else { return }
                spec.currentMode = mode
                device.kind = .humidifier(spec)
            }
        )
    }

    public func setHumidifierHumidity(_ deviceId: String, percent: Int) {
        guard let previous = controllableDevice(deviceId), case .humidifier(var s) = previous.kind,
              s.humidityWritable, let target = s.targetHumidity else { return }
        let clamped = max(s.minHumidity, min(s.maxHumidity, percent))
        guard clamped != target else { return }
        var updated = previous
        s.targetHumidity = clamped
        updated.kind = .humidifier(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setHumidity(entityId: s.entityId, percent: clamped),
            lock: .seconds(2.5), debounceKey: "\(deviceId).humidifier-humidity",
            mutate: { device in
                guard case .humidifier(var spec) = device.kind else { return }
                spec.targetHumidity = clamped
                device.kind = .humidifier(spec)
            }
        )
    }

    public func setClimateFanMode(_ deviceId: String, fanMode: String) {
        guard let initial = controllableDevice(deviceId),
              case .climate(let initialSpec) = initial.kind else { return }
        guard let confirmed = confirmAndResolveManualControl(.fanSpeed(fanMode), for: initial),
              case .climate(var s) = confirmed.device.kind,
              s.entityId == initialSpec.entityId else { return }
        let previous = confirmed.device
        var updated = previous
        s.fanMode = fanMode
        updated.kind = .climate(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateFanMode(entityId: s.entityId, fanMode: fanMode),
            lock: .seconds(2.2),
            habitIntents: [.init(targetId: deviceId, operation: .fanSpeed(fanMode))],
            mutate: { device in
                guard case .climate(var spec) = device.kind else { return }
                spec.fanMode = fanMode
                device.kind = .climate(spec)
            }
        )
    }

    public func setClimateSwingMode(_ deviceId: String, swingMode: String) {
        guard let initial = controllableDevice(deviceId),
              case .climate(let initialSpec) = initial.kind else { return }
        let operation = IntentOperation.oscillation(swingMode.caseInsensitiveCompare("off") != .orderedSame)
        guard let confirmed = confirmAndResolveManualControl(operation, for: initial),
              case .climate(var s) = confirmed.device.kind,
              s.entityId == initialSpec.entityId else { return }
        let previous = confirmed.device
        var updated = previous
        s.swingMode = swingMode
        updated.kind = .climate(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setClimateSwingMode(entityId: s.entityId, swingMode: swingMode),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .climate(var spec) = device.kind else { return }
                spec.swingMode = swingMode
                device.kind = .climate(spec)
            }
        )
    }

    public func setFanPercentage(_ deviceId: String, percent: Int) {
        guard let previous = controllableDevice(deviceId), case .fan = previous.kind,
              let change = Self.fanPercentageChange(previous, percent: percent) else { return }
        commitManualWrite(
            from: previous, to: change.updated,
            command: change.command,
            lock: .seconds(2.5), debounceKey: "\(deviceId).fanpercent",
            habitIntents: change.favoritePreset.map { [DeviceIntent(targetId: deviceId, operation: .fanSpeed($0))] } ?? [],
            mutate: { device in
                if let next = Self.fanPercentageChange(device, percent: percent)?.updated {
                    device = next
                }
            }
        )
    }

    /// A fan speed in percent: powers on and switches to the Favorite preset when the fan has one,
    /// because purifiers only honour a manual speed in that mode. Shared by the card and Raycast.
    nonisolated static func fanPercentageChange(
        _ device: SmartDevice,
        percent: Int
    ) -> (updated: SmartDevice, command: DeviceCommand, favoritePreset: String?)? {
        guard case .fan(var s) = device.kind else { return nil }
        let clamped = max(1, min(100, percent))
        let favorite = s.availablePresetModes.first(where: { $0.caseInsensitiveCompare("Favorite") == .orderedSame })
        s.isOn = true
        s.percentage = clamped
        if let favorite { s.presetMode = favorite }
        var updated = device
        updated.kind = .fan(s)
        return (updated, .setFanPercentage(entityId: s.entityId, percent: clamped), favorite)
    }

    public func setFanPresetMode(_ deviceId: String, preset: String) {
        guard let check = controllableDevice(deviceId), case .fan = check.kind else { return }
        cancelDebouncedWrites(for: deviceId, keys: ["\(deviceId).fanpercent"])
        guard let previous = devices.first(where: { $0.id == deviceId }),
              case .fan(var s) = previous.kind else { return }
        var updated = previous
        s.isOn = true
        s.presetMode = preset
        updated.kind = .fan(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setFanPresetMode(entityId: s.entityId, presetMode: preset),
            lock: .seconds(2.2),
            habitIntents: [.init(targetId: deviceId, operation: .fanSpeed(preset))],
            mutate: { device in
                guard case .fan(var spec) = device.kind else { return }
                spec.isOn = true
                spec.presetMode = preset
                device.kind = .fan(spec)
            }
        )
    }

    public func setCoverMotor(_ deviceId: String, description: String) {
        setCoverMotor(deviceId, description: description, panelConfirmed: false)
    }

    private func setCoverMotor(_ deviceId: String, description: String, panelConfirmed: Bool) {
        guard let check = controllableDevice(deviceId), case .cover(let checkSpec) = check.kind else { return }
        let opening = checkSpec.openDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let closing = checkSpec.closeDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let pausing = checkSpec.pauseDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let modalContext = captureModalDeviceContext(for: check)
        let preModalGeneration = snapshotGeneration
        let motorOperation: IntentOperation? = (opening || closing) ? .power(opening) : nil
        var didPresentModal = false
        if let motorOperation {
            didPresentModal = ManualControlPolicy.requiresConfirmation(motorOperation, for: check)
            guard panelConfirmed || allowManualControl(motorOperation, for: check) else { return }
        }
        guard let resolvedBeforeCancel = resolvePostModalDevice(
            modalContext, requireOnline: didPresentModal, showOfflineToast: true
        ) else { return }
        if let motorOperation,
           rejectChangedPostModalHazard(
               motorOperation,
               on: resolvedBeforeCancel,
               captured: modalContext,
               didPresentModal: didPresentModal
           ) {
            return
        }
        cancelDebouncedWrites(for: deviceId, keys: ["\(deviceId).cover"])
        if (opening || closing),
           optimisticFieldLocks[.field(deviceId, .coverPosition)] != nil,
           let reported = reportedDevice(for: deviceId),
           case .cover(let reportedSpec) = reported.kind {
            let reportedPos = lastCoverPositions[deviceId]
                ?? reportedSpec.reportedPositionPercent
                ?? reportedSpec.positionPercent
            let priorOrigin = coverCommandOrigins[deviceId]
            if (didPresentModal && snapshotGeneration != preModalGeneration)
                || (priorOrigin != nil && reportedPos != nil && reportedPos != priorOrigin) {
                dropSupersededCoverLock(deviceId: deviceId, restoring: reported)
            }
        }
        guard let previous = resolvePostModalDevice(
            modalContext, requireOnline: didPresentModal, showOfflineToast: true
        ) else { return }
        guard case .cover(var s) = previous.kind, s.entityId == checkSpec.entityId else {
            if didPresentModal { showPostModalDeviceChangedToast() }
            return
        }
        let priorCoverOrigin = coverCommandOrigins[deviceId]
        let latestPos = lastCoverPositions[deviceId] ?? s.reportedPositionPercent ?? s.positionPercent
        let origin = activeCoverOrigin(for: deviceId, fallback: s.positionPercent)
        if opening {
            coverCommandOrigins[deviceId] = latestPos
            s.positionPercent = 100
            s.motion = .opening
            s.motionIsInferred = false
        }
        if closing {
            coverCommandOrigins[deviceId] = latestPos
            s.positionPercent = 0
            s.motion = .closing
            s.motionIsInferred = false
        }
        if pausing {
            coverCommandOrigins[deviceId] = origin
            s.motion = .stopped
            s.motionIsInferred = false
        }
        let targetPosition = s.positionPercent
        let targetMotion = s.motion
        let targetInferred = s.motionIsInferred
        var updated = previous
        updated.kind = .cover(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSelectOption(entityId: s.entityId, option: description),
            lock: (opening || closing || pausing) ? coverOptimisticLockDuration : nil,
            priorCoverOrigin: priorCoverOrigin,
            mutate: { device in
                guard case .cover(var spec) = device.kind else { return }
                spec.positionPercent = targetPosition
                spec.motion = targetMotion
                spec.motionIsInferred = targetInferred
                device.kind = .cover(spec)
            }
        )
    }

    private func dropSupersededCoverLock(deviceId: String, restoring reported: SmartDevice) {
        if var session = manualWriteSessions[deviceId] {
            session.patches.removeAll { $0.fields.contains(.coverPosition) }
            session.baseFieldLocks.removeValue(forKey: .coverPosition)
            session.baseCoverOrigin = nil
            session.base = session.base.mergingOptimisticFields(from: reported, lockedFields: [.coverPosition])
            if session.patches.isEmpty {
                manualWriteSessions.removeValue(forKey: deviceId)
            } else {
                manualWriteSessions[deviceId] = session
            }
        }
        optimisticFieldLocks.removeValue(forKey: .field(deviceId, .coverPosition))
        coverCommandOrigins.removeValue(forKey: deviceId)
        if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
            if let session = manualWriteSessions[deviceId], optimisticLockRevision[deviceId] == session.revision {
                var composed = session.base
                for patch in session.patches {
                    patch.apply(&composed)
                }
                devices[idx] = composed
            } else {
                devices[idx] = devices[idx].mergingOptimisticFields(from: reported, lockedFields: [.coverPosition])
            }
            syncGenericPowerFacet(devices[idx])
        }
    }

    /// A curtain or blind treats the drag as the confirmation; a subtype the hazard table calls
    /// dangerous (garage door, gate) asks before the row moves. The drag's first tick carries the
    /// answer for the rest of that drag, the same way a facet slider rides on its first prompt.
    public func setCoverPosition(_ deviceId: String, percent: Int) {
        setCoverPosition(deviceId, percent: percent, panelConfirmed: false)
    }

    private func setCoverPosition(_ deviceId: String, percent: Int, panelConfirmed: Bool) {
        guard let initial = controllableDevice(deviceId),
              case .cover(let initialSpec) = initial.kind,
              initialSpec.positionWritable else { return }
        let modalContext = captureModalDeviceContext(for: initial)
        let key = "\(deviceId).cover"
        let clamped = max(0, min(100, percent))
        let displayed = CoverSpec.snappedPosition(clamped)
        // `lastCoverPositions` is the raw position the device last reported, updated by every
        // snapshot even while a command lock hides it. The row's `reportedPositionPercent` is the
        // same truth after a lock merge; `positionPercent` is only the commanded target, so a
        // missing report must stay unknown instead of borrowing the optimistic value.
        let preStartPosition = lastCoverPositions[deviceId] ?? initialSpec.reportedPositionPercent
        // Asked before any optimistic state moves, so a refusal leaves the slider on the position
        // the device really reports. The direction comes from the value the command sends, not the
        // snapped one the row shows: 0 → 1 % displays as a closed door but still opens it. It also
        // starts from the motor's reported position, not the card's commanded target: a moving
        // cover shows 100% while the motor is still at 0%, and 0 → 20% is the hazardous opening.
        // One answer covers the same-direction ticks of a drag still being accumulated; a tick the
        // other way, or one after the slot went out, is a new decision and asks on its own.
        // The command travels from the motor's reported position. A tick that lands back on that
        // reported position has no travel of its own, but a pending/in-flight command may still be
        // heading elsewhere; reversing it is a hazard decision on its own (#223), so the prompt
        // falls back to the displayed target. The send gate only trusts the reported direction.
        let preStartIsUnknown = preStartPosition == nil
        let preTravelDirection = preStartIsUnknown
            ? true
            : Self.coverDragDirection(from: preStartPosition, to: clamped)
        let preDisplayDirection = Self.coverDragDirection(from: initialSpec.positionPercent, to: clamped)
        let promptDirection = preTravelDirection ?? preDisplayDirection
        let promptApproval: CoverDragApproval?
        if preStartIsUnknown {
            // The answer covers a write from an unknown position; it is not an opening approval.
            promptApproval = .unknownStart
        } else if let promptDirection {
            promptApproval = promptDirection ? .opening : .closing
        } else {
            promptApproval = nil
        }
        let confirmedDrag = promptApproval.map {
            continuesConfirmedCoverDrag(key, deviceId: deviceId, approval: $0)
        } ?? false
        var answeredPrompt = false
        if let promptDirection, !confirmedDrag,
           ManualControlPolicy.requiresConfirmation(.power(promptDirection), for: initial) {
            if preStartIsUnknown {
                guard panelConfirmed || allowUnknownStartCoverControl(for: initial) else { return }
            } else {
                guard panelConfirmed || allowManualControl(.power(promptDirection), for: initial) else { return }
            }
            answeredPrompt = true
        }

        guard let previous = answeredPrompt
            ? resolvePostModalDevice(modalContext, requireOnline: true, showOfflineToast: true)
            : initial else { return }
        guard case .cover(var s) = previous.kind,
              s.entityId == initialSpec.entityId,
              s.positionWritable else {
            if answeredPrompt { showPostModalDeviceChangedToast() }
            return
        }
        let priorCoverOrigin = coverCommandOrigins[deviceId]
        let baselineCover: CoverSpec? = if case .cover(let baseSpec) = debouncedWrites[key]?.origin.kind {
            baseSpec
        } else {
            nil
        }
        let startPosition = lastCoverPositions[deviceId] ?? s.reportedPositionPercent
        let previousPosition = startPosition ?? displayed
        let startIsUnknown = startPosition == nil
        let travelDirection = startIsUnknown
            ? true
            : Self.coverDragDirection(from: startPosition, to: clamped)
        let stillConfirmedDrag = answeredPrompt ? false : confirmedDrag
        let approval: CoverDragApproval?
        if answeredPrompt {
            if promptApproval == .unknownStart {
                approval = ManualControlPolicy.requiresConfirmation(.power(true), for: previous)
                    ? .unknownStart
                    : nil
            } else {
                approval = promptApproval
            }
        } else if startIsUnknown {
            // The answer covers a write from an unknown position; it is not an opening approval.
            approval = stillConfirmedDrag
                && ManualControlPolicy.requiresConfirmation(.power(true), for: previous)
                ? .unknownStart
                : nil
        } else if let travelDirection, stillConfirmedDrag {
            approval = travelDirection ? .opening : .closing
        } else {
            approval = nil
        }
        let coverDrag = CoverDragPlan(
            target: clamped,
            approval: approval,
            startPosition: startPosition
        )
        if answeredPrompt,
           ManualControlHazardProfile(previous) != modalContext.hazardProfile
               || !Self.coverDragMaySend(coverDrag, from: previous, startPosition: startPosition) {
            showControlFailure(ManualWriteNeedsCoverConfirmation(), device: previous, adjustment: true)
            return
        }
        let origin = activeCoverOrigin(for: deviceId, fallback: startPosition)
        if let baselineCover {
            s.motion = baselineCover.motion
            s.motionIsInferred = baselineCover.motionIsInferred
        }
        s.positionPercent = displayed
        if displayed > previousPosition {
            s.motion = .opening
            s.motionIsInferred = false
        } else if displayed < previousPosition {
            s.motion = .closing
            s.motionIsInferred = false
        }
        var updated = previous
        updated.kind = .cover(s)
        if s.isMoving {
            coverCommandOrigins[deviceId] = origin
        } else {
            coverCommandOrigins.removeValue(forKey: deviceId)
        }
        commitManualWrite(
            from: previous, to: updated,
            command: .setNumberValue(entityId: s.entityId, value: Double(clamped)),
            lock: s.isMoving ? coverOptimisticLockDuration : nil,
            debounceKey: key,
            priorCoverOrigin: priorCoverOrigin,
            coverDrag: coverDrag,
            mutate: { device in
                guard case .cover(var spec) = device.kind else { return }
                // The direction is relative to where the motor actually is (the reported
                // position), not to a display target: a device report can re-base a still-pending
                // drag (50 -> 20 becomes 15 -> 20 when the first command stops at 15), and a
                // moving cover shows its commanded target while the motor is elsewhere. A captured
                // direction, or the composed row's optimistic position, would then confirm travel
                // the wrong way in `coverTravelTakesOver`. The plan's start is refreshed by every
                // report, including Home Assistant covers that never publish a reported position;
                // when it is nil the start stays unknown and no direction is invented.
                let start = spec.reportedPositionPercent ?? coverDrag.startPosition
                spec.positionPercent = displayed
                if let start {
                    if displayed > start {
                        spec.motion = .opening
                        spec.motionIsInferred = false
                    } else if displayed < start {
                        spec.motion = .closing
                        spec.motionIsInferred = false
                    } else {
                        // The motor is already where the drag points, so no travel remains; a
                        // left-over direction would make `coverTravelTakesOver` confirm the
                        // previous command's report against this target.
                        spec.motion = .stopped
                        spec.motionIsInferred = false
                    }
                }
                device.kind = .cover(spec)
            }
        )
        // Each commit mints a new slot token, so keep the recorded one current for as long as this
        // drag needs the same confirmation kind. A start that becomes known or unknown, or a tick
        // the other way, is a new hazard decision and asks on its own.
        if let promptApproval, answeredPrompt || stillConfirmedDrag, let token = debouncedWrites[key]?.token {
            confirmedCoverDragAnswers[key] = (token, promptApproval)
        }
    }

    /// True while the slider is still accumulating the drag whose hazard prompt was answered for
    /// this confirmation kind: the debounce slot still holds that answer's token and its patch has
    /// not been sent. A slot that went out, a replaced one, a tick the other way, or a start that
    /// became known/unknown starts a new decision, so neither a reversal nor a second drag during
    /// the command's flight inherits the answer.
    private func continuesConfirmedCoverDrag(
        _ key: String,
        deviceId: String,
        approval: CoverDragApproval
    ) -> Bool {
        guard let slot = debouncedWrites[key],
              let answer = confirmedCoverDragAnswers[key],
              answer.token == slot.token,
              answer.approval == approval else { return false }
        return manualWriteSessions[deviceId]?.patches.contains {
            $0.slotKey == key && $0.phase == .debouncing
        } == true
    }

    /// The hazard direction a position drag takes (`true` opens), or nil when it cannot move the
    /// device. A curtain has no hazard; a garage door is hazardous in both directions and a window
    /// opener or airer only while opening. An unknown reported position counts as opening, the
    /// direction every hazardous subtype asks about.
    nonisolated static func coverDragDirection(from start: Int?, to target: Int) -> Bool? {
        guard let start else { return true }
        guard start != target else { return nil }
        return target > start
    }

    func activeCoverOrigin(for deviceId: String, fallback: Int?) -> Int? {
        if let entry = optimisticFieldLocks[.field(deviceId, .coverPosition)],
           isOptimisticEntryActive(entry, at: optimisticNow(), continuousNow: ContinuousClock.now),
           let origin = coverCommandOrigins[deviceId] {
            return origin
        }
        coverCommandOrigins.removeValue(forKey: deviceId)
        return fallback
    }

    public func hasDetailDrawer(for device: SmartDevice) -> Bool {
        if device.hasDetailDrawer || deviceFacets[device.id]?.isEmpty == false {
            return true
        }
        if case .sensor = device.kind {
            return false
        }
        return deviceTransportDiagnostics[device.id] != nil
    }

    // MARK: - Generic Facet Controls (#5)

    public func setFacetValue(_ deviceId: String, controlId: String, value: JSONValue) {
        guard let device = controllableDevice(deviceId), device.isOnline,
              let facets = deviceFacets[deviceId],
              let index = facets.firstIndex(where: { $0.id == controlId }) else { return }
        let control = facets[index]
        if let target = control.target,
           let reason = miotCommandWriteRejection(for: target.referencedEntityId)
               ?? haCommandWriteRejection(for: target.referencedEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        guard facetWriteAllowed(control),
              control.target?.isAction == false,
              control.value != value,
              Self.facetCommand(for: control, value: value) != nil else { return }
        let modalContext = captureModalDeviceContext(for: device)
        let preModalGeneration = snapshotGeneration
        let key = facetWriteKey(deviceId, controlId)
        let prePromptPrevious = facetWrites[key]
        let prePromptOrigin = if let prePromptPrevious { prePromptPrevious.origin } else { control.value }
        var tickApproval: FacetDragApproval?
        var newlyApproved: FacetDragApproval?
        let preModalFacetApproval: FacetDragApproval?
        var didPresentModal = false
        if control.kind == .slider {
            // Only a slider still waiting in its debounce may reuse an approval that this same
            // drag already obtained for the same hazard kind. Cooling first (`confirmedApprovals`
            // empty) never covers a later warm-up, and an already in-flight write belongs to the
            // earlier gesture.
            let activeDrag = prePromptPrevious?.phase == .debouncing ? prePromptPrevious : nil
            let priorApprovals = activeDrag?.confirmedApprovals ?? []
            let evaluation = facetSliderEvaluation(
                deviceId: deviceId,
                controlId: controlId,
                origin: prePromptOrigin,
                value: value,
                fallbackDevice: device,
                fallbackControl: control
            )
            tickApproval = evaluation.approval
            preModalFacetApproval = evaluation.approval
            if let required = evaluation.approval, !priorApprovals.contains(required) {
                didPresentModal = ManualControlPolicy.confirmation(
                    facet: evaluation.control,
                    value: value,
                    for: evaluation.device
                ) != nil
                guard allowManualControl(
                    facet: evaluation.control,
                    value: value,
                    for: evaluation.device
                ) else { return }
                newlyApproved = required
            }
        } else {
            // A toggle or select tapped again while an earlier write is pending is a new decision
            // (off -> on of a heater) and is judged on its own value.
            preModalFacetApproval = ManualControlPolicy.facetConfirmationKind(
                control,
                value: value,
                for: device
            )
            didPresentModal = ManualControlPolicy.confirmation(
                facet: control,
                value: value,
                for: device
            ) != nil
            guard allowManualControl(facet: control, value: value, for: device) else { return }
            tickApproval = nil
        }

        // `allowManualControl` may run a modal confirmation loop during which snapshots arrive,
        // sources switch, or an earlier debounced tick rolls back and clears its undo banner.
        // Re-read live state before committing so stale pre-modal captures cannot overwrite new
        // cloud state, carry stale undo baselines, or target gone/re-sourced rows.
        guard let currentDevice = resolvePostModalDevice(modalContext, requireOnline: true, showOfflineToast: true),
              var currentFacets = deviceFacets[deviceId],
              let currentIndex = currentFacets.firstIndex(where: { $0.id == controlId }) else { return }
        let currentControl = currentFacets[currentIndex]
        guard currentControl.kind == control.kind,
              currentControl.target == control.target,
              facetWriteAllowed(currentControl),
              currentControl.target?.isAction == false,
              didPresentModal || currentControl.value != value,
              let currentCommand = Self.facetCommand(for: currentControl, value: value) else { return }
        if let reason = miotCommandWriteRejection(for: currentCommand.targetEntityId)
            ?? haCommandWriteRejection(for: currentCommand.targetEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        let previous = facetWrites[key]
        let snapshotAdvancedDuringModal = didPresentModal && snapshotGeneration != preModalGeneration
        let origin: JSONValue?
        let originSnapshotGeneration: UInt64
        let canReusePreviousBanner: Bool
        if let previous {
            if previous.phase == .debouncing, snapshotGeneration != previous.originSnapshotGeneration {
                origin = reportedFacetControl(deviceId: deviceId, controlId: controlId)?.value ?? currentControl.value
                originSnapshotGeneration = snapshotGeneration
                canReusePreviousBanner = false
            } else if snapshotAdvancedDuringModal {
                origin = reportedFacetControl(deviceId: deviceId, controlId: controlId)?.value ?? currentControl.value
                originSnapshotGeneration = snapshotGeneration
                canReusePreviousBanner = false
            } else {
                origin = previous.origin
                originSnapshotGeneration = previous.originSnapshotGeneration
                canReusePreviousBanner = true
            }
        } else if snapshotAdvancedDuringModal {
            origin = reportedFacetControl(deviceId: deviceId, controlId: controlId)?.value ?? currentControl.value
            originSnapshotGeneration = snapshotGeneration
            canReusePreviousBanner = false
        } else {
            origin = currentControl.value
            originSnapshotGeneration = snapshotGeneration
            canReusePreviousBanner = false
        }
        var confirmedApprovals: Set<FacetDragApproval> = []
        if currentControl.kind == .slider {
            let liveActiveDrag = previous?.phase == .debouncing ? previous : nil
            confirmedApprovals = liveActiveDrag?.confirmedApprovals ?? []
            if let newlyApproved {
                confirmedApprovals.insert(newlyApproved)
            }
        }
        if didPresentModal {
            let hazardStable = ManualControlHazardProfile(currentDevice) == modalContext.hazardProfile
                && currentControl.serviceName == control.serviceName
                && currentControl.name == control.name
            if !hazardStable {
                showControlFailure(
                    ManualWriteNeedsFacetConfirmation(),
                    device: currentDevice,
                    adjustment: currentControl.kind == .slider
                )
                return
            }
            if currentControl.kind == .slider {
                let postEvaluation = facetSliderEvaluation(
                    deviceId: deviceId,
                    controlId: controlId,
                    origin: origin,
                    value: value,
                    fallbackDevice: currentDevice,
                    fallbackControl: currentControl
                )
                if let postRequired = postEvaluation.approval,
                   !confirmedApprovals.contains(postRequired) {
                    showControlFailure(
                        ManualWriteNeedsFacetConfirmation(),
                        device: currentDevice,
                        adjustment: true
                    )
                    return
                }
                tickApproval = postEvaluation.approval
            } else {
                let postRequired = ManualControlPolicy.facetConfirmationKind(
                    currentControl,
                    value: value,
                    for: currentDevice
                )
                if let postRequired, postRequired != preModalFacetApproval {
                    showControlFailure(
                        ManualWriteNeedsFacetConfirmation(),
                        device: currentDevice,
                        adjustment: false
                    )
                    return
                }
            }
        }
        let reusableBannerID: UUID? = if canReusePreviousBanner,
                                         let existingBannerID = previous?.bannerID,
                                         undoBanner?.id == existingBannerID {
            existingBannerID
        } else {
            nil
        }
        var pending = FacetWriteState(
            token: UUID(),
            origin: origin,
            originSnapshotGeneration: originSnapshotGeneration,
            value: value,
            approval: tickApproval,
            confirmedApprovals: confirmedApprovals,
            phase: currentControl.kind == .slider ? .debouncing : .inFlight,
            bannerID: reusableBannerID
        )
        currentFacets[currentIndex].value = value
        deviceFacets[deviceId] = currentFacets
        extendFacetLock(deviceId, controlId: controlId, duration: .seconds(2.2))
        if reusableBannerID == nil {
            if let origin, origin != value,
               let restore = Self.facetCommand(for: currentControl, value: origin) {
                let rawTitle = currentControl.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? currentControl.name : rawTitle
                scheduleUndoBanner(
                    title: L10n.tr("已更新 \(currentDevice.name) 的\(title)", "Updated \(currentDevice.name): \(title)"),
                    restoreCommands: [restore],
                    previousDevices: [currentDevice], deviceCount: 1
                )
                pending.bannerID = undoBanner?.id
            } else if let staleID = previous?.bannerID, undoBanner?.id == staleID {
                undoTimerTask?.cancel()
                undoBanner = nil
            }
        }
        facetWrites[key] = pending
        dispatchFacetWrite(
            device: currentDevice, controlId: controlId, pending: pending,
            command: currentCommand,
            adjustment: currentControl.kind == .slider
        )
    }

    /// Fires a 更多设置 button. A feeding action takes `portion`, the amount the drawer picked;
    /// other inputs fall back to the profile default (an enum input prefers the app/remote source).
    public func runFacetAction(_ deviceId: String, controlId: String, portion: Int? = nil) {
        runFacetAction(deviceId, controlId: controlId, portion: portion, panelConfirmed: false)
    }

    private func runFacetAction(_ deviceId: String, controlId: String, portion: Int?, panelConfirmed: Bool) {
        guard let device = controllableDevice(deviceId), device.isOnline,
              let control = deviceFacets[deviceId]?.first(where: { $0.id == controlId }) else { return }
        if let target = control.target,
           let reason = miotCommandWriteRejection(for: target.referencedEntityId)
               ?? haCommandWriteRejection(for: target.referencedEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        guard facetWriteAllowed(control), let target = control.target else { return }
        switch target {
        case .action, .haAction:
            break
        case .property, .haProperty:
            return
        }
        let modalContext = captureModalDeviceContext(for: device)
        let didPresentModal = ManualControlPolicy.confirmation(
            facet: control,
            value: nil,
            portion: portion,
            for: device
        ) != nil
        guard panelConfirmed || allowManualControl(facet: control, value: nil, portion: portion, for: device),
              let currentDevice = resolvePostModalDevice(modalContext, requireOnline: true, showOfflineToast: true),
              let currentControl = deviceFacets[deviceId]?.first(where: { $0.id == controlId }),
              facetWriteAllowed(currentControl),
              let currentTarget = currentControl.target,
              currentTarget == target else { return }
        if didPresentModal,
           ManualControlHazardProfile(currentDevice) != modalContext.hazardProfile
               || currentControl.serviceName != control.serviceName
               || currentControl.name != control.name
               || currentControl.portionArgumentIndex != control.portionArgumentIndex {
            showControlFailure(ManualWriteNeedsFacetConfirmation(), device: currentDevice, adjustment: false)
            return
        }
        let command: DeviceCommand
        switch currentTarget {
        case .action(let entityId):
            command = .callMiotAction(
                entityId: entityId,
                arguments: Self.facetActionArguments(currentControl, portion: portion)
            )
        case .haAction(let entityId):
            command = .pressButton(entityId: entityId)
        case .property, .haProperty:
            return
        }
        if let reason = miotCommandWriteRejection(for: command.targetEntityId)
            ?? haCommandWriteRejection(for: command.targetEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        extendFacetLock(deviceId, controlId: controlId, duration: .seconds(2.0))
        let pending = FacetWriteState(
            token: UUID(),
            origin: nil,
            originSnapshotGeneration: snapshotGeneration,
            value: nil,
            approval: .write,
            confirmedApprovals: [.write],
            phase: .inFlight,
            bannerID: nil
        )
        facetWrites[facetWriteKey(deviceId, controlId)] = pending
        dispatchFacetWrite(device: currentDevice, controlId: controlId, pending: pending,
                           command: command, adjustment: false)
    }

    /// Input values for a facet action in spec order. The portion argument uses the drawer's pick,
    /// clamped to the spec's range; every other input takes its profile default.
    nonisolated static func facetActionArguments(_ control: FacetControl, portion: Int?) -> [JSONValue] {
        control.arguments.enumerated().map { index, argument in
            guard index == control.portionArgumentIndex else {
                return MiotFacetEngine.defaultActionArgument(argument)
            }
            return .number(Double(argument.range?.clampedPortion(portion) ?? portion ?? 1))
        }
    }

    /// The write a facet sends for `value`. MIoT properties carry the raw value; a Home Assistant
    /// facet picks the service by its domain and turns a select's option index back into its label.
    nonisolated static func facetCommand(for control: FacetControl, value: JSONValue) -> DeviceCommand? {
        guard let target = control.target else { return nil }
        switch target {
        case .property(let entityId, let piid):
            return .setMiotProperty(entityId: entityId, piid: piid, value: value)
        case .haProperty(let entityId):
            switch control.kind {
            case .toggle:
                guard let isOn = value.boolValue else { return nil }
                return .setSwitch(entityId: entityId, isOn: isOn)
            case .select:
                guard let index = value.intValue,
                      let option = control.options.first(where: { $0.value == index }) else { return nil }
                return .setSelectOption(entityId: entityId, option: option.label)
            case .slider:
                guard let number = value.doubleValue else { return nil }
                return .setNumberValue(entityId: entityId, value: number)
            case .reading, .button:
                return nil
            }
        case .action, .haAction:
            return nil
        }
    }

    /// The facet value an undo command restores, or nil when the command is not a property write.
    nonisolated static func facetValue(for command: DeviceCommand, control: FacetControl) -> JSONValue? {
        switch command {
        case .setSwitch(_, let isOn):
            return .bool(isOn)
        case .setSelectOption(_, let option):
            guard let match = control.options.first(where: { $0.label == option }) else { return nil }
            return .number(Double(match.value))
        case .setNumberValue(_, let value):
            return .number(value)
        case .setMiotProperty(_, _, let value):
            return value
        default:
            return nil
        }
    }

    /// The facet target a generic property command addresses. Only a target that matches an
    /// existing facet row makes the command a facet write, so card commands cannot be mistaken
    /// for one.
    nonisolated static func facetTarget(for command: DeviceCommand) -> FacetTarget? {
        switch command {
        case .setMiotProperty(let entityId, let piid, _):
            return .property(entityId: entityId, piid: piid)
        case .setSwitch(let entityId, _), .setSelectOption(let entityId, _), .setNumberValue(let entityId, _):
            return .haProperty(entityId: entityId)
        default:
            return nil
        }
    }

    private func facetWriteAllowed(_ control: FacetControl) -> Bool {
        control.isWritable && control.target != nil
            && (control.writesByDefault || control.isConfirmedWrite || allowAdvancedFacetWrites)
    }

    private func facetWriteKey(_ deviceId: String, _ controlId: String) -> String {
        "\(deviceId).facet.\(controlId)"
    }

    func cancelFacetWrite(deviceId: String, controlId: String) {
        let key = facetWriteKey(deviceId, controlId)
        facetWrites.removeValue(forKey: key)
        debounceTasks.removeValue(forKey: key)?.cancel()
    }

    func cancelFacetWrites(for deviceId: String?) {
        let prefix = deviceId.map { "\($0).facet." }
        for key in Array(facetWrites.keys) where prefix.map({ key.hasPrefix($0) }) ?? true {
            facetWrites.removeValue(forKey: key)
            debounceTasks.removeValue(forKey: key)?.cancel()
        }
    }

    func extendFacetLock(_ deviceId: String, controlId: String, duration: Duration) {
        let key = Self.facetLockKey(deviceId, controlId)
        let candidate = makeOptimisticEntry(
            duration: duration,
            revision: optimisticFacetLocks[key]?.revision ?? optimisticLockRevision[deviceId] ?? 1
        )
        if let existing = optimisticFacetLocks[key] {
            let maxUntil = max(existing.until, candidate.until)
            let maxInstant: ContinuousClock.Instant? = if let a = existing.untilInstant, let b = candidate.untilInstant {
                max(a, b)
            } else {
                candidate.untilInstant ?? existing.untilInstant
            }
            optimisticFacetLocks[key] = OptimisticLockEntry(
                until: maxUntil,
                untilInstant: hasCustomOptimisticNow ? nil : maxInstant,
                revision: existing.revision
            )
        } else {
            optimisticFacetLocks[key] = candidate
        }
    }

    func extendFacetLock(_ deviceId: String, duration: Duration) {
        let facets = deviceFacets[deviceId] ?? []
        if facets.isEmpty {
            lockOptimistic(deviceId, duration: duration)
            return
        }
        for facet in facets {
            extendFacetLock(deviceId, controlId: facet.id, duration: duration)
        }
    }

    func reportedDevice(for deviceId: String) -> SmartDevice? {
        lastReportedDevices[deviceId].map { devicesWithAliases([$0]).first ?? $0 }
    }

    private func reportedFacetControl(deviceId: String, controlId: String) -> FacetControl? {
        lastReportedFacets[deviceId]?.first(where: { $0.id == controlId })
    }

    private static func deviceWithoutUnreportedBaseline(_ device: SmartDevice) -> SmartDevice {
        var copy = device
        if case .appliance(var spec) = copy.kind {
            spec.targetTemperature = nil
            copy.kind = .appliance(spec)
        }
        return copy
    }

    private func facetSliderEvaluation(
        deviceId: String,
        controlId: String,
        origin: JSONValue?,
        value: JSONValue?,
        fallbackDevice: SmartDevice,
        fallbackControl: FacetControl
    ) -> (device: SmartDevice, control: FacetControl, approval: FacetDragApproval?) {
        let reportedDev = reportedDevice(for: deviceId)
        let evaluationDevice = reportedDev ?? Self.deviceWithoutUnreportedBaseline(fallbackDevice)
        let reportedControl: FacetControl
        if let reported = reportedFacetControl(deviceId: deviceId, controlId: controlId) {
            reportedControl = reported
        } else {
            // Without a real snapshot baseline, never trust the optimistic value on `deviceFacets`:
            // treat the starting reading as unknown so any leftover drag value cannot skip a prompt.
            var unknownStart = fallbackControl
            unknownStart.value = nil
            reportedControl = unknownStart
        }
        let lowerName = reportedControl.name.lowercased()
        let isTargetTemperature = lowerName == "target-temperature" || lowerName.hasSuffix("-target-temperature")
        if reportedDev == nil,
           isTargetTemperature,
           value?.doubleValue != nil,
           case .climate = fallbackDevice.kind,
           fallbackDevice.name.contains("热水器") {
            return (fallbackDevice, reportedControl, .unknownStartTemperature)
        }
        if let reportedApproval = ManualControlPolicy.facetConfirmationKind(
            reportedControl,
            value: value,
            for: evaluationDevice
        ) {
            return (evaluationDevice, reportedControl, reportedApproval)
        }
        if reportedDev != nil, origin != reportedControl.value {
            var originControl = reportedControl
            originControl.value = origin
            if let originApproval = ManualControlPolicy.facetConfirmationKind(
                originControl,
                value: value,
                for: evaluationDevice
            ) {
                return (evaluationDevice, originControl, originApproval)
            }
        }
        if fallbackDevice != evaluationDevice,
           let localDeviceApproval = ManualControlPolicy.facetConfirmationKind(
               reportedControl,
               value: value,
               for: fallbackDevice
           ) {
            return (fallbackDevice, reportedControl, localDeviceApproval)
        }
        return (evaluationDevice, reportedControl, nil)
    }

    /// Final fail-closed gate for a debounced facet slider: re-evaluates the requested value
    /// against the latest reported device and facet state right before sending.
    private func facetSliderMaySend(
        deviceId: String,
        controlId: String,
        pending: FacetWriteState
    ) -> Bool {
        guard let reportedDevice = reportedDevice(for: deviceId),
              let reportedControl = reportedFacetControl(deviceId: deviceId, controlId: controlId) else {
            return false
        }
        if let required = ManualControlPolicy.facetConfirmationKind(
            reportedControl,
            value: pending.value,
            for: reportedDevice
        ) {
            guard pending.approval == required else { return false }
        }
        if let liveDevice = devices.first(where: { $0.id == deviceId }),
           liveDevice != reportedDevice,
           let liveRequired = ManualControlPolicy.facetConfirmationKind(
               reportedControl,
               value: pending.value,
               for: liveDevice
           ) {
            return pending.approval == liveRequired
        }
        return true
    }

    private func rollbackFacetWrite(
        deviceId: String,
        controlId: String,
        key: String,
        pending: FacetWriteState
    ) {
        let restoredValue: JSONValue?
        if snapshotGeneration != pending.originSnapshotGeneration,
           let reported = reportedFacetControl(deviceId: deviceId, controlId: controlId) {
            restoredValue = reported.value
        } else {
            restoredValue = pending.origin
        }
        if let index = deviceFacets[deviceId]?.firstIndex(where: { $0.id == controlId }),
           deviceFacets[deviceId]?[index].target?.isAction == false {
            deviceFacets[deviceId]?[index].value = restoredValue
        }
        optimisticFacetLocks.removeValue(forKey: key)
        if let bannerID = pending.bannerID, undoBanner?.id == bannerID {
            undoTimerTask?.cancel()
            undoBanner = nil
        }
    }

    /// Runs the pre-send confirmation gate for `pending`; on mismatch, rolls back the optimistic
    /// facet value, lock and undo banner, shows the re-confirmation error toast, and returns `false`.
    func verifyPendingFacetSliderBeforeSend(
        device: SmartDevice,
        controlId: String,
        key: String,
        pending: FacetWriteState
    ) -> Bool {
        let deviceId = device.id
        guard !facetSliderMaySend(deviceId: deviceId, controlId: controlId, pending: pending) else {
            return true
        }
        rollbackFacetWrite(
            deviceId: deviceId,
            controlId: controlId,
            key: key,
            pending: pending
        )
        let toastDevice = reportedDevice(for: deviceId) ?? device
        showControlFailure(
            ManualWriteNeedsFacetConfirmation(),
            device: toastDevice,
            adjustment: true
        )
        return false
    }

    private func dispatchFacetWrite(
        device: SmartDevice, controlId: String, pending: FacetWriteState,
        command: DeviceCommand, adjustment: Bool
    ) {
        let deviceId = device.id
        let key = facetWriteKey(deviceId, controlId)
        let context = controlContextID
        let modalContext = captureModalDeviceContext(for: device)
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            defer {
                if let self, self.facetWrites[key]?.token == pending.token {
                    self.facetWrites.removeValue(forKey: key)
                    self.debounceTasks.removeValue(forKey: key)
                }
            }
            if adjustment {
                let debounceSleep = self?.controlDebounceSleep
                let debounceInterval = self?.controlDebounceInterval ?? .milliseconds(280)
                try? await debounceSleep?(debounceInterval)
            }
            guard !Task.isCancelled, let self, self.controlContextID == context,
                  self.facetWrites[key]?.token == pending.token else { return }
            guard self.matchesModalDeviceContext(modalContext) else {
                self.rollbackFacetWrite(
                    deviceId: deviceId,
                    controlId: controlId,
                    key: key,
                    pending: pending
                )
                return
            }
            if adjustment,
               !self.verifyPendingFacetSliderBeforeSend(
                   device: device,
                   controlId: controlId,
                   key: key,
                   pending: pending
               ) {
                return
            }
            self.facetWrites[key]?.phase = .inFlight
            do {
                try await self.executeDeviceCommand(command)
            } catch {
                guard self.controlContextID == context,
                      self.facetWrites[key]?.token == pending.token else { return }
                self.rollbackFacetWrite(
                    deviceId: deviceId,
                    controlId: controlId,
                    key: key,
                    pending: pending
                )
                self.showControlFailure(error, device: device, adjustment: adjustment)
            }
        }
    }

    public func setPlugChildLock(_ deviceId: String, locked: Bool) {
        guard let previous = controllableDevice(deviceId), case .plug(var s) = previous.kind,
              let lockEid = s.childLockEntityId else { return }
        var updated = previous
        s.isChildLocked = locked
        updated.kind = .plug(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: lockEid, isOn: locked),
            lock: .seconds(2.0),
            mutate: { device in
                guard case .plug(var spec) = device.kind else { return }
                spec.isChildLocked = locked
                device.kind = .plug(spec)
            }
        )
    }

    public func setFridgeMode(_ deviceId: String, mode: String) {
        guard let previous = controllableDevice(deviceId), case .fridge(var s) = previous.kind,
              let modeEid = s.modeEntityId else { return }
        var updated = previous
        s.currentMode = mode
        updated.kind = .fridge(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSelectOption(entityId: modeEid, option: mode),
            lock: .seconds(2.0),
            mutate: { device in
                guard case .fridge(var spec) = device.kind else { return }
                spec.currentMode = mode
                device.kind = .fridge(spec)
            }
        )
    }

    public func stepFridgeTargetTemp(_ deviceId: String, isFreezer: Bool, delta: Double) {
        guard let previous = controllableDevice(deviceId), case .fridge(var s) = previous.kind else { return }
        let entityId: String
        let next: Double
        if isFreezer {
            guard let eid = s.freezerTargetEntityId else { return }
            entityId = eid
            next = max(-24, min(-15, s.freezerTargetTemp + delta))
            s.freezerTargetTemp = next
            s.freezerTargetPresent = true
        } else {
            guard let eid = s.fridgeTargetEntityId else { return }
            entityId = eid
            next = max(2, min(8, s.fridgeTargetTemp + delta))
            s.fridgeTargetTemp = next
            s.fridgeTargetPresent = true
        }
        var updated = previous
        updated.kind = .fridge(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setNumberValue(entityId: entityId, value: next),
            lock: .seconds(2.5), debounceKey: "\(deviceId).\(isFreezer ? "freezer" : "fridge")",
            mutate: { device in
                guard case .fridge(var spec) = device.kind else { return }
                if isFreezer {
                    spec.freezerTargetTemp = next
                    spec.freezerTargetPresent = true
                } else {
                    spec.fridgeTargetTemp = next
                    spec.fridgeTargetPresent = true
                }
                device.kind = .fridge(spec)
            }
        )
    }

    public func performVacuumAction(_ deviceId: String, action: VacuumAction) {
        guard let initial = controllableDevice(deviceId),
              case .vacuum(let initialSpec) = initial.kind else { return }
        let operation: IntentOperation = action == .start ? .power(true) : .power(false)
        guard let confirmed = confirmAndResolveManualControl(operation, for: initial),
              case .vacuum(let currentSpec) = confirmed.device.kind,
              currentSpec.entityId == initialSpec.entityId,
              let change = Self.vacuumActionChange(confirmed.device, action: action) else { return }
        let previous = confirmed.device
        commitManualWrite(
            from: previous,
            to: change.updated,
            command: change.command,
            lock: .seconds(2.5),
            mutate: { device in
                if let next = Self.vacuumActionChange(device, action: action)?.updated {
                    device = next
                }
            }
        )
    }

    /// The status a vacuum shows while `action` runs. Shared by the card and Raycast.
    nonisolated static func vacuumActionChange(
        _ device: SmartDevice,
        action: VacuumAction
    ) -> (updated: SmartDevice, command: DeviceCommand)? {
        guard case .vacuum(var s) = device.kind else { return nil }
        switch action {
        case .start: s.status = "cleaning"
        case .pause: s.status = "paused"
        case .returnToBase: s.status = "returning"
        }
        var updated = device
        updated.kind = .vacuum(s)
        return (updated, .vacuumAction(entityId: s.entityId, action: action))
    }

    public func setSpeakerVolume(_ deviceId: String, percent: Int) {
        guard let previous = controllableDevice(deviceId) else { return }
        let clamped = max(0, min(100, percent))
        var updated = previous
        let mediaEid: String
        switch previous.kind {
        case .speaker(var s):
            s.volumePercent = clamped
            s.volumePresent = true
            updated.kind = .speaker(s)
            mediaEid = s.mediaEntityId
        case .tv(var s):
            guard s.volumeWritable else { return }
            s.volumePercent = clamped
            s.volumePresent = true
            updated.kind = .tv(s)
            mediaEid = s.mediaEntityId
        default:
            return
        }
        commitManualWrite(
            from: previous, to: updated,
            command: .mediaSetVolume(entityId: mediaEid, volumeLevel: Double(clamped) / 100.0),
            lock: .seconds(2.5), debounceKey: "\(deviceId).volume",
            mutate: { device in
                switch device.kind {
                case .speaker(var spec):
                    spec.volumePercent = clamped
                    spec.volumePresent = true
                    device.kind = .speaker(spec)
                case .tv(var spec):
                    spec.volumePercent = clamped
                    spec.volumePresent = true
                    device.kind = .tv(spec)
                default:
                    break
                }
            }
        )
    }

    public func toggleSpeakerMute(_ deviceId: String) {
        guard let previous = controllableDevice(deviceId), case .speaker(var s) = previous.kind,
              let muteEid = s.muteSwitchEntityId else { return }
        let nextMuted = !s.isMuted
        var updated = previous
        s.isMuted = nextMuted
        updated.kind = .speaker(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: muteEid, isOn: nextMuted),
            lock: .seconds(2.0),
            mutate: { device in
                guard case .speaker(var spec) = device.kind else { return }
                spec.isMuted = nextMuted
                device.kind = .speaker(spec)
            }
        )
    }

    public func toggleTVMute(_ deviceId: String) {
        guard let previous = controllableDevice(deviceId), case .tv(var s) = previous.kind else { return }
        let entityId: String
        if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
            entityId = LGWebOSProtocol.muteEntityId
        } else if let muteEid = s.muteSwitchEntityId {
            entityId = muteEid
        } else {
            return
        }
        let nextMuted = !s.isMuted
        var updated = previous
        s.isMuted = nextMuted
        updated.kind = .tv(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: entityId, isOn: nextMuted),
            lock: .seconds(2.0),
            mutate: { device in
                guard case .tv(var spec) = device.kind else { return }
                spec.isMuted = nextMuted
                device.kind = .tv(spec)
            }
        )
    }

    public func toggleTVScreenOff(_ deviceId: String) {
        guard let previous = controllableDevice(deviceId), case .tv(var s) = previous.kind else { return }
        let nextScreenOff = !s.isScreenOff
        var updated = previous
        s.isScreenOff = nextScreenOff
        if !nextScreenOff && (s.state == "off" || s.state == "standby") {
            s.state = "on"
        }
        updated.kind = .tv(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: nextScreenOff),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .tv(var spec) = device.kind else { return }
                spec.isScreenOff = nextScreenOff
                if !nextScreenOff && (spec.state == "off" || spec.state == "standby") {
                    spec.state = "on"
                }
                device.kind = .tv(spec)
            }
        )
    }

    public func selectTVSource(_ deviceId: String, source: String) {
        guard let previous = controllableDevice(deviceId), case .tv(var s) = previous.kind else { return }
        var updated = previous
        s.currentSource = source
        s.state = "on"
        s.isScreenOff = false
        updated.kind = .tv(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .mediaSelectSource(entityId: s.mediaEntityId, source: source),
            lock: .seconds(2.5),
            mutate: { device in
                guard case .tv(var spec) = device.kind else { return }
                spec.currentSource = source
                spec.state = "on"
                spec.isScreenOff = false
                device.kind = .tv(spec)
            }
        )
    }

    // MARK: TV Now Playing & remote pad

    public enum MediaTransport: Sendable { case playPause, next, previous }

    private static func mediaPlaybackTarget(for kind: DeviceKind) -> (entityId: String, playback: MediaPlaybackState)? {
        switch kind {
        case .tv(let s): return s.playback.map { (s.mediaEntityId, $0) }
        case .speaker(let s): return s.playback.map { (s.mediaEntityId, $0) }
        default: return nil
        }
    }

    /// Play/pause and track skip for TVs and speakers. The device reports the resulting state.
    public func sendMediaTransport(_ deviceId: String, _ transport: MediaTransport) {
        guard let device = controllableDevice(deviceId), let target = Self.mediaPlaybackTarget(for: device.kind) else { return }
        let command: DeviceCommand
        switch transport {
        case .playPause: guard target.playback.canPlayPause else { return }; command = .mediaPlayPause(entityId: target.entityId)
        case .next: guard target.playback.canSkipTrack else { return }; command = .mediaNextTrack(entityId: target.entityId)
        case .previous: guard target.playback.canSkipTrack else { return }; command = .mediaPreviousTrack(entityId: target.entityId)
        }
        commitManualWrite(from: device, to: nil, command: command, lock: nil)
    }

    /// One seek per finished drag; the drawer's `MediaSeekGuard` holds the bar on the target meanwhile.
    public func seekMedia(_ deviceId: String, toSeconds target: Double) {
        guard target.isFinite, let device = controllableDevice(deviceId), let media = Self.mediaPlaybackTarget(for: device.kind),
              media.playback.canSeek, let duration = media.playback.durationSec, duration > 0 else { return }
        let clamped = min(max(target, 0), duration)
        commitManualWrite(from: device, to: nil, command: .mediaSeek(entityId: media.entityId, positionSec: clamped), lock: nil)
    }

    /// A Xiaomi TV's own key action wins; otherwise the paired Home Assistant `remote.*`.
    public func sendTVRemoteKey(_ deviceId: String, key: TVRemoteKey) {
        guard let device = controllableDevice(deviceId), case .tv(let s) = device.kind,
              s.supportsRemotePad else { return }
        let command: DeviceCommand
        if let action = s.miotRemoteActions[key.rawValue] {
            command = .remoteSendKey(entityId: action, key: key)
        } else if let remote = s.remoteEntityId {
            command = .remoteSendKey(entityId: remote, key: key)
        } else {
            return
        }
        if let reason = miotCommandWriteRejection(for: command.targetEntityId)
            ?? haCommandWriteRejection(for: command.targetEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        commitManualWrite(from: device, to: nil, command: command, lock: nil)
    }

    @discardableResult
    public func sendSpeakerText(_ deviceId: String, text: String, asDirective: Bool) -> Bool {
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: deviceId) != nil { return false }
        guard !rejectWritesBlockedByMiSession() else { return false }
        guard !rejectControlWhileLocked() else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(let s) = devices[idx].kind else { return false }
        let initial = devices[idx]
        let modalContext = captureModalDeviceContext(for: initial)

        let targetEid = asDirective ? s.directiveNotifyEntityId : s.ttsNotifyEntityId
        guard let eid = targetEid else {
            showToast(L10n.tr("该音箱不支持此指令通道", "This speaker does not support that channel"), isError: true)
            return false
        }

        if asDirective {
            let prompt = ManualControlPolicy.speakerDirectiveConfirmation(text: trimmed, for: initial)
            guard let handler = manualControlConfirmationHandler, handler(prompt) else {
                showToast(L10n.tr("已取消高风险操作", "High-risk action cancelled."), isError: true)
                return false
            }
            guard let current = resolvePostModalDevice(modalContext),
                  case .speaker(let currentSpec) = current.kind,
                  currentSpec.directiveNotifyEntityId == eid else {
                return false
            }
        }

        Task { [weak self] in
            guard let self, self.matchesModalDeviceContext(modalContext) else { return }
            do {
                try await self.executeDeviceCommand(.sendNotifyMessage(entityId: eid, message: trimmed))
                guard self.matchesModalDeviceContext(modalContext) else { return }
                self.showToast(
                    asDirective
                        ? L10n.tr("已向小爱下发指令：「\(trimmed)」", "Sent command to XiaoAi: \"\(trimmed)\"")
                        : L10n.tr("小爱已播报：「\(trimmed)」", "XiaoAi announced: \"\(trimmed)\"")
                )
            } catch {
                guard self.matchesModalDeviceContext(modalContext) else { return }
                self.showToast(L10n.tr("发送失败：\(error.localizedDescription)", "Failed to send: \(error.localizedDescription)"), isError: true)
            }
        }
        return true
    }

    public func pressDeviceButton(_ buttonEntityId: String, label: String) {
        let command = DeviceCommand.pressButton(entityId: buttonEntityId)
        if let ownerId = owningDeviceIdForCommand(command),
           rejectDeviceWriteIfCapabilityDisabled(deviceId: ownerId) != nil {
            return
        }
        if let reason = miotCommandWriteRejection(for: buttonEntityId)
            ?? haCommandWriteRejection(for: buttonEntityId) {
            showToast(reason.userMessage, isError: true)
            return
        }
        guard !rejectWritesBlockedByMiSession() else { return }
        guard !rejectControlWhileLocked() else { return }
        Task {
            do {
                try await executeDeviceCommand(command)
                showToast(L10n.tr("已触发：\(label)", "Triggered: \(label)"))
            } catch let blocked as CapabilityControlBlockedError {
                showToast(blocked.reason.userMessage, isError: true)
            } catch {
                showToast(L10n.tr("\(label) 执行失败", "\(label) failed"), isError: true)
            }
        }
    }

    // MARK: - Camera Controls & Live Stream Resolution (#97)

    public func setCameraMotionDetection(_ deviceId: String, enabled: Bool) {
        guard let previous = controllableDevice(deviceId), case .camera(var s) = previous.kind,
              let motionEid = s.motionDetectionEntityId else { return }
        var updated = previous
        s.isMotionDetectionOn = enabled
        updated.kind = .camera(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSwitch(entityId: motionEid, isOn: enabled),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .camera(var spec) = device.kind else { return }
                spec.isMotionDetectionOn = enabled
                device.kind = .camera(spec)
            }
        )
    }

    public func setCameraNightShot(_ deviceId: String, mode: String) {
        guard let previous = controllableDevice(deviceId), case .camera(var s) = previous.kind,
              s.availableNightShots.contains(mode) else { return }
        var updated = previous
        s.nightShot = mode
        updated.kind = .camera(s)
        commitManualWrite(
            from: previous, to: updated,
            command: .setSelectOption(entityId: s.entityId, option: mode),
            lock: .seconds(2.2),
            mutate: { device in
                guard case .camera(var spec) = device.kind else { return }
                spec.nightShot = mode
                device.kind = .camera(spec)
            }
        )
    }

    public func openCameraLiveView(_ deviceId: String) {
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: deviceId) != nil { return }
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else { return }
        guard device.isOnline else {
            showToast(L10n.tr("\(device.name) 当前离线", "\(device.name) is offline"), isError: true)
            return
        }
        guard !rejectControlWhileLocked() else { return }
        activeLiveCameraDeviceId = device.id
        onOpenCameraLiveView?(device)
    }

    public func cameraCustomStreamURL(for deviceId: String) -> String? {
        guard let map = userDefaults.dictionary(forKey: Self.cameraStreamURLsKey) as? [String: String],
              let raw = map[deviceId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    public func setCameraCustomStreamURL(_ urlString: String?, for deviceId: String) {
        var map = (userDefaults.dictionary(forKey: Self.cameraStreamURLsKey) as? [String: String]) ?? [:]
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            map.removeValue(forKey: deviceId)
        } else {
            map[deviceId] = trimmed
        }
        userDefaults.set(map, forKey: Self.cameraStreamURLsKey)
    }

    public func cameraStreamQuality(for deviceId: String) -> XiaomiCameraStreamQuality {
        guard let map = userDefaults.dictionary(forKey: Self.cameraStreamQualityKey) as? [String: String],
              let raw = map[deviceId],
              let quality = XiaomiCameraStreamQuality(rawValue: raw) else {
            return .storageDefault
        }
        return quality
    }

    public func setCameraStreamQuality(_ quality: XiaomiCameraStreamQuality, for deviceId: String) {
        var map = (userDefaults.dictionary(forKey: Self.cameraStreamQualityKey) as? [String: String]) ?? [:]
        map[deviceId] = quality.rawValue
        userDefaults.set(map, forKey: Self.cameraStreamQualityKey)
    }

    public var supportsCustomCameraStreams: Bool { !(provider is DemoHomeProvider) }

    public func resolveCameraStream(
        for deviceId: String, channel: Int = 0, audioEnabled: Bool = false, genericStream: GenericCameraSource.Stream = .main
    ) async throws -> CameraStreamSource {
        if let reason = capabilityWriteRejection(forDeviceId: deviceId) {
            throw CapabilityControlBlockedError(reason: reason)
        }
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("未找到该摄像头设备", "Camera device not found"))
        }
        if deviceId.hasPrefix(GenericCameraSource.devicePrefix) {
            guard !rejectControlWhileLocked(), let camera = genericCamera(for: deviceId),
                  let credentials = genericCameraCredentials(camera) else { throw GenericCameraError.invalidConnection }
            return try await XiaomiCameraBridge.shared.startGenericCamera(
                camera, credentials: credentials, stream: genericStream, audioEnabled: audioEnabled,
                allowPublic: hasGenericCameraConsent(camera)
            )
        }
        if supportsCustomCameraStreams,
           let custom = cameraCustomStreamURL(for: deviceId),
           let url = URL(string: custom),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            let lower = custom.lowercased()
            if lower.contains("stream.mp4") {
                return .liveMP4(url, mjpegFallback: nil, ptz: nil)
            }
            if lower.contains("mjpeg") || lower.contains("mpjpeg") {
                return .mjpeg(url)
            }
            if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains("snapshot") || lower.contains("camera_proxy") || lower.contains("frame.jpeg") {
                return .snapshot(url)
            }
            return .hls(url)
        }
        let quality = cameraStreamQuality(for: deviceId)
        if let dual = provider as? DualSourceHomeProvider {
            var explicitlyDisabledBackends: Set<HomeBackend> = []
            if explicitlyDisabledConnections.contains(.homeAssistant)
                || explicitlyDisabledScopes.contains(homeAssistantScopeIdentifier) {
                explicitlyDisabledBackends.insert(.homeAssistant)
            }
            if explicitlyDisabledConnections.contains(.xiaomiCloud)
                || (!miAccounts.isEmpty && miAccounts.allSatisfy { explicitlyDisabledScopes.contains($0.id) }) {
                explicitlyDisabledBackends.insert(.xiaomiCloud)
            }
            return try await dual.resolveCameraStream(
                for: device, quality: quality, channel: channel, audioEnabled: audioEnabled, explicitlyDisabledBackends: explicitlyDisabledBackends
            )
        }
        return try await provider.resolveCameraStream(for: device, quality: quality, channel: channel, audioEnabled: audioEnabled)
    }

    public func stopCameraStream(for deviceId: String) async {
        if deviceId.hasPrefix(GenericCameraSource.devicePrefix) {
            await XiaomiCameraBridge.shared.stopGenericCamera(deviceID: deviceId)
            return
        }
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        await stopCameraStream(device: device)
    }

    /// Releases a stream for a card that may already have left `devices` (a closed camera type).
    public func stopCameraStream(device: SmartDevice) async {
        if device.id.hasPrefix(GenericCameraSource.devicePrefix) {
            await XiaomiCameraBridge.shared.stopGenericCamera(deviceID: device.id)
            return
        }
        await provider.stopCameraStream(for: device)
    }
}

package enum PanelControlAction: Equatable {
    case primary
    case coverMotor(String)
    case coverPosition(Int)
    case temperatureStep(Double)
    case mode(String)
    case applianceAction(ApplianceAction)
    case facetAction(FacetControl, portion: Int?)
}

@MainActor
package final class PanelControlConfirmation {
    fileprivate let device: SmartDevice
    fileprivate let context: ModalDeviceContext
    fileprivate let action: PanelControlAction
    package let level: PanelConfirmationLevel
    fileprivate var consumed = false

    fileprivate init(
        device: SmartDevice, context: ModalDeviceContext, action: PanelControlAction, level: PanelConfirmationLevel
    ) {
        self.device = device
        self.context = context
        self.action = action
        self.level = level
    }
}

extension HomeStore {
    package func panelConfirmationLevel(for device: SmartDevice, action: PanelControlAction) -> PanelConfirmationLevel? {
        guard device.isOnline else { return nil }
        let operation: IntentOperation
        switch action {
        case .primary:
            guard device.isPrimaryToggleable, let plannedOperation = primaryPlan(for: device)?.1 else { return nil }
            operation = plannedOperation
        case .coverMotor(let description):
            guard case .cover(let spec) = device.kind else { return nil }
            if spec.openDescription?.caseInsensitiveCompare(description) == .orderedSame {
                operation = .power(true)
            } else if spec.closeDescription?.caseInsensitiveCompare(description) == .orderedSame {
                operation = .power(false)
            } else {
                return nil
            }
        case .coverPosition(let target):
            guard case .cover(let spec) = device.kind, spec.positionWritable else { return nil }
            let reported = lastCoverPositions[device.id] ?? spec.reportedPositionPercent
            let direction = reported == nil
                ? true
                : Self.coverDragDirection(from: reported, to: target)
                    ?? Self.coverDragDirection(from: spec.positionPercent, to: target)
            guard let direction else { return nil }
            operation = .power(direction)
        case .temperatureStep(let delta):
            switch device.kind {
            case .climate(let spec) where spec.temperatureWritable:
                operation = .targetTemperature(max(spec.minTemp, min(spec.maxTemp, spec.targetTemperature + delta)))
            case .appliance(let spec) where spec.temperatureWritable:
                guard let target = spec.targetTemperature else { return nil }
                operation = .targetTemperature(Self.applianceStepTarget(spec, target: target, delta: delta))
            default: return nil
            }
        case .mode(let mode):
            switch device.kind {
            case .climate: operation = .hvacMode(mode)
            case .appliance(let spec) where spec.heats && !spec.isOn && ApplianceSpec.modeStartsHeating(mode):
                operation = .power(true)
            default: return nil
            }
        case .applianceAction(let action):
            guard case .appliance(let spec) = device.kind, spec.startAction == action else { return nil }
            operation = .power(true)
        case .facetAction(let control, _):
            guard ManualControlPolicy.facetRequiresConfirmation(control, value: nil, for: device) else { return nil }
            return ManualControlPolicy.panelConfirmationLevel(for: device)
        }
        return ManualControlPolicy.panelConfirmationLevel(
            operation, for: device, markedLightIds: SwitchLightMarks.load(defaults: userDefaults)
        )
    }

    package func beginPanelConfirmation(
        for device: SmartDevice, action: PanelControlAction, level: PanelConfirmationLevel
    ) -> PanelControlConfirmation? {
        let context = captureModalDeviceContext(for: device)
        guard let live = resolvePostModalDevice(context, requireOnline: true),
              panelConfirmationMatches(device, live, action: action),
              panelConfirmationLevel(for: live, action: action) == level else { return nil }
        return PanelControlConfirmation(device: live, context: context, action: action, level: level)
    }

    @discardableResult
    package func performPanelConfirmation(_ confirmation: PanelControlConfirmation) -> Task<Bool, Never>? {
        guard !confirmation.consumed else { return nil }
        confirmation.consumed = true
        guard let live = resolvePostModalDevice(confirmation.context, requireOnline: true),
              panelConfirmationMatches(confirmation.device, live, action: confirmation.action),
              panelConfirmationLevel(for: live, action: confirmation.action) == confirmation.level else { return nil }
        switch confirmation.action {
        case .primary:
            return togglePrimary(live, offersSwitchLightMark: false, panelConfirmed: true)
        case .coverMotor(let description):
            setCoverMotor(live.id, description: description, panelConfirmed: true)
        case .coverPosition(let target):
            setCoverPosition(live.id, percent: target, panelConfirmed: true)
        case .temperatureStep(let delta):
            if case .appliance = live.kind {
                stepApplianceTemperature(live.id, delta: delta, panelConfirmed: true)
            } else {
                stepClimateTemperature(live.id, delta: delta, panelConfirmed: true)
            }
        case .mode(let mode):
            if case .appliance = live.kind {
                setApplianceMode(live.id, mode: mode, panelConfirmed: true)
            } else {
                setClimateMode(live.id, mode: mode, panelConfirmed: true)
            }
        case .applianceAction(let action):
            runApplianceAction(live.id, action: action, panelConfirmed: true)
        case .facetAction(let control, let portion):
            runFacetAction(live.id, controlId: control.id, portion: portion, panelConfirmed: true)
        }
        return nil
    }

    private func panelConfirmationMatches(_ captured: SmartDevice, _ live: SmartDevice, action: PanelControlAction) -> Bool {
        guard captured.accountId == live.accountId,
              ManualControlHazardProfile(captured) == ManualControlHazardProfile(live) else { return false }
        switch action {
        case .primary:
            return primaryPlan(for: captured)?.0 == primaryPlan(for: live)?.0
        case .coverMotor:
            guard case .cover(let before) = captured.kind, case .cover(let after) = live.kind else { return false }
            return before.entityId == after.entityId
                && before.openDescription == after.openDescription
                && before.closeDescription == after.closeDescription
        case .coverPosition, .temperatureStep, .mode:
            return captured.kind == live.kind
        case .applianceAction(let action):
            guard case .appliance(let after) = live.kind else { return false }
            return after.startAction == action
        case .facetAction(let control, _):
            return deviceFacets[live.id]?.first(where: { $0.id == control.id }) == control
        }
    }
}
