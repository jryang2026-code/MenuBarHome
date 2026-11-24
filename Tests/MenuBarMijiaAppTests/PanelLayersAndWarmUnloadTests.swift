import AppKit
import Carbon
import Foundation
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

extension PanelPresentationTests {
@MainActor
@Suite(.serialized)
struct PanelLayersAndWarmUnloadTests {
    private func makeStore(theme: PanelTheme = .classic) async throws -> (HomeStore, InMemoryUserDefaults) {
        let defaults = InMemoryUserDefaults()
        defaults.set(theme.rawValue, forKey: PanelTheme.storageKey)
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
            defaults: defaults
        )
        store.assistantAutoResetTiming = .never
        store.completeOnboarding()
        try await store.waitForTestSnapshot()
        return (store, defaults)
    }

    // MARK: - 1. First-screen quick drawer fold state persistence & keyboard routing

    @Test("P1-3: Quick drawer defaults to folded and persists expand/collapse per user")
    func quickDrawerFoldStatePersistence() {
        let defaults = InMemoryUserDefaults()
        #expect(PanelQuickDrawerPrefs.load(from: defaults) == false)

        let state = PanelQuickDrawerState(defaults: defaults)
        #expect(state.isExpanded == false)

        #expect(state.toggle() == true)
        #expect(state.isExpanded == true)
        #expect(PanelQuickDrawerPrefs.load(from: defaults) == true)

        // A fresh instance reading the same defaults restores the persisted expanded state.
        let reloaded = PanelQuickDrawerState(defaults: defaults)
        #expect(reloaded.isExpanded == true)

        reloaded.setExpanded(false)
        #expect(reloaded.isExpanded == false)
        #expect(PanelQuickDrawerPrefs.load(from: defaults) == false)
    }

