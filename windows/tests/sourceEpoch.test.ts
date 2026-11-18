import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { STALE, SourceEpoch } from "../src/ui/sourceEpoch.js";

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (error: unknown) => void } {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("SourceEpoch cascade", () => {
  it("advances only the levels at and below the requested one", () => {
    const epoch = new SourceEpoch();
    assert.equal(epoch.sourceRevision, 0);
    const start = epoch.capture();
    assert.equal(start.isCurrent("source"), true);
    assert.equal(start.isCurrent("home"), true);
    assert.equal(start.isCurrent("localWrite"), true);

    epoch.advance("localWrite");
    assert.equal(start.isCurrent("source"), true, "a local write never touches the source level");
    assert.equal(start.isCurrent("home"), true, "a local write never touches the home level");
    assert.equal(start.isCurrent("localWrite"), false);

    epoch.advance("home");
    assert.equal(start.isCurrent("source"), true, "a home switch never touches the source level");
    assert.equal(start.isCurrent("home"), false);
    assert.equal(start.isCurrent("localWrite"), false);
  });

  it("cascades a home switch to the local-write level only downwards", () => {
    const epoch = new SourceEpoch();
    const fresh = epoch.capture();
    epoch.advance("home");
    assert.equal(fresh.isCurrent("home"), false);
    assert.equal(fresh.isCurrent("localWrite"), false, "a home switch also advances the local-write level");

    const afterHome = epoch.capture();
    epoch.advance("localWrite");
    assert.equal(afterHome.isCurrent("home"), true, "a local write never touches the home level");
    assert.equal(afterHome.isCurrent("localWrite"), false);
  });

  it("cascades a source switch to every level", () => {
    const epoch = new SourceEpoch();
    const before = epoch.capture();
    epoch.advance("source");
    assert.equal(epoch.sourceRevision, 1);
    assert.equal(before.isCurrent("source"), false);
    assert.equal(before.isCurrent("home"), false, "a source switch also advances the home level");
    assert.equal(before.isCurrent("localWrite"), false, "a source switch also advances the local-write level");
  });
});

describe("SourceEpoch.claimSyncRun", () => {
  it("claims the sync run without touching the home or local-write levels", () => {
    const epoch = new SourceEpoch();
    const before = epoch.capture();
    const run = epoch.claimSyncRun();
    assert.equal(before.isCurrent("source"), true, "a sync claim is not a source switch");
    assert.equal(before.isCurrent("home"), true, "a sync claim is not a home change");
    assert.equal(before.isCurrent("localWrite"), true, "a sync claim is not a control write");
    assert.equal(run.isCurrent(), true, "the claim owns the run it created");
  });

  it("supersedes the previous claim", () => {
    const epoch = new SourceEpoch();
    const first = epoch.claimSyncRun();
    assert.equal(first.isCurrent(), true);
    const second = epoch.claimSyncRun();
    assert.equal(first.isCurrent(), false, "each claim supersedes the previous sync run");
    assert.equal(second.isCurrent(), true);
  });

  it("is superseded by source and home advances but not by a local write", () => {
    const epoch = new SourceEpoch();

    const localRun = epoch.claimSyncRun();
    epoch.advance("localWrite");
    assert.equal(localRun.isCurrent(), true, "a local write does not cancel the running sync");

    const homeRun = epoch.claimSyncRun();
    epoch.advance("home");
    assert.equal(homeRun.isCurrent(), false, "a home switch supersedes the running sync");

    const sourceRun = epoch.claimSyncRun();
    epoch.advance("source");
    assert.equal(sourceRun.isCurrent(), false, "a source switch supersedes the running sync");
  });
});

describe("EpochToken.isCurrent", () => {
  it("stays current at every level when nothing advanced", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    assert.equal(token.isCurrent("source"), true);
    assert.equal(token.isCurrent("home"), true);
    assert.equal(token.isCurrent("localWrite"), true);
    assert.equal(token.isCurrent(), true, "localWrite is the default level");
  });

  it("keeps a token current at 'source' after a home advance, but not at 'home'/'localWrite'", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    epoch.advance("home");
    assert.equal(token.isCurrent("source"), true, "the source itself did not change");
    assert.equal(token.isCurrent("home"), false);
    assert.equal(token.isCurrent("localWrite"), false);
  });

  it("keeps a token current at 'source'/'home' after a local write, but not at 'localWrite'", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    epoch.advance("localWrite");
    assert.equal(token.isCurrent("source"), true);
    assert.equal(token.isCurrent("home"), true, "neither the source nor the home changed");
    assert.equal(token.isCurrent("localWrite"), false);
  });

  it("is stale at every level after a source advance", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    epoch.advance("source");
    assert.equal(token.isCurrent("source"), false);
    assert.equal(token.isCurrent("home"), false);
    assert.equal(token.isCurrent("localWrite"), false);
  });

  it("keeps the documented invariant: current at localWrite implies current everywhere", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    epoch.claimSyncRun();
    assert.equal(token.isCurrent("localWrite"), true, "a sync claim does not cancel guarded work");
    assert.equal(token.isCurrent("home"), true, "a sync claim does not move the home level");
    assert.equal(token.isCurrent("source"), true, "a sync claim does not move the source level");
  });
});

