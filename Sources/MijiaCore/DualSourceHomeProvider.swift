import Foundation

/// Keeps both providers connected and publishes one merged home. Commands are routed by their
/// target address, so an entity id decides the source without a second lookup table.
public actor DualSourceHomeProvider: HomeProvider {
    public typealias CanonicalIDPersistence = @Sendable ([String: String]) -> Void

    private var homeAssistant: (any HomeProvider)?
    private var xiaomiCloud: (any HomeProvider)?
    private let knownPreferenceIDs: @Sendable () -> Set<String>
    private let pinnedBackends: @Sendable () -> [String: HomeBackend]
    private let persistCanonicalIDs: CanonicalIDPersistence

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var haTask: Task<Void, Never>?
    private var miTask: Task<Void, Never>?
    private var started = false
    private var isShutDown = false
    private var pollingContext = PollingContext()

    private var haStatus: ConnectionStatus = .connecting
    private var miStatus: ConnectionStatus = .connecting
    private var haSnapshot: SynthesizedHome?
    private var miSnapshot: SynthesizedHome?
    private var lastStatus: ConnectionStatus?

    private var canonical: CanonicalDeviceRegistry
    private var rooms = RoomIdentityRegistry()
    private var routes: [String: DeviceMergeRoute] = [:]
    private var haCanonicalIDs: [String: String] = [:]
    private var miCanonicalIDs: [String: String] = [:]
    private var activeCameraRoutes: [String: DeviceMergeRoute] = [:]
    /// Merged card id → the latest press time each backend reported. A press the two sources
    /// both report counts once (#23).
    private var doorbellPressesByCard: [String: [HomeBackend: Date]] = [:]

    /// A doorbell press the two sources both report within this window counts once (#23). Both
    /// timestamps come from the device's own event clock, so cross-source skew stays far under
    /// the window; a human double-press (plus the doorbell's own debounce) spans well over it.
    /// The window is a fixed constant, so the boundary is deterministic and testable.
    static let crossSourceDoorbellDedupWindow: TimeInterval = 2

    var isShutDownForTesting: Bool { isShutDown }

    public init(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        initialCanonicalIDs: [String: String] = [:],
        knownPreferenceIDs: @escaping @Sendable () -> Set<String> = { [] },
        pinnedBackends: @escaping @Sendable () -> [String: HomeBackend] = { [:] },
        persistCanonicalIDs: @escaping CanonicalIDPersistence = { _ in }
    ) {
        self.homeAssistant = homeAssistant
        self.xiaomiCloud = xiaomiCloud
        self.canonical = CanonicalDeviceRegistry(assignments: initialCanonicalIDs)
        self.knownPreferenceIDs = knownPreferenceIDs
        self.pinnedBackends = pinnedBackends
        self.persistCanonicalIDs = persistCanonicalIDs
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
        } else if backend == .xiaomiCloud, xiaomiCloud != nil {
            miSnapshot = nil
            miStatus = .connecting
        } else {
            return
        }
        guard started else { return }
        emitStatus(force: true)
        emitSourceStatuses()
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
        } else {
            miTask?.cancel()
            miTask = nil
            previous = xiaomiCloud
            xiaomiCloud = next
            miSnapshot = nil
            miStatus = .connecting
        }
        await previous?.shutdown()
        guard !isShutDown, started else { return }
        if let next {
            startForwarding(next, for: backend)
            await next.setPollingContext(pollingContext)
        }
        emitStatus(force: true)
        emitSourceStatuses()
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
                haStatus = status
            } else if backend == .xiaomiCloud {
                miStatus = status
            }
            emitStatus()
            emitSourceStatuses()
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
            if let firedAt = ring.firedAtDate {
                if isCrossSourceDuplicateDoorbellPress(of: ring.deviceId, from: backend, at: firedAt) {
                    return
                }
                var presses = doorbellPressesByCard[ring.deviceId] ?? [:]
                presses[backend] = firedAt
                doorbellPressesByCard[ring.deviceId] = presses
            }
            continuation?.yield(.doorbellRang(ring))

        case .sourceStatusesChanged:
            break

        case .snapshotUpdated(let home):
            if backend == .homeAssistant {
                haStatus = .connected
                haSnapshot = home
            } else if backend == .xiaomiCloud {
                miStatus = .connected
                miSnapshot = home
            }
            emitStatus()
            recompute()
        }
    }

    private func sourceStreamFinished(_ backend: HomeBackend) {
        guard !isShutDown else { return }
        if backend == .homeAssistant {
            guard homeAssistant != nil else { return }
            haStatus = .disconnected("")
        } else if backend == .xiaomiCloud {
            guard xiaomiCloud != nil else { return }
            miStatus = .disconnected("")
        }
        emitStatus()
        emitSourceStatuses()
        recompute()
    }

    /// True when the other backend already reported this card's press within the dedupe window
    /// (#23). Suppressed presses are not recorded, so a genuine later press from either source
    /// still rings; only the already-yielded press's timestamp is remembered.
    private func isCrossSourceDuplicateDoorbellPress(of cardID: String, from backend: HomeBackend, at firedAt: Date) -> Bool {
        guard backend == .homeAssistant || backend == .xiaomiCloud else { return false }
        let otherBackend: HomeBackend = backend == .homeAssistant ? .xiaomiCloud : .homeAssistant
        guard let other = doorbellPressesByCard[cardID]?[otherBackend] else { return false }
        return abs(firedAt.timeIntervalSince(other)) <= Self.crossSourceDoorbellDedupWindow
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
        let result = DeviceDeduplicator.merge(
            homeAssistant: haSnapshot,
            xiaomiCloud: miSnapshot,
            haConnected: haStatus.isConnected,
            miConnected: miStatus.isConnected,
            canonical: canonical,
            rooms: rooms,
            knownPreferenceIDs: knownPreferenceIDs(),
            pinnedBackends: pinnedBackends()
        )
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
        continuation?.yield(.snapshotUpdated(home))
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
