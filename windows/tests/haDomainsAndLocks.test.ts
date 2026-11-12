import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { ManualControlPolicy } from "../src/core/assistant/actionPolicy.js";
import {
  HomeAssistantSynthesizer,
  haServiceCall,
  homeAssistantCommand,
  homeAssistantIdentity,
  parseCachedHAHome,
} from "../src/core/homeAssistant.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  deviceCanTogglePower,
  deviceStatusSummary,
  hasDetailDrawer,
  isDeviceActiveOn,
  type CoverSpec,
  type FacetControl,
  type SmartDevice,
} from "../src/core/models.js";
import {
  cancelDelayedReadBack,
  coverTravelTakesOver,
  hasPendingReadBack,
  isOptimisticallyLocked,
  lockOptimistic,
  mergeHomeSnapshotRespectingLocks,
  mergeSnapshotRespectingLocks,
  OPTIMISTIC_LOCK_DURATION_MS,
  optimisticLockRevision,
  scheduleDelayedReadBack,
  type OptimisticLockHost,
} from "../src/core/optimisticLock.js";
import { refreshHADevices } from "../src/ui/cloudRefresh.js";
import { applyCommand } from "../src/ui/commandDispatch.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

function loadFixture(name: string): unknown {
  const path = resolve(process.cwd(), `../Tests/Fixtures/${name}`);
  return JSON.parse(readFileSync(path, "utf8")) as unknown;
}

function byId(devices: readonly SmartDevice[]): Map<string, SmartDevice> {
  return new Map(devices.map((d) => [d.id, d]));
}

let activeDom: Window | null = null;

afterEach(async () => {
  setLanguage("zh-Hans");
  if (activeDom) {
    await closeTestWindow(activeDom);
    activeDom = null;
  }
});

