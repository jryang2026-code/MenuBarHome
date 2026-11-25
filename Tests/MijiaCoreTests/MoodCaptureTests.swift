import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct MoodCaptureTests {
    private func device(_ id: String, _ kind: DeviceKind, room: String = "study") -> SmartDevice {
        SmartDevice(id: id, name: id, roomId: room, roomName: room, model: "", isOnline: true, kind: kind)
    }

    private func makeStore(_ snapshot: SynthesizedHome) async throws -> (HomeStore, MockHomeProvider) {
        let provider = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.mood.\(UUID())")
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    @Test func capturesWritableFieldsInSelectedRoomAndPersistsAcrossSources() async throws {
        var light = device("mi-light", .light(.init(
            entityId: "miot:123456789:2", isOn: true, brightnessPercent: 40, colorTempKelvin: 3200,
            colorWritable: false
        )))
        light.accountId = "42"
        let climate = device("climate.study", .climate(.init(
            entityId: "climate.study", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool"], targetTemperature: 25
        )))
        let otherRoom = device("light.kitchen", .light(.init(entityId: "light.kitchen", isOn: true)), room: "kitchen")
        var snapshot = SynthesizedHome(devices: [light, climate, otherRoom])
        snapshot.deviceBackends = [light.id: .xiaomiCloud, climate.id: .homeAssistant]
        let (store, _) = try await makeStore(snapshot)

        #expect(store.captureMood(name: " Reading ", roomId: "study"))
        let mood = try #require(store.moods.first)
        #expect(mood.name == "Reading")
        #expect(mood.targets.count == 2)
        let lamp = try #require(mood.targets.first { $0.deviceId == light.id })
        #expect(lamp.sourceScope == "mi:42")
        #expect(lamp.fields == [.intent(.power(true)), .intent(.brightness(40))])
        let ac = try #require(mood.targets.first { $0.deviceId == climate.id })
        #expect(ac.sourceScope.hasPrefix("ha:"))
        #expect(ac.fields == [.intent(.hvacMode("cool")), .intent(.targetTemperature(25))])
        for number in 0..<32 { #expect(store.captureMood(name: "Mood \(number)", roomId: "study")) }
        #expect(store.moods.count == 32)
        #expect(!store.moods.contains(mood))
        #expect(MoodPreferences.load(from: store.userDefaults) == store.moods)
    }

    @Test func hotkeyConfirmsOneBatchSkipsOfflineAndOffersUndo() async throws {
        let plug = device("switch.heater", .plug(.init(switchEntityId: "switch.heater", isOn: true)))
        let garage = device("cover.garage", .cover(.init(
            entityId: "cover.garage", subtype: .garageDoor,
            positionPercent: 80, reportedPositionPercent: 80, positionWritable: true
        )))
        let light = device("light.study", .light(.init(entityId: "light.study", isOn: true)))
        let (store, provider) = try await makeStore(.init(devices: [plug, garage, light]))
        #expect(store.captureMood(name: "Evening", roomId: "study"))
        let mood = try #require(store.moods.first)

        let livePlug = device(plug.id, .plug(.init(switchEntityId: plug.id, isOn: false)))
        let liveGarage = device(garage.id, .cover(.init(
            entityId: garage.id, subtype: .garageDoor,
            positionPercent: 20, reportedPositionPercent: 20, positionWritable: true
        )))
        var offlineLight = light
        offlineLight.isOnline = false
        store.devices = [livePlug, liveGarage, offlineLight]
        store.lastCoverPositions[garage.id] = 20
        var prompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            prompts.append(prompt)
            return true
        }
        let binding = HotkeyBinding(
            target: .mood(moodId: mood.id), targetLabel: mood.name, shortcut: .defaultShortcut
        )
        let encoded = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: encoded) == binding)
        let outcome = await store.executeHotkeyBinding(binding)
        guard case .failed(let message) = outcome else {
            Issue.record("Expected the offline device to be reported")
            return
        }
        #expect(message.contains(light.name))
        #expect(prompts.count == 1)
        #expect(prompts.first?.message.contains(plug.name) == true)
        #expect(prompts.first?.message.contains(garage.name) == true)
        let expected: [DeviceCommand] = [
            .setSwitch(entityId: plug.id, isOn: true),
            .setNumberValue(entityId: garage.id, value: 80)
        ]
        #expect(await provider.executedCommands == expected)
        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(await provider.executedCommands == expected + [
            .setSwitch(entityId: plug.id, isOn: false),
            .setNumberValue(entityId: garage.id, value: 20)
        ])
    }

    @Test func screenLockAndDeclinedConfirmationSendNothing() async throws {
        let plug = device("switch.heater", .plug(.init(switchEntityId: "switch.heater", isOn: true)))
        let (store, provider) = try await makeStore(.init(devices: [plug]))
        #expect(store.captureMood(name: "Evening", roomId: "study"))
        let mood = try #require(store.moods.first)
        var promptCount = 0
        store.manualControlConfirmationHandler = { _ in
            promptCount += 1
            return false
        }
        store.blockControlWhileLocked = true
        store.setScreenLocked(true)
        #expect(await store.applyMood(id: mood.id) == .blocked(message: store.screenLockBlockedMessage))
        #expect(promptCount == 0)
        store.setScreenLocked(false)
        #expect(await store.applyMood(id: mood.id) == .cancelled)
        #expect(promptCount == 1)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test func disablingATargetCategoryPreventsReplay() async throws {
        let plug = device("switch.heater", .plug(.init(switchEntityId: "switch.heater", isOn: true)))
        let (store, provider) = try await makeStore(.init(devices: [plug]))
        #expect(store.captureMood(name: "Evening", roomId: "study"))
        let mood = try #require(store.moods.first)
        store.capabilitySelection.enabledCategories.remove(.plug)
        var promptCount = 0
        store.manualControlConfirmationHandler = { _ in
            promptCount += 1
            return true
        }
        guard case .failed = await store.applyMood(id: mood.id) else {
            Issue.record("Expected the disabled device to be reported")
            return
        }
        #expect(promptCount == 0)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test func sharedGoldenFixtureUsesV1Storage() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mood_snapshot_golden.json")
        let data = try Data(contentsOf: fixture)
        let file = try MoodPreferences.decode(data)
        #expect(file.version == 1)
        let suite = "test.mood.fixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try MoodPreferences.save(file.moods, to: defaults)
        #expect(MoodPreferences.load(from: defaults) == file.moods)
        let actual = try #require(defaults.data(forKey: MoodPreferences.key))
        #expect(try JSONSerialization.jsonObject(with: actual) as? NSDictionary ==
            JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
