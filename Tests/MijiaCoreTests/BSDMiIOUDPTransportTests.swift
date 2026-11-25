#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct BSDMiIOUDPTransportTests {
    @Test
    func sequentialPollsReuseTheSameSourcePortAndIgnoreStaleReplies() async throws {
        let server = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(server >= 0)
        defer { Darwin.close(server) }

        var receiveTimeout = timeval(tv_sec: 20, tv_usec: 0)
        let configured = setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        try #require(configured == 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                let bound = bind(server, pointer, length)
                try #require(bound == 0)
                let named = getsockname(server, pointer, &length)
                try #require(named == 0)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let transport = BSDMiIOUDPTransport(allowsHost: { $0 == "127.0.0.1" })
        let replyTimeout = Duration.seconds(30)

        var peerPorts: [UInt16] = []
        for pollID: UInt8 in [1, 2] {
            let (ready, signalReady) = AsyncStream<Void>.makeStream()
            var readiness = ready.makeAsyncIterator()
            async let peerPort = echoFromSocket(server, staleID: pollID - 1, ready: signalReady)
            try #require(await readiness.next() != nil)
            let reply = try await transport.send(Data([pollID]), to: "127.0.0.1", port: port, timeout: replyTimeout) {
                $0 == Data([pollID])
            }
            #expect(reply == Data([pollID]))
            peerPorts.append(try await peerPort)
        }

        #expect(Set(peerPorts).count == 1)
        await transport.shutdown()
        await #expect(throws: MiIOError.shutDown) {
            _ = try await transport.send(Data([3]), to: "127.0.0.1", port: port, timeout: replyTimeout)
        }
    }

    private func echoFromSocket(
        _ fd: Int32, staleID: UInt8, ready: AsyncStream<Void>.Continuation
    ) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var peer = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                var byte: UInt8 = 0
                let success = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        ready.yield(())
                        ready.finish()
                        guard recvfrom(fd, &byte, 1, 0, address, &size) == 1 else { return false }
                        var stale = staleID
                        return sendto(fd, &stale, 1, 0, address, size) == 1
                            && sendto(fd, &byte, 1, 0, address, size) == 1
                    }
                }
                if success {
                    continuation.resume(returning: UInt16(bigEndian: peer.sin_port))
                } else {
                    continuation.resume(throwing: MiIOError.sendFailed)
                }
            }
        }
    }
}
#endif
