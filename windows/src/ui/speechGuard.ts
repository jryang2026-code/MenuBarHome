import {
  AppURLParser,
  formatAppURLCommandLabel,
  onOpenURL,
  type AppURLCommandHost,
  type BuiltInURLSceneId,
} from "../core/appUrlCommand.js";
import { speechLocale, t } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { allOffTargets, hasDetailDrawer, type SmartDevice } from "../core/models.js";
import { planQuickAction, trText, type QuickActionId } from "../core/quickActions.js";
import {
  RaycastBridgeTokenManager,
  buildRaycastSnapshot,
  formatDynamicTraySummary,
  type RaycastCommandFeedback,
  type RaycastSnapshot,
} from "../core/raycastSnapshot.js";
import { undoBannerMs, undoDeviceCount, type MenuMijiaWindowsApp } from "./app.js";
import type {
  PersistedSettings,
  SpeechRecognitionInstance,
  UndoAction,
  UndoStep,
} from "./appTypes.js";
import { foldGrouped } from "./cloudRefresh.js";
import { recordHabits } from "./intentExecution.js";
import { filterByListCut } from "./listCut.js";
import { invokeTauriVoid, isWorkstationLockBlockingControl } from "./transport.js";

export interface UpdateDownloadProgress {
  readonly downloadedBytes: number;
  readonly totalBytes: number;
  readonly bytesPerSec: number;
}

interface PendingUrlConfirmationEntry {
  readonly description: string;
  readonly commandLabel: string;
  readonly requestId?: string;
  readonly sourceRevision: number;
  readonly resolve: (approved: boolean) => void;
}

/** One external link waiting its turn, stamped with the home it was opened against. */
interface QueuedOpenUrl {
  readonly url: string;
  /**
   * `host.sourceRevision` when the link entered the queue. A link captured against one data source
   * must never run against another: its `bridgeToken` and device ids belong to the old home.
   */
  readonly sourceRevision: number;
  readonly done: () => void;
}

interface UndoHoverPauseSnapshot {
  readonly action: UndoAction;
  readonly remainingActionMs: number;
  readonly remainingBannerMs: number;
}

interface HostRuntimeGuardState {
  speechRecognition: SpeechRecognitionInstance | null;
  trackedUndoAction: UndoAction | null;
  undoBannerTimer: number | null;
  pointerInsideBanner: boolean;
  hoverPause: UndoHoverPauseSnapshot | null;
  lastMiExpiryKind: "valid" | "expiringSoon" | "expired";
  bridgeTokens: RaycastBridgeTokenManager;
  snapshotExportTimer: number | null;
  lastExportedComparableJson: string | null;
  lastCommandFeedback: RaycastCommandFeedback | undefined;
  lastTraySummary: string | null | undefined;
  pendingUrlConfirmation: PendingUrlConfirmationEntry | null;
  urlQueue: QueuedOpenUrl[];
  isDrainingUrlQueue: boolean;
  lockBlockCount: number;
  exportSeq: number;
  bridgeTokenWarningShown: boolean;
}

const runtimeStateByHost = new WeakMap<MenuMijiaWindowsApp, HostRuntimeGuardState>();
const undoKindSnapshots = new WeakMap<UndoAction, ReadonlyMap<string, SmartDevice["kind"]>>();
const updateProgressBySettings = new WeakMap<PersistedSettings, UpdateDownloadProgress>();

let scheduledTimerTickDepth = 0;

export function runWithScheduledTimerTickExemption<T>(fn: () => T): T {
  scheduledTimerTickDepth += 1;
  try {
    return fn();
  } finally {
    scheduledTimerTickDepth = Math.max(0, scheduledTimerTickDepth - 1);
  }
}

export function isInsideScheduledTimerTick(): boolean {
  return scheduledTimerTickDepth > 0;
}

export function getUpdateProgressForSettings(
  settings: PersistedSettings,
): UpdateDownloadProgress | null {
  return updateProgressBySettings.get(settings) ?? null;
}

export function clearUpdateProgress(host: MenuMijiaWindowsApp): void {
  updateProgressBySettings.delete(host.settings);
}

function hostState(host: MenuMijiaWindowsApp): HostRuntimeGuardState {
  let state = runtimeStateByHost.get(host);
  if (!state) {
    state = {
      speechRecognition: null,
      trackedUndoAction: null,
      undoBannerTimer: null,
      pointerInsideBanner: false,
      hoverPause: null,
      lastMiExpiryKind: "valid",
      bridgeTokens: new RaycastBridgeTokenManager(),
      snapshotExportTimer: null,
      lastExportedComparableJson: null,
      lastCommandFeedback: undefined,
      lastTraySummary: undefined,
      pendingUrlConfirmation: null,
      urlQueue: [],
      isDrainingUrlQueue: false,
      lockBlockCount: 0,
      exportSeq: 0,
      bridgeTokenWarningShown: false,
    };
    runtimeStateByHost.set(host, state);
  }
  return state;
}

export function hasPendingUrlConfirmation(host: MenuMijiaWindowsApp): boolean {
  return hostState(host).pendingUrlConfirmation !== null;
}

export function shouldKeepPopoverPinned(host: MenuMijiaWindowsApp): boolean {
  return (
    host.isPollingQR ||
    host.activeSheet !== "none" ||
    host.isEditingLayout ||
    host.prompt !== null ||
    hasPendingUrlConfirmation(host) ||
    host.isListeningVoice ||
    (host.cameraLive.activeLiveCameraId !== null && !host.cameraLive.liveCameraHidden)
  );
}

