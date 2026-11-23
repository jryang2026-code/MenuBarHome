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
    /// True when the user's Focus filter asked for silence and this category is allowed to honour it.
    /// Callers skip posting a suppressed notification instead of posting a quiet one.
    public let isSuppressed: Bool

    public init(
        interruptionLevel: NotificationInterruptionLevel,
        relevanceScore: Double,
        isSuppressed: Bool = false
    ) {
        self.interruptionLevel = interruptionLevel
        self.relevanceScore = relevanceScore
        self.isSuppressed = isSuppressed
    }

    public static func resolve(
        for category: NotificationCategory,
        isFocusActive: Bool,
        focusFilter: FocusFilterProfile = .inactive
    ) -> Self {
        let ordinaryLevel: NotificationInterruptionLevel = isFocusActive ? .passive : .active
        // A Focus filter may only quieten ordinary notifications. Safety alerts and the doorbell
        // return a policy without `isSuppressed`, so no profile value can silence them.
        let suppressed = focusFilter.suppressesNonSafetyNotifications(isFocusActive: isFocusActive)
        switch category {
        case .safetyAlert(let alert):
            // A safety alert is never dropped, whatever the severity: the sensor severity table
            // decides only how loud it stays. Contact, motion, battery and offline alerts become
            // passive in Focus like before, they are never silenced by a filter.
            guard alert.severity == .alert else {
                return Self(interruptionLevel: ordinaryLevel, relevanceScore: 1)
            }
            return Self(interruptionLevel: .timeSensitive, relevanceScore: 1)
        case .missedTimer:
            return Self(interruptionLevel: ordinaryLevel, relevanceScore: 0.7, isSuppressed: suppressed)
        case .externalAction:
            return Self(interruptionLevel: ordinaryLevel, relevanceScore: 0.3, isSuppressed: suppressed)
        case .weeklyHealthReport:
            return Self(interruptionLevel: .passive, relevanceScore: 0, isSuppressed: suppressed)
        case .doorbell:
            // The press lasts a second and the visitor is still there, so it keeps its priority in
            // Focus like the hazard alerts; it still ranks below an alarm.
            return Self(interruptionLevel: .timeSensitive, relevanceScore: 0.9)
        }
    }
}
