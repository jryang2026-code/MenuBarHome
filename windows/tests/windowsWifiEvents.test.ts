import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  AUTOMATION_WIFI_SNAPSHOT_MAX_AGE_MS,
  AutomationEngine,
  createAutomationConditions,
  createAutomationRule,
  isAutomationWifiSnapshotFresh,
  wifiDispatchDecisionForObservation,
  wifiPollObservationFromProbe,
  type AutomationExecutionHost,
  type EngineWifiReading,
  type WindowsWifiProbeResult,
} from "../src/core/automationEngine.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import type { KeyValueStorageLike } from "../src/core/safetyAndHealth.js";
import { getHostActivityCenter, tickSafetyHealthAndAutomation } from "../src/ui/activityStackView.js";
import type { MenuMijiaWindowsApp } from "../src/ui/app.js";

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

function makeLight(id: string, isOn = true): SmartDevice {
  return {
    id,
    name: `灯 ${id}`,
    roomId: "room_study",
    roomName: "书房",
    model: "yeelink.light.lamp15",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: id,
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

describe("Windows Wi-Fi probe mapping (wifi_current → engine reading)", () => {
  it("maps the four probe states with macOS authorization semantics", () => {
    // 连接且有 SSID：已授权并联网。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "connected", ssid: "Home_5G" }), {
      state: "connected",
      reading: { ssid: "Home_5G", isAuthorized: true },
    });
    // SSID 两侧空白按引擎惯例修剪。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "connected", ssid: "  Home_5G " }), {
      state: "connected",
      reading: { ssid: "Home_5G", isAuthorized: true },
    });
    // 未连接：已授权但无 WLAN 关联（no-network），不是「无法知晓」。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "notConnected" }), {
      state: "notConnected",
      reading: { ssid: null, isAuthorized: true },
    });
    // 无权限：无法知晓（not-authorized），绝不能当成「未连接」。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "noPermission" }), {
      state: "noPermission",
      reading: { ssid: null, isAuthorized: false },
    });
    // 未知：同样给出「无法知晓」的读数（SSID 置空 + 不可信），引擎立即按不可信判定。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "unknown" }), {
      state: "unknown",
      reading: { ssid: null, isAuthorized: false },
    });
    // 连接但 SSID 为空（隐藏网络）＝无法知晓。
    assert.deepEqual(wifiPollObservationFromProbe({ state: "connected", ssid: "  " }), {
      state: "unknown",
      reading: { ssid: null, isAuthorized: false },
    });
    assert.deepEqual(wifiPollObservationFromProbe({ state: "connected", ssid: null }), {
      state: "unknown",
      reading: { ssid: null, isAuthorized: false },
    });
    // 异常载荷按未知处理。
    assert.deepEqual(wifiPollObservationFromProbe(undefined), {
      state: "unknown",
      reading: { ssid: null, isAuthorized: false },
    });
    assert.deepEqual(wifiPollObservationFromProbe({ state: "banana" } as unknown as WindowsWifiProbeResult), {
      state: "unknown",
      reading: { ssid: null, isAuthorized: false },
    });
  });

  it("dispatches only changed readings; unknown probes flip the engine to a fail-closed reading", () => {
    const last: EngineWifiReading = { ssid: "Home_5G", isAuthorized: true };
    const changed = wifiDispatchDecisionForObservation(
      wifiPollObservationFromProbe({ state: "connected", ssid: "Office" }),
      last,
    );
    assert.deepEqual(changed, { reading: { ssid: "Office", isAuthorized: true } });
    // 未变化不派发。
    assert.equal(wifiDispatchDecisionForObservation(wifiPollObservationFromProbe({ state: "connected", ssid: "Home_5G" }), last), null);
    // 授权状态变化也要派发。
    assert.deepEqual(
      wifiDispatchDecisionForObservation(wifiPollObservationFromProbe({ state: "noPermission" }), last),
      { reading: { ssid: null, isAuthorized: false } },
    );
    // 未知读数把引擎切到「无法知晓」（fail-closed），而不是保留旧的授权 SSID。
    assert.deepEqual(
      wifiDispatchDecisionForObservation(wifiPollObservationFromProbe({ state: "unknown" }), last),
      { reading: { ssid: null, isAuthorized: false } },
    );
    // 连续未知读数与上次相同，不再重复派发。
    assert.equal(
      wifiDispatchDecisionForObservation(wifiPollObservationFromProbe({ state: "unknown" }), { ssid: null, isAuthorized: false }),
      null,
    );
    // 首次读数（无基线）直接派发。
    assert.deepEqual(
      wifiDispatchDecisionForObservation(wifiPollObservationFromProbe({ state: "notConnected" }), null),
      { reading: { ssid: null, isAuthorized: true } },
    );
  });
});

