/**
 * Retryable connection-removal records (P2c-W).
 *
 * Removing a Xiaomi account or a Home Assistant connection is two phases: stop using the
 * connection, then delete the credentials it owns. Deleting can fail (credential manager locked,
 * native refusal, a crashed process), so the intent is written to disk *before* anything is
 * deleted and is only cleared once the deletion succeeded.
 *
 * While a record exists, its scope is excluded from the effective enabled set, so a restart can
 * never reconnect the connection that is still being removed, and a retry can resume the cleanup
 * without touching other accounts, the other data source or the assistant keys. The record carries
 * an owner version: a cleanup owned by an older intent stops instead of deleting a credential that
 * a newer intent (or a rebind) is responsible for.
 */

import { haConnectionScope } from "./haTransportGate.js";
import { defaultStorage, miAccountId } from "./pollingPolicy.js";
import {
  miAccountSessionCredentialName,
  normalizeMiCredentialSlotId,
  type SecureCredentialName,
} from "./secureStore.js";

export const CONNECTION_REMOVAL_STORAGE_KEY = "menumijia.windows.connectionRemoval.v1";
const SCHEMA_VERSION = 1;
const MAX_REMOVALS = 32;
const MAX_SLOT_IDS = 16;

export interface ConnectionRemovalReadStorage {
  getItem(key: string): string | null;
}

export type ConnectionRemovalKind = "mi" | "ha";
export type ConnectionRemovalStage = "draining" | "cleaning" | "failed";

export interface ConnectionRemovalRecord {
  /** Record key: `mi:<accountId>` or `ha:<normalized origin+path>`. */
  readonly scope: string;
  readonly kind: ConnectionRemovalKind;
  /** Version of the intent that owns this record; an older cleanup must not delete anything. */
  readonly ownerVersion: number;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly stage: ConnectionRemovalStage;
  readonly attempts: number;
  /** Xiaomi account whose credential slots belong to this removal. */
  readonly accountId: string | null;
  /** `mi_session_<slotId>` suffixes owned by the removed account (never another account's). */
  readonly slotIds: readonly string[];
  /** True when `mi_session` still belongs to the removed account and must be cleared too. */
  readonly ownsPrimarySlot: boolean;
  readonly lastError: string | null;
  /** Unknown fields are preserved so an older build never drops a newer build's data. */
  readonly extra: Readonly<Record<string, unknown>>;
}

export interface ConnectionRemovalState {
  readonly ownerVersion: number;
  readonly records: readonly ConnectionRemovalRecord[];
  readonly readError: boolean;
  readonly corruptRaw: string | null;
}

export interface BeginConnectionRemovalInput {
  readonly kind: ConnectionRemovalKind;
  readonly scope: string;
  readonly stage?: ConnectionRemovalStage;
  readonly accountId?: string | null;
  readonly slotIds?: readonly string[];
  readonly ownsPrimarySlot?: boolean;
  readonly error?: string | null;
  readonly now?: number;
}

export type ConnectionRemovalExecution =
  | { readonly status: "completed" }
  | { readonly status: "incomplete"; readonly reason: string; readonly remaining: readonly string[] };

export interface ConnectionRemovalVaultPort {
  /** Deletes exactly the given slots; a rejected slot must leave the others untouched. */
  deleteCredentialSlots(names: readonly SecureCredentialName[]): Promise<void>;
  /** Proves who owns `mi_session` now, so an old intent cannot delete a rebound credential. */
  readPrimarySession(): Promise<{ readonly userId: string; readonly region: string } | null>;
  didLastPrimarySessionReadFail(): boolean;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const positiveInt = (raw: unknown, fallback: number): number =>
  typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? Math.trunc(raw) : fallback;

const cleanText = (raw: unknown, limit = 240): string | null => {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed === "" ? null : trimmed.slice(0, limit);
};

export function miConnectionRemovalScope(accountId: string): string {
  const trimmed = accountId.trim();
  return trimmed.startsWith("mi:") ? trimmed : `mi:${trimmed}`;
}

export function haConnectionRemovalScope(scope: string | null | undefined): string | null {
  if (!scope) return null;
  return haConnectionScope(scope) ?? (scope.startsWith("ha:") ? scope : null);
}

function stageOf(raw: unknown, fallback: ConnectionRemovalStage): ConnectionRemovalStage {
  return raw === "draining" || raw === "cleaning" || raw === "failed" ? raw : fallback;
}

function parseSlotIds(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== "string") continue;
    try {
      const slotId = normalizeMiCredentialSlotId(item);
      if (!out.includes(slotId)) out.push(slotId);
    } catch {
      // A slot id the whitelist rejects cannot be one of ours; drop it instead of failing the record.
    }
    if (out.length >= MAX_SLOT_IDS) break;
  }
  return out;
}

