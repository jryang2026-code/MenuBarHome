import Foundation
import Testing
import KeychainTestSupport
@testable import MijiaCore

/// 审计 #7 / #9 / #10：保存失败必须回到 UI、跨区扫码按登录响应里的真实地区落库、开发用
/// `HA_ACCESS_TOKEN` 不得盖过用户保存的凭据或退出登录状态。
struct CredentialSaveResultTests {
    private func memoryVault(_ storage: MemoryVaultStorage = MemoryVaultStorage()) -> CredentialVault {
        CredentialVault(storage: storage.storage)
    }

    private func suiteDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "test.credential-result.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    @Test("A refused LG pairing-key write is reported instead of silently dropped")
    func lgPairingKeyWriteIsReported() throws {
        let storage = MemoryVaultStorage()
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = LGWebOSConfig(host: "192.0.2.10", clientKey: "pairing-key")
        #expect(config.save(to: defaults, vault: vault) == false)
        #expect(defaults.string(forKey: LGWebOSConfig.clientKeyDefaultsKey) == nil,
                "a refused Keychain write must not fall back to a plaintext copy")
        #expect(KeychainHelper.readKeychainSecret(account: LGWebOSConfig.clientKeyAccount, vault: vault) == nil)
    }

    @Test("A stored LG pairing key round-trips through the injected vault")
    func lgPairingKeyRoundTripsThroughVault() throws {
        let vault = memoryVault()
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = LGWebOSConfig(host: "192.0.2.10", clientKey: "pairing-key")
        #expect(config.save(to: defaults, vault: vault))
        #expect(defaults.string(forKey: LGWebOSConfig.clientKeyDefaultsKey) == nil)
        #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey == "pairing-key")
    }

    @Test("An LG pairing confirmation whose key was not stored shows an error, never 'Paired'")
    @MainActor
    func lgPairingRefusalShowsErrorToast() throws {
        let storage = MemoryVaultStorage()
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        #expect(store.applyLGClientKey("pairing-key") == false)
        #expect(store.lgConfig.clientKey.isEmpty, "the in-memory config must not pretend the key was saved")
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("已成功配对"))
        #expect(!notice.message.contains("Paired with"))
    }

    @Test("A stored LG pairing key keeps the success toast")
    @MainActor
    func lgPairingSuccessStillToasts() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        #expect(store.applyLGClientKey("pairing-key"))
        #expect(store.lgConfig.clientKey == "pairing-key")
        let notice = try #require(store.toastNotice)
        #expect(!notice.isError)
    }

    @Test("applyLGClientKey refusal rolls LGWebOSClient back to the persisted key so client and store never diverge")
    @MainActor
    func lgPairingRefusalRollsBackClientConfig() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "persisted-old-key")
        #expect(store.updateLGWebOSConfig(initial))
        let client = try #require(store.lgWebOSClient)
        #expect(await client.configForTesting.clientKey == "persisted-old-key")

        // Simulate LGWebOSClient receiving a new registered key while Keychain write fails.
        storage.writeSucceeds = false
        store.dismissToast()
        await client.simulateRegisteredForTesting(clientKey: "unsaved-tv-key")

        // Wait for the @MainActor callback and client rollback to settle.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.toastNotice == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // Poll until async onClientKeyRegistered callback delivers toast
        }

        #expect(store.lgConfig.clientKey == "persisted-old-key")
        let rollbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await client.configForTesting.clientKey != "persisted-old-key", ContinuousClock.now < rollbackDeadline {
            try await Task.sleep(for: .milliseconds(10)) // Poll until client config rolls back to persisted key
        }
        #expect(
            await client.configForTesting.clientKey == "persisted-old-key",
            "live LGWebOSClient must revert to the persisted key instead of keeping an unsaved pairing key"
        )
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        await client.shutdown()
    }

    @Test("applyLGClientKey persists only once and shows the Paired toast without a redundant didSet save")
    @MainActor
    func lgPairingCommitsInSingleWriteWithoutDidSetFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        // Make the second LGWebOSConfig.save fail even if the vault key was already written,
        // simulating a transient save failure in lgConfig.didSet after applyLGClientKey's own save succeeded.
        #expect(store.applyLGClientKey("single-write-key") == true)
        #expect(store.lgConfigSaveCallsInDidSetForTesting == 0, "applyLGClientKey must not run a redundant save inside lgConfig.didSet")
        #expect(store.lgConfig.clientKey == "single-write-key")
        let notice = try #require(store.toastNotice)
        #expect(!notice.isError)
        #expect(notice.message.contains("已成功配对") || notice.message.contains("Paired with"))
    }

    @Test("updateLGWebOSConfig refusal never shows saved toast, mutates defaults, or starts connecting")
    @MainActor
    func lgConfigUpdateRefusalStopsAndShowsError() async throws {
        let storage = MemoryVaultStorage()
        storage.readResult = .unavailable
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let attempted = LGWebOSConfig(
            isEnabled: true,
            host: "192.0.2.50",
            macAddress: "AA:BB:CC:DD:EE:FF",
            clientKey: "unsaved-key"
        )
        #expect(store.updateLGWebOSConfig(attempted) == false)

        #expect(store.lgConfig == LGWebOSConfig(), "unsaved config must not replace in-memory lgConfig")
        #expect(defaults.object(forKey: "lg_webos_enabled") == nil, "unsaved config must not mutate UserDefaults")
        #expect(store.lgWebOSClient == nil, "unsaved config must not start an LG client connection")
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("已保存并重连"))
        #expect(!notice.message.contains("Saved and reconnecting"))
    }

    @Test("updateLGWebOSConfig refusal with an existing client keeps the old saved config on the client")
    @MainActor
    func lgConfigUpdateRefusalPreservesExistingClientConfig() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key")
        #expect(store.updateLGWebOSConfig(initial))
        let client = try #require(store.lgWebOSClient)

        storage.writeSucceeds = false
        store.dismissToast()
        let replacement = LGWebOSConfig(isEnabled: true, host: "192.0.2.99", clientKey: "unsaved-new-key")
        #expect(store.updateLGWebOSConfig(replacement) == false)

        #expect(store.lgConfig == initial)
        #expect(await client.configForTesting == initial, "client must not connect with unsaved config")
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("已保存并重连"))
        await client.shutdown()
    }

    @Test("updateLGWebOSConfig refusal in Demo Mode still reports the error instead of demo notice")
    @MainActor
    func lgConfigUpdateRefusalInDemoReportsError() throws {
        let storage = MemoryVaultStorage()
        storage.readResult = .unavailable
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil
        store.switchBackend(.demo)

        #expect(store.updateLGWebOSConfig(LGWebOSConfig(isEnabled: true, host: "192.0.2.50")) == false)

        #expect(store.lgConfig == LGWebOSConfig())
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("演示模式下不会连接"))
        #expect(!notice.message.contains("Demo Mode does not connect"))
    }

    @Test("resetLGWebOSTrustAndPair refusal keeps the saved pairing key, stops connecting with empty key, and shows an error")
    @MainActor
    func lgResetTrustRefusalKeepsKeyAndShowsError() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key")
        #expect(store.updateLGWebOSConfig(initial))
        let client = try #require(store.lgWebOSClient)
        #expect(store.lgConfig.clientKey == "saved-key")

        storage.writeSucceeds = false
        store.dismissToast()
        let resetResult = await store.resetLGWebOSTrustAndPair()?.value

        #expect(resetResult == false)
        #expect(store.lgConfig.clientKey == "saved-key", "refused Keychain clear must keep old pairing key")
        #expect(await client.configForTesting.clientKey == "saved-key", "client must not reconnect with unsaved empty key")
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("旧电视身份已清除"))
        #expect(!notice.message.contains("Saved TV identity cleared"))

        // Once Keychain writes work again, retrying clears the key and notifies the user.
        storage.writeSucceeds = true
        store.dismissToast()
        let retryResult = await store.resetLGWebOSTrustAndPair()?.value
        #expect(retryResult == true)
        #expect(store.lgConfig.clientKey.isEmpty)
        #expect(await client.configForTesting.clientKey.isEmpty)
        let retryNotice = try #require(store.toastNotice)
        #expect(!retryNotice.isError)
        await client.shutdown()
    }

    @Test("resetLGWebOSTrustAndPair refusal preserves the pinned TLS certificate, pairing key, and active client connection", .timeLimit(.minutes(1)))
    @MainActor
    func lgResetTrustRefusalPreservesCertificateKeyAndConnection() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key")
        let (connectionStarted, started) = AsyncStream<Void>.makeStream()
        let (connectionLifetime, lifetime) = AsyncStream<Void>.makeStream()
        defer { lifetime.finish() }
        LGWebOSClient.$connectionOverrideForTesting.withValue({
            started.yield(())
            started.finish()
            for await _ in connectionLifetime {}
            try Task.checkCancellation()
        }) {
            #expect(store.updateLGWebOSConfig(initial))
        }
        let client = try #require(store.lgWebOSClient)

        let originalCert = Data("original-lg-tv-certificate".utf8)
        let replacementCert = Data("replacement-lg-tv-certificate".utf8)
        let trust = LGCertificateTrust(vault: vault)
        #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"))

        var connection = connectionStarted.makeAsyncIterator()
        _ = try #require(await connection.next())
        await client.simulateRegisteredForTesting(clientKey: "saved-key")
        let baselineStops = await client.stopCallCountForTesting
        #expect(await client.hasConnectionLoopForTesting)
        #expect(await client.isConnectedForTesting)

        // When Keychain writes are refused, neither the certificate pin nor the pairing key may be cleared,
        // and the active client connection must remain intact.
        storage.writeSucceeds = false
        store.dismissToast()
        let resetResult = await store.resetLGWebOSTrustAndPair()?.value

        #expect(resetResult == false)
        #expect(store.lgConfig.clientKey == "saved-key")
        #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey == "saved-key")
        #expect(await client.configForTesting.clientKey == "saved-key")
        #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"),
                "failed trust reset must keep the original pinned certificate")
        #expect(!trust.accepts(certificate: replacementCert, host: "192.0.2.10"),
                "failed trust reset must continue rejecting an untrusted replacement certificate")
        #expect(await client.hasConnectionLoopForTesting,
                "failed trust reset must keep the connection loop running")
        #expect(await client.stopCallCountForTesting == baselineStops,
                "failed trust reset must not stop or tear down the live client")
        #expect(await client.isConnectedForTesting)
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("旧电视身份已清除"))
        #expect(!notice.message.contains("Saved TV identity cleared"))

        // Once Keychain writes work again, retrying clears both the pairing key and the certificate pin.
        storage.writeSucceeds = true
        store.dismissToast()
        let retryResult = await store.resetLGWebOSTrustAndPair()?.value
        #expect(retryResult == true)
        #expect(store.lgConfig.clientKey.isEmpty)
        #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey.isEmpty)
        #expect(await client.configForTesting.clientKey.isEmpty)
        #expect(trust.accepts(certificate: replacementCert, host: "192.0.2.10"),
                "successful trust reset must allow trusting the new TV certificate")
        await client.shutdown()
    }

    @Test("Late callbacks from a replaced or shut down LGWebOSClient cannot overwrite current device or pairing key")
    @MainActor
    func staleLGClientCallbacksCannotOverwriteCurrentDeviceOrKey() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let oldConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", name: "Old TV", clientKey: "old-key")
        #expect(store.updateLGWebOSConfig(oldConfig))
        let oldClient = try #require(store.lgWebOSClient)

        let newConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.20", name: "New TV", clientKey: "new-key")
        #expect(newConfig.save(to: defaults, vault: vault))
        store.lgConfig = newConfig
        store.startLGWebOSIfNeeded()
        let newClient = try #require(store.lgWebOSClient)
        #expect(newClient !== oldClient)

        await newClient.simulateRegisteredForTesting(clientKey: "new-key")
        let waitNewDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.latestLGDevice?.name != "New TV", ContinuousClock.now < waitNewDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.latestLGDevice?.name == "New TV")

        // Simulate late callbacks arriving from the replaced client.
        await oldClient.simulateRegisteredForTesting(clientKey: "stale-old-key")
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.lgConfig.clientKey == "new-key", "stale client callback must not overwrite current pairing key")
        #expect(store.latestLGDevice?.name == "New TV", "stale client callback must not overwrite current LG device")
        #expect(store.devices.first(where: { $0.id == LGWebOSProtocol.deviceId })?.name == "New TV")

        // Post-shutdown late callbacks from the active client must also be rejected.
        await store.shutdown()
        await newClient.simulateRegisteredForTesting(clientKey: "post-shutdown-key")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.lgConfig.clientKey == "new-key")
        #expect(store.latestLGDevice?.name == "New TV")
    }

    @Test("LGWebOSClient.resetTrust keeps the active session intact when clearing trust fails")
    func lgClientResetTrustFailureDoesNotStopClient() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let trust = LGCertificateTrust(vault: vault)
        let originalCert = Data("original-lg-cert".utf8)
        let replacementCert = Data("replacement-lg-cert".utf8)
        #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"))

        let client = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key"),
            trustStore: trust,
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        await client.prepareSessionForTesting()
        let baselineInvalidations = await client.invalidatedSessionCountForTesting
        let baselineStops = await client.stopCallCountForTesting
        #expect(await client.hasActiveSessionForTesting)

        storage.writeSucceeds = false
        await #expect(throws: LGCertificateTrust.Failure.self) {
            try await client.resetTrust()
        }
        #expect(await client.hasActiveSessionForTesting, "resetTrust failure must not invalidate the live session")
        #expect(await client.invalidatedSessionCountForTesting == baselineInvalidations)
        #expect(await client.stopCallCountForTesting == baselineStops)
        #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"))
        #expect(!trust.accepts(certificate: replacementCert, host: "192.0.2.10"))
        await client.shutdown()
    }

    @Test("resetLGWebOSTrustAndPair never splits certificate trust and pairing key when only one write succeeds")
    @MainActor
    func lgResetTrustPartialWriteNeverSplitsCertAndKey() async throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key")
        #expect(store.updateLGWebOSConfig(initial))
        let client = try #require(store.lgWebOSClient)

        let originalCert = Data("original-lg-tv-certificate".utf8)
        let replacementCert = Data("replacement-lg-tv-certificate".utf8)
        let trust = LGCertificateTrust(vault: vault)
        #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"))

        let loopDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !client.hasConnectionLoopForTesting, ContinuousClock.now < loopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let baselineStops = await client.stopCallCountForTesting

        // Simulate a write sequence where a first Keychain write succeeds and a second fails.
        // An atomic reset either commits both together (returning true) or fails cleanly keeping both.
        let writesBeforeReset = storage.writes
        storage.writeSucceeds = false
        storage.writeSucceedsSequence = [true, false]
        store.dismissToast()
        let resetResult = await store.resetLGWebOSTrustAndPair()?.value

        if resetResult == true {
            #expect(storage.writes == writesBeforeReset + 1, "reset must clear cert pin and pairing key in a single atomic vault write")
            #expect(storage.storedItems?.isEmpty == true, "both pairing key and certificate pin must be cleared together")
            #expect(store.lgConfig.clientKey.isEmpty)
            #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey.isEmpty)
            #expect(await client.configForTesting.clientKey.isEmpty)
            storage.writeSucceedsSequence = []
            storage.writeSucceeds = true
            #expect(trust.accepts(certificate: replacementCert, host: "192.0.2.10"))
            let notice = try #require(store.toastNotice)
            #expect(!notice.isError)
        } else {
            #expect(store.lgConfig.clientKey == "saved-key")
            #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey == "saved-key")
            #expect(await client.configForTesting.clientKey == "saved-key")
            #expect(trust.accepts(certificate: originalCert, host: "192.0.2.10"))
            #expect(!trust.accepts(certificate: replacementCert, host: "192.0.2.10"))
            #expect(await client.hasConnectionLoopForTesting)
            #expect(await client.stopCallCountForTesting == baselineStops)
            let notice = try #require(store.toastNotice)
            #expect(notice.isError)
        }
        await client.shutdown()
    }

    @Test("AssistantConfig.save reports a refused Keychain write and leaves the saved endpoint alone")
    func assistantConfigSaveReportsFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved = AssistantConfig(
            baseURL: "https://openrouter.ai/api/v1",
            model: "~typesafe/jev-latest",
            apiKey: "sk-saved"
        )
        #expect(saved.save(to: defaults, vault: vault))
        let baseline = AssistantConfig.load(from: defaults, vault: vault)

        storage.writeSucceeds = false
        let replacement = AssistantConfig(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-replacement"
        )
        #expect(replacement.save(to: defaults, vault: vault) == false)
        let reloaded = AssistantConfig.load(from: defaults, vault: vault)
        #expect(reloaded.baseURL == baseline.baseURL, "a refused key write must not move the endpoint")
        #expect(reloaded.apiKey == "sk-saved", "the previous key stays active")
    }

    @Test("HomeStore.assistantConfigSave reports the refused write to the caller")
    @MainActor
    func storeAssistantSaveReportsFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        storage.writeSucceeds = false
        let config = AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "m", apiKey: "sk-x")
        #expect(store.saveAssistantConfig(config) == false)
        #expect(store.assistantConfig.apiKey.isEmpty)
    }

    @Test("OpenRouter/Jev save never partially commits when one of the two Keychain slots fails")
    func openRouterSaveIsTransactionalOnPartialFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = AssistantConfig(
            baseURL: "https://openrouter.ai/api/v1",
            model: "~typesafe/jev-latest",
            apiKey: "sk-initial"
        )
        #expect(initial.save(to: defaults, vault: vault))
        let providerAccount = KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev)
        let legacyAccount = KeychainHelper.assistantAPIKeyAccount
        #expect(KeychainHelper.loadSecret(account: providerAccount, defaults: defaults, vault: vault) == "sk-initial")
        #expect(KeychainHelper.loadSecret(account: legacyAccount, defaults: defaults, vault: vault) == "sk-initial")

        // Case 1: first write succeeds, second write fails.
        // If saveSecret writes both slots atomically in a single vault persist, it succeeds in 1 write and both slots hold sk-unsaved.
        // If saveSecret writes two slots sequentially, the second write fails and it must roll back the first slot to sk-initial.
        storage.writeSucceedsSequence = [true, false]
        storage.writeSucceeds = true

        let attempted = AssistantConfig(
            baseURL: "https://openrouter.ai/api/v1",
            model: "~typesafe/jev-latest",
            apiKey: "sk-unsaved"
        )
        let writesBefore = storage.writes
        let saved = attempted.save(to: defaults, vault: vault)

        if saved {
            #expect(storage.writes - writesBefore == 1, "single-write atomic commit must update both slots in one vault write")
            #expect(KeychainHelper.loadSecret(account: providerAccount, defaults: defaults, vault: vault) == "sk-unsaved")
            #expect(KeychainHelper.loadSecret(account: legacyAccount, defaults: defaults, vault: vault) == "sk-unsaved")

            // Also verify that when that single write is refused (comparing against the queued false), neither slot changes.
            let refused = AssistantConfig(
                baseURL: "https://openrouter.ai/api/v1",
                model: "~typesafe/jev-latest",
                apiKey: "sk-refused"
            )
            #expect(refused.save(to: defaults, vault: vault) == false)
            #expect(
                AssistantConfig.userStoredAPIKey(
                    forBaseURL: "https://openrouter.ai/api/v1",
                    defaults: defaults,
                    vault: vault
                ) == "sk-unsaved"
            )
            #expect(KeychainHelper.loadSecret(account: providerAccount, defaults: defaults, vault: vault) == "sk-unsaved")
            #expect(KeychainHelper.loadSecret(account: legacyAccount, defaults: defaults, vault: vault) == "sk-unsaved")
        } else {
            #expect(
                AssistantConfig.userStoredAPIKey(
                    forBaseURL: "https://openrouter.ai/api/v1",
                    defaults: defaults,
                    vault: vault
                ) == "sk-initial",
                "a refused OpenRouter save must not leave userStoredAPIKey reading the new key"
            )
            #expect(KeychainHelper.loadSecret(account: providerAccount, defaults: defaults, vault: vault) == "sk-initial")
            #expect(KeychainHelper.loadSecret(account: legacyAccount, defaults: defaults, vault: vault) == "sk-initial")
        }
    }
}

