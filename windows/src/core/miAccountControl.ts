import { AutomationRuleStore, type AutomationRule } from "./automationEngine.js";
import { DEVICE_CATEGORY_IDS, FEATURE_IDS, deviceCategoryForDevice, loadSharedCapabilityManifest, type CapabilityID, type DeviceCategoryID } from "./capabilityManifest.js";
import {
  controlTargetRejectionMessage, evaluateCapabilityDeactivation, evaluateControlTargetGate, evaluatePlanTargetsGate,
  partitionCapabilityDevices, resolveCapabilityInstallSelection, revalidatePausedTimer, type AutomationReference,
  type CapabilityDeactivationVerdict, type CapabilityIndexedDevice, type CapabilityInstallResolutionMode,
  type CapabilityReferenceGraph, type CapabilitySelection, type ControlTargetKind, type QuickActionReference,
  type SafetyRetentionPolicy, type SceneReference, type TimerReference,
} from "./capabilityReferenceVerdict.js";
import type { DeviceMergeRoute } from "./dualSourceProvider.js";
import { homeAssistantIdentity } from "./homeAssistant.js";
import type { LanguagePreference } from "./i18n.js";
import { MiAccountScope, makeMiAccount, miAccountId, type MiAccount } from "./miAccountsStore.js";
import { normalizeMiCloudRegion, type MiSession } from "./miCloudClient.js";
import { joinsAllOff, type DeviceIntent, type FacetControl, type HomeScene, type SmartDevice, type ScheduledCommand } from "./models.js";
import type { PausedScheduledCommand, ScheduledCommandStore } from "./scheduledCommands.js";

export const MI_ACCOUNT_CAPABILITY_STORAGE_KEY = "menumijia.windows.capabilitySelection.v1";
const BUILTIN_QUICK_ACTIONS = ["lightsOff", "softNightLight", "climateSleepOff"] as const;
const EMPTY_SAFETY_POLICY: SafetyRetentionPolicy = { enabledSignals: [] };
const ENTITY_FIELDS = [
  "entityId", "switchEntityId", "childLockEntityId", "motionDetectionEntityId", "modeEntityId", "fridgeTargetEntityId",
  "freezerTargetEntityId", "mediaEntityId", "muteSwitchEntityId", "sleepModeEntityId", "ttsActionId", "directiveActionId",
  "turnOnButtonId", "powerOnActionId", "powerOffActionId", "powerEntityId", "temperatureEntityId",
] as const;

export interface StorageLike { getItem(k: string): string | null; setItem(k: string, v: string): void; removeItem?(k: string): void; }
export interface DisabledMiDeviceSnapshot { readonly id: string; readonly rawDid: string; readonly name: string; readonly category: DeviceCategoryID; readonly accountId: string; readonly entityIds: readonly string[]; }
interface ParsedCapabilityStorageRecord { readonly migrationComplete: boolean; readonly disabledAccountIds: readonly string[]; readonly pausedQuickActionIds: readonly string[]; readonly knownDisabledDevices: readonly DisabledMiDeviceSnapshot[]; readonly extraFields: Readonly<Record<string, unknown>>; }
export interface ResolveMiAccountSelectionOptions { readonly storage?: StorageLike | null; readonly accounts: readonly MiAccount[]; readonly haBaseURL?: string | null; readonly haToken?: string | null; readonly connectionMode?: string; readonly dualSourceEnabled?: boolean; readonly hasExistingPreferences?: boolean; readonly hasPersistedLocalData?: boolean; readonly identityReadFailure?: string | null; }
export interface MiAccountSelectionState { readonly mode: CapabilityInstallResolutionMode; readonly selection: CapabilitySelection; readonly disabledAccountIds: ReadonlySet<string>; readonly pausedQuickActionIds: ReadonlySet<string>; readonly knownDisabledDevices: readonly DisabledMiDeviceSnapshot[]; persistIfMigrationReady(): boolean; }
export interface HostCapabilityContextInput { readonly state: MiAccountSelectionState; readonly accounts: readonly MiAccount[]; readonly devices: readonly SmartDevice[]; readonly scenes: readonly HomeScene[]; readonly haBaseURL?: string | null; readonly haToken?: string | null; readonly connectionMode: string; readonly dualSourceEnabled: boolean; readonly dualRoutes?: Readonly<Record<string, DeviceMergeRoute>>; readonly deviceOwners?: Readonly<Record<string, readonly string[]>>; readonly allOffOverrides?: Readonly<Record<string, boolean>>; readonly disablingAccountId?: string | null; }

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const defaultStorage = (): StorageLike | null => { try { return typeof localStorage !== "undefined" ? localStorage : null; } catch { return null; } };
const effectivePref = (pref?: LanguagePreference): LanguagePreference | undefined => (pref && pref !== "system" ? pref : undefined);
export const miAccountScope = (accountId: string): string => (accountId.startsWith("mi:") ? accountId : `mi:${accountId}`);
export const haConnectionScope = (haBaseURL?: string | null, haToken?: string | null): string | null => {
  const id = homeAssistantIdentity(haBaseURL ?? "", haToken ?? "");
  return id ? `ha:${id}` : null;
};

