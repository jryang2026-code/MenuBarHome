import Foundation

/// `Shared/deviceClaims.json` (#26): which MIoT service may claim a card, in which order, and under
/// which conditions. macOS ships a byte-identical copy in `Resources/`; Windows imports the same
/// file through `windows/src/core/miCloud/deviceClaims.ts`, so the two ladders cannot drift again
/// (`television`/`stb` used to exist on Windows only).
///
/// The document carries choices, never computation: the claim order, the device-type aliases, two
/// closed claim conditions, the appliance service list and the light-like fallback tokens. What a
/// claimed service renders as stays code on each end (`MiotSynthesizer.builders` here, the builder
/// switch on Windows) — a ladder rung whose family has no renderer is skipped, which is why a rung
/// can name `renderers`. `scripts/check_device_rules.py` pins that gap to a budget.
public struct DeviceClaims: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    static let macPlatform = "macos"
    static let windowsPlatform = "windows"
    static let allPlatforms = [macPlatform, windowsPlatform]

    /// The closed claim conditions: nothing here evaluates an expression, and a new kind of
    /// condition needs a code change on both ends (ADR-0023's closed-data rule).
    public struct Condition: Decodable, Equatable, Sendable {
        /// The spec must publish `property` on `service`. A mains breaker meters electric power
        /// (#265); a water or gas shut-off valve uses the same service and stays unsupported.
        public struct ServiceProperty: Decodable, Equatable, Sendable {
            public let service: String
            public let property: String
        }

        public let serviceHasProperty: ServiceProperty?
        /// Only a device whose own type is this service may claim it (#300): a `water-heater`
        /// service belongs to a water heater rather than claiming another device.
        public let deviceTypeIsService: Bool?
    }

    public struct LadderEntry: Decodable, Equatable, Sendable {
        public let service: String
        public let claimableWhen: Condition?
        /// The platforms whose builder list renders this claim. Absent means both; a rung that
        /// only one end can draw names the other end explicitly instead of leaving it to drift.
        public let renderers: [String]?
    }

    /// A service that may claim a device type whose own name contains one of the tokens, used by
    /// the last fallback rung (#296): a `light` service may claim light-like types only.
    public struct FallbackTokens: Decodable, Equatable, Sendable {
        public let service: String
        public let tokens: [String]
    }

    public let schemaVersion: Int
    /// Device type → the services that count as its own primary service (an outlet's `switch`, a
    /// camera's `camera-control`). A type the document does not list claims its own name.
    public let preferredServices: [String: [String]]
    /// Claim order, most specific first: the first rung whose service the spec publishes wins. A
    /// device type's own services are tried before this ladder, and the fallback table
    /// (`deviceProfiles.json`'s `fallbackClaims`) gates the last rung.
    public let ladder: [LadderEntry]
    /// Services one appliance card merges, in read order (#300).
    public let applianceServices: [String]
    public let fallbackTypeTokens: [FallbackTokens]

    public static let shared: DeviceClaims = {
        guard let data = bundledData(), let claims = try? JSONDecoder().decode(DeviceClaims.self, from: data) else {
            preconditionFailure("deviceClaims.json is missing from the MijiaCore bundle")
        }
        guard claims.schemaVersion == supportedSchemaVersion else {
            preconditionFailure("deviceClaims.json schemaVersion \(claims.schemaVersion) is not \(supportedSchemaVersion)")
        }
        return claims
    }()

    /// The rungs this platform renders, in claim order.
    public var macosLadder: [LadderEntry] {
        ladder.filter { ($0.renderers ?? Self.allPlatforms).contains(Self.macPlatform) }
    }

    /// Services that count as this device type's own primary service.
    public func preferredServices(forDeviceType deviceType: String) -> [String] {
        preferredServices[deviceType] ?? [deviceType]
    }

    /// Whether `service` may claim `spec`. A rung the document does not list is a code-side
    /// service with no condition, which keeps a caller from silently losing a card.
    public func allows(_ service: String, spec: MiotDeviceSpec) -> Bool {
        guard let entry = ladder.first(where: { $0.service == service }),
              let condition = entry.claimableWhen else { return true }
        if let rule = condition.serviceHasProperty {
            let published = spec.services(named: rule.service).contains { $0.property(named: rule.property) != nil }
            if !published { return false }
        }
        if condition.deviceTypeIsService == true, spec.shortName != service { return false }
        return true
    }

    /// The device-type tokens that let `service` claim a type whose own name contains one.
    public func fallbackTokens(for service: String) -> [String] {
        fallbackTypeTokens.first { $0.service == service }?.tokens ?? []
    }

    /// Bytes of the bundled document, so a test can prove it matches `Shared/deviceClaims.json`.
    /// Resolved through runtime bundle paths only: a compile-time source-location fallback would
    /// write the build machine's checkout into the release binary, which `scripts/build_app.sh`
    /// rejects (#275).
    static func bundledData() -> Data? {
        var urls: [URL] = []
        #if !os(macOS)
        if let url = Bundle.module.url(forResource: "deviceClaims", withExtension: "json", subdirectory: "Resources") {
            urls.append(url)
        }
        if let url = Bundle.module.url(forResource: "deviceClaims", withExtension: "json") {
            urls.append(url)
        }
        if let root = Bundle.module.resourceURL {
            urls.append(root.appendingPathComponent("Resources/deviceClaims.json"))
            urls.append(root.appendingPathComponent("deviceClaims.json"))
        }
        #endif
        for base in L10n.translationSearchBases {
            urls.append(base.appendingPathComponent("Resources/deviceClaims.json"))
            urls.append(base.appendingPathComponent("deviceClaims.json"))
            for name in L10n.resourceDirectoryNames(in: base) {
                let bundle = base.appendingPathComponent(name)
                urls.append(bundle.appendingPathComponent("Resources/deviceClaims.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/Resources/deviceClaims.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/deviceClaims.json"))
                urls.append(bundle.appendingPathComponent("deviceClaims.json"))
            }
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }
}
