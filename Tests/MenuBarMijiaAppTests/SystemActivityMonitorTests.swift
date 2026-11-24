import Foundation
import Network
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@Suite(.serialized)
struct SystemActivityMonitorTests {
    // MARK: - NetworkTopologyFingerprint

    @Test("NetworkTopologyFingerprint ignores awdl, llw, and loopback interfaces while tracking en0 prefix and gateway changes")
    func topologyFingerprintFiltersEphemeralInterfacesAndDetectsChanges() throws {
        let gw1IP = try #require(IPv4Address("192.0.2.1"))
        let gw2IP = try #require(IPv4Address("192.0.2.2"))
        let gw1 = NWEndpoint.hostPort(host: .ipv4(gw1IP), port: 80)
        let gw2 = NWEndpoint.hostPort(host: .ipv4(gw2IP), port: 80)

        let baseline = NetworkTopologyFingerprint(
            interfaceNames: ["en0"],
            gateways: [gw1],
            prefixes: ["en0:c0.0.2.0/24"]
        )
        let withEphemeralChurn = NetworkTopologyFingerprint(
            interfaceNames: ["en0", "awdl0", "llw0", "lo0"],
            gateways: [gw1],
            prefixes: ["en0:c0.0.2.0/24"]
        )
        #expect(baseline == withEphemeralChurn)

        let differentPrefix = NetworkTopologyFingerprint(
            interfaceNames: ["en0"],
            gateways: [gw1],
            prefixes: ["en0:c6.33.64.0/24"]
        )
        #expect(baseline != differentPrefix)

        let differentGateway = NetworkTopologyFingerprint(
            interfaceNames: ["en0"],
            gateways: [gw2],
            prefixes: ["en0:c0.0.2.0/24"]
        )
        #expect(baseline != differentGateway)
    }

    // MARK: - SystemWakePolicy

    @Test("SystemWakePolicy classifies long sleep, short interactive wake, short dark wake, and wake without prior sleep")
    func wakePolicyClassifiesSleepDurationsAndActivity() {
        let clock = VirtualWakeClock()
        var policy = SystemWakePolicy(now: { clock.now })

        // Wake without a prior sleep is treated as short.
        #expect(policy.wake(userActivityObserved: false) == .dark)
        #expect(policy.wake(userActivityObserved: true) == .probe)

        // Short sleep without user activity -> .dark
        policy.sleep()
        clock.advance(by: .seconds(599))
        #expect(policy.wake(userActivityObserved: false) == .dark)

        // Short sleep with user activity -> .probe
        policy.sleep()
        clock.advance(by: .seconds(30))
        #expect(policy.wake(userActivityObserved: true) == .probe)

        // Long sleep >= 600 s -> .reconnect regardless of user activity
        policy.sleep()
        clock.advance(by: .seconds(600))
        #expect(policy.wake(userActivityObserved: false) == .reconnect)

        // Subsequent wake without another sleep is again treated as short.
        #expect(policy.wake(userActivityObserved: false) == .dark)
    }

    // MARK: - DarkWake Cap

    @Test("DarkWake cap resumes HA transport after 10 minutes without interactive wake")
    @MainActor
    func darkWakeCapResumesTransportWhenElapsed() async throws {
        let clock = VirtualWakeClock()
        let gate = DarkWakeSleepGate()
        let (store, resumeCalls) = try await makeStore()
        defer { store.stop() }

        let monitor = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await gate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        monitor.start(with: store, observeSystemEvents: false)
        defer { monitor.stop() }

        monitor.apply(.displayAsleep(true))
        monitor.apply(.asleep(true))
        #expect(store.pollingContext.haTransportSuspended == true)

        clock.advance(by: .seconds(5))
        monitor.apply(.asleep(false))
        #expect(monitor.isWaitingForInteractiveWakeForTesting == true)
        #expect(store.pollingContext.haTransportSuspended == true)

        await gate.waitUntilParked()
        #expect(await gate.requestedDurations == [.seconds(600)])

        // Stay awake past the DarkWake cap without interactive wake.
        clock.advance(by: .seconds(600))
        await gate.release()

        try await awaitState { store.pollingContext.haTransportSuspended == false }
        #expect(monitor.isWaitingForInteractiveWakeForTesting == false)
        #expect(store.pollingContext.systemActive == false)

        // When display later wakes, the queued .systemWake + .displayWake flush together.
        monitor.apply(.displayAsleep(false))
        try await awaitState { store.pollingContext.systemActive == true }
        await waitUntil { await resumeCalls.value >= 1 }
    }

    @Test("DarkWake cap resumes full system activity on headless Mac when displayAsleep was not flagged")
    @MainActor
    func darkWakeCapResumesHeadlessMacWithAsleepDisplay() async throws {
        let clock = VirtualWakeClock()
        let gate = DarkWakeSleepGate()
        let (store, resumeCalls) = try await makeStore()
        defer { store.stop() }

        let monitor = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await gate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        monitor.start(with: store, observeSystemEvents: false)
        defer { monitor.stop() }

        monitor.apply(.asleep(true))
        clock.advance(by: .seconds(10))
        monitor.apply(.asleep(false))
        #expect(store.pollingContext.haTransportSuspended == true)

        await gate.waitUntilParked()
        await gate.release()

        try await awaitState {
            store.pollingContext.haTransportSuspended == false && store.pollingContext.systemActive == true
        }
        await waitUntil { await resumeCalls.value == 1 }
    }

