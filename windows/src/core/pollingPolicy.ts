import { sha256 } from "./miCloudCrypto.js";
import {
  MiCloudError,
  normalizeMiCloudRegion,
  type MiDeviceRecord,
  type MiRoom,
  type MiSession,
  type MiotDeviceSpec,
} from "./miCloudClient.js";

/**
 * Current panel and workstation activity context. Mirrors `Sources/MijiaCore/PollingPolicy.swift:4-22`.
 */
interface PollingContext {
  /** The control center panel is visible on screen. */
  readonly panelVisible: boolean;
  /** False while the machine or display sleeps or the workstation is locked. */
  readonly systemActive: boolean;
  /** OS power-saver / low-power mode is active. */
  readonly lowPower: boolean;
}

export function describePollingContext(context: PollingContext): string {
  if (!context.systemActive) return "paused (asleep or locked)";
  return `${context.panelVisible ? "panel open" : "panel closed"}${context.lowPower ? ", low power" : ""}`;
}

const PANEL_OPEN_INTERVAL_MS = 6_000;
const PANEL_CLOSED_INTERVAL_MS = 60_000;
const LOW_POWER_FACTOR = 3;
const DEVICE_REFRESH_EVERY_POLLS = 20;
const RATE_LIMIT_BACKOFF_SCHEDULE_MS = [60_000, 120_000, 240_000, 480_000, 900_000] as const;

/**
 * Xiaomi / cloud background polling cadence and rate-limit policy.
 * Mirrors `Sources/MijiaCore/PollingPolicy.swift:24-49` and `MiCloudProvider.swift:202-227`.
 */
export const PollingPolicy = {
  panelOpenIntervalMs: PANEL_OPEN_INTERVAL_MS,
  panelClosedIntervalMs: PANEL_CLOSED_INTERVAL_MS,
  lowPowerFactor: LOW_POWER_FACTOR,
  /** Full topology discovery (`deviceList + homeRooms + sharedHomes + lightGroupMembers`) runs once every 20 polls. */
  deviceRefreshEveryPolls: DEVICE_REFRESH_EVERY_POLLS,
  /** Exponential backoff steps on HTTP 429 / Xiaomi rate limit, capped at 900 s (15 min). */
  rateLimitBackoffScheduleMs: RATE_LIMIT_BACKOFF_SCHEDULE_MS,

  /**
   * Returns the wait in milliseconds between polls, or `null` when polling must pause (locked/asleep).
   */
  intervalMs(
    context: PollingContext,
    panelOpenMs: number = PANEL_OPEN_INTERVAL_MS,
    panelClosedMs: number = PANEL_CLOSED_INTERVAL_MS,
  ): number | null {
    if (!context.systemActive) return null;
    if (context.panelVisible) return panelOpenMs;
    return context.lowPower ? panelClosedMs * LOW_POWER_FACTOR : panelClosedMs;
  },

  /**
   * Returns the backoff delay in milliseconds for the `consecutiveHits`-th rate-limit error (1-based).
   * Schedule: `60s → 120s → 240s → 480s → 900s` (cap).
   */
  rateLimitBackoffMs(consecutiveHits: number): number {
    const clampedIndex = Math.max(
      0,
      Math.min(RATE_LIMIT_BACKOFF_SCHEDULE_MS.length - 1, Math.trunc(consecutiveHits) - 1),
    );
    return RATE_LIMIT_BACKOFF_SCHEDULE_MS[clampedIndex] ?? 900_000;
  },
} as const;

const RATE_LIMIT_MARKERS: readonly string[] = [
  "too many requests",
  "rate limit",
  "ratelimit",
  "frequency limit",
  "request limit",
  "请求过于频繁",
  "访问过于频繁",
];

export function isXiaomiRateLimitError(err: unknown): boolean {
  if (err instanceof MiCloudError) {
    if (err.code === 429 || err.code === -429) return true;
    const lower = err.message.toLowerCase();
    if (lower.includes("http 429")) return true;
    return RATE_LIMIT_MARKERS.some((marker) => lower.includes(marker));
  }
  if (err instanceof Error) {
    const lower = err.message.toLowerCase();
    if (lower.includes("http 429")) return true;
    return RATE_LIMIT_MARKERS.some((marker) => lower.includes(marker));
  }
  return false;
}

