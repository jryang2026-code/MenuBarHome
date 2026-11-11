import Foundation
import Testing
@testable import MijiaCore

/// #308: a Home Assistant doorbell press opens that doorbell's camera, only when the user asked for it.
struct DoorbellRingTests {
    static let first = "2026-11-05T01:00:00.000+00:00"
    static let second = "2026-11-05T01:05:00.000+00:00"

    private static func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    private static func state(_ entityId: String, _ value: String, deviceClass: String? = "doorbell") -> JSONValue {
        var attributes: [String: JSONValue] = [:]
        if let deviceClass { attributes["device_class"] = .string(deviceClass) }
        return .object(["entity_id": .string(entityId), "state": .string(value), "attributes": .object(attributes)])
    }

    private static func changed(_ newState: JSONValue) -> [String: JSONValue] {
        ["type": .string("event"), "event": .object([
            "event_type": .string("state_changed"),
            "data": .object(["new_state": newState]),
        ])]
    }

    private static func loaded() throws -> HAHomeSnapshot {
        var snapshot = HAHomeSnapshot()
        _ = try snapshot.receive(reply(1, .array([])))
        _ = try snapshot.receive(reply(2, .array([.object(["id": .string("door-device"), "name": .string("门口")])])))
        _ = try snapshot.receive(reply(3, .array([
            .object(["entity_id": .string("event.door_ring"), "device_id": .string("door-device")]),
            .object(["entity_id": .string("event.button_press"), "device_id": .string("door-device")]),
        ])))
        _ = try snapshot.receive(reply(4, .array([
            state("event.door_ring", first),
            state("event.button_press", first, deviceClass: "button"),
        ])))
        return snapshot
    }

    @Test("The initial load and refreshes never ring; a new timestamp rings once; repeats and unavailable do not")
    func detectsPresses() throws {
        var snapshot = HAHomeSnapshot()
        _ = try snapshot.receive(Self.changed(Self.state("event.door_ring", Self.first)))
        #expect(snapshot.takeDoorbellRings().isEmpty, "events before the initial load are not presses")

        snapshot = try Self.loaded()
        #expect(snapshot.takeDoorbellRings().isEmpty)

        _ = try snapshot.receive(Self.changed(Self.state("event.door_ring", Self.second)))
        #expect(snapshot.takeDoorbellRings() == [DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second)])

        _ = try snapshot.receive(Self.changed(Self.state("event.door_ring", Self.second)))
        _ = try snapshot.receive(Self.changed(Self.state("event.door_ring", "unavailable")))
        _ = try snapshot.receive(Self.changed(Self.state("event.button_press", Self.second, deviceClass: "button")))
        #expect(snapshot.takeDoorbellRings().isEmpty)

        _ = try snapshot.receive(Self.changed(Self.state("event.door_ring", Self.second)))
        #expect(snapshot.takeDoorbellRings().isEmpty, "coming back from unavailable with a press already seen is not a press")

        _ = try snapshot.receive(Self.reply(1000, .array([Self.state("event.door_ring", "2026-11-05T02:00:00.000+00:00")])))
        #expect(snapshot.takeDoorbellRings().isEmpty, "a get_states refresh is not a press")
    }

