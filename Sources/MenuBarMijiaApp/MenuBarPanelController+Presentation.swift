import AppKit
import SwiftUI
import MijiaCore

/// Window, frame and motion for the two panel themes.
///
/// The classic panel keeps commit 321c067's shape: a 376 pt card whose height follows
/// `PanelHeight`, centred under the menu-bar item, with the system window shadow and no entrance
/// animation. The Liquid Glass column stays on the right edge of the status item's screen, slides in
/// from off-screen and sits on the readability backdrop instead of a window shadow.
///
/// Status-item gestures, context menus, mouse monitors and observer registration stay in
/// `MenuBarPanelController.swift`; this file handles presentation, including the frame/theme
/// reaction to a preference change. The controller's content builders (`ensurePanelWindow`,
/// `prepareSidecar`, `refreshPanelContent`, `dropPanelContent`) live beside the stored state they
/// mutate.
extension MenuBarPanelController {
    // MARK: - Presentation Metrics

    private static let topGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    private static let rightInset: CGFloat = 16

    /// Notification Center measurements: 50 % at 85 ms, 63 % at 115 ms, 91 % at 198 ms.
    private static let fadeInDuration: TimeInterval = 0.365
    private static let fadeOutDuration: TimeInterval = 0.217
    private static let fadeCurve = CAMediaTimingFunction(controlPoints: 0.44, 1, 0.54, 0.98)
    private static let closeCurve = CAMediaTimingFunction(controlPoints: 0.20, 0, 0.50, 1)

    // MARK: - Showing & Hiding

