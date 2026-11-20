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
    private static func makeStore(_ suite: String, _ mem: MemoryVaultStorage) -> HomeStore {
        let store = HomeStore(defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage), miAccountsProviderFactory: stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() })
        store.toastAutoDismissInterval = nil
        return store
    }

    @Test("Discarding a corrupt removal record restores accounts and leaves every credential slot byte-identical")
    @MainActor
    func discardRestoresAccountsWithoutTouchingSlots() async throws {
        let mem = MemoryVaultStorage()
        let (suite, defaults) = try Self.seededSuite("discard", vault: CredentialVault(storage: mem.storage))
        defer { defaults.removePersistentDomain(forName: suite) }
        let slotsBefore = try #require(mem.storedItems)
        #expect(slotsBefore.keys.contains(KeychainHelper.tokenAccount))
        #expect(slotsBefore.keys.contains(MiSessionStore.keychainAccount))

        let store = Self.makeStore(suite, mem)
        #expect(store.isIdentityUncertain)
        #expect(store.miAccounts.isEmpty)
        #expect(!store.hasHASource)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)

        #expect(store.discardCorruptConnectionRemovalRecord())
        try await awaitState { !store.isIdentityUncertain && store.miAccounts.count == 2 }
        #expect(!store.hasCorruptConnectionRemovalState)
        #expect(!store.canDiscardCorruptConnectionRemovalRecord)
        #expect(store.hasHASource)
        #expect(Set(store.miAccounts.map(\.id)) == [MiAccount(session: Self.sessionA).id, MiAccount(session: Self.sessionB).id])
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
        #expect(defaults.data(forKey: ConnectionRemovalStore.unreadableKeyPrefix) == Self.corrupt)
        #expect(mem.storedItems == slotsBefore)

        let relaunched = Self.makeStore(suite, mem)
        #expect(!relaunched.isIdentityUncertain)
        #expect(relaunched.miAccounts.count == 2)
        #expect(mem.storedItems == slotsBefore)
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
            let store = Self.makeStore(suite, mem)
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
            let store = Self.makeStore(suite, mem)
            #expect(store.hasCorruptConnectionRemovalState)
            #expect(store.identityMigrationDiagnostic == "corrupt_capability_selection")
            #expect(!store.canDiscardCorruptConnectionRemovalRecord)
            #expect(!store.discardCorruptConnectionRemovalRecord())
            #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        }
    }
}
