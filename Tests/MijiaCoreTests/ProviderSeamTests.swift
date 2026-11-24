import Foundation
import Testing
@testable import MijiaCore

/// The provider seam: the store stops whatever provider it replaces through `HomeProvider`.
struct ProviderSeamTests {
    @Test("HA reconnect backoff uses away segments and resets after a topology restart")
    func reconnectBackoffSegmentsAndReset() {
        var backoff = HAReconnectBackoff()
        #expect(backoff.next() == .milliseconds(800))
        #expect(backoff.next() == .seconds(2))
        #expect(backoff.next() == .seconds(4))
        #expect(backoff.next() == .seconds(8))
        #expect(backoff.next() == .seconds(30))
        #expect(backoff.next() == .seconds(60))
        #expect(backoff.next() == .seconds(120))
        #expect(backoff.next() == .seconds(300))
        #expect(backoff.next() == .seconds(300))
        backoff.reset()
        #expect(backoff.next() == .milliseconds(800))
        #expect(backoff.next(localEndpoint: false) == .seconds(2))
    }

    @Test("The composite stops both sources through the protocol")
    @MainActor
    func compositeShutsDownChildren() async throws {
        let ha = StoppableProvider()
        let mi = StoppableProvider()
        let composite = HomeStore.makeComposite(
            homeAssistant: ha,
            xiaomiCloud: mi,
            defaults: UserDefaults(suiteName: "test.seam.\(UUID().uuidString)")!
        )
        let provider: any HomeProvider = composite
        await provider.shutdown()
        // The composite shuts each source down from a detached task. Wait on each source's own
        // signal instead of yielding a fixed number of times, and name the source that did not
        // stop when its deadline expires.
        let haStopped = await ha.waitUntilStopped()
        #expect(haStopped, "the composite never shut down the Home Assistant source")
        let miStopped = await mi.waitUntilStopped()
        #expect(miStopped, "the composite never shut down the Xiaomi Cloud source")
        #expect(await ha.stopped)
        #expect(await mi.stopped)
    }

    @Test("HAWebSocketProvider defers activeWebSocket until auth_ok so mid-handshake refresh sends nothing")
    func activeWebSocketDeferredUntilAuthOK() async throws {
        let socket = GatedHandshakeSocket()
        let provider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.20:8123",
            token: "ha-secret",
            rediscover: { _ in [] },
            allowsToken: { _ in true }
        )
        await provider.setTestSeams(
            connectOverride: nil,
            reconnectSleep: { _ in },
            webSocketFactory: { _ in socket }
        )

        let events = provider.events()
        var iterator = events.makeAsyncIterator()
        if case .statusChanged(let firstStatus) = await iterator.next() {
            #expect(firstStatus == .connecting)
        } else {
            Issue.record("Expected connecting status event")
        }

        await socket.waitUntilAuthSent()
        #expect(await provider.hasActiveWebSocketForTesting == false)

        await provider.refreshNow()
        let preAuthSent = await socket.sentTypes()
        #expect(preAuthSent == ["auth"])

        await socket.releaseAuthOK()
        if case .statusChanged(let secondStatus) = await iterator.next() {
            #expect(secondStatus == .connected)
        } else {
            Issue.record("Expected connected status event")
        }
        #expect(await provider.hasActiveWebSocketForTesting == true)

        await provider.shutdown()
    }

    @Test("HAWebSocketProvider halts only on auth_invalid and retries unexpected handshake frames")
    func authInvalidStopsWhileUnexpectedHandshakeFramesReconnect() async throws {
        let invalidAttempts = ProviderTestCounter()
        let invalidSleeps = ProviderTestCounter()
        let invalidProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.20:8123",
            token: "bad-token",
            rediscover: { _ in [] },
            allowsToken: { _ in true }
        )
        await invalidProvider.setTestSeams(
            connectOverride: nil,
            reconnectSleep: { _ in _ = invalidSleeps.increment() },
            webSocketFactory: { _ in
                _ = invalidAttempts.increment()
                return ScriptedHandshakeSocket(frames: [
                    #"{"type":"auth_required"}"#,
                    #"{"type":"auth_invalid","message":"Invalid password"}"#,
                ])
            }
        )

        var invalidStatuses: [ConnectionStatus] = []
        for await event in invalidProvider.events() {
            if case .statusChanged(let status) = event {
                invalidStatuses.append(status)
                if case .disconnected = status { break }
            }
        }
        #expect(invalidAttempts.value == 1)
        #expect(invalidSleeps.value == 0)
        #expect(invalidStatuses.count == 2)
        await invalidProvider.shutdown()

        let transientAttempts = ProviderTestCounter()
        let transientProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.20:8123",
            token: "good-token",
            rediscover: { _ in [] },
            allowsToken: { _ in true }
        )
        await transientProvider.setTestSeams(
            connectOverride: nil,
            reconnectSleep: { _ in },
            webSocketFactory: { _ in
                switch transientAttempts.increment() {
                case 1:
                    return ScriptedHandshakeSocket(frames: ["not-json"])
                case 2:
                    return ScriptedHandshakeSocket(frames: [
                        #"{"type":"auth_required"}"#,
                        #"{"type":"pong"}"#,
                    ])
                default:
                    return ScriptedHandshakeSocket(frames: [
                        #"{"type":"auth_required"}"#,
                        #"{"type":"auth_ok"}"#,
                    ], autoReplyRegistries: true)
                }
            }
        )

        var transientStatuses: [ConnectionStatus] = []
        for await event in transientProvider.events() {
            if case .statusChanged(let status) = event {
                transientStatuses.append(status)
                if status == .connected { break }
            }
        }
        #expect(transientAttempts.value == 3)
        #expect(transientStatuses.last == .connected)
        await transientProvider.shutdown()
    }
}

