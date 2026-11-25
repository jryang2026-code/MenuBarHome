import Dispatch
import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct HAEndpointAddressTests {
    @Test(arguments: [
        ("0.0.0.0", EndpointAddressClass.prohibited),
        ("0.1.2.3", .prohibited),
        ("127.255.0.1", .prohibited),
        ("::", .prohibited),
        ("::1", .prohibited),
        ("::ffff:127.0.0.1", .prohibited),
        ("169.254.169.254", .prohibited),
        ("::ffff:169.254.169.254", .prohibited),
        ("64:ff9b::127.0.0.1", .prohibited),
        ("64:ff9b::169.254.169.254", .prohibited),
        ("64:ff9b::192.168.1.10", .lan),
        ("64:ff9b::8.8.8.8", .publicNetwork),
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

    @Test(arguments: [
        ("https://home.example", "100.64.0.1", nil as HAEndpointResolutionError?),
        ("http://home.example", "192.0.2.10", nil),
        ("https://home.example", "127.0.0.1", .prohibitedAddress),
        ("https://home.example", "169.254.169.254", .prohibitedAddress),
        ("https://home.example", "64:ff9b::127.0.0.1", .prohibitedAddress),
        ("https://home.example", "64:ff9b::169.254.169.254", .prohibitedAddress),
        ("http://home.lan", "64:ff9b::8.8.8.8", .publicAddressForLocalPlaintext),
        ("http://home.lan", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("https://home.lan", "192.0.2.10", nil),
        ("ws://home.local", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("wss://home.local", "192.0.2.10", nil),
        ("http://192.168.1.10", "192.0.2.10", nil),
        ("http://[::ffff:192.168.1.10]", "192.0.2.10", nil),
        ("http://home.lan", "::ffff:127.0.0.1", .prohibitedAddress)
    ])
    func validatesMixedAnswers(_ test: (String, String, HAEndpointResolutionError?)) throws {
        let url = try #require(URL(string: test.0))
        let validate = {
            try HAPlaintextConsent.validateConnectionAddress(url) { _ in ["192.168.1.10", test.1] }
        }
        if let expected = test.2 {
            #expect(throws: expected) { try validate() }
        } else {
            try validate()
        }
    }

    @Test
    func systemLookupAndLiteralValidation() async throws {
        #expect(HAPlaintextConsent.addressLookupTimeout == .milliseconds(2500))
        let lanURL = try #require(URL(string: "http://192.168.1.10"))
        try await HAPlaintextConsent.validateConnectionAddress(lanURL)
        for raw in [
            "http://127.1:8123",
            "wss://[::ffff:127.0.0.1]:8123",
            "http://localhost:8123",
            "http://169.254.169.254/latest/meta-data/",
            "http://0xa9fea9fe/latest/meta-data/",
            "http://[::ffff:169.254.169.254]:8123",
            "http://[64:ff9b::127.0.0.1]:8123",
            "http://[64:ff9b::169.254.169.254]:8123",
        ] {
            let url = try #require(URL(string: raw))
            await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
                try await HAPlaintextConsent.validateConnectionAddress(url)
            }
        }
    }

    @Test
    func ipLiteralSkipsLookup() throws {
        var lookupCalled = false
        let url = try #require(URL(string: "http://192.168.1.10:8123"))
        try HAPlaintextConsent.validateConnectionAddress(url) { _ in
            lookupCalled = true
            return ["192.0.2.10"]
        }
        #expect(!lookupCalled)
    }

    @Test("BoundedHostLookup deduplicates active in-flight hosts without stripping trailing dots or caching results")
    func boundedLookupBehavior() async throws {
        // 1. Active in-flight deduplication (case-insensitive) + trailing dot kept distinct
        let (enteredStream, entered) = AsyncStream<String>.makeStream()
        var enteredIt = enteredStream.makeAsyncIterator()
        let releasePlain = DispatchSemaphore(value: 0)
        let releaseFQDN = DispatchSemaphore(value: 0)
        let callHosts = LockedBox([String]())
        let gate = TestTimeoutGate()
        let dedupResolver = BoundedHostLookup(
            maxConcurrentLookups: 3, timeout: .seconds(2),
            sleep: { _ in try await gate.waitNext() },
            resolve: { host in
                callHosts.withValue { $0.append(host) }
                entered.yield(host)
                if host.hasSuffix(".") {
                    releaseFQDN.wait()
                    return ["192.168.1.26"]
                }
                releasePlain.wait()
                return ["192.168.1.25"]
            }
        )
        let first = Task { try await dedupResolver.lookup("slow.local") }
        _ = await enteredIt.next(); await gate.waitForSleepers(count: 1)
        let second = Task { try await dedupResolver.lookup("SLOW.LOCAL") }
        await gate.waitForSleepers(count: 2)
        // Trailing-dot FQDN must not merge with search-domain hostname.
        let fqdn = Task { try await dedupResolver.lookup("slow.local.") }
        _ = await enteredIt.next(); await gate.waitForSleepers(count: 3)
        await gate.releaseOne()
        await #expect(throws: URLError(.timedOut)) { _ = try await first.value }
        // `second` is still an active waiter on "slow.local", so `third` coalesces onto it.
        let third = Task { try await dedupResolver.lookup("slow.local") }
        await gate.waitForSleepers(count: 3)
        #expect(callHosts.value == ["slow.local", "slow.local."])
        releasePlain.signal()
        releaseFQDN.signal()
        let secondIPs = try await second.value
        let thirdIPs = try await third.value
        let fqdnIPs = try await fqdn.value
        #expect(secondIPs == ["192.168.1.25"] && thirdIPs == ["192.168.1.25"] && fqdnIPs == ["192.168.1.26"])
        #expect(callHosts.value.count == 2)

        // 2. Abandoned timed-out lookup with zero active waiters does not coalesce a subsequent lookup
        let (abandonStream, abandonEntered) = AsyncStream<Int>.makeStream()
        var abandonIt = abandonStream.makeAsyncIterator()
        let releaseFirstAttempt = DispatchSemaphore(value: 0)
        let releaseSecondAttempt = DispatchSemaphore(value: 0)
        let attemptCount = LockedBox(0)
        let abandonGate = TestTimeoutGate()
        let abandonResolver = BoundedHostLookup(
            maxConcurrentLookups: 2, timeout: .seconds(2),
            sleep: { _ in try await abandonGate.waitNext() },
            resolve: { _ in
                let attempt = attemptCount.withValue { $0 += 1; return $0 }
                abandonEntered.yield(attempt)
                if attempt == 1 {
                    releaseFirstAttempt.wait()
                    return ["192.168.1.10"]
                }
                releaseSecondAttempt.wait()
                return ["192.168.1.99"]
            }
        )
        let timedOut = Task { try await abandonResolver.lookup("rebind.local") }
        #expect(await abandonIt.next() == 1)
        await abandonGate.waitForSleepers(count: 1)
        await abandonGate.releaseOne()
        await #expect(throws: URLError(.timedOut)) { _ = try await timedOut.value }
        let fresh = Task { try await abandonResolver.lookup("rebind.local") }
        #expect(await abandonIt.next() == 2)
        // Late completion of attempt 1 must not deliver stale IPs to attempt 2.
        releaseFirstAttempt.signal()
        releaseSecondAttempt.signal()
        #expect(try await fresh.value == ["192.168.1.99"])
        #expect(attemptCount.value == 2)

        // 3. Bounded concurrency + eviction of cancelled queued host
        let (capStream, capEntered) = AsyncStream<Void>.makeStream()
        var capIt = capStream.makeAsyncIterator()
        let capRelease = DispatchSemaphore(value: 0)
        let stats = LockedBox((active: 0, peak: 0, hosts: [String]()))
        let capGate = TestTimeoutGate()
        let capResolver = BoundedHostLookup(
            maxConcurrentLookups: 2, timeout: .seconds(2),
            sleep: { _ in try await capGate.waitNext() },
            resolve: { host in
                stats.withValue { $0.active += 1; $0.peak = max($0.peak, $0.active); $0.hosts.append(host) }
                capEntered.yield(); capRelease.wait()
                stats.withValue { $0.active -= 1 }
                return ["192.168.1.30"]
            }
        )
        let t1 = Task { try await capResolver.lookup("host-1.local") }
        let t2 = Task { try await capResolver.lookup("host-2.local") }
        _ = await capIt.next(); _ = await capIt.next()
        let t3 = Task { try await capResolver.lookup("host-3.local") }
        let t4 = Task { try await capResolver.lookup("host-4.local") }
        await capGate.waitForSleepers(count: 4)
        #expect(stats.value.peak == 2 && stats.value.hosts.count == 2)
        t3.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t3.value }
        capRelease.signal(); capRelease.signal()
        _ = await capIt.next()
        capRelease.signal()
        let (r1, r2, r4) = (try await t1.value, try await t2.value, try await t4.value)
        #expect(r1 == ["192.168.1.30"] && r2 == ["192.168.1.30"] && r4 == ["192.168.1.30"])
        #expect(stats.value.peak == 2 && !stats.value.hosts.contains("host-3.local") && stats.value.hosts.contains("host-4.local"))

        // 4. Fresh resolution on every sequential call (no positive cache -> immediate DNS rebinding rejection)
        let rebindState = LockedBox((calls: 0, ips: ["192.168.1.40"]))
        let freshResolver = BoundedHostLookup(
            maxConcurrentLookups: 2, timeout: .seconds(2),
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            resolve: { _ in
                rebindState.withValue { s -> [String] in
                    s.calls += 1
                    return s.ips
                }
            }
        )
        let targetURL = try #require(URL(string: "http://ha.local:8123/api/states"))
        try await HAPlaintextConsent.validateConnectionAddress(targetURL, resolver: freshResolver)
        #expect(rebindState.value.calls == 1)
        // Next lookup immediately observes DNS change to loopback/IMDS without stale cache hit.
        rebindState.withValue { $0.ips = ["127.0.0.1"] }
        await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
            try await HAPlaintextConsent.validateConnectionAddress(targetURL, resolver: freshResolver)
        }
        #expect(rebindState.value.calls == 2)
        rebindState.withValue { $0.ips = ["169.254.169.254"] }
        await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
            try await HAPlaintextConsent.validateConnectionAddress(targetURL, resolver: freshResolver)
        }
        #expect(rebindState.value.calls == 3)
        rebindState.withValue { $0.ips = ["192.168.1.41"] }
        try await HAPlaintextConsent.validateConnectionAddress(targetURL, resolver: freshResolver)
        #expect(rebindState.value.calls == 4)
    }

    @Test("isAllowedLoopbackStreamURL permits configured Basic Auth loopback URLs while keeping redirect origin checks strict")
    func customLoopbackBasicAuthValidation() async throws {
        let configured = "http://user:pass@127.0.0.1:8080/mjpeg"
        let exact = try #require(URL(string: configured))
        let snapshotWithCacheBust = try #require(URL(string: "http://user:pass@127.0.0.1:8080/snapshot.jpg?_t=12345"))
        let strippedAuth = try #require(URL(string: "http://127.0.0.1:8080/mjpeg"))
        let wrongCreds = try #require(URL(string: "http://attacker:secret@127.0.0.1:8080/mjpeg"))
        let wrongPort = try #require(URL(string: "http://user:pass@127.0.0.1:9090/mjpeg"))
        let nonLoopback = try #require(URL(string: "http://user:pass@192.168.1.10:8080/mjpeg"))

        #expect(await HAPlaintextConsent.isAllowedLoopbackStreamURL(exact, customStreamURL: configured))
        #expect(await HAPlaintextConsent.isAllowedLoopbackStreamURL(snapshotWithCacheBust, customStreamURL: configured))
        #expect(await HAPlaintextConsent.isAllowedLoopbackStreamURL(strippedAuth, customStreamURL: configured))

        // Unconfigured, credential-injected, mismatched-credential, wrong-port, or non-loopback must fail closed.
        #expect(!(await HAPlaintextConsent.isAllowedLoopbackStreamURL(exact, customStreamURL: nil)))
        #expect(!(await HAPlaintextConsent.isAllowedLoopbackStreamURL(exact, customStreamURL: "http://127.0.0.1:8080/mjpeg")))
        #expect(!(await HAPlaintextConsent.isAllowedLoopbackStreamURL(wrongCreds, customStreamURL: configured)))
        #expect(!(await HAPlaintextConsent.isAllowedLoopbackStreamURL(wrongPort, customStreamURL: configured)))
        #expect(!(await HAPlaintextConsent.isAllowedLoopbackStreamURL(nonLoopback, customStreamURL: nonLoopback.absoluteString)))

        // Redirect origin checks must stay strict and continue rejecting URLs with userinfo.
        #expect(!HAPlaintextConsent.hasSameOrigin(exact, as: strippedAuth))
        #expect(!HAPlaintextConsent.hasSameOrigin(exact, as: exact))
        #expect(HARedirectPolicy.allowedRedirectRequest(
            originalURL: strippedAuth,
            responseURL: strippedAuth,
            newRequest: URLRequest(url: exact),
            resolve: { _ in ["192.168.1.10"] }
        ) == nil)
    }

    @Test("HARedirectPolicy blocks cross-origin and prohibited redirects while permitting validated same-origin hops")
    func redirectPolicyAndDelegateBlocking() async throws {
        let original = try #require(URL(string: "http://192.168.1.10:8123/api/camera_proxy/camera.door"))
        let sameOrigin = try #require(URL(string: "http://192.168.1.10:8123/api/camera_proxy/camera.door?v=2"))
        #expect(HARedirectPolicy.allowedRedirectRequest(
            originalURL: original, responseURL: original, newRequest: URLRequest(url: sameOrigin),
            resolve: { _ in ["192.168.1.10"] }
        )?.url == sameOrigin)

        for raw in [
            "http://127.0.0.1:8080/admin", "http://169.254.169.254/latest/meta-data/",
            "http://[64:ff9b::127.0.0.1]:8123/secret", "https://192.168.1.10:8123/api/camera_proxy/camera.door",
            "http://192.168.1.10:9000/api/camera_proxy/camera.door", "http://192.168.1.11:8123/api/camera_proxy/camera.door",
            "https://attacker.example/steal", "http://user:pass@192.168.1.10:8123/api/camera_proxy/camera.door",
            "file:///etc/passwd",
        ] {
            let target = try #require(URL(string: raw))
            #expect(HARedirectPolicy.allowedRedirectRequest(
                originalURL: original, responseURL: original, newRequest: URLRequest(url: target),
                resolve: { _ in ["192.168.1.10"] }
            ) == nil, "redirect to \(raw) must be blocked")
        }

        let dnsURL = try #require(URL(string: "http://home.local:8123/api/states"))
        for badIP in ["127.0.0.1", "169.254.169.254", "64:ff9b::127.0.0.1"] {
            #expect(HARedirectPolicy.allowedRedirectRequest(
                originalURL: dnsURL, responseURL: dnsURL, newRequest: URLRequest(url: dnsURL),
                resolve: { _ in [badIP] }
            ) == nil)
        }

        let wssURL = try #require(URL(string: "wss://ha.example:8123/api/websocket"))
        let httpsURL = try #require(URL(string: "https://ha.example:8123/api/websocket"))
        let httpDowngrade = try #require(URL(string: "http://ha.example:8123/api/websocket"))
        #expect(HARedirectPolicy.allowedRedirectRequest(
            originalURL: wssURL, responseURL: nil, newRequest: URLRequest(url: httpsURL), resolve: { _ in ["192.0.2.10"] }
        )?.url == httpsURL)
        #expect(HARedirectPolicy.allowedRedirectRequest(
            originalURL: wssURL, responseURL: nil, newRequest: URLRequest(url: httpDowngrade), resolve: { _ in ["192.0.2.10"] }
        ) == nil)

        #if canImport(Darwin)
        #expect(HARedirectBlockingDelegate.shared.responds(
            to: NSSelectorFromString("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:")
        ))
        #endif
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: original))
        let redirectResponse = try #require(HTTPURLResponse(
            url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://127.0.0.1:8080/admin"]
        ))
        let evilTarget = try #require(URL(string: "http://127.0.0.1:8080/admin"))
        #expect(await Self.invokeRedirectDelegate(session: session, task: task, response: redirectResponse, newRequest: URLRequest(url: evilTarget)) == nil)
        #expect(await Self.invokeRedirectDelegate(session: session, task: task, response: redirectResponse, newRequest: URLRequest(url: sameOrigin))?.url == sameOrigin)
    }

    private static func invokeRedirectDelegate(
        session: URLSession, task: URLSessionTask, response: HTTPURLResponse, newRequest: URLRequest
    ) async -> URLRequest? {
        await withCheckedContinuation { cont in
            startRedirectDecision(session: session, task: task, response: response, newRequest: newRequest) {
                cont.resume(returning: $0)
            }
        }
    }

    private static func startRedirectDecision(
        session: URLSession, task: URLSessionTask, response: HTTPURLResponse, newRequest: URLRequest,
        completion: @escaping @Sendable (URLRequest?) -> Void
    ) {
        HARedirectBlockingDelegate.shared.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest, completionHandler: completion
        )
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult
    func withValue<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&storage) }
}

private actor TestTimeoutGate {
    private var sleepers: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitNext() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sleepers.append((id, cont))
                notifyCountWaiters()
            }
        } onCancel: { Task { await self.cancelSleeper(id: id) } }
    }

    func waitForSleepers(count: Int) async {
        if sleepers.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func releaseOne() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().continuation.resume()
    }

    private func cancelSleeper(id: UUID) {
        guard let idx = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: idx).continuation.resume(throwing: CancellationError())
    }

    private func notifyCountWaiters() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if sleepers.count >= waiter.target { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        countWaiters = remaining
    }
}
