import { resolveLanguage, type LanguagePreference } from "../core/i18n.js";
import { hasMatchingDomShape, inputKeepsDraft, morphMatchingDom, parseSingleElement } from "./dom.js";
import { renderPanel } from "./panelView.js";
import { syncPanelSelection } from "./panelKeyboard.js";
import { refreshHabitSharePreview } from "./settingsEvents.js";
import { captureSettingsDraft, restoreSettingsDraft } from "./settingsViews.js";
import type { MenuMijiaWindowsApp } from "./app.js";

export function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export type ControlIdentityKey = string;

export const FLUENT_MOTION = {
  decelerateEasing: "cubic-bezier(0, 0, 0, 1)",
  accelerateEasing: "cubic-bezier(1, 0, 1, 1)",
  linearEasing: "linear",
  enterDurationMs: 250,
  fastEnterDurationMs: 167,
  exitDurationMs: 167,
  dialogExitDurationMs: 150,
  menuExitDurationMs: 120,
  flipDurationMs: 250,
  subpageEnterKeyframes: [
    { opacity: 0, transform: "translateX(28px)" },
    { opacity: 1, transform: "translateX(0)" },
  ] as Keyframe[],
  subpageExitKeyframes: [
    { opacity: 1, transform: "translateX(0)" },
    { opacity: 0, transform: "translateX(24px)" },
  ] as Keyframe[],
  drillOutReturnKeyframes: [
    { opacity: 0, transform: "translateX(-24px)" },
    { opacity: 1, transform: "translateX(0)" },
  ] as Keyframe[],
  sheetEnterKeyframes: [
    { opacity: 0, transform: "translateY(14px) scale(0.985)" },
    { opacity: 1, transform: "translateY(0) scale(1)" },
  ] as Keyframe[],
  sheetExitKeyframes: [
    { opacity: 1, transform: "translateY(0) scale(1)" },
    { opacity: 0, transform: "translateY(10px) scale(0.985)" },
  ] as Keyframe[],
  backdropEnterKeyframes: [{ opacity: 0 }, { opacity: 1 }] as Keyframe[],
  backdropExitKeyframes: [{ opacity: 1 }, { opacity: 0 }] as Keyframe[],
  dialogEnterKeyframes: [
    { opacity: 0, transform: "scale(1.05)" },
    { opacity: 1, transform: "scale(1)" },
  ] as Keyframe[],
  dialogExitKeyframes: [
    { opacity: 1, transform: "scale(1)" },
    { opacity: 0, transform: "scale(0.98)" },
  ] as Keyframe[],
  menuEnterKeyframes: [
    { opacity: 0, transform: "translateY(-8px)" },
    { opacity: 1, transform: "translateY(0)" },
  ] as Keyframe[],
  menuExitKeyframes: [
    { opacity: 1, transform: "translateY(0)" },
    { opacity: 0, transform: "translateY(-6px)" },
  ] as Keyframe[],
  bannerEnterKeyframes: [
    { opacity: 0, transform: "translateY(-8px)" },
    { opacity: 1, transform: "translateY(0)" },
  ] as Keyframe[],
  bannerExitKeyframes: [
    { opacity: 1, transform: "translateY(0)" },
    { opacity: 0, transform: "translateY(-6px)" },
  ] as Keyframe[],
} as const;

const STATE_ONLY_DATA_ATTRS = new Set([
  "data-rotation",
  "data-copied",
  "data-tile-size",
  "data-min-c",
  "data-max-c",
  "data-keyboard-nav",
  "data-scheme",
  "data-flyout-edge",
  "data-backdrop",
  "data-exit-ghost",
]);

const GHOST_CLASS_RENAMES: ReadonlyArray<readonly [string, string]> = [
  ["cc-settings-sheet", "cc-settings-sheet-ghost"],
  ["cc-camera-live-sheet", "cc-camera-live-sheet-ghost"],
  ["cc-sheet", "cc-sheet-ghost"],
  ["cc-sheet-body", "cc-sheet-body-ghost"],
  ["cc-menu", "cc-menu-ghost"],
  ["cc-prompt", "cc-prompt-ghost"],
  ["is-subpage", "is-subpage-ghost"],
  ["cc-tile", "cc-tile-ghost"],
  ["win-notif-card", "win-notif-card-ghost"],
  ["cc-live-banner", "cc-live-banner-ghost"],
];

function hasStableControlId(id: string): boolean {
  return Boolean(id && !id.startsWith("panel-device-"));
}

export function extractControlIdentityKey(el: Element): ControlIdentityKey | null {
  if (el.hasAttribute("data-exit-ghost")) return null;

  const tileId = el.getAttribute("data-tile-id");
  if (tileId) {
    return el.classList.contains("is-subpage") ? `subpage:${tileId}` : `tile:${tileId}`;
  }

  if (el.classList.contains("cc-sheet-backdrop")) {
    if (el.querySelector(".cc-camera-live-sheet")) return "overlay:sheet-backdrop:camera";
    if (el.querySelector(".cc-settings-sheet")) return "overlay:sheet-backdrop:settings";
    return "overlay:sheet-backdrop:onboarding";
  }
  if (el.classList.contains("cc-sheet")) {
    if (el.classList.contains("cc-camera-live-sheet")) return "overlay:sheet:camera";
    if (el.classList.contains("cc-settings-sheet")) return "overlay:sheet:settings";
    return "overlay:sheet:onboarding";
  }
  if (el.classList.contains("cc-menu-scrim")) return "overlay:menu-scrim";
  if (el.classList.contains("cc-menu")) {
    return el.classList.contains("cc-home-menu") ? "overlay:menu:home" : "overlay:menu:context";
  }
  if (el.classList.contains("cc-prompt-backdrop")) return "overlay:prompt-backdrop";
  if (el.classList.contains("cc-prompt")) return "overlay:prompt";
  if (el.classList.contains("cc-camera-stage")) return "slot:camera-stage";

  if (el.hasAttribute("data-notif-card")) {
    return `notif:${el.getAttribute("data-notif-card")}`;
  }
  if (el.classList.contains("cc-live-banner")) return "notif:live-banner";
  if (el.hasAttribute("data-ha-error")) return "notif:ha-error";
  if (el.hasAttribute("data-mi-expiry-warning")) return "notif:mi-expiry";
  if (el.classList.contains("win-notif-card")) {
    if (el.querySelector(".cc-suggestion-row")) return "notif:pending-suggestions";
    if (el.querySelector(".cc-timers-stack")) return "notif:missed-timers";
  }

  if (hasStableControlId(el.id)) return `id:${el.id}`;
  if (el.hasAttribute("data-overlay-key")) return `overlay:${el.getAttribute("data-overlay-key")}`;
  if (el.hasAttribute("data-room")) return `room:${el.getAttribute("data-room")}`;
  if (el.hasAttribute("data-kind")) return `kind:${el.getAttribute("data-kind")}`;
  if (el.hasAttribute("data-settings-tab")) return `tab:${el.getAttribute("data-settings-tab")}`;
  if (el.hasAttribute("data-settings-panel")) return `panel:${el.getAttribute("data-settings-panel")}`;

  if (el.classList.contains("win-island--top")) return "slot:island-top";
  if (el.classList.contains("win-island--bottom")) return "slot:island-bottom";
  if (el.classList.contains("win-notif-stack")) return "slot:notif-stack";
  if (el.classList.contains("cc-env-strip")) return "slot:env-strip";
  if (el.classList.contains("cc-scroll-area")) return "slot:scroll-area";
  if (el.classList.contains("win-slider-deck")) return "slot:slider-deck";
  if (el.classList.contains("cc-quick-strip")) return "slot:quick-strip";
  if (el.classList.contains("cc-room-bar")) return "slot:room-bar";
  if (el.classList.contains("cc-footer")) return "slot:footer";
  if (el.classList.contains("cc-tile-fill")) return "slot:tile-fill";
  if (el.classList.contains("cc-tile-header")) return "slot:tile-header";
  if (el.classList.contains("win-split-pill")) return "slot:split-pill";
  if (el.classList.contains("cc-tile-drawer")) return "slot:tile-drawer";
  if (el.classList.contains("cc-climate-more")) return "slot:climate-more";
  if (el.tagName.toUpperCase() === "SECTION" && el.classList.contains("cc-group")) {
    const collapseKey = el.querySelector(":scope > [data-collapse]")?.getAttribute("data-collapse") ?? "rest";
    return `slot:group:${collapseKey}`;
  }

  const actionPairs: string[] = [];
  for (const attr of Array.from(el.attributes)) {
    if (attr.name.startsWith("data-") && !STATE_ONLY_DATA_ATTRS.has(attr.name)) {
      actionPairs.push(`${attr.name}=${attr.value}`);
    }
  }
  if (actionPairs.length > 0) {
    actionPairs.sort();
    return `action:${actionPairs.join("&")}`;
  }

  return null;
}