function parseDisabledDevice(raw: unknown): DisabledMiDeviceSnapshot | null {
  if (!isRecord(raw) || typeof raw["id"] !== "string" || !raw["id"] || typeof raw["rawDid"] !== "string" || !raw["rawDid"] ||
      typeof raw["name"] !== "string" || !raw["name"] || typeof raw["accountId"] !== "string" || !raw["accountId"] ||
      typeof raw["category"] !== "string" || !(DEVICE_CATEGORY_IDS as readonly string[]).includes(raw["category"]) || !Array.isArray(raw["entityIds"])) return null;
  return { id: raw["id"], rawDid: raw["rawDid"], name: raw["name"], category: raw["category"] as DeviceCategoryID, accountId: raw["accountId"], entityIds: raw["entityIds"].filter((x): x is string => typeof x === "string" && x.length > 0) };
}

function readCapabilityStorage(storage: StorageLike | null): { readonly parsed: ParsedCapabilityStorageRecord | null; readonly corruptRaw: string | null; readonly readError: boolean } {
  if (!storage) return { parsed: null, corruptRaw: null, readError: false };
  let raw: string | null = null;
  try { raw = storage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY); } catch { return { parsed: null, corruptRaw: null, readError: true }; }
  if (raw === null) return { parsed: null, corruptRaw: null, readError: false };
  try {
    const val: unknown = JSON.parse(raw);
    if (!isRecord(val) || val["schemaVersion"] !== 1 || typeof val["migrationComplete"] !== "boolean" ||
        !Array.isArray(val["disabledMiAccountIds"]) || !val["disabledMiAccountIds"].every((x) => typeof x === "string")) {
      return { parsed: null, corruptRaw: raw, readError: false };
    }
    const known = new Set(["schemaVersion", "migrationComplete", "disabledMiAccountIds", "pausedQuickActionIds", "knownDisabledDevices"]);
    const extraFields = Object.fromEntries(Object.entries(val).filter(([k]) => !known.has(k)));
    return {
      parsed: {
        migrationComplete: val["migrationComplete"], disabledAccountIds: val["disabledMiAccountIds"] as string[],
        pausedQuickActionIds: Array.isArray(val["pausedQuickActionIds"]) ? val["pausedQuickActionIds"].filter((x): x is string => typeof x === "string" && x.length > 0) : [],
        knownDisabledDevices: Array.isArray(val["knownDisabledDevices"]) ? val["knownDisabledDevices"].map(parseDisabledDevice).filter((x): x is DisabledMiDeviceSnapshot => x !== null) : [],
        extraFields,
      },
      corruptRaw: null, readError: false,
    };
  } catch { return { parsed: null, corruptRaw: raw, readError: false }; }
}

