import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { switchHome } from "../src/ui/sourceSwitch.js";
import { setLanguage } from "../src/core/i18n.js";

const HA_BASE_URL = "https://ha.example.test:8123";
const HA_TOKEN = "race-test-token";

/** A one-light HA snapshot; the HA device id becomes the `SmartDevice` id. */
function haLightSnapshot(deviceIds: readonly string[]): unknown {
  return {
    areas: [{ area_id: "living", name: "客厅" }],
    devices: deviceIds.map((id) => ({ id, name: `测试灯 ${id}`, area_id: "living" })),
    entities: deviceIds.map((id) => ({ entity_id: `light.${id}`, device_id: id })),
    states: deviceIds.map((id) => ({
      entity_id: `light.${id}`,
      state: "off",
      attributes: { friendly_name: `测试灯 ${id}` },
    })),
  };
}

const BASE_SNAPSHOT = haLightSnapshot(["race-base"]);

interface RaceContext {
  app: MenuMijiaWindowsApp;
  /** Resolves parked ha_snapshot call #index with the given payload. */
  releaseParked(index: number, payload: unknown): void;
  /** Flushes until `count` ha_snapshot calls are parked mid-flight. */
  waitForParked(count: number): Promise<void>;
  /** How many `ha_execute` service calls were dispatched. */
  haExecuteCount(): number;
}

/**
 * Mounts the app in Home Assistant mode. The first `ha_snapshot` (the baseline sync) resolves
 * immediately; every later one parks on a deferred promise so a test can change the world while
 * the refresh is waiting at its await, then release it.
 */
function mountRaceApp(): RaceContext {
  const parked: Array<(payload: unknown) => void> = [];
  let snapshotCalls = 0;
  let haExecuteCalls = 0;

  Object.defineProperty(window, "__TAURI_INTERNALS__", {
    configurable: true,
    value: {
      invoke: async (cmd: string, _args: Record<string, unknown> = {}): Promise<unknown> => {
        if (cmd === "is_workstation_locked") return false;
        if (cmd === "secure_store_get") return null;
        if (cmd === "ha_execute") {
          haExecuteCalls += 1;
          return null;
        }
        if (cmd === "ha_snapshot") {
          snapshotCalls += 1;
          if (snapshotCalls === 1) return structuredClone(BASE_SNAPSHOT);
          return await new Promise<unknown>((resolve) => {
            parked.push((payload: unknown) => resolve(structuredClone(payload)));
          });
        }
        return null;
      },
    },
  });

  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "homeAssistant",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
      haBaseURL: HA_BASE_URL,
      haToken: HA_TOKEN,
    }),
  );

  const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  return {
    app,
    releaseParked: (index, payload) => {
      const resolve = parked[index];
      assert.ok(resolve, `expected parked ha_snapshot call #${index}`);
      resolve(payload);
    },
    waitForParked: async (count) => {
      for (let i = 0; i < 200 && parked.length < count; i += 1) await setImmediate();
      assert.ok(parked.length >= count, `expected ${count} parked ha_snapshot call(s), got ${parked.length}`);
    },
    haExecuteCount: () => haExecuteCalls,
  };
}

async function flushAsync(rounds = 8): Promise<void> {
  for (let i = 0; i < rounds; i += 1) await setImmediate();
}

/** Runs one baseline sync so each race starts from a settled, attached panel. */
async function baselineSync(app: MenuMijiaWindowsApp): Promise<void> {
  await app.refreshHADevices(false);
  assert.equal(app.devices.length, 1, "baseline sync adopts the base light");
  assert.equal(app.isSyncingCloud, false);
}

