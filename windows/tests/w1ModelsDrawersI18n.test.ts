import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { deviceSvgIcon } from "../src/ui/deviceViews.js";
import { homeAssistantIdentity } from "../src/core/homeAssistant.js";
import {
  catalogKeys,
  currentLanguage,
  languageFromTag,
  resolveLanguage,
  setLanguage,
  speechLocale,
  speechLocaleFor,
  t,
  zhHantEntry,
  type AppLanguage,
} from "../src/core/i18n.js";
import {
  FAULT_KEYS,
  PROGRAMME_KEYS,
  applianceFaultNotice,
  computeTotalPowerWatts,
  devicePresentsAsActive,
  deviceStatusSummary,
  displayMiotValue,
  localizeApplianceMode,
  localizeApplianceStatus,
  type ApplianceSpec,
  type DeviceKind,
  type SpeakerSpec,
  type SmartDevice,
} from "../src/core/models.js";
import { parseMiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { facetServiceTitle, lockedControlIdForAlert } from "../src/core/miCloud/feedAction.js";
import { facetAlertText } from "../src/core/miotFacetText.js";
import type { FacetControl } from "../src/core/models.js";

let dom: Window | null = null;

function withLang<T>(lang: AppLanguage, fn: () => T): T {
  const prev = currentLanguage();
  setLanguage(lang);
  try {
    return fn();
  } finally {
    setLanguage(prev);
  }
}

function makeDevice(
  id: string,
  kind: DeviceKind,
  overrides: Partial<Omit<SmartDevice, "id" | "kind">> = {},
): SmartDevice {
  return {
    id,
    name: overrides.name ?? id,
    roomId: overrides.roomId ?? "living",
    roomName: overrides.roomName ?? "客厅",
    model: overrides.model ?? "xiaomi.dev.v1",
    isOnline: overrides.isOnline ?? true,
    kind,
  };
}

function makeApplianceSpec(overrides: Partial<ApplianceSpec> = {}): ApplianceSpec {
  return {
    kind: "appliance",
    entityId: "select.washer_mode",
    isOn: true,
    powerPresent: true,
    powerWritable: true,
    currentMode: "Quick Wash",
    availableModes: ["Quick Wash", "Delicate Wash", "Heavy Wash"],
    modeWritable: true,
    targetTemperature: null,
    currentTemperature: null,
    minTemp: 20,
    maxTemp: 90,
    step: 10,
    temperatureWritable: false,
    statusText: null,
    faultText: null,
    remainingMinutes: null,
    startAction: null,
    pauseAction: null,
    stopAction: null,
    powerEntityId: "switch.washer",
    modeEntityId: "select.washer_mode",
    temperatureEntityId: "climate.washer_temp",
    light: null,
    fanLevel: null,
    currentHumidity: null,
    symbolName: "washer",
    roomReading: false,
    heats: false,
    ...overrides,
  };
}

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
}

interface MountedHA {
  readonly app: MenuMijiaWindowsApp;
  readonly serviceCalls: Array<{
    domain: string;
    service: string;
    entity_id: string;
    data: Record<string, unknown>;
  }>;
}

