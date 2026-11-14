import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { hasDetailDrawer, type FacetControl, type SmartDevice } from "../src/core/models.js";
import {
  SENSOR_HISTORY_STORAGE_KEY,
  SensorHistoryStore,
  availableSensorMetrics,
  decodeLittleEndianFloat32Hex,
  decodeLittleEndianInt16Hex,
  extractSensorLiveMetrics,
  fetchHomeAssistantSensorHistory,
  fetchMiCloudSensorHistory,
  homeAssistantHistoryScope,
  parseHomeAssistantHistoryResponse,
  parseMiCloudHistoryPoints,
  resetSharedSensorHistoryStoreForTests,
  resolveHomeAssistantSensorEntityIds,
  resolveMiotSensorPropertyKeys,
  resolveSensorHistoryScope,
  sanitizeHumidity,
  sanitizeIlluminance,
  sanitizePm25,
  sanitizeTemperature,
  sharedSensorHistoryStore,
  startOfLocalDayMs,
  startOfLocalHourMs,
  type StorageLike,
} from "../src/core/sensorHistory.js";
import { applyTemperatureUnit } from "../src/core/temperature.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { demoDevices, demoSensorHistorySamples, seedDemoSensorHistory } from "../src/ui/demo.js";
import {
  buildSmoothCubicBezierPath,
  extractRawMiCloudDid,
  resetSensorHistoryUiState,
} from "../src/ui/sensorHistoryView.js";

class MapStorage implements StorageLike {
  public readonly data = new Map<string, string>();
  getItem(key: string): string | null {
    return this.data.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.data.set(key, value);
  }
  removeItem(key: string): void {
    this.data.delete(key);
  }
}

function makeSensor(
  id: string,
  overrides?: {
    name?: string;
    roomName?: string;
    isOnline?: boolean;
    temperature?: number | null;
    humidity?: number | null;
    battery?: number | null;
    statusText?: string;
  },
): SmartDevice {
  return {
    id,
    name: overrides?.name ?? "客厅温湿度计",
    roomId: "room_living",
    roomName: overrides?.roomName ?? "客厅",
    model: "miaomiaoce.sensor_ht.t2",
    isOnline: overrides?.isOnline ?? true,
    kind: {
      kind: "sensor",
      temperature: overrides?.temperature !== undefined ? overrides.temperature : 24.5,
      humidity: overrides?.humidity !== undefined ? overrides.humidity : 50,
      battery: overrides?.battery !== undefined ? overrides.battery : 92,
      ...(overrides?.statusText !== undefined ? { statusText: overrides.statusText } : {}),
    },
  };
}

