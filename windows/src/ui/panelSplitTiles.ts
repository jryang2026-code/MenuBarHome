import { decayedHabitWeight, type HabitEntry } from "../core/assistant.js";
import {
  DEFAULT_OVERVIEW_SLOT_BUDGET,
  selectOverviewSlotBudget,
  type OverviewSlotSize,
} from "../core/overviewSlotBudget.js";
import {
  deviceCanTogglePower,
  devicePresentsAsActive,
  deviceReadout,
  hasDetailDrawer,
  type FacetControl,
  type SmartDevice,
} from "../core/models.js";
import {
  applyOrder,
  chosenSize,
  hiddenDeviceIds,
  isDevicePinned,
  pageSections,
  pinnedDeviceIds,
  resolvedSize,
  tr3,
  withAliases,
  type LayoutPrefs,
  type PageSection,
} from "./panelPrefs.js";
import { hasPlottableSensorMetrics } from "./sensorHistoryView.js";
import { SF_ICONS } from "./appConstants.js";
import type { PendingHighRiskConfirmation } from "./appTypes.js";

export const INITIAL_ALL_OVERVIEW_LIMIT = 8;
export const INITIAL_ALL_OVERVIEW_SLOT_BUDGET = DEFAULT_OVERVIEW_SLOT_BUDGET;

export type DeviceTilePrimaryAction = "togglePower" | "openCamera";

export type DeviceTileActionLayout =
  | { readonly kind: "split"; readonly primary: DeviceTilePrimaryAction }
  | { readonly kind: "primaryOnly"; readonly primary: DeviceTilePrimaryAction }
  | { readonly kind: "adjustOnly" }
  | { readonly kind: "readOnly" };

function filterUnsupportedEffectsForLayout(
  dev: SmartDevice,
  unsupportedLightEffects?: ReadonlySet<string>,
): SmartDevice {
  if (
    dev.kind.kind !== "light" ||
    !unsupportedLightEffects ||
    unsupportedLightEffects.size === 0 ||
    dev.kind.availableEffects.length === 0
  ) {
    return dev;
  }
  const normalizedUnsupported = new Set<string>();
  for (const entry of unsupportedLightEffects) {
    normalizedUnsupported.add(entry.trim().toLowerCase());
  }
  const idPrefix = `${dev.id}\u0000`.toLowerCase();
  const availableEffects = dev.kind.availableEffects.filter((effect) => {
    const lower = effect.trim().toLowerCase();
    return (
      !normalizedUnsupported.has(lower) &&
      !normalizedUnsupported.has(`${idPrefix}${lower}`) &&
      !unsupportedLightEffects.has(`${dev.id}\u0000${effect}`)
    );
  });
  if (availableEffects.length === dev.kind.availableEffects.length) return dev;
  return {
    ...dev,
    kind: {
      ...dev.kind,
      availableEffects,
    },
  };
}

/**
 * Resolves the 4-way compact tile interaction contract aligned with macOS WP2c (`DeviceTileActionLayout`):
 * - `split`: left primary action (toggle power or open live camera) + right adjustment drawer button
 * - `primaryOnly`: single primary action across the tile, no misleading chevron
 * - `adjustOnly`: no direct power toggle, tile / chevron opens adjustment or sensor history drawer
 * - `readOnly`: offline / unpowered or read-only device, never exposes an expandable chevron
 */
export function resolveDeviceTileActionLayout(
  dev: SmartDevice,
  facets: readonly FacetControl[] = [],
  unsupportedLightEffects?: ReadonlySet<string>,
): DeviceTileActionLayout {
  if (!dev.isOnline) {
    return { kind: "readOnly" };
  }
  const effectiveDev = filterUnsupportedEffectsForLayout(dev, unsupportedLightEffects);
  const canAdjust =
    hasDetailDrawer(effectiveDev, facets) ||
    (dev.kind.kind === "sensor" && hasPlottableSensorMetrics(dev, facets));

  const primary: DeviceTilePrimaryAction | null =
    dev.kind.kind === "camera"
      ? "openCamera"
      : deviceCanTogglePower(dev)
        ? "togglePower"
        : null;

  if (primary !== null && canAdjust) {
    return { kind: "split", primary };
  }
  if (primary !== null) {
    return { kind: "primaryOnly", primary };
  }
  if (canAdjust) {
    return { kind: "adjustOnly" };
  }
  return { kind: "readOnly" };
}

