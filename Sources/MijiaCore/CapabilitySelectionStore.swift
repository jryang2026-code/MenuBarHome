import Foundation

extension CapabilityManifest {
    public static let shared: CapabilityManifest = {
        guard let data = bundledData(), let parsed = try? parse(from: data) else {
            preconditionFailure("capability-manifest.json is missing from the MijiaCore bundle")
        }
        return parsed
    }()

    /// Bytes of the bundled document. Resolved only through runtime bundle paths: a compile-time
    /// source-location fallback would write the build machine's checkout into the release binary,
    /// which `scripts/build_app.sh` rejects (#275).
    static func bundledData() -> Data? {
        var urls: [URL] = []
        #if !os(macOS)
        if let url = Bundle.module.url(forResource: "capability-manifest", withExtension: "json", subdirectory: "Resources") {
            urls.append(url)
        }
        if let url = Bundle.module.url(forResource: "capability-manifest", withExtension: "json") {
            urls.append(url)
        }
        if let root = Bundle.module.resourceURL {
            urls.append(root.appendingPathComponent("Resources/capability-manifest.json"))
            urls.append(root.appendingPathComponent("capability-manifest.json"))
        }
        #endif
        for base in L10n.translationSearchBases {
            urls.append(base.appendingPathComponent("Resources/capability-manifest.json"))
            urls.append(base.appendingPathComponent("capability-manifest.json"))
            for name in L10n.resourceDirectoryNames(in: base) {
                let bundle = base.appendingPathComponent(name)
                urls.append(bundle.appendingPathComponent("Resources/capability-manifest.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/Resources/capability-manifest.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/capability-manifest.json"))
            }
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }
}

/// Delta representing only the fields and scopes changed by a single capability write, so
/// revision-conflict merges never overwrite unrelated edits or undo another writer's disable.
public struct CapabilitySelectionPatch: Equatable, Sendable {
    public var addedConnections: Set<ConnectionCapabilityID>
    public var removedConnections: Set<ConnectionCapabilityID>
    public var addedDisabledConnections: Set<ConnectionCapabilityID>
    public var removedDisabledConnections: Set<ConnectionCapabilityID>
    public var enabledScopes: Set<String>
    public var disabledScopes: Set<String>
    public var removedScopes: Set<String>
    public var addedFeatures: Set<FeatureID>
    public var removedFeatures: Set<FeatureID>
    public var addedCategories: Set<DeviceCategoryID>
    public var removedCategories: Set<DeviceCategoryID>

    public init(
        addedConnections: Set<ConnectionCapabilityID> = [],
        removedConnections: Set<ConnectionCapabilityID> = [],
        addedDisabledConnections: Set<ConnectionCapabilityID> = [],
        removedDisabledConnections: Set<ConnectionCapabilityID> = [],
        enabledScopes: Set<String> = [],
        disabledScopes: Set<String> = [],
        removedScopes: Set<String> = [],
        addedFeatures: Set<FeatureID> = [],
        removedFeatures: Set<FeatureID> = [],
        addedCategories: Set<DeviceCategoryID> = [],
        removedCategories: Set<DeviceCategoryID> = []
    ) {
        self.addedConnections = addedConnections
        self.removedConnections = removedConnections
        self.addedDisabledConnections = addedDisabledConnections
        self.removedDisabledConnections = removedDisabledConnections
        self.enabledScopes = enabledScopes
        self.disabledScopes = disabledScopes
        self.removedScopes = removedScopes
        self.addedFeatures = addedFeatures
        self.removedFeatures = removedFeatures
        self.addedCategories = addedCategories
        self.removedCategories = removedCategories
    }

