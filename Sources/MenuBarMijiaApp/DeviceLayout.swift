import SwiftUI
import AppKit
import MijiaCore

/// Per-device card size picked from the card's context menu.
public enum TileSize: String, CaseIterable, Identifiable, Sendable {
    case auto, small, half, hero, full, panel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return L10n.tr("自动", "Auto")
        case .small: return L10n.tr("圆钮 (1×1)", "Round (1×1)")
        case .half: return L10n.tr("胶囊 (2×1)", "Capsule (2×1)")
        case .hero: return L10n.tr("方砖 (2×2)", "Square (2×2)")
        case .full: return L10n.tr("整行 (4×1)", "Full Row (4×1)")
        case .panel: return L10n.tr("常驻展开", "Always Expanded")
        }
    }

    public var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .small: return "circle.grid.2x2"
        case .half: return "rectangle.split.2x1"
        case .hero: return "square.grid.2x2"
        case .full: return "rectangle"
        case .panel: return "rectangle.expand.vertical"
        }
    }
}

/// Pure threshold resolver for the bottom-right corner arc resize gesture (#115).
/// Mirrors `targetSize` in `windows/src/ui/panelPrefs.ts` on purpose (shared contract).
public enum TileResizeGestureMath {
    public static let stepThreshold: CGFloat = 30

    private static let orderedSizes: [TileSize] = [.half, .full, .panel]

    public static func targetSize(
        startSize: TileSize,
        translation: CGSize,
        isCompactGrid: Bool = true
    ) -> TileSize {
        let resolvedStart: TileSize = startSize == .auto
            ? (isCompactGrid ? .half : .full)
            : startSize
        // A 1×1 round button resizes from the capsule step; a 2×2 hero from the full-row step.
        let gestureStart: TileSize = switch resolvedStart {
        case .small: .half
        case .hero: .full
        default: resolvedStart
        }
        guard let startIndex = orderedSizes.firstIndex(of: gestureStart) else {
            return resolvedStart
        }
        let stepDelta = axisSteps(for: translation.width) + axisSteps(for: translation.height)
        let targetIndex = min(max(startIndex + stepDelta, 0), orderedSizes.count - 1)
        return orderedSizes[targetIndex]
    }

    private static func axisSteps(for delta: CGFloat) -> Int {
        if delta > stepThreshold * 2 { return 2 }
        if delta > stepThreshold { return 1 }
        if delta < -stepThreshold * 2 { return -2 }
        if delta < -stepThreshold { return -1 }
        return 0
    }

    // MARK: Flick inertia (QuotaKeeper-style release velocity)

    /// One pointer position sample taken during a handle drag.
    public struct ResizeSample: Equatable, Sendable {
        public var offset: CGSize
        public var time: TimeInterval
        public init(offset: CGSize, time: TimeInterval) {
            self.offset = offset
            self.time = time
        }
    }

    /// Pointer velocity in pt/s from the last 100 ms of samples; zero when the pointer rested.
    public static func releaseVelocity(_ samples: [ResizeSample], now: TimeInterval) -> CGSize {
        let recent = samples.filter { now - $0.time <= 0.1 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return .zero }
        let elapsed = last.time - first.time
        guard elapsed >= 0.008, now - last.time <= 0.06 else { return .zero }
        return CGSize(
            width: (last.offset.width - first.offset.width) / elapsed,
            height: (last.offset.height - first.offset.height) / elapsed
        )
    }

    /// Flick projection (rate 0.99, as in iOS deceleration): a release flick lands at most one step.
    public static func projectedOffset(velocity: CGSize, threshold: CGFloat = stepThreshold) -> CGSize {
        func project(_ v: CGFloat) -> CGFloat { max(-threshold, min(threshold, v * 0.099)) }
        return CGSize(width: project(velocity.width), height: project(velocity.height))
    }
}

/// Stores `[deviceId: TileSize]` as JSON under one defaults key so views can observe it with `@AppStorage`.
public enum DeviceLayoutPrefs {
    public static let storageKey = ViewPreferenceKeys.tileSizes

