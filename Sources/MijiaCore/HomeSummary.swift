import Foundation

/// Fixed display order for the first-screen "我家现在" summary capsule row (R16 §1.3).
public enum HomeSummaryCapsuleKind: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case alerts
    case lightsOn
    case doorsOpen
    case indoorTemp
}

/// One tappable capsule in the first-screen summary row.
public struct HomeSummaryCapsule: Identifiable, Equatable, Sendable {
    public let kind: HomeSummaryCapsuleKind
    public let count: Int
    /// Rounded indoor temperature in Celsius (only set for `.indoorTemp`).
    public let temperatureCelsius: Double?
    /// Highest active severity from the shared `AlertSeverity` table (only set for `.alerts`).
    public let alertSeverity: AlertSeverity?
    /// Unique device IDs represented by this capsule, in snapshot order.
    public let targetDeviceIds: [String]
    /// Preferred `DeviceKindTag` filter when tapping the capsule, or `nil` for alert focus.
    public let filterTag: DeviceKindTag?

    public var id: String { kind.rawValue }

    public init(
        kind: HomeSummaryCapsuleKind,
        count: Int,
        temperatureCelsius: Double? = nil,
        alertSeverity: AlertSeverity? = nil,
        targetDeviceIds: [String] = [],
        filterTag: DeviceKindTag? = nil
    ) {
        self.kind = kind
        self.count = count
        self.temperatureCelsius = temperatureCelsius
        self.alertSeverity = alertSeverity
        self.targetDeviceIds = targetDeviceIds
        self.filterTag = filterTag
    }

    public func title(temperatureUnit: TemperatureUnit = .celsius) -> String {
        switch kind {
        case .alerts:
            return count == 1
                ? L10n.tr("1 条告警", "1 alert")
                : L10n.format("%@ 条告警", "%@ alerts", "\(count)")
        case .lightsOn:
            return count == 1
                ? L10n.tr("1 盏灯开着", "1 light on")
                : L10n.format("%@ 盏灯开着", "%@ lights on", "\(count)")
        case .doorsOpen:
            return count == 1
                ? L10n.tr("1 处门窗开着", "1 door/window open")
                : L10n.format("%@ 处门窗开着", "%@ doors/windows open", "\(count)")
        case .indoorTemp:
            guard let celsius = temperatureCelsius else { return "" }
            let displayValue: Double = switch temperatureUnit {
            case .celsius: celsius
            case .fahrenheit: celsius * 9.0 / 5.0 + 32.0
            }
            // Same precision as the header reading, so 25.8° up top never sits beside a rounded 26°.
            let text = temperatureUnit == .celsius && abs(celsius - celsius.rounded()) >= 0.05
                ? String(format: "%.1f", displayValue)
                : "\(Int(displayValue.rounded(.toNearestOrAwayFromZero)))"
            // Several sensors: say it is an average, so it does not read as contradicting the header's one room.
            return count > 1
                ? L10n.format("室内均温 %@°", "Indoor avg %@°", text)
                : L10n.format("室内 %@°", "Indoor %@°", text)
        }
    }

    public var sfSymbolName: String {
        switch kind {
        case .alerts:
            return alertSeverity == .alert ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
        case .lightsOn:
            return "lightbulb.fill"
        case .doorsOpen:
            return "door.left.hand.open"
        case .indoorTemp:
            return "thermometer.medium"
        }
    }
}

/// Pure home-level summary aggregation for the top-of-panel capsule row.
/// Mirrored in `windows/src/core/homeSummary.ts`; both ends share `Tests/Fixtures/home_summary_golden.json`.
public struct HomeSummary: Equatable, Sendable {
    public let capsules: [HomeSummaryCapsule]

    public var isEmpty: Bool { capsules.isEmpty }

    public init(capsules: [HomeSummaryCapsule]) {
        self.capsules = capsules
    }

