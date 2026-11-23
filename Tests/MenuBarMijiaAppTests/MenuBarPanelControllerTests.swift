import AppKit
import PreferencesTestSupport
import Speech
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@Suite(.serialized)
struct PanelPresentationTests {}

extension HomeStore {
    func waitForTestSnapshot() async throws {
        try await waitForInitialSnapshot(timeout: .seconds(30))
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(15),
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return }
    Issue.record(
        "condition was not met before \(timeout)",
        sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
}

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

    /// One instance for the store, the panel controller and the camera window: a second
    /// `UserDefaults(suiteName:)` reads through cfprefsd and can serve a stale cache (#309).
    private func makeCameraController(defaults: UserDefaults) -> CameraLivePanelController {
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        controller.frameDefaults = defaults
        return controller
    }

    private func makeStore() async throws -> (HomeStore, InMemoryUserDefaults) {
        let defaults = InMemoryUserDefaults()
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        #expect(!store.devices.isEmpty, "MockHomeProvider should deliver a snapshot right away")
        return (store, defaults)
    }

    private func makeExpiredMiSessionStore() async throws -> (HomeStore, InMemoryUserDefaults) {
        let defaults = InMemoryUserDefaults()
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
        let store = HomeStore(provider: mock, defaults: defaults)
        for _ in 0..<200 where !store.miSessionShowsExpired {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.miSessionShowsExpired)
        return (store, defaults)
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()

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

    @Test("Status bar icon stays template for normal and attention badges, red for safety alerts")
    func statusBarImageTemplateAndBadgeModes() throws {
        let normal = try #require(MenuBarPanelController.statusBarImage(for: MenuBarIconState(symbolName: "house.fill", badge: .none)))
        #expect(normal.isTemplate)

        let attention = try #require(MenuBarPanelController.statusBarImage(for: MenuBarIconState(symbolName: "house.slash", badge: .attention)))
        #expect(attention.isTemplate)
        #expect(attention.size.width >= 18)

        let alert = try #require(MenuBarPanelController.statusBarImage(for: MenuBarIconState(symbolName: "house.fill", badge: .safetyAlert)))
        #expect(!alert.isTemplate)
    }

    @Test("Status item reserves width for readouts and resets to variable length for icon-only")
    func statusItemWidthStabilization() async throws {
        let (store, _) = try await makeStore()
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let item = try #require(controller.statusItem)
        controller.syncStatusItem()
        let reserved = try #require(controller.widthState.reservedWidth)
        #expect(reserved > 0)
        #expect(abs(item.length - CGFloat(reserved)) <= 0.5)

        store.menuBarTargetId = "icon:only"
        controller.syncStatusItem()
        #expect(controller.widthState.reservedWidth == nil)
        #expect(item.length == NSStatusItem.variableLength)
    }

    @Test("Reopening during dismissal preserves the panel and emits each visibility change once", arguments: [false, true])
    func reopenDuringDismissal(reduced: Bool) async throws {
        // The slide-in dismissal this test drives belongs to the liquid-glass window.
        let themeScope = PanelPreferenceScope(theme: .liquidGlass)
        defer { themeScope.restore() }
        let (store, _) = try await makeStore()
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
        #expect(await waitUntil { !controller.isEntranceAnimating })
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
        #expect(await waitUntil { !controller.isEntranceAnimating })
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth(for: theme)) < 1)
        #expect(controller.hostedPanelTheme == theme)

