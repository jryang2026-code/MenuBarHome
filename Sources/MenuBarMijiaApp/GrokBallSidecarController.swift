import AppKit
import Observation
import SwiftUI
import MijiaCore

/// Screen coordinates keep the ball anchored while the suggestion surface grows around it.
struct GrokBallSidecarPlacement {
    enum Side: CaseIterable, Equatable {
        case left, right, above, below
        fileprivate static let directions: [Self] = [.left, .right, .above, .below]
        var isVertical: Bool { self == .left || self == .right }
        var opposite: Self {
            switch self {
            case .left: return .right
            case .right: return .left
            case .above: return .below
            case .below: return .above
            }
        }
    }

    static let ballDiameter: CGFloat = 72
    static let ballRadius: CGFloat = ballDiameter / 2
    static let outerInset: CGFloat = 6
    static let collapsedWidth: CGFloat = ballDiameter + 2 * outerInset
    static let collapsedRadius: CGFloat = collapsedWidth / 2
    static let expandedWidth: CGFloat = ballDiameter + GrokBallSuggestionMetrics.gapToBall + GrokBallSuggestionMetrics.columnWidth + 2 * outerInset
    static let expandedHeight: CGFloat = GrokBallSuggestionMetrics.columnHeight + 2 * outerInset
    static let gap: CGFloat = 8
    static let topInset: CGFloat = 44
    let side: Side
    let frame: NSRect
    let ballCenter: NSPoint
    let suggestionsFrame: NSRect?
    let suggestionColumns: Int

    var localBallCenter: CGPoint {
        CGPoint(x: ballCenter.x - frame.minX, y: frame.maxY - ballCenter.y)
    }

    var localSuggestionsOrigin: CGPoint {
        guard let suggestionsFrame else { return .zero }
        return CGPoint(x: suggestionsFrame.minX - frame.minX, y: frame.maxY - suggestionsFrame.maxY)
    }

    /// Top-edge reference point on `parent` so adaptive bottom-edge height changes (`280...560` pt)
    /// never shift a placed or dragged ball vertically.
    static func anchorOrigin(for parent: NSRect) -> NSPoint {
        NSPoint(x: parent.midX, y: parent.maxY)
    }

    static func resolve(parent: NSRect, visible: NSRect, expanded: Bool, ballCenter requested: NSPoint? = nil) -> Self {
        let safe = visible.insetBy(dx: gap, dy: gap)
        let initial = requested ?? defaultBallCenter(parent: parent, safe: safe)
        let center = NSPoint(
            x: clamp(initial.x, lower: safe.minX + collapsedRadius, upper: safe.maxX - collapsedRadius),
            y: clamp(initial.y, lower: safe.minY + collapsedRadius, upper: safe.maxY - collapsedRadius)
        )
        let preferred = preferredSide(for: center, relativeTo: parent)
        let ball = NSRect(x: center.x - ballRadius, y: center.y - ballRadius, width: ballDiameter, height: ballDiameter)
        var side = preferred
        var suggestions = suggestionLayout(side: preferred, ball: ball, safe: safe)
        var bestScore = score(suggestions.frame, side: preferred, preferred: preferred, ball: ball, safe: safe, parent: parent)
        for candidate in Side.directions where candidate != preferred {
            let layout = suggestionLayout(side: candidate, ball: ball, safe: safe)
            let candidateScore = score(layout.frame, side: candidate, preferred: preferred, ball: ball, safe: safe, parent: parent)
            if candidateScore < bestScore {
                side = candidate
                suggestions = layout
                bestScore = candidateScore
            }
        }
        let clampedSuggestions = clampSuggestionsToSafeIfDisjoint(suggestions.frame, ball: ball, safe: safe)
        let frame = (expanded ? ball.union(clampedSuggestions) : ball).insetBy(dx: -outerInset, dy: -outerInset)
        return Self(side: side, frame: frame, ballCenter: center,
                    suggestionsFrame: expanded ? clampedSuggestions : nil, suggestionColumns: suggestions.columns)
    }

