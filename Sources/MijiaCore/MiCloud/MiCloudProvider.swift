import Foundation
import os

/// `HomeProvider` that talks to Xiaomi cloud directly (no Home Assistant): discovers devices and
/// rooms, loads MIoT specs, polls properties and maps `DeviceCommand`s to MIoT writes.
public actor MiCloudProvider: HomeProvider {
    public typealias APIFactory = @Sendable (MiSession) -> any MiCloudAPI

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloudProvider")
    /// The one account this provider polls; nil keeps the legacy single-session behaviour.
    private let account: MiAccount?
    private let sessionLoader: @Sendable () -> MiSession?
    private let apiFactory: APIFactory
    private let specSource: any MiotSpecSource
    private let cameraBridge: any XiaomiCameraBridging
    private let localClient: LocalMiIOClient?
    private let topologyCache: MiTopologyCache?
    private let lanFailureThreshold: Int
    private let lanCooldownDuration: TimeInterval
    private let broadcastSweepMinInterval: TimeInterval
    private let now: @Sendable () -> Date
    /// Poll interval while the panel is open; see `PollingPolicy` for the rest (#26).
    private let pollInterval: Duration
    private let closedPollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration
    private let cameraSessionReleaseDelay: Duration
    private let selectedHomeLoader: @Sendable () -> String?

    struct LANEndpointBinding: Equatable, Sendable {
        var cloudIP: String
        var discoveredIP: String?
        var token: String
        var effectiveIP: String { (discoveredIP?.isEmpty == false) ? discoveredIP! : cloudIP }
        var usedBroadcastRecovery: Bool { (discoveredIP?.isEmpty == false) ? discoveredIP != cloudIP : false }

        mutating func reconcile(newCloudIP: String, newToken: String) -> Bool {
            if newToken != token {
                cloudIP = newCloudIP; discoveredIP = nil; token = newToken
                return true
            }
            if newCloudIP == cloudIP { return false }
            if newCloudIP.isEmpty {
                if discoveredIP == nil { cloudIP = "" }
                return false
            }
            cloudIP = newCloudIP
            if discoveredIP == newCloudIP { discoveredIP = nil; return false }
            discoveredIP = nil
            return true
        }
    }

    struct LANTransportDebugState: Equatable, Sendable {
        var transportSucceeded: Bool
        var isCoolingDown: Bool
        var consecutiveFailures: Int
        var lastRTTMs: Int?
        var usedBroadcastRecovery: Bool
        var effectiveIP: String?
    }

    private struct LANHealthState: Sendable {
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date?
        var lastRTTMs: Int?
        var lastErrorWasLocalNetworkDenied: Bool = false
    }

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    /// Whether the last status sent to the store was `.connected`; a transient read failure
    /// reports a disconnect that the next successful poll must clear (#201 review).
    private var lastReportedConnected = false
    private var loopTask: Task<Void, Never>?
    private var api: (any MiCloudAPI)?
    private var session: MiSession?
    /// A rejection is reported once; later failures must not re-open the re-auth prompt.
    private var didReportSessionExpired = false
    /// The credential the cloud already refused. A Mi service token has no client-side refresh, so
    /// another request with it can only 401 again, and a repeated write would reach the device twice.
    /// Polling, wake refreshes and commands stay off until `serviceToken` changes (a new scan) or the
    /// account signs out.
    private var rejectedSession: MiSession?
    private var pendingCameraReleases: [String: Task<Void, Never>] = [:]
    private var followUpTasks: [UUID: Task<Void, Never>] = [:]
    /// The hub DID and camera subdid used the last time this camera's bridge started.
    /// Teardown keeps that pair after the hub later looks offline.
    private var cameraBridgeBindings: [String: (did: String, subdid: String?)] = [:]
    private var lanHealthByDid: [String: LANHealthState] = [:]
    private var lanBindingsByDid: [String: LANEndpointBinding] = [:]
    private var didSeedLANBindingsFromCache = false
    private var lastBroadcastSweepAt: Date?
    private var lastRefreshBroadcastSweepAt: Date?
    private var refreshSweepPending = false
    private var isLocalNetworkDenied = false
    private var sharedHomeDids: Set<String> = []
    private var doorbellBaselineTime: [String: Date] = [:]
    private var lastDoorbellTimestamp: [String: Date] = [:]
    private var lastSavedTopology: CachedMiTopology?
    private var cloudRetryNotBefore: Date?
    private var cloudBackoffSeconds: Double = 2
    private var lastCloudError: (any Error)?
    private var lanSucceededDids: Set<String> = []
    private var lanTransportSucceededDids: Set<String> = []
    private var everObservedPropDids: Set<String> = []
    private var hasLiveTopologyRefresh = false

    private var devices: [MiDeviceRecord] = []
    private var rooms: [MiRoom] = []
    /// Light-group did → member dids, refreshed with the device list (#189).
    private var groupMembersByGroup: [String: [String]] = [:]
    private var specsByModel: [String: MiotDeviceSpec] = [:]
    /// Models currently served by the read-only fallback; retried on every device-list refresh (#30).
    private var fallbackSpecModels: Set<String> = []
    private var values: [MiotPropKey: JSONValue] = [:]
    /// Lights whose `mode` write the cloud rejected as unsupported; their scene chips are hidden.
    private var effectsUnsupported: Set<String> = []

    private var pollingContext = PollingContext()
    private var lastFullPollAt: ContinuousClock.Instant?
    private var lastWakePollAt: ContinuousClock.Instant?
    private var lastPolledSelection: String?
    private enum PendingLANRetry: Equatable {
        case devices(Set<String>)
        case all

        mutating func merge(_ deviceId: String?) {
            switch (self, deviceId) {
            case (.all, _), (_, nil):
                self = .all
            case (.devices(var ids), let id?):
                ids.insert(id)
                self = .devices(ids)
            }
        }
    }

    private var wakePollPending = false
    private var pendingRefreshAfterPoll = false
    private var pendingLANRetry: PendingLANRetry?
    private var isPolling = false
    private var isShutDown = false
    private static let wakeRefreshCooldown: Duration = .seconds(1)
    /// The loop's current wait; cancelling it makes the loop re-check `pollingContext` right away.
    private var waitTask: Task<Void, Never>?
    private var pollsSinceContextChange = 0
    /// Set on wake or unlock: poll once right away, however recent the last poll was.
    private var pollRequested = false

    var isShutDownForTesting: Bool { isShutDown }

    func lanTransportState(for did: String) -> LANTransportDebugState {
        let health = lanHealthByDid[did], binding = lanBindingsByDid[did]
        let coolingDown = health?.cooldownUntil.map { now() < $0 } ?? false
        return LANTransportDebugState(
            transportSucceeded: lanTransportSucceededDids.contains(did) && !coolingDown,
            isCoolingDown: coolingDown,
            consecutiveFailures: health?.consecutiveFailures ?? 0,
            lastRTTMs: health?.lastRTTMs,
            usedBroadcastRecovery: binding?.usedBroadcastRecovery ?? false,
            effectiveIP: binding?.effectiveIP
        )
    }

    public init(
        account: MiAccount? = nil,
        sessionLoader: @escaping @Sendable () -> MiSession? = { MiSessionStore.loadAccounts().first?.session },
        apiFactory: @escaping APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        cameraBridge: any XiaomiCameraBridging = XiaomiCameraBridge.shared,
        localClient: LocalMiIOClient? = LocalMiIOClient(),
        topologyCache: MiTopologyCache? = nil,
        lanFailureThreshold: Int = 3,
        lanCooldownDuration: TimeInterval = 30,
        broadcastSweepMinInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = PollingPolicy.panelOpenInterval,
        closedPollInterval: Duration = PollingPolicy.panelClosedInterval,
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800),
        cameraSessionReleaseDelay: Duration = .milliseconds(2500),
        selectedHomeLoader: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey) }
    ) {
        self.account = account
        self.sessionLoader = sessionLoader
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.cameraBridge = cameraBridge
        self.localClient = localClient
        self.topologyCache = topologyCache
        self.lanFailureThreshold = max(1, lanFailureThreshold)
        self.lanCooldownDuration = max(0, lanCooldownDuration)
        self.broadcastSweepMinInterval = max(0, broadcastSweepMinInterval)
        self.now = now
        self.pollInterval = pollInterval
        self.closedPollInterval = closedPollInterval
        self.deviceRefreshEveryPolls = max(1, deviceRefreshEveryPolls)
        self.followUpDelay = followUpDelay
        self.cameraSessionReleaseDelay = cameraSessionReleaseDelay
        self.selectedHomeLoader = selectedHomeLoader
        self.lastPolledSelection = selectedHomeLoader()
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
        restartLoop()
    }

    /// Stops polling, local/cloud clients, timers, and finishes the event stream; used when switching backends.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        pendingLANRetry = nil
        pendingRefreshAfterPoll = false
        loopTask?.cancel()
        loopTask = nil
        waitTask?.cancel()
        waitTask = nil
        for task in followUpTasks.values {
            task.cancel()
        }
        followUpTasks.removeAll()
        for task in pendingCameraReleases.values {
            task.cancel()
        }
        pendingCameraReleases.removeAll()
        doorbellBaselineTime.removeAll()
        lastDoorbellTimestamp.removeAll()
        let bindings = Array(cameraBridgeBindings.values)
        cameraBridgeBindings.removeAll()
        await localClient?.shutdown()
        await api?.shutdown()
        api = nil
        continuation?.finish()
        continuation = nil
        for binding in bindings {
            await cameraBridge.stopBridge(did: binding.did, subdid: binding.subdid)
        }
    }

    public func refreshNow() async {
        guard !isShutDown else { return }
        if let rejected = rejectedSession {
            // A wake refresh cannot revive a refused Mi token: only a scan that changed the stored
            // serviceToken may poll again, and that credential rebuilds the loop from scratch.
            guard let current = currentSession(), !current.sharesCredentials(with: rejected) else { return }
            restartLoop()
            return
        }
        guard let api else {
            restartLoop()
            return
        }
        let withinWakeCooldown = wakePollPending
            || (lastWakePollAt.map { ContinuousClock.now - $0 < Self.wakeRefreshCooldown } ?? false)
        let selectionChanged = selectedHomeLoader() != lastPolledSelection
        if isPolling {
            if selectionChanged || !withinWakeCooldown {
                pendingRefreshAfterPoll = true
                refreshSweepPending = true
            }
            return
        }
        if withinWakeCooldown, !selectionChanged, !devices.isEmpty, lastReportedConnected {
            return
        }
        // After switching homes, devices of a home never polled would flash as off; wait for their values.
        if !devices.isEmpty, lastReportedConnected, hasValuesForScope() {
            emitSnapshot(closesAwayGap: false)
        }
        refreshSweepPending = true
        prepareLocalNetworkRetryOnRefresh()
        await performImmediatePoll(api)
    }

    public func retryLAN(deviceId: String?) async {
        guard !isShutDown else { return }
        if let rejected = rejectedSession {
            guard let current = currentSession(), !current.sharesCredentials(with: rejected) else { return }
            clearLANCooldownForRetry(targetDids: resolvedTargetDids(for: deviceId.map { .devices([$0]) } ?? .all))
            lastBroadcastSweepAt = nil
            lastWakePollAt = nil
            restartLoop()
            return
        }
        let request: PendingLANRetry = deviceId.map { .devices([$0]) } ?? .all
        guard let api else {
            clearLANCooldownForRetry(targetDids: resolvedTargetDids(for: request))
            lastBroadcastSweepAt = nil
            lastWakePollAt = nil
            restartLoop()
            return
        }
        if isPolling {
            // Keep existing cooldown state untouched until the in-flight poll completes so its
            // snapshot cannot transiently flip the device to `.cloud` before the retry runs.
            if pendingLANRetry != nil {
                pendingLANRetry?.merge(deviceId)
            } else {
                pendingLANRetry = request
            }
            return
        }
        await performImmediateLANRetry(api, retry: request)
    }

    private func resolvedTargetDids(for retry: PendingLANRetry) -> Set<String>? {
        switch retry {
        case .all:
            return nil
        case .devices(let deviceIds):
            var targetDids = deviceIds
            for record in devices where deviceIds.contains(record.did) {
                targetDids.insert(record.miotDid)
            }
            for deviceId in deviceIds {
                if let members = groupMembersByGroup[deviceId] {
                    targetDids.formUnion(members)
                    for record in devices where members.contains(record.did) {
                        targetDids.insert(record.miotDid)
                    }
                }
            }
            return targetDids
        }
    }

    private func hasActiveLANEndpointInScope(dids: Set<String>? = nil) -> Bool {
        guard localClient != nil else { return false }
        let scopedDevices = scopedDevicesAndRooms().devices
        for record in scopedDevices {
            if let dids, !dids.contains(record.did), !dids.contains(record.miotDid) {
                continue
            }
            if lanEndpoint(for: record) != nil {
                return true
            }
        }
        return false
    }

    private func clearLANCooldownForRetry(targetDids: Set<String>?) {
        if let targetDids {
            for did in targetDids {
                guard var state = lanHealthByDid[did] else { continue }
                state.cooldownUntil = nil
                state.consecutiveFailures = 0
                lanHealthByDid[did] = state
            }
        } else {
            for (did, var state) in lanHealthByDid {
                state.cooldownUntil = nil
                state.consecutiveFailures = 0
                lanHealthByDid[did] = state
            }
        }
    }

    private func executeLANRetry(_ api: any MiCloudAPI, retry: PendingLANRetry) async throws {
        let targetDids = resolvedTargetDids(for: retry)
        clearLANCooldownForRetry(targetDids: targetDids)
        lastBroadcastSweepAt = nil
        lastWakePollAt = nil
        prepareLocalNetworkRetryOnRefresh()

        let scopedDevices = scopedDevicesAndRooms().devices
        let targetKeys = propKeys(of: scopedDevices, dids: targetDids)
        if !targetKeys.isEmpty, hasActiveLANEndpointInScope(dids: targetDids) {
            try await poll(api, dids: targetDids, allowBroadcastSweepOnFailure: true)
            return
        }

        if (lastCloudError as? MiCloudError) != .http(429) {
            cloudRetryNotBefore = nil
        }
        try await discover(api)
        try await poll(api, dids: nil, allowBroadcastSweepOnFailure: true)
    }

    private func performImmediateLANRetry(_ api: any MiCloudAPI, retry: PendingLANRetry) async {
        do {
            try await performTrackedPoll(api) {
                try await executeLANRetry(api, retry: retry)
            }
            reportConnected()
        } catch MiCloudError.sessionExpired {
            clearExpiredSnapshot()
            report(MiCloudError.sessionExpired)
        } catch {
            report(error)
        }
    }

    private func performImmediatePoll(_ api: any MiCloudAPI) async {
        if (lastCloudError as? MiCloudError) != .http(429) {
            cloudRetryNotBefore = nil
        }
        do {
            try await performTrackedPoll(api) {
                try await discover(api)
                try await poll(api, dids: nil)
            }
            reportConnected()
        } catch MiCloudError.sessionExpired {
            clearExpiredSnapshot()
            report(MiCloudError.sessionExpired)
        } catch {
            report(error)
        }
    }

    private func restartLoop() {
        guard !isShutDown else { return }
        loopTask?.cancel()
        loopTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        guard !isShutDown else { return }
        guard let session = account?.session ?? sessionLoader() else {
            api = nil
            continuation?.yield(.statusChanged(.disconnected(MiCloudError.notLoggedIn.localizedDescription)))
            return
        }
        self.session = session
        clearRejectionIfCredentialChanged(session)
        // Stop before any cloud call: this credential is the one the server refused and a Mi token
        // cannot refresh itself, so every request until a new scan can only 401 again.
        guard !isRejected(session) else { return }
        // The declaration is already stored, so a relaunch only reports it; no cloud call, no event.
        if session.expiryState(at: Date()) == .expired {
            api = nil
            topologyCache?.remove(accountID: MiAccount(session: session).id)
            continuation?.yield(.statusChanged(.disconnected(MiCloudError.sessionExpired.localizedDescription)))
            devices = []
            rooms = []
            values = [:]
            emitSnapshot()
            return
        }
        let api = apiFactory(session)
        self.api = api
        var backoff: Double = 2

        while !Task.isCancelled && !isShutDown {
            continuation?.yield(.statusChanged(.connecting))
            lastReportedConnected = false
            do {
                try await performTrackedPoll(api) {
                    try await discover(api)
                    try await poll(api, dids: nil)
                }
                reportConnected()
                backoff = 2
                var polls = 1
                while !Task.isCancelled && !isShutDown {
                    try await waitForNextPoll()
                    guard !Task.isCancelled && !isShutDown else { return }
                    try await performTrackedPoll(api) {
                        let refreshedTopologyInPoll = isCloudAllowed && (!hasLiveTopologyRefresh || cloudRetryNotBefore != nil)
                        if refreshedTopologyInPoll {
                            try await discover(api)
                        }
                        try await poll(api, dids: nil)
                        polls += 1
                        if !refreshedTopologyInPoll, isCloudAllowed, polls % deviceRefreshEveryPolls == 0 {
                            do {
                                try await refreshDeviceList(api)
                                clearCloudBackoff()
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch MiCloudError.sessionExpired {
                                throw MiCloudError.sessionExpired
                            } catch {
                                scheduleCloudBackoff(for: error)
                                if lanSucceededDids.isEmpty {
                                    throw error
                                }
                                emitSnapshot(closesAwayGap: false)
                            }
                        }
                    }
                    reportConnected()
                }
            } catch is CancellationError {
                return
            } catch MiCloudError.sessionExpired {
                if isShutDown { return }
                clearExpiredSnapshot()
                report(MiCloudError.sessionExpired)
                return
            } catch {
                if Task.isCancelled || isShutDown { return }
                wakePollPending = false
                report(error)
                // Xiaomi throttles busy clients; back off for minutes instead of seconds (#26).
                let throttled = (error as? MiCloudError) == .http(429)
                if throttled { backoff = max(backoff, 60) }
                try? await Task.sleep(for: .seconds(backoff))
                await waitWhilePaused()
                backoff = min(backoff * 2, throttled ? 900 : 60)
            }
        }
    }

    private func performTrackedPoll(_ api: any MiCloudAPI, _ body: () async throws -> Void) async throws {
        isPolling = true
        defer {
            isPolling = false
            pendingRefreshAfterPoll = false
            pendingLANRetry = nil
        }
        var pendingError: (any Error)?
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            pendingError = error
        }

        while !Task.isCancelled && !isShutDown {
            if let retry = pendingLANRetry {
                pendingLANRetry = nil
                pendingError = nil
                if case .all = retry {
                    pendingRefreshAfterPoll = false
                }
                do {
                    try await executeLANRetry(api, retry: retry)
                } catch is CancellationError {
                    throw CancellationError()
                } catch MiCloudError.sessionExpired {
                    throw MiCloudError.sessionExpired
                } catch {
                    pendingError = error
                }
                continue
            }
            if pendingError == nil, pendingRefreshAfterPoll {
                pendingRefreshAfterPoll = false
                do {
                    try await poll(api, dids: nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch MiCloudError.sessionExpired {
                    throw MiCloudError.sessionExpired
                } catch {
                    pendingError = error
                }
                continue
            }
            break
        }

        if let pendingError {
            throw pendingError
        }
    }

    private func performCloudCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        // Xiaomi issues no refresh token, so the same rejected credential can only 401 again:
        // a retry cannot succeed and a write would be sent twice. The credential is latched here
        // and every later call, wake refresh and command is refused until a new scan replaces it.
        if isSessionRejected { throw MiCloudError.sessionExpired }
        do {
            return try await body()
        } catch MiCloudError.sessionExpired {
            guard !Task.isCancelled && !isShutDown else { throw CancellationError() }
            if let rejected = session ?? currentSession() { latchRejection(rejected) }
            throw MiCloudError.sessionExpired
        }
    }

    /// The credential this provider would send today: a per-account child keeps its captured
    /// account, the legacy single-session provider re-reads its loader.
    private func currentSession() -> MiSession? {
        account?.session ?? sessionLoader()
    }

    private func isRejected(_ candidate: MiSession?) -> Bool {
        guard let candidate, let rejectedSession else { return false }
        return candidate.sharesCredentials(with: rejectedSession)
    }

    private var isSessionRejected: Bool {
        guard rejectedSession != nil else { return false }
        return isRejected(currentSession())
    }

    /// Keeps the refused credential out of every later request and sends the one re-auth event;
    /// a repeat must not re-open a prompt the user has already answered.
    private func latchRejection(_ rejected: MiSession) {
        rejectedSession = rejected
        guard !didReportSessionExpired else { return }
        didReportSessionExpired = true
        continuation?.yield(.sessionExpired(rejected))
    }

    /// Lifts the stop once the stored credential is no longer the rejected one (a second scan).
    private func clearRejectionIfCredentialChanged(_ candidate: MiSession) {
        guard let rejected = rejectedSession, !candidate.sharesCredentials(with: rejected) else { return }
        rejectedSession = nil
        didReportSessionExpired = false
    }

    // MARK: Polling Rhythm (#26)

    /// Called by the app when the panel opens or closes, the Mac sleeps or wakes, the screen locks, or
    /// Low Power Mode changes. Opening the panel or waking up polls right away if the data is older
    /// than the new interval.
    /// Declared `async` so it wins over the protocol's no-op default in async callers.
    public func setPollingContext(_ context: PollingContext) async {
        guard !isShutDown, context != pollingContext else { return }
        logger.info("Mi cloud polling: \(context.description, privacy: .public) (\(self.pollsSinceContextChange, privacy: .public) polls since last change)")
        if context.systemActive && !pollingContext.systemActive {
            pollRequested = true
            wakePollPending = true
            refreshSweepPending = true
        } else if !context.systemActive {
            wakePollPending = false
            lastWakePollAt = nil
        }
        pollingContext = context
        pollsSinceContextChange = 0
        waitTask?.cancel()
    }

    private var currentInterval: Duration? {
        PollingPolicy.interval(for: pollingContext, panelOpen: pollInterval, panelClosed: closedPollInterval)
    }

    /// Sleeps until the next poll is due. A context change wakes it to re-check, so the panel
    /// opening after a minute polls at once, and closing it stretches the wait.
    private func waitForNextPoll() async throws {
        while true {
            try Task.checkCancellation()
            guard let interval = currentInterval else {
                await sleepUntilWoken(for: nil)
                continue
            }
            if pollRequested { return }
            let remaining = (lastFullPollAt ?? .now).advanced(by: interval) - ContinuousClock.now
            guard remaining > .zero else { return }
            await sleepUntilWoken(for: remaining)
        }
    }

    private func waitWhilePaused() async {
        while !Task.isCancelled, currentInterval == nil {
            await sleepUntilWoken(for: nil)
        }
    }

    /// Sleeps for `duration` (an hour when nil), returning early on `setPollingContext` or cancellation.
    private func sleepUntilWoken(for duration: Duration?) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: duration ?? .seconds(3600)) }
        waitTask = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        waitTask = nil
    }

    /// Drops the cached home so an expired account stops contributing devices to the merged panel.
    private func clearExpiredSnapshot() {
        api = nil
        if let session {
            topologyCache?.remove(accountID: MiAccount(session: session).id)
        }
        lastSavedTopology = nil
        lanBindingsByDid.removeAll()
        lanHealthByDid.removeAll()
        didSeedLANBindingsFromCache = false
        lastBroadcastSweepAt = nil
        lastRefreshBroadcastSweepAt = nil
        refreshSweepPending = false
        pendingLANRetry = nil
        updateLocalNetworkDenied(false)
        lanSucceededDids.removeAll()
        lanTransportSucceededDids.removeAll()
        everObservedPropDids.removeAll()
        cloudRetryNotBefore = nil
        lastCloudError = nil
        hasLiveTopologyRefresh = false
        guard account != nil else { return }
        devices = []
        rooms = []
        sharedHomeDids.removeAll()
        values = [:]
        emitSnapshot()
    }

    private var isCloudAllowed: Bool {
        guard let retryAt = cloudRetryNotBefore else { return true }
        return now() >= retryAt
    }

    private func scheduleCloudBackoff(for error: any Error) {
        let throttled = (error as? MiCloudError) == .http(429)
        if throttled {
            cloudBackoffSeconds = max(cloudBackoffSeconds, 60)
        }
        cloudRetryNotBefore = now().addingTimeInterval(cloudBackoffSeconds)
        lastCloudError = error
        cloudBackoffSeconds = min(cloudBackoffSeconds * 2, throttled ? 900 : 60)
    }

    private func clearCloudBackoff() {
        cloudRetryNotBefore = nil
        cloudBackoffSeconds = 2
        lastCloudError = nil
    }

    private func report(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("Mi cloud error: \(message, privacy: .public)")
        lastReportedConnected = false
        if (error as? MiCloudError) == .sessionExpired, let rejected = session ?? currentSession() {
            latchRejection(rejected)
        }
        continuation?.yield(.statusChanged(.disconnected(message)))
    }

    /// Clears a disconnect reported by a failed poll after the cloud answers again.
    private func reportConnected() {
        guard !lastReportedConnected else { return }
        lastReportedConnected = true
        continuation?.yield(.statusChanged(.connected))
    }

    // MARK: Discovery & Polling

    private func discover(_ api: any MiCloudAPI) async throws {
        if !devices.isEmpty && !isCloudAllowed {
            return
        }
        do {
            // Rooms first: they name the shared-home devices the unfiltered device list leaves out (#134).
            let outcome = try await performCloudCall { try await MiCloudDiscovery.rooms(api) }
            if outcome.error == nil {
                if outcome.rooms != rooms { unresolvedRoomDids = [] }
                rooms = outcome.rooms
            }
            let roomsError = outcome.error
            logger.info("Mi cloud rooms: \(self.rooms.count, privacy: .public), homes: \(Self.homeOptions(from: self.rooms).count, privacy: .public)")
            try await refreshDeviceList(api, retryUnresolved: true)
            // An account whose only devices live in a home shared with it has an empty device list until
            // `homeRooms()` names that home. Reporting connected + empty hides that failure, so a broken
            // room list surfaces as the error it is (#76, #67). An account with direct devices still
            // degrades to 全屋, which is what the room-less snapshot is for.
            if devices.isEmpty, let roomsError { throw roomsError }
        } catch is CancellationError {
            throw CancellationError()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            if devices.isEmpty,
               localClient != nil,
               let session,
               let cached = topologyCache?.load(for: session),
               !cached.devices.isEmpty {
                devices = cached.devices
                rooms = cached.rooms
                groupMembersByGroup = cached.groupMembersByGroup
                lastSavedTopology = cached
                didSeedLANBindingsFromCache = true
                reconcileLANEndpoints(devices, seededDiscoveredIPs: cached.discoveredLANIPsByDid)
                await loadMissingSpecs()
                scheduleCloudBackoff(for: error)
                return
            }
            if !devices.isEmpty, (!lanSucceededDids.isEmpty || hasActiveLANEndpointInScope()) {
                scheduleCloudBackoff(for: error)
                return
            }
            throw error
        }
    }

    /// Room dids the by-did lookup returned nothing for (IR remotes, removed devices); the periodic
    /// refresh skips them so it does not spend a request on them every time.
    private var unresolvedRoomDids: Set<String> = []

    private func refreshDeviceList(_ api: any MiCloudAPI, retryUnresolved: Bool = false) async throws {
        let currentRooms = rooms
        let previousUnresolved = unresolvedRoomDids
        let outcome = try await performCloudCall {
            try await MiCloudDiscovery.devices(
                api,
                rooms: currentRooms,
                retryUnresolved: retryUnresolved,
                previousUnresolved: previousUnresolved
            )
        }
        unresolvedRoomDids = outcome.unresolvedRoomDids
        rooms = outcome.rooms
        devices = outcome.devices
        if !didSeedLANBindingsFromCache {
            didSeedLANBindingsFromCache = true
            if let session, let cached = topologyCache?.load(for: session) {
                lastSavedTopology = cached
                reconcileLANEndpoints(cached.devices, seededDiscoveredIPs: cached.discoveredLANIPsByDid)
            }
        }
        reconcileLANEndpoints(devices)
        try await refreshGroupMembers(api)
        persistTopologyIfNeeded()
        hasLiveTopologyRefresh = true
        await loadMissingSpecs()

        var unsupported: Set<String> = []
        var supported = 0
        for d in devices {
            if let spec = specsByModel[d.model], MiotSynthesizer.supportedServiceName(for: spec) != nil {
                supported += 1
            } else {
                unsupported.insert(d.model)
            }
        }
        let online = devices.filter(\.isOnline).count
        logger.info("Mi cloud devices: \(self.devices.count, privacy: .public) total, \(online, privacy: .public) online, \(supported, privacy: .public) supported")
        if !unsupported.isEmpty {
            logger.notice("Unsupported models (skipped): \(unsupported.sorted().joined(separator: ", "), privacy: .public)")
        }
    }

    /// Fetches light-group membership for the listed `group.*` cards so the panel can fold their
    /// member lights into one card (#189). A failed lookup clears the cache: showing a member
    /// twice beats hiding a light whose group query went stale.
    private func refreshGroupMembers(_ api: any MiCloudAPI) async throws {
        var seen: Set<String> = []
        let groupDids = devices.map(\.did).filter { $0.hasPrefix("group.") && seen.insert($0).inserted }
        guard !groupDids.isEmpty else {
            groupMembersByGroup = [:]
            return
        }
        do {
            groupMembersByGroup = try await performCloudCall {
                try await api.lightGroupMembers(groupDids: groupDids)
            }
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            groupMembersByGroup = [:]
            logger.error("Light-group member lookup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Member did → owning group did for cards in `devices`, in device-list order. Members or groups
    /// outside this home are omitted, so switching homes cannot hide a light through a stale group.
    static func deviceGroupOwners(
        membersByGroup: [String: [String]],
        devices: [MiDeviceRecord]
    ) -> [String: String] {
        let listed = Set(devices.map(\.did))
        var owners: [String: String] = [:]
        for device in devices {
            guard device.did.hasPrefix("group."), let memberDids = membersByGroup[device.did] else { continue }
            for did in memberDids where listed.contains(did) && owners[did] == nil {
                owners[did] = device.did
            }
        }
        return owners
    }

    private struct SpecLoadOutcome: Sendable {
        let model: String
        let spec: MiotDeviceSpec?
        let errorDescription: String?
    }

    private func loadMissingSpecs() async {
        struct SpecRequest: Sendable {
            var specType: String?
            var name: String
        }
        var pending: [String: SpecRequest] = [:]
        for device in devices where (specsByModel[device.model] == nil || fallbackSpecModels.contains(device.model))
            && pending[device.model] == nil {
            pending[device.model] = SpecRequest(specType: device.specType, name: device.name)
        }
        guard !pending.isEmpty else { return }
        let source = specSource
        let entries = Array(pending)
        let maxConcurrency = 6
        let loaded = await withTaskGroup(of: SpecLoadOutcome.self) { group in
            var iterator = entries.makeIterator()
            func enqueueNext() {
                guard let (model, request) = iterator.next() else { return }
                let specType = request.specType
                let name = request.name
                group.addTask {
                    do {
                        if let spec = try await source.spec(model: model, specType: specType) {
                            return SpecLoadOutcome(model: model, spec: spec, errorDescription: nil)
                        }
                    } catch {
                        return SpecLoadOutcome(
                            model: model,
                            spec: MiotFallbackSpec.infer(model: model, name: name),
                            errorDescription: error.localizedDescription
                        )
                    }
                    return SpecLoadOutcome(
                        model: model,
                        spec: MiotFallbackSpec.infer(model: model, name: name),
                        errorDescription: nil
                    )
                }
            }
            for _ in 0..<min(maxConcurrency, entries.count) {
                enqueueNext()
            }
            var out: [SpecLoadOutcome] = []
            for await result in group {
                out.append(result)
                enqueueNext()
            }
            return out
        }
        for outcome in loaded {
            if let spec = outcome.spec {
                specsByModel[outcome.model] = spec
                if Self.isFallbackSpec(spec) {
                    fallbackSpecModels.insert(outcome.model)
                } else {
                    fallbackSpecModels.remove(outcome.model)
                }
            }
            if let error = outcome.errorDescription {
                logger.error("Spec load failed for \(outcome.model, privacy: .public): \(error, privacy: .public); using the read-only fallback")
            }
        }
    }

    /// The bundled fallback table tags every URN with `fallback` as its vendor segment (#30), so a
    /// guessed spec cannot masquerade as a released one and stop the retry.
    static func isFallbackSpec(_ spec: MiotDeviceSpec) -> Bool {
        spec.type.split(separator: ":").dropFirst(5).first == "fallback"
    }

    private struct HybridPropReadOutcome {
        let values: [MiotPropKey: JSONValue]
        let completedKeys: [MiotPropKey]
        let lanSucceededDids: Set<String>
        let lanTransportSucceededDids: Set<String>
        let cloudError: (any Error)?
    }

    /// Reads the selected home's devices only (all homes when none is selected) (#26).
    @discardableResult
    private func poll(
        _ api: any MiCloudAPI,
        dids: Set<String>?,
        allowBroadcastSweepOnFailure: Bool = false
    ) async throws -> Set<MiotPropKey> {
        let outcome = try await pollOutcome(
            api,
            dids: dids,
            allowBroadcastSweepOnFailure: allowBroadcastSweepOnFailure
        )
        if let cloudError = outcome.cloudError {
            throw cloudError
        }
        return outcome.freshKeys
    }

    private func pollOutcome(
        _ api: any MiCloudAPI,
        dids: Set<String>?,
        allowBroadcastSweepOnFailure: Bool = false
    ) async throws -> (freshKeys: Set<MiotPropKey>, cloudError: (any Error)?) {
        let allowCooldownSweep: Bool
        if dids == nil {
            lastPolledSelection = selectedHomeLoader()
            pendingRefreshAfterPoll = false
            allowCooldownSweep = refreshSweepPending
            refreshSweepPending = false
        } else {
            allowCooldownSweep = false
        }
        let scopedDevices = scopedDevicesAndRooms().devices
        let keys = propKeys(of: scopedDevices, dids: dids)
        var freshKeys: Set<MiotPropKey> = []
        if !keys.isEmpty {
            let outcome = try await fetchPropsHybrid(
                api: api,
                keys: keys,
                scopedDevices: scopedDevices,
                allowCooldownSweep: allowCooldownSweep,
                allowBroadcastSweepOnFailure: allowBroadcastSweepOnFailure
            )
            if dids == nil {
                lanSucceededDids = outcome.lanSucceededDids
                lanTransportSucceededDids = outcome.lanTransportSucceededDids
            } else if let dids {
                lanSucceededDids.subtract(dids)
                lanSucceededDids.formUnion(outcome.lanSucceededDids)
                lanTransportSucceededDids.subtract(dids)
                lanTransportSucceededDids.formUnion(outcome.lanTransportSucceededDids)
            }
            freshKeys = Set(outcome.values.keys)
            everObservedPropDids.formUnion(outcome.values.keys.map(\.did))
            // getProps omits items with a non-zero code. A missing door-state must not keep the
            // previous locked/unlocked claim while the device list still says online (#149).
            let requestedLocks = doorStateKeys(requested: outcome.completedKeys)
            let clearedCachedLock = requestedLocks.contains { outcome.values[$0] == nil && values[$0] != nil }
            Self.applyPropRead(&values, fresh: outcome.values, requestedLockKeys: requestedLocks)
            if let cloudError = outcome.cloudError {
                if lanSucceededDids.isEmpty {
                    if !outcome.values.isEmpty || clearedCachedLock {
                        emitSnapshot(closesAwayGap: false)
                    }
                    return (freshKeys, cloudError)
                }
                if dids == nil {
                    lastFullPollAt = .now
                    if wakePollPending {
                        wakePollPending = false
                        lastWakePollAt = .now
                    }
                    pollRequested = false
                    pollsSinceContextChange += 1
                }
                emitSnapshot(closesAwayGap: false)
                return (freshKeys, nil)
            }
        } else if dids == nil {
            lanSucceededDids = []
            lanTransportSucceededDids = []
        }
        if dids == nil,
           lanSucceededDids.isEmpty,
           !isCloudAllowed || !hasLiveTopologyRefresh,
           let lastCloudError {
            return (freshKeys, lastCloudError)
        }
        if dids == nil {
            if isCloudAllowed {
                clearCloudBackoff()
                try await pollDoorbellEvents(api, scopedDevices: scopedDevices)
            }
            lastFullPollAt = .now
            if wakePollPending {
                wakePollPending = false
                lastWakePollAt = .now
            }
            pollRequested = false
            pollsSinceContextChange += 1
        }
        emitSnapshot(closesAwayGap: dids == nil && cloudRetryNotBefore == nil)
        return (freshKeys, nil)
    }

    private func fetchPropsHybrid(
        api: any MiCloudAPI,
        keys: [MiotPropKey],
        scopedDevices: [MiDeviceRecord],
        allowCooldownSweep: Bool = false,
        allowBroadcastSweepOnFailure: Bool = false
    ) async throws -> HybridPropReadOutcome {
        let cloudAllowed = isCloudAllowed
        guard let localClient else {
            if !cloudAllowed, let lastCloudError {
                throw lastCloudError
            }
            do {
                let cloudValues = try await performCloudCall {
                    try await api.getProps(keys)
                }
                clearCloudBackoff()
                everObservedPropDids.formUnion(cloudValues.keys.map(\.did))
                return HybridPropReadOutcome(
                    values: cloudValues,
                    completedKeys: keys,
                    lanSucceededDids: [],
                    lanTransportSucceededDids: [],
                    cloudError: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                scheduleCloudBackoff(for: error)
                throw error
            }
        }

        var recordByDid: [String: MiDeviceRecord] = [:]
        for record in scopedDevices {
            if let existing = recordByDid[record.miotDid], existing.splitParentDid == nil {
                continue
            }
            recordByDid[record.miotDid] = record
        }

        var lanEndpoints: [String: MiIODeviceEndpoint] = [:]
        var lanKeysByDid: [String: [MiotPropKey]] = [:]
        var cooldownSweepKeysByDid: [String: [MiotPropKey]] = [:]
        var cloudKeys: [MiotPropKey] = []

        for key in keys {
            if let record = recordByDid[key.did], let endpoint = lanEndpoint(for: record) {
                lanEndpoints[key.did] = endpoint
                lanKeysByDid[key.did, default: []].append(key)
            } else if allowCooldownSweep,
                      let record = recordByDid[key.did],
                      lanEligibleEndpointIgnoringCooldown(for: record) != nil {
                cooldownSweepKeysByDid[key.did, default: []].append(key)
            } else {
                cloudKeys.append(key)
            }
        }

        struct LANPollResult: Sendable {
            let did: String
            let values: [MiotPropKey: JSONValue]?
            let rttMs: Int?
            let keys: [MiotPropKey]
            let error: (any Error)?
        }

        var combined: [MiotPropKey: JSONValue] = [:]
        var lanAnsweredKeys: [MiotPropKey] = []
        var pollLanSucceededDids: Set<String> = []
        var pollLanTransportSucceededDids: Set<String> = []
        var failedOutcomes: [LANPollResult] = []
        var shouldSweep = false
        if !lanKeysByDid.isEmpty {
            var remainingLANKeysByDid = lanKeysByDid
            var probeOutcome: LANPollResult?
            if isLocalNetworkDenied, let probeDid = remainingLANKeysByDid.keys.sorted().first,
               let probeKeys = remainingLANKeysByDid[probeDid], let probeEndpoint = lanEndpoints[probeDid] {
                do {
                    let resultValues = try await localClient.getProps(probeKeys, endpoint: probeEndpoint)
                    let rttMs = await localClient.lastRoundTripMs(for: probeDid)
                    probeOutcome = LANPollResult(did: probeDid, values: resultValues, rttMs: rttMs, keys: probeKeys, error: nil)
                    remainingLANKeysByDid.removeValue(forKey: probeDid)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if (error as? MiIOError) == .localNetworkDenied {
                        recordLANFailure(did: probeDid, error: error)
                        for did in remainingLANKeysByDid.keys where did != probeDid {
                            var state = lanHealthByDid[did] ?? LANHealthState()
                            state.lastErrorWasLocalNetworkDenied = true
                            state.cooldownUntil = nil
                            lanHealthByDid[did] = state
                            lanSucceededDids.remove(did)
                            lanTransportSucceededDids.remove(did)
                        }
                        for (_, deviceKeys) in remainingLANKeysByDid {
                            cloudKeys.append(contentsOf: deviceKeys)
                        }
                        remainingLANKeysByDid.removeAll()
                    } else {
                        probeOutcome = LANPollResult(did: probeDid, values: nil, rttMs: nil, keys: probeKeys, error: error)
                        remainingLANKeysByDid.removeValue(forKey: probeDid)
                    }
                }
            }

            var lanResults = await withTaskGroup(of: LANPollResult.self) { group in
                for (did, deviceKeys) in remainingLANKeysByDid {
                    guard let endpoint = lanEndpoints[did] else { continue }
                    group.addTask {
                        do {
                            let result = try await localClient.getProps(deviceKeys, endpoint: endpoint)
                            let rttMs = await localClient.lastRoundTripMs(for: did)
                            return LANPollResult(did: did, values: result, rttMs: rttMs, keys: deviceKeys, error: nil)
                        } catch {
                            return LANPollResult(did: did, values: nil, rttMs: nil, keys: deviceKeys, error: error)
                        }
                    }
                }
                var out: [LANPollResult] = []
                for await item in group { out.append(item) }
                return out
            }
            if let probeOutcome {
                lanResults.insert(probeOutcome, at: 0)
            }

            let batchSawLocalNetworkDenied = lanResults.contains { ($0.error as? MiIOError) == .localNetworkDenied }
            let batchProvedPermissionGranted = !batchSawLocalNetworkDenied && lanResults.contains { outcome in
                guard let err = outcome.error else { return outcome.values != nil }
                return MiIOError.provesPacketCrossedPermissionBoundary(err)
            }
            if batchProvedPermissionGranted, isLocalNetworkDenied {
                updateLocalNetworkDenied(false)
            }
            for outcome in lanResults {
                if let err = outcome.error {
                    if err is CancellationError { throw CancellationError() }
                    recordLANFailure(
                        did: outcome.did,
                        error: err,
                        allowClearingDenied: !batchSawLocalNetworkDenied,
                        batchSawLocalNetworkDenied: batchSawLocalNetworkDenied
                    )
                    failedOutcomes.append(outcome)
                    if !batchSawLocalNetworkDenied,
                       (err as? MiIOError) != .localNetworkDenied,
                       (allowBroadcastSweepOnFailure || (lanHealthByDid[outcome.did]?.consecutiveFailures ?? 0) >= lanFailureThreshold) { shouldSweep = true }
                } else if let resultValues = outcome.values {
                    let missingKeys = outcome.keys.filter { resultValues[$0] == nil }
                    recordLANSuccess(did: outcome.did, rttMs: outcome.rttMs, allowClearingDenied: !batchSawLocalNetworkDenied)
                    pollLanTransportSucceededDids.insert(outcome.did)
                    if !resultValues.isEmpty || outcome.keys.isEmpty {
                        pollLanSucceededDids.insert(outcome.did)
                    }
                    if !resultValues.isEmpty { combined.merge(resultValues) { _, new in new } }
                    // Even an all-nonzero reply completed the read attempt; keep its keys in
                    // completedKeys so failed cloud fallback still clears stale door-state claims.
                    lanAnsweredKeys.append(contentsOf: outcome.keys)
                    if !missingKeys.isEmpty {
                        cloudKeys.append(contentsOf: missingKeys)
                    }
                }
            }
            if batchSawLocalNetworkDenied {
                updateLocalNetworkDenied(true)
                shouldSweep = false
            }
        }

        var recoveredDids: Set<String> = []
        let sweepPermitted = allowCooldownSweep ? canRunRefreshBroadcastSweep() : canRunBroadcastSweep()
        if (shouldSweep || !cooldownSweepKeysByDid.isEmpty) && !isLocalNetworkDenied && sweepPermitted {
            var seenCandidateDids: Set<String> = []
            var retryKeysByDid: [String: [MiotPropKey]] = [:]
            var candidates: [MiIODeviceCandidate] = []
            for outcome in failedOutcomes where (outcome.error as? MiIOError) != .localNetworkDenied {
                retryKeysByDid[outcome.did] = outcome.keys
                let token = lanBindingsByDid[outcome.did]?.token ?? recordByDid[outcome.did]?.token ?? ""
                if seenCandidateDids.insert(outcome.did).inserted, MiIOPacket.validateToken(token) != nil {
                    candidates.append(MiIODeviceCandidate(did: outcome.did, token: token))
                }
            }
            for did in cooldownSweepKeysByDid.keys.sorted() {
                if let cooldownKeys = cooldownSweepKeysByDid[did], retryKeysByDid[did] == nil {
                    retryKeysByDid[did] = cooldownKeys
                }
                let token = lanBindingsByDid[did]?.token ?? recordByDid[did]?.token ?? ""
                if seenCandidateDids.insert(did).inserted, MiIOPacket.validateToken(token) != nil {
                    candidates.append(MiIODeviceCandidate(did: did, token: token))
                }
            }
            if !candidates.isEmpty {
                let sweepTimestamp = now()
                lastBroadcastSweepAt = sweepTimestamp
                if allowCooldownSweep {
                    lastRefreshBroadcastSweepAt = sweepTimestamp
                }
                let candidateDidSet = Set(candidates.map(\.did))
                let excludedIPs = Set(pollLanTransportSucceededDids.compactMap { lanEndpoints[$0]?.ip })
                let knownNumericDids = Set(
                    devices.lazy
                        .filter { $0.splitParentDid == nil && !candidateDidSet.contains($0.miotDid) }
                        .compactMap { UInt64($0.miotDid) }
                )
                do {
                    let discovered = try await localClient.discoverEndpoints(
                        for: candidates,
                        excludedIPs: excludedIPs,
                        knownNumericDids: knownNumericDids
                    )
                    if !discovered.isEmpty {
                        applyBroadcastRecoveredEndpoints(discovered)
                        var completedPostSendRetryDids: Set<String> = []
                        for candidate in candidates where discovered[candidate.did] != nil {
                            let did = candidate.did
                            guard let retryKeys = retryKeysByDid[did],
                                  let record = recordByDid[did],
                                  let endpoint = lanEndpoint(for: record) else { continue }
                            do {
                                let retryValues = try await localClient.getProps(retryKeys, endpoint: endpoint)
                                completedPostSendRetryDids.insert(did)
                                recordLANSuccess(did: did, rttMs: await localClient.lastRoundTripMs(for: did))
                                pollLanTransportSucceededDids.insert(did)
                                if !retryValues.isEmpty || retryKeys.isEmpty {
                                    pollLanSucceededDids.insert(did)
                                }
                                recoveredDids.insert(did)
                                if !retryValues.isEmpty { combined.merge(retryValues) { _, new in new } }
                                lanAnsweredKeys.append(contentsOf: retryKeys)
                                cloudKeys.append(contentsOf: retryKeys.filter { retryValues[$0] == nil })
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                if (error as? MiIOError) == .localNetworkDenied {
                                    for remaining in candidates where !completedPostSendRetryDids.contains(remaining.did) {
                                        recordLANFailure(did: remaining.did, error: MiIOError.localNetworkDenied)
                                    }
                                    updateLocalNetworkDenied(true)
                                    break
                                }
                                if MiIOError.provesPacketCrossedPermissionBoundary(error) {
                                    completedPostSendRetryDids.insert(did)
                                }
                                recordLANFailure(did: did, error: error)
                            }
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as MiIOError where error == .shutDown { throw error }
                catch let error as MiIOError where error == .localNetworkDenied {
                    for candidate in candidates {
                        recordLANFailure(did: candidate.did, error: MiIOError.localNetworkDenied)
                    }
                    updateLocalNetworkDenied(true)
                }
                catch { logger.debug("LAN broadcast sweep failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        for outcome in failedOutcomes where !recoveredDids.contains(outcome.did) {
            cloudKeys.append(contentsOf: outcome.keys)
        }
        for (did, cooldownKeys) in cooldownSweepKeysByDid where !recoveredDids.contains(did) {
            cloudKeys.append(contentsOf: cooldownKeys)
        }

        if !cloudKeys.isEmpty {
            if cloudAllowed {
                do {
                    let cloudValues = try await performCloudCall {
                        try await api.getProps(cloudKeys)
                    }
                    clearCloudBackoff()
                    combined.merge(cloudValues) { _, new in new }
                } catch is CancellationError {
                    throw CancellationError()
                } catch MiCloudError.sessionExpired {
                    throw MiCloudError.sessionExpired
                } catch {
                    scheduleCloudBackoff(for: error)
                    if combined.isEmpty && lanAnsweredKeys.isEmpty && pollLanSucceededDids.isEmpty {
                        throw error
                    }
                    return HybridPropReadOutcome(
                        values: combined,
                        completedKeys: lanAnsweredKeys,
                        lanSucceededDids: pollLanSucceededDids,
                        lanTransportSucceededDids: pollLanTransportSucceededDids,
                        cloudError: error
                    )
                }
            } else {
                if combined.isEmpty && lanAnsweredKeys.isEmpty && pollLanSucceededDids.isEmpty {
                    if let lastCloudError {
                        throw lastCloudError
                    }
                }
                return HybridPropReadOutcome(
                    values: combined,
                    completedKeys: lanAnsweredKeys,
                    lanSucceededDids: pollLanSucceededDids,
                    lanTransportSucceededDids: pollLanTransportSucceededDids,
                    cloudError: lastCloudError
                )
            }
        }
        return HybridPropReadOutcome(
            values: combined,
            completedKeys: keys,
            lanSucceededDids: pollLanSucceededDids,
            lanTransportSucceededDids: pollLanTransportSucceededDids,
            cloudError: nil
        )
    }

    // MARK: - Hybrid LAN Eligibility & Cooldown

    private func persistTopologyIfNeeded() {
        guard let topologyCache, let session else { return }
        if devices.isEmpty {
            topologyCache.remove(accountID: MiAccount(session: session).id)
            lastSavedTopology = nil
            return
        }
        var discoveredIPs: [String: String] = [:]
        for record in devices where record.splitParentDid == nil {
            let did = record.miotDid
            if let b = lanBindingsByDid[did], b.usedBroadcastRecovery, let ip = b.discoveredIP, LocalMiIOClient.isPrivateRFC1918IPv4(ip) {
                discoveredIPs[did] = ip
            }
        }
        guard lastSavedTopology?.devices != devices || lastSavedTopology?.rooms != rooms
            || lastSavedTopology?.groupMembersByGroup != groupMembersByGroup
            || lastSavedTopology?.discoveredLANIPsByDid != discoveredIPs else { return }
        let snapshot = CachedMiTopology(savedAt: now(), devices: devices, rooms: rooms, groupMembersByGroup: groupMembersByGroup, discoveredLANIPsByDid: discoveredIPs)
        topologyCache.save(snapshot, for: session)
        lastSavedTopology = snapshot
    }

    private func canRunBroadcastSweep() -> Bool {
        lastBroadcastSweepAt.map { now().timeIntervalSince($0) >= broadcastSweepMinInterval } ?? true
    }

    private func canRunRefreshBroadcastSweep() -> Bool {
        lastRefreshBroadcastSweepAt.map { now().timeIntervalSince($0) >= broadcastSweepMinInterval } ?? true
    }

    private func applyBroadcastRecoveredEndpoints(_ discovered: [String: String]) {
        for (did, newIP) in discovered where LocalMiIOClient.isPrivateRFC1918IPv4(newIP) {
            if var binding = lanBindingsByDid[did] {
                binding.discoveredIP = newIP; lanBindingsByDid[did] = binding
            } else if let record = devices.first(where: { $0.miotDid == did && $0.splitParentDid == nil }) ?? devices.first(where: { $0.miotDid == did }),
                      let token = record.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                lanBindingsByDid[did] = LANEndpointBinding(cloudIP: record.localIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", discoveredIP: newIP, token: token)
            }
            lanHealthByDid[did] = LANHealthState()
        }
        persistTopologyIfNeeded()
    }

    private func updateLocalNetworkDenied(_ denied: Bool) {
        if !denied {
            for (did, var state) in lanHealthByDid where state.lastErrorWasLocalNetworkDenied {
                state.cooldownUntil = nil; state.lastErrorWasLocalNetworkDenied = false; lanHealthByDid[did] = state
            }
        }
        guard isLocalNetworkDenied != denied else { return }
        isLocalNetworkDenied = denied
        continuation?.yield(.localNetworkPermissionChanged(denied ? [.xiaomiLAN] : []))
    }

    private func prepareLocalNetworkRetryOnRefresh() {
        guard isLocalNetworkDenied else { return }
        for (did, var state) in lanHealthByDid where state.cooldownUntil != nil {
            state.cooldownUntil = nil
            lanHealthByDid[did] = state
        }
    }

    private func reconcileLANEndpoints(_ records: [MiDeviceRecord], seededDiscoveredIPs: [String: String] = [:]) {
        sharedHomeDids = Set(rooms.lazy.filter(\.isSharedHome).flatMap(\.dids))
        let activeDids = Set(records.map(\.miotDid))
        for did in Array(lanBindingsByDid.keys) where !activeDids.contains(did) {
            lanBindingsByDid.removeValue(forKey: did)
            lanHealthByDid.removeValue(forKey: did)
        }
        for record in records where record.splitParentDid == nil {
            let did = record.miotDid
            let ip = record.localIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = record.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                lanBindingsByDid.removeValue(forKey: did); lanHealthByDid.removeValue(forKey: did); continue
            }
            let seeded = seededDiscoveredIPs[did]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validSeeded = (seeded.map(LocalMiIOClient.isPrivateRFC1918IPv4) == true && seeded != ip) ? seeded : nil
            if var binding = lanBindingsByDid[did] {
                if binding.reconcile(newCloudIP: ip, newToken: token) { lanHealthByDid.removeValue(forKey: did) }
                if let validSeeded, binding.discoveredIP == nil { binding.discoveredIP = validSeeded }
                lanBindingsByDid[did] = binding
            } else {
                lanBindingsByDid[did] = LANEndpointBinding(cloudIP: ip, discoveredIP: validSeeded, token: token)
            }
        }
    }

    private func lanEligibleEndpointIgnoringCooldown(for record: MiDeviceRecord) -> MiIODeviceEndpoint? {
        let binding = lanBindingsByDid[record.miotDid]
        guard localClient != nil,
              record.isOnline,
              !record.isShared,
              !sharedHomeDids.contains(record.did),
              !sharedHomeDids.contains(record.miotDid),
              record.splitParentDid == nil,
              !record.did.hasPrefix("group."),
              let ip = (binding?.effectiveIP ?? record.localIp)?.trimmingCharacters(in: .whitespacesAndNewlines),
              LocalMiIOClient.isPrivateRFC1918IPv4(ip),
              let token = (binding?.token ?? record.token)?.trimmingCharacters(in: .whitespacesAndNewlines),
              MiIOPacket.validateToken(token) != nil else {
            return nil
        }
        return MiIODeviceEndpoint(did: record.miotDid, ip: ip, token: token)
    }

    private func lanEndpoint(for record: MiDeviceRecord) -> MiIODeviceEndpoint? {
        guard let endpoint = lanEligibleEndpointIgnoringCooldown(for: record) else { return nil }
        if let cooldownUntil = lanHealthByDid[record.miotDid]?.cooldownUntil, now() < cooldownUntil {
            return nil
        }
        return endpoint
    }

    private func recordLANSuccess(did: String, rttMs: Int? = nil, allowClearingDenied: Bool = true) {
        let quantized = rttMs.map(DeviceTransportDiagnostics.quantizeRTT) ?? lanHealthByDid[did]?.lastRTTMs
        lanHealthByDid[did] = LANHealthState(consecutiveFailures: 0, cooldownUntil: nil, lastRTTMs: quantized, lastErrorWasLocalNetworkDenied: false)
        lanTransportSucceededDids.insert(did)
        if allowClearingDenied, isLocalNetworkDenied { updateLocalNetworkDenied(false) }
    }

    private func recordLANFailure(
        did: String,
        error: any Error,
        allowClearingDenied: Bool = true,
        batchSawLocalNetworkDenied: Bool = false
    ) {
        var state = lanHealthByDid[did] ?? LANHealthState()
        let crossedPermissionBoundary = MiIOError.provesPacketCrossedPermissionBoundary(error)
        let isDenied = (error as? MiIOError) == .localNetworkDenied
            || (batchSawLocalNetworkDenied && !crossedPermissionBoundary)
        if isDenied {
            state.lastErrorWasLocalNetworkDenied = true
            state.cooldownUntil = nil
            updateLocalNetworkDenied(true)
        } else {
            if allowClearingDenied, isLocalNetworkDenied, crossedPermissionBoundary {
                updateLocalNetworkDenied(false)
            }
            if !isLocalNetworkDenied || crossedPermissionBoundary {
                state.lastErrorWasLocalNetworkDenied = false
            }
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= lanFailureThreshold {
                state.cooldownUntil = now().addingTimeInterval(lanCooldownDuration)
                logger.notice("LAN cooldown activated for \(did, privacy: .public) after \(state.consecutiveFailures, privacy: .public) failures: \(error.localizedDescription, privacy: .public)")
            }
        }
        lanHealthByDid[did] = state
        lanSucceededDids.remove(did)
        lanTransportSucceededDids.remove(did)
    }

    // MARK: - MIoT Doorbell Event Bridging

    static func doorbellEventTarget(for spec: MiotDeviceSpec) -> (siid: Int, eiid: Int)? {
        let prioritized = spec.services(named: "video-doorbell")
            + spec.services(named: "doorbell")
            + spec.services.filter { !["video-doorbell", "doorbell"].contains($0.shortName) }
        for service in prioritized {
            if let event = service.events.first(where: { ["doorbell-ring", "doorbell-press"].contains($0.shortName) }) {
                return (service.iid, event.iid)
            }
        }
        return nil
    }

    private func pollDoorbellEvents(_ api: any MiCloudAPI, scopedDevices: [MiDeviceRecord]) async throws {
        var seenTrackerKeys: Set<String> = []
        for record in scopedDevices where record.isOnline {
            guard let spec = specsByModel[record.model],
                  let target = Self.doorbellEventTarget(for: spec) else { continue }
            let eventKey = "\(target.siid).\(target.eiid)"
            let trackerKey = "\(record.miotDid)#\(eventKey)"
            guard seenTrackerKeys.insert(trackerKey).inserted else { continue }

            let currentNow = now()
            do {
                if let baseline = doorbellBaselineTime[trackerKey] {
                    let querySince = (lastDoorbellTimestamp[trackerKey] ?? baseline).addingTimeInterval(-1)
                    let latest = try await performCloudCall {
                        try await api.doorbellLatestEventTimestamp(
                            did: record.miotDid,
                            eventKey: eventKey,
                            since: querySince,
                            now: currentNow
                        )
                    }
                    doorbellBaselineTime[trackerKey] = currentNow
                    if let latest {
                        let isNewRing: Bool
                        if let previous = lastDoorbellTimestamp[trackerKey] {
                            isNewRing = latest > previous
                        } else {
                            isNewRing = latest > baseline
                        }
                        if isNewRing {
                            lastDoorbellTimestamp[trackerKey] = latest
                            let ring = DoorbellRing(
                                deviceId: record.did,
                                entityId: "miot-event:\(record.miotDid):\(target.siid):\(target.eiid)",
                                firedAt: Self.iso8601String(from: latest)
                            )
                            continuation?.yield(.doorbellRang(ring))
                        }
                    }
                } else {
                    let initialSince = currentNow.addingTimeInterval(-3600)
                    let latest = try await performCloudCall {
                        try await api.doorbellLatestEventTimestamp(
                            did: record.miotDid,
                            eventKey: eventKey,
                            since: initialSince,
                            now: currentNow
                        )
                    }
                    if let latest {
                        lastDoorbellTimestamp[trackerKey] = latest
                    }
                    doorbellBaselineTime[trackerKey] = currentNow
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                logger.notice("Doorbell event query failed for \(record.miotDid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Successful reads replace cached values. A requested `door-state` that this round did not
    /// return is removed, so a per-item failure cannot keep rendering the previous security claim.
    static func applyPropRead(
        _ values: inout [MiotPropKey: JSONValue],
        fresh: [MiotPropKey: JSONValue],
        requestedLockKeys: [MiotPropKey]
    ) {
        values.merge(fresh) { _, new in new }
        for key in requestedLockKeys where fresh[key] == nil {
            values.removeValue(forKey: key)
        }
    }

    private func doorStateKeys(requested: [MiotPropKey]) -> [MiotPropKey] {
        let requestedSet = Set(requested)
        var keys: [MiotPropKey] = []
        for device in devices {
            guard let spec = specsByModel[device.model] else { continue }
            for key in MiotSynthesizer.doorStateKeys(for: device, spec: spec) where requestedSet.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private func propKeys(of scoped: [MiDeviceRecord], dids: Set<String>?) -> [MiotPropKey] {
        var keys: [MiotPropKey] = []
        for d in scoped where d.isOnline && (dids?.contains(d.miotDid) ?? true) {
            guard let spec = specsByModel[d.model] else { continue }
            keys.append(contentsOf: MiotSynthesizer.requiredProps(for: d, spec: spec))
            keys.append(contentsOf: MiotSynthesizer.facetProps(for: d, spec: spec))
        }
        return keys
    }

    private func hasValuesForScope() -> Bool {
        propKeys(of: scopedDevicesAndRooms().devices, dids: nil).allSatisfy { values[$0] != nil }
    }

    /// The selected home's rooms and devices, plus parents of included split keys so their spec and
    /// values stay available. Everything when no (known) home is selected.
    private func scopedDevicesAndRooms() -> (devices: [MiDeviceRecord], rooms: [MiRoom]) {
        guard let selected = selectedHomeLoader() else {
            return (devices, rooms)
        }
        if selected == Self.otherAccountHomeSentinel {
            return ([], [])
        }
        guard Self.homeOptions(from: rooms).contains(where: { $0.id == selected }) else {
            return (devices, rooms)
        }
        let visibleRooms = rooms.filter { $0.homeId == selected }
        let dids = Set(visibleRooms.flatMap(\.dids))
        var visibleDevices = devices.filter { dids.contains($0.did) || ($0.splitParentDid.map(dids.contains) ?? false) }
        let parents = Set(visibleDevices.compactMap(\.splitParentDid))
        let includedIds = Set(visibleDevices.map(\.did))
        visibleDevices += devices.filter { parents.contains($0.did) && !includedIds.contains($0.did) }
        return (visibleDevices, visibleRooms)
    }

    /// UserDefaults key for the selected Mi Home id; absent or unknown means every home.
    public static let selectedHomeKey = "mi_selected_home_id"
    /// Returned to child providers when the user picked a home that belongs to another signed-in account.
    static let otherAccountHomeSentinel = "__other_account_home__"
    /// MIoT per-item code for "property not supported by this device".
    static let propertyUnsupportedCode = -704002000

    private func emitSnapshot(closesAwayGap: Bool = true) {
        let (visibleDevices, visibleRooms) = scopedDevicesAndRooms()
        let cloudBackingOff = cloudRetryNotBefore != nil
        let synthDevices: [MiDeviceRecord]
        if cloudBackingOff {
            synthDevices = visibleDevices.map { record in
                guard !lanSucceededDids.contains(record.miotDid),
                      !everObservedPropDids.contains(record.miotDid) else {
                    return record
                }
                var copy = record
                copy.isOnline = false
                return copy
            }
        } else {
            synthDevices = visibleDevices
        }
        var home = MiotSynthesizer.synthesize(
            devices: synthDevices,
            rooms: visibleRooms,
            specs: specsByModel,
            values: values
        )
        home.closesAwayGap = closesAwayGap
        home.homes = Self.homeOptions(from: rooms)
        home.lightGroupOwners = Self.deviceGroupOwners(membersByGroup: groupMembersByGroup, devices: visibleDevices)
        home.localNetworkBlockedFeatures = isLocalNetworkDenied ? [.xiaomiLAN] : []
        DeviceSynthesizer.reconcileLightGroups(&home)
        let currentNow = now()
        // Light groups advertise `mode` but their members reject it; hide scenes there too.
        for i in home.devices.indices {
            let recordMiotDid = visibleDevices.first(where: { $0.did == home.devices[i].id })?.miotDid
            let candidateDids = ([recordMiotDid].compactMap { $0 })
                + home.devices[i].miotCommandDids
                + [home.devices[i].id]
            let primaryMiotDid = recordMiotDid ?? home.devices[i].miotCommandDids.first ?? home.devices[i].id
            let health = lanHealthByDid[primaryMiotDid]
            let route: DeviceTransportRoute = if health?.lastErrorWasLocalNetworkDenied == true { .localNetworkBlocked }
                else if let cooldownUntil = health?.cooldownUntil, currentNow < cooldownUntil { .cooldown }
                else if candidateDids.contains(where: { lanTransportSucceededDids.contains($0) }) { .lan }
                else { .cloud }
            home.deviceTransportDiagnostics[home.devices[i].id] = DeviceTransportDiagnostics(
                route: route, rttMs: route == .lan ? health?.lastRTTMs : nil,
                consecutiveFailures: health?.consecutiveFailures ?? 0,
                usedBroadcastRecovery: lanBindingsByDid[primaryMiotDid]?.usedBroadcastRecovery ?? false
            )
            if cloudBackingOff {
                if !candidateDids.contains(where: { lanSucceededDids.contains($0) }) {
                    home.devices[i].telemetryStale = true
                }
            }
            guard case .light(var spec) = home.devices[i].kind,
                  home.devices[i].id.hasPrefix("group.") || effectsUnsupported.contains(home.devices[i].id) else { continue }
            spec.availableEffects = []
            home.devices[i].kind = .light(spec)
        }
        continuation?.yield(.snapshotUpdated(stamp(home)))
    }

    /// Namespaces room/home ids and tags devices with the account, so several accounts can be merged
    /// into one panel without id collisions. Device ids stay raw: MIoT calls address the did.
    private func stamp(_ home: SynthesizedHome) -> SynthesizedHome {
        guard let account else { return home }
        let prefix = "\(account.id)/"
        var stamped = home
        for i in stamped.rooms.indices {
            let room = stamped.rooms[i]
            stamped.rooms[i] = RoomArea(id: prefix + room.id, name: room.name, sortOrder: room.sortOrder)
        }
        for i in stamped.devices.indices {
            stamped.devices[i].roomId = prefix + stamped.devices[i].roomId
            stamped.devices[i].accountId = account.id
            stamped.devices[i].accountLabel = account.maskedUserId
        }
        for i in stamped.homes.indices {
            stamped.homes[i].id = prefix + stamped.homes[i].id
            stamped.homes[i].accountId = account.id
            stamped.homes[i].accountLabel = account.maskedUserId
        }
        return stamped
    }

    static func homeOptions(from rooms: [MiRoom]) -> [HomeOption] {
        var order: [String] = []
        var names: [String: String] = [:]
        var shared: [String: Bool] = [:]
        var didsByHome: [String: Set<String>] = [:]
        for room in rooms where !room.homeId.isEmpty {
            if names[room.homeId] == nil {
                order.append(room.homeId)
                names[room.homeId] = room.homeName
                shared[room.homeId] = room.isSharedHome
            }
            didsByHome[room.homeId, default: []].formUnion(room.dids)
        }
        return order.map {
            HomeOption(
                id: $0,
                name: names[$0] ?? "",
                deviceCount: didsByHome[$0]?.count ?? 0,
                isSharedHome: shared[$0] ?? false
            )
        }
    }

    // MARK: Commands

    func mapsToAction(_ command: DeviceCommand) -> Bool {
        let entityId = command.targetEntityId
        guard let did = MiotAddress.parseAction(entityId)?.did ?? MiotAddress.parse(entityId)?.did,
              let record = devices.first(where: { $0.did == did && $0.splitParentDid == nil })
                  ?? devices.first(where: { $0.did == did })
                  ?? devices.first(where: { $0.miotDid == did && $0.splitParentDid == nil })
                  ?? devices.first(where: { $0.miotDid == did }),
              let spec = specsByModel[record.model],
              let write = try? MiotCommandMapper.map(command, spec: spec) else {
            return !command.isIdempotentForAccountFallback
        }
        switch write {
        case .action:
            return true
        case .setProps:
            return false
        }
    }

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let (did, _) = MiotAddress.parse(entityId) else { throw MiotCommandError.invalidAddress(entityId) }
        guard let api else { throw MiCloudError.notLoggedIn }
        guard let record = devices.first(where: { $0.did == did && $0.splitParentDid == nil })
            ?? devices.first(where: { $0.did == did })
            ?? devices.first(where: { $0.miotDid == did && $0.splitParentDid == nil })
            ?? devices.first(where: { $0.miotDid == did }),
              let spec = specsByModel[record.model] else {
            throw MiotCommandError.unsupported("设备规格未加载")
        }
        let write = try MiotCommandMapper.map(command, spec: spec)
        var executedViaLAN = false
        if !isLocalNetworkDenied, let localClient, let endpoint = lanEndpoint(for: record) {
            do {
                switch write {
                case .setProps(let writes):
                    try await localClient.setProps(writes, endpoint: endpoint)
                case .action(let call):
                    _ = try await localClient.callAction(call, endpoint: endpoint)
                }
                let rttMs = await localClient.lastRoundTripMs(for: record.miotDid)
                recordLANSuccess(did: record.miotDid, rttMs: rttMs)
                executedViaLAN = true
            } catch MiCloudError.deviceError(let code, let message) {
                if case .setLightEffect = command, code == Self.propertyUnsupportedCode {
                    effectsUnsupported.insert(record.did)
                    emitSnapshot()
                }
                throw MiCloudError.deviceError(code: code, message: message)
            } catch MiIOError.ambiguousActionOutcome {
                recordLANFailure(did: record.miotDid, error: MiIOError.ambiguousActionOutcome)
                scheduleFollowUpPoll(for: record)
                throw MiIOError.ambiguousActionOutcome
            } catch MiIOError.shutDown {
                throw MiIOError.shutDown
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordLANFailure(did: record.miotDid, error: error)
            }
        }

        if !executedViaLAN {
            do {
                try await performCloudCall {
                    switch write {
                    case .setProps(let writes): try await api.setProps(writes)
                    case .action(let call): try await api.action(call)
                    }
                }
            } catch MiCloudError.sessionExpired {
                report(MiCloudError.sessionExpired)
                throw MiCloudError.sessionExpired
            } catch MiCloudError.deviceError(let code, let message) {
                if case .setLightEffect = command, code == Self.propertyUnsupportedCode {
                    effectsUnsupported.insert(record.did)
                    emitSnapshot()
                }
                throw MiCloudError.deviceError(code: code, message: message)
            }
        }

        scheduleFollowUpPoll(for: record)
    }

    private func scheduleFollowUpPoll(for record: MiDeviceRecord) {
        guard !isShutDown else { return }
        let delay = followUpDelay
        // Split cards address `100.s2`; property reads are keyed by the parent `100`.
        let followUpDid = record.miotDid
        let followUpId = UUID()
        let followUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.followUpPoll(did: followUpDid, taskId: followUpId)
        }
        followUpTasks[followUpId] = followUpTask
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard !isShutDown, !isSessionRejected, let api else { return .failed }
        // Split wall-switch cards report `100.s2` while property reads are keyed by `100`.
        guard let record = devices.first(where: { $0.did == deviceId }),
              let spec = specsByModel[record.model],
              let (service, _) = MiotSynthesizer.primary(for: record, spec: spec) else { return .failed }
        let did = record.miotDid
        do {
            // Only a full poll may clear home-wide staleness; this read refreshes one device.
            let outcome = try await pollOutcome(api, dids: [did])
            if let cloudError = outcome.cloudError {
                report(cloudError)
            }
            let powerKeys = service.properties.filter { ["on", "status"].contains($0.shortName) }.map {
                MiotPropKey(did: did, siid: service.iid, piid: $0.iid)
            }
            guard powerKeys.contains(where: { outcome.freshKeys.contains($0) }) else { return .failed }
            return .published
        } catch {
            report(error)
            return .failed
        }
    }

    private func followUpPoll(did: String, taskId: UUID) async {
        followUpTasks.removeValue(forKey: taskId)
        guard !isShutDown, !isSessionRejected, let api else { return }
        _ = try? await poll(api, dids: [did])
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard !isShutDown, let api else { return [] }
        let record = devices.first { $0.did == deviceId } ?? devices.first { $0.miotDid == deviceId }
        let did = record?.miotDid ?? deviceId
        let keys: (temperature: String?, humidity: String?)
        if let record, let spec = specsByModel[record.model] {
            keys = MiotSynthesizer.sensorPropertyKeys(for: record, spec: spec)
        } else {
            keys = (nil, nil)
        }
        do {
            return try await performCloudCall {
                try await api.sensorHistory(
                    did: did,
                    temperatureKey: keys.temperature,
                    humidityKey: keys.humidity,
                    window: window,
                    now: now
                )
            }
        } catch MiCloudError.sessionExpired {
            report(MiCloudError.sessionExpired)
            return []
        } catch {
            logger.notice("Sensor history fetch failed for \(did, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Camera Live Stream Resolution

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .sd)
    }

    public func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality, channel: 0)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        guard case .camera(let cameraSpec) = device.kind else {
            throw MiotCommandError.unsupported("camera")
        }
        try Task.checkCancellation()
        if isSessionRejected { throw MiCloudError.sessionExpired }
        var failureReason: String?
        if let api,
           let record = devices.first(where: { $0.did == device.id }) ?? devices.first(where: { $0.miotDid == device.id }),
           let spec = specsByModel[record.model] {
            let did = record.miotDid
            if CameraHubCatalog.isHub(model: record.model) {
                throw HomeProviderError.serviceCallFailed(
                    501,
                    L10n.tr(
                        "这是电池摄像机的室内机中继底座，不提供实时画面；请在机位条选择对应的摄像机",
                        "This is the indoor hub for a battery camera and has no live video. Select the camera in the camera rail."
                    )
                )
            }
            let hub = Self.hubRecord(for: record, devices: devices, rooms: rooms)
            if CameraHubCatalog.hubModel(for: record.model) != nil, hub == nil {
                throw HomeProviderError.serviceCallFailed(
                    501,
                    L10n.tr(
                        "找不到这台电池摄像机的室内机中继。请确认室内机在线后重试",
                        "Could not find the indoor hub for this battery camera. Make sure the hub is online and retry."
                    )
                )
            }
            let bridgeRecord = hub ?? record
            let bridgeDid = bridgeRecord.miotDid
            let subdid = hub == nil ? nil : record.did
            if let pending = pendingCameraReleases[did] {
                await pending.value
                if pendingCameraReleases[did] == pending {
                    pendingCameraReleases.removeValue(forKey: did)
                }
            }
            try Task.checkCancellation()
            let streamService: MiotService? = {
                if let streamId = cameraSpec.streamEntityId,
                   let (_, siid) = MiotAddress.parse(streamId),
                   let svc = spec.service(iid: siid),
                   svc.action(named: "start-hls-stream") != nil {
                    return svc
                }
                return spec.services(named: "camera-stream-for-google-home").first { $0.action(named: "start-hls-stream") != nil }
            }()
            if channel == 0,
               hub == nil,
               let svc = streamService,
               let act = svc.action(named: "start-hls-stream") {
                if let result = try? await api.callAction(MiotActionCall(did: did, siid: svc.iid, aiid: act.iid, inputs: [])),
                   let url = Self.extractStreamURL(from: result) {
                    try Task.checkCancellation()
                    return .hls(url)
                }
                try Task.checkCancellation()
                if let result = try? await api.callAction(MiotActionCall(did: did, siid: svc.iid, aiid: act.iid, inputs: [.number(1)])),
                   let url = Self.extractStreamURL(from: result) {
                    try Task.checkCancellation()
                    return .hls(url)
                }
            }
            try Task.checkCancellation()

            var startedP2PSession = false
            let abortIfCancelled = { () async throws in
                if Task.isCancelled {
                    if startedP2PSession {
                        await self.stopCameraStream(for: device)
                    }
                    throw CancellationError()
                }
            }

            // Private CS2/TUTK P2P camera stream (e.g. chuangmi.camera.061a01, isa.camera.*)
            if let p2pService = spec.services.first(where: { $0.action(named: "start-p2p-stream") != nil }) {
                if let stopAct = p2pService.action(named: "stop-stream") {
                    if (try? await api.callAction(MiotActionCall(did: did, siid: p2pService.iid, aiid: stopAct.iid, inputs: []))) != nil {
                        try? await Task.sleep(for: cameraSessionReleaseDelay)
                    }
                }
                try Task.checkCancellation()
                if let startAct = p2pService.action(named: "start-p2p-stream") {
                    if (try? await api.callAction(MiotActionCall(did: did, siid: p2pService.iid, aiid: startAct.iid, inputs: []))) != nil {
                        startedP2PSession = true
                    }
                }
            }
            try await abortIfCancelled()

            let resolvedIP: String = await {
                let cached = bridgeRecord.localIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !cached.isEmpty { return cached }
                let fetched = try? await api.cameraLocalIP(did: bridgeDid)
                return fetched?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }()
            try await abortIfCancelled()

            if !resolvedIP.isEmpty {
                let kp = XiaomiCameraBridge.makeX25519KeyPair()
                if let vendor = try? await api.cameraP2PVendor(did: bridgeDid, appPublicKey: kp.publicKeyHex),
                   !vendor.devicePublicKey.isEmpty,
                   !vendor.sign.isEmpty {
                    try await abortIfCancelled()
                    let endpoints: XiaomiCameraStreamEndpoints?
                    do {
                        endpoints = try await cameraBridge.startBridge(
                            did: bridgeDid,
                            model: bridgeRecord.model,
                            localIP: resolvedIP,
                            clientPublic: kp.publicKeyHex,
                            clientPrivate: kp.privateKeyHex,
                            devicePublic: vendor.devicePublicKey,
                            sign: vendor.sign,
                            vendor: vendor.vendorName,
                            uid: vendor.p2pId,
                            quality: quality,
                            channel: channel,
                            subdid: subdid
                        )
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            await stopCameraStream(for: device)
                            throw CancellationError()
                        }
                        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        failureReason = detail
                        logger.error("Xiaomi camera P2P bridge failed for \(did, privacy: .public): \(detail, privacy: .public)")
                        endpoints = nil
                    }
                    if let endpoints {
                        if Task.isCancelled {
                            await stopCameraStream(for: device)
                            throw CancellationError()
                        }
                        cameraBridgeBindings[did] = (did: bridgeDid, subdid: subdid)
                        let capability = CameraPTZCapability.resolve(
                            model: bridgeRecord.model,
                            vendor: vendor.vendorName
                        )
                        let binding = capability.map {
                            CameraPTZBinding(
                                capability: $0,
                                streamName: XiaomiCameraBridge.rawStreamName(
                                    cleanDid: XiaomiCameraBridge.streamKey(
                                        cleanDid: XiaomiCameraBridge.sanitizeDid(bridgeDid),
                                        subdid: subdid
                                    ),
                                    channel: channel
                                )
                            )
                        }
                        return .liveMP4(endpoints.mp4, mjpegFallback: endpoints.mjpeg, ptz: binding)
                    }
                } else {
                    failureReason = L10n.tr(
                        "该摄像机型号（\(record.model)）未返回受支持的局域网 P2P 加密协商参数，暂无法直连解码；可通过 Home Assistant 接入或点击右上角 🔗 填写流地址",
                        "Camera model (\(record.model)) did not return supported LAN P2P parameters; connect via Home Assistant or click 🔗 to set a custom stream URL"
                    )
                }
            } else {
                failureReason = L10n.tr(
                    "未能获取摄像机（\(record.model)）的局域网 IP 地址，请确认电脑与摄像机连接在同一路由器/局域网下后重试",
                    "Could not obtain LAN IP for camera (\(record.model)). Ensure your Mac and camera are on the same local network and retry"
                )
            }
            if startedP2PSession {
                await stopCameraStream(for: device)
            }
            try await abortIfCancelled()
        }

        try Task.checkCancellation()
        if let localURL = await probeLocalGo2RTC(for: device) {
            try Task.checkCancellation()
            return .hls(localURL)
        }

        throw HomeProviderError.serviceCallFailed(
            501,
            failureReason ?? L10n.tr(
                "米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址，或接入 Home Assistant 观看实时画面",
                "Xiaomi Cloud cameras use private P2P streaming; enter a local go2rtc / HLS URL below or connect via Home Assistant"
            )
        )
    }

    public func stopCameraStream(for device: SmartDevice) async {
        let record = devices.first(where: { $0.did == device.id }) ?? devices.first(where: { $0.miotDid == device.id })
        let did = record?.miotDid ?? device.id
        let saved = cameraBridgeBindings.removeValue(forKey: did)
        let hub = record.flatMap { Self.hubRecord(for: $0, devices: devices, rooms: rooms) }
        let bridgeDid = saved?.did ?? hub?.miotDid ?? did
        let subdid: String?
        if let saved {
            subdid = saved.subdid
        } else {
            subdid = hub == nil ? nil : record?.did
        }
        let bridge = cameraBridge
        let apiClient = api
        let releaseDelay = cameraSessionReleaseDelay
        let stopCall: MiotActionCall? = {
            guard let record,
                  let spec = specsByModel[record.model],
                  let p2pService = spec.services.first(where: { $0.action(named: "stop-stream") != nil }),
                  let stopAct = p2pService.action(named: "stop-stream") else {
                return nil
            }
            return MiotActionCall(did: did, siid: p2pService.iid, aiid: stopAct.iid, inputs: [])
        }()
        let previousRelease = pendingCameraReleases[did]
        let releaseTask = Task<Void, Never> {
            await previousRelease?.value
            await bridge.stopBridge(did: bridgeDid, subdid: subdid)
            if let apiClient, let stopCall {
                _ = try? await apiClient.callAction(stopCall)
                try? await Task.sleep(for: releaseDelay)
            }
        }
        pendingCameraReleases[did] = releaseTask
        await releaseTask.value
        if pendingCameraReleases[did] == releaseTask {
            pendingCameraReleases.removeValue(forKey: did)
        }
    }

    static func hubRecord(
        for record: MiDeviceRecord,
        devices: [MiDeviceRecord],
        rooms: [MiRoom]
    ) -> MiDeviceRecord? {
        guard let hubModel = CameraHubCatalog.hubModel(for: record.model) else { return nil }
        let hubs = devices.filter { $0.model.lowercased().hasPrefix(hubModel) }
        guard !hubs.isEmpty else { return nil }
        let hubDids = Set(hubs.map(\.did))
        let cameraRooms = rooms.filter { $0.dids.contains(record.did) }
        // A camera can sit in an earlier room that has no hub. That room must not hide
        // the later room that actually contains the indoor base.
        let cameraRoom = cameraRooms.first { room in
            room.dids.contains { hubDids.contains($0) }
        } ?? cameraRooms.first

        let scoped: [MiDeviceRecord]
        if let cameraRoom, !cameraRoom.homeId.isEmpty {
            let homeDids = Set(rooms.filter { $0.homeId == cameraRoom.homeId }.flatMap(\.dids))
            scoped = hubs.filter { homeDids.contains($0.did) }
        } else if hubs.count == 1 {
            scoped = hubs
        } else if let cameraRoom {
            scoped = hubs.filter { cameraRoom.dids.contains($0.did) }
        } else {
            scoped = []
        }

        let online = scoped.filter(\.isOnline)
        if let cameraRoom {
            let sameRoom = online.filter { cameraRoom.dids.contains($0.did) }
            if sameRoom.count > 1 { return nil }
            if let only = sameRoom.first { return only }
        }
        guard scoped.count == 1 else { return nil }
        return online.first
    }

    public static func extractStreamURL(from value: JSONValue) -> URL? {
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
               let url = URL(string: trimmed) {
                return url
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = extractStreamURL(from: item) { return found }
            }
            return nil
        case .object(let dict):
            if let out = dict["out"], let found = extractStreamURL(from: out) { return found }
            if let addr = dict["stream_address"], let found = extractStreamURL(from: addr) { return found }
            if let val = dict["value"], let found = extractStreamURL(from: val) { return found }
            for v in dict.values {
                if let found = extractStreamURL(from: v) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private func probeLocalGo2RTC(for device: SmartDevice) async -> URL? {
        await cameraBridge.probeRegisteredStream(candidates: [device.id, device.name, device.model])
    }
}