    public static func diff(
        from base: CapabilitySelection,
        baseDisabledConnections: Set<ConnectionCapabilityID>,
        baseDisabledScopes: Set<String> = [],
        to target: CapabilitySelection,
        targetDisabledConnections: Set<ConnectionCapabilityID>,
        targetDisabledScopes: Set<String> = [],
        configuredScopes: Set<String> = [],
        removingScopes: Set<String> = []
    ) -> CapabilitySelectionPatch {
        let addedConnections = target.enabledConnections.subtracting(base.enabledConnections)
        let removedConnections = base.enabledConnections.subtracting(target.enabledConnections)
        let addedDisabledConnections = targetDisabledConnections.subtracting(baseDisabledConnections)
        let removedDisabledConnections = baseDisabledConnections.subtracting(targetDisabledConnections)

        var enabledScopes = target.enabledConnectionScopes.subtracting(base.enabledConnectionScopes)
        enabledScopes.formUnion(baseDisabledScopes.subtracting(targetDisabledScopes))
        enabledScopes.subtract(removingScopes)

        var disabledScopes = base.enabledConnectionScopes.subtracting(target.enabledConnectionScopes)
        disabledScopes.formUnion(targetDisabledScopes.subtracting(baseDisabledScopes))
        disabledScopes.subtract(removingScopes)
        disabledScopes = disabledScopes.filter { scope in
            guard configuredScopes.isEmpty || configuredScopes.contains(scope) || targetDisabledScopes.contains(scope) else {
                return false
            }
            return CapabilityReferenceEngine.connectionCapability(forScope: scope)
                .map { !targetDisabledConnections.contains($0) } ?? true
        }

        return CapabilitySelectionPatch(
            addedConnections: addedConnections,
            removedConnections: removedConnections,
            addedDisabledConnections: addedDisabledConnections,
            removedDisabledConnections: removedDisabledConnections,
            enabledScopes: enabledScopes,
            disabledScopes: disabledScopes,
            removedScopes: removingScopes,
            addedFeatures: target.enabledFeatures.subtracting(base.enabledFeatures),
            removedFeatures: base.enabledFeatures.subtracting(target.enabledFeatures),
            addedCategories: target.enabledCategories.subtracting(base.enabledCategories),
            removedCategories: base.enabledCategories.subtracting(target.enabledCategories)
        )
    }
}

/// Authoritative post-write state persisted to disk, returned so callers can synchronize in-memory
/// state after a conflict merge.
public struct CapabilitySelectionPersistedState: Equatable, Sendable {
    public let enabledConnections: Set<ConnectionCapabilityID>
    public let disabledConnections: Set<ConnectionCapabilityID>
    public let disabledScopes: Set<String>
    public let enabledFeatures: Set<FeatureID>
    public let enabledCategories: Set<DeviceCategoryID>

    public init(
        enabledConnections: Set<ConnectionCapabilityID>,
        disabledConnections: Set<ConnectionCapabilityID>,
        disabledScopes: Set<String>,
        enabledFeatures: Set<FeatureID>,
        enabledCategories: Set<DeviceCategoryID>
    ) {
        self.enabledConnections = enabledConnections
        self.disabledConnections = disabledConnections
        self.disabledScopes = disabledScopes
        self.enabledFeatures = enabledFeatures
        self.enabledCategories = enabledCategories
    }
}

/// Outcome of persisting `CapabilitySelectionStore`, including optimistic-revision conflict merge diagnostics.
public struct CapabilitySelectionSaveResult: Equatable, Sendable {
    public let succeeded: Bool
    public let revision: Int?
    public let hadConflict: Bool
    public let diagnostic: String?
    public let persistedState: CapabilitySelectionPersistedState?

    public init(
        succeeded: Bool,
        revision: Int?,
        hadConflict: Bool,
        diagnostic: String?,
        persistedState: CapabilitySelectionPersistedState? = nil
    ) {
        self.succeeded = succeeded
        self.revision = revision
        self.hadConflict = hadConflict
        self.diagnostic = diagnostic
        self.persistedState = persistedState
    }
}

/// Persists capability and connection-scope enablement in `UserDefaults` using lossless
/// read-merge-write so unknown future keys or capability identifiers survive upgrades and downgrades.
public enum CapabilitySelectionStore {
    public static let storageKey = "capability_selection_v1"
    public static let schemaVersion = 1
    /// Serializes read-modify-write sequences within the process so concurrent writers cannot
    /// interleave stale snapshots and drop each other's updates.
    private static let storeLock = NSLock()