    private static func defaultBallCenter(parent: NSRect, safe: NSRect) -> NSPoint {
        let rightSpace = safe.maxX - parent.maxX - gap
        let leftSpace = parent.minX - gap - safe.minX
        let topAlignedY = parent.maxY - min(topInset, max(12, parent.height - collapsedWidth)) - collapsedRadius
        if max(rightSpace, leftSpace) >= collapsedWidth {
            let defaultRight = rightSpace >= expandedWidth || (leftSpace < expandedWidth && rightSpace > leftSpace)
            return NSPoint(
                x: defaultRight ? parent.maxX + gap + collapsedRadius : parent.minX - gap - collapsedRadius,
                y: topAlignedY
            )
        }
        let belowSpace = parent.minY - gap - safe.minY
        let aboveSpace = safe.maxY - parent.maxY - gap
        if belowSpace >= aboveSpace {
            return NSPoint(x: parent.midX, y: parent.minY - gap - collapsedRadius)
        }
        return NSPoint(x: parent.midX, y: parent.maxY + gap + collapsedRadius)
    }

    private static func preferredSide(for center: NSPoint, relativeTo parent: NSRect) -> Side {
        let clearances: [(Side, CGFloat)] = [
            (.left, parent.minX - center.x),
            (.right, center.x - parent.maxX),
            (.below, parent.minY - center.y),
            (.above, center.y - parent.maxY),
        ]
        if let outside = clearances.max(by: { $0.1 < $1.1 }), outside.1 > 0 {
            return outside.0
        }
        let dx = (center.x - parent.midX) / max(1, parent.width / 2)
        let dy = (center.y - parent.midY) / max(1, parent.height / 2)
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .below : .above)
    }

    private static func suggestionLayout(side: Side, ball: NSRect, safe: NSRect) -> (frame: NSRect, columns: Int) {
        let metrics = GrokBallSuggestionMetrics.self
        if side.isVertical {
            let x = side == .right ? ball.maxX + metrics.gapToBall
                : ball.minX - metrics.gapToBall - metrics.columnWidth
            let y = clamp(ball.maxY - metrics.columnHeight,
                          lower: safe.minY + outerInset, upper: safe.maxY - metrics.columnHeight - outerInset)
            return (NSRect(x: x, y: y, width: metrics.columnWidth, height: metrics.columnHeight), 1)
        }
        let available = side == .above
            ? safe.maxY - outerInset - ball.maxY - metrics.gapToBall
            : ball.minY - metrics.gapToBall - safe.minY - outerInset
        let columns = available < metrics.rowHeight && safe.width >= metrics.singleRowWidth + 2 * outerInset ? 4 : 2
        let width = columns == 4 ? metrics.singleRowWidth : metrics.rowWidth
        let height = columns == 4 ? metrics.pillHeight : metrics.rowHeight
        let x = clamp(ball.midX - width / 2, lower: safe.minX + outerInset, upper: safe.maxX - width - outerInset)
        let y = side == .above ? ball.maxY + metrics.gapToBall : ball.minY - metrics.gapToBall - height
        return (NSRect(x: x, y: y, width: width, height: height), columns)
    }

    private static func clampSuggestionsToSafeIfDisjoint(_ rect: NSRect, ball: NSRect, safe: NSRect) -> NSRect {
        let bounds = safe.insetBy(dx: outerInset, dy: outerInset)
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        let clamped = NSRect(
            x: clamp(rect.minX, lower: bounds.minX, upper: bounds.maxX - rect.width),
            y: clamp(rect.minY, lower: bounds.minY, upper: bounds.maxY - rect.height),
            width: min(rect.width, bounds.width),
            height: min(rect.height, bounds.height)
        )
        return clamped.intersects(ball.insetBy(dx: -2, dy: -2)) ? rect : clamped
    }

    private static func score(
        _ rect: NSRect,
        side: Side,
        preferred: Side,
        ball: NSRect,
        safe: NSRect,
        parent: NSRect
    ) -> (CGFloat, CGFloat, Int, CGFloat) {
        let footprint = rect.insetBy(dx: -outerInset, dy: -outerInset)
        let clipped = max(0, area(footprint) - area(footprint.intersection(safe)))
        let overlap = area(rect.intersection(parent)) + area(rect.intersection(ball))
        let preferenceRank = side == preferred ? 0 : (side == preferred.opposite ? 1 : 2)
        let alignmentDrift = side.isVertical ? abs(rect.maxY - ball.maxY) : abs(rect.midX - ball.midX)
        return (clipped, overlap, preferenceRank, alignmentDrift)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat { min(max(value, lower), max(lower, upper)) }
}

@Observable
@MainActor
final class GrokBallSidecarState {
    var placement: GrokBallSidecarPlacement?
    var isVisible = false
    let pointer = GrokBallPointerState()
}