export function deviceAdjustAriaLabel(deviceName: string, isExpanded: boolean): string {
  return isExpanded
    ? tr3(`收起 ${deviceName} 详细控制`, `收起 ${deviceName} 詳細控制`, `Collapse ${deviceName} controls`)
    : tr3(`调节 ${deviceName}`, `調節 ${deviceName}`, `Adjust ${deviceName}`);
}

export function deviceAdjustTooltip(isExpanded: boolean): string {
  return isExpanded
    ? tr3("收起详细控制", "收起詳細控制", "Collapse controls")
    : tr3("展开详细控制", "展開詳細控制", "Adjust controls");
}

export function formatOfflineDrawerTitle(): string {
  return tr3("离线或未通电", "離線或未通電", "Offline or Unpowered");
}

export function formatOfflineDrawerBadge(count: number): string {
  return tr3(`${count} 台`, `${count} 台`, String(count));
}

export function formatOfflineDrawerSummary(devices: readonly SmartDevice[]): string {
  if (devices.length === 0) return "";
  const names = devices.slice(0, 2).map((d) => d.name);
  if (devices.length === 1) {
    return tr3(`${names[0]} 离线`, `${names[0]} 離線`, `${names[0]} offline`);
  }
  if (devices.length === 2) {
    return tr3(
      `${names[0]}、${names[1]} 离线`,
      `${names[0]}、${names[1]} 離線`,
      `${names[0]}, ${names[1]} offline`,
    );
  }
  return tr3(
    `${names[0]}、${names[1]} 等 ${devices.length} 台离线`,
    `${names[0]}、${names[1]} 等 ${devices.length} 台離線`,
    `${names[0]}, ${names[1]} and ${devices.length - 2} more offline`,
  );
}

export function formatLongTailExpandTitle(count: number): string {
  return tr3(
    `展开其余 ${count} 台设备`,
    `展開其餘 ${count} 台設備`,
    `Show ${count} More Devices`,
  );
}

export function formatLongTailCollapseTitle(): string {
  return tr3("收起其余设备", "收起其餘設備", "Show Less");
}

export function formatBrowseByRoomTitle(): string {
  return tr3("按房间找", "按房間找", "By Room");
}

export function computeHabitDeviceOrder(
  habitEntries: readonly HabitEntry[] | undefined,
  nowMs = Date.now(),
): string[] {
  if (!habitEntries || habitEntries.length === 0) return [];
  const stats = new Map<string, { score: number; lastMs: number }>();
  for (const entry of habitEntries) {
    const id = entry.targetId?.trim();
    if (!id) continue;
    const weight = decayedHabitWeight(entry.count, entry.lastRecordedAtMs, nowMs);
    const lastMs = entry.lastRecordedAtMs ?? Number.NEGATIVE_INFINITY;
    const prev = stats.get(id);
    if (prev) {
      prev.score += weight;
      if (lastMs > prev.lastMs) {
        prev.lastMs = lastMs;
      }
    } else {
      stats.set(id, { score: weight, lastMs });
    }
  }
  return Array.from(stats.entries())
    .sort((a, b) => {
      if (Math.abs(b[1].score - a[1].score) > 1e-6) {
        return b[1].score - a[1].score;
      }
      return b[1].lastMs - a[1].lastMs;
    })
    .map(([id]) => id);
}

export interface PanelPrioritySnapshot {
  readonly habitOrder: readonly string[];
  readonly activeByDeviceId: Readonly<Record<string, boolean>>;
}