struct MiLoginRegionInferenceTests {
    @Test("The login location's p_idc selects the account's real region")
    func regionFromDataCenter() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=AT&p_idc=Europe&nonce=x"
        )!) == "de")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=CN&p_idc=China&nonce=x"
        )!) == "cn")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=IN&p_idc=India&nonce=x"
        )!) == "i2")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=SG&p_idc=Singapore&nonce=x"
        )!) == "sg")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=US&p_idc=America&nonce=x"
        )!) == "us")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=RU&p_idc=Russia&nonce=x"
        )!) == "ru")
    }

    @Test("A region country code is used when the data-center name is unfamiliar")
    func regionFallsBackToCountryCode() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=de"
        )!) == "de")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=GB&p_idc=Europe"
        )!) == "de")
    }

    @Test("Unknown hosts, plaintext locations and missing hints never invent a region")
    func regionRejectsUntrustedOrAmbiguousLocations() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://evil.example/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://xiaomi.com.evil.example/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "http://sts.api.io.mi.com/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=XX&p_idc=Unknown"
        )!) == nil)
    }

    @Test("waitForScan stores the region the login response proves, not the hand-picked one")
    func waitForScanUsesProvenRegion() async throws {
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.api.io.mi.com/sts?d=wb_1&p_ur=DE&p_idc=Europe"}"#)
            }
            if url.hasPrefix("https://sts.api.io.mi.com") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/; domain=.mi.com"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport, region: "cn")
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )
        let session = try await login.waitForScan(ticket)
        #expect(session.region == "de")
    }

    @Test("waitForScan keeps the selected region when the location carries no trusted hint")
    func waitForScanKeepsSelectedRegionWhenUnknown() async throws {
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.api.io.mi.com/sts?d=wb_1&p_ur=XX&p_idc=Unknown"}"#)
            }
            if url.hasPrefix("https://sts.api.io.mi.com") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/; domain=.mi.com"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport, region: "sg")
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )
        let session = try await login.waitForScan(ticket)
        #expect(session.region == "sg")
    }
}