const RECORDED_FIELDS = new Set([
  "scope",
  "kind",
  "ownerVersion",
  "createdAt",
  "updatedAt",
  "stage",
  "attempts",
  "accountId",
  "slotIds",
  "ownsPrimarySlot",
  "lastError",
  "extra",
]);

function parseRemovalRecord(raw: unknown): ConnectionRemovalRecord | null {
  if (!isRecord(raw)) return null;
  const kind = raw["kind"];
  const scope = cleanText(raw["scope"], 512);
  if ((kind !== "mi" && kind !== "ha") || !scope || !scope.startsWith(`${kind}:`)) return null;
  const extra: Record<string, unknown> = isRecord(raw["extra"]) ? { ...raw["extra"] } : {};
  for (const [key, value] of Object.entries(raw)) {
    if (!RECORDED_FIELDS.has(key)) extra[key] = value;
  }
  return {
    scope,
    kind,
    ownerVersion: positiveInt(raw["ownerVersion"], 0),
    createdAt: positiveInt(raw["createdAt"], 0),
    updatedAt: positiveInt(raw["updatedAt"], positiveInt(raw["createdAt"], 0)),
    stage: stageOf(raw["stage"], "cleaning"),
    attempts: positiveInt(raw["attempts"], 0),
    accountId: kind === "mi" ? cleanText(raw["accountId"], 96) : null,
    slotIds: kind === "mi" ? parseSlotIds(raw["slotIds"]) : [],
    ownsPrimarySlot: kind === "mi" && raw["ownsPrimarySlot"] === true,
    lastError: cleanText(raw["lastError"]),
    extra,
  };
}

function readRaw(storage: ConnectionRemovalReadStorage | null): string | null {
  if (!storage) return null;
  try {
    return storage.getItem(CONNECTION_REMOVAL_STORAGE_KEY);
  } catch {
    return null;
  }
}

function parseEnvelope(raw: string | null): Record<string, unknown> | null {
  if (raw === null) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isRecord(parsed) || parsed["schemaVersion"] !== SCHEMA_VERSION || !Array.isArray(parsed["removals"])) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

/**
 * The stored removal state. An unreadable payload is reported as `readError` instead of "no
 * removals": the caller must then keep its scopes blocked rather than trust a half-read record.
 */
export function readConnectionRemovalState(
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): ConnectionRemovalState {
  const raw = readRaw(storage);
  const empty: ConnectionRemovalState = { ownerVersion: 0, records: [], readError: false, corruptRaw: null };
  if (raw === null) return empty;
  const parsed = parseEnvelope(raw);
  if (parsed === null) return { ...empty, readError: true, corruptRaw: raw };
  const records: ConnectionRemovalRecord[] = [];
  for (const item of parsed["removals"] as readonly unknown[]) {
    const record = parseRemovalRecord(item);
    if (!record || records.some((existing) => existing.scope === record.scope)) continue;
    records.push(record);
    if (records.length >= MAX_REMOVALS) break;
  }
  return {
    ownerVersion: Math.max(positiveInt(parsed["ownerVersion"], 0), ...records.map((record) => record.ownerVersion)),
    records,
    readError: false,
    corruptRaw: null,
  };
}

function serializeRecord(record: ConnectionRemovalRecord): Record<string, unknown> {
  return {
    ...record.extra,
    scope: record.scope,
    kind: record.kind,
    ownerVersion: record.ownerVersion,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    stage: record.stage,
    attempts: record.attempts,
    ...(record.accountId !== null ? { accountId: record.accountId } : {}),
    ...(record.slotIds.length > 0 ? { slotIds: [...record.slotIds] } : {}),
    ...(record.ownsPrimarySlot ? { ownsPrimarySlot: true } : {}),
    ...(record.lastError !== null ? { lastError: record.lastError } : {}),
  };
}

