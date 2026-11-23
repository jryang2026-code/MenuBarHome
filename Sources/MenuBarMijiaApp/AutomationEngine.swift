import AppKit
import CoreGraphics
import Foundation
import MijiaCore
import os

/// The two values away-arbitration needs at the instant a notification arrives.
///
/// Injected so unit tests can drive lid state and SSID without a real lid or a Location grant.
@MainActor
struct AutomationEnvironmentProbe {
    var isLidClosed: () -> Bool
    var currentWiFi: () -> (ssid: String?, isAuthorized: Bool)
    var isScreenLocked: () -> Bool = { false }

    static let live = AutomationEnvironmentProbe(
        isLidClosed: { MacHardwareProbe.isLidClosed() },
        currentWiFi: { MacHardwareProbe.currentWiFi() },
        isScreenLocked: {
            ScreenLockPolicy.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
        }
    )
}

/// Observes Mac state and runs the user's automation rules (#59).
///
/// Triggers are grouped so one lid close cannot fire a rule several times:
/// - `away`: `willSleep`, `screensDidSleep`, and the distributed lock notification.
/// - `back`: `didWake`, `screensDidWake`, and the distributed unlock notification.
/// - external display connect/disconnect: active non-built-in display count changes.
///
/// Reliability notes:
/// - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` are distributed notifications, not
///   public NSWorkspace events. They do not arrive in a sandboxed process and can be missed while
///   the display is asleep; lock-based rules are therefore best-effort. This app is distributed
///   outside the sandbox, so it receives them today.
/// - Sleep rules may run just before the Mac suspends; a cloud command can be cut off mid-flight.
///   The optimistic update rolls back when dispatch fails, and the same rule fires again after
///   the next `back`/`away` transition at the earliest one minute later.
/// - `AutomationTriggerDeduper` coalesces bursts per trigger for one minute and persists the
///   timestamps, so relaunching the app does not replay a rule.
///
/// Demo mode uses `DemoHomeProvider`: commands are applied to an in-memory virtual home and never
/// touch the network (#47).
@MainActor
final class AutomationEngine {
    static let shared = AutomationEngine()

