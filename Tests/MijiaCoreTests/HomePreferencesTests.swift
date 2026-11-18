import Foundation
import Testing
@testable import MijiaCore

/// Every persisted setting has one key, one default and one coding.
@MainActor
struct HomePreferencesTests {
    private func fresh() -> UserDefaults {
        UserDefaults(suiteName: "test.prefs.\(UUID().uuidString)")!
    }

    @Test("Keys stay the ones earlier builds wrote, so saved settings survive the update")
    func legacyKeys() {
        #expect(HomePreferences.hideOfflineDevices.key == "hide_offline_devices")
        #expect(HomePreferences.isCompactGridMode.key == "compact_grid_mode")
        #expect(HomePreferences.enableWeeklyHealthReport.key == "weekly_health_report_enabled_v1")
        #expect(HomePreferences.sensorAlertsOnlyWhenAway.key == "safety_alert_only_when_away_v1")
        #expect(HomePreferences.doorbellPopupSeconds.key == "doorbell_popup_seconds")
        #expect(HomePreferences.menuBarTargetId.key == "menubar_target_id")
        #expect(HomePreferences.favoriteDeviceIds.key == "favorite_device_ids")
        #expect(HomePreferences.homeName.key == "home_name")
        #expect(HomePreferences.enableVoiceInput.key == "enable_voice_input")

        let d = fresh()
        d.set(false, forKey: "enable_global_hotkey")
        d.set(["lamp", "fan"], forKey: "favorite_device_ids")
        #expect(HomePreferences.enableGlobalHotkey.load(from: d) == false)
        #expect(HomePreferences.favoriteDeviceIds.load(from: d) == ["lamp", "fan"])
        #expect(HomePreferences.enableVoiceInput.load(from: d) == true)
    }

    @Test("The store loads and saves through the same table")
    func storeUsesTable() async throws {
        let suite = "test.prefs.store.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.set(false, forKey: "show_quick_actions_bar")
        d.set(true, forKey: "allow_advanced_facet_writes")
        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])), defaultsSuiteName: suite)
        #expect(store.showQuickActionsBar == false)
        #expect(store.allowAdvancedFacetWrites)
        #expect(store.enableVoiceInput == true)
        store.allowAdvancedFacetWrites = false
        #expect(HomePreferences.allowAdvancedFacetWrites.load(from: d) == false)
        store.doorbellPopupSeconds = 45
        #expect(HomePreferences.doorbellPopupSeconds.load(from: d) == 45)
    }

    @Test("Legacy defaults keep voice input enabled and preserve existing settings; toggling notifies observers and gates voice assistant requests")
    func voiceInputPreferenceMigrationAndAssistantGating() async throws {
        let suite = "test.prefs.voice.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let d = UserDefaults(suiteName: suite)!
        d.set("老用户的家", forKey: "home_name")
        d.set(["living_light"], forKey: "favorite_device_ids")

        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])), defaultsSuiteName: suite)
        #expect(store.enableVoiceInput == true, "Legacy users without enable_voice_input must keep voice input enabled by default")
        #expect(store.homeName == "老用户的家")
        #expect(store.favoriteDeviceIds == ["living_light"])

        var observedChanges: [Bool] = []
        let token = store.addVoiceInputPreferenceObserver { enabled in
            observedChanges.append(enabled)
        }
        defer { store.removeVoiceInputPreferenceObserver(token) }

        store.presentAssistantBar(startVoice: true)
        #expect(store.isShowingAssistantBar)
        #expect(store.assistantVoiceRequest == 1)

        store.enableVoiceInput = false
        #expect(HomePreferences.enableVoiceInput.load(from: d) == false)
        #expect(observedChanges == [false])
        #expect(store.homeName == "老用户的家", "Toggling voice input must not clobber other persisted settings")
        #expect(store.favoriteDeviceIds == ["living_light"])

        let previousVoiceRequest = store.assistantVoiceRequest
        let previousFocusRequest = store.assistantFocusRequest
        store.presentAssistantBar(startVoice: true)
        #expect(store.assistantVoiceRequest == previousVoiceRequest, "Voice requests must not fire while voice input is disabled")
        #expect(store.assistantFocusRequest == previousFocusRequest &+ 1, "Text focus still works when voice input is disabled")

        store.enableVoiceInput = true
        #expect(HomePreferences.enableVoiceInput.load(from: d) == true)
        #expect(observedChanges == [false, true])
        store.presentAssistantBar(startVoice: true)
        #expect(store.assistantVoiceRequest == previousVoiceRequest &+ 1)
    }
}

