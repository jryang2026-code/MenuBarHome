import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import {
  DEFAULT_CONFIRMATION_POLICY,
  DelayPhrase,
  LocalIntentParser,
  ManualControlPolicy,
  ModelActionPolicy,
  ModelIntentResolver,
  assistantDeviceCategory,
  buildIntentCatalog,
  catalogStateSummary,
} from "../src/core/assistant.js";
import { spokenChineseNumber } from "../src/core/assistant/chineseIntentTables.js";
import {
  deviceCategory,
  isHumidifierAppliance,
  isValveDevice,
} from "../src/core/assistant/deviceCategory.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import { setLanguage } from "../src/core/i18n.js";
import type { HttpTransport } from "../src/core/miCloudClient.js";
import type { DeviceIntent, HomeScene, SmartDevice } from "../src/core/models.js";
import {
  SCHEDULED_COMMANDS_STORAGE_KEY,
  ScheduledCommandStore,
  missingScheduledCommandTargets,
} from "../src/core/scheduledCommands.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import type { SpeechRecognitionEventLike, SpeechRecognitionInstance } from "../src/ui/appTypes.js";
import { handlePanelKey } from "../src/ui/panelKeyboard.js";
import {
  confirmMissedScheduledCommand,
  markTimerSnapshotReady,
  processScheduledCommands,
} from "../src/ui/scheduledCommands.js";
import {
  abortVoiceInput,
  runWithScheduledTimerTickExemption,
  toggleVoiceInput,
} from "../src/ui/speechGuard.js";

