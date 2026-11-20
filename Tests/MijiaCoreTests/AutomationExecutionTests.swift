import Foundation
import Testing
import StateTestSupport
@testable import MijiaCore

/// #59: automation executions go through HomeStore's normal dispatch path, never train habits, and
/// offer undo even for a single device.
@Suite(.timeLimit(.minutes(1)))
struct AutomationExecutionTests {
    static let studyLight = SmartDevice(
        id: "light_study",
        name: "书房台灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )
    static let hiddenLight = SmartDevice(
        id: "light_aquarium",
        name: "鱼缸灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.strip2",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.aquarium", isOn: true))
    )
    static let offlineLight = SmartDevice(
        id: "light_balcony",
        name: "阳台灯",
        roomId: "balcony",
        roomName: "阳台",
        model: "yeelink.light.lamp4",
        isOnline: false,
        kind: .light(LightSpec(entityId: "light.balcony", isOn: false))
    )
    static let scenes = [
        HomeScene(id: "scene_home", name: "回家模式", entityId: "scene.home")
    ]

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: [Self.studyLight, Self.hiddenLight, Self.offlineLight],
            scenes: Self.scenes
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.automation.exec.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.hideDevice(Self.hiddenLight.id)
        return (store, mock)
    }

    @Test("Disabling and immediately re-enabling stops an in-flight device rule and preserves undo")
    @MainActor
    func stopsRemainingWrites() async throws {
        let (store, mock) = try await makeStore()
        store.assistantNow = { Date(timeIntervalSince1970: 1_800_000_000) }
        await mock.holdNextExecute()
        let task = Task {
            await store.runAutomation(intents: [
                .init(targetId: Self.studyLight.id, operation: .power(false)),
                .init(targetId: Self.hiddenLight.id, operation: .power(false))
            ], title: "离开关灯")
        }
        try await awaitState { store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false }
        #expect(store.setEventAutomationEnabled(false))
        #expect(store.setEventAutomationEnabled(true))
        await mock.releaseExecute()
        let result = await task.value
        store.pauseUndoBannerCountdown()
        #expect(result.attemptedCount == 1)
        #expect(result.succeededCount == 1)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study", isOn: false)])
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.study", isOn: true)])
    }

    private struct HeldWriteProvider: HomeProvider {
        let mock: MockHomeProvider
        let gate: ScheduledCommandTestSupport.SleepGate

        func events() -> AsyncStream<HomeProviderEvent> { mock.events() }
        func refreshNow() async { await mock.refreshNow() }

        func execute(_ command: DeviceCommand) async throws {
            if case .setLightBrightness = command { await gate.sleep() }
            try await mock.execute(command)
        }
    }

