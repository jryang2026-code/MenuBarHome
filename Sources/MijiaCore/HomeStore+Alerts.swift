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

    /// Shown when a notification's target no longer belongs to the home on screen.
    public var staleSafetyAlertMessage: String {
        L10n.tr(
            "该提醒已不适用于当前家居，未关闭设备",
            "This alert no longer applies to the current home; nothing was turned off"
        )
    }

    /// Runs the 立即关闭 action of a safety notification. A notification is a person acting now, so the
    /// lock-screen preference applies (#143). `deliveredInScope` is the connection scope the alert was
    /// delivered in: Home Assistant entity ids repeat across servers (`light.heater`), so a device that
    /// exists in the current home is not proof that it is the one the notification was about.
    @discardableResult
    public func executeSafetyAlertAction(_ alert: SafetyAlert, deliveredInScope scope: String?) -> Task<Void, Never>? {
        guard let cmd = alert.turnOffCommand else { return nil }
        if rejectControlWhileLocked() { return nil }
        guard let deliveredScope = scope, deliveredScope == connectionScopeIdentifier,
              let device = devices.first(where: { $0.id == alert.deviceId }) else {
            showToast(staleSafetyAlertMessage, isError: true)
            return nil
        }
        let context = controlContextID
        return Task {
            // A switch can land between creating this task and it starting; check again right before
            // the send, when the current provider and devices are the ones that will be used.
            guard context == controlContextID else { return }
            guard deliveredScope == connectionScopeIdentifier,
                  let device = devices.first(where: { $0.id == alert.deviceId }) else {
                showToast(staleSafetyAlertMessage, isError: true)
                return
            }
            do {
                try await executeDeviceCommand(cmd)
                guard context == controlContextID else { return }
                await provider.refreshNow()
            } catch is MiSessionWriteBlocked {
                return
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
