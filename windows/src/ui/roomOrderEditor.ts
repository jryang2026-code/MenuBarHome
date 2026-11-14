import { t } from "../core/i18n.js";
import type { SmartDevice } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { KIND_CHIP, KIND_RANK, type DeviceKindTag, type RoomOption } from "./listCut.js";
import {
  applyKindOrder,
  applyRoomOrder,
  hiddenDeviceIds,
  hideDevice,
  movePinnedDevice,
  normalizeRoomAliases,
  roomDisplayName,
  seededRoomOrder,
  togglePinnedDevice,
  tr3,
  unhideAllDevices,
  unhideDevice,
} from "./panelPrefs.js";

export type RoomOrderEditorTab = "rooms" | "kinds";

export class RoomOrderDraft {
  public readonly originalOrder: readonly string[];
  public readonly originalAliases: Readonly<Record<string, string>>;
  public order: string[];
  public aliases: Record<string, string>;

  constructor(options: {
    readonly savedOrder?: readonly string[];
    readonly savedAliases?: Readonly<Record<string, string>>;
    readonly visibleIds: readonly string[];
  }) {
    const seeded = seededRoomOrder(options.savedOrder, options.visibleIds);
    const normalizedAliases = normalizeRoomAliases(options.savedAliases);
    this.originalOrder = [...seeded];
    this.originalAliases = { ...normalizedAliases };
    this.order = [...seeded];
    this.aliases = { ...normalizedAliases };
  }

  public visibleOrder(visibleIds: readonly string[]): string[] {
    const visibleSet = new Set(visibleIds);
    const seeded = seededRoomOrder(this.order, visibleIds);
    return seeded.filter((id) => visibleSet.has(id));
  }

  private writeVisibleSlots(nextVisible: readonly string[], visibleSet: ReadonlySet<string>): void {
    const base = seededRoomOrder(this.order, nextVisible);
    let cursor = 0;
    this.order = base.map((id) => {
      if (!visibleSet.has(id)) return id;
      const replacement = nextVisible[cursor];
      cursor += 1;
      return replacement ?? id;
    });
  }

  public move(id: string, direction: -1 | 1, visibleIds: readonly string[]): boolean {
    const visibleSet = new Set(visibleIds);
    const current = this.visibleOrder(visibleIds);
    const idx = current.indexOf(id);
    const targetIdx = idx + direction;
    if (idx < 0 || targetIdx < 0 || targetIdx >= current.length) return false;
    [current[idx], current[targetIdx]] = [current[targetIdx]!, current[idx]!];
    this.writeVisibleSlots(current, visibleSet);
    return true;
  }

  public moveToEdge(id: string, toStart: boolean, visibleIds: readonly string[]): boolean {
    const visibleSet = new Set(visibleIds);
    const current = this.visibleOrder(visibleIds);
    const idx = current.indexOf(id);
    if (idx < 0) return false;
    if ((toStart && idx === 0) || (!toStart && idx === current.length - 1)) return false;
    const [picked] = current.splice(idx, 1);
    if (!picked) return false;
    if (toStart) current.unshift(picked);
    else current.push(picked);
    this.writeVisibleSlots(current, visibleSet);
    return true;
  }

  public reorderVisible(
    draggedId: string,
    targetId: string,
    after: boolean,
    visibleIds: readonly string[],
  ): boolean {
    if (!draggedId || !targetId || draggedId === targetId) return false;
    const visibleSet = new Set(visibleIds);
    const current = this.visibleOrder(visibleIds);
    if (!current.includes(draggedId) || !current.includes(targetId)) return false;
    const without = current.filter((item) => item !== draggedId);
    const targetIdx = without.indexOf(targetId);
    if (targetIdx < 0) return false;
    without.splice(after ? targetIdx + 1 : targetIdx, 0, draggedId);
    this.writeVisibleSlots(without, visibleSet);
    return true;
  }

