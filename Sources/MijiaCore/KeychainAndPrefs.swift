import Foundation
import Security

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Shows the sensor picked through `HomeStore.menuBarTargetId` (first temperature sensor when unset).
    case sensorTemperature = "sensorTemperature"
    case activeCount = "activeCount"
    case iconOnly = "iconOnly"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sensorTemperature: return L10n.tr("传感器温度 (如 26.6°)", "Sensor Temp (e.g. 26.6°)")
        case .activeCount: return L10n.tr("开启设备数", "Active Devices")
        case .iconOnly: return L10n.tr("仅显示图标", "Icon Only")
        }
    }

    /// Raw values written by ≤1.0.x that hardcoded the author's 主卧/阳台 rooms. Read once on launch
    /// and migrated to `.sensorTemperature` plus the first available temperature sensor (#36).
    public static let legacyTemperatureRawValues: Set<String> = ["primaryTemp", "balconyTemp"]
}

public enum KeychainHelper {
    public static let service = "com.jryang1997.MenuBarMijia"
    private static let account = "ha_access_token"
    /// `UserDefaults` key where ≤1.0.6 mirrored the HA token in plain text. Only read by
    /// `migratePlaintextCredentialsToKeychain`; nothing writes it any more (#16).
    static let legacyPlaintextTokenKey = "ha_fallback_token"
    /// A development-only token override. It is honoured only when the app is started with the
    /// explicit opt-in below and the user has no saved credential (#10); it can never shadow a
    /// Keychain token, and an explicit sign-out keeps it suppressed until the user saves a new token.
    public static let environmentTokenName = "HA_ACCESS_TOKEN"
    public static let environmentTokenOptInKey = "MENUBARHOME_ALLOW_HA_ACCESS_TOKEN"
    static let environmentTokenSignedOutKey = "ha_environment_token_signed_out"

    public static var localizedDefaultHomeName: String {
        L10n.tr("我的家", "My Home")
    }
    public static let defaultNASURL = "http://homeassistant.local:8123"
    public static let defaultSeededToken = ""

    public static func loadToken(
        defaults: UserDefaults = .standard,
        vault: CredentialVault? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let vault { return readKeychainSecret(account: account, vault: vault) ?? defaultSeededToken }
        guard defaults === UserDefaults.standard else {
            return loadSecret(account: account, defaults: defaults)
        }
        // Credentials live only in the Keychain (#16). An unreadable item reads as "not signed in" instead of
        // looping on the Keychain authorization prompt.
        let stored = readKeychainSecret(account: account) ?? defaultSeededToken
        return resolvedToken(
            stored: stored,
            environment: environment,
            signedOut: defaults.bool(forKey: environmentTokenSignedOutKey)
        )
    }

    static func isTokenVaultUnavailable(
        defaults: UserDefaults,
        vault: CredentialVault?,
        retryingUnavailable: Bool = false
    ) -> Bool {
        guard vault != nil || defaults === UserDefaults.standard else { return false }
        if case .unavailable = (vault ?? .shared).lookup(account, retryingUnavailable: retryingUnavailable) {
            return true
        }
        return false
    }

    /// The environment token is a development escape hatch, never a credential of its own (#10):
    /// a saved token wins, an explicit sign-out wins, and without the opt-in it is ignored.
    static func resolvedToken(stored: String, environment: [String: String], signedOut: Bool) -> String {
        guard stored.isEmpty,
              !signedOut,
              environment[environmentTokenOptInKey] == "1",
              let envToken = environment[environmentTokenName]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !envToken.isEmpty else {
            return stored
        }
        return envToken
    }

