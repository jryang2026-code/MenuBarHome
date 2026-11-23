import Foundation
import Testing
@testable import MijiaCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
    return calendar
}()

/// 2026-11-01 is a Sunday.
private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
}

/// #182: the weekly report goes out once, Sunday evening, and never as a stale mid-week catch-up.
struct WeeklyHealthReportScheduleTests {
    @Test("The report is due from Sunday 20:00 until it has been delivered")
    func dueOnSundayEvening() {
        #expect(!WeeklyHealthReportSchedule.isDue(now: date(1, 19, 59), lastDeliveredAt: nil, calendar: calendar))
        #expect(WeeklyHealthReportSchedule.isDue(now: date(1, 20), lastDeliveredAt: nil, calendar: calendar))
        #expect(!WeeklyHealthReportSchedule.isDue(now: date(1, 21), lastDeliveredAt: date(1, 20, 1), calendar: calendar))
    }

    @Test("A Mac asleep on Sunday still gets the report on Monday, but not by Wednesday")
    func catchUpWindow() {
        #expect(WeeklyHealthReportSchedule.isDue(now: date(2, 9), lastDeliveredAt: nil, calendar: calendar))
        #expect(!WeeklyHealthReportSchedule.isDue(now: date(4, 9), lastDeliveredAt: nil, calendar: calendar))
    }

    @Test("Last week's delivery does not block this week's report")
    func nextWeek() {
        #expect(WeeklyHealthReportSchedule.isDue(now: date(8, 20, 30), lastDeliveredAt: date(1, 20, 1), calendar: calendar))
    }

    @Test func nextCheckUsesCurrentLocalSlotAndCatchUpWindow() {
        let slot = date(1, 20)
        let monday = date(2, 9)
        #expect(WeeklyHealthReportSchedule.nextCheck(now: slot - 0.25, lastDeliveredAt: nil, calendar: calendar) == slot)
        #expect(WeeklyHealthReportSchedule.nextCheck(now: monday, lastDeliveredAt: nil, calendar: calendar) == monday)
        #expect(WeeklyHealthReportSchedule.nextCheck(now: monday, lastDeliveredAt: slot, calendar: calendar) == date(8, 20))
        #expect(WeeklyHealthReportSchedule.nextCheck(now: date(4, 9), lastDeliveredAt: nil, calendar: calendar) == date(8, 20))

        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(WeeklyHealthReportSchedule.nextCheck(now: slot, lastDeliveredAt: nil, calendar: shifted) == slot + 8 * 3600)
    }

    @MainActor
    @Test("The store hands out a due report once, and only while the weekly report is on")
    func storeDeliversOnce() async throws {
        let suite = "weekly-report-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        let sunday = date(1, 20, 5)

        #expect(store.enableWeeklyHealthReport == false)
        #expect(store.takeDueWeeklyHealthReport(now: sunday, calendar: calendar) == nil)

        store.enableWeeklyHealthReport = true
        #expect(store.takeDueWeeklyHealthReport(now: sunday, calendar: calendar) != nil)
        #expect(store.takeDueWeeklyHealthReport(now: sunday.addingTimeInterval(60), calendar: calendar) == nil)

        let reloaded = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        #expect(reloaded.enableWeeklyHealthReport)
        #expect(reloaded.takeDueWeeklyHealthReport(now: sunday.addingTimeInterval(120), calendar: calendar) == nil)
    }
}
