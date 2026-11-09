import Foundation

/// The verdict of a bulk action that an external entry point can report on its own, instead of
/// reading whatever toast happens to be on screen (a stale expiry toast from an earlier tap must
/// not turn a completed LAN-only action into an error, and a refused batch must not report the
/// success title it captured before sending).
public enum BulkWriteOutcome: Equatable, Sendable {
    /// Every command was accepted.
    case completed
    /// At least one device refused a command for a reason other than the expired Mi session.
    /// The rows and the undo banner already show which.
    case partial
    /// The expired Mi session refused at least one device. Nothing that needed Mi was sent; the
    /// persistent expiry toast explains it.
    case refusedByMiSession
}

extension BulkWriteOutcome {
    /// The message and `isError` an external caller (`menumijia://`, Raycast) reports.
    public func externalResult(success: String, incomplete: String) -> (message: String, isError: Bool) {
        switch self {
        case .completed: return (success, false)
        case .partial: return (incomplete, true)
        case .refusedByMiSession: return (HomeStore.miSessionBlockedMessage, true)
        }
    }
}

/// A quick action or 全关 whose commands are still being sent, keyed by the undo banner it created.
///
/// `undoTurnAllOff` flips `isStopped` synchronously and then waits on `task`, so a batch command can
/// never land after the restore that took it back. `attemptedDeviceIds` records a device before its
/// command is sent, so the command in flight at undo time is included — it may already have reached
/// the device. Once `isStopped` is set the set is final: the loop checks the stop before it records.
@MainActor
final class RunningBatch {
    let task: Task<BulkWriteOutcome, Never>
    /// The action's optimistic write per device. Undo compares the row revision through `ownsRow`,
    /// so a device a newer write took keeps its own state instead of being restored to this
    /// action's snapshot.
    let writes: [String: OptimisticWrite]
    var isStopped = false
    var attemptedDeviceIds: Set<String> = []
    /// Devices this batch skipped because a newer write owns their row.
    var takenOverDeviceIds: Set<String> = []

