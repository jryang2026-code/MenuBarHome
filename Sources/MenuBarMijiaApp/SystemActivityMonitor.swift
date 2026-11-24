import AppKit
import CoreGraphics
import MijiaCore
import Network

struct NetworkTopologyFingerprint: Equatable, Sendable {
    let interfaces: Set<String>
    let gateways: Set<NWEndpoint>
    let prefixes: Set<String>

    init(interfaceNames: some Sequence<String>, gateways: Set<NWEndpoint> = [], prefixes: Set<String> = []) {
        interfaces = Set(interfaceNames.filter(Self.isRelevantInterface))
        self.gateways = gateways
        self.prefixes = prefixes
    }

    init(path: NWPath) {
        self.init(
            interfaceNames: path.availableInterfaces.map(\.name),
            gateways: Set(path.gateways),
            prefixes: Self.interfacePrefixes()
        )
    }

    private static func isRelevantInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !lower.hasPrefix("awdl") && !lower.hasPrefix("llw") && !lower.hasPrefix("lo")
    }

    private static func interfacePrefixes() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var prefixes: Set<String> = []
        for entry in sequence(first: list, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            let name = String(cString: interface.ifa_name)
            guard isRelevantInterface(name),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr, let mask = interface.ifa_netmask else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                prefixes.insert(prefix(name: name, address: ip, mask: netmask))
            case AF_INET6:
                let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let netmask = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                prefixes.insert(prefix(name: name, address: ip, mask: netmask))
            default:
                break
            }
        }
        return prefixes
    }

    private static func prefix<Address>(name: String, address: Address, mask: Address) -> String {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let maskBytes = withUnsafeBytes(of: mask) { Array($0) }
        let network = zip(bytes, maskBytes).map { String($0 & $1, radix: 16) }.joined(separator: ".")
        let length = maskBytes.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(name):\(network)/\(length)"
    }
}

struct SystemWakePolicy {
    enum Wake { case dark, probe, reconnect }

    private let now: () -> ContinuousClock.Instant
    private var sleepStartedAt: ContinuousClock.Instant?

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    mutating func sleep() {
        sleepStartedAt = now()
    }

    mutating func wake(userActivityObserved: Bool) -> Wake {
        let sleptFor = sleepStartedAt.map { $0.duration(to: now()) } ?? .zero
        sleepStartedAt = nil
        if sleptFor >= .seconds(600) { return .reconnect }
        return userActivityObserved ? .probe : .dark
    }
}

/// Pauses Mi cloud polling while the Mac or its display sleeps, the screen is locked, or another
/// user is active, and slows it in Low Power Mode (#26). Wake, unlock, session activation, and
/// network-path recovery route through `HomeStore.scheduleDebouncedResume(reason:)`.
@MainActor
final class SystemActivityMonitor {
    static let shared = SystemActivityMonitor()

    private enum Change: Sendable {
        case asleep(Bool), displayAsleep(Bool), locked(Bool), sessionInactive(Bool), powerState
    }

    private final class ObserverCleanupBag: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
        private var pathMonitor: NWPathMonitor?

        func addObserver(_ center: NotificationCenter, token: any NSObjectProtocol) {
            lock.withLock { observers.append((center, token)) }
        }

        func setPathMonitor(_ monitor: NWPathMonitor) {
            let previous: NWPathMonitor? = lock.withLock {
                let old = pathMonitor
                pathMonitor = monitor
                return old
            }
            previous?.cancel()
        }

