import Foundation

// Primary toggle and detail-drawer controls backed by optimistic state (#48).
extension HomeStore {
    /// A manual card action was confirmed by the device: GrokBall celebrates (#114) and the action
    /// is recorded into the habit memory for the current time bucket (#113).
    /// Returns the receipt so an undo banner can roll the record back; nil when learning is off.
    @discardableResult
    func confirmManualControl(intents: [DeviceIntent]) -> UserHabitMemory.RecordingReceipt? {
        celebrateGrokBall()
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

    @discardableResult
    public func togglePrimary(_ device: SmartDevice) -> Task<Bool, Never>? {
        // A tap on an LG TV is answered over the LAN, so the expired Mi session does not refuse it.
        guard !rejectWritesBlockedByMiSession(needsMi: !lgClientServes(device)) else { return nil }
        guard device.isOnline else {
            showToast(L10n.tr("\(device.name) 当前离线（可能断电）", "\(device.name) is offline (unplugged)"), isError: true)
            return nil
        }
        guard device.isPrimaryToggleable else {
            if hasDetailDrawer(for: device) { toggleExpanded(device.id) }
            return nil
        }
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return nil }
        let previous = devices[idx]
        guard !rejectControlWhileLocked() else { return nil }
        if case .cover(let s) = previous.kind {
            if s.isMoving {
                // Stopping a moving cover is a de-escalation action (or expands the drawer if
                // pause is unavailable) and never asks for hazard confirmation (#298).
            } else if let pos = s.positionPercent,
                      (pos == 0 ? s.openDescription : s.closeDescription) != nil {
                guard allowManualControl(.power(pos == 0), for: previous) else { return nil }
            } else {
                toggleExpanded(device.id)
                return nil
            }
        } else {
            if case .valve(let spec) = previous.kind {
                let opening = !spec.isOpen
                guard opening ? spec.openWritable : spec.closeWritable else { return nil }
            }
            let operation: IntentOperation
            switch previous.kind {
            case .vacuum(let spec):
                operation = .power(!spec.isCleaning)
            case .plug(let spec) where spec.switchEntityId.hasPrefix("button."):
                // A momentary plug button may toggle or trigger something; treat it as an activation.
                operation = .power(true)
            default:
                operation = .power(!previous.isActiveOn)
            }
            guard allowManualControl(operation, for: previous) else { return nil }
        }
        var updated = previous
        var command: DeviceCommand?
        // The cover travel origin this tap writes before the send. A tap that never reaches the
        // device must put it back, or a genuine report at that position is rejected later.
        var coverOrigin: (prior: Int?, written: Int)?
        let lockRevision = optimisticLockRevision[device.id]

        switch updated.kind {
        case .light(var s):
            s.isOn.toggle()
            updated.kind = .light(s)
            command = .setLightPower(entityId: s.entityId, isOn: s.isOn)

        case .climate(var s):
            s.isOn.toggle()
            let targetMode = s.isOn ? (s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode) : "off"
            s.hvacMode = targetMode
            updated.kind = .climate(s)
            command = .setClimatePower(entityId: s.entityId, isOn: s.isOn, fallbackMode: targetMode)

        case .fan(var s):
            s.isOn.toggle()
            updated.kind = .fan(s)
            command = .setFanPower(entityId: s.entityId, isOn: s.isOn)

        case .plug(var s):
            if s.switchEntityId.hasPrefix("button.") {
                command = .pressButton(entityId: s.switchEntityId)
            } else {
                s.isOn.toggle()
                updated.kind = .plug(s)
                command = .setSwitch(entityId: s.switchEntityId, isOn: s.isOn)
            }

        case .vacuum(var s):
            let startCleaning = !s.isCleaning
            s.status = startCleaning ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            command = .vacuumAction(entityId: s.entityId, action: startCleaning ? .start : .returnToBase)

        case .tv(var s):
            let turnOn = (s.state == "off" || s.state == "standby")
            s.state = turnOn ? "on" : "standby"
            if turnOn { s.isScreenOff = false }
            updated.kind = .tv(s)
            if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
                command = .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: turnOn)
            } else if turnOn, let btnId = s.turnOnButtonId {
                command = .pressButton(entityId: btnId)
            } else {
                toggleExpanded(device.id)
                return nil
            }


