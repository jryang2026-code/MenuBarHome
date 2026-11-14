import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import {
  HABIT_SEQUENCE_BOOST_WINDOW_MS,
  IntentValidator,
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  buildAssistantContext,
  encodeHabitOperation,
  endpointAllowsSendingSecrets,
  habitActionable,
  isLocalAssistantEndpoint,
  resolveGrokBallEmotion,
  timeBucketLabel,
} from "../core/assistant.js";
import { inverseCommands } from "../core/commandEffects.js";
import type { AssistantSuggestion, DeviceIntent, SmartDevice } from "../core/models.js";
import { SF_ICONS } from "./appConstants.js";
import {
  GROK_BALL_BASE_MARGIN_TOP_PX,
  GROK_BALL_DRAG_THRESHOLD_PX,
  clampGrokBallOffsetY,
  saveGrokBallOffsetY,
} from "./grokBall.js";
import { applyOrder, withAliases, type LayoutPrefs } from "./panelPrefs.js";
import { cancelRunningBatch } from "./intentExecution.js";
import { abortVoiceInput, clearUndoHoverPause } from "./speechGuard.js";
import { tr3 } from "./undoTracker.js";

const PROACTIVE_RETRY_COOLDOWN_MS = 5 * 60_000;

export type ProactiveSuggestionSourceKind = "habit" | "sequence" | "ambient" | "smart";

export interface ProactiveSuggestionSourceMeta {
  readonly kind: ProactiveSuggestionSourceKind;
  readonly label: string;
  readonly icon: string;
}

const SOURCE_ICONS: Readonly<Record<ProactiveSuggestionSourceKind, string>> = {
  habit: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/></svg>`,
  sequence: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 5v6a4 4 0 0 0 4 4h8"/><path d="m14 11 4 4-4 4"/></svg>`,
  ambient: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 14.76V5a2 2 0 1 0-4 0v9.76a4 4 0 1 0 4 0Z"/><path d="M12 9v6"/></svg>`,
  smart: SF_ICONS.sparkles,
};

interface GrokBallGestureState {
  phase: "idle" | "pressed" | "dragging" | "voice";
  pointerId: number | null;
  startX: number;
  startY: number;
  startOffsetY: number;
  wasListeningBeforePress: boolean;
  holdTimer: number | null;
  suppressClick: boolean;
  suppressResetTimer: number | null;
}

const gestureStateByHost = new WeakMap<MenuMijiaWindowsApp, GrokBallGestureState>();

function ensureGrokGestureState(host: MenuMijiaWindowsApp): GrokBallGestureState {
  let state = gestureStateByHost.get(host);
  if (!state) {
    state = {
      phase: "idle",
      pointerId: null,
      startX: 0,
      startY: 0,
      startOffsetY: 0,
      wasListeningBeforePress: false,
      holdTimer: null,
      suppressClick: false,
      suppressResetTimer: null,
    };
    gestureStateByHost.set(host, state);
  }
  return state;
}

export function isGrokBallOnLeft(
  host: Pick<MenuMijiaWindowsApp, "grokBallOnLeft" | "panelAnchor">,
): boolean {
  if (host.panelAnchor === "topRight" || host.panelAnchor === "bottomRight") return true;
  if (host.panelAnchor === "topLeft" || host.panelAnchor === "bottomLeft") return false;
  return host.grokBallOnLeft;
}

