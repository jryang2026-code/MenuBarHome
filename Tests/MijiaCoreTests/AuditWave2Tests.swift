import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct AuditWave2Tests {
    static let studyCeiling = AssistantTests.studyCeiling
    static let studyDesk = AssistantTests.studyDesk

    static func light(id: String, name: String, roomId: String, roomName: String, isOn: Bool = false) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: roomId,
            roomName: roomName,
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: isOn))
        )
    }

    /// One instance per store: a second `UserDefaults(suiteName:)` reads through cfprefsd and can
    /// serve a stale cache under CI load (#309). Cases that reopen the same domain pass it in.
    @MainActor
    private func makeStore(
        devices: [SmartDevice],
        scenes: [HomeScene] = [],
        readings: [EnvironmentReading] = [],
        defaults: InMemoryUserDefaults = InMemoryUserDefaults()
    ) async throws -> (HomeStore, MockHomeProvider) {
        let snapshot = SynthesizedHome(devices: devices, environmentReadings: readings, scenes: scenes)
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaults: defaults)
        store.assistantAutoResetTiming = .never
        store.enableSafetyAlerts = false
        try await store.waitForTestSnapshot()
        store.enableSafetyAlerts = true
        return (store, mock)
    }

    @Test("System One decision heads cover all 12 devices, and habit learning records manual/suggestion actions while skipping AI/scheduled and rolling back on undo")
    @MainActor
    func systemOneHeadsAndHabitLearningLifecycle() async throws {
        let twelveDevices = (1...12).map { idx in
            Self.light(id: "light_\(idx)", name: "灯\(idx)", roomId: "room_\(idx)", roomName: "房间\(idx)")
        }
        let emptyAnswers = try JSONSerialization.data(withJSONObject: ["answers": [String: Any]()])
        let resolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "test-token"),
            transport: { request in
                let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                let questions = try #require(body["questions"] as? [String: Any])
                #expect(questions.keys.filter { $0.hasPrefix("dev_") }.count == 12)
                #expect(questions["dev_d12"] != nil)
                return (emptyAnswers, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        _ = try await resolver.resolve("全屋准备一下", devices: twelveDevices, scenes: [])
        _ = try await resolver.recommendProactiveSuggestions(devices: twelveDevices, scenes: [], context: AssistantContext())

        let (store, _) = try await makeStore(devices: [Self.studyCeiling, Self.studyDesk])
        _ = await store.runAssistantCommand("打开书房灯")
        #expect(store.userHabitMemory.entries.count == 2 && store.userHabitMemory.phrases.count == 1)
        _ = await store.runAssistantCommand("撤销")
        #expect(store.userHabitMemory.entries.isEmpty && store.userHabitMemory.phrases.isEmpty)

        _ = await store.runAssistantCommand("打开书房灯")
        #expect(store.undoBanner?.habitReceipt != nil)
        await store.undoTurnAllOff()?.value
        #expect(store.userHabitMemory.entries.isEmpty && store.userHabitMemory.phrases.isEmpty)

        await store.applyAssistantSuggestion(
            AssistantSuggestion(id: "tap:1", title: "打开书房吸顶灯", intents: [DeviceIntent(targetId: Self.studyCeiling.id, operation: .power(true))])
        )
        #expect(store.userHabitMemory.entries.count == 1)

        let (aiStore, _) = try await makeStore(devices: [Self.studyCeiling])
        aiStore.setAIAssistantEnabled(true)
        let content = #"{"actions":[{"device":"d1","op":"power","value":true}],"reply":"已打开书房吸顶灯"}"#
        aiStore.assistantResolverOverride = ModelIntentResolver(
            config: AssistantConfig(model: "glm-5.1"),
            transport: { request in
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let plan = try #require(await aiStore.runAssistantCommand("我要睡觉了"))
        #expect(plan.source == .model && aiStore.userHabitMemory.entries.isEmpty)

        aiStore.assistantResolverOverride = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://example.invalid/v1", model: "m", apiKey: "k"),
            transport: { _ in throw URLError(.timedOut) }
        )
        await L10n.$overrideLanguage.withValue(.zhHans) {
            _ = await aiStore.runAssistantCommand("我有点冷怎么办")
            if case .failed(let msg) = aiStore.assistantState {
                #expect(msg.hasPrefix("AI 服务 10 秒没回应"))
            } else {
                Issue.record("expected failure")
            }
        }

        let schedDefaults = InMemoryUserDefaults()
        let (schedStore, _) = try await makeStore(devices: [Self.studyCeiling], defaults: schedDefaults)
        schedStore.assistantSleep = { _ in }
        schedStore.assistantNow = { Date() }
        _ = await schedStore.runAssistantCommand("10秒后打开书房灯")
        await waitUntil { schedStore.devices.first?.isActiveOn == true }
        #expect(schedStore.userHabitMemory.entries.isEmpty)

        let missedPlan = IntentPlan(intents: [DeviceIntent(targetId: Self.studyCeiling.id, operation: .power(false))], reply: "关闭书房吸顶灯", source: .local)
        let entry = ScheduledCommand(reply: "关闭书房吸顶灯", fireDate: Date().addingTimeInterval(-120), plan: missedPlan)
        ScheduledCommand.save([entry], to: schedDefaults)
        schedStore.restoreScheduledCommands(now: Date())
        _ = await schedStore.runMissedScheduledCommand(id: entry.id)
        #expect(schedStore.devices.first?.isActiveOn == false && schedStore.userHabitMemory.entries.isEmpty)

        var memory = UserHabitMemory()
        let intent = DeviceIntent(targetId: Self.studyCeiling.id, operation: .power(true))
        memory.record(utterance: "开灯", intents: [intent], devices: [Self.studyCeiling], scenes: [])
        let receipt = memory.record(utterance: "开灯", intents: [intent], devices: [Self.studyCeiling], scenes: [])
        if let receipt { memory.unrecord(receipt) }
        #expect(memory.entries.first?.count == 1 && memory.phrases.first?.count == 1)
    }

    @Test("Safety alerts require high power on long-running plugs and persist low-battery cooldown across stores")
    @MainActor
    func longRunningPlugPowerThresholdAndLowBatteryCooldownPersistence() async throws {
        let lowPowerPlug = SmartDevice(id: "plug_low", name: "路由器插座", roomId: "study", roomName: "书房", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.low", isOn: true, powerWatts: 5)))
        let noDataPlug = SmartDevice(id: "plug_nodata", name: "冰箱插座", roomId: "kitchen", roomName: "厨房", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.nodata", isOn: true)))
        let highPowerPlug = SmartDevice(id: "plug_high", name: "咖啡机插座", roomId: "kitchen", roomName: "厨房", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.high", isOn: true, powerWatts: 1_200)))

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (plugStore, _) = try await makeStore(devices: [lowPowerPlug, noDataPlug, highPowerPlug])
        #expect(plugStore.evaluateSafetyAlerts(now: start).isEmpty)
        let alerts = plugStore.evaluateSafetyAlerts(now: start.addingTimeInterval(46 * 60))
        #expect(alerts.map(\.id) == ["longrun:plug_high"])

        // Three stores on one domain: the shared instance is what proves the cooldown was persisted.
        let batteryDefaults = InMemoryUserDefaults()
        let sensor = SmartDevice(id: "sensor_low", name: "门磁", roomId: "hall", roomName: "走廊", model: "lumi.sensor_magnet", isOnline: true, kind: .sensor(SensorSpec(battery: 10)))
        let (first, _) = try await makeStore(devices: [sensor], defaults: batteryDefaults)
        #expect(first.evaluateSafetyAlerts(now: start).contains { $0.id == "battery:sensor_low" })
        let (second, _) = try await makeStore(devices: [sensor], defaults: batteryDefaults)
        #expect(second.evaluateSafetyAlerts(now: start.addingTimeInterval(3_600)).isEmpty)
        let (third, _) = try await makeStore(devices: [sensor], defaults: batteryDefaults)
        #expect(third.evaluateSafetyAlerts(now: start.addingTimeInterval(86_401)).contains { $0.id == "battery:sensor_low" })
    }

    @Test("Provider room ordering, legacy menu-bar mode migration, softNightLight history fallback, demo backend offline isolation, and speech preference")
    @MainActor
    func roomOrderingMenuBarSoftNightLightDemoAndSpeech() async throws {
        let devices = [
            Self.light(id: "bed", name: "Bed Lamp", roomId: "r-bed", roomName: "Bedroom"),
            Self.light(id: "living", name: "Ceiling", roomId: "r-living", roomName: "Living Room"),
            Self.light(id: "study", name: "Desk Lamp", roomId: "r-study", roomName: "Study")
        ]
        let order = DeviceSynthesizer.roomNameOrder(from: ["Living Room", "Bedroom", "Study"])
        let home = DeviceSynthesizer.assembleHome(devices: devices, readings: [], scenes: [], roomNameOrder: order)
        #expect(home.rooms.map(\.name) == ["Living Room", "Bedroom", "Study"])
        #expect(home.devices.map(\.roomName) == ["Living Room", "Bedroom", "Study"])

        let haHome = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "a_living", name: "Living Room"), HAAreaEntry(area_id: "a_bed", name: "Bedroom")],
            devices: [HADeviceEntry(id: "d_bed", area_id: "a_bed", name: "Bed Lamp"), HADeviceEntry(id: "d_living", area_id: "a_living", name: "Ceiling")],
            entities: [HAEntityEntry(entity_id: "light.bed", device_id: "d_bed"), HAEntityEntry(entity_id: "light.living", device_id: "d_living")],
            states: ["light.bed": HAEntityState(entityId: "light.bed", state: "off"), "light.living": HAEntityState(entityId: "light.living", state: "off")]
        )
        #expect(haHome.rooms.map(\.name) == ["Living Room", "Bedroom"])

        let mbDefaults = InMemoryUserDefaults()
        mbDefaults.set("primaryTemp", forKey: "menubar_display_mode")
        let livingReading = EnvironmentReading(id: "sensor_living", label: "Living Room Sensor", roomName: "Living Room", temperature: 25.5, humidity: 45)
        let (mbStore, _) = try await makeStore(devices: [], readings: [livingReading], defaults: mbDefaults)
        #expect(mbStore.menuBarDisplayMode == .sensorTemperature && mbStore.menuBarTargetId == "temp:sensor_living")
        L10n.$overrideTemperatureUnit.withValue(.celsius) { #expect(mbStore.menuBarText == "25.5°C") }

        let bedLight = Self.light(id: "bed_light", name: "Bed Lamp", roomId: "bed", roomName: "Bedroom")
        let livLight = Self.light(id: "living_light", name: "Ceiling", roomId: "living", roomName: "Living Room")
        let (nlStore, _) = try await makeStore(devices: [bedLight, livLight])
        storeToggle: do {
            let l1 = try #require(nlStore.devices.first { $0.id == "living_light" })
            #expect(await nlStore.togglePrimary(l1)?.value == true)
            let l2 = try #require(nlStore.devices.first { $0.id == "living_light" })
            #expect(await nlStore.togglePrimary(l2)?.value == true)
        }
        nlStore.executeQuickAction(.softNightLight)
        #expect(nlStore.devices.first { $0.id == "bed_light" }?.isActiveOn == false)
        #expect(nlStore.devices.first { $0.id == "living_light" }?.isActiveOn == true)

        let demoDefaults = InMemoryUserDefaults()
        demoDefaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
        let demoStore = HomeStore(defaults: demoDefaults)
        try await demoStore.waitForTestSnapshot()
        #expect(demoStore.homeBackend == .demo && demoStore.provider is DemoHomeProvider && demoStore.environmentReadings.count == 3)
        #expect(demoStore.prefersOnDeviceSpeech == true)
        demoStore.prefersOnDeviceSpeech = false
        #expect(HomeStore(provider: MockHomeProvider(), defaults: demoDefaults).prefersOnDeviceSpeech == false)

        demoStore.pinDeviceSource("card-a", to: .xiaomiCloud)
        #expect(demoStore.pinnedSource(for: "card-a") == .xiaomiCloud)
        #expect(DeviceSourcePinStorage.load(defaults: demoDefaults)["card-a"] == .xiaomiCloud)
        #expect(DevicePreferenceIndex.referencedIDs(defaults: demoDefaults).contains("card-a"))
        demoStore.pinDeviceSource("card-a", to: nil)
        #expect(demoStore.pinnedSource(for: "card-a") == nil)
        #expect(DeviceSourcePinStorage.load(defaults: demoDefaults)["card-a"] == nil)

        demoStore.setAIAssistantEnabled(true)
        demoStore.assistantConfig = AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "test-key")
        demoStore.assistantTransportOverride = { _ in
            Issue.record("Demo mode must not issue cloud requests")
            throw URLError(.badServerResponse)
        }
        #expect(await demoStore.runAssistantCommand("随口说一句解析不了的话xyzzy") == nil)
        await demoStore.requestProactiveJevSuggestions()
        #expect(!(await demoStore.verifyAssistantConfig(demoStore.assistantConfig).isSuccess))
    }
}