    @Test("P1-3: Quick drawer policy folds content cleanly and hides during search, edit, or dictation")
    func quickDrawerVisibilityPolicy() {
        #expect(PanelQuickDrawerPolicy.hasContent(
            showQuickActionsBar: false,
            hasScenes: false,
            proactiveEnabled: false,
            suggestionCount: 0
        ) == false)
        #expect(PanelQuickDrawerPolicy.hasContent(
            showQuickActionsBar: true,
            hasScenes: false,
            proactiveEnabled: false,
            suggestionCount: 0
        ) == true)
        #expect(PanelQuickDrawerPolicy.hasContent(
            showQuickActionsBar: false,
            hasScenes: false,
            proactiveEnabled: true,
            suggestionCount: 0
        ) == true)
        #expect(PanelQuickDrawerPolicy.hasContent(
            showQuickActionsBar: false,
            hasScenes: false,
            proactiveEnabled: false,
            suggestionCount: 2
        ) == true)

        #expect(PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: false, hasContent: true, isSearching: false, isEditing: false, isListening: false
        ) == false)
        #expect(PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: true, hasContent: true, isSearching: false, isEditing: false, isListening: false
        ) == true)
        #expect(PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: true, hasContent: true, isSearching: true, isEditing: false, isListening: false
        ) == false)
        #expect(PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: true, hasContent: true, isSearching: false, isEditing: true, isListening: false
        ) == false)
        #expect(PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: true, hasContent: true, isSearching: false, isEditing: false, isListening: true
        ) == false)
    }

    @Test("P1-3: ⌘K toggles the quick drawer in normal panel browsing and yields in modals or edit mode")
    func commandKTogglesQuickDrawer() {
        let cmdK = PanelKeyRouter.Key(code: kVK_ANSI_K, command: true, characters: "k")
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context()) == .toggleQuickDrawer)
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context(isPanelWindow: false)) == nil)
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context(isShowingOnboarding: true)) == nil)
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context(editMode: .deviceLayout)) == nil)
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context(hasActivePrompt: true)) == nil)
        #expect(PanelKeyRouter.beforeSearch(cmdK, PanelKeyRouter.Context(isFormFieldFocused: true)) == nil)
    }

    // MARK: - 2. Top-edge anchored ~200 ms height animation & Reduce Motion

    @Test("P0-7: Top-edge anchored frame preserves maxY on grow and shrink, and respects Reduce Motion")
    func topEdgeAnchoredHeightAnimationAndReduceMotion() async throws {
        let start = NSRect(x: 800, y: 400, width: 380, height: 320)
        let grown = MenuBarPanelController.topAnchoredFrame(from: start, targetHeight: 460)
        #expect(abs(grown.maxY - start.maxY) <= 0.5, "growing keeps top edge fixed")
        #expect(grown.height == 460)
        #expect(grown.origin.y == 260)

        let shrunk = MenuBarPanelController.topAnchoredFrame(from: grown, targetHeight: 300)
        #expect(abs(shrunk.maxY - start.maxY) <= 0.5, "shrinking keeps top edge fixed")
        #expect(shrunk.height == 300)
        #expect(shrunk.origin.y == 420)

        #expect(
            MenuBarPanelController.heightResizeAnimationDuration(
                presentsActively: true, isVisible: true, isClosing: false, reduceMotion: false,
                from: start, to: grown
            ) == MenuBarPanelController.heightResizeDuration
        )
        #expect(MenuBarPanelController.heightResizeDuration == 0.2)
        #expect(
            MenuBarPanelController.heightResizeAnimationDuration(
                presentsActively: true, isVisible: true, isClosing: false, reduceMotion: true,
                from: start, to: grown
            ) == nil,
            "Reduce Motion disables height animation"
        )
        #expect(
            MenuBarPanelController.heightResizeAnimationDuration(
                presentsActively: true, isVisible: true, isClosing: false, reduceMotion: false,
                from: start, to: start
            ) == nil,
            "unchanged height does not animate"
        )

        // Verify classic and liquid placement keep maxY anchored under a menu-bar anchor.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
        let anchor = NSRect(x: 1100, y: 876, width: 24, height: 24)
        for theme in PanelTheme.allCases {
            let smallFrame = MenuBarPanelController.placement(
                theme: theme,
                input: .init(
                    screenFrame: screen,
                    visibleFrame: visible,
                    anchor: anchor,
                    size: NSSize(width: MenuBarPanelController.panelWidth(for: theme), height: 340)
                )
            ).frame
            let tallFrame = MenuBarPanelController.placement(
                theme: theme,
                input: .init(
                    screenFrame: screen,
                    visibleFrame: visible,
                    anchor: anchor,
                    size: NSSize(width: MenuBarPanelController.panelWidth(for: theme), height: 520)
                )
            ).frame
            #expect(abs(smallFrame.maxY - tallFrame.maxY) <= 0.5, "\(theme) keeps top edge anchored")
        }

        // Verify live Classic controller resize respects Reduce Motion toggle.
        let (store, defaults) = try await makeStore(theme: .classic)
        let controller = MenuBarPanelController(userDefaults: defaults)
        controller.presentsActively = true
        var reduceMotion = true
        controller.shouldReduceMotion = { reduceMotion }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: PanelHeight.tall.points)
        #expect(controller.lastAppliedFrameAnimationDuration == nil, "Reduce Motion applies resize synchronously")

        reduceMotion = false
        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: PanelHeight.compact.points)
        #expect(controller.lastAppliedFrameAnimationDuration == MenuBarPanelController.heightResizeDuration)
    }

    // MARK: - 3. 45 s warm-unload timer & DispatchSourceMemoryPressure

    @Test("P0-7: Warm-unload timer keeps hosting warm before 45 s, cancels on re-show, and unloads at 45 s", arguments: [
        PanelTheme.classic,
        PanelTheme.liquidGlass,
    ])
    func warmUnloadTimerCancelsOnReshowAndUnloadsAfter45Seconds(theme: PanelTheme) async throws {
        let (store, defaults) = try await makeStore(theme: theme)
        let controller = MenuBarPanelController(userDefaults: defaults)
        controller.presentsActively = false

        var now: TimeInterval = 100
        var scheduled: [(deadline: TimeInterval, delay: TimeInterval, work: DispatchWorkItem)] = []
        controller.statusItemUptime = { now }
        controller.warmUnloadScheduler = { delay, work in
            scheduled.append((now + delay, delay, work))
        }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let firstHosting = try #require(panel.contentView)

        // Hide: arms 45 s timer and keeps hosting tree warm.
        controller.hidePanel(animated: false)
        #expect(controller.isPanelVisible == false)
        #expect(controller.isWarmUnloadPending)
        #expect(panel.contentView === firstHosting)
        #expect(scheduled.count == 1)
        #expect(scheduled[0].delay == 45.0)
        #expect(controller.warmUnloadScheduledAt == 100)

        // Re-show at t = 120 s (before 45 s): cancels timer and reuses warm hosting view.
        now = 120
        controller.showPanel()
        #expect(controller.isWarmUnloadPending == false)
        #expect(scheduled[0].work.isCancelled == true)
        #expect(panel.contentView === firstHosting, "re-showing within 45 s reuses warm hosting view")

        // Stale timer callback firing later must be a no-op.
        scheduled[0].work.perform()
        #expect(panel.contentView === firstHosting)
        #expect(controller.hostedPanelTheme == theme)

        // Hide again at t = 130 s, then let the 45 s timer fire at t = 175 s.
        now = 130
        controller.hidePanel(animated: false)
        #expect(scheduled.count == 2)
        #expect(scheduled[1].delay == 45.0)
        #expect(scheduled[1].work.isCancelled == false)

        now = 175
        scheduled[1].work.perform()
        #expect(panel.contentView == nil, "hosting tree is released after 45 s hidden")
        #expect(controller.hostedPanelTheme == nil)
        #expect(controller.isWarmUnloadPending == false)

        // Next show recreates the hosting tree and preserves #474 text-input activation & focus.
        var activations = 0
        controller.isApplicationActiveProvider = { false }
        controller.activateApplicationForTextInput = { activations += 1 }
        controller.showPanel()
        let recreatedHosting = try #require(panel.contentView)
        #expect(recreatedHosting !== firstHosting)
        #expect(controller.hostedPanelTheme == theme)
        #expect(panel.initialFirstResponder === recreatedHosting)
        #expect(recreatedHosting.acceptsFirstMouse(for: nil))

        controller.presentsActively = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        recreatedHosting.addSubview(textView)
        _ = panel.makeFirstResponder(textView)
        #expect(activations == 1, "#474 on-demand activation stays intact after warm unload + recreate")
        controller.presentsActively = false
    }

    @Test("P0-7: Memory pressure (.warning / .critical) unloads immediately when hidden and skips when visible")
    func memoryPressureUnloadsOnlyWhenHidden() async throws {
        let (store, defaults) = try await makeStore(theme: .liquidGlass)
        let controller = MenuBarPanelController(userDefaults: defaults)
        controller.presentsActively = false
        var scheduled: [DispatchWorkItem] = []
        controller.warmUnloadScheduler = { _, work in
            scheduled.append(work)
        }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let visibleHosting = try #require(panel.contentView)

        // While visible, neither .warning nor .critical may tear down the active UI.
        controller.handleMemoryPressure(eventMask: .warning)
        controller.handleMemoryPressure(eventMask: .critical)
        #expect(panel.contentView === visibleHosting)
        #expect(controller.isPanelVisible == true)

        // Hide -> .normal does nothing, .warning unloads immediately and cancels the 45 s timer.
        controller.hidePanel(animated: false)
        #expect(controller.isWarmUnloadPending == true)
        controller.handleMemoryPressure(eventMask: .normal)
        #expect(panel.contentView === visibleHosting)
        #expect(controller.isWarmUnloadPending == true)

        controller.handleMemoryPressure(eventMask: .warning)
        #expect(panel.contentView == nil)
        #expect(controller.hostedPanelTheme == nil)
        #expect(controller.isWarmUnloadPending == false)
        #expect(scheduled.last?.isCancelled == true)

        // Re-show, hide again, and verify .critical also unloads immediately.
        controller.showPanel()
        #expect(panel.contentView != nil)
        controller.hidePanel(animated: false)
        controller.handleMemoryPressure(eventMask: .critical)
        #expect(panel.contentView == nil)
        #expect(controller.hostedPanelTheme == nil)
    }
}
}