async function mountHADevices(
  devices: SmartDevice[],
  extraSettings: Record<string, unknown> = {},
): Promise<MountedHA> {
  const haBaseURL = "https://ha.example.test";
  const haToken = "test-ha-token";
  const serviceCalls: Array<{
    domain: string;
    service: string;
    entity_id: string;
    data: Record<string, unknown>;
  }> = [];
  const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (command === "ha_execute") {
      const call = args.command as {
        domain: string;
        service: string;
        entity_id: string;
        data: Record<string, unknown>;
      };
      serviceCalls.push(call);
      return null;
    }
    if (command === "ha_snapshot") {
      return { areas: [], devices: [], entities: [], states: [] };
    }
    return undefined;
  };
  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({
      connectionMode: "homeAssistant",
      hasCompletedOnboarding: true,
      haBaseURL,
      cachedHAHome: {
        identity: homeAssistantIdentity(haBaseURL, haToken),
        home: { devices, scenes: [], environmentReadings: [] },
      },
      ...extraSettings,
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  await setImmediate();
  await setImmediate();
  app.settings.haToken = haToken;
  app.devices = structuredClone(devices);
  app.render();
  await setImmediate();
  return { app, serviceCalls };
}

beforeEach(() => {
  setLanguage("zh-Hans");
});

afterEach(async () => {
  setLanguage("zh-Hans");
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

describe("A6 computeTotalPowerWatts + 30+ semantic SVG icons", () => {
  it("counts only online, switched-on plugs that participate in total power", () => {
    const devices: SmartDevice[] = [
      makeDevice("online-on", { kind: "plug", switchEntityId: "switch.p1", isOn: true, powerWatts: 125.5, childLockEntityId: null, isChildLocked: false}),
      makeDevice("online-on-2", { kind: "plug", switchEntityId: "switch.p2", isOn: true, powerWatts: 44.5, childLockEntityId: null, isChildLocked: false}),
      makeDevice("online-off-residual", { kind: "plug", switchEntityId: "switch.p3", isOn: false, powerWatts: 88, childLockEntityId: null, isChildLocked: false}),
      makeDevice( "offline-on", { kind: "plug", switchEntityId: "switch.p4", isOn: true, powerWatts: 300, childLockEntityId: null, isChildLocked: false}, { isOnline: false }, ),
      makeDevice("mains-breaker", { kind: "plug", switchEntityId: "switch.breaker", isOn: true, powerWatts: 1800, childLockEntityId: null, isChildLocked: false, countsInTotalPower: false}),
      makeDevice("zero-and-negative", { kind: "plug", switchEntityId: "switch.p5", isOn: true, powerWatts: -5, childLockEntityId: null, isChildLocked: false}),
      makeDevice("null-watts", { kind: "plug", switchEntityId: "switch.p6", isOn: true, powerWatts: null, childLockEntityId: null, isChildLocked: false}),
      makeDevice("light-ignored", { kind: "light", entityId: "light.l1", isOn: true, brightnessPercent: 100, colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []}),
    ];

    assert.equal(computeTotalPowerWatts(devices), 170);
  });

  it("wires computeTotalPowerWatts into MenuMijiaWindowsApp environment strip", async () => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.update.v1",
      JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
    );
    const devices: SmartDevice[] = [
      makeDevice("temp-1", { kind: "sensor", temperature: 24.5, humidity: 50, battery: 90}),
      makeDevice("plug-live", { kind: "plug", switchEntityId: "switch.live", isOn: true, powerWatts: 62, childLockEntityId: null, isChildLocked: false}),
      makeDevice("plug-off", { kind: "plug", switchEntityId: "switch.off", isOn: false, powerWatts: 500, childLockEntityId: null, isChildLocked: false}),
      makeDevice( "plug-offline", { kind: "plug", switchEntityId: "switch.offline", isOn: true, powerWatts: 900, childLockEntityId: null, isChildLocked: false}, { isOnline: false }, ),
    ];
    await mountHADevices(devices);
    const stripText = document.querySelector(".cc-env-strip")?.textContent ?? "";
    assert.match(stripText, /62W/);
    assert.doesNotMatch(stripText, /562W|962W|1462W/);
  });

  it("provides 30+ distinct semantic inline SVGs across device kinds, subtypes, and appliances", () => {
    const samples: Array<[string, SmartDevice]> = [
      [
        "light-on",
        makeDevice("l1", { kind: "light", entityId: "light.l1", isOn: true, brightnessPercent: 80, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []}),
      ],
      [
        "light-off",
        makeDevice("l2", { kind: "light", entityId: "light.l2", isOn: false, brightnessPercent: 0, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []}),
      ],
      [
        "light-strip",
        makeDevice( "l3", { kind: "light", entityId: "light.strip", isOn: true, brightnessPercent: 60, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []}, { model: "yeelink.light.strip6", name: "氛围灯带" }, ),
      ],
      [
        "ac-on",
        makeDevice("c1", { kind: "climate", entityId: "climate.ac", isOn: true, hvacMode: "cool", availableModes: ["cool"], targetTemperature: 26, currentTemperature: 28, minTemp: 16, maxTemp: 30, step: 1, fanMode: null, availableFanModes: []}),
      ],
      [
        "ac-off",
        makeDevice("c2", { kind: "climate", entityId: "climate.ac2", isOn: false, hvacMode: "off", availableModes: ["cool"], targetTemperature: 26, currentTemperature: 28, minTemp: 16, maxTemp: 30, step: 1, fanMode: null, availableFanModes: []}),
      ],
      [
        "heater",
        makeDevice( "c3", { kind: "climate", entityId: "climate.heater", isOn: true, hvacMode: "heat", availableModes: ["heat"], targetTemperature: 24, currentTemperature: 18, minTemp: 16, maxTemp: 32, step: 1, fanMode: null, availableFanModes: []}, { model: "zhimi.heater.ma3", name: "取暖器" }, ),
      ],
      [
        "blanket",
        makeDevice( "c4", { kind: "climate", entityId: "climate.blanket", isOn: true, hvacMode: "heat", availableModes: ["heat"], targetTemperature: 38, currentTemperature: 34, minTemp: 25, maxTemp: 55, step: 1, fanMode: null, availableFanModes: []}, { model: "qushui.blanket.mj1", name: "水暖毯" }, ),
      ],
      [
        "fan-floor",
        makeDevice("f1", { kind: "fan", entityId: "fan.f1", isOn: true, percentage: 50, presetMode: null, availablePresetModes: [], isOscillating: false}),
      ],
      [
        "air-purifier",
        makeDevice( "f2", { kind: "fan", entityId: "fan.airp", isOn: true, percentage: 40, presetMode: "Auto", availablePresetModes: ["Auto"], isOscillating: null, pm25Density: 12}, { model: "zhimi.airp.va2", name: "空气净化器" }, ),
      ],
      [
        "dehumidifier",
        makeDevice( "f3", { kind: "fan", entityId: "fan.derh", isOn: true, percentage: null, presetMode: null, availablePresetModes: [], isOscillating: null}, { model: "dmaker.derh.22l", name: "除湿机" }, ),
      ],
      [
        "humidifier",
        makeDevice( "f4", { kind: "fan", entityId: "fan.hum", isOn: true, percentage: null, presetMode: null, availablePresetModes: [], isOscillating: null}, { model: "zhimi.humidifier.ca4", name: "加湿器" }, ),
      ],
      [
        "fresh-air",
        makeDevice( "f5", { kind: "fan", entityId: "fan.fresh", isOn: true, percentage: null, presetMode: null, availablePresetModes: [], isOscillating: null}, { model: "dmaker.airfresh.a1", name: "新风机" }, ),
      ],
      [
        "plug-outlet",
        makeDevice("p1", { kind: "plug", switchEntityId: "switch.outlet", isOn: true, powerWatts: 15, childLockEntityId: null, isChildLocked: false}),
      ],
      [
        "wall-switch",
        makeDevice( "p2", { kind: "plug", switchEntityId: "switch.wall", isOn: true, powerWatts: null, childLockEntityId: null, isChildLocked: false}, { model: "lumi.switch.b2naus01", name: "墙壁开关" }, ),
      ],
      [
        "diffuser",
        makeDevice( "p3", { kind: "plug", switchEntityId: "switch.diff", isOn: true, powerWatts: null, childLockEntityId: null, isChildLocked: false}, { model: "hl.diffuser.x1", name: "香氛机" }, ),
      ],
      [
        "coffee-machine",
        makeDevice( "p4", { kind: "plug", switchEntityId: "switch.coffee", isOn: true, powerWatts: 1100, childLockEntityId: null, isChildLocked: false}, { name: "胶囊咖啡机" }, ),
      ],
      [
        "desktop-wol",
        makeDevice( "p5", { kind: "plug", switchEntityId: "button.wake_on_lan_pc", isOn: false, powerWatts: null, childLockEntityId: null, isChildLocked: false}, { name: "书房电脑" }, ),
      ],
      [
        "button-power",
        makeDevice( "p6", { kind: "plug", switchEntityId: "button.reboot_gateway", isOn: false, powerWatts: null, childLockEntityId: null, isChildLocked: false}, { name: "重启按钮" }, ),
      ],
      [
        "fridge",
        makeDevice("fr1", { kind: "fridge", modeEntityId: null, currentMode: "smart", availableModes: [], fridgeCurrentTemp: 4, fridgeTargetTemp: 4, fridgeTargetEntityId: null, freezerCurrentTemp: -18, freezerTargetTemp: -18, freezerTargetEntityId: null}),
      ],
      [
        "vacuum",
        makeDevice("v1", { kind: "vacuum", entityId: "vacuum.v1", status: "cleaning", battery: 85, modeEntityId: null, currentMode: null, availableModes: []}),
      ],
      [
        "speaker-active",
        makeDevice("sp1", { kind: "speaker", mediaEntityId: "media_player.sp1", state: "playing", volumePercent: 40, isMuted: false, muteSwitchEntityId: null, sleepModeEntityId: null, isSleepMode: false, volumeWritable: true}),
      ],
      [
        "speaker-muted",
        makeDevice("sp2", { kind: "speaker", mediaEntityId: "media_player.sp2", state: "idle", volumePercent: 20, isMuted: true, muteSwitchEntityId: null, sleepModeEntityId: null, isSleepMode: false, volumeWritable: true}),
      ],
      [
        "camera-on",
        makeDevice("cam1", { kind: "camera", entityId: "camera.c1", isOn: true, nightShot: null, availableNightShots: [], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null}),
      ],
      [
        "camera-sleep",
        makeDevice("cam2", { kind: "camera", entityId: "camera.c2", isOn: false, nightShot: null, availableNightShots: [], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null}),
      ],
      [
        "doorbell",
        makeDevice( "cam3", { kind: "camera", entityId: "camera.bell", isOn: true, nightShot: null, availableNightShots: [], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null}, { model: "madv.cateye.v3", name: "智能门铃" }, ),
      ],
      [
        "sensor-thermo",
        makeDevice("s1", { kind: "sensor", temperature: 23.4, humidity: 52, battery: 88}),
      ],
      [
        "sensor-lock",
        makeDevice( "s2", { kind: "sensor", temperature: null, humidity: null, battery: 95, statusText: "已上锁"}, { model: "xiaomi.lock.pro", name: "智能门锁" }, ),
      ],
      [
        "sensor-kettle",
        makeDevice( "s3", { kind: "sensor", temperature: null, humidity: null, battery: null, statusText: "保温监控"}, { model: "yunmi.kettle.r3", name: "恒温电水壶" }, ),
      ],
      [
        "sensor-fryer",
        makeDevice( "s4", { kind: "sensor", temperature: null, humidity: null, battery: null, statusText: "待机"}, { model: "careli.fryer.maf07", name: "空气炸锅" }, ),
      ],
      [
        "sensor-cooker",
        makeDevice( "s5", { kind: "sensor", temperature: null, humidity: null, battery: null, statusText: "运行中"}, { model: "chunmi.cooker.normal2", name: "电饭煲" }, ),
      ],
      [
        "sensor-motion",
        makeDevice( "s6", { kind: "sensor", temperature: null, humidity: null, battery: 100, statusText: "有人移动"}, { model: "lumi.motion.bmgl01", name: "人体传感器" }, ),
      ],
      [
        "sensor-magnet",
        makeDevice( "s7", { kind: "sensor", temperature: null, humidity: null, battery: 100, statusText: "已闭合"}, { model: "isa.magnet.dw2hl", name: "门窗传感器" }, ),
      ],
      [
        "sensor-leak",
        makeDevice( "s8", { kind: "sensor", temperature: null, humidity: null, battery: 100, statusText: "浸水告警"}, { model: "lumi.sensor_wleak.aq1", name: "水浸传感器" }, ),
      ],
      [
        "sensor-smoke",
        makeDevice( "s9", { kind: "sensor", temperature: null, humidity: null, battery: 100, statusText: "正常"}, { model: "lumi.sensor_smoke.v1", name: "烟雾报警器" }, ),
      ],
      [
        "sensor-gas",
        makeDevice( "s10", { kind: "sensor", temperature: null, humidity: null, battery: null, statusText: "正常"}, { model: "lumi.sensor_gas.v1", name: "燃气卫士" }, ),
      ],
      [
        "sensor-lux",
        makeDevice( "s11", { kind: "sensor", temperature: null, humidity: null, battery: 90, statusText: "320 lx"}, { model: "lumi.sen_ill.mgl01", name: "光照传感器" }, ),
      ],
      [
        "sensor-radar",
        makeDevice("s12", { kind: "sensor", temperature: null, humidity: null, battery: null, statusText: "在线"}),
      ],
      [
        "cover-curtain-open",
        makeDevice("cv1", { kind: "cover", entityId: "cover.c1", subtype: "curtain", positionPercent: 80, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause", batteryPercent: null, faultText: null, motion: "stopped"}),
      ],
      [
        "cover-curtain-closed",
        makeDevice("cv2", { kind: "cover", entityId: "cover.c2", subtype: "curtain", positionPercent: 0, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause", batteryPercent: null, faultText: null, motion: "stopped"}),
      ],
      [
        "cover-window",
        makeDevice("cv3", { kind: "cover", entityId: "cover.win", subtype: "window-opener", positionPercent: 50, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause", batteryPercent: null, faultText: null, motion: "stopped"}),
      ],
      [
        "cover-garage",
        makeDevice("cv4", { kind: "cover", entityId: "cover.garage", subtype: "garage-door", positionPercent: 0, positionWritable: false, openDescription: "Open", closeDescription: "Close", pauseDescription: "Stop", batteryPercent: null, faultText: null, motion: "stopped"}),
      ],
      [
        "cover-airer",
        makeDevice("cv5", { kind: "cover", entityId: "cover.airer", subtype: "clothes-airer", positionPercent: 100, positionWritable: true, openDescription: "Up", closeDescription: "Down", pauseDescription: "Pause", batteryPercent: null, faultText: null, motion: "stopped"}),
      ],
      ["app-washer", makeDevice("a1", makeApplianceSpec({ symbolName: "washer" }), { name: "洗衣机" })],
      ["app-dryer", makeDevice("a2", makeApplianceSpec({ symbolName: "dryer" }), { name: "干衣机" })],
      ["app-dishwasher", makeDevice("a3", makeApplianceSpec({ symbolName: "dishwasher" }), { name: "洗碗机" })],
      ["app-water-heater", makeDevice("a4", makeApplianceSpec({ symbolName: "water.waves" }), { name: "电热水器" })],
      ["app-bath-heater", makeDevice("a5", makeApplianceSpec({ symbolName: "sun.max.fill" }), { name: "智能浴霸" })],
      ["app-range-hood", makeDevice("a6", makeApplianceSpec({ symbolName: null }), { name: "烟灶油烟机" })],
      ["app-default", makeDevice("a7", makeApplianceSpec({ symbolName: null }), { name: "定制电器", model: "vendor.custom.v1" })],
      [
        "gen-fish",
        makeDevice( "g1", { kind: "generic", deviceType: "fish-tank", typeTitle: "鱼缸", isOn: true, powerControl: null, readouts: [], isReadOnly: false, symbolName: "fish.fill"}, { name: "智能鱼缸" }, ),
      ],
      [
        "gen-pet",
        makeDevice( "g2", { kind: "generic", deviceType: "pet-feeder", typeTitle: "喂食器", isOn: true, powerControl: null, readouts: [], isReadOnly: false, symbolName: "pawprint.fill"}, { name: "宠物喂食器" }, ),
      ],
      [
        "gen-tv",
        makeDevice( "g3", { kind: "generic", deviceType: "television", typeTitle: "电视", isOn: true, powerControl: null, readouts: [], isReadOnly: true, symbolName: "tv"}, { name: "客厅电视" }, ),
      ],
      [
        "gen-grid",
        makeDevice( "g4", { kind: "generic", deviceType: "custom-box", typeTitle: "通用", isOn: false, powerControl: null, readouts: [], isReadOnly: true, symbolName: "square.grid.2x2"}, { name: "扩展模块" }, ),
      ],
    ];

    const byKey = new Map<string, string>();
    for (const [label, dev] of samples) {
      const svg = deviceSvgIcon(dev);
      assert.match(svg, /^<svg\b[\s\S]*<\/svg>$/, `${label} must render a valid inline SVG`);
      byKey.set(label, svg);
    }

    const distinctCount = new Set(byKey.values()).size;
    assert.ok(distinctCount >= 35, `Expected >= 35 distinct SVGs, got ${distinctCount}`);
    assert.notEqual(byKey.get("fridge"), byKey.get("ac-on"), "Fridge must not borrow AC snowflake");
    assert.notEqual(byKey.get("sensor-thermo"), byKey.get("cover-curtain-open"));
    assert.notEqual(byKey.get("sensor-thermo"), byKey.get("app-washer"));
    assert.notEqual(byKey.get("sensor-thermo"), byKey.get("gen-grid"));
    assert.notEqual(byKey.get("cover-curtain-open"), byKey.get("cover-airer"));
    assert.notEqual(byKey.get("cover-window"), byKey.get("cover-garage"));
  });
});

describe("devicePresentsAsActive extinguishes stale and offline highlights", () => {
  it("returns false when valuesAreStale or offline, matching DeviceReadout.swift", () => {
    const onlineLight = makeDevice("l1", { kind: "light", entityId: "light.l1", isOn: true, brightnessPercent: 80, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []});
    const offlineLight = { ...onlineLight, isOnline: false };
    const offLight = makeDevice("l2", { kind: "light", entityId: "light.l2", isOn: false, brightnessPercent: 0, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []});

    assert.equal(devicePresentsAsActive(onlineLight, false), true);
    assert.equal(devicePresentsAsActive(onlineLight, true), false);
    assert.equal(devicePresentsAsActive(offlineLight, false), false);
    assert.equal(devicePresentsAsActive(offLight, false), false);
  });

  it("drops .is-active on stale and offline tiles in DOM while keeping waiting tiles lit", async () => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.update.v1",
      JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
    );
    const devices: SmartDevice[] = [
      makeDevice("light-live", { kind: "light", entityId: "light.live", isOn: true, brightnessPercent: 75, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []}),
      makeDevice("ac-live", { kind: "climate", entityId: "climate.live", isOn: true, hvacMode: "cool", availableModes: ["cool", "off"], targetTemperature: 25, currentTemperature: 27, minTemp: 16, maxTemp: 30, step: 1, fanMode: null, availableFanModes: []}),
      makeDevice( "plug-offline-cached-on", { kind: "plug", switchEntityId: "switch.offline", isOn: true, powerWatts: 50, childLockEntityId: null, isChildLocked: false}, { isOnline: false }, ),
    ];

    const { app } = await mountHADevices(devices);
    assert.equal(element('[data-tile-id="light-live"]').classList.contains("is-active"), true);
    assert.equal(element('[data-tile-id="ac-live"]').classList.contains("is-active"), true);
    assert.equal(
      element('[data-tile-id="plug-offline-cached-on"]').classList.contains("is-active"),
      false,
      "Offline tile must never keep cached .is-active highlight",
    );

    app.haConnectionError = "Connection timed out";
    app.render();
    assert.equal(element('[data-tile-id="light-live"]').classList.contains("is-active"), false);
    assert.equal(element('[data-tile-id="light-live"]').classList.contains("is-stale"), true);
    assert.equal(element('[data-tile-id="ac-live"]').classList.contains("is-active"), false);

    app.haConnectionError = null;
    app.settings.connectionMode = "xiaomiCloud";
    app.cloudValuesStale = true;
    app.render();
    assert.equal(element('[data-tile-id="light-live"]').classList.contains("is-active"), false);
    assert.equal(element('[data-tile-id="ac-live"]').classList.contains("is-active"), false);

    app.waitingDeviceIds.add("light-live");
    app.render();
    assert.equal(element('[data-tile-id="light-live"]').classList.contains("is-active"), true);
  });
});

describe("A5 washer/dryer programmes, 27 fault notices, >4 mode <select>, and fault copy", () => {
  it("translates all MIoT washer/dryer programmes neutrally across zh-Hans, zh-Hant, and en", () => {
    assert.ok(PROGRAMME_KEYS.length >= 25);

    withLang("zh-Hans", () => {
      assert.equal(displayMiotValue("Quick Wash"), "快速洗");
      assert.equal(displayMiotValue("Delicate Wash"), "轻柔洗");
      assert.equal(displayMiotValue("Heavy Wash"), "大件洗");
      assert.equal(displayMiotValue("Rinse-Spin"), "漂加脱");
      assert.equal(displayMiotValue("Spin"), "单脱水");
      assert.equal(displayMiotValue("Drum Clean"), "筒清洁");
      assert.equal(displayMiotValue("Down Coat"), "羽绒");
      assert.equal(displayMiotValue("Synthetic"), "化纤");
      assert.equal(displayMiotValue("User Define"), "自定义");
      assert.equal(displayMiotValue("Level2"), "2 档");
      assert.equal(localizeApplianceMode("Night"), "夜晚");
      assert.equal(localizeApplianceMode("Quick"), "快速");
      assert.equal(localizeApplianceMode("Quick Wash"), "快速洗");

      for (const key of PROGRAMME_KEYS) {
        const text = displayMiotValue(key);
        assert.notEqual(text, key, `${key} should translate in zh-Hans`);
        if (!key.includes("wash") && !key.includes("rinse") && !key.includes("spin")) {
          assert.ok(!text.includes("洗"), `${key} -> ${text} must stay dryer-neutral`);
        }
      }
    });

    withLang("zh-Hant", () => {
      assert.equal(displayMiotValue("Delicate Wash"), "輕柔洗");
      assert.equal(displayMiotValue("Rinse Spin"), "漂加脫");
      assert.equal(displayMiotValue("Drum Clean"), "筒清潔");
      assert.equal(displayMiotValue("Down Coat"), "羽絨");
      assert.equal(displayMiotValue("User Define"), "自訂");
      assert.equal(displayMiotValue("Level 3"), "3 檔");
    });

    withLang("en", () => {
      assert.equal(displayMiotValue("Quick Wash"), "Quick Wash");
      assert.equal(displayMiotValue("Level1"), "Level1");
      assert.equal(localizeApplianceStatus("洗涤中"), "Washing");
      assert.equal(localizeApplianceStatus("烘干中"), "Drying");
    });
  });

  it("formats all 27 MIoT appliance faults, bare codes, and unknown faults in all 3 languages", () => {
    assert.equal(FAULT_KEYS.length, 27);
    for (const key of FAULT_KEYS) {
      withLang("zh-Hans", () => {
        const notice = applianceFaultNotice(key);
        assert.match(notice.message, /^故障 /);
        assert.ok(notice.copyText.length > 0);
      });
      withLang("zh-Hant", () => {
        const notice = applianceFaultNotice(key);
        assert.match(notice.message, /^故障 /);
      });
      withLang("en", () => {
        const notice = applianceFaultNotice(key);
        assert.match(notice.message, /^Fault /);
      });
    }

    withLang("zh-Hans", () => {
      assert.deepEqual(applianceFaultNotice("Dehydration Fault"), {
        message: "故障 E3 · 衣物分布不平衡",
        copyText: "E3",
      });
      assert.deepEqual(applianceFaultNotice("Water Draining Malfunction"), {
        message: "故障 · 排水故障",
        copyText: "Water Draining Malfunction",
      });
      assert.deepEqual(applianceFaultNotice("FC2"), {
        message: "设备上报故障代码 FC2，请查看说明书或米家 App",
        copyText: "FC2",
      });
      assert.deepEqual(applianceFaultNotice("Custom Sensor Jam"), {
        message: "设备上报故障「Custom Sensor Jam」，请查看说明书或米家 App",
        copyText: "Custom Sensor Jam",
      });
    });

    withLang("zh-Hant", () => {
      assert.deepEqual(applianceFaultNotice("Dehydration Fault"), {
        message: "故障 E3 · 衣物分佈不平衡",
        copyText: "E3",
      });
      assert.deepEqual(applianceFaultNotice("E3"), {
        message: "裝置回報故障代碼 E3，請查看說明書或米家 App",
        copyText: "E3",
      });
    });

    withLang("en", () => {
      assert.deepEqual(applianceFaultNotice("Dehydration Fault"), {
        message: "Fault E3 · Dehydration Fault",
        copyText: "E3",
      });
      assert.deepEqual(applianceFaultNotice("E3"), {
        message: "The device reported fault code E3. Check the manual or the Mi Home app.",
        copyText: "E3",
      });
    });

    const washer = makeDevice("w1", makeApplianceSpec({ currentMode: "Down Coat", statusText: "洗涤中", faultText: "Dehydration Fault"}));
    withLang("zh-Hans", () => {
      assert.equal(deviceStatusSummary(washer), "羽绒 · 洗涤中 · 故障 E3 · 衣物分布不平衡");
    });
    withLang("zh-Hant", () => {
      assert.equal(deviceStatusSummary(washer), "羽絨 · 洗滌中 · 故障 E3 · 衣物分佈不平衡");
    });
    withLang("en", () => {
      assert.equal(deviceStatusSummary(washer), "Down Coat · Washing · Fault E3 · Dehydration Fault");
    });
  });

  it("switches >4 appliance modes to a compact <select>, keeps <=4 as pills, and copies fault codes", async () => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.update.v1",
      JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
    );
    const copiedTexts: string[] = [];
    Object.defineProperty(window.navigator, "clipboard", {
      value: {
        writeText: async (text: string) => {
          copiedTexts.push(text);
        },
      },
      configurable: true,
    });

    const fourModeDryer = makeDevice("dryer-4", makeApplianceSpec({ entityId: "select.dryer_mode", modeEntityId: "select.dryer_mode", currentMode: "Mix", availableModes: ["Mix", "Quick Wash", "Wool", "Cotton"]}), { name: "四档烘干机" });

    const eightModeWasher = makeDevice("washer-8", makeApplianceSpec({
      entityId: "select.washer_mode",
      modeEntityId: "select.washer_mode",
      currentMode: null,
      availableModes: [
        "Mix",
        "Quick Wash",
        "Delicate Wash",
        "Heavy Wash",
        "Down Coat",
        "Drum Clean",
        "Baby Care",
        "Wool",
      ],
      statusText: "洗涤中",
      faultText: "Dehydration Fault",
    }), { name: "八档洗衣机" });

    const { app, serviceCalls } = await mountHADevices([fourModeDryer, eightModeWasher]);

    app.expandedDeviceId = "dryer-4";
    app.render();
    assert.equal(document.querySelectorAll('[data-appliancemode^="dryer-4|"]').length, 4);
    assert.equal(document.querySelector('[data-appliancemode-select="dryer-4"]'), null);

    app.expandedDeviceId = "washer-8";
    app.render();
    assert.equal(document.querySelectorAll('[data-appliancemode^="washer-8|"]').length, 0);
    const select = element<HTMLSelectElement>('[data-appliancemode-select="washer-8"]');
    const optionLabels = Array.from(select.options).map((o) => o.textContent);
    assert.deepEqual(optionLabels, [
      "未选择",
      "混合",
      "快速洗",
      "轻柔洗",
      "大件洗",
      "羽绒",
      "筒清洁",
      "婴童",
      "羊毛",
    ]);

    select.value = "Down Coat";
    select.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(serviceCalls.length, 1);
    assert.deepEqual(serviceCalls[0], {
      domain: "select",
      service: "select_option",
      entity_id: "select.washer_mode",
      data: { option: "Down Coat" },
    });

    const faultBanner = element(".cc-appliance-fault");
    assert.match(faultBanner.textContent ?? "", /故障 E3 · 衣物分布不平衡/);
    const copyBtn = element<HTMLButtonElement>('[data-copy-fault="E3"]');
    assert.equal(copyBtn.textContent, "复制代码");
    copyBtn.click();
    await setImmediate();
    assert.deepEqual(copiedTexts, ["E3"]);
    assert.equal(copyBtn.textContent, "已复制");
    assert.equal(copyBtn.dataset.copied, "true");

    Object.defineProperty(window.navigator, "clipboard", {
      value: {
        writeText: async () => {
          throw new Error("Clipboard denied");
        },
      },
      configurable: true,
    });
    copyBtn.textContent = "复制代码";
    delete copyBtn.dataset.copied;
    copyBtn.click();
    await setImmediate();
    assert.equal(copyBtn.textContent, "已复制");
  });

  it("gates >4 mode <select> on standby heating appliances behind high-risk confirmation", async () => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.update.v1",
      JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
    );
    const bathHeater = makeDevice("bath-5", makeApplianceSpec({ entityId: "select.bath_mode", modeEntityId: "select.bath_mode", isOn: false, heats: true, currentMode: "Idle", availableModes: ["Idle", "Shower", "Heat", "Quick Heat", "Ventilate"], symbolName: "sun.max.fill"}), { name: "智能浴霸" });

    const { app, serviceCalls } = await mountHADevices([bathHeater]);
    app.expandedDeviceId = "bath-5";
    app.render();

    const select = element<HTMLSelectElement>('[data-appliancemode-select="bath-5"]');
    select.value = "Quick Heat";
    select.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(serviceCalls.length, 0, "First selection from standby must arm high-risk confirmation");
    assert.match(app.replyBanner?.text ?? "", /切换到强暖.*再点一次确认执行/);

    const revertedSelect = element<HTMLSelectElement>('[data-appliancemode-select="bath-5"]');
    assert.equal(revertedSelect.value, "Idle", "Unconfirmed selection must revert to currentMode");
    revertedSelect.value = "Quick Heat";
    revertedSelect.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(serviceCalls.length, 1);
    assert.equal(serviceCalls[0]?.data.option, "Quick Heat");
  });
});

describe("A7 Traditional Chinese (zh-Hant) + zero English/Chinese leaks", () => {
  it("covers every catalog key in zhHantCatalog with matching placeholders", () => {
    const placeholderSet = (text: string): string =>
      Array.from(text.matchAll(/\{(\w+)\}/g), (m) => m[1]!)
        .sort()
        .join(",");

    for (const key of catalogKeys()) {
      const hant = zhHantEntry(key);
      assert.ok(hant && hant.trim().length > 0, `Missing zh-Hant translation for: ${key}`);
      assert.equal(
        placeholderSet(hant),
        placeholderSet(key),
        `Placeholder mismatch in zh-Hant for: ${key} -> ${hant}`,
      );
    }

    assert.equal(languageFromTag("zh-TW"), "zh-Hant");
    assert.equal(languageFromTag("zh-HK"), "zh-Hant");
    assert.equal(languageFromTag("zh-MO"), "zh-Hant");
    assert.equal(languageFromTag("zh-Hant-TW"), "zh-Hant");
    assert.equal(languageFromTag("zh_TW"), "zh-Hant");
    assert.equal(languageFromTag("zh-CN"), "zh-Hans");
    assert.equal(resolveLanguage("system", ["zh-TW", "en-US"]), "zh-Hant");
    assert.equal(resolveLanguage("zh-Hant", ["en-US"]), "zh-Hant");
    assert.equal(speechLocaleFor("zh-Hant"), "zh-TW");
    withLang("zh-Hant", () => {
      assert.equal(speechLocale(), "zh-TW");
      assert.equal(t("重命名…"), "重新命名…");
      assert.equal(t("复制代码"), "複製代碼");
    });
  });

  it("persists zh-Hant from Settings and localizes all 7 context-menu buttons in en and zh-Hant", async () => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.update.v1",
      JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
    );
    const dev = makeDevice("light-ctx", { kind: "light", entityId: "light.ctx", isOn: true, brightnessPercent: 50, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: []});
    const { app } = await mountHADevices([dev]);

    app.openSettingsSheet("general");
    const hantBtn = element<HTMLButtonElement>('[data-interface-language="zh-Hant"]');
    assert.equal(hantBtn.textContent, "繁體中文");
    hantBtn.click();
    await setImmediate();

    assert.equal(app.settings.interfaceLanguage, "zh-Hant");
    assert.equal(currentLanguage(), "zh-Hant");
    assert.match(document.body.textContent ?? "", /偏好設定/);
    assert.match(document.body.textContent ?? "", /中國大陸 \(cn\)/);

    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
      interfaceLanguage?: string;
    };
    assert.equal(saved.interfaceLanguage, "zh-Hant");

    const reloaded = new MenuMijiaWindowsApp(element("#app"));
    reloaded.refreshDevices = async () => {};
    reloaded.refreshHADevices = async () => {};
    assert.equal(reloaded.settings.interfaceLanguage, "zh-Hant");
    assert.equal(currentLanguage(), "zh-Hant");

    reloaded.devices = [dev];
    reloaded.layout.groups = [{ id: "g1", name: "照明" }];
    reloaded.layout.groupMap[dev.id] = "g1";
    reloaded.ctxMenu = { x: 20, y: 20, groupId: "g1" };
    reloaded.render();
    let menuText = element(".cc-menu").textContent ?? "";
    assert.match(menuText, /重新命名/);
    assert.match(menuText, /上移分組/);
    assert.match(menuText, /下移分組/);
    assert.match(menuText, /刪除分組/);

    reloaded.ctxMenu = { x: 20, y: 20, deviceId: dev.id };
    reloaded.render();
    menuText = element(".cc-menu").textContent ?? "";
    assert.match(menuText, /不分組/);
    assert.match(menuText, /＋ 新增/);
    assert.match(menuText, /重新命名…/);

    setLanguage("en");
    reloaded.ctxMenu = { x: 20, y: 20, groupId: "g1" };
    reloaded.render();
    menuText = element(".cc-menu").textContent ?? "";
    for (const label of ["Rename", "Move group up", "Move group down", "Delete group"]) {
      assert.ok(menuText.includes(label), `Missing English group menu item: ${label}`);
    }

    reloaded.ctxMenu = { x: 20, y: 20, deviceId: dev.id };
    reloaded.render();
    menuText = element(".cc-menu").textContent ?? "";
    for (const label of ["No group", "＋ New", "Rename…"]) {
      assert.ok(menuText.includes(label), `Missing English device menu item: ${label}`);
    }
  });

  it("localizes synthesis.ts room fallback, sensors, kettle, curtains, and locks without changing zh-Hans", () => {
    const U = (kind: string, name: string, code: string) =>
      `urn:miot-spec-v2:${kind}:${name}:${code}:test:1`;

    const motionSpec = parseMiotDeviceSpec({
      type: U("device", "motion-sensor", "0000A014"),
      services: [
        {
          iid: 2,
          type: U("service", "motion-sensor", "00007825"),
          properties: [
            { iid: 1, type: U("property", "motion-state", "00000043"), format: "bool", access: ["read"] },
            { iid: 2, type: U("property", "illumination", "0000004E"), format: "float", access: ["read"] },
          ],
          actions: [],
        },
      ],
    })!;

    const magnetSpec = parseMiotDeviceSpec({
      type: U("device", "magnet-sensor", "0000A016"),
      services: [
        {
          iid: 2,
          type: U("service", "magnet-sensor", "00007827"),
          properties: [
            { iid: 1, type: U("property", "contact-state", "00000046"), format: "bool", access: ["read"] },
          ],
          actions: [],
        },
      ],
    })!;

    const leakSpec = parseMiotDeviceSpec({
      type: U("device", "submersion-sensor", "0000A027"),
      services: [
        {
          iid: 2,
          type: U("service", "submersion-sensor", "00007839"),
          properties: [
            { iid: 1, type: U("property", "submersion-state", "0000006E"), format: "bool", access: ["read"] },
          ],
          actions: [],
        },
      ],
    })!;

    const kettleSpec = parseMiotDeviceSpec({
      type: U("device", "kettle", "0000A009"),
      services: [
        {
          iid: 2,
          type: U("service", "kettle", "00007813"),
          properties: [
            {
              iid: 1,
              type: U("property", "status", "00000007"),
              format: "uint8",
              access: ["read"],
              "value-list": [
                { value: 0, description: "Idle" },
                { value: 1, description: "Keep Warm" },
              ],
            },
            { iid: 2, type: U("property", "temperature", "00000020"), format: "float", access: ["read"] },
            { iid: 3, type: U("property", "left-time", "0000003C"), format: "uint16", access: ["read"] },
          ],
          actions: [],
        },
      ],
    })!;

    const lockSpec = parseMiotDeviceSpec({
      type: U("device", "lock", "0000A038"),
      services: [
        {
          iid: 2,
          type: U("service", "lock", "00007855"),
          properties: [
            {
              iid: 1,
              type: U("property", "door-state", "00000007"),
              format: "uint8",
              access: ["read"],
              "value-list": [{ value: 1, description: "Locked" }],
            },
          ],
          actions: [],
        },
      ],
    })!;

    const dualCurtainSpec = parseMiotDeviceSpec({
      type: U("device", "curtain", "0000A00C"),
      services: [
        {
          iid: 2,
          type: U("service", "curtain", "00007816"),
          description: "Drape Curtain",
          properties: [
            { iid: 1, type: U("property", "current-position", "00000039"), format: "uint8", access: ["read"] },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: U("service", "curtain", "00007816"),
          description: "Lace Curtain",
          properties: [
            { iid: 1, type: U("property", "current-position", "00000039"), format: "uint8", access: ["read"] },
          ],
          actions: [],
        },
      ],
    })!;

    const records = [
      { did: "m1", name: "Motion", model: "test.motion.v1", isOnline: true, specType: null },
      { did: "mg1", name: "Door", model: "test.magnet.v1", isOnline: true, specType: null },
      { did: "lk1", name: "Leak", model: "test.leak.v1", isOnline: true, specType: null },
      { did: "kt1", name: "Kettle", model: "test.kettle.v1", isOnline: true, specType: null },
      { did: "kt2", name: "KettleEmpty", model: "test.kettle.v1", isOnline: true, specType: null },
      { did: "lo1", name: "LockOnline", model: "test.lock.v1", isOnline: true, specType: null },
      { did: "lo2", name: "LockOffline", model: "test.lock.v1", isOnline: false, specType: null },
      { did: "cu1", name: "Living", model: "test.curtain.v1", isOnline: true, specType: null },
    ];
    const specs = {
      "test.motion.v1": motionSpec,
      "test.magnet.v1": magnetSpec,
      "test.leak.v1": leakSpec,
      "test.kettle.v1": kettleSpec,
      "test.lock.v1": lockSpec,
      "test.curtain.v1": dualCurtainSpec,
    };
    const values = new Map<string, unknown>([
      ["m1.2.1", true],
      ["m1.2.2", 80],
      ["mg1.2.1", true],
      ["lk1.2.1", true],
      ["kt1.2.1", 1],
      ["kt1.2.2", 55],
      ["kt1.2.3", 12],
      ["lo1.2.1", 1],
      ["lo2.2.1", 1],
      ["cu1.2.1", 100],
      ["cu1.3.1", 0],
    ]);

    withLang("zh-Hans", () => {
      const home = MiotSynthesizer.synthesize(records, [], specs, values);
      const byId = new Map(home.devices.map((d) => [d.id, d]));
      assert.equal(byId.get("m1")?.roomName, "全屋");
      assert.equal((byId.get("m1")?.kind as { statusText?: string }).statusText, "有人移动 · 80 lx");
      assert.equal((byId.get("mg1")?.kind as { statusText?: string }).statusText, "已闭合");
      assert.equal((byId.get("lk1")?.kind as { statusText?: string }).statusText, "浸水告警");
      assert.equal(
        (byId.get("kt1")?.kind as { statusText?: string }).statusText,
        "保温中 · 55°C · 剩余 12 分",
      );
      assert.equal((byId.get("kt2")?.kind as { statusText?: string }).statusText, "保温监控");
      assert.equal((byId.get("lo1")?.kind as { statusText?: string }).statusText, "已上锁");
      assert.equal((byId.get("lo2")?.kind as { statusText?: string }).statusText, "锁状态未知");
      assert.equal(byId.get("cu1.s2")?.name, "布帘");
      assert.equal(byId.get("cu1.s3")?.name, "纱帘");
    });

    withLang("zh-Hant", () => {
      const home = MiotSynthesizer.synthesize(records, [], specs, values);
      const byId = new Map(home.devices.map((d) => [d.id, d]));
      assert.equal(byId.get("m1")?.roomName, "全屋");
      assert.equal((byId.get("m1")?.kind as { statusText?: string }).statusText, "有人移動 · 80 lx");
      assert.equal((byId.get("mg1")?.kind as { statusText?: string }).statusText, "已閉合");
      assert.equal((byId.get("lk1")?.kind as { statusText?: string }).statusText, "浸水告警");
      assert.equal(
        (byId.get("kt1")?.kind as { statusText?: string }).statusText,
        "保溫中 · 55°C · 剩餘 12 分",
      );
      assert.equal((byId.get("kt2")?.kind as { statusText?: string }).statusText, "保溫監控");
      assert.equal((byId.get("lo1")?.kind as { statusText?: string }).statusText, "已上鎖");
      assert.equal((byId.get("lo2")?.kind as { statusText?: string }).statusText, "門鎖狀態未知");
      assert.equal(byId.get("cu1.s2")?.name, "布簾");
      assert.equal(byId.get("cu1.s3")?.name, "紗簾");
    });

    withLang("en", () => {
      const home = MiotSynthesizer.synthesize(records, [], specs, values);
      const byId = new Map(home.devices.map((d) => [d.id, d]));
      assert.equal(byId.get("m1")?.roomName, "Whole Home");
      assert.equal((byId.get("m1")?.kind as { statusText?: string }).statusText, "Motion · 80 lx");
      assert.equal((byId.get("mg1")?.kind as { statusText?: string }).statusText, "Closed");
      assert.equal((byId.get("lk1")?.kind as { statusText?: string }).statusText, "Leak Detected");
      assert.equal(
        (byId.get("kt1")?.kind as { statusText?: string }).statusText,
        "Keep Warm · 55°C · 12 min left",
      );
      assert.equal((byId.get("kt2")?.kind as { statusText?: string }).statusText, "Water Monitor");
      assert.equal((byId.get("lo1")?.kind as { statusText?: string }).statusText, "Locked");
      assert.equal(
        (byId.get("lo2")?.kind as { statusText?: string }).statusText,
        "Lock status unknown",
      );
      assert.equal(byId.get("cu1.s2")?.name, "Drape Curtain");
      assert.equal(byId.get("cu1.s3")?.name, "Lace Curtain");
    });
  });
});

