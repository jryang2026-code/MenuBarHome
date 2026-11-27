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
    var externalDisplayCount: () -> Int = { AutomationEngine.activeExternalDisplayCount() }
    var frontmostAppBundleID: () -> String? = { nil }

    static let live = AutomationEnvironmentProbe(
        isLidClosed: { MacHardwareProbe.isLidClosed() },
        currentWiFi: { MacHardwareProbe.currentWiFi() },
        isScreenLocked: {
            ScreenLockPolicy.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
        },
        externalDisplayCount: { AutomationEngine.activeExternalDisplayCount() },
        frontmostAppBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    )
}

@MainActor
struct AutomationNotificationCenters {
    var workspace: NotificationCenter
    var distributed: NotificationCenter
    var app: NotificationCenter

    static let live = AutomationNotificationCenters(
        workspace: NSWorkspace.shared.notificationCenter,
        distributed: DistributedNotificationCenter.default(),
        app: .default
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
    nonisolated static let frontmostAppBundleIDUserInfoKey = "MenuBarHomeFrontmostAppBundleID"

    private let ruleStore: AutomationRuleStore
    private var runStates: [UUID: AutomationRunState] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private let deduper: AutomationTriggerDeduper
    private let contextStack: AutomationContextStack
    private let injectedContextProvider: (any MacContextProviding)?
    /// Every time-of-day decision in this engine (trigger windows, calendar lead times) reads this
    /// calendar. It is `Calendar.autoupdatingCurrent` in production, so a time-zone or DST change
    /// made while the app runs moves the verdicts with it instead of freezing the launch zone;
    /// tests inject a fixed calendar. Internal rather than private so a test can assert the default.
    let calendar: Calendar
    private let environment: AutomationEnvironmentProbe
    private let notificationCenters: AutomationNotificationCenters
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "Automation")
    private weak var store: HomeStore?
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    private var frontmostAppToken: (NotificationCenter, any NSObjectProtocol)?
    private var hasFrontmostAppBaseline = false
    private var lastFrontmostAppBundleID: String?
    private var observesSystem = false
    private var observationGeneration: UInt64 = 0
    private var contextObservationID: UUID?
    private var wasEnabled = true
    private var resumedAt: Date?
    private var resumeSuppressionUntil: [String: Date] = [:]
    private let now: () -> Date
    var isObservingSystem: Bool { !tokens.isEmpty }
    var isObservingFrontmostApp: Bool { frontmostAppToken != nil }
    var hasPendingAwayLock: Bool { arbitrator.hasPendingLock }
    private var lastExternalDisplayCount = 0
    private var activeContextProvider: (any MacContextProviding)?
    private var lastContext: MacContextSnapshot?
    private struct LastingObservation {
        let rule: AutomationRule
        let state: String
        let since: TimeInterval
        var lastSeen: TimeInterval
        var fired = false
    }

    private var lastingObservations: [UUID: LastingObservation] = [:]
    private var isSystemAsleep = false
    private var sleepGeneration: UInt64 = 0
    private let elapsedTime: () -> TimeInterval
    /// Away/back notifications drive this so a locked or sleeping Mac does not count as “still
    /// using the computer” for late-night rules; launch-time session state seeds the initial value.
    private var isUserPresent: Bool