export function classifyProactiveSuggestionSource(
  host: Pick<MenuMijiaWindowsApp, "habitSequences" | "lastHabitAction">,
  item: AssistantSuggestion,
  nowMs = Date.now(),
): ProactiveSuggestionSourceMeta {
  const isExplicitSequence = item.id.startsWith("seq:") || item.id.startsWith("sequence:");
  const lastAction = host.lastHabitAction();
  const isBoostedSequence =
    !isExplicitSequence &&
    item.id.startsWith("habit:") &&
    lastAction !== null &&
    nowMs - lastAction.recordedAtMs <= HABIT_SEQUENCE_BOOST_WINDOW_MS &&
    (() => {
      const afterKey = `${lastAction.targetId}|${lastAction.operationKey}`;
      const sequences = host.habitSequences();
      return item.intents.some((intent) => {
        const opKey = encodeHabitOperation(intent.operation);
        return (
          opKey !== null &&
          sequences.some(
            (seq) =>
              seq.afterKey === afterKey &&
              seq.targetId === intent.targetId &&
              seq.operationKey === opKey,
          )
        );
      });
    })();

  if (isExplicitSequence || isBoostedSequence) {
    return {
      kind: "sequence",
      label: tr3("序列跟随", "序列跟隨", "Follow-up sequence"),
      icon: SOURCE_ICONS.sequence,
    };
  }
  if (item.id.startsWith("habit:")) {
    return {
      kind: "habit",
      label: tr3("时段习惯", "時段習慣", "Time-of-day habit"),
      icon: SOURCE_ICONS.habit,
    };
  }
  if (item.id.startsWith("env:") || item.id.startsWith("ambient:")) {
    return {
      kind: "ambient",
      label: tr3("环境触发", "環境觸發", "Ambient trigger"),
      icon: SOURCE_ICONS.ambient,
    };
  }
  return {
    kind: "smart",
    label: tr3("智能推荐", "智慧推薦", "Smart suggestion"),
    icon: SOURCE_ICONS.smart,
  };
}

function normalizeConfidencePercent(value: number | null): number | null {
  if (value === null || !Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, Math.round(value)));
}

type ExtendedLayoutPrefs = LayoutPrefs & {
  readonly pinnedDeviceIds?: unknown;
  readonly favorites?: unknown;
  readonly hiddenDeviceIds?: unknown;
};

function proactiveVisibleDevices(host: MenuMijiaWindowsApp): SmartDevice[] {
  const rawHidden = (host.layout as ExtendedLayoutPrefs).hiddenDeviceIds;
  const hiddenSet = new Set(
    Array.isArray(rawHidden)
      ? rawHidden.filter((id): id is string => typeof id === "string")
      : [],
  );
  const visible = hiddenSet.size > 0
    ? host.devices.filter((d) => !hiddenSet.has(d.id))
    : host.devices;
  return withAliases(host.layout, visible);
}

function proactiveFavoriteIds(layout: LayoutPrefs, devices: readonly SmartDevice[]): string[] {
  const ext = layout as ExtendedLayoutPrefs;
  const pinned = Array.isArray(ext.pinnedDeviceIds)
    ? ext.pinnedDeviceIds.filter((id): id is string => typeof id === "string")
    : [];
  const legacyFavorites = Array.isArray(ext.favorites)
    ? ext.favorites.filter((id): id is string => typeof id === "string")
    : [];
  const explicit: string[] = [];
  for (const id of [...pinned, ...legacyFavorites]) {
    if (!explicit.includes(id)) explicit.push(id);
  }
  const knownGroups = new Set(layout.groups.map((g) => g.id));
  const grouped: string[] = [];
  for (const group of layout.groups) {
    const members = applyOrder(
      layout.order,
      devices.filter((d) => {
        const gid = layout.groupMap[d.id];
        return gid === group.id && knownGroups.has(gid);
      }),
    );
    for (const dev of members) {
      if (!explicit.includes(dev.id) && !grouped.includes(dev.id)) {
        grouped.push(dev.id);
      }
    }
  }
  return [...explicit, ...grouped];
}

export function proactiveSignature(host: MenuMijiaWindowsApp): string {
  const bucket = timeBucketLabel(new Date().getHours());
  const readings = host.computedEnvironmentReadings
    .map(
      (reading) =>
        `${reading.temperature !== null ? Math.round(reading.temperature) : "-"}|${
          reading.humidity !== null ? Math.round(reading.humidity / 5) * 5 : "-"
        }`,
    )
    .join(",");
  return `${bucket}|${readings}`;
}

