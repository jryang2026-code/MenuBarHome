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
export interface PollingContext {
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

/**
 * Non-secret session identity key (`userId + region + sha256(serviceToken)`).
 * Never exposes raw `serviceToken` or `ssecurity` to `localStorage`.
 */
export function miSessionFingerprint(session: MiSession): string {
  const userId = session.userId.trim();
  const region = normalizeMiCloudRegion(session.region);
  const tokenHash = bytesToHex(sha256(utf8Bytes(session.serviceToken)));
  return `${userId}|${region}|${tokenHash}`;
}

export interface CachedXiaomiTopology {
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

function defaultStorage(): Storage | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage : null;
  } catch {
    return null;
  }
}

export function isPersistedMiSessionExpired(
  session: MiSession | null | undefined,
  storage: Storage | null = defaultStorage(),
): boolean {
  if (!session || !storage) return false;
  try {
    const raw = storage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY);
    if (!raw) return false;
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false;
    const rec = parsed as Record<string, unknown>;
    return rec["fingerprint"] === miSessionFingerprint(session);
  } catch {
    return false;
  }
}

export function persistMiSessionExpired(
  session: MiSession | null | undefined,
  expired: boolean,
  storage: Storage | null = defaultStorage(),
  nowMs: number = Date.now(),
): void {
  if (!storage) return;
  try {
    if (!expired || !session) {
      storage.removeItem(MI_SESSION_EXPIRED_STORAGE_KEY);
      return;
    }
    storage.setItem(
      MI_SESSION_EXPIRED_STORAGE_KEY,
      JSON.stringify({
        fingerprint: miSessionFingerprint(session),
        expiredAtMs: nowMs,
      }),
    );
  } catch {
    // Ignore storage quota or sandbox errors.
  }
}

export function clearPersistedMiSessionExpired(
  storage: Storage | null = defaultStorage(),
): void {
  if (!storage) return;
  try {
    storage.removeItem(MI_SESSION_EXPIRED_STORAGE_KEY);
  } catch {
    // Ignore storage errors.
  }
}
