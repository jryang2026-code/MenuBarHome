import { LocalIntentParser, normalizeSceneName } from "./assistant.js";
import { AutomationRuleStore, automationTriggerTitle, summarizeAutomationAction, type AutomationRule } from "./automationEngine.js";
import { DEVICE_CATEGORY_IDS, FEATURE_IDS, deviceCategoryForDevice, loadSharedCapabilityManifest, type CapabilityID, type ConnectionCapabilityID, type DeviceCategoryID } from "./capabilityManifest.js";
import {
  QUICK_ACTION_TARGET_CATEGORIES, controlTargetRejectionMessage, evaluateCapabilityDeactivation, evaluateControlTargetGate, evaluatePlanTargetsGate,
  isValidCapabilityIndexedDevice, partitionCapabilityDevices, resolveCapabilityInstallSelection, revalidatePausedTimer, type AutomationReference,
  type CapabilityDeactivationVerdict, type CapabilityIndexedDevice, type CapabilityInstallResolutionMode,
  type CapabilityReferenceGraph, type CapabilitySelection, type ControlTargetKind, type ControlTargetRejectionReason,
  type QuickActionReference, type QuickActionReferenceKind, type SafetyRetentionPolicy, type SceneReference, type TimerReference,
} from "./capabilityReferenceVerdict.js";
import type { DeviceMergeRoute } from "./dualSourceProvider.js";
import { CAPABILITY_SELECTION_STORAGE_KEY, haConnectionScope } from "./haTransportGate.js";
import type { LanguagePreference } from "./i18n.js";
import { MiAccountScope, makeMiAccount, miAccountId, type MiAccount } from "./miAccountsStore.js";
import { normalizeMiCloudRegion, type MiSession } from "./miCloudClient.js";
import { joinsAllOff, type DeviceIntent, type DeviceKind, type FacetControl, type HomeScene, type SmartDevice, type ScheduledCommand } from "./models.js";
import { planQuickAction, quickActionTitle, type QuickActionId } from "./quickActions.js";
import type { PausedScheduledCommand, ScheduledCommandStore } from "./scheduledCommands.js";

export { haConnectionScope };
export const MI_ACCOUNT_CAPABILITY_STORAGE_KEY = CAPABILITY_SELECTION_STORAGE_KEY;

export class CapabilityGateError extends Error {
  public readonly code = "CAPABILITY_GATE_REJECTED" as const;
  public readonly reason: ControlTargetRejectionReason;

  constructor(reason: ControlTargetRejectionReason, preference?: LanguagePreference) {
    super(controlTargetRejectionMessage(reason, preference && preference !== "system" ? preference : undefined));
    this.name = "CapabilityGateError";
    this.reason = reason;
  }
}

export function isCapabilityGateError(error: unknown): error is CapabilityGateError {
  return (
    error instanceof CapabilityGateError ||
    (typeof error === "object" &&
      error !== null &&
      (error as { code?: unknown }).code === "CAPABILITY_GATE_REJECTED" &&
      typeof (error as { reason?: unknown }).reason === "object" &&
      (error as { reason?: unknown }).reason !== null)
  );
}

const BUILTIN_QUICK_ACTIONS: readonly QuickActionId[] = ["lightsOff", "softNightLight", "climateSleepOff"];
const EMPTY_SAFETY_POLICY: SafetyRetentionPolicy = { enabledSignals: [] };
const ENTITY_FIELDS = [
  "entityId", "switchEntityId", "childLockEntityId", "motionDetectionEntityId", "modeEntityId", "fridgeTargetEntityId",
  "freezerTargetEntityId", "mediaEntityId", "muteSwitchEntityId", "sleepModeEntityId", "ttsActionId", "directiveActionId",
  "turnOnButtonId", "powerOnActionId", "powerOffActionId", "powerEntityId", "temperatureEntityId",
] as const;

export interface StorageLike { getItem(k: string): string | null; setItem(k: string, v: string): void; removeItem?(k: string): void; }
export interface DisabledMiDeviceSnapshot { readonly id: string; readonly rawDid: string; readonly name: string; readonly category: DeviceCategoryID; readonly accountId: string; readonly entityIds: readonly string[]; }
export interface DisabledMiSceneSnapshot { readonly id: string; readonly entityId?: string; readonly name: string; readonly accountId: string; }
export interface DisabledHaDeviceSnapshot { readonly id: string; readonly rawHaId: string; readonly name: string; readonly category: DeviceCategoryID; readonly scope: string; readonly entityIds: readonly string[]; readonly aliasName?: string; }
export interface DisabledHaSceneSnapshot { readonly id: string; readonly entityId?: string; readonly name: string; readonly scope: string; }
export interface ParsedCapabilityStorageRecord {
  readonly migrationComplete: boolean;
  readonly disabledAccountIds: readonly string[];
  readonly pendingRevalidationAccountIds: readonly string[];
  readonly disabledHaScopes: readonly string[];
  readonly pendingRevalidationHaScopes: readonly string[];
  readonly pausedQuickActionIds: readonly string[];
  readonly knownDisabledDevices: readonly DisabledMiDeviceSnapshot[];
  readonly knownDisabledScenes: readonly DisabledMiSceneSnapshot[];
  readonly knownDisabledHaDevices: readonly DisabledHaDeviceSnapshot[];
  readonly knownDisabledHaScenes: readonly DisabledHaSceneSnapshot[];
  readonly extraFields: Readonly<Record<string, unknown>>;
}
export interface ResolveMiAccountSelectionOptions { readonly storage?: StorageLike | null; readonly accounts: readonly MiAccount[]; readonly haBaseURL?: string | null; readonly haToken?: string | null; readonly connectionMode?: string; readonly dualSourceEnabled?: boolean; readonly hasExistingPreferences?: boolean; readonly hasPersistedLocalData?: boolean; readonly identityReadFailure?: string | null; }
export interface MiAccountSelectionState {
  readonly mode: CapabilityInstallResolutionMode;
  readonly selection: CapabilitySelection;
  readonly disabledAccountIds: ReadonlySet<string>;
  readonly pendingRevalidationAccountIds: ReadonlySet<string>;
  readonly disabledHaScopes: ReadonlySet<string>;
  readonly pendingRevalidationHaScopes: ReadonlySet<string>;
  readonly pausedQuickActionIds: ReadonlySet<string>;
  readonly knownDisabledDevices: readonly DisabledMiDeviceSnapshot[];
  readonly knownDisabledScenes: readonly DisabledMiSceneSnapshot[];
  readonly knownDisabledHaDevices: readonly DisabledHaDeviceSnapshot[];
  readonly knownDisabledHaScenes: readonly DisabledHaSceneSnapshot[];
  persistIfMigrationReady(): boolean;
}
export interface HostCapabilityContextInput { readonly state: MiAccountSelectionState; readonly accounts: readonly MiAccount[]; readonly devices: readonly SmartDevice[]; readonly scenes: readonly HomeScene[];
  /** Index entries of cards a device-type selection withholds; they answer the gate, never display. */
  readonly hiddenDevices?: readonly CapabilityIndexedDevice[]; readonly haBaseURL?: string | null; readonly haToken?: string | null; readonly connectionMode: string; readonly dualSourceEnabled: boolean; readonly dualRoutes?: Readonly<Record<string, DeviceMergeRoute>>; readonly deviceOwners?: Readonly<Record<string, readonly string[]>>; readonly allOffOverrides?: Readonly<Record<string, boolean>>; readonly deviceAliases?: Readonly<Record<string, string>>; readonly disablingAccountId?: string | null; }

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const defaultStorage = (): StorageLike | null => { try { return typeof localStorage !== "undefined" ? localStorage : null; } catch { return null; } };
const effectivePref = (pref?: LanguagePreference): LanguagePreference | undefined => (pref && pref !== "system" ? pref : undefined);
export const miAccountScope = (accountId: string): string => (accountId.startsWith("mi:") ? accountId : `mi:${accountId}`);
const normalizeHaScopeString = (raw: string): string => haConnectionScope(raw) ?? (raw.startsWith("ha:") ? raw : `ha:${raw}`);
const stripHaCardPrefix = (id: string): string => (id.startsWith("ha:") ? id.slice(3) : id);

function parseDisabledDevice(raw: unknown): DisabledMiDeviceSnapshot | null {
  if (!isRecord(raw) || typeof raw["id"] !== "string" || !raw["id"] || typeof raw["rawDid"] !== "string" || !raw["rawDid"] ||
      typeof raw["name"] !== "string" || !raw["name"] || typeof raw["accountId"] !== "string" || !raw["accountId"] ||
      typeof raw["category"] !== "string" || !(DEVICE_CATEGORY_IDS as readonly string[]).includes(raw["category"]) || !Array.isArray(raw["entityIds"])) return null;
  return { id: raw["id"], rawDid: raw["rawDid"], name: raw["name"], category: raw["category"] as DeviceCategoryID, accountId: raw["accountId"], entityIds: raw["entityIds"].filter((x): x is string => typeof x === "string" && x.length > 0) };
}

function parseDisabledScene(raw: unknown): DisabledMiSceneSnapshot | null {
  if (!isRecord(raw) || typeof raw["id"] !== "string" || !raw["id"] || typeof raw["name"] !== "string" || !raw["name"] ||
      typeof raw["accountId"] !== "string" || !raw["accountId"]) return null;
  const entityId = typeof raw["entityId"] === "string" && raw["entityId"].length > 0 ? raw["entityId"] : undefined;
  return { id: raw["id"], ...(entityId !== undefined ? { entityId } : {}), name: raw["name"], accountId: raw["accountId"] };
}

function parseDisabledHaDevice(raw: unknown): DisabledHaDeviceSnapshot | null {
  if (!isRecord(raw) || typeof raw["id"] !== "string" || !raw["id"] || typeof raw["name"] !== "string" || !raw["name"] ||
      typeof raw["scope"] !== "string" || !raw["scope"] ||
      typeof raw["category"] !== "string" || !(DEVICE_CATEGORY_IDS as readonly string[]).includes(raw["category"]) || !Array.isArray(raw["entityIds"])) return null;
  const rawHaId = typeof raw["rawHaId"] === "string" && raw["rawHaId"].length > 0 ? raw["rawHaId"] : stripHaCardPrefix(raw["id"]);
  const aliasName = typeof raw["aliasName"] === "string" && raw["aliasName"].trim().length > 0 ? raw["aliasName"].trim() : undefined;
  return {
    id: raw["id"],
    rawHaId,
    name: raw["name"],
    category: raw["category"] as DeviceCategoryID,
    scope: normalizeHaScopeString(raw["scope"]),
    entityIds: raw["entityIds"].filter((x): x is string => typeof x === "string" && x.length > 0),
    ...(aliasName !== undefined ? { aliasName } : {}),
  };
}

