import SwiftUI
import MijiaCore

// MARK: - Split-Tile Action Layout (Shared Classic & Liquid Glass)

public enum DeviceTilePrimaryKind: Equatable, Sendable {
    case togglePower
    case cameraLive
}

/// Resolves whether a compact device tile renders as a 2-zone split tile (left = primary toggle/live,
/// right = adjustment drawer), a single-action tile, or a non-interactive read-only tile.
public enum DeviceTileActionLayout: Equatable, Sendable {
    case split(primary: DeviceTilePrimaryKind)
    case primaryOnly(DeviceTilePrimaryKind)
    case adjustOnly
    case readOnly

    @MainActor
    public static func resolve(for device: SmartDevice, store: HomeStore) -> DeviceTileActionLayout {
        let primary: DeviceTilePrimaryKind? = {
            if case .camera = device.kind {
                if device.isOnline { return .cameraLive }
                return device.isPrimaryToggleable ? .togglePower : nil
            }
            return device.isPrimaryToggleable ? .togglePower : nil
        }()
        // Offline / unpowered devices never expose an expandable adjustment drawer.
        let canAdjust = device.isOnline && store.hasDetailDrawer(for: device)

        switch (primary, canAdjust) {
        case (.some(let kind), true):
            return .split(primary: kind)
        case (.some(let kind), false):
            return .primaryOnly(kind)
        case (nil, true):
            return .adjustOnly
        case (nil, false):
            return .readOnly
        }
    }

    @MainActor
    @discardableResult
    public static func performPrimary(for device: SmartDevice, store: HomeStore) -> Task<Bool, Never>? {
        if case .camera(let cam) = device.kind, device.isOnline {
            if store.isControlBlockedByScreenLock {
                store.openCameraLiveView(device.id)
                return nil
            }
            var wakeTask: Task<Bool, Never>?
            if device.kind.canTogglePower, !cam.isOn {
                wakeTask = store.togglePrimary(device)
                if wakeTask == nil, store.cameraCustomStreamURL(for: device.id) == nil {
                    return nil
                }
            }
            store.openCameraLiveView(device.id)
            if device.isPrimaryToggleable, cam.isOn || wakeTask != nil {
                SoundFeedback.playSuccess()
            }
            return wakeTask
        }
        guard device.isPrimaryToggleable else { return nil }
        let task = store.togglePrimary(device)
        if task != nil, device.isOnline {
            SoundFeedback.playSuccess()
        }
        return task
    }

    @MainActor
    public static func performAdjust(for device: SmartDevice, store: HomeStore) {
        guard device.isOnline, store.hasDetailDrawer(for: device) else { return }
        store.toggleExpanded(device.id)
    }

    public static func primaryHint(for device: SmartDevice, kind: DeviceTilePrimaryKind) -> String {
        switch kind {
        case .cameraLive:
            return L10n.tr("打开实时画面", "Open live view")
        case .togglePower:
            return L10n.tr("切换开关", "Toggle power")
        }
    }

    public static func primaryTooltip(for device: SmartDevice, kind: DeviceTilePrimaryKind) -> String {
        switch kind {
        case .cameraLive:
            return L10n.tr("点击打开摄像头实时小窗", "Click to open live camera window")
        case .togglePower:
            return L10n.tr("点击直接切换开关", "Click to toggle power")
        }
    }

    public static func adjustTooltip(isExpanded: Bool) -> String {
        isExpanded
            ? L10n.tr("收起调节", "Collapse controls")
            : L10n.tr("展开调节", "Adjust controls")
    }

    public static func adjustAccessibilityLabel(deviceName: String, isExpanded: Bool) -> String {
        isExpanded
            ? L10n.tr("收起 \(deviceName) 详细控制", "Collapse \(deviceName) controls")
            : L10n.tr("调节 \(deviceName)", "Adjust \(deviceName)")
    }
}

// MARK: - Shared Compact Split-Tile Header View

