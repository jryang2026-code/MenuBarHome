import Foundation

/// Reason a system/network resume refresh was requested.
public enum ResumeReason: String, Hashable, Sendable, CaseIterable {
    case systemWake
    case displayWake
    case screenUnlocked
    case sessionActive
    case networkRestored
    case manual
}

/// Injectable monotonic clock and sleep seam so resume debounce tests never race wall-clock timers.
public struct DebouncedResumeScheduler: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = DebouncedResumeScheduler()
}

/// Coalesces burst system-wake, display-wake, unlock, session-active, and network-restore events
/// within a debounce window into a single background refresh callback, only when the Mac is active,
/// unlocked, and connected. Re-sleep, lock, network loss, or `shutdown()` cancels pending work.
public actor DebouncedResumeCoordinator {
    private let debounceInterval: Duration
    private let maxDelay: Duration
    private let scheduler: DebouncedResumeScheduler
    private let onResume: @Sendable (Set<ResumeReason>) async -> Void

    public private(set) var isSystemActive: Bool
    public private(set) var isScreenLocked: Bool
    public private(set) var isNetworkSatisfied: Bool
    public private(set) var isShutdown: Bool = false

    private var pendingReasons: Set<ResumeReason> = []
    private var burstStartedAt: ContinuousClock.Instant?
    private var debounceTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public var hasPendingResume: Bool { debounceTask != nil }

    private var isEligibleToResume: Bool {
        !isShutdown && isSystemActive && !isScreenLocked && isNetworkSatisfied
    }

    public init(
        debounceInterval: Duration = .milliseconds(300),
        maxDelay: Duration = .seconds(5),
        scheduler: DebouncedResumeScheduler = .live,
        initiallyActive: Bool = true,
        initiallyLocked: Bool = false,
        initiallyNetworkSatisfied: Bool = true,
        onResume: @escaping @Sendable (Set<ResumeReason>) async -> Void
    ) {
        self.debounceInterval = max(.zero, debounceInterval)
        self.maxDelay = max(.zero, maxDelay)
        self.scheduler = scheduler
        self.isSystemActive = initiallyActive
        self.isScreenLocked = initiallyLocked
        self.isNetworkSatisfied = initiallyNetworkSatisfied
        self.onResume = onResume
    }

    public func setSystemActive(_ active: Bool) {
        guard !isShutdown else { return }
        isSystemActive = active
        if !active {
            cancelPending()
        }
    }

    public func setScreenLocked(_ locked: Bool) {
        guard !isShutdown else { return }
        isScreenLocked = locked
        if locked {
            cancelPending()
        }
    }

    public func setNetworkSatisfied(_ satisfied: Bool) {
        guard !isShutdown else { return }
        isNetworkSatisfied = satisfied
        if !satisfied {
            cancelPending()
        }
    }

    public func notify(_ reason: ResumeReason) async {
        guard isEligibleToResume else {
            cancelPending()
            return
        }

        let currentNow = scheduler.now()
        if burstStartedAt == nil {
            burstStartedAt = currentNow
        }
        pendingReasons.insert(reason)

        let elapsed = burstStartedAt.map { max(.zero, $0.duration(to: currentNow)) } ?? .zero
        let remainingToMax = max(.zero, maxDelay - elapsed)
        let waitDuration = min(debounceInterval, remainingToMax)

        if waitDuration <= .zero {
            await firePendingIfEligible()
            return
        }

        generation &+= 1
        let token = generation
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.scheduler.sleep(waitDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.completeTimer(token: token)
        }
    }

    public func cancelPending() {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingReasons.removeAll()
        burstStartedAt = nil
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelPending()
    }

    private func completeTimer(token: UInt64) async {
        guard token == generation, isEligibleToResume else { return }
        await firePendingIfEligible()
    }

    private func firePendingIfEligible() async {
        guard isEligibleToResume else {
            cancelPending()
            return
        }
        let reasons = pendingReasons
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingReasons.removeAll()
        burstStartedAt = nil
        guard !reasons.isEmpty else { return }
        await onResume(reasons)
    }
}
