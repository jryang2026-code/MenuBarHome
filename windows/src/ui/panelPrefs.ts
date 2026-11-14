import type { MiRoom } from "../core/miCloudClient.js";
import type { SmartDevice } from "../core/models.js";
import { currentLanguage, resolveLanguage, t } from "../core/i18n.js";
import { LEGACY_STORAGE_KEY, STORAGE_KEY } from "./appConstants.js";

export function tr3(zhHans: string, zhHant: string, en: string): string {
  const lang = resolveLanguage(currentLanguage(), []);
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

// Panel personalisation shared with the macOS app: per-page card sizes, custom order,
// user groups and local device names. Pure functions only, so they can be unit tested.

export type AppAppearance = "system" | "light" | "dark";

export const APPEARANCES: ReadonlyArray<{ readonly id: AppAppearance; readonly title: string }> = [
  { id: "system", get title() { return t("跟随系统"); } },
  { id: "light", get title() { return t("浅色"); } },
  { id: "dark", get title() { return t("深色"); } },
];

export function resolveAppearance(preference: AppAppearance, systemPrefersLight = false): "light" | "dark" {
  if (preference === "light") return "light";
  if (preference === "dark") return "dark";
  return systemPrefersLight ? "light" : "dark";
}

/**
 * Panel background opacity in percent (#252). WebView2 does not blur the desktop behind a
 * transparent window, so a bright or busy wallpaper shows through the panel; 100 is solid.
 */
export const PANEL_OPACITY_MIN = 60;
export const PANEL_OPACITY_MAX = 100;
export const DEFAULT_PANEL_OPACITY = 90;

/** Missing, non-numeric or out-of-range values fall back into 60–100; the default matches the pre-#252 look. */
export function normalizePanelOpacity(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_PANEL_OPACITY;
  return Math.min(PANEL_OPACITY_MAX, Math.max(PANEL_OPACITY_MIN, Math.round(value)));
}

/** The panel background CSS reads `--panel-opacity` as a 0.6–1 fraction. */
export function applyPanelOpacity(root: HTMLElement, percent: number): void {
  root.style.setProperty("--panel-opacity", String(normalizePanelOpacity(percent) / 100));
}

export type PanelHeight = "compact" | "standard" | "tall" | "max";

export const PANEL_HEIGHTS: ReadonlyArray<{ readonly id: PanelHeight; readonly title: string; readonly px: number }> = [
  { id: "compact", get title() { return t("紧凑"); }, px: 580 },
  { id: "standard", get title() { return t("标准"); }, px: 680 },
  { id: "tall", get title() { return t("加高"); }, px: 780 },
  { id: "max", get title() { return t("最大"); }, px: 0 },
];

/**
 * Where the panel opens inside the active monitor's work area (#204). `auto` follows the taskbar edge
 * and the tray icon; a corner pins it. The backend owns the persisted value because dragging the panel
 * updates it from the window event loop.
 */
export type PanelAnchor = "auto" | "topLeft" | "topRight" | "bottomLeft" | "bottomRight";

export interface PanelPlacement {
  readonly anchor: PanelAnchor;
}

export const PANEL_ANCHORS: ReadonlyArray<{ readonly id: PanelAnchor; readonly title: string }> = [
  { id: "auto", get title() { return t("跟随任务栏"); } },
  { id: "topLeft", get title() { return t("左上"); } },
  { id: "topRight", get title() { return t("右上"); } },
  { id: "bottomLeft", get title() { return t("左下"); } },
  { id: "bottomRight", get title() { return t("右下"); } },
];

/** Reads what the backend reports; an unknown or missing value keeps following the taskbar. */
export function parsePanelPlacement(value: unknown): PanelPlacement {
  const candidate = value !== null && typeof value === "object" && "anchor" in value ? value.anchor : undefined;
  const known = PANEL_ANCHORS.find((item) => item.id === candidate);
  return { anchor: known?.id ?? "auto" };
}

export type TileSize = "auto" | "small" | "half" | "hero" | "full" | "panel";

export function normalizeTileSize(raw: unknown): TileSize {
  if (raw === "1x1" || raw === "small") return "small";
  if (raw === "2x1" || raw === "half") return "half";
  if (raw === "1x2" || raw === "full") return "full";
  if (raw === "2x2" || raw === "hero") return "hero";
  if (raw === "panel") return "panel";
  return "auto";
}

export const TILE_SIZES: ReadonlyArray<{ readonly id: TileSize; readonly title: string }> = [
  { id: "auto", get title() { return t("自动"); } },
  { id: "small", get title() { return tr3("1×1 磁贴", "1×1 磁貼", "1×1 Tile"); } },
  { id: "half", get title() { return t("半行"); } },
  { id: "full", get title() { return t("整行"); } },
  { id: "hero", get title() { return tr3("2×2 大卡", "2×2 大卡", "2×2 Large"); } },
  { id: "panel", get title() { return t("展开面板"); } },
];

export interface DeviceGroup {
  readonly id: string;
  readonly name: string;
}

export interface LayoutPrefs {
  /** Keys are `deviceId` (all pages) or `<page>|<deviceId>` (one page). */
  tileSizes: Record<string, TileSize>;
  order: string[];
  groups: DeviceGroup[];
  groupMap: Record<string, string>;
  /** `<page>|<sectionId>` of folded sections. */
  collapsed: string[];
  aliases: Record<string, string>;
  pinnedDeviceIds?: string[];
  hiddenDeviceIds?: string[];
  roomOrder?: string[];
  roomAliases?: Record<string, string>;
  kindOrder?: string[];
}

export const emptyLayoutPrefs = (): LayoutPrefs => ({
  tileSizes: {},
  order: [],
  groups: [],
  groupMap: {},
  collapsed: [],
  aliases: {},
  pinnedDeviceIds: [],
  hiddenDeviceIds: [],
  roomOrder: [],
  roomAliases: {},
  kindOrder: [],
});

export interface ActiveLayoutHostRef {
  readonly root: HTMLElement;
  readonly devices: readonly SmartDevice[];
  readonly layout: LayoutPrefs;
  saveLayout(): void;
  render(): void;
}

const activeLayoutHosts = new Set<WeakRef<ActiveLayoutHostRef>>();

export function registerLayoutHost(host: ActiveLayoutHostRef): void {
  for (const ref of activeLayoutHosts) {
    const existing = ref.deref();
    if (!existing) {
      activeLayoutHosts.delete(ref);
      continue;
    }
    if (existing === host) return;
  }
  activeLayoutHosts.add(new WeakRef(host));
}

function liveLayoutHosts(): ActiveLayoutHostRef[] {
  const out: ActiveLayoutHostRef[] = [];
  for (const ref of activeLayoutHosts) {
    const host = ref.deref();
    if (!host) {
      activeLayoutHosts.delete(ref);
      continue;
    }
    out.push(host);
  }
  return out;
}

export function layoutForDevices(devices: readonly SmartDevice[]): LayoutPrefs | null {
  const hosts = liveLayoutHosts();
  for (let i = hosts.length - 1; i >= 0; i--) {
    const host = hosts[i]!;
    if (host.devices === devices) return host.layout;
  }
  return null;
}

function dedupeStrings(items: readonly unknown[] | undefined): string[] {
  if (!Array.isArray(items)) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of items) {
    if (typeof item !== "string") continue;
    const trimmed = item.trim();
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
  }
  return out;
}

