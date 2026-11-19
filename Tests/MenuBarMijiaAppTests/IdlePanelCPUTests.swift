import AppKit
import Observation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
private final class IdlePanelThemeScope {
    private let previousTheme: String?

    init(theme: PanelTheme) {
        previousTheme = UserDefaults.standard.string(forKey: PanelTheme.storageKey)
        UserDefaults.standard.set(theme.rawValue, forKey: PanelTheme.storageKey)
    }

    func set(_ theme: PanelTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: PanelTheme.storageKey)
    }

    func restore() {
        if let previousTheme {
            UserDefaults.standard.set(previousTheme, forKey: PanelTheme.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelTheme.storageKey)
        }
    }
}

@Observable
@MainActor
private final class ProbeVisibilityModel {
    var isVisible = true
    var animate = true
}

private struct ProbeRootView: View {
    let model: ProbeVisibilityModel

    var body: some View {
        HStack(spacing: 8) {
            BreathingDot(color: .green, animate: model.animate)
            OmnibarLeadingSymbol(listening: true, isThinking: true)
        }
        .environment(\.reduceMotionOverride, false)
        .environment(\.isPanelVisible, model.isVisible)
        .transaction { transaction in
            if !model.isVisible {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

extension PanelPresentationTests {
/// Regression coverage ensuring the kept-alive control-center SwiftUI tree stops all continuous
/// animations, spinners, and live clocks once `MenuBarPanelController.hidePanel` orders the window
/// out (#208 follow-up: macOS 26+ retained `RepeatAnimation` and `SymbolEffect` ticks on hidden
/// trees and drove `FlexCoreInteractionModifier` spring updates at ~40% idle CPU).
@MainActor
@Suite(.serialized)
struct IdlePanelCPUTests {
    init() {
        SnapshotWindow.pinOverlayScrollers()
    }

    private static func pumpRunLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slice = min(0.01, deadline.timeIntervalSinceNow)
            guard slice > 0 else { break }
            CFRunLoopRunInMode(.defaultMode, slice, false)
        }
    }

    private static func containsProgressIndicator(in view: NSView?) -> Bool {
        guard let view else { return false }
        if view is NSProgressIndicator { return true }
        return view.subviews.contains { containsProgressIndicator(in: $0) }
    }

    /// Waits until the hidden hosting view stops receiving `layout()` passes, so hidden-panel
    /// assertions count steady state instead of the tail of the hide itself.
    ///
    /// Ordering the window out does not end SwiftUI's work at the same instant: `orderOut` leaves
    /// deferred `NSHostingView` root-value updates queued (the off-screen test panel runs no display
    /// cycle, so `requestUpdate(after:)` retries them), and each retry still drives one hosting
    /// layout pass. That burst is bounded — measured at ≤ 1 s after `hidePanel` with the host's
    /// cores fully saturated, then silent — but it straddles any fixed "sleep, then reset the
    /// counter" instant, which made the result depend on machine load rather than on the product.
    ///
    /// Returns `true` once the tree has been pass-free for `quietWindow`, or `false` when passes were
    /// still arriving at `deadline`. A surviving hidden clock (a re-mounted `TimelineView(.animation)`
    /// still ticking against an ordered-out window measured 13 Hz) never leaves a quiet gap that long,
    /// so it keeps returning `false`: callers must fail on it instead of measuring around it.
    private static func waitForHiddenLayoutQuiescence(
        _ hosting: PanelHostingView<AnyView>,
        quietWindow: TimeInterval = 0.25,
        deadline: TimeInterval = 5
    ) -> Bool {
        hosting.resetLayoutPassCount()
        let start = Date()
        var lastCount = 0
        var quietSince = start
        while Date().timeIntervalSince(start) < deadline {
            pumpRunLoop(0.01)
            let count = hosting.layoutPassCount
            if count != lastCount {
                lastCount = count
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietWindow {
                return true
            }
        }
        return false
    }

    private func makeConnectedDemoStore() async throws -> (HomeStore, String) {
        let suite = "test.idle.panel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(HomeBackend.demo.rawValue, forKey: "home_backend")
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.hasCompletedOnboarding = true
        store.connectionStatus = .connected
        #expect(store.panelHealth == .ok)
        return (store, suite)
    }

    @Test("PanelHostingVisibility tracks show, animated close completion, and mid-close reopen")
    func panelHostingVisibilityLifecycle() async throws {
        let themeScope = IdlePanelThemeScope(theme: .liquidGlass)
        defer { themeScope.restore() }
        let (store, suite) = try await makeConnectedDemoStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let controller = MenuBarPanelController()
        controller.presentsActively = true
        controller.shouldReduceMotion = { true }
        controller.install(with: store)
        defer { controller.uninstall() }

        #expect(controller.panelHostingVisibility.isVisible == false)

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(controller.panelHostingVisibility.isVisible == true)

        // Start an animated close, then reopen mid-flight: visibility must stay true throughout
        // and the cancelled close completion must not flip it false.
        controller.hidePanel(animated: true)
        #expect(controller.isClosing == true)
        #expect(controller.panelHostingVisibility.isVisible == true)

        Self.pumpRunLoop(0.05)
        controller.showPanel()
        #expect(controller.isClosing == false)
        #expect(controller.panelHostingVisibility.isVisible == true)

        // Let the cancelled close duration elapse and confirm it never tore down visibility.
        Self.pumpRunLoop(0.26)
        #expect(panel.isVisible == true)
        #expect(controller.panelHostingVisibility.isVisible == true)

        // Now let an uninterrupted animated close finish ordering out.
        controller.hidePanel(animated: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while panel.isVisible, ContinuousClock.now < deadline {
            Self.pumpRunLoop(0.01)
            await Task.yield()
        }
        #expect(panel.isVisible == false)
        #expect(controller.panelHostingVisibility.isVisible == false)
    }

    @Test("BreathingDot and OmnibarLeadingSymbol completely stop ViewGraph layout ticks when hidden")
    func breathingDotAndOmnibarSymbolTearDownAnimationsWhenHidden() {
        _ = NSApplication.shared
        let model = ProbeVisibilityModel()
        let panel = MenuBarPanelController.makePanel(theme: .classic)
        panel.setFrame(NSRect(x: -10_000, y: 100, width: 120, height: 60), display: true)

        let hosting = PanelHostingView(rootView: AnyView(ProbeRootView(model: model)))
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        panel.contentView = hosting
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
        }

        panel.alphaValue = 1
        panel.orderFront(nil)
        Self.pumpRunLoop(0.15)
        hosting.resetLayoutPassCount()
        Self.pumpRunLoop(0.25)
        #expect(hosting.layoutPassCount > 0, "active BreathingDot / symbolEffect should advance ViewGraph while visible")

        // Hide via environment and order out: the animated child nodes unmount synchronously,
        // leaving zero further ViewGraph layout passes.
        model.isVisible = false
        hosting.layoutSubtreeIfNeeded()
        panel.orderOut(nil)
        Self.pumpRunLoop(0.1)
        hosting.resetLayoutPassCount()
        Self.pumpRunLoop(0.35)
        #expect(hosting.layoutPassCount == 0, "hidden BreathingDot and OmnibarLeadingSymbol must not schedule further layouts")
    }

    @Test("Liquid Glass and Classic panels stop all hosting layout passes after hidePanel with panelHealth == .ok")
    func liquidGlassAndClassicStopHostingLayoutsWhenHidden() async throws {
        for theme in [PanelTheme.liquidGlass, PanelTheme.classic] {
            let themeScope = IdlePanelThemeScope(theme: theme)
            defer { themeScope.restore() }
            let (store, suite) = try await makeConnectedDemoStore()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

            let controller = MenuBarPanelController()
            controller.presentsActively = false
            controller.shouldReduceMotion = { false }
            controller.install(with: store)
            defer { controller.uninstall() }

            controller.showPanel()
            let panel = try #require(controller.panelWindow)
            let hosting = try #require(panel.contentView as? PanelHostingView<AnyView>)
            panel.setFrameOrigin(NSPoint(x: -10_000, y: panel.frame.minY))
            panel.alphaValue = 1
            Self.pumpRunLoop(0.2)

            controller.hidePanel(animated: false)
            #expect(panel.isVisible == false)
            #expect(store.pollingContext.panelVisible == false)
            #expect(controller.panelHostingVisibility.isVisible == false)

            let settled = Self.waitForHiddenLayoutQuiescence(hosting)
            #expect(
                settled,
                "hidden \(theme.rawValue) panel never settled: \(hosting.layoutPassCount) layout passes in 5 s"
            )
            hosting.resetLayoutPassCount()
            Self.pumpRunLoop(0.35)
            #expect(
                hosting.layoutPassCount == 0,
                "Expected 0 hidden layout passes for \(theme.rawValue), got \(hosting.layoutPassCount)"
            )
        }
    }

    @Test("Classic device-layout editing preserves edit mode across hide/show while pausing jiggle TimelineView")
    func classicLayoutEditingPausesJiggleTimelineWhenHidden() async throws {
        let themeScope = IdlePanelThemeScope(theme: .classic)
        defer {
            LayoutUIState.shared.endDeviceLayoutEditing()
            themeScope.restore()
        }
        let (store, suite) = try await makeConnectedDemoStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let controller = MenuBarPanelController()
        controller.presentsActively = false
        controller.shouldReduceMotion = { false }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? PanelHostingView<AnyView>)
        panel.setFrameOrigin(NSPoint(x: -10_000, y: panel.frame.minY))
        panel.alphaValue = 1
        LayoutUIState.shared.beginDeviceLayoutEditing()
        // Let `.animation(AppleMotion.snappySpring, value: layoutUI.editMode)` finish its ~0.6 s
        // entrance spring while open so the hidden check measures steady-state jiggle teardown.
        Self.pumpRunLoop(0.7)

        controller.hidePanel(animated: false)
        #expect(LayoutUIState.shared.editMode == .deviceLayout, "edit session survives close/reopen")
        let settled = Self.waitForHiddenLayoutQuiescence(hosting)
        #expect(
            settled,
            "hidden classic edit mode never settled: \(hosting.layoutPassCount) layout passes in 5 s"
        )
        hosting.resetLayoutPassCount()
        Self.pumpRunLoop(0.5)
        #expect(hosting.layoutPassCount == 0, "hidden classic edit mode must pause jiggle TimelineView")

        controller.showPanel()
        #expect(controller.panelHostingVisibility.isVisible == true)
        #expect(LayoutUIState.shared.editMode == .deviceLayout)
    }