/// Shared compact tile header used by both `DeviceCardView` (Liquid Glass) and `ClassicDeviceCardView` (Classic).
/// Left zone triggers primary toggle/live action; right zone opens/collapses the adjustment drawer;
/// single-action tiles render a single full-tile button without misleading affordances.
struct SplitDeviceTileHeader<Orb: View, Badge: View, QuickBadge: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.isEditingLayout) private var isEditingLayout

    let device: SmartDevice
    let store: HomeStore
    let statusText: String
    let nameColor: Color
    let statusColor: Color
    let accessibilitySummary: String
    let isExpanded: Bool
    let isHeroTile: Bool
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let verticalPadding: CGFloat
    @ViewBuilder let orb: () -> Orb
    @ViewBuilder let readOnlyBadge: () -> Badge
    @ViewBuilder let quickBadge: () -> QuickBadge

    @State private var isAdjustHovered = false

    private var actionLayout: DeviceTileActionLayout {
        DeviceTileActionLayout.resolve(for: device, store: store)
    }

    var body: some View {
        switch actionLayout {
        case .split(let primary):
            splitBody(primary: primary)
        case .primaryOnly(let primary):
            singleActionButton(
                hint: DeviceTileActionLayout.primaryHint(for: device, kind: primary),
                tooltip: DeviceTileActionLayout.primaryTooltip(for: device, kind: primary),
                showsChevron: false
            ) {
                guard !isEditingLayout else { return }
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    _ = DeviceTileActionLayout.performPrimary(for: device, store: store)
                }
            }
        case .adjustOnly:
            singleActionButton(
                hint: L10n.tr("展开详细控制", "Expand controls"),
                tooltip: DeviceTileActionLayout.adjustTooltip(isExpanded: isExpanded),
                showsChevron: true
            ) {
                guard !isEditingLayout else { return }
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    DeviceTileActionLayout.performAdjust(for: device, store: store)
                }
            }
        case .readOnly:
            readOnlyBody
        }
    }

    private func splitBody(primary: DeviceTilePrimaryKind) -> some View {
        HStack(alignment: isHeroTile ? .top : .center, spacing: 0) {
            Button {
                guard !isEditingLayout else { return }
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    _ = DeviceTileActionLayout.performPrimary(for: device, store: store)
                }
            } label: {
                HStack(spacing: 9) {
                    orb()
                    titleAndStatusBlock
                    Spacer(minLength: 4)
                }
                .padding(.leading, leadingPadding)
                .padding(.trailing, 6)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget, maxHeight: isExpanded ? nil : .infinity, alignment: isHeroTile ? .topLeading : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableCardButtonStyle())
            .accessibilityLabel(Text(accessibilitySummary))
            .accessibilityHint(Text(DeviceTileActionLayout.primaryHint(for: device, kind: primary)))
            .panelHelp(DeviceTileActionLayout.primaryTooltip(for: device, kind: primary))

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                .frame(width: DesignTokens.hairline)
                .padding(.vertical, 10)
                .accessibilityHidden(true)

            Button {
                guard !isEditingLayout else { return }
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    DeviceTileActionLayout.performAdjust(for: device, store: store)
                }
            } label: {
                HStack(spacing: 3) {
                    quickBadge()
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                        .foregroundStyle((isAdjustHovered || isExpanded) ? nameColor.opacity(0.88) : statusColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.leading, 7)
                .padding(.trailing, max(8, trailingPadding - 2))
                .frame(minWidth: 32, minHeight: DesignTokens.minHitTarget, maxHeight: isExpanded ? nil : .infinity)
                .background(
                    Color.primary.opacity(isAdjustHovered && !isEditingLayout ? (colorScheme == .dark ? 0.09 : 0.05) : 0)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isAdjustHovered = $0 }
            .accessibilityLabel(Text(DeviceTileActionLayout.adjustAccessibilityLabel(deviceName: device.name, isExpanded: isExpanded)))
            .panelHelp(DeviceTileActionLayout.adjustTooltip(isExpanded: isExpanded))
        }
    }

    private func singleActionButton(
        hint: String,
        tooltip: String,
        showsChevron: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                orb()
                titleAndStatusBlock
                Spacer(minLength: 2)
                quickBadge()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                        .foregroundStyle(isExpanded ? nameColor.opacity(0.88) : statusColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget, maxHeight: isExpanded ? nil : .infinity, alignment: isHeroTile ? .topLeading : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardButtonStyle())
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(hint))
        .panelHelp(tooltip)
    }

    private var readOnlyBody: some View {
        HStack(spacing: 9) {
            orb()
            titleAndStatusBlock
            Spacer(minLength: 2)
            quickBadge()
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget, maxHeight: isExpanded ? nil : .infinity, alignment: isHeroTile ? .topLeading : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var titleAndStatusBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(device.name)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)

                readOnlyBadge()
            }

            Text(statusText)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: device.isActiveOn ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
    }
}

