import Foundation
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@Suite("Sensor hover sparkline", .timeLimit(.minutes(1)))
struct SensorSparklineTests {
    private static func makePoints(
        temperatures: [Double?],
        humidities: [Double?]? = nil,
        anchor: Date = Date(timeIntervalSince1970: 1_764_000_000)
    ) -> [SensorHistoryPoint] {
        temperatures.enumerated().map { idx, temp in
            let hum = humidities?[idx]
            return SensorHistoryPoint(
                bucketStart: anchor.addingTimeInterval(Double(idx) * 3600),
                temperature: temp,
                humidity: hum
            )
        }
    }

    @Test("numericMinRange prevents minor 1-degree fluctuations from exaggerating into full-height teeth")
    func numericMinRangeAntiJitter() throws {
        var temps: [Double?] = Array(repeating: nil, count: 24)
        temps[20] = 22.0
        temps[21] = 22.4
        temps[22] = 22.1
        temps[23] = 22.8
        let points = Self.makePoints(temperatures: temps)

        let layout = try #require(
            SensorSparklineModel.compute(
                points: points,
                metric: .temperature,
                size: CGSize(width: 116, height: 22),
                padding: 2
            )
        )
        #expect(layout.observedCount == 4)
        #expect(layout.slotCount == 24)
        #expect(layout.yMax - layout.yMin >= 5.0)
        #expect(layout.observedMin == 22.0)
        #expect(layout.observedMax == 22.8)
        #expect(layout.latest == 22.8)

        let ys = layout.coords.map(\.y)
        let renderedSpan = (ys.max() ?? 0) - (ys.min() ?? 0)
        // With 0.8 C change against a 5.0 C minimum range on an 18pt inner height, vertical travel
        // stays calm (~2.9pt) rather than snapping top-to-bottom.
        #expect(renderedSpan < 4.0)
        #expect(renderedSpan > 1.0)
    }

    @Test("humidity bounds clamp inside 0...100 while preserving min range")
    func humidityBoundsClamp() throws {
        var hums: [Double?] = Array(repeating: nil, count: 24)
        hums[22] = 97.0
        hums[23] = 99.0
        let points = Self.makePoints(temperatures: Array(repeating: nil, count: 24), humidities: hums)

        let layout = try #require(
            SensorSparklineModel.compute(
                points: points,
                metric: .humidity,
                size: CGSize(width: 116, height: 22)
            )
        )
        #expect(layout.yMin >= 0)
        #expect(layout.yMax <= 100)
        #expect(layout.yMax - layout.yMin >= 10.0)
    }

    @Test("empty history returns nil and single-point history returns 1 coordinate")
    func emptyAndSinglePoint() throws {
        let empty = Self.makePoints(temperatures: Array(repeating: nil, count: 24))
        #expect(SensorSparklineModel.compute(points: empty, metric: .temperature, size: CGSize(width: 100, height: 20)) == nil)
        #expect(SensorSparklineModel.preferredMetric(for: empty, requested: .temperature) == nil)

        var single: [Double?] = Array(repeating: nil, count: 24)
        single[23] = 24.5
        let onePt = Self.makePoints(temperatures: single)
        let layout = try #require(
            SensorSparklineModel.compute(points: onePt, metric: .temperature, size: CGSize(width: 100, height: 20))
        )
        #expect(layout.coords.count == 1)
        #expect(layout.latest == 24.5)
    }

    @Test("preferredMetric falls back to available metric and formats range label cleanly")
    func preferredMetricAndRangeLabel() throws {
        var hums: [Double?] = Array(repeating: nil, count: 24)
        hums[10] = 44.0
        hums[23] = 56.0
        let humOnly = Self.makePoints(temperatures: Array(repeating: nil, count: 24), humidities: hums)
        #expect(SensorSparklineModel.preferredMetric(for: humOnly, requested: .temperature) == .humidity)

        let layout = try #require(
            SensorSparklineModel.compute(points: humOnly, metric: .humidity, size: CGSize(width: 116, height: 22))
        )
        #expect(SensorSparklineModel.rangeLabel(layout: layout) == "44–56%")
    }

    @Test("display-only: reading 24h sparkline points never sets cloud loading or triggers fetches")
    @MainActor
    func displayOnlyNeverFetchesCloud() {
        let suite = "SensorSparklineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let history = SensorHistory(defaults: defaults, connectionScope: "demo")
        let sensor = SmartDevice(
            id: "sensor.living",
            name: "客厅温湿度计",
            roomId: "living",
            roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 23.4, humidity: 51))
        )
        history.record(devices: [sensor], now: now.addingTimeInterval(-3600))
        let sensor2 = SmartDevice(
            id: "sensor.living",
            name: "客厅温湿度计",
            roomId: "living",
            roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.1, humidity: 53))
        )
        history.record(devices: [sensor2], now: now)

        let pts = history.points(forDevice: sensor.id, window: .last24Hours, now: now)
        let layout = SensorSparklineModel.compute(points: pts, metric: .temperature, size: CGSize(width: 116, height: 22))
        #expect(layout?.observedCount == 2)
        #expect(history.isLoading(deviceId: sensor.id, window: .last24Hours) == false)
        #expect(history.hasCloudHistory(forDevice: sensor.id) == false)
    }
}
