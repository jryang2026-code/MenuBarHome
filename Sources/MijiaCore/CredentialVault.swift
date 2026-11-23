import Foundation
import Security

enum SystemKeychainAccess {
    private static let lock = NSLock()
    private static let accessLock = NSLock()
    nonisolated(unsafe) private static var guardAccess: @Sendable () -> Void = {}

    static func installGuard(_ guardAccess: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.guardAccess = guardAccess
    }

    static func check() {
        lock.lock()
        let check = guardAccess
        lock.unlock()
        check()
    }

    static func perform<T>(_ body: () -> T) -> T {
        check()
        return accessLock.withLock(body)
    }

    static func readWithoutInteraction<T>(onFailure: T, _ body: () -> T) -> T {
        perform {
            #if os(macOS)
            // SecItem authentication contexts do not suppress ACL prompts for the file-based
            // login Keychain. Serialize our Security calls while its process-wide flag is off.
            var allowed = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else { return onFailure }
            if !allowed.boolValue { return body() }
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return onFailure }
            defer { SecKeychainSetUserInteractionAllowed(true) }
            #endif
            return body()
        }
    }
}

/// Every credential lives in **one** Keychain item, read once per process (#16).
///
/// Releases are signed with a free self-signed certificate. macOS stamps each Keychain item with the creating
/// build's `cdhash:` partition ID, so after every upgrade it asks again — for every item, on every read, because
/// `kSecUseAuthenticationUISkip` does not suppress that prompt on the file-based login keychain. Keeping all
/// credentials in a single item that is read once turns "a prompt per read of every credential" into one prompt per
/// upgrade; answering it with "Always Allow" also covers the writes that follow.
///
/// Failure rules: a vault that cannot be read reads as "not signed in" and is never overwritten (that would wipe the
/// other credentials); a failed write leaves the previous value in place.
public final class CredentialVault: @unchecked Sendable {
    public enum Lookup: Equatable, Sendable {
        case value(Data)
        case missing
        case unavailable
    }

    /// Decision for a targeted read-merge-write mutation of a single vault slot (P2c-M).
    public enum SlotMutation: Equatable, Sendable {
        case keep
        case replace(Data?)
        case abort(String)
    }

    public enum SlotMutationOutcome: Equatable, Sendable {
        case updated
        case unchanged
        case unavailable
        case writeFailed
        case aborted(String)
    }

    /// The single Keychain item that holds the encoded vault.
    public struct Storage: Sendable {
        public enum ReadResult: Equatable, Sendable {
            case found(Data)
            case notFound
            case unavailable
        }

        var read: @Sendable () -> ReadResult
        /// Replaces the item's data in place (keeping its access control), adding the item only when it is missing.
        var write: @Sendable (Data) -> Bool
        var readForRecovery: (@Sendable () -> ReadResult)? = nil
    }

    /// Per-account items written by releases up to 1.1.0. Adopted once, when no vault exists yet.
    struct LegacyItems: Sendable {
        var accounts: @Sendable () -> [String]?
        var read: @Sendable (String) -> Data?
        var delete: @Sendable (String) -> Void
        var readForRecovery: (@Sendable (String) -> Data?)? = nil

        static let none = LegacyItems(accounts: { [] }, read: { _ in nil }, delete: { _ in })
    }

    static let vaultAccount = "credential_vault_v1"

    public static let shared = CredentialVault(
        storage: .keychainItem(account: vaultAccount),
        legacy: .keychainItems(excluding: vaultAccount)
    )

    private enum State {
        case unloaded
        case loaded([String: Data])
        /// Per-account items serve this session from memory until a write can adopt them.
        /// Accounts that could not be read report `.unavailable`.
        case partialLegacy(items: [String: Data], unreadable: Set<String>, allLegacyAccounts: Set<String>)
        case unavailable
    }

    private let storage: Storage
    private let legacy: LegacyItems
    private let lock = NSLock()
    private var state = State.unloaded

