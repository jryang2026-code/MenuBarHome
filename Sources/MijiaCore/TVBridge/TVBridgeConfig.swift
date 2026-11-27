import Foundation

public struct TVBridgeDeviceConfig: Codable, Equatable, Sendable {
    public enum Driver: String, Codable, Sendable, CaseIterable {
        case lg_webos_ssap, xiaomi_mitv_6095, hisense_vidaa_mqtt
        case samsung_tizen_ws, sony_bravia_psk, tcl_ffalcon_tnscreen, android_adb_lan, dlna_dmr, kodi_jsonrpc

        public static let primaryCases: [Driver] = [.lg_webos_ssap, .xiaomi_mitv_6095, .hisense_vidaa_mqtt]
        public static let experimentalCases: [Driver] = allCases.filter { !primaryCases.contains($0) }
        public var isPrimary: Bool { Self.primaryCases.contains(self) }

        private static let legacyAliases: [String: Driver] = [
            "xiaomi_6095": .xiaomi_mitv_6095, "tcl_tnscreen": .tcl_ffalcon_tnscreen, "android_adb": .android_adb_lan,
            "lg_webos": .lg_webos_ssap, "sony_bravia": .sony_bravia_psk, "samsung_tizen": .samsung_tizen_ws,
        ]
        public static func canonical(from raw: String) -> Driver? { Driver(rawValue: raw) ?? legacyAliases[raw] }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let resolved = Self.canonical(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown TV bridge driver: \(raw)")
            }
            self = resolved
        }
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