describe("SensorHistoryStore core bucketing, pruning & scope isolation", () => {
  it("sanitizes metrics with Number.isFinite and domain bounds", () => {
    assert.equal(sanitizeTemperature(25.44), 25.4);
    assert.equal(sanitizeTemperature(Number.NaN), null);
    assert.equal(sanitizeTemperature(Number.POSITIVE_INFINITY), null);
    assert.equal(sanitizeTemperature(-80), null);
    assert.equal(sanitizeTemperature(150), null);

    assert.equal(sanitizeHumidity(52.6), 52.6);
    assert.equal(sanitizeHumidity(-1), null);
    assert.equal(sanitizeHumidity(105), null);

    assert.equal(sanitizePm25(35), 35);
    assert.equal(sanitizePm25(-5), null);
    assert.equal(sanitizePm25(1500), null);

    assert.equal(sanitizeIlluminance(320), 320);
    assert.equal(sanitizeIlluminance(-10), null);
    assert.equal(sanitizeIlluminance(500_000), null);
  });

  it("aggregates hourly & daily buckets, deduplicates single-refresh snapshots, and persists cleanly", () => {
    const storage = new MapStorage();
    const store = new SensorHistoryStore({ storage, connectionScope: "mi:cn:10001" });
    const baseNow = new Date(2026, 4, 10, 14, 15, 0, 0).getTime();

    assert.equal(
      store.record([makeSensor("s1", { temperature: 24.0, humidity: 48 })], {
        now: baseNow,
        snapshotKey: "rev-1",
      }),
      true,
    );
    assert.equal(
      store.record([makeSensor("s1", { temperature: 24.0, humidity: 48 })], {
        now: baseNow + 5_000,
        snapshotKey: "rev-1",
      }),
      false,
    );
    assert.equal(
      store.record([makeSensor("s1", { temperature: 26.0, humidity: 54 })], {
        now: baseNow + 20 * 60_000,
        snapshotKey: "rev-2",
      }),
      true,
    );

    const pts24 = store.points("s1", "24h", baseNow + 25 * 60_000);
    assert.equal(pts24.length, 24);
    const latestHour = pts24[23]!;
    assert.equal(latestHour.isObserved, true);
    assert.equal(latestHour.temperature, 25.0);
    assert.equal(latestHour.minTemperature, 24.0);
    assert.equal(latestHour.maxTemperature, 26.0);
    assert.equal(latestHour.humidity, 51);
    assert.equal(latestHour.minHumidity, 48);
    assert.equal(latestHour.maxHumidity, 54);

    const reloaded = new SensorHistoryStore({ storage, connectionScope: "mi:cn:10001" });
    const sum7d = reloaded.summary("s1", "7d", "temperature", baseNow + 25 * 60_000);
    assert.ok(sum7d);
    assert.equal(sum7d.average, 25.0);
    assert.equal(sum7d.min, 24.0);
    assert.equal(sum7d.max, 26.0);
    assert.equal(sum7d.latest, 25.0);
  });

  it("retains 48 hourly buckets & 14 daily buckets and prunes expired history across days", () => {
    const storage = new MapStorage();
    const store = new SensorHistoryStore({ storage, connectionScope: "mi:cn:10001" });
    const anchor = new Date(2026, 4, 20, 18, 0, 0, 0).getTime();

    const hourlySamples = Array.from({ length: 60 }, (_, idx) => ({
      timestamp: anchor - (59 - idx) * 3600_000,
      temperature: 20 + (idx % 6),
      humidity: 45 + (idx % 10),
    }));
    store.mergeCloudSamples("s1", "24h", hourlySamples, anchor);
    assert.equal(store.storedBucketCount("s1", "hourly"), 48);

    const dailySamples = Array.from({ length: 20 }, (_, idx) => ({
      timestamp: startOfLocalDayMs(anchor) - (19 - idx) * 86_400_000,
      temperature: 21 + (idx % 5),
      minTemperature: 18 + (idx % 5),
      maxTemperature: 25 + (idx % 5),
      humidity: 50,
    }));
    store.mergeCloudSamples("s1", "7d", dailySamples, anchor);
    assert.equal(store.storedBucketCount("s1", "daily"), 14);

    const pts24 = store.points("s1", "24h", anchor);
    assert.equal(pts24.length, 24);
    assert.equal(pts24.every((p) => p.isObserved), true);
    assert.equal(pts24[23]!.bucketStartMs, startOfLocalHourMs(anchor));

    const pts7d = store.points("s1", "7d", anchor);
    assert.equal(pts7d.length, 7);
    assert.equal(pts7d.every((p) => p.isObserved), true);
    assert.equal(pts7d[6]!.bucketStartMs, startOfLocalDayMs(anchor));
  });

  it("isolates history across demo / Home Assistant / Xiaomi Cloud scopes and migrates legacy unscoped keys", () => {
    const storage = new MapStorage();
    const nowMs = new Date(2026, 4, 12, 10, 0, 0, 0).getTime();
    storage.setItem(
      SENSOR_HISTORY_STORAGE_KEY,
      JSON.stringify({
        version: 1,
        hourlyByDevice: {
          legacy_sensor: [
            {
              bucketStartMs: startOfLocalHourMs(nowMs),
              metrics: { temperature: { sum: 22.5, count: 1, min: 22.5, max: 22.5 } },
            },
          ],
        },
        dailyByDevice: {},
        cloudSyncedDevices: ["legacy_sensor"],
      }),
    );

    const store = new SensorHistoryStore({ storage, connectionScope: "mi:cn:888" });
    assert.equal(store.points("legacy_sensor", "24h", nowMs)[23]!.temperature, 22.5);
    assert.equal(store.hasCloudHistory("legacy_sensor"), true);

    const haScope = homeAssistantHistoryScope("http://HomeAssistant.local:8123/api/");
    assert.equal(haScope, "ha:http://homeassistant.local:8123");
    store.setConnectionScope(haScope);
    assert.equal(store.points("legacy_sensor", "24h", nowMs)[23]!.temperature, null);

    assert.equal(
      resolveSensorHistoryScope({ connectionMode: "demo", haBaseURL: "", miSession: null }),
      "demo",
    );
    assert.equal(
      resolveSensorHistoryScope({
        connectionMode: "xiaomiCloud",
        haBaseURL: "",
        miSession: { userId: "999", region: "de" },
      }),
      "mi:de:999",
    );
  });

  it("extracts illuminance (lx) and PM2.5 from statusText and FacetControls", () => {
    const luxSensor = makeSensor("s_lux", {
      temperature: null,
      humidity: null,
      statusText: "320 lx",
    });
    const liveLux = extractSensorLiveMetrics(luxSensor);
    assert.equal(liveLux.illuminance, 320);
    assert.deepEqual(availableSensorMetrics(luxSensor), ["illuminance"]);

    const airFacets: FacetControl[] = [
      {
        id: "3.4",
        name: "pm2.5-density",
        title: "PM2.5",
        serviceName: "environment",
        kind: "reading",
        isWritable: false,
        writesByDefault: false,
        isHighValue: true,
        value: 18,
        unit: "μg/m³",
        scale: null,
        options: [],
        range: null,
        target: null,
      },
      {
        id: "2.3",
        name: "illumination",
        title: "光照度",
        serviceName: "illumination-sensor",
        kind: "reading",
        isWritable: false,
        writesByDefault: false,
        isHighValue: true,
        value: "460",
        unit: "lx",
        scale: null,
        options: [],
        range: null,
        target: null,
      },
    ];
    const combo = makeSensor("s_combo", { temperature: 25.2, humidity: 49 });
    const liveCombo = extractSensorLiveMetrics(combo, airFacets);
    assert.deepEqual(liveCombo, {
      temperature: 25.2,
      humidity: 49,
      pm25: 18,
      illuminance: 460,
    });
    assert.deepEqual(availableSensorMetrics(combo, airFacets), [
      "temperature",
      "humidity",
      "pm25",
      "illuminance",
    ]);
  });
});

