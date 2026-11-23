import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, element, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  AutomationEngine,
  AutomationRuleStore,
  createAutomationConditions,
  createAutomationRule,
  type AutomationExecutionHost,
  type AutomationRule,
  type AutomationTrigger,
  type SystemContextEvent,
} from "../src/core/automationEngine.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import type { KeyValueStorageLike } from "../src/core/safetyAndHealth.js";
import { resetSharedSensorHistoryStoreForTests } from "../src/core/sensorHistory.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";

const DAY_MINUTES = 24 * 60;
const NIGHT = { isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60 };
const DAY = { isEnabled: true, startMinute: 9 * 60, endMinute: 18 * 60 };
const RANGE_SUMMARY = "22:00\u201307:00";

class MemoryKV implements KeyValueStorageLike {
  private readonly map = new Map<string, string>();
  public getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  public setItem(key: string, value: string): void {
    this.map.set(key, value);
  }
  public removeItem(key: string): void {
    this.map.delete(key);
  }
}

function at(hour: number, minute = 0, second = 0, day = 12): number {
  return new Date(2026, 10, day, hour, minute, second).getTime();
}

function makeLight(isOn = true): SmartDevice {
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
      isOn,
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

function makeSensor(temperature: number): SmartDevice {
  return {
    id: "s.temp",
    name: "书房温度计",
    roomId: "room_study",
    roomName: "书房",
    model: "lumi.sensor_ht.v1",
    isOnline: true,
    kind: { kind: "sensor", temperature, humidity: 40, battery: 90 },
  };
}

function setLightOn(device: SmartDevice, isOn: boolean): void {
  if (device.kind.kind !== "light") return;
  device.kind = { ...device.kind, isOn };
}

function setTemperature(device: SmartDevice, temperature: number): void {
  if (device.kind.kind !== "sensor") return;
  device.kind = { ...device.kind, temperature };
}

function trackingHost(devices: SmartDevice[]): { host: AutomationExecutionHost; commands: DeviceCommand[] } {
  const commands: DeviceCommand[] = [];
  const host: AutomationExecutionHost = {
    devices,
    scenes: [],
    applyCommand: async (command) => {
      commands.push(command);
      return true;
    },
  };
  return { host, commands };
}

function deviceOffAction() {
  return { kind: "devices" as const, deviceIds: ["light.desk"], isOn: false };
}

function loadStored(raw: Record<string, unknown>): AutomationRule {
  const kv = new MemoryKV();
  kv.setItem(AutomationRuleStore.storageKey, JSON.stringify([raw]));
  const loaded = new AutomationRuleStore(kv).load();
  assert.equal(loaded.length, 1);
  return loaded[0]!;
}

function storedRule(args: {
  id: string;
  trigger: AutomationTrigger;
  timeWindow?: { isEnabled: boolean; startMinute: number; endMinute: number };
  triggerOptions?: Record<string, unknown>;
  wifi?: Record<string, unknown>;
}): Record<string, unknown> {
  const conditions: Record<string, unknown> = { wifi: args.wifi ?? { kind: "any" } };
  if (args.timeWindow) conditions.timeWindow = args.timeWindow;
  return {
    id: args.id,
    isEnabled: true,
    trigger: args.trigger,
    action: deviceOffAction(),
    ...(args.triggerOptions ? { triggerOptions: args.triggerOptions } : {}),
    conditions,
  };
}

async function dispatch(
  engine: AutomationEngine,
  host: AutomationExecutionHost,
  event: SystemContextEvent,
  rules: readonly AutomationRule[],
  nowMs: number,
  resumedAtMs?: number,
) {
  return engine.dispatchEvent(host, event, {
    rules,
    nowMs,
    ...(resumedAtMs !== undefined ? { resumedAtMs } : {}),
  });
}

async function awayCommands(
  window: { isEnabled: boolean; startMinute: number; endMinute: number } | undefined,
  hour: number,
  minute = 0,
  second = 0,
  day = 12,
): Promise<number> {
  const engine = new AutomationEngine(new MemoryKV());
  engine.primeLockBaseline(false);
  const rule = loadStored(
    storedRule({
      id: `away-${hour}-${minute}-${second}`,
      trigger: "away",
      ...(window ? { timeWindow: window } : {}),
    }),
  );
  const { host, commands } = trackingHost([makeLight()]);
  await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], at(hour, minute, second, day));
  return commands.length;
}