export function prioritizeAllViewOnlineDevices(options: {
  readonly devices: readonly SmartDevice[];
  readonly pinnedIds: readonly string[];
  readonly habitOrder: readonly string[];
  readonly customOrder: readonly string[];
  readonly isActive: (device: SmartDevice) => boolean;
}): SmartDevice[] {
  const { devices, pinnedIds, habitOrder, customOrder, isActive } = options;
  if (customOrder.length > 0) {
    const byId = new Map(devices.map((device) => [device.id, device]));
    const explicit: SmartDevice[] = [];
    const seen = new Set<string>();
    for (const id of customOrder) {
      if (seen.has(id)) continue;
      const dev = byId.get(id);
      if (dev) {
        seen.add(id);
        explicit.push(dev);
      }
    }
    if (explicit.length === devices.length) {
      return explicit;
    }
    const remaining = devices.filter((device) => !seen.has(device.id));
    const prioritizedTail = prioritizeAllViewOnlineDevices({
      devices: remaining,
      pinnedIds,
      habitOrder,
      customOrder: [],
      isActive,
    });
    return [...explicit, ...prioritizedTail];
  }
  const favRank = new Map<string, number>();
  pinnedIds.forEach((id, idx) => {
    if (!favRank.has(id)) favRank.set(id, idx);
  });
  const habitRank = new Map<string, number>();
  habitOrder.forEach((id, idx) => {
    if (!habitRank.has(id)) habitRank.set(id, idx);
  });

  return devices
    .map((device, index) => ({ device, index }))
    .sort((lhs, rhs) => {
      const a = lhs.device;
      const b = rhs.device;
      const aFav = favRank.has(a.id);
      const bFav = favRank.has(b.id);
      if (aFav !== bFav) return aFav ? -1 : 1;
      if (aFav && bFav) {
        const fa = favRank.get(a.id)!;
        const fb = favRank.get(b.id)!;
        if (fa !== fb) return fa - fb;
      }

      const aActive = isActive(a);
      const bActive = isActive(b);
      if (aActive !== bActive) return aActive ? -1 : 1;

      const ha = habitRank.get(a.id) ?? Number.MAX_SAFE_INTEGER;
      const hb = habitRank.get(b.id) ?? Number.MAX_SAFE_INTEGER;
      if (ha !== hb) return ha - hb;

      return lhs.index - rhs.index;
    })
    .map((entry) => entry.device);
}

export interface PanelRoomBrowseOption {
  readonly id: string;
  readonly name: string;
  readonly onlineCount: number;
}

export interface PanelDeviceGridModel {
  readonly onlineSections: PageSection[];
  readonly visibleOnlineCount: number;
  readonly totalOnlineCount: number;
  readonly hiddenOnlineCount: number;
  readonly showsLongTailBar: boolean;
  readonly isLongTailExpanded: boolean;
  readonly roomBrowseOptions: readonly PanelRoomBrowseOption[];
  readonly offlineDevices: readonly SmartDevice[];
  readonly isOfflineDrawerExpanded: boolean;
  readonly offlineSummary: string;
}

export interface PanelSplitGridHost {
  readonly isEditingLayout: boolean;
  readonly listCut:
    | { readonly kind: "all" }
    | { readonly kind: "room"; readonly roomId: string; readonly roomName: string }
    | { readonly kind: "deviceKind"; readonly tag: string };
  readonly selectedRoom: string;
  readonly layout: LayoutPrefs;
  readonly devices: readonly SmartDevice[];
  readonly presentationDevices: readonly SmartDevice[];
  readonly roomOptions: ReadonlyArray<{ readonly id: string; readonly name: string }>;
  readonly expandedDeviceId: string | null;
  readonly pendingHighRisk: PendingHighRiskConfirmation | null;
  readonly waitingDeviceIds: ReadonlySet<string>;
  readonly valuesAreStale: boolean;
  readonly settings: {
    readonly hideOfflineDevices: boolean;
    readonly isCompactGridMode?: boolean;
    readonly climatePanel?: boolean;
    readonly habitEntries?: readonly HabitEntry[];
  };
  isLongTailExpanded: boolean;
  isOfflineDrawerExpanded: boolean;
  isRoomBrowseMenuOpen: boolean;
  hasInteractedInPanelSession: boolean;
  prioritySnapshot: PanelPrioritySnapshot | null;
}

export function captureOrFreezePrioritySnapshot(
  host: PanelSplitGridHost,
  nowMs = Date.now(),
): PanelPrioritySnapshot {
  const freshActive: Record<string, boolean> = {};
  for (const dev of host.devices) {
    const readout = deviceReadout(host.waitingDeviceIds.has(dev.id), host.valuesAreStale);
    freshActive[dev.id] = devicePresentsAsActive(dev, readout === "possiblyStale");
  }
  for (const dev of host.presentationDevices) {
    if (!(dev.id in freshActive)) {
      const readout = deviceReadout(host.waitingDeviceIds.has(dev.id), host.valuesAreStale);
      freshActive[dev.id] = devicePresentsAsActive(dev, readout === "possiblyStale");
    }
  }
  const freshHabitOrder = computeHabitDeviceOrder(host.settings.habitEntries, nowMs);

  if (!host.hasInteractedInPanelSession || host.prioritySnapshot === null) {
    const next: PanelPrioritySnapshot = {
      habitOrder: freshHabitOrder,
      activeByDeviceId: freshActive,
    };
    host.prioritySnapshot = next;
    return next;
  }

  const prev = host.prioritySnapshot;
  let mergedActive: Record<string, boolean> | null = null;
  for (const [id, active] of Object.entries(freshActive)) {
    if (!(id in prev.activeByDeviceId)) {
      if (!mergedActive) mergedActive = { ...prev.activeByDeviceId };
      mergedActive[id] = active;
    }
  }
  if (!mergedActive) return prev;
  const updated: PanelPrioritySnapshot = {
    habitOrder: prev.habitOrder,
    activeByDeviceId: mergedActive,
  };
  host.prioritySnapshot = updated;
  return updated;
}

