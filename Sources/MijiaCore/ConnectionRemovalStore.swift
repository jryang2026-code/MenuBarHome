import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ConnectionRemovalKind: String, Codable, Equatable, Sendable { case mi, ha }
public enum ConnectionRemovalStage: String, Codable, Equatable, Sendable { case draining, cleaning, failed }

/// Persistent, retryable record for single-connection removal (P2c-M).
public struct ConnectionRemovalRecord: Equatable, Sendable, Identifiable {
    public var id: String { scope }
    public let scope: String
    public let kind: ConnectionRemovalKind
    public let ownerVersion: Int
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public let stage: ConnectionRemovalStage
    public let attempts: Int
    public let accountId: String?
    public let displayName: String?
    public let serverURL: String?
    public let slotNames: [String]
    /// Non-reversible SHA-256 fingerprint of the credential being removed (never raw secrets).
    public let credentialFingerprint: String?
    public let lastError: String?
    let extra: [String: JSONValue]
}

public struct ConnectionRemovalState: Equatable, Sendable {
    public let ownerVersion: Int
    public let records: [ConnectionRemovalRecord]
    public let readError: Bool
    public let corruptData: Data?
}

public struct ConnectionRemovalPreview: Equatable, Sendable {
    public let kind: ConnectionRemovalKind
    public let scope: String
    public let displayName: String
    public let credentialSlotsToClear: [String]
    public let serverURL: String?
    public let clearsServerURLBinding: Bool
    public let clearsPlaintextConsent: Bool
    public let clearsTopologyCache: Bool
    public let clearsSelectedHome: Bool
    public let clearsSharedItems: Bool
    public let remainingMiAccountCount: Int
    public let preservesHistory: Bool
    public let summaryText: String
    public let detailItems: [String]
    public let platformRevocationHint: String
}

public enum ConnectionRemovalOutcome: Equatable, Sendable {
    case completed
    case blockedByUncertainIdentity
    case blockedByDeactivation(CapabilityDeactivationVerdict)
    case requiresPauseConfirmation(CapabilityDeactivationVerdict)
    case incomplete(reason: String, remainingSlots: [String])
}

public enum ConnectionRemovalSlotExecution: Equatable, Sendable {
    case completed(reboundPreserved: Bool)
    case incomplete(reason: String, remainingSlots: [String])
}

public enum ConnectionRemovalQuarantineFailureKind: String, Equatable, Sendable {
    /// The target volume rejected `F_FULLFSYNC` as unsupported (`ENOTSUP`, `EOPNOTSUPP`, `ENOTTY`, `EINVAL`, `ENOSYS`).
    case fullFsyncUnsupported
    /// Transient I/O, directory creation, permission/ownership, symlink, or byte-for-byte read-back verification failure.
    case transientOrVerificationFailed
}

public struct ConnectionRemovalQuarantineFailure: Equatable, Sendable, Error {
    public let kind: ConnectionRemovalQuarantineFailureKind
    public let directoryPath: String?
    public let errorCode: Int32?
    public let usedAlternateDirectory: Bool

    public init(
        kind: ConnectionRemovalQuarantineFailureKind,
        directoryPath: String? = nil,
        errorCode: Int32? = nil,
        usedAlternateDirectory: Bool = false
    ) {
        self.kind = kind
        self.directoryPath = directoryPath
        self.errorCode = errorCode
        self.usedAlternateDirectory = usedAlternateDirectory
    }
}

public enum ConnectionRemovalDiscardResult: Equatable, Sendable {
    case discarded(quarantineFileURL: URL, usedAlternateDirectory: Bool)
    case notDiscardable
    case failed(ConnectionRemovalQuarantineFailure)

    public var succeeded: Bool {
        if case .discarded = self { return true }
        return false
    }
}

