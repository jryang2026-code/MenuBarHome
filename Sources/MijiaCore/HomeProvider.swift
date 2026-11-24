import Foundation
import os

public enum HomeBackend: String, CaseIterable, Identifiable, Sendable {
    case homeAssistant = "homeAssistant"
    case xiaomiCloud = "xiaomiCloud"
    /// A built-in virtual home that works without an account and never touches the network (#47).
    case demo = "demo"

    public var id: String { rawValue }

    public var title: String {
        descriptor.title
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Retry delays used while Home Assistant is away. The final segment is deliberately long so a
/// laptop that is off-site does not spend its battery reconnecting every few seconds.
struct HAReconnectBackoff: Sendable {
    private static let segments: [Duration] = [.milliseconds(800), .seconds(2), .seconds(4), .seconds(8), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]
    private(set) var failures = 0

    mutating func reset() { failures = 0 }
    mutating func next(localEndpoint: Bool = true) -> Duration {
        let delay = Self.segments[failures]
        failures = min(failures + 1, Self.segments.count - 1)
        return localEndpoint ? delay : min(delay, .seconds(10))
    }
}

/// What a provider can say after a power write.
///
/// `published` means a snapshot with the device's own properties was emitted.
/// `unavailable` means this provider has no property read (the accepted command is the result).
/// `failed` means a read was attempted and did not produce a snapshot.
public enum ControlReadBack: Sendable {
    case published
    case unavailable
    case failed
}

public enum HomeProviderEvent: Sendable {
    case statusChanged(ConnectionStatus)
    case snapshotUpdated(SynthesizedHome)
    /// Per-source states for a composite provider, emitted even when no snapshot is available
    /// (for example while both sources are reconnecting) so the panel footer cannot go stale (#111).
    case sourceStatusesChanged([HomeBackend: ConnectionStatus])
    case localNetworkPermissionChanged(Set<LocalNetworkBlockedFeature>)
    /// The cloud rejected the session; the store persists it as the session's end (#181).
    case sessionExpired(MiSession)
    /// A Home Assistant doorbell was pressed (#308).
    case doorbellRang(DoorbellRing)
    /// One Mi account's device-type pruning result (P3a-M): the identities a closed type keeps for
    /// the write gate and the hidden devices whose enabled safety alerts still need evaluating.
    case miotTypePruneChanged(MiotTypePruneReport)
    /// The Home Assistant connection's device-type pruning result (P3b-M), in the same report shape
    /// and scoped to its `ha:` address.
    case haTypePruneChanged(MiotTypePruneReport)
}

public enum HomeProviderError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case unauthorized
    case serviceCallFailed(Int, String)
    case networkError(String)
    /// A routed command needs a backend the composite provider was not given.
    case backendNotConfigured(HomeBackend)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return L10n.tr("无效的 HA 地址：\(u)", "Invalid HA URL: \(u)")
        case .unauthorized: return L10n.tr("令牌无效或已过期，请在设置中更新", "Invalid or expired token; update it in Settings")
        case .serviceCallFailed(let code, let msg): return L10n.tr("指令执行失败 (\(code))：\(msg)", "Command failed (\(code)): \(msg)")
        case .networkError(let msg): return L10n.tr("网络异常：\(msg)", "Network error: \(msg)")
        case .backendNotConfigured(.xiaomiCloud):
            return L10n.tr("米家云端未配置", "Xiaomi Cloud is not configured")
        case .backendNotConfigured(.homeAssistant):
            return L10n.tr("Home Assistant 未配置", "Home Assistant is not configured")
        case .backendNotConfigured(.demo):
            return L10n.tr("当前数据源未配置", "No data source is configured")
        }
    }
}

public enum AdapterErrorCode: String, Sendable {
    case authExpired
    case unreachable
    case rateLimited
    case unsupported
    case deviceOffline
    case unknown

    public init(classifying error: any Error) {
        if case .unsupported? = error as? MiotCommandError {
            self = .unsupported
            return
        }
        if case .serviceCallFailed(let status, _)? = error as? HomeProviderError {
            self.init(httpStatus: status)
            return
        }
        if case .http(let status)? = error as? MiCloudError {
            self.init(httpStatus: status)
            return
        }
        switch ControlFailure.classify(error) {
        case .sessionExpired, .signedOut, .tokenRejected: self = .authExpired
        case .network: self = .unreachable
        case .rateLimited: self = .rateLimited
        case .deviceOffline: self = .deviceOffline
        default: self = .unknown
        }
    }

    init(httpStatus: Int) {
        switch httpStatus {
        case 401, 403: self = .authExpired
        case 408, 502, 503, 504: self = .unreachable
        case 429: self = .rateLimited
        case 501: self = .unsupported
        default: self = .unknown
        }
    }
}

public enum HomeProviderCapability: String, Sendable {
    case readSnapshot
    case pushEvents
    case control
    case scenes
    case cameras
}

public protocol HomeProvider: Sendable {
    func events() -> AsyncStream<HomeProviderEvent>
    func execute(_ command: DeviceCommand) async throws
    func refreshNow() async
    /// Clears LAN failure cooldowns (for `deviceId`, or all devices when `nil`) and polls right away.
    func retryLAN(deviceId: String?) async
    /// Tells a polling provider whether the panel is open and the Mac is awake, so it can slow down or pause (#26).
    func setPollingContext(_ context: PollingContext) async
    /// Fetches historical temperature and humidity readings for `deviceId` over `window`.
    func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample]
    /// Resolves a playable live video or snapshot stream for a camera device.
    func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource
    func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource
    /// `channel` selects a second lens on cameras whose bridge supports it. Zero is the main lens.
    func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource
    /// Releases any active live stream session (such as a single-session P2P bridge) for a camera device.
    func stopCameraStream(for device: SmartDevice) async
    func readBack(deviceId: String) async -> ControlReadBack
    /// Stops sockets and polling and finishes the event stream. The store calls it on the provider
    /// it is replacing; a provider is not used again afterwards.
    func shutdown() async
}

extension HomeProvider {
    public func retryLAN(deviceId: String?) async {
        await refreshNow()
    }

    /// Push-based providers (Home Assistant) have nothing to slow down.
    public func setPollingContext(_ context: PollingContext) async {}