function makeLight(id: string, name: string, room = "书房", isOn = false): SmartDevice {
  return {
    id,
    name,
    roomId: room,
    roomName: room,
    model: "yeelink.light.lamp4",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: id,
      isOn,
      brightnessPercent: 60,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function makePlug(id: string, name: string, room = "客厅", isOn = false): SmartDevice {
  return {
    id,
    name,
    roomId: room,
    roomName: room,
    model: "chuangmi.plug.212a01",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: id,
      isOn,
      powerWatts: 12,
      energyKwh: null,
      childLockEntityId: null,
      isChildLocked: false,
    },
  };
}

describe("A9 ConfirmationPolicy wired into ModelIntentResolver", () => {
  const devices: SmartDevice[] = [
    makeLight("l1", "书房台灯", "书房"),
    makeLight("l2", "卧室吸顶灯", "卧室"),
    makeLight("l3", "客厅主灯", "客厅"),
    makeLight("l4", "阳台吸顶灯", "阳台"),
    makePlug("p1", "桌面插座", "书房"),
  ];
  const scenes: HomeScene[] = [];

  it("converts low-confidence SystemOne actions into confirmation chips by default and runs when askWhenUnsure is false", async () => {
    assert.deepEqual(DEFAULT_CONFIRMATION_POLICY, { askWhenUnsure: true, threshold: 0.8 });

    const systemOneBody = JSON.stringify({
      answers: {
        target: { choice: "d1", confidence: 0.62, probabilities: { d1: 0.62, none: 0.38 } },
        op: { choice: "power_on", confidence: 0.85, probabilities: { power_on: 0.85 } },
        temp: { choice: "none", confidence: 0.99 },
      },
    });

    const transport: HttpTransport = async () => ({
      status: 200,
      headers: {},
      body: systemOneBody,
    });

    const defaultResolver = new ModelIntentResolver(
      { baseURL: "http://127.0.0.1:11434/v1", model: "jev-latest", apiKey: "" },
      transport,
    );
    const defaultPlan = await defaultResolver.resolve("把台灯打开", devices, scenes);
    assert.equal(defaultPlan.intents.length, 0, "default threshold 0.8 holds 0.62 confidence for confirmation");
    assert.equal(defaultPlan.suggestions.length, 1);
    assert.equal(defaultPlan.suggestions[0]?.id, "confirm:primary");
    assert.deepEqual(defaultPlan.suggestions[0]?.intents, [
      { targetId: "l1", operation: { kind: "power", isOn: true } },
    ]);

    const permissiveResolver = new ModelIntentResolver(
      { baseURL: "http://127.0.0.1:11434/v1", model: "jev-latest", apiKey: "" },
      transport,
      { askWhenUnsure: false },
    );
    const autoPlan = await permissiveResolver.resolve("把台灯打开", devices, scenes);
    assert.deepEqual(autoPlan.intents, [{ targetId: "l1", operation: { kind: "power", isOn: true } }]);
    assert.equal(autoPlan.suggestions.length, 0);
    const loweredPlan = await defaultResolver.resolve("把台灯打开", devices, scenes, undefined, {
      askWhenUnsure: true,
      threshold: 0.5,
    });
    assert.equal(loweredPlan.intents.length, 1);
    assert.equal(loweredPlan.suggestions.length, 0);
  });

  it("still requires confirmation for hazardous devices and >3 multi-target actions even when askWhenUnsure is false", async () => {
    const catalog = buildIntentCatalog(devices, scenes);
    const plugAlias = catalog.aliasDevices.find((item) => item.device.id === "p1")?.alias;
    assert.ok(plugAlias);

    const hazardBody = JSON.stringify({
      answers: {
        target: { choice: plugAlias, confidence: 0.55 },
        op: { choice: "power_on", confidence: 0.55 },
        temp: { choice: "none", confidence: 0.99 },
      },
    });
    const hazardPlan = ModelIntentResolver.planFromSystemOne(
      hazardBody,
      catalog,
      devices,
      scenes,
      { askWhenUnsure: false, threshold: 0.1 },
    );
    assert.equal(hazardPlan.intents.length, 0, "hazard device never bypasses confirmation");
    assert.equal(hazardPlan.suggestions.length, 1);
    const wideChat = JSON.stringify({
      actions: [{ device: "all_lights", op: "power", value: false }],
      reply: "全屋关灯",
    });
    const widePlan = ModelIntentResolver.planFromChat(
      wideChat,
      catalog,
      devices,
      scenes,
      { askWhenUnsure: false },
    );
    assert.equal(widePlan.intents.length, 0, ">3 devices still convert to grouped confirmation chip");
    assert.equal(widePlan.suggestions[0]?.id, "confirm");
    assert.equal(widePlan.suggestions[0]?.intents.length, 4);

    const lowConfChat = JSON.stringify({
      actions: [{ device: "d1", op: "power", value: true, confidence: 0.45 }],
      reply: "打开台灯",
    });
    const askedChat = ModelIntentResolver.planFromChat(lowConfChat, catalog, devices, scenes, {
      askWhenUnsure: true,
      threshold: 0.8,
    });
    assert.equal(askedChat.intents.length, 0);
    assert.equal(askedChat.suggestions.length, 1);

    const directChat = ModelIntentResolver.planFromChat(lowConfChat, catalog, devices, scenes, {
      askWhenUnsure: false,
    });
    assert.equal(directChat.intents.length, 1);
    assert.equal(directChat.suggestions.length, 0);
  });
});

describe("A3c Home Assistant humidifier.* and valve.* category & AI catalog alignment", () => {
  const haHome = HomeAssistantSynthesizer.synthesize({
    areas: [
      { area_id: "bedroom", name: "卧室" },
      { area_id: "kitchen", name: "厨房" },
    ],
    devices: [
      { id: "ha-hum-bed", name: "卧室加湿器", area_id: "bedroom" },
      { id: "ha-valve-water", name: "厨房水阀", area_id: "kitchen" },
      { id: "ha-valve-gas", name: "厨房燃气阀", area_id: "kitchen" },
    ],
    entities: [
      { entity_id: "humidifier.bedroom", device_id: "ha-hum-bed" },
      { entity_id: "valve.kitchen_water", device_id: "ha-valve-water" },
      { entity_id: "valve.kitchen_gas", device_id: "ha-valve-gas" },
    ],
    states: [
      {
        entity_id: "humidifier.bedroom",
        state: "on",
        attributes: {
          humidity: 60,
          current_humidity: 48,
          mode: "auto",
          available_modes: ["auto", "sleep"],
          supported_features: 3,
        },
      },
      {
        entity_id: "valve.kitchen_water",
        state: "open",
        attributes: { device_class: "water", supported_features: 3 },
      },
      {
        entity_id: "valve.kitchen_gas",
        state: "closed",
        attributes: { device_class: "gas", supported_features: 3 },
      },
    ],
  });

  it("classifies HA humidifier.* as airPurifier and valve.* as valve across deviceCategory and IntentCatalog", () => {
    const hum = haHome.devices.find((d) => d.id === "ha-hum-bed")!;
    const waterValve = haHome.devices.find((d) => d.id === "ha-valve-water")!;
    const gasValve = haHome.devices.find((d) => d.id === "ha-valve-gas")!;

    assert.equal(isHumidifierAppliance(hum), true);
    assert.equal(deviceCategory(hum), "airPurifier");
    assert.equal(assistantDeviceCategory(hum), "airPurifier");
    assert.equal(catalogStateSummary(hum), "开 目标湿度60% 当前湿度48% auto");

    assert.equal(isValveDevice(waterValve), true);
    assert.equal(deviceCategory(waterValve), "valve");
    assert.equal(assistantDeviceCategory(waterValve), "valve");
    assert.equal(catalogStateSummary(waterValve), "开");
    assert.equal(catalogStateSummary(gasValve), "关");

    const catalog = buildIntentCatalog(haHome.devices, []);
    const parsedJson = JSON.parse(catalog.text.split("\n")[1]!) as {
      devices: Array<{ id: string; name: string; category: string; state: string }>;
    };
    const byName = new Map(parsedJson.devices.map((row) => [row.name, row]));
    assert.equal(byName.get("卧室加湿器")?.category, "airPurifier");
    assert.equal(byName.get("卧室加湿器")?.state, "开 目标湿度60% 当前湿度48% auto");
    assert.equal(byName.get("厨房水阀")?.category, "valve");
    assert.equal(byName.get("厨房水阀")?.state, "开");
    assert.equal(byName.get("厨房燃气阀")?.category, "valve");
    assert.equal(byName.get("厨房燃气阀")?.state, "关");
  });

  it("resolves bare category commands for HA humidifiers and valves and enforces open-valve hazard confirmation", () => {
    const closeHum = LocalIntentParser.parse("关加湿器", haHome.devices, []);
    assert.deepEqual(closeHum?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: false } },
    ]);

    const offHumHome: SmartDevice[] = haHome.devices.map((dev) =>
      dev.id === "ha-hum-bed" && dev.kind.kind === "appliance"
        ? { ...dev, kind: { ...dev.kind, isOn: false } }
        : dev,
    );
    const openHum = LocalIntentParser.parse("打开加湿器", offHumHome, []);
    assert.deepEqual(openHum?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: true } },
    ]);
    const enOpenHum = LocalIntentParser.parse("turn on humidifier", offHumHome, []);
    assert.deepEqual(enOpenHum?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: true } },
    ]);
    const closeValve = LocalIntentParser.parse("关水阀", haHome.devices, []);
    assert.deepEqual(closeValve?.intents, [
      { targetId: "ha-valve-water", operation: { kind: "power", isOn: false } },
    ]);
    assert.equal(
      ManualControlPolicy.requiresConfirmation(closeValve!.intents[0]!, haHome.devices),
      false,
      "closing a valve makes the home safer and runs directly",
    );
    const openValve = LocalIntentParser.parse("打开阀门", haHome.devices, []);
    assert.deepEqual(openValve?.intents, [
      { targetId: "ha-valve-gas", operation: { kind: "power", isOn: true } },
    ]);
    assert.equal(
      ManualControlPolicy.requiresConfirmation(openValve!.intents[0]!, haHome.devices),
      true,
      "opening a valve must require confirmation",
    );
    assert.equal(
      ModelActionPolicy.needsConfirmation(openValve!.intents[0]!, haHome.devices),
      true,
    );
  });

  it("excludes normally-open valves from all_devices and generic room/home shutoff while keeping explicit valve commands", () => {
    const kitchenLight: SmartDevice = {
      ...makeLight("kitchen-light", "厨房吸顶灯", "厨房", true),
      roomId: "kitchen",
    };
    const mixedDevices: SmartDevice[] = [...haHome.devices, kitchenLight];
    const catalog = buildIntentCatalog(mixedDevices, []);
    assert.deepEqual(catalog.aliasToIds.get("all_devices"), ["ha-hum-bed", "kitchen-light"]);
    assert.equal(
      catalog.aliasToIds.get("all_devices")?.includes("ha-valve-water"),
      false,
      "normally-open water valve must never enter all_devices",
    );
    const closeKitchen = LocalIntentParser.parse("关闭厨房", mixedDevices, []);
    assert.deepEqual(closeKitchen?.intents, [
      { targetId: "kitchen-light", operation: { kind: "power", isOn: false } },
    ]);

    const closeAll = LocalIntentParser.parse("把所有设备关掉", mixedDevices, []);
    assert.deepEqual(closeAll?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: false } },
      { targetId: "kitchen-light", operation: { kind: "power", isOn: false } },
    ]);
    assert.deepEqual(LocalIntentParser.parse("全屋关掉", mixedDevices, [])?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: false } },
      { targetId: "kitchen-light", operation: { kind: "power", isOn: false } },
    ]);
    const enMixedDevices: SmartDevice[] = mixedDevices.map((dev) =>
      dev.roomName === "厨房" ? { ...dev, roomName: "Kitchen" } : dev,
    );
    const enCloseKitchen = LocalIntentParser.parse("turn off kitchen", enMixedDevices, []);
    assert.deepEqual(enCloseKitchen?.intents, [
      { targetId: "kitchen-light", operation: { kind: "power", isOn: false } },
    ]);
    const enCloseAll = LocalIntentParser.parse("turn off everything", enMixedDevices, []);
    assert.deepEqual(enCloseAll?.intents, [
      { targetId: "ha-hum-bed", operation: { kind: "power", isOn: false } },
      { targetId: "kitchen-light", operation: { kind: "power", isOn: false } },
    ]);
    assert.deepEqual(LocalIntentParser.parse("关水阀", mixedDevices, [])?.intents, [
      { targetId: "ha-valve-water", operation: { kind: "power", isOn: false } },
    ]);
    assert.deepEqual(LocalIntentParser.parse("关闭厨房水阀", mixedDevices, [])?.intents, [
      { targetId: "ha-valve-water", operation: { kind: "power", isOn: false } },
    ]);
    assert.deepEqual(LocalIntentParser.parse("close water valve", mixedDevices, [])?.intents, [
      { targetId: "ha-valve-water", operation: { kind: "power", isOn: false } },
    ]);
  });
});

