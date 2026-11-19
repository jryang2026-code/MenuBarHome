import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

struct FirstRunOnboardingTests {
    private final class ToggleableVaultBox: @unchecked Sendable {
        var failReads: Bool = false
        var blob: Data?

        var storage: CredentialVault.Storage {
            CredentialVault.Storage(
                read: {
                    if self.failReads { return .unavailable }
                    return self.blob.map(CredentialVault.Storage.ReadResult.found) ?? .notFound
                },
                write: { data in
                    self.blob = data
                    return true
                }
            )
        }
    }

    private final class RequestCounter: @unchecked Sendable {
        var requests: Int = 0
    }

    @MainActor
    private static func makeFreshSuite(_ name: String) throws -> (suite: String, defaults: UserDefaults) {
        let suite = "test.p4a.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (suite, defaults)
    }

    private static let stubMiFactory: @MainActor ([MiAccount]) -> MiAccountsProvider = { _ in
        MiAccountsProvider(
            accounts: [],
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            followUpDelay: .seconds(3600)
        )
    }

    private static let stubHAFactory: @MainActor (String, String) -> any HomeProvider = { _, _ in
        MockHomeProvider()
    }

    @Test("Fresh install does zero background/LAN/update work and keeps onboarding open across relaunch")
    @MainActor
    func freshInstallZeroBackgroundWorkAndRelaunch() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("fresh")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let counter = RequestCounter()

        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        var driver = UpdateSystemDriver.live
        driver.fetchData = { _ in
            counter.requests += 1
            throw URLError(.notConnectedToInternet)
        }
        store.updater = AppUpdater(currentVersion: "1.0.0", driver: driver)

