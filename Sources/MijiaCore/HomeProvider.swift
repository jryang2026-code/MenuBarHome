import Foundation
import os

public enum HomeBackend: String, CaseIterable, Identifiable, Sendable {
    case homeAssistant = "homeAssistant"
    case xiaomiCloud = "xiaomiCloud"
    /// A built-in virtual home that works without an account and never touches the network (#47).
    case demo = "demo"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .homeAssistant: return "Home Assistant"
        case .xiaomiCloud: return L10n.tr("米家云端直连", "Xiaomi Cloud Direct")
        case .demo: return L10n.tr("演示模式", "Demo Mode")
        }
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
    /// The cloud rejected the session; the store persists it as the session's end (#181).
    case sessionExpired(MiSession)
    /// A Home Assistant doorbell was pressed (#308).
    case doorbellRang(DoorbellRing)
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

public protocol HomeProvider: Sendable {
    func events() -> AsyncStream<HomeProviderEvent>
    func execute(_ command: DeviceCommand) async throws
    func refreshNow() async
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

public actor HAWebSocketProvider: HomeProvider {
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "HAWebSocket")
    private var baseURLString: String
    private var token: String
    private var session: URLSession?
    private var isShutDown = false

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Error>?
    private var activeWebSocket: URLSessionWebSocketTask?
    private var nextWebSocketMessageId: Int = 5
    private var pendingRefreshStateIds: Set<Int> = []
    private var pendingStreamRequests: [Int: CheckedContinuation<String?, Never>] = [:]
    private var startupReplies: [Int: [String: JSONValue]] = [:]
    private var startupWaiters: [Int: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var startupFailure: Error?

    var hasActiveSessionForTesting: Bool { session != nil }
    var isShutDownForTesting: Bool { isShutDown }
    private(set) var createdSessionCountForTesting: Int = 0
    private(set) var invalidatedSessionCountForTesting: Int = 0

    func prepareSessionForTesting() {
        _ = replaceSession()
    }

    private var snapshot = HAHomeSnapshot()
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

    public init(
        baseURLString: String,
        token: String,
        onAddressSuggestion: (@Sendable (HADiscoveredInstance) -> Void)? = nil,
        rediscover: @escaping @Sendable (String) async -> [HADiscoveredInstance] = { await HADiscovery.discoverOnLAN(currentURLHint: $0) },
        allowsToken: @escaping @Sendable (String) -> Bool = { HAPlaintextConsent.allowsToken(to: $0, defaults: .standard) },
        onPlaintextConsentNeeded: (@Sendable (String) -> Void)? = nil
    ) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        self.onAddressSuggestion = onAddressSuggestion
        self.rediscover = rediscover
        self.allowsToken = allowsToken
        self.onPlaintextConsentNeeded = onPlaintextConsentNeeded
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

    public func updateCredentials(baseURLString: String, token: String) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        guard !isShutDown else { return }
        restartLoop()
    }

    public func shutdown() async {
        isShutDown = true
        loopTask?.cancel()
        loopTask = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
        activeWebSocket = nil
        failPendingStartupReplies(with: CancellationError())
        failPendingStreamRequests()
        invalidateSession()
        continuation?.finish()
        continuation = nil
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

    private func sendWebSocketPing(ws: URLSessionWebSocketTask) async {
        guard activeWebSocket === ws else { return }
        let pingId = allocateWebSocketMessageId()
        try? await sendJSON(ws: ws, ["id": pingId, "type": "ping"])
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task {
                await self.attachContinuation(continuation)
            }
        }
    }

    private func attachContinuation(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        self.continuation = cont
        restartLoop()
    }

    public func refreshNow() async {
        if let ws = activeWebSocket {
            let id = allocateWebSocketMessageId()
            pendingRefreshStateIds.insert(id)
            do {
                try await sendJSON(ws: ws, ["id": id, "type": "get_states"])
            } catch {
                pendingRefreshStateIds.remove(id)
            }
        } else {
            restartLoop()
        }
    }

    private func restartLoop() {
        guard !isShutDown else { return }
        loopTask?.cancel()
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
        activeWebSocket = nil
        failPendingStartupReplies(with: CancellationError())
        invalidateSession()

        loopTask = Task {
            await runConnectionLoop()
        }
    }

