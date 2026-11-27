import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import {
  AutomationContextStack,
  AutomationEngine,
  AutomationRuleStore,
  createAutomationRule,
  pairedContextTrigger,
  type AutomationContextSnapshot,
  type AutomationExecutionHost,
  type AutomationTrigger,
} from "../src/core/automationEngine.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import type { KeyValueStorageLike } from "../src/core/safetyAndHealth.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { closeTestWindow, element, installCssEscape, mountTestWindow } from "./uiHarness.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const GOLDEN_PATH = path.resolve(__dirname, "../../Tests/Fixtures/context_stack_golden.json");

class MemoryStorage implements KeyValueStorageLike {
  private readonly map = new Map<string, string>();
  getItem(key: string): string | null { return this.map.get(key) ?? null; }
  setItem(key: string, value: string): void { this.map.set(key, value); }
  removeItem(key: string): void { this.map.delete(key); }
}

function makeLight(id: string, isOn: boolean, name = "Desk Lamp"): SmartDevice {
  return {
    id, name, roomId: "room-study", roomName: "书房", model: "yeelink.light.lamp1", isOnline: true,
    kind: {
      kind: "light", entityId: `light.${id}`, isOn, brightnessPercent: 100,
      colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [], powerWritable: true,
    },
  };
}

function makeHighRiskPlug(id: string, isOn: boolean, name = "电暖器插座"): SmartDevice {
  return {
    id, name, roomId: "room-living", roomName: "客厅", model: "chuangmi.plug.m3", isOnline: true,
    kind: { kind: "plug", switchEntityId: `switch.${id}`, isOn, powerWatts: isOn ? 1200 : 0, childLockEntityId: null, isChildLocked: false, powerWritable: true },
  };
}

function makeCover(id: string, subtype: "garage-door" | "curtain", positionPercent: number, name: string): SmartDevice {
  return {
    id, name, roomId: "room-garage", roomName: "车库", model: `test.cover.${subtype}`, isOnline: true,
    kind: {
      kind: "cover", entityId: `cover.${id}`, subtype, positionPercent,
      positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause",
      batteryPercent: null, faultText: null, motion: "stopped",
    },
  };
}

const snap = (deviceId: string, baseline: boolean, applied: boolean): AutomationContextSnapshot => ({
  deviceId, baseline: { field: "power", boolValue: baseline }, applied: { field: "power", boolValue: applied },
});

function makeHost(devices: SmartDevice[], onCommand?: (cmd: DeviceCommand) => boolean) {
  const commands: DeviceCommand[] = [];
  const host: AutomationExecutionHost = {
    devices, scenes: [], sourceRevision: 1, settings: { connectionMode: "demo", interfaceLanguage: "zh-Hans" },
    async applyCommand(cmd: DeviceCommand): Promise<boolean> {
      commands.push(cmd);
      if (onCommand && !onCommand(cmd)) return false;
      if (cmd.kind === "setLightPower") {
        const dev = host.devices.find((d) => d.kind.kind === "light" && d.kind.entityId === cmd.entityId);
        if (dev?.kind.kind === "light") dev.kind = { ...dev.kind, isOn: cmd.isOn };
      } else if (cmd.kind === "setSwitch") {
        const dev = host.devices.find((d) => d.kind.kind === "plug" && d.kind.switchEntityId === cmd.entityId);
        if (dev?.kind.kind === "plug") dev.kind = { ...dev.kind, isOn: cmd.isOn };
      } else if (cmd.kind === "setSelectOption") {
        const dev = host.devices.find((d) => d.kind.kind === "cover" && d.kind.entityId === cmd.entityId);
        if (dev?.kind.kind === "cover") {
          dev.kind = { ...dev.kind, positionPercent: cmd.option === dev.kind.openDescription ? 100 : 0 };
        }
      }
      return true;
    },
  };
  return { host, commands };
}