export function markPanelSessionInteraction(host: PanelSplitGridHost, nowMs = Date.now()): void {
  if (!host.hasInteractedInPanelSession) {
    captureOrFreezePrioritySnapshot(host, nowMs);
    host.hasInteractedInPanelSession = true;
  }
}

export function resetPanelSplitTransientState(host: {
  isLongTailExpanded: boolean;
  isOfflineDrawerExpanded: boolean;
  isRoomBrowseMenuOpen: boolean;
  hasInteractedInPanelSession: boolean;
  prioritySnapshot: PanelPrioritySnapshot | null;
}): void {
  host.isLongTailExpanded = false;
  host.isOfflineDrawerExpanded = false;
  host.isRoomBrowseMenuOpen = false;
  host.hasInteractedInPanelSession = false;
  host.prioritySnapshot = null;
}

export function buildPanelDeviceGridModel(
  host: PanelSplitGridHost,
  nowMs = Date.now(),
): PanelDeviceGridModel {
  const isAllCut = host.listCut.kind === "all";
  const isAllRoom = host.selectedRoom === "全部";

  if (host.isEditingLayout) {
    const ordered = withAliases(host.layout, applyOrder(host.layout.order, host.presentationDevices));
    const sections = pageSections(host.layout, ordered, isAllRoom);
    return {
      onlineSections: sections,
      visibleOnlineCount: ordered.length,
      totalOnlineCount: ordered.length,
      hiddenOnlineCount: 0,
      showsLongTailBar: false,
      isLongTailExpanded: false,
      roomBrowseOptions: [],
      offlineDevices: [],
      isOfflineDrawerExpanded: false,
      offlineSummary: "",
    };
  }

  const aliased = withAliases(host.layout, host.presentationDevices);
  const rawOnline = aliased.filter((d) => d.isOnline);
  const rawOffline = host.settings.hideOfflineDevices ? [] : aliased.filter((d) => !d.isOnline);
  const offlineDevices = applyOrder(host.layout.order, rawOffline);

  if (offlineDevices.length === 0 && host.isOfflineDrawerExpanded) {
    host.isOfflineDrawerExpanded = false;
  }

  const snapshot = captureOrFreezePrioritySnapshot(host, nowMs);
  const pinnedIds = pinnedDeviceIds(host.layout);

  const orderedOnline = isAllCut
    ? prioritizeAllViewOnlineDevices({
        devices: rawOnline,
        pinnedIds,
        habitOrder: snapshot.habitOrder,
        customOrder: host.layout.order,
        isActive: (dev) => {
          if (dev.id in snapshot.activeByDeviceId) {
            return snapshot.activeByDeviceId[dev.id]!;
          }
          const readout = deviceReadout(host.waitingDeviceIds.has(dev.id), host.valuesAreStale);
          return devicePresentsAsActive(dev, readout === "possiblyStale");
        },
      })
    : applyOrder(host.layout.order, rawOnline);

  const rawOnlineSections = pageSections(host.layout, orderedOnline, isAllRoom);
  const flatOnline = rawOnlineSections.flatMap((section) => section.devices);
  const totalOnlineCount = flatOnline.length;

  let onlineSections = rawOnlineSections;
  let visibleOnlineCount = totalOnlineCount;
  let hiddenOnlineCount = 0;
  let showsLongTailBar = false;

  if (isAllCut) {
    const keepVisibleIds = new Set<string>();
    if (host.expandedDeviceId) {
      keepVisibleIds.add(host.expandedDeviceId);
    }
    if (
      host.pendingHighRisk &&
      host.pendingHighRisk.expiresAtMs > nowMs &&
      host.pendingHighRisk.deviceId
    ) {
      keepVisibleIds.add(host.pendingHighRisk.deviceId);
    }
    const pinnedSet = new Set(pinnedIds);
    const compactGrid = host.settings.isCompactGridMode ?? true;
    const climatePanel = host.settings.climatePanel ?? true;
    const slotItems = flatOnline.map((dev) => {
      const size: OverviewSlotSize = resolvedSize(
        chosenSize(host.layout, host.selectedRoom, dev.id),
        dev,
        compactGrid,
        climatePanel,
      );
      return {
        id: dev.id,
        size,
        isPinned: pinnedSet.has(dev.id),
      };
    });
    const budgetResult = selectOverviewSlotBudget({
      items: slotItems,
      budget: INITIAL_ALL_OVERVIEW_SLOT_BUDGET,
      keepingVisibleIds: keepVisibleIds,
    });
    if (budgetResult.hasOverflow) {
      if (host.isLongTailExpanded) {
        showsLongTailBar = true;
      } else {
        const allowedIds = new Set(budgetResult.visibleIds);
        onlineSections = rawOnlineSections
          .map((section) => ({
            ...section,
            devices: section.devices.filter((dev) => allowedIds.has(dev.id)),
          }))
          .filter((section) => section.devices.length > 0);
        visibleOnlineCount = allowedIds.size;
        hiddenOnlineCount = Math.max(0, totalOnlineCount - visibleOnlineCount);
        showsLongTailBar = hiddenOnlineCount > 0;
      }
    } else if (host.isLongTailExpanded) {
      host.isLongTailExpanded = false;
    }
  } else if (host.isLongTailExpanded) {
    host.isLongTailExpanded = false;
  }

  let roomBrowseOptions: PanelRoomBrowseOption[] = [];
  if (showsLongTailBar && !host.isLongTailExpanded && host.roomOptions.length > 1) {
    const hiddenSet = new Set(hiddenDeviceIds(host.layout));
    const onlineByRoomId = new Map<string, number>();
    for (const dev of rawOnline) {
      if (hiddenSet.has(dev.id) || !dev.isOnline || !dev.roomId) continue;
      onlineByRoomId.set(dev.roomId, (onlineByRoomId.get(dev.roomId) ?? 0) + 1);
    }
    const visibleOnlineRooms = host.roomOptions
      .map((opt) => ({
        id: opt.id,
        name: opt.name,
        onlineCount: onlineByRoomId.get(opt.id) ?? 0,
      }))
      .filter((opt) => opt.onlineCount > 0);
    if (visibleOnlineRooms.length > 1) {
      roomBrowseOptions = visibleOnlineRooms;
    }
  }
  if (host.isRoomBrowseMenuOpen && roomBrowseOptions.length <= 1) {
    host.isRoomBrowseMenuOpen = false;
  }

  return {
    onlineSections,
    visibleOnlineCount,
    totalOnlineCount,
    hiddenOnlineCount,
    showsLongTailBar,
    isLongTailExpanded: host.isLongTailExpanded && showsLongTailBar,
    roomBrowseOptions,
    offlineDevices,
    isOfflineDrawerExpanded: host.isOfflineDrawerExpanded && offlineDevices.length > 0,
    offlineSummary: formatOfflineDrawerSummary(offlineDevices),
  };
}