describe("automation time window", () => {
  it("includes the start minute and excludes the end minute", async () => {
    assert.equal(await awayCommands(DAY, 9, 0), 1);
    assert.equal(await awayCommands(DAY, 12, 0), 1);
    assert.equal(await awayCommands(DAY, 17, 59), 1);
    assert.equal(await awayCommands(DAY, 18, 0), 0);
    assert.equal(await awayCommands(DAY, 18, 0, 30), 0);
    assert.equal(await awayCommands(DAY, 8, 59), 0);
  });

  it("judges minutes from midnight, not whole hours", async () => {
    const window = { isEnabled: true, startMinute: 9 * 60 + 30, endMinute: 10 * 60 };
    assert.equal(await awayCommands(window, 9, 30), 1);
    assert.equal(await awayCommands(window, 9, 29), 0);
    assert.equal(await awayCommands(window, 9, 59), 1);
    assert.equal(await awayCommands(window, 10, 0), 0);
  });

  it("wraps an overnight window past midnight", async () => {
    assert.equal(await awayCommands(NIGHT, 22, 0), 1);
    assert.equal(await awayCommands(NIGHT, 23, 30), 1);
    assert.equal(await awayCommands(NIGHT, 0, 0), 1);
    assert.equal(await awayCommands(NIGHT, 6, 59), 1);
    assert.equal(await awayCommands(NIGHT, 7, 0), 0);
    assert.equal(await awayCommands(NIGHT, 12, 0), 0);
    assert.equal(await awayCommands(NIGHT, 21, 59), 0);
  });

  it("treats equal ends as the whole day and keeps them on the stored rule", async () => {
    const equal = { isEnabled: true, startMinute: 8 * 60, endMinute: 8 * 60 };
    const rule = loadStored(storedRule({ id: "equal", trigger: "away", timeWindow: equal }));
    assert.equal(rule.conditions.timeWindow?.isEnabled, true);
    assert.equal(rule.conditions.timeWindow?.startMinute, 8 * 60);
    assert.equal(rule.conditions.timeWindow?.endMinute, 8 * 60);
    assert.equal(await awayCommands(equal, 0, 0), 1);
    assert.equal(await awayCommands(equal, 8, 0), 1);
    assert.equal(await awayCommands(equal, 20, 0), 1);
  });

  it("runs a disabled window at noon and at night", async () => {
    const disabled = { isEnabled: false, startMinute: 22 * 60, endMinute: 7 * 60 };
    const rule = loadStored(storedRule({ id: "disabled", trigger: "away", timeWindow: disabled }));
    assert.equal(rule.conditions.timeWindow?.isEnabled, false);
    assert.equal(await awayCommands(disabled, 12, 0), 1);
    assert.equal(await awayCommands(disabled, 3, 0), 1);
  });

  it("loads a stored rule that has no timeWindow key unchanged", async () => {
    const rule = loadStored(
      storedRule({
        id: "legacy-json",
        trigger: "away",
        wifi: { kind: "inAny", ssids: ["Home"] },
      }),
    );
    assert.equal(rule.id, "legacy-json");
    assert.equal(rule.trigger, "away");
    assert.equal(rule.isEnabled, true);
    assert.deepEqual(rule.conditions.wifi, { kind: "inAny", ssids: ["Home"] });
    assert.equal(rule.conditions.timeWindow?.isEnabled, false);
    assert.equal(rule.action.kind, "devices");

    const open = loadStored(storedRule({ id: "legacy-open", trigger: "away" }));
    assert.equal(await awayCommands(undefined, 12, 0), 1);
    assert.equal(await awayCommands(undefined, 3, 0), 1);
    assert.equal(open.conditions.timeWindow?.isEnabled, false);
    assert.equal(open.conditions.timeWindow?.startMinute, 22 * 60);
    assert.equal(open.conditions.timeWindow?.endMinute, 7 * 60);
  });

  it("keeps a time window created in memory and reloads it from storage", async () => {
    const created = createAutomationRule({
      id: "factory-night",
      trigger: "away",
      action: deviceOffAction(),
      conditions: createAutomationConditions({ kind: "any" }, { isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60 }),
    });
    assert.equal(created.conditions.timeWindow?.isEnabled, true);
    assert.equal(created.conditions.timeWindow?.startMinute, 22 * 60);
    assert.equal(created.conditions.timeWindow?.endMinute, 7 * 60);

    const kv = new MemoryKV();
    const store = new AutomationRuleStore(kv);
    store.save([created]);
    const reloaded = store.load()[0];
    assert.ok(reloaded);
    assert.equal(reloaded.conditions.timeWindow?.endMinute, 7 * 60);
    assert.equal(await awayCommands(NIGHT, 12, 0), 0);
    assert.equal(await awayCommands(NIGHT, 23, 0), 1);

    const legacy = createAutomationRule({
      id: "factory-legacy",
      trigger: "away",
      action: deviceOffAction(),
    });
    assert.equal(legacy.conditions.timeWindow?.isEnabled, false);
    assert.equal(await awayCommands(undefined, 15, 0), 1);
  });

  it("clamps minutes into a single day", () => {
    const clamped = createAutomationRule({
      id: "clamped",
      trigger: "away",
      action: deviceOffAction(),
      conditions: createAutomationConditions({ kind: "any" }, { isEnabled: true, startMinute: 5_000, endMinute: -20 }),
    });
    assert.equal(clamped.conditions.timeWindow?.startMinute, DAY_MINUTES - 1);
    assert.equal(clamped.conditions.timeWindow?.endMinute, 0);
  });

  it("does not run an away rule outside the window and still runs the next lock inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const rule = loadStored(storedRule({ id: "away-gate", trigger: "away", timeWindow: DAY }));
    const { host, commands } = trackingHost([makeLight()]);
    const outside = at(8, 59, 30);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], outside);
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: false }, [rule], outside + 10_000);
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("still consumes the away cooldown when the lock is inside the window", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const rule = loadStored(storedRule({ id: "away-cool", trigger: "away", timeWindow: DAY }));
    const light = makeLight();
    const { host, commands } = trackingHost([light]);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], at(10, 0, 0));
    assert.equal(commands.length, 1);
    setLightOn(light, true);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: false }, [rule], at(10, 0, 10));
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], at(10, 0, 20));
    assert.equal(commands.length, 1);
  });

  it("does not run a power-saver rule outside the window and still runs the next change inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const rule = loadStored(
      storedRule({
        id: "saver",
        trigger: "powerSaverChanged",
        timeWindow: DAY,
        triggerOptions: { powerSaverEnabled: true },
      }),
    );
    const { host, commands } = trackingHost([makeLight()]);
    await dispatch(engine, host, { kind: "powerChanged", powerSaverEnabled: true }, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "powerChanged", powerSaverEnabled: false }, [rule], at(8, 59, 40));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "powerChanged", powerSaverEnabled: true }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("does not run a low-battery rule outside the window and still runs the next drop inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const rule = loadStored(
      storedRule({
        id: "battery",
        trigger: "batteryBelowThreshold",
        timeWindow: DAY,
        triggerOptions: { batteryThresholdPercent: 20 },
      }),
    );
    const { host, commands } = trackingHost([makeLight()]);
    await dispatch(engine, host, { kind: "powerChanged", onExternalPower: false, batteryPercent: 80 }, [rule], at(8, 0, 0));
    await dispatch(engine, host, { kind: "powerChanged", batteryPercent: 10 }, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "powerChanged", batteryPercent: 80 }, [rule], at(8, 59, 40));
    await dispatch(engine, host, { kind: "powerChanged", batteryPercent: 10 }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("does not run a Wi-Fi join rule outside the window and still runs the next join inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const rule = loadStored(storedRule({ id: "wifi-join", trigger: "wifiNetworkJoined", timeWindow: DAY }));
    const { host, commands } = trackingHost([makeLight()]);
    // 显式可信读数：首轮建立基线（默认快照不可信，不会触发）。
    await dispatch(engine, host, { kind: "wifiChanged", ssid: "Home", isAuthorized: true }, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, [rule], at(8, 59, 40));
    await dispatch(engine, host, { kind: "wifiChanged", ssid: "Home", isAuthorized: true }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("does not run a Wi-Fi leave rule outside the window and still runs the next leave inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const rule = loadStored(storedRule({ id: "wifi-leave", trigger: "wifiNetworkLeft", timeWindow: DAY }));
    const { host, commands } = trackingHost([makeLight()]);
    await dispatch(engine, host, { kind: "wifiChanged", ssid: "Home", isAuthorized: true }, [rule], at(8, 59, 0));
    await dispatch(engine, host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "wifiChanged", ssid: "Home", isAuthorized: true }, [rule], at(8, 59, 40));
    await dispatch(engine, host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("does not run a calendar rule outside the window and still runs that meeting inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const rule = loadStored(
      storedRule({
        id: "calendar",
        trigger: "calendarMeetingStartingSoon",
        timeWindow: DAY,
        triggerOptions: { calendarLeadMinutes: 5 },
      }),
    );
    const { host, commands } = trackingHost([makeLight()]);
    const event: SystemContextEvent = { kind: "calendarMeetingSoon", eventId: "meet-1", startsInMinutes: 1 };
    await dispatch(engine, host, event, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, event, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("skips late-night rules outside the window on tick and on panel wake without burning the night", async () => {
    const lateOptions = { lateNightWindow: { startHour: 20, endHour: 8 } };
    const narrow = { isEnabled: true, startMinute: 60, endMinute: 120 };
    for (const kind of ["tick", "panelWake"] as const) {
      const engine = new AutomationEngine(new MemoryKV());
      const rule = loadStored(
        storedRule({
          id: `late-${kind}`,
          trigger: "lateNightUsage",
          timeWindow: narrow,
          triggerOptions: lateOptions,
        }),
      );
      const { host, commands } = trackingHost([makeLight()]);
      await dispatch(engine, host, { kind }, [rule], at(23, 30, 0, 12));
      assert.equal(commands.length, 0, kind);
      await dispatch(engine, host, { kind }, [rule], at(1, 30, 0, 13));
      assert.equal(commands.length, 1, kind);
    }
  });

  it("skips the resumed late-night window on panel wake as well as on tick, then fires the next night", async () => {
    const lateOptions = { lateNightWindow: { startHour: 20, endHour: 8 } };
    for (const kind of ["tick", "panelWake"] as const) {
      const engine = new AutomationEngine(new MemoryKV());
      const rule = loadStored(
        storedRule({ id: `late-resume-${kind}`, trigger: "lateNightUsage", triggerOptions: lateOptions }),
      );
      const { host, commands } = trackingHost([makeLight()]);
      // Automation was switched back on at 23:30 on day 12, inside the late-night window.
      const resumedAtMs = at(23, 30, 0, 12);
      await dispatch(engine, host, { kind }, [rule], at(23, 31, 0, 12), resumedAtMs);
      assert.equal(commands.length, 0, `${kind}: the resumed night is skipped`);
      // The very next night is a new window, so the same rule fires again.
      await dispatch(engine, host, { kind }, [rule], at(23, 31, 0, 13), resumedAtMs);
      assert.equal(commands.length, 1, `${kind}: the next night still fires`);
    }
  });

  it("does not burn a scheduled minute that falls outside the window", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const scheduled = { scheduledTime: { hour: 12, minute: 0 } };
    const closed = loadStored(
      storedRule({
        id: "sched",
        trigger: "scheduledTime",
        timeWindow: NIGHT,
        triggerOptions: scheduled,
      }),
    );
    const opened = loadStored(
      storedRule({
        id: "sched",
        trigger: "scheduledTime",
        timeWindow: { isEnabled: false, startMinute: 0, endMinute: 0 },
        triggerOptions: scheduled,
      }),
    );
    const { host, commands } = trackingHost([makeLight()]);
    await dispatch(engine, host, { kind: "tick" }, [closed], at(12, 0, 0));
    assert.equal(commands.length, 0);
    await dispatch(engine, host, { kind: "tick" }, [opened], at(12, 0, 20));
    assert.equal(commands.length, 1);

    assert.equal(
      await (async () => {
        const fresh = new AutomationEngine(new MemoryKV());
        const nightRule = loadStored(
          storedRule({
            id: "sched-night",
            trigger: "scheduledTime",
            timeWindow: NIGHT,
            triggerOptions: { scheduledTime: { hour: 23, minute: 30 } },
          }),
        );
        const tracked = trackingHost([makeLight()]);
        await dispatch(fresh, tracked.host, { kind: "tick" }, [nightRule], at(23, 30, 0));
        return tracked.commands.length;
      })(),
      1,
    );
    assert.equal(
      await (async () => {
        const fresh = new AutomationEngine(new MemoryKV());
        const ended = loadStored(
          storedRule({
            id: "sched-end",
            trigger: "scheduledTime",
            timeWindow: NIGHT,
            triggerOptions: { scheduledTime: { hour: 7, minute: 0 } },
          }),
        );
        const tracked = trackingHost([makeLight()]);
        await dispatch(fresh, tracked.host, { kind: "tick" }, [ended], at(7, 0, 0));
        return tracked.commands.length;
      })(),
      0,
    );
  });

  it("does not run a sensor rule outside the window and still runs the next rise inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    const sensor = makeSensor(20);
    const rule = loadStored(
      storedRule({
        id: "sensor",
        trigger: "sensorThreshold",
        timeWindow: DAY,
        triggerOptions: {
          sensorCondition: { deviceId: "s.temp", metric: "temperature", comparison: "gte", threshold: 30 },
        },
      }),
    );
    const { host, commands } = trackingHost([sensor, makeLight()]);
    setTemperature(sensor, 31);
    await dispatch(engine, host, { kind: "tick" }, [rule], at(8, 59, 20));
    assert.equal(commands.length, 0);
    setTemperature(sensor, 20);
    await dispatch(engine, host, { kind: "tick" }, [rule], at(8, 59, 40));
    setTemperature(sensor, 31);
    await dispatch(engine, host, { kind: "tick" }, [rule], at(9, 0, 0));
    assert.equal(commands.length, 1);
  });

  it("does not run a screen lock from before a night window when the flush lands inside it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const rule = loadStored(storedRule({ id: "lock-night", trigger: "screenLocked", timeWindow: NIGHT }));
    const { host, commands } = trackingHost([makeLight()]);
    const lockAt = at(21, 59, 59);
    const tickAt = lockAt + 2_000;
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], lockAt);
    await dispatch(engine, host, { kind: "tick" }, [rule], tickAt);
    assert.equal(commands.length, 0);
    assert.equal(engine.deduper.lastFireAtMs("screenLocked"), null);

    const laterLockAt = tickAt + 30_000;
    await dispatch(engine, host, { kind: "lockChanged", isLocked: false }, [rule], tickAt + 1_000);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], laterLockAt);
    await dispatch(engine, host, { kind: "tick" }, [rule], laterLockAt + 2_000);
    assert.equal(commands.length, 1);
    assert.equal(engine.deduper.lastFireAtMs("screenLocked"), laterLockAt);
  });

  it("runs a screen lock inside a day window that ends at 22:00 when the flush lands after it", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const until22 = { isEnabled: true, startMinute: 9 * 60, endMinute: 22 * 60 };
    const rule = loadStored(storedRule({ id: "lock-day", trigger: "screenLocked", timeWindow: until22 }));
    const { host, commands } = trackingHost([makeLight()]);
    const lockAt = at(21, 59, 59);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], lockAt);
    await dispatch(engine, host, { kind: "tick" }, [rule], lockAt + 2_000);
    assert.equal(commands.length, 1);
    assert.equal(engine.deduper.lastFireAtMs("screenLocked"), lockAt);
  });

  it("judges a screen lock at the lock instant when the confirming tick is at 00:30", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const rule = loadStored(storedRule({ id: "lock-late", trigger: "screenLocked", timeWindow: NIGHT }));
    const { host, commands } = trackingHost([makeLight()]);
    const lockAt = at(21, 59, 59);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], lockAt);
    await dispatch(engine, host, { kind: "tick" }, [rule], at(0, 30, 0, 13));
    assert.equal(commands.length, 0);
    assert.equal(engine.deduper.lastFireAtMs("screenLocked"), null);
  });

  it("records a confirmed screen lock at the lock instant and keeps undo open from the flush", async () => {
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const rule = loadStored(storedRule({ id: "lock-stamp", trigger: "screenLocked", timeWindow: NIGHT }));
    const { host, commands } = trackingHost([makeLight()]);
    const lockAt = at(22, 0, 0);
    const tickAt = at(0, 30, 0, 13);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], lockAt);
    const runs = await dispatch(engine, host, { kind: "tick" }, [rule], tickAt);
    assert.equal(commands.length, 1);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]?.firedAtMs, lockAt);
    assert.ok((runs[0]?.expiresAtMs ?? 0) > tickAt);
  });

  it("loads an enabled window whose minutes are not numbers as disabled and still runs at noon", async () => {
    const kv = new MemoryKV();
    kv.setItem(
      AutomationRuleStore.storageKey,
      JSON.stringify([
        {
          id: "string-minutes",
          isEnabled: true,
          trigger: "away",
          action: deviceOffAction(),
          conditions: {
            wifi: { kind: "any" },
            timeWindow: { isEnabled: true, startMinute: "540", endMinute: "1080" },
          },
        },
      ]),
    );
    const rule = new AutomationRuleStore(kv).load()[0];
    assert.ok(rule);
    const engine = new AutomationEngine(new MemoryKV());
    engine.primeLockBaseline(false);
    const { host, commands } = trackingHost([makeLight()]);
    await dispatch(engine, host, { kind: "lockChanged", isLocked: true }, [rule], at(12, 0, 0));
    assert.equal(commands.length, 1);
    assert.equal(rule.conditions.timeWindow?.isEnabled, false);
  });
});

