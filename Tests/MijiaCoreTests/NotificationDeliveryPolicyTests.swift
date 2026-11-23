import Testing
@testable import MijiaCore

struct NotificationDeliveryPolicyTests {
    @Test("Hazard alerts remain time-sensitive during Focus", arguments: ["leak", "smoke", "gas"])
    func hazardAlertsKeepDeliveryPriority(kind: String) {
        let alert = SafetyAlert(id: "sensor:\(kind):device:123", deviceId: "device", title: "", body: "")

        let ordinary = NotificationDeliveryPolicy.resolve(for: .safetyAlert(alert), isFocusActive: false)
        let focused = NotificationDeliveryPolicy.resolve(for: .safetyAlert(alert), isFocusActive: true)

        #expect(focused.interruptionLevel == .timeSensitive)
        #expect(focused.relevanceScore == 1)
        #expect(focused == ordinary)
    }

    @Test("Ordinary safety alerts become passive during Focus", arguments: [
        "sensor:contact:device:123", "sensor:motion:device:123", "battery:device",
    ])
    func ordinarySafetyAlertsBecomePassive(id: String) {
        let alert = SafetyAlert(id: id, deviceId: "device", title: "", body: "")

        expectPolicy(for: .safetyAlert(alert), ordinary: .active, focused: .passive, score: 1)
    }

    @Test("Routine notifications stay in the list during Focus")
    func routineNotificationsBecomePassive() {
        expectPolicy(for: .missedTimer, ordinary: .active, focused: .passive, score: 0.7)
        expectPolicy(for: .externalAction, ordinary: .active, focused: .passive, score: 0.3)
        expectPolicy(for: .weeklyHealthReport, ordinary: .passive, focused: .passive, score: 0)
    }

    @Test("A doorbell press keeps its priority in Focus, below an alarm")
    func doorbellKeepsDeliveryPriority() {
        let withoutFocus = NotificationDeliveryPolicy.resolve(for: .doorbell, isFocusActive: false)
        let withFocus = NotificationDeliveryPolicy.resolve(for: .doorbell, isFocusActive: true)
        #expect(withoutFocus.interruptionLevel == .timeSensitive)
        #expect(withFocus.interruptionLevel == .timeSensitive)
        #expect(withoutFocus.relevanceScore == 0.9)
        #expect(withFocus.relevanceScore == 0.9)
    }

    private func expectPolicy(
        for category: NotificationCategory,
        ordinary: NotificationInterruptionLevel,
        focused: NotificationInterruptionLevel,
        score: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let withoutFocus = NotificationDeliveryPolicy.resolve(for: category, isFocusActive: false)
        let withFocus = NotificationDeliveryPolicy.resolve(for: category, isFocusActive: true)
        #expect(withoutFocus.interruptionLevel == ordinary, sourceLocation: sourceLocation)
        #expect(withFocus.interruptionLevel == focused, sourceLocation: sourceLocation)
        #expect(withoutFocus.relevanceScore == score, sourceLocation: sourceLocation)
        #expect(withFocus.relevanceScore == score, sourceLocation: sourceLocation)
    }
}
