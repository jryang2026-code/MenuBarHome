import Foundation
import Testing
@testable import MijiaCore

/// #113: the zero-delay Top-4 proactive suggestion engine.
/// The same phase order and filters are mirrored in `windows/src/core/assistant.ts`
/// and pinned by `Tests/Fixtures/habit_golden.json`.
struct ProactiveSuggestionEngineTests {
    private let evening = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 21, minute: 30))!

    private let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80, availableEffects: ["Day", "Night"]))
    )
    private let floorLamp = SmartDevice(
        id: "dev_floor_lamp", name: "落地灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "light.floor", isOn: true))
    )
    private let deskLamp = SmartDevice(
        id: "dev_desk_lamp", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.desk", isOn: false))
    )
    private let ac = SmartDevice(
        id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mt0", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
            targetTemperature: 25, currentTemperature: 29.5
        ))
    )
    private let plug = SmartDevice(
        id: "dev_plug", name: "路由器插座", roomId: "ke_ting", roomName: "客厅",
        model: "chuangmi.plug.m3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.plug", isOn: true))
    )
    private let sensor = SmartDevice(
        id: "dev_sensor", name: "温湿度计", roomId: "ke_ting", roomName: "客厅",
        model: "miaomiaoce.sensor_ht.t1", isOnline: true,
        kind: .sensor(SensorSpec(temperature: 29.5, humidity: 60))
    )

    private var devices: [SmartDevice] {
        [ceiling, floorLamp, deskLamp, ac, plug, sensor]
    }

    private func operationKeys(of suggestion: AssistantSuggestion) -> [String] {
        suggestion.intents.compactMap { UserHabitMemory.encodeOperation($0.operation) }
    }

    @Test("Favorite padding skips devices the assistant cannot power")
    func favoritePaddingSkipsNonToggleableDevices() {
        let memory = UserHabitMemory()
        let fridge = SmartDevice(
            id: "dev_fridge", name: "双开门冰箱", roomId: "ke_ting", roomName: "客厅",
            model: "xiaomi.fridge.dual", isOnline: true,
            kind: .fridge(FridgeSpec(
                modeEntityId: nil,
                currentMode: "normal",
                availableModes: ["normal"],
                fridgeCurrentTemp: 4.0,
                fridgeTargetTemp: 4.0,
                fridgeTargetEntityId: nil,
                freezerCurrentTemp: nil,
                freezerTargetTemp: -18,
                freezerTargetEntityId: nil
            ))
        )
        let onLight = SmartDevice(
            id: "dev_light", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
            model: "yeelink.light.ceiling20", isOnline: true,
            kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
        )
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 29.5, humidity: 60)]

        let suggestions = memory.topSuggestions(
            for: evening,
            devices: [fridge, onLight],
            scenes: [],
            favoriteIds: ["dev_fridge"],
            environmentReadings: readings
        )

        // The fridge never becomes a suggestion even though it is starred and online.
        #expect(suggestions.map(\.id) == ["active:\(onLight.id):off"])
    }

    @Test("Returns nothing without controllable online devices")
    func emptyWithoutDevices() {
        let memory = UserHabitMemory()
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 29.5, humidity: 60)]

        #expect(memory.topSuggestions(for: evening, devices: [], scenes: [], environmentReadings: readings).isEmpty)

        let offline = SmartDevice(
            id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
            model: "xiaomi.aircondition.mt0", isOnline: false,
            kind: .climate(ClimateSpec(entityId: "climate.ac", isOn: true, hvacMode: "cool", availableModes: ["off", "cool"], targetTemperature: 25))
        )
        #expect(memory.topSuggestions(for: evening, devices: [offline], scenes: [], environmentReadings: readings).isEmpty)
    }

    @Test("Habit entries still win and the engine caps at the requested limit")
    func habitLimitStillApplies() {
        var memory = UserHabitMemory()
        for _ in 0..<2 {
            memory.record(
                utterance: nil,
                intents: [
                    DeviceIntent(targetId: "dev_ceiling", operation: .lightEffect("Night")),
                    DeviceIntent(targetId: "dev_floor_lamp", operation: .power(false)),
                ],
                devices: devices,
                scenes: [],
                now: evening
            )
        }

        let suggestions = memory.topSuggestions(for: evening, devices: devices, scenes: [], limit: 2)

        // Habit suggestions come first and the limit caps before padding starts.
        #expect(suggestions.count == 2)
        #expect(operationKeys(of: suggestions[0]) == ["effect:Night"])
        #expect(operationKeys(of: suggestions[1]) == ["power:off"])
        #expect(suggestions[1].intents[0].targetId == "dev_floor_lamp")
    }
}
