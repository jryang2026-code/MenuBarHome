import Foundation

/// One row of the panel's activity stack: a system notice, a recorded safety alert or a doorbell
/// press. A pure value so the order, the ids and the dismiss rules are testable without a view
/// (control-center spec §2.4).
public struct PanelActivity: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notice(PanelNoticeSlot.Kind)
        case safety(RecordedSafetyAlert)
        case doorbell(DoorbellRing)
    }

    /// Stable per activity: a notice by its kind, a safety alert by `SafetyAlert.id`, a doorbell
    /// press by `DoorbellRing.key`.
    public let id: String
    public let kind: Kind
    /// When the activity happened: the recorded alert time, the press time HA reported, or the
    /// expiry a warning announces. A notice about a connection state has no time of its own.
    public let date: Date?
    /// 米家 expired and the plaintext-token decision wait for the user, so clearing them would only
    /// hide the one exit. Every other row can be cleared.
    public var isDismissible: Bool
}

/// A safety alert as the stack knows it: the notification's payload, the home it fired in, and when.
/// The same `alert.id` is one row however often the alert is recorded.
public struct RecordedSafetyAlert: Identifiable, Equatable, Sendable {
    public let alert: SafetyAlert
    /// `HomeStore.connectionScopeIdentifier` at the time of the alert. A notification's 立即关闭 names
    /// an entity of that home, so an alert recorded somewhere else is not this home's row.
    public let scope: String?
    public let date: Date

    public var id: String { alert.id }

    public init(alert: SafetyAlert, scope: String?, date: Date) {
        self.alert = alert
        self.scope = scope
        self.date = date
    }
}

public enum PanelActivityFeed {
    /// The stack in draw order: notices in `PanelNotice.kinds` order, then safety alerts newest
    /// first, then doorbell presses newest first. `dismissedIds` hides a row only when the row is
    /// dismissible; 米家 blocked and the plaintext decision ignore it.
    public static func items(
        notices: [PanelNoticeSlot.Kind],
        safety: [RecordedSafetyAlert],
        doorbells: [DoorbellRing],
        dismissedIds: Set<String>
    ) -> [PanelActivity] {
        var activities = notices.map { kind in
            PanelActivity(
                id: kind.activityID,
                kind: .notice(kind),
                date: kind.announcedDate,
                isDismissible: kind.isDismissible
            )
        }
        activities += safety
            .sorted { left, right in
                left.date == right.date ? left.id < right.id : left.date > right.date
            }
            .map { recorded in
                PanelActivity(
                    id: recorded.id,
                    kind: .safety(recorded),
                    date: recorded.date,
                    isDismissible: true
                )
            }
        activities += doorbells
            .map { (ring: $0, date: pressDate($0.firedAt)) }
            .sorted { left, right in
                switch (left.date, right.date) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.ring.key < right.ring.key
                }
            }
            .map { pair in
                PanelActivity(
                    id: pair.ring.key,
                    kind: .doorbell(pair.ring),
                    date: pair.date,
                    isDismissible: true
                )
            }
        return activities.filter { $0.isDismissible ? !dismissedIds.contains($0.id) : true }
    }

    /// HA reports an event entity's press time as ISO 8601 text and `unknown` when it never fired;
    /// anything unreadable has no time to show and sorts behind the presses that do.
    static func pressDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: Self.pressTimeWithFraction) { return date }
        return try? Date(raw, strategy: Self.pressTime)
    }

    /// Value-type strategies: the feed runs on every panel refresh, so a card must not allocate a
    /// formatter. HA sends `…T08:00:00.000+00:00`, or no fraction on an older core.
    private static let pressTimeWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let pressTime = Date.ISO8601FormatStyle()
}
