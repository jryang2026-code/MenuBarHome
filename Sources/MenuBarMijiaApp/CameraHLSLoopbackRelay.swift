import AVFoundation
import Darwin
import Dispatch
import Foundation
import MijiaCore
import Security

enum CameraHLSPlayerFactory {
    /// Routes non-managed / remote HLS streams through a per-session `CameraHLSLoopbackRelay`
    /// bound strictly to `127.0.0.1:0` with a 128-bit random token path prefix so `AVPlayer`
    /// fetches standard HTTP while every playlist, key, init map, and media segment stays
    /// same-origin, freshly DNS-validated, and redirect-blocked. Managed/explicit loopback
    /// streams keep direct `AVPlayerItem(url:)`.
    static func makePlayerItem(
        url: URL,
        allowsLoopback: Bool
    ) -> (item: AVPlayerItem, relay: CameraHLSLoopbackRelay?)? {
        guard HAPlaintextConsent.allowsImmediatePlaybackURL(url, allowsLoopback: allowsLoopback) else {
            return nil
        }
        if allowsLoopback {
            return (AVPlayerItem(url: url), nil)
        }
        guard let relayed = makeRelayedPlayerItem(originURL: url) else {
            return nil
        }
        return (relayed.item, relayed.relay)
    }

    static func makeRelayedPlayerItem(
        originURL: URL,
        sessionConfiguration: URLSessionConfiguration? = nil,
        validateAddress: @escaping @Sendable (URL) async throws -> Void = {
            try await HAPlaintextConsent.validateConnectionAddress($0)
        }
    ) -> (item: AVPlayerItem, relay: CameraHLSLoopbackRelay)? {
        guard let relay = CameraHLSLoopbackRelay(
            originURL: originURL,
            sessionConfiguration: sessionConfiguration,
            validateAddress: validateAddress
        ) else {
            return nil
        }
        let asset = AVURLAsset(url: relay.entryURL)
        return (AVPlayerItem(asset: asset), relay)
    }
}

/// Hardened local loopback HTTP relay for HA/remote HLS playback.
///
/// Binds strictly to `127.0.0.1:0`, authenticates every incoming request with a 128-bit random
/// path prefix, re-validates same-origin and DNS (no cache) on every sub-request, blocks
/// cross-origin/prohibited redirects via `HARedirectBlockingDelegate.shared`, and rewrites
/// M3U8 playlists fail-closed back onto this relay.
final class CameraHLSLoopbackRelay: @unchecked Sendable {
    let originURL: URL
    let port: UInt16
    let token: String
    let entryURL: URL

    private static let maxConcurrentConnections = 32
    private static let maxRequestHeaderBytes = 16 * 1024
    private static let maxSegmentBytes = 32 * 1024 * 1024

    private let relayBase: HAHLSPlaylistPolicy.RelayBase
    private let acceptQueue = DispatchQueue(label: "com.menubarhome.camera-hls-relay.accept")
    private let ioQueue = DispatchQueue(label: "com.menubarhome.camera-hls-relay.io", attributes: .concurrent)
    private let sessionDelegate: RelayURLSessionDelegate
    private let session: URLSession
    private let validateAddress: @Sendable (URL) async throws -> Void

