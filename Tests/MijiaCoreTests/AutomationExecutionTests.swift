import Foundation
import Testing
@testable import MijiaCore

/// #59: automation executions go through HomeStore's normal dispatch path, never train habits, and
/// offer undo even for a single device.
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
