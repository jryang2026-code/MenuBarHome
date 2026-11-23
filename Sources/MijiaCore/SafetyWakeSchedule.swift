import Foundation

public enum SafetyWakeEvent: Sendable, CaseIterable {
    case systemWake, screenUnlocked, clockChanged, timeZoneChanged
}

public func nextSafetyWake(
    now: Date, alertCheck: Date?, weeklyReport: Date?, updateCheck: Date?, event: SafetyWakeEvent? = nil
) -> Date? {
    if event != nil { return now }
    return [alertCheck, weeklyReport, updateCheck].compactMap { $0 }.min().map { max(now, $0) }
}

extension SafetyWakeEvent {
    func rearmedCommandDelay(now: Date, fireDate: Date) -> TimeInterval? {
        switch self {
        case .clockChanged:
            return max(0, fireDate.timeIntervalSince(now))
        case .systemWake, .screenUnlocked, .timeZoneChanged:
            return fireDate <= now ? 0 : nil
        }
    }
}

func scheduledCommandIsMissed(now: Date, fireDate: Date) -> Bool {
    now.timeIntervalSince(fireDate) > HomeStore.lateTimerGrace
}
