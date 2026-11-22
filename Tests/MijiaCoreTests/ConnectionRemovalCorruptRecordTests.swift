import Foundation
import KeychainTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct ConnectionRemovalCorruptRecordTests {
    private static let sessionA = MiSession(userId: "10001", cUserId: "c1", ssecurity: "sec-a", serviceToken: "tok-a", region: "cn", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    private static let sessionB = MiSession(userId: "20002", cUserId: "c2", ssecurity: "sec-b", serviceToken: "tok-b", region: "sg", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    private static let haURL = "http://ha.removal.example:8123"
    private static let corrupt = Data("{broken-removal-json".utf8)
    private static let stubMiFactory: @MainActor ([MiAccount]) -> MiAccountsProvider = { accounts in
        MiAccountsProvider(accounts: accounts, localClientFactory: { nil }, pollInterval: .seconds(3600), followUpDelay: .seconds(3600))
    }

    @MainActor
    private static func seededSuite(_ name: String, vault: CredentialVault) throws -> (String, UserDefaults) {
        let suite = "test.p2cm.corrupt.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(KeychainHelper.saveToken("ha-secret-tok", defaults: defaults, vault: vault))
        #expect(MiSessionStore.saveAccounts([MiAccount(session: sessionA), MiAccount(session: sessionB)], defaults: defaults, vault: vault))
        #expect(vault.set(Data("sk-openai".utf8), for: "assistant_api_key_openai"))
        #expect(vault.set(Data("sk-openrouter".utf8), for: "assistant_api_key_openrouter"))
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        defaults.set(corrupt, forKey: ConnectionRemovalStore.storageKey)
        return (suite, defaults)
    }

    @MainActor
    private static func makeStore(_ suite: String, _ vault: CredentialVault) -> HomeStore {
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: vault, miAccountsProviderFactory: stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        return store
    }

    @Test("Discarding a corrupt removal record restores accounts and leaves every credential slot byte-identical")
    @MainActor
    func discardRestoresAccountsWithoutTouchingSlots() async throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let (suite, defaults) = try Self.seededSuite("discard", vault: vault)
        defer { defaults.removePersistentDomain(forName: suite) }
        let quarantine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: quarantine) }
        let slotsBefore = try #require(mem.storedItems)
        #expect(slotsBefore.keys.contains(KeychainHelper.tokenAccount))
        #expect(slotsBefore.keys.contains(MiSessionStore.keychainAccount))

        let store = Self.makeStore(suite, vault)
        #expect(store.isIdentityUncertain)
        #expect(store.miAccounts.isEmpty)
        #expect(!store.hasHASource)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)

        #expect(store.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        try await awaitState { !store.isIdentityUncertain && store.miAccounts.count == 2 }
        #expect(!store.hasCorruptConnectionRemovalState)
        #expect(!store.canDiscardCorruptConnectionRemovalRecord)
        #expect(store.hasHASource)
        #expect(Set(store.miAccounts.map(\.id)) == [MiAccount(session: Self.sessionA).id, MiAccount(session: Self.sessionB).id])
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
        #expect(defaults.data(forKey: ConnectionRemovalStore.unreadableKeyPrefix) == Self.corrupt)
        #expect(mem.storedItems == slotsBefore)

        let relaunched = Self.makeStore(suite, CredentialVault(storage: mem.storage))
        #expect(!relaunched.isIdentityUncertain)
        #expect(relaunched.miAccounts.count == 2)
        #expect(mem.storedItems == slotsBefore)
    }

    @Test("Discard restores noncanonical Mi accounts without writing their slot", arguments: [false, true], [false, true])
    @MainActor
    func discardReadsNoncanonicalMiAccounts(duplicateEnvelope: Bool, reuseProvider: Bool) throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let (suite, defaults) = try Self.seededSuite("noncanonical", vault: vault)
        defer { defaults.removePersistentDomain(forName: suite) }
        let quarantine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: quarantine) }
        if reuseProvider {
            defaults.removeObject(forKey: ConnectionRemovalStore.storageKey)
        }
        let store = Self.makeStore(suite, vault)
        #expect((store.activeDualProvider != nil) == reuseProvider)
        if reuseProvider {
            defaults.set(Self.corrupt, forKey: ConnectionRemovalStore.storageKey)
            #expect(!store.retryIdentityMigration())
        }

        let legacy = try JSONEncoder().encode(Self.sessionA)
        let noncanonical: Data
        if duplicateEnvelope {
            let session = try JSONSerialization.jsonObject(with: legacy)
            noncanonical = try JSONSerialization.data(withJSONObject: ["version": 2, "accounts": [session, session]])
        } else {
            noncanonical = legacy
        }
        try #require(vault.set(noncanonical, for: MiSessionStore.keychainAccount))

        let writesBeforeDiscard = mem.writes

        try #require(store.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        #expect(store.miAccounts.map(\.id) == [MiAccount(session: Self.sessionA).id])
        #expect(store.activeMiAccountsProvider != nil)
        #expect(mem.storedItems?[MiSessionStore.keychainAccount] == noncanonical)
        #expect(mem.writes == writesBeforeDiscard)

        let relaunched = Self.makeStore(suite, CredentialVault(storage: mem.storage))
        #expect(relaunched.miAccounts.map(\.id) == [MiAccount(session: Self.sessionA).id])
        #expect(mem.storedItems?[MiSessionStore.keychainAccount] != noncanonical)
        #expect(mem.writes == writesBeforeDiscard + 1)
    }

    @Test("Discard keeps the original on quarantine failure and can reuse a verified copy on retry")
    @MainActor
    func discardRequiresPersistedQuarantine() throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let (suite, defaults) = try Self.seededSuite("quarantine", vault: vault)
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let quarantine = root.appendingPathComponent("quarantine")
        let store = Self.makeStore(suite, vault)

        try files.createSymbolicLink(at: quarantine, withDestinationURL: root)
        #expect(!store.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        #expect(try files.contentsOfDirectory(atPath: root.path) == ["quarantine"])
        try files.removeItem(at: quarantine)

        try #require(store.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        let entries = try files.contentsOfDirectory(atPath: quarantine.path)
        try #require(entries.count == 1)
        let copy = quarantine.appendingPathComponent(entries[0])
        #expect(try Data(contentsOf: copy) == Self.corrupt)
        #expect(try files.attributesOfItem(atPath: quarantine.path)[.posixPermissions] as? Int == 0o700)
        #expect(try files.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)

        defaults.set(Self.corrupt, forKey: ConnectionRemovalStore.storageKey)
        let relaunched = Self.makeStore(suite, vault)
        let linkTarget = root.appendingPathComponent("target")
        try files.moveItem(at: copy, to: linkTarget)
        try files.createSymbolicLink(at: copy, withDestinationURL: linkTarget)
        #expect(!relaunched.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(try Data(contentsOf: linkTarget) == Self.corrupt)
        try files.removeItem(at: copy)
        try files.moveItem(at: linkTarget, to: copy)

        try Data(repeating: 0xAB, count: Self.corrupt.count).write(to: copy)
        #expect(!relaunched.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(relaunched.canDiscardCorruptConnectionRemovalRecord)

        try Self.corrupt.write(to: copy)
        try #require(relaunched.discardCorruptConnectionRemovalRecord(quarantineDirectory: quarantine))
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
        #expect(try files.contentsOfDirectory(atPath: quarantine.path) == entries)
    }

    @Test("The discard action stays unavailable when anything besides the corrupt record keeps identity uncertain")
    @MainActor
    func discardUnavailableForOtherIdentityFailures() throws {
        // Locked vault: the launch diagnostic still names the corrupt record first, so the check must re-read the vault.
        do {
            let mem = MemoryVaultStorage()
            let (suite, defaults) = try Self.seededSuite("locked", vault: CredentialVault(storage: mem.storage))
            defer { defaults.removePersistentDomain(forName: suite) }
            let slotsBefore = mem.rawBlob
            mem.readResult = .unavailable
            let store = Self.makeStore(suite, CredentialVault(storage: mem.storage))
            #expect(store.identityMigrationDiagnostic == "corrupt_connection_removal")
            #expect(!store.canDiscardCorruptConnectionRemovalRecord)
            #expect(!store.discardCorruptConnectionRemovalRecord())
            #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
            #expect(store.isIdentityUncertain)
            #expect(mem.rawBlob == slotsBefore)
        }

        // Corrupt capability selection takes precedence and is not something this action may clear.
        do {
            let mem = MemoryVaultStorage()
            let (suite, defaults) = try Self.seededSuite("capability", vault: CredentialVault(storage: mem.storage))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(Data("{broken-capability".utf8), forKey: CapabilitySelectionStore.storageKey)
            let store = Self.makeStore(suite, CredentialVault(storage: mem.storage))
            #expect(store.hasCorruptConnectionRemovalState)
            #expect(store.identityMigrationDiagnostic == "corrupt_capability_selection")
            #expect(!store.canDiscardCorruptConnectionRemovalRecord)
            #expect(!store.discardCorruptConnectionRemovalRecord())
            #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        }
    }
}