  public restoreDefaultOrder(defaultVisibleIds: readonly string[]): void {
    const dedupedDefaults: string[] = [];
    const seen = new Set<string>();
    for (const id of defaultVisibleIds) {
      if (id && !seen.has(id)) {
        seen.add(id);
        dedupedDefaults.push(id);
      }
    }
    this.writeVisibleSlots(dedupedDefaults, seen);
  }

  public setAlias(roomId: string, rawText: string, originalName?: string): void {
    if (!roomId) return;
    const trimmed = rawText.trim();
    if (!trimmed || (originalName !== undefined && trimmed === originalName.trim())) {
      delete this.aliases[roomId];
    } else {
      this.aliases[roomId] = trimmed;
    }
  }

  public aliasFor(roomId: string): string {
    return this.aliases[roomId] ?? "";
  }

  public isDefaultOrder(defaultVisibleIds: readonly string[]): boolean {
    const current = this.visibleOrder(defaultVisibleIds);
    if (current.length !== defaultVisibleIds.length) return false;
    return current.every((id, idx) => id === defaultVisibleIds[idx]);
  }

  public get hasUnsavedChanges(): boolean {
    if (this.order.length !== this.originalOrder.length) return true;
    if (this.order.some((id, idx) => id !== this.originalOrder[idx])) return true;
    const keysA = Object.keys(this.aliases);
    const keysB = Object.keys(this.originalAliases);
    if (keysA.length !== keysB.length) return true;
    return keysA.some((key) => this.aliases[key] !== this.originalAliases[key]);
  }
}

export interface RoomOrderEditorSession {
  tab: RoomOrderEditorTab;
  focusRoomId: string | null;
  readonly roomDraft: RoomOrderDraft;
  readonly kindDraft: RoomOrderDraft;
  draggingRowId: string | null;
}

const editorSessions = new WeakMap<MenuMijiaWindowsApp, RoomOrderEditorSession>();

export function snapshotRoomsForHost(devices: readonly SmartDevice[]): RoomOption[] {
  const seen = new Set<string>();
  const out: RoomOption[] = [];
  for (const dev of devices) {
    if (!dev.roomId || seen.has(dev.roomId)) continue;
    seen.add(dev.roomId);
    out.push({ id: dev.roomId, name: dev.roomName });
  }
  return out;
}

export function snapshotKindsForHost(devices: readonly SmartDevice[]): DeviceKindTag[] {
  const present = new Set<DeviceKindTag>();
  for (const dev of devices) present.add(dev.kind.kind);
  const allKnown = (Object.keys(KIND_RANK) as DeviceKindTag[]).sort((a, b) => KIND_RANK[a] - KIND_RANK[b]);
  const base = present.size >= 2 ? [...present].sort((a, b) => KIND_RANK[a] - KIND_RANK[b]) : allKnown;
  return base;
}

export function isRoomOrderEditorPrompt(host: MenuMijiaWindowsApp): boolean {
  return host.prompt !== null && host.prompt.kind === "roomOrderEditor";
}

export function isRoomOrderEditorOpen(host: MenuMijiaWindowsApp): boolean {
  if (!isRoomOrderEditorPrompt(host)) {
    editorSessions.delete(host);
    return false;
  }
  return editorSessions.has(host);
}

export function getRoomOrderEditorSession(host: MenuMijiaWindowsApp): RoomOrderEditorSession | null {
  return isRoomOrderEditorOpen(host) ? (editorSessions.get(host) ?? null) : null;
}

export function activeRoomOptions(host: MenuMijiaWindowsApp): RoomOption[] {
  const session = getRoomOrderEditorSession(host);
  const prefs = session
    ? { roomOrder: session.roomDraft.order, roomAliases: session.roomDraft.aliases }
    : host.layout;
  return applyRoomOrder(prefs, snapshotRoomsForHost(host.devices));
}