export function abortVoiceInput(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  const current = state.speechRecognition;
  const wasListening = host.isListeningVoice || current !== null;
  state.speechRecognition = null;
  host.isListeningVoice = false;
  if (wasListening) {
    invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
  }
  if (current) {
    try {
      current.stop();
    } catch {
      // Already stopped or aborted.
    }
  }
}

export function toggleVoiceInput(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  if (host.isListeningVoice) {
    abortVoiceInput(host);
    host.render();
    return;
  }

  const SpeechCtor = window.SpeechRecognition ?? window.webkitSpeechRecognition;
  if (!SpeechCtor) {
    host.isShowingAssistantBar = true;
    host.replyBanner = {
      text: t("当前系统环境不支持离线语音识别，请直接输入文字指令。"),
      source: t("语音提示"),
    };
    host.render();
    host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
    return;
  }

  host.isShowingAssistantBar = true;
  const recognition = new SpeechCtor();
  recognition.lang = speechLocale();
  recognition.interimResults = false;
  recognition.continuous = false;

  recognition.onresult = (event) => {
    const first = event.results[0]?.[0]?.transcript;
    if (first) {
      const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
      if (inputEl) inputEl.value = "";
      void host.handleNaturalCommand(first);
    }
  };
  const finishRecognition = () => {
    if (state.speechRecognition !== recognition && !host.isListeningVoice) return;
    if (state.speechRecognition === recognition) {
      state.speechRecognition = null;
    }
    host.isListeningVoice = false;
    invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
    host.render();
  };
  recognition.onerror = finishRecognition;
  recognition.onend = finishRecognition;

  state.speechRecognition = recognition;
  host.isListeningVoice = true;
  // Pin before start() so OS mic permission dialogs or focus loss never collapse the popover.
  invokeTauriVoid("set_pin_popover", { pin: true });
  host.render();
  try {
    recognition.start();
  } catch {
    abortVoiceInput(host);
    host.render();
  }
}

export function isUndoHoverPaused(host: MenuMijiaWindowsApp): boolean {
  const state = hostState(host);
  return state.hoverPause !== null && state.hoverPause.action === host.lastUndoAction;
}

export function clearUndoHoverPause(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  state.pointerInsideBanner = false;
  state.hoverPause = null;
  state.trackedUndoAction = null;
  if (state.undoBannerTimer !== null) {
    window.clearTimeout(state.undoBannerTimer);
    state.undoBannerTimer = null;
  }
  cancelPendingExternalUrlWork(host);
}

/**
 * Drops every external link that has not run yet: the one on screen and everything queued behind
 * it. Each rejected entry still resolves its `done()` Promise, so `enqueueIncomingOpenUrl` waiters
 * cannot hang when the panel hides or the data source is replaced.
 *
 * The queue entries are cancelled in place (not via `done()` alone) because the drain loop owns the
 * shift; a cancelled entry is skipped when the loop reaches it, and the loop exits once the queue
 * is empty.
 */
export function cancelPendingExternalUrlWork(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  if (state.pendingUrlConfirmation !== null) {
    const pending = state.pendingUrlConfirmation;
    state.pendingUrlConfirmation = null;
    pending.resolve(false);
  }
}

/** How long the 撤销 control stays up. Matches macOS `undoBannerSeconds`: 10s, or 15s from three devices. */
export function syncUndoBannerClock(host: MenuMijiaWindowsApp, now = Date.now()): void {
  const state = hostState(host);
  const action = host.lastUndoAction;
  if (!action) {
    state.hoverPause = null;
    state.trackedUndoAction = null;
    host.undoBannerUntilMs = 0;
    if (state.undoBannerTimer !== null) {
      window.clearTimeout(state.undoBannerTimer);
      state.undoBannerTimer = null;
    }
    return;
  }
  if (state.hoverPause && state.hoverPause.action === action) {
    return;
  }
  if (state.hoverPause && state.hoverPause.action !== action) {
    state.hoverPause = null;
  }
  if (action.expiresAtMs <= now) {
    state.trackedUndoAction = null;
    host.undoBannerUntilMs = 0;
    if (state.undoBannerTimer !== null) {
      window.clearTimeout(state.undoBannerTimer);
      state.undoBannerTimer = null;
    }
    return;
  }
  if (state.trackedUndoAction === action) return;
  state.trackedUndoAction = action;
  const ms = undoBannerMs(undoDeviceCount(action.steps));
  host.undoBannerUntilMs = now + ms;
  if (state.undoBannerTimer !== null) {
    window.clearTimeout(state.undoBannerTimer);
    state.undoBannerTimer = null;
  }
  if (state.pointerInsideBanner) {
    state.hoverPause = {
      action,
      remainingActionMs: Math.max(0, action.expiresAtMs - now),
      remainingBannerMs: ms,
    };
    return;
  }
  state.undoBannerTimer = window.setTimeout(() => {
    state.undoBannerTimer = null;
    // The button leaving must not rebuild the panel under a slider drag or an All Off hold.
    if (state.trackedUndoAction === action) host.queueBackgroundRender();
  }, ms);
}

