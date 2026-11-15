import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { scopedKey } from "../src/ui/panelPrefs.js";
import { handlePanelKey } from "../src/ui/panelKeyboard.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const result = document.querySelector<T>(selector);
  assert.ok(result, `Missing ${selector}`);
  return result;
}

beforeEach(() => {
  dom = mountTestWindow();
});

afterEach(async () => {
  app?.dispose();
  app = null;
  await closeTestWindow(dom);
});

describe("Classic Single-Card Glass Shell, 4-Size Bento Grid & Inline Accordion Drawers", () => {
  it("renders a single unified .cc-popover.cc-rim.is-unified-popover in classic and preserves dual-island in fluent", () => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));

    const popover = element("#app > .cc-popover");
    assert.equal(popover.classList.contains("cc-rim"), true);
    assert.equal(popover.classList.contains("is-unified-popover"), true);
    assert.equal(document.querySelectorAll(".cc-popover").length, 1);
    assert.equal(document.querySelectorAll(".win-island, .win-slider-deck").length, 0);

    assert.ok(popover.querySelector(":scope > .cc-header #btn-home-menu"));
    assert.ok(popover.querySelector(":scope > .cc-header #btn-all-off"));
    assert.ok(popover.querySelector(":scope > .cc-header .cc-env-strip"));
    assert.ok(popover.querySelector(':scope > .cc-classic-upper-stack[data-slot="classic-upper"]'));
    assert.ok(popover.querySelector(":scope > .cc-assistant-section .cc-spotlight-bar #command-input"));
    assert.ok(popover.querySelector(":scope > .cc-quick-strip"));
    assert.ok(popover.querySelector(":scope > .cc-room-bar"));
    assert.ok(popover.querySelector(":scope > .cc-scroll-area .cc-devices-grid"));
    assert.ok(popover.querySelector(":scope > .cc-footer #btn-settings"));

    app.settings.panelTheme = "fluent";
    app.render();

    const fluentPopover = element("#app > .cc-popover");
    assert.equal(fluentPopover.classList.contains("is-unified-popover"), false);
    assert.ok(fluentPopover.querySelector(".win-island--top"));
    assert.ok(fluentPopover.querySelector(".win-island--bottom"));
    assert.ok(fluentPopover.querySelector(".win-slider-deck"));
  });

  it("renders 4 Bento footprints (small, half without split-pill, hero 2x2, full 4x1 with inline sliders) in classic", () => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));
    app.devices.push(
      {
        id: "tv.living_oled",
        name: "客厅电视",
        roomId: "room_living",
        roomName: "客厅",
        model: "xiaomi.tv.oled1",
        isOnline: true,
        kind: {
          kind: "tv",
          mediaEntityId: "miot:tv.living_oled:2",
          state: "playing",
          volumePercent: 35,
          isMuted: false,
          muteSwitchEntityId: "miot:tv.living_oled:3",
          currentSource: "HDMI 1",
          availableSources: ["HDMI 1", "HDMI 2"],
          volumeWritable: true,
          volumePresent: true,
        },
      },
      {
        id: "humidifier.bedroom_mist",
        name: "卧室加湿器",
        roomId: "room_bedroom",
        roomName: "主卧",
        model: "zhimi.humidifier.ca4",
        isOnline: true,
        kind: {
          kind: "humidifier",
          entityId: "miot:humidifier.bedroom_mist:2",
          isOn: true,
          currentMode: "Auto",
          availableModes: ["Auto", "Sleep"],
          modeWritable: true,
          targetHumidity: 55,
          minHumidity: 30,
          maxHumidity: 80,
          step: 1,
          humidityWritable: true,
          currentHumidity: 48,
          powerWritable: true,
        },
      },
    );

    const key = (id: string) => scopedKey(app!.pageKey, id);
    app.layout.tileSizes[key("plug.entry_socket")] = "small";
    app.layout.tileSizes[key("light.living_ceiling")] = "half";
    app.layout.tileSizes[key("light.study_desk")] = "hero";
    app.layout.tileSizes[key("tv.living_oled")] = "full";
    app.layout.tileSizes[key("humidifier.bedroom_mist")] = "full";
    app.render();

    const smallTile = element('[data-tile-id="plug.entry_socket"]');
    assert.equal(smallTile.classList.contains("is-size-small"), true);
    assert.match(smallTile.getAttribute("style") ?? "", /grid-column:\s*span 3/);

    const halfTile = element('[data-tile-id="light.living_ceiling"]');
    assert.equal(halfTile.classList.contains("is-bento-card"), true);
    assert.equal(halfTile.classList.contains("is-capsule"), false);
    assert.equal(halfTile.querySelector(".win-split-pill"), null);
    assert.match(halfTile.getAttribute("style") ?? "", /grid-column:\s*span 6/);
    assert.ok(halfTile.querySelector(".cc-tile-fill"));

    app.pipeline.patchDimPreview(app, "light.living_ceiling", 33);
    assert.equal(
      halfTile.querySelector(".cc-tile-fill")?.getAttribute("style"),
      "width:33%;--fill-scale:0.330",
    );

    const heroTile = element('[data-tile-id="light.study_desk"]');
    assert.equal(heroTile.classList.contains("is-bento-hero"), true);
    assert.match(heroTile.getAttribute("style") ?? "", /grid-column:\s*span 6;\s*grid-row:\s*span 2/);
    assert.ok(heroTile.querySelector(".cc-hero-room-pill"));
    assert.ok(heroTile.querySelector(".cc-hero-primary-bar [data-inline-brightness]"));

    const fullTvTile = element('[data-tile-id="tv.living_oled"]');
    assert.equal(fullTvTile.classList.contains("is-span-row"), true);
    assert.match(fullTvTile.getAttribute("style") ?? "", /grid-column:\s*span 12/);
    assert.ok(fullTvTile.querySelector('[data-inline-volume="tv.living_oled"]'));

    const fullHumTile = element('[data-tile-id="humidifier.bedroom_mist"]');
    assert.ok(fullHumTile.querySelector('[data-inline-humidity="humidifier.bedroom_mist"]'));
  });

  it("expands inline .cc-expander-grid drawers across light, tv, humidifier, sensor, and plug while keeping sibling tiles visible and closes on Escape", () => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));
    app.devices.push(
      {
        id: "tv.living_oled",
        name: "客厅电视",
        roomId: "room_living",
        roomName: "客厅",
        model: "xiaomi.tv.oled1",
        isOnline: true,
        kind: {
          kind: "tv",
          mediaEntityId: "miot:tv.living_oled:2",
          state: "playing",
          volumePercent: 40,
          isMuted: false,
          muteSwitchEntityId: "miot:tv.living_oled:3",
          currentSource: "HDMI 1",
          availableSources: ["HDMI 1", "HDMI 2"],
          volumeWritable: true,
          volumePresent: true,
        },
      },
      {
        id: "humidifier.bedroom_mist",
        name: "卧室加湿器",
        roomId: "room_bedroom",
        roomName: "主卧",
        model: "zhimi.humidifier.ca4",
        isOnline: true,
        kind: {
          kind: "humidifier",
          entityId: "miot:humidifier.bedroom_mist:2",
          isOn: true,
          currentMode: "Auto",
          availableModes: ["Auto", "Sleep"],
          modeWritable: true,
          targetHumidity: 55,
          minHumidity: 30,
          maxHumidity: 80,
          step: 1,
          humidityWritable: true,
          currentHumidity: 48,
          powerWritable: true,
        },
      },
    );

    for (const targetId of [
      "light.living_ceiling",
      "tv.living_oled",
      "humidifier.bedroom_mist",
      "sensor.living_env",
      "plug.entry_socket",
    ]) {
      app.expandedDeviceId = targetId;
      app.render();

      const expandedTile = element(`[data-tile-id="${targetId}"]`);
      assert.equal(expandedTile.classList.contains("is-expanded"), true);
      assert.equal(expandedTile.classList.contains("is-span-row"), true);
      assert.equal(expandedTile.classList.contains("is-subpage"), false);
      assert.equal(expandedTile.querySelector(".win-subpage-back"), null);
      assert.ok(
        expandedTile.querySelector(".cc-expander-grid .cc-expander-clip"),
        `Expected .cc-expander-grid inside expanded ${targetId}`,
      );
      assert.ok(
        document.querySelectorAll("[data-tile-id]").length > 5,
        `Expected sibling tiles to stay mounted when ${targetId} is expanded in classic`,
      );
    }

    const handled = handlePanelKey(
      app,
      new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
    assert.equal(handled, true);
    assert.equal(app.expandedDeviceId, null);
  });

  it("preserves live #cc-camera-live-img DOM node across live fluent <-> classic theme switches and cycles all 5 sizes on resize handle tap", async () => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "fluent" }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));

    app.cameraLive.activeLiveCameraId = "camera.living_cam";
    app.cameraLive.liveCameraHidden = false;
    app.cameraLive.liveCameraStreamURL = "http://127.0.0.1:1984/api/frame.jpeg?src=living";
    app.render();

    const imgBefore = element<HTMLImageElement>("#cc-camera-live-img");
    app.cameraLive.liveCameraImgEl = imgBefore;

    app.settings.panelTheme = "classic";
    app.render();
    const imgInClassic = element<HTMLImageElement>("#cc-camera-live-img");
    assert.equal(imgInClassic, imgBefore);

    app.settings.panelTheme = "fluent";
    app.render();
    const imgBackInFluent = element<HTMLImageElement>("#cc-camera-live-img");
    assert.equal(imgBackInFluent, imgBefore);

    app.cameraLive.activeLiveCameraId = null;
    app.settings.panelTheme = "classic";
    app.isEditingLayout = true;
    const sizeKey = scopedKey(app.pageKey, "light.living_ceiling");
    app.layout.tileSizes[sizeKey] = "small";
    app.render();

    const expectedSequence = ["half", "hero", "full", "panel", "small"] as const;
    for (const expected of expectedSequence) {
      element<HTMLButtonElement>('[data-cycle-size="light.living_ceiling"]').click();
      await setImmediate();
      assert.equal(app.layout.tileSizes[sizeKey], expected);
    }
  });
});
