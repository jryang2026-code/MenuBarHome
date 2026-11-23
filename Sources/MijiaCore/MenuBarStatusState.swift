import Foundation

/// Small semantic badge rendered alongside the menu-bar icon.
public enum MenuBarIconBadge: Equatable, Sendable {
    case none
    /// Offline, stale, or auth/permission issue requiring user attention (subtle template dot).
    case attention
    /// Active life-safety hazard (leak/smoke/gas); keeps the existing high-contrast red treatment.
    case safetyAlert
}

/// Pure inputs needed to derive the menu-bar icon and badge from store + speech state.
public struct MenuBarIconStateInput: Equatable, Sendable {
    public var isListening: Bool
    public var miSessionBlocksControl: Bool
    public var activeDeviceCount: Int
    public var hasSafetyAlert: Bool
    public var panelHealth: PanelHealth

    public init(
        isListening: Bool = false,
        miSessionBlocksControl: Bool = false,
        activeDeviceCount: Int = 0,
        hasSafetyAlert: Bool = false,
        panelHealth: PanelHealth = .ok
    ) {
        self.isListening = isListening
        self.miSessionBlocksControl = miSessionBlocksControl
        self.activeDeviceCount = activeDeviceCount
        self.hasSafetyAlert = hasSafetyAlert
        self.panelHealth = panelHealth
    }
}

/// Single source of truth for the macOS menu-bar icon symbol, badge, and template rendering mode.
public struct MenuBarIconState: Equatable, Sendable {
    public var symbolName: String
    public var badge: MenuBarIconBadge

    public init(symbolName: String, badge: MenuBarIconBadge) {
        self.symbolName = symbolName
        self.badge = badge
    }

    /// True when the icon should render as a macOS template image so it adapts automatically to
    /// light, dark, and tinted menu bars. Only active safety alerts opt out to paint red.
    public var usesTemplateRendering: Bool {
        badge != .safetyAlert
    }

    public static func resolve(_ input: MenuBarIconStateInput) -> MenuBarIconState {
        let symbolName: String
        if input.isListening {
            symbolName = "waveform"
        } else if input.miSessionBlocksControl {
            symbolName = "house.slash"
        } else if input.activeDeviceCount > 0 {
            symbolName = "house.fill"
        } else {
            symbolName = "house"
        }

        let badge: MenuBarIconBadge
        if input.hasSafetyAlert {
            badge = .safetyAlert
        } else if input.miSessionBlocksControl || Self.healthNeedsAttention(input.panelHealth) {
            badge = .attention
        } else {
            badge = .none
        }

        return MenuBarIconState(symbolName: symbolName, badge: badge)
    }

    private static func healthNeedsAttention(_ health: PanelHealth) -> Bool {
        switch health {
        case .degraded, .blocked:
            return true
        case .ok, .connecting, .notConfigured:
            return false
        }
    }
}

/// Hysteresis state for stabilizing `NSStatusItem.length` so readout updates do not jitter adjacent
/// menu-bar icons.
public struct MenuBarWidthState: Equatable, Sendable {
    /// Reserved status-item width in points, or `nil` when icon-only (`NSStatusItem.variableLength`).
    public var reservedWidth: Double?
    /// Character count of the label that established `reservedWidth`.
    public var anchorCharCount: Int
    /// Number of consecutive shrink-eligible updates observed since the last width change.
    public var pendingShrinkCount: Int

    public init(
        reservedWidth: Double? = nil,
        anchorCharCount: Int = 0,
        pendingShrinkCount: Int = 0
    ) {
        self.reservedWidth = reservedWidth
        self.anchorCharCount = anchorCharCount
        self.pendingShrinkCount = pendingShrinkCount
    }
}

/// Pure width anti-jitter policy for the menu-bar readout.
///
/// Grows immediately whenever a new string exceeds the reserved width (never clips), ignores small
/// character-count fluctuations below `shrinkCharThreshold`, and requires `shrinkHysteresisSteps`
/// consecutive shorter updates before shrinking the reserved width.
public enum MenuBarWidthStabilizer: Sendable {
    public static let defaultShrinkCharThreshold = 2
    public static let defaultShrinkHysteresisSteps = 2

    public static func update(
        state: MenuBarWidthState,
        text: String?,
        measuredWidth: Double,
        shrinkCharThreshold: Int = defaultShrinkCharThreshold,
        shrinkHysteresisSteps: Int = defaultShrinkHysteresisSteps
    ) -> MenuBarWidthState {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return MenuBarWidthState(reservedWidth: nil, anchorCharCount: 0, pendingShrinkCount: 0)
        }

