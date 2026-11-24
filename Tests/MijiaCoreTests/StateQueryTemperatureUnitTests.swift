import Foundation
import Testing
@testable import MijiaCore

/// Assistant state-query replies must speak the °C/°F display preference, not always °C (#428).
/// The stored values stay Celsius; the digits follow the panel's conventions for the same surface
/// (room temperature one decimal, setpoint whole digits).
struct StateQueryTemperatureUnitTests {
    private static let envSensor = SmartDevice(
        id: "dev_env", name: "客厅温度计", roomId: "ke_ting", roomName: "客厅",
        model: "miaomiaoce.sensor_ht.t1", isOnline: true,
        kind: .sensor(SensorSpec(temperature: 27.5, humidity: 52, battery: 80))
    )
    private static let livingAC = SmartDevice(
        id: "dev_living_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mc5", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.dev_living_ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat", "dry", "fan_only"],
            targetTemperature: 26, currentTemperature: 27.5, minTemp: 16, maxTemp: 31, step: 0.5
        ))
    )
    private static let devices = [envSensor, livingAC]

    @Test("The room temperature reply follows the display unit, one decimal like the panel")
    func roomTemperatureFollowsPreference() {
        #expect(Self.answer("客厅温度计温度是多少", unit: .celsius) == "客厅温度计：27.5°C")
        #expect(Self.answer("客厅温度计温度是多少", unit: .fahrenheit) == "客厅温度计：81.5°F")

        // An integer reading keeps the panel's temperature-only one-decimal shape in both units.
        let whole = SmartDevice(
            id: "dev_env", name: "客厅温度计", roomId: "ke_ting", roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t1", isOnline: true,
            kind: .sensor(SensorSpec(temperature: 26))
        )
        #expect(Self.answer("客厅温度计温度是多少", devices: [whole], unit: .celsius) == "客厅温度计：26.0°C")
        #expect(Self.answer("客厅温度计温度是多少", devices: [whole], unit: .fahrenheit) == "客厅温度计：78.8°F")
    }

    @Test("The AC setpoint reply follows the display unit with the panel's digits")
    func setpointFollowsPreference() {
        #expect(Self.answer("客厅空调设置了几度", unit: .celsius) == "客厅空调：设定 26°C")
        #expect(Self.answer("客厅空调设置了几度", unit: .fahrenheit) == "客厅空调：设定 79°F")
    }

    private static func answer(
        _ utterance: String,
        devices: [SmartDevice] = devices,
        unit: TemperatureUnit
    ) -> String? {
        guard let query = StateQuery.parse(utterance) else {
            Issue.record("the utterance must parse as a state query: \(utterance)")
            return nil
        }
        let plan = L10n.$overrideTemperatureUnit.withValue(unit) { query.answer(devices: devices) }
        return plan?.reply
    }
}
