import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { deviceCategory } from "../src/core/assistant/deviceCategory.js";
import { decodeHabitOperation, encodeHabitOperation } from "../src/core/assistant/habits.js";
import { IntentReply, IntentValidator, LocalIntentParser } from "../src/core/assistant/intent.js";
import { applyCommandToDevices, inverseCommands } from "../src/core/commandEffects.js";
import {
  HomeAssistantSynthesizer,
  haServiceCall,
  homeAssistantIdentity,
  parseCachedHAHome,
} from "../src/core/homeAssistant.js";
import { setLanguage } from "../src/core/i18n.js";
import { propKeyString } from "../src/core/miCloud/client.js";
import { MiotCommandMapper } from "../src/core/miCloud/command.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import {
  deviceCanTogglePower,
  devicePrimaryEntityId,
  deviceStatusSummary,
  hasDetailDrawer,
  isDeviceActiveOn,
  joinsAllOffByDefault,
  type SmartDevice,
  type TvSpec,
} from "../src/core/models.js";
import { cancelDelayedReadBack } from "../src/core/optimisticLock.js";
import { buildRaycastSnapshot } from "../src/core/raycastSnapshot.js";
import { refreshHADevices } from "../src/ui/cloudRefresh.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

let activeDom: Window | null = null;

afterEach(async () => {
  setLanguage("zh-Hans");
  if (activeDom) {
    await closeTestWindow(activeDom);
    activeDom = null;
  }
});

async function flushAsyncTicks(turns = 10): Promise<void> {
  for (let i = 0; i < turns; i += 1) {
    await Promise.resolve();
  }
}