    @Test("Disabling during a quick action keeps the first step and skips its pending color write")
    @MainActor
    func stopsRemainingQuickActionSteps() async throws {
        var light = Self.studyLight
        light.kind = .light(LightSpec(entityId: "light.study", isOn: true, brightnessPercent: 80, colorTempKelvin: 4000))
        let gate = ScheduledCommandTestSupport.SleepGate()
        let mock = MockHomeProvider(snapshot: .init(devices: [light]))
        let store = HomeStore(provider: HeldWriteProvider(mock: mock, gate: gate),
                              defaultsSuiteName: "test.automation.quick.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        let task = try #require(store.runAutomationQuickAction(.softNightLight))
        store.pauseUndoBannerCountdown()
        try await awaitState { gate.waiting == 1 }
        #expect(store.setEventAutomationEnabled(false))
        gate.release()
        #expect(await task.value == .partial)
        #expect(await mock.executedCommands == [.setLightBrightness(entityId: "light.study", percent: 15)])
        #expect(store.undoBanner?.restoreCommands == [.setLightBrightness(entityId: "light.study", percent: 80)])
    }

    @Test("Re-enabling accepts an already-off light and pauses unavailable quick actions")
    @MainActor
    func revalidatesQuickActions() async throws {
        let (store, mock) = try await makeStore()
        var light = Self.studyLight
        light.kind = .light(LightSpec(entityId: "light.study", isOn: false, brightnessWritable: false, colorWritable: false))
        await mock.updateSnapshot(.init(devices: [light], scenes: Self.scenes))
        try await awaitState { store.devices.count == 1 && store.devices.first?.isActiveOn == false }

        let ruleStore = AutomationRuleStore(defaults: store.userDefaults)
        let lightsOff = AutomationRule(trigger: .away, action: .quickAction(.lightsOff))
        let softLight = AutomationRule(trigger: .away, action: .quickAction(.softNightLight))
        let sleepOff = AutomationRule(trigger: .away, action: .quickAction(.climateSleepOff))
        ruleStore.save([lightsOff, softLight, sleepOff])
        #expect(store.setEventAutomationEnabled(false))
        #expect(ruleStore.load() == [lightsOff, softLight, sleepOff])
        #expect(store.setEventAutomationEnabled(true))
        #expect(ruleStore.load().map(\.isEnabled) == [true, false, false])
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Re-enabling retains a valid scene rule in a home without devices")
    @MainActor
    func revalidatesSceneOnlyHome() async throws {
        let (store, mock) = try await makeStore()
        await mock.updateSnapshot(.init(scenes: Self.scenes))
        try await awaitState { store.devices.isEmpty && store.scenes == Self.scenes }
        let rule = AutomationRule(trigger: .back, action: .scene(sceneId: "scene_home"))
        let ruleStore = store.automationRuleStore
        ruleStore.save([rule])
        #expect(store.setEventAutomationEnabled(false))
        #expect(store.setEventAutomationEnabled(true))
        #expect(ruleStore.load() == [rule])
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A device rule runs through the store, keeps its undo banner, and records no habit")
    @MainActor
    func deviceAutomation() async throws {
        let (store, mock) = try await makeStore()
        let plan = await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.studyLight.id, operation: .power(false))],
            title: "锁屏关灯"
        )

        #expect(plan.reply == "锁屏关灯")
        #expect(store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false)
        #expect(store.devices.first(where: { $0.id == Self.hiddenLight.id })?.isActiveOn == true)
        #expect(store.undoBanner?.title == "锁屏关灯")
        #expect(store.undoBanner?.restoreCommands == [
            .setLightPower(entityId: "light.study", isOn: true)
        ])
        // Automation is not a habit signal (#34).
        #expect(store.userHabitMemory.entries.isEmpty)
        #expect(store.userHabitMemory.phrases.isEmpty)
        let commands = await mock.executedCommands
        #expect(commands == [.setLightPower(entityId: "light.study", isOn: false)])
    }

    @Test("A scene rule activates the scene and offers no device undo")
    @MainActor
    func sceneAutomation() async throws {
        let (store, mock) = try await makeStore()
        _ = await store.runAutomation(
            intents: [DeviceIntent(targetId: "scene_home", operation: .activateScene)],
            title: "接入显示器"
        )

        let commands = await mock.executedCommands
        #expect(commands == [.activateScene(entityId: "scene.home")])
        #expect(store.undoBanner == nil)
        #expect(store.userHabitMemory.entries.isEmpty)
    }

    @Test("Banner undo consumes the command so a second undo cannot overwrite a later manual change")
    @MainActor
    func bannerUndoIsConsumed() async throws {
        let (store, mock) = try await makeStore()
        await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.studyLight.id, operation: .power(false))],
            title: "锁屏关灯"
        )
        store.undoTurnAllOff()
        #expect(store.lastAssistantActionAt == nil)
        for _ in 0..<50 {
            if await mock.executedCommands.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let light = try #require(store.devices.first(where: { $0.id == Self.studyLight.id }))
        let task = try #require(store.togglePrimary(light))
        #expect(await task.value)
        await store.runAssistantCommand("撤销")
        #expect(store.devices.first(where: { $0.id == Self.studyLight.id })?.isActiveOn == false)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.study", isOn: true),
            .setLightPower(entityId: "light.study", isOn: false)
        ])
    }

    @Test("External entry points only see visible, online, primary-toggleable devices")
    @MainActor
    func controllableDevices() async throws {
        let (store, _) = try await makeStore()
        #expect(store.controllableDevices.map(\.id) == [Self.studyLight.id])
    }

    @Test("High-risk automation rules require confirmation for turning on hazards and closing barrier covers")
    func highRiskAutomationRuleConfirmation() throws {
        let heaterPlug = SmartDevice(
            id: "plug_heater",
            name: "卧室取暖器插座",
            roomId: "bedroom",
            roomName: "卧室",
            model: "chuangmi.plug.212a01",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: false))
        )
        let garageDoor = SmartDevice(
            id: "cover_garage",
            name: "地下车库门",
            roomId: "garage",
            roomName: "车库",
            model: "lumi.curtain.v1",
            isOnline: true,
            kind: .cover(CoverSpec(entityId: "cover.garage_door", subtype: .garageDoor))
        )
        let devices = [Self.studyLight, heaterPlug, garageDoor]

        let turnOnRule = AutomationRule(
            trigger: .back,
            action: .devices(ids: [heaterPlug.id], isOn: true)
        )
        let confirmation = turnOnRule.highRiskConfirmation(devices: devices)
        #expect(confirmation != nil)
        #expect(confirmation?.message.contains("卧室取暖器插座") == true)
        #expect(!turnOnRule.highRiskApproved)

        let turnOffRule = AutomationRule(
            trigger: .away,
            action: .devices(ids: [heaterPlug.id], isOn: false)
        )
        #expect(turnOffRule.highRiskConfirmation(devices: devices) == nil)

        let closeGarageRule = AutomationRule(
            trigger: .away,
            action: .devices(ids: [garageDoor.id], isOn: false)
        )
        #expect(closeGarageRule.highRiskConfirmation(devices: devices) != nil)

        let lightRule = AutomationRule(
            trigger: .back,
            action: .devices(ids: [Self.studyLight.id], isOn: true)
        )
        #expect(lightRule.highRiskConfirmation(devices: devices) == nil)

        let approvedRule = AutomationRule(
            trigger: .back,
            action: .devices(ids: [heaterPlug.id], isOn: true),
            highRiskApproved: true
        )
        let data = try JSONEncoder().encode(approvedRule)
        let decoded = try JSONDecoder().decode(AutomationRule.self, from: data)
        #expect(decoded.highRiskApproved == true)
    }

    @Test("runAutomation returns typed attempted, succeeded, and failed counts for partial and total failures")
    @MainActor
    func runAutomationTypedOutcome() async throws {
        let deskLight = SmartDevice(
            id: "light_desk",
            name: "工作台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.desk", isOn: true))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.studyLight, deskLight]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.automation.outcome.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        await mock.setFailingCommands { $0 == .setLightPower(entityId: "light.desk", isOn: false) }
        let partial = await store.runAutomation(
            intents: [
                DeviceIntent(targetId: Self.studyLight.id, operation: .power(false)),
                DeviceIntent(targetId: deskLight.id, operation: .power(false))
            ],
            title: "锁屏关灯"
        )
        #expect(partial.attemptedCount == 2)
        #expect(partial.succeededCount == 1)
        #expect(partial.failedCount == 1)
        #expect(partial.errorMessage != nil)

        await mock.setFailingCommands { _ in true }
        let totalFail = await store.runAutomation(
            intents: [DeviceIntent(targetId: deskLight.id, operation: .power(false))],
            title: "再次关灯"
        )
        #expect(totalFail.attemptedCount == 1)
        #expect(totalFail.succeededCount == 0)
        #expect(totalFail.failedCount == 1)
        #expect(totalFail.errorMessage != nil)
    }
}
