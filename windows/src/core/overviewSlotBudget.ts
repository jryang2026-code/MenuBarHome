/**
 * Pure first-screen slot-budget selector (R16 §1.4 / HA `common-controls` model).
 * Mirrored from `Sources/MijiaCore/OverviewSlotBudget.swift`; both ends share
 * `Tests/Fixtures/slot_budget_golden.json`.
 */
export type OverviewSlotSize = "small" | "half" | "hero" | "full" | "panel";

export interface OverviewSlotItem {
  readonly id: string;
  readonly size: OverviewSlotSize;
  readonly isPinned: boolean;
}

export interface OverviewSlotBudgetResult {
  readonly visibleIds: readonly string[];
  readonly hiddenIds: readonly string[];
  readonly usedSlots: number;
  readonly effectiveBudget: number;
  readonly hiddenCount: number;
  readonly hasOverflow: boolean;
}

/** 16 slots = 8 standard `half` (2×1) tiles, matching the previous fixed 8-device overview cap. */
export const DEFAULT_OVERVIEW_SLOT_BUDGET = 16;

export function overviewSlotCost(size: OverviewSlotSize): number {
  switch (size) {
    case "small":
      return 1;
    case "half":
      return 2;
    case "hero":
    case "full":
    case "panel":
      return 4;
  }
}

export function selectOverviewSlotBudget(options: {
  readonly items: readonly OverviewSlotItem[];
  readonly budget?: number;
  readonly keepingVisibleIds?: ReadonlySet<string>;
}): OverviewSlotBudgetResult {
  const { items, keepingVisibleIds } = options;
  const clampedBudget = Math.max(0, options.budget ?? DEFAULT_OVERVIEW_SLOT_BUDGET);
  const selectedIds = new Set<string>();
  let pinnedCost = 0;

  for (const item of items) {
    if (item.isPinned && !selectedIds.has(item.id)) {
      selectedIds.add(item.id);
      pinnedCost += overviewSlotCost(item.size);
    }
  }

  const effectiveBudget = Math.max(clampedBudget, pinnedCost);
  let remaining = Math.max(0, effectiveBudget - pinnedCost);

  for (const item of items) {
    if (item.isPinned || selectedIds.has(item.id)) continue;
    const cost = overviewSlotCost(item.size);
    if (cost <= remaining) {
      selectedIds.add(item.id);
      remaining -= cost;
    }
  }

  if (keepingVisibleIds && keepingVisibleIds.size > 0) {
    for (const item of items) {
      if (keepingVisibleIds.has(item.id)) {
        selectedIds.add(item.id);
      }
    }
  }

  const visibleIds: string[] = [];
  const hiddenIds: string[] = [];
  let usedSlots = 0;
  const seen = new Set<string>();
  for (const item of items) {
    if (seen.has(item.id)) continue;
    seen.add(item.id);
    if (selectedIds.has(item.id)) {
      visibleIds.push(item.id);
      usedSlots += overviewSlotCost(item.size);
    } else {
      hiddenIds.push(item.id);
    }
  }

  return {
    visibleIds,
    hiddenIds,
    usedSlots,
    effectiveBudget,
    hiddenCount: hiddenIds.length,
    hasOverflow: hiddenIds.length > 0,
  };
}