    init(storage: Storage, legacy: LegacyItems = .none) {
        self.storage = storage
        self.legacy = legacy
    }

    /// Reads go to memory after the first successful load. An unreadable vault is not retried on reads, so a
    /// declined prompt is not followed by another one on the next read.
    public func lookup(_ account: String, retryingUnavailable: Bool = false) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded(retryingUnavailable: retryingUnavailable)
        switch state {
        case .loaded(let items):
            return items[account].map(Lookup.value) ?? .missing
        case .partialLegacy(let items, let unreadable, _):
            if unreadable.contains(account) { return .unavailable }
            return items[account].map(Lookup.value) ?? .missing
        case .unloaded, .unavailable:
            return .unavailable
        }
    }

    func data(for account: String) -> Data? {
        if case .value(let data) = lookup(account) { return data }
        return nil
    }

    /// Refreshes the in-memory view of the Keychain without migrating legacy items.
    func reloadForIdentityRecovery() -> Bool {
        lock.withLock {
            switch (storage.readForRecovery ?? storage.read)() {
            case .found(let blob):
                if let items = Self.decode(blob) {
                    state = .loaded(items)
                    return true
                }
            case .notFound:
                if reloadLegacyItemsForRecovery() { return true }
            case .unavailable:
                break
            }
            if case .partialLegacy = state { return false }
            state = .unavailable
            return false
        }
    }

    private func reloadLegacyItemsForRecovery() -> Bool {
        guard let accounts = legacy.accounts() else { return false }
        let read = legacy.readForRecovery ?? legacy.read
        var items: [String: Data] = [:]
        for account in accounts {
            guard let data = read(account) else { return false }
            items[account] = data
        }
        state = accounts.isEmpty
            ? .loaded([:])
            : .partialLegacy(items: items, unreadable: [], allLegacyAccounts: Set(accounts))
        return true
    }

    /// `nil` removes the account. Writes retry an unreadable vault once: they follow a user action, and the vault
    /// has to be readable before any of it is rewritten.
    @discardableResult
    func set(_ data: Data?, for account: String) -> Bool {
        setAll([account: data])
    }

    /// Atomically applies multiple account updates in a single vault persistence write.
    /// If the write fails, none of the accounts change in memory or on disk.
    @discardableResult
    func setAll(_ updates: [String: Data?]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let writable = itemsForWriteUnlocked(retryingUnavailable: true) else { return false }
        var items = writable.items
        var changed = false
        for (account, data) in updates {
            if items[account] != data {
                items[account] = data
                changed = true
            }
        }
        if !changed && writable.legacyAccounts.isEmpty { return true }
        guard persist(items) else { return false }
        for legacyAccount in writable.legacyAccounts {
            legacy.delete(legacyAccount)
        }
        return true
    }

    /// Adds the value only when the account is empty; an existing credential always wins over a migrated one.
    func insertIfMissing(_ data: Data, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let writable = itemsForWriteUnlocked(retryingUnavailable: false) else { return false }
        var items = writable.items
        guard items[account] == nil else { return true }
        items[account] = data
        guard persist(items) else { return false }
        for legacyAccount in writable.legacyAccounts { legacy.delete(legacyAccount) }
        return true
    }

    /// Refreshes the single-item vault from storage and atomically transforms only `account`,
    /// preserving every other slot intact. Fails closed when the vault is unreadable or corrupt.
    @discardableResult
    public func mutateSlot(_ account: String, _ transform: (Data?) -> SlotMutation) -> SlotMutationOutcome {
        lock.lock()
        defer { lock.unlock() }
        var pendingLegacyDelete: Set<String> = []
        guard var items = loadLatestItemsForWriteUnlocked(completedLegacyAccounts: &pendingLegacyDelete) else {
            return .unavailable
        }
        switch transform(items[account]) {
        case .keep:
            if pendingLegacyDelete.isEmpty { state = .loaded(items) }
            return .unchanged
        case .abort(let reason):
            return .aborted(reason)
        case .replace(let nextData):
            if items[account] == nextData && pendingLegacyDelete.isEmpty {
                state = .loaded(items)
                return .unchanged
            }
            items[account] = nextData
            guard persist(items) else { return .writeFailed }
            for legacyAccount in pendingLegacyDelete { legacy.delete(legacyAccount) }
            return .updated
        }
    }

    private func loadLatestItemsForWriteUnlocked(completedLegacyAccounts: inout Set<String>) -> [String: Data]? {
        let wasLoaded: Bool = if case .loaded = state { true } else { false }
        guard let writable = itemsForWriteUnlocked(retryingUnavailable: true) else { return nil }
        completedLegacyAccounts = writable.legacyAccounts
        guard wasLoaded, completedLegacyAccounts.isEmpty else { return writable.items }
        switch storage.read() {
        case .found(let blob):
            guard let fresh = Self.decode(blob) else { state = .unavailable; return nil }
            return fresh
        case .notFound:
            return [:]
        case .unavailable:
            state = .unavailable
            return nil
        }
    }

    private func itemsForWriteUnlocked(
        retryingUnavailable: Bool
    ) -> (items: [String: Data], legacyAccounts: Set<String>)? {
        loadIfNeeded(retryingUnavailable: retryingUnavailable)
        switch state {
        case .loaded(let items):
            return (items, [])
        case .partialLegacy(let items, let unreadable, let accounts) where unreadable.isEmpty:
            return (items, accounts)
        default:
            return nil
        }
    }

    /// True once this process has read the vault (or found there is nothing to read).
    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .loaded = state { return true }
        return false
    }

    // MARK: - Loading

    private func loadIfNeeded(retryingUnavailable: Bool) {
        switch state {
        case .loaded:
            return
        case .partialLegacy(var items, var unreadable, let allLegacy):
            guard retryingUnavailable else { return }
            for account in unreadable.sorted() {
                if let data = legacy.read(account) {
                    items[account] = data
                    unreadable.remove(account)
                }
            }
            state = .partialLegacy(items: items, unreadable: unreadable, allLegacyAccounts: allLegacy)
            return
        case .unavailable where !retryingUnavailable:
            return
        case .unavailable, .unloaded:
            break
        }
        switch storage.read() {
        case .found(let blob):
            // An undecodable vault is never rewritten: that would drop every credential in it.
            guard let items = Self.decode(blob) else {
                state = .unavailable
                return
            }
            state = .loaded(items)
        case .notFound:
            adoptLegacyItems()
        case .unavailable:
            state = .unavailable
        }
    }

    /// Moves the 1.1.0 per-account items into a new vault. The old items are deleted only after the vault was
    /// written. When any of them cannot be read (a declined prompt), nothing is written or deleted here, so the next
    /// launch retries the whole move; the readable ones still serve this session, while the unreadable ones report
    /// `.unavailable` and block partial vault writes until they can be read.
    private func adoptLegacyItems() {
        var items: [String: Data] = [:]
        var unreadable: Set<String> = []
        let accounts = legacy.accounts() ?? []
        for account in accounts {
            if let data = legacy.read(account) {
                items[account] = data
            } else {
                unreadable.insert(account)
            }
        }
        guard unreadable.isEmpty else {
            state = .partialLegacy(items: items, unreadable: unreadable, allLegacyAccounts: Set(accounts))
            return
        }
        state = .loaded(items)
        guard !items.isEmpty, persist(items) else { return }
        for account in items.keys {
            legacy.delete(account)
        }
    }

    private func persist(_ items: [String: Data]) -> Bool {
        guard let blob = Self.encode(items), storage.write(blob) else { return false }
        state = .loaded(items)
        return true
    }

    // MARK: - Encoding

    private struct File: Codable {
        var version: Int
        var items: [String: Data]
    }

    static func encode(_ items: [String: Data]) -> Data? {
        try? JSONEncoder().encode(File(version: 1, items: items))
    }

    static func decode(_ blob: Data) -> [String: Data]? {
        guard let file = try? JSONDecoder().decode(File.self, from: blob), file.version == 1 else { return nil }
        return file.items
    }
}

