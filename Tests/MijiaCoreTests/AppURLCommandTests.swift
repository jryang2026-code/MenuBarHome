import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// #57: URL Scheme parsing and the confirmation gate are pure logic, so a web page cannot smuggle
/// an unparsed parameter or skip the sheet by default.
struct AppURLCommandTests {
    @Test("Toggle link parses the device id")
    func parsesToggle() throws {
        let url = try #require(URL(string: "menumijia://toggle?device=dev_study_ceiling"))
        #expect(AppURLParser.parse(url) == .toggle(deviceId: "dev_study_ceiling"))
    }

    @Test("Scene link percent-decodes the scene name")
    func parsesScene() throws {
        let url = try #require(URL(string: "menumijia://scene?name=%E5%9B%9E%E5%AE%B6%E6%A8%A1%E5%BC%8F"))
        #expect(AppURLParser.parse(url) == .scene(name: "回家模式"))
    }

    @Test("Ask link keeps the sentence and trims surrounding whitespace")
    func parsesAsk() throws {
        let url = try #require(URL(string: "menumijia://ask?text=%20%E6%89%93%E5%BC%80%E4%B9%A6%E6%88%BF%E7%81%AF%20"))
        #expect(AppURLParser.parse(url) == .ask(text: "打开书房灯"))
    }

    @Test("Path-style links are accepted too")
    func parsesPathStyle() throws {
        let url = try #require(URL(string: "menumijia:/toggle?device=light_bed"))
        #expect(AppURLParser.parse(url) == .toggle(deviceId: "light_bed"))
    }

    @Test("Unknown, incomplete, empty, and oversized links are rejected")
    func rejectsMalformedLinks() throws {
        let bad = [
            "https://toggle?device=light_bed",
            "menumijia://toggle",
            "menumijia://toggle?device=",
            "menumijia://toggle?device=%20",
            "menumijia://scene?name=",
            "menumijia://ask?text=",
            "menumijia://unknown?device=light_bed",
            "menumijia://ask?text=" + String(repeating: "a", count: AppURLParser.maximumAskLength + 1)
        ]
        for raw in bad {
            let url = try #require(URL(string: raw), "invalid test URL \(raw)")
            #expect(AppURLParser.parse(url) == nil, "\(raw) should not parse")
        }
    }

    @Test("URL control asks for confirmation by default and only skips it after opt-in")
    func confirmationGate() throws {
        let defaults = InMemoryUserDefaults()

        #expect(URLDirectControl.requiresConfirmation(in: defaults))
        defaults.set(true, forKey: URLDirectControl.allowDirectControlKey)
        #expect(!URLDirectControl.requiresConfirmation(in: defaults))
        #expect(URLDirectControl.requiresConfirmation(allowDirectControl: false))
        #expect(!URLDirectControl.requiresConfirmation(allowDirectControl: true))
    }

    @Test("Envelope parser extracts bridge token and requestId while rejecting oversized metadata")
    func parsesEnvelopeAndBridgeToken() throws {
        let validURL = try #require(
            URL(string: "menumijia://toggle?device=dev_study_ceiling&token=0123456789abcdef0123456789abcdef&id=req-42")
        )
        let envelope = try #require(AppURLParser.parseEnvelope(validURL))
        #expect(envelope.command == .toggle(deviceId: "dev_study_ceiling"))
        #expect(envelope.token == "0123456789abcdef0123456789abcdef")
        #expect(envelope.requestId == "req-42")

