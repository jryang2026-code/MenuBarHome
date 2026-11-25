import Foundation

extension HomeStore {
    /// Ignore intermediate cover position/movement updates for 60 s after a room group command.
    public static let groupCoverIgnoreWindow: TimeInterval = 60

    public func roomAutoGroups(for roomId: String, roomName: String? = nil) -> [RoomAutoGroup] {
        let resolvedName = roomName ?? rooms.first(where: { $0.id == roomId })?.name
            ?? devices.first(where: { $0.roomId == roomId })?.roomName ?? ""
        let eligible = categoryVisibleDevices.filter {
            $0.roomId == roomId && capabilityWriteRejection(forDeviceId: $0.id) == nil
        }
        return RoomAutoGroup.build(roomId: roomId, roomName: resolvedName, devices: eligible)
    }

    func isIgnoringGroupCoverUpdates(for deviceId: String, at now: Date) -> Bool {
        guard let deadline = groupCoverIgnoreUntil[deviceId] else { return false }
        if now < deadline { return true }
        groupCoverIgnoreUntil.removeValue(forKey: deviceId)
        return false
    }

    @discardableResult
    public func toggleRoomGroup(_ group: RoomAutoGroup) async -> HotkeyExecutionOutcome {
        let targetOn = !group.isAnyOn
        let title = targetOn
            ? L10n.format("已打开 %@", "Turned on %@", group.label)
            : L10n.format("已关闭 %@", "Turned off %@", group.label)
        return await executeRoomGroupAction(group: group, operation: .power(targetOn), title: title)
    }

    @discardableResult
    public func setRoomGroupLightBrightness(_ group: RoomAutoGroup, percent: Int) async -> HotkeyExecutionOutcome {
        guard group.kind == .light else { return .unavailable(label: group.label) }
        let clamped = max(1, min(100, percent))
        let title = L10n.tr("\(group.label) 已调至 \(clamped)%", "\(group.label) set to \(clamped)%")
        return await executeRoomGroupAction(group: group, operation: .brightness(clamped), title: title)
    }

    private struct GroupStep {
        let effect: AssistantEffect
        let confirmation: IntentOperation?
        let isCover: Bool
    }

    private func groupStep(for operation: IntentOperation, on device: SmartDevice) -> GroupStep? {
        guard device.isOnline, !device.telemetryStale,
              capabilityWriteRejection(forDeviceId: device.id) == nil else { return nil }
        let effect: AssistantEffect?
        let isCover: Bool
        switch (operation, device.kind) {
        case (.power(let open), .cover(let spec)):
            isCover = true
            let start = lastCoverPositions[device.id] ?? Self.coverReportedPosition(device)
            if spec.positionWritable {
                effect = Self.moodCoverEffect(position: open ? 100 : 0, on: device, reportedStart: start)
            } else if let action = open ? spec.openDescription : spec.closeDescription {
                var updated = device
                var nextSpec = spec
                nextSpec.motion = open ? .opening : .closing
                nextSpec.motionIsInferred = false
                updated.kind = .cover(nextSpec)
                let restoreDesc = open ? spec.closeDescription : spec.openDescription
                let restore: [DeviceCommand] = restoreDesc.map { [.setSelectOption(entityId: spec.entityId, option: $0)] } ?? []
                effect = AssistantEffect(updated: updated, command: .setSelectOption(entityId: spec.entityId, option: action), restore: restore)
            } else {
                effect = nil
            }
        default:
            isCover = false
            effect = Self.assistantEffect(of: operation, on: device)
        }
        guard let effect, capabilityUndoRejectionReason(for: effect.command) == nil else { return nil }
        let marks = SwitchLightMarks.load(defaults: userDefaults)
        let risky = ManualControlPolicy.requiresConfirmation(operation, for: device, markedLightIds: marks)
        return GroupStep(effect: effect, confirmation: risky ? operation : nil, isCover: isCover)
    }