describe("Windows Wi-Fi conditions & triggers through wifiChanged", () => {
  it("evaluates Wi-Fi conditions per probe state: connected fires, noPermission and notConnected do not", async () => {
    const light = makeLight("light.home", true);
    const { host, commands } = trackingHost([light]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "away-in-any",
        trigger: "away",
        action: { kind: "devices", deviceIds: ["light.home"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Home_5G"] }),
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 9, 0, 0).getTime();
    // 首条 lockChanged 只建立基线。
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 });

    // 已连接 Home_5G：锁屏离开时 inAny 满足，规则执行。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Home_5G", isAuthorized: true }, { nowMs: t0 + 100 });
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 + 200 });
    assert.deepEqual(commands, [{ kind: "setLightPower", entityId: "light.home", isOn: false }]);

    // 无权限（权限被系统吊销）：读数「无法知晓」，条件按 not-authorized 判定不满足。
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 + 300 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: false }, { nowMs: t0 + 400 });
    assert.equal(engine.snapshot.wifiSSID, null);
    assert.equal(engine.snapshot.wifiAuthorized, false);
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 + 61_200 });
    assert.equal(commands.length, 1, "not-authorized must keep Wi-Fi-gated rules from firing");

    // 未连接（已授权但无 WLAN 关联）：条件按 no-network 判定不满足。
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 + 61_300 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, { nowMs: t0 + 61_400 });
    assert.equal(engine.snapshot.wifiSSID, null);
    assert.equal(engine.snapshot.wifiAuthorized, true);
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 + 122_400 });
    assert.equal(commands.length, 1, "no-network keeps Wi-Fi-gated rules from firing");

    // 恢复连接后规则重新可用（cooldown 未被失败条件消耗）。
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 + 122_500 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Home_5G", isAuthorized: true }, { nowMs: t0 + 122_600 });
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 + 122_700 });
    assert.deepEqual(
      commands.filter((c) => c.kind === "setLightPower"),
      [
        { kind: "setLightPower", entityId: "light.home", isOn: false },
        { kind: "setLightPower", entityId: "light.home", isOn: false },
      ],
    );
  });

  it("fires wifiNetworkJoined / wifiNetworkLeft on SSID transitions and refuses transitions with an unknowable side", async () => {
    const light = makeLight("light.desk", true);
    const { host, commands } = trackingHost([light]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "joined-home",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: false },
        triggerOptions: { wifiSSID: "Home_5G" },
      }),
      createAutomationRule({
        id: "left-home",
        trigger: "wifiNetworkLeft",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: false },
        triggerOptions: { wifiSSID: "Home_5G" },
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 10, 0, 0).getTime();
    // 首次确定读数（未连接）只建立基线。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, { nowMs: t0 });
    assert.equal(commands.length, 0);

    // null → Home_5G：joined 触发。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Home_5G", isAuthorized: true }, { nowMs: t0 + 100 });
    assert.deepEqual(commands, [{ kind: "setLightPower", entityId: "light.desk", isOn: false }]);

    // Home_5G → Office：left(Home_5G) 触发，joined(Home_5G) 不触发。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Office", isAuthorized: true }, { nowMs: t0 + 60_100 });
    assert.equal(commands.length, 2);

    // Office → null（确定断开）：left 目标是 Home_5G，不是刚离开的网络，不触发。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, { nowMs: t0 + 120_100 });
    assert.equal(commands.length, 2);

    // 无权限：引擎更新为「无法知晓」，但不得制造假的网络转换。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: false }, { nowMs: t0 + 180_100 });
    assert.equal(engine.snapshot.wifiSSID, null);
    assert.equal(engine.snapshot.wifiAuthorized, false);
    assert.equal(commands.length, 2);

    // 权限恢复并连上 Home_5G：macOS 语义要求两侧读数都可信才产生转换，
    // 因此不可信侧之后的首次连接不触发 joined。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Home_5G", isAuthorized: true }, { nowMs: t0 + 240_100 });
    assert.equal(engine.snapshot.wifiSSID, "Home_5G");
    assert.equal(engine.snapshot.wifiAuthorized, true);
    assert.equal(commands.length, 2);

    // 之后正常的离开/回来仍触发。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Office", isAuthorized: true }, { nowMs: t0 + 300_100 });
    assert.equal(commands.length, 3, "left(Home_5G) fires again once both sides are trusted");
  });
});