describe("A10 Chinese numeral delays (1..99, compound, trailing) & cross-home scheduled command guard", () => {
  let dom: Window | null = null;

  afterEach(async () => {
    if (dom) {
      await closeTestWindow(dom);
      dom = null;
    }
  });

  it("parses general 1..99 Chinese numerals, compound durations, and trailing delays within <= 86400s", () => {
    assert.equal(spokenChineseNumber("十"), 10);
    assert.equal(spokenChineseNumber("十五"), 15);
    assert.equal(spokenChineseNumber("二十"), 20);
    assert.equal(spokenChineseNumber("二十五"), 25);
    assert.equal(spokenChineseNumber("四十五"), 45);
    assert.equal(spokenChineseNumber("九十九"), 99);
    assert.equal(spokenChineseNumber("零五"), 5);

    assert.deepEqual(DelayPhrase.extract("二十五分钟后打开书房台灯"), {
      seconds: 1500,
      remainder: "打开书房台灯",
    });
    assert.deepEqual(DelayPhrase.extract("四十五秒后关灯"), {
      seconds: 45,
      remainder: "关灯",
    });
    assert.deepEqual(DelayPhrase.extract("九十九分钟后关空调"), {
      seconds: 5940,
      remainder: "关空调",
    });
    assert.deepEqual(DelayPhrase.extract("一个半小时后关灯"), {
      seconds: 5400,
      remainder: "关灯",
    });
    assert.deepEqual(DelayPhrase.extract("过十五分钟关闭客厅主灯"), {
      seconds: 900,
      remainder: "关闭客厅主灯",
    });
    assert.deepEqual(DelayPhrase.extract("把空调关掉 30分钟后"), {
      seconds: 1800,
      remainder: "把空调关掉",
    });
    assert.deepEqual(DelayPhrase.extract("把空调关掉 二十五分钟后"), {
      seconds: 1500,
      remainder: "把空调关掉",
    });
    assert.deepEqual(DelayPhrase.extract("把空调关掉，15分钟后"), {
      seconds: 900,
      remainder: "把空调关掉",
    });
    assert.equal(DelayPhrase.extract("二十四小时后关灯")?.seconds, 86400);
    assert.equal(DelayPhrase.extract("二十五小时后关灯"), null);
    assert.equal(DelayPhrase.extract("关灯 二十五小时后"), null);
    assert.equal(DelayPhrase.extract("关灯 90000秒后"), null);
    assert.equal(DelayPhrase.extract("10分钟关灯"), null);

    const tradDevices: SmartDevice[] = [
      makeLight("living-light", "客厅主灯", "客厅", true),
      makeLight("study-lamp", "书房台灯", "书房", false),
    ];
    assert.deepEqual(LocalIntentParser.parse("關閉客廳燈", tradDevices, [])?.intents, [
      { targetId: "living-light", operation: { kind: "power", isOn: false } },
    ]);
    assert.deepEqual(LocalIntentParser.parse("打開書房檯燈", tradDevices, [])?.intents, [
      { targetId: "study-lamp", operation: { kind: "power", isOn: true } },
    ]);
    assert.deepEqual(DelayPhrase.extract("二十分鐘後關閉書房檯燈"), {
      seconds: 1200,
      remainder: "關閉書房檯燈",
    });
    assert.deepEqual(
      LocalIntentParser.parse(
        DelayPhrase.extract("二十分鐘後關閉書房檯燈")!.remainder,
        tradDevices,
        [],
      )?.intents,
      [{ targetId: "study-lamp", operation: { kind: "power", isOn: false } }],
    );
  });

  it("parks due cross-home timers into missedScheduledCommands instead of dispatching or erroring (ADR-0019)", async () => {
    const mem = new Map<string, string>();
    const store = new ScheduledCommandStore(
      {
        getItem: (k) => mem.get(k) ?? null,
        setItem: (k, v) => {
          mem.set(k, v);
        },
      },
      1_000,
    );
    store.queue("xiaomi:cn:u1").scheduledCommands.push({
      id: "home_a_timer",
      command: "关闭书房台灯",
      reply: "25 分钟后：关闭书房台灯",
      delaySeconds: 1500,
      fireTimestampMs: 2_000,
      intents: [{ targetId: "did_home_a_lamp", operation: { kind: "power", isOn: false } }],
    });
    store.persist();

    const dueInHomeB = store.takeDue("xiaomi:cn:u1", true, 2_500, new Set(["did_home_b_ac"]));
    assert.deepEqual(dueInHomeB, []);
    assert.equal(store.queue("xiaomi:cn:u1").scheduledCommands.length, 0);
    assert.equal(store.queue("xiaomi:cn:u1").missedScheduledCommands.length, 1);
    assert.equal(store.queue("xiaomi:cn:u1").missedScheduledCommands[0]?.id, "home_a_timer");
    dom = mountTestWindow({ stubInterval: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        autoCheckUpdates: false,
        enableGrokBall: false,
      }),
    );

    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    app.settings.miSession = {
      userId: "10001",
      cUserId: "c10001",
      ssecurity: "sec",
      serviceToken: "tok",
      passToken: "pass",
      region: "cn",
    };
    app.timerCredentialsReady = true;

    const homeALamp = makeLight("did_home_a_lamp", "书房台灯", "书房", true);
    const homeBLamp = makeLight("did_home_b_lamp", "度假屋顶灯", "客厅", true);
    app.devices = [homeALamp];
    app.scenes = [];
    markTimerSnapshotReady(app);

    const executed: DeviceIntent[][] = [];
    app.executeIntents = async (intents) => {
      executed.push([...intents]);
      return true;
    };

    await app.handleNaturalCommand("二十五分钟后关闭书房台灯");
    assert.equal(app.scheduledCommands.length, 1);
    assert.equal(app.scheduledCommands[0]?.delaySeconds, 1500);
    const armed = app.scheduledCommands[0]!;
    app.replyBanner = null;
    app.devices = [homeBLamp];
    markTimerSnapshotReady(app);
    assert.deepEqual(missingScheduledCommandTargets(armed, app.devices, app.scenes), ["did_home_a_lamp"]);
    const originalPersist = app.scheduledCommandStore.persist.bind(app.scheduledCommandStore);
    let persistCallCount = 0;
    app.scheduledCommandStore.persist = () => {
      persistCallCount += 1;
      if (persistCallCount > 1) return false;
      return originalPersist();
    };
    const changed = runWithScheduledTimerTickExemption(() =>
      processScheduledCommands(app, armed.fireTimestampMs + 100),
    );
    await setImmediate();
    app.scheduledCommandStore.persist = originalPersist;
    assert.equal(persistCallCount, 1);
    assert.equal(changed, true);
    assert.equal(executed.length, 0, "must never blindly dispatch missing target in Home B");
    assert.equal(app.replyBanner, null, "must not surface an error banner when parking cross-home timer");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 1);
    assert.equal(app.missedScheduledCommands[0]?.id, armed.id);
    assert.ok(
      localStorage.getItem(SCHEDULED_COMMANDS_STORAGE_KEY)?.includes(armed.id),
      "missed timer is durably persisted to storage",
    );
    await confirmMissedScheduledCommand(app, armed.id);
    await setImmediate();
    assert.equal(executed.length, 0);
    assert.equal(app.missedScheduledCommands.length, 1);
    app.devices = [homeALamp];
    markTimerSnapshotReady(app);
    await confirmMissedScheduledCommand(app, armed.id);
    await setImmediate();
    assert.equal(executed.length, 1);
    assert.deepEqual(executed[0], armed.intents);
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.equal(
      localStorage.getItem(SCHEDULED_COMMANDS_STORAGE_KEY)?.includes(armed.id) ?? false,
      false,
    );

    const l1 = makeLight("did_l1", "灯一", "客厅", true);
    const l2 = makeLight("did_l2", "灯二", "客厅", true);
    const l3 = makeLight("did_l3", "灯三", "客厅", true);
    const l4 = makeLight("did_l4", "灯四", "卧室", true);
    app.devices = [l1, l2, l3, l4];
    markTimerSnapshotReady(app);
    const sentEntities: string[] = [];
    delete (app as { executeIntents?: unknown }).executeIntents;
    app.applyCommand = async (cmd) => {
      await setImmediate();
      if (cmd.kind === "setLightPower") sentEntities.push(cmd.entityId);
      return true;
    };
    app.scheduledCommands = [
      {
        id: "timer_3lights",
        command: "关客厅灯",
        reply: "1 分钟后：关客厅灯",
        delaySeconds: 60,
        fireTimestampMs: 1_000,
        intents: [
          { targetId: "did_l1", operation: { kind: "power", isOn: false } },
          { targetId: "did_l2", operation: { kind: "power", isOn: false } },
          { targetId: "did_l3", operation: { kind: "power", isOn: false } },
        ],
      },
      {
        id: "timer_4thlight",
        command: "关灯四",
        reply: "1 分钟后：关灯四",
        delaySeconds: 60,
        fireTimestampMs: 1_000,
        intents: [{ targetId: "did_l4", operation: { kind: "power", isOn: false } }],
      },
    ];
    app.scheduledCommandStore.persist();
    runWithScheduledTimerTickExemption(() => processScheduledCommands(app, 2_000));
    for (let i = 0; i < 12; i += 1) await setImmediate();
    assert.deepEqual(sentEntities.sort(), ["did_l1", "did_l2", "did_l3", "did_l4"]);
  });
});