        let screen = try #require(panel.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        switch theme {
        case .classic:
            let expectedHeight = min(PanelHeight.standard.points, visible.height - 24)
            #expect(abs(panel.frame.height - expectedHeight) <= 1, "the classic panel follows PanelHeight")
        case .liquidGlass:
            let maxAllowed = min(MenuBarPanelController.pilotMaxHeight, visible.height - 14)
            let minAllowed = min(MenuBarPanelController.pilotMinHeight, maxAllowed)
            #expect(panel.frame.height >= minAllowed - 1 && panel.frame.height <= maxAllowed + 1, "adaptive pilot clamps within 280...560 and visibleFrame")
        }
    }

    @Test("Hiding orders the window out, unmounts the SwiftUI tree, removes mouse monitors, and posts the hide notification")
    func hidePanelUnmountsContent() async throws {
        let (store, _) = try await makeStore()
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        #expect(!controller.hasActiveMouseMonitors)
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        _ = try #require(panel.contentView)
        #expect(controller.hasActiveMouseMonitors)

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
        #expect(panel.contentView == nil)
        #expect(controller.hostedPanelTheme == nil)
        #expect(!controller.hasActiveMouseMonitors)
        #expect(controller.panelWindow === panel, "the window is reused, not recreated")
    }

    @Test("Scanning from the Settings toast opens the panel that owns the QR view")
    func settingsToastScanRevealsPanel() async throws {
        let (store, _) = try await makeExpiredMiSessionStore()
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
        let (store, _) = try await makeExpiredMiSessionStore()
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
        let (store, _) = try await makeStore()
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(controller.hostedPanelTheme == .classic)

        let screen = try #require(panel.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        let expectedHeight = min(height.points, visible.height - 24)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
        #expect(abs(panel.frame.height - expectedHeight) <= 1, "classic height follows panel_height")
        #expect(panel.frame.minY >= visible.minY, "the panel stays on screen")
        #expect(panel.frame.maxY <= visible.maxY + 1)
        #expect(panel.frame.minX >= visible.minX)
        #expect(panel.frame.maxX <= visible.maxX)

        // Model a visible bar without a notch so a centered anchor can represent a real status item.
        let anchor = NSRect(x: visible.midX - 12, y: visible.maxY, width: 24, height: 24)
        let placementInput = MenuBarPanelController.PanelPlacementInput(
            screenFrame: screen.frame, visibleFrame: visible, anchor: anchor, size: panel.frame.size
        )
        let anchoredFrame = MenuBarPanelController.placement(theme: .classic, input: placementInput).frame
        #expect(abs(anchoredFrame.maxY - (anchor.minY - 6)) <= 1)
        #expect(abs(anchoredFrame.midX - anchor.midX) <= 1)
    }

    @Test("Changing the classic PanelHeight preference resizes the open panel")
    func classicPanelFollowsPanelHeightPreferenceChange() async throws {
        let themeScope = PanelPreferenceScope(theme: .classic, height: .compact)
        defer { themeScope.restore() }
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let classicContent = try #require(panel.contentView)
        let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
        #expect(controller.hostedPanelTheme == .classic)
        #expect(abs(panel.frame.height - min(PanelHeight.standard.points, visible.height - 24)) <= 1)

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
        let liquidScreen = try #require(panel.screen ?? NSScreen.main)
        let liquidVisible = liquidScreen.visibleFrame
        #expect(liquidContent !== classicContent)
        #expect(abs(panel.frame.width - MenuBarPanelController.pilotPanelWidth) < 1)
        let maxLiquidHeight = min(MenuBarPanelController.pilotMaxHeight, liquidVisible.height - 14)
        let minLiquidHeight = min(MenuBarPanelController.pilotMinHeight, maxLiquidHeight)
        #expect(panel.frame.height >= minLiquidHeight - 1 && panel.frame.height <= maxLiquidHeight + 1)
        #expect(panel.frame.minY >= liquidVisible.minY + 8 - 1)
        #expect(abs(panel.frame.maxX - (liquidVisible.maxX - 16)) <= 0.5)

        // Switching back while open closes it again and the next show restores the classic frame.
        UserDefaults.standard.set(PanelTheme.classic.rawValue, forKey: PanelTheme.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        Self.pumpMainRunLoop()

        #expect(controller.isPanelVisible == false)
        #expect(panel.contentView == nil)

        controller.showPanel()
        #expect(controller.hostedPanelTheme == .classic)
        #expect(abs(panel.frame.height - min(PanelHeight.standard.points, visible.height - 24)) <= 1)
    }

    @Test("Another window taking key status closes the panel; the panel and its own children do not")
    func otherWindowBecameKeyClosesPanel() async throws {
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()
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
        let (store, _) = try await makeStore()

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
        let (store, _) = try await makeStore()

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
        let (store, _) = try await makeStore()

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
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaults: defaults)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaults: defaults)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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
        let (store, defaults) = try await makeStore()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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
        let (store, defaults) = try await makeStore()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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
        let stored = cameraController.frameDefaults.string(forKey: "camera_live_panel_frame_v1")
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
        let (store, defaults) = try await makeStore()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))
        let cameraController = makeCameraController(defaults: defaults)
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
        let (store, defaults) = try await makeStore()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))
        let cameraController = makeCameraController(defaults: defaults)
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
        let defaults = InMemoryUserDefaults()
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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
        let (store, defaults) = try await makeStore()
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = makeCameraController(defaults: defaults)
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

        let slow = TileResizeGestureMath.projectedOffset(velocity: CGSize(width: 100, height: -100))
        #expect(abs(slow.width - 9.9) < 0.001)
        #expect(abs(slow.height + 9.9) < 0.001)
    }

    @Test("Disabling voice input blocks panel, status-item, and hotkey voice entry points with zero recognition tasks, audio taps, timers, or command submissions while preserving ordinary click and hotkey panel toggle")
    func voiceInputDisabledBlocksAllEntryPointsWhileKeepingClickAndHotkeyToggle() async throws {
        let (store, _) = try await makeStore()

        _ = NSApplication.shared
        let speech = SpeechInputController.shared
        var capturedEvents: (@Sendable (String?, Bool, Bool) -> Void)?
        let mockRuntime = SpeechInputRuntime(
            isPackagedApp: { true },
            requestMicrophoneAccess: { true },
            requestSpeechAuthorization: { .authorized },
            isHoldInputPhysicallyActive: { true },
            startCaptureSession: {
                _,
                onTapInstalled,
                onTapRemoved,
                onEngineStarted,
                onEngineStopped,
                onRecognitionTaskStarted,
                onRecognitionTaskCancelled,
                onEvent in
                onTapInstalled()
                onEngineStarted()
                onRecognitionTaskStarted()
                capturedEvents = onEvent
                return SpeechCaptureSession(
                    endAudio: {},
                    cancelRecognitionTask: { onRecognitionTaskCancelled() },
                    stopAudioEngine: { onEngineStopped() },
                    removeAudioTap: { onTapRemoved() }
                )
            }
        )
        speech.resetMetricsAndRuntimeForTesting(runtime: mockRuntime)

        let sharedController = MenuBarPanelController.shared
        let prevPresentsActively = sharedController.presentsActively
        sharedController.presentsActively = false
        store.enableVoiceInput = false
        sharedController.install(with: store)
        HotkeyAndNotificationManager.shared.attachStoreForTesting(store)
        defer {
            HotkeyAndNotificationManager.shared.attachStoreForTesting(nil)
            speech.resetMetricsAndRuntimeForTesting(runtime: .live)
            sharedController.uninstall()
            sharedController.presentsActively = prevPresentsActively
        }

        // Direct SpeechInputController entry points must no-op when disabled.
        speech.toggle(store: store)
        speech.startHoldToTalk(store: store)
        speech.finishHoldToTalk(store: store)
        await speech.start(holdMode: false, store: store)
        await speech.start(holdMode: true, store: store)
        speech.draft = "打开客厅灯"
        speech.submit(store: store)
        #expect(speech.isListening == false)
        #expect(speech.isHoldToTalk == false)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.activeRecognitionTaskCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.isAudioEngineRunning == false)
        #expect(speech.silenceTimersScheduledCount == 0)
        #expect(speech.holdReleaseTimersScheduledCount == 0)
        #expect(speech.hasActiveSilenceTimer == false)
        #expect(speech.hasActiveHoldReleaseTimer == false)
        #expect(speech.submittedCommandsCount == 0)
        #expect(capturedEvents == nil)

        // Status-item native long press must not start voice or open assistant bar when disabled.
        sharedController.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(sharedController.isPanelVisible == false)
        #expect(store.isShowingAssistantBar == false)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)
        #expect(speech.silenceTimersScheduledCount == 0)
        #expect(speech.holdReleaseTimersScheduledCount == 0)
        #expect(speech.submittedCommandsCount == 0)

        // Ordinary primary status-item click still toggles the panel open and closed.
        sharedController.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        sharedController.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(sharedController.isPanelVisible == true)
        sharedController.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        sharedController.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(sharedController.isPanelVisible == false)

        // Holding the global shortcut beyond the threshold must not trigger hold-to-talk; releasing still toggles the panel.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.02)
        try await Task.sleep(for: .milliseconds(50))
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        #expect(speech.isHoldToTalk == false)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(sharedController.isPanelVisible == true)
        #expect(store.isShowingAssistantBar == false)
        #expect(speech.submittedCommandsCount == 0)
    }

    @Test("Turning off voice input while recording stops recognition and audio engine, removes tap, cancels silence and hold-release timers, and blocks late results")
    func disablingVoiceInputWhileRecordingStopsAudioTapTimersAndBlocksLateResults() async throws {
        let (store, _) = try await makeStore()

        let speech = SpeechInputController.shared
        var latestEventHandler: (@Sendable (String?, Bool, Bool) -> Void)?
        var endAudioCallCount = 0
        let mockRuntime = SpeechInputRuntime(
            isPackagedApp: { true },
            requestMicrophoneAccess: { true },
            requestSpeechAuthorization: { .authorized },
            isHoldInputPhysicallyActive: { true },
            startCaptureSession: {
                _,
                onTapInstalled,
                onTapRemoved,
                onEngineStarted,
                onEngineStopped,
                onRecognitionTaskStarted,
                onRecognitionTaskCancelled,
                onEvent in
                onTapInstalled()
                onEngineStarted()
                onRecognitionTaskStarted()
                latestEventHandler = onEvent
                var cancelled = false
                var stopped = false
                var removed = false
                return SpeechCaptureSession(
                    endAudio: { endAudioCallCount += 1 },
                    cancelRecognitionTask: {
                        guard !cancelled else { return }
                        cancelled = true
                        onRecognitionTaskCancelled()
                    },
                    stopAudioEngine: {
                        guard !stopped else { return }
                        stopped = true
                        onEngineStopped()
                    },
                    removeAudioTap: {
                        guard !removed else { return }
                        removed = true
                        onTapRemoved()
                    }
                )
            }
        )
        speech.resetMetricsAndRuntimeForTesting(runtime: mockRuntime)
        speech.silenceAutoSubmitDelay = .seconds(5)
        speech.holdReleaseDelay = .seconds(5)
        defer {
            speech.resetMetricsAndRuntimeForTesting(runtime: .live)
        }

        // 1. Hands-free recording with active silence auto-submit timer.
        await speech.start(holdMode: false, store: store)
        #expect(speech.isListening == true)
        #expect(speech.recognitionTasksStartedCount == 1)
        #expect(speech.activeRecognitionTaskCount == 1)
        #expect(speech.audioTapsInstalledCount == 1)
        #expect(speech.activeAudioTapCount == 1)
        #expect(speech.isAudioEngineRunning == true)

        let firstEventHandler = try #require(latestEventHandler)
        firstEventHandler("把客厅灯打开", false, false)
        #expect(await Self.waitUntilCondition { speech.hasActiveSilenceTimer })
        #expect(speech.draft == "把客厅灯打开")
        #expect(speech.hasActiveSilenceTimer == true)
        #expect(speech.silenceTimersScheduledCount == 1)

        // Turn off voice input while actively listening and waiting on the silence timer.
        store.enableVoiceInput = false
        #expect(speech.isListening == false)
        #expect(speech.activeRecognitionTaskCount == 0)
        #expect(speech.recognitionTasksCancelledCount == 1)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.audioTapsRemovedCount == 1)
        #expect(speech.isAudioEngineRunning == false)
        #expect(speech.hasActiveSilenceTimer == false)
        #expect(speech.hasActiveHoldReleaseTimer == false)
        #expect(speech.draft.isEmpty)
        #expect(speech.submittedCommandsCount == 0)
        #expect(endAudioCallCount == 1)

        // Late recognition callback from the cancelled session must not resurrect draft, timers, or submit.
        firstEventHandler("把客厅灯关掉", true, false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(speech.draft.isEmpty)
        #expect(speech.hasActiveSilenceTimer == false)
        #expect(speech.silenceTimersScheduledCount == 1, "Zero new silence timers after turning off")
        #expect(speech.recognitionTasksStartedCount == 1, "Zero new recognition tasks after turning off")
        #expect(speech.audioTapsInstalledCount == 1, "Zero new audio taps after turning off")
        #expect(speech.submittedCommandsCount == 0, "Zero command submissions after turning off")

        // 2. Hold-to-talk recording with active hold-release flush timer.
        store.enableVoiceInput = true
        await speech.start(holdMode: true, store: store)
        #expect(speech.isListening == true)
        #expect(speech.isHoldToTalk == true)
        #expect(speech.activeRecognitionTaskCount == 1)
        #expect(speech.activeAudioTapCount == 1)
        #expect(speech.isAudioEngineRunning == true)

        let secondEventHandler = try #require(latestEventHandler)
        secondEventHandler("关闭卧室空调", false, false)
        #expect(await Self.waitUntilCondition { speech.draft == "关闭卧室空调" })
        speech.finishHoldToTalk(store: store)
        #expect(speech.hasActiveHoldReleaseTimer == true)
        let holdTimersBeforeDisable = speech.holdReleaseTimersScheduledCount
        let tasksBeforeDisable = speech.recognitionTasksStartedCount
        let tapsBeforeDisable = speech.audioTapsInstalledCount

        // Turn off voice input during the 320ms hold-release window.
        store.enableVoiceInput = false
        #expect(speech.isListening == false)
        #expect(speech.isHoldToTalk == false)
        #expect(speech.activeRecognitionTaskCount == 0)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.isAudioEngineRunning == false)
        #expect(speech.hasActiveHoldReleaseTimer == false)
        #expect(speech.hasActiveSilenceTimer == false)

        // Late final transcript arriving after disable must not submit or start anything.
        secondEventHandler("关闭卧室空调", true, false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(speech.recognitionTasksStartedCount == tasksBeforeDisable)
        #expect(speech.audioTapsInstalledCount == tapsBeforeDisable)
        #expect(speech.holdReleaseTimersScheduledCount == holdTimersBeforeDisable)
        #expect(speech.submittedCommandsCount == 0)
    }

    @Test("Turning off voice input while awaiting microphone or speech authorization prevents late grant from starting capture or submitting")
    func disablingVoiceInputDuringPendingAuthorizationBlocksLateGrant() async throws {
        let (store, _) = try await makeStore()

        let speech = SpeechInputController.shared
        var micContinuation: CheckedContinuation<Bool, Never>?
        var speechContinuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        let mockRuntime = SpeechInputRuntime(
            isPackagedApp: { true },
            requestMicrophoneAccess: {
                await withCheckedContinuation { cont in
                    micContinuation = cont
                }
            },
            requestSpeechAuthorization: {
                await withCheckedContinuation { cont in
                    speechContinuation = cont
                }
            },
            isHoldInputPhysicallyActive: { true },
            startCaptureSession: {
                _,
                onTapInstalled,
                onTapRemoved,
                onEngineStarted,
                onEngineStopped,
                onRecognitionTaskStarted,
                onRecognitionTaskCancelled,
                _ in
                onTapInstalled()
                onEngineStarted()
                onRecognitionTaskStarted()
                return SpeechCaptureSession(
                    endAudio: {},
                    cancelRecognitionTask: { onRecognitionTaskCancelled() },
                    stopAudioEngine: { onEngineStopped() },
                    removeAudioTap: { onTapRemoved() }
                )
            }
        )
        speech.resetMetricsAndRuntimeForTesting(runtime: mockRuntime)
        defer {
            micContinuation?.resume(returning: false)
            speechContinuation?.resume(returning: .denied)
            speech.resetMetricsAndRuntimeForTesting(runtime: .live)
        }

        // 1. Disable while waiting on microphone permission dialog.
        let startTask1 = Task { @MainActor in
            await speech.start(holdMode: false, store: store)
        }
        #expect(await Self.waitUntilCondition { micContinuation != nil })
        #expect(speech.isStarting == true)
        store.enableVoiceInput = false
        #expect(speech.isStarting == false)

        micContinuation?.resume(returning: true)
        micContinuation = nil
        await startTask1.value
        #expect(speech.isListening == false)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.isAudioEngineRunning == false)
        #expect(speech.silenceTimersScheduledCount == 0)
        #expect(speech.holdReleaseTimersScheduledCount == 0)
        #expect(speech.submittedCommandsCount == 0)

        // 2. Re-enable, pass mic permission, then disable while waiting on speech recognition permission.
        store.enableVoiceInput = true
        let startTask2 = Task { @MainActor in
            await speech.start(holdMode: true, store: store)
        }
        #expect(await Self.waitUntilCondition { micContinuation != nil })
        micContinuation?.resume(returning: true)
        micContinuation = nil
        #expect(await Self.waitUntilCondition { speechContinuation != nil })
        #expect(speech.isStarting == true)
        store.enableVoiceInput = false
        #expect(speech.isStarting == false)

        speechContinuation?.resume(returning: .authorized)
        speechContinuation = nil
        await startTask2.value
        #expect(speech.isListening == false)
        #expect(speech.isHoldToTalk == false)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.isAudioEngineRunning == false)
        #expect(speech.silenceTimersScheduledCount == 0)
        #expect(speech.holdReleaseTimersScheduledCount == 0)
        #expect(speech.submittedCommandsCount == 0)
    }

    @Test("Re-enabling voice input restores recording and command submission while typed commands remain unaffected")
    func reenablingVoiceInputRestoresRecordingAndTypedCommandsStayWorking() async throws {
        let (store, _) = try await makeStore()

        let speech = SpeechInputController.shared
        var latestEventHandler: (@Sendable (String?, Bool, Bool) -> Void)?
        let mockRuntime = SpeechInputRuntime(
            isPackagedApp: { true },
            requestMicrophoneAccess: { true },
            requestSpeechAuthorization: { .authorized },
            isHoldInputPhysicallyActive: { true },
            startCaptureSession: {
                _,
                onTapInstalled,
                onTapRemoved,
                onEngineStarted,
                onEngineStopped,
                onRecognitionTaskStarted,
                onRecognitionTaskCancelled,
                onEvent in
                onTapInstalled()
                onEngineStarted()
                onRecognitionTaskStarted()
                latestEventHandler = onEvent
                return SpeechCaptureSession(
                    endAudio: {},
                    cancelRecognitionTask: { onRecognitionTaskCancelled() },
                    stopAudioEngine: { onEngineStopped() },
                    removeAudioTap: { onTapRemoved() }
                )
            }
        )
        speech.resetMetricsAndRuntimeForTesting(runtime: mockRuntime)
        speech.silenceAutoSubmitDelay = .milliseconds(30)
        defer {
            speech.resetMetricsAndRuntimeForTesting(runtime: .live)
        }

        // Typed command while voice input is disabled still executes normally.
        store.enableVoiceInput = false
        let searchState = PanelSearchState()
        searchState.query = "把书房灯打开"
        PanelSearchKeyboard.runCommand(searchState.query, store: store, state: searchState)
        let typedCommandSucceeded = await Self.waitUntilCondition {
            if case .done = store.assistantState { return true }
            return false
        }
        #expect(typedCommandSucceeded == true)
        #expect(speech.recognitionTasksStartedCount == 0)
        #expect(speech.audioTapsInstalledCount == 0)

        // Turn voice input back on and verify recording + silence auto-submit work end-to-end.
        store.enableVoiceInput = true
        await speech.start(holdMode: false, store: store)
        #expect(speech.isListening == true)
        #expect(speech.recognitionTasksStartedCount == 1)
        #expect(speech.audioTapsInstalledCount == 1)
        #expect(speech.activeAudioTapCount == 1)
        #expect(speech.isAudioEngineRunning == true)

        let eventHandler = try #require(latestEventHandler)
        eventHandler("把客厅灯打开", false, false)
        #expect(await Self.waitUntilCondition { speech.submittedCommandsCount == 1 })
        #expect(speech.submittedCommandsCount == 1)
        #expect(speech.submittedCommands == ["把客厅灯打开"])
        #expect(speech.isListening == false)
        #expect(speech.activeAudioTapCount == 0)
        #expect(speech.activeRecognitionTaskCount == 0)
        #expect(speech.isAudioEngineRunning == false)
    }

    @Test("WP2d: Liquid Glass pilot measures 380 pt width, clamps 280-560 pt or tight visibleFrame, and serializes open/close/room/drawer passes")
    func adaptivePilotHeightAndSerialGeometry() async throws {
        #expect(MenuBarPanelController.clampAdaptiveHeight(160, availableHeight: 800) == 280)
        #expect(MenuBarPanelController.clampAdaptiveHeight(412.2, availableHeight: 800) == 413)
        #expect(MenuBarPanelController.clampAdaptiveHeight(720, availableHeight: 800) == 560)
        #expect(MenuBarPanelController.clampAdaptiveHeight(520, availableHeight: 340) == 340)
        #expect(MenuBarPanelController.preferredContentSize(screen: nil, theme: .liquidGlass, adaptiveContentHeight: nil).width == 380)

        let tightScreen = NSRect(x: 1_440, y: 0, width: 1_280, height: 360)
        let tightAnchor = NSRect(x: 2_660, y: 360, width: 24, height: 24)
        let tightFrame = MenuBarPanelController.liquidFrame(
            for: NSSize(width: 380, height: 560), within: tightScreen, anchor: tightAnchor
        )
        #expect(tightFrame.width == 380)
        #expect(tightFrame.minY >= tightScreen.minY + 8)
        #expect(tightFrame.maxY <= tightAnchor.minY - 6)
        #expect(tightFrame.maxX == tightScreen.maxX - 16)

        let themeScope = PanelPreferenceScope(theme: .liquidGlass, height: .compact)
        defer { themeScope.restore() }
        let (store, _) = try await makeStore()
        store.hasCompletedOnboarding = true
        store.dismissLaunchAtLoginSuggestion()

        let controller = makeController(store: store)
        defer { controller.uninstall() }

        // Multi-room demo content overflows 560 pt -> caps at 560 pt (or screen available height) and scrolls inside.
        controller.showPanel()
        Self.pumpMainRunLoop()
        let panel = try #require(controller.panelWindow)
        let screen = try #require(panel.screen ?? NSScreen.main)
        let maxCap = min(MenuBarPanelController.pilotMaxHeight, screen.visibleFrame.height - 14)
        #expect(abs(panel.frame.width - 380) < 1)
        #expect(abs(panel.frame.height - maxCap) <= 2)

        // Switching to a sparse room shrinks the panel toward the 280 pt pilot floor without closing.
        let demoDevices = store.devices
        let singleLight = try #require(store.devices.first {
            if case .light = $0.kind { return true }
            return false
        })
        store.devices = [singleLight]
        store.favoriteDeviceIds = []
        store.favoriteOrder = []
        _ = store.selectRoom(singleLight.roomId)
        Self.pumpMainRunLoop(0.08)
        let compactHeight = panel.frame.height
        #expect(compactHeight >= MenuBarPanelController.pilotMinHeight - 1)
        #expect(compactHeight < maxCap - 40, "sparse room shrinks well below the 560 pt cap")

        // Expanding a drawer grows serially, and collapsing it returns to the exact pre-expansion height.
        store.expandedDeviceId = singleLight.id
        Self.pumpMainRunLoop(0.08)
        #expect(panel.frame.height >= compactHeight)
        let passesBeforeHide = controller.serialGeometryApplyCount
        #expect(passesBeforeHide <= 3, "one coalesced pass per state change, not a layout feedback loop")

        store.expandedDeviceId = nil
        Self.pumpMainRunLoop(0.08)
        #expect(abs(panel.frame.height - compactHeight) <= 1, "collapsing the drawer restores the pre-expansion height")

        // Edit mode unmounts the footer slice (`clearOnDisappear: true`), so its 0 height must reach the
        // window instead of leaving the panel holding the space the footer used to take.
        // A four-tile room keeps the column above the 280 pt floor, where the footer's slice is visible
        // in the height instead of being absorbed by the minimum.
        store.devices = demoDevices.filter { $0.roomId == singleLight.roomId }
        Self.pumpMainRunLoop(0.08)
        let tallRoomHeight = panel.frame.height
        let probe = controller.panelAdaptiveHeightProbe
        let browsingNeed = probe.resolvedContentHeight
        let footerHeight = probe.bottomChromeHeight
        #expect(tallRoomHeight > MenuBarPanelController.pilotMinHeight + 4, "four tiles must clear the pilot floor")
        #expect(footerHeight > 0)
        #expect(abs(probe.topChromeHeight + probe.scrollContentHeight + footerHeight - browsingNeed) <= 0.5)

        LayoutUIState.shared.beginDeviceLayoutEditing()
        #expect(Self.pumpMainRunLoop(until: {
            probe.bottomChromeHeight == 0
                && abs(panel.frame.height - MenuBarPanelController.clampAdaptiveHeight(probe.resolvedContentHeight, availableHeight: maxCap)) <= 1
        }), "edit mode unmounts the footer slice, clears its measured height, and the window follows")

        LayoutUIState.shared.endDeviceLayoutEditing()
        #expect(Self.pumpMainRunLoop(until: { probe.bottomChromeHeight == footerHeight }))
        #expect(abs(panel.frame.height - tallRoomHeight) <= 1, "leaving edit mode restores the footer's height")

        controller.hidePanel()
        Self.pumpMainRunLoop(0.05)
        let passesWhileHidden = controller.serialGeometryApplyCount
        controller.panelAdaptiveHeightProbe.recordDuringLayout(slice: .scrollContent, height: 500)
        Self.pumpMainRunLoop(0.05)
        #expect(controller.serialGeometryApplyCount == passesWhileHidden, "hidden panel ignores layout slice churn")
    }

    @Test("WP2d: Hiding or losing key focus cancels an active 0.6s All-Off hold, declines pending confirmation, and collapses transient surfaces")
    func panelHideAndFocusLossCleanup() async throws {
        let transient = PanelTransientUIState.shared
        defer {
            transient.resetForTesting()
            PanelConnectionDetailState.shared.isPresented = false
        }

        let (store, _) = try await makeStore()
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        var cancelledCount = 0
        let holdToken = transient.beginAllOffHold { cancelledCount += 1 }
        #expect(transient.isAllOffHoldActive)

        // Losing key status cancels the active hold and suppresses the trailing button tap on mouse-up.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.panelWindow)
        #expect(cancelledCount == 1)
        #expect(transient.isAllOffHoldActive == false)
        #expect(transient.consumeConfirmedHold(session: holdToken) == false)
        #expect(transient.shouldSuppressTap() == true)

        // Hiding the panel cleans up pending cloud consent, active hold, and expanded transient drawers.
        let secondHold = transient.beginAllOffHold { cancelledCount += 1 }
        _ = secondHold
        var remindersCollapsed = false
        var offlineCollapsed = false
        transient.hasExpandedReminders = true
        transient.collapseRemindersHandler = { remindersCollapsed = true; transient.hasExpandedReminders = false }
        transient.hasExpandedOfflineDrawer = true
        transient.collapseOfflineDrawerHandler = { offlineCollapsed = true; transient.hasExpandedOfflineDrawer = false }
        store.pendingCloudConsent = PendingCloudConsent(
            utterance: "全部关闭",
            endpoint: "api.example.invalid",
            providerTitle: "Test"
        )
        let firstId = try #require(store.devices.first?.id)
        store.expandedDeviceId = firstId
        PanelConnectionDetailState.shared.isPresented = true

        controller.hidePanel()

        #expect(cancelledCount == 2)
        #expect(transient.isAllOffHoldActive == false)
        #expect(transient.shouldSuppressTap() == true)
        #expect(store.pendingCloudConsent == nil)
        #expect(store.expandedDeviceId == nil)
        #expect(PanelConnectionDetailState.shared.isPresented == false)
        #expect(remindersCollapsed)
        #expect(offlineCollapsed)
    }

    @Test("WP2d: a completed 0.6 s All-Off hold is consumed in either callback order, and only an explicit cancel voids it")
    func allOffHoldSessionSurvivesRelease() {
        let transient = PanelTransientUIState.shared
        defer { transient.resetForTesting() }

        // SwiftUI's real order: `onPressingChanged(false)` runs first, then the long press's `perform`.
        // The release must keep the session consumable, or every mouse hold is silently dropped.
        let releasedFirst = transient.beginAllOffHold { }
        transient.releaseAllOffHold(session: releasedFirst)
        #expect(transient.isAllOffHoldActive == false, "a finished hold stops owning Esc")
        #expect(transient.consumeConfirmedHold(session: releasedFirst), "release is not a cancel")

        // The opposite order (perform before release) must also fire exactly once.
        let performedFirst = transient.beginAllOffHold { }
        #expect(transient.consumeConfirmedHold(session: performedFirst))
        transient.releaseAllOffHold(session: performedFirst)
        #expect(transient.consumeConfirmedHold(session: performedFirst) == false, "a hold confirms once")

        // Esc, focus loss and hiding all go through `cancelAllOffHold`: the same late perform is refused.
        var resetCount = 0
        let cancelled = transient.beginAllOffHold { resetCount += 1 }
        transient.cancelAllOffHold()
        #expect(resetCount == 1, "a cancel resets the button's sweep")
        #expect(transient.consumeConfirmedHold(session: cancelled) == false)
        #expect(transient.shouldSuppressTap(), "a cancelled hold must not become the button's tap")

        // A short press that never reached 0.6 s leaves a stale token the next begin makes unusable.
        let shortPress = transient.beginAllOffHold { }
        transient.releaseAllOffHold(session: shortPress)
        let nextPress = transient.beginAllOffHold { }
        #expect(transient.consumeConfirmedHold(session: shortPress) == false)
        #expect(transient.consumeConfirmedHold(session: nextPress))
    }

    private static func waitUntilCondition(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private static func pumpMainRunLoop(_ seconds: TimeInterval = 0.05) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    /// Pumps the main runloop until `predicate` holds. A SwiftUI conditional removal settles across a
    /// display pass, so the height it frees arrives after the state change rather than with it.
    private static func pumpMainRunLoop(until predicate: () -> Bool, seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { return false }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        return true
    }
}
}

