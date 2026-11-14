import AppKit
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
private final class TestStatusBarButton: NSStatusBarButton {
    var performClickCount = 0
    var onPerformClick: (() -> Void)?

    override func performClick(_ sender: Any?) {
        performClickCount += 1
        onPerformClick?()
    }
}

@MainActor
private final class TestStatusItem: NSStatusItem {
    let testButton = TestStatusBarButton()
    override var button: NSStatusBarButton? { testButton }
}

/// Writes `panel_theme` / `panel_height` into the developer defaults for one test and puts the
/// previous values back, so a themed test cannot leak its choice into the next one.
@MainActor
private final class PanelPreferenceScope {
    private let previousTheme: String?
    private let previousHeight: String?

    init(theme: PanelTheme? = nil, height: PanelHeight? = nil) {
        previousTheme = UserDefaults.standard.string(forKey: PanelTheme.storageKey)
        previousHeight = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
        if let theme {
            UserDefaults.standard.set(theme.rawValue, forKey: PanelTheme.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelTheme.storageKey)
        }
        if let height {
            UserDefaults.standard.set(height.rawValue, forKey: PanelHeight.storageKey)
        }
    }

    func restore() {
        if let previousTheme {
            UserDefaults.standard.set(previousTheme, forKey: PanelTheme.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelTheme.storageKey)
        }
        if let previousHeight {
            UserDefaults.standard.set(previousHeight, forKey: PanelHeight.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelHeight.storageKey)
        }
    }
}

extension PanelPresentationTests {
/// #56: the control center is hosted by an app-owned `NSStatusItem` + `NSPanel` instead of the
/// `MenuBarExtra` scene. These tests drive the real AppKit objects — window creation, show/hide,
/// outside-click closing, sizing and positioning — with an in-memory home and no network.
///
/// `swift test` does not run the app, so the `Settings` scene, SwiftUI lifecycle and the menu bar
/// itself are out of reach; those remain manual acceptance on a Mac.
@MainActor
@Suite(.serialized)
struct MenuBarPanelControllerTests {
    init() {
        SnapshotWindow.pinOverlayScrollers()
    }

    private func makeStore() async throws -> (HomeStore, String) {
        let suite = "test.panel.controller.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        #expect(!store.devices.isEmpty, "MockHomeProvider should deliver a snapshot right away")
        return (store, suite)
    }

    private func makeExpiredMiSessionStore() async throws -> (HomeStore, String) {
        let suite = "test.panel.controller.expired.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let session = MiSession(
            userId: "42",
            cUserId: "c",
            ssecurity: "c2VjcmV0",
            serviceToken: "tok",
            expiresAt: Date().addingTimeInterval(-60)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<200 where !store.miSessionShowsExpired {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.miSessionShowsExpired)
        return (store, suite)
    }

    private func makeController(store: HomeStore) -> MenuBarPanelController {
        // `swift test` does not launch an app; AppKit still needs its shared application object
        // before a status item or a window can exist.
        _ = NSApplication.shared
        let controller = MenuBarPanelController()
        controller.presentsActively = false
        controller.install(with: store)
        return controller
    }

    @Test("Installing creates one status item with a button and uninstall releases it")
    func installCreatesStatusItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        #expect(controller.panelWindow == nil, "the panel window is created lazily on first open")
        #expect(controller.isPanelVisible == false)

        controller.uninstall()
        #expect(controller.statusItem == nil)
        #expect(controller.panelWindow == nil)
    }

    @Test("Status context menu has live mode, source status, Settings, updates, and Quit in both languages")
    func statusContextMenuStructureAndLocalization() {
        let controller = MenuBarPanelController()

        func verify(language: AppLanguage, titles: [String], connectionTitles: [String]) {
            L10n.$overrideLanguage.withValue(language) {
                let menu = controller.makeStatusContextMenu()
                #expect(menu.items.count == 5)
                guard menu.items.count == 5 else { return }
                #expect(menu.items.map(\.title) == titles)
                #expect(menu.items[3].isSeparatorItem)

                let connections = menu.items[0]
                let submenu = connections.submenu
                #expect(submenu != nil)
                guard let submenu else { return }
                #expect(submenu.items.map(\.title) == connectionTitles)
                #expect(submenu.items.count == 7)
                guard submenu.items.count == 7 else { return }
                #expect(submenu.items[2].isSeparatorItem)
                #expect(submenu.items[5].isSeparatorItem)

                let modeItems = Array(submenu.items.prefix(2))
                #expect(modeItems.map { $0.representedObject as? String } == [
                    "homeAssistant",
                    "demo",
                ])
                for item in modeItems {
                    #expect(item.target === controller)
                    #expect(item.action == NSSelectorFromString("switchBackendFromStatusMenu:"))
                }
                for item in submenu.items[3...4] {
                    #expect(item.isEnabled == false)
                    #expect(item.action == nil)
                }
                #expect(submenu.items[6].target === controller)
                #expect(
                    submenu.items[6].action
                        == NSSelectorFromString("openConnectionSettingsFromStatusMenu:")
                )