export function isIntentReversibleOnDevice(
  host: MenuMijiaWindowsApp,
  intent: DeviceIntent,
  device: SmartDevice,
): { reversible: boolean; nextDevice: SmartDevice } {
  if (!device.isOnline || (device.kind.kind === "plug" && device.kind.switchEntityId.startsWith("button."))) {
    return { reversible: false, nextDevice: device };
  }
  const normalized = IntentValidator.normalize(intent.operation, device);
  if (!normalized) return { reversible: false, nextDevice: device };
  if (
    host.settings.connectionMode === "homeAssistant" &&
    normalized.kind === "power" &&
    normalized.isOn &&
    device.kind.kind === "climate" &&
    !device.kind.availableModes.some((mode) => mode !== "off" && mode !== "unknown" && mode !== "unavailable")
  ) {
    return { reversible: false, nextDevice: device };
  }
  const normalizedIntent: DeviceIntent = { targetId: intent.targetId, operation: normalized };
  const commands = IntentValidator.commandsForIntent(normalizedIntent, device);
  if (commands.length === 0 || !commands.every((command) => inverseCommands(device, command).length > 0)) {
    return { reversible: false, nextDevice: device };
  }
  const k = device.kind;
  let nextKind = k;
  if (k.kind === "light") {
    if (normalized.kind === "power") nextKind = { ...k, isOn: normalized.isOn };
    else if (normalized.kind === "brightness") nextKind = { ...k, isOn: true, brightnessPercent: normalized.percent };
    else if (normalized.kind === "colorTemperature") nextKind = { ...k, isOn: true, colorTempKelvin: normalized.kelvin, currentEffect: null };
    else if (normalized.kind === "lightEffect") nextKind = { ...k, isOn: true, currentEffect: normalized.effect };
  } else if (k.kind === "climate") {
    if (normalized.kind === "power") {
      const resumeMode = k.hvacMode === "off" ? (k.availableModes.find((m) => m !== "off") ?? "cool") : k.hvacMode;
      nextKind = { ...k, isOn: normalized.isOn, hvacMode: normalized.isOn ? resumeMode : "off" };
    } else if (normalized.kind === "hvacMode") {
      nextKind = { ...k, isOn: normalized.mode !== "off", hvacMode: normalized.mode };
    } else if (normalized.kind === "targetTemperature") {
      nextKind = { ...k, targetTemperature: normalized.celsius };
    } else if (normalized.kind === "fanSpeed") {
      nextKind = { ...k, fanMode: normalized.speed };
    }
  }
  return { reversible: true, nextDevice: { ...device, kind: nextKind } };
}

/** The Top-4 zero-delay suggestions: the AI cache when fresh, otherwise ranked locally (#113). */
export function currentProactiveSuggestions(host: MenuMijiaWindowsApp): AssistantSuggestion[] {
  if (host.pendingSuggestions.length > 0 && !host.isGrokBallStageExpanded) return [];
  const signature = proactiveSignature(host);
  const aliasedDevices = proactiveVisibleDevices(host);
  const favoriteIds = proactiveFavoriteIds(host.layout, aliasedDevices);
  const local = new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()).topSuggestions({
    devices: aliasedDevices,
    scenes: host.isGrokBallStageExpanded ? [] : host.scenes,
    environmentReadings: host.computedEnvironmentReadings,
    favoriteIds,
  });
  const cached = host.aiProactiveSignature === signature ? host.aiProactiveSuggestions ?? [] : [];
  const fallback = host.isGrokBallStageExpanded
    ? new UserHabitMemory([]).topSuggestions({
        devices: aliasedDevices,
        scenes: [],
        limit: aliasedDevices.length + 4,
        favoriteIds,
      })
    : [];
  const result: AssistantSuggestion[] = [];
  for (const item of [...cached, ...local, ...fallback]) {
    if (host.isGrokBallStageExpanded && item.intents.some((intent) => intent.operation.kind === "activateScene")) continue;
    const actionableIntents = item.intents.filter((intent) => habitActionable(intent, aliasedDevices, host.scenes));
    if (actionableIntents.length === 0) continue;
    if (host.isGrokBallStageExpanded) {
      if (!item.intents.every((intent) => aliasedDevices.some((entry) => entry.id === intent.targetId && entry.isOnline))) continue;
      const stateByTarget = new Map<string, SmartDevice>();
      let allReversible = true;
      for (const intent of actionableIntents) {
        const current = stateByTarget.get(intent.targetId) ?? aliasedDevices.find((entry) => entry.id === intent.targetId);
        if (!current) {
          allReversible = false;
          break;
        }
        const check = isIntentReversibleOnDevice(host, intent, current);
        if (!check.reversible) {
          allReversible = false;
          break;
        }
        stateByTarget.set(intent.targetId, check.nextDevice);
      }
      if (!allReversible) continue;
    }
    const candidate: AssistantSuggestion = { ...item, intents: actionableIntents };
    if (result.some((existing) => JSON.stringify(existing.intents) === JSON.stringify(candidate.intents))) continue;
    result.push(candidate);
    if (result.length === 4) break;
  }
  return result;
}

