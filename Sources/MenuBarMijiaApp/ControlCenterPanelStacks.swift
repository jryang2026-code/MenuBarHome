import SwiftUI
import MijiaCore

/// How the column groups the devices below the pinned favorites.
enum PanelGrouping: String, CaseIterable, Identifiable {
    case room, kind

    static let storageKey = "panel_grouping"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: return L10n.tr("按房间", "Rooms")
        case .kind: return L10n.tr("按类型", "Types")
        }
    }
}

/// One group in the column. Favorites are pinned open like Notification Center's widgets; every
/// other group is a notification-style stack that opens into full-width device cards.
struct DeviceStack: Identifiable, Equatable {
    enum Source: Equatable {
        case favorites
        case group(String)
        /// `nil` collects devices whose room the store does not know.
        case room(String?)
        case kind(DeviceKindTag)
        case offline
    }

    let id: String
    let source: Source
    let title: String
    let devices: [SmartDevice]

    var isPinned: Bool { source == .favorites }

    /// True when `listCut` already narrows the entire panel to this stack's room or kind.
    func matches(listCut: DeviceListCut) -> Bool {
        switch (source, listCut) {
        case (.room(let stackRoomId?), .room(let cutRoomId)):
            return stackRoomId == cutRoomId
        case (.kind(let stackKind), .kind(let cutKind)):
            return stackKind == cutKind
        default:
            return false
        }
    }

    /// Pinned favorites, single-device online groups, and a stack matching the active list cut open
    /// by default; the bottom `.offline` drawer always starts folded until explicitly opened.
    func isOpen(expandedStacks: Set<String>, listCut: DeviceListCut = .all) -> Bool {
        if source == .offline {
            return expandedStacks.contains(id)
        }
        return isPinned || devices.count == 1 || matches(listCut: listCut) || expandedStacks.contains(id)
    }

    /// Multi-device unpinned stacks outside a matching list cut — and the `.offline` drawer — can fold back up.
    func canCollapse(listCut: DeviceListCut = .all, isEditingLayout: Bool = false) -> Bool {
        if source == .offline {
            return !isEditingLayout
        }
        return !isPinned && devices.count > 1 && !matches(listCut: listCut) && !isEditingLayout
    }

    /// Whether an open stack draws a section header row above its cards:
    /// - Single-device room/kind groups (`空调 1`, `扫地机 1`, `客厅 1`) omit the header and show
    ///   the device card directly, matching `ActivityStackView`'s single-item rule.
    /// - A room/kind group already named by the active `listCut` pill omits the duplicate header.
    /// - When `常用` is the only group on screen (`totalStacks == 1`), there is no lower section
    ///   to contrast with, so it omits the `"常用"` header as well.
    /// - Custom user groups (`.group`) and the `.offline` drawer always keep their header.
    func showsHeader(totalStacks: Int, listCut: DeviceListCut = .all) -> Bool {
        switch source {
        case .favorites:
            return totalStacks > 1
        case .group, .offline:
            return true
        case .room, .kind:
            return devices.count > 1 && !matches(listCut: listCut)
        }
    }

    /// Single-item headers (e.g. a 1-device custom group or 1-device pinned `常用`) drop the `"1"`.
    var showsHeaderCount: Bool {
        devices.count > 1
    }

    /// Whether cards inside this open stack carry their room badge:
    /// - Never when `listCut` already scopes the entire panel to one room.
    /// - For a `.room` stack, omitted when `showsHeader` already names the room above, but shown
    ///   when a single-device room renders headerless so the card still identifies its room.
    /// - Shown for `.favorites`, `.group`, `.kind`, and `.offline` outside a room cut.
    func showsRoomBadge(totalStacks: Int, listCut: DeviceListCut = .all) -> Bool {
        if case .room = listCut { return false }
        if case .room = source {
            return !showsHeader(totalStacks: totalStacks, listCut: listCut)
        }
        return true
    }