                let actions = [
                    #selector(MenuBarPanelController.openSettingsFromStatusMenu(_:)),
                    #selector(MenuBarPanelController.openUpdatesFromStatusMenu(_:)),
                    #selector(MenuBarPanelController.quitFromStatusMenu(_:)),
                ]
                for (item, action) in zip([menu.items[1], menu.items[2], menu.items[4]], actions) {
                    #expect(item.target === controller)
                    #expect(item.action == action)
                }
            }
        }

        verify(
            language: .zhHans,
            titles: ["家居连接", "设置…", "检查更新…", "", "退出 MenuBarHome"],
            connectionTitles: [
                "实时连接",
                "演示模式",
                "",
                "Home Assistant",
                "米家云端直连",
                "",
                "打开连接设置…",
            ]
        )
        verify(
            language: .zhHant,
            titles: ["家居連線", "設定…", "檢查更新…", "", "退出 MenuBarHome"],
            connectionTitles: [
                "實時連線",
                "演示模式",
                "",
                "Home Assistant",
                "米家雲端直連",
                "",
                "開啟連線設定…",
            ]
        )
        verify(
            language: .en,
            titles: ["Connections", "Settings…", "Check for Updates…", "", "Quit MenuBarHome"],
            connectionTitles: [
                "Live Connections",
                "Demo Mode",
                "",
                "Home Assistant",
                "Xiaomi Cloud Direct",
                "",
                "Open Connection Settings…",
            ]
        )
    }

    @Test("Connections submenu distinguishes live mode from the included live sources")
    func statusContextMenuReflectsConnectionState() throws {
        let cases: [(MenuBarPanelController.StatusConnectionMenuState, [NSControl.StateValue])] = [
            (
                .init(
                    homeBackend: .homeAssistant,
                    hasHASource: true,
                    hasMiSource: true,
                    preferredLiveBackend: .homeAssistant
                ),
                [.on, .off, .on, .on]
            ),
            (
                .init(
                    homeBackend: .xiaomiCloud,
                    hasHASource: false,
                    hasMiSource: true,
                    preferredLiveBackend: .xiaomiCloud
                ),
                [.on, .off, .off, .on]
            ),
            (
                .init(
                    homeBackend: .demo,
                    hasHASource: true,
                    hasMiSource: true,
                    preferredLiveBackend: .homeAssistant
                ),
                [.off, .on, .off, .off]
            ),
        ]
        let controller = MenuBarPanelController()

        for (state, expectedStates) in cases {
            let menu = controller.makeStatusContextMenu(connectionState: state)
            let submenu = try #require(menu.items[0].submenu)
            let states = [submenu.items[0], submenu.items[1], submenu.items[3], submenu.items[4]]
                .map(\.state)
            #expect(states == expectedStates)
        }
    }

    @Test("Status context menu routes backends, Settings pages, and Quit to their owners")
    func statusContextMenuActionRouting() throws {
        let controller = MenuBarPanelController()
        var selectedBackends: [HomeBackend] = []
        controller.switchHomeBackend = { selectedBackends.append($0) }

        let state = MenuBarPanelController.StatusConnectionMenuState(
            homeBackend: .xiaomiCloud,
            hasHASource: false,
            hasMiSource: true,
            preferredLiveBackend: .xiaomiCloud
        )
        let submenu = try #require(
            controller.makeStatusContextMenu(connectionState: state).items[0].submenu
        )
        let switchSelector = NSSelectorFromString("switchBackendFromStatusMenu:")
        #expect(controller.responds(to: switchSelector))
        guard controller.responds(to: switchSelector) else { return }

        let modeItems = Array(submenu.items.prefix(2))
        let expectedBackends: [HomeBackend] = [.xiaomiCloud, .demo]
        for (item, expectedBackend) in zip(modeItems, expectedBackends) {
            _ = controller.perform(switchSelector, with: item)
            #expect(selectedBackends.last == expectedBackend)
        }

        for malformedPayload in [nil, "unknown", 7] as [Any?] {
            let item = NSMenuItem()
            item.representedObject = malformedPayload
            _ = controller.perform(switchSelector, with: item)
            #expect(selectedBackends == [.xiaomiCloud, .demo])
        }

        var requestedTabs: [SettingsTab?] = []
        controller.showSettings = { requestedTabs.append($0) }
        var updateCheckCount = 0
        controller.performUpdateCheck = { updateCheckCount += 1 }

        let connectionSettingsSelector = NSSelectorFromString(
            "openConnectionSettingsFromStatusMenu:"
        )
        #expect(controller.responds(to: connectionSettingsSelector))
        guard controller.responds(to: connectionSettingsSelector) else { return }
        _ = controller.perform(connectionSettingsSelector, with: submenu.items[6])

        controller.openSettingsFromStatusMenu(nil)
        controller.openUpdatesFromStatusMenu(nil)
        #expect(requestedTabs == [.connection, nil, .about])
        #expect(updateCheckCount == 1, "Check for Updates must run a user-initiated check")

        var didRequestTermination = false
        controller.terminateApplication = { didRequestTermination = true }
        controller.quitFromStatusMenu(nil)
        #expect(didRequestTermination)
    }

    @Test("Secondary status-item click presents one menu and suppresses trailing primary events")
    func secondaryStatusItemClickPresentsMenuOnly() {
        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        let wasHoldToTalk = speech.isHoldToTalk
        speech.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
        defer {
            speech.setPreviewState(
                isListening: wasListening,
                isHoldToTalk: wasHoldToTalk,
                draft: previousDraft
            )
        }

        let controller = MenuBarPanelController()
        var presentedMenus: [NSMenu] = []
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = {
            presentedMenus.append($0)
            eventNumber = 101
        }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        controller.handleStatusItemEvent(eventType: .rightMouseUp, pressedMouseButtons: 0)
        // macOS 26 can deliver the compatibility selector and a trailing synthetic primary click
        // for the same physical secondary click. Neither may present twice or toggle the panel.
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .rightMouseDown,
            pressedMouseButtons: 0x2
        )
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(presentedMenus.count == 1)
        #expect(presentedMenus[0].items.count == 5)
        #expect(toggleCount == 0)
        #expect(controller.isPanelVisible == false)
        #expect(controller.isStatusItemPressActive == false)
        #expect(speech.isListening == false)
        #expect(speech.isHoldToTalk == false)
    }

    @Test("First physical primary click after dismissing the context menu toggles the panel")
    func primaryClickAfterContextMenuDismissalToggles() {
        let controller = MenuBarPanelController()
        var presentedMenuCount = 0
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in
            presentedMenuCount += 1
            // AppKit returns from its modal menu loop while handling the mouse-up that dismissed it.
            eventNumber = 101
        }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        // The mouse-up that dismissed AppKit's modal menu is forwarded once more to the status item.
        // It closes the menu only and must not toggle the panel.
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // The out-of-process menu-bar host can deliver the user's next real short click as only a
        // mouse-up. Its distinct event number identifies it as a new click, which must open the
        // panel immediately instead of forcing a third click.
        eventNumber = 102
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(presentedMenuCount == 1)
        #expect(toggleCount == 1)
    }

    @Test("Monitor-started first click after menu dismissal toggles despite an early button mouse-up")
    func monitorStartedPostMenuClickToggles() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        // The dismissal mouse-up itself only closes the menu.
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // The host forwards the user's next physical down to the mouse monitor but not to the
        // button, and its short click ends with a button mouse-up before the 30 ms hold tick.
        eventNumber = 102
        controller.beginHoldDetectionFromMonitor(allowsPostMenuToggle: true)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 1, "the pending post-menu click must not be discarded as a hold")
        #expect(controller.isStatusItemPressActive == false)

        // Consuming the fallback keeps a later stray mouse-up from toggling a second time.
        eventNumber = 103
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("A press outside the status button cannot consume the pending post-menu click")
    func neighborStatusItemPressKeepsPostMenuFallback() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        // The 6 pt hold-tracking tolerance accepts a neighboring item's down, but it must not turn
        // into a panel toggle.
        eventNumber = 102
        controller.beginHoldDetectionFromMonitor(allowsPostMenuToggle: false)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // The user's actual click on this item still consumes the fallback.
        eventNumber = 103
        controller.beginHoldDetectionFromMonitor(allowsPostMenuToggle: true)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("Monitor-started press without a pending menu click does not toggle the panel")
    func monitorStartedPressWithoutPendingClickDoesNotToggle() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        controller.statusItemEventNumber = { 200 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.beginHoldDetectionFromMonitor()
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 0)
        #expect(controller.isStatusItemPressActive == false)
    }

    @Test("Keyboard activation after a mouse-dismissed menu still toggles once the grace ends")
    func keyboardActivationAfterMenuDismissalToggles() async throws {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        // Escape and the synthetic tail of the dismissed menu arrive inside the 0.15 s grace and
        // must not open the panel.
        controller.handleStatusItemEvent(eventType: .keyDown, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // A later keyboard activation is a real toggle, not a stale mouse-up fallback.
        try await Task.sleep(for: .milliseconds(250))
        controller.handleStatusItemEvent(eventType: .keyDown, pressedMouseButtons: 0)
        #expect(toggleCount == 1)

        controller.handleStatusItemEvent(eventType: .keyDown, pressedMouseButtons: 0)
        #expect(toggleCount == 2, "the cleared fallback must not block subsequent keyboard activation")
    }

    @Test("Escape-dismissed menu arms the next mouse-up-only click after its synthetic tail")
    func keyboardDismissedMenuKeepsPostMenuClickFallback() async throws {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        // `currentEvent` is the Escape key event when AppKit's menu loop returns.
        controller.statusContextMenuPresenter = { _ in eventNumber = nil }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        // The synthetic primary pair has no physical button bit: both halves are rejected and the
        // fallback stays armed for the host's next mouse-up-only click.
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // macOS 26 can deliver the user's next click as only a mouse-up; it must toggle.
        try await Task.sleep(for: .milliseconds(120))
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("Native primary hold after menu dismissal cannot reuse the release as a panel click")
    func nativePrimaryHoldClearsPostMenuClickFallback() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        // macOS 26 can accept a native hold without forwarding its primary mouse-down. Model the
        // timer seeing the release before the button's later mouse-up callback.
        eventNumber = 102
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0
        )
        #expect(controller.isStatusItemPressActive == false)

        eventNumber = 103
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 0)
    }

    @Test("Primary status-item click still toggles and native primary hold stays on hold-to-talk path")
    func primaryStatusItemGesturesRemainUnchanged() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var presentedMenuCount = 0
        controller.statusItemToggle = { toggleCount += 1 }
        controller.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        #expect(controller.isStatusItemPressActive)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
        #expect(controller.isStatusItemPressActive == false)

        let holdController = MenuBarPanelController()
        holdController.statusItemToggle = { toggleCount += 1 }
        holdController.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }
        holdController.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(holdController.isStatusItemPressActive)
        #expect(presentedMenuCount == 0)
        holdController.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(holdController.isStatusItemPressActive == false)
        #expect(toggleCount == 1, "releasing a primary hold must not toggle the panel")
    }

    @Test("Primary click keeps the status item highlighted while its panel is visible")
    func primaryStatusItemHighlightTracksPanelVisibility() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        controller.presentsActively = false
        controller.install(with: store)
        defer { controller.uninstall() }
        let button = statusItem.testButton

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        #expect(button.cell?.isHighlighted == true)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible)
        #expect(button.cell?.isHighlighted == true)

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false)
        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Closing without another status-item click releases its highlight", arguments: PanelTheme.allCases, [false, true])
    func programmaticCloseReleasesStatusItemHighlight(theme: PanelTheme, animated: Bool) async throws {
        let preferences = PanelPreferenceScope(theme: theme)
        defer { preferences.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let item = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: item)
        controller.presentsActively = animated
        controller.shouldReduceMotion = { true }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(item.testButton.cell?.isHighlighted == true)
        controller.hidePanel()
        #expect(controller.isPanelVisible == false)
        #expect(item.testButton.cell?.isHighlighted == false)
    }

    @Test("Primary long press stays highlighted until release")
    func primaryLongPressHighlightsUntilRelease() {
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        let button = statusItem.testButton
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(button.cell?.isHighlighted == true)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Secondary menu highlights while open and its closing right click leaves no highlight")
    func secondaryMenuHighlightTracksPresentation() {
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        let button = statusItem.testButton
        var highlightedWhileMenuWasOpen = false
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in
            highlightedWhileMenuWasOpen = button.cell?.isHighlighted == true
            eventNumber = 101
        }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        #expect(highlightedWhileMenuWasOpen)
        #expect(button.cell?.isHighlighted == false)

        // The menu-bar host highlights the status button before dispatching the right click that
        // just dismissed the menu. The duplicate-suppression branch must release that highlight.
        button.highlight(true)
        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Out-of-process secondary click coalesces monitor and native signals into one presentation after native settle")
    func outOfProcessSecondaryClickPresentsOnceAfterNativeSettle() {
        _ = NSApplication.shared
        let statusItem = TestStatusItem()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 900, width: 80, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { hostWindow.orderOut(nil) }
        statusItem.testButton.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        hostWindow.contentView = statusItem.testButton

        let controller = MenuBarPanelController(statusItem: statusItem)
        var presentedMenus: [NSMenu] = []
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        controller.statusItemHostsOutOfProcess = { true }
        controller.statusContextMenuScheduler = { delay, work in
            scheduled.append((delay, work))
        }
        controller.statusContextMenuPresenter = { menu in
            presentedMenus.append(menu)
        }

        let insidePoint = NSPoint(x: 140, y: 912)
        controller.handleMouseDown(
            in: hostWindow,
            at: insidePoint,
            eventType: .rightMouseDown,
            pressedMouseButtons: 0x2
        )

        #expect(presentedMenus.isEmpty, "menu must wait for the out-of-process host to settle")
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.delay == MenuBarPanelController.ContextMenuSettle.fallback)
        #expect(scheduled.first?.work.isCancelled == false)
        #expect(statusItem.testButton.cell?.isHighlighted == true)

        controller.handleStatusItemNativeLongPressEvent(
            eventType: .rightMouseDown,
            pressedMouseButtons: 0x2
        )

        #expect(presentedMenus.isEmpty, "native secondary action resets the settle window instead of presenting immediately")
        #expect(scheduled.count == 2)
        #expect(scheduled.first?.work.isCancelled == true)
        #expect(scheduled.last?.delay == MenuBarPanelController.ContextMenuSettle.native)
        #expect(scheduled.last?.work.isCancelled == false)

        scheduled.first?.work.perform()
        #expect(presentedMenus.isEmpty, "cancelled fallback work item must not present the menu")

        scheduled.last?.work.perform()
        #expect(presentedMenus.count == 1)
        #expect(statusItem.testButton.cell?.isHighlighted == false)
    }

    @Test("Synthetic primary click during the context-menu settle window does not toggle the panel")
    func syntheticPrimaryClickDuringSettleWindowDoesNotTogglePanel() {
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        var presentedMenus: [NSMenu] = []
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        var toggleCount = 0
        controller.statusItemHostsOutOfProcess = { true }
        controller.statusContextMenuScheduler = { delay, work in
            scheduled.append((delay, work))
        }
        controller.statusContextMenuPresenter = { menu in
            presentedMenus.append(menu)
        }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        #expect(presentedMenus.isEmpty)
        #expect(scheduled.count == 1)

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0, "synthetic primary pair during settle window must not toggle the panel")
        #expect(presentedMenus.isEmpty)

        scheduled.first?.work.perform()
        #expect(presentedMenus.count == 1)
        #expect(toggleCount == 0)
    }

    @Test("Secondary click during a primary hold leaves release tracking active")
    func secondaryClickDuringPrimaryHoldKeepsReleaseTracking() {
        let controller = MenuBarPanelController()
        var presentedMenuCount = 0
        var toggleCount = 0
        controller.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        #expect(presentedMenuCount == 0, "a modal menu must not consume the hold's release")
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isStatusItemPressActive == false)

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("Secondary hit testing excludes the neighboring status item")
    func secondaryHitTestingExcludesNeighboringStatusItem() {
        let statusRect = NSRect(x: 100, y: 900, width: 80, height: 24)
        let inside = NSPoint(x: statusRect.maxX - 1, y: statusRect.midY)
        let neighboringPoint = NSPoint(x: statusRect.maxX + 3, y: statusRect.midY)

        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: inside,
            eventType: .rightMouseDown
        ))
        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: neighboringPoint,
            eventType: .rightMouseDown
        ) == false)
        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: neighboringPoint,
            eventType: .leftMouseDown
        ))
    }

    @Test("Recreating the status item at launch finish keeps a single working item")
    func recoverStatusItemKeepsOneItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.recoverStatusItemIfNeeded()
        controller.recoverStatusItemIfNeeded()

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        let expectedSymbol = SpeechInputController.shared.isListening ? "waveform" : store.menuBarSymbolName
        #expect(controller.labelSymbol == expectedSymbol)
    }

    @Test("Status item button carries the summary as tooltip and accessibility label")
    func statusItemShowsSummary() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        let summary = MenuBarStatusSummary.text(for: store)
        #expect(button.toolTip == summary)
        #expect(button.accessibilityLabel() == summary)
        let expectedTitle = try #require(store.menuBarText)
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == expectedTitle)
    }

    @Test("Listening shows the waveform icon and the transcript instead of the store text")
    func listeningLabelMirrorsSpeech() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        let draft = "把书房的吸顶灯亮度调暗一点"
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: draft)
        defer { speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft) }

        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        // 13 characters: the button shows the last ten, as the SwiftUI label did.
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == "的吸顶灯亮度调暗一点")
        #expect(controller.labelSymbol == "waveform")
    }

    @Test("Reopening during dismissal preserves the panel and emits each visibility change once", arguments: [false, true])
    func reopenDuringDismissal(reduced: Bool) async throws {
        // The slide-in dismissal this test drives belongs to the liquid-glass window.
        let themeScope = PanelPreferenceScope(theme: .liquidGlass)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.presentsActively = true
        controller.shouldReduceMotion = { reduced }
        var shows = 0
        var hides = 0
        let shown = NotificationCenter.default.addObserver(forName: MenuBarPanelController.didShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shows += 1 }
        }
        let hidden = NotificationCenter.default.addObserver(forName: MenuBarPanelController.didHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hides += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(shown)
            NotificationCenter.default.removeObserver(hidden)
        }
        func waitUntil(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !predicate() {
                guard ContinuousClock.now < deadline else { return false }
                Self.pumpMainRunLoop(0.005)
                await Task.yield()
            }
            return true
        }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(await waitUntil { controller.grokBallSidecarWindow?.isVisible == true })
        let settled = panel.frame
        controller.hidePanel()
        controller.hidePanel()
        #expect(await waitUntil { reduced ? panel.alphaValue < 0.95 : panel.frame.minX > settled.minX + 2 })
        let interrupted = panel.frame
        controller.handlePreferencesChanged()
        #expect(panel.frame == interrupted, "a preferences notification cannot snap a closing window back")
        controller.showPanel()
        controller.showPanel()
        #expect(abs(panel.frame.minX - interrupted.minX) <= 1, "reopening starts at the current position")
        #expect(await waitUntil { controller.grokBallSidecarWindow?.isVisible == true })
        #expect(panel.isVisible)
        #expect(controller.isPanelVisible)
        #expect(panel.frame == settled)
        #expect(shows == 2)
        #expect(hides == 1)
        controller.hidePanel()
        #expect(await waitUntil { !panel.isVisible })
        #expect(hides == 2)
    }

    @Test("Out-of-process status-item click while open slides the liquid-glass panel closed instead of reopening mid-close")
    func outOfProcessSecondClickSlidesLiquidGlassPanelClosed() async throws {
        let themeScope = PanelPreferenceScope(theme: .liquidGlass)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let statusItem = TestStatusItem()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 900, width: 80, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { hostWindow.orderOut(nil) }
        statusItem.testButton.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        hostWindow.contentView = statusItem.testButton

        var now: TimeInterval = 1_000
        let controller = MenuBarPanelController(statusItem: statusItem)
        controller.presentsActively = true
        controller.shouldReduceMotion = { true }
        controller.statusItemHostsOutOfProcess = { true }
        controller.statusItemUptime = { now }
        controller.install(with: store)
        defer { controller.uninstall() }

        var shows = 0
        var hides = 0
        let shown = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didShowNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { shows += 1 }
        }
        let hidden = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { hides += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(shown)
            NotificationCenter.default.removeObserver(hidden)
        }
        func waitUntil(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !predicate() {
                guard ContinuousClock.now < deadline else { return false }
                Self.pumpMainRunLoop(0.005)
                await Task.yield()
            }
            return true
        }

        // 1. First click (monitor press -> release -> synthesized action) opens the panel and
        // clears deactivation suppression so an immediate Command-Tab still closes it.
        let insideStatusPoint = NSPoint(x: 140, y: 912)
        controller.handleMouseDown(
            in: hostWindow,
            at: insideStatusPoint,
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        now += 0.04
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        let panel = try #require(controller.panelWindow)
        #expect(controller.isPanelVisible)
        #expect(shows == 1)
        #expect(hides == 0)

        // 2a. Second click on macOS 26+ out-of-process menu bar where `MenuBarAgent` deactivates
        // the app (`SETFRONT`) on mouse-down ~60-90 ms before `NSMenuBarNavigateAction` delivers
        // the synthesized primary click pair upon release.
        now += 0.5
        controller.handleApplicationResignActive()
        #expect(controller.isClosing, "deactivation starts the slide-out transition")
        #expect(controller.isPanelVisible == false)
        #expect(hides == 1)

        now += 0.08
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false, "trailing status-item action for the same click must not reopen the closing panel")
        #expect(shows == 1, "must not emit a second show notification mid-close")
        #expect(statusItem.testButton.cell?.isHighlighted == false)
        #expect(await waitUntil { !panel.isVisible })
        #expect(controller.isClosing == false)

        // 2b. Consuming the suppression lets the very next click reopen immediately.
        now += 0.2
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible)
        #expect(shows == 2)

        // 2c. A slower short click whose trailing synthesized action arrives after the 200 ms
        // close animation completed (at +250 ms < 350 ms suppression window, frozen on `now` so
        // `waitUntil` wall-clock time on a loaded runner cannot expire the deadline) is still
        // suppressed rather than reopening the ordered-out panel.
        now += 0.5
        controller.handleApplicationResignActive()
        #expect(await waitUntil { !panel.isVisible })
        #expect(controller.isClosing == false)
        #expect(hides == 2)
        now += 0.25
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false, "close-animation completion must not clear suppression before the trailing action arrives")
        #expect(shows == 2)

        // 2d. An actual outside click below the menu bar (or a fresh physical press after
        // deactivation) never swallows the user's next status-item click.
        controller.showPanel()
        #expect(controller.isPanelVisible)
        #expect(shows == 3)
        now += 0.05
        controller.handleMouseDown(
            in: nil,
            at: NSPoint(x: 20, y: 200),
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(controller.isPanelVisible == false)
        #expect(hides == 3)
        now += 0.05
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible, "an outside click below the menu bar must not suppress the next status-item open")
        #expect(shows == 4)

        now += 0.05
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
        #expect(hides == 4)
        now += 0.05
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible, "a fresh physical press after deactivation must reopen on the first click")
        #expect(shows == 5)

        // 2e. When `SETFRONT` (`handleApplicationResignActive`) runs before the global mouse
        // monitor reports the same physical mouse-down (both on `statusRect` and in the menu-bar
        // band when `statusWindow` is detached), the delayed monitor event preserves the reopen
        // guard so the subsequent synthesized down/up pair still keeps the panel closed.
        now += 0.5
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
        #expect(hides == 5)
        now += 0.01
        controller.handleMouseDown(
            in: hostWindow,
            at: insideStatusPoint,
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        now += 0.06
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false, "delayed monitor mouse-down for the dismissal click must not clear the reopen guard")
        #expect(shows == 5)

        let screen = try #require(NSScreen.main)
        let menuBarBandPoint = NSPoint(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12)
        controller.showPanel()
        #expect(controller.isPanelVisible)
        #expect(shows == 6)
        now += 0.5
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
        #expect(hides == 6)
        now += 0.01
        controller.handleMouseDown(
            in: nil,
            at: menuBarBandPoint,
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        now += 0.06
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false, "menu-bar-band monitor event for the dismissal click must preserve the reopen guard")
        #expect(shows == 6)

        // 3. When the global mouse monitor sees the status-item hit before `SETFRONT`, the
        // deactivation is ignored and the release action closes the panel once.
        controller.showPanel()
        #expect(controller.isPanelVisible)
        #expect(shows == 7)
        now += 0.5
        controller.handleMouseDown(
            in: hostWindow,
            at: insideStatusPoint,
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        now += 0.01
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible, "status-item mouse-down keeps the panel open until release")
        #expect(hides == 6)

        now += 0.05
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false)
        #expect(hides == 7)
        #expect(shows == 7)
        #expect(await waitUntil { !panel.isVisible })
    }

    @Test("Showing the panel creates a key-capable 376 pt window and marks it visible", arguments: PanelTheme.allCases)
    func showPanelCreatesVisibleWindow(theme: PanelTheme) async throws {
        let themeScope = PanelPreferenceScope(theme: theme)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        var didShow = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didShowNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { didShow = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        #expect(controller.isPanelVisible)
        #expect(didShow)
        #expect(panel.isVisible)
        #expect(panel.alphaValue == 0)
        #expect(panel.hasShadow == false)
        #expect(panel.canBecomeKey, "arrow keys and text fields need a key panel")
        #expect(panel.canBecomeMain == false)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
        #expect(controller.hostedPanelTheme == theme)

        let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        switch theme {
        case .classic:
            let expectedHeight = min(PanelHeight.standard.points, visible.height - 24)
            #expect(abs(panel.frame.height - expectedHeight) <= 1, "the classic panel follows PanelHeight")
        case .liquidGlass:
            #expect(panel.frame.height > visible.height - 30, "the column runs almost the whole visible height")
        }
    }

    @Test("Hiding orders the window out, keeps the SwiftUI tree and posts the hide notification")
    func hidePanelKeepsContent() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView)

        var didHide = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { didHide = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.hidePanel()

        #expect(didHide)
        #expect(controller.isPanelVisible == false)
        #expect(panel.isVisible == false)
        #expect(panel.contentView === hosting, "the SwiftUI tree survives a close")
        #expect(controller.panelWindow === panel, "the window is reused, not recreated")
    }

    @Test("Scanning from the Settings toast opens the panel that owns the QR view")
    func settingsToastScanRevealsPanel() async throws {
        let (store, suite) = try await makeExpiredMiSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let previousReveal = ToastNoticeActions.revealPanel
        ToastNoticeActions.revealPanel = { controller.showPanel() }
        defer { ToastNoticeActions.revealPanel = previousReveal }

        store.dismissMiReauth()
        ToastNoticeActions.perform(
            ToastAction(title: "扫码", kind: .presentMiReauth),
            store: store
        )

        #expect(store.isShowingMiReauth)
        #expect(controller.isPanelVisible)
    }

    @Test("An expired Mi session paints house.slash in the status item")
    func expiredMiSessionUsesSlashedIcon() async throws {
        let (store, suite) = try await makeExpiredMiSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.syncStatusItem()

        let button = try #require(controller.statusItem?.button)
        #expect(store.menuBarSymbolName == "house.slash")
        #expect(controller.labelSymbol == "house.slash")
        #expect(button.image != nil, "the slashed-house symbol must exist on the deployment target")
    }

    @Test("The classic panel hangs under the status item at the PanelHeight preference", arguments: [
        PanelHeight.compact, PanelHeight.standard, PanelHeight.tall, PanelHeight.max,
    ])
    func classicPanelFrameFollowsPanelHeight(height: PanelHeight) async throws {
        let themeScope = PanelPreferenceScope(theme: .classic, height: height)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(controller.hostedPanelTheme == .classic)

        let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        let expectedHeight = min(height.points, visible.height - 24)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
        #expect(abs(panel.frame.height - expectedHeight) <= 1, "classic height follows panel_height")
        #expect(panel.frame.minY >= visible.minY, "the panel stays on screen")
        #expect(panel.frame.maxY <= visible.maxY + 1)
        #expect(panel.frame.minX >= visible.minX)
        #expect(panel.frame.maxX <= visible.maxX)

        // `swift test` can receive a detached status-item window below the visible screen. Use a
        // known menu-bar anchor to verify placement independently of that AppKit host lifecycle.
        let anchor = NSRect(x: visible.midX - 12, y: visible.maxY, width: 24, height: 24)
        let anchoredFrame = MenuBarPanelController.frame(
            for: panel.frame.size, anchor: anchor, screen: panel.screen, theme: .classic
        )
        #expect(abs(anchoredFrame.maxY - (anchor.minY - 6)) <= 1)
        #expect(abs(anchoredFrame.midX - anchor.midX) <= 1)
    }

    @Test("Changing the classic PanelHeight preference resizes the open panel")
    func classicPanelFollowsPanelHeightPreferenceChange() async throws {
        let themeScope = PanelPreferenceScope(theme: .classic, height: .compact)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let compactHeight = panel.frame.height

        UserDefaults.standard.set(PanelHeight.tall.rawValue, forKey: PanelHeight.storageKey)
        controller.handlePreferencesChanged()

        let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        let expectedHeight = min(PanelHeight.tall.points, visible.height - 24)
        #expect(panel.frame.height > compactHeight, "the taller preference must grow the window")
        #expect(abs(panel.frame.height - expectedHeight) <= 1)
        #expect(panel.frame.minY >= visible.minY)
    }

    @Test("Switching the panel theme closes the panel; the next show rebuilds that theme's root and frame")
    func switchingPanelThemeClosesAndRebuilds() async throws {
        let themeScope = PanelPreferenceScope(theme: .classic, height: .standard)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let classicContent = try #require(panel.contentView)
        let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        #expect(controller.hostedPanelTheme == .classic)
        #expect(abs(panel.frame.height - min(PanelHeight.standard.points, visible.height - 24)) <= 1)
        #expect(controller.grokBallSidecarWindow?.isVisible == true, "the ball shows with the classic panel")

        // The user picks liquid glass while the panel is open: it closes first.
        UserDefaults.standard.set(PanelTheme.liquidGlass.rawValue, forKey: PanelTheme.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        Self.pumpMainRunLoop()

        #expect(controller.isPanelVisible == false, "a theme change closes the open panel")
        #expect(panel.contentView == nil, "the next show builds the other root instead of reusing the tree")

        controller.showPanel()
        #expect(controller.isPanelVisible)
        #expect(controller.hostedPanelTheme == .liquidGlass)
        let liquidContent = try #require(panel.contentView)
        let liquidVisible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        #expect(liquidContent !== classicContent)
        // With an auto-hidden or notch menu bar, `pumpMainRunLoop()` lets WindowServer place the
        // status-item window ~24-38 pt below `visibleFrame.maxY`; `liquidFrame` anchors 6 pt under
        // that item down to `visible.minY + 8`, so allow up to 60 pt of top chrome + margins.
        #expect(panel.frame.height > liquidVisible.height - 60, "liquid glass uses the full-height column")
        #expect(abs(panel.frame.minY - (liquidVisible.minY + 8)) <= 1)
        #expect(abs(panel.frame.maxX - (liquidVisible.maxX - 16)) <= 0.5)
        #expect(controller.grokBallSidecarWindow?.isVisible == true, "the ball returns with the liquid panel")

        // Switching back while open closes it again and the next show restores the classic frame.
        UserDefaults.standard.set(PanelTheme.classic.rawValue, forKey: PanelTheme.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        Self.pumpMainRunLoop()

        #expect(controller.isPanelVisible == false)
        #expect(panel.contentView == nil)

        controller.showPanel()
        #expect(controller.hostedPanelTheme == .classic)
        #expect(abs(panel.frame.height - min(PanelHeight.standard.points, visible.height - 24)) <= 1)
        #expect(controller.grokBallSidecarWindow?.isVisible == true, "the ball is not left suspended by the switch")
    }

    @Test("GrokBall sidecar stays outside the 376 pt panel and expands without changing it")
    func grokBallSidecarKeepsPanelWidthStable() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        #expect(store.enableGrokBall == false)
        controller.showPanel()
        #expect(controller.grokBallSidecarWindow?.isVisible == false)

        store.enableGrokBall = true
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        #expect(sidecar.alphaValue == 0)
        #expect(abs(panel.frame.width - 376) < 1)
        #expect(abs(sidecar.frame.width - GrokBallSidecarPlacement.collapsedWidth) < 1)
        #expect(sidecar.frame.minX >= panel.frame.maxX || sidecar.frame.maxX <= panel.frame.minX)
        #expect(controller.isPanelWindow(sidecar))

        let initialFrame = panel.frame
        store.toggleGrokBallStage()
        controller.showPanel()
        #expect(abs(panel.frame.width - 376) < 1)
        #expect(panel.frame == initialFrame)
        #expect(abs(sidecar.frame.width - GrokBallSidecarPlacement.expandedWidth) < 1)
        #expect(sidecar.frame.height >= GrokBallSidecarPlacement.expandedHeight - 1)

        controller.hidePanel()
        #expect(sidecar.isVisible == false)
        #expect(store.isGrokBallStageExpanded == false)
    }

    @Test("Expanded sidecar chooses the far edge and flips when the right side cannot fit")
    func grokBallSidecarFlipsAtScreenEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let rightParent = NSRect(x: 300, y: 300, width: 376, height: 420)
        let right = GrokBallSidecarPlacement.resolve(parent: rightParent, visible: visible, expanded: true)
        #expect(right.side == .right)
        #expect(right.frame.minX >= rightParent.maxX)

        let edgeParent = NSRect(x: 600, y: 300, width: 376, height: 420)
        let left = GrokBallSidecarPlacement.resolve(parent: edgeParent, visible: visible, expanded: true)
        #expect(left.side == .left)
        #expect(left.frame.maxX <= edgeParent.minX)

        for parent in [rightParent, edgeParent] {
            let collapsed = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: false)
            let expanded = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true)
            #expect(collapsed.side == expanded.side)
            #expect(collapsed.frame.maxY == expanded.frame.maxY)
            let collapsedBallX = collapsed.side == .right ? collapsed.frame.minX + 42 : collapsed.frame.maxX - 42
            let expandedBallX = expanded.side == .right ? expanded.frame.minX + 42 : expanded.frame.maxX - 42
            #expect(collapsedBallX == expandedBallX)
            #expect(expanded.frame.minX >= visible.minX)
            #expect(expanded.frame.maxX <= visible.maxX)
            #expect(expanded.frame.minY >= visible.minY)
        }
    }

    @Test("Sidecar key status and clicks belong to the dashboard; an outside click closes both")
    func grokBallSidecarOutsideClickAndKeyOwnership() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        controller.handleOtherWindowBecameKey(sidecar)
        #expect(controller.isPanelVisible)
        let center = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        controller.handleMouseDown(in: sidecar, at: center)
        controller.handleMouseDown(in: nil, at: center)
        #expect(controller.isPanelVisible)
        controller.handleMouseDown(in: nil, at: NSPoint(x: -10_000, y: -10_000))
        #expect(controller.isPanelVisible == false)
        #expect(sidecar.isVisible == false)
    }

    @Test("Escape in the sidecar collapses suggestions first, then closes the dashboard")
    func grokBallSidecarEscapeClosesInOrder() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        store.toggleGrokBallStage()
        sidecar.cancelOperation(nil)
        #expect(store.isGrokBallStageExpanded == false)
        #expect(controller.isPanelVisible)
        sidecar.cancelOperation(nil)
        #expect(controller.isPanelVisible == false)
        #expect(sidecar.isVisible == false)

        controller.uninstall()
        #expect(controller.grokBallSidecarWindow == nil)
        #expect(sidecar.parent == nil)
        #expect(sidecar.contentView == nil)
    }

    @Test("Moving and resizing the parent keeps the side attachment aligned")
    func grokBallSidecarFollowsParentGeometry() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let visible = try #require(panel.screen?.visibleFrame)
        store.toggleGrokBallStage()
        let movedFrame = NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 376, height: 320)
        panel.setFrame(movedFrame, display: true)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)
        let expected = GrokBallSidecarPlacement.resolve(parent: panel.frame, visible: visible, expanded: true)
        #expect(sidecar.frame == expected.frame)
        #expect(panel.frame.width == 376)
    }

    @Test("The English empty-state message fits the shallow recommendation row")
    func grokBallEnglishEmptyStateFitsShallowRow() throws {
        _ = NSApplication.shared
        let suite = "test.empty.ball.\(UUID().uuidString)"
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try #require(store.grokBallRadialSuggestions.isEmpty)
        L10n.$overrideLanguage.withValue(.en) {
            let hosting = NSHostingView(rootView: GrokBallSuggestions(store: store, columnCount: 4).body)
            hosting.frame = NSRect(x: 0, y: 0, width: 558, height: 44)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height <= 44)
        }
    }

    @Test("A shallow bottom gap keeps all four suggestions below the ball when a row fits")
    func grokBallUsesShallowBottomSpace() throws {
        let parent = NSRect(x: 312, y: 200, width: 376, height: 420)
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let center = NSPoint(x: 500, y: 135)
        let placement = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true, ballCenter: center)
        let pills = try #require(placement.suggestionsFrame)
        #expect(placement.side == .below)
        #expect(pills.maxY < center.y - 36)
        #expect(visible.contains(placement.frame))
        #expect(!pills.intersects(parent))
    }

    @Test("Recommendations follow the ball outward on all four sides without moving its anchor")
    func grokBallSuggestionsFollowFreePlacement() throws {
        let parent = NSRect(x: 650, y: 600, width: 376, height: 420)
        let visible = NSRect(x: 0, y: 0, width: 2000, height: 1800)
        let cases: [(NSPoint, GrokBallSidecarPlacement.Side)] = [
            (NSPoint(x: 540, y: 810), .left), (NSPoint(x: 1130, y: 810), .right),
            (NSPoint(x: 838, y: 500), .below), (NSPoint(x: 838, y: 1120), .above),
        ]
        for (center, direction) in cases {
            let closed = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: false, ballCenter: center)
            let open = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true, ballCenter: center)
            let pills = try #require(open.suggestionsFrame)
            #expect(open.side == direction)
            #expect(open.ballCenter == closed.ballCenter)
            #expect(visible.contains(open.frame))
            #expect(!pills.intersects(parent))
            switch direction {
            case .left: #expect(pills.maxX < center.x - 36)
            case .right: #expect(pills.minX > center.x + 36)
            case .above: #expect(pills.minY > center.y + 36)
            case .below: #expect(pills.maxY < center.y - 36)
            }
        }
    }

    @Test("Dragging the ball moves it freely without clicking or starting voice, and pills follow its side")
    func grokBallDragsWithoutActivating() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let visible = try #require(panel.screen?.visibleFrame)
        panel.setFrame(NSRect(x: visible.midX - 188, y: visible.minY + 240, width: 376, height: 320), display: true)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        let mainFrame = panel.frame
        store.isShowingAssistantBar = false
        var origin = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        let left = NSPoint(x: mainFrame.minX - 70, y: mainFrame.midY)
        sendBallMouse(.leftMouseDown, at: origin, window: sidecar)
        sendBallMouse(.leftMouseDragged, at: left, window: sidecar)
        sendBallMouse(.leftMouseUp, at: left, window: sidecar)
        #expect(abs(sidecar.frame.midX - left.x) < 1)
        #expect(abs(sidecar.frame.midY - left.y) < 1)
        #expect(!store.isGrokBallStageExpanded)
        #expect(!store.isShowingAssistantBar)
        sendBallMouse(.leftMouseDown, at: left, window: sidecar)
        sendBallMouse(.leftMouseUp, at: left, window: sidecar)
        #expect(store.isGrokBallStageExpanded)
        #expect(sidecar.frame.maxX < mainFrame.minX)
        origin = left
        let below = NSPoint(x: mainFrame.midX, y: mainFrame.minY - 65)
        sendBallMouse(.leftMouseDown, at: origin, window: sidecar)
        sendBallMouse(.leftMouseDragged, at: below, window: sidecar)
        sendBallMouse(.leftMouseUp, at: below, window: sidecar)
        sendBallMouse(.leftMouseDown, at: below, window: sidecar)
        sendBallMouse(.leftMouseUp, at: below, window: sidecar)
        #expect(store.isGrokBallStageExpanded)
        #expect(sidecar.frame.maxY < mainFrame.minY)
        #expect(panel.frame == mainFrame)
    }

    @Test("Holding the ball enters voice without also toggling suggestions")
    func grokBallHoldStartsVoiceOnly() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let speech = SpeechInputController.shared
        let controller = makeController(store: store)
        defer { speech.stop(andSubmit: false, store: nil); controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let point = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        store.isShowingAssistantBar = false
        sendBallMouse(.leftMouseDown, at: point, window: sidecar)
        for _ in 0..<250 where !store.isShowingAssistantBar { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isShowingAssistantBar)
        #expect(speech.isHoldToTalk)
        #expect(!store.isGrokBallStageExpanded)
        sendBallMouse(.leftMouseUp, at: point, window: sidecar)
        for _ in 0..<250 where speech.isHoldToTalk { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!speech.isHoldToTalk)
        #expect(!store.isGrokBallStageExpanded)
    }

    private func sendBallMouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSApp.sendEvent(event)
    }

    @Test("Another window taking key status closes the panel; the panel and its own children do not")
    func otherWindowBecameKeyClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)

        controller.handleOtherWindowBecameKey(panel)
        #expect(controller.isPanelVisible, "the panel itself is not 'another window'")

        // A context menu or sheet the panel spawned keeps it open.
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        child.alphaValue = 0
        child.hasShadow = false
        defer { child.orderOut(nil) }
        panel.addChildWindow(child, ordered: .above)
        #expect(controller.isPanelWindow(child))
        controller.handleOtherWindowBecameKey(child)
        #expect(controller.isPanelVisible, "a panel-owned window must not dismiss the panel")

        let settingsLike = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { settingsLike.orderOut(nil) }

        controller.handleOtherWindowBecameKey(settingsLike)
        #expect(controller.isPanelVisible == false)
    }

    @Test("An outside mouse click closes the panel without an application deactivation")
    func outsideMouseClickClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let outside = NSPoint(x: panel.frame.minX - 20, y: panel.frame.midY)
        controller.handleMouseDown(in: panel, at: panel.frame.origin)
        #expect(controller.isPanelVisible, "panel controls keep working")
        if let button = controller.statusItem?.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            controller.handleMouseDown(in: window, at: NSPoint(x: frame.midX, y: frame.midY))
            #expect(controller.isPanelVisible, "the status button must toggle on release")
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: outside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        NSApp.sendEvent(event)

        #expect(!controller.isPanelVisible)
        #expect(!store.pollingContext.panelVisible)

        controller.showPanel()
        NSApp.sendEvent(event)
        #expect(!controller.isPanelVisible, "outside clicks still work after reopening")
    }

    @Test("Losing key status to another app closes the panel, but dictation keeps it")
    func appDeactivationClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(controller.isPanelVisible)

        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: "开灯")
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible, "a TCC prompt must not close the panel mid-dictation")

        speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft)
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
    }

    @Test("Showing the panel reports panel visibility to the store so polling can follow it")
    func showAndHideUpdatePollingContext() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(store.pollingContext.panelVisible)
        controller.hidePanel()
        #expect(store.pollingContext.panelVisible == false)
    }

    @Test("Dark appearance renders a dark panel background instead of light material")
    func classicDarkModeRendersDarkBackground() async throws {
        let themeScope = PanelPreferenceScope(theme: .classic)
        defer { themeScope.restore() }
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let prevAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        defer {
            if let prevAppearance { UserDefaults.standard.set(prevAppearance, forKey: AppAppearance.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey) }
        }

        UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)

        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView)
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        panel.displayIfNeeded()

        let size = hosting.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        // Sample background pixel in the outer top-left padding (x: 10, y: 6) where no header views render.
        let bgColor = try #require(bitmap.colorAt(x: 10, y: 6)?.usingColorSpace(.deviceRGB))
        let luminance = 0.2126 * bgColor.redComponent + 0.7152 * bgColor.greenComponent + 0.0722 * bgColor.blueComponent
        let effectiveName = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(effectiveName == .darkAqua)
        #expect(luminance < 0.35, "Classic dark mode panel background should be dark, got luminance \(luminance)")

        // Switching to forced light updates the panel's appearance right away.
        UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
        controller.handlePreferencesChanged()
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    @Test("Short global hotkey press toggles the panel; holding opens voice assistant without closing on release")
    func globalHotkeyShortPressAndLongHoldVoice() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = NSApplication.shared
        let sharedController = MenuBarPanelController.shared
        let prevPresentsActively = sharedController.presentsActively
        sharedController.presentsActively = false
        sharedController.install(with: store)
        HotkeyAndNotificationManager.shared.attachStoreForTesting(store)
        defer {
            HotkeyAndNotificationManager.shared.attachStoreForTesting(nil)
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            sharedController.uninstall()
            sharedController.presentsActively = prevPresentsActively
        }

        // 1. Short tap (< threshold): toggles the panel open on release, without opening the voice bar.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar == false)

        // Second short tap closes the panel.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(sharedController.isPanelVisible == false)

        // 2. Long hold (>= threshold): opens the panel, presents the assistant bar, and starts Hold-to-Talk.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.03)
        // The hold fires from a timer task. Wait for the signal it sets instead of sleeping a fixed
        // 70 ms, which a loaded runner can outrun.
        for _ in 0..<250 where !HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
        #expect(SpeechInputController.shared.isHoldToTalk)

        // Releasing after a long hold finishes Hold-to-Talk instead of toggling the panel closed.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Status item native long press opens voice assistant and suppresses trailing synthetic click")
    func statusItemLongPressOpensVoiceAndSuppressesTrailingClick() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let controller = makeController(store: store)
        defer {
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            controller.uninstall()
        }

        let item = try #require(controller.statusItem)

        // Simulate macOS 26+ out-of-process menu bar secondary action (type 0 = long press on status item)
        let secondarySel = NSSelectorFromString("_performSecondaryAction:type:")
        if item.responds(to: secondarySel),
           let method = class_getInstanceMethod(type(of: item), secondarySel) {
            typealias PerformSecondaryFn = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> Void
            let imp = unsafeBitCast(method_getImplementation(method), to: PerformSecondaryFn.self)
            imp(item, secondarySel, nil, 0)
        } else {
            controller.handleStatusItemNativeLongPress(item)
        }
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)

        // A trailing synthetic click delivered right after releasing a long press must not close the panel
        controller.handleStatusItemPress()
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Horizontal wheel monitor translates vertical mouse wheel and trackpad deltas into clamped horizontal scroll")
    func horizontalWheelMonitorScrollsAndClamps() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        scrollView.documentView = documentView

        // Rolling the mouse wheel down (negative deltaY) moves the horizontal strip right.
        let movedRight = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -2,
            hasPreciseDeltas: false
        )
        #expect(movedRight)
        #expect(scrollView.contentView.bounds.origin.x == 32)

        // Trackpad horizontal swipe right-to-left (negative deltaX) advances by exact points.
        let movedPrecise = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: -48,
            deltaY: -4,
            hasPreciseDeltas: true
        )
        #expect(movedPrecise)
        #expect(scrollView.contentView.bounds.origin.x == 80)

        // Clamps at maxOffsetX (640 - 240 = 400) and back at 0.
        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 400)

        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: 1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 0)

        // Non-overflowing strip does not scroll.
        documentView.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        let movedWhenFitting = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -3,
            hasPreciseDeltas: false
        )
        #expect(!movedWhenFitting)
    }

    @Test("CameraLivePanelController attaches NSHostingView contentView and elevates above MenuBarPanel")
    func cameraLivePanelAttachesHostingViewAndOrdersAboveMenuBarPanel() async throws {
        let suite = "MenuBarPanelTests-camera-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        #expect(panel.isVisible)
        #expect(panel.alphaValue == 0)
        #expect(panel.hasShadow == false)
        #expect(panel.contentView is NSHostingView<CameraLivePanelView>, "NSPanel initializes with a blank NSView; present(device:) must replace it with NSHostingView<CameraLivePanelView>")
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
    }

    @Test("Camera diagnostics name the stream mode and whether its audio can be enabled (#29)")
    func cameraDiagnosticsReportStreamModeAndAudioSupport() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarPanelTests-camera-diagnostics-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.isMuted = true
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        func waitForDemoStream() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while cameraController.streamSource == nil {
                guard ContinuousClock.now < deadline else { return false }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
        try #require(await waitForDemoStream(), "30 秒内没有拿到 demo 流")
        let report = cameraController.desensitizedDiagnosticsReport()
        #expect(report.contains("stream_mode: demo, audio_support: video-only"))

        cameraController.toggleMute()
        #expect(cameraController.isMuted == false)
        #expect(
            cameraController.desensitizedDiagnosticsReport().contains("audio_support: video-only"),
            "only an HLS stream can carry audio, so unmuting must not relabel a demo stream"
        )

        cameraController.closePanel()
        #expect(cameraController.isMuted, "closing the live window returns the next open to muted")
    }

    @Test("Camera pin toggle changes the window level and rotation cycles in quarter turns")
    func cameraLivePanelPinAndRotation() async throws {
        _ = NSApplication.shared
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)

        cameraController.isPinnedOnTop = false
        #expect(panel.level == .normal)
        #expect(panel.isFloatingPanel == false)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))

        cameraController.isPinnedOnTop = true
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
        #expect(panel.isFloatingPanel == true)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        for expected in [90, 180, 270, 0] {
            cameraController.rotateVideo()
            #expect(cameraController.videoRotation(for: camera.id) == expected)
        }
    }

    @Test("Camera rotation keeps a quarter turn inside the viewport")
    func cameraRotationMath() {
        #expect(CameraVideoRotation.next(270) == 0)
        #expect(CameraVideoRotation.fitScale(degrees: 0, in: CGSize(width: 640, height: 420)) == 1)
        #expect(CameraVideoRotation.fitScale(degrees: 180, in: CGSize(width: 640, height: 420)) == 1)
        let quarterTurn = CameraVideoRotation.fitScale(degrees: 90, in: CGSize(width: 640, height: 420))
        #expect(abs(quarterTurn - 420.0 / 640.0) < 0.0001)
    }

    @Test("Camera maximize fills the screen and restores the previous frame")
    func cameraLivePanelMaximizeAndRestore() async throws {
        _ = NSApplication.shared
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        let screen = try #require(panel.screen ?? NSScreen.main)
        let original = panel.frame

        cameraController.toggleMaximized()
        #expect(cameraController.isMaximized)
        #expect(panel.frame == screen.visibleFrame)

        cameraController.toggleMaximized()
        #expect(!cameraController.isMaximized)
        #expect(panel.frame == original)

        cameraController.toggleMaximized()
        cameraController.storePanelFrame()
        let stored = UserDefaults.standard.string(forKey: "camera_live_panel_frame_v1")
        #expect(stored == NSStringFromRect(original))

        cameraController.toggleExpandedSize()
        #expect(!cameraController.isMaximized)
        #expect(abs(panel.frame.maxX - original.maxX) < 1)
        #expect(abs(panel.frame.maxY - original.maxY) < 1)
        #expect(panel.frame.size != screen.visibleFrame.size)
    }

    @Test("Picture in Picture keeps the maximized frame, so one click restores the small window")
    func pictureInPictureRestoreThenMaximizeReturnsTheSmallFrame() async throws {
        _ = NSApplication.shared
        let (store, suite) = try await makeStore()
        defer {
            UserDefaults.standard.removeObject(forKey: "camera_live_panel_frame_v1")
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))
        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        let screen = try #require(panel.screen ?? NSScreen.main)
        let small = panel.frame

        cameraController.toggleMaximized()
        #expect(cameraController.isMaximized)
        #expect(panel.frame == screen.visibleFrame)

        cameraController.suspendPanelForPictureInPicture()
        #expect(cameraController.isMaximized)
        #expect(panel.frame == screen.visibleFrame)
        panel.orderFrontRegardless()

        cameraController.toggleMaximized()
        #expect(!cameraController.isMaximized)
        #expect(panel.frame == small)
    }

    @Test("Reopening a hidden maximized window replaces the frame, so the next maximize fills the screen")
    func hiddenMaximizedWindowPresentsThenMaximizeFillsTheScreen() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "camera_live_panel_frame_v1")
        let (store, suite) = try await makeStore()
        defer {
            UserDefaults.standard.removeObject(forKey: "camera_live_panel_frame_v1")
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))
        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        let screen = try #require(panel.screen ?? NSScreen.main)
        cameraController.toggleMaximized()
        #expect(panel.frame == screen.visibleFrame)

        panel.orderOut(nil)
        #expect(cameraController.isMaximized)
        store.openCameraLiveView(camera.id)
        #expect(!cameraController.isMaximized)
        #expect(panel.frame != screen.visibleFrame)

        cameraController.toggleMaximized()
        #expect(cameraController.isMaximized)
        #expect(panel.frame == screen.visibleFrame)
    }

    @Test("Closing the camera mini-window hides it at once and releases the stream")
    func cameraLivePanelCloseReleasesStreamImmediately() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarPanelTests-camera-close-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        #expect(panel.isVisible)
        #expect(panel.canBecomeKey)

        panel.cancelOperation(nil)
        #expect(cameraController.isVisible == false)
        #expect(cameraController.videoPlayer == nil)

        var stopped = false
        for _ in 0..<40 {
            if await mock.stoppedCameraIDs.contains(camera.id) {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(stopped)
    }

    @Test("Picture in Picture reports a valid endless live time range")
    func cameraPictureInPictureLiveRangeIsValid() {
        let range = CameraPictureInPicture.livePlaybackTimeRange()
        #expect(range.isValid)
        #expect(range.duration.isPositiveInfinity)
    }

    @Test("Moving, resizing, or interacting with a doorbell camera window cancels auto-dismiss (#308)")
    func doorbellCameraUserTakeoverCancelsAutoDismiss() async throws {
        _ = NSApplication.shared
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer {
            cameraController.closePanel()
            cameraController.presentsActively = true
        }

        store.doorbellAutoPopup = true
        store.doorbellChime = false
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:00:00Z"))
        let panel = try #require(cameraController.panelWindow)
        #expect(cameraController.isVisible)
        #expect(cameraController.isDoorbellPlacement)
        #expect(cameraController.doorbellOwnsClose)
        #expect(cameraController.hasPendingDoorbellAutoDismiss)

        // Dragging the window hands both close ownership and placement ownership to the user,
        // and a subsequent press while the claimed window is open must not re-arm auto-close.
        cameraController.windowWillMove(Notification(name: NSWindow.willMoveNotification, object: panel))
        #expect(!cameraController.isDoorbellPlacement)
        #expect(!cameraController.doorbellOwnsClose)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:01:00Z"))
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)

        // Reset and check live-resize takeover vs non-positional HUD interaction (mute).
        cameraController.closePanel()
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:02:00Z"))
        #expect(cameraController.hasPendingDoorbellAutoDismiss)
        cameraController.toggleMute()
        #expect(!cameraController.doorbellOwnsClose)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)
        #expect(cameraController.isDoorbellPlacement, "muting keeps doorbell placement so auto-top-right never overwrites saved frame")

        cameraController.closePanel()
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:03:00Z"))
        #expect(cameraController.hasPendingDoorbellAutoDismiss)
        cameraController.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
        #expect(!cameraController.isDoorbellPlacement)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)

        // Pin, reconnect, and video-only badge clicks also claim close ownership while keeping doorbell placement.
        let savedPinned = cameraController.isPinnedOnTop
        defer { cameraController.isPinnedOnTop = savedPinned }

        cameraController.closePanel()
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:04:00Z"))
        #expect(cameraController.hasPendingDoorbellAutoDismiss)
        cameraController.togglePinnedOnTop()
        #expect(!cameraController.doorbellOwnsClose)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)
        #expect(cameraController.isDoorbellPlacement)

        cameraController.closePanel()
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:05:00Z"))
        #expect(cameraController.hasPendingDoorbellAutoDismiss)
        cameraController.userReloadStream()
        #expect(!cameraController.doorbellOwnsClose)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)

        cameraController.closePanel()
        store.handleDoorbellRing(DoorbellRing(deviceId: camera.id, entityId: "event.door_ring", firedAt: "2026-11-11T06:06:00Z"))
        #expect(cameraController.hasPendingDoorbellAutoDismiss)
        cameraController.showVideoOnlyNotice()
        #expect(!cameraController.doorbellOwnsClose)
        #expect(!cameraController.hasPendingDoorbellAutoDismiss)
    }


    @Test("TileResizeGestureMath maps 30pt horizontal and vertical translations across half, full, and panel (#115)")
    func tileResizeGestureMathThresholds() {
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 30, height: 30), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .full, translation: CGSize(width: -30, height: -30), isCompactGrid: true) == .full)

        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 31, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 0, height: 31), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 60, height: 60), isCompactGrid: true) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 65, height: 0), isCompactGrid: true) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 0, height: 65), isCompactGrid: true) == .panel)

        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -31, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: 0, height: -31), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -60, height: -60), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -65, height: 0), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: 0, height: -65), isCompactGrid: true) == .half)

        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: 50, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: 50, height: 0), isCompactGrid: false) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: -50, height: 0), isCompactGrid: false) == .half)
    }

    @Test("TileResizeGestureMath computes release velocity from the last 100ms and projects a flick onto at most one step (#115)")
    func tileResizeGestureMathFlickProjection() {
        let now: TimeInterval = 100
        let fast = [
            TileResizeGestureMath.ResizeSample(offset: .zero, time: now - 0.08),
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 24, height: 16), time: now),
        ]
        let velocity = TileResizeGestureMath.releaseVelocity(fast, now: now)
        #expect(abs(velocity.width - 300) < 1)
        #expect(abs(velocity.height - 200) < 1)

        // A rested pointer yields no velocity, so a stationary release cannot fling.
        let rested = [
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 20, height: 10), time: now - 0.5),
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 20, height: 10), time: now - 0.4),
        ]
        #expect(TileResizeGestureMath.releaseVelocity(rested, now: now) == .zero)

        // Projection clamps to the threshold per axis: a 300pt/s flick adds ~one step.
        let projection = TileResizeGestureMath.projectedOffset(velocity: velocity)
        #expect(abs(projection.width - 29.7) < 0.001)
        #expect(abs(projection.height - 19.8) < 0.001)

        // A short sub-threshold drag plus its flick crosses the step at release.
        let shortDrag = TileResizeGestureMath.targetSize(
            startSize: .half,
            translation: CGSize(width: 20 + projection.width, height: 0),
            isCompactGrid: true
        )
        #expect(shortDrag == .full)

        // A slow drag projects nothing extra.
        let slow = TileResizeGestureMath.projectedOffset(velocity: CGSize(width: 100, height: -100))
        #expect(abs(slow.width - 9.9) < 0.001)
        #expect(abs(slow.height + 9.9) < 0.001)
    }

    @Test("Long-pressing a light card no longer enters edit mode; the corner handle resizes and cycles once editing is entered from the menu (#115)")
    func longPressOnLightCardNoLongerEntersEditModeAndCornerHandleResizesWhenEditing() async throws {
        _ = NSApplication.shared
        let previousAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)

        let suite = "MenuBarPanelTests-resize-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let previousAppearance {
                UserDefaults.standard.set(previousAppearance, forKey: AppAppearance.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey)
            }
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(true, forKey: "launch_at_login_suggestion_dismissed")
        defaults.set(AppLanguagePreference.zhHans.rawValue, forKey: "app_language")
        defaults.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)
        defaults.set(false, forKey: "show_quick_actions_bar")
        defaults.set(false, forKey: "automatically_checks_for_updates")
        defaults.set(true, forKey: "compact_grid_mode")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome(includeCamera: false)),
            defaultsSuiteName: suite
        )
        try await store.waitForTestSnapshot()
        let light = try #require(store.devices.first { dev in
            if case .light = dev.kind { return true }
            return false
        })
        let initialIsOn = light.isActiveOn

        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .defaultAppStorage(defaults)
                .environment(\.reduceMotionOverride, true)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
        LayoutUIState.shared.cardGlobalFrames.removeAll()
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 120, width: 376, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.hasShadow = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        Self.pumpMainRunLoop()
        let card = try #require(LayoutUIState.shared.cardGlobalFrames[light.id])

        func sendMouse(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return }
            NSApp.sendEvent(event)
        }

        // Long-press the card body. The kind row shifts the first card, so a fixed window point misses it.
        let longPressPoint = NSPoint(x: card.minX + 28, y: hosting.bounds.height - card.midY)
        sendMouse(.leftMouseDown, at: longPressPoint)
        try await Task.sleep(for: .milliseconds(550))
        Self.pumpMainRunLoop()

        // The hold itself must do nothing: no edit mode, no drawer, no toggle mid-press.
        #expect(LayoutUIState.shared.editMode == .none, "A 550 ms hold on a card must not enter edit mode")
        #expect(store.expandedDeviceId == nil, "Holding a card must not expand its drawer")
        #expect(store.devices.first(where: { $0.id == light.id })?.isActiveOn == initialIsOn, "Holding a card must not toggle it mid-press")

        // Releasing is an ordinary click, never an edit-mode entry.
        sendMouse(.leftMouseUp, at: longPressPoint)
        try await Task.sleep(for: .milliseconds(150))
        Self.pumpMainRunLoop()

        #expect(LayoutUIState.shared.editMode == .none, "Releasing the hold must not enter edit mode")
        #expect(store.expandedDeviceId == nil, "Releasing the hold must not open the drawer")

        func handlePoint() -> NSPoint {
            if let g = LayoutUIState.shared.cardGlobalFrames[light.id] {
                return NSPoint(x: g.maxX - 6, y: hosting.bounds.height - g.maxY + 6)
            }
            return NSPoint(x: 176, y: 358)
        }
        func currentSizes() -> [String: TileSize] {
            DeviceLayoutPrefs.decode(defaults.string(forKey: DeviceLayoutPrefs.storageKey) ?? "{}")
        }
        func flushLayout() async throws {
            try await Task.sleep(for: .milliseconds(160))
            Self.pumpMainRunLoop()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            window.displayIfNeeded()
            Self.pumpMainRunLoop()
        }

        // Entering layout editing is a menu action only: the card's "Edit Layout…" item raises this
        // request, and the panel translates it into the one edit mode.
        LayoutUIState.shared.isEditingLayoutRequested = true
        try await flushLayout()
        #expect(LayoutUIState.shared.editMode == .deviceLayout, "The context-menu request must enter layout editing")
        #expect(!LayoutUIState.shared.isEditingLayoutRequested, "The request flag is consumed once handled")

        // 1. Outward drag on bottom-right corner arc handle: half -> full -> panel without reordering.
        let dragOutStart = handlePoint()
        sendMouse(.leftMouseDown, at: dragOutStart)
        try await Task.sleep(for: .milliseconds(30))
        Self.pumpMainRunLoop()

        let dragOutStep1 = NSPoint(x: dragOutStart.x + 60, y: dragOutStart.y)
        sendMouse(.leftMouseDragged, at: dragOutStep1)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .full, "Dragging handle right > 45pt must step half -> full")

        let dragOutStep2 = NSPoint(x: dragOutStart.x + 60, y: dragOutStart.y - 60)
        sendMouse(.leftMouseDragged, at: dragOutStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .panel, "Continuing drag down > 45pt must step full -> panel")

        sendMouse(.leftMouseUp, at: dragOutStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .panel)
        #expect(DeviceLayoutPrefs.decodeOrder(defaults.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]").isEmpty, "Handle drag must not trigger card reordering")

        // 2. Inward drag on bottom-right corner arc handle: panel -> full -> half without reordering.
        let dragInStart = handlePoint()
        sendMouse(.leftMouseDown, at: dragInStart)
        try await Task.sleep(for: .milliseconds(30))
        Self.pumpMainRunLoop()

        let dragInStep1 = NSPoint(x: dragInStart.x - 60, y: dragInStart.y)
        sendMouse(.leftMouseDragged, at: dragInStep1)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .full, "Dragging handle left < -45pt must step panel -> full")

        let dragInStep2 = NSPoint(x: dragInStart.x - 60, y: dragInStart.y + 60)
        sendMouse(.leftMouseDragged, at: dragInStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .half, "Continuing drag up < -45pt must step full -> half")

        sendMouse(.leftMouseUp, at: dragInStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .half)
        #expect(DeviceLayoutPrefs.decodeOrder(defaults.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]").isEmpty, "Inward handle drag must not trigger card reordering")

        // 3. Light tap on bottom-right corner arc handle cycles half -> 2×2 hero -> full -> panel -> half.
        func tapHandle() async throws -> [String: TileSize] {
            let point = handlePoint()
            sendMouse(.leftMouseDown, at: point)
            try await Task.sleep(for: .milliseconds(40))
            Self.pumpMainRunLoop()
            sendMouse(.leftMouseUp, at: point)
            try await flushLayout()
            return currentSizes()
        }

        let sizes1 = try await tapHandle()
        #expect(sizes1["all|\(light.id)"] == .hero)

        let sizes2 = try await tapHandle()
        #expect(sizes2["all|\(light.id)"] == .full)

        let sizes3 = try await tapHandle()
        #expect(sizes3["all|\(light.id)"] == .panel)

        let sizes4 = try await tapHandle()
        #expect(sizes4["all|\(light.id)"] == .half)

        // 4. Tapping the top-left `−` badge removes the card from 常用 (favorites).
        #expect(store.favoriteDeviceIds.contains(light.id), "The light card starts in Favorites")
        let cardBeforeRemove = try #require(LayoutUIState.shared.cardGlobalFrames[light.id])
        let removeBadgePoint = NSPoint(x: cardBeforeRemove.minX + 8, y: hosting.bounds.height - (cardBeforeRemove.minY + 8))
        sendMouse(.leftMouseDown, at: removeBadgePoint)
        try await Task.sleep(for: .milliseconds(40))
        Self.pumpMainRunLoop()
        sendMouse(.leftMouseUp, at: removeBadgePoint)
        try await flushLayout()
        #expect(!store.favoriteDeviceIds.contains(light.id), "Clicking the top-left − badge in edit mode must remove the device from Favorites")

        LayoutUIState.shared.endDeviceLayoutEditing()
    }

    private static func pumpMainRunLoop(_ seconds: TimeInterval = 0.05) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }
}
}
