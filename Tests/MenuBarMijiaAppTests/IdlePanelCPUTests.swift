import AppKit
import Foundation
import PreferencesTestSupport
import SwiftUI
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

extension PanelPresentationTests {
@MainActor
@Suite(.serialized)
struct IdlePanelCPUTests {
    private static func makeStore(
        theme: PanelTheme
    ) async throws -> (HomeStore, InMemoryUserDefaults) {
        // One instance for the store and for `MenuBarPanelController`: a second
        // `UserDefaults(suiteName:)` reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()
        defaults.set(theme.rawValue, forKey: PanelTheme.storageKey)
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
            defaults: defaults
        )
        store.completeOnboarding()
        try await store.waitForTestSnapshot()
        return (store, defaults)
    }

    private static func pumpMainRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @Test("Hiding the panel removes mouse monitors immediately and unmounts NSHostingView after warm-unload expiry in both themes", arguments: [
        PanelTheme.liquidGlass,
        PanelTheme.classic,
    ])
    func hiddenPanelUnmountsHostingViewAndMouseMonitors(theme: PanelTheme) async throws {
        _ = NSApplication.shared
        let (store, defaults) = try await Self.makeStore(theme: theme)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let controller = MenuBarPanelController(statusItem: statusItem, userDefaults: defaults)
        controller.presentsActively = false
        var scheduledUnloads: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        controller.warmUnloadScheduler = { delay, work in
            scheduledUnloads.append((delay, work))
        }
        controller.install(with: store)
        defer { controller.uninstall() }

        #expect(!controller.hasActiveMouseMonitors)

        for cycle in 0..<3 {
            controller.showPanel()
            Self.pumpMainRunLoop(seconds: 0.05)

            let panel = try #require(controller.panelWindow)
            let previousHosting = try #require(panel.contentView)
            #expect(panel.isVisible == true, "cycle \(cycle): panel must be visible after showPanel")
            #expect(controller.hostedPanelTheme == theme)
            #expect(controller.hasActiveMouseMonitors)
            #expect(store.pollingContext.panelVisible == true)

            controller.hidePanel(animated: false)
            Self.pumpMainRunLoop(seconds: 0.03)

            #expect(panel.isVisible == false, "cycle \(cycle): panel must be ordered out after hidePanel")
            #expect(!controller.hasActiveMouseMonitors)
            #expect(store.pollingContext.panelVisible == false)
            #expect(panel.contentView != nil, "cycle \(cycle): hosting stays warm until 45 s timer fires")
            #expect(controller.isWarmUnloadPending)

            let unload = try #require(scheduledUnloads.last)
            #expect(unload.delay == MenuBarPanelController.warmUnloadDelay)
            unload.work.perform()

            #expect(panel.contentView == nil, "cycle \(cycle): contentView must be nil after warm unload")
            #expect(controller.hostedPanelTheme == nil)

            controller.showPanel()
            let rebuiltHosting = try #require(panel.contentView)
            #expect(rebuiltHosting !== previousHosting)
            controller.hidePanel(animated: false)
            scheduledUnloads.last?.work.perform()
        }
    }

    @Test("Animated Liquid Glass close removes monitors on completion and unmounts after warm-unload expiry")
    func animatedLiquidGlassCloseUnmountsOnCompletion() async throws {
        _ = NSApplication.shared
        let (store, defaults) = try await Self.makeStore(theme: .liquidGlass)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let controller = MenuBarPanelController(statusItem: statusItem, userDefaults: defaults)
        controller.presentsActively = true
        controller.shouldReduceMotion = { true }
        var scheduledUnloads: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        controller.warmUnloadScheduler = { delay, work in
            scheduledUnloads.append((delay, work))
        }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        Self.pumpMainRunLoop(seconds: 0.25)

        let panel = try #require(controller.panelWindow)
        _ = try #require(panel.contentView)
        #expect(controller.hasActiveMouseMonitors)

        controller.hidePanel(animated: true)
        #expect(controller.isClosing == true)
        #expect(store.pollingContext.panelVisible == false)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (controller.isClosing || panel.isVisible) && ContinuousClock.now < deadline {
            Self.pumpMainRunLoop(seconds: 0.01)
            await Task.yield()
        }
        #expect(controller.isClosing == false)
        #expect(panel.isVisible == false)
        #expect(!controller.hasActiveMouseMonitors)
        #expect(controller.isWarmUnloadPending)
        #expect(panel.contentView != nil)

        let unload = try #require(scheduledUnloads.last)
        #expect(unload.delay == MenuBarPanelController.warmUnloadDelay)
        unload.work.perform()

        #expect(panel.contentView == nil)
        #expect(controller.hostedPanelTheme == nil)
    }

    @Test("Reopening during an animated close cancels teardown and keeps the panel mounted")
    func reopenDuringAnimatedCloseKeepsPanelMounted() async throws {
        _ = NSApplication.shared
        let (store, defaults) = try await Self.makeStore(theme: .liquidGlass)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let controller = MenuBarPanelController(statusItem: statusItem, userDefaults: defaults)
        controller.presentsActively = true
        controller.shouldReduceMotion = { true }
        controller.install(with: store)
        defer { controller.uninstall() }

        controller.showPanel()
        Self.pumpMainRunLoop(seconds: 0.25)

        let panel = try #require(controller.panelWindow)
        controller.hidePanel(animated: true)
        #expect(controller.isClosing == true)

        controller.showPanel()
        #expect(controller.isClosing == false)
        #expect(controller.isPanelVisible == true)
        #expect(store.pollingContext.panelVisible == true)

        Self.pumpMainRunLoop(seconds: 0.35)
        #expect(controller.isPanelVisible == true)
        #expect(panel.isVisible == true)
        #expect(panel.contentView != nil)
        #expect(controller.hasActiveMouseMonitors)
    }
}
}