    public func readBack(deviceId: String) async -> ControlReadBack { .unavailable }
    public func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample] { [] }
    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        throw HomeProviderError.serviceCallFailed(501, L10n.tr("当前数据源暂未返回该摄像头的实时画面流", "Current backend did not return a live stream for this camera"))
    }
    public func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device)
    }
    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality)
    }
    public func stopCameraStream(for device: SmartDevice) async {}
    /// Providers with nothing running in the background have nothing to stop.
    public func shutdown() async {}
}

// MARK: - Live Home Assistant WebSocket + REST Provider

protocol HAWebSocketConnection: AnyObject, Sendable {
    func resume()
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
}

private final class URLSessionHAWebSocketConnection: HAWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> Data {
        let msg = try await task.receive()
        switch msg {
        case .string(let s): return Data(s.utf8)
        case .data(let d): return d
        @unknown default: return Data()
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

public actor HAWebSocketProvider: HomeProvider {
    private static let compressedSubscriptionID = 4

    public static let capabilities: Set<HomeProviderCapability> = [
        .readSnapshot, .pushEvents, .control, .scenes, .cameras,
    ]

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "HAWebSocket")
    private var baseURLString: String
    private var token: String
    private var session: URLSession?
    private var isShutDown = false

    private var emitEvent: (@Sendable (HomeAdapterEvent) -> Void)?
    private var finishEvents: (@Sendable () -> Void)?
    private var loopTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Error>?
    private var activeWebSocket: (any HAWebSocketConnection)?
    private var handshakingWebSocket: (any HAWebSocketConnection)?
    private var nextWebSocketMessageId: Int = 5
    private var pendingRefreshStateIds: [Int: ContinuousClock.Instant] = [:]
    private var initialPollCapturedEpochs: [Int: ContinuousClock.Instant] = [:]
    private var pendingStreamRequests: [Int: CheckedContinuation<String?, Never>] = [:]
    private var startupReplies: [Int: [String: JSONValue]] = [:]
    private var startupWaiters: [Int: (UUID, CheckedContinuation<[String: JSONValue], Error>)] = [:]
    private var startupFailure: Error?
    private var legacyInitialStatesID: Int?
    private var legacySubscriptionID: Int?

    var hasActiveSessionForTesting: Bool { session != nil }
    var hasActiveWebSocketForTesting: Bool { activeWebSocket != nil }
    var isShutDownForTesting: Bool { isShutDown }
    private(set) var createdSessionCountForTesting: Int = 0
    private(set) var invalidatedSessionCountForTesting: Int = 0

    func prepareSessionForTesting() {
        _ = replaceSession()
    }

    private var snapshot = HAHomeSnapshot()
    private var pollingContext = PollingContext()
    private var lastEmittedHome: SynthesizedHome?
    private var coalesceTask: Task<Void, Never>?
    private var hasPendingCoalescedSynthesis = false
    private var lastLiveSynthesisAt: ContinuousClock.Instant?
    var liveEventCoalesceWindowOverride: Duration?
    /// Read for every frame, so a type the user closes stops re-synthesizing on the next one (P3b-M).
    private let typePrunePolicyLoader: @Sendable () -> HATypePrunePolicy
    /// Told about another Home Assistant address found after repeated disconnects. The provider never
    /// switches by itself: the token only goes to a new address after the user agrees (#18).
    private let onAddressSuggestion: (@Sendable (HADiscoveredInstance) -> Void)?
    private var lastRediscoveryAt: Date?
    /// Test seam for the LAN scan after a disconnect.
    private let rediscover: @Sendable (String) async -> [HADiscoveredInstance]
    /// Whether the token may go to an address; public plain http needs the user's consent (#276).
    private let allowsToken: @Sendable (String) -> Bool
    /// Told when the address needs plaintext consent; nothing carrying the token is sent until then.
    private let onPlaintextConsentNeeded: (@Sendable (String) -> Void)?
    private let isNetworkSatisfied: @Sendable () async -> Bool
    private var isLocalNetworkDenied = false
    private var pendingPingID: Int?
    private var pongTimeoutTask: Task<Void, Never>?

    enum ConnectTestOutcome: Sendable {
        case failedBeforeAuth(any Error)
        case authenticatedThenDisconnected(any Error)
        case authenticatedStayConnected
    }

    /// Test seams for retry, backoff, and the camera-stream timeout. Tests gate these instead of sleeping.
    private var connectOverride: (@Sendable () async throws -> ConnectTestOutcome)?
    private var webSocketFactoryOverride: (@Sendable (URL) -> any HAWebSocketConnection)?
    private var reconnectSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var transportSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var streamRequestTimeout: @Sendable () async -> Void = {
        try? await Task.sleep(for: .milliseconds(3500))
    }

    func setTestSeams(
        connectOverride: (@Sendable () async throws -> ConnectTestOutcome)?,
        reconnectSleep: (@Sendable (Duration) async throws -> Void)? = nil,
        webSocketFactory: (@Sendable (URL) -> any HAWebSocketConnection)? = nil,
        streamRequestTimeout: (@Sendable () async -> Void)? = nil,
        transportSleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.connectOverride = connectOverride
        if let reconnectSleep {
            self.reconnectSleep = reconnectSleep
        }
        self.webSocketFactoryOverride = webSocketFactory
        if let transportSleep { self.transportSleep = transportSleep }
        if let streamRequestTimeout {
            self.streamRequestTimeout = streamRequestTimeout
        }
    }

    public init(
        baseURLString: String,
        token: String,
        onAddressSuggestion: (@Sendable (HADiscoveredInstance) -> Void)? = nil,
        rediscover: @escaping @Sendable (String) async -> [HADiscoveredInstance] = { await HADiscovery.discoverOnLAN(currentURLHint: $0) },
        allowsToken: @escaping @Sendable (String) -> Bool = { HAPlaintextConsent.allowsToken(to: $0, defaults: .standard) },
        onPlaintextConsentNeeded: (@Sendable (String) -> Void)? = nil,
        isNetworkSatisfied: @escaping @Sendable () async -> Bool = { false },
        typePrunePolicyLoader: @escaping @Sendable () -> HATypePrunePolicy = { .unpruned }
    ) {
        self.typePrunePolicyLoader = typePrunePolicyLoader
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        self.onAddressSuggestion = onAddressSuggestion
        self.rediscover = rediscover
        self.allowsToken = allowsToken
        self.onPlaintextConsentNeeded = onPlaintextConsentNeeded
        self.isNetworkSatisfied = isNetworkSatisfied
    }

    private static func makeURLSession() -> URLSession {
        // Bypass system proxies for direct LAN communication with NAS
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private func ensureSession() -> URLSession? {
        guard !isShutDown else { return nil }
        if let session { return session }
        let created = Self.makeURLSession()
        self.session = created
        createdSessionCountForTesting += 1
        return created
    }

    private func replaceSession() -> URLSession? {
        guard !isShutDown else { return nil }
        let previous = self.session
        let created = Self.makeURLSession()
        self.session = created
        createdSessionCountForTesting += 1
        if let previous {
            invalidatedSessionCountForTesting += 1
            previous.invalidateAndCancel()
        }
        return created
    }

    private func invalidateSession(ifMatching target: URLSession? = nil) {
        if let target {
            guard self.session === target else { return }
            self.session = nil
            invalidatedSessionCountForTesting += 1
            target.invalidateAndCancel()
        } else {
            let old = self.session
            self.session = nil
            if let old {
                invalidatedSessionCountForTesting += 1
                old.invalidateAndCancel()
            }
        }
    }

    /// The address the provider is using; it only changes through `updateCredentials`.
    public var currentBaseURLString: String { baseURLString }

    var latestSnapshot: SynthesizedHome? {
        isShutDown ? nil : lastEmittedHome
    }

    public func updateCredentials(baseURLString: String, token: String) {
        let normalizedURL = Self.normalizeBaseURL(baseURLString)
        publishStaleRetainedDevices()
        lastEmittedHome = nil
        if self.baseURLString == normalizedURL {
            snapshot.resetForReconnect()
        } else {
            snapshot = HAHomeSnapshot()
        }
        self.baseURLString = normalizedURL
        self.token = token
        updateLocalNetworkDenied(false)
        guard !isShutDown else { return }
        restartLoop()
    }

    public func setPollingContext(_ context: PollingContext) async {
        guard !isShutDown else { return }
        let becameVisible = context.panelVisible && !pollingContext.panelVisible
        let becameActive = context.systemActive && !pollingContext.systemActive
        let resumed = !context.haTransportSuspended && pollingContext.haTransportSuspended
        let topologyChanged = context.haTransportRevision != pollingContext.haTransportRevision
        pollingContext = context
        if context.haTransportSuspended {
            stopPingLoop()
            if activeWebSocket == nil {
                stopConnectionLoop()
            }
        } else if topologyChanged || ((resumed || becameActive || becameVisible) && activeWebSocket == nil && handshakingWebSocket == nil) {
            if emitEvent != nil { restartLoop() }
        } else if !context.systemActive {
            stopPingLoop()
        } else if (resumed || becameActive), let ws = activeWebSocket {
            startPingLoop(ws: ws, probeImmediately: true)
        }
        if (becameVisible || becameActive), hasPendingCoalescedSynthesis {
            flushPendingCoalescedSynthesis()
        }
    }

    public func shutdown() async {
        isShutDown = true
        stopConnectionLoop()
        invalidateSession()
        finishEvents?()
        emitEvent = nil
        finishEvents = nil
    }

    private func failPendingStreamRequests() {
        pendingRefreshStateIds.removeAll()
        let waiters = pendingStreamRequests.values
        pendingStreamRequests.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func allocateWebSocketMessageId() -> Int {
        nextWebSocketMessageId += 1
        return nextWebSocketMessageId
    }

    private func sendWebSocketPing(ws: any HAWebSocketConnection) async {
        guard !Task.isCancelled, activeWebSocket === ws else { return }
        let id = allocateWebSocketMessageId()
        pongTimeoutTask?.cancel()
        pendingPingID = id
        pongTimeoutTask = Task { [weak self, transportSleep] in
            do {
                try await transportSleep(.milliseconds(2500))
                try Task.checkCancellation()
                await self?.handlePongTimeout(ws: ws, id: id)
            } catch {}
        }
        do {
            try await sendJSON(ws: ws, ["id": id, "type": "ping"])
        } catch {
            handlePongTimeout(ws: ws, id: id)
        }
    }

    private func handlePong(ws: any HAWebSocketConnection, id: Int) {
        guard activeWebSocket === ws, id == pendingPingID else { return }
        pendingPingID = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
    }

    private func handlePongTimeout(ws: any HAWebSocketConnection, id: Int) {
        guard pendingPingID == id, activeWebSocket === ws else { return }
        restartLoop()
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
        pendingPingID = nil
    }

    private func startPingLoop(ws: any HAWebSocketConnection, probeImmediately: Bool = false) {
        stopPingLoop()
        pingTask = Task { [weak self, transportSleep] in
            if probeImmediately { await self?.sendWebSocketPing(ws: ws) }
            while !Task.isCancelled {
                do {
                    try await transportSleep(.seconds(25))
                    try Task.checkCancellation()
                    await self?.sendWebSocketPing(ws: ws)
                } catch { break }
            }
        }
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        eventStream { $0.providerEvent }
    }

    nonisolated func eventStream<Event: Sendable>(
        _ transform: @escaping @Sendable (HomeAdapterEvent) -> Event
    ) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        Task { await self.attachContinuation(continuation, transform: transform) }
        return stream
    }

    private func attachContinuation<Event: Sendable>(
        _ continuation: AsyncStream<Event>.Continuation,
        transform: @escaping @Sendable (HomeAdapterEvent) -> Event
    ) {
        guard !isShutDown else {
            continuation.finish()
            return
        }
        emitEvent = { continuation.yield(transform($0)) }
        finishEvents = { continuation.finish() }
        restartLoop()
    }

    public func refreshNow() async {
        guard !isShutDown, !pollingContext.haTransportSuspended else { return }
        if let ws = activeWebSocket {
            let id = allocateWebSocketMessageId()
            pendingRefreshStateIds[id] = .now
            do {
                try await sendJSON(ws: ws, ["id": id, "type": "get_states"])
            } catch {
                pendingRefreshStateIds.removeValue(forKey: id)
            }
        } else if handshakingWebSocket == nil {
            restartLoop()
        }
    }

    private func stopConnectionLoop() {
        coalesceTask?.cancel()
        coalesceTask = nil
        hasPendingCoalescedSynthesis = false
        loopTask?.cancel()
        loopTask = nil
        stopPingLoop()
        receiveTask?.cancel()
        receiveTask = nil
        handshakingWebSocket?.cancel()
        handshakingWebSocket = nil
        activeWebSocket?.cancel()
        activeWebSocket = nil
        failPendingStartupReplies(with: CancellationError())
        failPendingStreamRequests()
    }

    private func restartLoop() {
        guard !isShutDown else { return }
        stopConnectionLoop()
        invalidateSession()
        guard !pollingContext.haTransportSuspended else { return }

        loopTask = Task {
            await runConnectionLoop()
        }
    }

    private func runConnectionLoop() async {
        var backoff = HAReconnectBackoff()
        var consecutiveFailures = 0
        while !Task.isCancelled, !pollingContext.haTransportSuspended {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateLocalNetworkDenied(false)
                emitEvent?(.statusChanged(.disconnected(L10n.tr("请在设置中配置访问令牌", "Configure your access token in Settings"))))
                return
            }
            guard allowsToken(baseURLString) else {
                updateLocalNetworkDenied(false)
                onPlaintextConsentNeeded?(baseURLString)
                emitEvent?(.statusChanged(.disconnected(HAPlaintextConsent.waitingMessage(baseURLString))))
                return
            }
            emitEvent?(.statusChanged(.connecting))
            do {
                if let connectOverride {
                    let outcome = try await connectOverride()
                    try Task.checkCancellation()
                    switch outcome {
                    case .failedBeforeAuth(let error):
                        throw error
                    case .authenticatedThenDisconnected(let error):
                        backoff.reset()
                        consecutiveFailures = 0
                        updateLocalNetworkDenied(false)
                        emitEvent?(.statusChanged(.connected))
                        throw error
                    case .authenticatedStayConnected:
                        backoff.reset()
                        consecutiveFailures = 0
                        updateLocalNetworkDenied(false)
                        emitEvent?(.statusChanged(.connected))
                        return
                    }
                } else {
                    try await connectAndListen {
                    backoff.reset()
                    consecutiveFailures = 0
                    }
                }
                backoff.reset()
                consecutiveFailures = 0
            } catch {
                if Task.isCancelled { break }
                let networkSatisfied = await isNetworkSatisfied()
                guard !Task.isCancelled else { break }
                let host = URL(string: Self.normalizeBaseURL(baseURLString))?.host?.lowercased()
                if LocalNetworkPermissionClassifier.isDeniedConnectionError(
                    error, targetHost: host, isGeneralNetworkSatisfied: networkSatisfied
                ) {
                    updateLocalNetworkDenied(true)
                } else if isLocalNetworkDenied, Self.provesPacketCrossedPermissionBoundary(error) {
                    updateLocalNetworkDenied(false)
                }
                if case HomeProviderError.unauthorized = error {
                    activeWebSocket = nil
                    let msg = Self.describeConnectionError(error, baseURLString: baseURLString, isGeneralNetworkSatisfied: networkSatisfied)
                    logger.error("WebSocket unauthorized: \(msg, privacy: .public)")
                    publishStaleRetainedDevices()
                    emitEvent?(.statusChanged(.disconnected(msg)))
                    return
                } else {
                    consecutiveFailures += 1
                    await suggestOtherAddressIfDue(consecutiveFailures: consecutiveFailures)
                    guard !Task.isCancelled else { break }
                    let msg = Self.describeConnectionError(error, baseURLString: baseURLString, isGeneralNetworkSatisfied: networkSatisfied)
                    logger.error("WebSocket disconnected: \(msg, privacy: .public)")
                    publishStaleRetainedDevices()
                    emitEvent?(.statusChanged(.disconnected(msg)))
                }
                let localEndpoint = AssistantEndpoint(baseURLString)?.isLocalNetwork == true
                try? await reconnectSleep(backoff.next(localEndpoint: localEndpoint))
            }
        }
    }

    private static func provesPacketCrossedPermissionBoundary(_ error: any Error) -> Bool {
        if let providerError = error as? HomeProviderError {
            switch providerError {
            case .unauthorized, .networkError, .serviceCallFailed:
                return true
            case .invalidURL, .backendNotConfigured:
                return false
            }
        }
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let nsError = current else { break }
            if nsError.domain == NSURLErrorDomain,
               nsError.code == URLError.badServerResponse.rawValue || nsError.code == URLError.userAuthenticationRequired.rawValue {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ECONNREFUSED) {
                return true
            }
            if let sd = (nsError.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue,
               let sc = (nsError.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue,
               sd == 1, sc == Int(ECONNREFUSED) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func updateLocalNetworkDenied(_ denied: Bool) {
        guard isLocalNetworkDenied != denied else { return }
        isLocalNetworkDenied = denied
        emitEvent?(.localNetworkPermissionChanged(denied ? [.homeAssistant] : []))
    }

    /// After two failures in a row, looks for Home Assistant elsewhere on the network at most every
    /// `HAAddressPolicy.rediscoveryInterval`, and only reports what it finds (#18).
    private func suggestOtherAddressIfDue(consecutiveFailures: Int, now: Date = Date()) async {
        guard let onAddressSuggestion, consecutiveFailures >= 2 else { return }
        if let last = lastRediscoveryAt, now.timeIntervalSince(last) < HAAddressPolicy.rediscoveryInterval { return }
        lastRediscoveryAt = now
        let current = baseURLString
        guard let candidate = await rediscover(current).first(where: { Self.normalizeBaseURL($0.baseURL) != current }),
              !Task.isCancelled else { return }
        logger.info("Found another Home Assistant address; asking the user before switching: \(candidate.baseURL, privacy: .public)")
        onAddressSuggestion(candidate)
    }

    private func connectAndListen(onAuthenticated: () -> Void = {}) async throws {
        guard !isShutDown else { return }
        guard let wsURL = Self.makeWebSocketURL(from: baseURLString) else {
            throw HomeProviderError.invalidURL(baseURLString)
        }
        let currentSession: URLSession?
        let ws: any HAWebSocketConnection
        if let webSocketFactoryOverride {
            currentSession = nil
            ws = webSocketFactoryOverride(wsURL)
        } else {
            guard let createdSession = replaceSession() else { return }
            currentSession = createdSession
            let task = createdSession.webSocketTask(with: wsURL)
            task.maximumMessageSize = 16 * 1024 * 1024
            ws = URLSessionHAWebSocketConnection(task: task)
        }
        self.handshakingWebSocket = ws
        ws.resume()

        defer {
            ws.cancel()
            if handshakingWebSocket === ws {
                handshakingWebSocket = nil
            }
            if activeWebSocket === ws {
                activeWebSocket = nil
                coalesceTask?.cancel()
                coalesceTask = nil
                hasPendingCoalescedSynthesis = false
                stopPingLoop()
                receiveTask?.cancel()
                receiveTask = nil
                failPendingStartupReplies(with: CancellationError())
                failPendingStreamRequests()
            }
            if let currentSession {
                invalidateSession(ifMatching: currentSession)
            }
        }

        try await authenticate(ws: ws)
        try Task.checkCancellation()
        handshakingWebSocket = nil
        activeWebSocket = ws
        onAuthenticated()
        snapshot.resetForReconnect()
        lastEmittedHome = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        hasPendingCoalescedSynthesis = false
        lastLiveSynthesisAt = nil
        nextWebSocketMessageId = 5
        pendingRefreshStateIds.removeAll()
        resetStartupReplyState()
        logger.info("Connected to Home Assistant WebSocket: \(self.baseURLString, privacy: .public)")

        updateLocalNetworkDenied(false)
        emitEvent?(.statusChanged(.connected))

        if pollingContext.systemActive, !pollingContext.haTransportSuspended {
            startPingLoop(ws: ws)
        }

        let startedReceiveTask = Task { [weak self] () throws in
            guard let self else { return }
            try await self.runReceiveLoop(ws: ws)
        }
        self.receiveTask = startedReceiveTask

        try await fetchInitialRegistries(ws: ws)

        try await startedReceiveTask.value
    }

    private func authenticate(ws: any HAWebSocketConnection) async throws {
        let watchdog = Task { [transportSleep] in
            do {
                try await transportSleep(.seconds(10))
                try Task.checkCancellation()
                guard handshakingWebSocket === ws else { return false }
                ws.cancel()
                return true
            } catch {
                return false
            }
        }
        defer { watchdog.cancel() }
        do {
            let greeting = try await receiveJSON(ws: ws)
            try Task.checkCancellation()
            try Self.validateAuthGreeting(greeting)
            try await sendJSON(ws: ws, ["type": "auth", "access_token": token])
            let response = try await receiveJSON(ws: ws)
            try Task.checkCancellation()
            try Self.validateAuthResponse(response)
        } catch {
            watchdog.cancel()
            if await watchdog.value { throw URLError(.timedOut) }
            throw error
        }
    }

    static func validateAuthGreeting(_ message: [String: JSONValue]) throws {
        switch message["type"]?.stringValue {
        case "auth_required":
            return
        case "auth_invalid":
            throw HomeProviderError.unauthorized
        default:
            throw HomeProviderError.networkError("Unexpected WebSocket greeting")
        }
    }

    static func validateAuthResponse(_ message: [String: JSONValue]) throws {
        switch message["type"]?.stringValue {
        case "auth_ok":
            return
        case "auth_invalid":
            throw HomeProviderError.unauthorized
        default:
            throw HomeProviderError.networkError("Unexpected WebSocket auth response")
        }
    }

    private func runReceiveLoop(ws: any HAWebSocketConnection) async throws {
        do {
            while !Task.isCancelled {
                let msg = try await receiveJSON(ws: ws)
                try Task.checkCancellation()
                if msg["type"]?.stringValue == "pong" {
                    if let id = msg["id"]?.intValue { handlePong(ws: ws, id: id) }
                    continue
                } else if msg["type"]?.stringValue == "result",
                   let id = msg["id"]?.intValue {
                    if let waiter = pendingStreamRequests.removeValue(forKey: id) {
                        waiter.resume(returning: msg["result"]?["url"]?.stringValue)
                        continue
                    }
                    let initialCapturedEpoch = initialPollCapturedEpochs.removeValue(forKey: id)
                    let isInitialStates = id == legacyInitialStatesID
                    let isStartup = (1...Self.compressedSubscriptionID).contains(id)
                        || isInitialStates || id == legacySubscriptionID
                    if isStartup {
                        deliverStartupReply(id: id, message: msg)
                    }
                    let refreshCapturedEpoch = pendingRefreshStateIds.removeValue(forKey: id)
                    let isRefresh = refreshCapturedEpoch != nil
                    if !isRefresh && !isInitialStates && !(1...3).contains(id) {
                        if !isStartup {
                            logger.debug("Ignoring Home Assistant result id \(id, privacy: .public) with no open request")
                        }
                        continue
                    }
                    if let home = try snapshot.receive(
                        msg, isInitialStatesResult: isInitialStates,
                        isRefreshStatesResult: isRefresh,
                        typePrunePolicy: typePrunePolicyLoader(),
                        pollCapturedEpoch: initialCapturedEpoch ?? refreshCapturedEpoch
                    ) {
                        coalesceTask?.cancel()
                        coalesceTask = nil
                        hasPendingCoalescedSynthesis = false
                        lastLiveSynthesisAt = ContinuousClock.now
                        publish(home, force: isRefresh || lastEmittedHome == nil)
                    }
                } else if msg["type"]?.stringValue == "event" {
                    let policy = typePrunePolicyLoader()
                    let shouldSynthesize: Bool
                    if msg["id"]?.intValue == Self.compressedSubscriptionID, legacyInitialStatesID == nil {
                        shouldSynthesize = try snapshot.ingestCompressedStates(msg["event"], typePrunePolicy: policy)
                    } else if let legacySubscriptionID, msg["id"]?.intValue == legacySubscriptionID {
                        shouldSynthesize = snapshot.ingestStateChangedEvent(msg, typePrunePolicy: policy, capturedEpoch: .now)
                    } else {
                        continue
                    }
                    for ring in snapshot.takeDoorbellRings() {
                        emitEvent?(.doorbellRang(ring))
                    }
                    if shouldSynthesize {
                        scheduleOrRunLiveSynthesis()
                    }
                    continue
                } else if let home = try snapshot.receive(msg, typePrunePolicy: typePrunePolicyLoader()) {
                    publish(home)
                }
                for ring in snapshot.takeDoorbellRings() {
                    emitEvent?(.doorbellRang(ring))
                }
            }
        } catch {
            if activeWebSocket === ws { failPendingStartupReplies(with: error) }
            throw error
        }
    }

    private var effectiveCoalesceWindow: Duration {
        if let liveEventCoalesceWindowOverride {
            return liveEventCoalesceWindowOverride
        }
        if webSocketFactoryOverride != nil {
            return .zero
        }
        return pollingContext.panelVisible ? .milliseconds(100) : .milliseconds(500)
    }

    private func scheduleOrRunLiveSynthesis() {
        let window = effectiveCoalesceWindow
        let now = ContinuousClock.now
        if window <= .zero || lastLiveSynthesisAt == nil || (now - lastLiveSynthesisAt!) >= window {
            flushPendingCoalescedSynthesis(now: now)
            return
        }
        hasPendingCoalescedSynthesis = true
        guard coalesceTask == nil else { return }
        let elapsed = now - lastLiveSynthesisAt!
        let remaining = max(.milliseconds(1), window - elapsed)
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            await self?.flushPendingCoalescedSynthesis()
        }
    }

    private func flushPendingCoalescedSynthesis(now: ContinuousClock.Instant = ContinuousClock.now) {
        coalesceTask?.cancel()
        coalesceTask = nil
        hasPendingCoalescedSynthesis = false
        lastLiveSynthesisAt = now
        if let home = snapshot.synthesizeCurrent(typePrunePolicy: typePrunePolicyLoader()) {
            publish(home, force: false)
        }
    }

    private func publish(_ home: SynthesizedHome, force: Bool = false) {
        var home = home
        if home.homeAssistantScope == nil {
            home.homeAssistantScope = ConnectionRemovalStore.haScope(serverURL: baseURLString)
        }
        let report = snapshot.takeTypePruneReport()
        if let report {
            emitEvent?(.haTypePruneChanged(report))
        }
        if !force, report == nil, home == lastEmittedHome {
            return
        }
        lastEmittedHome = home
        emitEvent?(.snapshotUpdated(home))
    }

    /// A lost connection stops feeding the type-retained devices, so their last reading must not keep
    /// raising alerts while Home Assistant is away (P3b-M).
    private func publishStaleRetainedDevices() {
        if let report = snapshot.staleTypePruneReport() {
            emitEvent?(.haTypePruneChanged(report))
        }
    }

    private func fetchInitialRegistries(ws: any HAWebSocketConnection) async throws {
        try await sendJSON(ws: ws, ["id": 1, "type": "config/area_registry/list"])
        try await sendJSON(ws: ws, ["id": 2, "type": "config/device_registry/list"])
        try await sendJSON(ws: ws, ["id": 3, "type": "config/entity_registry/list"])
        try await sendJSON(ws: ws, ["id": Self.compressedSubscriptionID, "type": "subscribe_entities"])
        let subscription = try await awaitStartupReply(id: Self.compressedSubscriptionID)
        var replyIDs = [1, 2, 3]
        if subscription["success"]?.boolValue == false {
            // A refresh or heartbeat can use the socket while the probe is in flight.
            let statesID = allocateWebSocketMessageId()
            legacyInitialStatesID = statesID
            initialPollCapturedEpochs[statesID] = .now
            try await sendJSON(ws: ws, ["id": statesID, "type": "get_states"])
            let subscriptionID = allocateWebSocketMessageId()
            legacySubscriptionID = subscriptionID
            try await sendJSON(ws: ws, [
                "id": subscriptionID,
                "type": "subscribe_events",
                "event_type": "state_changed"
            ])
            replyIDs += [statesID, subscriptionID]
        }
        _ = try await collectInitialRegistryReplies(ids: replyIDs)
    }

    func collectInitialRegistryReplies(ids: [Int]) async throws -> [[String: JSONValue]] {
        var replies: [[String: JSONValue]] = []
        for id in ids {
            replies.append(try await awaitStartupReply(id: id))
        }
        return replies
    }

    func resetStartupReplyState() {
        legacyInitialStatesID = nil
        legacySubscriptionID = nil
        startupReplies.removeAll()
        startupFailure = nil
        failPendingStartupReplies(with: CancellationError())
        startupFailure = nil
    }

    func deliverStartupReply(id: Int, message: [String: JSONValue]) {
        let isUnsupported = id == Self.compressedSubscriptionID
            && message["success"]?.boolValue == false
            && message["error"]?["code"]?.stringValue == "unknown_command"
        guard message["success"]?.boolValue == true || isUnsupported else {
            failPendingStartupReplies(with: HAHomeSnapshot.ReadError.rejected)
            return
        }
        if let (_, waiter) = startupWaiters.removeValue(forKey: id) {
            waiter.resume(returning: message)
        } else {
            startupReplies[id] = message
        }
    }

    private func awaitStartupReply(id: Int) async throws -> [String: JSONValue] {
        if let failure = startupFailure {
            throw failure
        }
        if let buffered = startupReplies.removeValue(forKey: id) {
            return buffered
        }
        let request = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                startupWaiters[id] = (request, continuation)
            }
        } onCancel: {
            Task { await self.cancelStartupWaiter(id: id, request: request) }
        }
    }

    private func cancelStartupWaiter(id: Int, request: UUID) {
        guard startupWaiters[id]?.0 == request else { return }
        startupWaiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }

    private func failPendingStartupReplies(with error: Error) {
        if startupFailure == nil {
            startupFailure = error
        }
        let waiters = startupWaiters.values
        startupWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Command Execution via REST Service Endpoint

    public func execute(_ command: DeviceCommand) async throws {
        switch command {
        case .setMiotProperty, .callMiotAction:
            throw HomeProviderError.serviceCallFailed(
                400,
                L10n.tr("该控件需要米家云端连接", "This control needs the Xiaomi cloud backend")
            )
        default:
            break
        }
        guard allowsToken(baseURLString) else {
            throw HomeProviderError.networkError(HAPlaintextConsent.waitingMessage(baseURLString))
        }
        let (domain, service, payload) = Self.mapCommandToService(command)
        if let entityId = payload["entity_id"] as? String,
           let category = snapshot.closedCategory(for: entityId, policy: typePrunePolicyLoader()) {
            throw CapabilityControlBlockedError(reason: .categoryDisabled(category))
        }
        guard let url = URL(string: "\(baseURLString)/api/services/\(domain)/\(service)") else {
            throw HomeProviderError.invalidURL(baseURLString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        guard let activeSession = ensureSession() else {
            throw HomeProviderError.networkError(L10n.tr("连接已关闭", "Connection is closed"))
        }
        let (data, response) = try await activeSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HomeProviderError.networkError(L10n.tr("无 HTTP 响应", "No HTTP response"))
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw HomeProviderError.serviceCallFailed(http.statusCode, bodyText)
        }
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        guard !isShutDown else {
            throw HomeProviderError.networkError(L10n.tr("连接已关闭", "Connection is closed"))
        }
        guard case .camera(let spec) = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("非摄像头设备", "Not a camera device"))
        }
        if let streamEntityId = spec.streamEntityId,
           let ws = activeWebSocket {
            let reqId = allocateWebSocketMessageId()
            let timeoutTask = Task { [weak self] in
                await self?.expireStreamRequest(id: reqId)
            }
            let urlPath: String? = await withCheckedContinuation { cont in
                pendingStreamRequests[reqId] = cont
                Task { [weak self] in
                    do {
                        try await self?.sendJSON(ws: ws, [
                            "id": reqId,
                            "type": "camera/stream",
                            "entity_id": streamEntityId,
                            "format": "hls"
                        ])
                    } catch {
                        await self?.completeStreamRequest(id: reqId, urlPath: nil)
                    }
                }
            }
            timeoutTask.cancel()
            if let urlPath, !urlPath.isEmpty,
               let hlsURL = Self.resolveStreamURL(pathOrURL: urlPath, baseURLString: baseURLString) {
                return .hls(hlsURL)
            }
        }
        if let snapshotPath = spec.snapshotPath, !snapshotPath.isEmpty {
            // HA serves every camera entity as MJPEG, including ones without the `stream`
            // integration or HLS support, so prefer real motion over ~1 fps snapshot polling.
            if let mjpegPath = Self.mjpegProxyPath(fromSnapshotPath: snapshotPath),
               let mjpegURL = Self.resolveStreamURL(pathOrURL: mjpegPath, baseURLString: baseURLString) {
                return .mjpeg(mjpegURL)
            }
            if let snapURL = Self.resolveStreamURL(pathOrURL: snapshotPath, baseURLString: baseURLString) {
                return .snapshot(snapURL)
            }
        }
        throw HomeProviderError.serviceCallFailed(
            404,
            L10n.tr(
                "Home Assistant 没有为这台摄像头提供画面（米家集成只提供开关，没有摄像头实体）。登录米家账号即可在本应用直接观看，或在下方填写 go2rtc / HLS 流地址",
                "Home Assistant has no video for this camera (the Xiaomi Home integration only adds switches, no camera entity). Sign in to Mi Home to watch it here, or enter a go2rtc / HLS stream URL below"
            )
        )
    }

    /// Maps HA's snapshot proxy (`/api/camera_proxy/<entity>?token=…`) to its MJPEG twin
    /// (`/api/camera_proxy_stream/<entity>?token=…`). The access token query is kept as-is.
    public static func mjpegProxyPath(fromSnapshotPath path: String) -> String? {
        let marker = "/api/camera_proxy/"
        guard let range = path.range(of: marker) else { return nil }
        return path.replacingCharacters(in: range, with: "/api/camera_proxy_stream/")
    }

    private func expireStreamRequest(id: Int) async {
        await streamRequestTimeout()
        completeStreamRequest(id: id, urlPath: nil)
    }

    private func completeStreamRequest(id: Int, urlPath: String?) {
        if let waiter = pendingStreamRequests.removeValue(forKey: id) {
            waiter.resume(returning: urlPath)
        }
    }

    public static func resolveStreamURL(pathOrURL: String, baseURLString: String) -> URL? {
        let trimmed = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let base = normalizeBaseURL(baseURLString)
        let slash = trimmed.hasPrefix("/") ? "" : "/"
        return URL(string: "\(base)\(slash)\(trimmed)")
    }

    public static func mapCommandToService(_ command: DeviceCommand) -> (domain: String, service: String, payload: [String: Any]) {
        switch command {
        case .setLightPower(let eid, let isOn):
            return ("light", isOn ? "turn_on" : "turn_off", ["entity_id": eid])

        case .setLightBrightness(let eid, let pct):
            return ("light", "turn_on", [
                "entity_id": eid,
                "brightness_pct": max(1, min(100, pct))
            ])

        case .setLightColorTemp(let eid, let kelvin):
            return ("light", "turn_on", [
                "entity_id": eid,
                "color_temp_kelvin": kelvin
            ])

        case .setLightEffect(let eid, let effect):
            return ("light", "turn_on", [
                "entity_id": eid,
                "effect": effect
            ])

        case .setClimatePower(let eid, let isOn, let fallbackMode):
            if isOn {
                return ("climate", "set_hvac_mode", [
                    "entity_id": eid,
                    "hvac_mode": fallbackMode == "off" ? "cool" : fallbackMode
                ])
            } else {
                return ("climate", "turn_off", ["entity_id": eid])
            }

        case .setClimateMode(let eid, let mode):
            return ("climate", "set_hvac_mode", [
                "entity_id": eid,
                "hvac_mode": mode
            ])

        case .setClimateTemperature(let eid, let temp):
            if eid.hasPrefix("water_heater.") {
                return ("water_heater", "set_temperature", [
                    "entity_id": eid,
                    "temperature": temp
                ])
            }
            return ("climate", "set_temperature", [
                "entity_id": eid,
                "temperature": temp
            ])

        case .setClimateFanMode(let eid, let fanMode):
            return ("climate", "set_fan_mode", [
                "entity_id": eid,
                "fan_mode": fanMode
            ])

        case .setClimateSwingMode(let eid, let swingMode):
            return ("climate", "set_swing_mode", [
                "entity_id": eid,
                "swing_mode": swingMode
            ])

        case .setFanPower(let eid, let isOn):
            return ("fan", isOn ? "turn_on" : "turn_off", ["entity_id": eid])

        case .setFanPercentage(let eid, let percent):
            return ("fan", "set_percentage", [
                "entity_id": eid,
                "percentage": max(0, min(100, percent))
            ])

        case .setFanPresetMode(let eid, let preset):
            return ("fan", "set_preset_mode", [
                "entity_id": eid,
                "preset_mode": preset
            ])

        case .setFanOscillating(let eid, let oscillating):
            return ("fan", "oscillate", [
                "entity_id": eid,
                "oscillating": oscillating
            ])

        case .setSwitch(let eid, let isOn):
            let primaryEid = eid.split(separator: "|").first.map(String.init) ?? eid
            if primaryEid.hasSuffix("#motion") {
                let camEid = String(primaryEid.dropLast("#motion".count))
                return ("camera", isOn ? "enable_motion_detection" : "disable_motion_detection", ["entity_id": camEid])
            }
            if primaryEid.hasPrefix("camera.") {
                return ("camera", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("media_player.") {
                return ("media_player", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("button.") {
                return ("button", "press", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("valve.") {
                return ("valve", isOn ? "open_valve" : "close_valve", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("humidifier.") {
                return ("humidifier", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("water_heater.") {
                return ("water_heater", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])
            }
            if primaryEid.hasPrefix("fan.") {
                return ("fan", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])
            }
            return ("switch", isOn ? "turn_on" : "turn_off", ["entity_id": primaryEid])

        case .setSelectOption(let eid, let option):
            let selectEid = eid.split(separator: "|").last.map(String.init) ?? eid
            if selectEid.hasPrefix("cover.") {
                let service: String
                switch option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "open", "打开":
                    service = "open_cover"
                case "close", "关闭":
                    service = "close_cover"
                case "pause", "stop", "暂停":
                    service = "stop_cover"
                default:
                    service = "stop_cover"
                }
                return ("cover", service, ["entity_id": selectEid])
            }
            if selectEid.hasPrefix("humidifier.") {
                return ("humidifier", "set_mode", [
                    "entity_id": selectEid,
                    "mode": option
                ])
            }
            if selectEid.hasPrefix("water_heater.") {
                return ("water_heater", "set_operation_mode", [
                    "entity_id": selectEid,
                    "operation_mode": option
                ])
            }
            return ("select", "select_option", [
                "entity_id": selectEid,
                "option": option
            ])

        case .setHumidity(let eid, let percent):
            return ("humidifier", "set_humidity", [
                "entity_id": eid,
                "humidity": max(0, min(100, percent))
            ])

        case .setNumberValue(let eid, let value):
            if eid.hasPrefix("cover.") {
                return ("cover", "set_cover_position", [
                    "entity_id": eid,
                    "position": MiotPercentScale.clampPercent(value)
                ])
            }
            return ("number", "set_value", [
                "entity_id": eid,
                "value": value
            ])

        case .vacuumAction(let eid, let action):
            return ("vacuum", action.rawValue, ["entity_id": eid])

        case .mediaSetVolume(let eid, let level):
            return ("media_player", "volume_set", [
                "entity_id": eid,
                "volume_level": max(0.0, min(1.0, level))
            ])

        case .mediaSelectSource(let eid, let source):
            return ("media_player", "select_source", [
                "entity_id": eid,
                "source": source
            ])

        case .pressButton(let eid):
            return ("button", "press", ["entity_id": eid])

        case .sendNotifyMessage(let eid, let message):
            return ("notify", "send_message", [
                "entity_id": eid,
                "message": message
            ])

        case .activateScene(let eid):
            if eid.hasPrefix("button.") {
                return ("button", "press", ["entity_id": eid])
            }
            let domain = eid.hasPrefix("script.") ? "script" : "scene"
            return (domain, "turn_on", ["entity_id": eid])

        case .setMiotProperty(let eid, _, _), .callMiotAction(let eid, _):
            // `execute` rejects these before reaching here; only the Xiaomi cloud understands MIoT.
            return ("miot", "unsupported", ["entity_id": eid])
        }
    }

    // MARK: - Helpers

    private func sendJSON(ws: any HAWebSocketConnection, _ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await ws.send(str)
    }

    private func receiveJSON(ws: any HAWebSocketConnection) async throws -> [String: JSONValue] {
        let data = try await ws.receive()
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    public static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if lower.hasPrefix("https://") {
            s = "https://" + s.dropFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            s = "http://" + s.dropFirst("http://".count)
        } else {
            s = "http://\(s)"
        }
        return s
    }

    /// Normalizes scheme and host case-insensitively while preserving case-sensitive reverse-proxy URL paths.
    public static func canonicalHistoryScopeURL(_ raw: String) -> String {
        let base = normalizeBaseURL(raw)
        if var components = URLComponents(string: base) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if var formatted = components.string {
                while formatted.hasSuffix("/") { formatted.removeLast() }
                return formatted
            }
        }
        guard let schemeRange = base.range(of: "://") else { return base.lowercased() }
        let afterScheme = base[schemeRange.upperBound...]
        if let slashIndex = afterScheme.firstIndex(of: "/") {
            let authority = base[..<slashIndex].lowercased()
            let path = base[slashIndex...]
            return authority + path
        }
        return base.lowercased()
    }

    private static func makeWebSocketURL(from baseURL: String) -> URL? {
        var wsStr = baseURL
        if wsStr.hasPrefix("https://") {
            wsStr = "wss://" + wsStr.dropFirst("https://".count)
        } else if wsStr.hasPrefix("http://") {
            wsStr = "ws://" + wsStr.dropFirst("http://".count)
        }
        return URL(string: "\(wsStr)/api/websocket")
    }

    public static func describeConnectionError(
        _ error: Error, baseURLString: String, isGeneralNetworkSatisfied: Bool = true
    ) -> String {
        let host = URL(string: normalizeBaseURL(baseURLString))?.host?.lowercased()
        if LocalNetworkPermissionClassifier.isDeniedConnectionError(
            error,
            targetHost: host,
            isGeneralNetworkSatisfied: isGeneralNetworkSatisfied
        ) {
            return L10n.tr(
                "局域网连接被系统拦截（请检查「系统设置 → 隐私与安全性 → 本地网络」中的 MenuBarHome 权限，或重新安装对齐本地应用签名）",
                "Local network connection blocked by macOS (check System Settings → Privacy & Security → Local Network for MenuBarHome)"
            )
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