function structuralClassSignature(el: Element): string {
  for (const cls of Array.from(el.classList)) {
    if (
      cls.startsWith("is-") ||
      cls.startsWith("has-") ||
      cls.startsWith("palette-") ||
      cls.startsWith("scheme-")
    ) {
      continue;
    }
    return cls;
  }
  return "";
}

export interface ReconcileOptions {
  readonly activeDraftElement?: Element | null;
  readonly protectedMediaNodes?: ReadonlySet<Element>;
}

function isProtectedCameraMedia(el: Element, options?: ReconcileOptions): boolean {
  if (el.id === "cc-camera-live-img" || el.id === "cc-camera-video") return true;
  return Boolean(options?.protectedMediaNodes?.has(el));
}

function retainsLiveCameraMediaAttr(
  isProtectedMedia: boolean,
  attrName: string,
  desired: Element,
): boolean {
  return isProtectedMedia && (attrName === "src" || attrName === "style") && !desired.hasAttribute(attrName);
}

function syncElementAttributesAndProps(
  current: Element,
  desired: Element,
  options?: ReconcileOptions,
): void {
  const tag = current.tagName.toUpperCase();
  const isDraftOwner =
    current === options?.activeDraftElement &&
    (tag === "INPUT" || tag === "TEXTAREA") &&
    inputKeepsDraft(current as HTMLInputElement | HTMLTextAreaElement);
  const isProtectedMedia = isProtectedCameraMedia(current, options);

  for (const attr of Array.from(current.attributes)) {
    if (attr.name === "value" && isDraftOwner) continue;
    if (retainsLiveCameraMediaAttr(isProtectedMedia, attr.name, desired)) {
      continue;
    }
    if (!desired.hasAttribute(attr.name)) {
      current.removeAttribute(attr.name);
    }
  }

  for (const attr of Array.from(desired.attributes)) {
    if (attr.name === "value" && isDraftOwner) continue;
    if (isProtectedMedia && attr.name === "src" && !attr.value) continue;
    if (current.getAttribute(attr.name) !== attr.value) {
      current.setAttribute(attr.name, attr.value);
    }
  }

  if (tag === "INPUT") {
    const currentInput = current as HTMLInputElement;
    const desiredInput = desired as HTMLInputElement;
    const desiredValue = desiredInput.getAttribute("value") ?? desiredInput.value;
    if (!isDraftOwner && currentInput.value !== desiredValue) {
      currentInput.value = desiredValue;
    }
    const desiredChecked = desiredInput.hasAttribute("checked");
    if (currentInput.checked !== desiredChecked) {
      currentInput.checked = desiredChecked;
    }
    const desiredDisabled = desiredInput.hasAttribute("disabled");
    if (currentInput.disabled !== desiredDisabled) {
      currentInput.disabled = desiredDisabled;
    }
  } else if (tag === "TEXTAREA") {
    const currentArea = current as HTMLTextAreaElement;
    const desiredArea = desired as HTMLTextAreaElement;
    if (!isDraftOwner && currentArea.value !== desiredArea.value) {
      currentArea.value = desiredArea.value;
    }
    const desiredDisabled = desiredArea.hasAttribute("disabled");
    if (currentArea.disabled !== desiredDisabled) {
      currentArea.disabled = desiredDisabled;
    }
  } else if (tag === "SELECT") {
    const currentSelect = current as HTMLSelectElement;
    const desiredSelect = desired as HTMLSelectElement;
    const desiredDisabled = desiredSelect.hasAttribute("disabled");
    if (currentSelect.disabled !== desiredDisabled) {
      currentSelect.disabled = desiredDisabled;
    }
  } else if (tag === "OPTION") {
    const currentOption = current as HTMLOptionElement;
    const desiredOption = desired as HTMLOptionElement;
    const desiredSelected = desiredOption.hasAttribute("selected");
    if (currentOption.selected !== desiredSelected) {
      currentOption.selected = desiredSelected;
    }
  } else if (tag === "DETAILS") {
    const currentDetails = current as HTMLDetailsElement;
    const desiredDetails = desired as HTMLDetailsElement;
    const desiredOpen = desiredDetails.hasAttribute("open");
    if (currentDetails.open !== desiredOpen) {
      currentDetails.open = desiredOpen;
    }
  }
}

function isExitGhostNode(node: Node): boolean {
  return node.nodeType === 1 && (node as Element).hasAttribute("data-exit-ghost");
}

function nextNonGhostSibling(node: Node | null): ChildNode | null {
  let cur = node ? node.nextSibling : null;
  while (cur && isExitGhostNode(cur)) {
    cur = cur.nextSibling;
  }
  return cur;
}

