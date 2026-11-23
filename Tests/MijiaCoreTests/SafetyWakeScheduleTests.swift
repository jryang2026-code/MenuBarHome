import Foundation
import Testing
@testable import MijiaCore

struct SafetyWakeScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func idleHasNoWake() {
        #expect(nextSafetyWake(now: now, alertCheck: nil, weeklyReport: nil, updateCheck: nil) == nil)
    }

    @Test func earliestDeadlineWinsAndAnOverdueAlertRunsImmediately() {
        let nextAlert = now + 90
        #expect(nextSafetyWake(
            now: now, alertCheck: nextAlert, weeklyReport: now + 180, updateCheck: now + 120
        ) == nextAlert)
        #expect(nextSafetyWake(
            now: now, alertCheck: now - 1, weeklyReport: now + 180, updateCheck: now + 120
        ) == now)
    }

    @Test(arguments: SafetyWakeEvent.allCases)
    func systemEventForcesImmediateReevaluation(event: SafetyWakeEvent) {
        #expect(nextSafetyWake(
            now: now, alertCheck: now + 3600, weeklyReport: now + 7200, updateCheck: now + 60, event: event
        ) == now)
        #expect(nextSafetyWake(
            now: now, alertCheck: nil, weeklyReport: nil, updateCheck: nil, event: event
        ) == now)

        let fireDate = now - 61
        #expect(event.rearmedCommandDelay(now: now, fireDate: fireDate) == 0)
        #expect(scheduledCommandIsMissed(now: now, fireDate: fireDate))
        #expect(!scheduledCommandIsMissed(now: now, fireDate: now - 60))
    }

    @Test func backwardClockChangeRearmsAtOriginalWallTime() {
        let fireDate = now + 90
        #expect(SafetyWakeEvent.clockChanged.rearmedCommandDelay(now: now, fireDate: fireDate) == 90)
        #expect(SafetyWakeEvent.systemWake.rearmedCommandDelay(now: now, fireDate: fireDate) == nil)
        #expect(SafetyWakeEvent.timeZoneChanged.rearmedCommandDelay(now: now, fireDate: fireDate) == nil)
    }
}
