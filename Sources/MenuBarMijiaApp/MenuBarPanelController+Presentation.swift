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
        let theme = currentPanelTheme
        let panel = ensurePanelWindow(theme: theme)
        prepareSidecar(for: panel)
        panel.appearance = Self.preferredAppearance(from: userDefaults)
        panelHostingVisibility.setVisible(true)
        refreshPanelContent(theme: theme)
        syncPanelRootVisibility()

        let wasVisible = panel.isVisible && !isClosing
        let wasOnScreen = panel.isVisible
        if theme == .liquidGlass, !wasVisible, let hosting = panel.contentView {
            panelAdaptiveHeightProbe.resetNotificationBaseline()
            if !wasOnScreen {
                hosting.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: Self.pilotPanelWidth,
                    height: Self.pilotMaxHeight
                )
            }
            hosting.layoutSubtreeIfNeeded()
        }

        let target = columnFrame(for: theme)
        isClosing = false
        isEntranceAnimating = false
        hasPendingGeometryPass = false
        clearImplicitDismissalStateOnShow()
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
        updateLabelTimer()
        if theme == .classic {
            // A Liquid Glass session suspends the ball while its column slides; resuming also
            // repositions it, which is the `synchronize()` the classic panel used to do.
            grokBallSidecar?.setPresentationSuspended(false)
        } else {
            grokBallSidecar?.synchronize()
        }
        // Re-showing an already visible panel (hotkey while open, URL scheme, intent) must not replay
        // the entrance animation.
        guard !wasVisible else {
            if theme == .liquidGlass {
                applySerialPanelGeometry()
            }
            return
        }
        store.setPanelVisible(true)
        NotificationCenter.default.post(name: Self.didShowNotification, object: panel)
        if presentsActively, theme == .liquidGlass {
            // Finish initial glass layout before starting the motion clock, avoiding a skipped first half.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            backdropWindow?.displayIfNeeded()
            CATransaction.flush()
            isEntranceAnimating = true
            fadePanel(to: 1, duration: Self.fadeInDuration) { [weak self] in
                guard let self else { return }
                if generation == self.presentationGeneration {
                    self.isEntranceAnimating = false
                }
                guard generation == self.presentationGeneration, !self.isClosing else { return }
                self.grokBallSidecar?.setPresentationSuspended(false)
                self.applySerialPanelGeometry()
            }
        } else if theme == .liquidGlass {
            grokBallSidecar?.setPresentationSuspended(false)
            applySerialPanelGeometry()
        }
    }

    /// `animated` is false for a theme switch, which closes the panel in place before the hosting
    /// tree is rebuilt for the other theme.
    func hidePanel(animated: Bool = true) {
        guard let panel = panelWindow, panel.isVisible, !isClosing else { return }
        isEntranceAnimating = false
        hasPendingGeometryPass = false
        clearResignActiveSuppressionOnHide()
        // #146 §5.2：点面板外、⌘Tab、打开设置、Esc 阶梯都会走到这里，排序会话不能比面板活得久。
        // 必须在这里提交草稿，而不是依赖视图的 `onDisappear`——拖动中 `DragGesture.onEnded` 不保证执行。
        LayoutUIState.shared.commitRoomOrderIfNeeded()
        PanelTransientUIState.shared.resetOnPanelHide(store: store)
        if hostedPanelTheme == .classic {
            grokBallSidecar?.hide()
        } else {
            grokBallSidecar?.setPresentationSuspended(true)
        }
        store?.dismissGrokBallStage()
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
                self.finishOrderingPanelOut(panel)
            }
        } else {
            isClosing = false
            panel.ignoresMouseEvents = false
            hideBackdropShadow()
            finishOrderingPanelOut(panel)
        }
        restoreStatusItemHighlight()
        updateLabelTimer()
        // The SwiftUI tree stays alive, exactly like a `.window`-style `MenuBarExtra`: scroll
        // position, the search field text and layout-editing state survive a close/reopen. A theme
        // switch drops it explicitly so the next open builds the other root view.
        NotificationCenter.default.post(name: Self.didHideNotification, object: panel)
    }

    /// Tears down hidden-panel animations, clocks, and any active text-field caret in one
    /// synchronous layout pass right before `orderOut` disconnects the window from display cycles.
    private func finishOrderingPanelOut(_ panel: NSPanel) {
        PanelConnectionDetailState.shared.dismiss(restoreFocus: false)
        PanelConnectionDetailState.shared.clearStatusControlFocus()
        if panel.firstResponder !== panel.contentView {
            _ = panel.makeFirstResponder(panel.contentView)
        }
        panelHostingVisibility.setVisible(false)
        syncPanelRootVisibility()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderOut(nil)
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
    /// under the item and clamped to the item's screen. No-op for the Liquid Glass pilot column,
    /// whose geometry is serially managed by `applySerialPanelGeometry()`.
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

    private var currentPanelTheme: PanelTheme {
        PanelTheme.resolved(from: userDefaults.string(forKey: PanelTheme.storageKey))
    }

    func handleScreenParametersChanged() {
        guard let panel = panelWindow, isPanelVisible else { return }
        switch hostedPanelTheme ?? currentPanelTheme {
        case .classic:
            let target = Self.frame(for: panel.frame.size, anchor: statusAnchor, screen: statusScreen, theme: .classic)
            if panel.frame != target {
                panel.setFrame(target, display: true)
            }
            grokBallSidecar?.synchronize()
        case .liquidGlass:
            scheduleAdaptiveGeometryPass()
        }
    }

    func handlePreferencesChanged() {
        preferencesReloadCount &+= 1
        lastSeenPreferences = WatchedPreferences(from: userDefaults)
        syncStatusItem()
        panelWindow?.appearance = Self.preferredAppearance(from: userDefaults)
        grokBallSidecarWindow?.appearance = Self.preferredAppearance(from: userDefaults)
        let theme = currentPanelTheme
        if let built = hostedPanelTheme, built != theme {
            // A theme switch only takes effect on the next open: close the panel in place, drop the
            // hosting tree, and let the next `showPanel` build the other root view. Bumping the
            // generation invalidates any in-flight show/close completion.
            presentationGeneration &+= 1
            isClosing = false
            isEntranceAnimating = false
            hasPendingGeometryPass = false
            if panelWindow?.isVisible == true {
                hidePanel(animated: false)
            }
            dropPanelContent()
            updateLabelTimer()
            return
        }
        guard isPanelVisible else { return }
        switch theme {
        case .classic:
            // Height or skin changed in Settings while the panel is open: apply it right away.
            updatePanelSize(
                width: Self.panelWidth,
                height: Self.preferredContentSize(screen: statusScreen, theme: .classic, defaults: userDefaults).height
            )
        case .liquidGlass:
            scheduleAdaptiveGeometryPass()
        }
    }

    /// The window target for the theme currently on screen.
    private func columnFrame(for theme: PanelTheme) -> NSRect {
        let adaptiveHeight: CGFloat?
        if theme == .liquidGlass {
            let measured = panelAdaptiveHeightProbe.resolvedContentHeight
            adaptiveHeight = measured > 0 ? measured : nil
        } else {
            adaptiveHeight = nil
        }
        return Self.frame(
            for: Self.preferredContentSize(
                screen: statusScreen,
                theme: theme,
                defaults: userDefaults,
                adaptiveContentHeight: adaptiveHeight
            ),
            anchor: statusAnchor,
            screen: statusScreen,
            theme: theme
        )
    }

    /// Queues or executes a serial adaptive geometry pass while the panel is open.
    /// Defers mid-slide updates until the entrance transition finishes, and ignores hidden/closing panels.
    func scheduleAdaptiveGeometryPass() {
        guard isPanelVisible, hostedPanelTheme == .liquidGlass else { return }
        if isEntranceAnimating {
            hasPendingGeometryPass = true
            return
        }
        // The probe notifies from inside SwiftUI's layout/`onChange` cycle and `didChangeScreen` arrives
        // mid-transaction; resizing right there re-enters AppKit's display pass and `onDisappear`.
        // Coalesce every request from this runloop turn into one pass on the next turn.
        guard !isGeometryPassScheduled else {
            hasPendingGeometryPass = true
            return
        }
        isGeometryPassScheduled = true
        // A runloop block, not `Task { @MainActor }`: the pass must land after the current AppKit
        // layout/display turn, and it has to run inside the runloop pumps the panel tests drive.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isGeometryPassScheduled = false
                guard self.isPanelVisible, !self.isClosing else { return }
                if self.isEntranceAnimating {
                    self.hasPendingGeometryPass = true
                    return
                }
                self.applySerialPanelGeometry()
            }
        }
    }

    /// Serially applies size measurement, screen clamping, backdrop shadow, and GrokBall synchronization
    /// so room switches, drawer toggles, and display changes never re-enter competitively or jitter.
    /// Only call this from outside a SwiftUI update; scheduled paths go through
    /// `scheduleAdaptiveGeometryPass()`, which hops to the next runloop turn first.
    func applySerialPanelGeometry() {
        guard !isApplyingPanelGeometry else {
            hasPendingGeometryPass = true
            return
        }
        isApplyingPanelGeometry = true
        defer { isApplyingPanelGeometry = false }

        var iterations = 0
        repeat {
            hasPendingGeometryPass = false
            iterations &+= 1
            guard isPanelVisible,
                  let panel = panelWindow,
                  grokBallSidecar?.isPresentationSuspended != true else { break }
            let theme = hostedPanelTheme ?? currentPanelTheme
            let target = columnFrame(for: theme)
            if panel.frame != target {
                serialGeometryApplyCount &+= 1
                panel.setFrame(target, display: true)
            }
            if presentsActively, theme == .liquidGlass {
                presentBackdropShadow(around: target, under: panel)
            }
            grokBallSidecar?.synchronize()
        } while hasPendingGeometryPass && iterations < 4
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
    static func preferredAppearance(from defaults: UserDefaults = .standard) -> NSAppearance? {
        let raw = defaults.string(forKey: AppAppearance.storageKey)
        return (raw.flatMap(AppAppearance.init(rawValue:)) ?? .system).nsAppearance
    }

    /// Clamps pilot content height into `[280, 560]` pt, bounded by the screen's usable height.
    static func clampAdaptiveHeight(_ rawHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let cap = min(pilotMaxHeight, max(0, availableHeight))
        let floor = min(pilotMinHeight, cap)
        return min(max(ceil(rawHeight), floor), cap)
    }

    /// Width and height per theme: Classic keeps 376 pt and `PanelHeight`; Liquid Glass pilot uses
    /// 380 pt width and adaptive 280–560 pt height bounded by `visibleFrame`.
    static func preferredContentSize(
        screen: NSScreen?,
        theme: PanelTheme,
        defaults: UserDefaults = .standard,
        adaptiveContentHeight: CGFloat? = nil
    ) -> NSSize {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        switch theme {
        case .classic:
            let raw = defaults.string(forKey: PanelHeight.storageKey)
            let height = (raw.flatMap(PanelHeight.init(rawValue:)) ?? .standard).points
            return NSSize(width: panelWidth, height: min(height, available - 24))
        case .liquidGlass:
            let usable = max(0, available - topGap - screenMargin)
            let requested = adaptiveContentHeight ?? pilotMaxHeight
            return NSSize(
                width: pilotPanelWidth,
                height: clampAdaptiveHeight(requested, availableHeight: usable)
            )
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

    /// Right-aligns the 380 pt adaptive pilot column on the status item's screen, anchored below
    /// the menu bar and clamped into `[280, 560]` pt within `visibleFrame`.
    static func liquidFrame(for size: NSSize, within visible: NSRect, anchor: NSRect?) -> NSRect {
        let maxUsableWidth = max(1, visible.width - screenMargin - rightInset)
        let width = min(size.width, maxUsableWidth)
        let x = max(visible.minX + screenMargin, visible.maxX - width - rightInset)
        let bottom = visible.minY + screenMargin
        // An anchor outside the visible frame (a hidden or detached item) falls back to the top edge.
        let anchorTop = anchor?.minY ?? visible.maxY
        let minTopClearance = min(pilotMinHeight, max(0, visible.height - topGap - screenMargin))
        let top = (anchorTop >= bottom + minTopClearance && anchorTop <= visible.maxY + 1 ? anchorTop : visible.maxY) - topGap
        let height = clampAdaptiveHeight(size.height, availableHeight: max(0, top - bottom))
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }

    static func makeBackdropWindow(frame: NSRect) -> NSPanel {
        let w = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.level = .statusBar
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: ControlCenterReadabilityBackdrop())
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        w.contentView = hosting
        return w
    }
}

/// Borderless panels are not key windows by default; the control center needs key status for arrow
/// keys, Esc, ⌘, and its text fields, as the `MenuBarExtra` window had.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Observable bridge feeding `\.isPanelVisible` into the kept-alive SwiftUI root without
/// recreating `NSHostingView.rootView` across close/reopen cycles.
@Observable
@MainActor
final class PanelHostingVisibility {
    private(set) var isVisible = false

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

/// Hosting view subclass that counts `layout()` passes — the exact hook `ViewGraph` drives on each
/// display-cycle update — so tests can verify the hidden tree goes completely quiescent.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutPassCount = 0

    override func layout() {
        layoutPassCount &+= 1
        super.layout()
    }

    func resetLayoutPassCount() {
        layoutPassCount = 0
    }
}

/// A soft, panel-local shadow maintains text readability over light and dark wallpaper.
private struct ControlCenterReadabilityBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel + 6, style: .continuous)
            .fill(Color.black.opacity(colorScheme == .dark ? 0.38 : 0.30))
            .padding(MenuBarPanelController.backdropBleed)
            .blur(radius: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
