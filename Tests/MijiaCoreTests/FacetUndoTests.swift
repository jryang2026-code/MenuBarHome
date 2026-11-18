import Foundation
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FacetUndoTests {
    private func light(_ id: String, entityId: String) -> SmartDevice {
        SmartDevice(
            id: id, name: id, roomId: "room", roomName: "room", model: "test.light",
            isOnline: true, kind: .light(LightSpec(entityId: entityId, isOn: true))
        )
    }

    private func facet(entityId: String, id: String = "3.2", value: Double = 1) -> FacetControl {
        FacetControl(
            id: id, kind: .select, name: "mode", title: "Mode", serviceName: "light",
            value: .number(value), isWritable: true, writesByDefault: true, isHighValue: true,
            target: .property(entityId: entityId, piid: 2)
        )
    }

    private func makeStore(
        devices: [SmartDevice], facets: [String: [FacetControl]]
    ) async throws -> (HomeStore, MockHomeProvider) {
        var snapshot = SynthesizedHome(devices: devices)
        snapshot.deviceFacets = facets
        let provider = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.facet.undo.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    private func offerUndo(_ store: HomeStore, command: DeviceCommand) {
        store.scheduleUndoBanner(
            title: "Updated mode", restoreCommands: [command], previousDevices: store.devices,
            deviceCount: 1
        )
        store.pauseUndoBannerCountdown()
    }

    @Test("Facet undo finds the Xiaomi target on a paired Home Assistant card")
    func pairedCardUndoFindsFacetOwner() async throws {
        let target = "miot:mi-light:3"
        let device = light("ha-light", entityId: "light.living")
        let (store, provider) = try await makeStore(
            devices: [device], facets: [device.id: [facet(entityId: target)]]
        )
        let command = DeviceCommand.setMiotProperty(entityId: target, piid: 2, value: .number(0))
        offerUndo(store, command: command)
        let task = try #require(store.undoTurnAllOff())
        #expect(store.deviceFacets[device.id]?.first?.value == .number(0))
        #expect(store.optimisticLockUntil[device.id] != nil)
        await task.value
        #expect(await provider.executedCommands == [command])
    }

    @Test("Facet undo locks and restores the addressed split card instead of its sibling")
    func splitCardUndoKeepsSibling() async throws {
        let first = light("100.s2", entityId: "miot:100:2")
        let second = light("100.s3", entityId: "miot:100:3")
        let target = "miot:100:3"
        let (store, provider) = try await makeStore(
            devices: [first, second],
            facets: [first.id: [facet(entityId: "miot:100:2", id: "2.2")],
                     second.id: [facet(entityId: target)]]
        )
        let command = DeviceCommand.setMiotProperty(entityId: target, piid: 2, value: .number(0))
        offerUndo(store, command: command)
        let task = try #require(store.undoTurnAllOff())
        #expect(store.deviceFacets[first.id]?.first?.value == .number(1))
        #expect(store.optimisticLockUntil[first.id] == nil)
        #expect(store.deviceFacets[second.id]?.first?.value == .number(0))
        #expect(store.optimisticLockUntil[second.id] != nil)
        await task.value
        #expect(await provider.executedCommands == [command])
    }

    @Test("A failed facet undo restores the pre-undo value and keeps the command available to retry")
    func failedUndoRestoresFacetValue() async throws {
        let device = light("light", entityId: "miot:light:2")
        let target = "miot:light:3"
        let (store, provider) = try await makeStore(
            devices: [device], facets: [device.id: [facet(entityId: target)]]
        )
        let command = DeviceCommand.setMiotProperty(entityId: target, piid: 2, value: .number(0))
        offerUndo(store, command: command)
        await provider.setShouldFail(true)
        let task = try #require(store.undoTurnAllOff())
        #expect(store.deviceFacets[device.id]?.first?.value == .number(0))
        await task.value
        store.pauseUndoBannerCountdown()
        #expect(store.deviceFacets[device.id]?.first?.value == .number(1))
        #expect(store.undoBanner?.restoreCommands == [command])
        #expect(store.optimisticLockUntil[device.id] == nil)
        await provider.setShouldFail(false)
        let retry = try #require(store.undoTurnAllOff())
        await retry.value
        #expect(store.deviceFacets[device.id]?.first?.value == .number(0))
        #expect(await provider.executedCommands == [command])
    }

    @Test("A failed voice undo restores facet values along with device rows")
    func failedVoiceUndoRestoresFacetValue() async throws {
        let device = light("light", entityId: "miot:light:2")
        let target = "miot:light:3"
        let (store, provider) = try await makeStore(
            devices: [device], facets: [device.id: [facet(entityId: target)]]
        )
        let command = DeviceCommand.setMiotProperty(entityId: target, piid: 2, value: .number(0))
        store.lastAssistantUndo = (
            reply: "Updated mode", restore: [command], previous: store.devices,
            at: Date(), habitReceipt: nil
        )
        await provider.setShouldFail(true)
        _ = await store.runAssistantCommand("撤销")
        #expect(store.deviceFacets[device.id]?.first?.value == .number(1))
        #expect(store.lastAssistantUndo?.restore == [command])
    }
    @Test("An offline facet owner never falls back to its online split sibling")
    func offlineSplitOwnerIsNotRetargeted() async throws {
        let first = light("100.s2", entityId: "miot:100:2")
        var second = light("100.s3", entityId: "miot:100:3")
        second.isOnline = false
        let (store, provider) = try await makeStore(
            devices: [first, second],
            facets: [first.id: [facet(entityId: "miot:100:2", id: "2.2")],
                     second.id: [facet(entityId: "miot:100:3")]]
        )
        offerUndo(store, command: .setMiotProperty(entityId: "miot:100:3", piid: 2, value: .number(0)))
        let task = store.undoTurnAllOff()
        #expect(task == nil)
        #expect(store.optimisticLockUntil[first.id] == nil)
        #expect(store.deviceFacets[first.id]?.first?.value == .number(1))
        #expect(await provider.executedCommands.isEmpty)
    }

    // MARK: - Restored values are judged like the tap that changed them

    private func heater(_ id: String, entityId: String) -> SmartDevice {
        SmartDevice(
            id: id, name: "取暖器", roomId: "room", roomName: "room", model: "xiaomi.heater.v1",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: entityId, isOn: true, hvacMode: "heat",
                availableModes: ["off", "heat"], targetTemperature: 22, minTemp: 16, maxTemp: 32
            ))
        )
    }

    /// An auxiliary switch on a heater, the shape 更多设置 shows as a toggle.
    private func auxiliarySwitch(entityId: String, current: JSONValue) -> FacetControl {
        FacetControl(
            id: "3.1", kind: .toggle, name: "on", title: "辅助加热", serviceName: "auxiliary",
            value: current, isWritable: true, writesByDefault: true, isHighValue: true,
            target: .property(entityId: entityId, piid: 1)
        )
    }

    @Test("Undoing an auxiliary switch back on asks before the heater is restored")
    func heaterFacetUndoAsks() async throws {
        let device = heater("heater", entityId: "miot:heater:2")
        let command = DeviceCommand.setMiotProperty(entityId: "miot:heater:3", piid: 1, value: .bool(true))
        let (store, provider) = try await makeStore(
            devices: [device],
            facets: [device.id: [auxiliarySwitch(entityId: "miot:heater:3", current: .bool(false))]]
        )
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }
        offerUndo(store, command: command)
        let task = try #require(store.undoTurnAllOff())
        #expect(prompts == 1, "turning the auxiliary switch back on is a heating write")
        await task.value
        #expect(await provider.executedCommands == [command])
    }

    @Test("Declining the undo prompt keeps the heater's restore command unsent")
    func heaterFacetUndoDeclined() async throws {
        let device = heater("heater", entityId: "miot:heater:2")
        let command = DeviceCommand.setMiotProperty(entityId: "miot:heater:3", piid: 1, value: .bool(true))
        let (store, provider) = try await makeStore(
            devices: [device],
            facets: [device.id: [auxiliarySwitch(entityId: "miot:heater:3", current: .bool(false))]]
        )
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        offerUndo(store, command: command)
        #expect(store.undoTurnAllOff() == nil)
        #expect(prompts == 1)
        #expect(store.undoBanner != nil, "a declined undo stays available to retry")
        #expect(store.deviceFacets[device.id]?.first?.value == .bool(false), "the refused restore never shows")
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test("A low-risk facet undo never asks")
    func lowRiskFacetUndoIsDirect() async throws {
        let device = light("light", entityId: "miot:light:2")
        let (store, provider) = try await makeStore(
            devices: [device], facets: [device.id: [facet(entityId: "miot:light:3")]]
        )
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let command = DeviceCommand.setMiotProperty(entityId: "miot:light:3", piid: 2, value: .number(0))
        offerUndo(store, command: command)
        let task = try #require(store.undoTurnAllOff())
        await task.value
        #expect(prompts == 0)
        #expect(await provider.executedCommands == [command])
    }

    /// A low-risk row on the same heater, so 更多设置 has one restore that never asks.
    private func autoOffFacet(entityId: String) -> FacetControl {
        FacetControl(
            id: "4.1", kind: .toggle, name: "auto-off", title: "无人自动关机", serviceName: "setting",
            value: .bool(false), isWritable: true, writesByDefault: true, isHighValue: true,
            target: .property(entityId: entityId, piid: 4)
        )
    }

    private func offerUndo(_ store: HomeStore, commands: [DeviceCommand]) {
        store.scheduleUndoBanner(
            title: "Updated settings", restoreCommands: commands, previousDevices: store.devices,
            deviceCount: 1
        )
        store.pauseUndoBannerCountdown()
    }

    @Test("A declined restore takes the same device's earlier approval with it")
    func declinedRestoreWithdrawsSameDeviceApproval() async throws {
        let device = heater("heater", entityId: "miot:heater:2")
        let autoOff = DeviceCommand.setMiotProperty(entityId: "miot:heater:4", piid: 4, value: .bool(true))
        let heating = DeviceCommand.setMiotProperty(entityId: "miot:heater:3", piid: 1, value: .bool(true))
        let facets = [device.id: [
            autoOffFacet(entityId: "miot:heater:4"),
            auxiliarySwitch(entityId: "miot:heater:3", current: .bool(false)),
        ]]
        let (store, provider) = try await makeStore(devices: [device], facets: facets)
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        // The low-risk row is approved on its own; the heating restore on the same device is refused.
        offerUndo(store, commands: [autoOff, heating])
        #expect(store.undoTurnAllOff() == nil)
        #expect(prompts == 1)
        #expect(store.undoBanner?.restoreCommands == [autoOff, heating], "a refused undo stays retryable")
        #expect(await provider.executedCommands.isEmpty)

        let (voiceStore, voiceProvider) = try await makeStore(devices: [device], facets: facets)
        var voicePrompts = 0
        voiceStore.manualControlConfirmationHandler = { _ in
            voicePrompts += 1
            return false
        }
        voiceStore.lastAssistantUndo = (
            reply: "Updated settings", restore: [autoOff, heating], previous: voiceStore.devices,
            at: Date(), habitReceipt: nil
        )
        _ = await voiceStore.runAssistantCommand("撤销")
        #expect(voicePrompts == 1)
        #expect(voiceStore.lastAssistantUndo?.restore == [autoOff, heating], "voice undo stays retryable")
        #expect(await voiceProvider.executedCommands.isEmpty)
    }

    @Test("A refused device does not stop another approved device from undoing")
    func refusedDeviceDoesNotBlockAnotherDevice() async throws {
        let hot = heater("heater", entityId: "miot:heater:2")
        let lamp = light("light", entityId: "miot:light:2")
        let heating = DeviceCommand.setMiotProperty(entityId: "miot:heater:3", piid: 1, value: .bool(true))
        let lampMode = DeviceCommand.setMiotProperty(entityId: "miot:light:3", piid: 2, value: .number(0))
        let (store, provider) = try await makeStore(
            devices: [hot, lamp],
            facets: [hot.id: [auxiliarySwitch(entityId: "miot:heater:3", current: .bool(false))],
                     lamp.id: [facet(entityId: "miot:light:3")]]
        )
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        offerUndo(store, commands: [heating, lampMode])
        let task = try #require(store.undoTurnAllOff())
        #expect(prompts == 1, "only the heater heats again; the lamp's mode is low risk")
        await task.value
        #expect(await provider.executedCommands == [lampMode])
        #expect(store.deviceFacets[lamp.id]?.first?.value == .number(0))
        #expect(store.deviceFacets[hot.id]?.first?.value == .bool(false), "the refused device never shows")
    }

    @Test("A de-escalating facet undo stays direct")
    func deescalatingFacetUndoIsDirect() async throws {
        let device = heater("heater", entityId: "miot:heater:2")
        let (store, provider) = try await makeStore(
            devices: [device],
            facets: [device.id: [auxiliarySwitch(entityId: "miot:heater:3", current: .bool(true))]]
        )
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let command = DeviceCommand.setMiotProperty(entityId: "miot:heater:3", piid: 1, value: .bool(false))
        offerUndo(store, command: command)
        let task = try #require(store.undoTurnAllOff())
        await task.value
        #expect(prompts == 0, "restoring the off state makes the home safer")
        #expect(await provider.executedCommands == [command])
    }

    @Test("An undecodable MIoT restore on a high-risk card asks, on a light it does not")
    func undecodedMiotRestoreFollowsDeviceHazard() async throws {
        let hot = heater("heater", entityId: "miot:heater:2")
        let (hotStore, hotProvider) = try await makeStore(devices: [hot], facets: [:])
        var hotPrompts = 0
        hotStore.manualControlConfirmationHandler = { _ in
            hotPrompts += 1
            return false
        }
        let hotCommand = DeviceCommand.setMiotProperty(entityId: "miot:heater:9", piid: 5, value: .number(1))
        offerUndo(hotStore, command: hotCommand)
        #expect(hotStore.undoTurnAllOff() == nil)
        #expect(hotPrompts == 1, "no facet row explains the restore, so the heater hazard decides")
        #expect(await hotProvider.executedCommands.isEmpty)

        let lamp = light("light", entityId: "miot:light:2")
        let (lampStore, lampProvider) = try await makeStore(devices: [lamp], facets: [:])
        var lampPrompts = 0
        lampStore.manualControlConfirmationHandler = { _ in
            lampPrompts += 1
            return false
        }
        let lampCommand = DeviceCommand.setMiotProperty(entityId: "miot:light:9", piid: 5, value: .number(1))
        offerUndo(lampStore, command: lampCommand)
        let task = try #require(lampStore.undoTurnAllOff())
        await task.value
        #expect(lampPrompts == 0)
        #expect(await lampProvider.executedCommands == [lampCommand])
    }

}