        let charCount = trimmed.count
        let clampedMeasured = max(0, ceil(measuredWidth))

        guard let currentReserved = state.reservedWidth else {
            return MenuBarWidthState(
                reservedWidth: clampedMeasured,
                anchorCharCount: charCount,
                pendingShrinkCount: 0
            )
        }

        if clampedMeasured > currentReserved {
            return MenuBarWidthState(
                reservedWidth: clampedMeasured,
                anchorCharCount: charCount,
                pendingShrinkCount: 0
            )
        }

        let threshold = max(1, shrinkCharThreshold)
        let stepsNeeded = max(1, shrinkHysteresisSteps)
        let charDrop = state.anchorCharCount - charCount

        guard charDrop >= threshold, clampedMeasured < currentReserved else {
            return MenuBarWidthState(
                reservedWidth: currentReserved,
                anchorCharCount: max(state.anchorCharCount, charCount),
                pendingShrinkCount: 0
            )
        }

        let nextPending = state.pendingShrinkCount + 1
        if nextPending >= stepsNeeded {
            return MenuBarWidthState(
                reservedWidth: clampedMeasured,
                anchorCharCount: charCount,
                pendingShrinkCount: 0
            )
        }

        return MenuBarWidthState(
            reservedWidth: currentReserved,
            anchorCharCount: state.anchorCharCount,
            pendingShrinkCount: nextPending
        )
    }
}

/// Normalization and compact formatting for optional pinned menu-bar readouts (up to 2 items).
public enum MenuBarPinnedReadout: Sendable {
    public static let maxPinnedCount = 2
    private static let maxSwitchNameLength = 6

    public static func normalize(_ rawIDs: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for raw in rawIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == maxPinnedCount { break }
        }
        return result
    }

    public static func extractReferencedID(_ token: String) -> String? {
        for prefix in ["temp:", "hum:", "temp_hum:", "switch:"] where token.hasPrefix(prefix) {
            let id = String(token.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    public static func format(
        pinnedIDs: [String],
        environmentReadings: [EnvironmentReading],
        devices: [SmartDevice]
    ) -> String? {
        let normalized = normalize(pinnedIDs)
        guard !normalized.isEmpty else { return nil }

        let parts = normalized.compactMap { token in
            formatSingle(token, environmentReadings: environmentReadings, devices: devices)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private static func formatSingle(
        _ token: String,
        environmentReadings: [EnvironmentReading],
        devices: [SmartDevice]
    ) -> String? {
        if token.hasPrefix("temp:") {
            let id = String(token.dropFirst("temp:".count))
            guard let t = environmentReadings.first(where: { $0.id == id })?.temperature else { return nil }
            return L10n.temperature(t, fractionDigits: 1)
        }
        if token.hasPrefix("hum:") {
            let id = String(token.dropFirst("hum:".count))
            guard let h = environmentReadings.first(where: { $0.id == id })?.humidity else { return nil }
            return String(format: "%.0f%%", h)
        }
        if token.hasPrefix("temp_hum:") {
            let id = String(token.dropFirst("temp_hum:".count))
            guard let env = environmentReadings.first(where: { $0.id == id }) else { return nil }
            switch (env.temperature, env.humidity) {
            case let (t?, h?):
                return "\(L10n.temperature(t, fractionDigits: 1)) \(String(format: "%.0f%%", h))"
            case let (t?, nil):
                return L10n.temperature(t, fractionDigits: 1)
            case let (nil, h?):
                return String(format: "%.0f%%", h)
            case (nil, nil):
                return nil
            }
        }
        if token.hasPrefix("switch:") {
            let id = String(token.dropFirst("switch:".count))
            guard let dev = devices.first(where: { $0.id == id }) else { return nil }
            let shortName = compactName(dev.name)
            if !dev.isOnline {
                return L10n.tr("\(shortName) 离线", "\(shortName) Offl.")
            }
            return dev.isActiveOn
                ? L10n.tr("\(shortName) 开", "\(shortName) On")
                : L10n.tr("\(shortName) 关", "\(shortName) Off")
        }
        return nil
    }

    private static func compactName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxSwitchNameLength else { return trimmed }
        return String(trimmed.prefix(maxSwitchNameLength)) + "…"
    }
}

extension SmartDevice {
    /// Devices whose binary on/off state is meaningful to pin in the menu bar.
    public var isPinnableMenuBarSwitch: Bool {
        switch kind {
        case .light, .plug, .climate, .fan, .humidifier, .appliance, .generic, .valve:
            return true
        case .sensor, .fridge, .cover, .vacuum, .speaker, .tv, .camera:
            return false
        }
    }
}
