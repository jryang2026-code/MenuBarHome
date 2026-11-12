import Foundation
import Testing
@testable import MijiaCore

/// HA light dimming / colour-temperature writability. Mirrors the Windows cases in
/// `windows/tests/aiAndSessionParity.test.ts`.
struct HALightCapabilityTests {
    private func flags(_ attributes: [String: JSONValue]) -> (brightness: Bool, colorTemperature: Bool) {
        DeviceSynthesizer.haLightWritability(attributes)
    }

    @Test func supportedColorModesDecideWritability() {
        #expect(flags(["supported_color_modes": .array([.string("onoff")])]) == (false, false))
        #expect(flags(["supported_color_modes": .array([.string("brightness")])]) == (true, false))
        #expect(flags(["supported_color_modes": .array([.string("white")])]) == (true, false))
        #expect(flags(["supported_color_modes": .array([.string("color_temp")])]) == (true, true))
        // HA emulates `color_temp_kelvin` on colour lights, so an RGB-only strip keeps it.
        #expect(flags(["supported_color_modes": .array([.string("hs")])]) == (true, true))
        #expect(flags(["supported_color_modes": .array([.string("rgbww")])]) == (true, true))
    }

    @Test func offLightWithoutModesStaysWritableFromLegacyHints() {
        #expect(flags(["color_mode": .string("onoff")]) == (false, false))
        #expect(flags(["supported_features": .number(1)]) == (true, false))
        #expect(flags(["supported_features": .number(16)]) == (true, true))
        #expect(flags(["min_color_temp_kelvin": .number(2700)]) == (true, true))
        #expect(flags([:]) == (true, true))
    }

    @Test func synthesizedOnOffLightIsNotOfferedSoftNightLight() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "ke_ting", name: "客厅")],
            devices: [HADeviceEntry(id: "dev_entry", area_id: "ke_ting", name: "玄关筒灯", model: "ha.light.onoff")],
            entities: [HAEntityEntry(entity_id: "light.entry", device_id: "dev_entry", area_id: "ke_ting")],
            states: ["light.entry": HAEntityState(
                entityId: "light.entry",
                state: "on",
                attributes: ["supported_color_modes": .array([.string("onoff")]), "color_mode": .string("onoff")]
            )]
        )
        let device = try #require(home.devices.first)
        guard case .light(let spec) = device.kind else { Issue.record("expected a light"); return }
        #expect(!spec.brightnessWritable)
        #expect(!spec.colorWritable)
    }
}
