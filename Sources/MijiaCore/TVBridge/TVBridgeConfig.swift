import Foundation

public struct TVBridgeDeviceConfig: Codable, Equatable, Sendable {
    public enum Driver: String, Codable, Sendable, CaseIterable {
        case xiaomi_6095, tcl_tnscreen, android_adb, lg_webos, sony_bravia, samsung_tizen, dlna_dmr, kodi_jsonrpc
    }
    public var nativeId: String
    public var driver: Driver
    public var host: String
    public var port: Int?
    public var name: String
    public var roomName: String
    public var macAddress: String?
    public var credentialSlot: String?
    public init(nativeId: String, driver: Driver, host: String, port: Int? = nil, name: String, roomName: String, macAddress: String? = nil, credentialSlot: String? = nil) {
        self.nativeId = nativeId; self.driver = driver; self.host = host; self.port = port; self.name = name; self.roomName = roomName; self.macAddress = macAddress; self.credentialSlot = credentialSlot
    }
}

public struct TVBridgeConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var binaryPath: String?
    public var expectedBinarySHA256: String?
    public var expectedManifestDigest: String?
    public var idleShutdownSeconds: Int
    public var devices: [TVBridgeDeviceConfig]
    public init(isEnabled: Bool = false, binaryPath: String? = nil, expectedBinarySHA256: String? = nil, expectedManifestDigest: String? = nil, idleShutdownSeconds: Int = 900, devices: [TVBridgeDeviceConfig] = []) {
        self.isEnabled = isEnabled; self.binaryPath = binaryPath; self.expectedBinarySHA256 = expectedBinarySHA256; self.expectedManifestDigest = expectedManifestDigest; self.idleShutdownSeconds = max(1, idleShutdownSeconds); self.devices = devices
    }
    public static let userDefaultsKey = "tvBridge.config.v1"
    public func save(to defaults: UserDefaults = .standard) throws { defaults.set(try JSONEncoder().encode(self), forKey: Self.userDefaultsKey) }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: userDefaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}