// MARK: - Frozen Panel Priority Snapshot & Organizer

/// Freezes habit frequency and active-on state for the duration of one panel open session so
/// clicking a toggle never reshuffles tiles underneath the pointer or changes quick-index digits.
public struct PanelPrioritySnapshot: Equatable, Sendable {
    public let habitOrder: [String]
    public let activeByDeviceId: [String: Bool]

    public init(habitOrder: [String], activeByDeviceId: [String: Bool]) {
        self.habitOrder = habitOrder
        self.activeByDeviceId = activeByDeviceId
    }

    @MainActor
    public static func capture(from store: HomeStore) -> PanelPrioritySnapshot {
        let activeMap = Dictionary(
            store.devices.map { ($0.id, store.presentsAsActive($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return PanelPrioritySnapshot(
            habitOrder: store.userHabitMemory.usageOrder(),
            activeByDeviceId: activeMap
        )
    }

    /// Freezes newly arrived devices (e.g. initial snapshot arriving after panel open) without
    /// unfreezing devices already shown in the current session.
    @MainActor
    public func freezingNewDevices(from store: HomeStore) -> PanelPrioritySnapshot {
        guard !activeByDeviceId.isEmpty else {
            return .capture(from: store)
        }
        var updated = activeByDeviceId
        var changed = false
        for device in store.devices where updated[device.id] == nil {
            updated[device.id] = store.presentsAsActive(device)
            changed = true
        }
        guard changed else { return self }
        return PanelPrioritySnapshot(habitOrder: habitOrder, activeByDeviceId: updated)
    }
}

public enum PanelDeviceOrganizer {
    public static let initialOverviewLimit = 8
    public static let initialOverviewSlotBudget = OverviewSlotBudget.defaultBudget
    public static let offlineSectionId = "offline"

    public struct Partition: Equatable, Sendable {
        public let online: [SmartDevice]
        public let offline: [SmartDevice]
    }

    public struct OverviewSlice: Equatable, Sendable {
        public let visible: [SmartDevice]
        public let hiddenCount: Int
        public let showsLongTailControl: Bool
    }

    public static func partition(_ devices: [SmartDevice], customOrder: [String]) -> Partition {
        let online = devices.filter(\.isOnline)
        let rawOffline = devices.filter { !$0.isOnline }
        let offline = DeviceLayoutPrefs.apply(order: customOrder, to: rawOffline)
        return Partition(online: online, offline: offline)
    }

    /// Orders online devices with Favorites first (`favoriteOrder`), then frequently used devices
    /// (`habitOrder`), then currently active devices (`isActive`), preserving snapshot order on ties.
    /// When the user has saved a manual `customOrder`, that explicit order wins.
    public static func prioritizeOnline(
        _ devices: [SmartDevice],
        favoriteIds: Set<String>,
        favoriteOrder: [String],
        habitOrder: [String],
        customOrder: [String],
        isActive: (SmartDevice) -> Bool
    ) -> [SmartDevice] {
        guard customOrder.isEmpty else {
            return DeviceLayoutPrefs.apply(order: customOrder, to: devices)
        }
        let favRank = Dictionary(favoriteOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let habitRank = Dictionary(habitOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        return devices.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let aFav = favoriteIds.contains(a.id)
            let bFav = favoriteIds.contains(b.id)
            if aFav != bFav { return aFav }
            if aFav && bFav {
                let fa = favRank[a.id] ?? Int.max
                let fb = favRank[b.id] ?? Int.max
                if fa != fb { return fa < fb }
            }
            let ha = habitRank[a.id] ?? Int.max
            let hb = habitRank[b.id] ?? Int.max
            if ha != hb { return ha < hb }

            let aa = isActive(a) ? 0 : 1
            let ba = isActive(b) ? 0 : 1
            if aa != ba { return aa < ba }

            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Orders a non-favorite online device pool (custom group, room, kind, or ungrouped rest),
    /// respecting `customOrder` when present, otherwise ranking by habit frequency then active state.
    public static func prioritizePool(
        _ devices: [SmartDevice],
        habitOrder: [String],
        customOrder: [String],
        isActive: (SmartDevice) -> Bool
    ) -> [SmartDevice] {
        prioritizeOnline(
            devices,
            favoriteIds: [],
            favoriteOrder: [],
            habitOrder: habitOrder,
            customOrder: customOrder,
            isActive: isActive
        )
    }

    /// Caps the initial `全部` (`listCut == .all`) overview using size-weighted slot accounting
    /// (`OverviewSlotBudget`, default 16 slots = 8 `half` tiles). Pinned items always appear;
    /// remaining slots are filled in order, skipping oversized tiles when smaller ones fit.
    public static func overviewSlice(
        orderedOnline: [SmartDevice],
        listCut: DeviceListCut,
        isExpanded: Bool,
        keepingVisibleIds: Set<String>,
        slotBudget: Int = initialOverviewSlotBudget,
        pinnedIds: Set<String> = [],
        slotSize: (SmartDevice) -> OverviewSlotSize = { _ in .half }
    ) -> OverviewSlice {
        guard listCut == .all else {
            return OverviewSlice(visible: orderedOnline, hiddenCount: 0, showsLongTailControl: false)
        }
        let items = orderedOnline.map { dev in
            OverviewSlotItem(
                id: dev.id,
                size: slotSize(dev),
                isPinned: pinnedIds.contains(dev.id)
            )
        }
        let budgetResult = OverviewSlotBudget.select(
            items: items,
            budget: slotBudget,
            keepingVisibleIds: keepingVisibleIds
        )
        guard budgetResult.hasOverflow else {
            return OverviewSlice(visible: orderedOnline, hiddenCount: 0, showsLongTailControl: false)
        }
        if isExpanded {
            return OverviewSlice(visible: orderedOnline, hiddenCount: 0, showsLongTailControl: true)
        }
        let visibleSet = Set(budgetResult.visibleIds)
        let visible = orderedOnline.filter { visibleSet.contains($0.id) }
        let hidden = max(0, orderedOnline.count - visible.count)
        return OverviewSlice(
            visible: visible,
            hiddenCount: hidden,
            showsLongTailControl: hidden > 0
        )
    }

    public static func offlineDrawerTitle() -> String {
        L10n.tr("离线或未通电", "Offline or Unpowered")
    }

    public static func offlineStackSummary(devices: [SmartDevice], aliases: [String: String]) -> String {
        let names = devices.prefix(2).map { aliases[$0.id] ?? $0.name }
        let joined = names.joined(separator: L10n.tr("、", ", "))
        if devices.count > 2 {
            return L10n.tr("\(joined) 等 \(devices.count) 台离线", "\(joined) and \(devices.count - 2) more offline")
        }
        return L10n.tr("\(joined) 离线", "\(joined) offline")
    }

    public static func longTailExpandTitle(count: Int) -> String {
        L10n.tr("展开其余 \(count) 台设备", "Show \(count) More Devices")
    }

    public static func longTailCollapseTitle() -> String {
        L10n.tr("收起其余设备", "Show Less")
    }

    public static func browseByRoomTitle() -> String {
        L10n.tr("按房间找", "By Room")
    }
}

// MARK: - Shared >8 Long-Tail Bar & Offline Drawer Controls

struct PanelRoomBrowseOption: Identifiable, Equatable {
    let id: String
    let title: String
    let onlineCount: Int
}

struct PanelLongTailBar: View {
    let hiddenCount: Int
    let isExpanded: Bool
    let rooms: [PanelRoomBrowseOption]
    let theme: PanelTheme
    let onToggleExpand: () -> Void
    let onSelectRoom: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpand) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: DesignTokens.TypeSize.footnote, weight: .bold))
                    Text(isExpanded
                        ? PanelDeviceOrganizer.longTailCollapseTitle()
                        : PanelDeviceOrganizer.longTailExpandTitle(count: hiddenCount))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget)
                .modifier(PanelCapsuleSurface(theme: theme))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded
                ? PanelDeviceOrganizer.longTailCollapseTitle()
                : PanelDeviceOrganizer.longTailExpandTitle(count: hiddenCount)))
            .panelHelp(isExpanded
                ? PanelDeviceOrganizer.longTailCollapseTitle()
                : PanelDeviceOrganizer.longTailExpandTitle(count: hiddenCount))

            if !isExpanded, rooms.count > 1 {
                Menu {
                    ForEach(rooms) { room in
                        Button {
                            onSelectRoom(room.id)
                        } label: {
                            Text(room.onlineCount > 0 ? "\(room.title)  \(room.onlineCount)" : room.title)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "house")
                            .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                        Text(PanelDeviceOrganizer.browseByRoomTitle())
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: DesignTokens.minHitTarget)
                    .modifier(PanelCapsuleSurface(theme: theme))
                    .contentShape(Capsule(style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text(PanelDeviceOrganizer.browseByRoomTitle()))
                .panelHelp(L10n.tr("按房间筛选设备", "Filter devices by room"))
            }
        }
    }
}

private struct PanelCapsuleSurface: ViewModifier {
    let theme: PanelTheme