export function renderLongTailBarHtml(
  model: PanelDeviceGridModel,
  isRoomMenuOpen: boolean,
  escapeHtml: (value: string) => string,
): string {
  if (!model.showsLongTailBar) return "";
  const toggleLabel = model.isLongTailExpanded
    ? formatLongTailCollapseTitle()
    : formatLongTailExpandTitle(model.hiddenOnlineCount);
  const toggleIcon = model.isLongTailExpanded ? SF_ICONS.chevronUp : SF_ICONS.chevronDown;
  const hasRoomBrowse = !model.isLongTailExpanded && model.roomBrowseOptions.length > 1;
  const browseTitle = formatBrowseByRoomTitle();
  const menuOpen = hasRoomBrowse && isRoomMenuOpen;

  const roomBrowseHtml = hasRoomBrowse
    ? `<div class="cc-room-browse-wrap">
        <button
          type="button"
          class="cc-long-tail-pill cc-room-browse-trigger ${menuOpen ? "is-open" : ""}"
          data-browse-room-toggle
          data-room-browse-trigger
          aria-haspopup="menu"
          aria-expanded="${menuOpen}"
          aria-label="${escapeHtml(browseTitle)}"
          title="${escapeHtml(tr3("按房间筛选设备", "按房間篩選設備", "Filter devices by room"))}"
        >
          <span class="cc-long-tail-icon" aria-hidden="true">${SF_ICONS.houseFill}</span>
          <span class="cc-long-tail-label">${escapeHtml(browseTitle)}</span>
        </button>
      </div>`
    : "";

  return `<div class="cc-long-tail-bar" data-long-tail-bar>
    <button
      type="button"
      class="cc-long-tail-pill cc-long-tail-expand"
      data-long-tail-toggle
      aria-expanded="${model.isLongTailExpanded}"
      aria-label="${escapeHtml(toggleLabel)}"
      title="${escapeHtml(toggleLabel)}"
    >
      <span class="cc-long-tail-icon" aria-hidden="true">${toggleIcon}</span>
      <span class="cc-long-tail-label">${escapeHtml(toggleLabel)}</span>
    </button>
    ${roomBrowseHtml}
  </div>`;
}

