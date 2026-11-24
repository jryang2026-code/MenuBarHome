import AppKit
import Observation
import os
import SwiftUI
import MijiaCore

/// App-owned menu-bar item and panel (#56).
///
/// `MenuBarExtra` keeps its status item and window inside private AppKit objects, so reaching them
/// required KVC on `_statusItem`, the private `setLongPressAction:` / `_requestExpandedInterfaceSession`
/// selectors, ivar scanning and window class-name sniffing. Owning the `NSStatusItem` and a borderless
/// `NSPanel` puts every capability the extra provided on public API:
///
/// - icon + text from `HomeStore.menuBarSymbolName` / `menuBarText`, with the listening waveform and
///   the live transcript while `SpeechInputController` records;
/// - tooltip and accessibility label from `MenuBarStatusSummary`;
/// - a left click toggles the panel, holding the left button starts hold-to-talk, and a right click
///   opens the app menu;
/// - the panel closes on an outside click or when the app deactivates (unless dictation is running);
/// - it becomes key, so arrow keys, Esc, ⌘, and its text fields behave as they did before;
/// - it is anchored under the item's own screen and stays on screen across display changes;
/// - its geometry follows `PanelTheme`: the classic card is 376 pt wide and `PanelHeight` tall,
///   hung centred under the item; the Liquid Glass column is 376 pt wide, inset 16 pt from the
///   visible right edge, full height, sliding horizontally like Notification Center (a cross-fade
///   when Reduce Motion is enabled).
///
/// To watch click, long-press, and context-menu routing decisions live without rebuilding (#330)
/// (call `/usr/bin/log` by full path because in zsh `log` can be shadowed by a shell function):
/// ```sh
/// /usr/bin/log stream --level debug --predicate 'subsystem == "com.jryang1997.MenuBarMijia" AND category == "StatusItem"'
/// ```
@MainActor
final class MenuBarPanelController: NSObject {
    static let shared = MenuBarPanelController()

    private static let statusItemLogSubsystem = "com.jryang1997.MenuBarMijia"
    private static let statusItemLogCategory = "StatusItem"
    private static let statusItemLogger = Logger(
        subsystem: statusItemLogSubsystem,
        category: statusItemLogCategory
    )

    /// Classic card width (376 pt); preserved until WP2e theme retirement decision.
    static let panelWidth: CGFloat = 376
    /// Adaptive pilot width (380 pt) and content height bounds (280–560 pt) from `ui.md` §4 `macOS`.
    static let pilotPanelWidth: CGFloat = 380
    static let pilotMinHeight: CGFloat = 280
    static let pilotMaxHeight: CGFloat = 560
    /// The panel draws its own material; AppKit only clips it to the extra's rounded corners.
    static let panelCornerRadius: CGFloat = DesignTokens.Radius.panel

    static func panelWidth(for theme: PanelTheme) -> CGFloat {
        theme == .liquidGlass ? pilotPanelWidth : panelWidth
    }

    /// Posted after the panel becomes visible, and after it is ordered out.
    static let didShowNotification = Notification.Name("MenuBarMijia.panelDidShow")
    static let didHideNotification = Notification.Name("MenuBarMijia.panelDidHide")

    /// Fallback for hosts that do not expose an event number when AppKit dismisses a menu.
    private static let contextMenuSyntheticClickTail: TimeInterval = 0.08
    /// Window after an outside-click or app-deactivation hide during which a trailing status-item
    /// toggle from the out-of-process menu bar (`NSMenuBarNavigationSceneExtension`) is recognised
    /// as the same click that just dismissed the panel rather than a request to reopen it.
    static let statusItemReopenSuppressionWindow: TimeInterval = 0.35
    /// Press-and-hold on the icon starts dictation instead of toggling the panel. 0.5 s is long
    /// enough that an ordinary slow click toggles the panel instead of dictating.
    private static let holdThreshold: TimeInterval = 0.5
    private static let holdTick: TimeInterval = 0.03
    /// Delay after hiding before releasing the heavy SwiftUI hosting tree (P0-7 warm unload).
    static let warmUnloadDelay: TimeInterval = 45.0
    /// Top-edge anchored height resize animation duration (P0-7).
    static let heightResizeDuration: TimeInterval = 0.2

    private(set) var statusItem: NSStatusItem?
    private(set) var panelWindow: NSPanel?
    /// Theme of the root view currently installed in `panelWindow`; nil until the first open.
    private(set) var hostedPanelTheme: PanelTheme?
    /// Owned by the readability-shadow code; the presentation extension reads it while animating.
    private(set) var backdropWindow: NSPanel?

    /// Tests switch this off so `swift test` shows the window without stealing key status or focus
    /// from the terminal; the app keeps it on, which is what makes the panel key like the extra was.
    var presentsActively = true
    var shouldReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// A close transition is running: toggles reopen the logically hidden panel from its current
    /// position. Read and written by `MenuBarPanelController+Presentation.swift`.
    var isClosing = false
    /// Bumped on every show, so stale presentation completions cannot hide a reopened panel.
    var presentationGeneration = 0
    /// Collects slice heights inside `ControlCenterPanel` so adaptive resizing stays loop-free.
    let panelAdaptiveHeightProbe = PanelAdaptiveHeightProbe()
    var isApplyingPanelGeometry = false
    var isEntranceAnimating = false
    var hasPendingGeometryPass = false
    /// One coalesced geometry pass per runloop turn; `scheduleAdaptiveGeometryPass()` owns the hop.
    var isGeometryPassScheduled = false
    var serialGeometryApplyCount = 0

