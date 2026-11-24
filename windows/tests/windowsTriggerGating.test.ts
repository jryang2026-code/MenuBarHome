import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
  AUTOMATION_TRIGGERS,
  AutomationEngine,
  WINDOWS_SUPPORTED_TRIGGERS,
  WINDOWS_TRIGGER_SOURCES,
  WINDOWS_WIFI_CONDITION_SUPPORTED,
  createAutomationRule,
  isTriggerSupportedOnWindows,
  isWiFiConditionSupportedOnWindows,
  type AutomationExecutionHost,
  type AutomationTrigger,
} from "../src/core/automationEngine.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import type { KeyValueStorageLike } from "../src/core/safetyAndHealth.js";

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

function readProductionSources(): ReadonlyMap<string, string> {
  const srcRoot = fileURLToPath(new URL("../src", import.meta.url));
  const out = new Map<string, string>();
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(".ts")) out.set(full, readFileSync(full, "utf8"));
    }
  };
  walk(srcRoot);
  if (out.size === 0) throw new Error("no production sources found under windows/src");
  return out;
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

describe("Windows automation trigger gating (source of truth)", () => {
  it("declares exactly the triggers with production event sources", () => {
    assert.ok(WINDOWS_SUPPORTED_TRIGGERS.length > 0, "supported set must not be empty");
    assert.deepEqual([...WINDOWS_SUPPORTED_TRIGGERS].sort(), [
      "away",
      "back",
      "batteryBelowThreshold",
      "cameraInUse",
      "cameraNotInUse",
      "displaySleep",
      "displayWake",
      "externalDisplayConnected",
      "externalDisplayDisconnected",
      "focusModeDisabled",
      "focusModeEnabled",
      "lateNightUsage",
      "microphoneInUse",
      "microphoneNotInUse",
      "powerConnected",
      "powerDisconnected",
      "scheduledTime",
      "screenLocked",
      "screenUnlocked",
      "sensorThreshold",
      "systemSleep",
      "systemWake",
      "wifiNetworkJoined",
      "wifiNetworkLeft",
    ]);
    assert.deepEqual(new Set(WINDOWS_SUPPORTED_TRIGGERS).size, WINDOWS_SUPPORTED_TRIGGERS.length, "no duplicates");
    for (const trigger of WINDOWS_SUPPORTED_TRIGGERS) {
      assert.ok(AUTOMATION_TRIGGERS.includes(trigger), `${trigger} must be a known AutomationTrigger`);
      assert.equal(isTriggerSupportedOnWindows(trigger), true, `${trigger} must report supported`);
    }
    const unsupported = AUTOMATION_TRIGGERS.filter((t) => !isTriggerSupportedOnWindows(t));
    assert.ok(unsupported.length > 0, "engine-only triggers must stay unsupported until wired");
    for (const trigger of unsupported) {
      assert.equal(isTriggerSupportedOnWindows(trigger), false, `${trigger} must report unsupported`);
    }
  });

  it("enables Wi-Fi condition support now that SSID events are wired", () => {
    assert.equal(WINDOWS_WIFI_CONDITION_SUPPORTED, true);
    assert.equal(isWiFiConditionSupportedOnWindows({ kind: "any" }), true);
    assert.equal(isWiFiConditionSupportedOnWindows({ kind: "inAny", ssids: ["Home_5G"] }), true);
    assert.equal(isWiFiConditionSupportedOnWindows({ kind: "notIn", ssids: ["Office"] }), true);
  });

  it("maps every supported trigger to declared source kinds and nothing else", () => {
    const sourceTriggers = Object.keys(WINDOWS_TRIGGER_SOURCES) as readonly AutomationTrigger[];
    assert.deepEqual(
      [...sourceTriggers].sort(),
      [...WINDOWS_SUPPORTED_TRIGGERS].sort(),
      "WINDOWS_TRIGGER_SOURCES must cover exactly the supported set",
    );
    for (const [trigger, kinds] of Object.entries(WINDOWS_TRIGGER_SOURCES)) {
      assert.ok(kinds.length > 0, `${trigger} must declare at least one source event kind`);
      assert.deepEqual(new Set(kinds).size, kinds.length, `${trigger} kinds must be unique`);
    }
    // Wi-Fi 触发器的唯一来源是 wifiChanged，与前端轮询派发点对应。
    assert.deepEqual(WINDOWS_TRIGGER_SOURCES.wifiNetworkJoined, ["wifiChanged"]);
    assert.deepEqual(WINDOWS_TRIGGER_SOURCES.wifiNetworkLeft, ["wifiChanged"]);
  });

  it("guards that every supported trigger is driven by an event dispatched in production code", () => {
    const sources = readProductionSources();
    const engineSource = [...sources.entries()]
      .filter(([path]) => path.endsWith(join("core", "automationEngine.ts")))
      .map(([, text]) => text)
      .join("\n");

    // 生产代码里所有 dispatchSystemContextEvent(host, { kind: "…" }) 调用点（静态提取）。
    const dispatchedKinds = new Set<string>();
    for (const text of sources.values()) {
      for (const match of text.matchAll(/dispatchSystemContextEvent\(\s*host\s*,\s*\{\s*kind:\s*"([A-Za-z]+)"/g)) {
        dispatchedKinds.add(match[1] ?? "");
      }
    }
    dispatchedKinds.delete("");
    // 生产派发点：锁屏轮询、面板唤醒、周期 tick、Wi-Fi 轮询，以及电源/外接显示器采样
    // （`pollSystemContextSignals`）和原生休眠/息屏回调（`notifySystem*` /
    // `notifyDisplayPowerChanged`）。新增派发点必须连同本断言与
    // WINDOWS_SUPPORTED_TRIGGERS / WINDOWS_TRIGGER_SOURCES 一并扩展。
    assert.deepEqual(
      [...dispatchedKinds].sort(),
      [
        "displayPowerChanged",
        "externalDisplayChanged",
        "focusModeChanged",
        "lockChanged",
        "mediaCaptureChanged",
        "panelWake",
        "powerChanged",
        "systemSleep",
        "systemWake",
        "tick",
        "wifiChanged",
      ],
      "production dispatch sites changed; update WINDOWS_SUPPORTED_TRIGGERS gating together",
    );

    for (const [trigger, kinds] of Object.entries(WINDOWS_TRIGGER_SOURCES)) {
      for (const kind of kinds) {
        assert.ok(
          dispatchedKinds.has(kind),
          `${trigger} declares source kind "${kind}", but no production code dispatches it`,
        );
        assert.ok(
          engineSource.includes(`case "${kind}"`),
          `${trigger} declares source kind "${kind}", but automationEngine has no "${kind}" branch`,
        );
      }
      // 触发器在引擎里除支持集合声明外，还必须存在真实的判定/派发引用。
      const quotedCount = engineSource.split(`"${trigger}"`).length - 1;
      assert.ok(
        quotedCount >= 2,
        `${trigger} appears only ${quotedCount}× in automationEngine.ts; expected a firing-path reference`,
      );
    }
  });

  it("does not fire rules whose trigger is outside the supported set from Windows production events", async () => {
    const unsupported = AUTOMATION_TRIGGERS.filter((t) => !isTriggerSupportedOnWindows(t));
    if (unsupported.length === 0) return; // 支持集合扩满时此用例自然失效。
    const trigger = unsupported[0]!;
    const light = makeLight(true);
    const { host, commands } = trackingHost([light]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        trigger,
        action: { kind: "devices", deviceIds: [light.id], isOn: false },
        isEnabled: true,
      }),
    ]);

    const t0 = new Date(2026, 10, 14, 14, 0, 0).getTime();
    let runs = await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 + 100 });
    runs = runs.concat(await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: t0 + 2_600 }));
    runs = runs.concat(await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 + 3_000 }));
    runs = runs.concat(await engine.dispatchEvent(host, { kind: "panelWake" }, { nowMs: t0 + 3_100 }));
    runs = runs.concat(await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: t0 + 5_800 }));
    assert.equal(runs.length, 0, `${trigger} rules must not fire on Windows production events`);
    assert.equal(commands.length, 0);
  });

  it("still fires supported-trigger rules through the production event kinds", async () => {
    const light = makeLight(true);
    const { host, commands } = trackingHost([light]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        trigger: "scheduledTime",
        action: { kind: "devices", deviceIds: [light.id], isOn: false },
        isEnabled: true,
        triggerOptions: { scheduledTime: { hour: 8, minute: 15 } },
      }),
    ]);
    const fireMs = new Date(2026, 10, 14, 8, 15, 0).getTime();
    const runs = await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: fireMs });
    assert.equal(runs.length, 1);
    assert.deepEqual(commands, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);
  });
});
