import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  AutomationEngine,
  AutomationRuleStore,
  createAutomationRule,
  type DoorbellCoordinatorScheduler,
} from "../src/core/automationEngine.js";
import { getScopedEnergyHistory } from "../src/core/energyHistory.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  makeMiAccount,
  mergeMiAccountSnapshots,
  type AccountChildSnapshot,
} from "../src/core/miAccountsStore.js";
import type { DeviceCommand, HomeScene, SmartDevice } from "../src/core/models.js";
import {
  SENSOR_ALERT_KINDS,
  SafetyMonitor,
  evaluateSensorAlerts,
  loadSensorAlertPolicy,
} from "../src/core/safetyAndHealth.js";
import {
  resetSharedSensorHistoryStoreForTests,
  sharedSensorHistoryStore,
} from "../src/core/sensorHistory.js";
import {
  dispatchSystemContextEvent,
  getHostActivityCenter,
  ingestHostHASnapshotForDoorbell,
  recordSafetyAlerts,
  tickSafetyHealthAndAutomation,
} from "../src/ui/activityStackView.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  SAFETY_GUARD_PREFS_KEY,
  loadSafetyGuardPrefs,
} from "../src/ui/automationSettingsView.js";
import { syncEnergyHostOnRender } from "../src/ui/energySettingsView.js";
import { syncSensorHistoryHost } from "../src/ui/sensorHistoryView.js";
import { searchSettings } from "../src/ui/settingsSearch.js";

class FakeDoorbellScheduler implements DoorbellCoordinatorScheduler {
  private nextId = 1;
  private readonly tasks = new Map<number, { dueMs: number; fn: () => void }>();
  public nowMs = 1_000_000;

  public setTimeout(handler: () => void, delayMs: number): ReturnType<typeof setTimeout> {
    const id = this.nextId++;
    this.tasks.set(id, { dueMs: this.nowMs + delayMs, fn: handler });
    return id as unknown as ReturnType<typeof setTimeout>;
  }

  public clearTimeout(handle: ReturnType<typeof setTimeout>): void {
    this.tasks.delete(handle as unknown as number);
  }

  public advanceBy(ms: number): void {
    this.nowMs += ms;
    for (const [id, task] of [...this.tasks.entries()]) {
      if (task.dueMs <= this.nowMs) {
        this.tasks.delete(id);
        task.fn();
      }
    }
  }
}

let dom: Window;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Expected element to exist: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function selectValue(selector: string, value: string): void {
  const sel = element<HTMLSelectElement>(selector);
  sel.value = value;
  sel.dispatchEvent(new window.Event("change", { bubbles: true }));
}