export function undoButtonVisible(host: MenuMijiaWindowsApp, now = Date.now()): boolean {
  const state = hostState(host);
  syncUndoBannerClock(host, now);
  if (state.hoverPause && state.hoverPause.action === host.lastUndoAction) {
    return state.hoverPause.remainingActionMs > 0 && state.hoverPause.remainingBannerMs > 0;
  }
  return host.lastUndoAction !== null && host.lastUndoAction.expiresAtMs > now && now < host.undoBannerUntilMs;
}

export function pauseUndoOnBannerHover(host: MenuMijiaWindowsApp, now = Date.now()): void {
  const state = hostState(host);
  syncUndoBannerClock(host, now);
  state.pointerInsideBanner = true;
  if (state.hoverPause && state.hoverPause.action === host.lastUndoAction) return;
  const action = host.lastUndoAction;
  if (!action || action.expiresAtMs <= now) return;
  if (state.undoBannerTimer !== null) {
    window.clearTimeout(state.undoBannerTimer);
    state.undoBannerTimer = null;
  }
  state.hoverPause = {
    action,
    remainingActionMs: Math.max(0, action.expiresAtMs - now),
    remainingBannerMs: Math.max(0, host.undoBannerUntilMs - now),
  };
}

export function resumeUndoHoverPause(host: MenuMijiaWindowsApp, now = Date.now()): void {
  const state = hostState(host);
  state.pointerInsideBanner = false;
  const paused = state.hoverPause;
  state.hoverPause = null;
  if (!paused || host.lastUndoAction !== paused.action) return;
  if (paused.remainingActionMs <= 0) {
    host.lastUndoAction = null;
    state.trackedUndoAction = null;
    host.undoBannerUntilMs = 0;
    host.queueBackgroundRender();
    return;
  }
  const updatedAction: UndoAction = {
    ...paused.action,
    expiresAtMs: now + paused.remainingActionMs,
  };
  copyUndoKindSnapshots(paused.action, updatedAction);
  host.lastUndoAction = updatedAction;
  state.trackedUndoAction = updatedAction;
  if (state.undoBannerTimer !== null) {
    window.clearTimeout(state.undoBannerTimer);
    state.undoBannerTimer = null;
  }
  if (paused.remainingBannerMs > 0) {
    host.undoBannerUntilMs = now + paused.remainingBannerMs;
    state.undoBannerTimer = window.setTimeout(() => {
      state.undoBannerTimer = null;
      if (state.trackedUndoAction === updatedAction) host.queueBackgroundRender();
    }, paused.remainingBannerMs);
  } else {
    host.undoBannerUntilMs = 0;
  }
}

export function reconcileUndoBannerHoverAfterRender(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  if ((state.pointerInsideBanner || state.hoverPause !== null) && !host.root.querySelector(".cc-live-banner")) {
    resumeUndoHoverPause(host);
  }
  bindUrlConfirmationEventsAfterRender(host);
  syncDynamicTrayTooltip(host);
  scheduleRaycastSnapshotExport(host);
}

function asElement(node: EventTarget | null | undefined): Element | null {
  return node !== null &&
    node !== undefined &&
    typeof node === "object" &&
    "closest" in node &&
    typeof (node as Element).closest === "function"
    ? (node as Element)
    : null;
}

export function bindUndoBannerHoverGuard(host: MenuMijiaWindowsApp): void {
  host.root.addEventListener(
    "pointerenter",
    (event) => {
      const target = asElement(event.target);
      if (target?.closest(".cc-live-banner")) {
        pauseUndoOnBannerHover(host);
      }
    },
    true,
  );
  host.root.addEventListener("pointerover", (event) => {
    const target = asElement(event.target);
    if (target?.closest(".cc-live-banner")) {
      pauseUndoOnBannerHover(host);
    }
  });
  host.root.addEventListener(
    "pointerleave",
    (event) => {
      const target = asElement(event.target);
      if (!target || !target.classList.contains("cc-live-banner")) return;
      const related = asElement((event as MouseEvent).relatedTarget);
      if (related?.closest(".cc-live-banner")) return;
      resumeUndoHoverPause(host);
    },
    true,
  );
  host.root.addEventListener("pointerout", (event) => {
    const target = asElement(event.target);
    if (!target || !target.isConnected || !target.closest(".cc-live-banner")) return;
    const related = asElement((event as MouseEvent).relatedTarget);
    if (related?.closest(".cc-live-banner")) return;
    resumeUndoHoverPause(host);
  });
  host.root.addEventListener(
    "click",
    (event) => {
      const target = asElement(event.target);
      if (target?.closest("#btn-hide-panel")) {
        dismissPendingUrlConfirmation(host, false);
        resumeUndoHoverPause(host);
      }
    },
    true,
  );
  window.addEventListener("blur", () => resumeUndoHoverPause(host));
  document.addEventListener("visibilitychange", () => {
    if (isPanelHidden()) {
      // A hidden panel cannot show a prompt, so neither the one on screen nor any queued link
      // that would need one may stay pending.
      cancelPendingExternalUrlWork(host);
      resumeUndoHoverPause(host);
    }
  });
  bindCompanionAndUpdaterEvents(host);
}

/** The panel is not on screen, so a modal confirmation would be invisible and unanswerable. */
function isPanelHidden(): boolean {
  return typeof document !== "undefined" && document.visibilityState === "hidden";
}

export const MI_SIGNOUT_PENDING_KEY = "menumijia.windows.miSignOutPending.v1";