function writeCapabilityStorageRecord(storage: StorageLike | null, record: ParsedCapabilityStorageRecord, quarantineRaw: string | null): boolean {
  if (!storage) return false;
  try {
    if (quarantineRaw !== null) {
      const base = `${MI_ACCOUNT_CAPABILITY_STORAGE_KEY}.unreadable`;
      let key = base, suffix = 0;
      while (storage.getItem(key) !== null) key = `${base}.${++suffix}`;
      storage.setItem(key, quarantineRaw);
    }
    storage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify({
      ...record.extraFields, schemaVersion: 1, migrationComplete: record.migrationComplete,
      disabledMiAccountIds: [...new Set(record.disabledAccountIds)],
      ...(record.pausedQuickActionIds.length > 0 ? { pausedQuickActionIds: [...new Set(record.pausedQuickActionIds)] } : {}),
      ...(record.knownDisabledDevices.length > 0 ? { knownDisabledDevices: record.knownDisabledDevices } : {}),
    }));
    return true;
  } catch { return false; }
}

export function resolveMiAccountSelectionState(options: ResolveMiAccountSelectionOptions): MiAccountSelectionState {
  const storage = options.storage === undefined ? defaultStorage() : options.storage;
  const stored = readCapabilityStorage(storage);
  const miScopes = options.accounts.map((acc) => miAccountScope(acc.id));
  const haScope = haConnectionScope(options.haBaseURL, options.haToken);
  const includeHA = Boolean(haScope && (options.dualSourceEnabled || options.connectionMode === "homeAssistant" || options.connectionMode === undefined));
  const configuredScopes = [...miScopes, ...(includeHA && haScope ? [haScope] : [])];
  const disabledSet = new Set<string>(stored.parsed?.migrationComplete ? stored.parsed.disabledAccountIds.map(miAccountScope) : []);
  const enabledConns = [
    ...(miScopes.length > 0 || options.connectionMode === "xiaomiCloud" || (stored.parsed?.knownDisabledDevices.length ?? 0) > 0 ? (["xiaomi-cloud"] as const) : []),
    ...(includeHA ? (["home-assistant"] as const) : []),
  ];
  const explicitSelection: CapabilitySelection | null = stored.parsed?.migrationComplete
    ? { enabledConnections: enabledConns, enabledConnectionScopes: configuredScopes.filter((s) => !disabledSet.has(s)), enabledFeatures: [...FEATURE_IDS], enabledCategories: [...DEVICE_CATEGORY_IDS] }
    : null;
  const failure = options.identityReadFailure?.trim() || (stored.readError ? "capability_selection_read_error" : stored.corruptRaw !== null ? "corrupt_capability_selection_storage" : "");
  const resolution = resolveCapabilityInstallSelection({
    explicitSelection, configuredConnectionScopes: configuredScopes,
    hasLegacySettingsOrOnboarding: options.hasExistingPreferences ?? false,
    hasPersistedLocalData: options.hasPersistedLocalData ?? false,
    identityReadFailure: failure || null,
  }, loadSharedCapabilityManifest());
  return {
    mode: resolution.mode, selection: resolution.selection, disabledAccountIds: disabledSet,
    pausedQuickActionIds: new Set(stored.parsed?.pausedQuickActionIds ?? []),
    knownDisabledDevices: stored.parsed?.knownDisabledDevices ?? [],
    persistIfMigrationReady(): boolean {
      if (!resolution.persistMigrationComplete || stored.corruptRaw !== null || stored.readError) return false;
      if (stored.parsed?.migrationComplete) return true;
      return writeCapabilityStorageRecord(storage, {
        migrationComplete: true, disabledAccountIds: stored.parsed?.disabledAccountIds ?? [],
        pausedQuickActionIds: stored.parsed?.pausedQuickActionIds ?? [],
        knownDisabledDevices: stored.parsed?.knownDisabledDevices ?? [], extraFields: stored.parsed?.extraFields ?? {},
      }, null);
    },
  };
}

export const filterEnabledMiAccounts = (accounts: readonly MiAccount[], state: Pick<MiAccountSelectionState, "disabledAccountIds">): MiAccount[] =>
  accounts.filter((acc) => !state.disabledAccountIds.has(miAccountScope(acc.id)));
export const isMiSessionEnabledInState = (session: MiSession, state: Pick<MiAccountSelectionState, "disabledAccountIds">): boolean =>
  !state.disabledAccountIds.has(miAccountScope(miAccountId(session)));