function typeInput(selector: string, value: string): void {
  const input = element<HTMLInputElement>(selector);
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function toggleCheck(selector: string, checked: boolean): void {
  const input = element<HTMLInputElement>(selector);
  input.checked = checked;
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

function makeLight(id: string, name: string, isOn = true, roomName = "书房"): SmartDevice {
  return {
    id,
    name,
    roomId: "room_study",
    roomName,
    model: "yeelink.light.lamp4",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: `light.${id}`,
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

function makePlug(overrides: {
  id?: string;
  name?: string;
  roomName?: string;
  isOnline?: boolean;
  isOn?: boolean;
  powerWatts?: number | null;
  energyKwh?: number | null;
} = {}): SmartDevice {
  const id = overrides.id ?? "plug.heater";
  return {
    id,
    name: overrides.name ?? "取暖器插座",
    roomId: "room_living",
    roomName: overrides.roomName ?? "客厅",
    model: "chuangmi.plug.212a01",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn: overrides.isOn ?? true,
      powerWatts: overrides.powerWatts !== undefined ? overrides.powerWatts : 1900,
      energyKwh: overrides.energyKwh !== undefined ? overrides.energyKwh : 5.0,
      childLockEntityId: null,
      isChildLocked: false,
      powerWritable: true,
    },
  };
}

function makeSensor(overrides: {
  id?: string;
  name?: string;
  roomName?: string;
  temperature?: number | null;
  humidity?: number | null;
  battery?: number | null;
} = {}): SmartDevice {
  return {
    id: overrides.id ?? "sensor.th",
    name: overrides.name ?? "主卧温湿度计",
    roomId: "room_bed",
    roomName: overrides.roomName ?? "主卧",
    model: "miaomiaoce.sensor_ht.t2",
    isOnline: true,
    kind: {
      kind: "sensor",
      temperature: overrides.temperature !== undefined ? overrides.temperature : 25.5,
      humidity: overrides.humidity !== undefined ? overrides.humidity : 52,
      battery: overrides.battery !== undefined ? overrides.battery : 88,
    },
  };
}

function makeCamera(id = "ha:cam_front", name = "玄关门铃摄像头"): SmartDevice {
  return {
    id,
    name,
    roomId: "area_entry",
    roomName: "玄关",
    model: "ha.camera.doorbell",
    isOnline: true,
    kind: {
      kind: "camera",
      entityId: "camera.front_door",
      isOn: true,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
      streamEntityId: "camera.front_door",
      snapshotPath: "/api/camera_proxy/camera.front_door",
      powerWritable: true,
    },
  };
}

function createCloudApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  const { connectionMode, ...restSettings } = extraSettings;
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      interfaceLanguage: "zh-Hans",
      selectedHomeId: "home-main",
      ...restSettings,
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  app.settings.connectionMode =
    (connectionMode as "xiaomiCloud" | "homeAssistant" | "demo" | undefined) ?? "xiaomiCloud";
  if (app.settings.connectionMode === "xiaomiCloud" && !extraSettings.miSession) {
    app.settings.miSession = {
      userId: "10086",
      serviceToken: "tok",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      cUserId: "c10086",
      passToken: "pass",
      region: "cn",
    };
  }
  app.cloudValuesStale = false;
  return app;
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  resetSharedSensorHistoryStoreForTests();
  setLanguage("zh-Hans");
});

afterEach(() => {
  resetSharedSensorHistoryStoreForTests();
  closeTestWindow(dom);
});

describe("Wave 4 · PC Context Automation Rule Editor UI & Live Runtime", () => {
  it("creates rules across triggers, Wi-Fi SSID conditions, quickAction/devices/scene actions, persists to AutomationRuleStore, and executes immediately", async () => {
    const app = createCloudApp();
    const studyLight = makeLight("light.study", "书房台灯", true);
    const ambientLight = makeLight("light.ambient", "氛围灯带", false);
    const tempSensor = makeSensor({ id: "sensor.study", name: "书房传感器", temperature: 31 });
    const movieScene: HomeScene = { id: "scene.meeting", name: "会议专注场景", entityId: "scene.meeting_focus" };
    app.devices = [studyLight, ambientLight, tempSensor];
    app.scenes = [movieScene];

    const dispatched: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      dispatched.push(cmd);
      if (cmd.kind === "setLightPower") {
        const target = app.devices.find((d) => d.kind.kind === "light" && d.kind.entityId === cmd.entityId);
        if (target && target.kind.kind === "light") {
          target.kind = { ...target.kind, isOn: cmd.isOn };
        }
      }
      return true;
    };

    app.openSettingsSheet("system");
    assert.ok(document.querySelector("#settings-auto-rules-empty"));

    selectValue("#settings-auto-trigger", "away");
    selectValue("#settings-auto-wifi-kind", "inAny");
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, true);
    assert.ok(document.querySelector("#settings-auto-wifi-hint"));

    typeInput("#settings-auto-wifi-ssids", "Home_5G, Study_WiFi");
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, false);
    await click("#btn-add-auto-rule");

    selectValue("#settings-auto-trigger", "back");
    selectValue("#settings-auto-wifi-kind", "any");
    selectValue("#settings-auto-action-kind", "devices");
    selectValue("#settings-auto-devices-power", "on");
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, true);
    toggleCheck('[data-auto-target-device="light.ambient"]', true);
    assert.equal(element<HTMLButtonElement>("#btn-add-auto-rule").disabled, false);
    await click("#btn-add-auto-rule");

    selectValue("#settings-auto-trigger", "cameraInUse");
    selectValue("#settings-auto-action-kind", "scene");
    selectValue("#settings-auto-scene-id", "scene.meeting");
    await click("#btn-add-auto-rule");

    selectValue("#settings-auto-trigger", "sensorThreshold");
    selectValue("#settings-auto-sensor-device", "sensor.study");
    selectValue("#settings-auto-sensor-metric", "temperature");
    selectValue("#settings-auto-sensor-comparison", "gt");
    typeInput("#settings-auto-sensor-threshold", "29");
    selectValue("#settings-auto-action-kind", "quickAction");
    selectValue("#settings-auto-quick-action", "softNightLight");
    await click("#btn-add-auto-rule");

    const store = new AutomationRuleStore();
    const savedRules = store.load();
    assert.equal(savedRules.length, 4);
    assert.deepEqual(savedRules[0]?.conditions.wifi, { kind: "inAny", ssids: ["Home_5G", "Study_WiFi"] });
    assert.deepEqual(savedRules[1]?.action, { kind: "devices", deviceIds: ["light.ambient"], isOn: true });
    assert.deepEqual(savedRules[2]?.action, { kind: "scene", sceneId: "scene.meeting" });
    assert.equal(savedRules[3]?.triggerOptions.sensorCondition?.threshold, 29);
    assert.equal(document.querySelectorAll("[data-auto-rule-row]").length, 4);

    const t0 = new Date(2026, 10, 14, 14, 0, 0).getTime();
    await dispatchSystemContextEvent(app, { kind: "wifiChanged", ssid: "CoffeeShop" }, t0);
    await dispatchSystemContextEvent(app, { kind: "lockChanged", isLocked: true }, t0 + 100);
    await dispatchSystemContextEvent(app, { kind: "tick" }, t0 + 2500);
    assert.equal(dispatched.filter((c) => c.kind === "setLightPower" && !c.isOn).length, 0);

    await dispatchSystemContextEvent(app, { kind: "lockChanged", isLocked: false }, t0 + 3000);
    assert.ok(dispatched.some((c) => c.kind === "setLightPower" && c.entityId === "light.light.ambient" && c.isOn));

    dispatched.length = 0;
    await dispatchSystemContextEvent(app, { kind: "wifiChanged", ssid: "Home_5G" }, t0 + 70_000);
    await dispatchSystemContextEvent(app, { kind: "lockChanged", isLocked: true }, t0 + 70_100);
    await dispatchSystemContextEvent(app, { kind: "tick" }, t0 + 72_500);
    assert.ok(dispatched.some((c) => c.kind === "setLightPower" && c.entityId === "light.light.study" && !c.isOn));

    dispatched.length = 0;
    await dispatchSystemContextEvent(app, { kind: "mediaCaptureChanged", cameraInUse: true }, t0 + 140_000);
    assert.deepEqual(dispatched, [{ kind: "activateScene", entityId: "scene.meeting_focus" }]);
  });

  it("supports enabling/disabling rules, deleting rules, and dry-running with workstation lock guard & 5m Undo", async () => {
    const app = createCloudApp({ blockControlWhileLocked: true });
    const lamp = makeLight("light.desk", "工作台灯", true);
    app.devices = [lamp];

    let locked = false;
    window.__TAURI_INTERNALS__ = {
      invoke: async <T>(cmd: string): Promise<T> => {
        if (cmd === "is_workstation_locked") return locked as unknown as T;
        return undefined as unknown as T;
      },
    };

    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      if (cmd.kind === "setLightPower") {
        lamp.kind = { ...(lamp.kind as Extract<SmartDevice["kind"], { kind: "light" }>), isOn: cmd.isOn };
      }
      return true;
    };

    app.openSettingsSheet("system");
    selectValue("#settings-auto-trigger", "lateNightUsage");
    selectValue("#settings-auto-latenight-start", "23");
    selectValue("#settings-auto-latenight-end", "5");
    await click("#btn-add-auto-rule");

    const ruleId = new AutomationRuleStore().load()[0]!.id;

    toggleCheck(`[data-auto-rule-toggle="${ruleId}"]`, false);
    assert.equal(new AutomationRuleStore().load()[0]?.isEnabled, false);
    const nightMs = new Date(2026, 10, 14, 23, 30, 0).getTime();
    await dispatchSystemContextEvent(app, { kind: "tick" }, nightMs);
    assert.equal(sent.length, 0);

    toggleCheck(`[data-auto-rule-toggle="${ruleId}"]`, true);
    assert.equal(new AutomationRuleStore().load()[0]?.isEnabled, true);

    locked = true;
    await click(`[data-auto-rule-run="${ruleId}"]`);
    await setImmediate();
    assert.equal(sent.length, 0);
    assert.equal(app.replyBanner?.isError, true);

    locked = false;
    await click(`[data-auto-rule-run="${ruleId}"]`);
    await setImmediate();
    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.light.desk", isOn: false }]);
    assert.ok(document.querySelector("#settings-auto-recent-runs"));

    const undoBtn = element<HTMLButtonElement>("[data-auto-run-undo]");
    undoBtn.click();
    await setImmediate();
    assert.deepEqual(sent[1], { kind: "setLightPower", entityId: "light.light.desk", isOn: true });

    await click(`[data-auto-rule-delete="${ruleId}"]`);
    assert.equal(new AutomationRuleStore().load().length, 0);
    assert.ok(document.querySelector("#settings-auto-rules-empty"));
  });
});

