export type HaConnectionLifecyclePhase = "enabled" | "stopping" | "disabled";

export interface HaGateStorageLike {
  getItem(key: string): string | null;
}

export interface HaTransportLease {
  readonly scope: string | null;
  readonly generation: number;
  readonly signal: AbortSignal;
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

const CAPABILITY_SELECTION_STORAGE_KEY = "menumijia.windows.capabilitySelection.v1";

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

interface ScopeLifecycleEntry {
  generation: number;
  controller: AbortController;
  readonly inFlightByGen: Map<number, number>;
  pendingEnableCallbacks: Array<(ready: boolean) => void>;
}

type PhaseListener = (scope: string, phase: HaConnectionLifecyclePhase) => void;

const fallbackEnvKey: object = {};
const scopeEntriesByEnv = new WeakMap<object, Map<string, ScopeLifecycleEntry>>();
const phaseListenersByEnv = new WeakMap<object, Set<PhaseListener>>();

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

function cancelPendingEnableCallbacks(entry: ScopeLifecycleEntry): void {
  if (entry.pendingEnableCallbacks.length === 0) return;
  const callbacks = entry.pendingEnableCallbacks.splice(0);
  for (const cb of callbacks) {
    try {
      cb(false);
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
      controller: new AbortController(),
      inFlightByGen: new Map(),
      pendingEnableCallbacks: [],
    };
    entries.set(scope, entry);
  }
  return entry;
}

function totalInFlight(entry: ScopeLifecycleEntry): number {
  let sum = 0;
  for (const count of entry.inFlightByGen.values()) {
    sum += count;
  }
  return sum;
}

function olderInFlight(entry: ScopeLifecycleEntry): number {
  let sum = 0;
  for (const [gen, count] of entry.inFlightByGen.entries()) {
    if (gen < entry.generation) sum += count;
  }
  return sum;
}

function notifyPhaseListeners(scope: string, phase: HaConnectionLifecyclePhase): void {
  for (const listener of [...getPhaseListeners()]) {
    try {
      listener(scope, phase);
    } catch {
      // Listener errors must never disrupt transport draining.
    }
  }
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
  return entry ? totalInFlight(entry) : 0;
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
    const draining = disabled ? totalInFlight(entry) : olderInFlight(entry);
    if (draining > 0) return "stopping";
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
  cancelPendingEnableCallbacks(entry);
  entry.generation += 1;
  entry.controller.abort();
  entry.controller = new AbortController();
  const phase: HaConnectionLifecyclePhase = totalInFlight(entry) > 0 ? "stopping" : "disabled";
  void storage;
  notifyPhaseListeners(normalized, phase);
  return phase;
}

export function requestHaScopeEnableAfterDrain(
  scope: string | null | undefined,
  onReady: (ready: boolean) => void,
  storage?: HaGateStorageLike | null,
): { readonly immediate: boolean; readonly generation: number } {
  const normalized = haConnectionScope(scope);
  if (!normalized) {
    onReady(true);
    return { immediate: true, generation: 0 };
  }
  const entry = ensureEntry(normalized);
  if (totalInFlight(entry) > 0) {
    cancelPendingEnableCallbacks(entry);
    entry.pendingEnableCallbacks = [onReady];
    notifyPhaseListeners(normalized, "stopping");
    return { immediate: false, generation: entry.generation };
  }
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
  if (!scope) {
    for (const [key, entry] of entries.entries()) {
      cancelPendingEnableCallbacks(entry);
      entry.generation += 1;
      entry.controller.abort();
      entry.controller = new AbortController();
      entries.delete(key);
    }
    return;
  }
  const normalized = haConnectionScope(scope);
  if (!normalized) return;
  const entry = entries.get(normalized);
  if (!entry) return;
  cancelPendingEnableCallbacks(entry);
  entry.generation += 1;
  entry.controller.abort();
  entry.controller = new AbortController();
  entries.delete(normalized);
}

export function acquireHaTransportLease(
  baseURL: string,
  options?: { readonly storage?: HaGateStorageLike | null },
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
  const entry = ensureEntry(scope);
  const leaseGeneration = entry.generation;
  const leaseSignal = entry.controller.signal;
  entry.inFlightByGen.set(leaseGeneration, (entry.inFlightByGen.get(leaseGeneration) ?? 0) + 1);
  let released = false;

  return {
    scope,
    generation: leaseGeneration,
    signal: leaseSignal,
    isCurrent(storage?: HaGateStorageLike | null): boolean {
      const effectiveStorage = storage === undefined ? options?.storage : storage;
      return (
        !leaseSignal.aborted &&
        entry.generation === leaseGeneration &&
        olderInFlight(entry) === 0 &&
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
      if (totalInFlight(entry) === 0) {
        if (entry.pendingEnableCallbacks.length > 0 && !isHaScopeDisabledInStorage(scope, options?.storage)) {
          const callbacks = entry.pendingEnableCallbacks.splice(0);
          entry.generation += 1;
          entry.controller = new AbortController();
          notifyPhaseListeners(scope, "enabled");
          for (const cb of callbacks) {
            cb(true);
          }
          return;
        }
        cancelPendingEnableCallbacks(entry);
        const settledPhase = isHaScopeDisabledInStorage(scope, options?.storage) ? "disabled" : "enabled";
        notifyPhaseListeners(scope, settledPhase);
      }
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

export function resetHaTransportGateForTests(): void {
  const entries = getScopeEntries();
  for (const entry of entries.values()) {
    cancelPendingEnableCallbacks(entry);
    entry.controller.abort();
  }
  entries.clear();
  getPhaseListeners().clear();
}