export function openRoomOrderEditor(
  host: MenuMijiaWindowsApp,
  options?: { readonly tab?: RoomOrderEditorTab; readonly focusRoomId?: string | null },
): RoomOrderEditorSession {
  const rooms = snapshotRoomsForHost(host.devices);
  const kinds = snapshotKindsForHost(host.devices);
  const session: RoomOrderEditorSession = {
    tab: options?.tab ?? "rooms",
    focusRoomId: options?.focusRoomId ?? null,
    roomDraft: new RoomOrderDraft({
      savedOrder: host.layout.roomOrder,
      savedAliases: host.layout.roomAliases,
      visibleIds: rooms.map((r) => r.id),
    }),
    kindDraft: new RoomOrderDraft({
      savedOrder: host.layout.kindOrder,
      visibleIds: kinds,
    }),
    draggingRowId: null,
  };
  editorSessions.set(host, session);
  host.openPrompt({ kind: "roomOrderEditor" });
  return session;
}

export function cancelRoomOrderEditor(host: MenuMijiaWindowsApp): void {
  editorSessions.delete(host);
  if (isRoomOrderEditorPrompt(host)) {
    host.closePrompt();
  } else {
    host.render();
  }
}

export function saveRoomOrderEditor(host: MenuMijiaWindowsApp): void {
  const session = editorSessions.get(host);
  if (!session) {
    if (isRoomOrderEditorPrompt(host)) host.closePrompt();
    return;
  }
  const roomsById = new Map(snapshotRoomsForHost(host.devices).map((r) => [r.id, r.name]));
  host.root.querySelectorAll<HTMLInputElement>("[data-room-alias-input]").forEach((input) => {
    const roomId = input.dataset.roomAliasInput ?? "";
    if (!roomId) return;
    session.roomDraft.setAlias(roomId, input.value, roomsById.get(roomId));
  });

  host.layout.roomOrder = [...session.roomDraft.order];
  host.layout.roomAliases = { ...session.roomDraft.aliases };
  host.layout.kindOrder = [...session.kindDraft.order];

  if (host.listCut.kind === "room") {
    const original = roomsById.get(host.listCut.roomId) ?? host.listCut.roomName;
    const updatedName = roomDisplayName(host.layout, host.listCut.roomId, original);
    host.selectRoom(host.listCut.roomId, updatedName);
  }

  editorSessions.delete(host);
  host.saveLayout();
  if (isRoomOrderEditorPrompt(host)) {
    host.closePrompt();
  } else {
    host.render();
  }
}

