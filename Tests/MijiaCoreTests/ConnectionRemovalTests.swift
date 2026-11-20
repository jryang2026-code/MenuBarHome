import Foundation
import KeychainTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct ConnectionRemovalTests {
    private actor GatedShutdownProvider: HomeProvider {
        private var shutdownStartedCont: CheckedContinuation<Void, Never>?
        private var shutdownReleaseCont: CheckedContinuation<Void, Never>?
        private var shutdownStarted = false
        private var released = false
        private(set) var shutdownCount = 0

        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            AsyncStream { cont in
                cont.yield(.statusChanged(.connected))
                var home = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
                home.isInitialLoadComplete = true
                home.closesAwayGap = true
                cont.yield(.snapshotUpdated(home))
            }
        }
        func execute(_ command: DeviceCommand) async throws {}
        func refreshNow() async {}

        func shutdown() async {
            shutdownCount += 1
            shutdownStarted = true
            shutdownStartedCont?.resume()
            shutdownStartedCont = nil
            if !released {
                await withCheckedContinuation { shutdownReleaseCont = $0 }
            }
        }

        func waitUntilShutdownStarted() async {
            if shutdownStarted { return }
            await withCheckedContinuation { shutdownStartedCont = $0 }
        }

        func releaseShutdown() {
            released = true
            shutdownReleaseCont?.resume()
            shutdownReleaseCont = nil
        }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private static let sessionA = MiSession(userId: "10001", cUserId: "c1", ssecurity: "sec-a", serviceToken: "tok-a", region: "cn", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    private static let sessionB = MiSession(userId: "20002", cUserId: "c2", ssecurity: "sec-b", serviceToken: "tok-b", region: "sg", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    private static let accA = MiAccount(session: sessionA)
    private static let accB = MiAccount(session: sessionB)
    private static let haURL = "http://ha.removal.example:8123"
    private static let stubMiFactory: @MainActor ([MiAccount]) -> MiAccountsProvider = { accounts in
        MiAccountsProvider(accounts: accounts, localClientFactory: { nil }, pollInterval: .seconds(3600), followUpDelay: .seconds(3600))
    }

    @MainActor
    private static func makeSuite(_ name: String) throws -> (String, UserDefaults) {
        let suite = "test.p2cm.\(name).\(UUID().uuidString)"
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    private static func seedAllSlots(vault: CredentialVault, defaults: UserDefaults) throws {
        #expect(KeychainHelper.saveToken("ha-secret-tok", defaults: defaults, vault: vault))
        #expect(MiSessionStore.saveAccounts([accA, accB], defaults: defaults, vault: vault))
        #expect(vault.set(Data("sk-openai".utf8), for: "assistant_api_key_openai"))
        #expect(vault.set(Data("sk-openrouter".utf8), for: "assistant_api_key_openrouter"))
        #expect(vault.set(Data("lg-key".utf8), for: LGWebOSConfig.clientKeyAccount))
    }

    @Test("Strict record parsing preserves unknown fields, rejects foreign slots, and quarantines corrupt payloads fail-closed")
    @MainActor
    func strictParsingUnknownFieldsAndCorruptQuarantine() throws {
        let (suite, defaults) = try Self.makeSuite("strict")
        defer { defaults.removePersistentDomain(forName: suite) }

        let haScope = ConnectionRemovalStore.haScope(serverURL: Self.haURL)
        let seedJSON: [String: Any] = [
            "schemaVersion": 1, "ownerVersion": 3, "futureTop": ["keep": true],
            "removals": [[
                "scope": haScope, "kind": "ha", "ownerVersion": 3, "createdAtMs": 1000, "updatedAtMs": 1000,
                "stage": "failed", "attempts": 1, "slotNames": ["ha_access_token"], "futureRec": "keep-me",
            ]],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: seedJSON), forKey: ConnectionRemovalStore.storageKey)
        let read = ConnectionRemovalStore.readState(defaults: defaults)
        #expect(!read.readError)
        #expect(read.records.count == 1)

        // Updating preserves unknown top-level and record-level fields and bumps ownerVersion.
        let bumped = try #require(ConnectionRemovalStore.beginRemoval(kind: .ha, scope: haScope, stage: .cleaning, defaults: defaults))
        #expect(bumped.ownerVersion == 4)
        #expect(bumped.attempts == 2)
        #expect(!ConnectionRemovalStore.completeRemoval(scope: haScope, ownerVersion: 3, defaults: defaults))
        let rawPersisted = try #require(defaults.data(forKey: ConnectionRemovalStore.storageKey))
        let persisted = try #require(try JSONSerialization.jsonObject(with: rawPersisted) as? [String: Any])
        #expect((persisted["futureTop"] as? [String: Bool]) == ["keep": true])
        let firstRec = try #require((persisted["removals"] as? [[String: Any]])?.first)
        #expect(firstRec["futureRec"] as? String == "keep-me")

        // Foreign slot whitelist rejection.
        #expect(ConnectionRemovalStore.beginRemoval(kind: .ha, scope: haScope, slotNames: ["assistant_api_key_openai"], defaults: defaults) == nil)

        // Corrupt payload is quarantined and NEVER treated as "no pending removals".
        let corrupt = Data("{broken-json".utf8)
        defaults.set(corrupt, forKey: ConnectionRemovalStore.storageKey)
        let bad = ConnectionRemovalStore.readState(defaults: defaults)
        #expect(bad.readError)
        #expect(ConnectionRemovalStore.hasPending(kind: .ha, defaults: defaults))
        #expect(ConnectionRemovalStore.isPending(scope: haScope, defaults: defaults))
        let quarantineKey = try #require(ConnectionRemovalStore.quarantineCorruptPayloadIfNeeded(defaults: defaults))
        #expect(defaults.data(forKey: quarantineKey) == corrupt)

        // Cold launch with corrupt payload fails closed (`isIdentityUncertain`) and blocks saves.
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: MemoryVaultStorage().storage), miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        #expect(store.hasCorruptConnectionRemovalState)
        #expect(store.isIdentityUncertain)
        #expect(!store.updateConnection(serverURL: Self.haURL, token: "new-tok"))
    }

    @Test("HA removal previews real scope, runs record -> drain -> delete ONLY ha_access_token -> clear, and preserves history & other slots")
    @MainActor
    func haRemovalOrderSlotBoundaryAndHistoryPreserved() async throws {
        let (suite, defaults) = try Self.makeSuite("ha-order")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        defaults.set("ha-uuid-123", forKey: HAAddressPolicy.rememberedUUIDKey)
        HAPlaintextConsent.approve(Self.haURL, defaults: defaults)

        let gated = GatedShutdownProvider()
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in gated })
        store.toastAutoDismissInterval = nil

        // Seed energy/sensor/offline history and user preference.
        let plug1 = SmartDevice(id: "plug.1", name: "插座", roomId: "r1", roomName: "客厅", model: "cuco.plug", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.p1", isOn: true, powerWatts: 42, energyKwh: 1.0)))
        let plug2 = SmartDevice(id: "plug.1", name: "插座", roomId: "r1", roomName: "客厅", model: "cuco.plug", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.p1", isOn: true, powerWatts: 42, energyKwh: 2.5)))
        let sensor = SmartDevice(id: "sensor.1", name: "温湿度", roomId: "r1", roomName: "客厅", model: "miaomiaoce.sensor", isOnline: true, kind: .sensor(SensorSpec(temperature: 23.5, humidity: 50)))
        store.energyHistory.record(devices: [plug1], deviceBackends: ["plug.1": .homeAssistant], now: Self.fixedNow)
        store.energyHistory.record(devices: [plug2], deviceBackends: ["plug.1": .homeAssistant], now: Self.fixedNow.addingTimeInterval(600))
        store.sensorHistory.record(devices: [sensor], now: Self.fixedNow)
        store.offlineHistory.record(devices: [plug2], now: Self.fixedNow)
        store.favoriteDeviceIds.insert("plug.1")

        let preview = store.previewHomeAssistantRemoval()
        #expect(preview.credentialSlotsToClear == [KeychainHelper.tokenAccount])
        #expect(preview.clearsPlaintextConsent)
        #expect(preview.clearsServerURLBinding)
        #expect(preview.preservesHistory)

        let miPreview = try #require(store.previewMiAccountRemoval(id: Self.accB.id))
        #expect(miPreview.credentialSlotsToClear == [MiSessionStore.keychainAccount])
        #expect(!miPreview.clearsSharedItems)
        #expect(miPreview.remainingMiAccountCount == 1)
        #expect(miPreview.preservesHistory)

        let removalTask = Task { await store.removeHomeAssistantConnection() }
        await gated.waitUntilShutdownStarted()

        // While draining: record exists, HA is disabled, and the token has NOT been deleted yet.
        #expect(ConnectionRemovalStore.find(scope: store.homeAssistantScopeIdentifier, defaults: defaults)?.stage == .draining)
        #expect(!store.isHAConnectionEnabled)
        #expect(vault.lookup("ha_access_token") == .value(Data("ha-secret-tok".utf8)))
        #expect(!store.updateConnection(serverURL: "https://other.ha.local:8123", token: "blocked"))

        await gated.releaseShutdown()
        let outcome = await removalTask.value
        #expect(outcome == .completed)
        #expect(ConnectionRemovalStore.readState(defaults: defaults).records.isEmpty)
        #expect(vault.lookup("ha_access_token") == .missing)
        // Other slots survive intact.
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).map(\.id) == [Self.accA.id, Self.accB.id])
        #expect(vault.lookup("assistant_api_key_openai") == .value(Data("sk-openai".utf8)))
        #expect(vault.lookup("assistant_api_key_openrouter") == .value(Data("sk-openrouter".utf8)))
        #expect(vault.lookup(LGWebOSConfig.clientKeyAccount) == .value(Data("lg-key".utf8)))
        // HA-scoped bindings cleared; HA history preserved under its original scope ("历史按原归属保留").
        #expect(!HAPlaintextConsent.isApproved(Self.haURL, defaults: defaults))
        #expect(defaults.string(forKey: HAAddressPolicy.rememberedUUIDKey) == nil)
        let persistedEnergy = EnergyHistory(defaults: defaults)
        persistedEnergy.setConnectionScope(ConnectionRemovalStore.haScope(serverURL: Self.haURL))
        let persistedSensor = SensorHistory(defaults: defaults)
        persistedSensor.setConnectionScope(ConnectionRemovalStore.haScope(serverURL: Self.haURL))
        #expect(persistedEnergy.hasMeasuredConsumption)
        #expect(persistedSensor.points(forDevice: "sensor.1", window: .last24Hours, now: Self.fixedNow).contains { $0.isObserved })
        #expect(store.favoriteDeviceIds.contains("plug.1"))
    }

    @Test("Failed removal survives crash/relaunch without reviving credentials, blocks HA saves, and finishes on retry")
    @MainActor
    func crashRecoveryRestartNonRevivalAndRetry() async throws {
        let (suite, defaults) = try Self.makeSuite("retry")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("p2cm-topo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let topoCache = MiTopologyCache(directory: tempDir)
        let devRec = MiDeviceRecord(did: "d1", name: "灯", model: "yeelink.light.lamp4", isOnline: true)
        topoCache.save(CachedMiTopology(savedAt: Self.fixedNow, devices: [devRec], rooms: []), for: Self.sessionB)

        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, topologyCache: topoCache, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil

        // Fail vault writes during both HA and Mi-B removals.
        mem.writeSucceeds = false
        let haFail = await store.removeHomeAssistantConnection()
        if case .incomplete = haFail {} else { Issue.record("expected incomplete HA removal, got \(haFail)") }
        let miFail = await store.removeMiAccount(id: Self.accB.id)
        if case .incomplete = miFail {} else { Issue.record("expected incomplete Mi removal, got \(miFail)") }
        #expect(store.pendingConnectionRemovals.count == 2)

        // Relaunch with a brand new HomeStore: neither pending scope revives; AccA stays active.
        let restarted = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage), topologyCache: topoCache, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        restarted.toastAutoDismissInterval = nil
        #expect(!restarted.hasHASource)
        #expect(restarted.loadHAToken().isEmpty)
        #expect(!restarted.activeBackends.contains(.homeAssistant))
        #expect(restarted.miAccounts.map(\.id) == [Self.accA.id])
        #expect(restarted.pendingConnectionRemovals.count == 2)
        // Any HA credential save (same or different URL) and removed Mi re-login are refused.
        #expect(!restarted.updateConnection(serverURL: Self.haURL, token: "new-ha"))
        #expect(!restarted.updateConnection(serverURL: "https://another.ha.local:8123", token: "new-ha"))
        #expect(!restarted.completeMiLogin(Self.sessionB))

        // Unlock writes and retry both removals.
        mem.writeSucceeds = true
        #expect(await restarted.retryConnectionRemoval(scope: restarted.homeAssistantScopeIdentifier) == .completed)
        #expect(await restarted.retryConnectionRemoval(scope: Self.accB.id) == .completed)
        try await awaitState { restarted.pendingConnectionRemovals.isEmpty }

        #expect(CredentialVault(storage: mem.storage).lookup("ha_access_token") == .missing)
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: CredentialVault(storage: mem.storage)).map(\.id) == [Self.accA.id])
        #expect(CredentialVault(storage: mem.storage).lookup("assistant_api_key_openai") == .value(Data("sk-openai".utf8)))
        #expect(topoCache.load(for: Self.sessionB) == nil)
        // Now HA save succeeds again.
        #expect(restarted.updateConnection(serverURL: "https://fresh.ha.local:8123", token: "fresh-tok"))
    }

    @Test("Concurrent rebind protection keeps rebound sessions/tokens and fails closed on unreadable ownership")
    @MainActor
    func concurrentRebindAndFailClosedOwnership() async throws {
        let (suite, defaults) = try Self.makeSuite("rebind")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)

        // 1. Mi session already belongs to AccA only -> AccB cleanup keeps AccA intact and still lets AccB finalize local cleanup.
        let recB = try #require(ConnectionRemovalStore.beginRemoval(kind: .mi, scope: Self.accB.id, accountId: Self.accB.id, defaults: defaults))
        #expect(MiSessionStore.saveAccounts([Self.accA], defaults: defaults, vault: vault))
        let resHanded = ConnectionRemovalStore.executeSlotDeletion(record: recB, defaults: defaults, vault: vault)
        #expect(resHanded == .completed(reboundPreserved: false))
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).map(\.id) == [Self.accA.id])

        // 1b. HA token concurrently overwritten with a newer token -> fingerprint mismatch preserves it.
        let haRecOld = try #require(ConnectionRemovalStore.beginRemoval(
            kind: .ha, scope: ConnectionRemovalStore.haScope(serverURL: Self.haURL),
            credentialFingerprint: ConnectionRemovalStore.fingerprint(haToken: "stale-ha-tok"), defaults: defaults
        ))
        #expect(ConnectionRemovalStore.executeSlotDeletion(record: haRecOld, defaults: defaults, vault: vault) == .completed(reboundPreserved: true))
        #expect(vault.lookup("ha_access_token") == .value(Data("ha-secret-tok".utf8)))
        _ = ConnectionRemovalStore.completeRemoval(scope: haRecOld.scope, ownerVersion: haRecOld.ownerVersion, defaults: defaults)

        // 2. Same account concurrently rebound with a newer serviceToken -> fingerprint mismatch preserves it.
        let newerB = MiSession(userId: "20002", cUserId: "c2", ssecurity: "sec-b-new", serviceToken: "tok-b-new", region: "sg")
        #expect(MiSessionStore.saveAccounts([Self.accA, MiAccount(session: newerB)], defaults: defaults, vault: vault))
        let recOldB = try #require(ConnectionRemovalStore.beginRemoval(
            kind: .mi, scope: Self.accB.id, accountId: Self.accB.id,
            credentialFingerprint: ConnectionRemovalStore.fingerprint(miSession: Self.sessionB), defaults: defaults
        ))
        #expect(ConnectionRemovalStore.executeSlotDeletion(record: recOldB, defaults: defaults, vault: vault) == .completed(reboundPreserved: true))
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).count == 2)

        // 3. Unreadable/corrupt mi_session -> fail-closed without deleting anything.
        #expect(vault.set(Data("corrupt-mi".utf8), for: MiSessionStore.keychainAccount))
        let resCorrupt = ConnectionRemovalStore.executeSlotDeletion(record: recOldB, defaults: defaults, vault: vault)
        #expect(resCorrupt == .incomplete(reason: "mi_session_unreadable", remainingSlots: [MiSessionStore.keychainAccount]))
        #expect(vault.lookup(MiSessionStore.keychainAccount) == .value(Data("corrupt-mi".utf8)))

        // 4. Superseded ownerVersion during drain stops older removal without deleting newly written token.
        #expect(MiSessionStore.saveAccounts([Self.accA], defaults: defaults, vault: vault))
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        store.connectionRemovalBeforeSlotDeleteHook = { rec in
            _ = ConnectionRemovalStore.beginRemoval(kind: .ha, scope: rec.scope, stage: .failed, defaults: defaults)
        }
        #expect(await store.removeHomeAssistantConnection() == .completed)
        #expect(vault.lookup("ha_access_token") == .value(Data("ha-secret-tok".utf8)))
        #expect(ConnectionRemovalStore.find(scope: store.homeAssistantScopeIdentifier, defaults: defaults)?.ownerVersion ?? 0 > 1)
    }

    @Test("Launch resumes interrupted removal while keeping its scope offline")
    @MainActor
    func launchResumesInterruptedRemoval() async throws {
        let (suite, defaults) = try Self.makeSuite("interrupted-launch")
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        try #require(ConnectionRemovalStore.beginRemoval(
            kind: .mi, scope: Self.accB.id, accountId: Self.accB.id,
            credentialFingerprint: ConnectionRemovalStore.fingerprint(miSession: Self.sessionB),
            nowMs: Int64(Self.fixedNow.timeIntervalSince1970 * 1000), defaults: defaults
        ) != nil)

        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault,
                              miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        #expect(store.miAccounts.map(\.id) == [Self.accA.id])
        try await awaitState { store.pendingConnectionRemovals.isEmpty }
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).map(\.id) == [Self.accA.id])
        #expect(vault.lookup("assistant_api_key_openai") == .value(Data("sk-openai".utf8)))
    }

    @Test("HA removal with an unreadable token vault writes no record and succeeds on retry once readable")
    @MainActor
    func haRemovalWithUnreadableVaultStaysRetryable() async throws {
        let (suite, defaults) = try Self.makeSuite("unreadable-vault")
        defer { defaults.removePersistentDomain(forName: suite) }
        // A legacy per-account HA item whose read is declined: identity stays certain in demo,
        // but the token cannot be fingerprinted yet.
        let legacy = MemoryLegacyItems([KeychainHelper.tokenAccount: Data("ha-secret-tok".utf8)], unreadable: [KeychainHelper.tokenAccount])
        let vault = CredentialVault(storage: MemoryVaultStorage().storage, legacy: legacy.legacy)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        #expect(!store.isIdentityUncertain)

        let refused = await store.removeHomeAssistantConnection()
        #expect(refused == .incomplete(reason: "keychain_unavailable", remainingSlots: [KeychainHelper.tokenAccount]))
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
        #expect(store.pendingConnectionRemovals.isEmpty)
        #expect(store.toastNotice?.isError == true)

        legacy.allow(KeychainHelper.tokenAccount)
        #expect(await store.removeHomeAssistantConnection() == .completed)
        #expect(vault.lookup(KeychainHelper.tokenAccount) == .missing)
        #expect(ConnectionRemovalStore.readState(defaults: defaults).records.isEmpty)
    }

    @Test("A pending HA record without an owner fingerprint recaptures it on retry and finishes")
    @MainActor
    func ownerlessHARecordRecapturesFingerprintOnRetry() async throws {
        let (suite, defaults) = try Self.makeSuite("ownerless-retry")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let haScope = ConnectionRemovalStore.haScope(serverURL: Self.haURL)
        try #require(ConnectionRemovalStore.beginRemoval(
            kind: .ha, scope: haScope, serverURL: Self.haURL, stage: .failed, error: "keychain_unavailable",
            nowMs: Int64(Self.fixedNow.timeIntervalSince1970 * 1000), defaults: defaults
        )?.credentialFingerprint == nil)

        let store = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage), miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        #expect(store.homeAssistantScopeIdentifier == haScope)
        #expect(await store.retryConnectionRemoval(scope: haScope) == .completed)
        let reread = CredentialVault(storage: mem.storage)
        #expect(reread.lookup(KeychainHelper.tokenAccount) == .missing)
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: reread).count == 2)
        #expect(reread.lookup("assistant_api_key_openai") == .value(Data("sk-openai".utf8)))
        #expect(ConnectionRemovalStore.readState(defaults: defaults).records.isEmpty)
    }

    @Test("Relaunch after a crash between slot deletion and record clear converges without errors or extra deletions")
    @MainActor
    func halfDeletedCleaningRecordsConvergeOnRelaunch() async throws {
        let (suite, defaults) = try Self.makeSuite("half-deleted")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let nowMs = Int64(Self.fixedNow.timeIntervalSince1970 * 1000)
        try #require(ConnectionRemovalStore.beginRemoval(
            kind: .ha, scope: ConnectionRemovalStore.haScope(serverURL: Self.haURL), serverURL: Self.haURL,
            credentialFingerprint: ConnectionRemovalStore.fingerprint(haToken: "ha-secret-tok"),
            stage: .cleaning, nowMs: nowMs, defaults: defaults
        ) != nil)
        try #require(ConnectionRemovalStore.beginRemoval(
            kind: .mi, scope: Self.accB.id, accountId: Self.accB.id,
            credentialFingerprint: ConnectionRemovalStore.fingerprint(miSession: Self.sessionB),
            stage: .cleaning, nowMs: nowMs, defaults: defaults
        ) != nil)
        // The crash hit after both slots were rewritten but before either record was cleared.
        #expect(vault.set(nil, for: KeychainHelper.tokenAccount))
        #expect(MiSessionStore.saveAccounts([Self.accA], defaults: defaults, vault: vault))
        let slotsAfterCrash = try #require(mem.storedItems)

        let restarted = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage), miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        restarted.toastAutoDismissInterval = nil
        restarted.assistantNow = { Self.fixedNow }
        #expect(!restarted.isIdentityUncertain)
        try await awaitState { restarted.pendingConnectionRemovals.isEmpty && restarted.isRemovingConnectionScopes.isEmpty }
        #expect(ConnectionRemovalStore.readState(defaults: defaults).records.isEmpty)
        #expect(restarted.toastNotice?.isError != true)
        #expect(mem.storedItems == slotsAfterCrash)
        #expect(restarted.miAccounts.map(\.id) == [Self.accA.id])
        #expect(!restarted.hasHASource)
    }

    @Test("Re-scanning the same Xiaomi account while its removal drains is refused and leaves the vault untouched")
    @MainActor
    func sameAccountRescanDuringDrainIsRefused() async throws {
        let (suite, defaults) = try Self.makeSuite("rescan-during-drain")
        defer { defaults.removePersistentDomain(forName: suite) }
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        try Self.seedAllSlots(vault: vault, defaults: defaults)
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        store.assistantNow = { Self.fixedNow }

        let (entered, enteredCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        store.connectionRemovalBeforeSlotDeleteHook = { _ in
            enteredCont.yield(())
            var it = release.makeAsyncIterator()
            _ = await it.next()
        }
        let removal = Task { await store.removeMiAccount(id: Self.accB.id) }
        var enteredIt = entered.makeAsyncIterator()
        _ = await enteredIt.next()

        let slotsDuringDrain = try #require(mem.storedItems)
        let rescanned = MiSession(userId: "20002", cUserId: "c2", ssecurity: "sec-b-rescan", serviceToken: "tok-b-rescan", region: "sg", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        #expect(!store.completeMiLogin(rescanned))
        #expect(store.toastNotice?.isError == true)
        #expect(mem.storedItems == slotsDuringDrain)
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).map(\.session) == [Self.sessionA, Self.sessionB])

        releaseCont.yield(())
        releaseCont.finish()
        enteredCont.finish()
        #expect(await removal.value == .completed)
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).map(\.id) == [Self.accA.id])
        #expect(vault.lookup("assistant_api_key_openai") == .value(Data("sk-openai".utf8)))
    }

    @Test("Uncertain identity blocks all connection removals with zero deletions; pause confirmation gates active timers")
    @MainActor
    func identityUncertainBlocksDeletesAndPauseGateWorks() async throws {
        // 1. Uncertain identity (locked vault at launch) blocks every removal/disconnect/logout path.
        do {
            let (suite, defaults) = try Self.makeSuite("uncertain")
            defer { defaults.removePersistentDomain(forName: suite) }
            let mem = MemoryVaultStorage()
            let seedVault = CredentialVault(storage: mem.storage)
            try Self.seedAllSlots(vault: seedVault, defaults: defaults)
            mem.readResult = .unavailable
            let lockedStore = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage), miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
            #expect(lockedStore.isIdentityUncertain)
            #expect(await lockedStore.removeHomeAssistantConnection() == .blockedByUncertainIdentity)
            #expect(await lockedStore.removeMiAccount(id: Self.accA.id) == .blockedByUncertainIdentity)
            #expect(!lockedStore.disconnectHomeAssistant())
            #expect(!lockedStore.logoutMiAccount())
            #expect(!lockedStore.signOutAndRevokeAll())
            mem.readResult = nil
            #expect(CredentialVault(storage: mem.storage).lookup("ha_access_token") == .value(Data("ha-secret-tok".utf8)))
            #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: CredentialVault(storage: mem.storage)).count == 2)
        }

        // 2. Active scheduled command referencing HA requires pause confirmation before writing any removal record.
        do {
            let (suite, defaults) = try Self.makeSuite("pause-gate")
            defer { defaults.removePersistentDomain(forName: suite) }
            let mem = MemoryVaultStorage()
            let vault = CredentialVault(storage: mem.storage)
            try Self.seedAllSlots(vault: vault, defaults: defaults)
            defaults.set(Self.haURL, forKey: "ha_server_url")
            defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
            let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: Self.stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
            store.toastAutoDismissInterval = nil
            store.assistantNow = { Self.fixedNow }
            let haLight = SmartDevice(id: "light.desk", name: "书桌灯", roomId: "r1", roomName: "书房", model: "ha.light", isOnline: true, kind: .light(LightSpec(entityId: "light.desk", isOn: true)))
            store.deviceBackends = ["light.desk": .homeAssistant]
            store.devices = [haLight]
            let cmd = ScheduledCommand(
                id: UUID(), reply: "关书桌灯",
                fireDate: Self.fixedNow.addingTimeInterval(300),
                plan: IntentPlan(intents: [DeviceIntent(targetId: "light.desk", operation: .power(false))], reply: "ok", source: .local),
                sourceScopes: [store.homeAssistantScopeIdentifier]
            )
            store.scheduledCommands = [cmd]
            let previewOutcome = await store.removeHomeAssistantConnection(pauseConfirmed: false)
            if case .requiresPauseConfirmation(let verdict) = previewOutcome {
                #expect(!verdict.itemsToPause.isEmpty)
                #expect(ConnectionRemovalStore.readState(defaults: defaults).records.isEmpty)
                let confirmed = await store.removeHomeAssistantConnection(
                    pauseConfirmed: true, expectedGeneration: store.capabilityGeneration,
                    expectedPauseItemKeys: Set(verdict.itemsToPause.map(\.pauseKey))
                )
                #expect(confirmed == .completed)
                #expect(vault.lookup("ha_access_token") == .missing)
            } else {
                Issue.record("expected .requiresPauseConfirmation, got \(previewOutcome)")
            }
        }
    }
}
