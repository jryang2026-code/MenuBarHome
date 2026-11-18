import Foundation

/// One press of a doorbell, from a Home Assistant `event` entity with `device_class: doorbell` (#308).
/// HA sets the entity's state to the event timestamp on every press.
public struct DoorbellRing: Equatable, Sendable {
    /// The card that owns the doorbell: the source-native device id, translated to the merged
    /// card id in dual-source mode (both sides, #23).
    public var deviceId: String
    public var entityId: String
    public var firedAt: String

    public init(deviceId: String, entityId: String, firedAt: String) {
        self.deviceId = deviceId
        self.entityId = entityId
        self.firedAt = firedAt
    }

    /// Identifies this press; the same press is handled at most once.
    public var key: String { "\(entityId)@\(firedAt)" }

    /// The press time, parsed from either source's ISO-8601 shape, or nil when the state text is
    /// not a timestamp. HA writes milliseconds (or whole seconds, or Python's microseconds); the
    /// Mi cloud writes milliseconds. Used to pair the two sources' reports of one press (#23).
    var firedAtDate: Date? {
        let text = firedAt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "unknown", text != "unavailable" else { return nil }
        Self.dateFormatterLock.lock()
        defer { Self.dateFormatterLock.unlock() }
        if let date = Self.fractionalFormatter.date(from: text) { return date }
        return Self.wholeSecondFormatter.date(from: text)
    }

    private static let dateFormatterLock = NSLock()
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSecondFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    /// The press timestamp a doorbell event entity reports, or nil for `unknown`/`unavailable`.
    static func timestamp(_ state: HAEntityState) -> String? {
        guard isDoorbellEvent(state), !["unknown", "unavailable", ""].contains(state.state) else { return nil }
        return state.state
    }

    static func isDoorbellEvent(_ state: HAEntityState) -> Bool {
        state.entityId.hasPrefix("event.") && state.attributes["device_class"]?.stringValue == "doorbell"
    }
}

/// What the app does for one press after the user's settings and the lock screen are applied.
public struct DoorbellResponse: Equatable, Sendable {
    /// The camera card to open, or nil when only the chime should play.
    public var cameraDeviceId: String?
    public var playsChime: Bool
    public var dismissAfter: Duration
}
