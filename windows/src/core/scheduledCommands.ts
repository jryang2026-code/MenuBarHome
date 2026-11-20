import type { DeviceIntent, IntentOperation, ScheduledCommand } from "./models.js";
import { partitionDueTimers } from "./models.js";

export const SCHEDULED_COMMANDS_STORAGE_KEY = "menumijia.windows.scheduledCommands.v1";

/**
 * Pause reason owned by the timer switch (P5d-TW).
 *
 * It is stored beside the capability reasons in `PausedScheduledCommand.pausedCapabilities`, so one
 * entry can be held by several independent owners at once and each owner releases only its own
 * reason. The `feature:` prefix is deliberate: it can never collide with a manifest capability ID,
 * and `revalidatePausedTimer` treats an unknown reason as "keep paused", so no capability resume
 * path (account / connection / device type) can release a timer this switch is holding, and this
 * switch cannot release a timer those paths are holding. Only `releaseFeaturePause` removes it.
 */
export const TIMER_FEATURE_PAUSE_REASON = "feature:scheduled-commands";

/** The subset of the settings record the timer switch reads. */
export interface TimerFeatureSwitchSettings {
  readonly scheduledCommandsEnabled?: boolean;
}

/**
 * 定时任务 switch (P5d-TW). Only an explicit `false` turns timers off: a missing key is the state of
 * an upgrade (and of a fresh install whose manifest has no timer row), which keeps the always-on
 * behavior every existing user already had.
 */
export function isScheduledCommandsEnabled(settings: TimerFeatureSwitchSettings): boolean {
  return settings.scheduledCommandsEnabled !== false;
}

/**
 * Returns target IDs referenced by `item.intents` that exist in neither `devices` nor `scenes`
 * of the active home (`HomeStore+Assistant.swift:missingPlanTargets`, ADR-0019).
 */
export function missingScheduledCommandTargets(
  item: ScheduledCommand,
  devices: readonly { readonly id: string }[],
  scenes: readonly { readonly id: string }[],
): string[] {
  if (!item.intents || item.intents.length === 0) return [];
  const deviceIds = new Set(devices.map((device) => device.id));
  const sceneIds = new Set(scenes.map((scene) => scene.id));
  const missing: string[] = [];
  for (const intent of item.intents) {
    if (!deviceIds.has(intent.targetId) && !sceneIds.has(intent.targetId)) {
      missing.push(intent.targetId);
    }
  }
  return missing;
}

export interface PausedScheduledCommand {
  readonly command: ScheduledCommand;
  readonly originalPartition: "waiting" | "missed";
  readonly sourceScopes: readonly string[];
  readonly pausedCapabilities: readonly string[];
}

export interface TimerQueue {
  scheduledCommands: ScheduledCommand[];
  missedScheduledCommands: ScheduledCommand[];
  pausedScheduledCommands?: PausedScheduledCommand[];
}

interface TimerStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function parseOperation(value: unknown): IntentOperation | null {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "power": return typeof value.isOn === "boolean" ? { kind: value.kind, isOn: value.isOn } : null;
    case "brightness": return finite(value.percent) ? { kind: value.kind, percent: value.percent } : null;
    case "brightnessStep": return finite(value.delta) ? { kind: value.kind, delta: value.delta } : null;
    case "colorTemperature": return finite(value.kelvin) ? { kind: value.kind, kelvin: value.kelvin } : null;
    case "lightEffect": return typeof value.effect === "string" ? { kind: value.kind, effect: value.effect } : null;
    case "hvacMode": return typeof value.mode === "string" ? { kind: value.kind, mode: value.mode } : null;
    case "targetTemperature": return finite(value.celsius) ? { kind: value.kind, celsius: value.celsius } : null;
    case "temperatureStep": return finite(value.delta) ? { kind: value.kind, delta: value.delta } : null;
    case "fanSpeed": return typeof value.speed === "string" ? { kind: value.kind, speed: value.speed } : null;
    case "oscillation": return typeof value.enabled === "boolean" ? { kind: value.kind, enabled: value.enabled } : null;
    case "activateScene": return { kind: value.kind };
    default: return null;
  }
}

