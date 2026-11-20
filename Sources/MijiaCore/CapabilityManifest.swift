import Foundation

public enum CapabilityKind: String, CaseIterable, Codable, Hashable, Sendable { case connection, feature, deviceCategory }
public enum CapabilityStartupPolicy: String, CaseIterable, Codable, Hashable, Sendable { case whenConfigured, onDemand, backgroundWhenEnabled, readPlanWhenEnabled }
public enum CapabilityPlatform: String, CaseIterable, Codable, Hashable, Sendable { case macos, windows }
public enum CapabilitySupportStatus: String, CaseIterable, Codable, Hashable, Sendable { case supported, partial, unsupported }
public enum CapabilityMatrixCoverage: String, CaseIterable, Codable, Hashable, Sendable { case mapped, baselineUnlisted }

public enum ConnectionCapabilityID: String, CaseIterable, Codable, Hashable, Sendable {
    case xiaomiCloud = "xiaomi-cloud", homeAssistant = "home-assistant"
    public var homeBackend: HomeBackend {
        switch self {
        case .xiaomiCloud: .xiaomiCloud
        case .homeAssistant: .homeAssistant
        }
    }
}

public enum FeatureID: String, CaseIterable, Codable, Hashable, Sendable {
    case voiceInput = "voice-input", aiAssistant = "ai-assistant"
    case proactiveSuggestions = "proactive-suggestions", companionIntegration = "companion-integration"
    case eventAutomation = "event-automation", grokball = "grokball"
    case sensorHistory = "sensor-history", plugEnergy = "plug-energy", cameraLive = "camera-live"
}

public enum DeviceCategoryID: String, CaseIterable, Codable, Hashable, Sendable {
    case light = "light", plug = "plug", climate = "climate", fan = "fan", cover = "cover"
    case appliance = "appliance", fridge = "fridge", vacuum = "vacuum", speaker = "speaker", tv = "tv"
    case camera = "camera", sensor = "sensor", valve = "valve", generic = "generic"

    public static let baselineUnlistedIDs: Set<DeviceCategoryID> = [.light, .vacuum, .tv]
    public var primaryListCutTag: DeviceKindTag {
        switch self {
        case .light: .light; case .plug, .valve: .plug; case .climate: .climate; case .fan: .fan
        case .cover: .cover; case .appliance: .appliance; case .fridge: .fridge; case .vacuum: .vacuum
        case .speaker: .speaker; case .tv: .tv; case .camera: .camera; case .sensor: .sensor; case .generic: .generic
        }
    }
}

/// Device-type selection presets shared with Windows (`DEVICE_CATEGORY_PRESETS`, P3c-M / P4b-M).
/// Both platforms read `Tests/Fixtures/capability_selection_golden.json` (`deviceTypeMapping.presets`)
/// to keep preset IDs and category membership identical.
public enum DeviceCategoryPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case allSupportedTypes
    /// 「只用灯和开关」. A wall switch driving a lamp is drawn as a `.plug` card, so the preset keeps both.
    case lightAndSwitch

    public var categories: [DeviceCategoryID] {
        switch self {
        case .allSupportedTypes: DeviceCategoryID.allCases
        case .lightAndSwitch: [.light, .plug]
        }
    }

    public var categorySet: Set<DeviceCategoryID> { Set(categories) }
}

public enum CapabilityID: Hashable, Sendable, CaseIterable {
    case connection(ConnectionCapabilityID), feature(FeatureID), deviceCategory(DeviceCategoryID)
    public static var allCases: [CapabilityID] {
        ConnectionCapabilityID.allCases.map(Self.connection) + FeatureID.allCases.map(Self.feature) + DeviceCategoryID.allCases.map(Self.deviceCategory)
    }
    public var rawValue: String {
        switch self { case .connection(let id): id.rawValue; case .feature(let id): id.rawValue; case .deviceCategory(let id): id.rawValue }
    }
    public var expectedKind: CapabilityKind {
        switch self { case .connection: .connection; case .feature: .feature; case .deviceCategory: .deviceCategory }
    }
    public init?(rawValue: String) {
        if let id = ConnectionCapabilityID(rawValue: rawValue) { self = .connection(id) }
        else if let id = FeatureID(rawValue: rawValue) { self = .feature(id) }
        else if let id = DeviceCategoryID(rawValue: rawValue) { self = .deviceCategory(id) }
        else { return nil }
    }
}

extension HomeBackend {
    public var connectionCapabilityID: ConnectionCapabilityID? {
        switch self { case .xiaomiCloud: .xiaomiCloud; case .homeAssistant: .homeAssistant; case .demo: nil }
    }
}

