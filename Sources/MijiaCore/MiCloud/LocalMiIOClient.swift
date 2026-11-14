import Foundation
import os
#if canImport(Network)
import Network
#endif

// MARK: - UDP Transport Seam

public protocol MiIOUDPTransport: Sendable {
    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data
    func shutdown() async
}

extension MiIOUDPTransport {
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
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MiIOError.invalidAddress(host)
        }
        let callID = UUID()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)

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

    private struct DeviceSession: Sendable {
        var ip: String
        var tokenData: Data
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
        await transport.shutdown()
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

    private func validatedHost(_ ip: String) throws -> String {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MiIOError.invalidAddress(ip) }
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
        let header = try MiIOPacket.decodeHeader(response)
        let deviceId32: UInt32
        if header.deviceId != 0 && header.deviceId != UInt32.max {
            deviceId32 = header.deviceId
        } else if let numericDid = UInt32(did) {
            deviceId32 = numericDid
        } else {
            throw MiIOError.unsupportedNonNumericDeviceId
        }
        let session = DeviceSession(
            ip: host,
            tokenData: tokenData,
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
            payload: payloadData
        )
        let json: JSONValue
        do {
            let responsePacket = try await transport.send(packet, to: host, port: port, timeout: requestTimeout)
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
                throw MiCloudError.deviceError(code: code, message: "设备未响应或离线")
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