export function renderRoomBrowseMenuHtml(
  model: PanelDeviceGridModel,
  isRoomMenuOpen: boolean,
  escapeHtml: (value: string) => string,
): string {
  if (!model.showsLongTailBar || model.isLongTailExpanded || model.roomBrowseOptions.length <= 1 || !isRoomMenuOpen) {
    return "";
  }
  const browseTitle = formatBrowseByRoomTitle();
  return `<div class="cc-room-browse-menu" role="menu" data-browse-room-menu data-overlay-key="room-browse-menu" aria-label="${escapeHtml(browseTitle)}">
    ${model.roomBrowseOptions
      .map(
        (room, idx) => `<button
          type="button"
          role="menuitem"
          tabindex="${idx === 0 ? "0" : "-1"}"
          class="cc-room-browse-item"
          data-browse-room-id="${escapeHtml(room.id)}"
          data-browse-room-name="${escapeHtml(room.name)}"
        >
          <span class="cc-room-browse-name">${escapeHtml(room.name)}</span>
          <span class="cc-room-browse-count">${room.onlineCount}</span>
        </button>`,
      )
      .join("")}
  </div>`;
}

/**
 * Dynamically anchors `[data-browse-room-menu]` inside `.cc-popover` so it never clips against
 * `.cc-scroll-area` or overflows narrow/compact flyouts. Returns `false` if the trigger scrolled
 * completely out of `.cc-scroll-area`'s visible viewport and the menu should close.
 */