// MARK: - Keychain Backing

private func keychainQuery(service: String, account: String?) -> [String: Any] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service
    ]
    if let account {
        query[kSecAttrAccount as String] = account
    }
    return query
}

extension CredentialVault.Storage {
    static func keychainItem(
        service: String = KeychainHelper.service,
        account: String,
        updateItem: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus = { query, changes in
            SystemKeychainAccess.perform { SecItemUpdate(query, changes) }
        },
        addItem: @escaping @Sendable (CFDictionary) -> OSStatus = { query in
            SystemKeychainAccess.perform { SecItemAdd(query, nil) }
        }
    ) -> Self {
        @Sendable func read(forRecovery: Bool) -> ReadResult {
            var query = keychainQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if !forRecovery {
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
            }
            var item: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &item) {
            case errSecSuccess:
                guard let data = item as? Data else { return .unavailable }
                return .found(data)
            case errSecItemNotFound:
                return .notFound
            default:
                return .unavailable
            }
        }
        return Self(
            read: { SystemKeychainAccess.perform { read(forRecovery: false) } },
            write: { data in
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                ]
                // Update in place: delete-then-add would lose the credentials when the add is refused.
                let query = keychainQuery(service: service, account: account)
                let status = updateItem(query as CFDictionary, attributes as CFDictionary)
                if status == errSecSuccess { return true }
                guard status == errSecItemNotFound else { return false }
                let addQuery = query.merging(attributes) { _, new in new }
                return addItem(addQuery as CFDictionary) == errSecSuccess
            },
            readForRecovery: { SystemKeychainAccess.readWithoutInteraction(onFailure: .unavailable) { read(forRecovery: true) } }
        )
    }
}

