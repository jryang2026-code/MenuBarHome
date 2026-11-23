import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) { _value = value }

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func increment() { lock.withLock { _count += 1 } }
    var count: Int { lock.withLock { _count } }
}

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
    private static func seededDefaults(vault: CredentialVault) -> UserDefaults {
        let defaults = InMemoryUserDefaults()
        #expect(KeychainHelper.saveToken("ha-secret-tok", defaults: defaults, vault: vault))
        #expect(MiSessionStore.saveAccounts([MiAccount(session: sessionA), MiAccount(session: sessionB)], defaults: defaults, vault: vault))
        #expect(vault.set(Data("sk-openai".utf8), for: "assistant_api_key_openai"))
        #expect(vault.set(Data("sk-openrouter".utf8), for: "assistant_api_key_openrouter"))
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        defaults.set(corrupt, forKey: ConnectionRemovalStore.storageKey)
        return defaults
    }

    @MainActor
    private static func makeStore(_ defaults: UserDefaults, _ vault: CredentialVault) -> HomeStore {
        let store = HomeStore(credentialVault: vault, miAccountsProviderFactory: stubMiFactory, haProviderFactory: { _, _ in MockHomeProvider() }, defaults: defaults)
        store.toastAutoDismissInterval = nil
        return store
    }

    @Test("Discarding a corrupt removal record restores accounts and leaves every credential slot byte-identical")
    @MainActor
    func discardRestoresAccountsWithoutTouchingSlots() async throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = Self.seededDefaults(vault: vault)
        let quarantine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: quarantine) }
        let slotsBefore = try #require(mem.storedItems)
        #expect(slotsBefore.keys.contains(KeychainHelper.tokenAccount))
        #expect(slotsBefore.keys.contains(MiSessionStore.keychainAccount))

        let store = Self.makeStore(defaults, vault)
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

        let relaunched = Self.makeStore(defaults, CredentialVault(storage: mem.storage))
        #expect(!relaunched.isIdentityUncertain)
        #expect(relaunched.miAccounts.count == 2)
        #expect(mem.storedItems == slotsBefore)
    }

    @Test("Discard restores noncanonical Mi accounts without writing their slot", arguments: [false, true], [false, true])
    @MainActor
    func discardReadsNoncanonicalMiAccounts(duplicateEnvelope: Bool, reuseProvider: Bool) throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = Self.seededDefaults(vault: vault)
        let quarantine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: quarantine) }
        if reuseProvider {
            defaults.removeObject(forKey: ConnectionRemovalStore.storageKey)
        }
        let store = Self.makeStore(defaults, vault)
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

        let relaunched = Self.makeStore(defaults, CredentialVault(storage: mem.storage))
        #expect(relaunched.miAccounts.map(\.id) == [MiAccount(session: Self.sessionA).id])
        #expect(mem.storedItems?[MiSessionStore.keychainAccount] != noncanonical)
        #expect(mem.writes == writesBeforeDiscard + 1)
    }

    @Test("Discard keeps the original on quarantine failure and can reuse a verified copy on retry")
    @MainActor
    func discardRequiresPersistedQuarantine() throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = Self.seededDefaults(vault: vault)
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let quarantine = root.appendingPathComponent("quarantine")
        let store = Self.makeStore(defaults, vault)

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
        let relaunched = Self.makeStore(defaults, vault)
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
            let defaults = Self.seededDefaults(vault: CredentialVault(storage: mem.storage))
            let slotsBefore = mem.rawBlob
            mem.readResult = .unavailable
            let store = Self.makeStore(defaults, CredentialVault(storage: mem.storage))
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
            let defaults = Self.seededDefaults(vault: CredentialVault(storage: mem.storage))
            defaults.set(Data("{broken-capability".utf8), forKey: CapabilitySelectionStore.storageKey)
            let store = Self.makeStore(defaults, CredentialVault(storage: mem.storage))
            #expect(store.hasCorruptConnectionRemovalState)
            #expect(store.identityMigrationDiagnostic == "corrupt_capability_selection")
            #expect(!store.canDiscardCorruptConnectionRemovalRecord)
            #expect(!store.discardCorruptConnectionRemovalRecord())
            #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        }
    }

    @Test("Unsupported F_FULLFSYNC keeps the original record, distinguishes the failure, and recovers via an alternate private folder", arguments: [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL, ENOSYS])
    @MainActor
    func fullFsyncUnsupportedDistinguishesAndRecoversViaAlternateFolder(errorCode: Int32) async throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = Self.seededDefaults(vault: vault)
        let slotsBefore = try #require(mem.storedItems)
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("corrupt-fullfsync-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }

        let primaryDir = root.appendingPathComponent("primary-quarantine", isDirectory: true)
        let unsupportedAltParent = root.appendingPathComponent("alt-unsupported", isDirectory: true)
        let goodAltParent = root.appendingPathComponent("alt-good", isDirectory: true)
        try files.createDirectory(at: unsupportedAltParent, withIntermediateDirectories: false)
        try files.createDirectory(at: goodAltParent, withIntermediateDirectories: false)

        let unsupportedAltDir = ConnectionRemovalStore.quarantineSubdirectory(inParentDirectory: unsupportedAltParent)
        let goodAltDir = ConnectionRemovalStore.quarantineSubdirectory(inParentDirectory: goodAltParent)
        let fullFsyncCallsOnGoodAlt = LockedCounter()

        let store = Self.makeStore(defaults, vault)
        store.corruptRemovalQuarantineHooks = ConnectionRemovalStore.QuarantinePersistenceHooks(
            defaultDirectory: { primaryDir },
            syncFD: { fd, _ in fsync(fd) == 0 ? 0 : errno },
            fullFsync: { fd, destination in
                if destination.standardizedFileURL == primaryDir.standardizedFileURL
                    || destination.standardizedFileURL == unsupportedAltDir.standardizedFileURL {
                    return errorCode
                }
                if destination.standardizedFileURL == goodAltDir.standardizedFileURL {
                    fullFsyncCallsOnGoodAlt.increment()
                }
                #if canImport(Darwin)
                return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : errno
                #else
                return 0
                #endif
            },
            readBack: { handle, _ in try? (handle.readToEnd() ?? Data()) }
        )

        // 1. Default location fails with F_FULLFSYNC unsupported -> keeps original record and classifies failure.
        #expect(!store.discardCorruptConnectionRemovalRecord())
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.hasCorruptConnectionRemovalState)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        #expect(store.corruptRemovalDiscardFailure == ConnectionRemovalQuarantineFailure(
            kind: .fullFsyncUnsupported,
            directoryPath: primaryDir.path,
            errorCode: errorCode,
            usedAlternateDirectory: false
        ))
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("F_FULLFSYNC") == true)
        #expect(mem.storedItems == slotsBefore)

        // 2. Alternate folder on a volume that also rejects F_FULLFSYNC still keeps original record & retryable state.
        #expect(!store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: unsupportedAltParent))
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.hasCorruptConnectionRemovalState)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        #expect(store.corruptRemovalDiscardFailure == ConnectionRemovalQuarantineFailure(
            kind: .fullFsyncUnsupported,
            directoryPath: unsupportedAltDir.path,
            errorCode: errorCode,
            usedAlternateDirectory: true
        ))
        #expect(mem.storedItems == slotsBefore)

        // 3. Alternate folder with valid local APFS F_FULLFSYNC succeeds, verifies 0700/0600 permissions, and restores accounts.
        #expect(store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: goodAltParent))
        try await awaitState { !store.isIdentityUncertain && store.miAccounts.count == 2 }
        #expect(fullFsyncCallsOnGoodAlt.count == 1)
        #expect(store.corruptRemovalDiscardFailure == nil)
        #expect(!store.hasCorruptConnectionRemovalState)
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
        #expect(mem.storedItems == slotsBefore)

        let entries = try files.contentsOfDirectory(atPath: goodAltDir.path)
        try #require(entries.count == 1)
        let copy = goodAltDir.appendingPathComponent(entries[0])
        #expect(try files.attributesOfItem(atPath: goodAltDir.path)[.posixPermissions] as? Int == 0o700)
        #expect(try files.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        #expect(try Data(contentsOf: copy) == Self.corrupt)
    }

    @Test("Alternate quarantine location enforces private permissions, read-back verification, and keeps retry on transient sync failures")
    @MainActor
    func alternateQuarantineValidationAndTransientRetry() async throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = Self.seededDefaults(vault: vault)
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("corrupt-transient-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }

        let primaryDir = root.appendingPathComponent("primary", isDirectory: true)
        let symlinkParent = root.appendingPathComponent("symlink-parent", isDirectory: true)
        let realTarget = root.appendingPathComponent("real-target", isDirectory: true)
        try files.createDirectory(at: realTarget, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: symlinkParent, withDestinationURL: realTarget)

        let openPermParent = root.appendingPathComponent("open-perm-parent", isDirectory: true)
        try files.createDirectory(at: openPermParent, withIntermediateDirectories: false)
        let preExistingSubdir = ConnectionRemovalStore.quarantineSubdirectory(inParentDirectory: openPermParent)
        try files.createDirectory(at: preExistingSubdir, withIntermediateDirectories: false)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preExistingSubdir.path)

        let transientParent = root.appendingPathComponent("transient-parent", isDirectory: true)
        try files.createDirectory(at: transientParent, withIntermediateDirectories: false)

        let failSync = LockedFlag(false)
        let corruptReadBack = LockedFlag(false)
        let store = Self.makeStore(defaults, vault)
        store.corruptRemovalQuarantineHooks = ConnectionRemovalStore.QuarantinePersistenceHooks(
            defaultDirectory: { primaryDir },
            syncFD: { fd, url in
                if failSync.value && url.path.contains("transient-parent") { return EIO }
                return fsync(fd) == 0 ? 0 : errno
            },
            fullFsync: { fd, _ in
                #if canImport(Darwin)
                return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : errno
                #else
                return 0
                #endif
            },
            readBack: { handle, _ in
                if corruptReadBack.value { return Data("mismatched".utf8) }
                return try? (handle.readToEnd() ?? Data())
            }
        )

        // Symlinked alternate parent is rejected before touching storageKey.
        #expect(!store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: symlinkParent))
        #expect(store.corruptRemovalDiscardFailure?.kind == .transientOrVerificationFailed)
        #expect(store.corruptRemovalDiscardFailure?.usedAlternateDirectory == true)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)

        // Pre-existing 0755 quarantine subdirectory is rejected.
        #expect(!store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: openPermParent))
        #expect(store.corruptRemovalDiscardFailure?.kind == .transientOrVerificationFailed)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)

        // Transient fsync EIO keeps original record and retry entry.
        failSync.value = true
        #expect(!store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: transientParent))
        #expect(store.corruptRemovalDiscardFailure?.kind == .transientOrVerificationFailed)
        #expect(store.corruptRemovalDiscardFailure?.errorCode == EIO)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        failSync.value = false

        // Byte-for-byte read-back mismatch keeps original record and retry entry.
        corruptReadBack.value = true
        #expect(!store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: transientParent))
        #expect(store.corruptRemovalDiscardFailure?.kind == .transientOrVerificationFailed)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == Self.corrupt)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        corruptReadBack.value = false

        // Switching to demo clears the transient UI failure; switching back allows retry to succeed.
        store.switchBackend(.demo)
        #expect(store.corruptRemovalDiscardFailure == nil)
        store.switchBackend(.homeAssistant)
        #expect(store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: transientParent))
        try await awaitState { !store.isIdentityUncertain && store.miAccounts.count == 2 }
        #expect(store.corruptRemovalDiscardFailure == nil)
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
    }
}
