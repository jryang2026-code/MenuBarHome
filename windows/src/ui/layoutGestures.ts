import { t } from "../core/i18n.js";
import type { DeviceCommand, DeviceIntent, SmartDevice } from "../core/models.js";
import { KIND_CHIP, type DeviceKindTag } from "./listCut.js";
import {
  isDevicePinned,
  moveInOrder,
  pinnedDeviceIds,
  projectedOffset,
  releaseVelocity,
  scopedKey,
  targetSize,
  type LayoutPrefs,
  type TileSize,
} from "./panelPrefs.js";
import type { PersistedSettings } from "./appTypes.js";
import { snapshotRoomsForHost } from "./roomOrderEditor.js";

export interface LayoutGestureHost {
  readonly root: HTMLElement;
  readonly devices: readonly SmartDevice[];
  readonly settings: PersistedSettings;
  readonly layout: LayoutPrefs;
  readonly pageKey: string;
  expandedDeviceId: string | null;
  draggingId: string | null;
  dragPointer: { x: number; y: number; grabX: number; grabY: number } | null;
  lastSwap: { slot: string; at: number } | null;
  ctxMenu: {
    x: number;
    y: number;
    deviceId?: string;
    groupId?: string;
    roomTarget?: { readonly roomId: string; readonly originalName: string };
    kindTarget?: DeviceKindTag;
    roomBar?: boolean;
  } | null;
  dimPreview: { id: string; percent: number } | null;
  suppressNextClick: boolean;
  pointerIsDown: boolean;
  isEditingLayout: boolean;
  tileSize(device: SmartDevice): Exclude<TileSize, "auto">;
  applyDragOffset(): void;
  executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower?: boolean,
  ): Promise<void>;
  render(): void;
  saveLayout(): void;
  startEditing(): void;
  swapIfNeeded(x: number, y: number): void;
}

  export function bindLayoutGestures(host: LayoutGestureHost): void {
    let press: { id: string; x: number; y: number; timer: number; dimming: boolean; el: HTMLElement } | null = null;
    let resizing: {
      id: string;
      startX: number;
      startY: number;
      startSize: Exclude<TileSize, "auto">;
      didStep: boolean;
      moved: boolean;
      lastDx: number;
      lastDy: number;
      samples: Array<{ x: number; y: number; t: number }>;
    } | null = null;
    let suppressNextHandleClick = false;

    const endHandleGesture = (id: string): void => {
      const tile = host.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(id)}"]`);
      tile?.classList.remove("is-resizing");
      host.root.querySelector<HTMLElement>(".cc-resize-handle.is-active")?.classList.remove("is-active");
    };

    const beginDrag = (id: string, el: HTMLElement, x: number, y: number) => {
      const r = el.getBoundingClientRect();
      host.draggingId = id;
      host.dragPointer = { x, y, grabX: x - r.left, grabY: y - r.top };
      host.lastSwap = null;
      host.suppressNextClick = true;
    };

    host.root.addEventListener(
      "pointerdown",
      () => {
        host.pointerIsDown = true;
      },
      { capture: true },
    );
    /**
     * A cancelled gesture (pointer cancel, window blur) ends the press without sending anything: the
     * pending dim preview and the long-press timer are dropped, so the next plain click on the tile is
     * a plain click instead of a brightness write against a stale preview.
     */
    const cancelGesture = (): void => {
      host.pointerIsDown = false;
      if (resizing) {
        endHandleGesture(resizing.id);
        resizing = null;
      }
      if (press) {
        window.clearTimeout(press.timer);
        press = null;
      }
      // Both a dim preview and a reorder drag live in the rendered DOM (the preview fill and the
      // dragged card's translate/is-dragging), so dropping either needs a repaint: the release that
      // follows a cancel no longer sees a press and would not render on its own.
      const droppedPreview = host.dimPreview !== null;
      const droppedDrag = host.draggingId !== null;
      host.dimPreview = null;
      host.draggingId = null;
      host.dragPointer = null;
      host.lastSwap = null;
      host.suppressNextClick = false;
      if (droppedPreview || droppedDrag) host.render();
    };

    window.addEventListener(
      "pointerup",
      () => {
        host.pointerIsDown = false;
      },
      { capture: true },
    );
    window.addEventListener("pointercancel", cancelGesture);
    window.addEventListener("blur", cancelGesture);

    host.root.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      suppressNextHandleClick = false;
      const handleEl = (e.target as HTMLElement).closest<HTMLElement>(".cc-resize-handle");
      if (handleEl && host.isEditingLayout) {
        const id = handleEl.dataset.resizeHandle ?? handleEl.dataset.cycleSize ?? "";
        const dev = host.devices.find((d) => d.id === id);
        if (dev) {
          resizing = {
            id: dev.id,
            startX: e.clientX,
            startY: e.clientY,
            startSize: host.tileSize(dev),
            didStep: false,
            moved: false,
            lastDx: 0,
            lastDy: 0,
            samples: [{ x: e.clientX, y: e.clientY, t: performance.now() }],
          };
          handleEl.classList.add("is-active");
          handleEl.closest<HTMLElement>("[data-tile-id]")?.classList.add("is-resizing");
        }
        return;
      }
      const el = (e.target as HTMLElement).closest<HTMLElement>("[data-tile-id]");
      if (!el || (e.target as HTMLElement).closest(".cc-resize-handle, .cc-inline-slider-wrap, .cc-hero-primary-bar, input")) return;
      const id = el.dataset.tileId as string;
      const timer = host.isEditingLayout
        ? 0
        : window.setTimeout(() => {
            if (!press || press.dimming) return;
            beginDrag(id, el, press.x, press.y);
            host.startEditing();
          }, 450);
      press = { id, x: e.clientX, y: e.clientY, timer, dimming: false, el };
    });

    window.addEventListener("pointermove", (e) => {
      if (resizing) {
        const dx = e.clientX - resizing.startX;
        const dy = e.clientY - resizing.startY;
        resizing.lastDx = dx;
        resizing.lastDy = dy;
        const now = performance.now();
        resizing.samples.push({ x: e.clientX, y: e.clientY, t: now });
        resizing.samples = resizing.samples.filter((sample) => now - sample.t <= 120);
        if (Math.hypot(dx, dy) > 3) {
          resizing.moved = true;
        }
        const dev = host.devices.find((d) => d.id === resizing?.id);
        if (!dev) return;
        const next = targetSize(
          resizing.startSize,
          { width: dx, height: dy },
          host.settings.isCompactGridMode,
        );
        if (next !== host.tileSize(dev)) {
          resizing.didStep = true;
          host.layout.tileSizes[scopedKey(host.pageKey, dev.id)] = next;
          host.saveLayout();
          host.render();
        }
        return;
      }
      if (!press) return;
      const dx = e.clientX - press.x;
      const dy = e.clientY - press.y;
      const moved = Math.hypot(dx, dy);
      if (host.draggingId) {
        if (host.dragPointer) { host.dragPointer.x = e.clientX; host.dragPointer.y = e.clientY; }
        host.applyDragOffset();
        const prevSlot = host.lastSwap?.slot ?? null;
        const draggedId = host.draggingId;
        host.swapIfNeeded(e.clientX, e.clientY);
        const nextSlot = host.lastSwap?.slot ?? null;
        if (nextSlot && nextSlot !== prevSlot && isDevicePinned(draggedId, host.layout)) {
          const sep = nextSlot.lastIndexOf("|");
          const targetId = sep > 0 ? nextSlot.slice(0, sep) : "";
          const after = sep > 0 && nextSlot.slice(sep + 1) === "true";
          if (targetId && isDevicePinned(targetId, host.layout)) {
            const pins = pinnedDeviceIds(host.layout);
            host.layout.pinnedDeviceIds = moveInOrder(pins, pins, draggedId, targetId, after);
            host.saveLayout();
            host.render();
          }
        }
        return;
      }
      if (host.isEditingLayout) {
        if (moved > 3) {
          beginDrag(press.id, press.el, press.x, press.y);
          host.render();
        }
        return;
      }
      const dev = host.devices.find((d) => d.id === press?.id);
      const tileSz = dev ? host.tileSize(dev) : "half";
      const isExpanded = dev ? (host.expandedDeviceId === dev.id || tileSz === "panel") : false;
      const canDim =
        !isExpanded &&
        tileSz !== "small" &&
        dev?.kind.kind === "light" &&
        dev.isOnline &&
        dev.kind.brightnessWritable !== false;
      if (!press.dimming && moved > 8) {
        window.clearTimeout(press.timer);
        if (canDim && Math.abs(dx) > Math.abs(dy)) press.dimming = true; else { press = null; return; }
      }
      if (press.dimming) {
        const tile = host.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(press.id)}"]`);
        if (!tile) return;
        const r = tile.getBoundingClientRect();
        const percent = Math.max(1, Math.min(100, Math.round(((e.clientX - r.left) / r.width) * 100)));
        host.dimPreview = { id: press.id, percent };
        host.suppressNextClick = true;
        host.render();
      }
    });

    window.addEventListener("pointerup", () => {
      if (resizing) {
        const { id, moved, didStep, startSize, samples, lastDx, lastDy } = resizing;
        resizing = null;
        endHandleGesture(id);
        // A drag without a size step leaves the same handle element mounted, so the browser
        // fires a real click on it after pointerup (microtasks run before that click); swallow it.
        if (moved && !didStep) {
          suppressNextHandleClick = true;
          window.setTimeout(() => {
            suppressNextHandleClick = false;
          }, 0);
          // QuotaKeeper-style flick: release velocity projects onto at most one step.
          const projection = projectedOffset(releaseVelocity(samples, performance.now()));
          const dev = host.devices.find((d) => d.id === id);
          if (!dev) return;
          const target = targetSize(
            startSize,
            { width: lastDx + projection.width, height: lastDy + projection.height },
            host.settings.isCompactGridMode,
          );
          if (target !== host.tileSize(dev)) {
            host.layout.tileSizes[scopedKey(host.pageKey, dev.id)] = target;
            host.saveLayout();
            host.render();
          }
        }
        return;
      }
      if (!press) return;
      window.clearTimeout(press.timer);
      const finished = press;
      press = null;
      if (host.draggingId) {
        host.draggingId = null;
        host.dragPointer = null;
        host.render();
        return;
      }
      if (finished.dimming && host.dimPreview) {
        const dev = host.devices.find((d) => d.id === finished.id);
        const percent = host.dimPreview.percent;
        host.dimPreview = null;
        if (dev && dev.kind.kind === "light" && dev.kind.brightnessWritable !== false) {
          void host.executeSingleCommand(dev, { kind: "setLightBrightness", entityId: dev.kind.entityId, percent }, t("已将{name}亮度设为 {percent}%", { name: dev.name, percent: percent }), { targetId: dev.id, operation: { kind: "brightness", percent } });
        }
      }
    });

    // A long-press or dim drag ends with a click on the card; swallow it so nothing toggles.
    host.root.addEventListener("click", (e) => {
      if (suppressNextHandleClick && (e.target as HTMLElement).closest(".cc-resize-handle")) {
        suppressNextHandleClick = false;
        e.stopPropagation();
        e.preventDefault();
        return;
      }
      if (host.suppressNextClick || host.isEditingLayout) {
        if ((e.target as HTMLElement).closest("[data-tile-id]") && !(e.target as HTMLElement).closest(".cc-resize-handle")) {
          e.stopPropagation();
          e.preventDefault();
        }
        host.suppressNextClick = false;
      }
    }, true);

    host.root.addEventListener("contextmenu", (e) => {
      const target = e.target as HTMLElement;
      const el = target.closest<HTMLElement>("[data-tile-id]");
      if (el) {
        e.preventDefault();
        host.ctxMenu = { x: e.clientX, y: e.clientY, deviceId: el.dataset.tileId as string };
        host.render();
        return;
      }
      const roomPill = target.closest<HTMLElement>(".cc-room-pill[data-room-id]");
      if (roomPill) {
        const roomId = roomPill.dataset.roomId ?? "";
        if (!roomId) return;
        e.preventDefault();
        const originalName =
          snapshotRoomsForHost(host.devices).find((r) => r.id === roomId)?.name ??
          roomPill.dataset.room ??
          roomId;
        host.ctxMenu = { x: e.clientX, y: e.clientY, roomTarget: { roomId, originalName } };
        host.render();
        return;
      }
      const kindPill = target.closest<HTMLElement>(".cc-room-pill[data-kind]");
      if (kindPill) {
        const rawKind = kindPill.dataset.kind ?? "";
        if (!rawKind || !(rawKind in KIND_CHIP)) return;
        e.preventDefault();
        host.ctxMenu = { x: e.clientX, y: e.clientY, kindTarget: rawKind as DeviceKindTag };
        host.render();
        return;
      }
      if (target.closest(".cc-room-bar")) {
        e.preventDefault();
        host.ctxMenu = { x: e.clientX, y: e.clientY, roomBar: true };
        host.render();
      }
    });
  }
