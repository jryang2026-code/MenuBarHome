import Foundation
import Testing
@testable import MijiaCore

extension SmartDevice {
    var coverSpec: CoverSpec? {
        guard case .cover(let spec) = kind else { return nil }
        return spec
    }
}

extension HomeStore {
    func waitForTestSnapshot() async throws {
        try await waitForInitialSnapshot(timeout: .seconds(30))
    }

    @discardableResult
    func runLocalCommand(_ text: String) async -> IntentPlan? {
        let previous = localAssistantAvailabilityOverride
        localAssistantAvailabilityOverride = .unavailable("local parser only")
        defer { localAssistantAvailabilityOverride = previous }
        return await runAssistantCommand(text)
    }

    func extendCoverLock(_ deviceId: String) throws {
        let existing = try #require(
            optimisticLockUntil[deviceId],
            "the command must have armed the optimistic lock before the test extends it"
        )
        optimisticLockUntil[deviceId] = max(existing, ContinuousClock.now.advanced(by: .seconds(600)))
    }

    func waitForCoverSnapshot(after generation: UInt64) async {
        await waitUntil(timeout: .seconds(30)) { snapshotGeneration > generation }
    }

    func settleCoverCommand(_ deviceId: String, after generation: UInt64) async throws {
        try extendCoverLock(deviceId)
        await waitForCoverSnapshot(after: generation)
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

    var optimisticLockUntil: [String: ContinuousClock.Instant] {
        get {
            var maxInstantByDevice: [String: ContinuousClock.Instant] = [:]
            for (key, entry) in optimisticFieldLocks {
                let instant = entry.untilInstant ?? continuousInstant(from: entry.until)
                if let current = maxInstantByDevice[key.deviceId], current >= instant { continue }
                maxInstantByDevice[key.deviceId] = instant
            }
            for (facetKey, entry) in optimisticFacetLocks {
                guard let deviceId = Self.deviceId(fromFacetWriteKey: facetKey) else { continue }
                let instant = entry.untilInstant ?? continuousInstant(from: entry.until)
                if let current = maxInstantByDevice[deviceId], current >= instant { continue }
                maxInstantByDevice[deviceId] = instant
            }
            return maxInstantByDevice
        }
        set {
            let currentDates = optimisticLockMaxDatesByDevice()
            let currentInstants = optimisticLockMaxInstantsByDevice()
            for (deviceId, oldMaxDate) in currentDates {
                guard let updatedInstant = newValue[deviceId] else {
                    clearOptimisticLockEntries(for: deviceId)
                    continue
                }
                if let oldMaxInstant = currentInstants[deviceId], oldMaxInstant == updatedInstant {
                    continue
                }
                let updatedDate = date(from: updatedInstant)
                if currentInstants[deviceId] == nil && abs(updatedDate.timeIntervalSince(oldMaxDate)) <= 1e-6 {
                    continue
                }
                setOptimisticLockExpiration(updatedDate, untilInstant: updatedInstant, for: deviceId)
            }
            for (deviceId, instant) in newValue where currentDates[deviceId] == nil {
                let rev = optimisticLockRevision[deviceId] ?? 1
                let fields: Set<OptimisticField>
                if let kind = devices.first(where: { $0.id == deviceId })?.kind {
                    let defaults = OptimisticField.primaryPowerFields(for: kind)
                    fields = defaults.isEmpty ? [.power] : defaults
                } else {
                    fields = [.power]
                }
                let until = date(from: instant)
                for field in fields {
                    optimisticFieldLocks[.field(deviceId, field)] = OptimisticLockEntry(
                        until: until,
                        untilInstant: hasCustomOptimisticNow ? nil : instant,
                        revision: rev
                    )
                }
            }
        }
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(30),
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return }
    Issue.record(
        "condition was not met before \(timeout)",
        sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
}
