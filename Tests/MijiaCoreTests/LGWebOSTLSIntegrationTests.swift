#if os(macOS)
import Foundation
import Testing
@testable import MijiaCore

struct LGWebOSTLSIntegrationTests {
    @Test("Real TLS rejects a replaced TV certificate and accepts it only after re-pair", .timeLimit(.minutes(1)))
    func certificateReplacementAtTLSBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "test.lg.tls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = LGCertificateTrust(defaults: defaults)
        let first = try await startServer(directory: directory, name: "original")
        defer { stop(first.process) }
        let second = try await startServer(directory: directory, name: "replacement")
        defer { stop(second.process) }
        let firstURL = try #require(URL(string: "https://127.0.0.1:\(first.port)/"))
        let secondURL = try #require(URL(string: "https://127.0.0.1:\(second.port)/"))

        let accepted = try await request(firstURL, trust: trust)
        #expect(accepted == 200)
        do {
            _ = try await request(secondURL, trust: trust)
            Issue.record("A replacement certificate completed TLS without re-pairing")
        } catch {
            #expect(trust.failure(for: "127.0.0.1") == .changed)
        }
        #expect(try await request(firstURL, trust: trust) == 200)
        #expect(trust.reset(host: "127.0.0.1"))
        #expect(try await request(secondURL, trust: trust) == 200)
        do {
            _ = try await request(firstURL, trust: trust)
            Issue.record("The discarded certificate completed TLS after re-pairing")
        } catch {
            #expect(trust.failure(for: "127.0.0.1") == .changed)
        }
    }

    /// Starts a TLS server on a port the kernel reported free. `/usr/bin/openssl` is LibreSSL,
    /// which rejects `-accept 0` ("getservbyname failure for 0"), so the port is reserved with a
    /// socket and released just before `s_server` binds it; a port stolen in that gap makes the
    /// start retry with a new one. The caller gets the port only once the server listens.
    private func startServer(directory: URL, name: String) async throws -> (process: Process, port: Int) {
        let certificate = directory.appendingPathComponent("\(name).crt").path
        let key = directory.appendingPathComponent("\(name).key").path
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                              "-subj", "/CN=\(name)", "-keyout", key, "-out", certificate]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        generate.waitUntilExit()
        try #require(generate.terminationStatus == 0, "Could not generate isolated test certificates")

        var lastError: any Error = LocalServerError(description: "no free port for the TLS server")
        for _ in 0..<5 {
            let port = try Self.availablePort()
            let server = Process()
            server.executableURL = generate.executableURL
            // Apple's LibreSSL parses `-accept` as a service name, so pass the bare number.
            server.arguments = ["s_server", "-accept", "\(port)", "-cert", certificate, "-key", key, "-www", "-quiet"]
            server.standardInput = FileHandle.nullDevice
            server.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            server.standardError = errorPipe
            try server.run()
            do {
                try await waitUntilListening(server, errorPipe: errorPipe)
                return (server, port)
            } catch {
                lastError = error
                stop(server)
            }
        }
        throw lastError
    }

    /// Asks the kernel for a free loopback port and releases it immediately, so `s_server` can
    /// take it.
    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalServerError(description: "socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw LocalServerError(description: "inet_pton failed for 127.0.0.1")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw LocalServerError(description: "bind failed: \(String(cString: strerror(errno)))")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw LocalServerError(description: "getsockname failed: \(String(cString: strerror(errno)))")
        }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// Waits until the child is listening, so the first request cannot race the bind. The child's
    /// stderr is read only after it exits, so the read cannot block the wait.
    private func waitUntilListening(
        _ process: Process,
        errorPipe: Pipe,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                let reason = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LocalServerError(
                    description: "openssl s_server exited (\(process.terminationStatus)) before it listened: \(reason)"
                )
            }
            if Self.isListening(pid: process.processIdentifier) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LocalServerError(description: "openssl s_server did not listen within \(timeout)")
    }

    private static func isListening(pid: Int32) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        let deadline = ContinuousClock.now + .seconds(5)
        while lsof.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if lsof.isRunning {
            lsof.terminate()
            lsof.waitUntilExit()
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return lsof.terminationStatus == 0
            && String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0.hasPrefix("n") }
    }

    private struct LocalServerError: Error, CustomStringConvertible {
        let description: String
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func request(_ url: URL, trust: LGCertificateTrust) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: LGWebOSTrustDelegate(trustStore: trust), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0..<40 {
            do {
                let (_, response) = try await session.data(from: url)
                return try #require(response as? HTTPURLResponse).statusCode
            } catch let error as URLError where error.code == .cannotConnectToHost && attempt < 39 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw URLError(.cannotConnectToHost)
    }
}
#endif