    /// Computes visible summary capsules from the current device snapshot and active alerts.
    /// Zero-count capsules are omitted; when nothing applies, `capsules` is empty.
    public static func compute(
        devices: [SmartDevice],
        alerts: [SafetyAlert],
        lightMarkedSwitchIds: Set<String> = []
    ) -> HomeSummary {
        var capsules: [HomeSummaryCapsule] = []

        // 1. Active alerts (highest severity from shared AlertSeverity table drives color).
        if !alerts.isEmpty {
            var seenAlertIds: Set<String> = []
            var uniqueAlerts: [SafetyAlert] = []
            for alert in alerts where seenAlertIds.insert(alert.id).inserted {
                uniqueAlerts.append(alert)
            }
            if !uniqueAlerts.isEmpty {
                let hasCritical = uniqueAlerts.contains { $0.severity == .alert }
                let severity: AlertSeverity = hasCritical ? .alert : .warning
                let deviceIds = uniqueOrdered(uniqueAlerts.compactMap { $0.deviceId.isEmpty ? nil : $0.deviceId })
                capsules.append(HomeSummaryCapsule(
                    kind: .alerts,
                    count: uniqueAlerts.count,
                    alertSeverity: severity,
                    targetDeviceIds: deviceIds,
                    filterTag: nil
                ))
            }
        }

        // 2. Lights currently on (online lights + online plugs marked as lights).
        var lightDeviceIds: [String] = []
        var hasNativeLight = false
        for device in devices where device.isOnline {
            switch device.kind {
            case .light(let spec) where spec.isOn:
                lightDeviceIds.append(device.id)
                hasNativeLight = true
            case .plug(let spec) where spec.isOn && lightMarkedSwitchIds.contains(device.id):
                lightDeviceIds.append(device.id)
            default:
                break
            }
        }
        if !lightDeviceIds.isEmpty {
            capsules.append(HomeSummaryCapsule(
                kind: .lightsOn,
                count: lightDeviceIds.count,
                targetDeviceIds: lightDeviceIds,
                filterTag: hasNativeLight ? .light : .plug
            ))
        }

        // 3. Doors / windows / covers currently open.
        var doorDeviceIds: [String] = []
        var hasCover = false
        for device in devices where device.isOnline {
            var isOpen = false
            if case .cover(let spec) = device.kind, (spec.positionPercent ?? 0) > 0 {
                isOpen = true
                hasCover = true
            } else if device.safetyObservations.contains(where: { $0.kind == .contact && $0.alarming }) {
                isOpen = true
            }
            if isOpen {
                doorDeviceIds.append(device.id)
            }
        }
        if !doorDeviceIds.isEmpty {
            capsules.append(HomeSummaryCapsule(
                kind: .doorsOpen,
                count: doorDeviceIds.count,
                targetDeviceIds: doorDeviceIds,
                filterTag: hasCover ? .cover : .sensor
            ))
        }

        // 4. Indoor temperature (average of online sensor temperatures; fallback to climate/fan).
        var sensorTemps: [(id: String, value: Double)] = []
        var fallbackTemps: [(id: String, value: Double, tag: DeviceKindTag)] = []
        for device in devices where device.isOnline {
            switch device.kind {
            case .sensor(let spec):
                if let temp = spec.temperature, temp.isFinite {
                    sensorTemps.append((device.id, temp))
                }
            case .climate(let spec):
                if let temp = spec.currentTemperature, temp.isFinite {
                    fallbackTemps.append((device.id, temp, .climate))
                }
            case .fan(let spec):
                if let temp = spec.temperature, temp.isFinite {
                    fallbackTemps.append((device.id, temp, .fan))
                }
            default:
                break
            }
        }
        if !sensorTemps.isEmpty {
            let avg = sensorTemps.reduce(0.0) { $0 + $1.value } / Double(sensorTemps.count)
            capsules.append(HomeSummaryCapsule(
                kind: .indoorTemp,
                count: sensorTemps.count,
                temperatureCelsius: avg,
                targetDeviceIds: sensorTemps.map(\.id),
                filterTag: .sensor
            ))
        } else if !fallbackTemps.isEmpty {
            let avg = fallbackTemps.reduce(0.0) { $0 + $1.value } / Double(fallbackTemps.count)
            let preferredTag = fallbackTemps.first?.tag ?? .climate
            capsules.append(HomeSummaryCapsule(
                kind: .indoorTemp,
                count: fallbackTemps.count,
                temperatureCelsius: avg,
                targetDeviceIds: fallbackTemps.map(\.id),
                filterTag: preferredTag
            ))
        }

        return HomeSummary(capsules: capsules)
    }

    private static func uniqueOrdered(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}
