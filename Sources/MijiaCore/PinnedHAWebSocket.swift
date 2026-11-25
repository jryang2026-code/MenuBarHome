import Foundation
import Network
import Security

public final class PinnedHAWebSocket: HAWebSocketConnection {
    private static let queue = DispatchQueue(label: "MenuBarHome.HAWebSocket")

    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(to url: URL) async throws -> PinnedHAWebSocket {
        let deadline = ContinuousClock.now + .seconds(10)
        let endpoint = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try ResolvedEndpoint(url: url) })
            }
        }
        var lastError: any Error = URLError(.cannotConnectToHost)
        for address in endpoint.addresses {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw URLError(.timedOut) }
            let connection = try makeConnection(endpoint, address: address)
            do {
                try await awaitHandshake(connection, timeout: min(remaining, .seconds(4)))
                try Task.checkCancellation()
                return PinnedHAWebSocket(connection: connection)
            } catch {
                connection.cancel()
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    private static func makeConnection(_ endpoint: ResolvedEndpoint, address: String) throws -> NWConnection {
        NWConnection(to: .url(try endpoint.pinnedURL(at: address)), using: parameters(for: endpoint))
    }

    static func parameters(for endpoint: ResolvedEndpoint) -> NWParameters {
        var tls: NWProtocolTLS.Options?
        if endpoint.url.scheme?.lowercased() == "wss" {
            let options = NWProtocolTLS.Options()
            let tlsHost = endpoint.host
            if EndpointAddressClass(numericAddress: tlsHost) == nil {
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, tlsHost)
            }
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, tlsHost as CFString)
                let configured = SecTrustSetPolicies(trust, policy) == errSecSuccess
                complete(configured && SecTrustEvaluateWithError(trust, nil))
            }, queue)
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let privacy = NWParameters.PrivacyContext(description: "MenuBarHome Home Assistant")
        privacy.proxyConfigurations = []
        parameters.setPrivacyContext(privacy)
        parameters.preferNoProxies = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.setAdditionalHeaders([("Host", endpoint.authority)])
        webSocket.maximumMessageSize = 16 * 1024 * 1024
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    private static func awaitHandshake(_ connection: NWConnection, timeout: Duration) async throws {
        let (states, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield()
                continuation.finish()
            case .failed(let error), .waiting(let error):
                continuation.finish(throwing: error)
            case .cancelled:
                continuation.finish(throwing: CancellationError())
            default:
                break
            }
        }
        defer { connection.stateUpdateHandler = nil }
        connection.start(queue: queue)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = states.makeAsyncIterator()
                guard try await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func resume() {
        // connect(to:) has already started and validated the WebSocket handshake.
    }

    public func send(_ text: String) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        while true {
            let message: Data? = try await withCheckedThrowingContinuation { reply in
                connection.receiveMessage { data, context, _, error in
                    if let error {
                        reply.resume(throwing: error)
                        return
                    }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    switch metadata?.opcode {
                    case .text, .binary: reply.resume(returning: data ?? Data())
                    case .ping, .pong: reply.resume(returning: nil)
                    default: reply.resume(throwing: URLError(.networkConnectionLost))
                    }
                }
            }
            if let message { return message }
        }
    }

    public func cancel() {
        connection.cancel()
    }
}
