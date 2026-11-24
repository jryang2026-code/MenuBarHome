import Foundation

/// Result reported back to `NSBackgroundActivityScheduler` (or a test double).
public enum BackgroundActivityResult: Equatable, Sendable {
    case finished
    case deferred
}

/// Injectable seam over `NSBackgroundActivityScheduler` so tests never wait on a real clock.
public protocol BackgroundActivityScheduling: AnyObject, Sendable {
    var identifier: String { get }
    var repeats: Bool { get set }
    var interval: TimeInterval { get set }
    var tolerance: TimeInterval { get set }
    var qualityOfService: QualityOfService { get set }
    var shouldDefer: Bool { get }
    func schedule(_ block: @escaping @Sendable (@escaping @Sendable (BackgroundActivityResult) -> Void) -> Void)
    func invalidate()
}

#if os(macOS)
/// Live macOS adapter backed by `NSBackgroundActivityScheduler`.
public final class SystemBackgroundActivityScheduler: BackgroundActivityScheduling, @unchecked Sendable {
    private let scheduler: NSBackgroundActivityScheduler

    public init(identifier: String) {
        self.scheduler = NSBackgroundActivityScheduler(identifier: identifier)
    }

    public var identifier: String { scheduler.identifier }
    public var repeats: Bool {
        get { scheduler.repeats }
        set { scheduler.repeats = newValue }
    }
    public var interval: TimeInterval {
        get { scheduler.interval }
        set { scheduler.interval = newValue }
    }
    public var tolerance: TimeInterval {
        get { scheduler.tolerance }
        set { scheduler.tolerance = newValue }
    }
    public var qualityOfService: QualityOfService {
        get { scheduler.qualityOfService }
        set { scheduler.qualityOfService = newValue }
    }
    public var shouldDefer: Bool { scheduler.shouldDefer }

    public func schedule(
        _ block: @escaping @Sendable (@escaping @Sendable (BackgroundActivityResult) -> Void) -> Void
    ) {
        scheduler.schedule { completion in
            block { result in
                completion(result == .deferred ? .deferred : .finished)
            }
        }
    }

    public func invalidate() {
        scheduler.invalidate()
    }
}
#endif

/// Schedules automatic update checks via `NSBackgroundActivityScheduler` plus a randomized
/// post-launch jitter delay so installs do not hit GitHub Releases simultaneously (#30).
@MainActor
public final class BackgroundUpdateScheduler {
    public static let defaultIdentifier = "com.jryang2026.MenuBarHome.updateCheck"
    public static let defaultInterval: TimeInterval = HomeStore.automaticUpdateCheckInterval
    /// One-sixth of the 6-hour interval so macOS can coalesce wakes and respect battery state.
    public static let defaultTolerance: TimeInterval = 3600
    /// Up to 30 minutes of post-launch jitter before the first automatic check.
    public static let defaultMaxInitialJitter: TimeInterval = 30 * 60

    public typealias ActivityFactory = @Sendable (String) -> any BackgroundActivityScheduling
    public typealias RandomUnitGenerator = @Sendable () -> Double
    public typealias DelayOperation = @Sendable (TimeInterval) async throws -> Void
    public typealias CheckOperation = @MainActor () async -> Date?

    private let identifier: String
    private let interval: TimeInterval
    private let tolerance: TimeInterval
    private let maxInitialJitter: TimeInterval
    private let makeActivity: ActivityFactory
    private let randomUnit: RandomUnitGenerator
    private let delay: DelayOperation
    private let now: @MainActor () -> Date
    private let performCheck: CheckOperation

    private var activeActivity: (any BackgroundActivityScheduling)?
    private var initialCheckTask: Task<Void, Never>?

    public private(set) var isRunning = false
    public private(set) var lastScheduledJitterDelay: TimeInterval?