function readStoredLayoutPrefs(): LayoutPrefs | null {
  if (typeof localStorage === "undefined") return null;
  try {
    const raw = localStorage.getItem(STORAGE_KEY) ?? localStorage.getItem(LEGACY_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { layout?: Partial<LayoutPrefs> } | null;
    if (!parsed || typeof parsed !== "object") return null;
    return { ...emptyLayoutPrefs(), ...(parsed.layout ?? {}) };
  } catch {
    return null;
  }
}

function writeStoredLayoutPatch(patch: Partial<LayoutPrefs>): void {
  if (typeof localStorage === "undefined") return;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
    const prevLayout =
      parsed && typeof parsed === "object" && parsed.layout && typeof parsed.layout === "object"
        ? (parsed.layout as Record<string, unknown>)
        : {};
    const next = {
      ...(parsed && typeof parsed === "object" ? parsed : {}),
      layout: { ...emptyLayoutPrefs(), ...prevLayout, ...patch },
    };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    return;
  }
}

function isCurrentDocumentHost(host: ActiveLayoutHostRef): boolean {
  if (!host.root.isConnected) return false;
  return typeof document === "undefined" || host.root.ownerDocument === document;
}

function currentConnectedHost(): ActiveLayoutHostRef | undefined {
  const hosts = liveLayoutHosts();
  for (let i = hosts.length - 1; i >= 0; i--) {
    const candidate = hosts[i]!;
    if (isCurrentDocumentHost(candidate)) return candidate;
  }
  return undefined;
}

