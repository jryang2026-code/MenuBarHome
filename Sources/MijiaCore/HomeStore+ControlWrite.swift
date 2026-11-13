import Foundation

// MARK: - Control write
//
// Every path that changes a device row ahead of the device's own report goes through here:
// card controls, the assistant, undo, quick actions and Raycast links.
//
//     let write = beginOptimisticWrite(from: previous, to: updated, lock: .seconds(2.5))
//     try await send(command, for: write)   // a failure puts `previous` back
//
// The invariant this module owns: a failed send restores the pre-write row, drops the lock and
// the cover travel origin, but only while no newer write has taken the same device. Before it
// existed the rollback was copied into five places, and the Raycast copies had lost the
// newer-write check and the cover-origin cleanup.

/// One optimistic change to a device row, returned by `beginOptimisticWrite` and handed back
/// to `send` or `revert`.
struct OptimisticWrite: Sendable {
    let deviceId: String
    /// The row before the write; a failed send restores it.
    let previous: SmartDevice
    /// The lock revision this write owns. A newer write on the same device bumps it.
    let revision: UInt64?
    /// False when nothing was shown ahead of the device (a momentary button), so a failure has
    /// nothing to undo.
    let isShown: Bool
}

/// A write refused because the only Mi session has expired. The persistent toast is already showing.
struct MiSessionWriteBlocked: Error {}

extension HomeStore {
    /// True when the LAN client answers this command, so an expired Mi session cannot block it.
    func lgClientServes(_ command: DeviceCommand) -> Bool {
        lgWebOSClient != nil && LGWebOSProtocol.isLGEntity(command.targetEntityId)
    }

    /// True when this row is an LG TV the LAN client controls, so its card and drawer writes need
    /// no Mi session. A TV row without a running client falls back to the provider and does.
    func lgClientServes(_ device: SmartDevice) -> Bool {
        guard lgWebOSClient != nil, case .tv(let spec) = device.kind else { return false }
        return LGWebOSProtocol.isLGEntity(spec.mediaEntityId)
    }

    @discardableResult
    func lockOptimistic(
        _ deviceId: String,
        duration: Duration,
        preserveManualDebounces: Bool = false
    ) -> UInt64 {
        if !preserveManualDebounces {
            cancelDebouncedWrites(for: deviceId, recomputeRow: false)
            manualWriteSessions.removeValue(forKey: deviceId)
        }
        let rev = (optimisticLockRevision[deviceId] ?? 0) &+ 1
        optimisticLockRevision[deviceId] = rev
        optimisticLockUntil[deviceId] = ContinuousClock.now.advanced(by: duration)
        return rev
    }

    func clearManualWriteSession(for deviceId: String, bumpRevision: Bool = true) {
        cancelDebouncedWrites(for: deviceId, recomputeRow: false)
        manualWriteSessions.removeValue(forKey: deviceId)
        if bumpRevision {
            optimisticLockRevision[deviceId, default: 0] &+= 1
        }
    }

    func cancelDebouncedWrites(
        for deviceId: String?,
        exceptKey: String? = nil,
        keys: Set<String>? = nil,
        recomputeRow: Bool = true
    ) {
        var affectedDevices: Set<String> = []
        for (key, state) in Array(debouncedWrites)
        where (deviceId == nil || state.deviceId == deviceId)
            && key != exceptKey
            && (keys == nil || keys?.contains(key) == true) {
            debouncedWrites.removeValue(forKey: key)
            debounceTasks.removeValue(forKey: key)?.cancel()
            if recomputeRow,
               var session = manualWriteSessions[state.deviceId],
               optimisticLockRevision[state.deviceId] == session.revision {
                let countBefore = session.patches.count
                session.patches.removeAll { $0.token == state.token && $0.phase == .debouncing }
                if session.patches.count != countBefore {
                    manualWriteSessions[state.deviceId] = session
                    affectedDevices.insert(state.deviceId)
                }
            }
        }
        if recomputeRow {
            for id in affectedDevices {
                finalizeOrApplyManualWriteSession(for: id)
            }
        }
    }

    func reconcileManualWriteSessionWithSnapshot(_ incoming: SmartDevice) -> SmartDevice {
        guard var session = manualWriteSessions[incoming.id],
              optimisticLockRevision[incoming.id] == session.revision else {
            manualWriteSessions.removeValue(forKey: incoming.id)
            return incoming
        }
        session.patches.removeAll { $0.phase == .succeeded }
        session.baseLockUntil = nil
        session.baseCoverOrigin = nil
        if session.patches.isEmpty {
            manualWriteSessions.removeValue(forKey: incoming.id)
            return incoming
        }
        session.base = incoming
        manualWriteSessions[incoming.id] = session
        var composed = incoming
        for patch in session.patches {
            patch.apply(&composed)
        }
        return composed
    }

