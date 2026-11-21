import SwiftUI
import AppKit
import MijiaCore

// MARK: - Classic Tile Sizes

/// `TileSize.small` and `.hero` belong to the liquid-glass theme's 12-column grid. The classic
/// six-column grid only has the 2×1 capsule and the full row, so a size saved by the other theme
/// falls back to its nearest classic shape instead of rendering a broken span. Storage stays
/// shared: the untouched raw value is what the other theme reads back.
func classicTileSize(_ size: TileSize) -> TileSize {
    switch size {
    case .small: return .half
    case .hero: return .full
    default: return size
    }
}

/// The sizes the classic card menu offers: `small` and `hero` are the liquid-glass grid's shapes,
/// so the classic menu keeps the four it always had.
let classicTileSizes: [TileSize] = [.auto, .half, .full, .panel]

// MARK: - Edit Mode (long-press → jiggle, drag to reorder, corner arc handle to resize)

/// Draws an iOS Control Center-style quarter-circle arc hugging the card's bottom-right corner (#115).
/// The visual arc is small and quiet; the enclosing 28pt frame stays the hit area.
struct ClassicCornerArcHandleShape: Shape {
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let radius = max(6, cornerRadius)
        let center = CGPoint(
            x: rect.maxX - inset - radius,
            y: rect.maxY - inset - radius
        )
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        return path
    }
}

/// Wraps one device card. Long-press then keep dragging picks the card up straight away (no
/// second click); while editing a plain drag moves any card. The card follows the pointer via
/// `dragOffset`, jiggles, and shows a bottom-right corner arc handle that supports both drag
/// resizing (`half ↔ full ↔ panel`) and tap cycling (`half → full → panel → half`).
struct ClassicLayoutEditable: ViewModifier {
    @Environment(\.isEditingLayout) private var editing
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let deviceId: String
    let size: TileSize
    let isDragging: Bool
    var isResizing: Bool = false
    let dragOffset: CGSize
    let onCycleSize: () -> Void
    var onBeginResize: () -> Void = {}
    var onResizeDrag: (CGSize) -> Void = { _ in }
    var onEndResize: (CGSize, [TileResizeGestureMath.ResizeSample]) -> Void = { _, _ in }
    /// #145: edit mode shows a pencil badge that opens the shared device rename prompt.
    var onRename: (() -> Void)? = nil

    /// Gesture-scoped state lives here so per-pointermove updates never re-render the whole
    /// panel (#115, QuotaKeeper-style "only the active card needs layout"). The card itself
    /// never transforms during a handle drag — a corner-anchored scale would push the
    /// opposite edges past the panel padding — only the handle leans into the finger.
    @State private var isHandleActive = false
    @State private var resizeSamples: [TileResizeGestureMath.ResizeSample] = []

    // Per-card phase so neighbouring cards do not swing in sync.
    private var phase: Double { Double(abs(deviceId.hashValue % 97)) / 97 * .pi * 2 }

    /// Quiet at rest, confident under the finger.
    private var handleInk: Color {
        if isHandleActive {
            return colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary.opacity(0.8)
        }
        return colorScheme == .dark ? Color.white.opacity(0.55) : Color.primary.opacity(0.45)
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .bottomTrailing) {
            jiggling(content.allowsHitTesting(!editing))
                .scaleEffect(isDragging ? 1.05 : 1)
                .shadowIf(isDragging, color: .black.opacity(0.3), radius: 12, y: 6)

            if editing && !isDragging {
                ClassicCornerArcHandleShape()
                    .stroke(
                        handleInk,
                        style: StrokeStyle(lineWidth: isHandleActive ? 4 : 3, lineCap: .round)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .scaleEffect(isHandleActive ? 1.25 : 1, anchor: .bottomTrailing)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: isHandleActive)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(TileSpace.name))
                            .onChanged { value in
                                isHandleActive = true
                                onBeginResize()
                                onResizeDrag(value.translation)
                                guard !reduceMotion else { return }
                                let now = Date.timeIntervalSinceReferenceDate
                                resizeSamples.append(TileResizeGestureMath.ResizeSample(offset: value.translation, time: now))
                                resizeSamples = resizeSamples.filter { now - $0.time <= 0.12 }
                            }
                            .onEnded { value in
                                isHandleActive = false
                                let samples = resizeSamples
                                resizeSamples = []
                                onEndResize(value.translation, samples)
                            }
                    )
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(L10n.tr("调整卡片大小，当前 \(size.title)", "Resize card, currently \(size.title)")))
                    .accessibilityAction { onCycleSize() }
                    .panelHelp(L10n.tr("拖拽或点击调整卡片大小：\(size.title)", "Drag or click to resize: \(size.title)"))
                    .padding(.bottom, -4)
                    .padding(.trailing, -4)
                    .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if editing, !isDragging, let onRename {
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.72))
                        .frame(width: 22, height: 22)
                        .classicAdaptiveGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("重命名设备", "Rename Device")))
                .accessibilityHint(Text(L10n.tr("打开重命名输入框", "Opens the rename prompt")))
                .panelHelp(L10n.tr("重命名设备（仅在编辑状态显示）", "Rename device (shown while editing)"))
                .padding(6)
                .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .offset(dragOffset)
        .zIndex(isDragging ? 10 : 0)
    }

    private var isJiggling: Bool {
        editing && !reduceMotion && !isDragging && !isResizing
    }

    private func jiggling<V: View>(_ view: V) -> some View {
        view
            .background {
                if isJiggling {
                    ClassicJiggleLayerHost(phase: phase)
                }
            }
            .compositingGroup()
    }
}

