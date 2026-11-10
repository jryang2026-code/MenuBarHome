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

    /// Device ids in on-screen order; `index + 1` is the badge drawn on that card.
    private(set) var deviceIds: [String]

    init(deviceIds: [String] = []) {
        self.deviceIds = Array(deviceIds.prefix(Self.limit))
    }

    /// Walks the column's stacks in draw order, skipping folded stacks and stopping at the ninth
    /// badge. `cards` must report a stack's devices the way `deviceCollectionView` draws them.
    init<Stacks: Sequence>(
        stacks: Stacks,
        isOpen: (DeviceStack) -> Bool,
        cards: (DeviceStack) -> [SmartDevice]
    ) where Stacks.Element == DeviceStack {
        var ids: [String] = []
        for stack in stacks where isOpen(stack) {
            for device in cards(stack) {
                guard ids.count < Self.limit else { break }
                ids.append(device.id)
            }
            if ids.count == Self.limit { break }
        }
        deviceIds = ids
    }

    /// Badge numbers keyed by device id, for `DeviceCardView.quickIndex`.
    var badges: [String: Int] {
        Dictionary(uniqueKeysWithValues: deviceIds.enumerated().map { ($1, $0 + 1) })
    }
}

/// Where the panel's digit shortcuts find their device.
///
/// The Liquid Glass column folds multi-device groups into stacks, so its visible order is not
/// `HomeStore.orderedVisibleDevices`: a device inside a folded stack has no card and no badge,
/// while the next open group's card may carry badge 1. `HomeStore.selectQuickIndex` numbers the
/// whole visible list, so it would toggle the folded group's first device instead of the card the
/// user sees. The glass panel therefore publishes the order it actually draws — the same
/// `PanelQuickIndexOrder` its badges read — and the key monitor dispatches through it.
///
/// Lifecycle: the glass column registers on appear and whenever its drawn order changes, and
/// clears when it leaves the hierarchy (theme switch, room ordering, onboarding). Without a
/// registration the store's own order runs, so Classic keeps its original behaviour. `select` also
/// ignores a stale registration once the stored theme is no longer Liquid Glass, or when the
/// registered device is no longer visible (hidden, removed, or replaced by another backend).
@MainActor
final class PanelQuickIndexState {
    static let shared = PanelQuickIndexState()

    /// The order the mounted glass column draws; `nil` when no glass column owns the digits.
    private(set) var order: PanelQuickIndexOrder?

    func register(_ next: PanelQuickIndexOrder) {
        guard order != next else { return }
        order = next
    }

    func clear() {
        order = nil
    }

    /// Performs the digit `PanelKeyRouter` routed to `.selectQuickIndex`. `theme` is injectable so
    /// a test can pin the surface without touching the stored preference.
    func select(_ oneBasedIndex: Int, store: HomeStore, theme: PanelTheme = .current) {
        guard theme == .liquidGlass else {
            store.selectQuickIndex(oneBasedIndex)
            return
        }
        guard let order else {
            store.selectQuickIndex(oneBasedIndex)
            return
        }
        let index = oneBasedIndex - 1
        // A digit past the last badge has no card behind it; it must not fall back to the store's
        // longer list, which is exactly the folded-stack device this seam exists to avoid.
        guard order.deviceIds.indices.contains(index) else { return }
        let deviceId = order.deviceIds[index]
        // A device that left the visible list since the last draw is not the card under the badge.
        guard let device = store.visibleDevices.first(where: { $0.id == deviceId }) else { return }
        _ = store.togglePrimary(device)
    }
}