/// Strict, read-merge-write persistence and targeted slot execution for connection removal (P2c-M).
public enum ConnectionRemovalStore {
    public static let storageKey = "connection_removal_v1"
    public static let unreadableKeyPrefix = "connection_removal_v1.unreadable"
    public static let quarantineDirectoryName = "MenuBarMijia-ConnectionRemovalQuarantine"
    public static let schemaVersion = 1
    static let maxRemovals = 32
    private static let storeLock = NSLock()
    private static let topKnownKeys: Set<String> = ["schemaVersion", "ownerVersion", "removals"]
    private static let recordKnownKeys: Set<String> = [
        "scope", "kind", "ownerVersion", "createdAtMs", "updatedAtMs", "stage", "attempts",
        "accountId", "displayName", "serverURL", "slotNames", "credentialFingerprint", "lastError",
    ]
    private static let allowedSlotsByKind: [ConnectionRemovalKind: Set<String>] = [
        .ha: [KeychainHelper.tokenAccount], .mi: [MiSessionStore.keychainAccount],
    ]

    public static func miScope(accountId: String) -> String {
        let trimmed = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("mi:") ? trimmed : "mi:\(trimmed)"
    }

    public static func haScope(serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("ha:") ? trimmed : "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(trimmed))"
    }

    public static func allowedSlots(for kind: ConnectionRemovalKind) -> [String] {
        kind == .ha ? [KeychainHelper.tokenAccount] : [MiSessionStore.keychainAccount]
    }

    public static func fingerprint(haToken: String) -> String? {
        let trimmed = haToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : sha256Hex("ha:\(trimmed)")
    }

    public static func fingerprint(miSession: MiSession) -> String {
        sha256Hex("mi:\(MiAccount(session: miSession).id)|\(miSession.ssecurity)|\(miSession.serviceToken)")
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Read & Quarantine

    public static func readState(defaults: UserDefaults = .standard) -> ConnectionRemovalState {
        storeLock.withLock { readStateUnlocked(defaults: defaults).state }
    }

    public static func find(scope: String, defaults: UserDefaults = .standard) -> ConnectionRemovalRecord? {
        let state = readState(defaults: defaults)
        return state.readError ? nil : state.records.first { $0.scope == scope }
    }

    /// Fail-closed: corrupt payloads count as pending rather than "no removals".
    public static func isPending(scope: String, defaults: UserDefaults = .standard) -> Bool {
        let state = readState(defaults: defaults)
        return state.readError || state.records.contains { $0.scope == scope }
    }

    public static func hasPending(kind: ConnectionRemovalKind, defaults: UserDefaults = .standard) -> Bool {
        let state = readState(defaults: defaults)
        return state.readError || state.records.contains { $0.kind == kind }
    }

    @discardableResult
    public static func quarantineCorruptPayloadIfNeeded(defaults: UserDefaults = .standard) -> String? {
        storeLock.withLock {
            let read = readStateUnlocked(defaults: defaults)
            guard read.state.readError, let raw = read.state.corruptData else { return nil }
            return storeQuarantineCopyUnlocked(raw, defaults: defaults)
        }
    }

    struct QuarantinePersistenceHooks: Sendable {
        var defaultDirectory: @Sendable () -> URL?
        var syncFD: @Sendable (Int32, URL) -> Int32
        var fullFsync: @Sendable (Int32, URL) -> Int32
        var readBack: @Sendable (FileHandle, URL) -> Data?

        static let live = QuarantinePersistenceHooks(
            defaultDirectory: {
                guard let support = try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                ) else { return nil }
                return support.resolvingSymlinksInPath()
                    .appendingPathComponent(quarantineDirectoryName, isDirectory: true)
            },
            syncFD: { fd, _ in
                fsync(fd) == 0 ? 0 : errno
            },
            fullFsync: { file, _ in
                #if canImport(Darwin)
                return fcntl(file, F_FULLFSYNC) == 0 ? 0 : errno
                #else
                return 0
                #endif
            },
            readBack: { handle, _ in
                try? (handle.readToEnd() ?? Data())
            }
        )
    }

    public static func quarantineSubdirectory(inParentDirectory parentDirectory: URL) -> URL {
        parentDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
    }

    /// Drops an unreadable removal payload only after a byte-identical quarantine file is persisted.
    /// Touches no credential slot. Returns false when the payload is readable or the copy cannot be confirmed.
    @discardableResult
    public static func discardCorruptPayload(defaults: UserDefaults = .standard) -> Bool {
        discardCorruptPayloadResult(defaults: defaults, quarantineDirectory: nil).succeeded
    }

    static func discardCorruptPayload(defaults: UserDefaults, quarantineDirectory: URL?) -> Bool {
        discardCorruptPayloadResult(defaults: defaults, quarantineDirectory: quarantineDirectory).succeeded
    }

