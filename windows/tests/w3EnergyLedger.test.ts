import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  ENERGY_RETENTION_DAYS,
  ENERGY_TOP_DEVICE_LIMIT,
  EnergyHistory,
  MAX_SINGLE_DELTA_KWH,
  energyScopeKey,
  getScopedEnergyHistory,
  localDayKey,
  type EnergyStorageLike,
} from "../src/core/energyHistory.js";
import { setLanguage } from "../src/core/i18n.js";
import { homeAssistantIdentity } from "../src/core/homeAssistant.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { searchSettings } from "../src/ui/settingsSearch.js";

let dom: Window;
let activeApps: MenuMijiaWindowsApp[] = [];

function makeMemoryStorage(): EnergyStorageLike & { readonly raw: Map<string, string> } {
  const raw = new Map<string, string>();
  return {
    raw,
    getItem: (k) => raw.get(k) ?? null,
    setItem: (k, v) => {
      raw.set(k, v);
    },
    removeItem: (k) => {
      raw.delete(k);
    },
  };
}

function localAt(dayOffset: number, hour: number, minute = 0): Date {
  return new Date(2026, 3, 1 + dayOffset, hour, minute, 0, 0);
}

function makePlug(
  id: string,
  name: string,
  energyKwh: number | null | undefined,
  opts: {
    roomId?: string;
    roomName?: string;
    powerWatts?: number | null;
    isOnline?: boolean;
    isOn?: boolean;
  } = {},
): SmartDevice {
  return {
    id,
    name,
    roomId: opts.roomId ?? "living",
    roomName: opts.roomName ?? "客厅",
    model: "chuangmi.plug.212a01",
    isOnline: opts.isOnline ?? true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn: opts.isOn ?? true,
      powerWatts: opts.powerWatts !== undefined ? opts.powerWatts : 120,
      energyKwh,
      childLockEntityId: null,
      isChildLocked: false,
    },
  };
}

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

