import Foundation
import os

// MARK: - MIoT Spec Model (miot-spec.org instance JSON)

/// Segment 3 of a MIoT URN (`urn:miot-spec-v2:property:brightness:0000000D:...` → `brightness`).
func miotShortName(_ urn: String) -> String {
    let parts = urn.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count > 3 ? String(parts[3]) : urn
}

public struct MiotValueListItem: Codable, Equatable, Sendable {
    public var value: Int
    public var description: String

    public init(value: Int, description: String) {
        self.value = value
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .value) {
            value = i
        } else {
            let number = try c.decode(Double.self, forKey: .value)
            guard let i = Int(exactly: number.rounded(.towardZero)) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: c,
                    debugDescription: "value-list value is outside the supported integer range"
                )
            }
            value = i
        }
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }
}

public struct MiotProperty: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?
    public var format: String
    public var access: [String]
    public var valueRange: [Double]?
    public var valueList: [MiotValueListItem]?
    public var unit: String?
    public var comment: String?

    enum CodingKeys: String, CodingKey {
        case iid, type, description, format, access, unit, comment
        case valueRange = "value-range"
        case valueList = "value-list"
    }

    public init(
        iid: Int, type: String, description: String? = nil, format: String, access: [String],
        valueRange: [Double]? = nil, valueList: [MiotValueListItem]? = nil, unit: String? = nil,
        comment: String? = nil
    ) {
        self.iid = iid
        self.type = type
        self.description = description
        self.format = format
        self.access = access
        self.valueRange = valueRange
        self.valueList = valueList
        self.unit = unit
        self.comment = comment
    }

    /// The bundled fallback table writes `valueRange` / `valueList`, the cloud writes the kebab
    /// case; Windows accepts both, so this decoder does too (#26).
    private enum CamelCaseKeys: String, CodingKey {
        case valueRange
        case valueList
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try? c.decode(String.self, forKey: .description)
        format = (try? c.decode(String.self, forKey: .format)) ?? "string"
        access = (try? c.decode([String].self, forKey: .access)) ?? []
        let camel = try? decoder.container(keyedBy: CamelCaseKeys.self)
        valueRange = (try? c.decode([Double].self, forKey: .valueRange))
            ?? (try? camel?.decode([Double].self, forKey: .valueRange)) ?? nil
        valueList = (try? c.decode([MiotValueListItem].self, forKey: .valueList))
            ?? (try? camel?.decode([MiotValueListItem].self, forKey: .valueList)) ?? nil
        unit = try? c.decode(String.self, forKey: .unit)
        comment = try? c.decode(String.self, forKey: .comment)
    }

    public var shortName: String { miotShortName(type) }
    public var isReadable: Bool { access.contains("read") }
    public var isWritable: Bool { access.contains("write") }
    public var rangeMin: Double? { valueRange.flatMap { $0.count >= 2 ? $0[0] : nil } }
    public var rangeMax: Double? { valueRange.flatMap { $0.count >= 2 ? $0[1] : nil } }
    public var rangeStep: Double? { valueRange.flatMap { $0.count >= 3 ? $0[2] : nil } }
    public var isIntegerFormat: Bool { format.hasPrefix("int") || format.hasPrefix("uint") }

    public func description(forValue v: Int) -> String? {
        valueList?.first { $0.value == v }?.description
    }
}

public struct MiotAction: Codable, Equatable, Sendable {
    public var inputProperties: [Int]
    enum CodingKeys: String, CodingKey { case iid, type, description; case inputProperties = "in" }
    public var iid: Int
    public var type: String
    public var description: String?

    public init(iid: Int, type: String, description: String? = nil, inputProperties: [Int] = []) {
        self.inputProperties = inputProperties
        self.iid = iid
        self.type = type
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        inputProperties = try c.decodeIfPresent([Int].self, forKey: .inputProperties) ?? []
    }

    public var shortName: String { miotShortName(type) }
}

public struct MiotEvent: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?
    public var arguments: [Int]

    enum CodingKeys: String, CodingKey { case iid, type, description, arguments }

    public init(iid: Int, type: String, description: String? = nil, arguments: [Int] = []) {
        self.iid = iid
        self.type = type
        self.description = description
        self.arguments = arguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        arguments = try c.decodeIfPresent([Int].self, forKey: .arguments) ?? []
    }

    public var shortName: String { miotShortName(type) }
}

