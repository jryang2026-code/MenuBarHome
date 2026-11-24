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
        pruneExpired(at: now)
        guard let index = frames.lastIndex(where: { $0.ruleID == ruleID }) else { return [] }
        let frame = frames.remove(at: index)
        persist()
        return frame.snapshots.compactMap { snapshot in
            guard let live = liveValues[snapshot.deviceID], live == snapshot.applied,
                  snapshot.baseline.field == .power, let value = snapshot.baseline.boolValue else { return nil }
            return DeviceIntent(targetId: snapshot.deviceID, operation: .power(value))
        }
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
