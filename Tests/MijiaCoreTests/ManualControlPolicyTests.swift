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

        let hintMark = "加上「灯」"
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
                    #expect(keywords == ["燈"])
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

    /// Text inside 「」 or “”, the marks the hint uses around the word to add.
    private static func quotedKeywords(in text: String) -> [String] {
        let pattern = /[「“]([^」”]+)[」”]/
        return text.matches(of: pattern).map { String($0.output.1) }
    }
}