public struct MiotService: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?
    public var properties: [MiotProperty]
    public var actions: [MiotAction]
    public var events: [MiotEvent]

    enum CodingKeys: String, CodingKey { case iid, type, description, properties, actions, events }

    public init(
        iid: Int,
        type: String,
        description: String? = nil,
        properties: [MiotProperty] = [],
        actions: [MiotAction] = [],
        events: [MiotEvent] = []
    ) {
        self.iid = iid
        self.type = type
        self.description = description
        self.properties = properties
        self.actions = actions
        self.events = events
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try? c.decode(String.self, forKey: .description)
        properties = (try? c.decode([MiotProperty].self, forKey: .properties)) ?? []
        actions = (try? c.decode([MiotAction].self, forKey: .actions)) ?? []
        events = (try? c.decode([MiotEvent].self, forKey: .events)) ?? []
    }

    public var shortName: String { miotShortName(type) }

    public func property(named name: String) -> MiotProperty? {
        properties.first { $0.shortName == name }
    }

    public func action(named name: String) -> MiotAction? {
        actions.first { $0.shortName == name }
    }

    public func event(named name: String) -> MiotEvent? {
        events.first { $0.shortName == name }
    }
}

public struct MiotDeviceSpec: Codable, Equatable, Sendable {
    public var type: String
    public var description: String?
    public var services: [MiotService]

    public init(type: String, description: String? = nil, services: [MiotService]) {
        self.type = type
        self.description = description
        self.services = services
    }

    public var shortName: String { miotShortName(type) }

    public func service(iid: Int) -> MiotService? {
        services.first { $0.iid == iid }
    }

    public func services(named name: String) -> [MiotService] {
        services.filter { $0.shortName == name }
    }

    /// Fallback spec for legacy Xiaomi models whose miot-spec.org instance remains in `debug`
    /// status (e.g. `yunmi.kettle.v1`) and is omitted from the `status=released` index.
    /// The table lives in `Resources/fallbackSpecs.json`, shared byte-for-byte with Windows, and
    /// every guessed property stays read-only (#154, #26).
    public static func inferFallbackSpec(model: String) -> MiotDeviceSpec? {
        guard MiotFallbackSpec.inferMatchingRule(model: model) else { return nil }
        return MiotFallbackSpec.spec(for: model)
    }
}

// MARK: - Spec Source & Disk-Cached Store

public protocol MiotSpecSource: Sendable {
    /// `specType` is the URN the cloud device list sometimes includes; when absent the model is looked up.
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec?
}