    @MainActor
    private static func store(cameraOnline: Bool = true) -> (HomeStore, PopupLog) {
        let camera = SmartDevice(
            id: "door-device", name: "门口", roomId: "door", roomName: "门口", model: "chuangmi.camera.door", isOnline: cameraOnline,
            kind: .camera(CameraSpec(entityId: "switch.door_cam", isOn: true, streamEntityId: "camera.door"))
        )
        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome()), defaultsSuiteName: "test.doorbell.\(UUID().uuidString)")
        store.devices = [camera]
        let log = PopupLog()
        store.onDoorbellRing = { log.items.append($0) }
        return (store, log)
    }

    @Test("Off by default; on opens the camera once per press; off again stops it")
    @MainActor
    func popupFollowsSettings() {
        let (store, log) = Self.store()
        let ring = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second)
        #expect(!store.doorbellAutoPopup && !store.doorbellChime)

        store.handleDoorbellRing(ring)
        #expect(log.items.isEmpty)
        #expect(store.recentDoorbellRings == [ring])

        store.doorbellAutoPopup = true
        store.doorbellChime = true
        let next = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "2026-11-05T01:10:00.000+00:00")
        store.handleDoorbellRing(next)
        #expect(log.items == [DoorbellResponse(cameraDeviceId: "door-device", playsChime: true, dismissAfter: .seconds(60))])

        store.handleDoorbellRing(next)
        #expect(log.items.count == 1, "the same press never opens the window twice, even after it was closed")

        store.doorbellAutoPopup = false
        store.doorbellChime = false
        store.handleDoorbellRing(DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "2026-11-05T01:20:00.000+00:00"))
        #expect(log.items.count == 1)
    }

    @Test("The chime is its own switch: it plays without the camera, and on a locked screen")
    @MainActor
    func chimeIsIndependent() {
        let (store, log) = Self.store()
        store.doorbellChime = true
        store.setScreenLocked(true)
        store.handleDoorbellRing(DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second))
        #expect(log.items == [DoorbellResponse(cameraDeviceId: nil, playsChime: true, dismissAfter: .seconds(60))])
    }

    @Test("While the screen is locked a press is only recorded")
    @MainActor
    func lockedScreenRecordsOnly() {
        let (store, log) = Self.store()
        store.doorbellAutoPopup = true
        store.setScreenLocked(true)
        let ring = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second)
        store.handleDoorbellRing(ring)
        #expect(log.items.isEmpty)
        #expect(store.recentDoorbellRings == [ring])
    }

    @Test("An offline camera or a ring without a camera card opens nothing")
    @MainActor
    func needsOnlineCamera() {
        let (store, log) = Self.store(cameraOnline: false)
        store.doorbellAutoPopup = true
        store.handleDoorbellRing(DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second))
        store.handleDoorbellRing(DoorbellRing(deviceId: "other", entityId: "event.other_ring", firedAt: Self.second))
        #expect(log.items.isEmpty)
    }

    @Test("A device whose only active entity is a doorbell event is not listed as unsupported")
    func doorbellEventIsSupported() throws {
        let devices = try JSONDecoder().decode([HADeviceEntry].self, from: Data(#"[{"id":"door-device","name":"门口猫眼"}]"#.utf8))
        let entities = try JSONDecoder().decode([HAEntityEntry].self, from: Data(#"[{"entity_id":"event.door_ring","device_id":"door-device"}]"#.utf8))
        let states = ["event.door_ring": HAEntityState(entityId: "event.door_ring", state: Self.first, attributes: ["device_class": .string("doorbell")])]
        let home = SynthesizedHome()
        #expect(UnsupportedDeviceCollector.homeAssistant(devices: devices, entities: entities, states: states, synthesized: home).isEmpty)
        #expect(UnsupportedDeviceCollector.homeAssistant(devices: devices, entities: entities, synthesized: home).count == 1)
    }

    @Test("Disabled or hidden Home Assistant doorbell entities and disabled devices never ring")
    func disabledOrHiddenEntitiesDoNotRing() throws {
        var snapshot = HAHomeSnapshot()
        _ = try snapshot.receive(Self.reply(1, .array([])))
        _ = try snapshot.receive(Self.reply(2, .array([
            .object(["id": .string("door-active"), "name": .string("门口")]),
            .object(["id": .string("door-disabled"), "name": .string("后门"), "disabled_by": .string("user")]),
        ])))
        _ = try snapshot.receive(Self.reply(3, .array([
            .object(["entity_id": .string("event.disabled_ring"), "device_id": .string("door-active"), "disabled_by": .string("user")]),
            .object(["entity_id": .string("event.hidden_ring"), "device_id": .string("door-active"), "hidden_by": .string("integration")]),
            .object(["entity_id": .string("event.disabled_device_ring"), "device_id": .string("door-disabled")]),
            .object(["entity_id": .string("event.active_ring"), "device_id": .string("door-active")]),
        ])))
        _ = try snapshot.receive(Self.reply(4, .array([])))

        _ = try snapshot.receive(Self.changed(Self.state("event.disabled_ring", Self.second)))
        _ = try snapshot.receive(Self.changed(Self.state("event.hidden_ring", Self.second)))
        _ = try snapshot.receive(Self.changed(Self.state("event.disabled_device_ring", Self.second)))
        #expect(snapshot.takeDoorbellRings().isEmpty)

        _ = try snapshot.receive(Self.changed(Self.state("event.active_ring", Self.second)))
        #expect(snapshot.takeDoorbellRings() == [DoorbellRing(deviceId: "door-active", entityId: "event.active_ring", firedAt: Self.second)])
    }

    @Test("Switching backend clears recorded doorbell rings so another home starts clean")
    @MainActor
    func switchingBackendClearsDoorbellRings() {
        let (store, log) = Self.store()
        store.doorbellAutoPopup = true
        let ring = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: Self.second)
        store.handleDoorbellRing(ring)
        #expect(store.recentDoorbellRings == [ring])
        #expect(log.items.count == 1)

        store.switchBackend(.demo)
        #expect(store.recentDoorbellRings.isEmpty)
    }

    @Test("Read-only brightness, colour temperature, and target temperature ignore manual and keyboard writes")
    @MainActor
    func readOnlyCapabilitiesIgnoreManualAndKeyboardWrites() async {
        let provider = MockHomeProvider(snapshot: SynthesizedHome())
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.readonly.controls.\(UUID().uuidString)")
        store.controlDebounceInterval = .zero
        let fixedLight = SmartDevice(
            id: "light-fixed",
            name: "走廊灯",
            roomId: "hall",
            roomName: "走廊",
            model: "yeelink.light.switch",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.hall",
                isOn: true,
                brightnessPercent: 100,
                colorTempKelvin: 4000,
                brightnessWritable: false,
                colorWritable: false
            ))
        )
        let fixedClimate = SmartDevice(
            id: "climate-fixed",
            name: "传感器温控",
            roomId: "hall",
            roomName: "走廊",
            model: "xiaomi.aircondition.ro",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.hall",
                isOn: true,
                hvacMode: "cool",
                availableModes: ["off", "cool"],
                targetTemperature: 26,
                currentTemperature: 27,
                minTemp: 16,
                maxTemp: 30,
                step: 1,
                fanMode: nil,
                availableFanModes: [],
                swingMode: nil,
                availableSwingModes: [],
                powerWritable: true,
                temperatureWritable: false
            ))
        )
        store.devices = [fixedLight, fixedClimate]

        store.setLightBrightness("light-fixed", percent: 30)
        store.setLightColorTemp("light-fixed", kelvin: 3000)
        store.stepClimateTemperature("climate-fixed", delta: -2)

        store.focusedDeviceId = "light-fixed"
        store.expandedDeviceId = "light-fixed"
        store.adjustFocusedDevice(delta: -1)
        #expect(store.expandedDeviceId == nil, "Left arrow collapses an expanded non-dimmable light instead of sending brightness")

        #expect(await provider.executedCommands.isEmpty)
        if case .light(let lightSpec) = store.devices.first(where: { $0.id == "light-fixed" })?.kind {
            #expect(lightSpec.brightnessPercent == 100)
            #expect(lightSpec.colorTempKelvin == 4000)
        }
        if case .climate(let climateSpec) = store.devices.first(where: { $0.id == "climate-fixed" })?.kind {
            #expect(climateSpec.targetTemperature == 26)
        }
    }

    @Test("HAHomeSnapshot.parseLastChanged parses fractional and whole-second ISO8601 timestamps")
    func parsesFractionalAndWholeSecondTimestamps() {
        let fractional = HAHomeSnapshot.parseLastChanged(.string("2026-11-11T08:00:00.500+00:00"))
        let whole = HAHomeSnapshot.parseLastChanged(.string("2026-11-11T08:00:00Z"))
        #expect(fractional != nil)
        #expect(whole != nil)
        if let fractional, let whole {
            #expect(abs(fractional.timeIntervalSince(whole) - 0.5) < 0.001)
        }
        #expect(HAHomeSnapshot.parseLastChanged(.string("not-a-date")) == nil)
        #expect(HAHomeSnapshot.parseLastChanged(nil) == nil)
    }
}

@MainActor
final class PopupLog {
    var items: [DoorbellResponse] = []
}
