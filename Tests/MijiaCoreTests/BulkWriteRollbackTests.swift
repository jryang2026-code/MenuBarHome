import Foundation
import Testing
@testable import MijiaCore

/// A quick action or 全关 shows every target row before the devices answer. A device that refuses
/// must get its pre-action row back, leave this action's undo banner, and surface an error instead
/// of sitting on a fake state behind a 3 s polling lock.
struct BulkWriteRollbackTests {
    private static let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(
            entityId: "light.ceiling", isOn: true, brightnessPercent: 80, colorTempKelvin: 4000
        ))
    )
    private static let deskLamp = SmartDevice(
        id: "dev_desk", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(
            entityId: "light.desk", isOn: true, brightnessPercent: 60, colorTempKelvin: 5000
        ))
    )
    private static let ac = SmartDevice(
        id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mt0", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
            targetTemperature: 25
        ))
    )

    @MainActor
    private func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.bulkrollback.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    /// Bounded poll for a deterministic signal instead of a fixed sleep (CODING_STANDARDS §9).
    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was never satisfied")
    }

    @Test("A refused 全关 device keeps its previous row and leaves the undo banner")
    @MainActor
    func partialFailureRollsBackOnlyTheFailedDevice() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.ac])
        await mock.setFailingTargets(["climate.ac"])

        let task = store.turnAllOff()
        // Freeze the banner so a loaded CI cannot expire it mid-test (CODING_STANDARDS §9).
        store.pauseUndoBannerCountdown()
        await task?.value

        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == false)
        let ac = try #require(store.devices.first { $0.id == "dev_ac" })
        #expect(ac.isActiveOn, "the refused device keeps its pre-action row")
        if case .climate(let spec) = ac.kind {
            #expect(spec.hvacMode == "cool")
        } else {
            Issue.record("expected the air conditioner row, got \(ac.kind)")
        }
        #expect(store.optimisticLockUntil["dev_ac"] == nil, "a failed write must not keep polling out")

        let banner = try #require(store.undoBanner)
        #expect(banner.restoreCommands == [.setLightPower(entityId: "light.ceiling", isOn: true)])
        #expect(banner.previousDevices.map(\.id) == ["dev_ceiling"])
        #expect(banner.deviceCount == 1)
        #expect(banner.title == "已关闭 1 台设备")
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("客厅空调") == true)
        // Habits train only for the device that accepted, and the trimmed banner stays this
        // action's banner so the receipt can still be attached to it.
        #expect(store.userHabitMemory.entries.map { "\($0.targetId)|\($0.operationKey)" } == ["dev_ceiling|power:off"])
        #expect(store.undoBanner?.habitReceipt != nil)

        await store.undoTurnAllOff()?.value
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "dev_ac" }?.isActiveOn == true)
    }

    @Test("A device with two commands is rolled back once and leaves both restore commands")
    @MainActor
    func multiCommandDeviceRollsBackOnce() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.setFailingTargets(["light.desk"])

        let task = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await task?.value

        let ceiling = try #require(store.devices.first { $0.id == "dev_ceiling" })
        if case .light(let spec) = ceiling.kind {
            #expect(spec.isOn)
            #expect(spec.brightnessPercent == 15)
            #expect(spec.colorTempKelvin == 2700)
        } else {
            Issue.record("expected the ceiling light row, got \(ceiling.kind)")
        }

        let desk = try #require(store.devices.first { $0.id == "dev_desk" })
        if case .light(let spec) = desk.kind {
            #expect(spec.isOn)
            #expect(spec.brightnessPercent == 60, "one rollback restores both commands")
            #expect(spec.colorTempKelvin == 5000)
        } else {
            Issue.record("expected the desk lamp row, got \(desk.kind)")
        }

        let banner = try #require(store.undoBanner)
        #expect(banner.restoreCommands == [
            .setLightBrightness(entityId: "light.ceiling", percent: 80),
            .setLightColorTemp(entityId: "light.ceiling", kelvin: 4000),
        ])
        #expect(banner.previousDevices.map(\.id) == ["dev_ceiling"])
        #expect(store.toastNotice?.message.contains("书房台灯") == true)
    }

    @Test("When every device refuses, the banner goes away and nothing stays locked")
    @MainActor
    func totalFailureRemovesTheBanner() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.ac])
        await mock.setShouldFail(true)

        let task = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await task?.value

        #expect(store.undoBanner == nil)
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "dev_ac" }?.isActiveOn == true)
        #expect(store.optimisticLockUntil.isEmpty)
        #expect(store.toastNotice?.isError == true)
    }

    @Test("A row a newer write took is not rolled back when the batch command fails")
    @MainActor
    func newerWriteKeepsItsRow() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        store.controlDebounceInterval = .zero
        await mock.holdNextExecute()

        let task = store.executeQuickAction(.lightsOff)
        store.pauseUndoBannerCountdown()
        try await waitUntil { await mock.executeStarted > 0 }

        // A newer write takes the row while the batch command is still in flight.
        store.setLightBrightness("dev_ceiling", percent: 42)
        try await waitUntil {
            await mock.executedCommands.contains(
                .setLightBrightness(entityId: "light.ceiling", percent: 42)
            )
        }

        // The batch command then fails; its rollback must not overwrite the newer write.
        await mock.setFailingTargets(["light.ceiling"])
        await mock.releaseExecute()
        await task?.value

        let light = try #require(store.devices.first { $0.id == "dev_ceiling" })
        #expect(light.isActiveOn, "the newer write's row survives the failed batch")
        if case .light(let spec) = light.kind {
            #expect(spec.brightnessPercent == 42)
        } else {
            Issue.record("expected the ceiling light row, got \(light.kind)")
        }
    }

    @Test("A context change in the middle of a batch reports nothing and rolls back nothing")
    @MainActor
    func contextChangeMidBatchDoesNothing() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.holdNextExecute()

        let task = store.turnAllOff()
        try await waitUntil { await mock.executeStarted > 0 }

        store.invalidateUndoContext()
        await mock.setShouldFail(true)
        await mock.releaseExecute()
        await task?.value

        #expect(store.undoBanner == nil)
        #expect(store.toastNotice == nil, "a home that is no longer on screen reports nothing")
        #expect(
            store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == false,
            "no rollback after the context moved on"
        )
    }

    @Test("A device that accepted one command keeps its row and undo entry when the next one fails")
    @MainActor
    func partlyAppliedDeviceKeepsItsRowAndBanner() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.setFailingCommands { command in
            if case .setLightColorTemp = command { return true }
            return false
        }

        let task = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await task?.value

        // The brightness write turned the lamp on, so the card must not claim it is off again and
        // 撤销 must stay available to turn it back off.
        let light = try #require(store.devices.first { $0.id == "dev_ceiling" })
        #expect(light.isActiveOn)
        if case .light(let spec) = light.kind {
            #expect(spec.brightnessPercent == 15)
        } else {
            Issue.record("expected the ceiling light row, got \(light.kind)")
        }
        let banner = try #require(store.undoBanner, "undo must still turn the light back off")
        #expect(banner.restoreCommands == [
            .setLightBrightness(entityId: "light.ceiling", percent: 80),
            .setLightColorTemp(entityId: "light.ceiling", kelvin: 4000),
        ])
        #expect(banner.previousDevices.map(\.id) == ["dev_ceiling"])
        #expect(banner.deviceCount == 1)
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("客厅吸顶灯") == true)
        #expect(store.toastNotice?.message.contains("只生效了一部分") == true)
        #expect(await mock.executedCommands == [.setLightBrightness(entityId: "light.ceiling", percent: 15)])
        #expect(store.userHabitMemory.entries.isEmpty, "habits train only on fully applied devices")
    }

    @Test("After a device's command fails, its remaining commands are not sent")
    @MainActor
    func failureStopsRemainingCommandsForThatDevice() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.setFailingCommands { command in
            if case .setLightBrightness = command { return true }
            return false
        }

        let task = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await task?.value

        #expect(await mock.executeStarted == 1, "the colour command must not follow the failed brightness write")
        #expect(await mock.executedCommands.isEmpty)
        // Nothing was accepted, so the row and the banner go back to the pre-action state.
        #expect(store.undoBanner == nil)
        let light = try #require(store.devices.first { $0.id == "dev_ceiling" })
        if case .light(let spec) = light.kind {
            #expect(spec.isOn)
            #expect(spec.brightnessPercent == 80)
            #expect(spec.colorTempKelvin == 4000)
        } else {
            Issue.record("expected the ceiling light row, got \(light.kind)")
        }
        #expect(store.toastNotice?.message.contains("未响应") == true)
    }

    @Test("A report that lands after a failed device's lock expired is not overwritten")
    @MainActor
    func expiredLockSkipsTheRevert() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.setFailingTargets(["light.ceiling"])
        await mock.setFailingCommands { command in
            if case .setLightPower(let entityId, _) = command, entityId == "light.desk" { return true }
            return false
        }
        await mock.holdNextExecute(forTarget: "light.desk")

        let task = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        // The first device fails; the second is still inside the provider.
        try await waitUntil { await mock.executeStarted == 2 }

        // The 3 s lock runs out and the device's own report lands before the batch finishes.
        store.optimisticLockUntil.removeValue(forKey: "dev_ceiling")
        var moved = Self.ceiling
        if case .light(var spec) = moved.kind {
            spec.brightnessPercent = 42
            moved.kind = .light(spec)
        }
        let before = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [moved, Self.deskLamp]))
        try await waitUntil { store.snapshotGeneration > before }
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)

        await mock.releaseExecute()
        await task?.value

        // The batch must leave the fresher row alone: it no longer owns the device.
        let light = try #require(store.devices.first { $0.id == "dev_ceiling" })
        #expect(light.isActiveOn)
        if case .light(let spec) = light.kind {
            #expect(spec.brightnessPercent == 42)
        } else {
            Issue.record("expected the ceiling light row, got \(light.kind)")
        }
        #expect(store.toastNotice?.message.contains("客厅吸顶灯") == true)
        #expect(store.undoBanner == nil, "both devices refused, so the banner has nothing to offer")
    }

    @Test("turnAllOff hands back the task that sends its commands")
    @MainActor
    func turnAllOffReturnsItsTask() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        let task = store.turnAllOff()
        #expect(task != nil)
        // Freeze the banner so a loaded CI cannot expire it mid-test (CODING_STANDARDS §9).
        store.pauseUndoBannerCountdown()
        await task?.value
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.ceiling", isOn: false)])
    }
}
