import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  AUTOMATION_POLICY,
  AUTOMATION_TRIGGERS,
  AutomationEngine,
  AutomationRuleStore,
  AwayArbitrator,
  DoorbellCameraCoordinator,
  DoorbellDetector,
  createAutomationConditions,
  createAutomationRule,
  createLateNightWindow,
  evaluateWiFiCondition,
  executeAutomationRule,
  lateNightAnchorKey,
  lateNightWindowContains,
  normalizeWiFiSSIDs,
  type DoorbellCoordinatorScheduler,
} from "../src/core/automationEngine.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import {
  OfflineHistory,
  SENSOR_ALERT_KINDS,
  SafetyMonitor,
  WeeklyHealthReportSchedule,
  buildWeeklyHealthReport,
  createDefaultSensorAlertPolicy,
  evaluateSensorAlerts,
  renderWeeklyHealthMarkdown,
  type KeyValueStorageLike,
} from "../src/core/safetyAndHealth.js";
import {
  buildActivityFeed,
  copyWeeklyHealthMarkdown,
  deliverWeeklyHealthReport,
  dispatchDesktopNotification,
  dispatchSystemContextEvent,
  getHostActivityCenter,
  ingestHostHASnapshotForDoorbell,
  recordSafetyAlerts,
  tickSafetyHealthAndAutomation,
} from "../src/ui/activityStackView.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { startTimerLoop, type LifecycleScheduler } from "../src/ui/appLifecycle.js";

class MemoryKV implements KeyValueStorageLike {
  private readonly store = new Map<string, string>();
  public getItem(key: string): string | null {
    return this.store.get(key) ?? null;
  }
  public setItem(key: string, value: string): void {
    this.store.set(key, value);
  }
  public removeItem(key: string): void {
    this.store.delete(key);
  }
}

class FakeTimeoutScheduler implements DoorbellCoordinatorScheduler {
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

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Expected selector to exist: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function makePlug(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  isOnline?: boolean;
  isOn?: boolean;
  powerWatts?: number | null;
  powerWritable?: boolean;
} = {}): SmartDevice {
  const id = overrides.id ?? "plug.heater";
  return {
    id,
    name: overrides.name ?? "取暖器插座",
    roomId: overrides.roomId ?? "room_living",
    roomName: overrides.roomName ?? "客厅",
    model: "chuangmi.plug.212a01",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn: overrides.isOn ?? true,
      powerWatts: overrides.powerWatts !== undefined ? overrides.powerWatts : 1850,
      energyKwh: 3.2,
      childLockEntityId: null,
      isChildLocked: false,
      powerWritable: overrides.powerWritable ?? true,
    },
  };
}

function makeClimate(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  isOnline?: boolean;
  isOn?: boolean;
  targetTemperature?: number;
} = {}): SmartDevice {
  const id = overrides.id ?? "climate.bedroom";
  return {
    id,
    name: overrides.name ?? "主卧空调",
    roomId: overrides.roomId ?? "room_bed",
    roomName: overrides.roomName ?? "主卧",
    model: "xiaomi.aircondition.mc5",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "climate",
      entityId: id,
      isOn: overrides.isOn ?? true,
      hvacMode: "cool",
      availableModes: ["cool", "heat", "off"],
      targetTemperature: overrides.targetTemperature ?? 25,
      currentTemperature: 27,
      minTemp: 16,
      maxTemp: 31,
      step: 1,
      fanMode: "auto",
      availableFanModes: ["auto", "low", "high"],
      powerWritable: true,
      temperatureWritable: true,
    },
  };
}

function makeLight(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  isOnline?: boolean;
  isOn?: boolean;
} = {}): SmartDevice {
  const id = overrides.id ?? "light.desk";
  return {
    id,
    name: overrides.name ?? "书桌台灯",
    roomId: overrides.roomId ?? "room_study",
    roomName: overrides.roomName ?? "书房",
    model: "yeelink.light.lamp15",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "light",
      entityId: id,
      isOn: overrides.isOn ?? true,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
      powerWritable: true,
      brightnessWritable: true,
      colorWritable: true,
    },
  };
}

function makeSensor(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  model?: string;
  isOnline?: boolean;
  battery?: number | null;
  statusText?: string | null;
  temperature?: number | null;
  humidity?: number | null;
} = {}): SmartDevice {
  return {
    id: overrides.id ?? "sensor.kitchen_smoke",
    name: overrides.name ?? "厨房烟感",
    roomId: overrides.roomId ?? "room_kitchen",
    roomName: overrides.roomName ?? "厨房",
    model: overrides.model ?? "lumi.sensor_smoke.v1",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "sensor",
      temperature: overrides.temperature ?? null,
      humidity: overrides.humidity ?? null,
      battery: overrides.battery ?? 90,
      ...(overrides.statusText !== undefined ? { statusText: overrides.statusText } : {}),
    },
  };
}

function makeCamera(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  entityId?: string;
  isOnline?: boolean;
} = {}): SmartDevice {
  const id = overrides.id ?? "ha:dev_front_door";
  const entityId = overrides.entityId ?? "camera.front_door";
  return {
    id,
    name: overrides.name ?? "玄关门铃摄像机",
    roomId: overrides.roomId ?? "area_entry",
    roomName: overrides.roomName ?? "玄关",
    model: "xiaomi.camera. doorbell",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "camera",
      entityId,
      isOn: true,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
      streamEntityId: entityId,
      snapshotPath: `/api/camera_proxy/${entityId}`,
      powerWritable: true,
    },
  };
}

function createCloudApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      interfaceLanguage: "zh-Hans",
      ...extraSettings,
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  app.settings.connectionMode = (extraSettings.connectionMode as "xiaomiCloud" | "homeAssistant" | "demo") ?? "xiaomiCloud";
  if (app.settings.connectionMode === "xiaomiCloud" && !extraSettings.miSession) {
    app.settings.miSession = {
      userId: "90001234",
      cUserId: "",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok-session-1",
      passToken: "",
      region: "cn",
    };
  }
  return app;
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  delete window.__TAURI_INTERNALS__;
  await closeTestWindow(dom);
});