export function renderRoomOrderEditorModal(host: MenuMijiaWindowsApp): string {
  const session = getRoomOrderEditorSession(host);
  if (!session) return "";
  const escape = (v: string) => host.escapeHtml(v);
  const rooms = snapshotRoomsForHost(host.devices);
  const roomsById = new Map(rooms.map((r) => [r.id, r.name]));
  const visibleRoomIds = rooms.map((r) => r.id);
  const orderedRoomIds = session.roomDraft.visibleOrder(visibleRoomIds);
  const isRoomDefault = session.roomDraft.isDefaultOrder(visibleRoomIds);

  const defaultKinds = snapshotKindsForHost(host.devices);
  const orderedKinds = applyKindOrder(session.kindDraft.order, defaultKinds, KIND_RANK);
  const isKindDefault = session.kindDraft.isDefaultOrder(defaultKinds);

  const hiddenIds = new Set(hiddenDeviceIds(host.layout));
  const hiddenDevices = host.devices.filter((d) => hiddenIds.has(d.id));

  const roomsBody =
    orderedRoomIds.length === 0
      ? `<div class="cc-room-editor-empty">${escape(tr3("当前家庭暂无房间", "目前家庭暫無房間", "No rooms in current home"))}</div>`
      : `<div class="cc-room-editor-list" role="list">
          ${orderedRoomIds
            .map((roomId, idx) => {
              const originalName = roomsById.get(roomId) ?? roomId;
              const alias = session.roomDraft.aliasFor(roomId);
              const displayValue = alias || originalName;
              const isAliased = Boolean(alias && alias !== originalName);
              const rid = escape(roomId);
              return `
                <div class="cc-room-editor-row" role="listitem" data-room-editor-row="${rid}">
                  <span class="cc-room-editor-index">${idx + 1}</span>
                  <div class="cc-room-editor-main">
                    <div class="cc-room-alias-wrap">
                      <input
                        type="text"
                        class="cc-prompt-input cc-room-alias-input"
                        data-room-alias-input="${rid}"
                        value="${escape(displayValue)}"
                        placeholder="${escape(originalName)}"
                        aria-label="${escape(tr3("房间显示名称", "房間顯示名稱", "Room display name"))} ${escape(originalName)}"
                      />
                      ${
                        isAliased
                          ? `<button type="button" class="cc-room-alias-reset" data-room-alias-clear="${rid}" title="${t("恢复原名")}" aria-label="${t("恢复原名")}">×</button>`
                          : ""
                      }
                    </div>
                    ${
                      isAliased
                        ? `<small class="cc-room-orig-hint">${escape(tr3(`原名：${originalName}`, `原名：${originalName}`, `Original: ${originalName}`))}</small>`
                        : ""
                    }
                  </div>
                  <div class="cc-room-order-btns">
                    <button type="button" class="cc-room-order-btn" data-room-order-up="${rid}" ${idx === 0 ? "disabled" : ""} title="${escape(tr3("上移", "上移", "Move up"))}" aria-label="${escape(tr3("上移", "上移", "Move up"))}">↑</button>
                    <button type="button" class="cc-room-order-btn" data-room-order-down="${rid}" ${idx === orderedRoomIds.length - 1 ? "disabled" : ""} title="${escape(tr3("下移", "下移", "Move down"))}" aria-label="${escape(tr3("下移", "下移", "Move down"))}">↓</button>
                  </div>
                </div>`;
            })
            .join("")}
        </div>
        <div class="cc-room-editor-subbar">
          <small>${escape(tr3("留空可恢复原名，仅在本机显示", "留空可恢復原名，僅在本機顯示", "Clear name to restore original; local to this device"))}</small>
          <button type="button" class="cc-inline-pill" id="btn-room-order-reset" ${isRoomDefault ? "disabled" : ""}>
            ${escape(tr3("恢复默认顺序", "恢復預設順序", "Reset Order"))}
          </button>
        </div>`;

  const kindsBody = `
    <div class="cc-room-editor-list" role="list">
      ${orderedKinds
        .map((tag, idx) => {
          const title = t(KIND_CHIP[tag].title);
          return `
            <div class="cc-room-editor-row is-kind" role="listitem" data-kind-editor-row="${tag}">
              <span class="cc-room-editor-index">${idx + 1}</span>
              <div class="cc-room-editor-main">
                <span class="cc-room-kind-title">${escape(title)}</span>
              </div>
              <div class="cc-room-order-btns">
                <button type="button" class="cc-room-order-btn" data-kind-order-up="${tag}" ${idx === 0 ? "disabled" : ""} title="${escape(tr3("上移", "上移", "Move up"))}" aria-label="${escape(tr3("上移", "上移", "Move up"))}">↑</button>
                <button type="button" class="cc-room-order-btn" data-kind-order-down="${tag}" ${idx === orderedKinds.length - 1 ? "disabled" : ""} title="${escape(tr3("下移", "下移", "Move down"))}" aria-label="${escape(tr3("下移", "下移", "Move down"))}">↓</button>
              </div>
            </div>`;
        })
        .join("")}
    </div>
    <div class="cc-room-editor-subbar">
      <small>${escape(tr3("调整筛选栏设备类型的展示先后", "調整篩選欄設備類型的展示先後", "Reorder device category filter pills"))}</small>
      <button type="button" class="cc-inline-pill" id="btn-kind-order-reset" ${isKindDefault ? "disabled" : ""}>
        ${escape(tr3("恢复默认顺序", "恢復預設順序", "Reset Order"))}
      </button>
    </div>`;

  const hiddenSection =
    hiddenDevices.length > 0
      ? `<div class="cc-room-editor-hidden">
          <div class="cc-room-editor-hidden-head">
            <span>${escape(tr3(`已隐藏设备 (${hiddenDevices.length})`, `已隱藏設備 (${hiddenDevices.length})`, `Hidden Devices (${hiddenDevices.length})`))}</span>
          </div>
          <div class="cc-room-editor-hidden-chips">
            ${hiddenDevices
              .map((dev) => {
                const name = host.layout.aliases[dev.id] ?? dev.name;
                return `<button type="button" class="cc-menu-chip" data-editor-unhide="${escape(dev.id)}" title="${escape(tr3("点击取消隐藏", "點擊取消隱藏", "Click to unhide"))}">
                  ${escape(name)} · ${escape(tr3("取消隐藏", "取消隱藏", "Unhide"))}
                </button>`;
              })
              .join("")}
          </div>
        </div>`
      : "";

  return `
    <div class="cc-prompt-backdrop" data-room-editor-cancel></div>
    <div class="cc-prompt cc-room-editor" role="dialog" aria-modal="true" aria-label="${escape(tr3("房间与分类管理", "房間與分類管理", "Rooms & Categories"))}">
      <div class="cc-room-editor-header">
        <strong>${escape(tr3("房间与分类管理", "房間與分類管理", "Rooms & Categories"))}</strong>
        <div class="cc-segmented-pills cc-room-editor-tabs" role="tablist">
          <button type="button" role="tab" class="cc-seg-pill ${session.tab === "rooms" ? "is-active" : ""}" data-room-editor-tab="rooms" aria-selected="${session.tab === "rooms"}">
            ${escape(tr3("房间与重命名", "房間與重新命名", "Rooms & Rename"))}
          </button>
          <button type="button" role="tab" class="cc-seg-pill ${session.tab === "kinds" ? "is-active" : ""}" data-room-editor-tab="kinds" aria-selected="${session.tab === "kinds"}">
            ${escape(tr3("设备分类顺序", "設備分類順序", "Category Order"))}
          </button>
        </div>
      </div>
      ${session.tab === "rooms" ? roomsBody : kindsBody}
      ${hiddenSection}
      <div class="cc-prompt-actions">
        <button type="button" class="cc-btn-secondary" data-room-editor-cancel>${t("取消")}</button>
        <button type="button" class="cc-btn-primary" id="btn-room-editor-save">${t("保存")}</button>
      </div>
    </div>`;
}

