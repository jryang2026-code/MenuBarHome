import Foundation
import Testing
@testable import MijiaCore

/// #26: the fallback table and the manual confirmation rules live in the shared JSON documents,
/// so macOS and Windows cannot drift from the code that reads them.
struct ManualControlPolicyTests {
    private static func genericDevice(_ deviceType: String) -> SmartDevice {
        SmartDevice(
            id: "vendor",
            name: deviceType,
            roomId: "test",
            roomName: "test",
            model: "generic.\(deviceType)",
            isOnline: true,
            kind: .generic(GenericSpec(
                deviceType: deviceType,
                typeTitle: deviceType,
                isOn: false,
                powerControl: nil,
                isReadOnly: false
            ))
        )
    }

    private static func facet(
        name: String = "speed",
        service: String = "vendor-service",
        current: JSONValue = .number(1),
        whitelisted: Bool = false
    ) -> FacetControl {
        FacetControl(
            id: "3.2",
            kind: .slider,
            name: name,
            title: "辅助设置",
            serviceName: service,
            value: current,
            isWritable: true,
            writesByDefault: whitelisted,
            isHighValue: true,
            target: .property(entityId: "miot:vendor:3", piid: 2)
        )
    }

    private static func spec(property: String) -> MiotDeviceSpec {
        MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:vendor-device:0000A000:test:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:vendor:00007800:test:1",
                    properties: [
                        MiotProperty(
                            iid: 1,
                            type: "urn:miot-spec-v2:property:\(property):00000000:test:1",
                            format: "uint8",
                            access: ["read", "write"],
                            valueRange: [0, 100, 1]
                        )
                    ]
                )
            ]
        )
    }

    @Test("Custom rules de-escalate a service the default table asks about (#26)")
    func rulesDriveFacetConfirmation() {
        let device = Self.genericDevice("vendor-box")
        let facet = Self.facet()

        #expect(ManualControlPolicy.facetRequiresConfirmation(facet, value: .number(2), for: device))

        let custom = DeviceProfiles.ManualControlRules(
            strictlyHighRisk: [],
            heatingService: [],
            lowRiskServices: ["vendor-service"],
            lowRiskTokens: []
        )
        #expect(!ManualControlPolicy.facetRequiresConfirmation(
            facet, value: .number(2), for: device, rules: custom
        ))
    }

    @Test("Custom strictly-high-risk entries keep an off direction behind a confirmation (#26)")
    func rulesDriveStrictRisk() {
        let device = Self.genericDevice("vendor-box")
        let facet = Self.facet(name: "on", service: "vendor-service", current: .bool(true))

        #expect(!ManualControlPolicy.facetRequiresConfirmation(facet, value: .bool(false), for: device))

        let custom = DeviceProfiles.ManualControlRules(
            strictlyHighRisk: ["vendor-service"],
            heatingService: [],
            lowRiskServices: [],
            lowRiskTokens: []
        )
        #expect(ManualControlPolicy.facetRequiresConfirmation(
            facet, value: .bool(false), for: device, rules: custom
        ))
    }

    @Test("MiotFacetEngine reads the low-risk write list from the same document (#26)")
    func lowRiskWritesDriveFacetRisk() throws {
        let data = try #require(DeviceProfiles.bundledData())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var root = try #require(object)
        var facets = try #require(root["facets"] as? [String: Any])
        facets["lowRiskWrites"] = ["vendor-knob"]
        root["facets"] = facets
        let custom = try DeviceProfiles.decode(JSONSerialization.data(withJSONObject: root))

        let customFacet = try #require(
            MiotFacetEngine.facets(for: Self.spec(property: "vendor-knob"), profiles: custom).first
        )
        #expect(customFacet.writesByDefault)

        let bundledFacet = try #require(
            MiotFacetEngine.facets(for: Self.spec(property: "vendor-knob"), profiles: .current).first
        )
        #expect(!bundledFacet.writesByDefault)
    }

    @Test("Switched lights skip manual confirmation, export as low-risk light in RaycastSnapshot, and allow low-risk HA companion switches")
    @MainActor
    func switchedLightsManualSnapshotAndHAFacets() async throws {
        func makePlug(
            id: String,
            name: String,
            model: String,
            switchEntityId: String? = nil,
            powerWritable: Bool = true
        ) -> SmartDevice {
            SmartDevice(
                id: id,
                name: name,
                roomId: "kitchen",
                roomName: "厨房",
                model: model,
                isOnline: true,
                kind: .plug(PlugSpec(
                    switchEntityId: switchEntityId ?? "switch.\(id)",
                    isOn: false,
                    powerWritable: powerWritable
                ))
            )
        }

        let positives: [SmartDevice] = [
            makePlug(id: "sw_kitchen", name: "厨房灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "sw_downlight", name: "筒灯", model: "lemesh.switch.sw2f12"),
            makePlug(id: "sw_en_light", name: "Kitchen Light", model: "lumi.switch.b1nacn02", switchEntityId: "switch.kitchen_light"),
            makePlug(id: "sw_warm_strip", name: "暖光灯带", model: "cuco.plug.cp1"),
            makePlug(id: "sw_lighting", name: "厨房照明", model: "090615.switch.09dh1"),
            makePlug(id: "sw_kitchen_trad", name: "廚房燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "sw_living_ceiling_trad", name: "客廳吸頂燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "sw_hall_lighting_trad", name: "玄關照明燈", model: "090615.switch.09dh1")
        ]

        for dev in positives {
            #expect(!ManualControlPolicy.requiresConfirmation(.power(true), for: dev), "\(dev.name) on should not confirm")
            #expect(!ManualControlPolicy.requiresConfirmation(.power(false), for: dev), "\(dev.name) off should not confirm")
        }

        let negatives: [SmartDevice] = [
            makePlug(id: "neg_steril", name: "杀菌灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_uv_zh", name: "紫外线消毒灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_uv_en", name: "UV灯", model: "cuco.plug.v3"),
            makePlug(id: "neg_bath_heat", name: "浴霸取暖灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_ir", name: "红外烤灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_mosquito", name: "灭蚊灯", model: "cuco.plug.v3"),
            makePlug(id: "neg_indicator", name: "路由器指示灯", model: "cuco.plug.v3"),
            makePlug(id: "neg_desk_outlet_zh", name: "台灯插座", model: "cuco.plug.v3"),
            makePlug(id: "neg_desk_outlet_en", name: "Desk Lamp Outlet", model: "cuco.plug.v3"),
            makePlug(id: "neg_uv_trad", name: "紫外線殺菌燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_bath_heat_trad", name: "浴霸取暖燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_ir_trad", name: "紅外烤燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_mosquito_trad", name: "滅蚊燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_mosquito_repel_trad", name: "驅蚊燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_indicator_trad", name: "路由器指示燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_signal_trad", name: "信號燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_xunhao_trad", name: "訊號燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_desk_outlet_trad", name: "檯燈插座", model: "cuco.plug.v3"),
            makePlug(id: "neg_ext_cord_trad", name: "延長線燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_electric_heat_trad", name: "電暖燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_healthpot_trad", name: "養生壺燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_rice_cooker_trad", name: "電飯鍋燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_stove_heater_trad", name: "暖爐燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_bath_hot_air_trad", name: "浴室熱風燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_dryer_trad", name: "烘乾機燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_bug_zapper_trad", name: "滅蟲燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_warning_trad", name: "警示燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_alarm_trad", name: "警報燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_smart_plug_trad", name: "智能插頭燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_adapter_trad", name: "轉接頭燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_rolling_door_trad", name: "鐵捲門燈", model: "lumi.switch.b1nacn02"),
            makePlug(id: "neg_uvc_trad", name: "UVC燈", model: "cuco.plug.v3"),
            makePlug(id: "neg_button", name: "厨房灯", model: "lumi.switch.b1nacn02", switchEntityId: "button.kitchen_light"),
            makePlug(id: "neg_breaker", name: "厨房灯", model: "lumi.switch.b1nacn02", powerWritable: false),
            makePlug(id: "neg_oven", name: "厨房灯", model: "chunmi.oven.s1")
        ]

        for dev in negatives {
            #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: dev), "\(dev.name) (\(dev.model)) should confirm")
        }

        let kitchenLight = positives[0]
        let uvLamp = negatives[1]
        let kitchenPlug = makePlug(id: "kitchen_plug", name: "厨房插座", model: "cuco.plug.cp1")

        let suite = "test.switched.light.snapshot.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let provider = MockHomeProvider(
            snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "kitchen", name: "厨房", sortOrder: 0)],
                devices: [kitchenLight, uvLamp, kitchenPlug]
            )
        )
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        let snapshot = store.buildRaycastSnapshot()

        let lightItem = try #require(snapshot.devices.first { $0.id == kitchenLight.id })
        #expect(lightItem.capabilities.isHighRisk == false)
        #expect(lightItem.category == "light")

        let uvItem = try #require(snapshot.devices.first { $0.id == uvLamp.id })
        #expect(uvItem.capabilities.isHighRisk == true)
        #expect(uvItem.category == "plug")

        let entity = HAEntityEntry(entity_id: "switch.kitchen_led", translation_key: "led")
        let states = ["switch.kitchen_led": HAEntityState(entityId: "switch.kitchen_led", state: "on")]

        let lightFacets = HAFacetEngine.controls(
            entities: [entity],
            states: states,
            excluding: [],
            device: kitchenLight
        )
        let lightFacet = try #require(lightFacets.first)
        #expect(lightFacet.writesByDefault == true)

        let plugFacets = HAFacetEngine.controls(
            entities: [entity],
            states: states,
            excluding: [],
            device: kitchenPlug
        )
        let plugFacet = try #require(plugFacets.first)
        #expect(plugFacet.writesByDefault == false)
    }

    @Test("A default-named wall switch still confirms, and only that dialog offers the rename hint (#104)")
    func wallSwitchLightHintDoesNotChangeConfirmation() {
        func makePlug(
            id: String,
            name: String,
            model: String,
            switchEntityId: String? = nil,
            powerWritable: Bool = true
        ) -> SmartDevice {
            SmartDevice(
                id: id,
                name: name,
                roomId: "hall",
                roomName: "玄关",
                model: model,
                isOnline: true,
                kind: .plug(PlugSpec(
                    switchEntityId: switchEntityId ?? "switch.\(id)",
                    isOn: false,
                    powerWritable: powerWritable
                ))
            )
        }

        // #104: the hint now points at the in-prompt mark entry instead of a rename keyword.
        let hintMark = "这是灯，以后不再询问"
        let wallSwitches = [
            makePlug(id: "left", name: "左键", model: "lumi.switch.b1nacn02"),
            makePlug(id: "middle", name: "中键", model: "lumi.switch.b2nacn02"),
            makePlug(id: "right", name: "右键", model: "lemesh.switch.sw2f12"),
            makePlug(id: "channel", name: "一路开关", model: "090615.switch.09dh1"),
        ]
        for dev in wallSwitches {
            #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: dev), "\(dev.name) still confirms")
            #expect(!ManualControlPolicy.requiresConfirmation(.power(false), for: dev), "\(dev.name) off stays direct")
            let prompt = ManualControlPolicy.confirmation(
                DeviceIntent(targetId: dev.id, operation: .power(true)),
                devices: [dev]
            )
            #expect(prompt?.hint?.contains(hintMark) == true, "\(dev.name) hint")
            #expect(prompt?.message.contains(hintMark) == false, "hint stays out of the decision message")
        }

        let silent = [
            makePlug(id: "socket", name: "书房插座", model: "cuco.plug.v3"),
            makePlug(id: "heater-plug", name: "取暖器插座", model: "chuangmi.plug.212a01"),
            makePlug(id: "named-switch", name: "一路开关", model: "cuco.plug.cp1"),
            makePlug(id: "uv", name: "杀菌灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "bath", name: "浴霸取暖灯", model: "lumi.switch.b1nacn02"),
            makePlug(id: "button", name: "左键", model: "lumi.switch.b1nacn02", switchEntityId: "button.left"),
            makePlug(id: "breaker", name: "左键", model: "lumi.switch.b1nacn02", powerWritable: false),
            makePlug(id: "oven", name: "左键", model: "chunmi.oven.s1"),
            makePlug(id: "already", name: "厨房灯", model: "lumi.switch.b1nacn02"),
        ]
        for dev in silent {
            let on = ManualControlPolicy.requiresConfirmation(.power(true), for: dev)
            let prompt = ManualControlPolicy.confirmation(
                DeviceIntent(targetId: dev.id, operation: .power(true)),
                devices: [dev]
            )
            #expect(prompt?.hint == nil, "\(dev.name) (\(dev.model)) has no rename hint")
            #expect((prompt != nil) == on, "\(dev.name) confirmation follows the existing decision")
        }

        let heater = SmartDevice(
            id: "heater", name: "电暖器", roomId: "study", roomName: "书房",
            model: "xiaomi.heater.v1", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.heater", isOn: false, hvacMode: "off",
                availableModes: ["off", "heat"], targetTemperature: 22, minTemp: 16, maxTemp: 30
            ))
        )
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: heater))
        #expect(ManualControlPolicy.confirmation(
            DeviceIntent(targetId: heater.id, operation: .power(true)),
            devices: [heater]
        )?.hint == nil)

    }

    @Test("Every language's hint recommends a name keyword that really stops the confirmation (#104)")
    func wallSwitchLightHintKeywordIsRecognizedInEveryLanguage() {
        let left = SmartDevice(
            id: "left", name: "左键", roomId: "hall", roomName: "玄关",
            model: "lumi.switch.b1nacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.left", isOn: false, powerWritable: true))
        )
        #expect(Set(AppLanguage.allCases).isSuperset(of: [.zhHans, .zhHant, .en]))
        for language in AppLanguage.allCases {
            L10n.$overrideLanguage.withValue(language) {
                let hint = ManualControlPolicy.confirmation(
                    DeviceIntent(targetId: left.id, operation: .power(true)),
                    devices: [left]
                )?.hint ?? ""
                let keywords = Self.quotedKeywords(in: hint)
                #expect(!keywords.isEmpty, "\(language.rawValue) hint names a keyword: \(hint)")
                if language == .zhHant {
                    // #104: the quoted text is now the mark entry's label, which names 「燈」.
                    #expect(keywords == ["這是燈，以後不再詢問"])
                }
                for keyword in keywords {
                    var renamed = left
                    renamed.name = "\(left.name) \(keyword)"
                    #expect(renamed.isSwitchedLight, "\(language.rawValue) keyword \(keyword) is a light name")
                    #expect(
                        !ManualControlPolicy.requiresConfirmation(.power(true), for: renamed),
                        "\(language.rawValue) keyword \(keyword) stops the confirmation"
                    )
                }
            }
        }
    }

    // MARK: - «这其实是灯» marks (#104)

    private static func wallSwitch(
        id: String = "wall",
        name: String = "左键",
        model: String = "lumi.switch.b1nacn02",
        switchEntityId: String? = nil,
        powerWritable: Bool = true
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: "hall",
            roomName: "玄关",
            model: model,
            isOnline: true,
            kind: .plug(PlugSpec(
                switchEntityId: switchEntityId ?? "switch.\(id)",
                isOn: false,
                powerWritable: powerWritable
            ))
        )
    }

    @Test("A wall switch marked as a light stops confirming; the mark never widens to other kinds (#104)")
    func markedSwitchLightStopsConfirmation() throws {
        let wall = Self.wallSwitch()
        let marks: Set<String> = [wall.id]
        #expect(ManualControlPolicy.wallSwitchMayControlLight(wall))

        // The marked switch no longer asks, exactly like renaming it with 「灯」 would.
        #expect(!ManualControlPolicy.requiresConfirmation(.power(true), for: wall, markedLightIds: marks))
        #expect(ManualControlPolicy.confirmation(
            DeviceIntent(targetId: wall.id, operation: .power(true)),
            devices: [wall],
            markedLightIds: marks
        ) == nil, "no prompt at all once marked")

        // Unmarked, the existing hazard table still asks and offers the entry in the prompt.
        let prompt = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: wall.id, operation: .power(true)),
            devices: [wall],
            markedLightIds: []
        )
        let option = try #require(prompt?.markAsLight)
        #expect(option.deviceId == wall.id)
        #expect(!option.title.isEmpty)
        // An already marked device never re-offers the entry.
        #expect(ManualControlPolicy.confirmation(
            DeviceIntent(targetId: wall.id, operation: .power(true)),
            devices: [wall],
            markedLightIds: marks
        ) == nil)

        // Stale marks never widen: every other kind still asks (#104 review).
        let stale: Set<String> = ["stale-plug", "stale-garage", "stale-heater", "stale-uv", "stale-button", "wall"]
        let socket = SmartDevice(
            id: "stale-plug", name: "书房插座", roomId: "study", roomName: "书房",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.plug", isOn: false, powerWritable: true))
        )
        let garage = SmartDevice(
            id: "stale-garage", name: "地下车库门", roomId: "door", roomName: "门口",
            model: "hmpace.wallswitch.v1", isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.garage", subtype: .garageDoor, positionPercent: 0,
                positionWritable: true, openDescription: "Open", closeDescription: "Close",
                pauseDescription: "Pause"
            ))
        )
        let heater = SmartDevice(
            id: "stale-heater", name: "电暖器", roomId: "study", roomName: "书房",
            model: "zhimi.heater.za2", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.heater", isOn: false, hvacMode: "off",
                availableModes: ["off", "heat"], targetTemperature: 22, minTemp: 16, maxTemp: 30
            ))
        )
        let uv = Self.wallSwitch(id: "stale-uv", name: "杀菌灯", model: "lumi.switch.b1nacn02")
        let button = Self.wallSwitch(id: "stale-button", name: "左键", switchEntityId: "button.left")
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: socket, markedLightIds: stale))
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: garage, markedLightIds: stale))
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: heater, markedLightIds: stale))
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: uv, markedLightIds: stale))
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: button, markedLightIds: stale))
        for dev in [socket, uv, button] {
            #expect(ManualControlPolicy.confirmation(
                DeviceIntent(targetId: dev.id, operation: .power(true)),
                devices: [dev],
                markedLightIds: stale
            )?.markAsLight == nil, "\(dev.name) never offers the mark entry")
        }

        // A Home Assistant auxiliary `switch.*` facet on the marked wall switch follows the mark.
        let auxSwitch = FacetControl(
            id: "switch.wall-aux", kind: .toggle, name: "on-power", title: "开关",
            serviceName: "switch", value: .bool(true), isWritable: true,
            writesByDefault: false, isHighValue: false,
            target: .haProperty(entityId: "switch.wall_aux")
        )
        #expect(ManualControlPolicy.facetRequiresConfirmation(auxSwitch, value: .bool(true), for: wall))
        #expect(!ManualControlPolicy.facetRequiresConfirmation(auxSwitch, value: .bool(true), for: wall, markedLightIds: marks))
    }

    @Test("Switch-light marks persist per device id and join the canonical-ID preference index (#104)")
    func switchLightMarksPersistAndSurviveMerge() throws {
        let suiteName = "test.switch-light-marks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wall = Self.wallSwitch(id: "canonical-wall")
        #expect(!SwitchLightMarks.isMarked(wall.id, defaults: defaults))
        #expect(ManualControlPolicy.requiresConfirmation(
            .power(true), for: wall, markedLightIds: SwitchLightMarks.load(defaults: defaults)
        ))

        var ids = SwitchLightMarks.load(defaults: defaults)
        ids.insert(wall.id)
        SwitchLightMarks.save(ids, defaults: defaults)
        #expect(SwitchLightMarks.load(defaults: defaults) == [wall.id])
        #expect(SwitchLightMarks.isMarked(wall.id, defaults: defaults))
        #expect(!ManualControlPolicy.requiresConfirmation(
            .power(true), for: wall, markedLightIds: SwitchLightMarks.load(defaults: defaults)
        ))

        // The canonical-ID chooser reads this index, so a dual-source source handoff keeps the mark.
        #expect(DevicePreferenceIndex.referencedIDs(defaults: defaults).contains(wall.id))
    }

    @Test("Marking a wall switch through the store stops its toggle confirmation entirely (#104)")
    @MainActor
    func storeMarkStopsTogglePrompt() async throws {
        let wall = Self.wallSwitch(id: "wall-e2e")
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [wall], scenes: []))
        let suiteName = "test.switch-light-store.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.controlDebounceInterval = .milliseconds(10)
        try await store.waitForTestSnapshot()
        let device = try #require(store.devices.first { $0.id == wall.id })

        var prompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            prompts.append(prompt)
            return true
        }

        // Before the mark the toggle asks, and the prompt offers the «this is a light» entry.
        _ = store.togglePrimary(device)
        await waitUntil { await provider.executedCommands.count == 1 }
        #expect(prompts.count == 1)
        #expect(prompts.first?.markAsLight?.deviceId == wall.id)

        // Marking through the store persists per device id; the next toggle runs directly.
        store.markSwitchAsLight(wall.id)
        #expect(store.isSwitchMarkedAsLight(wall.id))
        _ = store.togglePrimary(device)
        await waitUntil { await provider.executedCommands.count == 2 }
        #expect(prompts.count == 1, "the marked wall switch no longer asks")

        // Unmarking restores the confirmation.
        store.unmarkSwitchAsLight(wall.id)
        _ = store.togglePrimary(device)
        await waitUntil { await provider.executedCommands.count == 3 }
        #expect(prompts.count == 2)
    }

    /// Text inside 「」 or “”, the marks the hint uses around the word to add.
    private static func quotedKeywords(in text: String) -> [String] {
        let pattern = /[「“]([^」”]+)[」”]/
        return text.matches(of: pattern).map { String($0.output.1) }
    }
}
