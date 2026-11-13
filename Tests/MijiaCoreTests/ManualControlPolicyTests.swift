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

    @Test("The bundled deviceProfiles.json carries the manual-control table (#26)")
    func bundledRulesMatchDocument() throws {
        let data = try #require(DeviceProfiles.bundledData())
        let profiles = try DeviceProfiles.decode(data)
        let rules = try #require(profiles.manualControlPolicy)

        #expect(ManualControlPolicy.currentRules == rules)
        #expect(DeviceProfiles.ManualControlRules.defaults == rules)
        #expect(rules.heatingService.contains("floor-heat"))
        #expect(rules.lowRiskServices.contains("buzzer"))
        #expect(rules.lowRiskTokens.contains("display"))
        #expect(profiles.facets.lowRiskWrites.contains("target-humidity"))
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

    @Test("inferFallbackSpec is the shared table, and unknown models still return nil (#26)")
    func fallbackDelegatesToSharedTable() throws {
        for model in ["yunmi.kettle.v1", "loock.lock.v1", "lumi.sensor_magnet", "dmaker.fan.fallback"] {
            #expect(
                MiotDeviceSpec.inferFallbackSpec(model: model)
                    == MiotFallbackSpec.infer(model: model, name: ""),
                "\(model)"
            )
        }
        #expect(MiotDeviceSpec.inferFallbackSpec(model: "vendor.unknown.1") == nil)

        let kettle = try #require(MiotDeviceSpec.inferFallbackSpec(model: "yunmi.kettle.v1"))
        #expect(kettle.shortName == "kettle")
        #expect(kettle.services.flatMap(\.properties).allSatisfy { $0.access == ["read"] })

        let lock = try #require(MiotDeviceSpec.inferFallbackSpec(model: "loock.lock.v1"))
        #expect(lock.services(named: "battery").first?.properties.first?.shortName == "battery-level")
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
            makePlug(id: "sw_lighting", name: "厨房照明", model: "090615.switch.09dh1")
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
}
