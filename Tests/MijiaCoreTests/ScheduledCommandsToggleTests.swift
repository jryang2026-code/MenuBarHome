import Foundation
import StateTestSupport
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ScheduledCommandsToggleTests {
    private typealias Fixtures = ScheduledCommandTestSupport
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timer(
        _ store: HomeStore, offset: TimeInterval, plan: IntentPlan = ScheduledCommandTestSupport.plan
    ) -> ScheduledCommand {
        ScheduledCommand(reply: plan.reply, fireDate: now.addingTimeInterval(offset), plan: plan,
                         sourceScopes: store.activeConnectionScopes.sorted())
    }

    @Test("Turning timers off retains their partitions and expired timers require an explicit run")
    func pausePersistsAndExpiredTimersAreMissed() async throws {
        let (store, mock) = try await Fixtures.makeStore()
        store.assistantNow = { now }
        let gate = Fixtures.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        let waiting = timer(store, offset: 60)
        let missed = timer(store, offset: -60)
        let foreign = ScheduledCommand(reply: "Other home", fireDate: now.addingTimeInterval(60),
                                       plan: Fixtures.plan, sourceScope: "ha:https://other.example")
        ScheduledCommand.save([waiting, missed, foreign], to: store.userDefaults)
        store.restoreScheduledCommands()
        try await awaitState { gate.waiting == 1 }

        #expect(!store.setScheduledCommandsEnabled(false, confirming: [waiting]))
        #expect(store.scheduledCommandsEnabled)
        #expect(store.setScheduledCommandsEnabled(false, confirming: [waiting, missed, foreign]))
        try await awaitState { gate.waiting == 0 }
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.isEmpty)
        #expect(store.pausedScheduledCommands.map(\.originalPartition) == [.waiting, .missed, .foreign])

        let restoredProvider = MockHomeProvider(snapshot: .init(devices: [Fixtures.ceiling]))
        let restored = HomeStore(provider: restoredProvider, defaults: store.userDefaults)
        try await restored.waitForTestSnapshot()
        restored.assistantNow = { now.addingTimeInterval(61) }
        #expect(!restored.scheduledCommandsEnabled)
        #expect(restored.pausedScheduledCommands == store.pausedScheduledCommands)
        #expect(await restored.runMissedScheduledCommand(id: missed.id) == nil)
        _ = await restored.runLocalCommand("10分钟后关闭书房吸顶灯")
        #expect(restored.scheduledCommands.isEmpty)
        #expect(restored.setScheduledCommandsEnabled(true))
        #expect(Set(restored.missedScheduledCommands.map(\.id)) == [waiting.id, missed.id])
        #expect(restored.pausedScheduledCommands.map(\.command.id) == [foreign.id])
        #expect(restored.visiblePausedScheduledCommands.isEmpty)
        #expect(restored.cancelScheduledCommands() == 2)
        #expect(PausedScheduledCommand.load(from: store.userDefaults).map(\.command.id) == [foreign.id])
        #expect(await mock.executedCommands.isEmpty)
        #expect(await restoredProvider.executedCommands.isEmpty)
    }

    @Test("Turning timers back on does not release independent capability or connection pauses")
    func keepsOtherPauseReasons() async throws {
        let (store, mock) = try await Fixtures.makeStore()
        store.assistantNow = { now }
        let disabledScope = store.homeAssistantScopeIdentifier
        // Keep a matching demo stamp and an independent pause from the disabled HA connection.
        let waiting = timer(store, offset: 60)
        let paused = PausedScheduledCommand(
            command: waiting, originalPartition: .waiting,
            pausedCapabilities: [.deviceCategory(.light), .connection(.homeAssistant)],
            pausedScopes: [disabledScope]
        )
        PausedScheduledCommand.save([paused], to: store.userDefaults)
        store.restoreScheduledCommands()
        #expect(store.setScheduledCommandsEnabled(false))
        store.capabilitySelection.enabledCategories.remove(.light)
        store.capabilitySelection.enabledConnections.remove(.homeAssistant)
        store.explicitlyDisabledConnections.insert(.homeAssistant)

        #expect(store.setScheduledCommandsEnabled(true))
        let retained = try #require(store.pausedScheduledCommands.first)
        #expect(retained.pausedCapabilities == paused.pausedCapabilities)
        #expect(retained.pausedScopes == paused.pausedScopes)

        store.capabilitySelection.enabledCategories.insert(.light)
        store.revalidatePausedTimers()
        #expect(store.pausedScheduledCommands.map(\.command.id) == [waiting.id])
        #expect(store.scheduledCommands.isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Offline devices and unsupported operations stay paused until the live snapshot validates them")
    func requiresOnlineAndWritableTargets() async throws {
        let (store, mock) = try await Fixtures.makeStore()
        store.assistantNow = { now }
        let waiting = timer(store, offset: 60)
        ScheduledCommand.save([waiting], to: store.userDefaults)
        store.restoreScheduledCommands()
        #expect(store.setScheduledCommandsEnabled(false, confirming: [waiting]))

        var device = Fixtures.ceiling
        device.isOnline = false
        await mock.updateSnapshot(.init(devices: [device]))
        try await awaitState { store.devices.first?.isOnline == false }
        #expect(store.setScheduledCommandsEnabled(true))
        #expect(store.pausedScheduledCommands.map(\.command.id) == [waiting.id])

        device.isOnline = true
        device.kind = .light(LightSpec(entityId: "light.study_ceiling", isOn: true, powerWritable: false))
        await mock.updateSnapshot(.init(devices: [device]))
        try await awaitState { store.devices.first?.isOnline == true }
        #expect(store.pausedScheduledCommands.map(\.command.id) == [waiting.id])
        #expect(store.scheduledCommands.isEmpty)

        let gate = Fixtures.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        await mock.updateSnapshot(.init(devices: [Fixtures.ceiling]))
        try await awaitState { store.devices.first == Fixtures.ceiling }
        try #require(store.scheduledCommands == [waiting])
        try await awaitState { gate.waiting == 1 }
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(await mock.executedCommands.isEmpty)
        store.cancelScheduledCommands()
    }

    private struct HeldWriteProvider: HomeProvider {
        let mock: MockHomeProvider
        let gate: Fixtures.SleepGate

        func events() -> AsyncStream<HomeProviderEvent> { mock.events() }
        func refreshNow() async { await mock.refreshNow() }

        func execute(_ command: DeviceCommand) async throws {
            if command.targetEntityId == "light.study_ceiling" { await gate.sleep() }
            try await mock.execute(command)
        }
    }

    @Test("Turning off and back on between writes keeps the successful receipt and undo")
    func stopsRemainingWrites() async throws {
        let mock = MockHomeProvider(snapshot: .init(devices: [Fixtures.ceiling, Fixtures.kitchen]))
        let gate = Fixtures.SleepGate()
        let store = HomeStore(
            provider: HeldWriteProvider(mock: mock, gate: gate), defaultsSuiteName: "test.timer-runtime.\(UUID())"
        )
        try await store.waitForTestSnapshot()
        store.assistantNow = { now }
        var plan = Fixtures.plan
        plan.intents.append(.init(targetId: Fixtures.kitchen.id, operation: .power(false)))
        let entry = timer(store, offset: -60, plan: plan)
        ScheduledCommand.save([entry], to: store.userDefaults)
        store.restoreScheduledCommands()
        let execution = Task { await store.runMissedScheduledCommand(id: entry.id) }
        try await awaitState { gate.waiting == 1 }
        #expect(store.setScheduledCommandsEnabled(false))
        #expect(store.setScheduledCommandsEnabled(true))
        gate.release()
        let receipt = await execution.value
        #expect(receipt?.intents == Fixtures.plan.intents)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: true)])
        #expect(store.missedScheduledCommands.isEmpty)
    }

    @Test("A rejected storage write leaves the previous switch state, queues and sleeper intact")
    func persistenceFailureIsAtomic() async throws {
        let defaults = try #require(RejectingDefaults(suiteName: "test.timer-runtime.\(UUID())"))
        let mock = MockHomeProvider(snapshot: .init(devices: [Fixtures.ceiling]))
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.assistantNow = { now }
        let gate = Fixtures.SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        let waiting = timer(store, offset: 60)
        ScheduledCommand.save([waiting], to: defaults)
        store.restoreScheduledCommands()
        try await awaitState { gate.waiting == 1 }

        defaults.rejectTimerWrites()
        #expect(!store.setScheduledCommandsEnabled(false, confirming: [waiting]))
        #expect(store.scheduledCommandsEnabled)
        #expect(store.scheduledCommands == [waiting])
        #expect(gate.waiting == 1)
        #expect(ScheduledCommand.load(from: defaults) == [waiting])
        #expect(PausedScheduledCommand.load(from: defaults).isEmpty)

        defaults.rejectTimerWrites(false)
        #expect(store.setScheduledCommandsEnabled(false, confirming: [waiting]))
        try await awaitState { gate.waiting == 0 }
        defaults.rejectTimerWrites()
        #expect(!store.setScheduledCommandsEnabled(true))
        #expect(!store.scheduledCommandsEnabled)
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.pausedScheduledCommands.map(\.command.id) == [waiting.id])
        #expect(PausedScheduledCommand.load(from: defaults) == store.pausedScheduledCommands)
        #expect(await mock.executedCommands.isEmpty)
    }

    private final class RejectingDefaults: UserDefaults {
        private let lock = NSLock()
        private var rejectsTimerWrites = false

        func rejectTimerWrites(_ reject: Bool = true) {
            lock.withLock { rejectsTimerWrites = reject }
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName == ScheduledCommand.storageKey, lock.withLock({ rejectsTimerWrites }) { return }
            super.set(value, forKey: defaultName)
        }
    }
}
