import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { filterByListCut, kindChips, orderAndAliasRooms } from "../src/ui/listCut.js";
import {
  TILE_SIZES,
  applyKindOrder,
  applyRoomOrder,
  emptyLayoutPrefs,
  hiddenDeviceIds,
  hideDevice,
  isDeviceHidden,
  isDevicePinned,
  movePinnedDevice,
  nextSize,
  normalizeTileSize,
  pageSections,
  pinDevice,
  pinnedDeviceIds,
  roomDisplayName,
  setRoomAlias,
  spans,
  targetSize,
  togglePinnedDevice,
  tr3,
  unhideAllDevices,
  unhideDevice,
  withAliases,
} from "../src/ui/panelPrefs.js";
import {
  RoomOrderDraft,
  cancelRoomOrderEditor,
  isRoomOrderEditorOpen,
  openRoomOrderEditor,
  saveRoomOrderEditor,
} from "../src/ui/roomOrderEditor.js";

function makeLight(
  id: string,
  name: string,
  roomId: string,
  roomName: string,
  overrides: Partial<SmartDevice> & { isOn?: boolean; brightnessPercent?: number; brightnessWritable?: boolean } = {},
): SmartDevice {
  const { isOn = true, brightnessPercent = 72, brightnessWritable = true, ...rest } = overrides;
  return {
    id,
    name,
    roomId,
    roomName,
    model: "yeelink.light.ceiling22",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: `miot:${id}:2`,
      isOn,
      brightnessPercent,
      colorTempKelvin: 4200,
      minKelvin: 2700,
      maxKelvin: 6500,
      availableEffects: ["Reading", "Night"],
      currentEffect: null,
      powerWritable: true,
      brightnessWritable,
      colorWritable: true,
    },
    ...rest,
  };
}

function makeCover(
  id: string,
  name: string,
  roomId: string,
  roomName: string,
  positionPercent = 40,
  subtype: "curtain" | "clothes-airer" | "garage-door" = "curtain",
  positionWritable = true,
): SmartDevice {
  return {
    id,
    name,
    roomId,
    roomName,
    model: "lumi.curtain.v1",
    isOnline: true,
    kind: {
      kind: "cover",
      entityId: `miot:${id}:2`,
      subtype,
      positionPercent,
      positionWritable,
      motion: "stopped",
      openDescription: "Open",
      closeDescription: "Close",
      pauseDescription: "Pause",
      batteryPercent: 88,
      faultText: null,
    },
  };
}

function makeFan(id: string, name: string, roomId: string, roomName: string, percentage = 55): SmartDevice {
  return {
    id,
    name,
    roomId,
    roomName,
    model: "zhimi.fan.za5",
    isOnline: true,
    kind: {
      kind: "fan",
      entityId: `miot:${id}:2`,
      isOn: true,
      percentage,
      presetMode: "Level 2",
      availablePresetModes: ["Level 1", "Level 2", "Level 3"],
      isOscillating: false,
      powerWritable: true,
      speedWritable: true,
      swingWritable: true,
    },
  };
}

function makeVacuum(id: string, name: string, roomId: string, roomName: string): SmartDevice {
  return {
    id,
    name,
    roomId,
    roomName,
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: `miot:${id}:2`,
      status: "docked",
      battery: 95,
      modeEntityId: null,
      currentMode: "Balanced",
      availableModes: ["Silent", "Balanced", "Turbo"],
      actionsWritable: true,
    },
  };
}