describe("AutomationContextStack golden fixture & core parity", () => {
  it("executes shared Tests/Fixtures/context_stack_golden.json identically to macOS", () => {
    interface GoldenEntry { device: string; before: boolean; applied: boolean; }
    interface GoldenCase { name: string; enter: GoldenEntry | GoldenEntry[]; exit: { live: boolean; restored: boolean | null }; }
    const golden = JSON.parse(fs.readFileSync(GOLDEN_PATH, "utf8")) as { version: number; maxAgeHours: number; cases: GoldenCase[] };
    assert.equal(golden.version, 1);
    assert.equal(AutomationContextStack.maximumAgeMs, golden.maxAgeHours * 60 * 60 * 1000);

    for (const tc of golden.cases) {
      const stack = new AutomationContextStack(null, 100_000);
      const entries = Array.isArray(tc.enter) ? tc.enter : [tc.enter];
      entries.forEach((e, idx) => stack.push(`rule-${idx}`, [snap(e.device, e.before, e.applied)], 100_000 + idx * 1000));
      const last = entries[entries.length - 1]!;
      const intents = stack.pop(`rule-${entries.length - 1}`, { [last.device]: { field: "power", boolValue: tc.exit.live } }, 100_000 + entries.length * 1000);
      assert.deepEqual(
        intents,
        tc.exit.restored === null ? [] : [{ targetId: last.device, operation: { kind: "power", isOn: tc.exit.restored } }],
        tc.name,
      );
    }
  });

  it("enforces 12h max age, 32-frame cap, persistence, failed retry, and partial confirmation", () => {
    const storage = new MemoryStorage();
    const start = 1_700_000_000_000;

    new AutomationContextStack(storage, start).push("r1", [snap("lamp", true, false)], start);
    assert.equal(new AutomationContextStack(storage, start + 60_000).count, 1);
    assert.equal(new AutomationContextStack(storage, start + AutomationContextStack.maximumAgeMs + 1).isEmpty, true);

    const stack2 = new AutomationContextStack(new MemoryStorage(), start);
    stack2.push("r2", [snap("lamp", true, false), snap("fan", false, true)], start);
    const plan = stack2.prepareRestore(stack2.allFrames[0]!, {
      lamp: { field: "power", boolValue: false },
      fan: { field: "power", boolValue: true },
    }, start + 1000);
    assert.ok(plan);
    stack2.commitRestore(plan, new Set());
    assert.equal(stack2.count, 1);
    stack2.commitRestore(plan, new Set(["lamp"]));
    assert.deepEqual(stack2.allFrames[0]!.snapshots.map((s) => s.deviceId), ["fan"]);

    const stack3 = new AutomationContextStack(new MemoryStorage(), start);
    for (let i = 0; i <= AutomationContextStack.maximumFrames; i += 1) {
      stack3.push(`r-${i}`, [snap(`lamp-${i}`, false, true)], start + i * 1000);
    }
    assert.equal(stack3.count, AutomationContextStack.maximumFrames);
    assert.equal(stack3.allFrames[0]!.snapshots[0]!.deviceId, "lamp-1");
  });
});

