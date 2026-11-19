import Foundation

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
    private let graceSleepProvider: @Sendable (Duration) async throws -> Void

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
    private var miAccountStatuses: [String: ConnectionStatus] = [:]
    private var miAccountOfflineSince: [String: SuspendingClock.Instant] = [:]
    private var miAccountPreDropDevices: [String: [String: SmartDevice]] = [:]
    private var miExpiredAccountIDs: Set<String> = []
    private var inactiveSince: SuspendingClock.Instant?
    private var haGraceActiveInLastRecompute = false
    private var miGraceActiveInLastRecompute = false
    private var miGracedAccountsInLastRecompute: Set<String> = []
    /// Re-schedules a recompute for the moment a deferred fallback would take over (#25).
    private var fallbackRecheckTask: Task<Void, Never>?
    private var fallbackRecheckGeneration: UInt64 = 0
    private(set) var discardedFallbackWakeCountForTesting = 0
    private var haSnapshot: SynthesizedHome?
    private var miSnapshot: SynthesizedHome?
    private var haLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var miLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var lastEmittedLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var lastStatus: ConnectionStatus?

    private var canonical: CanonicalDeviceRegistry
    private var rooms = RoomIdentityRegistry()
    private var routes: [String: DeviceMergeRoute] = [:]
    private var haCanonicalIDs: [String: String] = [:]
    private var miCanonicalIDs: [String: String] = [:]
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
        persistCanonicalIDs: @escaping CanonicalIDPersistence = { _ in },
        graceNow: @escaping @Sendable () -> SuspendingClock.Instant = { SuspendingClock.now },
        graceSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await SuspendingClock().sleep(for: duration)
        }
    ) {
        self.homeAssistant = homeAssistant
        self.xiaomiCloud = xiaomiCloud
        self.canonical = CanonicalDeviceRegistry(assignments: initialCanonicalIDs)
        self.knownPreferenceIDs = knownPreferenceIDs
        self.pinnedBackends = pinnedBackends
        self.persistCanonicalIDs = persistCanonicalIDs
        self.graceNowProvider = graceNow
        self.graceSleepProvider = graceSleep
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

    public func setSourceProvider(_ next: (any HomeProvider)?, for backend: HomeBackend) async {
        guard !isShutDown else {
            await next?.shutdown()
            return
        }
        let previous: (any HomeProvider)?
        if backend == .homeAssistant {
            haTask?.cancel()
            haTask = nil
            previous = homeAssistant
            homeAssistant = next
            haSnapshot = nil
            haStatus = .connecting
            haOfflineSince = nil
            haGraceActiveInLastRecompute = false
            haLocalNetworkBlocks = []
        } else {
            miTask?.cancel()
            miTask = nil
            previous = xiaomiCloud
            xiaomiCloud = next
            miSnapshot = nil
            miStatus = .connecting
            miOfflineSince = nil
            miGraceActiveInLastRecompute = false
            clearXiaomiAccountGraceState()
            miLocalNetworkBlocks = []
        }
        await previous?.shutdown()
        guard !isShutDown, started else { return }
        if let next {
            startForwarding(next, for: backend)
            await next.setPollingContext(pollingContext)
        }
        emitStatus(force: true)
        emitSourceStatuses()
        emitLocalNetworkPermission()
        if previous != nil {
            recompute(allowEmpty: homeAssistant == nil && xiaomiCloud == nil)
        }
    }

    private func handle(_ event: HomeProviderEvent, from backend: HomeBackend) {
        guard !isShutDown else { return }
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
                if status.isConnected, miAccountStatuses.isEmpty {
                    miExpiredAccountIDs.removeAll()
                }
                recordXiaomiStatusTransition(status, previous: miStatus, now: now)
                miStatus = status
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
                    } == true
                    if miAccountStatuses[expiredID] != nil
                        || miSnapshot?.accountStatuses[expiredID] != nil
                        || hasDeviceForExpiredAccount {
                        miAccountStatuses[expiredID] = expiredStatus
                        miSnapshot?.accountStatuses[expiredID] = expiredStatus
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
                    let ownerIDs = Set(
                        (miSnapshot?.devices ?? []).compactMap {
                            Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs)
                        }
                    )
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
            let sourceCanonicalIDs = backend == .homeAssistant ? haCanonicalIDs : miCanonicalIDs
            if let cardID = sourceCanonicalIDs[ring.deviceId] {
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

    private func sourceStreamFinished(_ backend: HomeBackend) {
        guard !isShutDown else { return }
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

    /// Updates Xiaomi source and per-account grace tracking from `MiAccountsProvider` snapshots.
    /// `MiAccountsProvider` publishes a snapshot right after `.statusChanged(.disconnected)` with
    /// the dropped account's devices marked offline+stale; preserving pre-drop account state keeps
    /// the grace window effective in production while surfacing real `accountStatuses` to Settings.
    private func applyXiaomiSnapshot(_ home: SynthesizedHome) -> Bool {
        var home = home
        let now = effectiveGraceNow()
        let previousMiStatus = miStatus
        let knownIDs = knownXiaomiAccountIDs(in: home)
        if home.accountStatuses.isEmpty {
            if !miExpiredAccountIDs.isEmpty {
                let deviceOwners = Set(
                    home.devices.compactMap { Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs) }
                )
                let hasRecoveredAccount = miStatus == .connecting
                    || deviceOwners.contains { !miExpiredAccountIDs.contains($0) }
                if hasRecoveredAccount, !home.devices.isEmpty {
                    clearXiaomiAccountGraceState()
                    miStatus = .connected
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
            let presentIDs = Set(home.accountStatuses.keys)
            for staleID in Set(miAccountStatuses.keys).union(miExpiredAccountIDs)
            where !presentIDs.contains(staleID) {
                miAccountStatuses.removeValue(forKey: staleID)
                miAccountOfflineSince.removeValue(forKey: staleID)
                miAccountPreDropDevices.removeValue(forKey: staleID)
                miExpiredAccountIDs.remove(staleID)
            }
            for (accountID, nextAccStatus) in home.accountStatuses {
                let prevAccStatus = miAccountStatuses[accountID]
                if nextAccStatus.isConnected {
                    miExpiredAccountIDs.remove(accountID)
                    miAccountStatuses[accountID] = nextAccStatus
                    miAccountOfflineSince.removeValue(forKey: accountID)
                    var owned: [String: SmartDevice] = [:]
                    for device in home.devices
                    where Self.resolvedXiaomiAccountID(for: device, knownAccountIDs: knownIDs) == accountID {
                        owned[device.id] = device
                    }
                    miAccountPreDropDevices[accountID] = owned
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

            let aggregate = Self.aggregateAccountStatus(home.accountStatuses)
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

    /// Drops expired Xiaomi account candidates immediately so paired cards fail over to a
    /// surviving source instead of letting offline/pinned tie-breakers keep a dead session winning,
    /// while restoring pre-drop freshness for non-expired accounts still in their grace window (#25).
    private func effectiveXiaomiSnapshot(
        now: SuspendingClock.Instant
    ) -> (snapshot: SynthesizedHome?, gracedAccountIDs: Set<String>) {
        guard var snapshot = miSnapshot else { return (nil, []) }
        let knownIDs = knownXiaomiAccountIDs(in: snapshot)
        if !miExpiredAccountIDs.isEmpty {
            let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
            for expiredID in miExpiredAccountIDs where snapshot.accountStatuses[expiredID] != nil {
                if case .disconnected = snapshot.accountStatuses[expiredID] {} else {
                    snapshot.accountStatuses[expiredID] = miAccountStatuses[expiredID] ?? expiredStatus
                }
            }
            let statusAccountIDs = Set(snapshot.accountStatuses.keys).union(miAccountStatuses.keys)
            let hasNonExpiredAccount: Bool
            if !statusAccountIDs.isEmpty {
                hasNonExpiredAccount = statusAccountIDs.contains { !miExpiredAccountIDs.contains($0) }
            } else {
                let deviceOwners = Set(
                    snapshot.devices.compactMap { Self.resolvedXiaomiAccountID(for: $0, knownAccountIDs: knownIDs) }
                )
                hasNonExpiredAccount = deviceOwners.contains { !miExpiredAccountIDs.contains($0) }
            }

            snapshot.devices.removeAll { device in
                guard let ownerID = Self.resolvedXiaomiAccountID(for: device, knownAccountIDs: knownIDs) else {
                    // Unattributed Xiaomi devices (`accountId == nil` and unscoped `roomId`) cannot
                    // be verified against a healthy account once a Xiaomi session has expired.
                    return true
                }
                return miExpiredAccountIDs.contains(ownerID)
            }
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
                    return miExpiredAccountIDs.contains(roomOwner)
                }
                return !hasNonExpiredAccount
            }
            snapshot.homes.removeAll { option in
                let ownerID = (option.accountId?.isEmpty == false ? option.accountId : nil)
                    ?? MiAccountScope.owner(of: option.id).flatMap { knownIDs.contains($0) ? $0 : nil }
                if let ownerID {
                    return miExpiredAccountIDs.contains(ownerID)
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
            guard !miExpiredAccountIDs.contains(accountID),
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
            guard let ownerID = Self.resolvedXiaomiAccountID(for: snapshot.devices[index], knownAccountIDs: knownIDs),
                  gracedAccountIDs.contains(ownerID),
                  let restored = miAccountPreDropDevices[ownerID]?[snapshot.devices[index].id] else {
                continue
            }
            snapshot.devices[index] = restored
        }
        return (snapshot, gracedAccountIDs)
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
        fallbackRecheckTask?.cancel()
        fallbackRecheckTask = nil
    }

    /// Schedules the recompute that adopts the fallback once a deferred grace expires, so a silent
    /// line (no further events) still hands the cards to the surviving source (#25).
    private func scheduleFallbackRecheckIfNeeded(now: SuspendingClock.Instant) {
        cancelFallbackRecheck()
        guard pollingContext.systemActive,
              let deadline = earliestPendingFallbackDeadline(after: now) else {
            return
        }
        let token = fallbackRecheckGeneration
        let delay = max(.milliseconds(100), now.duration(to: deadline))
        let sleep = graceSleepProvider
        fallbackRecheckTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await sleep(delay)
            } catch {
                // A newer recompute cancelled this deadline and owns rescheduling now. Waking
                // here to merge again would ping-pong cancelled sleepers into a recompute loop.
                return
            }
            await self?.completeScheduledFallbackRecheck(token: token)
        }
    }

    private func completeScheduledFallbackRecheck(token: UInt64) {
        guard !isShutDown,
              pollingContext.systemActive,
              !Task.isCancelled,
              token == fallbackRecheckGeneration else {
            discardedFallbackWakeCountForTesting += 1
            return
        }
        fallbackRecheckTask = nil
        recompute()
    }

    private func earliestPendingFallbackDeadline(after now: SuspendingClock.Instant) -> SuspendingClock.Instant? {
        var deadline: SuspendingClock.Instant?
        func consider(_ since: SuspendingClock.Instant) {
            let expiry = since.advanced(by: Self.sourceFallbackGraceDuration)
            if expiry > now {
                deadline = deadline.map { min($0, expiry) } ?? expiry
            }
        }
        if homeAssistant != nil, !haStatus.isConnected, let since = haOfflineSince {
            consider(since)
        }
        if xiaomiCloud != nil, !miStatus.isConnected, let since = miOfflineSince {
            consider(since)
        }
        if xiaomiCloud != nil {
            for (accountID, since) in miAccountOfflineSince
            where !(miAccountStatuses[accountID]?.isConnected ?? true) && !miExpiredAccountIDs.contains(accountID) {
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
        if haGraceActiveInLastRecompute {
            let haStillGraced = homeAssistant != nil
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
        var statuses: [ConnectionStatus] = []
        if homeAssistant != nil { statuses.append(haStatus) }
        if xiaomiCloud != nil { statuses.append(miStatus) }
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
        // Hysteresis (#25): a source that just dropped keeps routing its cards for the grace
        // window, so a brief blip neither flips paired cards nor kills a live camera view. The
        // deadline task re-merges when the window lapses, even if no further event arrives.
        let haGraceConnected = Self.effectiveConnected(
            actual: haStatus.isConnected,
            snapshot: haSnapshot,
            offlineSince: haOfflineSince,
            now: now
        )
        let (effectiveMi, gracedMiAccounts) = effectiveXiaomiSnapshot(now: now)
        let miGraceConnected = Self.effectiveConnected(
            actual: miStatus.isConnected,
            snapshot: effectiveMi,
            offlineSince: miOfflineSince,
            now: now
        )
        haGraceActiveInLastRecompute = homeAssistant != nil && !haStatus.isConnected && haGraceConnected
        miGraceActiveInLastRecompute = xiaomiCloud != nil && !miStatus.isConnected && miGraceConnected
        miGracedAccountsInLastRecompute = xiaomiCloud != nil ? gracedMiAccounts : []
        let result = DeviceDeduplicator.merge(
            homeAssistant: haSnapshot,
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
        haCanonicalIDs = result.haCanonicalIDs
        miCanonicalIDs = result.miCanonicalIDs
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
            }
        }
        var home = result.home
        home.accountStatuses = miSnapshot?.accountStatuses ?? [:]
        home.sourceStatuses = configuredSourceStatuses()
        home.localNetworkBlockedFeatures = currentLocalNetworkBlocks()
        continuation?.yield(.snapshotUpdated(home))
    }

    private func currentLocalNetworkBlocks() -> Set<LocalNetworkBlockedFeature> {
        (homeAssistant != nil ? haLocalNetworkBlocks : []).union(xiaomiCloud != nil ? miLocalNetworkBlocks : [])
    }

    private func emitLocalNetworkPermission() {
        let next = currentLocalNetworkBlocks()
        guard next != lastEmittedLocalNetworkBlocks else { return }
        lastEmittedLocalNetworkBlocks = next
        continuation?.yield(.localNetworkPermissionChanged(next))
    }

    private func configuredSourceStatuses() -> [HomeBackend: ConnectionStatus] {
        var statuses: [HomeBackend: ConnectionStatus] = [:]
        if homeAssistant != nil { statuses[.homeAssistant] = haStatus }
        if xiaomiCloud != nil { statuses[.xiaomiCloud] = miStatus }
        return statuses
    }

    // MARK: - Commands

    public func execute(_ command: DeviceCommand) async throws {
        if MiotAddress.parse(command.targetEntityId) != nil {
            guard let xiaomiCloud else {
                throw HomeProviderError.backendNotConfigured(.xiaomiCloud)
            }
            try await xiaomiCloud.execute(command)
        } else {
            guard let homeAssistant else {
                throw HomeProviderError.backendNotConfigured(.homeAssistant)
            }
            try await homeAssistant.execute(command)
        }
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let route = routes[deviceId] else { return .failed }
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
        let ha = homeAssistant
        let mi = xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.refreshNow() } }
            if let mi { group.addTask { await mi.refreshNow() } }
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
        let ha = homeAssistant
        let mi = xiaomiCloud
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
        guard let route = routes[deviceId] else { return [] }
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
        if let route = routes[device.id] {
            if let previous = activeCameraRoutes[device.id],
               (previous.backend != route.backend || previous.sourceDeviceID != route.sourceDeviceID) {
                await stopCameraStream(for: previous)
            }
            switch route.backend {
            case .homeAssistant:
                if let homeAssistant {
                    let source = try await homeAssistant.resolveCameraStream(
                        for: route.sourceDevice,
                        quality: quality,
                        channel: channel
                    )
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .xiaomiCloud:
                if let xiaomiCloud {
                    let source = try await xiaomiCloud.resolveCameraStream(
                        for: route.sourceDevice,
                        quality: quality,
                        channel: channel
                    )
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .demo:
                break
            }
        }
        if case .camera(let spec) = device.kind,
           MiotAddress.parse(spec.entityId) != nil,
           let xiaomiCloud {
            let source = try await xiaomiCloud.resolveCameraStream(
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
        if let homeAssistant {
            let source = try await homeAssistant.resolveCameraStream(
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
        if let xiaomiCloud {
            let source = try await xiaomiCloud.resolveCameraStream(
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
        haTask?.cancel()
        haTask = nil
        miTask?.cancel()
        miTask = nil
        cancelFallbackRecheck()
        continuation?.finish()
        continuation = nil
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
