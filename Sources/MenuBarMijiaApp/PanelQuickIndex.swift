import MijiaCore

/// The number keys' order for the panel that is on screen: the cards that carry a 1…9 badge, in
/// the order the column draws them.
///
/// The card badges and the digit dispatch both read this one list, so a digit can only control the
/// device under its badge. `cardOrder(in:)` supplies each stack's cards in their drawn order, and
/// folded stacks contribute no cards at all.
struct PanelQuickIndexOrder: Equatable {
    /// Every card that may show a badge, in draw order.
    static let limit = 9

    /// All drawn device ids in on-screen order, used by ↑/↓, Space and Return focus navigation.
    private(set) var navigableIds: [String]

    /// Device ids in on-screen order capped at `limit`; `index + 1` is the badge drawn on that card.
    private(set) var deviceIds: [String]

    init(deviceIds: [String] = []) {
        var seen = Set<String>()
        let deduped = deviceIds.filter { seen.insert($0).inserted }
        self.navigableIds = deduped
        self.deviceIds = Array(deduped.prefix(Self.limit))
    }

    /// Walks the column's stacks in draw order, skipping folded stacks. `cards` must report a
    /// stack's devices the way `deviceCollectionView` draws them.
    init<Stacks: Sequence>(
        stacks: Stacks,
        isOpen: (DeviceStack) -> Bool,
        cards: (DeviceStack) -> [SmartDevice]
    ) where Stacks.Element == DeviceStack {
        var allIds: [String] = []
        var seen = Set<String>()
        for stack in stacks where isOpen(stack) {
            for device in cards(stack) where seen.insert(device.id).inserted {
                allIds.append(device.id)
            }
        }
        navigableIds = allIds
        deviceIds = Array(allIds.prefix(Self.limit))
    }

    /// Badge numbers keyed by device id, for `DeviceCardView.quickIndex`.
    var badges: [String: Int] {
        Dictionary(uniqueKeysWithValues: deviceIds.enumerated().map { ($1, $0 + 1) })
    }
}

/// Where the panel's digit and focus shortcuts find their device.
///
/// Both themes reorder cards via `DeviceLayoutPrefs` and hide cards inside folded stacks (Liquid
/// Glass) or collapsed sections (Classic), so the visible order on screen is not
/// `HomeStore.orderedVisibleDevices`. Each mounted panel publishes the order it actually draws —
/// the same `PanelQuickIndexOrder` its badges read — and the key monitor dispatches digits, ↑/↓,
/// Space and Return through it.
///
/// Lifecycle: the active panel registers on appear and whenever its drawn order changes, and clears
/// its own registration when it leaves the hierarchy. Without a registration for the requested
/// theme, `HomeStore`'s default order runs so unmounted themes never leak into one another.
@MainActor
final class PanelQuickIndexState {
    static let shared = PanelQuickIndexState()

    /// The order the mounted panel draws; `nil` when no panel owns the shortcuts.
    private(set) var order: PanelQuickIndexOrder?
    private(set) var registeredTheme: PanelTheme?

    func register(_ next: PanelQuickIndexOrder, theme: PanelTheme = .liquidGlass) {
        guard order != next || registeredTheme != theme else { return }
        order = next
        registeredTheme = theme
    }

    func clear(theme: PanelTheme? = nil) {
        if let theme, registeredTheme != theme { return }
        order = nil
        registeredTheme = nil
    }

    private func activeOrder(for theme: PanelTheme) -> PanelQuickIndexOrder? {
        guard registeredTheme == theme else { return nil }
        return order
    }

    /// Performs the digit `PanelKeyRouter` routed to `.selectQuickIndex`. `theme` is injectable so
    /// a test can pin the surface without touching the stored preference.
    func select(_ oneBasedIndex: Int, store: HomeStore, theme: PanelTheme = .current) {
        guard let order = activeOrder(for: theme) else {
            store.selectQuickIndex(oneBasedIndex)
            return
        }
        let index = oneBasedIndex - 1
        // A digit past the last badge has no card behind it; it must not fall back to the store's
        // longer list, which is exactly the folded-stack / collapsed-group device this seam avoids.
        guard order.deviceIds.indices.contains(index) else { return }
        let deviceId = order.deviceIds[index]
        // A device that left the visible list since the last draw is not the card under the badge.
        guard let device = store.visibleDevices.first(where: { $0.id == deviceId }) else { return }
        _ = store.togglePrimary(device)
    }

    func moveFocus(delta: Int, store: HomeStore, theme: PanelTheme = .current) {
        if let order = activeOrder(for: theme) {
            store.moveFocus(delta: delta, in: order.navigableIds)
        } else {
            store.moveFocus(delta: delta)
        }
    }

    func toggleFocusedDevice(store: HomeStore, theme: PanelTheme = .current) {
        if let order = activeOrder(for: theme) {
            store.toggleFocusedDevice(in: order.navigableIds)
        } else {
            store.toggleFocusedDevice()
        }
    }
}