describe("Xiaomi Cloud & Home Assistant remote history parsing and fetch deduplication", () => {
  beforeEach(() => {
    resetSharedSensorHistoryStoreForTests();
  });

  it("decodes MiCloud statistics & get_user_device_data payloads including LE Float32 and Int16 hex", () => {
    assert.equal(decodeLittleEndianFloat32Hex("cdccbc41"), 23.6);
    assert.equal(decodeLittleEndianInt16Hex("f700"), 24.7);
    assert.equal(decodeLittleEndianInt16Hex("1000"), null);

    const statPts = parseMiCloudHistoryPoints(
      {
        list: [
          { time: 1_715_000_000, value: "[23.2, 24.8]" },
          { time: 1_715_003_600, value: { avg: 25.1, min: 24.4, max: 26.0 } },
        ],
      },
      "2.1",
      "temperature",
    );
    assert.equal(statPts.length, 2);
    assert.equal(statPts[0]!.value, 24.0);
    assert.equal(statPts[0]!.minValue, 23.2);
    assert.equal(statPts[0]!.maxValue, 24.8);
    assert.equal(statPts[1]!.value, 25.1);
    assert.equal(statPts[1]!.minValue, 24.4);
    assert.equal(statPts[1]!.maxValue, 26.0);

    const blePts = parseMiCloudHistoryPoints(
      [{ time: 1_715_000_000, value: '"cdccbc41"' }],
      "4c01",
      "temperature",
    );
    assert.equal(blePts.length, 1);
    assert.equal(blePts[0]!.value, 23.6);
  });

  it("falls back from Xiaomi v2/user/statistics to user/get_user_device_data when statistics is empty", async () => {
    const session: MiSession = {
      userId: "12345",
      serviceToken: "svc-token",
      ssecurity: Buffer.alloc(16, 7).toString("base64"),
      passToken: "",
      cUserId: "c12345",
      region: "cn",
    };
    const requestedUrls: string[] = [];
    const nowMs = 1_715_010_000_000;
    const keys = resolveMiotSensorPropertyKeys({
      type: "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:miaomiaoce-t2:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:miaomiaoce-t2:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:miaomiaoce-t2:1", format: "float", access: ["read", "notify"] },
            { iid: 2, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:miaomiaoce-t2:1", format: "uint8", access: ["read", "notify"] },
          ],
          actions: [],
        },
      ],
    });
    assert.deepEqual(keys, { temperature: "2.1", humidity: "2.2" });

    const transport = async (req: { url: string; body?: string }) => {
      requestedUrls.push(req.url);
      if (req.url.includes("/v2/user/statistics")) {
        return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: [] }) };
      }
      if (req.url.includes("/user/get_user_device_data")) {
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            code: 0,
            result: [
              { time: 1_715_002_800, value: "[23.4]" },
              { time: 1_715_006_400, value: "[24.9]" },
            ],
          }),
        };
      }
      return { status: 500, headers: {}, body: "{}" };
    };
    const fallbackSamples = await fetchMiCloudSensorHistory({
      session,
      transport,
      did: "blt.3.sensor1",
      window: "24h",
      metrics: ["temperature"],
      propertyKeys: keys,
      now: nowMs,
    });
    assert.equal(fallbackSamples.length, 2);
    assert.equal(fallbackSamples[0]!.temperature, 23.4);
    assert.equal(fallbackSamples[1]!.temperature, 24.9);
    assert.ok(requestedUrls.some((u) => u.includes("/v2/user/statistics")));
    assert.ok(requestedUrls.some((u) => u.includes("/user/get_user_device_data")));
  });

  it("parses Home Assistant /api/history/period minimal_response and converts °F history to Celsius", async () => {
    const t1 = "2026-05-10T08:00:00.000Z";
    const t2 = "2026-05-10T09:00:00.000Z";
    const payload = [
      [
        {
          entity_id: "sensor.living_temperature",
          state: "77.0",
          last_changed: t1,
          attributes: { device_class: "temperature", unit_of_measurement: "°F" },
        },
        {
          s: "78.8",
          lu: Math.floor(Date.parse(t2) / 1000),
        },
        {
          s: "unavailable",
          lu: Math.floor(Date.parse(t2) / 1000) + 60,
        },
      ],
      [
        {
          entity_id: "sensor.living_humidity",
          state: "53",
          last_changed: t1,
          attributes: { device_class: "humidity", unit_of_measurement: "%" },
        },
      ],
    ];

    const parsed = parseHomeAssistantHistoryResponse(payload);
    assert.equal(parsed.length, 3);
    assert.equal(parsed[0]!.temperature, 25.0);
    assert.equal(parsed[2]!.temperature, 26.0);

    let callCount = 0;
    const samples = await fetchHomeAssistantSensorHistory({
      baseURL: "http://ha.local:8123/",
      token: "ha-secret",
      entityIds: resolveHomeAssistantSensorEntityIds(
        makeSensor("sensor.living_temperature", { temperature: 25, humidity: 53 }),
      ),
      window: "24h",
      now: Date.parse(t2),
      transport: async (req) => {
        callCount += 1;
        assert.ok(req.url.startsWith("http://ha.local:8123/api/history/period/"));
        assert.ok(req.url.includes("sensor.living_temperature"));
        assert.ok(req.url.includes("sensor.living_humidity"));
        assert.equal(req.headers?.Authorization, "Bearer ha-secret");
        return { status: 200, headers: {}, body: JSON.stringify(payload) };
      },
    });
    assert.equal(callCount, 1);
    assert.equal(samples.length, 3);
  });

  it("deduplicates concurrent in-flight fetches and silently retains local samples on failure", async () => {
    const storage = new MapStorage();
    const store = new SensorHistoryStore({ storage, connectionScope: "ha:http://ha.local:8123" });
    const nowMs = new Date(2026, 4, 15, 12, 0, 0, 0).getTime();
    store.record([makeSensor("sensor.room", { temperature: 24.2, humidity: 50 })], { now: nowMs });

    let invocations = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });

    const fetcher = async () => {
      invocations += 1;
      await gate;
      return [{ timestamp: nowMs - 3600_000, temperature: 23.1, humidity: 47 }];
    };

    const p1 = store.fetchAndMerge("sensor.room", "24h", fetcher, { now: nowMs });
    const p2 = store.fetchAndMerge("sensor.room", "24h", fetcher, { now: nowMs });
    assert.equal(store.isLoading("sensor.room", "24h"), true);
    release();
    const [r1, r2] = await Promise.all([p1, p2]);
    assert.equal(invocations, 1);
    assert.equal(r1.length, 1);
    assert.equal(r2.length, 1);
    assert.equal(store.isLoading("sensor.room", "24h"), false);
    assert.equal(store.shouldFetchCloud("sensor.room", "24h", nowMs + 60_000), false);

    const failed = await store.fetchAndMerge(
      "sensor.room",
      "7d",
      async () => {
        throw new Error("network unreachable");
      },
      { now: nowMs, force: true },
    );
    assert.deepEqual(failed, []);
    assert.equal(store.points("sensor.room", "7d", nowMs)[6]!.temperature, 24.2);
  });
});