    /// Descriptor for the parent room/kind submenu injected into cards when `showsHeader` is false,
    /// so hiding a single-device header never strands Rename Room or Move Up / Move Down.
    struct HeaderlessMenuDescriptor: Equatable {
        let title: String
        let symbol: String
    }

    func headerlessMenuDescriptor(
        showsHeader: Bool,
        canReorderRooms: Bool,
        canReorderKinds: Bool
    ) -> HeaderlessMenuDescriptor? {
        guard !showsHeader else { return nil }
        switch source {
        case .room(.some):
            return HeaderlessMenuDescriptor(
                title: L10n.tr("房间：\(title)", "Room: \(title)"),
                symbol: "house"
            )
        case .kind:
            guard canReorderKinds else { return nil }
            return HeaderlessMenuDescriptor(
                title: L10n.tr("类型：\(title)", "Type: \(title)"),
                symbol: devices.first?.sfSymbolName ?? "square.stack"
            )
        case .favorites, .group, .room(nil), .offline:
            return nil
        }
    }
}

/// Parent stack actions forwarded into `DeviceCardView`'s context menu when the stack's own
/// section header is hidden (`showsHeader == false`).
struct HeaderlessStackMenu {
    let title: String
    let symbol: String
    let makeContent: @MainActor () -> AnyView
}

private struct HeaderlessStackMenuKey: EnvironmentKey {
    static let defaultValue: HeaderlessStackMenu? = nil
}

extension EnvironmentValues {
    var headerlessStackMenu: HeaderlessStackMenu? {
        get { self[HeaderlessStackMenuKey.self] }
        set { self[HeaderlessStackMenuKey.self] = newValue }
    }
}

/// Applies a modifier only when there is one; keeps a single view identity either way.
struct OptionalModifier<Wrapped: ViewModifier>: ViewModifier {
    let wrapped: Wrapped?

    init(_ wrapped: Wrapped?) { self.wrapped = wrapped }

    func body(content: Content) -> some View {
        if let wrapped {
            content.modifier(wrapped)
        } else {
            content
        }
    }
}

extension View {
    /// macOS 26 softens content as it scrolls under the fixed header, as Notification Center does.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

extension ControlCenterPanel {
    var grouping: PanelGrouping { PanelGrouping(rawValue: groupingRaw) ?? .room }

    // MARK: - Building the stacks

    /// Favorites & habit-frequent devices first, then custom groups, then online room/kind stacks
    /// ranked by habit & active state, with offline/unpowered devices sunk into a bottom drawer.
    var deviceStacks: [DeviceStack] {
        let known = Set(groups.map(\.id))
        let map = groupMap.filter { known.contains($0.value) }
        let order = currentOrder
        let habitOrder = prioritySnapshot?.habitOrder ?? store.userHabitMemory.usageOrder()
        let isActive: (SmartDevice) -> Bool = {
            prioritySnapshot?.activeByDeviceId[$0.id] ?? store.presentsAsActive($0)
        }
        func ordered(_ devices: [SmartDevice]) -> [SmartDevice] {
            DeviceLayoutPrefs.apply(order: order, to: devices)
        }
        func prioritized(_ devices: [SmartDevice]) -> [SmartDevice] {
            PanelDeviceOrganizer.prioritizePool(
                devices,
                habitOrder: habitOrder,
                customOrder: order,
                isActive: isActive
            )
        }

        if isEditingLayout {
            var editStacks: [DeviceStack] = []
            var editPool = store.visibleDevices
            if !store.favoriteDevices.isEmpty {
                editStacks.append(DeviceStack(
                    id: "fav",
                    source: .favorites,
                    title: L10n.tr("常用", "Favorites"),
                    devices: ordered(store.favoriteDevices)
                ))
                editPool = store.nonFavoriteDevices
            }
            appendOnlineGroupAndCategoryStacks(from: editPool, map: map, orderFn: ordered, into: &editStacks)
            return editStacks
        }

        let partition = PanelDeviceOrganizer.partition(store.visibleDevices, customOrder: order)
        let onlineIdSet = Set(partition.online.map(\.id))
        let starredRaw = store.favoriteDevices.filter { onlineIdSet.contains($0.id) }
        let starredIds = Set(starredRaw.map(\.id))
        let favDevices = PanelDeviceOrganizer.prioritizeOnline(
            starredRaw,
            favoriteIds: starredIds,
            favoriteOrder: store.favoriteOrder,
            habitOrder: habitOrder,
            customOrder: order,
            isActive: isActive
        )

        var stacks: [DeviceStack] = []
        var pool = partition.online
        if !favDevices.isEmpty {
            stacks.append(DeviceStack(
                id: "fav",
                source: .favorites,
                title: L10n.tr("常用", "Favorites"),
                devices: favDevices
            ))
            pool = partition.online.filter { !starredIds.contains($0.id) }
        }

        appendOnlineGroupAndCategoryStacks(from: pool, map: map, orderFn: prioritized, into: &stacks)

        if !partition.offline.isEmpty {
            stacks.append(DeviceStack(
                id: PanelDeviceOrganizer.offlineSectionId,
                source: .offline,
                title: PanelDeviceOrganizer.offlineDrawerTitle(),
                devices: partition.offline
            ))
        }
        return stacks
    }