    /// Saves (or, with an empty token, deletes) the Home Assistant token. Returns false when the
    /// Keychain or vault refused the write, so sign-out can report an incomplete revocation.
    @discardableResult
    public static func saveToken(
        _ token: String,
        defaults: UserDefaults = .standard,
        vault: CredentialVault? = nil
    ) -> Bool {
        // An explicit vault is the revocation test seam; it must observe a failing Keychain even for
        // a custom defaults suite, which otherwise keeps credentials in the suite (see below).
        if let vault {
            guard writeKeychainSecret(token, account: account, vault: vault) else { return false }
            defaults.removeObject(forKey: secretFallbackKey(for: account))
            defaults.set(
                token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                forKey: environmentTokenSignedOutKey
            )
            return true
        }
        // A test suite keeps its token in the suite, never in the real login Keychain. This mirrors
        // `loadToken(defaults:)`, so HomeStore tests can exercise sign-out and revocation.
        guard defaults === UserDefaults.standard else {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = secretFallbackKey(for: account)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(trimmed, forKey: key)
            }
            defaults.set(trimmed.isEmpty, forKey: environmentTokenSignedOutKey)
            return true
        }
        guard writeKeychainSecret(token, account: account) else { return false }
        defaults.removeObject(forKey: legacyPlaintextTokenKey)
        defaults.set(
            token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            forKey: environmentTokenSignedOutKey
        )
        return true
    }

    // MARK: - Keychain Primitives

    /// Every credential is one entry of `CredentialVault` (a single Keychain item, read once per process), so
    /// these keep their per-account shape while macOS only ever sees one item (#16).
    static func readKeychainSecret(account: String, vault: CredentialVault = .shared) -> String? {
        guard let data = readKeychainData(account: account, vault: vault),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readKeychainData(account: String, vault: CredentialVault = .shared) -> Data? {
        vault.data(for: account)
    }

    /// Saving an empty value deletes the item.
    @discardableResult
    static func writeKeychainSecret(_ value: String, account: String, vault: CredentialVault = .shared) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return writeKeychainData(trimmed.isEmpty ? nil : trimmed.data(using: .utf8), account: account, vault: vault)
    }

    /// Passing `nil` deletes the item. A refused write keeps the previous value.
    @discardableResult
    static func writeKeychainData(_ data: Data?, account: String, vault: CredentialVault = .shared) -> Bool {
        vault.set(data, for: account)
    }

    static func deleteKeychainItem(account: String, vault: CredentialVault = .shared) {
        vault.set(nil, for: account)
    }

    // MARK: - Plaintext Migration (#16, #27)

    /// Moves every credential that ≤1.0.6 mirrored into plain `UserDefaults` into the Keychain, then deletes the
    /// plaintext copies. Idempotent: with no plaintext key left it does nothing. Call once at launch, before
    /// anything reads a credential.
    public static func migratePlaintextCredentialsToKeychain(defaults: UserDefaults = .standard, vault: CredentialVault = .shared) {
        // Only the app's own domain ever held these keys; a test suite must never write production accounts.
        guard defaults === UserDefaults.standard else { return }
        migratePlaintextSecret(defaults: defaults, plaintextKey: legacyPlaintextTokenKey, account: account, vault: vault)
        for accountName in assistantSecretAccounts {
            migratePlaintextSecret(defaults: defaults, plaintextKey: secretFallbackKey(for: accountName), account: accountName, vault: vault)
        }
        migratePlaintextSecret(
            defaults: defaults,
            plaintextKey: LGWebOSConfig.clientKeyDefaultsKey,
            account: LGWebOSConfig.clientKeyAccount, vault: vault
        )
        migratePlaintextSession(defaults: defaults, vault: vault)
    }

    /// Legacy plaintext must never replace a credential already protected by Keychain. Keep the plaintext
    /// for retry when the vault cannot be read or written.
    static func migratePlaintextSecret(
        defaults: UserDefaults, plaintextKey: String, account: String, vault: CredentialVault = .shared
    ) {
        guard let raw = defaults.string(forKey: plaintextKey) else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || vault.insertIfMissing(Data(value.utf8), for: account) else { return }
        defaults.removeObject(forKey: plaintextKey)
    }

    static func migratePlaintextSession(
        defaults: UserDefaults, account: String = MiSessionStore.keychainAccount, vault: CredentialVault = .shared
    ) {
        guard let legacy = defaults.data(forKey: MiSessionStore.fallbackDefaultsKey) else { return }
        // Re-encoding through `MiSession` into a v2 envelope drops the `passToken` that ≤1.0.6 also persisted
        // (#27, ADR-0004).
        if let data = MiSessionStore.migratedData(fromLegacyDefaults: legacy) {
            guard vault.insertIfMissing(data, for: account) else { return }
        }
        defaults.removeObject(forKey: MiSessionStore.fallbackDefaultsKey)
    }
}