describe("Sensor card inline SVG trend chart UI & interactions", () => {
  let dom: Window;
  let restoreCssEscape: () => void;

  beforeEach(() => {
    resetSharedSensorHistoryStoreForTests();
    resetSensorHistoryUiState();
    dom = mountTestWindow({ stubInterval: true });
    restoreCssEscape = installCssEscape();
    setLanguage("zh-Hans");
    applyTemperatureUnit("zh-CN", "celsius");
  });

  afterEach(async () => {
    setLanguage("zh-Hans");
    applyTemperatureUnit("zh-CN", "celsius");
    resetSensorHistoryUiState();
    resetSharedSensorHistoryStoreForTests();
    restoreCssEscape();
    await closeTestWindow(dom);
  });

  it("keeps hasDetailDrawer(sensor) === false while Demo mode clicks expand 24h & 7d smooth cubic Bézier SVG curves", () => {
    const devices = demoDevices();
    const envSensor = devices.find((d) => d.id === "sensor.living_env")!;
    assert.ok(envSensor);
    assert.equal(hasDetailDrawer(envSensor), false);

    const demo24 = demoSensorHistorySamples("sensor.living_env", { temperature: 25.5, humidity: 52 }, "24h", 1_715_000_000_000);
    const demo24Repeat = demoSensorHistorySamples("sensor.living_env", { temperature: 25.5, humidity: 52 }, "24h", 1_715_000_000_000);
    assert.deepEqual(demo24, demo24Repeat);
    assert.equal(demo24.length, 24);
    assert.equal(demo24[23]!.temperature, 25.5);

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);

    const cardCollapsed = root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"]');
    assert.ok(cardCollapsed);
    assertMissing(cardCollapsed.querySelector("[data-expand-device]"));
    assertMissing(root.querySelector("[data-sensor-history-drawer]"));

    cardCollapsed.click();
    assert.equal(app.expandedDeviceId, "sensor.living_env");

    const drawer = root.querySelector<HTMLElement>('[data-sensor-history-drawer="sensor.living_env"]');
    assert.ok(drawer);
    const expandedCard = root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"]')!;
    assert.match(expandedCard.getAttribute("style") ?? "", /span 6/);

    const linePath = drawer.querySelector<SVGPathElement>("[data-sensor-line-path]");
    const areaPath = drawer.querySelector<SVGPathElement>("[data-sensor-area-path]");
    assert.ok(linePath);
    assert.ok(areaPath);
    assert.match(linePath.getAttribute("d") ?? "", /^M [\d.]+ [\d.]+ C /);
    assert.match(areaPath.getAttribute("d") ?? "", /Z$/);
    assert.equal(drawer.querySelectorAll("[data-sensor-slot]").length, 24);
    assert.match(drawer.textContent ?? "", /最高/);
    assert.match(drawer.textContent ?? "", /最低/);
    assert.match(drawer.textContent ?? "", /舒适/);

    drawer.click();
    assert.equal(app.expandedDeviceId, "sensor.living_env");

    const btn7d = drawer.querySelector<HTMLButtonElement>('[data-sensor-window="sensor.living_env:7d"]');
    assert.ok(btn7d);
    btn7d.click();
    assert.equal(app.expandedDeviceId, "sensor.living_env");

    const drawer7d = root.querySelector<HTMLElement>('[data-sensor-history-drawer="sensor.living_env"]')!;
    assert.equal(drawer7d.querySelectorAll("[data-sensor-slot]").length, 7);
    assert.ok(drawer7d.querySelector("[data-sensor-band-path]"));
    assert.match(drawer7d.textContent ?? "", /今天/);

    const btnHum = drawer7d.querySelector<HTMLButtonElement>('[data-sensor-metric="sensor.living_env:humidity"]');
    assert.ok(btnHum);
    btnHum.click();
    const plotHum = root.querySelector<SVGElement>('[data-sensor-plot="sensor.living_env"]')!;
    assert.equal(plotHum.getAttribute("data-sensor-metric-active"), "humidity");
    assert.match(root.querySelector("[data-sensor-readout-value]")?.textContent ?? "", /%/);

    root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"] .cc-sensor-wide')!.click();
    assert.equal(app.expandedDeviceId, null);
    assertMissing(root.querySelector("[data-sensor-history-drawer]"));
  });

  it("supports hover slot scrubbing, °C / °F conversion, tr3 localization, and illuminance / PM2.5 sensors", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );
    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);

    const luxDev = makeSensor("sensor.study_lux", {
      name: "书房光照传感器",
      roomName: "书房",
      temperature: null,
      humidity: null,
      statusText: "320 lx",
    });
    const lockDev = makeSensor("sensor.front_lock", {
      name: "入户门锁",
      roomName: "玄关",
      temperature: null,
      humidity: null,
      statusText: "已上锁",
    });
    app.devices = [...app.devices, luxDev, lockDev];
    seedDemoSensorHistory(app.devices, { store: sharedSensorHistoryStore(), force: true });
    app.render();

    assertMissing(root.querySelector('[data-sensor-card="sensor.front_lock"]'));

    const luxCard = root.querySelector<HTMLElement>('[data-sensor-card="sensor.study_lux"]');
    assert.ok(luxCard);
    luxCard.click();
    assert.equal(app.expandedDeviceId, "sensor.study_lux");
    assert.match(root.querySelector("[data-sensor-readout-value]")?.textContent ?? "", /320 lx/);

    root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"]')!.click();
    const drawer = root.querySelector<HTMLElement>('[data-sensor-history-drawer="sensor.living_env"]')!;
    const scrubber = drawer.querySelector<SVGElement>("[data-sensor-scrubber]")!;
    const hoverDot = drawer.querySelector<SVGElement>("[data-sensor-hover-dot]")!;
    assert.equal(scrubber.hasAttribute("hidden"), true);

    const slot4 = drawer.querySelector<Element>('[data-sensor-slot="4"]')!;
    const expectedSlotVal = slot4.getAttribute("data-slot-value")!;
    const expectedSlotTime = slot4.getAttribute("data-slot-time")!;
    slot4.dispatchEvent(new dom.MouseEvent("mouseover", { bubbles: true }) as unknown as Event);
    assert.equal(drawer.querySelector("[data-sensor-readout-value]")?.textContent, expectedSlotVal);
    assert.equal(drawer.querySelector("[data-sensor-readout-time]")?.textContent, expectedSlotTime);
    assert.equal(scrubber.hasAttribute("hidden"), false);
    assert.equal(hoverDot.hasAttribute("hidden"), false);

    const plot = drawer.querySelector<SVGElement>("[data-sensor-plot]")!;
    plot.dispatchEvent(new dom.MouseEvent("mouseleave", { bubbles: false }) as unknown as Event);
    assert.equal(drawer.querySelector("[data-sensor-readout-value]")?.textContent, "25.5°C");
    assert.equal(scrubber.hasAttribute("hidden"), true);

    applyTemperatureUnit("zh-CN", "fahrenheit");
    app.render();
    const drawerF = root.querySelector<HTMLElement>('[data-sensor-history-drawer="sensor.living_env"]')!;
    assert.equal(drawerF.querySelector("[data-sensor-readout-value]")?.textContent, "77.9°F");
    assert.match(drawerF.querySelector("[data-sensor-y-max]")?.textContent ?? "", /°F$/);
    assert.match(drawerF.querySelector("[data-sensor-readout-sub]")?.textContent ?? "", /°F/);

    setLanguage("en");
    app.render();
    assert.match(root.querySelector('[data-sensor-history-drawer="sensor.living_env"]')?.textContent ?? "", /Current/);
    assert.match(root.querySelector('[data-sensor-history-drawer="sensor.living_env"]')?.textContent ?? "", /Temp/);

    setLanguage("zh-Hant");
    app.render();
    assert.match(root.querySelector('[data-sensor-history-drawer="sensor.living_env"]')?.textContent ?? "", /24小時/);
    assert.match(root.querySelector('[data-sensor-history-drawer="sensor.living_env"]')?.textContent ?? "", /溫度/);
  });

  it("blocks expansion during layout editing, hides misleading charts when valuesAreStale, and merges async HA history", async () => {
    const tNow = Date.now();
    const haHistoryPayload = [
      [
        {
          entity_id: "sensor.ha_env_temperature",
          state: "22.4",
          last_changed: new Date(tNow - 3 * 3600_000).toISOString(),
          attributes: { device_class: "temperature", unit_of_measurement: "°C" },
        },
        {
          entity_id: "sensor.ha_env_temperature",
          state: "24.8",
          last_changed: new Date(tNow - 300_000).toISOString(),
          attributes: { device_class: "temperature", unit_of_measurement: "°C" },
        },
      ],
    ];

    let historyCalls = 0;
    window.__TAURI_INTERNALS__ = {
      invoke: (async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "native_http" && String(args?.url ?? "").includes("/api/history/period/")) {
            historyCalls += 1;
            return { status: 200, headers: {}, body: JSON.stringify(haHistoryPayload) };
          }
          if (cmd === "ha_snapshot") {
            return {
              states: [
                {
                  entity_id: "sensor.ha_env_temperature",
                  state: "24.8",
                  attributes: { friendly_name: "客厅温度", device_class: "temperature", unit_of_measurement: "°C" },
                },
              ],
              entities: [],
              devices: [],
              areas: [],
            };
          }
          return null;
      }) as <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
    };

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        haBaseURL: "https://ha.example.com",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.settings.haToken = "ha-live-token";
    app.devices = [
      makeSensor("sensor.ha_env_temperature", {
        name: "客厅温度计",
        temperature: 24.8,
        humidity: null,
      }),
    ];
    app.haConnectionError = null;
    assert.equal(app.valuesAreStale, false);
    app.render();

    app.isEditingLayout = true;
    app.render();
    root.querySelector<HTMLElement>('[data-sensor-card="sensor.ha_env_temperature"]')?.click();
    assert.equal(app.expandedDeviceId, null);

    app.isEditingLayout = false;
    app.render();
    root.querySelector<HTMLElement>('[data-sensor-card="sensor.ha_env_temperature"]')!.click();
    assert.equal(app.expandedDeviceId, "sensor.ha_env_temperature");
    await setImmediate();
    await setImmediate();
    assert.equal(historyCalls, 1);
    const linePath = root.querySelector<SVGPathElement>("[data-sensor-line-path]");
    assert.ok(linePath);
    assert.match(linePath.getAttribute("d") ?? "", /^M [\d.]+ [\d.]+ C /);

    app.haConnectionError = "Connection timed out";
    assert.equal(app.valuesAreStale, true);
    app.render();
    assertMissing(root.querySelector("[data-sensor-history-drawer]"));
    assert.match(root.querySelector(".cc-sensor")?.textContent ?? "", /可能过期/);

    assert.equal(buildSmoothCubicBezierPath([]), "");
    assert.equal(buildSmoothCubicBezierPath([{ x: 10, y: 20 }]), "M 10 20");
  });

  it("fetches Xiaomi Cloud v2/user/statistics on sensor expansion and resets UI state on scope switch (§13)", async () => {
    const tNowSec = Math.floor(Date.now() / 1000);
    let miStatCalls = 0;
    window.__TAURI_INTERNALS__ = {
      invoke: (async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "native_http") {
            const url = String(args?.url ?? "");
            if (url.includes("/v2/user/statistics")) {
              miStatCalls += 1;
              return {
                status: 200,
                headers: {},
                body: JSON.stringify({
                  code: 0,
                  result: [
                    { time: tNowSec - 7200, value: "[23.0]" },
                    { time: tNowSec - 3600, value: "[24.1]" },
                    { time: tNowSec - 60, value: "[25.3]" },
                  ],
                }),
              };
            }
            return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: [] }) };
          }
          return null;
      }) as <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
    };

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);

    root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"]')!.click();
    root.querySelector<HTMLButtonElement>('[data-sensor-window="sensor.living_env:7d"]')!.click();
    assert.equal(
      root.querySelector('[data-sensor-plot="sensor.living_env"]')?.getAttribute("data-sensor-window-active"),
      "7d",
    );

    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = {
      userId: "mi-user-77",
      cUserId: "c77",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "mi-svc-token",
      passToken: "",
      region: "cn",
    };
    app.devices = [
      makeSensor("mi_sensor_1", {
        name: "主卧温湿度计",
        roomName: "主卧",
        temperature: 25.3,
        humidity: 51,
      }),
    ];
    app.expandedDeviceId = null;
    app.markCloudValuesFresh();
    app.render();

    root.querySelector<HTMLElement>('[data-sensor-card="mi_sensor_1"]')!.click();
    await setImmediate();
    await setImmediate();
    assert.ok(miStatCalls >= 1);
    const plot = root.querySelector<SVGElement>('[data-sensor-plot="mi_sensor_1"]');
    assert.ok(plot);
    assert.equal(plot.getAttribute("data-sensor-window-active"), "24h");
    assert.ok(root.querySelector("[data-sensor-line-path]"));
    assert.match(root.querySelector("[data-sensor-source-badge]")?.textContent ?? "", /云端\+本机/);
  });

  it("does not stamp cold disk cache or expired-session snapshots as live current-hour observations", () => {
    const coldSensor = makeSensor("mi_cold_1", {
      name: "次卧温湿度计",
      roomName: "次卧",
      temperature: 21.6,
      humidity: 44,
    });
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
        cachedXiaomiDevices: [coldSensor],
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    const store = sharedSensorHistoryStore();
    assert.equal(store.storedBucketCount("mi_cold_1", "hourly"), 0);

    app.miSessionExpired = true;
    app.devices = [makeSensor("mi_cold_1", { temperature: 22.0, humidity: 45 })];
    app.render();
    assert.equal(store.storedBucketCount("mi_cold_1", "hourly"), 0);

    app.miSessionExpired = false;
    app.timerSnapshot = { identity: "mi:cn:1", sourceRevision: app.sourceRevision };
    app.devices = [makeSensor("mi_cold_1", { temperature: 22.8, humidity: 47 })];
    app.render();
    assert.equal(store.storedBucketCount("mi_cold_1", "hourly"), 1);
  });

  it("records silent cross-hour app.devices polling updates without app.render()", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.settings.miSession = {
      userId: "mi-silent-1",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "svc-1",
      passToken: "",
      region: "cn",
    };
    app.layout.collapsed = [`${app.pageKey}:room_living`, "room_living"];
    app.render();

    const store = sharedSensorHistoryStore();
    const realDateNow = Date.now;
    let fakeNowMs = new Date(2026, 10, 14, 9, 15, 0, 0).getTime();
    Date.now = () => fakeNowMs;
    try {
      app.devices = [makeSensor("mi_silent_ht", { temperature: 24.5, humidity: 50 })];
      app.deviceFacets = {
        mi_silent_ht: [
          {
            id: "2.3",
            name: "illumination",
            title: "光照度",
            serviceName: "illumination-sensor",
            kind: "reading",
            isWritable: false,
            writesByDefault: false,
            isHighValue: true,
            value: 310,
            unit: "lx",
            scale: null,
            options: [],
            range: null,
            target: null,
          },
        ],
      };
      app.timerSnapshot = { identity: "mi:cn:mi-silent-1", sourceRevision: app.sourceRevision };
      await Promise.resolve();
      assert.equal(store.storedBucketCount("mi_silent_ht", "hourly"), 1);

      fakeNowMs = new Date(2026, 10, 14, 10, 15, 0, 0).getTime();
      app.devices = [makeSensor("mi_silent_ht", { temperature: 24.5, humidity: 50 })];
      await Promise.resolve();
      assert.equal(store.storedBucketCount("mi_silent_ht", "hourly"), 2);

      fakeNowMs = new Date(2026, 10, 14, 11, 15, 0, 0).getTime();
      app.devices = [makeSensor("mi_silent_ht", { temperature: 24.5, humidity: 50 })];
      await Promise.resolve();
      assert.equal(store.storedBucketCount("mi_silent_ht", "hourly"), 3);

      const pts = store.points("mi_silent_ht", "24h", fakeNowMs);
      const populated = pts.filter((p) => p.temperature !== null);
      assert.equal(populated.length, 3);
      assert.equal(populated[0]?.illuminance, 310);
    } finally {
      Date.now = realDateNow;
    }
  });

  it("strips multi-account <accountId>/<did> and mi: prefixes when fetching Xiaomi Cloud statistics", async () => {
    assert.equal(extractRawMiCloudDid("acct_2/blt.3.ht1"), "blt.3.ht1");
    assert.equal(extractRawMiCloudDid("mi:sg:2002/mi:998877"), "998877");
    assert.equal(extractRawMiCloudDid("mi:998877"), "998877");
    assert.equal(extractRawMiCloudDid("998877"), "998877");

    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const requestedDids: string[] = [];
    const tNowSec = Math.floor(Date.now() / 1000);

    window.__TAURI_INTERNALS__ = {
      invoke: (async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "native_http") {
            const url = String(args?.url ?? "");
            if (url.includes("/v2/user/statistics")) {
              const fields = new URLSearchParams(String(args?.body ?? ""));
              const nonce = fields.get("_nonce")!;
              const encrypted = fields.get("data")!;
              const payload = JSON.parse(
                MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce)),
              ) as { did?: string };
              if (payload.did) requestedDids.push(payload.did);
              return {
                status: 200,
                headers: {},
                body: JSON.stringify({
                  code: 0,
                  result: [
                    { time: tNowSec - 3600, value: "[23.5]" },
                    { time: tNowSec - 60, value: "[24.2]" },
                  ],
                }),
              };
            }
            return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: [] }) };
          }
          return null;
      }) as <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
    };

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.settings.miSession = {
      userId: "2002",
      cUserId: "c2002",
      ssecurity: security,
      serviceToken: "svc-multi",
      passToken: "",
      region: "cn",
    };
    app.devices = [
      {
        ...makeSensor("acct_2/mi:998877", {
          name: "副账号书房温湿度计",
          roomName: "书房",
          temperature: 24.2,
          humidity: 48,
        }),
        accountId: "mi:cn:3003",
      },
    ];
    app.miAccountsOverride = [
      makeMiAccount(app.settings.miSession!),
      makeMiAccount({
        userId: "3003",
        cUserId: "c3003",
        ssecurity: security,
        serviceToken: "svc-secondary-3003",
        passToken: "",
        region: "cn",
      }),
    ];
    app.timerSnapshot = { identity: "mi:cn:2002", sourceRevision: app.sourceRevision };
    app.markCloudValuesFresh();
    app.render();

    root.querySelector<HTMLElement>('[data-sensor-card="acct_2/mi:998877"]')!.click();
    await setImmediate();
    await setImmediate();

    assert.ok(requestedDids.length >= 1);
    assert.ok(requestedDids.every((did) => did === "998877"));
    assert.ok(root.querySelector('[data-sensor-plot="acct_2/mi:998877"]'));
  });

  it("discovers all registered HA sensor entities via ha_snapshot even when illuminance is in deviceFacets", async () => {
    resetSharedSensorHistoryStoreForTests();
    const requestedUrls: string[] = [];
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        hasCompletedOnboarding: true,
        haBaseURL: "http://192.168.1.50:8123",
        haToken: "ha-tok-env",
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );
    window.__TAURI_INTERNALS__ = {
      invoke: (async (cmd: string, args?: Record<string, unknown>) => {
        if (cmd === "native_http") {
          requestedUrls.push(String(args?.url ?? ""));
          return { status: 200, headers: {}, body: "[]" };
        }
        return null;
      }) as <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
    };
    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.haInvokeOverride = (async (cmd: string) => {
      if (cmd === "ha_snapshot") {
        return {
          entities: [
            { entity_id: "sensor.living_temperature", device_id: "dev_living_env" },
            { entity_id: "sensor.living_humidity", device_id: "dev_living_env" },
            { entity_id: "sensor.living_illuminance", device_id: "dev_living_env" },
          ],
        };
      }
      return {};
    }) as typeof app.haInvokeOverride;
    app.devices = [
      makeSensor("ha:dev_living_env", {
        name: "客厅环境传感器",
        roomName: "客厅",
        temperature: 23.5,
        humidity: 52,
      }),
    ];
    app.deviceFacets = {
      "ha:dev_living_env": [
        {
          id: "sensor.living_illuminance",
          name: "illumination",
          title: "光照度",
          serviceName: "sensor",
          kind: "reading",
          isWritable: false,
          writesByDefault: false,
          isHighValue: true,
          value: "320",
          unit: "lx",
          scale: null,
          options: [],
          range: null,
          target: { kind: "property", entityId: "sensor.living_illuminance", piid: 1 },
        },
      ],
    };
    app.timerSnapshot = { identity: "ha:http://192.168.1.50:8123", sourceRevision: app.sourceRevision };
    app.markCloudValuesFresh();
    app.render();

    root.querySelector<HTMLElement>('[data-sensor-card="ha:dev_living_env"]')!.click();
    await setImmediate();
    await setImmediate();

    assert.equal(requestedUrls.length, 1);
    const decodedUrl = decodeURIComponent(requestedUrls[0]!);
    assert.match(decodedUrl, /sensor\.living_temperature/);
    assert.match(decodedUrl, /sensor\.living_humidity/);
    assert.match(decodedUrl, /sensor\.living_illuminance/);

    const pollutantHistory = parseHomeAssistantHistoryResponse([
      [
        {
          entity_id: "sensor.living_pm10",
          state: "88",
          last_changed: "2026-11-14T10:00:00Z",
          attributes: { device_class: "pm10", unit_of_measurement: "µg/m³" },
        },
      ],
      [
        {
          entity_id: "sensor.living_voc",
          state: "120",
          last_changed: "2026-11-14T10:00:00Z",
          attributes: { device_class: "volatile_organic_compounds", unit_of_measurement: "µg/m³" },
        },
      ],
      [
        {
          entity_id: "sensor.living_pm25",
          state: "34",
          last_changed: "2026-11-14T10:00:00Z",
          attributes: { device_class: "pm25", unit_of_measurement: "µg/m³" },
        },
      ],
    ]);
    assert.equal(pollutantHistory.length, 1);
    assert.equal(pollutantHistory[0]?.pm25, 34);

    const { MiAccountsStore } = await import("../src/core/miAccountsStore.js");
    const { CredentialVault, serializeMiSession } = await import("../src/core/secureStore.js");
    const primarySess = {
      userId: "10001",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok-primary",
      passToken: "",
      region: "cn" as const,
    };
    const secondarySess = {
      userId: "20002",
      cUserId: "c2",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok-secondary",
      passToken: "",
      region: "sg" as const,
    };
    const credMap = new Map<string, string>();
    let failPrimaryRead = false;
    const flakyVault = new CredentialVault(async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
      const name = String(args.name ?? "");
      if (cmd === "secure_store_get") {
        if (name === "mi_session" && failPrimaryRead) {
          throw new Error("Win32 vault temporarily locked");
        }
        return (credMap.get(name) ?? null) as T | null;
      }
      if (cmd === "secure_store_set") {
        credMap.set(name, String(args.value ?? ""));
        return null;
      }
      if (cmd === "secure_store_delete") {
        credMap.delete(name);
        return null;
      }
      return null;
    });
    const acctStore = new MiAccountsStore(flakyVault, localStorage);
    await acctStore.upsertAccount(primarySess);
    await acctStore.upsertAccount(secondarySess);
    const savedPrimaryBefore = credMap.get("mi_session");
    assert.ok(savedPrimaryBefore);

    failPrimaryRead = true;
    const loadedDuringOutage = await acctStore.load();
    assert.equal(loadedDuringOutage.length, 2);
    assert.equal(credMap.get("mi_session"), savedPrimaryBefore);
    assert.equal(credMap.get("mi_session"), serializeMiSession(primarySess));
  });
});