    private func runConnectionLoop() async {
        var backoffSeconds: Double = 0.8
        var consecutiveFailures = 0
        while !Task.isCancelled {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continuation?.yield(.statusChanged(.disconnected(L10n.tr("请在设置中配置访问令牌", "Configure your access token in Settings"))))
                return
            }
            guard allowsToken(baseURLString) else {
                onPlaintextConsentNeeded?(baseURLString)
                continuation?.yield(.statusChanged(.disconnected(HAPlaintextConsent.waitingMessage(baseURLString))))
                return
            }
            continuation?.yield(.statusChanged(.connecting))
            do {
                try await connectAndListen()
                backoffSeconds = 0.8
                consecutiveFailures = 0
            } catch {
                if Task.isCancelled { break }
                if case HomeProviderError.unauthorized = error {
                    let msg = Self.describeConnectionError(error, baseURLString: baseURLString)
                    logger.error("WebSocket unauthorized: \(msg, privacy: .public)")
                    continuation?.yield(.statusChanged(.disconnected(msg)))
                } else {
                    consecutiveFailures += 1
                    await suggestOtherAddressIfDue(consecutiveFailures: consecutiveFailures)
                    let msg = Self.describeConnectionError(error, baseURLString: baseURLString)
                    logger.error("WebSocket disconnected: \(msg, privacy: .public)")
                    continuation?.yield(.statusChanged(.disconnected(msg)))
                }
                try? await Task.sleep(for: .seconds(backoffSeconds))
                backoffSeconds = min(backoffSeconds * 1.8, 10.0)
            }
        }
    }

    /// After two failures in a row, looks for Home Assistant elsewhere on the network at most every
    /// `HAAddressPolicy.rediscoveryInterval`, and only reports what it finds (#18).
    private func suggestOtherAddressIfDue(consecutiveFailures: Int, now: Date = Date()) async {
        guard let onAddressSuggestion, consecutiveFailures >= 2 else { return }
        if let last = lastRediscoveryAt, now.timeIntervalSince(last) < HAAddressPolicy.rediscoveryInterval { return }
        lastRediscoveryAt = now
        let current = baseURLString
        guard let candidate = await rediscover(current).first(where: { Self.normalizeBaseURL($0.baseURL) != current }) else { return }
        logger.info("Found another Home Assistant address; asking the user before switching: \(candidate.baseURL, privacy: .public)")
        onAddressSuggestion(candidate)
    }

    private func connectAndListen() async throws {
        guard !isShutDown else { return }
        guard let wsURL = Self.makeWebSocketURL(from: baseURLString) else {
            throw HomeProviderError.invalidURL(baseURLString)
        }
        guard let currentSession = replaceSession() else { return }

        let ws = currentSession.webSocketTask(with: wsURL)
        ws.maximumMessageSize = 16 * 1024 * 1024
        self.activeWebSocket = ws
        ws.resume()

        var localPingTask: Task<Void, Never>?
        var localReceiveTask: Task<Void, Error>?
        defer {
            localPingTask?.cancel()
            localReceiveTask?.cancel()
            if let localPingTask, self.pingTask == localPingTask {
                self.pingTask = nil
            }
            if let localReceiveTask, self.receiveTask == localReceiveTask {
                self.receiveTask = nil
            }
            ws.cancel(with: .goingAway, reason: nil)
            if self.activeWebSocket === ws {
                self.activeWebSocket = nil
            }
            failPendingStartupReplies(with: CancellationError())
            failPendingStreamRequests()
            invalidateSession(ifMatching: currentSession)
        }

        // 1. Expect auth_required
        _ = try await receiveJSON(ws: ws)

        // 2. Send auth
        try await sendJSON(ws: ws, [
            "type": "auth",
            "access_token": token
        ])

        let authResp = try await receiveJSON(ws: ws)
        let authType = authResp["type"]?.stringValue ?? ""
        if authType != "auth_ok" {
            ws.cancel(with: .goingAway, reason: nil)
            throw HomeProviderError.unauthorized
        }

        snapshot = HAHomeSnapshot()
        nextWebSocketMessageId = 5
        pendingRefreshStateIds.removeAll()
        resetStartupReplyState()
        logger.info("Connected to Home Assistant WebSocket: \(self.baseURLString, privacy: .public)")

        continuation?.yield(.statusChanged(.connected))

        // 3. Periodic 25-second ping task to keep connection alive forever
        let startedPingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }
                await self?.sendWebSocketPing(ws: ws)
            }
        }
        localPingTask = startedPingTask
        self.pingTask = startedPingTask

        // 4. Start receive loop before pipelined sends so early startup replies are never missed.
        let startedReceiveTask = Task { [weak self] () throws in
            guard let self else { return }
            try await self.runReceiveLoop(ws: ws)
        }
        localReceiveTask = startedReceiveTask
        self.receiveTask = startedReceiveTask

        // 5. Request registries, initial states, and state_changed subscription sequentially
        //    on the socket, then collect all 5 replies concurrently via `async let`.
        try await fetchInitialRegistries(ws: ws)

        // 6. Keep listening for state_changed events and stream responses until disconnect.
        try await startedReceiveTask.value
    }

    private func runReceiveLoop(ws: URLSessionWebSocketTask) async throws {
        do {
            while !Task.isCancelled {
                let msg = try await receiveJSON(ws: ws)
                if msg["type"]?.stringValue == "result",
                   let id = msg["id"]?.intValue {
                    if let waiter = pendingStreamRequests.removeValue(forKey: id) {
                        waiter.resume(returning: msg["result"]?["url"]?.stringValue)
                        continue
                    }
                    if (1...5).contains(id) {
                        deliverStartupReply(id: id, message: msg)
                    }
                    let isRefresh = pendingRefreshStateIds.remove(id) != nil
                    if let home = try snapshot.receive(msg, isRefreshStatesResult: isRefresh) {
                        continuation?.yield(.snapshotUpdated(home))
                    }
                } else if let home = try snapshot.receive(msg) {
                    continuation?.yield(.snapshotUpdated(home))
                }
                for ring in snapshot.takeDoorbellRings() {
                    continuation?.yield(.doorbellRang(ring))
                }
            }
        } catch {
            failPendingStartupReplies(with: error)
            throw error
        }
    }

    func fetchInitialRegistries(ws: URLSessionWebSocketTask) async throws {
        try await sendJSON(ws: ws, ["id": 1, "type": "config/area_registry/list"])
        try await sendJSON(ws: ws, ["id": 2, "type": "config/device_registry/list"])
        try await sendJSON(ws: ws, ["id": 3, "type": "config/entity_registry/list"])
        try await sendJSON(ws: ws, ["id": 4, "type": "get_states"])
        try await sendJSON(ws: ws, [
            "id": 5,
            "type": "subscribe_events",
            "event_type": "state_changed"
        ])
        _ = try await collectInitialRegistryReplies()
    }

    func collectInitialRegistryReplies() async throws -> [[String: JSONValue]] {
        async let areasReply = awaitStartupReply(id: 1)
        async let devicesReply = awaitStartupReply(id: 2)
        async let entitiesReply = awaitStartupReply(id: 3)
        async let statesReply = awaitStartupReply(id: 4)
        async let subscribeReply = awaitStartupReply(id: 5)
        let r1 = try await areasReply
        let r2 = try await devicesReply
        let r3 = try await entitiesReply
        let r4 = try await statesReply
        let r5 = try await subscribeReply
        return [r1, r2, r3, r4, r5]
    }

    func resetStartupReplyState() {
        startupReplies.removeAll()
        startupFailure = nil
        failPendingStartupReplies(with: CancellationError())
        startupFailure = nil
    }

    func deliverStartupReply(id: Int, message: [String: JSONValue]) {
        guard message["success"]?.boolValue == true else {
            failPendingStartupReplies(with: HAHomeSnapshot.ReadError.rejected)
            return
        }
        if let waiter = startupWaiters.removeValue(forKey: id) {
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let failure = self.startupFailure {
                    continuation.resume(throwing: failure)
                } else if let buffered = self.startupReplies.removeValue(forKey: id) {
                    continuation.resume(returning: buffered)
                } else {
                    self.startupWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelStartupWaiter(id: id) }
        }
    }

    private func cancelStartupWaiter(id: Int) {
        if let waiter = startupWaiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func failPendingStartupReplies(with error: Error) {
        if startupFailure == nil {
            startupFailure = error
        }
        let waiters = startupWaiters.values
        startupWaiters.removeAll()
        for waiter in waiters {
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
            throw HomeProviderError.networkError("无 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw HomeProviderError.serviceCallFailed(http.statusCode, bodyText)
        }
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        guard case .camera(let spec) = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("非摄像头设备", "Not a camera device"))
        }
        if let streamEntityId = spec.streamEntityId,
           let ws = activeWebSocket {
            let reqId = allocateWebSocketMessageId()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(3500))
                await self?.completeStreamRequest(id: reqId, urlPath: nil)
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
                    "position": max(0, min(100, Int(value.rounded())))
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

    private func sendJSON(ws: URLSessionWebSocketTask, _ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await ws.send(.string(str))
    }

    private func receiveJSON(ws: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
        let msg = try await ws.receive()
        let data: Data = switch msg {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
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

    public static func describeConnectionError(_ error: Error, baseURLString: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == URLError.notConnectedToInternet.rawValue,
           let host = URL(string: normalizeBaseURL(baseURLString))?.host?.lowercased(),
           (HADiscovery.isPrivateLANIPv4(host) || host.hasSuffix(".local")) {
            return L10n.tr(
                "局域网连接被系统拦截（请检查「系统设置 → 隐私与安全性 → 本地网络」中的 MenuBarHome 权限，或重新安装对齐本地应用签名）",
                "Local network connection blocked by macOS (check System Settings → Privacy & Security → Local Network for MenuBarHome)"
            )
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