describe("A13 Panel keyboard navigation (Tab/Shift+Tab, Ctrl+,, Escape hide_panel)", () => {
  let dom: Window;
  let app: MenuMijiaWindowsApp;
  let tauriCalls: string[];

  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    tauriCalls = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string) => {
          tauriCalls.push(cmd);
          return undefined;
        },
      },
      configurable: true,
    });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        autoCheckUpdates: false,
        enableGrokBall: false,
      }),
    );
    app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  });

  afterEach(async () => {
    await closeTestWindow(dom);
  });

  function dispatchKey(key: string, init: KeyboardEventInit = {}): KeyboardEvent {
    const event = new window.KeyboardEvent("keydown", {
      key,
      bubbles: true,
      cancelable: true,
      ...init,
    });
    (document.activeElement ?? window).dispatchEvent(event);
    return event;
  }

  it("cycles .cc-room-pill[data-room] forward/backward on Tab/Shift+Tab without hitting [data-kind] pills and ignores Tab inside #command-input", () => {
    const roomPillsBefore = [...document.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-room]")];
    const kindPillsBefore = [...document.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-kind]")];
    assert.ok(roomPillsBefore.length >= 3, "demo mode renders multiple [data-room] filter pills");
    assert.ok(kindPillsBefore.length > 0, "'全部' view also renders [data-kind] pills sharing .cc-room-pill");
    assert.ok(roomPillsBefore[0]?.classList.contains("is-active"));

    const assertActiveIsRoomPill = (expectedIndex: number): void => {
      const roomPills = [...document.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-room]")];
      const activePills = [...document.querySelectorAll<HTMLButtonElement>(".cc-room-pill.is-active")];
      assert.equal(activePills.length, 1);
      const active = activePills[0]!;
      assert.equal(active.hasAttribute("data-room"), true, "activated pill must carry data-room");
      assert.equal(active.hasAttribute("data-kind"), false, "activated pill must never be a data-kind pill");
      const resolvedIdx = expectedIndex < 0 ? roomPills.length + expectedIndex : expectedIndex;
      assert.equal(active, roomPills[resolvedIdx]);
    };
    const tab1 = dispatchKey("Tab");
    assert.equal(tab1.defaultPrevented, true);
    assertActiveIsRoomPill(1);
    dispatchKey("Tab", { shiftKey: true });
    assertActiveIsRoomPill(0);
    assert.ok(document.querySelectorAll(".cc-room-pill[data-kind]").length > 0);

    dispatchKey("Tab", { shiftKey: true });
    assertActiveIsRoomPill(-1);
    assert.equal(app.listCut.kind, "room");
    dispatchKey("Tab");
    assertActiveIsRoomPill(0);
    dispatchKey("/");
    const inputEl = document.querySelector<HTMLInputElement>("#command-input")!;
    assert.equal(document.activeElement, inputEl);
    const tabInInput = dispatchKey("Tab");
    assert.equal(tabInInput.defaultPrevented, false);
    assertActiveIsRoomPill(0);
    inputEl.blur();
    dispatchKey("2");
    assertActiveIsRoomPill(1);
  });

  it("opens Preferences on Ctrl+, or Meta+, and invokes hide_panel on terminal Escape", async () => {
    dispatchKey("/");
    const inputEl = document.querySelector<HTMLInputElement>("#command-input")!;
    inputEl.value = "书房";
    inputEl.dispatchEvent(new window.Event("input", { bubbles: true }));
    dispatchKey("Escape");
    assert.equal(app.panelSearch.query, "");
    assert.ok(!tauriCalls.includes("hide_panel"));
    app.expandedDeviceId = app.devices[0]!.id;
    app.panelSearch.selectedDeviceId = app.devices[0]!.id;
    app.render();
    dispatchKey("Escape");
    assert.equal(app.expandedDeviceId, null);
    assert.ok(!tauriCalls.includes("hide_panel"));
    dispatchKey("Escape");
    assert.equal(app.panelSearch.selectedDeviceId, null);
    assert.ok(!tauriCalls.includes("hide_panel"));
    const escEvent = new window.KeyboardEvent("keydown", { key: "Escape", cancelable: true });
    assert.equal(handlePanelKey(app, escEvent), true);
    await setImmediate();
    assert.ok(tauriCalls.includes("hide_panel"));
    assert.equal(app.activeSheet, "none");
    const ctrlComma = dispatchKey(",", { ctrlKey: true });
    assert.equal(ctrlComma.defaultPrevented, true);
    assert.equal(app.activeSheet, "settings");
    app.activeSheet = "none";
    app.render();
    const metaComma = dispatchKey(",", { metaKey: true });
    assert.equal(metaComma.defaultPrevented, true);
    assert.equal(app.activeSheet, "settings");
  });
});