describe("Issue #9: lock-time Wi-Fi snapshot for the debounced flush", () => {
  function buildInterleavedEngine(): { engine: AutomationEngine; host: AutomationExecutionHost; commands: DeviceCommand[] } {
    const lightA = makeLight("light.a", true);
    const lightB = makeLight("light.b", true);
    const { host, commands } = trackingHost([lightA, lightB]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "lock-a",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.a"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "lock-b",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.b"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_B"] }),
      }),
    ]);
    return { engine, host, commands };
  }

  it("judges the flush on the network present at lock time even after switching during the debounce", async () => {
    const { engine, host, commands } = buildInterleavedEngine();
    const t0 = new Date(2026, 10, 16, 22, 0, 0).getTime();
    // 解锁基线 + 锁上时在 Net_A。
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 - 1000 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Net_A", isAuthorized: true }, { nowMs: t0 - 500 });
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 });

    // 防抖窗口内切到 Net_B（该次派发自带的 flush 因未到 2 秒而不结算）。
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Net_B", isAuthorized: true }, { nowMs: t0 + 1500 });
    assert.equal(engine.snapshot.wifiSSID, "Net_B");

    // 2 秒后任意事件结算锁屏：规则必须按锁屏时刻的 Net_A 判定。
    await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: t0 + 2100 });
    assert.deepEqual(
      commands.filter((c) => c.kind === "setLightPower"),
      [{ kind: "setLightPower", entityId: "light.a", isOn: false }],
    );
  });

  it("falls back to the current reading once the lock-time snapshot exceeds the 120s freshness window", async () => {
    const { engine, host, commands } = buildInterleavedEngine();
    const t0 = new Date(2026, 10, 16, 23, 0, 0).getTime();
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 - 1000 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Net_A", isAuthorized: true }, { nowMs: t0 - 500 });
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: true }, { nowMs: t0 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Net_B", isAuthorized: true }, { nowMs: t0 + 1500 });

    // 挂起很久后才收到下一条事件：快照过期，回退当前读数 Net_B。
    await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: t0 + AUTOMATION_WIFI_SNAPSHOT_MAX_AGE_MS + 1000 });
    assert.deepEqual(
      commands.filter((c) => c.kind === "setLightPower"),
      [{ kind: "setLightPower", entityId: "light.b", isOn: false }],
    );
  });

  it("treats a snapshot inside 120s as fresh, including clock rollbacks", () => {
    const snapshot = { ssid: "Net_A", isAuthorized: true, capturedAtMs: 1000 };
    assert.equal(isAutomationWifiSnapshotFresh(snapshot, 1000 + AUTOMATION_WIFI_SNAPSHOT_MAX_AGE_MS), true);
    assert.equal(isAutomationWifiSnapshotFresh(snapshot, 1000 + AUTOMATION_WIFI_SNAPSHOT_MAX_AGE_MS + 1), false);
    // 时钟回拨仍视为新鲜（与 macOS `timeIntervalSince` 语义一致）。
    assert.equal(isAutomationWifiSnapshotFresh(snapshot, 900), true);
  });
});

