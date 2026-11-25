import { isDeviceActiveOn, type SmartDevice } from "./models.js";
import { defaultSafetyStorage, type KeyValueStorageLike } from "./safetyAndHealth.js";

/** Single field captured before a context rule writes it (mirrors macOS `AutomationContextField`). */
export type AutomationContextField = "power";

export interface AutomationContextValue {
  readonly field: AutomationContextField;
  readonly boolValue: boolean;
}

export interface AutomationContextSnapshot {
  readonly deviceId: string;
  readonly baseline: AutomationContextValue;
  readonly applied: AutomationContextValue;
}

export interface AutomationContextFrame {
  readonly ruleId: string;
  readonly enteredAtMs: number;
  readonly snapshots: readonly AutomationContextSnapshot[];
}

export interface AutomationContextRestoreIntent {
  readonly targetId: string;
  readonly operation: { readonly kind: "power"; readonly isOn: boolean };
}

export interface AutomationContextRestorePlan {
  readonly frame: AutomationContextFrame;
  readonly intents: readonly AutomationContextRestoreIntent[];
}

export function contextValuesEqual(a: AutomationContextValue, b: AutomationContextValue): boolean {
  return a.field === b.field && a.boolValue === b.boolValue;
}

export function deviceAutomationContextValue(device: SmartDevice): AutomationContextValue {
  return { field: "power", boolValue: isDeviceActiveOn(device) };
}

function parseStoredValue(raw: unknown): AutomationContextValue | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  return obj.field === "power" && typeof obj.boolValue === "boolean"
    ? { field: "power", boolValue: obj.boolValue }
    : null;
}

function parseStoredSnapshot(raw: unknown): AutomationContextSnapshot | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const deviceId = typeof obj.deviceId === "string" ? obj.deviceId : typeof obj.deviceID === "string" ? obj.deviceID : null;
  const baseline = parseStoredValue(obj.baseline);
  const applied = parseStoredValue(obj.applied);
  return deviceId && deviceId.trim() !== "" && baseline && applied ? { deviceId, baseline, applied } : null;
}

function parseStoredFrame(raw: unknown): AutomationContextFrame | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const ruleId = typeof obj.ruleId === "string" ? obj.ruleId : typeof obj.ruleID === "string" ? obj.ruleID : null;
  const enteredAtMs =
    typeof obj.enteredAtMs === "number" && Number.isFinite(obj.enteredAtMs)
      ? obj.enteredAtMs
      : typeof obj.enteredAt === "number" && Number.isFinite(obj.enteredAt)
        ? (obj.enteredAt < 1e11 ? obj.enteredAt * 1000 : obj.enteredAt)
        : null;
  if (!ruleId || ruleId.trim() === "" || enteredAtMs === null || !Array.isArray(obj.snapshots)) return null;
  const snapshots = obj.snapshots.map(parseStoredSnapshot).filter((s): s is AutomationContextSnapshot => s !== null);
  return snapshots.length > 0 ? { ruleId, enteredAtMs, snapshots } : null;
}

/**
 * Persistent LIFO state for context automations (mirrors macOS `AutomationContextStack`
 * and `Tests/Fixtures/context_stack_golden.json`).
 */
export class AutomationContextStack {
  public static readonly storageKey = "automation_context_stack_v1";
  public static readonly maximumFrames = 32;
  public static readonly maximumAgeMs = 12 * 60 * 60 * 1000;

  private readonly storage: KeyValueStorageLike | null;
  private frames: AutomationContextFrame[] = [];

  constructor(storage: KeyValueStorageLike | null = defaultSafetyStorage(), nowMs: number = Date.now()) {
    this.storage = storage;
    if (storage) {
      try {
        const parsed = JSON.parse(storage.getItem(AutomationContextStack.storageKey) ?? "null") as unknown;
        if (Array.isArray(parsed)) {
          this.frames = parsed
            .map(parseStoredFrame)
            .filter((f): f is AutomationContextFrame => f !== null && nowMs - f.enteredAtMs <= AutomationContextStack.maximumAgeMs)
            .slice(-AutomationContextStack.maximumFrames);
        }
      } catch {
        this.frames = [];
      }
    }
    this.persist();
  }