function utf8Bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function bytesToHex(bytes: Uint8Array): string {
  let hex = "";
  for (let i = 0; i < bytes.length; i += 1) {
    hex += (bytes[i] ?? 0).toString(16).padStart(2, "0");
  }
  return hex;
}

const MI_SESSION_FINGERPRINT_PREFIX = "v2:";
const MI_SESSION_FINGERPRINT_DOMAIN = "menumijia.windows.miSessionFingerprint";

function digestSessionIdentity(identity: string): string {
  return bytesToHex(sha256(utf8Bytes(`${MI_SESSION_FINGERPRINT_DOMAIN}\n${identity}`)));
}

/**
 * Opaque session identity key for the whole `userId + region + sha256(serviceToken)` tuple.
 * The digest covers the Xiaomi userId, so `localStorage` never holds a plaintext account ID
 * (v1 records wrote `userId|region|tokenHash`). The token still contributes its entropy, which
 * keeps the digest unguessable even for a low-entropy numeric userId.
 */
export function miSessionFingerprint(session: MiSession): string {
  const userId = session.userId.trim();
  const region = normalizeMiCloudRegion(session.region);
  const tokenHash = bytesToHex(sha256(utf8Bytes(session.serviceToken)));
  return `${MI_SESSION_FINGERPRINT_PREFIX}${digestSessionIdentity(`${userId}|${region}|${tokenHash}`)}`;
}

function isLegacyMiSessionFingerprint(fingerprint: string): boolean {
  return !fingerprint.startsWith(MI_SESSION_FINGERPRINT_PREFIX);
}

/**
 * Upgrades a v1 `userId|region|tokenHash` fingerprint to the v2 digest. Hashing the legacy string
 * is a pure function of the same identity, so "this exact session was rejected" keeps holding after
 * the upgrade instead of silently turning an expired session back into a valid one.
 */
export function upgradeMiSessionFingerprint(fingerprint: string): string {
  return isLegacyMiSessionFingerprint(fingerprint)
    ? `${MI_SESSION_FINGERPRINT_PREFIX}${digestSessionIdentity(fingerprint)}`
    : fingerprint;
}

interface CachedXiaomiTopology {
  readonly sessionFingerprint: string;
  readonly sourceRevision: number;
  readonly selectedHomeId: string | null;
  readonly allDevices: readonly MiDeviceRecord[];
  readonly allRooms: readonly MiRoom[];
  readonly rawDevices: readonly MiDeviceRecord[];
  readonly rooms: readonly MiRoom[];
  readonly specs: Readonly<Record<string, MiotDeviceSpec>>;
  readonly membersByGroup: ReadonlyMap<string, readonly string[]>;
}

interface HostXiaomiPollState {
  topology: CachedXiaomiTopology | null;
  silentPollsSinceTopology: number;
  backoffSessionFingerprint: string | null;
  consecutiveRateLimits: number;
  backoffUntilMs: number | null;
}

const hostPollStates = new WeakMap<object, HostXiaomiPollState>();

function ensureHostPollState(host: object): HostXiaomiPollState {
  let state = hostPollStates.get(host);
  if (!state) {
    state = {
      topology: null,
      silentPollsSinceTopology: 0,
      backoffSessionFingerprint: null,
      consecutiveRateLimits: 0,
      backoffUntilMs: null,
    };
    hostPollStates.set(host, state);
  }
  return state;
}

/**
 * Returns the cached topology when a background silent poll (`silent === true`) is within rounds 1..19
 * of the last full discovery for the exact same session, source revision, and selected home.
 * Returns `null` on manual refreshes, initial load, home/session switch, or every 20th poll.
 */
