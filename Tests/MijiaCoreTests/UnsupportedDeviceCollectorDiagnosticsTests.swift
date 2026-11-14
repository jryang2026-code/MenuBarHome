import Foundation
import Testing
@testable import MijiaCore

/// #17: "复制诊断信息" carries a local crash count and the latest crash day. The file filter decides
/// what counts, and the rendered report contains neither a file name nor a path.
struct UnsupportedDeviceCollectorDiagnosticsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func stamp(_ name: String, daysAgo: Double) -> DiagnosticsReportBuilder.CrashReportStamp {
        DiagnosticsReportBuilder.CrashReportStamp(
            fileName: name,
            modifiedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
        )
    }

    private static func input(crashes: [Date]) -> DiagnosticsReportBuilder.Input {
        DiagnosticsReportBuilder.Input(
            appVersion: "1.0.6",
            buildNumber: "42",
            macOSVersion: "Version 14.5.0 (Build 23F79)",
            backendTitle: "Demo",
            miCloudRegion: "-",
            deviceCount: 0,
            onlineDeviceCount: 0,
            hiddenDeviceCount: 0,
            models: [],
            recentCrashTimestamps: crashes
        )
    }

    /// Lines under the crash heading, so an assertion cannot accidentally match another section.
    private static func crashSection(_ report: String) -> String {
        let header = "### " + L10n.tr("本地崩溃", "Local Crashes")
        guard let start = report.range(of: header)?.upperBound else { return "" }
        let tail = report[start...]
        let end = tail.range(of: "\n\n")?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    @Test("Only this app's .ips and .crash files inside the window count as crashes")
    func crashTimestampsFilterNamesAndWindow() {
        let timestamps = DiagnosticsReportBuilder.crashTimestamps(
            from: [
                Self.stamp("MenuBarMijia-2026-11-05-101010.ips", daysAgo: 1),
                Self.stamp("MenuBarMijiaApp-2026-11-04-101010.ips", daysAgo: 3),
                Self.stamp("MenuBarMijia-2026-11-01-101010.crash", daysAgo: 6),
                Self.stamp("MenuBarMijia-2026-11-02-101010.IPS", daysAgo: 2),
                Self.stamp("MenuBarMijia-2026-10-20-101010.ips", daysAgo: 8),
                Self.stamp("MenuBarMijia-2026-11-06-101010.txt", daysAgo: 1),
                Self.stamp("OtherApp-2026-11-05-101010.ips", daysAgo: 1),
                Self.stamp("MenuBarMijia-2026-11-07-101010.ips", daysAgo: -1)
            ],
            now: Self.now
        )

        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.count == 4)
        #expect(!timestamps.contains(Self.now.addingTimeInterval(-8 * 86_400)))
        #expect(timestamps.last == Self.now.addingTimeInterval(-86_400))
    }

    @Test("The report shows the crash count and latest day, and no file name or path")
    func crashSectionRendering() throws {
        let latest = try Self.localNoon(year: 2026, month: 11, day: 5)
        let now = latest.addingTimeInterval(2 * 3600)
        let report = DiagnosticsReportBuilder.markdown(
            Self.input(crashes: [
                latest.addingTimeInterval(-30 * 86_400),
                latest,
                latest.addingTimeInterval(-3600)
            ]),
            now: now
        )

        let section = Self.crashSection(report)
        #expect(section.contains("2"))
        #expect(section.contains("2026-11-05"))
        #expect(!section.contains("2026-10-06"))
        #expect(!report.contains(".ips"))
        #expect(!report.contains("/Users/"))
    }

    @Test("No local crashes render as a zero count")
    func crashSectionZero() {
        let report = DiagnosticsReportBuilder.markdown(Self.input(crashes: []), now: Self.now)

        #expect(Self.crashSection(report).contains("0"))
    }
}