export function writeMiAccountSelectionMutation(options: { readonly storage?: StorageLike | null; readonly mutate: (prev: ParsedCapabilityStorageRecord) => ParsedCapabilityStorageRecord }): boolean {
  const storage = options.storage === undefined ? defaultStorage() : options.storage;
  const current = readCapabilityStorage(storage);
  if (current.readError) return false;
  const base: ParsedCapabilityStorageRecord = current.parsed ?? { migrationComplete: true, disabledAccountIds: [], pausedQuickActionIds: [], knownDisabledDevices: [], extraFields: {} };
  return writeCapabilityStorageRecord(storage, options.mutate({ ...base, migrationComplete: true }), current.corruptRaw);
}

export function removeSignedOutMiAccountFromSelection(accountId: string | null, storage?: StorageLike | null): void {
  const target = accountId ? miAccountScope(accountId) : null;
  writeMiAccountSelectionMutation({ storage, mutate: (prev) => ({
    ...prev,
    disabledAccountIds: target === null ? [] : prev.disabledAccountIds.filter((id) => miAccountScope(id) !== target),
    knownDisabledDevices: target === null ? [] : prev.knownDisabledDevices.filter((d) => miAccountScope(d.accountId) !== target),
  }) });
}

export function collectEntityIdsForDevice(device: SmartDevice, facets: readonly FacetControl[] = []): string[] {
  const ids = new Set<string>([device.id, MiAccountScope.localId(device.id)]);
  const k = device.kind as unknown as Record<string, unknown>;
  for (const f of ENTITY_FIELDS) if (typeof k[f] === "string" && k[f]) ids.add(k[f] as string);
  for (const facet of facets) if (facet.target?.entityId) ids.add(facet.target.entityId);
  return [...ids];
}

export const snapshotDisabledMiDevice = (device: SmartDevice, accountId: string, facets: readonly FacetControl[] = []): DisabledMiDeviceSnapshot => ({
  id: device.id, rawDid: MiAccountScope.localId(device.id), name: device.name,
  category: deviceCategoryForDevice(device), accountId: miAccountScope(accountId), entityIds: collectEntityIdsForDevice(device, facets),
});

export function resolveDeviceMiAccountOwner(options: { readonly device: SmartDevice; readonly accounts: readonly MiAccount[]; readonly deviceOwners?: Readonly<Record<string, readonly string[]>>; readonly dualRoute?: DeviceMergeRoute }): string | null {
  const { device, accounts, deviceOwners, dualRoute } = options;
  if (device.accountId) return device.accountId;
  const scoped = MiAccountScope.owner(device.id);
  if (scoped) return scoped;
  const fromOwners = deviceOwners?.[device.id]?.[0] ?? deviceOwners?.[MiAccountScope.localId(device.id)]?.[0];
  if (fromOwners) return fromOwners;
  if (dualRoute) {
    if (dualRoute.backend === "xiaomiCloud") return dualRoute.sourceDevice.accountId ?? MiAccountScope.owner(dualRoute.sourceDeviceId) ?? accounts[0]?.id ?? null;
    if (dualRoute.alternateBackend === "xiaomiCloud" && dualRoute.alternateDevice) return dualRoute.alternateDevice.accountId ?? MiAccountScope.owner(dualRoute.alternateDevice.id) ?? accounts[0]?.id ?? null;
    return null;
  }
  return device.sourceBackend === "homeAssistant" ? null : (accounts[0]?.id ?? null);
}

export function parseTimerIdentityScope(identity: string): string | null {
  if (identity === "demo") return null;
  try {
    const parsed: unknown = JSON.parse(identity);
    if (!Array.isArray(parsed)) return null;
    if (parsed[0] === "xiaomiCloud" && typeof parsed[1] === "string" && typeof parsed[2] === "string") return miAccountId({ userId: parsed[1], region: normalizeMiCloudRegion(parsed[2]) });
    if (parsed[0] === "homeAssistant" && typeof parsed[1] === "string") return `ha:${parsed[1]}`;
  } catch {}
  return null;
}