function firstNonGhostChild(parent: Element): ChildNode | null {
  let cur = parent.firstChild;
  while (cur && isExitGhostNode(cur)) {
    cur = cur.nextSibling;
  }
  return cur;
}

export function reconcileElementTree(
  current: Element,
  desired: Element,
  options?: ReconcileOptions,
): void {
  const tag = current.tagName.toUpperCase();
  syncElementAttributesAndProps(current, desired, options);

  if (tag === "SVG") {
    if (current.innerHTML !== desired.innerHTML) {
      current.innerHTML = desired.innerHTML;
    }
    return;
  }

  if (current.classList.contains("cc-camera-stage")) {
    const existingMedia = current.querySelector("#cc-camera-live-img, #cc-camera-video");
    if (existingMedia && desired.children.length === 0) {
      return;
    }
  }

  const currentNodes = Array.from(current.childNodes).filter((node) => !isExitGhostNode(node));
  const desiredNodes = Array.from(desired.childNodes);

  const keyedCurrent = new Map<ControlIdentityKey, Element>();
  for (const node of currentNodes) {
    if (node.nodeType === 1) {
      const el = node as Element;
      const key = extractControlIdentityKey(el);
      if (key && !keyedCurrent.has(key)) {
        keyedCurrent.set(key, el);
      }
    }
  }

  const matchedCurrent: Array<ChildNode | null> = new Array(desiredNodes.length).fill(null);
  const usedCurrent = new Set<ChildNode>();

  for (let i = 0; i < desiredNodes.length; i += 1) {
    const dNode = desiredNodes[i]!;
    if (dNode.nodeType !== 1) continue;
    const dEl = dNode as Element;
    const key = extractControlIdentityKey(dEl);
    if (!key) continue;
    const candidate = keyedCurrent.get(key);
    if (
      candidate &&
      !usedCurrent.has(candidate) &&
      candidate.tagName.toUpperCase() === dEl.tagName.toUpperCase()
    ) {
      matchedCurrent[i] = candidate;
      usedCurrent.add(candidate);
    }
  }

  for (let i = 0; i < desiredNodes.length; i += 1) {
    if (matchedCurrent[i] !== null) continue;
    const dNode = desiredNodes[i]!;
    if (dNode.nodeType === 3) {
      const candidate = currentNodes.find((c) => c.nodeType === 3 && !usedCurrent.has(c));
      if (candidate) {
        matchedCurrent[i] = candidate;
        usedCurrent.add(candidate);
      }
      continue;
    }
    if (dNode.nodeType === 1) {
      const dEl = dNode as Element;
      if (extractControlIdentityKey(dEl) !== null) continue;
      const dTag = dEl.tagName.toUpperCase();
      const dSig = structuralClassSignature(dEl);
      const candidate = currentNodes.find((c) => {
        if (c.nodeType !== 1 || usedCurrent.has(c)) return false;
        const cEl = c as Element;
        if (extractControlIdentityKey(cEl) !== null) return false;
        if (cEl.tagName.toUpperCase() !== dTag) return false;
        if (dTag === "SVG") return true;
        return structuralClassSignature(cEl) === dSig;
      });
      if (candidate) {
        matchedCurrent[i] = candidate;
        usedCurrent.add(candidate);
      }
    }
  }

  for (const cNode of currentNodes) {
    if (!usedCurrent.has(cNode)) {
      if (cNode.nodeType === 1 && isProtectedCameraMedia(cNode as Element, options)) {
        continue;
      }
      cNode.remove();
    }
  }

  let cursor = firstNonGhostChild(current);
  for (let i = 0; i < desiredNodes.length; i += 1) {
    const dNode = desiredNodes[i]!;
    const match = matchedCurrent[i]!;
    if (match) {
      if (match === cursor) {
        cursor = nextNonGhostSibling(cursor);
      } else {
        current.insertBefore(match, cursor);
      }
      if (match.nodeType === 3) {
        if (match.nodeValue !== dNode.nodeValue) {
          match.nodeValue = dNode.nodeValue;
        }
      } else if (match.nodeType === 1) {
        reconcileElementTree(match as Element, dNode as Element, options);
      }
    } else {
      const clone = dNode.cloneNode(true);
      current.insertBefore(clone, cursor);
    }
  }

  if (tag === "SELECT") {
    const currentSelect = current as HTMLSelectElement;
    const desiredSelect = desired as HTMLSelectElement;
    const selectedOpt =
      Array.from(desiredSelect.options).find((opt) => opt.hasAttribute("selected")) ??
      desiredSelect.options[desiredSelect.selectedIndex];
    const targetValue = selectedOpt ? selectedOpt.value : desiredSelect.value;
    if (currentSelect.value !== targetValue) {
      currentSelect.value = targetValue;
    }
  }
}

export function sanitizeDepartureGhost(sourceEl: HTMLElement): HTMLElement {
  const clone = sourceEl.cloneNode(true) as HTMLElement;
  const allNodes = [clone, ...Array.from(clone.querySelectorAll<HTMLElement>("*"))];
  for (const node of allNodes) {
    node.removeAttribute("id");
    for (const attr of Array.from(node.attributes)) {
      if (attr.name.startsWith("data-")) {
        node.removeAttribute(attr.name);
      }
    }
    for (const [liveClass, ghostClass] of GHOST_CLASS_RENAMES) {
      if (node.classList.contains(liveClass)) {
        node.classList.remove(liveClass);
        node.classList.add(ghostClass);
      }
    }
    const tag = node.tagName.toUpperCase();
    if (tag === "BUTTON" || tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA") {
      node.setAttribute("tabindex", "-1");
      (node as HTMLButtonElement).disabled = true;
    }
  }
  clone.setAttribute("data-exit-ghost", "true");
  clone.setAttribute("inert", "");
  (clone as HTMLElement & { inert?: boolean }).inert = true;
  clone.setAttribute("aria-hidden", "true");
  clone.style.pointerEvents = "none";
  return clone;
}

export const sanitizeExitGhost = sanitizeDepartureGhost;

interface RegisteredRenderListener {
  readonly target: EventTarget;
  readonly type: string;
  readonly listener: EventListenerOrEventListenerObject;
  readonly capture: boolean;
}

function findEventTargetPrototype(root: Element): {
  addEventListener: typeof EventTarget.prototype.addEventListener;
} {
  let proto: object | null = Object.getPrototypeOf(root);
  while (proto && !Object.prototype.hasOwnProperty.call(proto, "addEventListener")) {
    proto = Object.getPrototypeOf(proto);
  }
  return (proto ?? root) as {
    addEventListener: typeof EventTarget.prototype.addEventListener;
  };
}

export class RenderEventScope {
  private controller: AbortController | null = null;
  private registered: RegisteredRenderListener[] = [];

