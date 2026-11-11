import Foundation

/// The bridge allocates one session per drag and a process-scoped epoch. A late request from an
/// old session can never start a motor again, even after the bridge restarted.
public struct CameraPTZSessionToken: Equatable, Sendable {
    public var epoch: String
    public var session: UInt64

    public init(epoch: String, session: UInt64) {
        self.epoch = epoch
        self.session = session
    }
}

/// Result of asking the bridge to stop a move. The camera has no trusted motor acknowledgement,
/// so `confirmed` is always false until hardware verification says otherwise.
public struct CameraPTZStopResult: Equatable, Sendable {
    public var sent: Bool
    public var confirmed: Bool
    /// A step-mode camera needs no stop operation, so `sent == false` there is expected.
    public var mode: CameraPTZMotionMode?
    /// The bridge accepted the request but the write to the camera failed.
    public var errorReason: String?

    /// A later retry may clear a failed write only when this stop actually sent `-1001`.
    /// A missing `stopError` with `sent == false` is how an old session reports a no-op.
    public var clearsFailedWrite: Bool {
        errorReason == nil && sent
    }

    public init(
        sent: Bool,
        confirmed: Bool = false,
        mode: CameraPTZMotionMode? = nil,
        errorReason: String? = nil
    ) {
        self.sent = sent
        self.confirmed = confirmed
        self.mode = mode
        self.errorReason = errorReason
    }
}

/// Which failed-stop attempts remain after a later stop on the same camera.
public enum CameraPTZFailureResolution {
    /// A stop that sent `-1001` proves the motor stopped, so older failures for
    /// that camera are finished. A not-sent reply leaves every attempt in place.
    public static func remainingDeviceIds(
        unresolvedDeviceIds: [String],
        stoppedDeviceId: String?,
        result: CameraPTZStopResult
    ) -> [String] {
        guard result.clearsFailedWrite, let stoppedDeviceId else {
            return unresolvedDeviceIds
        }
        return unresolvedDeviceIds.filter { $0 != stoppedDeviceId }
    }
}

public enum CameraPTZClientError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case rejected
    /// The bridge has no active session, the session ended, or the sequence is stale.
    case staleSession
    /// The bridge restarted; its epoch no longer matches.
    case bridgeChanged
    case network

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.tr("本地云台桥不可用", "Local PTZ bridge is unavailable")
        case .rejected:
            return L10n.tr("云台指令被拒绝", "PTZ command was rejected")
        case .staleSession:
            return L10n.tr("云台会话已结束，请重新拖动", "PTZ session ended; drag again")
        case .bridgeChanged:
            return L10n.tr("流媒体桥已重启，请重新拖动", "Streaming bridge restarted; drag again")
        case .network:
            return L10n.tr("云台指令未送达", "PTZ command did not reach the bridge")
        }
    }
}

public protocol CameraPTZControlling: Sendable {
    func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?)
    func move(direction: CameraPTZDirection, token: CameraPTZSessionToken, seq: UInt64) async throws
    func heartbeat(token: CameraPTZSessionToken, seq: UInt64) async throws
    func stop(token: CameraPTZSessionToken) async throws -> CameraPTZStopResult
}

/// Talks to the pinned go2rtc build's `/api/xiaomi/ptz` endpoint over loopback. The stream name
/// belongs to the already-open P2P session, so no second camera connection is created.
public actor CameraPTZClient: CameraPTZControlling {
    private let baseURL: URL
    private let streamName: String
    private let authorization: String?
    private let session: URLSession

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public init(
        baseURL: URL,
        streamName: String,
        username: String?,
        password: String?,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.streamName = streamName
        if let username, let password, !username.isEmpty {
            authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        } else {
            authorization = nil
        }
        self.session = session ?? Self.defaultSession
    }

    @discardableResult
    public func begin() async throws -> (token: CameraPTZSessionToken, mode: CameraPTZMotionMode?) {
        let data = try await send(Body(action: "begin"))
        let reply = try? JSONDecoder().decode(BeginReply.self, from: data)
        guard let reply, reply.ok, !reply.epoch.isEmpty, reply.session > 0 else {
            throw CameraPTZClientError.rejected
        }
        return (
            CameraPTZSessionToken(epoch: reply.epoch, session: reply.session),
            reply.mode.flatMap(CameraPTZMotionMode.init(rawValue:))
        )
    }

    public func move(
        direction: CameraPTZDirection,
        token: CameraPTZSessionToken,
        seq: UInt64
    ) async throws {
        _ = try await send(Body(
            action: "move",
            epoch: token.epoch,
            session: token.session,
            seq: seq,
            direction: direction.rawValue
        ))
    }

    public func heartbeat(token: CameraPTZSessionToken, seq: UInt64) async throws {
        _ = try await send(Body(
            action: "heartbeat",
            epoch: token.epoch,
            session: token.session,
            seq: seq
        ))
    }

    @discardableResult
    public func stop(token: CameraPTZSessionToken) async throws -> CameraPTZStopResult {
        let data = try await send(Body(
            action: "stop",
            epoch: token.epoch,
            session: token.session
        ))
        let reply = try? JSONDecoder().decode(StopReply.self, from: data)
        return CameraPTZStopResult(
            sent: reply?.stopSent ?? false,
            confirmed: false,
            mode: reply?.mode.flatMap(CameraPTZMotionMode.init(rawValue:)),
            errorReason: reply?.stopError
        )
    }

    private func send(_ body: Body) async throws -> Data {
        var body = body
        body.src = streamName
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CameraPTZClientError.notConfigured
        }
        components.path = "/api/xiaomi/ptz"
        guard let url = components.url else { throw CameraPTZClientError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CameraPTZClientError.network
        }
        guard let http = response as? HTTPURLResponse else { throw CameraPTZClientError.network }
        switch http.statusCode {
        case 200..<300:
            return data
        case 409:
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("epoch") {
                throw CameraPTZClientError.bridgeChanged
            }
            throw CameraPTZClientError.staleSession
        default:
            throw CameraPTZClientError.rejected
        }
    }

    private struct Body: Encodable {
        var src: String
        var action: String
        var epoch: String?
        var session: UInt64?
        var seq: UInt64?
        var direction: String?

        init(
            action: String,
            epoch: String? = nil,
            session: UInt64? = nil,
            seq: UInt64? = nil,
            direction: String? = nil
        ) {
            self.src = ""
            self.action = action
            self.epoch = epoch
            self.session = session
            self.seq = seq
            self.direction = direction
        }

        // `src` is per client, injected by the sender through the encoder's userInfo is not
        // available in a Codable value; fill it with a custom encode instead.
        enum CodingKeys: String, CodingKey {
            case src, action, epoch, session, seq, direction
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(src, forKey: .src)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(epoch, forKey: .epoch)
            try container.encodeIfPresent(session, forKey: .session)
            try container.encodeIfPresent(seq, forKey: .seq)
            try container.encodeIfPresent(direction, forKey: .direction)
        }
    }

    private struct BeginReply: Decodable {
        var ok: Bool
        var epoch: String
        var session: UInt64
        var mode: String?
    }

    private struct StopReply: Decodable {
        var stopSent: Bool
        var stopConfirmed: Bool
        var mode: String?
        var stopError: String?
    }
}