describe("Home Assistant domain synthesis & golden fixtures", () => {
  it("matches ha_domain_cards.json for humidifiers, water heaters, valves, and 更多设置 facets", () => {
    const raw = loadFixture("ha_domain_cards.json");
    const home = HomeAssistantSynthesizer.synthesize(raw);
    const map = byId(home.devices);

    // 1. Full humidifier card + 6 unclaimed facets
    const humFull = map.get("humidifier-full");
    assert.ok(humFull, "humidifier-full card exists");
    assert.equal(humFull.name, "客厅加湿器");
    assert.equal(humFull.roomName, "客厅");
    assert.equal(humFull.isOnline, true);
    assert.equal(humFull.kind.kind, "appliance");
    assert.equal(humFull.kind.entityId, "humidifier.living");
    assert.equal(humFull.kind.isOn, true);
    assert.equal(humFull.kind.powerWritable, true);
    assert.equal(humFull.kind.currentMode, "auto");
    assert.deepEqual(humFull.kind.availableModes, ["auto", "sleep", "strong"]);
    assert.equal(humFull.kind.modeWritable, true);
    assert.equal(humFull.kind.minTemp, 30);
    assert.equal(humFull.kind.maxTemp, 80);
    assert.equal(humFull.kind.step, 5);
    assert.equal(humFull.kind.currentHumidity, 48, "entity current_humidity beats sensor.living_humidity (47)");
    assert.equal(humFull.kind.symbolName, "humidity.fill");
    assert.equal(humFull.kind.roomReading, true);
    assert.equal(humFull.kind.heats, false);
    assert.equal(hasDetailDrawer(humFull, home.deviceFacets?.["humidifier-full"] ?? []), true);
    const humSubtitle = deviceStatusSummary(humFull);
    assert.ok(humSubtitle.includes("48"), `expected 48 in "${humSubtitle}"`);
    assert.ok(humSubtitle.includes("55"), `expected 55 in "${humSubtitle}"`);
    assert.equal(home.environmentReadings.find((r) => r.id === "humidifier-full")?.humidity, 48);

    const facets = home.deviceFacets?.["humidifier-full"] ?? [];
    assert.deepEqual(
      facets.map((f) => f.id),
      [
        "humidifier.living#target_humidity",
        "switch.living_led",
        "select.living_fan_mode",
        "number.target_level",
        "button.living_self_clean",
        "sensor.living_battery",
        "binary_sensor.living_water_shortage",
      ],
      "prepends synthetic target humidity slider and skips claimed sensor.living_humidity, text.living_note, and config switch.living_reboot",
    );

    const humTargetSlider = facets.find((f) => f.id === "humidifier.living#target_humidity");
    assert.equal(humTargetSlider?.kind, "slider");
    assert.equal(humTargetSlider?.name, "target-humidity");
    assert.equal(humTargetSlider?.serviceName, "humidifier");
    assert.equal(humTargetSlider?.unit, "percentage");
    assert.equal(humTargetSlider?.value, 55);
    assert.deepEqual(humTargetSlider?.range, { min: 30, max: 80, step: 5 });
    assert.equal(humTargetSlider?.writesByDefault, true);
    assert.equal(humTargetSlider?.isHighValue, true);

    const led = facets.find((f) => f.id === "switch.living_led");
    assert.equal(led?.kind, "toggle");
    assert.equal(led?.value, true);
    assert.equal(led?.writesByDefault, true);
    assert.deepEqual(led?.target, { kind: "property", entityId: "switch.living_led", piid: 0 });

    const fanSelect = facets.find((f) => f.id === "select.living_fan_mode");
    assert.equal(fanSelect?.kind, "select");
    assert.equal(fanSelect?.value, 1);
    assert.deepEqual(fanSelect?.options.map((o) => o.label), ["low", "medium", "high"]);
    assert.equal(fanSelect?.writesByDefault, true);

    const slider = facets.find((f) => f.id === "number.target_level");
    assert.equal(slider?.kind, "slider");
    assert.equal(slider?.value, 40);
    assert.deepEqual(slider?.range, { min: 0, max: 100, step: 10 });
    assert.equal(slider?.isHighValue, true);
    assert.equal(slider?.writesByDefault, false);

    const button = facets.find((f) => f.id === "button.living_self_clean");
    assert.equal(button?.kind, "button");
    assert.equal(button?.writesByDefault, false);
    assert.deepEqual(button?.target, { kind: "action", entityId: "button.living_self_clean" });

    const battery = facets.find((f) => f.id === "sensor.living_battery");
    assert.equal(battery?.kind, "reading");
    assert.equal(battery?.value, 88);
    assert.equal(battery?.unit, "%");

    const shortage = facets.find((f) => f.id === "binary_sensor.living_water_shortage");
    assert.equal(shortage?.kind, "reading");
    assert.equal(shortage?.value, false);

    // 2. Minimal humidifier card
    const humMin = map.get("humidifier-minimal");
    assert.ok(humMin);
    assert.equal(humMin.kind.kind, "appliance");
    assert.equal(humMin.kind.isOn, false);
    assert.deepEqual(humMin.kind.availableModes, []);
    assert.equal(humMin.kind.modeWritable, false);
    assert.equal(humMin.kind.minTemp, 0);
    assert.equal(humMin.kind.maxTemp, 100);
    assert.equal(humMin.kind.step, 1);
    assert.equal(humMin.kind.currentHumidity, null);
    assert.equal(hasDetailDrawer(humMin, home.deviceFacets?.["humidifier-minimal"] ?? []), false);
    assert.equal(deviceCanTogglePower(humMin), true);

    // 3. Full & minimal water heater cards + high-risk heat confirmation
    const whFull = map.get("water-heater-full");
    assert.ok(whFull);
    assert.equal(whFull.kind.kind, "appliance");
    assert.equal(whFull.kind.entityId, "water_heater.boiler");
    assert.equal(whFull.kind.isOn, true);
    assert.equal(whFull.kind.currentMode, "eco");
    assert.deepEqual(whFull.kind.availableModes, ["eco", "performance", "electric"]);
    assert.equal(whFull.kind.modeWritable, true);
    assert.equal(whFull.kind.targetTemperature, 55);
    assert.equal(whFull.kind.currentTemperature, 48);
    assert.equal(whFull.kind.minTemp, 35);
    assert.equal(whFull.kind.maxTemp, 75);
    assert.equal(whFull.kind.step, 1);
    assert.equal(whFull.kind.temperatureWritable, true);
    assert.equal(whFull.kind.heats, true);
    assert.equal(whFull.kind.symbolName, "water.waves");
    assert.equal(hasDetailDrawer(whFull), true);

    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: whFull.id, operation: { kind: "power", isOn: true } },
        home.devices,
      ),
      true,
    );
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: whFull.id, operation: { kind: "power", isOn: false } },
        home.devices,
      ),
      false,
    );
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: whFull.id, operation: { kind: "targetTemperature", celsius: 56 } },
        home.devices,
      ),
      true,
    );
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: whFull.id, operation: { kind: "targetTemperature", celsius: 54 } },
        home.devices,
      ),
      false,
    );

    const whMin = map.get("water-heater-minimal");
    assert.ok(whMin);
    assert.equal(whMin.kind.kind, "appliance");
    assert.equal(whMin.kind.isOn, false);
    assert.equal(whMin.kind.heats, true);
    assert.equal(whMin.kind.temperatureWritable, false);
    assert.equal(hasDetailDrawer(whMin), false);
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: whMin.id, operation: { kind: "power", isOn: true } },
        home.devices,
      ),
      true,
    );

    // 4. Water, gas, and minimal valve cards + open confirmation
    const valveWater = map.get("valve-water");
    assert.ok(valveWater);
    assert.equal(valveWater.kind.kind, "appliance");
    assert.equal(valveWater.kind.entityId, "valve.water_main");
    assert.equal(valveWater.kind.isOn, true);
    assert.equal(valveWater.kind.symbolName, "drop.fill");
    assert.equal(valveWater.kind.heats, true);
    assert.equal(isDeviceActiveOn(valveWater), true);
    assert.equal(hasDetailDrawer(valveWater), false);
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: valveWater.id, operation: { kind: "power", isOn: true } },
        home.devices,
      ),
      true,
    );
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: valveWater.id, operation: { kind: "power", isOn: false } },
        home.devices,
      ),
      false,
    );

    const valveGas = map.get("valve-gas");
    assert.ok(valveGas);
    assert.equal(valveGas.kind.kind, "appliance");
    assert.equal(valveGas.kind.isOn, false);
    assert.equal(valveGas.kind.symbolName, "flame");
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: valveGas.id, operation: { kind: "power", isOn: true } },
        home.devices,
      ),
      true,
    );
    assert.equal(
      ManualControlPolicy.requiresConfirmation(
        { targetId: valveGas.id, operation: { kind: "power", isOn: false } },
        home.devices,
      ),
      false,
    );

    const valveMin = map.get("valve-minimal");
    assert.ok(valveMin);
    assert.equal(valveMin.kind.kind, "appliance");
    assert.equal(valveMin.kind.isOn, false);
    assert.equal(valveMin.kind.powerWritable, true);

    // 5. Parity edge cases: target-humidity-only humidifier, valve SET_POSITION / closing / powerWritable,
    //    and media_player power / play-pause / source controls.
    const parityHome = HomeAssistantSynthesizer.synthesize({
      areas: [],
      devices: [
        { id: "hum_only_target", name: "卧室加湿器" },
        { id: "valve_pos_dev", name: "总水阀" },
        { id: "valve_closing_dev", name: "关闭中水阀" },
        { id: "valve_close_only_dev", name: "单向关阀" },
        { id: "valve_open_only_dev", name: "单向开阀" },
        { id: "tv_speaker_dev", name: "客厅音响" },
      ],
      entities: [
        { entity_id: "humidifier.only_target", device_id: "hum_only_target" },
        { entity_id: "valve.pos_main", device_id: "valve_pos_dev" },
        { entity_id: "valve.closing_one", device_id: "valve_closing_dev" },
        { entity_id: "valve.close_only", device_id: "valve_close_only_dev" },
        { entity_id: "valve.open_only", device_id: "valve_open_only_dev" },
        { entity_id: "media_player.living_speaker", device_id: "tv_speaker_dev" },
      ],
      states: [
        {
          entity_id: "humidifier.only_target",
          state: "on",
          attributes: { humidity: 50, min_humidity: 35, max_humidity: 75, supported_features: 1 },
        },
        {
          entity_id: "valve.pos_main",
          state: "open",
          attributes: { device_class: "water", current_position: 35, supported_features: 7 },
        },
        {
          entity_id: "valve.closing_one",
          state: "closing",
          attributes: { device_class: "water", current_position: 40, supported_features: 3 },
        },
        {
          entity_id: "valve.close_only",
          state: "closed",
          attributes: { device_class: "water", supported_features: 2 },
        },
        {
          entity_id: "valve.open_only",
          state: "open",
          attributes: { device_class: "water", supported_features: 1 },
        },
        {
          entity_id: "media_player.living_speaker",
          state: "paused",
          attributes: {
            supported_features: 1 | 128 | 256 | 2048 | 16384,
            source_list: ["Spotify", "AirPlay"],
            source: "AirPlay",
          },
        },
      ],
    });
    const parityMap = byId(parityHome.devices);

    const humOnly = parityMap.get("hum_only_target")!;
    const humOnlyFacets = parityHome.deviceFacets?.["hum_only_target"] ?? [];
    assert.equal(humOnlyFacets.length, 1);
    assert.equal(humOnlyFacets[0]?.id, "humidifier.only_target#target_humidity");
    assert.equal(hasDetailDrawer(humOnly, humOnlyFacets), true, "target-humidity-only humidifier expands drawer");

    const valvePos = parityMap.get("valve_pos_dev")!;
    const valvePosFacets = parityHome.deviceFacets?.["valve_pos_dev"] ?? [];
    assert.equal(valvePosFacets.length, 1);
    assert.equal(valvePosFacets[0]?.id, "valve.pos_main#position");
    assert.equal(valvePosFacets[0]?.serviceName, "water-valve");
    assert.equal(valvePosFacets[0]?.writesByDefault, false);
    assert.equal(valvePosFacets[0]?.isConfirmedWrite, true);
    assert.equal(hasDetailDrawer(valvePos, valvePosFacets), true);
    assert.equal(
      ManualControlPolicy.facetRequiresConfirmation(valvePosFacets[0]!, 50, valvePos),
      true,
      "valve position write must always require confirmation",
    );
    const cachedRoundTrip = parseCachedHAHome(
      JSON.parse(JSON.stringify({ identity: "http://192.168.1.8:8123|tok", home: parityHome })),
    );
    assert.equal(
      cachedRoundTrip?.home.deviceFacets?.["valve_pos_dev"]?.[0]?.isConfirmedWrite,
      true,
      "parseCachedHAHome preserves isConfirmedWrite on synthetic valve position facet",
    );

    const valveClosing = parityMap.get("valve_closing_dev")!;
    assert.equal(valveClosing.kind.kind, "appliance");
    assert.equal(valveClosing.kind.isOn, false, "closing valve with current_position > 0 must have isOn: false");
    assert.equal(valveClosing.kind.statusText, "正在关闭");

    const valveCloseOnly = parityMap.get("valve_close_only_dev")!;
    assert.equal(valveCloseOnly.kind.kind, "appliance");
    assert.equal(valveCloseOnly.kind.powerWritable, false, "closed valve without OPEN bit cannot toggle on");

    const valveOpenOnly = parityMap.get("valve_open_only_dev")!;
    assert.equal(valveOpenOnly.kind.kind, "appliance");
    assert.equal(valveOpenOnly.kind.powerWritable, false, "open valve without CLOSE bit cannot toggle off");

    const tvSpeaker = parityMap.get("tv_speaker_dev")!;
    const tvSpeakerFacets = parityHome.deviceFacets?.["tv_speaker_dev"] ?? [];
    assert.deepEqual(
      tvSpeakerFacets.map((f) => f.id),
      [
        "media_player.living_speaker#play_pause",
        "media_player.living_speaker#power",
        "media_player.living_speaker#source",
      ],
    );
    assert.equal(tvSpeakerFacets[0]?.value, false);
    assert.equal(tvSpeakerFacets[1]?.value, true);
    assert.equal(tvSpeakerFacets[2]?.value, 1);
    assert.equal(hasDetailDrawer(tvSpeaker, tvSpeakerFacets), true);
  });

  it("matches ha_cover_snapshot.json and splits dual-track covers sharing one HA device_id", () => {
    const raw = loadFixture("ha_cover_snapshot.json");
    const home = HomeAssistantSynthesizer.synthesize(raw);
    assert.equal(home.devices.length, 20);
    const map = byId(home.devices);

    const expectedSubtypes: ReadonlyArray<[string, CoverSpec["subtype"], number, boolean, string | null]> = [
      ["ha_class_curtain", "curtain", 60, true, "Pause"],
      ["ha_class_blind", "curtain", 45, true, "Pause"],
      ["ha_class_shade", "curtain", 0, true, "Pause"],
      ["ha_class_shutter", "curtain", 0, false, "Pause"],
      ["ha_class_awning", "curtain", 80, true, "Pause"],
      ["ha_class_damper", "curtain", 100, true, "Pause"],
      ["ha_class_window", "window-opener", 0, true, "Pause"],
      ["ha_class_garage", "garage-door", 0, false, "Pause"],
      ["ha_class_gate", "garage-door", 100, true, "Pause"],
      ["ha_class_door", "garage-door", 0, false, null],
      ["ha_name_cn_curtain", "curtain", 50, true, "Pause"],
      ["ha_name_en_curtain", "curtain", 0, true, "Pause"],
      ["ha_name_en_blind", "curtain", 30, true, "Pause"],
      ["ha_name_cn_garage", "garage-door", 0, false, "Pause"],
      ["ha_name_cn_gate", "garage-door", 0, false, "Pause"],
      ["ha_name_en_garage", "garage-door", 100, false, "Pause"],
      ["ha_name_en_gate", "garage-door", 100, false, "Pause"],
      ["ha_name_cn_window", "window-opener", 0, true, "Pause"],
      ["ha_name_en_window", "window-opener", 25, true, "Pause"],
      ["ha_fallback_unknown", "window-opener", 0, false, "Pause"],
    ];

    for (const [id, subtype, pos, posWritable, pause] of expectedSubtypes) {
      const dev = map.get(id);
      assert.ok(dev, `missing cover card ${id}`);
      assert.equal(dev.kind.kind, "cover");
      assert.equal(dev.kind.subtype, subtype, `subtype mismatch on ${id}`);
      assert.equal(dev.kind.positionPercent, pos, `position mismatch on ${id}`);
      assert.equal(dev.kind.positionWritable, posWritable, `positionWritable mismatch on ${id}`);
      assert.equal(dev.kind.pauseDescription, pause, `pauseDescription mismatch on ${id}`);
    }
    const curtain = map.get("ha_class_curtain")!;
    assert.equal(curtain.kind.kind === "cover" ? curtain.kind.batteryPercent : null, 88);
    assert.equal(home.deviceFacets?.["ha_class_curtain"], undefined, "claimed battery sensor stays out of facets");

    // Dual-track cover sharing one HA device_id + distinct/shared auxiliary controls + airer inference
    const dualSnapshot = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "dual_curtain_dev", area_id: "living", name: "双轨窗帘", model: "lumi.curtain.dual" },
        { id: "balcony_airer", area_id: "living", name: "智能晾衣机", model: "hyd.airer.znlyj1" },
      ],
      entities: [
        { entity_id: "cover.living_cloth_curtain", device_id: "dual_curtain_dev", name: "客厅布帘" },
        { entity_id: "cover.living_gauze_curtain", device_id: "dual_curtain_dev", name: "客厅纱帘" },
        { entity_id: "sensor.cloth_battery", device_id: "dual_curtain_dev" },
        { entity_id: "sensor.gauze_battery", device_id: "dual_curtain_dev" },
        { entity_id: "switch.living_cloth_reverse", device_id: "dual_curtain_dev" },
        { entity_id: "switch.curtain_indicator_led", device_id: "dual_curtain_dev" },
        { entity_id: "cover.balcony_airer", device_id: "balcony_airer" },
      ],
      states: [
        {
          entity_id: "cover.living_cloth_curtain",
          state: "open",
          attributes: { device_class: "curtain", current_position: 75, supported_features: 15 },
        },
        {
          entity_id: "cover.living_gauze_curtain",
          state: "closing",
          attributes: { device_class: "curtain", current_position: 30, supported_features: 15 },
        },
        { entity_id: "sensor.cloth_battery", state: "91", attributes: { device_class: "battery" } },
        { entity_id: "sensor.gauze_battery", state: "84", attributes: { device_class: "battery" } },
        { entity_id: "switch.living_cloth_reverse", state: "off", attributes: { friendly_name: "布帘反向" } },
        { entity_id: "switch.curtain_indicator_led", state: "on", attributes: { friendly_name: "指示灯" } },
        { entity_id: "cover.balcony_airer", state: "opening", attributes: { current_position: 40, supported_features: 15 } },
      ],
    };

    const dualHome = HomeAssistantSynthesizer.synthesize(dualSnapshot);
    const dualMap = byId(dualHome.devices);
    const cloth = dualMap.get("dual_curtain_dev#cover.living_cloth_curtain");
    const gauze = dualMap.get("dual_curtain_dev#cover.living_gauze_curtain");
    const airer = dualMap.get("balcony_airer");
    assert.ok(cloth && cloth.kind.kind === "cover");
    assert.ok(gauze && gauze.kind.kind === "cover");
    assert.ok(airer && airer.kind.kind === "cover");
    assert.equal(cloth.name, "客厅布帘");
    assert.equal(cloth.kind.positionPercent, 75);
    assert.equal(cloth.kind.batteryPercent, 91);
    assert.equal(gauze.name, "客厅纱帘");
    assert.equal(gauze.kind.motion, "closing");
    assert.equal(gauze.kind.batteryPercent, 84);
    assert.equal(airer.kind.subtype, "clothes-airer");
    assert.equal(airer.kind.motion, "opening");

    assert.deepEqual(
      dualHome.deviceFacets?.["dual_curtain_dev#cover.living_cloth_curtain"]?.map((f) => f.id),
      ["switch.living_cloth_reverse", "switch.curtain_indicator_led"],
    );
    assert.deepEqual(
      dualHome.deviceFacets?.["dual_curtain_dev#cover.living_gauze_curtain"]?.map((f) => f.id),
      ["switch.curtain_indicator_led"],
    );
  });

  it("replays ha_regressions.json without regressing climate, switch-camera, or air purifier cards", () => {
    const raw = loadFixture("ha_regressions.json");
    const home = HomeAssistantSynthesizer.synthesize(raw);
    const map = byId(home.devices);
    assert.equal(map.get("heat-only")?.kind.kind, "climate");
    assert.equal(map.get("dev_cam_1")?.kind.kind, "camera");
    const airp = map.get("dev_airp_1");
    assert.ok(airp && airp.kind.kind === "fan");
    assert.equal(airp.kind.pm25Density, 18);
    assert.equal(airp.kind.temperature, 24.5);
    assert.equal(airp.kind.humidity, 52);
    assert.equal(airp.kind.filterLifePercent, 86);
    assert.equal(home.deviceFacets?.["dev_airp_1"], undefined, "claimed purifier sensors do not duplicate in facets");
  });

  it("never leaks disabled_by or hidden_by registry entities back through states fallback (CODING_STANDARDS §1)", () => {
    const snapshot = {
      areas: [{ area_id: "study", name: "书房" }],
      devices: [
        { id: "dev_active", area_id: "study", name: "台灯", model: "yeelight.light.lamp" },
        { id: "dev_disabled", area_id: "study", name: "停用插座", model: "cuco.plug.v3", disabled_by: "user" },
      ],
      entities: [
        { entity_id: "light.desk", device_id: "dev_active" },
        { entity_id: "switch.hidden_usb", device_id: "dev_active", hidden_by: "user" },
        { entity_id: "number.disabled_dimmer", device_id: "dev_active", disabled_by: "integration" },
        { entity_id: "switch.disabled_plug", device_id: "dev_disabled" },
        { entity_id: "humidifier.standalone_disabled", device_id: null, disabled_by: "user" },
        { entity_id: "valve.standalone_hidden", device_id: null, hidden_by: "integration" },
        { entity_id: "scene.disabled_movie", disabled_by: "user" },
        { entity_id: "script.hidden_sleep", hidden_by: "user" },
        { entity_id: "scene.active_reading", name: "阅读模式" },
      ],
      states: [
        { entity_id: "light.desk", state: "on", attributes: { brightness: 128 } },
        { entity_id: "switch.hidden_usb", state: "on", attributes: { friendly_name: "USB" } },
        { entity_id: "number.disabled_dimmer", state: "50", attributes: { min: 0, max: 100 } },
        { entity_id: "switch.disabled_plug", state: "on", attributes: { device_class: "outlet" } },
        { entity_id: "humidifier.standalone_disabled", state: "on", attributes: {} },
        { entity_id: "valve.standalone_hidden", state: "open", attributes: {} },
        { entity_id: "scene.disabled_movie", state: "scening", attributes: { friendly_name: "观影" } },
        { entity_id: "script.hidden_sleep", state: "off", attributes: { friendly_name: "晚安" } },
        { entity_id: "scene.active_reading", state: "scening", attributes: { friendly_name: "阅读" } },
      ],
    };

    const home = HomeAssistantSynthesizer.synthesize(snapshot);
    assert.deepEqual(home.devices.map((d) => d.id), ["dev_active"]);
    assert.equal(home.deviceFacets?.["dev_active"], undefined);
    assert.deepEqual(home.scenes.map((s) => s.entityId), ["scene.active_reading"]);
  });

  it("synthesizes media_player, binary_sensor (locale-reactive), standalone button, input_boolean, and read-only lock", () => {
    const snapshot = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "speaker_dev", area_id: "living", name: "小爱音箱", model: "xiaomi.wifispeaker.lx06" },
        { id: "leak_dev", area_id: "living", name: "水浸传感器", model: "lumi.sensor_wleak.aq1" },
        { id: "wol_dev", area_id: "living", name: "书房主机", model: "Wake on LAN" },
        { id: "lock_dev", area_id: "living", name: "入户门锁", model: "xiaomi.lock.pro" },
      ],
      entities: [
        { entity_id: "media_player.xiaoai", device_id: "speaker_dev" },
        { entity_id: "switch.xiaoai_sleep_mode", device_id: "speaker_dev" },
        { entity_id: "select.xiaoai_source", device_id: "speaker_dev", translation_key: "mode" },
        { entity_id: "binary_sensor.kitchen_leak", device_id: "leak_dev" },
        { entity_id: "sensor.kitchen_leak_battery", device_id: "leak_dev" },
        { entity_id: "button.wake_on_lan_pc", device_id: "wol_dev" },
        { entity_id: "button.aux_action", device_id: "wol_dev" },
        { entity_id: "button.aux_restart", device_id: "wol_dev" },
        { entity_id: "lock.front_door", device_id: "lock_dev" },
        { entity_id: "switch.front_door_auto_lock", device_id: "lock_dev" },
      ],
      states: [
        {
          entity_id: "media_player.xiaoai",
          state: "playing",
          attributes: { volume_level: 0.35, is_volume_muted: false, supported_features: 12 },
        },
        { entity_id: "switch.xiaoai_sleep_mode", state: "off", attributes: {} },
        { entity_id: "select.xiaoai_source", state: "Bluetooth", attributes: { options: ["WiFi", "Bluetooth"] } },
        {
          entity_id: "binary_sensor.kitchen_leak",
          state: "on",
          attributes: { device_class: "moisture" },
        },
        {
          entity_id: "sensor.kitchen_leak_battery",
          state: "95",
          attributes: { device_class: "battery" },
        },
        { entity_id: "button.wake_on_lan_pc", state: "unknown", attributes: {} },
        { entity_id: "button.aux_action", state: "unknown", attributes: { friendly_name: "休眠" } },
        { entity_id: "button.aux_restart", state: "unknown", attributes: { device_class: "restart" } },
        { entity_id: "lock.front_door", state: "locked", attributes: {} },
        { entity_id: "switch.front_door_auto_lock", state: "on", attributes: { friendly_name: "自动上锁" } },
        { entity_id: "binary_sensor.hall_motion", state: "on", attributes: { friendly_name: "玄关人体" } },
        { entity_id: "input_boolean.guest_mode", state: "on", attributes: { friendly_name: "访客模式" } },
      ],
    };

    setLanguage("zh-Hans");
    const zhHome = HomeAssistantSynthesizer.synthesize(snapshot);
    const zhMap = byId(zhHome.devices);

    const speaker = zhMap.get("speaker_dev");
    assert.ok(speaker && speaker.kind.kind === "speaker");
    assert.equal(speaker.kind.mediaEntityId, "media_player.xiaoai");
    assert.equal(speaker.kind.state, "playing");
    assert.equal(speaker.kind.volumePercent, 35);
    assert.equal(speaker.kind.muteSwitchEntityId, "media_player.xiaoai#mute");
    assert.equal(speaker.kind.sleepModeEntityId, "switch.xiaoai_sleep_mode");
    assert.deepEqual(zhHome.deviceFacets?.["speaker_dev"]?.map((f) => f.id), ["select.xiaoai_source"]);
    assert.equal(zhHome.deviceFacets?.["speaker_dev"]?.[0]?.name, "mode", "translation_key wins over objectId");

    const leak = zhMap.get("leak_dev");
    assert.ok(leak && leak.kind.kind === "sensor");
    assert.equal(leak.kind.statusText, "检测到漏水");
    assert.equal(leak.kind.battery, 95);
    assert.equal(zhHome.deviceFacets?.["leak_dev"], undefined);

    const hallMotion = zhMap.get("binary_sensor.hall_motion");
    assert.ok(hallMotion && hallMotion.kind.kind === "sensor");
    assert.equal(hallMotion.kind.statusText, "有人");
    assert.equal(zhHome.deviceFacets?.["binary_sensor.hall_motion"], undefined);

    const wol = zhMap.get("wol_dev");
    assert.ok(wol && wol.kind.kind === "plug");
    assert.equal(wol.kind.switchEntityId, "button.wake_on_lan_pc");
    assert.deepEqual(zhHome.deviceFacets?.["wol_dev"]?.map((f) => f.id), ["button.aux_action"]);

    const guestToggle = zhMap.get("input_boolean.guest_mode");
    assert.ok(guestToggle && guestToggle.kind.kind === "plug");
    assert.equal(guestToggle.kind.switchEntityId, "input_boolean.guest_mode");
    assert.equal(guestToggle.kind.isOn, true);

    const lock = zhMap.get("lock_dev");
    assert.ok(lock && lock.kind.kind === "sensor", "companion switch must not turn lock device into plug");
    assert.equal(lock.kind.statusText, "已上锁");

    // Switch language to English and verify speechLocale()-driven HA synthesis strings
    setLanguage("en");
    const enHome = HomeAssistantSynthesizer.synthesize(snapshot);
    const enMap = byId(enHome.devices);
    const enLeak = enMap.get("leak_dev");
    const enMotion = enMap.get("binary_sensor.hall_motion");
    const enLock = enMap.get("lock_dev");
    assert.ok(enLeak && enLeak.kind.kind === "sensor");
    assert.ok(enMotion && enMotion.kind.kind === "sensor");
    assert.ok(enLock && enLock.kind.kind === "sensor");
    assert.equal(enLeak.kind.statusText, "Leak detected");
    assert.equal(enMotion.kind.statusText, "Detected");
    assert.equal(enLock.kind.statusText, "Locked");
  });
});

