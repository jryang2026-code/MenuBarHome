import { miSceneRows, refreshMiScenes, type MiSceneSnapshot } from "../core/miCloud/scenes.js";
import { markTimerSnapshotReady, scheduledCommandIdentity } from "./scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { deviceCategoryForDevice } from "../core/capabilityManifest.js";
import { MiCloudClient, MiCloudError, MiotSynthesizer, normalizeMiCloudRegion, type MiDeviceRecord, type MiRoom, type MiSession, type MiotDeviceSpec } from "../core/miCloudClient.js";
import { discoverMiHome } from "../core/miCloud/discovery.js";
import { HomeAssistantClient, homeAssistantIdentity, type HAInvoke } from "../core/homeAssistant.js";
import { adoptPairedDevicePreferences, applyOrder, homeOptions, scopedKey, spans, tr3 } from "./panelPrefs.js";
import { filterByListCut, foldGroupedLights, kindChips, memberGroupOwners, showsKindRow } from "./listCut.js";
import { hasMatchingDomShape, morphMatchingDom, parseSingleElement } from "./dom.js";
import { getPanelThemeProfile, normalizePanelTheme } from "./panelTheme.js";
import { hasPendingMiVaultDeletion } from "./speechGuard.js";
import { environmentReadingPriority, type FacetControl, type HomeBackend, type HomeScene, type SmartDevice } from "../core/models.js";
import { appDiagnosticsLog } from "../core/diagnosticsAndScanner.js";
import {
  DUAL_SOURCE_ENABLED_STORAGE_KEY,
  DualSourceCoordinator,
  extractMiDeviceIdentities,
  fetchHASnapshotWithIdentities,
  type DeviceMergeResult,
  type DualSourceInputSnapshot,
} from "../core/dualSourceProvider.js";
import {
  MiAccountsStore,
  hasCorruptMiAccountIndex,
  hasSecondaryMiAccountsInIndex,
  makeMiAccount,
  miAccountId,
  refreshMiAccountsConcurrently,
  type AccountChildSnapshot,
  type MergedMiAccountsSnapshot,
  type MiAccount,
} from "../core/miAccountsStore.js";
import { isHostAttachedToActiveWindow, mergeHomeSnapshotRespectingLocks } from "../core/optimisticLock.js";
import { STALE, type EpochToken, type SyncRunToken } from "./sourceEpoch.js";
import { getUnsupportedLightEffects } from "./commandDispatch.js";
import { patchConnectionStatusFooter } from "./connectionStatus.js";
import { switchLightMarkIds } from "../core/switchLightMarks.js";
import { AutomationRuleStore, type HASnapshotLike } from "../core/automationEngine.js";
import { ingestHostHASnapshotForDoorbell, structuralActivityStackKey } from "./activityStackView.js";
import { energyScopeForHost, plugTodaySummaryForDrawer, syncEnergyHostOnRender } from "./energySettingsView.js";
import { structuralSensorHistoryKey, syncSensorHistoryHost } from "./sensorHistoryView.js";
import { availableQuickActions } from "../core/quickActions.js";
import { normalizeSearch } from "../core/panelSearch.js";
import { renderSliderDeck } from "./panelView.js";
import { getCachedUnsupportedDeviceCountOnHost } from "./connectionsAndDiagView.js";
import { buildPanelDeviceGridModel, renderLongTailBarHtml } from "./panelSplitTiles.js";
import { isWorkstationLocked } from "./transport.js";
import {
  clearCachedXiaomiTopology,
  clearXiaomiRateLimitBackoff,
  isPersistedMiSessionExpired,
  isXiaomiRateLimitError,
  miSessionFingerprint,
  persistMiSessionExpired,
  recordXiaomiRateLimit,
  shouldSkipSilentPollForBackoff,
  storeCachedXiaomiTopology,
  takeCachedXiaomiTopologyForPoll,
} from "../core/pollingPolicy.js";
import {
  filterEnabledMiAccounts,
  haConnectionScope,
  isHaScopeEnabledInState,
  isMiSessionEnabledInState,
  miAccountScope,
  resolveMiAccountSelectionState,
  revalidateAfterMiAccountReenable,
  type HostCapabilityContextInput,
  type MiAccountSelectionState,
} from "../core/miAccountControl.js";
import { buildMiotTypePrunePlan, miotRoundClosesCategory } from "../core/miotTypePruning.js";
import type { HaTypePruneOptions } from "../core/haTypePruning.js";
import { safetySignalsForPrefs } from "../core/safetySignalPolicy.js";
import { loadSensorAlertPolicy } from "../core/safetyAndHealth.js";
import { loadSafetyGuardPrefs } from "./automationSettingsView.js";
import { buildIndexedCapabilityDevices } from "../core/miAccountControl.js";
import type { CapabilityIndexedDevice, CapabilitySelection, SafetySignalKind } from "../core/capabilityReferenceVerdict.js";
import {
  getHaScopeLifecyclePhase,
  isHaBlockedRequestError,
  isHaScopeDisabledInStorage,
  type HaConnectionLifecyclePhase,
} from "../core/haTransportGate.js";
import type { LoadedSettings, PersistedSettings } from "./appTypes.js";

type MiSelectionHost = DualSourceInspectableHost & {
  readonly miAccountsStore?: MiAccountsStore | null;
  readonly loadedSettings?: LoadedSettings;
  readonly identityMigrationDiagnostic?: string | null;
  readonly timerCredentialsReady?: boolean;
};

function hostKnownMiAccounts(host: MiSelectionHost, accounts?: readonly MiAccount[]): readonly MiAccount[] {
  if (accounts) return accounts;
  if (host.miAccountsOverride) return host.miAccountsOverride;
  if (host.multiAccountState?.accounts?.length) return host.multiAccountState.accounts;
  const storeAccounts = host.miAccountsStore?.getAccounts();
  if (storeAccounts && storeAccounts.length > 0) return storeAccounts;
  return host.settings.miSession ? [makeMiAccount(host.settings.miSession as MiSession)] : [];
}

export function resolveHostMiSelectionState(host: MiSelectionHost, accounts?: readonly MiAccount[]): MiAccountSelectionState {
  const list = hostKnownMiAccounts(host, accounts);
  const partial = host.miAccountsStore?.getAccountsReadState() === "partial";
  const loaded = host.loadedSettings;
  const hasHaScope = Boolean(haConnectionScope(host.settings.haBaseURL ?? null, host.settings.haToken ?? null));
  const hasExistingPreferences = loaded
    ? loaded.hasPersistedSettings || loaded.hasExplicitOnboardingFlag || loaded.settings.hasCompletedOnboarding
    : Boolean(list.length > 0 || hasHaScope || isDualSourceEnabled(host));
  const hasPersistedLocalData = loaded?.hasPersistedLocalData ?? false;
  const identityReadFailure =
    (partial ? "partial_mi_accounts_vault" : null) ??
    loaded?.settingsReadError ??
    host.identityMigrationDiagnostic ??
    (hasCorruptMiAccountIndex() ? "corrupt_mi_accounts_index" : null);
  const state = resolveMiAccountSelectionState({
    accounts: list,
    haBaseURL: host.settings.haBaseURL ?? null,
    haToken: host.settings.haToken ?? null,
    ...(host.settings.connectionMode ? { connectionMode: host.settings.connectionMode } : {}),
    dualSourceEnabled: isDualSourceEnabled(host),
    hasExistingPreferences,
    hasPersistedLocalData,
    identityReadFailure,
  });
  const canSealMigration =
    !identityReadFailure &&
    (list.length > 0 || hasHaScope || (host.timerCredentialsReady === true && (hasExistingPreferences || hasPersistedLocalData)));
  if (canSealMigration) state.persistIfMigrationReady();
  return state;
}

export const resolveEnabledMiAccountsForHost = (host: MiSelectionHost, accounts?: readonly MiAccount[]): MiAccount[] => {
  const resolved = hostKnownMiAccounts(host, accounts);
  return filterEnabledMiAccounts(resolved, resolveHostMiSelectionState(host, resolved));
};

/**
 * Device-type pruning inputs for one Mi refresh round (P3a-W): the host selection plus every safety
 * signal that is currently on, so a closed category keeps exactly the reads its alerts need.
 */
export interface HostMiotTypePruneOptions {
  readonly selection: CapabilitySelection;
  readonly safetySignals: readonly SafetySignalKind[];
  /** Pinned cards, whose offline alert keeps only their topology record. */
  readonly starredDeviceIds: readonly string[];
}

export function hostMiotTypePruneOptions(
  host: MiSelectionHost & {
    readonly layout?: { readonly pinnedDeviceIds?: readonly string[] } | null;
    readonly settings: DualSourceInspectableHost["settings"] & {
      readonly layout?: { readonly pinnedDeviceIds?: readonly string[] } | null;
    };
  },
): HostMiotTypePruneOptions {
  return {
    selection: resolveHostMiSelectionState(host).selection,
    // "安全与提醒" owns these: the master switch drops the long-run, battery and pinned-offline
    // alerts, and each keeps only its own signal. The sensor alerts have their own switches below
    // it, so they stay on (architecture.md §D, ruling 3).
    safetySignals: safetySignalsForPrefs(loadSafetyGuardPrefs(), loadSensorAlertPolicy()),
    starredDeviceIds: [...new Set([
      ...(host.layout?.pinnedDeviceIds ?? []),
      ...(host.settings.layout?.pinnedDeviceIds ?? []),
    ])],
  };
}

/**
 * The off-panel half of a Mi snapshot. `safetyDevices` are read and synthesized only so enabled
 * alerts keep their signal; `hiddenDevices` let the host write gate answer "该设备类型已关闭"
 * instead of "设备不存在" for a closed type. Neither ever becomes a card, search hit, AI target or
 * control entry (architecture.md §D, ruling 3).
 */
