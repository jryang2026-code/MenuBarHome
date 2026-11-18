import CryptoKit
import Foundation

public struct CachedMiTopology: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: Date
    public var devices: [MiDeviceRecord]
    public var rooms: [MiRoom]
    public var groupMembersByGroup: [String: [String]]
    public var discoveredLANIPsByDid: [String: String]

    public init(
        version: Int = 1,
        savedAt: Date,
        devices: [MiDeviceRecord],
        rooms: [MiRoom],
        groupMembersByGroup: [String: [String]] = [:],
        discoveredLANIPsByDid: [String: String] = [:]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.devices = devices
        self.rooms = rooms
        self.groupMembersByGroup = groupMembersByGroup
        self.discoveredLANIPsByDid = discoveredLANIPsByDid
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.savedAt = try c.decode(Date.self, forKey: .savedAt)
        self.devices = try c.decode([MiDeviceRecord].self, forKey: .devices)
        self.rooms = try c.decode([MiRoom].self, forKey: .rooms)
        self.groupMembersByGroup = try c.decodeIfPresent([String: [String]].self, forKey: .groupMembersByGroup) ?? [:]
        self.discoveredLANIPsByDid = try c.decodeIfPresent([String: String].self, forKey: .discoveredLANIPsByDid) ?? [:]
    }
}

public struct MiTopologyCache: Sendable {
    public static let currentVersion = 1

    public let directory: URL

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MenuBarMijia", isDirectory: true)
            .appendingPathComponent("mi-topology", isDirectory: true)
    }

    public static let shared = MiTopologyCache(directory: defaultDirectory)

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    public func save(_ topology: CachedMiTopology, for session: MiSession) {
        guard !topology.devices.isEmpty, !session.ssecurity.isEmpty else { return }
        let accountID = MiAccount(session: session).id
        let key = Self.symmetricKey(accountID: accountID, ssecurity: session.ssecurity)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoded = try JSONEncoder().encode(topology)
            let sealed = try AES.GCM.seal(encoded, using: key)
            guard let combined = sealed.combined else { return }
            let target = fileURL(forAccountID: accountID)
            try combined.write(to: target, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            return
        }
    }

    public func load(for session: MiSession) -> CachedMiTopology? {
        guard !session.ssecurity.isEmpty else { return nil }
        let accountID = MiAccount(session: session).id
        let target = fileURL(forAccountID: accountID)
        guard let combined = try? Data(contentsOf: target) else { return nil }
        let key = Self.symmetricKey(accountID: accountID, ssecurity: session.ssecurity)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            let decoded = try JSONDecoder().decode(CachedMiTopology.self, from: plaintext)
            guard decoded.version == Self.currentVersion else { return nil }
            return decoded
        } catch {
            return nil
        }
    }

    public func remove(accountID: String) {
        try? FileManager.default.removeItem(at: fileURL(forAccountID: accountID))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func fileURL(forAccountID accountID: String) -> URL {
        let digest = SHA256.hash(data: Data("MenuBarHome.MiTopologyFile.v1|\(accountID)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).bin", isDirectory: false)
    }

    private static func symmetricKey(accountID: String, ssecurity: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data("MenuBarHome.MiTopologyCache.v1|\(accountID)|\(ssecurity)".utf8))
        return SymmetricKey(data: digest)
    }
}
