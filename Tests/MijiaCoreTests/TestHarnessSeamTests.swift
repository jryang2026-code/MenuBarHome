import Foundation
import Testing
@testable import MijiaCore

/// The test seams added so a case can observe a snapshot, a cover lock, or a local command
/// without sleeping and without the on-device model.
struct TestHarnessSeamTests {
    private static let ceiling = ScheduledCommandTestSupport.ceiling

    @Test("A held snapshot stays in the mock until emit, and readBack reports that same snapshot")
    @MainActor
    func heldSnapshotIsUnchangedUntilEmit() async throws {
        let home = SynthesizedHome(devices: [Self.ceiling])
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.harness.snapshot.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        #expect(store.devices.first?.isActiveOn == true)

        let beforeRead = store.snapshotGeneration
        let read = await mock.readBack(deviceId: Self.ceiling.id)
        #expect(read == .published)
        await waitUntil { store.snapshotGeneration > beforeRead }
        #expect(store.devices.first?.isActiveOn == true, "readBack reports the snapshot the mock already holds")

        let generation = store.snapshotGeneration
        await mock.holdSnapshots()
        try await mock.execute(.setLightPower(entityId: "light.study_ceiling", isOn: false))
        #expect(store.snapshotGeneration == generation)
        #expect(store.devices.first?.isActiveOn == true)

        await mock.emitSnapshot()
        await waitUntil { store.snapshotGeneration > generation }
        #expect(store.devices.first?.isActiveOn == false)
    }

    @Test("A target hold suspends only the matching command")
    func targetHoldLeavesOtherCommandsRunning() async throws {
        let mock = MockHomeProvider()
        await mock.holdNextExecute(forTarget: "light.held")
        try await mock.execute(.setLightPower(entityId: "light.other", isOn: false))
        #expect(await mock.executedCommands.count == 1)
        #expect(await mock.executeStarted == 1)

        let held = Task {
            try await mock.execute(.setLightPower(entityId: "light.held", isOn: false))
        }
        await waitUntil { await mock.executeStarted == 2 }
        #expect(await mock.executedCommands.count == 1, "the matching command is suspended before it is recorded")
        await mock.releaseExecute()
        try await held.value
        #expect(await mock.executedCommands.count == 2)
    }

    @Test("A cover lock uses the injected duration, so a test does not wait out eight seconds")
    @MainActor
    func coverLockDurationIsInjectable() async throws {
        let curtain = SmartDevice(
            id: "curtain", name: "客厅窗帘", roomId: "ke_ting", roomName: "客厅",
            model: "lumi.curtain.hagl04", isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.curtain",
                subtype: .curtain,
                positionPercent: 0,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause"
            ))
        )
        let home = SynthesizedHome(devices: [curtain])
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.harness.cover.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.coverOptimisticLockDuration = .zero

        let card = try #require(store.devices.first)
        #expect(await store.togglePrimary(card)?.value == true)
        await mock.updateSnapshot(home)
        await waitUntil(timeout: .seconds(2)) { store.optimisticLockUntil[card.id] == nil }
        #expect(store.devices.first?.coverSpec?.positionPercent == 0)
    }

    @Test("runLocalCommand stays on the local parser when the on-device model is available")
    @MainActor
    func runLocalCommandDoesNotCallTheOnDeviceModel() async throws {
        let (store, mock) = try await ScheduledCommandTestSupport.makeStore()
        let spy = LocalResolverSpy(plan: IntentPlan(intents: [], reply: "model", source: .model))
        store.localAssistantAvailabilityOverride = .available
        store.localAssistantResolverOverride = spy

        let plan = try #require(await store.runLocalCommand("关闭书房吸顶灯"))
        #expect(plan.source == .local)
        #expect(await spy.utterances.isEmpty)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])

        let missed = await store.runLocalCommand("zzzz-not-a-home-command")
        #expect(missed == nil)
        #expect(await spy.utterances.isEmpty)
    }
}

private actor LocalResolverSpy: AssistantCommandResolving {
    private(set) var utterances: [String] = []
    private let plan: IntentPlan

    init(plan: IntentPlan) {
        self.plan = plan
    }

    func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext,
        confirmation: ModelActionPolicy.ConfirmationPolicy
    ) async throws -> IntentPlan {
        utterances.append(utterance)
        return plan
    }
}