  public get count(): number { return this.frames.length; }
  public get isEmpty(): boolean { return this.frames.length === 0; }
  public get allFrames(): readonly AutomationContextFrame[] { return this.frames; }

  public push(ruleId: string, snapshots: readonly AutomationContextSnapshot[], nowMs: number = Date.now()): AutomationContextFrame | null {
    if (snapshots.length === 0) return null;
    const frame: AutomationContextFrame = { ruleId, enteredAtMs: nowMs, snapshots: [...snapshots] };
    this.frames.push(frame);
    if (this.frames.length > AutomationContextStack.maximumFrames) {
      this.frames.splice(0, this.frames.length - AutomationContextStack.maximumFrames);
    }
    this.persist();
    return frame;
  }

  public pop(ruleId: string, liveValues: Readonly<Record<string, AutomationContextValue>>, nowMs: number = Date.now()): AutomationContextRestoreIntent[] {
    let target: AutomationContextFrame | undefined;
    for (let i = this.frames.length - 1; i >= 0; i -= 1) {
      if (this.frames[i]!.ruleId === ruleId) { target = this.frames[i]!; break; }
    }
    if (!target) return [];
    const plan = this.prepareRestore(target, liveValues, nowMs);
    if (!plan) return [];
    this.commitRestore(plan, new Set(plan.intents.map((i) => i.targetId)));
    return [...plan.intents];
  }

  public prepareRestore(
    frame: AutomationContextFrame,
    liveValues: Readonly<Record<string, AutomationContextValue>>,
    nowMs: number = Date.now(),
  ): AutomationContextRestorePlan | null {
    this.pruneExpired(nowMs);
    const index = this.frames.findIndex((f) => f.ruleId === frame.ruleId && f.enteredAtMs === frame.enteredAtMs);
    if (index === -1) return null;
    const stored = this.frames[index]!;
    const retained = stored.snapshots.filter((s) => {
      const live = liveValues[s.deviceId];
      return !live || contextValuesEqual(live, s.applied);
    });
    const eligible = retained.flatMap((snapshot) => {
      const live = liveValues[snapshot.deviceId];
      if (!live || !contextValuesEqual(live, snapshot.applied) || snapshot.baseline.field !== "power") return [];
      return [{ snapshot, intent: { targetId: snapshot.deviceId, operation: { kind: "power" as const, isOn: snapshot.baseline.boolValue } } }];
    });
    if (retained.length === 0) {
      this.frames.splice(index, 1);
      this.persist();
      return null;
    }
    const updated: AutomationContextFrame = { ruleId: stored.ruleId, enteredAtMs: stored.enteredAtMs, snapshots: retained };
    this.frames[index] = updated;
    this.persist();
    if (eligible.length === 0) return null;
    return {
      frame: { ruleId: updated.ruleId, enteredAtMs: updated.enteredAtMs, snapshots: eligible.map((e) => e.snapshot) },
      intents: eligible.map((e) => e.intent),
    };
  }

  public commitRestore(plan: AutomationContextRestorePlan, restoredDeviceIds: ReadonlySet<string>): void {
    const index = this.frames.findIndex((f) => f.ruleId === plan.frame.ruleId && f.enteredAtMs === plan.frame.enteredAtMs);
    if (index === -1) return;
    const remaining = this.frames[index]!.snapshots.filter((s) => !restoredDeviceIds.has(s.deviceId));
    if (remaining.length === 0) this.frames.splice(index, 1);
    else this.frames[index] = { ...this.frames[index]!, snapshots: remaining };
    this.persist();
  }

  public pruneExpired(nowMs: number = Date.now()): void {
    const remaining = this.frames.filter((f) => nowMs - f.enteredAtMs <= AutomationContextStack.maximumAgeMs);
    if (remaining.length === this.frames.length) return;
    this.frames = remaining;
    this.persist();
  }

  private persist(): void {
    if (!this.storage) return;
    try { this.storage.setItem(AutomationContextStack.storageKey, JSON.stringify(this.frames)); } catch {}
  }
}