function parseTimer(value: unknown): ScheduledCommand | null {
  if (!isRecord(value) || typeof value.id !== "string" || !/^[a-zA-Z0-9_-]{1,128}$/.test(value.id) ||
      typeof value.command !== "string" || !value.command || typeof value.reply !== "string" ||
      !finite(value.delaySeconds) || value.delaySeconds <= 0 || value.delaySeconds > 86400 ||
      !finite(value.fireTimestampMs) || value.fireTimestampMs < 0 ||
      !Array.isArray(value.intents) || value.intents.length === 0) return null;
  const intents: DeviceIntent[] = [];
  for (const intent of value.intents) {
    if (!isRecord(intent) || typeof intent.targetId !== "string" || !intent.targetId) return null;
    const operation = parseOperation(intent.operation);
    if (!operation) return null;
    intents.push({ targetId: intent.targetId, operation });
  }
  const sourceScopes = Array.isArray(value.sourceScopes)
    ? value.sourceScopes.filter((s): s is string => typeof s === "string" && s.length > 0)
    : [];
  return {
    id: value.id, command: value.command, reply: value.reply,
    delaySeconds: value.delaySeconds, fireTimestampMs: value.fireTimestampMs, intents,
    ...(sourceScopes.length > 0 ? { sourceScopes } : {}),
  };
}

function parsePausedTimer(value: unknown): PausedScheduledCommand | null {
  if (!isRecord(value)) return null;
  const command = parseTimer(value.command);
  if (!command || (value.originalPartition !== "waiting" && value.originalPartition !== "missed")) return null;
  if (!Array.isArray(value.sourceScopes) || !Array.isArray(value.pausedCapabilities)) return null;
  return {
    command,
    originalPartition: value.originalPartition,
    sourceScopes: value.sourceScopes.filter((s): s is string => typeof s === "string" && s.length > 0),
    pausedCapabilities: value.pausedCapabilities.filter((c): c is string => typeof c === "string" && c.length > 0),
  };
}

function parseQueues(
  raw: string | null,
): { readonly queues: Map<string, TimerQueue>; readonly hadCorruption: boolean } | null {
  if (raw === null) return { queues: new Map(), hadCorruption: false };
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.sources)) return null;
    const sources = new Map<string, TimerQueue>();
    let hadCorruption = false;
    for (const source of value.sources) {
      if (
        !isRecord(source) ||
        typeof source.identity !== "string" ||
        !source.identity ||
        sources.has(source.identity) ||
        !Array.isArray(source.scheduledCommands) ||
        !Array.isArray(source.missedScheduledCommands) ||
        (source.pausedScheduledCommands !== undefined && !Array.isArray(source.pausedScheduledCommands))
      ) {
        hadCorruption = true;
        continue;
      }
      const seenIds = new Set<string>();
      const scheduledCommands: ScheduledCommand[] = [];
      for (const rawItem of source.scheduledCommands) {
        const parsed = parseTimer(rawItem);
        if (!parsed || seenIds.has(parsed.id)) {
          hadCorruption = true;
          continue;
        }
        seenIds.add(parsed.id);
        scheduledCommands.push(parsed);
      }
      const missedScheduledCommands: ScheduledCommand[] = [];
      for (const rawItem of source.missedScheduledCommands) {
        const parsed = parseTimer(rawItem);
        if (!parsed || seenIds.has(parsed.id)) {
          hadCorruption = true;
          continue;
        }
        seenIds.add(parsed.id);
        missedScheduledCommands.push(parsed);
      }
      const pausedScheduledCommands: PausedScheduledCommand[] = [];
      for (const rawItem of source.pausedScheduledCommands ?? []) {
        const parsed = parsePausedTimer(rawItem);
        if (!parsed || seenIds.has(parsed.command.id)) {
          hadCorruption = true;
          continue;
        }
        seenIds.add(parsed.command.id);
        pausedScheduledCommands.push(parsed);
      }
      sources.set(source.identity, { scheduledCommands, missedScheduledCommands, pausedScheduledCommands });
    }
    return { queues: sources, hadCorruption };
  } catch {
    return null;
  }
}

export class ScheduledCommandStore {
  private readonly sources: Map<string, TimerQueue>;
  private readonly unavailable: TimerQueue = { scheduledCommands: [], missedScheduledCommands: [], pausedScheduledCommands: [] };
  private unreadableRaw: string | null = null;
  private storageReadable = true;