export function syncGrokBallEmotion(host: MenuMijiaWindowsApp): void {
  const now = Date.now();
  host.grokBall.setEmotion(resolveGrokBallEmotion({
    timeBucket: timeBucketLabel(new Date(now).getHours()),
    activeDeviceCount: host.activeDeviceCount,
    speechListening: host.isListeningVoice,
    assistantState: host.isResolvingIntent ? "thinking" : host.pendingSuggestions.length > 0 ? "awaitingChoice" : "idle",
    isRecommending: host.isRefreshingProactive,
    hasErrorToast: host.replyBanner?.isError === true || Boolean(host.haConnectionError),
    isStageExpanded: host.isGrokBallStageExpanded,
    isPointerTracking: now < host.grokBallPointerUntil,
    hasRecentCelebration: now < host.grokBallCelebrationUntil,
  }));
}

export function renderProactiveInlinePill(host: MenuMijiaWindowsApp, item: AssistantSuggestion): string {
  const source = classifyProactiveSuggestionSource(host, item);
  const pct = normalizeConfidencePercent(item.confidencePercent);
  const tooltip = `${source.label} · ${item.title}${pct !== null ? ` (${pct}%)` : ""}`;
  return `<button class="cc-inline-pill" data-proactive-id="${host.escapeHtml(item.id)}" title="${host.escapeHtml(tooltip)}" style="display:inline-flex;align-items:center;gap:4px;"><span data-grok-source="${source.kind}" aria-hidden="true" style="width:12px;height:12px;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;">${source.icon}</span><span>${host.escapeHtml(item.title)}</span>${
    pct !== null ? `<span class="cc-grok-confidence" data-grok-confidence="${pct}" style="opacity:0.78;font-variant-numeric:tabular-nums;">· ${pct}%</span>` : ""
  }</button>`;
}

export function renderGrokBallStage(host: MenuMijiaWindowsApp): string {
  if (!host.isGrokBallStageExpanded) return "";
  const items = currentProactiveSuggestions(host).slice(0, 4);
  if (items.length === 0) {
    const emptyText = tr3(
      "暂无可用建议，先试着控制设备",
      "暫無可用建議，先試著控制設備",
      "No suggestions yet. Try controlling a device first.",
    );
    return `<section class="cc-grok-stage" aria-label="${t("猜你想控")}">
      <div class="cc-grok-empty" data-grok-empty role="status" style="width:148px;padding:10px 12px;border-radius:var(--r-module,12px);background:var(--glass-elevated);color:var(--text-secondary);font-size:11px;line-height:1.4;text-align:center;box-shadow:0 4px 12px rgba(0,0,0,0.16);">${host.escapeHtml(emptyText)}</div>
    </section>`;
  }
  return `<section class="cc-grok-stage" aria-label="${t("猜你想控")}">
    ${items
      .map((item) => {
        const source = classifyProactiveSuggestionSource(host, item);
        const pct = normalizeConfidencePercent(item.confidencePercent);
        const tooltip = `${source.label} · ${item.title}${pct !== null ? ` (${pct}%)` : ""}`;
        const safeTooltip = host.escapeHtml(tooltip);
        return `<button class="cc-grok-pill" data-proactive-id="${host.escapeHtml(item.id)}" title="${safeTooltip}" aria-label="${safeTooltip}" style="display:flex;align-items:center;gap:6px;padding:6px 10px;">
          <span class="cc-grok-source-icon" data-grok-source="${source.kind}" title="${host.escapeHtml(source.label)}" aria-hidden="true" style="width:13px;height:13px;flex-shrink:0;display:inline-flex;align-items:center;justify-content:center;color:var(--apple-amber);">${source.icon}</span>
          <span class="cc-grok-pill-title" style="flex:1 1 auto;min-width:0;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;">${host.escapeHtml(item.title)}</span>${
            pct !== null
              ? `<span class="cc-grok-confidence" data-grok-confidence="${pct}" style="flex-shrink:0;font-size:10px;font-weight:600;font-variant-numeric:tabular-nums;color:var(--text-secondary);">${pct}%</span>`
              : ""
          }</button>`;
      })
      .join("")}
  </section>`;
}