    private func appendOnlineGroupAndCategoryStacks(
        from pool: [SmartDevice],
        map: [String: String],
        orderFn: ([SmartDevice]) -> [SmartDevice],
        into stacks: inout [DeviceStack]
    ) {
        for group in groups {
            let members = pool.filter { map[$0.id] == group.id }
            if !members.isEmpty {
                stacks.append(DeviceStack(
                    id: "group:\(group.id)",
                    source: .group(group.id),
                    title: group.name,
                    devices: orderFn(members)
                ))
            }
        }
        let rest = pool.filter { map[$0.id] == nil }

        switch grouping {
        case .room:
            let rooms = displayRooms
            for room in rooms {
                let members = rest.filter { $0.roomId == room.id }
                if !members.isEmpty {
                    stacks.append(DeviceStack(
                        id: "room:\(room.id)",
                        source: .room(room.id),
                        title: roomDisplayTitle(room),
                        devices: orderFn(members)
                    ))
                }
            }
            let roomIds = Set(rooms.map(\.id))
            let homeless = rest.filter { !roomIds.contains($0.roomId) }
            if !homeless.isEmpty {
                stacks.append(DeviceStack(
                    id: "room:-",
                    source: .room(nil),
                    title: L10n.tr("其他", "Other"),
                    devices: orderFn(homeless)
                ))
            }
        case .kind:
            for tag in displayKinds {
                let members = rest.filter { $0.kind.tag == tag }
                if !members.isEmpty {
                    stacks.append(DeviceStack(
                        id: "kind:\(tag.rawValue)",
                        source: .kind(tag),
                        title: tag.chipTitle,
                        devices: orderFn(members)
                    ))
                }
            }
        }
    }

    private func stackSlotCost(_ stack: DeviceStack) -> Int {
        stack.devices.reduce(0) { $0 + tileSize($1).overviewSlotSize.slotCost }
    }

    /// Single-device non-favorite stacks beyond the initial slot budget fold into the long tail
    /// until opened by the user. Pinned favorites always stay open; remaining slots are filled
    /// by size weight (skipping oversized stacks so smaller ones still fit).
    func overviewFoldedStackIds(in stacks: [DeviceStack]) -> Set<String> {
        guard !isEditingLayout, store.listCut == .all else { return [] }
        let onlineStacks = stacks.filter { $0.source != .offline }
        let totalSlotCost = onlineStacks.reduce(0) { $0 + stackSlotCost($1) }
        guard totalSlotCost > PanelDeviceOrganizer.initialOverviewSlotBudget else { return [] }

        let pinnedCost = onlineStacks.filter(\.isPinned).reduce(0) { $0 + stackSlotCost($1) }
        var remaining = max(0, PanelDeviceOrganizer.initialOverviewSlotBudget - pinnedCost)
        var folded: Set<String> = []
        for stack in onlineStacks where !stack.isPinned {
            if stack.isOpen(expandedStacks: [], listCut: store.listCut) {
                let cost = stackSlotCost(stack)
                if cost <= remaining {
                    remaining -= cost
                } else {
                    folded.insert(stack.id)
                }
            }
        }
        return folded
    }

