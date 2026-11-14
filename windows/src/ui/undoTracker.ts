import {
  currentLanguage,
  resolveLanguage,
  t,
  type AppLanguage,
  type LanguagePreference,
} from "../core/i18n.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoAction } from "./appTypes.js";
import { isUndoHoverPaused } from "./speechGuard.js";

export const UNDO_AVAILABILITY_WINDOW_MS = 10 * 60 * 1000;

export function undoBannerMs(deviceCount: number): number {
  return (deviceCount >= 3 ? 15 : 10) * 1000;
}

export function undoDeviceCount(steps: readonly { readonly deviceId: string }[]): number {
  return new Set(steps.map((step) => step.deviceId)).size;
}

function fillParams(
  template: string,
  params?: Readonly<Record<string, string | number>>,
): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole,
  );
}

export function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  params?: Readonly<Record<string, string | number>>,
  preference?: LanguagePreference,
): string {
  const lang: AppLanguage =
    preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : currentLanguage();
  const chosen = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  return fillParams(chosen, params);
}

export interface UndoAvailabilitySnapshot {
  readonly isAvailable: boolean;
  readonly shouldShowHeaderPill: boolean;
  readonly summary: string | null;
  readonly remainingMs: number;
  readonly expiresAtMs: number | null;
}

export class UndoAvailabilityTracker {
  public static readonly windowMs = UNDO_AVAILABILITY_WINDOW_MS;

  private trackedExpiresAtMs: number | null = null;
  private trackedActionAtMs: number | null = null;
  private trackedSummary: string | null = null;
  private expiryTimer: ReturnType<typeof setTimeout> | null = null;

  public get lastActionAtMs(): number | null {
    return this.trackedActionAtMs;
  }

  public get summary(): string | null {
    return this.trackedSummary;
  }

  public get expiresAtMs(): number | null {
    return this.trackedExpiresAtMs;
  }

  public get isAvailable(): boolean {
    return this.remainingMs() > 0;
  }

  public remainingMs(now = Date.now()): number {
    if (this.trackedExpiresAtMs === null) return 0;
    return Math.max(0, this.trackedExpiresAtMs - now);
  }

  public syncAction(
    action: Pick<UndoAction, "summary" | "expiresAtMs"> | null,
    now = Date.now(),
    onExpire?: () => void,
  ): void {
    this.clearTimer();
    this.trackedExpiresAtMs = null;
    this.trackedActionAtMs = null;
    this.trackedSummary = null;
    if (!action) return;
    const remaining = action.expiresAtMs - now;
    if (remaining <= 0) return;
    this.trackedExpiresAtMs = action.expiresAtMs;
    this.trackedActionAtMs = action.expiresAtMs - UndoAvailabilityTracker.windowMs;
    this.trackedSummary = action.summary;
    if (onExpire) {
      this.expiryTimer = setTimeout(() => {
        this.expiryTimer = null;
        this.trackedExpiresAtMs = null;
        this.trackedActionAtMs = null;
        this.trackedSummary = null;
        onExpire();
      }, remaining);
      if (typeof this.expiryTimer === "object" && this.expiryTimer !== null && "unref" in this.expiryTimer) {
        (this.expiryTimer as { unref(): void }).unref();
      }
    }
  }

  public async performUndo(host: Pick<MenuMijiaWindowsApp, "performUndo" | "lastUndoAction">): Promise<void> {
    this.syncAction(null);
    await host.performUndo();
    this.syncAction(host.lastUndoAction);
  }

  public dispose(): void {
    this.clearTimer();
    this.trackedExpiresAtMs = null;
    this.trackedActionAtMs = null;
    this.trackedSummary = null;
  }

  private clearTimer(): void {
    if (this.expiryTimer !== null) {
      clearTimeout(this.expiryTimer);
      this.expiryTimer = null;
    }
  }
}

export function computeUndoAvailability(
  host: MenuMijiaWindowsApp,
  now = Date.now(),
): UndoAvailabilitySnapshot {
  const action = host.lastUndoAction;
  if (!action) {
    return {
      isAvailable: false,
      shouldShowHeaderPill: false,
      summary: null,
      remainingMs: 0,
      expiresAtMs: null,
    };
  }
  const paused = isUndoHoverPaused(host);
  const remainingMs = Math.max(0, action.expiresAtMs - now);
  const isAvailable = paused || remainingMs > 0;
  if (!isAvailable) {
    return {
      isAvailable: false,
      shouldShowHeaderPill: false,
      summary: null,
      remainingMs: 0,
      expiresAtMs: null,
    };
  }
  const bannerUndoVisible = host.undoButtonVisible(now);
  const shouldShowHeaderPill =
    !bannerUndoVisible && !host.pendingCloudConsent && !host.isEditingLayout;
  return {
    isAvailable: true,
    shouldShowHeaderPill,
    summary: action.summary,
    remainingMs,
    expiresAtMs: action.expiresAtMs,
  };
}

export function formatUndoPillTooltip(
  host: Pick<MenuMijiaWindowsApp, "formatRemainingMs">,
  summary: string,
  remainingMs: number,
): string {
  const remaining = host.formatRemainingMs(Math.max(1000, remainingMs));
  return tr3(
    "撤销：{summary}（剩余 {remaining}）",
    "撤銷：{summary}（剩餘 {remaining}）",
    "Undo: {summary} ({remaining} left)",
    { summary, remaining },
  );
}

const trackerByHost = new WeakMap<MenuMijiaWindowsApp, UndoAvailabilityTracker>();

export function undoTrackerFor(host: MenuMijiaWindowsApp): UndoAvailabilityTracker {
  let tracker = trackerByHost.get(host);
  if (!tracker) {
    tracker = new UndoAvailabilityTracker();
    trackerByHost.set(host, tracker);
  }
  return tracker;
}

export function renderPersistentUndoPill(
  host: MenuMijiaWindowsApp,
  now = Date.now(),
): string {
  const state = computeUndoAvailability(host, now);
  const tracker = undoTrackerFor(host);
  if (!state.isAvailable || isUndoHoverPaused(host) || !host.lastUndoAction) {
    tracker.syncAction(null, now);
  } else if (tracker.expiresAtMs !== state.expiresAtMs || tracker.summary !== state.summary) {
    tracker.syncAction(host.lastUndoAction, now, () => {
      if (host.lastUndoAction && host.lastUndoAction.expiresAtMs <= Date.now()) {
        host.lastUndoAction = null;
      }
      host.queueBackgroundRender();
    });
  }
  if (!state.shouldShowHeaderPill || !state.summary) return "";
  const tooltip = formatUndoPillTooltip(host, state.summary, state.remainingMs);
  const safeTooltip = host.escapeHtml(tooltip);
  return `<button
    type="button"
    class="cc-inline-pill"
    id="btn-header-undo"
    data-persistent-undo
    title="${safeTooltip}"
    aria-label="${safeTooltip}"
    style="height:28px;padding:0 10px;display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:600;white-space:nowrap;flex-shrink:0;"
  >↶ ${t("撤销")}</button>`;
}

export function bindPersistentUndoEvents(host: MenuMijiaWindowsApp): void {
  const button = host.root.querySelector<HTMLButtonElement>("#btn-header-undo");
  if (!button) return;
  button.addEventListener("click", () => {
    void host.performUndo();
  });
}
