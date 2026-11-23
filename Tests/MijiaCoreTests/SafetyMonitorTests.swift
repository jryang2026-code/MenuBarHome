import Foundation
import Testing
@testable import MijiaCore

/// `SafetyMonitor` is driven directly, without a store: snapshots in, alerts out.
struct SafetyMonitorTests {
    private static let policy = SensorAlertPolicy(enabled: [:], onlyWhenAway: false, includesAway: false)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.safetymonitor.\(UUID().uuidString)")!
    }

    private func sensor(
        battery: Int,
        online: Bool = true,
        stale: Bool = false,
        observations: [SensorObservation] = []
    ) -> SmartDevice {
        SmartDevice(
            id: "door",
            name: "门磁",
            roomId: "r",
            roomName: "玄关",
            model: "lumi.sensor",
            isOnline: online,
            kind: .sensor(SensorSpec(battery: battery, observations: observations)),
            telemetryStale: stale
        )
    }

    private func plug(on: Bool, watts: Double, online: Bool = true, stale: Bool = false) -> SmartDevice {
        SmartDevice(
            id: "heater",
            name: "暖风机",
            roomId: "r",
            roomName: "书房",
            model: "cuco.plug",
            isOnline: online,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: on, powerWatts: watts)),
            telemetryStale: stale
        )
    }

    @Test func timedAlertsWakeAtTheirThresholdWithoutAnotherSnapshot() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let climate = SmartDevice(
            id: "ac", name: "空调", roomId: "r", roomName: "书房", model: "ac", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac", isOn: true, hvacMode: "cool",
                availableModes: ["off", "cool"], targetTemperature: 26
            ))
        )
        let devices = [sensor(battery: 9), plug(on: true, watts: 900), climate]
        var monitor = SafetyMonitor(defaults: defaults())
        #expect(monitor.nextTimedCheck(devices: devices, now: start) == start)
        #expect(monitor.evaluate(devices: devices, favorites: [], sensorPolicy: Self.policy, now: start).map(\.id)
            == ["battery:door"])

        let plugDue = start + 45 * 60
        #expect(monitor.nextTimedCheck(devices: devices, now: start) == plugDue)
        #expect(monitor.evaluate(devices: devices, favorites: [], sensorPolicy: Self.policy, now: plugDue).map(\.id)
            == ["longrun:heater"])

        let climateDue = start + 4 * 3600
        #expect(monitor.nextTimedCheck(devices: devices, now: plugDue) == climateDue)
        #expect(monitor.evaluate(devices: devices, favorites: [], sensorPolicy: Self.policy, now: climateDue).map(\.id)
            == ["longrun:ac"])

        let batteryDue = start + 86_400
        #expect(monitor.nextTimedCheck(devices: devices, now: climateDue) == batteryDue)
        #expect(monitor.evaluate(devices: devices, favorites: [], sensorPolicy: Self.policy, now: batteryDue).map(\.id)
            == ["battery:door"])
        #expect(monitor.nextTimedCheck(devices: [plug(on: true, watts: 900)], now: batteryDue) == nil)
        #expect(monitor.nextTimedCheck(devices: [sensor(battery: 9, stale: true)], now: batteryDue) == nil)
    }

    @Test("Low battery alerts once per 24 h, and the cooldown survives a relaunch")
    func lowBatteryCooldown() {
        let store = defaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var monitor = SafetyMonitor(defaults: store)
        #expect(monitor.evaluate(devices: [sensor(battery: 9)], favorites: [], sensorPolicy: Self.policy, now: start).map(\.id) == ["battery:door"])
        #expect(monitor.evaluate(devices: [sensor(battery: 9)], favorites: [], sensorPolicy: Self.policy, now: start + 3600).isEmpty)

        var relaunched = SafetyMonitor(defaults: store)
        #expect(relaunched.evaluate(devices: [sensor(battery: 9)], favorites: [], sensorPolicy: Self.policy, now: start + 7200).isEmpty)
        #expect(relaunched.evaluate(devices: [sensor(battery: 9)], favorites: [], sensorPolicy: Self.policy, now: start + 86_400).count == 1)
    }

    @Test("A starred device alerts when it goes from online to offline, not while it stays offline")
    func starredOfflineTransition() {
        var monitor = SafetyMonitor(defaults: defaults())
        let now = Date(timeIntervalSince1970: 2_000_000)
        _ = monitor.evaluate(devices: [sensor(battery: 80)], favorites: ["door"], sensorPolicy: Self.policy, now: now)
        let dropped = monitor.evaluate(devices: [sensor(battery: 80, online: false)], favorites: ["door"], sensorPolicy: Self.policy, now: now + 60)
        #expect(dropped.count == 1)
        #expect(dropped.first?.id.hasPrefix("offline:door") == true)
        #expect(monitor.evaluate(devices: [sensor(battery: 80, online: false)], favorites: ["door"], sensorPolicy: Self.policy, now: now + 120).isEmpty)
    }

    @Test("A high-draw plug reminds once after 45 minutes; switching off re-arms it")
    func longRunningPlug() {
        var monitor = SafetyMonitor(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        #expect(monitor.evaluate(devices: [plug(on: true, watts: 900)], favorites: [], sensorPolicy: Self.policy, now: t0).isEmpty)
        let reminded = monitor.evaluate(devices: [plug(on: true, watts: 900)], favorites: [], sensorPolicy: Self.policy, now: t0 + 46 * 60)
        #expect(reminded.map(\.id) == ["longrun:heater"])
        #expect(reminded.first?.turnOffCommand == .setSwitch(entityId: "switch.heater", isOn: false))
        #expect(monitor.evaluate(devices: [plug(on: true, watts: 900)], favorites: [], sensorPolicy: Self.policy, now: t0 + 90 * 60).isEmpty)
        _ = monitor.evaluate(devices: [plug(on: false, watts: 0)], favorites: [], sensorPolicy: Self.policy, now: t0 + 91 * 60)
        _ = monitor.evaluate(devices: [plug(on: true, watts: 900)], favorites: [], sensorPolicy: Self.policy, now: t0 + 92 * 60)
        #expect(monitor.evaluate(devices: [plug(on: true, watts: 900)], favorites: [], sensorPolicy: Self.policy, now: t0 + 140 * 60).count == 1)
    }

    @Test("A low-draw plug never reminds")
    func lowDrawPlugStaysQuiet() {
        var monitor = SafetyMonitor(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        _ = monitor.evaluate(devices: [plug(on: true, watts: 12)], favorites: [], sensorPolicy: Self.policy, now: t0)
        #expect(monitor.evaluate(devices: [plug(on: true, watts: 12)], favorites: [], sensorPolicy: Self.policy, now: t0 + 5 * 3600).isEmpty)
    }

    @Test("Stale telemetry suppresses false offline, battery, long-run, and sensor alerts while preserving tracking state")
    func staleTelemetrySuppressesAlertsAndPreservesTracking() {
        var monitor = SafetyMonitor(defaults: defaults())
        let leakPolicy = SensorAlertPolicy(enabled: [.leak: true], onlyWhenAway: false, includesAway: false)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        let clearObs = [SensorObservation(sourceId: "door#leak", kind: .leak, alarming: false)]
        let alarmObs = [SensorObservation(sourceId: "door#leak", kind: .leak, alarming: true)]

        #expect(monitor.evaluate(
            devices: [
                sensor(battery: 80, online: true, stale: false, observations: clearObs),
                plug(on: true, watts: 900, online: true, stale: false),
            ],
            favorites: ["door"],
            sensorPolicy: leakPolicy,
            now: t0
        ).isEmpty)

        #expect(monitor.evaluate(
            devices: [
                sensor(battery: 5, online: false, stale: true, observations: alarmObs),
                plug(on: false, watts: 0, online: false, stale: true),
            ],
            favorites: ["door"],
            sensorPolicy: leakPolicy,
            now: t0 + 20 * 60
        ).isEmpty)

        let alertsAt46m = monitor.evaluate(
            devices: [
                sensor(battery: 80, online: false, stale: false, observations: alarmObs),
                plug(on: true, watts: 900, online: true, stale: false),
            ],
            favorites: ["door"],
            sensorPolicy: leakPolicy,
            now: t0 + 46 * 60
        )
        #expect(Set(alertsAt46m.map(\.deviceId)) == ["door", "heater"])
        #expect(alertsAt46m.contains { $0.id.hasPrefix("offline:door:") })
        #expect(alertsAt46m.contains { $0.id == "longrun:heater" })
        #expect(alertsAt46m.contains { $0.id.hasPrefix("sensor:leak:door#leak:") })

        #expect(monitor.evaluate(
            devices: [
                sensor(battery: 80, online: false, stale: true, observations: clearObs),
                plug(on: false, watts: 0, online: false, stale: true),
            ],
            favorites: ["door"],
            sensorPolicy: leakPolicy,
            now: t0 + 50 * 60
        ).isEmpty)

        #expect(monitor.evaluate(
            devices: [
                sensor(battery: 80, online: true, stale: false, observations: alarmObs),
                plug(on: true, watts: 900, online: true, stale: false),
            ],
            favorites: ["door"],
            sensorPolicy: leakPolicy,
            now: t0 + 100 * 60
        ).isEmpty)
    }
}