    func body(content: Content) -> some View {
        switch theme {
        case .classic:
            content.classicAdaptiveGlass(in: Capsule(style: .continuous), interactive: true)
        case .liquidGlass:
            content.adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
        }
    }
}

struct ClassicOfflineDrawerHeader: View {
    let count: Int
    let summary: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "wifi.slash")
                        .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(PanelDeviceOrganizer.offlineDrawerTitle())
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(1)
                    if !isExpanded, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: DesignTokens.TypeSize.footnote))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Text(L10n.tr("\(count) 台", "\(count)"))
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget, alignment: .leading)
            .classicTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            summary.isEmpty
                ? PanelDeviceOrganizer.offlineDrawerTitle()
                : "\(PanelDeviceOrganizer.offlineDrawerTitle())\(L10n.tr("，", ", "))\(summary)"
        ))
        .accessibilityHint(Text(isExpanded
            ? L10n.tr("收起离线设备列表", "Collapse offline devices")
            : L10n.tr("展开查看 \(count) 台设备", "Expand to show \(count) devices")))
        .panelHelp(isExpanded
            ? L10n.tr("收起离线设备", "Collapse offline devices")
            : L10n.tr("点击展开查看离线或未通电设备", "Click to show offline or unpowered devices"))
    }
}

/// Quiet row at the bottom of the device list surfacing the cached unsupported-device count (#15).
struct UnsupportedDevicesQuietRow: View {
    let count: Int
    let action: () -> Void

    static func labelText(count: Int) -> String {
        guard count > 0 else { return "" }
        if count == 1 {
            return L10n.tr("1 台设备暂不支持显示", "1 device not supported yet")
        }
        return L10n.format("%@ 台设备暂不支持显示", "%@ devices not supported yet", "\(count)")
    }

    var body: some View {
        if count > 0 {
            let label = Self.labelText(count: count)
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(L10n.tr("在设置中查看未能显示的设备", "View devices not shown in Settings")))
            .panelHelp(L10n.tr("在设置中查看未能显示的设备", "View devices not shown in Settings"))
            .accessibilityIdentifier("unsupported-devices-quiet-row")
        }
    }
}