describe("SpeakerSpec optional ttsActionId and directiveActionId fields", () => {
  it("accepts optional ttsActionId and directiveActionId while staying backward-compatible", () => {
    const legacySpeaker: SpeakerSpec = {
      kind: "speaker",
      mediaEntityId: "media_player.xiaoai",
      state: "idle",
      volumePercent: 35,
      isMuted: false,
      muteSwitchEntityId: null,
      sleepModeEntityId: null,
      isSleepMode: false,
      volumeWritable: true,
    };
    const extendedSpeaker: SpeakerSpec = {
      ...legacySpeaker,
      state: "playing",
      ttsActionId: "miot:did_sp:5:1",
      directiveActionId: "miot:did_sp:5:4",
    };
    const nullActionSpeaker: SpeakerSpec = {
      ...legacySpeaker,
      ttsActionId: null,
      directiveActionId: null,
    };

    assert.equal(legacySpeaker.ttsActionId, undefined);
    assert.equal(extendedSpeaker.ttsActionId, "miot:did_sp:5:1");
    assert.equal(extendedSpeaker.directiveActionId, "miot:did_sp:5:4");
    assert.equal(nullActionSpeaker.ttsActionId, null);
    assert.equal(deviceStatusSummary(makeDevice("sp", extendedSpeaker)), "播放中 · 音量 35%");
  });

  it("preserves zh-Hant language setting when matching MIoT alert controls in lockedControlIdForAlert", () => {
    withLang("zh-Hant", () => {
      const controls: FacetControl[] = [
        {
          id: "did.2.1",
          serviceName: "physical-controls-locked",
          name: "physical-controls-locked-status",
          title: "Physical Control Locked Status",
          kind: "reading",
          value: 1,
          unit: null,
          scale: null,
          range: null,
          options: [{ value: 1, label: "Abnormal" }],
          isWritable: false,
          writesByDefault: false,
          isHighValue: true,
          isConfirmedWrite: false,
          target: null,
        },
        {
          id: "did.2.2",
          serviceName: "physical-controls-locked",
          name: "physical-controls-locked",
          title: "Physical Control Locked",
          kind: "toggle",
          value: false,
          unit: null,
          scale: null,
          range: null,
          options: [],
          isWritable: true,
          writesByDefault: false,
          isHighValue: true,
          isConfirmedWrite: false,
          target: { kind: "property", entityId: "miot.did", piid: 2 },
        },
      ];
      const alertText = facetAlertText(controls[0]!, "Abnormal");
      assert.equal(currentLanguage(), "zh-Hant");
      const lockedId = lockedControlIdForAlert(alertText, controls, false);
      assert.equal(lockedId, "did.2.2");
      assert.equal(currentLanguage(), "zh-Hant");
      assert.equal(facetServiceTitle("physical-controls-locked"), "按鍵鎖");
    });
  });
});
