import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { PollingPolicy } from "../src/core/pollingPolicy.js";

// Mirrors `Tests/MijiaCoreTests/MiCloudPollingTests.swift` `policyIdleDecay` / `policyTable`.
const TOUCHED_AT_MS = 1_000_000;
const MINUTE_MS = 60_000;

interface IntervalOptions {
  readonly panelVisible?: boolean;
  readonly systemActive?: boolean;
  readonly lowPower?: boolean;
  readonly safetyAlertsRelyOnPolling?: boolean;
  readonly menuBarShowsLiveReading?: boolean;
  readonly lastPanelInteractionAtMs?: number | null;
}

/** The wait for a closed panel the user last touched `idleMs` ago, with the decay gates off. */
function intervalAfterIdle(idleMs: number, options: IntervalOptions = {}): number | null {
  return PollingPolicy.intervalMs(
    {
      panelVisible: options.panelVisible ?? false,
      systemActive: options.systemActive ?? true,
      lowPower: options.lowPower ?? false,
      lastPanelInteractionAtMs:
        options.lastPanelInteractionAtMs === undefined ? TOUCHED_AT_MS : options.lastPanelInteractionAtMs,
      safetyAlertsRelyOnPolling: options.safetyAlertsRelyOnPolling ?? false,
      menuBarShowsLiveReading: options.menuBarShowsLiveReading ?? false,
    },
    undefined,
    undefined,
    TOUCHED_AT_MS + idleMs,
  );
}

describe("PollingPolicy idle decay (mirrors macOS PollingPolicy.interval)", () => {
  it("stretches a closed panel 60 s → 120 s after 30 min → 300 s after 2 h", () => {
    assert.equal(intervalAfterIdle(0), 60_000);
    assert.equal(intervalAfterIdle(29 * MINUTE_MS), 60_000);
    assert.equal(intervalAfterIdle(30 * MINUTE_MS), 120_000);
    assert.equal(intervalAfterIdle(60 * MINUTE_MS), 120_000);
    assert.equal(intervalAfterIdle(2 * 60 * MINUTE_MS - 1), 120_000);
    assert.equal(intervalAfterIdle(2 * 60 * MINUTE_MS), 300_000);
    assert.equal(intervalAfterIdle(5 * 60 * MINUTE_MS), 300_000);
  });

  it("never decays while an enabled safety alert or a live label reading depends on the poll", () => {
    const fiveHours = 5 * 60 * MINUTE_MS;
    assert.equal(intervalAfterIdle(fiveHours, { safetyAlertsRelyOnPolling: true }), 60_000);
    assert.equal(intervalAfterIdle(fiveHours, { menuBarShowsLiveReading: true }), 60_000);
    assert.equal(
      intervalAfterIdle(fiveHours, { safetyAlertsRelyOnPolling: true, menuBarShowsLiveReading: true }),
      60_000,
    );
    // Untracked callers keep the old flat cadence: both gates default to "must not decay".
    assert.equal(PollingPolicy.intervalMs({ panelVisible: false, systemActive: true, lowPower: false }), 60_000);
  });

  it("keeps 6 s with the panel open and pauses while asleep, locked, or another user is active", () => {
    const fiveHours = 5 * 60 * MINUTE_MS;
    assert.equal(intervalAfterIdle(fiveHours, { panelVisible: true }), 6_000);
    assert.equal(intervalAfterIdle(fiveHours, { panelVisible: true, lowPower: true }), 6_000);
    assert.equal(intervalAfterIdle(fiveHours, { systemActive: false }), null);
    assert.equal(intervalAfterIdle(fiveHours, { panelVisible: true, systemActive: false }), null);
  });

  it("takes the longer of the Low Power interval and the idle step, never their product", () => {
    assert.equal(intervalAfterIdle(0, { lowPower: true }), 180_000);
    assert.equal(intervalAfterIdle(40 * MINUTE_MS, { lowPower: true }), 180_000);
    assert.equal(intervalAfterIdle(3 * 60 * MINUTE_MS, { lowPower: true }), 300_000);
  });

  it("does not decay before it knows when the panel was last touched", () => {
    assert.equal(intervalAfterIdle(5 * 60 * MINUTE_MS, { lastPanelInteractionAtMs: null }), 60_000);
  });
});
