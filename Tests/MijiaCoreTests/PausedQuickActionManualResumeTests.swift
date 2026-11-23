import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// Audit follow-up of #389: the fail-safe that keeps a paused group bound to the HA server it lost
/// must not leave users without a way out. A pause marker written before #389 can have no scope at
/// all, so auto-resume never clears it; these tests pin the manual path next to that fail-safe.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PausedQuickActionManualResumeTests {
    private static let haURL = "http://192.168.1.50:8123"
    private static let haToken = "ha-token-manual-resume"
    private static let light = SmartDevice(
        id: "ha-light", name: "Hall", roomId: "hall", roomName: "Hall",
        model: "ha.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.hall", isOn: true))
    )

    /// Seeds what a release before #389 persisted: a paused group with no scope, a device group
    /// preference that still lists its member, and a live HA snapshot so the member is available.
    private static func makeStore(
        defaults: InMemoryUserDefaults, pausedIDs: [String] = ["group:hall"]
    ) async throws -> HomeStore {
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken(haToken, defaults: defaults, vault: vault)
        defaults.set(#"[{"id":"hall","name":"Hall"}]"#, forKey: "device_groups")
        defaults.set("{\"\(light.id)\":\"hall\"}", forKey: ViewPreferenceKeys.groupMap)
        defaults.set(pausedIDs, forKey: HomeStore.pausedQuickActionsKey)
        var snapshot = SynthesizedHome(devices: [light])
        snapshot.isInitialLoadComplete = true
        let store = HomeStore(provider: MockHomeProvider(snapshot: snapshot), credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil
        return store
    }

    @Test("A group paused before #389 stays paused and names the manual resume")
    func legacyEmptyScopeGroupStaysPaused() async throws {
        let store = try await Self.makeStore(defaults: InMemoryUserDefaults())

        store.revalidatePausedItems()

        // Fail-safe first: no scope means no proof which HA server it was paused for.
        #expect(store.pausedQuickActionIDs.contains("group:hall"))
        #expect(store.pausedQuickActionRequiresManualResume("group:hall"))
        #expect(store.pausedQuickActionsRequiringManualResume.map(\.id) == ["group:hall"])
        #expect(store.pausedQuickActionsRequiringManualResume.first?.title == "Hall")
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.pausedQuickActionMessage(forPausedID: "group:hall", title: "Hall").contains("手动恢复"))
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(store.pausedQuickActionMessage(forPausedID: "group:hall", title: "Hall").contains("manually"))
        }
    }

    @Test("Manual resume releases a legacy group and clears its pause markers")
    func manualResumeClearsLegacyPause() async throws {
        let defaults = InMemoryUserDefaults()
        let store = try await Self.makeStore(defaults: defaults)
        #expect(store.pausedQuickActionRequiresManualResume("group:hall"))

        #expect(store.resumePausedQuickAction(id: "group:hall"))

        #expect(!store.pausedQuickActionIDs.contains("group:hall"))
        #expect(store.pausedQuickActionScopes["group:hall"] == nil)
        #expect(store.pausedQuickActionsRequiringManualResume.isEmpty)
        #expect(defaults.stringArray(forKey: HomeStore.pausedQuickActionsKey) == nil)
    }

    @Test("Manual resume keeps the pause while a group member is still unavailable")
    func manualResumeRefusesUnavailableMembers() async throws {
        let store = try await Self.makeStore(defaults: InMemoryUserDefaults())
        // Closing the light type hides the only member: the same availability rule auto-resume uses.
        let picked = Set(DeviceCategoryID.allCases).subtracting([.light])
        let preview = store.previewDeviceCategorySelection(picked)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true,
            expectedPauseItemKeys: preview.pauseItemKeys, expectedGeneration: preview.generation
        ) == .applied)

        #expect(!store.resumePausedQuickAction(id: "group:hall"))

        #expect(store.pausedQuickActionIDs.contains("group:hall"))
        #expect(store.toastNotice?.isError == true)
    }

    @Test("A rule paused for HA without its ha scope stays paused and reports the manual switch")
    func legacyRuleReportsManualSwitch() async throws {
        let store = try await Self.makeStore(defaults: InMemoryUserDefaults(), pausedIDs: [])
        let rule = AutomationRule(
            trigger: .away, action: .devices(ids: [Self.light.id], isOn: false), isEnabled: false,
            pausedCapabilities: [.connection(.homeAssistant)]
        )
        store.automationRuleStore.save([rule])

        store.revalidatePausedItems()

        let stored = try #require(store.automationRuleStore.load().first)
        #expect(!stored.isEnabled)
        #expect(store.pausedRuleRequiresManualResume(stored))
        // The settings switch clears the markers itself, so an enabled rule is never "manual".
        #expect(!store.pausedRuleRequiresManualResume(AutomationRule(
            trigger: .away, action: .devices(ids: [Self.light.id], isOn: false), isEnabled: true,
            pausedCapabilities: [.connection(.homeAssistant)]
        )))
    }
}