describe("B4 Active Safety Guard, 7-Kind Security Sensor Alerts & Offline/Health Report", () => {
  it("alerts on >300W plugs >=45m (skipping read-only/low-draw plugs), climate >=4h, pinned offline transitions, and <15% battery with 24h cooldown", () => {
    const kv = new MemoryKV();
    const monitor = new SafetyMonitor(kv);
    const t0 = Date.UTC(2026, 10, 8, 8, 0, 0);

    const highPowerPlug = makePlug({ id: "p.high", name: "电暖插座", powerWatts: 1500 });
    const lowPowerPlug = makePlug({ id: "p.router", name: "路由器插座", powerWatts: 18 });
    const readOnlyBreaker = makePlug({
      id: "p.breaker",
      name: "总空开",
      powerWatts: 2200,
      powerWritable: false,
    });
    const ac = makeClimate({ id: "c.bed", name: "主卧空调", targetTemperature: 24 });
    const favLight = makeLight({ id: "l.fav", name: "玄关主灯", isOnline: true });
    const lowBatSensor = makeSensor({ id: "s.door", name: "大门门磁", battery: 12 });

    const policy = createDefaultSensorAlertPolicy(false);
    const favorites = new Set(["l.fav"]);

    const first = monitor.evaluate({
      devices: [highPowerPlug, lowPowerPlug, readOnlyBreaker, ac, favLight, lowBatSensor],
      favorites,
      sensorPolicy: policy,
      nowMs: t0,
    });
    assert.deepEqual(
      first.map((a) => a.id),
      ["battery:s.door"],
    );

    const at44m = monitor.evaluate({
      devices: [highPowerPlug, lowPowerPlug, readOnlyBreaker, ac, favLight, lowBatSensor],
      favorites,
      sensorPolicy: policy,
      nowMs: t0 + 44 * 60_000,
    });
    assert.equal(at44m.length, 0);

    const favOffline = makeLight({ id: "l.fav", name: "玄关主灯", isOnline: false });
    const at45m = monitor.evaluate({
      devices: [highPowerPlug, lowPowerPlug, readOnlyBreaker, ac, favOffline, lowBatSensor],
      favorites,
      sensorPolicy: policy,
      nowMs: t0 + 45 * 60_000,
    });
    assert.equal(at45m.length, 2);
    const plugAlert = at45m.find((a) => a.id === "longrun:p.high");
    assert.ok(plugAlert);
    assert.deepEqual(plugAlert.turnOffCommand, {
      kind: "setSwitch",
      entityId: "switch.p.high",
      isOn: false,
    });
    assert.ok(at45m.some((a) => a.id.startsWith("offline:l.fav:")));

    const at4h = monitor.evaluate({
      devices: [highPowerPlug, lowPowerPlug, readOnlyBreaker, ac, favOffline, lowBatSensor],
      favorites,
      sensorPolicy: policy,
      nowMs: t0 + 4 * 3_600_000,
    });
    assert.deepEqual(
      at4h.map((a) => a.id),
      ["longrun:c.bed"],
    );
    assert.deepEqual(at4h[0]?.turnOffCommand, {
      kind: "setClimatePower",
      entityId: "c.bed",
      isOn: false,
      resumeMode: "cool",
    });

    const reloaded = new SafetyMonitor(kv);
    assert.equal(
      reloaded.evaluate({
        devices: [lowBatSensor],
        favorites,
        sensorPolicy: policy,
        nowMs: t0 + 23 * 3_600_000,
      }).length,
      0,
    );
    assert.equal(
      reloaded.evaluate({
        devices: [lowBatSensor],
        favorites,
        sensorPolicy: policy,
        nowMs: t0 + 24 * 3_600_000 + 1000,
      }).length,
      1,
    );
  });

  it("evaluates all 7 security sensor edge classes with hazard first-sample semantics and onlyWhenAway filtering", () => {
    assert.equal(SENSOR_ALERT_KINDS.length, 7);
    const nowMs = Date.UTC(2026, 10, 8, 12, 0, 0);

    const smoke = makeSensor({ id: "s1", name: "厨房烟雾", model: "lumi.sensor_smoke", statusText: "烟雾报警" });
    const gas = makeSensor({ id: "s2", name: "厨房燃气", model: "lumi.sensor_natgas", statusText: "燃气泄漏告警" });
    const leak = makeSensor({ id: "s3", name: "卫生间水浸", model: "lumi.sensor_wleak", statusText: "浸水告警" });
    const contact = makeSensor({ id: "s4", name: "阳台门磁", model: "isa.magnet.dw2hl", statusText: "已关闭" });
    const motion = makeSensor({ id: "s5", name: "玄关人体", model: "lumi.motion.bmgl01", statusText: "无人" });
    const vibration = makeSensor({ id: "s6", name: "保险箱震动", model: "lumi.vibration.aq1", statusText: "正常" });
    const lock = makeSensor({ id: "s7", name: "入户门锁", model: "xiaomi.lock.pro", statusText: "已上锁" });

    const allEnabledHomePolicy = {
      enabled: {
        smoke: true,
        gas: true,
        leak: true,
        contact: true,
        motion: true,
        vibration: true,
        lock: true,
      },
      onlyWhenAway: true,
      includesAway: false,
    };

    const pass1 = evaluateSensorAlerts(
      [smoke, gas, leak, contact, motion, vibration, lock],
      {},
      nowMs,
      allEnabledHomePolicy,
    );
    assert.deepEqual(
      pass1.alerts.map((a) => a.sensorKind),
      ["smoke", "gas", "leak"],
    );

    const contactOpen = makeSensor({ ...contact, statusText: "已打开" });
    const motionActive = makeSensor({ ...motion, statusText: "有人移动" });
    const vibrationActive = makeSensor({ ...vibration, statusText: "检测到震动" });
    const lockTamper = makeSensor({ ...lock, statusText: "门锁异常未关好" });

    const pass2Suppressed = evaluateSensorAlerts(
      [smoke, gas, leak, contactOpen, motionActive, vibrationActive, lockTamper],
      pass1.ledger,
      nowMs + 5_000,
      allEnabledHomePolicy,
    );
    assert.equal(pass2Suppressed.alerts.length, 0);

    const passReset = evaluateSensorAlerts(
      [contact, motion, vibration, lock],
      pass2Suppressed.ledger,
      nowMs + 10_000,
      { ...allEnabledHomePolicy, includesAway: true },
    );
    assert.equal(passReset.alerts.length, 0);

    const passAway = evaluateSensorAlerts(
      [contactOpen, motionActive, vibrationActive, lockTamper],
      passReset.ledger,
      nowMs + 15_000,
      { ...allEnabledHomePolicy, includesAway: true },
    );
    assert.deepEqual(
      passAway.alerts.map((a) => a.sensorKind),
      ["contact", "motion", "vibration", "lock"],
    );
  });

  it("tracks 14-day offline frequency/duration, triggers Sunday 20:00 Weekly Health Report, and exports tri-lingual Markdown", async () => {
    const kv = new MemoryKV();
    const history = new OfflineHistory(kv);
    const sunday20 = new Date(2026, 10, 8, 20, 5, 0).getTime();
    const dayMs = 24 * 3_600_000;

    const staleDev = makeLight({ id: "l.old", name: "旧灯", isOnline: false });
    history.record([staleDev], sunday20 - 16 * dayMs);

    const dropA = makeLight({ id: "l.dropA", name: "次卧吸顶灯", roomName: "次卧", isOnline: false });
    const dropB = makeSensor({ id: "s.dropB", name: "次卧温湿度", roomName: "次卧", isOnline: false });
    for (const offsetDays of [3, 2, 1]) {
      const tStart = sunday20 - offsetDays * dayMs;
      history.record([dropA, dropB], tStart);
      history.record(
        [
          makeLight({ ...dropA, isOnline: true }),
          makeSensor({ ...dropB, isOnline: true }),
        ],
        tStart + 30 * 60_000,
      );
    }

    const days7 = history.offlineDays(7, sunday20);
    assert.equal(days7["l.old"], undefined);
    assert.equal(days7["l.dropA"], 3);
    const ledger = history.deviceSummaries(14, sunday20);
    assert.equal(ledger["l.dropA"]?.outageCount, 3);
    assert.equal(ledger["l.dropA"]?.offlineDurationMs, 90 * 60_000);

    const standbyPlug = makePlug({
      id: "p.tv",
      name: "电视机插座",
      roomName: "客厅",
      isOn: false,
      powerWatts: 4.6,
    });
    const lowVacuum: SmartDevice = {
      id: "v.main",
      name: "扫拖机器人",
      roomId: "room_living",
      roomName: "客厅",
      model: "roborock.vacuum.a15",
      isOnline: true,
      kind: {
        kind: "vacuum",
        entityId: "vacuum.main",
        status: "docked",
        battery: 15,
        modeEntityId: null,
        currentMode: null,
        availableModes: [],
      },
    };

    const report = buildWeeklyHealthReport({
      devices: [
        makeLight({ id: "l.dropA", name: "次卧吸顶灯", roomName: "次卧", isOnline: true }),
        makeSensor({ id: "s.dropB", name: "次卧温湿度", roomName: "次卧", isOnline: true, battery: 80 }),
        standbyPlug,
        lowVacuum,
      ],
      dailyEnergy: [
        ...Array.from({ length: 7 }, () => ({ kwh: 4, isObserved: true })),
        ...Array.from({ length: 7 }, () => ({ kwh: 5, isObserved: true })),
      ],
      energyByDevice: [{ name: "电视机插座", kwh: 12.4 }],
      offlineHistory: history,
      nowMs: sunday20,
    });

    assert.equal(report.standbyConsumers.length, 1);
    assert.equal(report.maintenance.length, 1);
    assert.deepEqual(report.unreliableRooms, ["次卧"]);

    const mdZhHans = renderWeeklyHealthMarkdown(report, "zh-Hans");
    const mdZhHant = renderWeeklyHealthMarkdown(report, "zh-Hant");
    const mdEn = renderWeeklyHealthMarkdown(report, "en");

    assert.match(mdZhHans, /# 家庭健康周报/);
    assert.match(mdZhHans, /待机耗电提醒：客厅 · 电视机插座 \(关闭状态仍消耗 4\.6 W\)/);
    assert.match(mdZhHans, /建议排查网络\/网关信号的房间：次卧/);
    assert.match(mdZhHant, /# 家庭健康週報/);
    assert.match(mdZhHant, /待機耗電提醒/);
    assert.match(mdEn, /# Weekly Home Health Report/);
    assert.match(mdEn, /Standby power alert: 客厅 · 电视机插座/);
    assert.match(mdEn, /Rooms recommended for Wi-Fi\/gateway check: 次卧/);

    assert.equal(WeeklyHealthReportSchedule.isDue(sunday20, null), true);
    assert.equal(WeeklyHealthReportSchedule.isDue(sunday20 + 3 * dayMs, null), false);

    const app = createCloudApp();
    app.devices = [standbyPlug, lowVacuum];
    deliverWeeklyHealthReport(app, sunday20, { report, storage: kv });
    app.render();

    assert.ok(document.querySelector("[data-activity-copy-health]"));
    let clipboardText = "";
    (globalThis.navigator as unknown as { clipboard: { writeText: (txt: string) => Promise<void> } }).clipboard = {
      writeText: async (txt: string) => {
        clipboardText = txt;
      },
    };
    await click("[data-activity-copy-health]");
    assert.match(clipboardText, /# 家庭健康周报/);
    assert.equal(await copyWeeklyHealthMarkdown(app), clipboardText);
  });
});

describe("B9 Single-Owner Lifecycle, Lock-Screen Interception & Activity Stack UI", () => {
  it("intercepts「立即关闭」on a safety alert card while workstation is locked, and executes once unlocked", async () => {
    const app = createCloudApp({ blockControlWhileLocked: true });
    const heaterPlug = makePlug({ id: "p.heater", name: "浴室暖风机", powerWatts: 1900 });
    app.devices = [heaterPlug];

    let locked = true;
    window.__TAURI_INTERNALS__ = {
      invoke: async <T>(cmd: string): Promise<T> => {
        if (cmd === "is_workstation_locked") return locked as unknown as T;
        return undefined as unknown as T;
      },
    };

    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      return true;
    };

    recordSafetyAlerts(app, [
      {
        id: "longrun:p.heater",
        deviceId: "p.heater",
        title: "浴室暖风机 已开启超过 45 分钟",
        body: "当前功率 1900W",
        category: "longRun",
        priority: "high",
        turnOffCommand: { kind: "setSwitch", entityId: "switch.p.heater", isOn: false },
      },
    ]);
    app.render();

    await click('[data-activity-safety-off="longrun:p.heater"]');
    await setImmediate();
    assert.equal(sent.length, 0);
    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /屏幕已锁定/);
    assert.ok(document.querySelector('[data-activity-safety-off="longrun:p.heater"]'));

    locked = false;
    await click('[data-activity-safety-off="longrun:p.heater"]');
    await setImmediate();
    assert.deepEqual(sent, [{ kind: "setSwitch", entityId: "switch.p.heater", isOn: false }]);
    assert.equal(document.querySelector('[data-activity-safety-off="longrun:p.heater"]'), null);
  });

  it("enforces single-owner lifecycle: caps at 10 deduped alerts, wakes dismissed alerts on recurrence, cleans orphans, collapses on hide, and clears on home/backend switch", async () => {
    const app = createCloudApp();
    const devices = Array.from({ length: 12 }, (_, idx) =>
      makePlug({ id: `p.${idx}`, name: `插座${idx}`, powerWatts: 800 }),
    );
    app.devices = devices;
    app.render();

    recordSafetyAlerts(
      app,
      devices.map((d) => ({
        id: `longrun:${d.id}`,
        deviceId: d.id,
        title: `${d.name} 超时`,
        body: "功率高",
        category: "longRun" as const,
        priority: "normal" as const,
      })),
    );
    const center = getHostActivityCenter(app);
    assert.equal(center.recentSafetyAlerts.length, 10);
    app.render();

    assert.equal(element("[data-activity-stack]").dataset.activityExpanded, "false");
    assert.equal(element("[data-activity-toggle-expand]").textContent?.trim(), "+9");
    await click("[data-activity-toggle-expand]");
    assert.equal(element("[data-activity-stack]").dataset.activityExpanded, "true");
    assert.equal(document.querySelectorAll("[data-activity-card]").length, 10);

    await click('[data-activity-dismiss="safety:longrun:p.11"]');
    assert.equal(document.querySelector('[data-activity-card="safety:longrun:p.11"]'), null);
    recordSafetyAlerts(app, [
      {
        id: "longrun:p.11",
        deviceId: "p.11",
        title: "插座11 再次超时",
        body: "功率高",
        category: "longRun",
        priority: "normal",
      },
    ]);
    app.render();
    assert.ok(document.querySelector('[data-activity-card="safety:longrun:p.11"]'));

    await click('[data-activity-dismiss="safety:longrun:p.10"]');
    assert.equal(center.dismissedActivityIds.has("safety:longrun:p.10"), true);
    app.devices = devices.slice(0, 10);
    app.render();
    assert.equal(center.recentSafetyAlerts.some((r) => r.alert.deviceId === "p.11"), false);
    assert.equal(center.dismissedActivityIds.has("safety:longrun:p.10"), false);

    assert.equal(center.isExpanded, true);
    await click("#btn-hide-panel");
    assert.equal(center.isExpanded, false);

    await click("[data-activity-toggle-expand]");
    assert.equal(center.isExpanded, true);
    app.settings.selectedHomeId = "home_parents_2";
    app.invalidateSourceControl();
    app.render();
    assert.equal(center.recentSafetyAlerts.length, 0);
    assert.equal(center.dismissedActivityIds.size, 0);
    assert.equal(center.isExpanded, false);
    assert.equal(document.querySelector("[data-activity-stack]"), null);
  });

  it("re-surfaces dismissed Mi session expiry notice when renewed session has a new expiry timestamp, and safely falls back on desktop notifications", async () => {
    const now = Date.now();
    const firstExpiry = now + 24 * 3_600_000;
    const secondExpiry = now + 36 * 3_600_000;
    const app = createCloudApp({
      miSession: {
        userId: "90001234",
        cUserId: "",
        ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
        serviceToken: "tok-1",
        passToken: "",
        region: "cn",
        expiresAt: firstExpiry,
      },
    });
    app.devices = [makeLight()];
    app.render();

    assert.ok(document.querySelector("[data-mi-expiry-warning]"));
    await click(`[data-activity-dismiss="notice:miExpiringSoon:${firstExpiry}"]`);
    assert.equal(document.querySelector("[data-mi-expiry-warning]"), null);

    app.settings.miSession = {
      ...app.settings.miSession!,
      expiresAt: secondExpiry,
    };
    app.render();
    assert.ok(document.querySelector("[data-mi-expiry-warning]"));

    window.__TAURI_INTERNALS__ = {
      invoke: async () => {
        throw new Error("plugin:notification unavailable");
      },
    };
    const record = await dispatchDesktopNotification(app, {
      id: "smoke:1",
      title: "厨房烟感 烟雾告警",
      body: "立即查看",
    });
    assert.equal(record.channel, "panel-only");
  });
});

describe("B1 + B5 PC Context Automation Engine, AwayArbitrator, 5m Undo & HA Doorbell User-Takeover", () => {
  it("supports 16+ triggers, resilient rule store, Wi-Fi conditions, cross-midnight LateNightWindow, and AwayArbitrator lock+sleep arbitration", () => {
    assert.ok(AUTOMATION_TRIGGERS.length >= 16);

    const kv = new MemoryKV();
    const validRule = createAutomationRule({
      id: "r-valid",
      trigger: "screenLocked",
      action: { kind: "quickAction", quickAction: "lightsOff" },
      conditions: createAutomationConditions({
        kind: "inAny",
        ssids: ["  HomeWiFi  ", "HomeWiFi", "Office5G"],
      }),
    });
    kv.setItem(
      AutomationRuleStore.storageKey,
      JSON.stringify([
        validRule,
        { id: "r-corrupt", isEnabled: true, trigger: "nonExistentTrigger", action: { kind: "unknown" } },
      ]),
    );
    const loaded = new AutomationRuleStore(kv).load();
    assert.equal(loaded.length, 1);
    assert.equal(loaded[0]?.id, "r-valid");
    assert.deepEqual(normalizeWiFiSSIDs([" A ", "A", "", "B"]), ["A", "B"]);

    const notInWork = { kind: "notIn" as const, ssids: ["CorpNet"] };
    assert.equal(evaluateWiFiCondition(notInWork, null, true).status, "no-network");
    assert.equal(evaluateWiFiCondition(notInWork, "HomeNet", false).status, "not-authorized");
    assert.equal(evaluateWiFiCondition(notInWork, "CorpNet", true).isSatisfied, false);
    assert.equal(evaluateWiFiCondition(notInWork, "HomeNet", true).isSatisfied, true);

    const win = createLateNightWindow(23, 6);
    const evening = new Date(2026, 10, 8, 23, 30, 0).getTime();
    const afterMidnight = new Date(2026, 10, 9, 1, 30, 0).getTime();
    const noon = new Date(2026, 10, 9, 12, 0, 0).getTime();
    assert.equal(lateNightWindowContains(win, evening), true);
    assert.equal(lateNightWindowContains(win, afterMidnight), true);
    assert.equal(lateNightWindowContains(win, noon), false);
    assert.equal(lateNightAnchorKey(win, evening), lateNightAnchorKey(win, afterMidnight));

    const arb = new AwayArbitrator();
    assert.equal(arb.ingest("screenLocked", false, 1_000), null);
    assert.equal(arb.hasPendingLock, true);
    assert.equal(arb.ingest("willSleep", true, 1_800), "lidClosedSleep");
    assert.equal(arb.flush(3_500), null);
    assert.equal(arb.ingest("screenLocked", true, 3_000), null);
    assert.equal(arb.hasPendingLock, false);
    assert.equal(arb.ingest("screenLocked", false, 10_000), null);
    assert.equal(arb.flush(11_000), null);
    assert.equal(arb.flush(12_000), "screenLockedOnly");
  });

  it("fires lock/sensor/scheduled rules via startTimerLoop & dispatchSystemContextEvent with 5-minute Undo (exempt on trigger, guarded on manual Undo while locked, zero habit pollution)", async () => {
    const app = createCloudApp({ blockControlWhileLocked: true, habitLearningEnabled: true });
    const deskLight = makeLight({ id: "l.study", name: "书房台灯", isOn: true });
    const tempSensor = makeSensor({ id: "s.temp", name: "书房温度计", temperature: 24 });
    app.devices = [deskLight, tempSensor];

    const center = getHostActivityCenter(app);
    const lockRule = createAutomationRule({
      id: "rule-lock-off",
      trigger: "away",
      action: { kind: "devices", deviceIds: ["l.study"], isOn: false },
    });
    const sensorRule = createAutomationRule({
      id: "rule-hot-on",
      trigger: "sensorThreshold",
      action: { kind: "devices", deviceIds: ["l.study"], isOn: true },
      triggerOptions: {
        sensorCondition: {
          deviceId: "s.temp",
          metric: "temperature",
          comparison: "gte",
          threshold: 30,
        },
      },
    });
    center.automationEngine.store.save([lockRule, sensorRule]);

    let workstationLocked = false;
    window.__TAURI_INTERNALS__ = {
      invoke: async <T>(cmd: string): Promise<T> => {
        if (cmd === "is_workstation_locked") return workstationLocked as unknown as T;
        return undefined as unknown as T;
      },
    };

    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      if (cmd.kind === "setLightPower" && deskLight.kind.kind === "light") {
        deskLight.kind = { ...deskLight.kind, isOn: cmd.isOn };
      }
      return true;
    };

    let intervalTick: (() => void) | null = null;
    let fakeNow = Date.now();
    const scheduler: LifecycleScheduler = {
      now: () => fakeNow,
      setTimeout: () => 0,
      clearTimeout: () => {},
      setInterval: (fn) => {
        intervalTick = fn;
        return 1;
      },
      clearInterval: () => {
        intervalTick = null;
      },
    };
    const stopLoop = startTimerLoop(app, { scheduler });

    intervalTick!();
    await setImmediate();
    await setImmediate();
    assert.equal(sent.length, 0);

    workstationLocked = true;
    fakeNow += 1_000;
    intervalTick!();
    await setImmediate();
    await setImmediate();

    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "l.study", isOn: false }]);
    assert.equal(deskLight.kind.kind === "light" && deskLight.kind.isOn, false);
    assert.equal(app.settings.habitEntries.length, 0);
    assert.equal(app.lastUndoAction?.expiresAtMs, fakeNow + AUTOMATION_POLICY.undoWindowMs);
    app.render();

    const undoBtn = document.querySelector<HTMLButtonElement>("[data-activity-auto-undo]");
    assert.ok(undoBtn);

    undoBtn.click();
    await setImmediate();
    assert.equal(sent.length, 1);
    assert.equal(app.replyBanner?.isError, true);

    workstationLocked = false;
    const undoBtnAfter = element("[data-activity-auto-undo]");
    undoBtnAfter.click();
    await setImmediate();
    assert.deepEqual(sent, [
      { kind: "setLightPower", entityId: "l.study", isOn: false },
      { kind: "setLightPower", entityId: "l.study", isOn: true },
    ]);
    assert.equal(deskLight.kind.kind === "light" && deskLight.kind.isOn, true);

    deskLight.kind = { ...(deskLight.kind as Extract<SmartDevice["kind"], { kind: "light" }>), isOn: false };
    app.devices = [deskLight, makeSensor({ id: "s.temp", name: "书房温度计", temperature: 31 })];
    fakeNow += 120_000;
    const sensorRuns = await dispatchSystemContextEvent(app, { kind: "tick" }, fakeNow);
    assert.equal(sensorRuns.length, 1);
    assert.equal(deskLight.kind.kind === "light" && deskLight.kind.isOn, true);

    stopLoop();
  });

  it("detects HA doorbell event edges (skipping disabled/hidden & surviving unavailable) and enforces User-Takeover protection on camera popup", async () => {
    const detector = new DoorbellDetector();
    const frontCam = makeCamera({ id: "ha:dev_front", entityId: "camera.front_door", name: "前门摄像机" });
    const backyardCam = makeCamera({ id: "ha:dev_back", entityId: "camera.backyard", name: "后院摄像机", roomId: "area_back", roomName: "后院" });

    const baseSnapshot = {
      devices: [
        { id: "dev_front", area_id: "area_entry", disabled_by: null },
        { id: "dev_disabled", area_id: "area_entry", disabled_by: "user" },
      ],
      entities: [
        { entity_id: "camera.front_door", device_id: "dev_front", disabled_by: null, hidden_by: null },
        { entity_id: "event.front_doorbell", device_id: "dev_front", disabled_by: null, hidden_by: null },
        { entity_id: "event.hidden_doorbell", device_id: "dev_front", disabled_by: null, hidden_by: "user" },
        { entity_id: "event.disabled_dev_bell", device_id: "dev_disabled", disabled_by: null, hidden_by: null },
      ],
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-08T10:00:00.000Z",
          attributes: { device_class: "doorbell" },
        },
        {
          entity_id: "event.hidden_doorbell",
          state: "2026-11-08T10:00:00.000Z",
          attributes: { device_class: "doorbell" },
        },
        {
          entity_id: "event.disabled_dev_bell",
          state: "2026-11-08T10:00:00.000Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };

    assert.equal(detector.ingestHASnapshot(baseSnapshot, [frontCam, backyardCam]).length, 0);

    assert.equal(
      detector.ingestHASnapshot(
        {
          ...baseSnapshot,
          states: [
            { entity_id: "event.front_doorbell", state: "unavailable", attributes: { device_class: "doorbell" } },
          ],
        },
        [frontCam, backyardCam],
      ).length,
      0,
    );
    assert.equal(detector.ingestHASnapshot(baseSnapshot, [frontCam, backyardCam]).length, 0);

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        hasCompletedOnboarding: true,
        haBaseURL: "https://ha.example.invalid:8123",
        haToken: "test-ha-tok-1",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    app.refreshHADevices = async () => {};
    app.devices = [frontCam, backyardCam];

    const doorbellTimer = new FakeTimeoutScheduler();
    const center = getHostActivityCenter(app, { doorbellScheduler: doorbellTimer });
    assert.ok(center);

    await ingestHostHASnapshotForDoorbell(app, baseSnapshot, { isLocked: false });
    assert.equal(app.cameraLive.activeLiveCameraId, null);

    app.cameraLive.openCameraLiveView(backyardCam.id);
    assert.equal(app.cameraLive.activeLiveCameraId, backyardCam.id);

    const ring1Snapshot = {
      ...baseSnapshot,
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-08T10:05:00.000Z",
          attributes: { device_class: "doorbell" },
        },
        {
          entity_id: "event.hidden_doorbell",
          state: "2026-11-08T10:05:00.000Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };
    const respWhileBusy = await ingestHostHASnapshotForDoorbell(app, ring1Snapshot, {
      isLocked: false,
      popupSeconds: 30,
    });
    assert.equal(respWhileBusy.length, 1);
    assert.equal(respWhileBusy[0]?.cameraDeviceId, null);
    assert.equal(app.cameraLive.activeLiveCameraId, backyardCam.id);
    assert.equal(center.doorbellCoordinator.isAutoDismissArmed, false);

    app.cameraLive.closeCameraLiveView();
    assert.equal(app.cameraLive.activeLiveCameraId, null);

    const ring2Snapshot = {
      ...baseSnapshot,
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-08T10:06:00.000Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };
    const respAuto = await ingestHostHASnapshotForDoorbell(app, ring2Snapshot, {
      isLocked: false,
      popupSeconds: 30,
    });
    assert.equal(respAuto[0]?.cameraDeviceId, frontCam.id);
    assert.equal(app.cameraLive.activeLiveCameraId, frontCam.id);
    assert.equal(app.cameraLive.liveCameraHidden, false);
    assert.equal(center.doorbellCoordinator.isAutoDismissArmed, true);

    doorbellTimer.advanceBy(30_000);
    assert.equal(app.cameraLive.liveCameraHidden, true);

    const ring3Snapshot = {
      ...baseSnapshot,
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-08T10:08:00.000Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };
    await ingestHostHASnapshotForDoorbell(app, ring3Snapshot, {
      isLocked: false,
      popupSeconds: 30,
    });
    app.render();
    assert.equal(app.cameraLive.activeLiveCameraId, frontCam.id);
    assert.equal(app.cameraLive.liveCameraHidden, false);
    assert.equal(center.doorbellCoordinator.isAutoDismissArmed, true);

    const sheet = element(".cc-camera-live-sheet");
    sheet.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    assert.equal(center.doorbellCoordinator.isAutoDismissArmed, false);

    doorbellTimer.advanceBy(60_000);
    assert.equal(app.cameraLive.activeLiveCameraId, frontCam.id);
    assert.equal(app.cameraLive.liveCameraHidden, false);

    assert.equal(tickSafetyHealthAndAutomation({}), false);
    const standaloneEngine = new AutomationEngine(new MemoryKV());
    assert.equal(standaloneEngine.snapshot.isLocked, false);
    const standaloneCoord = new DoorbellCameraCoordinator(doorbellTimer);
    assert.equal(standaloneCoord.recentRings.length, 0);
  });

  it("skips cold disk cache / stale / HA error snapshots on telemetry tick and honors local device & room aliases", async () => {
    const offlinePlug = makePlug({ id: "ha:plug_cold", name: "Raw Plug", roomId: "r-kit", roomName: "Raw Kitchen", isOnline: false, isOn: false, powerWatts: null });
    const hotPlug = makePlug({ id: "ha:plug_hot", name: "Raw Kettle", roomId: "r-kit", roomName: "Raw Kitchen", isOn: true, powerWatts: 1600 });
    const light = makeLight({ id: "ha:light_1", name: "Raw Lamp", isOn: true });
    const frontCam = makeCamera({ id: "ha:cam_1", name: "Raw DoorCam", roomId: "r-entry", roomName: "Raw Entry", entityId: "camera.front_door" });

    const app = createCloudApp();
    app.applyCommand = async () => true;
    const kv = new MemoryKV();

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://homeassistant.local:8123";
    app.settings.haToken = "tok-cold";
    app.settings.cachedHAHome = {
      identity: "http://homeassistant.local:8123|tok-cold",
      home: { rooms: [], devices: [structuredClone(offlinePlug)], scenes: [], environmentReadings: [] },
    };
    app.sourceRevision += 1;
    app.devices = [structuredClone(offlinePlug)];
    const center = getHostActivityCenter(app, { storage: kv });
    const t0 = new Date(2026, 10, 8, 12, 0, 0).getTime();

    tickSafetyHealthAndAutomation(app, t0);
    assert.deepEqual(center.offlineHistory.offlineDays(7, t0), {});

    app.haConnectionError = "401 Unauthorized";
    tickSafetyHealthAndAutomation(app, t0 + 1_000);
    assert.deepEqual(center.offlineHistory.offlineDays(7, t0 + 1_000), {});

    app.haConnectionError = null;
    app.timerSnapshot = { sourceRevision: app.sourceRevision, devices: [] } as never;
    app.layout.aliases = {
      [hotPlug.id]: "吧台烧水壶",
      [light.id]: "书桌主灯",
      [frontCam.id]: "入户猫眼",
    };
    app.layout.roomAliases = {
      "r-kit": "西厨岛台",
      "r-entry": "一楼玄关",
    };
    app.devices = [hotPlug, light, frontCam, offlinePlug];

    tickSafetyHealthAndAutomation(app, t0);
    tickSafetyHealthAndAutomation(app, t0 + 46 * 60 * 1000);
    assert.equal(center.recentSafetyAlerts.length, 1);
    assert.match(center.recentSafetyAlerts[0]!.alert.title, /吧台烧水壶/);
    assert.equal(center.offlineHistory.offlineDays(7, t0)[offlinePlug.id], 1);

    const md = await copyWeeklyHealthMarkdown(app);
    assert.match(md, /西厨岛台 · Raw Plug/);

    center.automationEngine.store.save([
      createAutomationRule({
        id: "r-alias",
        trigger: "away",
        action: { kind: "devices", deviceIds: [light.id], isOn: false },
      }),
    ]);
    await dispatchSystemContextEvent(app, { kind: "lockChanged", isLocked: false }, t0);
    const runs = await dispatchSystemContextEvent(app, { kind: "lockChanged", isLocked: true }, t0 + 5_000);
    assert.equal(runs.length, 1);
    assert.match(runs[0]!.summary, /书桌主灯/);

    const baseSnap = {
      entities: [{ entity_id: "event.front_doorbell", device_id: "dev_cam" }, { entity_id: "camera.front_door", device_id: "dev_cam" }],
      states: [{ entity_id: "event.front_doorbell", state: "2026-11-08T12:00:00Z", attributes: { device_class: "doorbell" } }],
    };
    await ingestHostHASnapshotForDoorbell(app, baseSnap, { isLocked: true });
    await ingestHostHASnapshotForDoorbell(
      app,
      { ...baseSnap, states: [{ entity_id: "event.front_doorbell", state: "2026-11-08T12:05:00Z", attributes: { device_class: "doorbell" } }] },
      { isLocked: true },
    );
    const feed = buildActivityFeed(app, t0 + 6_000);
    const doorbellItem = feed.find((x) => x.kind === "doorbell");
    assert.ok(doorbellItem);
    assert.match(doorbellItem.title, /入户猫眼/);
    assert.equal(doorbellItem.subtitle, "一楼玄关");

    const slugDetector = new DoorbellDetector();
    const cams = [
      makeCamera({ id: "ha:cam_a", entityId: "camera.living_a", name: "Cam A" }),
      makeCamera({ id: "ha:cam_b", entityId: "camera.yard_b", name: "Cam B" }),
    ];
    slugDetector.ingestHASnapshot(
      { states: [{ entity_id: "event._doorbell", state: "2026-11-08T12:00:00Z", attributes: { device_class: "doorbell" } }] },
      cams,
    );
    const emptySlugRings = slugDetector.ingestHASnapshot(
      { states: [{ entity_id: "event._doorbell", state: "2026-11-08T12:01:00Z", attributes: { device_class: "doorbell" } }] },
      cams,
    );
    assert.equal(emptySlugRings.length, 1);
    assert.equal(emptySlugRings[0]!.deviceId, "event._doorbell");

    const highRiskHeater = makePlug({
      id: "ha:heater_plug",
      name: "卧室取暖器",
      isOn: false,
      powerWatts: 0,
    });
    const sentHighRisk: DeviceCommand[] = [];
    app.devices = [highRiskHeater];
    app.applyCommand = async (cmd) => {
      sentHighRisk.push(cmd);
      return true;
    };
    const heaterRule = createAutomationRule({
      id: "r-heater-on",
      trigger: "back",
      action: { kind: "devices", deviceIds: [highRiskHeater.id], isOn: true },
    });
    const highRiskRun = await executeAutomationRule(app, heaterRule, { nowMs: t0 + 10_000 });
    assert.equal(sentHighRisk.length, 0);
    assert.equal(highRiskRun, null);

    app.scenes = [{ id: "scene.sleep", entityId: "scene.sleep", name: "睡眠模式" }];
    app.replyBanner = null;
    app.applyCommand = async () => {
      app.replyBanner = { text: "场景激活失败", source: "Home Assistant", isError: true };
      return false;
    };
    const failedSceneRule = createAutomationRule({
      id: "r-scene-fail",
      trigger: "scheduledTime",
      action: { kind: "scene", sceneId: "scene.sleep" },
    });
    const failedSceneRun = await executeAutomationRule(app, failedSceneRule, { nowMs: t0 + 20_000 });
    assert.equal(failedSceneRun, null);
    const errBanner = app.replyBanner as { readonly text: string; readonly isError?: boolean } | null;
    assert.equal(errBanner?.isError, true);
    assert.equal(errBanner?.text, "场景激活失败");

    const lightA = makeLight({ id: "ha:light_a", name: "灯A", isOn: true });
    const lightB = makeLight({ id: "ha:light_b", name: "灯B", isOn: true });
    app.devices = [lightA, lightB];
    const undoCenter = getHostActivityCenter(app);
    undoCenter.recentAutomationRuns = [
      {
        id: "run-source-switch",
        ruleId: "r-away",
        trigger: "away",
        triggerTitle: "离开电脑",
        summary: "离开电脑 · 已执行",
        steps: [
          { deviceId: lightA.id, commands: [{ kind: "setLightPower", entityId: lightA.id, isOn: true }] },
          { deviceId: lightB.id, commands: [{ kind: "setLightPower", entityId: lightB.id, isOn: true }] },
        ],
        kindSnapshots: new Map([
          [lightA.id, structuredClone(lightA.kind)],
          [lightB.id, structuredClone(lightB.kind)],
        ]),
        scope: undoCenter.scopeKey,
        firedAtMs: t0,
        expiresAtMs: t0 + 300_000,
      },
    ];
    const undoSent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      undoSent.push(cmd);
      app.settings.haBaseURL = "http://other-ha.local:8123";
      app.invalidateSourceControl();
      return true;
    };
    const { executeAutomationCardUndo } = await import("../src/ui/activityStackView.js");
    const undoOk = await executeAutomationCardUndo(app, "run-source-switch", t0 + 1_000);
    assert.equal(undoOk, false);
    assert.equal(undoSent.length, 1);

    const { HomeAssistantSynthesizer } = await import("../src/core/homeAssistant.js");
    const makeMultiSafetySnap = (smokeState: "on" | "off", gasState: "on" | "off") => ({
      areas: [{ area_id: "kitchen", name: "厨房" }],
      devices: [{ id: "generic_combo_dev", name: "Kitchen", model: "TS0205", area_id: "kitchen" }],
      entities: [
        { entity_id: "sensor.kitchen_temp", device_id: "generic_combo_dev" },
        { entity_id: "binary_sensor.kitchen_smoke", device_id: "generic_combo_dev" },
        { entity_id: "binary_sensor.kitchen_gas", device_id: "generic_combo_dev" },
      ],
      states: [
        { entity_id: "sensor.kitchen_temp", state: "24.0", attributes: { device_class: "temperature" } },
        { entity_id: "binary_sensor.kitchen_smoke", state: smokeState, attributes: { device_class: "smoke" } },
        { entity_id: "binary_sensor.kitchen_gas", state: gasState, attributes: { device_class: "gas" } },
      ],
    });
    const gasOn1 = HomeAssistantSynthesizer.synthesize(makeMultiSafetySnap("off", "on")).devices[0]!;
    const gasOff = HomeAssistantSynthesizer.synthesize(makeMultiSafetySnap("off", "off")).devices[0]!;
    const gasOn2 = HomeAssistantSynthesizer.synthesize(makeMultiSafetySnap("off", "on")).devices[0]!;

    const monitor = new SafetyMonitor(new MemoryKV(), "ha:home-1");
    const policy = createDefaultSensorAlertPolicy();
    assert.equal(
      monitor.evaluate({ devices: [gasOn1], favorites: new Set(), sensorPolicy: policy, nowMs: t0 }).length,
      1,
    );
    assert.equal(
      monitor.evaluate({ devices: [gasOff], favorites: new Set(), sensorPolicy: policy, nowMs: t0 + 5_000 }).length,
      0,
    );
    assert.equal(
      monitor.evaluate({ devices: [gasOn2], favorites: new Set(), sensorPolicy: policy, nowMs: t0 + 10_000 }).length,
      1,
    );

    monitor.resetSessionState("ha:home-2");
    assert.equal(
      monitor.evaluate({ devices: [gasOn2], favorites: new Set(), sensorPolicy: policy, nowMs: t0 + 15_000 }).length,
      1,
    );

    const r1 = createAutomationRule({
      id: "r-dispatch-1",
      trigger: "screenUnlocked",
      action: { kind: "devices", deviceIds: [lightA.id], isOn: false },
    });
    const r2 = createAutomationRule({
      id: "r-dispatch-2",
      trigger: "screenUnlocked",
      action: { kind: "devices", deviceIds: [lightB.id], isOn: false },
    });
    let dispatchedRules = 0;
    const revHost = {
      devices: [lightA, lightB],
      scenes: [],
      sourceRevision: 10,
      applyCommand: async () => {
        dispatchedRules += 1;
        revHost.sourceRevision = 11;
        return true;
      },
      executeScene: async () => true,
    };
    const eng = new AutomationEngine(new MemoryKV());
    await eng.dispatchEvent(revHost, { kind: "lockChanged", isLocked: true }, { rules: [r1, r2], nowMs: t0 + 40_000 });
    const revRuns = await eng.dispatchEvent(
      revHost,
      { kind: "lockChanged", isLocked: false },
      { rules: [r1, r2], nowMs: t0 + 50_000 },
    );
    assert.equal(dispatchedRules, 1);
    assert.equal(revRuns.length, 0);
  });
});