describe("HA service mapping, subpath identity, and cache round-trip", () => {
  it("maps humidifier, water_heater, valve, media_player, input_boolean, button scene, and facet writes while rejecting lock", () => {
    // Humidifier
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "humidifier.living", isOn: true }), {
      domain: "humidifier",
      service: "turn_on",
      entity_id: "humidifier.living",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "setSelectOption", entityId: "humidifier.living", option: "sleep" }), {
      domain: "humidifier",
      service: "set_mode",
      entity_id: "humidifier.living",
      data: { mode: "sleep" },
    });
    assert.deepEqual(haServiceCall({ kind: "setNumberValue", entityId: "humidifier.living", value: 60 }), {
      domain: "humidifier",
      service: "set_humidity",
      entity_id: "humidifier.living",
      data: { humidity: 60 },
    });

    // Water heater
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "water_heater.boiler", isOn: false }), {
      domain: "water_heater",
      service: "turn_off",
      entity_id: "water_heater.boiler",
      data: {},
    });
    assert.deepEqual(
      haServiceCall({ kind: "setClimateTemperature", entityId: "water_heater.boiler", temperature: 56 }),
      {
        domain: "water_heater",
        service: "set_temperature",
        entity_id: "water_heater.boiler",
        data: { temperature: 56 },
      },
    );
    assert.deepEqual(haServiceCall({ kind: "setSelectOption", entityId: "water_heater.boiler", option: "eco" }), {
      domain: "water_heater",
      service: "set_operation_mode",
      entity_id: "water_heater.boiler",
      data: { operation_mode: "eco" },
    });

    // Valve
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "valve.water_main", isOn: true }), {
      domain: "valve",
      service: "open_valve",
      entity_id: "valve.water_main",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "valve.water_main", isOn: false }), {
      domain: "valve",
      service: "close_valve",
      entity_id: "valve.water_main",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "pressButton", entityId: "valve.water_main#stop" }), {
      domain: "valve",
      service: "stop_valve",
      entity_id: "valve.water_main",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "setNumberValue", entityId: "valve.water_main", value: 45 }), {
      domain: "valve",
      service: "set_valve_position",
      entity_id: "valve.water_main",
      data: { position: 45 },
    });

    // Media player
    assert.deepEqual(haServiceCall({ kind: "pressButton", entityId: "media_player.xiaoai" }), {
      domain: "media_player",
      service: "media_play_pause",
      entity_id: "media_player.xiaoai",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "mediaSetVolume", entityId: "media_player.xiaoai", level: 0.42 }), {
      domain: "media_player",
      service: "volume_set",
      entity_id: "media_player.xiaoai",
      data: { volume_level: 0.42 },
    });
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "media_player.xiaoai#mute", isOn: true }), {
      domain: "media_player",
      service: "volume_mute",
      entity_id: "media_player.xiaoai",
      data: { is_volume_muted: true },
    });
    assert.deepEqual(haServiceCall({ kind: "setSelectOption", entityId: "media_player.xiaoai", option: "AUX" }), {
      domain: "media_player",
      service: "select_source",
      entity_id: "media_player.xiaoai",
      data: { source: "AUX" },
    });

    // input_boolean & button scene
    assert.deepEqual(haServiceCall({ kind: "setSwitch", entityId: "input_boolean.guest_mode", isOn: true }), {
      domain: "input_boolean",
      service: "turn_on",
      entity_id: "input_boolean.guest_mode",
      data: {},
    });
    assert.deepEqual(haServiceCall({ kind: "activateScene", entityId: "button.good_morning" }), {
      domain: "button",
      service: "press",
      entity_id: "button.good_morning",
      data: {},
    });

    // Facet setMiotProperty mapping via homeAssistantCommand
    const facets: Record<string, FacetControl[]> = {
      "humidifier-full": [
        {
          id: "select.living_fan_mode",
          kind: "select",
          name: "living-fan-mode",
          title: "风速",
          serviceName: "select",
          unit: null,
          scale: null,
          value: 0,
          options: [
            { value: 0, label: "low" },
            { value: 1, label: "medium" },
            { value: 2, label: "high" },
          ],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: false,
          target: { kind: "property", entityId: "select.living_fan_mode", piid: 0 },
        },
      ],
    };
    const mappedSelect = homeAssistantCommand(
      { kind: "setMiotProperty", entityId: "select.living_fan_mode", piid: 0, value: 2 },
      [],
      facets,
    );
    assert.deepEqual(mappedSelect, {
      kind: "setSelectOption",
      entityId: "select.living_fan_mode",
      option: "high",
    });
    assert.deepEqual(haServiceCall(mappedSelect), {
      domain: "select",
      service: "select_option",
      entity_id: "select.living_fan_mode",
      data: { option: "high" },
    });

    // Lock remains strictly forbidden (ADR-0001)
    assert.throws(
      () => haServiceCall({ kind: "setSwitch", entityId: "lock.front_door", isOn: false }),
      /read-only/,
    );
  });

  it("normalizes reverse-proxy subpath HA identities and round-trips cached HA cards + deviceFacets", () => {
    const idSub = homeAssistantIdentity("https://home.example.com/hass", "tok-1");
    const idSlash = homeAssistantIdentity("https://home.example.com/hass/", "tok-1");
    const idApi = homeAssistantIdentity("https://home.example.com/hass/api/", "tok-1");
    const idNested = homeAssistantIdentity("http://192.168.1.8:8123/proxy/ha", "tok-1");
    const idOther = homeAssistantIdentity("https://home.example.com/hass2", "tok-1");

    assert.ok(idSub?.startsWith("https://home.example.com/hass|"));
    assert.equal(idSub, idSlash);
    assert.equal(idSub, idApi);
    assert.ok(idNested?.startsWith("http://192.168.1.8:8123/proxy/ha|"));
    assert.notEqual(idSub, idOther);

    // Reject query, fragment, userinfo, traversal, encoded slashes, and backslashes
    assert.equal(homeAssistantIdentity("https://home.example.com/hass?x=1", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass#frag", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://user:pw@home.example.com/hass", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass/../admin", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass/%2e%2e/admin", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass%2fadmin", "tok-1"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass\\admin", "tok-1"), null);

    // Round-trip ha_domain_cards.json + speaker + camera (ensuring snapshotPath stays stripped)
    const home = HomeAssistantSynthesizer.synthesize(loadFixture("ha_domain_cards.json"));
    const withExtra = {
      ...home,
      devices: [
        ...home.devices,
        {
          id: "speaker-1",
          name: "音箱",
          roomId: "living",
          roomName: "客厅",
          model: "xiaomi.speaker",
          isOnline: true,
          kind: {
            kind: "speaker" as const,
            mediaEntityId: "media_player.living",
            state: "playing" as const,
            volumePercent: 40,
            isMuted: false,
            muteSwitchEntityId: "media_player.living#mute",
            sleepModeEntityId: null,
            isSleepMode: false,
            volumeWritable: true,
          },
        },
        {
          id: "cam-1",
          name: "摄像机",
          roomId: "living",
          roomName: "客厅",
          model: "chuangmi.camera",
          isOnline: true,
          kind: {
            kind: "camera" as const,
            entityId: "camera.living",
            isOn: true,
            nightShot: null,
            availableNightShots: [],
            motionDetectionEntityId: null,
            isMotionDetectionOn: null,
            streamEntityId: "camera.living",
            snapshotPath: "/api/camera_proxy/camera.living?token=secret",
          },
        },
      ],
    };
    const parsed = parseCachedHAHome(
      JSON.parse(JSON.stringify({ identity: idSub, home: withExtra })),
    );
    assert.ok(parsed);
    assert.equal(parsed.identity, idSub);
    assert.equal(parsed.home.devices.length, withExtra.devices.length);
    assert.equal(parsed.home.deviceFacets?.["humidifier-full"]?.length, 7);
    const parsedCam = parsed.home.devices.find((d) => d.id === "cam-1");
    assert.equal(parsedCam?.kind.kind === "camera" ? parsedCam.kind.snapshotPath : "bad", null);
  });
});

