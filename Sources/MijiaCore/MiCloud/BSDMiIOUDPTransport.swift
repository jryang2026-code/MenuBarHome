#if canImport(Darwin)
import Darwin
import Foundation

@available(*, deprecated, renamed: "BSDMiIOUDPTransport")
public typealias NWConnectionMiIOUDPTransport = BSDMiIOUDPTransport

public actor BSDMiIOUDPTransport: MiIOUDPTransport {
    private struct Endpoint: Hashable, Sendable {
        let address: in_addr_t
        let port: in_port_t
    }

    private struct Call {
        let id: UUID
        let matches: @Sendable (Data) -> Bool
        let reply: CheckedContinuation<Data, any Error>
        let timer: Task<Void, Never>
    }

    private let queue = DispatchQueue(label: "MenuBarHome.miIO.UDP", qos: .utility)
    private let allowsHost: @Sendable (String) -> Bool
    private var socketFD: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var pending: [Endpoint: [Call]] = [:]
    private var isShutDown = false

    public init() {
        allowsHost = LocalMiIOClient.isPrivateRFC1918IPv4
    }

    init(allowsHost: @escaping @Sendable (String) -> Bool) {
        self.allowsHost = allowsHost
    }

    deinit {
        readSource?.cancel()
    }

    public func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await send(packet, to: host, port: port, timeout: timeout) { _ in true }
    }

    public func send(
        _ packet: Data, to host: String, port: UInt16, timeout: Duration,
        matching reply: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        try Task.checkCancellation()
        guard !isShutDown else { throw MiIOError.shutDown }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var destination = Self.socketAddress(port: port)
        guard port != 0, allowsHost(trimmed), inet_pton(AF_INET, trimmed, &destination.sin_addr) == 1 else {
            throw MiIOError.invalidAddress(host)
        }

        let fd = try openSocket()
        let endpoint = Endpoint(address: destination.sin_addr.s_addr, port: destination.sin_port)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let sent = packet.withUnsafeBytes { buffer in
                    withUnsafePointer(to: &destination) { address in
                        address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent == packet.count else {
                    let denied = LocalNetworkPermissionClassifier.isDeniedPOSIXCode(errno)
                    continuation.resume(throwing: denied ? MiIOError.localNetworkDenied : MiIOError.sendFailed)
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail(endpoint, id: id, with: MiIOError.timeout)
                }
                pending[endpoint, default: []].append(Call(id: id, matches: reply, reply: continuation, timer: timer))
            }
        } onCancel: {
            Task { await self.fail(endpoint, id: id, with: CancellationError()) }
        }
    }

    public func probeBroadcast(_ packet: Data, port: UInt16, timeout: Duration) async throws -> [MiIOBroadcastReply] {
        guard !isShutDown else { throw MiIOError.shutDown }
        return try await DarwinBSDMiIOBroadcastScanner.probeBroadcast(packet: packet, port: port, timeout: timeout)
    }

    public func shutdown() async {
        isShutDown = true
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        let active = pending
        pending.removeAll()
        for call in active.values.joined() {
            call.timer.cancel()
            call.reply.resume(throwing: MiIOError.shutDown)
        }
    }

    private func openSocket() throws -> Int32 {
        if socketFD >= 0 { return socketFD }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiIOError.transportUnavailable }
        var local = Self.socketAddress(port: 0)
        let bound = withUnsafePointer(to: &local) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw MiIOError.transportUnavailable
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let packets = Self.readDatagrams(fd)
            guard !packets.isEmpty else { return }
            Task { await self?.receive(packets) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        socketFD = fd
        source.resume()
        return fd
    }

    private static func socketAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        return address
    }

    private static func readDatagrams(_ fd: Int32) -> [(Endpoint, Data)] {
        var buffer = [UInt8](repeating: 0, count: Int(UInt16.max))
        var packets: [(Endpoint, Data)] = []
        for _ in 0..<32 {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count >= 0 else { break }
            let endpoint = Endpoint(address: sender.sin_addr.s_addr, port: sender.sin_port)
            packets.append((endpoint, Data(buffer.prefix(count))))
        }
        return packets
    }

    private func receive(_ packets: [(Endpoint, Data)]) {
        for (endpoint, packet) in packets {
            guard let index = pending[endpoint]?.firstIndex(where: { $0.matches(packet) }) else { continue }
            removeCall(endpoint, at: index).resume(returning: packet)
        }
    }

    private func fail(_ endpoint: Endpoint, id: UUID, with error: any Error) {
        guard let index = pending[endpoint]?.firstIndex(where: { $0.id == id }) else { return }
        removeCall(endpoint, at: index).resume(throwing: error)
    }

    private func removeCall(_ endpoint: Endpoint, at index: Int) -> CheckedContinuation<Data, any Error> {
        let call = pending[endpoint]!.remove(at: index)
        if pending[endpoint]?.isEmpty == true { pending.removeValue(forKey: endpoint) }
        call.timer.cancel()
        return call.reply
    }
}
#endif
