import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
  type AppLanguage,
  catalogEntry,
  catalogKeys,
  languageFromTag,
  resolveLanguage,
  setLanguage,
  t,
} from "../src/core/i18n.js";
import {
  applyTemperatureUnit,
  displayStep,
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  resolveTemperatureUnit,
  stepCelsius,
  temperatureSymbol,
  toCelsius,
  toDisplayTemperature,
} from "../src/core/temperature.js";
import { classifyControlFailure, MIOT_DEVICE_OFFLINE_CODE } from "../src/core/controlFailure.js";
import { DeviceDeduplicator, RoomIdentityRegistry } from "../src/core/dualSourceProvider.js";
import { haBinarySensorStatusText, haLockStatusText } from "../src/core/haDomains.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import { MI_CLOUD_REGIONS, MiCloudClient, miCloudRegionLabel } from "../src/core/miCloudClient.js";
import { KIND_CHIP } from "../src/ui/listCut.js";
import { localizeEffect, localizeFanMode } from "../src/ui/panelPrefs.js";

function withLanguage<T>(language: AppLanguage, body: () => T): T {
  setLanguage(language);
  try {
    return body();
  } finally {
    setLanguage("zh-Hans");
  }
}

describe("text catalog (#52)", () => {
  it("every t() key used by the UI exists in the catalog", () => {
    const srcRoot = fileURLToPath(new URL("../src", import.meta.url));
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (entry.isFile() && entry.name.endsWith(".ts") && entry.name !== "i18n.ts") out.push(full);
      }
      return out;
    };
    const sources = walk(srcRoot).map((path) => readFileSync(path, "utf8"));
    const used = new Set<string>();
    for (const source of sources) {
      for (const match of source.matchAll(/\bt\(\s*"((?:[^"\\]|\\.)*)"/g)) {
        used.add(JSON.parse(`"${match[1]}"`) as string);
      }
    }
    assert.ok(used.size > 100, `expected many call sites, saw ${used.size}`);
    const missing = [...used].filter((key) => catalogEntry(key) === undefined);
    assert.deepEqual(missing, [], `catalog is missing: ${missing.join(" | ")}`);
  });

  it("every catalog entry carries a non-empty English translation", () => {
    for (const key of catalogKeys()) {
      const entry = catalogEntry(key);
      assert.ok(entry, `missing entry ${key}`);
      assert.equal(entry[0], key, `Simplified column must echo the key: ${key}`);
      assert.ok(entry[1].trim().length > 0, `empty English text for ${key}`);
    }
  });

  it("fills named placeholders and keeps unknown ones visible", () => {
    withLanguage("en", () => {
      assert.equal(t("已同步 {count} 台真实米家设备", { count: 3 }), "Synced 3 devices");
      assert.equal(
        t("米家账号 {user} · {count} 台设备", { user: "10****00", count: 5 }),
        "Mi account 10****00 · 5 devices",
      );
      // A placeholder the caller forgot stays visible instead of printing "undefined".
      assert.equal(t("全关·{room}"), "All off · {room}");
    });
    withLanguage("zh-Hans", () => {
      assert.equal(t("全关·{room}", { room: "客厅" }), "全关·客厅");
    });
  });

  it("returns the Chinese text for an unknown key instead of an empty label", () => {
    withLanguage("en", () => {
      assert.equal(t("这条文案不在表里"), "这条文案不在表里");
    });
  });

  it("falls back to Chinese for Chinese regions and to English for everything else", () => {
    assert.equal(languageFromTag("zh-CN"), "zh-Hans");
    assert.equal(languageFromTag("zh-Hant-HK"), "zh-Hant");
    assert.equal(languageFromTag("zh"), "zh-Hans");
    assert.equal(languageFromTag("en-GB"), "en");
    assert.equal(languageFromTag("fr-FR"), "en");
    assert.equal(resolveLanguage("en", ["zh-CN"]), "en");
    assert.equal(resolveLanguage("zh-Hans", ["en-US"]), "zh-Hans");
    assert.equal(resolveLanguage("system", ["en-US", "zh-Hans"]), "en");
    assert.equal(resolveLanguage("system", ["zh-Hans-CN"]), "zh-Hans");
    // No OS languages at all: the app's own default, not an empty string.
    assert.equal(resolveLanguage("system", []), "zh-Hans");
  });

  it("localizes MiCloud, Home Assistant, KIND_CHIP, and panel preference strings in en and zh-Hant (#45)", () => {
    withLanguage("en", () => {
      assert.throws(
        () => MiCloudClient.decodeResponse("", 401, ""),
        /The Mi Home session expired; scan again/,
      );
      assert.throws(
        () => MiCloudClient.decodeResponse("", 503, ""),
        /Mi Cloud service returned HTTP 503/,
      );
      assert.equal(miCloudRegionLabel("sg"), "Singapore / Global (sg)");
      assert.equal(MI_CLOUD_REGIONS[0]?.label, "China Mainland (cn)");
      assert.equal(KIND_CHIP.climate.title, "Climate");
      assert.equal(KIND_CHIP.climate.hint, "Also heaters, thermostats, and electric blankets");
      assert.equal(localizeEffect("Warmth"), "Cozy");
      assert.equal(localizeFanMode("quiet"), "Low");
      assert.equal(haLockStatusText({ entityId: "lock.front", state: "jammed", attributes: {} }), "Jammed");
      assert.equal(
        haBinarySensorStatusText("smoke", { entityId: "binary_sensor.smoke", state: "on", attributes: {} }),
        "Smoke detected",
      );
      const synth = HomeAssistantSynthesizer.synthesize({
        states: [{ entity_id: "light.unnamed", state: "on", attributes: {} }],
        devices: [{ id: "dev-1", name: "" }],
        entities: [{ entity_id: "light.unnamed", device_id: "dev-1" }],
        areas: [],
      });
      assert.equal(synth.devices[0]?.roomName, "Whole Home");
      assert.equal(synth.devices[0]?.name, "Smart Device");
    });

    withLanguage("zh-Hant", () => {
      assert.throws(
        () => MiCloudClient.decodeResponse("", 401, ""),
        /米家登入已過期，請重新掃碼/,
      );
      assert.equal(miCloudRegionLabel("de"), "歐洲 (de)");
      assert.equal(KIND_CHIP.sensor.title, "感測器");
      assert.equal(KIND_CHIP.sensor.hint, "也包括沒有開關的小家電");
      assert.equal(localizeEffect("Reading"), "閱讀");
      assert.equal(haLockStatusText({ entityId: "lock.front", state: "locked", attributes: {} }), "已上鎖");
      assert.equal(
        haBinarySensorStatusText("leak", { entityId: "binary_sensor.leak", state: "on", attributes: {} }),
        "偵測到漏水",
      );
      const synth = HomeAssistantSynthesizer.synthesize({
        states: [{ entity_id: "light.unnamed", state: "on", attributes: {} }],
        devices: [{ id: "dev-1", name: "" }],
        entities: [{ entity_id: "light.unnamed", device_id: "dev-1" }],
        areas: [],
      });
      assert.equal(synth.devices[0]?.roomName, "全屋");
      assert.equal(synth.devices[0]?.name, "智慧裝置");
    });
  });

  it("preserves unassigned-room inheritance in DeviceDeduplicator.merge and classifyControlFailure across en and zh-Hant (#45)", () => {
    let sharedRooms = new RoomIdentityRegistry();
    const lightKind = {
      kind: "light" as const,
      entityId: "light.lamp_100001",
      isOn: true,
      brightnessPercent: 50,
      colorTempKelvin: null,
      minKelvin: 2700,
      maxKelvin: 6500,
      availableEffects: [] as const,
      currentEffect: null,
    };

    withLanguage("zh-Hans", () => {
      const initial = DeviceDeduplicator.merge({
        homeAssistant: {
          home: {
            devices: [
              { id: "light.unassigned_999001", name: "Hall Lamp", roomId: "other", roomName: "全屋", model: "yeelink.light.lamp1", isOnline: true, kind: lightKind },
            ],
            rooms: [],
            environmentReadings: [],
            scenes: [],
          },
        },
        rooms: sharedRooms,
      });
      sharedRooms = initial.rooms;
      assert.equal(initial.home.devices[0]?.roomName, "全屋");
    });

    withLanguage("en", () => {
      const mergedEn = DeviceDeduplicator.merge({
        homeAssistant: {
          home: {
            devices: [
              { id: "100001", name: "Desk Lamp", roomId: "other", roomName: "Whole Home", model: "yeelink.light.lamp1", isOnline: true, kind: lightKind },
              { id: "light.unassigned_999001", name: "Hall Lamp", roomId: "other", roomName: "Whole Home", model: "yeelink.light.lamp1", isOnline: true, kind: lightKind },
            ],
            rooms: [],
            environmentReadings: [],
            scenes: [],
          },
        },
        xiaomiCloud: {
          home: {
            devices: [
              { id: "100001", name: "Desk Lamp", roomId: "room-lr", roomName: "Living Room", model: "yeelink.light.lamp1", isOnline: true, kind: lightKind },
            ],
            rooms: [{ id: "room-lr", name: "Living Room", deviceCount: 1 }],
            environmentReadings: [],
            scenes: [],
          },
        },
        rooms: sharedRooms,
      });
      const paired = mergedEn.home.devices.find((d) => d.name === "Desk Lamp");
      const unassigned = mergedEn.home.devices.find((d) => d.name === "Hall Lamp");
      assert.equal(paired?.roomName, "Living Room");
      assert.equal(unassigned?.roomName, "Whole Home");

      assert.equal(classifyControlFailure(new Error(t("请先扫码登录米家")))?.kind, "signedOut");
      assert.equal(classifyControlFailure(new Error(t("米家登录已过期，请重新扫码")))?.kind, "sessionExpired");
      assert.equal(classifyControlFailure(new Error(t("设备未响应或离线")))?.kind, "deviceOffline");
      assert.equal(
        classifyControlFailure(
          new Error(t("米家云指令失败 ({code})：{message}", { code: MIOT_DEVICE_OFFLINE_CODE, message: "err" })),
        )?.kind,
        "deviceOffline",
      );
      assert.equal(
        classifyControlFailure(
          new Error(t("米家云指令失败 ({code})：{message}", { code: -704042001, message: "err" })),
        )?.kind,
        "deviceRejected",
      );
    });

    withLanguage("zh-Hant", () => {
      const mergedHant = DeviceDeduplicator.merge({
        homeAssistant: {
          home: {
            devices: [
              { id: "light.unassigned_999001", name: "Hall Lamp", roomId: "other", roomName: "預設房間", model: "yeelink.light.lamp1", isOnline: true, kind: lightKind },
            ],
            rooms: [],
            environmentReadings: [],
            scenes: [],
          },
        },
        rooms: sharedRooms,
      });
      assert.equal(mergedHant.home.devices[0]?.roomName, "全屋");

      assert.equal(classifyControlFailure(new Error(t("请先扫码登录米家")))?.kind, "signedOut");
      assert.equal(classifyControlFailure(new Error(t("米家登录已过期，请重新扫码")))?.kind, "sessionExpired");
      assert.equal(classifyControlFailure(new Error(t("设备未响应或离线")))?.kind, "deviceOffline");
      assert.equal(
        classifyControlFailure(
          new Error(t("米家云指令失败 ({code})：{message}", { code: MIOT_DEVICE_OFFLINE_CODE, message: "err" })),
        )?.kind,
        "deviceOffline",
      );
      assert.equal(
        classifyControlFailure(
          new Error(t("米家云指令失败 ({code})：{message}", { code: -704042001, message: "err" })),
        )?.kind,
        "deviceRejected",
      );
    });
  });
});