    private struct ContextCapture {
        let ruleID: UUID
        let snapshots: [AutomationContextSnapshot]
    }

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
        notificationCenters: AutomationNotificationCenters = .live,
        now: @escaping () -> Date = { Date() },
        elapsedTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.ruleStore = AutomationRuleStore(defaults: defaults)
        self.deduper = AutomationTriggerDeduper(defaults: defaults)
        self.contextStack = AutomationContextStack(defaults: defaults)
        self.injectedContextProvider = contextProvider
        self.calendar = calendar
        self.environment = environment
        self.notificationCenters = notificationCenters
        self.now = now
        self.elapsedTime = elapsedTime
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
        lastExternalDisplayCount = environment.externalDisplayCount()
        isUserPresent = !environment.isScreenLocked()
        isSystemAsleep = false
        let workspace = notificationCenters.workspace
        observe(workspace, NSWorkspace.willSleepNotification, .away, systemSleeping: true)
        observe(workspace, NSWorkspace.screensDidSleepNotification, .away)
        observe(workspace, NSWorkspace.didWakeNotification, .back, systemSleeping: false)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .back)

        let distributed = notificationCenters.distributed
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
        let appCenter = notificationCenters.app
        let screenToken = appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation else { return }
                self.screenConfigurationChanged()
            }
        }
        tokens.append((appCenter, screenToken))
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
            guard rule.isEnabled, rule.trigger.isSupportedOnMacOS else { return false }
            return rule.conditions.wifi.isNetworkSpecific || rule.trigger.usesMacContextObserver
        }
    }

    /// Test seam: starts the injected context provider (or the real observer when enabled rules
    /// need it) without subscribing to NSWorkspace/distributed notifications.
    func startContextObservation() {
        guard store?.eventAutomationEnabled == true, activeContextProvider == nil, !isSystemAsleep else { return }
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

    static func needsFrontmostAppObservation(_ rules: [AutomationRule]) -> Bool {
        rules.contains { rule in
            guard rule.isEnabled, rule.trigger.isSupportedOnMacOS else { return false }
            if rule.trigger.macOSSources.contains(.workspaceDidActivateApplication) {
                return true
            }
            return rule.restoreWhenContextEnds
                && (rule.restoreTrigger?.macOSSources.contains(.workspaceDidActivateApplication) == true)
        }
    }

    private func startFrontmostAppObservation() {
        guard observesSystem, frontmostAppToken == nil else { return }
        if let initial = Self.normalizedBundleID(environment.frontmostAppBundleID()) {
            lastFrontmostAppBundleID = initial
            hasFrontmostAppBaseline = true
        } else {
            lastFrontmostAppBundleID = nil
            hasFrontmostAppBaseline = false
        }
        let generation = observationGeneration
        let workspace = notificationCenters.workspace
        let token = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = Self.bundleIdentifier(from: notification)
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation else { return }
                let firedAt = self.now()
                Task { @MainActor in
                    guard self.observationGeneration == generation else { return }
                    await self.handleFrontmostAppActivated(bundleID: bundleID, at: firedAt)
                }
            }
        }
        frontmostAppToken = (workspace, token)
    }

    private func stopFrontmostAppObservation() {
        if let (center, token) = frontmostAppToken {
            center.removeObserver(token)
        }
        frontmostAppToken = nil
        hasFrontmostAppBaseline = false
        lastFrontmostAppBundleID = nil
    }

    private nonisolated static func bundleIdentifier(from notification: Notification) -> String? {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            return app.bundleIdentifier
        }
        return notification.userInfo?[Self.frontmostAppBundleIDUserInfoKey] as? String
    }

    private static func normalizedBundleID(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
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
        lastingObservations = lastingObservations.filter { _, state in
            state.rule.isEnabled && rules.contains(state.rule)
        }
        guard rules.contains(where: \.isEnabled) else {
            if !tokens.isEmpty || frontmostAppToken != nil || activeContextProvider != nil || !enabled {
                observationGeneration &+= 1
            }
            for (center, token) in tokens { center.removeObserver(token) }
            tokens.removeAll()
            stopFrontmostAppObservation()
            stopContextObservation()
            arbitrationTask?.cancel()
            arbitrationTask = nil
            arbitrator = AwayArbitrator()
            lockTimeWiFi = nil
            lastKnownWiFi = nil
            return
        }
        startSystemObservation()
        if Self.needsFrontmostAppObservation(rules) {
            startFrontmostAppObservation()
        } else {
            stopFrontmostAppObservation()
        }
        if Self.needsContextPolling(rules) {
            if injectedContextProvider == nil { MacContextPermissionRequester.requestPermissions(for: rules) }
            startContextObservation()
        } else {
            stopContextObservation()
        }
    }

    private func stopContextObservation(keepingBaseline: Bool = false) {
        contextObservationID = nil
        activeContextProvider?.stop()
        activeContextProvider = nil
        lastingObservations.removeAll()
        if !keepingBaseline {
            lastContext = nil
            lastKnownWiFi = nil
        }
    }

    /// Test seam: notifying systems cannot post in unit tests, so the mapping is exercised by
    /// calling this directly. Observers above do exactly the same thing.
    func handle(trigger: AutomationTrigger, at now: Date = Date()) async {
        guard let store, store.eventAutomationEnabled, trigger.isSupportedOnMacOS else { return }
        let generation = observationGeneration
        switch trigger {
        case .away, .screenLocked, .lidClosedSleep, .systemSleep:
            isUserPresent = false
        case .back:
            isUserPresent = true
        default:
            break
        }
        await restoreContextsIfNeeded(for: trigger, store: store, at: now)
        let rules = AutomationMatcher.rules(for: trigger, in: ruleStore.load())
        // An empty list must not burn the cooldown; the user may add a rule a moment later.
        guard !rules.isEmpty else { return }

        // Conditions filter before the cooldown is consumed: a lock that arrives on the wrong
        // network must leave the trigger available for the next one.
        let reading = wifiReadingForDispatch(at: now)
        let eligible = rules.filter { rule in
            guard rule.conditions.lastingMinutes == nil else {
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                return false
            }
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

    /// Evaluates `.frontmostAppLeft` and `.frontmostAppBecame` transitions without polling.
    /// First observation only warms up the baseline so enabling a rule while an app is already
    /// active never fires. Privacy: non-matching apps are never stored or logged.
    func handleFrontmostAppActivated(bundleID: String?, at now: Date = Date()) async {
        guard let store, store.eventAutomationEnabled else { return }
        let current = Self.normalizedBundleID(bundleID)
        if !hasFrontmostAppBaseline {
            hasFrontmostAppBaseline = true
            lastFrontmostAppBundleID = current
            return
        }
        let previous = lastFrontmostAppBundleID
        guard current != previous else { return }
        lastFrontmostAppBundleID = current

        let generation = observationGeneration
        if let previous {
            await restoreContextsIfNeeded(
                for: .frontmostAppLeft,
                store: store,
                at: now,
                matching: { $0.triggerOptions.frontmostAppBundleID == previous }
            )
            await dispatchFrontmostApp(
                trigger: .frontmostAppLeft,
                bundleID: previous,
                generation: generation,
                store: store,
                at: now
            )
        }
        if let current {
            await restoreContextsIfNeeded(
                for: .frontmostAppBecame,
                store: store,
                at: now,
                matching: { $0.triggerOptions.frontmostAppBundleID == current }
            )
            await dispatchFrontmostApp(
                trigger: .frontmostAppBecame,
                bundleID: current,
                generation: generation,
                store: store,
                at: now
            )
        }
    }

    private func dispatchFrontmostApp(
        trigger: AutomationTrigger,
        bundleID: String,
        generation: UInt64,
        store: HomeStore,
        at now: Date
    ) async {
        let rules = ruleStore.load().filter {
            $0.isEnabled
                && $0.trigger == trigger
                && $0.triggerOptions.frontmostAppBundleID == bundleID
        }
        guard !rules.isEmpty else { return }
        let reading = wifiReadingForDispatch(at: now)
        let eligible = rules.filter { rule in
            guard rule.conditions.lastingMinutes == nil else {
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                return false
            }
            guard rule.conditions.isWithinTimeWindow(at: now, calendar: calendar) else {
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                return false
            }
            let result = rule.conditions.evaluate(
                wifiSSID: reading?.ssid,
                isAuthorized: reading?.isAuthorized ?? true
            )
            if !result.isSatisfied { store.recordAutomationRun(rule, at: now, reason: .conditionFalse) }
            return result.isSatisfied
        }
        for rule in eligible {
            guard generation == observationGeneration, store.eventAutomationEnabled,
                  ruleStore.load().contains(rule) else {
                store.recordAutomationRun(rule, at: now, reason: .writeGateDenied)
                continue
            }
            let dedupeKey = "\(trigger.rawValue).\(rule.id.uuidString)"
            await run(rule, store: store, at: now, cooldown: {
                self.deduper.shouldFire(dedupeKey, at: now, cooldown: AutomationPolicy.triggerCooldown)
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
        store.updateDesktopContext(DesktopAmbientContext.from(macSnapshot: effective, externalDisplayCount: environment.externalDisplayCount(), now: now, calendar: calendar))
        let rules = ruleStore.load()
        let elapsed = elapsedTime()
        if let resumedAt {
            // Capture the baseline once so later snapshots cannot suppress newly added events.
            for rule in rules {
                let events = MacContextAutomation.events(
                    for: rule, previous: nil, current: effective, at: resumedAt, calendar: calendar
                )
                for event in events {
                    resumeSuppressionUntil[event.dedupeKey] = event.trigger == .scheduledTime
                        ? calendar.dateInterval(of: .minute, for: resumedAt)?.end
                        : resumedAt.addingTimeInterval(event.cooldown)
                }
            }
            self.resumedAt = nil
        }
        // Restoration is keyed by the paired exit signal, which may not have its own rule. Probe
        // each configured restore trigger directly so a context frame is restored even when the
        // user only created the entering rule.
        var restoreTriggers: [AutomationTrigger] = []
        for rule in rules where rule.isEnabled && rule.restoreWhenContextEnds {
            guard let restoreTrigger = rule.restoreTrigger else { continue }
            let probe = AutomationRule(
                trigger: restoreTrigger,
                action: .devices(ids: [], isOn: false),
                triggerOptions: rule.triggerOptions
            )
            let events = MacContextAutomation.events(
                for: probe, previous: previous, current: effective, at: now, calendar: calendar
            )
            if !events.isEmpty && !restoreTriggers.contains(restoreTrigger) {
                restoreTriggers.append(restoreTrigger)
            }
        }
        for trigger in restoreTriggers {
            await restoreContextsIfNeeded(for: trigger, store: store, at: now)
        }
        var candidates: [(rule: AutomationRule, events: [AutomationTriggerEvent], lastingSince: TimeInterval?)] = []
        for rule in rules where rule.isEnabled && rule.trigger.isSupportedOnMacOS {
            let events = MacContextAutomation.events(
                for: rule, previous: previous, current: effective, at: now, calendar: calendar
            )
            guard !events.isEmpty || rule.conditions.lastingMinutes != nil else { continue }
            let conditionSSID = rule.trigger == .wifiNetworkLeft
                ? (previous?.wifiSSID ?? context.wifiSSID)
                : context.wifiSSID
            let conditionsHold = rule.conditions.isWithinTimeWindow(at: now, calendar: calendar)
                && rule.conditions.evaluate(wifiSSID: conditionSSID, isAuthorized: context.isWiFiAuthorized).isSatisfied
            if let minutes = rule.conditions.lastingMinutes {
                let state = !isSystemAsleep && conditionsHold
                    ? lastingState(for: rule, context: effective, at: now) : nil
                guard let state else {
                    let wasPending = lastingObservations.removeValue(forKey: rule.id)?.fired == false
                    if wasPending || !events.isEmpty {
                        store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                    }
                    continue
                }
                var reading = lastingObservations[rule.id]
                    ?? LastingObservation(rule: rule, state: state, since: elapsed, lastSeen: elapsed)
                let gap = elapsed - reading.lastSeen
                guard gap >= 0 else { continue }
                if reading.rule != rule || reading.state != state || gap > MacContextObserver.refreshInterval * 2 {
                    reading = LastingObservation(rule: rule, state: state, since: elapsed, lastSeen: elapsed)
                }
                reading.lastSeen = elapsed
                let ready = !reading.fired && elapsed - reading.since >= TimeInterval(minutes) * 60
                reading.fired = reading.fired || ready
                lastingObservations[rule.id] = reading
                if ready { candidates.append((rule, events, reading.since)) }
                continue
            }
            if rule.trigger == .scheduledTime, isSystemAsleep { continue }
            guard conditionsHold else {
                store.recordAutomationRun(rule, at: now, reason: .conditionFalse)
                continue
            }
            candidates.append((rule, events, nil))
        }
        for (rule, events, lastingSince) in candidates {
            guard generation == observationGeneration, contextID == contextObservationID,
                  store.eventAutomationEnabled else { break }
            guard ruleStore.load().contains(rule) else { continue }
            await run(rule, store: store, at: now, lastingSince: lastingSince, cooldown: {
                (lastingSince != nil && rule.trigger != .lateNightUsage) || self.allows(events, at: now)
            })
        }
    }

    private func allows(_ events: [AutomationTriggerEvent], at now: Date) -> Bool {
        events.contains { event in
            guard now >= (resumeSuppressionUntil[event.dedupeKey] ?? .distantPast) else { return false }
            if event.trigger == .scheduledTime {
                return deduper.claimScheduledOccurrence(event.dedupeKey, at: now)
            }
            return deduper.shouldFire(event.dedupeKey, at: now, cooldown: event.cooldown)
        }
    }

    private func lastingState(for rule: AutomationRule, context: MacContextSnapshot, at now: Date) -> String? {
        guard rule.trigger.supportsLasting else { return nil }
        let options = rule.triggerOptions
        let active: Bool
        switch rule.trigger {
        case .cameraInUse, .cameraNotInUse:
            guard context.isCameraUsageAvailable else { return nil }
            active = context.cameraInUse == (rule.trigger == .cameraInUse)
        case .microphoneInUse, .microphoneNotInUse:
            guard context.isMicrophoneUsageAvailable else { return nil }
            active = context.microphoneInUse == (rule.trigger == .microphoneInUse)
        case .powerConnected: active = context.powerSource == .ac
        case .powerDisconnected: active = context.powerSource == .battery
        case .batteryBelowThreshold:
            active = context.powerSource == .battery && (context.batteryPercent ?? 100) < options.batteryThresholdPercent
        case .wifiNetworkJoined:
            guard context.isWiFiAuthorized, let ssid = context.wifiSSID,
                  options.wifiSSID == nil || options.wifiSSID == ssid else { return nil }
            return ssid
        case .focusModeEnabled, .focusModeDisabled:
            guard let isActive = context.isFocusActive else { return nil }
            if let name = options.focusModeName {
                guard !isActive || context.focusModeName != nil else { return nil }
                active = (isActive && context.focusModeName == name) == (rule.trigger == .focusModeEnabled)
            } else {
                active = isActive == (rule.trigger == .focusModeEnabled)
            }
        case .lateNightUsage:
            guard context.isUserPresent,
                  let anchor = options.lateNightWindow.nightAnchor(containing: now, calendar: calendar) else { return nil }
            return String(anchor.timeIntervalSince1970)
        default:
            return nil
        }
        return active ? rule.trigger.rawValue : nil
    }

    func setSystemSleeping(_ sleeping: Bool) {
        isSystemAsleep = sleeping
        if sleeping {
            sleepGeneration &+= 1
            lastingObservations.removeAll()
            if observesSystem { stopContextObservation(keepingBaseline: true) }
        } else if observesSystem {
            startContextObservation()
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ trigger: AutomationTrigger,
        systemSleeping: Bool? = nil
    ) {
        let generation = observationGeneration
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation else { return }
                if let systemSleeping { self.setSystemSleeping(systemSleeping) }
                let firedAt = self.now()
                Task { @MainActor in
                    guard self.observationGeneration == generation else { return }
                    await self.handle(trigger: trigger, at: firedAt)
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
                guard let self, self.observationGeneration == generation else { return }
                let arrivedAt = self.now()
                Task { @MainActor in
                    guard self.observationGeneration == generation else { return }
                    await self.ingestAway(signal, at: arrivedAt)
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
        let delay = max(0, deadline.timeIntervalSince(now()))
        arbitrationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.flushArbitration(at: self.now())
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
        let count = environment.externalDisplayCount()
        defer { lastExternalDisplayCount = count }
        if let store { var d = store.desktopContext; d.externalDisplayConnected = count > 0; store.updateDesktopContext(d) }
        guard count != lastExternalDisplayCount else { return }
        let trigger: AutomationTrigger = count > lastExternalDisplayCount
            ? .externalDisplayConnected
            : .externalDisplayDisconnected
        let generation = observationGeneration
        let changedAt = now()
        Task { @MainActor in
            guard observationGeneration == generation else { return }
            await handle(trigger: trigger, at: changedAt)
        }
    }

    /// Counts active displays that are not built into the Mac. Using total `NSScreen.screens.count`
    /// would report a disconnect when a laptop lid closes while an external display stays on.
    static func activeExternalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let maxDisplays = count
        guard CGGetActiveDisplayList(maxDisplays, &displays, &count) == .success else { return 0 }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    private func run(
        _ rule: AutomationRule, store: HomeStore, at time: Date,
        lastingSince: TimeInterval? = nil, cooldown: () -> Bool
    ) async {
        if let lastingSince, lastingObservations[rule.id]?.since != lastingSince {
            store.recordAutomationRun(rule, at: time, reason: .conditionFalse)
            return
        }
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
        let sleepGeneration = sleepGeneration
        runStates[rule.id] = state
        let task = Task {
            await previous?.value
            @MainActor func blocked() -> AutomationSkipReason? {
                guard self.runStates[rule.id]?.owns(token) == true else { return .superseded }
                guard generation == self.observationGeneration, store.eventAutomationEnabled,
                      self.ruleStore.load().contains(rule) else { return .writeGateDenied }
                if let lastingSince, self.lastingObservations[rule.id]?.since != lastingSince {
                    return .conditionFalse
                }
                if rule.trigger == .scheduledTime || lastingSince != nil {
                    if self.isSystemAsleep || sleepGeneration != self.sleepGeneration { return .writeGateDenied }
                    if self.environment.isScreenLocked() { return .screenLocked }
                }
                return nil
            }
            let reason: AutomationSkipReason?
            if let denied = blocked() {
                reason = denied
            } else {
                let capture = rule.restoreWhenContextEnds ? self.captureContext(for: rule, store: store) : nil
                reason = await self.execute(rule, store: store, blocked: blocked)
                if reason == nil, let capture {
                    self.commitContext(capture, in: store, at: time)
                }
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

    private func captureContext(for rule: AutomationRule, store: HomeStore) -> ContextCapture? {
        guard case .devices(let ids, let isOn) = rule.action else { return nil }
        let snapshots = ids.compactMap { id -> AutomationContextSnapshot? in
            guard let device = store.devices.first(where: { $0.id == id }),
                  let baseline = device.automationContextValue() else { return nil }
            let applied = AutomationContextValue(field: .power, boolValue: isOn)
            return AutomationContextSnapshot(deviceID: id, baseline: baseline, applied: applied)
        }
        guard !snapshots.isEmpty else { return nil }
        return ContextCapture(ruleID: rule.id, snapshots: snapshots)
    }

    private func commitContext(_ capture: ContextCapture, in store: HomeStore, at time: Date) {
        let applied = capture.snapshots.filter { snapshot in
            store.devices.first(where: { $0.id == snapshot.deviceID })?.automationContextValue() == snapshot.applied
        }
        _ = contextStack.push(ruleID: capture.ruleID, snapshots: applied, at: time)
    }

    private func restoreContextsIfNeeded(
        for trigger: AutomationTrigger,
        store: HomeStore,
        at time: Date,
        matching predicate: ((AutomationRule) -> Bool)? = nil
    ) async {
        guard !isSystemAsleep else { return }
        let restoreRules = ruleStore.load().filter {
            $0.isEnabled && $0.restoreWhenContextEnds && $0.restoreTrigger == trigger
                && (predicate?($0) ?? true)
        }
        guard !restoreRules.isEmpty else {
            contextStack.pruneExpired(at: time)
            return
        }
        let ruleIDs = Set(restoreRules.map(\.id))
        guard contextStack.allFrames.contains(where: { ruleIDs.contains($0.ruleID) }) else { return }
        guard deduper.shouldFire(trigger, at: time) else { return }
        await restoreContexts(for: restoreRules, store: store, at: time)
    }

    private func restoreContexts(for rules: [AutomationRule], store: HomeStore, at time: Date) async {
        guard !rules.isEmpty else {
            contextStack.pruneExpired(at: time)
            return
        }
        var live = Dictionary(uniqueKeysWithValues: store.devices.compactMap { device in
            device.automationContextValue().map { (device.id, $0) }
        })
        let ruleIDs = Set(rules.map(\.id))
        let frames = contextStack.allFrames
            .filter { ruleIDs.contains($0.ruleID) }
            .sorted { $0.enteredAt > $1.enteredAt }
        var skippedHighRiskIDs = Set<String>()
        func requiresRestoreConfirmation(_ intent: DeviceIntent) -> Bool {
            guard case .power(true) = intent.operation else { return false }
            return ManualControlPolicy.requiresConfirmation(intent, devices: store.devices)
        }
        for frame in frames {
            guard let plan = contextStack.prepareRestore(frame: frame, liveValues: live, at: time) else { continue }
            var blockedIDs = Set<String>()
            func skipHighRiskIntent(_ intent: DeviceIntent) -> Bool {
                guard requiresRestoreConfirmation(intent) else { return false }
                blockedIDs.insert(intent.targetId)
                return true
            }
            let executableIntents = plan.intents.filter { !skipHighRiskIntent($0) }
            // Consume skipped power-ons so a later exit cannot retry them unattended.
            if !blockedIDs.isEmpty {
                contextStack.commitRestore(plan, restoredDeviceIDs: blockedIDs)
            }
            guard !executableIntents.isEmpty else {
                skippedHighRiskIDs.formUnion(blockedIDs)
                continue
            }

            let outcome = await store.runAutomation(
                intents: executableIntents,
                title: L10n.tr("自动化还原上下文", "Restore automation context"),
                shouldSkipIntent: skipHighRiskIntent
            )
            skippedHighRiskIDs.formUnion(blockedIDs)
            let restoredIDs = Set(executableIntents.compactMap { intent -> String? in
                guard case .power(let value) = intent.operation,
                      store.devices.first(where: { $0.id == intent.targetId })?.automationContextValue()
                        == AutomationContextValue(field: .power, boolValue: value) else { return nil }
                return intent.targetId
            })
            contextStack.commitRestore(plan, restoredDeviceIDs: restoredIDs.union(blockedIDs))
            for intent in executableIntents where restoredIDs.contains(intent.targetId) {
                if case .power(let value) = intent.operation {
                    live[intent.targetId] = AutomationContextValue(field: .power, boolValue: value)
                }
            }
            if outcome.succeededCount == 0, outcome.attemptedCount > 0 {
                store.showToast(
                    L10n.tr("上下文还原被安全策略跳过", "Context restore skipped by safety policy"),
                    isError: true
                )
            }
        }
        if !skippedHighRiskIDs.isEmpty {
            store.showToast(
                L10n.format(
                    "还原时已跳过 %@ 台需要重新开启的高风险设备",
                    "Restore skipped %@ high-risk device(s) that would have been turned back on",
                    String(skippedHighRiskIDs.count)
                ),
                isError: true
            )
        }
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
