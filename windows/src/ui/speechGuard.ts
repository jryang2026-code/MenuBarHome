import {
  AppURLParser,
  formatAppURLCommandLabel,
  onOpenURL,
  type AppURLCommandHost,
  type BuiltInURLSceneId,
  type UrlDeviceFocusResult,
} from "../core/appUrlCommand.js";
import { allOffResultText, speechLocale, t } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { hasDetailDrawer, type SmartDevice } from "../core/models.js";
import { planQuickAction, quickActionTitle, type QuickActionId } from "../core/quickActions.js";
import {
  RaycastBridgeTokenManager,
  buildRaycastSnapshot,
  formatDynamicTraySummary,
  type RaycastCommandFeedback,
  type RaycastSnapshot,
} from "../core/raycastSnapshot.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { tr3, undoBannerMs, undoDeviceCount } from "./undoTracker.js";
import type {
  PersistedSettings,
  SpeechRecognitionInstance,
  UndoAction,
  UndoStep,
} from "./appTypes.js";
import { isConnectionsAndDiagModalOpen } from "./connectionsAndDiagView.js";
import { buildHostCapabilityContext, foldGrouped, isDualSourceEnabled, resolveHostMiSelectionState } from "./cloudRefresh.js";
import { QUICK_ACTION_TARGET_CATEGORIES } from "../core/capabilityReferenceVerdict.js";
import { evaluateDeviceEntityWriteGate, evaluateQuickActionSourceWriteGate, planWritableAllOff } from "../core/miAccountControl.js";
import { resolveConnectionStatus } from "./connectionStatus.js";
import { recordHabits } from "./intentExecution.js";
import { filterByListCut } from "./listCut.js";
import { bindMoodPromptEventsAfterRender } from "./moods.js";
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
  /** `companionEpoch` on arrival: switching the integration off or on drops every link queued before. */
  readonly companionEpoch: number;
  readonly done: () => void;
}

/** What 检测接入 last found, shown under the integration switch until the next check. */
export interface CompanionNotice {
  readonly checkedAt: number;
  readonly lines: readonly string[];
  readonly isError: boolean;
  readonly retryDisconnect?: boolean;
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
  /** Bumped by every integration switch; in-flight and queued external links of an older epoch are dropped. */
  companionEpoch: number;
  /** The generation the native host issued for the current switch; snapshot writes must carry it. */
  companionGeneration: Promise<number | null>;
  companionNotice: CompanionNotice | null;
}

export interface LockGuardHost {
  readonly settings: { readonly blockControlWhileLocked?: boolean };
  replyBanner: { text: string; source: string; isError?: boolean } | null;
  render(): void;
}

const runtimeStateByHost = new WeakMap<object, HostRuntimeGuardState>();
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

function hostState(host: object): HostRuntimeGuardState {
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
      companionEpoch: 0,
      companionGeneration: Promise.resolve(null),
      companionNotice: null,
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
    isConnectionsAndDiagModalOpen(host) ||
    host.isEditingLayout ||
    host.prompt !== null ||
    host.pendingMoodCapture !== null ||
    host.pendingMoodConfirm !== null ||
    hasPendingUrlConfirmation(host) ||
    host.isListeningVoice ||
    host.isHomeMenuOpen ||
    host.ctxMenu !== null ||
    host.pendingHighRisk !== null ||
    (host.cameraLive.activeLiveCameraId !== null &&
      !host.cameraLive.liveCameraHidden &&
      !host.cameraLive.isDetachedPipActive)
  );
}

export function abortVoiceInput(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  const current = state.speechRecognition;
  const wasListening = host.isListeningVoice || current !== null;
  state.speechRecognition = null;
  host.isListeningVoice = false;
  if (wasListening) {
    const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
    if (inputEl && !host.panelSearch.query) {
      inputEl.value = "";
    }
    invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
  }
  if (current) {
    try {
      if (typeof current.abort === "function") {
        current.abort();
      } else {
        current.stop();
      }
    } catch {
      // Already stopped or aborted.
    }
  }
}

