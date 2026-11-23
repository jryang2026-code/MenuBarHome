import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// P5a-M: macOS AI enable/disable and per-provider removal, mirroring the P5a-W semantics
/// (windows/tests/aiToggleAndProviderRemoval.test.ts).
@Suite(.timeLimit(.minutes(5)))
struct AssistantToggleAndProviderRemovalTests {
    static let desk = SmartDevice(
        id: "dev_desk", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.desk", isOn: false))
    )

    /// Deferred HTTP transport: records requests; each awaits an explicit release.
    @MainActor
    final class DeferredTransport {
        private var resolvers: [CheckedContinuation<(Data, URLResponse), Error>] = []
        private(set) var calls: [URLRequest] = []

        var count: Int { calls.count }

        func stub(_ request: URLRequest) async throws -> (Data, URLResponse) {
            calls.append(request)
            return try await withCheckedThrowingContinuation { resolvers.append($0) }
        }

        func release(_ result: (Data, URLResponse)) {
            resolvers.removeFirst().resume(returning: result)
        }

        func release(error: Error) {
            resolvers.removeFirst().resume(throwing: error)
        }
    }

    static func chat(_ content: String) -> (Data, URLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }

    /// A model plan that would power the desk lamp on: observable if a late result leaks through.
    static let powerOnPlan = #"{"actions":[{"device":"dev_desk","op":"power","value":true}],"reply":"已打开书房台灯"}"#