extension CredentialVault.LegacyItems {
    static func keychainItems(service: String = KeychainHelper.service, excluding vaultAccount: String) -> Self {
        #if os(macOS)
        @Sendable func read(account: String) -> Data? {
            var query = keychainQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        }
        return Self(
            accounts: {
                // Attributes only: listing items never needs their secret, so it never prompts.
                var query = keychainQuery(service: service, account: nil)
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitAll
                var result: CFTypeRef?
                let status = SystemKeychainAccess.perform { SecItemCopyMatching(query as CFDictionary, &result) }
                if status == errSecItemNotFound { return [] }
                guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return nil }
                return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount }
            },
            read: { account in SystemKeychainAccess.perform { read(account: account) } },
            delete: { account in
                let query = keychainQuery(service: service, account: account)
                _ = SystemKeychainAccess.perform { SecItemDelete(query as CFDictionary) }
            },
            readForRecovery: { account in SystemKeychainAccess.readWithoutInteraction(onFailure: nil) { read(account: account) } }
        )
        #else
        return .none
        #endif
    }
}

extension CredentialVault {
    /// Whether the app has stored any credential on this Mac, judged from item attributes only (never prompts).
    public static func hasStoredCredentials(service: String = KeychainHelper.service) -> Bool {
        itemExists(service: service, account: nil)
    }

    /// Whether the single-item vault exists yet (as opposed to only the 1.1.0 per-account items).
    public static func hasVaultItem(service: String = KeychainHelper.service) -> Bool {
        itemExists(service: service, account: vaultAccount)
    }

    private static func itemExists(service: String, account: String?) -> Bool {
        #if os(macOS)
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SystemKeychainAccess.perform { SecItemCopyMatching(query as CFDictionary, &result) } == errSecSuccess
        #else
        return false
        #endif
    }
}