export function takeCachedXiaomiTopologyForPoll(
  host: object,
  session: MiSession,
  sourceRevision: number,
  selectedHomeId: string | null,
  silent: boolean,
  everyPolls: number = PollingPolicy.deviceRefreshEveryPolls,
): CachedXiaomiTopology | null {
  if (!silent) return null;
  const state = hostPollStates.get(host);
  if (!state || !state.topology) return null;
  const cached = state.topology;
  if (
    cached.allDevices.length === 0 ||
    cached.rawDevices.length === 0 ||
    cached.sessionFingerprint !== miSessionFingerprint(session) ||
    cached.sourceRevision !== sourceRevision ||
    cached.selectedHomeId !== (selectedHomeId ?? null)
  ) {
    return null;
  }
  const threshold = Math.max(1, Math.trunc(everyPolls));
  const nextRound = state.silentPollsSinceTopology + 1;
  if (nextRound >= threshold) {
    return null;
  }
  state.silentPollsSinceTopology = nextRound;
  return cached;
}

export function getCachedXiaomiTopology(host: object): CachedXiaomiTopology | null {
  return hostPollStates.get(host)?.topology ?? null;
}

export function storeCachedXiaomiTopology(
  host: object,
  topology: CachedXiaomiTopology,
): void {
  const state = ensureHostPollState(host);
  state.topology = topology;
  state.silentPollsSinceTopology = 0;
}

export function clearCachedXiaomiTopology(host: object): void {
  const state = hostPollStates.get(host);
  if (!state) return;
  state.topology = null;
  state.silentPollsSinceTopology = 0;
}

export function shouldSkipSilentPollForBackoff(
  host: object,
  session: MiSession,
  nowMs: number = Date.now(),
): boolean {
  const state = hostPollStates.get(host);
  if (!state || state.backoffUntilMs === null) return false;
  if (state.backoffSessionFingerprint !== miSessionFingerprint(session)) {
    state.backoffSessionFingerprint = null;
    state.consecutiveRateLimits = 0;
    state.backoffUntilMs = null;
    return false;
  }
  return nowMs < state.backoffUntilMs;
}

export function recordXiaomiRateLimit(
  host: object,
  session: MiSession,
  nowMs: number = Date.now(),
): number {
  const state = ensureHostPollState(host);
  const fp = miSessionFingerprint(session);
  if (state.backoffSessionFingerprint !== fp) {
    state.backoffSessionFingerprint = fp;
    state.consecutiveRateLimits = 0;
  }
  state.consecutiveRateLimits += 1;
  const delayMs = PollingPolicy.rateLimitBackoffMs(state.consecutiveRateLimits);
  state.backoffUntilMs = nowMs + delayMs;
  return delayMs;
}

export function clearXiaomiRateLimitBackoff(host: object): void {
  const state = hostPollStates.get(host);
  if (!state) return;
  state.backoffSessionFingerprint = null;
  state.consecutiveRateLimits = 0;
  state.backoffUntilMs = null;
}

export function getXiaomiBackoffUntilMs(host: object, session: MiSession): number | null {
  const state = hostPollStates.get(host);
  if (!state || state.backoffUntilMs === null) return null;
  if (state.backoffSessionFingerprint !== miSessionFingerprint(session)) return null;
  return state.backoffUntilMs;
}

export const MI_SESSION_EXPIRED_STORAGE_KEY = "menumijia.windows.miSessionExpired.v1";
export const MI_ACCOUNTS_EXPIRED_STORAGE_KEY = "menumijia.windows.miAccountsExpired.v1";

/**
 * One storage key per rejected session fingerprint. Rejections never share a JSON object, so two
 * windows writing at the same time touch different keys and can never overwrite each other; no lock
 * or compare-and-swap is needed.
 */
export const MI_SESSION_REJECTED_STORAGE_PREFIX = "menumijia.windows.miSessionRejected.v2.";

function defaultStorage(): Storage | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage : null;
  } catch {
    return null;
  }
}

/**
 * Stable non-secret account id (`mi:<region>:<8-byte hash>`); already privacy-safe.
 * Lives here so the rejection store can read the legacy per-account map without a cycle.
 */
