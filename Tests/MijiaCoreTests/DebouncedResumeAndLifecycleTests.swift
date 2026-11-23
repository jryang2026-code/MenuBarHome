import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct DebouncedResumeAndLifecycleTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    // MARK: - DebouncedResumeCoordinator

    @Test("Burst wake, display-wake, unlock, and network-restore notifications coalesce into one callback")
    @MainActor
    func burstNotificationsCoalesceIntoSingleResume() async throws {
        let clock = VirtualClock()
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { clock.now },
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
        let clock = VirtualClock()
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { clock.now },
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
        let clock = VirtualClock()
        let gate = SleepGate()
        let recorder = ResumeRecorder()
        let scheduler = DebouncedResumeScheduler(
            now: { clock.now },
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

    @Test("Wake rereads unavailable identity on a monotonic cooldown and defers provider work until an eligible resume")
    @MainActor
    func wakeIdentityRecovery() async throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")
        let blob = try #require(CredentialVault.encode([KeychainHelper.tokenAccount: Data("ha-token".utf8)]))
        let storage = MemoryVaultStorage(blob: blob)
        storage.readResult = .unavailable
        let provider = CountingHomeProvider()
        var providerStarts = 0
        let store = HomeStore(
            credentialVault: CredentialVault(storage: storage.storage),
            haProviderFactory: { _, _ in
                providerStarts += 1
                return provider
            },
            defaults: defaults
        )
        let clock = VirtualClock()
        store.resumeDebounceInterval = .zero
        store.resumeScheduler = DebouncedResumeScheduler(now: { clock.now })

        let launchReads = storage.reads
        store.setScreenLocked(true)
        store.scheduleDebouncedResume(reason: .systemWake)
        store.setScreenLocked(false)
        store.scheduleDebouncedResume(reason: .displayWake)
        store.scheduleDebouncedResume(reason: .networkRestored)
        await store.flushResumeSync()
        #expect(storage.reads == launchReads)

        store.setNetworkSatisfiedForResume(false)
        store.scheduleDebouncedResume(reason: .systemWake)
        #expect(storage.reads == launchReads + 1)
        #expect(store.isIdentityUncertain)
        #expect(store.toastNotice == nil)
        storage.readResult = nil
        clock.advance(by: .seconds(59))
        store.scheduleDebouncedResume(reason: .systemWake)
        #expect(storage.reads == launchReads + 1)
        #expect(store.isIdentityUncertain)

        clock.advance(by: .seconds(1))
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(storage.reads == launchReads + 2)
        #expect(!store.isIdentityUncertain && store.hasEnabledHASource)
        #expect(store.capabilityResolutionMode == .legacyPreserved && store.hasCompletedOnboarding)
        #expect(store.shouldSuppressBackgroundNetworkWork)
        #expect(providerStarts == 0)

        store.setScreenLocked(true)
        store.setNetworkSatisfiedForResume(true)
        store.scheduleDebouncedResume(reason: .networkRestored)
        await store.flushResumeSync()
        #expect(providerStarts == 0)

        store.setScreenLocked(false)
        store.scheduleDebouncedResume(reason: .screenUnlocked)
        await store.flushResumeSync()
        #expect(providerStarts == 1)
        #expect(await provider.refreshCount == 1)
        #expect(!store.shouldSuppressBackgroundNetworkWork)

        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(storage.reads == launchReads + 2 && storage.writes == 0)
        #expect(providerStarts == 1)
        #expect(await provider.refreshCount == 2)
        await store.shutdown()
    }

    @Test("Wake leaves corrupt records and legacy credential storage alone")
    @MainActor
    func wakeIdentityRecoveryDoesNotAdoptOrDiscard() async throws {
        let defaults = InMemoryUserDefaults()
        let corruptRemoval = Data("broken-removal".utf8)
        let legacyToken = Data("old-ha-token".utf8)
        let legacy = MemoryLegacyItems(
            [KeychainHelper.tokenAccount: legacyToken],
            unreadable: [KeychainHelper.tokenAccount]
        )
        let storage = MemoryVaultStorage()
        storage.readResult = .unavailable
        let store = HomeStore(
            provider: CountingHomeProvider(),
            credentialVault: CredentialVault(storage: storage.storage, legacy: legacy.legacy),
            defaults: defaults
        )
        let clock = VirtualClock()
        store.resumeDebounceInterval = .zero
        store.resumeScheduler = DebouncedResumeScheduler(now: { clock.now })
        storage.readResult = nil
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(store.isIdentityUncertain)
        #expect(storage.writes == 0 && legacy.remaining[KeychainHelper.tokenAccount] == legacyToken)

        legacy.allow(KeychainHelper.tokenAccount)
        defaults.set(corruptRemoval, forKey: ConnectionRemovalStore.storageKey)
        clock.advance(by: .seconds(60))
        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(store.identityMigrationDiagnostic == HomeStore.corruptConnectionRemovalDiagnostic)
        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == corruptRemoval)
        #expect(defaults.object(forKey: CapabilitySelectionStore.storageKey) == nil)
        #expect(store.toastNotice == nil)
        #expect(storage.writes == 0 && legacy.deletedAccounts.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.discardCorruptConnectionRemovalRecord(quarantineDirectory: directory))
        #expect(!store.isIdentityUncertain && store.hasEnabledHASource)
        #expect(storage.writes == 0 && legacy.deletedAccounts.isEmpty)
        await store.shutdown()
    }

    @Test("Wake does not confirm identity while the only Xiaomi session is still in legacy preferences")
    @MainActor
    func wakeLeavesUnmigratedXiaomiSessionAlone() async throws {
        let defaults = InMemoryUserDefaults()
        let session = Data("legacy-session".utf8)
        defaults.set(session, forKey: MiSessionStore.fallbackDefaultsKey)
        defaults.set("legacy-home", forKey: MiCloudProvider.selectedHomeKey)
        let storage = MemoryVaultStorage()
        storage.readResult = .unavailable
        let provider = CountingHomeProvider()
        let store = HomeStore(
            provider: provider,
            credentialVault: CredentialVault(storage: storage.storage),
            defaults: defaults
        )
        store.resumeDebounceInterval = .zero
        storage.readResult = nil

        store.scheduleDebouncedResume(reason: .systemWake)
        await store.flushResumeSync()
        #expect(store.isIdentityUncertain)
        #expect(await provider.refreshCount == 0)
        #expect(storage.writes == 0)
        #expect(defaults.data(forKey: MiSessionStore.fallbackDefaultsKey) == session)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == "legacy-home")
        #expect(defaults.object(forKey: CapabilitySelectionStore.storageKey) == nil)
        await store.shutdown()
    }

    @Test("HomeStore coalesces burst resume notifications and cancels on lock, sleep, and shutdown")
    @MainActor
    func homeStoreDebouncedResumeLifecycle() async throws {
        let provider = CountingHomeProvider()
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()

        let clock = VirtualClock()
        let gate = SleepGate()
        store.resumeScheduler = DebouncedResumeScheduler(
            now: { clock.now },
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

    @Test("performDebouncedResumeRefresh skips refresh when shutdown or provider swap happens across await")
    @MainActor
    func debouncedResumeRefreshRechecksShutdownAndProviderIdentityAfterAwait() async throws {
        // 1. Shutdown during await hook skips refreshNow()
        let shutdownProvider = CountingHomeProvider()
        let store1 = HomeStore(provider: shutdownProvider, defaults: InMemoryUserDefaults())
        try await store1.waitForTestSnapshot()
        store1.resumeDebounceInterval = .zero
        var hookRan1 = false
        store1.onDebouncedResumeHook = { _ in
            hookRan1 = true
            await store1.shutdown()
        }
        store1.scheduleDebouncedResume(reason: .systemWake)
        await store1.flushResumeSync()
        await waitUntil { hookRan1 && !store1.isPerformingResumeRefresh }
        #expect(await shutdownProvider.refreshCount == 0, "must not refresh after shutdown during hook await")

        // 2. Provider replacement during await hook skips refreshing old or swapped provider
        let oldProvider = CountingHomeProvider()
        let newProvider = CountingHomeProvider()
        let store2 = HomeStore(provider: oldProvider, defaults: InMemoryUserDefaults())
        try await store2.waitForTestSnapshot()
        store2.resumeDebounceInterval = .zero
        var hookRan2 = false
        store2.onDebouncedResumeHook = { _ in
            hookRan2 = true
            store2.provider = newProvider
        }
        store2.scheduleDebouncedResume(reason: .systemWake)
        await store2.flushResumeSync()
        await waitUntil { hookRan2 && !store2.isPerformingResumeRefresh }
        #expect(await oldProvider.refreshCount == 0, "old provider must not refresh after provider identity changed")
        #expect(await newProvider.refreshCount == 0, "stale resume must not refresh replacement provider")

        // 3. Provider replacement during refreshNow() skips starting LGWebOSClient
        let gatedProvider = GatedRefreshProvider()
        let store3 = HomeStore(provider: gatedProvider, defaults: InMemoryUserDefaults())
        try await store3.waitForTestSnapshot()
        store3.resumeDebounceInterval = .zero
        store3.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.0.2.55")
        let lgClient = LGWebOSClient(
            config: store3.lgConfig,
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        store3.lgWebOSClient = lgClient

        store3.scheduleDebouncedResume(reason: .systemWake)
        await waitUntil { await gatedProvider.enteredRefresh }
        store3.provider = CountingHomeProvider()
        await gatedProvider.releaseRefresh()
        await store3.flushResumeSync()
        await waitUntil { !store3.isPerformingResumeRefresh }
        #expect(await lgClient.hasConnectionLoopForTesting == false, "must not start LG client after provider swap during refresh")
        await lgClient.shutdown()
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
        let defaults = InMemoryUserDefaults()

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

private actor GatedRefreshProvider: HomeProvider {
    private(set) var enteredRefresh = false
    private var waiter: CheckedContinuation<Void, Never>?
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
        enteredRefresh = true
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func releaseRefresh() {
        waiter?.resume()
        waiter = nil
    }

    func shutdown() async {
        releaseRefresh()
        continuation?.finish()
        continuation = nil
    }
}