    private enum Keys {
        static let schemaVersion = "schemaVersion"
        static let revision = "revision"
        static let migrationComplete = "migrationComplete"
        static let enabledConnections = "enabledConnections"
        static let disabledConnections = "disabledConnections"
        static let disabledConnectionScopes = "disabledConnectionScopes"
        static let enabledFeatures = "enabledFeatures"
        static let enabledCategories = "enabledCategories"
    }

    private static let knownConnections = Set(ConnectionCapabilityID.allCases.map(\.rawValue))
    private static let knownFeatures = Set(FeatureID.allCases.map(\.rawValue))
    private static let knownCategories = Set(DeviceCategoryID.allCases.map(\.rawValue))

    public static func hasCompletedMigration(defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock()
        defer { storeLock.unlock() }
        return (readValidEnvelopeUnlocked(defaults: defaults)?[Keys.migrationComplete] as? Bool) == true
    }

    static func currentRevision(defaults: UserDefaults) -> Int? {
        storeLock.lock()
        defer { storeLock.unlock() }
        return readValidEnvelopeUnlocked(defaults: defaults)?[Keys.revision] as? Int
    }

    static func explicitlyDisabledConnections(defaults: UserDefaults) -> Set<ConnectionCapabilityID> {
        storeLock.lock()
        defer { storeLock.unlock() }
        let raw = readValidEnvelopeUnlocked(defaults: defaults)?[Keys.disabledConnections] as? [String] ?? []
        return Set(raw.compactMap(ConnectionCapabilityID.init(rawValue:)))
    }

    static func explicitlyDisabledScopes(defaults: UserDefaults) -> Set<String> {
        storeLock.lock()
        defer { storeLock.unlock() }
        return Set(readValidEnvelopeUnlocked(defaults: defaults)?[Keys.disabledConnectionScopes] as? [String] ?? [])
    }

    static func resolveAtLaunch(
        defaults: UserDefaults,
        vault: CredentialVault?,
        configuredScopes: [String],
        miAccountsResult: MiSessionStore.AccountsLoadResult,
        checkMiVault: Bool,
        checkHATokenVault: Bool,
        hasLegacySettingsOrOnboarding: Bool,
        hasPersistedLocalData: Bool,
        legacyFeatureFlags: [FeatureID: Bool],
        connectionRemovalReadError: Bool = false
    ) -> CapabilityInstallResolution {
        var explicitSelection: CapabilitySelection?
        var identityReadFailure: String?

        let rawPresenceAndEnvelope: (present: Bool, dict: [String: Any]?) = {
            storeLock.lock()
            defer { storeLock.unlock() }
            let present = defaults.object(forKey: storageKey) != nil
            let dict = present ? readValidEnvelopeUnlocked(defaults: defaults) : nil
            return (present, dict)
        }()

        if rawPresenceAndEnvelope.present {
            if let dict = rawPresenceAndEnvelope.dict {
                if (dict[Keys.migrationComplete] as? Bool) == true {
                    let disabledConns = Set((dict[Keys.disabledConnections] as? [String] ?? [])
                        .compactMap(ConnectionCapabilityID.init(rawValue:)))
                    let disabledScopes = Set(dict[Keys.disabledConnectionScopes] as? [String] ?? [])
                    var conns = Set((dict[Keys.enabledConnections] as? [String] ?? [])
                        .compactMap(ConnectionCapabilityID.init(rawValue:)))
                    for scope in configuredScopes {
                        if let conn = CapabilityReferenceEngine.connectionCapability(forScope: scope),
                           !disabledConns.contains(conn) {
                            conns.insert(conn)
                        }
                    }
                    conns.subtract(disabledConns)
                    let feats = Set((dict[Keys.enabledFeatures] as? [String] ?? FeatureID.allCases.map(\.rawValue))
                        .compactMap(FeatureID.init(rawValue:)))
                    let cats = Set((dict[Keys.enabledCategories] as? [String] ?? DeviceCategoryID.allCases.map(\.rawValue))
                        .compactMap(DeviceCategoryID.init(rawValue:)))
                    explicitSelection = CapabilitySelection(
                        enabledConnections: conns,
                        enabledConnectionScopes: Set(configuredScopes).subtracting(disabledScopes),
                        enabledFeatures: feats,
                        enabledCategories: cats
                    )
                }
            } else {
                identityReadFailure = "corrupt_capability_selection"
            }
        }

        if identityReadFailure == nil && connectionRemovalReadError {
            identityReadFailure = "corrupt_connection_removal"
        }
        if identityReadFailure == nil && checkMiVault,
           case .unavailable = miAccountsResult {
            identityReadFailure = "mi_accounts_unavailable"
        }
        if identityReadFailure == nil && checkHATokenVault,
           KeychainHelper.isTokenVaultUnavailable(defaults: defaults, vault: vault) {
            identityReadFailure = "ha_token_unavailable"
        }

        let evidence = CapabilityInstallEvidence(
            explicitSelection: explicitSelection,
            hasLegacySettingsOrOnboarding: hasLegacySettingsOrOnboarding,
            configuredConnectionScopes: configuredScopes,
            hasPersistedLocalData: hasPersistedLocalData,
            legacyFeatureFlags: legacyFeatureFlags,
            identityReadFailure: identityReadFailure
        )
        let resolution = CapabilityReferenceEngine.resolveInstallSelection(evidence: evidence, manifest: .shared)
        if resolution.persistMigrationComplete && !hasCompletedMigration(defaults: defaults) {
            save(selection: resolution.selection, configuredScopes: Set(configuredScopes), defaults: defaults)
        }
        return resolution
    }