describe("Wave 4 · Active Safety Guard, Security Sensor Alerts & HA Doorbell Settings UI", () => {
  it("wires active safety switches & 7-kind security sensor switches to live SafetyMonitor evaluation", async () => {
    const app = createCloudApp();
    const heaterPlug = makePlug({ id: "plug.bath", name: "浴霸插座", powerWatts: 2100, isOn: true });
    const lowBatSensor = makeSensor({ id: "sensor.door", name: "入户门磁", battery: 9 });
    app.devices = [heaterPlug, lowBatSensor];

    recordSafetyAlerts(app, [
      {
        id: "longrun:plug.bath",
        deviceId: "plug.bath",
        title: "浴霸插座 已开启超过 45 分钟",
        body: "当前功率 2100W",
        category: "longRun",
        priority: "high",
      },
    ]);
    assert.equal(getHostActivityCenter(app).recentSafetyAlerts.length, 1);

    app.openSettingsSheet("system");

    toggleCheck("#settings-safety-plug", false);
    assert.equal(loadSafetyGuardPrefs().longRunningPlug, false);
    assert.equal(getHostActivityCenter(app).recentSafetyAlerts.length, 0);

    const t0 = new Date(2026, 10, 14, 10, 0, 0).getTime();
    tickSafetyHealthAndAutomation(app, t0);
    assert.ok(getHostActivityCenter(app).recentSafetyAlerts.some((r) => r.alert.id === "battery:sensor.door"));

    tickSafetyHealthAndAutomation(app, t0 + 50 * 60 * 1000);
    assert.equal(
      getHostActivityCenter(app).recentSafetyAlerts.some((r) => r.alert.id === "longrun:plug.bath"),
      false,
    );

    toggleCheck("#settings-safety-master", false);
    assert.equal(element<HTMLInputElement>("#settings-safety-climate").disabled, true);
    assert.equal(element<HTMLInputElement>("#settings-safety-low-battery").disabled, true);

    for (const kind of SENSOR_ALERT_KINDS) {
      assert.ok(document.querySelector(`#settings-sensor-alert-${kind}`));
    }
    toggleCheck("#settings-sensor-alert-contact", true);
    toggleCheck("#settings-sensor-only-away", true);

    const policy = loadSensorAlertPolicy();
    assert.equal(policy.enabled.contact, true);
    assert.equal(policy.onlyWhenAway, true);
  });

  it("persists HA doorbell auto-popup, chime, and auto-close seconds across restarts and governs live rings", async () => {
    const app = createCloudApp({ connectionMode: "homeAssistant", haBaseURL: "http://ha.local:8123", haToken: "tok" });
    const cam = makeCamera();
    app.devices = [cam];
    (app as unknown as { timerSnapshot: { identity: string; sourceRevision: number } }).timerSnapshot = {
      identity: "ha:http://ha.local:8123",
      sourceRevision: app.sourceRevision,
    };

    const scheduler = new FakeDoorbellScheduler();
    getHostActivityCenter(app, { doorbellScheduler: scheduler });

    app.openSettingsSheet("system");
    toggleCheck("#settings-doorbell-chime", true);
    selectValue("#settings-doorbell-seconds", "120");
    assert.equal(loadSafetyGuardPrefs().doorbellPopupSeconds, 120);
    assert.equal(loadSafetyGuardPrefs().doorbellChime, true);

    const baseSnap = {
      entities: [{ entity_id: "event.front_doorbell", device_id: "cam_front" }, { entity_id: "camera.front_door", device_id: "cam_front" }],
      states: [{ entity_id: "event.front_doorbell", state: "2026-11-14T10:00:00Z", attributes: { device_class: "doorbell" } }],
    };
    const ringSnap1 = {
      ...baseSnap,
      states: [{ entity_id: "event.front_doorbell", state: "2026-11-14T10:01:00Z", attributes: { device_class: "doorbell" } }],
    };

    await ingestHostHASnapshotForDoorbell(app, baseSnap, { isLocked: false, nowMs: scheduler.nowMs });
    const res1 = await ingestHostHASnapshotForDoorbell(app, ringSnap1, { isLocked: false, nowMs: scheduler.nowMs + 1000 });
    assert.equal(res1.length, 1);
    assert.equal(res1[0]?.cameraDeviceId, cam.id);
    assert.equal(res1[0]?.playsChime, true);
    assert.equal(res1[0]?.dismissAfterSeconds, 120);
    assert.equal(app.cameraLive.activeLiveCameraId, cam.id);

    scheduler.advanceBy(60_000);
    assert.equal(app.cameraLive.liveCameraHidden, false);
    scheduler.advanceBy(60_000);
    assert.equal(app.cameraLive.liveCameraHidden, true);

    toggleCheck("#settings-doorbell-auto-popup", false);
    assert.equal(element<HTMLSelectElement>("#settings-doorbell-seconds").disabled, true);
    assert.ok(localStorage.getItem(SAFETY_GUARD_PREFS_KEY));

    const restartedApp = new MenuMijiaWindowsApp(element("#app"));
    restartedApp.devices = [cam];
    await ingestHostHASnapshotForDoorbell(restartedApp, baseSnap, { isLocked: false, nowMs: 2_000_000 });
    const ringSnap2 = {
      ...baseSnap,
      states: [{ entity_id: "event.front_doorbell", state: "2026-11-14T10:05:00Z", attributes: { device_class: "doorbell" } }],
    };
    const res2 = await ingestHostHASnapshotForDoorbell(restartedApp, ringSnap2, { isLocked: false, nowMs: 2_005_000 });
    assert.equal(res2[0]?.cameraDeviceId, null);
    assert.equal(restartedApp.cameraLive.activeLiveCameraId, null);
  });
});

