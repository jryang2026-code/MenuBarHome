import Foundation

/// A single field captured before a context rule writes it. Keeping the field explicit makes
/// manual takeover detection independent from the rest of a device's telemetry.
public enum AutomationContextField: String, Codable, Equatable, Sendable {
    case power
}

public struct AutomationContextValue: Codable, Equatable, Sendable {
    public let field: AutomationContextField
    public let boolValue: Bool?

    public init(field: AutomationContextField, boolValue: Bool) {
        self.field = field
        self.boolValue = boolValue
    }
}

public struct AutomationContextSnapshot: Codable, Equatable, Sendable {
    public let deviceID: String
    public let baseline: AutomationContextValue
    public let applied: AutomationContextValue

    public init(deviceID: String, baseline: AutomationContextValue, applied: AutomationContextValue) {
        self.deviceID = deviceID
        self.baseline = baseline
        self.applied = applied
    }
}

public struct AutomationContextFrame: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let enteredAt: Date
    public let snapshots: [AutomationContextSnapshot]

    public init(ruleID: UUID, enteredAt: Date, snapshots: [AutomationContextSnapshot]) {
        self.ruleID = ruleID
        self.enteredAt = enteredAt
        self.snapshots = snapshots
    }
}

public struct AutomationContextRestorePlan: Equatable, Sendable {
    public let frame: AutomationContextFrame
    public let intents: [DeviceIntent]

    public init(frame: AutomationContextFrame, intents: [DeviceIntent]) {
        self.frame = frame
        self.intents = intents
    }
}

/// Persistent LIFO state for context automations. The stack stores only fields changed by the
/// action, so a restore cannot clobber unrelated device state. Expired frames are discarded on
/// load without issuing writes.
public final class AutomationContextStack {
    public static let storageKey = "automation_context_stack_v1"
    public static let maximumFrames = 32
    public static let maximumAge: TimeInterval = 12 * 60 * 60

    private let defaults: UserDefaults?
    private var frames: [AutomationContextFrame]

    public init(defaults: UserDefaults? = nil, now: Date = Date()) {
        self.defaults = defaults
        if let defaults,
           let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([AutomationContextFrame].self, from: data) {
            self.frames = decoded.filter { now.timeIntervalSince($0.enteredAt) <= Self.maximumAge }
                .prefix(Self.maximumFrames).map { $0 }
        } else {
            self.frames = []
        }
        persist()
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }
    public var allFrames: [AutomationContextFrame] { frames }

    @discardableResult
    public func push(ruleID: UUID, snapshots: [AutomationContextSnapshot], at now: Date = Date()) -> AutomationContextFrame? {
        guard !snapshots.isEmpty else { return nil }
        let frame = AutomationContextFrame(ruleID: ruleID, enteredAt: now, snapshots: snapshots)
        frames.append(frame)
        if frames.count > Self.maximumFrames { frames.removeFirst(frames.count - Self.maximumFrames) }
        persist()
        return frame
    }

    /// Pops the newest frame for a rule and returns only fields whose live value still equals the
    /// value written on enter. A manual write or a newer context therefore wins.
    @discardableResult
    public func pop(ruleID: UUID, liveValues: [String: AutomationContextValue], at now: Date = Date()) -> [DeviceIntent] {
        guard let frame = frames.last(where: { $0.ruleID == ruleID }),
              let plan = prepareRestore(frame: frame, liveValues: liveValues, at: now) else { return [] }
        commitRestore(plan, restoredDeviceIDs: Set(plan.intents.map(\.targetId)))
        return plan.intents
    }

    public func prepareRestore(
        frame: AutomationContextFrame,
        liveValues: [String: AutomationContextValue],
        at now: Date = Date()
    ) -> AutomationContextRestorePlan? {
        pruneExpired(at: now)
        guard let index = frames.firstIndex(where: {
            $0.ruleID == frame.ruleID && $0.enteredAt == frame.enteredAt
        }) else { return nil }
        let retained = frame.snapshots.filter { snapshot in
            guard let live = liveValues[snapshot.deviceID] else { return true }
            return live == snapshot.applied
        }
        let eligible = retained.compactMap { snapshot -> (AutomationContextSnapshot, DeviceIntent)? in
            guard let live = liveValues[snapshot.deviceID], live == snapshot.applied,
                  snapshot.baseline.field == .power, let value = snapshot.baseline.boolValue else { return nil }
            return (snapshot, DeviceIntent(targetId: snapshot.deviceID, operation: .power(value)))
        }
        guard !retained.isEmpty else {
            frames.remove(at: index)
            persist()
            return nil
        }
        let updated = AutomationContextFrame(ruleID: frame.ruleID, enteredAt: frame.enteredAt, snapshots: retained)
        frames[index] = updated
        persist()
        guard !eligible.isEmpty else { return nil }
        return AutomationContextRestorePlan(
            frame: AutomationContextFrame(
                ruleID: updated.ruleID,
                enteredAt: updated.enteredAt,
                snapshots: eligible.map(\.0)
            ),
            intents: eligible.map(\.1)
        )
    }

    public func commitRestore(_ plan: AutomationContextRestorePlan, restoredDeviceIDs: Set<String>) {
        guard let index = frames.firstIndex(where: {
            $0.ruleID == plan.frame.ruleID && $0.enteredAt == plan.frame.enteredAt
        }) else { return }
        let remaining = frames[index].snapshots.filter { !restoredDeviceIDs.contains($0.deviceID) }
        if remaining.isEmpty {
            frames.remove(at: index)
        } else {
            frames[index] = AutomationContextFrame(
                ruleID: frames[index].ruleID,
                enteredAt: frames[index].enteredAt,
                snapshots: remaining
            )
        }
        persist()
    }

    public func pruneExpired(at now: Date = Date()) {
        let remaining = frames.filter { now.timeIntervalSince($0.enteredAt) <= Self.maximumAge }
        guard remaining.count != frames.count else { return }
        frames = remaining
        persist()
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(frames) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

public extension SmartDevice {
    /// Current value used by the context stack for the fields supported by automation actions.
    func automationContextValue(for field: AutomationContextField = .power) -> AutomationContextValue? {
        guard field == .power else { return nil }
        return AutomationContextValue(field: .power, boolValue: isActiveOn)
    }
}
