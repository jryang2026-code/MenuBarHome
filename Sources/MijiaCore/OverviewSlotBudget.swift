import Foundation

/// Size classes used for first-screen slot-budget accounting (R16 §1.4).
/// Mirrored in `windows/src/core/overviewSlotBudget.ts`; both ends share `Tests/Fixtures/slot_budget_golden.json`.
public enum OverviewSlotSize: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case small
    case half
    case hero
    case full
    case panel

    /// Weighted slot cost on the 12-column grid:
    /// - `small` (1×1 round, 3 cols) = 1
    /// - `half`  (2×1 capsule, 6 cols) = 2
    /// - `hero`  (2×2 square, 6 cols × 2 rows) = 4
    /// - `full`  (4×1 full row, 12 cols) = 4
    /// - `panel` (4×N always expanded, 12 cols) = 4
    public var slotCost: Int {
        switch self {
        case .small: 1
        case .half: 2
        case .hero, .full, .panel: 4
        }
    }
}

/// One candidate device for first-screen slot-budget selection.
public struct OverviewSlotItem: Equatable, Sendable {
    public let id: String
    public let size: OverviewSlotSize
    public let isPinned: Bool

    public var cost: Int { size.slotCost }

    public init(id: String, size: OverviewSlotSize, isPinned: Bool) {
        self.id = id
        self.size = size
        self.isPinned = isPinned
    }
}

/// Result of applying the first-screen slot budget to an ordered list of online items.
public struct OverviewSlotBudgetResult: Equatable, Sendable {
    public let visibleIds: [String]
    public let hiddenIds: [String]
    public let usedSlots: Int
    public let effectiveBudget: Int

    public var hiddenCount: Int { hiddenIds.count }
    public var hasOverflow: Bool { !hiddenIds.isEmpty }

    public init(visibleIds: [String], hiddenIds: [String], usedSlots: Int, effectiveBudget: Int) {
        self.visibleIds = visibleIds
        self.hiddenIds = hiddenIds
        self.usedSlots = usedSlots
        self.effectiveBudget = effectiveBudget
    }
}

/// Pure first-screen slot-budget selector (R16 §1.4 / HA `common-controls` model):
/// - Pinned items always appear (`effectiveBudget = max(budget, pinnedCost)`).
/// - Remaining slots are filled in priority order by size weight; an oversized item is skipped
///   so smaller items behind it can still fit.
/// - Items in `keepingVisibleIds` (focused / expanded / pending confirmation) stay visible.
public enum OverviewSlotBudget {
    /// 16 slots = 8 standard `half` (2×1) tiles, matching the previous fixed 8-device overview cap
    /// on typical compact-grid layouts.
    public static let defaultBudget = 16

    public static func select(
        items: [OverviewSlotItem],
        budget: Int = defaultBudget,
        keepingVisibleIds: Set<String> = []
    ) -> OverviewSlotBudgetResult {
        let clampedBudget = max(0, budget)
        var selectedIds: Set<String> = []
        var pinnedCost = 0

        for item in items where item.isPinned {
            if selectedIds.insert(item.id).inserted {
                pinnedCost += item.cost
            }
        }

        let effectiveBudget = max(clampedBudget, pinnedCost)
        var remaining = max(0, effectiveBudget - pinnedCost)

        for item in items where !item.isPinned {
            guard !selectedIds.contains(item.id) else { continue }
            if item.cost <= remaining {
                selectedIds.insert(item.id)
                remaining -= item.cost
            }
        }

        for item in items where keepingVisibleIds.contains(item.id) {
            selectedIds.insert(item.id)
        }

        var visibleIds: [String] = []
        var hiddenIds: [String] = []
        var usedSlots = 0
        var seen: Set<String> = []
        for item in items where seen.insert(item.id).inserted {
            if selectedIds.contains(item.id) {
                visibleIds.append(item.id)
                usedSlots += item.cost
            } else {
                hiddenIds.append(item.id)
            }
        }

        return OverviewSlotBudgetResult(
            visibleIds: visibleIds,
            hiddenIds: hiddenIds,
            usedSlots: usedSlots,
            effectiveBudget: effectiveBudget
        )
    }
}
