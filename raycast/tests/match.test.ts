import assert from "node:assert/strict";
import { test } from "node:test";
import { describeDevice, matchDevice, matchScene } from "../src/match.ts";
import type { RaycastDevice, RaycastSnapshot } from "../src/snapshot.ts";

function device(overrides: Partial<RaycastDevice> & Pick<RaycastDevice, "id" | "name">): RaycastDevice {
  return {
    roomId: "study",
    roomName: "书房",
    roomSortOrder: 0,
    category: "light",
    categoryTitle: "灯",
    model: "yeelink.light.lamp",
    stateText: "已关",
    isOnline: true,
    isActiveOn: false,
    isPrimaryToggleable: true,
    isFavorite: false,
    pinyinInitials: "",
    pinyinFull: "",
    roomPinyinInitials: "",
    capabilities: {
      canTogglePower: true,
      brightnessWritable: true,
      colorWritable: false,
      supportsMoonlight: false,
      availableEffects: [],
      temperatureWritable: false,
      availableModes: [],
      fanSpeedWritable: false,
      availablePresetModes: [],
      positionWritable: false,
      canMoveCover: false,
      isHighRisk: false,
    },
    ...overrides,
  };
}

function snapshot(): RaycastSnapshot {
  return {
    schemaVersion: 1,
    updatedAt: "2026-11-06T08:00:00.000Z",
    bridgeToken: "t".repeat(40),
    connectionSummary: "Home Assistant · 米家云端直连",
    isStale: false,
    devices: [
      device({
        id: "dev_living_light",
        name: "客厅吸顶灯",
        roomId: "living",
        roomName: "客厅",
        stateText: "已开 · 80%",
        isActiveOn: true,
        isFavorite: true,
        pinyinInitials: "ktxdd",
        pinyinFull: "ketingxidingdeng",
        roomPinyinInitials: "kt",
      }),
      device({
        id: "dev_study_lamp",
        name: "书房台灯",
        pinyinInitials: "sftd",
        pinyinFull: "shufutaideng",
        roomPinyinInitials: "sf",
      }),
      device({
        id: "dev_study_ac",
        name: "书房空调",
        category: "climate",
        stateText: "制冷 · 25°C",
        isActiveOn: true,
        isPrimaryToggleable: true,
        pinyinInitials: "sfkt",
        roomPinyinInitials: "sf",
      }),
    ],
    quickActions: [
      {
        id: "lightsOff",
        name: "全屋关灯",
        subtitle: "",
        icon: "lightbulb.slash",
        isEnabled: true,
        affectedCount: 2,
        pinyinInitials: "qwgd",
      },
      {
        id: "allOff",
        name: "一键全关",
        subtitle: "",
        icon: "power",
        isEnabled: true,
        affectedCount: 3,
        pinyinInitials: "yjqg",
      },
    ],
    scenes: [
      {
        id: "scene_movie",
        name: "观影模式",
        entityId: "scene.movie",
        icon: "film.fill",
        visualCategory: "movie",
        pinyinInitials: "gyms",
        pinyinFull: "guanyingmoshi",
      },
    ],
    climate: [],
    environmentReadings: [],
  };
}

function deviceId(query: string): string {
  const match = matchDevice(snapshot(), query);
  assert.equal(match.ok, true, `expected "${query}" to resolve, got ${JSON.stringify(match)}`);
  return match.ok ? match.device.id : "";
}

test("matchDevice resolves names, rooms, ids and pinyin initials", () => {
  assert.equal(deviceId("客厅吸顶灯"), "dev_living_light");
  assert.equal(deviceId("dev_study_ac"), "dev_study_ac");
  assert.equal(deviceId("sftd"), "dev_study_lamp");
  assert.equal(deviceId("书房 台灯"), "dev_study_lamp");
  assert.equal(deviceId("KTXDD"), "dev_living_light");
  assert.equal(deviceId("shufutaideng"), "dev_study_lamp");
  assert.equal(deviceId("  书房台灯  "), "dev_study_lamp");
});

test("matchDevice reports ambiguity and unknown devices without picking one", () => {
  const unique = matchDevice(snapshot(), "台灯");
  assert.equal(unique.ok, true);
  if (unique.ok) {
    assert.equal(unique.device.id, "dev_study_lamp");
  }
  const ambiguous = matchDevice(snapshot(), "书房");
  assert.equal(ambiguous.ok, false);
  if (!ambiguous.ok) {
    assert.match(ambiguous.error, /matches 2 devices/);
    assert.match(ambiguous.error, /书房台灯/);
    assert.match(ambiguous.error, /书房空调/);
  }
  const many = matchDevice(snapshot(), "灯");
  assert.equal(many.ok, false);
  if (!many.ok) {
    assert.match(many.error, /matches 2 devices/);
    assert.match(many.error, /客厅吸顶灯/);
    assert.match(many.error, /书房台灯/);
  }
  const missing = matchDevice(snapshot(), "车库射灯");
  assert.equal(missing.ok, false);
  if (!missing.ok) {
    assert.match(missing.error, /No device matches/);
  }
  assert.equal(matchDevice(snapshot(), "   ").ok, false);
});

test("matchScene resolves scenes, quick actions and the quick: prefix", () => {
  const scene = matchScene(snapshot(), "观影模式");
  assert.equal(scene.ok, true);
  if (scene.ok) {
    assert.deepEqual([scene.kind, scene.id], ["scene", "scene_movie"]);
  }
  const byEntity = matchScene(snapshot(), "scene.movie");
  assert.equal(byEntity.ok, true);
  if (byEntity.ok) {
    assert.equal(byEntity.id, "scene_movie");
  }
  const quickByName = matchScene(snapshot(), "全屋关灯");
  assert.equal(quickByName.ok, true);
  if (quickByName.ok) {
    assert.deepEqual([quickByName.kind, quickByName.id], ["quick", "lightsOff"]);
  }
  const quickByPrefixedId = matchScene(snapshot(), "quick:allOff");
  assert.equal(quickByPrefixedId.ok, true);
  if (quickByPrefixedId.ok) {
    assert.deepEqual([quickByPrefixedId.kind, quickByPrefixedId.id], ["quick", "allOff"]);
  }
  const byPinyin = matchScene(snapshot(), "gyms");
  assert.equal(byPinyin.ok, true);
  if (byPinyin.ok) {
    assert.equal(byPinyin.name, "观影模式");
  }
});

test("matchScene refuses unknown and ambiguous names", () => {
  const missing = matchScene(snapshot(), "回家模式");
  assert.equal(missing.ok, false);
  if (!missing.ok) {
    assert.match(missing.error, /No scene or quick action matches/);
  }
  const ambiguous = matchScene(snapshot(), "关");
  assert.equal(ambiguous.ok, false);
  if (!ambiguous.ok) {
    assert.match(ambiguous.error, /matches 2 scenes/);
    assert.match(ambiguous.error, /全屋关灯/);
    assert.match(ambiguous.error, /一键全关/);
  }
  // quick: 前缀只看快捷动作，不会误配到名字相同的场景。
  assert.equal(matchScene(snapshot(), "quick:观影模式").ok, false);
});

test("describeDevice keeps offline devices explicit", () => {
  const online = snapshot().devices[0];
  assert.equal(describeDevice(online), "客厅吸顶灯 · 客厅 · 已开 · 80%");
  assert.equal(
    describeDevice({ ...online, isOnline: false }),
    "客厅吸顶灯 · 客厅 · Offline",
  );
});
