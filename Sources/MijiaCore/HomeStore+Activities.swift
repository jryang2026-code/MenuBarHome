import Foundation

// The panel's activity stack: system notices, recorded safety alerts and doorbell presses in one
// list (§2 of the control-center redesign). Undo and toasts are not activities; they stay on
// `undoBanner` / `toastNotice` for the transient banner stack.
extension HomeStore {
    /// How many safety alerts the stack keeps. Ten is more than the collapsed stack ever unfolds.
    public static let recentSafetyAlertLimit = 10

    /// Every activity the panel shows, in draw order. An alert or a ring whose card has left the
    /// home, or an alert recorded in another home, is not this home's activity and stays out.
    public var panelActivities: [PanelActivity] {
        let scope = connectionScopeIdentifier
        let presentDeviceIds = Set(devices.map(\.id))
        return PanelActivityFeed.items(
            notices: panelNoticeKinds,
            safety: recentSafetyAlerts.filter { recorded in
                recorded.scope == scope && presentDeviceIds.contains(recorded.alert.deviceId)
            },
            doorbells: recentDoorbellRings.filter { presentDeviceIds.contains($0.deviceId) },
            dismissedIds: dismissedActivityIds
        )
    }

    /// Ends one row. The address suggestion is dismissed at the source, where the URL is remembered
    /// as declined; every other row is only hidden for this session. The two notices the user still
    /// has to answer are refused here as well as by the feed.
    public func dismissActivity(_ activity: PanelActivity) {
        guard activity.isDismissible else { return }
        if case .notice(.haAddress(let instance)) = activity.kind {
            // A swipe may finish after discovery has replaced the card's address (§13).
            guard pendingHAAddressSuggestion == instance else { return }
            dismissHAAddressSuggestion()
            return
        }
        if case .notice(.haPlaintext(let prompt)) = activity.kind,
           haPlaintextPrompt != prompt { return }
        if case .safety(let recorded) = activity.kind {
            // An exit animation owns this occurrence, not a later alert reusing its id.
            guard recentSafetyAlerts.contains(where: { $0.id == recorded.id && $0.date == recorded.date }) else { return }
        }
        dismissedActivityIds.insert(activity.id)
    }

    /// The × in the stack header: every row the user is allowed to clear, and nothing else.
    public func clearDismissibleActivities() {
        for activity in panelActivities where activity.isDismissible {
            dismissActivity(activity)
        }
    }

    /// Records alerts raised by `evaluateSafetyAlerts(now:)`. A repeated id keeps one row with the
    /// newest time, and the list stops at `recentSafetyAlertLimit`.
    func recordSafetyAlerts(_ alerts: [SafetyAlert], now: Date = Date()) {
        guard !alerts.isEmpty else { return }
        let scope = connectionScopeIdentifier
        var next = recentSafetyAlerts
        for alert in alerts {
            dismissedActivityIds.remove(alert.id)
            next.removeAll { $0.id == alert.id }
            next.insert(RecordedSafetyAlert(alert: alert, scope: scope, date: now), at: 0)
        }
        if next.count > Self.recentSafetyAlertLimit {
            next.removeLast(next.count - Self.recentSafetyAlertLimit)
        }
        if next != recentSafetyAlerts { recentSafetyAlerts = next }
    }

    /// Snapshot removal ends the record, so reconnecting a device cannot revive an old warning.
    func removeActivitiesForMissingDevices() {
        let presentIds = Set(devices.map(\.id))
        recentSafetyAlerts.removeAll { recorded in
            guard !presentIds.contains(recorded.alert.deviceId) else { return false }
            dismissedActivityIds.remove(recorded.id)
            return true
        }
    }
}