function parseDisabledHaScene(raw: unknown): DisabledHaSceneSnapshot | null {
  if (!isRecord(raw) || typeof raw["id"] !== "string" || !raw["id"] || typeof raw["name"] !== "string" || !raw["name"] ||
      typeof raw["scope"] !== "string" || !raw["scope"]) return null;
  const entityId = typeof raw["entityId"] === "string" && raw["entityId"].length > 0 ? raw["entityId"] : undefined;
  return {
    id: raw["id"],
    ...(entityId !== undefined ? { entityId } : {}),
    name: raw["name"],
    scope: normalizeHaScopeString(raw["scope"]),
  };
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
    if (val["disabledHaScopes"] !== undefined && (!Array.isArray(val["disabledHaScopes"]) || !val["disabledHaScopes"].every((x) => typeof x === "string"))) {
      return { parsed: null, corruptRaw: raw, readError: false };
    }
    const known = new Set([
      "schemaVersion", "migrationComplete", "disabledMiAccountIds", "pendingRevalidationAccountIds",
      "disabledHaScopes", "pendingRevalidationHaScopes", "pausedQuickActionIds",
      "knownDisabledDevices", "knownDisabledScenes", "knownDisabledHaDevices", "knownDisabledHaScenes",
    ]);
    const extraFields = Object.fromEntries(Object.entries(val).filter(([k]) => !known.has(k)));
    return {
      parsed: {
        migrationComplete: val["migrationComplete"],
        disabledAccountIds: val["disabledMiAccountIds"] as string[],
        pendingRevalidationAccountIds: Array.isArray(val["pendingRevalidationAccountIds"])
          ? val["pendingRevalidationAccountIds"].filter((x): x is string => typeof x === "string" && x.length > 0)
          : [],
        disabledHaScopes: Array.isArray(val["disabledHaScopes"])
          ? val["disabledHaScopes"].filter((x): x is string => typeof x === "string" && x.length > 0).map(normalizeHaScopeString)
          : [],
        pendingRevalidationHaScopes: Array.isArray(val["pendingRevalidationHaScopes"])
          ? val["pendingRevalidationHaScopes"].filter((x): x is string => typeof x === "string" && x.length > 0).map(normalizeHaScopeString)
          : [],
        pausedQuickActionIds: Array.isArray(val["pausedQuickActionIds"]) ? val["pausedQuickActionIds"].filter((x): x is string => typeof x === "string" && x.length > 0) : [],
        knownDisabledDevices: Array.isArray(val["knownDisabledDevices"]) ? val["knownDisabledDevices"].map(parseDisabledDevice).filter((x): x is DisabledMiDeviceSnapshot => x !== null) : [],
        knownDisabledScenes: Array.isArray(val["knownDisabledScenes"]) ? val["knownDisabledScenes"].map(parseDisabledScene).filter((x): x is DisabledMiSceneSnapshot => x !== null) : [],
        knownDisabledHaDevices: Array.isArray(val["knownDisabledHaDevices"]) ? val["knownDisabledHaDevices"].map(parseDisabledHaDevice).filter((x): x is DisabledHaDeviceSnapshot => x !== null) : [],
        knownDisabledHaScenes: Array.isArray(val["knownDisabledHaScenes"]) ? val["knownDisabledHaScenes"].map(parseDisabledHaScene).filter((x): x is DisabledHaSceneSnapshot => x !== null) : [],
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
      ...(record.pendingRevalidationAccountIds.length > 0 ? { pendingRevalidationAccountIds: [...new Set(record.pendingRevalidationAccountIds.map(miAccountScope))] } : {}),
      ...(record.disabledHaScopes.length > 0 ? { disabledHaScopes: [...new Set(record.disabledHaScopes.map(normalizeHaScopeString))] } : {}),
      ...(record.pendingRevalidationHaScopes.length > 0 ? { pendingRevalidationHaScopes: [...new Set(record.pendingRevalidationHaScopes.map(normalizeHaScopeString))] } : {}),
      ...(record.pausedQuickActionIds.length > 0 ? { pausedQuickActionIds: [...new Set(record.pausedQuickActionIds)] } : {}),
      ...(record.knownDisabledDevices.length > 0 ? { knownDisabledDevices: record.knownDisabledDevices } : {}),
      ...(record.knownDisabledScenes.length > 0 ? { knownDisabledScenes: record.knownDisabledScenes } : {}),
      ...(record.knownDisabledHaDevices.length > 0 ? { knownDisabledHaDevices: record.knownDisabledHaDevices } : {}),
      ...(record.knownDisabledHaScenes.length > 0 ? { knownDisabledHaScenes: record.knownDisabledHaScenes } : {}),
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
  const pendingRevalidationSet = new Set<string>(stored.parsed?.migrationComplete ? stored.parsed.pendingRevalidationAccountIds.map(miAccountScope) : []);
  const disabledHaSet = new Set<string>(stored.parsed?.migrationComplete ? stored.parsed.disabledHaScopes.map(normalizeHaScopeString) : []);
  const pendingRevalidationHaSet = new Set<string>(stored.parsed?.migrationComplete ? stored.parsed.pendingRevalidationHaScopes.map(normalizeHaScopeString) : []);
  const isCurrentHaDisabled = Boolean(haScope && disabledHaSet.has(haScope));
  const enabledConns = [
    ...(miScopes.length > 0 || options.connectionMode === "xiaomiCloud" || (stored.parsed?.knownDisabledDevices.length ?? 0) > 0 || (stored.parsed?.knownDisabledScenes.length ?? 0) > 0 ? (["xiaomi-cloud"] as const) : []),
    ...(includeHA && !isCurrentHaDisabled ? (["home-assistant"] as const) : []),
  ];
  const explicitSelection: CapabilitySelection | null = stored.parsed?.migrationComplete
    ? {
        enabledConnections: enabledConns,
        enabledConnectionScopes: configuredScopes.filter((s) => !disabledSet.has(s) && !disabledHaSet.has(s)),
        enabledFeatures: [...FEATURE_IDS],
        enabledCategories: [...DEVICE_CATEGORY_IDS],
      }
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
    pendingRevalidationAccountIds: pendingRevalidationSet,
    disabledHaScopes: disabledHaSet,
    pendingRevalidationHaScopes: pendingRevalidationHaSet,
    pausedQuickActionIds: new Set(stored.parsed?.pausedQuickActionIds ?? []),
    knownDisabledDevices: stored.parsed?.knownDisabledDevices ?? [],
    knownDisabledScenes: stored.parsed?.knownDisabledScenes ?? [],
    knownDisabledHaDevices: stored.parsed?.knownDisabledHaDevices ?? [],
    knownDisabledHaScenes: stored.parsed?.knownDisabledHaScenes ?? [],
    persistIfMigrationReady(): boolean {
      if (!resolution.persistMigrationComplete || stored.corruptRaw !== null || stored.readError) return false;
      if (stored.parsed?.migrationComplete) return true;
      return writeCapabilityStorageRecord(storage, {
        migrationComplete: true, disabledAccountIds: stored.parsed?.disabledAccountIds ?? [],
        pendingRevalidationAccountIds: stored.parsed?.pendingRevalidationAccountIds ?? [],
        disabledHaScopes: stored.parsed?.disabledHaScopes ?? [],
        pendingRevalidationHaScopes: stored.parsed?.pendingRevalidationHaScopes ?? [],
        pausedQuickActionIds: stored.parsed?.pausedQuickActionIds ?? [],
        knownDisabledDevices: stored.parsed?.knownDisabledDevices ?? [],
        knownDisabledScenes: stored.parsed?.knownDisabledScenes ?? [],
        knownDisabledHaDevices: stored.parsed?.knownDisabledHaDevices ?? [],
        knownDisabledHaScenes: stored.parsed?.knownDisabledHaScenes ?? [],
        extraFields: stored.parsed?.extraFields ?? {},
      }, null);
    },
  };
}

export const filterEnabledMiAccounts = (accounts: readonly MiAccount[], state: Pick<MiAccountSelectionState, "disabledAccountIds">): MiAccount[] =>
  accounts.filter((acc) => !state.disabledAccountIds.has(miAccountScope(acc.id)));
export const isMiSessionEnabledInState = (session: MiSession, state: Pick<MiAccountSelectionState, "disabledAccountIds">): boolean =>
  !state.disabledAccountIds.has(miAccountScope(miAccountId(session)));
export const isHaScopeEnabledInState = (scope: string | null | undefined, state: Pick<MiAccountSelectionState, "disabledHaScopes">): boolean =>
  Boolean(scope && !state.disabledHaScopes.has(normalizeHaScopeString(scope)));

export function writeMiAccountSelectionMutation(options: { readonly storage?: StorageLike | null; readonly mutate: (prev: ParsedCapabilityStorageRecord) => ParsedCapabilityStorageRecord }): boolean {
  const storage = options.storage === undefined ? defaultStorage() : options.storage;
  const current = readCapabilityStorage(storage);
  if (current.readError) return false;
  const base: ParsedCapabilityStorageRecord = current.parsed ?? {
    migrationComplete: true,
    disabledAccountIds: [],
    pendingRevalidationAccountIds: [],
    disabledHaScopes: [],
    pendingRevalidationHaScopes: [],
    pausedQuickActionIds: [],
    knownDisabledDevices: [],
    knownDisabledScenes: [],
    knownDisabledHaDevices: [],
    knownDisabledHaScenes: [],
    extraFields: {},
  };
  return writeCapabilityStorageRecord(storage, options.mutate({ ...base, migrationComplete: true }), current.corruptRaw);
}

export function removeSignedOutMiAccountFromSelection(accountId: string | null, storage?: StorageLike | null): void {
  const target = accountId ? miAccountScope(accountId) : null;
  writeMiAccountSelectionMutation({ storage, mutate: (prev) => ({
    ...prev,
    disabledAccountIds: target === null ? [] : prev.disabledAccountIds.filter((id) => miAccountScope(id) !== target),
    pendingRevalidationAccountIds: target === null ? [] : prev.pendingRevalidationAccountIds.filter((id) => miAccountScope(id) !== target),
    pausedQuickActionIds: target === null && prev.disabledHaScopes.length === 0 ? [] : prev.pausedQuickActionIds,
    knownDisabledDevices: target === null ? [] : prev.knownDisabledDevices.filter((d) => miAccountScope(d.accountId) !== target),
    knownDisabledScenes: target === null ? [] : prev.knownDisabledScenes.filter((s) => miAccountScope(s.accountId) !== target),
  }) });
}

export function removeDisconnectedHaFromSelection(haScope?: string | null, storage?: StorageLike | null): void {
  const target = haScope ? normalizeHaScopeString(haScope) : null;
  writeMiAccountSelectionMutation({
    storage,
    mutate: (prev) => ({
      ...prev,
      disabledHaScopes: target === null ? [] : prev.disabledHaScopes.filter((s) => normalizeHaScopeString(s) !== target),
      pendingRevalidationHaScopes: target === null ? [] : prev.pendingRevalidationHaScopes.filter((s) => normalizeHaScopeString(s) !== target),
      pausedQuickActionIds:
        target === null && prev.disabledAccountIds.length === 0
          ? []
          : prev.pausedQuickActionIds,
      knownDisabledHaDevices: target === null ? [] : prev.knownDisabledHaDevices.filter((d) => normalizeHaScopeString(d.scope) !== target),
      knownDisabledHaScenes: target === null ? [] : prev.knownDisabledHaScenes.filter((s) => normalizeHaScopeString(s.scope) !== target),
    }),
  });
}

export function queueMiAccountReenableFromLogin(
  accountId: string,
  options: {
    readonly storage?: StorageLike | null;
    readonly scheduledCommandStore?: ScheduledCommandStore | null;
    readonly ruleStore?: AutomationRuleStore | null;
  } = {},
): void {
  const targetScope = miAccountScope(accountId);
  const hasPausedTimers = options.scheduledCommandStore
    ? [...options.scheduledCommandStore.entries()].some(([, q]) => (q.pausedScheduledCommands?.length ?? 0) > 0)
    : false;
  const effectiveRuleStore = options.ruleStore === undefined ? new AutomationRuleStore() : options.ruleStore;
  const hasPausedRules = effectiveRuleStore
    ? effectiveRuleStore.load().some((r) => Boolean(r.pausedByCapabilities?.length))
    : false;
  writeMiAccountSelectionMutation({
    storage: options.storage,
    mutate: (prev) => {
      const needsRevalidation =
        prev.disabledAccountIds.some((id) => miAccountScope(id) === targetScope) ||
        prev.pendingRevalidationAccountIds.some((id) => miAccountScope(id) === targetScope) ||
        prev.knownDisabledDevices.some((d) => miAccountScope(d.accountId) === targetScope) ||
        prev.knownDisabledScenes.some((s) => miAccountScope(s.accountId) === targetScope) ||
        prev.pausedQuickActionIds.length > 0 ||
        hasPausedTimers ||
        hasPausedRules;
      return {
        ...prev,
        disabledAccountIds: prev.disabledAccountIds.filter((id) => miAccountScope(id) !== targetScope),
        pendingRevalidationAccountIds: needsRevalidation
          ? [...new Set([...prev.pendingRevalidationAccountIds, targetScope])]
          : prev.pendingRevalidationAccountIds,
      };
    },
  });
}

export function collectEntityIdsForDevice(device: SmartDevice, facets: readonly FacetControl[] = []): string[] {
  const rawHaId = stripHaCardPrefix(device.id);
  const ids = new Set<string>([device.id, MiAccountScope.localId(device.id), rawHaId]);
  const k = device.kind as unknown as Record<string, unknown>;
  for (const f of ENTITY_FIELDS) if (typeof k[f] === "string" && k[f]) ids.add(k[f] as string);
  for (const facet of facets) if (facet.target?.entityId) ids.add(facet.target.entityId);
  return [...ids];
}

export const snapshotDisabledMiDevice = (device: SmartDevice, accountId: string, facets: readonly FacetControl[] = []): DisabledMiDeviceSnapshot => ({
  id: device.id, rawDid: MiAccountScope.localId(device.id), name: device.name,
  category: deviceCategoryForDevice(device), accountId: miAccountScope(accountId), entityIds: collectEntityIdsForDevice(device, facets),
});

export const snapshotDisabledMiScene = (scene: HomeScene, accountId: string): DisabledMiSceneSnapshot => ({
  id: scene.id,
  ...(scene.entityId ? { entityId: scene.entityId } : {}),
  name: scene.name,
  accountId: miAccountScope(accountId),
});

export const snapshotDisabledHaDevice = (
  device: SmartDevice,
  haScope: string,
  facets: readonly FacetControl[] = [],
  aliasName?: string | null,
): DisabledHaDeviceSnapshot => {
  const trimmedAlias = typeof aliasName === "string" && aliasName.trim().length > 0 ? aliasName.trim() : undefined;
  return {
    id: device.id,
    rawHaId: stripHaCardPrefix(device.id),
    name: device.name,
    category: deviceCategoryForDevice(device),
    scope: normalizeHaScopeString(haScope),
    entityIds: collectEntityIdsForDevice(device, facets),
    ...(trimmedAlias !== undefined ? { aliasName: trimmedAlias } : {}),
  };
};

export const snapshotDisabledHaScene = (scene: HomeScene, haScope: string): DisabledHaSceneSnapshot => ({
  id: scene.id,
  ...(scene.entityId ? { entityId: scene.entityId } : {}),
  name: scene.name,
  scope: normalizeHaScopeString(haScope),
});

export function resolveDeviceMiAccountOwner(options: {
  readonly device: SmartDevice;
  readonly accounts: readonly MiAccount[];
  readonly deviceOwners?: Readonly<Record<string, readonly string[]>>;
  readonly dualRoute?: DeviceMergeRoute;
  readonly connectionMode?: string;
  readonly dualSourceEnabled?: boolean;
  readonly disabledAccountIds?: ReadonlySet<string>;
  readonly disablingAccountId?: string | null;
}): string | null {
  const { device, accounts, deviceOwners, dualRoute, connectionMode, dualSourceEnabled, disabledAccountIds, disablingAccountId } = options;
  if (!dualSourceEnabled && connectionMode !== undefined && connectionMode !== "xiaomiCloud") {
    return null;
  }
  if ((device.sourceBackend === "homeAssistant" || device.id.startsWith("ha:")) && !dualRoute) {
    return null;
  }
  const scoped = MiAccountScope.owner(device.id);
  if (scoped) return scoped;

  const candidates: string[] = [];
  const addCandidate = (id: string | null | undefined): void => {
    if (id && !candidates.includes(id)) candidates.push(id);
  };
  const addOwnersForId = (id: string | null | undefined): void => {
    if (!id || !deviceOwners) return;
    for (const owner of deviceOwners[id] ?? []) addCandidate(owner);
    const local = MiAccountScope.localId(id);
    if (local !== id) {
      for (const owner of deviceOwners[local] ?? []) addCandidate(owner);
    }
  };

  if (device.accountId) addCandidate(device.accountId);
  addOwnersForId(device.id);
  if (dualRoute) {
    if (dualRoute.backend === "xiaomiCloud") {
      addCandidate(dualRoute.sourceDevice.accountId ?? MiAccountScope.owner(dualRoute.sourceDeviceId));
      addOwnersForId(dualRoute.sourceDevice.id);
      addOwnersForId(dualRoute.sourceDeviceId);
    }
    if (dualRoute.alternateBackend === "xiaomiCloud" && dualRoute.alternateDevice) {
      addCandidate(dualRoute.alternateDevice.accountId ?? MiAccountScope.owner(dualRoute.alternateDevice.id));
      addOwnersForId(dualRoute.alternateDevice.id);
    }
    if (candidates.length === 0) {
      if (dualRoute.backend === "xiaomiCloud" || (dualRoute.alternateBackend === "xiaomiCloud" && dualRoute.alternateDevice)) {
        return accounts[0]?.id ?? null;
      }
      return null;
    }
  }

  if (candidates.length > 0) {
    const disabledScopes = new Set([...(disabledAccountIds ?? [])].map(miAccountScope));
    const disablingScope = disablingAccountId ? miAccountScope(disablingAccountId) : null;
    const knownScopes = new Set(accounts.map((acc) => miAccountScope(acc.id)));
    const isKnown = (id: string): boolean => knownScopes.size === 0 || knownScopes.has(miAccountScope(id));
    const survivingEnabled = candidates.find(
      (id) => isKnown(id) && !disabledScopes.has(miAccountScope(id)) && miAccountScope(id) !== disablingScope,
    );
    if (survivingEnabled) return survivingEnabled;
    const enabledBefore = candidates.find((id) => isKnown(id) && !disabledScopes.has(miAccountScope(id)));
    if (enabledBefore) return enabledBefore;
    return candidates[0]!;
  }

  if (dualSourceEnabled && connectionMode === "homeAssistant" && device.sourceBackend !== "xiaomiCloud") {
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
    if (parsed[0] === "homeAssistant" && typeof parsed[1] === "string") {
      const baseUrl = parsed[1].split("|", 1)[0] ?? parsed[1];
      return haConnectionScope(baseUrl) ?? `ha:${baseUrl}`;
    }
  } catch {}
  return null;
}

const toAutomationReference = (
  rule: AutomationRule,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  preference?: LanguagePreference,
): AutomationReference => ({
  id: rule.id,
  name: `${automationTriggerTitle(rule.trigger, preference)} → ${summarizeAutomationAction(rule.action, devices, scenes, preference)}`,
  isEnabled: rule.isEnabled,
  action: rule.action.kind === "devices" ? { kind: "devices", targetIds: rule.action.deviceIds }
    : rule.action.kind === "scene" ? { kind: "scene", sceneId: rule.action.sceneId }
    : { kind: "quickAction", quickAction: rule.action.quickAction },
});

export function resolveSceneMiAccountOwner(options: {
  readonly scene: HomeScene;
  readonly accounts: readonly MiAccount[];
  readonly connectionMode: string;
  readonly dualSourceEnabled: boolean;
  readonly haBaseURL?: string | null;
  readonly haToken?: string | null;
}): string | null {
  if (options.connectionMode === "demo" && !options.dualSourceEnabled) return null;
  const haScope = haConnectionScope(options.haBaseURL, options.haToken);
  const explicitMiOwner =
    options.scene.accountId ??
    MiAccountScope.owner(options.scene.id) ??
    MiAccountScope.owner(options.scene.entityId) ??
    (options.scene.sourceBackend === "xiaomiCloud" ||
    (!options.scene.sourceBackend &&
      !options.scene.id.startsWith("scene.") &&
      !options.scene.entityId.startsWith("scene.") &&
      (/^\d+\.\d+\./.test(options.scene.entityId) || options.scene.entityId.startsWith("miot:")))
      ? (options.accounts[0]?.id ?? null)
      : null);
  const useSceneHa =
    options.connectionMode === "homeAssistant" && !options.dualSourceEnabled
      ? true
      : Boolean(
          options.dualSourceEnabled &&
            haScope &&
            options.scene.sourceBackend !== "xiaomiCloud" &&
            (!explicitMiOwner || options.scene.sourceBackend === "homeAssistant"),
        );
  if (useSceneHa) return null;
  return explicitMiOwner ?? options.accounts[0]?.id ?? null;
}

export function buildIndexedCapabilityDevices(input: HostCapabilityContextInput): { readonly indexedDevices: CapabilityIndexedDevice[]; readonly sceneRefs: SceneReference[] } {
  const haScope = haConnectionScope(input.haBaseURL, input.haToken);
  const disablingScope = input.disablingAccountId ? miAccountScope(input.disablingAccountId) : null;
  const isCurrentHaDisabled = Boolean(haScope && input.state.disabledHaScopes.has(haScope));
  const indexedDevices: CapabilityIndexedDevice[] = [];
  const seenIds = new Set<string>();
  for (const dev of input.devices) {
    if (seenIds.has(dev.id)) continue;
    const route = input.dualRoutes?.[dev.id];
    const miOwner = resolveDeviceMiAccountOwner({
      device: dev,
      accounts: input.accounts,
      connectionMode: input.connectionMode,
      dualSourceEnabled: input.dualSourceEnabled,
      disabledAccountIds: input.state.disabledAccountIds,
      disablingAccountId: input.disablingAccountId ?? null,
      ...(input.deviceOwners ? { deviceOwners: input.deviceOwners } : {}),
      ...(route ? { dualRoute: route } : {}),
    });
    const isPureHaDevice =
      !miOwner &&
      Boolean(
        haScope &&
          (route?.backend === "homeAssistant" ||
            (!route && (dev.sourceBackend === "homeAssistant" || dev.id.startsWith("ha:")))),
      );
    const hasEnabledHaFallback = Boolean(
      input.dualSourceEnabled &&
        haScope &&
        !isCurrentHaDisabled &&
        (route?.backend === "homeAssistant" ||
          (route?.alternateBackend === "homeAssistant" && route.alternateDevice !== null) ||
          (!route && dev.sourceBackend === "homeAssistant")),
    );
    const useHa = input.connectionMode === "homeAssistant" && !input.dualSourceEnabled
      ? true
      : isPureHaDevice ||
        (hasEnabledHaFallback &&
          (!miOwner || miAccountScope(miOwner) === disablingScope || input.state.disabledAccountIds.has(miAccountScope(miOwner))));
    const ownerId = miOwner ?? input.accounts[0]?.id ?? null;
    const connection = input.connectionMode === "demo" && !input.dualSourceEnabled ? null : useHa ? (haScope ? ("home-assistant" as const) : null) : (ownerId ? ("xiaomi-cloud" as const) : null);
    const sourceScope = connection === null ? "demo" : connection === "home-assistant" ? haScope! : miAccountScope(ownerId!);
    const isSourceAvailable =
      connection === "xiaomi-cloud" && ownerId
        ? !input.state.disabledAccountIds.has(miAccountScope(ownerId))
        : connection === "home-assistant" && haScope
          ? !input.state.disabledHaScopes.has(haScope)
          : true;
    seenIds.add(dev.id);
    indexedDevices.push({
      id: dev.id, name: dev.name, category: deviceCategoryForDevice(dev), connection, sourceScope,
      isSourceAvailable,
      upstreamHiddenOrDisabled: false, participatesInAllOff: joinsAllOff(dev, input.allOffOverrides ?? {}),
      safetySignals: [], readKeys: [dev.id], safetyReadKeys: [],
    });
  }
  // A closed device type stays in the identity index so the gate can name it instead of claiming
  // the device never existed (architecture.md §D). Availability still comes from the live account.
  for (const hidden of input.hiddenDevices ?? []) {
    if (!isValidCapabilityIndexedDevice(hidden) || seenIds.has(hidden.id)) continue;
    seenIds.add(hidden.id);
    indexedDevices.push({
      ...hidden,
      isSourceAvailable: input.state.disabledAccountIds.has(hidden.sourceScope) ? false : hidden.isSourceAvailable,
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
  for (const snap of input.state.knownDisabledHaDevices) {
    const scope = normalizeHaScopeString(snap.scope);
    if (!input.state.disabledHaScopes.has(scope) || seenIds.has(snap.id)) continue;
    seenIds.add(snap.id);
    indexedDevices.push({
      id: snap.id, name: snap.name, category: snap.category, connection: "home-assistant",
      sourceScope: scope, isSourceAvailable: false, upstreamHiddenOrDisabled: false,
      participatesInAllOff: false, safetySignals: [], readKeys: [snap.id], safetyReadKeys: [],
    });
  }
  const seenSceneIds = new Set<string>();
  const sceneRefs: SceneReference[] = [];
  for (const sc of input.scenes) {
    if (seenSceneIds.has(sc.id)) continue;
    seenSceneIds.add(sc.id);
    if (input.connectionMode === "demo" && !input.dualSourceEnabled) {
      sceneRefs.push({ id: sc.id, name: sc.name, connection: null, sourceScope: "demo", isSourceAvailable: true });
      continue;
    }
    const miOwner = resolveSceneMiAccountOwner({
      scene: sc,
      accounts: input.accounts,
      connectionMode: input.connectionMode,
      dualSourceEnabled: input.dualSourceEnabled,
      haBaseURL: input.haBaseURL ?? null,
      haToken: input.haToken ?? null,
    });
    const connection = miOwner !== null
      ? ("xiaomi-cloud" as const)
      : (haScope ? ("home-assistant" as const) : null);
    const sourceScope =
      connection === null ? "demo" : connection === "home-assistant" ? haScope! : miAccountScope(miOwner!);
    const isSourceAvailable =
      connection === "xiaomi-cloud" && miOwner
        ? !input.state.disabledAccountIds.has(miAccountScope(miOwner))
        : connection === "home-assistant" && haScope
          ? !input.state.disabledHaScopes.has(haScope)
          : true;
    sceneRefs.push({ id: sc.id, name: sc.name, connection, sourceScope, isSourceAvailable });
  }
  for (const snap of input.state.knownDisabledScenes) {
    const scope = miAccountScope(snap.accountId);
    if (!input.state.disabledAccountIds.has(scope) || seenSceneIds.has(snap.id)) continue;
    seenSceneIds.add(snap.id);
    sceneRefs.push({
      id: snap.id,
      name: snap.name,
      connection: "xiaomi-cloud",
      sourceScope: scope,
      isSourceAvailable: false,
    });
  }
  for (const snap of input.state.knownDisabledHaScenes) {
    const scope = normalizeHaScopeString(snap.scope);
    if (!input.state.disabledHaScopes.has(scope) || seenSceneIds.has(snap.id)) continue;
    seenSceneIds.add(snap.id);
    sceneRefs.push({
      id: snap.id,
      name: snap.name,
      connection: "home-assistant",
      sourceScope: scope,
      isSourceAvailable: false,
    });
  }
  return { indexedDevices, sceneRefs };
}

function collectTimerReferencesForDeactivation(options: {
  readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null;
  readonly activeSessionScopes: readonly string[];
  readonly devById: ReadonlyMap<string, CapabilityIndexedDevice>;
  readonly sceneById: ReadonlyMap<string, SceneReference>;
}): TimerReference[] {
  const activeTimerScope = options.activeTimerIdentity ? parseTimerIdentityScope(options.activeTimerIdentity) : null;
  const timers: TimerReference[] = [];
  for (const [identity, queue] of options.scheduledCommandStore.entries()) {
    const queueScope = parseTimerIdentityScope(identity);
    const isActive =
      identity === options.activeTimerIdentity ||
      (queueScope !== null && queueScope.startsWith("ha:") && activeTimerScope === queueScope);
    const pushList = (list: readonly ScheduledCommand[], partition: TimerReference["partition"]) => {
      for (const item of list) {
        const targetIds = (item.intents ?? []).map((i) => i.targetId);
        const derived = targetIds
          .map((tid) => options.devById.get(tid)?.sourceScope ?? options.sceneById.get(tid)?.sourceScope)
          .filter((s): s is string => Boolean(s && s !== "demo"));
        const sourceScopes = item.sourceScopes?.length
          ? [...new Set(item.sourceScopes)]
          : isActive
            ? [...new Set([...options.activeSessionScopes, ...derived])]
            : derived.length > 0
              ? [...new Set(derived)]
              : queueScope
                ? [queueScope]
                : [];
        timers.push({ id: item.id, name: item.command, partition, targetIds, sourceScopes });
      }
    };
    pushList(queue.scheduledCommands, isActive ? "waiting" : "foreign");
    pushList(queue.missedScheduledCommands, isActive ? "missed" : "foreign");
  }
  return timers;
}

export function previewMiAccountDisable(options: {
  readonly accountId: string; readonly context: HostCapabilityContextInput; readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null; readonly ruleStore: AutomationRuleStore; readonly preferences?: CapabilityReferenceGraph["preferences"];
  readonly expectedGeneration?: number | null; readonly currentGeneration?: number | null; readonly languagePreference?: LanguagePreference;
}): CapabilityDeactivationVerdict {
  const pref = effectivePref(options.languagePreference);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices({ ...options.context, disablingAccountId: options.accountId });
  const devById = new Map(indexedDevices.map((d) => [d.id, d] as const));
  const sceneById = new Map(sceneRefs.map((s) => [s.id, s] as const));
  const timers = collectTimerReferencesForDeactivation({
    scheduledCommandStore: options.scheduledCommandStore,
    activeTimerIdentity: options.activeTimerIdentity,
    activeSessionScopes: options.context.state.selection.enabledConnectionScopes,
    devById,
    sceneById,
  });
  const targetScope = miAccountScope(options.accountId);
  const proposed: CapabilitySelection = { ...options.context.state.selection, enabledConnectionScopes: options.context.state.selection.enabledConnectionScopes.filter((s) => s !== targetScope) };
  return evaluateCapabilityDeactivation(
    options.context.state.selection, proposed, loadSharedCapabilityManifest(), indexedDevices, EMPTY_SAFETY_POLICY,
    {
      timers,
      automations: options.ruleStore.load().map((rule) => toAutomationReference(rule, options.context.devices, options.context.scenes, pref)),
      quickActions: BUILTIN_QUICK_ACTIONS.map((id): QuickActionReference => ({ id, name: quickActionTitle(id, pref), kind: id, isEnabled: !options.context.state.pausedQuickActionIds.has(id) })),
      scenes: sceneRefs, ...(options.preferences ? { preferences: options.preferences } : {}),
      ...(options.scheduledCommandStore.hasStorageError() ? { corruptedStoreReasons: ["scheduledCommands"] } : {}),
      expectedGeneration: options.expectedGeneration ?? null, currentGeneration: options.currentGeneration ?? null,
    },
  );
}

export function previewHaConnectionDisable(options: {
  readonly haScope?: string | null;
  readonly context: HostCapabilityContextInput;
  readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null;
  readonly ruleStore: AutomationRuleStore;
  readonly preferences?: CapabilityReferenceGraph["preferences"];
  readonly expectedGeneration?: number | null;
  readonly currentGeneration?: number | null;
  readonly languagePreference?: LanguagePreference;
}): CapabilityDeactivationVerdict {
  const pref = effectivePref(options.languagePreference);
  const resolvedScope =
    (options.haScope ? normalizeHaScopeString(options.haScope) : null) ??
    haConnectionScope(options.context.haBaseURL, options.context.haToken);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  const devById = new Map(indexedDevices.map((d) => [d.id, d] as const));
  const sceneById = new Map(sceneRefs.map((s) => [s.id, s] as const));
  const timers = collectTimerReferencesForDeactivation({
    scheduledCommandStore: options.scheduledCommandStore,
    activeTimerIdentity: options.activeTimerIdentity,
    activeSessionScopes: options.context.state.selection.enabledConnectionScopes,
    devById,
    sceneById,
  });
  const proposed: CapabilitySelection = {
    ...options.context.state.selection,
    enabledConnections: options.context.state.selection.enabledConnections.filter((c) => c !== "home-assistant"),
    enabledConnectionScopes: options.context.state.selection.enabledConnectionScopes.filter(
      (s) => !s.startsWith("ha:") && (resolvedScope === null || s !== resolvedScope),
    ),
  };
  return evaluateCapabilityDeactivation(
    options.context.state.selection,
    proposed,
    loadSharedCapabilityManifest(),
    indexedDevices,
    EMPTY_SAFETY_POLICY,
    {
      timers,
      automations: options.ruleStore.load().map((rule) => toAutomationReference(rule, options.context.devices, options.context.scenes, pref)),
      quickActions: BUILTIN_QUICK_ACTIONS.map((id): QuickActionReference => ({
        id,
        name: quickActionTitle(id, pref),
        kind: id,
        isEnabled: !options.context.state.pausedQuickActionIds.has(id),
      })),
      scenes: sceneRefs,
      ...(options.preferences ? { preferences: options.preferences } : {}),
      ...(options.scheduledCommandStore.hasStorageError() ? { corruptedStoreReasons: ["scheduledCommands"] } : {}),
      expectedGeneration: options.expectedGeneration ?? null,
      currentGeneration: options.currentGeneration ?? null,
    },
  );
}

export function applyPauseItemsFromVerdict(options: {
  readonly verdict: CapabilityDeactivationVerdict;
  readonly scheduledCommandStore: ScheduledCommandStore;
  readonly ruleStore: AutomationRuleStore;
  readonly activeTimerIdentity?: string | null;
  readonly activeConnectionScopes?: readonly string[];
}): { readonly ok: boolean; readonly pausedQuickActionIds: readonly string[] } {
  const timerItems = new Map(options.verdict.itemsToPause.filter((i) => i.kind === "waitingTimer" || i.kind === "missedTimer" || i.kind === "foreignTimer").map((i) => [i.id, i] as const));
  if (timerItems.size > 0) {
    const activeScopes = options.activeConnectionScopes ?? [];
    const activeTimerScope = options.activeTimerIdentity ? parseTimerIdentityScope(options.activeTimerIdentity) : null;
    for (const [identity, queue] of options.scheduledCommandStore.entries()) {
      const queueScope = parseTimerIdentityScope(identity);
      const isActive =
        options.activeTimerIdentity !== undefined
          ? identity === options.activeTimerIdentity ||
            (queueScope !== null && queueScope.startsWith("ha:") && activeTimerScope === queueScope)
          : true;
      const paused = (queue.pausedScheduledCommands ??= []);
      const moveFrom = (list: readonly ScheduledCommand[], orig: "waiting" | "missed") => list.filter((cmd) => {
        const hit = timerItems.get(cmd.id);
        if (!hit) return true;
        const fullScopes = cmd.sourceScopes?.length
          ? [...new Set([...cmd.sourceScopes, ...hit.connectionScopes])]
          : isActive
            ? [...new Set([...activeScopes, ...hit.connectionScopes])]
            : [...new Set([...(queueScope ? [queueScope] : []), ...hit.connectionScopes])];
        const stampedCmd: ScheduledCommand = cmd.sourceScopes?.length ? cmd : { ...cmd, sourceScopes: fullScopes };
        paused.push({ command: stampedCmd, originalPartition: orig, sourceScopes: fullScopes, pausedCapabilities: hit.affectedCapabilities });
        return false;
      });
      queue.scheduledCommands = moveFrom(queue.scheduledCommands, "waiting");
      queue.missedScheduledCommands = moveFrom(queue.missedScheduledCommands, "missed");
    }
    if (!options.scheduledCommandStore.persist()) {
      return { ok: false, pausedQuickActionIds: [] };
    }
  }
  const rulePauseMap = new Map(options.verdict.itemsToPause.filter((i) => i.kind === "automationRule").map((i) => [i.id, [...new Set([...i.affectedCapabilities, ...i.connectionScopes])]] as const));
  if (rulePauseMap.size > 0) {
    const saved = options.ruleStore.save(options.ruleStore.load().map((rule) => {
      const reasons = rulePauseMap.get(rule.id);
      return reasons && rule.isEnabled ? { ...rule, isEnabled: false, pausedByCapabilities: [...new Set([...(rule.pausedByCapabilities ?? []), ...reasons])] } : rule;
    }));
    if (!saved) {
      return { ok: false, pausedQuickActionIds: [] };
    }
  }
  return {
    ok: true,
    pausedQuickActionIds: options.verdict.itemsToPause.filter((i) => i.kind === "quickAction").map((i) => i.id),
  };
}

export function revalidateAfterMiAccountReenable(options: {
  readonly context: HostCapabilityContextInput;
  readonly scheduledCommandStore: ScheduledCommandStore;
  readonly activeTimerIdentity: string | null;
  readonly ruleStore: AutomationRuleStore;
  readonly nowMs?: number;
  readonly storage?: StorageLike | null;
  readonly completedScopes?: ReadonlySet<string>;
  readonly completedHaScopes?: ReadonlySet<string>;
  readonly hasLiveHaSnapshot?: boolean;
}): boolean {
  const nowEpochSeconds = Math.floor((options.nowMs ?? Date.now()) / 1000);
  const completedMiScopes = new Set<string>();
  const completedHaScopes = new Set<string>();
  for (const raw of options.completedScopes ?? []) {
    if (raw.startsWith("ha:")) completedHaScopes.add(normalizeHaScopeString(raw));
    else completedMiScopes.add(miAccountScope(raw));
  }
  for (const raw of options.completedHaScopes ?? []) {
    completedHaScopes.add(normalizeHaScopeString(raw));
  }
  const effectiveKnownDisabled =
    completedMiScopes.size > 0
      ? options.context.state.knownDisabledDevices.filter((d) => !completedMiScopes.has(miAccountScope(d.accountId)))
      : options.context.state.knownDisabledDevices;
  const effectiveKnownDisabledScenes =
    completedMiScopes.size > 0
      ? options.context.state.knownDisabledScenes.filter((s) => !completedMiScopes.has(miAccountScope(s.accountId)))
      : options.context.state.knownDisabledScenes;
  const effectivePendingScopes =
    completedMiScopes.size > 0
      ? new Set([...options.context.state.pendingRevalidationAccountIds].filter((s) => !completedMiScopes.has(miAccountScope(s))))
      : options.context.state.pendingRevalidationAccountIds;
  const effectiveKnownDisabledHa =
    completedHaScopes.size > 0
      ? options.context.state.knownDisabledHaDevices.filter((d) => !completedHaScopes.has(normalizeHaScopeString(d.scope)))
      : options.context.state.knownDisabledHaDevices;
  const effectiveKnownDisabledHaScenes =
    completedHaScopes.size > 0
      ? options.context.state.knownDisabledHaScenes.filter((s) => !completedHaScopes.has(normalizeHaScopeString(s.scope)))
      : options.context.state.knownDisabledHaScenes;
  const effectivePendingHaScopes =
    completedHaScopes.size > 0
      ? new Set([...options.context.state.pendingRevalidationHaScopes].filter((s) => !completedHaScopes.has(normalizeHaScopeString(s))))
      : options.context.state.pendingRevalidationHaScopes;

  const hasLiveXiaomiSnapshot =
    options.context.connectionMode === "xiaomiCloud" ||
    options.context.dualSourceEnabled ||
    options.context.connectionMode === "demo";
  const configuredMiScopes = options.context.accounts.map((acc) => miAccountScope(acc.id));
  const configuredMiScopeSet = new Set(configuredMiScopes);
  const currentHaScope = haConnectionScope(options.context.haBaseURL, options.context.haToken);
  const haModeActive =
    Boolean(currentHaScope) &&
    (options.context.connectionMode === "homeAssistant" || options.context.dualSourceEnabled);
  const hasLiveHaSnapshot =
    options.hasLiveHaSnapshot !== undefined
      ? options.hasLiveHaSnapshot
      : haModeActive || options.context.connectionMode === "demo";
  const unverifiedMiScopes = new Set<string>([
    ...options.context.state.disabledAccountIds,
    ...effectivePendingScopes,
    ...(!hasLiveXiaomiSnapshot ? configuredMiScopes : []),
  ]);
  const unverifiedHaScopes = new Set<string>([
    ...options.context.state.disabledHaScopes,
    ...effectivePendingHaScopes,
    ...(!hasLiveHaSnapshot && currentHaScope ? [currentHaScope] : []),
  ]);
  const isSignedOutMiScope = (s: string): boolean =>
    s.startsWith("mi:") && !configuredMiScopeSet.has(s) && !unverifiedMiScopes.has(s);
  const isSignedOutHaScope = (s: string): boolean =>
    s.startsWith("ha:") && normalizeHaScopeString(s) !== currentHaScope && !unverifiedHaScopes.has(normalizeHaScopeString(s));
  const isSignedOutScope = (s: string): boolean => isSignedOutMiScope(s) || isSignedOutHaScope(s);

  const effectiveEnabledScopes = options.context.state.selection.enabledConnectionScopes.filter(
    (s) => !unverifiedMiScopes.has(s) && !unverifiedHaScopes.has(s),
  );
  const effectiveSelection: CapabilitySelection = {
    ...options.context.state.selection,
    enabledConnections: options.context.state.selection.enabledConnections.filter((c) => {
      if (c === "xiaomi-cloud") {
        return effectiveEnabledScopes.some((s) => s.startsWith("mi:")) || options.context.connectionMode === "demo";
      }
      if (c === "home-assistant") {
        return effectiveEnabledScopes.some((s) => s.startsWith("ha:")) || options.context.connectionMode === "demo";
      }
      return true;
    }),
    enabledConnectionScopes: effectiveEnabledScopes,
  };
  const effectiveState: MiAccountSelectionState = {
    ...options.context.state,
    selection: effectiveSelection,
    disabledAccountIds: unverifiedMiScopes,
    disabledHaScopes: unverifiedHaScopes,
    knownDisabledDevices: effectiveKnownDisabled,
    knownDisabledScenes: effectiveKnownDisabledScenes,
    knownDisabledHaDevices: effectiveKnownDisabledHa,
    knownDisabledHaScenes: effectiveKnownDisabledHaScenes,
    pendingRevalidationAccountIds: effectivePendingScopes,
    pendingRevalidationHaScopes: effectivePendingHaScopes,
  };
  const effectiveContext: HostCapabilityContextInput = {
    ...options.context,
    state: effectiveState,
  };
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(effectiveContext);
  const selection = effectiveState.selection;
  const availSet = new Set(partitionCapabilityDevices(indexedDevices, selection, EMPTY_SAFETY_POLICY).availableDeviceIds);
  const devById = new Map(indexedDevices.map((d) => [d.id, d] as const));
  const enabledSceneIds = new Set(
    sceneRefs
      .filter((sc) =>
        evaluateControlTargetGate({
          targetKind: "scene",
          targetId: sc.id,
          selection,
          devices: indexedDevices,
          scenes: sceneRefs,
        }).allowed,
      )
      .map((sc) => sc.id),
  );

  const activeTimerScope = options.activeTimerIdentity ? parseTimerIdentityScope(options.activeTimerIdentity) : null;
  const timerSnapshot = options.scheduledCommandStore.snapshotQueues();
  let timersMutated = false;
  for (const [identity, queue] of options.scheduledCommandStore.entries()) {
    const pausedList = queue.pausedScheduledCommands ?? [];
    if (pausedList.length === 0) continue;
    const queueScope = parseTimerIdentityScope(identity);
    const isSameHaScopeAsActive = Boolean(
      queueScope && queueScope.startsWith("ha:") && activeTimerScope === queueScope && options.activeTimerIdentity !== null,
    );
    const isActiveQueue = identity === options.activeTimerIdentity || isSameHaScopeAsActive;
    const isSignedOutQueue = queueScope !== null && isSignedOutScope(queueScope);
    const activeScopes =
      isActiveQueue
        ? (identity === "demo"
            ? ["demo", ...selection.enabledConnectionScopes]
            : [...new Set([...selection.enabledConnectionScopes, ...configuredMiScopes])])
        : queueScope && selection.enabledConnectionScopes.includes(queueScope)
          ? [queueScope]
          : [];
    const stillPaused: PausedScheduledCommand[] = [];
    for (const paused of pausedList) {
      const timerScopes = paused.sourceScopes.length > 0 ? paused.sourceScopes : queueScope ? [queueScope] : [];
      const pausedCapScopes = (paused.pausedCapabilities ?? []).filter((c) => c.startsWith("mi:") || c.startsWith("ha:"));
      const candidateScopes = [...new Set([...(queueScope ? [queueScope] : []), ...timerScopes, ...pausedCapScopes])];
      const candidateMiScopes = candidateScopes.filter((s) => s.startsWith("mi:"));
      const candidateHaScopes = candidateScopes.filter((s) => s.startsWith("ha:")).map(normalizeHaScopeString);
      const waitsOnPendingMi =
        (queueScope !== null && effectivePendingScopes.has(queueScope)) ||
        timerScopes.some((s) => effectivePendingScopes.has(s)) ||
        (paused.pausedCapabilities ?? []).some(
          (c) =>
            effectivePendingScopes.has(c) ||
            (c === "xiaomi-cloud" &&
              effectivePendingScopes.size > 0 &&
              (candidateMiScopes.length === 0 || candidateMiScopes.some((s) => !isSignedOutMiScope(s)))),
        );
      const waitsOnPendingHa =
        (queueScope !== null && effectivePendingHaScopes.has(queueScope)) ||
        timerScopes.some((s) => s.startsWith("ha:") && effectivePendingHaScopes.has(normalizeHaScopeString(s))) ||
        (paused.pausedCapabilities ?? []).some(
          (c) =>
            (c.startsWith("ha:") && effectivePendingHaScopes.has(normalizeHaScopeString(c))) ||
            (c === "home-assistant" &&
              (effectivePendingHaScopes.size > 0 || (!hasLiveHaSnapshot && Boolean(currentHaScope))) &&
              (candidateHaScopes.length === 0 || candidateHaScopes.some((s) => !isSignedOutHaScope(s)))),
        );
      if (waitsOnPendingMi || waitsOnPendingHa) {
        stillPaused.push(paused);
        continue;
      }
      const signedOutForTimer = candidateScopes.filter(isSignedOutScope);
      const releasingSignedOut = signedOutForTimer.length > 0;
      const evalTimerScopes = timerScopes.length > 0 ? timerScopes : signedOutForTimer;
      const evalActiveScopes = releasingSignedOut
        ? [
            ...new Set([
              ...activeScopes.filter((s) => !s.startsWith("ha:") || evalTimerScopes.includes(s)),
              ...signedOutForTimer,
              ...evalTimerScopes.filter((s) => selection.enabledConnectionScopes.includes(s)),
            ]),
          ]
        : activeScopes;
      const evalSelection: CapabilitySelection = releasingSignedOut
        ? {
            ...selection,
            enabledConnections: [
              ...new Set<ConnectionCapabilityID>([
                ...selection.enabledConnections,
                ...(signedOutForTimer.some((s) => s.startsWith("mi:")) ? (["xiaomi-cloud"] as const) : []),
                ...(signedOutForTimer.some((s) => s.startsWith("ha:")) ? (["home-assistant"] as const) : []),
              ]),
            ],
            enabledConnectionScopes: [...new Set([...selection.enabledConnectionScopes, ...signedOutForTimer])],
          }
        : selection;
      const disp = revalidatePausedTimer({
        timer: {
          id: paused.command.id,
          name: paused.command.command,
          partition: isActiveQueue || isSignedOutQueue || releasingSignedOut ? paused.originalPartition : "foreign",
          targetIds: (paused.command.intents ?? []).map((i) => i.targetId),
          sourceScopes: evalTimerScopes,
          pausedCapabilities: paused.pausedCapabilities as readonly CapabilityID[],
        },
        fireAtEpochSeconds: Math.floor(paused.command.fireTimestampMs / 1000),
        nowEpochSeconds,
        activeConnectionScopes: evalActiveScopes,
        selection: evalSelection,
        devices: indexedDevices,
        scenes: sceneRefs,
      });
      if (disp === "keepPaused" || disp === "partitionForeign") { stillPaused.push(paused); continue; }
      timersMutated = true;
      const destQueue =
        isSameHaScopeAsActive && identity !== options.activeTimerIdentity && options.activeTimerIdentity !== null
          ? options.scheduledCommandStore.queue(options.activeTimerIdentity)
          : queue;
      if (disp === "armWaiting" && paused.originalPartition === "waiting" && !isSignedOutQueue) destQueue.scheduledCommands.push(paused.command);
      else destQueue.missedScheduledCommands.push(paused.command);
    }
    queue.pausedScheduledCommands = stillPaused;
  }
  if (timersMutated && !options.scheduledCommandStore.persist()) {
    options.scheduledCommandStore.restoreQueues(timerSnapshot);
    return false;
  }

  const disabledDevIds = new Set([
    ...effectiveKnownDisabled.map((d) => d.id),
    ...effectiveKnownDisabledHa.map((d) => d.id),
  ]);
  const disabledSceneIds = new Set([
    ...effectiveKnownDisabledScenes.map((s) => s.id),
    ...effectiveKnownDisabledHaScenes.map((s) => s.id),
  ]);
  let rulesMutated = false;
  const resumedRules = options.ruleStore.load().map((rule) => {
    if (!rule.pausedByCapabilities?.length) return rule;
    const scopes = rule.pausedByCapabilities.filter((c) => c.startsWith("mi:") || c.startsWith("ha:"));
    if (scopes.some((s) => unverifiedMiScopes.has(s) || (s.startsWith("ha:") && unverifiedHaScopes.has(normalizeHaScopeString(s))))) {
      return rule;
    }
    if (
      rule.pausedByCapabilities.includes("xiaomi-cloud") &&
      (effectivePendingScopes.size > 0 || (!hasLiveXiaomiSnapshot && configuredMiScopes.length > 0))
    ) {
      return rule;
    }
    if (
      rule.pausedByCapabilities.includes("home-assistant") &&
      (effectivePendingHaScopes.size > 0 || (!hasLiveHaSnapshot && Boolean(currentHaScope)) || unverifiedHaScopes.size > 0)
    ) {
      return rule;
    }
    const allSignedOutReasons =
      (scopes.length > 0 && scopes.every(isSignedOutScope)) ||
      (scopes.length === 0 &&
        rule.pausedByCapabilities.includes("xiaomi-cloud") &&
        configuredMiScopes.length === 0 &&
        unverifiedMiScopes.size === 0) ||
      (scopes.length === 0 &&
        rule.pausedByCapabilities.includes("home-assistant") &&
        currentHaScope === null &&
        unverifiedHaScopes.size === 0);
    if (rule.action.kind === "devices") {
      const allAvail = rule.action.deviceIds.length > 0 && rule.action.deviceIds.every((id) => availSet.has(id));
      if (!allAvail) {
        if (allSignedOutReasons && !rule.action.deviceIds.some((id) => disabledDevIds.has(id))) {
          rulesMutated = true;
          const { pausedByCapabilities: _c, ...rest } = rule;
          return { ...rest, isEnabled: false };
        }
        return rule;
      }
    }
    if (rule.action.kind === "scene" && !enabledSceneIds.has(rule.action.sceneId)) {
      if (allSignedOutReasons && !disabledSceneIds.has(rule.action.sceneId)) {
        rulesMutated = true;
        const { pausedByCapabilities: _c, ...rest } = rule;
        return { ...rest, isEnabled: false };
      }
      return rule;
    }
    if (rule.action.kind === "quickAction") {
      if (effectivePendingScopes.size > 0 || effectivePendingHaScopes.size > 0) return rule;
      const cats: readonly DeviceCategoryID[] = QUICK_ACTION_TARGET_CATEGORIES[rule.action.quickAction] ?? [];
      const hasCat = [...availSet].some((id) => {
        const dev = devById.get(id);
        return (
          dev !== undefined &&
          cats.includes(dev.category) &&
          (dev.connection !== "xiaomi-cloud" || hasLiveXiaomiSnapshot) &&
          (dev.connection !== "home-assistant" || hasLiveHaSnapshot)
        );
      });
      const remainingDisabledHasCat =
        effectiveKnownDisabled.some((d) => cats.includes(d.category)) ||
        effectiveKnownDisabledHa.some((d) => cats.includes(d.category)) ||
        (!hasLiveXiaomiSnapshot && options.context.state.disabledAccountIds.size > 0) ||
        (!hasLiveHaSnapshot && options.context.state.disabledHaScopes.size > 0);
      if (!hasCat && remainingDisabledHasCat) return rule;
    }
    rulesMutated = true;
    const { pausedByCapabilities: _c, ...rest } = rule;
    return { ...rest, isEnabled: true };
  });
  if (rulesMutated && !options.ruleStore.save(resumedRules)) {
    return false;
  }

  const restoredQa = new Set<string>();
  if (effectivePendingScopes.size === 0 && effectivePendingHaScopes.size === 0) {
    for (const qaId of effectiveState.pausedQuickActionIds) {
      const cats: readonly DeviceCategoryID[] = QUICK_ACTION_TARGET_CATEGORIES[qaId as QuickActionReferenceKind] ?? [];
      const availHasCategory = [...availSet].some((id) => {
        const dev = devById.get(id);
        return (
          dev !== undefined &&
          cats.includes(dev.category) &&
          (dev.connection !== "xiaomi-cloud" || hasLiveXiaomiSnapshot) &&
          (dev.connection !== "home-assistant" || hasLiveHaSnapshot)
        );
      });
      const remainingDisabledHasCategory =
        effectiveKnownDisabled.some((d) => cats.includes(d.category)) ||
        effectiveKnownDisabledHa.some((d) => cats.includes(d.category)) ||
        (!hasLiveXiaomiSnapshot && options.context.state.disabledAccountIds.size > 0) ||
        (!hasLiveHaSnapshot && options.context.state.disabledHaScopes.size > 0);
      if (availHasCategory || !remainingDisabledHasCategory) restoredQa.add(qaId);
    }
  }
  if (completedMiScopes.size > 0 || completedHaScopes.size > 0 || restoredQa.size > 0) {
    const wroteSelection = writeMiAccountSelectionMutation({
      storage: options.storage,
      mutate: (prev) => ({
        ...prev,
        pendingRevalidationAccountIds:
          completedMiScopes.size > 0
            ? prev.pendingRevalidationAccountIds.filter((id) => !completedMiScopes.has(miAccountScope(id)))
            : prev.pendingRevalidationAccountIds,
        knownDisabledDevices:
          completedMiScopes.size > 0
            ? prev.knownDisabledDevices.filter((d) => !completedMiScopes.has(miAccountScope(d.accountId)))
            : prev.knownDisabledDevices,
        knownDisabledScenes:
          completedMiScopes.size > 0
            ? prev.knownDisabledScenes.filter((s) => !completedMiScopes.has(miAccountScope(s.accountId)))
            : prev.knownDisabledScenes,
        pendingRevalidationHaScopes:
          completedHaScopes.size > 0
            ? prev.pendingRevalidationHaScopes.filter((s) => !completedHaScopes.has(normalizeHaScopeString(s)))
            : prev.pendingRevalidationHaScopes,
        knownDisabledHaDevices:
          completedHaScopes.size > 0
            ? prev.knownDisabledHaDevices.filter((d) => !completedHaScopes.has(normalizeHaScopeString(d.scope)))
            : prev.knownDisabledHaDevices,
        knownDisabledHaScenes:
          completedHaScopes.size > 0
            ? prev.knownDisabledHaScenes.filter((s) => !completedHaScopes.has(normalizeHaScopeString(s.scope)))
            : prev.knownDisabledHaScenes,
        pausedQuickActionIds:
          restoredQa.size > 0
            ? prev.pausedQuickActionIds.filter((id) => !restoredQa.has(id))
            : prev.pausedQuickActionIds,
      }),
    });
    if (!wroteSelection) return false;
  }
  return true;
}

/**
 * One identifier space for a disabled Xiaomi device snapshot: the card id, the raw did, every entity/action id
 * collected at snapshot time, and the `miot:<did>:` property forms. Direct writes (`evaluateDeviceEntityWriteGate`)
 * and URL commands must agree on it, or a link reports "missing device" for a device the panel can name.
 */
function disabledDeviceIdentifierMatches(rec: DisabledMiDeviceSnapshot, targetIdOrEntityId: string): boolean {
  const base = targetIdOrEntityId.split("#")[0] ?? targetIdOrEntityId;
  return (
    rec.id === targetIdOrEntityId || rec.id === base || rec.rawDid === targetIdOrEntityId || rec.rawDid === base ||
    rec.entityIds.includes(targetIdOrEntityId) || rec.entityIds.includes(base) ||
    base.startsWith(`${rec.id}.`) || base.startsWith(`${rec.rawDid}.`) || base.startsWith(`miot:${rec.id}:`) || base.startsWith(`miot:${rec.rawDid}:`)
  );
}

/** `menumijia://toggle?device=` also accepts the display name; compare it like `resolveTarget` does elsewhere. */
function disabledDeviceNameMatches(rec: { readonly name: string; readonly aliasName?: string }, targetName: string): boolean {
  const wanted = normalizeSceneName(targetName).toLocaleLowerCase();
  if (wanted.length === 0) return false;
  if (normalizeSceneName(rec.name).toLocaleLowerCase() === wanted) return true;
  if (rec.aliasName && normalizeSceneName(rec.aliasName).toLocaleLowerCase() === wanted) return true;
  return false;
}

function disabledHaDeviceIdentifierMatches(rec: DisabledHaDeviceSnapshot, targetIdOrEntityId: string): boolean {
  const trimmed = targetIdOrEntityId.trim();
  if (!trimmed) return false;
  const base = trimmed.split("#")[0] ?? trimmed;
  const stripped = stripHaCardPrefix(base);
  const lowerTrimmed = trimmed.toLowerCase();
  const lowerBase = base.toLowerCase();
  const lowerStripped = stripped.toLowerCase();
  if (
    rec.id === trimmed || rec.id === base || rec.rawHaId === trimmed || rec.rawHaId === base || rec.rawHaId === stripped ||
    rec.id.toLowerCase() === lowerTrimmed || rec.id.toLowerCase() === lowerBase ||
    rec.rawHaId.toLowerCase() === lowerBase || rec.rawHaId.toLowerCase() === lowerStripped
  ) {
    return true;
  }
  return rec.entityIds.some((eid) => {
    const lowerEid = eid.toLowerCase();
    return eid === trimmed || eid === base || eid === stripped || lowerEid === lowerTrimmed || lowerEid === lowerBase || lowerEid === lowerStripped;
  });
}

export function resolveDisabledDeviceByEntity(entityId: string, knownDisabledDevices: readonly DisabledMiDeviceSnapshot[]): DisabledMiDeviceSnapshot | null {
  return knownDisabledDevices.find((rec) => disabledDeviceIdentifierMatches(rec, entityId)) ?? null;
}

function hiddenTypeDeviceIdentifierMatches(rec: CapabilityIndexedDevice, targetIdOrEntityId: string): boolean {
  const base = targetIdOrEntityId.split("#")[0] ?? targetIdOrEntityId;
  // A multi-account card is `<accountId>/<raw did>`; the index entry keeps the raw did.
  const wanted = [base, MiAccountScope.localId(base)];
  const ids = [rec.id, MiAccountScope.localId(rec.id)];
  return wanted.some(
    (target) =>
      ids.includes(target) ||
      ids.some((id) => target.startsWith(`${id}.`) || target.startsWith(`miot:${id}:`) || target.startsWith(`miot-action:${id}:`)),
  );
}

/**
 * A device whose type is turned off. It is still in the identity index, so the host must answer
 * "该设备类型已关闭" rather than "设备不存在" for an old link, timer or AI intent (architecture.md §D).
 */
export function resolveHiddenTypeDeviceByEntity(
  entityId: string,
  hiddenDevices: readonly CapabilityIndexedDevice[] | undefined,
): CapabilityIndexedDevice | null {
  return hiddenDevices?.find((rec) => hiddenTypeDeviceIdentifierMatches(rec, entityId)) ?? null;
}

export function resolveDisabledHaDeviceByEntity(
  entityId: string,
  knownDisabledHaDevices: readonly DisabledHaDeviceSnapshot[],
  disabledHaScopes?: ReadonlySet<string>,
): DisabledHaDeviceSnapshot | null {
  return (
    knownDisabledHaDevices.find(
      (rec) =>
        (!disabledHaScopes || disabledHaScopes.has(normalizeHaScopeString(rec.scope))) &&
        disabledHaDeviceIdentifierMatches(rec, entityId),
    ) ?? null
  );
}

export function resolveDisabledSceneByTarget(
  targetIdOrEntityId: string,
  knownDisabledScenes: readonly DisabledMiSceneSnapshot[],
  disabledAccountIds?: ReadonlySet<string>,
): DisabledMiSceneSnapshot | null {
  return (
    knownDisabledScenes.find((rec) => {
      if (disabledAccountIds && !disabledAccountIds.has(miAccountScope(rec.accountId))) return false;
      if (rec.id === targetIdOrEntityId || MiAccountScope.localId(rec.id) === targetIdOrEntityId) return true;
      if (rec.entityId !== undefined && (rec.entityId === targetIdOrEntityId || MiAccountScope.localId(rec.entityId) === targetIdOrEntityId)) return true;
      return false;
    }) ?? null
  );
}

export function resolveDisabledHaSceneByTarget(
  targetIdOrEntityId: string,
  knownDisabledHaScenes: readonly DisabledHaSceneSnapshot[],
  disabledHaScopes?: ReadonlySet<string>,
): DisabledHaSceneSnapshot | null {
  const trimmed = targetIdOrEntityId.trim();
  if (!trimmed) return null;
  const stripped = stripHaCardPrefix(trimmed);
  const lowerTrimmed = trimmed.toLowerCase();
  const lowerStripped = stripped.toLowerCase();
  return (
    knownDisabledHaScenes.find((rec) => {
      if (disabledHaScopes && !disabledHaScopes.has(normalizeHaScopeString(rec.scope))) return false;
      if (
        rec.id === trimmed ||
        rec.id === stripped ||
        rec.id.toLowerCase() === lowerTrimmed ||
        rec.id.toLowerCase() === lowerStripped
      ) {
        return true;
      }
      if (rec.entityId !== undefined) {
        const lowerEntity = rec.entityId.toLowerCase();
        if (rec.entityId === trimmed || rec.entityId === stripped || lowerEntity === lowerTrimmed || lowerEntity === lowerStripped) {
          return true;
        }
      }
      return false;
    }) ?? null
  );
}

export interface WriteGateRejectionVerdict {
  readonly reason: ControlTargetRejectionReason;
  readonly message: string;
}

function looksLikeUnattributedHaTarget(targetIdOrEntityId: string): boolean {
  const trimmed = targetIdOrEntityId.trim();
  if (!trimmed) return false;
  if (
    MiAccountScope.owner(trimmed) !== null ||
    trimmed.startsWith("miot:") ||
    trimmed.startsWith("lg:") ||
    trimmed.startsWith("lgtv:") ||
    /^\d+(?:\.\d+)*(?:#.*)?$/.test(trimmed)
  ) {
    return false;
  }
  if (trimmed.startsWith("ha:")) return true;
  const base = trimmed.split("#", 1)[0] ?? trimmed;
  return /^[a-z_][a-z0-9_]*\.[a-z0-9_]+$/i.test(base);
}

function toWriteGateVerdict(
  reason: ControlTargetRejectionReason | null,
  pref?: LanguagePreference,
): WriteGateRejectionVerdict | null {
  if (!reason) return null;
  return {
    reason,
    message: controlTargetRejectionMessage(reason, pref),
  };
}

export function evaluateDeviceEntityWriteGateVerdict(options: {
  readonly targetKind: ControlTargetKind;
  readonly targetIdOrEntityId: string;
  readonly resolvedActiveDeviceId: string | null;
  readonly context: HostCapabilityContextInput;
  readonly languagePreference?: LanguagePreference;
  readonly rejectUnknown?: boolean;
}): WriteGateRejectionVerdict | null {
  const pref = effectivePref(options.languagePreference);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  const currentHaScope = haConnectionScope(options.context.haBaseURL, options.context.haToken);
  const isCurrentHaDisabled = Boolean(currentHaScope && options.context.state.disabledHaScopes.has(currentHaScope));
  const hasNoHaSnapshotsForScope =
    currentHaScope !== null &&
    !options.context.state.knownDisabledHaDevices.some((d) => normalizeHaScopeString(d.scope) === currentHaScope) &&
    !options.context.state.knownDisabledHaScenes.some((s) => normalizeHaScopeString(s.scope) === currentHaScope);
  if (options.targetKind === "scene") {
    const lowerTarget = options.targetIdOrEntityId.toLowerCase();
    const matched = options.context.scenes.find(
      (s) =>
        s.id === options.targetIdOrEntityId ||
        s.entityId === options.targetIdOrEntityId ||
        s.id.toLowerCase() === lowerTarget ||
        s.entityId.toLowerCase() === lowerTarget,
    );
    const disabledScene = matched
      ? null
      : resolveDisabledSceneByTarget(options.targetIdOrEntityId, options.context.state.knownDisabledScenes, options.context.state.disabledAccountIds);
    const disabledHaScene =
      matched || disabledScene
        ? null
        : resolveDisabledHaSceneByTarget(
            options.targetIdOrEntityId,
            options.context.state.knownDisabledHaScenes,
            options.context.state.disabledHaScopes,
          );
    const targetSceneId = matched?.id ?? disabledScene?.id ?? disabledHaScene?.id ?? null;
    if (targetSceneId === null) {
      const scopedOwner = MiAccountScope.owner(options.targetIdOrEntityId);
      if (scopedOwner && options.context.state.disabledAccountIds.has(miAccountScope(scopedOwner))) {
        return toWriteGateVerdict(
          { code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: miAccountScope(scopedOwner) },
          pref,
        );
      }
      if (isCurrentHaDisabled && hasNoHaSnapshotsForScope && looksLikeUnattributedHaTarget(options.targetIdOrEntityId)) {
        return toWriteGateVerdict(
          { code: "connectionScopeDisabled", connection: "home-assistant", scope: currentHaScope! },
          pref,
        );
      }
      return options.rejectUnknown ? toWriteGateVerdict({ code: "sceneNotFound" }, pref) : null;
    }
    const v = evaluateControlTargetGate({ targetKind: "scene", targetId: targetSceneId, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
    return v.allowed ? null : toWriteGateVerdict(v.rejectionReason, pref);
  }
  const disabledMatch =
    options.resolvedActiveDeviceId === null
      ? resolveDisabledDeviceByEntity(options.targetIdOrEntityId, options.context.state.knownDisabledDevices)
      : null;
  const disabledHaMatch =
    options.resolvedActiveDeviceId === null && disabledMatch === null
      ? resolveDisabledHaDeviceByEntity(
          options.targetIdOrEntityId,
          options.context.state.knownDisabledHaDevices,
          options.context.state.disabledHaScopes,
        )
      : null;
  const hiddenTypeMatch =
    options.resolvedActiveDeviceId === null && disabledMatch === null && disabledHaMatch === null
      ? resolveHiddenTypeDeviceByEntity(options.targetIdOrEntityId, options.context.hiddenDevices)
      : null;
  const targetId =
    options.resolvedActiveDeviceId ?? disabledMatch?.id ?? disabledHaMatch?.id ?? hiddenTypeMatch?.id ?? null;
  if (targetId === null) {
    const scopedOwner = MiAccountScope.owner(options.targetIdOrEntityId);
    if (scopedOwner && options.context.state.disabledAccountIds.has(miAccountScope(scopedOwner))) {
      return toWriteGateVerdict(
        { code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: miAccountScope(scopedOwner) },
        pref,
      );
    }
    if (isCurrentHaDisabled && hasNoHaSnapshotsForScope && looksLikeUnattributedHaTarget(options.targetIdOrEntityId)) {
      return toWriteGateVerdict(
        { code: "connectionScopeDisabled", connection: "home-assistant", scope: currentHaScope! },
        pref,
      );
    }
    return options.rejectUnknown ? toWriteGateVerdict({ code: "deviceNotFound" }, pref) : null;
  }
  const v = evaluateControlTargetGate({ targetKind: "device", targetId, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
  return v.allowed ? null : toWriteGateVerdict(v.rejectionReason, pref);
}

export function evaluateDeviceEntityWriteGate(options: {
  readonly targetKind: ControlTargetKind;
  readonly targetIdOrEntityId: string;
  readonly resolvedActiveDeviceId: string | null;
  readonly context: HostCapabilityContextInput;
  readonly languagePreference?: LanguagePreference;
  readonly rejectUnknown?: boolean;
}): string | null {
  return evaluateDeviceEntityWriteGateVerdict(options)?.message ?? null;
}

export function evaluateIntentsWriteGateVerdict(options: {
  readonly intents: readonly DeviceIntent[];
  readonly context: HostCapabilityContextInput;
  readonly languagePreference?: LanguagePreference;
}): WriteGateRejectionVerdict | null {
  if (options.intents.length === 0) return null;
  const pref = effectivePref(options.languagePreference);
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(options.context);
  const currentHaScope = haConnectionScope(options.context.haBaseURL, options.context.haToken);
  const isCurrentHaDisabled = Boolean(currentHaScope && options.context.state.disabledHaScopes.has(currentHaScope));
  const hasNoHaSnapshotsForScope =
    currentHaScope !== null &&
    !options.context.state.knownDisabledHaDevices.some((d) => normalizeHaScopeString(d.scope) === currentHaScope) &&
    !options.context.state.knownDisabledHaScenes.some((s) => normalizeHaScopeString(s.scope) === currentHaScope);
  const targets: Array<{ readonly kind: ControlTargetKind; readonly id: string }> = [];
  for (const i of options.intents) {
    if (i.operation.kind === "activateScene") {
      const lowerTarget = i.targetId.toLowerCase();
      const activeMatch = options.context.scenes.find(
        (s) => s.id === i.targetId || s.entityId === i.targetId || s.id.toLowerCase() === lowerTarget || s.entityId.toLowerCase() === lowerTarget,
      );
      const disabledMatch = activeMatch
        ? null
        : resolveDisabledSceneByTarget(i.targetId, options.context.state.knownDisabledScenes, options.context.state.disabledAccountIds);
      const disabledHaMatch =
        activeMatch || disabledMatch
          ? null
          : resolveDisabledHaSceneByTarget(i.targetId, options.context.state.knownDisabledHaScenes, options.context.state.disabledHaScopes);
      const resolvedId = activeMatch?.id ?? disabledMatch?.id ?? disabledHaMatch?.id ?? null;
      if (resolvedId === null) {
        const scopedOwner = MiAccountScope.owner(i.targetId);
        if (scopedOwner && options.context.state.disabledAccountIds.has(miAccountScope(scopedOwner))) {
          return toWriteGateVerdict(
            { code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: miAccountScope(scopedOwner) },
            pref,
          );
        }
        if (isCurrentHaDisabled && hasNoHaSnapshotsForScope && looksLikeUnattributedHaTarget(i.targetId)) {
          return toWriteGateVerdict(
            { code: "connectionScopeDisabled", connection: "home-assistant", scope: currentHaScope! },
            pref,
          );
        }
      }
      targets.push({ kind: "scene", id: resolvedId ?? i.targetId });
      continue;
    }
    const activeDev = options.context.devices.find((d) => d.id === i.targetId);
    const disabledDev = activeDev ? null : resolveDisabledDeviceByEntity(i.targetId, options.context.state.knownDisabledDevices);
    const disabledHaDev =
      activeDev || disabledDev
        ? null
        : resolveDisabledHaDeviceByEntity(i.targetId, options.context.state.knownDisabledHaDevices, options.context.state.disabledHaScopes);
    const hiddenTypeDev =
      activeDev || disabledDev || disabledHaDev
        ? null
        : resolveHiddenTypeDeviceByEntity(i.targetId, options.context.hiddenDevices);
    const resolvedId = activeDev?.id ?? disabledDev?.id ?? disabledHaDev?.id ?? hiddenTypeDev?.id ?? null;
    if (resolvedId === null) {
      const scopedOwner = MiAccountScope.owner(i.targetId);
      if (scopedOwner && options.context.state.disabledAccountIds.has(miAccountScope(scopedOwner))) {
        return toWriteGateVerdict(
          { code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: miAccountScope(scopedOwner) },
          pref,
        );
      }
      if (isCurrentHaDisabled && hasNoHaSnapshotsForScope && looksLikeUnattributedHaTarget(i.targetId)) {
        return toWriteGateVerdict(
          { code: "connectionScopeDisabled", connection: "home-assistant", scope: currentHaScope! },
          pref,
        );
      }
    }
    targets.push({ kind: "device", id: resolvedId ?? i.targetId });
  }
  const v = evaluatePlanTargetsGate({ targets, selection: options.context.state.selection, devices: indexedDevices, scenes: sceneRefs });
  return v.allowed ? null : toWriteGateVerdict(v.rejectionReason, pref);
}

export function evaluateIntentsWriteGate(options: { readonly intents: readonly DeviceIntent[]; readonly context: HostCapabilityContextInput; readonly languagePreference?: LanguagePreference }): string | null {
  return evaluateIntentsWriteGateVerdict(options)?.message ?? null;
}

function stubKindForDisabledCategory(category: DeviceCategoryID, entityId: string): DeviceKind {
  switch (category) {
    case "light":
      return {
        kind: "light",
        entityId,
        isOn: false,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      };
    case "climate":
      return {
        kind: "climate",
        entityId,
        isOn: false,
        hvacMode: "cool",
        availableModes: ["cool", "heat", "auto", "dry", "fan_only"],
        targetTemperature: 24,
        currentTemperature: 24,
        minTemp: 16,
        maxTemp: 30,
        step: 1,
        fanMode: "auto",
        availableFanModes: ["auto", "low", "medium", "high"],
      };
    case "fan":
      return {
        kind: "fan",
        entityId,
        isOn: false,
        percentage: 50,
        presetMode: null,
        availablePresetModes: [],
        isOscillating: false,
      };
    case "cover":
      return {
        kind: "cover",
        entityId,
        subtype: "curtain",
        positionPercent: 50,
        positionWritable: true,
        openDescription: "open",
        closeDescription: "close",
        pauseDescription: "stop",
        batteryPercent: null,
        faultText: null,
        motion: "stopped",
      };
    case "vacuum":
      return {
        kind: "vacuum",
        entityId,
        status: "docked",
        battery: 100,
        modeEntityId: null,
        currentMode: null,
        availableModes: [],
        actionsWritable: true,
      };
    case "camera":
      return {
        kind: "camera",
        entityId,
        isOn: true,
        nightShot: null,
        availableNightShots: [],
        motionDetectionEntityId: null,
        isMotionDetectionOn: null,
        streamEntityId: null,
      };
    default:
      return {
        kind: "plug",
        switchEntityId: entityId,
        isOn: false,
        powerWatts: null,
        childLockEntityId: null,
        isChildLocked: false,
      };
  }
}

export function evaluateDisabledUtteranceGate(options: {
  readonly utterance: string;
  readonly context: HostCapabilityContextInput;
  readonly aliases?: Readonly<Record<string, string>>;
  readonly languagePreference?: LanguagePreference;
}): string | null {
  const trimmed = options.utterance.trim();
  if (!trimmed) return null;
  if (options.context.connectionMode === "demo" && !options.context.dualSourceEnabled) return null;
  const { state } = options.context;
  const aliases = options.aliases ?? {};
  const buildStubDevices = (useAliases: boolean): SmartDevice[] => {
    const out: SmartDevice[] = [...options.context.devices];
    const seen = new Set(out.map((d) => d.id));
    for (const snap of state.knownDisabledDevices) {
      if (!state.disabledAccountIds.has(miAccountScope(snap.accountId)) || seen.has(snap.id)) continue;
      seen.add(snap.id);
      const displayName = useAliases ? (aliases[snap.id]?.trim() || snap.name) : snap.name;
      out.push({
        id: snap.id,
        name: displayName,
        roomId: "disabled",
        roomName: "",
        model: "disabled.mi",
        isOnline: true,
        kind: stubKindForDisabledCategory(snap.category, snap.entityIds[0] ?? snap.id),
      });
    }
    for (const snap of state.knownDisabledHaDevices) {
      const scope = normalizeHaScopeString(snap.scope);
      if (!state.disabledHaScopes.has(scope) || seen.has(snap.id)) continue;
      seen.add(snap.id);
      const displayName = useAliases
        ? ((aliases[snap.id] ?? aliases[snap.rawHaId] ?? snap.aliasName)?.trim() || snap.name)
        : snap.name;
      out.push({
        id: snap.id,
        name: displayName,
        roomId: "disabled",
        roomName: "",
        model: "disabled.ha",
        isOnline: true,
        kind: stubKindForDisabledCategory(snap.category, snap.entityIds[0] ?? snap.id),
      });
    }
    // A closed device type stays resolvable by voice so the answer names the type instead of
    // claiming the device never existed (architecture.md §D).
    for (const hidden of options.context.hiddenDevices ?? []) {
      if (seen.has(hidden.id)) continue;
      seen.add(hidden.id);
      const displayName = useAliases ? (aliases[hidden.id]?.trim() || hidden.name) : hidden.name;
      out.push({
        id: hidden.id,
        name: displayName,
        roomId: "disabled",
        roomName: "",
        model: "disabled.mi",
        isOnline: true,
        kind: stubKindForDisabledCategory(hidden.category, hidden.id),
      });
    }
    return out;
  };
  const stubDevices = buildStubDevices(true);
  const stubScenes: HomeScene[] = [...options.context.scenes];
  const seenSceneIds = new Set(stubScenes.map((s) => s.id));
  for (const snap of state.knownDisabledScenes) {
    if (!state.disabledAccountIds.has(miAccountScope(snap.accountId)) || seenSceneIds.has(snap.id)) continue;
    seenSceneIds.add(snap.id);
    stubScenes.push({ id: snap.id, name: snap.name, entityId: snap.entityId ?? snap.id });
  }
  for (const snap of state.knownDisabledHaScenes) {
    const scope = normalizeHaScopeString(snap.scope);
    if (!state.disabledHaScopes.has(scope) || seenSceneIds.has(snap.id)) continue;
    seenSceneIds.add(snap.id);
    stubScenes.push({ id: snap.id, name: snap.name, entityId: snap.entityId ?? snap.id });
  }
  if (stubDevices.length === options.context.devices.length && stubScenes.length === options.context.scenes.length) {
    return null;
  }
  const parsed =
    LocalIntentParser.parse(trimmed, stubDevices, stubScenes) ??
    LocalIntentParser.parse(trimmed, buildStubDevices(false), stubScenes);
  if (!parsed) return null;
  const candidateIntents =
    parsed.intents.length > 0
      ? parsed.intents
      : parsed.suggestions.flatMap((s) => s.intents);
  if (candidateIntents.length === 0) return null;
  return evaluateIntentsWriteGate({
    intents: candidateIntents,
    context: options.context,
    languagePreference: options.languagePreference,
  });
}

export function evaluateQuickActionSourceWriteGate(options: {
  readonly actionId: QuickActionId;
  readonly scopeDevices: readonly SmartDevice[];
  readonly lastManuallyUsedLightId?: string | null;
  readonly context: HostCapabilityContextInput;
  readonly languagePreference?: LanguagePreference;
}): string | null {
  if (options.context.connectionMode === "demo" && !options.context.dualSourceEnabled) return null;
  const pref = effectivePref(options.languagePreference);
  const { state } = options.context;
  const currentHaScope = haConnectionScope(options.context.haBaseURL ?? null, options.context.haToken ?? null);
  const haDisabled = currentHaScope !== null && state.disabledHaScopes.has(currentHaScope);
  const enabledMiCount = options.context.accounts.filter((a) => !state.disabledAccountIds.has(miAccountScope(a.id))).length;
  if (!options.context.dualSourceEnabled) {
    if (options.context.connectionMode === "homeAssistant" && haDisabled) {
      return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "home-assistant", scope: currentHaScope! }, pref);
    }
    if (options.context.connectionMode !== "homeAssistant" && options.context.accounts.length > 0 && enabledMiCount === 0) {
      const firstDisabled = options.context.accounts.find((a) => state.disabledAccountIds.has(miAccountScope(a.id)));
      return controlTargetRejectionMessage(
        { code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: miAccountScope(firstDisabled?.id ?? options.context.accounts[0]!.id) },
        pref,
      );
    }
  } else if (haDisabled && (options.context.accounts.length === 0 || enabledMiCount === 0)) {
    return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "home-assistant", scope: currentHaScope! }, pref);
  }
  const planned = planQuickAction(options.actionId, options.scopeDevices, options.lastManuallyUsedLightId ?? null);
  if (planned.targets.length === 0) return null;
  return evaluateIntentsWriteGate({
    intents: planned.targets.map((t) => ({ targetId: t.deviceId, operation: { kind: "power" as const, isOn: false } })),
    context: options.context,
    languagePreference: options.languagePreference,
  });
}

export function evaluateAutomationRuleWriteGate(options: {
  readonly rule: AutomationRule;
  readonly context: HostCapabilityContextInput;
  readonly lastManuallyUsedLightId?: string | null;
  readonly languagePreference?: LanguagePreference;
}): string | null {
  if (options.context.connectionMode === "demo" && !options.context.dualSourceEnabled) return null;
  const pref = effectivePref(options.languagePreference);
  const { state } = options.context;
  const currentHaScope = haConnectionScope(options.context.haBaseURL ?? null, options.context.haToken ?? null);
  if (options.rule.pausedByCapabilities?.length) {
    for (const cap of options.rule.pausedByCapabilities) {
      if (cap.startsWith("ha:")) {
        const normalized = normalizeHaScopeString(cap);
        if (state.disabledHaScopes.has(normalized)) {
          return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "home-assistant", scope: normalized }, pref);
        }
      } else if (cap === "home-assistant") {
        if ((currentHaScope && state.disabledHaScopes.has(currentHaScope)) || !state.selection.enabledConnections.includes("home-assistant")) {
          return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "home-assistant", scope: currentHaScope ?? "home-assistant" }, pref);
        }
      } else if (cap.startsWith("mi:")) {
        if (state.disabledAccountIds.has(cap)) {
          return controlTargetRejectionMessage({ code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: cap }, pref);
        }
      } else if (cap === "xiaomi-cloud") {
        if (!state.selection.enabledConnections.includes("xiaomi-cloud")) {
          return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "xiaomi-cloud", scope: "xiaomi-cloud" }, pref);
        }
      }
    }
  }
  const action = options.rule.action;
  if (action.kind === "devices") {
    return evaluateIntentsWriteGate({
      intents: action.deviceIds.map((id) => ({ targetId: id, operation: { kind: "power" as const, isOn: action.isOn } })),
      context: options.context,
      languagePreference: options.languagePreference,
    });
  }
  if (action.kind === "scene") {
    return evaluateIntentsWriteGate({
      intents: [{ targetId: action.sceneId, operation: { kind: "activateScene" as const } }],
      context: options.context,
      languagePreference: options.languagePreference,
    });
  }
  if (state.pausedQuickActionIds.has(action.quickAction)) {
    if (currentHaScope && state.disabledHaScopes.has(currentHaScope)) {
      return controlTargetRejectionMessage({ code: "connectionDisabled", connection: "home-assistant", scope: currentHaScope }, pref);
    }
    const firstDisabledMi = [...state.disabledAccountIds][0];
    if (firstDisabledMi) {
      return controlTargetRejectionMessage({ code: "connectionScopeDisabled", connection: "xiaomi-cloud", scope: firstDisabledMi }, pref);
    }
  }
  return evaluateQuickActionSourceWriteGate({
    actionId: action.quickAction,
    scopeDevices: options.context.devices,
    lastManuallyUsedLightId: options.lastManuallyUsedLightId,
    context: options.context,
    languagePreference: options.languagePreference,
  });
}

