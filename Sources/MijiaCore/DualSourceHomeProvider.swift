import Dispatch
import Foundation

/// Synchronous single-slot timer handle used by `DualSourceHomeProvider` for fallback grace
/// rechecks (#25).
///
/// Re-arming one `DispatchSourceTimer` in place avoids spawning and cancelling an `async` sleeper
/// `Task` on every recompute, which tripped the Swift 6 `x86_64` concurrency runtime abort
/// (`swift_task_dealloc`: "freed pointer was not the last allocation") under parallel CI (#274).
protocol FallbackRecheckTimer: Sendable {
    /// Replaces any currently armed deadline with a new one-shot fire after `delay`.
    func schedule(after delay: Duration, onFire: @escaping @Sendable () -> Void)
    /// Disarms any pending fire while keeping the timer reusable for later schedules.
    func cancelPending()
    /// Permanently invalidates the timer during shutdown, preventing further schedules; a callback
    /// already dequeued before invalidation may still arrive and must be guarded by the caller.
    func invalidate()
}

final class DispatchFallbackRecheckTimer: FallbackRecheckTimer, @unchecked Sendable {
    private static let defaultQueue = DispatchQueue(
        label: "com.jryang1997.MenuBarMijia.DualSourceFallbackRecheck",
        qos: .utility
    )

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var desiredID: UInt64 = 0
    private var desiredHandler: (@Sendable () -> Void)?
    private var isInvalidated = false

    // Accessed only on `queue` while `self` is alive, and once in `deinit` after the last
    // strong reference drops.
    private var timer: DispatchSourceTimer?
    private var armedOnQueueID: UInt64 = 0

    init(queue: DispatchQueue = DispatchFallbackRecheckTimer.defaultQueue) {
        self.queue = queue
    }

    deinit {
        timer?.cancel()
    }

    func schedule(after delay: Duration, onFire: @escaping @Sendable () -> Void) {
        let deadline = DispatchTime.now() + Self.dispatchTimeInterval(from: delay)
        let id: UInt64 = lock.withLock {
            guard !isInvalidated else { return 0 }
            desiredID &+= 1
            if desiredID == 0 { desiredID = 1 }
            desiredHandler = onFire
            return desiredID
        }
        guard id != 0 else { return }
        queue.async { [weak self] in
            self?.applyScheduleOnQueue(id: id, deadline: deadline)
        }
    }

    func cancelPending() {
        let shouldDisarm = lock.withLock { () -> Bool in
            guard !isInvalidated, desiredHandler != nil else { return false }
            desiredID &+= 1
            if desiredID == 0 { desiredID = 1 }
            desiredHandler = nil
            return true
        }
        guard shouldDisarm else { return }
        queue.async { [weak self] in
            self?.disarmIfIdleOnQueue()
        }
    }

    func invalidate() {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !isInvalidated else { return false }
            isInvalidated = true
            desiredID &+= 1
            if desiredID == 0 { desiredID = 1 }
            desiredHandler = nil
            return true
        }
        guard shouldCancel else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.armedOnQueueID = 0
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func applyScheduleOnQueue(id: UInt64, deadline: DispatchTime) {
        let stillDesired = lock.withLock { !isInvalidated && desiredID == id }
        guard stillDesired else { return }
        armedOnQueueID = id
        ensureTimerOnQueue().schedule(deadline: deadline, leeway: .milliseconds(200))
    }

    private func disarmIfIdleOnQueue() {
        let stillIdle = lock.withLock { !isInvalidated && desiredHandler == nil }
        guard stillIdle else { return }
        armedOnQueueID = 0
        timer?.schedule(deadline: .distantFuture)
    }

    private func ensureTimerOnQueue() -> DispatchSourceTimer {
        if let existing = timer {
            return existing
        }
        let created = DispatchSource.makeTimerSource(queue: queue)
        created.setEventHandler { [weak self] in
            self?.handleTimerEventOnQueue()
        }
        created.schedule(deadline: .distantFuture)
        created.resume()
        timer = created
        return created
    }

    private func handleTimerEventOnQueue() {
        let id = armedOnQueueID
        guard id != 0 else { return }
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !isInvalidated, desiredID == id else { return nil }
            let next = desiredHandler
            desiredHandler = nil
            return next
        }
        guard let handler else { return }
        armedOnQueueID = 0
        handler()
    }

    private static func dispatchTimeInterval(from delay: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = delay.components
        if seconds < 0 || (seconds == 0 && attoseconds <= 0) {
            return .nanoseconds(0)
        }
        let maxSecondsForNanos = Int64(Int.max / 1_000_000_000)
        if seconds >= maxSecondsForNanos {
            return .seconds(Int(min(seconds, Int64(Int.max))))
        }
        let totalNanos = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(max(0, min(totalNanos, Int64(Int.max)))))
    }
}

private final class DisabledBackendsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var disabled: Set<HomeBackend> = []
    private var generations: [HomeBackend: UInt64] = [:]

    @discardableResult
    func markDisabled(_ backend: HomeBackend) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        disabled.insert(backend)
        let next = (generations[backend] ?? 0) &+ 1
        generations[backend] = next
        return next
    }

    func currentGeneration(for backend: HomeBackend) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generations[backend] ?? 0
    }

    func enableIfGenerationMatches(_ backend: HomeBackend, expectedGeneration: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedGeneration else { return !disabled.contains(backend) }
        guard (generations[backend] ?? 0) == expectedGeneration else { return false }
        disabled.remove(backend)
        return true
    }

    func contains(_ backend: HomeBackend) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabled.contains(backend)
    }

    func snapshot() -> Set<HomeBackend> {
        lock.lock()
        defer { lock.unlock() }
        return disabled
    }
}

private final class DisabledXiaomiAccountsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var disabled: Set<String> = []
    private var revocationVersions: [String: UInt64] = [:]

    func markDisabled(_ accountIDs: Set<String>) -> [String: UInt64] {
        lock.withLock {
            var revocations: [String: UInt64] = [:]
            for accountID in accountIDs where !accountID.isEmpty {
                disabled.insert(accountID)
                let version = (revocationVersions[accountID] ?? 0) &+ 1
                revocationVersions[accountID] = version
                revocations[accountID] = version
            }
            return revocations
        }
    }

    func markEnabled(_ accountID: String) {
        lock.withLock {
            _ = disabled.remove(accountID)
        }
    }

    func snapshot() -> (disabled: Set<String>, revocationVersions: [String: UInt64]) {
        lock.withLock {
            (disabled, revocationVersions)
        }
    }
}

/// Monotonic (insert/update only, never delete) source-native id ↔ canonical card id table for
/// `DualSourceHomeProvider` (#303, #325). Shared via `NSLock` so `HomeStore` can expand
/// `starredDeviceIds` synchronously when publishing type-pruning policies, even after a device
/// type is closed or one source disconnects.
private final class CanonicalSourceIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var haToCanonical: [String: String] = [:]
    private var miToCanonical: [String: String] = [:]

    init(initialAssignments: [String: String] = [:]) {
        for (key, canonicalID) in initialAssignments where !canonicalID.isEmpty {
            if key.hasPrefix("ha:") {
                let sourceID = String(key.dropFirst(3))
                if !sourceID.isEmpty { haToCanonical[sourceID] = canonicalID }
            } else if key.hasPrefix("mi:") {
                let sourceID = String(key.dropFirst(3))
                if !sourceID.isEmpty { miToCanonical[sourceID] = canonicalID }
            } else if key.hasPrefix("pair:") {
                let body = key.dropFirst(5)
                if let sep = body.firstIndex(of: "|") {
                    let haID = String(body[..<sep])
                    let miID = String(body[body.index(after: sep)...])
                    if !haID.isEmpty, haToCanonical[haID] == nil { haToCanonical[haID] = canonicalID }
                    if !miID.isEmpty, miToCanonical[miID] == nil { miToCanonical[miID] = canonicalID }
                }
            }
        }
    }

    func merge(haCanonicalIDs: [String: String], miCanonicalIDs: [String: String]) {
        guard !haCanonicalIDs.isEmpty || !miCanonicalIDs.isEmpty else { return }
        lock.withLock {
            for (sourceID, canonicalID) in haCanonicalIDs where !sourceID.isEmpty && !canonicalID.isEmpty {
                haToCanonical[sourceID] = canonicalID
            }
            for (sourceID, canonicalID) in miCanonicalIDs where !sourceID.isEmpty && !canonicalID.isEmpty {
                miToCanonical[sourceID] = canonicalID
            }
        }
    }

    func canonicalID(forSourceID sourceID: String, backend: HomeBackend) -> String? {
        lock.withLock {
            switch backend {
            case .homeAssistant: return haToCanonical[sourceID]
            case .xiaomiCloud: return miToCanonical[sourceID]
            case .demo: return nil
            }
        }
    }

    func sourceIDs(forCanonicalIDs canonicalIDs: Set<String>, backend: HomeBackend) -> Set<String> {
        guard !canonicalIDs.isEmpty else { return [] }
        return lock.withLock {
            let map: [String: String]
            switch backend {
            case .homeAssistant: map = haToCanonical
            case .xiaomiCloud: map = miToCanonical
            case .demo: return []
            }
            var result: Set<String> = []
            for (sourceID, canonicalID) in map where canonicalIDs.contains(canonicalID) {
                result.insert(sourceID)
            }
            return result
        }
    }

    func canonicalToSourceIDs(for backend: HomeBackend) -> [String: Set<String>] {
        lock.withLock {
            let map: [String: String]
            switch backend {
            case .homeAssistant: map = haToCanonical
            case .xiaomiCloud: map = miToCanonical
            case .demo: return [:]
            }
            var reverse: [String: Set<String>] = [:]
            for (sourceID, canonicalID) in map {
                reverse[canonicalID, default: []].insert(sourceID)
            }
            return reverse
        }
    }
}