describe("Windows Wi-Fi poll wiring (tick → wifiChanged dispatch)", () => {
  let dom: Window;

  function miniHost(devices: SmartDevice[] = [makeLight("light.desk", true)]): MenuMijiaWindowsApp {
    return {
      devices,
      scenes: [],
      settings: { connectionMode: "demo", hasCompletedOnboarding: true },
      queueBackgroundRender() {},
      render() {},
      applyCommand: async () => true,
      sourceRevision: 0,
    } as unknown as MenuMijiaWindowsApp;
  }

  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    installCssEscape();
  });

  afterEach(async () => {
    await closeTestWindow(dom);
  });

  it("dispatches wifiChanged on SSID change, skips unchanged and unknown probes, and guides on missing permission", async () => {
    const host = miniHost();
    const center = getHostActivityCenter(host);
    const sent: DeviceCommand[] = [];
    host.applyCommand = async (cmd) => {
      sent.push(cmd);
      return true;
    };
    center.automationEngine.store.save([
      createAutomationRule({
        id: "join-any",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: false },
      }),
    ]);

    let wifiResponse: WindowsWifiProbeResult | Error = { state: "connected", ssid: "Home_5G" };
    let probeCalls = 0;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd !== "wifi_current") return undefined;
          probeCalls += 1;
          if (wifiResponse instanceof Error) throw wifiResponse;
          return wifiResponse;
        },
      },
    });

    const t0 = 1_800_000_000_000;
    tickSafetyHealthAndAutomation(host, t0);
    await setImmediate();
    await setImmediate();
    assert.equal(probeCalls, 1);
    assert.deepEqual(
      sent,
      [{ kind: "setLightPower", entityId: "light.desk", isOn: false }],
      "first definite reading joins Home_5G and fires the joined rule",
    );
    assert.equal(center.lastWifiProbeState, "connected");

    // 未到 10 秒节流间隔：不探针、不派发。
    tickSafetyHealthAndAutomation(host, t0 + 5_000);
    await setImmediate();
    await setImmediate();
    assert.equal(probeCalls, 1);
    assert.equal(sent.length, 1);

    // 读数未变化：探针但不派发。
    tickSafetyHealthAndAutomation(host, t0 + 11_000);
    await setImmediate();
    await setImmediate();
    assert.equal(probeCalls, 2);
    assert.equal(sent.length, 1);

    // 切换网络：派发 wifiChanged，joined 规则对新 SSID 再触发。
    wifiResponse = { state: "connected", ssid: "Office" };
    tickSafetyHealthAndAutomation(host, t0 + 22_000);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 2);

    // 探针失败：读数按「无法知晓」派发（SSID 置空 + 不可信，引擎失_close），
    // 但信任门会拦下假的 joined/left 转换，不触发规则。
    wifiResponse = new Error("wlan svc down");
    tickSafetyHealthAndAutomation(host, t0 + 33_000);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 2);
    assert.equal(center.lastWifiProbeState, "unknown");
    assert.equal(center.automationEngine.snapshot.wifiSSID, null);
    assert.equal(center.automationEngine.snapshot.wifiAuthorized, false);

    // 连续无权限读数与上次「无法知晓」一致：不重复派发。
    wifiResponse = { state: "noPermission" };
    tickSafetyHealthAndAutomation(host, t0 + 44_000);
    await setImmediate();
    await setImmediate();
    assert.equal(center.lastWifiProbeState, "noPermission");
    assert.equal(sent.length, 2);

    // 权限恢复后连上网络：读数变化会派发（上下文刷新），但不可信侧之后的
    // 首次连接按 macOS 语义不触发 joined。
    wifiResponse = { state: "connected", ssid: "Office" };
    tickSafetyHealthAndAutomation(host, t0 + 55_000);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 2);
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Office");
    assert.equal(center.automationEngine.snapshot.wifiAuthorized, true);
  });

  it("takes a fresh Wi-Fi sample when the screen locks so the debounced flush judges on the live network", async () => {
    const host = miniHost([makeLight("light.a", true), makeLight("light.b", true)]);
    const center = getHostActivityCenter(host);
    const sent: DeviceCommand[] = [];
    host.applyCommand = async (cmd) => {
      sent.push(cmd);
      return true;
    };
    center.automationEngine.store.save([
      createAutomationRule({
        id: "lock-a",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.a"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "lock-b",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.b"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_B"] }),
      }),
    ]);

    // 轮询只能看到 Net_A；真实网络在两次 Wi-Fi 轮询之间切到 Net_B，
    // 锁屏瞬间的实时探针必须把 B 交给锁屏快照。
    let wifiResponse: WindowsWifiProbeResult = { state: "connected", ssid: "Net_A" };
    let locked = false;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "wifi_current") return wifiResponse;
          if (cmd === "is_workstation_locked") return locked as unknown;
          return undefined;
        },
      },
    });

    const t0 = 1_800_000_000_000;
    tickSafetyHealthAndAutomation(host, t0);
    await setImmediate();
    await setImmediate();
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Net_A");

    wifiResponse = { state: "connected", ssid: "Net_B" };
    locked = true;
    tickSafetyHealthAndAutomation(host, t0 + 2000);
    await setImmediate();
    await setImmediate();
    await setImmediate();
    // 锁屏事件本身已经把实时读数带进上下文与锁屏快照。
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Net_B");

    // 2 秒防抖后结算：按锁屏时刻的 Net_B 判定，而不是轮询缓存的 Net_A。
    tickSafetyHealthAndAutomation(host, t0 + 4100);
    await setImmediate();
    await setImmediate();
    assert.deepEqual(
      sent.filter((c) => c.kind === "setLightPower"),
      [{ kind: "setLightPower", entityId: "light.b", isOn: false }],
    );
  });

  it("never probes Wi-Fi without a Tauri host (happy-dom without __TAURI_INTERNALS__)", () => {
    const host = miniHost();
    const center = getHostActivityCenter(host);
    Reflect.deleteProperty(window, "__TAURI_INTERNALS__");
    const before = center.lastWifiPollAtMs;
    tickSafetyHealthAndAutomation(host, 1_800_000_000_000);
    assert.equal(center.lastWifiPollAtMs, before, "no probe state touched without invoke");
    assert.equal(center.lastWifiProbeState, null);
  });
});