        func invalidate() {
            let (drainedObservers, drainedMonitor) = lock.withLock {
                let obs = observers
                let mon = pathMonitor
                observers = []
                pathMonitor = nil
                return (obs, mon)
            }
            for (center, token) in drainedObservers {
                center.removeObserver(token)
            }
            drainedMonitor?.cancel()
        }
    }

    private weak var store: HomeStore?
    private let observerBag = ObserverCleanupBag()
    private var isStarted = false
    private var asleep = false
    private var displayAsleep = false
    private var locked = false
    private var sessionInactive = false
    private var pendingResumeReasons: Set<ResumeReason> = []
    private var lastNetworkSatisfied: Bool?
    private var networkFingerprint: NetworkTopologyFingerprint?
    private var wakePolicy = SystemWakePolicy()
    private var waitingForInteractiveWake = false
    private var pendingTransportRestart = false

    deinit {
        observerBag.invalidate()
    }

    func start(with store: HomeStore) {
        guard !isStarted else { return }
        isStarted = true
        self.store = store
        // The app can launch from a login item while the screen is already locked; notifications
        // only report later changes, so read the authoritative session state once up front.
        locked = ScreenLockPolicy.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .asleep(true))
        observe(workspace, NSWorkspace.didWakeNotification, .asleep(false))
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep(true))
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep(false))
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive(true))
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive(false))
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .locked(true))
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked(false))
        // Posted on a background queue; `queue: .main` below moves it to the main thread.
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange, .powerState)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let fingerprint = NetworkTopologyFingerprint(path: path)
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(isSatisfied: satisfied, fingerprint: fingerprint)
            }
        }
        observerBag.setPathMonitor(monitor)
        monitor.start(queue: DispatchQueue(label: "com.jryang1997.MenuBarMijia.NetworkMonitor", qos: .utility))

        publish()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observerBag.invalidate()
        store = nil
        asleep = false
        displayAsleep = false
        locked = false
        sessionInactive = false
        pendingResumeReasons.removeAll()
        lastNetworkSatisfied = nil
        networkFingerprint = nil
        waitingForInteractiveWake = false
        pendingTransportRestart = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: Change) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(change)
            }
        }
        observerBag.addObserver(center, token: token)
    }

    private func apply(_ change: Change) {
        guard isStarted else { return }
        switch change {
        case .asleep(true):
            asleep = true
            waitingForInteractiveWake = false
            wakePolicy.sleep()
            pendingResumeReasons.removeAll()
        case .asleep(false):
            guard asleep else { return }
            asleep = false
            let displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
            switch wakePolicy.wake(userActivityObserved: displayAwake && !sessionInactive) {
            case .dark:
                waitingForInteractiveWake = true
            case .probe:
                pendingResumeReasons.insert(.systemWake)
            case .reconnect:
                pendingResumeReasons.insert(.systemWake)
                pendingTransportRestart = true
            }
        case .displayAsleep(let value):
            if !value { recordInteractiveWake() }
            if displayAsleep && !value { pendingResumeReasons.insert(.displayWake) }
            displayAsleep = value
        case .locked(let value):
            if !value { recordInteractiveWake() }
            if locked && !value { pendingResumeReasons.insert(.screenUnlocked) }
            if value { pendingResumeReasons.removeAll() }
            locked = value
        case .sessionInactive(let value):
            if !value, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { recordInteractiveWake() }
            if sessionInactive && !value { pendingResumeReasons.insert(.sessionActive) }
            if value { pendingResumeReasons.removeAll() }
            sessionInactive = value
        case .powerState:
            break
        }
        let isActive = !(transportSuspended || displayAsleep || locked || sessionInactive)
        publish()
        if isActive, !pendingResumeReasons.isEmpty {
            let reasons = pendingResumeReasons
            pendingResumeReasons.removeAll()
            for reason in reasons {
                store?.scheduleDebouncedResume(reason: reason)
            }
        }
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool, fingerprint: NetworkTopologyFingerprint) {
        guard isStarted else { return }
        let previous = lastNetworkSatisfied
        let previousFingerprint = networkFingerprint
        lastNetworkSatisfied = isSatisfied
        networkFingerprint = fingerprint
        store?.setNetworkSatisfiedForResume(isSatisfied)
        if let previous, let previousFingerprint,
           previous != isSatisfied || previousFingerprint != fingerprint {
            pendingTransportRestart = true
            publishTransportState()
        }
        if previous == false, isSatisfied {
            store?.scheduleDebouncedResume(reason: .networkRestored)
        }
    }

    private func recordInteractiveWake() {
        guard waitingForInteractiveWake else { return }
        waitingForInteractiveWake = false
        pendingResumeReasons.insert(.systemWake)
    }

    private var transportSuspended: Bool { asleep || waitingForInteractiveWake }

    private func publishTransportState() {
        let restart = !transportSuspended && pendingTransportRestart
        if restart { pendingTransportRestart = false }
        store?.setHATransportSuspended(transportSuspended, topologyChanged: restart)
    }

    private func publish() {
        publishTransportState()
        store?.setScreenLocked(locked)
        store?.setSystemActive(!(transportSuspended || displayAsleep || locked || sessionInactive))
        store?.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