extension DeviceKind {
    public var capabilityCategoryID: DeviceCategoryID {
        switch self {
        case .light: .light; case .plug: .plug; case .climate: .climate; case .fan, .humidifier: .fan
        case .cover: .cover; case .appliance: .appliance; case .fridge: .fridge; case .vacuum: .vacuum
        case .speaker: .speaker; case .tv: .tv; case .camera: .camera; case .sensor: .sensor
        case .valve: .valve; case .generic: .generic
        }
    }
}

extension SmartDevice { public var capabilityCategoryID: DeviceCategoryID { kind.capabilityCategoryID } }

public struct CapabilityPlatformAvailability: Codable, Equatable, Sendable {
    public let macos: CapabilitySupportStatus, windows: CapabilitySupportStatus
    public func status(for platform: CapabilityPlatform) -> CapabilitySupportStatus { platform == .macos ? macos : windows }
}

public struct CapabilityMatrixMapping: Codable, Equatable, Sendable {
    public let coverage: CapabilityMatrixCoverage, rowIds: [String]
}

public struct CapabilityManifestEntry: Equatable, Sendable {
    public let id: CapabilityID, kind: CapabilityKind, dependsOn: [CapabilityID]
    public let defaultOnFreshInstall: Bool, startupPolicy: CapabilityStartupPolicy
    public let platforms: CapabilityPlatformAvailability, capabilityMatrix: CapabilityMatrixMapping
}

public enum CapabilityManifestError: Error, Equatable, Sendable {
    case invalidJSONStructure(String), unsupportedSchemaVersion(Int), unexpectedKeys(scope: String, keys: [String])
    case unknownCapabilityID(String), duplicateCapabilityID(String)
    case kindMismatch(id: CapabilityID, expected: CapabilityKind, actual: CapabilityKind)
    case missingCapabilities([CapabilityID]), duplicateDependency(id: CapabilityID, dependency: CapabilityID)
    case dependencyCycle([CapabilityID])
    case unsupportedDependencyPlatform(id: CapabilityID, dependency: CapabilityID, platform: CapabilityPlatform)
    case invalidDefaultDependency(id: CapabilityID, dependency: CapabilityID), invalidMatrixMapping(String)
}

public struct CapabilityManifest: Equatable, Sendable {
    private struct RawRoot: Decodable {
        struct RawEntry: Decodable {
            let id: String, kind: CapabilityKind, dependsOn: [String], defaultOnFreshInstall: Bool
            let startupPolicy: CapabilityStartupPolicy, platforms: CapabilityPlatformAvailability, capabilityMatrix: CapabilityMatrixMapping
        }
        let schemaVersion: Int, hostCoreCapabilityMatrixIds: [String], capabilities: [RawEntry]
    }

    public static let supportedSchemaVersion = 1
    public let schemaVersion: Int, hostCoreCapabilityMatrixIds: [String], entries: [CapabilityManifestEntry]
    private let byID: [CapabilityID: CapabilityManifestEntry]
    public func entry(for id: CapabilityID) -> CapabilityManifestEntry { byID[id]! }

    public static func parse(from data: Data) throws -> CapabilityManifest {
        try validateRawKeys(from: data)
        let decoded: RawRoot
        do { decoded = try JSONDecoder().decode(RawRoot.self, from: data) }
        catch { throw CapabilityManifestError.invalidJSONStructure(error.localizedDescription) }
        guard decoded.schemaVersion == supportedSchemaVersion else {
            throw CapabilityManifestError.unsupportedSchemaVersion(decoded.schemaVersion)
        }
        if decoded.hostCoreCapabilityMatrixIds.contains(where: \.isEmpty) || Set(decoded.hostCoreCapabilityMatrixIds).count != decoded.hostCoreCapabilityMatrixIds.count {
            throw CapabilityManifestError.invalidMatrixMapping("invalid hostCoreCapabilityMatrixIds")
        }

        var entries: [CapabilityManifestEntry] = [], byID: [CapabilityID: CapabilityManifestEntry] = [:]
        var seenRawIDs: Set<String> = [], optionalMatrixIds: Set<String> = []
        for raw in decoded.capabilities {
            if !seenRawIDs.insert(raw.id).inserted { throw CapabilityManifestError.duplicateCapabilityID(raw.id) }
            guard let id = CapabilityID(rawValue: raw.id) else { throw CapabilityManifestError.unknownCapabilityID(raw.id) }
            if raw.kind != id.expectedKind { throw CapabilityManifestError.kindMismatch(id: id, expected: id.expectedKind, actual: raw.kind) }
            var deps: [CapabilityID] = [], seenDeps: Set<CapabilityID> = []
            for rawDep in raw.dependsOn {
                guard let depID = CapabilityID(rawValue: rawDep) else { throw CapabilityManifestError.unknownCapabilityID(rawDep) }
                if !seenDeps.insert(depID).inserted { throw CapabilityManifestError.duplicateDependency(id: id, dependency: depID) }
                deps.append(depID)
            }
            try validateMatrix(raw.capabilityMatrix, id: id, rawID: raw.id)
            optionalMatrixIds.formUnion(raw.capabilityMatrix.rowIds)
            let entry = CapabilityManifestEntry(
                id: id, kind: raw.kind, dependsOn: deps, defaultOnFreshInstall: raw.defaultOnFreshInstall,
                startupPolicy: raw.startupPolicy, platforms: raw.platforms, capabilityMatrix: raw.capabilityMatrix
            )
            entries.append(entry); byID[id] = entry
        }

        let missing = CapabilityID.allCases.filter { byID[$0] == nil }
        if !missing.isEmpty { throw CapabilityManifestError.missingCapabilities(missing) }
        if !Set(decoded.hostCoreCapabilityMatrixIds).isDisjoint(with: optionalMatrixIds) {
            throw CapabilityManifestError.invalidMatrixMapping("hostCoreCapabilityMatrixIds overlaps optional rowIds")
        }
        try validateGraph(entries: entries, byID: byID)
        return CapabilityManifest(schemaVersion: decoded.schemaVersion, hostCoreCapabilityMatrixIds: decoded.hostCoreCapabilityMatrixIds, entries: entries, byID: byID)
    }

