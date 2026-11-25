type Admission =
  | { kind: "admitted"; generation: number }
  | { kind: "wait"; delayMs: number }
  | { kind: "limited" };

interface AccountBudget {
  reads: number;
  writes: number;
  lastRefillMs: number;
  readNotBeforeMs: number;
  generation: number;
  consecutiveLimits: number;
}

const STORAGE_PREFIX = "menumijia.miCloudBudget.";

// A full 6-second visible polling interval refills 12 reads (1,200 properties)
// and 8 reserved writes. Discovery and bursts can spend a full interval's tokens at once.
const READ_CAPACITY = 12;
const WRITE_CAPACITY = 8;
const REFILL_INTERVAL_MS = 6_000;
export const RATE_LIMIT_BACKOFF_MS = [60_000, 120_000, 240_000, 480_000, 900_000] as const;

function retryAfterMs(raw: string | undefined, nowMs: number): number {
  const value = raw?.trim();
  if (!value) return 0;
  if (/^\d+$/.test(value)) {
    const delay = Number(value) * 1000;
    return Number.isFinite(delay) ? delay : 0;
  }
  if (!/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)/.test(value)) return 0;
  const date = Date.parse(value);
  // Date.parse accepts IMF-fixdate and RFC 850; asctime lacks an explicit zone.
  const asUtc = /\d{4}$/.test(value) && !value.includes(",") ? Date.parse(value + " GMT") : date;
  return Number.isFinite(asUtc) ? Math.max(0, asUtc - nowMs) : 0;
}

export class MiCloudRateLimiter {
  private readonly budgets = new Map<string, AccountBudget>();

  constructor(
    private readonly clock = () => performance.timeOrigin + performance.now(),
    private readonly wallClock = Date.now,
    private readonly jitter = Math.random,
    // Separate Tauri webviews share the origin's storage and serialize budget updates via Web Locks.
    private readonly sharedWebviews = false,
  ) {}

  private get locks(): LockManager | undefined {
    return this.sharedWebviews ? globalThis.navigator?.locks : undefined;
  }

  private load(account: string): AccountBudget | undefined {
    const local = this.budgets.get(account);
    if (local) return local;
    if (this.locks) {
      try {
        const value = localStorage.getItem(STORAGE_PREFIX + account);
        const state = value ? JSON.parse(value) as AccountBudget | null : null;
        if (state && Number.isFinite(state.lastRefillMs) && Number.isFinite(state.reads) &&
            Number.isFinite(state.writes) && Number.isFinite(state.readNotBeforeMs) &&
            Number.isSafeInteger(state.generation) && Number.isSafeInteger(state.consecutiveLimits)) {
          return state;
        }
      } catch {
        return undefined;
      }
    }
    return undefined;
  }

  private update<T>(account: string, apply: (state: AccountBudget, nowMs: number) => T): Promise<T> {
    const update = () => {
      const nowMs = this.clock();
      const state = this.load(account) ?? {
        reads: READ_CAPACITY, writes: WRITE_CAPACITY, lastRefillMs: nowMs,
        readNotBeforeMs: 0, generation: 0, consecutiveLimits: 0,
      };
      const result = apply(state, nowMs);
      try {
        if (this.locks) {
          localStorage.setItem(STORAGE_PREFIX + account, JSON.stringify(state));
          this.budgets.delete(account);
          return result;
        }
      } catch {
        // Keep enforcing the budget locally if storage is unavailable or full.
      }
      this.budgets.set(account, state);
      return result;
    };
    const locks = this.locks;
    return locks ? locks.request(STORAGE_PREFIX + account, update) : Promise.resolve(update());
  }

  admit(account: string, userWrite: boolean): Promise<Admission> {
    return this.update(account, (state, nowMs) => {
      const elapsed = Math.max(0, nowMs - state.lastRefillMs);
      state.lastRefillMs = nowMs;
      state.reads = Math.min(READ_CAPACITY, state.reads + elapsed * READ_CAPACITY / REFILL_INTERVAL_MS);
      state.writes = Math.min(WRITE_CAPACITY, state.writes + elapsed * WRITE_CAPACITY / REFILL_INTERVAL_MS);

      if (userWrite && state.writes >= 1) {
        state.writes -= 1;
      } else if (nowMs < state.readNotBeforeMs) {
        return { kind: "limited" };
      } else if (state.reads >= 1) {
        state.reads -= 1;
      } else if (userWrite) {
        return { kind: "limited" };
      } else {
        return { kind: "wait", delayMs: (1 - state.reads) * REFILL_INTERVAL_MS / READ_CAPACITY };
      }
      return { kind: "admitted", generation: state.generation };
    });
  }

  recordLimit(account: string, retryAfter: string | undefined): Promise<void> {
    const minimumDelay = retryAfterMs(retryAfter, this.wallClock());
    return this.update(account, (state, nowMs) => {
      state.generation += 1;
      const step = Math.min(state.consecutiveLimits, RATE_LIMIT_BACKOFF_MS.length - 1);
      state.consecutiveLimits = step + 1;
      const jitter = RATE_LIMIT_BACKOFF_MS[step]! * this.jitter();
      state.readNotBeforeMs = Math.max(state.readNotBeforeMs, nowMs + minimumDelay + jitter);
    });
  }

  recordReadSuccess(account: string, generation: number): Promise<void> {
    if (!this.load(account)?.consecutiveLimits) return Promise.resolve();
    return this.update(account, (state) => {
      if (state.generation === generation) state.consecutiveLimits = 0;
    });
  }

  readCooldownMs(account: string): number {
    return Math.max(0, (this.load(account)?.readNotBeforeMs ?? 0) - this.clock());
  }

  async clear(account?: string): Promise<void> {
    if (account === undefined) {
      this.budgets.clear();
      if (this.locks) {
        let keys: string[];
        try {
          keys = Object.keys(localStorage).filter((key) => key.startsWith(STORAGE_PREFIX));
        } catch {
          return;
        }
        await Promise.all(keys.map((key) => this.clear(key.slice(STORAGE_PREFIX.length))));
      }
      return;
    }
    this.budgets.delete(account);
    await this.locks?.request(STORAGE_PREFIX + account, () => {
      try {
        localStorage.removeItem(STORAGE_PREFIX + account);
      } catch {
        // In-memory metadata is already cleared.
      }
    });
  }
}

export const miCloudRateLimiter = new MiCloudRateLimiter(undefined, undefined, undefined, true);
