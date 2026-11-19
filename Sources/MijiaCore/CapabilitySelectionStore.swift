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

/// Persists capability and connection-scope enablement in `UserDefaults` using lossless
/// read-merge-write so unknown future keys or capability identifiers survive upgrades and downgrades.
public enum CapabilitySelectionStore {
    public static let storageKey = "capability_selection_v1"
    public static let schemaVersion = 1

    private enum Keys {
        static let schemaVersion = "schemaVersion"
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
        (readValidEnvelope(defaults: defaults)?[Keys.migrationComplete] as? Bool) == true
    }

    static func explicitlyDisabledConnections(defaults: UserDefaults) -> Set<ConnectionCapabilityID> {
        let raw = readValidEnvelope(defaults: defaults)?[Keys.disabledConnections] as? [String] ?? []
        return Set(raw.compactMap(ConnectionCapabilityID.init(rawValue:)))
    }

    static func explicitlyDisabledScopes(defaults: UserDefaults) -> Set<String> {
        Set(readValidEnvelope(defaults: defaults)?[Keys.disabledConnectionScopes] as? [String] ?? [])
    }

    static func resolveAtLaunch(
        defaults: UserDefaults,
        vault: CredentialVault?,
        configuredScopes: [String],
        checkMiVault: Bool,
        checkHATokenVault: Bool,
        hasLegacySettingsOrOnboarding: Bool,
        hasPersistedLocalData: Bool,
        legacyFeatureFlags: [FeatureID: Bool]
    ) -> CapabilityInstallResolution {
        var explicitSelection: CapabilitySelection?
        var identityReadFailure: String?

        if defaults.object(forKey: storageKey) != nil {
            if let dict = readValidEnvelope(defaults: defaults) {
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

        if identityReadFailure == nil && checkMiVault,
           MiSessionStore.readExistingAccounts(defaults: defaults, vault: vault) == nil {
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
        defaults.object(forKey: storageKey) == nil || readValidEnvelope(defaults: defaults) != nil
    }

    @discardableResult
    static func save(
        selection: CapabilitySelection,
        configuredScopes: Set<String>,
        explicitlyDisabledConnections: Set<ConnectionCapabilityID>? = nil,
        removingScopes: Set<String> = [],
        defaults: UserDefaults
    ) -> Bool {
        if defaults.object(forKey: storageKey) != nil && readValidEnvelope(defaults: defaults) == nil {
            return false
        }
        var dict = readValidEnvelope(defaults: defaults) ?? [:]
        dict[Keys.schemaVersion] = schemaVersion
        dict[Keys.migrationComplete] = true
        dict[Keys.enabledConnections] = mergeKnown(
            selection.enabledConnections, existing: dict[Keys.enabledConnections] as? [String], known: knownConnections
        )
        let disabledConnections = explicitlyDisabledConnections ?? Set(
            (dict[Keys.disabledConnections] as? [String] ?? []).compactMap(ConnectionCapabilityID.init(rawValue:))
        )
        if let explicitlyDisabledConnections {
            dict[Keys.disabledConnections] = mergeKnown(
                explicitlyDisabledConnections, existing: dict[Keys.disabledConnections] as? [String], known: knownConnections
            )
        }
        var disabledScopes = Set(dict[Keys.disabledConnectionScopes] as? [String] ?? [])
        disabledScopes.subtract(removingScopes)
        disabledScopes.subtract(selection.enabledConnectionScopes)
        // A scope of a connection the user turned off as a whole is not an explicit per-scope
        // decision. Recording it would keep the scope off after the connection is turned back on and
        // would write a freshly accepted Home Assistant address down as a disabled scope (H1).
        disabledScopes.formUnion(configuredScopes.subtracting(selection.enabledConnectionScopes).filter { scope in
            CapabilityReferenceEngine.connectionCapability(forScope: scope).map { !disabledConnections.contains($0) } ?? true
        })
        dict[Keys.disabledConnectionScopes] = disabledScopes.sorted()
        dict[Keys.enabledFeatures] = mergeKnown(
            selection.enabledFeatures, existing: dict[Keys.enabledFeatures] as? [String], known: knownFeatures
        )
        dict[Keys.enabledCategories] = mergeKnown(
            selection.enabledCategories, existing: dict[Keys.enabledCategories] as? [String], known: knownCategories
        )
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    private static func readValidEnvelope(defaults: UserDefaults) -> [String: Any]? {
        guard let data = defaults.data(forKey: storageKey),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json[Keys.schemaVersion] as? Int) == schemaVersion else { return nil }
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
