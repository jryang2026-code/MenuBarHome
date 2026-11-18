import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Network)
import Network
#endif

// MARK: - UDP Transport Seam

public struct MiIOBroadcastReply: Equatable, Sendable {
    public var sourceIP: String
    public var packet: Data
    public init(sourceIP: String, packet: Data) { self.sourceIP = sourceIP; self.packet = packet }
}

public struct MiIODeviceCandidate: Equatable, Sendable {
    public var did: String
    public var token: String
    public init(did: String, token: String) { self.did = did; self.token = token }
}

public protocol MiIOUDPTransport: Sendable {
    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data
    func probeBroadcast(_ packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply]
    func shutdown() async
}

extension MiIOUDPTransport {
    public func probeBroadcast(_ packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply] { [] }
    public func shutdown() async {}
}

#if canImport(Network)
public actor NWConnectionMiIOUDPTransport: MiIOUDPTransport {
    private final class PendingCall: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var connection: NWConnection?
        private var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Data, any Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func attachTimeout(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyDone = continuation == nil
            if !alreadyDone {
                timeoutTask = task
            }
            lock.unlock()
            if alreadyDone {
                task.cancel()
            }
        }

        func succeed(_ data: Data) {
            finish(with: .success(data))
        }

        func fail(_ error: any Error) {
            finish(with: .failure(error))
        }

        private func finish(with result: Result<Data, any Error>) {
            lock.lock()
            let cont = continuation
            let conn = connection
            let timer = timeoutTask
            continuation = nil
            connection = nil
            timeoutTask = nil
            lock.unlock()

            timer?.cancel()
            conn?.stateUpdateHandler = nil
            conn?.cancel()
            cont?.resume(with: result)
        }
    }

    private let queue = DispatchQueue(label: "com.jryang1997.MenuBarMijia.LocalMiIO.UDP")
    private var pending: [UUID: PendingCall] = [:]
    private var isShutDown = false

    public init() {}

    public func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalMiIOClient.isPrivateRFC1918IPv4(trimmedHost),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MiIOError.invalidAddress(host)
        }
        let callID = UUID()
        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .udp)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                let call = PendingCall(continuation: cont, connection: connection)
                self.register(call, id: callID)
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutCall(id: callID)
                }
                call.attachTimeout(timer)
                let complete: @Sendable (Result<Data, any Error>) -> Void = { [weak self] result in
                    switch result {
                    case .success(let data):
                        call.succeed(data)
                    case .failure(let error):
                        call.fail(error)
                    }
                    if let actor = self {
                        Task { await actor.removeCall(id: callID) }
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: packet, completion: .contentProcessed { sendError in
                            if let sendError {
                                complete(.failure(sendError))
                                return
                            }
                            connection.receiveMessage { content, _, _, receiveError in
                                if let receiveError {
                                    complete(.failure(receiveError))
                                    return
                                }
                                guard let content, !content.isEmpty else {
                                    complete(.failure(MiIOError.malformedPacket))
                                    return
                                }
                                complete(.success(content))
                            }
                        })
                    case .failed(let err):
                        complete(.failure(err))
                    case .cancelled:
                        complete(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            Task { await self.failCall(id: callID, error: CancellationError()) }
        }
    }

    public func probeBroadcast(_ packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply] {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        #if canImport(Darwin)
        return try await DarwinBSDMiIOBroadcastScanner.probeBroadcast(packet: packet, port: port, timeout: timeout)
        #else
        return []
        #endif
    }

    private func register(_ call: PendingCall, id: UUID) {
        if isShutDown {
            call.fail(MiIOError.shutDown)
            return
        }
        pending[id] = call
    }

    private func removeCall(id: UUID) {
        pending.removeValue(forKey: id)
    }

    private func timeoutCall(id: UUID) {
        if let call = pending.removeValue(forKey: id) {
            call.fail(MiIOError.timeout)
        }
    }

    private func failCall(id: UUID, error: any Error) {
        if let call = pending.removeValue(forKey: id) {
            call.fail(error)
        }
    }

    public func shutdown() async {
        isShutDown = true
        let active = Array(pending.values)
        pending.removeAll()
        for call in active {
            call.fail(MiIOError.shutDown)
        }
    }
}
#endif

#if canImport(Darwin)
enum DarwinBSDMiIOBroadcastScanner {
    private static let broadcastQueue = DispatchQueue(label: "com.jryang1997.MenuBarMijia.LocalMiIO.Broadcast", qos: .utility, attributes: .concurrent)

