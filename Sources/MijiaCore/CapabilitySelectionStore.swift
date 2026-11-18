import Foundation

extension CapabilityManifest {
    public static let shared: CapabilityManifest = {
        if let url = Bundle.module.url(forResource: "capability-manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? parse(from: data) {
            return parsed
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/capability-manifest.json")
        return try! parse(from: try! Data(contentsOf: fallback))
    }()
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

    static func save(
        selection: CapabilitySelection,
        configuredScopes: Set<String>,
        explicitlyDisabledConnections: Set<ConnectionCapabilityID>? = nil,
        removingScopes: Set<String> = [],
        defaults: UserDefaults
    ) {
        if defaults.object(forKey: storageKey) != nil && readValidEnvelope(defaults: defaults) == nil {
            return
        }
        var dict = readValidEnvelope(defaults: defaults) ?? [:]
        dict[Keys.schemaVersion] = schemaVersion
        dict[Keys.migrationComplete] = true
        dict[Keys.enabledConnections] = mergeKnown(
            selection.enabledConnections, existing: dict[Keys.enabledConnections] as? [String], known: knownConnections
        )
        if let explicitlyDisabledConnections {
            dict[Keys.disabledConnections] = mergeKnown(
                explicitlyDisabledConnections, existing: dict[Keys.disabledConnections] as? [String], known: knownConnections
            )
        }
        var disabledScopes = Set(dict[Keys.disabledConnectionScopes] as? [String] ?? [])
        disabledScopes.subtract(removingScopes)
        disabledScopes.subtract(selection.enabledConnectionScopes)
        disabledScopes.formUnion(configuredScopes.subtracting(selection.enabledConnectionScopes))
        dict[Keys.disabledConnectionScopes] = disabledScopes.sorted()
        dict[Keys.enabledFeatures] = mergeKnown(
            selection.enabledFeatures, existing: dict[Keys.enabledFeatures] as? [String], known: knownFeatures
        )
        dict[Keys.enabledCategories] = mergeKnown(
            selection.enabledCategories, existing: dict[Keys.enabledCategories] as? [String], known: knownCategories
        )
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            defaults.set(data, forKey: storageKey)
        }
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
