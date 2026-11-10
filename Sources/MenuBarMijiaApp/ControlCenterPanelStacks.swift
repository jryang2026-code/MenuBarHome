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
struct DeviceStack: Identifiable {
    enum Source: Equatable {
        case favorites
        case group(String)
        /// `nil` collects devices whose room the store does not know.
        case room(String?)
        case kind(DeviceKindTag)
    }

    let id: String
    let source: Source
    let title: String
    let devices: [SmartDevice]

    var isPinned: Bool { source == .favorites }
    /// A room stack already names the room, so its cards drop the room badge.
    var showsRoomBadge: Bool {
        if case .room = source { return false }
        return true
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

    /// Favorites first, then each custom group, then one stack per room or per kind.
    var deviceStacks: [DeviceStack] {
        let known = Set(groups.map(\.id))
        let map = groupMap.filter { known.contains($0.value) }
        let order = currentOrder
        func ordered(_ devices: [SmartDevice]) -> [SmartDevice] {
            DeviceLayoutPrefs.apply(order: order, to: devices)
        }

        var stacks: [DeviceStack] = []
        var pool = store.visibleDevices
        if !store.favoriteDevices.isEmpty {
            stacks.append(DeviceStack(
                id: "fav", source: .favorites,
                title: L10n.tr("常用", "Favorites"),
                devices: ordered(store.favoriteDevices)
            ))
            pool = store.nonFavoriteDevices
        }
        for group in groups {
            let members = pool.filter { map[$0.id] == group.id }
            if !members.isEmpty {
                stacks.append(DeviceStack(id: "group:\(group.id)", source: .group(group.id), title: group.name, devices: ordered(members)))
            }
        }
        let rest = pool.filter { map[$0.id] == nil }

        switch grouping {
        case .room:
            let rooms = displayRooms
            for room in rooms {
                let members = rest.filter { $0.roomId == room.id }
                if !members.isEmpty {
                    stacks.append(DeviceStack(id: "room:\(room.id)", source: .room(room.id), title: roomDisplayTitle(room), devices: ordered(members)))
                }
            }
            let roomIds = Set(rooms.map(\.id))
            let homeless = rest.filter { !roomIds.contains($0.roomId) }
            if !homeless.isEmpty {
                stacks.append(DeviceStack(id: "room:-", source: .room(nil), title: L10n.tr("其他", "Other"), devices: ordered(homeless)))
            }
        case .kind:
            for tag in displayKinds {
                let members = rest.filter { $0.kind.tag == tag }
                if !members.isEmpty {
                    stacks.append(DeviceStack(id: "kind:\(tag.rawValue)", source: .kind(tag), title: tag.chipTitle, devices: ordered(members)))
                }
            }
        }
        return stacks
    }

    /// Pinned favorites and single-device groups never fold; edit mode opens everything.
    func isStackOpen(_ stack: DeviceStack) -> Bool {
        stack.isPinned || stack.devices.count == 1 || isEditingLayout || expandedStacks.contains(stack.id)
    }

    func openStack(containing deviceId: String?) {
        guard let deviceId,
              let stack = deviceStacks.first(where: { $0.devices.contains { $0.id == deviceId } }),
              !isStackOpen(stack) else { return }
        withAnimation(stackAnimation) { _ = expandedStacks.insert(stack.id) }
    }

    private var stackAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.stack
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
            GlassSegmentedControl(
                selection: $groupingRaw,
                segments: PanelGrouping.allCases.map { GlassSegment(value: $0.rawValue, title: $0.title) }
            )
            if let cut = listCutTitle {
                Button {
                    withAnimation(AppleMotion.snappySpring) { _ = store.selectRoom(nil) }
                } label: {
                    HStack(spacing: 4) {
                        Text(cut)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(Text(L10n.tr("显示全部：取消只看\(cut)", "Show all: stop showing only \(cut)")))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
    func stackView(_ stack: DeviceStack, quickIndexMap: [String: Int]) -> some View {
        let open = isStackOpen(stack)
        VStack(alignment: .leading, spacing: 8) {
            if open {
                stackHeader(stack)
                    .transition(.opacity)
                deviceCollectionView(
                    devices: stack.devices,
                    showRoomBadge: stack.showsRoomBadge,
                    quickIndexMap: quickIndexMap,
                    asRows: !stack.isPinned
                )
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
        .id(stack.id)
    }

    private func stackHeader(_ stack: DeviceStack) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(stack.title)
                .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold))
                .lineLimit(1)
            Text("\(stack.devices.count)")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(stack.devices.count)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !stack.isPinned, stack.devices.count > 1, !isEditingLayout {
                Button {
                    setStack(stack, open: false)
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.tr("收起", "Show Less"))
                        Image(systemName: "chevron.up")
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 26)
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
    }

    /// Colour only inside the orb: the family colour of the first running device, gray when all are off.
    private func stackOrb(_ stack: DeviceStack, lit: [SmartDevice]) -> some View {
        let color = lit.first.map { DevicePalette.accentColor(for: $0) }
        let symbol: String = {
            switch stack.source {
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
        .animation(AppleMotion.control, value: color == nil)
    }

    /// What a notification body would say: which devices are on, plus the room's climate reading.
    private func stackSummary(_ stack: DeviceStack, lit: [SmartDevice]) -> String {
        let aliases = GroupPrefs.map(aliasesRaw)
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
            if let humidity = reading.humidity { climate += " \(Int(humidity.rounded()))%" }
            parts.append(climate)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Stack menu

    @ViewBuilder
    private func stackMenu(_ stack: DeviceStack) -> some View {
        switch stack.source {
        case .favorites:
            EmptyView()
        case .group(let gid):
            Button { layoutUI.renamingGroupId = gid } label: { Label(L10n.tr("重命名", "Rename"), systemImage: "pencil") }
            Button { moveGroup(gid, by: -1) } label: { Label(L10n.tr("上移分组", "Move Up"), systemImage: "arrow.up") }
            Button { moveGroup(gid, by: 1) } label: { Label(L10n.tr("下移分组", "Move Down"), systemImage: "arrow.down") }
            Divider()
            Button(role: .destructive) { deleteGroup(gid) } label: { Label(L10n.tr("删除分组", "Delete Group"), systemImage: "trash") }
        case .room(let id?):
            Button { layoutUI.renamingRoomId = id } label: { Label(L10n.tr("重命名房间…", "Rename Room…"), systemImage: "pencil") }
            Button { moveRoom(id, by: -1) } label: { Label(L10n.tr("上移", "Move Up"), systemImage: "arrow.up") }
                .disabled(displayRooms.first?.id == id)
            Button { moveRoom(id, by: 1) } label: { Label(L10n.tr("下移", "Move Down"), systemImage: "arrow.down") }
                .disabled(displayRooms.last?.id == id)
            Divider()
            Button { beginRoomOrder() } label: { Label(L10n.tr("排序房间…", "Reorder Rooms…"), systemImage: "arrow.up.arrow.down") }
        case .room(nil):
            EmptyView()
        case .kind(let tag):
            Button { moveKind(tag, by: -1) } label: { Label(L10n.tr("上移", "Move Up"), systemImage: "arrow.up") }
                .disabled(displayKinds.first == tag)
            Button { moveKind(tag, by: 1) } label: { Label(L10n.tr("下移", "Move Down"), systemImage: "arrow.down") }
                .disabled(displayKinds.last == tag)
            Divider()
            Button { beginRoomOrder(target: .kinds) } label: { Label(L10n.tr("排序类型…", "Reorder Kinds…"), systemImage: "arrow.up.arrow.down") }
        }
    }
}