export function evaluateDisabledDeviceUrlGate(
  deviceIdOrName: string,
  settings: {
    readonly connectionMode?: string;
    readonly miSession?: MiSession | null;
    readonly haBaseURL?: string;
    readonly haToken?: string;
    readonly dualSourceEnabled?: boolean;
    readonly interfaceLanguage?: LanguagePreference;
    readonly deviceAliases?: Readonly<Record<string, string>>;
    /** The identity index of the cards the type selection withholds (P3a-W). */
    readonly hiddenDevices?: readonly CapabilityIndexedDevice[];
  },
  storage?: StorageLike | null,
): string | null {
  if (settings.connectionMode === "demo" && !settings.dualSourceEnabled) return null;
  const accounts = settings.miSession ? [makeMiAccount(settings.miSession)] : [];
  const mode = settings.connectionMode ?? "xiaomiCloud";
  const state = resolveMiAccountSelectionState({ storage, accounts, haBaseURL: settings.haBaseURL ?? null, haToken: settings.haToken ?? null, connectionMode: mode, dualSourceEnabled: Boolean(settings.dualSourceEnabled), hasExistingPreferences: true });
  const aliases = settings.deviceAliases ?? {};
  // The account check belongs inside the predicate: a same-named device on an enabled account must not shadow the
  // disabled one and turn this into a "device missing" answer.
  const miHit = state.knownDisabledDevices.find(
    (d) =>
      state.disabledAccountIds.has(miAccountScope(d.accountId)) &&
      (disabledDeviceIdentifierMatches(d, deviceIdOrName) ||
        disabledDeviceNameMatches(
          { name: d.name, ...(aliases[d.id] ? { aliasName: aliases[d.id] } : {}) },
          deviceIdOrName,
        )),
  );
  const haHit = miHit
    ? null
    : state.knownDisabledHaDevices.find(
        (d) =>
          state.disabledHaScopes.has(normalizeHaScopeString(d.scope)) &&
          (disabledHaDeviceIdentifierMatches(d, deviceIdOrName) ||
            disabledDeviceNameMatches(
              {
                name: d.name,
                ...(d.aliasName ?? aliases[d.id] ?? aliases[d.rawHaId]
                  ? { aliasName: d.aliasName ?? aliases[d.id] ?? aliases[d.rawHaId] }
                  : {}),
              },
              deviceIdOrName,
            )),
      );
  const hiddenHit = miHit || haHit
    ? null
    : (settings.hiddenDevices ?? []).find(
        (d) =>
          hiddenTypeDeviceIdentifierMatches(d, deviceIdOrName) ||
          disabledDeviceNameMatches(
            { name: d.name, ...(aliases[d.id] ? { aliasName: aliases[d.id] } : {}) },
            deviceIdOrName,
          ),
      );
  const pref = effectivePref(settings.interfaceLanguage);
  // A URL arrives without a host context, but the hidden index only ever holds cards the current
  // device-type selection withholds, so its category is the answer (architecture.md §D).
  if (hiddenHit) {
    return controlTargetRejectionMessage({ code: "categoryDisabled", disabledCategory: hiddenHit.category }, pref);
  }
  const hitId = miHit?.id ?? haHit?.id ?? null;
  if (!hitId) return null;
  const { indexedDevices } = buildIndexedCapabilityDevices({
    state, accounts, devices: [], scenes: [],
    haBaseURL: settings.haBaseURL ?? null, haToken: settings.haToken ?? null,
    connectionMode: mode, dualSourceEnabled: Boolean(settings.dualSourceEnabled),
  });
  const v = evaluateControlTargetGate({ targetKind: "device", targetId: hitId, selection: state.selection, devices: indexedDevices });
  return v.allowed || !v.rejectionReason ? null : controlTargetRejectionMessage(v.rejectionReason, pref);
}

