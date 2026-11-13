import AppKit
import CoreGraphics
import MijiaCore
import Network

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
    private var lastNetworkSatisfied: Bool?

    init() {}

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
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(isSatisfied: satisfied)
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
        lastNetworkSatisfied = nil
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
        var resumeReason: ResumeReason?
        switch change {
        case .asleep(let value):
            asleep = value
            if !value { resumeReason = .systemWake }
        case .displayAsleep(let value):
            displayAsleep = value
            if !value { resumeReason = .displayWake }
        case .locked(let value):
            locked = value
            if !value { resumeReason = .screenUnlocked }
        case .sessionInactive(let value):
            sessionInactive = value
            if !value { resumeReason = .sessionActive }
        case .powerState:
            break
        }
        publish()
        if let resumeReason {
            store?.scheduleDebouncedResume(reason: resumeReason)
        }
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool) {
        guard isStarted else { return }
        let previous = lastNetworkSatisfied
        lastNetworkSatisfied = isSatisfied
        store?.setNetworkSatisfiedForResume(isSatisfied)
        if previous == false, isSatisfied {
            store?.scheduleDebouncedResume(reason: .networkRestored)
        }
    }

    private func publish() {
        store?.setScreenLocked(locked)
        store?.setSystemActive(!(asleep || displayAsleep || locked || sessionInactive))
        store?.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
