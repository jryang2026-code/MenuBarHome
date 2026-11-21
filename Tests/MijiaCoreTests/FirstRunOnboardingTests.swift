import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct FirstRunOnboardingTests {
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var requests: Int {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        @discardableResult
        func increment() -> Int {
            lock.withLock { value += 1; return value }
        }
    }

    private static let stubMiFactory: @MainActor ([MiAccount]) -> MiAccountsProvider = { _ in
        MiAccountsProvider(accounts: [], localClientFactory: { nil }, pollInterval: .seconds(3600), followUpDelay: .seconds(3600))
    }

    private static let stubHAFactory: @MainActor (String, String) -> any HomeProvider = { _, _ in
        MockHomeProvider()
    }

    @Test("Fresh install does zero background/LAN/update work, keeps onboarding open across relaunch, and restores prior backend after demo")
    @MainActor
    func freshInstallAndDemoLifecycle() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let counter = RequestCounter()

        let store = HomeStore(
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory,
            defaults: defaults
        )
        var driver = UpdateSystemDriver.live
        driver.fetchData = { _ in counter.increment(); throw URLError(.notConnectedToInternet) }
        store.updater = AppUpdater(currentVersion: "1.0.0", driver: driver)

        let expectedFresh = CapabilityReferenceEngine.resolveInstallSelection(
            evidence: CapabilityInstallEvidence(),
            manifest: .shared
        ).selection
        #expect(store.capabilityResolutionMode == .freshInstall)
        #expect(store.showsFullOnboardingGuide && store.shouldShowOnboarding)
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN && !store.isDiscoveringHA && store.discoveredHAInstances.isEmpty)
        #expect(store.shouldSuppressBackgroundNetworkWork)
        #expect(store.capabilitySelection.enabledCategories == expectedFresh.enabledCategories)

        await store.checkForUpdatesIfNeeded()
        #expect(counter.requests == 0)

        store.switchBackend(.demo)
        #expect(store.homeBackend == .demo)
        #expect(!store.leaveDemo() && store.showsFullOnboardingGuide)

        let relaunched = HomeStore(
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory,
            defaults: defaults
        )
        #expect(relaunched.showsFullOnboardingGuide && relaunched.shouldSuppressBackgroundNetworkWork)
        relaunched.finishOnboardingGuide()
        #expect(relaunched.hasCompletedOnboarding && !relaunched.showsFullOnboardingGuide)
        relaunched.reopenOnboarding()
        #expect(relaunched.showsFullOnboardingGuide)

        let haDefaults = InMemoryUserDefaults()
        let haVault = CredentialVault(storage: MemoryVaultStorage().storage)
        #expect(KeychainHelper.saveToken("ha-tok", defaults: haDefaults, vault: haVault))
        haDefaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let haStore = HomeStore(provider: MockHomeProvider(), credentialVault: haVault, defaults: haDefaults)
        haStore.hasHASource = true
        haStore.switchBackend(.demo)
        #expect(haStore.leaveDemo() && haStore.homeBackend == .homeAssistant)
    }

    @Test("Legacy users (demo-only, capability-selection-only, or existing account) migrate silently without popping onboarding")
    @MainActor
    func legacyUsersMigrateSilentlyWithoutOnboarding() throws {
        do {
            let defaults = InMemoryUserDefaults()
            defaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
            let store = HomeStore(
                credentialVault: CredentialVault(storage: MemoryVaultStorage().storage),
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory,
                defaults: defaults
            )
            #expect(store.capabilityResolutionMode == .legacyPreserved && store.homeBackend == .demo)
            #expect(store.hasCompletedOnboarding && !store.showsFullOnboardingGuide && !store.shouldShowOnboarding)
        }

        do {
            let defaults = InMemoryUserDefaults()
            let fresh = CapabilityReferenceEngine.resolveInstallSelection(evidence: CapabilityInstallEvidence(), manifest: .shared).selection
            #expect(CapabilitySelectionStore.save(selection: fresh, configuredScopes: [], defaults: defaults))
            let store = HomeStore(
                credentialVault: CredentialVault(storage: MemoryVaultStorage().storage),
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory,
                defaults: defaults
            )
            #expect(store.capabilityResolutionMode == .explicit && store.hasCompletedOnboarding && !store.showsFullOnboardingGuide)
        }

        do {
            let defaults = InMemoryUserDefaults()
            let vault = CredentialVault(storage: MemoryVaultStorage().storage)
            let session = MiSession(userId: "99100", cUserId: "c", ssecurity: "s", serviceToken: "tok", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
            #expect(MiSessionStore.save(session, defaults: defaults, vault: vault))
            let store = HomeStore(
                credentialVault: vault,
                miAccountsProviderFactory: Self.stubMiFactory,
                haProviderFactory: Self.stubHAFactory,
                defaults: defaults
            )
            #expect(store.capabilityResolutionMode == .legacyPreserved && store.hasCompletedOnboarding && !store.showsFullOnboardingGuide)
        }
    }

    @Test("Uncertain credential or corrupt selection reads fail closed, suppress live network work, preserve legacy bare home ID, and recover on retry or QR sign-in")
    @MainActor
    func uncertainIdentityFailClosedAndRecovery() async throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let seedVault = CredentialVault(storage: mem.storage)
        let sessionA = MiSession(userId: "88100", cUserId: "c", ssecurity: "s", serviceToken: "tok", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let sessionB = MiSession(userId: "77202", cUserId: "c2", ssecurity: "s2", serviceToken: "tok2", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        #expect(MiSessionStore.save(sessionA, defaults: defaults, vault: seedVault))
        #expect(KeychainHelper.saveToken("valid-ha-token", defaults: defaults, vault: seedVault))
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")
        defaults.set("legacy-home-42", forKey: MiCloudProvider.selectedHomeKey)
        #expect(LGWebOSConfig(isEnabled: true, host: "192.0.2.55").save(to: defaults, vault: seedVault))

        mem.readResult = .unavailable
        let haFactoryCalls = RequestCounter()
        let miFactoryCalls = RequestCounter()
        let updateFetchCalls = RequestCounter()
        let lanDiscoverCalls = RequestCounter()
        let resumeHookCalls = RequestCounter()

        let store = HomeStore(
            credentialVault: CredentialVault(storage: mem.storage),
            miAccountsProviderFactory: { accounts in miFactoryCalls.increment(); return Self.stubMiFactory(accounts) },
            haProviderFactory: { _, _ in haFactoryCalls.increment(); return MockHomeProvider() },
            defaults: defaults
        )
        var driver = UpdateSystemDriver.live
        driver.fetchData = { _ in updateFetchCalls.increment(); throw URLError(.notConnectedToInternet) }
        store.updater = AppUpdater(currentVersion: "1.0.0", driver: driver)
        store.haLANDiscoverer = { _ in lanDiscoverCalls.increment(); return [] }
        let fixedNow = ContinuousClock.now
        store.resumeDebounceInterval = .zero
        store.resumeScheduler = DebouncedResumeScheduler(now: { fixedNow }, sleep: { _ in })
        store.onDebouncedResumeHook = { _ in resumeHookCalls.increment() }

        #expect(store.capabilityResolutionMode == .uncertainFallback && store.identityMigrationDiagnostic != nil)
        #expect(store.onboardingPresentation == .hidden && !store.showsFullOnboardingGuide)
        #expect(store.shouldSuppressBackgroundNetworkWork && !store.shouldAutoDiscoverHomeAssistantOnLAN)
        #expect(defaults.object(forKey: "has_completed_onboarding") == nil)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home-42")
        #expect(haFactoryCalls.requests == 0 && miFactoryCalls.requests == 0 && store.lgWebOSClient == nil)
        if case .blocked(_, let action) = store.panelHealth {
            #expect(action == .retryIdentityMigration)
        } else {
            Issue.record("expected .blocked(.retryIdentityMigration)")
        }

        store.rebuildLiveProvider()
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        await store.checkForUpdatesIfNeeded()
        _ = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
        #expect(haFactoryCalls.requests == 0 && miFactoryCalls.requests == 0 && resumeHookCalls.requests == 0)
        #expect(updateFetchCalls.requests == 0 && lanDiscoverCalls.requests == 0)
        #expect(!store.retryIdentityMigration() && defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home-42")

        store.completeMiLogin(sessionB)
        #expect(store.identityMigrationDiagnostic != nil && store.toastNotice?.isError == true && miFactoryCalls.requests == 0)

        mem.readResult = nil
        store.completeMiLogin(sessionB)
        #expect(store.identityMigrationDiagnostic == nil)
        let acctAId = MiAccount(session: sessionA).id
        let acctBId = MiAccount(session: sessionB).id
        #expect(store.isMiAccountEnabled(acctAId) && store.isMiAccountEnabled(acctBId))
        let expectedScoped = MiAccountScope.id("legacy-home-42", account: acctAId)
        #expect(store.selectedMiHomeId == expectedScoped && defaults.string(forKey: MiCloudProvider.selectedHomeKey) == expectedScoped)
        #expect(miFactoryCalls.requests >= 1 && store.lgWebOSClient != nil)
        await store.shutdown()

        let corruptDefaults = InMemoryUserDefaults()
        let corrupt = Data("{not valid json".utf8)
        corruptDefaults.set(corrupt, forKey: CapabilitySelectionStore.storageKey)
        let corruptStore = HomeStore(
            credentialVault: CredentialVault(storage: MemoryVaultStorage().storage),
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory,
            defaults: corruptDefaults
        )
        #expect(corruptStore.capabilityResolutionMode == .uncertainFallback && corruptStore.identityMigrationDiagnostic != nil)
        #expect(corruptDefaults.data(forKey: CapabilitySelectionStore.storageKey) == corrupt)
    }

    @Test("Adding HA for dual-source verifies snapshot before commit, rolls back on failure/cancel, and shuts down probe on timeout/error/cancel")
    @MainActor
    func haOnboardingVerificationRollbackAndProbeTeardown() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let miSession = MiSession(userId: "77100", cUserId: "c", ssecurity: "s", serviceToken: "mi-tok", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        #expect(MiSessionStore.save(miSession, defaults: defaults, vault: vault))
        #expect(KeychainHelper.saveToken("old-valid-token", defaults: defaults, vault: vault))
        defaults.set("https://old.example.local:8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: vault,
            miAccountsProviderFactory: Self.stubMiFactory,
            haProviderFactory: Self.stubHAFactory,
            defaults: defaults
        )
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true)

        let emptyURL = await store.connectHomeAssistantForOnboarding(serverURL: " ", token: "bad")
        if case .failed = emptyURL {} else { Issue.record("expected .failed") }
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token" && !store.isHAConnectionEnabled)

        store.haOnboardingVerifier = { _, _ in throw HomeProviderError.unauthorized }
        let failed = await store.connectHomeAssistantForOnboarding(serverURL: "https://new.example.local:8123", token: "bad-token")
        if case .failed(let reason, let impact, _) = failed {
            #expect(!reason.isEmpty && (impact.contains("双源未启用") || impact.contains("dual-source")))
        } else {
            Issue.record("expected .failed")
        }
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token" && store.serverURLString == "https://old.example.local:8123")

        let startedStream = AsyncStream<Void>.makeStream()
        store.haOnboardingVerifier = { _, _ in
            startedStream.continuation.yield()
            try await Task.sleep(for: .seconds(60))
        }
        let pending = Task { @MainActor in
            await store.connectHomeAssistantForOnboarding(serverURL: "https://pending.example.local:8123", token: "pending-token")
        }
        var iterator = startedStream.stream.makeAsyncIterator()
        _ = await iterator.next()
        store.cancelPendingHAOnboardingVerification()
        #expect(await pending.value == .cancelled)
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "old-valid-token" && !store.isHAConnectionEnabled)

        store.haOnboardingVerifier = { _, _ in }
        #expect(await store.connectHomeAssistantForOnboarding(serverURL: "https://verified.example.local:8123", token: "verified-token") == .connected)
        #expect(KeychainHelper.loadToken(defaults: defaults, vault: vault) == "verified-token" && store.isHAConnectionEnabled)

        do {
            let connectAttempts = RequestCounter()
            let probe = HAWebSocketProvider(baseURLString: "https://ha.example.local:8123", token: "tok")
            await probe.setTestSeams(
                connectOverride: { connectAttempts.increment(); return .failedBeforeAuth(URLError(.cannotConnectToHost)) },
                reconnectSleep: { _ in try await Task.sleep(for: .seconds(60)) }
            )
            await #expect(throws: HomeStore.HAOnboardingVerifyError.self) {
                try await HomeStore.verifyHomeAssistantSnapshot(
                    baseURLString: "https://ha.example.local:8123",
                    token: "tok",
                    probeFactory: { _, _ in probe },
                    timeoutSleep: { try await Task.sleep(for: .seconds(60)) }
                )
            }
            #expect(await probe.isShutDownForTesting && connectAttempts.requests == 1)
        }

        do {
            let connectAttempts = RequestCounter()
            let started = AsyncStream<Void>.makeStream()
            let probe = HAWebSocketProvider(baseURLString: "https://ha.example.local:8123", token: "tok")
            await probe.setTestSeams(
                connectOverride: {
                    connectAttempts.increment()
                    started.continuation.yield()
                    try await Task.sleep(for: .seconds(60))
                    return .failedBeforeAuth(URLError(.timedOut))
                },
                reconnectSleep: { _ in }
            )
            await #expect(throws: HomeStore.HAOnboardingVerifyError.timedOut) {
                try await HomeStore.verifyHomeAssistantSnapshot(
                    baseURLString: "https://ha.example.local:8123",
                    token: "tok",
                    probeFactory: { _, _ in probe },
                    timeoutSleep: {
                        for await _ in started.stream { break }
                    }
                )
            }
            #expect(await probe.isShutDownForTesting && connectAttempts.requests == 1)
        }
    }

    @Test("CapabilitySelectionStore merges concurrent revision conflicts across stores, preserves unknown fields, and honors explicit re-login")
    @MainActor
    func capabilitySelectionRevisionConflictMergeAndRelogin() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let sessionA = MiSession(userId: "11101", cUserId: "c1", ssecurity: "s1", serviceToken: "t1", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let sessionB = MiSession(userId: "22202", cUserId: "c2", ssecurity: "s2", serviceToken: "t2", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        #expect(MiSessionStore.upsert(sessionA, defaults: defaults, vault: vault))
        #expect(MiSessionStore.upsert(sessionB, defaults: defaults, vault: vault))
        #expect(KeychainHelper.saveToken("ha-tok", defaults: defaults, vault: vault))
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")
        defaults.set(true, forKey: "has_completed_onboarding")

        let seedStore = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        let acctA = try #require(seedStore.miAccounts.first { $0.session.userId == "11101" })
        let baseRev = try #require(seedStore.capabilityStoreRevision)

        let rawSeed = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        var seedJSON = try #require(try JSONSerialization.jsonObject(with: rawSeed) as? [String: Any])
        seedJSON["futureFlag"] = "keep-me"
        defaults.set(try JSONSerialization.data(withJSONObject: seedJSON), forKey: CapabilitySelectionStore.storageKey)

        let storeA = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        let storeB = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(storeA.capabilityStoreRevision == baseRev && storeB.capabilityStoreRevision == baseRev)

        #expect(storeA.setMiAccountEnabled(false, id: acctA.id, pauseConfirmed: true).disposition == .allowed)
        storeB.capabilitySelection.enabledFeatures.remove(.sensorHistory)
        #expect(storeB.persistCapabilitySelection())

        #expect(!storeB.isMiAccountEnabled(acctA.id) && storeB.explicitlyDisabledScopes.contains(acctA.id))
        #expect(!storeB.capabilitySelection.enabledFeatures.contains(.sensorHistory))
        #expect(storeB.capabilityStoreRevision == baseRev + 2 && storeB.capabilityMergeConflictCount == 1)

        let storeC = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        storeA.capabilitySelection.enabledFeatures.remove(.voiceInput)
        #expect(storeA.persistCapabilitySelection())
        let refreshedA = MiSession(userId: "11101", cUserId: "c1", ssecurity: "s1-new", serviceToken: "t1-new", expiresAt: Date(timeIntervalSince1970: 4_100_000_000))
        storeC.completeMiLogin(refreshedA)

        #expect(storeC.isMiAccountEnabled(acctA.id) && !storeC.explicitlyDisabledScopes.contains(acctA.id))
        #expect(!storeC.capabilitySelection.enabledFeatures.contains(.voiceInput))
        let rawPersisted = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: rawPersisted) as? [String: Any])
        #expect(persisted["futureFlag"] as? String == "keep-me")
    }
}