function field(selector: string): HTMLInputElement {
  return element<HTMLInputElement>(selector);
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function typeText(selector: string, value: string): void {
  const input = field(selector);
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function startApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...extraSettings,
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  activeApps.push(app);
  return app;
}

function assertClose(actual: number | null | undefined, expected: number, eps = 1e-6): void {
  assert.ok(typeof actual === "number" && Number.isFinite(actual), `Expected finite number, got ${String(actual)}`);
  assert.ok(Math.abs(actual - expected) <= eps, `Expected ${actual} to be within ${eps} of ${expected}`);
}

beforeEach(() => {
  activeApps = [];
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  for (const app of activeApps) {
    app.dispose();
  }
  activeApps = [];
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Wave 3 · B3 Smart Plug 31-Day Energy Ledger Core Engine", () => {
  it("establishes a baseline on first reading without backfilling lifetime counter totals", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "test", storage });

    history.record([makePlug("plug_tv", "电视插座", 258.42)], localAt(0, 9));

    assert.equal(history.hasMeasuredConsumption, false);
    assert.deepEqual(history.recordingStartedAt, localAt(0, 9));
    assert.equal(history.todayTotalKwh(localAt(0, 12)), 0);
    assert.equal(history.totalKwh(7, localAt(0, 12)), 0);
    assert.equal(history.todayKwh("plug_tv", localAt(0, 12)), 0);
    assert.equal(history.deviceTotals(7, [], localAt(0, 12)).length, 0);

    const [today] = history.dailyTotals(1, localAt(0, 12));
    assert.ok(today);
    assert.equal(today.kwh, 0);
    assert.equal(today.isObserved, true);
  });

  it("accumulates positive deltas once and ignores duplicate or out-of-order timestamps", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "test", storage });

    history.record([makePlug("plug_ac", "空调伴侣", 10.0)], localAt(0, 9));
    history.record([makePlug("plug_ac", "空调伴侣", 10.65)], localAt(0, 11));
    history.record([makePlug("plug_ac", "空调伴侣", 10.65)], localAt(0, 11));
    history.record([makePlug("plug_ac", "空调伴侣", 12.0)], localAt(0, 10));
    history.record([makePlug("plug_ac", "空调伴侣", 11.0)], localAt(0, 12));

    assertClose(history.todayKwh("plug_ac", localAt(0, 12)), 1.0);
    assertClose(history.todayTotalKwh(localAt(0, 12)), 1.0);
  });

  it("rebases safely on firmware counter zeroing or rollback without recording negative kWh", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "test", storage });

    history.record([makePlug("plug_heater", "取暖器插座", 42.0)], localAt(0, 8));
    history.record([makePlug("plug_heater", "取暖器插座", 42.8)], localAt(0, 10));
    assertClose(history.todayTotalKwh(localAt(0, 10)), 0.8);

    history.record([makePlug("plug_heater", "取暖器插座", 0.05)], localAt(0, 11));
    assertClose(history.todayTotalKwh(localAt(0, 11)), 0.8);
    assertClose(history.todayKwh("plug_heater", localAt(0, 11)), 0.8);

    history.record([makePlug("plug_heater", "取暖器插座", 0.4)], localAt(0, 12));
    assertClose(history.todayTotalKwh(localAt(0, 12)), 1.15);
  });

  it("persists cross-day zero-delta sample dates across restarts and attributes new-day deltas accurately", () => {
    const storage = makeMemoryStorage();
    const first = new EnergyHistory({ scope: "test", storage });

    first.record(
      [
        makePlug("plug_idle", "书桌插座", 15.0),
        makePlug("plug_fridge", "冰箱插座", 30.0),
      ],
      localAt(0, 21),
    );

    first.record([makePlug("plug_fridge", "冰箱插座", 30.2)], localAt(1, 7));

    first.record([makePlug("plug_idle", "书桌插座", 15.0)], localAt(1, 8));

    const relaunched = new EnergyHistory({ scope: "test", storage });
    assert.equal(relaunched.todayKwh("plug_idle", localAt(1, 9)), 0);

    relaunched.record([makePlug("plug_idle", "书桌插座", 15.45)], localAt(1, 14));
    assertClose(relaunched.todayKwh("plug_idle", localAt(1, 15)), 0.45);

    const [day0, day1] = relaunched.dailyTotals(2, localAt(1, 15));
    assert.ok(day0 && day1);
    assert.equal(day0.dayKey, localDayKey(localAt(0, 0)));
    assert.equal(day1.dayKey, localDayKey(localAt(1, 0)));
    assertClose(day0.kwh, 0.2);
    assertClose(day1.kwh, 0.45);
    assert.equal(day0.isObserved, true);
    assert.equal(day1.isObserved, true);
  });

  it("marks unsampled days as unobserved and filters NaN, Infinity, negative, offline, wattage-only, and spike readings", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "test", storage });

    history.record(
      [
        makePlug("p1", "NaN插座", Number.NaN),
        makePlug("p2", "Inf插座", Number.POSITIVE_INFINITY),
        makePlug("p3", "负值插座", -3.2),
        makePlug("p4", "离线插座", 12.0, { isOnline: false }),
        makePlug("p5", "仅功率插座", null, { powerWatts: 1800 }),
      ],
      localAt(0, 8),
    );
    assert.equal(history.recordingStartedAt, null);
    assert.equal(history.hasMeasuredConsumption, false);

    history.record([makePlug("p_ok", "正常插座", 10.0)], localAt(0, 9));
    history.record([makePlug("p_ok", "正常插座", 10.5)], localAt(0, 18));

    history.record([makePlug("p_ok", "正常插座", Number.NaN)], localAt(0, 19));

    const spikedValue = 10.5 + MAX_SINGLE_DELTA_KWH + 250;
    history.record([makePlug("p_ok", "正常插座", spikedValue)], localAt(0, 20));
    assertClose(history.todayTotalKwh(localAt(0, 20)), 0.5);

    history.record([makePlug("p_ok", "正常插座", spikedValue + 0.25)], localAt(0, 21));
    assertClose(history.todayTotalKwh(localAt(0, 21)), 0.75);

    history.record([makePlug("p_ok", "正常插座", spikedValue + 0.25)], localAt(2, 9));
    history.record([makePlug("p_ok", "正常插座", spikedValue + 0.55)], localAt(2, 18));

    const threeDays = history.dailyTotals(3, localAt(2, 20));
    assert.deepEqual(
      threeDays.map((d) => d.isObserved),
      [true, false, true],
    );
    assertClose(threeDays[0]?.kwh, 0.75);
    assertClose(threeDays[1]?.kwh, 0);
    assertClose(threeDays[2]?.kwh, 0.3);
  });

  it("prunes ledger to 31 days, drops gaps exceeding retention, and ranks Top 6 devices with room & share", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "test", storage });

    const totalSimulatedDays = ENERGY_RETENTION_DAYS + 8;
    for (let day = 0; day < totalSimulatedDays; day++) {
      history.record([makePlug("plug_main", "客厅主插座", day)], localAt(day, 8));
      history.record([makePlug("plug_main", "客厅主插座", day + 1)], localAt(day, 20));
    }

    const lastDay = totalSimulatedDays - 1;
    const retained = history.dailyTotals(ENERGY_RETENTION_DAYS + 10, localAt(lastDay, 22));
    assert.equal(retained.length, ENERGY_RETENTION_DAYS);
    assertClose(history.totalKwh(ENERGY_RETENTION_DAYS, localAt(lastDay, 22)), ENERGY_RETENTION_DAYS);
    assert.equal(
      retained[0]?.dayKey,
      localDayKey(localAt(lastDay - (ENERGY_RETENTION_DAYS - 1), 0)),
    );

    const rankStorage = makeMemoryStorage();
    const rankHistory = new EnergyHistory({ scope: "rank", storage: rankStorage });
    const baselinePlugs = Array.from({ length: 8 }, (_, i) =>
      makePlug(`plug_${i + 1}`, `插座${i + 1}`, 100, { roomName: `房间${i + 1}` }),
    );
    const grownPlugs = Array.from({ length: 8 }, (_, i) =>
      makePlug(`plug_${i + 1}`, `插座${i + 1}`, 100 + (i + 1) * 0.5, { roomName: `房间${i + 1}` }),
    );
    rankHistory.record(baselinePlugs, localAt(0, 9));
    rankHistory.record(grownPlugs, localAt(0, 18));

    const top6 = rankHistory.topDevices(7, ENERGY_TOP_DEVICE_LIMIT, [], localAt(0, 20));
    assert.equal(top6.length, 6);
    assert.deepEqual(
      top6.map((d) => d.deviceId),
      ["plug_8", "plug_7", "plug_6", "plug_5", "plug_4", "plug_3"],
    );
    assert.equal(top6[0]?.name, "插座8");
    assert.equal(top6[0]?.roomName, "房间8");
    assertClose(top6[0]?.kwh, 4.0);
    assertClose(top6[0]?.share, 4 / 18);
    assertClose(top6[0]?.barFraction, 1);
  });

  it("isolates scopes across demo, Xiaomi Cloud accounts, and Home Assistant servers", () => {
    const demoKey = energyScopeKey({ connectionMode: "demo" });
    const miA = energyScopeKey({
      connectionMode: "xiaomiCloud",
      miSession: { userId: "10001", region: "cn" },
    });
    const miB = energyScopeKey({
      connectionMode: "xiaomiCloud",
      miSession: { userId: "20002", region: "de" },
    });
    const haA = energyScopeKey({
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha-one.example.test:8123",
      haToken: "token-alpha",
    });
    const haB = energyScopeKey({
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha-two.example.test:8123",
      haToken: "token-beta",
    });

    assert.equal(new Set([demoKey, miA, miB, haA, haB]).size, 5);

    const hA = getScopedEnergyHistory({
      connectionMode: "xiaomiCloud",
      miSession: { userId: "10001", region: "cn" },
    });
    const hB = getScopedEnergyHistory({
      connectionMode: "xiaomiCloud",
      miSession: { userId: "20002", region: "de" },
    });

    hA.record([makePlug("plug_shared_id", "A账号插座", 10)], localAt(0, 9));
    hA.record([makePlug("plug_shared_id", "A账号插座", 11.2)], localAt(0, 10));

    assertClose(hA.totalKwh(7, localAt(0, 12)), 1.2);
    assert.equal(hB.totalKwh(7, localAt(0, 12)), 0);
    assert.equal(hB.recordingStartedAt, null);
  });

  it("preserves previously saved electricity price on invalid/non-positive input and clears only when empty", () => {
    const storage = makeMemoryStorage();
    const history = new EnergyHistory({ scope: "price", storage });

    assert.equal(history.pricePerKwh, null);
    assert.equal(history.costForKwh(3), null);

    const saved = history.applyPriceInput("0.56");
    assert.deepEqual(saved, { action: "saved", pricePerKwh: 0.56 });
    assertClose(history.costForKwh(2), 1.12);

    for (const invalid of ["abc", "0", "-0.5", "NaN", "Infinity", "0.5.2", "--"]) {
      const outcome = history.applyPriceInput(invalid);
      assert.equal(outcome.action, "kept", `Input "${invalid}" should keep prior price`);
      assertClose(history.pricePerKwh, 0.56);
    }

    const commaSaved = history.applyPriceInput("0,65");
    assert.deepEqual(commaSaved, { action: "saved", pricePerKwh: 0.65 });
    assertClose(history.pricePerKwh, 0.65);

    history.record([makePlug("p1", "插座", 1)], localAt(0, 9));
    history.record([makePlug("p1", "插座", 2)], localAt(0, 10));
    history.clear();
    assertClose(history.pricePerKwh, 0.65);

    const cleared = history.applyPriceInput("   ");
    assert.deepEqual(cleared, { action: "cleared", pricePerKwh: null });
    assert.equal(history.pricePerKwh, null);
    assert.equal(history.costForKwh(2), null);

    storage.setItem(history.storageKey, "{not-valid-json");
    const recovered = new EnergyHistory({ scope: "price", storage });
    assert.equal(recovered.recordingStartedAt, null);
    assert.equal(recovered.hasMeasuredConsumption, false);
  });
});

