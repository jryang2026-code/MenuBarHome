import Foundation
import KeychainTestSupport
import Observation
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// P5b-M: macOS 主动建议 on its own switch, mirroring P5b-W
/// (windows/tests/proactiveSuggestionsToggle.test.ts).
///
/// Acceptance mapping:
/// 1. Off means the shared snapshot cadence never enters the suggestion branch: zero ambient
///    signatures, habit rankings, cache reads, chips and suggestion requests. Safety alerts, undo
///    expiry and saved timers on the same cadence keep running (positive controls).
/// 2. A suggestion run in flight when the switch closes is dropped by its own generation and
///    claims neither the signature nor the cache; a user command keeps running.
/// 3. Fresh installs start on, upgrades keep it, an uncertain identity changes nothing.
/// 4. #322 item 2: a discarded refresh never writes the retry cooldown.
@Suite(.timeLimit(.minutes(5)))
@MainActor
struct ProactiveSuggestionsToggleTests {
    nonisolated static let frozenNow = Date(timeIntervalSince1970: 1_800_000_000)

    static let desk = SmartDevice(
        id: "dev_desk", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.desk", isOn: false))
    )
    static let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
    )

    static func leak(_ alarming: Bool) -> SmartDevice {
        SmartDevice(
            id: "sink", name: "水浸传感器", roomId: "chu_fang", roomName: "厨房",
            model: "test.sensor", isOnline: true,
            kind: .sensor(SensorSpec(battery: nil, observations: [
                SensorObservation(sourceId: "sink#miot:2", kind: .leak, alarming: alarming)
            ]))
        )
    }

    static func readings(_ temperature: Double) -> [EnvironmentReading] {
        [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: temperature, humidity: 60)]
    }

    static func home(temperature: Double, leakAlarming: Bool = false) -> SynthesizedHome {
        SynthesizedHome(
            devices: [desk, ceiling, leak(leakAlarming)],
            environmentReadings: readings(temperature),
            scenes: []
        )
    }

    /// Deferred HTTP transport: records requests; each awaits an explicit release.
    @Observable
    @MainActor
    final class DeferredTransport {
        @ObservationIgnored private var resolvers: [CheckedContinuation<(Data, URLResponse), Error>] = []
        private(set) var count = 0

        func stub(_ request: URLRequest) async throws -> (Data, URLResponse) {
            count += 1
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
            url: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }

    static let suggestionReply = #"{"suggestions":[{"device":"dev_desk","op":"power","value":true,"confidence":85}]}"#

    /// A legacy (upgraded) store: AI and suggestions on, frozen clock, loopback model, no consent.
    private func makeStore(
        temperature: Double = 29.5
    ) async throws -> (store: HomeStore, mock: MockHomeProvider, transport: DeferredTransport, defaults: UserDefaults) {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let mock = MockHomeProvider(snapshot: Self.home(temperature: temperature))
        let store = HomeStore(
            provider: mock,
            credentialVault: CredentialVault(storage: MemoryVaultStorage().storage),
            defaults: defaults
        )
        store.assistantNow = { Self.frozenNow }
        store.enableSafetyAlerts = false
        try await store.waitForTestSnapshot()
        store.enableSafetyAlerts = true
        #expect(store.homeBackend != .demo)
        #expect(store.aiAssistantEnabled)
        #expect(store.proactiveSuggestionsEnabled)
        #expect(store.saveAssistantConfig(AssistantConfig(
            baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", apiKey: ""
        )))
        let transport = DeferredTransport()
        store.assistantTransportOverride = { request in try await transport.stub(request) }
        return (store, mock, transport, defaults)
    }

    // MARK: - Acceptance 3: defaults and write refusals

    @Test("Fresh installs and upgrades both start with suggestions on, independently of AI")
    func defaults() async throws {
        let fresh = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: [])),
            credentialVault: CredentialVault(storage: MemoryVaultStorage().storage),
            defaults: InMemoryUserDefaults()
        )
        try await fresh.waitForTestSnapshot()
        #expect(fresh.capabilityResolutionMode == .freshInstall)
        #expect(fresh.proactiveSuggestionsEnabled, "manifest proactive-suggestions.defaultOnFreshInstall is true")
        #expect(fresh.aiAssistantEnabled == false, "the two switches are independent")

        let (legacy, _, _, _) = try await makeStore()
        #expect(legacy.capabilityResolutionMode == .legacyPreserved)
        #expect(legacy.setProactiveSuggestionsEnabled(false))
        #expect(legacy.aiAssistantEnabled, "closing suggestions leaves AI on")
        #expect(legacy.setAIAssistantEnabled(false))
        #expect(legacy.setProactiveSuggestionsEnabled(true))
        #expect(legacy.proactiveSuggestionsEnabled && !legacy.aiAssistantEnabled)
    }

    @Test("An uncertain identity read or a refused store write keeps the switch value")
    func refusals() async throws {
        let mem = MemoryVaultStorage()
        mem.readResult = .unavailable
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let uncertain = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: [])),
            credentialVault: CredentialVault(storage: mem.storage), defaults: defaults
        )
        try await uncertain.waitForTestSnapshot()
        #expect(uncertain.isIdentityUncertain)
        #expect(uncertain.setProactiveSuggestionsEnabled(false) == false)
        #expect(uncertain.proactiveSuggestionsEnabled, "fail-closed: the preserved value stays")

        let (store, _, _, storeDefaults) = try await makeStore()
        storeDefaults.set(Data("not json".utf8), forKey: CapabilitySelectionStore.storageKey)
        #expect(store.setProactiveSuggestionsEnabled(false) == false)
        #expect(store.proactiveSuggestionsEnabled, "a refused write must not leave a half-applied state")
    }

    @Test("Turning suggestions off persists across a store restart")
    func persistsAcrossRestart() async throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: [])),
            credentialVault: vault, defaults: defaults
        )
        try await store.waitForTestSnapshot()
        #expect(store.setProactiveSuggestionsEnabled(false))

        let restarted = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.desk], scenes: [])),
            credentialVault: vault, defaults: defaults
        )
        try await restarted.waitForTestSnapshot()
        #expect(restarted.proactiveSuggestionsEnabled == false)
        #expect(restarted.aiAssistantEnabled)
    }

    // MARK: - Acceptance 1: zero suggestion work while off

    @Test("Off: every suggestion entry and the snapshot cadence do zero suggestion work")
    func offDoesZeroSuggestionWork() async throws {
        let (store, mock, transport, _) = try await makeStore()
        store.presentAssistantBar()
        #expect(store.assistantSuggestions.isEmpty == false, "control: on, the bar shows chips")
        try await awaitState { transport.count == 1 }
        #expect(store.setProactiveSuggestionsEnabled(false))
        #expect(store.assistantSuggestions.isEmpty, "closing clears the displayed chips")
        transport.release(Self.chat(Self.suggestionReply))
        try await awaitState { store.isProactiveRecommending == false }
        let settledRequests = transport.count
        store.proactiveWorkCounters = ProactiveWorkCounters()

        store.presentAssistantBar()
        store.refreshProactiveSuggestionCacheIfStale()
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() == nil)
        await store.refreshProactiveSuggestionsCache()
        await store.requestProactiveJevSuggestions()

        // The shared cadence: a climate change that would normally start a refresh.
        await mock.updateSnapshot(Self.home(temperature: 24))
        try await awaitState { store.environmentReadings.first?.temperature == 24 }

        #expect(store.proactiveWorkCounters == ProactiveWorkCounters(), "no signature, ranking or cache read")
        #expect(store.assistantSuggestions.isEmpty, "no chip and no count")
        #expect(store.proactiveRefreshTask == nil)
        #expect(transport.count == settledRequests, "no suggestion request")
        #expect(store.assistantState == .idle, "no prompt")
    }

    @Test("Automation off preserves safety alerts, undo, scheduled commands and the lock guard")
    func automationOffLeavesIndependentConsumersRunning() async throws {
        let (store, mock, _, _) = try await makeStore()
        let write = await store.runAutomation(
            intents: [.init(targetId: Self.desk.id, operation: .power(true))], title: "开灯"
        )
        #expect(write.succeededCount == 1)
        store.pauseUndoBannerCountdown()
        #expect(store.setEventAutomationEnabled(false))

        var alerts: [SafetyAlert] = []
        store.onSafetyAlert = { alerts.append($0) }
        await mock.updateSnapshot(Self.home(temperature: 24, leakAlarming: true))
        try await awaitState { store.environmentReadings.first?.temperature == 24 }
        #expect(alerts.count == 1)

        let desk = try #require(store.devices.first { $0.id == Self.desk.id })
        store.setScreenLocked(true)
        #expect(store.togglePrimary(desk) == nil)
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        #expect(store.undoTurnAllOff() == nil)
        #expect(store.undoBanner != nil)
        store.setScreenLocked(false)
        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(await mock.executedCommands.contains(.setLightPower(entityId: "light.desk", isOn: false)))

        let gate = ScheduledCommandTestSupport.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后打开书房台灯")
        #expect(store.scheduledCommands.count == 1)
        try await awaitState { gate.waiting == 1 }
        gate.release()
        try await awaitState { store.scheduledCommands.isEmpty }
        try await awaitState { store.devices.first { $0.id == Self.desk.id }?.isActiveOn == true }
    }

    @Test("Off: safety alerts, undo expiry and saved timers still run on the same cadence")
    func offKeepsSafetyUndoAndTimers() async throws {
        let (store, mock, transport, _) = try await makeStore()
        #expect(store.setProactiveSuggestionsEnabled(false))
        store.proactiveWorkCounters = ProactiveWorkCounters()
        var alerts: [SafetyAlert] = []
        store.onSafetyAlert = { alerts.append($0) }

        // Safety: the same snapshot that changes the climate raises the leak alert.
        await mock.updateSnapshot(Self.home(temperature: 24, leakAlarming: true))
        try await awaitState { store.environmentReadings.first?.temperature == 24 }
        #expect(alerts.count == 1, "the leak alert still fires")
        #expect(alerts.first?.body.contains("水浸传感器") == true)

        // Undo: a banner still expires on its own schedule.
        store.scheduleUndoBanner(
            title: "已打开书房台灯", restoreCommands: [], previousDevices: [], deviceCount: 1, duration: 0.05
        )
        #expect(store.undoBanner != nil)
        try await awaitState { store.undoBanner == nil }

        // Timers: a saved timer is created and fires through the frozen sleep.
        let gate = ScheduledCommandTestSupport.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后打开书房台灯")
        #expect(store.scheduledCommands.count == 1)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        try await awaitState { store.scheduledCommands.isEmpty }
        await waitUntil { await mock.executedCommands.contains(.setLightPower(entityId: "light.desk", isOn: true)) }

        #expect(store.proactiveWorkCounters == ProactiveWorkCounters(), "the positive controls did no suggestion work")
        #expect(store.assistantSuggestions.isEmpty)
        #expect(transport.count == 0)
    }

    // MARK: - Acceptance 2: in-flight runs

    @Test("A suggestion result landing after the switch closes claims neither signature nor cache")
    func inFlightSuggestionDropped() async throws {
        let (store, _, transport, _) = try await makeStore()
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        try await awaitState { transport.count == 1 }

        let assistantGeneration = store.assistantEpoch
        #expect(store.setProactiveSuggestionsEnabled(false))
        #expect(store.assistantEpoch == assistantGeneration, "the AI generation is untouched")
        transport.release(Self.chat(Self.suggestionReply))
        try await awaitState { store.isProactiveRecommending == false }

        #expect(store.lastProactiveRefreshSignature == nil, "a discarded run must not claim the signature")
        #expect(store.aiProactiveSuggestions == nil)
        #expect(store.assistantSuggestions.isEmpty)
        #expect(store.proactiveRetryEarliest == nil)
    }

    @Test("Closing suggestions does not cancel a command the user started")
    func userCommandSurvivesSuggestionsOff() async throws {
        let (store, mock, transport, _) = try await makeStore()
        let task = Task { await store.runAssistantCommand("我要睡觉了") }
        try await awaitState { transport.count == 1 }
        #expect(store.setProactiveSuggestionsEnabled(false))
        transport.release(Self.chat(#"{"actions":[{"device":"dev_desk","op":"power","value":true}],"reply":"已打开书房台灯"}"#))
        #expect(await task.value != nil, "the command keeps its result")
        await waitUntil { await mock.executedCommands.contains(.setLightPower(entityId: "light.desk", isOn: true)) }
    }

    @Test("Re-enabling refreshes again from the next snapshot")
    func reenableRefreshes() async throws {
        let (store, mock, transport, _) = try await makeStore()
        #expect(store.setProactiveSuggestionsEnabled(false))
        #expect(store.setProactiveSuggestionsEnabled(true))
        await mock.updateSnapshot(Self.home(temperature: 24))
        try await awaitState { transport.count == 1 }
        transport.release(Self.chat(Self.suggestionReply))
        try await awaitState { store.lastProactiveRefreshSignature != nil }
        #expect(store.assistantSuggestions.isEmpty == false)
    }

    // MARK: - #322 item 2: discarded refreshes never write the cooldown

    @Test("A refresh discarded by the AI switch leaves no cooldown behind (#322)")
    func aiOffDiscardWritesNoCooldown() async throws {
        let (store, _, transport, _) = try await makeStore()
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        try await awaitState { transport.count == 1 }
        #expect(store.setAIAssistantEnabled(false))
        transport.release(error: URLError(.cancelled))
        try await awaitState { store.isProactiveRecommending == false }
        #expect(store.proactiveRetryEarliest == nil)

        #expect(store.setAIAssistantEnabled(true))
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil, "refreshes at once after re-enabling")
        try await awaitState { transport.count == 2 }
        transport.release(Self.chat(Self.suggestionReply))
        try await awaitState { store.lastProactiveRefreshSignature != nil }
    }

    @Test("A refresh discarded by the suggestions switch leaves no cooldown; a real failure still does")
    func suggestionsOffDiscardWritesNoCooldown() async throws {
        let (store, _, transport, _) = try await makeStore()
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        try await awaitState { transport.count == 1 }
        #expect(store.setProactiveSuggestionsEnabled(false))
        transport.release(error: URLError(.timedOut))
        try await awaitState { store.isProactiveRecommending == false }
        #expect(store.proactiveRetryEarliest == nil)

        // Control: an undisturbed failure still throttles the retry, on the frozen clock.
        #expect(store.setProactiveSuggestionsEnabled(true))
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil)
        try await awaitState { transport.count == 2 }
        transport.release(error: URLError(.timedOut))
        try await awaitState { store.proactiveRetryEarliest != nil }
        #expect(store.proactiveRetryEarliest == Self.frozenNow.addingTimeInterval(store.proactiveRetryCooldown))
    }
}
