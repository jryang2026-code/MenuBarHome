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
}