describe("A8 Voice input live interim streaming draft & accurate Web Speech error copy", () => {
  let dom: Window;
  let app: MenuMijiaWindowsApp;

  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: { invoke: async () => undefined },
      configurable: true,
    });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        autoCheckUpdates: false,
        enableGrokBall: false,
      }),
    );
    app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  });

  afterEach(async () => {
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("reports accurate Web Speech API unavailability copy instead of claiming offline speech", () => {
    delete (window as { SpeechRecognition?: unknown }).SpeechRecognition;
    delete (window as { webkitSpeechRecognition?: unknown }).webkitSpeechRecognition;

    setLanguage("zh-Hans");
    toggleVoiceInput(app);
    assert.ok(app.replyBanner?.text);
    assert.ok(!app.replyBanner.text.includes("离线语音识别"), "must not claim offline speech recognition");
    assert.match(app.replyBanner.text, /在线语音识别|Web Speech API/);

    setLanguage("en");
    toggleVoiceInput(app);
    assert.match(app.replyBanner?.text ?? "", /Web Speech API/i);
  });

  it("streams interim transcripts into #command-input without submitting until final/onend and clears on abort/error", () => {
    const instances: FakeSpeechRecognition[] = [];
    class FakeSpeechRecognition implements SpeechRecognitionInstance {
      lang = "";
      interimResults = false;
      continuous = false;
      onresult: ((event: SpeechRecognitionEventLike) => void) | null = null;
      onerror: (() => void) | null = null;
      onend: (() => void) | null = null;
      constructor() {
        instances.push(this);
      }
      start(): void {}
      stop(): void {}
      abort(): void {}
    }

    (window as { SpeechRecognition?: unknown }).SpeechRecognition = FakeSpeechRecognition;

    const submitted: string[] = [];
    app.handleNaturalCommand = async (raw: string) => {
      submitted.push(raw);
    };
    toggleVoiceInput(app);
    const rec1 = instances[0]!;
    assert.equal(rec1.interimResults, true);

    rec1.onresult?.({
      results: [{ 0: { transcript: "打开书房" }, isFinal: false }],
    });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "打开书房");
    assert.deepEqual(submitted, [], "interim result must not submit prematurely");

    rec1.onresult?.({
      results: [{ 0: { transcript: "打开书房台灯" }, isFinal: false }],
    });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "打开书房台灯");
    assert.deepEqual(submitted, []);

    rec1.onresult?.({
      results: [{ 0: { transcript: "打开书房台灯" }, isFinal: true }],
    });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
    assert.deepEqual(submitted, ["打开书房台灯"]);

    rec1.onend?.();
    assert.deepEqual(submitted, ["打开书房台灯"], "onend after isFinal must not submit a second time");
    assert.equal(app.isListeningVoice, false);
    toggleVoiceInput(app);
    const rec2 = instances[1]!;
    rec2.onresult?.({
      results: [{ 0: { transcript: "关闭客厅" }, isFinal: false }],
    });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "关闭客厅");
    abortVoiceInput(app);
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
    assert.deepEqual(submitted, ["打开书房台灯"]);
    toggleVoiceInput(app);
    const rec3 = instances[2]!;
    rec3.onresult?.({
      results: [{ 0: { transcript: "调暗" }, isFinal: false }],
    });
    rec3.onerror?.();
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
    assert.deepEqual(submitted, ["打开书房台灯"]);
    toggleVoiceInput(app);
    const rec4 = instances[3]!;
    rec4.onresult?.({
      results: [{ 0: { transcript: "关闭空调" }, isFinal: false }],
    });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "关闭空调");
    rec4.onend?.();
    assert.deepEqual(submitted, ["打开书房台灯", "关闭空调"]);
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
  });
});
