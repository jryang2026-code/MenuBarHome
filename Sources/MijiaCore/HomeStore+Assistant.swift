import Foundation
import Observation

// Assistant side of HomeStore: command bar, model/local intent resolution,
// spoken delays, voice undo and applying intents to devices.
// Stored state lives in HomeStore.swift (extensions cannot hold stored properties).
extension HomeStore {
    public var assistantConfig: AssistantConfig {
        get { AssistantConfig.load(from: userDefaults, vault: credentialVault) }
        set {
            let previous = assistantConfig
            _ = newValue.save(to: userDefaults, vault: credentialVault)
            let after = assistantConfig
            if previous.baseURL != after.baseURL || previous.model != after.model || previous.apiKey != after.apiKey {
                advanceAssistantEpoch()
            }
        }
    }

    /// Supersedes every in-flight AI request: results that arrive under an older generation are
    /// discarded before they can drive a device or claim the suggestion cache (P5a-M).
    func advanceAssistantEpoch() {
        assistantEpoch &+= 1
    }

    /// Whether the AI assistant feature is enabled. Fresh installs start with it off (the
    /// `ai-assistant` manifest entry, P4a-M), upgraded users keep it on, and an uncertain
    /// identity read preserves whatever was read last.
    public var aiAssistantEnabled: Bool {
        capabilitySelection.enabledFeatures.contains(.aiAssistant)
    }

