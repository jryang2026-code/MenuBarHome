import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// P3b-M on the host side: a closed Home Assistant type answers 「该设备类型已关闭」 with zero writes
/// on every entry, keeps the alerts the user left on, and its retained set follows the connection.
@MainActor
struct HATypePruneStoreTests {
    static let haURL = "http://192.168.1.60:8123"

    static let hiddenPlug = SmartDevice(
        id: "dev_plug", name: "阳台取暖器", roomId: "balcony", roomName: "阳台",
        model: "ha.switch", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.balcony_heater", isOn: true))
    )

    static let leakSensor = SmartDevice(
        id: "dev_leak", name: "厨房水浸", roomId: "kitchen", roomName: "厨房",
        model: "ha.sensor", isOnline: true,
        kind: .sensor(SensorSpec(
            battery: 90,
            observations: [SensorObservation(sourceId: "dev_leak#binary_sensor.kitchen_leak", kind: .leak, alarming: true)]
        ))
    )

    static let visibleLight = SmartDevice(
        id: "dev_light", name: "吸顶灯", roomId: "living", roomName: "客厅",
        model: "ha.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true))
    )

    private func makeStore(closed: Set<DeviceCategoryID>) async throws -> (HomeStore, MockHomeProvider) {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(Self.haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)
        var snapshot = SynthesizedHome(devices: [Self.visibleLight], scenes: [HomeScene(id: "scene.movie", name: "观影", entityId: "scene.movie")])
        snapshot.isInitialLoadComplete = true
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil
        var selection = store.capabilitySelection
        selection.enabledCategories.subtract(closed)
        store.capabilitySelection = selection
        #expect(store.isHAConnectionEnabled)
        return (store, mock)
    }

    private func report(_ store: HomeStore, hidden: [SmartDevice], safety: [SmartDevice] = [], scope: String? = nil) -> MiotTypePruneReport {
        let scope = scope ?? store.homeAssistantScopeIdentifier
        return MiotTypePruneReport(
            scope: scope,
            hiddenIndexedDevices: hidden.map { device in
                let keys = device.referencedEntityIds.isEmpty ? [device.id] : device.referencedEntityIds
                return CapabilityIndexedDevice(
                    id: device.id, name: device.name, category: device.capabilityCategoryID,
                    connection: .homeAssistant, sourceScope: scope,
                    isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
                    safetySignals: [], readKeys: keys, safetyReadKeys: keys
                )
            },
            hiddenDeviceIds: Set(hidden.map(\.id)).subtracting(safety.map(\.id)),
            safetyDevices: safety
        )
    }

    @Test("Every write entry refuses a closed Home Assistant type with 「该设备类型已关闭」 and zero writes")
    func everyEntryRefusesAClosedType() async throws {
        let (store, mock) = try await makeStore(closed: [.plug])
        store.handleProviderEvent(.haTypePruneChanged(report(store, hidden: [Self.hiddenPlug])))
        let closed = ControlTargetRejectionReason.categoryDisabled(.plug).userMessage
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in prompts += 1; return true }

        let gate = store.evaluateDeviceControlGate(deviceId: Self.hiddenPlug.id)
        #expect(gate.rejectionReason == .categoryDisabled(.plug) && gate.writeCount == 0)
        #expect(store.evaluateDeviceControlGate(deviceId: "dev_ghost").rejectionReason == .deviceNotFound)

