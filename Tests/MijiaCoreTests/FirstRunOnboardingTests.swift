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

    @Test("P1-1: Uncertain Keychain read preserves legacy bare Mi home ID and migrates it on retry")
    @MainActor
    func uncertainKeychainPreservesLegacySelectedMiHomeAndMigratesOnRetry() throws {
        let (suite, defaults) = try Self.makeFreshSuite("p1-1-legacy-home")
        defer { defaults.removePersistentDomain(forName: suite) }

        let box = ToggleableVaultBox()
        let seedVault = CredentialVault(storage: box.storage)
        let session = MiSession(
            userId: "66100", cUserId: "c", ssecurity: "s", serviceToken: "tok",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.save(session, defaults: defaults, vault: seedVault))
        defaults.set("legacy-home-42", forKey: MiCloudProvider.selectedHomeKey)

        // Simulate locked Keychain on cold launch: legacy bare home ID must not be deleted.
        box.failReads = true
        let launchVault = CredentialVault(storage: box.storage)
        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: launchVault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home-42")
        #expect(!store.retryIdentityMigration())
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home-42")

        // Once Keychain becomes readable, retry migrates the bare ID with the account prefix.
        box.failReads = false
        #expect(store.retryIdentityMigration())
        let account = try #require(store.miAccounts.first)
        let expectedScoped = MiAccountScope.id("legacy-home-42", account: account.id)
        #expect(store.selectedMiHomeId == expectedScoped)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == expectedScoped)
    }

    @Test("P1-2: Uncertain identity blocks live providers, LG TV, wake refresh, and Settings auto checks")
    @MainActor
    func uncertainIdentityBlocksLaunchWakeAndSettingsAutoNetworkWork() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("p1-2-uncertain-network")
        defer { defaults.removePersistentDomain(forName: suite) }

        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let session = MiSession(
            userId: "55100", cUserId: "c", ssecurity: "s", serviceToken: "mi-tok",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.save(session, defaults: defaults, vault: vault))
        #expect(KeychainHelper.saveToken("valid-ha-token", defaults: defaults, vault: vault))
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.55")
        #expect(lgConfig.save(to: defaults, vault: vault))

        // Corrupt capability selection while HA token, Mi account, and LG TV are all valid.
        defaults.set(Data("{corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)

        let haFactoryCalls = RequestCounter()
        let miFactoryCalls = RequestCounter()
        let updateFetchCalls = RequestCounter()
        let lanDiscoverCalls = RequestCounter()
        let resumeHookCalls = RequestCounter()

        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: { _ in
                miFactoryCalls.requests += 1
                return Self.stubMiFactory([])
            },
            haProviderFactory: { _, _ in
                haFactoryCalls.requests += 1
                return MockHomeProvider()
            }
        )
        var driver = UpdateSystemDriver.live
        driver.fetchData = { _ in
            updateFetchCalls.requests += 1
            throw URLError(.notConnectedToInternet)
        }
        store.updater = AppUpdater(currentVersion: "1.0.0", driver: driver)
        store.haLANDiscoverer = { _ in
            lanDiscoverCalls.requests += 1
            return []
        }
        let fixedNow = ContinuousClock.now
        store.resumeDebounceInterval = .zero
        store.resumeScheduler = DebouncedResumeScheduler(
            now: { fixedNow },
            sleep: { _ in }
        )
        store.onDebouncedResumeHook = { _ in
            resumeHookCalls.requests += 1
        }

        // 1. Launch must not build live providers or start the LG TV connection loop.
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(store.shouldSuppressBackgroundNetworkWork)
        #expect(haFactoryCalls.requests == 0, "uncertain launch must not construct live HA provider")
        #expect(miFactoryCalls.requests == 0, "uncertain launch must not construct live Mi provider")
        #expect(store.activeHAProvider == nil)
        #expect(store.activeMiAccountsProvider == nil)
        #expect(store.lgWebOSClient == nil, "uncertain launch must not start LG webOS client")

        // Direct rebuild attempts while identity is uncertain must also stay offline.
        store.rebuildLiveProvider()
        #expect(haFactoryCalls.requests == 0)
        #expect(miFactoryCalls.requests == 0)

        // 2. Wake / resume refresh must not run while identity is uncertain.
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(resumeHookCalls.requests == 0)

        // 3. Settings auto checks (update check & automatic LAN discovery) must not run.
        await store.checkForUpdatesIfNeeded()
        _ = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
        #expect(updateFetchCalls.requests == 0)
        #expect(lanDiscoverCalls.requests == 0)

        // 4. Once corruption is resolved and retry succeeds, live providers and LG resume normally.
        defaults.removeObject(forKey: CapabilitySelectionStore.storageKey)
        #expect(store.retryIdentityMigration())
        #expect(store.identityMigrationDiagnostic == nil)
        #expect(haFactoryCalls.requests >= 1)
        #expect(miFactoryCalls.requests >= 1)
        #expect(store.lgWebOSClient != nil)
        await store.shutdown()
    }

    @Test("P1-4: Revision conflict preserves account/connection disables alongside unrelated feature changes and syncs memory")
    @MainActor
    func revisionConflictPreservesAccountDisableAndUnrelatedFeatureChangeAndSyncsMemory() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("p1-4-conflict")
        defer { defaults.removePersistentDomain(forName: suite) }

        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let sessionA = MiSession(
            userId: "11101", cUserId: "c1", ssecurity: "s1", serviceToken: "t1",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let sessionB = MiSession(
            userId: "22202", cUserId: "c2", ssecurity: "s2", serviceToken: "t2",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.upsert(sessionA, defaults: defaults, vault: vault))
        #expect(MiSessionStore.upsert(sessionB, defaults: defaults, vault: vault))
        #expect(KeychainHelper.saveToken("ha-tok", defaults: defaults, vault: vault))
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")
        defaults.set(true, forKey: "has_completed_onboarding")

        // Seed revision 1 via an initial store, then load two concurrent stores A & B from revision 1.
        let seedStore = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        let acctA = try #require(seedStore.miAccounts.first { $0.session.userId == "11101" })
        let baseRev = try #require(seedStore.capabilityStoreRevision)

        let storeA = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        let storeB = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(storeA.capabilityStoreRevision == baseRev)
        #expect(storeB.capabilityStoreRevision == baseRev)

        // Writer A disables Mi account A.
        let verdictA = storeA.setMiAccountEnabled(false, id: acctA.id, pauseConfirmed: true)
        #expect(verdictA.disposition == .allowed)
        #expect(!storeA.isMiAccountEnabled(acctA.id))
        #expect(storeA.capabilityStoreRevision == baseRev + 1)

        // Writer B (still at baseRev!) toggles an unrelated feature (.grokball) and persists.
        storeB.capabilitySelection.enabledFeatures.remove(.grokball)
        #expect(storeB.persistCapabilitySelection())

        // Both A's account disable AND B's feature disable must be preserved on disk AND synced into B's memory.
        let raw = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let diskDisabledScopes = Set(persisted["disabledConnectionScopes"] as? [String] ?? [])
        let diskEnabledFeatures = Set(persisted["enabledFeatures"] as? [String] ?? [])
        #expect(diskDisabledScopes.contains(acctA.id), "A's account disable must survive B's stale feature write")
        #expect(!diskEnabledFeatures.contains(FeatureID.grokball.rawValue), "B's feature disable must be persisted")
        #expect(diskEnabledFeatures.contains(FeatureID.voiceInput.rawValue), "untouched features must stay enabled")

        #expect(!storeB.isMiAccountEnabled(acctA.id), "storeB memory must sync A's disabled account after conflict merge")
        #expect(storeB.explicitlyDisabledScopes.contains(acctA.id))
        #expect(!storeB.capabilitySelection.enabledFeatures.contains(.grokball))
        #expect(storeB.capabilityStoreRevision == baseRev + 2)
        #expect(storeB.capabilityMergeConflictCount == 1)

        // Also verify whole-connection disable (HA) survives an unrelated stale feature edit.
        let storeC = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        let storeD = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        _ = storeC.setHAConnectionEnabled(false, pauseConfirmed: true)
        #expect(!storeC.isHAConnectionEnabled)

        storeD.capabilitySelection.enabledFeatures.remove(.voiceInput)
        #expect(storeD.persistCapabilitySelection())

        #expect(!storeD.isHAConnectionEnabled, "C's HA connection disable must survive D's stale feature write")
        #expect(storeD.explicitlyDisabledConnections.contains(.homeAssistant))
        #expect(!storeD.capabilitySelection.enabledFeatures.contains(.voiceInput))
        #expect(!storeD.capabilitySelection.enabledFeatures.contains(.grokball))
    }

    @Test("P1-4: Concurrent in-process CapabilitySelectionStore writes serialize cleanly without losing disables or features")
    func concurrentInProcessCapabilityWritesPreserveAllDisjointPatches() async throws {
        let suite = "test.p4a.p1-4-concurrent-lock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let baseSelection = CapabilitySelection(
            enabledConnections: [.homeAssistant, .xiaomiCloud],
            enabledConnectionScopes: ["mi:cn:1", "mi:cn:2", "ha:https://ha.local:8123"],
            enabledFeatures: Set(FeatureID.allCases),
            enabledCategories: Set(DeviceCategoryID.allCases)
        )
        let seed = CapabilitySelectionStore.saveMergingConflicts(
            selection: baseSelection,
            configuredScopes: baseSelection.enabledConnectionScopes,
            explicitlyDisabledConnections: [],
            expectedRevision: nil,
            defaults: defaults
        )
        let baseRev = try #require(seed.revision)

        let results = try await withThrowingTaskGroup(of: CapabilitySelectionSaveResult.self, returning: [CapabilitySelectionSaveResult].self) { group in
            group.addTask {
                let taskDefaults = try #require(UserDefaults(suiteName: suite))
                var sel = baseSelection
                sel.enabledConnectionScopes.remove("mi:cn:1")
                return CapabilitySelectionStore.saveMergingConflicts(
                    selection: sel,
                    configuredScopes: baseSelection.enabledConnectionScopes,
                    explicitlyDisabledConnections: [],
                    patch: CapabilitySelectionPatch(disabledScopes: ["mi:cn:1"]),
                    expectedRevision: baseRev,
                    defaults: taskDefaults
                )
            }
            group.addTask {
                let taskDefaults = try #require(UserDefaults(suiteName: suite))
                var sel = baseSelection
                sel.enabledFeatures.remove(.grokball)
                return CapabilitySelectionStore.saveMergingConflicts(
                    selection: sel,
                    configuredScopes: baseSelection.enabledConnectionScopes,
                    explicitlyDisabledConnections: [],
                    patch: CapabilitySelectionPatch(removedFeatures: [.grokball]),
                    expectedRevision: baseRev,
                    defaults: taskDefaults
                )
            }
            group.addTask {
                let taskDefaults = try #require(UserDefaults(suiteName: suite))
                var sel = baseSelection
                sel.enabledFeatures.remove(.voiceInput)
                return CapabilitySelectionStore.saveMergingConflicts(
                    selection: sel,
                    configuredScopes: baseSelection.enabledConnectionScopes,
                    explicitlyDisabledConnections: [],
                    patch: CapabilitySelectionPatch(removedFeatures: [.voiceInput]),
                    expectedRevision: baseRev,
                    defaults: taskDefaults
                )
            }
            var collected: [CapabilitySelectionSaveResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.succeeded })
        #expect(Set(results.compactMap(\.revision)) == Set([baseRev + 1, baseRev + 2, baseRev + 3]))

        let raw = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let diskDisabledScopes = Set(persisted["disabledConnectionScopes"] as? [String] ?? [])
        let diskEnabledFeatures = Set(persisted["enabledFeatures"] as? [String] ?? [])
        #expect(diskDisabledScopes.contains("mi:cn:1"))
        #expect(!diskEnabledFeatures.contains(FeatureID.grokball.rawValue))
        #expect(!diskEnabledFeatures.contains(FeatureID.voiceInput.rawValue))
    }

    private actor AsyncSignal {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            signaled = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            if signaled { return }
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    private actor CancellableGate {
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var cancelSignalWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var sawCancellation = false

        func wait() async throws {
            if Task.isCancelled {
                markCancelled()
                throw CancellationError()
            }
            if released { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if released {
                        cont.resume()
                    } else if Task.isCancelled {
                        markCancelled()
                        cont.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = cont
                    }
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        private func markCancelled() {
            sawCancellation = true
            let pending = cancelSignalWaiters
            cancelSignalWaiters.removeAll()
            pending.forEach { $0.resume() }
        }

        private func cancel(id: UUID) {
            markCancelled()
            if let cont = waiters.removeValue(forKey: id) {
                cont.resume(throwing: CancellationError())
            }
        }

        func waitUntilCancelled() async {
            if sawCancellation { return }
            await withCheckedContinuation { cont in
                cancelSignalWaiters.append(cont)
            }
        }

        func releaseAll() {
            released = true
            let pending = waiters.values
            waiters.removeAll()
            for cont in pending {
                cont.resume()
            }
        }
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("P2-1: HA onboarding verification shuts down probe and stops retries on timeout, retryable error, and cancellation")
    func haOnboardingVerificationShutsDownProbeOnTimeoutErrorAndCancel() async throws {
        // 1. Timeout exit: probe must be shut down and must never start a second connection attempt.
        do {
            let connectAttempts = AtomicCounter()
            let firstConnectStarted = AsyncSignal()
            let hangConnect = CancellableGate()
            let reconnectGate = CancellableGate()
            let probe = HAWebSocketProvider(baseURLString: "https://ha.example.local:8123", token: "tok")
            await probe.setTestSeams(
                connectOverride: {
                    connectAttempts.increment()
                    await firstConnectStarted.signal()
                    try await hangConnect.wait()
                    return .failedBeforeAuth(URLError(.timedOut))
                },
                reconnectSleep: { _ in
                    try await reconnectGate.wait()
                }
            )

            var caughtTimeout = false
            do {
                try await HomeStore.verifyHomeAssistantSnapshot(
                    baseURLString: "https://ha.example.local:8123",
                    token: "tok",
                    probeFactory: { _, _ in probe },
                    timeoutSleep: {
                        await firstConnectStarted.wait()
                    }
                )
            } catch let error as HomeStore.HAOnboardingVerifyError {
                caughtTimeout = (error == .timedOut)
            }

            #expect(caughtTimeout)
            #expect(await probe.isShutDownForTesting, "timeout must shut down probe provider")
            await hangConnect.waitUntilCancelled()
            await reconnectGate.releaseAll()
            await probe.refreshNow()
            #expect(connectAttempts.count == 1, "timed-out probe must not retry in the background")
        }

        // 2. Retryable disconnect error exit: probe must be shut down and never reconnect.
        do {
            let connectAttempts = AtomicCounter()
            let reconnectGate = CancellableGate()
            let probe = HAWebSocketProvider(baseURLString: "https://ha.example.local:8123", token: "tok")
            await probe.setTestSeams(
                connectOverride: {
                    connectAttempts.increment()
                    return .failedBeforeAuth(URLError(.cannotConnectToHost))
                },
                reconnectSleep: { _ in
                    try await reconnectGate.wait()
                }
            )

            var caughtFailure = false
            do {
                try await HomeStore.verifyHomeAssistantSnapshot(
                    baseURLString: "https://ha.example.local:8123",
                    token: "tok",
                    probeFactory: { _, _ in probe },
                    timeoutSleep: {
                        try await CancellableGate().wait()
                    }
                )
            } catch let error as HomeStore.HAOnboardingVerifyError {
                if case .failed = error { caughtFailure = true }
            }

            #expect(caughtFailure)
            #expect(await probe.isShutDownForTesting, "retryable error must shut down probe provider")
            await reconnectGate.releaseAll()
            await probe.refreshNow()
            #expect(connectAttempts.count == 1, "errored probe must not reconnect in the background")
        }

        // 3. External cancellation exit: probe must be shut down before returning.
        do {
            let connectAttempts = AtomicCounter()
            let firstConnectStarted = AsyncSignal()
            let hangConnect = CancellableGate()
            let hangTimeout = CancellableGate()
            let probe = HAWebSocketProvider(baseURLString: "https://ha.example.local:8123", token: "tok")
            await probe.setTestSeams(
                connectOverride: {
                    connectAttempts.increment()
                    await firstConnectStarted.signal()
                    try await hangConnect.wait()
                    return .failedBeforeAuth(URLError(.cancelled))
                },
                reconnectSleep: { _ in }
            )

            let verifyTask = Task {
                try await HomeStore.verifyHomeAssistantSnapshot(
                    baseURLString: "https://ha.example.local:8123",
                    token: "tok",
                    probeFactory: { _, _ in probe },
                    timeoutSleep: {
                        try await hangTimeout.wait()
                    }
                )
            }
            await firstConnectStarted.wait()
            verifyTask.cancel()

            var caughtCancel = false
            do {
                try await verifyTask.value
            } catch is CancellationError {
                caughtCancel = true
            }

            #expect(caughtCancel)
            #expect(await probe.isShutDownForTesting, "cancelled verification must shut down probe provider")
            await hangConnect.waitUntilCancelled()
            await hangTimeout.waitUntilCancelled()
            await probe.refreshNow()
            #expect(connectAttempts.count == 1, "cancelled probe must not retry in the background")
        }
    }

    private final class TransientReadVaultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        private var blob: Data?

        init(remainingFailures: Int = 0) {
            self.remainingFailures = remainingFailures
        }

        func setRemainingFailures(_ count: Int) {
            lock.lock()
            remainingFailures = count
            lock.unlock()
        }

        var storage: CredentialVault.Storage {
            CredentialVault.Storage(
                read: {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    if self.remainingFailures > 0 {
                        self.remainingFailures -= 1
                        return .unavailable
                    }
                    return self.blob.map(CredentialVault.Storage.ReadResult.found) ?? .notFound
                },
                write: { data in
                    self.lock.lock()
                    self.blob = data
                    self.lock.unlock()
                    return true
                }
            )
        }
    }

    @Test("C1: Transient first-read Keychain failure during launch never deletes legacy bare Mi home ID and migrates it once recovered")
    @MainActor
    func transientFirstReadFailurePreservesAndMigratesLegacySelectedMiHome() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("c1-transient-first-read-home")
        defer { defaults.removePersistentDomain(forName: suite) }

        let box = TransientReadVaultBox()
        let seedVault = CredentialVault(storage: box.storage)
        let session = MiSession(
            userId: "66200", cUserId: "c", ssecurity: "s", serviceToken: "tok",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.save(session, defaults: defaults, vault: seedVault))
        defaults.set("legacy-home-99", forKey: MiCloudProvider.selectedHomeKey)

        // Fail ONLY the very first Keychain read; the next read succeeds.
        // Previously, HomeStore.init loaded `initialAccounts = []` on read #1 while
        // `resolveAtLaunch -> readExistingAccounts` retried and succeeded on read #2,
        // causing `resolveSelectedMiHomeId` to delete `mi_selected_home_id` with empty accounts.
        box.setRemainingFailures(1)
        let launchVault = CredentialVault(storage: box.storage)
        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: launchVault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )

        if store.identityMigrationDiagnostic != nil {
            #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home-99")
            #expect(store.retryIdentityMigration())
        }

        #expect(store.identityMigrationDiagnostic == nil)
        let account = try #require(store.miAccounts.first)
        let expectedScoped = MiAccountScope.id("legacy-home-99", account: account.id)
        #expect(store.selectedMiHomeId == expectedScoped)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == expectedScoped)
        #expect(store.isMiAccountEnabled(account.id))
        await store.shutdown()
    }

    @Test("C2: QR sign-in after uncertain launch recovers identity first, preserves existing accounts enabled, and starts live provider")
    @MainActor
    func miLoginAfterUncertainLaunchRecoversIdentityPreservesOtherAccountsAndStartsProvider() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("c2-login-after-uncertain")
        defer { defaults.removePersistentDomain(forName: suite) }

        let box = ToggleableVaultBox()
        let seedVault = CredentialVault(storage: box.storage)
        let sessionA = MiSession(
            userId: "77101", cUserId: "c1", ssecurity: "s1", serviceToken: "tok1",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let sessionB = MiSession(
            userId: "77202", cUserId: "c2", ssecurity: "s2", serviceToken: "tok2",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.upsert(sessionA, defaults: defaults, vault: seedVault))
        let acctAId = MiAccount(session: sessionA).id
        let acctBId = MiAccount(session: sessionB).id

        // Cold launch fails to read Keychain -> uncertain identity, no live provider.
        box.failReads = true
        let miFactoryCalls = RequestCounter()
        let launchVault = CredentialVault(storage: box.storage)
        let store = HomeStore(
            defaultsSuiteName: suite,
            credentialVault: launchVault,
            miAccountsProviderFactory: { accounts in
                miFactoryCalls.requests += 1
                return Self.stubMiFactory(accounts)
            },
            haProviderFactory: Self.stubHAFactory
        )
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(miFactoryCalls.requests == 0)

        // While Keychain is still unavailable, QR login must refuse rather than corrupting state.
        store.completeMiLogin(sessionB)
        #expect(store.identityMigrationDiagnostic != nil)
        #expect(store.toastNotice?.isError == true)
        #expect(miFactoryCalls.requests == 0)
        #expect(!store.hasCompletedOnboarding)

        // Keychain recovers; user directly completes QR login for account B without pressing Retry first.
        box.failReads = false
        store.completeMiLogin(sessionB)

        #expect(store.identityMigrationDiagnostic == nil)
        #expect(store.isMiAccountEnabled(acctAId), "pre-existing account A must remain enabled")
        #expect(store.isMiAccountEnabled(acctBId), "newly signed-in account B must be enabled")
        #expect(!store.explicitlyDisabledScopes.contains(acctAId))
        #expect(!store.explicitlyDisabledScopes.contains(acctBId))
        #expect(miFactoryCalls.requests >= 1, "live Mi provider must start once identity recovers on login")

        let raw = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let diskDisabledScopes = Set(persisted["disabledConnectionScopes"] as? [String] ?? [])
        #expect(!diskDisabledScopes.contains(acctAId), "account A must not be persisted into disabledConnectionScopes")
        #expect(!diskDisabledScopes.contains(acctBId))
        await store.shutdown()
    }

    @Test("D: Cross-store revision conflict preserves explicit re-enable when another store re-signs in a disabled Mi account")
    @MainActor
    func crossStoreConflictPreservesExplicitReenableOnMiRelogin() async throws {
        let (suite, defaults) = try Self.makeFreshSuite("d-conflict-explicit-reenable")
        defer { defaults.removePersistentDomain(forName: suite) }

        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let sessionA = MiSession(
            userId: "88101", cUserId: "c1", ssecurity: "s1", serviceToken: "tok1",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let sessionB = MiSession(
            userId: "88202", cUserId: "c2", ssecurity: "s2", serviceToken: "tok2",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(MiSessionStore.upsert(sessionA, defaults: defaults, vault: vault))
        #expect(MiSessionStore.upsert(sessionB, defaults: defaults, vault: vault))
        defaults.set(true, forKey: "has_completed_onboarding")

        // Seed revision 1 with both accounts enabled, then load two stores A & B at the same baseline.
        let seedStore = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        let acctA = try #require(seedStore.miAccounts.first { $0.session.userId == "88101" })
        let baseRev = try #require(seedStore.capabilityStoreRevision)
        await seedStore.shutdown()

        let storeA = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        let storeB = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(storeA.capabilityStoreRevision == baseRev)
        #expect(storeB.capabilityStoreRevision == baseRev)
        #expect(storeA.isMiAccountEnabled(acctA.id))
        #expect(storeB.isMiAccountEnabled(acctA.id))

        // Store A disables account A (and toggles off an unrelated feature).
        let verdict = storeA.setMiAccountEnabled(false, id: acctA.id, pauseConfirmed: true)
        #expect(verdict.disposition == .allowed)
        #expect(!storeA.isMiAccountEnabled(acctA.id))
        storeA.capabilitySelection.enabledFeatures.remove(.grokball)
        #expect(storeA.persistCapabilitySelection())

        // Store B (still at baseRev, where acctA was already enabled in its baseline) re-signs in account A.
        let refreshedSessionA = MiSession(
            userId: "88101", cUserId: "c1", ssecurity: "s1-new", serviceToken: "tok1-new",
            expiresAt: Date(timeIntervalSince1970: 4_100_000_000)
        )
        storeB.completeMiLogin(refreshedSessionA)

        // Account A must be explicitly re-enabled despite matching B's old baseline, while A's unrelated feature toggle survives.
        #expect(storeB.isMiAccountEnabled(acctA.id), "explicit re-login must re-enable account A across revision conflict")
        #expect(!storeB.explicitlyDisabledScopes.contains(acctA.id))
        #expect(!storeB.capabilitySelection.enabledFeatures.contains(.grokball), "unrelated feature edit from store A must survive merge")

        let raw = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let diskDisabledScopes = Set(persisted["disabledConnectionScopes"] as? [String] ?? [])
        let diskEnabledFeatures = Set(persisted["enabledFeatures"] as? [String] ?? [])
        #expect(!diskDisabledScopes.contains(acctA.id), "disk state must not keep account A disabled after explicit re-login")
        #expect(!diskEnabledFeatures.contains(FeatureID.grokball.rawValue))

        // A freshly opened store confirms account A is enabled on disk.
        let reloaded = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory
        )
        #expect(reloaded.isMiAccountEnabled(acctA.id))
        #expect(!reloaded.capabilitySelection.enabledFeatures.contains(.grokball))
        await storeA.shutdown()
        await storeB.shutdown()
        await reloaded.shutdown()
    }
}
