import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// P4b-M: the device-type picker previews what a change hides, which alerts keep reading, and which
/// timers it pauses; only an applied choice prunes, and a refused write keeps the stored types.
@Suite("Device type selection store", .timeLimit(.minutes(1)))
@MainActor
struct DeviceTypeSelectionStoreTests {
    static let haURL = "http://192.168.1.60:8123"
    nonisolated static let frozenNow = Date(timeIntervalSince1970: 1_760_000_000)

    static let light = SmartDevice(
        id: "dev_light", name: "吸顶灯", roomId: "living", roomName: "客厅",
        model: "ha.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true))
    )
    static let plug = SmartDevice(
        id: "dev_plug", name: "台灯插座", roomId: "study", roomName: "书房",
        model: "ha.switch", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.desk", isOn: false))
    )
    static let leakSensor = SmartDevice(
        id: "dev_leak", name: "厨房水浸", roomId: "kitchen", roomName: "厨房",
        model: "ha.sensor", isOnline: true,
        kind: .sensor(SensorSpec(
            observations: [SensorObservation(sourceId: "dev_leak#binary_sensor.kitchen_leak", kind: .leak, alarming: false)]
        ))
    )
    static let scene = HomeScene(id: "scene.movie", name: "观影", entityId: "scene.movie")

    private func makeStore(defaults: InMemoryUserDefaults = InMemoryUserDefaults()) async throws -> HomeStore {
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)
        var snapshot = SynthesizedHome(devices: [Self.light, Self.plug, Self.leakSensor], scenes: [Self.scene])
        snapshot.isInitialLoadComplete = true
        let store = HomeStore(provider: MockHomeProvider(snapshot: snapshot), credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil
        store.assistantNow = { Self.frozenNow }
        try await awaitState { store.devices.count == 3 }
        #expect(store.isHAConnectionEnabled)
        return store
    }

    private var allTypes: Set<DeviceCategoryID> { Set(DeviceCategoryID.allCases) }

    @Test("Upgraded users keep every type, and the three choices map to their modes")
    func defaultsAndModes() async throws {
        let store = try await makeStore()
        #expect(store.capabilitySelection.enabledCategories == allTypes)
        #expect(store.deviceTypeSelectionMode == .allSupportedTypes)
        #expect(HomeStore.deliveredDeviceCategories == DeviceCategoryID.allCases)
        #expect(DeviceTypeSelectionMode.mode(for: [.plug, .light]) == .lightAndSwitch)
        #expect(DeviceTypeSelectionMode.mode(for: [.light]) == .custom)
        #expect(store.applyDeviceCategorySelection(allTypes) == .unchanged)
    }

    @Test("Closing sensors previews the hidden card, keeps the leak alert, and leaves manual scenes runnable")
    func closingSensorsKeepsLeakAlert() async throws {
        let defaults = InMemoryUserDefaults()
        let store = try await makeStore(defaults: defaults)
        let picked = allTypes.subtracting([.sensor])

        let impact = store.previewDeviceCategorySelection(picked)
        #expect(impact.removedCategories == [.sensor])
        #expect(impact.hiddenCardNames == [Self.leakSensor.name])
        #expect(impact.retainedSafetyDevices.map(\.id) == [Self.leakSensor.id])
        #expect(impact.retainedSafetyDevices.first?.signals.contains(.leak) == true)
        #expect(impact.showsManualSceneNotice)
        #expect(store.capabilitySelection.enabledCategories == allTypes, "a preview never writes")

        #expect(store.applyDeviceCategorySelection(picked) == .applied)
        #expect(store.capabilitySelection.enabledCategories == picked)
        #expect(store.deviceTypeSelectionMode == .custom)
        #expect(store.evaluateSceneControlGate(sceneId: Self.scene.id).rejectionReason == nil)
        #expect(store.evaluateDeviceControlGate(deviceId: Self.leakSensor.id).rejectionReason == .categoryDisabled(.sensor))

        let restarted = try await makeStore(defaults: defaults)
        #expect(restarted.capabilitySelection.enabledCategories == picked)
    }

    @Test("A timer on a closing type waits for confirmation of that exact list, then is paused")
    func referencedTimerNeedsConfirmation() async throws {
        let defaults = InMemoryUserDefaults()
        let store = try await makeStore(defaults: defaults)
        let scope = store.homeAssistantScopeIdentifier
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭吸顶灯",
            fireDate: Self.frozenNow.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: Self.light.id, operation: .power(false))], reply: "关闭吸顶灯", source: .local),
            sourceScope: scope,
            sourceScopes: [scope]
        )
        store.assistantSleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands(now: Self.frozenNow)
        let picked: Set<DeviceCategoryID> = [.plug, .sensor]

        guard case .needsConfirmation(let impact) = store.applyDeviceCategorySelection(picked) else {
            Issue.record("closing a referenced type must ask first"); return
        }
        #expect(impact.itemsToPause.contains { $0.kind == .waitingTimer && $0.id == timer.id.uuidString })
        #expect(store.capabilitySelection.enabledCategories == allTypes)
        #expect(store.pausedScheduledCommands.isEmpty)

        #expect(store.applyDeviceCategorySelection(picked, pauseConfirmed: true, expectedPauseItemKeys: ["automationRule:other"]) == .needsConfirmation(impact),
                "a confirmation for a different list re-previews")
        #expect(store.applyDeviceCategorySelection(picked, pauseConfirmed: true, expectedPauseItemKeys: impact.pauseItemKeys) == .applied)
        #expect(store.capabilitySelection.enabledCategories == picked)
        #expect(store.pausedScheduledCommands.map(\.command.id) == [timer.id])
    }

    @Test("A refused save, an uncertain identity, or an empty list keep the stored types")
    func refusalsKeepSelection() async throws {
        let defaults = InMemoryUserDefaults()
        let store = try await makeStore(defaults: defaults)
        #expect(store.applyDeviceCategorySelection([]).isRefused)
        #expect(store.capabilitySelection.enabledCategories == allTypes)

        defaults.set(Data("not json".utf8), forKey: CapabilitySelectionStore.storageKey)
        #expect(store.applyDeviceCategorySelection(DeviceCategoryPreset.lightAndSwitch.categorySet).isRefused)
        #expect(store.capabilitySelection.enabledCategories == allTypes)

        let mem = MemoryVaultStorage()
        mem.readResult = .unavailable
        let suite = "test.devicetype.uncertain.\(UUID().uuidString)"
        let uncertainDefaults = try #require(UserDefaults(suiteName: suite))
        uncertainDefaults.set(true, forKey: "has_completed_onboarding")
        let uncertain = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light], scenes: [])),
            defaultsSuiteName: suite,
            credentialVault: CredentialVault(storage: mem.storage)
        )
        try await uncertain.waitForTestSnapshot()
        #expect(uncertain.isIdentityUncertain)
        #expect(uncertain.applyDeviceCategorySelection(DeviceCategoryPreset.lightAndSwitch.categorySet).isRefused)
        #expect(uncertain.capabilitySelection.enabledCategories == allTypes)
    }
}

private extension DeviceTypeSelectionOutcome {
    var isRefused: Bool { if case .refused = self { true } else { false } }
}
