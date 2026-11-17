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

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider, SleepGate) {
        let gate = SleepGate()
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.curtain]))
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.coverdrag.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()
        return (store, mock, gate)
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
}