    @Test("Interactive wake before DarkWake cap cancels the cap timer and resumes transport")
    @MainActor
    func interactiveWakeBeforeCapCancelsTimer() async throws {
        let clock = VirtualWakeClock()
        let gate = DarkWakeSleepGate()
        let (store, resumeCalls) = try await makeStore()
        defer { store.stop() }

        let monitor = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await gate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        monitor.start(with: store, observeSystemEvents: false)
        defer { monitor.stop() }

        monitor.apply(.displayAsleep(true))
        monitor.apply(.asleep(true))
        clock.advance(by: .seconds(5))
        monitor.apply(.asleep(false))

        await gate.waitUntilParked()
        #expect(monitor.isWaitingForInteractiveWakeForTesting == true)

        monitor.apply(.displayAsleep(false))
        await gate.waitUntilCancelled()

        #expect(await gate.cancelledCount == 1)
        #expect(monitor.isWaitingForInteractiveWakeForTesting == false)
        try await awaitState {
            store.pollingContext.haTransportSuspended == false && store.pollingContext.systemActive == true
        }
        await waitUntil { await resumeCalls.value == 1 }
    }

    @Test("Sleeping again before DarkWake cap cancels the cap timer and keeps transport suspended")
    @MainActor
    func sleepAgainBeforeCapCancelsTimer() async throws {
        let clock = VirtualWakeClock()
        let gate = DarkWakeSleepGate()
        let (store, _) = try await makeStore()
        defer { store.stop() }

        let monitor = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await gate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        monitor.start(with: store, observeSystemEvents: false)
        defer { monitor.stop() }

        monitor.apply(.displayAsleep(true))
        monitor.apply(.asleep(true))
        clock.advance(by: .seconds(5))
        monitor.apply(.asleep(false))

        await gate.waitUntilParked()
        #expect(monitor.isWaitingForInteractiveWakeForTesting == true)

        monitor.apply(.asleep(true))
        await gate.waitUntilCancelled()

        #expect(await gate.cancelledCount == 1)
        #expect(monitor.isWaitingForInteractiveWakeForTesting == false)
        #expect(store.pollingContext.haTransportSuspended == true)
    }

    @Test("Monitor stop and deallocation cancel a pending DarkWake cap timer")
    @MainActor
    func stopAndTeardownCancelDarkWakeCapTimer() async throws {
        let clock = VirtualWakeClock()
        let stopGate = DarkWakeSleepGate()
        let (store, _) = try await makeStore()
        defer { store.stop() }

        let stoppedMonitor = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await stopGate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        stoppedMonitor.start(with: store, observeSystemEvents: false)
        stoppedMonitor.apply(.asleep(true))
        clock.advance(by: .seconds(5))
        stoppedMonitor.apply(.asleep(false))
        await stopGate.waitUntilParked()

        stoppedMonitor.stop()
        await stopGate.waitUntilCancelled()
        #expect(await stopGate.cancelledCount == 1)

        // Verify deinit teardown also cancels the timer even if stop() was not called.
        let teardownGate = DarkWakeSleepGate()
        var transientMonitor: SystemActivityMonitor? = SystemActivityMonitor(
            scheduler: DebouncedResumeScheduler(
                now: { clock.now },
                sleep: { duration in try await teardownGate.sleep(for: duration) }
            ),
            isDisplayAwake: { false }
        )
        transientMonitor?.start(with: store, observeSystemEvents: false)
        transientMonitor?.apply(.asleep(true))
        clock.advance(by: .seconds(5))
        transientMonitor?.apply(.asleep(false))
        await teardownGate.waitUntilParked()

        transientMonitor = nil
        await teardownGate.waitUntilCancelled()
        #expect(await teardownGate.cancelledCount == 1)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() async throws -> (HomeStore, ResumeCounter) {
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
            defaults: defaults
        )
        let counter = ResumeCounter()
        store.resumeDebounceInterval = .zero
        store.resumeMaxDelay = .zero
        store.onDebouncedResumeHook = { _ in
            await counter.increment()
        }
        store.completeOnboarding()
        try await store.waitForTestSnapshot()
        return (store, counter)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            await Task.yield()
        }
    }
}

private final class VirtualWakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { current } }

    func advance(by duration: Duration) {
        lock.withLock { current = current.advanced(by: duration) }
    }
}

private actor ResumeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor DarkWakeSleepGate {
    private(set) var requestedDurations: [Duration] = []
    private(set) var cancelledCount = 0
    private var waiter: CheckedContinuation<Void, Error>?
    private var parkedWaiter: CheckedContinuation<Void, Never>?
    private var cancelledWaiter: CheckedContinuation<Void, Never>?
    private var isParked = false

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cancelledCount += 1
                    cancelledWaiter?.resume()
                    cancelledWaiter = nil
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiter = cont
                isParked = true
                parkedWaiter?.resume()
                parkedWaiter = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilParked() async {
        if isParked { return }
        await withCheckedContinuation { cont in
            parkedWaiter = cont
        }
    }

    func waitUntilCancelled() async {
        if cancelledCount > 0 { return }
        await withCheckedContinuation { cont in
            cancelledWaiter = cont
        }
    }

    func release() {
        isParked = false
        waiter?.resume()
        waiter = nil
    }

    private func cancel() {
        isParked = false
        cancelledCount += 1
        let activeWaiter = waiter
        waiter = nil
        activeWaiter?.resume(throwing: CancellationError())
        cancelledWaiter?.resume()
        cancelledWaiter = nil
    }
}