    /// Page-routing boundary used by the status menu; the app delegates to the existing Settings owner.
    var showSettings: (SettingsTab?) -> Void = { SettingsWindowOpener.shared.show(tab: $0) }
    /// Backend-routing boundary used by tests; production falls through to the installed store.
    var switchHomeBackend: ((HomeBackend) -> Void)?
    /// Injectable so menu-action tests can verify Quit without terminating the test runner.
    var terminateApplication: () -> Void = { NSApplication.shared.terminate(nil) }
    /// Update route for the status menu; production falls through to the installed store.
    var performUpdateCheck: (() -> Void)?
    /// Event-boundary seams keep gesture routing testable without creating a process-wide NSApp.
    var statusContextMenuPresenter: ((NSMenu) -> Void)?
    var statusItemHostsOutOfProcess: (() -> Bool)?
    var statusContextMenuScheduler: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var statusItemToggle: (() -> Void)?
    var statusItemUptime: () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }
    var statusItemEventNumber: () -> Int? = {
        MenuBarPanelController.statusEventNumber(for: NSApplication.shared.currentEvent)
    }
    /// On-demand activation hooks for text input (CJK IME / Emoji / ⌘C/⌘V) while the panel stays
    /// non-activating by default. Injectable so tests can assert activation without stealing focus.
    var isApplicationActiveProvider: () -> Bool = {
        NSApp.isActive
    }
    var activateApplicationForTextInput: () -> Void = {
        NSApp.activate()
    }
    /// Injectable seam for tests to simulate an active modal confirmation alert without `runModal()`.
    var isModalConfirmationActiveProvider: () -> Bool = {
        ManualControlConfirmationPresenter.isPresenting || NSApp.modalWindow != nil
    }
    /// Injectable timer scheduler for the 45 s warm-unload grace period so tests can drive it
    /// deterministically without sleeping.
    var warmUnloadScheduler: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Duration used by the most recent frame resize pass (`nil` when applied without animation).
    var lastAppliedFrameAnimationDuration: TimeInterval?

    private func traceStatusItem(_ message: @autoclosure () -> String) {
        let line = message()
        Self.statusItemLogger.debug("\(line, privacy: .public)")
    }

    private static func statusEventTypeName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "nil" }
        switch eventType {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        default: return "raw(\(eventType.rawValue))"
        }
    }

    /// Reads the current event's number only when it is a mouse event. `NSEvent.eventNumber` raises
    /// `NSInternalInconsistencyException` for keyboard events, which reach the status item when the
    /// context menu is dismissed with Escape or the item is activated by keyboard navigation.
    private static func statusEventNumber(for event: NSEvent?) -> Int? {
        guard let event else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .mouseMoved,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .mouseEntered, .mouseExited:
            return event.eventNumber
        default:
            return nil
        }
    }

    struct WatchedPreferences: Equatable {
        var appearance: String?
        var panelTheme: String?
        var panelHeight: String?
        var temperatureUnit: String?

        init(from defaults: UserDefaults) {
            appearance = defaults.string(forKey: AppAppearance.storageKey)
            panelTheme = defaults.string(forKey: PanelTheme.storageKey)
            panelHeight = defaults.string(forKey: PanelHeight.storageKey)
            temperatureUnit = defaults.string(forKey: TemperatureUnitPreference.storageKey)
        }
    }

    let userDefaults: UserDefaults
    /// Read-only outside this file; `install` / `uninstall` own the lifetime.
    private(set) weak var store: HomeStore?
    private var labelTimer: Timer?
    private var subMinuteWakeTimer: Timer?
    private var observationGeneration: UInt64 = 0
    var lastSeenPreferences: WatchedPreferences?
    var preferencesReloadCount = 0
    private var pressTimer: Timer?
    private var pressStartedAt: TimeInterval = 0
    private var pressTriggered = false
    private var pressAllowsToggle = true
    private var suppressReleaseUntil: TimeInterval = 0
    private var suppressContextMenuUntil: TimeInterval = 0
    private var suppressResignActiveHideUntil: TimeInterval = 0
    private var suppressStatusItemReopenUntil: TimeInterval = 0
    private var resignActiveAwaitingMonitorMouseDown = false
    /// A context menu waiting for the out-of-process menu bar to finish its own handling of the
    /// same secondary click (see `requestStatusContextMenu`).
    private var pendingContextMenu: DispatchWorkItem?
    /// Pending 45 s warm-unload work item armed when the panel finishes hiding.
    private var pendingWarmUnloadWork: DispatchWorkItem?
    private(set) var warmUnloadScheduledAt: TimeInterval?
    var isWarmUnloadPending: Bool {
        pendingWarmUnloadWork?.isCancelled == false
    }
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var contextMenuDismissalEventNumber: Int?
    private var acceptsStandalonePostMenuMouseUp = false
    /// What the status button currently shows; kept after a sync so diagnostics and tests can read it.
    private(set) var labelIconState: MenuBarIconState?
    var labelSymbol: String? { labelIconState?.symbolName }
    private(set) var widthState = MenuBarWidthState()
    private(set) var labelText: String?
    private(set) var tooltipText: String?
    private var observers: [any NSObjectProtocol] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var voiceInputObserverID: UUID?
    private var didInstall = false

    var isLabelTimerRunning: Bool {
        labelTimer != nil
    }

    init(statusItem: NSStatusItem? = nil, userDefaults: UserDefaults = .standard) {
        self.statusItem = statusItem
        self.userDefaults = userDefaults
        super.init()
        panelAdaptiveHeightProbe.onHeightChange = { [weak self] _ in
            self?.scheduleAdaptiveGeometryPass()
        }
    }

    // MARK: - Installation

    /// Creates the status item and keeps its label in sync. Safe to call twice.
    ///
    /// The app calls this from `App.init`, possibly before the status bar is ready. If the resulting
    /// item never acquired a button window (which only happens when it was created too early), it is
    /// recreated once at `applicationDidFinishLaunching`.
    func install(with store: HomeStore) {
        if let oldStore = self.store, let voiceInputObserverID {
            oldStore.removeVoiceInputPreferenceObserver(voiceInputObserverID)
            self.voiceInputObserverID = nil
        }
        self.store = store
        self.voiceInputObserverID = store.addVoiceInputPreferenceObserver { [weak self] enabled in
            if !enabled {
                self?.cancelHoldToTalkOnDisable()
            }
        }
        guard !didInstall else { return }
        didInstall = true
        lastSeenPreferences = WatchedPreferences(from: userDefaults)
        createStatusItem()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverStatusItemIfNeeded()
            }
        })
        installObservers()
        installMemoryPressureMonitor()
        observationGeneration &+= 1
        observeStatusItemState(generation: observationGeneration)
    }

    /// A status item created before the status bar was ready stays blank; remove and recreate it.
    func recoverStatusItemIfNeeded() {
        if let statusItem, statusItem.button?.window == nil {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            labelIconState = nil
            widthState = MenuBarWidthState()
            labelText = nil
            tooltipText = nil
        }
        createStatusItem()
        syncStatusItem()
        updateLabelTimer()
    }

    /// Releases the status item, the panel and every observer. Used by tests; the app keeps the item
    /// for its whole lifetime.
    func uninstall() {
        presentationGeneration &+= 1
        observationGeneration &+= 1
        isClosing = false
        isApplyingPanelGeometry = false
        isEntranceAnimating = false
        hasPendingGeometryPass = false
        isGeometryPassScheduled = false
        panelAdaptiveHeightProbe.resetNotificationBaseline()
        PanelTransientUIState.shared.resetOnPanelHide(store: store)
        removeMouseMonitors()
        labelTimer?.invalidate()
        labelTimer = nil
        subMinuteWakeTimer?.invalidate()
        subMinuteWakeTimer = nil
        lastSeenPreferences = nil
        pendingContextMenu?.cancel()
        pendingContextMenu = nil
        cancelWarmUnload()
        stopMemoryPressureMonitor()
        lastAppliedFrameAnimationDuration = nil
        stopPressTimer()
        pressTriggered = false
        suppressReleaseUntil = 0
        suppressContextMenuUntil = 0
        suppressResignActiveHideUntil = 0
        suppressStatusItemReopenUntil = 0
        resignActiveAwaitingMonitorMouseDown = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let store, let voiceInputObserverID {
            store.removeVoiceInputPreferenceObserver(voiceInputObserverID)
        }
        voiceInputObserverID = nil
        backdropWindow?.orderOut(nil)
        backdropWindow?.contentView = nil
        backdropWindow = nil
        panelWindow?.orderOut(nil)
        panelWindow?.contentView = nil
        panelWindow = nil
        hostedPanelTheme = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        store = nil
        didInstall = false
        labelIconState = nil
        widthState = MenuBarWidthState()
        labelText = nil
        tooltipText = nil
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemPress)
            // `NSControl.sendAction(on:)` only honors primary-button tracking masks. Secondary
            // clicks arrive through the status-item secondary action or the event monitors below.
            _ = button.sendAction(on: [.leftMouseDown, .leftMouseUp])
        }
        configureStatusItemLongPress(on: item)
        statusItem = item
        syncStatusItem()
    }

    /// Registers `setLongPressAction:` on `NSStatusItem` for macOS 26+, where the out-of-process
    /// menu bar (`NSMenuBarNavigationSceneExtension`) routes press-and-hold and secondary clicks
    /// through `-[NSStatusItem _performSecondaryAction:type:]` instead of delivering `leftMouseDown`
    /// to the button action when the finger first touches the trackpad.
    private func configureStatusItemLongPress(on item: NSStatusItem) {
        // Always assign `item.target` unconditionally: `-[NSStatusItem target]` falls back to
        // `button.target`, whereas `-[NSStatusItem _performSecondaryAction:type:]` reads the
        // `NSStatusItem->_target` ivar directly without consulting `button.target`.
        item.target = self
        let setLongSel = NSSelectorFromString("setLongPressAction:")
        guard item.responds(to: setLongSel),
              let method = class_getInstanceMethod(type(of: item), setLongSel) else { return }
        typealias SetSelFn = @convention(c) (AnyObject, Selector, Selector) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: SetSelFn.self)
        imp(item, setLongSel, #selector(handleStatusItemNativeLongPress(_:)))
    }

    // MARK: - Status Item Context Menu

    struct StatusConnectionMenuState {
        let isDemo: Bool
        let includesHomeAssistant: Bool
        let includesXiaomiCloud: Bool
        let preferredLiveBackend: HomeBackend

        init(
            homeBackend: HomeBackend,
            hasHASource: Bool,
            hasMiSource: Bool,
            preferredLiveBackend: HomeBackend
        ) {
            let active = HomeBackendDescriptor.activeBackends(
                homeBackend: homeBackend,
                configuredSources: Set([
                    hasHASource ? .homeAssistant : nil,
                    hasMiSource ? .xiaomiCloud : nil,
                ].compactMap { $0 })
            )
            isDemo = active.contains(.demo)
            includesHomeAssistant = active.contains(.homeAssistant)
            includesXiaomiCloud = active.contains(.xiaomiCloud)
            self.preferredLiveBackend = preferredLiveBackend
        }
    }

    private var statusConnectionMenuState: StatusConnectionMenuState {
        guard let store else {
            return StatusConnectionMenuState(
                homeBackend: .homeAssistant,
                hasHASource: false,
                hasMiSource: false,
                preferredLiveBackend: .homeAssistant
            )
        }
        return StatusConnectionMenuState(
            homeBackend: store.homeBackend,
            hasHASource: store.hasHASource,
            hasMiSource: store.hasMiSource,
            preferredLiveBackend: store.preferredLiveBackend
        )
    }

    /// Creates a new menu for each presentation so a runtime language change is reflected at once.
    func makeStatusContextMenu(connectionState: StatusConnectionMenuState? = nil) -> NSMenu {
        let menu = NSMenu()
        let state = connectionState ?? statusConnectionMenuState
        let connections = NSMenuItem(
            title: L10n.tr("家居连接", "Connections"),
            action: nil,
            keyEquivalent: ""
        )
        let connectionsMenu = NSMenu()

        let liveConnections = NSMenuItem(
            title: L10n.tr("实时连接", "Live Connections"),
            action: #selector(switchBackendFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        liveConnections.target = self
        liveConnections.representedObject = state.preferredLiveBackend.rawValue
        liveConnections.state = state.isDemo ? .off : .on
        connectionsMenu.addItem(liveConnections)

        let demo = NSMenuItem(
            title: HomeBackend.demo.title,
            action: #selector(switchBackendFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        demo.target = self
        demo.representedObject = HomeBackend.demo.rawValue
        demo.state = state.isDemo ? .on : .off
        connectionsMenu.addItem(demo)

        connectionsMenu.addItem(.separator())
        let homeAssistant = NSMenuItem(
            title: HomeBackend.homeAssistant.title,
            action: nil,
            keyEquivalent: ""
        )
        homeAssistant.state = state.includesHomeAssistant ? .on : .off
        homeAssistant.isEnabled = false
        connectionsMenu.addItem(homeAssistant)

        let xiaomiCloud = NSMenuItem(
            title: HomeBackend.xiaomiCloud.title,
            action: nil,
            keyEquivalent: ""
        )
        xiaomiCloud.state = state.includesXiaomiCloud ? .on : .off
        xiaomiCloud.isEnabled = false
        connectionsMenu.addItem(xiaomiCloud)

        connectionsMenu.addItem(.separator())
        let connectionSettings = NSMenuItem(
            title: L10n.tr("打开连接设置…", "Open Connection Settings…"),
            action: #selector(openConnectionSettingsFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        connectionSettings.target = self
        connectionsMenu.addItem(connectionSettings)
        connections.submenu = connectionsMenu
        menu.addItem(connections)

        let settings = NSMenuItem(
            title: L10n.tr("设置…", "Settings…"),
            action: #selector(openSettingsFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(
            title: L10n.tr("检查更新…", "Check for Updates…"),
            action: #selector(openUpdatesFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: L10n.tr("退出 MenuBarHome", "Quit MenuBarHome"),
            action: #selector(quitFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// How long to wait after a secondary click before opening the menu on an out-of-process menu
    /// bar host (macOS 26+). The host follows the click with its own secondary action, which runs
    /// "select item / end expanded interface session" on the status item; a menu already attached
    /// at that moment is force-closed about 0.25 s after it appears. `native` is the short settle
    /// after that action reached us; `fallback` covers a host that never sends it.
    enum ContextMenuSettle {
        static let native: TimeInterval = 0.08
        static let fallback: TimeInterval = 0.3
    }

    /// The menu bar runs in another process when the status item takes `setLongPressAction:`.
    private var hostsStatusItemOutOfProcess: Bool {
        if let statusItemHostsOutOfProcess {
            return statusItemHostsOutOfProcess()
        }
        guard statusContextMenuPresenter == nil else { return false }
        return statusItem?.responds(to: NSSelectorFromString("setLongPressAction:")) == true
    }

    /// Opens the context menu now, or after `settle` on an out-of-process host. Repeated requests
    /// for the same click replace the pending one, so the menu opens once, after the last signal.
    private func requestStatusContextMenu(
        settle: TimeInterval,
        eventType: NSEvent.EventType? = nil,
        pressedMouseButtons: Int = NSEvent.pressedMouseButtons
    ) {
        let now = statusItemUptime()
        let resolvedEventType = eventType ?? NSApp?.currentEvent?.type
        let eventName = Self.statusEventTypeName(resolvedEventType)
        let buttons = "0x\(String(pressedMouseButtons, radix: 16))"
        let settleText = String(format: "%.3f", settle)
        let uptimeText = String(format: "%.3f", now)
        guard hostsStatusItemOutOfProcess else {
            traceStatusItem(
                "requestStatusContextMenu event=\(eventName) buttons=\(buttons) settle=\(settleText) uptime=\(uptimeText) decision=synchronous(inProcess)"
            )
            showStatusContextMenu(
                eventType: resolvedEventType,
                pressedMouseButtons: pressedMouseButtons
            )
            return
        }
        guard now >= suppressContextMenuUntil else {
            traceStatusItem(
                "requestStatusContextMenu event=\(eventName) buttons=\(buttons) settle=\(settleText) uptime=\(uptimeText) guard=suppressContextMenuUntil"
            )
            restoreStatusItemHighlight()
            return
        }
        guard !pressTriggered else {
            traceStatusItem(
                "requestStatusContextMenu event=\(eventName) buttons=\(buttons) settle=\(settleText) uptime=\(uptimeText) guard=pressTriggered"
            )
            restoreStatusItemHighlight()
            return
        }
        // The host may follow the secondary click with a synthetic primary pair; it must not
        // toggle the panel while the menu is still on its way.
        // Bounded, so a request that ends up not presenting can never strand primary clicks.
        pressAllowsToggle = false
        suppressReleaseUntil = max(suppressReleaseUntil, now + settle + 0.1)
        setStatusItemHighlighted(true)
        let replacedPending = pendingContextMenu != nil
        pendingContextMenu?.cancel()
        weak var weakWork: DispatchWorkItem?
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, weakWork?.isCancelled == false else { return }
                self.pendingContextMenu = nil
                self.showStatusContextMenu(
                    eventType: resolvedEventType,
                    pressedMouseButtons: pressedMouseButtons
                )
            }
        }
        weakWork = work
        pendingContextMenu = work
        traceStatusItem(
            "requestStatusContextMenu event=\(eventName) buttons=\(buttons) settle=\(settleText) uptime=\(uptimeText) decision=schedule(replacedPending=\(replacedPending))"
        )
        statusContextMenuScheduler(settle, work)
    }

    private func showStatusContextMenu(
        eventType: NSEvent.EventType? = nil,
        pressedMouseButtons: Int = NSEvent.pressedMouseButtons
    ) {
        pendingContextMenu?.cancel()
        pendingContextMenu = nil
        let now = statusItemUptime()
        let eventName = Self.statusEventTypeName(eventType ?? NSApp?.currentEvent?.type)
        let buttons = "0x\(String(pressedMouseButtons, radix: 16))"
        let uptimeText = String(format: "%.3f", now)
        guard now >= suppressContextMenuUntil else {
            traceStatusItem(
                "showStatusContextMenu event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) guard=suppressContextMenuUntil"
            )
            restoreStatusItemHighlight()
            return
        }
        // Keep the release timer alive once hold-to-talk has started. Opening AppKit's modal menu
        // here can consume the left-button release and strand both recording and `pressTriggered`.
        guard !pressTriggered else {
            traceStatusItem(
                "showStatusContextMenu event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) guard=pressTriggered"
            )
            return
        }
        traceStatusItem(
            "showStatusContextMenu event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) decision=present"
        )

        // A pop-up menu runs a modal event loop. Suppress every duplicate/synthetic status-item
        // action while it is open. Its dismissal event is remembered below so the next distinct
        // primary mouse-up can be recognized even if the out-of-process host omits mouse-down.
        pressAllowsToggle = false
        stopPressTimer()
        suppressContextMenuUntil = .infinity
        suppressReleaseUntil = .infinity
        suppressResignActiveHideUntil = 0
        suppressStatusItemReopenUntil = 0
        resignActiveAwaitingMonitorMouseDown = false

        let menu = makeStatusContextMenu()
        if let statusContextMenuPresenter {
            // Tests replace only AppKit's blocking menu tracker; keep its visual state real.
            setStatusItemHighlighted(true)
            statusContextMenuPresenter(menu)
        } else if let statusItem {
            Self.presentStatusMenu(menu, on: statusItem)
        }

        let dismissedAt = statusItemUptime()
        restoreStatusItemHighlight()
        contextMenuDismissalEventNumber = statusItemEventNumber()
        // Escape and keyboard activation expose no mouse event number, but the next physical click
        // can still arrive as a mouse-up only on macOS 26. Arm the fallback either way and keep the
        // time-based tail for hosts that omit the dismissal event number.
        acceptsStandalonePostMenuMouseUp = true
        suppressContextMenuUntil = dismissedAt + 0.15
        suppressReleaseUntil = contextMenuDismissalEventNumber == nil
            ? dismissedAt + Self.contextMenuSyntheticClickTail
            : 0
    }

    /// Uses `NSStatusItem.menu` so AppKit owns the menu's click tracking and pressed appearance.
    /// `performClick` is synchronous for status-menu tracking, so restoring the previous menu after
    /// it returns keeps ordinary primary clicks routed to the controller.
    static func presentStatusMenu(_ menu: NSMenu, on statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        let previousMenu = statusItem.menu
        statusItem.menu = menu
        defer { statusItem.menu = previousMenu }
        button.performClick(nil)
    }

    @objc func openSettingsFromStatusMenu(_ sender: Any?) {
        showSettings(nil)
    }

    @objc func switchBackendFromStatusMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let backend = HomeBackend(rawValue: rawValue) else { return }
        if let switchHomeBackend {
            switchHomeBackend(backend)
        } else {
            guard let store else { return }
            if backend != .demo, store.homeBackend != .demo { return }
            store.switchBackend(backend)
        }
    }

    @objc func openConnectionSettingsFromStatusMenu(_ sender: Any?) {
        showSettings(.connection)
    }

    @objc func openUpdatesFromStatusMenu(_ sender: Any?) {
        showSettings(.about)
        // This is an explicit check; the About tab's `checkForUpdatesIfNeeded()` skips automatic
        // checks that are disabled or recent, so do not rely on it.
        if let performUpdateCheck {
            performUpdateCheck()
        } else if let store {
            Task { await store.checkForUpdates() }
        }
    }

    @objc func quitFromStatusMenu(_ sender: Any?) {
        terminateApplication()
    }

    // MARK: - Menu Bar Label (#54)

    func shouldRunLabelTimer(now: Date = Date()) -> Bool {
        guard didInstall, let store else { return false }
        let speech = SpeechInputController.shared
        if speech.isListening || speech.isHoldToTalk || isStatusItemPressActive {
            return true
        }
        // A pending shrink is settled by one more tick; without it an idle readout keeps the wider
        // reserve until the next text change (#420). The tick clears the flag, so the loop stops again.
        if MenuBarWidthStabilizer.needsSettle(widthState) { return true }
        if store.undoBanner != nil || store.toastNotice != nil {
            return true
        }
        return store.scheduledCommands.contains { $0.fireDate.timeIntervalSince(now) <= 60 }
    }

    func updateLabelTimer(now: Date = Date()) {
        subMinuteWakeTimer?.invalidate()
        subMinuteWakeTimer = nil
        if shouldRunLabelTimer(now: now) {
            startLabelUpdates()
            return
        }
        labelTimer?.invalidate()
        labelTimer = nil
        guard didInstall, let store,
              let nextFire = store.scheduledCommands.map(\.fireDate).min() else { return }
        let delayUntilSubMinute = nextFire.timeIntervalSince(now) - 60
        guard delayUntilSubMinute > 0 else { return }
        let wake = Timer(
            timeInterval: delayUntilSubMinute,
            target: self,
            selector: #selector(handleSubMinuteWake(_:)),
            userInfo: nil,
            repeats: false
        )
        // One second of leeway lets the system coalesce this wake with timers it already runs. It can
        // only land late, and the 0.5 s loop it starts re-derives every value from `fireDate`, so the
        // worst case is entering the last minute one second late.
        wake.tolerance = 1
        subMinuteWakeTimer = wake
        RunLoop.main.add(wake, forMode: .common)
    }

    private func observeStatusItemState(generation: UInt64) {
        guard didInstall, generation == observationGeneration, store != nil else { return }
        withObservationTracking {
            syncStatusItem()
            readObservableStatusInputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.didInstall, generation == self.observationGeneration else { return }
                self.observeStatusItemState(generation: generation)
            }
        }
        updateLabelTimer()
    }

    private func readObservableStatusInputs() {
        let speech = SpeechInputController.shared
        _ = speech.isListening
        _ = speech.isHoldToTalk
        _ = speech.draft
        if let store {
            _ = store.menuBarIconState(isListening: speech.isListening)
            _ = store.menuBarPinnedReadouts
            _ = store.menuBarText
            _ = MenuBarStatusSummary.text(for: store)
            _ = store.undoBanner?.id
            _ = store.toastNotice?.id
            _ = store.scheduledCommands
        }
    }

    private func startLabelUpdates() {
        guard labelTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handleLabelTimerTick(_:)),
            userInfo: nil,
            repeats: true
        )
        // 100 ms of leeway on a 0.5 s refresh is invisible on screen, and it lets the system batch
        // this wake with the timers it already has to run (idle wakeups, #26).
        timer.tolerance = 0.1
        labelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleSubMinuteWake(_ timer: Timer) {
        subMinuteWakeTimer = nil
        syncStatusItem()
        updateLabelTimer()
    }

    @objc private func handleLabelTimerTick(_ timer: Timer) {
        syncStatusItem()
        updateLabelTimer()
    }

    /// Pushes icon, text, tooltip and accessibility label onto the status button without animation.
    func syncStatusItem() {
        guard let statusItem, let button = statusItem.button, let store else { return }
        let speech = SpeechInputController.shared
        let iconState = store.menuBarIconState(isListening: speech.isListening)
        let text = speech.isListening ? Self.speechLabel(speech.draft) : store.menuBarText
        let summary = MenuBarStatusSummary.text(for: store)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var contentChanged = false
        if iconState != labelIconState {
            labelIconState = iconState
            if let image = Self.statusBarImage(for: iconState) {
                button.image = image
            }
            contentChanged = true
        }
        if text != labelText {
            labelText = text
            button.attributedTitle = Self.statusTitle(text, isSpeech: speech.isListening)
            contentChanged = true
        }
        // A pending shrink owes one more unchanged reading before it commits; skipping the block because
        // the text stopped changing would hold the wider reserve until the next text change (#420).
        if contentChanged || MenuBarWidthStabilizer.needsSettle(widthState) {
            let measured = Self.measuredStatusItemWidth(button: button, text: text)
            widthState = MenuBarWidthStabilizer.update(
                state: widthState,
                text: text,
                measuredWidth: measured
            )
            let targetLength = widthState.reservedWidth.map { CGFloat($0) } ?? NSStatusItem.variableLength
            if abs(statusItem.length - targetLength) > 0.5 {
                statusItem.length = targetLength
            }
        }
        if summary != tooltipText {
            tooltipText = summary
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
            button.setAccessibilityHelp(summary)
        }
    }

    /// Resolves the status-bar image for `MenuBarIconState`:
    /// - `.none`: native template SF Symbol (adapts to light/dark/tinted menu bars)
    /// - `.attention`: template SF Symbol + subtle bottom-right cutout dot (still `isTemplate = true`)
    /// - `.safetyAlert`: existing high-contrast `.systemRed` palette symbol
    static func statusBarImage(for state: MenuBarIconState) -> NSImage? {
        guard let base = statusBarImage(symbolName: state.symbolName) else { return nil }
        switch state.badge {
        case .none:
            base.isTemplate = true
            return base
        case .attention:
            return badgedTemplateImage(base: base)
        case .safetyAlert:
            base.isTemplate = false
            let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let painted = base.withSymbolConfiguration(red) ?? base
            painted.isTemplate = false
            return painted
        }
    }

    /// Composites a template SF Symbol with a subtle 4.5 pt bottom-right dot separated by a 1 pt
    /// clear halo so the entire icon remains `isTemplate = true` and adapts to any menu-bar tint.
    private static func badgedTemplateImage(base: NSImage) -> NSImage {
        let baseSize = base.size.width > 0 && base.size.height > 0 ? base.size : NSSize(width: 18, height: 18)
        let canvasSize = NSSize(width: max(18, ceil(baseSize.width) + 2), height: max(18, ceil(baseSize.height)))
        let composite = NSImage(size: canvasSize, flipped: false) { rect in
            let symbolOrigin = NSPoint(
                x: floor((rect.width - baseSize.width) / 2),
                y: floor((rect.height - baseSize.height) / 2)
            )
            base.draw(
                in: NSRect(origin: symbolOrigin, size: baseSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            let dotDiameter: CGFloat = 4.5
            let haloInset: CGFloat = 1.0
            let dotRect = NSRect(
                x: rect.maxX - dotDiameter - 0.5,
                y: 1.5,
                width: dotDiameter,
                height: dotDiameter
            )
            let haloRect = dotRect.insetBy(dx: -haloInset, dy: -haloInset)
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .copy
                NSColor.clear.setFill()
                NSBezierPath(ovalIn: haloRect).fill()
                context.restoreGraphicsState()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composite.isTemplate = true
        return composite
    }

    /// Intrinsic width of the status button for the current icon + attributed title.
    private static func measuredStatusItemWidth(button: NSStatusBarButton, text: String?) -> Double {
        guard let text, !text.isEmpty else { return 0 }
        if let cellWidth = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 22)).width,
           cellWidth > 0 {
            return Double(ceil(cellWidth))
        }
        let imageWidth = button.image?.size.width ?? 18
        let titleWidth = button.attributedTitle.size().width
        return Double(ceil(imageWidth + titleWidth + 14))
    }

    /// Resolves the status-bar SF Symbol image with a safe fallback so an unavailable symbol name
    /// never leaves the menu-bar button blank or stuck on the previous icon.
    private static func statusBarImage(symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "house", accessibilityDescription: nil)
    }

    /// Last ten characters of the live transcript, or "聆听中…" before the first words arrive.
    private static func speechLabel(_ draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.tr("聆听中…", "Listening…") }
        if trimmed.count > 10 {
            return String(trimmed.suffix(10))
        }
        return trimmed
    }

    /// Same typography as the SwiftUI label: 12 pt rounded semibold for the live transcript and
    /// medium with monospaced digits for all device readouts so digit updates never shift width.
    private static func statusTitle(_ text: String?, isSpeech: Bool) -> NSAttributedString {
        guard let text, !text.isEmpty else { return NSAttributedString(string: "") }
        let size: CGFloat = 12
        let weight: NSFont.Weight = isSpeech ? .semibold : .medium
        let font: NSFont
        if !isSpeech {
            font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        } else {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        return NSAttributedString(
            string: " " + text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    // MARK: - Showing & Hiding

    var isPanelVisible: Bool {
        panelWindow?.isVisible == true && !isClosing
    }

    /// True for the control center panel or a window it owns (sheet, context menu, child), so both
    /// keyboard handling and the outside-click rule can tell it apart from Settings.
    func isPanelWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panelWindow else { return false }
        if window === backdropWindow { return false }
        if window === panelWindow { return true }
        if window.parent === panelWindow { return true }
        if panelWindow.attachedSheet === window { return true }
        return panelWindow.childWindows?.contains { $0 === window } ?? false
    }

    func togglePanel() {
        if isPanelVisible {
            // An expired session keeps the panel open for the QR overlay; a second click on the
            // icon only closes the panel once that overlay is already the active view.
            if let store, store.miSessionBlocksControl, !store.isShowingMiReauth {
                withAnimation(AppleMotion.resolve(.snappy)) { store.presentMiReauth() }
                return
            }
            hidePanel()
        } else {
            if let store, store.miSessionBlocksControl {
                withAnimation(AppleMotion.resolve(.snappy)) { store.presentMiReauth() }
            }
            showPanel()
        }
    }

    // MARK: - Panel Content

    /// Creates the window on demand and records it. Presentation only reads `panelWindow`.
    func ensurePanelWindow(theme: PanelTheme) -> NSPanel {
        if let panelWindow { return panelWindow }
        let panel = Self.makePanel(theme: theme)
        if let menuBarPanel = panel as? MenuBarPanel {
            menuBarPanel.onTextInputFocused = { [weak self] in
                self?.activateForTextInputIfNeeded()
            }
        }
        panelWindow = panel
        installPanelGeometryObservers(for: panel)
        return panel
    }

    /// Escalates a non-activating panel session to active app status only when a text input
    /// (`TextField` / `NSTextView`) takes focus, keeping CJK IME candidates, Emoji picker, and
    /// standard clipboard shortcuts reliable while leaving ordinary clicks non-activating.
    func activateForTextInputIfNeeded() {
        guard presentsActively, isPanelVisible, let panel = panelWindow else { return }
        if !isApplicationActiveProvider() {
            activateApplicationForTextInput()
        }
        if !panel.isKeyWindow {
            panel.makeKey()
        }
    }

    func refreshPanelContent(theme: PanelTheme) {
        guard let panel = panelWindow, let store else { return }
        if let hosting = panel.contentView, hostedPanelTheme == theme {
            // Warm reuse within the 45 s grace window: restore first responder so keyboard and
            // search focus behave identically to a freshly built hosting tree (#474).
            panel.initialFirstResponder = hosting
            if panel.firstResponder !== hosting {
                _ = panel.makeFirstResponder(hosting)
            }
            return
        }
        if hostedPanelTheme == .liquidGlass {
            hideBackdropShadow()
        }
        panel.contentView = nil
        panel.contentMinSize = .zero
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let hosting = PanelHostingView(
            rootView: Self.panelRoot(
                store: store,
                theme: theme,
                adaptiveProbe: theme == .liquidGlass ? panelAdaptiveHeightProbe : nil
            )
        )
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        switch theme {
        case .classic:
            hosting.layer?.cornerRadius = Self.panelCornerRadius
            hosting.layer?.masksToBounds = true
        case .liquidGlass:
            hosting.layer?.cornerRadius = 0
            hosting.layer?.masksToBounds = false
        }
        hostedPanelTheme = theme
        panel.contentView = hosting
        panel.initialFirstResponder = hosting
        _ = panel.makeFirstResponder(hosting)
    }

    func dropPanelContent() {
        cancelWarmUnload()
        hideBackdropShadow()
        isApplyingPanelGeometry = false
        isEntranceAnimating = false
        hasPendingGeometryPass = false
        isGeometryPassScheduled = false
        panelAdaptiveHeightProbe.resetNotificationBaseline()
        panelWindow?.contentView = nil
        panelWindow?.contentMinSize = .zero
        panelWindow?.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        hostedPanelTheme = nil
    }

    /// Arms a 45 s grace timer after hiding so rapid re-opens stay instant, while long idle periods
    /// release the SwiftUI hosting tree to keep background memory low (P0-7).
    func scheduleWarmUnload() {
        cancelWarmUnload()
        guard panelWindow?.contentView != nil else { return }
        warmUnloadScheduledAt = statusItemUptime()
        weak var weakWork: DispatchWorkItem?
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, weakWork?.isCancelled == false else { return }
                self.pendingWarmUnloadWork = nil
                self.warmUnloadScheduledAt = nil
                guard !self.isPanelVisible, !self.isClosing else { return }
                self.dropPanelContent()
            }
        }
        weakWork = work
        pendingWarmUnloadWork = work
        warmUnloadScheduler(Self.warmUnloadDelay, work)
    }

    func cancelWarmUnload() {
        pendingWarmUnloadWork?.cancel()
        pendingWarmUnloadWork = nil
        warmUnloadScheduledAt = nil
    }

    /// Unloads the warm hosting tree immediately when macOS signals `.warning` or `.critical`
    /// memory pressure while the panel is hidden. Never tears down a visible panel.
    func handleMemoryPressure(eventMask: DispatchSource.MemoryPressureEvent) {
        guard eventMask.contains(.warning) || eventMask.contains(.critical) else { return }
        guard !isPanelVisible, !isClosing else { return }
        dropPanelContent()
    }

    private func installMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            MainActor.assumeIsolated {
                self?.handleMemoryPressure(eventMask: event)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func stopMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    private static func panelRoot(
        store: HomeStore,
        theme: PanelTheme,
        adaptiveProbe: PanelAdaptiveHeightProbe? = nil
    ) -> AnyView {
        switch theme {
        case .classic:
            return AnyView(ClassicControlCenterPanel(store: store))
        case .liquidGlass:
            return AnyView(
                ControlCenterPanel(store: store)
                    .environment(\.panelAdaptiveHeightProbe, adaptiveProbe)
                    .environment(\.appearsActive, true)
            )
        }
    }

    // MARK: - Status Item Gesture

    /// A short left click toggles the panel, a left hold starts dictation, and a right click opens
    /// the native context menu.
    /// On macOS 26+, the system menu bar (`NSMenuBarNavigationSceneExtension`) hosts status items
    /// out-of-process: it delivers holds via `setLongPressAction:` (`_performSecondaryAction:type:`)
    /// and delivers short clicks as a synthesized mouseDown+mouseUp pair upon release. Combining
    /// button actions, `setLongPressAction:`, and mouse-down monitors covers both in-process and
    /// out-of-process menu bar hosts.
    @objc func handleStatusItemPress() {
        handleStatusItemEvent(
            eventType: NSApp.currentEvent?.type,
            pressedMouseButtons: NSEvent.pressedMouseButtons
        )
    }

    func handleStatusItemEvent(eventType: NSEvent.EventType?, pressedMouseButtons: Int) {
        let eventNumber = statusItemEventNumber()
        let now = statusItemUptime()
        let decision = StatusItemEventDecision.decide(
            eventType: eventType,
            pressedMouseButtons: pressedMouseButtons,
            now: now,
            state: StatusItemEventDecision.State(
                isContextMenuDismissalEvent: isContextMenuDismissalEvent(eventNumber),
                pressTriggered: pressTriggered,
                isPressActive: isStatusItemPressActive,
                acceptsStandalonePostMenuMouseUp: acceptsStandalonePostMenuMouseUp,
                suppressReleaseUntil: suppressReleaseUntil,
                suppressContextMenuUntil: suppressContextMenuUntil
            )
        )
        traceStatusItem(
            "handleStatusItemEvent event=\(Self.statusEventTypeName(eventType)) "
                + "buttons=0x\(String(pressedMouseButtons, radix: 16)) "
                + "uptime=\(String(format: "%.3f", now)) \(decision.trace)"
        )
        if decision.cancelsReleaseSuppression { suppressReleaseUntil = 0 }
        if decision.clearsPostMenuMouseUp { clearPostMenuPrimaryMouseUp() }
        switch decision.step {
        case .none:
            break
        case .beginPress:
            resignActiveAwaitingMonitorMouseDown = false
            if (pressedMouseButtons & 0x1) != 0 {
                suppressStatusItemReopenUntil = 0
            }
            pressAllowsToggle = true
            setStatusItemHighlighted(true)
            beginPress()
        case .requestContextMenu:
            requestStatusContextMenu(
                settle: ContextMenuSettle.fallback,
                eventType: eventType,
                pressedMouseButtons: pressedMouseButtons
            )
        case .finishPress:
            finishPress()
        case .postMenuToggle:
            pressAllowsToggle = false
            suppressReleaseUntil = statusItemUptime() + 0.15
            performStatusItemToggle()
        case .toggle:
            performStatusItemToggle()
        }
        if decision.restoresHighlight { restoreStatusItemHighlight() }
    }

    @objc func handleStatusItemNativeLongPress(_ sender: Any?) {
        handleStatusItemNativeLongPressEvent(
            eventType: NSApp.currentEvent?.type,
            pressedMouseButtons: NSEvent.pressedMouseButtons
        )
    }

    func handleStatusItemNativeLongPressEvent(
        eventType: NSEvent.EventType?,
        pressedMouseButtons: Int
    ) {
        let now = statusItemUptime()
        let eventName = Self.statusEventTypeName(eventType)
        let buttons = "0x\(String(pressedMouseButtons, radix: 16))"
        let uptimeText = String(format: "%.3f", now)
        if eventType == .rightMouseDown || (pressedMouseButtons & 0x2) != 0 {
            traceStatusItem(
                "handleStatusItemNativeLongPressEvent event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) decision=requestStatusContextMenu(native)"
            )
            requestStatusContextMenu(
                settle: ContextMenuSettle.native,
                eventType: eventType,
                pressedMouseButtons: pressedMouseButtons
            )
            return
        }

        guard now >= suppressReleaseUntil else {
            traceStatusItem(
                "handleStatusItemNativeLongPressEvent event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) guard=suppressReleaseUntil"
            )
            return
        }
        guard store?.enableVoiceInput ?? true else {
            traceStatusItem(
                "handleStatusItemNativeLongPressEvent event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) guard=voiceInputDisabled"
            )
            restoreStatusItemHighlight()
            return
        }
        traceStatusItem(
            "handleStatusItemNativeLongPressEvent event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) decision=primaryLongPress(finishImmediately=\((pressedMouseButtons & 0x1) == 0))"
        )
        clearPostMenuPrimaryMouseUp()
        suppressStatusItemReopenUntil = 0
        resignActiveAwaitingMonitorMouseDown = false
        if (pressedMouseButtons & 0x1) != 0 {
            setStatusItemHighlighted(true)
        }
        if !pressTriggered {
            pressTriggered = true
            pressAllowsToggle = false
            pressStartedAt = now
            beginHoldToTalk()
        }
        if (pressedMouseButtons & 0x1) != 0 {
            startPressTimerIfNeeded()
        } else {
            finishPress()
        }
    }

    /// `handleMouseDown` routes a status-item hit here. Internal so gesture tests can exercise the
    /// monitor path without a live menu-bar window.
    ///
    /// `allowsPostMenuToggle` is true only when the press landed on the button itself; the wider
    /// hold-tracking tolerance must not consume the pending post-menu click.
    func beginHoldDetectionFromMonitor(
        allowsPostMenuToggle: Bool = false,
        preservesDismissalReopenGuard: Bool = false
    ) {
        let now = statusItemUptime()
        guard !pressTriggered else { return }
        if !preservesDismissalReopenGuard, allowsPostMenuToggle || !isPanelVisible {
            suppressStatusItemReopenUntil = 0
        }
        if now < suppressReleaseUntil {
            guard allowsPostMenuToggle else { return }
            suppressReleaseUntil = 0
        }
        setStatusItemHighlighted(true)
        if pressTimer == nil {
            // The first physical press after the context menu closed is the click that dismissed it.
            // Its release must toggle the panel even when the host forwards this down to the monitor
            // but not to the button, so consume the pending fallback and let the press toggle.
            if allowsPostMenuToggle, acceptsStandalonePostMenuMouseUp {
                clearPostMenuPrimaryMouseUp()
                pressAllowsToggle = true
            } else {
                pressAllowsToggle = false
            }
            pressStartedAt = now
            startPressTimerIfNeeded()
        }
    }

    private func beginPress() {
        let now = statusItemUptime()
        guard now >= suppressReleaseUntil, !pressTriggered else { return }
        if pressTimer == nil {
            pressStartedAt = now
        }
        startPressTimerIfNeeded()
    }

    private func startPressTimerIfNeeded() {
        guard pressTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.holdTick,
            target: self,
            selector: #selector(handlePressTick(_:)),
            userInfo: nil,
            repeats: true
        )
        pressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateLabelTimer()
    }

    @objc private func handlePressTick(_ timer: Timer) {
        if (NSEvent.pressedMouseButtons & 0x1) != 0 {
            guard store?.enableVoiceInput ?? true else { return }
            guard !pressTriggered,
                  statusItemUptime() - pressStartedAt >= Self.holdThreshold else { return }
            // Keep ticking so the release still stops dictation.
            pressTriggered = true
            beginHoldToTalk()
            return
        }
        // Released outside the button: the up action never arrives, so finish from here.
        finishPress()
    }

    private func finishPress() {
        guard pressTimer != nil || pressTriggered else { return }
        let now = statusItemUptime()
        stopPressTimer()

        if pressTriggered {
            pressTriggered = false
            pressAllowsToggle = false
            suppressReleaseUntil = now + 0.45
            endHoldToTalk()
            restoreStatusItemHighlight()
            return
        }

        // AppKit can deliver both the up action and the timer fallback for one release.
        guard now >= suppressReleaseUntil else {
            restoreStatusItemHighlight()
            return
        }
        if pressAllowsToggle {
            pressAllowsToggle = false
            suppressReleaseUntil = now + 0.15
            performStatusItemToggle()
        } else if isPanelVisible {
            // A monitor-started press while the panel is open ended on physical release; keep
            // deactivation suppression alive across the XPC hop until `NSMenuBarNavigateAction`
            // reaches the status item.
            suppressResignActiveHideUntil = max(
                suppressResignActiveHideUntil,
                now + ContextMenuSettle.fallback
            )
        }
        restoreStatusItemHighlight()
    }

    private func performStatusItemToggle() {
        let now = statusItemUptime()
        suppressResignActiveHideUntil = 0
        resignActiveAwaitingMonitorMouseDown = false
        if !isPanelVisible, now < suppressStatusItemReopenUntil {
            suppressStatusItemReopenUntil = 0
            traceStatusItem(
                "performStatusItemToggle uptime=\(String(format: "%.3f", now)) guard=suppressStatusItemReopenUntil"
            )
            restoreStatusItemHighlight()
            return
        }
        suppressStatusItemReopenUntil = 0
        if let statusItemToggle {
            statusItemToggle()
        } else {
            togglePanel()
        }
    }

    /// Keeps the status item selected while its control-center panel remains visible, and otherwise
    /// preserves the transient pressed appearance only for an active primary gesture.
    func restoreStatusItemHighlight() {
        setStatusItemHighlighted(isPanelVisible || isStatusItemPressActive)
    }

    func setStatusItemHighlighted(_ highlighted: Bool) {
        Self.setStatusItemHighlight(on: statusItem?.button, highlighted: highlighted)
    }

    static func setStatusItemHighlight(on button: NSButton?, highlighted: Bool) {
        button?.highlight(highlighted)
    }

    private func isContextMenuDismissalEvent(_ eventNumber: Int?) -> Bool {
        guard let eventNumber, let contextMenuDismissalEventNumber else { return false }
        return eventNumber == contextMenuDismissalEventNumber
    }

    private func clearPostMenuPrimaryMouseUp() {
        acceptsStandalonePostMenuMouseUp = false
        contextMenuDismissalEventNumber = nil
    }

    var isStatusItemPressActive: Bool {
        pressTimer != nil || pressTriggered
    }

    private func stopPressTimer() {
        pressTimer?.invalidate()
        pressTimer = nil
        updateLabelTimer()
    }

    // MARK: - Hold to Talk

    func beginHoldToTalk() {
        guard let store, store.enableVoiceInput else { return }
        suppressStatusItemReopenUntil = 0
        resignActiveAwaitingMonitorMouseDown = false
        SpeechInputController.shared.startHoldToTalk(store: store)
        syncStatusItem()
        updateLabelTimer()
        showPanel()
        store.presentAssistantBar(startVoice: false)
        // A microphone prompt or the first audio buffer can steal key status; re-assert the panel.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, self.isPanelVisible, let store = self.store, store.isShowingAssistantBar else { return }
            self.syncStatusItem()
            self.showPanel()
        }
    }

    func endHoldToTalk() {
        guard let store else { return }
        SpeechInputController.shared.finishHoldToTalk(store: store)
        syncStatusItem()
        updateLabelTimer()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, self.isPanelVisible, let store = self.store, store.isShowingAssistantBar else { return }
            self.syncStatusItem()
            self.showPanel()
        }
    }

    func cancelHoldToTalkOnDisable() {
        let wasTriggered = pressTriggered
        pressTriggered = false
        if wasTriggered {
            pressAllowsToggle = false
            stopPressTimer()
        }
        if let store {
            SpeechInputController.shared.handleVoiceInputPreferenceChanged(enabled: false, store: store)
        }
        syncStatusItem()
        updateLabelTimer()
        restoreStatusItemHighlight()
    }

    // MARK: - Outside Click, Screens & Preferences

    private func installPanelGeometryObservers(for panel: NSPanel) {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePanelDidResignKey() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        })
    }

    private func installObservers() {
        // Outside clicks end the session through two public signals: activating another app
        // (`didResignActive`) and another window of ours taking key status. A SwiftUI context menu
        // opens its own window while the panel stays up, so that case is explicitly exempt.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleOtherWindowBecameKey(window)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationResignActive()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        })
        // Height or skin changed in Settings while the panel is open: apply it right away.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUserDefaultsDidChange()
            }
        })
    }

    func handleUserDefaultsDidChange() {
        let current = WatchedPreferences(from: userDefaults)
        guard current != lastSeenPreferences else { return }
        lastSeenPreferences = current
        handlePreferencesChanged()
    }

    /// Another window of ours (Settings, etc.) took key status: the panel closes, like the extra
    /// did when the user moved to the Settings scene. The status item's own window, modal high-risk
    /// confirmation alerts, the camera window, and anything the panel spawned (sheet, popover,
    /// context menu) are exempt.
    func handleOtherWindowBecameKey(_ window: NSWindow?) {
        guard isPanelVisible, let window else { return }
        guard window !== backdropWindow else { return }
        guard !isPanelWindow(window) else { return }
        guard window !== statusItem?.button?.window else { return }
        guard window !== CameraLivePanelController.shared.panelWindow else { return }
        guard !isModalConfirmationActiveProvider(), NSApp.modalWindow !== window else { return }
        hidePanel()
    }

    func installMouseMonitors() {
        guard localMouseMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                    ?? event.locationInWindow
                self?.handleMouseDown(
                    in: event.window,
                    at: point,
                    eventType: event.type,
                    pressedMouseButtons: NSEvent.pressedMouseButtons
                )
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDown(
                    in: nil,
                    at: NSEvent.mouseLocation,
                    eventType: event.type,
                    pressedMouseButtons: NSEvent.pressedMouseButtons
                )
            }
        }
    }

    var hasActiveMouseMonitors: Bool {
        localMouseMonitor != nil || globalMouseMonitor != nil
    }

    func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    /// A click need not activate another app (desktop, nonactivating panels, other status items).
    /// Keep our own controls and status button working, and never swallow the original click.
    func handleMouseDown(
        in window: NSWindow?,
        at screenPoint: NSPoint,
        eventType: NSEvent.EventType = .leftMouseDown,
        pressedMouseButtons: Int = NSEvent.pressedMouseButtons
    ) {
        if let button = statusItem?.button,
           let statusWindow = button.window {
            let statusRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if window === statusWindow || Self.isStatusItemHit(
                statusRect: statusRect,
                point: screenPoint,
                eventType: eventType
            ) {
                let now = statusItemUptime()
                let isDelayedDismissalMouseDown = !isPanelVisible && resignActiveAwaitingMonitorMouseDown
                resignActiveAwaitingMonitorMouseDown = false
                if isPanelVisible {
                    suppressResignActiveHideUntil = max(
                        suppressResignActiveHideUntil,
                        now + ContextMenuSettle.fallback + 0.1
                    )
                } else if isDelayedDismissalMouseDown {
                    noteImplicitDismissalForStatusItemReopenGuard(now: now)
                } else {
                    suppressStatusItemReopenUntil = 0
                }
                let eventName = Self.statusEventTypeName(eventType)
                let buttons = "0x\(String(pressedMouseButtons, radix: 16))"
                let uptimeText = String(format: "%.3f", now)
                if eventType == .rightMouseDown {
                    traceStatusItem(
                        "handleMouseDown event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) decision=requestStatusContextMenu(fallback)"
                    )
                    requestStatusContextMenu(
                        settle: ContextMenuSettle.fallback,
                        eventType: eventType,
                        pressedMouseButtons: pressedMouseButtons
                    )
                } else if eventType == .leftMouseDown, (pressedMouseButtons & 0x1) != 0 {
                    // The 6 pt tolerance serves hold tracking. A post-menu click must land on the
                    // button itself, or a neighboring status item could toggle this panel.
                    let allowsPostMenuToggle = statusRect.contains(screenPoint)
                    traceStatusItem(
                        "handleMouseDown event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) decision=beginHoldDetectionFromMonitor(allowsPostMenuToggle=\(allowsPostMenuToggle))"
                    )
                    beginHoldDetectionFromMonitor(
                        allowsPostMenuToggle: allowsPostMenuToggle,
                        preservesDismissalReopenGuard: isDelayedDismissalMouseDown
                    )
                } else {
                    traceStatusItem(
                        "handleMouseDown event=\(eventName) buttons=\(buttons) uptime=\(uptimeText) guard=ignoredStatusHit"
                    )
                }
                return
            }
        }
        if eventType == .leftMouseDown, !isPanelVisible {
            let isMenuBarHit = hostsStatusItemOutOfProcess && Self.isMenuBarBandPoint(screenPoint)
            if resignActiveAwaitingMonitorMouseDown, isMenuBarHit {
                resignActiveAwaitingMonitorMouseDown = false
                noteImplicitDismissalForStatusItemReopenGuard()
            } else if (pressedMouseButtons & 0x1) != 0 || !isMenuBarHit {
                resignActiveAwaitingMonitorMouseDown = false
                suppressStatusItemReopenUntil = 0
            }
        }
        guard isPanelVisible, let panel = panelWindow else { return }
        guard !isPanelWindow(window) else { return }
        if let cameraWindow = CameraLivePanelController.shared.panelWindow,
           cameraWindow.isVisible,
           window === cameraWindow || cameraWindow.frame.contains(screenPoint) {
            return
        }
        if panel.frame.contains(screenPoint) { return }
        if let children = panel.childWindows,
           children.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) { return }
        if SpeechInputController.shared.isListening
            || SpeechInputController.shared.isHoldToTalk
            || pressTriggered
            || pressTimer != nil
            || HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown { return }
        if eventType == .leftMouseDown,
           hostsStatusItemOutOfProcess,
           Self.isMenuBarBandPoint(screenPoint) {
            noteImplicitDismissalForStatusItemReopenGuard()
        }
        hidePanel()
    }

    /// Primary hold tracking gets a small tolerance for host/window coordinate drift. Secondary
    /// clicks stay inside the real item so an adjacent menu-bar item cannot open this app's menu.
    static func isStatusItemHit(
        statusRect: NSRect,
        point: NSPoint,
        eventType: NSEvent.EventType
    ) -> Bool {
        if eventType == .rightMouseDown {
            return statusRect.contains(point)
        }
        return statusRect.insetBy(dx: -6, dy: -6).contains(point)
    }

    /// True when `point` lies in the menu-bar strip at the top of any screen. An out-of-process
    /// status item (`NSMenuBarNavigationSceneExtension`) can keep its local scene window at `.zero`
    /// while the user clicks the real menu bar, whereas clicks in the workspace below the menu bar
    /// never belong to the status item.
    static func isMenuBarBandPoint(_ point: NSPoint, screens: [NSScreen] = NSScreen.screens) -> Bool {
        for screen in screens {
            let frame = screen.frame
            guard point.x >= frame.minX - 6, point.x <= frame.maxX + 6 else { continue }
            let bandFloor = min(screen.visibleFrame.maxY, frame.maxY - 44) - 6
            if point.y >= bandFloor, point.y <= frame.maxY + 6 {
                return true
            }
        }
        return false
    }

    private var isVoiceOrPressInteractionActive: Bool {
        SpeechInputController.shared.isListening
            || SpeechInputController.shared.isHoldToTalk
            || pressTriggered
            || pressTimer != nil
            || HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown
    }

    private func hasVisiblePanelOwnedTransientWindow() -> Bool {
        guard let panel = panelWindow else { return false }
        if panel.attachedSheet?.isVisible == true { return true }
        if panel.childWindows?.contains(where: { $0 !== backdropWindow && $0.isVisible }) == true {
            return true
        }
        return NSApp.windows.contains { $0.isVisible && $0.level == .popUpMenu }
    }

    private func isCameraWindowTakingFocus() -> Bool {
        guard let cameraWindow = CameraLivePanelController.shared.panelWindow else { return false }
        if NSApp.keyWindow === cameraWindow || cameraWindow.isKeyWindow { return true }
        if cameraWindow.isVisible,
           (NSEvent.pressedMouseButtons & 0x7) != 0,
           cameraWindow.frame.contains(NSEvent.mouseLocation) {
            return true
        }
        return false
    }

    /// Non-activating panels do not trigger `didResignActive` when the user switches apps or clicks
    /// away, so `NSWindow.didResignKeyNotification` drives dismissal with explicit exemptions for
    /// dictation/hold, modal high-risk alerts, panel-owned popovers/menus/sheets, camera window,
    /// and status-item clicks.
    func handlePanelDidResignKey() {
        PanelTransientUIState.shared.cancelAllOffHold()
        PanelTransientUIState.shared.cancelDeviceControlGesture()
        let now = statusItemUptime()
        let context = PanelResignKeyDecision.Context(
            isPanelVisible: isPanelVisible,
            isVoiceOrPressActive: isVoiceOrPressInteractionActive,
            isModalConfirmationActive: isModalConfirmationActiveProvider(),
            newKeyWindowIsPanelOwned: isPanelWindow(NSApp.keyWindow),
            hasVisiblePanelOwnedTransientWindow: hasVisiblePanelOwnedTransientWindow(),
            isCameraWindowActive: isCameraWindowTakingFocus(),
            isStatusItemInteraction: now < suppressResignActiveHideUntil || isStatusItemMouseDownAtCurrentLocation()
        )
        guard PanelResignKeyDecision.decide(context) == .hide else { return }
        if hostsStatusItemOutOfProcess {
            resignActiveAwaitingMonitorMouseDown = true
            noteImplicitDismissalForStatusItemReopenGuard(now: now)
        }
        hidePanel()
    }

    func handleApplicationResignActive() {
        guard isPanelVisible else { return }
        let now = statusItemUptime()
        // A TCC prompt (microphone/speech) deactivates the app mid-dictation; keep the panel.
        // An out-of-process menu bar (macOS 26+ MenuBarAgent) also deactivates the app on
        // mouse-down ~60–90 ms before delivering `NSMenuBarNavigateAction` to the status item.
        if isVoiceOrPressInteractionActive
            || isModalConfirmationActiveProvider()
            || now < suppressResignActiveHideUntil
            || isStatusItemMouseDownAtCurrentLocation() { return }
        if hostsStatusItemOutOfProcess {
            resignActiveAwaitingMonitorMouseDown = true
            noteImplicitDismissalForStatusItemReopenGuard(now: now)
        }
        hidePanel()
    }

    func clearImplicitDismissalStateOnShow() {
        suppressStatusItemReopenUntil = 0
        suppressResignActiveHideUntil = 0
        resignActiveAwaitingMonitorMouseDown = false
    }

    func clearResignActiveSuppressionOnHide() {
        suppressResignActiveHideUntil = 0
        if !pressTriggered {
            suppressReleaseUntil = 0
        }
    }

    private func noteImplicitDismissalForStatusItemReopenGuard(
        now: TimeInterval? = nil
    ) {
        let resolvedNow = now ?? statusItemUptime()
        let holdHeadroom = (NSEvent.pressedMouseButtons & 0x1) != 0 ? Self.holdThreshold : 0
        suppressStatusItemReopenUntil = max(
            suppressStatusItemReopenUntil,
            resolvedNow + Self.statusItemReopenSuppressionWindow + holdHeadroom
        )
    }

    private func isStatusItemMouseDownAtCurrentLocation() -> Bool {
        guard (NSEvent.pressedMouseButtons & 0x3) != 0,
              let button = statusItem?.button,
              let statusWindow = button.window else { return false }
        let statusRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return Self.isStatusItemHit(
            statusRect: statusRect,
            point: NSEvent.mouseLocation,
            eventType: .leftMouseDown
        )
    }

    // MARK: - Control Center Readability Shadow

    /// Keep the full blur footprint while the column travels across the screen edge.
    static let backdropBleed: CGFloat = 72

    /// Keep the shadow's column geometry intact; the display clips the off-screen portion.
    func presentBackdropShadow(around panelFrame: NSRect, under panel: NSPanel) {
        let frame = panelFrame.insetBy(dx: -Self.backdropBleed, dy: -Self.backdropBleed)
        let backdrop = backdropWindow ?? Self.makeBackdropWindow(frame: frame)
        backdropWindow = backdrop
        backdrop.appearance = panel.appearance
        if backdrop.frame != frame {
            backdrop.setFrame(frame, display: true)
        }
        backdrop.alphaValue = panel.alphaValue
        backdrop.order(.below, relativeTo: panel.windowNumber)
    }

    func hideBackdropShadow() {
        guard let backdrop = backdropWindow, backdrop.isVisible else { return }
        backdrop.orderOut(nil)
        backdrop.alphaValue = 0
    }
}