        let expectedFresh = CapabilityReferenceEngine.resolveInstallSelection(
            evidence: CapabilityInstallEvidence(),
            manifest: .shared
        ).selection
        #expect(store.capabilityResolutionMode == .freshInstall)
        #expect(store.showsFullOnboardingGuide)
        #expect(store.shouldShowOnboarding)
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)
        #expect(!store.isDiscoveringHA)
        #expect(store.discoveredHAInstances.isEmpty)
        #expect(store.shouldSuppressBackgroundNetworkWork)
        #expect(store.capabilitySelection.enabledCategories == expectedFresh.enabledCategories)

        await store.checkForUpdatesIfNeeded()
        #expect(counter.requests == 0, "unconnected fresh install must not auto-check for updates")

        // Second launch before connecting or skipping still opens first-run onboarding.
        let relaunched = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(relaunched.showsFullOnboardingGuide)
        #expect(!relaunched.shouldAutoDiscoverHomeAssistantOnLAN)
        #expect(relaunched.shouldSuppressBackgroundNetworkWork)

        // Skipping closes onboarding; reopening brings the full guide back.
        relaunched.finishOnboardingGuide()
        #expect(relaunched.hasCompletedOnboarding)
        #expect(!relaunched.showsFullOnboardingGuide)
        relaunched.reopenOnboarding()
        #expect(relaunched.showsFullOnboardingGuide)
    }

    @Test("Legacy users (demo-only, capability-selection-only, or existing account) do not pop onboarding")
    @MainActor
    func legacyUsersMigrateSilentlyWithoutOnboarding() throws {
        // 1. Demo-only legacy user
        do {
            let (suite, defaults) = try Self.makeFreshSuite("legacy-demo")
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            let store = HomeStore(
                defaultsSuiteName: suite,
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory
            )
            #expect(store.capabilityResolutionMode == .legacyPreserved)
            #expect(store.homeBackend == .demo)
            #expect(store.hasCompletedOnboarding)
            #expect(!store.showsFullOnboardingGuide)
            #expect(!store.shouldShowOnboarding)
        }

        // 2. Capability-selection-only record
        do {
            let (suite, defaults) = try Self.makeFreshSuite("legacy-caps")
            defer { defaults.removePersistentDomain(forName: suite) }
            let fresh = CapabilityReferenceEngine.resolveInstallSelection(
                evidence: CapabilityInstallEvidence(),
                manifest: .shared
            ).selection
            #expect(CapabilitySelectionStore.save(
                selection: fresh,
                configuredScopes: [],
                defaults: defaults
            ))
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            let store = HomeStore(
                defaultsSuiteName: suite,
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory
            )
            #expect(store.capabilityResolutionMode == .explicit)
            #expect(store.hasCompletedOnboarding)
            #expect(!store.showsFullOnboardingGuide)
            #expect(!store.shouldShowOnboarding)
        }

        // 3. Existing Mi session without has_completed_onboarding
        do {
            let (suite, defaults) = try Self.makeFreshSuite("legacy-mi")
            defer { defaults.removePersistentDomain(forName: suite) }
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            let session = MiSession(
                userId: "99100", cUserId: "c", ssecurity: "s", serviceToken: "tok",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
            #expect(MiSessionStore.save(session, defaults: defaults, vault: vault))
            let store = HomeStore(
                defaultsSuiteName: suite,
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory
            )
            #expect(store.capabilityResolutionMode == .legacyPreserved)
            #expect(store.hasCompletedOnboarding)
            #expect(!store.showsFullOnboardingGuide)
            #expect(!store.shouldShowOnboarding)
        }
    }

    @Test("Uncertain credential or selection reads fail closed without popping onboarding and recover on retry")
    @MainActor
    func uncertainReadFailsClosedAndRetries() throws {
        let (suite, defaults) = try Self.makeFreshSuite("uncertain")
        defer { defaults.removePersistentDomain(forName: suite) }

        let box = ToggleableVaultBox()
        let seedVault = CredentialVault(storage: box.storage)
        let session = MiSession(
            userId: "88100", cUserId: "c", ssecurity: "s", serviceToken: "tok",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.save(session, defaults: defaults, vault: seedVault))

        // Lock the vault before a cold launch (fresh CredentialVault) to simulate Keychain read failure.
        box.failReads = true
        let launchVault = CredentialVault(storage: box.storage)
        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: launchVault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(store.capabilityResolutionMode == .uncertainFallback)
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(store.onboardingPresentation == .hidden)
        #expect(!store.showsFullOnboardingGuide)
        #expect(store.shouldSuppressBackgroundNetworkWork)
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)
        #expect(defaults.object(forKey: "has_completed_onboarding") == nil, "must not seal onboarding on uncertain read")
        if case .blocked(_, let action) = store.panelHealth {
            #expect(action == .retryIdentityMigration)
        } else {
            Issue.record("expected .blocked(.retryIdentityMigration), got \(store.panelHealth)")
        }

        // Retrying while still locked remains fail-closed.
        #expect(!store.retryIdentityMigration())
        #expect(store.identityMigrationDiagnostic != nil)

        // Unlocking the vault recovers legacy accounts and clears fail-closed state.
        box.failReads = false
        #expect(store.retryIdentityMigration())
        #expect(store.identityMigrationDiagnostic == nil)
        #expect(store.miAccounts.count == 1)
        #expect(store.hasCompletedOnboarding)
        #expect(!store.showsFullOnboardingGuide)
    }

    @Test("Corrupt capability_selection_v1 fails closed and preserves raw bytes untouched")
    @MainActor
    func corruptSelectionPreservesBytes() throws {
        let (suite, defaults) = try Self.makeFreshSuite("corrupt")
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("{not valid json".utf8)
        defaults.set(corrupt, forKey: CapabilitySelectionStore.storageKey)
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)

        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(store.capabilityResolutionMode == .uncertainFallback)
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(store.onboardingPresentation == .hidden)
        #expect(defaults.data(forKey: CapabilitySelectionStore.storageKey) == corrupt)
    }

    @Test("CapabilitySelectionStore merges concurrent revision conflicts and preserves unknown fields")
    @MainActor
    func conflictMergeAdvancesRevisionAndPreservesUnknownKeys() throws {
        let (suite, defaults) = try Self.makeFreshSuite("conflict")
        defer { defaults.removePersistentDomain(forName: suite) }

        let full = CapabilitySelection(
            enabledConnections: [.homeAssistant, .xiaomiCloud],
            enabledConnectionScopes: [],
            enabledFeatures: Set(FeatureID.allCases),
            enabledCategories: Set(DeviceCategoryID.allCases)
        )
        let initial = CapabilitySelectionStore.saveMergingConflicts(
            selection: full,
            configuredScopes: [],
            expectedRevision: nil,
            defaults: defaults
        )
        #expect(initial.succeeded)
        #expect(!initial.hadConflict)
        #expect(initial.revision == 1)

        // Simulate a newer external write that bumped revision to 3 and added a future key.
        let externalObj: [String: Any] = [
            "schemaVersion": 1,
            "revision": 3,
            "migrationComplete": true,
            "futureFlag": "keep-me",
            "enabledConnections": ["homeAssistant", "xiaomiCloud"],
            "disabledConnections": [],
            "disabledConnectionScopes": [],
            "enabledCategories": DeviceCategoryID.allCases.map(\.rawValue),
            "enabledFeatures": FeatureID.allCases.map(\.rawValue)
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: externalObj), forKey: CapabilitySelectionStore.storageKey)

        // Writer with stale expectedRevision=1 merges, detects conflict, and advances past revision 3.
        let fresh = CapabilityReferenceEngine.resolveInstallSelection(
            evidence: CapabilityInstallEvidence(),
            manifest: .shared
        ).selection
        let merged = CapabilitySelectionStore.saveMergingConflicts(
            selection: fresh,
            configuredScopes: [],
            expectedRevision: 1,
            defaults: defaults
        )
        #expect(merged.succeeded)
        #expect(merged.hadConflict)
        #expect(merged.revision == 4)
        #expect(merged.diagnostic != nil)

        let raw = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(persisted["futureFlag"] as? String == "keep-me")
        #expect(persisted["revision"] as? Int == 4)
    }

    @Test("Adding HA for dual-source verifies snapshot before commit and rolls back on failure or cancel")
    @MainActor
    func haOnboardingVerificationRollbackAndSuccess() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("ha-verify")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)

        // Pre-seed Mi account plus a previously saved HA token (disabled) to ensure failed/cancelled
        // onboarding attempts never overwrite the old valid token or flip HA back on.
        let miSession = MiSession(
            userId: "77100", cUserId: "c", ssecurity: "s", serviceToken: "mi-tok",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.save(miSession, defaults: defaults, vault: vault))
        #expect(KeychainHelper.saveToken("old-valid-token", defaults: defaults, vault: vault))
        defaults.set("https://old.example.local:8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true)
        #expect(!store.isHAConnectionEnabled)

        // 1. Validation failures never touch saved token or enable HA.
        let emptyURL = await store.connectHomeAssistantForOnboarding(serverURL: " ", token: "bad")
        if case .failed = emptyURL {} else { Issue.record("expected .failed for empty URL") }
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token")
        #expect(!store.isHAConnectionEnabled)

        // 2. Verifier failure rolls back cleanly and preserves old valid token.
        store.haOnboardingVerifier = { _, _ in
            throw HomeProviderError.unauthorized
        }
        let failed = await store.connectHomeAssistantForOnboarding(
            serverURL: "https://new.example.local:8123",
            token: "bad-token"
        )
        if case .failed(let reason, let impact, _) = failed {
            #expect(!reason.isEmpty)
            #expect(impact.contains("双源未启用") || impact.contains("dual-source"))
        } else {
            Issue.record("expected .failed on verifier error")
        }
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token")
        #expect(store.serverURLString == "https://old.example.local:8123")
        #expect(!store.isHAConnectionEnabled)

        // 3. Cancellation while verification is pending rolls back cleanly.
        let startedStream = AsyncStream<Void>.makeStream()
        store.haOnboardingVerifier = { _, _ in
            startedStream.continuation.yield()
            try await Task.sleep(for: .seconds(60))
        }
        let pending = Task { @MainActor in
            await store.connectHomeAssistantForOnboarding(
                serverURL: "https://pending.example.local:8123",
                token: "pending-token"
            )
        }
        var iterator = startedStream.stream.makeAsyncIterator()
        _ = await iterator.next()
        store.cancelPendingHAOnboardingVerification()
        let cancelledOutcome = await pending.value
        #expect(cancelledOutcome == .cancelled)
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token")
        #expect(!store.isHAConnectionEnabled)

        // 4. Verified snapshot (even with zero devices) commits URL, token, and enables HA dual-source.
        store.haOnboardingVerifier = { _, _ in }
        let ok = await store.connectHomeAssistantForOnboarding(
            serverURL: "https://verified.example.local:8123",
            token: "verified-token"
        )
        #expect(ok == .connected)
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "verified-token")
        #expect(store.serverURLString == "https://verified.example.local:8123")
        #expect(store.isHAConnectionEnabled)
        #expect(store.hasEnabledMiSource)
        #expect(store.hasEnabledHASource)
    }

    @Test("Demo mode restores prior real backend on exit and reopens guide when unconfigured")
    @MainActor
    func demoEnterAndExitRestoresPriorSelection() throws {
        // Fresh unconfigured -> demo -> leaveDemo reopens onboarding.
        do {
            let (suite, defaults) = try Self.makeFreshSuite("demo-fresh")
            defer { defaults.removePersistentDomain(forName: suite) }
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            let store = HomeStore(
                defaultsSuiteName: suite,
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory
            )
            store.switchBackend(.demo)
            #expect(store.homeBackend == .demo)
            #expect(!store.leaveDemo())
            #expect(store.showsFullOnboardingGuide)
        }

        // Configured HA + Mi -> demo -> leaveDemo restores HA (pre-demo backend).
        do {
            let (suite, defaults) = try Self.makeFreshSuite("demo-restore")
            defer { defaults.removePersistentDomain(forName: suite) }
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            #expect(KeychainHelper.saveToken("ha-tok", defaults: defaults, vault: vault))
            defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
            let store = HomeStore(
                provider: MockHomeProvider(),
                defaultsSuiteName: suite,
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory
            )
            store.hasHASource = true
            store.switchBackend(.demo)
            #expect(store.homeBackend == .demo)
            #expect(store.leaveDemo())
            #expect(store.homeBackend == .homeAssistant)
        }
    }
}
