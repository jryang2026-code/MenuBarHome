import Foundation
import Testing
import KeychainTestSupport
@testable import MijiaCore

/// 审计 #7 / #9 / #10：保存失败必须回到 UI、跨区扫码按登录响应里的真实地区落库、开发用
/// `HA_ACCESS_TOKEN` 不得盖过用户保存的凭据或退出登录状态。
struct CredentialSaveResultTests {
    private func memoryVault(_ storage: MemoryVaultStorage = MemoryVaultStorage()) -> CredentialVault {
        CredentialVault(storage: storage.storage)
    }

    private func suiteDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "test.credential-result.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    @Test("A refused LG pairing-key write is reported instead of silently dropped")
    func lgPairingKeyWriteIsReported() throws {
        let storage = MemoryVaultStorage()
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = LGWebOSConfig(host: "192.0.2.10", clientKey: "pairing-key")
        #expect(config.save(to: defaults, vault: vault) == false)
        #expect(defaults.string(forKey: LGWebOSConfig.clientKeyDefaultsKey) == nil,
                "a refused Keychain write must not fall back to a plaintext copy")
        #expect(KeychainHelper.readKeychainSecret(account: LGWebOSConfig.clientKeyAccount, vault: vault) == nil)
    }

    @Test("A stored LG pairing key round-trips through the injected vault")
    func lgPairingKeyRoundTripsThroughVault() throws {
        let vault = memoryVault()
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = LGWebOSConfig(host: "192.0.2.10", clientKey: "pairing-key")
        #expect(config.save(to: defaults, vault: vault))
        #expect(defaults.string(forKey: LGWebOSConfig.clientKeyDefaultsKey) == nil)
        #expect(LGWebOSConfig.load(from: defaults, vault: vault).clientKey == "pairing-key")
    }

    @Test("An LG pairing confirmation whose key was not stored shows an error, never 'Paired'")
    @MainActor
    func lgPairingRefusalShowsErrorToast() throws {
        let storage = MemoryVaultStorage()
        storage.writeSucceeds = false
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        #expect(store.applyLGClientKey("pairing-key") == false)
        #expect(store.lgConfig.clientKey.isEmpty, "the in-memory config must not pretend the key was saved")
        let notice = try #require(store.toastNotice)
        #expect(notice.isError)
        #expect(!notice.message.contains("已成功配对"))
        #expect(!notice.message.contains("Paired with"))
    }

    @Test("A stored LG pairing key keeps the success toast")
    @MainActor
    func lgPairingSuccessStillToasts() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil

        #expect(store.applyLGClientKey("pairing-key"))
        #expect(store.lgConfig.clientKey == "pairing-key")
        let notice = try #require(store.toastNotice)
        #expect(!notice.isError)
    }

    @Test("AssistantConfig.save reports a refused Keychain write and leaves the saved endpoint alone")
    func assistantConfigSaveReportsFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved = AssistantConfig(
            baseURL: "https://openrouter.ai/api/v1",
            model: "~typesafe/jev-latest",
            apiKey: "sk-saved"
        )
        #expect(saved.save(to: defaults, vault: vault))
        let baseline = AssistantConfig.load(from: defaults, vault: vault)

        storage.writeSucceeds = false
        let replacement = AssistantConfig(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-replacement"
        )
        #expect(replacement.save(to: defaults, vault: vault) == false)
        let reloaded = AssistantConfig.load(from: defaults, vault: vault)
        #expect(reloaded.baseURL == baseline.baseURL, "a refused key write must not move the endpoint")
        #expect(reloaded.apiKey == "sk-saved", "the previous key stays active")
    }

    @Test("HomeStore.assistantConfigSave reports the refused write to the caller")
    @MainActor
    func storeAssistantSaveReportsFailure() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        let (suite, defaults) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        storage.writeSucceeds = false
        let config = AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "m", apiKey: "sk-x")
        #expect(store.saveAssistantConfig(config) == false)
        #expect(store.assistantConfig.apiKey.isEmpty)
    }
}

