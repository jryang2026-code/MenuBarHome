import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Per-address consent to send the Home Assistant token over plain http to a non-local host (#276).
///
/// https addresses and `LocalNetworkEndpoint`s never ask. Every other address needs the user to agree
/// once; the agreement is keyed by origin, so a changed address asks again.
public enum HAPlaintextConsent {
    static let defaultsKey = "ha_plaintext_consent_v1"
    private static let addressLookupTimeout: Duration = .milliseconds(500)

    /// True when sending the token to `baseURL` would cross the internet unencrypted. An address that
    /// does not parse counts as needing consent, so an odd URL fails closed.
    public static func needsConsent(_ baseURL: String) -> Bool {
        !(AssistantEndpoint(HAWebSocketProvider.normalizeBaseURL(baseURL))?.allowsSendingSecrets ?? false)
    }

    public static func isApproved(_ baseURL: String, defaults: UserDefaults) -> Bool {
        approved(defaults).contains(key(baseURL))
    }

    /// Whether the token may go to `baseURL` right now.
    public static func allowsToken(to baseURL: String, defaults: UserDefaults) -> Bool {
        !needsConsent(baseURL) || isApproved(baseURL, defaults: defaults)
    }

    /// Checks the current DNS answers before starting an HA request. URLSession can resolve
    /// the name again when it connects, leaving a window for DNS to change after this check.
    public static func validateConnectionAddress(_ url: URL) async throws {
        try await resolveWithTimeout {
            try validateConnectionAddress(url, resolve: lookup)
        }
    }

    /// Pins the numeric address passed to go2rtc, so the helper never resolves the name again.
    static func resolveCameraAddress(_ url: URL, allowPublic: Bool) async throws -> String {
        try await resolveWithTimeout {
            guard let host = url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else {
                throw URLError(.badURL)
            }
            if let literal = EndpointAddressClass(numericAddress: host),
               literal == .lan || (allowPublic && literal == .publicNetwork) {
                return host
            }
            let addresses = try lookup(host)
            guard let selected = addresses.first, addresses.allSatisfy({ address in
                guard let kind = EndpointAddressClass(numericAddress: address) else { return false }
                return kind == .lan || (allowPublic && kind == .publicNetwork)
            }) else {
                throw HAEndpointResolutionError.prohibitedAddress
            }
            return selected
        }
    }

    private static func resolveWithTimeout<Value: Sendable>(
        _ lookup: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let (resolved, completion) = AsyncThrowingStream<Value, Error>.makeStream()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: addressLookupTimeout)
                completion.finish(throwing: URLError(.timedOut))
            } catch {
            }
        }
        defer { timeoutTask.cancel() }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion.yield(try lookup())
                completion.finish()
            } catch {
                completion.finish(throwing: error)
            }
        }
        var result = resolved.makeAsyncIterator()
        let value = try await withTaskCancellationHandler {
            try await result.next()
        } onCancel: {
            completion.finish(throwing: CancellationError())
        }
        try Task.checkCancellation()
        guard let value else { throw URLError(.cannotFindHost) }
        return value
    }

    static func validateConnectionAddress(_ url: URL, resolve: (String) throws -> [String]) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw URLError(.badURL)
        }
        let plaintext = scheme == "http" || scheme == "ws"
        components.scheme = plaintext ? "http" : "https"
        guard let origin = normalizedOrigin(from: components) else { throw URLError(.badURL) }
        let endpoint = components.string.flatMap(AssistantEndpoint.init)
        let normalizedHost = endpoint?.host ?? origin.host
        let literal = EndpointAddressClass(numericAddress: normalizedHost)
        guard literal != .prohibited else { throw HAEndpointResolutionError.prohibitedAddress }
        guard literal != nil || endpoint != nil else { throw URLError(.badURL) }
        if literal != nil { return }
        let requiresLAN = plaintext && (literal.map { $0 == .lan } ?? (endpoint?.isLocalNetwork == true))
        let answers = try resolve(host)
        guard !answers.isEmpty else { throw URLError(.cannotFindHost) }
        for answer in answers {
            guard let addressClass = EndpointAddressClass(numericAddress: answer),
                  addressClass != .prohibited else {
                throw HAEndpointResolutionError.prohibitedAddress
            }
            if requiresLAN && addressClass == .publicNetwork {
                throw HAEndpointResolutionError.publicAddressForLocalPlaintext
            }
        }
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            throw URLError(.cannotFindHost)
        }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let entry = current?.pointee {
            current = entry.ai_next
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.ai_addr, entry.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else {
                throw URLError(.cannotFindHost)
            }
            addresses.append(String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
        }
        return addresses
    }

    public static func matchesServerOrigin(_ targetURL: URL, serverBaseURL: String) -> Bool {
        guard !serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalizedServer = HAWebSocketProvider.normalizeBaseURL(serverBaseURL)
        guard let targetComponents = URLComponents(url: targetURL, resolvingAgainstBaseURL: true),
              let serverComponents = URLComponents(string: normalizedServer),
              let targetOrigin = normalizedOrigin(from: targetComponents),
              let serverOrigin = normalizedOrigin(from: serverComponents) else {
            return false
        }
        return targetOrigin == serverOrigin
    }

    private static func normalizedOrigin(from components: URLComponents) -> (scheme: String, host: String, port: Int)? {
        guard components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }
        let effectivePort = components.port ?? (scheme == "https" ? 443 : 80)
        return (scheme, host, effectivePort)
    }

    public static func approve(_ baseURL: String, defaults: UserDefaults) {
        var urls = approved(defaults)
        urls.insert(key(baseURL))
        defaults.set(urls.sorted(), forKey: defaultsKey)
    }

    public static func revoke(_ baseURL: String, defaults: UserDefaults) {
        var urls = approved(defaults)
        guard urls.remove(key(baseURL)) != nil else { return }
        if urls.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(urls.sorted(), forKey: defaultsKey)
        }
    }

    public static func revokeAll(defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// The token goes to a host, so consent covers the origin (scheme, host, port), not a path.
    private static func key(_ baseURL: String) -> String {
        let normalized = HAWebSocketProvider.normalizeBaseURL(baseURL)
        guard let endpoint = AssistantEndpoint(normalized) else { return normalized }
        return "\(endpoint.scheme)://\(endpoint.identity)"
    }

    private static func approved(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public static func host(_ baseURL: String) -> String {
        URL(string: HAWebSocketProvider.normalizeBaseURL(baseURL))?.host ?? baseURL
    }

    static func waitingMessage(_ baseURL: String) -> String {
        let host = host(baseURL)
        return L10n.tr(
            "\(host) 是公网明文地址，令牌会以明文传输。同意前不会连接。",
            "\(host) is a public plain-http address; your token would travel unencrypted. Not connecting until you agree."
        )
    }

    public static func declinedMessage(_ baseURL: String) -> String {
        let host = host(baseURL)
        return L10n.tr(
            "未连接 \(host)：你拒绝了以明文发送令牌。改用 https 或局域网地址后再连接。",
            "Not connected to \(host): you declined sending the token unencrypted. Use an https or local-network address."
        )
    }
}

enum HAEndpointResolutionError: LocalizedError {
    case prohibitedAddress
    case publicAddressForLocalPlaintext

    var errorDescription: String? {
        switch self {
        case .prohibitedAddress:
            L10n.tr("Home Assistant 地址解析到了禁止访问的 IP", "The Home Assistant address resolved to a prohibited IP.")
        case .publicAddressForLocalPlaintext:
            L10n.tr("局域网明文地址解析到了公网 IP，已阻止连接", "The local plaintext address resolved to a public IP. The connection was blocked.")
        }
    }
}

enum EndpointAddressClass: Equatable {
    case publicNetwork
    case lan
    case prohibited

    init?(numericAddress: String) {
        let address = String(numericAddress.prefix(while: { $0 != "%" }))
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            self.init(ipv4: withUnsafeBytes(of: ipv4, Array.init))
        } else if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6, Array.init)
            switch bytes {
            case let bytes where bytes.prefix(12).elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255]):
                self.init(ipv4: Array(bytes.suffix(4)))
            case let bytes where bytes.prefix(12).allSatisfy({ $0 == 0 }):
                self = .prohibited
            default:
                switch (bytes[0], bytes[1]) {
                case (0xfc...0xfd, _), (0xfe, 0x80...0xbf): self = .lan
                case (0xfe, 0xc0...0xff), (0xff, _): self = .prohibited
                default: self = .publicNetwork
                }
            }
        } else {
            return nil
        }
    }

    private init(ipv4 bytes: [UInt8]) {
        switch (bytes[0], bytes[1]) {
        case (0, _), (127, _), (224...255, _): self = .prohibited
        // Shared address space (100.64/10) includes Tailscale endpoints.
        case (10, _), (172, 16...31), (192, 168), (169, 254), (100, 64...127): self = .lan
        default: self = .publicNetwork
        }
    }
}

/// What the panel shows about a public plain-http Home Assistant address.
public enum HAPlaintextPrompt: Equatable, Sendable {
    case asking(String)
    case declined(String)

    public var address: String {
        switch self {
        case .asking(let url), .declined(let url): url
        }
    }
}
