import Foundation
import Testing
@testable import MijiaCore

/// Time windows: the "only run at night" half of a rule, and the boundaries that decide whether a
/// sleepy user's 22:00 window turns the heater off at 21:59 or not.
struct AutomationTimeWindowTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 12
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: Disabled

    @Test func disabledWindowAlwaysPasses() {
        let window = AutomationTimeWindow(isEnabled: false, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(window.contains(date(hour: 3), calendar: calendar))
        #expect(window.contains(date(hour: 12), calendar: calendar))
        #expect(window.contains(date(hour: 22), calendar: calendar))
    }

    // MARK: Same-day window

    @Test func sameDayWindowIncludesStartAndExcludesEnd() {
        let window = AutomationTimeWindow(isEnabled: true, startMinute: 9 * 60, endMinute: 18 * 60)
        #expect(window.contains(date(hour: 9, minute: 0), calendar: calendar))
        #expect(window.contains(date(hour: 12), calendar: calendar))
        #expect(window.contains(date(hour: 17, minute: 59), calendar: calendar))
        // End is exclusive, so the boundary itself already belongs to the next window.
        #expect(!window.contains(date(hour: 18, minute: 0), calendar: calendar))
        #expect(!window.contains(date(hour: 8, minute: 59), calendar: calendar))
    }

    // MARK: Overnight window

    @Test func overnightWindowWrapsPastMidnight() {
        let window = AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(window.contains(date(hour: 22, minute: 0), calendar: calendar))
        #expect(window.contains(date(hour: 23, minute: 30), calendar: calendar))
        #expect(window.contains(date(hour: 0, minute: 0), calendar: calendar))
        #expect(window.contains(date(hour: 6, minute: 59), calendar: calendar))
        #expect(!window.contains(date(hour: 7, minute: 0), calendar: calendar))
        #expect(!window.contains(date(hour: 12), calendar: calendar))
        #expect(!window.contains(date(hour: 21, minute: 59), calendar: calendar))
    }

    // MARK: Edge cases

    @Test func equalEndsMeanAllDayRatherThanNever() {
        let window = AutomationTimeWindow(isEnabled: true, startMinute: 8 * 60, endMinute: 8 * 60)
        // Silently disabling the rule would be worse than treating it as "the whole day".
        #expect(window.contains(date(hour: 0), calendar: calendar))
        #expect(window.contains(date(hour: 8), calendar: calendar))
        #expect(window.contains(date(hour: 20), calendar: calendar))
    }

    @Test func minutesAreClampedToADay() {
        let window = AutomationTimeWindow(isEnabled: true, startMinute: 5_000, endMinute: -20)
        #expect(window.startMinute == 24 * 60 - 1)
        #expect(window.endMinute == 0)
    }

    @Test func summaryReadsAsAClockRange() {
        let window = AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(window.summary == "22:00–07:00")
    }

    // MARK: Persistence

    @Test func conditionsRoundTripThroughJSON() throws {
        let rule = AutomationRule(
            trigger: .back,
            action: .quickAction(.lightsOff),
            conditions: AutomationConditions(
                wifi: .inAny(["Home"]),
                timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
            )
        )
        let decoded = try JSONDecoder().decode(
            AutomationRule.self,
            from: try JSONEncoder().encode(rule)
        )
        #expect(decoded == rule)
        #expect(decoded.conditions.timeWindow.isEnabled)
        #expect(decoded.conditions.timeWindow.startMinute == 22 * 60)
    }

    @Test func ruleStoredBeforeTimeWindowsDecodesAsAnytime() throws {
        // A rule persisted before this feature has neither `timeWindow` nor any time key at all.
        let legacy = """
        {
          "id": "9F1F0D3C-8E1B-4A55-9C0E-1B2C3D4E5F60",
          "isEnabled": true,
          "trigger": "away",
          "action": { "kind": "quickAction", "quickAction": "lightsOff" },
          "triggerOptions": { "batteryThresholdPercent": 20, "lateNightStartHour": 23, "lateNightEndHour": 6, "calendarLeadMinutes": 1 },
          "conditions": { "wifi": { "kind": "any", "ssids": [] } }
        }
        """
        let rule = try JSONDecoder().decode(AutomationRule.self, from: Data(legacy.utf8))
        #expect(rule.conditions.timeWindow == .anytime)
        #expect(rule.conditions.isWithinTimeWindow(at: date(hour: 3), calendar: calendar))
    }

    // MARK: Summary

    @Test func summaryMentionsBothConditions() {
        let conditions = AutomationConditions(
            wifi: .inAny(["Home"]),
            timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        )
        let summary = conditions.summary() ?? ""
        #expect(summary.contains("Home"))
        #expect(summary.contains("22:00–07:00"))

        let timeOnly = AutomationConditions(
            timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        )
        #expect(timeOnly.summary()?.contains("22:00–07:00") == true)
        #expect(AutomationConditions().summary() == nil)
    }

    @Test func windowIsEvaluatedAgainstTheTriggerTimestamp() {
        // The sleep trigger is held for two seconds; the verdict must use the trigger's own time,
        // not the moment the pipeline happens to resume.
        let conditions = AutomationConditions(
            timeWindow: AutomationTimeWindow(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        )
        #expect(conditions.isWithinTimeWindow(at: date(hour: 23, minute: 59), calendar: calendar))
        #expect(!conditions.isWithinTimeWindow(at: date(hour: 7, minute: 0), calendar: calendar))
    }
}