function syncMountedHostsField<K extends "pinnedDeviceIds" | "hiddenDeviceIds">(
  key: K,
  nextValue: string[],
  mutatedPrefs?: LayoutPrefs,
): void {
  for (const host of liveLayoutHosts()) {
    if (mutatedPrefs && host.layout !== mutatedPrefs) continue;
    if (!mutatedPrefs && !isCurrentDocumentHost(host)) continue;
    host.layout[key] = [...nextValue];
  }
}

export function hiddenDeviceIds(prefs?: LayoutPrefs): string[] {
  if (prefs) return dedupeStrings(prefs.hiddenDeviceIds);
  const connected = currentConnectedHost();
  if (connected) return dedupeStrings(connected.layout.hiddenDeviceIds);
  const stored = readStoredLayoutPrefs();
  return stored ? dedupeStrings(stored.hiddenDeviceIds) : [];
}

export function isDeviceHidden(deviceId: string, prefs?: LayoutPrefs): boolean {
  return hiddenDeviceIds(prefs).includes(deviceId);
}

export function hideDevice(deviceId: string, prefs?: LayoutPrefs): string[] {
  const id = deviceId.trim();
  if (!id) return hiddenDeviceIds(prefs);
  const current = hiddenDeviceIds(prefs);
  const next = current.includes(id) ? current : [...current, id];
  if (prefs) {
    prefs.hiddenDeviceIds = next;
  } else {
    syncMountedHostsField("hiddenDeviceIds", next);
  }
  writeStoredLayoutPatch({ hiddenDeviceIds: next });
  return next;
}

export function unhideDevice(deviceId: string, prefs?: LayoutPrefs): string[] {
  const id = deviceId.trim();
  const current = hiddenDeviceIds(prefs);
  const next = current.filter((item) => item !== id);
  if (prefs) {
    prefs.hiddenDeviceIds = next;
  } else {
    syncMountedHostsField("hiddenDeviceIds", next);
  }
  writeStoredLayoutPatch({ hiddenDeviceIds: next });
  return next;
}

export function unhideAllDevices(prefs?: LayoutPrefs): string[] {
  if (prefs) {
    prefs.hiddenDeviceIds = [];
  } else {
    syncMountedHostsField("hiddenDeviceIds", []);
  }
  writeStoredLayoutPatch({ hiddenDeviceIds: [] });
  return [];
}

export function pinnedDeviceIds(prefs?: LayoutPrefs): string[] {
  if (prefs) return dedupeStrings(prefs.pinnedDeviceIds);
  const connected = currentConnectedHost();
  if (connected) return dedupeStrings(connected.layout.pinnedDeviceIds);
  const stored = readStoredLayoutPrefs();
  return stored ? dedupeStrings(stored.pinnedDeviceIds) : [];
}

export function isDevicePinned(deviceId: string, prefs?: LayoutPrefs): boolean {
  return pinnedDeviceIds(prefs).includes(deviceId);
}

export function pinDevice(deviceId: string, prefs?: LayoutPrefs): string[] {
  const id = deviceId.trim();
  if (!id) return pinnedDeviceIds(prefs);
  const current = pinnedDeviceIds(prefs);
  const next = current.includes(id) ? current : [...current, id];
  if (prefs) {
    prefs.pinnedDeviceIds = next;
  } else {
    syncMountedHostsField("pinnedDeviceIds", next);
  }
  writeStoredLayoutPatch({ pinnedDeviceIds: next });
  return next;
}

export function unpinDevice(deviceId: string, prefs?: LayoutPrefs): string[] {
  const id = deviceId.trim();
  const current = pinnedDeviceIds(prefs);
  const next = current.filter((item) => item !== id);
  if (prefs) {
    prefs.pinnedDeviceIds = next;
  } else {
    syncMountedHostsField("pinnedDeviceIds", next);
  }
  writeStoredLayoutPatch({ pinnedDeviceIds: next });
  return next;
}