describe("Wave 3 · B3 Energy Settings Panel, Plug Drawer Today Cell & Settings Search", () => {
  it("registers search anchors for 用电统计 / 插座电量 / 电费 / 电价 / energy / electricity / tariff / kwh", async () => {
    const queries = [
      "用电统计",
      "插座电量",
      "电费",
      "电价",
      "energy",
      "electricity",
      "tariff",
      "kwh",
      "yongdian",
      "dianfei",
    ];
    for (const q of queries) {
      const outcome = searchSettings(q);
      assert.ok(
        outcome.hits.some((h) => h.anchor === "energyHistory" && h.tab === "system"),
        `Expected query "${q}" to match energyHistory on system tab`,
      );
    }

    startApp();
    await click("#btn-settings");
    assert.equal(element('[data-settings-tab="general"]').getAttribute("aria-selected"), "true");

    typeText("#settings-search-input", "电费");
    await setImmediate();
    await click('[data-settings-search-hit="energyHistory"]');

    assert.equal(element('[data-settings-tab="system"]').getAttribute("aria-selected"), "true");
    assert.equal(
      element('[data-settings-anchor="energyHistory"]').classList.contains("is-search-highlighted"),
      true,
    );
  });

  it("shows 今日用电 and estimated cost inside the plug detail drawer without backfilling baseline", async () => {
    const app = startApp();
    app.devices = [
      makePlug("desk_plug", "书桌计量插座", 88.5, {
        roomId: "study",
        roomName: "书房",
        powerWatts: 145,
      }),
    ];
    app.expandedDeviceId = "desk_plug";
    app.render();

    const initialCell = element('[data-plug-today="desk_plug"]');
    assert.match(initialCell.textContent ?? "", /今日用电/);
    assert.match(initialCell.textContent ?? "", /0\.00 kWh/);
    assert.equal(document.querySelector('[data-plug-today-cost="desk_plug"]'), null);

    app.devices = [
      makePlug("desk_plug", "书桌计量插座", 88.85, {
        roomId: "study",
        roomName: "书房",
        powerWatts: 145,
      }),
    ];
    app.render();

    const drawerText = element('[data-tile-id="desk_plug"] .cc-tile-drawer').textContent ?? "";
    assert.match(drawerText, /145 W/);
    assert.match(drawerText, /88\.85 kWh/);
    assert.match(element('[data-plug-today="desk_plug"]').textContent ?? "", /0\.35 kWh/);

    getScopedEnergyHistory(app.settings).setPricePerKwh(0.6);
    app.render();
    assert.match(element('[data-plug-today-cost="desk_plug"]').textContent ?? "", /¥0\.21/);
  });

  it("renders 7-day bar chart, Top 6 ranking, typo-safe price input, and secondary clear confirmation in Settings", async () => {
    const now = new Date();
    const history = getScopedEnergyHistory({ connectionMode: "demo" });
    const plugsBase = Array.from({ length: 7 }, (_, i) =>
      makePlug(`plug_${i + 1}`, `插座${i + 1}`, 10, { roomName: `房间${i + 1}` }),
    );
    const plugsAfter = Array.from({ length: 7 }, (_, i) =>
      makePlug(`plug_${i + 1}`, `插座${i + 1}`, 10 + (i + 1) * 0.4, { roomName: `房间${i + 1}` }),
    );
    const t0 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 1, 0, 0);
    const t1 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 2, 0, 0);
    history.record(plugsBase, t0);
    history.record(plugsAfter, t1);

    const app = startApp();
    app.devices = plugsAfter;
    app.openSettingsSheet("system");
    await setImmediate();

    assert.equal(element("#settings-energy-today-kwh").textContent, "11.20 kWh");
    assert.equal(element("#settings-energy-week-kwh").textContent, "11.20 kWh");
    assert.equal(document.querySelectorAll("[data-energy-day]").length, 7);
    const rankRows = document.querySelectorAll("[data-energy-rank]");
    assert.equal(rankRows.length, 6);
    assert.match(rankRows[0]?.textContent ?? "", /插座7 · 房间7/);
    assert.match(rankRows[0]?.textContent ?? "", /2\.80 kWh · 25%/);

    typeText("#settings-energy-price", "0.50");
    await click("#btn-save-energy-price");
    assert.equal(field("#settings-energy-price").value, "0.50");
    assert.match(element("#settings-energy-today-cost").textContent ?? "", /¥5\.60/);
    assert.match(element("#settings-energy-week-cost").textContent ?? "", /¥5\.60/);

    typeText("#settings-energy-price", "-2");
    await click("#btn-save-energy-price");
    assert.equal(field("#settings-energy-price").value, "0.50");
    assertClose(history.pricePerKwh, 0.5);
    assert.ok(document.querySelector("#settings-energy-price-feedback"));

    typeText("#settings-energy-price", "abc");
    await click("#btn-save-energy-price");
    assert.equal(field("#settings-energy-price").value, "0.50");
    assertClose(history.pricePerKwh, 0.5);

    assert.equal(element("#settings-clear-energy-confirm").hidden, true);
    await click("#btn-clear-energy-history");
    assert.equal(element("#settings-clear-energy-confirm").hidden, false);

    await click("#btn-cancel-clear-energy");
    assert.equal(element("#settings-clear-energy-confirm").hidden, true);
    assert.equal(element("#settings-energy-today-kwh").textContent, "11.20 kWh");

    await click("#btn-clear-energy-history");
    assert.equal(element("#settings-clear-energy-confirm").hidden, false);
    await click('[data-settings-tab="general"]');
    await click('[data-settings-tab="system"]');
    assert.equal(element("#settings-clear-energy-confirm").hidden, true);

    await click("#btn-clear-energy-history");
    await click("#btn-confirm-clear-energy");
    assert.equal(element("#settings-energy-today-kwh").textContent, "—");
    assert.equal(element("#settings-energy-week-kwh").textContent, "—");
    assert.equal((element<HTMLButtonElement>("#btn-clear-energy-history")).disabled, true);
    assert.equal(field("#settings-energy-price").value, "0.50");
    assertClose(history.pricePerKwh, 0.5);

    typeText("#settings-energy-price", "");
    await click("#btn-save-energy-price");
    assert.equal(history.pricePerKwh, null);
    assert.equal(field("#settings-energy-price").value, "");
    assert.equal(document.querySelector("#btn-clear-energy-price"), null);

    typeText("#settings-energy-price", "0.68");
    field("#settings-energy-price").dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
    );
    await setImmediate();
    assertClose(history.pricePerKwh, 0.68);
    await click("#btn-clear-energy-price");
    assert.equal(history.pricePerKwh, null);
  });

  it("skips stale snapshots, formats <0.01 kWh, and escapes HTML in ranked device/room names", async () => {
    const history = getScopedEnergyHistory({ connectionMode: "demo" });
    const now = new Date();
    const t0 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 1, 0, 0);
    const t1 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 2, 0, 0);
    history.record([makePlug("xss_plug", "<img src=x onerror=alert(1)>", 5.0, { roomName: "<b>卧室</b>" })], t0);
    history.record([makePlug("xss_plug", "<img src=x onerror=alert(1)>", 5.004, { roomName: "<b>卧室</b>" })], t1);

    const app = startApp({ connectionMode: "xiaomiCloud", miSession: { userId: "888", region: "cn" } });
    app.cloudValuesStale = true;
    app.devices = [makePlug("stale_plug", "过期插座", 99.0)];
    app.render();
    assert.equal(getScopedEnergyHistory(app.settings).recordingStartedAt, null);

    app.settings.connectionMode = "demo";
    app.cloudValuesStale = false;
    app.devices = [makePlug("xss_plug", "<img src=x onerror=alert(1)>", 5.004, { roomName: "<b>卧室</b>" })];
    app.openSettingsSheet("system");
    await setImmediate();

    assert.equal(element("#settings-energy-today-kwh").textContent, "<0.01 kWh");
    assert.equal(element("#settings-energy-section").querySelector("img"), null);
    assert.equal(element("#settings-energy-section").querySelector("b"), null);
    assert.match(element("[data-energy-rank]").textContent ?? "", /<img src=x onerror=alert\(1\)> · <b>卧室<\/b>/);
  });

  it("does not treat cold-boot cached devices as a live today observation and renders zh-Hant / en copy", async () => {
    const cachedPlug = makePlug("cached_plug", "缓存插座", 12.34);
    const app = startApp({
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha.example.test:8123",
      haToken: "",
      cachedHAHome: null,
      cachedXiaomiDevices: [cachedPlug],
    });
    const haHistory = getScopedEnergyHistory(app.settings);
    assert.equal(haHistory.recordingStartedAt, null);

    app.openSettingsSheet("system");
    await setImmediate();

    setLanguage("zh-Hant");
    app.render();
    assert.match(element("#settings-energy-section").textContent ?? "", /插座用電統計/);
    assert.match(element("#settings-energy-section").textContent ?? "", /清空用電統計/);

    setLanguage("en");
    app.render();
    assert.match(element("#settings-energy-section").textContent ?? "", /Plug Energy/);
    assert.match(element("#settings-energy-section").textContent ?? "", /Clear Energy History/);
  });

  it("does not record cachedHAHome as observed during credential hydration when HA refresh fails", async () => {
    const haBaseURL = "https://ha.example.test:8123";
    const haToken = "ha-test-token-offline";
    const cachedPlug = makePlug("ha_cached_plug", "HA缓存插座", 64.25, {
      roomId: "living",
      roomName: "客厅",
      powerWatts: 95,
    });
    const invoke = async <T>(command: string, args: Record<string, unknown> = {}): Promise<T> => {
      if (command === "secure_store_get") {
        if (args.name === "ha_token") return haToken as unknown as T;
        return null as unknown as T;
      }
      if (command === "ha_snapshot") {
        throw new Error("Home Assistant authentication rejected (401)");
      }
      return null as unknown as T;
    };
    window.__TAURI_INTERNALS__ = { invoke };

    const app = startApp({
      connectionMode: "homeAssistant",
      haBaseURL,
      haToken: "",
      cachedHAHome: {
        identity: homeAssistantIdentity(haBaseURL, haToken),
        home: {
          devices: [cachedPlug],
          rooms: [],
          scenes: [],
          environmentReadings: [],
        },
      },
    });

    for (let i = 0; i < 8; i++) {
      await setImmediate();
    }

    assert.equal(app.settings.haToken, haToken);
    assert.equal(app.devices.length, 1);
    assert.ok(app.haConnectionError);

    const haHistory = getScopedEnergyHistory(app.settings);
    assert.equal(haHistory.recordingStartedAt, null);
    assert.equal(haHistory.isTodayObserved(), false);
    assert.equal(haHistory.todayKwh("ha_cached_plug"), null);

    app.expandedDeviceId = "ha_cached_plug";
    app.openSettingsSheet("system");
    await setImmediate();

    assert.equal(element("#settings-energy-today-kwh").textContent, "—");
    assert.match(element('[data-plug-today="ha_cached_plug"]').textContent ?? "", /—/);
  });

  it("displays local device aliases and local room aliases in the Top 6 energy ranking", async () => {
    const app = startApp();
    const rawPlugA = makePlug("plug_workstation", "原始排插A", 20.0, {
      roomId: "study_room",
      roomName: "原始书房",
    });
    const rawPlugB = makePlug("plug_router", "原始排插B", 10.0, {
      roomId: "hall_room",
      roomName: "原始玄关",
    });

    app.layout.aliases["plug_router"] = "弱电箱光猫插座";
    app.layout.roomAliases = { hall_room: "入户弱电间" };

    app.devices = [rawPlugA, rawPlugB];
    app.render();
    await new Promise((r) => setTimeout(r, 5));
    app.devices = [
      makePlug("plug_workstation", "原始排插A", 21.5, {
        roomId: "study_room",
        roomName: "原始书房",
      }),
      makePlug("plug_router", "原始排插B", 10.5, {
        roomId: "hall_room",
        roomName: "原始玄关",
      }),
    ];
    app.render();

    app.layout.aliases["plug_workstation"] = "电竞升降桌总插";
    app.layout.roomAliases = {
      ...app.layout.roomAliases,
      study_room: "主卧工作室",
    };
    app.devices = [
      makePlug("plug_workstation", "原始排插A", 21.5, {
        roomId: "study_room",
        roomName: "原始书房",
      }),
    ];
    app.openSettingsSheet("system");
    await setImmediate();

    const ranks = document.querySelectorAll("[data-energy-rank]");
    assert.equal(ranks.length, 2);
    assert.match(ranks[0]?.textContent ?? "", /电竞升降桌总插 · 主卧工作室/);
    assert.match(ranks[1]?.textContent ?? "", /弱电箱光猫插座 · 入户弱电间/);
  });

  it("handles narrow EnergyTrackableHost callers with HA credentials when optional dual-source fields are omitted", async () => {
    const { energyScopeForHost, syncEnergyHostOnRender } = await import("../src/ui/energySettingsView.js");
    const root = element("#app");
    const narrowHost = {
      root,
      settings: {
        connectionMode: "homeAssistant" as const,
        haBaseURL: "http://192.168.1.10:8123",
        haToken: "ha-token-123",
      },
      devices: [makePlug("ha_narrow_plug", "HA插座", 5.0)],
      timerSnapshot: { identity: "ha:http://192.168.1.10:8123", sourceRevision: 0 },
      sourceRevision: 0,
      render() {},
    };
    const scope = energyScopeForHost(narrowHost);
    assert.equal(scope.connectionMode, "homeAssistant");
    assert.equal(scope.dualSourceEnabled, false);
    assert.deepEqual(scope.activeAccountIds, []);
    syncEnergyHostOnRender(narrowHost);
    assert.ok(narrowHost);

    const rebaseHistory = new EnergyHistory({ scope: "dual-rebase-test", storage: makeMemoryStorage() });
    const d0 = new Date(2026, 10, 14, 10, 0, 0, 0);
    const d1 = new Date(2026, 10, 14, 10, 5, 0, 0);
    const d2 = new Date(2026, 10, 14, 10, 10, 0, 0);
    const d3 = new Date(2026, 10, 14, 10, 15, 0, 0);
    const haPlug10: SmartDevice = {
      ...makePlug("shared_plug", "客厅插座", 10.0),
      sourceBackend: "homeAssistant",
    };
    const haPlug10_5: SmartDevice = {
      ...makePlug("shared_plug", "客厅插座", 10.5),
      sourceBackend: "homeAssistant",
    };
    const miPlug100: SmartDevice = {
      ...makePlug("shared_plug", "客厅插座", 100.0),
      sourceBackend: "xiaomiCloud",
      accountId: "mi:cn:1",
    };
    const miPlug100_3: SmartDevice = {
      ...makePlug("shared_plug", "客厅插座", 100.3),
      sourceBackend: "xiaomiCloud",
      accountId: "mi:cn:1",
    };
    rebaseHistory.record([haPlug10], d0);
    rebaseHistory.record([haPlug10_5], d1);
    assert.ok(Math.abs((rebaseHistory.todayKwh("shared_plug", d1) ?? 0) - 0.5) < 1e-6);
    rebaseHistory.record([miPlug100], d2);
    assert.ok(Math.abs((rebaseHistory.todayKwh("shared_plug", d2) ?? 0) - 0.5) < 1e-6);
    rebaseHistory.record([miPlug100_3], d3);
    assert.ok(Math.abs((rebaseHistory.todayKwh("shared_plug", d3) ?? 0) - 0.8) < 1e-6);

    const { MultiAccountMiCloudProvider, makeMiAccount } = await import("../src/core/miAccountsStore.js");
    const { MiCloudError } = await import("../src/core/miCloudClient.js");
    const acc1 = makeMiAccount({
      userId: "1001",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok1",
      passToken: "",
      region: "cn",
    });
    const acc2 = makeMiAccount({
      userId: "2002",
      cUserId: "c2",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok2",
      passToken: "",
      region: "cn",
    });
    let currentRev = 0;
    let transportCalls = 0;
    const provider = new MultiAccountMiCloudProvider({
      accounts: [acc1, acc2],
      deviceOwners: { "100200300": [acc1.id, acc2.id] },
      specsByModel: {
        "cuco.plug.cp1": {
          type: "urn:miot-spec-v2:device:outlet:0000A002:cuco-cp1:1",
          services: [
            {
              iid: 2,
              type: "urn:miot-spec-v2:service:switch:0000780C:cuco-cp1:1",
              description: "Switch",
              properties: [
                {
                  iid: 1,
                  type: "urn:miot-spec-v2:property:on:00000006:cuco-cp1:1",
                  description: "Switch Status",
                  format: "bool",
                  access: ["read", "write", "notify"],
                },
              ],
              actions: [],
            },
          ],
        },
      },
      devices: [
        {
          ...miPlug100,
          id: "100200300",
          model: "cuco.plug.cp1",
          kind: {
            kind: "plug",
            switchEntityId: "miot:100200300:2",
            isOn: false,
            powerWatts: 0,
            energyKwh: 100,
            childLockEntityId: null,
            isChildLocked: false,
          },
        },
      ],
      specResolver: { resolve: async () => ({ type: "", services: [] }) },
      deviceForEntity: () => undefined,
      transport: async () => {
        transportCalls += 1;
        currentRev = 1;
        throw new MiCloudError("sessionExpired", "401");
      },
    });
    await assert.rejects(
      () =>
        provider.execute(
          { kind: "setSwitch", entityId: "miot:100200300:2", isOn: true },
          {
            beforeSend: () => {
              if (currentRev !== 0) throw new Error("stale source");
            },
          },
        ),
      /stale source/,
    );
    assert.equal(transportCalls, 1);

    const { getScopedEnergyHistory } = await import("../src/core/energyHistory.js");
    const midnightHost = {
      root: element("#app"),
      settings: {
        connectionMode: "demo" as const,
      },
      devices: [makePlug("midnight_plug", "跨夜插座", 10)],
      render() {},
    };
    const scopedHist = getScopedEnergyHistory({ connectionMode: "demo" });
    scopedHist.clear();
    const RealDate = globalThis.Date;
    const yesterdayMorning = localAt(-1, 22);
    const todayMorning = localAt(0, 8);
    const todayAfternoon = localAt(0, 14);
    try {
      globalThis.Date = class extends RealDate {
        constructor(...args: unknown[]) {
          if (args.length === 0) {
            super(yesterdayMorning.getTime());
          } else {
            super(...(args as [number]));
          }
        }
        static override now(): number {
          return yesterdayMorning.getTime();
        }
      } as DateConstructor;
      syncEnergyHostOnRender(midnightHost);

      globalThis.Date = class extends RealDate {
        constructor(...args: unknown[]) {
          if (args.length === 0) {
            super(todayMorning.getTime());
          } else {
            super(...(args as [number]));
          }
        }
        static override now(): number {
          return todayMorning.getTime();
        }
      } as DateConstructor;
      syncEnergyHostOnRender(midnightHost);

      midnightHost.devices = [makePlug("midnight_plug", "跨夜插座", 10.5)];
      globalThis.Date = class extends RealDate {
        constructor(...args: unknown[]) {
          if (args.length === 0) {
            super(todayAfternoon.getTime());
          } else {
            super(...(args as [number]));
          }
        }
        static override now(): number {
          return todayAfternoon.getTime();
        }
      } as DateConstructor;
      syncEnergyHostOnRender(midnightHost);
    } finally {
      globalThis.Date = RealDate;
    }
    assert.ok(Math.abs((scopedHist.todayKwh("midnight_plug", todayAfternoon) ?? 0) - 0.5) < 1e-6);
  });
});
