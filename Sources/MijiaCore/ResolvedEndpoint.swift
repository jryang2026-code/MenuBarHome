import Darwin
import Foundation
import Network

enum EndpointAddressClass: Equatable {
    case publicNetwork
    case lan
    case prohibited

    init?(numericAddress: String) {
        let address = String(numericAddress.prefix(while: { $0 != "%" }))
        if let ipv4 = IPv4Address(address) {
            self.init(ipv4: Array(ipv4.rawValue))
        } else if let ipv6 = IPv6Address(address) {
            let bytes = Array(ipv6.rawValue)
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

enum EndpointResolutionError: LocalizedError, Equatable {
    case lookupFailed
    case outsideAddressScope
    case plaintextConsentRequired

    var errorDescription: String? {
        switch self {
        case .lookupFailed:
            L10n.tr("无法解析服务地址", "Could not resolve the service address")
        case .outsideAddressScope:
            L10n.tr("服务解析到其配置范围之外的 IP 地址", "The service resolved to an IP address outside its configured network scope")
        case .plaintextConsentRequired:
            L10n.tr("局域网明文地址解析到了公网 IP，已阻止连接", "The local plain-http address resolved to a public IP. The connection was blocked.")
        }
    }
}

struct ResolvedEndpoint: Sendable {
    let url: URL
    let host: String
    let authority: String
    let port: Int
    let addresses: [String]

    init(url: URL, resolve: (String, Int) throws -> [String] = Self.lookup) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              let originalHost = url.host, !originalHost.isEmpty else {
            throw URLError(.badURL)
        }
        let secure = scheme == "https" || scheme == "wss"
        let defaultPort = secure ? 443 : 80
        let port = components.port ?? defaultPort
        var httpComponents = components
        httpComponents.scheme = secure ? "https" : "http"
        guard (1...65535).contains(port), let httpURL = httpComponents.string,
              let endpoint = AssistantEndpoint(httpURL) else {
            throw URLError(.badURL)
        }

        let literal = EndpointAddressClass(numericAddress: endpoint.host)
        let lookupHost = literal == nil ? originalHost : endpoint.host
        let addresses = try resolve(lookupHost, port)
        guard !addresses.isEmpty else { throw EndpointResolutionError.lookupFailed }
        let expected = literal ?? (endpoint.isLocalNetwork ? .lan : .publicNetwork)
        let classes = addresses.compactMap(EndpointAddressClass.init(numericAddress:))
        guard expected != .prohibited,
              classes.count == addresses.count,
              classes.allSatisfy({ $0 != .prohibited }) else {
            throw EndpointResolutionError.outsideAddressScope
        }
        if expected == .lan, !secure, classes.contains(.publicNetwork) {
            throw EndpointResolutionError.plaintextConsentRequired
        }
        guard classes.allSatisfy({ $0 == expected }) else {
            throw EndpointResolutionError.outsideAddressScope
        }
        self.url = url
        self.host = originalHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let httpHost = originalHost.contains(":") ? components.percentEncodedHost ?? "[\(originalHost)]" : originalHost
        self.authority = components.port.map { "\(httpHost):\($0)" } ?? httpHost
        self.port = port
        self.addresses = addresses
    }

    func pinnedURL(at address: String) throws -> URL {
        guard addresses.contains(address),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.host = address.contains(":") ? "[\(address)]" : address
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    static func lookup(_ host: String, _ port: Int) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
            throw EndpointResolutionError.lookupFailed
        }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let entry = current?.pointee {
            current = entry.ai_next
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.ai_addr, entry.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else {
                throw EndpointResolutionError.lookupFailed
            }
            let numeric = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            if !addresses.contains(numeric) {
                addresses.append(numeric)
            }
        }
        return addresses
    }
}