    public static func decode(_ raw: String) -> [String: TileSize] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict.compactMapValues(TileSize.init(rawValue:))
    }

    public static func encode(_ sizes: [String: TileSize]) -> String {
        // A page-scoped "auto" is kept: it overrides a non-auto default set for every page.
        let dict = sizes.filter { $0.value != .auto || $0.key.contains("|") }.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Memoised decode: cards read their size on every render, the JSON only changes on edits.
    @MainActor private static var cache: (raw: String, sizes: [String: TileSize]) = ("", [:])

    /// Size for a device on one page (`scope` = room id or "all"); falls back to the all-pages default.
    @MainActor
    public static func cachedSize(raw: String, id: String, scope: String) -> TileSize {
        if cache.raw != raw { cache = (raw, decode(raw)) }
        return lookup(cache.sizes, id: id, scope: scope)
    }

    public static func lookup(_ sizes: [String: TileSize], id: String, scope: String) -> TileSize {
        if let exact = sizes[scopedKey(id: id, scope: scope)] {
            return exact
        }
        if let slash = scope.firstIndex(of: "/") {
            let rawRoomId = String(scope[scope.index(after: slash)...])
            if let legacyRoomScoped = sizes[scopedKey(id: id, scope: rawRoomId)] {
                return legacyRoomScoped
            }
        }
        return sizes[id] ?? .auto
    }

    public static func scopedKey(id: String, scope: String) -> String { "\(scope)|\(id)" }

    /// Resolves `.auto` into a concrete size for the current grid mode and climate setting.
    public static func resolved(_ size: TileSize, device: SmartDevice, compactGrid: Bool, climatePanel: Bool) -> TileSize {
        guard size == .auto else { return size }
        if case .climate = device.kind, climatePanel { return .full }
        return compactGrid ? .half : .full
    }
}

// MARK: - Custom Order

extension DeviceLayoutPrefs {
    public static let orderKey = ViewPreferenceKeys.customOrder

    public static func decodeOrder(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    public static func encodeOrder(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Sorts by the saved order; devices not in it keep their incoming order after the known ones.
    public static func apply(order: [String], to devices: [SmartDevice]) -> [SmartDevice] {
        guard !order.isEmpty else { return devices }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return devices.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? (order.count + a.offset)
            let rb = rank[b.element.id] ?? (order.count + b.offset)
            return ra < rb
        }.map(\.element)
    }
}

// MARK: - Edit Mode (menu → still cards, drag to reorder, corner arc handle to resize)

private struct LayoutEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var isEditingLayout: Bool {
        get { self[LayoutEditingKey.self] }
        set { self[LayoutEditingKey.self] = newValue }
    }
}

/// The arc macOS Control Center draws on the hovered module's bottom-right corner while editing.
/// Concentric with the card's own corner (`distance == 0` rides directly on the card's outer edge),
/// spanning 49° (`20.5° → 69.5°`) centred on the 45° diagonal. `cornerRadius == nil` means a
/// capsule, whose corner radius is half the shorter side. Drawn in the card's bounds.
struct CornerArcHandleShape: Shape {
    var cornerRadius: CGFloat?
    /// Distance from the card edge to the stroke's centre line (0 pt rides on the card's outer arc).
    var distance: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let corner = resolvedCorner(in: rect.size)
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.maxX - corner, y: rect.maxY - corner),
            radius: corner + distance,
            startAngle: .degrees(20.5),
            endAngle: .degrees(69.5),
            clockwise: false
        )
        return path
    }

    func resolvedCorner(in size: CGSize) -> CGFloat {
        let capsule = min(size.width, size.height) / 2
        return min(cornerRadius ?? capsule, capsule)
    }
}

/// The visible resize grabber: pure white 4.75 pt round-capped arc with a faint 5 % black shadow.
private struct CornerArcHandle: View {
    let cornerRadius: CGFloat?
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let corner = CornerArcHandleShape(cornerRadius: cornerRadius).resolvedCorner(in: geo.size)
            CornerArcHandleShape(cornerRadius: cornerRadius)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 4.75, lineCap: .round)
                )
                .shadow(color: .black.opacity(0.05), radius: 1.2)
                .scaleEffect(
                    isActive ? 1.12 : 1,
                    anchor: UnitPoint(
                        x: geo.size.width > 0 ? (geo.size.width - corner) / geo.size.width : 1,
                        y: geo.size.height > 0 ? (geo.size.height - corner) / geo.size.height : 1
                    )
                )
        }
        .allowsHitTesting(false)
    }
}

/// 完成 in the edit toolbar: a glass capsule that rises 2 % under the pointer. Return finishes too.
struct LayoutEditDoneButton: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(L10n.tr("完成", "Done"))
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : AppleMotion.control, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityHint(Text(L10n.tr("结束布局编辑", "Finish editing the layout")))
    }
}