    private let ruleStore: AutomationRuleStore
    private var runStates: [UUID: AutomationRunState] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private let deduper: AutomationTriggerDeduper
    private let injectedContextProvider: (any MacContextProviding)?
    /// Every time-of-day decision in this engine (trigger windows, calendar lead times) reads this
    /// calendar. It is `Calendar.autoupdatingCurrent` in production, so a time-zone or DST change
    /// made while the app runs moves the verdicts with it instead of freezing the launch zone;
    /// tests inject a fixed calendar. Internal rather than private so a test can assert the default.
    let calendar: Calendar
    private let environment: AutomationEnvironmentProbe
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "Automation")
    private weak var store: HomeStore?
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    private var observesSystem = false
    private var observationGeneration: UInt64 = 0
    private var contextObservationID: UUID?
    private var wasEnabled = true
    private var resumedAt: Date?
    private var resumeSuppressionUntil: [String: Date] = [:]
    private let now: () -> Date
    var isObservingSystem: Bool { !tokens.isEmpty }
    private var lastExternalDisplayCount = 0
    private var activeContextProvider: (any MacContextProviding)?
    private var lastContext: MacContextSnapshot?
    /// Away/back notifications drive this so a locked or sleeping Mac does not count as “still
    /// using the computer” for late-night rules; launch-time session state seeds the initial value.
    private var isUserPresent: Bool

    // MARK: Away arbitration state

    private var arbitrator = AwayArbitrator()
    /// SSID captured the moment the screen locked. A lid close locks first, so this is the freshest
    /// value available before the Wi-Fi interface is torn down for suspend.
    private var lockTimeWiFi: WiFiReading?
    /// Last reading from the 10 s context poll, including "authorized but no network" results.
    private var lastKnownWiFi: WiFiReading?
    // Written on the main actor. `nonisolated(unsafe)` lets `deinit` cancel the debounce sleep.
    private nonisolated(unsafe) var arbitrationTask: Task<Void, Never>?

    struct WiFiReading: Equatable, Sendable {
        var ssid: String?
        var isAuthorized: Bool
        var capturedAt: Date

        /// A cached reading is only trustworthy for a short while; a disconnect minutes ago must
        /// not be reported as "still on that network".
        static let maxAge: TimeInterval = 120

        func isFresh(at now: Date) -> Bool {
            now.timeIntervalSince(capturedAt) <= Self.maxAge
        }
    }

    /// `defaults` and `contextProvider` are injectable for tests; the app always uses `.standard`
    /// and the real CoreMediaIO/CoreWLAN/EventKit observer.
    init(
        defaults: UserDefaults = .standard,
        contextProvider: (any MacContextProviding)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        environment: AutomationEnvironmentProbe = .live,
        now: @escaping () -> Date = { Date() }
    ) {
        self.ruleStore = AutomationRuleStore(defaults: defaults)
        self.deduper = AutomationTriggerDeduper(defaults: defaults)
        self.injectedContextProvider = contextProvider
        self.calendar = calendar
        self.environment = environment
        self.now = now
        self.isUserPresent = !environment.isScreenLocked()
    }

    deinit {
        arbitrationTask?.cancel()
    }

    func start(with store: HomeStore) {
        attach(store: store)
        observesSystem = true
        rulesDidChange()
    }

    private func startSystemObservation() {
        guard observesSystem, tokens.isEmpty else { return }
        lastExternalDisplayCount = Self.activeExternalDisplayCount()
        isUserPresent = !environment.isScreenLocked()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .away)
        observe(workspace, NSWorkspace.screensDidSleepNotification, .away)
        observe(workspace, NSWorkspace.didWakeNotification, .back)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .back)

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .away)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .back)

        // Precise away triggers. The coarse `away`/`back` observers above stay so rules written
        // before the split keep firing; `AwayArbitrator` decides which precise one happened.
        observeAway(workspace, NSWorkspace.willSleepNotification, .willSleep)
        observeAway(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observeAway(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)

        // AppKit has no public “display connected” notification; enumerating active displays is the
        // documented substitute. Resolution-only changes keep the same count and are ignored.
        let generation = observationGeneration
        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation else { return }
                self.screenConfigurationChanged()
            }
        }
        tokens.append((.default, screenToken))
    }

    /// Test seam: binds the store without subscribing to system notifications, so `handle(trigger:)`
    /// and `handle(context:)` can be driven directly (the notifying systems cannot post in unit
    /// tests).
    func attach(store: HomeStore) {
        self.store = store
        wasEnabled = store.eventAutomationEnabled
        store.onAutomationRulesChanged = { [weak self] in
            self?.rulesDidChange()
        }
    }

    /// Whether any enabled rule needs the 10-second Mac context poller (CoreMediaIO, CoreAudio,
    /// IOKit, CoreWLAN, Focus, EventKit). Event-driven triggers (`away`, `back`, precise sleep/lock,
    /// external display count) with unconditional Wi-Fi run purely off system notifications.
    static func needsContextPolling(_ rules: [AutomationRule]) -> Bool {
        rules.contains { rule in
            guard rule.isEnabled else { return false }
            if rule.conditions.wifi.isNetworkSpecific { return true }
            switch rule.trigger {
            case .away, .back, .screenLocked, .lidClosedSleep, .systemSleep,
                 .externalDisplayConnected, .externalDisplayDisconnected:
                return false
            case .cameraInUse, .cameraNotInUse,
                 .microphoneInUse, .microphoneNotInUse,
                 .powerConnected, .powerDisconnected, .batteryBelowThreshold,
                 .wifiNetworkJoined, .wifiNetworkLeft,
                 .focusModeEnabled, .focusModeDisabled,
                 .calendarMeetingStartingSoon, .lateNightUsage:
                return true
            }
        }
    }

    /// Test seam: starts the injected context provider (or the real observer when enabled rules
    /// need it) without subscribing to NSWorkspace/distributed notifications.
    func startContextObservation() {
        guard store?.eventAutomationEnabled == true, activeContextProvider == nil else { return }
        let provider: any MacContextProviding
        if let injectedContextProvider {
            provider = injectedContextProvider
        } else {
            let rules = ruleStore.load()
            guard Self.needsContextPolling(rules) else { return }
            provider = MacContextObserver()
        }
        activeContextProvider = provider
        let id = UUID()
        contextObservationID = id
        provider.start { [weak self] snapshot, now in
            guard let self, self.contextObservationID == id else { return }
            await self.handle(context: snapshot, at: now)
        }
    }

    /// Settings calls this after a rule is added, removed or toggled so a newly enabled Focus,
    /// calendar or Wi-Fi rule can request its permission immediately and start or stop the 10 s
    /// context poller as needed.
    func rulesDidChange() {
        guard let store else { return }
        let enabled = store.eventAutomationEnabled
        if enabled != wasEnabled {
            resumedAt = enabled ? now() : nil
            resumeSuppressionUntil.removeAll()
        }
        wasEnabled = enabled

        let rules = enabled ? ruleStore.load() : []
        guard rules.contains(where: \.isEnabled) else {
            if !tokens.isEmpty || activeContextProvider != nil || !enabled {
                observationGeneration &+= 1
            }
            for (center, token) in tokens { center.removeObserver(token) }
            tokens.removeAll()
            stopContextObservation()
            arbitrationTask?.cancel()
            arbitrationTask = nil
            arbitrator = AwayArbitrator()
            lockTimeWiFi = nil
            lastKnownWiFi = nil
            return
        }
        startSystemObservation()
        if Self.needsContextPolling(rules) {
            if injectedContextProvider == nil { MacContextPermissionRequester.requestPermissions(for: rules) }
            startContextObservation()
        } else {
            stopContextObservation()
        }
    }

    private func stopContextObservation() {
        contextObservationID = nil
        activeContextProvider?.stop()
        activeContextProvider = nil
        lastContext = nil
        lastKnownWiFi = nil
    }

    /// Test seam: notifying systems cannot post in unit tests, so the mapping is exercised by
    /// calling this directly. Observers above do exactly the same thing.
    func handle(trigger: AutomationTrigger, at now: Date = Date()) async {
        guard let store, store.eventAutomationEnabled else { return }
        let generation = observationGeneration
        switch trigger {
        case .away, .screenLocked, .lidClosedSleep, .systemSleep:
            isUserPresent = false
        case .back:
            isUserPresent = true
        default:
            break
        }
        let rules = AutomationMatcher.rules(for: trigger, in: ruleStore.load())
        // An empty list must not burn the cooldown; the user may add a rule a moment later.
        guard !rules.isEmpty else { return }

        // Conditions filter before the cooldown is consumed: a lock that arrives on the wrong
        // network must leave the trigger available for the next one.
        let reading = wifiReadingForDispatch(at: now)
        let eligible = rules.filter { rule in
            // A rule outside its window must not consume the cooldown either: the trigger stays
            // available for the first event that lands inside the window.
            guard rule.conditions.isWithinTimeWindow(at: now, calendar: calendar) else {
                logger.notice(
                    """
                    rule-check trigger=\(trigger.rawValue, privacy: .public) \
                    rule=\(rule.id.uuidString.prefix(8), privacy: .public) \
                    time=outside \
                    window=\(rule.conditions.timeWindow.summary, privacy: .public) \
                    verdict=skip
                    """
                )
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                return false
            }
            let result = rule.conditions.evaluate(
                wifiSSID: reading?.ssid,
                isAuthorized: reading?.isAuthorized ?? true
            )
            logger.notice(
                """
                rule-check trigger=\(trigger.rawValue, privacy: .public) \
                rule=\(rule.id.uuidString.prefix(8), privacy: .public) \
                time=\(rule.conditions.timeWindow.isEnabled ? "inside" : "any", privacy: .public) \
                wifi=\(result.logToken, privacy: .public) \
                ssid=\(reading?.ssid ?? "-", privacy: .private) \
                verdict=\(result.isSatisfied ? "run" : "skip", privacy: .public)
                """
            )
            if !result.isSatisfied { store.recordAutomationRun(rule, at: now, reason: .conditionFalse) }
            return result.isSatisfied
        }
        var shouldFire: Bool?
        for rule in eligible {
            guard generation == observationGeneration, store.eventAutomationEnabled,
                  ruleStore.load().contains(rule) else {
                store.recordAutomationRun(rule, at: now, reason: .writeGateDenied)
                continue
            }
            await run(rule, store: store, at: now, cooldown: {
                let allowed = shouldFire ?? self.deduper.shouldFire(trigger, at: now)
                shouldFire = allowed
                return allowed
            })
        }
    }

    /// Evaluates every enabled rule against one Mac context snapshot. The pure `MacContextAutomation`
    /// switch decides which signal changed; this method only applies the per-rule cooldown and
    /// executes.
    func handle(context: MacContextSnapshot, at now: Date = Date()) async {
        guard let store, store.eventAutomationEnabled else { return }
        let generation = observationGeneration
        let contextID = contextObservationID
        var effective = context
        effective.isUserPresent = isUserPresent && context.isUserPresent
        // Keep the most recent poll result as the last-resort SSID source for a sleep that arrives
        // without a preceding lock (the interface is already down by then).
        lastKnownWiFi = WiFiReading(
            ssid: context.wifiSSID,
            isAuthorized: context.isWiFiAuthorized,
            capturedAt: now
        )
        let previous = lastContext
        lastContext = effective
        let rules = ruleStore.load()
        if let resumedAt {
            // Capture the baseline once so later snapshots cannot suppress newly added events.
            for rule in rules {
                let events = MacContextAutomation.events(
                    for: rule, previous: nil, current: effective, at: resumedAt, calendar: calendar
                )
                for event in events {
                    resumeSuppressionUntil[event.dedupeKey] = resumedAt.addingTimeInterval(event.cooldown)
                }
            }
            self.resumedAt = nil
        }
        for rule in rules where rule.isEnabled {
            guard generation == observationGeneration, contextID == contextObservationID,
                  store.eventAutomationEnabled else { break }
            guard ruleStore.load().contains(rule) else { continue }
            let events = MacContextAutomation.events(
                for: rule, previous: previous, current: effective, at: now, calendar: calendar
            )
            guard !events.isEmpty else { continue }
            let conditionSSID = rule.trigger == .wifiNetworkLeft
                ? (previous?.wifiSSID ?? context.wifiSSID)
                : context.wifiSSID
            guard rule.conditions.isWithinTimeWindow(at: now, calendar: calendar),
                  rule.conditions.evaluate(wifiSSID: conditionSSID, isAuthorized: context.isWiFiAuthorized)
                    .isSatisfied else {
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                continue
            }
            await run(rule, store: store, at: now, cooldown: {
                events.contains {
                    now >= (self.resumeSuppressionUntil[$0.dedupeKey] ?? .distantPast)
                        && self.deduper.shouldFire($0.dedupeKey, at: now, cooldown: $0.cooldown)
                }
            })
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ trigger: AutomationTrigger
    ) {
        let generation = observationGeneration
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    guard self.observationGeneration == generation else { return }
                    await self.handle(trigger: trigger)
                }
            }
        }
        tokens.append((center, token))
    }

    // MARK: - Away arbitration

    private func observeAway(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ signal: AwaySignal
    ) {
        let generation = observationGeneration
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    guard self.observationGeneration == generation else { return }
                    await self.ingestAway(signal)
                }
            }
        }
        tokens.append((center, token))
    }

    /// Feeds one system notification through the arbiter and runs whatever it settles on.
    /// Also the test seam: the notifying systems cannot post inside a unit test.
    func ingestAway(_ signal: AwaySignal, at now: Date = Date()) async {
        guard store?.eventAutomationEnabled == true else { return }
        switch signal {
        case .screenLocked, .willSleep, .displayDidSleep:
            isUserPresent = false
        case .screenUnlocked:
            isUserPresent = true
        }
        if signal == .screenLocked {
            // Read the SSID while the interface is certainly still up: a lid close locks *before*
            // it suspends, so this is the freshest reading a sleep can ever consult.
            lockTimeWiFi = captureWiFi(at: now)
        }
        let lidClosed = environment.isLidClosed()
        let outcome = arbitrator.ingest(signal, lidClosed: lidClosed, at: now)
        // Values are computed first: OSLog interpolation becomes a closure, which would require
        // explicit `self.` for every property read inside the message.
        let signalName = String(describing: signal)
        let outcomeName = outcome.map { String(describing: $0) } ?? "wait"
        let pending = arbitrator.hasPendingLock
        logger.notice(
            """
            away-signal signal=\(signalName, privacy: .public) \
            lidClosed=\(lidClosed, privacy: .public) \
            pending=\(pending, privacy: .public) \
            outcome=\(outcomeName, privacy: .public)
            """
        )
        scheduleArbitrationFlush()
        if let outcome {
            await dispatchAway(outcome, at: now)
        }
    }

    /// Runs when the pending-lock deadline is reached.
    ///
    /// `now` only answers whether the debounce has elapsed. The rule is judged at the lock
    /// instant, one debounce earlier, so a flush that lands at 22:00:01 still sees a 21:59:59
    /// lock as outside a 22:00 window. A late wake must not move that verdict.
    func flushArbitration(at now: Date = Date()) async {
        guard store?.eventAutomationEnabled == true else { return }
        let lockInstant = arbitrator.pendingDeadline?.addingTimeInterval(-AwayArbitrator.lockDebounce)
        guard let outcome = arbitrator.flush(at: now) else { return }
        logger.notice("away-flush outcome=\(String(describing: outcome), privacy: .public)")
        await dispatchAway(outcome, at: lockInstant ?? now)
    }

    private func scheduleArbitrationFlush() {
        arbitrationTask?.cancel()
        guard let deadline = arbitrator.pendingDeadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        arbitrationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushArbitration(at: Date())
        }
    }

    private func dispatchAway(_ outcome: AwayOutcome, at now: Date) async {
        let reading = lockTimeWiFi
        let generation = observationGeneration
        await handle(trigger: outcome.trigger, at: now)
        if generation == observationGeneration, reading == lockTimeWiFi { lockTimeWiFi = nil }
    }

    private func captureWiFi(at now: Date) -> WiFiReading {
        let reading = environment.currentWiFi()
        return WiFiReading(ssid: reading.ssid, isAuthorized: reading.isAuthorized, capturedAt: now)
    }

    /// Best-known network at dispatch time. Order: the lock-time snapshot → a live read → the last
    /// poll. A live read that succeeds with "no network" is authoritative and must not be replaced
    /// by a cached SSID, otherwise a rule would fire on a network the Mac already left.
    private func wifiReadingForDispatch(at now: Date) -> WiFiReading? {
        if let lockTimeWiFi, lockTimeWiFi.isFresh(at: now) {
            logger.notice("wifi-source lock-time ssid=\(lockTimeWiFi.ssid ?? "-", privacy: .private)")
            return lockTimeWiFi
        }
        let live = captureWiFi(at: now)
        if live.ssid != nil || !live.isAuthorized {
            logger.notice(
                """
                wifi-source live ssid=\(live.ssid ?? "-", privacy: .private) \
                authorized=\(live.isAuthorized, privacy: .public)
                """
            )
            return live
        }
        if let cached = lastKnownWiFi, cached.isFresh(at: now), cached.ssid != nil {
            logger.notice("wifi-source cached ssid=\(cached.ssid ?? "-", privacy: .private)")
            return cached
        }
        logger.notice("wifi-source none")
        return live
    }

    private func screenConfigurationChanged() {
        let count = Self.activeExternalDisplayCount()
        defer { lastExternalDisplayCount = count }
        guard count != lastExternalDisplayCount else { return }
        let trigger: AutomationTrigger = count > lastExternalDisplayCount
            ? .externalDisplayConnected
            : .externalDisplayDisconnected
        let generation = observationGeneration
        Task { @MainActor in
            guard observationGeneration == generation else { return }
            await handle(trigger: trigger)
        }
    }

    /// Counts active displays that are not built into the Mac. Using total `NSScreen.screens.count`
    /// would report a disconnect when a laptop lid closes while an external display stays on.
    private static func activeExternalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let maxDisplays = count
        guard CGGetActiveDisplayList(maxDisplays, &displays, &count) == .success else { return 0 }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    private func run(
        _ rule: AutomationRule, store: HomeStore, at time: Date, cooldown: () -> Bool
    ) async {
        guard cooldown() else {
            store.recordAutomationRun(rule, at: time, reason: .cooldown)
            return
        }
        var state = runStates[rule.id] ?? AutomationRunState()
        let token = UUID()
        guard state.start(token, mode: rule.mode) else {
            store.recordAutomationRun(rule, at: time, reason: .singleAlreadyRunning)
            return
        }
        let previous = runTasks[rule.id]
        let generation = observationGeneration
        runStates[rule.id] = state
        let task = Task {
            await previous?.value
            @MainActor func blocked() -> AutomationSkipReason? {
                guard self.runStates[rule.id]?.owns(token) == true else { return .superseded }
                guard generation == self.observationGeneration, store.eventAutomationEnabled,
                      self.ruleStore.load().contains(rule) else { return .writeGateDenied }
                return nil
            }
            let reason: AutomationSkipReason?
            if let denied = blocked() {
                reason = denied
            } else {
                reason = await self.execute(rule, store: store, blocked: blocked)
            }
            store.recordAutomationRun(rule, at: time, reason: reason)
            self.runStates[rule.id]?.finish(token)
            if self.runStates[rule.id]?.isRunning == false {
                self.runStates[rule.id] = nil
                self.runTasks[rule.id] = nil
            }
        }
        runTasks[rule.id] = task
        await task.value
    }

    private func execute(
        _ rule: AutomationRule, store: HomeStore, blocked: @escaping () -> AutomationSkipReason?
    ) async -> AutomationSkipReason? {
        if rule.highRiskConfirmation(devices: store.devices) != nil, !rule.highRiskApproved {
            var stored = ruleStore.load()
            if let idx = stored.firstIndex(where: { $0.id == rule.id }) {
                stored[idx].isEnabled = false
                ruleStore.save(stored)
                rulesDidChange()
            }
            store.showToast(
                L10n.tr("高风险自动化规则需在设置中重新确认启用", "High-risk automation rule requires re-confirmation in Settings"),
                isError: true
            )
            return .writeGateDenied
        }
        switch rule.action {
        // Quick actions aggregate devices in the store and already show their own toast plus undo
        // banner; the longer automation window keeps the banner usable after unlocking (#59).
        case .quickAction(let action):
            // Automation is not a user action, so it never trains habits (#34/#113).
            var wrote = false
            let task = store.runAutomationQuickAction(action, canContinue: { blocked() == nil }) { wrote = $0 }
            let outcome = await task?.value
            if wrote { return nil }
            if let denied = blocked() { return denied }
            switch outcome {
            case .refusedByMiSession: return .writeGateDenied
            case .partial, .completed: return .error
            case nil:
                return store.automationQuickActionSkipReason(action)
            }
        case .devices, .scene:
            let intents = rule.action.intents()
            guard !intents.isEmpty else { return .noActionNeeded }
            let summary = rule.action.summary(devices: store.devices, scenes: store.scenes)
            let title = L10n.format("自动化：%@", "Automation: %@", summary)
            let outcome = await store.runAutomation(
                intents: intents,
                title: title,
                canContinue: { blocked() == nil }
            )
            if outcome.succeededCount == 0, let denied = blocked() { return denied }
            if outcome.attemptedCount == 0 { return outcome.skipReason }
            if outcome.succeededCount == 0 {
                let message = outcome.errorMessage ?? L10n.tr("控制执行失败", "Execution failed")
                store.showToast(message, isError: true)
            } else if outcome.failedCount > 0 {
                let summaryDetail = L10n.format(
                    "成功 %@ 项，%@ 项失败",
                    "%@ succeeded, %@ failed",
                    String(outcome.succeededCount),
                    String(outcome.failedCount)
                )
                let detail = outcome.errorMessage.map { "\(summaryDetail)：\($0)" } ?? summaryDetail
                store.showToast("\(title)（\(detail)）", isError: true)
            } else {
                store.showToast(title)
            }
            return outcome.skipReason
        }
    }
}