export function hasPendingMiVaultDeletion(): boolean {
  try {
    return typeof localStorage !== "undefined" && localStorage.getItem(MI_SIGNOUT_PENDING_KEY) === "1";
  } catch {
    return false;
  }
}

export function setPendingMiVaultDeletion(pending: boolean): void {
  try {
    if (typeof localStorage === "undefined") return;
    if (pending) {
      localStorage.setItem(MI_SIGNOUT_PENDING_KEY, "1");
    } else {
      localStorage.removeItem(MI_SIGNOUT_PENDING_KEY);
    }
  } catch {
    // Ignore storage quota errors.
  }
}

export function didMiExpiryKindChange(host: MenuMijiaWindowsApp, now = Date.now()): boolean {
  const state = hostState(host);
  const current =
    host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession
      ? miSessionExpiryState(host.settings.miSession, now).kind
      : "valid";
  if (state.lastMiExpiryKind === current) return false;
  state.lastMiExpiryKind = current;
  return true;
}

export function recordUndoKindSnapshots(
  action: UndoAction,
  snapshots: ReadonlyMap<string, SmartDevice["kind"]>,
): void {
  if (snapshots.size > 0) {
    undoKindSnapshots.set(action, snapshots);
  }
}

export function copyUndoKindSnapshots(fromAction: UndoAction, toAction: UndoAction): void {
  const existing = undoKindSnapshots.get(fromAction);
  if (existing) {
    undoKindSnapshots.set(toAction, existing);
  }
}

export function restoreUndoKindSnapshot(action: UndoAction, device: SmartDevice): void {
  const prevKind = undoKindSnapshots.get(action)?.get(device.id);
  if (prevKind) {
    device.kind = structuredClone(prevKind);
  }
}

export function quickActionScopeDevices(host: MenuMijiaWindowsApp): SmartDevice[] {
  return foldGrouped(host, filterByListCut(host.devices, host.listCut, false));
}

export async function executeBuiltInQuickAction(
  host: MenuMijiaWindowsApp,
  actionId: QuickActionId,
): Promise<void> {
  if (await rejectIfControlBlockedWhileLocked(host)) return;
  const sourceRevision = host.sourceRevision;
  const planned = planQuickAction(actionId, quickActionScopeDevices(host), host.lastManuallyUsedLightId);

  if (planned.targets.length === 0) {
    host.replyBanner = {
      text: trText("当前无需执行「{title}」", "No devices need \"{title}\"", { title: planned.title }),
      source: t("0ms 本地直达"),
    };
    host.render();
    return;
  }

  const outcomes = await Promise.allSettled(
    planned.targets.map(async (target) => {
      let accepted = 0;
      let failed = false;
      let failureMessage = "";
      for (const command of target.commands) {
        if (sourceRevision !== host.sourceRevision) {
          return { target, accepted, failed: true, failureMessage: "" };
        }
        if (await host.applyCommand(command)) {
          accepted += 1;
        } else {
          failed = true;
          failureMessage = host.replyBanner?.text ?? "设备未响应";
          break;
        }
      }
      return { target, accepted, failed, failureMessage };
    }),
  );

  if (sourceRevision !== host.sourceRevision) return;

  const steps: UndoStep[] = [];
  const kindMap = new Map<string, SmartDevice["kind"]>();
  const succeededHabitIntents = [];
  let succeededCount = 0;
  let failedCount = 0;
  let lastFailureMessage = "";

  for (const outcome of outcomes) {
    if (outcome.status === "rejected") {
      failedCount += 1;
      lastFailureMessage =
        outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason);
      continue;
    }
    const { target, accepted, failed, failureMessage } = outcome.value;
    if (accepted > 0) {
      steps.push({ deviceId: target.deviceId, commands: target.restoreCommands });
      kindMap.set(target.deviceId, target.previousKind);
    }
    if (!failed && accepted === target.commands.length) {
      succeededCount += 1;
      succeededHabitIntents.push(...target.habitIntents);
    } else {
      failedCount += 1;
      if (failureMessage) lastFailureMessage = failureMessage;
    }
  }

  const habitReceipt = succeededHabitIntents.length > 0 ? recordHabits(host, succeededHabitIntents) : null;
  if (steps.length > 0) {
    host.lastManuallyUsedLightId = planned.nextLastManuallyUsedLightId;
    const undoAction: UndoAction = {
      summary: trText("已执行「{title}」", "Executed \"{title}\"", { title: planned.title }),
      steps,
      expiresAtMs: Date.now() + 10 * 60 * 1000,
      habitReceipt: habitReceipt ?? undefined,
    };
    recordUndoKindSnapshots(undoAction, kindMap);
    host.lastUndoAction = undoAction;
  }

  host.replyBanner =
    failedCount > 0
      ? {
          text: t("已执行 {ok} 项，{failed} 项失败。{message}", {
            ok: succeededCount,
            failed: failedCount,
            message: lastFailureMessage,
          }),
          source: t("控制失败"),
          isError: true,
        }
      : {
          text: trText("已执行「{title}」", "Executed \"{title}\"", { title: planned.title }),
          source: t("0ms 本地直达"),
        };
  host.render();
}

export function isControlBlockedWhileLocked(host: MenuMijiaWindowsApp): Promise<boolean> {
  return isWorkstationLockBlockingControl(host);
}