    /// True when `save` can write: the stored envelope is either absent or still readable. Callers
    /// that pair a write with a side effect (pausing references) check this first, so a refused write
    /// never leaves a half-applied disable behind.
    public static func canPersist(defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock()
        defer { storeLock.unlock() }
        return defaults.object(forKey: storageKey) == nil || readValidEnvelopeUnlocked(defaults: defaults) != nil
    }

    @discardableResult
    static func save(
        selection: CapabilitySelection,
        configuredScopes: Set<String>,
        explicitlyDisabledConnections: Set<ConnectionCapabilityID>? = nil,
        removingScopes: Set<String> = [],
        defaults: UserDefaults
    ) -> Bool {
        saveMergingConflicts(
            selection: selection,
            configuredScopes: configuredScopes,
            explicitlyDisabledConnections: explicitlyDisabledConnections,
            removingScopes: removingScopes,
            patch: nil,
            expectedRevision: nil,
            defaults: defaults
        ).succeeded
    }

    /// Read-merge-write with optimistic revision tracking. When another writer advanced the stored
    /// revision since `expectedRevision`, only the caller's actual `patch` delta is merged onto
    /// disk's latest state so unknown keys, other writers' feature edits, and connection/account
    /// disables survive intact.
    @discardableResult
    static func saveMergingConflicts(
        selection: CapabilitySelection,
        configuredScopes: Set<String>,
        explicitlyDisabledConnections: Set<ConnectionCapabilityID>? = nil,
        removingScopes: Set<String> = [],
        patch: CapabilitySelectionPatch? = nil,
        expectedRevision: Int? = nil,
        defaults: UserDefaults
    ) -> CapabilitySelectionSaveResult {
        storeLock.lock()
        defer { storeLock.unlock() }

        if defaults.object(forKey: storageKey) != nil && readValidEnvelopeUnlocked(defaults: defaults) == nil {
            return CapabilitySelectionSaveResult(
                succeeded: false,
                revision: nil,
                hadConflict: false,
                diagnostic: "corrupt_capability_selection"
            )
        }
        var dict = readValidEnvelopeUnlocked(defaults: defaults) ?? [:]
        let diskRevision = dict[Keys.revision] as? Int
        let hadConflict = expectedRevision != nil && diskRevision != expectedRevision
        let nextRevision = (diskRevision ?? 0) + 1
        dict[Keys.schemaVersion] = schemaVersion
        dict[Keys.revision] = nextRevision
        dict[Keys.migrationComplete] = true

        let diskEnabledConnections = Set((dict[Keys.enabledConnections] as? [String] ?? [])
            .compactMap(ConnectionCapabilityID.init(rawValue:)))
        let diskDisabledConnections = Set((dict[Keys.disabledConnections] as? [String] ?? [])
            .compactMap(ConnectionCapabilityID.init(rawValue:)))
        let diskDisabledScopes = Set(dict[Keys.disabledConnectionScopes] as? [String] ?? [])
        let diskEnabledFeatures = Set((dict[Keys.enabledFeatures] as? [String] ?? FeatureID.allCases.map(\.rawValue))
            .compactMap(FeatureID.init(rawValue:)))
        let diskEnabledCategories = Set((dict[Keys.enabledCategories] as? [String] ?? DeviceCategoryID.allCases.map(\.rawValue))
            .compactMap(DeviceCategoryID.init(rawValue:)))

        let finalEnabledConnections: Set<ConnectionCapabilityID>
        let finalDisabledConnections: Set<ConnectionCapabilityID>
        let finalDisabledScopes: Set<String>
        let finalEnabledFeatures: Set<FeatureID>
        let finalEnabledCategories: Set<DeviceCategoryID>
        let shouldWriteDisabledConnections: Bool

        if hadConflict {
            if let patch {
                var mergedDisabledConnections = diskDisabledConnections
                mergedDisabledConnections.formUnion(patch.addedDisabledConnections)
                mergedDisabledConnections.subtract(patch.removedDisabledConnections)

                var mergedConnections = diskEnabledConnections
                mergedConnections.formUnion(patch.addedConnections)
                mergedConnections.subtract(patch.removedConnections)
                mergedConnections.subtract(mergedDisabledConnections)

                var mergedDisabledScopes = diskDisabledScopes
                mergedDisabledScopes.subtract(patch.removedScopes)
                mergedDisabledScopes.subtract(removingScopes)
                mergedDisabledScopes.subtract(patch.enabledScopes)
                mergedDisabledScopes.formUnion(patch.disabledScopes.filter { scope in
                    CapabilityReferenceEngine.connectionCapability(forScope: scope)
                        .map { !mergedDisabledConnections.contains($0) } ?? true
                })

                var mergedFeatures = diskEnabledFeatures
                mergedFeatures.formUnion(patch.addedFeatures)
                mergedFeatures.subtract(patch.removedFeatures)

                var mergedCategories = diskEnabledCategories
                mergedCategories.formUnion(patch.addedCategories)
                mergedCategories.subtract(patch.removedCategories)

                let normalized = CapabilitySelection(
                    enabledConnections: mergedConnections,
                    enabledConnectionScopes: configuredScopes.subtracting(mergedDisabledScopes).filter { scope in
                        CapabilityReferenceEngine.connectionCapability(forScope: scope)
                            .map { mergedConnections.contains($0) && !mergedDisabledConnections.contains($0) } ?? true
                    },
                    enabledFeatures: mergedFeatures,
                    enabledCategories: mergedCategories
                ).normalized(with: .shared)

                finalDisabledConnections = mergedDisabledConnections
                finalEnabledConnections = normalized.enabledConnections.subtracting(mergedDisabledConnections)
                finalDisabledScopes = mergedDisabledScopes
                finalEnabledFeatures = normalized.enabledFeatures
                finalEnabledCategories = normalized.enabledCategories
                shouldWriteDisabledConnections = explicitlyDisabledConnections != nil
                    || dict[Keys.disabledConnections] != nil
                    || !finalDisabledConnections.isEmpty
            } else {
                // Conservative fallback when a caller reports a stale revision without a delta patch:
                // never undo a connection or scope disable already persisted by another writer.
                var mergedDisabledConnections = diskDisabledConnections
                if let explicitlyDisabledConnections {
                    mergedDisabledConnections.formUnion(explicitlyDisabledConnections)
                }
                let mergedConnections = diskEnabledConnections
                    .union(selection.enabledConnections)
                    .subtracting(mergedDisabledConnections)
                var mergedDisabledScopes = diskDisabledScopes
                mergedDisabledScopes.subtract(removingScopes)
                mergedDisabledScopes.formUnion(configuredScopes.subtracting(selection.enabledConnectionScopes).filter { scope in
                    CapabilityReferenceEngine.connectionCapability(forScope: scope)
                        .map { !mergedDisabledConnections.contains($0) } ?? true
                })
                finalDisabledConnections = mergedDisabledConnections
                finalEnabledConnections = mergedConnections
                finalDisabledScopes = mergedDisabledScopes
                finalEnabledFeatures = diskEnabledFeatures
                finalEnabledCategories = diskEnabledCategories
                shouldWriteDisabledConnections = explicitlyDisabledConnections != nil
                    || dict[Keys.disabledConnections] != nil
                    || !finalDisabledConnections.isEmpty
            }
        } else {
            let disabledConnections = explicitlyDisabledConnections ?? diskDisabledConnections
            var disabledScopes = diskDisabledScopes
            disabledScopes.subtract(removingScopes)
            disabledScopes.subtract(selection.enabledConnectionScopes)
            // A scope of a connection the user turned off as a whole is not an explicit per-scope
            // decision. Recording it would keep the scope off after the connection is turned back on and
            // would write a freshly accepted Home Assistant address down as a disabled scope (H1).
            disabledScopes.formUnion(configuredScopes.subtracting(selection.enabledConnectionScopes).filter { scope in
                CapabilityReferenceEngine.connectionCapability(forScope: scope)
                    .map { !disabledConnections.contains($0) } ?? true
            })
            finalEnabledConnections = selection.enabledConnections
            finalDisabledConnections = disabledConnections
            finalDisabledScopes = disabledScopes
            finalEnabledFeatures = selection.enabledFeatures
            finalEnabledCategories = selection.enabledCategories
            shouldWriteDisabledConnections = explicitlyDisabledConnections != nil
        }

        dict[Keys.enabledConnections] = mergeKnown(
            finalEnabledConnections, existing: dict[Keys.enabledConnections] as? [String], known: knownConnections
        )
        if shouldWriteDisabledConnections {
            dict[Keys.disabledConnections] = mergeKnown(
                finalDisabledConnections, existing: dict[Keys.disabledConnections] as? [String], known: knownConnections
            )
        }
        dict[Keys.disabledConnectionScopes] = finalDisabledScopes.sorted()
        dict[Keys.enabledFeatures] = mergeKnown(
            finalEnabledFeatures, existing: dict[Keys.enabledFeatures] as? [String], known: knownFeatures
        )
        dict[Keys.enabledCategories] = mergeKnown(
            finalEnabledCategories, existing: dict[Keys.enabledCategories] as? [String], known: knownCategories
        )

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return CapabilitySelectionSaveResult(
                succeeded: false,
                revision: diskRevision,
                hadConflict: hadConflict,
                diagnostic: "encode_capability_selection_failed"
            )
        }
        defaults.set(data, forKey: storageKey)
        let diagnostic = hadConflict
            ? "merged_revision_conflict:\(expectedRevision ?? 0)->\(diskRevision ?? 0)->\(nextRevision)"
            : nil
        let persistedState = CapabilitySelectionPersistedState(
            enabledConnections: finalEnabledConnections,
            disabledConnections: finalDisabledConnections,
            disabledScopes: finalDisabledScopes,
            enabledFeatures: finalEnabledFeatures,
            enabledCategories: finalEnabledCategories
        )
        return CapabilitySelectionSaveResult(
            succeeded: true,
            revision: nextRevision,
            hadConflict: hadConflict,
            diagnostic: diagnostic,
            persistedState: persistedState
        )
    }

    private static func readValidEnvelopeUnlocked(defaults: UserDefaults) -> [String: Any]? {
        guard let data = defaults.data(forKey: storageKey),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json[Keys.schemaVersion] as? Int) == schemaVersion else { return nil }
        if let rev = json[Keys.revision], !(rev is Int) { return nil }
        if let flag = json[Keys.migrationComplete], !(flag is Bool) { return nil }
        for key in [Keys.enabledConnections, Keys.disabledConnections, Keys.disabledConnectionScopes, Keys.enabledFeatures, Keys.enabledCategories] {
            if let value = json[key], !(value is [String]) { return nil }
        }
        return json
    }

    private static func mergeKnown<T: RawRepresentable>(
        _ selected: Set<T>, existing: [String]?, known: Set<String>
    ) -> [String] where T.RawValue == String {
        var combined = selected.map(\.rawValue).sorted()
        for unknown in (existing ?? []) where !known.contains(unknown) && !combined.contains(unknown) {
            combined.append(unknown)
        }
        return combined
    }
}