describe("EpochToken.guard", () => {
  it("resolves to the value when the epoch is unchanged", async () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    assert.equal(await token.guard(Promise.resolve(42)), 42);
  });

  it("resolves to STALE when the epoch advanced before settle time", async () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    const gate = deferred<number>();
    const guarded = token.guard(gate.promise);
    epoch.advance("source");
    gate.resolve(42);
    assert.equal(await guarded, STALE);
  });

  it("checks the requested level, not only the default one", async () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    const gate = deferred<number>();
    const guarded = token.guard(gate.promise, "home");
    epoch.advance("localWrite");
    gate.resolve(7);
    assert.equal(await guarded, 7, "a local write does not cancel a home-level guard");
  });

  it("propagates rejections unchanged, stale or not", async () => {
    const epoch = new SourceEpoch();
    const current = epoch.capture();
    const boom = new Error("boom");
    await assert.rejects(current.guard(Promise.reject(boom)), (error: unknown) => error === boom);

    const stale = epoch.capture();
    epoch.advance("source");
    const boom2 = new Error("boom2");
    await assert.rejects(stale.guard(Promise.reject(boom2)), (error: unknown) => error === boom2);
  });
});

describe("SyncRunToken.guard", () => {
  it("resolves to the value while the run still owns the sync", async () => {
    const epoch = new SourceEpoch();
    const run = epoch.claimSyncRun();
    assert.equal(await run.guard(Promise.resolve("kept")), "kept");
  });

  it("resolves to STALE once a newer claim or a source/home advance happened", async () => {
    const epoch = new SourceEpoch();
    const supersededByClaim = epoch.claimSyncRun();
    const claimGate = deferred<number>();
    const claimGuarded = supersededByClaim.guard(claimGate.promise);
    epoch.claimSyncRun();
    claimGate.resolve(1);
    assert.equal(await claimGuarded, STALE);

    const supersededByHome = epoch.claimSyncRun();
    const homeGate = deferred<number>();
    const homeGuarded = supersededByHome.guard(homeGate.promise);
    epoch.advance("home");
    homeGate.resolve(2);
    assert.equal(await homeGuarded, STALE);

    const supersededBySource = epoch.claimSyncRun();
    const sourceGate = deferred<number>();
    const sourceGuarded = supersededBySource.guard(sourceGate.promise);
    epoch.advance("source");
    sourceGate.resolve(3);
    assert.equal(await sourceGuarded, STALE);
  });

  it("resolves to the value when only a local write happened", async () => {
    const epoch = new SourceEpoch();
    const run = epoch.claimSyncRun();
    const gate = deferred<number>();
    const guarded = run.guard(gate.promise);
    epoch.advance("localWrite");
    gate.resolve(9);
    assert.equal(await guarded, 9, "a local write does not cancel the running sync");
  });

  it("propagates rejections unchanged, stale or not", async () => {
    const epoch = new SourceEpoch();
    const current = epoch.claimSyncRun();
    const boom = new Error("boom");
    await assert.rejects(current.guard(Promise.reject(boom)), (error: unknown) => error === boom);

    const stale = epoch.claimSyncRun();
    const boom2 = new Error("boom2");
    await assert.rejects(stale.guard(Promise.reject(boom2)), (error: unknown) => error === boom2);
  });
});