private struct ClassicJiggleLayerHost: NSViewRepresentable {
    let phase: Double

    func makeNSView(context: Context) -> ClassicJiggleNSView {
        let view = ClassicJiggleNSView()
        view.update(phase: phase)
        return view
    }

    func updateNSView(_ nsView: ClassicJiggleNSView, context: Context) {
        nsView.update(phase: phase)
    }

    static func dismantleNSView(_ nsView: ClassicJiggleNSView, coordinator: ()) {
        nsView.stopJiggle()
    }
}

private final class ClassicJiggleNSView: NSView {
    private static let animationKey = "classic.layout.jiggle"
    private var isJiggling = true
    private var phase: Double = 0
    private var animatedBoundsSize: CGSize = .zero
    private weak var animatedLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncAnimation()
    }

    override func layout() {
        super.layout()
        syncAnimation()
    }

    func update(phase: Double) {
        let changed = !self.isJiggling || self.phase != phase
        self.isJiggling = true
        self.phase = phase
        if changed {
            if let animatedLayer {
                animatedLayer.removeAnimation(forKey: Self.animationKey)
            }
            syncAnimation()
        }
    }

    func stopJiggle() {
        isJiggling = false
        animatedBoundsSize = .zero
        if let animatedLayer {
            animatedLayer.removeAnimation(forKey: Self.animationKey)
            self.animatedLayer = nil
        }
    }

    private func targetLayer() -> CALayer? {
        superview?.superview?.layer ?? superview?.layer
    }

    private static func rotationTransform(angle: CGFloat, center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DRotate(transform, angle, 0, 0, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        return transform
    }

    private func syncAnimation() {
        guard isJiggling, let target = targetLayer() else {
            if let animatedLayer {
                animatedLayer.removeAnimation(forKey: Self.animationKey)
                self.animatedLayer = nil
            }
            animatedBoundsSize = .zero
            return
        }
        let targetBounds = target.bounds
        guard targetBounds.width > 0, targetBounds.height > 0 else { return }
        if animatedLayer !== target {
            animatedLayer?.removeAnimation(forKey: Self.animationKey)
            animatedLayer = target
            animatedBoundsSize = .zero
        }
        if animatedBoundsSize != targetBounds.size {
            target.removeAnimation(forKey: Self.animationKey)
            animatedBoundsSize = targetBounds.size
        }
        guard target.animation(forKey: Self.animationKey) == nil else { return }
        let angle = CGFloat(1.1 * .pi / 180.0)
        let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        let neg = NSValue(caTransform3D: Self.rotationTransform(angle: -angle, center: center))
        let pos = NSValue(caTransform3D: Self.rotationTransform(angle: angle, center: center))
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [neg, pos, neg]
        animation.keyTimes = [0, 0.5, 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        animation.duration = 1.0 / 3.6
        animation.repeatCount = .infinity
        animation.timeOffset = (phase / (2 * .pi)) * animation.duration
        animation.isRemovedOnCompletion = false
        target.add(animation, forKey: Self.animationKey)
    }
}

// MARK: - Flow Layout

struct ClassicTileSpanKey: LayoutValueKey {
    static let defaultValue = 6
}

/// Packs children left to right into rows of 6 columns using each child's `ClassicTileSpanKey`.
/// Cards in a row share the tallest card's height.
struct ClassicTileFlowLayout: Layout {
    var spacing: CGFloat = 7

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func width(for span: Int, total: CGFloat) -> CGFloat {
        let unit = (total - spacing * 5) / 6
        return unit * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    private func rows(_ subviews: Subviews, total: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var used = 0
        for (i, sub) in subviews.enumerated() {
            let span = min(max(sub[ClassicTileSpanKey.self], 1), 6)
            if used + span > 6, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                used = 0
            }
            let h = sub.sizeThatFits(ProposedViewSize(width: width(for: span, total: total), height: nil)).height
            current.indices.append(i)
            current.height = max(current.height, h)
            used += span
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 330
        let rs = rows(subviews, total: total)
        let height = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, total: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let span = min(max(subviews[i][ClassicTileSpanKey.self], 1), 6)
                let w = width(for: span, total: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}
