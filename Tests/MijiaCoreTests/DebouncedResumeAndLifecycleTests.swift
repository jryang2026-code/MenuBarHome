import Foundation
import Testing
@testable import MijiaCore

struct DebouncedResumeAndLifecycleTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    // MARK: - DebouncedResumeCoordinator

    @Test("Burst wake, display-wake, unlock, and network-restore notifications coalesce into one callback")
    @MainActor
    func burstNotificationsCoalesceIntoSingleResume() async throws {
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { ContinuousClock.now },
            sleep: { _ in await gate.sleep() }
        )
        let coordinator = DebouncedResumeCoordinator(
            debounceInterval: .milliseconds(300),
            maxDelay: .seconds(5),
            scheduler: scheduler,
            onResume: { reasons in
                await recorder.record(reasons)
            }
        )

        await coordinator.notify(.systemWake)
        await waitUntil { gate.parkCount == 1 && gate.waiting == 1 }

        await coordinator.notify(.displayWake)
        await waitUntil { gate.parkCount == 2 && gate.waiting == 1 }

        await coordinator.notify(.screenUnlocked)
        await waitUntil { gate.parkCount == 3 && gate.waiting == 1 }

        await coordinator.notify(.networkRestored)
        await waitUntil { gate.parkCount == 4 && gate.waiting == 1 }

        #expect(await recorder.calls.isEmpty)

        gate.release()
        await waitUntil { await recorder.calls.count == 1 }
        let recorded = await recorder.calls
        #expect(recorded.count == 1)
        #expect(recorded.first == [.systemWake, .displayWake, .screenUnlocked, .networkRestored])
        #expect(await coordinator.hasPendingResume == false)
    }

    @Test("Re-sleep, screen lock, or network loss cancels pending wake work")
    @MainActor
    func sleepLockAndNetworkDropCancelPendingResume() async throws {
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { ContinuousClock.now },
            sleep: { _ in await gate.sleep() }
        )
        let coordinator = DebouncedResumeCoordinator(
            debounceInterval: .milliseconds(300),
            scheduler: scheduler,
            onResume: { reasons in
                await recorder.record(reasons)
            }
        )

        // 1. Re-sleep cancels pending work
        await coordinator.notify(.systemWake)
        await waitUntil { gate.parkCount == 1 && gate.waiting == 1 }
        await coordinator.setSystemActive(false)
        await waitUntil { gate.waiting == 0 }
        #expect(await coordinator.hasPendingResume == false)
        #expect(await recorder.calls.isEmpty)

        // Notify while asleep is ignored
        await coordinator.notify(.displayWake)
        #expect(gate.parkCount == 1)
        await coordinator.setSystemActive(true)

        // 2. Screen lock cancels pending work
        await coordinator.notify(.systemWake)
        await waitUntil { gate.parkCount == 2 && gate.waiting == 1 }
        await coordinator.setScreenLocked(true)
        await waitUntil { gate.waiting == 0 }
        #expect(await coordinator.hasPendingResume == false)

        // Notify while locked is ignored
        await coordinator.notify(.networkRestored)
        #expect(gate.parkCount == 2)
        await coordinator.setScreenLocked(false)

        // 3. Network drop cancels pending work
        await coordinator.notify(.screenUnlocked)
        await waitUntil { gate.parkCount == 3 && gate.waiting == 1 }
        await coordinator.setNetworkSatisfied(false)
        await waitUntil { gate.waiting == 0 }
        #expect(await coordinator.hasPendingResume == false)
        #expect(await recorder.calls.isEmpty)
    }

    @Test("shutdown cancels pending debounce work, is idempotent, and ignores subsequent notifications")
    @MainActor
    func coordinatorShutdownCancelsAndIsIdempotent() async throws {
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { ContinuousClock.now },
            sleep: { _ in await gate.sleep() }
        )
        let coordinator = DebouncedResumeCoordinator(
            debounceInterval: .milliseconds(300),
            scheduler: scheduler,
            onResume: { reasons in
                await recorder.record(reasons)
            }
        )

        await coordinator.notify(.systemWake)
        await waitUntil { gate.parkCount == 1 && gate.waiting == 1 }

        await coordinator.shutdown()
        await waitUntil { gate.waiting == 0 }
        #expect(await coordinator.isShutdown)
        #expect(await coordinator.hasPendingResume == false)

        // Idempotent second shutdown and ignored notify afterwards
        await coordinator.shutdown()
        await coordinator.notify(.manual)
        #expect(gate.parkCount == 1)
        #expect(await recorder.calls.isEmpty)
    }

    @Test("Max delay clamp fires immediately once jitter reaches maxDelay")
    @MainActor
    func maxDelayClampPreventsStarvation() async throws {
        let clock = VirtualClock()
        let gate = SleepGate()
        let recordedSleeps = DurationRecorder()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { clock.now },
            sleep: { duration in
                await recordedSleeps.append(duration)
                await gate.sleep()
            }
        )
        let coordinator = DebouncedResumeCoordinator(
            debounceInterval: .milliseconds(300),
            maxDelay: .milliseconds(500),
            scheduler: scheduler,
            onResume: { reasons in
                await recorder.record(reasons)
            }
        )

        await coordinator.notify(.networkRestored)
        await waitUntil { gate.parkCount == 1 && gate.waiting == 1 }
        #expect(await recordedSleeps.values == [.milliseconds(300)])

        clock.advance(by: .milliseconds(250))
        await coordinator.notify(.networkRestored)
        await waitUntil { gate.parkCount == 2 && gate.waiting == 1 }
        #expect(await recordedSleeps.values == [.milliseconds(300), .milliseconds(250)])

        // Reaching the 500ms clamp fires without parking on another sleep.
        clock.advance(by: .milliseconds(250))
        await coordinator.notify(.networkRestored)
        await waitUntil { await recorder.calls.count == 1 }
        #expect(gate.parkCount == 2)
    }

    // MARK: - HomeStore + Resume Integration

    @Test("HomeStore coalesces burst resume notifications and cancels on lock, sleep, and shutdown")
    @MainActor
    func homeStoreDebouncedResumeLifecycle() async throws {
        let provider = CountingHomeProvider()
        let suite = "test.resume.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try await store.waitForTestSnapshot()

        let gate = SleepGate()
        store.resumeScheduler = DebouncedResumeScheduler(
            now: { ContinuousClock.now },
            sleep: { _ in await gate.sleep() }
        )

        store.scheduleDebouncedResume(reason: .systemWake)
        store.scheduleDebouncedResume(reason: .displayWake)
        store.scheduleDebouncedResume(reason: .screenUnlocked)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 1 }
        #expect(await provider.refreshCount == 0)

        gate.release()
        await waitUntil { await provider.refreshCount == 1 }

        // Screen lock cancels pending resume and preserves isScreenLocked contract
        store.scheduleDebouncedResume(reason: .networkRestored)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 1 }
        store.setScreenLocked(true)
        #expect(store.isScreenLocked == true)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 0 }
        #expect(await provider.refreshCount == 1)

        store.setScreenLocked(false)
        #expect(store.isScreenLocked == false)

        // System sleep cancels pending resume and preserves pollingContext / awayGap contracts
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 1 }
        store.setSystemActive(false)
        #expect(store.pollingContext.systemActive == false)
        #expect(store.awayGap.includesAway == true)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 0 }
        #expect(await provider.refreshCount == 1)

        // Re-activate, arm another resume, then shut down HomeStore cleanly
        store.setSystemActive(true)
        store.scheduleDebouncedResume(reason: .sessionActive)
        await store.flushResumeSync()
        await waitUntil { gate.waiting == 1 }

        await store.shutdown()
        await waitUntil { gate.waiting == 0 }
        #expect(store.debouncedResumeCoordinator == nil)
        #expect(store.isResumeShutdown == true)
        #expect(await provider.shutdownCount == 1)
        #expect(await provider.refreshCount == 1)

        // Post-shutdown resume calls are ignored
        store.scheduleDebouncedResume(reason: .manual)
        await store.flushResumeSync()
        #expect(store.debouncedResumeCoordinator == nil)
    }

    // MARK: - Provider & Client Lifecycle Cleanup

    @Test("HAWebSocketProvider shutdown is idempotent and invalidates session")
    func haWebSocketShutdownIsIdempotent() async throws {
        let provider = HAWebSocketProvider(
            baseURLString: "http://192.0.2.10:8123",
            token: "test-token",
            allowsToken: { _ in true }
        )

        let events = provider.events()
        let consumer = Task<[HomeProviderEvent], Never> {
            var collected: [HomeProviderEvent] = []
            for await event in events {
                collected.append(event)
            }
            return collected
        }

        // Wait until the connection loop creates at least one session (deterministic even when Linux fails ENETUNREACH in <1ms).
        await waitUntil {
            await provider.createdSessionCountForTesting >= 1
        }
        await provider.prepareSessionForTesting()
        #expect(await provider.hasActiveSessionForTesting)
        let baselineInvalidations = await provider.invalidatedSessionCountForTesting

        await provider.shutdown()
        #expect(await provider.isShutDownForTesting)
        #expect(await provider.hasActiveSessionForTesting == false)
        #expect(await provider.invalidatedSessionCountForTesting >= baselineInvalidations + 1)

        // Second shutdown & credential update after shutdown are idempotent no-ops
        let postShutdownInvalidations = await provider.invalidatedSessionCountForTesting
        let postShutdownCreations = await provider.createdSessionCountForTesting
        await provider.shutdown()
        await provider.updateCredentials(baseURLString: "http://192.0.2.11:8123", token: "test-token")
        #expect(await provider.hasActiveSessionForTesting == false)
        #expect(await provider.createdSessionCountForTesting == postShutdownCreations)
        #expect(await provider.invalidatedSessionCountForTesting == postShutdownInvalidations)

        let received = await consumer.value
        #expect(!received.isEmpty)
    }

    @Test("HAWebSocketProvider startup registry collector collects out-of-order replies and surfaces subscribe errors")
    func haStartupRegistryParallelCollectionAndErrorHandling() async throws {
        let provider = HAWebSocketProvider(
            baseURLString: "http://192.0.2.10:8123",
            token: "test-token",
            allowsToken: { _ in true }
        )
        await provider.resetStartupReplyState()

        let collectTask = Task {
            try await provider.collectInitialRegistryReplies()
        }

        // Deliver replies out of order: 4, 2, 5, 1, 3
        await provider.deliverStartupReply(id: 4, message: ["type": .string("result"), "id": .number(4), "success": .bool(true)])
        await provider.deliverStartupReply(id: 2, message: ["type": .string("result"), "id": .number(2), "success": .bool(true)])
        await provider.deliverStartupReply(id: 5, message: ["type": .string("result"), "id": .number(5), "success": .bool(true)])
        await provider.deliverStartupReply(id: 1, message: ["type": .string("result"), "id": .number(1), "success": .bool(true)])
        await provider.deliverStartupReply(id: 3, message: ["type": .string("result"), "id": .number(3), "success": .bool(true)])

        let replies = try await collectTask.value
        #expect(replies.count == 5)
        #expect(replies.map { $0["id"]?.intValue } == [1, 2, 3, 4, 5])

        // Verify subscribe_events (id 5) failure is not silently dropped
        await provider.resetStartupReplyState()
        let failingTask = Task {
            try await provider.collectInitialRegistryReplies()
        }
        await provider.deliverStartupReply(id: 1, message: ["type": .string("result"), "id": .number(1), "success": .bool(true)])
        await provider.deliverStartupReply(id: 5, message: ["type": .string("result"), "id": .number(5), "success": .bool(false)])

        do {
            _ = try await failingTask.value
            Issue.record("Expected rejected subscribe_events to throw")
        } catch let error as HAHomeSnapshot.ReadError {
            guard case .rejected = error else {
                Issue.record("Expected HAHomeSnapshot.ReadError.rejected, got \(error)")
                return
            }
        }
        await provider.shutdown()
    }

    @Test("LGWebOSClient shutdown is idempotent and clears session")
    func lgWebOSClientShutdownIsIdempotent() async throws {
        let client = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: true, host: "192.0.2.50"),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        await client.start()
        await waitUntil {
            await client.createdSessionCountForTesting >= 1
        }
        await client.prepareSessionForTesting()
        #expect(await client.hasActiveSessionForTesting)
        let baselineInvalidations = await client.invalidatedSessionCountForTesting

        await client.shutdown()
        #expect(await client.isShutDownForTesting)
        #expect(await client.hasActiveSessionForTesting == false)
        #expect(await client.invalidatedSessionCountForTesting >= baselineInvalidations + 1)

        // Second shutdown is idempotent and start() after shutdown is a no-op
        let postShutdownInvalidations = await client.invalidatedSessionCountForTesting
        let postShutdownCreations = await client.createdSessionCountForTesting
        await client.shutdown()
        await client.start()
        #expect(await client.hasActiveSessionForTesting == false)
        #expect(await client.createdSessionCountForTesting == postShutdownCreations)
        #expect(await client.invalidatedSessionCountForTesting == postShutdownInvalidations)
    }

    @Test("DualSourceHomeProvider shutdown awaits both sources in parallel and is idempotent")
    @MainActor
    func dualSourceShutdownParallelAndIdempotent() async throws {
        let ha = GatedShutdownProvider()
        let mi = GatedShutdownProvider()
        let suite = "test.dual.shutdown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let composite = HomeStore.makeComposite(
            homeAssistant: ha,
            xiaomiCloud: mi,
            defaults: defaults
        )

        let shutdownTask = Task {
            await composite.shutdown()
        }

        // Both children must enter shutdown concurrently before either finishes.
        await waitUntil {
            let haEntered = await ha.enterCount
            let miEntered = await mi.enterCount
            return haEntered == 1 && miEntered == 1
        }
        #expect(await ha.completedCount == 0)
        #expect(await mi.completedCount == 0)

        await ha.releaseShutdown()
        await mi.releaseShutdown()
        await shutdownTask.value

        #expect(await ha.completedCount == 1)
        #expect(await mi.completedCount == 1)

        // Idempotent second shutdown
        await composite.shutdown()
        #expect(await ha.enterCount == 2)
        #expect(await mi.enterCount == 2)
    }
}

// MARK: - Test Support

private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            current = current.advanced(by: duration)
        }
    }
}

private actor ResumeRecorder {
    private(set) var calls: [Set<ResumeReason>] = []

    func record(_ reasons: Set<ResumeReason>) {
        calls.append(reasons)
    }
}

private actor DurationRecorder {
    private(set) var values: [Duration] = []

    func append(_ duration: Duration) {
        values.append(duration)
    }
}

private actor CountingHomeProvider: HomeProvider {
    private(set) var refreshCount = 0
    private(set) var shutdownCount = 0
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task { await self.attach(cont) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(SynthesizedHome(devices: [ScheduledCommandTestSupport.ceiling], scenes: [])))
    }

    func execute(_ command: DeviceCommand) async throws {}

    func refreshNow() async {
        refreshCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
        continuation?.finish()
        continuation = nil
    }
}

private actor GatedShutdownProvider: HomeProvider {
    private(set) var enterCount = 0
    private(set) var completedCount = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var preReleased = false

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { _ in }
    }

    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}

    func shutdown() async {
        enterCount += 1
        if enterCount == 1 && !preReleased {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        completedCount += 1
    }

    func releaseShutdown() {
        preReleased = true
        waiter?.resume()
        waiter = nil
    }
}