final class ProviderTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private actor GatedHandshakeSocket: HAWebSocketConnection {
    private var step = 0
    private var sent: [String] = []
    private var authSentWaiter: CheckedContinuation<Void, Never>?
    private var authSent = false
    private var authOKWaiter: CheckedContinuation<Data, Error>?
    private var authOKReleased = false
    private var pendingIncoming: [Data] = []
    private var nextReceiveWaiter: CheckedContinuation<Data, Error>?
    private var isCancelled = false

    nonisolated func resume() {}

    func send(_ text: String) async throws {
        guard !isCancelled else { throw CancellationError() }
        sent.append(text)
        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let type = obj["type"] as? String {
            if type == "auth" {
                authSent = true
                authSentWaiter?.resume()
                authSentWaiter = nil
            } else if let id = obj["id"] as? Int, (1...5).contains(id) {
                let resultPayload = id == 5 ? "null" : "[]"
                let reply = Data(#"{"id":\#(id),"type":"result","success":true,"result":\#(resultPayload)}"#.utf8)
                enqueue(reply)
            }
        }
    }

    func receive() async throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        step += 1
        if step == 1 {
            return Data(#"{"type":"auth_required"}"#.utf8)
        }
        if step == 2 {
            if authOKReleased {
                return Data(#"{"type":"auth_ok"}"#.utf8)
            }
            return try await withCheckedThrowingContinuation { cont in
                if isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    authOKWaiter = cont
                }
            }
        }
        if !pendingIncoming.isEmpty {
            return pendingIncoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { cont in
            if isCancelled {
                cont.resume(throwing: CancellationError())
            } else {
                nextReceiveWaiter = cont
            }
        }
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }

    private func markCancelled() {
        isCancelled = true
        authOKWaiter?.resume(throwing: CancellationError())
        authOKWaiter = nil
        nextReceiveWaiter?.resume(throwing: CancellationError())
        nextReceiveWaiter = nil
    }

    private func enqueue(_ data: Data) {
        if let waiter = nextReceiveWaiter {
            nextReceiveWaiter = nil
            waiter.resume(returning: data)
        } else {
            pendingIncoming.append(data)
        }
    }

    func waitUntilAuthSent() async {
        if authSent { return }
        await withCheckedContinuation { cont in
            authSentWaiter = cont
        }
    }

    func releaseAuthOK() {
        authOKReleased = true
        authOKWaiter?.resume(returning: Data(#"{"type":"auth_ok"}"#.utf8))
        authOKWaiter = nil
    }

    func sentTypes() -> [String] {
        sent.compactMap { raw in
            (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["type"] as? String
        }
    }
}

private actor ScriptedHandshakeSocket: HAWebSocketConnection {
    private var frames: [Data]
    private let autoReplyRegistries: Bool
    private var waiter: CheckedContinuation<Data, Error>?
    private var isCancelled = false

    init(frames: [String], autoReplyRegistries: Bool = false) {
        self.frames = frames.map { Data($0.utf8) }
        self.autoReplyRegistries = autoReplyRegistries
    }

    nonisolated func resume() {}

    func send(_ text: String) async throws {
        guard !isCancelled else { throw CancellationError() }
        guard autoReplyRegistries,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = obj["id"] as? Int,
              (1...5).contains(id) else {
            return
        }
        let resultPayload = id == 5 ? "null" : "[]"
        let reply = Data(#"{"id":\#(id),"type":"result","success":true,"result":\#(resultPayload)}"#.utf8)
        if let pending = waiter {
            waiter = nil
            pending.resume(returning: reply)
        } else {
            frames.append(reply)
        }
    }

    func receive() async throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        return try await withCheckedThrowingContinuation { cont in
            if isCancelled {
                cont.resume(throwing: CancellationError())
            } else {
                waiter = cont
            }
        }
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }

    private func markCancelled() {
        isCancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private actor StoppableProvider: HomeProvider {
    private(set) var stopped = false
    private var stopWaiter: (continuation: CheckedContinuation<Bool, Never>, timeout: Task<Void, Never>)?

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { _ in }
    }

    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}
    func shutdown() async {
        stopped = true
        guard let waiter = stopWaiter else { return }
        stopWaiter = nil
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: true)
    }

    /// Waits until `shutdown` ran; false when the deadline expired first. The deadline task is
    /// cancelled when the signal arrives, so it never outlives the wait.
    func waitUntilStopped(timeout: Duration = .seconds(10)) async -> Bool {
        if stopped { return true }
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self.expireStopWaiter()
            }
            stopWaiter = (continuation, timeoutTask)
        }
    }

    private func expireStopWaiter() {
        guard let waiter = stopWaiter else { return }
        stopWaiter = nil
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: false)
    }
}
