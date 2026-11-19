export type HaConnectionLifecyclePhase = "enabled" | "stopping" | "stop_timeout" | "disabled";

export interface HaGateStorageLike {
  getItem(key: string): string | null;
}

export interface HaTransportLease {
  readonly scope: string | null;
  readonly generation: number;
  readonly signal: AbortSignal;
  readonly nativeReady?: Promise<void>;
  isCurrent(storage?: HaGateStorageLike | null): boolean;
  release(): void;
}

export class HaBlockedRequestError extends Error {
  public readonly code = "HA_CONNECTION_DISABLED" as const;
  public readonly scope: string;

  constructor(scope: string, message = "Home Assistant is turned off") {
    super(message);
    this.name = "HaBlockedRequestError";
    this.scope = scope;
  }
}

export function isHaBlockedRequestError(error: unknown): error is HaBlockedRequestError {
  return (
    error instanceof HaBlockedRequestError ||
    (typeof error === "object" &&
      error !== null &&
      (error as { code?: unknown }).code === "HA_CONNECTION_DISABLED")
  );
}

export const CAPABILITY_SELECTION_STORAGE_KEY = "menumijia.windows.capabilitySelection.v1";

export const HA_NATIVE_CANCEL_READY = true;

export const DEFAULT_HA_STOP_DRAIN_TIMEOUT_MS = 8_000;

function defaultStorage(): HaGateStorageLike | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage : null;
  } catch {
    return null;
  }
}

