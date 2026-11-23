public enum NotificationCategory: Sendable {
    case safetyAlert(SafetyAlert)
    case missedTimer
    case externalAction
    case weeklyHealthReport
    /// A doorbell press (#10): somebody is at the door right now.
    case doorbell
}

public enum NotificationInterruptionLevel: Equatable, Sendable {
    case passive
    case active
    case timeSensitive
}

public struct NotificationDeliveryPolicy: Equatable, Sendable {
    public let interruptionLevel: NotificationInterruptionLevel
    public let relevanceScore: Double

    public static func resolve(
        for category: NotificationCategory,
        isFocusActive: Bool
    ) -> Self {
        let ordinaryLevel: NotificationInterruptionLevel = isFocusActive ? .passive : .active
        switch category {
        case .safetyAlert(let alert):
            let kind = SensorAlertKind.parse(fromAlertId: alert.id)
            let level: NotificationInterruptionLevel = kind?.honorsAwayLimit == false
                ? .timeSensitive
                : ordinaryLevel
            return Self(interruptionLevel: level, relevanceScore: 1)
        case .missedTimer:
            return Self(interruptionLevel: ordinaryLevel, relevanceScore: 0.7)
        case .externalAction:
            return Self(interruptionLevel: ordinaryLevel, relevanceScore: 0.3)
        case .weeklyHealthReport:
            return Self(interruptionLevel: .passive, relevanceScore: 0)
        case .doorbell:
            // The press lasts a second and the visitor is still there, so it keeps its priority in
            // Focus like the hazard alerts; it still ranks below an alarm.
            return Self(interruptionLevel: .timeSensitive, relevanceScore: 0.9)
        }
    }
}