    func isStackOpen(_ stack: DeviceStack, overviewFolded: Set<String>) -> Bool {
        if overviewFolded.contains(stack.id), !expandedStacks.contains(stack.id) {
            return false
        }
        return stack.isOpen(expandedStacks: expandedStacks, listCut: store.listCut)
    }

    /// Pinned favorites, single-device groups within the initial slot budget, and a stack matching
    /// the active list cut open automatically.
    func isStackOpen(_ stack: DeviceStack) -> Bool {
        isStackOpen(stack, overviewFolded: overviewFoldedStackIds(in: deviceStacks))
    }

    func longTailBarState(for stacks: [DeviceStack]) -> (shows: Bool, hiddenCount: Int, isExpanded: Bool) {
        guard !isEditingLayout, store.listCut == .all else { return (false, 0, false) }
        let onlineStacks = stacks.filter { $0.source != .offline }
        let totalSlotCost = onlineStacks.reduce(0) { $0 + stackSlotCost($1) }
        guard totalSlotCost > PanelDeviceOrganizer.initialOverviewSlotBudget else { return (false, 0, false) }

        let collapsible = onlineStacks.filter { !$0.isPinned }
        guard !collapsible.isEmpty else { return (false, 0, false) }

        let foldedByCap = overviewFoldedStackIds(in: stacks)
        let hiddenCount = onlineStacks.reduce(0) { sum, stack in
            isStackOpen(stack, overviewFolded: foldedByCap) ? sum : (sum + stack.devices.count)
        }
        if hiddenCount > 0 {
            return (true, hiddenCount, false)
        }
        let anyManuallyExpanded = collapsible.contains { expandedStacks.contains($0.id) }
        return (anyManuallyExpanded, 0, anyManuallyExpanded)
    }

    func toggleLongTail(in stacks: [DeviceStack]) {
        let state = longTailBarState(for: stacks)
        let ids = stacks.filter { $0.source != .offline && !$0.isPinned }.map(\.id)
        withAnimation(stackAnimation) {
            if state.isExpanded {
                expandedStacks.subtract(ids)
            } else {
                expandedStacks.formUnion(ids)
            }
        }
    }

    var roomBrowseOptions: [PanelRoomBrowseOption] {
        let visibleByRoom = Dictionary(grouping: store.visibleDevices, by: \.roomId)
        return displayRooms.compactMap { room in
            guard let members = visibleByRoom[room.id], !members.isEmpty else { return nil }
            let onlineCount = members.filter(\.isOnline).count
            return PanelRoomBrowseOption(
                id: room.id,
                title: roomDisplayTitle(room),
                onlineCount: onlineCount
            )
        }
    }

    /// Online devices below `常用` and custom groups — the slice `按房间 / 按类型` actually regroups.
    /// With 0 or 1 online device here, both segments render identically, so the toggle hides.
    var unpinnedUngroupedDeviceCount: Int {
        let known = Set(groups.map(\.id))
        let map = groupMap.filter { known.contains($0.value) }
        let onlinePool = (store.favoriteDevices.isEmpty ? store.visibleDevices : store.nonFavoriteDevices)
            .filter(\.isOnline)
        return onlinePool.filter { map[$0.id] == nil }.count
    }

    var showsGroupingSegments: Bool {
        unpinnedUngroupedDeviceCount > 1
    }

    var showsGroupingBar: Bool {
        showsGroupingSegments || listCutTitle != nil || hasQuickDrawerContent
    }