    static func discardCorruptPayloadResult(
        defaults: UserDefaults,
        quarantineDirectory: URL?,
        usedAlternateDirectory: Bool = false,
        hooks: QuarantinePersistenceHooks = .live
    ) -> ConnectionRemovalDiscardResult {
        storeLock.withLock {
            let read = readStateUnlocked(defaults: defaults)
            guard read.state.readError, let raw = read.state.corruptData else { return .notDiscardable }
            let key = storeQuarantineCopyUnlocked(raw, defaults: defaults)
            guard defaults.data(forKey: key) == raw else {
                return .failed(.init(
                    kind: .transientOrVerificationFailed,
                    directoryPath: quarantineDirectory?.path,
                    errorCode: nil,
                    usedAlternateDirectory: usedAlternateDirectory
                ))
            }
            switch persistQuarantineFile(
                raw,
                directory: quarantineDirectory,
                usedAlternateDirectory: usedAlternateDirectory,
                hooks: hooks
            ) {
            case .failure(let failure):
                return .failed(failure)
            case .success(let fileURL):
                guard readStateUnlocked(defaults: defaults).state.corruptData == raw else {
                    return .failed(.init(
                        kind: .transientOrVerificationFailed,
                        directoryPath: fileURL.deletingLastPathComponent().path,
                        errorCode: nil,
                        usedAlternateDirectory: usedAlternateDirectory
                    ))
                }
                defaults.removeObject(forKey: storageKey)
                guard defaults.object(forKey: storageKey) == nil else {
                    return .failed(.init(
                        kind: .transientOrVerificationFailed,
                        directoryPath: fileURL.deletingLastPathComponent().path,
                        errorCode: nil,
                        usedAlternateDirectory: usedAlternateDirectory
                    ))
                }
                return .discarded(quarantineFileURL: fileURL, usedAlternateDirectory: usedAlternateDirectory)
            }
        }
    }

    // MARK: - State Transitions

    @discardableResult
    public static func beginRemoval(
        kind: ConnectionRemovalKind,
        scope: String,
        accountId: String? = nil,
        displayName: String? = nil,
        serverURL: String? = nil,
        slotNames: [String]? = nil,
        credentialFingerprint: String? = nil,
        stage: ConnectionRemovalStage = .draining,
        error: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        defaults: UserDefaults = .standard
    ) -> ConnectionRemovalRecord? {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedScope.hasPrefix("\(kind.rawValue):"), normalizedScope.count > kind.rawValue.count + 1 else {
            return nil
        }
        if kind == .mi {
            guard let accountId, miScope(accountId: accountId) == normalizedScope else { return nil }
        }
        let allowed = allowedSlotsByKind[kind] ?? []
        let requested = slotNames ?? allowedSlots(for: kind)
        guard !requested.isEmpty, requested.allSatisfy({ allowed.contains($0) }) else { return nil }

        return storeLock.withLock {
            let loaded = readStateUnlocked(defaults: defaults)
            if loaded.state.readError {
                if let raw = loaded.state.corruptData { _ = storeQuarantineCopyUnlocked(raw, defaults: defaults) }
                return nil
            }
            let prev = loaded.state.records.first { $0.scope == normalizedScope }
            let nextVersion = max(loaded.state.ownerVersion, loaded.state.records.map(\.ownerVersion).max() ?? 0) + 1
            let uniqueSlots = requested.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let record = ConnectionRemovalRecord(
                scope: normalizedScope, kind: kind, ownerVersion: nextVersion,
                createdAtMs: prev?.createdAtMs ?? nowMs, updatedAtMs: nowMs, stage: stage,
                attempts: (prev?.attempts ?? 0) + 1,
                accountId: kind == .mi ? cleanText(accountId ?? prev?.accountId, limit: 128) : nil,
                displayName: cleanText(displayName ?? prev?.displayName, limit: 128),
                serverURL: kind == .ha ? cleanText(serverURL ?? prev?.serverURL, limit: 512) : nil,
                slotNames: uniqueSlots,
                credentialFingerprint: cleanText(credentialFingerprint ?? prev?.credentialFingerprint, limit: 128),
                lastError: cleanText(error, limit: 240), extra: prev?.extra ?? [:]
            )
            var records = loaded.state.records.filter { $0.scope != normalizedScope }
            guard records.count < maxRemovals else { return nil }
            records.append(record)
            return writeStateUnlocked(records: records, ownerVersion: nextVersion, topExtra: loaded.topExtra, corruptData: nil, defaults: defaults) ? record : nil
        }
    }

