import type { MenuMijiaWindowsApp } from "./app.js";
import {
  HABIT_SEQUENCE_BOOST_WINDOW_MS,
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  buildAssistantContext,
  encodeHabitOperation,
  endpointAllowsSendingSecrets,
  habitActionable,
  isLocalAssistantEndpoint,
  timeBucketLabel,
} from "../core/assistant.js";
import type { AssistantSuggestion, SmartDevice } from "../core/models.js";
import { SF_ICONS } from "./appConstants.js";
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

/** The Top-4 zero-delay suggestions: the AI cache when fresh, otherwise ranked locally (#113). */
export function currentProactiveSuggestions(host: MenuMijiaWindowsApp): AssistantSuggestion[] {
  if (host.pendingSuggestions.length > 0) return [];
  const signature = proactiveSignature(host);
  const aliasedDevices = proactiveVisibleDevices(host);
  const favoriteIds = proactiveFavoriteIds(host.layout, aliasedDevices);
  const local = new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()).topSuggestions({
    devices: aliasedDevices,
    scenes: host.scenes,
    environmentReadings: host.computedEnvironmentReadings,
    favoriteIds,
  });
  const cached = host.aiProactiveSignature === signature ? host.aiProactiveSuggestions ?? [] : [];
  const result: AssistantSuggestion[] = [];
  for (const item of [...cached, ...local]) {
    const actionableIntents = item.intents.filter((intent) => habitActionable(intent, aliasedDevices, host.scenes));
    if (actionableIntents.length === 0) continue;
    const candidate: AssistantSuggestion = { ...item, intents: actionableIntents };
    if (result.some((existing) => JSON.stringify(existing.intents) === JSON.stringify(candidate.intents))) continue;
    result.push(candidate);
    if (result.length === 4) break;
  }
  return result;
}

export function renderProactiveInlinePill(host: MenuMijiaWindowsApp, item: AssistantSuggestion): string {
  const source = classifyProactiveSuggestionSource(host, item);
  const pct = normalizeConfidencePercent(item.confidencePercent);
  const tooltip = `${source.label} · ${item.title}${pct !== null ? ` (${pct}%)` : ""}`;
  return `<button class="cc-inline-pill" data-proactive-id="${host.escapeHtml(item.id)}" title="${host.escapeHtml(tooltip)}" style="display:inline-flex;align-items:center;gap:4px;"><span data-grok-source="${source.kind}" aria-hidden="true" style="width:12px;height:12px;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;">${source.icon}</span><span>${host.escapeHtml(item.title)}</span>${
    pct !== null ? `<span class="cc-grok-confidence" data-grok-confidence="${pct}" style="opacity:0.78;font-variant-numeric:tabular-nums;">· ${pct}%</span>` : ""
  }</button>`;
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
        // The context counts as served only once a usable result landed (Codex #116 review).
        host.aiProactiveSignature = signature;
        if (suggestions.length > 0) {
          host.aiProactiveSuggestions = suggestions;
        } else {
          // An empty result is a valid "home is ideal" answer: drop any older cache so the
          // local ranking takes over instead of stale suggestions (Codex #116 re-review).
          host.aiProactiveSuggestions = null;
        }
        if (!host.hasBlockingPanelInteraction()) host.render();
      }
    })
    .catch(() => {
      if (sourceRevision !== host.sourceRevision || host.settings.selectedHomeId !== selectedHomeId) return;
      // Silent: the previous cache keeps showing; retry after a cooldown (Codex #116 review).
      host.isRefreshingProactive = false;
      host.proactiveRetryAfterMs = Date.now() + PROACTIVE_RETRY_COOLDOWN_MS;
    });
}

export function invalidateSourceControl(host: MenuMijiaWindowsApp): void {
  abortVoiceInput(host);
  // Bump sourceRevision before resolving any pending URL confirmation so the drain loop sees
  // queued links as belonging to the previous source and cancels them cleanly.
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
  host.applyPanelHeight();
  host.haConnectionError = null;
  host.lastUndoAction = null;
  host.pendingCloudConsent = null;
  host.clearPendingHighRisk();
  host.lastManuallyUsedLightId = null;
  host.pendingSuggestions = [];
}
