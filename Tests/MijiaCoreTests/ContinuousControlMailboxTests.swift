import Foundation
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContinuousControlMailboxTests {
    @Test(arguments: [true, false], [4, 50])
    func dragKeepsOneFollowUp(lan: Bool, inputCount: Int) async throws {
        let lamp = SmartDevice(
            id: "lamp", name: "Lamp", roomId: "room", roomName: "Room", model: "light", isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 10))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp]))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        await provider.holdSnapshots()
        await provider.holdNextExecute()
        let sleepGate = ScheduledCommandTestSupport.SleepGate()
        let now = ContinuousClock.now
        store.controlSliderNow = { now }
        if lan {
            store.activeHAConfig = (url: "http://homeassistant.local", token: "")
        }
        store.controlDebounceSleep = { _ in await sleepGate.sleep() }

        store.setLightBrightness(lamp.id, percent: 11)
        if !lan {
            try await awaitState { sleepGate.waiting == 1 }
            sleepGate.release()
        }
        await waitUntil { await provider.executeStarted == 1 }
        let field = OptimisticLockKey.field(lamp.id, .brightness)
        let firstEpoch = try #require(store.fieldWriteEpochs[field])

        let lastValue = 10 + inputCount
        for value in 12...lastValue {
            store.setLightBrightness(lamp.id, percent: value)
        }
        #expect(await provider.executeStarted == 1)
        #expect(store.debouncedWrites.count == 1)
        let trailing = try #require(store.debounceTasks["lamp.brightness"])
        let previewEpoch = try #require(store.fieldWriteEpochs[field])
        #expect(previewEpoch >= firstEpoch)
        await provider.releaseExecute()
        if lan {
            try await awaitState { sleepGate.waiting == 1 }
            #expect(await provider.executeStarted == 1)
            sleepGate.release()
            try await awaitState { sleepGate.parkCount == 2 }
            sleepGate.release()
        }
        await trailing.value

        #expect(await provider.executedCommands == [
            .setLightBrightness(entityId: "light.lamp", percent: 11),
            .setLightBrightness(entityId: "light.lamp", percent: lastValue),
        ])
        #expect(try #require(store.fieldWriteEpochs[field]) > previewEpoch)
        let afterLease = Date().addingTimeInterval(10)
        store.optimisticNow = { afterLease }
        var stalePoll = SynthesizedHome(devices: [lamp])
        stalePoll.devicePollCapturedEpochs[lamp.id] = previewEpoch
        store.handleProviderEvent(.snapshotUpdated(stalePoll))
        guard case .light(let final) = try #require(store.devices.first).kind else {
            Issue.record("Missing lamp")
            return
        }
        #expect(final.brightnessPercent == lastValue)
    }

    @Test
    func hazardousLANControlWaitsForConfirmationAndQuietPeriod() async throws {
        let cover = SmartDevice(
            id: "garage", name: "Garage", roomId: "room", roomName: "Room", model: "garage", isOnline: true,
            kind: .cover(CoverSpec(entityId: "cover.garage", subtype: .garageDoor,
                                   positionPercent: 10, reportedPositionPercent: 10, positionWritable: true))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [cover]))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        store.activeHAConfig = (url: "http://homeassistant.local", token: "")
        let sleepGate = ScheduledCommandTestSupport.SleepGate()
        store.controlDebounceSleep = { _ in await sleepGate.sleep() }
        var confirmations = 0
        store.manualControlConfirmationHandler = { _ in
            confirmations += 1
            return true
        }

        store.setCoverPosition(cover.id, percent: 70)
        let pending = try #require(store.debounceTasks["garage.cover"])
        try await awaitState { sleepGate.waiting == 1 }
        #expect(confirmations == 1)
        #expect(await provider.executedCommands.isEmpty)
        sleepGate.release()
        await pending.value
        #expect(await provider.executedCommands == [.setNumberValue(entityId: "cover.garage", value: 70)])
    }
}
