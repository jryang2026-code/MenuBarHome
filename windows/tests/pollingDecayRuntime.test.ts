import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import "./dom.js";
import {
  CLOUD_REFRESH_HIDDEN_MS,
  CLOUD_REFRESH_VISIBLE_MS,
  PollingPolicy,
  cloudRefreshDue,
  cloudRefreshIntervalMs,
} from "../src/core/pollingPolicy.js";
import { SENSOR_ALERT_KINDS, saveSensorAlertPolicy, type SensorAlertKind } from "../src/core/safetyAndHealth.js";
import { saveSafetyGuardPrefs } from "../src/ui/automationSettingsView.js";
import {
  notePanelInteraction,
  pollingDecayInputs,
  safetyAlertsRelyOnPolling,
  trayShowsLiveReading,
} from "../src/ui/pollingSchedule.js";

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const TOUCHED_AT_MS = 1_000_000;

/** 安全与提醒 and 传感器告警 both fully off: the only configuration that may stretch the closed poll. */
function disableEverySafetyAlert(): void {
  saveSensorAlertPolicy({
    enabled: Object.fromEntries(SENSOR_ALERT_KINDS.map((kind) => [kind, false])) as Record<SensorAlertKind, boolean>,
    onlyWhenAway: false,
  });
  saveSafetyGuardPrefs({
    enableSafetyAlerts: false,
    longRunningPlug: false,
    longRunningClimate: false,
    favoriteOffline: false,
    lowBattery: false,
  });
}

/** A host that only carries the idle clock, i.e. what `startTimerLoop` and the tray recovery see. */
function hostTouchedAt(touchedAtMs: number | null): { lastPanelInteractionAtMs: number | null } {
  return { lastPanelInteractionAtMs: touchedAtMs };
}

beforeEach(() => {
  localStorage.clear();
});

describe("polling decay gates (mirrors macOS HomeStore storeDecayGates)", () => {
  it("keeps the safety gate on while any enabled alert reads the poll (ADR-0023 §4)", () => {
    assert.equal(safetyAlertsRelyOnPolling(), true, "烟雾 / 燃气 / 水浸 / 门锁 alert kinds default on");

    saveSafetyGuardPrefs({ enableSafetyAlerts: false });
    assert.equal(safetyAlertsRelyOnPolling(), true, "the sensor alert block has its own switches");

    saveSensorAlertPolicy({
      enabled: Object.fromEntries(SENSOR_ALERT_KINDS.map((kind) => [kind, false])) as Record<SensorAlertKind, boolean>,
      onlyWhenAway: false,
    });
    assert.equal(safetyAlertsRelyOnPolling(), false, "every alert kind off: nothing reads the poll");

    saveSafetyGuardPrefs({ enableSafetyAlerts: true, longRunningPlug: true });
    assert.equal(safetyAlertsRelyOnPolling(), true, "长通电提醒 reads the same polled snapshot");
  });

  it("keeps the tray gate off: Windows has no always-on reading outside the panel", () => {
    assert.equal(trayShowsLiveReading(), false);
    assert.deepEqual(pollingDecayInputs(hostTouchedAt(TOUCHED_AT_MS)), {
      lastPanelInteractionAtMs: TOUCHED_AT_MS,
      safetyAlertsRelyOnPolling: true,
      menuBarShowsLiveReading: false,
    });
  });

  it("reports an untracked clock as unknown so the interval stays flat", () => {
    assert.equal(pollingDecayInputs({}).lastPanelInteractionAtMs, null);
    assert.equal(pollingDecayInputs(hostTouchedAt(null)).lastPanelInteractionAtMs, null);
    assert.equal(
      cloudRefreshIntervalMs(TOUCHED_AT_MS + 5 * HOUR_MS, false, {
        safetyAlertsRelyOnPolling: false,
        menuBarShowsLiveReading: false,
      }),
      CLOUD_REFRESH_HIDDEN_MS,
      "no interaction clock: no stretch",
    );
  });

  it("restarts the idle clock when the panel opens or closes", () => {
    const host = hostTouchedAt(TOUCHED_AT_MS);
    assert.equal(notePanelInteraction(host, TOUCHED_AT_MS + 30 * MINUTE_MS), TOUCHED_AT_MS + 30 * MINUTE_MS);
    assert.equal(host.lastPanelInteractionAtMs, TOUCHED_AT_MS + 30 * MINUTE_MS);
  });
});