/// Wraps one device card. While editing (entered from the `⋯` menu or a card's context menu,
/// never a long press) cards stay at scale 1.0 without jiggling; the hovered card shows the
/// bottom-right corner arc grabber, which drags or taps between sizes (`1×1 ↔ 2×1 ↔ 2×2 ↔ 4×1`).
/// A plain drag anywhere on a card reorders it with a subtle shadow while neighbours reflow along
/// a critically damped 0.50 s spring. A 20 pt dark frosted `−` badge on the top-left removes the
/// card from 常用 (and hides across all cards while a drag is in flight).
struct LayoutEditable: ViewModifier {
    @Environment(\.isEditingLayout) private var editing
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let deviceId: String
    let size: TileSize
    let isDragging: Bool
    var isAnyCardDragging: Bool = false
    var isResizing: Bool = false
    let dragOffset: CGSize
    let onCycleSize: () -> Void
    var onBeginResize: () -> Void = {}
    var onResizeDrag: (CGSize) -> Void = { _ in }
    var onEndResize: (CGSize, [TileResizeGestureMath.ResizeSample]) -> Void = { _, _ in }
    /// Only cards in 常用 are edited here; `nil` hides the `−` badge for the rest.
    var onRemove: (() -> Void)? = nil

    /// Gesture-scoped state lives here so per-pointermove updates never re-render the whole
    /// panel (#115, QuotaKeeper-style "only the active card needs layout").
    @State private var isHandleActive = false
    @State private var resizeSamples: [TileResizeGestureMath.ResizeSample] = []
    @State private var isCardHovered = false
    @State private var isHandleHovered = false

    /// 1×1 and 2×1 cards are capsules; 2×2 and full rows use the module radius.
    private var arcCornerRadius: CGFloat? {
        (size == .half || size == .small) ? nil : DesignTokens.Radius.module
    }

    private var showsChrome: Bool {
        editing && !isDragging && !isAnyCardDragging
            && (isCardHovered || isHandleHovered || isResizing || isHandleActive)
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .bottomTrailing) {
            content.allowsHitTesting(!editing)
                .shadow(
                    color: .black.opacity(isDragging ? 0.30 : 0),
                    radius: isDragging ? 14 : 0,
                    y: isDragging ? 6 : 0
                )
                .animation(reduceMotion ? nil : AppleMotion.snappySpring, value: isDragging)

            if editing && !isDragging && !isAnyCardDragging {
                resizeHandle
            }
        }
        .contentShape(Rectangle())
        .onHover { isCardHovered = $0 }
        .overlay(alignment: .topLeading) {
            if editing, !isDragging, !isAnyCardDragging, let onRemove {
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.78)) : AnyShapeStyle(.ultraThinMaterial))
                        Circle()
                            .fill(Color.black.opacity(reduceTransparency ? 0.20 : 0.48))
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.90))
                            .frame(width: 9, height: 1.75)
                    }
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -2, y: -2)
                .accessibilityLabel(Text(L10n.tr("从常用移除", "Remove from Favorites")))
                .panelHelp(L10n.tr("从常用移除（设备仍在下方的房间里）", "Remove from Favorites (the device stays in its room below)"))
                .transition(.opacity)
            }
        }
        .overlay {
            if showsChrome {
                CornerArcHandle(cornerRadius: arcCornerRadius, isActive: isHandleActive || isResizing)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : AppleMotion.control, value: showsChrome)
        .animation(reduceMotion ? nil : AppleMotion.control, value: isAnyCardDragging)
        .offset(dragOffset)
        .zIndex(isDragging ? 10 : 0)
        .onChange(of: editing) { _, _ in
            isCardHovered = false
            isHandleHovered = false
        }
    }

    /// The 28 pt hit area at the card's bottom-right corner. It stays mounted (and invisible) for
    /// every card while editing; the arc only draws once the pointer is over the card.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onHover { isHandleHovered = $0 }
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
    }
}

enum TileSpace {
    static let name = "device_tiles"
}

/// Live state of one corner-handle resize gesture (#115): the size the drag started from and
/// whether a step already fired. Velocity samples live in `LayoutEditable`'s local state.
struct ActiveTileResize {
    let deviceId: String
    let startSize: TileSize
    var didStep: Bool
}