let dom: Window;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("cloud refresh races guarded by SourceEpoch tokens", () => {
  it("drops a snapshot that arrives after a home switch, and the superseded run leaves isSyncingCloud alone", async () => {
    const { app, releaseParked, waitForParked } = mountRaceApp();
    await flushAsync(4);
    await baselineSync(app);

    const refresh = app.refreshHADevices(false);
    await waitForParked(1);
    assert.equal(app.isSyncingCloud, true, "the refresh owns the sync wire while parked");

    // The invalidation half of `selectHome` (ui/sourceSwitch.ts): a home switch mid-refresh.
    switchHome(app);
    assert.equal(app.isSyncingCloud, false, "a home switch releases the sync wire immediately");

    releaseParked(0, haLightSnapshot(["race-base", "home-switch-extra"]));
    await refresh;
    await flushAsync(4);

    assert.equal(
      app.devices.some((device) => device.id === "home-switch-extra"),
      false,
      "the stale snapshot must not be adopted after a home switch",
    );
    assert.equal(app.isSyncingCloud, false, "the superseded run must not resurrect isSyncingCloud");
  });

  it("rejects an offline click immediately without dispatch or an optimistic on state", async () => {
    const { app, haExecuteCount } = mountRaceApp();
    await flushAsync(4);
    await baselineSync(app);
    const light = app.devices.find((device) => device.id === "race-base")!;
    Object.assign(light, { isOnline: false });

    const result = app.applyCommand({ kind: "setLightPower", entityId: "light.race-base", isOn: true });
    assert.equal(app.replyBanner?.isError, true);
    assert.equal(light.kind.kind === "light" && light.kind.isOn, false);
    assert.equal(await result, false);
    assert.equal(haExecuteCount(), 0);
  });

  it("keeps the written field but adopts the rest of a poll captured before a local write", async () => {
    const { app, releaseParked, waitForParked, haExecuteCount } = mountRaceApp();
    await flushAsync(4);
    await baselineSync(app);
    const light = app.devices.find((device) => device.id === "race-base")!;
    assert.equal(light.kind.kind, "light");

    const refresh = app.refreshHADevices(false);
    await waitForParked(1);
    assert.equal(app.isSyncingCloud, true);

    // A local control write through the public single-command path advances the localWrite level.
    await app.executeSingleCommand(
      light,
      { kind: "setLightPower", entityId: "light.race-base", isOn: true },
      "切换灯光",
    );
    assert.equal(light.kind.kind === "light" ? light.kind.isOn : false, true, "the local write applied");
    assert.equal(haExecuteCount(), 1, "the write dispatched to Home Assistant");

    releaseParked(0, haLightSnapshot(["race-base", "manual-write-extra"]));
    await refresh;
    await flushAsync(4);

    assert.equal(
      app.devices.some((device) => device.id === "manual-write-extra"),
      true,
      "the unrelated new device is adopted",
    );
    const updated = app.devices.find((device) => device.id === "race-base")!;
    assert.equal(updated.kind.kind === "light" && updated.kind.isOn, true, "the written power field survives");
    assert.equal(
      app.isSyncingCloud,
      false,
      "a local write does not supersede the run, so the run's own finally still clears the wire",
    );
  });

  it("keeps the newer sync run's isSyncingCloud when the superseded older run finishes (selectHome path)", async () => {
    const { app, releaseParked, waitForParked } = mountRaceApp();
    await flushAsync(4);
    await baselineSync(app);

    const oldRefresh = app.refreshHADevices(false);
    await waitForParked(1);
    assert.equal(app.isSyncingCloud, true);

    // The real user path: picking another home invalidates the old run and auto-starts a new one.
    app.selectHome("home-race");
    await waitForParked(2);
    assert.equal(app.isSyncingCloud, true, "the home switch's auto refresh owns the wire now");

    // The OLD run's snapshot arrives late: it must neither adopt nor clear the newer run's wire.
    releaseParked(0, haLightSnapshot(["old-run-device"]));
    await oldRefresh;
    await flushAsync(4);
    assert.equal(
      app.devices.some((device) => device.id === "old-run-device"),
      false,
      "the superseded run must not adopt its snapshot",
    );
    assert.equal(
      app.isSyncingCloud,
      true,
      "the older run's finally must not clear the newer run's isSyncingCloud",
    );

    // The NEW run's snapshot arrives and is adopted normally.
    releaseParked(1, haLightSnapshot(["new-run-device"]));
    await flushAsync(20);
    assert.equal(
      app.devices.some((device) => device.id === "new-run-device"),
      true,
      "the newer run adopts its own snapshot",
    );
    assert.equal(app.isSyncingCloud, false);
  });
});
