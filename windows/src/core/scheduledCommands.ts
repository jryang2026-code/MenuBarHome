import type { DeviceIntent, IntentOperation, ScheduledCommand } from "./models.js";
import { partitionDueTimers } from "./models.js";

export const SCHEDULED_COMMANDS_STORAGE_KEY = "menumijia.windows.scheduledCommands.v1";

export interface TimerQueue {
  scheduledCommands: ScheduledCommand[];
  missedScheduledCommands: ScheduledCommand[];
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
  return {
    id: value.id, command: value.command, reply: value.reply,
    delaySeconds: value.delaySeconds, fireTimestampMs: value.fireTimestampMs, intents,
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
        !Array.isArray(source.missedScheduledCommands)
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
      sources.set(source.identity, { scheduledCommands, missedScheduledCommands });
    }
    return { queues: sources, hadCorruption };
  } catch {
    return null;
  }
}

export class ScheduledCommandStore {
  private readonly sources: Map<string, TimerQueue>;
  private readonly unavailable: TimerQueue = { scheduledCommands: [], missedScheduledCommands: [] };
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

  queue(identity: string | null): TimerQueue {
    if (identity === null) return this.unavailable;
    let queue = this.sources.get(identity);
    if (!queue) {
      queue = { scheduledCommands: [], missedScheduledCommands: [] };
      this.sources.set(identity, queue);
    }
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
        sources: [...this.sources].map(([identity, queue]) => ({ identity, ...queue })),
      }));
      return true;
    } catch { return false; }
  }

  takeDue(identity: string | null, ready: boolean, nowMs: number): ScheduledCommand[] | null {
    const runnable: ScheduledCommand[] = [];
    let changed = false;
    for (const [owner, queue] of this.sources) {
      const { run, missed, remaining } = partitionDueTimers(queue.scheduledCommands, nowMs);
      if (run.length === 0 && missed.length === 0) continue;
      queue.scheduledCommands = remaining;
      queue.missedScheduledCommands.push(...missed);
      if (owner === identity && ready) runnable.push(...run);
      else queue.missedScheduledCommands.push(...run);
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