    private static func validateRawKeys(from data: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CapabilityManifestError.invalidJSONStructure("root must be a JSON object")
        }
        try checkKeys(root, allowed: ["schemaVersion", "hostCoreCapabilityMatrixIds", "capabilities"], scope: "root")
        let entryAllowed: Set<String> = ["id", "kind", "dependsOn", "defaultOnFreshInstall", "startupPolicy", "platforms", "capabilityMatrix"]
        for (i, item) in ((root["capabilities"] as? [Any]) ?? []).enumerated() {
            guard let obj = item as? [String: Any] else { continue }
            try checkKeys(obj, allowed: entryAllowed, scope: "capabilities[\(i)]")
            let rawID = (obj["id"] as? String) ?? "capabilities[\(i)]"
            if let p = obj["platforms"] as? [String: Any] { try checkKeys(p, allowed: ["macos", "windows"], scope: "\(rawID).platforms") }
            if let m = obj["capabilityMatrix"] as? [String: Any] { try checkKeys(m, allowed: ["coverage", "rowIds"], scope: "\(rawID).capabilityMatrix") }
        }
    }

    private static func checkKeys(_ dict: [String: Any], allowed: Set<String>, scope: String) throws {
        let extra = Set(dict.keys).subtracting(allowed).sorted()
        if !extra.isEmpty { throw CapabilityManifestError.unexpectedKeys(scope: scope, keys: extra) }
    }

    private static func validateMatrix(_ matrix: CapabilityMatrixMapping, id: CapabilityID, rawID: String) throws {
        if matrix.rowIds.contains(where: \.isEmpty) || Set(matrix.rowIds).count != matrix.rowIds.count {
            throw CapabilityManifestError.invalidMatrixMapping("\(rawID) invalid rowIds")
        }
        if matrix.coverage == .mapped, matrix.rowIds.isEmpty { throw CapabilityManifestError.invalidMatrixMapping("\(rawID) mapped rowIds empty") }
        if matrix.coverage == .baselineUnlisted {
            guard case .deviceCategory(let cat) = id, DeviceCategoryID.baselineUnlistedIDs.contains(cat), matrix.rowIds.isEmpty else {
                throw CapabilityManifestError.invalidMatrixMapping("\(rawID) invalid baselineUnlisted")
            }
        }
    }

    private static func validateGraph(entries: [CapabilityManifestEntry], byID: [CapabilityID: CapabilityManifestEntry]) throws {
        var states: [CapabilityID: Bool] = [:], stack: [CapabilityID] = []
        func dfs(_ id: CapabilityID) throws {
            states[id] = false; stack.append(id)
            let entry = byID[id]!
            for dep in entry.dependsOn {
                guard let depEntry = byID[dep] else { throw CapabilityManifestError.unknownCapabilityID(dep.rawValue) }
                if let done = states[dep] {
                    if !done { throw CapabilityManifestError.dependencyCycle(Array(stack[(stack.firstIndex(of: dep) ?? 0)...]) + [dep]) }
                } else { try dfs(dep) }
                for platform in CapabilityPlatform.allCases
                where entry.platforms.status(for: platform) != .unsupported && depEntry.platforms.status(for: platform) == .unsupported {
                    throw CapabilityManifestError.unsupportedDependencyPlatform(id: id, dependency: dep, platform: platform)
                }
                if entry.defaultOnFreshInstall && !depEntry.defaultOnFreshInstall {
                    throw CapabilityManifestError.invalidDefaultDependency(id: id, dependency: dep)
                }
            }
            stack.removeLast(); states[id] = true
        }
        for entry in entries where states[entry.id] == nil { try dfs(entry.id) }
    }
}