export function evaluateDisabledSceneUrlGate(
  sceneNameOrId: string,
  settings: { readonly connectionMode?: string; readonly miSession?: MiSession | null; readonly haBaseURL?: string; readonly haToken?: string; readonly dualSourceEnabled?: boolean; readonly interfaceLanguage?: LanguagePreference },
  storage?: StorageLike | null,
): string | null {
  if (settings.connectionMode === "demo" && !settings.dualSourceEnabled) return null;
  const accounts = settings.miSession ? [makeMiAccount(settings.miSession)] : [];
  const mode = settings.connectionMode ?? "xiaomiCloud";
  const state = resolveMiAccountSelectionState({
    storage,
    accounts,
    haBaseURL: settings.haBaseURL ?? null,
    haToken: settings.haToken ?? null,
    connectionMode: mode,
    dualSourceEnabled: Boolean(settings.dualSourceEnabled),
    hasExistingPreferences: true,
  });
  const normalizedName = normalizeSceneName(sceneNameOrId).toLocaleLowerCase();
  const miHit = state.knownDisabledScenes.find(
    (s) =>
      state.disabledAccountIds.has(miAccountScope(s.accountId)) &&
      (s.id === sceneNameOrId ||
        MiAccountScope.localId(s.id) === sceneNameOrId ||
        (s.entityId !== undefined && (s.entityId === sceneNameOrId || MiAccountScope.localId(s.entityId) === sceneNameOrId)) ||
        (normalizedName.length > 0 && normalizeSceneName(s.name).toLocaleLowerCase() === normalizedName)),
  );
  const haHit = miHit
    ? null
    : state.knownDisabledHaScenes.find(
        (s) =>
          state.disabledHaScopes.has(normalizeHaScopeString(s.scope)) &&
          (resolveDisabledHaSceneByTarget(sceneNameOrId, [s], state.disabledHaScopes) !== null ||
            (normalizedName.length > 0 && normalizeSceneName(s.name).toLocaleLowerCase() === normalizedName)),
      );
  const hitId = miHit?.id ?? haHit?.id ?? null;
  if (!hitId) return null;
  const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices({
    state,
    accounts,
    devices: [],
    scenes: [],
    haBaseURL: settings.haBaseURL ?? null,
    haToken: settings.haToken ?? null,
    connectionMode: mode,
    dualSourceEnabled: Boolean(settings.dualSourceEnabled),
  });
  const v = evaluateControlTargetGate({ targetKind: "scene", targetId: hitId, selection: state.selection, devices: indexedDevices, scenes: sceneRefs });
  return v.allowed || !v.rejectionReason ? null : controlTargetRejectionMessage(v.rejectionReason, effectivePref(settings.interfaceLanguage));
}