    @Test("Hidden panel suspends relative activity clocks, scheduled countdown timers, and thinking spinners")
    func hiddenPanelSuspendsClocksSpinnersAndSymbolEffects() async throws {
        let themeScope = IdlePanelThemeScope(theme: .classic)
        defer { themeScope.restore() }
        let (store, suite) = try await makeConnectedDemoStore()
        defer {
            store.assistantState = .idle
            for cmd in store.scheduledCommands {
                store.cancelScheduledCommands(id: cmd.id)
            }
            store.clearDismissibleActivities()
            store.dismissAssistantBar()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        let deviceId = try #require(store.devices.first?.id)
        store.recentSafetyAlerts = [
            RecordedSafetyAlert(
                alert: SafetyAlert(
                    id: "idle-test-alert",
                    deviceId: deviceId,
                    title: "设备持续运行",
                    body: "请确认是否需要关闭。"
                ),
                scope: store.connectionScopeIdentifier,
                date: Date().addingTimeInterval(-12)
            )
        ]
        store.presentAssistantBar(startVoice: false)
        store.scheduledCommands = [
            ScheduledCommand(
                reply: "10 分钟后关灯",
                fireDate: Date().addingTimeInterval(600),
                plan: IntentPlan(intents: [], reply: "10 分钟后关灯", source: .local)
            )
        ]
        store.assistantState = .thinking

        let controller = MenuBarPanelController()
        controller.presentsActively = false
        controller.shouldReduceMotion = { false }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? PanelHostingView<AnyView>)
        panel.setFrameOrigin(NSPoint(x: -10_000, y: panel.frame.minY))
        panel.alphaValue = 1
        Self.pumpRunLoop(0.2)
        #expect(Self.containsProgressIndicator(in: hosting), "thinking state mounts ProgressView while visible")

        controller.hidePanel(animated: false)
        #expect(!Self.containsProgressIndicator(in: hosting), "hidden panel must unmount indeterminate NSProgressIndicator")

        let settled = Self.waitForHiddenLayoutQuiescence(hosting)
        #expect(
            settled,
            "hidden panel never settled: \(hosting.layoutPassCount) layout passes in 5 s"
        )
        hosting.resetLayoutPassCount()
        // Span > 1.0 s so any 1 Hz relative/timer clock would tick at least once if still active.
        Self.pumpRunLoop(1.2)
        #expect(
            hosting.layoutPassCount == 0,
            "hidden panel must not wake ViewGraph for relative/timer clocks or spinners; got \(hosting.layoutPassCount)"
        )

        // Reopening restores live spinner while assistantState is still .thinking.
        controller.showPanel()
        Self.pumpRunLoop(0.1)
        #expect(Self.containsProgressIndicator(in: hosting), "reopening remounts ProgressView while still thinking")
    }
}
}