  public abort(): void {
    if (this.controller) {
      this.controller.abort();
      this.controller = null;
    }
    if (this.registered.length > 0) {
      const list = this.registered.splice(0);
      for (const item of list) {
        try {
          item.target.removeEventListener(item.type, item.listener, item.capture);
        } catch {}
      }
    }
  }

  public rebind(root: HTMLElement, bindFn: () => void): void {
    this.abort();
    const nextController = new AbortController();
    this.controller = nextController;
    const signal = nextController.signal;
    const registered = this.registered;
    const proto = findEventTargetPrototype(root);
    const originalAddEventListener = proto.addEventListener;

    proto.addEventListener = function scopedAddEventListener(
      this: EventTarget,
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions,
    ): void {
      const candidate = this as unknown as Element | null;
      if (
        listener &&
        candidate &&
        candidate.nodeType === 1 &&
        candidate !== root &&
        root.contains(candidate) &&
        candidate.id !== "cc-camera-live-img" &&
        candidate.id !== "cc-camera-video"
      ) {
        const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
        registered.push({ target: this, type, listener, capture });
        const mergedOptions: AddEventListenerOptions =
          typeof options === "boolean"
            ? { capture: options, signal }
            : options
              ? { ...options, signal }
              : { signal };
        return originalAddEventListener.call(this, type, listener, mergedOptions);
      }
      return originalAddEventListener.call(this, type, listener, options);
    };

    try {
      bindFn();
    } finally {
      proto.addEventListener = originalAddEventListener;
    }
  }
}

function hasActiveWebAnimations(ownerWin: Window & typeof globalThis): boolean {
  const proto = ownerWin.HTMLElement?.prototype;
  if (!proto || typeof proto.animate !== "function") return false;
  if ("happyDOM" in ownerWin) {
    return proto.animate !== ownerWin.Element?.prototype?.animate;
  }
  return true;
}

export class CameraStandbyController {
  private activeCancel: (() => void) | null = null;

  private findCameraBackdrop(root: HTMLElement): {
    backdrop: HTMLElement;
    sheet: HTMLElement;
  } | null {
    const sheet = root.querySelector<HTMLElement>(".cc-camera-live-sheet");
    const backdrop = sheet?.closest<HTMLElement>(".cc-sheet-backdrop") ?? null;
    if (!sheet || !backdrop) return null;
    return { backdrop, sheet };
  }

  public cancel(): void {
    if (this.activeCancel) {
      const fn = this.activeCancel;
      this.activeCancel = null;
      fn();
    }
  }

  public resumeFromStandby(root: HTMLElement): void {
    this.cancel();
    const pair = this.findCameraBackdrop(root);
    if (!pair) return;
    pair.backdrop.style.display = "";
    pair.backdrop.style.pointerEvents = "";
  }

  public enterWarmStandby(root: HTMLElement): void {
    this.cancel();
    const pair = this.findCameraBackdrop(root);
    if (!pair) return;
    const { backdrop, sheet } = pair;
    const ownerWin = (root.ownerDocument?.defaultView ?? window) as Window & typeof globalThis;

    if (prefersReducedMotion() || !hasActiveWebAnimations(ownerWin) || typeof sheet.animate !== "function") {
      backdrop.style.display = "none";
      backdrop.style.pointerEvents = "";
      return;
    }

    backdrop.style.display = "";
    backdrop.style.pointerEvents = "none";

    const sheetAnim = sheet.animate(FLUENT_MOTION.sheetExitKeyframes as Keyframe[], {
      duration: FLUENT_MOTION.exitDurationMs,
      easing: FLUENT_MOTION.accelerateEasing,
    });
    sheetAnim?.finished?.catch?.(() => {});

    if (!sheetAnim || typeof sheetAnim.finished?.then !== "function") {
      backdrop.style.display = "none";
      backdrop.style.pointerEvents = "";
      return;
    }

    const backdropAnim =
      typeof backdrop.animate === "function"
        ? backdrop.animate(FLUENT_MOTION.backdropExitKeyframes as Keyframe[], {
            duration: FLUENT_MOTION.exitDurationMs,
            easing: FLUENT_MOTION.accelerateEasing,
          })
        : null;
    backdropAnim?.finished?.catch?.(() => {});

    let settled = false;
    const timer = window.setTimeout(() => finish(true), FLUENT_MOTION.exitDurationMs + 60);
    const finish = (applyDisplayNone: boolean) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timer);
      if (this.activeCancel === cancelFn) {
        this.activeCancel = null;
      }
      try {
        sheetAnim.cancel?.();
        backdropAnim?.cancel?.();
      } catch {}
      backdrop.style.pointerEvents = "";
      if (applyDisplayNone) {
        backdrop.style.display = "none";
      }
    };
    const cancelFn = () => finish(false);
    this.activeCancel = cancelFn;

    void sheetAnim.finished.then(
      () => finish(true),
      () => finish(true),
    );
  }
}

export function syncDocumentLanguage(
  doc: Document | null | undefined,
  preference: LanguagePreference,
): "zh-CN" | "zh-TW" | "en" {
  const navLangs =
    typeof window !== "undefined" && window.navigator?.languages
      ? window.navigator.languages
      : typeof navigator !== "undefined"
        ? navigator.languages
        : [];
  const resolved = resolveLanguage(preference, navLangs);
  const langTag: "zh-CN" | "zh-TW" | "en" =
    resolved === "zh-Hant" ? "zh-TW" : resolved === "en" ? "en" : "zh-CN";
  if (doc?.documentElement) {
    doc.documentElement.lang = langTag;
  }
  return langTag;
}

interface LayerSnapshot {
  readonly activeSheet: string | null;
  readonly expandedDeviceId: string | null;
  readonly isCameraOpen: boolean;
  readonly cameraDeviceId: string | null;
  readonly isMenuOpen: boolean;
  readonly isPromptOpen: boolean;
}

function isSheetOpen(sheet: string | null | undefined): boolean {
  return Boolean(sheet && sheet !== "none");
}

interface StagedDepartureGhost {
  readonly ghost: HTMLElement;
  readonly rect: DOMRect;
  readonly keyframes: readonly Keyframe[];
  readonly durationMs: number;
  readonly zIndex: string;
}

function selectorForTriggerElement(el: Element | null, root: HTMLElement): string | null {
  if (!el || !root.contains(el) || el === root) return null;
  const target = el.closest<HTMLElement>("button, [tabindex], summary, input, select, textarea") ?? (el as HTMLElement);
  if (hasStableControlId(target.id)) {
    return `#${target.id}`;
  }
  const priorityAttrs = [
    "data-expand-device",
    "data-body-device",
    "data-toggle-device",
    "data-open-camera",
    "data-tile-id",
    "data-room",
    "data-kind",
    "data-settings-tab",
  ];
  for (const attr of priorityAttrs) {
    const val = target.getAttribute(attr);
    if (val !== null) {
      return `[${attr}="${val.replace(/"/g, '\\"')}"]`;
    }
  }
  return null;
}