    private let lock = NSLock()
    private var isStopped = false
    private var isPortRegistered = false
    private var listenSource: (any DispatchSourceRead)?
    private var activeSockets: [UUID: ManagedSocketFD] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    init?(
        originURL: URL,
        sessionConfiguration: URLSessionConfiguration? = nil,
        validateAddress: @escaping @Sendable (URL) async throws -> Void = {
            try await HAPlaintextConsent.validateConnectionAddress($0)
        }
    ) {
        let token = Self.makeRandomToken()
        guard let (listenFD, boundPort) = Self.makeLoopbackListener() else {
            return nil
        }
        var ownsListenFD = true
        defer {
            if ownsListenFD {
                Darwin.close(listenFD)
            }
        }
        guard let relayBase = HAHLSPlaylistPolicy.RelayBase(port: boundPort, token: token),
              let entryURL = HAHLSPlaylistPolicy.relayURL(
                  for: originURL,
                  allowedOrigin: originURL,
                  relay: relayBase
              ) else {
            return nil
        }

        self.originURL = originURL
        self.port = boundPort
        self.token = token
        self.relayBase = relayBase
        self.entryURL = entryURL
        self.validateAddress = validateAddress

        let cfg = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? {
            let base = URLSessionConfiguration.ephemeral
            base.connectionProxyDictionary = [:]
            base.httpCookieStorage = nil
            base.httpShouldSetCookies = false
            base.urlCredentialStorage = nil
            base.timeoutIntervalForRequest = 15
            base.timeoutIntervalForResource = 30
            base.waitsForConnectivity = false
            return base
        }()
        let delegate = RelayURLSessionDelegate(
            maxPlaylistBytes: HAHLSPlaylistPolicy.maxPlaylistBytes,
            maxSegmentBytes: Self.maxSegmentBytes
        )
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

        HAPlaintextConsent.registerInternalLoopbackPort(boundPort)
        self.isPortRegistered = true

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections(listenFD: listenFD)
        }
        source.setCancelHandler {
            Darwin.close(listenFD)
        }
        ownsListenFD = false
        self.listenSource = source
        source.resume()
    }

    deinit {
        stop()
    }

    func stop() {
        let (source, sockets, tasks, shouldUnregister): (
            (any DispatchSourceRead)?,
            [ManagedSocketFD],
            [Task<Void, Never>],
            Bool
        ) = {
            lock.lock()
            defer { lock.unlock() }
            isStopped = true
            let currentSource = listenSource
            listenSource = nil
            let currentSockets = Array(activeSockets.values)
            let currentTasks = Array(activeTasks.values)
            activeTasks.removeAll()
            let unregister = isPortRegistered
            isPortRegistered = false
            return (currentSource, currentSockets, currentTasks, unregister)
        }()

        source?.cancel()
        for socket in sockets {
            socket.shutdown()
        }
        for task in tasks {
            task.cancel()
        }
        sessionDelegate.invalidate()
        session.invalidateAndCancel()
        if shouldUnregister {
            HAPlaintextConsent.unregisterInternalLoopbackPort(port)
        }
    }

    private func acceptPendingConnections(listenFD: Int32) {
        while true {
            var peerAddr = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &peerAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &peerLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            Self.configureClientSocket(clientFD)
            let managed = ManagedSocketFD(fd: clientFD)
            let connectionID = UUID()

            let accepted: Bool = {
                lock.lock()
                defer { lock.unlock() }
                guard !isStopped, activeSockets.count < Self.maxConcurrentConnections else {
                    return false
                }
                activeSockets[connectionID] = managed
                return true
            }()
            guard accepted else {
                managed.closeIfNeeded()
                continue
            }

            let task = Task { [weak self] in
                defer {
                    managed.closeIfNeeded()
                    self?.finishConnection(id: connectionID)
                }
                guard let self else { return }
                await self.handleConnection(managed)
            }

            let cancelledImmediately: Bool = {
                lock.lock()
                defer { lock.unlock() }
                if isStopped { return true }
                activeTasks[connectionID] = task
                return false
            }()
            if cancelledImmediately {
                managed.shutdown()
                task.cancel()
            }
        }
    }

    private func finishConnection(id: UUID) {
        lock.lock()
        activeSockets.removeValue(forKey: id)
        activeTasks.removeValue(forKey: id)
        lock.unlock()
    }

    private func handleConnection(_ socket: ManagedSocketFD) async {
        let headerBytes = await readRequestHeaders(from: socket)
        guard !Task.isCancelled, !headerBytes.isEmpty else { return }

        let responseData: Data
        switch Self.parseHTTPRequest(headerBytes) {
        case .valid(let request):
            responseData = await buildHTTPResponse(for: request)
        case .methodNotAllowed:
            responseData = Self.makeErrorResponse(
                statusCode: 405,
                reason: "Method Not Allowed",
                extraHeaders: ["Allow": "GET, HEAD"]
            )
        case .badRequest:
            responseData = Self.makeErrorResponse(statusCode: 400, reason: "Bad Request")
        }

        guard !Task.isCancelled else { return }
        await writeAll(responseData, to: socket)
    }

    private func buildHTTPResponse(for request: ParsedHTTPRequest) async -> Data {
        guard let upstreamURL = HAHLSPlaylistPolicy.upstreamURL(
            forRequestTarget: request.target,
            expectedToken: token,
            originURL: originURL
        ) else {
            return Self.makeErrorResponse(statusCode: 403, reason: "Forbidden")
        }

        do {
            try await validateAddress(upstreamURL)
            try Task.checkCancellation()
        } catch is HAEndpointResolutionError {
            return Self.makeErrorResponse(statusCode: 403, reason: "Forbidden")
        } catch {
            return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
        }

        let isKnownPlaylist = upstreamURL == originURL || HAHLSPlaylistPolicy.looksLikePlaylistURL(upstreamURL)
        let upstreamMethod = isKnownPlaylist ? "GET" : request.method.rawValue
        let initialRangeHeader: String? = (isKnownPlaylist || request.method == .head) ? nil : request.rangeHeader

        do {
            var fetched = try await fetchUpstream(
                url: upstreamURL,
                method: upstreamMethod,
                rangeHeader: initialRangeHeader,
                maxBytes: isKnownPlaylist ? HAHLSPlaylistPolicy.maxPlaylistBytes : Self.maxSegmentBytes
            )
            try Task.checkCancellation()

            var sentRange = initialRangeHeader
            var status = fetched.response.statusCode
            var finalURL = fetched.response.url ?? upstreamURL

            guard HAPlaintextConsent.hasSameOrigin(finalURL, as: originURL) else {
                return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
            }

            if let terminalError = Self.mappedUpstreamErrorResponse(statusCode: status) {
                return terminalError
            }
            guard status == 200 || status == 206 else {
                return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
            }

            var isPlaylist = HAHLSPlaylistPolicy.isPlaylistResponse(
                requestURL: upstreamURL,
                responseURL: finalURL,
                mimeType: fetched.response.mimeType,
                data: fetched.data
            )

            // Extensionless playlist probed with HEAD: refetch complete playlist via GET so it is
            // validated, rewritten, and served with exact rewritten Content-Length.
            if request.method == .head && !isKnownPlaylist && isPlaylist {
                try await validateAddress(upstreamURL)
                try Task.checkCancellation()
                fetched = try await fetchUpstream(
                    url: upstreamURL,
                    method: "GET",
                    rangeHeader: nil,
                    maxBytes: HAHLSPlaylistPolicy.maxPlaylistBytes
                )
                sentRange = nil
                status = fetched.response.statusCode
                finalURL = fetched.response.url ?? upstreamURL
                guard HAPlaintextConsent.hasSameOrigin(finalURL, as: originURL) else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
                if let terminalError = Self.mappedUpstreamErrorResponse(statusCode: status) {
                    return terminalError
                }
                guard status == 200 || status == 206 else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
                isPlaylist = true
            }

            // Extensionless playlist that received a 206 because Range was forwarded: refetch once without Range.
            if isPlaylist && status == 206 && sentRange != nil {
                try await validateAddress(upstreamURL)
                try Task.checkCancellation()
                fetched = try await fetchUpstream(
                    url: upstreamURL,
                    method: "GET",
                    rangeHeader: nil,
                    maxBytes: HAHLSPlaylistPolicy.maxPlaylistBytes
                )
                sentRange = nil
                status = fetched.response.statusCode
                finalURL = fetched.response.url ?? upstreamURL
                guard HAPlaintextConsent.hasSameOrigin(finalURL, as: originURL) else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
                if let terminalError = Self.mappedUpstreamErrorResponse(statusCode: status) {
                    return terminalError
                }
                guard status == 200 || status == 206 else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
            }

            if isPlaylist {
                if status == 206 {
                    guard HAHLSPlaylistPolicy.isCompleteFromZeroContentRange(
                        fetched.response.value(forHTTPHeaderField: "Content-Range"),
                        expectedByteCount: fetched.data.count
                    ) else {
                        return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                    }
                }
                let rewritten = try HAHLSPlaylistPolicy.rewritePlaylist(
                    data: fetched.data,
                    playlistURL: finalURL,
                    allowedOrigin: originURL,
                    relay: relayBase
                )
                return Self.makeHTTPResponse(
                    statusCode: 200,
                    reason: "OK",
                    headers: [
                        ("Content-Type", "application/vnd.apple.mpegurl"),
                        ("Content-Length", String(rewritten.count)),
                        ("Cache-Control", "no-store"),
                        ("Connection", "close"),
                    ],
                    body: request.method == .head ? Data() : rewritten
                )
            }

            // Non-playlist media segment, init map, or decryption key.
            let contentType = HAHLSPlaylistPolicy.sanitizedHeaderValue(
                fetched.response.value(forHTTPHeaderField: "Content-Type")
            ) ?? Self.inferredContentType(for: finalURL)
            let supportsByteRanges = fetched.response.value(forHTTPHeaderField: "Accept-Ranges")?
                .lowercased()
                .contains("bytes") == true

            if status == 206 {
                guard sentRange != nil,
                      let parsedRange = HAHLSPlaylistPolicy.parseContentRange(
                          fetched.response.value(forHTTPHeaderField: "Content-Range")
                      ) else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
                let expectedCount = (parsedRange.end - parsedRange.start) + 1
                guard Int64(fetched.data.count) == expectedCount else {
                    return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
                }
                let canonicalRange = HAHLSPlaylistPolicy.formatContentRange(
                    start: parsedRange.start,
                    end: parsedRange.end,
                    total: parsedRange.total
                )
                return Self.makeHTTPResponse(
                    statusCode: 206,
                    reason: "Partial Content",
                    headers: [
                        ("Content-Type", contentType),
                        ("Content-Range", canonicalRange),
                        ("Accept-Ranges", "bytes"),
                        ("Content-Length", String(fetched.data.count)),
                        ("Cache-Control", "no-store"),
                        ("Connection", "close"),
                    ],
                    body: request.method == .head ? Data() : fetched.data
                )
            }

            var headers: [(String, String)] = [("Content-Type", contentType)]
            if supportsByteRanges {
                headers.append(("Accept-Ranges", "bytes"))
            }
            if request.method == .head {
                if let rawLength = fetched.response.value(forHTTPHeaderField: "Content-Length"),
                   let parsedLength = Int64(rawLength.trimmingCharacters(in: .whitespaces)),
                   parsedLength >= 0 {
                    headers.append(("Content-Length", String(parsedLength)))
                } else if fetched.response.expectedContentLength >= 0 {
                    headers.append(("Content-Length", String(fetched.response.expectedContentLength)))
                }
            } else {
                headers.append(("Content-Length", String(fetched.data.count)))
            }
            headers.append(("Cache-Control", "no-store"))
            headers.append(("Connection", "close"))
            return Self.makeHTTPResponse(
                statusCode: 200,
                reason: "OK",
                headers: headers,
                body: request.method == .head ? Data() : fetched.data
            )
        } catch {
            return Self.makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
        }
    }

    private func fetchUpstream(
        url: URL,
        method: String,
        rangeHeader: String?,
        maxBytes: Int
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        return try await sessionDelegate.fetch(request: request, using: session, maxBytes: maxBytes)
    }

    private func readRequestHeaders(from socket: ManagedSocketFD) async -> Data {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                var collected = Data()
                var scratch = [UInt8](repeating: 0, count: 4096)
                let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
                while collected.count < Self.maxRequestHeaderBytes {
                    let count = socket.read(into: &scratch, maxLength: min(scratch.count, Self.maxRequestHeaderBytes - collected.count))
                    if count > 0 {
                        collected.append(contentsOf: scratch[0..<count])
                        if let range = collected.range(of: delimiter) {
                            continuation.resume(returning: collected.subdata(in: collected.startIndex..<range.upperBound))
                            return
                        }
                    } else if count == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func writeAll(_ data: Data, to socket: ManagedSocketFD) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else { return }
                    var offset = 0
                    while offset < rawBuffer.count {
                        let written = socket.write(base.advanced(by: offset), count: rawBuffer.count - offset)
                        if written > 0 {
                            offset += written
                        } else if written < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                }
                continuation.resume()
            }
        }
    }

    private enum HTTPRequestParseResult {
        case valid(ParsedHTTPRequest)
        case methodNotAllowed
        case badRequest
    }

    private struct ParsedHTTPRequest: Sendable {
        enum Method: String, Sendable {
            case get = "GET"
            case head = "HEAD"
        }
        let method: Method
        let target: String
        let rangeHeader: String?
    }

    private static func parseHTTPRequest(_ headerBytes: Data) -> HTTPRequestParseResult {
        guard let text = String(data: headerBytes, encoding: .isoLatin1),
              let terminatorRange = text.range(of: "\r\n\r\n") else {
            return .badRequest
        }
        let head = String(text[..<terminatorRange.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .badRequest
        }
        // Reject bare CR or LF inside any header line to block request smuggling.
        for line in lines {
            if line.contains("\r") || line.contains("\n") || line.utf8.contains(0) {
                return .badRequest
            }
        }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3 else {
            return .badRequest
        }
        let rawMethod = String(tokens[0])
        let target = String(tokens[1])
        let version = String(tokens[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .badRequest
        }
        let method: ParsedHTTPRequest.Method
        switch rawMethod {
        case "GET":
            method = .get
        case "HEAD":
            method = .head
        default:
            return .methodNotAllowed
        }

        var rangeHeader: String?
        var sawRange = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .badRequest
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
            if name == "range" {
                if sawRange {
                    return .badRequest
                }
                sawRange = true
                rangeHeader = HAHLSPlaylistPolicy.sanitizedRangeHeader(value)
            }
        }
        return .valid(ParsedHTTPRequest(method: method, target: target, rangeHeader: rangeHeader))
    }

    private static func mappedUpstreamErrorResponse(statusCode: Int) -> Data? {
        switch statusCode {
        case 404:
            return makeErrorResponse(statusCode: 404, reason: "Not Found")
        case 410:
            return makeErrorResponse(statusCode: 410, reason: "Gone")
        case 416:
            return makeErrorResponse(statusCode: 416, reason: "Range Not Satisfiable")
        case 300..<400:
            return makeErrorResponse(statusCode: 502, reason: "Bad Gateway")
        default:
            return nil
        }
    }

    private static func makeErrorResponse(
        statusCode: Int,
        reason: String,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var headers: [(String, String)] = extraHeaders.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        headers.append(("Content-Length", "0"))
        headers.append(("Cache-Control", "no-store"))
        headers.append(("Connection", "close"))
        return makeHTTPResponse(statusCode: statusCode, reason: reason, headers: headers, body: Data())
    }

    private static func makeHTTPResponse(
        statusCode: Int,
        reason: String,
        headers: [(String, String)],
        body: Data
    ) -> Data {
        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var response = Data(head.utf8)
        if !body.isEmpty {
            response.append(body)
        }
        return response
    }

    private static func inferredContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ts":
            return "video/mp2t"
        case "m4s", "mp4":
            return "video/mp4"
        case "m4a":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "m3u8", "m3u":
            return "application/vnd.apple.mpegurl"
        default:
            return "application/octet-stream"
        }
    }

    private static func makeRandomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeLoopbackListener() -> (fd: Int32, port: UInt16)? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &boundLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        guard nameResult == 0, port > 0 else {
            Darwin.close(fd)
            return nil
        }
        return (fd, port)
    }

    private static func configureClientSocket(_ fd: Int32) {
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var rcvTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
        var sndTimeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Ensures each accepted client file descriptor is shut down safely and closed exactly once.
private final class ManagedSocketFD: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        closeIfNeeded()
    }

    func shutdown() {
        lock.lock()
        let current = fd
        lock.unlock()
        if current >= 0 {
            _ = Darwin.shutdown(current, SHUT_RDWR)
        }
    }

    func closeIfNeeded() {
        let toClose: Int32 = {
            lock.lock()
            defer { lock.unlock() }
            let current = fd
            fd = -1
            return current
        }()
        if toClose >= 0 {
            Darwin.close(toClose)
        }
    }

    func read(into buffer: inout [UInt8], maxLength: Int) -> Int {
        lock.lock()
        let current = fd
        lock.unlock()
        guard current >= 0 else { return -1 }
        return buffer.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return -1 }
            return Darwin.read(current, ptr, maxLength)
        }
    }

    func write(_ pointer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        let current = fd
        lock.unlock()
        guard current >= 0 else { return -1 }
        return Darwin.write(current, pointer, count)
    }
}

