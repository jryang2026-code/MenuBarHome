import Foundation

// Scenes, quick actions, 全关 and the unified undo banner (#48).
extension HomeStore {
    func invalidateUndoContext() {
        controlContextID = UUID()
        readBackTickets.reset()
        undoTimerTask?.cancel()
        undoBanner = nil
        lastAssistantUndo = nil
        setAssistantState(.idle)
        pendingCloudConsent = nil
        assistantSuggestions = []
        aiProactiveSuggestions = nil
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        isProactiveRecommending = false
        proactiveRetryEarliest = nil
        isGrokBallStageExpanded = false
        grokBallCelebrationTask?.cancel()
        grokBallCelebrationUntil = nil
        optimisticLockUntil.removeAll()
        coverCommandOrigins.removeAll()
        lastCoverPositions.removeAll()
        cancelFacetWrites(for: nil)
        // A different home is a different suggestion context even at the same ambient signature (Codex #116 review).
        lastProactiveRefreshSignature = nil
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }

    // MARK: - Scenes & Built-In QuickActions with 5-Second Undo

    @discardableResult
    public func triggerScene(_ scene: HomeScene) -> Task<Bool, Never> {
        guard !rejectControlWhileLocked() else { return Task { false } }
        return Task {
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                confirmManualControl(intents: [.init(targetId: scene.id, operation: .activateScene)])
                showToast(L10n.tr("已触发场景：\(scene.name)", "Activated scene: \(scene.name)"))
                return true
            } catch {
                showToast(L10n.tr("场景「\(scene.name)」执行失败", "Scene \"\(scene.name)\" failed"), isError: true)
                return false
            }
        }
    }

    @discardableResult
    public func executeQuickAction(
        _ action: QuickAction,
        undoBannerDuration: TimeInterval? = nil,
        recordsHabits: Bool = true,
        respectScreenLock: Bool = true
    ) -> Task<Void, Never>? {
        if respectScreenLock, rejectControlWhileLocked() { return nil }
        let previousSnapshot = devices
        var commands: [(deviceId: String, command: DeviceCommand)] = []
        var restoreCommands: [(deviceId: String, command: DeviceCommand)] = []
        var affectedDeviceIds: Set<String> = []
        var habitIntents: [DeviceIntent] = []
        // One write per device: a device that sends two commands (softNightLight) is rolled back once.
        var writes: [String: OptimisticWrite] = [:]

        switch action {
        case .lightsOff:
            for idx in devices.indices where devices[idx].isOnline {
                let previous = devices[idx]
                guard case .light(var s) = previous.kind, s.isOn, s.powerWritable else { continue }
                let deviceId = previous.id
                affectedDeviceIds.insert(deviceId)
                habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                commands.append((deviceId, .setLightPower(entityId: s.entityId, isOn: false)))
                restoreCommands.append((deviceId, .setLightPower(entityId: s.entityId, isOn: true)))
                s.isOn = false
                var updated = previous
                updated.kind = .light(s)
                writes[deviceId] = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(3.0))
            }

        case .softNightLight:
            var targetIndices = devices.indices.filter { idx in
                guard devices[idx].isOnline, case .light(let s) = devices[idx].kind else { return false }
                return s.isOn && s.brightnessWritable && s.colorWritable
            }
            if targetIndices.isEmpty {
                let isOnlineLight = { (dev: SmartDevice) -> Bool in
                    if dev.isOnline, case .light(let spec) = dev.kind {
                        return spec.brightnessWritable && spec.colorWritable
                    }
                    return false
                }
                // Prefer the light the user last switched on by hand; otherwise the first light (#36).
                let fallbackIdx = lastManuallyUsedLightId.flatMap { lastLightId in
                    devices.indices.first(where: { isOnlineLight(devices[$0]) && devices[$0].id == lastLightId })
                } ?? devices.indices.first(where: { isOnlineLight(devices[$0]) })
                if let fallbackIdx {
                    targetIndices = [fallbackIdx]
                    if lastManuallyUsedLightId == nil {
                        // No manual pick yet: remember the light this action chose so the next tap is stable.
                        recordManualLightUse(devices[fallbackIdx].id)
                    }
                }
            }
            for idx in targetIndices {
                let previous = devices[idx]
                guard case .light(var s) = previous.kind else { continue }
                let deviceId = previous.id
                affectedDeviceIds.insert(deviceId)
                habitIntents.append(.init(targetId: deviceId, operation: .brightness(15)))
                habitIntents.append(.init(targetId: deviceId, operation: .colorTemperature(max(s.minKelvin, 2700))))
                let prevOn = s.isOn
                let prevBri = s.brightnessPercent ?? 80
                let prevKelvin = s.colorTempKelvin ?? 4000
                commands.append((deviceId, .setLightBrightness(entityId: s.entityId, percent: 15)))
                commands.append((deviceId, .setLightColorTemp(entityId: s.entityId, kelvin: max(s.minKelvin, 2700))))
                if prevOn {
                    restoreCommands.append((deviceId, .setLightBrightness(entityId: s.entityId, percent: prevBri)))
                    restoreCommands.append((deviceId, .setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin)))
                } else {
                    restoreCommands.append((deviceId, .setLightPower(entityId: s.entityId, isOn: false)))
                }
                s.isOn = true
                s.brightnessPercent = 15
                s.colorTempKelvin = max(s.minKelvin, 2700)
                s.currentEffect = nil
                var updated = previous
                updated.kind = .light(s)
                writes[deviceId] = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(3.0))
            }

        case .climateSleepOff:
            for idx in devices.indices where devices[idx].isOnline {
                let previous = devices[idx]
                let deviceId = previous.id
                switch previous.kind {
                case .climate(var s) where s.isOn && s.hvacMode != "off" && s.powerWritable:
                    let prevMode = s.hvacMode
                    affectedDeviceIds.insert(deviceId)
                    habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                    commands.append((deviceId, .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode)))
                    restoreCommands.append((deviceId, .setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode)))
                    s.isOn = false
                    s.hvacMode = "off"
                    var updated = previous
                    updated.kind = .climate(s)
                    writes[deviceId] = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(3.0))
                case .fan(var s) where s.isOn && s.powerWritable:
                    affectedDeviceIds.insert(deviceId)
                    habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                    commands.append((deviceId, .setFanPower(entityId: s.entityId, isOn: false)))
                    restoreCommands.append((deviceId, .setFanPower(entityId: s.entityId, isOn: true)))
                    s.isOn = false
                    var updated = previous
                    updated.kind = .fan(s)
                    writes[deviceId] = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(3.0))
                default:
                    break
                }
            }
        }

        guard !commands.isEmpty else {
            showToast(L10n.tr("当前无需执行「\(action.title)」", "No devices need \"\(action.title)\""))
            return nil
        }

        let bannerTitle = L10n.tr("已执行「\(action.title)」", "Executed \"\(action.title)\"")
        scheduleUndoBanner(
            title: bannerTitle,
            restoreCommands: restoreCommands.map(\.command),
            previousDevices: previousSnapshot,
            deviceCount: affectedDeviceIds.count,
            habitReceipt: nil,
            duration: undoBannerDuration
        )
        guard let bannerId = undoBanner?.id else { return nil }

        let context = controlContextID
        let deviceNames = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
        return Task {
            guard let outcome = await runBatchCommands(commands, context: context) else { return }
            let failedDeviceIds = outcome.failedDeviceIds
            if !failedDeviceIds.isEmpty {
                // A device with no accepted command keeps nothing on screen: its row goes back and
                // its restore commands leave this action's banner. A device that accepted an earlier
                // command stays as shown (undo still turns it back), and is reported separately.
                let refusedDeviceIds = failedDeviceIds.filter { outcome.acceptedByDevice[$0] == nil }
                let now = ContinuousClock.now
                for deviceId in refusedDeviceIds {
                    // Revert only while this batch's lock still holds the row. An expired lock means
                    // a device report already took over, and a whole-row revert would overwrite it.
                    guard let write = writes[deviceId],
                          let lockUntil = optimisticLockUntil[deviceId],
                          now < lockUntil else { continue }
                    revert(write)
                }
                trimUndoBanner(
                    bannerId,
                    droppedDeviceIds: refusedDeviceIds,
                    restoreCommands: restoreCommands,
                    remainingDeviceCount: affectedDeviceIds.subtracting(refusedDeviceIds).count,
                    title: bannerTitle
                )
                let names = Self.batchFailureNames(
                    commands: commands,
                    failedDeviceIds: failedDeviceIds,
                    acceptedByDevice: outcome.acceptedByDevice,
                    deviceNames: deviceNames
                )
                showBatchWriteFailure(
                    actionTitle: action.title,
                    refusedNames: names.refused,
                    partlyAppliedNames: names.partlyApplied
                )
            }
            // Habits train only on devices with no failed command, and only while the banner this
            // action created is still the live one (an undo or expiry cancels the learning) (#113).
            let succeededIntents = habitIntents.filter { !failedDeviceIds.contains($0.targetId) }
            guard context == controlContextID, !succeededIntents.isEmpty, recordsHabits, undoBanner?.id == bannerId else { return }
            undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
        }
    }

    // MARK: - Turn All Off with Undo

    /// Plugs often power a router, fridge or NAS, and 全关 should not send a cleaning vacuum home (#23).
    public nonisolated static func joinsAllOffByDefault(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .plug, .vacuum, .camera, .cover, .appliance, .generic, .valve: return false
        default: return true
        }
    }

    public func joinsAllOff(_ device: SmartDevice) -> Bool {
        allOffOverrides[device.id] ?? Self.joinsAllOffByDefault(device)
    }

    public func setJoinsAllOff(_ joins: Bool, deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        allOffOverrides[deviceId] = joins == Self.joinsAllOffByDefault(device) ? nil : joins
    }

    /// What 全关 turns off: devices on screen right now (current room, not hidden) that are on,
    /// take part in 全关, and can actually be switched off from here.
    public var allOffTargets: [SmartDevice] {
        filteredDevices.filter { $0.isActiveOn && joinsAllOff($0) && Self.allOffChange(for: $0) != nil }
    }

    public var allOffScopeName: String? {
        switch listCut {
        case .all:
            return nil
        case .room(let id):
            return rooms.first { $0.id == id }?.name
        case .kind(let tag):
            return tag.chipTitle
        }
    }

    /// The command that switches `device` off, the one that brings it back, and the optimistic state.
    nonisolated static func allOffChange(for device: SmartDevice) -> (off: DeviceCommand, restore: DeviceCommand, kind: DeviceKind)? {
        guard device.kind.canTogglePower else { return nil }
        switch device.kind {
        case .light(var s):
            s.isOn = false
            return (.setLightPower(entityId: s.entityId, isOn: false), .setLightPower(entityId: s.entityId, isOn: true), .light(s))
        case .climate(var s):
            let prevMode = s.hvacMode
            s.isOn = false
            s.hvacMode = "off"
            return (
                .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode),
                .setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode),
                .climate(s)
            )
        case .fan(var s):
            s.isOn = false
            return (.setFanPower(entityId: s.entityId, isOn: false), .setFanPower(entityId: s.entityId, isOn: true), .fan(s))
        case .plug(var s):
            s.isOn = false
            return (.setSwitch(entityId: s.switchEntityId, isOn: false), .setSwitch(entityId: s.switchEntityId, isOn: true), .plug(s))
        case .vacuum(var s):
            s.status = "returning"
            return (.vacuumAction(entityId: s.entityId, action: .returnToBase), .vacuumAction(entityId: s.entityId, action: .start), .vacuum(s))
        case .tv(var s):
            guard LGWebOSProtocol.isLGEntity(s.mediaEntityId) else { return nil }
            s.state = "standby"
            return (
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: false),
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true),
                .tv(s)
            )
        case .camera(var s):
            s.isOn = false
            return (.setSwitch(entityId: s.entityId, isOn: false), .setSwitch(entityId: s.entityId, isOn: true), .camera(s))
        case .appliance(var s):
            guard s.powerWritable else { return nil }
            s.isOn = false
            return (
                .setSwitch(entityId: s.powerEntityId, isOn: false),
                .setSwitch(entityId: s.powerEntityId, isOn: true),
                .appliance(s)
            )
        case .humidifier(var s):
            guard s.powerWritable else { return nil }
            s.isOn = false
            return (.setSwitch(entityId: s.entityId, isOn: false), .setSwitch(entityId: s.entityId, isOn: true), .humidifier(s))
        case .valve(var s):
            guard s.closeWritable, s.isOpen else { return nil }
            s.isOpen = false
            return (.setSwitch(entityId: s.entityId, isOn: false), .setSwitch(entityId: s.entityId, isOn: true), .valve(s))
        case .speaker, .fridge, .sensor, .cover, .generic:
            return nil
        }
    }

    @discardableResult
    public func turnAllOff() -> Task<Void, Never>? {
        guard !rejectControlWhileLocked() else { return nil }
        let targetIds = Set(allOffTargets.map(\.id))
        guard !targetIds.isEmpty else {
            showToast(L10n.tr("当前没有开启的设备", "No active devices are currently on"))
            return nil
        }
        recordOnboardingMilestone(.turnedAllOff)

        let previousSnapshot = devices
        var offCommands: [(deviceId: String, command: DeviceCommand)] = []
        var restoreCommands: [(deviceId: String, command: DeviceCommand)] = []
        var habitIntents: [DeviceIntent] = []
        var writes: [String: OptimisticWrite] = [:]

        for idx in devices.indices where targetIds.contains(devices[idx].id) {
            let previous = devices[idx]
            guard let change = Self.allOffChange(for: previous) else { continue }
            let deviceId = previous.id
            // A vacuum returning home has no power op, so it executes but does not train a habit (#113).
            if UserHabitMemory.isPowerToggleable(previous) {
                habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
            }
            offCommands.append((deviceId, change.off))
            restoreCommands.append((deviceId, change.restore))
            var updated = previous
            updated.kind = change.kind
            writes[deviceId] = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(3.0))
        }

        scheduleUndoBanner(
            title: L10n.tr("已关闭 \(offCommands.count) 台设备", "Turned off \(offCommands.count) device(s)"),
            restoreCommands: restoreCommands.map(\.command),
            previousDevices: previousSnapshot,
            deviceCount: targetIds.count,
            habitReceipt: nil,
            isAllOff: true
        )
        guard let bannerId = undoBanner?.id else { return nil }

        let context = controlContextID
        let deviceNames = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
        return Task {
            guard let outcome = await runBatchCommands(offCommands, context: context) else { return }
            let failedDeviceIds = outcome.failedDeviceIds
            if !failedDeviceIds.isEmpty {
                let refusedDeviceIds = failedDeviceIds.filter { outcome.acceptedByDevice[$0] == nil }
                let now = ContinuousClock.now
                for deviceId in refusedDeviceIds {
                    // Revert only while this batch's lock still holds the row; an expired lock means
                    // a device report already took over.
                    guard let write = writes[deviceId],
                          let lockUntil = optimisticLockUntil[deviceId],
                          now < lockUntil else { continue }
                    revert(write)
                }
                let remainingDeviceCount = offCommands.count - refusedDeviceIds.count
                trimUndoBanner(
                    bannerId,
                    droppedDeviceIds: refusedDeviceIds,
                    restoreCommands: restoreCommands,
                    remainingDeviceCount: remainingDeviceCount,
                    title: L10n.tr("已关闭 \(remainingDeviceCount) 台设备", "Turned off \(remainingDeviceCount) device(s)")
                )
                let names = Self.batchFailureNames(
                    commands: offCommands,
                    failedDeviceIds: failedDeviceIds,
                    acceptedByDevice: outcome.acceptedByDevice,
                    deviceNames: deviceNames
                )
                showBatchWriteFailure(
                    actionTitle: L10n.tr("全关", "Turn all off"),
                    refusedNames: names.refused,
                    partlyAppliedNames: names.partlyApplied
                )
            }
            // Habits train only on confirmed success while this action's banner is live (#113).
            let succeededIntents = habitIntents.filter { !failedDeviceIds.contains($0.targetId) }
            guard context == controlContextID, !succeededIntents.isEmpty, undoBanner?.id == bannerId else { return }
            undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
        }
    }

    /// How long the 撤销 banner stays after 全关 and similar bulk actions (#23): 10 s for one or two
    /// devices, 15 s from three on so the user can read which devices the AI touched (#53).
    nonisolated static func undoBannerSeconds(forDeviceCount count: Int) -> Double {
        count >= 3 ? 15 : 10
    }

    func scheduleUndoBanner(
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        deviceCount: Int,
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil,
        isAllOff: Bool = false
    ) {
        let banner = UndoBanner(
            title: title,
            restoreCommands: restoreCommands,
            previousDevices: previousDevices,
            deviceCount: deviceCount,
            habitReceipt: habitReceipt,
            duration: duration,
            isAllOff: isAllOff
        )
        self.undoBanner = banner
        undoTimerTask?.cancel()
        // `duration` overrides the panel's 10/15 s rule for automation, which usually fires while
        // the panel is closed (#59).
        let seconds = duration ?? Self.undoBannerSeconds(forDeviceCount: deviceCount)
        undoTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.undoBanner?.id == banner.id {
                self?.undoBanner = nil
            }
        }
    }

    /// Drops the devices a bulk action failed on from the banner it created, so 撤销 restores only
    /// what the devices accepted. Every device failing removes the banner instead. A banner that
    /// has already been replaced or dismissed is left alone.
    private func trimUndoBanner(
        _ bannerId: UUID,
        droppedDeviceIds: Set<String>,
        restoreCommands: [(deviceId: String, command: DeviceCommand)],
        remainingDeviceCount: Int,
        title: String
    ) {
        guard let banner = undoBanner, banner.id == bannerId else { return }
        let keptCommands = restoreCommands
            .filter { !droppedDeviceIds.contains($0.deviceId) }
            .map(\.command)
        guard !keptCommands.isEmpty else {
            undoTimerTask?.cancel()
            undoBanner = nil
            return
        }
        undoBanner?.title = title
        undoBanner?.restoreCommands = keptCommands
        undoBanner?.previousDevices = banner.previousDevices.filter { !droppedDeviceIds.contains($0.id) }
        undoBanner?.deviceCount = remainingDeviceCount
    }

    /// `撤销未完成` wording for a bulk action some devices refused or only partly applied (#113).
    private func showBatchWriteFailure(
        actionTitle: String,
        refusedNames: [String],
        partlyAppliedNames: [String]
    ) {
        let separator = L10n.isEnglish ? ", " : "、"
        var clauses: [String] = []
        if !refusedNames.isEmpty {
            let list = refusedNames.joined(separator: separator)
            clauses.append(L10n.tr("\(list) 未响应", "\(list) did not respond"))
        }
        if !partlyAppliedNames.isEmpty {
            let list = partlyAppliedNames.joined(separator: separator)
            clauses.append(L10n.tr("\(list) 只生效了一部分", "\(list) applied only partly"))
        }
        let detail = clauses.joined(separator: L10n.isEnglish ? "; " : "；")
        showToast(
            L10n.tr("「\(actionTitle)」未完成：\(detail)", "\"\(actionTitle)\" incomplete: \(detail)"),
            isError: true
        )
    }

    /// What a bulk action's commands did, split by device.
    struct BatchCommandOutcome {
        /// Commands each device accepted; a device missing here accepted none.
        var acceptedByDevice: [String: Int] = [:]
        /// Devices with at least one failed command.
        var failedDeviceIds: Set<String> = []
    }

    /// Sends a bulk action's commands in order. Once a command on a device fails, that device's
    /// remaining commands are not sent, the same rule the undo executor follows. Returns nil when
    /// the control context moved on.
    func runBatchCommands(
        _ commands: [(deviceId: String, command: DeviceCommand)],
        context: UUID
    ) async -> BatchCommandOutcome? {
        var outcome = BatchCommandOutcome()
        for item in commands {
            guard context == controlContextID else { return nil }
            if outcome.failedDeviceIds.contains(item.deviceId) { continue }
            do {
                try await executeDeviceCommand(item.command)
                outcome.acceptedByDevice[item.deviceId, default: 0] += 1
            } catch {
                outcome.failedDeviceIds.insert(item.deviceId)
            }
        }
        guard context == controlContextID else { return nil }
        return outcome
    }

    /// Names for the failure toast, in the order the action sent the devices: those that refused
    /// every command, and those that accepted at least one before one failed.
    nonisolated static func batchFailureNames(
        commands: [(deviceId: String, command: DeviceCommand)],
        failedDeviceIds: Set<String>,
        acceptedByDevice: [String: Int],
        deviceNames: [String: String]
    ) -> (refused: [String], partlyApplied: [String]) {
        var refused: [String] = []
        var partlyApplied: [String] = []
        var seen: Set<String> = []
        for item in commands {
            guard seen.insert(item.deviceId).inserted else { continue }
            guard failedDeviceIds.contains(item.deviceId), let name = deviceNames[item.deviceId] else { continue }
            if acceptedByDevice[item.deviceId] == nil {
                refused.append(name)
            } else {
                partlyApplied.append(name)
            }
        }
        return (refused, partlyApplied)
    }

    @discardableResult
    public func undoTurnAllOff() -> Task<Void, Never>? {
        guard let banner = undoBanner else { return nil }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        self.undoBanner = nil
        let undoRevision = undoStateRevision
        let preUndoById = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let preUndoFacetsById = deviceFacets
        let applicable = applyUndoCommands(banner.restoreCommands, previousDevices: banner.previousDevices)
        if applicable.isEmpty, !banner.restoreCommands.isEmpty {
            showToast(L10n.tr("设备状态已变化，无法撤销", "Device state changed; cannot undo"), isError: true)
            return nil
        }
        if !applicable.isEmpty, banner.isAllOff { recordOnboardingMilestone(.undidAllOff) }

        let context = controlContextID
        return Task {
            guard let outcome = await runUndoCommands(
                applicable,
                context: context,
                preUndoById: preUndoById,
                preUndoFacetsById: preUndoFacetsById,
                habitReceipt: banner.habitReceipt
            ) else { return }
            if outcome.succeeded {
                showToast(L10n.tr("已恢复关闭前的状态", "Restored previous device states"))
                return
            }
            if undoStateRevision == undoRevision {
                scheduleUndoBanner(
                    title: banner.title,
                    restoreCommands: outcome.failedCommands,
                    previousDevices: banner.previousDevices,
                    deviceCount: outcome.failedDeviceIds.count,
                    habitReceipt: outcome.habitReceipt,
                    duration: banner.duration,
                    isAllOff: banner.isAllOff
                )
            }
            let sep = L10n.isEnglish ? ", " : "、"
            let list = outcome.failedNames.joined(separator: sep)
            showToast(
                L10n.tr(
                    "撤销未完成：\(list) 未响应，可再次点击撤销重试",
                    "Undo incomplete: \(list) did not respond; tap Undo to retry"
                ),
                isError: true
            )
        }
    }

    struct UndoApplicableCommand: Sendable {
        let command: DeviceCommand
        let deviceId: String
        let deviceName: String
        let lockRevision: UInt64
    }

    /// What replaying an undo stack did: the devices that refused, and the habit records that still
    /// belong to the devices that accepted.
    struct UndoRunOutcome {
        let failedCommands: [DeviceCommand]
        let failedDeviceIds: Set<String>
        let failedNames: [String]
        let habitReceipt: UserHabitMemory.RecordingReceipt?

        var succeeded: Bool { failedCommands.isEmpty }
    }

    /// Sends `applicable` undo commands in order, rolls back the devices that refused, and takes back
    /// the habit entries that belonged to them. Returns nil when the control context moved on: a home
    /// that is no longer on screen reports nothing.
    func runUndoCommands(
        _ applicable: [UndoApplicableCommand],
        context: UUID,
        preUndoById: [String: SmartDevice],
        preUndoFacetsById: [String: [FacetControl]],
        habitReceipt: UserHabitMemory.RecordingReceipt?
    ) async -> UndoRunOutcome? {
        var failedCommands: [DeviceCommand] = []
        var failedDeviceIds: Set<String> = []
        var failedNames: [String] = []
        for item in applicable {
            guard context == controlContextID else { return nil }
            if failedDeviceIds.contains(item.deviceId) {
                failedCommands.append(item.command)
                continue
            }
            do {
                try await executeDeviceCommand(item.command)
            } catch {
                failedCommands.append(item.command)
                failedDeviceIds.insert(item.deviceId)
                if !failedNames.contains(item.deviceName) {
                    failedNames.append(item.deviceName)
                }
            }
        }
        guard context == controlContextID else { return nil }
        if failedCommands.isEmpty {
            if let habitReceipt {
                var memory = userHabitMemory
                memory.unrecord(habitReceipt)
                userHabitMemory = memory
            }
            return UndoRunOutcome(
                failedCommands: [],
                failedDeviceIds: [],
                failedNames: [],
                habitReceipt: nil
            )
        }
        rollbackFailedUndoDevices(
            failedDeviceIds, applicable: applicable, preUndoById: preUndoById,
            preUndoFacetsById: preUndoFacetsById
        )
        var remainingReceipt: UserHabitMemory.RecordingReceipt?
        if let habitReceipt {
            let (succeededPart, remainingPart) = Self.partitionHabitReceipt(habitReceipt, failedDeviceIds: failedDeviceIds)
            if let succeededPart {
                var memory = userHabitMemory
                memory.unrecord(succeededPart)
                userHabitMemory = memory
            }
            remainingReceipt = remainingPart
        }
        return UndoRunOutcome(
            failedCommands: failedCommands,
            failedDeviceIds: failedDeviceIds,
            failedNames: failedNames,
            habitReceipt: remainingReceipt
        )
    }

    func applyUndoCommands(
        _ commands: [DeviceCommand],
        previousDevices: [SmartDevice] = []
    ) -> [UndoApplicableCommand] {
        var applicable: [UndoApplicableCommand] = []
        for command in commands {
            // A 更多设置 write has no card-state effect; undo restores the facet value it carries.
            if let target = Self.facetTarget(for: command),
               let device = devices.first(where: { device in
                   deviceFacets[device.id]?.contains { $0.target == target } == true
               }),
               device.isOnline {
                if var facets = deviceFacets[device.id],
                   let index = facets.firstIndex(where: { $0.target == target }) {
                    cancelFacetWrite(deviceId: device.id, controlId: facets[index].id)
                    if let value = Self.facetValue(for: command, control: facets[index]) {
                        facets[index].value = value
                    }
                    deviceFacets[device.id] = facets
                }
                let rev = lockOptimistic(device.id, duration: .seconds(3.0))
                applicable.append(
                    UndoApplicableCommand(
                        command: command,
                        deviceId: device.id,
                        deviceName: device.name,
                        lockRevision: rev
                    )
                )
                continue
            }
            // Snapshots without the facet row still resolve a MIoT write by its owning did.
            if case .setMiotProperty(let entityId, let piid, let value) = command {
                let did = MiotAddress.parse(entityId)?.did
                let fallbackOwners = devices.filter { device in
                    did.map { device.id == $0 || device.miotCommandDids.contains($0) } == true
                }
                guard let device = fallbackOwners.count == 1 ? fallbackOwners.first : nil,
                      device.isOnline else {
                    continue
                }
                if var facets = deviceFacets[device.id],
                   let index = facets.firstIndex(where: { $0.target == .property(entityId: entityId, piid: piid) }) {
                    cancelFacetWrite(deviceId: device.id, controlId: facets[index].id)
                    facets[index].value = value
                    deviceFacets[device.id] = facets
                }
                let rev = lockOptimistic(device.id, duration: .seconds(3.0))
                applicable.append(
                    UndoApplicableCommand(
                        command: command,
                        deviceId: device.id,
                        deviceName: device.name,
                        lockRevision: rev
                    )
                )
                continue
            }
            if let idx = devices.indices.first(where: { Self.undoEffect(of: command, on: devices[$0]) != nil }),
               let restored = Self.undoEffect(of: command, on: devices[idx]) {
                let name = devices[idx].name
                devices[idx] = restored
                let rev = lockOptimistic(restored.id, duration: .seconds(3.0))
                applicable.append(
                    UndoApplicableCommand(
                        command: command,
                        deviceId: restored.id,
                        deviceName: name,
                        lockRevision: rev
                    )
                )
                continue
            }

            guard let prev = previousDevices.first(where: { Self.undoEffect(of: command, on: $0) != nil }),
                  let idx = devices.indices.first(where: { devices[$0].id == prev.id && devices[$0].isOnline }),
                  let retargeted = Self.retargetedUndoEffect(of: command, on: devices[idx]) else {
                continue
            }
            let name = devices[idx].name
            devices[idx] = retargeted.updated
            let rev = lockOptimistic(retargeted.updated.id, duration: .seconds(3.0))
            applicable.append(
                UndoApplicableCommand(
                    command: retargeted.command,
                    deviceId: retargeted.updated.id,
                    deviceName: name,
                    lockRevision: rev
                )
            )
        }
        return applicable
    }

    func rollbackFailedUndoDevices(
        _ failedDeviceIds: Set<String>,
        applicable: [UndoApplicableCommand],
        preUndoById: [String: SmartDevice],
        preUndoFacetsById: [String: [FacetControl]]
    ) {
        var expectedRevisions: [String: UInt64] = [:]
        for item in applicable {
            expectedRevisions[item.deviceId] = item.lockRevision
        }
        for failedId in failedDeviceIds {
            guard let current = devices.first(where: { $0.id == failedId }) else { continue }
            let write = OptimisticWrite(
                deviceId: failedId,
                previous: preUndoById[failedId] ?? current,
                revision: expectedRevisions[failedId],
                isShown: true
            )
            guard ownsRow(write) else { continue }
            deviceFacets[failedId] = preUndoFacetsById[failedId]
            revert(write)
        }
    }

    nonisolated static func partitionHabitReceipt(
        _ receipt: UserHabitMemory.RecordingReceipt,
        failedDeviceIds: Set<String>
    ) -> (succeeded: UserHabitMemory.RecordingReceipt?, remaining: UserHabitMemory.RecordingReceipt?) {
        if failedDeviceIds.isEmpty {
            return (receipt, nil)
        }
        let succeededEntries = receipt.entries.filter { !failedDeviceIds.contains($0.targetId) }
        let remainingEntries = receipt.entries.filter { failedDeviceIds.contains($0.targetId) }
        let succeededSequences = receipt.sequences.filter { !failedDeviceIds.contains($0.targetId) }
        let remainingSequences = receipt.sequences.filter { failedDeviceIds.contains($0.targetId) }

        let lastRemainingEntry = remainingEntries.last
        let fallbackLastAction: UserHabitMemory.LastAction? = lastRemainingEntry.flatMap { entry in
            receipt.recordedLastAction.map { recorded in
                UserHabitMemory.LastAction(
                    targetId: entry.targetId,
                    operationKey: entry.operationKey,
                    recordedAt: recorded.recordedAt
                )
            }
        }
        let preserveOnSucceeded = lastRemainingEntry != nil && fallbackLastAction == nil

        let succeeded: UserHabitMemory.RecordingReceipt? =
            (succeededEntries.isEmpty && succeededSequences.isEmpty)
            ? nil
            : UserHabitMemory.RecordingReceipt(
                entries: succeededEntries,
                phrase: nil,
                sequences: succeededSequences,
                previousLastAction: lastRemainingEntry != nil ? fallbackLastAction : receipt.previousLastAction,
                recordedLastAction: receipt.recordedLastAction,
                preserveLastAction: preserveOnSucceeded
            )
        let remaining: UserHabitMemory.RecordingReceipt? =
            (remainingEntries.isEmpty && remainingSequences.isEmpty && receipt.phrase == nil)
            ? nil
            : UserHabitMemory.RecordingReceipt(
                entries: remainingEntries,
                phrase: receipt.phrase,
                sequences: remainingSequences,
                previousLastAction: receipt.previousLastAction,
                recordedLastAction: fallbackLastAction ?? receipt.recordedLastAction
            )
        return (succeeded, remaining)
    }
}