export function renderEditLayoutToolbar(host: MenuMijiaWindowsApp): string {
  if (!host.isEditingLayout) return "";
  return `<div class="cc-edit-layout-toolbar">
    <button type="button" class="cc-inline-pill cc-edit-rooms-btn" id="btn-edit-room-order" data-open-room-editor="rooms">
      ${host.escapeHtml(tr3("调整房间与分类顺序 / 重命名房间", "調整房間與分類順序 / 重新命名房間", "Reorder & Rename Rooms / Categories"))}
    </button>
  </div>`;
}

export function renderHiddenDevicesTray(host: MenuMijiaWindowsApp): string {
  if (!host.isEditingLayout && host.presentationDevices.length > 0) return "";
  const hiddenIds = new Set(hiddenDeviceIds(host.layout));
  if (hiddenIds.size === 0) return "";
  const hiddenDevices = host.devices.filter((d) => hiddenIds.has(d.id));
  if (hiddenDevices.length === 0) return "";
  const escape = (v: string) => host.escapeHtml(v);
  return `<section class="cc-hidden-devices-tray" aria-label="${escape(tr3("已隐藏的设备", "已隱藏的設備", "Hidden devices"))}">
    <div class="cc-hidden-devices-header">
      <span class="cc-group-title">${escape(tr3(`已隐藏设备 (${hiddenDevices.length})`, `已隱藏設備 (${hiddenDevices.length})`, `Hidden Devices (${hiddenDevices.length})`))}</span>
      ${
        hiddenDevices.length > 1
          ? `<button type="button" class="cc-inline-pill" id="btn-unhide-all-devices">${escape(tr3("全部恢复显示", "全部恢復顯示", "Unhide All"))}</button>`
          : ""
      }
    </div>
    <div class="cc-hidden-devices-list">
      ${hiddenDevices
        .map((dev) => {
          const id = escape(dev.id);
          const name = escape(host.layout.aliases[dev.id] ?? dev.name);
          const room = escape(roomDisplayName(host.layout, dev.roomId, dev.roomName));
          return `
            <div class="cc-hidden-device-card" data-hidden-card-id="${id}">
              <div class="cc-hidden-device-meta">
                <span class="cc-hidden-device-name">${name}</span>
                <span class="cc-hidden-device-room">${room}</span>
              </div>
              <button type="button" class="cc-inline-pill cc-unhide-pill" data-unhide-device="${id}">
                ${escape(tr3("取消隐藏", "取消隱藏", "Unhide"))}
              </button>
            </div>`;
        })
        .join("")}
    </div>
  </section>`;
}

