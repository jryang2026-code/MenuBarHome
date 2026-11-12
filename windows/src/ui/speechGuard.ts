import { speechLocale, t } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import type { SmartDevice } from "../core/models.js";
import { planQuickAction, trText, type QuickActionId } from "../core/quickActions.js";
import { undoBannerMs, undoDeviceCount, type MenuMijiaWindowsApp } from "./app.js";
import type { SpeechRecognitionInstance, UndoAction, UndoStep } from "./appTypes.js";
import { foldGrouped } from "./cloudRefresh.js";
import { recordHabits } from "./intentExecution.js";
import { filterByListCut } from "./listCut.js";
import { invokeTauriVoid } from "./transport.js";

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
}

const runtimeStateByHost = new WeakMap<MenuMijiaWindowsApp, HostRuntimeGuardState>();
const undoKindSnapshots = new WeakMap<UndoAction, ReadonlyMap<string, SmartDevice["kind"]>>();

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
    };
    runtimeStateByHost.set(host, state);
  }
  return state;
}

export function shouldKeepPopoverPinned(host: MenuMijiaWindowsApp): boolean {
  return (
    host.isPollingQR ||
    host.activeSheet !== "none" ||
    host.isEditingLayout ||
    host.prompt !== null ||
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
        resumeUndoHoverPause(host);
      }
    },
    true,
  );
  window.addEventListener("blur", () => resumeUndoHoverPause(host));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      resumeUndoHoverPause(host);
    }
  });
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

  if (succeededCount > 0 && failedCount === 0) {
    host.grokBallCelebrationUntil = Date.now() + 2400;
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
