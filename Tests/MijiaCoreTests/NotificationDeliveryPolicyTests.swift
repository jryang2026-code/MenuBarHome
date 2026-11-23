import Foundation
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

    // MARK: - Focus filters (#575)

    private static let quietFilter = FocusFilterProfile(isEnabled: true, suppressNonSafetyNotifications: true)

    @Test("Hazard alerts are never suppressed by a Focus filter", arguments: ["leak", "smoke", "gas"])
    func focusFilterNeverSilencesHazards(kind: String) {
        let alert = SafetyAlert(id: "sensor:\(kind):device:123", deviceId: "device", title: "", body: "")

        for filter in [Self.quietFilter, FocusFilterProfile(isEnabled: true, suppressNonSafetyNotifications: true)] {
            for isFocusActive in [false, true] {
                let policy = NotificationDeliveryPolicy.resolve(
                    for: .safetyAlert(alert),
                    isFocusActive: isFocusActive,
                    focusFilter: filter
                )
                #expect(policy.isSuppressed == false)
                #expect(policy.interruptionLevel == .timeSensitive)
            }
        }
    }

    @Test("Ordinary safety alerts stay in the list under a quiet Focus filter", arguments: [
        "sensor:contact:device:123", "sensor:motion:device:123", "battery:device", "offline:device",
    ])
    func focusFilterNeverDropsOrdinarySafetyAlerts(id: String) {
        let alert = SafetyAlert(id: id, deviceId: "device", title: "", body: "")
        let policy = NotificationDeliveryPolicy.resolve(
            for: .safetyAlert(alert),
            isFocusActive: true,
            focusFilter: Self.quietFilter
        )
        #expect(policy.isSuppressed == false)
        // Focus still quiets it; the filter may not remove it.
        #expect(policy.interruptionLevel == .passive)
    }

    @Test("A ringing doorbell is never suppressed by a Focus filter")
    func focusFilterNeverSilencesTheDoorbell() {
        let policy = NotificationDeliveryPolicy.resolve(
            for: .doorbell,
            isFocusActive: true,
            focusFilter: Self.quietFilter
        )
        #expect(policy.isSuppressed == false)
        #expect(policy.interruptionLevel == .timeSensitive)
    }

    @Test("A quiet Focus filter suppresses ordinary notifications")
    func quietFilterSuppressesOrdinaryNotifications() {
        let categories: [(NotificationCategory, Double)] = [
            (.missedTimer, 0.7),
            (.externalAction, 0.3),
            (.weeklyHealthReport, 0),
        ]
        for (category, score) in categories {
            let policy = NotificationDeliveryPolicy.resolve(
                for: category,
                isFocusActive: true,
                focusFilter: Self.quietFilter
            )
            #expect(policy.isSuppressed)
            #expect(policy.interruptionLevel == .passive)
            #expect(policy.relevanceScore == score)
        }
    }

    @Test("Suppression needs an active Focus, not just a stored filter")
    func suppressionNeedsFocus() {
        let noFocus = NotificationDeliveryPolicy.resolve(
            for: .externalAction,
            isFocusActive: false,
            focusFilter: Self.quietFilter
        )
        #expect(noFocus.isSuppressed == false)
        #expect(noFocus.interruptionLevel == .active)

        let unknownFocus = NotificationDeliveryPolicy.resolve(
            for: .externalAction,
            isFocusActive: false,
            focusFilter: FocusFilterProfile(isEnabled: true, suppressNonSafetyNotifications: true)
        )
        #expect(unknownFocus.isSuppressed == false)
    }

    @Test("A filter that does not ask for silence changes nothing")
    func loudFilterKeepsOrdinaryDelivery() {
        let filter = FocusFilterProfile(isEnabled: true, suppressNonSafetyNotifications: false)
        let policy = NotificationDeliveryPolicy.resolve(
            for: .missedTimer,
            isFocusActive: true,
            focusFilter: filter
        )
        #expect(policy.isSuppressed == false)
        #expect(policy.interruptionLevel == .passive)
    }

    @Test("A Focus filter profile round-trips through UserDefaults and clears to inactive")
    func profileStorage() throws {
        let suite = "test.focus.filter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
        FocusFilterStorage.save(Self.quietFilter, defaults: defaults)
        #expect(FocusFilterStorage.load(defaults: defaults) == Self.quietFilter)

        FocusFilterStorage.clear(defaults: defaults)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
        // Saving the inactive profile never leaves a stale record behind.
        FocusFilterStorage.save(Self.quietFilter, defaults: defaults)
        FocusFilterStorage.save(.inactive, defaults: defaults)
        #expect(defaults.data(forKey: FocusFilterStorage.key) == nil)
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
