import Foundation

// Safety alerts: the store's preferences and actions around `SafetyMonitor` (#48).
extension HomeStore {

    public func isSensorAlertEnabled(_ kind: SensorAlertKind) -> Bool {
        sensorAlertPreferences[kind] ?? kind.enabledByDefault
    }

    public func setSensorAlertEnabled(_ kind: SensorAlertKind, _ enabled: Bool) {
        sensorAlertPreferences[kind] = enabled
        userDefaults.set(enabled, forKey: kind.defaultsKey)
        // Turning an alert off ends its exclusive reads; a closed type keeps only the ones still on.
        syncMiotTypePrunePolicy()
        // The last enabled kind turned off is what lets an idle poll stretch (ADR-0023 §4).
        refreshPollingContext()
    }

    public var awayGapIncludesAway: Bool {
        awayGap.includesAway
    }

    public var menuBarShowsHazard: Bool {
        guard enableSafetyAlerts else { return false }
        // A closed type keeps its hazard sensors evaluating, so the menu bar must still colour.
        for device in devices + typeHiddenSafetyDevices {
            for observation in device.freshSafetyObservations
            where observation.alarming && observation.kind.colorsMenuBar && isSensorAlertEnabled(observation.kind) {
                return true
            }
        }
        return false
    }

    /// An enabled alert is read out of the polled snapshots, so the poll cannot slow down for being
    /// idle: a closed device type still keeps its flood and smoke sensors in `typeHiddenSafetyDevices`
    /// (ADR-0023 §4). Off when the alerts are off, or when every alert kind is.
    public var safetyAlertsRelyOnPolling: Bool {
        guard enableSafetyAlerts else { return false }
        return SensorAlertKind.allCases.contains { isSensorAlertEnabled($0) }
    }

    public func nextSafetyAlertCheck(now: Date) -> Date? {
        guard enableSafetyAlerts else { return nil }
        return safetyMonitor.nextTimedCheck(devices: devices + typeHiddenSafetyDevices, now: now)
    }

    @discardableResult
    public func evaluateSafetyAlerts(now: Date = Date()) -> [SafetyAlert] {
        guard enableSafetyAlerts else { return [] }
        let enabled = Dictionary(uniqueKeysWithValues: SensorAlertKind.allCases.map { ($0, isSensorAlertEnabled($0)) })
        let unavailableActionIds = Set(devices.lazy
            .filter { !self.capabilitySelection.enabledCategories.contains($0.capabilityCategoryID) }
            .map(\.id))
        let retained = typeHiddenSafetyDevices
        let alerts = safetyMonitor.evaluate(
            devices: devices + retained,
            favorites: favoriteDeviceIds,
            unavailableActionIds: unavailableActionIds.union(retained.map(\.id)),
            sensorPolicy: SensorAlertPolicy(
                enabled: enabled,
                onlyWhenAway: sensorAlertsOnlyWhenAway,
                includesAway: awayGap.includesAway
            ),
            now: now
        )
        // Every evaluation advances `SafetyMonitor` session state (`longRunAlertedForSession`,
        // cooldowns), so both snapshots and scheduled checks record here.
        recordSafetyAlerts(alerts, now: now)
        return alerts
    }

    /// Shown when a notification's target no longer belongs to the home on screen.
    public var staleSafetyAlertMessage: String {
        L10n.tr(
            "该提醒已不适用于当前家居，未关闭设备",
            "This alert no longer applies to the current home; nothing was turned off"
        )
    }

    private func safetyAlertActionTarget(_ id: String) -> SmartDevice? {
        guard let device = devices.first(where: { $0.id == id }),
              capabilityWriteRejection(for: device) == nil else { return nil }
        return device
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
              safetyAlertActionTarget(alert.deviceId) != nil else {
            showToast(staleSafetyAlertMessage, isError: true)
            return nil
        }
        let context = controlContextID
        return Task {
            // A switch can land between creating this task and it starting; check again right before
            // the send, when the current provider and devices are the ones that will be used.
            guard context == controlContextID else { return }
            guard deliveredScope == connectionScopeIdentifier,
                  let device = safetyAlertActionTarget(alert.deviceId) else {
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