        case .camera(var s):
            s.isOn.toggle()
            updated.kind = .camera(s)
            command = .setSwitch(entityId: s.entityId, isOn: s.isOn)
        case .cover(var s):
            // A cover tap is a three-way control: travel stops, otherwise open/close. Pause needs
            // no position reading, so a moving cover stops before the position guard (#298).
            // The stored origin is kept before `activeCoverOrigin` can drop a stale one: a tap whose
            // claim fails has to leave the in-flight tap's origin in place.
            let priorOrigin = coverCommandOrigins[device.id]
            let origin = activeCoverOrigin(for: device.id, fallback: s.positionPercent)
            if s.isMoving {
                guard let pause = s.pauseDescription else {
                    toggleExpanded(device.id)
                    return nil
                }
                s.motion = .stopped
                s.motionIsInferred = false
                updated.kind = .cover(s)
                if let origin {
                    coverOrigin = (priorOrigin, origin)
                    coverCommandOrigins[device.id] = origin
                }
                command = .setSelectOption(entityId: s.entityId, option: pause)
            } else {
                guard let pos = s.positionPercent,
                      let action = (pos == 0 ? s.openDescription : s.closeDescription) else {
                    toggleExpanded(device.id)
                    return nil
                }
                coverOrigin = (priorOrigin, pos)
                coverCommandOrigins[device.id] = pos
                let shouldOpen = pos == 0
                s.positionPercent = shouldOpen ? 100 : 0
                s.motion = shouldOpen ? .opening : .closing
                s.motionIsInferred = false
                updated.kind = .cover(s)
                command = .setSelectOption(entityId: s.entityId, option: action)
            }
        case .appliance(var s):
            s.isOn.toggle()
            updated.kind = .appliance(s)
            command = .setSwitch(entityId: s.powerEntityId, isOn: s.isOn)

        case .generic(var s):
            guard let control = s.powerControl,
                  case .property(let entityId, let piid) = control.target else {
                toggleExpanded(device.id)
                return nil
            }
            s.isOn.toggle()
            s.powerControl?.value = .bool(s.isOn)
            updated.kind = .generic(s)
            command = .setMiotProperty(entityId: entityId, piid: piid, value: .bool(s.isOn))
        case .humidifier(var s):
            s.isOn.toggle()
            updated.kind = .humidifier(s)
            command = .setSwitch(entityId: s.entityId, isOn: s.isOn)

        case .valve(var s):
            let open = !s.isOpen
            s.isOpen = open
            s.motion = nil
            updated.kind = .valve(s)
            command = .setSwitch(entityId: s.entityId, isOn: open)