/** Read-merge-write of the whole document; returns false when nothing could be persisted. */
function writeConnectionRemovalState(
  storage: ConnectionRemovalReadStorage | null,
  state: ConnectionRemovalState,
  records: readonly ConnectionRemovalRecord[],
  ownerVersion: number,
): boolean {
  const writable = storage as (ConnectionRemovalReadStorage & {
    setItem(key: string, value: string): void;
    removeItem?(key: string): void;
  }) | null;
  if (!writable || typeof writable.setItem !== "function") return false;
  try {
    const previous = parseEnvelope(readRaw(storage)) ?? {};
    const known = new Set(["schemaVersion", "ownerVersion", "removals"]);
    const carried: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(previous)) {
      if (!known.has(key)) carried[key] = value;
    }
    if (records.length === 0) {
      if (state.corruptRaw !== null && writable.removeItem) {
        // Quarantine an unreadable payload instead of silently discarding it, like capability storage.
        try {
          const base = `${CONNECTION_REMOVAL_STORAGE_KEY}.unreadable`;
          let key = base;
          let suffix = 0;
          while (writable.getItem(key) !== null) key = `${base}.${++suffix}`;
          writable.setItem(key, state.corruptRaw);
        } catch {
          // Best effort: never fail a removal that already succeeded.
        }
      }
      if (writable.removeItem) {
        writable.removeItem(CONNECTION_REMOVAL_STORAGE_KEY);
        return true;
      }
    }
    writable.setItem(
      CONNECTION_REMOVAL_STORAGE_KEY,
      JSON.stringify({
        ...carried,
        schemaVersion: SCHEMA_VERSION,
        ownerVersion,
        removals: records.map(serializeRecord),
      }),
    );
    return true;
  } catch {
    return false;
  }
}

function nextOwnerVersion(state: ConnectionRemovalState): number {
  const fromRecords = state.records.reduce((max, record) => Math.max(max, record.ownerVersion), 0);
  return Math.max(state.ownerVersion, fromRecords) + 1;
}

/** Records (or refreshes) the removal intent; `null` means nothing was persisted. */
export function beginConnectionRemoval(
  input: BeginConnectionRemovalInput,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): ConnectionRemovalRecord | null {
  const state = readConnectionRemovalState(storage);
  const now = input.now ?? Date.now();
  const previous = state.records.find((record) => record.scope === input.scope) ?? null;
  const ownerVersion = nextOwnerVersion(state);
  const record: ConnectionRemovalRecord = {
    scope: input.scope,
    kind: input.kind,
    ownerVersion,
    createdAt: previous?.createdAt ?? now,
    updatedAt: now,
    stage: input.stage ?? previous?.stage ?? "cleaning",
    attempts: (previous?.attempts ?? 0) + 1,
    accountId: input.accountId ?? previous?.accountId ?? null,
    slotIds: input.slotIds ?? previous?.slotIds ?? [],
    ownsPrimarySlot: input.ownsPrimarySlot ?? previous?.ownsPrimarySlot ?? false,
    lastError: input.error ?? null,
    extra: previous?.extra ?? {},
  };
  const records = [...state.records.filter((item) => item.scope !== record.scope), record];
  return writeConnectionRemovalState(storage, state, records, ownerVersion) ? record : null;
}

/** Moves a record's stage; refuses when a newer intent took the record over. */
export function markConnectionRemovalStage(
  scope: string,
  ownerVersion: number,
  stage: ConnectionRemovalStage,
  error: string | null = null,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): ConnectionRemovalRecord | null {
  const state = readConnectionRemovalState(storage);
  const current = state.records.find((record) => record.scope === scope);
  if (!current || current.ownerVersion !== ownerVersion) return null;
  const record: ConnectionRemovalRecord = {
    ...current,
    stage,
    lastError: cleanText(error),
    updatedAt: Date.now(),
  };
  const records = state.records.map((item) => (item.scope === scope ? record : item));
  return writeConnectionRemovalState(storage, state, records, state.ownerVersion) ? record : null;
}

