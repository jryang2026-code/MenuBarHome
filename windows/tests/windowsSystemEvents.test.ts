import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  getHostActivityCenter,
  notifyDisplayPowerChanged,
  notifySystemSleep,
  notifySystemWake,
  pollSystemContextSignals,
  tickSafetyHealthAndAutomation,
} from "../src/ui/activityStackView.js";
import { bindLifecycleRecovery } from "../src/ui/appLifecycle.js";
import { createAutomationRule } from "../src/core/automationEngine.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import {
  SYSTEM_CONTEXT_POLL_INTERVAL_MS,
  planSystemSignalTransition,
  resolveSystemSignalBaseline,
  triggerUsesSystemSignal,
  type NativeSystemSignals,
} from "../src/ui/systemContextPoll.js";
import { readNativeSystemPower } from "../src/ui/transport.js";

let dom: Window | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
  localStorage.removeItem(STORAGE_KEY);
});

afterEach(async () => {
  delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

/** Lets the fire-and-forget dispatch (`void dispatchSystemContextEvent(...)`) settle. */
async function flush(): Promise<void> {
  await setImmediate();
  await setImmediate();
}

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Expected selector to exist: ${selector}`);
  return found;
}

function makeLight(): SmartDevice {
  return {
    id: "light.desk",
    name: "书桌台灯",
    roomId: "room_study",
    roomName: "书房",
    model: "yeelink.light.lamp15",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "light.desk",
      isOn: true,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
      powerWritable: true,
    },
  };
}

interface NativeStub {
  power: { hasBattery: boolean; onExternalPower: boolean | null; batteryPercent: number | null } | null;
  displays: number | null;
  readonly calls: string[];
}

function stubNative(partial: Partial<Omit<NativeStub, "calls">> = {}): NativeStub {
  const stub: NativeStub = { power: null, displays: null, calls: [], ...partial };
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async <T>(cmd: string): Promise<T> => {
      if (cmd === "system_power_status" || cmd === "external_display_count") stub.calls.push(cmd);
      if (cmd === "system_power_status") return stub.power as unknown as T;
      if (cmd === "external_display_count") return stub.displays as unknown as T;
      if (cmd === "is_workstation_locked") return false as unknown as T;
      return undefined as unknown as T;
    },
  };
  return stub;
}

function createApp(): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      interfaceLanguage: "zh-Hans",
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  app.settings.connectionMode = "demo";
  return app;
}

function trackingApp(rules: ReturnType<typeof createAutomationRule>[]): {
  app: MenuMijiaWindowsApp;
  sent: DeviceCommand[];
} {
  const app = createApp();
  const light = makeLight();
  app.devices = [light];
  getHostActivityCenter(app).automationEngine.store.save(rules);
  const sent: DeviceCommand[] = [];
  app.applyCommand = async (command) => {
    sent.push(command);
    if (command.kind === "setLightPower" && light.kind.kind === "light") {
      light.kind = { ...light.kind, isOn: command.isOn };
    }
    return true;
  };
  return { app, sent };
}

const LIGHT_OFF_ACTION = { kind: "devices" as const, deviceIds: ["light.desk"], isOn: false };

describe("Windows power/display sampling plan (systemContextPoll.ts)", () => {
  it("never compares against a missing baseline, so the first sample cannot fire", () => {
    const first: NativeSystemSignals = {
      power: { hasBattery: true, onExternalPower: false, batteryPercent: 12 },
      externalDisplayCount: 1,
    };
    assert.deepEqual(planSystemSignalTransition(null, first), {
      power: null,
      externalDisplayCount: null,
    });
    assert.deepEqual(resolveSystemSignalBaseline(null, first), {
      power: { onExternalPower: false, batteryPercent: 12 },
      externalDisplayCount: 1,
    });
  });

  it("reports AC transitions and charge-level changes, and nothing on a repeated sample", () => {
    const unplugged = planSystemSignalTransition(
      { power: { onExternalPower: true, batteryPercent: 90 }, externalDisplayCount: 0 },
      { power: { hasBattery: true, onExternalPower: false, batteryPercent: 90 }, externalDisplayCount: 0 },
    );
    assert.deepEqual(unplugged, {
      power: { onExternalPower: false, batteryPercent: 90 },
      externalDisplayCount: null,
    });

    const dropping = planSystemSignalTransition(
      { power: { onExternalPower: false, batteryPercent: 21 }, externalDisplayCount: 0 },
      { power: { hasBattery: true, onExternalPower: false, batteryPercent: 19 }, externalDisplayCount: 0 },
    );
    assert.deepEqual(dropping.power, { onExternalPower: false, batteryPercent: 19 });

    const repeated = planSystemSignalTransition(
      { power: { onExternalPower: false, batteryPercent: 19 }, externalDisplayCount: 0 },
      { power: { hasBattery: true, onExternalPower: false, batteryPercent: 19 }, externalDisplayCount: 0 },
    );
    assert.deepEqual(repeated, { power: null, externalDisplayCount: null });
  });

  it("keeps the previous value when the native call is unavailable instead of inventing a change", () => {
    const baseline = resolveSystemSignalBaseline(null, {
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 55 },
      externalDisplayCount: 1,
    });
    assert.deepEqual(
      planSystemSignalTransition(baseline, { power: null, externalDisplayCount: null }),
      { power: null, externalDisplayCount: null },
    );
    assert.deepEqual(resolveSystemSignalBaseline(baseline, { power: null, externalDisplayCount: null }), baseline);

    // An unknown AC line status keeps the last known power source but still carries the charge.
    const unknownAc = planSystemSignalTransition(baseline, {
      power: { hasBattery: true, onExternalPower: null, batteryPercent: 54 },
      externalDisplayCount: null,
    });
    assert.deepEqual(unknownAc.power, { onExternalPower: true, batteryPercent: 54 });
  });

  it("tracks the external display count independently of power", () => {
    const baseline = resolveSystemSignalBaseline(null, {
      power: { hasBattery: false, onExternalPower: true, batteryPercent: null },
      externalDisplayCount: 0,
    });
    assert.deepEqual(
      planSystemSignalTransition(baseline, {
        power: { hasBattery: false, onExternalPower: true, batteryPercent: null },
        externalDisplayCount: 2,
      }),
      { power: null, externalDisplayCount: 2 },
    );
  });

  it("maps triggers to the native signal they wait for", () => {
    assert.equal(triggerUsesSystemSignal("powerConnected", "powerChanged"), true);
    assert.equal(triggerUsesSystemSignal("batteryBelowThreshold", "powerChanged"), true);
    assert.equal(triggerUsesSystemSignal("externalDisplayDisconnected", "externalDisplayChanged"), true);
    assert.equal(triggerUsesSystemSignal("wifiNetworkJoined", "powerChanged"), false);
    assert.equal(triggerUsesSystemSignal("lidClosedSleep", "powerChanged"), false);
    assert.equal(triggerUsesSystemSignal("powerConnected", "externalDisplayChanged"), false);
  });

  it("normalizes a desktop reply even when the native layer reports a charge level", async () => {
    stubNative({ power: { hasBattery: false, onExternalPower: false, batteryPercent: 64 } });
    assert.deepEqual(await readNativeSystemPower(), {
      hasBattery: false,
      onExternalPower: true,
      batteryPercent: null,
    });
    delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
    assert.equal(await readNativeSystemPower(), null);
  });

  it("computes systemSignalNeed and hasSystemSignalConsumers only for enabled power/display rules", async () => {
    const { hasSystemSignalConsumers, systemSignalNeed } = await import("../src/ui/systemContextPoll.js");
    assert.deepEqual(systemSignalNeed([]), { power: false, externalDisplayCount: false });
    assert.equal(hasSystemSignalConsumers([]), false);

    const awayRule = createAutomationRule({ id: "r-away", trigger: "away", action: LIGHT_OFF_ACTION });
    const disabledPower = createAutomationRule({
      id: "r-p-off",
      trigger: "powerConnected",
      action: LIGHT_OFF_ACTION,
      isEnabled: false,
    });
    assert.deepEqual(systemSignalNeed([awayRule, disabledPower]), {
      power: false,
      externalDisplayCount: false,
    });
    assert.equal(hasSystemSignalConsumers([awayRule, disabledPower]), false);

    const enabledPower = { ...disabledPower, isEnabled: true };
    const enabledDisplay = createAutomationRule({
      id: "r-d-on",
      trigger: "externalDisplayConnected",
      action: LIGHT_OFF_ACTION,
    });
    assert.deepEqual(systemSignalNeed([awayRule, enabledPower]), {
      power: true,
      externalDisplayCount: false,
    });
    assert.equal(hasSystemSignalConsumers([awayRule, enabledPower]), true);
    assert.deepEqual(systemSignalNeed([enabledPower, enabledDisplay]), {
      power: true,
      externalDisplayCount: true,
    });
  });
});

describe("Windows power/display automation (pollSystemContextSignals)", () => {
  const t0 = new Date(2026, 10, 14, 9, 0, 0).getTime();

  it("primes at startup, then fires a low-battery rule once when the charge crosses the threshold", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({
        id: "rule-battery",
        trigger: "batteryBelowThreshold",
        action: LIGHT_OFF_ACTION,
        triggerOptions: { batteryThresholdPercent: 20 },
      }),
    ]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: false, batteryPercent: 80 },
      displays: 0,
    });

    assert.equal(await pollSystemContextSignals(app, t0), false, "the first sample only seeds the baseline");
    assert.deepEqual(sent, []);

    stub.power = { hasBattery: true, onExternalPower: false, batteryPercent: 18 };
    assert.equal(await pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS), true);
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    stub.power = { hasBattery: true, onExternalPower: false, batteryPercent: 17 };
    assert.equal(await pollSystemContextSignals(app, t0 + 2 * SYSTEM_CONTEXT_POLL_INTERVAL_MS), false);
    assert.equal(sent.length, 1, "an already-below rule must not fire again on every percent drop");
  });

  it("does not fire a low-battery rule on a desktop that has no battery", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({
        id: "rule-battery",
        trigger: "batteryBelowThreshold",
        action: LIGHT_OFF_ACTION,
        triggerOptions: { batteryThresholdPercent: 90 },
      }),
    ]);
    const stub = stubNative({
      power: { hasBattery: false, onExternalPower: true, batteryPercent: null },
      displays: 0,
    });

    for (let index = 0; index < 3; index += 1) {
      await pollSystemContextSignals(app, t0 + index * SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    }
    assert.deepEqual(sent, []);
    assert.equal(stub.calls.filter((cmd) => cmd === "system_power_status").length, 3);
  });

  it("fires power disconnected/connected only on the transition, never on the startup state", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({
        id: "rule-unplug",
        trigger: "powerDisconnected",
        action: LIGHT_OFF_ACTION,
      }),
      createAutomationRule({
        id: "rule-plug",
        trigger: "powerConnected",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: true },
      }),
    ]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 90 },
      displays: 0,
    });

    await pollSystemContextSignals(app, t0);
    assert.deepEqual(sent, [], "booting on AC power must not run a power-connected rule");

    stub.power = { hasBattery: true, onExternalPower: false, batteryPercent: 90 };
    await pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    stub.power = { hasBattery: true, onExternalPower: true, batteryPercent: 90 };
    await pollSystemContextSignals(app, t0 + 2 * SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    assert.deepEqual(sent.at(-1), { kind: "setLightPower", entityId: "light.desk", isOn: true });
  });

  it("fires external display rules when the monitor count changes", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({
        id: "rule-display-on",
        trigger: "externalDisplayConnected",
        action: LIGHT_OFF_ACTION,
      }),
    ]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 70 },
      displays: 0,
    });

    await pollSystemContextSignals(app, t0);
    assert.deepEqual(sent, [], "the startup display layout must not fire");

    stub.displays = 1;
    await pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    stub.displays = 1;
    await pollSystemContextSignals(app, t0 + 2 * SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    assert.equal(sent.length, 1, "an unchanged layout must not refire");
  });

  it("keeps one sample per macOS cadence and skips native calls when no rule needs them", async () => {
    const { app } = trackingApp([
      createAutomationRule({ id: "rule-lock", trigger: "away", action: LIGHT_OFF_ACTION }),
    ]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 70 },
      displays: 0,
    });

    assert.equal(await pollSystemContextSignals(app, t0), false);
    assert.deepEqual(stub.calls, [], "a lock-only rule set must not sample power or displays");

    getHostActivityCenter(app).automationEngine.store.save([
      createAutomationRule({ id: "rule-p", trigger: "powerConnected", action: LIGHT_OFF_ACTION }),
    ]);
    await pollSystemContextSignals(app, t0);
    assert.deepEqual(stub.calls, ["system_power_status"]);

    await pollSystemContextSignals(app, t0 + 1_000);
    assert.deepEqual(stub.calls, ["system_power_status"], "the 10 s cadence holds inside the 1 s tick");
    await pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    assert.deepEqual(stub.calls, ["system_power_status", "system_power_status"]);
  });

  it("is kicked by the safety/automation tick in production", async () => {
    const { app } = trackingApp([
      createAutomationRule({ id: "rule-p", trigger: "powerConnected", action: LIGHT_OFF_ACTION }),
    ]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 70 },
      displays: 0,
    });

    tickSafetyHealthAndAutomation(app, t0);
    await flush();
    assert.ok(stub.calls.includes("system_power_status"));
  });
});

describe("Windows suspend/display-power notifications", () => {
  const t0 = new Date(2026, 10, 14, 9, 0, 0).getTime();

  it("runs system sleep and display sleep rules from the native notifications", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({ id: "rule-sleep", trigger: "systemSleep", action: LIGHT_OFF_ACTION }),
      createAutomationRule({
        id: "rule-display",
        trigger: "displaySleep",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: true },
      }),
    ]);
    stubNative();
    app.devices[0]!.kind = { ...(app.devices[0]!.kind as Extract<SmartDevice["kind"], { kind: "light" }>), isOn: true };

    notifySystemSleep(app, t0);
    await flush();
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    notifyDisplayPowerChanged(app, true, t0 + 2_000);
    await flush();
    assert.deepEqual(sent.at(-1), { kind: "setLightPower", entityId: "light.desk", isOn: true });
  });

  it("bridges the menumijia: DOM events raised by system_events.rs", async () => {
    const { app, sent } = trackingApp([
      createAutomationRule({ id: "rule-wake", trigger: "systemWake", action: LIGHT_OFF_ACTION }),
    ]);
    stubNative();
    const dispose = bindLifecycleRecovery(app);

    window.dispatchEvent(new window.CustomEvent("menumijia:system-wake"));
    await flush();
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    notifySystemWake(app, t0 + 1_000);
    await flush();
    assert.equal(sent.length, 1, "the engine's 60 s per-trigger cooldown still applies");
    dispose();
  });
});
