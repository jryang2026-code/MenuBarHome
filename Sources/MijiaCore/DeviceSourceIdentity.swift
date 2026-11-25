import Foundation

/// Pairing evidence captured while a provider still has the raw identities. `SmartDevice` keeps
/// its source-native id and control addresses; the merges happen on this side table.
public struct DeviceSourceIdentity: Equatable, Sendable {
    public var dids: [String]
    public var macAddresses: [String]
    public var uniqueIds: [String]
    public var model: String
    public var name: String
    public var roomName: String
    public var kindTag: DeviceKindTag

    public init(
        dids: [String] = [],
        macAddresses: [String] = [],
        uniqueIds: [String] = [],
        model: String = "",
        name: String = "",
        roomName: String = "",
        kindTag: DeviceKindTag = .sensor
    ) {
        self.dids = DeviceIdentityNormalizer.sortedUnique(
            dids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        self.macAddresses = DeviceIdentityNormalizer.sortedUnique(
            macAddresses.compactMap { DeviceIdentityNormalizer.macAddress(from: $0) }
        )
        self.uniqueIds = DeviceIdentityNormalizer.sortedUnique(
            uniqueIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kindTag = kindTag
    }
}

public enum DeviceIdentityNormalizer {
    /// Home Assistant exposes Xiaomi devices as `<server>_<did>` (xiaomi_home), a bare did
    /// (xiaomi_miot), or only through entity unique ids such as `<did>_<siid>_<piid>`.
    public static func didCandidates(from rawValues: [String]) -> [String] {
        var candidates: [String] = []
        for raw in rawValues {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { continue }
            candidates.append(value)
            let parts = value.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == ":" })
            for part in parts where isDidLike(String(part)) {
                candidates.append(String(part))
            }
        }
        return sortedUnique(candidates)
    }

    static func isDidLike(_ token: String) -> Bool {
        let value = token.lowercased()
        if value.hasPrefix("blt.") || value.hasPrefix("group.") || value.hasPrefix("miot.") {
            return true
        }
        let head = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return head.count >= 6 && head.allSatisfy { $0.isNumber }
    }

    public static func macAddress(from raw: String) -> String? {
        let hex = raw.lowercased().filter { $0.isHexDigit }
        return hex.count == 12 ? hex : nil
    }

    public static func normalizedRoomName(_ raw: String) -> String {
        DeviceSynthesizer.normalizeRoomName(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func normalizedToken(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

/// Pairing-key → canonical device id. Keys stay stable when a source is temporarily absent, so a
/// paired card keeps the same id (and therefore the same favorites, tile size, order, group, alias).
public struct CanonicalDeviceRegistry: Equatable, Sendable, Codable {
    static let orphanRetention: TimeInterval = 30 * 24 * 60 * 60

    // Preferences keep their original ID and storage owner. The tombstone keeps
    // the identity mapping that makes those preferences reachable again.
    private var orphanedAt: [String: Date]?
    private(set) var explicitlyDeleted: Set<String>
    public private(set) var assignments: [String: String]

    public init(assignments: [String: String] = [:]) {
        self.assignments = assignments
        self.orphanedAt = nil
        self.explicitlyDeleted = []
    }

    private enum CodingKeys: String, CodingKey {
        case assignments
        case orphanedAt
        case explicitlyDeleted
    }

    public init(from decoder: Decoder) throws {
        if let values = try? decoder.singleValueContainer(),
           let legacy = try? values.decode([String: String].self) {
            assignments = legacy
            orphanedAt = nil
            explicitlyDeleted = []
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try container.decode([String: String].self, forKey: .assignments)
        orphanedAt = try container.decodeIfPresent([String: Date].self, forKey: .orphanedAt)
        explicitlyDeleted = Set(try container.decodeIfPresent([String].self, forKey: .explicitlyDeleted) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assignments, forKey: .assignments)
        try container.encodeIfPresent(orphanedAt, forKey: .orphanedAt)
        if !explicitlyDeleted.isEmpty { try container.encode(Array(explicitlyDeleted).sorted(), forKey: .explicitlyDeleted) }
    }

    public func canonicalID(forKeys keys: [String], allowOrphans: Bool = true) -> String? {
        for key in keys {
            if let id = assignments[key], !id.isEmpty, !explicitlyDeleted.contains(id), allowOrphans || orphanedAt?[id] == nil { return id }
        }
        return nil
    }

    mutating func forget(_ canonicalID: String) {
        guard !canonicalID.isEmpty else { return }
        explicitlyDeleted.insert(canonicalID)
        assignments = assignments.filter { $0.value != canonicalID }
        orphanedAt?.removeValue(forKey: canonicalID)
    }

    mutating func purgeExpired(at now: Date) {
        guard let orphanedAt else { return }
        let expired = Set(orphanedAt.filter { now.timeIntervalSince($0.value) >= Self.orphanRetention }.keys)
        guard !expired.isEmpty else { return }
        assignments = assignments.filter { !expired.contains($0.value) }
        self.orphanedAt = orphanedAt.filter { !expired.contains($0.key) }
        if self.orphanedAt?.isEmpty == true { self.orphanedAt = nil }
    }

    mutating func reconcile(presentIDs: Set<String>, at now: Date) {
        var next = orphanedAt ?? [:]
        let assignedIDs = Set(assignments.values)
        next = next.filter { assignedIDs.contains($0.key) && !presentIDs.contains($0.key) }
        for id in assignedIDs.subtracting(presentIDs) where next[id] == nil {
            next[id] = now
        }
        orphanedAt = next.isEmpty ? nil : next
    }

    public mutating func assign(_ canonicalID: String, toKeys keys: [String]) {
        guard !canonicalID.isEmpty, !explicitlyDeleted.contains(canonicalID) else { return }
        for key in keys where !key.isEmpty {
            assignments[key] = canonicalID
        }
    }
}

/// Normalized room name → the id and display name the merged home uses. Remembering the mapping
/// keeps a selected room valid when one source drops out.
public struct RoomIdentityRegistry: Equatable, Sendable {
    public var idsByName: [String: String]
    public var displayNames: [String: String]

    public init(idsByName: [String: String] = [:], displayNames: [String: String] = [:]) {
        self.idsByName = idsByName
        self.displayNames = displayNames
    }
}