export function renderGrokBallSidebar(host: MenuMijiaWindowsApp): string {
  if (!host.settings.enableGrokBall) return "";
  const offsetY = clampGrokBallOffsetY(host.grokBall.offsetY, host.root);
  const ballHint = tr3(
    "点击展开建议 · 上下拖拽调整位置 · 长按语音控制",
    "點擊展開建議 · 上下拖曳調整位置 · 長按語音控制",
    "Click for suggestions · Drag vertically to reposition · Hold for voice",
  );
  return `<aside class="cc-grok-sidebar" aria-label="${t("猜你想控")}" data-grok-offset-y="${offsetY}" style="margin-top:${GROK_BALL_BASE_MARGIN_TOP_PX + offsetY}px;">
    <button class="cc-grok-toggle" id="btn-grok-ball" data-grok-toggle title="${host.escapeHtml(ballHint)}" aria-label="${t("猜你想控")}" aria-expanded="${host.isGrokBallStageExpanded}"><span data-grok-slot></span></button>
    ${renderGrokBallStage(host)}
  </aside>`;
}

export function setGrokBallStageExpanded(host: MenuMijiaWindowsApp, expanded: boolean): void {
  if (host.isGrokBallStageExpanded === expanded) return;
  host.isGrokBallStageExpanded = expanded;
  host.applyPanelHeight();
  if (window.__TAURI_INTERNALS__) {
    void host.panelGeometryUpdates.then(() => host.render());
  } else {
    host.render();
  }
}

export function cancelGrokBallGesture(host: MenuMijiaWindowsApp): void {
  const state = gestureStateByHost.get(host);
  if (!state) return;
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
  if (state.holdTimer !== null) {
    ownerWin.clearTimeout(state.holdTimer);
    state.holdTimer = null;
  }
  if (state.suppressResetTimer !== null) {
    ownerWin.clearTimeout(state.suppressResetTimer);
    state.suppressResetTimer = null;
  }
  state.suppressClick = false;
  if (state.phase === "idle") return;
  const prevPhase = state.phase;
  const wasListening = state.wasListeningBeforePress;
  state.phase = "idle";
  state.pointerId = null;
  host.pointerIsDown = false;
  host.root.querySelector<HTMLElement>(":scope > .cc-grok-sidebar")?.removeAttribute("data-dragging");
  if (prevPhase === "dragging") {
    saveGrokBallOffsetY(host.grokBall.offsetY);
  }
  if (prevPhase === "voice" && !wasListening && host.isListeningVoice) {
    abortVoiceInput(host);
    host.queueBackgroundRender();
  } else if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
    host.queueBackgroundRender();
  }
}

function asElement(target: EventTarget | null): Element | null {
  return target && typeof (target as Element).closest === "function" ? (target as Element) : null;
}

