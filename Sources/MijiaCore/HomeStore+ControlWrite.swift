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
    /// The lock revision this write owns. A newer write on the same field/device bumps it.
    let revision: UInt64?
    /// Specific card fields mutated and locked by this write. Empty means whole-row fallback.
    let fields: Set<OptimisticField>
    /// Per-field lock revisions owned by this write.
    let fieldRevisions: [OptimisticField: UInt64]
    /// Specific facet control IDs locked by this write, if any.
    let facetControlIds: Set<String>
    /// Per-facet lock revisions owned by this write.
    let facetRevisions: [String: UInt64]
    /// False when nothing was shown ahead of the device (a momentary button), so a failure has
    /// nothing to undo.
    let isShown: Bool

    init(
        deviceId: String,
        previous: SmartDevice,
        revision: UInt64?,
        fields: Set<OptimisticField> = [],
        fieldRevisions: [OptimisticField: UInt64]? = nil,
        facetControlIds: Set<String> = [],
        facetRevisions: [String: UInt64]? = nil,
        isShown: Bool
    ) {
        self.deviceId = deviceId
        self.previous = previous
        self.revision = revision
        self.fields = fields
        if let fieldRevisions {
            self.fieldRevisions = fieldRevisions
        } else if let revision {
            self.fieldRevisions = Dictionary(uniqueKeysWithValues: fields.map { ($0, revision) })
        } else {
            self.fieldRevisions = [:]
        }
        self.facetControlIds = facetControlIds
        if let facetRevisions {
            self.facetRevisions = facetRevisions
        } else if let revision {
            self.facetRevisions = Dictionary(uniqueKeysWithValues: facetControlIds.map { ($0, revision) })
        } else {
            self.facetRevisions = [:]
        }
        self.isShown = isShown
    }
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

    static func facetLockKey(_ deviceId: String, _ controlId: String) -> String {
        "\(deviceId).facet.\(controlId)"
    }

    static func deviceId(fromFacetWriteKey key: String) -> String? {
        guard let range = key.range(of: ".facet.") else { return nil }
        return String(key[..<range.lowerBound])
    }

    static func controlId(fromFacetWriteKey key: String) -> String? {
        guard let range = key.range(of: ".facet.") else { return nil }
        return String(key[range.upperBound...])
    }

    func continuousInstant(from date: Date) -> ContinuousClock.Instant {
        let delta = date.timeIntervalSince(optimisticClockAnchorDate)
        return optimisticClockAnchorInstant.advanced(by: .nanoseconds(Int64((delta * 1_000_000_000).rounded())))
    }

    func date(from instant: ContinuousClock.Instant) -> Date {
        let delta = optimisticClockAnchorInstant.duration(to: instant).optimisticTimeInterval
        return optimisticClockAnchorDate.addingTimeInterval(delta)
    }

    func optimisticLockMaxDatesByDevice() -> [String: Date] {
        var result: [String: Date] = [:]
        for (key, entry) in optimisticFieldLocks {
            if let existing = result[key.deviceId], existing >= entry.until { continue }
            result[key.deviceId] = entry.until
        }
        for (facetKey, entry) in optimisticFacetLocks {
            guard let deviceId = Self.deviceId(fromFacetWriteKey: facetKey) else { continue }
            if let existing = result[deviceId], existing >= entry.until { continue }
            result[deviceId] = entry.until
        }
        return result
    }

    func optimisticLockMaxInstantsByDevice() -> [String: ContinuousClock.Instant] {
        var result: [String: ContinuousClock.Instant] = [:]
        for (key, entry) in optimisticFieldLocks {
            let instant = entry.untilInstant ?? continuousInstant(from: entry.until)
            if let existing = result[key.deviceId], existing >= instant { continue }
            result[key.deviceId] = instant
        }
        for (facetKey, entry) in optimisticFacetLocks {
            guard let deviceId = Self.deviceId(fromFacetWriteKey: facetKey) else { continue }
            let instant = entry.untilInstant ?? continuousInstant(from: entry.until)
            if let existing = result[deviceId], existing >= instant { continue }
            result[deviceId] = instant
        }
        return result
    }

    func clearOptimisticLockEntries(for deviceId: String) {
        for key in optimisticFieldLocks.keys where key.deviceId == deviceId {
            optimisticFieldLocks.removeValue(forKey: key)
        }
        let prefix = "\(deviceId).facet."
        for key in optimisticFacetLocks.keys where key.hasPrefix(prefix) {
            optimisticFacetLocks.removeValue(forKey: key)
        }
        if var session = manualWriteSessions[deviceId] {
            session.baseFieldLocks.removeAll()
            var remaining: [ManualWritePatch] = []
            for var patch in session.patches {
                patch.lockEntry = nil
                if patch.phase == .succeeded {
                    applyManualPatch(patch, to: &session.base)
                } else {
                    remaining.append(patch)
                }
            }
            session.patches = remaining
            if session.patches.isEmpty {
                manualWriteSessions.removeValue(forKey: deviceId)
            } else {
                manualWriteSessions[deviceId] = session
            }
        }
    }

    func clearOptimisticRevisions(for deviceId: String) {
        for key in optimisticFieldRevisions.keys where key.deviceId == deviceId {
            optimisticFieldRevisions.removeValue(forKey: key)
        }
        let prefix = "\(deviceId).facet."
        for key in optimisticFacetRevisions.keys where key.hasPrefix(prefix) {
            optimisticFacetRevisions.removeValue(forKey: key)
        }
    }

    func setOptimisticLockExpiration(
        _ until: Date,
        untilInstant: ContinuousClock.Instant? = nil,
        for deviceId: String
    ) {
        let instant = hasCustomOptimisticNow ? nil : untilInstant
        for key in optimisticFieldLocks.keys where key.deviceId == deviceId {
            optimisticFieldLocks[key]?.until = until
            optimisticFieldLocks[key]?.untilInstant = instant
        }
        let prefix = "\(deviceId).facet."
        for key in optimisticFacetLocks.keys where key.hasPrefix(prefix) {
            optimisticFacetLocks[key]?.until = until
            optimisticFacetLocks[key]?.untilInstant = instant
        }
        if var session = manualWriteSessions[deviceId] {
            for field in Array(session.baseFieldLocks.keys) {
                session.baseFieldLocks[field]?.until = until
                session.baseFieldLocks[field]?.untilInstant = instant
            }
            for idx in session.patches.indices where session.patches[idx].lockEntry != nil {
                session.patches[idx].lockEntry?.until = until
                session.patches[idx].lockEntry?.untilInstant = instant
            }
            manualWriteSessions[deviceId] = session
        }
    }

    func makeOptimisticEntry(duration: Duration, revision: UInt64) -> OptimisticLockEntry {
        OptimisticLockEntry(
            until: optimisticNow().addingTimeInterval(duration.optimisticTimeInterval),
            untilInstant: hasCustomOptimisticNow ? nil : ContinuousClock.now.advanced(by: duration),
            revision: revision
        )
    }

    func isOptimisticEntryActive(
        _ entry: OptimisticLockEntry,
        at now: Date,
        continuousNow: ContinuousClock.Instant
    ) -> Bool {
        if hasCustomOptimisticNow {
            return entry.isActive(at: now)
        }
        if let untilInstant = entry.untilInstant {
            return continuousNow < untilInstant
        }
        return entry.isActive(at: now)
    }

    /// Clears all optimistic field/facet lock leases, revisions, and cover travel origins
    /// (for a single device when `deviceId` is given, or globally on backend switch / shutdown).
    func clearOptimisticLocks(for deviceId: String? = nil) {
        if let deviceId {
            cancelDebouncedWrites(for: deviceId, recomputeRow: false)
            manualWriteSessions.removeValue(forKey: deviceId)
            clearOptimisticLockEntries(for: deviceId)
            clearOptimisticRevisions(for: deviceId)
            optimisticLockRevision.removeValue(forKey: deviceId)
            coverCommandOrigins.removeValue(forKey: deviceId)
        } else {
            cancelDebouncedWrites(for: nil, recomputeRow: false)
            manualWriteSessions.removeAll()
            optimisticFieldLocks.removeAll()
            optimisticFacetLocks.removeAll()
            optimisticFieldRevisions.removeAll()
            optimisticFacetRevisions.removeAll()
            optimisticLockRevision.removeAll()
            coverCommandOrigins.removeAll()
        }
    }

    /// Removes expired field and facet locks for `deviceId` at `now`.
    func pruneExpiredOptimisticLocks(
        for deviceId: String,
        at now: Date,
        continuousNow: ContinuousClock.Instant = .now
    ) {
        for (key, entry) in optimisticFieldLocks
        where key.deviceId == deviceId && !isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow) {
            optimisticFieldLocks.removeValue(forKey: key)
        }
        let prefix = "\(deviceId).facet."
        for (key, entry) in optimisticFacetLocks
        where key.hasPrefix(prefix) && !isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow) {
            optimisticFacetLocks.removeValue(forKey: key)
        }
        if optimisticFieldLocks[.field(deviceId, .coverPosition)] == nil {
            coverCommandOrigins.removeValue(forKey: deviceId)
        }
    }

    /// Returns fields actively locked on `deviceId` at `now`.
    func activeLockedFields(
        for deviceId: String,
        at now: Date,
        continuousNow: ContinuousClock.Instant = .now
    ) -> Set<OptimisticField> {
        var fields: Set<OptimisticField> = []
        for (key, entry) in optimisticFieldLocks
        where key.deviceId == deviceId && isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow) {
            if let field = key.field {
                fields.insert(field)
            }
        }
        return fields
    }

    /// Returns facet control IDs actively locked on `deviceId` at `now`.
    func activeLockedFacetControlIds(
        for deviceId: String,
        at now: Date,
        continuousNow: ContinuousClock.Instant = .now
    ) -> Set<String> {
        let prefix = "\(deviceId).facet."
        var controlIds: Set<String> = []
        for (key, entry) in optimisticFacetLocks
        where key.hasPrefix(prefix) && isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow) {
            if let controlId = Self.controlId(fromFacetWriteKey: key) {
                controlIds.insert(controlId)
            }
        }
        return controlIds
    }

    @discardableResult
    func lockOptimistic(
        _ deviceId: String,
        fields: Set<OptimisticField>? = nil,
        duration: Duration,
        preserveManualDebounces: Bool = false
    ) -> UInt64 {
        if !preserveManualDebounces {
            cancelDebouncedWrites(for: deviceId, recomputeRow: false)
            manualWriteSessions.removeValue(forKey: deviceId)
        }
        let rev = (optimisticLockRevision[deviceId] ?? 0) &+ 1
        optimisticLockRevision[deviceId] = rev
        let targetFields: Set<OptimisticField>
        if let fields, !fields.isEmpty {
            targetFields = fields
        } else if let device = devices.first(where: { $0.id == deviceId }) {
            let defaults = OptimisticField.primaryPowerFields(for: device.kind)
            targetFields = defaults.isEmpty ? [.power] : defaults
        } else {
            targetFields = [.power]
        }
        let entry = makeOptimisticEntry(duration: duration, revision: rev)
        for field in targetFields {
            optimisticFieldLocks[.field(deviceId, field)] = entry
            optimisticFieldRevisions[.field(deviceId, field)] = rev
        }
        return rev
    }

    @discardableResult
    func lockOptimisticFacet(
        _ deviceId: String,
        controlId: String,
        duration: Duration,
        bumpDeviceRevision: Bool = false
    ) -> UInt64 {
        let key = Self.facetLockKey(deviceId, controlId)
        let baseline = max(optimisticFacetRevisions[key] ?? 0, optimisticLockRevision[deviceId] ?? 0)
        let rev = baseline &+ 1
        if bumpDeviceRevision {
            optimisticLockRevision[deviceId] = rev
        }
        optimisticFacetLocks[key] = makeOptimisticEntry(duration: duration, revision: rev)
        optimisticFacetRevisions[key] = rev
        return rev
    }

    private func applyManualPatch(_ patch: ManualWritePatch, to device: inout SmartDevice) {
        var scratched = device
        patch.apply(&scratched)
        if !patch.fields.isEmpty {
            device = device.mergingOptimisticFields(from: scratched, lockedFields: patch.fields)
        } else {
            device = scratched
        }
    }

    private func syncManualSessionFieldLocks(
        for deviceId: String,
        session: ManualWriteSession,
        now: Date,
        continuousNow: ContinuousClock.Instant
    ) {
        var candidateFields: Set<OptimisticField> = Set(session.baseFieldLocks.keys)
        for patch in session.patches {
            candidateFields.formUnion(patch.fields)
        }
        for key in optimisticFieldLocks.keys where key.deviceId == deviceId {
            if let field = key.field {
                candidateFields.insert(field)
            }
        }
        for field in candidateFields {
            var bestEntry: OptimisticLockEntry?
            if let baseEntry = session.baseFieldLocks[field],
               isOptimisticEntryActive(baseEntry, at: now, continuousNow: continuousNow) {
                bestEntry = baseEntry
            }
            for patch in session.patches where patch.fields.contains(field) {
                if let entry = patch.lockEntry,
                   isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow) {
                    if let current = bestEntry {
                        if entry.until >= current.until {
                            bestEntry = OptimisticLockEntry(
                                until: entry.until,
                                untilInstant: entry.untilInstant,
                                revision: max(current.revision, entry.revision)
                            )
                        } else {
                            bestEntry = OptimisticLockEntry(
                                until: current.until,
                                untilInstant: current.untilInstant,
                                revision: max(current.revision, entry.revision)
                            )
                        }
                    } else {
                        bestEntry = entry
                    }
                }
            }
            if var bestEntry {
                let currentRev = optimisticFieldRevisions[.field(deviceId, field)] ?? 0
                bestEntry.revision = max(bestEntry.revision, currentRev)
                optimisticFieldLocks[.field(deviceId, field)] = bestEntry
                optimisticFieldRevisions[.field(deviceId, field)] = bestEntry.revision
            } else {
                optimisticFieldLocks.removeValue(forKey: .field(deviceId, field))
            }
        }
    }

    func clearManualWriteSession(for deviceId: String, bumpRevision: Bool = true) {
        let savedCoverOrigin = bumpRevision ? nil : coverCommandOrigins[deviceId]
        cancelDebouncedWrites(for: deviceId, recomputeRow: true)
        if !bumpRevision {
            if let savedCoverOrigin {
                coverCommandOrigins[deviceId] = savedCoverOrigin
            } else {
                coverCommandOrigins.removeValue(forKey: deviceId)
            }
        }
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

    func reconcileManualWriteSessionWithSnapshot(
        _ incoming: SmartDevice,
        local: SmartDevice? = nil,
        lockedFields: Set<OptimisticField> = []
    ) -> SmartDevice {
        guard var session = manualWriteSessions[incoming.id],
              optimisticLockRevision[incoming.id] == session.revision else {
            manualWriteSessions.removeValue(forKey: incoming.id)
            if !lockedFields.isEmpty, let local {
                return incoming.mergingOptimisticFields(from: local, lockedFields: lockedFields)
            }
            return incoming
        }
        session.patches.removeAll { patch in
            patch.phase == .succeeded && patch.fields.isDisjoint(with: lockedFields)
        }
        session.baseFieldLocks = session.baseFieldLocks.filter { field, _ in
            lockedFields.contains(field)
        }
        if !lockedFields.contains(.coverPosition) {
            session.baseCoverOrigin = nil
        }
        if session.patches.isEmpty {
            manualWriteSessions.removeValue(forKey: incoming.id)
            if !lockedFields.isEmpty, let local {
                return incoming.mergingOptimisticFields(from: local, lockedFields: lockedFields)
            }
            return incoming
        }
        let nextBase: SmartDevice
        if !session.baseFieldLocks.isEmpty, let local {
            nextBase = incoming.mergingOptimisticFields(
                from: local,
                lockedFields: Set(session.baseFieldLocks.keys)
            )
        } else {
            nextBase = incoming
        }
        session.base = nextBase
        manualWriteSessions[incoming.id] = session
        var composed = nextBase
        for patch in session.patches {
            if patch.phase == .succeeded {
                let activePatchFields = patch.fields.intersection(lockedFields)
                if !activePatchFields.isEmpty {
                    var scratched = composed
                    patch.apply(&scratched)
                    composed = composed.mergingOptimisticFields(from: scratched, lockedFields: activePatchFields)
                }
            } else {
                applyManualPatch(patch, to: &composed)
            }
        }
        return composed
    }

    private func foldExpiredSucceededPatches(
        in session: inout ManualWriteSession,
        now: Date,
        continuousNow: ContinuousClock.Instant
    ) {
        var remaining: [ManualWritePatch] = []
        remaining.reserveCapacity(session.patches.count)
        for patch in session.patches {
            let lockExpired = patch.lockEntry.map {
                !isOptimisticEntryActive($0, at: now, continuousNow: continuousNow)
            } ?? true
            if patch.phase == .succeeded, lockExpired {
                applyManualPatch(patch, to: &session.base)
            } else {
                remaining.append(patch)
            }
        }
        session.baseFieldLocks = session.baseFieldLocks.filter { _, entry in
            isOptimisticEntryActive(entry, at: now, continuousNow: continuousNow)
        }
        session.patches = remaining
    }

    private func finalizeOrApplyManualWriteSession(for deviceId: String) {
        guard var session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision else { return }
        let nowDate = optimisticNow()
        let continuousNow = ContinuousClock.now
        foldExpiredSucceededPatches(in: &session, now: nowDate, continuousNow: continuousNow)
        if session.patches.isEmpty {
            if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
                devices[idx] = session.base
                syncGenericPowerFacet(session.base)
            }
            manualWriteSessions.removeValue(forKey: deviceId)
            for key in optimisticFieldLocks.keys where key.deviceId == deviceId {
                optimisticFieldLocks.removeValue(forKey: key)
            }
            for (field, var baseEntry) in session.baseFieldLocks
            where isOptimisticEntryActive(baseEntry, at: nowDate, continuousNow: continuousNow) {
                let currentRev = optimisticFieldRevisions[.field(deviceId, field)] ?? 0
                baseEntry.revision = max(baseEntry.revision, currentRev)
                optimisticFieldLocks[.field(deviceId, field)] = baseEntry
                optimisticFieldRevisions[.field(deviceId, field)] = baseEntry.revision
            }
            if let priorOrigin = session.baseCoverOrigin {
                coverCommandOrigins[deviceId] = priorOrigin
            } else {
                coverCommandOrigins.removeValue(forKey: deviceId)
            }
        } else {
            manualWriteSessions[deviceId] = session
            applyManualWriteSession(for: deviceId, now: nowDate, continuousNow: continuousNow)
        }
    }

    private func applyManualWriteSession(
        for deviceId: String,
        now: Date? = nil,
        continuousNow: ContinuousClock.Instant = .now
    ) {
        guard let session = manualWriteSessions[deviceId],
              optimisticLockRevision[deviceId] == session.revision else { return }
        let nowDate = now ?? optimisticNow()
        if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
            var composed = session.base
            for patch in session.patches {
                applyManualPatch(patch, to: &composed)
            }
            devices[idx] = composed
            syncGenericPowerFacet(composed)
        }
        syncManualSessionFieldLocks(for: deviceId, session: session, now: nowDate, continuousNow: continuousNow)
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
        let nowDate = optimisticNow()
        let continuousNow = ContinuousClock.now
        session.patches[idx].phase = .inFlight
        if let lock {
            let rev = session.patches[idx].lockEntry?.revision ?? session.revision
            session.patches[idx].lockEntry = makeOptimisticEntry(duration: lock, revision: rev)
        }
        manualWriteSessions[deviceId] = session
        syncManualSessionFieldLocks(for: deviceId, session: session, now: nowDate, continuousNow: continuousNow)
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

    /// Shows `updated` now. With a `lock`, stale snapshots cannot overwrite its changed fields until
    /// the lock expires or the device reports the same state. Without one the row changes but an
    /// earlier lock (if any) stays in charge. Pass `updated: nil` to send without showing anything.
    func beginOptimisticWrite(
        from previous: SmartDevice,
        to updated: SmartDevice?,
        lock: Duration?,
        preserveManualDebounces: Bool = false
    ) -> OptimisticWrite {
        guard let updated, let idx = devices.firstIndex(where: { $0.id == previous.id }) else {
            return OptimisticWrite(deviceId: previous.id, previous: previous, revision: nil, isShown: false)
        }
        let rawChanged = OptimisticField.changedFields(from: previous, to: updated)
        var changed = rawChanged
        if lock != nil && changed.isEmpty {
            let defaults = OptimisticField.primaryPowerFields(for: updated.kind)
            changed = defaults.isEmpty ? [.power] : defaults
        }
        let hadPendingDebounces = !preserveManualDebounces
            && debouncedWrites.values.contains { $0.deviceId == previous.id }
        if !preserveManualDebounces {
            if hadPendingDebounces {
                cancelDebouncedWrites(for: previous.id, recomputeRow: true)
            }
            if lock != nil || hadPendingDebounces {
                manualWriteSessions.removeValue(forKey: previous.id)
            }
        }
        if let currentIdx = devices.firstIndex(where: { $0.id == previous.id }) {
            if hadPendingDebounces && !rawChanged.isEmpty {
                devices[currentIdx] = devices[currentIdx].mergingOptimisticFields(
                    from: updated,
                    lockedFields: rawChanged
                )
            } else {
                devices[currentIdx] = updated
            }
            syncGenericPowerFacet(devices[currentIdx])
        } else {
            devices[idx] = updated
            syncGenericPowerFacet(updated)
        }
        let revision: UInt64?
        let fieldRevisions: [OptimisticField: UInt64]
        if let lock {
            let locked = lockOptimistic(
                previous.id,
                fields: changed,
                duration: lock,
                preserveManualDebounces: true
            )
            revision = locked
            fieldRevisions = Dictionary(uniqueKeysWithValues: changed.map { ($0, locked) })
        } else if !changed.isEmpty {
            let bumped = (optimisticLockRevision[previous.id] ?? 0) &+ 1
            optimisticLockRevision[previous.id] = bumped
            for field in changed {
                optimisticFieldRevisions[.field(previous.id, field)] = bumped
            }
            revision = bumped
            fieldRevisions = Dictionary(uniqueKeysWithValues: changed.map { ($0, bumped) })
        } else {
            revision = optimisticLockRevision[previous.id]
            fieldRevisions = [:]
        }
        return OptimisticWrite(
            deviceId: previous.id,
            previous: previous,
            revision: revision,
            fields: changed,
            fieldRevisions: fieldRevisions,
            isShown: true
        )
    }

    private func ownedFields(for write: OptimisticWrite) -> Set<OptimisticField> {
        guard !write.fieldRevisions.isEmpty else { return [] }
        var owned: Set<OptimisticField> = []
        for (field, rev) in write.fieldRevisions where optimisticFieldRevisions[.field(write.deviceId, field)] == rev {
            owned.insert(field)
        }
        return owned
    }

    private func ownedFacetControlIds(for write: OptimisticWrite) -> Set<String> {
        guard !write.facetRevisions.isEmpty else { return [] }
        var owned: Set<String> = []
        for (controlId, rev) in write.facetRevisions
        where optimisticFacetRevisions[Self.facetLockKey(write.deviceId, controlId)] == rev {
            owned.insert(controlId)
        }
        return owned
    }

    /// True while no newer write has superseded any field or facet owned by `write`.
    func ownsRow(_ write: OptimisticWrite) -> Bool {
        if !write.fieldRevisions.isEmpty || !write.facetRevisions.isEmpty {
            return write.fieldRevisions.allSatisfy { field, rev in
                optimisticFieldRevisions[.field(write.deviceId, field)] == rev
            } && write.facetRevisions.allSatisfy { controlId, rev in
                optimisticFacetRevisions[Self.facetLockKey(write.deviceId, controlId)] == rev
            }
        }
        return optimisticLockRevision[write.deviceId] == write.revision
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

    /// Restores `restoring` (or still-owned fields from `write.previous`) when `write` still owns target fields/facets.
    func revert(_ write: OptimisticWrite, restoring: SmartDevice? = nil) {
        guard write.isShown else { return }
        if write.fieldRevisions.isEmpty && write.facetRevisions.isEmpty {
            guard optimisticLockRevision[write.deviceId] == write.revision else { return }
            if let idx = devices.firstIndex(where: { $0.id == write.deviceId }) {
                devices[idx] = restoring ?? write.previous
                syncGenericPowerFacet(devices[idx])
            }
            clearOptimisticLockEntries(for: write.deviceId)
            coverCommandOrigins.removeValue(forKey: write.deviceId)
            return
        }

        let stillOwnedFields = ownedFields(for: write)
        let stillOwnedFacets = ownedFacetControlIds(for: write)
        guard !stillOwnedFields.isEmpty || !stillOwnedFacets.isEmpty else { return }

        if let idx = devices.firstIndex(where: { $0.id == write.deviceId }) {
            if let restoring, ownsRow(write) {
                devices[idx] = restoring
            } else if !stillOwnedFields.isEmpty {
                devices[idx] = devices[idx].mergingOptimisticFields(
                    from: restoring ?? write.previous,
                    lockedFields: stillOwnedFields
                )
            }
            syncGenericPowerFacet(devices[idx])
        }

        for field in stillOwnedFields {
            if let expected = write.fieldRevisions[field],
               let entry = optimisticFieldLocks[.field(write.deviceId, field)],
               entry.revision != expected {
                continue
            }
            optimisticFieldLocks.removeValue(forKey: .field(write.deviceId, field))
        }
        for controlId in stillOwnedFacets {
            let key = Self.facetLockKey(write.deviceId, controlId)
            if let expected = write.facetRevisions[controlId],
               let entry = optimisticFacetLocks[key],
               entry.revision != expected {
                continue
            }
            optimisticFacetLocks.removeValue(forKey: key)
        }
        if stillOwnedFields.contains(.coverPosition) {
            coverCommandOrigins.removeValue(forKey: write.deviceId)
        }
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
        let nowDate = optimisticNow()
        let continuousNow = ContinuousClock.now
        let token = UUID()
        let slotKey = debounceKey ?? token.uuidString
        let applyPatch: @Sendable (inout SmartDevice) -> Void = mutate ?? { $0 = updated }
        var priorFieldLocks: [OptimisticField: OptimisticLockEntry] = [:]
        for (key, entry) in optimisticFieldLocks
        where key.deviceId == deviceId && isOptimisticEntryActive(entry, at: nowDate, continuousNow: continuousNow) {
            if let field = key.field {
                priorFieldLocks[field] = entry
            }
        }
        let slotOrigin = debounceKey.flatMap { debouncedWrites[$0]?.origin } ?? previous

        var session: ManualWriteSession
        if var existing = manualWriteSessions[deviceId],
           optimisticLockRevision[deviceId] == existing.revision {
            foldExpiredSucceededPatches(in: &existing, now: nowDate, continuousNow: continuousNow)
            if existing.patches.isEmpty {
                session = ManualWriteSession(
                    revision: 0,
                    base: slotOrigin,
                    baseCoverOrigin: priorCoverOrigin,
                    baseFieldLocks: existing.baseFieldLocks.merging(priorFieldLocks) { _, latest in latest },
                    patches: []
                )
            } else {
                session = existing
            }
        } else {
            session = ManualWriteSession(
                revision: 0,
                base: slotOrigin,
                baseCoverOrigin: priorCoverOrigin,
                baseFieldLocks: priorFieldLocks,
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

        var patchedFromOrigin = slotOrigin
        applyPatch(&patchedFromOrigin)
        var patchFields = OptimisticField.changedFields(from: slotOrigin, to: patchedFromOrigin)
            .union(OptimisticField.changedFields(from: previous, to: updated))
        if lock != nil && patchFields.isEmpty {
            let defaults = OptimisticField.primaryPowerFields(for: updated.kind)
            patchFields = defaults.isEmpty ? [.power] : defaults
        }

        let rev = (optimisticLockRevision[deviceId] ?? 0) &+ 1
        optimisticLockRevision[deviceId] = rev
        for field in patchFields {
            optimisticFieldRevisions[.field(deviceId, field)] = rev
        }
        let initialLockEntry = lock.map { makeOptimisticEntry(duration: $0, revision: rev) }
        let phase: ManualWritePatch.Phase = (debounceKey == nil) ? .inFlight : .debouncing
        session.patches.append(ManualWritePatch(
            slotKey: slotKey,
            token: token,
            phase: phase,
            fields: patchFields,
            lockEntry: initialLockEntry,
            apply: applyPatch
        ))

        session.revision = rev
        manualWriteSessions[deviceId] = session
        applyManualWriteSession(for: deviceId, now: nowDate, continuousNow: continuousNow)

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