const toAutomationReference = (rule: AutomationRule): AutomationReference => ({
  id: rule.id, name: rule.id, isEnabled: rule.isEnabled,
  action: rule.action.kind === "devices" ? { kind: "devices", targetIds: rule.action.deviceIds }
    : rule.action.kind === "scene" ? { kind: "scene", sceneId: rule.action.sceneId }
    : { kind: "quickAction", quickAction: rule.action.quickAction },
});

export function buildIndexedCapabilityDevices(input: HostCapabilityContextInput): { readonly indexedDevices: CapabilityIndexedDevice[]; readonly sceneRefs: SceneReference[] } {
  const haScope = haConnectionScope(input.haBaseURL, input.haToken);
  const indexedDevices: CapabilityIndexedDevice[] = [];
  const seenIds = new Set<string>();
  for (const dev of input.devices) {
    if (seenIds.has(dev.id)) continue;
    const route = input.dualRoutes?.[dev.id];
    const miOwner = resolveDeviceMiAccountOwner({ device: dev, accounts: input.accounts, ...(input.deviceOwners ? { deviceOwners: input.deviceOwners } : {}), ...(route ? { dualRoute: route } : {}) });
    const hasHaFallback = Boolean(input.dualSourceEnabled && haScope && (route?.backend === "homeAssistant" || (route?.alternateBackend === "homeAssistant" && route.alternateDevice !== null) || (!route && dev.sourceBackend === "homeAssistant")));
    const useHa = input.connectionMode === "homeAssistant" && !input.dualSourceEnabled ? true : hasHaFallback && (!miOwner || miOwner === input.disablingAccountId || input.state.disabledAccountIds.has(miOwner));
    const ownerId = miOwner ?? input.accounts[0]?.id ?? null;
    const connection = input.connectionMode === "demo" ? null : useHa ? (haScope ? ("home-assistant" as const) : null) : (ownerId ? ("xiaomi-cloud" as const) : null);
    const sourceScope = connection === null ? "demo" : connection === "home-assistant" ? haScope! : miAccountScope(ownerId!);
    seenIds.add(dev.id);
    indexedDevices.push({
      id: dev.id, name: dev.name, category: deviceCategoryForDevice(dev), connection, sourceScope,
      isSourceAvailable: connection === "xiaomi-cloud" && ownerId ? !input.state.disabledAccountIds.has(ownerId) : true,
      upstreamHiddenOrDisabled: false, participatesInAllOff: joinsAllOff(dev, input.allOffOverrides ?? {}),
      safetySignals: [], readKeys: [dev.id], safetyReadKeys: [],
    });
  }
  for (const snap of input.state.knownDisabledDevices) {
    if (seenIds.has(snap.id)) continue;
    seenIds.add(snap.id);
    indexedDevices.push({
      id: snap.id, name: snap.name, category: snap.category, connection: "xiaomi-cloud",
      sourceScope: miAccountScope(snap.accountId), isSourceAvailable: false, upstreamHiddenOrDisabled: false,
      participatesInAllOff: false, safetySignals: [], readKeys: [snap.id], safetyReadKeys: [],
    });
  }
  const sceneHasHa = input.connectionMode !== "demo" && haScope !== null;
  const sceneRefs: SceneReference[] = input.scenes.map((sc) => ({ id: sc.id, name: sc.name, connection: sceneHasHa ? "home-assistant" : null, sourceScope: sceneHasHa ? haScope! : "demo", isSourceAvailable: true }));
  return { indexedDevices, sceneRefs };
}

