/// The two levels every alert surface agrees on (deep-dive R16 §1.5): an `alert` is a life-safety
/// hazard and draws and notifies above a `warning`, which only asks for attention.
public enum AlertSeverity: String, CaseIterable, Hashable, Sendable {
    case alert
    case warning

    /// The single kind-to-severity table. Windows (`alertSeverity.ts`) mirrors it, and both ends
    /// read `Tests/Fixtures/alert_severity_golden.json`.
    public init(sensorAlertKind: SensorAlertKind) {
        switch sensorAlertKind {
        case .leak, .smoke, .gas:
            self = .alert
        case .contact, .motion:
            self = .warning
        }
    }

    /// `alert` sorts before `warning` where the activity stack orders rows.
    public var sortRank: Int {
        switch self {
        case .alert: 0
        case .warning: 1
        }
    }
}

extension SensorAlertKind {
    public var severity: AlertSeverity { AlertSeverity(sensorAlertKind: self) }
}

extension SafetyAlert {
    /// `nil` for alerts outside the sensor table (battery, offline, long-run), which keep their own
    /// priority instead of pretending to be a warning.
    public var severity: AlertSeverity? {
        SensorAlertKind.parse(fromAlertId: id)?.severity
    }
}
