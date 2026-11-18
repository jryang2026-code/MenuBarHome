/**
 * Connection-source epoch (GLOSSARY.md「SourceEpoch（连接源代际）」).
 *
 * Three nested levels track how far the world moved since async work started:
 * `source` (the connection source itself was replaced — account, backend,
 * endpoint) ⊃ `home` (the selected home inside the same source) ⊃ `localWrite`
 * (a local control write only). Advancing a level cascades to every level
 * below it, so a token captured before any switch needs a single comparison
 * to detect staleness.
 *
 * Cloud sync runs live on a separate private counter: `claimSyncRun` hands a
 * refresh a `SyncRunToken` that a newer claim, a source switch or a home
 * switch supersedes, while a local control write does not. A claim never
 * touches the three levels — "a sync run started" is not "the home changed"
 * nor "a control write happened" — so tokens captured before a claim stay
 * current, and `current at localWrite implies current everywhere` holds.
 *
 * This module is pure: it must not import app, host or DOM types.
 */

export type EpochLevel = "source" | "home" | "localWrite";

/**
 * The sentinel `EpochToken.guard` / `SyncRunToken.guard` resolve to instead
 * of the value when the epoch moved on while the promise was in flight.
 * Unique symbol so a stale result can never be confused with a legitimate one.
 */
export const STALE: unique symbol = Symbol("SourceEpoch.stale");
export type STALE = typeof STALE;

/** A point-in-time snapshot of the epoch; see `SourceEpoch.capture`. */
export interface EpochToken {
  /**
   * True iff the counter for `level` has not moved since capture. Because
   * every advance cascades downwards, a token current at `localWrite` is also
   * current at every level above it (nothing advanced at all), while a token
   * current at `source` may still be stale at `home`/`localWrite`.
   */
  isCurrent(level?: EpochLevel): boolean;
  /**
   * Settles to `STALE` when the token is no longer current at `level` by the
   * time the promise settles. Rejections propagate unchanged.
   */
  guard<T>(promise: Promise<T>, level?: EpochLevel): Promise<T | STALE>;
}

/**
 * Ownership of the single cloud-sync run. Current only while no newer claim
 * has taken over and no source/home switch has happened; a local control
 * write does not take the wire away from a running sync.
 */
export interface SyncRunToken {
  /** True iff this run still owns the cloud sync. */
  isCurrent(): boolean;
  /**
   * Settles to `STALE` when a newer run took over before the promise
   * settled. Rejections propagate unchanged.
   */
  guard<T>(promise: Promise<T>): Promise<T | STALE>;
}

interface EpochCounts {
  readonly source: number;
  readonly home: number;
  readonly localWrite: number;
}

export class SourceEpoch {
  private sourceCount = 0;
  private homeCount = 0;
  private localCount = 0;
  private syncRunCount = 0;

  /**
   * Advances `level` and every level below it (source ⊃ home ⊃ localWrite).
   * A source or home switch also supersedes the running cloud sync.
   */
  public advance(level: EpochLevel): void {
    switch (level) {
      case "source":
        this.sourceCount += 1;
        this.homeCount += 1;
        this.localCount += 1;
        this.syncRunCount += 1;
        return;
      case "home":
        this.homeCount += 1;
        this.localCount += 1;
        this.syncRunCount += 1;
        return;
      case "localWrite":
        this.localCount += 1;
        return;
    }
  }

  /**
   * Claims ownership of the cloud-sync run for a refresh: the claim
   * supersedes any earlier in-flight run, and a later claim,
   * `advance("source")` or `advance("home")` supersedes this one. The claim
   * advances ONLY the private sync-run counter — never the `home` level (a
   * background refresh is not a home change) nor `localWrite` (not a control
   * write), so tokens captured before the claim stay current.
   */
  public claimSyncRun(): SyncRunToken {
    this.syncRunCount += 1;
    const runCount = this.syncRunCount;
    return {
      isCurrent: () => this.syncRunCount === runCount,
      guard: <T>(promise: Promise<T>) =>
        promise.then((value: T) => (this.syncRunCount === runCount ? value : STALE)),
    };
  }

  public capture(): EpochToken {
    const counts: EpochCounts = {
      source: this.sourceCount,
      home: this.homeCount,
      localWrite: this.localCount,
    };
    const countAt = (level: EpochLevel): number => {
      if (level === "source") return this.sourceCount;
      if (level === "home") return this.homeCount;
      return this.localCount;
    };
    return {
      isCurrent: (level: EpochLevel = "localWrite") => countAt(level) === counts[level],
      guard: <T>(promise: Promise<T>, level: EpochLevel = "localWrite") =>
        promise.then((value: T) => (countAt(level) === counts[level] ? value : STALE)),
    };
  }

  /** How many times the connection source was replaced. */
  public get sourceRevision(): number {
    return this.sourceCount;
  }
}