export function previewMiAccountDisable(options: {
  readonly accountId: string; readonly context: HostCapabilityContextInput; readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null; readonly ruleStore: AutomationRuleStore; readonly preferences?: CapabilityReferenceGraph["preferences"];
  readonly expectedGeneration?: number | null; readonly currentGeneration?: number | null;
}): CapabilityDeactivationVerdict {
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices({ ...options.context, disablingAccountId: options.accountId });
  const devById = new Map(indexedDevices.map((d) => [d.id, d] as const));
  const timers: TimerReference[] = [];
  for (const [identity, queue] of options.scheduledCommandStore.entries()) {
    const queueScope = parseTimerIdentityScope(identity), isActive = identity === options.activeTimerIdentity;
    const pushList = (list: readonly ScheduledCommand[], partition: TimerReference["partition"]) => {
      for (const item of list) {
        const targetIds = (item.intents ?? []).map((i) => i.targetId);
        const derived = targetIds.map((tid) => devById.get(tid)?.sourceScope).filter((s): s is string => Boolean(s && s !== "demo"));
        timers.push({ id: item.id, name: item.command, partition, targetIds, sourceScopes: derived.length > 0 ? [...new Set(derived)] : queueScope ? [queueScope] : [] });
      }
    };
    pushList(queue.scheduledCommands, isActive ? "waiting" : "foreign");
    pushList(queue.missedScheduledCommands, isActive ? "missed" : "foreign");
  }
  const targetScope = miAccountScope(options.accountId);
  const proposed: CapabilitySelection = { ...options.context.state.selection, enabledConnectionScopes: options.context.state.selection.enabledConnectionScopes.filter((s) => s !== targetScope) };
  return evaluateCapabilityDeactivation(
    options.context.state.selection, proposed, loadSharedCapabilityManifest(), indexedDevices, EMPTY_SAFETY_POLICY,
    {
      timers, automations: options.ruleStore.load().map(toAutomationReference),
      quickActions: BUILTIN_QUICK_ACTIONS.map((id): QuickActionReference => ({ id, name: id, kind: id, isEnabled: !options.context.state.pausedQuickActionIds.has(id) })),
      scenes: sceneRefs, ...(options.preferences ? { preferences: options.preferences } : {}),
      ...(options.scheduledCommandStore.hasStorageError() ? { corruptedStoreReasons: ["scheduledCommands"] } : {}),
      expectedGeneration: options.expectedGeneration ?? null, currentGeneration: options.currentGeneration ?? null,
    },
  );
}

export function applyPauseItemsFromVerdict(options: { readonly verdict: CapabilityDeactivationVerdict; readonly scheduledCommandStore: ScheduledCommandStore; readonly ruleStore: AutomationRuleStore }): readonly string[] {
  const timerItems = new Map(options.verdict.itemsToPause.filter((i) => i.kind === "waitingTimer" || i.kind === "missedTimer" || i.kind === "foreignTimer").map((i) => [i.id, i] as const));
  if (timerItems.size > 0) {
    for (const [, queue] of options.scheduledCommandStore.entries()) {
      const paused = (queue.pausedScheduledCommands ??= []);
      const moveFrom = (list: readonly ScheduledCommand[], orig: "waiting" | "missed") => list.filter((cmd) => {
        const hit = timerItems.get(cmd.id);
        if (!hit) return true;
        paused.push({ command: cmd, originalPartition: orig, sourceScopes: hit.connectionScopes, pausedCapabilities: hit.affectedCapabilities });
        return false;
      });
      queue.scheduledCommands = moveFrom(queue.scheduledCommands, "waiting");
      queue.missedScheduledCommands = moveFrom(queue.missedScheduledCommands, "missed");
    }
    options.scheduledCommandStore.persist();
  }
  const rulePauseMap = new Map(options.verdict.itemsToPause.filter((i) => i.kind === "automationRule").map((i) => [i.id, [...new Set([...i.affectedCapabilities, ...i.connectionScopes])]] as const));
  if (rulePauseMap.size > 0) {
    options.ruleStore.save(options.ruleStore.load().map((rule) => {
      const reasons = rulePauseMap.get(rule.id);
      return reasons && rule.isEnabled ? { ...rule, isEnabled: false, pausedByCapabilities: [...new Set([...(rule.pausedByCapabilities ?? []), ...reasons])] } : rule;
    }));
  }
  return options.verdict.itemsToPause.filter((i) => i.kind === "quickAction").map((i) => i.id);
}