export class PanelRenderPipeline {
  public readonly eventScope = new RenderEventScope();
  public readonly cameraStandby = new CameraStandbyController();

  private prevLayers: LayerSnapshot = {
    activeSheet: null,
    expandedDeviceId: null,
    isCameraOpen: false,
    cameraDeviceId: null,
    isMenuOpen: false,
    isPromptOpen: false,
  };
  private prevNotifKeys = new Set<string>();
  private hasRenderedOnce = false;
  private focusOrigins = new Map<string, string>();
  private activeGhostCleanups = new Set<() => void>();

  public recordFocusOrigin(
    layerKey: string,
    explicitTrigger?: Element | string | null,
    root?: HTMLElement,
  ): void {
    if (typeof explicitTrigger === "string" && explicitTrigger) {
      this.focusOrigins.set(layerKey, explicitTrigger);
      return;
    }
    if (explicitTrigger && typeof explicitTrigger === "object" && "nodeType" in explicitTrigger && root) {
      const sel = selectorForTriggerElement(explicitTrigger, root);
      if (sel) {
        this.focusOrigins.set(layerKey, sel);
      }
    }
  }

  public restoreFocusOrigin(root: HTMLElement, layerKey: string, fallbackSelector?: string): boolean {
    const selector = this.focusOrigins.get(layerKey) ?? fallbackSelector ?? null;
    this.focusOrigins.delete(layerKey);
    const candidates = [selector, fallbackSelector].filter((s): s is string => Boolean(s));
    for (const sel of candidates) {
      try {
        const target = root.querySelector<HTMLElement>(sel);
        if (target && typeof target.focus === "function") {
          target.focus();
          return true;
        }
      } catch {}
    }
    return false;
  }

  public clearTransientState(): void {
    for (const cleanup of Array.from(this.activeGhostCleanups)) {
      cleanup();
    }
    this.activeGhostCleanups.clear();
    this.cameraStandby.cancel();
    this.focusOrigins.clear();
    this.prevNotifKeys.clear();
    this.hasRenderedOnce = false;
    this.prevLayers = {
      activeSheet: null,
      expandedDeviceId: null,
      isCameraOpen: false,
      cameraDeviceId: null,
      isMenuOpen: false,
      isPromptOpen: false,
    };
  }

  public patchPopover(
    host: MenuMijiaWindowsApp,
    popoverClass: string,
    innerContent: string,
    extraPopoverAttrs?: Readonly<Record<string, string | null>>,
  ): void {
    const existingPopover = host.root.querySelector<HTMLElement>(":scope > .cc-popover");
    const heldAllOff = existingPopover?.querySelector<HTMLElement>("#btn-all-off.is-holding") ?? null;
    const attrParts: string[] = [];
    if (extraPopoverAttrs) {
      for (const [name, value] of Object.entries(extraPopoverAttrs)) {
        if (value !== null && value !== undefined) {
          attrParts.push(`${name}="${host.escapeHtml(value)}"`);
        }
      }
    }
    const attrSuffix = attrParts.length > 0 ? ` ${attrParts.join(" ")}` : "";
    const desiredPopover = parseSingleElement(
      `<div class="${popoverClass}"${attrSuffix}>${innerContent}</div>`,
    );

    this.eventScope.abort();

    if (existingPopover && desiredPopover) {
      for (const preservedAttr of ["data-keyboard-nav", "data-flyout-edge", "data-backdrop"]) {
        if (
          existingPopover.hasAttribute(preservedAttr) &&
          !desiredPopover.hasAttribute(preservedAttr)
        ) {
          desiredPopover.setAttribute(
            preservedAttr,
            existingPopover.getAttribute(preservedAttr) ?? "",
          );
        }
      }
      const activeElement = host.root.ownerDocument.activeElement;
      const activeDraftElement =
        activeElement &&
        existingPopover.contains(activeElement) &&
        (activeElement.tagName === "INPUT" || activeElement.tagName === "TEXTAREA") &&
        inputKeepsDraft(activeElement as HTMLInputElement | HTMLTextAreaElement)
          ? activeElement
          : null;
      const protectedMediaNodes = new Set<Element>();
      if (host.cameraLive.liveCameraImgEl) protectedMediaNodes.add(host.cameraLive.liveCameraImgEl);
      if (host.cameraLive.liveCameraRawMediaEl) protectedMediaNodes.add(host.cameraLive.liveCameraRawMediaEl);

      if (!activeDraftElement && protectedMediaNodes.size === 0 && hasMatchingDomShape(existingPopover, desiredPopover)) {
        morphMatchingDom(existingPopover, desiredPopover);
      } else {
        reconcileElementTree(existingPopover, desiredPopover, {
          activeDraftElement,
          protectedMediaNodes,
        });
      }
      if (heldAllOff && heldAllOff.parentNode) {
        const freshAllOff = heldAllOff.cloneNode(true) as HTMLElement;
        freshAllOff.classList.remove("is-holding");
        heldAllOff.parentNode.replaceChild(freshAllOff, heldAllOff);
      }
    } else if (desiredPopover) {
      host.root.replaceChildren(desiredPopover);
    } else {
      host.root.innerHTML = `<div class="${popoverClass}"${attrSuffix}>${innerContent}</div>`;
    }
  }

  public patchDimPreview(
    host: { readonly root: HTMLElement },
    deviceId: string,
    percent: number | null,
  ): void {
    const tiles = host.root.querySelectorAll<HTMLElement>("[data-tile-id]");
    let tile: HTMLElement | null = null;
    for (const candidate of Array.from(tiles)) {
      if (candidate.getAttribute("data-tile-id") === deviceId) {
        tile = candidate;
        break;
      }
    }
    if (!tile) return;

    const splitPill = tile.querySelector<HTMLElement>(".win-split-pill");
    let fillEl = tile.querySelector<HTMLElement>(".cc-tile-fill");

    if (percent === null) {
      tile.classList.remove("is-dimming");
      if (tile.classList.contains("is-capsule") && fillEl) {
        fillEl.remove();
      }
      return;
    }

    tile.classList.add("is-dimming");
    if (percent > 0) {
      if (!fillEl) {
        fillEl = tile.ownerDocument.createElement("span");
        fillEl.className = "cc-tile-fill";
        if (splitPill) {
          splitPill.insertBefore(fillEl, splitPill.firstChild);
        } else {
          tile.insertBefore(fillEl, tile.firstChild);
        }
      }
      fillEl.setAttribute("style", `width:${percent}%;--fill-scale:${(percent / 100).toFixed(3)}`);
    } else if (fillEl) {
      fillEl.remove();
    }

    const statusEl = tile.querySelector<HTMLElement>(".cc-tile-status");
    if (statusEl) {
      const label = `${percent}%`;
      statusEl.textContent = label;
      statusEl.setAttribute("title", label);
    }
  }

