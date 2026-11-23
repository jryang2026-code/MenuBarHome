import Foundation

/// What the user is doing right now. Mi cloud polls slower or stops based on it (#26).
public struct PollingContext: Equatable, Sendable, CustomStringConvertible {
    /// The control center panel is on screen.
    public var panelVisible: Bool
    /// False while the Mac or its display sleeps, the screen is locked, or another user is logged in.
    public var systemActive: Bool
    /// macOS Low Power Mode is on.
    public var lowPower: Bool
    /// When the user last touched the panel: opening it, closing it, or running a control from it
    /// while it was closed. `nil` means "not tracked", which keeps the closed-panel interval flat.
    public var lastPanelInteractionAt: Date?
    /// An enabled safety alert reads its sensor through this poll (ADR-0023 §4). A closed panel then
    /// keeps 60 s no matter how long the user has been away: a leak or a smoke reading that arrives
    /// four minutes late is a missed alert, not a staler number.
    public var safetyAlertsRelyOnPolling: Bool
    /// The menu-bar label renders a polled reading (temperature, watts, active count). Stretching the
    /// interval would make the label the user keeps on screen show a 2–5 minute old number.
    public var menuBarShowsLiveReading: Bool

    public init(
        panelVisible: Bool = false,
        systemActive: Bool = true,
        lowPower: Bool = false,
        lastPanelInteractionAt: Date? = nil,
        safetyAlertsRelyOnPolling: Bool = true,
        menuBarShowsLiveReading: Bool = true
    ) {
        self.panelVisible = panelVisible
        self.systemActive = systemActive
        self.lowPower = lowPower
        self.lastPanelInteractionAt = lastPanelInteractionAt
        self.safetyAlertsRelyOnPolling = safetyAlertsRelyOnPolling
        self.menuBarShowsLiveReading = menuBarShowsLiveReading
    }

    public var description: String {
        if !systemActive { return "paused (asleep or locked)" }
        return (panelVisible ? "panel open" : "panel closed") + (lowPower ? ", low power" : "")
    }
}

/// How often to poll for device state (#26).
///
/// | Situation | Interval |
/// | --- | --- |
/// | Panel open | 6 s |
/// | Panel closed (menu bar text, reminders) | 60 s |
/// | Panel closed, 30 min since the last touch | 120 s |
/// | Panel closed, 2 h since the last touch | 300 s |
/// | Panel closed in Low Power Mode | 180 s, or the idle step when that one is longer |
/// | Asleep, display asleep, locked | no polling; polls once right after |
///
/// The idle steps apply only while nothing polled is still on screen: see
/// `PollingContext.safetyAlertsRelyOnPolling` and `PollingContext.menuBarShowsLiveReading`.
/// Windows mirrors this table in `windows/src/core/pollingPolicy.ts`.
public enum PollingPolicy {
    public static let panelOpenInterval: Duration = .seconds(6)
    public static let panelClosedInterval: Duration = .seconds(60)
    /// Nobody has touched a closed panel for this long, so 60 s becomes `idleInterval`.
    public static let idleThreshold: Duration = .seconds(30 * 60)
    public static let idleInterval: Duration = .seconds(120)
    /// Two hours of no interaction; the last step before polling is purely for freshness.
    public static let longIdleThreshold: Duration = .seconds(2 * 60 * 60)
    public static let longIdleInterval: Duration = .seconds(300)
    /// Low Power Mode stretches the panel-closed interval by this factor. An open panel keeps 6 s:
    /// someone is looking, and it is open only briefly.
    public static let lowPowerFactor = 3

    /// - Parameter now: injected so the table is a pure function of its inputs (tests, replay).
    /// - Returns: the wait between polls, or nil to stop polling until the context changes.
    public static func interval(
        for context: PollingContext,
        now: Date = Date(),
        panelOpen: Duration = panelOpenInterval,
        panelClosed: Duration = panelClosedInterval
    ) -> Duration? {
        guard context.systemActive else { return nil }
        if context.panelVisible { return panelOpen }
        let lowPowerInterval = context.lowPower ? panelClosed * lowPowerFactor : panelClosed
        // Low Power Mode scales the configured interval; the idle step is an absolute floor taken on
        // top of it. The longer of the two wins, and they never multiply into 360 s / 900 s.
        return max(lowPowerInterval, stretchedInterval(for: context, now: now, panelClosed: panelClosed))
    }

    /// The closed-panel interval after idle stretching, before Low Power Mode.
    private static func stretchedInterval(
        for context: PollingContext,
        now: Date,
        panelClosed: Duration
    ) -> Duration {
        guard !context.safetyAlertsRelyOnPolling, !context.menuBarShowsLiveReading,
              let lastInteraction = context.lastPanelInteractionAt else { return panelClosed }
        let idle = Duration.seconds(now.timeIntervalSince(lastInteraction))
        if idle >= longIdleThreshold { return longIdleInterval }
        if idle >= idleThreshold { return idleInterval }
        return panelClosed
    }
}