    func showPanel() {
        guard let store else { return }
        let theme = PanelTheme.current
        let panel = ensurePanelWindow(theme: theme)
        prepareSidecar(for: panel)
        panel.appearance = Self.preferredAppearance()
        refreshPanelContent(theme: theme)

        let target = columnFrame(for: theme)
        let wasVisible = panel.isVisible && !isClosing
        let wasOnScreen = panel.isVisible
        isClosing = false
        if !wasVisible { presentationGeneration &+= 1 }
        let generation = presentationGeneration
        panel.ignoresMouseEvents = false
        installMouseMonitors()

        if presentsActively {
            switch theme {
            case .classic:
                panel.setFrame(target, display: true)
                panel.alphaValue = 1
                panel.hasShadow = true
                // Order the window in first: cooperative activation only succeeds once the app has
                // a window to become active for, and this agent app owns none at that moment.
                panel.makeKeyAndOrderFront(nil)
                if !NSApp.isActive {
                    NSApp.activate()
                }
            case .liquidGlass:
                if !wasVisible {
                    grokBallSidecar?.setPresentationSuspended(true)
                    if !wasOnScreen {
                        let reduced = shouldReduceMotion()
                        panel.setFrame(
                            reduced ? target : target.offsetBy(dx: target.width + Self.rightInset, dy: 0),
                            display: true
                        )
                        panel.alphaValue = reduced ? 0 : 1
                    }
                }
                panel.hasShadow = false
                presentBackdropShadow(around: panel.frame, under: panel)
                // Agent activation is asynchronous; the hosting root also keeps glass active on frame one.
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.hasShadow = false
            panel.orderFront(nil)
        }
        setStatusItemHighlighted(true)
        if theme == .classic {
            // A Liquid Glass session suspends the ball while its column slides; resuming also
            // repositions it, which is the `synchronize()` the classic panel used to do.
            grokBallSidecar?.setPresentationSuspended(false)
        } else {
            grokBallSidecar?.synchronize()
        }
        // Re-showing an already visible panel (hotkey while open, URL scheme, intent) must not replay
        // the entrance animation.
        guard !wasVisible else { return }
        store.setPanelVisible(true)
        NotificationCenter.default.post(name: Self.didShowNotification, object: panel)
        if presentsActively, theme == .liquidGlass {
            // Finish initial glass layout before starting the motion clock, avoiding a skipped first half.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            backdropWindow?.displayIfNeeded()
            CATransaction.flush()
            fadePanel(to: 1, duration: Self.fadeInDuration) { [weak self] in
                guard let self, generation == self.presentationGeneration, !self.isClosing else { return }
                self.grokBallSidecar?.setPresentationSuspended(false)
                self.refreshPanelFrame()
            }
        } else if theme == .liquidGlass {
            grokBallSidecar?.setPresentationSuspended(false)
        }
    }

    /// `animated` is false for a theme switch, which closes the panel in place before the hosting
    /// tree is rebuilt for the other theme.
    func hidePanel(animated: Bool = true) {
        guard let panel = panelWindow, panel.isVisible, !isClosing else { return }
        // #146 §5.2：点面板外、⌘Tab、打开设置、Esc 阶梯都会走到这里，排序会话不能比面板活得久。
        // 必须在这里提交草稿，而不是依赖视图的 `onDisappear`——拖动中 `DragGesture.onEnded` 不保证执行。
        LayoutUIState.shared.commitRoomOrderIfNeeded()
        if hostedPanelTheme == .classic {
            grokBallSidecar?.hide()
        } else {
            grokBallSidecar?.setPresentationSuspended(true)
        }
        store?.dismissGrokBallStage()
        restoreStatusItemHighlight()
        store?.setPanelVisible(false)
        if presentsActively, animated, hostedPanelTheme == .liquidGlass {
            // Hide logically now; order out only after the window and its shadow leave the screen.
            isClosing = true
            panel.ignoresMouseEvents = true
            let generation = presentationGeneration
            fadePanel(to: 0, duration: Self.fadeOutDuration) { [weak self] in
                guard let self, self.isClosing, generation == self.presentationGeneration else { return }
                self.isClosing = false
                panel.ignoresMouseEvents = false
                self.hideBackdropShadow()
                panel.orderOut(nil)
            }
        } else {
            isClosing = false
            panel.ignoresMouseEvents = false
            hideBackdropShadow()
            panel.orderOut(nil)
        }
        // The SwiftUI tree stays alive, exactly like a `.window`-style `MenuBarExtra`: scroll
        // position, the search field text and layout-editing state survive a close/reopen. A theme
        // switch drops it explicitly so the next open builds the other root view.
        NotificationCenter.default.post(name: Self.didHideNotification, object: panel)
    }

    /// Retarget the current window position, keeping the full shadow in the same animation group.
    /// Reduce Motion keeps the final geometry and cross-fades over 0.2 seconds instead.
    private func fadePanel(
        to alpha: CGFloat,
        duration: TimeInterval,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let panel = panelWindow else { return }
        let target = columnFrame(for: .liquidGlass)
        let reduced = shouldReduceMotion()
        let destination = alpha == 1 ? target : target.offsetBy(dx: target.width + Self.rightInset, dy: 0)
        if reduced {
            panel.setFrame(target, display: true)
            backdropWindow?.setFrame(target.insetBy(dx: -Self.backdropBleed, dy: -Self.backdropBleed), display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.2 : duration
            context.timingFunction = alpha == 1 ? Self.fadeCurve : Self.closeCurve
            if reduced {
                panel.animator().alphaValue = alpha
                backdropWindow?.animator().alphaValue = alpha
            } else {
                panel.alphaValue = 1
                backdropWindow?.alphaValue = 1
                panel.animator().setFrame(destination, display: true)
                backdropWindow?.animator().setFrame(destination.insetBy(dx: -Self.backdropBleed, dy: -Self.backdropBleed), display: true)
            }
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: - Frame

    /// Sizing hook for `ClassicControlCenterPanel`: 376 pt wide, the requested height, top edge kept
    /// under the item and clamped to the item's screen. No-op for the Liquid Glass column, whose
    /// height always comes from the screen.
    func updatePanelSize(width: CGFloat, height: CGFloat) {
        guard hostedPanelTheme == .classic, let panel = panelWindow else { return }
        let target = Self.frame(
            for: NSSize(width: Self.panelWidth, height: height),
            anchor: statusAnchor,
            screen: statusScreen,
            theme: .classic
        )
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
        grokBallSidecar?.synchronize()
    }

    func handleScreenParametersChanged() {
        guard let panel = panelWindow, panel.isVisible else { return }
        switch hostedPanelTheme ?? PanelTheme.current {
        case .classic:
            panel.setFrame(
                Self.frame(for: panel.frame.size, anchor: statusAnchor, screen: statusScreen, theme: .classic),
                display: true
            )
            grokBallSidecar?.synchronize()
        case .liquidGlass:
            refreshPanelFrame()
        }
    }

    func handlePreferencesChanged() {
        panelWindow?.appearance = Self.preferredAppearance()
        grokBallSidecarWindow?.appearance = Self.preferredAppearance()
        let theme = PanelTheme.current
        if let built = hostedPanelTheme, built != theme {
            // A theme switch only takes effect on the next open: close the panel in place, drop the
            // hosting tree, and let the next `showPanel` build the other root view. Bumping the
            // generation invalidates any in-flight show/close completion.
            presentationGeneration &+= 1
            isClosing = false
            if panelWindow?.isVisible == true {
                hidePanel(animated: false)
            }
            dropPanelContent()
            return
        }
        guard isPanelVisible else { return }
        switch theme {
        case .classic:
            // Height or skin changed in Settings while the panel is open: apply it right away.
            updatePanelSize(
                width: Self.panelWidth,
                height: Self.preferredContentSize(screen: statusScreen, theme: .classic).height
            )
        case .liquidGlass:
            refreshPanelFrame()
        }
    }

    /// The window target for the theme currently on screen.
    private func columnFrame(for theme: PanelTheme) -> NSRect {
        Self.frame(
            for: Self.preferredContentSize(screen: statusScreen, theme: theme),
            anchor: statusAnchor,
            screen: statusScreen,
            theme: theme
        )
    }

    /// Re-applies the column frame after a screen or preference change. No-op while closed.
    private func refreshPanelFrame() {
        guard let panel = panelWindow, isPanelVisible, grokBallSidecar?.isPresentationSuspended != true else { return }
        let theme = hostedPanelTheme ?? PanelTheme.current
        let target = columnFrame(for: theme)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
        if presentsActively, theme == .liquidGlass {
            presentBackdropShadow(around: target, under: panel)
        }
        grokBallSidecar?.synchronize()
    }

    static func makePanel(theme: PanelTheme) -> NSPanel {
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: preferredContentSize(screen: nil, theme: theme)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = theme == .classic
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = preferredAppearance()
        panel.contentView = nil
        return panel
    }

    /// Mirrors `AppAppearance` onto the AppKit panel so materials, dynamic `NSColor`s, menus and
    /// tooltips match the SwiftUI scheme.
    static func preferredAppearance() -> NSAppearance? {
        let raw = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        return (raw.flatMap(AppAppearance.init(rawValue:)) ?? .system).nsAppearance
    }

    /// Width is fixed; height comes from the theme: the `PanelHeight` preference for the classic
    /// card, the full column under the menu bar for Liquid Glass.
    static func preferredContentSize(screen: NSScreen?, theme: PanelTheme) -> NSSize {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        switch theme {
        case .classic:
            let raw = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
            let height = (raw.flatMap(PanelHeight.init(rawValue:)) ?? .standard).points
            return NSSize(width: panelWidth, height: min(height, available - 24))
        case .liquidGlass:
            return NSSize(width: panelWidth, height: max(320, available - topGap - screenMargin))
        }
    }

    private var statusAnchor: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var statusScreen: NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main
    }

    /// Raw geometry for a theme: the classic card hangs centred under the item, the Liquid Glass
    /// column is right-aligned on the item's screen.
    static func frame(for size: NSSize, anchor: NSRect?, screen: NSScreen?, theme: PanelTheme) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        switch theme {
        case .classic: return classicFrame(for: size, within: visible, anchor: anchor)
        case .liquidGlass: return liquidFrame(for: size, within: visible, anchor: anchor)
        }
    }

    /// Puts the card's top edge just under the status item, centred on it, clamped into the visible
    /// frame of whichever screen hosts the item (a menu bar on a secondary display included).
    private static func classicFrame(for size: NSSize, within visible: NSRect, anchor: NSRect?) -> NSRect {
        let width = min(size.width, visible.width - screenMargin * 2)
        let height = min(size.height, visible.height - screenMargin * 2)
        var x = (anchor?.midX ?? visible.midX) - width / 2
        x = min(max(x, visible.minX + screenMargin), visible.maxX - width - screenMargin)
        let top = anchor?.minY ?? visible.maxY
        let y = max(top - height - topGap, visible.minY + screenMargin)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// Right-aligns the column on the status item's screen, with its top below the menu bar.
    /// The column runs down to the screen margin; detached anchors fall back to the visible top.
    private static func liquidFrame(for size: NSSize, within visible: NSRect, anchor: NSRect?) -> NSRect {
        let width = min(size.width, visible.width - screenMargin - rightInset)
        let x = visible.maxX - width - rightInset
        let bottom = visible.minY + screenMargin
        // An anchor outside the visible frame (a hidden or detached item) falls back to the top edge.
        let anchorTop = anchor?.minY ?? visible.maxY
        let top = (anchorTop > bottom + 320 && anchorTop <= visible.maxY + 1 ? anchorTop : visible.maxY) - topGap
        let height = max(min(size.height, top - bottom), 320)
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height.rounded())
    }
}