/// Dedicated `URLSessionDataDelegate` for the loopback relay:
/// - Always delegates redirect decisions to `HARedirectBlockingDelegate.shared`
/// - Rejects `3xx` responses (blocked redirects) and oversized bodies before buffering OOM
private final class RelayURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        let maxBytes: Int
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var response: HTTPURLResponse?
        var data = Data()
        var customError: Error?
        var effectiveMaxBytes: Int

        init(maxBytes: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.maxBytes = maxBytes
            self.effectiveMaxBytes = maxBytes
            self.continuation = continuation
        }
    }

    private let maxPlaylistBytes: Int
    private let maxSegmentBytes: Int
    private let lock = NSLock()
    private var isInvalidated = false
    private var states: [Int: TaskState] = [:]

    init(maxPlaylistBytes: Int, maxSegmentBytes: Int) {
        self.maxPlaylistBytes = maxPlaylistBytes
        self.maxSegmentBytes = maxSegmentBytes
        super.init()
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        lock.unlock()
    }

    func fetch(
        request: URLRequest,
        using session: URLSession,
        maxBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = TaskState(maxBytes: min(maxBytes, maxSegmentBytes), continuation: continuation)
                let rejected: Bool = {
                    lock.lock()
                    defer { lock.unlock() }
                    if isInvalidated { return true }
                    states[task.taskIdentifier] = state
                    return false
                }()
                if rejected {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        HARedirectBlockingDelegate.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            recordFailure(taskID: dataTask.taskIdentifier, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        if (300..<400).contains(http.statusCode) {
            recordFailure(taskID: dataTask.taskIdentifier, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let isPlaylistMIME = HAHLSPlaylistPolicy.isPlaylistMIME(http.mimeType)
        let allowed: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard let state = states[dataTask.taskIdentifier] else { return false }
            state.response = http
            if isPlaylistMIME {
                state.effectiveMaxBytes = min(state.maxBytes, maxPlaylistBytes)
            }
            if http.expectedContentLength > Int64(state.effectiveMaxBytes) {
                state.customError = HAHLSPlaylistError.oversizedPlaylist
                return false
            }
            return true
        }()
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard let state = states[dataTask.taskIdentifier] else { return false }
            let (nextCount, overflow) = state.data.count.addingReportingOverflow(data.count)
            if overflow || nextCount > state.effectiveMaxBytes {
                state.customError = HAHLSPlaylistError.oversizedPlaylist
                return true
            }
            state.data.append(data)
            return false
        }()
        if exceeded {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state: TaskState? = {
            lock.lock()
            defer { lock.unlock() }
            return states.removeValue(forKey: task.taskIdentifier)
        }()
        guard let state else { return }
        if let customError = state.customError {
            state.continuation.resume(throwing: customError)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    private func recordFailure(taskID: Int, error: Error) {
        lock.lock()
        states[taskID]?.customError = error
        lock.unlock()
    }
}
