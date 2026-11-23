import Foundation

/// The safety-alert engine and the state it remembers between evaluations: who was online,
/// when a low battery last alerted (persisted, 24 h cooldown), when a device switched on, which
/// long runs already alerted this session, and the sensor alarm edges (persisted).
///
/// `HomeStore` owns one and feeds it every snapshot; tests drive it directly without a store.
struct SafetyMonitor {
    /// #35: a plug joins the long-running reminder only when it reports power above this threshold.
    /// Plugs without a power reading (router, fridge, fish tank) never trigger it; 300 W keeps
    /// low-draw infrastructure quiet while a coffee machine or heater still alerts after 45 min.
    static let longRunningPlugMinimumWatts: Double = 300
    private static let lowBatteryCooldown: TimeInterval = 86_400
    static let lowBatteryAlertedAtKey = "safety_low_battery_alerted_at_v1"
    static let sensorEdgeKey = "safety_sensor_edge_v1"

    private let defaults: UserDefaults
    private var previousOnlineDeviceIds: Set<String> = []
    private var lowBatteryAlertedAt: [String: Date]
    private var activeSinceByDeviceId: [String: Date] = [:]
    private var longRunAlertedForSession: Set<String> = []
    private var sensorEdge: [String: Bool]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let storedBattery = defaults.dictionary(forKey: Self.lowBatteryAlertedAtKey) ?? [:]
        self.lowBatteryAlertedAt = storedBattery.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            .mapValues { Date(timeIntervalSince1970: $0) }
        var edge: [String: Bool] = [:]
        for (key, value) in defaults.dictionary(forKey: Self.sensorEdgeKey) ?? [:] {
            if let number = value as? NSNumber { edge[key] = number.boolValue }
        }
        self.sensorEdge = edge
    }

    func nextTimedCheck(devices: [SmartDevice], now: Date) -> Date? {
        var next: Date?
        for device in devices where !device.telemetryStale {
            if Self.lowBatteryLevel(device) != nil {
                let due = lowBatteryAlertedAt[device.id]?.addingTimeInterval(Self.lowBatteryCooldown) ?? now
                next = min(next ?? due, due)
            }
            if device.isActiveOn, !longRunAlertedForSession.contains(device.id),
               let threshold = Self.longRunThreshold(device) {
                let due = (activeSinceByDeviceId[device.id] ?? now).addingTimeInterval(threshold)
                next = min(next ?? due, due)
            }
        }
        return next
    }

    private static func lowBatteryLevel(_ device: SmartDevice) -> Int? {
        guard device.isOnline, case .sensor(let sensor) = device.kind,
              let level = sensor.battery, level > 0, level < 15 else { return nil }
        return level
    }

    private static func longRunThreshold(_ device: SmartDevice) -> TimeInterval? {
        switch device.kind {
        case .plug(let plug) where plug.powerWritable && (plug.powerWatts ?? 0) > longRunningPlugMinimumWatts:
            return 45 * 60
        case .climate:
            return 4 * 3600
        default:
            return nil
        }
    }

    /// The alerts this snapshot raises. Remembers what it alerted so the next call does not repeat it.
    mutating func evaluate(
        devices: [SmartDevice],
        favorites: Set<String>,
        unavailableActionIds: Set<String> = [],
        sensorPolicy: SensorAlertPolicy,
        now: Date,
        calendar: Calendar = .current
    ) -> [SafetyAlert] {
        var emitted: [SafetyAlert] = []
        let presentIds = Set(devices.map(\.id))
        activeSinceByDeviceId = activeSinceByDeviceId.filter { presentIds.contains($0.key) }
        longRunAlertedForSession.formIntersection(presentIds)

        for dev in devices {
            if dev.telemetryStale { continue }
            // 1. Starred device offline transition check
            if favorites.contains(dev.id) {
                if previousOnlineDeviceIds.contains(dev.id) && !dev.isOnline {
                    emitted.append(
                        SafetyAlert(
                            id: "offline:\(dev.id):\(Int(now.timeIntervalSince1970))",
                            deviceId: dev.id,
                            title: L10n.tr("\(dev.name) 已离线", "\(dev.name) Offline"),
                            body: L10n.tr(
                                "\(dev.roomName)的「\(dev.name)」刚刚断开连接或断电。",
                                "\"\(dev.name)\" in \(dev.roomName) just went offline or lost power."
                            )
                        )
                    )
                }
            }

            // 2. Low battery check (<15% for sensors/locks, 24h cooldown)
            if let bat = Self.lowBatteryLevel(dev) {
                let due = lowBatteryAlertedAt[dev.id]?.addingTimeInterval(Self.lowBatteryCooldown) ?? now
                if now >= due {
                    lowBatteryAlertedAt[dev.id] = now
                    persistLowBatteryAlertedAt()
                    emitted.append(
                        SafetyAlert(
                            id: "battery:\(dev.id)",
                            deviceId: dev.id,
                            title: L10n.tr("\(dev.name) 电量低 (\(bat)%)", "\(dev.name) Low Battery (\(bat)%)"),
                            body: L10n.tr(
                                "请及时为\(dev.roomName)的「\(dev.name)」更换电池或充电。",
                                "Please replace or recharge the battery for \"\(dev.name)\" (\(dev.roomName))."
                            )
                        )
                    )
                }
            }

            // 3. Long-running plug (>=45m) or climate (>=4h) check
            if dev.isActiveOn {
                let startedAt = activeSinceByDeviceId[dev.id] ?? {
                    activeSinceByDeviceId[dev.id] = now
                    return now
                }()
                guard !longRunAlertedForSession.contains(dev.id),
                      let threshold = Self.longRunThreshold(dev),
                      now >= startedAt.addingTimeInterval(threshold) else { continue }

                let canTurnOff = !unavailableActionIds.contains(dev.id)
                switch dev.kind {
                // A read-only plug (unverified spec, mains breaker #265) gets no reminder: its
                // notification button would send the very switch command the card refuses.
                case .plug(let s):
                    longRunAlertedForSession.insert(dev.id)
                    let watts = DeviceSynthesizer.roundedInt(s.powerWatts ?? 0) ?? 0
                    emitted.append(
                        SafetyAlert(
                            id: "longrun:\(dev.id)",
                            deviceId: dev.id,
                            title: L10n.tr("\(dev.name) 已开启超过 45 分钟", "\(dev.name) On for Over 45m"),
                            body: canTurnOff ? L10n.tr(
                                "当前功率 \(watts)W，如需关闭可直接点击通知按钮。",
                                "Drawing \(watts)W. Click the notification action to turn it off."
                            ) : L10n.tr(
                                "当前功率 \(watts)W，请确认是否仍需开启。",
                                "Drawing \(watts)W. Check if you still need it running."
                            ),
                            turnOffCommand: canTurnOff ? .setSwitch(entityId: s.switchEntityId, isOn: false) : nil
                        )
                    )
                case .climate(let s):
                    longRunAlertedForSession.insert(dev.id)
                    emitted.append(
                        SafetyAlert(
                            id: "longrun:\(dev.id)",
                            deviceId: dev.id,
                            title: L10n.tr("\(dev.name) 已连续运行 4 小时", "\(dev.name) Running for 4 Hours"),
                            body: L10n.tr(
                                "当前设定 \(L10n.temperature(s.targetTemperature))，请确认是否仍需开启。",
                                "Target temp \(L10n.temperature(s.targetTemperature)). Check if you still need it running."
                            ),
                            turnOffCommand: canTurnOff ? .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: s.hvacMode) : nil
                        )
                    )
                default:
                    break
                }
            } else {
                activeSinceByDeviceId.removeValue(forKey: dev.id)
                longRunAlertedForSession.remove(dev.id)
            }
        }

        let evaluated = SensorAlerts.evaluate(
            devices: devices,
            ledger: sensorEdge,
            now: now,
            calendar: calendar,
            policy: sensorPolicy
        )
        if evaluated.ledger != sensorEdge {
            sensorEdge = evaluated.ledger
            defaults.set(sensorEdge, forKey: Self.sensorEdgeKey)
        }
        emitted.append(contentsOf: evaluated.alerts)

        let stalePreserved = Set(devices.filter { $0.telemetryStale && previousOnlineDeviceIds.contains($0.id) }.map(\.id))
        let freshOnline = Set(devices.filter { !$0.telemetryStale && $0.isOnline }.map(\.id))
        previousOnlineDeviceIds = stalePreserved.union(freshOnline)
        return emitted
    }

    /// Remembers the 24 h low-battery cooldown across launches (#35).
    private func persistLowBatteryAlertedAt() {
        defaults.set(lowBatteryAlertedAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.lowBatteryAlertedAtKey)
    }
}
