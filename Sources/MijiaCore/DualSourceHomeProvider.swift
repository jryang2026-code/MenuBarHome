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

    private var homeAssistant: (any HomeProvider)?
    private var xiaomiCloud: (any HomeProvider)?
    private let knownPreferenceIDs: @Sendable () -> Set<String>
    private let pinnedBackends: @Sendable () -> [String: HomeBackend]
    private let persistCanonicalIDs: CanonicalIDPersistence
    private let nowProvider: @Sendable () -> Date

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var haTask: Task<Void, Never>?
    private var miTask: Task<Void, Never>?
    private var started = false
    private var isShutDown = false
    private var pollingContext = PollingContext()

    private var haStatus: ConnectionStatus = .connecting
    private var miStatus: ConnectionStatus = .connecting
    /// When each source last dropped while holding a snapshot, for the fallback grace (#25).
    private var haOfflineSince: Date?
    private var miOfflineSince: Date?
    /// Re-schedules a recompute for the moment a deferred fallback would take over (#25).
    private var fallbackRecheckTask: Task<Void, Never>?
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeAssistant = homeAssistant
        self.xiaomiCloud = xiaomiCloud
        self.canonical = CanonicalDeviceRegistry(assignments: initialCanonicalIDs)
        self.knownPreferenceIDs = knownPreferenceIDs
        self.pinnedBackends = pinnedBackends
        self.persistCanonicalIDs = persistCanonicalIDs
        self.nowProvider = now
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

    public func invalidateSnapshot(for backend: HomeBackend) {
        guard !isShutDown else { return }
        if backend == .homeAssistant, homeAssistant != nil {
            haSnapshot = nil
            haStatus = .connecting
            haOfflineSince = nil
            haLocalNetworkBlocks = []
        } else if backend == .xiaomiCloud, xiaomiCloud != nil {
            miSnapshot = nil
            miStatus = .connecting
            miOfflineSince = nil
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
            haLocalNetworkBlocks = []
        } else {
            miTask?.cancel()
            miTask = nil
            previous = xiaomiCloud
            xiaomiCloud = next
            miSnapshot = nil
            miStatus = .connecting
            miOfflineSince = nil
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
            if backend == .homeAssistant {
                recordStatusTransition(status, previous: haStatus, offlineSince: &haOfflineSince)
                haStatus = status
                if case .connected = status { haLocalNetworkBlocks.remove(.homeAssistant) }
            } else if backend == .xiaomiCloud {
                recordStatusTransition(status, previous: miStatus, offlineSince: &miOfflineSince)
                miStatus = status
            }
            emitStatus()
            emitSourceStatuses()
            emitLocalNetworkPermission()
            recompute()

        case .sessionExpired(let session):
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
            if backend == .homeAssistant {
                haStatus = .connected
                haOfflineSince = nil
                haSnapshot = home
                haLocalNetworkBlocks = home.localNetworkBlockedFeatures
            } else if backend == .xiaomiCloud {
                miStatus = .connected
                miOfflineSince = nil
                miSnapshot = home
                miLocalNetworkBlocks = home.localNetworkBlockedFeatures
            }
            emitStatus()
            emitLocalNetworkPermission()
            recompute()
        }
    }

    private func sourceStreamFinished(_ backend: HomeBackend) {
        guard !isShutDown else { return }
        if backend == .homeAssistant {
            guard homeAssistant != nil else { return }
            recordStatusTransition(.disconnected(""), previous: haStatus, offlineSince: &haOfflineSince)
            haStatus = .disconnected("")
        } else if backend == .xiaomiCloud {
            guard xiaomiCloud != nil else { return }
            recordStatusTransition(.disconnected(""), previous: miStatus, offlineSince: &miOfflineSince)
            miStatus = .disconnected("")
        }
        emitStatus()
        emitSourceStatuses()
        recompute()
    }

    /// Marks when a source that still holds a snapshot dropped, so the fallback grace (#25) can
    /// keep its cards routed until the drop proves persistent.
    private func recordStatusTransition(
        _ next: ConnectionStatus,
        previous: ConnectionStatus,
        offlineSince: inout Date?
    ) {
        if next.isConnected {
            offlineSince = nil
        } else if previous.isConnected {
            offlineSince = nowProvider()
        }
    }

    /// Test seam (#25): rewinds the recorded drop timestamps past the grace window and re-merges,
    /// so store-level tests reach the post-grace fallback deterministically without waiting the
    /// window out in wall-clock time.
    public func expireFallbackGraceForTesting() {
        if let since = haOfflineSince {
            haOfflineSince = since.addingTimeInterval(-(Self.sourceFallbackGrace + 1))
        }
        if let since = miOfflineSince {
            miOfflineSince = since.addingTimeInterval(-(Self.sourceFallbackGrace + 1))
        }
        recompute()
    }

    /// A dropped source stays trusted while its last snapshot is this fresh (#25). The status bar
    /// keeps showing the real state; only routing holds.
    private static func effectiveConnected(
        actual: Bool,
        snapshot: SynthesizedHome?,
        offlineSince: Date?,
        now: Date
    ) -> Bool {
        if actual { return true }
        guard let snapshot, !snapshot.devices.isEmpty, let offlineSince else { return false }
        return now.timeIntervalSince(offlineSince) < sourceFallbackGrace
    }

    /// Schedules the recompute that adopts the fallback once a deferred grace expires, so a silent
    /// line (no further events) still hands the cards to the surviving source (#25).
    private func scheduleFallbackRecheckIfNeeded(now: Date) {
        fallbackRecheckTask?.cancel()
        guard let deadline = earliestPendingFallbackDeadline(after: now) else { return }
        fallbackRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, now.distance(to: deadline))))
            await self?.recompute()
        }
    }

    private func earliestPendingFallbackDeadline(after now: Date) -> Date? {
        var deadline: Date?
        if homeAssistant != nil, !haStatus.isConnected, let since = haOfflineSince {
            let expiry = since.addingTimeInterval(Self.sourceFallbackGrace)
            if expiry > now { deadline = deadline.map { min($0, expiry) } ?? expiry }
        }
        if xiaomiCloud != nil, !miStatus.isConnected, let since = miOfflineSince {
            let expiry = since.addingTimeInterval(Self.sourceFallbackGrace)
            if expiry > now { deadline = deadline.map { min($0, expiry) } ?? expiry }
        }
        return deadline
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

    private func recompute(allowEmpty: Bool = false) {
        guard !isShutDown else { return }
        guard allowEmpty || haSnapshot != nil || miSnapshot != nil else { return }
        let now = nowProvider()
        // Hysteresis (#25): a source that just dropped keeps routing its cards for the grace
        // window, so a brief blip neither flips paired cards nor kills a live camera view. The
        // deadline task re-merges when the window lapses, even if no further event arrives.
        let haGraceConnected = Self.effectiveConnected(
            actual: haStatus.isConnected,
            snapshot: haSnapshot,
            offlineSince: haOfflineSince,
            now: now
        )
        let miGraceConnected = Self.effectiveConnected(
            actual: miStatus.isConnected,
            snapshot: miSnapshot,
            offlineSince: miOfflineSince,
            now: now
        )
        let result = DeviceDeduplicator.merge(
            homeAssistant: haSnapshot,
            xiaomiCloud: miSnapshot,
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
        pollingContext = context
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
        fallbackRecheckTask?.cancel()
        fallbackRecheckTask = nil
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