  constructor(private readonly storage: TimerStorage, nowMs = Date.now()) {
    let raw: string | null = null;
    try { raw = storage.getItem(SCHEDULED_COMMANDS_STORAGE_KEY); } catch {
      this.storageReadable = false;
    }
    const parsed = parseQueues(raw);
    this.sources = parsed?.queues ?? new Map();
    if (!parsed || parsed.hadCorruption) this.unreadableRaw = raw;
    let changed = false;
    for (const queue of this.sources.values()) {
      const expired = queue.scheduledCommands.filter((item) => item.fireTimestampMs <= nowMs);
      queue.scheduledCommands = queue.scheduledCommands.filter((item) => item.fireTimestampMs > nowMs);
      queue.missedScheduledCommands.push(...expired);
      changed ||= expired.length > 0;
    }
    if (changed) this.persist();
  }

  hasStorageError(): boolean {
    return !this.storageReadable || this.unreadableRaw !== null;
  }

  entries(): ReadonlyArray<readonly [string, TimerQueue]> {
    return [...this.sources.entries()];
  }

  snapshotQueues(): Map<string, TimerQueue> {
    return structuredClone(this.sources);
  }

  restoreQueues(snapshot: ReadonlyMap<string, TimerQueue>): boolean {
    for (const key of [...this.sources.keys()]) {
      if (!snapshot.has(key)) this.sources.delete(key);
    }
    for (const [key, val] of snapshot.entries()) {
      const cloned = structuredClone(val);
      const existing = this.sources.get(key);
      if (existing) {
        existing.scheduledCommands = cloned.scheduledCommands;
        existing.missedScheduledCommands = cloned.missedScheduledCommands;
        existing.pausedScheduledCommands = cloned.pausedScheduledCommands ?? [];
      } else {
        this.sources.set(key, cloned);
      }
    }
    return this.persist();
  }

  /**
   * Parks every waiting timer for the timer switch (P5d-TW) and records this switch as one more
   * pause reason on the ones already paused: the plan, the fire time, the source scopes and the
   * original partition all stay, so re-enabling can revalidate instead of guessing. Missed timers
   * stay in the missed partition — they are already off the automatic path.
   *
   * Returns whether anything changed; a queue that is already parked is left byte-for-byte alone so
   * the caller can skip the write. `scopesForQueue` stamps a timer that never recorded its own
   * scopes, so a legacy entry can still be revalidated against the queue it came from.
   */
  pauseForFeatureSwitch(scopesForQueue?: (identity: string) => readonly string[]): boolean {
    let changed = false;
    for (const [identity, queue] of this.sources) {
      const paused = queue.pausedScheduledCommands ?? [];
      const restamped: PausedScheduledCommand[] = [];
      let queueChanged = false;
      for (const entry of paused) {
        if (entry.pausedCapabilities.includes(TIMER_FEATURE_PAUSE_REASON)) {
          restamped.push(entry);
          continue;
        }
        restamped.push({ ...entry, pausedCapabilities: [...entry.pausedCapabilities, TIMER_FEATURE_PAUSE_REASON] });
        queueChanged = true;
      }
      const parked = queue.scheduledCommands.map((item): PausedScheduledCommand => ({
        command: item,
        originalPartition: "waiting",
        sourceScopes: item.sourceScopes ? [...item.sourceScopes] : [...(scopesForQueue?.(identity) ?? [])],
        pausedCapabilities: [TIMER_FEATURE_PAUSE_REASON],
      }));
      if (parked.length > 0) {
        queue.scheduledCommands = [];
        queueChanged = true;
      }
      if (!queueChanged) continue;
      queue.pausedScheduledCommands = [...restamped, ...parked];
      changed = true;
    }
    return changed;
  }

  /** True while any queue still has a timer the automatic path could pick up. */
  hasWaitingTimers(): boolean {
    for (const queue of this.sources.values()) if (queue.scheduledCommands.length > 0) return true;
    return false;
  }