    static func directedBroadcastIP(address: String, netmask: String) -> String? {
        var addr = in_addr(), mask = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1, inet_pton(AF_INET, netmask, &mask) == 1 else { return nil }
        let hostAddr = UInt32(bigEndian: addr.s_addr), hostMask = UInt32(bigEndian: mask.s_addr)
        return (hostMask != 0 && hostMask != UInt32.max) ? ipv4String(from: in_addr(s_addr: ((hostAddr & hostMask) | ~hostMask).bigEndian)) : nil
    }

    static func isValidBroadcastResponderIP(_ sourceIP: String, localIPs: Set<String>, broadcastIPs: Set<String>) -> Bool {
        let t = sourceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return t != "255.255.255.255" && t != "0.0.0.0" && !localIPs.contains(t) && !broadcastIPs.contains(t) && LocalMiIOClient.isPrivateRFC1918IPv4(t)
    }

    static func probeBroadcast(packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply] {
        try Task.checkCancellation()
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                broadcastQueue.async {
                    if cancelFlag.withLock({ $0 }) { cont.resume(throwing: CancellationError()); return }
                    do { cont.resume(returning: try performBlockingBroadcast(packet: packet, port: port, timeout: timeout, cancelFlag: cancelFlag)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { cancelFlag.withLock { $0 = true } }
    }

    private static func performBlockingBroadcast(packet: Data, port: UInt16, timeout: Duration, cancelFlag: OSAllocatedUnfairLock<Bool>) throws -> [MiIOBroadcastReply] {
        var localIPs: Set<String> = ["0.0.0.0", "127.0.0.1"], broadcastIPs: Set<String> = ["255.255.255.255"]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            defer { freeifaddrs(first) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = cursor?.pointee {
                defer { cursor = ifa.ifa_next }
                let flags = Int32(ifa.ifa_flags)
                guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, let addrPtr = ifa.ifa_addr, Int32(addrPtr.pointee.sa_family) == AF_INET,
                      let ipString = ipv4String(from: UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr),
                      LocalMiIOClient.isPrivateRFC1918IPv4(ipString) else { continue }
                localIPs.insert(ipString)
                if let maskPtr = ifa.ifa_netmask, Int32(maskPtr.pointee.sa_family) == AF_INET,
                   let maskString = ipv4String(from: UnsafeRawPointer(maskPtr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr),
                   let directed = directedBroadcastIP(address: ipString, netmask: maskString) { broadcastIPs.insert(directed) }
                if (flags & IFF_BROADCAST) != 0, let dstPtr = ifa.ifa_dstaddr, Int32(dstPtr.pointee.sa_family) == AF_INET,
                   let bcast = ipv4String(from: UnsafeRawPointer(dstPtr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr) { broadcastIPs.insert(bcast) }
            }
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiIOError.transportUnavailable }
        defer { Darwin.close(fd) }
        var broadcastOn: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let packetBytes = [UInt8](packet)
        var sentCount = 0
        for target in broadcastIPs.sorted() {
            var dst = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian, sin_addr: in_addr(), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            guard inet_pton(AF_INET, target, &dst.sin_addr) == 1 else { continue }
            let sent = packetBytes.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, rawBuf.baseAddress, packetBytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            if sent >= 0 { sentCount += 1 }
        }
        if sentCount == 0 { return [] }
        let deadline = ContinuousClock.now + .milliseconds(max(1, Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)))
        var replies: [MiIOBroadcastReply] = [], seenSources: Set<String> = [], buf = [UInt8](repeating: 0, count: 2048)
        while !cancelFlag.withLock({ $0 }) {
            let rem = deadline - ContinuousClock.now
            let remMs = Int(rem.components.seconds) * 1000 + Int(rem.components.attoseconds / 1_000_000_000_000_000)
            if remMs <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(50, max(1, remMs))))
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 || (pfd.revents & Int16(POLLIN)) == 0 { continue }
            while true {
                var srcAddr = sockaddr_in(), srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBytes { rawBuf in
                    withUnsafeMutablePointer(to: &srcAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, rawBuf.baseAddress, rawBuf.count, 0, $0, &srcLen) } }
                }
                if n <= 0 { break }
                guard n >= MiIOPacket.headerSize, let sourceIP = ipv4String(from: srcAddr.sin_addr),
                      isValidBroadcastResponderIP(sourceIP, localIPs: localIPs, broadcastIPs: broadcastIPs),
                      seenSources.insert(sourceIP).inserted else { continue }
                replies.append(MiIOBroadcastReply(sourceIP: sourceIP, packet: Data(buf.prefix(n))))
            }
        }
        if cancelFlag.withLock({ $0 }) { throw CancellationError() }
        return replies
    }