describe("cloud refresh cadence applies the idle decay (`cloudRefreshDue`)", () => {
  it("stretches a closed panel 60 s → 120 s after 30 min → 300 s after 2 h once both gates are off", () => {
    disableEverySafetyAlert();
    const decay = pollingDecayInputs(hostTouchedAt(TOUCHED_AT_MS));
    assert.equal(decay.safetyAlertsRelyOnPolling, false);

    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS, false, decay), 60_000);
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 29 * MINUTE_MS, false, decay), 60_000);
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 30 * MINUTE_MS, false, decay), 120_000);
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 119 * MINUTE_MS, false, decay), 120_000);
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 2 * HOUR_MS, false, decay), 300_000);
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 5 * HOUR_MS, false, decay), 300_000);

    const polledAtMs = TOUCHED_AT_MS + 2 * HOUR_MS;
    assert.equal(cloudRefreshDue(polledAtMs + 299_999, polledAtMs, false, decay), false);
    assert.equal(cloudRefreshDue(polledAtMs + 300_000, polledAtMs, false, decay), true);
  });

  it("SAFETY INVARIANT: decay never slows a poll that an enabled safety alert depends on", () => {
    // Default install: 烟雾 / 燃气 / 水浸 / 门锁 alerts on, panel closed for five hours.
    const decay = pollingDecayInputs(hostTouchedAt(TOUCHED_AT_MS));
    assert.equal(decay.safetyAlertsRelyOnPolling, true);

    for (const idleMs of [0, 29 * MINUTE_MS, 30 * MINUTE_MS, 2 * HOUR_MS, 5 * HOUR_MS]) {
      assert.equal(
        cloudRefreshIntervalMs(TOUCHED_AT_MS + idleMs, false, decay),
        CLOUD_REFRESH_HIDDEN_MS,
        `idle ${idleMs} ms must keep the 60 s safety cadence`,
      );
    }

    const polledAtMs = TOUCHED_AT_MS + 5 * HOUR_MS;
    assert.equal(cloudRefreshDue(polledAtMs + 59_999, polledAtMs, false, decay), false);
    assert.equal(cloudRefreshDue(polledAtMs + 60_000, polledAtMs, false, decay), true, "late by a second is still a miss risk");

    // The same holds when only the tray label gate stays on: a reading on screen never goes stale.
    assert.equal(
      cloudRefreshIntervalMs(polledAtMs, false, {
        lastPanelInteractionAtMs: TOUCHED_AT_MS,
        safetyAlertsRelyOnPolling: false,
        menuBarShowsLiveReading: true,
      }),
      CLOUD_REFRESH_HIDDEN_MS,
    );
  });

  it("keeps 6 s with the panel open and 60 s for a caller that passes no gates", () => {
    disableEverySafetyAlert();
    const decay = pollingDecayInputs(hostTouchedAt(TOUCHED_AT_MS));
    assert.equal(cloudRefreshIntervalMs(TOUCHED_AT_MS + 5 * HOUR_MS, true, decay), CLOUD_REFRESH_VISIBLE_MS);
    assert.equal(cloudRefreshDue(TOUCHED_AT_MS + 5 * HOUR_MS + 6_000, null, true, decay), true);

    // The historical 6 s / 60 s pair: no gates and no clock at all.
    const last = 1_000_000;
    assert.equal(cloudRefreshIntervalMs(last, false), CLOUD_REFRESH_HIDDEN_MS);
    assert.equal(cloudRefreshDue(last + 5_999, last, true), false);
    assert.equal(cloudRefreshDue(last + 6_000, last, true), true);
    assert.equal(cloudRefreshDue(last + 59_999, last, false), false);
    assert.equal(cloudRefreshDue(last + 60_000, last, false), true);
    assert.equal(cloudRefreshDue(last + 5 * HOUR_MS, last, false), true);
  });

  it("takes the longer of the Low Power interval and the idle step, never their product", () => {
    const lowPowerIntervalMs = PollingPolicy.intervalMs(
      {
        panelVisible: false,
        systemActive: true,
        lowPower: true,
        lastPanelInteractionAtMs: TOUCHED_AT_MS,
        safetyAlertsRelyOnPolling: false,
        menuBarShowsLiveReading: false,
      },
      undefined,
      undefined,
      TOUCHED_AT_MS + 2 * HOUR_MS,
    );
    assert.equal(lowPowerIntervalMs, 300_000);
    assert.equal(
      cloudRefreshIntervalMs(TOUCHED_AT_MS + 2 * HOUR_MS, false, {
        lastPanelInteractionAtMs: TOUCHED_AT_MS,
        safetyAlertsRelyOnPolling: false,
        menuBarShowsLiveReading: false,
      }),
      300_000,
      "Windows has no Low Power Mode signal, so the runtime cadence matches the idle step",
    );
  });
});
