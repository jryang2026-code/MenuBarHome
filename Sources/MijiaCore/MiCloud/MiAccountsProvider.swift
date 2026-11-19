import Foundation

/// `HomeProvider` over several Xiaomi accounts: one `MiCloudProvider` per account, merged into one
/// panel listing whose devices and homes carry the account they came from.
public actor MiAccountsProvider: HomeProvider {
    private enum ScopedSelection: Equatable, Sendable {
        case allHomes
        case home(String)

        var rawValue: String? {
            switch self {
            case .allHomes: return nil
            case .home(let id): return id
            }
        }
    }

    private final class AccountScopeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var firstId: String?
        private var knownIds: Set<String>
        private var lastResolved: [String: ScopedSelection] = [:]

        init(accounts: [MiAccount]) {
            self.firstId = accounts.first?.id
            self.knownIds = Set(accounts.map(\.id))
        }

        func update(accounts: [MiAccount], removing removedIds: Set<String> = []) {
            lock.withLock {
                firstId = accounts.first?.id
                let nextIds = Set(accounts.map(\.id))
                knownIds = nextIds
                lastResolved = lastResolved.filter { nextIds.contains($0.key) && !removedIds.contains($0.key) }
            }
        }

        func resolve(for accountId: String, rawSelection: String?) -> String? {
            lock.withLock {
                let resolved = Self.compute(
                    rawSelection: rawSelection,
                    accountId: accountId,
                    firstId: firstId,
                    knownIds: knownIds
                )
                lastResolved[accountId] = resolved
                return resolved.rawValue
            }
        }

        func hasSelectionChanged(for accountId: String, rawSelection: String?) -> Bool {
            lock.withLock {
                guard let previous = lastResolved[accountId] else { return false }
                let current = Self.compute(
                    rawSelection: rawSelection,
                    accountId: accountId,
                    firstId: firstId,
                    knownIds: knownIds
                )
                return previous != current
            }
        }

        private static func compute(
            rawSelection: String?,
            accountId: String,
            firstId: String?,
            knownIds: Set<String>
        ) -> ScopedSelection {
            guard let selection = rawSelection, !selection.isEmpty else { return .allHomes }
            guard let ownerId = MiAccountScope.owner(of: selection) else {
                if firstId == accountId { return .home(selection) }
                return knownIds.count > 1 ? .home(MiCloudProvider.otherAccountHomeSentinel) : .allHomes
            }
            guard ownerId == accountId else {
                return knownIds.contains(ownerId) ? .home(MiCloudProvider.otherAccountHomeSentinel) : .allHomes
            }
            let raw = MiAccountScope.localId(of: selection)
            return raw.isEmpty ? .allHomes : .home(raw)
        }
    }

    private var accounts: [MiAccount]
    private let scopeBox: AccountScopeBox
    private let apiFactory: MiCloudProvider.APIFactory
    private let specSource: any MiotSpecSource
    private let cameraBridge: any XiaomiCameraBridging
    private let localClientFactory: @Sendable () -> LocalMiIOClient?
    private let topologyCache: MiTopologyCache?
    private let pollInterval: Duration
    private let closedPollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration
    private let cameraSessionReleaseDelay: Duration
    private let selectedHomeLoader: @Sendable () -> String?
    private let clearSelectedHome: @Sendable () -> Void

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var children: [(account: MiAccount, provider: MiCloudProvider)] = []
    private var forwardTasks: [String: Task<Void, Never>] = [:]
    private var snapshots: [String: SynthesizedHome] = [:]
    private var statuses: [String: ConnectionStatus] = [:]
    private var disconnectedStatuses: [String: ConnectionStatus] = [:]
    /// Accounts that delivered a post-poll snapshot (`closesAwayGap == true`) in the current wake cycle.
    private var freshAccounts: Set<String> = []
    private var expiredAccounts: Set<String> = []
    /// did → owning accounts in account order; a did shared by two accounts keeps its first owner first.
    private var deviceOwners: [String: [String]] = [:]
    private var localNetworkBlocksByAccount: [String: Set<LocalNetworkBlockedFeature>] = [:]
    private var lastLocalNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    private var lastStatus: ConnectionStatus?
    private var pollingContext = PollingContext()
    private var isShutDown = false

    var isShutDownForTesting: Bool { isShutDown }

    func childProviderIdentityForTesting(accountId: String) -> ObjectIdentifier? {
        childProvider(for: accountId).map(ObjectIdentifier.init)
    }

    /// Whether the account is parked as ended: no child polls it until a new scan replaces the session.
    func isExpiredAccountForTesting(_ accountId: String) -> Bool {
        expiredAccounts.contains(accountId)
    }

    public init(
        accounts: [MiAccount],
        apiFactory: @escaping MiCloudProvider.APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        cameraBridge: any XiaomiCameraBridging = XiaomiCameraBridge.shared,
        localClientFactory: @escaping @Sendable () -> LocalMiIOClient? = { LocalMiIOClient() },
        topologyCache: MiTopologyCache? = nil,
        pollInterval: Duration = PollingPolicy.panelOpenInterval,
        closedPollInterval: Duration = PollingPolicy.panelClosedInterval,
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800),
        cameraSessionReleaseDelay: Duration = .milliseconds(2500),
        selectedHomeLoader: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)
        },
        clearSelectedHome: @escaping @Sendable () -> Void = {
            UserDefaults.standard.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
    ) {
        self.accounts = accounts
        self.scopeBox = AccountScopeBox(accounts: accounts)
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.cameraBridge = cameraBridge
        self.localClientFactory = localClientFactory
        self.topologyCache = topologyCache
        self.pollInterval = pollInterval
        self.closedPollInterval = closedPollInterval
        self.deviceRefreshEveryPolls = deviceRefreshEveryPolls
        self.followUpDelay = followUpDelay
        self.cameraSessionReleaseDelay = cameraSessionReleaseDelay
        self.selectedHomeLoader = selectedHomeLoader
        self.clearSelectedHome = clearSelectedHome
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) async {
        guard !isShutDown else {
            cont.finish()
            return
        }
        continuation = cont
        await start()
    }

    public func start() async {
        guard !isShutDown else { return }
        guard !accounts.isEmpty else {
            let disconnected = ConnectionStatus.disconnected(MiCloudError.notLoggedIn.localizedDescription)
            lastStatus = disconnected
            continuation?.yield(.statusChanged(disconnected))
            return
        }
        for account in accounts where account.session.expiryState(at: Date()) == .expired {
            resetSelection(ownedBy: account.id)
        }
        if children.isEmpty { startChildren() }
        await applyPollingContext()
    }

    private func startChildren() {
        guard !isShutDown else { return }
        for account in accounts {
            _ = startChild(for: account)
        }
    }

    @discardableResult
    private func startChild(for account: MiAccount) -> MiCloudProvider {
        if account.session.expiryState(at: Date()) == .expired {
            let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
            expiredAccounts.insert(account.id)
            disconnectedStatuses[account.id] = expiredStatus
            statuses[account.id] = expiredStatus
        }
        let provider = MiCloudProvider(
            account: account,
            apiFactory: apiFactory,
            specSource: specSource,
            cameraBridge: cameraBridge,
            localClient: localClientFactory(),
            topologyCache: topologyCache,
            pollInterval: pollInterval,
            closedPollInterval: closedPollInterval,
            deviceRefreshEveryPolls: deviceRefreshEveryPolls,
            followUpDelay: followUpDelay,
            cameraSessionReleaseDelay: cameraSessionReleaseDelay,
            selectedHomeLoader: scopedSelection(for: account)
        )
        children.append((account: account, provider: provider))
        let stream = provider.events()
        forwardTasks[account.id] = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(event, from: account.id)
            }
        }
        return provider
    }

    public func updateAccounts(_ nextAccounts: [MiAccount]) async {
        guard !isShutDown else { return }
        let now = Date()
        let nextById = Dictionary(uniqueKeysWithValues: nextAccounts.map { ($0.id, $0) })
        let hasNewlyExpiredChild = children.contains { entry in
            !expiredAccounts.contains(entry.account.id)
                && nextById[entry.account.id]?.session.expiryState(at: now) == .expired
        }
        let unchanged = !hasNewlyExpiredChild
            && accounts.count == nextAccounts.count
            && zip(accounts, nextAccounts).allSatisfy { $0.id == $1.id && $0.session == $1.session }
        guard !unchanged else { return }
        for account in accounts where nextById[account.id] == nil {
            resetSelection(ownedBy: account.id)
        }
        var keptChildren: [(account: MiAccount, provider: MiCloudProvider)] = []
        var removedProviders: [MiCloudProvider] = []
        var removedChildIds = Set<String>()
        for entry in children {
            let newlyExpired = !expiredAccounts.contains(entry.account.id)
                && nextById[entry.account.id]?.session.expiryState(at: now) == .expired
            if let nextAccount = nextById[entry.account.id],
               nextAccount.session == entry.account.session,
               !newlyExpired {
                keptChildren.append((account: nextAccount, provider: entry.provider))
            } else {
                forwardTasks.removeValue(forKey: entry.account.id)?.cancel()
                snapshots.removeValue(forKey: entry.account.id)
                statuses.removeValue(forKey: entry.account.id)
                disconnectedStatuses.removeValue(forKey: entry.account.id)
                localNetworkBlocksByAccount.removeValue(forKey: entry.account.id)
                freshAccounts.remove(entry.account.id)
                expiredAccounts.remove(entry.account.id)
                removedChildIds.insert(entry.account.id)
                removedProviders.append(entry.provider)
            }
        }
        accounts = nextAccounts
        scopeBox.update(accounts: nextAccounts, removing: removedChildIds)
        children = keptChildren
        for account in accounts where account.session.expiryState(at: now) == .expired {
            resetSelection(ownedBy: account.id)
        }
        let rawSelection = selectedHomeLoader()
        var retainedIdsToRefresh = Set<String>()
        for entry in keptChildren where !expiredAccounts.contains(entry.account.id) {
            if scopeBox.hasSelectionChanged(for: entry.account.id, rawSelection: rawSelection) {
                snapshots.removeValue(forKey: entry.account.id)
                freshAccounts.remove(entry.account.id)
                retainedIdsToRefresh.insert(entry.account.id)
            }
        }
        for provider in removedProviders { await provider.shutdown() }
        guard continuation != nil, !isShutDown else { return }
        if accounts.isEmpty {
            rebuildDeviceOwners()
            localNetworkBlocksByAccount.removeAll()
            publishLocalNetworkPermission()
            let disconnected = ConnectionStatus.disconnected(MiCloudError.notLoggedIn.localizedDescription)
            if lastStatus != disconnected {
                lastStatus = disconnected
                continuation?.yield(.statusChanged(disconnected))
            }
            var empty = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
            empty.isInitialLoadComplete = true
            continuation?.yield(.snapshotUpdated(empty))
            return
        }
        var newlyStarted: [MiCloudProvider] = []
        for account in accounts where !children.contains(where: { $0.account.id == account.id }) {
            newlyStarted.append(startChild(for: account))
        }
        let childrenById = Dictionary(uniqueKeysWithValues: children.map { ($0.account.id, $0) })
        children = accounts.compactMap { childrenById[$0.id] }
        for provider in newlyStarted { await provider.setPollingContext(pollingContext) }
        guard !isShutDown else { return }
        rebuildDeviceOwners()
        publishLocalNetworkPermission()
        publishStatus()
        if !snapshots.isEmpty {
            publishSnapshot()
        }
        let providersToRefresh = children
            .filter { retainedIdsToRefresh.contains($0.account.id) }
            .map(\.provider)
        if !providersToRefresh.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for provider in providersToRefresh {
                    group.addTask { await provider.refreshNow() }
                }
            }
        }
    }

    /// The child provider only understands raw home ids, while the app stores `"<accountID>/<homeID>"`.
    /// A bare id from before multi-account belongs to the first account. When another signed-in account's
    /// home is selected, this child hides its devices/rooms while still reporting its home options.
    private func scopedSelection(for account: MiAccount) -> @Sendable () -> String? {
        let loader = selectedHomeLoader
        let accountId = account.id
        let scopeBox = self.scopeBox
        return {
            scopeBox.resolve(for: accountId, rawSelection: loader())
        }
    }

    @discardableResult
    private func resetSelection(ownedBy accountId: String) -> Bool {
        guard let selection = selectedHomeLoader(),
              MiAccountScope.isOwned(selection, by: accountId)
                || (MiAccountScope.owner(of: selection) == nil && accounts.first?.id == accountId) else { return false }
        clearSelectedHome()
        return true
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for task in forwardTasks.values { task.cancel() }
        forwardTasks.removeAll()
        let currentChildren = children
        children = []
        for child in currentChildren { await child.provider.shutdown() }
        continuation?.finish()
        continuation = nil
    }

    public func refreshNow() async {
        guard !isShutDown else { return }
        let providers = children.map { $0.provider }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await provider.refreshNow() }
            }
        }
    }

    public func setPollingContext(_ context: PollingContext) async {
        guard !isShutDown else { return }
        if context.systemActive && !pollingContext.systemActive {
            freshAccounts.removeAll()
        }
        pollingContext = context
        await applyPollingContext()
    }

    private func applyPollingContext() async {
        guard !isShutDown else { return }
        let context = pollingContext
        let providers = children.map { $0.provider }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await provider.setPollingContext(context) }
            }
        }
    }

    // MARK: Merging Child Events

    private func handle(_ event: HomeProviderEvent, from accountId: String) async {
        guard !isShutDown, accounts.contains(where: { $0.id == accountId }) else { return }
        switch event {
        case .statusChanged(let status):
            if expiredAccounts.contains(accountId) {
                guard case .disconnected = status else { break }
            }
            let previousStatus = statuses[accountId]
            let previousDisconnected = disconnectedStatuses[accountId]
            statuses[accountId] = status
            switch status {
            case .connected:
                disconnectedStatuses.removeValue(forKey: accountId)
            case .disconnected:
                disconnectedStatuses[accountId] = status
            case .connecting:
                break
            }
            publishStatus()
            if !snapshots.isEmpty,
               (previousStatus != statuses[accountId] || previousDisconnected != disconnectedStatuses[accountId]) {
                publishSnapshot()
            }
        case .sessionExpired(let session):
            let expiredStatus = ConnectionStatus.disconnected(MiCloudError.sessionExpired.localizedDescription)
            expiredAccounts.insert(accountId)
            disconnectedStatuses[accountId] = expiredStatus
            statuses[accountId] = expiredStatus
            publishLocalNetworkPermission()
            if !snapshots.isEmpty {
                publishSnapshot()
            }
            publishStatus()
            continuation?.yield(.sessionExpired(session))
            if resetSelection(ownedBy: accountId) {
                await refreshNow()
            }
        case .sourceStatusesChanged:
            break
        case .localNetworkPermissionChanged(let blocked):
            localNetworkBlocksByAccount[accountId] = blocked
            publishLocalNetworkPermission()
            if !snapshots.isEmpty {
                publishSnapshot()
            }
        case .doorbellRang(let ring):
            continuation?.yield(.doorbellRang(ring))
        case .snapshotUpdated(let home):
            snapshots[accountId] = home
            localNetworkBlocksByAccount[accountId] = home.localNetworkBlockedFeatures
            publishLocalNetworkPermission()
            if !expiredAccounts.contains(accountId), !home.devices.isEmpty {
                if home.closesAwayGap {
                    disconnectedStatuses.removeValue(forKey: accountId)
                    if case .connecting? = statuses[accountId] {
                        statuses[accountId] = .connected
                    }
                } else if disconnectedStatuses[accountId] == nil, case .connecting? = statuses[accountId] {
                    statuses[accountId] = .connected
                }
            }
            if home.closesAwayGap {
                freshAccounts.insert(accountId)
            } else {
                freshAccounts.remove(accountId)
            }
            rebuildDeviceOwners()
            publishSnapshot()
        }
    }

    /// Connected wins so one expired account cannot hide a working one.
    private func publishStatus() {
        var connected = false
        var seenConnecting = false
        var firstDisconnected: ConnectionStatus?
        for account in accounts {
            guard let status = statuses[account.id] else { continue }
            switch status {
            case .connected: connected = true
            case .connecting: seenConnecting = true
            case .disconnected: if firstDisconnected == nil { firstDisconnected = status }
            }
        }
        let aggregate: ConnectionStatus = connected
            ? .connected
            : (seenConnecting ? .connecting : (firstDisconnected ?? .connecting))
        guard aggregate != lastStatus else { return }
        lastStatus = aggregate
        continuation?.yield(.statusChanged(aggregate))
    }

    private func publishLocalNetworkPermission() {
        let unioned = accounts.filter { !expiredAccounts.contains($0.id) }.reduce(into: Set<LocalNetworkBlockedFeature>()) {
            if let f = localNetworkBlocksByAccount[$1.id] { $0.formUnion(f) }
        }
        guard unioned != lastLocalNetworkBlocks else { return }
        lastLocalNetworkBlocks = unioned
        continuation?.yield(.localNetworkPermissionChanged(unioned))
    }

    private func rebuildDeviceOwners() {
        var owners: [String: [String]] = [:]
        for account in accounts {
            guard let home = snapshots[account.id] else { continue }
            for device in home.devices {
                for key in [device.id] + device.miotCommandDids {
                    if owners[key]?.contains(account.id) == true { continue }
                    owners[key, default: []].append(account.id)
                }
            }
        }
        deviceOwners = owners
    }

    private func isDisconnected(_ accountId: String) -> Bool {
        if expiredAccounts.contains(accountId) { return true }
        if disconnectedStatuses[accountId] != nil { return true }
        if case .disconnected? = statuses[accountId] { return true }
        return false
    }

    private func isDisconnectedWithNoDevices(_ accountId: String) -> Bool {
        guard isDisconnected(accountId),
              let home = snapshots[accountId],
              home.devices.isEmpty else {
            return false
        }
        return true
    }

    private static func deviceFreshnessRank(
        _ device: SmartDevice,
        accountDisconnected: Bool,
        accountExpired: Bool = false
    ) -> Int {
        if accountExpired { return 4 }
        if accountDisconnected { return 3 }
        if device.telemetryStale { return 2 }
        return device.isOnline ? 0 : 1
    }

    private func ownerFreshnessRank(accountId: String, key: String) -> Int {
        if expiredAccounts.contains(accountId) { return 4 }
        let accountDisconnected = isDisconnected(accountId)
        guard !accountDisconnected, let home = snapshots[accountId] else {
            return 3
        }
        var bestRank = 2
        for device in home.devices where device.id == key || device.miotCommandDids.contains(key) {
            let rank = Self.deviceFreshnessRank(device, accountDisconnected: false)
            if rank < bestRank {
                bestRank = rank
            }
        }
        return bestRank
    }

    private func publishSnapshot() {
        let orderedAccounts = accounts.filter { !isDisconnected($0.id) }
            + accounts.filter { isDisconnected($0.id) && !expiredAccounts.contains($0.id) }
            + accounts.filter { expiredAccounts.contains($0.id) }
        let reported = orderedAccounts.compactMap { account -> (account: MiAccount, home: SynthesizedHome)? in
            guard let home = snapshots[account.id] else { return nil }
            return (account, home)
        }
        guard !reported.isEmpty else { return }
        var rooms: [RoomArea] = []
        var devices: [SmartDevice] = []
        var readings: [EnvironmentReading] = []
        var scenes: [HomeScene] = []
        var homes: [HomeOption] = []
        var roomIds = Set<String>()
        var deviceIds = Set<String>()
        var deviceIndexById: [String: Int] = [:]
        var bestRankByDeviceId: [String: Int] = [:]
        var winningAccountByDeviceId: [String: String] = [:]
        var deviceAccountIDs: [String: [String]] = [:]
        var readingIds = Set<String>()
        var sceneIds = Set<String>()
        var homeIds = Set<String>()
        var identities: [String: DeviceSourceIdentity] = [:]
        var lightGroupOwners: [String: String] = [:]
        var facetsByDevice: [String: [FacetControl]] = [:]
        var transportDiagnosticsByDevice: [String: DeviceTransportDiagnostics] = [:]
        var closesAwayGap = true
        for (account, home) in reported {
            let accountExpired = expiredAccounts.contains(account.id)
            let accountDisconnected = accountExpired || isDisconnected(account.id)
            closesAwayGap = closesAwayGap && home.closesAwayGap
            for rawDevice in home.devices {
                if deviceAccountIDs[rawDevice.id]?.contains(account.id) != true {
                    deviceAccountIDs[rawDevice.id, default: []].append(account.id)
                }
                var device = rawDevice
                if device.accountId == nil || device.accountId?.isEmpty == true {
                    device.accountId = account.id
                }
                if device.accountLabel == nil {
                    device.accountLabel = account.maskedUserId
                }
                if accountDisconnected {
                    device.isOnline = false
                    device.telemetryStale = true
                }
                let rank = Self.deviceFreshnessRank(
                    device,
                    accountDisconnected: accountDisconnected,
                    accountExpired: accountExpired
                )
                if let existingIndex = deviceIndexById[device.id],
                   let existingRank = bestRankByDeviceId[device.id] {
                    if rank < existingRank {
                        devices[existingIndex] = device
                        bestRankByDeviceId[device.id] = rank
                        winningAccountByDeviceId[device.id] = account.id
                        if let identity = home.deviceIdentities[device.id] {
                            identities[device.id] = identity
                        } else {
                            identities.removeValue(forKey: device.id)
                        }
                        if let facets = home.deviceFacets[device.id] {
                            facetsByDevice[device.id] = facets
                        } else {
                            facetsByDevice.removeValue(forKey: device.id)
                        }
                        transportDiagnosticsByDevice[device.id] = home.deviceTransportDiagnostics[device.id]
                    }
                } else {
                    deviceIndexById[device.id] = devices.count
                    bestRankByDeviceId[device.id] = rank
                    winningAccountByDeviceId[device.id] = account.id
                    deviceIds.insert(device.id)
                    devices.append(device)
                    if let identity = home.deviceIdentities[device.id] {
                        identities[device.id] = identity
                    }
                    if let facets = home.deviceFacets[device.id] {
                        facetsByDevice[device.id] = facets
                    }
                    transportDiagnosticsByDevice[device.id] = home.deviceTransportDiagnostics[device.id]
                }
            }
        }
        for (account, home) in reported {
            let accountDisconnected = isDisconnected(account.id)
            for (id, identity) in home.deviceIdentities where identities[id] == nil {
                identities[id] = identity
            }
            for (memberDid, groupDid) in home.lightGroupOwners {
                if winningAccountByDeviceId[memberDid] == account.id || lightGroupOwners[memberDid] == nil {
                    lightGroupOwners[memberDid] = groupDid
                }
            }
            if !accountDisconnected {
                for reading in home.environmentReadings {
                    if let winningAccount = winningAccountByDeviceId[reading.id], winningAccount != account.id {
                        continue
                    }
                    if readingIds.insert(reading.id).inserted {
                        readings.append(reading)
                    }
                }
            }
            for scene in home.scenes where sceneIds.insert(scene.id).inserted { scenes.append(scene) }
        }
        for account in accounts {
            guard let home = snapshots[account.id] else { continue }
            for room in home.rooms where roomIds.insert(room.id).inserted { rooms.append(room) }
            for option in home.homes where homeIds.insert(option.id).inserted { homes.append(option) }
        }
        var merged = SynthesizedHome(rooms: rooms, devices: devices, environmentReadings: readings, scenes: scenes)
        merged.homes = homes
        var effectiveStatuses = statuses
        for (id, disconnectedStatus) in disconnectedStatuses {
            effectiveStatuses[id] = disconnectedStatus
        }
        for id in expiredAccounts where effectiveStatuses[id] == nil {
            effectiveStatuses[id] = .disconnected(MiCloudError.sessionExpired.localizedDescription)
        }
        merged.accountStatuses = effectiveStatuses
        merged.expiredAccountIDs = expiredAccounts
        merged.deviceAccountIDs = deviceAccountIDs
        merged.deviceIdentities = identities
        merged.deviceFacets = facetsByDevice
        merged.deviceTransportDiagnostics = transportDiagnosticsByDevice
        merged.localNetworkBlockedFeatures = lastLocalNetworkBlocks
        merged.lightGroupOwners = lightGroupOwners.filter {
            deviceIds.contains($0.key) && deviceIds.contains($0.value)
        }
        // A partially reported panel or a pre-sleep cached snapshot from another account must not
        // close an away gap: the missing account may hold the door sensor that changed while asleep.
        let allFreshAfterWake = accounts.allSatisfy {
            freshAccounts.contains($0.id) || isDisconnectedWithNoDevices($0.id)
        }
        merged.closesAwayGap = closesAwayGap && allFreshAfterWake
        merged.isInitialLoadComplete = accounts.allSatisfy {
            snapshots[$0.id] != nil || isDisconnected($0.id)
        }
        continuation?.yield(.snapshotUpdated(merged))
    }

    private func childProvider(for accountId: String) -> MiCloudProvider? {
        children.first { $0.account.id == accountId }?.provider
    }

    private func preferredOwners(for key: String) -> [String] {
        let raw = deviceOwners[key] ?? []
        return raw.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = ownerFreshnessRank(accountId: lhs.element, key: key)
                let rhsRank = ownerFreshnessRank(accountId: rhs.element, key: key)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Commands & Device Calls

    private static func isPreTransmitURLError(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected:
            return true
        default:
            return false
        }
    }

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let did = MiotAddress.parseAction(entityId)?.did ?? MiotAddress.parse(entityId)?.did else {
            throw MiotCommandError.invalidAddress(entityId)
        }
        let owners = preferredOwners(for: did)
        guard !owners.isEmpty else { throw MiotCommandError.unsupported(entityId) }
        var lastFallbackError: (any Error)?
        for ownerId in owners {
            guard let child = childProvider(for: ownerId) else { continue }
            let nonIdempotent: Bool
            if !command.isIdempotentForAccountFallback {
                nonIdempotent = true
            } else {
                nonIdempotent = await child.mapsToAction(command)
            }
            do {
                try await child.execute(command)
                return
            } catch MiCloudError.sessionExpired {
                lastFallbackError = MiCloudError.sessionExpired
            } catch MiCloudError.notLoggedIn {
                if (lastFallbackError as? MiCloudError) != .sessionExpired {
                    lastFallbackError = MiCloudError.notLoggedIn
                }
            } catch let cloudErr as MiCloudError {
                if case .http(let status) = cloudErr {
                    guard !nonIdempotent || (400..<500).contains(status) else {
                        throw cloudErr
                    }
                    if (lastFallbackError as? MiCloudError) != .sessionExpired {
                        lastFallbackError = cloudErr
                    }
                    continue
                }
                throw cloudErr
            } catch let urlErr as URLError {
                guard !nonIdempotent || Self.isPreTransmitURLError(urlErr.code) else {
                    throw urlErr
                }
                if (lastFallbackError as? MiCloudError) != .sessionExpired {
                    lastFallbackError = urlErr
                }
            } catch {
                throw error
            }
        }
        throw lastFallbackError ?? MiCloudError.notLoggedIn
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let ownerId = preferredOwners(for: deviceId).first,
              let child = childProvider(for: ownerId) else { return .failed }
        return await child.readBack(deviceId: deviceId)
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let ownerId = preferredOwners(for: deviceId).first,
              let child = childProvider(for: ownerId) else { return [] }
        return await child.fetchSensorHistory(deviceId: deviceId, window: window, now: now)
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .hd)
    }

    public func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: quality, channel: 0)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        let ownerId = preferredOwners(for: device.id).first ?? device.accountId
        guard let ownerId, let child = childProvider(for: ownerId) else {
            throw HomeProviderError.serviceCallFailed(
                501,
                L10n.tr("当前数据源暂未返回该摄像头的实时画面流", "Current backend did not return a live stream for this camera")
            )
        }
        return try await child.resolveCameraStream(for: device, quality: quality, channel: channel)
    }

    public func stopCameraStream(for device: SmartDevice) async {
        for ownerId in deviceOwners[device.id] ?? [] {
            guard let child = childProvider(for: ownerId) else { continue }
            await child.stopCameraStream(for: device)
        }
    }
}

/// How a multi-account home names what one Mi account owns: `<accountId>/<local id>`.
/// Home selections and room ids use it; the store reads ownership through here instead of
/// parsing the separator itself.
public enum MiAccountScope {
    public static func id(_ localId: String, account accountId: String) -> String {
        "\(accountId)/\(localId)"
    }

    /// The owning account, or nil for an unscoped id (a single-account selection).
    public static func owner(of scopedId: String) -> String? {
        guard let slash = scopedId.firstIndex(of: "/") else { return nil }
        return String(scopedId[..<slash])
    }

    /// The part after the account; the whole id when it is unscoped.
    public static func localId(of scopedId: String) -> String {
        guard let slash = scopedId.firstIndex(of: "/") else { return scopedId }
        return String(scopedId[scopedId.index(after: slash)...])
    }

    public static func isOwned(_ scopedId: String, by accountId: String) -> Bool {
        scopedId.hasPrefix(accountId + "/")
    }
}
