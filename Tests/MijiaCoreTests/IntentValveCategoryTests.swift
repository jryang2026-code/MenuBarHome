import Testing
@testable import MijiaCore

struct IntentValveCategoryTests {
    @Test(arguments: ["water_heater.test", "water_heater.valve_model"])
    func waterHeaterCategoryIsStableAcrossAvailability(model: String) {
        let online = SmartDevice(
            id: "heater", name: "燃气阀旁热水器", roomId: "kitchen", roomName: "厨房",
            model: model, isOnline: true,
            kind: .appliance(ApplianceSpec(
                entityId: "water_heater.test", targetTemperature: 45, temperatureWritable: true, heats: true
            ))
        )
        let offline = SmartDevice(
            id: online.id, name: online.name, roomId: "kitchen", roomName: "厨房",
            model: model, isOnline: false,
            kind: .appliance(ApplianceSpec(entityId: "water_heater.test", heats: true))
        )

        #expect(IntentDeviceCategory(online) == .appliance)
        #expect(IntentDeviceCategory(offline) == .appliance)
        #expect(ManualControlHazardProfile(online) == ManualControlHazardProfile(offline))
    }

    @Test(arguments: [true, false])
    func offlineWaterHeaterRetainsApplianceConfirmation(heats: Bool) {
        let device = SmartDevice(
            id: "heater", name: "燃气阀旁热水器", roomId: "kitchen", roomName: "厨房",
            model: "water_heater.test", isOnline: false,
            kind: .appliance(ApplianceSpec(
                entityId: "water_heater.test",
                startAction: heats ? nil : ApplianceAction(kind: .start, entityId: "button.start"),
                heats: heats
            ))
        )

        let profile = ManualControlHazardProfile(device)
        #expect(profile.category == .appliance)
        #expect(profile.applianceHeats == heats)
        #expect(profile.applianceHasStartAction == !heats)
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .power(true)), devices: [device]))
        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .power(false)), devices: [device]))
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .targetTemperature(45)), devices: [device]))
    }

    @Test(arguments: [
        DeviceKind.valve(ValveSpec(entityId: "valve.test", isOpen: false)),
        DeviceKind.appliance(ApplianceSpec(entityId: "valve.test"))
    ])
    func valveEntityRetainsOpeningConfirmation(kind: DeviceKind) {
        let device = SmartDevice(
            id: "valve", name: "总开关", roomId: "kitchen", roomName: "厨房",
            model: "test", isOnline: true, kind: kind
        )

        let profile = ManualControlHazardProfile(device)
        #expect(profile.category == .valve)
        #expect(!profile.applianceHeats)
        #expect(!profile.applianceHasStartAction)
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .power(true)), devices: [device]))
        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .power(false)), devices: [device]))
        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: device.id, operation: .targetTemperature(45)), devices: [device]))
    }
}