public actor MiotSpecStore: MiotSpecSource {
    public static let defaultMirrorBaseURLs: [URL] = [
        URL(string: "https://miot-spec.org")!,
        URL(string: "https://spec.miot-spec.com")!,
    ]

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiotSpec")
    private let transport: any MiHTTPTransport
    private let cacheDirectory: URL
    private let indexMaxAge: TimeInterval
    private let specMaxAge: TimeInterval
    private let ttlJitterFraction: Double
    private let mirrorBaseURLs: [URL]
    private let now: @Sendable () -> Date
    private let jitterRandom: @Sendable () -> Double

    private var typeByModel: [String: String]?
    private var indexTask: Task<[String: String], any Error>?
    private var specByType: [String: MiotDeviceSpec] = [:]
    private var jitteredTTLByKey: [String: TimeInterval] = [:]

    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarMijia", isDirectory: true)
    }

    public init(
        transport: any MiHTTPTransport = URLSessionMiTransport(timeout: 60),
        cacheDirectory: URL = MiotSpecStore.defaultCacheDirectory,
        indexMaxAge: TimeInterval = 7 * 24 * 3600,
        specMaxAge: TimeInterval = 30 * 24 * 3600,
        ttlJitterFraction: Double = 0.15,
        mirrorBaseURLs: [URL] = MiotSpecStore.defaultMirrorBaseURLs,
        now: @escaping @Sendable () -> Date = { Date() },
        jitterRandom: @escaping @Sendable () -> Double = { Double.random(in: -1.0...1.0) }
    ) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.indexMaxAge = indexMaxAge
        self.specMaxAge = specMaxAge
        self.ttlJitterFraction = ttlJitterFraction
        self.mirrorBaseURLs = mirrorBaseURLs.isEmpty ? Self.defaultMirrorBaseURLs : mirrorBaseURLs
        self.now = now
        self.jitterRandom = jitterRandom
    }

    public func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        let type: String
        if let specType, !specType.isEmpty {
            type = specType
        } else if let found = try await typeIndex()[model] {
            type = found
        } else {
            return MiotDeviceSpec.inferFallbackSpec(model: model)
        }
        if let loaded = try? await instance(type: type) {
            return loaded
        }
        return MiotDeviceSpec.inferFallbackSpec(model: model)
    }

    /// Prefetches MIoT specs for multiple models concurrently with a bounded `TaskGroup`.
    public func getSpecs(for models: [String], maxConcurrency: Int = 6) async -> [String: MiotDeviceSpec] {
        var seen: Set<String> = []
        let uniqueModels = models.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !uniqueModels.isEmpty else { return [:] }
        _ = try? await typeIndex()
        let limit = max(1, maxConcurrency)
        return await withTaskGroup(of: (String, MiotDeviceSpec?).self) { group in
            var iterator = uniqueModels.makeIterator()
            for _ in 0..<min(limit, uniqueModels.count) {
                if let model = iterator.next() {
                    group.addTask {
                        let loaded = try? await self.spec(model: model, specType: nil)
                        return (model, loaded)
                    }
                }
            }
            var results: [String: MiotDeviceSpec] = [:]
            for await (model, loaded) in group {
                if let loaded {
                    results[model] = loaded
                }
                if let nextModel = iterator.next() {
                    group.addTask {
                        let nextLoaded = try? await self.spec(model: nextModel, specType: nil)
                        return (nextModel, nextLoaded)
                    }
                }
            }
            return results
        }
    }

    func effectiveTTL(forKey cacheKey: String, base: TimeInterval) -> TimeInterval {
        guard base > 0 else { return 0 }
        if let cached = jitteredTTLByKey[cacheKey] { return cached }
        let clampedFraction = min(0.5, max(0.0, ttlJitterFraction))
        let delta = clampedFraction > 0 ? max(-1.0, min(1.0, jitterRandom())) * clampedFraction : 0.0
        let ttl = max(1.0, base * (1.0 + delta))
        jitteredTTLByKey[cacheKey] = ttl
        return ttl
    }

    private func isFreshCacheFile(_ file: URL, cacheKey: String, baseMaxAge: TimeInterval) -> Bool {
        let ttl = effectiveTTL(forKey: cacheKey, base: baseMaxAge)
        guard ttl > 0 else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }
        let age = now().timeIntervalSince(modified)
        return age >= 0 && age < ttl
    }

    private func typeIndex() async throws -> [String: String] {
        if let typeByModel { return typeByModel }
        // Actor reentrancy: concurrent spec lookups would otherwise each download the 2 MB index.
        if let indexTask { return try await indexTask.value }
        let task = Task { try await self.loadTypeIndex() }
        indexTask = task
        do {
            let index = try await task.value
            typeByModel = index
            return index
        } catch {
            indexTask = nil
            throw error
        }
    }

    private func loadTypeIndex() async throws -> [String: String] {
        let file = cacheDirectory.appendingPathComponent("miot-instances.json")
        var data: Data?
        // A modification date in the future (clock skew, copied file) would otherwise keep a stale
        // index forever, so only a non-negative age counts as fresh.
        if isFreshCacheFile(file, cacheKey: "__index__", baseMaxAge: indexMaxAge) {
            data = try? Data(contentsOf: file)
        }
        if data == nil {
            let fetched = try await fetchWithMirrorFallback(
                path: "miot-spec-v2/instances",
                queryItems: [URLQueryItem(name: "status", value: "released")]
            ) { payload in
                (try? JSONSerialization.jsonObject(with: payload)) != nil
            }
            data = fetched
            writeCache(fetched, to: file)
        }
        let index = Self.parseInstanceIndex(data ?? Data())
        logger.info("MIoT instance index loaded: \(index.count, privacy: .public) models")
        return index
    }

    /// Highest released version per model.
    public static func parseInstanceIndex(_ data: Data) -> [String: String] {
        struct Entry: Decodable { let model: String; let version: Int; let type: String }
        struct Root: Decodable { let instances: [Entry] }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [:] }
        var best: [String: Entry] = [:]
        for e in root.instances where (best[e.model]?.version ?? Int.min) < e.version {
            best[e.model] = e
        }
        return best.mapValues(\.type)
    }

    private func instance(type: String) async throws -> MiotDeviceSpec? {
        if let cached = specByType[type] { return cached }
        let safeName = type.replacingOccurrences(of: ":", with: "_") + ".json"
        let file = cacheDirectory.appendingPathComponent("instances", isDirectory: true).appendingPathComponent(safeName)
        if isFreshCacheFile(file, cacheKey: type, baseMaxAge: specMaxAge),
           let data = try? Data(contentsOf: file),
           let spec = try? JSONDecoder().decode(MiotDeviceSpec.self, from: data) {
            specByType[type] = spec
            return spec
        }
        let fetched = try await fetchWithMirrorFallback(
            path: "miot-spec-v2/instance",
            queryItems: [URLQueryItem(name: "type", value: type)]
        ) { payload in
            (try? JSONDecoder().decode(MiotDeviceSpec.self, from: payload)) != nil
        }
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: fetched)
        writeCache(fetched, to: file)
        specByType[type] = spec
        return spec
    }

    private func fetchWithMirrorFallback(
        path: String,
        queryItems: [URLQueryItem],
        validate: (Data) -> Bool
    ) async throws -> Data {
        var lastError: any Error = MiCloudError.badResponse("mirror unavailable")
        for baseURL in mirrorBaseURLs {
            var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            comps?.queryItems = queryItems
            guard let url = comps?.url else { continue }
            do {
                let (data, http) = try await transport.send(URLRequest(url: url))
                guard http.statusCode == 200 else {
                    lastError = MiCloudError.http(http.statusCode)
                    continue
                }
                guard validate(data) else {
                    lastError = MiCloudError.badResponse("invalid spec payload")
                    continue
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func writeCache(_ data: Data, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            logger.error("Spec cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