export function miAccountId(session: Pick<MiSession, "userId" | "region">): string {
  const region = normalizeMiCloudRegion(session.region);
  const digest = sha256(utf8Bytes(`${region}:${session.userId.trim()}`));
  return `mi:${region}:${bytesToHex(digest.subarray(0, 8))}`;
}

export function miSessionRejectedStorageKey(fingerprint: string): string {
  const digest = fingerprint.startsWith("v2:") ? fingerprint.slice(3) : fingerprint;
  return `${MI_SESSION_REJECTED_STORAGE_PREFIX}${digest}`;
}

export interface MiSessionRejection {
  readonly expiredAtMs: number;
}

/**
 * Fingerprints rejected while their storage write failed. Consulted before storage so a server
 * rejection is never lost to a quota/disabled-storage failure (fail-closed); entries are dropped
 * once the write lands, and by every recovery path.
 */
const rejectedSessionFingerprints = new Map<string, number>();

interface LegacyRejectionRecord {
  /** Fingerprint already upgraded to the v2 digest. */
  readonly fingerprint: string;
  readonly expiredAtMs: number;
}

function parseLegacyRejection(value: unknown): LegacyRejectionRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const stored = record["fingerprint"];
  if (typeof stored !== "string" || stored.trim() === "") return null;
  const expiredAtMs = record["expiredAtMs"];
  return {
    fingerprint: upgradeMiSessionFingerprint(stored),
    // The fingerprint identifies the rejected session; a missing or malformed timestamp must not
    // invalidate it (v2 payloads fall back to 0 the same way).
    expiredAtMs: typeof expiredAtMs === "number" && Number.isFinite(expiredAtMs) ? expiredAtMs : 0,
  };
}

function parseLegacySingle(raw: string): LegacyRejectionRecord[] {
  try {
    const record = parseLegacyRejection(JSON.parse(raw));
    return record ? [record] : [];
  } catch {
    return [];
  }
}

function parseLegacyAccountMap(raw: string): Map<string, LegacyRejectionRecord> {
  const out = new Map<string, LegacyRejectionRecord>();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return out;
    for (const [accountId, value] of Object.entries(parsed as Record<string, unknown>)) {
      const record = parseLegacyRejection(value);
      if (record) out.set(accountId, record);
    }
  } catch {}
  return out;
}

/**
 * Appends every legacy record as its own fingerprint key, then drops the legacy key only when all
 * writes succeeded. A failure keeps the old key (the verdict still honours it) and retries later;
 * re-writing a key is idempotent, so a partial migration is safe.
 */
function migrateLegacyRejectionKey(
  storage: Storage,
  legacyKey: string,
  records: readonly LegacyRejectionRecord[],
): void {
  try {
    for (const record of records) {
      storage.setItem(
        miSessionRejectedStorageKey(record.fingerprint),
        JSON.stringify({ expiredAtMs: record.expiredAtMs }),
      );
    }
    storage.removeItem(legacyKey);
  } catch {}
}

function migrateLegacyRejections(storage: Storage): void {
  try {
    const raw = storage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY);
    if (raw !== null) {
      const records = parseLegacySingle(raw);
      if (records.length === 0) storage.removeItem(MI_SESSION_EXPIRED_STORAGE_KEY);
      else migrateLegacyRejectionKey(storage, MI_SESSION_EXPIRED_STORAGE_KEY, records);
    }
  } catch {}
  try {
    const raw = storage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
    if (raw !== null) {
      const records = [...parseLegacyAccountMap(raw).values()];
      if (records.length === 0) storage.removeItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
      else migrateLegacyRejectionKey(storage, MI_ACCOUNTS_EXPIRED_STORAGE_KEY, records);
    }
  } catch {}
}

function readPersistedRejection(storage: Storage, fingerprint: string): MiSessionRejection | null {
  try {
    const raw = storage.getItem(miSessionRejectedStorageKey(fingerprint));
    if (raw === null) return null;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        const expiredAtMs = (parsed as Record<string, unknown>)["expiredAtMs"];
        if (typeof expiredAtMs === "number" && Number.isFinite(expiredAtMs)) return { expiredAtMs };
      }
    } catch {}
    // The marker exists, so the session is rejected even if its payload is unreadable.
    return { expiredAtMs: 0 };
  } catch {
    return null;
  }
}