struct MiLoginRegionInferenceTests {
    @Test("The login location's p_idc selects the account's real region")
    func regionFromDataCenter() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=AT&p_idc=Europe&nonce=x"
        )!) == "de")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=CN&p_idc=China&nonce=x"
        )!) == "cn")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=IN&p_idc=India&nonce=x"
        )!) == "i2")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=SG&p_idc=Singapore&nonce=x"
        )!) == "sg")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=US&p_idc=America&nonce=x"
        )!) == "us")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=RU&p_idc=Russia&nonce=x"
        )!) == "ru")
    }

    @Test("A region country code is used when the data-center name is unfamiliar")
    func regionFallsBackToCountryCode() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=de"
        )!) == "de")
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=GB&p_idc=Europe"
        )!) == "de")
    }

    @Test("Unknown hosts, plaintext locations and missing hints never invent a region")
    func regionRejectsUntrustedOrAmbiguousLocations() {
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://evil.example/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://xiaomi.com.evil.example/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "http://sts.api.io.mi.com/sts?p_ur=DE&p_idc=Europe"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1"
        )!) == nil)
        #expect(MiAccountLogin.regionCode(fromLoginLocation: URL(
            string: "https://sts.api.io.mi.com/sts?d=wb_1&p_ur=XX&p_idc=Unknown"
        )!) == nil)
    }

    @Test("waitForScan stores the region the login response proves, not the hand-picked one")
    func waitForScanUsesProvenRegion() async throws {
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.api.io.mi.com/sts?d=wb_1&p_ur=DE&p_idc=Europe"}"#)
            }
            if url.hasPrefix("https://sts.api.io.mi.com") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/; domain=.mi.com"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport, region: "cn")
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )
        let session = try await login.waitForScan(ticket)
        #expect(session.region == "de")
    }

    @Test("waitForScan keeps the selected region when the location carries no trusted hint")
    func waitForScanKeepsSelectedRegionWhenUnknown() async throws {
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.example/sts?p_ur=DE&p_idc=Europe"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/; domain=.example"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport, region: "sg")
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )
        let session = try await login.waitForScan(ticket)
        #expect(session.region == "sg")
    }
}

struct HAEnvironmentTokenTests {
    private let env: [String: String] = [
        KeychainHelper.environmentTokenName: "env-token",
        KeychainHelper.environmentTokenOptInKey: "1",
    ]

    @Test("A saved credential always wins over the development environment token")
    func savedCredentialWins() {
        #expect(KeychainHelper.resolvedToken(stored: "saved-token", environment: env, signedOut: false) == "saved-token")
    }

    @Test("The environment token needs an explicit opt-in")
    func environmentTokenNeedsOptIn() {
        let withoutOptIn = [KeychainHelper.environmentTokenName: "env-token"]
        #expect(KeychainHelper.resolvedToken(stored: "", environment: withoutOptIn, signedOut: false) == "")
        #expect(KeychainHelper.resolvedToken(stored: "", environment: env, signedOut: false) == "env-token")
    }

    @Test("Signing out keeps the environment token from signing the user back in")
    func signOutSuppressesEnvironmentToken() {
        #expect(KeychainHelper.resolvedToken(stored: "", environment: env, signedOut: true) == "")
    }

    @Test("Saving and clearing the token toggles the sign-out marker on the default suite")
    func saveTokenTogglesSignOutMarker() throws {
        let suite = "test.env-token.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)

        #expect(KeychainHelper.saveToken("saved-token", defaults: defaults, vault: vault))
        #expect(defaults.bool(forKey: KeychainHelper.environmentTokenSignedOutKey) == false)
        #expect(KeychainHelper.saveToken("", defaults: defaults, vault: vault))
        #expect(defaults.bool(forKey: KeychainHelper.environmentTokenSignedOutKey))
    }
}