    /// The order the digit shortcuts and the card badges share: every card the column draws, in
    /// the order it draws them. Folded stacks draw one summary card and contribute no digits.
    func quickIndexOrder(_ stacks: [DeviceStack]) -> PanelQuickIndexOrder {
        let folded = overviewFoldedStackIds(in: stacks)
        return PanelQuickIndexOrder(
            stacks: stacks,
            isOpen: { isStackOpen($0, overviewFolded: folded) },
            cards: { cardOrder($0.devices) }
        )
    }

    func openStack(containing deviceId: String?) {
        let stacks = deviceStacks
        let folded = overviewFoldedStackIds(in: stacks)
        guard let deviceId,
              let stack = stacks.first(where: { $0.devices.contains { $0.id == deviceId } }),
              !isStackOpen(stack, overviewFolded: folded) else { return }
        withAnimation(stackAnimation) { _ = expandedStacks.insert(stack.id) }
    }

    private var stackAnimation: Animation? {
        AppleMotion.resolve(.stack, reduceMotion: reduceMotion)
    }

    private func setStack(_ stack: DeviceStack, open: Bool) {
        withAnimation(stackAnimation) {
            if open { expandedStacks.insert(stack.id) } else { expandedStacks.remove(stack.id) }
        }
    }

    // MARK: - Grouping capsule

    /// Rooms / types, plus the room or kind a Tab cut is showing, which a click clears.
    var groupingBar: some View {
        HStack(spacing: 6) {
            if showsGroupingSegments {
                GlassSegmentedControl(
                    selection: $groupingRaw,
                    segments: PanelGrouping.allCases.map { GlassSegment(value: $0.rawValue, title: $0.title) }
                )
            }
            if let cut = listCutTitle {
                Button {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { _ = store.selectRoom(nil) }
                } label: {
                    HStack(spacing: 4) {
                        Text(cut)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.footnote, weight: .bold))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(Text(L10n.tr("显示全部：取消只看\(cut)", "Show all: stop showing only \(cut)")))
                .panelHelp(L10n.tr("取消筛选，返回全部设备", "Clear filter and show all devices"))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if !showsGroupingSegments {
                Spacer(minLength: 0)
            }
            if hasQuickDrawerContent {
                PanelQuickDrawerToggleButton(
                    isExpanded: quickDrawerState.isExpanded,
                    theme: .liquidGlass,
                    action: toggleQuickDrawer
                )
            }
        }
    }

    private var listCutTitle: String? {
        switch store.listCut {
        case .all:
            return nil
        case .room(let id):
            return store.rooms.first { $0.id == id }.map(roomDisplayTitle)
        case .kind(let tag):
            return tag.chipTitle
        }
    }

    // MARK: - A stack

    @ViewBuilder
    func stackView(
        _ stack: DeviceStack,
        totalStacks: Int,
        overviewFolded: Set<String>,
        quickIndexMap: [String: Int]
    ) -> some View {
        let open = isStackOpen(stack, overviewFolded: overviewFolded)
        let showsHeader = stack.showsHeader(totalStacks: totalStacks, listCut: store.listCut)
            || (expandedStacks.contains(stack.id) && overviewFolded.contains(stack.id))
        let showRoomBadge: Bool = if case .room = stack.source, showsHeader {
            false
        } else {
            stack.showsRoomBadge(totalStacks: totalStacks, listCut: store.listCut)
        }
        let dimmedInEdit = !stack.isPinned && isEditingLayout
        VStack(alignment: .leading, spacing: 8) {
            if open {
                if showsHeader {
                    stackHeader(stack)
                        .transition(.opacity)
                }
                deviceCollectionView(
                    devices: stack.devices,
                    showRoomBadge: showRoomBadge,
                    quickIndexMap: quickIndexMap,
                    allowsLayoutEditing: stack.isPinned
                )
                .environment(\.headerlessStackMenu, headerlessStackMenu(for: stack, showsHeader: showsHeader))
                // The cards slide out of the stack's top edge, as an opened notification group does.
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(y: -10))
                        .combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                ))
            } else {
                collapsedStack(stack)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .opacity(dimmedInEdit ? 0.45 : 1)
        .allowsHitTesting(!dimmedInEdit)
        .id(stack.id)
    }

