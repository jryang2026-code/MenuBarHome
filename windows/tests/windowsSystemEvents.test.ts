import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  dispatchSystemContextEvent,
  getHostActivityCenter,
  setEventAutomationRunning,
  notifyDisplayPowerChanged,
  notifySystemSleep,
  notifySystemWake,
  pollSystemContextSignals,
  tickSafetyHealthAndAutomation,
} from "../src/ui/activityStackView.js";
import { bindLifecycleRecovery, retryIdentityMigration, syncAutomationLifecycle } from "../src/ui/appLifecycle.js";
import { markTimerSnapshotReady } from "../src/ui/scheduledCommands.js";
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

/** The three DOM events `system_events.rs` forwards, and the only ones the switch controls. */
const AUTOMATION_EVENT_TYPES = ["menumijia:system-sleep", "menumijia:system-wake", "menumijia:display-power"];

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

  it("computes systemSignalNeed only for enabled power/display rules", async () => {
    const { systemSignalNeed } = await import("../src/ui/systemContextPoll.js");
    assert.deepEqual(systemSignalNeed([]), { power: false, externalDisplayCount: false });

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

  it("does not run a display rule that was disabled while the power rule was executing", async () => {
    const powerRule = createAutomationRule({ id: "rule-p", trigger: "powerConnected", action: LIGHT_OFF_ACTION });
    const displayRule = createAutomationRule({
      id: "rule-d",
      trigger: "externalDisplayConnected",
      action: { kind: "devices", deviceIds: ["light.desk"], isOn: true },
    });
    const { app, sent } = trackingApp([powerRule, displayRule]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: false, batteryPercent: 70 },
      displays: 0,
    });
    const store = getHostActivityCenter(app).automationEngine.store;
    await pollSystemContextSignals(app, t0);

    const applyCommand = app.applyCommand.bind(app);
    app.applyCommand = async (command) => {
      store.save(store.load().map((rule) => (rule.id === "rule-d" ? { ...rule, isEnabled: false } : rule)));
      return applyCommand(command);
    };
    stub.power = { hasBattery: true, onExternalPower: true, batteryPercent: 70 };
    stub.displays = 1;
    await pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS);

    assert.equal(sent.length, 1, "only the power rule may send a command");
    assert.deepEqual(sent.map((command) => command.kind === "setLightPower" && command.isOn), [false]);
  });

  it("is kicked by the safety/automation tick in production, adds no extra rule-store read, and clears baseline when disabled", async () => {
    const powerRule = createAutomationRule({ id: "rule-p", trigger: "powerConnected", action: LIGHT_OFF_ACTION });
    const { app } = trackingApp([powerRule]);
    const stub = stubNative({
      power: { hasBattery: true, onExternalPower: true, batteryPercent: 70 },
      displays: 0,
    });
    const center = getHostActivityCenter(app);
    const origLoad = center.automationEngine.store.load.bind(center.automationEngine.store);
    let storeLoadCalls = 0;
    center.automationEngine.store.load = () => {
      storeLoadCalls += 1;
      return origLoad();
    };

    // The poll reuses the tick's rules; the second read is the engine's own dispatch.
    tickSafetyHealthAndAutomation(app, t0);
    assert.equal(storeLoadCalls, 2, "poll-due tick reads the rule store for the tick and the engine only");
    await flush();
    assert.ok(stub.calls.includes("system_power_status"));
    assert.notEqual(center.systemSignalBaseline, null);
    assert.equal(center.lastSystemPollAtMs, t0);

    storeLoadCalls = 0;
    tickSafetyHealthAndAutomation(app, t0 + 1_000);
    assert.equal(storeLoadCalls, 2, "non-due tick reads the rule store for the tick and the engine only");
    await flush();

    // Disabling power/display consumers clears cached baseline & poll timestamp.
    center.automationEngine.store.save([{ ...powerRule, isEnabled: false }]);
    tickSafetyHealthAndAutomation(app, t0 + 2_000);
    assert.equal(center.systemSignalBaseline, null);
    assert.equal(center.lastSystemPollAtMs, 0);
  });

  it("discards an in-flight system poll result and resets baseline if rules are disabled before IPC returns", async () => {
    const powerRule = createAutomationRule({ id: "rule-p", trigger: "powerConnected", action: LIGHT_OFF_ACTION });
    const { app, sent } = trackingApp([powerRule]);
    const center = getHostActivityCenter(app);
    center.systemSignalBaseline = {
      power: { onExternalPower: true, batteryPercent: 70 },
      externalDisplayCount: null,
    };
    center.lastSystemPollAtMs = t0;

    let resolvePower!: (value: unknown) => void;
    (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
      invoke: (cmd: string) => {
        if (cmd === "system_power_status") {
          return new Promise((resolve) => {
            resolvePower = resolve;
          });
        }
        return Promise.resolve(false);
      },
    };

    const pollPromise = pollSystemContextSignals(app, t0 + SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    // Disable all rules while the native IPC is still in flight.
    center.automationEngine.store.save([{ ...powerRule, isEnabled: false }]);
    resolvePower({ hasBattery: true, onExternalPower: false, batteryPercent: 68 });

    assert.equal(await pollPromise, false);
    assert.deepEqual(sent, [], "disabled rule must not fire from stale in-flight sample");
    assert.equal(center.systemSignalBaseline, null, "in-flight cancellation resets baseline");
    assert.equal(center.lastSystemPollAtMs, 0, "in-flight cancellation resets poll timestamp");
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

describe("PC context automation runtime switch", () => {
  it("detaches native event consumers and retains rules while stopped", async () => {
    const rule = createAutomationRule({ id: "sleep", trigger: "systemSleep", action: LIGHT_OFF_ACTION });
    const { app, sent } = trackingApp([rule]);
    const center = getHostActivityCenter(app);
    const stored = center.automationEngine.store.load();
    const stub = stubNative();
    const stop = bindLifecycleRecovery(app);
    try {
      setEventAutomationRunning(app, false);
      syncAutomationLifecycle(app);
      window.dispatchEvent(new window.CustomEvent("menumijia:system-sleep"));
      tickSafetyHealthAndAutomation(app);
      await flush();
      assert.deepEqual(sent, []);
      assert.deepEqual(stub.calls, []);
      assert.deepEqual(center.automationEngine.store.load(), stored);
      assert.equal(center.automationEngine.snapshot.isSystemAsleep, false);

      setEventAutomationRunning(app, true);
      syncAutomationLifecycle(app);
      window.dispatchEvent(new window.CustomEvent("menumijia:system-sleep"));
      await flush();
      assert.equal(sent.length, 1);
    } finally {
      stop();
    }
  });

  it("pauses unavailable targets and skips the schedule minute already in progress", async () => {
    const now = new Date(2026, 10, 20, 12, 0, 10).getTime();
    const missing = createAutomationRule({
      id: "missing", trigger: "systemSleep",
      action: { ...LIGHT_OFF_ACTION, deviceIds: ["light.removed"] },
    });
    const schedule = createAutomationRule({
      id: "schedule", trigger: "scheduledTime", action: LIGHT_OFF_ACTION,
      triggerOptions: { scheduledTime: { hour: 12, minute: 0 } },
    });
    const { app, sent } = trackingApp([missing, schedule]);
    const store = getHostActivityCenter(app).automationEngine.store;
    setEventAutomationRunning(app, false, now);
    assert.equal(store.load().find((rule) => rule.id === "missing")?.isEnabled, true);
    setEventAutomationRunning(app, true, now);
    assert.deepEqual(store.load().find((rule) => rule.id === "missing"), { ...missing, isEnabled: false });
    await dispatchSystemContextEvent(app, { kind: "tick" }, now + 1_000);
    assert.deepEqual(sent, []);
    await dispatchSystemContextEvent(app, { kind: "tick" }, now + 86_400_000);
    assert.equal(sent.length, 1);
  });

  it("resumes a scene-only home without device cards and still pauses it when the source is not live", () => {
    const sceneRule = (id: string, sceneId: string) =>
      createAutomationRule({ id, trigger: "systemSleep", action: { kind: "scene", sceneId } });
    const rules = [sceneRule("sleep-scene", "scene.sleep"), sceneRule("gone-scene", "scene.removed")];
    const { app } = trackingApp(rules);
    // A Home Assistant home whose kept types leave no device cards: scenes are all it has.
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.local:8123";
    app.settings.haToken = "ha-token";
    app.devices = [];
    app.scenes = [{ id: "scene.sleep", name: "睡眠模式", entityId: "scene.sleep" }];
    markTimerSnapshotReady(app);

    setEventAutomationRunning(app, false);
    assert.equal(setEventAutomationRunning(app, true), true);
    assert.deepEqual(
      getHostActivityCenter(app).automationEngine.store.load().map(({ id, isEnabled }) => [id, isEnabled]),
      [["sleep-scene", true], ["gone-scene", false]],
    );

    // A pending source switch (no snapshot for this revision) pauses the scene rule again.
    setEventAutomationRunning(app, false);
    app.sourceEpoch.advance("source");
    assert.equal(setEventAutomationRunning(app, true), true);
    assert.deepEqual(
      getHostActivityCenter(app).automationEngine.store.load().map(({ id, isEnabled }) => [id, isEnabled]),
      [["sleep-scene", false], ["gone-scene", false]],
    );

    // A failed Home Assistant connection is not a live source either.
    markTimerSnapshotReady(app);
    app.haConnectionError = "Home Assistant authentication rejected";
    setEventAutomationRunning(app, false);
    assert.equal(setEventAutomationRunning(app, true), true);
    assert.equal(
      getHostActivityCenter(app).automationEngine.store.load().find((rule) => rule.id === "sleep-scene")?.isEnabled,
      false,
    );
  });

  it("pauses a climate quick action after fan is disabled and keeps lights off available", () => {
    const rules = (["climateSleepOff", "lightsOff"] as const).map((quickAction) =>
      createAutomationRule({ id: quickAction, trigger: "systemSleep", action: { kind: "quickAction", quickAction } }));
    const { app } = trackingApp(rules);
    app.settings.connectionMode = "homeAssistant";
    const light = makeLight();
    if (light.kind.kind === "light") light.kind.isOn = false;
    app.devices = [light, {
      ...light, id: "climate.bedroom",
      kind: {
        kind: "climate", entityId: "climate.bedroom", isOn: false,
        hvacMode: "off", availableModes: ["cool"], targetTemperature: 26,
        currentTemperature: null, minTemp: 16, maxTemp: 30, step: 1,
        fanMode: null, availableFanModes: [],
      },
    }];
    assert.equal(app.setEnabledDeviceCategories(["light", "climate", "fan"]), true);
    setEventAutomationRunning(app, false);
    assert.equal(app.setEnabledDeviceCategories(["light", "climate"]), true);
    assert.equal(setEventAutomationRunning(app, true), true);
    assert.deepEqual(getHostActivityCenter(app).automationEngine.store.load().map(({ id, isEnabled }) =>
      [id, isEnabled]), [["climateSleepOff", false], ["lightsOff", true]]);
  });

  for (const restart of [false, true]) {
    it(`stops a multi-target run after ${restart ? "a quick restart" : "switching off"} and keeps its undo`, async () => {
      const action = restart
        ? { kind: "quickAction", quickAction: "softNightLight" } as const
        : { ...LIGHT_OFF_ACTION, deviceIds: ["light.desk", "light.bedroom"] };
      const { app, sent } = trackingApp([createAutomationRule({ trigger: "systemSleep", action })]);
      const light = makeLight();
      assert.equal(light.kind.kind, "light");
      app.devices = [makeLight(), { ...light, id: "light.bedroom", kind: { ...light.kind, entityId: "light.bedroom" } }];
      let release!: (accepted: boolean) => void;
      const command = new Promise<boolean>((resolve) => { release = resolve; });
      app.applyCommand = (cmd) => {
        sent.push(cmd);
        return command;
      };

      const dispatch = dispatchSystemContextEvent(app, { kind: "systemSleep" });
      assert.equal(sent.length, 1);
      setEventAutomationRunning(app, false);
      if (restart) assert.equal(setEventAutomationRunning(app, true), true);
      release(true);
      const runs = await dispatch;

      assert.equal(sent.length, 1);
      assert.deepEqual(runs[0]?.steps.map((step) => step.deviceId), ["light.desk"]);
      assert.equal(runs[0]?.attemptedCount, 1);
      assert.ok(app.lastUndoAction);
    });
  }

  it("stays off when rule pauses cannot be saved", () => {
    const rule = createAutomationRule({
      trigger: "systemSleep",
      action: { ...LIGHT_OFF_ACTION, deviceIds: ["light.removed"] },
    });
    const { app } = trackingApp([rule]);
    const store = getHostActivityCenter(app).automationEngine.store;
    setEventAutomationRunning(app, false);
    store.save = () => false;
    assert.equal(setEventAutomationRunning(app, true), false);
    assert.equal(app.settings.eventAutomationEnabled, false);
    assert.equal(store.load()[0]?.isEnabled, true);
  });

  it("discards an old power sample even when automation has already restarted", async () => {
    const now = Date.now();
    const rule = createAutomationRule({ trigger: "powerConnected", action: LIGHT_OFF_ACTION });
    const { app, sent } = trackingApp([rule]);
    const center = getHostActivityCenter(app);
    stubNative({ power: { hasBattery: true, onExternalPower: false, batteryPercent: 70 } });
    await pollSystemContextSignals(app, now);

    let release!: (status: NativeStub["power"]) => void;
    const power = new Promise<NativeStub["power"]>((resolve) => { release = resolve; });
    window.__TAURI_INTERNALS__ = {
      invoke: async <T>(cmd: string): Promise<T> =>
        (cmd === "system_power_status" ? await power : false) as T,
    };
    const poll = pollSystemContextSignals(app, now + SYSTEM_CONTEXT_POLL_INTERVAL_MS);
    setEventAutomationRunning(app, false);
    setEventAutomationRunning(app, true);
    release({ hasBattery: true, onExternalPower: true, batteryPercent: 70 });
    assert.equal(await poll, false);
    assert.equal(center.systemSignalBaseline, null);
    assert.deepEqual(sent, []);
  });

  it("keeps the started rule's undo and discards the next rule even after a quick restart", async () => {
    const rules = ["first", "queued"].map((id) =>
      createAutomationRule({ id, trigger: "systemSleep", action: LIGHT_OFF_ACTION }));
    const { app } = trackingApp(rules);
    let release!: (accepted: boolean) => void;
    const command = new Promise<boolean>((resolve) => { release = resolve; });
    let writes = 0;
    app.applyCommand = () => {
      writes += 1;
      return command;
    };

    const dispatch = dispatchSystemContextEvent(app, { kind: "systemSleep" });
    assert.equal(writes, 1);
    setEventAutomationRunning(app, false);
    setEventAutomationRunning(app, true);
    release(true);
    const runs = await dispatch;

    assert.equal(writes, 1);
    assert.deepEqual(runs.map((run) => run.ruleId), ["first"]);
    assert.ok(app.lastUndoAction);
    assert.equal(getHostActivityCenter(app).recentAutomationRuns.length, 1);
  });

  it("detaches the system-event listeners once a settings reload settles automation on off", async () => {
    // A cold start whose settings read failed binds the three automation listeners to the default
    // (on); the repaired storage below says off, so the listeners must go away with the reload.
    const tracked = (type: string): boolean => AUTOMATION_EVENT_TYPES.includes(type);
    const listeners = new Set<string>();
    const addEventListener = window.addEventListener.bind(window);
    const removeEventListener = window.removeEventListener.bind(window);
    window.addEventListener = (type: string, listener: EventListenerOrEventListenerObject) => {
      if (tracked(type)) listeners.add(`${type}:${String(listener)}`);
      addEventListener(type, listener);
    };
    window.removeEventListener = (type: string, listener: EventListenerOrEventListenerObject) => {
      if (tracked(type)) listeners.delete(`${type}:${String(listener)}`);
      removeEventListener(type, listener);
    };
    try {
      localStorage.setItem(STORAGE_KEY, "{not-json");
      const app = new MenuMijiaWindowsApp(element("#app"));
      const stub = stubNative();
      const stop = bindLifecycleRecovery(app);
      try {
        const bound = [...listeners].filter((entry) => entry.startsWith("menumijia:system-sleep:"));
        assert.equal(bound.length, 1, "the default (on) binds the native system-event consumers");

        localStorage.setItem(STORAGE_KEY, JSON.stringify({
          connectionMode: "demo",
          hasCompletedOnboarding: true,
          eventAutomationEnabled: false,
        }));
        await retryIdentityMigration(app);
        assert.equal(app.settings.eventAutomationEnabled, false, "the repaired storage value wins");
        assert.deepEqual([...listeners], [], "a settled off switch unbinds the system-event consumers");

        window.dispatchEvent(new window.CustomEvent("menumijia:system-sleep"));
        await flush();
        assert.deepEqual(stub.calls, []);
      } finally {
        stop();
      }
    } finally {
      window.addEventListener = addEventListener;
      window.removeEventListener = removeEventListener;
    }
  });
});