    /// Turns the AI feature on or off (P5a-M). Turning it off supersedes in-flight requests,
    /// stops the proactive background consumer, and dismisses a pending cloud-consent prompt;
    /// the saved provider config and key slots stay untouched, so re-enabling restores the
    /// previous setup. Returns false and keeps the current value when the write is refused:
    /// identity reads failed closed (`isIdentityUncertain`) or the capability store rejected
    /// the save.
    @discardableResult
    public func setAIAssistantEnabled(_ enabled: Bool) -> Bool {
        guard enabled != aiAssistantEnabled else { return true }
        guard !isIdentityUncertain else {
            showToast(
                L10n.tr(
                    "仍无法读取历史配置或凭据，请检查钥匙串授权后重试",
                    "Still unable to read settings or credentials; check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }
        let previous = capabilitySelection
        var next = capabilitySelection
        if enabled {
            next.enabledFeatures.insert(.aiAssistant)
        } else {
            next.enabledFeatures.remove(.aiAssistant)
        }
        capabilitySelection = next.normalized(with: .shared)
        // Supersede in-flight results before persisting: nothing may land after the switch flips.
        advanceAssistantEpoch()
        proactiveRefreshTask?.cancel()
        if !enabled {
            pendingCloudConsent = nil
            // A spinner left over from a superseded request would keep 语音提交 locked out
            // (SpeechInputController refuses while .thinking), so clear it here instead of
            // waiting for the stale cloud response to return (P5a-M Codex review).
            clearThinkingAssistantState()
            // Suggestions and cache the AI produced stop being displayed: with the feature
            // off they could still be tapped, and keeping the signature served would block
            // a fresh AI refresh after re-enabling.
            resetAISuggestionCache()
        }
        guard persistCapabilitySelection() else {
            capabilitySelection = previous
            showToast(
                L10n.tr("无法保存 AI 开关状态，请重试", "Could not save the AI switch; try again"),
                isError: true
            )
            return false
        }
        return true
    }

    /// Whether 主动建议 is enabled (P5b-M). Fresh installs start with it on (the
    /// `proactive-suggestions` manifest entry), upgraded users keep it on, and an uncertain
    /// identity read preserves whatever was read last. Independent of `aiAssistantEnabled`:
    /// with AI off the suggestions still rank locally.
    public var proactiveSuggestionsEnabled: Bool {
        capabilitySelection.enabledFeatures.contains(.proactiveSuggestions)
    }

    /// Turns 主动建议 on or off (P5b-M). Off means the shared snapshot cadence never enters the
    /// suggestion branch: no ambient signature, habit ranking, cache read, chip or background
    /// request. Safety alerts, undo expiry and saved timers keep their own schedule. Only the
    /// suggestion generation advances, so a command the user started is never cancelled.
    /// Returns false and keeps the current value when the write is refused.
    @discardableResult
    public func setProactiveSuggestionsEnabled(_ enabled: Bool) -> Bool {
        guard enabled != proactiveSuggestionsEnabled else { return true }
        guard !isIdentityUncertain else {
            showToast(
                L10n.tr(
                    "仍无法读取历史配置或凭据，请检查钥匙串授权后重试",
                    "Still unable to read settings or credentials; check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }
        let previous = capabilitySelection
        var next = capabilitySelection
        if enabled {
            next.enabledFeatures.insert(.proactiveSuggestions)
        } else {
            next.enabledFeatures.remove(.proactiveSuggestions)
        }
        capabilitySelection = next.normalized(with: .shared)
        // Supersede in-flight suggestion runs before persisting: none may claim the cache later.
        proactiveEpoch &+= 1
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        if !enabled {
            aiProactiveSuggestions = nil
            lastProactiveRefreshSignature = nil
            proactiveRetryEarliest = nil
            // Choices a command is waiting on are not suggestions; keep them.
            if case .awaitingChoice = assistantState {} else {
                assistantSuggestions = []
            }
        }
        guard persistCapabilitySelection() else {
            capabilitySelection = previous
            showToast(
                L10n.tr("无法保存主动建议开关状态，请重试", "Could not save the suggestions switch; try again"),
                isError: true
            )
            return false
        }
        return true
    }

    /// Persists an AI configuration and reports whether the Keychain accepted the key (#7). The Settings
    /// and onboarding forms use this instead of the silent setter so a refused write never looks saved.
    @discardableResult
    public func saveAssistantConfig(_ config: AssistantConfig) -> Bool {
        let previous = assistantConfig
        guard config.save(to: userDefaults, vault: credentialVault) else { return false }
        // A provider switch or key change supersedes results still in flight (P5a-M).
        let after = assistantConfig
        if previous.baseURL != after.baseURL || previous.model != after.model || previous.apiKey != after.apiKey {
            advanceAssistantEpoch()
        }
        return true
    }

    public var userHabitMemory: UserHabitMemory {
        get { UserHabitMemory.load(from: userDefaults) }
        set { newValue.save(to: userDefaults) }
    }

    public func presentAssistantBar(startVoice: Bool = false) {
        isShowingAssistantBar = true
        refreshProactiveSuggestionCacheIfStale()
        if startVoice && enableVoiceInput {
            assistantVoiceRequest &+= 1
        } else {
            assistantFocusRequest &+= 1
        }
    }

    /// Zero delay: re-ranks the cache locally from habits, favorites, environment, and running
    /// devices when it is empty or stale, then lets a configured model refresh it in the background (#113).
    public func refreshProactiveSuggestionCacheIfStale() {
        guard proactiveSuggestionsEnabled else { return }
        if !assistantState.isUserActive,
           assistantSuggestions.isEmpty || proactiveRefreshSignature() != lastProactiveRefreshSignature {
            assistantSuggestions = proactiveDisplaySuggestions()
        }
        maybeRefreshProactiveSuggestionsInBackground()
    }

    /// The suggestions to show when nothing else claims the chips: the AI cache while it still
    /// matches the ambient context, otherwise the local Top 4. Empty while 主动建议 is off (P5b-M).
    func proactiveDisplaySuggestions() -> [AssistantSuggestion] {
        guard proactiveSuggestionsEnabled else { return [] }
        if proactiveRefreshSignature() == lastProactiveRefreshSignature {
            proactiveWorkCounters.cacheReads += 1
            if let ai = aiProactiveSuggestions, !ai.isEmpty { return ai }
        }
        return localTopSuggestions()
    }

    /// The local zero-delay Top 4 (#113). Empty while 主动建议 is off: no habit ranking runs (P5b-M).
    func localTopSuggestions() -> [AssistantSuggestion] {
        guard proactiveSuggestionsEnabled else { return [] }
        proactiveWorkCounters.rankings += 1
        return userHabitMemory.topSuggestions(
            for: assistantNow(),
            devices: devices,
            scenes: scenes,
            favoriteIds: favoriteOrder,
            environmentReadings: environmentReadings
        )
    }

    /// Time bucket + per-room temperature (1 °C steps) and humidity (5 % steps): the ambient
    /// signature that decides when the suggestion cache is stale (#113).
    func proactiveRefreshSignature(now: Date? = nil) -> String {
        proactiveWorkCounters.signatures += 1
        let now = now ?? assistantNow()
        let bucket = UserHabitMemory.TimeBucket.from(date: now)
        let readings = environmentReadings.map { reading -> String in
            let temperature = reading.temperature.map { String(($0 / 1.0).rounded()) } ?? "-"
            let humidity = reading.humidity.map { String((($0 / 5.0).rounded() * 5)) } ?? "-"
            return "\(temperature)/\(humidity)"
        }
        return "\(bucket.rawValue)|\(readings.joined(separator: ","))"
    }

    /// Fires the silent background AI refresh when the ambient context changed since the
    /// last successful one; returns the task (also stored in `proactiveRefreshTask`) or nil (#113).
    /// The signature is recorded only when a refresh produces a usable result — a failed
    /// attempt retries after `proactiveRetryCooldown` instead of being swallowed (Codex #116 review).
    @discardableResult
    public func maybeRefreshProactiveSuggestionsInBackground() -> Task<Void, Never>? {
        // 主动建议 off (P5b-M): checked before anything else, so the snapshot cadence pays nothing.
        guard proactiveSuggestionsEnabled, aiAssistantEnabled else { return nil }
        let signature = proactiveRefreshSignature()
        guard signature != lastProactiveRefreshSignature else { return nil }
        if let retryAfter = proactiveRetryEarliest, assistantNow() < retryAfter { return nil }
        guard homeBackend != .demo,
              !assistantState.isUserActive else { return nil }
        let config = assistantConfig
        guard !shouldRejectMissingAPIKey(for: config),
              cloudConsentNeeded(for: config, utterance: nil) == nil else { return nil }
        let task = Task { await self.refreshProactiveSuggestionsCache(signature: signature) }
        proactiveRefreshTask = task
        return task
    }

    /// Silent cache refresh: never blocks the panel, never asks for consent, never surfaces
    /// errors — the previous cache simply survives a failed refresh (#113).
    public func refreshProactiveSuggestionsCache(signature: String? = nil) async {
        guard !isProactiveRecommending, homeBackend != .demo, !assistantState.isUserActive else { return }
        let config = assistantConfig
        guard proactiveSuggestionsEnabled, aiAssistantEnabled,
              !shouldRejectMissingAPIKey(for: config),
              cloudConsentNeeded(for: config, utterance: nil) == nil else { return }
        let epoch = assistantEpoch
        let suggestionEpoch = proactiveEpoch
        let attemptedSignature = signature ?? proactiveRefreshSignature()
        let context = controlContextID
        isProactiveRecommending = true
        defer { isProactiveRecommending = false }
        let resolver = makeAssistantResolver(config: config, epoch: epoch, proactiveEpoch: suggestionEpoch)
        let assistantContext = buildAssistantContext(mention: .none)
        do {
            let inferred = try await resolver.recommendProactiveSuggestions(
                devices: devices,
                scenes: scenes,
                context: assistantContext
            )
            // A disable, provider change or removal supersedes this run: it must not claim the
            // signature (a superseded signature would never retry) or feed the cache (P5a-M).
            guard context == controlContextID,
                  epoch == assistantEpoch,
                  suggestionEpoch == proactiveEpoch, proactiveSuggestionsEnabled,
                  aiAssistantEnabled, !assistantState.isUserActive else { return }
            // The context counts as served only once a usable result landed (Codex #116 review);
            // an empty result is a valid "home is ideal" answer and falls back to the local
            // ranking instead of stale suggestions (Codex #116 re-review).
            lastProactiveRefreshSignature = attemptedSignature
            aiProactiveSuggestions = inferred
            assistantSuggestions = inferred.isEmpty ? localTopSuggestions() : inferred
        } catch {
            // A discarded run (AI or suggestions switched off, provider changed, task cancelled)
            // is not a failure: a cooldown would delay the first refresh after re-enabling (#322).
            guard !isAssistantRunSuperseded(error, epoch: epoch),
                  suggestionEpoch == proactiveEpoch, proactiveSuggestionsEnabled,
                  !Task.isCancelled else { return }
            proactiveRetryEarliest = assistantNow().addingTimeInterval(proactiveRetryCooldown)
        }
    }

    public func setPreviewState(
        assistantState: AssistantState,
        suggestions: [AssistantSuggestion],
        undoBanner: UndoBanner? = nil,
        homeBackend: HomeBackend? = nil,
        miSessionMaskedUserId: String? = nil
    ) {
        self.assistantState = assistantState
        self.assistantSuggestions = suggestions
        self.undoBanner = undoBanner
        if let homeBackend {
            self.homeBackend = homeBackend
        }
        if let miSessionMaskedUserId {
            self.miSessionMaskedUserId = miSessionMaskedUserId
        }
    }

    public func dismissAssistantBar() {
        isShowingAssistantBar = false
        if assistantState != .thinking {
            setAssistantState(.idle)
        }
    }

    public func buildAssistantContext(now: Date = Date(), mention: CommandMention) -> AssistantContext {
        let bucket = UserHabitMemory.TimeBucket.from(date: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeSummary = "\(bucket.rawValue) \(formatter.string(from: now))"

        let envParts = environmentReadings.map { reading -> String in
            var text = PromptText.cleanField(reading.roomName, limit: PromptText.nameLimit)
            if let t = reading.temperature, t.isFinite { text += " \(String(format: "%.1f°C", t))" }
            if let h = reading.humidity.flatMap(DeviceSynthesizer.roundedInt) { text += " \(h)%" }
            return text
        }
        let environmentSummary = envParts.joined(separator: "，")

        let activeParts = devices.filter(\.isActiveDevice).map { dev in
            let name = PromptText.cleanField(dev.name, limit: PromptText.nameLimit)
            let state = PromptText.cleanField(IntentCatalog.stateSummary(dev), limit: PromptText.activeStateLimit)
            return "\(name)(\(state))"
        }
        let activeSummary = activeParts.isEmpty
            ? L10n.tr("全屋设备均关闭", "All devices are off")
            : activeParts.joined(separator: "、")
        let habitSummary = shareHabitSentence(
            sharing: habitSharing,
            memory: userHabitMemory,
            devices: devices,
            scenes: scenes,
            mention: mention,
            now: now
        )

        return AssistantContext(
            timeSummary: PromptText.cleanField(timeSummary, limit: PromptText.contextLimit),
            environmentSummary: PromptText.cleanField(environmentSummary, limit: PromptText.contextLimit),
            activeDevicesSummary: PromptText.cleanField(activeSummary, limit: PromptText.contextLimit),
            habitSummary: PromptText.cleanField(habitSummary, limit: PromptText.contextLimit),
            favoriteDeviceIds: favoriteOrder
        )
    }

    /// Uses the configured AI model (Jev System One or OpenAI-compatible Chat) to infer personalized proactive suggestions
    /// from current room temp/humidity, time of day, active devices, and the user's learned habit memory.
    public func requestProactiveJevSuggestions() async {
        guard proactiveSuggestionsEnabled, !isProactiveRecommending else { return }
        guard homeBackend != .demo else {
            // 演示模式完全离线（#47）：只给基于本地习惯记忆的建议。
            assistantSuggestions = localTopSuggestions()
            setAssistantState(.done(L10n.tr("演示模式建议基于内置虚拟设备", "Demo suggestions are based on the built-in virtual home")))
            return
        }
        let config = assistantConfig
        guard aiAssistantEnabled else {
            assistantSuggestions = localTopSuggestions()
            setAssistantState(.failed(L10n.tr(
                "AI 一句话控制已关闭，指令只在本机解析；可在设置中重新开启。",
                "AI command control is off; commands are parsed on this Mac only. You can turn it back on in Settings."
            )))
            return
        }
        if shouldRejectMissingAPIKey(for: config) {
            setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
            return
        }
        if let consent = cloudConsentNeeded(for: config, utterance: nil) {
            pendingCloudConsent = consent
            return
        }
        let epoch = assistantEpoch
        let suggestionEpoch = proactiveEpoch
        isProactiveRecommending = true
        defer { isProactiveRecommending = false }

        let controlContext = controlContextID
        let snapshotDevices = devices
        let snapshotScenes = scenes
        let resolver = makeAssistantResolver(config: config, epoch: epoch, proactiveEpoch: suggestionEpoch)
        let context = buildAssistantContext(mention: .none)
        do {
            let inferred = try await resolver.recommendProactiveSuggestions(
                devices: snapshotDevices,
                scenes: snapshotScenes,
                context: context
            )
            guard controlContext == controlContextID, epoch == assistantEpoch,
                  suggestionEpoch == proactiveEpoch else { return }
            if !inferred.isEmpty {
                assistantSuggestions = inferred
                let label = ModelIntentResolver.isSystemOneModel(config.model) ? "Jev" : "AI"
                setAssistantState(.done(L10n.tr("\(label) 已结合室温与习惯生成建议", "\(label) generated suggestions from room climate & habits")))
            } else {
                let fallback = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
                assistantSuggestions = fallback
                setAssistantState(.done(L10n.tr("当前居家状态已处于理想区间", "Home environment is already in an ideal range")))
            }
        } catch {
            guard controlContext == controlContextID else { return }
            // Superseded runs keep the previous suggestions; showing a fake failure would
            // describe a request the user already cancelled (P5a-M).
            if error as? AssistantError == .superseded || suggestionEpoch != proactiveEpoch { return }
            setAssistantState(.failed(AssistantError.userMessage(for: error)))
        }
    }

    /// Persists and verifies the given AI configuration against the live endpoint using the same reloaded `assistantConfig` as normal command execution.
    public func verifyAssistantConfig(_ draftConfig: AssistantConfig) async -> (isSuccess: Bool, message: String) {
        // The probe is an AI request too, so the switch gates it (P5a-M acceptance #1).
        guard aiAssistantEnabled else {
            return (
                false,
                L10n.tr("AI 一句话控制已关闭，测试连接不可用", "AI command control is off; the connection check is unavailable")
            )
        }
        guard saveAssistantConfig(draftConfig) else {
            return (
                false,
                L10n.tr(
                    "无法写入钥匙串，请授权钥匙串访问后重试",
                    "Could not save to Keychain; allow Keychain access and try again"
                )
            )
        }
        guard homeBackend != .demo else {
            return (false, L10n.tr("演示模式不联网，请切换数据源后测试连接", "Demo mode is offline; switch the data source to test this connection"))
        }
        let resolved = assistantConfig
        if shouldRejectMissingAPIKey(for: resolved) {
            return (false, AssistantError.userMessage(for: AssistantError.missingAPIKey))
        }
        // Capture after the save (which advances the epoch): a disable or provider change
        // while the probe runs must stop its initial attempt and any retry (P5a-M).
        let epoch = assistantEpoch
        let resolver = makeAssistantResolver(config: resolved, epoch: epoch)
        do {
            let ms = try await resolver.testConnection()
            guard epoch == assistantEpoch, aiAssistantEnabled else {
                return (false, L10n.tr("AI 已关闭或服务商已切换，测试中止", "AI was disabled or the provider changed; the check was aborted"))
            }
            let presetLabel = resolved.preset.shortTitle
            return (
                true,
                L10n.tr(
                    "连接成功 (\(presetLabel) · \(ms) ms)",
                    "Connected (\(presetLabel) · \(ms) ms)"
                )
            )
        } catch {
            if error as? AssistantError == .superseded, epoch != assistantEpoch || !aiAssistantEnabled {
                return (false, L10n.tr("AI 已关闭或服务商已切换，测试中止", "AI was disabled or the provider changed; the check was aborted"))
            }
            return (false, AssistantError.userMessage(for: error))
        }
    }

    // MARK: - Cloud consent (#20)

    static let cloudConsentKey = "assistant_cloud_consent_v1"

    /// AI services (host[:port]) the user has allowed to receive commands. Local endpoints never need this.
    public var consentedCloudEndpoints: [String] {
        userDefaults.stringArray(forKey: Self.cloudConsentKey) ?? []
    }

    /// The consent request to show before the first cloud call to this service, or nil when sending is already allowed.
    func cloudConsentNeeded(
        for config: AssistantConfig, utterance: String?, companionGeneration: UInt64? = nil
    ) -> PendingCloudConsent? {
        guard assistantResolverOverride == nil, !config.isLoopbackEndpoint,
              let endpoint = AssistantEndpoint(config.baseURL)?.identity,
              !consentedCloudEndpoints.contains(endpoint) else {
            return nil
        }
        return PendingCloudConsent(
            utterance: utterance, endpoint: endpoint, providerTitle: config.preset.shortTitle,
            companionGeneration: companionGeneration
        )
    }

    /// Remembers the user's OK for the waiting service, then runs what was waiting.
    @discardableResult
    public func allowPendingCloudRequest() async -> IntentPlan? {
        guard let pending = pendingCloudConsent else { return nil }
        pendingCloudConsent = nil
        if let generation = pending.companionGeneration, !companionCanExecute(generation: generation) { return nil }
        var endpoints = consentedCloudEndpoints
        if !endpoints.contains(pending.endpoint) {
            endpoints.append(pending.endpoint)
        }
        userDefaults.set(endpoints, forKey: Self.cloudConsentKey)
        guard let utterance = pending.utterance else {
            await requestProactiveJevSuggestions()
            return nil
        }
        if let generation = pending.companionGeneration {
            return await withCompanionCommandGeneration(generation) { await runAssistantCommand(utterance) }
        }
        return await runAssistantCommand(utterance)
    }

    public func declinePendingCloudRequest() {
        guard pendingCloudConsent != nil else { return }
        pendingCloudConsent = nil
        setAssistantState(.failed(L10n.tr(
            "没有发送。「打开书房灯」这类简单指令不用联网",
            "Not sent. Direct commands like \"turn on study light\" work offline."
        )))
    }

    /// Forgets every allowed AI service; the next cloud request asks again.
    public func revokeCloudConsent() {
        userDefaults.removeObject(forKey: Self.cloudConsentKey)
        pendingCloudConsent = nil
    }

    // MARK: - Provider Removal (P5a-M)

    /// Removes one AI provider's local configuration: its Keychain key slot, its imported-key
    /// label and custom-endpoint binding, and the cloud-consent entries that belong to it.
    /// Sibling providers keep their slots, bindings and consents. When the removed preset is
    /// the configured one, the saved base URL and model fall back to the shipped default
    /// preset, whose own saved key (if any) is kept. Returns false when the Keychain refused
    /// the key delete; nothing else was touched in that case, so Settings can offer a retry.
    @discardableResult
    public func removeAssistantProvider(_ preset: AssistantProviderPreset) -> Bool {
        // Supersede in-flight results synchronously, before any storage write (P5a-W review:
        // a result landing during the removal window must not drive a device).
        advanceAssistantEpoch()
        proactiveRefreshTask?.cancel()
        // The key delete is the only step that can refuse; run it alone first so a refusal
        // leaves the config, bindings and consent untouched and the removal retryable.
        guard AssistantConfig.clearSecret(for: preset, defaults: userDefaults, vault: credentialVault) else {
            return false
        }
        _ = removeAssistantProviderBindings(preset: preset)
        if let pending = pendingCloudConsent,
           AssistantProviderPreset.infer(baseURL: "https://\(pending.endpoint)") == preset {
            pendingCloudConsent = nil
        }
        // The removed provider's inferred suggestions and served signature must not survive:
        // displayed chips stay executable through applyAssistantSuggestion, and a preserved
        // signature would stop the next provider from ever refreshing the cache (P5a-M
        // Codex review). The spinner of a superseded request goes too.
        resetAISuggestionCache()
        clearThinkingAssistantState()
        return true
    }

    /// Drops the AI-served suggestion state: the cached recommendations, the ambient signature
    /// they claimed, and the displayed chips fall back to the local Top 4.
    private func resetAISuggestionCache() {
        aiProactiveSuggestions = nil
        lastProactiveRefreshSignature = nil
        assistantSuggestions = localTopSuggestions()
    }

    /// Drops the UserDefaults-side bindings of one provider: the imported-key label, the
    /// custom key-endpoint binding, and the consent entries the provider owns (endpoint
    /// identity → preset, the same ownership rule as P5a-W). Resets the saved base URL and
    /// model to the default preset when the removed preset was the configured one. Returns
    /// the pruned consent identities.
    @discardableResult
    private func removeAssistantProviderBindings(preset: AssistantProviderPreset) -> [String] {
        userDefaults.removeObject(forKey: AssistantConfig.importedKeySourceKey(for: preset))
        if preset == .custom {
            userDefaults.removeObject(forKey: AssistantConfig.customKeyEndpointKey)
        }
        let consented = consentedCloudEndpoints
        let pruned = consented.filter { endpoint in
            AssistantProviderPreset.infer(baseURL: "https://\(endpoint)") == preset
        }
        if !pruned.isEmpty {
            userDefaults.set(consented.filter { !pruned.contains($0) }, forKey: Self.cloudConsentKey)
        }
        let savedBase = userDefaults.string(forKey: AssistantConfig.baseURLKey) ?? AssistantConfig.defaultBaseURL
        if AssistantProviderPreset.infer(baseURL: savedBase) == preset {
            // The configured provider is gone: fall back to the shipped default preset. Its own
            // key slot is untouched, so `AssistantConfig.load` surfaces that key again.
            userDefaults.set(AssistantConfig.defaultBaseURL, forKey: AssistantConfig.baseURLKey)
            userDefaults.set(AssistantConfig.defaultModel, forKey: AssistantConfig.modelKey)
        }
        return pruned
    }

    private func shouldRejectMissingAPIKey(for config: AssistantConfig) -> Bool {
        assistantResolverOverride == nil && !config.hasAPIKey && !config.isLoopbackEndpoint
    }

    /// Builds the model resolver with a transport gate: every attempt — the initial call and
    /// the in-resolver temperature-400 retry alike — re-checks the AI switch and the captured
    /// epoch before a byte leaves (P5a-M acceptance #1/#3, mirroring P5a-W).
    /// A suggestion run also passes `proactiveEpoch`, so closing 主动建议 refuses its retries (P5b-M).
    private func makeAssistantResolver(config: AssistantConfig, epoch: Int, proactiveEpoch: Int? = nil) -> ModelIntentResolver {
        if let override = assistantResolverOverride { return override }
        let base = assistantTransportOverride ?? ModelIntentResolver.defaultTransport(for: config)
        let gate: ModelIntentResolver.Transport = { [weak self] request in
            guard let self else { throw AssistantError.superseded }
            let allowed = await MainActor.run {
                self.assistantEpoch == epoch && self.aiAssistantEnabled
                    && (proactiveEpoch.map { $0 == self.proactiveEpoch && self.proactiveSuggestionsEnabled } ?? true)
            }
            guard allowed else { throw AssistantError.superseded }
            return try await base(request)
        }
        return ModelIntentResolver(config: config, transport: gate)
    }

    /// True when a model run's error or generation means the result must be dropped silently:
    /// the store left mid-run, the AI switch flipped, or the provider changed (P5a-M).
    func isAssistantRunSuperseded(_ error: Error, epoch: Int) -> Bool {
        if error as? AssistantError == .superseded { return true }
        return epoch != assistantEpoch || !aiAssistantEnabled
    }

    /// Clears the spinner a discarded run left behind without clobbering a newer reply.
    private func clearThinkingAssistantState() {
        if case .thinking = assistantState {
            setAssistantState(.idle)
        }
    }

    /// The on-device resolver when the user has not chosen a provider and Apple's model is usable.
    /// `assistantResolverOverride` keeps its old meaning: a forced cloud resolver in tests.
    func localCommandResolver(for config: AssistantConfig) -> (any AssistantCommandResolving)? {
        guard assistantResolverOverride == nil else { return nil }
        let availability = localAssistantAvailabilityOverride ?? .current
        guard AssistantModelSelection.route(for: config, localAvailability: availability) == .localFoundation else {
            return nil
        }
        if let override = localAssistantResolverOverride { return override }
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return FoundationModelIntentResolver()
            #endif
        }
        return nil
    }

    /// The manual hazard rule for a command the user issued. A local plan has no confirmation chips
    /// of its own, so a high-risk device asks here before it changes (#143, #274 review). Low-risk
    /// devices pass through untouched, and any modal run re-checks sibling intents against the
    /// latest marks, device categories, and source contexts.
    private func hazardApprovedIntents(_ intents: [DeviceIntent]) -> [DeviceIntent] {
        let contextBeforeModal = controlContextID
        let generationBeforeModal = capabilityGeneration
        var capturedContexts: [String: ModalDeviceContext] = [:]
        var capturedSceneEntities: [String: String] = [:]
        var promptedProfiles: [Int: ManualControlHazardProfile] = [:]
        var approvedIndices: Set<Int> = []
        var rejectedIndices: Set<Int> = []
        var didPresentAnyModal = false

        var didPresentModalInPass = false
        repeat {
            didPresentModalInPass = false
            guard controlContextID == contextBeforeModal,
                  capabilityGeneration == generationBeforeModal else { return [] }
            if didPresentAnyModal, rejectControlWhileLocked() { return [] }
            for idx in intents.indices where !rejectedIndices.contains(idx) {
                let intent = intents[idx]
                if case .activateScene = intent.operation {
                    guard capabilitySceneControlRejectionMessage(forSceneIdOrName: intent.targetId) == nil,
                          let liveScene = scenes.first(where: { $0.id == intent.targetId }),
                          haCommandWriteRejection(for: liveScene.entityId) == nil else {
                        approvedIndices.remove(idx)
                        rejectedIndices.insert(idx)
                        continue
                    }
                    if capturedSceneEntities[liveScene.id] == nil {
                        capturedSceneEntities[liveScene.id] = liveScene.entityId
                    }
                    if capturedSceneEntities[liveScene.id] == liveScene.entityId {
                        approvedIndices.insert(idx)
                    } else {
                        approvedIndices.remove(idx)
                        rejectedIndices.insert(idx)
                    }
                    continue
                }
                guard capabilityWriteRejection(forDeviceId: intent.targetId) == nil,
                      let liveDevice = devices.first(where: { $0.id == intent.targetId }) else {
                    approvedIndices.remove(idx)
                    rejectedIndices.insert(idx)
                    continue
                }
                if capturedContexts[liveDevice.id] == nil {
                    capturedContexts[liveDevice.id] = captureModalDeviceContext(for: liveDevice)
                }
                guard let captured = capturedContexts[liveDevice.id],
                      matchesModalDeviceContext(captured) else {
                    approvedIndices.remove(idx)
                    rejectedIndices.insert(idx)
                    continue
                }
                let marks = SwitchLightMarks.load(defaults: userDefaults)
                let needsConfirm = ManualControlPolicy.requiresConfirmation(
                    intent.operation,
                    for: liveDevice,
                    markedLightIds: marks
                )
                if !needsConfirm {
                    approvedIndices.insert(idx)
                } else if let promptedProfile = promptedProfiles[idx] {
                    if ManualControlHazardProfile(liveDevice) != promptedProfile {
                        approvedIndices.remove(idx)
                        rejectedIndices.insert(idx)
                    }
                } else {
                    approvedIndices.remove(idx)
                    if rejectControlWhileLocked() { return [] }
                    let prePromptContext = captureModalDeviceContext(for: liveDevice)
                    promptedProfiles[idx] = prePromptContext.hazardProfile
                    didPresentModalInPass = true
                    didPresentAnyModal = true
                    if allowManualControl(intent.operation, for: liveDevice),
                       let postDevice = resolvePostModalDevice(prePromptContext),
                       !rejectChangedPostModalHazard(
                           intent.operation,
                           on: postDevice,
                           captured: prePromptContext,
                           didPresentModal: true
                       ) {
                        approvedIndices.insert(idx)
                    } else {
                        rejectedIndices.insert(idx)
                    }
                }
            }
        } while didPresentModalInPass

        guard controlContextID == contextBeforeModal,
              capabilityGeneration == generationBeforeModal else { return [] }
        if didPresentAnyModal, rejectControlWhileLocked() { return [] }
        return intents.enumerated().compactMap { idx, intent in
            guard approvedIndices.contains(idx), !rejectedIndices.contains(idx) else {
                return nil
            }
            if case .activateScene = intent.operation {
                guard capabilitySceneControlRejectionMessage(forSceneIdOrName: intent.targetId) == nil,
                      let liveScene = scenes.first(where: { $0.id == intent.targetId }),
                      haCommandWriteRejection(for: liveScene.entityId) == nil,
                      capturedSceneEntities[liveScene.id] == liveScene.entityId else {
                    return nil
                }
                return intent
            }
            guard let captured = capturedContexts[intent.targetId],
                  matchesModalDeviceContext(captured) else {
                return nil
            }
            return intent
        }
    }

    public func applyAssistantSuggestion(_ suggestion: AssistantSuggestion, offersUndoBanner: Bool = false) async {
        let contextBeforeModal = controlContextID
        assistantSuggestions.removeAll { $0.id == suggestion.id }
        if let capabilityMsg = firstPlanCapabilityRejectionMessage(for: suggestion.intents) {
            showToast(capabilityMsg, isError: true)
            setAssistantState(.failed(capabilityMsg))
            return
        }
        let intents = hazardApprovedIntents(suggestion.intents)
        if let capabilityMsg = firstPlanCapabilityRejectionMessage(for: suggestion.intents) {
            showToast(capabilityMsg, isError: true)
            setAssistantState(.failed(capabilityMsg))
            return
        }
        guard controlContextID == contextBeforeModal, !intents.isEmpty else {
            if isControlBlockedByScreenLock {
                setAssistantState(.failed(screenLockBlockedMessage))
            }
            return
        }
        let reply = IntentReply.describe(intents, devices: devices, scenes: scenes)
        let plan = IntentPlan(intents: intents, reply: reply, source: .model)
        if let delaySpec = suggestion.delaySpec {
            _ = schedule(plan, after: delaySpec.seconds)
            return
        }
        _ = await executeIntentPlan(plan, recordedUtterance: nil, origin: .userInitiated, offersUndoBanner: offersUndoBanner)
    }

    /// Resolves a natural-language command (local parser first, model fallback) and applies it.
    @discardableResult
    public func runAssistantCommand(_ text: String) async -> IntentPlan? {
        let companion = activeCompanionCommandGeneration
        if let companion, !companionCanExecute(generation: companion) { return nil }
        let controlContext = controlContextID
        // A disable, provider change or removal while this command runs must discard its late
        // model result before it can reach the write gate (P5a-M acceptance #3).
        let assistantGeneration = assistantEpoch
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        let startedAt = Date()
        if DelayPhrase.isCancel(spoken) {
            let count = cancelScheduledCommands()
            setAssistantState(
                count > 0
                    ? .done(L10n.tr("已取消 \(count) 个定时", "Cancelled \(count) timer(s)"))
                    : .failed(L10n.tr("现在没有定时任务", "No active timers"))
            )
            return nil
        }
        if UndoPhrase.isUndo(spoken) {
            await undoLastAssistantAction()
            return nil
        }
        let delayed = DelayPhrase.extract(spoken)
        let utterance = delayed?.remainder ?? spoken
        setAssistantState(.thinking)

        var plan: IntentPlan
        var habitSummary: String?
        if let local = LocalIntentParser.parse(
            utterance,
            devices: devices,
            scenes: scenes,
            panelRoom: panelRoom,
            usageOrder: userHabitMemory.usageOrder()
        ) {
            plan = local
        } else if homeBackend == .demo {
            // 演示模式完全离线（#47）：本地解析不了的指令绝不送云端。
            setAssistantState(.failed(L10n.tr(
                "演示模式只在本机解析。试试「打开客厅灯」「空调调到 26 度」这类说法",
                "Demo mode parses locally. Try phrases like \"Turn on the living room light\" or \"Set the AC to 26\""
            )))
            return nil
        } else {
            let config = assistantConfig
            // AI is off: zero requests, zero retries, no cloud-consent prompt. Local parsing,
            // habit phrases and saved timers were already handled above (P5a-M acceptance #1).
            guard aiAssistantEnabled else {
                setAssistantState(.failed(L10n.tr(
                    "AI 一句话控制已关闭，指令只在本机解析；可在设置中重新开启。",
                    "AI command control is off; commands are parsed on this Mac only. You can turn it back on in Settings."
                )))
                return nil
            }
            let localResolver = localCommandResolver(for: config)
            if localResolver == nil {
                if shouldRejectMissingAPIKey(for: config) {
                    setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
                    return nil
                }
                if let consent = cloudConsentNeeded(for: config, utterance: spoken, companionGeneration: companion) {
                    pendingCloudConsent = consent
                    setAssistantState(.idle)
                    return nil
                }
            }
            let resolver: any AssistantCommandResolving = localResolver ?? makeAssistantResolver(config: config, epoch: assistantGeneration)
            let context = buildAssistantContext(mention: .utterance(utterance))
            if !context.habitSummary.isEmpty {
                habitSummary = context.habitSummary
            }
            do {
                plan = try await resolver.resolve(
                    utterance,
                    devices: devices,
                    scenes: scenes,
                    context: context,
                    confirmation: aiConfirmationPolicy
                )
            } catch {
                guard controlContext == controlContextID else { return nil }
                // A superseded run stays quiet: the user already switched AI off or changed the
                // provider, and a stale failure would only describe a cancelled request.
                if isAssistantRunSuperseded(error, epoch: assistantGeneration) {
                    clearThinkingAssistantState()
                    return nil
                }
                setAssistantState(.failed(AssistantError.userMessage(for: error)))
                return nil
            }
            guard assistantGeneration == assistantEpoch, aiAssistantEnabled else {
                clearThinkingAssistantState()
                return nil
            }
            // A companion command disconnected while the model was answering must not act.
            if let companion, !companionCanExecute(generation: companion) {
                clearThinkingAssistantState()
                return nil
            }
        }
        guard controlContext == controlContextID else { return nil }
        if !plan.intents.isEmpty {
            let originalIntents = plan.intents
            if let capabilityMsg = firstPlanCapabilityRejectionMessage(for: originalIntents) {
                let blocked = IntentPlan(
                    intents: [],
                    reply: capabilityMsg,
                    source: plan.source
                )
                showToast(capabilityMsg, isError: true)
                setAssistantState(.failed(capabilityMsg))
                return blocked
            }
            let approved = hazardApprovedIntents(originalIntents)
            guard controlContext == controlContextID else { return nil }
            if let capabilityMsg = firstPlanCapabilityRejectionMessage(for: originalIntents) {
                let blocked = IntentPlan(
                    intents: [],
                    reply: capabilityMsg,
                    source: plan.source
                )
                showToast(capabilityMsg, isError: true)
                setAssistantState(.failed(capabilityMsg))
                return blocked
            }
            guard !approved.isEmpty else {
                if isControlBlockedByScreenLock {
                    let blocked = IntentPlan(
                        intents: [],
                        reply: screenLockBlockedMessage,
                        source: plan.source
                    )
                    setAssistantState(.failed(blocked.reply))
                    return blocked
                }
                let cancelled = IntentPlan(
                    intents: [],
                    reply: L10n.tr("已取消", "Cancelled"),
                    source: plan.source
                )
                setAssistantState(.done(cancelled.reply))
                return cancelled
            }
            if approved.count != plan.intents.count {
                plan = IntentPlan(
                    intents: approved,
                    reply: IntentReply.describe(approved, devices: devices, scenes: scenes),
                    source: plan.source,
                    suggestions: plan.suggestions
                )
            }
        }
        guard !plan.intents.isEmpty else {
            let isBareLocalChoice = plan.source == .local
                && (plan.suggestions.isEmpty || plan.suggestions.allSatisfy { $0.baseId.hasPrefix("bare:") })
            if delayed != nil, isBareLocalChoice {
                // A timer never fires an unresolved choice; ask for the room or device now.
                assistantSuggestions = localTopSuggestions()
                setAssistantState(.done(plan.reply.isEmpty
                    ? L10n.tr("没有找到可执行的设备操作", "No matching device actions found")
                    : plan.reply))
                return plan
            }
            if !plan.suggestions.isEmpty {
                if let delayed {
                    let delaySpec = SuggestionDelaySpec(seconds: delayed.delay)
                    plan.suggestions = plan.suggestions.map { $0.withDelay(delaySpec) }
                }
                assistantSuggestions = plan.suggestions
                setAssistantState(.awaitingChoice(plan.reply.isEmpty
                    ? ModelActionPolicy.confirmationReply(ranReply: nil)
                    : plan.reply))
                return plan
            }
            if plan.source == .local, !plan.reply.isEmpty {
                assistantSuggestions = localTopSuggestions()
                setAssistantState(.done(plan.reply))
                return plan
            }
            setAssistantState(.failed(plan.reply.isEmpty ? L10n.tr("没有找到可执行的设备操作", "No matching device actions found") : plan.reply))
            return plan
        }

        if let delayed {
            if !plan.suggestions.isEmpty {
                let delaySpec = SuggestionDelaySpec(seconds: delayed.delay)
                plan.suggestions = plan.suggestions.map { $0.withDelay(delaySpec) }
            }
            var timerPlan = plan
            timerPlan.suggestions = []
            var scheduled = schedule(timerPlan, after: delayed.delay)
            if case .failed = assistantState {
                return scheduled
            }
            if !plan.suggestions.isEmpty {
                assistantSuggestions = plan.suggestions
            }
            scheduled.suggestions = plan.suggestions
            return scheduled
        }
        // A locally parsed command is the user's explicit ask. A model plan is the AI filling in
        // devices/actions the user never spelled out, so it does not train habits (#34).
        let origin: AssistantExecutionOrigin = plan.source == .local ? .userInitiated : .aiAutomatic
        return await executeIntentPlan(
            plan,
            recordedUtterance: utterance,
            origin: origin,
            receiptStartedAt: startedAt,
            usedHabitContext: habitSummary != nil,
            habitSummary: habitSummary
        )
    }

    // MARK: - Voice Undo

    /// Restores only the devices the last assistant action touched; others may have changed since.
    private func undoLastAssistantAction() async {
        guard let last = lastAssistantUndo, Date().timeIntervalSince(last.at) <= Self.voiceUndoWindow else {
            lastAssistantUndo = nil
            setAssistantState(.failed(L10n.tr("没有可以撤销的操作", "Nothing to undo")))
            return
        }
        // A locked Mac refuses the restore itself, not just the command that made the change: the
        // entry stays recorded so the same 撤销 works after unlocking (#143).
        if rejectControlWhileLocked() {
            setAssistantState(.failed(screenLockBlockedMessage))
            return
        }
        let prePartition = partitionUndoCommandsByCapability(
            last.restore,
            previousDevices: last.previous
        )
        if !last.restore.isEmpty,
           prePartition.eligibleCommands.isEmpty,
           let firstBlocked = prePartition.firstBlockedReason {
            let msg = firstBlocked.userMessage
            showToast(msg, isError: true)
            setAssistantState(.failed(msg))
            return
        }
        let hasLGRestore = prePartition.eligibleCommands.contains { lgClientServes($0) }
        let hasMiRestore = prePartition.eligibleCommands.contains { !lgClientServes($0) }
        if hasMiRestore, !hasLGRestore, rejectWritesBlockedByMiSession() {
            setAssistantState(.failed(Self.miSessionBlockedMessage))
            return
        }
        let contextBeforeModal = controlContextID
        let confirmation = confirmUndoTargets(prePartition.eligibleCommands, previousDevices: last.previous)
        if confirmation.abortUndo {
            setAssistantState(.failed(L10n.tr("已取消高风险操作", "High-risk action cancelled.")))
            return
        }
        guard controlContextID == contextBeforeModal,
              lastAssistantUndo?.actionId == last.actionId else {
            return
        }
        let postPartition = partitionUndoCommandsByCapability(
            last.restore,
            previousDevices: last.previous,
            excludingDeviceIds: confirmation.excludedDeviceIds
        )
        if !last.restore.isEmpty,
           postPartition.eligibleCommands.isEmpty,
           let firstBlocked = postPartition.firstBlockedReason {
            let msg = firstBlocked.userMessage
            showToast(msg, isError: true)
            setAssistantState(.failed(msg))
            return
        }
        if rejectControlWhileLocked() {
            setAssistantState(.failed(screenLockBlockedMessage))
            return
        }
        let postHasLG = postPartition.eligibleCommands.contains { lgClientServes($0) }
        let postHasMi = postPartition.eligibleCommands.contains { !lgClientServes($0) }
        if postHasMi, !postHasLG, rejectWritesBlockedByMiSession() {
            setAssistantState(.failed(Self.miSessionBlockedMessage))
            return
        }
        let savedBanner = undoBanner?.actionId == last.actionId ? undoBanner : nil
        lastAssistantUndo = nil
        if savedBanner != nil {
            undoTimerTask?.cancel()
            undoBanner = nil
        }
        let capturedAssistantRevision = assistantUndoRevision
        let capturedBannerRevision = bannerUndoRevision
        let preUndoById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let preUndoFacetsById = deviceFacets
        let applicable = applyUndoCommands(
            postPartition.eligibleCommands,
            previousDevices: last.previous,
            excludingDeviceIds: confirmation.excludedDeviceIds
        )
        if applicable.isEmpty, !last.restore.isEmpty {
            if !postPartition.blockedCommands.isEmpty, let firstReason = postPartition.firstBlockedReason {
                let blockedCount = max(postPartition.blockedDeviceIds.count, postPartition.blockedCommands.count)
                let remainingReceipt = last.habitReceipt.flatMap {
                    Self.partitionHabitReceipt($0, failedDeviceIds: postPartition.blockedDeviceIds).remaining
                }
                lastAssistantUndo = AssistantUndoEntry(
                    actionId: last.actionId,
                    reply: last.reply,
                    restore: postPartition.blockedCommands,
                    previous: last.previous.filter { postPartition.blockedDeviceIds.contains($0.id) },
                    at: assistantNow(),
                    habitReceipt: remainingReceipt
                )
                if let savedBanner {
                    scheduleUndoBanner(
                        actionId: savedBanner.actionId,
                        title: savedBanner.title,
                        restoreCommands: postPartition.blockedCommands,
                        previousDevices: savedBanner.previousDevices.filter { postPartition.blockedDeviceIds.contains($0.id) },
                        deviceCount: blockedCount,
                        habitReceipt: remainingReceipt,
                        duration: savedBanner.duration,
                        isAllOff: savedBanner.isAllOff
                    )
                }
                let msg = partialCapabilityUndoMessage(blockedCount: blockedCount, reason: firstReason)
                showToast(msg, isError: true)
                setAssistantState(.failed(msg))
                return
            }
            setAssistantState(.failed(L10n.tr("设备状态已变化，无法撤销", "Device state changed; cannot undo")))
            return
        }
        let context = controlContextID
        guard let outcome = await runUndoCommands(
            applicable,
            context: context,
            preUndoById: preUndoById,
            preUndoFacetsById: preUndoFacetsById,
            habitReceipt: last.habitReceipt,
            preBlockedDeviceIds: postPartition.blockedDeviceIds
        ) else { return }
        let remainingCommands = outcome.failedCommands + postPartition.blockedCommands
        let remainingDeviceIds = outcome.failedDeviceIds.union(postPartition.blockedDeviceIds)
        if remainingCommands.isEmpty {
            let what = last.reply.hasPrefix("已") ? String(last.reply.dropFirst()) : last.reply
            setAssistantState(.done(L10n.tr("已撤销：\(what)", "Undone: \(what)")))
            return
        }
        let remainingCount = max(remainingDeviceIds.count, remainingCommands.count)
        let lockedBeforeAnySend = outcome.blockedByScreenLock && !outcome.didSendAnyCommand
        if assistantUndoRevision == capturedAssistantRevision {
            if lockedBeforeAnySend {
                lastAssistantUndo = last
            } else {
                lastAssistantUndo = AssistantUndoEntry(
                    actionId: last.actionId,
                    reply: last.reply,
                    restore: remainingCommands,
                    previous: last.previous.filter { remainingDeviceIds.contains($0.id) },
                    at: assistantNow(),
                    habitReceipt: outcome.habitReceipt
                )
            }
        }
        if let savedBanner, bannerUndoRevision == capturedBannerRevision {
            if lockedBeforeAnySend {
                scheduleUndoBanner(
                    actionId: savedBanner.actionId,
                    title: savedBanner.title,
                    restoreCommands: savedBanner.restoreCommands,
                    previousDevices: savedBanner.previousDevices,
                    deviceCount: savedBanner.deviceCount,
                    habitReceipt: savedBanner.habitReceipt,
                    duration: savedBanner.duration,
                    isAllOff: savedBanner.isAllOff,
                    attemptedDeviceIds: savedBanner.attemptedDeviceIds
                )
            } else {
                scheduleUndoBanner(
                    actionId: savedBanner.actionId,
                    title: savedBanner.title,
                    restoreCommands: remainingCommands,
                    previousDevices: savedBanner.previousDevices.filter { remainingDeviceIds.contains($0.id) },
                    deviceCount: remainingCount,
                    habitReceipt: outcome.habitReceipt,
                    duration: savedBanner.duration,
                    isAllOff: savedBanner.isAllOff
                )
            }
        }
        if outcome.blockedByScreenLock {
            setAssistantState(.failed(screenLockBlockedMessage))
            return
        }
        let capabilityBlockedReason = postPartition.firstBlockedReason ?? outcome.capabilityBlockedReason
        if outcome.failedCommands.isEmpty, let reason = capabilityBlockedReason {
            let msg = partialCapabilityUndoMessage(blockedCount: remainingCount, reason: reason)
            showToast(msg, isError: true)
            setAssistantState(.failed(msg))
            return
        }
        if let reason = outcome.capabilityBlockedReason, outcome.nonCapabilityFailedNames.isEmpty {
            let msg = partialCapabilityUndoMessage(blockedCount: remainingCount, reason: reason)
            showToast(msg, isError: true)
            setAssistantState(.failed(msg))
            return
        }
        let sep = L10n.isEnglish ? ", " : "、"
        let list = outcome.failedNames.joined(separator: sep)
        setAssistantState(.failed(L10n.tr("撤销未完成：\(list) 未响应，可再次撤销重试", "Undo incomplete: \(list) did not respond; retry undo")))
    }

    // MARK: - Scheduled Commands

    private func schedule(_ plan: IntentPlan, after delay: TimeInterval) -> IntentPlan {
        guard scheduledCommandsEnabled else {
            let message = L10n.tr("定时任务已关闭，开启后才能新建定时", "Scheduled commands are off. Turn them back on to create a timer.")
            showToast(message, isError: true)
            setAssistantState(.failed(message))
            return plan
        }
        let scopes = activeConnectionScopes
        // A timer made against the previous source's device list would be stamped with the new
        // sources; wait for one snapshot after `startListening()` before offering to schedule. LG rows
        // come from the LAN client, so an all-LG plan is current even without a cloud snapshot.
        let needsCloudSnapshot = !planHasOnlyLGTargets(plan)
        guard !scopes.isEmpty,
              !needsCloudSnapshot || snapshotGeneration != listeningSnapshotGeneration else {
            let message = L10n.tr(
                "数据源尚未就绪，定时任务未创建",
                "The home source is not ready; the timer was not created"
            )
            showToast(message, isError: true)
            setAssistantState(.failed(message))
            return plan
        }
        var action = IntentReply.describe(plan.intents, devices: devices, scenes: scenes)
        if action.hasPrefix("已") { action.removeFirst() }
        let entry = ScheduledCommand(
            reply: DelayPhrase.describe(delay) + action,
            fireDate: assistantNow().addingTimeInterval(delay),
            plan: plan,
            sourceScope: connectionScopeIdentifier,
            sourceScopes: scopes.sorted()
        )
        guard commitScheduledCommands(waiting: scheduledCommands + [entry]) else { return plan }
        startScheduledTask(for: entry, delay: delay)
        var reply = plan
        reply.reply = L10n.tr("好的，", "Scheduled — ") + entry.reply
        setAssistantState(.done(reply.reply))
        return reply
    }

    /// True when the rows on screen were produced by the connected sources. `startListening()` marks
    /// the generation at the switch and only the next snapshot advances it, so the list left over from
    /// the previous home is exactly the equality `schedule()` refuses. LG rows come from the LAN client,
    /// so an all-LG plan is current without a cloud snapshot.
    private func rowsBelongToConnectedSources(for plan: IntentPlan) -> Bool {
        planHasOnlyLGTargets(plan) || snapshotGeneration != listeningSnapshotGeneration
    }

    /// True when every target is a local LG card. Those rows come from the LAN client rather than a
    /// cloud snapshot, so a stale `snapshotGeneration` says nothing about their freshness.
    private func planHasOnlyLGTargets(_ plan: IntentPlan) -> Bool {
        !plan.intents.isEmpty && plan.intents.allSatisfy { intent in
            guard let device = devices.first(where: { $0.id == intent.targetId }),
                  case .tv(let spec) = device.kind else { return false }
            return LGWebOSProtocol.isLGEntity(spec.mediaEntityId)
        }
    }

    public var scheduledCommandsAffectedByDisable: [ScheduledCommand] {
        scheduledCommands + missedScheduledCommands + foreignScheduledCommands
    }

    public var visiblePausedScheduledCommands: [PausedScheduledCommand] {
        pausedScheduledCommands.filter { paused in
            if !paused.requiresTimerRevalidation || !paused.pausedCapabilities.isEmpty || !paused.pausedScopes.isEmpty {
                return true
            }
            let cmd = paused.command
            return timerScopeMatches(cmd) || (cmd.effectiveSourceScopes == nil && connectionScopeIdentifier != nil)
        }
    }

    @discardableResult
    public func setScheduledCommandsEnabled(_ enabled: Bool, confirming entries: [ScheduledCommand] = []) -> Bool {
        guard enabled != scheduledCommandsEnabled else { return true }
        if enabled { return revalidatePausedTimers(enabling: true) }
        guard entries == scheduledCommandsAffectedByDisable else { return false }

        var paused = pausedScheduledCommands
        for (queue, partition) in [(scheduledCommands, TimerPartition.waiting),
                                   (missedScheduledCommands, .missed), (foreignScheduledCommands, .foreign)] {
            paused += queue.map { PausedScheduledCommand(command: $0, originalPartition: partition, pausedCapabilities: []) }
        }
        for index in paused.indices { paused[index].requiresTimerRevalidation = true }
        guard commitScheduledCommands(waiting: [], missed: [], foreign: [], paused: paused, enabled: false) else {
            return false
        }
        for entry in entries { disarmScheduledCommand(entry.id) }
        return true
    }

    @discardableResult
    func commitScheduledCommands(
        waiting: [ScheduledCommand]? = nil, missed: [ScheduledCommand]? = nil,
        foreign: [ScheduledCommand]? = nil, paused: [PausedScheduledCommand]? = nil, enabled: Bool? = nil
    ) -> Bool {
        let waiting = waiting ?? scheduledCommands
        let missed = missed ?? missedScheduledCommands
        let foreign = foreign ?? foreignScheduledCommands
        let paused = paused ?? pausedScheduledCommands
        let enabled = enabled ?? scheduledCommandsEnabled
        let state = ScheduledCommandState(enabled: enabled, active: waiting + missed + foreign, paused: paused)
        guard state.save(to: userDefaults) else {
            let message = if !enabled && scheduledCommandsEnabled {
                L10n.tr("无法保存暂停的定时，定时任务仍处于开启状态", "Could not save the paused timers, so scheduled commands stay on.")
            } else {
                L10n.tr("定时指令无法保存，请重试", "Could not save scheduled commands. Please try again.")
            }
            showToast(message, isError: true)
            return false
        }
        if scheduledCommandsEnabled != enabled {
            scheduledCommandsGeneration &+= 1
            scheduledCommandsEnabled = enabled
        }
        scheduledCommands = waiting.sorted { $0.fireDate < $1.fireDate }
        missedScheduledCommands = missed.sorted { $0.fireDate < $1.fireDate }
        foreignScheduledCommands = foreign.sorted { $0.fireDate < $1.fireDate }
        pausedScheduledCommands = paused
        return true
    }

    func disarmScheduledCommand(_ id: UUID) {
        scheduledTasks.removeValue(forKey: id)?.cancel()
        scheduledTaskTokens.removeValue(forKey: id)
        notifiedMissedTimerIds.remove(id)
    }

    private func scheduledCommandsCanWrite(generation: UInt64) -> Bool {
        scheduledCommandsEnabled && scheduledCommandsGeneration == generation
    }

    private var scheduledCommandsOffMessage: String {
        L10n.tr("定时任务已关闭，开启后才能执行这条定时", "Scheduled commands are off. Turn them back on to run this timer.")
    }

    func timerPlanCanResume(_ plan: IntentPlan) -> Bool {
        guard rowsBelongToConnectedSources(for: plan),
              planHasOnlyLGTargets(plan) || (hasReceivedInitialSnapshot && !deviceValuesAreStale) else { return false }
        return plan.intents.allSatisfy { intent in
            if intent.operation == .activateScene {
                return sourceStatuses[.homeAssistant]?.isConnected != false
                    && scenes.contains { $0.id == intent.targetId }
                    && evaluateSceneControlGate(sceneId: intent.targetId).allowed
            }
            guard let device = devices.first(where: { $0.id == intent.targetId }),
                  device.isOnline, capabilityWriteRejection(for: device) == nil,
                  IntentDeviceCategory(device).isAssistantControllable else { return false }
            let (connection, scope) = inferSource(for: device)
            guard !pendingRevalidationScopes.contains(scope) else { return false }
            if connection == .homeAssistant, sourceStatuses[.homeAssistant]?.isConnected == false { return false }
            if connection == .xiaomiCloud,
               (miAccountStatuses[scope] ?? sourceStatuses[.xiaomiCloud])?.isConnected == false { return false }
            return Self.assistantEffect(of: intent.operation, on: device) != nil
        }
    }

    /// Re-partitions timers after the connected sources changed. Called from `startListening()`, where
    /// the new provider is already in place; re-arming from persisted data is the existing restore path.
    func syncScheduledCommandScopeIfNeeded() {
        guard scheduledCommandsScope != activeConnectionScopes else { return }
        restoreScheduledCommands()
    }

    func startScheduledTask(for entry: ScheduledCommand, delay: TimeInterval) {
        guard scheduledCommandsEnabled else { return }
        let generation = scheduledCommandsGeneration
        scheduledTasks[entry.id]?.cancel()
        let sleep = assistantSleep
        let waitSeconds = max(0, delay)
        // Identifies this run so a task re-armed for the same entry (source A → B → A) keeps its handle.
        let token = UUID()
        scheduledTaskTokens[entry.id] = token
        scheduledTasks[entry.id] = Task { [weak self] in
            defer {
                if let self {
                    self.scheduledTaskExits &+= 1
                }
            }
            do { try await sleep(.seconds(waitSeconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // A source switch while this timer slept re-partitions the lists elsewhere; the timer must
            // not run against whatever home happens to be connected now.
            guard self.scheduledCommandsCanWrite(generation: generation), self.timerScopeMatches(entry) else {
                self.finishScheduledTask(entry.id, token: token)
                return
            }
            // Task.sleep keeps counting while the Mac sleeps, so after a closed lid it returns the moment
            // the Mac wakes. A timer that is more than a minute late is not run silently (#22).
            if self.assistantNow().timeIntervalSince(entry.fireDate) > Self.lateTimerGrace {
                self.moveToMissed(entry, taskToken: token)
                return
            }
            await self.waitForInitialSnapshotIfNeeded()
            guard !Task.isCancelled else {
                self.finishScheduledTask(entry.id, token: token)
                return
            }
            guard self.scheduledCommandsCanWrite(generation: generation), self.timerScopeMatches(entry) else {
                self.finishScheduledTask(entry.id, token: token)
                return
            }
            // Selecting another Mi Home keeps the connection scope but swaps the device list; a target
            // that is no longer here must wait for confirmation instead of running into nothing.
            guard self.missingPlanTargets(entry.plan).isEmpty else {
                self.moveToMissed(entry, taskToken: token)
                return
            }
            // Consume before sending. A switch while the request is in flight re-partitions from disk,
            // and an entry still there would be armed or moved to missed again and could run twice.
            // Losing a timer to a crash mid-execution is the safer failure for hardware.
            self.finishScheduledTask(entry.id, token: token)
            guard self.commitScheduledCommands(waiting: self.scheduledCommands.filter { $0.id != entry.id }) else { return }
            _ = await self.executeIntentPlan(
                entry.plan, recordedUtterance: nil, origin: .scheduled, timerGeneration: generation
            )
        }
    }

    func timerScopeMatches(_ entry: ScheduledCommand) -> Bool {
        // A plan whose targets are all LG LAN cards never depends on a cloud scope (ADR-0023).
        if timerTargetsAreAllLGLan(entry.plan) { return true }
        guard let scopes = entry.effectiveSourceScopes else { return false }
        return Self.sourceScopesMatch(scopes, active: activeConnectionScopes)
    }

    /// True when a timer's captured sources still overlap the connected ones. Matching entries are
    /// armed or shown; the caller decides what a mismatch means.
    static func sourceScopesMatch(_ stamped: [String], active: Set<String>) -> Bool {
        guard stamped.contains(where: active.contains) else { return false }
        // Timer targets are merged card ids that an HA absent at creation can already claim, so every
        // HA connected now must be one this timer saw when it was created.
        return active.filter { $0.hasPrefix("ha:") }.allSatisfy(stamped.contains)
    }

    /// Plan targets that are in neither the current device list nor the current scenes. A plan with no
    /// device targets (empty intents) has none, so it is never misrouted into the missed flow.
    private func missingPlanTargets(_ plan: IntentPlan) -> [String] {
        plan.intents.compactMap { intent in
            if devices.contains(where: { $0.id == intent.targetId }) { return nil }
            if scenes.contains(where: { $0.id == intent.targetId }) { return nil }
            return intent.targetId
        }
    }

    /// Clears the task handle only when it still belongs to the run that just finished.
    private func finishScheduledTask(_ id: UUID, token: UUID) {
        guard scheduledTaskTokens[id] == token else { return }
        scheduledTasks[id] = nil
        scheduledTaskTokens[id] = nil
    }

    private func moveToMissed(_ entry: ScheduledCommand, taskToken: UUID) {
        finishScheduledTask(entry.id, token: taskToken)
        guard commitScheduledCommands(
            waiting: scheduledCommands.filter { $0.id != entry.id },
            missed: missedScheduledCommands + [entry]
        ) else { return }
        notifyMissedScheduledCommandsIfNeeded()
    }

    private func waitForInitialSnapshotIfNeeded() async {
        guard devices.isEmpty, scenes.isEmpty, !Task.isCancelled else { return }
        initialSnapshotWaiters += 1
        defer { initialSnapshotWaiters -= 1 }
        for _ in 0..<50 where devices.isEmpty && scenes.isEmpty && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Restores persisted timers on launch. Future timers resume their countdown; expired timers move to
    /// `missedScheduledCommands` so an overdue heater or light timer never fires silently hours later.
    /// Timers the Mac sleeps through take the same path when they wake up late (see `startScheduledTask`).
    /// Only timers whose captured sources still match the connected ones are armed or shown; the other
    /// sources' entries stay persisted (ADR-0019). Legacy entries with no scope never arm against the
    /// connected home: with a primary source known they wait visibly in the missed list until the user
    /// confirms them, and stay parked on disk while no source is known (#22).
    public func restoreScheduledCommands(now: Date? = nil) {
        for task in scheduledTasks.values {
            task.cancel()
        }
        scheduledTasks.removeAll()
        scheduledTaskTokens.removeAll()
        let now = now ?? assistantNow()

        let scopes = activeConnectionScopes
        scheduledCommandsScope = scopes
        let primaryScope = connectionScopeIdentifier

        guard let state = ScheduledCommandState.load(from: userDefaults) else {
            scheduledCommands = []
            missedScheduledCommands = []
            foreignScheduledCommands = []
            return
        }
        scheduledCommandsEnabled = state.enabled
        pausedScheduledCommands = state.paused

        var upcoming: [ScheduledCommand] = []
        var missed: [ScheduledCommand] = []
        var foreign: [ScheduledCommand] = []
        for stored in state.enabled ? state.active : [] {
            if stored.effectiveSourceScopes == nil {
                // No recorded scope means the creating home is unknown. Adopting it to whichever
                // source happens to be connected could fire it in a home it never belonged to, so
                // it only becomes visible — never armed, never announced as missed — until the user
                // confirms it (`confirmScheduledCommandSource`) or, once due, runs it (#22).
                if primaryScope != nil {
                    missed.append(stored)
                } else {
                    foreign.append(stored)
                }
                continue
            }
            let entry = stored
            // Disabling the last Mi account empties the active scope set, but a timer that only
            // targets LG LAN cards is still driven locally and must stay armed (ADR-0023).
            let lgOnly = timerTargetsAreAllLGLan(entry.plan)
            guard lgOnly || (entry.effectiveSourceScopes.map { Self.sourceScopesMatch($0, active: scopes) } ?? false) else {
                foreign.append(entry)
                continue
            }
            if entry.fireDate > now {
                upcoming.append(entry)
            } else {
                missed.append(entry)
            }
        }

        scheduledCommands = upcoming.sorted { $0.fireDate < $1.fireDate }
        for entry in scheduledCommands {
            startScheduledTask(for: entry, delay: entry.fireDate.timeIntervalSince(now))
        }

        missedScheduledCommands = missed.sorted { $0.fireDate < $1.fireDate }
        foreignScheduledCommands = foreign.sorted { $0.fireDate < $1.fireDate }

        if !missedScheduledCommands.isEmpty {
            notifyMissedScheduledCommandsIfNeeded()
        }
    }

    public func notifyMissedScheduledCommandsIfNeeded() {
        guard let handler = onMissedScheduledCommand else { return }
        // A legacy entry with no recorded source is not a missed timer of this home: it may not be
        // due yet and nobody has confirmed its owner, so the "missed while closed" banner and its
        // Run Now action are not offered for it. The panel activity stack shows it as 来源待确认 (#22).
        for entry in missedScheduledCommands
        where entry.effectiveSourceScopes != nil && !notifiedMissedTimerIds.contains(entry.id) {
            notifiedMissedTimerIds.insert(entry.id)
            handler(entry)
        }
    }

    @discardableResult
    public func runMissedScheduledCommand(id: UUID) async -> IntentPlan? {
        // 立即补执行 is a person acting now, so the lock-screen preference applies (#143). Checked
        // before anything else: a refused run stays in the list and can be retried after unlocking.
        if rejectControlWhileLocked() { return nil }
        guard scheduledCommandsEnabled else {
            showToast(scheduledCommandsOffMessage, isError: true)
            return nil
        }
        let generation = scheduledCommandsGeneration
        guard let entry = missedScheduledCommands.first(where: { $0.id == id }) else { return nil }
        // Same exemption as the armed path: a plan targeting only LG LAN cards is driven locally, so
        // an unrelated cloud scope being off must not block "Run Now" either (ADR-0023).
        // An unscoped legacy entry has no owner to match: the tap confirms that the home on screen
        // owns it (#22), so the run is bound to that home once due.
        let lgOnly = timerTargetsAreAllLGLan(entry.plan)
        let entryScopes = entry.effectiveSourceScopes
        let tappedOwner: LegacyTimerOwner?
        if let entryScopes {
            guard lgOnly || Self.sourceScopesMatch(entryScopes, active: activeConnectionScopes) else { return nil }
            tappedOwner = nil
        } else {
            guard entry.fireDate <= assistantNow(), let owner = currentLegacyTimerOwner() else { return nil }
            tappedOwner = owner
        }
        await waitForInitialSnapshotIfNeeded()
        // A switch or a lock can land while we wait for the snapshot. Re-check before consuming the
        // entry: it is removed and persisted only once the run is actually going ahead.
        if rejectControlWhileLocked() { return nil }
        guard scheduledCommandsCanWrite(generation: generation) else { return nil }
        if let entryScopes {
            guard lgOnly || Self.sourceScopesMatch(entryScopes, active: activeConnectionScopes) else { return nil }
        } else {
            guard currentLegacyTimerOwner() == tappedOwner else { return nil }
            // The previous home's rows are still on screen right after a switch; running against them
            // would check the targets in one home and send to the other (#22).
            guard rowsBelongToConnectedSources(for: entry.plan) else {
                showToast(
                    L10n.tr(
                        "数据源尚未就绪，定时未执行",
                        "The home source is not ready; the timer did not run"
                    ),
                    isError: true
                )
                return nil
            }
        }
        guard missingPlanTargets(entry.plan).isEmpty else {
            showToast(
                L10n.tr(
                    "定时的目标设备不在当前家庭，未执行",
                    "The timer's devices are not in the current home; it did not run"
                ),
                isError: true
            )
            return nil
        }
        // The user may have dismissed or cancelled it during the wait, and a second tap may already
        // have taken it. Existence check, removal and persistence run in one stretch without an await
        // so exactly one waiter can win.
        guard let current = missedScheduledCommands.first(where: { $0.id == id }) else { return nil }
        guard commitScheduledCommands(missed: missedScheduledCommands.filter { $0.id != id }) else { return nil }
        notifiedMissedTimerIds.remove(id)
        return await executeIntentPlan(
            current.plan, recordedUtterance: nil, origin: .scheduled, timerGeneration: generation
        )
    }

    public func dismissMissedScheduledCommand(id: UUID) {
        if commitScheduledCommands(missed: missedScheduledCommands.filter { $0.id != id }) {
            notifiedMissedTimerIds.remove(id)
        }
    }

    /// 确认 on a legacy timer saved before scopes existed (#22). It stamps the timer with the sources
    /// on screen at the tap, and from then on the ADR-0019 rules apply: a timer still ahead arms for
    /// its own time, and one that fell due meanwhile becomes an ordinary missed timer that still needs
    /// 立即补执行. Confirming never sends a command. Returns false and keeps the entry unconfirmed when
    /// the source or home changed during the snapshot wait, when the device rows still come from the
    /// previous home, or when the plan's devices are not here.
    @discardableResult
    public func confirmScheduledCommandSource(id: UUID) async -> Bool {
        guard scheduledCommandsEnabled else {
            showToast(scheduledCommandsOffMessage, isError: true)
            return false
        }
        let generation = scheduledCommandsGeneration
        guard let entry = missedScheduledCommands.first(where: { $0.id == id }),
              entry.effectiveSourceScopes == nil,
              let tappedOwner = currentLegacyTimerOwner() else { return false }
        await waitForInitialSnapshotIfNeeded()
        guard scheduledCommandsCanWrite(generation: generation),
              currentLegacyTimerOwner() == tappedOwner else { return false }
        // Confirming stamps the newly connected sources; it must not do that while the device rows
        // still come from the previous home (#22).
        guard rowsBelongToConnectedSources(for: entry.plan) else {
            showToast(
                L10n.tr(
                    "数据源尚未就绪，定时未确认",
                    "The home source is not ready; the timer was not confirmed"
                ),
                isError: true
            )
            return false
        }
        guard missingPlanTargets(entry.plan).isEmpty else {
            showToast(
                L10n.tr(
                    "定时的目标设备不在当前家庭，未确认",
                    "The timer's devices are not in the current home; it was not confirmed"
                ),
                isError: true
            )
            return false
        }
        // Same single stretch as 立即补执行: a dismiss or a second tap during the wait wins cleanly.
        guard let current = missedScheduledCommands.first(where: { $0.id == id }),
              current.effectiveSourceScopes == nil else { return false }
        let confirmed = ScheduledCommand(
            id: current.id,
            reply: current.reply,
            fireDate: current.fireDate,
            plan: current.plan,
            sourceScope: connectionScopeIdentifier,
            sourceScopes: tappedOwner.scopes.sorted()
        )
        let remaining = missedScheduledCommands.filter { $0.id != id }
        let now = assistantNow()
        if confirmed.fireDate > now {
            guard commitScheduledCommands(waiting: scheduledCommands + [confirmed], missed: remaining) else { return false }
            notifiedMissedTimerIds.remove(id)
            startScheduledTask(for: confirmed, delay: confirmed.fireDate.timeIntervalSince(now))
        } else {
            guard commitScheduledCommands(missed: remaining + [confirmed]) else { return false }
            notifiedMissedTimerIds.insert(id)
        }
        return true
    }

    /// What a tap on a legacy (unscoped) timer vouches for: the sources connected and the home on
    /// screen at that moment. Selecting another Mi Home keeps the scopes but resets the control
    /// context, so both are compared after the snapshot wait (#22).
    private struct LegacyTimerOwner: Equatable {
        let scopes: Set<String>
        let controlContext: UUID
    }

    private func currentLegacyTimerOwner() -> LegacyTimerOwner? {
        let scopes = activeConnectionScopes
        guard !scopes.isEmpty, connectionScopeIdentifier != nil else { return nil }
        return LegacyTimerOwner(scopes: scopes, controlContext: controlContextID)
    }

    /// Cancels one pending command, or all of them when `id` is nil. Returns how many were cancelled.
    /// Paused timers count too: they are shown in the bar and "cancel every timer" has to include them.
    @discardableResult
    public func cancelScheduledCommands(id: UUID? = nil) -> Int {
        func matches(_ entry: ScheduledCommand) -> Bool { id == nil || entry.id == id }
        let targets = (scheduledCommands + missedScheduledCommands).filter(matches)
        let pausedTargets = Set(visiblePausedScheduledCommands.filter { matches($0.command) }.map(\.command.id))
        let count = targets.count + pausedTargets.count
        guard count > 0, commitScheduledCommands(
            waiting: scheduledCommands.filter { !matches($0) },
            missed: missedScheduledCommands.filter { !matches($0) },
            paused: pausedScheduledCommands.filter { !pausedTargets.contains($0.command.id) }
        ) else { return 0 }
        for entry in targets { disarmScheduledCommand(entry.id) }
        return count
    }

    /// Where an executed plan came from; only explicit user actions train habits (#34).
    enum AssistantExecutionOrigin: Equatable, Sendable {
        /// Local plan from a typed/spoken command, or a suggestion the user tapped.
        case userInitiated
        /// The model inferred device actions the user did not spell out.
        case aiAutomatic
        /// A scheduled command fired (including a missed timer the user confirmed).
        case scheduled
        /// A Mac-state automation rule fired (lock, sleep, display change); never trains habits (#59).
        case automation

        var recordsHabits: Bool { self == .userInitiated }

        /// A direct or AI-assisted command is still a person acting now; scheduled and automation
        /// rules are what the lock-screen preference deliberately lets through (#143).
        var blocksWhileScreenLocked: Bool {
            switch self {
            case .userInitiated, .aiAutomatic: return true
            case .scheduled, .automation: return false
            }
        }
    }

    func executeIntentPlan(
        _ plan: IntentPlan,
        recordedUtterance: String?,
        origin: AssistantExecutionOrigin,
        offersUndoBanner: Bool = false,
        receiptStartedAt: Date? = nil,
        usedHabitContext: Bool = false,
        habitSummary: String? = nil,
        automationGeneration: UInt64? = nil,
        timerGeneration: UInt64? = nil,
        onAutomationCompletion: ((Int, Int, Int) -> Void)? = nil
    ) async -> IntentPlan {
        if origin.blocksWhileScreenLocked, isControlBlockedByScreenLock {
            showToast(screenLockBlockedMessage, isError: true)
            setAssistantState(.failed(screenLockBlockedMessage))
            return IntentPlan(
                intents: [],
                reply: screenLockBlockedMessage,
                source: plan.source
            )
        }
        if let capabilityMessage = firstPlanCapabilityRejectionMessage(for: plan.intents) {
            showToast(capabilityMessage, isError: true)
            setAssistantState(.failed(capabilityMessage))
            return IntentPlan(
                intents: [],
                reply: capabilityMessage,
                source: plan.source
            )
        }
        let context = controlContextID
        let previousSnapshot = devices
        var groupOrder: [String] = []
        var intentsByTarget: [String: [DeviceIntent]] = [:]
        for intent in plan.intents {
            if intentsByTarget[intent.targetId] == nil { groupOrder.append(intent.targetId) }
            intentsByTarget[intent.targetId, default: []].append(intent)
        }

        func runtimeAllowsWrites() -> Bool {
            if let timerGeneration { return scheduledCommandsCanWrite(generation: timerGeneration) }
            if let automationGeneration { return automationCanWrite(generation: automationGeneration) }
            return true
        }

        var outcomes: [AssistantApplyOutcome] = []
        if timerGeneration != nil || automationGeneration != nil {
            // A switch stops the next step without cancelling a write already sent to the provider.
            for intent in plan.intents {
                guard context == controlContextID, runtimeAllowsWrites() else { break }
                outcomes.append(await apply(intent, context: context))
            }
        } else {
            // Other plans run devices concurrently while preserving each device's intent order.
            let deviceTasks = groupOrder.map { targetId in
                let intents = intentsByTarget[targetId] ?? []
                return Task { () -> [AssistantApplyOutcome] in
                    var out: [AssistantApplyOutcome] = []
                    for intent in intents {
                        guard context == self.controlContextID else { break }
                        out.append(await self.apply(intent, context: context))
                    }
                    return out
                }
            }
            for task in deviceTasks {
                outcomes.append(contentsOf: await task.value)
            }
        }
        guard context == controlContextID else { return plan }

        var restoreCommands: [DeviceCommand] = []
        var failedNames: [String] = []
        var offlineNames: [String] = []
        var appliedDeviceIds: Set<String> = []
        var appliedSceneIds: Set<String> = []
        var succeededIntents: [DeviceIntent] = []
        for outcome in outcomes {
            switch outcome {
            case .applied(let intent, let deviceId, let restore):
                succeededIntents.append(intent)
                restoreCommands.append(contentsOf: restore)
                if let deviceId { appliedDeviceIds.insert(deviceId) }
            case .appliedScene(let intent, let sceneId):
                succeededIntents.append(intent)
                appliedSceneIds.insert(sceneId)
            case .failed(let name):
                if !failedNames.contains(name) { failedNames.append(name) }
            case .offline(let name):
                if !offlineNames.contains(name) { offlineNames.append(name) }
            case .skipped:
                break
            }
        }

        onAutomationCompletion?(outcomes.count, succeededIntents.count, outcomes.count - succeededIntents.count)
        if outcomes.isEmpty, !runtimeAllowsWrites() { return plan }

        // Only explicit user actions become habits, and only for intents that actually succeeded (#34/#113).
        var habitReceipt: UserHabitMemory.RecordingReceipt?
        if origin.recordsHabits, isHabitLearningEnabled, !succeededIntents.isEmpty {
            var memory = userHabitMemory
            let utteranceForHabit = (failedNames.isEmpty && offlineNames.isEmpty) ? recordedUtterance : nil
            habitReceipt = memory.record(
                utterance: utteranceForHabit,
                intents: succeededIntents,
                devices: devices,
                scenes: scenes
            )
            userHabitMemory = memory
        }

        let timerInterrupted = timerGeneration != nil && outcomes.count < plan.intents.count && !runtimeAllowsWrites()
        let completedReply = timerInterrupted
            ? IntentReply.describe(succeededIntents, devices: devices, scenes: scenes) : plan.reply
        if !appliedDeviceIds.isEmpty {
            let actionId = UUID()
            lastAssistantUndo = AssistantUndoEntry(
                actionId: actionId,
                reply: completedReply,
                restore: restoreCommands.reversed(),
                previous: previousSnapshot.filter { appliedDeviceIds.contains($0.id) },
                at: Date(),
                habitReceipt: habitReceipt
            )
            if appliedDeviceIds.count > 1 || origin == .automation || offersUndoBanner || timerInterrupted {
                scheduleUndoBanner(
                    actionId: actionId,
                    title: completedReply.isEmpty ? L10n.tr("已执行 AI 指令", "Executed AI command") : completedReply,
                    restoreCommands: restoreCommands.reversed(),
                    previousDevices: previousSnapshot,
                    deviceCount: appliedDeviceIds.count,
                    habitReceipt: habitReceipt,
                    duration: origin == .automation ? AutomationPolicy.undoWindow : nil
                )
            }
        }

        if timerInterrupted {
            let message = L10n.tr("定时任务开关已改变，已停止剩余步骤", "The scheduled-commands switch changed, so the remaining steps were stopped.")
            var partial = plan
            partial.intents = succeededIntents
            partial.reply = succeededIntents.isEmpty ? message
                : completedReply + "\n" + message
            setAssistantState(succeededIntents.isEmpty ? .failed(message) : .done(partial.reply))
            return partial
        }
        if !failedNames.isEmpty {
            let sep = L10n.isEnglish ? ", " : "、"
            setAssistantState(.failed(L10n.tr("\(failedNames.joined(separator: sep)) 未响应", "\(failedNames.joined(separator: sep)) did not respond")))
        } else if outcomes.allSatisfy({ outcome in
            if case .applied = outcome { return false }
            if case .appliedScene = outcome { return false }
            return true
        }) {
            let sep = L10n.isEnglish ? ", " : "、"
            let reason = offlineNames.isEmpty
                ? L10n.tr("没有可执行的设备操作", "No matching device actions")
                : L10n.tr("\(offlineNames.joined(separator: sep)) 当前离线", "\(offlineNames.joined(separator: sep)) offline")
            setAssistantState(.failed(reason))
        } else {
            assistantSuggestions = plan.suggestions.isEmpty ? proactiveDisplaySuggestions() : plan.suggestions
            let receipt = receiptStartedAt.map { start in
                AssistantExecutionReceipt(
                    route: plan.source == .local ? .localRule : .aiModel,
                    elapsedMilliseconds: elapsedMilliseconds(since: start),
                    usedHabitContext: usedHabitContext,
                    habitSummary: usedHabitContext ? habitSummary : nil
                )
            }
            let momentaryIds = Set(devices.filter(\.isMomentaryButton).map(\.id))
            let resolvedReply: String
            if plan.intents.contains(where: { momentaryIds.contains($0.targetId) }) {
                resolvedReply = IntentReply.describe(plan.intents, devices: devices, scenes: scenes)
            } else {
                resolvedReply = plan.reply
            }
            setAssistantState(.done(resolvedReply), receipt: receipt)
        }
        return plan
    }

    private enum AssistantApplyOutcome: Sendable {
        case applied(intent: DeviceIntent, deviceId: String?, restore: [DeviceCommand])
        /// A scene ran: it counts toward habit learning but offers no device undo (#113).
        case appliedScene(intent: DeviceIntent, sceneId: String)
        case failed(String)
        case offline(String)
        case skipped
    }

    nonisolated struct AssistantEffect {
        let updated: SmartDevice
        let command: DeviceCommand
        let restore: [DeviceCommand]
    }

    /// The single execution path for assistant intents: optimistic update, lock, dispatch, rollback on failure.
    private func apply(_ intent: DeviceIntent, context: UUID) async -> AssistantApplyOutcome {
        guard context == controlContextID else { return .skipped }
        if intent.operation == .activateScene {
            if let capabilityMessage = capabilitySceneControlRejectionMessage(forSceneIdOrName: intent.targetId) {
                return .failed(capabilityMessage)
            }
            let gate = evaluateSceneControlGate(sceneId: intent.targetId)
            if !gate.allowed {
                return .failed(gate.rejectionReason?.userMessage ?? intent.targetId)
            }
            guard let scene = scenes.first(where: { $0.id == intent.targetId }) else { return .skipped }
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                guard context == controlContextID else { return .skipped }
                return .appliedScene(intent: intent, sceneId: intent.targetId)
            } catch {
                return .failed(scene.name)
            }
        }

        if let reason = capabilityWriteRejection(forDeviceId: intent.targetId) {
            return .failed(reason.userMessage)
        }
        guard let previous = devices.first(where: { $0.id == intent.targetId }) else { return .skipped }
        guard previous.isOnline else { return .offline(previous.name) }
        // Appliance cards are not assistant-controllable in this cut. Their `.power` effect exists
        // only so All Off undo can restore them; direct assistant plans still skip them (#300).
        guard IntentDeviceCategory(previous).isAssistantControllable else { return .skipped }
        guard let effect = Self.assistantEffect(of: intent.operation, on: previous) else { return .skipped }

        let write = beginOptimisticWrite(
            from: previous,
            to: previous.isMomentaryButton ? nil : effect.updated,
            lock: .seconds(3.0)
        )
        do {
            try await send(effect.command, for: write, context: context)
            guard context == controlContextID else { return .skipped }
            return .applied(intent: intent, deviceId: previous.isMomentaryButton ? nil : previous.id, restore: effect.restore)
        } catch {
            guard context == controlContextID else { return .skipped }
            return .failed(previous.name)
        }
    }

    static func undoOperation(for command: DeviceCommand) -> IntentOperation? {
        switch command {
        case .setLightPower(_, let on), .setFanPower(_, let on), .setSwitch(_, let on): return .power(on)
        case .setLightBrightness(_, let percent): return .brightness(percent)
        case .setLightColorTemp(_, let kelvin): return .colorTemperature(kelvin)
        case .setLightEffect(_, let effect): return .lightEffect(effect)
        case .setClimatePower(_, let on, let mode): return .hvacMode(on ? mode : "off")
        case .setClimateMode(_, let mode): return .hvacMode(mode)
        case .setClimateTemperature(_, let temperature): return .targetTemperature(temperature)
        case .setClimateFanMode(_, let mode), .setFanPresetMode(_, let mode): return .fanSpeed(mode)
        case .setFanOscillating(_, let on): return .oscillation(on)
        case .vacuumAction(_, .start): return .power(true)
        case .vacuumAction(_, .returnToBase): return .power(false)
        default: return nil
        }
    }

    static func undoEffect(of command: DeviceCommand, on device: SmartDevice) -> SmartDevice? {
        guard let operation = undoOperation(for: command),
              let effect = assistantEffect(of: operation, on: device),
              effect.command.targetEntityId == command.targetEntityId else { return nil }
        if case .setClimatePower = command { return effect.updated }
        guard effect.command == command else { return nil }
        return effect.updated
    }

    static func retargetedUndoEffect(
        of command: DeviceCommand,
        on device: SmartDevice
    ) -> (updated: SmartDevice, command: DeviceCommand)? {
        guard let operation = undoOperation(for: command),
              let effect = assistantEffect(of: operation, on: device) else { return nil }
        if case .setClimatePower(_, let on, let mode) = command,
           case .climate(let spec) = device.kind {
            return (
                effect.updated,
                .setClimatePower(entityId: spec.entityId, isOn: on, fallbackMode: mode)
            )
        }
        return (effect.updated, effect.command)
    }

    /// Verify the same intermediate states and reverse command order used by real execution.
    static func isAssistantSuggestionReversible(_ suggestion: AssistantSuggestion, devices: [SmartDevice]) -> Bool {
        var snapshots: [String: (before: SmartDevice, after: SmartDevice)] = [:]
        var restore: [(targetId: String, command: DeviceCommand)] = []
        for intent in suggestion.intents {
            guard let original = devices.first(where: { $0.id == intent.targetId }),
                  !original.isMomentaryButton else { return false }
            let current = snapshots[intent.targetId]?.after ?? original
            guard let effect = assistantEffect(of: intent.operation, on: current),
                  !effect.restore.isEmpty else { return false }
            snapshots[intent.targetId] = (original, effect.updated)
            for command in effect.restore { restore.append((intent.targetId, command)) }
        }
        guard !restore.isEmpty else { return false }
        for step in restore.reversed() {
            guard let snapshot = snapshots[step.targetId],
                  let restored = undoEffect(of: step.command, on: snapshot.after) else { return false }
            snapshots[step.targetId] = (snapshot.before, restored)
        }
        return snapshots.values.allSatisfy { $0.before.kind == $0.after.kind }
    }

    nonisolated static func assistantEffect(of operation: IntentOperation, on device: SmartDevice) -> AssistantEffect? {
        guard let op = IntentValidator.normalize(operation, for: device) else { return nil }
        var updated = device

        switch (op, device.kind) {
        case (.power(let on), .light(var s)):
            let restore = DeviceCommand.setLightPower(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightPower(entityId: s.entityId, isOn: on), restore: [restore])

        case (.brightness(let percent), .light(var s)):
            var restore: [DeviceCommand] = []
            if !s.isOn { restore.append(.setLightPower(entityId: s.entityId, isOn: false)) }
            if let previous = s.brightnessPercent {
                restore.append(.setLightBrightness(entityId: s.entityId, percent: previous))
            } else if s.isOn {
                restore.append(.setLightBrightness(entityId: s.entityId, percent: 100))
            }
            s.isOn = true
            s.brightnessPercent = percent
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightBrightness(entityId: s.entityId, percent: percent), restore: restore)

        case (.colorTemperature(let kelvin), .light(var s)):
            var restore: [DeviceCommand] = []
            if !s.isOn { restore.append(.setLightPower(entityId: s.entityId, isOn: false)) }
            if let prevKelvin = s.colorTempKelvin {
                if let effect = s.currentEffect { restore.append(.setLightEffect(entityId: s.entityId, effect: effect)) }
                restore.append(.setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin))
            } else if s.isOn {
                restore.append(.setLightPower(entityId: s.entityId, isOn: true))
            }
            s.isOn = true
            s.colorTempKelvin = kelvin
            s.currentEffect = nil
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightColorTemp(entityId: s.entityId, kelvin: kelvin), restore: restore)

        case (.lightEffect(let effect), .light(var s)):
            var restore: [DeviceCommand] = []
            if !s.isOn { restore.append(.setLightPower(entityId: s.entityId, isOn: false)) }
            if let prevEffect = s.currentEffect {
                restore.append(.setLightEffect(entityId: s.entityId, effect: prevEffect))
            } else if let prevKelvin = s.colorTempKelvin {
                restore.append(.setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin))
            } else if s.isOn {
                restore.append(.setLightPower(entityId: s.entityId, isOn: true))
            }
            s.isOn = true
            s.currentEffect = effect
            updated.kind = .light(s)
            return AssistantEffect(
                updated: updated,
                command: .setLightEffect(entityId: s.entityId, effect: effect),
                restore: restore
            )

        case (.power(let on), .climate(var s)):
            let wasOn = s.isOn && s.hvacMode != "off"
            let resumeMode = s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode
            let restore = DeviceCommand.setClimatePower(entityId: s.entityId, isOn: wasOn, fallbackMode: resumeMode)
            s.isOn = on
            s.hvacMode = on ? resumeMode : "off"
            updated.kind = .climate(s)
            return AssistantEffect(
                updated: updated,
                command: .setClimatePower(entityId: s.entityId, isOn: on, fallbackMode: resumeMode),
                restore: [restore]
            )

        case (.hvacMode(let mode), .climate(var s)):
            let restore = DeviceCommand.setClimateMode(entityId: s.entityId, hvacMode: s.isOn ? s.hvacMode : "off")
            s.hvacMode = mode
            s.isOn = (mode != "off")
            updated.kind = .climate(s)
            return AssistantEffect(updated: updated, command: .setClimateMode(entityId: s.entityId, hvacMode: mode), restore: [restore])

        case (.targetTemperature(let temperature), .climate(var s)):
            let restore = DeviceCommand.setClimateTemperature(entityId: s.entityId, temperature: s.targetTemperature)
            s.targetTemperature = temperature
            updated.kind = .climate(s)
            return AssistantEffect(
                updated: updated,
                command: .setClimateTemperature(entityId: s.entityId, temperature: temperature),
                restore: [restore]
            )

        case (.power(let on), .fan(var s)):
            let restore = DeviceCommand.setFanPower(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanPower(entityId: s.entityId, isOn: on), restore: [restore])

        case (.power(let on), .plug(var s)):
            if s.switchEntityId.hasPrefix("button.") {
                guard on else { return nil }
                return AssistantEffect(updated: updated, command: .pressButton(entityId: s.switchEntityId), restore: [])
            }
            let restore = DeviceCommand.setSwitch(entityId: s.switchEntityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .plug(s)
            return AssistantEffect(updated: updated, command: .setSwitch(entityId: s.switchEntityId, isOn: on), restore: [restore])

        case (.power(let on), .vacuum(var s)):
            let restore = DeviceCommand.vacuumAction(entityId: s.entityId, action: s.isCleaning ? .start : .returnToBase)
            s.status = on ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            return AssistantEffect(
                updated: updated,
                command: .vacuumAction(entityId: s.entityId, action: on ? .start : .returnToBase),
                restore: [restore]
            )

        case (.power(let on), .tv(var s)):
            let wasOn = s.state != "off" && s.state != "standby"
            let powerEntity = LGWebOSProtocol.isLGEntity(s.mediaEntityId) ? LGWebOSProtocol.powerEntityId : s.mediaEntityId
            let restore = DeviceCommand.setSwitch(entityId: powerEntity, isOn: wasOn)
            s.state = on ? "on" : "standby"
            if on { s.isScreenOff = false }
            updated.kind = .tv(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: powerEntity, isOn: on),
                restore: [restore]
            )


        case (.power(let on), .camera(var s)):
            let restore = DeviceCommand.setSwitch(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .camera(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: s.entityId, isOn: on),
                restore: [restore]
            )
        case (.power(let on), .appliance(var s)):
            let restore = DeviceCommand.setSwitch(entityId: s.powerEntityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .appliance(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: s.powerEntityId, isOn: on),
                restore: [restore]
            )
        case (.power(let on), .humidifier(var s)):
            let restore = DeviceCommand.setSwitch(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .humidifier(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: s.entityId, isOn: on),
                restore: [restore]
            )
        case (.power(let on), .valve(var s)):
            let restore = DeviceCommand.setSwitch(entityId: s.entityId, isOn: s.isOpen)
            s.isOpen = on
            updated.kind = .valve(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: s.entityId, isOn: on),
                restore: [restore]
            )

        case (.fanSpeed(let preset), .fan(var s)):
            var restore: [DeviceCommand] = []
            if !s.isOn { restore.append(.setFanPower(entityId: s.entityId, isOn: false)) }
            if let previous = s.presetMode {
                restore.append(.setFanPresetMode(entityId: s.entityId, presetMode: previous))
            } else if s.isOn {
                restore.append(.setFanPower(entityId: s.entityId, isOn: true))
            }
            s.isOn = true
            s.presetMode = preset
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanPresetMode(entityId: s.entityId, presetMode: preset), restore: restore)

        case (.fanSpeed(let fanMode), .climate(var s)):
            let restore = s.fanMode.map { [DeviceCommand.setClimateFanMode(entityId: s.entityId, fanMode: $0)] } ?? []
            s.fanMode = fanMode
            updated.kind = .climate(s)
            return AssistantEffect(updated: updated, command: .setClimateFanMode(entityId: s.entityId, fanMode: fanMode), restore: restore)

        case (.oscillation(let on), .fan(var s)):
            let restore = DeviceCommand.setFanOscillating(entityId: s.entityId, oscillating: s.isOscillating ?? !on)
            s.isOscillating = on
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanOscillating(entityId: s.entityId, oscillating: on), restore: [restore])

        default:
            return nil
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    func setAssistantState(_ state: AssistantState, receipt: AssistantExecutionReceipt? = nil) {
        assistantState = state
        lastAssistantReceipt = receipt
        assistantResetTask?.cancel()
        switch state {
        case .done, .failed, .awaitingChoice:
            // A "tap a suggestion" hint stays longer so it can be read next to the chips.
            let delay: Double = if case .awaitingChoice = state { 8 } else { 3.2 }
            assistantResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.assistantState == state else { return }
                self.assistantState = .idle
                self.lastAssistantReceipt = nil
            }
        case .idle, .thinking:
            break
        }
    }
}