export async function rejectIfControlBlockedWhileLocked(
  host: MenuMijiaWindowsApp,
): Promise<boolean> {
  if (!(await isControlBlockedWhileLocked(host))) return false;
  hostState(host).lockBlockCount += 1;
  host.replyBanner = {
    text: t("屏幕已锁定，已拦截设备控制指令"),
    source: t("锁屏保护"),
    isError: true,
  };
  host.render();
  return true;
}

export async function runScheduledCommandWithLockGuard(
  host: MenuMijiaWindowsApp,
  item: import("../core/models.js").ScheduledCommand,
  runner: () => Promise<void>,
): Promise<void> {
  const state = hostState(host);
  const exempt = isInsideScheduledTimerTick();
  const beforeBlockedCount = state.lockBlockCount;
  await runner();
  if (!exempt && state.lockBlockCount > beforeBlockedCount) {
    if (!host.missedScheduledCommands.some((entry) => entry.id === item.id)) {
      host.missedScheduledCommands = [...host.missedScheduledCommands, item];
      host.scheduledCommandStore.persist();
      host.render();
    }
  }
}

export function dismissPendingUrlConfirmation(
  host: MenuMijiaWindowsApp,
  approved: boolean,
): void {
  const state = hostState(host);
  const pending = state.pendingUrlConfirmation;
  if (!pending) return;
  state.pendingUrlConfirmation = null;
  invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
  pending.resolve(approved);
  host.render();
}

export function renderUrlConfirmationPrompt(host: MenuMijiaWindowsApp): string {
  const pending = hostState(host).pendingUrlConfirmation;
  if (!pending) return "";
  return `
    <div class="cc-prompt-backdrop" data-url-confirm-cancel></div>
    <div class="cc-prompt" role="alertdialog" aria-modal="true" aria-label="${t("允许外部链接控制设备？")}">
      <strong>${t("允许外部链接控制设备？")}</strong>
      <p style="margin: 6px 0; font-size: 13px; line-height: 1.45;">${host.escapeHtml(pending.description)}</p>
      <small>${t("网页和其它应用都可以打开这个链接。确认后只执行这一次。")}</small>
      <div class="cc-prompt-actions">
        <button type="button" class="cc-btn-secondary" id="btn-url-confirm-cancel">${t("取消")}</button>
        <button type="button" class="cc-btn-primary" id="btn-url-confirm-run">${t("执行一次")}</button>
      </div>
    </div>`;
}

function bindUrlConfirmationEventsAfterRender(host: MenuMijiaWindowsApp): void {
  if (!hasPendingUrlConfirmation(host)) return;
  const cancelBtn = host.root.querySelector<HTMLButtonElement>("#btn-url-confirm-cancel");
  const runBtn = host.root.querySelector<HTMLButtonElement>("#btn-url-confirm-run");
  cancelBtn?.addEventListener("click", () => dismissPendingUrlConfirmation(host, false));
  runBtn?.addEventListener("click", () => dismissPendingUrlConfirmation(host, true));
  host.root
    .querySelectorAll<HTMLElement>("[data-url-confirm-cancel]")
    .forEach((el) =>
      el.addEventListener("click", () => dismissPendingUrlConfirmation(host, false)),
    );
  const promptEl = host.root.querySelector<HTMLElement>(".cc-prompt");
  if (cancelBtn && promptEl && !promptEl.contains(document.activeElement)) {
    cancelBtn.focus();
  }
}

/**
 * The current bridge token, or `undefined` when the integration is off — or when no CSPRNG is
 * available. A weak token is never minted (see `generateRandomHexToken`); the failure surfaces
 * once through `warnBridgeTokenUnavailable` instead of throwing inside a render.
 */
export function getActiveRaycastBridgeTokenForHost(
  host: MenuMijiaWindowsApp,
): string | undefined {
  const state = hostState(host);
  try {
    return state.bridgeTokens.getOrCreate(host.settings.enableRaycastIntegration);
  } catch (error) {
    warnBridgeTokenUnavailable(host, error);
    return undefined;
  }
}

function warnBridgeTokenUnavailable(host: MenuMijiaWindowsApp, error: unknown): void {
  const state = hostState(host);
  if (state.bridgeTokenWarningShown) return;
  state.bridgeTokenWarningShown = true;
  const detail = error instanceof Error ? error.message : String(error);
  host.replyBanner = {
    text: detail,
    source: trText("Raycast 集成", "Raycast Integration"),
    isError: true,
  };
  // Without a token nothing can be written safely, so the integration stays off until it works.
  host.settings.enableRaycastIntegration = false;
  host.saveSettings();
}

export function getLatestRaycastSnapshotForHost(host: MenuMijiaWindowsApp): RaycastSnapshot {
  const state = hostState(host);
  const token = getActiveRaycastBridgeTokenForHost(host) ?? "";
  const visibleDevices = foldGrouped(host, host.devices);
  const rooms = host.roomOptions.map((r) => ({
    id: r.id,
    name: r.name,
    deviceCount: visibleDevices.filter((d) => d.roomId === r.id).length,
  }));
  const activeUndo =
    host.lastUndoAction && host.lastUndoAction.expiresAtMs > Date.now()
      ? {
          title: host.lastUndoAction.summary,
          count: undoDeviceCount(host.lastUndoAction.steps),
        }
      : null;

  return buildRaycastSnapshot({
    connectionMode: host.settings.connectionMode,
    selectedHomeId: host.settings.selectedHomeId,
    connectionSummary: host.panelHealth().label,
    bridgeToken: token,
    isStale: host.valuesAreStale,
    devices: visibleDevices,
    rooms,
    scenes: host.scenes,
    environmentReadings: host.computedEnvironmentReadings,
    hideOfflineDevices: host.settings.hideOfflineDevices,
    aliases: host.layout.aliases,
    allOffOverrides: host.settings.allOffOverrides,
    undoSummary: activeUndo,
    ...(state.lastCommandFeedback ? { lastCommandFeedback: state.lastCommandFeedback } : {}),
  });
}