    public init(
        identifier: String = defaultIdentifier,
        interval: TimeInterval = defaultInterval,
        tolerance: TimeInterval = defaultTolerance,
        maxInitialJitter: TimeInterval = defaultMaxInitialJitter,
        makeActivity: @escaping ActivityFactory,
        randomUnit: @escaping RandomUnitGenerator = { Double.random(in: 0..<1) },
        delay: @escaping DelayOperation = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        },
        now: @escaping @MainActor () -> Date = { Date() },
        performCheck: @escaping CheckOperation
    ) {
        self.identifier = identifier
        self.interval = interval
        self.tolerance = tolerance
        self.maxInitialJitter = max(0, maxInitialJitter)
        self.makeActivity = makeActivity
        self.randomUnit = randomUnit
        self.delay = delay
        self.now = now
        self.performCheck = performCheck
    }

    #if os(macOS)
    public convenience init(
        identifier: String = defaultIdentifier,
        interval: TimeInterval = defaultInterval,
        tolerance: TimeInterval = defaultTolerance,
        maxInitialJitter: TimeInterval = defaultMaxInitialJitter,
        randomUnit: @escaping RandomUnitGenerator = { Double.random(in: 0..<1) },
        delay: @escaping DelayOperation = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        },
        now: @escaping @MainActor () -> Date = { Date() },
        performCheck: @escaping CheckOperation
    ) {
        self.init(
            identifier: identifier,
            interval: interval,
            tolerance: tolerance,
            maxInitialJitter: maxInitialJitter,
            makeActivity: { SystemBackgroundActivityScheduler(identifier: $0) },
            randomUnit: randomUnit,
            delay: delay,
            now: now,
            performCheck: performCheck
        )
    }
    #endif

    public nonisolated static func computeInitialJitter(randomUnit: Double, maxJitter: TimeInterval) -> TimeInterval {
        guard maxJitter > 0, randomUnit.isFinite else { return 0 }
        return min(1.0, max(0.0, randomUnit)) * maxJitter
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            if !isRunning { start() }
        } else {
            stop()
        }
    }

    public func start() {
        stop()
        isRunning = true
        scheduleActivity()

        let jitterDelay = Self.computeInitialJitter(randomUnit: randomUnit(), maxJitter: maxInitialJitter)
        lastScheduledJitterDelay = jitterDelay
        let delayOperation = delay
        initialCheckTask = Task { @MainActor [weak self] in
            do { try await delayOperation(jitterDelay) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning else { return }
            _ = await self.performCheck()
        }
    }

    private func scheduleActivity(retryAt: Date? = nil) {
        activeActivity?.invalidate()
        let activity = makeActivity(retryAt == nil ? identifier : identifier + ".retry")
        activity.repeats = retryAt == nil
        activity.interval = retryAt.map { max(1, $0.timeIntervalSince(now()).rounded(.up)) } ?? interval
        activity.tolerance = retryAt == nil ? tolerance : 0
        activity.qualityOfService = .utility
        activeActivity = activity

        activity.schedule { [weak self, weak activity] completion in
            guard let activity else { completion(.finished); return }
            if activity.shouldDefer { completion(.deferred); return }
            Task { @MainActor [weak self, weak activity] in
                guard let self, let activity, self.isRunning, self.activeActivity === activity else {
                    completion(.finished)
                    return
                }
                if activity.shouldDefer { completion(.deferred); return }
                let retryAt = await self.performCheck()
                guard self.activeActivity === activity else {
                    completion(.finished)
                    return
                }
                if let retryAt {
                    // Replace the early repeat with a fresh delay to the persisted deadline.
                    completion(.finished)
                    self.scheduleActivity(retryAt: retryAt)
                } else if activity.shouldDefer {
                    completion(.deferred)
                } else {
                    completion(.finished)
                    if !activity.repeats { self.scheduleActivity() }
                }
            }
        }
    }

    public func stop() {
        isRunning = false
        initialCheckTask?.cancel()
        initialCheckTask = nil
        activeActivity?.invalidate()
        activeActivity = nil
    }
}