describe("AutomationEngine context restore parity", () => {
  it("captures baseline before action, commits only on success, persists across restarts, and dedupes exits", async () => {
    const storage = new MemoryStorage();
    const engine = new AutomationEngine(storage);
    const rule = createAutomationRule({ id: "cam-rule", trigger: "cameraInUse", action: { kind: "devices", deviceIds: ["lamp"], isOn: true }, restoreWhenContextEnds: true });
    assert.equal(rule.restoreTrigger, "cameraNotInUse");
    engine.store.save([rule]);

    const t0 = 1_800_000_000_000;
    const failSetup = makeHost([makeLight("lamp", false)], () => false);
    await engine.dispatchEvent(failSetup.host, { kind: "mediaCaptureChanged", cameraInUse: true }, { nowMs: t0 });
    assert.equal(engine.contextStack.isEmpty, true);

    engine.primeMediaCaptureBaseline(false, false);
    const okSetup = makeHost([makeLight("lamp", false)]);
    await engine.dispatchEvent(okSetup.host, { kind: "mediaCaptureChanged", cameraInUse: true }, { nowMs: t0 + 70_000 });
    assert.deepEqual(okSetup.commands, [{ kind: "setLightPower", entityId: "light.lamp", isOn: true }]);
    assert.equal(engine.contextStack.count, 1);

    const restarted = new AutomationEngine(storage);
    restarted.primeMediaCaptureBaseline(true, false);
    await restarted.dispatchEvent(okSetup.host, { kind: "mediaCaptureChanged", cameraInUse: false }, { nowMs: t0 + 80_000 });
    assert.deepEqual(okSetup.commands[1], { kind: "setLightPower", entityId: "light.lamp", isOn: false });
    assert.equal(restarted.contextStack.isEmpty, true);

    restarted.contextStack.push("cam-rule", [snap("lamp", true, false)], t0 + 80_500);
    assert.equal(await restarted.restoreContextsIfNeeded("cameraNotInUse", okSetup.host, t0 + 81_000), 0);
    assert.equal(okSetup.commands.length, 2);
  });

  it("supports mic, focus, and power paired triggers and lets manual takeover win", async () => {
    const pairs: Array<{
      enter: AutomationTrigger; exit: AutomationTrigger;
      enterEvent: Parameters<AutomationEngine["dispatchEvent"]>[1];
      exitEvent: Parameters<AutomationEngine["dispatchEvent"]>[1];
      prime: (e: AutomationEngine) => void;
    }> = [
      { enter: "microphoneInUse", exit: "microphoneNotInUse", enterEvent: { kind: "mediaCaptureChanged", microphoneInUse: true }, exitEvent: { kind: "mediaCaptureChanged", microphoneInUse: false }, prime: (e) => e.primeMediaCaptureBaseline(false, false) },
      { enter: "focusModeEnabled", exit: "focusModeDisabled", enterEvent: { kind: "focusModeChanged", enabled: true }, exitEvent: { kind: "focusModeChanged", enabled: false }, prime: (e) => e.primeFocusModeBaseline(false) },
      { enter: "powerConnected", exit: "powerDisconnected", enterEvent: { kind: "powerChanged", onExternalPower: true }, exitEvent: { kind: "powerChanged", onExternalPower: false }, prime: (e) => e.primePowerBaseline(false, 80) },
    ];
    for (const pair of pairs) {
      assert.equal(pairedContextTrigger(pair.enter), pair.exit);
      assert.equal(pairedContextTrigger(pair.exit), pair.enter);
      const engine = new AutomationEngine(new MemoryStorage());
      pair.prime(engine);
      engine.store.save([createAutomationRule({ trigger: pair.enter, action: { kind: "devices", deviceIds: ["lamp"], isOn: false }, restoreWhenContextEnds: true })]);
      const { host, commands } = makeHost([makeLight("lamp", true)]);
      await engine.dispatchEvent(host, pair.enterEvent, { nowMs: 1_800_000_000_000 });
      await engine.dispatchEvent(host, pair.exitEvent, { nowMs: 1_800_000_010_000 });
      assert.deepEqual(commands[1], { kind: "setLightPower", entityId: "light.lamp", isOn: true });
    }

    const engine = new AutomationEngine(new MemoryStorage());
    engine.primeFocusModeBaseline(false);
    engine.store.save([createAutomationRule({ trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["lamp"], isOn: false }, restoreWhenContextEnds: true })]);
    const { host, commands } = makeHost([makeLight("lamp", true)]);
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: true }, { nowMs: 1_800_000_000_000 });
    if (host.devices[0]!.kind.kind === "light") host.devices[0]!.kind = { ...host.devices[0]!.kind, isOn: true };
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: false }, { nowMs: 1_800_000_010_000 });
    assert.equal(commands.length, 1);
    assert.equal(engine.contextStack.isEmpty, true);
  });

  it("never turns a high-risk device ON during restore: skips write, shows error banner, and clears frame", async () => {
    const engine = new AutomationEngine(new MemoryStorage());
    engine.primeFocusModeBaseline(false);
    engine.store.save([createAutomationRule({
      id: "heater-rule", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["heater"], isOn: false },
      highRiskApproved: true, restoreWhenContextEnds: true,
    })]);
    const { host, commands } = makeHost([makeHighRiskPlug("heater", true)]);
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: true }, { nowMs: 1_800_000_000_000 });
    assert.equal(commands.length, 1);
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: false }, { nowMs: 1_800_000_010_000 });
    assert.equal(commands.length, 1);
    assert.equal(host.replyBanner?.isError, true);
    assert.match(host.replyBanner?.text ?? "", /跳过 1 台需要确认的高风险设备/);
    assert.doesNotMatch(host.replyBanner?.text ?? "", /需要重新开启/);
    assert.equal(engine.contextStack.isEmpty, true);
  });

  it("blocks garage-door close on restore while still closing safe curtains (#558)", async () => {
    const engine = new AutomationEngine(new MemoryStorage());
    engine.primeFocusModeBaseline(false);
    engine.store.save([createAutomationRule({
      id: "garage-rule", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["garage", "curtain"], isOn: true },
      highRiskApproved: true, restoreWhenContextEnds: true,
    })]);
    const { host, commands } = makeHost([
      makeCover("garage", "garage-door", 0, "车库门"),
      makeCover("curtain", "curtain", 0, "客厅窗帘"),
    ]);
    const t0 = 1_800_000_000_000;
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: true }, { nowMs: t0 });
    assert.deepEqual(commands, [
      { kind: "setSelectOption", entityId: "cover.garage", option: "Open" },
      { kind: "setSelectOption", entityId: "cover.curtain", option: "Open" },
    ]);

    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: false }, { nowMs: t0 + 10_000 });
    assert.deepEqual(commands, [
      { kind: "setSelectOption", entityId: "cover.garage", option: "Open" },
      { kind: "setSelectOption", entityId: "cover.curtain", option: "Open" },
      { kind: "setSelectOption", entityId: "cover.curtain", option: "Close" },
    ]);
    assert.equal(host.replyBanner?.isError, true);
    assert.match(host.replyBanner?.text ?? "", /跳过 1 台需要确认的高风险设备/);
    assert.doesNotMatch(host.replyBanner?.text ?? "", /需要重新开启/);
    assert.equal(engine.contextStack.isEmpty, true);
  });

  it("commits blocked high-risk restores before host.applyCommand so an exception cannot leave them pending (#558)", async () => {
    const storage = new MemoryStorage();
    const engine = new AutomationEngine(storage);
    engine.store.save([createAutomationRule({
      id: "throw-rule", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["heater", "lamp"], isOn: false },
      highRiskApproved: true, restoreWhenContextEnds: true,
    })]);
    const t0 = 1_800_000_000_000;
    engine.contextStack.push("throw-rule", [snap("heater", true, false), snap("lamp", true, false)], t0);
    const { host } = makeHost([makeHighRiskPlug("heater", false), makeLight("lamp", false)], () => {
      throw new Error("transport crashed");
    });

    await assert.rejects(
      engine.restoreContextsIfNeeded("focusModeDisabled", host, t0 + 10_000),
      /transport crashed/,
    );
    // Blocked heater was already committed and persisted before applyCommand threw; only lamp remains.
    assert.equal(engine.contextStack.count, 1);
    assert.deepEqual(engine.contextStack.allFrames[0]!.snapshots.map((s) => s.deviceId), ["lamp"]);
    const persisted = new AutomationContextStack(storage, t0 + 10_000);
    assert.deepEqual(persisted.allFrames[0]!.snapshots.map((s) => s.deviceId), ["lamp"]);
  });

  it("merges skipped high-risk notice and failed safe-device notice in the same restore batch (#558)", async () => {
    const engine = new AutomationEngine(new MemoryStorage());
    engine.primeFocusModeBaseline(false);
    engine.store.save([createAutomationRule({
      id: "merge-rule", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["heater", "lamp"], isOn: false },
      highRiskApproved: true, restoreWhenContextEnds: true,
    })]);
    const { host } = makeHost(
      [makeHighRiskPlug("heater", true), makeLight("lamp", true)],
      (cmd) => !(cmd.kind === "setLightPower" && cmd.isOn),
    );
    const t0 = 1_800_000_000_000;
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: true }, { nowMs: t0 });
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: false }, { nowMs: t0 + 10_000 });

    assert.equal(host.replyBanner?.isError, true);
    assert.match(host.replyBanner?.text ?? "", /1 台需要确认的高风险设备/);
    assert.match(host.replyBanner?.text ?? "", /1 台设备还原失败/);
    assert.deepEqual(engine.contextStack.allFrames[0]!.snapshots.map((s) => s.deviceId), ["lamp"]);
  });

  it("restores a light even when the same frame contains a blocked heater write", async () => {
    const engine = new AutomationEngine(new MemoryStorage());
    engine.primeFocusModeBaseline(false);
    engine.store.save([createAutomationRule({
      trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["heater", "lamp"], isOn: false },
      highRiskApproved: true, restoreWhenContextEnds: true,
    })]);
    const { host, commands } = makeHost([makeHighRiskPlug("heater", true), makeLight("lamp", true)]);
    const entered = 1_800_000_000_000;
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: true }, { nowMs: entered });
    assert.equal(engine.contextStack.count, 1);

    const exited = entered + 10_000;
    await engine.dispatchEvent(host, { kind: "focusModeChanged", enabled: false }, { nowMs: exited });
    assert.deepEqual(commands, [
      { kind: "setSwitch", entityId: "switch.heater", isOn: false },
      { kind: "setLightPower", entityId: "light.lamp", isOn: false },
      { kind: "setLightPower", entityId: "light.lamp", isOn: true },
    ]);
    assert.equal(host.replyBanner?.isError, true);
    assert.equal(engine.contextStack.isEmpty, true);
    assert.equal(await engine.restoreContextsIfNeeded("focusModeDisabled", host, exited + 70_000), 0);
    assert.equal(commands.length, 3);
  });

  it("restores nested frames newest-first (strict LIFO) and retains frames on failed restore for retry", async () => {
    const engine = new AutomationEngine(new MemoryStorage());
    engine.store.save([
      createAutomationRule({ id: "outer", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["lamp"], isOn: false }, restoreWhenContextEnds: true }),
      createAutomationRule({ id: "inner", trigger: "focusModeEnabled", action: { kind: "devices", deviceIds: ["lamp"], isOn: true }, restoreWhenContextEnds: true }),
    ]);
    const t0 = 1_800_000_000_000;
    engine.contextStack.push("outer", [snap("lamp", true, false)], t0);
    engine.contextStack.push("inner", [snap("lamp", false, true)], t0 + 1000);

    const failHost = makeHost([makeLight("lamp", true)], () => false);
    await engine.restoreContextsIfNeeded("focusModeDisabled", failHost.host, t0 + 2000);
    assert.equal(engine.contextStack.count, 2);

    const okHost = makeHost([makeLight("lamp", true)]);
    assert.equal(await engine.restoreContextsIfNeeded("focusModeDisabled", okHost.host, t0 + 70_000), 2);
    assert.deepEqual(okHost.commands, [
      { kind: "setLightPower", entityId: "light.lamp", isOn: false },
      { kind: "setLightPower", entityId: "light.lamp", isOn: true },
    ]);
    assert.equal(engine.contextStack.isEmpty, true);
  });
});