describe("Wave 2 A14: RoomOrderDraft, Favorites, Hidden Devices, 4-Step Sizes & Inline Sliders", () => {
  describe("pure RoomOrderDraft & panelPrefs helpers", () => {
    it("reorders visible rooms and resets default order while preserving unseen rooms from other homes", () => {
      const draft = new RoomOrderDraft({
        savedOrder: ["other_home_1", "r_study", "other_home_2", "r_living", "r_bed"],
        savedAliases: { r_living: "会客厅", other_home_1: "别墅主卧" },
        visibleIds: ["r_living", "r_bed", "r_study"],
      });

      assert.deepEqual(draft.visibleOrder(["r_living", "r_bed", "r_study"]), ["r_study", "r_living", "r_bed"]);
      assert.equal(draft.hasUnsavedChanges, false);

      assert.equal(draft.move("r_bed", -1, ["r_living", "r_bed", "r_study"]), true);
      assert.deepEqual(draft.order, ["other_home_1", "r_study", "other_home_2", "r_bed", "r_living"]);
      assert.equal(draft.hasUnsavedChanges, true);

      assert.equal(draft.moveToEdge("r_living", true, ["r_living", "r_bed", "r_study"]), true);
      assert.deepEqual(draft.visibleOrder(["r_living", "r_bed", "r_study"]), ["r_living", "r_study", "r_bed"]);

      draft.restoreDefaultOrder(["r_living", "r_bed", "r_study"]);
      assert.deepEqual(draft.order, ["other_home_1", "r_living", "other_home_2", "r_bed", "r_study"]);
      assert.equal(draft.isDefaultOrder(["r_living", "r_bed", "r_study"]), true);

      draft.setAlias("r_study", "  阅读室  ", "书房");
      assert.equal(draft.aliasFor("r_study"), "阅读室");
      draft.setAlias("r_study", "书房", "书房");
      assert.equal(draft.aliasFor("r_study"), "");
      draft.setAlias("r_living", "   ", "客厅");
      assert.equal(draft.aliasFor("r_living"), "");
      assert.equal(draft.aliases.other_home_1, "别墅主卧");
    });

    it("applies room order, room aliases, and device-kind order cleanly", () => {
      const prefs = emptyLayoutPrefs();
      prefs.roomOrder = ["r2", "r1"];
      setRoomAlias(prefs, "r1", "大客厅", "客厅");
      const rooms = applyRoomOrder(prefs, [
        { id: "r1", name: "客厅" },
        { id: "r2", name: "主卧" },
        { id: "r3", name: "阳台" },
      ]);
      assert.deepEqual(
        rooms.map((r) => `${r.id}:${r.name}`),
        ["r2:主卧", "r1:大客厅", "r3:阳台"],
      );
      assert.equal(roomDisplayName(prefs, "r1", "客厅"), "大客厅");
      setRoomAlias(prefs, "r1", "", "客厅");
      assert.equal(roomDisplayName(prefs, "r1", "客厅"), "客厅");

      const orderedKinds = applyKindOrder(
        ["cover", "fan"],
        ["light", "climate", "fan", "cover"],
        { light: 0, climate: 1, fan: 2, cover: 3 },
      );
      assert.deepEqual(orderedKinds, ["cover", "fan", "light", "climate"]);
    });

    it("preserves existing nextSize/targetSize/spans contracts and normalizes 4-step aliases", () => {
      assert.equal(normalizeTileSize("1x1"), "small");
      assert.equal(normalizeTileSize("2x1"), "half");
      assert.equal(normalizeTileSize("1x2"), "full");
      assert.equal(normalizeTileSize("2x2"), "hero");
      assert.equal(normalizeTileSize("panel"), "panel");
      assert.equal(normalizeTileSize("unknown"), "auto");

      assert.equal(nextSize("half"), "full");
      assert.equal(nextSize("full"), "panel");
      assert.equal(nextSize("panel"), "half");
      assert.equal(nextSize("small"), "half");
      assert.equal(nextSize("hero"), "half");

      assert.equal(targetSize("small", { width: 35, height: 0 }, true), "full");
      assert.equal(targetSize("hero", { width: -35, height: 0 }, true), "half");

      const devices = [
        makeLight("d1", "灯1", "r1", "客厅"),
        makeLight("d2", "灯2", "r1", "客厅"),
        makeLight("d3", "灯3", "r1", "客厅"),
        makeLight("d4", "灯4", "r1", "客厅"),
      ];
      const sizeLookup: Record<string, "small" | "half" | "full" | "hero"> = {
        d1: "small",
        d2: "half",
        d3: "full",
        d4: "hero",
      };
      const spanMap = spans(devices, (d) => sizeLookup[d.id] ?? "half");
      assert.equal(spanMap.get("d1"), 3);
      assert.equal(spanMap.get("d2"), 3);
      assert.equal(spanMap.get("d3"), 6);
      assert.equal(spanMap.get("d4"), 6);
      assert.deepEqual(
        TILE_SIZES.map((s) => s.id),
        ["auto", "small", "half", "full", "hero", "panel"],
      );
    });

    it("places pinned Favorites first on All page only and filters hidden devices via listCut", () => {
      const prefs = emptyLayoutPrefs();
      const d1 = makeLight("l1", "吸顶灯", "r1", "客厅");
      const d2 = makeCover("c1", "电动窗帘", "r1", "客厅");
      const d3 = makeFan("f1", "落地扇", "r2", "书房");
      const list = [d1, d2, d3];

      pinDevice("f1", prefs);
      pinDevice("c1", prefs);
      assert.deepEqual(pinnedDeviceIds(prefs), ["f1", "c1"]);
      movePinnedDevice("c1", -1, prefs);
      assert.deepEqual(pinnedDeviceIds(prefs), ["c1", "f1"]);

      const allSections = pageSections(prefs, withAliases(prefs, list), true);
      assert.equal(allSections.length, 2);
      assert.equal(allSections[0]?.id, "pinned");
      assert.deepEqual(
        allSections[0]?.devices.map((d) => d.id),
        ["c1", "f1"],
      );
      assert.deepEqual(
        allSections[1]?.devices.map((d) => d.id),
        ["l1"],
      );

      const roomSections = pageSections(prefs, withAliases(prefs, [d1, d2]), false);
      assert.equal(roomSections.length, 1);
      assert.equal(roomSections[0]?.title, null);

      hideDevice("c1", prefs);
      assert.equal(isDeviceHidden("c1", prefs), true);
      const visible = filterByListCut(list, { kind: "all" }, false, { layout: prefs });
      assert.deepEqual(
        visible.map((d) => d.id),
        ["l1", "f1"],
      );

      unhideDevice("c1", prefs);
      assert.equal(isDeviceHidden("c1", prefs), false);
      assert.equal(togglePinnedDevice("f1", prefs), false);
      assert.equal(isDevicePinned("f1", prefs), false);
    });

    it("covers Simplified Chinese, Traditional Chinese, and English via tr3 without missing catalog keys", () => {
      setLanguage("zh-Hans");
      assert.equal(tr3("设为常用（置顶）", "設為常用（置頂）", "Pin to Favorites"), "设为常用（置顶）");
      setLanguage("zh-Hant");
      assert.equal(tr3("设为常用（置顶）", "設為常用（置頂）", "Pin to Favorites"), "設為常用（置頂）");
      setLanguage("en");
      assert.equal(tr3("设为常用（置顶）", "設為常用（置頂）", "Pin to Favorites"), "Pin to Favorites");
      setLanguage("zh-Hans");
    });
  });

  describe("DOM integration: RoomOrderEditor, Favorites, Hidden Devices, 4-Step Sizes & Inline Sliders", () => {
    let dom: Window;
    let restoreCssEscape: () => void;

    const fixtureDevices = (): SmartDevice[] => [
      makeLight("light_living", "客厅吸顶灯", "r_living", "客厅", { brightnessPercent: 75 }),
      makeCover("curtain_living", "客厅纱帘", "r_living", "客厅", 40, "curtain"),
      makeFan("fan_study", "书房循环扇", "r_study", "书房", 60),
      makeVacuum("vac_bed", "主卧扫地机", "r_bed", "主卧"),
    ];

    const seedSettings = (extra: Record<string, unknown> = {}): void => {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          connectionMode: "xiaomiCloud",
          hasCompletedOnboarding: true,
          isCompactGridMode: true,
          cachedXiaomiDevices: fixtureDevices(),
          ...extra,
        }),
      );
    };

    const el = <T extends Element = HTMLElement>(selector: string): T => {
      const found = document.querySelector<T>(selector);
      assert.ok(found, `Expected element matching ${selector}`);
      return found;
    };

    beforeEach(() => {
      dom = mountTestWindow({ stubInterval: true });
      restoreCssEscape = installCssEscape();
      setLanguage("zh-Hans");
    });

    afterEach(async () => {
      setLanguage("zh-Hans");
      restoreCssEscape();
      await closeTestWindow(dom);
    });

    it("opens Room & Category Order Editor, discards draft on Cancel, and persists order + local room rename on Save", async () => {
      seedSettings();
      const app = new MenuMijiaWindowsApp(el("#app"));
      await setImmediate();

      const roomPillIds = () =>
        [...document.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-room-id]")].map(
          (b) => `${b.dataset.roomId}:${b.textContent?.trim()}`,
        );
      assert.deepEqual(roomPillIds(), ["r_living:客厅", "r_study:书房", "r_bed:主卧"]);

      el('.cc-room-pill[data-room-id="r_living"]').dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 80 }),
      );
      el<HTMLButtonElement>('[data-open-room-rename="r_living"]').click();
      assert.equal(isRoomOrderEditorOpen(app), true);

      const aliasInput = el<HTMLInputElement>('[data-room-alias-input="r_living"]');
      aliasInput.value = "阳光会客厅";
      aliasInput.dispatchEvent(new window.Event("input", { bubbles: true }));
      assert.equal(
        el('.cc-room-pill[data-room-id="r_living"]').textContent?.trim(),
        "阳光会客厅",
      );
      el<HTMLButtonElement>('[data-room-order-up="r_bed"]').click();
      cancelRoomOrderEditor(app);

      assert.equal(isRoomOrderEditorOpen(app), false);
      assert.deepEqual(roomPillIds(), ["r_living:客厅", "r_study:书房", "r_bed:主卧"]);
      assert.equal(app.layout.roomAliases?.r_living, undefined);

      app.selectRoom("r_living", "客厅");
      app.layout.tileSizes["客厅|light_living"] = "hero";
      app.layout.collapsed = ["客厅|rest"];
      app.render();

      el<HTMLButtonElement>("#btn-room-order-editor").click();
      assert.equal(isRoomOrderEditorOpen(app), true);
      el<HTMLButtonElement>('[data-room-order-up="r_study"]').click();
      const livingInput = el<HTMLInputElement>('[data-room-alias-input="r_living"]');
      livingInput.value = "阳光客厅";
      livingInput.dispatchEvent(new window.Event("input", { bubbles: true }));

      el<HTMLButtonElement>('[data-room-editor-tab="kinds"]').click();
      el<HTMLButtonElement>('[data-kind-order-up="vacuum"]').click();
      el<HTMLButtonElement>('[data-kind-order-up="vacuum"]').click();
      el<HTMLButtonElement>('[data-kind-order-up="vacuum"]').click();

      saveRoomOrderEditor(app);
      assert.equal(isRoomOrderEditorOpen(app), false);
      assert.equal(app.pageKey, "阳光客厅");
      assert.equal(app.layout.tileSizes["阳光客厅|light_living"], "hero");
      assert.equal(app.layout.tileSizes["客厅|light_living"], undefined);
      assert.deepEqual(app.layout.collapsed, ["阳光客厅|rest"]);
      assert.equal(app.tileSize(app.devices[0]!), "hero");
      app.selectRoom(null);
      app.render();

      assert.deepEqual(roomPillIds(), ["r_study:书房", "r_living:阳光客厅", "r_bed:主卧"]);
      const kindOrderDom = [...document.querySelectorAll<HTMLButtonElement>("[data-kind]")].map(
        (b) => b.dataset.kind,
      );
      assert.equal(kindOrderDom[0], "vacuum");

      assert.match(
        el('[data-tile-id="light_living"] .cc-tile-status').textContent ?? "",
        /阳光客厅/,
      );

      const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as {
        layout?: { roomOrder?: string[]; roomAliases?: Record<string, string>; kindOrder?: string[] };
      };
      assert.deepEqual(stored.layout?.roomOrder?.slice(0, 3), ["r_study", "r_living", "r_bed"]);
      assert.equal(stored.layout?.roomAliases?.r_living, "阳光客厅");
      assert.equal(stored.layout?.kindOrder?.[0], "vacuum");
      assert.deepEqual(
        orderAndAliasRooms([
          { id: "r_living", name: "客厅" },
          { id: "r_study", name: "书房" },
        ], app.layout),
        [
          { id: "r_study", name: "书房" },
          { id: "r_living", name: "阳光客厅" },
        ],
      );
      assert.equal(kindChips(app.devices, { kind: "all" }, false, { layout: app.layout })[0], "vacuum");

      openRoomOrderEditor(app, { focusRoomId: "r_living" });
      const clearInput = el<HTMLInputElement>('[data-room-alias-input="r_living"]');
      clearInput.value = "   ";
      clearInput.dispatchEvent(new window.Event("input", { bubbles: true }));
      el<HTMLButtonElement>("#btn-room-editor-save").click();
      assert.deepEqual(roomPillIds(), ["r_study:书房", "r_living:客厅", "r_bed:主卧"]);
      assert.equal(app.layout.tileSizes["客厅|light_living"], "hero");
      assert.deepEqual(app.layout.collapsed, ["客厅|rest"]);
    });

    it("pins Favorites to top on All view and hides/restores single devices across grid, edit mode, and panelPrefs API", async () => {
      seedSettings();
      const app = new MenuMijiaWindowsApp(el("#app"));
      await setImmediate();

      for (const id of ["vac_bed", "fan_study"]) {
        el(`[data-tile-id="${id}"]`).dispatchEvent(
          new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 90 }),
        );
        el<HTMLButtonElement>(`[data-toggle-pin="${id}"]`).click();
      }

      const headers = [...document.querySelectorAll(".cc-group-title")].map((n) => n.textContent?.trim());
      assert.equal(headers[0], "常用");
      const firstGridIds = [
        ...document.querySelectorAll(".cc-group:first-child [data-tile-id]"),
      ].map((n) => (n as HTMLElement).dataset.tileId);
      assert.deepEqual(firstGridIds, ["vac_bed", "fan_study"]);
      assert.ok(document.querySelector('[data-tile-id="vac_bed"] .cc-tile-pin-badge'));

      el('[data-tile-id="fan_study"]').dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 90 }),
      );
      el<HTMLButtonElement>('[data-move-pin="fan_study:-1"]').click();
      assert.deepEqual(
        [...document.querySelectorAll(".cc-group:first-child [data-tile-id]")].map(
          (n) => (n as HTMLElement).dataset.tileId,
        ),
        ["fan_study", "vac_bed"],
      );

      el('[data-tile-id="curtain_living"]').dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 90 }),
      );
      el<HTMLButtonElement>('[data-hide-device="curtain_living"]').click();
      assertMissing(document.querySelector('[data-tile-id="curtain_living"]'));
      assert.deepEqual(hiddenDeviceIds(app.layout), ["curtain_living"]);
      assert.equal(
        app.allOffTargets.some((d) => d.id === "curtain_living"),
        false,
      );

      app.startEditing();
      const hiddenTray = el(".cc-hidden-devices-tray");
      assert.match(hiddenTray.textContent ?? "", /客厅纱帘/);
      assert.ok(document.querySelector("#btn-edit-room-order"));
      el<HTMLButtonElement>('[data-unhide-device="curtain_living"]').click();
      assertMissing(document.querySelector(".cc-hidden-devices-tray"));
      app.stopEditing();
      assert.ok(document.querySelector('[data-tile-id="curtain_living"]'));
      assert.deepEqual(hiddenDeviceIds(app.layout), []);

      hideDevice("light_living", app.layout);
      hideDevice("fan_study", app.layout);
      app.saveLayout();
      app.render();
      assertMissing(document.querySelector('[data-tile-id="light_living"]'));
      assertMissing(document.querySelector('[data-tile-id="fan_study"]'));
      unhideAllDevices(app.layout);
      app.saveLayout();
      app.render();
      assert.ok(document.querySelector('[data-tile-id="light_living"]'));
      assert.ok(document.querySelector('[data-tile-id="fan_study"]'));
    });

    it("renders 4-step card sizes (`small` 1x1 compact tile, `half` 2x1, `full` 1x2, `hero` 2x2 large card)", async () => {
      seedSettings();
      const commands: DeviceCommand[] = [];
      const app = new MenuMijiaWindowsApp(el("#app"));
      app.executeSingleCommand = async (_dev, cmd) => {
        commands.push(cmd);
      };
      await setImmediate();

      const pickSize = (deviceId: string, sizeId: string): void => {
        el(`[data-tile-id="${deviceId}"]`).dispatchEvent(
          new window.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 60 }),
        );
        el<HTMLButtonElement>(`[data-set-size="${deviceId}:${sizeId}"]`).click();
      };

      pickSize("light_living", "small");
      const smallTile = el('[data-tile-id="light_living"]');
      assert.equal(smallTile.dataset.tileSize, "small");
      assert.equal(smallTile.classList.contains("is-size-small"), true);
      assert.match(smallTile.getAttribute("style") ?? "", /grid-column:\s*span 3/);
      assertMissing(smallTile.querySelector(".cc-tile-name"));
      const smallBtn = el<HTMLButtonElement>('[data-tile-id="light_living"] .cc-small-tile-btn');
      assert.match(smallBtn.title, /客厅吸顶灯/);
      smallBtn.click();
      await setImmediate();
      assert.equal(commands.length, 1);

      pickSize("light_living", "hero");
      const heroLight = el('[data-tile-id="light_living"]');
      assert.equal(heroLight.dataset.tileSize, "hero");
      assert.equal(heroLight.classList.contains("is-size-hero"), true);
      assert.match(heroLight.getAttribute("style") ?? "", /grid-column:\s*span 6/);
      assert.equal(heroLight.querySelector(".cc-hero-room-pill")?.textContent?.trim(), "客厅");
      assert.ok(heroLight.querySelector('[data-inline-brightness="light_living"]'));

      pickSize("vac_bed", "hero");
      const heroVac = el('[data-tile-id="vac_bed"]');
      assert.ok(heroVac.querySelector(".cc-hero-primary-bar [data-vacuumaction]"));

      pickSize("light_living", "half");
      assertMissing(document.querySelector('[data-inline-brightness="light_living"]'));
      pickSize("light_living", "full");
      assert.ok(document.querySelector('[data-inline-brightness="light_living"]'));
    });

    it("drives collapsed inline quick sliders on `full`/`hero` lights & curtains with §16 gesture render deferral and no accidental drawer expansion", async () => {
      seedSettings({ isCompactGridMode: false });
      const sent: Array<{ id: string; command: DeviceCommand; summary: string }> = [];
      const app = new MenuMijiaWindowsApp(el("#app"));
      app.executeSingleCommand = async (dev, command, summary) => {
        sent.push({ id: dev.id, command, summary });
      };
      await setImmediate();

      const briSlider = el<HTMLInputElement>('[data-inline-brightness="light_living"]');
      const coverSlider = el<HTMLInputElement>('[data-inline-coverpos="curtain_living"]');
      assert.equal(briSlider.value, "75");
      assert.equal(coverSlider.value, "40");
      assert.equal(app.expandedDeviceId, null);

      briSlider.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
      assert.equal(app.pointerIsDown, true);

      briSlider.value = "38";
      briSlider.dispatchEvent(new window.Event("input", { bubbles: true }));

      app.queueBackgroundRender();
      assert.equal(app.pendingCloudRender, true);
      assert.ok(document.querySelector('[data-inline-brightness="light_living"]') === briSlider);
      assert.equal(
        el('[data-tile-id="light_living"] .cc-inline-slider-val').textContent,
        "38%",
      );
      assert.equal(
        el<HTMLElement>('[data-tile-id="light_living"] .cc-tile-fill').style.width,
        "38%",
      );

      briSlider.dispatchEvent(new window.Event("change", { bubbles: true }));
      briSlider.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      await setImmediate();

      assert.equal(app.pointerIsDown, false);
      assert.equal(app.pendingCloudRender, false);
      assert.equal(app.expandedDeviceId, null);
      assert.equal(sent.length, 1);
      assert.deepEqual(sent[0]?.command, {
        kind: "setLightBrightness",
        entityId: "miot:light_living:2",
        percent: 38,
      });

      const liveCoverSlider = el<HTMLInputElement>('[data-inline-coverpos="curtain_living"]');
      liveCoverSlider.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
      liveCoverSlider.value = "99";
      liveCoverSlider.dispatchEvent(new window.Event("input", { bubbles: true }));
      assert.equal(
        el('[data-tile-id="curtain_living"] .cc-inline-slider-val').textContent,
        "99%",
      );
      liveCoverSlider.dispatchEvent(new window.Event("change", { bubbles: true }));
      liveCoverSlider.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      await setImmediate();

      assert.equal(app.expandedDeviceId, null);
      assert.equal(sent.length, 2);
      assert.deepEqual(sent[1]?.command, {
        kind: "setNumberValue",
        entityId: "miot:curtain_living:2",
        value: 99,
      });
      assert.match(sent[1]?.summary ?? "", /100%/);

      app.expandedDeviceId = "light_living";
      app.render();
      assertMissing(document.querySelector('[data-inline-brightness="light_living"]'));
      assert.ok(document.querySelector('[data-brightness="light_living"]'));
    });

    it("reorders pinned Favorites via edit-mode drag and renders tri-lingual UI (en / zh-Hant)", async () => {
      seedSettings();
      const app = new MenuMijiaWindowsApp(el("#app"));
      await setImmediate();

      app.layout.groups = [{ id: "g_clean", name: "清洁区" }];
      app.layout.groupMap.vac_bed = "g_clean";
      app.saveLayout();
      app.render();

      for (const id of ["light_living", "vac_bed"]) {
        el(`[data-tile-id="${id}"]`).dispatchEvent(
          new window.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 60 }),
        );
        el<HTMLButtonElement>(`[data-toggle-pin="${id}"]`).click();
      }
      assert.deepEqual(pinnedDeviceIds(app.layout), ["light_living", "vac_bed"]);

      app.startEditing();
      const tileFirst = el('[data-tile-id="light_living"]');
      const tileSecond = el('[data-tile-id="vac_bed"]');
      tileFirst.getBoundingClientRect = () =>
        ({ left: 10, top: 80, right: 160, bottom: 150, width: 150, height: 70 }) as DOMRect;
      tileSecond.getBoundingClientRect = () =>
        ({ left: 170, top: 80, right: 320, bottom: 150, width: 150, height: 70 }) as DOMRect;

      tileSecond.dispatchEvent(
        new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 200, clientY: 110 }),
      );
      window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 190, clientY: 110 }));
      el('[data-tile-id="light_living"]').getBoundingClientRect = () =>
        ({ left: 10, top: 80, right: 160, bottom: 150, width: 150, height: 70 }) as DOMRect;
      el('[data-tile-id="vac_bed"]').getBoundingClientRect = () =>
        ({ left: 170, top: 80, right: 320, bottom: 150, width: 150, height: 70 }) as DOMRect;
      window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 30, clientY: 110 }));
      window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, clientX: 30, clientY: 110 }));
      app.stopEditing();

      assert.deepEqual(pinnedDeviceIds(app.layout), ["vac_bed", "light_living"]);
      assert.equal(app.layout.groupMap.vac_bed, "g_clean");
      assert.equal(app.layout.groupMap.light_living, undefined);

      setLanguage("en");
      app.render();
      assert.equal(el(".cc-group-title").textContent?.trim(), "Favorites");
      openRoomOrderEditor(app);
      assert.match(el(".cc-room-editor-header strong").textContent ?? "", /Rooms & Categories/);
      cancelRoomOrderEditor(app);

      setLanguage("zh-Hant");
      app.render();
      openRoomOrderEditor(app);
      assert.match(el(".cc-room-editor-header strong").textContent ?? "", /房間與分類管理/);
      cancelRoomOrderEditor(app);

      el('[data-tile-id="vac_bed"]').dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 60 }),
      );
      assert.match(el(".cc-menu").textContent ?? "", /取消常用（置頂）/);
      assert.match(el(".cc-menu").textContent ?? "", /隱藏此設備/);
    });
  });
});