async function exportRaycastSnapshotNow(
  host: MenuMijiaWindowsApp,
  force = false,
): Promise<void> {
  const state = hostState(host);
  if (!host.settings.enableRaycastIntegration) return;
  if (
    host.isSyncingCloud &&
    host.devices.length === 0 &&
    host.scenes.length === 0 &&
    host.computedEnvironmentReadings.length === 0 &&
    state.lastCommandFeedback === undefined
  ) {
    return;
  }
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
  if (state.snapshotExportTimer !== null) {
    ownerWin.clearTimeout(state.snapshotExportTimer);
    state.snapshotExportTimer = null;
  }
  const snapshot = getLatestRaycastSnapshotForHost(host);
  const comparable = JSON.stringify({
    ...snapshot,
    generatedAt: "",
    updatedAt: "",
    environmentReadings: snapshot.environmentReadings.map((r) => ({ ...r, updatedAt: "" })),
    climate: snapshot.climate.map((r) => ({ ...r, updatedAt: "" })),
  });
  if (!force && state.lastExportedComparableJson === comparable) return;

  const invoke = window.__TAURI_INTERNALS__?.invoke;
  if (!invoke) return;
  // The dedupe stamp is only advanced by a write that actually landed. Recording it up front made
  // one transient I/O failure permanent: every later render saw "already exported" and skipped.
  const seq = ++state.exportSeq;
  try {
    await invoke("write_raycast_snapshot", {
      contents: JSON.stringify(snapshot, null, 2),
    });
  } catch {
    // Transient filesystem error: leaving `lastExportedComparableJson` stale lets the next render
    // retry the same content.
    return;
  }
  // A newer export (or the integration being switched off) owns the stamp now.
  if (seq !== state.exportSeq || !host.settings.enableRaycastIntegration) return;
  state.lastExportedComparableJson = comparable;
}

export function scheduleRaycastSnapshotExport(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  if (!host.settings.enableRaycastIntegration) return;
  // A missing CSPRNG disables the integration inside the getter, so stop before scheduling a write
  // that would publish a snapshot with an empty token.
  if (getActiveRaycastBridgeTokenForHost(host) === undefined) return;
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
  if (state.snapshotExportTimer !== null) {
    ownerWin.clearTimeout(state.snapshotExportTimer);
  }
  state.snapshotExportTimer = ownerWin.setTimeout(() => {
    state.snapshotExportTimer = null;
    if (!host.root.isConnected) return;
    void exportRaycastSnapshotNow(host, false);
  }, 300);
}

export function setRaycastIntegrationEnabled(
  host: MenuMijiaWindowsApp,
  enabled: boolean,
): void {
  const state = hostState(host);
  host.settings.enableRaycastIntegration = enabled;
  host.saveSettings();
  if (enabled) {
    if (getActiveRaycastBridgeTokenForHost(host) === undefined) {
      // No CSPRNG: `warnBridgeTokenUnavailable` already turned the integration back off.
      host.render();
      return;
    }
    void exportRaycastSnapshotNow(host, true);
  } else {
    const ownerWin = host.root.ownerDocument?.defaultView ?? window;
    if (state.snapshotExportTimer !== null) {
      ownerWin.clearTimeout(state.snapshotExportTimer);
      state.snapshotExportTimer = null;
    }
    state.bridgeTokens.revoke();
    state.lastExportedComparableJson = null;
    // Any write still in flight belongs to the run that just ended; its completion must not
    // reinstate a dedupe stamp for a snapshot that is being deleted.
    state.exportSeq += 1;
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (invoke) {
      void invoke("remove_raycast_snapshot").catch(() => undefined);
    }
  }
  host.render();
}

function syncDynamicTrayTooltip(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  const summary = formatDynamicTraySummary(
    host.computedEnvironmentReadings,
    foldGrouped(host, host.devices),
  );
  if (state.lastTraySummary === summary) return;
  state.lastTraySummary = summary;
  invokeTauriVoid("set_tray_tooltip", { summary });
}

/**
 * Wraps the app for one external link, pinned to the data source it was opened against.
 *
 * `onOpenURL` awaits a prompt, a reveal and a device write; the user can switch Mi Home, sign out,
 * or switch HA in any of those gaps. Once `host.sourceRevision` moves, the token and device ids in
 * the link describe a home that is no longer on screen, so every mutating step refuses instead of
 * controlling a same-id device in the new account.
 */
