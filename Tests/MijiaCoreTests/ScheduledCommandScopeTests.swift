import Foundation
import Testing
@testable import MijiaCore

/// 定时任务属于创建它的数据源：换家庭 / 账号 / 数据源后不能误触发，也不能被别的数据源保存时删掉（ADR-0019）。
struct ScheduledCommandScopeTests {
    static let ceiling = SmartDevice(
        id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: true))
    )

    static let plan = IntentPlan(
        intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .power(false))],
        reply: "已关闭书房吸顶灯",
        source: .local
    )

    /// A second Home Assistant that is not the one this test store starts on.
    static let otherHomeURL = "http://192.0.2.20:8123"

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    @Test("A timer belongs to the source that created it, survives another source's save and re-arms on return")
    @MainActor
    func timerFollowsItsSource() async throws {
        let (store, mock) = try await makeStore()
        store.assistantSleep = { _ in try await Task.sleep(for: .seconds(5)) }
        let homeURL = store.serverURLString

        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let homeTimer = try #require(store.scheduledCommands.first)
        let homeScope = try #require(homeTimer.sourceScope)
        #expect(homeScope == store.connectionScopeIdentifier)

        // The user points the app at another Home Assistant while this timer counts down.
        store.serverURLString = Self.otherHomeURL
        store.startListening()
        #expect(store.scheduledCommands.isEmpty, "Another source's timer must not be armed here")
        #expect(store.missedScheduledCommands.isEmpty)

        // A timer set on the new source is saved next to the old one instead of deleting it.
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let otherTimer = try #require(store.scheduledCommands.first)
        #expect(otherTimer.sourceScope != homeScope)

        let persisted = ScheduledCommand.load(from: store.userDefaults)
        #expect(Set(persisted.map(\.id)) == [homeTimer.id, otherTimer.id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mock.executedCommands.isEmpty, "No timer of an inactive source may fire")

        // Back home: the original timer is still there and runs.
        store.assistantSleep = { _ in try await Task.sleep(for: .milliseconds(30)) }
        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [homeTimer.id])
        for _ in 0..<50 where !store.scheduledCommands.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [otherTimer.id])
    }

    @Test("A timer that passed while its source was away waits in the missed list")
    @MainActor
    func timerPassedWhileAwayIsMissed() async throws {
        let (store, mock) = try await makeStore()
        let homeURL = store.serverURLString
        let homeScope = try #require(store.connectionScopeIdentifier)
        let fireDate = Date().addingTimeInterval(600)
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭书房吸顶灯", fireDate: fireDate, plan: Self.plan, sourceScope: homeScope
        )
        ScheduledCommand.save([timer], to: store.userDefaults)

        store.serverURLString = Self.otherHomeURL
        store.startListening()
        #expect(store.scheduledCommands.isEmpty)

        var notified: [ScheduledCommand] = []
        store.onMissedScheduledCommand = { notified.append($0) }
        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id])

        // The source came back after the moment the timer was due; it must ask, not run silently.
        store.restoreScheduledCommands(now: fireDate.addingTimeInterval(120))
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.map(\.id) == [timer.id])
        #expect(notified.map(\.id) == [timer.id])
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A locked Mac leaves 立即补执行 pending and runs it after unlocking")
    @MainActor
    func lockedMissedRunStaysPending() async throws {
        let (store, mock) = try await makeStore()
        let homeScope = try #require(store.connectionScopeIdentifier)
        let expired = ScheduledCommand(
            reply: "10 分钟后关闭书房吸顶灯",
            fireDate: Date().addingTimeInterval(-120),
            plan: Self.plan,
            sourceScope: homeScope
        )
        ScheduledCommand.save([expired], to: store.userDefaults)
        store.restoreScheduledCommands()
        #expect(store.missedScheduledCommands.map(\.id) == [expired.id])

        store.setScreenLocked(true)
        #expect(await store.runMissedScheduledCommand(id: expired.id) == nil)
        #expect(store.missedScheduledCommands.map(\.id) == [expired.id], "A refused run stays in the list")
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        #expect(await mock.executedCommands.isEmpty)

        store.setScreenLocked(false)
        _ = await store.runMissedScheduledCommand(id: expired.id)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("A missed timer from another source is refused and kept")
    @MainActor
    func missedRunRefusesAnotherScope() async throws {
        let (store, mock) = try await makeStore()
        let foreign = ScheduledCommand(
            reply: "关闭书房吸顶灯",
            fireDate: Date().addingTimeInterval(-120),
            plan: Self.plan,
            sourceScope: "ha:\(Self.otherHomeURL)"
        )
        ScheduledCommand.save([foreign], to: store.userDefaults)
        store.restoreScheduledCommands()
        #expect(store.missedScheduledCommands.isEmpty)

        #expect(await store.runMissedScheduledCommand(id: foreign.id) == nil)
        #expect(await mock.executedCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [foreign.id])

        // Even if a stale entry reached the list, the scope guard keeps it there.
        store.missedScheduledCommands = [foreign]
        #expect(await store.runMissedScheduledCommand(id: foreign.id) == nil)
        #expect(store.missedScheduledCommands.map(\.id) == [foreign.id])
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A source switch during a timer's sleep keeps it from running")
    @MainActor
    func switchDuringSleepStopsTimer() async throws {
        let (store, mock) = try await makeStore()
        let gate = AsyncStream.makeStream(of: Void.self)
        store.assistantSleep = { _ in
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.count == 1)

        // The scope changes before the provider swap re-partitions the timers.
        store.serverURLString = Self.otherHomeURL
        gate.continuation.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(await mock.executedCommands.isEmpty)
        #expect(store.scheduledCommands.count == 1, "The timer was neither run nor silently dropped")
    }

    @Test("Timers saved before scopes existed still decode and join the current source")
    @MainActor
    func legacyTimerAdoptsCurrentScope() async throws {
        let (store, mock) = try await makeStore()
        let id = UUID(uuidString: "0E7A2C6B-8C4F-4A0D-9D7E-5C3B1F2A6D41")!
        // Exactly what 1.2.0 wrote: no `sourceScope` key at all, Date as seconds since 2001.
        let legacyJSON = """
        [{"id":"\(id.uuidString)","reply":"10 分钟后关闭书房吸顶灯","fireDate":780000000,\
        "plan":{"intents":[{"targetId":"dev_study_ceiling","operation":{"power":{"_0":false}}}],\
        "reply":"已关闭书房吸顶灯","source":"local","suggestions":[]}}]
        """
        store.userDefaults.set(Data(legacyJSON.utf8), forKey: ScheduledCommand.storageKey)

        let decoded = ScheduledCommand.load(from: store.userDefaults)
        #expect(decoded.map(\.id) == [id])
        #expect(decoded.first?.sourceScope == nil)

        store.restoreScheduledCommands()
        let adopted = try #require(store.missedScheduledCommands.first)
        #expect(adopted.id == id)
        #expect(adopted.sourceScope == store.connectionScopeIdentifier)
        #expect(ScheduledCommand.load(from: store.userDefaults).first?.sourceScope == store.connectionScopeIdentifier)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A timer firing while the Mac is locked still runs")
    @MainActor
    func timerRunsWhileLocked() async throws {
        let (store, mock) = try await makeStore()
        store.setScreenLocked(true)
        store.assistantSleep = { _ in }

        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        for _ in 0..<100 where store.devices.first?.isActiveOn != false {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.devices.first?.isActiveOn == false)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("An unresolved source neither arms nor adopts timers")
    @MainActor
    func unresolvedScopeKeepsTimersParked() async throws {
        let (store, mock) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        #expect(store.connectionScopeIdentifier == nil)

        let legacy = ScheduledCommand(
            reply: "关闭书房吸顶灯", fireDate: Date().addingTimeInterval(-120), plan: Self.plan
        )
        ScheduledCommand.save([legacy], to: store.userDefaults)
        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.isEmpty)
        let persisted = ScheduledCommand.load(from: store.userDefaults)
        #expect(persisted.map(\.id) == [legacy.id])
        #expect(persisted.first?.sourceScope == nil, "Without a source nothing may claim the timer")

        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.toastNotice?.isError == true)
        #expect(await mock.executedCommands.isEmpty)
    }
}
