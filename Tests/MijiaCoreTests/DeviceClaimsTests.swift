import Foundation
import Testing
@testable import MijiaCore

/// #26: the MIoT claim ladder, its device-type service aliases, its two claim conditions, the
/// appliance service list and the light-like fallback tokens moved into `Shared/deviceClaims.json`.
/// Windows imports the same file through `windows/src/core/miCloud/deviceClaims.ts`, and
/// `scripts/check_device_rules.py` keeps both ends' code tables aligned with the document. These
/// tests pin the macOS half of that contract and the behaviour the old hardcoded tables had.
struct DeviceClaimsTests {
    private func repoFile(_ relative: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func spec(_ deviceType: String, services: [MiotService] = []) -> MiotDeviceSpec {
        MiotDeviceSpec(type: "urn:miot-spec-v2:device:\(deviceType):0000A001:1", services: services)
    }

    private func service(_ shortName: String, properties: [(String, String)] = []) -> MiotService {
        MiotService(
            iid: 2,
            type: "urn:miot-spec-v2:service:\(shortName):00007800:1",
            properties: properties.enumerated().map { index, pair in
                MiotProperty(
                    iid: index + 1,
                    type: "urn:miot-spec-v2:property:\(pair.0):00000000:1",
                    format: pair.1,
                    access: ["read", "write"]
                )
            }
        )
    }

    @Test("Bundled deviceClaims.json loads and matches the shared document byte for byte")
    func bundledCopyMatchesSharedDocument() throws {
        let shared = try repoFile("Shared/deviceClaims.json")
        let bundled = try repoFile("Sources/MijiaCore/Resources/deviceClaims.json")
        #expect(shared == bundled)
        #expect(DeviceClaims.shared.schemaVersion == DeviceClaims.supportedSchemaVersion)
        #expect(DeviceClaims.shared.ladder.count == 45)
        // The two MIoT television rungs are Windows-only: macOS has no card builder for them.
        #expect(DeviceClaims.shared.macosLadder.count == 43)
    }

    @Test("The claim ladder is the shared order, filtered to the builders this platform has")
    func registryFollowsTheSharedLadder() {
        #expect(MiotSynthesizer.registry.map(\.service) == DeviceClaims.shared.macosLadder.map(\.service))
        #expect(!MiotSynthesizer.registry.contains { $0.service == "television" })
    }

    @Test("Device-type service aliases come from the document")
    func preferredServicesComeFromTheDocument() {
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "outlet") == ["outlet", "switch"])
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "camera") == ["camera-control", "video-doorbell"])
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "cateye") == ["camera-control", "video-doorbell"])
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "kettle") == ["kettle", "ble-kettle", "water-dispenser"])
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "stb") == ["stb", "television"])
        // A type the document does not alias claims its own name, as before.
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "fish-tank") == ["fish-tank"])
        // The appliance table still wins for a type it lists (#4).
        #expect(MiotSynthesizer.preferredServices(forDeviceType: "bath-heater") == ["ptc-bath-heater", "bath-heater"])
    }

    @Test("An electronic-valve only claims a card when it meters electric power (#265)")
    func breakerClaimNeedsAPowerMeter() {
        let shutOffValve = spec("electronic-valve", services: [service("electronic-valve", properties: [("on", "bool")])])
        #expect(!MiotSynthesizer.claims("electronic-valve", spec: shutOffValve))
        #expect(MiotSynthesizer.primary(for: shutOffValve) == nil)

        let breaker = spec(
            "electronic-valve",
            services: [
                service("electronic-valve", properties: [("on", "bool")]),
                service("power-consumption", properties: [("electric-power", "float")]),
            ]
        )
        #expect(MiotSynthesizer.claims("electronic-valve", spec: breaker))
        #expect(MiotSynthesizer.primary(for: breaker)?.0.shortName == "electronic-valve")
    }

    @Test("A water-heater service only claims its own device type (#300)")
    func waterHeaterClaimIsOwnTypeOnly() {
        let heater = spec("water-heater", services: [service("water-heater", properties: [("on", "bool")])])
        #expect(MiotSynthesizer.claims("water-heater", spec: heater))

        let other = spec("kettle", services: [service("water-heater", properties: [("on", "bool")])])
        #expect(!MiotSynthesizer.claims("water-heater", spec: other))
        #expect(MiotSynthesizer.primary(for: other) == nil)
    }

    @Test("The appliance service list comes from the document")
    func applianceServicesComeFromTheDocument() {
        #expect(MiotSynthesizer.applianceServiceNames == DeviceClaims.shared.applianceServices)
        #expect(MiotSynthesizer.applianceServiceNames.contains("cleanfly-dryer"))
    }

    @Test("On the last fallback rung a light service claims light-like types only (#296)")
    func lightFallbackTokensComeFromTheDocument() {
        #expect(MiotSynthesizer.fallbackAllows(deviceType: "night-light", service: "light"))
        #expect(MiotSynthesizer.fallbackAllows(deviceType: "ceiling-lamp", service: "light"))
        #expect(!MiotSynthesizer.fallbackAllows(deviceType: "hood", service: "light"))
        // The pair table in deviceProfiles.json still owns the non-token pairs.
        #expect(MiotSynthesizer.fallbackAllows(deviceType: "relay", service: "switch"))
        #expect(!MiotSynthesizer.fallbackAllows(deviceType: "relay", service: "outlet"))
    }
}
