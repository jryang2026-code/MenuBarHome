import Foundation

extension HomeStore {
    @discardableResult
    public func captureMood(name: String, roomId: String) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let targets = devices.filter { $0.roomId == roomId }.compactMap(moodTarget)
        guard !targets.isEmpty else {
            showToast(L10n.tr("这个房间没有可保存的设备状态", "This room has no device states to save"), isError: true)
            return false
        }
        let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let mood = MoodSnapshot(id: UUID().uuidString, name: title, createdAt: createdAt, targets: targets)
        return saveMoods(Array(([mood] + moods).prefix(MoodPreferences.limit)))
    }

    public func deleteMood(id: String) {
        _ = saveMoods(moods.filter { $0.id != id })
    }

    private func saveMoods(_ updated: [MoodSnapshot]) -> Bool {
        do {
            try MoodPreferences.save(updated, to: userDefaults)
            moods = updated
            return true
        } catch {
            showToast(L10n.tr("无法保存氛围", "Could not save moods"), isError: true)
            return false
        }
    }

    private func moodScope(for device: SmartDevice) -> String? {
        switch deviceBackend(for: device.id) {
        case .homeAssistant: return homeAssistantScopeIdentifier
        case .xiaomiCloud:
            return device.accountId.map(ConnectionRemovalStore.miScope(accountId:)) ?? miSessionScopeIdentifier
        case .demo: return "demo"
        }
    }

    private func moodTarget(for device: SmartDevice) -> MoodSnapshot.Target? {
        guard device.isOnline, !device.telemetryStale,
              capabilityWriteRejection(forDeviceId: device.id) == nil,
              let scope = moodScope(for: device),
              let entityId = Self.moodEntityId(for: device) else { return nil }
        var target = MoodSnapshot.Target(deviceId: device.id, name: device.name, sourceScope: scope, entityId: entityId)
        switch device.kind {
        case .light(let spec):
            target.power = spec.powerWritable ? spec.isOn : nil
            if spec.isOn {
                target.brightness = spec.brightnessWritable ? spec.brightnessPercent.map { min(100, max(1, $0)) } : nil
                target.colorTemperature = spec.colorWritable ? spec.colorTempKelvin : nil
            }
        case .climate(let spec):
            let mode = spec.isOn ? spec.hvacMode : "off"
            if !spec.availableModes.isEmpty,
               IntentValidator.normalize(.hvacMode(mode), for: device) == .hvacMode(mode),
               spec.isOn || spec.availableModes.contains("off") {
                target.hvacMode = mode
            }
            if target.hvacMode == nil, spec.powerWritable { target.power = spec.isOn }
            if spec.isOn, spec.temperatureWritable, spec.targetTemperature.isFinite {
                target.targetTemperature = spec.targetTemperature
            }
        case .fan(let spec):
            if spec.powerWritable { target.power = spec.isOn }
        case .plug(let spec):
            if spec.powerWritable, !device.isMomentaryButton { target.power = spec.isOn }
        case .cover(let spec):
            if spec.positionWritable {
                target.coverPosition = lastCoverPositions[device.id] ?? Self.coverReportedPosition(device)
                    ?? (!spec.isMoving ? spec.positionPercent : nil)
            }
        default:
            return nil
        }
        return target.fields.isEmpty ? nil : target
    }

    private static func moodEntityId(for device: SmartDevice) -> String? {
        switch device.kind {
        case .light(let spec): return spec.entityId
        case .climate(let spec): return spec.entityId
        case .fan(let spec): return spec.entityId
        case .plug(let spec): return spec.switchEntityId
        case .cover(let spec): return spec.entityId
        default: return nil
        }
    }

    static func moodCoverEffect(position: Int, on device: SmartDevice, reportedStart: Int? = nil) -> AssistantEffect? {
        guard (0...100).contains(position), case .cover(var spec) = device.kind,
              spec.positionWritable else { return nil }
        let start = reportedStart ?? coverReportedPosition(device)
        let restore: [DeviceCommand] = start.map {
            [.setNumberValue(entityId: spec.entityId, value: Double($0))]
        } ?? []
        let direction = start.flatMap { coverDragDirection(from: $0, to: position) }
        spec.positionPercent = CoverSpec.snappedPosition(position)
        spec.motion = direction.map { $0 ? .opening : .closing } ?? .stopped
        spec.motionIsInferred = false
        var updated = device
        updated.kind = .cover(spec)
        return AssistantEffect(
            updated: updated,
            command: .setNumberValue(entityId: spec.entityId, value: Double(position)),
            restore: restore
        )
    }

    static func moodCoverRestore(
        _ command: DeviceCommand, on device: SmartDevice, reportedStart: Int? = nil
    ) -> AssistantEffect? {
        guard case .setNumberValue(let entityId, let value) = command,
              case .cover(let spec) = device.kind, spec.entityId == entityId,
              value.isFinite, (0...100).contains(value), value.rounded() == value else { return nil }
        return moodCoverEffect(position: Int(value), on: device, reportedStart: reportedStart)
    }

    private struct MoodStep {
        let effect: AssistantEffect
        let confirmation: IntentOperation?
    }

    private func moodStep(_ field: MoodSnapshot.Field, on device: SmartDevice) -> MoodStep? {
        let operation: IntentOperation
        let effect: AssistantEffect?
        switch field {
        case .intent(let requested):
            guard !device.isMomentaryButton, Self.moodEntityId(for: device) != nil,
                  IntentValidator.normalize(requested, for: device) == requested else { return nil }
            if case .hvacMode("off") = requested, case .climate(let spec) = device.kind,
               !spec.availableModes.contains("off") { return nil }
            operation = requested
            effect = Self.assistantEffect(of: requested, on: device)
        case .coverPosition(let position):
            let start = lastCoverPositions[device.id] ?? Self.coverReportedPosition(device)
            operation = .power(Self.coverDragDirection(from: start, to: position) ?? true)
            effect = Self.moodCoverEffect(position: position, on: device, reportedStart: start)
        }
        guard let effect, capabilityUndoRejectionReason(for: effect.command) == nil else { return nil }
        let marks = SwitchLightMarks.load(defaults: userDefaults)
        let risky = ManualControlPolicy.requiresConfirmation(operation, for: device, markedLightIds: marks)
        return MoodStep(effect: effect, confirmation: risky ? operation : nil)
    }

    private func moodDevice(for target: MoodSnapshot.Target) -> SmartDevice? {
        guard let device = devices.first(where: { $0.id == target.deviceId }),
              moodScope(for: device) == target.sourceScope,
              Self.moodEntityId(for: device) == target.entityId else { return nil }
        return device
    }

    @discardableResult
    public func applyMood(id: String) async -> HotkeyExecutionOutcome {
        guard let mood = moods.first(where: { $0.id == id }) else { return .unavailable(label: id) }
        if rejectControlWhileLocked() { return .blocked(message: screenLockBlockedMessage) }
        if rejectWritesBlockedByMiSession() { return .blocked(message: Self.miSessionBlockedMessage) }

        let context = controlContextID
        let generation = capabilityGeneration
        let revisions = optimisticLockRevision
        let originalBanner = undoBanner?.id
        var skipped: [String] = []
        var offline: [String] = []
        let planned = mood.targets.compactMap { target -> (MoodSnapshot.Target, SmartDevice, [MoodStep?])? in
            guard let device = moodDevice(for: target) else {
                skipped.append(target.name)
                return nil
            }
            guard device.isOnline else {
                offline.append(device.name)
                return nil
            }
            return (target, device, target.fields.map { moodStep($0, on: device) })
        }
        let riskyNames = planned.compactMap { _, device, steps in
            steps.contains { $0?.confirmation != nil } ? device.name : nil
        }
        if !riskyNames.isEmpty {
            let names = riskyNames.joined(separator: L10n.isEnglish ? ", " : "、")
            guard manualControlConfirmationHandler?(ManualControlConfirmation(
                title: L10n.format("确认应用「%@」？", "Apply “%@”?", mood.name),
                message: L10n.format("此氛围将对这些高风险设备执行操作：%@", "This mood controls these high-risk devices: %@", names),
                confirmTitle: L10n.tr("确认执行", "Confirm"),
                cancelTitle: L10n.tr("取消", "Cancel")
            )) == true else { return .cancelled }
        }

        guard context == controlContextID else { return .cancelled }
        if rejectControlWhileLocked() { return .blocked(message: screenLockBlockedMessage) }

        var restores: [(SmartDevice, [DeviceCommand], OptimisticWrite)] = []
        for (target, original, steps) in planned {
            var lastWrite: OptimisticWrite?
            var restore: [DeviceCommand] = []
            var before: SmartDevice?
            var revision = revisions[original.id]
            for (field, approved) in zip(target.fields, steps) {
                guard context == controlContextID else { return .cancelled }
                guard !isControlBlockedByScreenLock else {
                    skipped.append(original.name)
                    break
                }
                guard let live = moodDevice(for: target) else {
                    skipped.append(original.name)
                    break
                }
                guard live.isOnline else {
                    offline.append(live.name)
                    break
                }
                guard !live.telemetryStale,
                      capabilityGeneration == generation,
                      optimisticLockRevision[live.id] == revision,
                      lastWrite.map(ownsRow) != false,
                      let approved, let step = moodStep(field, on: live),
                      step.effect.command == approved.effect.command,
                      step.confirmation == nil || (
                          step.confirmation == approved.confirmation &&
                          ManualControlHazardProfile(live) == ManualControlHazardProfile(original)
                      ) else {
                    skipped.append(original.name)
                    break
                }
                if before == nil { before = live }
                let write = beginOptimisticWrite(from: live, to: step.effect.updated, lock: .seconds(3))
                do {
                    try await send(step.effect.command, for: write, context: context)
                    lastWrite = write
                    revision = write.revision
                    restore.insert(contentsOf: step.effect.restore.reversed(), at: 0)
                } catch {
                    // A failed optimistic write also advances the row revision.
                    if ownsRow(write) { lastWrite = write }
                    skipped.append(original.name)
                    break
                }
            }
            if let before, let lastWrite, !restore.isEmpty { restores.append((before, restore, lastWrite)) }
        }
        guard context == controlContextID else { return .cancelled }
        let title = L10n.format("已应用「%@」", "Applied “%@”", mood.name)
        let undo = restores.filter { ownsRow($0.2) && optimisticLockRevision[$0.0.id] == $0.2.revision }
        if !undo.isEmpty, undoBanner?.id == originalBanner {
            scheduleUndoBanner(
                title: title, restoreCommands: undo.flatMap { $0.1 }, previousDevices: undo.map { $0.0 },
                deviceCount: undo.count
            )
        }
        if !offline.isEmpty || !skipped.isEmpty {
            let separator = L10n.isEnglish ? ", " : "、"
            let unavailable = offline.isEmpty ? nil
                : L10n.format("离线，已跳过：%@", "Offline and skipped: %@", offline.joined(separator: separator))
            let failed = skipped.isEmpty ? nil
                : L10n.format("未完整应用：%@", "Could not fully apply to: %@", skipped.joined(separator: separator))
            let message = [unavailable, failed].compactMap { $0 }.joined(separator: "\n")
            showToast(message, isError: true)
            return .failed(message: message)
        }
        if undo.isEmpty { showToast(title) }
        return .executed(message: title)
    }
}
