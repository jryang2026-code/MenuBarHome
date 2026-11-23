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
        // A Focus filter may only quieten ordinary notifications. `neverSuppressed` is checked per
        // category below, so no profile value can silence a hazard or the doorbell.
        let suppressed = focusFilter.suppressesNonSafetyNotifications(isFocusActive: isFocusActive)
        switch category {
        case .safetyAlert(let alert):
            // The sensor severity table is the only place that decides which alerts stay loud in
            // Focus; non-sensor safety alerts (battery, offline, long-run) keep the ordinary level.
            guard alert.severity == .alert else {
                return Self(
                    interruptionLevel: ordinaryLevel,
                    relevanceScore: 1,
                    isSuppressed: suppressed
                )
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
