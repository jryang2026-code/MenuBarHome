import Foundation

public struct GenericCameraSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case rtsp, onvif, isapi, dahua, tapo

        public var id: Self { self }
        public var title: String {
            switch self {
            case .rtsp: "RTSP"
            case .onvif: "ONVIF"
            case .isapi: L10n.tr("海康 ISAPI", "Hikvision ISAPI")
            case .dahua: L10n.tr("大华", "Dahua")
            case .tapo: "TP-Link Tapo"
            }
        }

        public var defaultPort: Int {
            switch self {
            case .rtsp, .isapi, .dahua: 554
            case .onvif: 80
            case .tapo: 8800
            }
        }
    }

    public enum Stream: Sendable {
        case main, sub
    }

    public var id = UUID()
    public var name = ""
    public var kind: Kind = .rtsp
    public var host = ""
    public var port: Int?
    public var path: String?
    public var channel: Int?
    public var mainStream: String?
    public var subStream: String?

    public init() {}

    static let devicePrefix = "generic-camera:"
    public var deviceID: String { Self.devicePrefix + id.uuidString.lowercased() }

    private var normalizedHost: String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    var endpointKey: String { "\(kind.rawValue)|\(normalizedHost)|\(port ?? kind.defaultPort)" }

    public var requiresPlaintextConsent: Bool {
        let host = normalizedHost
        return EndpointAddressClass(numericAddress: host) != .lan && !host.hasSuffix(".local")
    }

    private var endpointURL: URL? {
        let host = normalizedHost
        let port = port ?? kind.defaultPort
        guard (1...65535).contains(port), EndpointAddressClass(numericAddress: host) != .prohibited,
              EndpointAddressClass(numericAddress: host) != nil
                || host.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*/) != nil,
              !host.contains("%") else { return nil }
        return URL(string: "http://\(Self.authorityHost(host)):\(port)")
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && endpointURL != nil
            && (1...999).contains(channel ?? 1)
            && (kind == .rtsp || path == nil)
            && [Stream.main, .sub].allSatisfy { streamPath($0) != nil }
    }

    public struct Credentials: Codable, Equatable, Sendable {
        public var username: String
        public var password: String

        public init(username: String = "", password: String = "") {
            self.username = username
            self.password = password
        }
    }

    func credentials(vault: CredentialVault) -> Credentials? {
        guard let data = KeychainHelper.readKeychainData(account: deviceID, vault: vault) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    func storeCredentials(_ credentials: Credentials?, vault: CredentialVault) -> Bool {
        if let credentials {
            guard let data = try? JSONEncoder().encode(credentials) else { return false }
            return KeychainHelper.writeKeychainData(data, account: deviceID, vault: vault)
        }
        return KeychainHelper.writeKeychainData(nil, account: deviceID, vault: vault)
    }

    func source(_ stream: Stream, credentials: Credentials? = nil, address: String? = nil) -> String? {
        guard endpointURL != nil, let path = streamPath(stream) else { return nil }
        let host = Self.authorityHost(address ?? normalizedHost)
        let port = port ?? kind.defaultPort
        let user = credentials.map { Self.encode($0.username) } ?? "{user}"
        let pass = credentials.map { Self.encode($0.password) } ?? "{pass}"
        let auth = credentials?.username.isEmpty == true && credentials?.password.isEmpty == true
            ? "" : "\(user):\(pass)@"
        let noBackchannel = "#backchannel=0"
        switch kind {
        case .rtsp, .isapi, .dahua:
            return "rtsp://\(auth)\(host):\(port)\(path)\(noBackchannel)"
        case .onvif:
            return "onvif://\(auth)\(host):\(port)\(path)\(noBackchannel)"
        case .tapo:
            let authority = self.port == nil ? host : "\(host):\(port)"
            return "tapo://\(pass)@\(authority)\(path)"
        }
    }

    func resolvedAddress(allowPublic: Bool) async throws -> String {
        guard isValid, let endpointURL, allowPublic || !requiresPlaintextConsent else {
            throw GenericCameraError.invalidConnection
        }
        return try await HAPlaintextConsent.resolveCameraAddress(endpointURL, allowPublic: allowPublic)
    }

    private func streamPath(_ stream: Stream) -> String? {
        let selector = stream == .main ? mainStream : subStream
        switch kind {
        case .rtsp, .isapi, .dahua:
            let channel = channel ?? 1
            let fallback: String
            switch kind {
            case .isapi: fallback = "/Streaming/Channels/\(channel)\(stream == .main ? "01" : "02")"
            case .dahua: fallback = "/cam/realmonitor?channel=\(channel)&subtype=\(stream == .main ? 0 : 1)"
            default: fallback = path ?? "/"
            }
            let suffix = selector ?? (kind == .rtsp && stream == .sub ? mainStream : nil) ?? fallback
            guard suffix.hasPrefix("/"), !suffix.hasPrefix("//"), !suffix.contains("#"), !suffix.contains("\\"),
                  let url = URL(string: "rtsp://camera.invalid\(suffix)"),
                  url.absoluteString == "rtsp://camera.invalid\(suffix)" else { return nil }
            return suffix
        case .onvif:
            guard let selector else { return stream == .main ? "" : "?subtype=1" }
            guard !selector.isEmpty, selector.utf8.count <= 128,
                  selector.utf8.allSatisfy(Self.isUnreserved) else { return nil }
            return "?subtype=\(selector)"
        case .tapo:
            let subtype = selector ?? (stream == .main ? "0" : "1")
            guard subtype == "0" || subtype == "1", (1...999).contains(channel ?? 1) else { return nil }
            let index = (channel ?? 1) - 1
            let query = [subtype == "0" ? nil : "subtype=1", index == 0 ? nil : "channel=\(index)"].compactMap { $0 }
            return query.isEmpty ? "" : "?" + query.joined(separator: "&")
        }
    }

    private static func authorityHost(_ host: String) -> String {
        host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 45, 46, 95, 126: true
        default: false
        }
    }

    private static func encode(_ value: String) -> String {
        value.utf8.map { isUnreserved($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
}

enum GenericCameraError: LocalizedError {
    case invalidConnection, failedConnection, unsupportedHelper

    var errorDescription: String? {
        switch self {
        case .invalidConnection: L10n.tr("请检查地址、端口和码流设置。", "Check the address, port and stream settings.")
        case .failedConnection: L10n.tr("未能获取摄像机画面，请检查网络和凭据。", "Couldn’t get a camera picture. Check the network and credentials.")
        case .unsupportedHelper: L10n.tr("此流媒体组件不支持只读摄像机，请更新应用。", "This streaming helper lacks read-only camera support. Update the app to continue.")
        }
    }
}