export function normalizeHomeAssistantScopeUrl(baseURL?: string | null): string | null {
  try {
    const trimmed = (baseURL ?? "").trim();
    if (!trimmed || trimmed.includes("\\")) return null;
    if (/[\x00-\x1f\x7f]/.test(trimmed)) return null;
    if (/%2e|%2f|%5c/i.test(trimmed)) return null;
    const schemeEnd = trimmed.indexOf("://");
    if (schemeEnd > 0) {
      const afterHostSlash = trimmed.indexOf("/", schemeEnd + 3);
      if (afterHostSlash >= 0) {
        const rawPath = trimmed.slice(afterHostSlash).split(/[?#]/, 1)[0] ?? "";
        if (rawPath.split("/").some((seg) => seg === "." || seg === "..")) return null;
      }
    }
    const url = new URL(trimmed);
    if (
      (url.protocol !== "http:" && url.protocol !== "https:") ||
      url.username ||
      url.password ||
      !url.hostname ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    if (/%2e|%2f|%5c/i.test(url.pathname)) return null;
    const segments = url.pathname.split("/").filter(Boolean);
    if (segments.some((seg) => seg === "." || seg === "..")) return null;
    let normalizedSegments = segments;
    if (
      normalizedSegments.length >= 2 &&
      normalizedSegments[normalizedSegments.length - 2] === "api" &&
      normalizedSegments[normalizedSegments.length - 1] === "websocket"
    ) {
      normalizedSegments = normalizedSegments.slice(0, -2);
    } else if (
      normalizedSegments.length > 0 &&
      normalizedSegments[normalizedSegments.length - 1] === "api"
    ) {
      normalizedSegments = normalizedSegments.slice(0, -1);
    }
    const basePath = normalizedSegments.length > 0 ? `/${normalizedSegments.join("/")}` : "";
    return `${url.origin}${basePath}`;
  } catch {
    return null;
  }
}

export function haConnectionScope(haBaseURL?: string | null, _haToken?: string | null): string | null {
  if (typeof haBaseURL === "string" && haBaseURL.startsWith("ha:")) {
    const normalized = normalizeHomeAssistantScopeUrl(haBaseURL.slice(3));
    return normalized ? `ha:${normalized}` : null;
  }
  const normalized = normalizeHomeAssistantScopeUrl(haBaseURL);
  return normalized ? `ha:${normalized}` : null;
}

export function isHaScopeDisabledInStorage(
  scope: string | null | undefined,
  storage?: HaGateStorageLike | null,
): boolean {
  if (!scope) return false;
  const normalizedScope = scope.startsWith("ha:") ? haConnectionScope(scope.slice(3)) ?? scope : haConnectionScope(scope) ?? scope;
  const backing = storage === undefined ? defaultStorage() : storage;
  if (!backing) return false;
  try {
    const raw = backing.getItem(CAPABILITY_SELECTION_STORAGE_KEY);
    if (!raw) return false;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return false;
    const rec = parsed as Record<string, unknown>;
    if (rec["schemaVersion"] !== 1 || rec["migrationComplete"] !== true) return false;
    const list = rec["disabledHaScopes"];
    if (!Array.isArray(list)) return false;
    return list.some((item) => typeof item === "string" && (haConnectionScope(item) ?? item) === normalizedScope);
  } catch {
    return false;
  }
}

export interface HaDrainReadyMeta {
  readonly timedOut?: boolean;
}

interface ScopeLifecycleEntry {
  generation: number;
  abandonedBeforeGen: number;
  stopTimedOut: boolean;
  nativeDrain: Promise<void> | null;
  drainTimer: ReturnType<typeof setTimeout> | null;
  lastPhase: HaConnectionLifecyclePhase | null;
  controller: AbortController;
  readonly inFlightByGen: Map<number, number>;
  pendingEnableCallbacks: Array<(ready: boolean, meta?: HaDrainReadyMeta) => void>;
}

type PhaseListener = (scope: string, phase: HaConnectionLifecyclePhase) => void;

const fallbackEnvKey: object = {};
const scopeEntriesByEnv = new WeakMap<object, Map<string, ScopeLifecycleEntry>>();
const phaseListenersByEnv = new WeakMap<object, Set<PhaseListener>>();
const nativeCancelReadyOverrideByEnv = new WeakMap<object, boolean>();
const stopDrainTimeoutMsOverrideByEnv = new WeakMap<object, number>();

function currentEnvKey(): object {
  try {
    if (typeof window !== "undefined" && window !== null && typeof window === "object") {
      return window as object;
    }
  } catch {
    // Ignore restricted global window access.
  }
  return fallbackEnvKey;
}

interface NativeRegistration {
  readonly scope: string | null;
  readonly token: string;
  readonly generation: number;
  readonly ready: Promise<void>;
  status: "pending" | "ready" | "failed";
}

const nativeRegistrations = new WeakMap<object, NativeRegistration>();
// Keep revisions increasing across WebView reloads in the same native process.
let nativeGeneration = Math.floor(performance.timeOrigin * 1000);

export function syncHaNativeConnection(baseURL: string, token: string): Promise<void> | undefined {
  const env = currentEnvKey();
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return undefined;
  const scope = token ? haConnectionScope(baseURL) : null;
  const previous = nativeRegistrations.get(env);
  const activeToken = scope ? token : "";
  if (!scope && !previous) return undefined;
  if (previous && previous.scope === scope && previous.token === activeToken && previous.status !== "failed") {
    return previous.status === "pending" ? previous.ready : undefined;
  }

  const generation = ++nativeGeneration;
  const ready = invoke<void>("ha_set_connection", { baseUrl: scope ? baseURL : null, generation });
  const registration: NativeRegistration = { scope, token: activeToken, generation, ready, status: "pending" };
  nativeRegistrations.set(env, registration);
  void ready.then(
    () => { registration.status = "ready"; },
    () => { registration.status = "failed"; },
  );
  return ready;
}

function retireNativeHaScope(scope: string | null): Promise<void> | undefined {
  const current = nativeRegistrations.get(currentEnvKey());
  if (!current || (scope !== null && current.scope !== scope && current.scope !== null)) return undefined;
  return syncHaNativeConnection("", "");
}

const NATIVE_HA_STALE_MESSAGE = "Home Assistant connection is disabled or has changed";

function nativeErrorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string") return message;
  }
  return "";
}

/**
 * A stale native registration is the same condition as a locally blocked scope, so it must reach
 * callers as `HaBlockedRequestError` instead of surfacing the native English message in the UI.
 */
export function mapNativeHaTransportError(error: unknown, scope?: string | null): unknown {
  if (!nativeErrorMessage(error).includes(NATIVE_HA_STALE_MESSAGE)) return error;
  return new HaBlockedRequestError(scope ?? "ha:");
}

export function invokeHaWithLease<T>(
  lease: HaTransportLease,
  invoke: (command: string, args: Record<string, unknown>) => Promise<T>,
  command: string,
  args: Record<string, unknown>,
): Promise<T> {
  const send = () => {
    if (!lease.isCurrent()) return Promise.reject(new HaBlockedRequestError(lease.scope ?? "ha:"));
    return invoke(command, { ...args, generation: lease.generation });
  };
  const pending = lease.nativeReady ? lease.nativeReady.then(send) : send();
  return pending.catch((error: unknown) => {
    throw mapNativeHaTransportError(error, lease.scope);
  });
}

export function isHaNativeCancelReady(): boolean {
  const override = nativeCancelReadyOverrideByEnv.get(currentEnvKey());
  return override !== undefined ? override : HA_NATIVE_CANCEL_READY;
}

export function setHaNativeCancelReadyForTests(ready: boolean | null): void {
  const key = currentEnvKey();
  if (ready === null) {
    nativeCancelReadyOverrideByEnv.delete(key);
  } else {
    nativeCancelReadyOverrideByEnv.set(key, ready);
  }
}

export function getHaStopDrainTimeoutMs(): number {
  const override = stopDrainTimeoutMsOverrideByEnv.get(currentEnvKey());
  return override !== undefined ? override : DEFAULT_HA_STOP_DRAIN_TIMEOUT_MS;
}

export function setHaStopDrainTimeoutMsForTests(ms: number | null): void {
  const key = currentEnvKey();
  if (ms === null) {
    stopDrainTimeoutMsOverrideByEnv.delete(key);
  } else {
    stopDrainTimeoutMsOverrideByEnv.set(key, Math.max(1, Math.trunc(ms)));
  }
}

function getScopeEntries(): Map<string, ScopeLifecycleEntry> {
  const key = currentEnvKey();
  let map = scopeEntriesByEnv.get(key);
  if (!map) {
    map = new Map<string, ScopeLifecycleEntry>();
    scopeEntriesByEnv.set(key, map);
  }
  return map;
}

function getPhaseListeners(): Set<PhaseListener> {
  const key = currentEnvKey();
  let set = phaseListenersByEnv.get(key);
  if (!set) {
    set = new Set<PhaseListener>();
    phaseListenersByEnv.set(key, set);
  }
  return set;
}

function clearDrainTimer(entry: ScopeLifecycleEntry): void {
  if (entry.drainTimer !== null) {
    clearTimeout(entry.drainTimer);
    entry.drainTimer = null;
  }
}

function cancelPendingEnableCallbacks(entry: ScopeLifecycleEntry, meta?: HaDrainReadyMeta): void {
  if (entry.pendingEnableCallbacks.length === 0) return;
  const callbacks = entry.pendingEnableCallbacks.splice(0);
  for (const cb of callbacks) {
    try {
      cb(false, meta);
    } catch {
      // Ignore callback errors during cancellation.
    }
  }
}

function ensureEntry(scope: string): ScopeLifecycleEntry {
  const entries = getScopeEntries();
  let entry = entries.get(scope);
  if (!entry) {
    entry = {
      generation: 1,
      abandonedBeforeGen: 0,
      stopTimedOut: false,
      nativeDrain: null,
      drainTimer: null,
      lastPhase: null,
      controller: new AbortController(),
      inFlightByGen: new Map(),
      pendingEnableCallbacks: [],
    };
    entries.set(scope, entry);
  }
  return entry;
}

function activeInFlight(entry: ScopeLifecycleEntry): number {
  let sum = Number(entry.nativeDrain !== null);
  for (const [gen, count] of entry.inFlightByGen.entries()) {
    if (gen >= entry.abandonedBeforeGen) sum += count;
  }
  return sum;
}

function activeOlderInFlight(entry: ScopeLifecycleEntry): number {
  let sum = Number(entry.nativeDrain !== null);
  for (const [gen, count] of entry.inFlightByGen.entries()) {
    if (gen >= entry.abandonedBeforeGen && gen < entry.generation) sum += count;
  }
  return sum;
}

function notifyPhaseListeners(scope: string, phase: HaConnectionLifecyclePhase): void {
  const entry = getScopeEntries().get(scope);
  if (entry) {
    if (entry.lastPhase === phase) return;
    entry.lastPhase = phase;
  }
  for (const listener of [...getPhaseListeners()]) {
    try {
      listener(scope, phase);
    } catch {
      // Listener errors must never disrupt transport draining.
    }
  }
}

function armDrainTimer(scope: string, entry: ScopeLifecycleEntry): void {
  clearDrainTimer(entry);
  if (activeInFlight(entry) <= 0) return;
  const timer = setTimeout(() => {
    entry.drainTimer = null;
    if (activeInFlight(entry) <= 0) return;
    entry.stopTimedOut = true;
    cancelPendingEnableCallbacks(entry, { timedOut: true });
    notifyPhaseListeners(scope, "stop_timeout");
  }, getHaStopDrainTimeoutMs());
  // An awaited enable-after-drain settles only when this timer fires, so it must keep the runtime
  // alive; only an unawaited disable drain may unref and let a Node process exit first.
  if (entry.pendingEnableCallbacks.length === 0) {
    (timer as unknown as { unref?: () => void }).unref?.();
  }
  entry.drainTimer = timer;
}

/**
 * Test hook: whether the armed drain timer still holds the runtime open. A drain that settles an
 * awaited enable must report `true`, otherwise that await can never resolve.
 */
export function isHaDrainTimerRefedForTests(scope: string | null | undefined): boolean | null {
  const normalized = haConnectionScope(scope);
  const timer = normalized ? getScopeEntries().get(normalized)?.drainTimer : null;
  if (!timer) return null;
  const handle = timer as unknown as { hasRef?: () => boolean };
  return typeof handle.hasRef === "function" ? handle.hasRef() : true;
}

export function getHaScopeGeneration(scope: string | null | undefined): number {
  const normalized = haConnectionScope(scope);
  if (!normalized) return 0;
  return ensureEntry(normalized).generation;
}

export function getHaScopeSignal(scope: string | null | undefined): AbortSignal {
  const normalized = haConnectionScope(scope);
  if (!normalized) return new AbortController().signal;
  return ensureEntry(normalized).controller.signal;
}

export function getHaScopeInFlightCount(scope: string | null | undefined): number {
  const normalized = haConnectionScope(scope);
  if (!normalized) return 0;
  const entry = getScopeEntries().get(normalized);
  return entry ? activeInFlight(entry) : 0;
}

export function isHaScopeStopTimedOut(scope: string | null | undefined): boolean {
  const normalized = haConnectionScope(scope);
  if (!normalized) return false;
  const entry = getScopeEntries().get(normalized);
  return Boolean(entry && entry.stopTimedOut && activeInFlight(entry) > 0);
}

export function getHaScopeLifecyclePhase(
  scope: string | null | undefined,
  storage?: HaGateStorageLike | null,
): HaConnectionLifecyclePhase {
  const normalized = haConnectionScope(scope);
  if (!normalized) return "enabled";
  const entry = getScopeEntries().get(normalized);
  const disabled = isHaScopeDisabledInStorage(normalized, storage);
  if (entry) {
    const draining = disabled ? activeInFlight(entry) : activeOlderInFlight(entry);
    if (draining > 0) return entry.stopTimedOut ? "stop_timeout" : "stopping";
  }
  return disabled ? "disabled" : "enabled";
}

export function beginHaScopeDisable(
  scope: string | null | undefined,
  storage?: HaGateStorageLike | null,
): HaConnectionLifecyclePhase {
  const normalized = haConnectionScope(scope);
  if (!normalized) return "disabled";
  const entry = ensureEntry(normalized);
  clearDrainTimer(entry);
  cancelPendingEnableCallbacks(entry);
  entry.stopTimedOut = false;
  entry.generation += 1;
  entry.controller.abort();
  entry.controller = new AbortController();
  const nativeDrain = retireNativeHaScope(normalized);
  if (nativeDrain) {
    entry.nativeDrain = nativeDrain;
    void nativeDrain.then(() => {
      if (entry.nativeDrain !== nativeDrain) return;
      entry.nativeDrain = null;
      finishDrain(normalized, entry, storage);
    }, () => {
      if (entry.nativeDrain !== nativeDrain) return;
      // A rejected registration would otherwise stay counted as in-flight forever, pinning the
      // lifecycle at `stop_timeout` and starving every later `requestHaScopeEnableAfterDrain`.
      entry.nativeDrain = null;
      clearDrainTimer(entry);
      entry.stopTimedOut = true;
      cancelPendingEnableCallbacks(entry, { timedOut: true });
      notifyPhaseListeners(normalized, "stop_timeout");
    });
  }
  const draining = activeInFlight(entry) > 0;
  const phase: HaConnectionLifecyclePhase = draining ? "stopping" : "disabled";
  if (draining) {
    armDrainTimer(normalized, entry);
  }
  notifyPhaseListeners(normalized, phase);
  return phase;
}

/**
 * Abandons hung pre-timeout in-flight tracking so user-initiated retry / re-enable
 * can recover from `stop_timeout` without allowing late settlement of abandoned
 * generations (`lease.isCurrent() === false`) to write state.
 */
export function abandonHungHaScopeInFlight(
  scope: string | null | undefined,
  storage?: HaGateStorageLike | null,
): HaConnectionLifecyclePhase {
  const normalized = haConnectionScope(scope);
  if (!normalized) return "disabled";
  const entry = ensureEntry(normalized);
  clearDrainTimer(entry);
  cancelPendingEnableCallbacks(entry);
  if (entry.nativeDrain) return beginHaScopeDisable(normalized, storage);
  entry.abandonedBeforeGen = entry.generation;
  entry.generation += 1;
  entry.controller.abort();
  entry.controller = new AbortController();
  entry.stopTimedOut = false;
  const nextPhase: HaConnectionLifecyclePhase = isHaScopeDisabledInStorage(normalized, storage)
    ? "disabled"
    : "enabled";
  notifyPhaseListeners(normalized, nextPhase);
  return nextPhase;
}

export function requestHaScopeEnableAfterDrain(
  scope: string | null | undefined,
  onReady: (ready: boolean, meta?: HaDrainReadyMeta) => void,
  storage?: HaGateStorageLike | null,
): { readonly immediate: boolean; readonly generation: number } {
  const normalized = haConnectionScope(scope);
  if (!normalized) {
    onReady(true);
    return { immediate: true, generation: 0 };
  }
  const entry = ensureEntry(normalized);
  if (activeInFlight(entry) > 0) {
    entry.stopTimedOut = false;
    cancelPendingEnableCallbacks(entry);
    entry.pendingEnableCallbacks = [onReady];
    armDrainTimer(normalized, entry);
    notifyPhaseListeners(normalized, "stopping");
    return { immediate: false, generation: entry.generation };
  }
  clearDrainTimer(entry);
  entry.stopTimedOut = false;
  cancelPendingEnableCallbacks(entry);
  entry.generation += 1;
  entry.controller = new AbortController();
  if (!isHaScopeDisabledInStorage(normalized, storage)) {
    notifyPhaseListeners(normalized, "enabled");
    onReady(true);
  } else {
    onReady(false);
  }
  return { immediate: true, generation: entry.generation };
}

export function clearHaScopeLifecycle(scope?: string | null): void {
  const entries = getScopeEntries();
  const normalized = haConnectionScope(scope);
  if (!scope || normalized) void retireNativeHaScope(normalized);
  if (!scope) {
    for (const [key, entry] of entries.entries()) {
      clearDrainTimer(entry);
      cancelPendingEnableCallbacks(entry);
      entry.generation += 1;
      entry.controller.abort();
      entry.controller = new AbortController();
      entries.delete(key);
    }
    return;
  }
  if (!normalized) return;
  const entry = entries.get(normalized);
  if (!entry) return;
  clearDrainTimer(entry);
  cancelPendingEnableCallbacks(entry);
  entry.generation += 1;
  entry.controller.abort();
  entry.controller = new AbortController();
  entries.delete(normalized);
}

function finishDrain(scope: string, entry: ScopeLifecycleEntry, storage?: HaGateStorageLike | null): void {  if (activeInFlight(entry) > 0 || getScopeEntries().get(scope) !== entry) return;
  clearDrainTimer(entry);
  entry.stopTimedOut = false;
  const disabled = isHaScopeDisabledInStorage(scope, storage);
  if (entry.pendingEnableCallbacks.length > 0 && !disabled) {
    const callbacks = entry.pendingEnableCallbacks.splice(0);
    entry.generation += 1;
    entry.controller = new AbortController();
    notifyPhaseListeners(scope, "enabled");
    for (const callback of callbacks) callback(true);
    return;
  }
  cancelPendingEnableCallbacks(entry);
  notifyPhaseListeners(scope, disabled ? "disabled" : "enabled");
}

export function acquireHaTransportLease(
  baseURL: string,
  options?: { readonly storage?: HaGateStorageLike | null; readonly token?: string },
): HaTransportLease | null {
  const scope = haConnectionScope(baseURL);
  if (!scope) {
    const fallbackController = new AbortController();
    let released = false;
    return {
      scope: null,
      generation: 0,
      signal: fallbackController.signal,
      isCurrent: () => !released && !fallbackController.signal.aborted,
      release: () => {
        released = true;
      },
    };
  }
  if (getHaScopeLifecyclePhase(scope, options?.storage) !== "enabled") {
    return null;
  }
  const env = currentEnvKey();
  const registration = nativeRegistrations.get(env);
  if (registration && (registration.scope !== scope ||
    (options?.token !== undefined && registration.token !== options.token.trim()))) {
    return null;
  }
  const entry = ensureEntry(scope);
  const leaseGeneration = entry.generation;
  const leaseSignal = entry.controller.signal;
  entry.inFlightByGen.set(leaseGeneration, (entry.inFlightByGen.get(leaseGeneration) ?? 0) + 1);
  let released = false;

  return {
    scope,
    generation: registration?.generation ?? leaseGeneration,
    ...(registration && registration.status !== "ready" ? { nativeReady: registration.ready } : {}),
    signal: leaseSignal,
    isCurrent(storage?: HaGateStorageLike | null): boolean {
      const effectiveStorage = storage === undefined ? options?.storage : storage;
      return (
        nativeRegistrations.get(env) === registration &&
        !leaseSignal.aborted &&
        leaseGeneration >= entry.abandonedBeforeGen &&
        entry.generation === leaseGeneration &&
        activeOlderInFlight(entry) === 0 &&
        !isHaScopeDisabledInStorage(scope, effectiveStorage)
      );
    },
    release(): void {
      if (released) return;
      released = true;
      const prev = entry.inFlightByGen.get(leaseGeneration) ?? 0;
      if (prev <= 1) {
        entry.inFlightByGen.delete(leaseGeneration);
      } else {
        entry.inFlightByGen.set(leaseGeneration, prev - 1);
      }
      if (leaseGeneration < entry.abandonedBeforeGen) {
        return;
      }
      finishDrain(scope, entry, options?.storage);
    },
  };
}

export function subscribeHaScopeLifecycle(
  listener: (scope: string, phase: HaConnectionLifecyclePhase) => void,
): () => void {
  const listeners = getPhaseListeners();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export interface HaDrainWaitResult {
  readonly drained: boolean;
  readonly timedOut: boolean;
}

/**
 * Resolves once nothing of `scope` is still in flight, or when the stop drain times out.
 *
 * Connection removal uses this between "stop using it" and "delete its credentials": a transport
 * still holding the old generation must finish (or time out) before the token it carries is gone.
 */
export function waitForHaScopeDrained(
  scope: string | null | undefined,
  timeoutMs: number = getHaStopDrainTimeoutMs(),
): Promise<HaDrainWaitResult> {
  const normalized = haConnectionScope(scope);
  if (!normalized || getHaScopeInFlightCount(normalized) === 0) {
    return Promise.resolve({ drained: true, timedOut: false });
  }
  return new Promise<HaDrainWaitResult>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let unsubscribe = (): void => undefined;
    const finish = (result: HaDrainWaitResult): void => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      unsubscribe();
      resolve(result);
    };
    timer = setTimeout(() => finish({ drained: false, timedOut: true }), Math.max(1, timeoutMs));
    unsubscribe = subscribeHaScopeLifecycle((changed, phase) => {
      if (changed !== normalized) return;
      if (phase === "stop_timeout") {
        finish({ drained: false, timedOut: true });
        return;
      }
      if (phase === "disabled" || phase === "enabled") {
        finish({ drained: getHaScopeInFlightCount(normalized) === 0, timedOut: false });
      }
    });
    // The drain may have finished between the check above and the subscription.
    if (getHaScopeInFlightCount(normalized) === 0) finish({ drained: true, timedOut: false });
    else if (isHaScopeStopTimedOut(normalized)) finish({ drained: false, timedOut: true });
  });
}

export function resetHaTransportGateForTests(): void {
  const entries = getScopeEntries();
  for (const entry of entries.values()) {
    clearDrainTimer(entry);
    cancelPendingEnableCallbacks(entry);
    entry.controller.abort();
  }
  entries.clear();
  getPhaseListeners().clear();
  const envKey = currentEnvKey();
  nativeRegistrations.delete(envKey);
  nativeCancelReadyOverrideByEnv.delete(envKey);
  stopDrainTimeoutMsOverrideByEnv.delete(envKey);
}
