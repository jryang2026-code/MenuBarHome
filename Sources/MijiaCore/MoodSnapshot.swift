import Foundation

public struct MoodSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    let targets: [Target]

    struct Target: Codable, Equatable, Sendable {
        let deviceId: String
        let name: String
        let sourceScope: String
        let entityId: String
        var power: Bool?
        var brightness: Int?
        var colorTemperature: Int?
        var coverPosition: Int?
        var targetTemperature: Double?
        var hvacMode: String?

        var fields: [Field] {
            var result: [Field] = []
            if let power, hvacMode == nil { result.append(.intent(.power(power))) }
            if let hvacMode { result.append(.intent(.hvacMode(hvacMode))) }
            if power != false && hvacMode != "off" {
                if let brightness { result.append(.intent(.brightness(brightness))) }
                if let colorTemperature { result.append(.intent(.colorTemperature(colorTemperature))) }
                if let targetTemperature { result.append(.intent(.targetTemperature(targetTemperature))) }
            }
            if let coverPosition { result.append(.coverPosition(coverPosition)) }
            return result
        }
    }

    enum Field: Equatable {
        case intent(IntentOperation)
        case coverPosition(Int)
    }
}

enum MoodPreferences {
    static let key = "localMoodSnapshots"
    static let limit = 32

    struct File: Codable, Equatable {
        let version: Int
        let moods: [MoodSnapshot]
    }

    static func load(from defaults: UserDefaults) -> [MoodSnapshot] {
        guard let data = defaults.data(forKey: key),
              let file = try? decode(data), file.version == 1 else { return [] }
        return Array(file.moods.prefix(limit))
    }

    static func decode(_ data: Data) throws -> File {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(File.self, from: data)
    }

    static func save(_ moods: [MoodSnapshot], to defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(version: 1, moods: Array(moods.prefix(limit))))
        defaults.set(data, forKey: key)
    }
}