export function revalidateAfterMiAccountReenable(options: {
  readonly context: HostCapabilityContextInput; readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null; readonly ruleStore: AutomationRuleStore; readonly nowMs?: number; readonly storage?: StorageLike | null;
}): void {
  const nowEpochSeconds = Math.floor((options.nowMs ?? Date.now()) / 1000);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  const selection = options.context.state.selection;
  const availSet = new Set(partitionCapabilityDevices(indexedDevices, selection, EMPTY_SAFETY_POLICY).availableDeviceIds);
  const devById = new Map(indexedDevices.map((d) => [d.id, d] as const));

  let timersMutated = false;
  for (const [identity, queue] of options.scheduledCommandStore.entries()) {
    const pausedList = queue.pausedScheduledCommands ?? [];
    if (pausedList.length === 0) continue;
    const queueScope = parseTimerIdentityScope(identity);
    const activeScopes = identity === options.activeTimerIdentity ? selection.enabledConnectionScopes : queueScope && selection.enabledConnectionScopes.includes(queueScope) ? [queueScope] : [];
    const stillPaused: PausedScheduledCommand[] = [];
    for (const paused of pausedList) {
      const disp = revalidatePausedTimer({
        timer: {
          id: paused.command.id, name: paused.command.command, partition: identity === options.activeTimerIdentity ? paused.originalPartition : "foreign",
          targetIds: (paused.command.intents ?? []).map((i) => i.targetId), sourceScopes: paused.sourceScopes.length > 0 ? paused.sourceScopes : queueScope ? [queueScope] : [],
          pausedCapabilities: paused.pausedCapabilities as readonly CapabilityID[],
        },
        fireAtEpochSeconds: Math.floor(paused.command.fireTimestampMs / 1000), nowEpochSeconds, activeConnectionScopes: activeScopes, selection, devices: indexedDevices, scenes: sceneRefs,
      });
      if (disp === "keepPaused" || (disp === "partitionForeign" && activeScopes.length === 0)) { stillPaused.push(paused); continue; }
      timersMutated = true;
      if (disp === "armWaiting" && paused.originalPartition === "waiting") queue.scheduledCommands.push(paused.command);
      else queue.missedScheduledCommands.push(paused.command);
    }
    queue.pausedScheduledCommands = stillPaused;
  }
  if (timersMutated) options.scheduledCommandStore.persist();

  let rulesMutated = false;
  const resumedRules = options.ruleStore.load().map((rule) => {
    if (!rule.pausedByCapabilities?.length) return rule;
    const scopes = rule.pausedByCapabilities.filter((c) => c.startsWith("mi:") || c.startsWith("ha:"));
    if (scopes.some((s) => !selection.enabledConnectionScopes.includes(s))) return rule;
    if (rule.action.kind === "devices" && !rule.action.deviceIds.some((id) => availSet.has(id))) return rule;
    rulesMutated = true;
    const { pausedByCapabilities: _c, ...rest } = rule;
    return { ...rest, isEnabled: true };
  });
  if (rulesMutated) options.ruleStore.save(resumedRules);

  const restoredQa = new Set<string>();
  for (const qaId of options.context.state.pausedQuickActionIds) {
    const cats = qaId === "climateSleepOff" ? ["climate", "fan"] : ["light"];
    if ([...availSet].some((id) => cats.includes(devById.get(id)?.category ?? ""))) restoredQa.add(qaId);
  }
  if (restoredQa.size > 0) writeMiAccountSelectionMutation({ storage: options.storage, mutate: (prev) => ({ ...prev, pausedQuickActionIds: prev.pausedQuickActionIds.filter((id) => !restoredQa.has(id)) }) });
}

export function resolveDisabledDeviceByEntity(entityId: string, knownDisabledDevices: readonly DisabledMiDeviceSnapshot[]): DisabledMiDeviceSnapshot | null {
  const base = entityId.split("#")[0] ?? entityId;
  return knownDisabledDevices.find((rec) =>
    rec.id === entityId || rec.id === base || rec.rawDid === entityId || rec.rawDid === base || rec.entityIds.includes(entityId) || rec.entityIds.includes(base) ||
    base.startsWith(`${rec.id}.`) || base.startsWith(`${rec.rawDid}.`) || base.startsWith(`miot:${rec.id}:`) || base.startsWith(`miot:${rec.rawDid}:`),
  ) ?? null;
}