    private func executeRoomGroupAction(
        group: RoomAutoGroup, operation: IntentOperation, title: String
    ) async -> HotkeyExecutionOutcome {
        if rejectControlWhileLocked() { return .blocked(message: screenLockBlockedMessage) }
        let context = controlContextID, generation = capabilityGeneration
        let revisions = optimisticLockRevision, originalBanner = undoBanner?.id
        var planned: [(SmartDevice, GroupStep)] = [], offline: [String] = [], skipped: [String] = []
        for deviceId in group.deviceIds {
            guard let device = devices.first(where: { $0.id == deviceId }) else { continue }
            guard device.isOnline else { offline.append(device.name); continue }
            guard let step = groupStep(for: operation, on: device) else { skipped.append(device.name); continue }
            planned.append((device, step))
        }
        guard !planned.isEmpty else { return .unavailable(label: group.label) }
        if planned.allSatisfy({ deviceBackend(for: $0.0.id) == .xiaomiCloud }), rejectWritesBlockedByMiSession() {
            return .blocked(message: Self.miSessionBlockedMessage)
        }
        let riskyNames = planned.compactMap { $0.1.confirmation != nil ? $0.0.name : nil }
        if !riskyNames.isEmpty {
            let names = riskyNames.joined(separator: L10n.isEnglish ? ", " : "、")
            guard manualControlConfirmationHandler?(ManualControlConfirmation(
                title: L10n.format("确认群控「%@」？", "Control “%@”?", group.label),
                message: L10n.format("此群控将对这些高风险设备执行操作：%@", "This group action controls these high-risk devices: %@", names),
                confirmTitle: L10n.tr("确认执行", "Confirm"),
                cancelTitle: L10n.tr("取消", "Cancel")
            )) == true else { return .cancelled }
        }
        guard context == controlContextID else { return .cancelled }
        if rejectControlWhileLocked() { return .blocked(message: screenLockBlockedMessage) }

        var restores: [(SmartDevice, [DeviceCommand], OptimisticWrite)] = []
        for (original, approved) in planned {
            guard context == controlContextID else { return .cancelled }
            guard !isControlBlockedByScreenLock else { skipped.append(original.name); continue }
            guard let live = devices.first(where: { $0.id == original.id }), live.isOnline else {
                offline.append(original.name); continue
            }
            guard !live.telemetryStale, capabilityGeneration == generation,
                  optimisticLockRevision[live.id] == revisions[original.id],
                  let step = groupStep(for: operation, on: live),
                  step.effect.command == approved.effect.command,
                  step.confirmation == nil || (
                      step.confirmation == approved.confirmation &&
                      ManualControlHazardProfile(live) == ManualControlHazardProfile(original)
                  ) else { skipped.append(original.name); continue }
            let lockDuration: Duration = step.isCover ? .seconds(Self.groupCoverIgnoreWindow) : .seconds(3)
            let write = beginOptimisticWrite(from: live, to: step.effect.updated, lock: lockDuration)
            if step.isCover {
                groupCoverIgnoreUntil[live.id] = optimisticNow().addingTimeInterval(Self.groupCoverIgnoreWindow)
            }
            do {
                try await send(step.effect.command, for: write, context: context)
                if !step.effect.restore.isEmpty { restores.append((live, step.effect.restore.reversed(), write)) }
            } catch {
                if step.isCover { groupCoverIgnoreUntil.removeValue(forKey: live.id) }
                skipped.append(original.name)
            }
        }

        guard context == controlContextID else { return .cancelled }
        let undo = restores.filter { ownsRow($0.2) && optimisticLockRevision[$0.0.id] == $0.2.revision }
        if !undo.isEmpty, undoBanner?.id == originalBanner {
            scheduleUndoBanner(title: title, restoreCommands: undo.flatMap { $0.1 },
                               previousDevices: undo.map { $0.0 }, deviceCount: undo.count)
        }
        if !offline.isEmpty || !skipped.isEmpty {
            let sep = L10n.isEnglish ? ", " : "、"
            let msg = [
                offline.isEmpty ? nil : L10n.format("离线，已跳过：%@", "Offline and skipped: %@", offline.joined(separator: sep)),
                skipped.isEmpty ? nil : L10n.format("未完整应用：%@", "Could not fully apply to: %@", skipped.joined(separator: sep)),
            ].compactMap { $0 }.joined(separator: "\n")
            showToast(msg, isError: true)
            return .failed(message: msg)
        }
        if undo.isEmpty { showToast(title) }
        return .executed(message: title)
    }
}