describe("Automation settings UI context restore toggle", () => {
  let dom: Window;
  let restoreCss: () => void;
  beforeEach(() => { dom = mountTestWindow(); restoreCss = installCssEscape(); });
  afterEach(async () => { restoreCss(); await closeTestWindow(dom); });

  it("shows '情境结束后还原' off by default only for paired triggers with devices action and persists toggles", () => {
    const app = new MenuMijiaWindowsApp(element<HTMLElement>("#app"));
    app.devices = [makeLight("lamp-1", false, "台灯")];
    app.activeSheet = "settings";
    app.render();

    assert.equal(document.querySelector("#settings-auto-restore-context"), null);
    const triggerSelect = element<HTMLSelectElement>("#settings-auto-trigger");
    triggerSelect.value = "cameraInUse";
    triggerSelect.dispatchEvent(new Event("change", { bubbles: true }));
    assert.equal(document.querySelector("#settings-auto-restore-context"), null);

    const actionSelect = element<HTMLSelectElement>("#settings-auto-action-kind");
    actionSelect.value = "devices";
    actionSelect.dispatchEvent(new Event("change", { bubbles: true }));
    assert.equal(element<HTMLInputElement>("#settings-auto-restore-context").checked, false);
    assert.match(document.querySelector("#settings-auto-restore-hint")?.textContent ?? "", /摄像头停止使用/);

    const devCheckbox = element<HTMLInputElement>('[data-auto-target-device="lamp-1"]');
    devCheckbox.checked = true;
    devCheckbox.dispatchEvent(new Event("change", { bubbles: true }));
    const restoreCheckbox = element<HTMLInputElement>("#settings-auto-restore-context");
    restoreCheckbox.checked = true;
    restoreCheckbox.dispatchEvent(new Event("change", { bubbles: true }));
    element<HTMLButtonElement>("#btn-add-auto-rule").click();

    const stored = new AutomationRuleStore().load();
    assert.equal(stored.length, 1);
    assert.equal(stored[0]!.restoreWhenContextEnds, true);
    assert.equal(stored[0]!.restoreTrigger, "cameraNotInUse");

    const rowToggle = element<HTMLInputElement>(`[data-auto-rule-restore="${stored[0]!.id}"]`);
    assert.equal(rowToggle.checked, true);
    rowToggle.checked = false;
    rowToggle.dispatchEvent(new Event("change", { bubbles: true }));
    const updated = new AutomationRuleStore().load();
    assert.equal(updated[0]!.restoreWhenContextEnds, undefined);
    assert.equal(updated[0]!.restoreTrigger, undefined);
  });

  it("requires confirmation before enabling context restore on a rule turning off a high-risk device", () => {
    const rule = createAutomationRule({
      id: "heater-off",
      trigger: "focusModeEnabled",
      action: { kind: "devices", deviceIds: ["heater-1"], isOn: false },
    });
    new AutomationRuleStore().save([rule]);

    const app = new MenuMijiaWindowsApp(element<HTMLElement>("#app"));
    app.devices = [makeHighRiskPlug("heater-1", true, "电暖器插座")];
    app.activeSheet = "settings";
    app.render();

    const rowToggle = element<HTMLInputElement>('[data-auto-rule-restore="heater-off"]');
    rowToggle.checked = true;
    rowToggle.dispatchEvent(new Event("change", { bubbles: true }));

    // Must arm confirmation dialog and NOT save restoreWhenContextEnds yet
    assert.ok(document.querySelector("#settings-auto-high-risk-confirm"));
    assert.equal(new AutomationRuleStore().load()[0]!.restoreWhenContextEnds, undefined);

    element<HTMLButtonElement>("#btn-confirm-auto-high-risk").click();
    const confirmed = new AutomationRuleStore().load()[0]!;
    assert.equal(confirmed.restoreWhenContextEnds, true);
    assert.equal(confirmed.restoreTrigger, "focusModeDisabled");
  });
});