export function evaluateDeviceEntityWriteGate(options: {
  readonly targetKind: ControlTargetKind; readonly targetIdOrEntityId: string; readonly resolvedActiveDeviceId: string | null;
  readonly context: HostCapabilityContextInput; readonly languagePreference?: LanguagePreference;
}): string | null {
  const pref = effectivePref(options.languagePreference);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  if (options.targetKind === "scene") {
    const matched = options.context.scenes.find((s) => s.id === options.targetIdOrEntityId || s.entityId === options.targetIdOrEntityId);
    if (!matched) return null;
    const v = evaluateControlTargetGate({ targetKind: "scene", targetId: matched.id, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
    return v.allowed || !v.rejectionReason ? null : controlTargetRejectionMessage(v.rejectionReason, pref);
  }
  const disabledMatch = options.resolvedActiveDeviceId === null ? resolveDisabledDeviceByEntity(options.targetIdOrEntityId, options.context.state.knownDisabledDevices) : null;
  const targetId = options.resolvedActiveDeviceId ?? disabledMatch?.id ?? null;
  if (targetId === null) return null;
  const v = evaluateControlTargetGate({ targetKind: "device", targetId, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
  return v.allowed || !v.rejectionReason ? null : controlTargetRejectionMessage(v.rejectionReason, pref);
}

export function evaluateIntentsWriteGate(options: { readonly intents: readonly DeviceIntent[]; readonly context: HostCapabilityContextInput; readonly languagePreference?: LanguagePreference }): string | null {
  if (options.intents.length === 0) return null;
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  const targets = options.intents.map((i) => ({ kind: (i.operation.kind === "activateScene" ? "scene" : "device") as ControlTargetKind, id: i.targetId }));
  const v = evaluatePlanTargetsGate({ targets, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
  if (v.allowed || !v.rejectionReason) return null;
  if ((v.rejectionReason.code === "deviceNotFound" || v.rejectionReason.code === "sceneNotFound") &&
      targets.some((t) => (t.kind === "scene" ? sceneRefs.some((s) => s.id === t.id) : options.context.devices.some((d) => d.id === t.id)))) return null;
  return controlTargetRejectionMessage(v.rejectionReason, effectivePref(options.languagePreference));
}

export function evaluateDisabledDeviceUrlGate(
  deviceIdOrName: string,
  settings: { readonly connectionMode?: string; readonly miSession?: MiSession | null; readonly haBaseURL?: string; readonly haToken?: string; readonly dualSourceEnabled?: boolean; readonly interfaceLanguage?: LanguagePreference },
  storage?: StorageLike | null,
): string | null {
  if (settings.connectionMode === "demo") return null;
  const accounts = settings.miSession ? [makeMiAccount(settings.miSession)] : [];
  const mode = settings.connectionMode ?? "xiaomiCloud";
  const state = resolveMiAccountSelectionState({ storage, accounts, haBaseURL: settings.haBaseURL ?? null, haToken: settings.haToken ?? null, connectionMode: mode, dualSourceEnabled: Boolean(settings.dualSourceEnabled), hasExistingPreferences: true });
  const hit = state.knownDisabledDevices.find((d) => d.id === deviceIdOrName || d.rawDid === deviceIdOrName || d.name === deviceIdOrName);
  if (!hit || !state.disabledAccountIds.has(hit.accountId)) return null;
  const { indexedDevices } = buildIndexedCapabilityDevices({ state, accounts, devices: [], scenes: [], haBaseURL: settings.haBaseURL ?? null, haToken: settings.haToken ?? null, connectionMode: mode, dualSourceEnabled: Boolean(settings.dualSourceEnabled) });
  const v = evaluateControlTargetGate({ targetKind: "device", targetId: hit.id, selection: state.selection, devices: indexedDevices });
  return v.allowed || !v.rejectionReason ? null : controlTargetRejectionMessage(v.rejectionReason, effectivePref(settings.interfaceLanguage));
}
