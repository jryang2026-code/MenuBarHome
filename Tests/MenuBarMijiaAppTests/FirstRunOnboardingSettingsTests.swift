import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@MainActor
struct FirstRunOnboardingSettingsTests {
    @MainActor
    private final class SpyLaunchAtLoginSystem: LaunchAtLoginSystem {
        var status: LaunchAtLoginStatus = .notRegistered
        var registerCalls = 0
        var unregisterCalls = 0
        var openSettingsCalls = 0

        func register() throws {
            registerCalls += 1
            status = .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            status = .notRegistered
        }

        func openSystemSettings() {
            openSettingsCalls += 1
        }
    }

    @Test("P1-3: Settings HA save entry leaves onboarding flag and launch-at-login untouched when identity is uncertain")
    func settingsSaveGuardPreservesOnboardingAndLaunchAtLoginWhenIdentityUncertain() throws {
        // One instance for the seed, the store and the guard: a second `UserDefaults(suiteName:)`
        // reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()

        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        #expect(KeychainHelper.saveToken("existing-valid-token", defaults: defaults, vault: vault))
        defaults.set("https://existing.example.local:8123", forKey: "ha_server_url")
        // Corrupt capability selection so launch is fail-closed and has_completed_onboarding remains unset.
        defaults.set(Data("{corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)

        let loginSystem = SpyLaunchAtLoginSystem()
        let store = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: vault,
            defaults: defaults
        )
        store.launchAtLoginSystem = loginSystem
        store.toastAutoDismissInterval = nil

        #expect(store.identityMigrationDiagnostic != nil)
        #expect(defaults.object(forKey: "has_completed_onboarding") == nil)
        #expect(!store.hasCompletedOnboarding)

        // Saving through Settings' HAConnectionSaveGuard entry must not mark onboarding completed
        // or apply the launch-at-login choice while identity is uncertain.
        var tokenDraft = "new-typed-token"
        var initialLookupWasUnavailable = false
        HAConnectionSaveGuard.save(
            serverURL: "https://new.example.local:8123",
            tokenDraft: &tokenDraft,
            initialLookupWasUnavailable: &initialLookupWasUnavailable,
            in: store
        )

        #expect(defaults.object(forKey: "has_completed_onboarding") == nil, "has_completed_onboarding must stay untouched")
        #expect(!store.hasCompletedOnboarding)
        #expect(!store.hasAppliedLaunchAtLoginOnboardingChoice)
        #expect(loginSystem.registerCalls == 0, "launch-at-login must not be registered while identity is uncertain")
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "existing-valid-token")
        #expect(store.serverURLString == "https://existing.example.local:8123")

        // Calling completeOnboarding() directly while identity is uncertain must also be a no-op.
        store.completeOnboarding()
        #expect(defaults.object(forKey: "has_completed_onboarding") == nil)
        #expect(!store.hasCompletedOnboarding)
        #expect(loginSystem.registerCalls == 0)
    }
}
