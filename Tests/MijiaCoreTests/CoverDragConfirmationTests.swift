import Foundation
import Testing
@testable import MijiaCore

/// A position slider is the confirmation for a curtain, but not for the subtypes the hazard table
/// calls dangerous: dragging a garage door closed is the same action as pressing 关闭.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoverDragConfirmationTests {
    private func cover(_ id: String, name: String, subtype: CoverSubtype, position: Int?) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "room", roomName: "room", model: "test.cover",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.\(id)", subtype: subtype, positionPercent: position,
                positionWritable: true, openDescription: "Open",
                closeDescription: "Close", pauseDescription: "Stop"
            ))
        )
    }

    private func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.cover.drag.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .zero
        return (store, provider)
    }

    private func position(_ store: HomeStore, _ id: String) -> Int? {
        guard case .cover(let spec) = store.devices.first(where: { $0.id == id })?.kind else { return nil }
        return spec.positionPercent
    }

    @Test("Dragging a garage door asks, and a refusal sends nothing and leaves the row where it was")
    func garageDoorDragAsks() async throws {
        let garage = cover("garage", name: "车库门", subtype: .garageDoor, position: 100)
        let (store, provider) = try await makeStore([garage])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        store.setCoverPosition(garage.id, percent: 0)
        #expect(prompts == 1)
        #expect(position(store, garage.id) == 100, "a refused drag never shows the closed position")
        #expect(store.optimisticLockUntil[garage.id] == nil, "a refused drag takes no lock")
        #expect(await provider.executedCommands.isEmpty)

        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }
        store.setCoverPosition(garage.id, percent: 0)
        #expect(prompts == 2, "the next drag asks on its own")
        await waitUntil { await provider.executedCommands == [
            .setNumberValue(entityId: "cover.garage", value: 0)
        ] }
        #expect(position(store, garage.id) == 0)
    }

    @Test("A drag asks once while it is still accumulating inside the debounce window")
    func garageDoorDragAsksOncePerDirection() async throws {
        let garage = cover("garage", name: "车库门", subtype: .garageDoor, position: 100)
        let (store, provider) = try await makeStore([garage])
        store.controlDebounceInterval = .milliseconds(300)
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        for percent in stride(from: 80, through: 40, by: -20) {
            store.setCoverPosition(garage.id, percent: percent)
        }
        #expect(prompts == 1, "one hold of the slider is one decision")
        await waitUntil { await provider.executedCommands.count == 1 }
        #expect(await provider.executedCommands == [.setNumberValue(entityId: "cover.garage", value: 40)],
                "the debounce sends the last position of the drag")
    }

    @Test("A second drag after the first command went out asks again")
    func secondDragAfterSendAsks() async throws {
        let garage = cover("garage", name: "车库门", subtype: .garageDoor, position: 100)
        let (store, provider) = try await makeStore([garage])
        store.controlDebounceInterval = .milliseconds(20)
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setCoverPosition(garage.id, percent: 0)
        #expect(prompts == 1)
        // The debounce slot is the drag: once it is gone, the answer it carried is gone with it.
        await waitUntil {
            await provider.executedCommands.count == 1 && store.debouncedWrites["garage.cover"] == nil
        }

        // Reversing right after the command went out is a new decision, not a tick of the drag that
        // was already answered.
        store.setCoverPosition(garage.id, percent: 100)
        #expect(prompts == 2, "a drag after the slot went out asks again instead of inheriting the answer")
    }

    @Test("Dragging a curtain stays direct")
    func curtainDragIsDirect() async throws {
        let curtain = cover("curtain", name: "客厅窗帘", subtype: .curtain, position: 100)
        let (store, provider) = try await makeStore([curtain])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        store.setCoverPosition(curtain.id, percent: 40)
        #expect(prompts == 0)
        await waitUntil { await provider.executedCommands == [
            .setNumberValue(entityId: "cover.curtain", value: 40)
        ] }
        #expect(position(store, curtain.id) == 40)
    }

    @Test("Closing a window opener is direct while opening asks")
    func windowOpenerAsksOnlyWhenOpening() async throws {
        let opener = cover("opener", name: "阳台窗", subtype: .windowOpener, position: 40)
        let (store, provider) = try await makeStore([opener])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        store.setCoverPosition(opener.id, percent: 0)
        await waitUntil { await provider.executedCommands.count == 1 }
        #expect(prompts == 0, "closing a window makes the home safer")

        store.setCoverPosition(opener.id, percent: 90)
        #expect(prompts == 1, "opening it is the hazardous direction")
        #expect(position(store, opener.id) == 0, "the refused opening never shows")
        #expect(await provider.executedCommands.count == 1)
    }

    @Test("A drag that snaps to the same end still asks when the command moves the motor")
    func snappedEndDragStillAsks() async throws {
        let closed = cover("garage_closed", name: "车库门", subtype: .garageDoor, position: 0)
        let (closedStore, closedProvider) = try await makeStore([closed])
        var closedPrompts = 0
        closedStore.manualControlConfirmationHandler = { _ in
            closedPrompts += 1
            return false
        }
        closedStore.setCoverPosition(closed.id, percent: 1)
        #expect(closedPrompts == 1, "1% displays as 0% but the command still opens the door")
        #expect(await closedProvider.executedCommands.isEmpty)
        #expect(position(closedStore, closed.id) == 0)

        let open = cover("garage_open", name: "车库门", subtype: .garageDoor, position: 100)
        let (openStore, openProvider) = try await makeStore([open])
        var openPrompts = 0
        openStore.manualControlConfirmationHandler = { _ in
            openPrompts += 1
            return false
        }
        openStore.setCoverPosition(open.id, percent: 99)
        #expect(openPrompts == 1, "99% displays as 100% but the command still closes the door")
        #expect(await openProvider.executedCommands.isEmpty)
        #expect(position(openStore, open.id) == 100)
    }
}