    private func foldExpiredSucceededPatches(in session: inout ManualWriteSession, now: ContinuousClock.Instant) {
        var remaining: [ManualWritePatch] = []
        remaining.reserveCapacity(session.patches.count)
        for patch in session.patches {
            if patch.phase == .succeeded, patch.lockUntil.map({ $0 <= now }) ?? true {
                patch.apply(&session.base)
            } else {
                remaining.append(patch)
            }
        }
        session.patches = remaining
    }

    private func finalizeOrApplyManualWriteSession(for deviceId: String) {
        guard var session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision else { return }
        let now = ContinuousClock.now
        foldExpiredSucceededPatches(in: &session, now: now)
        if session.patches.isEmpty {
            if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
                devices[idx] = session.base
                syncGenericPowerFacet(session.base)
            }
            manualWriteSessions.removeValue(forKey: deviceId)
            if let baseLock = session.baseLockUntil, baseLock > now {
                optimisticLockUntil[deviceId] = baseLock
            } else {
                optimisticLockUntil.removeValue(forKey: deviceId)
            }
            if let priorOrigin = session.baseCoverOrigin {
                coverCommandOrigins[deviceId] = priorOrigin
            } else {
                coverCommandOrigins.removeValue(forKey: deviceId)
            }
        } else {
            manualWriteSessions[deviceId] = session
            applyManualWriteSession(for: deviceId, now: now)
        }
    }

    private func applyManualWriteSession(for deviceId: String, now: ContinuousClock.Instant = .now) {
        guard let session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision else { return }
        if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
            var composed = session.base
            for patch in session.patches {
                patch.apply(&composed)
            }
            devices[idx] = composed
            syncGenericPowerFacet(composed)
        }
        let patchLock = session.patches.compactMap(\.lockUntil).filter { $0 > now }.max()
        let baseLock = session.baseLockUntil.flatMap { $0 > now ? $0 : nil }
        if let activeLock = [patchLock, baseLock].compactMap({ $0 }).max() {
            optimisticLockUntil[deviceId] = activeLock
        } else {
            optimisticLockUntil.removeValue(forKey: deviceId)
        }
    }

    private func updateManualSessionPatchForSend(
        deviceId: String,
        token: UUID,
        lock: Duration?
    ) -> Bool {
        guard var session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision,
              let idx = session.patches.firstIndex(where: { $0.token == token }) else {
            return false
        }
        let now = ContinuousClock.now
        session.patches[idx].phase = .inFlight
        if let lock {
            let until = now.advanced(by: lock)
            session.patches[idx].lockUntil = until
        }
        manualWriteSessions[deviceId] = session
        if let maxLock = session.patches.compactMap(\.lockUntil).filter({ $0 > now }).max() {
            optimisticLockUntil[deviceId] = maxLock
        }
        return true
    }

    private func markManualSessionPatchSucceeded(deviceId: String, token: UUID) {
        guard var session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision,
              let idx = session.patches.firstIndex(where: { $0.token == token }) else {
            return
        }
        session.patches[idx].phase = .succeeded
        manualWriteSessions[deviceId] = session
    }

    private func revertManualSessionPatch(deviceId: String, token: UUID) {
        guard var session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision,
              let removeIdx = session.patches.firstIndex(where: { $0.token == token }) else {
            return
        }
        session.patches.remove(at: removeIdx)
        manualWriteSessions[deviceId] = session
        finalizeOrApplyManualWriteSession(for: deviceId)
    }

    func executeDeviceCommand(_ command: DeviceCommand) async throws {
        if LGWebOSProtocol.isLGEntity(command.targetEntityId), let lgClient = lgWebOSClient {
            try await lgClient.execute(command)
        } else {
            // The guard sits on the Mi provider call, not on every command: a LAN TV write does
            // not depend on the expired Xiaomi Home session.
            if rejectWritesBlockedByMiSession() {
                throw MiSessionWriteBlocked()
            }
            try await provider.execute(command)
        }
    }

    /// Shows `updated` now. With a `lock`, stale snapshots cannot overwrite it until the lock
    /// expires or the device reports the same state. Without one the row changes but an earlier
    /// lock (if any) stays in charge. Pass `updated: nil` to send without showing anything.
    func beginOptimisticWrite(
        from previous: SmartDevice,
        to updated: SmartDevice?,
        lock: Duration?,
        preserveManualDebounces: Bool = false
    ) -> OptimisticWrite {
        guard let updated, let idx = devices.firstIndex(where: { $0.id == previous.id }) else {
            return OptimisticWrite(deviceId: previous.id, previous: previous, revision: nil, isShown: false)
        }
        devices[idx] = updated
        syncGenericPowerFacet(updated)
        let revision = lock.map {
            lockOptimistic(previous.id, duration: $0, preserveManualDebounces: preserveManualDebounces)
        } ?? optimisticLockRevision[previous.id]
        return OptimisticWrite(deviceId: previous.id, previous: previous, revision: revision, isShown: true)
    }

    /// True while no newer write has taken this write's device.
    func ownsRow(_ write: OptimisticWrite) -> Bool {
        optimisticLockRevision[write.deviceId] == write.revision
    }

    /// Sends `commands` in order for `write`. On failure the row is rolled back (see `revert`)
    /// unless `context` is given and the control context has moved on, then the error is rethrown.
    func send(_ commands: [DeviceCommand], for write: OptimisticWrite, context: UUID? = nil) async throws {
        do {
            for command in commands {
                try await executeDeviceCommand(command)
            }
        } catch {
            if context == nil || context == controlContextID {
                revert(write)
            }
            throw error
        }
    }

    func send(_ command: DeviceCommand, for write: OptimisticWrite, context: UUID? = nil) async throws {
        try await send([command], for: write, context: context)
    }

    /// Restores `restoring` (the write's previous row by default) when the write still owns the device.
    func revert(_ write: OptimisticWrite, restoring: SmartDevice? = nil) {
        guard write.isShown, ownsRow(write) else { return }
        if let idx = devices.firstIndex(where: { $0.id == write.deviceId }) {
            devices[idx] = restoring ?? write.previous
            syncGenericPowerFacet(devices[idx])
        }
        optimisticLockUntil.removeValue(forKey: write.deviceId)
        coverCommandOrigins.removeValue(forKey: write.deviceId)
    }

    /// Puts back the cover travel origin a tap wrote before its command, for a tap that never
    /// reached the device. Only the tap's own value is put back, and only while no newer write has
    /// taken the row, so a newer tap or drag keeps the origin it owns.
    func discardCoverOrigin(
        _ origin: (prior: Int?, written: Int)?,
        deviceId: String,
        revision: UInt64?
    ) {
        guard let origin,
              optimisticLockRevision[deviceId] == revision,
              coverCommandOrigins[deviceId] == origin.written else { return }
        if let prior = origin.prior {
            coverCommandOrigins[deviceId] = prior
        } else {
            coverCommandOrigins.removeValue(forKey: deviceId)
        }
    }

    /// Keeps a stored facet row on the same value as the generic tile's main switch. The switch is
    /// normally not in `deviceFacets`, so this is a no-op unless a test or an older snapshot row
    /// still carries it.
    func syncGenericPowerFacet(_ device: SmartDevice) {
        guard case .generic(let spec) = device.kind,
              let control = spec.powerControl,
              let index = deviceFacets[device.id]?.firstIndex(where: { $0.id == control.id }) else {
            return
        }
        deviceFacets[device.id]?[index].value = .bool(spec.isOn)
    }

    // MARK: Card controls

    /// The row a card control acts on, after the lock-screen and expired-session checks.
    func controllableDevice(_ deviceId: String) -> SmartDevice? {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return nil }
        guard !rejectWritesBlockedByMiSession(needsMi: !lgClientServes(device)) else { return nil }
        guard !rejectControlWhileLocked() else { return nil }
        return device
    }

    /// A card control's write: show `updated`, send `command` (after `debounceKey`'s quiet period
    /// when given, so a slider sends only its last value), record `habitIntents` on success, and
    /// roll back with a toast on failure.
    func commitManualWrite(
        from previous: SmartDevice,
        to updated: SmartDevice?,
        command: DeviceCommand,
        lock: Duration?,
        debounceKey: String? = nil,
        priorCoverOrigin: Int? = nil,
        powersOffDevice: Bool = false,
        habitIntents: [DeviceIntent] = [],
        mutate: (@Sendable (inout SmartDevice) -> Void)? = nil
    ) {
        let context = controlContextID
        guard let updated else {
            let write = beginOptimisticWrite(from: previous, to: nil, lock: nil)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(command, for: write, context: context)
                    guard self.controlContextID == context else { return }
                    self.confirmManualControl(intents: habitIntents)
                } catch {
                    guard self.controlContextID == context else { return }
                    self.showControlFailure(error, device: previous, adjustment: false)
                }
            }
            return
        }

        let deviceId = previous.id
        let now = ContinuousClock.now
        let token = UUID()
        let slotKey = debounceKey ?? token.uuidString
        let applyPatch: @Sendable (inout SmartDevice) -> Void = mutate ?? { $0 = updated }
        let priorLock = optimisticLockUntil[deviceId].flatMap { $0 > now ? $0 : nil }

        var session: ManualWriteSession
        if var existing = manualWriteSessions[deviceId],
           optimisticLockRevision[deviceId] == existing.revision {
            foldExpiredSucceededPatches(in: &existing, now: now)
            if existing.patches.isEmpty {
                let baseRow = (debounceKey.flatMap { debouncedWrites[$0]?.origin }) ?? previous
                session = ManualWriteSession(
                    revision: 0,
                    base: baseRow,
                    baseCoverOrigin: priorCoverOrigin,
                    baseLockUntil: priorLock,
                    patches: []
                )
            } else {
                session = existing
            }
        } else {
            let baseRow = (debounceKey.flatMap { debouncedWrites[$0]?.origin }) ?? previous
            session = ManualWriteSession(
                revision: 0,
                base: baseRow,
                baseCoverOrigin: priorCoverOrigin,
                baseLockUntil: priorLock,
                patches: []
            )
        }

        if powersOffDevice {
            cancelDebouncedWrites(for: deviceId, exceptKey: debounceKey, recomputeRow: false)
            session.patches.removeAll { $0.slotKey != debounceKey && $0.phase == .debouncing }
        }
        if let debounceKey {
            session.patches.removeAll { $0.slotKey == debounceKey && $0.phase == .debouncing }
        }

        let initialLockUntil = lock.map { now.advanced(by: $0) }
        let phase: ManualWritePatch.Phase = (debounceKey == nil) ? .inFlight : .debouncing
        session.patches.append(ManualWritePatch(
            slotKey: slotKey,
            token: token,
            phase: phase,
            lockUntil: initialLockUntil,
            apply: applyPatch
        ))

        let rev = (optimisticLockRevision[deviceId] ?? 0) &+ 1
        optimisticLockRevision[deviceId] = rev
        session.revision = rev
        manualWriteSessions[deviceId] = session
        applyManualWriteSession(for: deviceId, now: now)

        let sessionBase = session.base
        guard let debounceKey else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.executeDeviceCommand(command)
                    guard self.controlContextID == context else { return }
                    self.markManualSessionPatchSucceeded(deviceId: deviceId, token: token)
                    self.confirmManualControl(intents: habitIntents)
                } catch {
                    guard self.controlContextID == context else { return }
                    self.revertManualSessionPatch(deviceId: deviceId, token: token)
                    self.showControlFailure(error, device: sessionBase, adjustment: false)
                }
            }
            return
        }

        let slotOrigin = debouncedWrites[debounceKey]?.origin ?? previous
        debouncedWrites[debounceKey] = DebouncedWriteState(
            token: token,
            deviceId: deviceId,
            origin: slotOrigin
        )
        debounceTasks[debounceKey]?.cancel()
        debounceTasks[debounceKey] = Task { [weak self] in
            defer {
                if let self, self.debouncedWrites[debounceKey]?.token == token {
                    self.debouncedWrites.removeValue(forKey: debounceKey)
                    self.debounceTasks.removeValue(forKey: debounceKey)
                }
            }
            try? await Task.sleep(for: self?.controlDebounceInterval ?? .milliseconds(280))
            guard !Task.isCancelled,
                  let self,
                  self.controlContextID == context,
                  self.debouncedWrites[debounceKey]?.token == token,
                  self.updateManualSessionPatchForSend(deviceId: deviceId, token: token, lock: lock) else { return }
            do {
                try await self.executeDeviceCommand(command)
                guard self.controlContextID == context else { return }
                self.markManualSessionPatchSucceeded(deviceId: deviceId, token: token)
                self.confirmManualControl(intents: habitIntents)
            } catch {
                guard self.controlContextID == context else { return }
                self.revertManualSessionPatch(deviceId: deviceId, token: token)
                self.showControlFailure(error, device: sessionBase, adjustment: true)
            }
        }
    }

    func showControlFailure(_ error: Error, device: SmartDevice, adjustment: Bool) {
        guard !ControlFailure.isCancellation(error) else { return }
        showToast(
            ControlFailure.userMessage(
                for: error,
                deviceName: device.name,
                isDeviceOnline: device.isOnline,
                adjustment: adjustment
            ),
            isError: true
        )
    }
}