/** 语音输入 is on unless the user explicitly turned it off; legacy settings have no key. */
export function isVoiceInputEnabled(
  settings: Pick<PersistedSettings, "voiceInputEnabled">,
): boolean {
  return settings.voiceInputEnabled !== false;
}

/** Whether this WebView exposes Web Speech at all; the switch stays honest either way. */
export function isSpeechRecognitionSupported(): boolean {
  return Boolean(window.SpeechRecognition ?? window.webkitSpeechRecognition);
}

/**
 * Turns 语音输入 on or off. Turning it off aborts the live recognizer before the setting is
 * written, so a result that lands afterwards sees a closed session and is dropped instead of
 * submitting a command the user can no longer cancel.
 */
export function setVoiceInputEnabled(
  host: MenuMijiaWindowsApp,
  enabled: boolean,
  options?: { readonly persistSettings?: boolean; readonly render?: boolean },
): void {
  const persistSettings = options?.persistSettings ?? true;
  const shouldRender = options?.render ?? true;
  host.settings.voiceInputEnabled = enabled;
  if (!enabled) {
    abortVoiceInput(host);
  }
  if (persistSettings) {
    host.saveSettings();
  }
  if (shouldRender) {
    host.render();
  }
}

export function toggleVoiceInput(host: MenuMijiaWindowsApp): void {
  const state = hostState(host);
  if (!isVoiceInputEnabled(host.settings)) {
    // The mic entry is hidden while off; this also covers a stale click from a panel rendered
    // before the switch flipped, and makes sure nothing keeps running.
    abortVoiceInput(host);
    return;
  }
  if (host.isListeningVoice) {
    abortVoiceInput(host);
    host.render();
    return;
  }

  const SpeechCtor = window.SpeechRecognition ?? window.webkitSpeechRecognition;
  if (!SpeechCtor) {
    host.isShowingAssistantBar = true;
    host.replyBanner = {
      text: tr3(
        "当前环境不支持在线语音识别（Web Speech API 不可用），请直接输入文字指令。",
        "目前環境不支援線上語音辨識（Web Speech API 不可用），請直接輸入文字指令。",
        "Online speech recognition (Web Speech API) is unavailable in this environment; please type your command.",
      ),
      source: t("语音提示"),
    };
    host.render();
    host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
    return;
  }

  host.isShowingAssistantBar = true;
  const startedRevision = host.sourceRevision;
  const recognition = new SpeechCtor();
  recognition.lang = speechLocale();
  recognition.interimResults = true;
  recognition.continuous = false;

  let latestInterim = "";
  let submittedFinal = false;
  let hadError = false;

  recognition.onresult = (event) => {
    if (!isVoiceInputEnabled(host.settings)) return;
    if (state.speechRecognition !== recognition || host.sourceRevision !== startedRevision) return;
    let finalTranscript = "";
    let interimTranscript = "";
    const length = event.results?.length ?? 0;
    for (let i = 0; i < length; i += 1) {
      const item = event.results[i];
      const piece = item?.[0]?.transcript ?? "";
      if (!piece) continue;
      if (item?.isFinal === true) {
        finalTranscript += piece;
      } else {
        interimTranscript += piece;
      }
    }
    const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
    if (finalTranscript.trim()) {
      submittedFinal = true;
      latestInterim = "";
      if (inputEl) inputEl.value = "";
      void host.handleNaturalCommand(finalTranscript.trim());
      return;
    }
    if (interimTranscript) {
      latestInterim = interimTranscript;
      if (inputEl) {
        inputEl.value = interimTranscript;
      }
    }
  };
  const finishRecognition = () => {
    // A recognizer that was stopped and replaced must not end the session that replaced it.
    if (state.speechRecognition !== recognition) return;
    state.speechRecognition = null;
    host.isListeningVoice = false;
    invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
    host.render();
  };
  recognition.onerror = () => {
    if (state.speechRecognition !== recognition) return;
    hadError = true;
    latestInterim = "";
    const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
    if (inputEl && !host.panelSearch.query) inputEl.value = "";
    finishRecognition();
  };
  recognition.onend = () => {
    if (state.speechRecognition !== recognition) return;
    const pending =
      !submittedFinal && !hadError && isVoiceInputEnabled(host.settings) && host.sourceRevision === startedRevision
        ? latestInterim.trim()
        : "";
    latestInterim = "";
    const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
    if (inputEl && !host.panelSearch.query) inputEl.value = "";
    finishRecognition();
    if (pending) {
      submittedFinal = true;
      void host.handleNaturalCommand(pending);
    }
  };

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
    // The prompt pinned the popover and is still in the DOM; without this its buttons are dead.
    invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
    host.queueBackgroundRender();
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
  bindMoodPromptEventsAfterRender(host);
  if (!host.isStandaloneSettingsWindow) {
    syncDynamicTrayTooltip(host);
    scheduleRaycastSnapshotExport(host);
  }
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
  return foldGrouped(host, filterByListCut(host.devices, host.listCut, false, { layout: host.layout }));
}

