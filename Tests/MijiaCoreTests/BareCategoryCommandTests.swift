import Foundation
import Testing
@testable import MijiaCore

/// GLOSSARY `BareCategoryCommand`: 「关灯」 looks only at the same-category devices that are on.
struct BareCategoryCommandTests {
    static func light(_ id: String, _ name: String, room: String, isOn: Bool) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: room, roomName: room,
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: isOn))
        )
    }

    static func climate(_ id: String, _ name: String, room: String, isOn: Bool) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: room, roomName: room,
            model: "xiaomi.aircondition.mt0", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.\(id)",
                isOn: isOn,
                hvacMode: isOn ? "cool" : "off",
                availableModes: ["off", "cool", "heat"],
                targetTemperature: 24
            ))
        )
    }

    static let studyCeiling = light("dev_study_ceiling", "书房吸顶灯", room: "书房", isOn: true)
    static let studyDesk = light("dev_study_desk", "书房台灯", room: "书房", isOn: true)
    static let bedroomLamp = light("dev_bedroom_lamp", "主卧床头灯", room: "主卧", isOn: true)
    static let kitchenLight = light("dev_kitchen_light", "厨房灯", room: "厨房", isOn: false)
    static let livingAC = climate("dev_living_ac", "客厅中央空调", room: "客厅", isOn: true)
    static let bedroomAC = climate("dev_bedroom_ac", "主卧挂机空调", room: "主卧", isOn: false)
    static let livingFan = SmartDevice(
        id: "dev_living_fan", name: "客厅循环扇", roomId: "客厅", roomName: "客厅",
        model: "dmaker.fan.p5", isOnline: true,
        kind: .fan(FanSpec(
            entityId: "fan.living", isOn: true, presetMode: "Level1",
            availablePresetModes: ["Level1", "Level2", "Level3"], isOscillating: false
        ))
    )
    static let purifier = SmartDevice(
        id: "dev_living_purifier", name: "客厅空净机", roomId: "客厅", roomName: "客厅",
        model: "zhimi.airp.rma3", isOnline: true,
        kind: .fan(FanSpec(entityId: "fan.purifier", isOn: true, availablePresetModes: ["Auto"]))
    )

    static let devices = [
        studyCeiling, studyDesk, bedroomLamp, kitchenLight,
        livingAC, bedroomAC, livingFan, purifier
    ]

    static func parse(_ text: String, panelRoomName: String? = nil, usageOrder: [String] = []) -> IntentPlan? {
        LocalIntentParser.parse(
            text,
            devices: devices,
            scenes: [],
            // These fixtures use the room name as the room id.
            panelRoom: panelRoomName.map { BareCategoryCommand.Room(id: $0, name: $0) },
            usageOrder: usageOrder
        )
    }

    @Test("关灯 with only one light on closes that light instead of the dark ones")
    func oneLightOnRunsDirectly() throws {
        let onlyBedroomOn = LocalIntentParser.parse(
            "关灯",
            devices: [Self.studyCeiling.off(), Self.studyDesk.off(), Self.bedroomLamp, Self.kitchenLight],
            scenes: []
        )
        let resolved = try #require(onlyBedroomOn)
        #expect(resolved.intents == [DeviceIntent(targetId: "dev_bedroom_lamp", operation: .power(false))])
        #expect(resolved.reply == "已关闭主卧床头灯")
    }

    @Test("Candidates cap at four devices and one 全部关掉 closes all of them")
    func candidatesCapAtFour() throws {
        let extras = (1...3).map { index in
            Self.light("dev_extra_\(index)", "额外灯\(index)", room: "房间\(index)", isOn: true)
        }
        let manyOn = [Self.studyCeiling, Self.studyDesk, Self.bedroomLamp] + extras
        let plan = try #require(LocalIntentParser.parse("关灯", devices: manyOn, scenes: []))
        #expect(plan.suggestions.count == 5)
        #expect(plan.suggestions.dropLast().allSatisfy { $0.intents.count == 1 })
        #expect(plan.suggestions.last?.intents.count == 6)
    }

    @Test("关空调 and 关风扇 follow the same rule for their own category")
    func otherCategoriesFollowTheSameRule() throws {
        let ac = try #require(Self.parse("关空调"))
        #expect(ac.intents == [DeviceIntent(targetId: "dev_living_ac", operation: .power(false))])

        let fan = try #require(Self.parse("关风扇"))
        #expect(fan.intents == [DeviceIntent(targetId: "dev_living_fan", operation: .power(false))])

        let purifier = try #require(Self.parse("关空气净化器"))
        #expect(purifier.intents == [DeviceIntent(targetId: "dev_living_purifier", operation: .power(false))])
    }

    @Test("Several running air conditioners offer candidates like lights")
    func otherCategoryCandidates() throws {
        let secondAC = Self.climate("dev_bedroom_ac_on", "次卧壁挂机", room: "次卧", isOn: true)
        let plan = try #require(LocalIntentParser.parse(
            "关空调",
            devices: [Self.livingAC, Self.bedroomAC, secondAC],
            scenes: []
        ))
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.map(\.title) == [
            "关闭客厅中央空调",
            "关闭次卧壁挂机",
            "全部关掉"
        ])
        #expect(plan.suggestions.last?.intents.count == 2)
    }

    @Test("Scope words keep their existing behavior")
    func scopeUnchanged() throws {
        let scoped = try #require(Self.parse("关掉所有的灯"))
        #expect(scoped.intents.map(\.targetId) == [
            "dev_study_ceiling",
            "dev_study_desk",
            "dev_bedroom_lamp",
            "dev_kitchen_light"
        ])

        let every = try #require(Self.parse("全部关灯"))
        #expect(every.intents.count == 4)

        let everyOn = try #require(Self.parse("打开所有的灯"))
        #expect(everyOn.intents.count == 4)
        #expect(everyOn.intents.allSatisfy { $0.operation == .power(true) })
    }

    // MARK: - Opening (#274)

    static let darkLights = [
        studyCeiling.off(), studyDesk.off(), bedroomLamp.off(), kitchenLight
    ]

    static func parse(_ text: String, devices: [SmartDevice], panelRoomName: String? = nil) -> IntentPlan? {
        LocalIntentParser.parse(
            text,
            devices: devices,
            scenes: [],
            panelRoom: panelRoomName.map { BareCategoryCommand.Room(id: $0, name: $0) }
        )
    }

    @Test("开灯 with one same-category device runs it directly")
    func oneDeviceOpensDirectly() throws {
        let plan = try #require(Self.parse("开灯", devices: [Self.studyCeiling.off()]))
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true))
        ])
        #expect(plan.reply == "已打开书房吸顶灯")
        #expect(plan.suggestions.isEmpty)
    }

    @Test("Open candidate order follows the habit order")
    func openCandidatesFollowHabitOrder() throws {
        let plan = try #require(LocalIntentParser.parse(
            "开灯",
            devices: Self.darkLights,
            scenes: [],
            usageOrder: ["dev_bedroom_lamp", "dev_kitchen_light"]
        ))
        #expect(plan.suggestions.map(\.title) == [
            "打开主卧床头灯",
            "打开厨房灯",
            "打开书房吸顶灯",
            "全部打开"
        ])
        #expect(plan.suggestions.last?.intents.count == 4)
    }
}

private extension SmartDevice {
    func off() -> SmartDevice {
        var copy = self
        if case .light(var spec) = copy.kind {
            spec.isOn = false
            copy.kind = .light(spec)
        }
        return copy
    }
}