describe("automation time window settings", () => {
  let dom: Window;

  async function click(selector: string): Promise<void> {
    element(selector).click();
    await setImmediate();
  }

  function selectValue(selector: string, value: string): void {
    const sel = element<HTMLSelectElement>(selector);
    sel.value = value;
    sel.dispatchEvent(new window.Event("change", { bubbles: true }));
  }

  function toggleCheck(selector: string, checked: boolean): void {
    const input = element<HTMLInputElement>(selector);
    input.checked = checked;
    input.dispatchEvent(new window.Event("change", { bubbles: true }));
  }

  function createCloudApp(): MenuMijiaWindowsApp {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
        selectedHomeId: "home-main",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    app.refreshHADevices = async () => {};
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = {
      userId: "10086",
      serviceToken: "tok",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      cUserId: "c10086",
      passToken: "pass",
      region: "cn",
    };
    app.settings.interfaceLanguage = "zh-Hans";
    app.cloudValuesStale = false;
    return app;
  }

  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    installCssEscape();
    resetSharedSensorHistoryStoreForTests();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    resetSharedSensorHistoryStoreForTests();
    await closeTestWindow(dom);
  });

  it("saves a 22:00–07:00 window and shows it in zh-Hans, zh-Hant, and English", async () => {
    const app = createCloudApp();
    app.openSettingsSheet("safety");
    assert.equal(element<HTMLInputElement>("#settings-auto-time-window").checked, false);
    assert.equal(document.querySelector("#settings-auto-time-start"), null);

    toggleCheck("#settings-auto-time-window", true);
    assert.equal(element<HTMLSelectElement>("#settings-auto-time-start").value, "22");
    assert.equal(element<HTMLSelectElement>("#settings-auto-time-end").value, "7");
    assert.match(element("#settings-auto-time-hint").textContent ?? "", /跨夜/);
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, false);

    await click("#btn-add-auto-rule");
    const saved = new AutomationRuleStore().load()[0];
    assert.ok(saved);
    assert.equal(saved.conditions.timeWindow?.isEnabled, true);
    assert.equal(saved.conditions.timeWindow?.startMinute, 22 * 60);
    assert.equal(saved.conditions.timeWindow?.endMinute, 7 * 60);
    assert.match(document.body.textContent ?? "", new RegExp(`时段 ${RANGE_SUMMARY}`));

    app.settings.interfaceLanguage = "zh-Hant";
    app.render();
    assert.match(document.body.textContent ?? "", new RegExp(`時段 ${RANGE_SUMMARY}`));

    app.settings.interfaceLanguage = "en";
    app.render();
    assert.match(document.body.textContent ?? "", new RegExp(`Between ${RANGE_SUMMARY}`));
    assert.match(element("#settings-auto-time-window").parentElement?.textContent ?? "", /Only between/);
  });

  it("refuses a window whose start and end hours are the same", () => {
    const app = createCloudApp();
    app.openSettingsSheet("safety");
    toggleCheck("#settings-auto-time-window", true);
    selectValue("#settings-auto-time-start", "8");
    selectValue("#settings-auto-time-end", "8");
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, true);
    assert.match(element("#settings-auto-time-hint").textContent ?? "", /起止不能相同/);
    assert.equal(new AutomationRuleStore().load().length, 0);

    app.settings.interfaceLanguage = "zh-Hant";
    app.render();
    assert.match(element("#settings-auto-time-hint").textContent ?? "", /起止不能相同/);

    app.settings.interfaceLanguage = "en";
    app.render();
    assert.match(element("#settings-auto-time-hint").textContent ?? "", /Start and end must differ/);
  });

  it("keeps Save gated only by the time window now that the Wi-Fi condition editor is enabled", async () => {
    const app = createCloudApp();
    app.openSettingsSheet("safety");
    toggleCheck("#settings-auto-time-window", true);
    selectValue("#settings-auto-time-start", "8");
    selectValue("#settings-auto-time-end", "8");
    assert.equal(element<HTMLSelectElement>("#settings-auto-wifi-kind").disabled, false);
    assert.equal(document.querySelector("#settings-auto-wifi-unsupported-hint"), null);
    assert.equal(document.querySelector("#settings-auto-wifi-ssids"), null);
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, true);

    selectValue("#settings-auto-time-end", "18");
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, false);
    await click("#btn-add-auto-rule");
    const saved = new AutomationRuleStore().load()[0];
    assert.ok(saved);
    assert.deepEqual(saved.conditions.wifi, { kind: "any" });
  });
});
