import Foundation

// Safety alerts: the store's preferences and actions around `SafetyMonitor` (#48).
extension HomeStore {

    public func isSensorAlertEnabled(_ kind: SensorAlertKind) -> Bool {
        sensorAlertPreferences[kind] ?? kind.enabledByDefault
    }

    public func setSensorAlertEnabled(_ kind: SensorAlertKind, _ enabled: Bool) {
        sensorAlertPreferences[kind] = enabled
        userDefaults.set(enabled, forKey: kind.defaultsKey)
    }

    public var menuBarShowsHazard: Bool {
        guard enableSafetyAlerts else { return false }
        for device in devices {
            guard case .sensor(let spec) = device.kind else { continue }
            for observation in spec.observations
            where observation.alarming && observation.kind.colorsMenuBar && isSensorAlertEnabled(observation.kind) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func evaluateSafetyAlerts(now: Date = Date()) -> [SafetyAlert] {
        guard enableSafetyAlerts else { return [] }
        let enabled = Dictionary(uniqueKeysWithValues: SensorAlertKind.allCases.map { ($0, isSensorAlertEnabled($0)) })
        return safetyMonitor.evaluate(
            devices: devices,
            favorites: favoriteDeviceIds,
            sensorPolicy: SensorAlertPolicy(
                enabled: enabled,
                onlyWhenAway: sensorAlertsOnlyWhenAway,
                includesAway: awayGap.includesAway
            ),
            now: now
        )
    }

    /// Runs the 立即关闭 action of a safety notification. A notification is a person acting now, so the
    /// lock-screen preference applies (#143), and a notification tapped after the user switched home,
    /// account or source must not reach a device that is no longer theirs.
    @discardableResult
    public func executeSafetyAlertAction(_ alert: SafetyAlert) -> Task<Void, Never>? {
        guard let cmd = alert.turnOffCommand else { return nil }
        if rejectControlWhileLocked() { return nil }
        guard let device = devices.first(where: { $0.id == alert.deviceId }) else {
            showToast(
                L10n.tr(
                    "该提醒已不适用于当前家居，未关闭设备",
                    "This alert no longer applies to the current home; nothing was turned off"
                ),
                isError: true
            )
            return nil
        }
        let context = controlContextID
        return Task {
            do {
                try await executeDeviceCommand(cmd)
                guard context == controlContextID else { return }
                await provider.refreshNow()
            } catch {
                // A switch during the send makes the failure irrelevant to the new home.
                guard context == controlContextID else { return }
                showToast(
                    L10n.format("「%@」关闭失败", "Could not turn off %@", device.name),
                    isError: true
                )
            }
        }
    }
}
