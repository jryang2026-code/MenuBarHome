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

        // Mode labels trim whitespace, ignore blanks, and decode legacy profiles without the field.
        let labelled = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "  睡眠  "
        )
        #expect(labelled.focusModeName == "睡眠")
        #expect(labelled.activeFocusModeName == "睡眠")
        FocusFilterStorage.save(labelled, defaults: defaults)
        #expect(FocusFilterStorage.load(defaults: defaults) == labelled)

        let legacyData = Data(#"{"isEnabled":true,"suppressNonSafetyNotifications":true}"#.utf8)
        defaults.set(legacyData, forKey: FocusFilterStorage.key)
        #expect(FocusFilterStorage.load(defaults: defaults) == Self.quietFilter)
    }

    @Test("Direct Focus A to Focus B switch replaces or clears the previous profile without silencing hazards")
    func directFocusSwitchReconcilesProfile() async throws {
        let suite = "test.focus.reconcile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let sleepProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠"
        )
        let workLoudProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: false,
            focusModeName: "工作"
        )
        FocusFilterStorage.save(sleepProfile, defaults: defaults)

        // Focus A (quiet "睡眠") -> Focus B (no MenuBarHome filter configured): `isFocusActive` stays
        // true, `currentFilter` reports `.notFound`, and ordinary notifications are no longer silenced.
        let cleared = await FocusFilterStorage.reconcile(
            isFocusActive: true,
            currentFilter: { .notFound },
            defaults: defaults
        )
        #expect(cleared == .inactive)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: true,
                focusFilter: cleared
            ).isSuppressed
        )

        // Focus A (quiet "睡眠") -> Focus B (loud "工作"): replaces Focus A's profile directly.
        FocusFilterStorage.save(sleepProfile, defaults: defaults)
        let switchedToWork = await FocusFilterStorage.reconcile(
            isFocusActive: true,
            currentFilter: { .active(workLoudProfile) },
            defaults: defaults
        )
        #expect(switchedToWork == workLoudProfile)
        #expect(FocusFilterStorage.load(defaults: defaults) == workLoudProfile)
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .missedTimer,
                isFocusActive: true,
                focusFilter: switchedToWork
            ).isSuppressed
        )

        // Focus -> Off clears even if the system filter query would still report a stale entry.
        FocusFilterStorage.save(sleepProfile, defaults: defaults)
        let turnedOff = await FocusFilterStorage.reconcile(
            isFocusActive: false,
            currentFilter: { .active(sleepProfile) },
            defaults: defaults
        )
        #expect(turnedOff == .inactive)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)

        // Transient query error (`.unavailable`) preserves the last written profile while active.
        FocusFilterStorage.save(sleepProfile, defaults: defaults)
        let unavailable = await FocusFilterStorage.reconcile(
            isFocusActive: true,
            currentFilter: { .unavailable },
            defaults: defaults
        )
        #expect(unavailable == sleepProfile)
        #expect(FocusFilterStorage.load(defaults: defaults) == sleepProfile)

        // Hazard alerts and the doorbell are never suppressed regardless of profile or mode name.
        let hazard = SafetyAlert(id: "sensor:smoke:device:1", deviceId: "device", title: "", body: "")
        for filter in [sleepProfile, workLoudProfile, .inactive] {
            let hazardPolicy = NotificationDeliveryPolicy.resolve(
                for: .safetyAlert(hazard),
                isFocusActive: true,
                focusFilter: filter
            )
            #expect(!hazardPolicy.isSuppressed)
            #expect(hazardPolicy.interruptionLevel == .timeSensitive)

            let doorbellPolicy = NotificationDeliveryPolicy.resolve(
                for: .doorbell,
                isFocusActive: true,
                focusFilter: filter
            )
            #expect(!doorbellPolicy.isSuppressed)
            #expect(doorbellPolicy.interruptionLevel == .timeSensitive)
        }
    }

    @Test("Slow Focus filter reconciliation never overwrites a newer perform() profile write")
    func reconcileDoesNotOverwriteNewerSave() async throws {
        let suite = "test.focus.race.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠"
        )
        let newerProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: false,
            focusModeName: "工作"
        )
        FocusFilterStorage.save(oldProfile, defaults: defaults)

        let resolved = await FocusFilterStorage.reconcile(
            isFocusActive: true,
            currentFilter: {
                // Simulate `perform()` landing while `SetFocusFilterIntent.current` is in flight.
                FocusFilterStorage.save(newerProfile, defaults: defaults)
                return .notFound
            },
            defaults: defaults
        )
        #expect(resolved == newerProfile)
        #expect(FocusFilterStorage.load(defaults: defaults) == newerProfile)
    }

    @Test("Clearing empty storage advances the sequence so an older overlapping query cannot resurrect a stale profile")
    func overlappingClearPreventsStaleResurrection() async throws {
        let suite = "test.focus.emptyclear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let staleProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠"
        )

        let resolved = await FocusFilterStorage.reconcile(
            isFocusActive: true,
            currentFilter: {
                // Storage starts empty; a newer reconciliation gets `.notFound` and clears first.
                let newer = await FocusFilterStorage.reconcile(
                    isFocusActive: true,
                    currentFilter: { .notFound },
                    defaults: defaults
                )
                #expect(newer == .inactive)
                return .active(staleProfile)
            },
            defaults: defaults
        )
        #expect(resolved == .inactive)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
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