    static func temperature400() -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            statusCode: 400, httpVersion: nil, headerFields: nil
        )!
        return (Data(#"{"error":{"message":"temperature is not supported"}}"#.utf8), response)
    }

    @MainActor
    private func makeStore() async throws -> (
        store: HomeStore, mock: MockHomeProvider, vault: CredentialVault, mem: MemoryVaultStorage, defaults: UserDefaults
    ) {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = InMemoryUserDefaults()
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: []))
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        return (store, mock, vault, mem, defaults)
    }

    /// Configures a DeepSeek provider with a saved key and consent, plus an OpenRouter key as a sibling.
    @MainActor
    private func configureDeepSeek(
        _ store: HomeStore, vault: CredentialVault, defaults: UserDefaults
    ) {
        #expect(KeychainHelper.saveSecret(
            "sk-or", account: KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev),
            defaults: defaults, vault: vault
        ))
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "sk-ds"
        )))
        defaults.set(["api.deepseek.com", "openrouter.ai"], forKey: HomeStore.cloudConsentKey)
    }

    // MARK: - Defaults (fresh install off, upgrade keeps on)

    @Test("Fresh installs start with the AI assistant off; upgraded users keep it on")
    @MainActor
    func freshInstallDefaultOffLegacyKeepsOn() async throws {
        let (store, _, _, _, _) = try await makeStore()
        #expect(store.capabilityResolutionMode == .freshInstall)
        #expect(store.aiAssistantEnabled == false, "manifest ai-assistant.defaultOnFreshInstall is false")

        let mem = MemoryVaultStorage()
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: []))
        let legacy = HomeStore(provider: mock, credentialVault: CredentialVault(storage: mem.storage), defaults: defaults)
        try await legacy.waitForTestSnapshot()
        #expect(legacy.aiAssistantEnabled == true, "pre-existing users keep the always-on behavior")
    }

    // MARK: - Acceptance 1: AI off means zero requests

    @Test("AI off sends no request on a local-parse miss and never asks for cloud consent")
    @MainActor
    func offMeansZeroRequests() async throws {
        let (store, _, _, _, _) = try await makeStore()
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        #expect(await store.runAssistantCommand("我要睡觉了") == nil)
        #expect(transport.count == 0, "AI off must not send any request")
        #expect(store.pendingCloudConsent == nil, "AI off must not ask for cloud consent")
        guard case .failed(let message) = store.assistantState else {
            Issue.record("expected the off banner"); return
        }
        #expect(message == L10n.tr(
            "AI 一句话控制已关闭，指令只在本机解析；可在设置中重新开启。",
            "AI command control is off; commands are parsed on this Mac only. You can turn it back on in Settings."
        ))
    }

    @Test("AI off keeps local parsing, timers and timer execution working")
    @MainActor
    func offKeepsLocalParsingAndTimers() async throws {
        let (store, mock, _, _, _) = try await makeStore()
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        // Local parsing still acts on devices.
        _ = await store.runAssistantCommand("打开书房台灯")
        try await awaitState {
            store.devices.contains { device in
                guard device.id == Self.desk.id, case .light(let spec) = device.kind else { return false }
                return spec.isOn
            }
        }
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.desk", isOn: true)])

        // Saved timers are still created and still execute without consulting AI.
        let gate = ScheduledCommandTestSupport.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭书房台灯")
        await waitUntil { gate.waiting == 1 }
        #expect(store.scheduledCommands.count == 1)
        gate.release()
        await waitUntil { await mock.executedCommands.count == 2 }
        #expect(store.scheduledCommands.isEmpty)
        #expect(await mock.executedCommands.last == .setLightPower(entityId: "light.desk", isOn: false))
        #expect(transport.count == 0, "timer execution must not consult AI")
    }

    @Test("AI off refuses the connection probe before saving or sending")
    @MainActor
    func offRefusesProbe() async throws {
        let (store, _, _, _, _) = try await makeStore()
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "sk-ds"
        )))

        let result = await store.verifyAssistantConfig(AssistantConfig(
            baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: "sk-probe"
        ))
        #expect(result.isSuccess == false)
        #expect(result.message == L10n.tr(
            "AI 一句话控制已关闭，测试连接不可用", "AI command control is off; the connection check is unavailable"
        ))
        #expect(transport.count == 0, "the probe must not send")
        #expect(store.assistantConfig.baseURL == "https://api.deepseek.com/v1", "the draft was not saved")
    }

    // MARK: - Acceptance 3: late in-flight results dispatch nothing

    @Test("A natural-command result that lands after the switch is flipped drives nothing")
    @MainActor
    func lateResultAfterToggleOffDiscarded() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 1 }
        #expect(store.setAIAssistantEnabled(false))
        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await task.value == nil, "the discarded run returns no plan")
        #expect(await mock.executedCommands.isEmpty, "a late result must not actuate the device")
        // The discarded run must not leave the spinner up.
        try await awaitState {
            if case .thinking = store.assistantState { return false }
            return true
        }
    }

    @Test("A companion ask disconnected while the model answers drives nothing (P6a-M)")
    @MainActor
    func lateResultAfterCompanionDisconnectDiscarded() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(store.setCompanionIntegrationEnabled(true))
        let generation = store.companionGeneration
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task {
            await store.withCompanionCommandGeneration(generation) {
                await store.runAssistantCommand("我要睡觉了")
            }
        }
        await waitUntil { transport.count == 1 }
        #expect(store.setCompanionIntegrationEnabled(false))
        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await task.value == nil, "the disconnected companion run returns no plan")
        #expect(await mock.executedCommands.isEmpty, "a late result must not actuate the device")
        #expect(store.scheduledCommands.isEmpty, "nor leave a timer behind")
    }

    @Test("Disconnect clears consent requested by a companion ask and keeps local consent")
    @MainActor
    func disconnectClearsOnlyCompanionConsent() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        store.revokeCloudConsent()
        #expect(store.setCompanionIntegrationEnabled(true))
        let generation = store.companionGeneration

        let gate = ScheduledCommandTestSupport.SleepGate()
        let companion = Task {
            await store.withCompanionCommandGeneration(generation) {
                _ = await store.runAssistantCommand("我要睡觉了")
                await gate.sleep()
            }
        }
        try await awaitState { gate.waiting == 1 }
        #expect(store.pendingCloudConsent?.companionGeneration == generation)
        #expect(store.disconnectCompanionIntegration())
        #expect(store.pendingCloudConsent == nil)
        #expect(await store.allowPendingCloudRequest() == nil)
        #expect(store.consentedCloudEndpoints.isEmpty)
        #expect(await mock.executedCommands.isEmpty)

        #expect(store.setCompanionIntegrationEnabled(true))
        _ = await store.runAssistantCommand("客厅现在舒服吗")
        let local = store.pendingCloudConsent
        #expect(local != nil && local?.companionGeneration == nil)
        #expect(store.disconnectCompanionIntegration())
        #expect(store.pendingCloudConsent == local)
        gate.release()
        await companion.value
    }

    @Test("No retry may leave once AI is switched off mid-flight")
    @MainActor
    func inResolverRetryGatedAfterToggleOff() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 1 }
        #expect(store.setAIAssistantEnabled(false))
        // A temperature-400 would normally trigger one in-resolver retry; the gated transport
        // must refuse it now that AI is off.
        transport.release(Self.temperature400())
        #expect(await task.value == nil)
        #expect(transport.count == 1, "no retry may leave after the switch is off")
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A result landing during provider removal drives nothing")
    @MainActor
    func resultDuringRemovalDiscarded() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 1 }
        // Removal advances the epoch before touching storage, so a result landing during
        // the removal window is already stale (P5a-W review: advance synchronously).
        #expect(store.removeAssistantProvider(.deepSeek))
        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await task.value == nil)
        #expect(await mock.executedCommands.isEmpty, "a result landing during removal must not actuate")
    }

    @Test("A discarded proactive refresh must not claim the ambient signature")
    @MainActor
    func discardedProactiveDoesNotClaimSignature() async throws {
        let (store, _, _, _, _) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        // Loopback Ollama: no key, no consent prompt.
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", apiKey: ""
        )))
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        await waitUntil { transport.count == 1 }

        #expect(store.setAIAssistantEnabled(false))
        transport.release(Self.chat(#"{"suggestions":[]}"#))
        try await awaitState { store.isProactiveRecommending == false }
        #expect(store.lastProactiveRefreshSignature == nil, "a discarded run must not claim the signature")
        #expect(store.aiProactiveSuggestions == nil)
    }

    @Test("A manual suggestion request failing after AI is switched off shows no stale error (#321)")
    @MainActor
    func lateProactiveFailureAfterToggleOffStaysQuiet() async throws {
        let (store, _, _, _, _) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        #expect(store.setProactiveSuggestionsEnabled(true))
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", apiKey: ""
        )))
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task { await store.requestProactiveJevSuggestions() }
        await waitUntil { transport.count == 1 }
        #expect(store.setAIAssistantEnabled(false))
        let failure = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
            statusCode: 500, httpVersion: nil, headerFields: nil
        )!
        transport.release((Data(), failure))
        await task.value
        if case .failed = store.assistantState {
            Issue.record("a request the user cancelled must not surface its failure: \(store.assistantState)")
        }
    }

    // MARK: - Acceptance 2: removing a provider clears only its own config and key

    @Test("Removing the active provider deletes its slot and consent, siblings survive")
    @MainActor
    func removalScopesToOwnProvider() async throws {
        let (store, _, vault, mem, defaults) = try await makeStore()
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(KeychainHelper.saveSecret(
            "sk-custom", account: KeychainHelper.assistantProviderAPIKeyAccount(for: .custom),
            defaults: defaults, vault: vault
        ))
        // Home credentials and the pre-v1.0.4 OpenRouter slot live in the same vault: removing one
        // provider must never take them with it.
        let survivors = [
            MiSessionStore.keychainAccount: "mi-session",
            KeychainHelper.tokenAccount: "ha-token",
            LGWebOSConfig.clientKeyAccount: "lg-key",
            KeychainHelper.assistantAPIKeyAccount: "sk-legacy",
        ]
        for (account, value) in survivors {
            #expect(KeychainHelper.saveSecret(value, account: account, defaults: defaults, vault: vault))
        }
        defaults.set("192.168.1.5:8000", forKey: AssistantConfig.customKeyEndpointKey)

        #expect(store.removeAssistantProvider(.deepSeek))

        let stored = try #require(mem.storedItems)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek)] == nil, "removed provider's slot must be deleted")
        #expect(String(data: try #require(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev)]), encoding: .utf8) == "sk-or", "default preset's saved key must survive")
        #expect(String(data: try #require(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .custom)]), encoding: .utf8) == "sk-custom", "sibling slot must survive")
        // The configured provider is gone: config falls back to the shipped default preset.
        #expect(defaults.string(forKey: AssistantConfig.baseURLKey) == AssistantConfig.defaultBaseURL)
        #expect(defaults.string(forKey: AssistantConfig.modelKey) == AssistantConfig.defaultModel)
        // Consent entries owned by the removed provider go; the sibling's stays.
        #expect(store.consentedCloudEndpoints == ["openrouter.ai"])
        #expect(defaults.string(forKey: AssistantConfig.customKeyEndpointKey) == "192.168.1.5:8000")
        for (account, value) in survivors {
            #expect(stored[account].flatMap { String(data: $0, encoding: .utf8) } == value, "\(account) must survive")
        }
    }

    @Test("Removing OpenRouter deletes the legacy key slot and leaves home credentials alone (#322)")
    @MainActor
    func removingOpenRouterClearsLegacySlotOnly() async throws {
        let (store, _, vault, mem, defaults) = try await makeStore()
        let survivors = [
            MiSessionStore.keychainAccount: "mi-session",
            KeychainHelper.tokenAccount: "ha-token",
            LGWebOSConfig.clientKeyAccount: "lg-key",
        ]
        for (account, value) in survivors {
            #expect(KeychainHelper.saveSecret(value, account: account, defaults: defaults, vault: vault))
        }
        #expect(KeychainHelper.saveSecret(
            "sk-legacy", account: KeychainHelper.assistantAPIKeyAccount, defaults: defaults, vault: vault
        ))
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: AssistantConfig.defaultBaseURL, model: AssistantConfig.defaultModel, apiKey: "sk-or"
        )))

        #expect(store.removeAssistantProvider(.openRouterJev))

        let stored = try #require(mem.storedItems)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev)] == nil)
        #expect(stored[KeychainHelper.assistantAPIKeyAccount] == nil, "the pre-v1.0.4 slot would otherwise resurrect the key")
        #expect(AssistantConfig.userStoredAPIKey(
            forBaseURL: AssistantConfig.defaultBaseURL, defaults: defaults, vault: vault
        ).isEmpty)
        for (account, value) in survivors {
            #expect(stored[account].flatMap { String(data: $0, encoding: .utf8) } == value, "\(account) must survive")
        }
    }

    @Test("Removing a non-active provider leaves the active config untouched")
    @MainActor
    func removingNonActiveProviderKeepsActiveConfig() async throws {
        let (store, _, vault, mem, defaults) = try await makeStore()
        configureDeepSeek(store, vault: vault, defaults: defaults)

        #expect(store.removeAssistantProvider(.openRouterJev))

        #expect(defaults.string(forKey: AssistantConfig.baseURLKey) == "https://api.deepseek.com/v1")
        #expect(defaults.string(forKey: AssistantConfig.modelKey) == "deepseek-chat")
        let stored = try #require(mem.storedItems)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek)] != nil, "active provider's key must survive")
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev)] == nil, "removed slot entry must go")
        #expect(store.consentedCloudEndpoints == ["api.deepseek.com"])
        #expect(KeychainHelper.loadSecret(
            account: KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek),
            defaults: defaults, vault: vault
        ) == "sk-ds")
    }

    @Test("Removing the custom provider clears its binding and consent, not the saved provider")
    @MainActor
    func removingCustomClearsBindingOnly() async throws {
        let (store, _, vault, mem, defaults) = try await makeStore()
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(KeychainHelper.saveSecret(
            "sk-custom", account: KeychainHelper.assistantProviderAPIKeyAccount(for: .custom),
            defaults: defaults, vault: vault
        ))
        defaults.set("192.168.1.5:8000", forKey: AssistantConfig.customKeyEndpointKey)
        defaults.set(["api.deepseek.com", "openrouter.ai", "192.168.1.5:8000"], forKey: HomeStore.cloudConsentKey)

        #expect(store.removeAssistantProvider(.custom))

        #expect(defaults.object(forKey: AssistantConfig.customKeyEndpointKey) == nil)
        let stored = try #require(mem.storedItems)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .custom)] == nil)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek)] != nil)
        #expect(store.consentedCloudEndpoints == ["api.deepseek.com", "openrouter.ai"])
        #expect(defaults.string(forKey: AssistantConfig.baseURLKey) == "https://api.deepseek.com/v1", "active config untouched")
    }

    @Test("A refused key delete rolls the removal back so a retry targets the same provider")
    @MainActor
    func removalRollsBackOnVaultFailure() async throws {
        let (store, _, vault, mem, defaults) = try await makeStore()
        configureDeepSeek(store, vault: vault, defaults: defaults)

        mem.writeSucceeds = false
        #expect(store.removeAssistantProvider(.deepSeek) == false)
        #expect(defaults.string(forKey: AssistantConfig.baseURLKey) == "https://api.deepseek.com/v1", "config must be back so a retry removes deepseek, not the default preset")
        #expect(store.consentedCloudEndpoints == ["api.deepseek.com", "openrouter.ai"])
        #expect(KeychainHelper.loadSecret(
            account: KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek),
            defaults: defaults, vault: vault
        ) == "sk-ds")

        mem.writeSucceeds = true
        #expect(store.removeAssistantProvider(.deepSeek) == true, "retry removes the same provider")
        let stored = try #require(mem.storedItems)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .deepSeek)] == nil)
        #expect(stored[KeychainHelper.assistantProviderAPIKeyAccount(for: .openRouterJev)] != nil, "default key survives the retry")
    }

    @Test("A pending consent prompt for the removed provider is dismissed")
    @MainActor
    func removalDismissesPendingConsent() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        store.revokeCloudConsent()

        _ = await store.runAssistantCommand("我要睡觉了")
        #expect(store.pendingCloudConsent?.endpoint == "api.deepseek.com")

        #expect(store.removeAssistantProvider(.deepSeek))
        #expect(store.pendingCloudConsent == nil, "allowing it would re-grant the removed provider's consent")
    }

    @Test("Removing the provider clears the served signature and displayed AI suggestions")
    @MainActor
    func removalResetsSuggestionCache() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        await waitUntil { transport.count == 1 }
        transport.release(Self.chat(#"{"suggestions":[]}"#))
        try await awaitState { store.isProactiveRecommending == false }
        #expect(store.lastProactiveRefreshSignature != nil, "the removed provider's refresh claimed the signature")

        #expect(store.removeAssistantProvider(.deepSeek))
        #expect(store.lastProactiveRefreshSignature == nil, "a preserved signature would stop the next provider from refreshing")
        #expect(store.aiProactiveSuggestions == nil)
        #expect(store.assistantSuggestions == store.localTopSuggestions(), "displayed AI chips must not survive as executable suggestions")
        // The signature reset unblocks the next provider: the fallback preset still has its
        // sibling key, so a new background refresh may leave (that is the point of the reset).
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
    }

    @Test("Disabling AI clears a superseded request's spinner immediately")
    @MainActor
    func toggleOffClearsThinkingState() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let task = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 1 }
        #expect(store.assistantState == .thinking)
        #expect(store.setAIAssistantEnabled(false))
        #expect(store.assistantState == .idle, "the spinner must clear at the switch, not when the stale request returns")
        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await task.value == nil)
        #expect(store.assistantState == .idle, "the discarded run must not clobber the cleared state")
    }

    @Test("A discarded older command leaves a newer command's spinner up (#322)")
    @MainActor
    func staleCommandKeepsNewerSpinner() async throws {
        let (store, mock, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }

        let stale = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 1 }
        #expect(store.setAIAssistantEnabled(false))
        #expect(store.setAIAssistantEnabled(true))
        let current = Task { await store.runAssistantCommand("我要睡觉了") }
        await waitUntil { transport.count == 2 }
        #expect(store.assistantState == .thinking)

        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await stale.value == nil)
        #expect(store.assistantState == .thinking, "the newer command is still waiting for its reply")

        transport.release(Self.chat(Self.powerOnPlan))
        #expect(await current.value != nil)
        #expect(await mock.executedCommands.count == 1, "only the newer command drives the lamp")
    }

    // MARK: - Onboarding AI card save (#322 item 3)

    @Test("The guide's Done keeps a deliberately disabled assistant off when the draft only echoes the stored config")
    @MainActor
    func onboardingDoneWithUnchangedDraftKeepsAssistantOff() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(store.setAIAssistantEnabled(false))
        // Reopening the guide prefills the saved key, so Done saves the config it just read.
        let stored = store.assistantConfig

        #expect(store.saveOnboardingAssistantConfig(stored, explicit: false))
        #expect(store.aiAssistantEnabled == false, "a draft the user never changed must not re-enable a disabled assistant")
    }

    @Test("The guide's Done enables the assistant when the draft really changes the config")
    @MainActor
    func onboardingDoneWithChangedDraftEnablesAssistant() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(store.setAIAssistantEnabled(false))

        #expect(store.saveOnboardingAssistantConfig(AssistantConfig(
            baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k", apiKey: "sk-moon"
        ), explicit: false))
        #expect(store.aiAssistantEnabled, "picking a new provider is a new choice, so Done may turn AI on")
    }

    @Test("The AI card's Save button enables the assistant even when the draft matches the stored config")
    @MainActor
    func onboardingExplicitSaveEnablesAssistant() async throws {
        let (store, _, vault, _, defaults) = try await makeStore()
        #expect(store.setAIAssistantEnabled(true))
        configureDeepSeek(store, vault: vault, defaults: defaults)
        #expect(store.setAIAssistantEnabled(false))

        #expect(store.saveOnboardingAssistantConfig(store.assistantConfig, explicit: true))
        #expect(store.aiAssistantEnabled, "the card's own Save is the explicit opt-in")
    }

    // MARK: - Toggle write failures

    @Test("A refused capability-store write keeps the switch value")
    @MainActor
    func toggleRefusedWhenStoreUnreadable() async throws {
        let (store, _, _, _, defaults) = try await makeStore()
        #expect(store.aiAssistantEnabled == false)
        defaults.set(Data("not json".utf8), forKey: CapabilitySelectionStore.storageKey)

        #expect(store.setAIAssistantEnabled(true) == false)
        #expect(store.aiAssistantEnabled == false, "a refused write must not leave a half-applied state")
    }

    @Test("An uncertain identity read refuses to change the AI switch")
    @MainActor
    func toggleRefusedWhileIdentityUncertain() async throws {
        let mem = MemoryVaultStorage()
        mem.readResult = .unavailable
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: []))
        let store = HomeStore(provider: mock, credentialVault: CredentialVault(storage: mem.storage), defaults: defaults)
        try await store.waitForTestSnapshot()

        #expect(store.isIdentityUncertain)
        #expect(store.aiAssistantEnabled == true, "the preserved value stays")
        #expect(store.setAIAssistantEnabled(false) == false)
        #expect(store.aiAssistantEnabled == true)
    }

    @Test("Toggling persists across a store restart")
    @MainActor
    func togglePersistsAcrossRestart() async throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: []))
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        // A legacy user's explicit off must survive a restart.
        #expect(store.aiAssistantEnabled == true)
        #expect(store.setAIAssistantEnabled(false))

        let restarted = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: [])),
            credentialVault: vault,
            defaults: defaults
        )
        try await restarted.waitForTestSnapshot()
        #expect(restarted.aiAssistantEnabled == false)
    }
}