export function bindGrokBallGestures(host: MenuMijiaWindowsApp): () => void {
  const state = ensureGrokGestureState(host);
  const ownerWin = host.root.ownerDocument?.defaultView ?? window;

  const clearHoldTimer = () => {
    if (state.holdTimer !== null) {
      ownerWin.clearTimeout(state.holdTimer);
      state.holdTimer = null;
    }
  };

  const armClickSuppression = () => {
    state.suppressClick = true;
    if (state.suppressResetTimer !== null) {
      ownerWin.clearTimeout(state.suppressResetTimer);
    }
    state.suppressResetTimer = ownerWin.setTimeout(() => {
      state.suppressResetTimer = null;
      state.suppressClick = false;
    }, 0);
  };

  const collapseStageInPlaceForDrag = () => {
    if (!host.isGrokBallStageExpanded) return;
    host.isGrokBallStageExpanded = false;
    host.root.classList.remove("is-grok-expanded");
    host.root.querySelector(":scope > .cc-grok-sidebar .cc-grok-stage")?.remove();
    host.root.querySelector("#btn-grok-ball")?.setAttribute("aria-expanded", "false");
    host.applyPanelHeight();
    syncGrokBallEmotion(host);
  };

  const onPointerDown = (event: PointerEvent) => {
    if (event.button !== 0 || !host.settings.enableGrokBall) return;
    const target = asElement(event.target);
    const toggle = target?.closest<HTMLElement>("[data-grok-toggle]");
    if (!toggle) return;

    clearHoldTimer();
    if (state.suppressResetTimer !== null) {
      ownerWin.clearTimeout(state.suppressResetTimer);
      state.suppressResetTimer = null;
    }
    state.suppressClick = false;
    state.phase = "pressed";
    state.pointerId = typeof event.pointerId === "number" ? event.pointerId : null;
    state.startX = event.clientX;
    state.startY = event.clientY;
    state.startOffsetY = clampGrokBallOffsetY(host.grokBall.offsetY, host.root);
    state.wasListeningBeforePress = host.isListeningVoice;
    host.pointerIsDown = true;

    const holdMs = Math.max(0, host.grokBall.voiceHoldMs);
    state.holdTimer = ownerWin.setTimeout(() => {
      state.holdTimer = null;
      if (state.phase !== "pressed") return;
      if (!host.root.isConnected || document.visibilityState === "hidden" || !document.hasFocus()) {
        cancelGrokBallGesture(host);
        return;
      }
      state.phase = "voice";
      state.suppressClick = true;
      if (host.isGrokBallStageExpanded) {
        host.setGrokBallStageExpanded(false);
      }
      if (!state.wasListeningBeforePress) {
        if (!host.isListeningVoice) {
          host.toggleVoiceInput();
        }
      } else {
        host.toggleVoiceInput();
      }
    }, holdMs);
  };

  const onPointerMove = (event: PointerEvent) => {
    if (state.phase === "idle") return;
    if (
      state.pointerId !== null &&
      typeof event.pointerId === "number" &&
      event.pointerId !== state.pointerId
    ) {
      return;
    }
    const dx = event.clientX - state.startX;
    const dy = event.clientY - state.startY;
    if (state.phase === "pressed") {
      if (Math.hypot(dx, dy) < GROK_BALL_DRAG_THRESHOLD_PX) return;
      clearHoldTimer();
      state.phase = "dragging";
      state.suppressClick = true;
      collapseStageInPlaceForDrag();
      host.root.querySelector<HTMLElement>(":scope > .cc-grok-sidebar")?.setAttribute("data-dragging", "true");
    }
    if (state.phase === "dragging") {
      host.grokBall.setOffsetY(state.startOffsetY + dy, host.root, false);
    }
  };

  const onPointerUp = (event: PointerEvent) => {
    if (state.phase === "idle") return;
    if (
      state.pointerId !== null &&
      typeof event.pointerId === "number" &&
      event.pointerId !== state.pointerId
    ) {
      return;
    }
    clearHoldTimer();
    const finishedPhase = state.phase;
    const wasListeningBeforePress = state.wasListeningBeforePress;
    state.phase = "idle";
    state.pointerId = null;
    host.pointerIsDown = false;
    host.root.querySelector<HTMLElement>(":scope > .cc-grok-sidebar")?.removeAttribute("data-dragging");

    if (finishedPhase === "pressed") {
      if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
        host.queueBackgroundRender();
      }
      return;
    }
    armClickSuppression();
    if (finishedPhase === "dragging") {
      saveGrokBallOffsetY(host.grokBall.offsetY);
      if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
        host.queueBackgroundRender();
      }
      return;
    }
    if (finishedPhase === "voice") {
      if (!wasListeningBeforePress && host.isListeningVoice) {
        const pendingInterim = !host.panelSearch.query
          ? (host.root.querySelector<HTMLInputElement>("#command-input")?.value.trim() ?? "")
          : "";
        host.toggleVoiceInput();
        if (pendingInterim) {
          void host.handleNaturalCommand(pendingInterim);
        }
      } else if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
        host.queueBackgroundRender();
      }
    }
  };

  const onRootClickCapture = (event: MouseEvent) => {
    const target = asElement(event.target);
    if (!target?.closest("[data-grok-toggle]")) return;
    if (!state.suppressClick) return;
    state.suppressClick = false;
    if (state.suppressResetTimer !== null) {
      ownerWin.clearTimeout(state.suppressResetTimer);
      state.suppressResetTimer = null;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
  };

  const onAbortGesture = () => {
    cancelGrokBallGesture(host);
  };

  host.root.addEventListener("pointerdown", onPointerDown as EventListener);
  host.root.addEventListener("click", onRootClickCapture as EventListener, true);
  ownerWin.addEventListener("pointermove", onPointerMove as EventListener);
  ownerWin.addEventListener("pointerup", onPointerUp as EventListener);
  ownerWin.addEventListener("pointercancel", onAbortGesture);
  ownerWin.addEventListener("blur", onAbortGesture);

  return () => {
    cancelGrokBallGesture(host);
    host.root.removeEventListener("pointerdown", onPointerDown as EventListener);
    host.root.removeEventListener("click", onRootClickCapture as EventListener, true);
    ownerWin.removeEventListener("pointermove", onPointerMove as EventListener);
    ownerWin.removeEventListener("pointerup", onPointerUp as EventListener);
    ownerWin.removeEventListener("pointercancel", onAbortGesture);
    ownerWin.removeEventListener("blur", onAbortGesture);
  };
}

