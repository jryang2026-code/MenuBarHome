import Foundation
import Network
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct ResolvedEndpointTests {
    @Test(arguments: [
        ("0.0.0.0", EndpointAddressClass.prohibited),
        ("0.1.2.3", .prohibited),
        ("127.255.0.1", .prohibited),
        ("::", .prohibited),
        ("::1", .prohibited),
        ("::ffff:127.0.0.1", .prohibited),
        ("169.254.1.2", .lan),
        ("::ffff:192.168.1.2", .lan),
        ("fe80::1%en0", .lan),
        ("febf::1", .lan),
        ("fc00::1", .lan),
        ("fdff::1", .lan),
        ("100.64.0.1", .lan),
        ("100.127.255.255", .lan),
        ("100.128.0.1", .publicNetwork),
        ("::ffff:8.8.8.8", .publicNetwork),
        ("2001:4860::8888", .publicNetwork)
    ])
    func addressClassification(_ input: (String, EndpointAddressClass)) {
        #expect(EndpointAddressClass(numericAddress: input.0) == input.1)
    }

    @Test
    func rejectsAnswersOutsideTheConfiguredScope() throws {
        let publicURL = try #require(URL(string: "https://fixture.example"))
        #expect(throws: EndpointResolutionError.outsideAddressScope) {
            try ResolvedEndpoint(url: publicURL) { _, _ in ["192.0.2.10", "192.168.1.10"] }
        }
        let lanURL = try #require(URL(string: "http://fixture.lan:8123"))
        #expect(throws: EndpointResolutionError.plaintextConsentRequired) {
            try ResolvedEndpoint(url: lanURL) { _, _ in ["192.168.1.10", "192.0.2.10"] }
        }
        #expect(throws: EndpointResolutionError.outsideAddressScope) {
            try ResolvedEndpoint(url: lanURL) { _, _ in ["::ffff:127.0.0.1"] }
        }
        #expect(throws: EndpointResolutionError.outsideAddressScope) {
            try ResolvedEndpoint(url: #require(URL(string: "http://127.0.0.1:8123")))
        }
    }

    @Test
    func numericSocketURLKeepsThePathAndOriginalAuthority() throws {
        let url = try #require(URL(string: "wss://fixture.lan:8123/hass/api/websocket"))
        let endpoint = try ResolvedEndpoint(url: url) { host, port in
            #expect(host == "fixture.lan")
            #expect(port == 8123)
            return ["fe80::2%en0"]
        }
        #expect(endpoint.authority == "fixture.lan:8123")
        #expect(try endpoint.pinnedURL(at: "fe80::2%en0").absoluteString == "wss://[fe80::2%25en0]:8123/hass/api/websocket")
        #expect(throws: URLError.self) { try endpoint.pinnedURL(at: "127.0.0.1") }
    }

    @Test
    func tlsClientHelloSendsTheOriginalServerNameOnANumericConnection() async throws {
        let url = try #require(URL(string: "wss://fixture.lan:8123/hass/api/websocket"))
        let endpoint = try ResolvedEndpoint(url: url) { _, _ in ["192.168.1.10"] }
        let listenerParams = NWParameters.tcp
        listenerParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: listenerParams)
        let queue = DispatchQueue(label: "ResolvedEndpointTests TLS")
        let (ready, readyContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let (peers, peerContinuation) = AsyncStream<NWConnection>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyContinuation.yield()
                readyContinuation.finish()
            case .failed(let error):
                readyContinuation.finish(throwing: error)
                peerContinuation.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { peerContinuation.yield($0) }
        listener.start(queue: queue)
        defer { listener.cancel() }
        var readiness = ready.makeAsyncIterator()
        _ = try await readiness.next()
        let port = try #require(listener.port?.rawValue)
        // The loopback listener is a transport fixture. The production policy refuses this address.
        let fixtureURL = try #require(URL(string: "wss://127.0.0.1:\(port)/hass/api/websocket"))
        let client = NWConnection(to: .url(fixtureURL), using: PinnedHAWebSocket.parameters(for: endpoint))
        client.start(queue: queue)
        defer { client.cancel() }
        var connections = peers.makeAsyncIterator()
        let peer = try #require(await connections.next())
        peer.start(queue: queue)
        defer { peer.cancel() }
        let header = try await read(5, from: peer)
        #expect(header.first == 22) // TLS handshake record.
        let size = (Int(header[3]) << 8) | Int(header[4])
        let clientHello = try await read(size, from: peer)
        #expect(clientHello.first == 1)
        #expect(clientHello.range(of: Data("fixture.lan".utf8)) != nil)
    }

    private func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? URLError(.networkConnectionLost))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
