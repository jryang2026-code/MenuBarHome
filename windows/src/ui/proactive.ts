import type { MenuMijiaWindowsApp } from "./app.js";

const PROACTIVE_RETRY_COOLDOWN_MS = 5 * 60_000;
import {
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  buildAssistantContext,
  endpointAllowsSendingSecrets,
  habitActionable,
  isLocalAssistantEndpoint,
  timeBucketLabel,
} from "../core/assistant.js";
import type { AssistantSuggestion, SmartDevice } from "../core/models.js";
import { applyOrder, withAliases, type LayoutPrefs } from "./panelPrefs.js";
import { abortVoiceInput, clearUndoHoverPause } from "./speechGuard.js";

function proactiveFavoriteIds(layout: LayoutPrefs, devices: readonly SmartDevice[]): string[] {
  const rawFavorites = (layout as LayoutPrefs & { readonly favorites?: unknown }).favorites;
  const explicit = Array.isArray(rawFavorites)
    ? rawFavorites.filter((id): id is string => typeof id === "string")
    : [];
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
  const aliasedDevices = withAliases(host.layout, host.devices);
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
  const aliasedDevices = withAliases(host.layout, host.devices);
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