export function togglePinnedDevice(deviceId: string, prefs?: LayoutPrefs): boolean {
  if (isDevicePinned(deviceId, prefs)) {
    unpinDevice(deviceId, prefs);
    return false;
  }
  pinDevice(deviceId, prefs);
  return true;
}

export function movePinnedDevice(deviceId: string, direction: -1 | 1, prefs?: LayoutPrefs): string[] {
  const next = [...pinnedDeviceIds(prefs)];
  const idx = next.indexOf(deviceId);
  const targetIdx = idx + direction;
  if (idx < 0 || targetIdx < 0 || targetIdx >= next.length) return next;
  [next[idx], next[targetIdx]] = [next[targetIdx]!, next[idx]!];
  if (prefs) {
    prefs.pinnedDeviceIds = next;
  } else {
    syncMountedHostsField("pinnedDeviceIds", next);
  }
  writeStoredLayoutPatch({ pinnedDeviceIds: next });
  return next;
}

export function normalizeRoomAliases(aliases?: Readonly<Record<string, string>>): Record<string, string> {
  if (!aliases || typeof aliases !== "object") return {};
  const out: Record<string, string> = {};
  for (const [roomId, raw] of Object.entries(aliases)) {
    if (typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (roomId && trimmed) out[roomId] = trimmed;
  }
  return out;
}

export function roomDisplayName(
  prefs: Pick<LayoutPrefs, "roomAliases"> | null | undefined,
  roomId: string,
  originalName: string,
): string {
  const alias = prefs?.roomAliases?.[roomId]?.trim();
  return alias ? alias : originalName;
}

export function setRoomAlias(
  prefs: LayoutPrefs,
  roomId: string,
  rawAlias: string,
  originalName?: string,
): void {
  if (!roomId) return;
  const aliases = normalizeRoomAliases(prefs.roomAliases);
  const trimmed = rawAlias.trim();
  if (!trimmed || (originalName !== undefined && trimmed === originalName.trim())) {
    delete aliases[roomId];
  } else {
    aliases[roomId] = trimmed;
  }
  prefs.roomAliases = aliases;
}

export function seededRoomOrder(savedOrder: readonly string[] | undefined, visibleIds: readonly string[]): string[] {
  const next = dedupeStrings(savedOrder);
  const seen = new Set(next);
  for (const id of visibleIds) {
    if (id && !seen.has(id)) {
      seen.add(id);
      next.push(id);
    }
  }
  return next;
}

export function applyRoomOrder<T extends { readonly id: string; readonly name: string }>(
  prefs: Pick<LayoutPrefs, "roomOrder" | "roomAliases"> | null | undefined,
  rooms: readonly T[],
): T[] {
  const ordered = applyOrder(dedupeStrings(prefs?.roomOrder), rooms);
  const aliases = prefs?.roomAliases;
  if (!aliases) return ordered;
  return ordered.map((room) => {
    const alias = aliases[room.id]?.trim();
    return alias && alias !== room.name ? { ...room, name: alias } : room;
  });
}

export function applyKindOrder<T extends string>(
  savedKindOrder: readonly string[] | undefined,
  tags: readonly T[],
  fallbackRank: Readonly<Record<T, number>>,
): T[] {
  const order = dedupeStrings(savedKindOrder);
  const explicitRank = new Map<string, number>();
  order.forEach((tag, idx) => explicitRank.set(tag, idx));
  return [...tags].sort((a, b) => {
    const ra = explicitRank.get(a);
    const rb = explicitRank.get(b);
    if (ra !== undefined && rb !== undefined) return ra - rb;
    if (ra !== undefined) return -1;
    if (rb !== undefined) return 1;
    return (fallbackRank[a] ?? 999) - (fallbackRank[b] ?? 999);
  });
}

export function scopedKey(page: string, id: string): string {
  return `${page}|${id}`;
}

/** Size for a device on one page, falling back to the all-pages default. */
export function chosenSize(prefs: LayoutPrefs, page: string, id: string): TileSize {
  const raw = prefs.tileSizes[scopedKey(page, id)] ?? prefs.tileSizes[id];
  return raw !== undefined ? normalizeTileSize(raw) : "auto";
}

/** Resolves `auto` for the current grid mode; climate defaults to the full-row strip when enabled. */
export function resolvedSize(size: TileSize, device: SmartDevice, compactGrid: boolean, climatePanel: boolean): Exclude<TileSize, "auto"> {
  const normalized = normalizeTileSize(size);
  if (normalized !== "auto") return normalized;
  if (device.kind.kind === "climate" && climatePanel) return "full";
  return compactGrid ? "half" : "full";
}

export function nextSize(size: Exclude<TileSize, "auto">): Exclude<TileSize, "auto"> {
  // Windows still packs a 6-column grid without 2×2 rows, so its tap cycle keeps the original
  // three steps; `small`/`hero` arrive through the explicit 4-size picker or a saved macOS layout.
  if (size === "small") return "half";
  return size === "half" ? "full" : size === "full" ? "panel" : "half";
}

export interface TileResizeTranslation {
  readonly width: number;
  readonly height: number;
}

/** Drag distance in px that advances one size step (half ↔ full ↔ panel). */
export const RESIZE_STEP_THRESHOLD = 30;

const ORDERED_CONCRETE_TILE_SIZES: ReadonlyArray<Exclude<TileSize, "auto">> = ["half", "full", "panel"];

function resizeAxisSteps(delta: number, stepThreshold: number): number {
  if (delta > stepThreshold * 2) return 2;
  if (delta > stepThreshold) return 1;
  if (delta < -stepThreshold * 2) return -2;
  if (delta < -stepThreshold) return -1;
  return 0;
}

/**
 * Pure threshold resolver for the bottom-right corner arc resize gesture (#115).
 * Must stay semantically identical to `TileResizeGestureMath` in
 * `Sources/MenuBarMijiaApp/DeviceLayout.swift` — the two platforms mirror this contract
 * on purpose (same 30pt horizontal/vertical step thresholds, same half → full → panel order).
 */
export function targetSize(
  startSize: TileSize,
  translation: TileResizeTranslation,
  isCompactGrid = true,
): Exclude<TileSize, "auto"> {
  const normalizedStart = normalizeTileSize(startSize);
  const resolvedStart: Exclude<TileSize, "auto"> = normalizedStart === "auto" ? (isCompactGrid ? "half" : "full") : normalizedStart;
  // A 1×1 round button resizes from the capsule step; a 2×2 hero from the full-row step.
  const gestureStart: Exclude<TileSize, "auto"> =
    resolvedStart === "small" ? "half" : resolvedStart === "hero" ? "full" : resolvedStart;
  const startIndex = ORDERED_CONCRETE_TILE_SIZES.indexOf(gestureStart);
  const stepDelta =
    resizeAxisSteps(translation.width, RESIZE_STEP_THRESHOLD) +
    resizeAxisSteps(translation.height, RESIZE_STEP_THRESHOLD);
  const targetIndex = Math.min(Math.max(startIndex + stepDelta, 0), ORDERED_CONCRETE_TILE_SIZES.length - 1);
  return ORDERED_CONCRETE_TILE_SIZES[targetIndex] ?? resolvedStart;
}

export interface TileResizeSample {
  readonly x: number;
  readonly y: number;
  /** `performance.now()` milliseconds. */
  readonly t: number;
}

/** Pointer velocity in px/s from the last 100 ms of samples; zero when the pointer rested. */
export function releaseVelocity(samples: readonly TileResizeSample[], now: number): { x: number; y: number } {
  const recent = samples.filter((sample) => now - sample.t <= 100);
  if (recent.length < 2) return { x: 0, y: 0 };
  const first = recent[0]!;
  const last = recent.at(-1)!;
  const elapsed = last.t - first.t;
  if (elapsed < 8 || now - last.t > 60) return { x: 0, y: 0 };
  return { x: (last.x - first.x) / (elapsed / 1000), y: (last.y - first.y) / (elapsed / 1000) };
}

/** Flick projection (rate 0.99, iOS deceleration): clamped to one threshold per axis. */
export function projectedOffset(velocity: { x: number; y: number }, threshold = RESIZE_STEP_THRESHOLD): { width: number; height: number } {
  const project = (v: number) => Math.max(-threshold, Math.min(threshold, v * 0.099));
  return { width: project(velocity.x), height: project(velocity.y) };
}

/** Sorts by the saved order; devices not in it keep their incoming order after the known ones. */
export function applyOrder<T extends { readonly id: string }>(order: readonly string[], devices: readonly T[]): T[] {
  if (order.length === 0) return [...devices];
  const rank = new Map<string, number>();
  order.forEach((id, i) => { if (!rank.has(id)) rank.set(id, i); });
  return devices
    .map((d, i) => ({ d, r: rank.get(d.id) ?? order.length + i }))
    .sort((a, b) => a.r - b.r)
    .map((x) => x.d);
}

/** Moves `dragged` before/after `target`, seeding the order from `allIds` so unknown ids keep their place. */
export function moveInOrder(order: readonly string[], allIds: readonly string[], dragged: string, target: string, after: boolean): string[] {
  const next = [...order];
  for (const id of allIds) if (!next.includes(id)) next.push(id);
  if (!next.includes(dragged) || !next.includes(target) || dragged === target) return next;
  const without = next.filter((id) => id !== dragged);
  const t = without.indexOf(target);
  without.splice(after ? t + 1 : t, 0, dragged);
  return without;
}

/** Column span out of 6: small/half = 3, hero/full/panel = 6. */
export function spans(
  devices: readonly SmartDevice[],
  sizeOf: (d: SmartDevice) => Exclude<TileSize, "auto">,
): Map<string, number> {
  const out = new Map<string, number>();
  for (const d of devices) {
    const size = sizeOf(d);
    out.set(d.id, size === "small" || size === "half" ? 3 : 6);
  }
  return out;
}

export interface PageSection {
  readonly id: string;
  readonly title: string | null;
  readonly devices: SmartDevice[];
  /** Set for user groups (rename / reorder / delete). */
  readonly groupId: string | null;
}

/**
 * Favorites ("常用") first on the All page, then user groups, then the ungrouped rest.
 * A page without any pinned or grouped device remains a single untitled section.
 */
export function pageSections(prefs: LayoutPrefs, devices: readonly SmartDevice[], isAllPage: boolean): PageSection[] {
  const pinnedOrder = isAllPage ? pinnedDeviceIds(prefs) : [];
  const pinnedSet = new Set(pinnedOrder);
  const known = new Set(prefs.groups.map((g) => g.id));
  const groupOf = (id: string): string | null => {
    const g = prefs.groupMap[id];
    return g && known.has(g) ? g : null;
  };
  const sections: PageSection[] = [];
  if (pinnedSet.size > 0) {
    const pinnedMembers = applyOrder(
      pinnedOrder,
      devices.filter((d) => pinnedSet.has(d.id)),
    );
    if (pinnedMembers.length > 0) {
      sections.push({
        id: "pinned",
        title: tr3("常用", "常用", "Favorites"),
        devices: pinnedMembers,
        groupId: null,
      });
    }
  }
  const remaining = pinnedSet.size > 0 ? devices.filter((d) => !pinnedSet.has(d.id)) : devices;
  for (const g of prefs.groups) {
    const members = remaining.filter((d) => groupOf(d.id) === g.id);
    if (members.length > 0) sections.push({ id: g.id, title: g.name, devices: members, groupId: g.id });
  }
  const rest = remaining.filter((d) => groupOf(d.id) === null);
  if (rest.length > 0) {
    const title = sections.length === 0 ? null : isAllPage ? t("更多设备") : t("其他");
    sections.push({ id: "rest", title, devices: rest, groupId: null });
  }
  return sections;
}

const renderedPinnedDevices = new WeakMap<SmartDevice, boolean>();

export function isRenderedDevicePinned(device: SmartDevice): boolean {
  return renderedPinnedDevices.get(device) === true;
}

export function withAliases(prefs: LayoutPrefs, devices: readonly SmartDevice[]): SmartDevice[] {
  const pinnedSet = new Set(pinnedDeviceIds(prefs));
  const roomAliases = prefs.roomAliases;
  return devices.map((d) => {
    const devAlias = prefs.aliases[d.id];
    const roomAlias = d.roomId && roomAliases ? roomAliases[d.roomId]?.trim() : undefined;
    const nextRoomName = roomAlias && roomAlias !== d.roomName ? roomAlias : d.roomName;
    const next =
      devAlias || nextRoomName !== d.roomName
        ? {
            ...d,
            ...(devAlias ? { name: devAlias } : {}),
            ...(nextRoomName !== d.roomName ? { roomName: nextRoomName } : {}),
          }
        : d;
    renderedPinnedDevices.set(next, pinnedSet.has(d.id));
    return next;
  });
}

export interface HomeOption {
  readonly id: string;
  readonly name: string;
  readonly deviceCount: number;
}

/** One entry per Mi Home, in cloud order, counting unique dids. */
export function homeOptions(rooms: readonly MiRoom[]): HomeOption[] {
  const order: string[] = [];
  const names = new Map<string, string>();
  const dids = new Map<string, Set<string>>();
  for (const r of rooms) {
    const hid = r.homeId ?? "";
    if (!hid) continue;
    if (!names.has(hid)) { order.push(hid); names.set(hid, r.homeName ?? ""); dids.set(hid, new Set()); }
    for (const d of r.dids) dids.get(hid)?.add(d);
  }
  return order.map((id) => ({ id, name: names.get(id) ?? "", deviceCount: dids.get(id)?.size ?? 0 }));
}

export type ComfortLevel = "warm" | "cool" | "dry" | "humid" | "comfy";

export function comfort(temperature: number | null, humidity: number | null): { level: ComfortLevel; label: string } {
  const t0 = temperature ?? 24;
  const h = humidity ?? 50;
  if (t0 >= 28) return { level: "warm", label: t("偏热") };
  if (t0 <= 16) return { level: "cool", label: t("偏冷") };
  if (h < 35) return { level: "dry", label: t("偏干") };
  if (h > 70) return { level: "humid", label: t("偏湿") };
  return { level: "comfy", label: t("舒适") };
}

const EFFECT_NAMES: Record<string, string> = {
  Day: "日光", Night: "月光", None: "无", Warmth: "温馨", Tv: "观影", TV: "观影", Reading: "阅读",
  Computer: "电脑", Hospitality: "会客", Entertainment: "娱乐", Wakeup: "起床", Dusk: "黄昏", Sleep: "睡眠",
};

export function localizeEffect(effect: string): string {
  const key = EFFECT_NAMES[effect];
  return key === undefined ? effect : t(key);
}

const FAN_NAMES: Record<string, string> = { auto: "自动", low: "低", silent: "低", quiet: "低", medium: "中", middle: "中", high: "高" };

export function localizeFanMode(raw: string): string {
  const lower = raw.toLowerCase();
  const key = FAN_NAMES[lower];
  if (key !== undefined) return t(key);
  const m = /^level\s*(\d+)$/.exec(lower);
  return m ? t("{level} 档", { level: m[1] ?? "" }) : raw;
}

// MARK: - Customizable Global Shortcut (#43)

export const DEFAULT_GLOBAL_SHORTCUT = "Alt+M";

const CANONICAL_MODIFIERS = ["Ctrl", "Alt", "Shift", "Super"] as const;
type ShortcutModifier = (typeof CANONICAL_MODIFIERS)[number];

const MODIFIER_ALIASES: Record<string, ShortcutModifier> = {
  ctrl: "Ctrl",
  control: "Ctrl",
  alt: "Alt",
  option: "Alt",
  shift: "Shift",
  super: "Super",
  meta: "Super",
  win: "Super",
  cmd: "Super",
  command: "Super",
};

const SPECIAL_KEY_ALIASES: Record<string, string> = {
  space: "Space",
  tab: "Tab",
  enter: "Enter",
  return: "Enter",
  backspace: "Backspace",
  delete: "Delete",
  del: "Delete",
  insert: "Insert",
  home: "Home",
  end: "End",
  pageup: "PageUp",
  pgup: "PageUp",
  pagedown: "PageDown",
  pgdn: "PageDown",
  up: "ArrowUp",
  arrowup: "ArrowUp",
  down: "ArrowDown",
  arrowdown: "ArrowDown",
  left: "ArrowLeft",
  arrowleft: "ArrowLeft",
  right: "ArrowRight",
  arrowright: "ArrowRight",
  minus: "Minus",
  "-": "Minus",
  equal: "Equal",
  "=": "Equal",
  bracketleft: "BracketLeft",
  "[": "BracketLeft",
  bracketright: "BracketRight",
  "]": "BracketRight",
  backslash: "Backslash",
  "\\": "Backslash",
  semicolon: "Semicolon",
  ";": "Semicolon",
  quote: "Quote",
  "'": "Quote",
  backquote: "Backquote",
  "`": "Backquote",
  comma: "Comma",
  ",": "Comma",
  period: "Period",
  ".": "Period",
  slash: "Slash",
  "/": "Slash",
};

function normalizeKeyToken(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  if (/^[a-zA-Z]$/.test(trimmed)) return trimmed.toUpperCase();
  if (/^[0-9]$/.test(trimmed)) return trimmed;
  const keyMatch = /^key([a-z])$/i.exec(trimmed);
  if (keyMatch) return keyMatch[1]!.toUpperCase();
  const digitMatch = /^digit([0-9])$/i.exec(trimmed);
  if (digitMatch) return digitMatch[1]!;
  const numpadMatch = /^numpad([0-9])$/i.exec(trimmed);
  if (numpadMatch) return `Numpad${numpadMatch[1]!}`;
  const fnMatch = /^f([1-9]|1[0-9]|20)$/i.exec(trimmed);
  if (fnMatch) return `F${fnMatch[1]}`;
  const special = SPECIAL_KEY_ALIASES[trimmed.toLowerCase()];
  return special ?? null;
}

function isFunctionKeyToken(keyToken: string): boolean {
  return /^F([1-9]|1[0-9]|20)$/.test(keyToken);
}

/**
 * Parses and validates a shortcut string into canonical `Ctrl+Alt+Shift+Super+<Key>` order.
 * Requires at least one modifier or a standalone F1–F20 key so a plain letter cannot hijack typing.
 */
export function parseGlobalShortcut(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const parts = raw
    .split("+")
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  if (parts.length === 0) return null;

  const mods = new Set<ShortcutModifier>();
  let mainKey: string | null = null;
  for (const part of parts) {
    const mod = MODIFIER_ALIASES[part.toLowerCase()];
    if (mod) {
      mods.add(mod);
      continue;
    }
    if (mainKey !== null) return null;
    const normalizedKey = normalizeKeyToken(part);
    if (!normalizedKey) return null;
    mainKey = normalizedKey;
  }

  if (!mainKey) return null;
  if (mods.size === 0 && !isFunctionKeyToken(mainKey)) return null;

  const orderedMods = CANONICAL_MODIFIERS.filter((m) => mods.has(m));
  return [...orderedMods, mainKey].join("+");
}

export function isValidGlobalShortcut(raw: unknown): boolean {
  return parseGlobalShortcut(raw) !== null;
}

export function normalizeGlobalShortcut(raw: unknown): string {
  return parseGlobalShortcut(raw) ?? DEFAULT_GLOBAL_SHORTCUT;
}

export interface KeyEventLike {
  readonly key: string;
  readonly code?: string;
  readonly ctrlKey?: boolean;
  readonly altKey?: boolean;
  readonly shiftKey?: boolean;
  readonly metaKey?: boolean;
}

export type RecordedShortcutOutcome =
  | { readonly kind: "cancel" }
  | { readonly kind: "modifier-only" }
  | { readonly kind: "invalid" }
  | { readonly kind: "recorded"; readonly shortcut: string };

const IGNORED_MODIFIER_KEYS = new Set(["control", "ctrl", "alt", "shift", "meta", "os", "super"]);

/** Turns a DOM `keydown` event into a recorded global shortcut or a state transition (#43). */
export function recordShortcutFromKeyEvent(event: KeyEventLike): RecordedShortcutOutcome {
  const keyLower = (event.key ?? "").toLowerCase();
  if (keyLower === "escape" || (event.code ?? "").toLowerCase() === "escape") {
    return { kind: "cancel" };
  }
  if (IGNORED_MODIFIER_KEYS.has(keyLower)) {
    return { kind: "modifier-only" };
  }

  const rawCode = (event.code ?? "").trim();
  const keyToken =
    rawCode.length > 0
      ? normalizeKeyToken(rawCode)
      : event.key === " "
        ? "Space"
        : normalizeKeyToken(event.key ?? "");
  if (!keyToken) {
    return { kind: "invalid" };
  }

  const mods: ShortcutModifier[] = [];
  if (event.ctrlKey) mods.push("Ctrl");
  if (event.altKey) mods.push("Alt");
  if (event.shiftKey) mods.push("Shift");
  if (event.metaKey) mods.push("Super");

  const candidate = [...mods, keyToken].join("+");
  const normalized = parseGlobalShortcut(candidate);
  if (!normalized) {
    return { kind: "invalid" };
  }
  return { kind: "recorded", shortcut: normalized };
}
