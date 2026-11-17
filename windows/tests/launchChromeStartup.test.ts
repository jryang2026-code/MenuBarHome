import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { runLaunchChromeStartupSelfTest } from "../scripts/verify-flyout-layout.mjs";

describe("launchChrome startup", () => {
  it("kills a silent child after the DevTools timeout and not before", { timeout: 15_000 }, async () => {
    const report = await runLaunchChromeStartupSelfTest();
    assert.match(report, /devtools child stayed alive \(port 9222\)/);
    assert.match(report, /alive at 200ms: true/);
    assert.match(report, /alive after reject: false/);
    const rejected = /rejected at (\d+)ms \(timeout (\d+)ms\)/.exec(report);
    assert.ok(rejected, report);
    const elapsedMs = Number(rejected[1]);
    const timeoutMs = Number(rejected[2]);
    assert.ok(elapsedMs + 20 >= timeoutMs, report);
  });
});