export function bindRoomOrderEditorEvents(host: MenuMijiaWindowsApp): void {

  host.root.querySelectorAll<HTMLElement>("[data-toggle-pin]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.togglePin ?? "";
      if (!id) return;
      togglePinnedDevice(id, host.layout);
      host.saveLayout();
      host.ctxMenu = null;
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-move-pin]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const raw = btn.dataset.movePin ?? "";
      const sep = raw.lastIndexOf(":");
      const id = sep > 0 ? raw.slice(0, sep) : "";
      const dir = Number(sep > 0 ? raw.slice(sep + 1) : "0");
      if (!id || (dir !== -1 && dir !== 1)) return;
      movePinnedDevice(id, dir, host.layout);
      host.saveLayout();
      host.ctxMenu = null;
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-hide-device]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.hideDevice ?? "";
      if (!id) return;
      hideDevice(id, host.layout);
      if (host.expandedDeviceId === id) host.expandedDeviceId = null;
      if (host.panelSearch.selectedDeviceId === id) host.panelSearch.selectedDeviceId = null;
      host.saveLayout();
      host.ctxMenu = null;
      host.render();
    });
  });

  host.root.querySelector("#btn-room-order-editor")?.addEventListener("click", () => {
    openRoomOrderEditor(host, { tab: "rooms" });
  });

  host.root.querySelectorAll<HTMLElement>("[data-open-room-editor]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.openRoomEditor === "kinds" ? "kinds" : "rooms";
      host.ctxMenu = null;
      openRoomOrderEditor(host, { tab });
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-open-room-rename]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const roomId = btn.dataset.openRoomRename ?? "";
      host.ctxMenu = null;
      openRoomOrderEditor(host, { tab: "rooms", focusRoomId: roomId || null });
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-quick-room-move]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const raw = btn.dataset.quickRoomMove ?? "";
      const sep = raw.lastIndexOf(":");
      const roomId = sep > 0 ? raw.slice(0, sep) : "";
      const dir = Number(sep > 0 ? raw.slice(sep + 1) : "0");
      if (!roomId || (dir !== -1 && dir !== 1)) return;
      const rooms = snapshotRoomsForHost(host.devices);
      const draft = new RoomOrderDraft({
        savedOrder: host.layout.roomOrder,
        savedAliases: host.layout.roomAliases,
        visibleIds: rooms.map((r) => r.id),
      });
      if (draft.move(roomId, dir, rooms.map((r) => r.id))) {
        host.layout.roomOrder = [...draft.order];
        host.saveLayout();
      }
      host.ctxMenu = null;
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-unhide-device]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.unhideDevice ?? "";
      if (!id) return;
      unhideDevice(id, host.layout);
      host.saveLayout();
      host.render();
    });
  });

  host.root.querySelector("#btn-unhide-all-devices")?.addEventListener("click", (e) => {
    e.stopPropagation();
    unhideAllDevices(host.layout);
    host.saveLayout();
    host.render();
  });

  const session = getRoomOrderEditorSession(host);
  if (!session) return;

  const rooms = snapshotRoomsForHost(host.devices);
  const roomsById = new Map(rooms.map((r) => [r.id, r.name]));
  const visibleRoomIds = rooms.map((r) => r.id);
  const defaultKinds = snapshotKindsForHost(host.devices);

  if (session.focusRoomId && session.tab === "rooms") {
    const escapedRoomId =
      typeof CSS !== "undefined" && typeof CSS.escape === "function"
        ? CSS.escape(session.focusRoomId)
        : session.focusRoomId.replace(/(["\\])/g, "\\$1");
    const targetInput = host.root.querySelector<HTMLInputElement>(
      `[data-room-alias-input="${escapedRoomId}"]`,
    );
    session.focusRoomId = null;
    if (targetInput) {
      targetInput.focus();
      targetInput.select();
    }
  }

  const flushAliasInputs = (): void => {
    host.root.querySelectorAll<HTMLInputElement>("[data-room-alias-input]").forEach((input) => {
      const roomId = input.dataset.roomAliasInput ?? "";
      if (roomId) session.roomDraft.setAlias(roomId, input.value, roomsById.get(roomId));
    });
  };

  host.root.querySelectorAll<HTMLElement>("[data-room-editor-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      flushAliasInputs();
      session.tab = btn.dataset.roomEditorTab === "kinds" ? "kinds" : "rooms";
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLInputElement>("[data-room-alias-input]").forEach((input) => {
    input.addEventListener("input", () => {
      const roomId = input.dataset.roomAliasInput ?? "";
      if (!roomId) return;
      const originalName = roomsById.get(roomId) ?? roomId;
      session.roomDraft.setAlias(roomId, input.value, originalName);
      const shownName = roomDisplayName({ roomAliases: session.roomDraft.aliases }, roomId, originalName);
      const escapedRoomId =
        typeof CSS !== "undefined" && typeof CSS.escape === "function"
          ? CSS.escape(roomId)
          : roomId.replace(/(["\\])/g, "\\$1");
      const pill = host.root.querySelector<HTMLButtonElement>(`.cc-room-pill[data-room-id="${escapedRoomId}"]`);
      if (pill) {
        pill.dataset.room = shownName;
        pill.textContent = shownName;
      }
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        saveRoomOrderEditor(host);
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        cancelRoomOrderEditor(host);
      }
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-room-alias-clear]").forEach((btn) => {
    btn.addEventListener("click", () => {
      flushAliasInputs();
      const roomId = btn.dataset.roomAliasClear ?? "";
      if (!roomId) return;
      session.roomDraft.setAlias(roomId, "");
      session.focusRoomId = roomId;
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-room-order-up]").forEach((btn) => {
    btn.addEventListener("click", () => {
      flushAliasInputs();
      const roomId = btn.dataset.roomOrderUp ?? "";
      if (session.roomDraft.move(roomId, -1, visibleRoomIds)) host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-room-order-down]").forEach((btn) => {
    btn.addEventListener("click", () => {
      flushAliasInputs();
      const roomId = btn.dataset.roomOrderDown ?? "";
      if (session.roomDraft.move(roomId, 1, visibleRoomIds)) host.render();
    });
  });

  host.root.querySelector("#btn-room-order-reset")?.addEventListener("click", () => {
    flushAliasInputs();
    session.roomDraft.restoreDefaultOrder(visibleRoomIds);
    host.render();
  });

  host.root.querySelectorAll<HTMLElement>("[data-kind-order-up]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tag = btn.dataset.kindOrderUp ?? "";
      if (session.kindDraft.move(tag, -1, defaultKinds)) host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-kind-order-down]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tag = btn.dataset.kindOrderDown ?? "";
      if (session.kindDraft.move(tag, 1, defaultKinds)) host.render();
    });
  });

  host.root.querySelector("#btn-kind-order-reset")?.addEventListener("click", () => {
    session.kindDraft.restoreDefaultOrder(defaultKinds);
    host.render();
  });

  host.root.querySelectorAll<HTMLElement>("[data-editor-unhide]").forEach((btn) => {
    btn.addEventListener("click", () => {
      flushAliasInputs();
      const devId = btn.dataset.editorUnhide ?? "";
      if (!devId) return;
      unhideDevice(devId, host.layout);
      host.saveLayout();
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-room-editor-cancel]").forEach((el) => {
    el.addEventListener("click", () => cancelRoomOrderEditor(host));
  });

  host.root.querySelector("#btn-room-editor-save")?.addEventListener("click", () => {
    saveRoomOrderEditor(host);
  });
}