  /**
   * Queues that still hold this switch's pause reason. A queue whose source is not active keeps the
   * reason until that source is back, so its timers cannot be released without a revalidation.
   */
  featurePausedIdentities(): string[] {
    const identities: string[] = [];
    for (const [identity, queue] of this.sources) {
      if ((queue.pausedScheduledCommands ?? []).some((entry) => entry.pausedCapabilities.includes(TIMER_FEATURE_PAUSE_REASON))) {
        identities.push(identity);
      }
    }
    return identities;
  }

  /** True while at least one entry is still held by the timer switch. */
  hasFeaturePause(): boolean {
    return this.featurePausedIdentities().length > 0;
  }

  /**
   * Drops this switch's pause reason and nothing else: whatever another owner still records (a
   * disabled device type, a disabled account or connection) keeps holding the entry, and the
   * caller's revalidation decides between waiting and missed afterwards.
   *
   * `identities` limits the release to queues whose source was verified in this pass.
   *
   * Returns whether anything changed.
   */
  releaseFeaturePause(identities?: ReadonlySet<string>): boolean {
    let changed = false;
    for (const [identity, queue] of this.sources) {
      if (identities !== undefined && !identities.has(identity)) continue;
      const paused = queue.pausedScheduledCommands ?? [];
      if (!paused.some((entry) => entry.pausedCapabilities.includes(TIMER_FEATURE_PAUSE_REASON))) continue;
      queue.pausedScheduledCommands = paused.map((entry) =>
        entry.pausedCapabilities.includes(TIMER_FEATURE_PAUSE_REASON)
          ? { ...entry, pausedCapabilities: entry.pausedCapabilities.filter((cap) => cap !== TIMER_FEATURE_PAUSE_REASON) }
          : entry,
      );
      changed = true;
    }
    return changed;
  }

  queue(identity: string | null): TimerQueue {
    if (identity === null) return this.unavailable;
    let queue = this.sources.get(identity);
    if (!queue) {
      queue = { scheduledCommands: [], missedScheduledCommands: [], pausedScheduledCommands: [] };
      this.sources.set(identity, queue);
    }
    queue.pausedScheduledCommands ??= [];
    return queue;
  }

  persist(): boolean {
    if (!this.storageReadable) return false;
    try {
      if (this.unreadableRaw !== null) {
        const base = `${SCHEDULED_COMMANDS_STORAGE_KEY}.unreadable`;
        let key = base;
        let suffix = 0;
        while (this.storage.getItem(key) !== null) key = `${base}.${++suffix}`;
        this.storage.setItem(key, this.unreadableRaw);
        this.unreadableRaw = null;
      }
      this.storage.setItem(SCHEDULED_COMMANDS_STORAGE_KEY, JSON.stringify({
        version: 1,
        sources: [...this.sources].map(([identity, queue]) => ({
          identity,
          scheduledCommands: queue.scheduledCommands,
          missedScheduledCommands: queue.missedScheduledCommands,
          ...(queue.pausedScheduledCommands?.length ? { pausedScheduledCommands: queue.pausedScheduledCommands } : {}),
        })),
      }));
      return true;
    } catch { return false; }
  }

  takeDue(
    identity: string | null,
    ready: boolean,
    nowMs: number,
    knownTargetIds?: ReadonlySet<string>,
  ): ScheduledCommand[] | null {
    const runnable: ScheduledCommand[] = [];
    let changed = false;
    for (const [owner, queue] of this.sources) {
      const { run, missed, remaining } = partitionDueTimers(queue.scheduledCommands, nowMs);
      if (run.length === 0 && missed.length === 0) continue;
      queue.scheduledCommands = remaining;
      queue.missedScheduledCommands.push(...missed);
      if (owner === identity && ready) {
        for (const item of run) {
          const missingTarget =
            knownTargetIds !== undefined &&
            Boolean(item.intents?.some((intent) => !knownTargetIds.has(intent.targetId)));
          if (missingTarget) queue.missedScheduledCommands.push(item);
          else runnable.push(item);
        }
      } else {
        queue.missedScheduledCommands.push(...run);
      }
      changed = true;
    }
    if (changed && !this.persist()) {
      // A task cannot execute until its removal is durable, or restart could execute it twice.
      this.queue(identity).missedScheduledCommands.push(...runnable);
      return null;
    }
    return runnable;
  }
}