describe("Windows TV and humidifier parity (#29)", () => {
  it("synthesizes HA TV (including volumePresent false) and humidifier entities, round-trips cache, and maps HA service calls", () => {
    setLanguage("zh-Hans");
    const snapshot = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "tv-full", name: "客厅电视", area_id: "living" },
        { id: "tv-novol", name: "卧室电视", area_id: "living" },
        { id: "hum-ha", name: "卧室加湿器", area_id: "living" },
      ],
      entities: [
        { entity_id: "media_player.living_tv", device_id: "tv-full" },
        { entity_id: "button.living_tv_turn_on", device_id: "tv-full" },
        { entity_id: "media_player.bed_tv", device_id: "tv-novol" },
        { entity_id: "humidifier.bed", device_id: "hum-ha" },
      ],
      states: [
        {
          entity_id: "media_player.living_tv",
          state: "off",
          attributes: {
            device_class: "tv",
            supported_features: 4 | 8 | 128 | 256 | 2048 | 16384,
            volume_level: 0.35,
            is_volume_muted: true,
            source: "HDMI 1",
            source_list: ["HDMI 1", "HDMI 2", "Apple TV"],
          },
        },
        {
          entity_id: "button.living_tv_turn_on",
          state: "unknown",
          attributes: { friendly_name: "Turn On TV" },
        },
        {
          entity_id: "media_player.bed_tv",
          state: "playing",
          attributes: {
            device_class: "tv",
            supported_features: 4 | 256,
          },
        },
        {
          entity_id: "humidifier.bed",
          state: "on",
          attributes: {
            humidity: 55,
            current_humidity: 46,
            min_humidity: 30,
            max_humidity: 80,
            target_humidity_step: 5,
            mode: "auto",
            available_modes: ["auto", "sleep"],
            supported_features: 3,
          },
        },
      ],
    };

    const home = HomeAssistantSynthesizer.synthesize(snapshot);
    const byId = new Map(home.devices.map((d) => [d.id, d]));

    const tvFull = byId.get("tv-full");
    assert.ok(tvFull && tvFull.kind.kind === "tv");
    assert.equal(tvFull.kind.mediaEntityId, "media_player.living_tv");
    assert.equal(tvFull.kind.state, "off");
    assert.equal(tvFull.kind.volumePercent, 35);
    assert.equal(tvFull.kind.volumeWritable, true);
    assert.equal(tvFull.kind.volumePresent !== false, true);
    assert.equal(tvFull.kind.isMuted, true);
    assert.equal(tvFull.kind.muteSwitchEntityId, "media_player.living_tv#mute");
    assert.equal(tvFull.kind.currentSource, "HDMI 1");
    assert.deepEqual(tvFull.kind.availableSources, ["HDMI 1", "HDMI 2", "Apple TV"]);
    assert.equal(tvFull.kind.turnOnButtonId, "button.living_tv_turn_on");
    assert.equal(tvFull.kind.powerWritable, true);
    assert.equal(deviceCanTogglePower(tvFull), true);
    assert.equal(isDeviceActiveOn(tvFull), false);
    assert.equal(joinsAllOffByDefault(tvFull), true);
    assert.equal(devicePrimaryEntityId(tvFull), "media_player.living_tv");
    assert.deepEqual(
      (home.deviceFacets?.["tv-full"] ?? []).map((f) => f.id),
      ["media_player.living_tv#play_pause"],
    );

    const tvNoVol = byId.get("tv-novol");
    assert.ok(tvNoVol && tvNoVol.kind.kind === "tv");
    assert.equal(tvNoVol.kind.volumeWritable, true);
    assert.equal(tvNoVol.kind.volumePresent, false);
    assert.equal(isDeviceActiveOn(tvNoVol), true);

    const hum = byId.get("hum-ha");
    assert.ok(hum && hum.kind.kind === "humidifier");
    assert.equal(hum.kind.entityId, "humidifier.bed");
    assert.equal(hum.kind.isOn, true);
    assert.equal(hum.kind.targetHumidity, 55);
    assert.equal(hum.kind.currentHumidity, 46);
    assert.equal(hum.kind.minHumidity, 30);
    assert.equal(hum.kind.maxHumidity, 80);
    assert.equal(hum.kind.step, 5);
    assert.equal(hum.kind.humidityWritable, true);
    assert.equal(hum.kind.currentMode, "auto");
    assert.deepEqual(hum.kind.availableModes, ["auto", "sleep"]);
    assert.equal(hum.kind.modeWritable, true);
    assert.equal(hasDetailDrawer(hum), true);
    assert.equal(deviceStatusSummary(hum), "46% · 目标 55% · 自动");

    const identity = homeAssistantIdentity("http://192.168.1.20:8123", "tok")!;
    const roundTripped = parseCachedHAHome(JSON.parse(JSON.stringify({ identity, home })));
    assert.ok(roundTripped);
    const cachedTvNoVol = roundTripped.home.devices.find((d) => d.id === "tv-novol");
    assert.ok(cachedTvNoVol && cachedTvNoVol.kind.kind === "tv");
    assert.equal(cachedTvNoVol.kind.volumePresent, false);
    const cachedHum = roundTripped.home.devices.find((d) => d.id === "hum-ha");
    assert.ok(cachedHum && cachedHum.kind.kind === "humidifier");
    assert.equal(cachedHum.kind.targetHumidity, 55);

    assert.deepEqual(
      haServiceCall({ kind: "mediaSelectSource", entityId: "media_player.living_tv", source: "HDMI 2" }),
      { domain: "media_player", service: "select_source", entity_id: "media_player.living_tv", data: { source: "HDMI 2" } },
    );
    assert.deepEqual(
      haServiceCall({ kind: "setHumidity", entityId: "humidifier.bed", percent: 60 }),
      { domain: "humidifier", service: "set_humidity", entity_id: "humidifier.bed", data: { humidity: 60 } },
    );
    assert.deepEqual(
      haServiceCall({ kind: "setSelectOption", entityId: "humidifier.bed", option: "sleep" }),
      { domain: "humidifier", service: "set_mode", entity_id: "humidifier.bed", data: { mode: "sleep" } },
    );
    assert.deepEqual(
      haServiceCall({ kind: "setSwitch", entityId: "media_player.living_tv#mute", isOn: false }),
      { domain: "media_player", service: "volume_mute", entity_id: "media_player.living_tv", data: { is_volume_muted: false } },
    );
  });

  it("synthesizes MIoT television/stb and humidifier specs and maps MIoT property/action writes", () => {
    const tvSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:television:0000A010:xiaomi-tv1:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:television:0000781B:xiaomi-tv1:1",
          description: "Television",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:status:00000007:xiaomi-tv1:1",
              description: "Status",
              format: "uint8",
              access: ["read", "notify"],
              valueList: [
                { value: 0, description: "Off" },
                { value: 1, description: "On" },
              ],
            },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:input-control:0000003E:xiaomi-tv1:1",
              description: "Input Control",
              format: "uint8",
              access: ["read", "write", "notify"],
              valueList: [
                { value: 1, description: "HDMI 1" },
                { value: 2, description: "HDMI 2" },
              ],
            },
          ],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:turn-on:00002808:xiaomi-tv1:1", description: "Turn On", in: [] },
            { iid: 2, type: "urn:miot-spec-v2:action:turn-off:00002809:xiaomi-tv1:1", description: "Turn Off", in: [] },
          ],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:speaker:0000781C:xiaomi-tv1:1",
          description: "Speaker",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:volume:00000013:xiaomi-tv1:1",
              description: "Volume",
              format: "uint8",
              access: ["read", "write", "notify"],
              valueRange: [0, 100, 1],
            },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:mute:00000040:xiaomi-tv1:1",
              description: "Mute",
              format: "bool",
              access: ["read", "write", "notify"],
            },
          ],
          actions: [],
        },
      ],
    };

    const humSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:humidifier:0000A00E:zhimi-ca4:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:humidifier:00007818:zhimi-ca4:1",
          description: "Humidifier",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:on:00000006:zhimi-ca4:1",
              description: "Switch Status",
              format: "bool",
              access: ["read", "write", "notify"],
            },
            {
              iid: 5,
              type: "urn:miot-spec-v2:property:fan-level:00000016:zhimi-ca4:1",
              description: "Fan Level",
              format: "uint8",
              access: ["read", "write", "notify"],
              valueList: [
                { value: 0, description: "Auto" },
                { value: 1, description: "Silent" },
              ],
            },
            {
              iid: 6,
              type: "urn:miot-spec-v2:property:target-humidity:00000022:zhimi-ca4:1",
              description: "Target Humidity",
              format: "uint8",
              access: ["read", "write", "notify"],
              valueRange: [30, 80, 1],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:zhimi-ca4:1",
          description: "Environment",
          properties: [
            {
              iid: 7,
              type: "urn:miot-spec-v2:property:relative-humidity:0000000C:zhimi-ca4:1",
              description: "Relative Humidity",
              format: "uint8",
              access: ["read", "notify"],
              valueRange: [0, 100, 1],
            },
          ],
          actions: [],
        },
      ],
    };

    const values = new Map<string, unknown>([
      [propKeyString({ did: "did-tv", siid: 2, piid: 1 }), 1],
      [propKeyString({ did: "did-tv", siid: 2, piid: 2 }), 1],
      [propKeyString({ did: "did-tv", siid: 3, piid: 1 }), 40],
      [propKeyString({ did: "did-tv", siid: 3, piid: 2 }), false],
      [propKeyString({ did: "did-hum", siid: 2, piid: 1 }), true],
      [propKeyString({ did: "did-hum", siid: 2, piid: 5 }), 0],
      [propKeyString({ did: "did-hum", siid: 2, piid: 6 }), 55],
      [propKeyString({ did: "did-hum", siid: 3, piid: 7 }), 48],
    ]);

    const miHome = MiotSynthesizer.synthesize(
      [
        { did: "did-tv", name: "小米电视", model: "xiaomi.tv.tv1", isOnline: true, specType: tvSpec.type },
        { did: "did-hum", name: "智米加湿器", model: "zhimi.humidifier.ca4", isOnline: true, specType: humSpec.type },
      ],
      [{ id: "r1", name: "客厅", dids: ["did-tv", "did-hum"] }],
      {
        "xiaomi.tv.tv1": tvSpec,
        "zhimi.humidifier.ca4": humSpec,
      },
      values,
    );

    const miTv = miHome.devices.find((d) => d.id === "did-tv");
    assert.ok(miTv && miTv.kind.kind === "tv");
    assert.equal(miTv.kind.state, "on");
    assert.equal(miTv.kind.volumePercent, 40);
    assert.equal(miTv.kind.volumeWritable, true);
    assert.equal(miTv.kind.volumePresent !== false, true);
    assert.equal(miTv.kind.isMuted, false);
    assert.equal(miTv.kind.muteSwitchEntityId, "miot:did-tv:3");
    assert.equal(miTv.kind.currentSource, "HDMI 1");
    assert.deepEqual(miTv.kind.availableSources, ["HDMI 1", "HDMI 2"]);
    assert.equal(miTv.kind.powerOnActionId, "miot-action:did-tv:2:1");
    assert.equal(miTv.kind.powerOffActionId, "miot-action:did-tv:2:2");
    assert.equal(deviceCanTogglePower(miTv), true);

    const miHum = miHome.devices.find((d) => d.id === "did-hum");
    assert.ok(miHum && miHum.kind.kind === "humidifier");
    assert.equal(miHum.kind.isOn, true);
    assert.equal(miHum.kind.targetHumidity, 55);
    assert.equal(miHum.kind.currentHumidity, 48);
    assert.equal(miHum.kind.humidityWritable, true);
    assert.deepEqual(miHum.kind.availableModes, ["Auto", "Silent"]);

    assert.deepEqual(
      MiotCommandMapper.map({ kind: "setSwitch", entityId: "miot:did-tv:2", isOn: false }, tvSpec),
      { kind: "action", call: { did: "did-tv", siid: 2, aiid: 2, inputs: [] } },
    );
    assert.deepEqual(
      MiotCommandMapper.map({ kind: "mediaSetVolume", entityId: "miot:did-tv:2", level: 0.65 }, tvSpec),
      { kind: "setProps", writes: [{ did: "did-tv", siid: 3, piid: 1, value: 65 }] },
    );
    assert.deepEqual(
      MiotCommandMapper.map({ kind: "setSwitch", entityId: "miot:did-tv:3", isOn: true }, tvSpec),
      { kind: "setProps", writes: [{ did: "did-tv", siid: 3, piid: 2, value: true }] },
    );
    assert.deepEqual(
      MiotCommandMapper.map({ kind: "mediaSelectSource", entityId: "miot:did-tv:2", source: "HDMI 2" }, tvSpec),
      { kind: "setProps", writes: [{ did: "did-tv", siid: 2, piid: 2, value: 2 }] },
    );
    assert.deepEqual(
      MiotCommandMapper.map({ kind: "setHumidity", entityId: "miot:did-hum:2", percent: 60 }, humSpec),
      {
        kind: "setProps",
        writes: [
          { did: "did-hum", siid: 2, piid: 1, value: true },
          { did: "did-hum", siid: 2, piid: 6, value: 60 },
        ],
      },
    );
    assert.deepEqual(
      MiotCommandMapper.map({ kind: "setSelectOption", entityId: "miot:did-hum:2", option: "Silent" }, humSpec),
      {
        kind: "setProps",
        writes: [{ did: "did-hum", siid: 2, piid: 5, value: 1 }],
      },
    );
  });

  it("resolves 关电视, 打开电视, 打开加湿器, and target humidity intents plus habits and Raycast categories", () => {
    setLanguage("zh-Hans");
    const tvOffSpec: TvSpec = {
      kind: "tv",
      mediaEntityId: "media_player.living_tv",
      state: "off",
      volumePercent: 30,
      volumeWritable: true,
      volumePresent: true,
      isMuted: false,
      muteSwitchEntityId: "media_player.living_tv#mute",
      currentSource: "HDMI 1",
      availableSources: ["HDMI 1", "HDMI 2"],
      turnOnButtonId: "button.living_tv_wol",
      powerWritable: true,
    };
    const tvOffWithWol: SmartDevice = {
      id: "tv-1",
      name: "客厅电视",
      roomId: "living",
      roomName: "客厅",
      model: "xiaomi.tv.tv1",
      isOnline: true,
      kind: tvOffSpec,
    };
    const tvOn: SmartDevice = {
      ...tvOffWithWol,
      kind: { ...tvOffSpec, state: "on" },
    };
    const hum: SmartDevice = {
      id: "hum-1",
      name: "卧室加湿器",
      roomId: "bed",
      roomName: "卧室",
      model: "zhimi.humidifier.ca4",
      isOnline: true,
      kind: {
        kind: "humidifier",
        entityId: "humidifier.bed",
        isOn: false,
        targetHumidity: 50,
        currentHumidity: 42,
        minHumidity: 35,
        maxHumidity: 75,
        step: 5,
        humidityWritable: true,
        currentMode: "auto",
        availableModes: ["auto", "sleep"],
        modeWritable: true,
        powerWritable: true,
      },
    };

    assert.equal(deviceCategory(tvOn), "tv");
    assert.equal(deviceCategory(hum), "humidifier");

    const closeTvPlan = LocalIntentParser.parse("关电视", [tvOn, hum], []);
    assert.ok(closeTvPlan);
    const closeTvIntents = IntentValidator.sanitize(closeTvPlan.intents, [tvOn, hum], []);
    assert.equal(closeTvIntents.length, 1);
    assert.deepEqual(IntentValidator.commandsForIntent(closeTvIntents[0]!, tvOn), [
      { kind: "setSwitch", entityId: "media_player.living_tv", isOn: false },
    ]);

    const openTvPlan = LocalIntentParser.parse("打开电视", [tvOffWithWol, hum], []);
    assert.ok(openTvPlan);
    const openTvIntents = IntentValidator.sanitize(openTvPlan.intents, [tvOffWithWol, hum], []);
    assert.equal(openTvIntents.length, 1);
    assert.deepEqual(IntentValidator.commandsForIntent(openTvIntents[0]!, tvOffWithWol), [
      { kind: "pressButton", entityId: "button.living_tv_wol" },
    ]);

    const openHumPlan = LocalIntentParser.parse("打开加湿器", [tvOn, hum], []);
    assert.ok(openHumPlan);
    const openHumIntents = IntentValidator.sanitize(openHumPlan.intents, [tvOn, hum], []);
    assert.equal(openHumIntents.length, 1);
    assert.deepEqual(IntentValidator.commandsForIntent(openHumIntents[0]!, hum), [
      { kind: "setSwitch", entityId: "humidifier.bed", isOn: true },
    ]);

    const humTargetPlan = LocalIntentParser.parse("把加湿器湿度调到 85%", [tvOn, hum], []);
    assert.ok(humTargetPlan);
    const humTargetIntents = IntentValidator.sanitize(humTargetPlan.intents, [tvOn, hum], []);
    assert.deepEqual(humTargetIntents, [
      { targetId: "hum-1", operation: { kind: "targetHumidity", percent: 75 } },
    ]);
    assert.deepEqual(IntentValidator.commandsForIntent(humTargetIntents[0]!, hum), [
      { kind: "setHumidity", entityId: "humidifier.bed", percent: 75 },
    ]);
    assert.equal(IntentReply.describe(humTargetIntents, [tvOn, hum], []), "已卧室加湿器目标湿度调至 75%");

    const habitKey = encodeHabitOperation({ kind: "targetHumidity", percent: 55 });
    assert.equal(habitKey, "humidity:55");
    assert.deepEqual(decodeHabitOperation(habitKey!), { kind: "targetHumidity", percent: 55 });

    const mutableTv: SmartDevice = structuredClone(tvOn);
    applyCommandToDevices(
      [mutableTv],
      { kind: "setSwitch", entityId: "media_player.living_tv#mute", isOn: true },
      "homeAssistant",
    );
    assert.equal(mutableTv.kind.kind === "tv" && mutableTv.kind.isMuted, true);

    assert.deepEqual(
      inverseCommands(hum, { kind: "setHumidity", entityId: "humidifier.bed", percent: 65 }),
      [
        { kind: "setHumidity", entityId: "humidifier.bed", percent: 50 },
        { kind: "setSwitch", entityId: "humidifier.bed", isOn: false },
      ],
    );
    assert.deepEqual(
      inverseCommands(tvOn, { kind: "mediaSelectSource", entityId: "media_player.living_tv", source: "HDMI 2" }),
      [{ kind: "mediaSelectSource", entityId: "media_player.living_tv", source: "HDMI 1" }],
    );

    const raySnap = buildRaycastSnapshot({
      connectionMode: "homeAssistant",
      selectedHomeId: "home-1",
      connectionSummary: "Home Assistant",
      bridgeToken: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      isStale: false,
      devices: [tvOn, hum],
      rooms: [
        { id: "living", name: "客厅", deviceCount: 1 },
        { id: "bed", name: "卧室", deviceCount: 1 },
      ],
      scenes: [],
      environmentReadings: [],
    });
    const rayTv = raySnap.devices.find((d) => d.id === "tv-1");
    const rayHum = raySnap.devices.find((d) => d.id === "hum-1");
    assert.equal(rayTv?.category, "tv");
    assert.equal(rayTv?.categoryTitle, "电视");
    assert.equal(rayHum?.category, "humidifier");
    assert.equal(rayHum?.categoryTitle, "加湿器");
  });

  it("renders TV and humidifier drawers (omitting volume slider when volumePresent is false) and dispatches DOM controls", async () => {
    activeDom = mountTestWindow({ stubInterval: true });
    const { MenuMijiaWindowsApp } = await import("../src/ui/app.js");
    const haBaseURL = "http://192.168.1.21:8123";
    const haToken = "tv-hum-dom-token";

    const snapshot = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "tv-dom", name: "客厅电视", area_id: "living" },
        { id: "tv-novol-dom", name: "次卧电视", area_id: "living" },
        { id: "hum-dom", name: "客厅加湿器", area_id: "living" },
      ],
      entities: [
        { entity_id: "media_player.tv_dom", device_id: "tv-dom" },
        { entity_id: "button.tv_dom_turn_on", device_id: "tv-dom" },
        { entity_id: "media_player.tv_novol_dom", device_id: "tv-novol-dom" },
        { entity_id: "humidifier.hum_dom", device_id: "hum-dom" },
      ],
      states: [
        {
          entity_id: "media_player.tv_dom",
          state: "off",
          attributes: {
            device_class: "tv",
            supported_features: 4 | 8 | 128 | 256 | 2048 | 16384,
            volume_level: 0.3,
            is_volume_muted: false,
            source: "HDMI 1",
            source_list: ["HDMI 1", "HDMI 2"],
          },
        },
        {
          entity_id: "button.tv_dom_turn_on",
          state: "unknown",
          attributes: { friendly_name: "Turn On TV" },
        },
        {
          entity_id: "media_player.tv_novol_dom",
          state: "on",
          attributes: {
            device_class: "tv",
            supported_features: 4 | 256 | 2048,
            source: "TV",
            source_list: ["TV", "HDMI 1"],
          },
        },
        {
          entity_id: "humidifier.hum_dom",
          state: "on",
          attributes: {
            humidity: 50,
            current_humidity: 45,
            min_humidity: 30,
            max_humidity: 80,
            target_humidity_step: 5,
            mode: "auto",
            available_modes: ["auto", "sleep"],
            supported_features: 3,
          },
        },
      ],
    };

    const executedCalls: Array<{ domain: string; service: string; entity_id: string; data: Record<string, unknown> }> = [];
    const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (command === "ha_execute") {
        executedCalls.push(
          args.command as { domain: string; service: string; entity_id: string; data: Record<string, unknown> },
        );
        return null;
      }
      if (command === "ha_snapshot") {
        return structuredClone(snapshot);
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
        haToken,
        cachedHAHome: {
          identity: homeAssistantIdentity(haBaseURL, haToken),
          home: HomeAssistantSynthesizer.synthesize(snapshot),
        },
      }),
    );

    const root = document.querySelector<HTMLElement>("#app")!;
    const app = new MenuMijiaWindowsApp(root);
    await refreshHADevices(app, true);

    const expandTvNoVol =
      root.querySelector<HTMLElement>('[data-expand-device="tv-novol-dom"]') ??
      root.querySelector<HTMLElement>('[data-body-device="tv-novol-dom"]');
    assert.ok(expandTvNoVol);
    expandTvNoVol.click();
    assert.equal(root.querySelector('input[data-volume="tv-novol-dom"]'), null);
    assert.notEqual(root.querySelector('button[data-tvsource="tv-novol-dom|HDMI 1"]'), null);

    const toggleTvBtn = root.querySelector<HTMLButtonElement>('button[data-toggle-device="tv-dom"]');
    assert.ok(toggleTvBtn);
    toggleTvBtn.click();
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "button",
      service: "press",
      entity_id: "button.tv_dom_turn_on",
      data: {},
    });
    assert.equal(
      (app.devices.find((d) => d.id === "tv-dom")!.kind as { state: string }).state,
      "on",
    );

    const expandTv =
      root.querySelector<HTMLElement>('[data-expand-device="tv-dom"]') ??
      root.querySelector<HTMLElement>('[data-body-device="tv-dom"]');
    assert.ok(expandTv);
    expandTv.click();

    const volSlider = root.querySelector<HTMLInputElement>('input[data-volume="tv-dom"]');
    assert.ok(volSlider && !volSlider.disabled);
    volSlider.value = "55";
    volSlider.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "volume_set",
      entity_id: "media_player.tv_dom",
      data: { volume_level: 0.55 },
    });

    const muteBtn = root.querySelector<HTMLButtonElement>('button[data-speakermute="tv-dom"]');
    assert.ok(muteBtn && !muteBtn.disabled);
    muteBtn.click();
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "volume_mute",
      entity_id: "media_player.tv_dom",
      data: { is_volume_muted: true },
    });

    const sourceBtn = root.querySelector<HTMLButtonElement>('button[data-tvsource="tv-dom|HDMI 2"]');
    assert.ok(sourceBtn && !sourceBtn.disabled);
    sourceBtn.click();
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "select_source",
      entity_id: "media_player.tv_dom",
      data: { source: "HDMI 2" },
    });

    const expandHum =
      root.querySelector<HTMLElement>('[data-expand-device="hum-dom"]') ??
      root.querySelector<HTMLElement>('[data-body-device="hum-dom"]');
    assert.ok(expandHum);
    expandHum.click();

    const humSlider = root.querySelector<HTMLInputElement>('input[data-humidity="hum-dom"]');
    assert.ok(humSlider && !humSlider.disabled);
    humSlider.value = "65";
    humSlider.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "humidifier",
      service: "set_humidity",
      entity_id: "humidifier.hum_dom",
      data: { humidity: 65 },
    });

    const modeBtn = root.querySelector<HTMLButtonElement>('button[data-humidifiermode="hum-dom|sleep"]');
    assert.ok(modeBtn && !modeBtn.disabled);
    modeBtn.click();
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "humidifier",
      service: "set_mode",
      entity_id: "humidifier.hum_dom",
      data: { mode: "sleep" },
    });

    const toggleHumBtn = root.querySelector<HTMLButtonElement>('button[data-toggle-device="hum-dom"]');
    assert.ok(toggleHumBtn);
    toggleHumBtn.click();
    await flushAsyncTicks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "humidifier",
      service: "turn_off",
      entity_id: "humidifier.hum_dom",
      data: {},
    });

    cancelDelayedReadBack(app);
  });
});