struct HAEnvironmentTokenTests {
    private let env: [String: String] = [
        KeychainHelper.environmentTokenName: "env-token",
        KeychainHelper.environmentTokenOptInKey: "1",
    ]

    @Test("A saved credential always wins over the development environment token")
    func savedCredentialWins() {
        #expect(KeychainHelper.resolvedToken(stored: "saved-token", environment: env, signedOut: false) == "saved-token")
    }

    @Test("The environment token needs an explicit opt-in")
    func environmentTokenNeedsOptIn() {
        let withoutOptIn = [KeychainHelper.environmentTokenName: "env-token"]
        #expect(KeychainHelper.resolvedToken(stored: "", environment: withoutOptIn, signedOut: false) == "")
        #expect(KeychainHelper.resolvedToken(stored: "", environment: env, signedOut: false) == "env-token")
    }

    @Test("Signing out keeps the environment token from signing the user back in")
    func signOutSuppressesEnvironmentToken() {
        #expect(KeychainHelper.resolvedToken(stored: "", environment: env, signedOut: true) == "")
    }

    @Test("Saving and clearing the token toggles the sign-out marker on the default suite")
    func saveTokenTogglesSignOutMarker() throws {
        let suite = "test.env-token.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)

        #expect(KeychainHelper.saveToken("saved-token", defaults: defaults, vault: vault))
        #expect(defaults.bool(forKey: KeychainHelper.environmentTokenSignedOutKey) == false)
        #expect(KeychainHelper.saveToken("", defaults: defaults, vault: vault))
        #expect(defaults.bool(forKey: KeychainHelper.environmentTokenSignedOutKey))
    }
}