/// Card frames in the tile coordinate space, used to find which card the pointer is over.
struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Flow Layout

struct TileSpanKey: LayoutValueKey {
    static let defaultValue = 12
}

/// Packs children left to right into rows of 12 columns using each child's `TileSpanKey`
/// (3 = 1×1 round button, 6 = 2×1 capsule / 2×2 hero, 12 = full row).
/// Cards in a row share the tallest card's height.
struct TileFlowLayout: Layout {
    var spacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func width(for span: Int, total: CGFloat) -> CGFloat {
        let unit = (total - spacing * 11) / 12
        return unit * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    private func rows(_ subviews: Subviews, total: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var used = 0
        for (i, sub) in subviews.enumerated() {
            let span = min(max(sub[TileSpanKey.self], 1), 12)
            if used + span > 12, !current.indices.isEmpty {
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
        let total = proposal.width ?? 350
        let rs = rows(subviews, total: total)
        let height = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, total: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let span = min(max(subviews[i][TileSpanKey.self], 1), 12)
                let w = width(for: span, total: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}


// MARK: - Custom Groups

/// A user-named section ("灯光", "电器") that cards can be filed under on every page.
public struct DeviceGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
}

public enum GroupPrefs {
    public static let groupsKey = "device_groups"
    public static let mapKey = ViewPreferenceKeys.groupMap
    public static let collapsedKey = "device_groups_collapsed"
    /// `[deviceId: display name]`; local to this app, the Mi Home name is untouched.
    public static let aliasesKey = ViewPreferenceKeys.deviceAliases

    public static func groups(_ raw: String) -> [DeviceGroup] {
        (try? JSONDecoder().decode([DeviceGroup].self, from: Data(raw.utf8))) ?? []
    }

    public static func encode(_ groups: [DeviceGroup]) -> String {
        (try? String(data: JSONEncoder().encode(groups), encoding: .utf8)) ?? "[]"
    }

    public static func map(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    public static func encode(_ map: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
    }

    public static func set(_ raw: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [])
    }

    public static func encode(_ set: Set<String>) -> String {
        (try? String(data: JSONEncoder().encode(set.sorted()), encoding: .utf8)) ?? "[]"
    }
}

// MARK: - Room Display Preferences (#146)

/// Persisted room display preferences: `[roomId: alias]` plus a custom room order.
///
/// Both are JSON strings so the panel can observe them through `@AppStorage`. Preferences are
/// keyed by room id and never pruned: a room that disappears from a snapshot keeps its alias and
/// slot, and unknown ids are simply ignored when the order is applied.
public enum RoomPrefs {
    public static let aliasesKey = "room_aliases"
    public static let orderKey = "room_custom_order"

    public static func decodeAliases(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    public static func encodeAliases(_ aliases: [String: String]) -> String {
        let cleaned = aliases.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return (try? String(data: JSONEncoder().encode(cleaned), encoding: .utf8)) ?? "{}"
    }

    public static func decodeOrder(_ raw: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    public static func encodeOrder(_ ids: [String]) -> String {
        let unique = RoomPrefs.deduped(ids)
        return (try? String(data: JSONEncoder().encode(unique), encoding: .utf8)) ?? "[]"
    }

    /// The user's alias for `roomId`, or `nil` when it is unset or blank.
    public static func alias(for roomId: String, in aliases: [String: String]) -> String? {
        guard let alias = aliases[roomId]?.trimmingCharacters(in: .whitespaces), !alias.isEmpty else { return nil }
        return alias
    }

    /// Sorts rooms by the saved order; rooms not in it keep their incoming order after the known
    /// ones, and ids that no longer match a room are ignored.
    public static func apply(order: [String], to rooms: [RoomArea]) -> [RoomArea] {
        guard !order.isEmpty else { return rooms }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return rooms.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? (order.count + lhs.offset)
            let right = rank[rhs.element.id] ?? (order.count + rhs.offset)
            return left < right
        }.map(\.element)
    }

    /// Room ids in display order: the order the strip draws and Tab/Shift-Tab traverse. Rooms the
    /// saved order does not know yet follow the ranked ones.
    public static func displayIds(order: [String], rooms: [RoomArea]) -> [String] {
        apply(order: order, to: rooms).map(\.id)
    }

    /// The saved room order in `defaults`; empty when the user has not reordered.
    public static func storedOrder(from defaults: UserDefaults = .standard) -> [String] {
        decodeOrder(defaults.string(forKey: orderKey) ?? "[]")
    }

    /// Saved order seeded with every currently visible room, so a move never drops an id that
    /// belongs to a room which is temporarily missing from the snapshot.
    public static func seededOrder(_ order: [String], rooms: [RoomArea]) -> [String] {
        var result = order
        let known = Set(result)
        for room in rooms where !known.contains(room.id) {
            result.append(room.id)
        }
        return result
    }

    /// Moves `id` next to `target` (drag reorder). Unknown ids are a no-op.
    public static func move(_ order: [String], id: String, relativeTo target: String, after: Bool) -> [String] {
        guard id != target, order.contains(id), order.contains(target) else { return order }
        var result = order
        result.removeAll { $0 == id }
        guard let index = result.firstIndex(of: target) else { return order }
        result.insert(id, at: after ? index + 1 : index)
        return result
    }

    /// Moves `id` by one visible slot left (`delta < 0`) or right (`delta > 0`). Hidden ids keep
    /// their stored slot and are skipped while walking to the neighbouring visible room; shifting
    /// a hidden id is a no-op.
    public static func shift(_ order: [String], id: String, by delta: Int, visible: Set<String>) -> [String] {
        guard delta != 0, visible.contains(id), let from = order.firstIndex(of: id) else { return order }
        let step = delta > 0 ? 1 : -1
        var to = from + step
        while order.indices.contains(to), !visible.contains(order[to]) {
            to += step
        }
        guard order.indices.contains(to) else { return order }
        var result = order
        result.swapAt(from, to)
        return result
    }

    /// Raw defaults values for the "reset room names and order" action.
    public static func reset() -> (aliases: String, order: String) {
        (encodeAliases([:]), encodeOrder([]))
    }
}

/// Panel-wide UI requests raised from deep inside cards (context menus cannot host text input).
@MainActor
@Observable
final class LayoutUIState {
    static let shared = LayoutUIState()
    /// Non-nil while the "new group" name prompt is open; holds the device to file into it.
    var newGroupForDevice: String?
    /// Non-nil while renaming that group.
    var renamingGroupId: String?
    /// Non-nil while renaming that device (local display name only).
    var renamingDeviceId: String?
    /// Non-nil while renaming that room (local display name only).
    var renamingRoomId: String?
    /// Raised from a card's context menu, so entering edit mode is a discovered menu action and
    /// never a long press on a card (#41).
    var isEditingLayoutRequested = false
    /// Latest card frames in window `.global` coordinates; lets UI tests locate the resize
    /// handle after dynamic relayouts without hard-coding pixel positions.
    var cardGlobalFrames: [String: CGRect] = [:]
    /// The one edit mode the panel is in (#146 room-order redesign). Replaces the two booleans
    /// `isEditingLayout` / `isEditingRooms` that every entry point had to clear by hand. Lives here
    /// rather than in the panel's `@State` because the app-wide key monitor has to read it.
    var editMode: PanelEditMode = .none
    /// The reorder session's in-memory order and aliases; `nil` outside `roomOrder`. Dragging writes
    /// only here, so `@AppStorage` never republishes mid-drag.
    var roomOrderDraft: RoomOrderDraft?
    /// The same session's kind-chip order; `nil` outside `roomOrder`.
    var kindOrderDraft: RoomOrderDraft?
    /// Which of the two lists the order session shows.
    var orderTarget: OrderListTarget = .rooms
    /// Keyboard / VoiceOver focus inside the order list (a room id, or a kind's raw value).
    var focusedRoomId: String?
}

/// Inline name prompt shown over the panel for creating or renaming a group.
struct GroupNamePrompt: View {
    let title: String
    @State var name: String
    var placeholder: String = L10n.tr("例如：灯光、电器、环境", "e.g. Lights, Appliances")
    var onReset: (() -> Void)? = nil
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: DesignTokens.TypeSize.body))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
                .focused($focused)
                .onSubmit(save)
            HStack {
                if let onReset {
                    Button(L10n.tr("恢复原名", "Reset"), action: onReset)
                        .buttonStyle(PillActionButtonStyle())
                }
                Spacer()
                Button(L10n.tr("取消", "Cancel"), action: onCancel)
                    .buttonStyle(PillActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存", "Save"), action: save)
                    .buttonStyle(PillActionButtonStyle(isSelected: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous))
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
