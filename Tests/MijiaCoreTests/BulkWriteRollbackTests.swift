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
        // Freeze the toast so a loaded CI cannot dismiss it before the assertions (CODING_STANDARDS §9).
        store.toastAutoDismissInterval = nil
        return (store, mock)
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
        await waitUntil { await mock.executeStarted > 0 }

        // A newer write takes the row while the batch command is still in flight.
        store.setLightBrightness("dev_ceiling", percent: 42)
        await waitUntil {
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
        await waitUntil { await mock.executeStarted > 0 }

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
        #expect(store.runningBatches.isEmpty, "the stopped batch leaves no registration behind")
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

    @Test("A failed device whose lock ran out is still rolled back when no report arrived")
    @MainActor
    func expiredLockWithoutSnapshotStillReverts() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.setFailingTargets(["light.ceiling"])

        let task = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        // The 3 s window ran out, but the device never reported, so the row is still the fake one.
        store.optimisticLockUntil["dev_ceiling"] = ContinuousClock.now.advanced(by: .milliseconds(-1))
        await task?.value

        #expect(
            store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true,
            "the fake off state is rolled back even though the lock expired"
        )
        #expect(store.optimisticLockUntil["dev_ceiling"] == nil)
        #expect(store.undoBanner == nil)
        #expect(store.toastNotice?.message.contains("客厅吸顶灯") == true)
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
        await waitUntil { await mock.executeStarted == 2 }

        // The lock runs out and the device's own report lands before the batch finishes.
        store.optimisticLockUntil["dev_ceiling"] = ContinuousClock.now.advanced(by: .milliseconds(-1))
        var moved = Self.ceiling
        if case .light(var spec) = moved.kind {
            spec.brightnessPercent = 42
            moved.kind = .light(spec)
        }
        let before = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [moved, Self.deskLamp]))
        await waitUntil { store.snapshotGeneration > before }
        #expect(store.optimisticLockUntil["dev_ceiling"] == nil, "applying the report drops the expired entry")
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

    @Test("An LG report that repeats the row the batch showed still counts as a takeover")
    @MainActor
    func equalLGReportTakesTheRow() async throws {
        let tv = SmartDevice(
            id: LGWebOSProtocol.deviceId, name: "LG C2 电视", roomId: "ke_ting", roomName: "客厅",
            model: "lg.webos.oled42c2pca", isOnline: true,
            kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 12))
        )
        // The provider snapshot has no LG tile; the LAN client adds it, as in the app.
        let (store, mock) = try await makeStore([Self.ceiling])
        store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10")
        store.applyLGDeviceUpdate(tv)
        #expect(store.devices.map(\.id) == ["dev_ceiling", tv.id])

        await mock.setFailingTargets(["light.ceiling", LGWebOSProtocol.powerEntityId])
        await mock.holdNextExecute(forTarget: LGWebOSProtocol.powerEntityId)

        let task = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        // The light fails; the TV keeps the batch open.
        await waitUntil { await mock.executeStarted == 2 }

        // The window runs out and the TV reports the same standby row the batch showed.
        store.optimisticLockUntil[tv.id] = ContinuousClock.now.advanced(by: .milliseconds(-1))
        var reported = tv
        if case .tv(var spec) = reported.kind {
            spec.state = "standby"
            reported.kind = .tv(spec)
        }
        store.applyLGDeviceUpdate(reported)
        #expect(store.optimisticLockUntil[tv.id] == nil, "adopting an LG row drops its lock entry")

        await mock.releaseExecute()
        await task?.value

        let row = try #require(store.devices.first { $0.id == tv.id })
        if case .tv(let spec) = row.kind {
            #expect(spec.state == "standby", "the adopted report must not be rolled back to on")
        } else {
            Issue.record("expected the TV row, got \(row.kind)")
        }
        #expect(store.undoBanner == nil)
    }

    @Test("Undo during a running 全关 stops the batch and restores only the device it reached")
    @MainActor
    func undoDuringRunningBatchStopsRemainingCommands() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        // The cards answer at once, before the held command has reached its device.
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "dev_desk" }?.isActiveOn == true)

        await mock.releaseExecute()
        await batch?.value
        await undo.value

        // The held command finishes first, then the only restore. The desk lamp is never switched
        // off, so it never needs (and never gets) a restore command.
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.ceiling", isOn: false),
            .setLightPower(entityId: "light.ceiling", isOn: true),
        ])
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "dev_desk" }?.isActiveOn == true)
        #expect(store.runningBatches.isEmpty)
        #expect(store.undoBanner == nil)
        #expect(store.toastNotice?.message.contains("已恢复关闭前的状态") == true)
    }

    @Test("Undo during a running quick action restores only the device it reached")
    @MainActor
    func undoDuringRunningQuickActionFiltersRestores() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.holdNextExecute()

        let batch = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        await mock.releaseExecute()
        await batch?.value
        await undo.value

        // Only the ceiling light was touched: its brightness landed, its colour never left, and
        // only its own two restores are sent. The desk lamp row is back whole with no command.
        #expect(await mock.executedCommands == [
            .setLightBrightness(entityId: "light.ceiling", percent: 15),
            .setLightBrightness(entityId: "light.ceiling", percent: 80),
            .setLightColorTemp(entityId: "light.ceiling", kelvin: 4000),
        ])
        let desk = try #require(store.devices.first { $0.id == "dev_desk" })
        if case .light(let spec) = desk.kind {
            #expect(spec.isOn)
            #expect(spec.brightnessPercent == 60)
            #expect(spec.colorTempKelvin == 5000)
        } else {
            Issue.record("expected the desk lamp row, got \(desk.kind)")
        }
        #expect(store.undoBanner == nil)
    }

    @Test("A command that fails after the undo reports nothing and revives no banner")
    @MainActor
    func failureAfterUndoStaysSilent() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        // The held off command fails; the undo's on command still succeeds.
        await mock.setFailingCommands { command in
            if case .setLightPower(_, let isOn) = command { return isOn == false }
            return false
        }
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        // An unserialised undo would finish its restore and toast before the held command fails, so a
        // late failure report would be the last word on screen. The serialised undo parks on the
        // in-flight command and sends nothing.
        await waitUntil { store.undoInFlightWaiters == 1 }
        #expect(store.toastNotice == nil, "the undo must still be waiting for the held command")
        await mock.releaseExecute()
        await batch?.value
        await undo.value

        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.ceiling", isOn: true)])
        #expect(store.devices.first { $0.id == "dev_ceiling" }?.isActiveOn == true)
        #expect(store.undoBanner == nil, "a stopped batch must not bring the banner back")
        #expect(store.toastNotice?.isError == false)
        #expect(store.toastNotice?.message.contains("未完成") == false)
        #expect(store.toastNotice?.message.contains("未响应") == false)
        #expect(store.userHabitMemory.entries.isEmpty, "a stopped batch never trains habits")
    }

    @Test("A banner that expires mid-batch still sends the remaining commands")
    @MainActor
    func bannerExpiryDoesNotStopTheBatch() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        // What the expiry timer does when the window runs out: only an actual undo may stop a batch.
        store.undoBanner = nil
        await mock.releaseExecute()
        await batch?.value

        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.ceiling", isOn: false),
            .setLightPower(entityId: "light.desk", isOn: false),
        ])
        #expect(store.devices.allSatisfy { !$0.isActiveOn })
        #expect(store.undoBanner == nil)
    }

    @Test("A snapshot during the undo wait cannot leave the card off")
    @MainActor
    func undoWaitKeepsRestoredRowAgainstSnapshot() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        #expect(store.devices.first?.isActiveOn == true)
        // The device answers slowly and reports the batch's own state while the undo is still waiting.
        var reportedOff = Self.ceiling
        if case .light(var spec) = reportedOff.kind {
            spec.isOn = false
            reportedOff.kind = .light(spec)
        }
        let before = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [reportedOff]))
        await waitUntil { store.snapshotGeneration > before }
        #expect(store.devices.first?.isActiveOn == true, "the wait lock keeps the restored row")

        await mock.releaseExecute()
        await batch?.value
        await undo.value
        #expect(store.devices.first?.isActiveOn == true)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.ceiling", isOn: false),
            .setLightPower(entityId: "light.ceiling", isOn: true),
        ])
    }

    @Test("The undo holds its rows through the wait, then relaxes the lock")
    @MainActor
    func undoWaitLockIsBoundedAndRelaxed() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        let now = ContinuousClock.now
        let waitingDeadline = try #require(store.optimisticLockUntil["dev_ceiling"])
        #expect(waitingDeadline > now.advanced(by: .seconds(3)), "held past the normal 3 s window")
        #expect(
            waitingDeadline <= now.advanced(by: HomeStore.undoWaitLockCeiling),
            "bounded: a command that never returns cannot keep the row locked forever"
        )

        // Hold the restore so the relaxed lock can be seen before its snapshot arrives.
        await mock.holdNextExecute(forTarget: "light.ceiling")
        await mock.releaseExecute()
        await batch?.value
        await waitUntil { await mock.executeStarted == 2 }
        let afterWait = try #require(store.optimisticLockUntil["dev_ceiling"])
        #expect(
            afterWait <= ContinuousClock.now.advanced(by: .seconds(3)),
            "the normal lease is back once the wait is over"
        )

        await mock.releaseExecute()
        await undo.value
    }

    @Test("A context change while the undo waits writes nothing into the new home")
    @MainActor
    func undoWaitStopsAtContextChange() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        store.invalidateUndoContext()
        await mock.releaseExecute()
        await batch?.value
        await undo.value

        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.ceiling", isOn: false)])
        #expect(store.toastNotice == nil, "a home that is no longer on screen reports nothing")
        #expect(store.undoBanner == nil)
        #expect(
            store.optimisticLockUntil.isEmpty,
            "a stale undo must not write row state into the new home"
        )
    }

    @Test("A newer write during the undo wait keeps its row")
    @MainActor
    func undoWaitLeavesNewerWriteInPlace() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        store.controlDebounceInterval = .zero
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        // The user changes the lamp while the undo waits for the slow off command.
        store.setLightBrightness("dev_ceiling", percent: 42)
        await waitUntil {
            await mock.executedCommands.contains(
                .setLightBrightness(entityId: "light.ceiling", percent: 42)
            )
        }

        await mock.releaseExecute()
        await batch?.value
        await undo.value

        let light = try #require(store.devices.first)
        if case .light(let spec) = light.kind {
            #expect(spec.isOn)
            #expect(spec.brightnessPercent == 42, "the newer write owns the row, so the undo leaves it")
        } else {
            Issue.record("expected the light row, got \(light.kind)")
        }
    }

    @Test("A device taken over during the batch gets neither a local nor a network restore")
    @MainActor
    func undoDuringBatchLeavesTakenOverDeviceAlone() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        store.controlDebounceInterval = .zero
        await mock.holdNextExecute()

        let batch = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        // The desk lamp is taken over while the ceiling light's command is still in flight.
        store.setLightBrightness("dev_desk", percent: 70)
        await waitUntil {
            await mock.executedCommands.contains(
                .setLightBrightness(entityId: "light.desk", percent: 70)
            )
        }

        let undo = try #require(store.undoTurnAllOff())
        let desk = try #require(store.devices.first { $0.id == "dev_desk" })
        if case .light(let spec) = desk.kind {
            #expect(spec.brightnessPercent == 70, "undo does not restore a taken-over row locally")
        } else {
            Issue.record("expected the desk lamp row, got \(desk.kind)")
        }

        await mock.releaseExecute()
        await batch?.value
        await undo.value

        let commands = await mock.executedCommands
        #expect(!commands.contains(.setLightBrightness(entityId: "light.desk", percent: 60)))
        #expect(!commands.contains(.setLightColorTemp(entityId: "light.desk", kelvin: 5000)))
        #expect(commands.contains(.setLightBrightness(entityId: "light.ceiling", percent: 80)))
    }

    @Test("A skipped command keeps its whole intent group out of the habits")
    @MainActor
    func skippedCommandTrainsNoHabitGroup() async throws {
        let (store, mock) = try await makeStore([Self.ceiling])
        store.controlDebounceInterval = .zero
        await mock.holdNextExecute()

        let batch = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        // The brightness command is out; a newer write takes the row before the colour follows.
        store.setLightBrightness("dev_ceiling", percent: 70)
        await waitUntil {
            await mock.executedCommands.contains(
                .setLightBrightness(entityId: "light.ceiling", percent: 70)
            )
        }

        await mock.releaseExecute()
        await batch?.value

        #expect(
            !(await mock.executedCommands.contains(
                .setLightColorTemp(entityId: "light.ceiling", kelvin: 2700)
            ))
        )
        let keys = store.userHabitMemory.entries.map { "\($0.targetId)|\($0.operationKey)" }
        #expect(!keys.contains("dev_ceiling|brightness:15"), "a skipped command must not train its group")
        #expect(!keys.contains("dev_ceiling|colorTemperature:2700"))
    }

    @Test("An older batch skips a device a newer write took and still sends to the rest")
    @MainActor
    func olderBatchSkipsTakenDevice() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        store.controlDebounceInterval = .zero
        await mock.holdNextExecute()

        let batch = store.executeQuickAction(.softNightLight)
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        // The user dims the second lamp while the first command is still in flight.
        store.setLightBrightness("dev_desk", percent: 70)
        await waitUntil {
            await mock.executedCommands.contains(
                .setLightBrightness(entityId: "light.desk", percent: 70)
            )
        }

        await mock.releaseExecute()
        await batch?.value

        // Its queued brightness and colour must not overwrite the newer 70.
        let commands = await mock.executedCommands
        #expect(!commands.contains(.setLightBrightness(entityId: "light.desk", percent: 15)))
        #expect(!commands.contains(.setLightColorTemp(entityId: "light.desk", kelvin: 2700)))
        #expect(commands.contains(.setLightColorTemp(entityId: "light.ceiling", kelvin: 2700)))
        #expect(store.toastNotice == nil, "a skipped device is not a failure")
        #expect(store.devices.first { $0.id == "dev_desk" }?.isActiveOn == true)

        // The banner no longer carries it, so undo leaves both its row and the network alone.
        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        let afterUndo = await mock.executedCommands
        #expect(!afterUndo.contains(.setLightBrightness(entityId: "light.desk", percent: 60)))
        #expect(!afterUndo.contains(.setLightColorTemp(entityId: "light.desk", kelvin: 5000)))
        #expect(afterUndo.contains(.setLightBrightness(entityId: "light.ceiling", percent: 80)))
        let desk = try #require(store.devices.first { $0.id == "dev_desk" })
        if case .light(let spec) = desk.kind {
            #expect(spec.brightnessPercent == 70, "undo leaves the taken-over lamp's newer write")
        } else {
            Issue.record("expected the desk lamp row, got \(desk.kind)")
        }
    }

    @Test("A newer 全关 that takes a row during the wait gets no restore from the old undo")
    @MainActor
    func undoWaitSkipsDeviceANewerBatchTook() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        // The ceiling light's command goes out; the desk lamp's is held, so the old batch is still
        // running with both devices attempted when the undo arrives.
        await mock.holdNextExecute(forTarget: "light.desk")

        let oldBatch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 2 }

        let undo = try #require(store.undoTurnAllOff())
        // The user asks for another 全关 while the old undo waits; it only sees the living room.
        store.selectRoom("ke_ting")
        let newerBatch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await newerBatch?.value

        await mock.releaseExecute()
        await oldBatch?.value
        await undo.value

        let commands = await mock.executedCommands
        #expect(
            !commands.contains(.setLightPower(entityId: "light.ceiling", isOn: true)),
            "the newer 全关 owns the ceiling row, so the old undo must not turn it back on"
        )
        #expect(
            commands.contains(.setLightPower(entityId: "light.desk", isOn: true)),
            "the desk lamp still belongs to the old undo and is restored"
        )
    }

    @Test("An undo whose rows were all taken during the wait ends quietly")
    @MainActor
    func undoWaitQuietWhenEveryRowWasTaken() async throws {
        let (store, mock) = try await makeStore([Self.ceiling, Self.deskLamp])
        await mock.holdNextExecute()

        let oldBatch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        // A newer 全关 takes both rows while the old undo is still waiting.
        let newerBatch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await newerBatch?.value

        await mock.releaseExecute()
        await oldBatch?.value
        await undo.value

        let commands = await mock.executedCommands
        #expect(!commands.contains(.setLightPower(entityId: "light.ceiling", isOn: true)))
        #expect(!commands.contains(.setLightPower(entityId: "light.desk", isOn: true)))
        #expect(store.toastNotice == nil, "nothing was restored, so nothing is announced")
    }
}
