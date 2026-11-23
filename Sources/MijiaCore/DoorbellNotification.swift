import Foundation

/// The macOS notification for one doorbell press (#10).
///
/// Built from the same `DoorbellRing` the activity feed and the popup use, so one physical press
/// produces one notification: the request identifier is derived from `DoorbellRing.key`, which is
/// also the store's dedupe key. A repeat of a press that was already shown replaces the banner
/// instead of adding a second one.
public struct DoorbellNotification: Equatable, Sendable {
    public static let identifierPrefix = "doorbell:"

    public let ring: DoorbellRing
    /// The card's name at delivery time; nil when the card has left the home.
    public let deviceName: String?
    public let title: String
    public let body: String

    /// One identifier per press, shared with the store's dedupe key.
    public var identifier: String { Self.identifierPrefix + ring.key }
    /// The camera card the tap should open.
    public var deviceId: String { ring.deviceId }

    /// The ring time comes from the source's own timestamp, so a press buffered during a
    /// reconnect still says when it happened. An unparsable state text falls back to `now`.
    public init(
        ring: DoorbellRing,
        deviceName: String?,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) {
        self.ring = ring
        self.deviceName = deviceName
        let name = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = name.isEmpty
            ? L10n.tr("门铃响了", "Doorbell rang")
            : L10n.tr("门铃：\(name)", "Doorbell: \(name)")
        let time = Self.timeText(ring.firedAtDate ?? now, locale: locale, timeZone: timeZone)
        self.body = L10n.tr(
            "\(time) 按下门铃。点击查看实时画面。",
            "Rang at \(time). Click to view the live camera."
        )
    }

    static func timeText(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