        case .speaker, .fridge, .sensor:
            toggleExpanded(device.id)
            return nil
        }

        guard let cmd = command else { return nil }
        let context = controlContextID
        let isMomentaryButton = device.isMomentaryButton
        if isMomentaryButton {
            return Task {
                guard self.controlContextID == context else { return false }
                do {
                    try await self.executeDeviceCommand(cmd)
                    guard self.controlContextID == context else { return false }
                    self.celebrateGrokBall()
                    self.showToast(L10n.tr("已触发 \(device.name)", "Triggered \(device.name)"), isError: false)
                    return true
                } catch {
                    guard self.controlContextID == context else { return false }
                    self.showToast(L10n.tr("\(device.name) 触发失败", "Failed to trigger \(device.name)"), isError: true)
                    return false
                }
            }
        }

        guard let ticket = self.readBackTickets.claim(device.id) else {
            // An earlier tap still owns the read-back, so this one never sends; it must not leave
            // its own travel origin behind.
            self.discardCoverOrigin(coverOrigin, deviceId: device.id, revision: lockRevision)
            return nil
        }
        self.clearManualWriteSession(for: device.id, bumpRevision: coverOrigin == nil)

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
            coverPriorLockEntry = optimisticFieldLocks[.field(device.id, .coverPosition)]
                .flatMap { isOptimisticEntryActive($0, at: now, continuousNow: continuousNow) ? $0 : nil }
            coverWrite = beginOptimisticWrite(from: previous, to: updated, lock: coverOptimisticLockDuration)
        }

        return Task {
            defer { self.readBackTickets.finish(device.id, ticket: ticket) }
            guard self.controlContextID == context else { return false }
            do {
                try await self.executeDeviceCommand(cmd)
                guard self.controlContextID == context else { return false }
                let confirmation = await self.confirmToggleReadBack(deviceId: device.id, requested: updated, ticket: ticket, context: context)
                guard self.controlContextID == context else { return false }
                switch confirmation {
                case .matched:
                    let shown = self.devices.first(where: { $0.id == device.id }) ?? updated
                    self.confirmManualControl(intents: [DeviceIntent(targetId: device.id, operation: .power(updated.isActiveOn))])
                    if case .light = shown.kind, shown.isActiveOn {
                        self.recordManualLightUse(device.id)
                    }
                    return true
                case .unmatched:
                    self.showToast(
                        L10n.tr("\(device.name) 未能读回状态", "\(device.name) state was not read back"),
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
                if self.readBackTickets.isLatest(device.id, ticket: ticket) {
                    if let coverWrite {
                        // A report that confirmed travel removes the lock entry without bumping
                        // the revision, so the entry must still exist for this write to own the
                        // row; the same rule guards the batch rollback. Only then does the tap
                        // restore its pre-tap row, the lock it displaced, and that lock's origin.
                        if self.ownsRow(coverWrite), self.optimisticFieldLocks[.field(device.id, .coverPosition)] != nil {
                            self.revert(coverWrite)
                            if var coverPriorLockEntry {
                                coverPriorLockEntry.revision = self.optimisticLockRevision[device.id] ?? coverPriorLockEntry.revision
                                self.optimisticFieldLocks[.field(device.id, .coverPosition)] = coverPriorLockEntry
                                if let prior = coverOrigin?.prior {
                                    self.coverCommandOrigins[device.id] = prior
                                }
                            }
                        }
                    } else {
                        self.discardCoverOrigin(coverOrigin, deviceId: device.id, revision: lockRevision)
                    }
                }
                self.showToast(L10n.tr("\(device.name) 响应失败", "\(device.name) failed to respond"), isError: true)
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
            let again = snapshotGeneration
            if holdReadBackEcho {
                isHoldingReadBackEcho = true
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.readBackEchoHold = cont
                }
            } else {
                try? await Task.sleep(for: readBackEchoDelay)
            }
            if !readBackTickets.isLatest(deviceId, ticket: ticket) { return .superseded }
            let second = await provider.readBack(deviceId: deviceId)
            if !readBackTickets.isLatest(deviceId, ticket: ticket) { return .superseded }
            if case .failed = second { return .unmatched }
            await settleSnapshot(after: again)
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
        guard let previous = controllableDevice(deviceId),
              case .climate(var s) = previous.kind,
              s.temperatureWritable else { return }
        let nextTemp = max(s.minTemp, min(s.maxTemp, s.targetTemperature + delta))
        guard allowManualControl(.targetTemperature(nextTemp), for: previous) else { return }
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
        guard let previous = controllableDevice(deviceId), case .climate(var s) = previous.kind else { return }
        guard allowManualControl(.hvacMode(mode), for: previous) else { return }
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
        guard let previous = controllableDevice(deviceId), case .appliance(var s) = previous.kind,
              s.modeWritable, s.availableModes.contains(mode) else { return }
        // Picking a heat mode from standby starts the heater, so it takes the same confirmation
        // as the power button. Idle/off modes and appliances without heat stay direct (#4).
        if s.heats, !s.isOn, ApplianceSpec.modeStartsHeating(mode) {
            guard allowManualControl(.power(true), for: previous) else { return }
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

    public func stepApplianceTemperature(_ deviceId: String, delta: Double) {
        guard let previous = controllableDevice(deviceId), case .appliance(var s) = previous.kind,
              s.temperatureWritable, let target = s.targetTemperature else { return }
        let step = s.step > 0 ? s.step : 1
        let raw = max(s.minTemp, min(s.maxTemp, target + delta))
        // A Fahrenheit tap is 5/9 °C, smaller than a coarse step. Round to the nearest step so a
        // small decimal step keeps its adjacent value, then move one step when that is the target.
        var units = ((raw - s.minTemp) / step).rounded()
        if s.minTemp + units * step == target {
            units += delta > 0 ? 1 : -1
        }
        let stepped = s.minTemp + units * step
        let nextTemp = max(s.minTemp, min(s.maxTemp, stepped))
        guard nextTemp != target, allowManualControl(.targetTemperature(nextTemp), for: previous) else { return }
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
        guard let previous = controllableDevice(deviceId), case .appliance(let s) = previous.kind,
              s.startAction == action || s.pauseAction == action || s.stopAction == action else { return }
        // Starting a cycle is the hazardous direction; pausing and stopping wind it down.
        let operation: IntentOperation = action.kind == .start ? .power(true) : .power(false)
        guard allowManualControl(operation, for: previous) else { return }
        // The program state is reported by the device; nothing is shown ahead of it.
        commitManualWrite(from: previous, to: nil, command: .pressButton(entityId: action.entityId), lock: nil)
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
        guard let previous = controllableDevice(deviceId), case .climate(var s) = previous.kind else { return }
        guard allowManualControl(.fanSpeed(fanMode), for: previous) else { return }
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
        guard let previous = controllableDevice(deviceId), case .climate(var s) = previous.kind else { return }
        guard allowManualControl(.oscillation(swingMode.caseInsensitiveCompare("off") != .orderedSame), for: previous) else { return }
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
        guard let check = controllableDevice(deviceId), case .cover(let checkSpec) = check.kind else { return }
        let opening = checkSpec.openDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let closing = checkSpec.closeDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let pausing = checkSpec.pauseDescription.map { description.caseInsensitiveCompare($0) == .orderedSame } ?? false
        if opening || closing {
            guard allowManualControl(opening ? .power(true) : .power(false), for: check) else { return }
        }
        cancelDebouncedWrites(for: deviceId, keys: ["\(deviceId).cover"])
        guard let previous = devices.first(where: { $0.id == deviceId }),
              case .cover(var s) = previous.kind else { return }
        let priorCoverOrigin = coverCommandOrigins[deviceId]
        let origin = activeCoverOrigin(for: deviceId, fallback: s.positionPercent)
        if opening {
            coverCommandOrigins[deviceId] = s.positionPercent
            s.positionPercent = 100
            s.motion = .opening
            s.motionIsInferred = false
        }
        if closing {
            coverCommandOrigins[deviceId] = s.positionPercent
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

    /// A drag is the confirmation. One-tap open still asks via `setCoverMotor` / `togglePrimary`.
    public func setCoverPosition(_ deviceId: String, percent: Int) {
        guard let previous = controllableDevice(deviceId), case .cover(var s) = previous.kind,
              s.positionWritable else { return }
        let key = "\(deviceId).cover"
        let priorCoverOrigin = coverCommandOrigins[deviceId]
        let clamped = max(0, min(100, percent))
        let displayed = CoverSpec.snappedPosition(clamped)
        let baselineCover: CoverSpec? = if case .cover(let baseSpec) = debouncedWrites[key]?.origin.kind {
            baseSpec
        } else {
            nil
        }
        let previousPosition = (baselineCover ?? s).positionPercent ?? displayed
        let origin = activeCoverOrigin(for: deviceId, fallback: previousPosition) ?? previousPosition
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
        let targetMotion = s.motion
        let targetInferred = s.motionIsInferred
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
            mutate: { device in
                guard case .cover(var spec) = device.kind else { return }
                spec.positionPercent = displayed
                spec.motion = targetMotion
                spec.motionIsInferred = targetInferred
                device.kind = .cover(spec)
            }
        )
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
        device.hasDetailDrawer || deviceFacets[device.id]?.isEmpty == false
    }

    // MARK: - Generic Facet Controls (#5)

    public func setFacetValue(_ deviceId: String, controlId: String, value: JSONValue) {
        guard let device = controllableDevice(deviceId), device.isOnline,
              var facets = deviceFacets[deviceId],
              let index = facets.firstIndex(where: { $0.id == controlId }) else { return }
        let control = facets[index]
        guard facetWriteAllowed(control),
              control.target?.isAction == false,
              control.value != value,
              let command = Self.facetCommand(for: control, value: value) else { return }
        let key = facetWriteKey(deviceId, controlId)
        let previous = facetWrites[key]
        // Only a slider still being dragged rides on the confirmation its first tick got. A
        // toggle or select tapped again while the earlier write is pending is a new decision
        // (off -> on of a heater) and is judged on its own value.
        let continuesConfirmedDrag = previous != nil && control.kind == .slider
        guard continuesConfirmedDrag || allowManualControl(facet: control, value: value, for: device) else { return }
        let origin = if let previous { previous.origin } else { control.value }
        var pending = FacetWriteState(token: UUID(), origin: origin, bannerID: previous?.bannerID)
        facets[index].value = value
        deviceFacets[deviceId] = facets
        extendFacetLock(deviceId, controlId: controlId, duration: .seconds(2.2))
        if previous == nil, let origin, let restore = Self.facetCommand(for: control, value: origin) {
            let rawTitle = control.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? control.name : rawTitle
            scheduleUndoBanner(
                title: L10n.tr("已更新 \(device.name) 的\(title)", "Updated \(device.name): \(title)"),
                restoreCommands: [restore],
                previousDevices: [device], deviceCount: 1
            )
            pending.bannerID = undoBanner?.id
        }
        facetWrites[key] = pending
        dispatchFacetWrite(
            device: device, controlId: controlId, pending: pending,
            command: command,
            adjustment: control.kind == .slider
        )
    }

    /// Fires a 更多设置 button. A feeding action takes `portion`, the amount the drawer picked;
    /// other inputs fall back to the profile default (an enum input prefers the app/remote source).
    public func runFacetAction(_ deviceId: String, controlId: String, portion: Int? = nil) {
        guard let device = controllableDevice(deviceId), device.isOnline,
              let control = deviceFacets[deviceId]?.first(where: { $0.id == controlId }),
              facetWriteAllowed(control), let target = control.target else { return }
        let command: DeviceCommand
        switch target {
        case .action(let entityId):
            command = .callMiotAction(
                entityId: entityId,
                arguments: Self.facetActionArguments(control, portion: portion)
            )
        case .haAction(let entityId):
            command = .pressButton(entityId: entityId)
        case .property, .haProperty:
            return
        }
        guard allowManualControl(facet: control, value: nil, portion: portion, for: device) else { return }
        extendFacetLock(deviceId, controlId: controlId, duration: .seconds(2.0))
        let pending = FacetWriteState(token: UUID(), origin: nil, bannerID: nil)
        facetWrites[facetWriteKey(deviceId, controlId)] = pending
        dispatchFacetWrite(device: device, controlId: controlId, pending: pending,
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

    private func dispatchFacetWrite(
        device: SmartDevice, controlId: String, pending: FacetWriteState,
        command: DeviceCommand, adjustment: Bool
    ) {
        let deviceId = device.id
        let key = facetWriteKey(deviceId, controlId)
        let context = controlContextID
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            defer {
                if let self, self.facetWrites[key]?.token == pending.token {
                    self.facetWrites.removeValue(forKey: key)
                    self.debounceTasks.removeValue(forKey: key)
                }
            }
            if adjustment {
                try? await Task.sleep(for: self?.controlDebounceInterval ?? .milliseconds(280))
            }
            guard !Task.isCancelled, let self, self.controlContextID == context,
                  self.facetWrites[key]?.token == pending.token else { return }
            do {
                try await self.executeDeviceCommand(command)
            } catch {
                guard self.controlContextID == context,
                      self.facetWrites[key]?.token == pending.token else { return }
                if let index = self.deviceFacets[deviceId]?.firstIndex(where: { $0.id == controlId }),
                   self.deviceFacets[deviceId]?[index].target?.isAction == false {
                    self.deviceFacets[deviceId]?[index].value = pending.origin
                }
                self.optimisticFacetLocks.removeValue(forKey: key)
                if let bannerID = pending.bannerID, self.undoBanner?.id == bannerID {
                    self.undoTimerTask?.cancel()
                    self.undoBanner = nil
                }
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
        } else {
            guard let eid = s.fridgeTargetEntityId else { return }
            entityId = eid
            next = max(2, min(8, s.fridgeTargetTemp + delta))
            s.fridgeTargetTemp = next
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
                } else {
                    spec.fridgeTargetTemp = next
                }
                device.kind = .fridge(spec)
            }
        )
    }

    public func performVacuumAction(_ deviceId: String, action: VacuumAction) {
        guard let previous = controllableDevice(deviceId), case .vacuum = previous.kind else { return }
        guard allowManualControl(action == .start ? .power(true) : .power(false), for: previous),
              let change = Self.vacuumActionChange(previous, action: action) else { return }
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
            updated.kind = .speaker(s)
            mediaEid = s.mediaEntityId
        case .tv(var s):
            s.volumePercent = clamped
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
                    device.kind = .speaker(spec)
                case .tv(var spec):
                    spec.volumePercent = clamped
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
        let nextMuted = !s.isMuted
        var updated = previous
        s.isMuted = nextMuted
        updated.kind = .tv(s)
        let entityId = LGWebOSProtocol.isLGEntity(s.mediaEntityId) ? LGWebOSProtocol.muteEntityId : s.mediaEntityId
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

    public func sendSpeakerText(_ deviceId: String, text: String, asDirective: Bool) {
        guard !rejectWritesBlockedByMiSession() else { return }
        guard !rejectControlWhileLocked() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(let s) = devices[idx].kind else { return }

        let targetEid = asDirective ? s.directiveNotifyEntityId : s.ttsNotifyEntityId
        guard let eid = targetEid else {
            showToast(L10n.tr("该音箱不支持此指令通道", "This speaker does not support that channel"), isError: true)
            return
        }

        Task {
            do {
                try await executeDeviceCommand(.sendNotifyMessage(entityId: eid, message: trimmed))
                showToast(
                    asDirective
                        ? L10n.tr("已向小爱下发指令：「\(trimmed)」", "Sent command to XiaoAi: \"\(trimmed)\"")
                        : L10n.tr("小爱已播报：「\(trimmed)」", "XiaoAi announced: \"\(trimmed)\"")
                )
            } catch {
                showToast(L10n.tr("发送失败：\(error.localizedDescription)", "Failed to send: \(error.localizedDescription)"), isError: true)
            }
        }
    }

    public func pressDeviceButton(_ buttonEntityId: String, label: String) {
        guard !rejectWritesBlockedByMiSession() else { return }
        guard !rejectControlWhileLocked() else { return }
        Task {
            do {
                try await executeDeviceCommand(.pressButton(entityId: buttonEntityId))
                showToast(L10n.tr("已触发：\(label)", "Triggered: \(label)"))
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
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else { return }
        guard device.isOnline else {
            showToast(L10n.tr("\(device.name) 当前离线", "\(device.name) is offline"), isError: true)
            return
        }
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

    public func resolveCameraStream(for deviceId: String, channel: Int = 0) async throws -> CameraStreamSource {
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("未找到该摄像头设备", "Camera device not found"))
        }
        if let custom = cameraCustomStreamURL(for: deviceId),
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
        return try await provider.resolveCameraStream(
            for: device,
            quality: cameraStreamQuality(for: deviceId),
            channel: channel
        )
    }

    public func stopCameraStream(for deviceId: String) async {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        await provider.stopCameraStream(for: device)
    }
}