function createUrlCommandHostAdapter(
  host: MenuMijiaWindowsApp,
  expectedRevision: number,
): AppURLCommandHost {
  const state = hostState(host);
  const revisionStillMatches = () => host.sourceRevision === expectedRevision;
  return {
    get devices() {
      return host.devices;
    },
    get scenes() {
      return host.scenes;
    },
    get sourceRevision() {
      return host.sourceRevision;
    },
    get settings() {
      return host.settings;
    },
    get layout() {
      return host.layout;
    },
    get pendingHighRisk() {
      return host.pendingHighRisk;
    },
    get replyBanner() {
      return host.replyBanner;
    },
    get pendingConsent() {
      return host.pendingCloudConsent;
    },
    get expandedDeviceId() {
      return host.expandedDeviceId;
    },
    set expandedDeviceId(id: string | null) {
      host.expandedDeviceId = id;
    },

    async waitForInitialSnapshotIfNeeded(): Promise<void> {
      if (host.devices.length > 0 || !host.isSyncingCloud) return;
      const deadline = Date.now() + 2000;
      while (host.devices.length === 0 && host.isSyncingCloud && Date.now() < deadline) {
        await new Promise<void>((resolve) => window.setTimeout(resolve, 40));
      }
    },

    getActiveRaycastBridgeToken(): string | undefined {
      return getActiveRaycastBridgeTokenForHost(host);
    },

    isControlBlockedByScreenLock(): Promise<boolean> {
      return isControlBlockedWhileLocked(host);
    },

    requestExternalUrlConfirmation(args): Promise<boolean> {
      // A hidden panel cannot show this modal, so the request is refused outright rather than
      // parked: an unseen prompt would hold the queue open forever.
      if (!revisionStillMatches() || isPanelHidden()) return Promise.resolve(false);
      if (state.pendingUrlConfirmation !== null) {
        const previous = state.pendingUrlConfirmation;
        state.pendingUrlConfirmation = null;
        previous.resolve(false);
      }
      return new Promise<boolean>((resolve) => {
        state.pendingUrlConfirmation = {
          description: args.description,
          commandLabel: args.commandLabel,
          ...(args.requestId ? { requestId: args.requestId } : {}),
          sourceRevision: args.sourceRevision,
          resolve,
        };
        invokeTauriVoid("set_pin_popover", { pin: true });
        host.render();
      });
    },

    async revealPanelForExternalUrl(): Promise<void> {
      const invoke = window.__TAURI_INTERNALS__?.invoke;
      if (!invoke) return;
      try {
        await invoke("show_panel_for_url");
      } catch {
        // Ignore in headless test harnesses.
      }
    },

    setPendingHighRisk(next): void {
      host.setPendingHighRisk(next);
    },

    clearPendingHighRisk(): void {
      host.clearPendingHighRisk();
    },

    showExternalToast(message: string, isError: boolean): void {
      host.replyBanner = {
        text: message,
        source: t("外部链接"),
        ...(isError ? { isError: true } : {}),
      };
      host.render();
    },

    recordRaycastCommandFeedback(feedback): void {
      state.lastCommandFeedback = {
        ...feedback,
        completedAt: new Date().toISOString(),
      };
      if (host.settings.enableRaycastIntegration) {
        void exportRaycastSnapshotNow(host, true);
      }
    },

    async executeSingleCommand(device, command, summary, intent, readBackPower): Promise<void> {
      if (!revisionStillMatches()) return;
      await host.executeSingleCommand(device, command, summary, intent, readBackPower);
    },

    async applyCommand(command, readBackPower): Promise<boolean> {
      if (!revisionStillMatches()) return false;
      return host.applyCommand(command, readBackPower);
    },

    async handleNaturalCommand(rawInput, fromScheduled): Promise<void> {
      if (!revisionStillMatches()) return;
      await host.handleNaturalCommand(rawInput, fromScheduled);
    },

    async executeBuiltInSceneFromUrl(
      scene: BuiltInURLSceneId,
    ): Promise<{ readonly message: string; readonly isError: boolean }> {
      if (!revisionStillMatches()) {
        return {
          message: trText("数据源已切换，已取消外部链接执行", "Data source changed; external link cancelled"),
          isError: true,
        };
      }
      if (scene === "lightsOff" || scene === "softNightLight" || scene === "climateSleepOff") {
        await executeBuiltInQuickAction(host, scene);
        const banner = host.replyBanner;
        return {
          message: banner?.text ?? "",
          isError: Boolean(banner?.isError),
        };
      }
      if (scene === "allOff") {
        const targets = allOffTargets(
          foldGrouped(host, host.devices),
          host.settings.allOffOverrides,
        );
        if (targets.length === 0) {
          return {
            message: trText("当前没有开启的设备", "No active devices are currently on"),
            isError: false,
          };
        }
        const ok = await host.executeIntents(
          targets.map((d) => ({ targetId: d.id, operation: { kind: "power", isOn: false } })),
          t("已关闭 {count} 台开启中的设备", { count: targets.length }),
          t("一键全关"),
          { recordHabits: true },
        );
        return {
          message:
            host.replyBanner?.text ??
            t("已关闭 {count} 台开启中的设备", { count: targets.length }),
          isError: !ok || Boolean(host.replyBanner?.isError),
        };
      }
      await host.performUndo();
      const banner = host.replyBanner;
      const noUndo =
        banner?.source === t("撤销提示") || Boolean(banner?.isError);
      return {
        message: banner?.text ?? trText("没有可以撤销的操作", "Nothing to undo"),
        isError: noUndo,
      };
    },

    isDeviceVisibleInPanel(deviceId: string): boolean {
      const dev = host.devices.find((d) => d.id === deviceId);
      if (!dev) return false;
      const hiddenIds = (host.layout as { hiddenIds?: readonly string[] })?.hiddenIds;
      if (hiddenIds && hiddenIds.includes(deviceId)) return false;
      if (host.settings.hideOfflineDevices && !dev.isOnline) return false;
      return true;
    },

    focusDeviceFromUrl(deviceId: string): void {
      if (!revisionStillMatches()) return;
      host.activeSheet = "none";
      host.selectRoom(null);
      const dev = host.devices.find((d) => d.id === deviceId);
      host.expandedDeviceId =
        dev && hasDetailDrawer(dev, host.deviceFacets?.[deviceId] ?? []) ? deviceId : null;
      host.panelSearch.selectedDeviceId = deviceId;
      host.panelSearch.explicitSelection = true;
      host.render();
      const escapedId =
        typeof CSS !== "undefined" && typeof CSS.escape === "function"
          ? CSS.escape(deviceId)
          : deviceId.replace(/["\\]/g, "\\$&");
      const card = host.root.querySelector<HTMLElement>(
        `[data-device-card="${escapedId}"]`,
      );
      card?.scrollIntoView?.({ block: "nearest" });
    },
  };
}

export function enqueueIncomingOpenUrl(
  host: MenuMijiaWindowsApp,
  rawUrl: string,
): Promise<void> {
  const state = hostState(host);
  // The stamp is taken here, at the moment the link arrives, not when it is finally dequeued.
  const sourceRevision = host.sourceRevision;
  return new Promise<void>((done) => {
    state.urlQueue.push({ url: rawUrl, sourceRevision, done });
    if (!state.isDrainingUrlQueue) {
      state.isDrainingUrlQueue = true;
      void (async () => {
        try {
          while (state.urlQueue.length > 0) {
            const item = state.urlQueue.shift()!;
            try {
              if (host.sourceRevision !== item.sourceRevision) {
                reportStaleExternalUrl(host, item.url);
                continue;
              }
              await onOpenURL(
                item.url,
                createUrlCommandHostAdapter(host, item.sourceRevision),
              );
            } finally {
              item.done();
            }
          }
        } finally {
          state.isDrainingUrlQueue = false;
        }
      })();
    }
  });
}

/**
 * Answers a link that outlived its data source. Without this the user would see nothing at all:
 * the device ids and `bridgeToken` in the link refer to the home that is no longer loaded.
 */
function reportStaleExternalUrl(host: MenuMijiaWindowsApp, rawUrl: string): void {
  const state = hostState(host);
  const envelope = AppURLParser.parseEnvelope(rawUrl);
  host.replyBanner = {
    text: trText("数据源已切换，已取消外部链接执行", "Data source changed; external link cancelled"),
    source: t("外部链接"),
    isError: true,
  };
  state.lastCommandFeedback = {
    ...(envelope?.requestId ? { requestId: envelope.requestId } : {}),
    command: envelope ? formatAppURLCommandLabel(envelope.command) : "invalid",
    message: trText("数据源已切换，已取消外部链接执行", "Data source changed; external link cancelled"),
    isError: true,
    completedAt: new Date().toISOString(),
  };
  host.render();
  if (host.settings.enableRaycastIntegration) {
    void exportRaycastSnapshotNow(host, true);
  }
}

function bindCompanionAndUpdaterEvents(host: MenuMijiaWindowsApp): void {
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
  ownerWin.addEventListener("menumijia:open-url", (event: Event) => {
    if (!host.root.isConnected) return;
    const detail = (event as CustomEvent<unknown>).detail;
    if (typeof detail === "string" && detail.trim() !== "") {
      void enqueueIncomingOpenUrl(host, detail);
    }
  });

  ownerWin.addEventListener("menumijia:update-progress", (event: Event) => {
    if (!host.root.isConnected) return;
    const detail = (event as CustomEvent<unknown>).detail;
    if (!detail || typeof detail !== "object") return;
    const rec = detail as Record<string, unknown>;
    const downloadedBytes = Number(rec.downloadedBytes ?? 0);
    const totalBytes = Number(rec.totalBytes ?? 0);
    const bytesPerSec = Number(rec.bytesPerSec ?? 0);
    if (!Number.isFinite(downloadedBytes) || downloadedBytes < 0) return;
    updateProgressBySettings.set(host.settings, {
      downloadedBytes,
      totalBytes: Number.isFinite(totalBytes) && totalBytes >= 0 ? totalBytes : 0,
      bytesPerSec: Number.isFinite(bytesPerSec) && bytesPerSec >= 0 ? bytesPerSec : 0,
    });
    if (host.isInstallingUpdate) {
      host.queueBackgroundRender();
    }
  });

  if (host.settings.enableRaycastIntegration) {
    getActiveRaycastBridgeTokenForHost(host);
    void exportRaycastSnapshotNow(host, true);
  } else {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (invoke) {
      void invoke("remove_raycast_snapshot").catch(() => undefined);
    }
  }

  const invoke = window.__TAURI_INTERNALS__?.invoke;
  if (!invoke) return;

  if (host.settings.launchAtLogin) {
    void invoke("set_launch_at_login", { enabled: true }).catch(() => undefined);
  }

  void invoke<string[]>("drain_pending_open_urls")
    .then((urls) => {
      if (!Array.isArray(urls)) return;
      for (const url of urls) {
        if (typeof url === "string" && url.trim() !== "") {
          void enqueueIncomingOpenUrl(host, url);
        }
      }
    })
    .catch(() => undefined);
}