describe("Per-device optimistic write locks & 800ms delayed read-back", () => {
  it("preserves locked rows across stale polls, drops removed IDs, clears on confirmation, and invalidates on sourceRevision", () => {
    const makeLight = (id: string, isOn: boolean, brightnessPercent = 60): SmartDevice => ({
      id,
      name: id,
      roomId: "living",
      roomName: "客厅",
      model: "yeelink.light",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: `light.${id}`,
        isOn,
        brightnessPercent,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    });

    const host: OptimisticLockHost & { sourceRevision: number } = {
      sourceRevision: 1,
      devices: [makeLight("lamp", true, 80), makeLight("gone", false, 50)],
      deviceFacets: {
        lamp: [
          {
            id: "switch.lamp_led",
            kind: "toggle",
            name: "led",
            title: "指示灯",
            serviceName: "switch",
            unit: null,
            scale: null,
            value: false,
            options: [],
            range: null,
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: { kind: "property", entityId: "switch.lamp_led", piid: 0 },
          },
        ],
      },
    };

    const rev1 = lockOptimistic(host, "lamp", OPTIMISTIC_LOCK_DURATION_MS, {
      nowMs: 1_000,
      baselineDevice: makeLight("lamp", false, 60),
    });
    lockOptimistic(host, "gone", OPTIMISTIC_LOCK_DURATION_MS, { nowMs: 1_000 });
    assert.equal(rev1, 1);
    assert.equal(isOptimisticallyLocked(host, "lamp", 2_500), true);

    // 1. Stale poll within 3000ms keeps local optimistic row + local facets, while dropping removed `gone`
    const staleMerged = mergeHomeSnapshotRespectingLocks(
      host,
      [makeLight("lamp", false, 60)],
      {
        lamp: [{ ...host.deviceFacets!.lamp![0]!, value: true }],
      },
      2_500,
    );
    assert.deepEqual(staleMerged.devices.map((d) => d.id), ["lamp"]);
    assert.equal(staleMerged.devices[0]!.kind.kind === "light" && staleMerged.devices[0]!.kind.isOn, true);
    assert.equal(staleMerged.deviceFacets.lamp?.[0]?.value, false);
    assert.equal(isOptimisticallyLocked(host, "gone", 2_500), false, "removed device lock dropped");
    assert.equal(isOptimisticallyLocked(host, "lamp", 2_500), true);

    // 2. Confirming poll clears lock early before 3000ms expiry
    const confirmedMerged = mergeHomeSnapshotRespectingLocks(
      host,
      [makeLight("lamp", true, 80)],
      {
        lamp: [{ ...host.deviceFacets!.lamp![0]!, value: false }],
      },
      2_800,
    );
    assert.equal(confirmedMerged.devices[0]!.kind.kind === "light" && confirmedMerged.devices[0]!.kind.isOn, true);
    assert.equal(isOptimisticallyLocked(host, "lamp", 2_800), false, "confirmed write clears lock early");

    // 3. Expired lock adopts incoming state
    lockOptimistic(host, "lamp", 3_000, { nowMs: 5_000 });
    const expiredMerged = mergeSnapshotRespectingLocks(host, [makeLight("lamp", false, 30)], 8_001);
    assert.equal(expiredMerged[0]!.kind.kind === "light" && expiredMerged[0]!.kind.isOn, false);

    // 4. Changing host.sourceRevision invalidates all locks & pending read-back tickets
    lockOptimistic(host, "lamp", 3_000, { nowMs: 9_000 });
    const ticket = scheduleDelayedReadBack(host, "lamp", 5_000, () => {});
    assert.equal(isOptimisticallyLocked(host, "lamp", 9_100), true);
    assert.equal(hasPendingReadBack(host, "lamp"), true);

    host.sourceRevision = 2;
    assert.equal(isOptimisticallyLocked(host, "lamp", 9_100), false);
    assert.equal(optimisticLockRevision(host, "lamp"), 0);
    assert.equal(ticket.isCancelled(), true);
    assert.equal(hasPendingReadBack(host, "lamp"), false);
  });

  it("holds cover locks across stale pre-command origin and mid-travel until target reached or stopped post-travel", () => {
    const makeCover = (positionPercent: number, motion: CoverSpec["motion"]): SmartDevice => ({
      id: "curtain-1",
      name: "客厅窗帘",
      roomId: "living",
      roomName: "客厅",
      model: "lumi.curtain",
      isOnline: true,
      kind: {
        kind: "cover",
        entityId: "cover.living",
        subtype: "curtain",
        positionPercent,
        positionWritable: true,
        openDescription: "Open",
        closeDescription: "Close",
        pauseDescription: "Pause",
        batteryPercent: 90,
        faultText: null,
        motion,
      },
    });

    const host: OptimisticLockHost = {
      sourceRevision: 1,
      devices: [makeCover(100, "opening")],
    };
    lockOptimistic(host, "curtain-1", 3_000, { nowMs: 1_000, coverOriginPosition: 0 });

    // Stale origin (0, stopped) does NOT take over
    const atOrigin = mergeSnapshotRespectingLocks(host, [makeCover(0, "stopped")], 1_500);
    assert.equal(atOrigin[0]!.kind.kind === "cover" ? atOrigin[0]!.kind.positionPercent : -1, 100);
    assert.equal(isOptimisticallyLocked(host, "curtain-1", 1_500), true);

    // Mid-travel (45, opening) does NOT take over yet
    const midTravel = mergeSnapshotRespectingLocks(host, [makeCover(45, "opening")], 2_000);
    assert.equal(midTravel[0]!.kind.kind === "cover" ? midTravel[0]!.kind.positionPercent : -1, 100);
    assert.equal(isOptimisticallyLocked(host, "curtain-1", 2_000), true);

    // Stopped at a new post-travel position (72, stopped) DOES take over and clears lock
    assert.equal(
      coverTravelTakesOver(
        0,
        host.devices[0]!.kind as CoverSpec,
        makeCover(72, "stopped").kind as CoverSpec,
      ),
      true,
    );
    const settled = mergeSnapshotRespectingLocks(host, [makeCover(72, "stopped")], 2_400);
    assert.equal(settled[0]!.kind.kind === "cover" ? settled[0]!.kind.positionPercent : -1, 72);
    assert.equal(isOptimisticallyLocked(host, "curtain-1", 2_400), false);
  });

  it("cancels superseded 800ms ReadBackTicket on newer write and runs silent read-back for the latest ticket", async () => {
    let readBackCount = 0;
    const host: OptimisticLockHost = {
      sourceRevision: 1,
      devices: [],
      refreshDevices: async (silent) => {
        if (silent) readBackCount += 1;
      },
    };

    const first = scheduleDelayedReadBack(host, "dev-1", 25);
    const second = scheduleDelayedReadBack(host, "dev-1", 25);
    assert.equal(first.isCancelled(), true, "newer write cancels previous ReadBackTicket");
    assert.equal(second.isCancelled(), false);

    await new Promise((resolveTimer) => setTimeout(resolveTimer, 60));
    assert.equal(readBackCount, 1);
    assert.equal(hasPendingReadBack(host, "dev-1"), false);
    cancelDelayedReadBack(host);
  });

  it("integrates applyCommand + refreshHADevices optimistic locks and facet writes on subpath HA URL", async () => {
    activeDom = mountTestWindow({ stubInterval: true });
    const { MenuMijiaWindowsApp } = await import("../src/ui/app.js");
    const haBaseURL = "https://192.0.2.10:8443/hass/";
    const haToken = "subpath-test-token";
    const fixture = loadFixture("ha_domain_cards.json") as {
      areas: unknown[];
      devices: unknown[];
      entities: unknown[];
      states: Array<{ entity_id: string; state: string; attributes: Record<string, unknown> }>;
    };
    const executedCalls: Array<{ domain: string; service: string; entity_id: string; data: Record<string, unknown> }> = [];
    let nextSnapshot = structuredClone(fixture);

    const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (command === "ha_execute") {
        executedCalls.push(
          args.command as { domain: string; service: string; entity_id: string; data: Record<string, unknown> },
        );
        return null;
      }
      if (command === "ha_snapshot") {
        return structuredClone(nextSnapshot);
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
          home: HomeAssistantSynthesizer.synthesize(fixture),
        },
      }),
    );

    const root = document.querySelector<HTMLElement>("#app")!;
    const app = new MenuMijiaWindowsApp(root);
    await refreshHADevices(app, true);
    assert.equal(app.deviceFacets["humidifier-full"]?.length, 7);

    // Toggle switch.living_led facet off via setMiotProperty -> switch.turn_off
    const ok = await applyCommand(app, {
      kind: "setMiotProperty",
      entityId: "switch.living_led",
      piid: 0,
      value: false,
    });
    assert.equal(ok, true);
    assert.deepEqual(executedCalls.at(-1), {
      domain: "switch",
      service: "turn_off",
      entity_id: "switch.living_led",
      data: {},
    });
    assert.equal(
      app.deviceFacets["humidifier-full"]?.find((f) => f.id === "switch.living_led")?.value,
      false,
    );
    assert.equal(isOptimisticallyLocked(app, "humidifier-full"), true);
    assert.equal(hasPendingReadBack(app, "humidifier-full"), true);

    // A stale HA poll (still reporting switch.living_led = "on") preserves the optimistic `false`
    await refreshHADevices(app, true);
    assert.equal(
      app.deviceFacets["humidifier-full"]?.find((f) => f.id === "switch.living_led")?.value,
      false,
      "stale HA poll within 3000ms lock window must not revert optimistic facet write",
    );

    // Once HA reports switch.living_led = "off", refreshHADevices confirms and clears the lock early
    nextSnapshot = structuredClone(fixture);
    const ledState = nextSnapshot.states.find((s) => s.entity_id === "switch.living_led")!;
    ledState.state = "off";
    await refreshHADevices(app, true);
    assert.equal(
      app.deviceFacets["humidifier-full"]?.find((f) => f.id === "switch.living_led")?.value,
      false,
    );
    assert.equal(isOptimisticallyLocked(app, "humidifier-full"), false);

    // Replacing or closing the owning Window cancels delayed read-backs so earlier hosts never
    // invoke `ha_snapshot` or overwrite `localStorage` on a subsequent window.
    let staleSnapshotCalls = 0;
    const crossWindowTicket = scheduleDelayedReadBack(app, "humidifier-full", 25, () => {
      staleSnapshotCalls += 1;
    });
    assert.equal(crossWindowTicket.isCancelled(), false);
    const previousDom = activeDom;
    activeDom = mountTestWindow({ stubInterval: true });
    await closeTestWindow(previousDom!);
    assert.equal(crossWindowTicket.isCancelled(), true);
    await new Promise((resolveTimer) => setTimeout(resolveTimer, 50));
    assert.equal(staleSnapshotCalls, 0);

    cancelDelayedReadBack(app);
  });

  it("dispatches humidifier target humidity, media_player play/pause/power/source, and confirmed valve position from mounted DOM", async () => {
    activeDom = mountTestWindow({ stubInterval: true });
    const { MenuMijiaWindowsApp } = await import("../src/ui/app.js");
    const haBaseURL = "http://192.168.1.8:8123";
    const haToken = "dom-parity-token";
    const snapshot = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "hum-dom", name: "加湿器", area_id: "living" },
        { id: "speaker-dom", name: "家庭音箱", area_id: "living" },
        { id: "valve-dom", name: "总水阀", area_id: "living" },
      ],
      entities: [
        { entity_id: "humidifier.dom", device_id: "hum-dom" },
        { entity_id: "media_player.dom", device_id: "speaker-dom" },
        { entity_id: "valve.dom", device_id: "valve-dom" },
      ],
      states: [
        {
          entity_id: "humidifier.dom",
          state: "on",
          attributes: {
            humidity: 50,
            current_humidity: 44,
            min_humidity: 30,
            max_humidity: 80,
            target_humidity_step: 5,
            supported_features: 1,
          },
        },
        {
          entity_id: "media_player.dom",
          state: "paused",
          attributes: {
            supported_features: 1 | 4 | 8 | 128 | 256 | 2048 | 16384,
            volume_level: 0.4,
            is_volume_muted: false,
            source_list: ["Spotify", "AirPlay"],
            source: "AirPlay",
          },
        },
        {
          entity_id: "valve.dom",
          state: "open",
          attributes: {
            device_class: "water",
            current_position: 35,
            supported_features: 7,
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
        allowAdvancedFacetWrites: false,
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
    const flushMicrotasks = () => new Promise((r) => setTimeout(r, 0));

    const openDrawerMoreSettings = (deviceId: string) => {
      const expandBtn =
        root.querySelector<HTMLElement>(`[data-expand-device="${deviceId}"]`) ??
        root.querySelector<HTMLElement>(`[data-body-device="${deviceId}"]`);
      assert.ok(expandBtn, `expected expandable trigger for ${deviceId}`);
      expandBtn.click();
      const moreToggle = root.querySelector<HTMLElement>(`[data-more-settings-toggle="${deviceId}"]`);
      assert.ok(moreToggle, `expected 更多设置 toggle for ${deviceId}`);
      moreToggle.click();
    };

    // 1. Humidifier target humidity slider dispatches humidifier.set_humidity directly
    openDrawerMoreSettings("hum-dom");
    const humSlider = root.querySelector<HTMLInputElement>(
      '[data-facet-number="hum-dom|humidifier.dom#target_humidity"]',
    );
    assert.ok(humSlider && !humSlider.disabled, "humidifier target humidity slider is enabled");
    humSlider.value = "65";
    humSlider.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushMicrotasks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "humidifier",
      service: "set_humidity",
      entity_id: "humidifier.dom",
      data: { humidity: 65 },
    });
    const humDev = app.devices.find((d) => d.id === "hum-dom")!;
    assert.ok(deviceStatusSummary(humDev).includes("65"), "optimistic humidifier status reflects 65%");

    // 2. Speaker play/pause, source select, and power off controls
    openDrawerMoreSettings("speaker-dom");
    const playBtn = root.querySelector<HTMLButtonElement>(
      '[data-facet-toggle="speaker-dom|media_player.dom#play_pause"]',
    );
    assert.ok(playBtn && !playBtn.disabled, "speaker play/pause toggle is enabled");
    playBtn.click();
    await flushMicrotasks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "media_play_pause",
      entity_id: "media_player.dom",
      data: {},
    });
    const speakerDev = app.devices.find((d) => d.id === "speaker-dom")!;
    assert.equal(speakerDev.kind.kind, "speaker");
    assert.equal(speakerDev.kind.state, "playing");
    assert.equal(
      app.deviceFacets["speaker-dom"]?.find((f) => f.id === "media_player.dom#play_pause")?.value,
      true,
    );

    const sourceSpotifyBtn = root.querySelector<HTMLButtonElement>(
      '[data-facet-select="speaker-dom|media_player.dom#source|0"]',
    );
    assert.ok(sourceSpotifyBtn && !sourceSpotifyBtn.disabled, "speaker source pill is enabled");
    sourceSpotifyBtn.click();
    await flushMicrotasks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "select_source",
      entity_id: "media_player.dom",
      data: { source: "Spotify" },
    });

    const powerBtn = root.querySelector<HTMLButtonElement>(
      '[data-facet-toggle="speaker-dom|media_player.dom#power"]',
    );
    assert.ok(powerBtn && !powerBtn.disabled, "speaker power toggle is enabled");
    powerBtn.click();
    await flushMicrotasks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "media_player",
      service: "turn_off",
      entity_id: "media_player.dom",
      data: {},
    });
    assert.equal(
      (app.devices.find((d) => d.id === "speaker-dom")!.kind as { state: string }).state,
      "idle",
    );

    // 3. Valve SET_POSITION slider stays enabled with allowAdvancedFacetWrites=false, arms high-risk
    //    confirmation on the first change, and dispatches valve.set_valve_position on confirmation.
    openDrawerMoreSettings("valve-dom");
    const countBeforeValve = executedCalls.length;
    const valveSlider1 = root.querySelector<HTMLInputElement>(
      '[data-facet-number="valve-dom|valve.dom#position"]',
    );
    assert.ok(valveSlider1 && !valveSlider1.disabled, "valve position slider is enabled via isConfirmedWrite");
    valveSlider1.value = "50";
    valveSlider1.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushMicrotasks();
    assert.equal(executedCalls.length, countBeforeValve, "first valve position write arms confirmation");
    assert.ok(app.pendingHighRisk !== null, "pendingHighRisk is armed");

    const valveSlider2 = root.querySelector<HTMLInputElement>(
      '[data-facet-number="valve-dom|valve.dom#position"]',
    );
    assert.ok(valveSlider2);
    valveSlider2.value = "50";
    valveSlider2.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushMicrotasks();
    assert.deepEqual(executedCalls.at(-1), {
      domain: "valve",
      service: "set_valve_position",
      entity_id: "valve.dom",
      data: { position: 50 },
    });
    assert.equal(
      (app.devices.find((d) => d.id === "valve-dom")!.kind as { statusText: string | null }).statusText,
      "开 50%",
    );

    cancelDelayedReadBack(app);
  });

  it("preserves composite sensor safety alerts, hardens URL identity, restores cached facets, and enforces §14 lock ownership", async () => {
    setLanguage("zh-Hans");
    // 1. Composite temperature + smoke binary_sensor keeps smoke alert statusText on sensor card
    const comboHome = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "kitchen", name: "厨房" }],
      devices: [{ id: "combo-smoke", name: "复合探头", area_id: "kitchen" }],
      entities: [
        { entity_id: "sensor.kitchen_temp", device_id: "combo-smoke" },
        { entity_id: "binary_sensor.kitchen_smoke", device_id: "combo-smoke" },
      ],
      states: [
        { entity_id: "sensor.kitchen_temp", state: "23.5", attributes: { device_class: "temperature" } },
        { entity_id: "binary_sensor.kitchen_smoke", state: "on", attributes: { device_class: "smoke" } },
      ],
    });
    const comboDev = byId(comboHome.devices).get("combo-smoke");
    assert.ok(comboDev && comboDev.kind.kind === "sensor");
    assert.equal(comboDev.kind.temperature, 23.5);
    assert.equal(comboDev.kind.statusText, "检测到烟雾");
    assert.equal(comboHome.deviceFacets?.["combo-smoke"], undefined);

    // 2. URL control-char rejection and exact lowercase /api normalization
    assert.equal(homeAssistantIdentity("https://home.example.com/hass/.\t./admin", "tok"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass\n/api", "tok"), null);
    assert.equal(homeAssistantIdentity("https://home.example.com/hass/api", "tok"), homeAssistantIdentity("https://home.example.com/hass", "tok"));
    assert.notEqual(homeAssistantIdentity("https://home.example.com/hass/API", "tok"), homeAssistantIdentity("https://home.example.com/hass", "tok"));

    // 3. Rapid reverse off -> on -> off keeps lock against stale `on`, and revision survives clear
    const mkPlug = (isOn: boolean): SmartDevice => ({
      id: "plug-1", name: "插座", roomId: "r", roomName: "客厅", model: "m", isOnline: true,
      kind: { kind: "plug", switchEntityId: "switch.p1", isOn, powerWatts: null, energyKwh: null, childLockEntityId: null, isChildLocked: false },
    });
    const lockHost: { sourceRevision: number; devices: SmartDevice[]; deviceFacets: Record<string, FacetControl[]> } = { sourceRevision: 1, devices: [mkPlug(true)], deviceFacets: {} };
    lockOptimistic(lockHost, "plug-1", 3000, { baselineDevice: mkPlug(false), nowMs: 100 });
    lockHost.devices = [mkPlug(false)];
    const rev2 = lockOptimistic(lockHost, "plug-1", 3000, { baselineDevice: mkPlug(true), nowMs: 200 });
    assert.equal(rev2, 2);
    const staleOnMerged = mergeSnapshotRespectingLocks(lockHost, [mkPlug(true)], 300);
    assert.equal((staleOnMerged[0]!.kind as { isOn: boolean }).isOn, false, "stale on must not revert off->on->off");
    assert.equal(isOptimisticallyLocked(lockHost, "plug-1", 300), true);
    const confirmedMerged = mergeSnapshotRespectingLocks(lockHost, [mkPlug(false)], 400);
    assert.equal((confirmedMerged[0]!.kind as { isOn: boolean }).isOn, false);
    assert.equal(isOptimisticallyLocked(lockHost, "plug-1", 400), false);
    assert.equal(optimisticLockRevision(lockHost, "plug-1"), 2, "revision persists after lock clears");

    // 4. Cached deviceFacets restore offline + cover pre-send lock + out-of-order write + read-back & button
    activeDom = mountTestWindow({ stubInterval: true });
    const { MenuMijiaWindowsApp } = await import("../src/ui/app.js");
    const haBaseURL = "http://192.168.1.9:8123";
    const haToken = "tok-" + "ab".repeat(8);
    const liveSnap = {
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [{ id: "hum-1", name: "加湿器", area_id: "living" }, { id: "cov-1", name: "窗帘", area_id: "living" }, { id: "btn-1", name: "门铃按钮", area_id: "living" }],
      entities: [{ entity_id: "humidifier.h1", device_id: "hum-1" }, { entity_id: "cover.c1", device_id: "cov-1" }, { entity_id: "button.b1", device_id: "btn-1" }],
      states: [
        { entity_id: "humidifier.h1", state: "off", attributes: { humidity: 45, min_humidity: 30, max_humidity: 80, supported_features: 1 } },
        { entity_id: "cover.c1", state: "closed", attributes: { current_position: 0, supported_features: 15 } },
        { entity_id: "button.b1", state: "unknown", attributes: {} },
      ],
    };
    let rejectSnapshot = true;
    const gateQueue: Array<() => void> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "ha_snapshot") {
            if (rejectSnapshot) throw new Error("offline");
            return structuredClone(liveSnap);
          }
          if (cmd === "ha_execute" && gateQueue.length > 0) {
            await new Promise<void>((res) => { const g = gateQueue.shift(); if (g) g(); res(); });
          }
          return null;
        },
      },
      configurable: true,
    });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "homeAssistant", hasCompletedOnboarding: true, haBaseURL, haToken,
      cachedHAHome: { identity: homeAssistantIdentity(haBaseURL, haToken), home: HomeAssistantSynthesizer.synthesize(liveSnap) },
    }));
    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    assert.ok((app.deviceFacets["hum-1"]?.length ?? 0) > 0, "cachedHAHome restores deviceFacets at startup");

    rejectSnapshot = false;
    await refreshHADevices(app, true);
    // Cover locks before send finishes, keeping origin=0 even if mid-flight snapshot reports 40
    let releaseCover: () => void = () => {};
    const coverHold = new Promise<void>((r) => { releaseCover = r; });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "ha_execute") { await coverHold; return null; }
          if (cmd === "ha_snapshot") return structuredClone(liveSnap);
          return null;
        },
      },
      configurable: true,
    });
    const coverSend = applyCommand(app, { kind: "setSelectOption", entityId: "cover.c1", option: "open" });
    assert.equal(isOptimisticallyLocked(app, "cov-1"), true, "cover locked before send completes");
    releaseCover();
    await coverSend;
    assert.equal((mergeSnapshotRespectingLocks(app, [byId(HomeAssistantSynthesizer.synthesize(liveSnap).devices).get("cov-1")!]).find((d) => d.id === "cov-1")!.kind as CoverSpec).motion, "opening");

    // Standalone button schedules delayed read-back; busy sync retries read-back and read-back replaces locked non-cover row
    await applyCommand(app, { kind: "setSwitch", entityId: "button.b1", isOn: true });
    assert.equal(hasPendingReadBack(app, "btn-1"), true, "standalone button.* schedules 800ms read-back");

    await applyCommand(app, { kind: "setSwitch", entityId: "humidifier.h1", isOn: true });
    assert.equal((app.devices.find((d) => d.id === "hum-1")!.kind as { isOn: boolean }).isOn, true);
    app.isSyncingCloud = true;
    scheduleDelayedReadBack(app, "hum-1", 15);
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(hasPendingReadBack(app, "hum-1"), true, "busy sync re-arms read-back instead of dropping it");
    app.isSyncingCloud = false;
    await new Promise((r) => setTimeout(r, 300));
    assert.equal((app.devices.find((d) => d.id === "hum-1")!.kind as { isOn: boolean }).isOn, false, "read-back replaces locked non-cover row with actual remote off");

    cancelDelayedReadBack(app);
  });
});