  public updateSliderThumbBadge(slider: HTMLInputElement, text: string, visible: boolean): void {
    const parent = slider.parentElement;
    if (!parent) return;
    let badge = parent.querySelector<HTMLElement>(".cc-slider-thumb-badge");
    if (!visible) {
      if (badge) {
        badge.classList.remove("is-visible");
        badge.setAttribute("aria-hidden", "true");
      }
      return;
    }
    if (!badge) {
      badge = slider.ownerDocument.createElement("span");
      badge.className = "cc-slider-thumb-badge";
      badge.setAttribute("aria-hidden", "true");
      parent.appendChild(badge);
    }
    const min = Number(slider.min || "0");
    const max = Number(slider.max || "100");
    const val = Number(slider.value || "0");
    const ratio = max > min ? Math.max(0, Math.min(1, (val - min) / (max - min))) : 0;
    const leftPct =
      slider.offsetWidth > 0 && parent.clientWidth > 0
        ? ((slider.offsetLeft + 8 + ratio * Math.max(0, slider.offsetWidth - 16)) / parent.clientWidth) * 100
        : ratio * 100;
    badge.textContent = text;
    badge.classList.add("is-visible");
    badge.style.setProperty("--thumb-ratio", ratio.toFixed(4));
    badge.style.setProperty("--thumb-left", `${leftPct.toFixed(2)}%`);
    badge.style.left = `${leftPct.toFixed(2)}%`;
  }

  private snapshotLayers(host: MenuMijiaWindowsApp): LayerSnapshot {
    return {
      activeSheet: host.activeSheet,
      expandedDeviceId: host.expandedDeviceId,
      isCameraOpen:
        host.cameraLive.activeLiveCameraId !== null && !host.cameraLive.liveCameraHidden,
      cameraDeviceId: host.cameraLive.activeLiveCameraId,
      isMenuOpen: host.isHomeMenuOpen || host.ctxMenu !== null,
      isPromptOpen: host.prompt !== null,
    };
  }

  private mountDepartureGhost(popover: HTMLElement, staged: StagedDepartureGhost): void {
    const popoverRect = popover.getBoundingClientRect();
    const { ghost, rect, keyframes, durationMs, zIndex } = staged;
    ghost.style.position = "absolute";
    ghost.style.top = `${Math.max(0, rect.top - popoverRect.top)}px`;
    ghost.style.left = `${Math.max(0, rect.left - popoverRect.left)}px`;
    if (rect.width > 0) ghost.style.width = `${rect.width}px`;
    if (rect.height > 0) ghost.style.height = `${rect.height}px`;
    ghost.style.pointerEvents = "none";
    ghost.style.zIndex = zIndex;

    popover.appendChild(ghost);
    const anim = ghost.animate(keyframes as Keyframe[], {
      duration: durationMs,
      easing: FLUENT_MOTION.accelerateEasing,
      fill: "forwards",
    });
    anim?.finished?.catch?.(() => {});

    if (!anim || typeof anim.finished?.then !== "function") {
      ghost.remove();
      return;
    }

    let cleaned = false;
    const timer = window.setTimeout(() => cleanup(), durationMs + 60);
    const cleanup = () => {
      if (cleaned) return;
      cleaned = true;
      window.clearTimeout(timer);
      this.activeGhostCleanups.delete(cleanup);
      try {
        anim.cancel?.();
      } catch {}
      ghost.remove();
    };
    this.activeGhostCleanups.add(cleanup);
    void anim.finished.then(cleanup, cleanup);
  }

