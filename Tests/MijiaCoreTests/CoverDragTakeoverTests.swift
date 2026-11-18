import Foundation
import Testing
@testable import MijiaCore

/// A cover drag is debounced: only its last value is sent. The device report that confirms an
/// earlier command used to clear the whole manual-write session in `HomeStore+Backend.swift`, so a
/// second drag still waiting in its debounce never reached the provider and the card dropped back
/// to the reported position. A report may end only the commands it actually confirmed.
struct CoverDragTakeoverTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    private static let curtain = SmartDevice(
        id: "curtain", name: "客厅窗帘", roomId: "ke_ting", roomName: "客厅",
        model: "lumi.curtain.hagl04", isOnline: true,
        kind: .cover(CoverSpec(
            entityId: "cover.curtain",
            subtype: .curtain,
            positionPercent: 0,
            reportedPositionPercent: 0,
            positionWritable: true,
            openDescription: "Open",
            closeDescription: "Close",
            pauseDescription: "Pause"
        ))
    )

    /// The same curtain parked at `position`, as a report from the device.
    private static func curtain(at position: Int) -> SmartDevice {
        curtain(target: position, reported: position, motion: .stopped)
    }

    /// The same curtain at `position`, still travelling, as a report from the device.
    private static func curtain(at position: Int, motion: CoverMotion) -> SmartDevice {
        curtain(target: position, reported: position, motion: motion)
    }

    /// A moving cover whose commanded target and reported position differ, as MIoT reports them.
    private static func curtain(target: Int, reported: Int, motion: CoverMotion) -> SmartDevice {
        var device = curtain
        guard case .cover(var spec) = device.kind else { return device }
        spec.positionPercent = target
        spec.reportedPositionPercent = reported
        spec.motion = motion
        spec.motionIsInferred = false
        device.kind = .cover(spec)
        return device
    }

    /// A generic cover for the hazard cases: a subtype the policy prompts for, with the display
    /// target and the reported position kept apart the way MIoT reports a moving motor.
    private static func cover(
        id: String,
        name: String,
        subtype: CoverSubtype,
        position: Int?,
        reported: Int? = nil,
        motion: CoverMotion = .stopped
    ) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "room", roomName: "room", model: "test.cover",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.\(id)",
                subtype: subtype,
                positionPercent: position,
                reportedPositionPercent: reported,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Stop",
                motion: motion
            ))
        )
    }

    @MainActor
    private func makeStore(
        _ devices: [SmartDevice]
    ) async throws -> (HomeStore, MockHomeProvider, SleepGate) {
        let gate = SleepGate()
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.coverdrag.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()
        return (store, mock, gate)
    }

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider, SleepGate) {
        try await makeStore([Self.curtain])
    }

    /// True once the only patch in `deviceId`'s session has been acknowledged by the provider.
    @MainActor
    private func hasSucceededPatch(_ store: HomeStore, _ deviceId: String) -> Bool {
        guard let patch = store.manualWriteSessions[deviceId]?.patches.first else { return false }
        if case .succeeded = patch.phase { return true }
        return false
    }

    @Test("A second drag still reaches the provider after a report confirms the first one")
    @MainActor
    func secondDragSurvivesTravelTakeover() async throws {
        let (store, mock, gate) = try await makeStore()
        let id = Self.curtain.id
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        // First drag: 0 -> 50%, sent once the debounce releases.
        store.setCoverPosition(id, percent: 50)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, id) }

        // Second drag: 50 -> 20%, still waiting in its debounce. The motor has not moved from its
        // reported 0%, so the command travels 0 -> 20.
        store.setCoverPosition(id, percent: 20)
        await waitUntil { gate.waiting == 1 }
        let pending = try #require(store.devices.first?.coverSpec)
        #expect(pending.positionPercent == 20)
        #expect(pending.motion == .opening)

        // The motor reports a stop at 15%. It confirms travel, but it cannot confirm the 20% drag
        // that has not left the Mac yet.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain(at: 15)]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        let held = try #require(store.devices.first?.coverSpec)
        #expect(held.positionPercent == 20, "the card keeps the drag that is still pending")
        #expect(held.motion == .opening, "the pending 15 -> 20 drag travels the other way now")
        #expect(store.optimisticLockUntil[id] != nil, "the pending drag still owns the cover position")

        // Releasing the debounce must deliver the second position, not drop it.
        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let commandCount = await mock.executedCommands.count
        let lastCommand = await mock.executedCommands.last
        #expect(commandCount == 2)
        #expect(
            lastCommand == .setNumberValue(entityId: "cover.curtain", value: 20),
            "the second drag's position reaches the provider"
        )

        // An intermediate opening report must not be read as confirmation of a closing drag.
        let beforeTravel = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain(at: 16, motion: .opening)]))
        await waitUntil { store.snapshotGeneration > beforeTravel }
        let travelling = try #require(store.devices.first?.coverSpec)
        #expect(travelling.positionPercent == 20, "travel towards the new target keeps the target on the card")
        #expect(travelling.motion == .opening)

        // Once the device reports the second target, its own report settles the row.
        let beforeConfirm = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain(at: 20)]))
        await waitUntil { store.snapshotGeneration > beforeConfirm }
        let settled = try #require(store.devices.first?.coverSpec)
        #expect(settled.positionPercent == 20)
        #expect(settled.motion == .stopped)
        #expect(store.optimisticLockUntil[id] == nil)
        #expect(prompts == 0, "a curtain drag is its own confirmation")
    }

    @Test("A reverse drag during travel takes its direction from the reported position")
    @MainActor
    func reverseDragDuringTravelKeepsItsDirection() async throws {
        let (store, mock, gate) = try await makeStore()
        let id = Self.curtain.id

        // First drag: 0 -> 100%, sent. The card shows the commanded 100% while the motor is still
        // near its reported 0%.
        store.setCoverPosition(id, percent: 100)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, id) }

        // Reverse drag to 10%: the motor has to open 0 -> 10, not close 100 -> 10.
        store.setCoverPosition(id, percent: 10)
        await waitUntil { gate.waiting == 1 }
        #expect(
            store.devices.first?.coverSpec?.motion == .opening,
            "the direction comes from the reported position, not the old display target"
        )

        // An opening report at 5% is behind the new target, so it cannot confirm the drag.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.curtain(target: 100, reported: 5, motion: .opening)
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        let held = try #require(store.devices.first?.coverSpec)
        #expect(held.positionPercent == 10)
        #expect(held.motion == .opening)
        #expect(store.optimisticLockUntil[id] != nil)
    }

    @Test("A drag back to the reported position does not keep the old travel direction")
    @MainActor
    func dragBackToReportedPositionStops() async throws {
        let (store, mock, gate) = try await makeStore()
        let id = Self.curtain.id

        store.setCoverPosition(id, percent: 50)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, id) }

        // The motor never left 0%, so dragging back to 0% leaves nothing to travel.
        store.setCoverPosition(id, percent: 0)
        await waitUntil { gate.waiting == 1 }
        let held = try #require(store.devices.first?.coverSpec)
        #expect(held.positionPercent == 0)
        #expect(held.motion == .stopped, "a target the motor already reports has no direction")

        // An opening report from the first command must not confirm the 0% target.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.curtain(target: 50, reported: 5, motion: .opening)
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        let shown = try #require(store.devices.first?.coverSpec)
        #expect(shown.positionPercent == 0)
        #expect(store.optimisticLockUntil[id] != nil)
    }

    @Test("A travel report still takes the card over when no drag is waiting")
    @MainActor
    func reportTakesOverWithoutPendingDrag() async throws {
        let (store, mock, gate) = try await makeStore()
        let id = Self.curtain.id

        store.setCoverPosition(id, percent: 50)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, id) }

        // The device stopped at 15%, away from both the commanded 50% and the drag origin.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain(at: 15)]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        let shown = try #require(store.devices.first?.coverSpec)
        #expect(shown.positionPercent == 15, "with nothing pending, the report owns the row")
        #expect(shown.motion == .stopped)
        #expect(store.optimisticLockUntil[id] == nil)
        #expect(store.manualWriteSessions[id] == nil)
    }

    @Test("An idle cover follows an external remote move")
    @MainActor
    func idleCoverFollowsRemoteMove() async throws {
        let (store, mock, _) = try await makeStore()

        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain(at: 60)]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        let shown = try #require(store.devices.first?.coverSpec)
        #expect(shown.positionPercent == 60)
        #expect(shown.motion == .stopped)
        #expect(store.optimisticLockUntil[Self.curtain.id] == nil)
    }

    @Test("A drag that a newer write supersedes is rolled back and reported, never dropped in silence")
    @MainActor
    func supersededDragIsVisible() async throws {
        let (store, mock, gate) = try await makeStore()
        let id = Self.curtain.id

        store.setCoverPosition(id, percent: 50)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, id) }

        store.setCoverPosition(id, percent: 20)
        await waitUntil { gate.waiting == 1 }

        // A newer write takes the device revision while the drag waits, so the session can no
        // longer send. Nothing was commanded, so the row must not keep showing 20% in silence.
        _ = store.lockOptimisticFacet(
            id,
            controlId: "calibration",
            duration: .seconds(5),
            bumpDeviceRevision: true
        )
        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }

        let commandCount = await mock.executedCommands.count
        #expect(commandCount == 1, "a superseded drag must not reach the provider")
        let message = try #require(store.toastNotice?.message)
        #expect(store.toastNotice?.isError == true)
        #expect(message.contains("调节未生效"), "the dropped drag is reported to the user")
        let shown = try #require(store.devices.first?.coverSpec)
        #expect(shown.positionPercent == 50, "the row returns to the value before the dropped drag")
    }

    @Test("A live report under a travel lock starts the next hazardous drag")
    @MainActor
    func liveReportUnderLockStartsNextDrag() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: 100, reported: 100
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        // Closing a window opener is direct.
        store.setCoverPosition(opener.id, percent: 0)
        #expect(prompts == 0)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, opener.id) }

        // The motor is already at 10% while the locked card still shows the commanded 0%.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "opener", name: "阳台窗", subtype: .windowOpener,
                position: 0, reported: 10, motion: .closing
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        let moving = try #require(store.devices.first?.coverSpec)
        #expect(moving.reportedPositionPercent == 10, "a lock hides the target, not the live report")

        // 10 -> 30 opens the window even though the card still shows the commanded 0%.
        store.setCoverPosition(opener.id, percent: 30)
        #expect(prompts == 1, "the direction starts from the live report, not the locked target")
        await waitUntil { gate.waiting == 1 }
        let pending = try #require(store.devices.first?.coverSpec)
        #expect(pending.positionPercent == 30)
        #expect(pending.motion == .opening, "the card shows the travel the command will make")

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let sent = await mock.executedCommands
        #expect(sent.count == 2)
        #expect(sent.last == .setNumberValue(entityId: "cover.opener", value: 30))
    }

    @Test("A re-based cover without a reported position keeps the new direction")
    @MainActor
    func rebasedCoverWithoutReportedPositionKeepsDirection() async throws {
        // A Home Assistant cover publishes only `positionPercent`; `reportedPositionPercent` stays
        // nil. The pending patch must still follow the report that re-bases it.
        let curtain = Self.cover(
            id: "ha_curtain", name: "客厅窗帘", subtype: .curtain, position: 50, reported: nil
        )
        let (store, mock, gate) = try await makeStore([curtain])

        store.setCoverPosition(curtain.id, percent: 20)
        await waitUntil { gate.waiting == 1 }
        #expect(store.devices.first?.coverSpec?.motion == .closing)

        // The motor stopped at 15%, so the pending 20% is now an opening.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(id: "ha_curtain", name: "客厅窗帘", subtype: .curtain, position: 15)
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        let held = try #require(store.devices.first?.coverSpec)
        #expect(held.positionPercent == 20)
        #expect(held.motion == .opening, "the displayed direction follows the re-based start")

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let lastCommand = await mock.executedCommands.last
        #expect(lastCommand == .setNumberValue(entityId: "cover.ha_curtain", value: 20))

        // An intermediate opening report is below the pending target, so it cannot settle the card.
        let beforeTravel = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "ha_curtain", name: "客厅窗帘", subtype: .curtain,
                position: 16, motion: .opening
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeTravel }
        let travelling = try #require(store.devices.first?.coverSpec)
        #expect(travelling.positionPercent == 20, "the card keeps the target until the motor reaches it")
        #expect(travelling.motion == .opening)
    }

    @Test("A missing position report cannot turn the optimistic target into the drag's start")
    @MainActor
    func missingReportFailsClosedForHazardousCover() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: 0, reported: 0
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        // Confirm and send 0 -> 100.
        store.setCoverPosition(opener.id, percent: 100)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, opener.id) }

        // A report without any position keeps the locked 100% target on screen. The motor's real
        // position is unknown and must not be borrowed from that optimistic target.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(id: "opener", name: "阳台窗", subtype: .windowOpener, position: nil, reported: nil)
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        #expect(store.lastCoverPositions[opener.id] == nil)
        #expect(store.devices.first?.coverSpec?.positionPercent == 100)

        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        store.setCoverPosition(opener.id, percent: 20)
        #expect(prompts == 2, "an unknown start counts as the hazardous opening direction")
        #expect(await mock.executedCommands.count == 1, "the refused drag never reaches the provider")
        #expect(store.devices.first?.coverSpec?.positionPercent == 100, "the refused drag leaves the row")
    }

    @Test("A garage drag with an unknown start still asks")
    @MainActor
    func garageDragWithUnknownStartAsks() async throws {
        let garage = Self.cover(
            id: "garage", name: "车库门", subtype: .garageDoor, position: nil, reported: nil
        )
        let (store, mock, _) = try await makeStore([garage])
        var prompts = 0
        var promptMessage: String?
        store.manualControlConfirmationHandler = { prompt in
            prompts += 1
            promptMessage = prompt.message
            return false
        }

        store.setCoverPosition(garage.id, percent: 60)
        #expect(prompts == 1, "a garage door needs an answer in either direction")
        #expect(
            promptMessage?.contains("位置回报缺失") == true,
            "an unknown start gets the direction-free copy, not the opening prompt"
        )
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.first?.coverSpec?.positionPercent == nil)
    }

    @Test("A curtain drag with an unknown start stays direct")
    @MainActor
    func curtainDragWithUnknownStartStaysDirect() async throws {
        let curtain = Self.cover(
            id: "curtain", name: "客厅窗帘", subtype: .curtain, position: nil, reported: nil
        )
        let (store, mock, gate) = try await makeStore([curtain])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setCoverPosition(curtain.id, percent: 50)
        #expect(prompts == 0, "a curtain has no hazard direction")
        await waitUntil { gate.waiting == 1 }
        #expect(store.devices.first?.coverSpec?.positionPercent == 50)

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        #expect(await mock.executedCommands == [.setNumberValue(entityId: "cover.curtain", value: 50)])
    }

    @Test("A window-opener drag is judged from the reported position, so opening asks")
    @MainActor
    func windowOpenerDragUsesReportedDirection() async throws {
        // The card shows the commanded 100% while the motor is still at its reported 0%.
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener,
            position: 100, reported: 0, motion: .opening
        )
        let (store, mock, _) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        store.setCoverPosition(opener.id, percent: 20)
        #expect(prompts == 1, "0% -> 20% opens the window even though the row shows 100%")
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.first?.coverSpec?.positionPercent == 100, "a refused drag never shows")
    }

    @Test("A rebased window-opener drag that becomes an unconfirmed opening is dropped")
    @MainActor
    func rebasedWindowOpenerOpeningIsDropped() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: 50, reported: 50
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        // The first drag opens 50 -> 100 and carries the user's answer.
        store.setCoverPosition(opener.id, percent: 100)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        await waitUntil { hasSucceededPatch(store, opener.id) }

        // The motor reports 50% on its way to 100%, so the next drag starts from 50%.
        let beforeMove = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "opener", name: "阳台窗", subtype: .windowOpener,
                position: 100, reported: 50, motion: .opening
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeMove }

        // 50 -> 20 closes the window, which makes the home safer, so it needs no prompt.
        store.setCoverPosition(opener.id, percent: 20)
        await waitUntil { gate.waiting == 1 }
        #expect(prompts == 1, "closing a window opener is direct")

        // The motor stopped at 15%, so the pending command would now open 15 -> 20. That is the
        // hazardous direction the user never answered for, so it must not be sent.
        let exits = store.manualWriteExits
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "opener", name: "阳台窗", subtype: .windowOpener,
                position: 15, reported: 15
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        await waitUntil { store.manualWriteExits > exits }

        let sent = await mock.executedCommands
        #expect(sent.count == 1, "the unconfirmed 15 -> 20 opening must not be sent")
        #expect(store.devices.first?.coverSpec?.positionPercent == 15, "the row follows the report")
        #expect(store.optimisticLockUntil[opener.id] == nil)
        let message = try #require(store.toastNotice?.message)
        #expect(store.toastNotice?.isError == true)
        #expect(message.contains("重新确认"), "the user is told the drag needs a new confirmation")
    }

    @Test("A confirmed garage-door direction that flips after a re-base is not sent")
    @MainActor
    func rebasedGarageDirectionIsDropped() async throws {
        let garage = Self.cover(
            id: "garage", name: "车库门", subtype: .garageDoor, position: 100, reported: 100
        )
        let (store, mock, gate) = try await makeStore([garage])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        // Closing the door is hazardous and approved as closing.
        store.setCoverPosition(garage.id, percent: 60)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }

        // A report stops at 50%, so the pending 60% is now an opening, not the approved closing.
        let exits = store.manualWriteExits
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "garage", name: "车库门", subtype: .garageDoor,
                position: 50, reported: 50
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }
        await waitUntil { store.manualWriteExits > exits }

        #expect(await mock.executedCommands.isEmpty, "the closing answer does not cover opening")
        #expect(store.devices.first?.coverSpec?.positionPercent == 50, "the row follows the report")
        #expect(store.toastNotice?.message.contains("重新确认") == true)
    }

    @Test("A confirmed opening drag still sends when a re-base keeps the direction")
    @MainActor
    func rebasedConfirmedOpeningStillSends() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: 0, reported: 0
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setCoverPosition(opener.id, percent: 100)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }

        // The report stops at 15%, but 15 -> 100 is still the approved opening direction.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(id: "opener", name: "阳台窗", subtype: .windowOpener, position: 15, reported: 15)
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let sent = await mock.executedCommands
        #expect(sent == [.setNumberValue(entityId: "cover.opener", value: 100)])
        #expect(prompts == 1, "the answer already covered this direction")
    }

    @Test("A known-direction answer does not carry into an unknown start")
    @MainActor
    func knownAnswerDoesNotCarryIntoUnknownStart() async throws {
        let garage = Self.cover(
            id: "garage", name: "车库门", subtype: .garageDoor, position: 0, reported: 0
        )
        let (store, mock, gate) = try await makeStore([garage])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return prompts == 1
        }

        // The first tick is approved as an opening.
        store.setCoverPosition(garage.id, percent: 100)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }

        // The report loses the position while this drag is still accumulating.
        let beforeMissing = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(id: "garage", name: "车库门", subtype: .garageDoor, position: nil, reported: nil)
        ]))
        await waitUntil { store.snapshotGeneration > beforeMissing }
        #expect(store.lastCoverPositions[garage.id] == nil)

        // The next tick needs the unknown-start answer, not the opening answer it inherited.
        store.setCoverPosition(garage.id, percent: 20)
        #expect(prompts == 2, "an unknown start needs its own confirmation kind")

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let sent = await mock.executedCommands
        #expect(
            sent.allSatisfy { $0 != .setNumberValue(entityId: "cover.garage", value: 20) },
            "the refused unknown-start tick never reaches the provider"
        )
        #expect(
            sent.isEmpty,
            "the first opening approval also fails closed once its start becomes unknown"
        )
    }

    @Test("An unknown-start answer does not carry into a known opening")
    @MainActor
    func unknownAnswerDoesNotCarryIntoKnownOpening() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: nil, reported: nil
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return prompts == 1
        }

        // The first tick is approved for an unknown start.
        store.setCoverPosition(opener.id, percent: 100)
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }

        // A real report arrives, so the pending drag now starts from a known 0% and opens.
        let beforeReport = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [
            Self.cover(
                id: "opener", name: "阳台窗", subtype: .windowOpener,
                position: 0, reported: 0, motion: .opening
            )
        ]))
        await waitUntil { store.snapshotGeneration > beforeReport }

        // The next tick needs an opening answer, not the unknown-start answer it inherited.
        store.setCoverPosition(opener.id, percent: 20)
        #expect(prompts == 2, "a known opening needs its own confirmation kind")

        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        let sent = await mock.executedCommands
        #expect(
            sent.allSatisfy { $0 != .setNumberValue(entityId: "cover.opener", value: 20) },
            "the refused opening tick never reaches the provider"
        )
        #expect(
            sent.isEmpty,
            "the unknown-start approval also fails closed once its start becomes a known opening"
        )
    }

    @Test("Same-kind ticks inside one drag reuse the single answer")
    @MainActor
    func sameKindTicksReuseOneAnswer() async throws {
        let opener = Self.cover(
            id: "opener", name: "阳台窗", subtype: .windowOpener, position: 0, reported: 0
        )
        let (store, mock, gate) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setCoverPosition(opener.id, percent: 80)
        #expect(prompts == 1)
        store.setCoverPosition(opener.id, percent: 90)
        #expect(prompts == 1, "the same opening kind reuses the answer")

        await waitUntil { gate.waiting == 1 }
        let exits = store.manualWriteExits
        gate.release()
        await waitUntil { store.manualWriteExits > exits }
        #expect(await mock.executedCommands == [.setNumberValue(entityId: "cover.opener", value: 90)])
    }
}