        // Card.
        #expect(store.togglePrimary(Self.hiddenPlug) == nil)
        #expect(store.toastNotice?.message == closed)
        // A stored entity command (undo, timer) finds its hidden owner by entity id.
        await #expect(throws: CapabilityControlBlockedError(reason: .categoryDisabled(.plug))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "switch.balcony_heater", isOn: false))
        }
        // Intent plan: a mixed plan is refused whole, so the visible light is not written either.
        let plan = IntentPlan(
            intents: [
                DeviceIntent(targetId: Self.visibleLight.id, operation: .power(false)),
                DeviceIntent(targetId: Self.hiddenPlug.id, operation: .power(false)),
            ],
            reply: "关灯和取暖器", source: .model
        )
        let result = await store.executeIntentPlan(plan, recordedUtterance: "关灯和取暖器", origin: .userInitiated)
        #expect(result.intents.isEmpty && result.reply == closed)
        // Automation.
        let outcome = await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.hiddenPlug.id, operation: .power(false))], title: "睡前"
        )
        #expect(outcome.succeededCount == 0 && outcome.errorMessage == closed)
        // Voice undo.
        store.lastAssistantUndo = AssistantUndoEntry(
            actionId: UUID(), reply: "已关闭取暖器",
            restore: [.setSwitch(entityId: "switch.balcony_heater", isOn: true)],
            previous: [Self.hiddenPlug], at: Date(), habitReceipt: nil
        )
        await L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(UndoPhrase.isUndo("撤銷"))
            _ = await store.runAssistantCommand("撤銷")
            #expect(store.assistantState == .failed("有 1 項未能復原。請在設定中重新開啟「插座與開關」裝置類型。接著再說或輸入「撤銷」。"))
            #expect(store.toastNotice?.message == "有 1 項未能復原。請在設定中重新開啟「插座與開關」裝置類型。接著再說或輸入「撤銷」。")
        }
        // Companion (Raycast).
        let raycast = await store.executeRaycastPower(deviceId: Self.hiddenPlug.id, isOn: false)
        #expect(raycast.isError && raycast.message == closed)

        #expect(prompts == 0, "the gate runs before any confirmation")
        #expect(await mock.executedCommands.isEmpty)
        // Scenes are never pruned: the platform scene stays on the scene bar.
        #expect(store.visibleScenes.map(\.id) == ["scene.movie"])
    }

    @Test("A closed sensor type keeps evaluating its enabled leak alert without drawing the card")
    func retainedSensorStillAlerts() async throws {
        let (store, _) = try await makeStore(closed: [.sensor])
        store.handleProviderEvent(.haTypePruneChanged(report(store, hidden: [Self.leakSensor], safety: [Self.leakSensor])))
        #expect(!store.devices.contains { $0.id == Self.leakSensor.id })
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.leakSensor.id])
        #expect(store.menuBarShowsHazard)
        #expect(store.recentSafetyAlerts.contains { $0.alert.deviceId == Self.leakSensor.id })
    }

    @Test("The retained set follows the connection: another address or a disabled connection keeps nothing")
    func retainedSetFollowsTheConnection() async throws {
        let (store, _) = try await makeStore(closed: [.sensor])
        store.handleProviderEvent(.haTypePruneChanged(report(store, hidden: [Self.leakSensor], safety: [Self.leakSensor], scope: "ha:http://old.local:8123")))
        #expect(store.typeHiddenSafetyDevices.isEmpty, "a report from a replaced address is dropped")

        store.handleProviderEvent(.haTypePruneChanged(report(store, hidden: [Self.leakSensor], safety: [Self.leakSensor])))
        #expect(store.typeHiddenSafetyDevices.count == 1)
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.typeHiddenSafetyDevices.isEmpty)
        store.handleProviderEvent(.haTypePruneChanged(report(store, hidden: [Self.leakSensor], safety: [Self.leakSensor])))
        #expect(store.typeHiddenSafetyDevices.isEmpty, "a late report from a disabled connection is dropped")
        #expect(
            store.evaluateDeviceControlGate(deviceId: Self.leakSensor.id).rejectionReason
                == .connectionDisabled(.homeAssistant, scope: store.homeAssistantScopeIdentifier),
            "the identity stays, so the disabled connection is named"
        )
    }

    @Test("The published Home Assistant policy carries the selection, alert switches and its address")
    func publishedPolicyMatchesTheHost() async throws {
        let (store, _) = try await makeStore(closed: [.cover])
        store.syncMiotTypePrunePolicy()
        let policy = store.haTypePruneBox.get()
        #expect(policy.sourceScope == store.homeAssistantScopeIdentifier)
        #expect(policy.selection == store.capabilitySelection)
        #expect(!policy.prunesNothing)
        #expect(policy.safetyPolicy == store.miotTypePruneBox.get().safetyPolicy)
        store.setSensorAlertEnabled(.motion, true)
        #expect(store.haTypePruneBox.get().safetyPolicy.enabledSignals.contains(.motion))
    }
}