    private func stackHeader(_ stack: DeviceStack) -> some View {
        let canCollapse = stack.canCollapse(listCut: store.listCut, isEditingLayout: isEditingLayout)
            || (!stack.isPinned && !stack.matches(listCut: store.listCut) && !isEditingLayout && expandedStacks.contains(stack.id))
        return HStack(alignment: .center, spacing: 6) {
            Text(stack.title)
                .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold))
                .lineLimit(1)
            if stack.showsHeaderCount {
                Text("\(stack.devices.count)")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(stack.devices.count)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canCollapse {
                Button {
                    setStack(stack, open: false)
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.tr("收起", "Show Less"))
                        Image(systemName: "chevron.up")
                            .font(.system(size: DesignTokens.TypeSize.footnote, weight: .bold))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: DesignTokens.minHitTarget)
                    .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("收起 \(stack.title)", "Collapse \(stack.title)")))
                .panelHelp(L10n.tr("收起分组", "Collapse group"))
            }
        }
        .frame(minHeight: DesignTokens.minHitTarget)
        .padding(.leading, 2)
        .contentShape(Rectangle())
        .contextMenu { stackMenu(stack) }
    }

    /// The folded group: a summary card with two narrower layers peeking 7 pt under it.
    private func collapsedStack(_ stack: DeviceStack) -> some View {
        let lit = stack.devices.filter { store.presentsAsActive($0) }
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
        let depth = min(stack.devices.count, StackedCardGeometry.maxVisible) - 1
        return Button {
            setStack(stack, open: true)
        } label: {
            HStack(spacing: 12) {
                stackOrb(stack, lit: lit)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(stack.title)
                            .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.tr("\(stack.devices.count) 台", "\(stack.devices.count)"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(stackSummary(stack, lit: lit))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(PressableCardButtonStyle())
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.module)
        .glassHoverHighlight(in: shape)
        .background {
            GeometryReader { proxy in
                // The peek says "more inside", so it stays under reduced motion too.
                if depth > 0 {
                    ForEach((1...depth).reversed(), id: \.self) { layer in
                        StackedCardBackplate(depth: layer, size: proxy.size)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.bottom, StackedCardGeometry.offsetY(depth: depth))
        .contextMenu { stackMenu(stack) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(stack.title)，\(stackSummary(stack, lit: lit))"))
        .accessibilityHint(Text(L10n.tr("展开查看 \(stack.devices.count) 台设备", "Expand to show \(stack.devices.count) devices")))
        .panelHelp(L10n.tr("点击展开查看 \(stack.devices.count) 台设备", "Click to show \(stack.devices.count) devices"))
    }

    /// Colour only inside the orb: the family colour of the first running device, gray when all are off.
    private func stackOrb(_ stack: DeviceStack, lit: [SmartDevice]) -> some View {
        let color = stack.source == .offline ? nil : lit.first.map { DevicePalette.accentColor(for: $0) }
        let symbol: String = {
            switch stack.source {
            case .offline: return "wifi.slash"
            case .kind, .group: return (lit.first ?? stack.devices.first)?.sfSymbolName ?? "square.stack.fill"
            case .room, .favorites: return "house.fill"
            }
        }()
        return ZStack {
            Circle()
                .fill(color ?? Color.primary.opacity(effectiveScheme == .dark ? 0.14 : 0.08))
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .foregroundStyle(color == nil ? Color.secondary : Color.white)
        }
        .frame(width: 38, height: 38)
        .animation(AppleMotion.resolve(.control, reduceMotion: reduceMotion), value: color == nil)
    }

    /// What a notification body would say: which devices are on, plus the room's climate reading.
    private func stackSummary(_ stack: DeviceStack, lit: [SmartDevice]) -> String {
        let aliases = GroupPrefs.map(aliasesRaw)
        if stack.source == .offline {
            return PanelDeviceOrganizer.offlineStackSummary(devices: stack.devices, aliases: aliases)
        }
        var parts: [String] = []
        if lit.isEmpty {
            parts.append(L10n.tr("全部关闭", "All off"))
        } else {
            let names = lit.prefix(2).map { aliases[$0.id] ?? $0.name }
            let joined = names.joined(separator: L10n.tr("、", ", "))
            parts.append(lit.count > 2
                ? L10n.tr("\(joined) 等 \(lit.count) 台开启", "\(joined) and \(lit.count - 2) more on")
                : L10n.tr("\(joined) 开启", "\(joined) on"))
        }
        if case .room(let id?) = stack.source,
           let room = store.rooms.first(where: { $0.id == id }),
           let reading = store.environmentReadings.first(where: { $0.roomName == room.name && $0.temperature != nil }) {
            var climate = reading.temperature.map { L10n.temperature($0, fractionDigits: 1) } ?? ""
            if let humidity = reading.humidity.flatMap(DeviceSynthesizer.roundedInt) { climate += " \(humidity)%" }
            parts.append(climate)
        }
        return parts.joined(separator: " · ")
    }

    private func headerlessStackMenu(for stack: DeviceStack, showsHeader: Bool) -> HeaderlessStackMenu? {
        guard let descriptor = stack.headerlessMenuDescriptor(
            showsHeader: showsHeader,
            canReorderRooms: canReorderRooms,
            canReorderKinds: canReorderKinds
        ) else {
            return nil
        }
        return HeaderlessStackMenu(
            title: descriptor.title,
            symbol: descriptor.symbol,
            makeContent: { AnyView(stackMenu(stack)) }
        )
    }

    // MARK: - Stack menu

    @ViewBuilder
    private func stackMenu(_ stack: DeviceStack) -> some View {
        switch stack.source {
        case .favorites, .offline:
            EmptyView()
        case .group(let gid):
            Button { layoutUI.renamingGroupId = gid } label: { Label(L10n.tr("重命名", "Rename"), systemImage: "pencil") }
            Button { moveGroup(gid, by: -1) } label: { Label(L10n.tr("上移分组", "Move Up"), systemImage: "arrow.up") }
            Button { moveGroup(gid, by: 1) } label: { Label(L10n.tr("下移分组", "Move Down"), systemImage: "arrow.down") }
            Divider()
            Button(role: .destructive) { deleteGroup(gid) } label: { Label(L10n.tr("删除分组", "Delete Group"), systemImage: "trash") }
        case .room(let id?):
            Button { layoutUI.renamingRoomId = id } label: { Label(L10n.tr("重命名房间…", "Rename Room…"), systemImage: "pencil") }
            if canReorderRooms {
                Button { moveRoom(id, by: -1) } label: { Label(L10n.tr("上移", "Move Up"), systemImage: "arrow.up") }
                    .disabled(displayRooms.first?.id == id)
                Button { moveRoom(id, by: 1) } label: { Label(L10n.tr("下移", "Move Down"), systemImage: "arrow.down") }
                    .disabled(displayRooms.last?.id == id)
                Divider()
                Button { beginRoomOrder() } label: { Label(L10n.tr("排序房间…", "Reorder Rooms…"), systemImage: "arrow.up.arrow.down") }
            }
        case .room(nil):
            EmptyView()
        case .kind(let tag):
            if canReorderKinds {
                Button { moveKind(tag, by: -1) } label: { Label(L10n.tr("上移", "Move Up"), systemImage: "arrow.up") }
                    .disabled(displayKinds.first == tag)
                Button { moveKind(tag, by: 1) } label: { Label(L10n.tr("下移", "Move Down"), systemImage: "arrow.down") }
                    .disabled(displayKinds.last == tag)
                Divider()
                Button { beginRoomOrder(target: .kinds) } label: { Label(L10n.tr("排序类型…", "Reorder Kinds…"), systemImage: "arrow.up.arrow.down") }
            }
        }
    }
}
