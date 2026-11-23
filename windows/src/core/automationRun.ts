import type { AutomationTrigger } from "./automationEngine.js";
import type { KeyValueStorageLike } from "./safetyAndHealth.js";

export type AutomationExecutionMode = "single" | "restart";

export const AUTOMATION_SKIP_REASONS = [
  "conditionFalse", "singleAlreadyRunning", "screenLocked", "writeGateDenied", "deviceOffline",
  "error", "cooldown", "superseded", "noActionNeeded",
] as const;
export type AutomationSkipReason = (typeof AUTOMATION_SKIP_REASONS)[number];

export type AutomationRunEntry = {
  readonly ruleId: string;
  readonly trigger: AutomationTrigger | "manual";
  readonly time: number;
} & ({ readonly result: "executed" } | { readonly result: "skipped"; readonly reason: AutomationSkipReason });

export class AutomationRunHistory {
  static readonly storageKey = "automation_run_history_v1";
  static readonly limit = 200;

  constructor(private readonly storage: KeyValueStorageLike) {}

  load(): AutomationRunEntry[] {
    try {
      const value = JSON.parse(this.storage.getItem(AutomationRunHistory.storageKey) ?? "[]") as unknown;
      if (!Array.isArray(value)) return [];
      return value.slice(0, AutomationRunHistory.limit).filter((entry: unknown): entry is AutomationRunEntry => {
        if (!entry || typeof entry !== "object") return false;
        const row = entry as Partial<AutomationRunEntry>;
        return typeof row.ruleId === "string" && typeof row.trigger === "string" && Number.isFinite(row.time)
          && (row.result === "executed" || (row.result === "skipped" && row.reason !== undefined && AUTOMATION_SKIP_REASONS.includes(row.reason)));
      });
    } catch {
      return [];
    }
  }

  append(entry: AutomationRunEntry): void {
    try {
      const entries = [entry, ...this.load()].slice(0, AutomationRunHistory.limit);
      this.storage.setItem(AutomationRunHistory.storageKey, JSON.stringify(entries));
    } catch {
      // Storage failure must not interrupt device execution.
    }
  }
}

export class AutomationRunState {
  private current: symbol | undefined;

  get isRunning(): boolean { return this.current !== undefined; }

  start(id: symbol, mode: AutomationExecutionMode): boolean {
    if (this.isRunning && mode === "single") return false;
    this.current = id;
    return true;
  }

  owns(id: symbol): boolean { return this.current === id; }

  finish(id: symbol): void {
    if (this.owns(id)) this.current = undefined;
  }
}