export interface HostMiotTypePruneSnapshot {
  readonly safetyDevices?: readonly SmartDevice[];
  readonly safetyDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly hiddenDevices?: readonly CapabilityIndexedDevice[];
  /** The plan's own per-card signals, so the device-type preview names what pruning keeps. */
  readonly safetySignalsByDeviceId?: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

/** The host fields the Mi prune snapshot owns. */
export interface MiotTypePruneHostSlice {
  safetyRetainedDevices?: SmartDevice[];
  safetyRetainedDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  hiddenMiDevices?: readonly CapabilityIndexedDevice[];
  miTypeSafetySignals?: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

export function applyMiotTypePruneSnapshot(
  host: MiotTypePruneHostSlice,
  snapshot: HostMiotTypePruneSnapshot | null | undefined,
): void {
  host.safetyRetainedDevices = snapshot?.safetyDevices ? [...snapshot.safetyDevices] : [];
  host.safetyRetainedDeviceFacets = snapshot?.safetyDeviceFacets ?? {};
  host.hiddenMiDevices = snapshot?.hiddenDevices ? [...snapshot.hiddenDevices] : [];
  host.miTypeSafetySignals = snapshot?.safetySignalsByDeviceId ?? {};
}

/**
 * Drops one Mi account's off-panel devices right after it is disabled: until the next refresh
 * rewrites the snapshot, its retained sensors would otherwise keep evaluating (P3a-W).
 */
export function dropMiotTypePruneSnapshotForAccount(
  host: MiotTypePruneHostSlice & { readonly devices?: readonly SmartDevice[] },
  accountId: string,
): void {
  const scope = miAccountScope(accountId);
  const ownedByAccount = (device: { readonly id: string; readonly accountId?: string }): boolean =>
    device.accountId === accountId || device.id.startsWith(`${accountId}/`);
  const retained = host.safetyRetainedDevices ?? [];
  const dropped = new Set(retained.filter(ownedByAccount).map((device) => device.id));
  const facets: Record<string, readonly FacetControl[]> = { ...(host.safetyRetainedDeviceFacets ?? {}) };
  for (const id of dropped) delete facets[id];
  const droppedSignalIds = new Set([
    ...dropped,
    ...(host.devices ?? []).filter(ownedByAccount).map((device) => device.id),
    ...(host.hiddenMiDevices ?? []).filter((device) => device.sourceScope === scope).map((device) => device.id),
  ]);
  applyMiotTypePruneSnapshot(host, {
    safetyDevices: retained.filter((device) => !dropped.has(device.id)),
    safetyDeviceFacets: facets,
    hiddenDevices: (host.hiddenMiDevices ?? []).filter((device) => device.sourceScope !== scope),
    safetySignalsByDeviceId: Object.fromEntries(
      Object.entries(host.miTypeSafetySignals ?? {}).filter(([id]) => !droppedSignalIds.has(id)),
    ),
  });
}

/**
 * Device-type pruning inputs for one Home Assistant round (P3b-W). The selection is the host's own —
 * the same one the Mi refresh uses — because a turned-off type is turned off on both sources.
 */
function hostHaTypePruneOptions(
  host: MiSelectionHost & {
    readonly layout?: { readonly pinnedDeviceIds?: readonly string[] } | null;
    readonly settings: DualSourceInspectableHost["settings"] & {
      readonly layout?: { readonly pinnedDeviceIds?: readonly string[] } | null;
      readonly allOffOverrides?: Readonly<Record<string, boolean>>;
    };
  },
): HaTypePruneOptions | null {
  const scope = haConnectionScope(host.settings.haBaseURL ?? null, host.settings.haToken ?? null);
  if (!scope) return null;
  return {
    selection: resolveHostMiSelectionState(host).selection,
    connectionScope: scope,
    safetySignals: safetySignalsForPrefs(loadSafetyGuardPrefs(), loadSensorAlertPolicy()),
    starredDeviceIds: [...new Set([
      ...(host.layout?.pinnedDeviceIds ?? []),
      ...(host.settings.layout?.pinnedDeviceIds ?? []),
    ])],
    ...(host.settings.allOffOverrides ? { allOffOverrides: host.settings.allOffOverrides } : {}),
  };
}

/**
 * The off-panel half of a Home Assistant snapshot. `safetyDevices` are synthesized only so enabled
 * alerts keep their signal; `hiddenDevices` let the host write gate answer "该设备类型已关闭"
 * instead of "设备不存在" for a closed type. Neither ever becomes a card, search hit, AI target or
 * control entry (architecture.md §D).
 */
export interface HostHaTypePruneSnapshot {
  /** The `ha:` scope these entries belong to; a different endpoint makes them stale. */
  readonly scope: string;
  readonly safetyDevices?: readonly SmartDevice[];
  readonly safetyDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly hiddenDevices?: readonly CapabilityIndexedDevice[];
  /** Every card's own signals (`haCardSafetySignals`), kept even when this round pruned nothing. */
  readonly safetySignalsByDeviceId?: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

/** The host fields the off-panel Home Assistant snapshot owns; every production host is wider. */
export interface HaTypePruneHostSlice {
  haTypePruneScope?: string | null;
  safetyRetainedHADevices?: SmartDevice[];
  safetyRetainedHADeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  hiddenHADevices?: readonly CapabilityIndexedDevice[];
  haTypeSafetySignals?: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

export function applyHaTypePruneSnapshot(
  host: HaTypePruneHostSlice,
  snapshot: HostHaTypePruneSnapshot | null | undefined,
): void {
  host.haTypePruneScope = snapshot?.scope ?? null;
  host.safetyRetainedHADevices = snapshot?.safetyDevices ? [...snapshot.safetyDevices] : [];
  host.safetyRetainedHADeviceFacets = snapshot?.safetyDeviceFacets ?? {};
  host.hiddenHADevices = snapshot?.hiddenDevices ? [...snapshot.hiddenDevices] : [];
  host.haTypeSafetySignals = snapshot?.safetySignalsByDeviceId ?? {};
}

/**
 * The retained and hidden halves belong to one endpoint. Turning the connection off, removing it or
 * pointing the app at another Home Assistant leaves them behind, so every reader asks whether the
 * scope that wrote them is still the current one.
 */
export interface HaTypePruneHostFields extends HaTypePruneHostSlice {
  readonly settings: {
    readonly haBaseURL?: string | null;
    readonly haToken?: string | null;
    readonly connectionMode?: string;
    readonly dualSourceEnabled?: boolean;
  };
  readonly dualSourceEnabledOverride?: boolean | null;
  readonly miSession?: unknown;
}

export function haTypePruneSnapshotIsCurrent(host: HaTypePruneHostFields): boolean {
  // The slice is only live while Home Assistant is an active source: a host that switched back to
  // Mi must not answer for, or alert from, a connection it is no longer reading.
  if (host.settings.connectionMode !== "homeAssistant" && !isDualSourceEnabled(host as DualSourceInspectableHost)) {
    return false;
  }
  const scope = haConnectionScope(host.settings.haBaseURL ?? null, host.settings.haToken ?? null);
  return scope !== null && (host.haTypePruneScope ?? null) === scope;
}

/** Home Assistant cards a closed type keeps only for enabled alerts, scoped to the live endpoint. */
export function safetyRetainedHADevices(host: HaTypePruneHostFields): readonly SmartDevice[] {
  return haTypePruneSnapshotIsCurrent(host) ? host.safetyRetainedHADevices ?? [] : [];
}

/** Facet rows of `safetyRetainedHADevices`; a retained generic card's alert labels live here. */
export function safetyRetainedHADeviceFacets(
  host: HaTypePruneHostFields,
): Readonly<Record<string, readonly FacetControl[]>> {
  return haTypePruneSnapshotIsCurrent(host) ? host.safetyRetainedHADeviceFacets ?? {} : {};
}

/**
 * Every identity entry the device-type selection withholds, from both sources, for the host write
 * gate and the voice/AI resolution stub (P3a-W, P3b-W).
 */
export function hiddenTypeDevices(
  host: HaTypePruneHostFields & { readonly hiddenMiDevices?: readonly CapabilityIndexedDevice[] },
): readonly CapabilityIndexedDevice[] {
  const mi = host.hiddenMiDevices ?? [];
  const ha = haTypePruneSnapshotIsCurrent(host) ? host.hiddenHADevices ?? [] : [];
  return ha.length === 0 ? mi : [...mi, ...ha];
}

export const isHostMiSessionEnabled = (host: MiSelectionHost, session: MiSession | null | undefined): boolean =>
  Boolean(session && isMiSessionEnabledInState(session, resolveHostMiSelectionState(host, [makeMiAccount(session)])));

export function isHostHaEnabled(host: MiSelectionHost): boolean {
  const scope = haConnectionScope(host.settings.haBaseURL ?? null, host.settings.haToken ?? null);
  if (!scope) return true;
  return isHaScopeEnabledInState(scope, resolveHostMiSelectionState(host));
}

export function getHostHaLifecyclePhase(host: MiSelectionHost): HaConnectionLifecyclePhase {
  const phase = getHaScopeLifecyclePhase(host.settings.haBaseURL ?? null);
  if (phase === "stopping" || phase === "stop_timeout") return phase;
  return isHostHaEnabled(host) ? "enabled" : "disabled";
}

export interface HaCacheReadSettings<
  TCache extends { readonly identity: string } | null | undefined = PersistedSettings["cachedHAHome"],
> {
  readonly haBaseURL?: string | null;
  readonly haToken?: string | null;
  readonly cachedHAHome?: TCache;
}

export function settingsHaCacheIfEnabled<
  TCache extends { readonly identity: string } | null | undefined = PersistedSettings["cachedHAHome"],
>(
  settings: HaCacheReadSettings<TCache>,
  options?: { readonly requireIdentityMatch?: boolean },
): NonNullable<TCache> | null {
  const cache = settings.cachedHAHome ?? null;
  const identityBaseUrl = cache?.identity ? (cache.identity.split("|", 1)[0] ?? null) : null;
  const scope =
    haConnectionScope(settings.haBaseURL ?? null, settings.haToken ?? null) ??
    haConnectionScope(identityBaseUrl);
  if (scope && isHaScopeDisabledInStorage(scope)) return null;
  if (!cache) return null;
  if (options?.requireIdentityMatch) {
    const expected = homeAssistantIdentity(settings.haBaseURL ?? "", settings.haToken ?? "");
    return expected !== null && cache.identity === expected ? (cache as NonNullable<TCache>) : null;
  }
  return cache as NonNullable<TCache>;
}

export function haCacheIfEnabled(
  host: MiSelectionHost & { readonly settings: DualSourceInspectableHost["settings"] & Pick<HaCacheReadSettings, "cachedHAHome"> },
  options?: { readonly requireIdentityMatch?: boolean },
): NonNullable<PersistedSettings["cachedHAHome"]> | null {
  if (!isHostHaEnabled(host)) return null;
  return settingsHaCacheIfEnabled(host.settings, options);
}

export interface HostSceneSource {
  readonly scenes?: readonly HomeScene[] | null;
}

const singleAccountSceneSnapshots = new WeakMap<MenuMijiaWindowsApp, { sourceRevision: number; snapshot: MiSceneSnapshot }>();

/**
 * Every scene the host currently knows about, deduplicated by id (first source wins).
 */
export function collectHostKnownScenes(
  host: DualSourceInspectableHost & HostSceneSource & { readonly multiAccountState?: HostMultiAccountState | null; readonly dualSourceCoordinator?: DualSourceCoordinator | null },
): readonly HomeScene[] {
  const seen = new Set<string>();
  const out: HomeScene[] = [];
  const push = (list: readonly HomeScene[] | null | undefined): void => {
    for (const scene of list ?? []) {
      if (!scene || seen.has(scene.id)) continue;
      seen.add(scene.id);
      out.push(scene);
    }
  };
  push(host.scenes);
  push(host.multiAccountState?.merged?.home?.scenes);
  for (const child of Object.values(host.multiAccountState?.children ?? {})) push(child?.home?.scenes);
  if (isDualSourceEnabled(host)) push(host.dualSourceCoordinator?.getLastMiSnapshot?.()?.home?.scenes);
  return out;
}

export function buildHostCapabilityContext(
  host: MiSelectionHost & { readonly devices?: readonly SmartDevice[]; readonly unprunedCameraDevices?: readonly SmartDevice[]; readonly multiAccountState?: HostMultiAccountState | null; readonly dualSourceCoordinator?: DualSourceCoordinator | null; readonly hiddenMiDevices?: readonly CapabilityIndexedDevice[]; readonly miTypeSafetySignals?: Readonly<Record<string, readonly SafetySignalKind[]>>; readonly haTypePruneScope?: string | null; readonly hiddenHADevices?: readonly CapabilityIndexedDevice[]; readonly haTypeSafetySignals?: Readonly<Record<string, readonly SafetySignalKind[]>>; readonly settings: DualSourceInspectableHost["settings"] & { readonly allOffOverrides?: Readonly<Record<string, boolean>> } } & HostSceneSource,
  accountsOverride?: readonly MiAccount[],
): HostCapabilityContextInput {
  const accounts = hostKnownMiAccounts(host, accountsOverride);
  const state = resolveHostMiSelectionState(host, accounts), dualEnabled = isDualSourceEnabled(host);
  const dualRoutes = dualEnabled ? host.dualSourceCoordinator?.getLastMerged?.()?.routes : undefined;
  const hidden = hiddenTypeDevices(host);
  const haSignals = haTypePruneSnapshotIsCurrent(host) ? host.haTypeSafetySignals ?? {} : {};
  const miSignals = host.settings.connectionMode === "xiaomiCloud" || dualEnabled ? host.miTypeSafetySignals ?? {} : {};
  const signals: Record<string, readonly SafetySignalKind[]> = Object.create(null);
  const getSignals = (id: string, isHA: boolean) => {
    const byId = isHA ? haSignals : miSignals;
    return Object.hasOwn(byId, id) ? byId[id] : undefined;
  };
  for (const device of host.devices ?? []) {
    const route = dualRoutes?.[device.id];
    if (route) {
      const winnerIsHA = route.backend === "homeAssistant";
      const winner = getSignals(route.sourceDeviceId, winnerIsHA);
      const alternate = route.alternateDevice;
      const other = alternate && deviceCategoryForDevice(alternate) === deviceCategoryForDevice(device)
        ? getSignals(alternate.id, !winnerIsHA) : undefined;
      if (winner || other) signals[device.id] = [...new Set([...(winner ?? []), ...(other ?? [])])];
    } else {
      const own = getSignals(device.id, device.sourceBackend === "homeAssistant" || host.settings.connectionMode === "homeAssistant");
      if (own) signals[device.id] = own;
    }
  }
  const context: HostCapabilityContextInput = {
    state, accounts, devices: host.devices ?? [], scenes: collectHostKnownScenes(host),
    ...(hidden.length ? { hiddenDevices: hidden } : {}),
    ...(Object.keys(signals).length ? { safetySignalsByDeviceId: signals } : {}),
    ...(host.multiAccountState?.merged?.deviceOwners ? { deviceOwners: host.multiAccountState.merged.deviceOwners } : {}),
    ...(dualRoutes ? { dualRoutes } : {}),
    haBaseURL: host.settings.haBaseURL ?? "", haToken: host.settings.haToken ?? "",
    connectionMode: (host.settings.connectionMode as HomeBackend | undefined) ?? "demo",
    dualSourceEnabled: dualEnabled, ...(host.settings.allOffOverrides ? { allOffOverrides: host.settings.allOffOverrides } : {}),
  };
  const cameras = host.unprunedCameraDevices ?? [];
  if (cameras.length === 0) return context;
  const { indexedDevices } = buildIndexedCapabilityDevices({ ...context, devices: cameras, hiddenDevices: [] });
  const cameraIds = new Set(cameras.map((device) => device.id));
  return { ...context, hiddenDevices: [...hidden, ...indexedDevices.filter((device) => cameraIds.has(device.id))] };
}

function completePendingMiRevalidation(
  host: MenuMijiaWindowsApp,
  syncedAccountIds: readonly string[],
  accountsOverride?: readonly MiAccount[],
): boolean {
  if (syncedAccountIds.length === 0) return false;
  const state = resolveHostMiSelectionState(host, accountsOverride);
  const matchedScopes = new Set(
    syncedAccountIds.map(miAccountScope).filter((s) => state.pendingRevalidationAccountIds.has(s)),
  );
  if (matchedScopes.size === 0) return false;
  const nowMs = (host as { pendingReenableNowMs?: number }).pendingReenableNowMs;
  return revalidateAfterMiAccountReenable({
    context: buildHostCapabilityContext(host, accountsOverride),
    scheduledCommandStore: host.scheduledCommandStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore: new AutomationRuleStore(),
    completedScopes: matchedScopes,
    ...(nowMs !== undefined ? { nowMs } : {}),
  });
}

function completePendingHaRevalidation(
  host: MenuMijiaWindowsApp,
  endpoint: string,
  token: string,
  accountsOverride?: readonly MiAccount[],
): boolean {
  const scope = haConnectionScope(endpoint, token);
  if (!scope) return false;
  const state = resolveHostMiSelectionState(host, accountsOverride);
  if (!state.pendingRevalidationHaScopes.has(scope)) return false;
  const nowMs = (host as { pendingReenableNowMs?: number }).pendingReenableNowMs;
  return revalidateAfterMiAccountReenable({
    context: buildHostCapabilityContext(host, accountsOverride),
    scheduledCommandStore: host.scheduledCommandStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore: new AutomationRuleStore(),
    completedHaScopes: new Set([scope]),
    hasLiveHaSnapshot: true,
    ...(nowMs !== undefined ? { nowMs } : {}),
  });
}

export function foldGrouped(host: MenuMijiaWindowsApp, devices: readonly SmartDevice[]): SmartDevice[] {
    return host.settings.hideGroupedLights
      ? foldGroupedLights(devices, host.groupOwnerByMemberDid)
      : [...devices];
  }

export async function refreshDevices(host: MenuMijiaWindowsApp, silent = false): Promise<void> {
    if (!isHostAttachedToActiveWindow(host)) return;
    if (isDualSourceEnabled(host)) return refreshDualSourceDevices(host, silent);
    if (host.settings.connectionMode === "homeAssistant") return refreshHADevices(host, silent);
    if (host.settings.connectionMode === "xiaomiCloud") {
      // The store's first load of this window enumerates the credential slots; later loads read
      // the assembled list. This replaces the old "only multi-account indexes hydrate" gate (#228).
      const storeToken = host.sourceEpoch.capture();
      const store = getHostMiAccountsStore(host);
      const storeAccounts = host.miAccountsOverride ?? (await store.load().catch(() => []));
      if ((await storeToken.guard(adoptRecoveredPrimarySession(host, store, storeAccounts))) === STALE) return;
      // A host whose every Mi account is turned off or signed out must not keep evaluating the alert
      // signals it left behind. A multi-account host with any enabled account keeps its snapshot:
      // its own refresh rewrites the per-account retained set, so clearing here would drop the
      // sibling accounts' sensors until that refresh returns (P3a-W). The verdict needs the loaded
      // list: judging it before `store.load()` would clear a multi-account host's snapshot.
      const knownAccounts = hostKnownMiAccounts(host, storeAccounts);
      if (knownAccounts.length > 0 && resolveEnabledMiAccountsForHost(host, storeAccounts).length === 0) {
        applyMiotTypePruneSnapshot(host, null);
      }
      if (storeAccounts.length > 1 || hasMultipleMiAccountsForHost(host)) {
        return refreshMultiAccountXiaomiDevices(host, silent);
      }
    }
    if (
      !host.settings.miSession ||
      host.settings.connectionMode !== "xiaomiCloud" ||
      host.isSyncingCloud ||
      !isHostMiSessionEnabled(host, host.settings.miSession)
    ) {
      return;
    }
    const session = host.settings.miSession;
    const currentFingerprint = miSessionFingerprint(session);
    const previousFingerprint = host.lastSessionFingerprint ?? undefined;
    host.lastSessionFingerprint = currentFingerprint;
    const isInitialStartupCheck = !host.initialSessionCheckDone;
    host.initialSessionCheckDone = true;
    const expiredBefore = host.miSessionExpired;
    const persistedExpired = isPersistedMiSessionExpired(session);
    if (previousFingerprint !== undefined && previousFingerprint !== currentFingerprint && !persistedExpired) {
      host.miSessionExpired = false;
    } else if (persistedExpired && !host.miSessionExpired) {
      host.miSessionExpired = true;
    }
    if (silent && host.miSessionExpired) {
      if (!expiredBefore && isHostAttachedToActiveWindow(host)) {
        host.queueBackgroundRender();
      }
      return;
    }
    if (!silent && isInitialStartupCheck && !host.isPollingQR && persistedExpired) {
      host.render();
      return;
    }
    const refreshStartedAt = Date.now();
    if (silent && shouldSkipSilentPollForBackoff(host, session, refreshStartedAt)) {
      return;
    }
    if (silent && typeof window !== "undefined" && window.__TAURI_INTERNALS__?.invoke) {
      if (host.lockProbeInFlight) return;
      host.lockProbeInFlight = true;
      let locked = false;
      try {
        locked = await isWorkstationLocked();
      } finally {
        host.lockProbeInFlight = false;
      }
      if (locked) {
        host.lastCloudRefreshAt = null;
        return;
      }
      if (
        !isHostAttachedToActiveWindow(host) ||
        host.settings.connectionMode !== "xiaomiCloud" ||
        host.settings.miSession !== session ||
        host.isSyncingCloud
      ) {
        return;
      }
    }
    const normalizedRegion = normalizeMiCloudRegion(session.region);
    const previousPresentation = cloudPresentationFingerprint(host);
    const previousStructure = cloudPanelStructureFingerprint(host);
    const staleBefore = host.cloudValuesStale;
    // Device-type pruning inputs for this round (P3a-W). One plan feeds the early paint, the cloud
    // read batch and the final synthesis, so a turned-off type costs no reads anywhere.
    const pruneOptions = hostMiotTypePruneOptions(host);
    const accountId = miAccountId(session);
    const scope = miAccountScope(accountId);
    const prunePlanFor = (records: readonly MiDeviceRecord[], planSpecs: Readonly<Record<string, MiotDeviceSpec>>) =>
      buildMiotTypePrunePlan({
        rawDevices: records,
        specs: planSpecs,
        selection: pruneOptions.selection,
        connectionScope: scope,
        safetySignals: pruneOptions.safetySignals,
        starredDeviceIds: pruneOptions.starredDeviceIds,
      });
    const stateToken = host.sourceEpoch.capture();
    const selectedHomeAtStart = host.settings.selectedHomeId;
    const sourceRevisionAtStart = host.sourceRevision;
    const syncRun = host.sourceEpoch.claimSyncRun();
    let presentationChanged = false;
    host.isSyncingCloud = true;
    host.lastCloudRefreshAt = refreshStartedAt;
    if (!silent) {
      host.render();
    }

    try {
      const client = new MiCloudClient(session, host.transport);
      // A closed `light` type draws no group card, so its membership query is a wasted request per
      // group (P2-10). The scope is this round's own, so the same fail-closed rule as the read plan.
      const skipLightGroupMembers = miotRoundClosesCategory(pruneOptions.selection, scope, "light");
      const cachedTopology = takeCachedXiaomiTopologyForPoll(
        host,
        session,
        sourceRevisionAtStart,
        selectedHomeAtStart ?? null,
        silent,
        !skipLightGroupMembers,
      );

      const previousSceneEntry = singleAccountSceneSnapshots.get(host);
      let sceneSnapshot = previousSceneEntry?.sourceRevision === sourceRevisionAtStart
        ? previousSceneEntry.snapshot : undefined;
      let rawDevices: readonly MiDeviceRecord[];
      let rooms: readonly MiRoom[];
      let specs: Readonly<Record<string, MiotDeviceSpec>>;
      let membersByGroup: ReadonlyMap<string, readonly string[]>;
      let allDevicesForCache: readonly MiDeviceRecord[] | null = null;
      let allRoomsForCache: readonly MiRoom[] | null = null;

      if (cachedTopology) {
        rawDevices = cachedTopology.rawDevices;
        rooms = cachedTopology.rooms;
        specs = cachedTopology.specs;
        membersByGroup = cachedTopology.membersByGroup;
      } else {
        const discovery = await discoverMiHome(client, {
          unresolvedDids: host.unresolvedRoomDids,
          retryUnresolved: !silent,
          cachedRooms: () => {
            const cached = host.lastGoodXiaomiRooms;
            return cached &&
              cached.sourceRevision === host.sourceRevision &&
              cached.userId === session.userId &&
              cached.region === normalizedRegion
              ? cached.rooms
              : null;
          },
          onRoomsRead: (fetchedRooms) => {
            if (!isHostMiSessionEnabled(host, session)) return;
            host.lastGoodXiaomiRooms = {
              sourceRevision: host.sourceRevision,
              userId: session.userId,
              region: normalizedRegion,
              rooms: fetchedRooms,
            };
          },
        });
        const homeRoomsError = discovery.roomsError;
        const allRooms = discovery.rooms;
        const allDevices = discovery.devices;
        const nextHomes = homeOptions(allRooms);
        if (cloudSnapshotIsStale(host, session, stateToken, syncRun, selectedHomeAtStart)) return;
        if (homeRoomsError === null || nextHomes.length > 0) {
          host.homes = applyOrder(host.homes.map((home) => home.id), nextHomes);
        }
        const filtered = filterBySelectedHome(host, allDevices, allRooms);
        rawDevices = filtered.devices;
        rooms = filtered.rooms;
        allDevicesForCache = allDevices;
        allRoomsForCache = allRooms;
        const groupDids = rawDevices.map((device) => device.did).filter((did) => did.startsWith("group."));
        // Skipped while `light` is off: no group card is drawn, so the membership read is waste.
        const membershipPromise = groupDids.length > 0 && !skipLightGroupMembers
          ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
          : Promise.resolve(new Map<string, string[]>());

        const stage1Specs = host.specResolver.exportCachedSpecs();
        const stage1Home = MiotSynthesizer.synthesize(
          prunePlanFor(rawDevices, stage1Specs).visibleRecords,
          rooms,
          stage1Specs,
          new Map<string, unknown>(),
        );
        if (stage1Home.devices.length > 0 && host.devices.length === 0) {
          host.devices = stage1Home.devices;
          host.deviceFacets = stage1Home.deviceFacets ?? {};
          presentationChanged = true;
          host.render();
        }

        if (homeRoomsError === null) {
          sceneSnapshot = await refreshMiScenes(client, allRooms, session.userId, sceneSnapshot, Date.now());
        }
        specs = await host.specResolver.resolveForDevices(rawDevices);
        membersByGroup = await membershipPromise;
        if (cloudSnapshotIsStale(host, session, stateToken, syncRun, selectedHomeAtStart)) return;
      }

      // Card properties plus the 更多设置 rows (#5), deduped so one snapshot covers both, and minus
      // the keys of a turned-off device type that no consumer reads any more (architecture.md §D).
      const prunePlan = prunePlanFor(rawDevices, specs);
      const propKeys = prunePlan.readKeys;

      let values: Map<string, unknown>;
      try {
        values =
          propKeys.length > 0
            ? await client.getProps(propKeys)
            : new Map<string, unknown>();
      } catch (error) {
        if (!cloudSnapshotIsStale(host, session, stateToken, syncRun, selectedHomeAtStart)) {
          host.markCloudValuesStale();
        }
        throw error;
      }

      const home = MiotSynthesizer.synthesize(prunePlan.visibleRecords, rooms, specs, values);
      // A closed category still evaluates its enabled alerts, but only as the minimal shape those
      // alerts read; these devices never join `host.devices`, so no card or control can reach them.
      const safetyHome = prunePlan.safetyRecords.length > 0
        ? MiotSynthesizer.synthesize(prunePlan.safetyRecords, rooms, specs, values)
        : null;
      if (cloudSnapshotIsStale(host, session, stateToken, syncRun, selectedHomeAtStart)) return;
      if (allDevicesForCache !== null && allRoomsForCache !== null) {
        storeCachedXiaomiTopology(host, {
          sessionFingerprint: miSessionFingerprint(session),
          sourceRevision: sourceRevisionAtStart,
          selectedHomeId: selectedHomeAtStart ?? null,
          allDevices: allDevicesForCache,
          allRooms: allRoomsForCache,
          rawDevices,
          rooms,
          specs,
          membersByGroup,
          ...(skipLightGroupMembers ? { skippedLightGroupMembers: true } : {}),
        });
      }
      clearXiaomiRateLimitBackoff(host);
      // The setter clears only this session's own rejection key, so other accounts' records survive.
      host.miSessionExpired = false;
      host.lastMiCloudSyncFailed = false;
      host.markCloudValuesFresh();
      if (sceneSnapshot) {
        singleAccountSceneSnapshots.set(host, { sourceRevision: sourceRevisionAtStart, snapshot: sceneSnapshot });
      }
      const fetchedScenes = miSceneRows(sceneSnapshot, rooms, accountId);
      const retainedScenes = host.scenes.filter((scene) => scene.sourceBackend === "xiaomiCloud" || scene.accountId !== undefined || !scene.id.startsWith("scene."));
      host.scenes = [...fetchedScenes, ...retainedScenes.filter((scene) => !fetchedScenes.some((fresh) => fresh.id === scene.id))];
      host.groupOwnerByMemberDid = memberGroupOwners(membersByGroup as Map<string, string[]>);
      const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
      host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
      host.deviceFacets = merged.deviceFacets;
      if (
        host.cameraLive.activeLiveCameraId !== null &&
        !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
      ) {
        host.cameraLive.closeCameraLiveView();
      }
      const readingPriorityById = new Map(
        home.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      host.environmentReadings = applyOrder(
        host.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      presentationChanged =
        presentationChanged || cloudPresentationFingerprint(host) !== previousPresentation;

      applyMiotTypePruneSnapshot(host, {
        // Stamp the owning account like `stampAccountSnapshot` does, so disabling or signing this
        // account out drops exactly its retained sensors (`dropMiotTypePruneSnapshotForAccount`).
        safetyDevices: safetyHome?.devices.map((device) => ({ ...device, accountId })),
        safetyDeviceFacets: safetyHome?.deviceFacets,
        hiddenDevices: prunePlan.hiddenIndexedDevices.filter((device) => device.sourceScope === scope),
        safetySignalsByDeviceId: prunePlan.safetySignalsByDeviceId,
      });
      markTimerSnapshotReady(host);
      if (completePendingMiRevalidation(host, [miAccountId(session)])) {
        presentationChanged = true;
      }
      host.settings.cachedXiaomiDevices = host.devices;
      const knownModelTypes = host.specResolver.exportKnownModelTypes(
        rawDevices.map((d) => d.model),
      );
      const cacheChanged =
        JSON.stringify(knownModelTypes) !== JSON.stringify(host.settings.cachedModelTypes);
      host.settings.cachedModelTypes = knownModelTypes;
      if (presentationChanged || cacheChanged) {
        host.saveSettings();
      }

      if (!silent) {
        host.replyBanner = {
          text:
            home.devices.length > 0
              ? t("已同步 {count} 台真实米家设备", { count: home.devices.length })
              : t("当前小米账号下暂未发现米家设备"),
          source: t("米家云直连"),
        };
      }
    } catch (err) {
      if (!cloudSnapshotIsStale(host, session, stateToken, syncRun, selectedHomeAtStart)) {
        host.lastMiCloudSyncFailed = true;
        host.markCloudValuesStale();
        appDiagnosticsLog.record({
          error: err,
          category:
            err instanceof MiCloudError && err.kind === "sessionExpired"
              ? "auth"
              : isXiaomiRateLimitError(err)
                ? "rateLimit"
                : "miCloud",
          statusCode: err instanceof MiCloudError ? (err.code ?? null) : null,
          forbiddenLiterals: [session.userId, session.cUserId, session.serviceToken, session.ssecurity],
        });
        if (err instanceof MiCloudError && err.kind === "sessionExpired") {
          // A refused Xiaomi serviceToken cannot refresh itself: no retry here, and silent polls
          // stay off until a new scan changes the fingerprint (#6).
          host.miSessionExpired = true;
          persistMiSessionExpired(session, true);
          clearCachedXiaomiTopology(host);
        } else if (isXiaomiRateLimitError(err)) {
          recordXiaomiRateLimit(host, session, Date.now());
        }
      }
      if (!silent) {
        const msg = err instanceof Error ? err.message : String(err);
        host.replyBanner = {
          text: t("米家云同步失败：{message}", { message: msg }),
          source: t("连接异常"),
          isError: true,
        };
      }
    } finally {
      if (syncRun.isCurrent()) {
        host.isSyncingCloud = false;
        if (isHostAttachedToActiveWindow(host)) {
          const staleChanged = staleBefore !== host.cloudValuesStale;
          const expiredChanged = expiredBefore !== host.miSessionExpired;
          if (!silent) {
            host.render();
          } else if (staleChanged || expiredChanged) {
            host.queueBackgroundRender();
          } else if (presentationChanged) {
            if (
              cloudPanelStructureFingerprint(host) !== previousStructure ||
              !patchCloudPresentation(host)
            ) {
              host.queueBackgroundRender();
            }
          }
        }
      }
    }
  }

export async function refreshHADevices(host: MenuMijiaWindowsApp, silent = false): Promise<void> {
    if (
      !isHostAttachedToActiveWindow(host) ||
      host.settings.connectionMode !== "homeAssistant" ||
      host.isSyncingCloud ||
      !isHostHaEnabled(host) ||
      getHostHaLifecyclePhase(host) !== "enabled"
    ) {
      return;
    }
    const endpoint = host.settings.haBaseURL;
    const token = host.settings.haToken;
    const stateToken = host.sourceEpoch.capture();
    const syncRun = host.sourceEpoch.claimSyncRun();
    const previousPresentation = cloudPresentationFingerprint(host);
    const previousStructure = cloudPanelStructureFingerprint(host);
    let failed = false;
    let shouldUpdateView = false;
    host.isSyncingCloud = true;
    host.lastCloudRefreshAt = Date.now();
    if (!silent && host.devices.length === 0) host.render();
    try {
      await host.endpointSubmission;
      if (
        !isHostAttachedToActiveWindow(host) ||
        host.settings.connectionMode !== "homeAssistant" ||
        host.settings.haBaseURL !== endpoint ||
        host.settings.haToken !== token ||
        !isHostHaEnabled(host) ||
        getHostHaLifecyclePhase(host) !== "enabled" ||
        !stateToken.isCurrent() ||
        !syncRun.isCurrent()
      ) {
        return;
      }
      const haClient = new HomeAssistantClient(endpoint, token, host.haInvokeOverride ?? undefined);
      const prune = hostHaTypePruneOptions(host);
      const synthesized = await haClient.snapshotWithPrune(prune);
      const home = synthesized.home;
      const identity = homeAssistantIdentity(endpoint, token);
      if (!identity) throw new Error("Invalid Home Assistant URL");
      if (
        !isHostAttachedToActiveWindow(host) ||
        host.settings.connectionMode !== "homeAssistant" ||
        host.settings.haBaseURL !== endpoint ||
        host.settings.haToken !== token ||
        !isHostHaEnabled(host) ||
        getHostHaLifecyclePhase(host) !== "enabled" ||
        !stateToken.isCurrent() ||
        !syncRun.isCurrent()
      ) {
        return;
      }
      const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
      host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
      host.deviceFacets = merged.deviceFacets;
      applyMiotTypePruneSnapshot(host, null);
      // A closed type contributes nothing to the panel, search, the AI directory, the companion
      // export or a control entry; only its enabled alerts still read it (architecture.md §D).
      // An unpruned round still records each card's signals, so the device-type preview can say
      // which cards closing a type would keep reading.
      applyHaTypePruneSnapshot(host, prune === null
        ? null
        : {
            scope: prune.connectionScope,
            safetyDevices: synthesized.safetyDevices,
            ...(synthesized.safetyDeviceFacets ? { safetyDeviceFacets: synthesized.safetyDeviceFacets } : {}),
            hiddenDevices: synthesized.hiddenIndexedDevices,
            safetySignalsByDeviceId: synthesized.safetySignalsByDeviceId,
          });
      host.scenes = [...home.scenes];
      if (haClient.lastRawSnapshot && typeof haClient.lastRawSnapshot === "object") {
        void ingestHostHASnapshotForDoorbell(host, haClient.lastRawSnapshot as HASnapshotLike);
      }
      if (
        host.cameraLive.activeLiveCameraId !== null &&
        !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
      ) {
        host.cameraLive.closeCameraLiveView();
      }
      markTimerSnapshotReady(host);
      completePendingHaRevalidation(host, endpoint, token);
      const readingPriorityById = new Map(
        host.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      host.environmentReadings = applyOrder(
        host.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      const hadValidCache = host.settings.cachedHAHome?.identity === identity;
      const presentationChanged =
        cloudPresentationFingerprint(host) !== previousPresentation || host.haConnectionError !== null;
      const cachedHome = {
        devices: host.devices,
        rooms: home.rooms,
        environmentReadings: host.environmentReadings,
        scenes: home.scenes,
        ...(Object.keys(host.deviceFacets).length > 0 ? { deviceFacets: host.deviceFacets } : {}),
      };
      host.settings.cachedHAHome = { identity, home: cachedHome };
      if (host.haConnectionError !== null) failed = true;
      host.haConnectionError = null;
      if (presentationChanged || !hadValidCache) host.saveSettings();
      shouldUpdateView = !silent || presentationChanged;
    } catch (error) {
      if (
        isHaBlockedRequestError(error) ||
        !isHostAttachedToActiveWindow(host) ||
        host.settings.connectionMode !== "homeAssistant" ||
        host.settings.haBaseURL !== endpoint ||
        host.settings.haToken !== token ||
        !isHostHaEnabled(host) ||
        getHostHaLifecyclePhase(host) !== "enabled" ||
        !stateToken.isCurrent() ||
        !syncRun.isCurrent()
      ) {
        return;
      }
      failed = true;
      shouldUpdateView = true;
      appDiagnosticsLog.record({
        error,
        category: "homeAssistant",
        forbiddenLiterals: [endpoint, token],
      });
      host.haConnectionError = error instanceof Error ? error.message : String(error);
    } finally {
      if (syncRun.isCurrent()) {
        host.isSyncingCloud = false;
        if (shouldUpdateView && isHostAttachedToActiveWindow(host)) {
          if (failed || host.devices.length === 0 || cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)) host.queueBackgroundRender();
        }
      }
    }
  }

  export function cloudPresentationFingerprint(host: MenuMijiaWindowsApp): string {
    return JSON.stringify({
      homes: host.homes,
      devices: host.devices,
      deviceFacets: host.deviceFacets,
      scenes: host.scenes,
      environmentReadings: host.environmentReadings,
      groupOwners: [...host.groupOwnerByMemberDid],
    });
  }

export function cloudSnapshotIsStale(
  host: MenuMijiaWindowsApp,
  session: MiSession,
  stateToken: EpochToken,
  syncRun?: SyncRunToken,
  selectedHomeId?: string | null,
): boolean {
    return (
      !isHostAttachedToActiveWindow(host) ||
      host.settings.connectionMode !== "xiaomiCloud" ||
      host.settings.miSession !== session ||
      !isHostMiSessionEnabled(host, session) ||
      !stateToken.isCurrent() ||
      (syncRun !== undefined && !syncRun.isCurrent()) ||
      (selectedHomeId !== undefined && host.settings.selectedHomeId !== selectedHomeId)
    );
  }

export function cloudPanelStructureFingerprint(host: MenuMijiaWindowsApp): string {
    const kindChipsForPanel = kindChips(
      host.devices,
      host.listCut,
      host.settings.hideOfflineDevices,
      { layout: host.layout },
    );
    const quickActions =
      host.settings.showQuickActionsBar && host.settings.connectionMode !== "demo"
        ? availableQuickActions(foldGrouped(host, filterByListCut(host.devices, host.listCut, false, { layout: host.layout }))).map(
            (action) => action.id,
          )
        : null;
    return JSON.stringify({
      homes: host.homes,
      scenes: host.scenes,
      quickActions,
      kindChips: kindChipsForPanel,
      kindRowVisible: showsKindRow(kindChipsForPanel, host.listCut),
      groupOwners: [...host.groupOwnerByMemberDid],
      sensorHistory: structuralSensorHistoryKey(host),
      activityStack: structuralActivityStackKey(host),
      allOffTargets: host.settings.connectionMode === "homeAssistant" ? null : host.allOffTargets.map((device) => device.id),
      devices: host.devices.map((device) => {
        const kind = device.kind;
        const capabilities =
          kind.kind === "light"
            ? [
                kind.availableEffects,
                [...getUnsupportedLightEffects(host, device.id)],
                kind.minKelvin,
                kind.maxKelvin,
                kind.powerWritable !== false,
                kind.brightnessWritable !== false,
                kind.colorWritable !== false,
              ]
            : kind.kind === "climate"
              ? [kind.availableModes, kind.availableFanModes, kind.minTemp, kind.maxTemp, kind.step]
              : kind.kind === "fan"
                ? [kind.availablePresetModes]
                : kind.kind === "vacuum"
                  ? [kind.availableModes]
                  : kind.kind === "camera"
                    ? [kind.availableNightShots, kind.motionDetectionEntityId]
                    : kind.kind === "cover"
                      ? [
                          kind.subtype,
                          kind.positionWritable,
                          kind.openDescription,
                          kind.closeDescription,
                          kind.pauseDescription,
                        ]
                      : kind.kind === "appliance"
                        ? [
                            kind.powerPresent,
                            kind.powerWritable,
                            kind.availableModes,
                            kind.modeWritable,
                            kind.temperatureWritable,
                            kind.minTemp,
                            kind.maxTemp,
                            kind.step,
                            kind.symbolName,
                            kind.heats,
                          ]
                        : kind.kind === "speaker"
                          ? [
                              kind.volumeWritable,
                              kind.muteSwitchEntityId,
                              kind.sleepModeEntityId,
                              kind.ttsActionId,
                              kind.directiveActionId,
                            ]
                          : kind.kind === "tv"
                            ? [kind.volumeWritable, kind.volumePresent, kind.muteSwitchEntityId, kind.availableSources, kind.turnOnButtonId, kind.powerWritable]
                            : kind.kind === "humidifier"
                              ? [kind.powerWritable, kind.humidityWritable, kind.minHumidity, kind.maxHumidity, kind.step, kind.availableModes, kind.modeWritable]
                              : kind.kind === "plug"
                            ? (() => {
                                const hasEnergy =
                                  kind.energyKwh !== null &&
                                  kind.energyKwh !== undefined &&
                                  Number.isFinite(kind.energyKwh);
                                const todaySummary = plugTodaySummaryForDrawer(device, hasEnergy, energyScopeForHost(host));
                                return [
                                  hasEnergy,
                                  todaySummary !== null,
                                  todaySummary?.costText !== null,
                                ];
                              })()
                            : [];
        const facetIds = (host.deviceFacets[device.id] ?? []).map((facet) => [
          facet.id,
          facet.kind,
          facet.isWritable,
        ]);
        return {
          id: device.id,
          name: device.name,
          roomId: device.roomId,
          roomName: device.roomName,
          model: device.model,
          isOnline: device.isOnline,
          category: kind.kind,
          capabilities,
          ...(facetIds.length > 0 ? { facetIds } : {}),
          sensorShape:
            kind.kind === "sensor"
              ? [kind.temperature !== null, kind.humidity !== null, kind.battery !== null]
              : null,
        };
      }),
    });
  }

export function patchCloudPresentation(host: MenuMijiaWindowsApp): boolean {
    if (
      host.isEditingLayout ||
      host.activeSheet !== "none" ||
      host.pointerIsDown ||
      host.draggingId !== null ||
      host.isRoomBrowseMenuOpen ||
      Boolean(normalizeSearch(host.panelSearch.query))
    ) {
      return false;
    }
    syncSensorHistoryHost(host);
    syncEnergyHostOnRender(host);

    const gridModel = buildPanelDeviceGridModel(host);
    const desiredHeaders = gridModel.onlineSections.filter((section) => section.title !== null);
    const domHeaders = Array.from(host.root.querySelectorAll<HTMLElement>(".cc-group-header"));
    if (domHeaders.length !== desiredHeaders.length) return false;
    for (const section of desiredHeaders) {
      const header = domHeaders.find((element) => element.dataset.collapse === section.id);
      const count = header?.querySelector(".cc-group-count")?.textContent ?? "";
      if (!header || count !== String(section.devices.length)) return false;
    }

    const domLongTailBar = host.root.querySelector<HTMLElement>("[data-long-tail-bar]");
    if (Boolean(domLongTailBar) !== gridModel.showsLongTailBar) return false;

    const domOfflineDrawer = host.root.querySelector<HTMLElement>("[data-offline-drawer]");
    const wantsOfflineDrawer = gridModel.offlineDevices.length > 0;
    if (Boolean(domOfflineDrawer) !== wantsOfflineDrawer) return false;
    const domUnsupportedRow = host.root.querySelector<HTMLElement>("[data-unsupported-devices-row]");
    const cachedUnsupportedCount = getCachedUnsupportedDeviceCountOnHost(host);
    const wantsUnsupportedRow = cachedUnsupportedCount > 0;
    if (Boolean(domUnsupportedRow) !== wantsUnsupportedRow) return false;
    if (domUnsupportedRow && domUnsupportedRow.dataset.unsupportedCount !== String(cachedUnsupportedCount)) {
      return false;
    }
    if (wantsOfflineDrawer) {
      const domOfflineToggle = domOfflineDrawer?.querySelector<HTMLElement>("[data-offline-drawer-toggle]");
      if (
        !domOfflineToggle ||
        domOfflineToggle.getAttribute("aria-expanded") !== String(gridModel.isOfflineDrawerExpanded)
      ) {
        return false;
      }
    }

    const domTileElements = Array.from(
      host.root.querySelectorAll<HTMLElement>("[data-tile-id]:not([data-exit-ghost])"),
    );
    const desiredRenders: Array<{ device: SmartDevice; span: number; index: number }> = [];
    let index = 0;
    for (const section of gridModel.onlineSections) {
      const hasActiveSubpage =
        host.expandedDeviceId !== null && section.devices.some((device) => device.id === host.expandedDeviceId);
      if (host.layout.collapsed.includes(scopedKey(host.pageKey, section.id)) && !hasActiveSubpage) continue;
      const spanMap = spans(
        section.devices,
        (device) => (host.expandedDeviceId === device.id ? "full" : host.tileSize(device)),
      );
      for (const device of section.devices) {
        desiredRenders.push({
          device,
          span: spanMap.get(device.id) ?? 6,
          index: index++,
        });
      }
    }
    if (gridModel.isOfflineDrawerExpanded && gridModel.offlineDevices.length > 0) {
      const offlineSpanMap = spans(gridModel.offlineDevices, (device) => host.tileSize(device));
      for (const device of gridModel.offlineDevices) {
        desiredRenders.push({
          device,
          span: offlineSpanMap.get(device.id) ?? 6,
          index: index++,
        });
      }
    }

    if (domTileElements.length !== desiredRenders.length) return false;
    const tilePatches: Array<{ current: HTMLElement; desired: Element }> = [];
    for (let i = 0; i < desiredRenders.length; i += 1) {
      const entry = desiredRenders[i]!;
      const current = domTileElements[i]!;
      if ((current.dataset.tileId ?? "") !== entry.device.id) return false;
      const desired = parseSingleElement(
        host.renderDeviceTile(entry.device, entry.span, entry.index),
      );
      if (!desired || !hasMatchingDomShape(current, desired)) return false;
      tilePatches.push({ current, desired });
    }
    for (const patch of tilePatches) morphMatchingDom(patch.current, patch.desired);

    if (domLongTailBar && gridModel.showsLongTailBar) {
      const desiredLongTail = parseSingleElement(
        renderLongTailBarHtml(gridModel, host.isRoomBrowseMenuOpen, (v) => host.escapeHtml(v)),
      );
      if (desiredLongTail && hasMatchingDomShape(domLongTailBar, desiredLongTail)) {
        morphMatchingDom(domLongTailBar, desiredLongTail);
      }
    }
    if (domOfflineDrawer && wantsOfflineDrawer) {
      const domOfflineBadge = domOfflineDrawer.querySelector<HTMLElement>(".cc-offline-drawer-badge");
      const domOfflineSummary = domOfflineDrawer.querySelector<HTMLElement>(".cc-offline-drawer-summary");
      if (domOfflineSummary && !gridModel.isOfflineDrawerExpanded) {
        domOfflineSummary.textContent = gridModel.offlineSummary;
      }
      if (domOfflineBadge) {
        domOfflineBadge.textContent = tr3(
          `${gridModel.offlineDevices.length} 台`,
          `${gridModel.offlineDevices.length} 台`,
          `${gridModel.offlineDevices.length}`,
        );
      }
    }
    if (host.settings.connectionMode === "homeAssistant") {
      const isClassic = getPanelThemeProfile(host.settings.panelTheme).shellLayout === "unifiedPopover";
      const current = host.root.querySelector<HTMLElement>("#btn-all-off");
      const desired = parseSingleElement(host.renderAllOffControl(isClassic));
      const helperText = isClassic ? host.allOffHelperText() : "";
      if (current && desired) {
        morphMatchingDom(current, desired);
        if (isClassic) {
          const stack = current.closest(".cc-all-off-stack");
          const caption = stack?.querySelector<HTMLElement>(".cc-all-off-caption");
          if (helperText) {
            if (caption) {
              caption.textContent = helperText;
            } else if (stack) {
              const span = document.createElement("span");
              span.className = "cc-all-off-caption";
              span.textContent = helperText;
              stack.append(span);
            }
          } else {
            caption?.remove();
          }
        }
      } else if (current) {
        const stack = current.closest(".cc-all-off-stack");
        if (stack) stack.remove();
        else current.remove();
      } else if (desired) {
        if (isClassic) {
          const headerControls = host.root.querySelector(".cc-header-controls");
          const stack = document.createElement("div");
          stack.className = "cc-all-off-stack";
          stack.append(desired);
          if (helperText) {
            const span = document.createElement("span");
            span.className = "cc-all-off-caption";
            span.textContent = helperText;
            stack.append(span);
          }
          headerControls?.append(stack);
        } else {
          host.root.querySelector(".cc-footer-status")?.append(desired);
        }
        host.bindAllOffControl();
      }
    }

    const envHTML = host.renderEnvironmentStrip();
    const currentEnv = host.root.querySelector<HTMLElement>(".cc-env-strip");
    if (currentEnv) {
      const desiredEnv = parseSingleElement(envHTML);
      if (!desiredEnv) {
        currentEnv.remove();
      } else if (hasMatchingDomShape(currentEnv, desiredEnv)) {
        morphMatchingDom(currentEnv, desiredEnv);
      } else {
        currentEnv.replaceWith(desiredEnv);
      }
    } else if (envHTML) {
      host.root.querySelector(".cc-header-top")?.insertAdjacentHTML("afterend", envHTML);
    }

    if (!host.root.querySelector(".win-slider-deck:focus-within")) {
      const deckHTML = renderSliderDeck(host);
      const currentDeck = host.root.querySelector<HTMLElement>(".win-slider-deck");
      const desiredDeck = parseSingleElement(deckHTML);
      if (currentDeck && !desiredDeck) {
        currentDeck.remove();
      } else if (currentDeck && desiredDeck) {
        if (hasMatchingDomShape(currentDeck, desiredDeck)) {
          morphMatchingDom(currentDeck, desiredDeck);
        } else {
          currentDeck.replaceWith(desiredDeck);
          host.bindDeckEvents();
        }
      } else if (!currentDeck && desiredDeck) {
        host.root.querySelector(".cc-footer")?.before(desiredDeck);
        host.bindDeckEvents();
      }
    }

    const subtitle = host.root.querySelector<HTMLElement>(".cc-subtitle");
    if (subtitle) {
      subtitle.textContent = host.isEditingLayout
        ? t("拖动卡片排序 · 点右下角圆弧手柄改大小")
        : normalizePanelTheme(host.settings.panelTheme) === "classic"
          ? host.classicStatusSummaryText
          : host.statusSummaryText;
    }
    host.root
      .querySelector<HTMLElement>(".cc-home-badge")
      ?.classList.toggle("is-active", host.activeDeviceCount > 0);
    // The footer (trigger, recovery action, detail card) always re-derives from one owner; a silent refresh must
    // never write an older label back over the plain-language state (#280 review).
    return patchConnectionStatusFooter(host);
  }

  export function filterBySelectedHome<D extends { readonly did: string; readonly splitParentDid?: string | null }, R extends { readonly homeId?: string; readonly dids: readonly string[] }>(
    host: MenuMijiaWindowsApp,
    devices: readonly D[],
    rooms: readonly R[],
  ): { devices: D[]; rooms: R[] } {
    const selected = host.settings.selectedHomeId;
    if (!selected || !host.homes.some((h) => h.id === selected)) return { devices: [...devices], rooms: [...rooms] };
    const homeRooms = rooms.filter((r) => r.homeId === selected);
    const dids = new Set(homeRooms.flatMap((r) => r.dids));
    const kept = devices.filter((d) => dids.has(d.did) || (d.splitParentDid ? dids.has(d.splitParentDid) : false));
    const keptSet = new Set(kept);
    const parents = new Set(kept.map((d) => d.splitParentDid).filter((x): x is string => !!x));
    const withParents = devices.filter((d) => keptSet.has(d) || parents.has(d.did));
    return { devices: withParents, rooms: homeRooms };
  }

export interface HostMultiAccountState {
  readonly accounts: readonly MiAccount[];
  readonly merged: MergedMiAccountsSnapshot | null;
  readonly children: Readonly<Record<string, AccountChildSnapshot>>;
}

export interface MiAccountsConfigurableHost {
  miAccountsStore?: MiAccountsStore | null;
  miAccountsOverride?: readonly MiAccount[] | null;
  readonly credentialVault?: import("../core/secureStore.js").CredentialVault;
}

export function getHostMiAccountsStore(host: MiAccountsConfigurableHost): MiAccountsStore {
  if (!host.miAccountsStore) {
    host.miAccountsStore = new MiAccountsStore(host.credentialVault);
  }
  return host.miAccountsStore;
}

export function setHostMiAccounts(
  host: MiAccountsConfigurableHost,
  accounts: readonly (MiAccount | MiSession)[] | null,
): void {
  if (accounts === null) {
    host.miAccountsOverride = null;
    return;
  }
  host.miAccountsOverride = accounts.map((entry) => ("session" in entry ? entry : makeMiAccount(entry)));
}

export interface DualSourceInspectableHost {
  readonly settings: {
    readonly connectionMode?: "demo" | "homeAssistant" | "xiaomiCloud" | string;
    readonly haBaseURL?: string | null;
    readonly haToken?: string | null;
    readonly miSession?: { readonly userId: string; readonly region: string } | null;
    readonly dualSourceEnabled?: boolean;
  };
  readonly miAccountsOverride?: readonly MiAccount[] | null;
  readonly dualSourceEnabledOverride?: boolean | null;
  readonly multiAccountState?: HostMultiAccountState | null;
  readonly dualSourceCoordinator?: DualSourceCoordinator | null;
}

export function getHostMiAccountsState(host: DualSourceInspectableHost): HostMultiAccountState | null {
  return host.multiAccountState ?? null;
}

export function hasMultipleMiAccountsForHost(host: DualSourceInspectableHost): boolean {
  if (host.miAccountsOverride != null) return host.miAccountsOverride.length > 1;
  if ((host.multiAccountState?.accounts.length ?? 0) > 1) return true;
  // A corrupt index cannot prove there is only one account; `store.load()` must run to rebuild it.
  return hasSecondaryMiAccountsInIndex() || hasCorruptMiAccountIndex();
}

/**
 * Enumeration can promote a recovered secondary account into `mi_session` when no primary
 * credential exists. The settings object must learn that session immediately, otherwise the next
 * settings save persists `miSession: null` and deletes the recovered account's only credential.
 */
export async function adoptRecoveredPrimarySession(
  host: { readonly settings: { miSession: MiSession | null; miCloudRegion: string } },
  store: MiAccountsStore,
  accounts: readonly MiAccount[],
): Promise<void> {
  const primary = accounts[0];
  const adoptionBlocked = (): boolean => hasPendingMiVaultDeletion() || host.settings.miSession !== null;
  if (!primary || adoptionBlocked() || !store.hasConfirmedPrimarySession()) {
    return;
  }
  // The load may have raced a sign-out or another credential write. A confirmed mismatch means the
  // promoted session is gone; an unavailable verification must not cost the just-promoted credential.
  if ((await store.checkPrimarySession(primary.session)) === "stale") return;
  // Revalidate after each await: a sign-out may have started or completed in the meantime.
  if (adoptionBlocked()) return;
  if ((await store.checkPrimarySession(primary.session)) === "stale") return;
  if (adoptionBlocked()) return;
  host.settings.miSession = primary.session;
  host.settings.miCloudRegion = normalizeMiCloudRegion(primary.region);
}

function knownPreferenceIdsForHost(host: MenuMijiaWindowsApp): Set<string> {
  const ids = new Set<string>();
  const layout = host.settings.layout;
  for (const id of layout.pinnedDeviceIds ?? []) ids.add(id);
  for (const id of layout.hiddenDeviceIds ?? []) ids.add(id);
  for (const id of layout.order) ids.add(id);
  for (const id of Object.keys(layout.aliases)) ids.add(id);
  for (const id of Object.keys(layout.groupMap)) ids.add(id);
  for (const key of Object.keys(layout.tileSizes)) {
    const bar = key.indexOf("|");
    ids.add(bar >= 0 ? key.slice(bar + 1) : key);
  }
  for (const id of Object.keys(host.settings.allOffOverrides)) ids.add(id);
  // #104: wall switches marked as lights keep their mark across a source handoff.
  for (const id of switchLightMarkIds()) ids.add(id);
  return ids;
}

function applySynthesizedSnapshotToHost(
  host: MenuMijiaWindowsApp,
  home: {
    readonly devices: readonly SmartDevice[];
    readonly deviceFacets?: Readonly<Record<string, readonly import("../core/models.js").FacetControl[]>>;
    readonly environmentReadings: readonly import("../core/models.js").EnvironmentReading[];
    readonly scenes: readonly import("../core/models.js").HomeScene[];
  },
  groupOwners: Map<string, string>,
): void {
  host.scenes = [...host.scenes.filter((scene) => scene.sourceBackend === "xiaomiCloud" || scene.accountId !== undefined || !scene.id.startsWith("scene.")), ...home.scenes];
  host.groupOwnerByMemberDid = groupOwners;
  const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
  host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
  host.deviceFacets = merged.deviceFacets;
  if (
    host.cameraLive.activeLiveCameraId !== null &&
    !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
  ) {
    host.cameraLive.closeCameraLiveView();
  }
  const readingPriorityById = new Map(
    host.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
  );
  host.environmentReadings = applyOrder(
    host.environmentReadings.map((reading) => reading.id),
    home.environmentReadings,
  ).sort((a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0));
}

async function refreshMultiAccountXiaomiDevices(
  host: MenuMijiaWindowsApp,
  silent = false,
): Promise<void> {
  if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "xiaomiCloud" || host.isSyncingCloud) {
    return;
  }
  // One token covers both the local-write and source levels: a source switch cascades down to
  // `localWrite`, so a single `isCurrent()` at the strictest level detects every switch.
  const stateToken = host.sourceEpoch.capture();
  if (silent && (await isWorkstationLocked())) return;
  if (
    !isHostAttachedToActiveWindow(host) ||
    host.settings.connectionMode !== "xiaomiCloud" ||
    !stateToken.isCurrent() ||
    host.isSyncingCloud
  ) {
    return;
  }
  const store = getHostMiAccountsStore(host);
  const loadedFromStore = host.miAccountsOverride ?? (await store.load());
  await adoptRecoveredPrimarySession(host, store, loadedFromStore);
  if (
    !isHostAttachedToActiveWindow(host) ||
    host.settings.connectionMode !== "xiaomiCloud" ||
    !stateToken.isCurrent() ||
    host.isSyncingCloud
  ) {
    return;
  }
  const accounts =
    loadedFromStore.length > 0
      ? loadedFromStore
      : host.settings.miSession
        ? [makeMiAccount(host.settings.miSession)]
        : [];
  const enabledAccounts = resolveEnabledMiAccountsForHost(host, accounts);
  if (enabledAccounts.length === 0) return;

  const syncRun = host.sourceEpoch.claimSyncRun();
  const previousPresentation = cloudPresentationFingerprint(host);
  const previousStructure = cloudPanelStructureFingerprint(host);
  const staleBefore = host.cloudValuesStale;
  const expiredBefore = host.miSessionExpired;
  let presentationChanged = false;
  host.isSyncingCloud = true;
  host.lastCloudRefreshAt = Date.now();

  try {
    const prevState = host.multiAccountState;
    const { merged, children } = await refreshMiAccountsConcurrently({
      accounts: enabledAccounts,
      namespaceSingleAccount:
        accounts.length > 1 || (host.miAccountsOverride == null && hasSecondaryMiAccountsInIndex()),
      transport: host.transport,
      specResolver: host.specResolver,
      selectedHomeId: host.settings.selectedHomeId,
      silent,
      previousSnapshots: prevState?.children,
      prune: hostMiotTypePruneOptions(host),
    });
    const latestAccounts = host.miAccountsOverride ?? (store.getAccounts().length > 0 ? store.getAccounts() : accounts);
    const latestEnabledIds = new Set(resolveEnabledMiAccountsForHost(host, latestAccounts).map((a) => a.id));
    if (
      !isHostAttachedToActiveWindow(host) ||
      host.settings.connectionMode !== "xiaomiCloud" ||
      !stateToken.isCurrent() ||
      !syncRun.isCurrent() ||
      enabledAccounts.length !== latestEnabledIds.size ||
      !enabledAccounts.every((a) => latestEnabledIds.has(a.id))
    ) {
      return;
    }

    for (const account of enabledAccounts) {
      const child = children[account.id];
      if (child?.error) {
        appDiagnosticsLog.record({
          error: child.error,
          category:
            child.error instanceof MiCloudError && child.error.kind === "sessionExpired"
              ? "auth"
              : isXiaomiRateLimitError(child.error)
                ? "rateLimit"
                : "miCloud",
          statusCode: child.error instanceof MiCloudError ? (child.error.code ?? null) : null,
          forbiddenLiterals: [
            account.id,
            account.session.userId,
            account.session.cUserId,
            account.session.serviceToken,
            account.session.ssecurity,
          ],
        });
      }
    }

    host.multiAccountState = { accounts, merged, children };
    applyMiotTypePruneSnapshot(host, {
      safetyDevices: merged.safetyDevices,
      safetyDeviceFacets: merged.safetyDeviceFacets,
      hiddenDevices: merged.hiddenDevices,
      ...(merged.safetySignalsByDeviceId ? { safetySignalsByDeviceId: merged.safetySignalsByDeviceId } : {}),
    });
    if (merged.resetSelectedHome) {
      host.settings.selectedHomeId = null;
    }
    if (merged.homes.length > 0 || host.homes.length === 0) {
      host.homes = applyOrder(host.homes.map((h) => h.id), merged.homes);
    }

    const allExpired = enabledAccounts.every((acc) => merged.accountTokenStatuses[acc.id]?.kind === "expired");
    host.miSessionExpired = allExpired;
    if (merged.aggregateStatus.kind === "disconnected") {
      host.lastMiCloudSyncFailed = true;
      host.markCloudValuesStale();
      if (merged.home.devices.length > 0) {
        applySynthesizedSnapshotToHost(host, merged.home, merged.lightGroupOwners);
        presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
      }
      if (merged.resetSelectedHome) host.saveSettings();
    } else {
      host.lastMiCloudSyncFailed = false;
      host.markCloudValuesFresh();
      applySynthesizedSnapshotToHost(host, merged.home, merged.lightGroupOwners);
      presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
      markTimerSnapshotReady(host);
      const freshAccountIds = enabledAccounts
        .filter((acc) => children[acc.id]?.status.kind === "connected")
        .map((acc) => acc.id);
      if (completePendingMiRevalidation(host, freshAccountIds, accounts)) {
        presentationChanged = true;
      }
      host.settings.cachedXiaomiDevices = host.devices;
      if (presentationChanged || merged.resetSelectedHome) {
        host.saveSettings();
      }
    }

    if (!silent) {
      const isErr = merged.aggregateStatus.kind === "disconnected" && merged.home.devices.length === 0;
      host.replyBanner = isErr
        ? {
            text: t("米家云同步失败：{message}", { message: merged.aggregateStatus.reason }),
            source: t("连接异常"),
            isError: true,
          }
        : {
            text:
              merged.home.devices.length > 0
                ? t("已同步 {count} 台真实米家设备", { count: merged.home.devices.length })
                : t("当前小米账号下暂未发现米家设备"),
            source: t("米家云直连"),
          };
    }
  } finally {
    if (syncRun.isCurrent()) {
      host.isSyncingCloud = false;
      if (isHostAttachedToActiveWindow(host)) {
        const staleChanged = staleBefore !== host.cloudValuesStale;
        const expiredChanged = expiredBefore !== host.miSessionExpired;
        if (!silent) {
          host.render();
        } else if (staleChanged || expiredChanged) {
          host.queueBackgroundRender();
        } else if (presentationChanged) {
          if (cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)) {
            host.queueBackgroundRender();
          }
        }
      }
    }
  }
}

export function canUseDualSource(host: DualSourceInspectableHost): boolean {
  if (host.settings.connectionMode === "demo") return false;
  const hasHA = homeAssistantIdentity(host.settings.haBaseURL ?? "", host.settings.haToken ?? "") !== null;
  if (!hasHA) return false;
  const override = host.miAccountsOverride;
  const hasMi =
    (override != null && override.length > 0) ||
    host.settings.miSession != null ||
    hasSecondaryMiAccountsInIndex();
  return hasMi;
}

export function isDualSourceEnabled(host: DualSourceInspectableHost): boolean {
  if (!canUseDualSource(host)) return false;
  if (host.dualSourceEnabledOverride != null) return host.dualSourceEnabledOverride;
  if (typeof host.settings.dualSourceEnabled === "boolean") return host.settings.dualSourceEnabled;
  try {
    return typeof localStorage !== "undefined" && localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

export interface DualSourceMutableHost extends DualSourceInspectableHost {
  dualSourceEnabledOverride?: boolean | null;
  readonly settings: DualSourceInspectableHost["settings"] & {
    dualSourceEnabled?: boolean;
  };
}

export function setHostDualSourceEnabled(
  host: DualSourceMutableHost,
  enabled: boolean,
  options: { readonly persist?: boolean } = {},
): void {
  host.dualSourceEnabledOverride = enabled;
  host.settings.dualSourceEnabled = enabled;
  if (!enabled) {
    host.dualSourceCoordinator?.reset();
  }
  if (options.persist) {
    try {
      if (typeof localStorage !== "undefined") {
        if (enabled) localStorage.setItem(DUAL_SOURCE_ENABLED_STORAGE_KEY, "1");
        else localStorage.removeItem(DUAL_SOURCE_ENABLED_STORAGE_KEY);
      }
    } catch {
      return;
    }
  }
}

export function setHostHAInvokeOverride(host: MenuMijiaWindowsApp, invoke: HAInvoke | null): void {
  host.haInvokeOverride = invoke;
}

export function getHostDualSourceCoordinator(host: MenuMijiaWindowsApp): DualSourceCoordinator {
  if (!host.dualSourceCoordinator) {
    host.dualSourceCoordinator = new DualSourceCoordinator(undefined, {
      onRecompute: (merged) => {
        if (!isDualSourceEnabled(host)) return;
        applyDualSourceMergeToHost(host, merged);
        if (isHostAttachedToActiveWindow(host)) host.render();
      },
    });
  }
  return host.dualSourceCoordinator;
}

export function getHostDualSourceState(host: DualSourceInspectableHost): DeviceMergeResult | null {
  if (!isDualSourceEnabled(host)) return null;
  return host.dualSourceCoordinator?.getLastMerged() ?? null;
}

export function setHostDeviceSourcePin(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  backend: HomeBackend | null,
): DeviceMergeResult | null {
  if (!isDualSourceEnabled(host)) return null;
  const coordinator = getHostDualSourceCoordinator(host);
  coordinator.pinStorage.pin(deviceId, backend);
  return coordinator.getLastMerged();
}

export function recomputeHostDualSource(host: MenuMijiaWindowsApp): DeviceMergeResult | null {
  if (!isDualSourceEnabled(host)) return null;
  const coordinator = getHostDualSourceCoordinator(host);
  const merged = coordinator.recompute(host.settings.interfaceLanguage);
  if (merged) {
    applyDualSourceMergeToHost(host, merged);
    if (isHostAttachedToActiveWindow(host)) host.render();
  }
  return merged;
}

function applyDualSourceMergeToHost(host: MenuMijiaWindowsApp, merged: DeviceMergeResult): void {
  if (merged.homes.length > 0 || host.homes.length === 0) {
    host.homes = applyOrder(host.homes.map((h) => h.id), merged.homes);
  }
  const groupOwners = new Map<string, string>(merged.lightGroupOwners);
  applySynthesizedSnapshotToHost(host, merged.home, groupOwners);
  host.scenes = [...merged.home.scenes];
  // Fold the orphaned side's preferences onto the canonical cards (#24). Persisting only on a
  // real change keeps the periodic refresh from rewriting the settings store.
  if (adoptPairedDevicePreferences(host.settings.layout, merged.preferenceAdoptions)) {
    host.saveSettings();
  }
}

async function refreshDualSourceDevices(
  host: MenuMijiaWindowsApp,
  silent = false,
): Promise<void> {
  if (!isHostAttachedToActiveWindow(host) || host.isSyncingCloud) return;
  // One token covers both the local-write and source levels: a source switch cascades down to
  // `localWrite`, so a single `isCurrent()` at the strictest level detects every switch.
  const stateToken = host.sourceEpoch.capture();
  if (silent && (await isWorkstationLocked())) return;
  if (
    !isHostAttachedToActiveWindow(host) ||
    !isDualSourceEnabled(host) ||
    !stateToken.isCurrent() ||
    host.isSyncingCloud
  ) {
    return;
  }

  const endpoint = host.settings.haBaseURL;
  const token = host.settings.haToken;
  const overrideAccounts = host.miAccountsOverride;
  const store = getHostMiAccountsStore(host);
  const loadedAccounts =
    overrideAccounts ?? (await store.load().catch(() => []));
  await adoptRecoveredPrimarySession(host, store, loadedAccounts);
  if (
    !isHostAttachedToActiveWindow(host) ||
    !isDualSourceEnabled(host) ||
    !stateToken.isCurrent() ||
    host.isSyncingCloud
  ) {
    return;
  }
  const accounts =
    loadedAccounts.length > 0
      ? loadedAccounts
      : host.settings.miSession
        ? [makeMiAccount(host.settings.miSession)]
        : [];
  if (accounts.length === 0) return;
  const enabledAccounts = resolveEnabledMiAccountsForHost(host, accounts);
  const haEnabledAtStart = isHostHaEnabled(host) && getHostHaLifecyclePhase(host) === "enabled";
  if (!haEnabledAtStart && enabledAccounts.length === 0) return;
  const currentDualAccounts = () =>
    host.miAccountsOverride ?? (store.getAccounts().length > 0 ? store.getAccounts() : accounts);
  const currentHaActive = () => isHostHaEnabled(host) && getHostHaLifecyclePhase(host) === "enabled";

  const syncRun = host.sourceEpoch.claimSyncRun();
  const previousPresentation = cloudPresentationFingerprint(host);
  const previousStructure = cloudPanelStructureFingerprint(host);
  let presentationChanged = false;
  let failed = false;
  host.isSyncingCloud = true;
  host.lastCloudRefreshAt = Date.now();

  try {
    await host.endpointSubmission;
    if (
      !isHostAttachedToActiveWindow(host) ||
      !isDualSourceEnabled(host) ||
      !stateToken.isCurrent() ||
      !syncRun.isCurrent() ||
      currentHaActive() !== haEnabledAtStart
    ) {
      return;
    }
    const coordinator = getHostDualSourceCoordinator(host);
    const prevMiState = host.multiAccountState;
    const haInvoke = host.haInvokeOverride ?? undefined;
    let haRawSnapshot: unknown = null;
    let nextMultiAccountState: typeof host.multiAccountState = null;

    const outcome = await coordinator.refreshParallel({
      knownPreferenceIds: knownPreferenceIdsForHost(host),
      languagePreference: host.settings.interfaceLanguage,
      shouldCommit: () => {
        const latestIds = new Set(resolveEnabledMiAccountsForHost(host, currentDualAccounts()).map((a) => a.id));
        return (
          isHostAttachedToActiveWindow(host) &&
          isDualSourceEnabled(host) &&
          stateToken.isCurrent() &&
          syncRun.isCurrent() &&
          currentHaActive() === haEnabledAtStart &&
          enabledAccounts.length === latestIds.size &&
          enabledAccounts.every((a) => latestIds.has(a.id))
        );
      },
      fetchHA: haEnabledAtStart
        ? async (): Promise<DualSourceInputSnapshot> => {
            const haPrune = hostHaTypePruneOptions(host);
            const res = await fetchHASnapshotWithIdentities(endpoint, token, haInvoke, haPrune);
            haRawSnapshot = res.rawSnapshot;
            return {
              home: res.home,
              identity: homeAssistantIdentity(endpoint, token),
              identities: res.identities,
              safetySignalsByDeviceId: res.safetySignalsByDeviceId,
              ...(haPrune !== null
                ? {
                    safetyDevices: res.safetyDevices,
                    ...(res.safetyDeviceFacets ? { safetyDeviceFacets: res.safetyDeviceFacets } : {}),
                    hiddenDevices: res.hiddenIndexedDevices,
                  }
                : {}),
            };
          }
        : async (): Promise<DualSourceInputSnapshot | null> => null,
      fetchMi: async (): Promise<DualSourceInputSnapshot | null> => {
        if (enabledAccounts.length === 0) {
          return null;
        }
        const { merged, children } = await refreshMiAccountsConcurrently({
          accounts: enabledAccounts,
          namespaceSingleAccount:
            accounts.length > 1 || (host.miAccountsOverride == null && hasSecondaryMiAccountsInIndex()),
          transport: host.transport,
          specResolver: host.specResolver,
          selectedHomeId: host.settings.selectedHomeId,
          silent,
          previousSnapshots: prevMiState?.children,
          prune: hostMiotTypePruneOptions(host),
        });
        nextMultiAccountState = { accounts, merged, children };
        if (merged.aggregateStatus.kind === "disconnected") {
          throw new Error(merged.aggregateStatus.reason);
        }
        const allRawRecords: MiDeviceRecord[] = [];
        const seenDids = new Set<string>();
        for (const acc of enabledAccounts) {
          for (const rec of merged.rawDevicesByAccount[acc.id] ?? []) {
            if (!seenDids.has(rec.did)) {
              seenDids.add(rec.did);
              allRawRecords.push(rec);
            }
          }
        }
        return {
          home: merged.home,
          identities: extractMiDeviceIdentities(allRawRecords, merged.home),
          lightGroupOwners: merged.lightGroupOwners,
          homes: merged.homes,
          accountStatuses: merged.accountStatuses,
          safetyDevices: merged.safetyDevices ?? [],
          safetyDeviceFacets: merged.safetyDeviceFacets ?? {},
          hiddenDevices: merged.hiddenDevices ?? [],
          ...(merged.safetySignalsByDeviceId ? { safetySignalsByDeviceId: merged.safetySignalsByDeviceId } : {}),
        };
      },
    });

    const latestEnabledIds = new Set(resolveEnabledMiAccountsForHost(host, currentDualAccounts()).map((a) => a.id));
    if (
      outcome.aborted ||
      !isHostAttachedToActiveWindow(host) ||
      !isDualSourceEnabled(host) ||
      !stateToken.isCurrent() ||
      !syncRun.isCurrent() ||
      currentHaActive() !== haEnabledAtStart ||
      enabledAccounts.length !== latestEnabledIds.size ||
      !enabledAccounts.every((a) => latestEnabledIds.has(a.id))
    ) {
      return;
    }
    if (nextMultiAccountState) {
      host.multiAccountState = nextMultiAccountState;
    }

    if (haEnabledAtStart && outcome.haError) {
      appDiagnosticsLog.record({
        summary: outcome.haError,
        category: "homeAssistant",
        forbiddenLiterals: [endpoint, token],
      });
    }
    if (outcome.miError) {
      appDiagnosticsLog.record({
        summary: outcome.miError,
        category: "miCloud",
        forbiddenLiterals: accounts.flatMap((a) => [a.id, a.session.userId, a.session.serviceToken, a.session.ssecurity]),
      });
    }

    host.haConnectionError = haEnabledAtStart ? outcome.haError : null;
    host.lastMiCloudSyncFailed = Boolean(outcome.miError);
    host.markCloudValuesFresh();
    applyDualSourceMergeToHost(host, outcome.merged);
    const lastMiSnapshot = coordinator.getLastMiSnapshot();
    applyMiotTypePruneSnapshot(host, {
      safetyDevices: lastMiSnapshot?.safetyDevices,
      safetyDeviceFacets: lastMiSnapshot?.safetyDeviceFacets,
      hiddenDevices: lastMiSnapshot?.hiddenDevices,
      ...(lastMiSnapshot?.safetySignalsByDeviceId ? { safetySignalsByDeviceId: lastMiSnapshot.safetySignalsByDeviceId } : {}),
    });
    const lastHaSnapshot = coordinator.getLastHASnapshot();
    const haPruneScope = haConnectionScope(endpoint, token);
    applyHaTypePruneSnapshot(host, haEnabledAtStart && haPruneScope !== null && lastHaSnapshot
      ? {
          scope: haPruneScope,
          safetyDevices: lastHaSnapshot.safetyDevices,
          ...(lastHaSnapshot.safetyDeviceFacets ? { safetyDeviceFacets: lastHaSnapshot.safetyDeviceFacets } : {}),
          hiddenDevices: lastHaSnapshot.hiddenDevices,
          ...(lastHaSnapshot.safetySignalsByDeviceId ? { safetySignalsByDeviceId: lastHaSnapshot.safetySignalsByDeviceId } : {}),
        }
      : null);
    if (haEnabledAtStart && haRawSnapshot && typeof haRawSnapshot === "object") {
      void ingestHostHASnapshotForDoorbell(host, haRawSnapshot as HASnapshotLike);
    }
    markTimerSnapshotReady(host);
    if (haEnabledAtStart && !outcome.haError) {
      completePendingHaRevalidation(host, endpoint, token, accounts);
    }
    if (nextMultiAccountState) {
      const freshAccountIds = enabledAccounts
        .filter((acc) => nextMultiAccountState?.children[acc.id]?.status.kind === "connected")
        .map((acc) => acc.id);
      completePendingMiRevalidation(host, freshAccountIds, accounts);
    }
    presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
    if (presentationChanged) host.saveSettings();
    if (!silent) {
      host.replyBanner = {
        text: tr3(
          `双源并行已融合 ${outcome.merged.home.devices.length} 台设备`,
          `雙源並行已融合 ${outcome.merged.home.devices.length} 台裝置`,
          `Merged ${outcome.merged.home.devices.length} device(s) from Home Assistant + Xiaomi Cloud`,
        ),
        source: tr3("HA + 米家双源", "HA + 米家雙源", "HA + Xiaomi Dual Source"),
      };
    }
  } catch (error) {
    if (isHaBlockedRequestError(error) || !isHostAttachedToActiveWindow(host) || !stateToken.isCurrent() || !syncRun.isCurrent()) {
      return;
    }
    failed = true;
    const msg = error instanceof Error ? error.message : String(error);
    if (haEnabledAtStart) host.haConnectionError = msg;
    host.lastMiCloudSyncFailed = true;
    host.markCloudValuesStale();
    if (!silent) {
      host.replyBanner = {
        text: tr3(
          `双源同步失败：${msg}`,
          `雙源同步失敗：${msg}`,
          `Dual-source sync failed: ${msg}`,
        ),
        source: t("连接异常"),
        isError: true,
      };
    }
    appDiagnosticsLog.record({
      error,
      category: "network",
      forbiddenLiterals: [endpoint, token],
    });
  } finally {
    if (syncRun.isCurrent()) {
      host.isSyncingCloud = false;
      if (isHostAttachedToActiveWindow(host)) {
        if (!silent) {
          host.render();
        } else if (
          failed ||
          (presentationChanged &&
            (cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)))
        ) {
          host.queueBackgroundRender();
        }
      }
    }
  }
}