        let expectedToken = "0123456789abcdef0123456789abcdef"
        #expect(URLDirectControl.isValidBridgeToken(envelope.token, expectedToken: expectedToken))
        #expect(!URLDirectControl.isValidBridgeToken("wrong-token-12345678", expectedToken: expectedToken))
        #expect(!URLDirectControl.isValidBridgeToken("short", expectedToken: "short"))
        #expect(
            !URLDirectControl.requiresConfirmation(
                allowDirectControl: false,
                providedToken: envelope.token,
                expectedToken: expectedToken
            )
        )
        #expect(
            URLDirectControl.requiresConfirmation(
                allowDirectControl: false,
                providedToken: "invalid-token-0000000000000000",
                expectedToken: expectedToken
            )
        )

        let oversizedToken = String(repeating: "x", count: AppURLParser.maximumTokenLength + 1)
        let badTokenURL = try #require(URL(string: "menumijia://toggle?device=dev_1&token=\(oversizedToken)"))
        #expect(AppURLParser.parseEnvelope(badTokenURL) == nil)
    }

    @Test("BuiltInURLScene resolves quick actions, allOff, and undo identifiers")
    func resolvesBuiltInScenes() {
        #expect(BuiltInURLScene.resolve("lightsOff") == .lightsOff)
        #expect(BuiltInURLScene.resolve("quick:lightsOff") == .lightsOff)
        #expect(BuiltInURLScene.resolve("全屋关灯") == .lightsOff)
        #expect(BuiltInURLScene.resolve("softNightLight") == .softNightLight)
        #expect(BuiltInURLScene.resolve("柔和夜灯") == .softNightLight)
        #expect(BuiltInURLScene.resolve("climateSleepOff") == .climateSleepOff)
        #expect(BuiltInURLScene.resolve("关温控风扇") == .climateSleepOff)
        #expect(BuiltInURLScene.resolve("allOff") == .allOff)
        #expect(BuiltInURLScene.resolve("一键全关") == .allOff)
        #expect(BuiltInURLScene.resolve("undo") == .undo)
        #expect(BuiltInURLScene.resolve("撤销上一步") == .undo)
        #expect(BuiltInURLScene.resolve("unknown_custom_scene") == nil)
    }

    @Test("Raycast integration is off by default; on, exports coalesce, skip unchanged snapshots and write feedback at once; off revokes the token")
    @MainActor
    func raycastSnapshotExportIsCoalescedAndSkipsUnchangedWrites() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raycast-coalesce-\(UUID().uuidString)", isDirectory: true)
        let snapshotFile = tempDir.appendingPathComponent("raycast-snapshot.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let lamp = SmartDevice(
            id: "dev_lamp", name: "台灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: false))
        )
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp])),
            defaults: InMemoryUserDefaults()
        )
        try await store.waitForTestSnapshot()
        store.raycastSnapshotTestURL = snapshotFile
        let gate = ScheduledCommandTestSupport.SleepGate()
        store.raycastExportSleep = { _ in
            // Schedules cancelled by a later one are already cancelled before they run.
            // Only the surviving quiet period parks, so `waiting == 1` is that period.
            if Task.isCancelled { return }
            await gate.sleep()
        }

        // Off by default: nothing is written and there is no token.
        #expect(!store.raycastIntegrationEnabled)
        #expect(store.raycastBridgeToken == nil)
        store.scheduleRaycastSnapshotExport()
        store.exportRaycastSnapshotIfNeeded()
        store.recordRaycastCommandFeedback(requestId: "ignored", command: "toggle", message: "x")
        await store.raycastExportTask?.value
        #expect(!FileManager.default.fileExists(atPath: snapshotFile.path))

        store.setRaycastIntegration(enabled: true)
        let firstToken = try #require(store.raycastBridgeToken)
        try FileManager.default.removeItem(at: snapshotFile)
        store.lastExportedRaycastSnapshot = nil

        // A burst of changes schedules one export that lands after the quiet period.
        for _ in 0..<5 { store.scheduleRaycastSnapshotExport() }
        await waitUntil { gate.waiting == 1 }
        #expect(!FileManager.default.fileExists(atPath: snapshotFile.path))
        let exportTask = store.raycastExportTask
        gate.release()
        await exportTask?.value
        let first = try Data(contentsOf: snapshotFile)

        // Nothing changed except the clock: the file is left alone.
        store.exportRaycastSnapshotIfNeeded(now: Date().addingTimeInterval(60))
        #expect(try Data(contentsOf: snapshotFile) == first)

        // Command feedback is written immediately because Raycast is waiting for it.
        store.recordRaycastCommandFeedback(requestId: "req-1", command: "toggle", message: "已打开 台灯")
        let decoded = try JSONDecoder().decode(RaycastSnapshot.self, from: Data(contentsOf: snapshotFile))
        #expect(decoded.lastCommandFeedback?.requestId == "req-1")
        #expect(decoded.bridgeToken == firstToken)

        // Turning it off deletes the file and revokes the token; turning it back on issues a new one.
        store.setRaycastIntegration(enabled: false)
        #expect(!FileManager.default.fileExists(atPath: snapshotFile.path))
        #expect(store.raycastBridgeToken == nil)
        #expect(!URLDirectControl.isValidBridgeToken(firstToken, expectedToken: store.raycastBridgeToken))
        store.setRaycastIntegration(enabled: true)
        #expect(try #require(store.raycastBridgeToken) != firstToken)
    }

    @Test("RaycastSnapshot exports 0600 JSON with capabilities, pinyin, multi-sensor readings, and command feedback")
    @MainActor
    func exportsRaycastSnapshotAndExecutesBuiltInScenes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raycast-snapshot-test-\(UUID().uuidString)", isDirectory: true)
        let snapshotFile = tempDir.appendingPathComponent("raycast-snapshot.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let rooms = [
            RoomArea(id: "living", name: "客厅", sortOrder: 0),
            RoomArea(id: "study", name: "书房", sortOrder: 1),
        ]
        let devices = [
            SmartDevice(
                id: "dev_living_light",
                name: "客厅吸顶灯",
                roomId: "living",
                roomName: "客厅",
                model: "yeelink.light.ceiling",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.living",
                    isOn: true,
                    brightnessPercent: 80,
                    colorTempKelvin: 4000,
                    minKelvin: 2700,
                    maxKelvin: 6500
                ))
            ),
            SmartDevice(
                id: "dev_study_ac",
                name: "书房空调",
                roomId: "study",
                roomName: "书房",
                model: "xiaomi.aircondition.mc5",
                isOnline: true,
                kind: .climate(ClimateSpec(
                    entityId: "climate.study",
                    isOn: true,
                    hvacMode: "cool",
                    availableModes: ["off", "cool", "heat"],
                    targetTemperature: 25,
                    currentTemperature: 27
                ))
            ),
        ]
        let readings = [
            EnvironmentReading(
                id: "sensor_living_1",
                label: "沙发温湿度计",
                roomName: "客厅",
                temperature: 24.5,
                humidity: 52,
                battery: 90
            ),
            EnvironmentReading(
                id: "sensor_living_2",
                label: "阳台侧温湿度计",
                roomName: "客厅",
                temperature: 26.1,
                humidity: 48,
                battery: 82
            ),
        ]
        let scenes = [
            HomeScene(id: "scene_movie", name: "观影模式", entityId: "scene.movie", iconName: "film.fill")
        ]

        let provider = MockHomeProvider(
            snapshot: SynthesizedHome(
                rooms: rooms,
                devices: devices,
                environmentReadings: readings,
                scenes: scenes
            )
        )
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        defer { store.stop() }
        store.raycastSnapshotTestURL = snapshotFile
        try await store.waitForTestSnapshot()
        store.setRaycastIntegration(enabled: true)
        store.exportRaycastSnapshotIfNeeded()

        // Selecting a single room in the panel must NOT hide other rooms in the Raycast snapshot.
        store.selectRoom("study")
        store.exportRaycastSnapshotIfNeeded()

        let data = try Data(contentsOf: snapshotFile)
        let decoded = try JSONDecoder().decode(RaycastSnapshot.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.bridgeToken.count >= 32)
        #expect(decoded.devices.count == 2)

        let lightItem = try #require(decoded.devices.first(where: { $0.id == "dev_living_light" }))
        let acItem = try #require(decoded.devices.first(where: { $0.id == "dev_study_ac" }))
        #expect(lightItem.capabilities.supportsMoonlight == true)
        #expect(acItem.capabilities.supportsMoonlight == false)
        #expect(acItem.capabilities.temperatureWritable == true)
        #expect(lightItem.pinyinInitials == "ktxdd")

        // Both sensors in the same room keep their distinct IDs.
        #expect(decoded.environmentReadings.map(\.id) == ["sensor_living_1", "sensor_living_2"])
        #expect(decoded.quickActions.map(\.id) == ["lightsOff", "softNightLight", "climateSleepOff", "allOff", "undo"])

        // File permissions must be 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotFile.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((perms & 0o777) == 0o600)

        // Built-in quick action + undo execution and command feedback persistence.
        let lightsOffOutcome = await store.executeBuiltInURLScene(.lightsOff)
        #expect(!lightsOffOutcome.isError)
        #expect(store.devices.first(where: { $0.id == "dev_living_light" })?.isActiveOn == false)

        let undoOutcome = await store.executeBuiltInURLScene(.undo)
        #expect(!undoOutcome.isError)
        #expect(store.devices.first(where: { $0.id == "dev_living_light" })?.isActiveOn == true)

        store.recordRaycastCommandFeedback(
            requestId: "req-99",
            command: "ask:打开客厅灯",
            message: "已打开 客厅吸顶灯",
            isError: false
        )
        #expect(store.lastRaycastCommandFeedback?.requestId == "req-99")
        let updatedData = try Data(contentsOf: snapshotFile)
        let updatedSnapshot = try JSONDecoder().decode(RaycastSnapshot.self, from: updatedData)
        #expect(updatedSnapshot.lastCommandFeedback?.requestId == "req-99")
        #expect(updatedSnapshot.lastCommandFeedback?.message == "已打开 客厅吸顶灯")
        #expect(updatedSnapshot.lastCommandFeedback?.isError == false)
    }

    // MARK: - Parameterized Companion Controls (#20)

    @Test("Parameterized companion links parse into exact-value commands")
    func parsesParameterizedControls() throws {
        let power = try #require(URL(string: "menumijia://power?device=dev_light&on=false"))
        #expect(AppURLParser.parse(power) == .power(deviceId: "dev_light", isOn: false))
        let powerState = try #require(URL(string: "menumijia://power?device=dev_light&state=ON"))
        #expect(AppURLParser.parse(powerState) == .power(deviceId: "dev_light", isOn: true))

        let brightness = try #require(URL(string: "menumijia://brightness?device=dev_light&percent=40"))
        #expect(AppURLParser.parse(brightness) == .brightness(deviceId: "dev_light", percent: 40))

        for route in ["color-temp", "color_temp", "colortemp"] {
            let url = try #require(URL(string: "menumijia://\(route)?device=dev_light&kelvin=2700"))
            #expect(AppURLParser.parse(url) == .colorTemp(deviceId: "dev_light", kelvin: 2700))
        }

        let temperature = try #require(URL(string: "menumijia://temperature?device=dev_ac&celsius=25.5"))
        #expect(AppURLParser.parse(temperature) == .temperature(deviceId: "dev_ac", celsius: 25.5))
        let hotWater = try #require(URL(string: "menumijia://temperature?device=dev_water_heater&celsius=65"))
        #expect(AppURLParser.parse(hotWater) == .temperature(deviceId: "dev_water_heater", celsius: 65))

        let fanPercent = try #require(URL(string: "menumijia://fan?device=dev_fan&percent=60"))
        #expect(AppURLParser.parse(fanPercent) == .fan(deviceId: "dev_fan", percent: 60, preset: nil))
        let fanPreset = try #require(URL(string: "menumijia://fan?device=dev_fan&preset=Auto"))
        #expect(AppURLParser.parse(fanPreset) == .fan(deviceId: "dev_fan", percent: nil, preset: "Auto"))

        let focus = try #require(URL(string: "menumijia://focus?device=dev_fan"))
        #expect(AppURLParser.parse(focus) == .focus(deviceId: "dev_fan"))
        // A Spotlight room hit navigates to that room's filter instead of a device drawer (#575).
        let focusRoom = try #require(URL(string: "menumijia://focus?room=living"))
        #expect(AppURLParser.parse(focusRoom) == .focusRoom(roomId: "living"))
        #expect(AppURLParser.parse(focusRoom)?.controlsDevice == false)

        // A slider that overshoots must not be clamped at the edge of the process: reject the link.
        let rejected = [
            "menumijia://power?device=dev_light",
            "menumijia://power?device=dev_light&on=maybe",
            "menumijia://brightness?device=dev_light",
            "menumijia://brightness?device=dev_light&percent=101",
            "menumijia://brightness?device=dev_light&percent=-1",
            "menumijia://color-temp?device=dev_light&kelvin=999",
            "menumijia://temperature?device=dev_ac&celsius=nan",
            "menumijia://temperature?device=dev_ac&celsius=101",
            "menumijia://temperature?device=dev_ac&celsius=-31",
            "menumijia://fan?device=dev_fan",
            "menumijia://fan?device=dev_fan&percent=250",
            "menumijia://fan?device=dev_fan&percent=60&preset=Auto",
            "menumijia://focus?device=",
            "menumijia://focus",
            "menumijia://focus?room=",
            "menumijia://focus?device=dev_fan&room=living",
        ]
        for raw in rejected {
            let url = try #require(URL(string: raw))
            #expect(AppURLParser.parse(url) == nil, "\(raw) should not parse")
        }
    }

    @Test("Parameterized links write exact values, clamp to the device's range, and report the result")
    @MainActor
    func parameterizedControlsWriteExactValues() async throws {
        let rooms = [
            RoomArea(id: "living", name: "客厅", sortOrder: 0),
            RoomArea(id: "study", name: "书房", sortOrder: 1),
            RoomArea(id: "bedroom", name: "卧室", sortOrder: 2),
        ]
        let light = SmartDevice(
            id: "dev_living_light",
            name: "客厅吸顶灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.ceiling",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living",
                isOn: true,
                brightnessPercent: 80,
                colorTempKelvin: 4000,
                minKelvin: 2700,
                maxKelvin: 6500
            ))
        )
        let ac = SmartDevice(
            id: "dev_study_ac",
            name: "书房空调",
            roomId: "study",
            roomName: "书房",
            model: "xiaomi.aircondition.mc5",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.study",
                isOn: true,
                hvacMode: "cool",
                availableModes: ["off", "cool", "heat"],
                targetTemperature: 25,
                minTemp: 16,
                maxTemp: 30,
                step: 0.5
            ))
        )
        let fan = SmartDevice(
            id: "dev_bedroom_fan",
            name: "卧室风扇",
            roomId: "bedroom",
            roomName: "卧室",
            model: "zhimi.fan.za4",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "fan.bedroom",
                isOn: false,
                percentage: 40,
                presetMode: "Auto",
                availablePresetModes: ["Auto", "Sleep", "Favorite"]
            ))
        )
        let offlineLamp = SmartDevice(
            id: "dev_offline_lamp",
            name: "阳台灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.color1",
            isOnline: false,
            kind: .light(LightSpec(entityId: "light.balcony", isOn: false))
        )

        let provider = MockHomeProvider(snapshot: SynthesizedHome(rooms: rooms, devices: [light, ac, fan, offlineLamp]))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        func device(_ id: String) -> SmartDevice? {
            store.devices.first { $0.id == id }
        }

        // Brightness writes the exact percent; zero turns the light off instead of asking for 0%.
        let dimmed = await store.executeRaycastBrightness(deviceId: "dev_living_light", percent: 40)
        #expect(!dimmed.isError)
        guard case .light(let dimmedSpec) = try #require(device("dev_living_light")?.kind) else {
            Issue.record("expected a light")
            return
        }
        #expect(dimmedSpec.brightnessPercent == 40)
        #expect(dimmedSpec.isOn)
        var commands = await provider.executedCommands
        #expect(commands.last == .setLightBrightness(entityId: "light.living", percent: 40))

        let off = await store.executeRaycastBrightness(deviceId: "dev_living_light", percent: 0)
        #expect(!off.isError)
        guard case .light(let offSpec) = try #require(device("dev_living_light")?.kind) else {
            Issue.record("expected a light")
            return
        }
        #expect(offSpec.isOn == false)
        commands = await provider.executedCommands
        #expect(commands.last == .setLightPower(entityId: "light.living", isOn: false))

        // Colour temperature is clamped to the light's own 2700…6500 K window.
        let warm = await store.executeRaycastColorTemp(deviceId: "dev_living_light", kelvin: 9000)
        #expect(!warm.isError)
        guard case .light(let warmSpec) = try #require(device("dev_living_light")?.kind) else {
            Issue.record("expected a light")
            return
        }
        #expect(warmSpec.colorTempKelvin == 6500)
        #expect(warmSpec.isOn)
        commands = await provider.executedCommands
        #expect(commands.last == .setLightColorTemp(entityId: "light.living", kelvin: 6500))

        // 25.3 °C snaps to the thermostat's 0.5 °C step instead of reaching the device as 25.3.
        let warmer = await store.executeRaycastTemperature(deviceId: "dev_study_ac", celsius: 25.3)
        #expect(!warmer.isError)
        guard case .climate(let acSpec) = try #require(device("dev_study_ac")?.kind) else {
            Issue.record("expected a climate device")
            return
        }
        #expect(acSpec.targetTemperature == 25.5)
        commands = await provider.executedCommands
        #expect(commands.last == .setClimateTemperature(entityId: "climate.study", temperature: 25.5))

        // Setting the temperature it already holds is a no-op, not another cloud round trip.
        let unchanged = await store.executeRaycastTemperature(deviceId: "dev_study_ac", celsius: 25.5)
        #expect(!unchanged.isError)
        #expect(unchanged.message.contains("25.5"))
        commands = await provider.executedCommands
        #expect(commands.count == 4)

        // Water-heater temperatures (up to 100 °C) still clamp an AC to its own 30 °C ceiling.
        let clampedAC = await store.executeRaycastTemperature(deviceId: "dev_study_ac", celsius: 75)
        #expect(!clampedAC.isError)
        guard case .climate(let maxACSpec) = try #require(device("dev_study_ac")?.kind) else {
            Issue.record("expected a climate device")
            return
        }
        #expect(maxACSpec.targetTemperature == 30.0)
        commands = await provider.executedCommands
        #expect(commands.last == .setClimateTemperature(entityId: "climate.study", temperature: 30.0))

        // Fan percentage powers on and switches to Favorite, the mode purifiers honour a speed in.
        let faster = await store.executeRaycastFan(deviceId: "dev_bedroom_fan", percent: 70, preset: nil)
        #expect(!faster.isError)
        guard case .fan(let fanSpec) = try #require(device("dev_bedroom_fan")?.kind) else {
            Issue.record("expected a fan")
            return
        }
        #expect(fanSpec.percentage == 70)
        #expect(fanSpec.isOn)
        #expect(fanSpec.presetMode == "Favorite")
        commands = await provider.executedCommands
        #expect(commands.last == .setFanPercentage(entityId: "fan.bedroom", percent: 70))

        // A preset is matched against the modes the device publishes.
        let quiet = await store.executeRaycastFan(deviceId: "dev_bedroom_fan", percent: nil, preset: "sleep")
        #expect(!quiet.isError)
        guard case .fan(let quietSpec) = try #require(device("dev_bedroom_fan")?.kind) else {
            Issue.record("expected a fan")
            return
        }
        #expect(quietSpec.presetMode == "Sleep")
        commands = await provider.executedCommands
        #expect(commands.last == .setFanPresetMode(entityId: "fan.bedroom", presetMode: "Sleep"))

        // An unpublished mode is refused with the available list instead of being sent anyway.
        let unknown = await store.executeRaycastFan(deviceId: "dev_bedroom_fan", percent: nil, preset: "Turbo")
        #expect(unknown.isError)
        #expect(unknown.message.contains("Auto"))
        commands = await provider.executedCommands
        #expect(commands.count == 7)

        // Explicit power: on/off set the state, and asking for the state it already holds is a no-op.
        let turnedOn = await store.executeRaycastPower(deviceId: "dev_bedroom_fan", isOn: true)
        #expect(!turnedOn.isError)
        let alreadyOn = await store.executeRaycastPower(deviceId: "dev_bedroom_fan", isOn: true)
        #expect(!alreadyOn.isError)
        #expect(alreadyOn.message.contains("已经"))
        commands = await provider.executedCommands
        #expect(commands.count == 7, "an already-satisfied power link sends nothing")

        let turnedOff = await store.executeRaycastPower(deviceId: "dev_bedroom_fan", isOn: false)
        #expect(!turnedOff.isError)
        #expect(device("dev_bedroom_fan")?.isActiveOn == false)

        // An offline device is refused before any command is queued.
        let offline = await store.executeRaycastBrightness(deviceId: "dev_offline_lamp", percent: 50)
        #expect(offline.isError)

        // Focus shows the device's room and drawer without changing any device state.
        let focused = store.focusRaycastDevice(deviceId: "dev_study_ac")
        #expect(!focused.isError)
        #expect(store.selectedRoomId == "study")
        #expect(store.expandedDeviceId == "dev_study_ac")

        store.hideDevice("dev_study_ac")
        let hidden = store.focusRaycastDevice(deviceId: "dev_study_ac")
        #expect(hidden.isError)
    }

    @Test("A power link opens or closes a travelling cover instead of pausing it")
    @MainActor
    func powerLinkDrivesCoverInTheRequestedDirection() async throws {
        let openingCurtain = SmartDevice(
            id: "dev_opening_curtain",
            name: "客厅窗帘",
            roomId: "living",
            roomName: "客厅",
            model: "lumi.curtain.hagl05",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.opening",
                subtype: .curtain,
                positionPercent: 40,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause",
                motion: .opening
            ))
        )
        let closingWindow = SmartDevice(
            id: "dev_closing_window",
            name: "卧室窗户",
            roomId: "bedroom",
            roomName: "卧室",
            model: "linp.wopener.wd1lb",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.window",
                subtype: .windowOpener,
                positionPercent: 60,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause",
                motion: .closing
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [
                RoomArea(id: "living", name: "客厅", sortOrder: 0),
                RoomArea(id: "bedroom", name: "卧室", sortOrder: 1),
            ],
            devices: [openingCurtain, closingWindow]
        ))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        // Off while the curtain is opening closes it: the three-way tile toggle would pause it.
        let closed = await store.executeRaycastPower(deviceId: "dev_opening_curtain", isOn: false)
        #expect(!closed.isError)
        var commands = await provider.executedCommands
        #expect(commands.last == .setSelectOption(entityId: "cover.opening", option: "Close"))

        // On while the window is closing opens it, but only after the high-risk gate approves.
        store.manualControlConfirmationHandler = { _ in false }
        let refused = await store.executeRaycastPower(deviceId: "dev_closing_window", isOn: true)
        #expect(refused.isError)
        #expect(await provider.executedCommands.count == commands.count)

        store.manualControlConfirmationHandler = { _ in true }
        let opened = await store.executeRaycastPower(deviceId: "dev_closing_window", isOn: true)
        #expect(!opened.isError)
        commands = await provider.executedCommands
        #expect(commands.last == .setSelectOption(entityId: "cover.window", option: "Open"))
    }

    @Test("A power link keeps the high-risk confirmation gate and refuses an unconfirmed heater")
    @MainActor
    func powerLinkKeepsHazardConfirmation() async throws {
        let heater = SmartDevice(
            id: "dev_water_heater",
            name: "热水器",
            roomId: "bathroom",
            roomName: "卫生间",
            model: "xiaomi.waterheater.ymj",
            isOnline: true,
            kind: .appliance(ApplianceSpec(
                entityId: "switch.water_heater",
                isOn: false,
                powerPresent: true,
                powerWritable: true,
                heats: true
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "bathroom", name: "卫生间", sortOrder: 0)],
            devices: [heater]
        ))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        store.manualControlConfirmationHandler = { _ in false }
        let refused = await store.executeRaycastPower(deviceId: "dev_water_heater", isOn: true)
        #expect(refused.isError)
        #expect(store.devices.first { $0.id == "dev_water_heater" }?.isActiveOn == false)
        #expect(await provider.executedCommands.isEmpty)

        store.manualControlConfirmationHandler = { _ in true }
        let approved = await store.executeRaycastPower(deviceId: "dev_water_heater", isOn: true)
        #expect(!approved.isError)
        #expect(store.devices.first { $0.id == "dev_water_heater" }?.isActiveOn == true)
    }

    @Test("Shared app_url_command_golden.json corpus matches macOS parser, scene resolver, bridge token gate, and temperature snap (#46)")
    func matchesAppURLCommandGoldenCorpus() throws {
        struct ParseExpected: Decodable {
            let kind: String; let deviceId: String?; let name: String?; let text: String?; let isOn: Bool?; let isMuted: Bool?
            let percent: Int?; let kelvin: Int?; let celsius: Double?; let preset: String?
            let controlsDevice: Bool; let token: String?; let requestId: String?
        }
        struct ParseCase: Decodable { let url: String; let expected: ParseExpected? }
        struct BuiltInSceneCase: Decodable { let raw: String; let expected: String? }
        struct BridgeTokenCase: Decodable {
            let allowDirectControl: Bool; let providedToken: String?; let expectedToken: String?
            let validToken: Bool; let requiresConfirmation: Bool
        }
        struct SnapTempCase: Decodable { let celsius: Double; let min: Double; let max: Double; let step: Double; let expected: Double }
        struct GoldenFile: Decodable {
            let parseCases: [ParseCase]; let builtInSceneCases: [BuiltInSceneCase]
            let bridgeTokenCases: [BridgeTokenCase]; let snapTemperatureCases: [SnapTempCase]
        }

        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/app_url_command_golden.json")
        let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))

        for item in golden.parseCases {
            let parsed = URL(string: item.url).flatMap(AppURLParser.parseEnvelope)
            guard let exp = item.expected else { #expect(parsed == nil, "\(item.url)"); continue }
            let env = try #require(parsed, "expected \(item.url) to parse")
            #expect(env.command.controlsDevice == exp.controlsDevice && env.token == exp.token && env.requestId == exp.requestId, "\(item.url)")
            switch exp.kind {
            case "toggle": #expect(env.command == .toggle(deviceId: exp.deviceId ?? ""))
            case "scene": #expect(env.command == .scene(name: exp.name ?? ""))
            case "ask": #expect(env.command == .ask(text: exp.text ?? ""))
            case "power": #expect(env.command == .power(deviceId: exp.deviceId ?? "", isOn: exp.isOn ?? false))
            case "brightness": #expect(env.command == .brightness(deviceId: exp.deviceId ?? "", percent: exp.percent ?? 0))
            case "colorTemp": #expect(env.command == .colorTemp(deviceId: exp.deviceId ?? "", kelvin: exp.kelvin ?? 0))
            case "temperature": #expect(env.command == .temperature(deviceId: exp.deviceId ?? "", celsius: exp.celsius ?? 0))
            case "fan": #expect(env.command == .fan(deviceId: exp.deviceId ?? "", percent: exp.percent, preset: exp.preset))
            case "coverPosition": #expect(env.command == .coverPosition(deviceId: exp.deviceId ?? "", percent: exp.percent ?? 0))
            case "volume": #expect(env.command == .volume(deviceId: exp.deviceId ?? "", percent: exp.percent ?? 0))
            case "mute": #expect(env.command == .mute(deviceId: exp.deviceId ?? "", isMuted: exp.isMuted ?? false))
            case "mediaPlayPause": #expect(env.command == .mediaPlayPause(deviceId: exp.deviceId ?? ""))
            case "focus": #expect(env.command == .focus(deviceId: exp.deviceId ?? ""))
            default: Issue.record("Unknown kind \(exp.kind)")
            }
        }
        for item in golden.builtInSceneCases { #expect(BuiltInURLScene.resolve(item.raw)?.rawValue == item.expected) }
        for item in golden.bridgeTokenCases {
            #expect(URLDirectControl.isValidBridgeToken(item.providedToken, expectedToken: item.expectedToken) == item.validToken)
            #expect(URLDirectControl.requiresConfirmation(allowDirectControl: item.allowDirectControl, providedToken: item.providedToken, expectedToken: item.expectedToken) == item.requiresConfirmation)
        }
        for item in golden.snapTemperatureCases {
            #expect(abs(HomeStore.snappedTemperature(item.celsius, lowerBound: item.min, upperBound: item.max, step: item.step) - item.expected) < 1e-6)
        }
    }

    @Test("Direct natural-language fan preset command refuses unpublished modes and lists available ones (#21)")
    @MainActor
    func directFanPresetRefusesUnpublishedModeAndListsAvailable() async throws {
        let twoModeFan = SmartDevice(
            id: "dev_two_mode_fan",
            name: "卧室风扇",
            roomId: "bedroom",
            roomName: "卧室",
            model: "zhimi.fan.za5",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "fan.two_mode",
                isOn: false,
                percentage: 30,
                presetMode: "Auto",
                availablePresetModes: ["Auto", "Sleep"]
            ))
        )
        let noPresetFan = SmartDevice(
            id: "dev_no_preset_fan",
            name: "书房风扇",
            roomId: "study",
            roomName: "书房",
            model: "zhimi.fan.za4",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "fan.no_preset",
                isOn: false,
                percentage: 40,
                presetMode: nil,
                availablePresetModes: []
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [
                RoomArea(id: "bedroom", name: "卧室", sortOrder: 0),
                RoomArea(id: "study", name: "书房", sortOrder: 1),
            ],
            devices: [twoModeFan, noPresetFan]
        ))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        let missingFav = await store.executeRaycastDirectCommand("把卧室风扇设为最爱模式")
        #expect(missingFav.handled)
        #expect(missingFav.isError)
        #expect(missingFav.message.contains("Auto"))
        #expect(missingFav.message.contains("Sleep"))
        #expect(await provider.executedCommands.isEmpty)
        if case .fan(let spec)? = store.devices.first(where: { $0.id == "dev_two_mode_fan" })?.kind {
            #expect(spec.presetMode == "Auto")
            #expect(spec.isOn == false)
        }

        let emptyPresets = await store.executeRaycastDirectCommand("把书房风扇设为自动模式")
        #expect(emptyPresets.handled)
        #expect(emptyPresets.isError)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test("Direct fan preset succeeds when percentage speed is read-only but preset modes are writable (#263)")
    @MainActor
    func directFanPresetSucceedsWhenSpeedReadOnlyButPresetsWritable() async throws {
        let readOnlySpeedFan = SmartDevice(
            id: "dev_readonly_speed_fan",
            name: "客厅风扇",
            roomId: "living",
            roomName: "客厅",
            model: "zhimi.fan.za5",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "fan.readonly_speed",
                isOn: false,
                percentage: nil,
                presetMode: "Auto",
                availablePresetModes: ["Auto", "Sleep"],
                speedWritable: false
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 0)],
            devices: [readOnlySpeedFan]
        ))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        // 1. Natural language preset command works despite speedWritable == false
        let result = await store.executeRaycastDirectCommand("把客厅风扇设为睡眠模式")
        #expect(result.handled)
        #expect(!result.isError)
        let commands = await provider.executedCommands
        #expect(commands.last == .setFanPresetMode(entityId: "fan.readonly_speed", presetMode: "Sleep"))
        if case .fan(let spec)? = store.devices.first(where: { $0.id == "dev_readonly_speed_fan" })?.kind {
            #expect(spec.presetMode == "Sleep")
            #expect(spec.isOn == true)
        }

        // 2. Setting percentage still correctly refuses when speedWritable == false
        let percentResult = await store.executeRaycastDirectCommand("把客厅风扇风速调到 50%")
        #expect(percentResult.handled)
        #expect(percentResult.isError)

        // 3. executeRaycastFan direct URL preset command also works despite speedWritable == false
        let urlResult = await store.executeRaycastFan(deviceId: "dev_readonly_speed_fan", percent: nil, preset: "Auto")
        #expect(!urlResult.isError)
        let updatedCommands = await provider.executedCommands
        #expect(updatedCommands.last == .setFanPresetMode(entityId: "fan.readonly_speed", presetMode: "Auto"))
    }

    @Test("MCP 2.0 cover-position, media controls, sanitized automationStatus, and zero-placeholder MCP config path")
    @MainActor
    func mcpV2CoverMediaSnapshotAndConfigPath() async throws {
        func mkCover(_ id: String, _ name: String, _ sub: CoverSubtype, _ pos: Int) -> SmartDevice {
            SmartDevice(id: id, name: name, roomId: "living", roomName: "客厅", model: "lumi.\(sub.rawValue)", isOnline: true, kind: .cover(CoverSpec(entityId: "cover.\(id)", subtype: sub, positionPercent: pos, positionWritable: true, openDescription: "Open", closeDescription: "Close")))
        }
        let tv = SmartDevice(id: "dev_tv", name: "客厅电视", roomId: "living", roomName: "客厅", model: "xiaomi.tv.s1", isOnline: true, kind: .tv(TVSpec(mediaEntityId: "media_player.tv", state: "on", volumePercent: 40, isMuted: false, muteSwitchEntityId: "switch.tv_mute", volumeWritable: true, playback: MediaPlaybackState(state: .paused, canPlayPause: true))))
        let provider = MockHomeProvider(snapshot: SynthesizedHome(rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 0)], devices: [mkCover("curtain", "客厅窗帘", .curtain, 80), mkCover("garage", "车库门", .garageDoor, 100), mkCover("window", "书房开窗器", .windowOpener, 50), tv]))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        #expect(!(await store.executeRaycastCoverPosition(deviceId: "curtain", percent: 45)).isError)
        #expect((await provider.executedCommands).last == .setNumberValue(entityId: "cover.curtain", value: 45))
        var confirmCalls = 0
        store.manualControlConfirmationHandler = { _ in confirmCalls += 1; return false }
        for (id, pct) in [("garage", 0), ("garage", 50), ("window", 0), ("window", 50)] {
            #expect((await store.executeRaycastCoverPosition(deviceId: id, percent: pct)).isError)
        }
        #expect(confirmCalls == 4)
        store.manualControlConfirmationHandler = { _ in true }
        #expect(!(await store.executeRaycastCoverPosition(deviceId: "window", percent: 0)).isError)
        #expect((await provider.executedCommands).last == .setNumberValue(entityId: "cover.window", value: 0))

        #expect(!(await store.executeRaycastVolume(deviceId: "dev_tv", percent: 35)).isError)
        #expect((await provider.executedCommands).last == .mediaSetVolume(entityId: "media_player.tv", volumeLevel: 0.35))
        #expect(!(await store.executeRaycastMute(deviceId: "dev_tv", isMuted: true)).isError)
        let afterMute = (await provider.executedCommands).count
        #expect(!(await store.executeRaycastMute(deviceId: "dev_tv", isMuted: true)).isError && (await provider.executedCommands).count == afterMute)
        #expect(!(await store.executeRaycastMediaPlayPause(deviceId: "dev_tv")).isError)
        #expect((await provider.executedCommands).last == .mediaPlayPause(entityId: "media_player.tv"))

        let rule = AutomationRule(trigger: .calendarMeetingStartingSoon, action: .quickAction(.lightsOff))
        store.recordAutomationRun(rule, at: Date(), reason: .cooldown)
        let snap = store.buildRaycastSnapshot()
        let tvSnap = try #require(snap.devices.first { $0.id == "dev_tv" })
        #expect(tvSnap.capabilities.volumeWritable == true && tvSnap.capabilities.muteWritable == true && tvSnap.capabilities.canPlayPause == true)
        #expect(snap.automationStatus?.skippedCount == 1 && snap.automationStatus?.recentRuns.first?.skipReason == "cooldown")

        let bundled = "/Applications/MenuBarHome.app/Contents/Resources/cli/mijia-mcp"; let devPath = "/tmp/repo/scripts/mijia-mcp"
        #expect(CompanionIntegrationConfig.resolveMCPCommandPath(bundleResourceURL: URL(fileURLWithPath: "/Applications/MenuBarHome.app/Contents/Resources", isDirectory: true), executableURL: nil, currentDirectoryURL: URL(fileURLWithPath: "/tmp/repo", isDirectory: true), pathEnvironment: "/opt/bin", isExecutable: { $0 == bundled || $0 == devPath }) == bundled)
        #expect(CompanionIntegrationConfig.resolveMCPCommandPath(bundleResourceURL: nil, executableURL: nil, currentDirectoryURL: URL(fileURLWithPath: "/tmp/repo/sub", isDirectory: true), pathEnvironment: "/opt/bin", isExecutable: { $0 == devPath }) == devPath)
        #expect(CompanionIntegrationConfig.resolveMCPCommandPath(bundleResourceURL: nil, executableURL: nil, currentDirectoryURL: URL(fileURLWithPath: "/tmp/none", isDirectory: true), pathEnvironment: "/opt/bin", isExecutable: { $0 == "/opt/bin/mijia-mcp" }) == "/opt/bin/mijia-mcp")
        let cfg = CompanionIntegrationConfig.mcpConfigJSON(snapshotURL: URL(fileURLWithPath: "/tmp/snap.json"), mcpCommandPath: bundled)
        #expect(cfg.contains(bundled) && !cfg.contains("/ABSOLUTE/PATH/TO/"))
    }
}