  public commitRender(host: MenuMijiaWindowsApp): void {
    if (host.panelSearch.isComposing) {
      if (
        host.activeSheet !== "none" ||
        document.activeElement?.id !== "command-input" ||
        host.panelSearch.compositionSourceRevision !== host.sourceRevision
      ) {
        host.panelSearch.isComposing = false;
      } else {
        host.pendingCloudRender = true;
        return;
      }
    }

    const prev = this.prevLayers;
    const next = this.snapshotLayers(host);
    const activeEl = host.root.ownerDocument.activeElement;
    const triggerSelector = selectorForTriggerElement(activeEl, host.root);

    if (!isSheetOpen(prev.activeSheet) && isSheetOpen(next.activeSheet)) {
      const origin =
        triggerSelector && triggerSelector !== "#command-input" ? triggerSelector : "#btn-settings";
      this.focusOrigins.set("sheet", origin);
    }
    if (prev.expandedDeviceId === null && next.expandedDeviceId !== null) {
      const escapedId = next.expandedDeviceId.replace(/"/g, '\\"');
      const defaultExpandSelector = `[data-expand-device="${escapedId}"]`;
      const origin =
        triggerSelector &&
        triggerSelector !== "#command-input" &&
        triggerSelector.includes(escapedId)
          ? triggerSelector
          : defaultExpandSelector;
      this.focusOrigins.set("subpage", origin);
    }
    if (!prev.isCameraOpen && next.isCameraOpen && next.cameraDeviceId) {
      const escapedId = next.cameraDeviceId.replace(/"/g, '\\"');
      const origin =
        triggerSelector && triggerSelector !== "#command-input"
          ? triggerSelector
          : `[data-open-camera="${escapedId}"]`;
      this.focusOrigins.set("camera", origin);
    }
    if (!prev.isMenuOpen && next.isMenuOpen) {
      const origin =
        triggerSelector && triggerSelector !== "#command-input" ? triggerSelector : "#btn-home-menu";
      this.focusOrigins.set("menu", origin);
    }
    if (!prev.isPromptOpen && next.isPromptOpen && triggerSelector) {
      this.focusOrigins.set("prompt", triggerSelector);
    }

    const focused = document.activeElement as HTMLElement | null;
    const focusedInput =
      focused && (focused.tagName === "INPUT" || focused.tagName === "TEXTAREA")
        ? (focused as HTMLInputElement | HTMLTextAreaElement)
        : null;
    const keepsFocusedDraft = focusedInput ? inputKeepsDraft(focusedInput) : false;
    const focusAttributes = focused
      ? Array.from(focused.attributes)
          .filter((attr) => attr.name === "id" || attr.name.startsWith("data-"))
          .map((attr) => ({ name: attr.name, value: attr.value }))
      : [];
    const focusSnapshot =
      focused && focusAttributes.length > 0
        ? {
            tagName: focused.tagName,
            attributes: focusAttributes,
            value: keepsFocusedDraft ? focusedInput?.value ?? null : null,
            selectionStart: keepsFocusedDraft ? focusedInput?.selectionStart ?? null : null,
            selectionEnd: keepsFocusedDraft ? focusedInput?.selectionEnd ?? null : null,
          }
        : null;

    const prevSubpageId =
      host.root.querySelector<HTMLElement>(".cc-tile.is-subpage:not([data-exit-ghost])")?.dataset
        .tileId ?? null;
    const ownerWin = (host.root.ownerDocument?.defaultView ?? window) as Window & typeof globalThis;
    const canAnimate = !prefersReducedMotion() && hasActiveWebAnimations(ownerWin);

    const stagedGhosts: StagedDepartureGhost[] = [];
    const stagedNotifGhosts = new Map<string, StagedDepartureGhost>();
    const existingPopover = host.root.querySelector<HTMLElement>(":scope > .cc-popover");

    if (canAnimate && existingPopover && this.hasRenderedOnce) {
      if (prev.expandedDeviceId !== null && next.expandedDeviceId === null) {
        const subpageEl = existingPopover.querySelector<HTMLElement>(
          ".cc-tile.is-subpage:not([data-exit-ghost])",
        );
        if (subpageEl) {
          stagedGhosts.push({
            ghost: sanitizeDepartureGhost(subpageEl),
            rect: subpageEl.getBoundingClientRect(),
            keyframes: FLUENT_MOTION.subpageExitKeyframes,
            durationMs: FLUENT_MOTION.exitDurationMs,
            zIndex: "25",
          });
        }
      }
      if (isSheetOpen(prev.activeSheet) && !isSheetOpen(next.activeSheet)) {
        const sheetEl = existingPopover.querySelector<HTMLElement>(
          ".cc-sheet:not(.cc-camera-live-sheet):not([data-exit-ghost])",
        );
        if (sheetEl) {
          stagedGhosts.push({
            ghost: sanitizeDepartureGhost(sheetEl),
            rect: sheetEl.getBoundingClientRect(),
            keyframes: FLUENT_MOTION.sheetExitKeyframes,
            durationMs: FLUENT_MOTION.exitDurationMs,
            zIndex: "35",
          });
        }
      }
      if (prev.isPromptOpen && !next.isPromptOpen) {
        const promptEl = existingPopover.querySelector<HTMLElement>(
          ".cc-prompt:not([data-exit-ghost])",
        );
        if (promptEl) {
          stagedGhosts.push({
            ghost: sanitizeDepartureGhost(promptEl),
            rect: promptEl.getBoundingClientRect(),
            keyframes: FLUENT_MOTION.dialogExitKeyframes,
            durationMs: FLUENT_MOTION.dialogExitDurationMs,
            zIndex: "55",
          });
        }
      }
      if (prev.isMenuOpen && !next.isMenuOpen) {
        const menuEl = existingPopover.querySelector<HTMLElement>(
          ".cc-menu:not([data-exit-ghost])",
        );
        if (menuEl) {
          stagedGhosts.push({
            ghost: sanitizeDepartureGhost(menuEl),
            rect: menuEl.getBoundingClientRect(),
            keyframes: FLUENT_MOTION.menuExitKeyframes,
            durationMs: FLUENT_MOTION.menuExitDurationMs,
            zIndex: "45",
          });
        }
      }
      existingPopover
        .querySelectorAll<HTMLElement>(".win-notif-stack .win-notif-card:not([data-exit-ghost])")
        .forEach((cardEl) => {
          const key = extractControlIdentityKey(cardEl);
          if (key) {
            stagedNotifGhosts.set(key, {
              ghost: sanitizeDepartureGhost(cardEl),
              rect: cardEl.getBoundingClientRect(),
              keyframes: FLUENT_MOTION.bannerExitKeyframes,
              durationMs: FLUENT_MOTION.dialogExitDurationMs,
              zIndex: "20",
            });
          }
        });
    }

    const before = new Map<string, DOMRect>();
    if (canAnimate && prev.expandedDeviceId === null && next.expandedDeviceId === null) {
      host.root
        .querySelectorAll<HTMLElement>("[data-tile-id]:not([data-exit-ghost])")
        .forEach((el) => {
          const rect = el.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0 && el.dataset.tileId) {
            before.set(el.dataset.tileId, rect);
          }
        });
    }

    const scrollTop = host.root.querySelector(".cc-scroll-area")?.scrollTop ?? 0;
    const roomLeft = host.root.querySelector(".cc-room-scroll")?.scrollLeft ?? 0;
    const sheetScroll =
      host.root.querySelector<HTMLElement>(".cc-sheet-body:not([data-exit-ghost])") ??
      host.root.querySelector<HTMLElement>(".cc-sheet:not([data-exit-ghost])");
    const sheetScrollTop = sheetScroll?.scrollTop ?? 0;
    const settingsDraft = captureSettingsDraft(host.root);

    host.pendingCloudRender = false;
    renderPanel(host);
    syncPanelSelection(host);
    this.prevLayers = next;

    const currentNotifKeys = new Set<string>();
    const newlyAddedNotifCards: HTMLElement[] = [];
    host.root
      .querySelectorAll<HTMLElement>(".win-notif-stack .win-notif-card:not([data-exit-ghost])")
      .forEach((cardEl) => {
        const key = extractControlIdentityKey(cardEl);
        if (key) {
          currentNotifKeys.add(key);
          if (this.hasRenderedOnce && !this.prevNotifKeys.has(key)) {
            newlyAddedNotifCards.push(cardEl);
          }
        }
      });
    this.prevNotifKeys = currentNotifKeys;
    const wasFirstRender = !this.hasRenderedOnce;
    this.hasRenderedOnce = true;

    const nextSubpageEl = host.root.querySelector<HTMLElement>(
      ".cc-tile.is-subpage:not([data-exit-ghost])",
    );
    const nextSubpageId = nextSubpageEl?.dataset.tileId ?? null;
    const area = host.root.querySelector(".cc-scroll-area");
    if (area) {
      if (prevSubpageId === null && nextSubpageId !== null) {
        host.savedGridScrollTop = scrollTop;
        area.scrollTop = 0;
      } else if (prevSubpageId !== null && nextSubpageId === null) {
        area.scrollTop = host.savedGridScrollTop;
      } else if (prevSubpageId !== nextSubpageId) {
        area.scrollTop = 0;
      } else {
        area.scrollTop = scrollTop;
      }
    }
    const strip = host.root.querySelector<HTMLElement>(".cc-room-scroll");
    if (strip) strip.scrollLeft = roomLeft;
    const sheet =
      host.root.querySelector<HTMLElement>(".cc-sheet-body:not([data-exit-ghost])") ??
      host.root.querySelector<HTMLElement>(".cc-sheet:not([data-exit-ghost])");
    if (sheet) sheet.scrollTop = sheetScrollTop;
    if (
      restoreSettingsDraft(host.root, settingsDraft, (el, url) =>
        host.syncKeyFieldWithEndpoint(el, url),
      )
    ) {
      refreshHabitSharePreview(host);
    }

    const closedSheet = isSheetOpen(prev.activeSheet) && !isSheetOpen(next.activeSheet);
    const closedSubpage = prev.expandedDeviceId !== null && next.expandedDeviceId === null;
    const closedCamera = prev.isCameraOpen && !next.isCameraOpen;
    const closedMenu = prev.isMenuOpen && !next.isMenuOpen;
    const closedPrompt = prev.isPromptOpen && !next.isPromptOpen;
    const keepCommandFocus = focusSnapshot?.attributes.some(
      (a) => a.name === "id" && a.value === "command-input",
    );

    if (closedSheet && !keepCommandFocus) {
      this.restoreFocusOrigin(host.root, "sheet", "#btn-settings");
    } else if (closedSubpage && !keepCommandFocus && prev.expandedDeviceId) {
      const escapedId = prev.expandedDeviceId.replace(/"/g, '\\"');
      this.restoreFocusOrigin(
        host.root,
        "subpage",
        `[data-expand-device="${escapedId}"], [data-body-device="${escapedId}"], [data-tile-id="${escapedId}"]`,
      );
    } else if (closedCamera && !keepCommandFocus && prev.cameraDeviceId) {
      const escapedId = prev.cameraDeviceId.replace(/"/g, '\\"');
      this.restoreFocusOrigin(
        host.root,
        "camera",
        `[data-open-camera="${escapedId}"], [data-body-device="${escapedId}"], [data-tile-id="${escapedId}"]`,
      );
    } else if (closedMenu && !keepCommandFocus) {
      this.restoreFocusOrigin(host.root, "menu", "#btn-home-menu");
    } else if (closedPrompt && !keepCommandFocus) {
      this.restoreFocusOrigin(host.root, "prompt");
    } else if (focusSnapshot) {
      const matches = Array.from(
        host.root.querySelectorAll<HTMLElement>(focusSnapshot.tagName.toLowerCase()),
      ).filter(
        (element) =>
          !element.hasAttribute("data-exit-ghost") &&
          !element.closest("[data-exit-ghost]") &&
          focusSnapshot.attributes.every(
            (attribute) => element.getAttribute(attribute.name) === attribute.value,
          ),
      );
      const replacement = matches.length === 1 ? matches[0] : undefined;
      if (replacement) {
        if (focusSnapshot.value !== null && "value" in replacement) {
          (replacement as HTMLInputElement).value = focusSnapshot.value;
        }
        replacement.focus({ preventScroll: true });
        if (focusSnapshot.selectionStart !== null && "setSelectionRange" in replacement) {
          (replacement as HTMLInputElement).setSelectionRange(
            focusSnapshot.selectionStart,
            focusSnapshot.selectionEnd ?? focusSnapshot.selectionStart,
          );
        }
      }
    }

    if (canAnimate) {
      const popover = host.root.querySelector<HTMLElement>(":scope > .cc-popover");
      if (popover && !wasFirstRender) {
        for (const staged of stagedGhosts) {
          this.mountDepartureGhost(popover, staged);
        }
        for (const [key, staged] of stagedNotifGhosts) {
          if (!currentNotifKeys.has(key)) {
            this.mountDepartureGhost(popover, staged);
          }
        }
      }

      if (isSheetOpen(next.activeSheet) && next.activeSheet !== prev.activeSheet) {
        const sheetEl = host.root.querySelector<HTMLElement>(
          ".cc-sheet:not(.cc-camera-live-sheet):not([data-exit-ghost])",
        );
        const backdropEl = sheetEl?.closest<HTMLElement>(".cc-sheet-backdrop") ?? null;
        sheetEl?.animate?.(FLUENT_MOTION.sheetEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.enterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
        backdropEl?.animate?.(FLUENT_MOTION.backdropEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.fastEnterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      }

      if (next.isCameraOpen && !prev.isCameraOpen) {
        const cameraSheetEl = host.root.querySelector<HTMLElement>(
          ".cc-camera-live-sheet:not([data-exit-ghost])",
        );
        const backdropEl = cameraSheetEl?.closest<HTMLElement>(".cc-sheet-backdrop") ?? null;
        cameraSheetEl?.animate?.(FLUENT_MOTION.sheetEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.enterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
        backdropEl?.animate?.(FLUENT_MOTION.backdropEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.fastEnterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      }

      if (nextSubpageEl && nextSubpageId !== null && nextSubpageId !== prevSubpageId) {
        nextSubpageEl.animate?.(FLUENT_MOTION.subpageEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.enterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      } else if (prevSubpageId !== null && nextSubpageId === null) {
        host.root
          .querySelector<HTMLElement>(".cc-scroll-area")
          ?.animate?.(FLUENT_MOTION.drillOutReturnKeyframes as Keyframe[], {
            duration: FLUENT_MOTION.enterDurationMs,
            easing: FLUENT_MOTION.decelerateEasing,
          });
      } else if (prevSubpageId === null && nextSubpageId === null && before.size > 0) {
        host.root
          .querySelectorAll<HTMLElement>("[data-tile-id]:not([data-exit-ghost])")
          .forEach((el) => {
            const id = el.dataset.tileId as string;
            const old = before.get(id);
            if (!old || id === host.draggingId) return;
            const now = el.getBoundingClientRect();
            if (now.width === 0 || now.height === 0) return;
            const dx = old.left - now.left;
            const dy = old.top - now.top;
            if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
            el.animate?.(
              [
                { transform: `translate(${dx}px, ${dy}px)` },
                { transform: "translate(0, 0)" },
              ],
              {
                duration: FLUENT_MOTION.flipDurationMs,
                easing: FLUENT_MOTION.decelerateEasing,
              },
            );
          });
      }

      if (next.isPromptOpen && !prev.isPromptOpen) {
        const promptEl = host.root.querySelector<HTMLElement>(
          ".cc-prompt:not([data-exit-ghost])",
        );
        const backdropEl = host.root.querySelector<HTMLElement>(
          ".cc-prompt-backdrop:not([data-exit-ghost])",
        );
        promptEl?.animate?.(FLUENT_MOTION.dialogEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.fastEnterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
        backdropEl?.animate?.(FLUENT_MOTION.backdropEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.fastEnterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      }

      if (next.isMenuOpen && !prev.isMenuOpen) {
        const menuEl = host.root.querySelector<HTMLElement>(
          ".cc-menu:not([data-exit-ghost])",
        );
        menuEl?.animate?.(FLUENT_MOTION.menuEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.fastEnterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      }

      for (const cardEl of newlyAddedNotifCards) {
        cardEl.animate?.(FLUENT_MOTION.bannerEnterKeyframes as Keyframe[], {
          duration: FLUENT_MOTION.enterDurationMs,
          easing: FLUENT_MOTION.decelerateEasing,
        });
      }
    }

    host.applyDragOffset();
    host.animateEntrance = false;
    host.poppedDeviceId = null;
  }
}
