import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #174 review: exercise the real IOKit power description path (owned vs borrowed CFDictionary)
/// and keep the battery reading range valid.
@MainActor
struct MacContextObserverTests {
    @Test("Power source read owns/releases IOKit values correctly and clamps the battery")
    func powerSourceRead() {
        let (source, percent) = MacContextObserver.readPowerState()
        #expect([MacPowerSource.ac, .battery, .unknown].contains(source))
        if let percent {
            #expect((0...100).contains(percent))
        }
    }

    @Test("Snapshot presence requires both an awake display and an unlocked on-console session")
    func snapshotPresenceRequiresUnlockedSession() {
        let unlockedSession: [String: Any] = [
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]
        let lockedSession: [String: Any] = [
            "CGSSessionScreenIsLocked": 1,
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]
        let offConsoleSession: [String: Any] = [
            "kCGSSessionOnConsoleKey": 0,
            "kCGSessionLoginDoneKey": 1
        ]

        #expect(MacContextObserver.isUserPresent(displayIsAsleep: false, session: unlockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: true, session: unlockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: lockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: offConsoleSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: nil))
    }

    @Test("Observer reconciles direct Focus A -> Focus B switches, Focus off, and unknown mode names")
    func observerReconcilesFocusTransitions() async throws {
        let suite = "test.focus.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let sleepProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠"
        )
        let workProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: false,
            focusModeName: "工作"
        )
        let unknownModeProfile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "未命名外部模式"
        )

        @MainActor
        final class FocusProbeState {
            var active: Bool?
            var result: FocusFilterQueryResult

            init(active: Bool?, result: FocusFilterQueryResult) {
                self.active = active
                self.result = result
            }
        }

        let probe = FocusProbeState(active: true, result: .active(sleepProfile))

        let observer = MacContextObserver(
            focusActiveProvider: { probe.active },
            focusFilterReader: { probe.result },
            focusFilterDefaults: defaults
        )

        let sleepSnapshot = await observer.captureSnapshot()
        #expect(sleepSnapshot.isFocusActive == true)
        #expect(sleepSnapshot.focusModeName == "睡眠")
        #expect(FocusFilterStorage.load(defaults: defaults) == sleepProfile)
        #expect(
            NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: true,
                focusFilter: FocusFilterStorage.load(defaults: defaults)
            ).isSuppressed
        )

        // 1) Direct switch: Focus A ("睡眠", quiet) -> Focus B (no MenuBarHome filter -> .notFound).
        probe.active = true
        probe.result = .notFound
        let unconfiguredFocusSnapshot = await observer.captureSnapshot()
        #expect(unconfiguredFocusSnapshot.isFocusActive == true)
        #expect(unconfiguredFocusSnapshot.focusModeName == nil)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: true,
                focusFilter: FocusFilterStorage.load(defaults: defaults)
            ).isSuppressed
        )

        // 2) Direct switch: Focus A ("睡眠", quiet) -> Focus B ("工作", loud).
        FocusFilterStorage.save(sleepProfile, defaults: defaults)
        probe.active = true
        probe.result = .active(workProfile)
        let workSnapshot = await observer.captureSnapshot()
        #expect(workSnapshot.isFocusActive == true)
        #expect(workSnapshot.focusModeName == "工作")
        #expect(FocusFilterStorage.load(defaults: defaults) == workProfile)
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: true,
                focusFilter: FocusFilterStorage.load(defaults: defaults)
            ).isSuppressed
        )

        // 3) Unknown mode name still records the mode name and never suppresses hazards/doorbell.
        probe.active = true
        probe.result = .active(unknownModeProfile)
        let unknownSnapshot = await observer.captureSnapshot()
        #expect(unknownSnapshot.focusModeName == "未命名外部模式")
        let sleepRule = AutomationRule(
            trigger: .focusModeEnabled,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(focusModeName: "睡眠")
        )
        #expect(
            MacContextAutomation.events(
                for: sleepRule,
                previous: workSnapshot,
                current: unknownSnapshot,
                at: Date()
            ).isEmpty
        )
        let hazard = SafetyAlert(id: "sensor:leak:device:1", deviceId: "device", title: "", body: "")
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .safetyAlert(hazard),
                isFocusActive: true,
                focusFilter: FocusFilterStorage.load(defaults: defaults)
            ).isSuppressed
        )
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .doorbell,
                isFocusActive: true,
                focusFilter: FocusFilterStorage.load(defaults: defaults)
            ).isSuppressed
        )

        // 4) Focus -> Off clears profile and mode name.
        probe.active = false
        probe.result = .active(sleepProfile)
        let offSnapshot = await observer.captureSnapshot()
        #expect(offSnapshot.isFocusActive == false)
        #expect(offSnapshot.focusModeName == nil)
        #expect(FocusFilterStorage.load(defaults: defaults) == .inactive)
    }
}
