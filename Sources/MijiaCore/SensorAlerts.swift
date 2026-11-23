import Foundation

struct MacAwayGap: Equatable, Sendable {
    static let storageKey = "safety_alert_away_gap_v1"
    var includesAway: Bool
}

struct SensorAlertPolicy: Sendable {
    var enabled: [SensorAlertKind: Bool]
    var onlyWhenAway: Bool
    var includesAway: Bool

    func allows(_ kind: SensorAlertKind) -> Bool {
        guard enabled[kind] == true else { return false }
        if kind.honorsAwayLimit && onlyWhenAway {
            return includesAway
        }
        return true
    }
}

enum SensorAlerts {
    static func evaluate(
        devices: [SmartDevice],
        ledger: [String: Bool],
        now: Date,
        calendar: Calendar,
        policy: SensorAlertPolicy
    ) -> (alerts: [SafetyAlert], ledger: [String: Bool]) {
        var ledger = ledger
        var alerts: [SafetyAlert] = []
        for device in devices {
            let observations = device.freshSafetyObservations
            var countByKind: [SensorAlertKind: Int] = [:]
            for observation in observations {
                countByKind[observation.kind, default: 0] += 1
            }
            var deviceKindAlarming: [String: Bool] = [:]
            for observation in observations {
                let deviceKindKey = "device:\(device.id)#\(observation.kind.rawValue)"
                let rawPrevious = ledger[observation.sourceId]
                let effectivePrevious: Bool?
                if countByKind[observation.kind] == 1, let previousDeviceKind = ledger[deviceKindKey] {
                    // Track a single-probe sensor's edge by canonical (device.id, kind) so a
                    // dual-source handover between HA and Mi neither double-fires an active alarm
                    // nor swallows a fresh alarm after clearing on the other source (#325).
                    effectivePrevious = previousDeviceKind
                } else {
                    effectivePrevious = rawPrevious
                }
                ledger[observation.sourceId] = observation.alarming
                deviceKindAlarming[deviceKindKey] = (deviceKindAlarming[deviceKindKey] ?? false) || observation.alarming
                let firstSample = effectivePrevious == nil && observation.kind.notifiesOnFirstSample
                let rose = observation.alarming && (effectivePrevious == false || firstSample)
                guard rose, policy.allows(observation.kind) else { continue }
                alerts.append(makeAlert(device: device, observation: observation, now: now, calendar: calendar))
            }
            for (deviceKindKey, isAlarming) in deviceKindAlarming {
                ledger[deviceKindKey] = isAlarming
            }
        }
        return (alerts, ledger)
    }

    static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func makeAlert(
        device: SmartDevice,
        observation: SensorObservation,
        now: Date,
        calendar: Calendar
    ) -> SafetyAlert {
        let detected = observation.reportedAt ?? now
        let clock = clockLabel(detected, calendar: calendar)
        return SafetyAlert(
            id: "sensor:\(observation.kind.rawValue):\(observation.sourceId):\(Int(detected.timeIntervalSince1970))",
            deviceId: device.id,
            title: observation.kind.notificationTitle(deviceName: device.name),
            body: L10n.format(
                "「%@」（%@）于 %@ 触发",
                "\"%@\" (%@) at %@",
                device.name,
                device.roomName,
                clock
            ),
            turnOffCommand: nil
        )
    }
}
