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
    assert.equal(epoch.homeGeneration, 0);
    assert.equal(epoch.localRevision, 0);

    epoch.advance("localWrite");
    assert.equal(epoch.sourceRevision, 0, "a local write never touches the source level");
    assert.equal(epoch.homeGeneration, 0, "a local write never touches the home level");
    assert.equal(epoch.localRevision, 1);

    epoch.advance("home");
    assert.equal(epoch.sourceRevision, 0, "a home switch never touches the source level");
    assert.equal(epoch.homeGeneration, 1);
    assert.equal(epoch.localRevision, 2, "a home switch also advances the local-write level");

    epoch.advance("source");
    assert.equal(epoch.sourceRevision, 1);
    assert.equal(epoch.homeGeneration, 2, "a source switch also advances the home level");
    assert.equal(epoch.localRevision, 3, "a source switch also advances the local-write level");
  });

  it("claimSyncRun advances only the home generation, like the old ++syncGeneration", () => {
    const epoch = new SourceEpoch();
    const first = epoch.claimSyncRun();
    assert.equal(first, 1);
    assert.equal(epoch.sourceRevision, 0);
    assert.equal(epoch.homeGeneration, 1);
    assert.equal(epoch.localRevision, 0, "a sync claim must not look like a control write");

    const second = epoch.claimSyncRun();
    assert.equal(second, 2, "each claim supersedes the previous sync run");
    assert.equal(epoch.localRevision, 0);
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

  it("defaults to the strictest check: current at localWrite implies current everywhere", () => {
    const epoch = new SourceEpoch();
    const token = epoch.capture();
    epoch.claimSyncRun();
    assert.equal(token.isCurrent("localWrite"), true, "a sync claim does not cancel guarded work");
    assert.equal(token.isCurrent("home"), false);
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