    init(task: Task<BulkWriteOutcome, Never>, writes: [String: OptimisticWrite]) {
        self.task = task
        self.writes = writes
    }
}

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
        // A persistent toast carries an action for the connection that raised it (the expired Mi
        // session's Scan button). Reaching demo mode or another account leaves it a dead button,
        // so it must end with the context that created it (§13). A suspended prompt is dropped too,
        // so the end of whatever ordinary toast is on screen cannot bring it back.
        isSessionToastSuspended = false
        if toastNotice?.persistent == true { dismissToast() }
    }

    // MARK: - Scenes & Built-In QuickActions with 5-Second Undo

    @discardableResult
    public func triggerScene(_ scene: HomeScene) -> Task<Bool, Never> {
        guard !rejectWritesBlockedByMiSession() else { return Task { false } }
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
    ) -> Task<BulkWriteOutcome, Never>? {
        if respectScreenLock, rejectControlWhileLocked() { return nil }
        // Every quick action targets Mi rows only, so a blocked session means no target can be
        // sent: refuse before building rows or a banner instead of flashing them and taking them back.
        if rejectWritesBlockedByMiSession() { return Task { .refusedByMiSession } }
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
        let task = Task { () -> BulkWriteOutcome in
            // Every exit drops the registration, so a later undo never waits on a finished batch.
            defer { runningBatches[bannerId] = nil }
            guard let outcome = await runBatchCommands(commands, context: context, batchId: bannerId, writes: writes) else { return .partial }
            // Undo needs this report after this task ends: a device a newer write took before its
            // send keeps its own state and must not receive a restore command.
            if undoBanner?.id == bannerId { undoBanner?.attemptedDeviceIds = outcome.attemptedDeviceIds }
            let failedDeviceIds = outcome.failedDeviceIds
            let refusedDeviceIds = failedDeviceIds.filter { outcome.acceptedByDevice[$0] == nil }
            let droppedDeviceIds = refusedDeviceIds.union(outcome.takenOverDeviceIds)
            if !droppedDeviceIds.isEmpty {
                // A device with no accepted command keeps nothing on screen: its row goes back and
                // its restore commands leave this action's banner. A device that accepted an earlier
                // command stays as shown (undo still turns it back), and is reported separately. A
                // device a newer write took keeps that write, so it leaves the banner too.
                revertRefusedBatchWrites(refusedDeviceIds, writes: writes)
                trimUndoBanner(
                    bannerId,
                    droppedDeviceIds: droppedDeviceIds,
                    restoreCommands: restoreCommands,
                    remainingDeviceCount: affectedDeviceIds.subtracting(droppedDeviceIds).count,
                    title: bannerTitle
                )
            }
            // A session-refused device already has the persistent expiry toast; naming it in the
            // "did not respond" toast would blame the device and queue a second message.
            let reportedFailureIds = failedDeviceIds.subtracting(outcome.sessionRefusedDeviceIds)
            if !reportedFailureIds.isEmpty {
                let names = Self.batchFailureNames(
                    commands: commands,
                    failedDeviceIds: reportedFailureIds,
                    acceptedByDevice: outcome.acceptedByDevice,
                    deviceNames: deviceNames
                )
                showBatchWriteFailure(
                    actionTitle: action.title,
                    refusedNames: names.refused,
                    partlyAppliedNames: names.partlyApplied
                )
            }
            // Habits train only on devices this action actually reached in full, without a newer
            // write taking the row, and only while the banner this action created is still the live
            // one (an undo or expiry cancels the learning) (#113).
            let succeededIntents = habitIntents.filter {
                outcome.attemptedDeviceIds.contains($0.targetId)
                    && !failedDeviceIds.contains($0.targetId)
                    && !outcome.takenOverDeviceIds.contains($0.targetId)
            }
            if context == controlContextID, !succeededIntents.isEmpty, recordsHabits, undoBanner?.id == bannerId {
                undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
            }
            if !outcome.sessionRefusedDeviceIds.isEmpty { return .refusedByMiSession }
            if !failedDeviceIds.isEmpty || !outcome.takenOverDeviceIds.isEmpty { return .partial }
            return .completed
        }
        // A main-actor task only starts once this synchronous section yields, so the entry is in
        // place before `runBatchCommands` looks it up.
        runningBatches[bannerId] = RunningBatch(task: task, writes: writes)
        return task
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

    /// Header copy for 全关. The excluded count is the active devices in the current room or filter,
    /// and the plug phrase appears only when one of those leftovers is a plug.
    public func allOffHeaderCopy(scopeName: String?) -> AllOffHeaderCopy {
        let visibleActive = filteredDevices.filter(\.isActiveDevice)
        let targets = allOffTargets
        let targetIDs = Set(targets.map(\.id))
        let excluded = visibleActive.filter { !targetIDs.contains($0.id) }
        let includesPlug = excluded.contains { device in
            if case .plug = device.kind { return true }
            return false
        }
        return AllOffHeaderCopy.make(
            activeDeviceCount: visibleActive.count,
            targetNames: targets.map(\.name),
            scopeName: scopeName,
            excludedIncludesPlug: includesPlug
        )
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
    public func turnAllOff() -> Task<BulkWriteOutcome, Never>? {
        guard !rejectControlWhileLocked() else { return nil }
        let targets = allOffTargets
        let targetIds = Set(targets.map(\.id))
        guard !targetIds.isEmpty else {
            showToast(L10n.tr("当前没有开启的设备", "No active devices are currently on"))
            return nil
        }
        // Mixed LG + Mi runs: the batch refuses only the Mi rows. Refuse early only when no target
        // can be sent at all, so an all-Mi tap does not flash its fabricated rows.
        if targets.allSatisfy({ !lgClientServes($0) }), rejectWritesBlockedByMiSession() {
            return Task { .refusedByMiSession }
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
        let task = Task { () -> BulkWriteOutcome in
            // Every exit drops the registration, so a later undo never waits on a finished batch.
            defer { runningBatches[bannerId] = nil }
            guard let outcome = await runBatchCommands(offCommands, context: context, batchId: bannerId, writes: writes) else { return .partial }
            // Undo needs this report after this task ends: a device a newer write took before its
            // send keeps its own state and must not receive a restore command.
            if undoBanner?.id == bannerId { undoBanner?.attemptedDeviceIds = outcome.attemptedDeviceIds }
            let failedDeviceIds = outcome.failedDeviceIds
            let refusedDeviceIds = failedDeviceIds.filter { outcome.acceptedByDevice[$0] == nil }
            let droppedDeviceIds = refusedDeviceIds.union(outcome.takenOverDeviceIds)
            if !droppedDeviceIds.isEmpty {
                revertRefusedBatchWrites(refusedDeviceIds, writes: writes)
                let remainingDeviceCount = offCommands.count - droppedDeviceIds.count
                trimUndoBanner(
                    bannerId,
                    droppedDeviceIds: droppedDeviceIds,
                    restoreCommands: restoreCommands,
                    remainingDeviceCount: remainingDeviceCount,
                    title: L10n.tr("已关闭 \(remainingDeviceCount) 台设备", "Turned off \(remainingDeviceCount) device(s)")
                )
            }
            let reportedFailureIds = failedDeviceIds.subtracting(outcome.sessionRefusedDeviceIds)
            if !reportedFailureIds.isEmpty {
                let names = Self.batchFailureNames(
                    commands: offCommands,
                    failedDeviceIds: reportedFailureIds,
                    acceptedByDevice: outcome.acceptedByDevice,
                    deviceNames: deviceNames
                )
                showBatchWriteFailure(
                    actionTitle: L10n.tr("全关", "Turn all off"),
                    refusedNames: names.refused,
                    partlyAppliedNames: names.partlyApplied
                )
            }
            // Habits train only on devices this action actually reached in full, without a newer
            // write taking the row, while this action's banner is live (#113).
            let succeededIntents = habitIntents.filter {
                outcome.attemptedDeviceIds.contains($0.targetId)
                    && !failedDeviceIds.contains($0.targetId)
                    && !outcome.takenOverDeviceIds.contains($0.targetId)
            }
            if context == controlContextID, !succeededIntents.isEmpty, undoBanner?.id == bannerId {
                undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
            }
            if !outcome.sessionRefusedDeviceIds.isEmpty { return .refusedByMiSession }
            if !failedDeviceIds.isEmpty || !outcome.takenOverDeviceIds.isEmpty { return .partial }
            return .completed
        }
        // A main-actor task only starts once this synchronous section yields, so the entry is in
        // place before `runBatchCommands` looks it up.
        runningBatches[bannerId] = RunningBatch(task: task, writes: writes)
        return task
    }

    /// How long the 撤销 banner stays after 全关 and similar bulk actions (#23): 10 s for one or two
    /// devices, 15 s from three on so the user can read which devices the AI touched (#53).
    nonisolated static func undoBannerSeconds(forDeviceCount count: Int) -> Double {
        count >= 3 ? 15 : 10
    }

    /// How long the rows a waiting undo restored stay locked. A bulk action's command can be in
    /// flight for as long as the Home Assistant request timeout (120 s), so the normal 3 s lease
    /// would run out mid-wait and a snapshot could overwrite the restored card. The ceiling keeps a
    /// command that never returns from holding the row locked forever.
    static let undoWaitLockCeiling: Duration = .seconds(120)

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
        /// Devices a `MiSessionWriteBlocked` refused. Their persistent toast is already up, so the
        /// failure toast must not name them a second time.
        var sessionRefusedDeviceIds: Set<String> = []
        /// Devices the batch sent to, including the one in flight at undo time.
        var attemptedDeviceIds: Set<String> = []
        /// Devices the batch skipped because a newer write owns their row.
        var takenOverDeviceIds: Set<String> = []
    }

    /// Puts the rows a bulk action showed back for the devices that refused every command, but only
    /// while the batch still owns them: applying a snapshot or an LG report to a row removes its
    /// lock entry, so an entry that is still there means no authoritative report has taken the row.
    /// An expired entry still counts, because an unreported failure leaves the fabricated row.
    private func revertRefusedBatchWrites(
        _ refusedDeviceIds: Set<String>,
        writes: [String: OptimisticWrite]
    ) {
        for deviceId in refusedDeviceIds {
            guard let write = writes[deviceId], optimisticLockUntil[deviceId] != nil else { continue }
            revert(write)
        }
    }

    /// Sends a bulk action's commands in order. Once a command on a device fails, that device's
    /// remaining commands are not sent, the same rule the undo executor follows. Returns nil when
    /// the control context moved on or the action's undo stopped this batch: a stopped batch
    /// reports nothing, so it cannot revert, trim or toast over the rows the undo put back.
    ///
    /// `batchId` names the entry the action registered for its banner; each device is recorded
    /// before its command is sent, so the command in flight at undo time counts as attempted.
    /// `writes` is the action's optimistic write per device; a device a newer write took since is
    /// skipped, because a queued command must not overwrite that newer state.
    func runBatchCommands(
        _ commands: [(deviceId: String, command: DeviceCommand)],
        context: UUID,
        batchId: UUID,
        writes: [String: OptimisticWrite]
    ) async -> BatchCommandOutcome? {
        var outcome = BatchCommandOutcome()
        for item in commands {
            guard context == controlContextID,
                  let batch = runningBatches[batchId], !batch.isStopped else { return nil }
            if outcome.failedDeviceIds.contains(item.deviceId) { continue }
            // The batch's own write sets the revision once and nothing bumps it before a send, so
            // this only fires for a newer write (the user, another action, an undo). A device's own
            // report is adopted without bumping the revision, so it never counts as a takeover.
            if let write = writes[item.deviceId], !ownsRow(write) {
                batch.takenOverDeviceIds.insert(item.deviceId)
                continue
            }
            batch.attemptedDeviceIds.insert(item.deviceId)
            do {
                try await executeDeviceCommand(item.command)
                outcome.acceptedByDevice[item.deviceId, default: 0] += 1
            } catch is MiSessionWriteBlocked {
                // This device is refused like any other; later devices still run, so a batch that
                // mixes LAN targets and Mi targets keeps sending the LAN ones. The catch continues
                // the loop instead of breaking.
                outcome.sessionRefusedDeviceIds.insert(item.deviceId)
                outcome.failedDeviceIds.insert(item.deviceId)
            } catch {
                outcome.failedDeviceIds.insert(item.deviceId)
            }
        }
        guard context == controlContextID,
              let batch = runningBatches[batchId], !batch.isStopped else { return nil }
        outcome.attemptedDeviceIds = batch.attemptedDeviceIds
        outcome.takenOverDeviceIds = batch.takenOverDeviceIds
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
        // Nothing to undo stays silent. A blocked Mi session is checked before any UI state or a
        // running batch is touched: undo cannot restore anything over the expired source, so the
        // banner stays and the batch keeps running. The batch stops itself at its next command,
        // puts its rows back and drops this banner through the blocked path, which is exactly the
        // cleanup an undo would otherwise do.
        guard let banner = undoBanner else { return nil }
        // Only an undo whose restores are all Mi-dependent is refused outright. A mixed undo sends
        // its LAN restores, keeps the refused Mi ones in the banner and leaves the expiry toast up.
        let hasLGRestore = banner.restoreCommands.contains { lgClientServes($0) }
        let hasMiRestore = banner.restoreCommands.contains { !lgClientServes($0) }
        if hasMiRestore, !hasLGRestore, rejectWritesBlockedByMiSession() {
            return nil
        }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        self.undoBanner = nil
        // A bulk action that is still sending must stop before its next command, and the restore
        // below waits for the command already in flight, so a late batch write cannot land after
        // the undo. The rows go back synchronously, so the card still answers at once.
        let batch = runningBatches[banner.id]
        batch?.isStopped = true
        let batchTask = batch?.task
        // Final once stopped: the loop records a device before its send and checks the stop before
        // recording, so the wait below cannot admit another device. A batch that already finished
        // left its report on the banner; an assistant-plan banner has neither, so undo sends all.
        let attemptedDeviceIds = batch?.attemptedDeviceIds ?? banner.attemptedDeviceIds
        // A device a newer write took keeps its own state: neither its row nor a restore command
        // belongs to this action any more. A running batch compares each row's revision through
        // `ownsRow`; a finished batch had these devices dropped from its banner when it ended.
        let takenOverDeviceIds = batch.map { running in
            Set(running.writes.filter { !ownsRow($0.value) }.keys)
        } ?? []
        let undoRevision = undoStateRevision
        let preUndoById = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let preUndoFacetsById = deviceFacets
        let applicable = applyUndoCommands(
            banner.restoreCommands,
            previousDevices: banner.previousDevices,
            excludingDeviceIds: takenOverDeviceIds
        )
        if applicable.isEmpty, !banner.restoreCommands.isEmpty {
            showToast(L10n.tr("设备状态已变化，无法撤销", "Device state changed; cannot undo"), isError: true)
            return nil
        }
        if !applicable.isEmpty, banner.isAllOff { recordOnboardingMilestone(.undidAllOff) }
        // The 3 s row locks `applyUndoCommands` took are shorter than a stalled command can be. Hold
        // these rows for as long as the wait can last, so no snapshot can overwrite the restored
        // card; the ceiling means a command that never returns still releases them.
        if batchTask != nil {
            let until = ContinuousClock.now.advanced(by: Self.undoWaitLockCeiling)
            for item in applicable { optimisticLockUntil[item.deviceId] = until }
        }

        let context = controlContextID
        return Task {
            var restorable = applicable
            if let batchTask {
                // The batch is sequential, so at most the one in-flight command is still running.
                _ = await batchTask.value
                // The wait can outlive the connection it started on; a home that is no longer on
                // screen writes nothing.
                guard context == controlContextID else { return }
                // A newer batch or write can take a row while this undo waits. The last revision per
                // device is the one this undo holds; a device with two restore commands retook its
                // row twice, the same way `rollbackFailedUndoDevices` reads it. A device taken over
                // during the wait gets neither its lock refreshed nor a restore command.
                var held: [String: UInt64] = [:]
                for item in applicable { held[item.deviceId] = item.lockRevision }
                let owned = held.compactMap { deviceId, revision in
                    optimisticLockRevision[deviceId] == revision ? deviceId : nil
                }
                restorable = applicable.filter { owned.contains($0.deviceId) }
                guard !restorable.isEmpty else {
                    // Every row is the newer action's now, so there is nothing left to restore and
                    // nothing to announce.
                    return
                }
                // Back to the normal lease.
                let normal = ContinuousClock.now.advanced(by: .seconds(3.0))
                for deviceId in owned { optimisticLockUntil[deviceId] = normal }
            }
            // A device this batch never sent to is still where the action found it: its row is back
            // above, and a restore command would re-apply a change that never happened.
            let restoreTargets = attemptedDeviceIds.map { attempted in
                restorable.filter { attempted.contains($0.deviceId) }
            } ?? restorable
            guard let outcome = await runUndoCommands(
                restoreTargets,
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
            // The refused Mi commands stay in the banner; the persistent expiry toast already
            // explains them, so the generic "did not respond" message would only replace it.
            if !outcome.blockedByMiSession {
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
        /// At least one restore was refused by the expired Mi session; its persistent toast is up.
        let blockedByMiSession: Bool

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
        var blockedByMiSession = false
        for item in applicable {
            guard context == controlContextID else { return nil }
            if failedDeviceIds.contains(item.deviceId) {
                failedCommands.append(item.command)
                continue
            }
            do {
                try await executeDeviceCommand(item.command)
            } catch {
                if error is MiSessionWriteBlocked { blockedByMiSession = true }
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
                habitReceipt: nil,
                blockedByMiSession: false
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
            habitReceipt: remainingReceipt,
            blockedByMiSession: blockedByMiSession
        )
    }

    /// Puts the rows an undo restores back on screen and collects the commands to send. A device a
    /// newer write owns (`excludingDeviceIds`) is left alone entirely: neither its row nor its
    /// restore command belongs to this action any more.
    func applyUndoCommands(
        _ commands: [DeviceCommand],
        previousDevices: [SmartDevice] = [],
        excludingDeviceIds: Set<String> = []
    ) -> [UndoApplicableCommand] {
        var applicable: [UndoApplicableCommand] = []
        for command in commands {
            // A 更多设置 write has no card-state effect; undo restores the facet value it carries.
            if let target = Self.facetTarget(for: command),
               let device = devices.first(where: { device in
                   deviceFacets[device.id]?.contains { $0.target == target } == true
                       && !excludingDeviceIds.contains(device.id)
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
                      device.isOnline,
                      !excludingDeviceIds.contains(device.id) else {
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
            if let idx = devices.indices.first(where: {
                   !excludingDeviceIds.contains(devices[$0].id)
                       && Self.undoEffect(of: command, on: devices[$0]) != nil
               }),
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

            guard let prev = previousDevices.first(where: {
                      !excludingDeviceIds.contains($0.id)
                          && Self.undoEffect(of: command, on: $0) != nil
                  }),
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