export function positionRoomBrowseMenu(root: ParentNode): boolean {
  const menu = root.querySelector<HTMLElement>("[data-browse-room-menu]");
  const trigger = root.querySelector<HTMLElement>("[data-browse-room-toggle]");
  const popover = root.querySelector<HTMLElement>(".cc-popover");
  if (!menu || !trigger || !popover) return true;

  const popoverRect = popover.getBoundingClientRect();
  const triggerRect = trigger.getBoundingClientRect();
  if (popoverRect.width <= 0 || popoverRect.height <= 0) return true;

  const scrollArea = root.querySelector<HTMLElement>(".cc-scroll-area");
  if (scrollArea) {
    const scrollRect = scrollArea.getBoundingClientRect();
    if (
      scrollRect.height > 0 &&
      (triggerRect.bottom <= scrollRect.top + 2 || triggerRect.top >= scrollRect.bottom - 2)
    ) {
      return false;
    }
  }

  const originLeft = popoverRect.left + popover.clientLeft;
  const originTop = popoverRect.top + popover.clientTop;
  const innerWidth = popover.clientWidth > 0 ? popover.clientWidth : popoverRect.width;
  const innerHeight = popover.clientHeight > 0 ? popover.clientHeight : popoverRect.height;

  const edgePad = 6;
  const gap = 6;
  const availWidth = Math.max(72, Math.floor(innerWidth - edgePad * 2));
  menu.style.maxWidth = `${availWidth}px`;
  menu.style.minWidth = `${Math.min(168, availWidth)}px`;
  menu.style.right = "auto";
  menu.style.bottom = "auto";
  menu.style.left = `${edgePad}px`;
  menu.style.top = `${edgePad}px`;
  menu.style.maxHeight = "none";

  const naturalHeight = Math.max(menu.scrollHeight + 2, 40);
  const idealHeight = Math.min(220, naturalHeight);
  const triggerTopRel = triggerRect.top - originTop;
  const triggerBottomRel = triggerRect.bottom - originTop;
  const spaceAbove = triggerTopRel - gap - edgePad;
  const spaceBelow = innerHeight - edgePad - (triggerBottomRel + gap);

  let openUp = true;
  let maxHeightPx: number;
  if (spaceAbove >= idealHeight) {
    openUp = true;
    maxHeightPx = Math.min(220, Math.floor(spaceAbove));
  } else if (spaceBelow >= idealHeight) {
    openUp = false;
    maxHeightPx = Math.min(220, Math.floor(spaceBelow));
  } else if (Math.max(spaceAbove, spaceBelow) >= 88) {
    openUp = spaceAbove >= spaceBelow;
    maxHeightPx = Math.min(220, Math.floor(openUp ? spaceAbove : spaceBelow));
  } else {
    openUp = spaceAbove >= spaceBelow;
    maxHeightPx = Math.min(220, Math.max(48, Math.floor(innerHeight - edgePad * 2)));
  }
  menu.style.maxHeight = `${maxHeightPx}px`;

  const measured = menu.getBoundingClientRect();
  const menuW = measured.width;
  const menuH = measured.height;
  const desiredLeft = triggerRect.right - originLeft - menuW;
  const clampedLeft = Math.min(
    Math.max(edgePad, desiredLeft),
    Math.max(edgePad, innerWidth - edgePad - menuW),
  );
  const desiredTop = openUp ? triggerTopRel - gap - menuH : triggerBottomRel + gap;
  const clampedTop = Math.min(
    Math.max(edgePad, desiredTop),
    Math.max(edgePad, innerHeight - edgePad - menuH),
  );

  menu.style.left = `${Math.round(clampedLeft)}px`;
  menu.style.top = `${Math.round(clampedTop)}px`;
  return true;
}

export function renderOfflineDrawerHtml(options: {
  readonly model: PanelDeviceGridModel;
  readonly renderTile: (device: SmartDevice, index: number) => string;
  readonly startIndex: number;
  readonly escapeHtml: (value: string) => string;
}): string {
  const { model, renderTile, startIndex, escapeHtml } = options;
  if (model.offlineDevices.length === 0) return "";
  const count = model.offlineDevices.length;
  const expanded = model.isOfflineDrawerExpanded;
  const title = formatOfflineDrawerTitle();
  const summary = model.offlineSummary;
  const badge = formatOfflineDrawerBadge(count);
  const ariaLabel = summary
    ? `${title}${tr3("，", "，", ", ")}${summary}`
    : title;
  const tooltip = expanded
    ? tr3("收起离线设备", "收起離線設備", "Collapse offline devices")
    : tr3("点击展开查看离线或未通电设备", "點擊展開查看離線或未通電設備", "Click to show offline or unpowered devices");

  let index = startIndex;
  const bodyHtml = expanded
    ? `<div class="cc-devices-grid is-flow cc-offline-drawer-grid" data-offline-drawer-grid>
        ${model.offlineDevices.map((dev) => renderTile(dev, index++)).join("")}
      </div>`
    : "";

  return `<section class="cc-offline-drawer ${expanded ? "is-expanded" : ""}" data-offline-drawer>
    <button
      type="button"
      class="cc-offline-drawer-toggle"
      data-offline-drawer-toggle
      aria-expanded="${expanded}"
      aria-label="${escapeHtml(ariaLabel)}"
      title="${escapeHtml(tooltip)}"
    >
      <span class="cc-offline-drawer-icon" aria-hidden="true">${SF_ICONS.wifiSlash}</span>
      <span class="cc-offline-drawer-copy">
        <span class="cc-offline-drawer-title">${escapeHtml(title)}</span>
        ${!expanded && summary ? `<span class="cc-offline-drawer-summary">${escapeHtml(summary)}</span>` : ""}
      </span>
      <span class="cc-offline-drawer-badge">${escapeHtml(badge)}</span>
      <span class="cc-offline-drawer-chevron ${expanded ? "is-open" : ""}" aria-hidden="true">${SF_ICONS.chevronRight}</span>
    </button>
    ${bodyHtml}
  </section>`;
}

export { isDevicePinned };