/**
 * Silent background AI refresh for proactive suggestions (#113): fires only when the
 * time bucket or room climate changed, never blocks the panel, never asks for consent,
 * and keeps the previous cache when the request fails.
 */
export function maybeRefreshProactiveInBackground(host: MenuMijiaWindowsApp): void {
  if (host.isRefreshingProactive || host.settings.connectionMode === "demo") return;
  if (host.proactiveRetryAfterMs !== null && Date.now() < host.proactiveRetryAfterMs) return;
  const signature = proactiveSignature(host);
  if (signature === host.aiProactiveSignature) return;
  const baseURL = host.settings.assistantBaseURL.trim() || "https://openrouter.ai/api/v1";
  if (!endpointAllowsSendingSecrets(baseURL)) return;
  const apiKey = host.apiKeyFor(baseURL);
  const isLoopback = isLocalAssistantEndpoint(baseURL);
  if (!apiKey && !isLoopback) return;
  if (!isLoopback) {
    const endpoint = assistantEndpointIdentity(baseURL);
    if (!endpoint || !host.settings.cloudConsentEndpoints.includes(endpoint)) return;
  }
  const sourceRevision = host.sourceRevision;
  const selectedHomeId = host.settings.selectedHomeId;
  host.isRefreshingProactive = true;
  const resolver = new ModelIntentResolver(
    { baseURL, model: host.settings.assistantModel, apiKey },
    host.transport,
  );
  const aliasedDevices = proactiveVisibleDevices(host);
  resolver
    .recommendProactiveSuggestions(
      aliasedDevices,
      host.scenes,
      buildAssistantContext({
        now: new Date(),
        readings: host.computedEnvironmentReadings,
        devices: aliasedDevices,
        scenes: host.scenes,
        sharing: host.settings.habitShareEnabled ? "on" : "off",
        memory: new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()),
        phrases: host.settings.learnedShortcuts.map((shortcut) => ({
          phrase: shortcut.phrase,
          intents: shortcut.intents,
        })),
        mention: { kind: "none" },
      }),
    )
    .then((suggestions) => {
      if (sourceRevision !== host.sourceRevision || host.settings.selectedHomeId !== selectedHomeId) return;
      host.isRefreshingProactive = false;
      if (proactiveSignature(host) === signature) {
        host.aiProactiveSignature = signature;
        if (suggestions.length > 0) {
          host.aiProactiveSuggestions = suggestions;
        } else {
          host.aiProactiveSuggestions = null;
        }
        if (!host.hasBlockingPanelInteraction()) host.render();
      }
    })
    .catch(() => {
      if (sourceRevision !== host.sourceRevision || host.settings.selectedHomeId !== selectedHomeId) return;
      host.isRefreshingProactive = false;
      host.proactiveRetryAfterMs = Date.now() + PROACTIVE_RETRY_COOLDOWN_MS;
    });
}

export function invalidateSourceControl(host: MenuMijiaWindowsApp): void {
  cancelGrokBallGesture(host);
  abortVoiceInput(host);
  host.sourceRevision += 1;
  cancelRunningBatch(host, "sourceChanged");
  clearUndoHoverPause(host);
  host.timerSnapshot = null;
  host.syncGeneration += 1;
  host.isSyncingCloud = false;
  host.isPollingQR = false;
  host.qrTicket = null;
  host.isResolvingIntent = false;
  host.aiProactiveSuggestions = null;
  host.aiProactiveSignature = null;
  host.isRefreshingProactive = false;
  host.proactiveRetryAfterMs = null;
  host.isGrokBallStageExpanded = false;
  host.grokBallCelebrationUntil = 0;
  host.applyPanelHeight();
  host.haConnectionError = null;
  host.lastUndoAction = null;
  host.pendingCloudConsent = null;
  host.clearPendingHighRisk();
  host.lastManuallyUsedLightId = null;
  host.pendingSuggestions = [];
}
