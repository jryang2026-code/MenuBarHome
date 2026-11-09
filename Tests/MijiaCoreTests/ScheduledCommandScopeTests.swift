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

    /// A device from another Mi Home: it keeps the timer from being confused with an empty store.
    static let kitchen = SmartDevice(
        id: "dev_kitchen", name: "厨房灯", roomId: "chu_fang", roomName: "厨房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.kitchen", isOn: true))
    )

    static let plan = IntentPlan(
        intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .power(false))],
        reply: "已关闭书房吸顶灯",
        source: .local
    )

    /// A second Home Assistant that is not the one this test store starts on.
    static let otherHomeURL = "http://192.0.2.20:8123"

    static let cnAccount = MiAccount(session: MiSession(
        userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
    ))
    static let deAccount = MiAccount(session: MiSession(
        userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
    ))
    static let miLamp = SmartDevice(
        id: "1234567890", name: "米家台灯", roomId: "wo_shi", roomName: "卧室",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:1234567890:2", isOn: true)),
        accountId: cnAccount.id
    )
    static let deLamp = SmartDevice(
        id: "{{DEVICE_ab12cd34}}", name: "德国台灯", roomId: "de_wo_shi", roomName: "卧室",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:{{DEVICE_ab12cd34}}:2", isOn: true)),
        accountId: deAccount.id
    )
    static let lgTV = SmartDevice(
        id: LGWebOSProtocol.deviceId, name: "LG电视", roomId: "ke_ting", roomName: "客厅",
        model: "lg.webos.oled42c2pca", isOnline: true,
        kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 12))
    )

    /// Home Assistant plus one Xiaomi account, both configured.
    @MainActor
    private func makeDualSourceStore(
        devices: [SmartDevice]? = nil
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: devices ?? [Self.ceiling, Self.miLamp],
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.hasHASource = true
        store.miAccounts = [Self.cnAccount]
        store.miSessionMaskedUserId = Self.cnAccount.maskedUserId
        store.miSessionScopeIdentifier = Self.cnAccount.id
        store.homeBackend = .homeAssistant
        return (store, mock)
    }

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    /// Parks a timer inside `assistantSleep` until the test releases it; cancellation still wakes it, so
    /// a source switch never depends on a wall-clock countdown.
    @MainActor
    private final class SleepGate {
        private var continuation: AsyncStream<Void>.Continuation
        private var stream: AsyncStream<Void>
        private(set) var waiting = 0

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        }

        func sleep() async {
            waiting += 1
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            waiting -= 1
        }

        func release() {
            continuation.yield(())
        }
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
    }

    @Test("A timer belongs to the source that created it, survives another source's save and re-arms on return")
    @MainActor
    func timerFollowsItsSource() async throws {
        let (store, mock) = try await makeStore()
        let homeURL = store.serverURLString
        let homeGate = SleepGate()
        store.assistantSleep = { _ in await homeGate.sleep() }

        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let homeTimer = try #require(store.scheduledCommands.first)
        let homeScope = try #require(homeTimer.sourceScope)
        #expect(homeScope == store.connectionScopeIdentifier)
        await waitUntil { homeGate.waiting == 1 }

        // The user points the app at another Home Assistant while this timer counts down.
        store.serverURLString = Self.otherHomeURL
        store.startListening()
        #expect(store.scheduledCommands.isEmpty, "Another source's timer must not be armed here")
        #expect(store.missedScheduledCommands.isEmpty)
        try await store.waitForTestSnapshot()

        // A timer set on the new source is saved next to the old one instead of deleting it.
        let otherGate = SleepGate()
        store.assistantSleep = { _ in await otherGate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let otherTimer = try #require(store.scheduledCommands.first)
        #expect(otherTimer.sourceScope != homeScope)
        await waitUntil { otherGate.waiting == 1 }
        #expect(Set(ScheduledCommand.load(from: store.userDefaults).map(\.id)) == [homeTimer.id, otherTimer.id])
        #expect(await mock.executedCommands.isEmpty, "No timer of an inactive source may fire")

        // Back home: the original timer is still there and runs.
        let rearmGate = SleepGate()
        store.assistantSleep = { _ in await rearmGate.sleep() }
        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [homeTimer.id])
        await waitUntil { rearmGate.waiting == 1 }
        rearmGate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(store.scheduledCommands.isEmpty)
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

    @Test("A switch while 立即补执行 waits for the snapshot keeps the entry and sends nothing")
    @MainActor
    func missedRunRefusedWhenScopeChangesDuringTheSnapshotWait() async throws {
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

        // No snapshot yet, so the run parks in `waitForInitialSnapshotIfNeeded`.
        store.devices = []
        let run = Task { await store.runMissedScheduledCommand(id: expired.id) }
        for _ in 0..<5 { await Task.yield() }
        store.serverURLString = Self.otherHomeURL
        store.devices = [Self.ceiling]

        #expect(await run.value == nil)
        #expect(store.missedScheduledCommands.map(\.id) == [expired.id])
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [expired.id])
        #expect(await mock.executedCommands.isEmpty)
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

    @Test("A missed timer dismissed while 立即补执行 waits sends nothing")
    @MainActor
    func dismissDuringSnapshotWaitSendsNothing() async throws {
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

        store.devices = []
        let run = Task { await store.runMissedScheduledCommand(id: expired.id) }
        for _ in 0..<10 { await Task.yield() }
        store.dismissMissedScheduledCommand(id: expired.id)
        store.devices = [Self.ceiling]

        #expect(await run.value == nil)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Cancelling all timers while 立即补执行 waits sends nothing")
    @MainActor
    func cancelAllDuringSnapshotWaitSendsNothing() async throws {
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

        store.devices = []
        let run = Task { await store.runMissedScheduledCommand(id: expired.id) }
        for _ in 0..<10 { await Task.yield() }
        #expect(store.cancelScheduledCommands() == 1)
        store.devices = [Self.ceiling]

        #expect(await run.value == nil)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Two 立即补执行 taps on the same missed timer run it once")
    @MainActor
    func concurrentMissedRunsExecuteOnce() async throws {
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

        store.devices = []
        let first = Task { await store.runMissedScheduledCommand(id: expired.id) }
        let second = Task { await store.runMissedScheduledCommand(id: expired.id) }
        for _ in 0..<10 { await Task.yield() }
        store.devices = [Self.ceiling]

        let firstResult = await first.value
        let secondResult = await second.value
        #expect((firstResult == nil) != (secondResult == nil), "Only one tap may run the plan")
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("A timer whose device is not in the current home waits for confirmation")
    @MainActor
    func timerWithAbsentTargetWaitsForConfirmation() async throws {
        let (store, mock) = try await makeStore()
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let timer = try #require(store.scheduledCommands.first)
        await waitUntil { gate.waiting == 1 }

        // Selecting another Mi Home keeps the account scope but replaces the device list.
        store.devices = [Self.kitchen]
        gate.release()
        await waitUntil { store.missedScheduledCommands.contains { $0.id == timer.id } }

        #expect(store.missedScheduledCommands.map(\.id) == [timer.id])
        #expect(store.scheduledCommands.isEmpty)
        #expect(await mock.executedCommands.isEmpty)

        // Confirming it must not send the command to a device that is not here either.
        #expect(await store.runMissedScheduledCommand(id: timer.id) == nil)
        #expect(store.missedScheduledCommands.map(\.id) == [timer.id])
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == "定时的目标设备不在当前家庭，未执行")
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A plan with no device targets is not misrouted into the missed flow")
    @MainActor
    func emptyPlanIsConsumed() async throws {
        let (store, mock) = try await makeStore()
        let homeScope = try #require(store.connectionScopeIdentifier)
        let empty = ScheduledCommand(
            reply: "空计划",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(intents: [], reply: "", source: .local),
            sourceScope: homeScope
        )
        ScheduledCommand.save([empty], to: store.userDefaults)
        store.assistantSleep = { _ in }
        store.restoreScheduledCommands()
        await waitUntil { store.scheduledCommands.isEmpty }

        #expect(store.missedScheduledCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A switch during execution does not let a consumed timer reappear")
    @MainActor
    func switchDuringExecutionLeavesNoRecord() async throws {
        let (store, mock) = try await makeStore()
        let homeURL = store.serverURLString
        store.assistantSleep = { _ in }
        await mock.holdNextExecute()
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let entry = try #require(store.scheduledCommands.first)
        await waitUntil { await mock.executeStarted >= 1 }

        // Switch while the send is in flight: restore parks the entry as another source's.
        store.serverURLString = Self.otherHomeURL
        store.startListening()
        await mock.releaseExecute()
        await waitUntil { await mock.executedCommands.count == 1 }

        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(!ScheduledCommand.load(from: store.userDefaults).contains { $0.id == entry.id })
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("A switch away and back while the send is in flight cannot offer the timer again")
    @MainActor
    func roundTripDuringExecutionRunsOnce() async throws {
        let (store, mock) = try await makeStore()
        let homeURL = store.serverURLString
        store.assistantSleep = { _ in }
        await mock.holdNextExecute()
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        let entry = try #require(store.scheduledCommands.first)
        await waitUntil { await mock.executeStarted >= 1 }

        // Consumed before the request goes out: a re-partition during the in-flight send has
        // nothing left to bring back as missed.
        #expect(!ScheduledCommand.load(from: store.userDefaults).contains { $0.id == entry.id })

        store.serverURLString = Self.otherHomeURL
        store.startListening()
        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.isEmpty, "An in-flight timer must not come back as missed")
        #expect(!ScheduledCommand.load(from: store.userDefaults).contains { $0.id == entry.id })

        await mock.releaseExecute()
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).isEmpty)
    }

    @Test("A source switch during a timer's sleep keeps it from running")
    @MainActor
    func switchDuringSleepStopsTimer() async throws {
        let (store, mock) = try await makeStore()
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.count == 1)
        await waitUntil { gate.waiting == 1 }

        // The scope changes before the provider swap re-partitions the timers.
        store.serverURLString = Self.otherHomeURL
        gate.release()
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

    // MARK: - The stamp is the connected source set (ADR-0019)

    @Test("Scope matching needs an intersection and never crosses Home Assistant servers")
    @MainActor
    func scopeMatchingRule() {
        #expect(HomeStore.sourceScopesMatch(["ha:a", "mi:x"], active: ["mi:x"]))
        #expect(!HomeStore.sourceScopesMatch(["ha:a", "mi:x"], active: ["ha:b", "mi:x"]))
        #expect(!HomeStore.sourceScopesMatch(["mi:x"], active: ["ha:a", "mi:x"]))
        #expect(!HomeStore.sourceScopesMatch(["mi:x"], active: ["mi:y"]))
        #expect(HomeStore.sourceScopesMatch(["demo"], active: ["demo"]))
    }

    @Test("A Xiaomi-device timer keeps running after Home Assistant is removed")
    @MainActor
    func xiaomiTimerSurvivesHARemoval() async throws {
        let (store, mock) = try await makeDualSourceStore()
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭米家台灯")
        let timer = try #require(store.scheduledCommands.first)
        let haScope = "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(store.serverURLString))"
        #expect(Set(try #require(timer.effectiveSourceScopes)) == [Self.cnAccount.id, haScope])
        await waitUntil { gate.waiting == 1 }

        store.hasHASource = false
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id])

        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(await mock.executedCommands == [.setLightPower(entityId: "miot:1234567890:2", isOn: false)])
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(ScheduledCommand.load(from: store.userDefaults).isEmpty)
    }

    @Test("A captured HA A vetoes arming on HA B even while a Xiaomi scope still overlaps")
    @MainActor
    func haServerChangeVetoesTheWholeStamp() async throws {
        let (store, mock) = try await makeDualSourceStore()
        let homeURL = store.serverURLString
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭米家台灯")
        let timer = try #require(store.scheduledCommands.first)
        await waitUntil { gate.waiting == 1 }

        store.hasHASource = false
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id], "Removing HA leaves the Mi source matching")

        store.serverURLString = Self.otherHomeURL
        store.hasHASource = true
        store.startListening()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.map(\.id) == [timer.id])
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [timer.id])
        for _ in 0..<50 { await Task.yield() }
        #expect(await mock.executedCommands.isEmpty, "Nothing may reach server B")

        store.serverURLString = homeURL
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id], "Switching back to A re-arms the timer")
        _ = store.cancelScheduledCommands()
    }

    @Test("Connecting a Home Assistant after creation holds a Xiaomi-only timer back until it is removed")
    @MainActor
    func haAddedAfterCreationHoldsTheTimerBack() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.miLamp], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.homeBackend = .xiaomiCloud
        store.hasHASource = false
        store.miAccounts = [Self.cnAccount]
        store.miSessionMaskedUserId = Self.cnAccount.maskedUserId
        store.miSessionScopeIdentifier = Self.cnAccount.id
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        _ = await store.runAssistantCommand("10分钟后关闭米家台灯")
        let timer = try #require(store.scheduledCommands.first)
        #expect(timer.effectiveSourceScopes == [Self.cnAccount.id])
        await waitUntil { gate.waiting == 1 }

        // A merged card id can be claimed by a Home Assistant the timer never saw when it was created.
        store.hasHASource = true
        store.startListening()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.map(\.id) == [timer.id])
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [timer.id])
        for _ in 0..<50 { await Task.yield() }
        #expect(await mock.executedCommands.isEmpty)

        // Removing that HA restores the original Xiaomi-only match.
        store.hasHASource = false
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id])

        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(await mock.executedCommands == [.setLightPower(entityId: "miot:1234567890:2", isOn: false)])
    }

    @Test("Removing the first Mi account keeps a timer stamped with both")
    @MainActor
    func secondAccountTimerSurvivesFirstAccountRemoval() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.miLamp, Self.deLamp], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.homeBackend = .xiaomiCloud
        store.hasHASource = false
        store.miAccounts = [Self.cnAccount, Self.deAccount]
        store.miSessionMaskedUserId = Self.cnAccount.maskedUserId
        store.miSessionScopeIdentifier = Self.cnAccount.id
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        _ = await store.runAssistantCommand("10分钟后关闭德国台灯")
        let timer = try #require(store.scheduledCommands.first)
        #expect(Set(try #require(timer.effectiveSourceScopes)) == [Self.cnAccount.id, Self.deAccount.id])
        await waitUntil { gate.waiting == 1 }

        store.miAccounts = [Self.deAccount]
        store.miSessionMaskedUserId = Self.deAccount.maskedUserId
        store.miSessionScopeIdentifier = Self.deAccount.id
        store.startListening()
        #expect(store.scheduledCommands.map(\.id) == [timer.id])

        gate.release()
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(await mock.executedCommands == [.setLightPower(entityId: "miot:\(Self.deLamp.id):2", isOn: false)])
    }

    @Test("A stamp from an unrelated source is foreign and stays on disk")
    @MainActor
    func unrelatedStampIsForeign() async throws {
        let (store, _) = try await makeStore()
        let foreign = ScheduledCommand(
            reply: "10 分钟后关闭书房吸顶灯",
            fireDate: Date().addingTimeInterval(600),
            plan: Self.plan,
            sourceScopes: ["mi:xx:0123456789abcdef"]
        )
        ScheduledCommand.save([foreign], to: store.userDefaults)

        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.map(\.id) == [foreign.id])
        #expect(ScheduledCommand.load(from: store.userDefaults).map(\.id) == [foreign.id])
    }

    @Test("A mixed plan stays one timer and its undo record covers every target")
    @MainActor
    func mixedPlanStaysOneEntry() async throws {
        let (store, mock) = try await makeDualSourceStore()
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        _ = await store.runAssistantCommand("10分钟后关闭米家台灯、书房吸顶灯")

        let timer = try #require(store.scheduledCommands.first)
        #expect(store.scheduledCommands.count == 1)
        #expect(Set(timer.plan.intents.map(\.targetId)) == [Self.miLamp.id, Self.ceiling.id])
        await waitUntil { gate.waiting == 1 }

        gate.release()
        await waitUntil { await mock.executedCommands.count == 2 }
        let executed = await mock.executedCommands
        #expect(executed.contains(.setLightPower(entityId: "miot:1234567890:2", isOn: false)))
        #expect(executed.contains(.setLightPower(entityId: "light.study_ceiling", isOn: false)))
        #expect(store.undoBanner?.restoreCommands.count == 2)
        #expect(store.lastAssistantUndo?.previous.count == 2)
        #expect(store.lastAssistantUndo?.restore.count == 2)
    }

    @Test("An LG TV without a backend map can still be scheduled in dual-source mode")
    @MainActor
    func lgTimerSchedulesInDualSourceMode() async throws {
        let (store, _) = try await makeDualSourceStore(devices: [Self.ceiling])
        store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10")
        store.applyLGDeviceUpdate(Self.lgTV)
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        _ = await store.runAssistantCommand("10分钟后关闭LG电视")
        #expect(store.scheduledCommands.count == 1)
        #expect(store.scheduledCommands.first?.plan.intents.map(\.targetId) == [Self.lgTV.id])
        _ = store.cancelScheduledCommands()
    }

    @Test("An LG-only timer skips the cloud snapshot guard")
    @MainActor
    func lgOnlyTimerSkipsSnapshotGuard() async throws {
        let (store, _) = try await makeDualSourceStore(devices: [Self.ceiling])
        store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10")
        store.applyLGDeviceUpdate(Self.lgTV)
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        // No cloud snapshot since the last listen; the LAN TV row is still current.
        store.startListening()
        store.eventTask?.cancel()
        #expect(store.listeningSnapshotGeneration == store.snapshotGeneration)
        _ = await store.runAssistantCommand("10分钟后关闭LG电视")
        #expect(store.scheduledCommands.count == 1)
        #expect(store.scheduledCommands.first?.plan.intents.map(\.targetId) == [Self.lgTV.id])
        _ = store.cancelScheduledCommands()
    }

    @Test("An LG timer with a cloud target still waits for a snapshot")
    @MainActor
    func mixedLGAndCloudTimerNeedsSnapshot() async throws {
        let (store, _) = try await makeDualSourceStore(devices: [Self.ceiling])
        store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.10")
        store.applyLGDeviceUpdate(Self.lgTV)
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        store.startListening()
        store.eventTask?.cancel()
        _ = await store.runAssistantCommand("10分钟后关闭LG电视、书房吸顶灯")
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.toastNotice?.message == "数据源尚未就绪，定时任务未创建")
    }

    @Test("Scheduling refuses until a snapshot arrives after startListening")
    @MainActor
    func refusesStaleDeviceListAfterStartListening() async throws {
        let (store, _) = try await makeStore()
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        store.startListening()
        store.eventTask?.cancel()
        #expect(store.listeningSnapshotGeneration == store.snapshotGeneration)
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.toastNotice?.message == "数据源尚未就绪，定时任务未创建")

        store.startListening()
        try await store.waitForTestSnapshot()
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.count == 1)
        _ = store.cancelScheduledCommands()
    }

    @Test("Demo mode still creates a timer after its snapshot")
    @MainActor
    func demoTimerStillSchedules() async throws {
        let (store, _) = try await makeStore()
        store.homeBackend = .demo
        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }

        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.count == 1)
        #expect(store.scheduledCommands.first?.effectiveSourceScopes == ["demo"])
        _ = store.cancelScheduledCommands()
    }

    @Test("An entry with only the older sourceScope field still decodes and arms")
    @MainActor
    func legacySingleScopeFieldStillWorks() async throws {
        let (store, mock) = try await makeStore()
        let id = UUID()
        let fireDate = Date().addingTimeInterval(600)
        let scope = "ha:\(HAWebSocketProvider.canonicalHistoryScopeURL(store.serverURLString))"
        // Exactly what the per-target build wrote: one `sourceScope`, no `sourceScopes` key.
        let legacyJSON = """
        [{"id":"\(id.uuidString)","reply":"10 分钟后关闭书房吸顶灯","fireDate":\(fireDate.timeIntervalSinceReferenceDate),\
        "plan":{"intents":[{"targetId":"dev_study_ceiling","operation":{"power":{"_0":false}}}],\
        "reply":"已关闭书房吸顶灯","source":"local","suggestions":[]},"sourceScope":"\(scope)"}]
        """
        store.userDefaults.set(Data(legacyJSON.utf8), forKey: ScheduledCommand.storageKey)

        let decoded = try #require(ScheduledCommand.load(from: store.userDefaults).first)
        #expect(decoded.sourceScopes == nil)
        #expect(decoded.effectiveSourceScopes == [scope])

        let gate = SleepGate()
        store.assistantSleep = { _ in await gate.sleep() }
        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.map(\.id) == [id])
        #expect(await mock.executedCommands.isEmpty)
        _ = store.cancelScheduledCommands()
    }
}
