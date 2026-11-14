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

        let d = fresh()
        d.set(false, forKey: "enable_global_hotkey")
        d.set(["lamp", "fan"], forKey: "favorite_device_ids")
        #expect(HomePreferences.enableGlobalHotkey.load(from: d) == false)
        #expect(HomePreferences.favoriteDeviceIds.load(from: d) == ["lamp", "fan"])
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
        store.allowAdvancedFacetWrites = false
        #expect(HomePreferences.allowAdvancedFacetWrites.load(from: d) == false)
        store.doorbellPopupSeconds = 45
        #expect(HomePreferences.doorbellPopupSeconds.load(from: d) == 45)
    }
}
