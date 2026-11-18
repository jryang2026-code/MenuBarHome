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
 * This module is pure: it must not import app, host or DOM types.
 */

export type EpochLevel = "source" | "home" | "localWrite";

/**
 * The sentinel `EpochToken.guard` resolves to instead of the value when the
 * epoch moved on while the promise was in flight. Unique symbol so a stale
 * result can never be confused with a legitimate one.
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

interface EpochCounts {
  readonly source: number;
  readonly home: number;
  readonly localWrite: number;
}

export class SourceEpoch {
  private sourceCount = 0;
  private homeCount = 0;
  private localCount = 0;

  /** Advances `level` and every level below it (source ⊃ home ⊃ localWrite). */
  public advance(level: EpochLevel): void {
    switch (level) {
      case "source":
        this.sourceCount += 1;
        this.homeCount += 1;
        this.localCount += 1;
        return;
      case "home":
        this.homeCount += 1;
        this.localCount += 1;
        return;
      case "localWrite":
        this.localCount += 1;
        return;
    }
  }

  /**
   * Claims the home generation for a new cloud-sync run and returns the new
   * `homeGeneration`. This is the old `++syncGeneration` (cloudRefresh.ts): a
   * refresh starting supersedes older in-flight sync runs, but must not look
   * like a home switch or a control write, so it advances ONLY the home
   * counter without cascading to `localWrite`.
   */
  public claimSyncRun(): number {
    this.homeCount += 1;
    return this.homeCount;
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

  /** Home-level generation; equals today's `syncGeneration` semantics. */
  public get homeGeneration(): number {
    return this.homeCount;
  }

  /** Local-write revision; equals today's `localControlRevision` semantics. */
  public get localRevision(): number {
    return this.localCount;
  }
}