function readLegacyRejection(
  session: MiSession,
  storage: Storage,
  fingerprint: string,
): MiSessionRejection | null {
  try {
    const raw = storage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY);
    if (raw !== null) {
      const match = parseLegacySingle(raw).find((record) => record.fingerprint === fingerprint);
      if (match) return { expiredAtMs: match.expiredAtMs };
    }
  } catch {}
  try {
    const raw = storage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
    if (raw !== null) {
      const record = parseLegacyAccountMap(raw).get(miAccountId(session));
      if (record && record.fingerprint === fingerprint) return { expiredAtMs: record.expiredAtMs };
    }
  } catch {}
  return null;
}

/**
 * The rejection (if any) for this exact session: memory first (fail-closed), then its own key,
 * then the not-yet-migrated v1 records. Also performs the best-effort v1 migration.
 */
export function miSessionRejectedRecord(
  session: MiSession | null | undefined,
  storage: Storage | null = defaultStorage(),
): MiSessionRejection | null {
  if (!session) return null;
  const fingerprint = miSessionFingerprint(session);
  const inMemory = rejectedSessionFingerprints.get(fingerprint);
  if (inMemory !== undefined) return { expiredAtMs: inMemory };
  if (!storage) return null;
  migrateLegacyRejections(storage);
  return (
    readPersistedRejection(storage, fingerprint) ?? readLegacyRejection(session, storage, fingerprint)
  );
}

export function isPersistedMiSessionExpired(
  session: MiSession | null | undefined,
  storage: Storage | null = defaultStorage(),
): boolean {
  return miSessionRejectedRecord(session, storage) !== null;
}

/**
 * Persists a rejection under the session's own fingerprint key. Memory is updated first and only
 * dropped once the write succeeds, so a failed write still rejects the session for this run.
 */
export function persistMiSessionExpired(
  session: MiSession | null | undefined,
  expired: boolean,
  storage: Storage | null = defaultStorage(),
  nowMs: number = Date.now(),
): void {
  if (!session) {
    if (!expired) clearPersistedMiSessionExpired(storage);
    return;
  }
  const fingerprint = miSessionFingerprint(session);
  if (!expired) {
    clearPersistedMiSessionExpiredFor(session, storage);
    return;
  }
  rejectedSessionFingerprints.set(fingerprint, nowMs);
  if (!storage) return;
  try {
    storage.setItem(
      miSessionRejectedStorageKey(fingerprint),
      JSON.stringify({ expiredAtMs: nowMs }),
    );
    rejectedSessionFingerprints.delete(fingerprint);
  } catch {
    // Keep the in-memory rejection: the session stays rejected for this run.
  }
}

/** Removes this session's rejection only; other fingerprints are never touched. */
export function clearPersistedMiSessionExpiredFor(
  session: MiSession | null | undefined,
  storage: Storage | null = defaultStorage(),
): void {
  if (!session) return;
  const fingerprint = miSessionFingerprint(session);
  rejectedSessionFingerprints.delete(fingerprint);
  if (!storage) return;
  // Move any v1 record for this session (and for other sessions) to its own key first, so the
  // legacy fallback cannot report it as rejected right after a successful recovery.
  migrateLegacyRejections(storage);
  try {
    storage.removeItem(miSessionRejectedStorageKey(fingerprint));
  } catch {}
}

/** Sign-out: forgets every rejection, including the v1 records and all per-fingerprint keys. */
export function clearPersistedMiSessionExpired(storage: Storage | null = defaultStorage()): void {
  rejectedSessionFingerprints.clear();
  if (!storage) return;
  try {
    const keys: string[] = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (key !== null && key.startsWith(MI_SESSION_REJECTED_STORAGE_PREFIX)) keys.push(key);
    }
    for (const key of keys) storage.removeItem(key);
    storage.removeItem(MI_SESSION_EXPIRED_STORAGE_KEY);
    storage.removeItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
  } catch {}
}
