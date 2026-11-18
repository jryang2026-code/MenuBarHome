import Foundation
import Testing
@testable import MijiaCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
    return calendar
}()

private func date(_ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)) ?? .distantPast
}

private func plug(_ id: String, online: Bool) -> SmartDevice {
    SmartDevice(
        id: id, name: id, roomId: "r", roomName: "客厅", model: "m", isOnline: online,
        kind: .plug(PlugSpec(switchEntityId: "switch.\(id)", isOn: false))
    )
}

/// #182: which devices keep dropping offline, counted in days so a flapping refresh counts once.
@MainActor
struct OfflineHistoryTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.offline.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @Test("Counts each day a device was seen offline once, within the last week")
    func countsDays() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = OfflineHistory(defaults: defaults, calendar: calendar)

        history.record(devices: [plug("a", online: false), plug("b", online: true)], now: date(2, 9))
        history.record(devices: [plug("a", online: false)], now: date(2, 18))
        history.record(devices: [plug("a", online: false)], now: date(5))
        history.record(devices: [plug("a", online: false)], now: date(10))

        #expect(history.offlineDays(dayCount: 7, now: date(10)) == ["a": 2])
        #expect(history.offlineDays(dayCount: 14, now: date(10)) == ["a": 3])
    }

    @Test("Survives a reload and forgets days older than two weeks")
    func persistsAndTrims() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        OfflineHistory(defaults: defaults, calendar: calendar).record(devices: [plug("a", online: false)], now: date(1))
        let later = OfflineHistory(defaults: defaults, calendar: calendar)
        #expect(later.offlineDays(dayCount: 14, now: date(3)) == ["a": 1])
        later.record(devices: [plug("b", online: false)], now: date(20))
        #expect(OfflineHistory(defaults: defaults, calendar: calendar).offlineDays(dayCount: 14, now: date(20)) == ["b": 1])
    }

    @Test("The weekly report lists devices offline on two or more days even if they are back online")
    func reportListsFlakyDevices() {
        let report = WeeklyHealthReport.build(
            devices: [plug("flaky", online: true), plug("once", online: true), plug("down", online: false)],
            dailyEnergy: [],
            energyByDevice: [],
            climate: [:],
            offlineDays: ["flaky": 3, "once": 1, "down": 1]
        )
        #expect(report.offlineDevices == [
            .init(deviceName: "flaky", roomName: "客厅", daysOffline: 3, isOfflineNow: false),
            .init(deviceName: "down", roomName: "客厅", daysOffline: 1),
        ])
        #expect(report.markdown(language: .chinese).contains("- 客厅 · flaky（本周 3 天出现离线）"))
        #expect(report.markdown(language: .chinese).contains("- 客厅 · down（现在离线）"))
    }

    @Test("Devices marked telemetryStale do not record false hardware offline days or stale sensor samples")
    func telemetryStaleSkippedInOfflineAndSensorHistory() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let offlineHistory = OfflineHistory(defaults: defaults, calendar: calendar)

        var staleOffline = plug("stale-plug", online: false)
        staleOffline.telemetryStale = true
        let realOffline = plug("real-offline-plug", online: false)

        offlineHistory.record(devices: [staleOffline, realOffline], now: date(4, 10))
        #expect(offlineHistory.offlineDays(dayCount: 7, now: date(4, 12)) == ["real-offline-plug": 1])

        let sensorHistory = SensorHistory(defaults: defaults, calendar: calendar, connectionScope: "ha:test")
        let staleSensor = SmartDevice(
            id: "sensor-1",
            name: "温湿度计",
            roomId: "r",
            roomName: "客厅",
            model: "lumi.sensor_ht.v1",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.0, humidity: 50.0, statusText: "24°C")),
            telemetryStale: true
        )
        sensorHistory.record(devices: [staleSensor], now: date(4, 10))
        let points = sensorHistory.points(forDevice: "sensor-1", window: .last24Hours, now: date(4, 10))
        #expect(points.filter(\.isObserved).isEmpty)
    }
}