/** Drops the record after the slots are gone; an older intent keeps the newer record. */
export function completeConnectionRemoval(
  scope: string,
  ownerVersion: number,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): boolean {
  const state = readConnectionRemovalState(storage);
  const current = state.records.find((record) => record.scope === scope);
  if (!current || current.ownerVersion !== ownerVersion) return false;
  return writeConnectionRemovalState(
    storage,
    state,
    state.records.filter((record) => record.scope !== scope),
    state.ownerVersion,
  );
}

export function findConnectionRemoval(
  scope: string | null | undefined,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): ConnectionRemovalRecord | null {
  if (!scope) return null;
  return readConnectionRemovalState(storage).records.find((record) => record.scope === scope) ?? null;
}

export function isConnectionRemovalPending(
  scope: string | null | undefined,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): boolean {
  return findConnectionRemoval(scope, storage) !== null;
}

export function clearConnectionRemovals(storage: ConnectionRemovalReadStorage | null = defaultStorage()): boolean {
  const state = readConnectionRemovalState(storage);
  if (state.records.length === 0 && state.corruptRaw === null) return true;
  return writeConnectionRemovalState(storage, state, [], state.ownerVersion);
}

/**
 * Scopes of `kind` whose removal is still incomplete. `resolveMiAccountSelectionState` treats them
 * as disabled, so no read, write, timer or camera lease can start for them after a restart.
 */
export function pendingConnectionRemovalScopes(
  kind: ConnectionRemovalKind,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): readonly string[] {
  return readConnectionRemovalState(storage)
    .records.filter((record) => record.kind === kind)
    .map((record) => record.scope);
}

/** The exact credential slots this record owns: never another account, the other source or a key. */
export function connectionRemovalCredentialNames(record: ConnectionRemovalRecord): SecureCredentialName[] {
  if (record.kind === "ha") return ["ha_token"];
  const names: SecureCredentialName[] = record.slotIds.map((slotId) => miAccountSessionCredentialName(slotId));
  if (record.ownsPrimarySlot) names.unshift("mi_session");
  return [...new Set<SecureCredentialName>(names)];
}

function errorMessage(error: unknown): string {
  if (typeof error === "string") return error.slice(0, 240);
  if (error instanceof Error && error.message.trim() !== "") return error.message.trim().slice(0, 240);
  return "connection_removal_failed";
}

/**
 * Deletes only the slots the record owns and clears the record on success. Idempotent: a retry
 * re-runs the same targeted deletes after a partial failure.
 */
export async function executeConnectionRemoval(
  record: ConnectionRemovalRecord,
  vault: ConnectionRemovalVaultPort,
  storage: ConnectionRemovalReadStorage | null = defaultStorage(),
): Promise<ConnectionRemovalExecution> {
  const incomplete = (reason: string, remaining: readonly string[]): ConnectionRemovalExecution => {
    markConnectionRemovalStage(record.scope, record.ownerVersion, "failed", reason, storage);
    return { status: "incomplete", reason, remaining };
  };

  const names = connectionRemovalCredentialNames(record);
  if (record.ownsPrimarySlot && names.includes("mi_session")) {
    const primary = await vault.readPrimarySession();
    if (vault.didLastPrimarySessionReadFail()) {
      // Cannot prove who owns `mi_session` now: deleting it could remove a rebound account (#228).
      return incomplete("primary_session_unreadable", ["mi_session"]);
    }
    if (primary !== null && record.accountId !== null && miAccountId(primary) !== record.accountId) {
      // Another account was promoted into `mi_session`; that slot is no longer ours to delete.
      names.splice(names.indexOf("mi_session"), 1);
    }
  }

  try {
    await vault.deleteCredentialSlots(names);
  } catch (error) {
    const failed =
      typeof (error as { failed?: unknown })?.failed === "object" &&
      Array.isArray((error as { failed?: unknown[] }).failed)
        ? ((error as { failed: readonly SecureCredentialName[] }).failed.map(String))
        : names;
    return incomplete(errorMessage(error), failed);
  }
  if (completeConnectionRemoval(record.scope, record.ownerVersion, storage)) return { status: "completed" };
  // A newer intent took the record over: it owns the cleanup now, so this one is finished. Anything
  // else means the record could not be cleared and would keep the scope blocked after a restart.
  const stillOwned = findConnectionRemoval(record.scope, storage)?.ownerVersion === record.ownerVersion;
  return stillOwned ? incomplete("removal_record_not_cleared", names) : { status: "completed" };
}
