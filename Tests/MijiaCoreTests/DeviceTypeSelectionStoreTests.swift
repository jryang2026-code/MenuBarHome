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

    static let lgTV = SmartDevice(
        id: LGWebOSProtocol.deviceId, name: "LG电视", roomId: "living", roomName: "客厅",
        model: "lg.webos.oled42c2pca", isOnline: true,
        kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 12))
    )

    static func homeSnapshot(devices: [SmartDevice] = [light, plug, leakSensor]) -> SynthesizedHome {
        var snapshot = SynthesizedHome(devices: devices, scenes: [scene])
        snapshot.isInitialLoadComplete = true
        return snapshot
    }

    private func makeStore(
        defaults: InMemoryUserDefaults = InMemoryUserDefaults(),
        provider: MockHomeProvider = MockHomeProvider(snapshot: homeSnapshot())
    ) async throws -> HomeStore {
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)
        let store = HomeStore(provider: provider, credentialVault: vault, defaults: defaults)
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
        #expect(impact.retainedSafetyDevices.first?.signals == [.leak], "an unstarred sensor is not listed under 星标离线")
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

    @Test("Closing a type takes its cards off the panel, AI catalog and Raycast at once, before any refresh prunes them")
    func closedTypeCardsLeaveImmediately() async throws {
        var activePlug = Self.plug
        if case .plug(var spec) = activePlug.kind {
            spec.isOn = true
            activePlug.kind = .plug(spec)
        }
        let store = try await makeStore(
            provider: MockHomeProvider(snapshot: Self.homeSnapshot(devices: [Self.light, activePlug, Self.leakSensor]))
        )
        store.setAIAssistantEnabled(true)
        let capturedBodies = CapturedBodies()
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            capturedBodies.append(body)
            let ok = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": #"{"actions":[],"reply":""}"#]]]])
            return (ok, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let picked = allTypes.subtracting([.plug])

        #expect(store.applyDeviceCategorySelection(picked) == .applied)
        #expect(!store.categoryVisibleDevices.contains { $0.id == Self.plug.id })
        #expect(!store.filteredDevices.contains { $0.id == Self.plug.id })
        #expect(!store.visibleDevices.contains { $0.id == Self.plug.id })
        #expect(!store.raycastVisibleDevices.contains { $0.id == Self.plug.id })
        #expect(store.filteredDevices.map(\.id).sorted() == [Self.leakSensor.id, Self.light.id].sorted())

        _ = await store.runAssistantCommand("我要睡觉了")
        let closedCatalog = try #require(capturedBodies.last)
        #expect(!closedCatalog.contains(Self.plug.name))
        #expect(closedCatalog.contains(Self.light.name))
        #expect(!store.buildAssistantContext(mention: .none).activeDevicesSummary.contains(Self.plug.name))

        #expect(store.applyDeviceCategorySelection(allTypes) == .applied)
        #expect(store.categoryVisibleDevices.contains { $0.id == Self.plug.id })
        #expect(store.filteredDevices.contains { $0.id == Self.plug.id }, "reopening the type brings the card back")
        #expect(store.raycastVisibleDevices.contains { $0.id == Self.plug.id })

        _ = await store.runAssistantCommand("我要睡觉了")
        let reopenedCatalog = try #require(capturedBodies.last)
        #expect(reopenedCatalog.contains(Self.plug.name))
    }

    @Test("Closing TVs drops the LAN LG card and keeps it out across updates; reopening restores it")
    func closingTVsDropsLGCard() async throws {
        let provider = MockHomeProvider(snapshot: Self.homeSnapshot())
        let store = try await makeStore(provider: provider)
        store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10")
        store.applyLGDeviceUpdate(Self.lgTV)
        #expect(store.filteredDevices.contains { $0.id == Self.lgTV.id })
        #expect(store.raycastVisibleDevices.contains { $0.id == Self.lgTV.id })
        #expect(store.favoriteDeviceIds.contains(Self.lgTV.id), "a newly found TV is favorited once")
        store.toggleFavorite(Self.lgTV.id)
        #expect(!store.favoriteDeviceIds.contains(Self.lgTV.id))

        #expect(store.applyDeviceCategorySelection(allTypes.subtracting([.tv])) == .applied)
        #expect(!store.devices.contains { $0.id == Self.lgTV.id })
        #expect(!store.filteredDevices.contains { $0.id == Self.lgTV.id })
        #expect(!store.raycastVisibleDevices.contains { $0.id == Self.lgTV.id })

        store.applyLGDeviceUpdate(Self.lgTV)
        #expect(!store.devices.contains { $0.id == Self.lgTV.id }, "a fresh TV report stays hidden while TVs are closed")

        var renamedLight = Self.light
        renamedLight.name = "主灯"
        await provider.updateSnapshot(Self.homeSnapshot(devices: [renamedLight, Self.plug, Self.leakSensor]))
        try await awaitState { store.devices.contains { $0.name == "主灯" } }
        #expect(!store.devices.contains { $0.id == Self.lgTV.id }, "a provider snapshot does not re-insert the TV")

        #expect(store.applyDeviceCategorySelection(allTypes) == .applied)
        #expect(store.filteredDevices.contains { $0.id == Self.lgTV.id }, "reopening TVs restores the card without a new report")
        #expect(store.raycastVisibleDevices.contains { $0.id == Self.lgTV.id })
        #expect(!store.favoriteDeviceIds.contains(Self.lgTV.id), "reopening TVs keeps the user's unfavorite")
        #expect(!store.favoriteOrder.contains(Self.lgTV.id))
    }
}

private extension DeviceTypeSelectionOutcome {
    var isRefused: Bool { if case .refused = self { true } else { false } }
}

private final class CapturedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    func append(_ body: String) { lock.withLock { bodies.append(body) } }
    var last: String? { lock.withLock { bodies.last } }
}
