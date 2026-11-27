import Foundation
import Testing
@testable import MijiaCore

struct AICoreCoverageTests {
    static let fan = SmartDevice(id: "dev_fan", name: "客厅风扇", roomId: "living", roomName: "客厅", model: "dmaker.fan.p5", isOnline: true, kind: .fan(FanSpec(entityId: "fan.living", isOn: true, percentage: 30, presetMode: "Level1", availablePresetModes: ["Level1", "Level2", "Level3"], isOscillating: false)))
    static let deskLamp = SmartDevice(id: "dev_lamp", name: "书房台灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "light.study_desk", isOn: false, brightnessPercent: 50)))
    static func cover(_ id: String, _ name: String, _ subtype: CoverSubtype, pos: Int = 0) -> SmartDevice {
        SmartDevice(id: id, name: name, roomId: "living", roomName: "客厅", model: "lumi.curtain.v1", isOnline: true, kind: .cover(CoverSpec(entityId: "cover.\(id)", subtype: subtype, positionPercent: pos, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause")))
    }
    static func testSyllables(_ text: String) -> [String]? {
        let map: [Character: String] = ["书": "shu", "房": "fang", "台": "tai", "灯": "deng", "等": "deng", "客": "ke", "厅": "ting", "窗": "chuang", "帘": "lian", "连": "lian"]
        let syms = text.compactMap { map[$0] }; return syms.isEmpty ? nil : syms
    }

    @Test("fan_percentage, cover_position, and safety gates work across models and catalog")
    func fanCoverAndSafetyGates() throws {
        let curtain = Self.cover("c1", "客厅窗帘", .curtain), garage = Self.cover("c2", "车库门", .garageDoor, pos: 50)
        let opener = Self.cover("c3", "阳台开窗器", .windowOpener, pos: 50), airer = Self.cover("c4", "阳台晾衣架", .clothesAirer, pos: 50)
        let all = [Self.fan, Self.deskLamp, curtain, garage, opener, airer]
        let catalog = IntentCatalog(devices: all, scenes: [])
        #expect(catalog.realIds(forTargetChoice: "d3") == ["c1"] && !catalog.realIds(forTargetChoice: "all_devices").contains("c1"))
        let prompt = ModelIntentResolver.systemPrompt(catalog: catalog)
        #expect(prompt.contains("fan_percentage") && prompt.contains("cover_position"))

        let json = #"{"actions":[{"device":"d1","op":"fan_percentage","value":65},{"device":"d3","op":"cover_position","value":50}],"reply":"已调节"}"#
        let plan = try ModelIntentResolver.plan(fromModelContent: json, catalog: catalog, devices: all, scenes: [])
        #expect(plan.intents == [DeviceIntent(targetId: "dev_fan", operation: .fanPercentage(65)), DeviceIntent(targetId: "c1", operation: .coverPosition(50))])
        let mapped = AssistantLocalPlanMapper.plan(actions: [.init(target: "d1", operation: .fanPercentage(40)), .init(target: "d3", operation: .coverPosition(30))], reply: "ok", catalog: catalog, devices: all, scenes: [])
        #expect(mapped.intents == [DeviceIntent(targetId: "dev_fan", operation: .fanPercentage(40)), DeviceIntent(targetId: "c1", operation: .coverPosition(30))])
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            #expect(FoundationAssistantOperation.fanPercentage(55).intentOperation == .fanPercentage(55))
            #expect(FoundationAssistantOperation.coverPosition(50).intentOperation == .coverPosition(50))
        }
        #endif

        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c1", operation: .coverPosition(50)), devices: all))
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c2", operation: .coverPosition(0)), devices: all))
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c2", operation: .coverPosition(50)), devices: all))
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c3", operation: .coverPosition(50)), devices: all))
        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c3", operation: .coverPosition(0)), devices: all))
        #expect(ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c4", operation: .coverPosition(50)), devices: all))
        #expect(!ModelActionPolicy.needsConfirmation(DeviceIntent(targetId: "c4", operation: .coverPosition(0)), devices: all))
        #expect(ManualControlPolicy.requiresConfirmation(.coverPosition(0), for: garage))
        #expect(LocalIntentParser.parse("关闭所有设备", devices: all, scenes: [])?.intents.contains { $0.targetId == "c1" || $0.targetId == "c2" } != true)
    }

    @Test("Pinyin, homophones, 3-way miss diagnostics, and 0ms learned shortcuts respect safety gates")
    @MainActor
    func pinyinDiagnosticsAndLearnedShortcut() async throws {
        let curtain = Self.cover("c1", "客厅窗帘", .curtain), garage = Self.cover("c2", "车库门", .garageDoor, pos: 0)
        let devs = [Self.fan, Self.deskLamp, curtain]
        let parse: (String) -> LocalIntentParseOutcome = { LocalIntentParser.parseWithDiagnostic($0, devices: devs, scenes: [], syllables: Self.testSyllables) }
        #expect(parse("打开 sftd").plan?.intents == [DeviceIntent(targetId: "dev_lamp", operation: .power(true))])
        #expect(parse("turn on shufangtaideng").plan?.intents == [DeviceIntent(targetId: "dev_lamp", operation: .power(true))])
        #expect(parse("打开书房台等").plan?.intents == [DeviceIntent(targetId: "dev_lamp", operation: .power(true))])
        #expect(parse("把客厅窗连开到50%").plan?.intents == [DeviceIntent(targetId: "c1", operation: .coverPosition(50))])
        #expect(parse("打开厨房灯") == .missed(.unknownDevice) && parse("打开火星投影仪") == .missed(.unknownDevice))
        #expect(parse("客厅窗帘亮度50%") == .missed(.unsupportedAction) && parse("书房台灯调到26度") == .missed(.unsupportedAction))
        #expect(parse("我要睡觉了") == .missed(.unrecognizedPhrasing))

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.deskLamp, garage], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.shortcut.\(UUID().uuidString)")
        store.assistantAutoResetTiming = .never
        try await store.waitForTestSnapshot()
        var mem = store.userHabitMemory
        let firstLamp = mem.learnPhraseShortcut(phrase: "我要看书", intents: [DeviceIntent(targetId: "dev_lamp", operation: .power(true))], devices: store.devices, scenes: [])
        let secondLamp = mem.learnPhraseShortcut(phrase: "我要看书", intents: [DeviceIntent(targetId: "dev_lamp", operation: .power(true))], devices: store.devices, scenes: [])
        let prematureShortcut = mem.learnedShortcutPlan(for: "我要看书", devices: store.devices, scenes: [])
        #expect(firstLamp != nil && secondLamp != nil && prematureShortcut == nil)
        let thirdLamp = mem.learnPhraseShortcut(phrase: "我要看书", intents: [DeviceIntent(targetId: "dev_lamp", operation: .power(true))], devices: store.devices, scenes: [])
        var learnedGarage = true
        for _ in 0..<UserHabitMemory.learnedShortcutMinCount {
            if mem.learnPhraseShortcut(phrase: "开个门", intents: [DeviceIntent(targetId: "c2", operation: .coverPosition(50))], devices: store.devices, scenes: []) == nil {
                learnedGarage = false
            }
        }
        #expect(thirdLamp != nil && learnedGarage)
        store.userHabitMemory = mem

        var prompted = false
        store.manualControlConfirmationHandler = { _ in prompted = true; return false }
        let denied = try #require(await store.runAssistantCommand("开个门"))
        let cmdsAfterDenied = await mock.executedCommands
        #expect(prompted && denied.intents.isEmpty && cmdsAfterDenied.isEmpty)
        store.setScreenLocked(true)
        let locked = try #require(await store.runAssistantCommand("我要看书"))
        let cmdsAfterLocked = await mock.executedCommands
        #expect(locked.intents.isEmpty && locked.reply == store.screenLockBlockedMessage && cmdsAfterLocked.isEmpty)
        store.setScreenLocked(false)
        let ok = try #require(await store.runAssistantCommand("我要看书"))
        let cmdsAfterOk = await mock.executedCommands
        #expect(ok.source == .local && cmdsAfterOk == [.setLightPower(entityId: "light.study_desk", isOn: true)])
    }

    @Test("Chat catalog token budget, response_format JSON schema fallback retry, and Ollama preset")
    func chatBudgetAndSchemaFallback() async throws {
        var many: [SmartDevice] = (1...48).map { i in SmartDevice(id: "d_\(i)", name: "备用台灯\(i)", roomId: "r_\(i % 6)", roomName: "房间\(i % 6)", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "light.d_\(i)", isOn: false))) }
        many.append(Self.cover("cov_bed", "主卧窗帘", .curtain))
        let catalog = IntentCatalog(devices: many, scenes: [])
        let prompt = ModelIntentResolver.systemPrompt(catalog: catalog, mention: "把主卧窗帘开到50%", maxCatalogTokens: 900)
        #expect(prompt.contains("主卧窗帘") && prompt.count < catalog.text.count + 600)

        let bodies = LockedBox<[[String: Any]]>([])
        let resolver = ModelIntentResolver(config: AssistantConfig(baseURL: "http://localhost:11434/v1", model: AssistantProviderPreset.ollama.defaultModel), transport: { req in
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            bodies.mutate { $0.append(obj) }
            if obj["response_format"] != nil { return (Data(#"{"error":{"message":"response_format json_schema unsupported"}}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!) }
            if obj["temperature"] != nil { return (Data(#"{"error":{"message":"invalid temperature"}}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!) }
            return (Data(#"{"choices":[{"message":{"content":"{\"actions\":[{\"device\":\"d1\",\"op\":\"fan_percentage\",\"value\":45}],\"reply\":\"已调速\"}"}}]}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let plan = try await resolver.resolve("把风扇吹柔一点", devices: [Self.fan], scenes: [])
        let sent = bodies.value
        #expect(sent.count == 3 && sent[0]["response_format"] != nil && sent[1]["response_format"] == nil && sent[2]["temperature"] == nil)
        #expect(plan.intents == [DeviceIntent(targetId: "dev_fan", operation: .fanPercentage(45))] && AssistantProviderPreset.ollama.defaultModel == "qwen3:8b")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func mutate(_ transform: (inout Value) -> Void) { lock.withLock { transform(&storage) } }
}