/// Owns placement and mouse arbitration; the SwiftUI button retains keyboard/accessibility actions.
@MainActor
final class GrokBallSidecarController {
    let panelWindow: NSPanel
    private let store: HomeStore
    private weak var parent: NSPanel?
    private let state = GrokBallSidecarState()
    private let beginVoice: () -> Void
    private let endVoice: () -> Void
    private var pointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var holdTask: Task<Void, Never>?
    private var ballOffset: NSPoint?
    private var isTornDown = false
    private(set) var isPresentationSuspended = false
    private enum Gesture {
        case pressed(origin: NSPoint, center: NSPoint)
        case dragging(origin: NSPoint, center: NSPoint)
        case voice
    }
    private var gesture: Gesture?

    init(store: HomeStore, parent: NSPanel, beginVoice: @escaping () -> Void,
         endVoice: @escaping () -> Void, closePanel: @escaping () -> Void) {
        self.store = store
        self.parent = parent
        self.beginVoice = beginVoice
        self.endVoice = endVoice
        let initialSide = GrokBallSidecarPlacement.collapsedWidth
        let panel = GrokBallSidecarPanel(contentRect: NSRect(x: 0, y: 0, width: initialSide, height: initialSide),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        panelWindow = panel
        panel.isFloatingPanel = true
        panel.level = parent.level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(rootView: GrokBallSidecarView(store: store, state: state))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onCancel = { [weak store] in
            if let store, store.isGrokBallStageExpanded { store.dismissGrokBallStage() }
            else { closePanel() }
        }
        parent.acceptsMouseMovedEvents = true
        observePresentation()
    }

    /// The parent slides as one rigid surface; place the ball only once that surface settles.
    func setPresentationSuspended(_ suspended: Bool) {
        isPresentationSuspended = suspended
        if suspended { hide() } else { synchronize() }
    }

    func synchronize() {
        guard !isTornDown, !isPresentationSuspended, let parent else { return }
        panelWindow.appearance = parent.appearance
        panelWindow.alphaValue = parent.alphaValue
        guard parent.isVisible, !store.showsFullOnboardingGuide, store.enableGrokBall else { hide(); return }
        let anchor = GrokBallSidecarPlacement.anchorOrigin(for: parent.frame)
        let requested = ballOffset.map { NSPoint(x: anchor.x + $0.x, y: anchor.y + $0.y) }
        let visible = screen(at: requested)?.visibleFrame ?? parent.screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let placement = GrokBallSidecarPlacement.resolve(parent: parent.frame, visible: visible,
                                                        expanded: store.isGrokBallStageExpanded, ballCenter: requested)
        state.placement = placement
        if panelWindow.frame != placement.frame {
            panelWindow.setFrame(placement.frame, display: true)
        }
        if panelWindow.parent !== parent { parent.addChildWindow(panelWindow, ordered: .above) }
        state.isVisible = true
        panelWindow.orderFront(nil)
        installPointerMonitor()
        updatePointer(at: NSEvent.mouseLocation)
    }

    func hide() {
        cancelGesture()
        state.isVisible = false
        state.pointer.position = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        pointerMonitor = nil
        globalPointerMonitor = nil
        parent?.removeChildWindow(panelWindow)
        panelWindow.orderOut(nil)
    }

    func tearDown() {
        isTornDown = true
        hide()
        parent?.removeChildWindow(panelWindow)
        panelWindow.contentView = nil
        parent = nil
    }

    private func screen(at point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func observePresentation() {
        guard !isTornDown else { return }
        withObservationTracking {
            _ = store.isGrokBallStageExpanded
            _ = store.showsFullOnboardingGuide
            _ = store.enableGrokBall
            _ = store.enableVoiceInput
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else { return }
                if !self.store.enableVoiceInput {
                    self.holdTask?.cancel()
                    self.holdTask = nil
                    if case .voice = self.gesture {
                        self.cancelGesture()
                    }
                }
                self.synchronize()
                self.observePresentation()
            }
        }
    }

    private func installPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if self.handlePointer(event, at: point) { return true }
                self.updatePointer(at: point)
                return false
            }
            return consumed ? nil : event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if event.type == .leftMouseUp {
                    _ = self.handlePointer(event, at: point)
                }
                self.updatePointer(at: point)
            }
        }
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard state.isVisible, let placement = state.placement else { return false }
        let radius = GrokBallSidecarPlacement.collapsedRadius
        let side = GrokBallSidecarPlacement.collapsedWidth
        let inset = GrokBallSidecarPlacement.outerInset
        let ballRect = NSRect(x: placement.ballCenter.x - radius, y: placement.ballCenter.y - radius, width: side, height: side)
        if ballRect.contains(point) { return true }
        if let suggestions = placement.suggestionsFrame?.insetBy(dx: -inset, dy: -inset), suggestions.contains(point) {
            return true
        }
        return false
    }

    private func handlePointer(_ event: NSEvent, at point: NSPoint) -> Bool {
        switch event.type {
        case .leftMouseDown:
            let hitRadius = GrokBallSidecarPlacement.collapsedRadius
            guard event.window === panelWindow, let placement = state.placement,
                  abs(point.x - placement.ballCenter.x) <= hitRadius, abs(point.y - placement.ballCenter.y) <= hitRadius else { return false }
            gesture = .pressed(origin: point, center: placement.ballCenter)
            if panelWindow.alphaValue > 0 {
                panelWindow.makeKey()
            }
            holdTask?.cancel()
            if store.enableVoiceInput {
                holdTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, self.store.enableVoiceInput, case .pressed = self.gesture else { return }
                    self.gesture = .voice
                    self.store.dismissGrokBallStage()
                    self.beginVoice()
                }
            } else {
                holdTask = nil
            }
            return true
        case .leftMouseDragged:
            guard let gesture else { return false }
            switch gesture {
            case let .pressed(origin, center):
                guard hypot(point.x - origin.x, point.y - origin.y) >= 6 else { return true }
                holdTask?.cancel()
                self.gesture = .dragging(origin: origin, center: center)
                store.dismissGrokBallStage()
                moveBall(to: NSPoint(x: center.x + point.x - origin.x, y: center.y + point.y - origin.y))
            case let .dragging(origin, center):
                moveBall(to: NSPoint(x: center.x + point.x - origin.x, y: center.y + point.y - origin.y))
            case .voice: break
            }
            return true
        case .leftMouseUp:
            guard let gesture else { return false }
            holdTask?.cancel()
            holdTask = nil
            self.gesture = nil
            switch gesture {
            case .pressed: store.toggleGrokBallStage(); synchronize()
            case .dragging: break
            case .voice: endVoice()
            }
            return true
        default: return false
        }
    }

    private func moveBall(to point: NSPoint) {
        guard let parent else { return }
        let anchor = GrokBallSidecarPlacement.anchorOrigin(for: parent.frame)
        ballOffset = NSPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        synchronize()
        if let actual = state.placement?.ballCenter {
            let refreshedAnchor = GrokBallSidecarPlacement.anchorOrigin(for: parent.frame)
            ballOffset = NSPoint(x: actual.x - refreshedAnchor.x, y: actual.y - refreshedAnchor.y)
        }
    }

    private func cancelGesture() {
        holdTask?.cancel()
        holdTask = nil
        if case .voice = gesture { SpeechInputController.shared.stop(andSubmit: false, store: store) }
        gesture = nil
    }

    private func updatePointer(at point: NSPoint) {
        guard state.isVisible, let parent else { return }
        if parent.frame.contains(point) || panelWindow.frame.contains(point) {
            let windowPoint = panelWindow.convertPoint(fromScreen: point)
            state.pointer.position = panelWindow.contentView?.convert(windowPoint, from: nil)
        } else if state.pointer.position != nil {
            state.pointer.position = nil
        }
    }
}

private final class GrokBallSidecarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct GrokBallSidecarView: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    let store: HomeStore
    let state: GrokBallSidecarState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let placement = state.placement {
                GrokBallControl(store: store, pointer: state.pointer, center: placement.localBallCenter, isVisible: state.isVisible)
                    .frame(width: GrokBallSidecarPlacement.ballDiameter, height: GrokBallSidecarPlacement.ballDiameter)
                    .position(placement.localBallCenter)
                if let suggestions = placement.suggestionsFrame {
                    GrokBallSuggestions(store: store, columnCount: placement.suggestionColumns)
                        .frame(width: suggestions.width, height: suggestions.height, alignment: .topLeading)
                        .position(x: placement.localSuggestionsOrigin.x + suggestions.width / 2,
                                  y: placement.localSuggestionsOrigin.y + suggestions.height / 2)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .accessibilityElement(children: .contain)
    }
}