    @discardableResult
    public static func markStage(
        scope: String, ownerVersion: Int, stage: ConnectionRemovalStage, error: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), defaults: UserDefaults = .standard
    ) -> ConnectionRemovalRecord? {
        storeLock.withLock {
            let loaded = readStateUnlocked(defaults: defaults)
            guard !loaded.state.readError,
                  let idx = loaded.state.records.firstIndex(where: { $0.scope == scope }),
                  loaded.state.records[idx].ownerVersion == ownerVersion else { return nil }
            let cur = loaded.state.records[idx]
            let updated = ConnectionRemovalRecord(
                scope: cur.scope, kind: cur.kind, ownerVersion: cur.ownerVersion,
                createdAtMs: cur.createdAtMs, updatedAtMs: nowMs, stage: stage, attempts: cur.attempts,
                accountId: cur.accountId, displayName: cur.displayName, serverURL: cur.serverURL,
                slotNames: cur.slotNames, credentialFingerprint: cur.credentialFingerprint,
                lastError: cleanText(error, limit: 240), extra: cur.extra
            )
            var records = loaded.state.records
            records[idx] = updated
            return writeStateUnlocked(records: records, ownerVersion: loaded.state.ownerVersion, topExtra: loaded.topExtra, corruptData: nil, defaults: defaults) ? updated : nil
        }
    }

    @discardableResult
    public static func completeRemoval(scope: String, ownerVersion: Int, defaults: UserDefaults = .standard) -> Bool {
        storeLock.withLock {
            let loaded = readStateUnlocked(defaults: defaults)
            guard !loaded.state.readError,
                  let cur = loaded.state.records.first(where: { $0.scope == scope }),
                  cur.ownerVersion == ownerVersion else { return false }
            return writeStateUnlocked(
                records: loaded.state.records.filter { $0.scope != scope },
                ownerVersion: loaded.state.ownerVersion, topExtra: loaded.topExtra, corruptData: nil, defaults: defaults
            )
        }
    }

    @discardableResult
    public static func clearAll(defaults: UserDefaults = .standard) -> Bool {
        storeLock.withLock {
            let loaded = readStateUnlocked(defaults: defaults)
            if loaded.state.records.isEmpty && !loaded.state.readError { return true }
            return writeStateUnlocked(
                records: [], ownerVersion: loaded.state.ownerVersion,
                topExtra: loaded.topExtra, corruptData: loaded.state.corruptData, defaults: defaults
            )
        }
    }

    // MARK: - Targeted Credential Slot Deletion

    public static func executeSlotDeletion(
        record: ConnectionRemovalRecord, defaults: UserDefaults = .standard, vault: CredentialVault? = nil
    ) -> ConnectionRemovalSlotExecution {
        storeLock.withLock {
            let state = readStateUnlocked(defaults: defaults).state
            guard !state.readError else {
                return .incomplete(reason: "removal_record_unreadable", remainingSlots: record.slotNames)
            }
            guard let live = state.records.first(where: { $0.scope == record.scope }),
                  live.ownerVersion == record.ownerVersion else {
                return .completed(reboundPreserved: true)
            }
            let allowed = allowedSlotsByKind[live.kind] ?? []
            guard !live.slotNames.isEmpty, live.slotNames.allSatisfy({ allowed.contains($0) }) else {
                return .incomplete(reason: "invalid_slot_list", remainingSlots: record.slotNames)
            }
            return live.kind == .ha
                ? deleteHASlot(record: live, defaults: defaults, vault: vault)
                : deleteMiSlot(record: live, defaults: defaults, vault: vault)
        }
    }

    private static func deleteHASlot(
        record: ConnectionRemovalRecord, defaults: UserDefaults, vault: CredentialVault?
    ) -> ConnectionRemovalSlotExecution {
        let slot = KeychainHelper.tokenAccount
        let transform: (Data?) -> (CredentialVault.SlotMutation, Bool) = { existing in
            guard let existing else { return (.keep, false) }
            guard let text = String(data: existing, encoding: .utf8) else { return (.abort("ha_token_unreadable"), false) }
            guard let expected = record.credentialFingerprint, let actual = fingerprint(haToken: text) else {
                return (.abort("ha_owner_unreadable"), false)
            }
            if actual != expected {
                return (.keep, true)
            }
            return (.replace(nil), false)
        }
        return applySlotMutation(
            slot: slot, fallbackKey: KeychainHelper.secretFallbackKey(for: slot), fallbackIsString: true,
            defaults: defaults, vault: vault, transform: transform
        ) { rebound, _ in
            if !rebound {
                defaults.removeObject(forKey: KeychainHelper.legacyPlaintextTokenKey)
                defaults.removeObject(forKey: KeychainHelper.secretFallbackKey(for: slot))
                defaults.set(true, forKey: KeychainHelper.environmentTokenSignedOutKey)
            }
        }
    }

    private static func deleteMiSlot(
        record: ConnectionRemovalRecord, defaults: UserDefaults, vault: CredentialVault?
    ) -> ConnectionRemovalSlotExecution {
        let slot = MiSessionStore.keychainAccount
        guard let targetId = record.accountId, !targetId.isEmpty else {
            return .incomplete(reason: "missing_account_id", remainingSlots: [slot])
        }
        let transform: (Data?) -> (CredentialVault.SlotMutation, Bool) = { existing in
            guard let existing else { return (.keep, false) }
            guard let accounts = MiSessionStore.decodeAccountsStrict(from: existing) else {
                return (.abort("mi_session_unreadable"), false)
            }
            guard let target = accounts.first(where: { $0.id == targetId }) else { return (.keep, false) }
            guard let expected = record.credentialFingerprint else { return (.abort("mi_owner_unreadable"), false) }
            if fingerprint(miSession: target.session) != expected {
                return (.keep, true)
            }
            let remaining = accounts.filter { $0.id != targetId }
            if remaining.isEmpty { return (.replace(nil), false) }
            guard let encoded = MiSessionStore.encodeAccounts(remaining) else {
                return (.abort("mi_session_encode_failed"), false)
            }
            return (.replace(encoded), false)
        }
        return applySlotMutation(
            slot: slot, fallbackKey: MiSessionStore.fallbackDefaultsKey, fallbackIsString: false,
            defaults: defaults, vault: vault, transform: transform
        ) { rebound, updatedVault in
            if !rebound && updatedVault {
                defaults.removeObject(forKey: MiSessionStore.fallbackDefaultsKey)
            }
        }
    }

    private static func applySlotMutation(
        slot: String, fallbackKey: String, fallbackIsString: Bool,
        defaults: UserDefaults, vault: CredentialVault?,
        transform: (Data?) -> (CredentialVault.SlotMutation, Bool),
        onSuccess: (_ rebound: Bool, _ updatedVault: Bool) -> Void
    ) -> ConnectionRemovalSlotExecution {
        if vault != nil || defaults === UserDefaults.standard {
            var rebound = false
            var vaultHadValue = false
            let outcome = (vault ?? .shared).mutateSlot(slot) { existing in
                vaultHadValue = existing != nil
                let (mutation, wasRebound) = transform(existing)
                rebound = wasRebound
                return mutation
            }
            switch outcome {
            case .updated:
                onSuccess(rebound, true)
                return .completed(reboundPreserved: rebound)
            case .unchanged:
                if !vaultHadValue && !fallbackIsString && defaults.object(forKey: fallbackKey) != nil {
                    return applyDefaultsSlotMutation(
                        slot: slot, fallbackKey: fallbackKey, fallbackIsString: false,
                        defaults: defaults, transform: transform, onSuccess: onSuccess
                    )
                }
                onSuccess(rebound, false)
                return .completed(reboundPreserved: rebound)
            case .unavailable: return .incomplete(reason: "keychain_unavailable", remainingSlots: [slot])
            case .writeFailed: return .incomplete(reason: "keychain_write_failed", remainingSlots: [slot])
            case .aborted(let reason): return .incomplete(reason: reason, remainingSlots: [slot])
            }
        }
        return applyDefaultsSlotMutation(
            slot: slot, fallbackKey: fallbackKey, fallbackIsString: fallbackIsString,
            defaults: defaults, transform: transform, onSuccess: onSuccess
        )
    }

    private static func applyDefaultsSlotMutation(
        slot: String, fallbackKey: String, fallbackIsString: Bool,
        defaults: UserDefaults,
        transform: (Data?) -> (CredentialVault.SlotMutation, Bool),
        onSuccess: (_ rebound: Bool, _ updatedVault: Bool) -> Void
    ) -> ConnectionRemovalSlotExecution {
        let existing: Data?
        if fallbackIsString {
            existing = defaults.string(forKey: fallbackKey).map { Data($0.utf8) }
        } else {
            if defaults.object(forKey: fallbackKey) != nil, defaults.data(forKey: fallbackKey) == nil {
                return .incomplete(reason: "mi_session_unreadable", remainingSlots: [slot])
            }
            existing = defaults.data(forKey: fallbackKey)
        }
        let (mutation, rebound) = transform(existing)
        switch mutation {
        case .keep:
            onSuccess(rebound, false)
            return .completed(reboundPreserved: rebound)
        case .abort(let reason):
            return .incomplete(reason: reason, remainingSlots: [slot])
        case .replace(let nextData):
            if let nextData {
                if fallbackIsString, let str = String(data: nextData, encoding: .utf8) {
                    defaults.set(str, forKey: fallbackKey)
                } else {
                    defaults.set(nextData, forKey: fallbackKey)
                }
            } else {
                defaults.removeObject(forKey: fallbackKey)
            }
            onSuccess(false, false)
            return .completed(reboundPreserved: false)
        }
    }

    // MARK: - Strict Envelope Codec

    private struct LoadedEnvelope {
        let state: ConnectionRemovalState
        let topExtra: [String: JSONValue]
    }

    private static func readStateUnlocked(defaults: UserDefaults) -> LoadedEnvelope {
        guard let rawObject = defaults.object(forKey: storageKey) else {
            return LoadedEnvelope(state: .init(ownerVersion: 0, records: [], readError: false, corruptData: nil), topExtra: [:])
        }
        let rawData: Data
        if let data = rawObject as? Data { rawData = data }
        else if let str = rawObject as? String { rawData = Data(str.utf8) }
        else {
            let archived = try? PropertyListSerialization.data(fromPropertyList: rawObject, format: .binary, options: 0)
            return corruptEnvelope(archived ?? Data("non-data-removal-payload".utf8))
        }

        guard let root = try? JSONDecoder().decode(JSONValue.self, from: rawData),
              case .object(let dict) = root,
              strictInt(dict["schemaVersion"], min: 1) == schemaVersion,
              case .array(let rawRecords) = dict["removals"] else { return corruptEnvelope(rawData) }
        let envVer: Int
        if let rawVer = dict["ownerVersion"] {
            guard let parsed = strictInt(rawVer, min: 0) else { return corruptEnvelope(rawData) }
            envVer = parsed
        } else { envVer = 0 }

        var records: [ConnectionRemovalRecord] = []
        var seen: Set<String> = []
        for item in rawRecords {
            guard let record = parseRecordStrict(item), seen.insert(record.scope).inserted else {
                return corruptEnvelope(rawData)
            }
            records.append(record)
            if records.count > maxRemovals { return corruptEnvelope(rawData) }
        }
        return LoadedEnvelope(
            state: .init(ownerVersion: max(envVer, records.map(\.ownerVersion).max() ?? 0), records: records, readError: false, corruptData: nil),
            topExtra: dict.filter { !topKnownKeys.contains($0.key) }
        )
    }

    private static func corruptEnvelope(_ raw: Data) -> LoadedEnvelope {
        LoadedEnvelope(state: .init(ownerVersion: 0, records: [], readError: true, corruptData: raw), topExtra: [:])
    }

    private static func parseRecordStrict(_ value: JSONValue) -> ConnectionRemovalRecord? {
        guard case .object(let d) = value,
              let kind = d["kind"]?.stringValue.flatMap(ConnectionRemovalKind.init(rawValue:)),
              let scope = cleanText(d["scope"]?.stringValue, limit: 512),
              scope.hasPrefix("\(kind.rawValue):"), scope.count > kind.rawValue.count + 1,
              let ownerVersion = strictInt(d["ownerVersion"], min: 0),
              let stage = d["stage"]?.stringValue.flatMap(ConnectionRemovalStage.init(rawValue:)),
              let attempts = strictInt(d["attempts"], min: 0) else { return nil }
        let created = d["createdAtMs"].map { strictInt64($0) } ?? .some(0)
        let updated = d["updatedAtMs"].map { strictInt64($0) } ?? created
        guard let createdAtMs = created, let updatedAtMs = updated else { return nil }

        let allowed = allowedSlotsByKind[kind] ?? []
        guard case .array(let items) = d["slotNames"], !items.isEmpty else { return nil }
        let slots = items.compactMap(\.stringValue)
        guard slots.count == items.count, Set(slots).count == slots.count,
              slots.allSatisfy({ allowed.contains($0) }) else { return nil }

        guard let accountId = strictOptionalText(d["accountId"], limit: 128),
              let displayName = strictOptionalText(d["displayName"], limit: 128),
              let serverURL = strictOptionalText(d["serverURL"], limit: 512),
              let fingerprint = strictOptionalText(d["credentialFingerprint"], limit: 128),
              let lastError = strictOptionalText(d["lastError"], limit: 240) else { return nil }

        if kind == .mi {
            guard let accountId, miScope(accountId: accountId) == scope else { return nil }
        }

        return ConnectionRemovalRecord(
            scope: scope, kind: kind, ownerVersion: ownerVersion, createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs, stage: stage, attempts: attempts,
            accountId: kind == .mi ? accountId : nil, displayName: displayName,
            serverURL: kind == .ha ? serverURL : nil, slotNames: slots,
            credentialFingerprint: fingerprint, lastError: lastError,
            extra: d.filter { !recordKnownKeys.contains($0.key) }
        )
    }

    private static func writeStateUnlocked(
        records: [ConnectionRemovalRecord], ownerVersion: Int, topExtra: [String: JSONValue],
        corruptData: Data?, defaults: UserDefaults
    ) -> Bool {
        if let corruptData { _ = storeQuarantineCopyUnlocked(corruptData, defaults: defaults) }
        if records.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return defaults.object(forKey: storageKey) == nil
        }
        var root = topExtra
        root["schemaVersion"] = .number(Double(schemaVersion))
        root["ownerVersion"] = .number(Double(ownerVersion))
        root["removals"] = .array(records.map { r in
            var d = r.extra
            d["scope"] = .string(r.scope); d["kind"] = .string(r.kind.rawValue)
            d["ownerVersion"] = .number(Double(r.ownerVersion)); d["createdAtMs"] = .number(Double(r.createdAtMs))
            d["updatedAtMs"] = .number(Double(r.updatedAtMs)); d["stage"] = .string(r.stage.rawValue)
            d["attempts"] = .number(Double(r.attempts)); d["slotNames"] = .array(r.slotNames.map(JSONValue.string))
            if let v = r.accountId { d["accountId"] = .string(v) }
            if let v = r.displayName { d["displayName"] = .string(v) }
            if let v = r.serverURL { d["serverURL"] = .string(v) }
            if let v = r.credentialFingerprint { d["credentialFingerprint"] = .string(v) }
            if let v = r.lastError { d["lastError"] = .string(v) }
            return .object(d)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(root)) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    @discardableResult
    private static func storeQuarantineCopyUnlocked(_ raw: Data, defaults: UserDefaults) -> String {
        var key = unreadableKeyPrefix
        var suffix = 0
        while let existing = defaults.data(forKey: key) {
            if existing == raw { return key }
            suffix += 1
            key = "\(unreadableKeyPrefix).\(suffix)"
        }
        defaults.set(raw, forKey: key)
        return key
    }

    static func isFullFsyncUnsupportedError(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOTTY || code == EINVAL || code == ENOSYS
    }

    private static func persistQuarantineFile(
        _ raw: Data,
        directory: URL?,
        usedAlternateDirectory: Bool,
        hooks: QuarantinePersistenceHooks
    ) -> Result<URL, ConnectionRemovalQuarantineFailure> {
        guard let destination = directory ?? hooks.defaultDirectory() else {
            return .failure(.init(
                kind: .transientOrVerificationFailed,
                directoryPath: nil,
                errorCode: nil,
                usedAlternateDirectory: usedAlternateDirectory
            ))
        }

        let failTransient: (Int32?) -> Result<URL, ConnectionRemovalQuarantineFailure> = { code in
            .failure(.init(
                kind: .transientOrVerificationFailed,
                directoryPath: destination.path,
                errorCode: code,
                usedAlternateDirectory: usedAlternateDirectory
            ))
        }

        let parentURL = destination.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return failTransient(errno) }
        defer { close(parent) }

        var parentInfo = stat()
        let stickyBit: mode_t = 0o1000
        guard fstat(parent, &parentInfo) == 0,
              (parentInfo.st_uid == geteuid() && (parentInfo.st_mode & 0o002) == 0)
              || (parentInfo.st_uid == 0 && (parentInfo.st_mode & stickyBit) != 0) else {
            return failTransient(EACCES)
        }

        let directoryName = destination.lastPathComponent
        guard mkdirat(parent, directoryName, 0o700) == 0 || errno == EEXIST else { return failTransient(errno) }
        let folder = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return failTransient(errno) }
        defer { close(folder) }

        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            return failTransient(EACCES)
        }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let name = "\(unreadableKeyPrefix).\(digest).bin"
        let fileURL = destination.appendingPathComponent(name, isDirectory: false)
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var file = openat(folder, name, flags)
        if file < 0 {
            guard errno == ENOENT else { return failTransient(errno) }
            let writeErrno = writeQuarantineFile(raw, name: name, folder: folder, fileURL: fileURL, syncFD: hooks.syncFD)
            guard writeErrno == 0 else { return failTransient(writeErrno) }
            file = openat(folder, name, flags)
        }
        guard file >= 0 else { return failTransient(errno) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_size == raw.count else {
            return failTransient(EACCES)
        }
        // Flush the file, enforce F_FULLFSYNC on the target volume, flush directory entries, then read back.
        let fileSyncErr = hooks.syncFD(file, fileURL)
        guard fileSyncErr == 0 else { return failTransient(fileSyncErr) }
        let fullSyncErr = hooks.fullFsync(file, destination)
        if fullSyncErr != 0 {
            let kind: ConnectionRemovalQuarantineFailureKind = isFullFsyncUnsupportedError(fullSyncErr)
                ? .fullFsyncUnsupported
                : .transientOrVerificationFailed
            return .failure(.init(
                kind: kind,
                directoryPath: destination.path,
                errorCode: fullSyncErr,
                usedAlternateDirectory: usedAlternateDirectory
            ))
        }
        for (fd, url) in [(folder, destination), (parent, parentURL)] {
            let dirSyncErr = hooks.syncFD(fd, url)
            guard dirSyncErr == 0 else { return failTransient(dirSyncErr) }
        }
        guard hooks.readBack(handle, fileURL) == raw else { return failTransient(EIO) }
        return .success(fileURL)
    }

    private static func writeQuarantineFile(
        _ raw: Data,
        name: String,
        folder: Int32,
        fileURL: URL,
        syncFD: @Sendable (Int32, URL) -> Int32
    ) -> Int32 {
        let temporary = ".\(UUID().uuidString).tmp"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return errno }
        defer { _ = unlinkat(folder, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: raw)
            let syncErr = syncFD(file, fileURL)
            guard syncErr == 0 else { return syncErr }
            try handle.close()
            return renameat(folder, temporary, folder, name) == 0 ? 0 : errno
        } catch {
            return errno != 0 ? errno : EIO
        }
    }

    private static func strictInt(_ value: JSONValue?, min: Int) -> Int? {
        guard case .number(let n) = value, n.isFinite, n == n.rounded(), let i = Int(exactly: n), i >= min else { return nil }
        return i
    }

    private static func strictInt64(_ value: JSONValue) -> Int64? {
        guard case .number(let n) = value, n.isFinite, n >= 0, n == n.rounded(), let i = Int64(exactly: n) else { return nil }
        return i
    }

    private static func cleanText(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(limit))
    }

    /// Returns `.some(nil)` when absent/null, `.some(text)` when valid string, or `nil` when wrong JSON type.
    private static func strictOptionalText(_ value: JSONValue?, limit: Int) -> String?? {
        guard let value, value != .null else { return .some(nil) }
        guard let str = value.stringValue else { return nil }
        return .some(cleanText(str, limit: limit))
    }
}