/// Keeps both providers connected and publishes one merged home. Commands are routed by their
/// target address, so an entity id decides the source without a second lookup table.
public actor DualSourceHomeProvider: HomeProvider {
    public typealias CanonicalIDPersistence = @Sendable ([String: String]) -> Void

    /// How long a configured source that just dropped stays trusted for routing after its last
    /// snapshot (#25). A Wi-Fi roam, a wake-from-sleep reconnect or a websocket blip resolves in
    /// seconds; within this window the paired cards keep their winning source and an active live
    /// camera keeps playing, so neither flips back and forth. A real outage outlasts it and the
    /// ordinary online-first fallback takes over, closing the dead source's stream explicitly.
    public static let sourceFallbackGrace: TimeInterval = 15
    static let sourceFallbackGraceDuration: Duration = .seconds(15)

    private var homeAssistant: (any HomeProvider)?
    private var xiaomiCloud: (any HomeProvider)?
    private let knownPreferenceIDs: @Sendable () -> Set<String>
    private let pinnedBackends: @Sendable () -> [String: HomeBackend]
    private let persistCanonicalIDs: CanonicalIDPersistence
    private let graceNowProvider: @Sendable () -> SuspendingClock.Instant
    private let fallbackRecheckTimer: any FallbackRecheckTimer
    private let disabledBackendsGate = DisabledBackendsGate()
    private let disabledXiaomiAccountsGate = DisabledXiaomiAccountsGate()

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var haTask: Task<Void, Never>?
    private var miTask: Task<Void, Never>?
    private var started = false
    private var isShutDown = false
    private var pollingContext = PollingContext()

    private var haStatus: ConnectionStatus = .connecting
    private var miStatus: ConnectionStatus = .connecting
    /// Suspending-clock instant when each source or Xiaomi account last dropped while holding a
    /// snapshot (#25). `SuspendingClock` halts across kernel sleep, and `inactiveSince` freezes
    /// active grace while `pollingContext.systemActive` is false.
    private var haOfflineSince: SuspendingClock.Instant?
    private var miOfflineSince: SuspendingClock.Instant?
    private struct PreDropXiaomiDevice: Sendable {
        let device: SmartDevice
        let identity: DeviceSourceIdentity?
        let wasPrimaryOwner: Bool
    }

    private var miAccountStatuses: [String: ConnectionStatus] = [:]
    private var miAccountOfflineSince: [String: SuspendingClock.Instant] = [:]
    private var miAccountPreDropDevices: [String: [String: PreDropXiaomiDevice]] = [:]
    private var miExpiredAccountIDs: Set<String> = []
    private var appliedXiaomiRevocationVersions: [String: UInt64] = [:]
    private var inactiveSince: SuspendingClock.Instant?
    private var haGraceActiveInLastRecompute = false
    private var miGraceActiveInLastRecompute = false
    private var miGracedAccountsInLastRecompute: Set<String> = []
    /// Monotonic generation token guarding scheduled fallback recheck wakes (#25).
    private var fallbackRecheckGeneration: UInt64 = 0
    private(set) var discardedFallbackWakeCountForTesting = 0
    private var haSnapshot: SynthesizedHome?
    private var miSnapshot: SynthesizedHome?
    private var haLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var miLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var lastEmittedLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var lastStatus: ConnectionStatus?

    private var canonical: CanonicalDeviceRegistry
    private let canonicalSourceIDs: CanonicalSourceIDBox
    private var rooms = RoomIdentityRegistry()
    private var routes: [String: DeviceMergeRoute] = [:]
    private var activeCameraRoutes: [String: DeviceMergeRoute] = [:]
    /// Merged card id → recent emitted press timestamps per backend. Keeping a bounded history
    /// rather than only the latest timestamp lets a delayed poll from the slower source still
    /// recognize an earlier press after a newer press has already arrived (#23).
    private var doorbellPressesByCard: [String: [HomeBackend: [Date]]] = [:]

    /// A doorbell press the two sources both report within this window counts once (#23). Both
    /// timestamps come from the device's own event clock, so cross-source skew stays far under
    /// the window; a human double-press (plus the doorbell's own debounce) spans well over it.
    /// The window is a fixed constant, so the boundary is deterministic and testable.
    static let crossSourceDoorbellDedupWindow: TimeInterval = 2

    /// Maximum event-time age an unmatched press stays in history to pair with a delayed report
    /// from the other source (#23).
    static let crossSourceDoorbellHistoryRetention: TimeInterval = 120

    /// Maximum unmatched presses retained per card and source so rapid presses cannot grow
    /// history without bound (#23).
    static let crossSourceDoorbellHistoryLimit = 16

    /// Maximum distinct cards retained in doorbell dedupe history.
    static let crossSourceDoorbellCardLimit = 64

    var isShutDownForTesting: Bool { isShutDown }

    func doorbellPressHistoryCountForTesting(cardID: String, backend: HomeBackend) -> Int {
        doorbellPressesByCard[cardID]?[backend]?.count ?? 0
    }

    var doorbellTrackedCardCountForTesting: Int {
        doorbellPressesByCard.count
    }

    public init(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        initialCanonicalIDs: [String: String] = [:],
        knownPreferenceIDs: @escaping @Sendable () -> Set<String> = { [] },
        pinnedBackends: @escaping @Sendable () -> [String: HomeBackend] = { [:] },
        persistCanonicalIDs: @escaping CanonicalIDPersistence = { _ in }
    ) {
        self.init(
            homeAssistant: homeAssistant,
            xiaomiCloud: xiaomiCloud,
            initialCanonicalIDs: initialCanonicalIDs,
            knownPreferenceIDs: knownPreferenceIDs,
            pinnedBackends: pinnedBackends,
            persistCanonicalIDs: persistCanonicalIDs,
            graceNow: { SuspendingClock.now },
            fallbackRecheckTimer: DispatchFallbackRecheckTimer()
        )
    }

    init(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        initialCanonicalIDs: [String: String] = [:],
        knownPreferenceIDs: @escaping @Sendable () -> Set<String> = { [] },
        pinnedBackends: @escaping @Sendable () -> [String: HomeBackend] = { [:] },
        persistCanonicalIDs: @escaping CanonicalIDPersistence = { _ in },
        graceNow: @escaping @Sendable () -> SuspendingClock.Instant,
        fallbackRecheckTimer: any FallbackRecheckTimer
    ) {
        self.homeAssistant = homeAssistant
        self.xiaomiCloud = xiaomiCloud
        self.canonical = CanonicalDeviceRegistry(assignments: initialCanonicalIDs)
        self.canonicalSourceIDs = CanonicalSourceIDBox(initialAssignments: initialCanonicalIDs)
        self.knownPreferenceIDs = knownPreferenceIDs
        self.pinnedBackends = pinnedBackends
        self.persistCanonicalIDs = persistCanonicalIDs
        self.graceNowProvider = graceNow
        self.fallbackRecheckTimer = fallbackRecheckTimer
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        guard !isShutDown else {
            cont.finish()
            return
        }
        continuation = cont
        start()
    }

    public func start() {
        guard !isShutDown else { return }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !isShutDown, !started else { return }
        started = true
        if let homeAssistant {
            startForwarding(homeAssistant, for: .homeAssistant)
        }
        if let xiaomiCloud {
            startForwarding(xiaomiCloud, for: .xiaomiCloud)
        }
        emitStatus(force: true)
        emitSourceStatuses()
    }

    private func startForwarding(_ source: any HomeProvider, for backend: HomeBackend) {
        let task = Task { [weak self] in
            for await event in source.events() {
                guard !Task.isCancelled, let self else { return }
                await self.handle(event, from: backend)
            }
            guard !Task.isCancelled else { return }
            await self?.sourceStreamFinished(backend)
        }
        switch backend {
        case .homeAssistant:
            haTask?.cancel()
            haTask = task
        case .xiaomiCloud:
            miTask?.cancel()
            miTask = task
        case .demo:
            task.cancel()
        }
    }

    private func clearXiaomiAccountGraceState() {
        miAccountStatuses.removeAll()
        miAccountOfflineSince.removeAll()
        miAccountPreDropDevices.removeAll()
        miExpiredAccountIDs.removeAll()
        miGracedAccountsInLastRecompute.removeAll()
    }

    public func invalidateSnapshot(for backend: HomeBackend) {
        guard !isShutDown else { return }
        if backend == .homeAssistant, homeAssistant != nil {
            haSnapshot = nil
            haStatus = .connecting
            haOfflineSince = nil
            haGraceActiveInLastRecompute = false
            haLocalNetworkBlocks = []
        } else if backend == .xiaomiCloud, xiaomiCloud != nil {
            miSnapshot = nil
            miStatus = .connecting
            miOfflineSince = nil
            miGraceActiveInLastRecompute = false
            clearXiaomiAccountGraceState()
            miLocalNetworkBlocks = []
        } else {
            return
        }
        guard started else { return }
        emitStatus(force: true)
        emitSourceStatuses()
        emitLocalNetworkPermission()
        recompute()
    }

    /// Canonical card id → known Mi source device ids (monotonic across pruning and source drops, #303).
    public nonisolated var canonicalToMiSourceIDs: [String: Set<String>] {
        canonicalSourceIDs.canonicalToSourceIDs(for: .xiaomiCloud)
    }

    /// Canonical card id → known Home Assistant native device ids (monotonic across pruning and source drops, #325).
    public nonisolated var canonicalToHASourceIDs: [String: Set<String>] {
        canonicalSourceIDs.canonicalToSourceIDs(for: .homeAssistant)
    }

    public nonisolated func miSourceIDs(forCanonicalIDs canonicalIDs: Set<String>) -> Set<String> {
        canonicalSourceIDs.sourceIDs(forCanonicalIDs: canonicalIDs, backend: .xiaomiCloud)
    }

    public nonisolated func haSourceIDs(forCanonicalIDs canonicalIDs: Set<String>) -> Set<String> {
        canonicalSourceIDs.sourceIDs(forCanonicalIDs: canonicalIDs, backend: .homeAssistant)
    }

    public nonisolated func canonicalID(forSourceID sourceID: String, backend: HomeBackend) -> String? {
        canonicalSourceIDs.canonicalID(forSourceID: sourceID, backend: backend)
    }

    /// Synchronously seals off reads, writes, and events for `backend` before async provider
    /// teardown reaches the actor, closing the disable-to-shutdown request window.
    @discardableResult
    public nonisolated func markBackendDisabled(_ backend: HomeBackend) -> UInt64 {
        disabledBackendsGate.markDisabled(backend)
    }

    public nonisolated func disableGeneration(for backend: HomeBackend) -> UInt64 {
        disabledBackendsGate.currentGeneration(for: backend)
    }

    /// Synchronously revokes grace eligibility for a disabled or signed-out Xiaomi account before
    /// async provider updates reach the actor, preventing cached pre-drop copies from being picked.
    @discardableResult
    public nonisolated func markXiaomiAccountDisabled(_ accountID: String) -> [String: UInt64] {
        markXiaomiAccountsDisabled([accountID])
    }

    @discardableResult
    public nonisolated func markXiaomiAccountsDisabled(_ accountIDs: Set<String>) -> [String: UInt64] {
        disabledXiaomiAccountsGate.markDisabled(accountIDs)
    }

    public nonisolated func markXiaomiAccountEnabled(_ accountID: String) {
        disabledXiaomiAccountsGate.markEnabled(accountID)
    }

    public func revokeXiaomiAccountsGrace(_ revocations: [String: UInt64]) {
        guard !isShutDown, !revocations.isEmpty else { return }
        let (disabled, versions) = disabledXiaomiAccountsGate.snapshot()
        let currentRevocations = revocations.filter { accountID, version in
            disabled.contains(accountID) && versions[accountID] == version
        }
        guard !currentRevocations.isEmpty else { return }
        applyXiaomiAccountRevocations(currentRevocations)
        guard started else { return }
        emitStatus()
        emitSourceStatuses()
        emitLocalNetworkPermission()
        recompute()
    }

    private func pruneRevokedXiaomiAccountGraceState() -> Set<String> {
        let (disabled, versions) = disabledXiaomiAccountsGate.snapshot()
        applyXiaomiAccountRevocations(versions)
        return disabled
    }

    private func applyXiaomiAccountRevocations(_ versions: [String: UInt64]) {
        for (accountID, version) in versions where appliedXiaomiRevocationVersions[accountID] != version {
            appliedXiaomiRevocationVersions[accountID] = version
            miAccountPreDropDevices.removeValue(forKey: accountID)
            miAccountOfflineSince.removeValue(forKey: accountID)
            miAccountStatuses.removeValue(forKey: accountID)
            miExpiredAccountIDs.remove(accountID)
            miGracedAccountsInLastRecompute.remove(accountID)
        }
    }

    /// Attaching without a generation requires the backend to still be enabled.
    public func setSourceProvider(
        _ next: (any HomeProvider)?,
        for backend: HomeBackend,
        expectedDisableGeneration: UInt64? = nil
    ) async {
        guard !isShutDown else {
            await next?.shutdown()
            return
        }
        if let next, expectedDisableGeneration == nil, disabledBackendsGate.contains(backend) {
            await next.shutdown()
            return
        }
        let previous: (any HomeProvider)?
        var tornDownCameraRoutes: [DeviceMergeRoute] = []
        if next == nil {
            for (deviceId, route) in activeCameraRoutes where route.backend == backend {
                activeCameraRoutes.removeValue(forKey: deviceId)
                tornDownCameraRoutes.append(route)
            }
        }
        if backend == .homeAssistant {
            haTask?.cancel()
            haTask = nil
            previous = homeAssistant
            homeAssistant = nil
            haSnapshot = nil
            haStatus = .connecting
            haOfflineSince = nil
            haGraceActiveInLastRecompute = false
            haLocalNetworkBlocks = []
        } else {
            miTask?.cancel()
            miTask = nil
            previous = xiaomiCloud
            xiaomiCloud = nil
            miSnapshot = nil
            miStatus = .connecting
            miOfflineSince = nil
            miGraceActiveInLastRecompute = false
            clearXiaomiAccountGraceState()
            miLocalNetworkBlocks = []
        }
        for route in tornDownCameraRoutes {
            await previous?.stopCameraStream(for: route.sourceDevice)
        }
        await previous?.shutdown()
        guard !isShutDown else {
            await next?.shutdown()
            return
        }
        if let next {
            if !disabledBackendsGate.enableIfGenerationMatches(backend, expectedGeneration: expectedDisableGeneration) {
                await next.shutdown()
            } else {
                if backend == .homeAssistant {
                    homeAssistant = next
                } else {
                    xiaomiCloud = next
                }
                if started {
                    startForwarding(next, for: backend)
                    await next.setPollingContext(pollingContext)
                }
            }
        }
        guard started, !isShutDown else { return }
        emitStatus(force: true)
        emitSourceStatuses()
        emitLocalNetworkPermission()
        if previous != nil {
            recompute(allowEmpty: homeAssistant == nil && xiaomiCloud == nil)
        }
    }

    private func handle(_ event: HomeProviderEvent, from backend: HomeBackend) {
        guard !isShutDown, !disabledBackendsGate.contains(backend) else { return }
        if backend == .homeAssistant, homeAssistant == nil { return }
        if backend == .xiaomiCloud, xiaomiCloud == nil { return }
        switch event {
        case .statusChanged(let status):
            let now = effectiveGraceNow()
            if backend == .homeAssistant {
                recordStatusTransition(status, previous: haStatus, offlineSince: &haOfflineSince, now: now)
                haStatus = status
                if case .connected = status { haLocalNetworkBlocks.remove(.homeAssistant) }
            } else if backend == .xiaomiCloud {
                let allKnownExpired = !miExpiredAccountIDs.isEmpty
                    && (miAccountStatuses.isEmpty || miAccountStatuses.keys.allSatisfy { miExpiredAccountIDs.contains($0) })
                if allKnownExpired {
                    miOfflineSince = nil
                    if !status.isConnected {
                        miStatus = status
                    }
                } else {
                    recordXiaomiStatusTransition(status, previous: miStatus, now: now)
                    miStatus = status
                }
            }
            emitStatus()
            emitSourceStatuses()
            emitLocalNetworkPermission()
            recompute()

        case .sessionExpired(let session):
            if backend == .xiaomiCloud {
                let expiredID = MiAccount(session: session).id
                let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
                let previousMiStatus = miStatus
                miExpiredAccountIDs.insert(expiredID)
                miAccountOfflineSince.removeValue(forKey: expiredID)
                miAccountPreDropDevices.removeValue(forKey: expiredID)
                let knownIDs = knownXiaomiAccountIDs(in: miSnapshot)
                if !miAccountStatuses.isEmpty || !(miSnapshot?.accountStatuses.isEmpty ?? true) {
                    let hasDeviceForExpiredAccount = miSnapshot?.devices.contains {
                        Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs) == expiredID
                            || miSnapshot?.deviceAccountIDs[$0.id]?.contains(expiredID) == true
                    } == true
                    if miAccountStatuses[expiredID] != nil
                        || miSnapshot?.accountStatuses[expiredID] != nil
                        || hasDeviceForExpiredAccount {
                        miAccountStatuses[expiredID] = expiredStatus
                        miSnapshot?.accountStatuses[expiredID] = expiredStatus
                        miSnapshot?.expiredAccountIDs.insert(expiredID)
                    }
                    if !miAccountStatuses.isEmpty {
                        let aggregate = Self.aggregateAccountStatus(miAccountStatuses)
                        if aggregate.isConnected {
                            miOfflineSince = nil
                        } else {
                            // Auth expiry never starts a fresh grace window; carry forward only an
                            // already-running grace timestamp from a non-expired sibling account.
                            miOfflineSince = miAccountOfflineSince
                                .filter { !miExpiredAccountIDs.contains($0.key) }
                                .values
                                .max()
                        }
                        miStatus = aggregate
                    }
                } else {
                    miSnapshot?.expiredAccountIDs.insert(expiredID)
                    var ownerIDs = Set(
                        (miSnapshot?.devices ?? []).compactMap {
                            Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs)
                        }
                    )
                    if let coOwnersByDevice = miSnapshot?.deviceAccountIDs {
                        for owners in coOwnersByDevice.values {
                            ownerIDs.formUnion(owners.filter { !$0.isEmpty })
                        }
                    }
                    if ownerIDs.subtracting(miExpiredAccountIDs).isEmpty {
                        miOfflineSince = nil
                        miStatus = expiredStatus
                        miLocalNetworkBlocks = []
                    }
                }
                if !miAccountStatuses.isEmpty,
                   miAccountStatuses.keys.allSatisfy({ miExpiredAccountIDs.contains($0) }) {
                    miLocalNetworkBlocks = []
                }
                emitStatus()
                if miStatus != previousMiStatus {
                    emitSourceStatuses()
                }
                emitLocalNetworkPermission()
                recompute()
            }
            continuation?.yield(.sessionExpired(session))

        case .doorbellRang(var ring):
            // Both sources report presses with their own device id; translate onto the merged
            // card so the paired card's popup and the activity feed can find it (#23).
            if let cardID = canonicalSourceIDs.canonicalID(forSourceID: ring.deviceId, backend: backend) {
                ring.deviceId = cardID
            }
            // The same physical press can arrive from both sources with different entity ids
            // and slightly different timestamps. Yield it once.
            if let firedAt = ring.firedAtDate,
               backend == .homeAssistant || backend == .xiaomiCloud {
                if matchAndConsumeCrossSourceDoorbellPress(of: ring.deviceId, from: backend, at: firedAt) {
                    return
                }
                recordDoorbellPress(of: ring.deviceId, from: backend, at: firedAt)
            }
            continuation?.yield(.doorbellRang(ring))

        case .sourceStatusesChanged:
            break

        case .miotTypePruneChanged(let report):
            continuation?.yield(.miotTypePruneChanged(canonicalizedPruneReport(report, from: backend)))

        case .haTypePruneChanged(let report):
            continuation?.yield(.haTypePruneChanged(canonicalizedPruneReport(report, from: backend)))

        case .localNetworkPermissionChanged(let blocked):
            if backend == .homeAssistant { haLocalNetworkBlocks = blocked }
            else if backend == .xiaomiCloud { miLocalNetworkBlocks = blocked }
            emitLocalNetworkPermission()
            recompute()

        case .snapshotUpdated(let home):
            var sourceStatusesChanged = false
            if backend == .homeAssistant {
                if haStatus != .connected { sourceStatusesChanged = true }
                haStatus = .connected
                haOfflineSince = nil
                haSnapshot = home
                haLocalNetworkBlocks = home.localNetworkBlockedFeatures
            } else if backend == .xiaomiCloud {
                sourceStatusesChanged = applyXiaomiSnapshot(home)
            }
            emitStatus()
            if sourceStatusesChanged {
                emitSourceStatuses()
            }
            emitLocalNetworkPermission()
            recompute()
        }
    }

    private func canonicalizedPruneReport(
        _ report: MiotTypePruneReport,
        from backend: HomeBackend
    ) -> MiotTypePruneReport {
        guard !report.isEmpty else { return report }
        let hiddenIndexedDevices = report.hiddenIndexedDevices.map { entry -> CapabilityIndexedDevice in
            guard let canonicalID = canonicalSourceIDs.canonicalID(forSourceID: entry.id, backend: backend),
                  canonicalID != entry.id else {
                return entry
            }
            return CapabilityIndexedDevice(
                id: canonicalID,
                name: entry.name,
                category: entry.category,
                connection: entry.connection,
                sourceScope: entry.sourceScope,
                isSourceAvailable: entry.isSourceAvailable,
                upstreamHiddenOrDisabled: entry.upstreamHiddenOrDisabled,
                participatesInAllOff: entry.participatesInAllOff,
                safetySignals: entry.safetySignals,
                readKeys: entry.readKeys,
                safetyReadKeys: entry.safetyReadKeys
            )
        }
        let hiddenDeviceIds = Set(report.hiddenDeviceIds.map { id in
            canonicalSourceIDs.canonicalID(forSourceID: id, backend: backend) ?? id
        })
        let safetyDevices = report.safetyDevices.map { device -> SmartDevice in
            guard let canonicalID = canonicalSourceIDs.canonicalID(forSourceID: device.id, backend: backend),
                  canonicalID != device.id else {
                return device
            }
            var rewritten = SmartDevice(
                id: canonicalID,
                name: device.name,
                roomId: device.roomId,
                roomName: device.roomName,
                model: device.model,
                isOnline: device.isOnline,
                kind: device.kind,
                isSharedHome: device.isSharedHome,
                accountId: device.accountId,
                accountLabel: device.accountLabel,
                telemetryStale: device.telemetryStale,
                auxiliarySafetyObservations: device.auxiliarySafetyObservations
            )
            rewritten.providerSafetySignals = device.providerSafetySignals
            return rewritten
        }
        return MiotTypePruneReport(
            scope: report.scope,
            hiddenIndexedDevices: hiddenIndexedDevices,
            hiddenDeviceIds: hiddenDeviceIds,
            safetyDevices: safetyDevices
        )
    }

    private func sourceStreamFinished(_ backend: HomeBackend) {
        guard !isShutDown, !disabledBackendsGate.contains(backend) else { return }
        let now = effectiveGraceNow()
        if backend == .homeAssistant {
            guard homeAssistant != nil else { return }
            recordStatusTransition(.disconnected(""), previous: haStatus, offlineSince: &haOfflineSince, now: now)
            haStatus = .disconnected("")
        } else if backend == .xiaomiCloud {
            guard xiaomiCloud != nil else { return }
            recordXiaomiStatusTransition(.disconnected(""), previous: miStatus, now: now)
            miStatus = .disconnected("")
        }
        emitStatus()
        emitSourceStatuses()
        recompute()
    }

    private func effectiveGraceNow() -> SuspendingClock.Instant {
        inactiveSince ?? graceNowProvider()
    }

    /// Marks when a source that still holds a snapshot dropped, so the fallback grace (#25) can
    /// keep its cards routed until the drop proves persistent.
    private func recordStatusTransition(
        _ next: ConnectionStatus,
        previous: ConnectionStatus,
        offlineSince: inout SuspendingClock.Instant?,
        now: SuspendingClock.Instant
    ) {
        if next.isConnected {
            offlineSince = nil
        } else if previous.isConnected {
            offlineSince = now
        }
    }

    private func recordXiaomiStatusTransition(
        _ next: ConnectionStatus,
        previous: ConnectionStatus,
        now: SuspendingClock.Instant
    ) {
        if next.isConnected {
            miOfflineSince = nil
            return
        }
        let allKnownExpired = !miExpiredAccountIDs.isEmpty
            && (miAccountStatuses.isEmpty || miAccountStatuses.keys.allSatisfy { miExpiredAccountIDs.contains($0) })
        if allKnownExpired {
            miOfflineSince = nil
        } else if previous.isConnected {
            miOfflineSince = now
        }
    }

    private func knownXiaomiAccountIDs(in snapshot: SynthesizedHome?) -> Set<String> {
        var ids = Set(miAccountStatuses.keys)
        ids.formUnion(miExpiredAccountIDs)
        if let snapshot {
            ids.formUnion(snapshot.accountStatuses.keys)
            ids.formUnion(snapshot.expiredAccountIDs.filter { !$0.isEmpty })
            for owners in snapshot.deviceAccountIDs.values {
                ids.formUnion(owners.filter { !$0.isEmpty })
            }
            for device in snapshot.devices {
                if let accountId = device.accountId, !accountId.isEmpty {
                    ids.insert(accountId)
                }
            }
            for option in snapshot.homes {
                if let accountId = option.accountId, !accountId.isEmpty {
                    ids.insert(accountId)
                }
            }
        }
        return ids
    }

    private static func resolvedXiaomiAccountID(
        for device: SmartDevice,
        knownAccountIDs: Set<String>
    ) -> String? {
        if let accountId = device.accountId, !accountId.isEmpty {
            return accountId
        }
        if let roomOwner = MiAccountScope.owner(of: device.roomId),
           knownAccountIDs.contains(roomOwner) {
            return roomOwner
        }
        return nil
    }

    private static func accountLabel(for accountID: String, in snapshot: SynthesizedHome) -> String? {
        snapshot.homes.first(where: { $0.accountId == accountID && $0.accountLabel != nil })?.accountLabel
            ?? snapshot.devices.first(where: { $0.accountId == accountID && $0.accountLabel != nil })?.accountLabel
    }

    private static func survivingXiaomiCoOwner(
        for deviceID: String,
        in snapshot: SynthesizedHome,
        miAccountStatuses: [String: ConnectionStatus],
        statusAccountIDs: Set<String>,
        expiredAccountIDs: Set<String>
    ) -> String? {
        guard let owners = snapshot.deviceAccountIDs[deviceID], !owners.isEmpty else {
            return nil
        }
        let candidates = owners.filter { candidate in
            guard !candidate.isEmpty, !expiredAccountIDs.contains(candidate) else { return false }
            return statusAccountIDs.isEmpty || statusAccountIDs.contains(candidate)
        }
        guard !candidates.isEmpty else { return nil }
        if let connected = candidates.first(where: { candidate in
            let status = snapshot.accountStatuses[candidate] ?? miAccountStatuses[candidate]
            return status?.isConnected ?? true
        }) {
            return connected
        }
        return candidates.first
    }

    private static func promoteSharedXiaomiDevice(
        _ device: inout SmartDevice,
        from expiredOwnerID: String?,
        to survivingID: String,
        in snapshot: SynthesizedHome,
        miAccountStatuses: [String: ConnectionStatus],
        ensuredRooms: inout [RoomArea]
    ) {
        device.accountId = survivingID
        device.accountLabel = accountLabel(for: survivingID, in: snapshot)
        if let expiredOwnerID, MiAccountScope.isOwned(device.roomId, by: expiredOwnerID) {
            let localSlug = MiAccountScope.localId(of: device.roomId)
            let scopedCandidateID = MiAccountScope.id(localSlug, account: survivingID)
            if let exactRoom = snapshot.rooms.first(where: { $0.id == scopedCandidateID }) {
                device.roomId = exactRoom.id
                device.roomName = exactRoom.name
            } else if let sameNamedRoom = snapshot.rooms.first(where: {
                MiAccountScope.isOwned($0.id, by: survivingID) && $0.name == device.roomName
            }) {
                device.roomId = sameNamedRoom.id
            } else {
                device.roomId = scopedCandidateID
                if !ensuredRooms.contains(where: { $0.id == scopedCandidateID }) {
                    ensuredRooms.append(RoomArea(id: scopedCandidateID, name: device.roomName))
                }
            }
        }
        if let status = snapshot.accountStatuses[survivingID] ?? miAccountStatuses[survivingID],
           !status.isConnected {
            device.isOnline = false
            device.telemetryStale = true
        }
    }

    /// Updates Xiaomi source and per-account grace tracking from `MiAccountsProvider` snapshots.
    /// `MiAccountsProvider` publishes a snapshot right after `.statusChanged(.disconnected)` with
    /// the dropped account's devices marked offline+stale; preserving pre-drop account state keeps
    /// the grace window effective in production while surfacing real `accountStatuses` to Settings.
    private func applyXiaomiSnapshot(_ home: SynthesizedHome) -> Bool {
        var home = home
        let now = effectiveGraceNow()
        let previousMiStatus = miStatus
        let disabledAccountIDs = pruneRevokedXiaomiAccountGraceState()
        let snapshotExpiredIDs = Set(home.expiredAccountIDs.filter { !$0.isEmpty && !disabledAccountIDs.contains($0) })
        for expiredID in snapshotExpiredIDs {
            miExpiredAccountIDs.insert(expiredID)
            miAccountOfflineSince.removeValue(forKey: expiredID)
            miAccountPreDropDevices.removeValue(forKey: expiredID)
        }
        let knownIDs = knownXiaomiAccountIDs(in: home).union(disabledAccountIDs)
        if home.accountStatuses.isEmpty {
            if !miExpiredAccountIDs.isEmpty {
                var deviceOwners = Set(
                    home.devices.compactMap { Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs) }
                )
                for owners in home.deviceAccountIDs.values {
                    deviceOwners.formUnion(owners.filter { !$0.isEmpty })
                }
                deviceOwners.subtract(disabledAccountIDs)
                let hasNonExpiredDeviceOwner = deviceOwners.contains { !miExpiredAccountIDs.contains($0) }
                let hasRecoveredAccount = snapshotExpiredIDs.isEmpty
                    && (home.closesAwayGap || hasNonExpiredDeviceOwner)
                if hasRecoveredAccount, !home.devices.isEmpty {
                    clearXiaomiAccountGraceState()
                    miStatus = .connected
                } else {
                    home.expiredAccountIDs.formUnion(miExpiredAccountIDs)
                    if !hasNonExpiredDeviceOwner {
                        home.localNetworkBlockedFeatures = []
                    }
                }
                miOfflineSince = nil
            } else {
                clearXiaomiAccountGraceState()
                if !home.devices.isEmpty || miStatus == .connecting {
                    miStatus = .connected
                }
                miOfflineSince = nil
            }
        } else {
            let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
            for expiredID in snapshotExpiredIDs where home.accountStatuses[expiredID] == nil {
                home.accountStatuses[expiredID] = expiredStatus
            }
            let activeAccountStatuses = home.accountStatuses.filter { !disabledAccountIDs.contains($0.key) }
            let presentIDs = Set(activeAccountStatuses.keys)
            for staleID in Set(miAccountStatuses.keys).union(miExpiredAccountIDs)
            where !presentIDs.contains(staleID) {
                miAccountStatuses.removeValue(forKey: staleID)
                miAccountOfflineSince.removeValue(forKey: staleID)
                miAccountPreDropDevices.removeValue(forKey: staleID)
                miExpiredAccountIDs.remove(staleID)
            }
            for (accountID, nextAccStatus) in activeAccountStatuses {
                let prevAccStatus = miAccountStatuses[accountID]
                if nextAccStatus.isConnected, !snapshotExpiredIDs.contains(accountID) {
                    miExpiredAccountIDs.remove(accountID)
                    miAccountStatuses[accountID] = nextAccStatus
                    miAccountOfflineSince.removeValue(forKey: accountID)
                    var owned: [String: PreDropXiaomiDevice] = [:]
                    for device in home.devices {
                        let identity = home.deviceIdentities[device.id]
                        if Self.resolvedXiaomiAccountID(for: device, knownAccountIDs: knownIDs) == accountID {
                            owned[device.id] = PreDropXiaomiDevice(
                                device: device,
                                identity: identity,
                                wasPrimaryOwner: true
                            )
                        } else if home.deviceAccountIDs[device.id]?.contains(accountID) == true {
                            var copy = device
                            copy.accountId = accountID
                            if let label = Self.accountLabel(for: accountID, in: home) {
                                copy.accountLabel = label
                            }
                            owned[device.id] = PreDropXiaomiDevice(
                                device: copy,
                                identity: identity,
                                wasPrimaryOwner: false
                            )
                        }
                    }
                    miAccountPreDropDevices[accountID] = owned
                } else if case .connecting = nextAccStatus,
                          !snapshotExpiredIDs.contains(accountID),
                          miExpiredAccountIDs.contains(accountID) {
                    miExpiredAccountIDs.remove(accountID)
                    miAccountStatuses[accountID] = nextAccStatus
                    miAccountOfflineSince.removeValue(forKey: accountID)
                    miAccountPreDropDevices.removeValue(forKey: accountID)
                } else if miExpiredAccountIDs.contains(accountID) {
                    let demotedStatus: ConnectionStatus
                    if case .disconnected = nextAccStatus {
                        demotedStatus = nextAccStatus
                    } else {
                        demotedStatus = miAccountStatuses[accountID] ?? expiredStatus
                        home.accountStatuses[accountID] = demotedStatus
                    }
                    miAccountStatuses[accountID] = demotedStatus
                    miAccountOfflineSince.removeValue(forKey: accountID)
                    miAccountPreDropDevices.removeValue(forKey: accountID)
                } else {
                    miAccountStatuses[accountID] = nextAccStatus
                    if prevAccStatus?.isConnected == true,
                       !(miAccountPreDropDevices[accountID]?.isEmpty ?? true) {
                        miAccountOfflineSince[accountID] = miOfflineSince ?? now
                    }
                }
            }

            if !miAccountStatuses.isEmpty,
               miAccountStatuses.keys.allSatisfy({ miExpiredAccountIDs.contains($0) }) {
                home.localNetworkBlockedFeatures = []
            }
            let aggregate = Self.aggregateAccountStatus(activeAccountStatuses)
            recordXiaomiStatusTransition(aggregate, previous: miStatus, now: now)
            miStatus = aggregate
        }
        miSnapshot = home
        miLocalNetworkBlocks = home.localNetworkBlockedFeatures
        return miStatus != previousMiStatus
    }

    private static func aggregateAccountStatus(_ statuses: [String: ConnectionStatus]) -> ConnectionStatus {
        if statuses.values.contains(where: \.isConnected) {
            return .connected
        }
        if statuses.values.contains(where: {
            if case .connecting = $0 { return true }
            return false
        }) {
            return .connecting
        }
        for key in statuses.keys.sorted() {
            if case .disconnected = statuses[key] {
                return statuses[key] ?? .connecting
            }
        }
        return .connecting
    }

    /// Drops expired or disabled/signed-out Xiaomi account candidates immediately so paired cards
    /// fail over to a surviving source instead of letting offline/pinned tie-breakers or cached
    /// pre-drop copies keep a dead or revoked session winning, while promoting surviving Xiaomi
    /// co-owners for shared devices and restoring pre-drop freshness for non-expired enabled
    /// accounts still in their grace window (#25).
    private func effectiveXiaomiSnapshot(
        now: SuspendingClock.Instant
    ) -> (snapshot: SynthesizedHome?, gracedAccountIDs: Set<String>) {
        let disabledAccountIDs = pruneRevokedXiaomiAccountGraceState()
        guard !disabledBackendsGate.contains(.xiaomiCloud),
              var snapshot = miSnapshot else {
            return (nil, [])
        }
        let knownIDs = knownXiaomiAccountIDs(in: snapshot).union(disabledAccountIDs)
        if !disabledAccountIDs.isEmpty {
            snapshot.accountStatuses = snapshot.accountStatuses.filter { !disabledAccountIDs.contains($0.key) }
            snapshot.expiredAccountIDs.subtract(disabledAccountIDs)
            snapshot.freshAccountIds.subtract(disabledAccountIDs)
            snapshot.devices.removeAll { device in
                if let ownerID = Self.resolvedXiaomiAccountID(for: device, knownAccountIDs: knownIDs) {
                    return disabledAccountIDs.contains(ownerID)
                }
                if let owners = snapshot.deviceAccountIDs[device.id], !owners.isEmpty {
                    return owners.allSatisfy { disabledAccountIDs.contains($0) }
                }
                return false
            }
            let remainingDeviceIDs = Set(snapshot.devices.map(\.id))
            var cleanedDeviceAccountIDs: [String: [String]] = [:]
            for (deviceID, owners) in snapshot.deviceAccountIDs where remainingDeviceIDs.contains(deviceID) {
                let kept = owners.filter { !disabledAccountIDs.contains($0) }
                if !kept.isEmpty {
                    cleanedDeviceAccountIDs[deviceID] = kept
                }
            }
            snapshot.deviceAccountIDs = cleanedDeviceAccountIDs
            snapshot.deviceIdentities = snapshot.deviceIdentities.filter { remainingDeviceIDs.contains($0.key) }
            snapshot.deviceFacets = snapshot.deviceFacets.filter { remainingDeviceIDs.contains($0.key) }
            snapshot.deviceTransportDiagnostics = snapshot.deviceTransportDiagnostics.filter {
                remainingDeviceIDs.contains($0.key)
            }
            snapshot.lightGroupOwners = snapshot.lightGroupOwners.filter {
                remainingDeviceIDs.contains($0.key) && remainingDeviceIDs.contains($0.value)
            }
            snapshot.environmentReadings = snapshot.environmentReadings.filter {
                remainingDeviceIDs.contains($0.id)
            }
            snapshot.rooms.removeAll { room in
                guard let roomOwner = MiAccountScope.owner(of: room.id) else { return false }
                return disabledAccountIDs.contains(roomOwner)
            }
            snapshot.homes.removeAll { option in
                let ownerID = (option.accountId?.isEmpty == false ? option.accountId : nil)
                    ?? MiAccountScope.owner(of: option.id)
                guard let ownerID else { return false }
                return disabledAccountIDs.contains(ownerID)
            }
            if snapshot.devices.isEmpty, snapshot.accountStatuses.isEmpty {
                snapshot.localNetworkBlockedFeatures = []
            }
        }
        let activeExpiredIDs = miExpiredAccountIDs
            .union(snapshot.expiredAccountIDs.filter { !$0.isEmpty })
            .subtracting(disabledAccountIDs)
        if !activeExpiredIDs.isEmpty {
            let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
            for expiredID in activeExpiredIDs where snapshot.accountStatuses[expiredID] != nil {
                if case .disconnected = snapshot.accountStatuses[expiredID] {} else {
                    snapshot.accountStatuses[expiredID] = miAccountStatuses[expiredID] ?? expiredStatus
                }
            }
            let statusAccountIDs = Set(snapshot.accountStatuses.keys)
                .union(miAccountStatuses.keys)
                .subtracting(disabledAccountIDs)
            let hasNonExpiredAccount: Bool
            if !statusAccountIDs.isEmpty {
                hasNonExpiredAccount = statusAccountIDs.contains { !activeExpiredIDs.contains($0) }
            } else {
                var deviceOwners = Set(
                    snapshot.devices.compactMap { Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs) }
                )
                for owners in snapshot.deviceAccountIDs.values {
                    deviceOwners.formUnion(owners.filter { !$0.isEmpty })
                }
                deviceOwners.subtract(disabledAccountIDs)
                hasNonExpiredAccount = deviceOwners.contains { !activeExpiredIDs.contains($0) }
            }

            var promotedDevices: [SmartDevice] = []
            promotedDevices.reserveCapacity(snapshot.devices.count)
            var ensuredRooms: [RoomArea] = []
            for var device in snapshot.devices {
                guard let ownerID = Self.resolvedXiaomiAccountID(for: device, knownAccountIDs: knownIDs) else {
                    if let survivingID = Self.survivingXiaomiCoOwner(
                        for: device.id,
                        in: snapshot,
                        miAccountStatuses: miAccountStatuses,
                        statusAccountIDs: statusAccountIDs,
                        expiredAccountIDs: activeExpiredIDs
                    ) {
                        Self.promoteSharedXiaomiDevice(
                            &device,
                            from: nil,
                            to: survivingID,
                            in: snapshot,
                            miAccountStatuses: miAccountStatuses,
                            ensuredRooms: &ensuredRooms
                        )
                        promotedDevices.append(device)
                    }
                    // Unattributed Xiaomi devices (`accountId == nil`, unscoped `roomId`, and no
                    // surviving co-owner) cannot be verified once a Xiaomi session has expired.
                    continue
                }
                if activeExpiredIDs.contains(ownerID) {
                    guard let survivingID = Self.survivingXiaomiCoOwner(
                        for: device.id,
                        in: snapshot,
                        miAccountStatuses: miAccountStatuses,
                        statusAccountIDs: statusAccountIDs,
                        expiredAccountIDs: activeExpiredIDs
                    ) else {
                        continue
                    }
                    Self.promoteSharedXiaomiDevice(
                        &device,
                        from: ownerID,
                        to: survivingID,
                        in: snapshot,
                        miAccountStatuses: miAccountStatuses,
                        ensuredRooms: &ensuredRooms
                    )
                }
                promotedDevices.append(device)
            }
            snapshot.devices = promotedDevices
            let remainingDeviceIDs = Set(snapshot.devices.map(\.id))
            snapshot.deviceIdentities = snapshot.deviceIdentities.filter { remainingDeviceIDs.contains($0.key) }
            snapshot.deviceFacets = snapshot.deviceFacets.filter { remainingDeviceIDs.contains($0.key) }
            snapshot.deviceTransportDiagnostics = snapshot.deviceTransportDiagnostics.filter {
                remainingDeviceIDs.contains($0.key)
            }
            snapshot.lightGroupOwners = snapshot.lightGroupOwners.filter {
                remainingDeviceIDs.contains($0.key) && remainingDeviceIDs.contains($0.value)
            }
            snapshot.environmentReadings = snapshot.environmentReadings.filter {
                remainingDeviceIDs.contains($0.id)
            }
            snapshot.rooms.removeAll { room in
                if let roomOwner = MiAccountScope.owner(of: room.id),
                   knownIDs.contains(roomOwner) {
                    return activeExpiredIDs.contains(roomOwner)
                }
                return !hasNonExpiredAccount
            }
            for room in ensuredRooms
            where !snapshot.rooms.contains(where: { $0.id == room.id }) {
                snapshot.rooms.append(room)
            }
            snapshot.homes.removeAll { option in
                let ownerID = (option.accountId?.isEmpty == false ? option.accountId : nil)
                    ?? MiAccountScope.owner(of: option.id).flatMap { knownIDs.contains($0) ? $0 : nil }
                if let ownerID {
                    return activeExpiredIDs.contains(ownerID)
                }
                return !hasNonExpiredAccount
            }
            if !hasNonExpiredAccount {
                snapshot.localNetworkBlockedFeatures = []
            }
        }
        guard !snapshot.accountStatuses.isEmpty else { return (snapshot, []) }
        var gracedAccountIDs: Set<String> = []
        for (accountID, accStatus) in snapshot.accountStatuses where !accStatus.isConnected {
            guard !activeExpiredIDs.contains(accountID),
                  !disabledAccountIDs.contains(accountID),
                  let since = miAccountOfflineSince[accountID],
                  let preDrop = miAccountPreDropDevices[accountID],
                  !preDrop.isEmpty,
                  since.duration(to: now) < Self.sourceFallbackGraceDuration else {
                continue
            }
            snapshot.accountStatuses[accountID] = .connected
            gracedAccountIDs.insert(accountID)
        }
        guard !gracedAccountIDs.isEmpty else { return (snapshot, []) }
        for index in snapshot.devices.indices {
            let current = snapshot.devices[index]
            let currentOwnerID = Self.resolvedXiaomiAccountID(for: current, knownAccountIDs: knownIDs)
            var bestDevice = current
            var bestIdentity: DeviceSourceIdentity?
            var selectedCachedCopy = false
            var bestRank: Int
            if let currentOwnerID,
               gracedAccountIDs.contains(currentOwnerID),
               let restored = miAccountPreDropDevices[currentOwnerID]?[current.id] {
                bestDevice = restored.device
                bestIdentity = restored.identity
                selectedCachedCopy = true
                bestRank = Self.xiaomiDeviceFreshnessRank(restored.device, accountDisconnected: false)
            } else {
                let currentDisconnected = currentOwnerID.map { ownerID in
                    !(snapshot.accountStatuses[ownerID]?.isConnected ?? true)
                } ?? false
                bestRank = Self.xiaomiDeviceFreshnessRank(current, accountDisconnected: currentDisconnected)
            }
            // Shared devices can have a connected co-owner (e.g. reporting the camera offline)
            // overwrite the streaming owner in `MiAccountsProvider` as soon as the primary owner
            // drops. Include still-graced pre-drop primary owners by DID so grace holds routing.
            var candidateOwnerIDs = snapshot.deviceAccountIDs[current.id] ?? []
            for gracedID in gracedAccountIDs.sorted() where !candidateOwnerIDs.contains(gracedID) {
                candidateOwnerIDs.append(gracedID)
            }
            for candidateOwnerID in candidateOwnerIDs
            where candidateOwnerID != currentOwnerID && gracedAccountIDs.contains(candidateOwnerID) {
                guard let preDrop = miAccountPreDropDevices[candidateOwnerID]?[current.id],
                      preDrop.wasPrimaryOwner else {
                    continue
                }
                let candidateRank = Self.xiaomiDeviceFreshnessRank(preDrop.device, accountDisconnected: false)
                if candidateRank < bestRank {
                    bestDevice = preDrop.device
                    bestIdentity = preDrop.identity
                    selectedCachedCopy = true
                    bestRank = candidateRank
                }
            }
            snapshot.devices[index] = bestDevice
            if selectedCachedCopy {
                if let bestIdentity {
                    snapshot.deviceIdentities[bestDevice.id] = bestIdentity
                } else {
                    snapshot.deviceIdentities.removeValue(forKey: bestDevice.id)
                }
            }
        }
        return (snapshot, gracedAccountIDs)
    }

    private static func xiaomiDeviceFreshnessRank(
        _ device: SmartDevice,
        accountDisconnected: Bool
    ) -> Int {
        if accountDisconnected { return 3 }
        if device.telemetryStale { return 2 }
        return device.isOnline ? 0 : 1
    }

    /// Test seam (#25): expires any active drop grace windows immediately and re-merges, so
    /// store-level tests reach the post-grace fallback deterministically without sleeping.
    public func expireFallbackGraceForTesting() {
        haOfflineSince = nil
        miOfflineSince = nil
        miAccountOfflineSince.removeAll()
        cancelFallbackRecheck()
        recompute()
    }

    /// A dropped source stays trusted while its last snapshot is within the grace window (#25).
    /// The status bar keeps showing the real state; only routing holds.
    private static func effectiveConnected(
        actual: Bool,
        snapshot: SynthesizedHome?,
        offlineSince: SuspendingClock.Instant?,
        now: SuspendingClock.Instant
    ) -> Bool {
        if actual { return true }
        guard let snapshot, !snapshot.devices.isEmpty, let offlineSince else { return false }
        return offlineSince.duration(to: now) < sourceFallbackGraceDuration
    }

    private func cancelFallbackRecheck() {
        fallbackRecheckGeneration &+= 1
        fallbackRecheckTimer.cancelPending()
    }

    /// Schedules the recompute that adopts the fallback once a deferred grace expires, so a silent
    /// line (no further events) still hands the cards to the surviving source (#25).
    private func scheduleFallbackRecheckIfNeeded(now: SuspendingClock.Instant) {
        fallbackRecheckGeneration &+= 1
        guard !isShutDown,
              pollingContext.systemActive,
              let deadline = earliestPendingFallbackDeadline(after: now) else {
            fallbackRecheckTimer.cancelPending()
            return
        }
        let token = fallbackRecheckGeneration
        let delay = max(.milliseconds(100), now.duration(to: deadline))
        fallbackRecheckTimer.schedule(after: delay) { [weak self] in
            guard let self else { return }
            Task {
                await self.completeScheduledFallbackRecheck(token: token)
            }
        }
    }

    private func completeScheduledFallbackRecheck(token: UInt64) {
        guard !isShutDown,
              pollingContext.systemActive,
              token == fallbackRecheckGeneration else {
            discardedFallbackWakeCountForTesting += 1
            return
        }
        recompute()
    }

    private func earliestPendingFallbackDeadline(after now: SuspendingClock.Instant) -> SuspendingClock.Instant? {
        let disabledBackends = disabledBackendsGate.snapshot()
        let disabledAccountIDs = pruneRevokedXiaomiAccountGraceState()
        var deadline: SuspendingClock.Instant?
        func consider(_ since: SuspendingClock.Instant) {
            let expiry = since.advanced(by: Self.sourceFallbackGraceDuration)
            if expiry > now {
                deadline = deadline.map { min($0, expiry) } ?? expiry
            }
        }
        if homeAssistant != nil, !disabledBackends.contains(.homeAssistant), !haStatus.isConnected, let since = haOfflineSince {
            consider(since)
        }
        if xiaomiCloud != nil, !disabledBackends.contains(.xiaomiCloud), !miStatus.isConnected, let since = miOfflineSince {
            consider(since)
        }
        if xiaomiCloud != nil, !disabledBackends.contains(.xiaomiCloud) {
            for (accountID, since) in miAccountOfflineSince
            where !(miAccountStatuses[accountID]?.isConnected ?? true)
                && !miExpiredAccountIDs.contains(accountID)
                && !disabledAccountIDs.contains(accountID) {
                consider(since)
            }
        }
        return deadline
    }

    private func shiftActiveGraceTimestampsOnWake(
        pausedAt: SuspendingClock.Instant,
        asleepDuration: Duration
    ) {
        guard asleepDuration > .zero else { return }
        if let since = haOfflineSince,
           since.duration(to: pausedAt) < Self.sourceFallbackGraceDuration {
            haOfflineSince = since.advanced(by: asleepDuration)
        }
        if let since = miOfflineSince,
           since.duration(to: pausedAt) < Self.sourceFallbackGraceDuration {
            miOfflineSince = since.advanced(by: asleepDuration)
        }
        for (accountID, since) in miAccountOfflineSince
        where since.duration(to: pausedAt) < Self.sourceFallbackGraceDuration {
            miAccountOfflineSince[accountID] = since.advanced(by: asleepDuration)
        }
    }

    /// True when the last merged snapshot held a dropped source or Xiaomi account on grace whose
    /// window had already elapsed before `inactiveSince` froze it (so `shiftActiveGraceTimestampsOnWake`
    /// left its timestamp unshifted and `scheduleFallbackRecheckIfNeeded` would see no future deadline).
    private func hasExpiredGraceSinceLastRecompute(at now: SuspendingClock.Instant) -> Bool {
        guard haGraceActiveInLastRecompute
            || miGraceActiveInLastRecompute
            || !miGracedAccountsInLastRecompute.isEmpty else {
            return false
        }
        let disabledBackends = disabledBackendsGate.snapshot()
        if haGraceActiveInLastRecompute {
            let haStillGraced = homeAssistant != nil
                && !disabledBackends.contains(.homeAssistant)
                && !haStatus.isConnected
                && Self.effectiveConnected(
                    actual: false,
                    snapshot: haSnapshot,
                    offlineSince: haOfflineSince,
                    now: now
                )
            if !haStillGraced { return true }
        }
        let (effectiveMi, gracedMiAccounts) = effectiveXiaomiSnapshot(now: now)
        if miGraceActiveInLastRecompute {
            let miStillGraced = xiaomiCloud != nil
                && !disabledBackends.contains(.xiaomiCloud)
                && !miStatus.isConnected
                && Self.effectiveConnected(
                    actual: false,
                    snapshot: effectiveMi,
                    offlineSince: miOfflineSince,
                    now: now
                )
            if !miStillGraced { return true }
        }
        if !miGracedAccountsInLastRecompute.isSubset(of: gracedMiAccounts) {
            return true
        }
        return false
    }

    /// True when the other backend already reported a press for this card within the dedupe
    /// window (#23). Matching consumes the closest unmatched press so a genuine later press
    /// within the window is never swallowed, and suppressed duplicates are never recorded.
    private func matchAndConsumeCrossSourceDoorbellPress(
        of cardID: String,
        from backend: HomeBackend,
        at firedAt: Date
    ) -> Bool {
        let referenceDate = latestDoorbellPressDate(of: cardID, including: firedAt)
        pruneDoorbellHistory(of: cardID, referenceDate: referenceDate)

        let otherBackend: HomeBackend = backend == .homeAssistant ? .xiaomiCloud : .homeAssistant
        guard var byBackend = doorbellPressesByCard[cardID],
              var otherPresses = byBackend[otherBackend],
              !otherPresses.isEmpty else {
            return false
        }

        var bestIndex: Int?
        var bestDistance = TimeInterval.infinity
        for (index, candidate) in otherPresses.enumerated() {
            let distance = abs(firedAt.timeIntervalSince(candidate))
            if distance <= Self.crossSourceDoorbellDedupWindow, distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let matchedIndex = bestIndex else { return false }

        otherPresses.remove(at: matchedIndex)
        if otherPresses.isEmpty {
            byBackend.removeValue(forKey: otherBackend)
        } else {
            byBackend[otherBackend] = otherPresses
        }
        if byBackend.isEmpty {
            doorbellPressesByCard.removeValue(forKey: cardID)
        } else {
            doorbellPressesByCard[cardID] = byBackend
        }
        return true
    }

    private func recordDoorbellPress(of cardID: String, from backend: HomeBackend, at firedAt: Date) {
        let referenceDate = latestDoorbellPressDate(of: cardID, including: firedAt)
        var byBackend = doorbellPressesByCard[cardID] ?? [:]
        var presses = byBackend[backend] ?? []
        presses.append(firedAt)
        presses.sort()
        byBackend[backend] = presses
        doorbellPressesByCard[cardID] = byBackend
        pruneDoorbellHistory(of: cardID, referenceDate: referenceDate)
        pruneExcessDoorbellCards()
    }

    private func latestDoorbellPressDate(of cardID: String, including candidate: Date) -> Date {
        guard let byBackend = doorbellPressesByCard[cardID] else { return candidate }
        var latest = candidate
        for timestamps in byBackend.values {
            if let backendMax = timestamps.max(), backendMax > latest {
                latest = backendMax
            }
        }
        return latest
    }

    private func pruneDoorbellHistory(of cardID: String, referenceDate: Date) {
        guard var byBackend = doorbellPressesByCard[cardID] else { return }
        for backend in Array(byBackend.keys) {
            var timestamps = byBackend[backend] ?? []
            timestamps.removeAll {
                referenceDate.timeIntervalSince($0) > Self.crossSourceDoorbellHistoryRetention
            }
            if timestamps.count > Self.crossSourceDoorbellHistoryLimit {
                timestamps.sort()
                timestamps.removeFirst(timestamps.count - Self.crossSourceDoorbellHistoryLimit)
            }
            if timestamps.isEmpty {
                byBackend.removeValue(forKey: backend)
            } else {
                byBackend[backend] = timestamps
            }
        }
        if byBackend.isEmpty {
            doorbellPressesByCard.removeValue(forKey: cardID)
        } else {
            doorbellPressesByCard[cardID] = byBackend
        }
    }

    private func pruneExcessDoorbellCards() {
        while doorbellPressesByCard.count > Self.crossSourceDoorbellCardLimit {
            guard let oldestCard = doorbellPressesByCard.min(by: { lhs, rhs in
                let lhsMax = lhs.value.values.compactMap { $0.max() }.max() ?? .distantPast
                let rhsMax = rhs.value.values.compactMap { $0.max() }.max() ?? .distantPast
                return lhsMax < rhsMax
            })?.key else {
                break
            }
            doorbellPressesByCard.removeValue(forKey: oldestCard)
        }
    }

    private func emitStatus(force: Bool = false) {
        guard let status = aggregateStatus() else { return }
        guard force || status != lastStatus else { return }
        lastStatus = status
        continuation?.yield(.statusChanged(status))
    }

    private func emitSourceStatuses() {
        let statuses = configuredSourceStatuses()
        guard !statuses.isEmpty else { return }
        continuation?.yield(.sourceStatusesChanged(statuses))
    }

    private func aggregateStatus() -> ConnectionStatus? {
        let disabledBackends = disabledBackendsGate.snapshot()
        var statuses: [ConnectionStatus] = []
        if homeAssistant != nil, !disabledBackends.contains(.homeAssistant) { statuses.append(haStatus) }
        if xiaomiCloud != nil, !disabledBackends.contains(.xiaomiCloud) { statuses.append(miStatus) }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(where: { $0.isConnected }) { return .connected }
        if statuses.contains(where: { status in
            if case .connecting = status { return true }
            return false
        }) {
            return .connecting
        }
        for status in statuses {
            if case .disconnected(let reason) = status, !reason.isEmpty {
                return .disconnected(reason)
            }
        }
        return statuses.first
    }

    private func recompute(allowEmpty: Bool = false, now overrideNow: SuspendingClock.Instant? = nil) {
        guard !isShutDown else { return }
        guard allowEmpty || haSnapshot != nil || miSnapshot != nil else {
            haGraceActiveInLastRecompute = false
            miGraceActiveInLastRecompute = false
            miGracedAccountsInLastRecompute.removeAll()
            cancelFallbackRecheck()
            return
        }
        let now = overrideNow ?? effectiveGraceNow()
        let disabledBackends = disabledBackendsGate.snapshot()
        let disabledAccountIDs = pruneRevokedXiaomiAccountGraceState()
        let haActive = homeAssistant != nil && !disabledBackends.contains(.homeAssistant)
        let miActive = xiaomiCloud != nil && !disabledBackends.contains(.xiaomiCloud)
        // Hysteresis (#25): a source that just dropped keeps routing its cards for the grace
        // window, so a brief blip neither flips paired cards nor kills a live camera view. The
        // deadline task re-merges when the window lapses, even if no further event arrives.
        let effectiveHA = haActive ? haSnapshot : nil
        let haGraceConnected = haActive && Self.effectiveConnected(
            actual: haStatus.isConnected,
            snapshot: effectiveHA,
            offlineSince: haOfflineSince,
            now: now
        )
        let (effectiveMi, gracedMiAccounts) = miActive ? effectiveXiaomiSnapshot(now: now) : (nil, [])
        let miGraceConnected = miActive && Self.effectiveConnected(
            actual: miStatus.isConnected,
            snapshot: effectiveMi,
            offlineSince: miOfflineSince,
            now: now
        )
        haGraceActiveInLastRecompute = haActive && !haStatus.isConnected && haGraceConnected
        miGraceActiveInLastRecompute = miActive && !miStatus.isConnected && miGraceConnected
        miGracedAccountsInLastRecompute = miActive ? gracedMiAccounts : []
        let result = DeviceDeduplicator.merge(
            homeAssistant: effectiveHA,
            xiaomiCloud: effectiveMi,
            haConnected: haGraceConnected,
            miConnected: miGraceConnected,
            canonical: canonical,
            rooms: rooms,
            knownPreferenceIDs: knownPreferenceIDs(),
            pinnedBackends: pinnedBackends()
        )
        scheduleFallbackRecheckIfNeeded(now: now)
        if result.canonical != canonical {
            canonical = result.canonical
            persistCanonicalIDs(result.canonical.assignments)
        }
        rooms = result.rooms
        routes = result.routes
        canonicalSourceIDs.merge(haCanonicalIDs: result.haCanonicalIDs, miCanonicalIDs: result.miCanonicalIDs)
        for (deviceID, activeRoute) in activeCameraRoutes {
            let nextRoute = result.routes[deviceID]
            if nextRoute?.backend != activeRoute.backend || nextRoute?.sourceDeviceID != activeRoute.sourceDeviceID {
                activeCameraRoutes.removeValue(forKey: deviceID)
                let ha = homeAssistant
                let mi = xiaomiCloud
                Task {
                    switch activeRoute.backend {
                    case .homeAssistant:
                        await ha?.stopCameraStream(for: activeRoute.sourceDevice)
                    case .xiaomiCloud:
                        await mi?.stopCameraStream(for: activeRoute.sourceDevice)
                    case .demo:
                        break
                    }
                }
            } else if let nextRoute {
                activeCameraRoutes[deviceID] = nextRoute
            }
        }
        var home = result.home
        if miActive {
            home.accountStatuses = (miSnapshot?.accountStatuses ?? [:]).filter {
                !disabledAccountIDs.contains($0.key)
            }
            home.expiredAccountIDs = miExpiredAccountIDs
                .union((miSnapshot?.expiredAccountIDs ?? []).filter { !$0.isEmpty })
                .subtracting(disabledAccountIDs)
        } else {
            home.accountStatuses = [:]
            home.expiredAccountIDs = []
        }
        home.sourceStatuses = configuredSourceStatuses()
        home.localNetworkBlockedFeatures = currentLocalNetworkBlocks()
        continuation?.yield(.snapshotUpdated(home))
    }

    private func currentLocalNetworkBlocks() -> Set<LocalNetworkBlockedFeature> {
        let disabledBackends = disabledBackendsGate.snapshot()
        let haBlocks = (homeAssistant != nil && !disabledBackends.contains(.homeAssistant)) ? haLocalNetworkBlocks : []
        let miBlocks = (xiaomiCloud != nil && !disabledBackends.contains(.xiaomiCloud)) ? miLocalNetworkBlocks : []
        return haBlocks.union(miBlocks)
    }

    private func emitLocalNetworkPermission() {
        let next = currentLocalNetworkBlocks()
        guard next != lastEmittedLocalNetworkBlocks else { return }
        lastEmittedLocalNetworkBlocks = next
        continuation?.yield(.localNetworkPermissionChanged(next))
    }

    private func configuredSourceStatuses() -> [HomeBackend: ConnectionStatus] {
        let disabledBackends = disabledBackendsGate.snapshot()
        var statuses: [HomeBackend: ConnectionStatus] = [:]
        if homeAssistant != nil, !disabledBackends.contains(.homeAssistant) { statuses[.homeAssistant] = haStatus }
        if xiaomiCloud != nil, !disabledBackends.contains(.xiaomiCloud) { statuses[.xiaomiCloud] = miStatus }
        return statuses
    }

    // MARK: - Commands

    public func execute(_ command: DeviceCommand) async throws {
        if MiotAddress.parse(command.targetEntityId) != nil
            || MiCloudScene.accountID(for: command.targetEntityId) != nil {
            guard !disabledBackendsGate.contains(.xiaomiCloud), let xiaomiCloud else {
                throw HomeProviderError.backendNotConfigured(.xiaomiCloud)
            }
            try await xiaomiCloud.execute(command)
        } else {
            guard !disabledBackendsGate.contains(.homeAssistant), let homeAssistant else {
                throw HomeProviderError.backendNotConfigured(.homeAssistant)
            }
            try await homeAssistant.execute(command)
        }
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let route = routes[deviceId], !disabledBackendsGate.contains(route.backend) else { return .failed }
        switch route.backend {
        case .homeAssistant:
            guard let homeAssistant else { return .failed }
            return await homeAssistant.readBack(deviceId: route.sourceDeviceID)
        case .xiaomiCloud:
            guard let xiaomiCloud else { return .failed }
            return await xiaomiCloud.readBack(deviceId: route.sourceDeviceID)
        case .demo:
            return .unavailable
        }
    }

    // MARK: - Polling

    public func refreshNow() async {
        guard !isShutDown else { return }
        let disabled = disabledBackendsGate.snapshot()
        let ha = disabled.contains(.homeAssistant) ? nil : homeAssistant
        let mi = disabled.contains(.xiaomiCloud) ? nil : xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.refreshNow() } }
            if let mi { group.addTask { await mi.refreshNow() } }
        }
    }

    public func retryLAN(deviceId: String?) async {
        guard !isShutDown else { return }
        guard let deviceId else {
            let ha = homeAssistant
            let mi = xiaomiCloud
            await withTaskGroup(of: Void.self) { group in
                if let ha { group.addTask { await ha.retryLAN(deviceId: nil) } }
                if let mi { group.addTask { await mi.retryLAN(deviceId: nil) } }
            }
            return
        }
        if let route = routes[deviceId] {
            switch route.backend {
            case .xiaomiCloud:
                await xiaomiCloud?.retryLAN(deviceId: route.sourceDeviceID)
            case .homeAssistant:
                let miSourceIDs = Array(canonicalSourceIDs.sourceIDs(forCanonicalIDs: [deviceId], backend: .xiaomiCloud))
                let ha = homeAssistant
                let mi = xiaomiCloud
                await withTaskGroup(of: Void.self) { group in
                    if let ha { group.addTask { await ha.retryLAN(deviceId: route.sourceDeviceID) } }
                    if let mi {
                        for miID in miSourceIDs {
                            group.addTask { await mi.retryLAN(deviceId: miID) }
                        }
                    }
                }
            case .demo:
                break
            }
            return
        }
        let miSourceIDs = Array(canonicalSourceIDs.sourceIDs(forCanonicalIDs: [deviceId], backend: .xiaomiCloud))
        let ha = homeAssistant
        let mi = xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.retryLAN(deviceId: deviceId) } }
            if let mi {
                if miSourceIDs.isEmpty {
                    group.addTask { await mi.retryLAN(deviceId: deviceId) }
                } else {
                    for miID in miSourceIDs {
                        group.addTask { await mi.retryLAN(deviceId: miID) }
                    }
                }
            }
        }
    }

    public func setPollingContext(_ context: PollingContext) async {
        guard !isShutDown else { return }
        if !context.systemActive && pollingContext.systemActive {
            inactiveSince = graceNowProvider()
            pollingContext = context
            cancelFallbackRecheck()
        } else if context.systemActive && !pollingContext.systemActive {
            let wake = graceNowProvider()
            if let pausedAt = inactiveSince {
                let asleepDuration = max(.zero, pausedAt.duration(to: wake))
                shiftActiveGraceTimestampsOnWake(pausedAt: pausedAt, asleepDuration: asleepDuration)
            }
            inactiveSince = nil
            pollingContext = context
            if hasExpiredGraceSinceLastRecompute(at: wake) {
                recompute(now: wake)
            } else {
                scheduleFallbackRecheckIfNeeded(now: wake)
            }
        } else {
            pollingContext = context
        }
        let disabled = disabledBackendsGate.snapshot()
        let ha = disabled.contains(.homeAssistant) ? nil : homeAssistant
        let mi = disabled.contains(.xiaomiCloud) ? nil : xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.setPollingContext(context) } }
            if let mi { group.addTask { await mi.setPollingContext(context) } }
        }
    }

    // MARK: - History & Camera Routing

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let route = routes[deviceId], !disabledBackendsGate.contains(route.backend) else { return [] }
        switch route.backend {
        case .homeAssistant:
            guard let homeAssistant else { return [] }
            return await homeAssistant.fetchSensorHistory(
                deviceId: route.sourceDeviceID,
                window: window,
                now: now
            )
        case .xiaomiCloud:
            guard let xiaomiCloud else { return [] }
            return await xiaomiCloud.fetchSensorHistory(
                deviceId: route.sourceDeviceID,
                window: window,
                now: now
            )
        case .demo:
            return []
        }
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .hd)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality
    ) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality, channel: 0)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality, channel: channel, audioEnabled: false)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int,
        audioEnabled: Bool
    ) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality, channel: channel, audioEnabled: audioEnabled, explicitlyDisabledBackends: [])
    }

    func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int,
        audioEnabled: Bool = false,
        explicitlyDisabledBackends: Set<HomeBackend>
    ) async throws -> CameraStreamSource {
        let disabled = disabledBackendsGate.snapshot()
        let activeHA = disabled.contains(.homeAssistant) ? nil : homeAssistant
        let activeMi = disabled.contains(.xiaomiCloud) ? nil : xiaomiCloud
        if let route = routes[device.id] {
            if let previous = activeCameraRoutes[device.id],
               (previous.backend != route.backend || previous.sourceDeviceID != route.sourceDeviceID) {
                await stopCameraStream(for: previous)
            }
            switch route.backend {
            case .homeAssistant:
                if let activeHA {
                    let source = try await activeHA.resolveCameraStream(
                        for: route.sourceDevice,
                        quality: quality,
                        channel: channel
                    )
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .xiaomiCloud:
                if let activeMi {
                    let source = try await activeMi.resolveCameraStream(
                        for: route.sourceDevice,
                        quality: quality,
                        channel: channel,
                        audioEnabled: audioEnabled
                    )
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .demo:
                break
            }
        }
        if case .camera(let spec) = device.kind {
            if MiotAddress.parse(spec.entityId) != nil {
                guard let activeMi else {
                    throw HomeProviderError.serviceCallFailed(
                        501,
                        explicitlyDisabledBackends.contains(.xiaomiCloud)
                            ? L10n.tr("米家已停用", "Xiaomi Home is turned off")
                            : HomeProviderError.backendNotConfigured(.xiaomiCloud).localizedDescription
                    )
                }
                let source = try await activeMi.resolveCameraStream(
                    for: device,
                    quality: quality,
                    channel: channel,
                    audioEnabled: audioEnabled
                )
                activeCameraRoutes[device.id] = DeviceMergeRoute(
                    backend: .xiaomiCloud,
                    sourceDeviceID: device.id,
                    sourceDevice: device
                )
                return source
            }
            guard let activeHA else {
                throw HomeProviderError.serviceCallFailed(
                    501,
                    explicitlyDisabledBackends.contains(.homeAssistant)
                        ? L10n.tr("Home Assistant 已停用", "Home Assistant is turned off")
                        : HomeProviderError.backendNotConfigured(.homeAssistant).localizedDescription
                )
            }
            let source = try await activeHA.resolveCameraStream(
                for: device,
                quality: quality,
                channel: channel
            )
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .homeAssistant,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        if let activeHA {
            let source = try await activeHA.resolveCameraStream(
                for: device,
                quality: quality,
                channel: channel
            )
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .homeAssistant,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        if let activeMi {
            let source = try await activeMi.resolveCameraStream(
                for: device,
                quality: quality,
                channel: channel
            )
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .xiaomiCloud,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        throw HomeProviderError.serviceCallFailed(
            501,
            L10n.tr("未配置数据源", "No data source is configured")
        )
    }

    public func stopCameraStream(for device: SmartDevice) async {
        let activeRoute = activeCameraRoutes.removeValue(forKey: device.id)
        let currentRoute = routes[device.id]
        if let activeRoute {
            await stopCameraStream(for: activeRoute)
        }
        if let currentRoute,
           (currentRoute.backend != activeRoute?.backend || currentRoute.sourceDeviceID != activeRoute?.sourceDeviceID) {
            await stopCameraStream(for: currentRoute)
        }
        if activeRoute != nil || currentRoute != nil {
            return
        }
        if case .camera(let spec) = device.kind, MiotAddress.parse(spec.entityId) != nil {
            await xiaomiCloud?.stopCameraStream(for: device)
            return
        }
        await homeAssistant?.stopCameraStream(for: device)
        await xiaomiCloud?.stopCameraStream(for: device)
    }

    private func stopCameraStream(for route: DeviceMergeRoute) async {
        switch route.backend {
        case .homeAssistant:
            await homeAssistant?.stopCameraStream(for: route.sourceDevice)
        case .xiaomiCloud:
            await xiaomiCloud?.stopCameraStream(for: route.sourceDevice)
        case .demo:
            break
        }
    }

    public func shutdown() async {
        isShutDown = true
        let haForward = haTask
        let miForward = miTask
        haTask?.cancel()
        haTask = nil
        miTask?.cancel()
        miTask = nil
        fallbackRecheckGeneration &+= 1
        fallbackRecheckTimer.invalidate()
        continuation?.finish()
        continuation = nil
        // Await the cancelled forwarding loops so no stream reader outlives teardown and races
        // the next suite (#274). `fallbackRecheckTimer` is synchronously invalidated above, and
        // any already-enqueued `completeScheduledFallbackRecheck` exits immediately because
        // `isShutDown` is already set and `fallbackRecheckGeneration` has advanced.
        await haForward?.value
        await miForward?.value
        let ha = homeAssistant
        let mi = xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.shutdown() } }
            if let mi { group.addTask { await mi.shutdown() } }
        }
    }
}

extension DualSourceHomeProvider: DualSourceRecomputing {
    /// Re-merges cached snapshots after a source pin changes, without polling either backend.
    public nonisolated func requestRecompute() {
        Task { await self.recompute() }
    }
}