export async function executeBuiltInQuickAction(
  host: MenuMijiaWindowsApp,
  actionId: QuickActionId,
): Promise<void> {
  const state = resolveHostMiSelectionState(host);
  if (state.pausedQuickActionIds.has(actionId)) {
    const categoryDisabled = QUICK_ACTION_TARGET_CATEGORIES[actionId].some(
      (id) => !state.selection.enabledCategories.includes(id),
    );
    const title = quickActionTitle(actionId);
    host.replyBanner = {
      text: categoryDisabled
        ? tr3(
            `「${title}」已暂停，请重新开启关联的设备类型。`,
            `「${title}」已暫停，請重新開啟關聯的裝置類型。`,
            `"${title}" is paused. Re-enable the linked device types.`,
          )
        : tr3(
            `「${title}」功能已随关联连接停用而暂停，重新开启对应连接后即可恢复`,
            `「${title}」功能已隨關聯連線停用而暫停，重新開啟對應連線後即可恢復`,
            `"${title}" is paused because its linked connection is turned off; turn the connection back on to resume`,
          ),
      source: tr3("快捷功能", "捷徑功能", "Quick Actions"),
      isError: true,
    };
    host.render();
    return;
  }
  const scopeDevices = quickActionScopeDevices(host);
  if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const gateMsg = evaluateQuickActionSourceWriteGate({
      actionId,
      scopeDevices,
      lastManuallyUsedLightId: host.lastManuallyUsedLightId,
      context: buildHostCapabilityContext(host),
      languagePreference: host.settings.interfaceLanguage,
    });
    if (gateMsg !== null) {
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      host.render();
      return;
    }
  }
  if (await rejectIfControlBlockedWhileLocked(host)) return;
  const sourceRevision = host.sourceRevision;
  const planned = planQuickAction(actionId, scopeDevices, host.lastManuallyUsedLightId);

  if (planned.targets.length === 0) {
    host.replyBanner = {
      text: tr3(`当前无需执行「${planned.title}」`, `目前無需執行「${planned.title}」`, `No devices need "${planned.title}"`),
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
          failureMessage = host.replyBanner?.text ?? t("设备未响应");
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
      summary: tr3(`已执行「${planned.title}」`, `已執行「${planned.title}」`, `Executed "${planned.title}"`),
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
          text: tr3(`已执行「${planned.title}」`, `已執行「${planned.title}」`, `Executed "${planned.title}"`),
          source: t("0ms 本地直达"),
        };
  host.render();
}

export function isControlBlockedWhileLocked(
  host: Pick<LockGuardHost, "settings">,
): Promise<boolean> {
  return isWorkstationLockBlockingControl(host);
}

export function getLockBlockCount(host: object): number {
  return hostState(host).lockBlockCount;
}

