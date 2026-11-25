import Dispatch
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
    static let addressLookupTimeout: Duration = .milliseconds(2500)
    private static let sharedLookup = BoundedHostLookup(resolve: lookup)

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
        try await validateConnectionAddress(url, resolver: sharedLookup)
    }

    static func validateConnectionAddress(_ url: URL, resolver: BoundedHostLookup) async throws {
        try Task.checkCancellation()
        switch try parseValidationTarget(url) {
        case .literal:
            return
        case .hostname(let host, let requiresLAN):
            let answers = try await resolver.lookup(host)
            try validateResolvedAnswers(answers, requiresLAN: requiresLAN)
        }
    }

    /// Pins the numeric address passed to go2rtc, so the helper never resolves the name again.
    static func resolveCameraAddress(_ url: URL, allowPublic: Bool) async throws -> String {
        try Task.checkCancellation()
        guard let host = url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else {
            throw URLError(.badURL)
        }
        if let literal = EndpointAddressClass(numericAddress: host) {
            guard literal == .lan || (allowPublic && literal == .publicNetwork) else {
                throw HAEndpointResolutionError.prohibitedAddress
            }
            return host
        }
        let addresses = try await sharedLookup.lookup(host)
        guard let selected = addresses.first, addresses.allSatisfy({ address in
            guard let kind = EndpointAddressClass(numericAddress: address) else { return false }
            return kind == .lan || (allowPublic && kind == .publicNetwork)
        }) else {
            throw HAEndpointResolutionError.prohibitedAddress
        }
        return selected
    }

    private enum ValidationTarget {
        case literal
        case hostname(host: String, requiresLAN: Bool)
    }

    private static func parseValidationTarget(_ url: URL) throws -> ValidationTarget {
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
        if literal != nil { return .literal }
        let requiresLAN = plaintext && (endpoint?.isLocalNetwork == true)
        return .hostname(host: host, requiresLAN: requiresLAN)
    }

    private static func validateResolvedAnswers(_ answers: [String], requiresLAN: Bool) throws {
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

    static func validateConnectionAddress(_ url: URL, resolve: (String) throws -> [String]) throws {
        switch try parseValidationTarget(url) {
        case .literal:
            return
        case .hostname(let host, let requiresLAN):
            let answers = try resolve(host)
            try validateResolvedAnswers(answers, requiresLAN: requiresLAN)
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

    public static func hasSameOrigin(_ lhs: URL, as rhs: URL, allowWebSocketSchemes: Bool = false) -> Bool {
        guard let lhsComponents = URLComponents(url: lhs, resolvingAgainstBaseURL: true),
              let rhsComponents = URLComponents(url: rhs, resolvingAgainstBaseURL: true),
              let lhsOrigin = normalizedOrigin(from: lhsComponents, allowWebSocketSchemes: allowWebSocketSchemes),
              let rhsOrigin = normalizedOrigin(from: rhsComponents, allowWebSocketSchemes: allowWebSocketSchemes) else {
            return false
        }
        return lhsOrigin == rhsOrigin
    }

    /// Returns `true` for a local go2rtc bridge URL owned by `XiaomiCameraBridge` or an explicit
    /// loopback custom camera URL configured by the user.
    public static func isAllowedLoopbackStreamURL(_ url: URL, customStreamURL: String?) async -> Bool {
        if await XiaomiCameraBridge.shared.isManagedStreamURL(url) { return true }
        guard let customStreamURL else { return false }
        let trimmedCustom = customStreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCustom.isEmpty,
              let customURL = URL(string: trimmedCustom),
              let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let customComponents = URLComponents(url: customURL, resolvingAgainstBaseURL: true),
              let urlOrigin = normalizedOrigin(from: urlComponents, allowUserInfo: true),
              let customOrigin = normalizedOrigin(from: customComponents, allowUserInfo: true),
              urlOrigin == customOrigin,
              AssistantEndpoint(trimmedCustom)?.isLoopback == true else {
            return false
        }
        if urlComponents.user != nil || urlComponents.password != nil {
            return urlComponents.user == customComponents.user
                && urlComponents.password == customComponents.password
        }
        return true
    }

    /// Synchronous literal-host check for views (such as `AVPlayer`) that cannot await DNS before mounting.
    public static func allowsImmediatePlaybackURL(_ url: URL, allowsLoopback: Bool = false) -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if allowsLoopback { components.user = nil; components.password = nil }
        guard let origin = normalizedOrigin(from: components) else { return false }
        let endpoint = components.string.flatMap(AssistantEndpoint.init)
        let normalizedHost = endpoint?.host ?? origin.host
        if let literal = EndpointAddressClass(numericAddress: normalizedHost) {
            return literal != .prohibited || (allowsLoopback && endpoint?.isLoopback == true)
        }
        return endpoint != nil
    }

    private static func normalizedOrigin(
        from components: URLComponents,
        allowWebSocketSchemes: Bool = false,
        allowUserInfo: Bool = false
    ) -> (scheme: String, host: String, port: Int)? {
        guard allowUserInfo || (components.user == nil && components.password == nil),
              let rawScheme = components.scheme?.lowercased(),
              var host = components.host?.lowercased() else {
            return nil
        }
        let scheme: String
        switch rawScheme {
        case "http", "https":
            scheme = rawScheme
        case "ws" where allowWebSocketSchemes:
            scheme = "http"
        case "wss" where allowWebSocketSchemes:
            scheme = "https"
        default:
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

public enum HAEndpointResolutionError: LocalizedError, Sendable {
    case prohibitedAddress
    case publicAddressForLocalPlaintext

    public var errorDescription: String? {
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
            case let bytes where bytes.prefix(12).elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]):
                // RFC 6052 NAT64 well-known prefix (64:ff9b::/96): classify the embedded IPv4 target.
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
        // Cloud instance metadata service (IMDS) must never be treated as LAN.
        if bytes == [169, 254, 169, 254] {
            self = .prohibited
            return
        }
        switch (bytes[0], bytes[1]) {
        case (0, _), (127, _), (224...255, _): self = .prohibited
        // Shared address space (100.64/10) includes Tailscale endpoints.
        case (10, _), (172, 16...31), (192, 168), (169, 254), (100, 64...127): self = .lan
        default: self = .publicNetwork
        }
    }
}

/// Bounds concurrent blocking `getaddrinfo` lookups and deduplicates active in-flight queries per
/// exact lowercased host so polling loops against unreachable hosts cannot exhaust GCD threads,
/// while never caching DNS answers across sequential validations.
final class BoundedHostLookup: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        enum State { case pending, waiting(CheckedContinuation<[String], Error>), completed(Result<[String], Error>), consumed }
        let id = UUID()
        var state: State = .pending
    }
    private struct InFlightEntry {
        let id: UUID
        let host: String
        var started: Bool
        var waiters: [UUID: Waiter]
    }

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "com.menubarhome.ha-dns-lookup", qos: .userInitiated, attributes: .concurrent)
    private let maxConcurrentLookups: Int
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let resolve: @Sendable (String) throws -> [String]
    private var activeCount = 0
    private var inFlight: [String: InFlightEntry] = [:]
    private var pendingQueue: [(id: UUID, key: String)] = []

    init(
        maxConcurrentLookups: Int = 4,
        timeout: Duration = HAPlaintextConsent.addressLookupTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        resolve: @escaping @Sendable (String) throws -> [String]
    ) {
        self.maxConcurrentLookups = max(1, maxConcurrentLookups)
        self.timeout = timeout
        self.sleep = sleep
        self.resolve = resolve
    }

    func lookup(_ host: String) async throws -> [String] {
        try Task.checkCancellation()
        let key = host.lowercased()
        let waiter = Waiter()
        let (entryID, launchJob) = beginLookup(key: key, host: host, waiter: waiter)
        if launchJob { dispatchLookup(id: entryID, key: key, host: host) }

        let timeoutTask = Task { [weak self, sleep, timeout] in
            if (try? await sleep(timeout)) != nil {
                self?.finishWaiter(waiter, entryID: entryID, key: key, result: .failure(URLError(.timedOut)))
            }
        }
        defer { timeoutTask.cancel() }

        let addresses = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { self.installContinuation($0, on: waiter) }
        } onCancel: {
            self.finishWaiter(waiter, entryID: entryID, key: key, result: .failure(CancellationError()))
        }
        try Task.checkCancellation()
        return addresses
    }

    private func beginLookup(key: String, host: String, waiter: Waiter) -> (UUID, Bool) {
        lock.lock(); defer { lock.unlock() }
        if var existing = inFlight[key], !existing.waiters.isEmpty {
            existing.waiters[waiter.id] = waiter
            inFlight[key] = existing
            return (existing.id, false)
        }
        let id = UUID()
        let canStart = activeCount < maxConcurrentLookups
        if canStart {
            activeCount += 1
        } else {
            pendingQueue.append((id: id, key: key))
        }
        inFlight[key] = InFlightEntry(id: id, host: host, started: canStart, waiters: [waiter.id: waiter])
        return (id, canStart)
    }

    private func installContinuation(_ continuation: CheckedContinuation<[String], Error>, on waiter: Waiter) {
        let immediate: Result<[String], Error>? = {
            lock.lock(); defer { lock.unlock() }
            switch waiter.state {
            case .pending: waiter.state = .waiting(continuation); return nil
            case .completed(let result): waiter.state = .consumed; return result
            case .waiting, .consumed: return nil
            }
        }()
        if let immediate { continuation.resume(with: immediate) }
    }

    private func finishWaiter(_ waiter: Waiter, entryID: UUID, key: String, result: Result<[String], Error>) {
        let cont: CheckedContinuation<[String], Error>? = {
            lock.lock(); defer { lock.unlock() }
            let active: CheckedContinuation<[String], Error>?
            switch waiter.state {
            case .pending: waiter.state = .completed(result); active = nil
            case .waiting(let existing): waiter.state = .consumed; active = existing
            case .completed, .consumed: return nil
            }
            if var entry = inFlight[key], entry.id == entryID {
                entry.waiters.removeValue(forKey: waiter.id)
                if entry.waiters.isEmpty {
                    inFlight.removeValue(forKey: key)
                    if !entry.started {
                        pendingQueue.removeAll { $0.id == entryID }
                    }
                } else {
                    inFlight[key] = entry
                }
            }
            return active
        }()
        cont?.resume(with: result)
    }

    private func dispatchLookup(id: UUID, key: String, host: String) {
        let resolve = self.resolve
        workerQueue.async { [weak self] in
            self?.completeLookup(id: id, key: key, result: Result { try resolve(host) })
        }
    }

    private func completeLookup(id: UUID, key: String, result: Result<[String], Error>) {
        let (continuations, nextJobs): ([CheckedContinuation<[String], Error>], [(UUID, String, String)]) = {
            lock.lock(); defer { lock.unlock() }
            activeCount = max(0, activeCount - 1)
            var waiting: [CheckedContinuation<[String], Error>] = []
            if inFlight[key]?.id == id, let entry = inFlight.removeValue(forKey: key) {
                for waiter in entry.waiters.values {
                    switch waiter.state {
                    case .pending: waiter.state = .completed(result)
                    case .waiting(let cont): waiter.state = .consumed; waiting.append(cont)
                    case .completed, .consumed: break
                    }
                }
            }
            var launched: [(UUID, String, String)] = []
            while activeCount < maxConcurrentLookups, !pendingQueue.isEmpty {
                let next = pendingQueue.removeFirst()
                guard var entry = inFlight[next.key], entry.id == next.id, !entry.started else { continue }
                if entry.waiters.isEmpty {
                    inFlight.removeValue(forKey: next.key)
                    continue
                }
                entry.started = true
                inFlight[next.key] = entry
                activeCount += 1
                launched.append((next.id, next.key, entry.host))
            }
            return (waiting, launched)
        }()
        for cont in continuations { cont.resume(with: result) }
        for (nextID, nextKey, nextHost) in nextJobs {
            dispatchLookup(id: nextID, key: nextKey, host: nextHost)
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
