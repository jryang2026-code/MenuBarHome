import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  AUTOMATION_WIFI_SNAPSHOT_MAX_AGE_MS,
  AutomationEngine,
  AutomationTriggerDeduper,
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

  it("judges left transitions on the network just left and joined transitions on the new network (macOS matrix)", async () => {
    // 转换矩阵：inAny / notIn 两种条件 × joined / left 两种触发器 ×
    // A→B、A→null、null→A 三种转换，结果逐项对照 macOS handle(context:)：
    // left 用刚离开的 SSID，joined 用新 SSID。
    const lights = {
      leftInAny: makeLight("light.left-in-any", true),
      leftNotIn: makeLight("light.left-not-in", true),
      joinInAny: makeLight("light.join-in-any", true),
      joinNotIn: makeLight("light.join-not-in", true),
    };
    const { host, commands } = trackingHost(Object.values(lights));
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "left-in-any",
        trigger: "wifiNetworkLeft",
        action: { kind: "devices", deviceIds: ["light.left-in-any"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "left-not-in",
        trigger: "wifiNetworkLeft",
        action: { kind: "devices", deviceIds: ["light.left-not-in"], isOn: false },
        conditions: createAutomationConditions({ kind: "notIn", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "join-in-any",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.join-in-any"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_B"] }),
      }),
      createAutomationRule({
        id: "join-not-in",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.join-not-in"], isOn: false },
        conditions: createAutomationConditions({ kind: "notIn", ssids: ["Net_B"] }),
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 11, 0, 0).getTime();
    const ssid = (ssid: string | null) => ({ kind: "wifiChanged" as const, ssid, isAuthorized: true });

    // 先建立可信的「未连接」基线（默认快照不可信，首轮不触发——安全语义）。
    await engine.dispatchEvent(host, ssid(null), { nowMs: t0 });
    assert.equal(commands.length, 0);

    // null → Net_A：joined 按新网络 Net_A 判定。inAny[Net_B] 不满足；
    // notIn[Net_B] 满足 → join-not-in 触发。
    await engine.dispatchEvent(host, ssid("Net_A"), { nowMs: t0 + 61_000 });
    assert.deepEqual(commands, [{ kind: "setLightPower", entityId: "light.join-not-in", isOn: false }]);

    // Net_A → Net_B：left 按刚离开的 Net_A 判定（inAny[Net_A] 满足 → 触发；
    // notIn[Net_A] 排除 → 不触发，修复前两者相反）；joined 按新网络 Net_B 判定
    // （inAny[Net_B] 满足 → 触发；notIn[Net_B] 排除 → 不触发）。
    await engine.dispatchEvent(host, ssid("Net_B"), { nowMs: t0 + 122_000 });
    assert.deepEqual(
      commands.map((c) => c.entityId),
      ["light.join-not-in", "light.left-in-any", "light.join-in-any"],
    );

    // Net_B → null：left 按刚离开的 Net_B 判定（inAny[Net_A] 不满足；notIn[Net_A]
    // 满足 → left-not-in 触发）；joined 不进入（新网络为 null）。
    await engine.dispatchEvent(host, ssid(null), { nowMs: t0 + 183_000 });
    assert.deepEqual(
      commands.map((c) => c.entityId),
      ["light.join-not-in", "light.left-in-any", "light.join-in-any", "light.left-not-in"],
    );
  });

  it("persists joined/left dedupe stamps without any observed SSID and purges legacy keys", async () => {
    const light = makeLight("light.desk", true);
    const { host } = trackingHost([light]);
    const kv = new MemoryKV();
    const engine = new AutomationEngine(kv);
    engine.store.save([
      createAutomationRule({
        id: "join-any",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: false },
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 12, 0, 0).getTime();
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: null, isAuthorized: true }, { nowMs: t0 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Private_Visited_Network", isAuthorized: true }, { nowMs: t0 + 100 });
    const persisted = kv.getItem(AutomationTriggerDeduper.storageKey) ?? "";
    assert.ok(persisted.includes("wifiJoined:join-any"), "trigger + rule id remain the dedupe key");
    assert.equal(persisted.includes("Private_Visited_Network"), false, "observed SSIDs must never be persisted");
    assert.equal(persisted.includes("Net_A"), false);

    // 旧格式键（含 SSID）在读取时清除并回写，不留在磁盘上；其他键保留。
    const seeded = new MemoryKV();
    seeded.setItem(
      AutomationTriggerDeduper.storageKey,
      JSON.stringify({
        "wifiJoined:join-any:Private_Visited_Network": 1000,
        "wifiLeft:r1:Net_A": 2000,
        "lateNight:r2:2026-11-17": 3000,
        "sched:r3:2026-11-17:08:15": 4000,
      }),
    );
    const deduper = new AutomationTriggerDeduper(seeded);
    assert.equal(deduper.lastFireAtMs("lateNight:r2:2026-11-17"), 3_000_000, "non-Wi-Fi keys survive");
    assert.equal(deduper.lastFireAtMs("sched:r3:2026-11-17:08:15"), 4_000_000);
    assert.equal(deduper.lastFireAtMs("wifiJoined:join-any:Private_Visited_Network"), null, "legacy key no longer readable");
    assert.equal(deduper.lastFireAtMs("wifiLeft:r1:Net_A"), null);
    const afterPurge = JSON.parse(seeded.getItem(AutomationTriggerDeduper.storageKey) ?? "{}") as Record<string, unknown>;
    assert.deepEqual(Object.keys(afterPurge).sort(), ["lateNight:r2:2026-11-17", "sched:r3:2026-11-17:08:15"]);
    assert.equal(
      (seeded.getItem(AutomationTriggerDeduper.storageKey) ?? "").includes("Private_Visited_Network"),
      false,
      "legacy SSID keys are removed from storage, not just ignored",
    );
  });

  it("shares one per-rule cooldown for joined/left transitions like macOS (A→B→A within the cooldown is suppressed)", async () => {
    const light = makeLight("light.desk", true);
    const { host, commands } = trackingHost([light]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "join-any",
        trigger: "wifiNetworkJoined",
        action: { kind: "devices", deviceIds: ["light.desk"], isOn: false },
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 13, 0, 0).getTime();
    const ssid = (ssid: string | null) => ({ kind: "wifiChanged" as const, ssid, isAuthorized: true });
    await engine.dispatchEvent(host, ssid(null), { nowMs: t0 });
    await engine.dispatchEvent(host, ssid("Net_A"), { nowMs: t0 + 100 });
    assert.equal(commands.length, 1);
    // A → B → A 快速切换：同一规则在同一冷却窗口内只触发一次（macOS
    // transitionEvent 的键不含网络标识，冷却跨网络共享）。
    await engine.dispatchEvent(host, ssid("Net_B"), { nowMs: t0 + 200 });
    await engine.dispatchEvent(host, ssid("Net_A"), { nowMs: t0 + 300 });
    assert.equal(commands.length, 1);
    // 冷却过后恢复触发。
    await engine.dispatchEvent(host, ssid("Net_B"), { nowMs: t0 + 61_100 });
    assert.equal(commands.length, 2);
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

  it("prefers the live reading carried on the lock event over the polling context (race-free capture)", async () => {
    const lightA = makeLight("light.a", true);
    const lightB = makeLight("light.b", true);
    const { host, commands } = trackingHost([lightA, lightB]);
    const engine = new AutomationEngine(new MemoryKV());
    engine.store.save([
      createAutomationRule({
        id: "away-a",
        trigger: "away",
        action: { kind: "devices", deviceIds: ["light.a"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "away-b",
        trigger: "away",
        action: { kind: "devices", deviceIds: ["light.b"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_B"] }),
      }),
      createAutomationRule({
        id: "flush-b",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.b"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_B"] }),
      }),
    ]);

    const t0 = new Date(2026, 10, 16, 21, 0, 0).getTime();
    await engine.dispatchEvent(host, { kind: "lockChanged", isLocked: false }, { nowMs: t0 - 1000 });
    await engine.dispatchEvent(host, { kind: "wifiChanged", ssid: "Net_A", isAuthorized: true }, { nowMs: t0 - 500 });

    // 锁屏事件自带实时读数 Net_B（锁屏翻转时的探针）：锁屏快照与 away 判定都用它，
    // 不依赖可能被并发轮询写入的共享上下文；上下文本身保持轮询值。
    await engine.dispatchEvent(
      host,
      { kind: "lockChanged", isLocked: true, wifi: { ssid: "Net_B", isAuthorized: true } },
      { nowMs: t0 },
    );
    assert.equal(engine.snapshot.wifiSSID, "Net_A");
    assert.deepEqual(
      commands.filter((c) => c.kind === "setLightPower"),
      [{ kind: "setLightPower", entityId: "light.b", isOn: false }],
      "away rules judge on the lock-time reading, not the possibly-poisoned context",
    );

    // 防抖后的 flush 同样按事件读数判定。
    await engine.dispatchEvent(host, { kind: "tick" }, { nowMs: t0 + 2100 });
    assert.deepEqual(
      commands.filter((c) => c.kind === "setLightPower"),
      [
        { kind: "setLightPower", entityId: "light.b", isOn: false },
        { kind: "setLightPower", entityId: "light.b", isOn: false },
      ],
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
    // 首次观测只建立基线：默认快照「无法知晓」，join 不触发设备控制。
    assert.equal(sent.length, 0);
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Home_5G");
    assert.equal(center.automationEngine.snapshot.wifiAuthorized, true);
    assert.equal(center.lastWifiProbeState, "connected");

    // 未到 10 秒节流间隔：不探针、不派发。
    tickSafetyHealthAndAutomation(host, t0 + 5_000);
    await setImmediate();
    await setImmediate();
    assert.equal(probeCalls, 1);
    assert.equal(sent.length, 0);

    // 读数未变化：探针但不派发。
    tickSafetyHealthAndAutomation(host, t0 + 11_000);
    await setImmediate();
    await setImmediate();
    assert.equal(probeCalls, 2);
    assert.equal(sent.length, 0);

    // 切换网络：两侧读数都可信，joined 规则触发。
    wifiResponse = { state: "connected", ssid: "Office" };
    tickSafetyHealthAndAutomation(host, t0 + 22_000);
    await setImmediate();
    await setImmediate();
    assert.deepEqual(
      sent,
      [{ kind: "setLightPower", entityId: "light.desk", isOn: false }],
    );

    // 探针失败：读数按「无法知晓」派发（SSID 置空 + 不可信，引擎失_close），
    // 但信任门会拦下假的 joined/left 转换，不触发规则。
    wifiResponse = new Error("wlan svc down");
    tickSafetyHealthAndAutomation(host, t0 + 33_000);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 1);
    assert.equal(center.lastWifiProbeState, "unknown");
    assert.equal(center.automationEngine.snapshot.wifiSSID, null);
    assert.equal(center.automationEngine.snapshot.wifiAuthorized, false);

    // 连续无权限读数与上次「无法知晓」一致：不重复派发。
    wifiResponse = { state: "noPermission" };
    tickSafetyHealthAndAutomation(host, t0 + 44_000);
    await setImmediate();
    await setImmediate();
    assert.equal(center.lastWifiProbeState, "noPermission");
    assert.equal(sent.length, 1);

    // 权限恢复后连上网络：读数变化会派发（上下文刷新），但不可信侧之后的
    // 首次连接按 macOS 语义不触发 joined。
    wifiResponse = { state: "connected", ssid: "Office" };
    tickSafetyHealthAndAutomation(host, t0 + 55_000);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 1);
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

  it("drops a superseded lock flip when a newer sample already dispatched the opposite transition", async () => {
    const host = miniHost([makeLight("light.a", true)]);
    const center = getHostActivityCenter(host);
    const sent: DeviceCommand[] = [];
    host.applyCommand = async (cmd) => {
      sent.push(cmd);
      return true;
    };
    center.automationEngine.store.save([
      createAutomationRule({
        id: "away-any",
        trigger: "away",
        action: { kind: "devices", deviceIds: ["light.a"], isOn: false },
      }),
    ]);

    const lockedQueue: boolean[] = [];
    let wifiProbeCalls = 0;
    // 闭包里赋值的函数句柄用对象属性承载，避免 TS 把流程收窄成 never。
    const probeGate: { release: (() => void) | null } = { release: null };
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "is_workstation_locked") {
            if (lockedQueue.length === 0) return false as unknown;
            return lockedQueue.shift()! as unknown;
          }
          if (cmd === "wifi_current") {
            wifiProbeCalls += 1;
            // 第一次是常规 10 秒轮询，立即返回并建立基线；第二次是锁屏翻转的
            // 实时探针，用门控挂起，模拟探针与规则执行耗时。
            if (wifiProbeCalls === 1) return { state: "connected", ssid: "Net_A" };
            await new Promise<void>((resolve) => { probeGate.release = resolve; });
            return { state: "connected", ssid: "Net_A" };
          }
          return undefined;
        },
      },
    });

    const t0 = 1_800_000_000_000;
    // 第一轮采样：解锁基线；Wi-Fi 轮询建立 (Net_A, true) 基线。
    lockedQueue.push(false);
    tickSafetyHealthAndAutomation(host, t0);
    await setImmediate();
    await setImmediate();
    assert.equal(center.lastSampledLockState, false);
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Net_A");

    // 第二轮采样：锁上。回调卡在门控的 Wi-Fi 探针上，lastSampled 已写成 true。
    lockedQueue.push(true);
    tickSafetyHealthAndAutomation(host, t0 + 1_000);
    await setImmediate();
    await setImmediate();
    assert.equal(center.lastSampledLockState, true);
    assert.equal(typeof probeGate.release, "function");

    // 等待期间用户解锁：第三轮采样 false，按最新状态派发解锁事件。
    lockedQueue.push(false);
    tickSafetyHealthAndAutomation(host, t0 + 2_000);
    await setImmediate();
    await setImmediate();
    assert.equal(center.lastSampledLockState, false);

    // 放行被门控的探针：旧回调恢复后不得再派发过时的 lockChanged(true)。
    probeGate.release?.();
    await setImmediate();
    await setImmediate();
    await setImmediate();
    assert.equal(center.automationEngine.snapshot.isLocked, false, "engine must follow the newest sample, not the stale flip");
    assert.equal(sent.length, 0, "no away rule may fire from a superseded lock event");
  });

  it("fails closed when the lock-time Wi-Fi probe rejects instead of carrying the stale authorized SSID", async () => {
    const host = miniHost([makeLight("light.home", true)]);
    const center = getHostActivityCenter(host);
    const sent: DeviceCommand[] = [];
    host.applyCommand = async (cmd) => {
      sent.push(cmd);
      return true;
    };
    center.automationEngine.store.save([
      createAutomationRule({
        id: "away-in",
        trigger: "away",
        action: { kind: "devices", deviceIds: ["light.home"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
      createAutomationRule({
        id: "lock-in",
        trigger: "screenLocked",
        action: { kind: "devices", deviceIds: ["light.home"], isOn: false },
        conditions: createAutomationConditions({ kind: "inAny", ssids: ["Net_A"] }),
      }),
    ]);

    // 轮询先看到 Net_A；锁屏瞬间探针 IPC 失败，必须按「无法知晓」失_close。
    let wifiResponse: WindowsWifiProbeResult | Error = { state: "connected", ssid: "Net_A" };
    let locked = false;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "wifi_current") {
            if (wifiResponse instanceof Error) throw wifiResponse;
            return wifiResponse;
          }
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

    wifiResponse = new Error("wlan svc down at lock");
    locked = true;
    tickSafetyHealthAndAutomation(host, t0 + 1_000);
    await setImmediate();
    await setImmediate();
    await setImmediate();
    // 不可信读数已随 wifiChanged 派发进上下文，并随 lockChanged 进入锁屏快照。
    assert.equal(center.automationEngine.snapshot.wifiSSID, null);
    assert.equal(center.automationEngine.snapshot.wifiAuthorized, false);

    // 防抖后结算：快照不可信，Wi-Fi 门控规则不触发。
    tickSafetyHealthAndAutomation(host, t0 + 2_100);
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 0);
  });

  it("discards a periodic probe superseded by the lock-time probe instead of overwriting the newer reading", async () => {
    const host = miniHost([makeLight("light.desk", true)]);
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

    // 周期轮询先发起（读到 Net_A）但被门控挂起；锁屏探针后发起（读到 Net_B）。
    let locked = false;
    let wifiProbeCalls = 0;
    const probeGate: { release: (() => void) | null } = { release: null };
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "is_workstation_locked") return locked as unknown;
          if (cmd === "wifi_current") {
            wifiProbeCalls += 1;
            if (wifiProbeCalls === 1) {
              await new Promise<void>((resolve) => { probeGate.release = resolve; });
              return { state: "connected", ssid: "Net_A" };
            }
            return { state: "connected", ssid: "Net_B" };
          }
          return undefined;
        },
      },
    });

    const t0 = 1_800_000_000_000;
    tickSafetyHealthAndAutomation(host, t0);
    await setImmediate();
    await setImmediate();
    // 周期探针已发起但尚未返回；锁屏采样建立基线。
    assert.equal(center.wifiProbeSeq, 1);
    assert.equal(center.wifiAppliedSeq, 0);
    assert.equal(center.lastSampledLockState, false);

    // 锁屏翻转：实时探针读到 Net_B 并先行应用。
    locked = true;
    tickSafetyHealthAndAutomation(host, t0 + 1_000);
    await setImmediate();
    await setImmediate();
    await setImmediate();
    assert.equal(center.wifiAppliedSeq, 2);
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Net_B");

    // 后返回的 Net_A 是被超越的旧探针：丢弃，不覆盖 Net_B、不制造假转换。
    probeGate.release?.();
    await setImmediate();
    await setImmediate();
    await setImmediate();
    assert.equal(center.wifiAppliedSeq, 2, "superseded probe result is discarded");
    assert.equal(center.automationEngine.snapshot.wifiSSID, "Net_B");
    assert.equal(center.lastWifiReading?.ssid, "Net_B");
    assert.equal(sent.length, 0, "no spurious joined/left transition from the stale probe");
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
