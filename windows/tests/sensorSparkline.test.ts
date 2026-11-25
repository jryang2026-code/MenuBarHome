import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import {
  resetSharedSensorHistoryStoreForTests,
  SensorHistoryStore,
  sharedSensorHistoryStore,
} from "../src/core/sensorHistory.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { computeSparklineGeometry } from "../src/ui/sensorHistoryView.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

class MapStorage {
  private readonly map = new Map<string, string>();
  getItem(key: string): string | null { return this.map.get(key) ?? null; }
  setItem(key: string, value: string): void { this.map.set(key, value); }
  removeItem(key: string): void { this.map.delete(key); }
}

let dom: Window;

describe("Sensor hover sparkline", () => {
  beforeEach(() => {
    dom = mountTestWindow();
    installCssEscape();
    localStorage.clear();
    resetSharedSensorHistoryStoreForTests();
  });

  afterEach(async () => {
    await closeTestWindow(dom);
  });

  it("enforces numericMinRange so minor 1-degree swings stay calm instead of jagged spikes", () => {
    const store = new SensorHistoryStore({ storage: new MapStorage(), connectionScope: "demo" });
    const anchor = new Date(2026, 4, 20, 18, 0, 0, 0).getTime();
    store.mergeCloudSamples(
      "sensor.living",
      "24h",
      [
        { timestamp: anchor - 3 * 3600_000, temperature: 22.0, humidity: 50 },
        { timestamp: anchor - 2 * 3600_000, temperature: 22.4, humidity: 51 },
        { timestamp: anchor - 1 * 3600_000, temperature: 22.1, humidity: 50 },
        { timestamp: anchor, temperature: 22.8, humidity: 52 },
      ],
      anchor,
    );

    const points = store.points("sensor.living", "24h", anchor);
    const geom = computeSparklineGeometry(points, "temperature", "celsius", 104, 20, 2);
    assert.ok(geom);
    assert.equal(geom.observedCount, 4);
    assert.ok(geom.yMaxDisplay - geom.yMinDisplay >= 5);
    assert.equal(geom.rangeLabel, "22.0–22.8°C");

    const ys = geom.coords.map((c) => c.y);
    const verticalTravel = Math.max(...ys) - Math.min(...ys);
    assert.ok(verticalTravel < 4, `expected calm vertical span <4px, got ${verticalTravel}`);
    assert.ok(verticalTravel > 1, `expected visible variation >1px, got ${verticalTravel}`);
  });

  it("clamps humidity sparkline bounds within 0...100 and handles empty/single-point histories", () => {
    const store = new SensorHistoryStore({ storage: new MapStorage(), connectionScope: "demo" });
    const anchor = new Date(2026, 4, 20, 18, 0, 0, 0).getTime();
    assert.equal(computeSparklineGeometry(store.points("sensor.empty", "24h", anchor), "temperature", "celsius"), null);

    store.mergeCloudSamples(
      "sensor.bath",
      "24h",
      [
        { timestamp: anchor - 3600_000, humidity: 96 },
        { timestamp: anchor, humidity: 99 },
      ],
      anchor,
    );
    const humGeom = computeSparklineGeometry(store.points("sensor.bath", "24h", anchor), "humidity", "celsius");
    assert.ok(humGeom);
    assert.ok(humGeom.yMinDisplay >= 0);
    assert.ok(humGeom.yMaxDisplay <= 100);
    assert.equal(humGeom.rangeLabel, "96–99%");

    store.mergeCloudSamples(
      "sensor.single",
      "24h",
      [{ timestamp: anchor, temperature: 25.0 }],
      anchor,
    );
    const singleGeom = computeSparklineGeometry(store.points("sensor.single", "24h", anchor), "temperature", "celsius");
    assert.ok(singleGeom);
    assert.equal(singleGeom.coords.length, 1);
  });

  it("renders read-only 24h hover sparklines on sensor cards and switches active metric on reading hover without network fetches", () => {
    let fetchCalls = 0;
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async () => {
      fetchCalls += 1;
      throw new Error("hover sparkline must not fetch");
    }) as typeof fetch;

    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          connectionMode: "demo",
          hasCompletedOnboarding: true,
          autoCheckUpdates: false,
          panelTheme: "fluent",
        }),
      );
      const root = document.getElementById("app")!;
      const app = new MenuMijiaWindowsApp(root);
      app.isLongTailExpanded = true;
      app.render();

      const card = root.querySelector<HTMLElement>('[data-sensor-card="sensor.living_env"]');
      assert.ok(card, "demo sensor card must be mounted");
      const tempSparkline = card.querySelector<HTMLElement>('.cc-sensor-sparkline[data-sparkline-metric="temperature"]');
      const humSparkline = card.querySelector<HTMLElement>('.cc-sensor-sparkline[data-sparkline-metric="humidity"]');
      assert.ok(tempSparkline, "temperature 24h sparkline should be rendered from local history");
      assert.ok(humSparkline, "humidity 24h sparkline should be rendered from local history");
      assert.equal(sharedSensorHistoryStore().isLoading("sensor.living_env", "24h"), false);

      const tempEl = card.querySelector<HTMLElement>(".cc-sensor-temp");
      assert.ok(tempEl);
      tempEl.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
      assert.equal(card.dataset.sparklineActive, "temperature");

      const humEl = card.querySelector<HTMLElement>(".cc-hum-ring, .cc-sensor-hum");
      assert.ok(humEl);
      humEl.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
      assert.equal(card.dataset.sparklineActive, "humidity");

      card.dispatchEvent(new window.MouseEvent("mouseleave", { bubbles: false }));
      assert.equal(card.dataset.sparklineActive, undefined);
      assert.equal(fetchCalls, 0);
    } finally {
      globalThis.fetch = origFetch;
    }
  });
});