    private static func ipv4String(from addr: in_addr) -> String? {
        var copy = addr, buffer = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : nil
    }
}
#endif

private struct UnavailableMiIOUDPTransport: MiIOUDPTransport {
    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        throw MiIOError.transportUnavailable
    }
}

// MARK: - Device Endpoint & Handshake Types

public struct MiIODeviceEndpoint: Equatable, Sendable {
    public var did: String
    public var ip: String
    public var token: String

    public init(did: String, ip: String, token: String) {
        self.did = did
        self.ip = ip
        self.token = token
    }
}

public struct MiIOHandshakeInfo: Equatable, Sendable {
    public var deviceId32: UInt32
    public var deviceStamp: UInt32
    public var handshakeAt: Date

    public init(deviceId32: UInt32, deviceStamp: UInt32, handshakeAt: Date) {
        self.deviceId32 = deviceId32
        self.deviceStamp = deviceStamp
        self.handshakeAt = handshakeAt
    }
}

// MARK: - LocalMiIOClient

/// Actor managing local miIO UDP (port 54321) handshakes, stamp skew tracking, serial
/// per-device request queues, MTU-safe chunking, and AES-128-CBC packet exchange.
public actor LocalMiIOClient {
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "LocalMiIO")
    private let transport: any MiIOUDPTransport
    private let port: UInt16
    private let requestTimeout: Duration
    private let handshakeTimeout: Duration
    private let maxRetries: Int
    private let handshakeTTL: TimeInterval
    private let maxBatchSize: Int
    private let now: @Sendable () -> Date

    private struct HardwareDeviceID: Equatable, Sendable {
        var unknown: UInt32
        var deviceId: UInt32

        func matches(_ header: MiIOPacketHeader) -> Bool {
            let headerUnknown = header.unknown == UInt32.max ? 0 : header.unknown
            return header.deviceId == deviceId && headerUnknown == unknown
        }
    }

    private struct DeviceSession: Sendable {
        var ip: String
        var tokenData: Data
        var unknown: UInt32
        var deviceId32: UInt32
        var baseStamp: UInt32
        var handshakeAt: Date
        var lastSentStamp: UInt32?

        mutating func nextStamp(at currentTime: Date) -> UInt32 {
            let rawDelta = currentTime.timeIntervalSince(handshakeAt)
            let clampedSeconds = rawDelta.isFinite && rawDelta > 0 ? min(rawDelta, Double(UInt32.max)) : 0
            let elapsed = UInt32(clampedSeconds.rounded(.towardZero))
            let computed = baseStamp &+ elapsed
            let stamp: UInt32
            if let prev = lastSentStamp, computed <= prev {
                stamp = prev &+ 1
            } else {
                stamp = computed
            }
            lastSentStamp = stamp
            return stamp
        }
    }

    private var sessions: [String: DeviceSession] = [:]
    private var knownHardwareIdsByDid: [String: HardwareDeviceID] = [:]
    private var lastRTTMsByDid: [String: Int] = [:]
    private var commandTails: [String: Task<Void, Never>] = [:]
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
    private var nextRequestId: Int = 100
    private var isShutDown = false

    public static func defaultTransport() -> any MiIOUDPTransport {
        #if canImport(Network)
        return NWConnectionMiIOUDPTransport()
        #else
        return UnavailableMiIOUDPTransport()
        #endif
    }

    public init(
        transport: any MiIOUDPTransport = LocalMiIOClient.defaultTransport(),
        port: UInt16 = 54321,
        requestTimeout: Duration = .milliseconds(1200),
        handshakeTimeout: Duration = .milliseconds(1000),
        maxRetries: Int = 1,
        handshakeTTL: TimeInterval = 120,
        maxBatchSize: Int = MiIOPacket.defaultMaxBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.port = port
        self.requestTimeout = requestTimeout
        self.handshakeTimeout = handshakeTimeout
        self.maxRetries = max(0, maxRetries)
        self.handshakeTTL = max(1, handshakeTTL)
        self.maxBatchSize = min(14, max(10, maxBatchSize))
        self.now = now
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        for tail in commandTails.values {
            tail.cancel()
        }
        commandTails.removeAll()
        sessions.removeAll()
        knownHardwareIdsByDid.removeAll()
        lastRTTMsByDid.removeAll()
        await transport.shutdown()
    }

    public func lastRoundTripMs(for did: String) -> Int? { lastRTTMsByDid[did] }

    public func discoverEndpoints(
        for candidates: [MiIODeviceCandidate], broadcastTimeout: Duration = .milliseconds(650)
    ) async throws -> [String: String] {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        var validCandidates: [(did: String, tokenData: Data)] = [], seenDids: Set<String> = []
        for c in candidates where !c.did.isEmpty && seenDids.insert(c.did).inserted {
            if let tokenData = MiIOPacket.validateToken(c.token) { validCandidates.append((c.did, tokenData)) }
        }
        guard !validCandidates.isEmpty else { return [:] }
        let replies = try await transport.probeBroadcast(MiIOPacket.helloPacket, port: port, timeout: broadcastTimeout)
        guard !isShutDown else { throw MiIOError.shutDown }
        var parsedReplies: [(sourceIP: String, packet: Data, header: MiIOPacketHeader)] = [], seenReplyIPs: Set<String> = []
        for reply in replies {
            let ip = reply.sourceIP.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ip != "255.255.255.255", Self.isPrivateRFC1918IPv4(ip), seenReplyIPs.insert(ip).inserted,
                  let header = try? MiIOPacket.decodeHeader(reply.packet), header.deviceId != 0, header.deviceId != UInt32.max else { continue }
            parsedReplies.append((ip, reply.packet, header))
        }
        guard !parsedReplies.isEmpty else { return [:] }

        var discovered: [String: String] = [:], claimedIPs: Set<String> = []
        for candidate in validCandidates {
            let matching = parsedReplies.filter { r in
                guard !claimedIPs.contains(r.sourceIP) else { return false }
                if let known = knownHardwareIdsByDid[candidate.did], known.matches(r.header) { return true }
                guard let did64 = UInt64(candidate.did) else { return false }
                return r.header.deviceId64 == did64 || ((r.header.unknown == 0 || r.header.unknown == UInt32.max) && UInt32(exactly: did64) == r.header.deviceId)
            }
            for reply in matching {
                try Task.checkCancellation()
                if try await verifyBroadcastCandidate(did: candidate.did, tokenData: candidate.tokenData, sourceIP: reply.sourceIP, packet: reply.packet, header: reply.header) {
                    discovered[candidate.did] = reply.sourceIP; claimedIPs.insert(reply.sourceIP); break
                }
            }
        }
        var unclaimedProbesRemaining = 8
        for candidate in validCandidates where discovered[candidate.did] == nil && UInt64(candidate.did) == nil && knownHardwareIdsByDid[candidate.did] == nil {
            for reply in parsedReplies where !claimedIPs.contains(reply.sourceIP) && unclaimedProbesRemaining > 0 {
                if MiIOPacket.helloChecksumMatches(reply.packet, token: candidate.tokenData) == false { continue }
                unclaimedProbesRemaining -= 1
                try Task.checkCancellation()
                if try await verifyBroadcastCandidate(did: candidate.did, tokenData: candidate.tokenData, sourceIP: reply.sourceIP, packet: reply.packet, header: reply.header) {
                    discovered[candidate.did] = reply.sourceIP; claimedIPs.insert(reply.sourceIP); break
                }
            }
        }
        return discovered
    }

    private func verifyBroadcastCandidate(
        did: String, tokenData: Data, sourceIP: String, packet: Data, header: MiIOPacketHeader
    ) async throws -> Bool {
        if MiIOPacket.helloChecksumMatches(packet, token: tokenData) == false { return false }
        let reqId = allocateRequestId(), resolvedUnknown = header.unknown == UInt32.max ? 0 : header.unknown, probeStamp = header.stamp &+ 1
        let rpc: JSONValue = .object(["id": .number(Double(reqId)), "method": .string("get_properties"), "params": .array([.object(["did": .string(did), "siid": .number(1), "piid": .number(1)])])])
        let probePacket = try MiIOPacket.encode(deviceId: header.deviceId, stamp: probeStamp, token: tokenData, payload: Data(rpc.compactJSONString.utf8), unknown: resolvedUnknown)
        let sendStart = ContinuousClock.now, responsePacket: Data
        do { responsePacket = try await transport.send(probePacket, to: sourceIP, port: port, timeout: handshakeTimeout) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        guard !isShutDown else { throw MiIOError.shutDown }
        guard let (respHeader, plaintext) = try? MiIOPacket.decode(responsePacket, token: tokenData),
              let rawText = String(data: plaintext, encoding: .utf8) else { return false }
        let cleaned = cleanMalformedFirmwareJSON(rawText)
        guard !cleaned.isEmpty, let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(cleaned.utf8)),
              decoded["id"]?.intValue == reqId else { return false }
        lastRTTMsByDid[did] = Self.milliseconds(since: sendStart)
        knownHardwareIdsByDid[did] = HardwareDeviceID(unknown: resolvedUnknown, deviceId: header.deviceId)
        sessions[did] = DeviceSession(ip: sourceIP, tokenData: tokenData, unknown: resolvedUnknown, deviceId32: header.deviceId, baseStamp: respHeader.stamp, handshakeAt: now(), lastSentStamp: probeStamp)
        return true
    }

    public func handshake(for endpoint: MiIODeviceEndpoint) async throws -> MiIOHandshakeInfo {
        let tokenData = try validatedToken(endpoint.token)
        let host = try validatedHost(endpoint.ip)
        return try await enqueueSerialized(did: endpoint.did) {
            let session = try await self.performHandshake(did: endpoint.did, host: host, tokenData: tokenData)
            return MiIOHandshakeInfo(
                deviceId32: session.deviceId32,
                deviceStamp: session.baseStamp,
                handshakeAt: session.handshakeAt
            )
        }
    }

    public func getProps(_ keys: [MiotPropKey], endpoint: MiIODeviceEndpoint) async throws -> [MiotPropKey: JSONValue] {
        guard !keys.isEmpty else { return [:] }
        let tokenData = try validatedToken(endpoint.token)
        let host = try validatedHost(endpoint.ip)
        let chunks = MiIOPacket.chunked(keys, maxBatchSize: maxBatchSize)
        return try await enqueueSerialized(did: endpoint.did) {
            var values: [MiotPropKey: JSONValue] = [:]
            for chunk in chunks {
                try Task.checkCancellation()
                let params: [JSONValue] = chunk.map {
                    .object([
                        "did": .string($0.did),
                        "siid": .number(Double($0.siid)),
                        "piid": .number(Double($0.piid)),
                    ])
                }
                let result = try await self.sendWithRetry(
                    did: endpoint.did,
                    host: host,
                    tokenData: tokenData,
                    method: "get_properties",
                    params: .array(params)
                )
                values.merge(Self.parsePropValues(result, defaultDid: endpoint.did)) { _, new in new }
            }
            return values
        }
    }

    public func setProps(_ writes: [MiotPropWrite], endpoint: MiIODeviceEndpoint) async throws {
        guard !writes.isEmpty else { return }
        let tokenData = try validatedToken(endpoint.token)
        let host = try validatedHost(endpoint.ip)
        let chunks = MiIOPacket.chunked(writes, maxBatchSize: maxBatchSize)
        try await enqueueSerialized(did: endpoint.did) {
            for chunk in chunks {
                try Task.checkCancellation()
                let params: [JSONValue] = chunk.map {
                    .object([
                        "did": .string($0.did),
                        "siid": .number(Double($0.siid)),
                        "piid": .number(Double($0.piid)),
                        "value": $0.value,
                    ])
                }
                let result = try await self.sendWithRetry(
                    did: endpoint.did,
                    host: host,
                    tokenData: tokenData,
                    method: "set_properties",
                    params: .array(params)
                )
                try Self.checkWriteCodes(result.arrayValue ?? [])
            }
        }
    }

    public func callAction(_ call: MiotActionCall, endpoint: MiIODeviceEndpoint) async throws -> JSONValue {
        let tokenData = try validatedToken(endpoint.token)
        let host = try validatedHost(endpoint.ip)
        return try await enqueueSerialized(did: endpoint.did) {
            let params: JSONValue = .object([
                "did": .string(call.did),
                "siid": .number(Double(call.siid)),
                "aiid": .number(Double(call.aiid)),
                "in": .array(call.inputs),
            ])
            let result = try await self.sendWithRetry(
                did: endpoint.did,
                host: host,
                tokenData: tokenData,
                method: "action",
                params: params,
                allowPostSendRetry: false
            )
            if case .array(let items) = result {
                try Self.checkWriteCodes(items)
            } else {
                try Self.checkWriteCodes([result])
            }
            return result
        }
    }

    static func parsePropValues(_ result: JSONValue, defaultDid: String) -> [MiotPropKey: JSONValue] {
        var values: [MiotPropKey: JSONValue] = [:]
        for item in result.arrayValue ?? [] {
            let did = item["did"]?.idString ?? defaultDid
            guard let siid = item["siid"]?.intValue,
                  let piid = item["piid"]?.intValue,
                  item["code"].map({ $0.intValue == 0 }) ?? true,
                  let value = item["value"],
                  value != .null else { continue }
            values[MiotPropKey(did: did, siid: siid, piid: piid)] = value
        }
        return values
    }

    // MARK: - Internal Serialization & Handshake

    private func validatedToken(_ hex: String) throws -> Data {
        guard let tokenData = MiIOPacket.validateToken(hex) else {
            throw MiIOError.invalidToken
        }
        return tokenData
    }

    public static func isPrivateRFC1918IPv4(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(part.count > 1 && part.first == "0"),
                  let value = Int(part),
                  (0...255).contains(value) else {
                return false
            }
            octets.append(value)
        }
        let a = octets[0]
        let b = octets[1]
        return a == 2 * 5
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
    }

    private func validatedHost(_ ip: String) throws -> String {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPrivateRFC1918IPv4(trimmed) else { throw MiIOError.invalidAddress(ip) }
        return trimmed
    }

    private func enqueueSerialized<T: Sendable>(
        did: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        let previous = commandTails[did]
        let taskID = UUID()
        let current = Task<T, any Error> {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await operation()
        }
        let tracker = Task<Void, Never> {
            _ = await current.result
        }
        commandTails[did] = tracker
        inFlightTasks[taskID] = tracker
        defer {
            inFlightTasks.removeValue(forKey: taskID)
        }
        return try await withTaskCancellationHandler {
            try await current.value
        } onCancel: {
            current.cancel()
        }
    }

    private func ensureSession(did: String, host: String, tokenData: Data) async throws -> DeviceSession {
        let currentTime = now()
        if let existing = sessions[did],
           existing.ip == host,
           existing.tokenData == tokenData,
           currentTime.timeIntervalSince(existing.handshakeAt) >= 0,
           currentTime.timeIntervalSince(existing.handshakeAt) < handshakeTTL {
            return existing
        }
        return try await performHandshake(did: did, host: host, tokenData: tokenData)
    }

    private func performHandshake(did: String, host: String, tokenData: Data) async throws -> DeviceSession {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        let start = ContinuousClock.now
        let response: Data
        do {
            response = try await transport.send(MiIOPacket.helloPacket, to: host, port: port, timeout: handshakeTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MiIOError {
            throw error == .transportUnavailable ? error : MiIOError.handshakeFailed
        } catch {
            throw MiIOError.handshakeFailed
        }
        guard !isShutDown else { throw MiIOError.shutDown }
        lastRTTMsByDid[did] = Self.milliseconds(since: start)
        let header = try MiIOPacket.decodeHeader(response)
        let (resolvedUnknown, deviceId32): (UInt32, UInt32)
        if header.deviceId != 0 && header.deviceId != UInt32.max {
            (resolvedUnknown, deviceId32) = (header.unknown == UInt32.max ? 0 : header.unknown, header.deviceId)
        } else if let numericDid32 = UInt32(did) {
            (resolvedUnknown, deviceId32) = (0, numericDid32)
        } else if let numericDid64 = UInt64(did) {
            (resolvedUnknown, deviceId32) = (UInt32(truncatingIfNeeded: numericDid64 >> 32), UInt32(truncatingIfNeeded: numericDid64))
        } else if let known = knownHardwareIdsByDid[did] {
            (resolvedUnknown, deviceId32) = (known.unknown, known.deviceId)
        } else {
            throw MiIOError.unsupportedNonNumericDeviceId
        }
        knownHardwareIdsByDid[did] = HardwareDeviceID(unknown: resolvedUnknown, deviceId: deviceId32)
        let session = DeviceSession(
            ip: host,
            tokenData: tokenData,
            unknown: resolvedUnknown,
            deviceId32: deviceId32,
            baseStamp: header.stamp,
            handshakeAt: now(),
            lastSentStamp: nil
        )
        sessions[did] = session
        return session
    }

    private func sendWithRetry(
        did: String,
        host: String,
        tokenData: Data,
        method: String,
        params: JSONValue,
        allowPostSendRetry: Bool = true
    ) async throws -> JSONValue {
        var lastError: any Error = MiIOError.timeout
        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            guard !isShutDown else { throw MiIOError.shutDown }
            do {
                return try await sendOnce(
                    did: did,
                    host: host,
                    tokenData: tokenData,
                    method: method,
                    params: params,
                    allowPostSendRetry: allowPostSendRetry
                )
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < maxRetries else {
                    throw error
                }
                // Clear cached session so the retry re-handshakes and refreshes stamp skew.
                sessions.removeValue(forKey: did)
                logger.notice("Retrying local miIO \(method, privacy: .public) for \(did, privacy: .public) after error: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError
    }

    private func sendOnce(
        did: String,
        host: String,
        tokenData: Data,
        method: String,
        params: JSONValue,
        allowPostSendRetry: Bool
    ) async throws -> JSONValue {
        var session = try await ensureSession(did: did, host: host, tokenData: tokenData)
        let stamp = session.nextStamp(at: now())
        sessions[did] = session

        let reqId = allocateRequestId()
        let rpc: JSONValue = .object([
            "id": .number(Double(reqId)),
            "method": .string(method),
            "params": params,
        ])
        let payloadData = Data(rpc.compactJSONString.utf8)
        let packet = try MiIOPacket.encode(
            deviceId: session.deviceId32,
            stamp: stamp,
            token: tokenData,
            payload: payloadData,
            unknown: session.unknown
        )
        let json: JSONValue
        let sendStart = ContinuousClock.now
        do {
            let responsePacket = try await transport.send(packet, to: host, port: port, timeout: requestTimeout)
            if !isShutDown { lastRTTMsByDid[did] = Self.milliseconds(since: sendStart) }
            let (_, responsePlaintext) = try MiIOPacket.decode(responsePacket, token: tokenData)
            guard let rawText = String(data: responsePlaintext, encoding: .utf8) else {
                throw MiIOError.malformedPacket
            }
            let cleaned = cleanMalformedFirmwareJSON(rawText)
            guard !cleaned.isEmpty,
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(cleaned.utf8)) else {
                throw MiIOError.malformedPacket
            }
            json = decoded
        } catch {
            if !allowPostSendRetry {
                if error is CancellationError || error is MiCloudError {
                    throw error
                }
                if let miio = error as? MiIOError, miio == .transportUnavailable {
                    throw error
                }
                // Clear session after ambiguous UDP send/reply loss so the next request re-handshakes,
                // without automatically replaying a potentially executed action.
                sessions.removeValue(forKey: did)
                throw MiIOError.ambiguousActionOutcome
            }
            throw error
        }
        if let respId = json["id"]?.intValue, respId != reqId {
            if !allowPostSendRetry {
                sessions.removeValue(forKey: did)
                throw MiIOError.ambiguousActionOutcome
            }
            throw MiIOError.malformedPacket
        }
        if let errObj = json["error"], case .object = errObj {
            let code = errObj["code"]?.intValue ?? -1
            let message = errObj["message"]?.stringValue ?? "device error"
            throw MiCloudError.deviceError(code: code, message: message)
        }
        return json["result"] ?? .null
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return max(1, Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    private func allocateRequestId() -> Int {
        nextRequestId += 1
        if nextRequestId > 999_999_999 {
            nextRequestId = 100
        }
        return nextRequestId
    }

    private static func checkWriteCodes(_ items: [JSONValue]) throws {
        for item in items {
            let code = item["code"]?.intValue ?? 0
            if code < 0 {
                throw MiCloudError.deviceError(
                    code: code,
                    message: L10n.tr("设备未响应或离线", "Device did not respond or is offline")
                )
            }
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if error is MiCloudError { return false }
        if let miio = error as? MiIOError {
            switch miio {
            case .timeout, .handshakeFailed, .malformedPacket:
                return true
            case .invalidToken, .invalidAddress, .payloadTooLarge, .checksumMismatch,
                 .unsupportedNonNumericDeviceId, .shutDown, .encryptionFailed,
                 .decryptionFailed, .transportUnavailable, .ambiguousActionOutcome, .deviceError:
                return false
            }
        }
        return true
    }
}
