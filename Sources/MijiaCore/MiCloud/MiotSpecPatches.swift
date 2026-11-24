import Foundation

/// `Shared/specPatches.json`: per-model declarative MIoT spec overrides (hide broken properties,
/// override property `access`, `unit`, `valueRange`, `valueList`, and `description`).
/// macOS ships a byte-identical copy in `Sources/MijiaCore/Resources/specPatches.json`;
/// Windows imports the same file through `windows/src/core/miCloud/specPatches.ts`.
public struct MiotSpecPatches: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public struct PropertyRef: Decodable, Equatable, Hashable, Sendable {
        public let siid: Int
        public let piid: Int

        public init(siid: Int, piid: Int) {
            self.siid = siid
            self.piid = piid
        }
    }

    public struct PropertyOverride: Decodable, Equatable, Sendable {
        public let siid: Int
        public let piid: Int
        public let access: [String]?
        public let unit: String?
        public let valueRange: [Double]?
        public let valueList: [MiotValueListItem]?
        public let description: String?
        public let note: String?

        public init(
            siid: Int,
            piid: Int,
            access: [String]? = nil,
            unit: String? = nil,
            valueRange: [Double]? = nil,
            valueList: [MiotValueListItem]? = nil,
            description: String? = nil,
            note: String? = nil
        ) {
            self.siid = siid
            self.piid = piid
            self.access = access
            self.unit = unit
            self.valueRange = valueRange
            self.valueList = valueList
            self.description = description
            self.note = note
        }
    }

    public struct ModelPatch: Decodable, Equatable, Sendable {
        public let hideProperties: [PropertyRef]?
        public let properties: [PropertyOverride]?
        public let note: String?

        public init(
            hideProperties: [PropertyRef]? = nil,
            properties: [PropertyOverride]? = nil,
            note: String? = nil
        ) {
            self.hideProperties = hideProperties
            self.properties = properties
            self.note = note
        }
    }

    public let schemaVersion: Int
    public let models: [String: ModelPatch]

    public init(schemaVersion: Int = MiotSpecPatches.supportedSchemaVersion, models: [String: ModelPatch] = [:]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }

    public static let shared: MiotSpecPatches = {
        guard let data = bundledData(), let patches = try? JSONDecoder().decode(MiotSpecPatches.self, from: data) else {
            preconditionFailure("specPatches.json is missing from the MijiaCore bundle")
        }
        guard patches.schemaVersion == supportedSchemaVersion else {
            preconditionFailure("specPatches.json schemaVersion \(patches.schemaVersion) is not \(supportedSchemaVersion)")
        }
        return patches
    }()

    /// Apply any model-specific patch to `spec`. Pure and idempotent.
    public func apply(to spec: MiotDeviceSpec, model: String) -> MiotDeviceSpec {
        guard let patch = models[model] else { return spec }
        let hidden = Set(patch.hideProperties ?? [])
        var overridesByRef: [PropertyRef: PropertyOverride] = [:]
        for item in patch.properties ?? [] {
            overridesByRef[PropertyRef(siid: item.siid, piid: item.piid)] = item
        }
        if hidden.isEmpty && overridesByRef.isEmpty { return spec }

        var patched = spec
        patched.services = spec.services.map { service in
            var updatedService = service
            updatedService.properties = service.properties.compactMap { prop in
                let ref = PropertyRef(siid: service.iid, piid: prop.iid)
                if hidden.contains(ref) { return nil }
                guard let override = overridesByRef[ref] else { return prop }
                var updatedProp = prop
                if let access = override.access { updatedProp.access = access }
                if let unit = override.unit { updatedProp.unit = unit }
                if let valueRange = override.valueRange { updatedProp.valueRange = valueRange }
                if let valueList = override.valueList { updatedProp.valueList = valueList }
                if let description = override.description { updatedProp.description = description }
                return updatedProp
            }
            return updatedService
        }
        return patched
    }

    /// Bytes of the bundled document, so a test can prove it matches `Shared/specPatches.json`.
    static func bundledData() -> Data? {
        var urls: [URL] = []
        #if !os(macOS)
        if let url = Bundle.module.url(forResource: "specPatches", withExtension: "json", subdirectory: "Resources") {
            urls.append(url)
        }
        if let url = Bundle.module.url(forResource: "specPatches", withExtension: "json") {
            urls.append(url)
        }
        if let root = Bundle.module.resourceURL {
            urls.append(root.appendingPathComponent("Resources/specPatches.json"))
            urls.append(root.appendingPathComponent("specPatches.json"))
        }
        #endif
        for base in L10n.translationSearchBases {
            urls.append(base.appendingPathComponent("Resources/specPatches.json"))
            urls.append(base.appendingPathComponent("specPatches.json"))
            for name in L10n.resourceDirectoryNames(in: base) {
                let bundle = base.appendingPathComponent(name)
                urls.append(bundle.appendingPathComponent("Resources/specPatches.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/Resources/specPatches.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/specPatches.json"))
                urls.append(bundle.appendingPathComponent("specPatches.json"))
            }
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }
}