export async function rejectIfControlBlockedWhileLocked(
  host: LockGuardHost,
  options?: { readonly beforeRender?: () => void },
): Promise<boolean> {
  if (!(await isControlBlockedWhileLocked(host))) return false;
  hostState(host).lockBlockCount += 1;
  host.replyBanner = {
    text: t("屏幕已锁定，已拦截设备控制指令"),
    source: t("锁屏保护"),
    isError: true,
  };
  options?.beforeRender?.();
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
  if (!state.bridgeTokenWarningShown) {
    state.bridgeTokenWarningShown = true;
    host.replyBanner = {
      text: error instanceof Error ? error.message : String(error),
      source: tr3("Raycast 集成", "Raycast 整合", "Raycast Integration"),
      isError: true,
    };
  }
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
    // The Raycast snapshot speaks the same plain-language status as the footer: one owner, one truth.
    connectionSummary: resolveConnectionStatus(host).text,
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
  const generation = await state.companionGeneration;
  if (generation === null || seq !== state.exportSeq || !host.settings.enableRaycastIntegration) return;
  try {
    await invoke("write_raycast_snapshot", {
      contents: JSON.stringify(snapshot, null, 2),
      generation,
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

export async function setRaycastIntegrationEnabled(
  host: MenuMijiaWindowsApp,
  enabled: boolean,
  options?: {
    readonly persistSettings?: boolean;
    readonly render?: boolean;
    readonly announceDisconnect?: boolean;
  },
): Promise<boolean> {
  const persistSettings = options?.persistSettings ?? true;
  const shouldRender = options?.render ?? true;
  const state = hostState(host);
  const changed = host.settings.enableRaycastIntegration !== enabled;
  host.settings.enableRaycastIntegration = enabled;
  const active = enabled && (host.isStandaloneSettingsWindow || getActiveRaycastBridgeTokenForHost(host) !== undefined);
  if (persistSettings && active === enabled) {
    host.saveSettings();
  }
  if (changed || !active) {
    // Whatever external link is waiting belongs to the run that just ended (P6a-W).
    state.companionEpoch += 1;
    state.companionNotice = null;
    state.lastCommandFeedback = undefined;
    if (!host.isStandaloneSettingsWindow) {
      if (!active && host.pendingHighRisk?.origin === "url") host.clearPendingHighRisk();
      cancelPendingExternalUrlWork(host);
    }
  }
  if (!active) {
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
  }
  // The main window owns token creation and exports. Settings can retry the atomic native
  // disable directly even when the persisted switch is already off.
  const registration = !host.isStandaloneSettingsWindow || (!active && persistSettings)
    ? registerCompanionWithNativeHost(host, active)
    : null;
  if (active && registration) void exportRaycastSnapshotNow(host, true);
  if (shouldRender) host.render();

  const epoch = state.companionEpoch;
  if (!registration) return true;
  const registered = (await registration) !== null;
  if (epoch !== state.companionEpoch) return false;
  if (!active && (!registered || options?.announceDisconnect)) {
    state.companionNotice = registered
      ? {
          checkedAt: Date.now(),
          lines: [tr3(
            "已断开：快照已删除，旧令牌已吊销，之前排队的外部命令不会再执行。",
            "已中斷連線：快照已刪除，舊權杖已撤銷，之前排隊的外部命令不會再執行。",
            "Disconnected: the snapshot is deleted, the old token is revoked and earlier queued commands will not run.",
          )],
          isError: false,
        }
      : companionDisconnectFailure();
    if (shouldRender) host.render();
  }
  return registered && active === enabled;
}

/**
 * A `set_companion_integration` IPC that never settles must not park every later switch behind it:
 * a link that has not settled within this window yields `null` (a failed registration) and releases
 * the queue. A disconnect therefore still reaches the native host and revokes the token.
 */
export const COMPANION_REGISTRATION_TIMEOUT_MS = 5_000;

/** Resolves with `work`'s value, or with `fallback` once `timeoutMs` elapses. The first settlement wins, so a late result is dropped. */
function settleWithin<T>(work: Promise<T>, fallback: T, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const finish = (value: T): void => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      resolve(value);
    };
    timer = setTimeout(() => finish(fallback), timeoutMs);
    work.then(finish, () => finish(fallback));
  });
}

/** Moves the native registration (`companion.rs`), which only accepts writes of the generation it returns. */
function registerCompanionWithNativeHost(host: MenuMijiaWindowsApp, enabled: boolean): Promise<number | null> {
  const state = hostState(host);
  const invoke = window.__TAURI_INTERNALS__?.invoke;
  // Every link settles (a hang resolves `null` after the bounded wait), so this chain never parks.
  state.companionGeneration = state.companionGeneration.then(async () => {
    try {
      const call = invoke?.<number>("set_companion_integration", { enabled });
      if (!call) return null;
      // A generation that arrives after the timeout belongs to a superseded run: the promise already
      // resolved `null`, so `setRaycastIntegrationEnabled` and `exportRaycastSnapshotNow` ignore it.
      const generation = await settleWithin(call, null, COMPANION_REGISTRATION_TIMEOUT_MS);
      return typeof generation === "number" ? generation : null;
    } catch {
      return null;
    }
  });
  return state.companionGeneration;
}

function companionDisconnectFailure(): CompanionNotice {
  return {
    checkedAt: Date.now(),
    lines: [tr3(
      "集成已关闭，但无法确认快照已移除。请重试删除快照。",
      "整合已關閉，但無法確認快照已移除。請重試刪除快照。",
      "Integration is off, but snapshot removal could not be confirmed. Retry deleting the snapshot.",
    )],
    isError: true,
    retryDisconnect: true,
  };
}

export function getCompanionNotice(host: MenuMijiaWindowsApp): CompanionNotice | null {
  return hostState(host).companionNotice;
}

export function setCompanionNotice(host: MenuMijiaWindowsApp, lines: readonly string[], isError: boolean): void {
  hostState(host).companionNotice = { checkedAt: Date.now(), lines, isError };
}

interface NativeCompanionStatus {
  readonly enabled?: boolean;
  readonly snapshotPath?: string | null;
  readonly snapshotExists?: boolean;
  readonly snapshotModifiedMs?: number | null;
  readonly forwardingReady?: boolean;
}

async function readNativeCompanionStatus(): Promise<NativeCompanionStatus | null> {
  const invoke = window.__TAURI_INTERNALS__?.invoke;
  if (!invoke) return null;
  try {
    const status = await invoke<unknown>("companion_status");
    return status && typeof status === "object" ? (status as NativeCompanionStatus) : null;
  } catch {
    return null;
  }
}

/**
 * MCP client config for 复制配置. It names the snapshot path only: the `bridgeToken` stays in the
 * owner-only snapshot file and is never put on the shared clipboard.
 */
export function buildCompanionConfigText(snapshotPath: string | null): string {
  const env = snapshotPath ? { MENUBARMIJIA_SNAPSHOT_PATH: snapshotPath } : {};
  return JSON.stringify(
    {
      mcpServers: {
        menubarhome: {
          command: "python",
          args: [tr3("<MenuBarHome 源码目录>\\scripts\\mijia-mcp", "<MenuBarHome 原始碼目錄>\\scripts\\mijia-mcp", "<MenuBarHome source folder>\\scripts\\mijia-mcp")],
          env,
        },
      },
    },
    null,
    2,
  );
}

export async function copyCompanionConfig(host: MenuMijiaWindowsApp): Promise<boolean> {
  const status = await readNativeCompanionStatus();
  const text = buildCompanionConfigText(status?.snapshotPath ?? null);
  const nav = host.root.ownerDocument?.defaultView?.navigator ?? globalThis.navigator;
  try {
    if (typeof nav?.clipboard?.writeText !== "function") return false;
    await nav.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

/** 检测接入: what this machine can actually confirm — the snapshot, forwarding and the last companion command. */
export async function detectCompanionIntegration(host: MenuMijiaWindowsApp): Promise<CompanionNotice> {
  const state = hostState(host);
  const epoch = state.companionEpoch;
  if (host.settings.enableRaycastIntegration && !host.isStandaloneSettingsWindow) {
    // A write still waiting on a retry would make the first check report a missing snapshot.
    await exportRaycastSnapshotNow(host, true);
  }
  const status = await readNativeCompanionStatus();
  const lines: string[] = [];
  let isError = false;
  if (!host.settings.enableRaycastIntegration) {
    if (status?.enabled !== false || status.snapshotExists !== false) {
      const failure = companionDisconnectFailure();
      if (epoch === state.companionEpoch) state.companionNotice = failure;
      return failure;
    }
    lines.push(tr3("集成已关闭：没有快照，外部工具发来的命令会被拒绝。", "整合已關閉：沒有快照，外部工具傳來的命令會被拒絕。", "Integration is off: no snapshot, and companion commands are refused."));
  } else if (status === null) {
    isError = true;
    lines.push(tr3("无法读取本机集成状态。", "無法讀取本機整合狀態。", "Could not read the local integration status."));
  } else {
    if (status.snapshotExists && status.enabled) {
      const at = status.snapshotModifiedMs ? new Date(status.snapshotModifiedMs).toLocaleTimeString() : "";
      lines.push(tr3("设备快照已导出 {at}", "裝置快照已匯出 {at}", "Device snapshot exported {at}", { at }).trim());
    } else {
      isError = true;
      lines.push(tr3("设备快照未导出，外部工具读不到设备。", "裝置快照未匯出，外部工具讀不到裝置。", "The device snapshot is missing, so companions cannot see devices."));
    }
    lines.push(
      status.forwardingReady
        ? tr3("链接转发正常：外部链接会交给正在运行的这个窗口。", "連結轉發正常：外部連結會交給正在執行的這個視窗。", "Link forwarding works: links reach this running instance.")
        : tr3("链接转发未就绪，可重启应用后再检测。", "連結轉發未就緒，可重新啟動應用程式後再檢測。", "Link forwarding is not ready; restart the app and check again."),
    );
    if (!status.forwardingReady) isError = true;
    const feedback = state.lastCommandFeedback;
    lines.push(
      feedback?.requestId
        ? tr3("最近一次外部命令：{time}", "最近一次外部命令：{time}", "Last companion command: {time}", { time: new Date(feedback.completedAt).toLocaleTimeString() })
        : tr3("还没收到外部工具的命令。", "還沒收到外部工具的命令。", "No companion command received yet."),
    );
  }
  const detection: CompanionNotice = { checkedAt: Date.now(), lines, isError };
  // A switch during the check makes the answer describe a run that is gone.
  if (epoch === state.companionEpoch) state.companionNotice = detection;
  return detection;
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
  const companionEpoch = state.companionEpoch;
  const revisionStillMatches = () =>
    host.sourceRevision === expectedRevision && state.companionEpoch === companionEpoch;
  let createdUndoAction: UndoAction | null = null;
  // Check before opening a prompt so a type closed ahead of the refresh is refused up front.
  const deviceWriteGate = (deviceId: string): string | null => {
    if (host.settings.connectionMode === "demo" && !isDualSourceEnabled(host)) return null;
    return evaluateDeviceEntityWriteGate({
      targetKind: "device",
      targetIdOrEntityId: deviceId,
      resolvedActiveDeviceId: host.devices.some((d) => d.id === deviceId) ? deviceId : null,
      context: buildHostCapabilityContext(host),
      rejectUnknown: true,
      languagePreference: host.settings.interfaceLanguage,
    });
  };
  return {
    lockHost: host,
    get devices() {
      return host.devices;
    },
    get scenes() {
      return host.scenes;
    },
    get sourceRevision() {
      return host.sourceRevision;
    },
    // The queued-link path is a production write entry, so it needs the same hidden index the panel
    // and voice gates get; without it a closed type answers "missing device" (P3a-W, P3b-W).
    get hiddenDevices() {
      return host.hiddenDevices;
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
      if (revisionStillMatches()) host.setPendingHighRisk(next);
    },

    clearPendingHighRisk(): void {
      if (revisionStillMatches()) host.clearPendingHighRisk();
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
      if (state.companionEpoch !== companionEpoch) return;
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
      const beforeUndo = host.lastUndoAction;
      await host.executeSingleCommand(device, command, summary, intent, readBackPower);
      createdUndoAction = host.lastUndoAction !== beforeUndo ? host.lastUndoAction : null;
    },

    async applyCommand(command, readBackPower): Promise<boolean> {
      if (!revisionStillMatches()) return false;
      return host.applyCommand(command, readBackPower);
    },

    updateUndoCommandsForDevice(deviceId, commands, previousKind): void {
      if (!revisionStillMatches() || !createdUndoAction) {
        return;
      }
      const mutableSteps = createdUndoAction.steps as UndoStep[];
      for (let i = 0; i < mutableSteps.length; i += 1) {
        if (mutableSteps[i]!.deviceId === deviceId) {
          mutableSteps[i] = { deviceId, commands: [...commands] };
        }
      }
      recordUndoKindSnapshots(createdUndoAction, new Map([[deviceId, structuredClone(previousKind)]]));
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
          message: tr3("数据源已切换，已取消外部链接执行", "資料源已切換，已取消外部連結執行", "Data source changed; external link cancelled"),
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
        const context = host.settings.connectionMode === "demo" && !isDualSourceEnabled(host)
          ? null
          : buildHostCapabilityContext(host);
        if (context) {
          const gateMsg = evaluateQuickActionSourceWriteGate({
            actionId: "lightsOff",
            scopeDevices: [],
            context,
            languagePreference: host.settings.interfaceLanguage,
          });
          if (gateMsg !== null) {
            host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
            host.render();
            return { message: gateMsg, isError: true };
          }
        }
        const { targets, skipped } = planWritableAllOff(
          foldGrouped(host, host.devices),
          host.settings.allOffOverrides,
          context,
        );
        const result = allOffResultText(targets.length, skipped);
        if (targets.length === 0) {
          return {
            message: skipped > 0
              ? result
              : tr3("当前没有开启的设备", "目前沒有開啟的裝置", "No active devices are currently on"),
            isError: false,
          };
        }
        const ok = await host.executeIntents(
          targets.map((d) => ({ targetId: d.id, operation: { kind: "power", isOn: false } })),
          result,
          t("一键全关"),
          { recordHabits: true },
        );
        return {
          message: host.replyBanner?.text ?? result,
          isError: !ok || Boolean(host.replyBanner?.isError),
        };
      }
      await host.performUndo();
      const banner = host.replyBanner;
      const noUndo =
        banner?.source === t("撤销提示") || Boolean(banner?.isError);
      return {
        message: banner?.text ?? tr3("没有可以撤销的操作", "沒有可以復原的操作", "Nothing to undo"),
        isError: noUndo,
      };
    },

    evaluateDeviceWriteGate: deviceWriteGate,

    isDeviceVisibleInPanel(deviceId: string): boolean {
      const dev = host.devices.find((d) => d.id === deviceId);
      if (!dev) return false;
      if (host.settings.hideOfflineDevices && !dev.isOnline) return false;
      return true;
    },

    focusDeviceFromUrl(deviceId: string): UrlDeviceFocusResult {
      if (!revisionStillMatches()) return "source-changed";
      if (host.activeSheet === "settings") {
        if (!host.requestCloseSettingsSheet()) return "unsaved-settings";
      } else {
        host.activeSheet = "none";
      }
      if (host.cameraLive.activeLiveCameraId !== null) {
        host.cameraLive.closeCameraLiveView();
      }
      host.panelSearch.query = "";
      const searchInput = host.root.querySelector<HTMLInputElement>("#command-input");
      if (searchInput) searchInput.value = "";
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
        `[data-tile-id="${escapedId}"]`,
      );
      card?.scrollIntoView?.({ block: "nearest" });
      return "focused";
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
  const companionEpoch = state.companionEpoch;
  return new Promise<void>((done) => {
    state.urlQueue.push({ url: rawUrl, sourceRevision, companionEpoch, done });
    if (!state.isDrainingUrlQueue) {
      state.isDrainingUrlQueue = true;
      void (async () => {
        try {
          while (state.urlQueue.length > 0) {
            const item = state.urlQueue.shift()!;
            try {
              if (item.url.startsWith("menumijia://notification/")) {
                // Toast links are external input and can only navigate to an existing card.
                const match = /^menumijia:\/\/notification\/(?:safety|doorbell|leak|smoke|gas)\/([a-zA-Z0-9_.:@-]{1,128})$/.exec(item.url);
                const deviceId = match?.[1];
                if (match?.[0] !== item.url || !deviceId || deviceId === "." || deviceId === "..") continue;
                if (item.sourceRevision !== host.sourceRevision) continue;
                const adapter = createUrlCommandHostAdapter(host, item.sourceRevision);
                if (!host.timerCredentialsReady && !adapter.isDeviceVisibleInPanel?.(deviceId)) {
                  await host.initialCredentialsReady;
                  if (item.sourceRevision !== host.sourceRevision || !host.root.isConnected) continue;
                }
                if (adapter.isDeviceVisibleInPanel?.(deviceId)) {
                  adapter.focusDeviceFromUrl(deviceId);
                }
                await adapter.revealPanelForExternalUrl();
                continue;
              }
              if (state.companionEpoch !== item.companionEpoch) {
                reportStaleExternalUrl(
                  host,
                  item.url,
                  tr3("Raycast 与本地 CLI / MCP 集成已切换，已取消之前排队的外部链接", "Raycast 與本機 CLI / MCP 整合已切換，已取消之前排隊的外部連結", "Raycast & local CLI / MCP integration was switched; earlier queued links were cancelled"),
                  false,
                );
                continue;
              }
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
function reportStaleExternalUrl(
  host: MenuMijiaWindowsApp,
  rawUrl: string,
  staleMessage = tr3("数据源已切换，已取消外部链接执行", "資料源已切換，已取消外部連結執行", "Data source changed; external link cancelled"),
  recordFeedback = true,
): void {
  host.replyBanner = {
    text: staleMessage,
    source: t("外部链接"),
    isError: true,
  };
  if (recordFeedback) {
    const envelope = AppURLParser.parseEnvelope(rawUrl);
    hostState(host).lastCommandFeedback = {
      ...(envelope?.requestId ? { requestId: envelope.requestId } : {}),
      command: envelope ? formatAppURLCommandLabel(envelope.command) : "invalid",
      message: staleMessage,
      isError: true,
      completedAt: new Date().toISOString(),
    };
  }
  host.render();
  if (recordFeedback && host.settings.enableRaycastIntegration) {
    void exportRaycastSnapshotNow(host, true);
  }
}

function bindCompanionAndUpdaterEvents(host: MenuMijiaWindowsApp): void {
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
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

  if (host.isStandaloneSettingsWindow) return;

  ownerWin.addEventListener("menumijia:open-url", (event: Event) => {
    if (!host.root.isConnected) return;
    const detail = (event as CustomEvent<unknown>).detail;
    if (typeof detail === "string" && detail.trim() !== "") {
      void enqueueIncomingOpenUrl(host, detail);
    }
  });

  void setRaycastIntegrationEnabled(host, host.settings.enableRaycastIntegration, { persistSettings: false, render: false });

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
