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

    @Test("The preview and provider retain the doorbell when safety alerts are off")
    func doorbellUsesItsOwnPreferences() async throws {
        let store = try await makeStore()
        store.enableSafetyAlerts = false
        store.doorbellAutoPopup = false
        store.doorbellChime = true
        let (_, home, _) = try HATypePruningTests.load(
            HATypePruningTests.cameras, policy: HATypePruningTests.policy(closed: [])
        )
        store.devices.append(contentsOf: home.devices)
        let (_, _, actual) = try HATypePruningTests.load(
            HATypePruningTests.cameras, policy: HATypePruningTests.policy(closed: [.camera], signals: [.doorbell])
        )

        let impact = store.previewDeviceCategorySelection(allTypes.subtracting([.camera]))
        #expect(impact.retainedSafetyDevices.map(\.id) == ["dev_doorbell"])
        #expect(actual?.safetyDevices.map(\.id) == ["dev_doorbell"])
        #expect(impact.retainedSafetyDevices.first?.signals == [.doorbell])
        #expect(store.haTypePruneBox.get().safetyPolicy.enabledSignals == [.doorbell])
        #expect(store.miotTypePruneBox.get().safetyPolicy.enabledSignals == [.doorbell])
    }

    @Test("The preview keeps the same auxiliary HA alarm as the provider")
    func auxiliaryHAAlarmAppearsInPreview() async throws {
        let store = try await makeStore()
        store.enableSafetyAlerts = true
        let (_, home, _) = try HATypePruningTests.load(HATypePruningTests.home, policy: HATypePruningTests.policy(closed: []))
        let merged = DeviceDeduplicator.merge(homeAssistant: home, xiaomiCloud: nil).home
        let valve = try #require(merged.devices.first { $0.id == "dev_valve" })
        #expect(valve.providerSafetySignals?.contains(.gas) == true)
        #expect(valve.auxiliarySafetyObservations.contains { $0.kind == .gas })
        store.devices.append(valve)
        let picked = allTypes.subtracting([valve.capabilityCategoryID])
        let (_, _, actual) = try HATypePruningTests.load(
            HATypePruningTests.home,
            policy: HATypePruningTests.policy(closed: [valve.capabilityCategoryID], signals: [.gas])
        )
        let impact = store.previewDeviceCategorySelection(picked)
        #expect(actual?.safetyDevices.contains { $0.id == valve.id } == true)
        #expect(impact.retainedSafetyDevices.first { $0.id == valve.id }?.signals == [.gas])
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

        #expect(store.applyDeviceCategorySelection(picked, pauseConfirmed: true, expectedGeneration: impact.generation) == .needsConfirmation(impact))
        #expect(store.applyDeviceCategorySelection(picked, pauseConfirmed: true, expectedPauseItemKeys: impact.pauseItemKeys) == .needsConfirmation(impact))
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: ["automationRule:other"], expectedGeneration: impact.generation
        ) == .needsConfirmation(impact))

        store.capabilityGeneration &+= 1
        let fresh = store.previewDeviceCategorySelection(picked)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: impact.pauseItemKeys, expectedGeneration: impact.generation
        ) == .needsConfirmation(fresh))
        #expect(store.capabilitySelection.enabledCategories == allTypes)
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: fresh.pauseItemKeys, expectedGeneration: fresh.generation
        ) == .applied)
        #expect(store.capabilitySelection.enabledCategories == picked)
        #expect(store.pausedScheduledCommands.map(\.command.id) == [timer.id])
    }

    @Test("A confirmed pause list must be reviewed again even when the current list is empty")
    func disappearingReferenceRequiresAnotherConfirmation() async throws {
        let store = try await makeStore()
        let picked = allTypes.subtracting([.plug])
        let current = store.previewDeviceCategorySelection(picked)
        #expect(current.pauseItemKeys.isEmpty)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: ["waitingTimer:removed"], expectedGeneration: current.generation
        ) == .needsConfirmation(current))
        #expect(store.capabilitySelection.enabledCategories == allTypes)
    }

    @Test("The picker preview observes snapshots, safety settings and favorites at the same capability generation")
    func previewObservesImpactInputs() async throws {
        let provider = MockHomeProvider(snapshot: Self.homeSnapshot())
        let store = try await makeStore(provider: provider)
        let picked = allTypes.subtracting([.sensor])
        let generation = store.capabilityGeneration
        let nextName = "水浸快照新名称"
        var renamed = Self.leakSensor
        renamed.name = nextName
        let snapshot = Self.homeSnapshot(devices: [Self.light, Self.plug, renamed])
        let update = Task { await provider.updateSnapshot(snapshot) }
        try await awaitState {
            store.previewDeviceCategorySelection(picked).hiddenCardNames == [nextName]
        }
        await update.value

        let favorite = Task { @MainActor in store.toggleFavorite(Self.leakSensor.id) }
        try await awaitState {
            store.previewDeviceCategorySelection(picked).retainedSafetyDevices.first?.signals.contains(.starredOffline) == true
        }
        await favorite.value

        let disableLeak = Task { @MainActor in store.setSensorAlertEnabled(.leak, false) }
        try await awaitState {
            store.previewDeviceCategorySelection(picked).retainedSafetyDevices.first?.signals == [.starredOffline]
        }
        await disableLeak.value

        let disableSafety = Task { @MainActor in store.enableSafetyAlerts = false }
        try await awaitState {
            store.previewDeviceCategorySelection(picked).retainedSafetyDevices.isEmpty
        }
        await disableSafety.value
        #expect(store.capabilityGeneration == generation)
    }

    @Test("A pruned real type stays blocked but the same type can be controlled in the demo provider")
    func demoWritesStayLocalAndIgnoreRealTypeSelection() async throws {
        let realProvider = MockHomeProvider(snapshot: Self.homeSnapshot())
        let store = try await makeStore(provider: realProvider)
        #expect(store.supportsCustomCameraStreams)
        let picked = allTypes.subtracting([.light, .camera])
        let preview = store.previewDeviceCategorySelection(picked)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: preview.pauseItemKeys, expectedGeneration: preview.generation
        ) == .applied)
        #expect(store.togglePrimary(Self.light) == nil)
        #expect(store.evaluateDeviceControlGate(deviceId: Self.light.id).rejectionReason == .categoryDisabled(.light))

        store.homeBackend = .demo
        #expect(store.provider is MockHomeProvider)
        #expect(store.togglePrimary(Self.light) == nil, "the backend label alone cannot exempt a real provider")
        store.switchBackend(.demo)
        #expect(store.evaluateDeviceControlGate(deviceId: Self.light.id).rejectionReason == .categoryDisabled(.light))
        try await store.waitForTestSnapshot()
        let demoProvider = try #require(store.provider as? DemoHomeProvider)
        #expect(!store.supportsCustomCameraStreams)
        let demoLight = try #require(store.devices.first { $0.id == "demo_living_light" })
        #expect(store.evaluateDeviceControlGate(deviceId: demoLight.id).allowed)
        #expect(store.evaluateDeviceControlGate(deviceId: demoLight.id, expectedGeneration: -1).rejectionReason == .staleGeneration)
        let toggle = try #require(store.togglePrimary(demoLight))
        #expect(await toggle.value)
        let demoCamera = try #require(store.devices.first { $0.capabilityCategoryID == .camera })
        store.setCameraCustomStreamURL("https://example.test/demo.m3u8", for: demoCamera.id)
        guard case .demo(let streamID) = try await store.resolveCameraStream(for: demoCamera.id) else {
            Issue.record("the demo camera must stay on the synthetic stream")
            return
        }
        #expect(streamID == demoCamera.id)

        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(), onDeviceUpdated: { _ in }, onClientKeyRegistered: { _ in }, onSecurityFailure: { _ in }
        )
        let lanCommand = DeviceCommand.mediaSetVolume(entityId: LGWebOSProtocol.mediaEntityId, volumeLevel: 0.5)
        try await store.executeDeviceCommand(lanCommand)
        #expect(await demoProvider.executedCommands == [
            .setLightPower(entityId: "light.demo_living_ceiling", isOn: false), lanCommand,
        ])
        #expect(await realProvider.executedCommands.isEmpty)
        #expect(store.capabilitySelection.enabledCategories == picked)
    }

    @Test("Quick action pauses name the type or connection in each shipped language")
    func pausedQuickActionToastNamesTheCause() async throws {
        let provider = MockHomeProvider(snapshot: Self.homeSnapshot())
        let store = try await makeStore(provider: provider)
        let picked = allTypes.subtracting([.light])
        let preview = store.previewDeviceCategorySelection(picked)
        #expect(store.applyDeviceCategorySelection(
            picked, pauseConfirmed: true, expectedPauseItemKeys: preview.pauseItemKeys, expectedGeneration: preview.generation
        ) == .applied)

        let messages: [(AppLanguage, String, String)] = [
            (.zhHans, "该快捷动作因设备类型关闭已暂停", "该快捷动作因连接停用已暂停"),
            (.zhHant, "該捷徑動作因裝置類型關閉已暫停", "該捷徑動作因連線停用已暫停"),
            (.en, "This quick action is paused while a device type is turned off",
             "This quick action is paused while its connection is disabled"),
        ]
        for (language, typeMessage, _) in messages {
            L10n.$overrideLanguage.withValue(language) {
                #expect(store.executeQuickAction(.lightsOff) == nil)
                #expect(store.toastNotice?.message == typeMessage)
            }
        }
        #expect(store.applyDeviceCategorySelection(allTypes) == .applied)
        guard case .requiresPauseConfirmation = store.previewSetHAConnectionEnabled(false).disposition else {
            Issue.record("disabling the connection must pause its quick action")
            return
        }
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true)
        for (language, _, connectionMessage) in messages {
            L10n.$overrideLanguage.withValue(language) {
                #expect(store.executeQuickAction(.lightsOff) == nil)
                #expect(store.toastNotice?.message == connectionMessage)
            }
        }
        #expect(await provider.executedCommands.isEmpty)
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
        let uncertainDefaults = InMemoryUserDefaults()
        uncertainDefaults.set(true, forKey: "has_completed_onboarding")
        let uncertain = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light], scenes: [])),
            credentialVault: CredentialVault(storage: mem.storage),
            defaults: uncertainDefaults
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

        #expect(store.applyDeviceCategorySelection(allTypes.subtracting([.tv])) == .applied)
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.lgTV.id], "a favorited TV keeps its offline alert")
        #expect(store.applyDeviceCategorySelection(allTypes) == .applied)
        store.toggleFavorite(Self.lgTV.id)
        #expect(!store.favoriteDeviceIds.contains(Self.lgTV.id))

        #expect(store.applyDeviceCategorySelection(allTypes.subtracting([.tv])) == .applied)
        #expect(store.typeHiddenSafetyDevices.isEmpty, "an unfavorited TV leaves the safety set")
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