describe("temperature units (#52)", () => {
  it("resolves Fahrenheit from the region subtag only", () => {
    assert.equal(resolveTemperatureUnit("en-US"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("en_US"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("zh-Hans-CN"), "celsius");
    assert.equal(resolveTemperatureUnit("zh-Hant-TW"), "celsius");
    assert.equal(resolveTemperatureUnit("de-DE"), "celsius");
    assert.equal(resolveTemperatureUnit("en"), "celsius");
    assert.equal(resolveTemperatureUnit("en-US@calendar=gregorian"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("en-US", "celsius"), "celsius");
    assert.equal(resolveTemperatureUnit("de-DE", "fahrenheit"), "fahrenheit");
  });

  it("formats display units while the stored value stays Celsius", () => {
    applyTemperatureUnit("en-US", "celsius");
    assert.equal(getTemperatureUnit(), "celsius");
    assert.equal(formatTemperature(24), "24°C");
    assert.equal(formatTemperature(25.5), "25.5°C");
    assert.equal(formatTemperatureValue(24.5), "24.5");
    assert.equal(formatTemperatureValue(26.5, undefined, 1), "26.5");
    assert.equal(temperatureSymbol(), "°C");

    applyTemperatureUnit("en-US", "system");
    assert.equal(getTemperatureUnit(), "fahrenheit");
    assert.equal(formatTemperature(0), "32°F");
    assert.equal(formatTemperature(24), "75°F");
    assert.equal(formatTemperature(22, undefined, 1), "71.6°F");
    assert.equal(temperatureSymbol(), "°F");
    assert.ok(Math.abs(toCelsius(toDisplayTemperature(21.5)) - 21.5) < 1e-9);
    applyTemperatureUnit("en-US", "celsius");
  });

  it("uses one whole °F per thermostat tap but keeps Celsius in the command", () => {
    applyTemperatureUnit("en-US", "celsius");
    assert.equal(stepCelsius(0.5), 0.5);
    assert.equal(displayStep(0.5), 0.5);

    applyTemperatureUnit("en-US", "fahrenheit");
    assert.ok(Math.abs(stepCelsius(0.5) - 5 / 9) < 1e-9);
    assert.equal(displayStep(0.5), 1);
    const next = 24 + stepCelsius(0.5);
    assert.ok(Math.abs(toDisplayTemperature(next) - toDisplayTemperature(24) - 1) < 1e-9);
    applyTemperatureUnit("zh-Hans-CN", "celsius");
  });
});