describe("Wave 4 · Weekly Home Health Report Preview, Clipboard Copy & Search Anchors", () => {
  it("generates & copies tri-lingual Markdown health report, toggles Sunday schedule, and resets preview on scope switch", async () => {
    let copiedText = "";
    const nav = globalThis.navigator as unknown as {
      clipboard?: { writeText: (txt: string) => Promise<void> };
    };
    nav.clipboard = {
      writeText: async (txt: string) => {
        copiedText = txt;
      },
    };

    const app = createCloudApp();
    const standbyPlug = makePlug({ id: "plug.tv", name: "电视柜插座", isOn: false, powerWatts: 4.6, energyKwh: 12.5 });
    const offlinePlug = makePlug({ id: "plug.balcony", name: "阳台洗衣机插座", roomName: "阳台", isOnline: false, isOn: false, powerWatts: 0 });
    const hotSensor = makeSensor({ id: "sensor.living", name: "客厅温湿度计", roomName: "客厅", temperature: 32, humidity: 76, battery: 12 });
    app.devices = [standbyPlug, offlinePlug, hotSensor];

    const sundayMs = new Date(2026, 10, 15, 20, 5, 0).getTime();
    const energy = getScopedEnergyHistory(app.settings);
    energy.record([standbyPlug], new Date(sundayMs - 2 * 86_400_000));
    const higherPlug = makePlug({ id: "plug.tv", name: "电视柜插座", isOn: false, powerWatts: 4.6, energyKwh: 16.3 });
    energy.record([higherPlug], new Date(sundayMs - 86_400_000));

    const sensorStore = sharedSensorHistoryStore();
    sensorStore.record([hotSensor], { now: sundayMs - 3_600_000 });

    const center = getHostActivityCenter(app);
    center.offlineHistory.record(app.devices, sundayMs - 3_600_000);

    app.openSettingsSheet("system");
    await click("#btn-generate-copy-health-report");
    await setImmediate();

    const previewEl = element("#settings-health-report-markdown");
    assert.match(previewEl.textContent ?? "", /# 家庭健康周报/);
    assert.match(previewEl.textContent ?? "", /电视柜插座/);
    assert.match(previewEl.textContent ?? "", /客厅温湿度计/);
    assert.match(previewEl.textContent ?? "", /阳台洗衣机插座/);
    assert.equal(copiedText, previewEl.textContent);
    assert.equal(center.lastClipboardMarkdown, copiedText);

    app.settings.interfaceLanguage = "en";
    setLanguage("en");
    app.render();
    await click("#btn-generate-copy-health-report");
    await setImmediate();
    assert.match(copiedText, /# Weekly Home Health Report/);

    app.settings.interfaceLanguage = "zh-Hant";
    setLanguage("zh-Hant");
    app.render();
    await click("#btn-generate-copy-health-report");
    await setImmediate();
    assert.match(copiedText, /# 家庭健康週報/);

    app.settings.interfaceLanguage = "zh-Hans";
    setLanguage("zh-Hans");
    app.render();
    toggleCheck("#settings-weekly-report-enabled", false);
    assert.equal(loadSafetyGuardPrefs().enableWeeklyHealthReport, false);
    tickSafetyHealthAndAutomation(app, sundayMs);
    assert.equal(center.weeklyReportCard, null);

    toggleCheck("#settings-weekly-report-enabled", true);
    tickSafetyHealthAndAutomation(app, sundayMs);
    assert.ok(center.weeklyReportCard);

    await click("#btn-generate-copy-health-report");
    assert.ok(document.querySelector("#settings-health-report-preview"));
    app.settings.selectedHomeId = "home-other";
    app.sourceRevision += 1;
    center.weeklyReportCard = null;
    app.render();
    assert.equal(document.querySelector("#settings-health-report-preview"), null);

    const dualAcc1 = makeMiAccount({
      userId: "10001",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok1",
      passToken: "pass1",
      region: "cn",
    });
    const dualAcc2 = makeMiAccount({
      userId: "20002",
      cUserId: "c2",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok2",
      passToken: "pass2",
      region: "sg",
    });
    app.miAccountsOverride = [dualAcc1, dualAcc2];
    app.dualSourceEnabledOverride = true;
    app.settings.haBaseURL = "https://ha.local:8123";
    app.settings.haToken = "ha-tok";
    const dualEnergy = getScopedEnergyHistory({
      connectionMode: app.settings.connectionMode,
      dualSourceEnabled: true,
      activeAccountIds: [dualAcc1.id, dualAcc2.id],
      miSession: app.settings.miSession,
      haBaseURL: app.settings.haBaseURL,
      haToken: app.settings.haToken,
    });
    const nowMs = Date.now();
    dualEnergy.record([makePlug({ id: "plug.tv", name: "电视柜插座", isOn: true, powerWatts: 200, energyKwh: 30 })], new Date(nowMs - 2 * 86_400_000));
    dualEnergy.record([makePlug({ id: "plug.tv", name: "电视柜插座", isOn: true, powerWatts: 200, energyKwh: 36.2 })], new Date(nowMs - 86_400_000));
    await click("#btn-generate-copy-health-report");
    await setImmediate();
    assert.match(copiedText, /本周 6\.2 kWh/);
  });

  it("finds automation, safety guard, sensor alert, doorbell, and weekly health report anchors in search and jumps to highlight", async () => {
    const queryExpectations: ReadonlyArray<readonly [string, string]> = [
      ["自动化规则", "automationRules"],
      ["锁屏自动关灯", "automationRules"],
      ["离开回来", "automationRules"],
      ["zidonghua", "automationRules"],
      ["安全守护", "safetyAlerts"],
      ["低电量", "safetyAlerts"],
      ["漏水烟雾提醒", "sensorAlerts"],
      ["仅在离开", "sensorAlerts"],
      ["门铃自动弹窗", "doorbellAutoView"],
      ["doorbell popup", "doorbellAutoView"],
      ["家庭健康周报", "weeklyReport"],
      ["zhoubao", "weeklyReport"],
      ["weekly health report", "weeklyReport"],
    ];

    for (const [query, expectedAnchor] of queryExpectations) {
      const outcome = searchSettings(query);
      assert.ok(
        outcome.hits.some((h) => h.anchor === expectedAnchor),
        `Expected query "${query}" to match anchor "${expectedAnchor}", got: ${outcome.hits.map((h) => h.anchor).join(", ")}`,
      );
    }

    const app = createCloudApp();
    app.openSettingsSheet("general");
    assert.equal(app.settingsTab, "general");

    typeInput("#settings-search-input", "门铃自动弹窗");
    await click('[data-settings-search-hit="doorbellAutoView"]');

    assert.equal(app.settingsTab, "system");
    const highlighted = element('[data-settings-anchor="doorbellAutoView"]');
    assert.equal(highlighted.getAttribute("data-settings-highlighted"), "doorbellAutoView");
  });

  it("supports scheduled weekday triggers, sensor alarm triggers, battery thresholds, XSS escaping, and closes cleanly without false unsaved prompts", async () => {
    const app = createCloudApp();
    const xssLight = makeLight("light.xss", "<img src=x onerror=alert(1)>主灯", true, "<b>客厅</b>");
    const leakSensor = makeSensor({ id: "sensor.leak", name: "厨房水浸传感器" });
    app.devices = [xssLight, leakSensor];

    app.openSettingsSheet("system");

    await click("#btn-toggle-auto-form");
    assert.equal(element("#settings-auto-form").hidden, true);
    await click("#btn-toggle-auto-form");
    assert.equal(element("#settings-auto-form").hidden, false);

    selectValue("#settings-auto-trigger", "scheduledTime");
    selectValue("#settings-auto-schedule-hour", "8");
    selectValue("#settings-auto-schedule-minute", "15");
    toggleCheck('[data-auto-weekday="1"]', true);
    toggleCheck('[data-auto-weekday="3"]', true);
    selectValue("#settings-auto-wifi-kind", "notIn");
    typeInput("#settings-auto-wifi-ssids", "<script>bad</script>Office_Guest");
    selectValue("#settings-auto-action-kind", "devices");
    toggleCheck('[data-auto-target-device="light.xss"]', true);
    await click("#btn-add-auto-rule");

    selectValue("#settings-auto-trigger", "sensorThreshold");
    selectValue("#settings-auto-sensor-device", "sensor.leak");
    selectValue("#settings-auto-sensor-metric", "alarm");
    selectValue("#settings-auto-sensor-alert-kind", "leak");
    selectValue("#settings-auto-wifi-kind", "any");
    selectValue("#settings-auto-action-kind", "quickAction");
    selectValue("#settings-auto-quick-action", "lightsOff");
    await click("#btn-add-auto-rule");

    selectValue("#settings-auto-trigger", "batteryBelowThreshold");
    typeInput("#settings-auto-battery-threshold", "18");
    await click("#btn-add-auto-rule");

    const rules = new AutomationRuleStore().load();
    assert.equal(rules.length, 3);
    assert.deepEqual(rules[0]?.triggerOptions.scheduledTime, { hour: 8, minute: 15, weekdays: [1, 3] });
    assert.deepEqual(rules[1]?.triggerOptions.sensorCondition, {
      deviceId: "sensor.leak",
      metric: "alarm",
      alertKind: "leak",
    });
    assert.equal(rules[2]?.triggerOptions.batteryThresholdPercent, 18);

    const rulesList = element("#settings-auto-rules-list");
    assert.equal(rulesList.querySelectorAll("script, img").length, 0);
    assert.match(rulesList.textContent ?? "", /Office_Guest/);

    await click("#btn-generate-copy-health-report");
    assert.ok(document.querySelector("#settings-health-report-preview"));
    await click("#btn-clear-health-report-preview");
    assert.equal(document.querySelector("#settings-health-report-preview"), null);

    await click("#btn-close-settings");
    assert.equal(app.activeSheet, "none");
  });
});

describe("Wave 4 · Issue #133 Partial-Account Staleness Guard & PM2.5 Sensor Facet Thresholds", () => {
  it("marks retained cached devices from disconnected Xiaomi accounts as telemetryStale and excludes them from live SensorHistory, EnergyHistory, and SafetyMonitor", async () => {
    const accFailed = makeMiAccount({
      userId: "10001",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok1",
      passToken: "pass1",
      region: "cn",
    });
    const accConnected = makeMiAccount({
      userId: "20002",
      cUserId: "c2",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok2",
      passToken: "pass2",
      region: "sg",
    });

    const staleSensor = makeSensor({
      id: "sensor.stale",
      name: "断连温湿度计",
      temperature: 26.5,
      humidity: 61,
      battery: 8,
    });
    const stalePlug = makePlug({
      id: "plug.stale",
      name: "断连取暖器插座",
      isOn: true,
      powerWatts: 1900,
      energyKwh: 50,
    });
    const liveSensor = makeSensor({
      id: "sensor.live",
      name: "在线温湿度计",
      temperature: 22.0,
      humidity: 48,
      battery: 90,
    });
    const livePlug = makePlug({
      id: "plug.live",
      name: "在线插座",
      isOn: true,
      powerWatts: 120,
      energyKwh: 10,
    });

    const children: Record<string, AccountChildSnapshot> = {
      [accFailed.id]: {
        account: accFailed,
        status: { kind: "disconnected", reason: "HTTP 401" },
        tokenStatus: { kind: "expired", source: "rejected" },
        home: {
          rooms: [{ id: "r1", name: "客厅", deviceCount: 2 }],
          devices: [staleSensor, stalePlug],
          environmentReadings: [],
          scenes: [],
        },
        homes: [],
        rawDevices: [],
        allDevices: [],
        allRooms: [],
        specs: {},
        lightGroupOwners: new Map(),
      },
      [accConnected.id]: {
        account: accConnected,
        status: { kind: "connected" },
        tokenStatus: { kind: "valid" },
        home: {
          rooms: [{ id: "r2", name: "书房", deviceCount: 2 }],
          devices: [liveSensor, livePlug],
          environmentReadings: [],
          scenes: [],
        },
        homes: [],
        rawDevices: [],
        allDevices: [],
        allRooms: [],
        specs: {},
        lightGroupOwners: new Map(),
      },
    };

    const merged = mergeMiAccountSnapshots([accFailed, accConnected], children);
    assert.equal(merged.home.devices.length, 4);
    assert.ok(merged.staleDeviceIds.has("sensor.stale"));
    assert.ok(merged.staleDeviceIds.has("plug.stale"));
    assert.equal(merged.staleDeviceIds.has("sensor.live"), false);

    const retainedSensor = merged.home.devices.find((d) => d.id === "sensor.stale")!;
    const retainedPlug = merged.home.devices.find((d) => d.id === "plug.stale")!;
    const activeSensor = merged.home.devices.find((d) => d.id === "sensor.live")!;
    const activePlug = merged.home.devices.find((d) => d.id === "plug.live")!;

    assert.equal(retainedSensor.telemetryStale, true);
    assert.equal(retainedPlug.telemetryStale, true);
    assert.equal(activeSensor.telemetryStale, undefined);
    assert.equal(activePlug.telemetryStale, undefined);

    const app = createCloudApp();
    app.devices = [...merged.home.devices];
    (app as unknown as { timerSnapshot: { identity: string; sourceRevision: number } }).timerSnapshot = {
      identity: "mi:test",
      sourceRevision: app.sourceRevision,
    };

    syncSensorHistoryHost(app);
    const sensorStore = sharedSensorHistoryStore();
    assert.equal(
      sensorStore.points(retainedSensor.id, "24h").filter((pt) => pt.isObserved).length,
      0,
    );
    assert.ok(
      sensorStore.points(activeSensor.id, "24h").filter((pt) => pt.isObserved).length > 0,
    );

    syncEnergyHostOnRender(app);
    await new Promise((r) => setTimeout(r, 5));
    app.devices = merged.home.devices.map((d) =>
      d.id === retainedPlug.id && d.kind.kind === "plug"
        ? { ...d, kind: { ...d.kind, energyKwh: 55 } }
        : d.id === activePlug.id && d.kind.kind === "plug"
          ? { ...d, kind: { ...d.kind, energyKwh: 12.5 } }
          : d,
    );
    syncEnergyHostOnRender(app);
    const energy = getScopedEnergyHistory(app.settings);
    assert.equal(energy.todayKwh(retainedPlug.id), null);
    assert.equal(energy.todayKwh(activePlug.id), 2.5);

    const t0 = new Date("2026-11-15T10:00:00Z");
    const policy = loadSensorAlertPolicy();
    policy.enabled.smoke = true;
    const monitor = new SafetyMonitor();
    monitor.evaluate({
      devices: merged.home.devices,
      favorites: new Set(),
      sensorPolicy: policy,
      nowMs: t0.getTime(),
    });
    const alertsAfter2h = monitor.evaluate({
      devices: merged.home.devices,
      favorites: new Set(),
      sensorPolicy: policy,
      nowMs: t0.getTime() + 2 * 3600_000,
    });
    assert.equal(
      alertsAfter2h.some((a) => a.deviceId === retainedPlug.id || a.deviceId === retainedSensor.id),
      false,
    );

    const staleSmokeSensor: SmartDevice = {
      ...retainedSensor,
      kind: {
        kind: "sensor",
        temperature: 26,
        humidity: 50,
        battery: 80,
        alertKind: "smoke",
        statusText: "烟雾报警",
      },
    };
    const sensorEval = evaluateSensorAlerts([staleSmokeSensor], {}, t0.getTime(), policy);
    assert.equal(sensorEval.alerts.length, 0);
  });

  it("resolves environmental sensor deviceFacets PM2.5 readings in sensorThreshold rules and skips telemetryStale sensors", async () => {
    const app = createCloudApp();
    const airSensor = makeSensor({ id: "sensor.air", name: "客厅空气质量检测仪" });
    const studyLight = makeLight("light.study", "书房台灯", false);
    const dispatched: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      dispatched.push(cmd);
      return true;
    };

    const rule = createAutomationRule({
      trigger: "sensorThreshold",
      triggerOptions: {
        sensorCondition: {
          deviceId: airSensor.id,
          metric: "pm25",
          comparison: "gt",
          threshold: 75,
        },
      },
      action: {
        kind: "devices",
        deviceIds: [studyLight.id],
        isOn: true,
      },
    });

    const engine = new AutomationEngine();
    const pm25Facets = {
      [airSensor.id]: [
        {
          id: "3.4",
          kind: "reading" as const,
          name: "pm2.5-density",
          title: "PM2.5",
          serviceName: "environment",
          unit: "μg/m³",
          scale: null,
          value: 115,
          options: [],
          range: null,
          isWritable: false,
          writesByDefault: false,
          isHighValue: true,
          target: null,
        },
      ],
    };

    app.devices = [{ ...airSensor, telemetryStale: true }, studyLight];
    app.deviceFacets = pm25Facets;
    const staleRuns = await engine.dispatchEvent(
      app,
      { kind: "tick" },
      { rules: [rule], nowMs: 1_000_000 },
    );
    assert.equal(staleRuns.length, 0);
    assert.equal(dispatched.length, 0);

    app.devices = [airSensor, studyLight];
    const liveRuns = await engine.dispatchEvent(
      app,
      { kind: "tick" },
      { rules: [rule], nowMs: 1_060_000 },
    );
    assert.equal(liveRuns.length, 1);
    assert.deepEqual(dispatched, [
      { kind: "setLightPower", entityId: "light.light.study", isOn: true },
    ]);
  });

  it("records live sensor and energy telemetry for HA-winning dual-source cards whose canonical ID matches a stale Xiaomi DID", async () => {
    const app = createCloudApp();
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.haBaseURL = "http://192.168.1.10:8123";
    app.settings.haToken = "token-ha-dual";
    app.dualSourceEnabledOverride = true;
    app.sourceRevision = 12;
    (app as unknown as { timerSnapshot: { identity: string; sourceRevision: number } }).timerSnapshot = {
      identity: "dual:test",
      sourceRevision: 12,
    };

    const accA = makeMiAccount({
      userId: "10001",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok1",
      passToken: "pass1",
      region: "cn",
    });
    const accB = makeMiAccount({
      userId: "20002",
      cUserId: "c2",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok2",
      passToken: "pass2",
      region: "de",
    });
    const staleXiaomiCanonicalId = "mi:20002/did-paired-sensor";
    const staleXiaomiPlugCanonicalId = "mi:20002/did-paired-plug";

    const haBackedSensor: SmartDevice = {
      ...makeSensor({
        id: staleXiaomiCanonicalId,
        name: "Living Room Sensor (HA)",
        temperature: 24.5,
        humidity: 52,
        battery: 95,
      }),
      sourceBackend: "homeAssistant",
    };
    const haBackedPlug: SmartDevice = {
      ...makePlug({
        id: staleXiaomiPlugCanonicalId,
        name: "Living Room Plug (HA)",
        isOn: true,
        powerWatts: 110,
        energyKwh: 4.2,
      }),
      sourceBackend: "homeAssistant",
    };

    app.multiAccountState = {
      accounts: [accA, accB],
      children: {},
      merged: {
        home: {
          devices: [haBackedSensor, haBackedPlug],
          rooms: [],
          environmentReadings: [],
          scenes: [],
        },
        homes: [],
        accountStatuses: {
          [accA.id]: { kind: "connected" },
          [accB.id]: { kind: "disconnected", reason: "token expired" },
        },
        accountTokenStatuses: {},
        deviceOwners: {},
        aggregateStatus: { kind: "connected" },
        rawDevicesByAccount: {},
        allDevicesByAccount: {},
        allRoomsByAccount: {},
        specsByModel: {},
        lightGroupOwners: new Map(),
        resetSelectedHome: false,
        staleDeviceIds: new Set([staleXiaomiCanonicalId, staleXiaomiPlugCanonicalId]),
      },
    };

    app.devices = [haBackedSensor, haBackedPlug];
    syncSensorHistoryHost(app);
    syncEnergyHostOnRender(app);

    const sensorPoints = sharedSensorHistoryStore().points(
      staleXiaomiCanonicalId,
      "24h",
    );
    assert.ok(sensorPoints.some((p) => p.isObserved), "HA-winning sensor must record live points despite Xiaomi canonical ID in staleDeviceIds");

    await new Promise((r) => setTimeout(r, 5));
    const nextHaPlug: SmartDevice = {
      ...haBackedPlug,
      kind:
        haBackedPlug.kind.kind === "plug"
          ? { ...haBackedPlug.kind, energyKwh: 5.7 }
          : haBackedPlug.kind,
    };
    app.devices = [haBackedSensor, nextHaPlug];
    syncEnergyHostOnRender(app);

    const energyHistory = getScopedEnergyHistory({
      ...app.settings,
      dualSourceEnabled: true,
      activeAccountIds: [accA.id, accB.id],
    });
    const plugDelta = energyHistory.todayKwh(staleXiaomiPlugCanonicalId) ?? 0;
    assert.ok(Math.abs(plugDelta - 1.5) < 1e-6, `Expected 1.5 kWh recorded for HA-winning plug, got ${plugDelta}`);
  });
});
