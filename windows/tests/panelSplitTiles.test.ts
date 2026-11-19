import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate as flushImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, FacetControl, SmartDevice } from "../src/core/models.js";
import { collapseActivityStackOnHide } from "../src/ui/activityStackView.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { cloudPanelStructureFingerprint, patchCloudPresentation } from "../src/ui/cloudRefresh.js";
import { deviceAdjustAriaLabel, resolveDeviceTileActionLayout } from "../src/ui/deviceViews.js";
import {
  formatBrowseByRoomTitle,
  formatLongTailCollapseTitle,
  formatLongTailExpandTitle,
  formatOfflineDrawerBadge,
  formatOfflineDrawerSummary,
  formatOfflineDrawerTitle,
  markPanelSessionInteraction,
} from "../src/ui/panelSplitTiles.js";
import { resolveTilePresentation } from "../src/ui/panelTheme.js";
import { setCustomApplyCommand } from "../src/ui/commandDispatch.js";
import { loadSettings } from "../src/ui/settings.js";
import { searchSettings, UNRESTRICTED_SETTINGS_AVAILABILITY } from "../src/ui/settingsSearch.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

const el = <T extends HTMLElement = HTMLElement>(selector: string): T => {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
};

const text = (selector: string): string => el(selector).textContent?.trim() ?? "";

const escape = (): void => {
  window.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
  );
};

function makeLight(
  id: string,
  name: string,
  options?: {
    roomId?: string;
    roomName?: string;
    isOnline?: boolean;
    isOn?: boolean;
    brightness?: number | null;
  },
): SmartDevice {
  return {
    id,
    name,
    roomName: options?.roomName ?? "客厅",
    roomId: options?.roomId ?? "room-living",
    isOnline: options?.isOnline ?? true,
    sourceBackend: "xiaomiCloud",
    model: "yeelink.light.color4",
    kind: {
      kind: "light",
      entityId: `miot:${id}:2`,
      isOn: options?.isOn ?? false,
      brightnessPercent: options?.brightness === undefined ? 65 : options.brightness,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function makeSimplePlug(
  id: string,
  name: string,
  options?: { isOnline?: boolean; isOn?: boolean; energyKwh?: number | null },
): SmartDevice {
  return {
    id,
    name,
    roomName: "客厅",
    roomId: "room-living",
    isOnline: options?.isOnline ?? true,
    sourceBackend: "xiaomiCloud",
    model: "chuangmi.plug.212a01",
    kind: {
      kind: "plug",
      switchEntityId: `miot:${id}:2`,
      isOn: options?.isOn ?? false,
      powerWatts: null,
      energyKwh: options?.energyKwh ?? null,
      childLockEntityId: null,
      isChildLocked: false,
    },
  };
}

function makeAdjustOnlyCurtain(id: string, name: string, isOnline = true): SmartDevice {
  return {
    id,
    name,
    roomName: "卧室",
    roomId: "room-bed",
    isOnline,
    sourceBackend: "homeAssistant",
    model: "lumi.curtain.hagl04",
    kind: {
      kind: "cover",
      entityId: `cover.${id}`,
      subtype: "curtain",
      positionPercent: 50,
      positionWritable: true,
      openDescription: null,
      closeDescription: null,
      pauseDescription: "暂停",
      batteryPercent: null,
      faultText: null,
      motion: "stopped",
    },
  };
}

function makeReadOnlyGeneric(id: string, name: string, isOnline = true): SmartDevice {
  return {
    id,
    name,
    roomName: "书房",
    roomId: "room-study",
    isOnline,
    sourceBackend: "homeAssistant",
    model: "binary_sensor.door",
    kind: {
      kind: "generic",
      deviceType: "contact-sensor",
      typeTitle: "门窗传感器",
      isOn: false,
      powerControl: null,
      isReadOnly: true,
      readouts: ["已闭合"],
      symbolName: null,
    },
  };
}

function makeCamera(
  id: string,
  name: string,
  options?: { isOnline?: boolean; isOn?: boolean; streamEntityId?: string | null },
): SmartDevice {
  return {
    id,
    name,
    roomName: "玄关",
    roomId: "room-entry",
    isOnline: options?.isOnline ?? true,
    sourceBackend: "xiaomiCloud",
    model: "isa.camera.hlc7",
    kind: {
      kind: "camera",
      entityId: `miot:${id}:2`,
      isOn: options?.isOn ?? false,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
      streamEntityId: options?.streamEntityId ?? null,
      powerWritable: true,
    },
  };
}

function makeHeaterClimate(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomName: "卧室",
    roomId: "room-bed",
    isOnline: true,
    sourceBackend: "xiaomiCloud",
    model: "zhimi.heater.ma3",
    kind: {
      kind: "climate",
      entityId: `miot:${id}:2`,
      isOn: false,
      hvacMode: "heat",
      availableModes: ["heat"],
      targetTemperature: 20,
      currentTemperature: 18,
      minTemp: 16,
      maxTemp: 28,
      step: 1,
      fanMode: null,
      availableFanModes: [],
    },
  };
}

function startApp(
  devices: SmartDevice[],
  extraSettings?: Record<string, unknown>,
  facets?: Record<string, readonly FacetControl[]>,
): { host: MenuMijiaWindowsApp; commands: DeviceCommand[] } {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      interfaceLanguage: "zh-Hans",
      ...extraSettings,
    }),
  );
  const host = new MenuMijiaWindowsApp(el("#app"));
  app = host;
  host.refreshDevices = async () => {};
  host.refreshHADevices = async () => {};
  host.settings.connectionMode = "xiaomiCloud";
  host.settings.miSession = {
    userId: "90001234",
    cUserId: "",
    ssecurity: "AAAAAAAAAAAAAAAAAAAAAA==",
    serviceToken: "y",
    passToken: "",
    region: "cn",
  };
  const commands: DeviceCommand[] = [];
  setCustomApplyCommand(host, async (command) => {
    commands.push(command);
    return true;
  });
  host.devices = devices;
  if (facets) {
    host.deviceFacets = facets;
  }
  host.render();
  return { host, commands };
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
});

afterEach(async () => {
  app?.dispose();
  app = null;
  await closeTestWindow(dom);
});

describe("WP5b-2 · 2-column compact split-tile defaults and settings toggle", () => {
  it("defaults isCompactGridMode to true on fresh install and uses 2-column span (6) across Fluent and Classic", () => {
    const loaded = loadSettings();
    assert.equal(loaded.settings.isCompactGridMode, true);

    assert.equal(
      resolveTilePresentation({ theme: "fluent", size: "half", isExpanded: false, hasDrawer: true }).cssColumnSpan,
      6,
    );
    assert.equal(
      resolveTilePresentation({ theme: "classic", size: "half", isExpanded: false, hasDrawer: true }).cssColumnSpan,
      6,
    );

    const { host } = startApp([
      makeLight("light-1", "客厅主灯", { isOn: true }),
      makeLight("light-2", "餐厅吊灯", { isOn: false }),
    ]);

    assert.equal(el('[data-tile-id="light-1"]').style.gridColumn, "span 6");
    host.setPanelTheme("classic");
    assert.equal(el('[data-tile-id="light-1"]').style.gridColumn, "span 6");
    assert.ok(el('[data-tile-id="light-1"]').classList.contains("is-bento-card"));
  });

  it("exposes compactGridMode in Settings › General › Advanced Display and Settings search", () => {
    const { host } = startApp([makeLight("light-1", "客厅主灯")]);
    host.openSettingsSheet("general");

    const checkbox = el<HTMLInputElement>("#settings-compact-grid");
    assert.equal(checkbox.checked, true);
    assert.ok(el('[data-settings-anchor="compactGridMode"]'));

    checkbox.checked = false;
    checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.equal(host.settings.isCompactGridMode, false);

    const searchOutcome = searchSettings("双列分体", UNRESTRICTED_SETTINGS_AVAILABILITY);
    assert.ok(searchOutcome.hits.some((hit) => hit.anchor === "compactGridMode"));
  });
});

describe("WP5b-2 · 4-way tile action layout, hit zones, a11y, camera lock guard, and high-risk confirm", () => {
  it("resolves split / primaryOnly / adjustOnly / readOnly identically across Fluent and Classic", async () => {
    const splitLight = makeLight("light-split", "吸顶灯", { isOn: false, brightness: 80 });
    const primaryPlug = makeSimplePlug("plug-primary", "桌面排插", { isOn: true, energyKwh: null });
    const adjustCurtain = makeAdjustOnlyCurtain("curtain-adjust", "卧室纱帘");
    const roSensor = makeReadOnlyGeneric("gen-ro", "门磁状态");

    assert.deepEqual(resolveDeviceTileActionLayout(splitLight, [], false), {
      kind: "split",
      primary: "togglePower",
    });
    assert.deepEqual(resolveDeviceTileActionLayout(primaryPlug, [], false), {
      kind: "primaryOnly",
      primary: "togglePower",
    });
    assert.equal(resolveDeviceTileActionLayout(adjustCurtain, [], false).kind, "adjustOnly");
    assert.equal(resolveDeviceTileActionLayout(roSensor, [], false).kind, "readOnly");

    const { host, commands } = startApp([splitLight, primaryPlug, adjustCurtain, roSensor]);

    for (const theme of ["fluent", "classic"] as const) {
      host.setPanelTheme(theme);
      host.expandedDeviceId = null;
      host.render();

      assert.equal(el('[data-tile-id="light-split"]').dataset.actionLayout, "split");
      assert.equal(el('[data-tile-id="plug-primary"]').dataset.actionLayout, "primaryOnly");
      assert.equal(el('[data-tile-id="curtain-adjust"]').dataset.actionLayout, "adjustOnly");
      assert.equal(el('[data-tile-id="gen-ro"]').dataset.actionLayout, "readOnly");

      // primaryOnly: has toggle, never renders misleading expand chevron
      assert.ok(document.querySelector('[data-tile-id="plug-primary"] [data-toggle-device="plug-primary"]'));
      assert.equal(document.querySelector('[data-tile-id="plug-primary"] [data-expand-device]'), null);

      // adjustOnly: has expand affordance, never renders dead power toggle
      assert.equal(document.querySelector('[data-tile-id="curtain-adjust"] [data-toggle-device]'), null);
      assert.ok(document.querySelector('[data-tile-id="curtain-adjust"] [data-expand-device="curtain-adjust"]'));

      // readOnly: renders read-only badge + non-button group, no power toggle or expand chevron
      assert.ok(document.querySelector('[data-tile-id="gen-ro"] .cc-readonly-badge'));
      assert.equal(document.querySelector('[data-tile-id="gen-ro"] [data-toggle-device]'), null);
      assert.equal(document.querySelector('[data-tile-id="gen-ro"] [data-expand-device]'), null);
      assert.equal(el('[data-body-device="gen-ro"]').tagName, "DIV");
      el('[data-body-device="gen-ro"]').click();
      assert.equal(host.expandedDeviceId, null);

      // split left primary zone toggles power without expanding drawer
      const beforeCount = commands.length;
      el<HTMLButtonElement>('[data-toggle-device="light-split"]').click();
      await flushImmediate();
      assert.equal(commands.length, beforeCount + 1);
      assert.equal(host.expandedDeviceId, null);

      // In Classic 2-column split card, clicking the left text body also triggers primary toggle
      if (theme === "classic") {
        el<HTMLButtonElement>('[data-body-device="light-split"]').click();
        await flushImmediate();
        assert.equal(commands.length, beforeCount + 2);
        assert.equal(host.expandedDeviceId, null);
      }

      // split right adjust button expands and collapses detail drawer with exact aria-label & aria-expanded
      const adjustBtn = el<HTMLButtonElement>('[data-expand-device="light-split"]');
      assert.equal(adjustBtn.getAttribute("aria-label"), "调节 吸顶灯");
      assert.equal(adjustBtn.getAttribute("aria-expanded"), "false");
      adjustBtn.click();
      assert.equal(host.expandedDeviceId, "light-split");

      if (theme === "classic") {
        const collapseBtn = el<HTMLButtonElement>('[data-expand-device="light-split"]');
        assert.equal(collapseBtn.getAttribute("aria-label"), "收起 吸顶灯 详细控制");
        assert.equal(collapseBtn.getAttribute("aria-expanded"), "true");
        collapseBtn.click();
        assert.equal(host.expandedDeviceId, null);
      }
    }
  });

  it("enters openCameraLiveView on locked workstation without silent wake writes or swallowed clicks", async () => {
    window.__TAURI_INTERNALS__ = {
      invoke: (async (cmd: string) => {
        if (cmd === "is_workstation_locked") return true;
        return undefined;
      }) as NonNullable<(typeof window)["__TAURI_INTERNALS__"]>["invoke"],
    };
    const sleepingCam = makeCamera("cam-sleep", "玄关摄像头", {
      isOnline: true,
      isOn: false,
      streamEntityId: null,
    });
    const awakeCam = makeCamera("cam-awake", "客厅摄像头", {
      isOnline: true,
      isOn: true,
      streamEntityId: null,
    });
    const { host, commands } = startApp([sleepingCam, awakeCam], {
      blockControlWhileLocked: true,
      panelTheme: "classic",
    });

    assert.deepEqual(resolveDeviceTileActionLayout(sleepingCam, [], true), {
      kind: "split",
      primary: "openCamera",
    });

    // Sleeping camera: opens camera sheet without silent wake writes and reports screen-lock banner
    el<HTMLButtonElement>('[data-open-camera="cam-sleep"]').click();
    await flushImmediate();
    await flushImmediate();
    assert.equal(commands.length, 0);
    assert.ok(document.querySelector(".cc-camera-live-sheet"));
    assert.match(host.replyBanner?.text ?? "", /锁定/);

    // Awake camera: opens camera sheet and surfaces lock notice directly inside the live sheet
    host.cameraLive.closeCameraLiveView();
    el<HTMLButtonElement>('[data-open-camera="cam-awake"]').click();
    await flushImmediate();
    await flushImmediate();
    assert.equal(commands.length, 0);
    assert.match(el(".cc-camera-live-sheet").textContent ?? "", /锁定/);
  });

  it("preserves two-step high-risk protection on compact split tiles and [data-high-risk-confirm] inside drawers (ui.md:178)", async () => {
    const heater = makeHeaterClimate("heater-bed", "卧室取暖器");
    const { host, commands } = startApp([heater], {
      panelTheme: "classic",
      layout: {
        order: [],
        tileSizes: { "heater-bed": "half" },
        collapsed: [],
        pinned: [],
        hidden: [],
        aliases: {},
        roomOrder: [],
        roomAliases: {},
        sceneOrder: [],
      },
    });

    assert.deepEqual(resolveDeviceTileActionLayout(heater, [], false), {
      kind: "split",
      primary: "togglePower",
    });

    // First tap on primary left zone arms pendingHighRisk instead of firing immediately
    el<HTMLButtonElement>('[data-toggle-device="heater-bed"]').click();
    await flushImmediate();
    assert.equal(commands.length, 0);
    assert.ok(host.pendingHighRisk);
    assert.equal(host.pendingHighRisk?.deviceId, "heater-bed");

    // Second tap confirms primary power toggle
    el<HTMLButtonElement>('[data-toggle-device="heater-bed"]').click();
    await flushImmediate();
    assert.equal(commands.length, 1);

    // Expand drawer and raise heater temperature slider -> renders [data-high-risk-confirm] button
    el<HTMLButtonElement>('[data-expand-device="heater-bed"]').click();
    const slider = el<HTMLInputElement>('[data-actemp="heater-bed"]');
    slider.value = "27";
    slider.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushImmediate();
    assert.equal(commands.length, 1);

    const confirmBtn = el<HTMLButtonElement>('[data-high-risk-confirm="heater-bed"]');
    assert.equal(confirmBtn.textContent?.trim(), "确认执行");
    confirmBtn.click();
    await flushImmediate();
    assert.equal(commands.length, 2);
  });
});

describe("WP5b-2 · All-view priority ordering, session freeze, >8 long-tail fold, and browse-by-room", () => {
  it("prioritizes pinned > active > recent habit > remaining in All view and freezes order after interaction", async () => {
    const now = Date.now();
    const devices = [
      makeLight("d-idle-1", "普通灯A", { isOn: false }),
      makeLight("d-habit", "最近常按灯", { isOn: false }),
      makeLight("d-active", "正在亮着的灯", { isOn: true }),
      makeLight("d-pinned", "置顶主灯", { isOn: false }),
    ];
    const { host } = startApp(devices, {
      layout: {
        order: [],
        tileSizes: {},
        collapsed: [],
        pinnedDeviceIds: ["d-pinned"],
        hidden: [],
        aliases: {},
        roomOrder: [],
        roomAliases: {},
        sceneOrder: [],
      },
      habitEntries: [
        {
          bucket: "evening",
          targetId: "d-habit",
          operationKey: "power:on",
          count: 5,
          lastRecordedAtMs: now - 60_000,
        },
      ],
    });

    const visibleIds = (): string[] =>
      Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]")).map(
        (node) => node.dataset.tileId ?? "",
      );

    assert.deepEqual(visibleIds(), ["d-pinned", "d-active", "d-habit", "d-idle-1"]);

    // Once user interacts in this session, turning off d-active must NOT jump cards under the pointer
    markPanelSessionInteraction(host, now);
    host.devices = devices.map((d) =>
      d.id === "d-active" ? makeLight("d-active", "正在亮着的灯", { isOn: false }) : d,
    );
    host.render();
    assert.deepEqual(visibleIds(), ["d-pinned", "d-active", "d-habit", "d-idle-1"]);

    // Hiding the panel resets session freeze so the next open reflects fresh active priority
    collapseActivityStackOnHide(host);
    host.render();
    assert.deepEqual(visibleIds(), ["d-pinned", "d-habit", "d-idle-1", "d-active"]);
  });

  it("folds >8 online devices in All view, keeps expanded/high-risk #9+ visible, and supports 按房间找", () => {
    const devices = Array.from({ length: 11 }, (_, idx) => {
      const n = idx + 1;
      const room =
        n <= 4
          ? { roomId: "r-living", roomName: "客厅" }
          : n <= 8
            ? { roomId: "r-bed", roomName: "卧室" }
            : { roomId: "r-study", roomName: "书房" };
      return makeLight(`d-${n}`, `设备${n}`, { ...room, isOn: n <= 2 });
    });

    const { host } = startApp(devices);

    const onlineTileIds = (): string[] =>
      Array.from(document.querySelectorAll<HTMLElement>(".cc-group [data-tile-id]")).map(
        (node) => node.dataset.tileId ?? "",
      );

    assert.equal(onlineTileIds().length, 8);
    assert.equal(text("[data-long-tail-toggle]"), "展开其余 3 台设备");
    assert.equal(el("[data-long-tail-toggle]").getAttribute("aria-expanded"), "false");
    assert.ok(document.querySelector("[data-browse-room-toggle]"));

    // Keep-alive: if #10 is expanded or has pendingHighRisk, it stays visible even while folded
    host.expandedDeviceId = "d-10";
    host.render();
    assert.ok(onlineTileIds().includes("d-10"));
    assert.equal(onlineTileIds().length, 9);
    host.expandedDeviceId = null;
    host.pendingHighRisk = {
      deviceId: "d-11",
      actionKey: "power:on",
      expiresAtMs: Date.now() + 10_000,
      sourceRevision: host.sourceRevision,
    };
    host.render();
    assert.ok(onlineTileIds().includes("d-11"));
    host.clearPendingHighRisk();
    host.render();
    assert.equal(onlineTileIds().length, 8);

    // Expand & collapse long-tail
    el<HTMLButtonElement>("[data-long-tail-toggle]").click();
    assert.equal(onlineTileIds().length, 11);
    assert.equal(text("[data-long-tail-toggle]"), "收起其余设备");
    assert.equal(el("[data-long-tail-toggle]").getAttribute("aria-expanded"), "true");

    // Escape collapses long-tail before hiding panel
    escape();
    assert.equal(host.isLongTailExpanded, false);
    assert.equal(onlineTileIds().length, 8);

    // Browse-by-room menu opens, navigates to 书房, shows all room devices without 8-item truncation, and focuses room pill
    el<HTMLButtonElement>("[data-browse-room-toggle]").click();
    assert.ok(document.querySelector("[data-browse-room-menu]"));
    el<HTMLButtonElement>('[data-browse-room-id="r-study"]').click();
    assert.equal(host.selectedRoom, "书房");
    assert.deepEqual(onlineTileIds(), ["d-9", "d-10", "d-11"]);
    assert.equal(document.querySelector("[data-long-tail-bar]"), null);
    assert.equal(document.activeElement, document.querySelector(".cc-room-pill.is-active"));
  });
});

describe("WP5b-2 · Offline sinking drawer, empty-pinned suppression, cloudRefresh parity, and i18n", () => {
  it("sinks offline devices into a collapsed bottom drawer, suppresses empty 常用 header, and syncs cloudRefresh flips", () => {
    const devices = [
      makeLight("on-1", "客厅主灯", { isOnline: true, isOn: true }),
      makeLight("off-pin", "离线床头灯", { isOnline: false, isOn: false }),
      makeSimplePlug("off-2", "玄关插座", { isOnline: false }),
      makeLight("off-3", "书房台灯", { isOnline: false }),
    ];

    const { host } = startApp(devices, {
      layout: {
        order: [],
        tileSizes: {},
        collapsed: [],
        pinnedDeviceIds: ["off-pin"],
        hidden: [],
        aliases: {},
        roomOrder: [],
        roomAliases: {},
        sceneOrder: [],
      },
    });

    // All pinned devices are offline -> must NOT render an empty 常用 group header
    assert.equal(document.querySelectorAll(".cc-group-header").length, 0);
    // Main online grid only renders online devices
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>(".cc-group [data-tile-id]")).map(
        (n) => n.dataset.tileId,
      ),
      ["on-1"],
    );

    // Offline drawer is collapsed by default with summary + count badge
    const drawerToggle = el<HTMLButtonElement>("[data-offline-drawer-toggle]");
    assert.equal(drawerToggle.getAttribute("aria-expanded"), "false");
    assert.equal(text(".cc-offline-drawer-title"), "离线或未通电");
    assert.equal(text(".cc-offline-drawer-badge"), "3 台");
    assert.equal(text(".cc-offline-drawer-summary"), "离线床头灯、玄关插座 等 3 台离线");
    assert.equal(document.querySelector("[data-offline-drawer-grid]"), null);

    // Silent cloudRefresh with unchanged topology patches cleanly without leaking offline tiles into online grid
    assert.equal(patchCloudPresentation(host), true);
    assert.equal(document.querySelectorAll(".cc-group [data-tile-id]").length, 1);

    // Expanding offline drawer renders read-only offline tiles that cannot open detail drawers
    drawerToggle.click();
    assert.equal(el("[data-offline-drawer-toggle]").getAttribute("aria-expanded"), "true");
    assert.equal(document.querySelectorAll("[data-offline-drawer-grid] [data-tile-id]").length, 3);
    assert.equal(document.querySelector('[data-tile-id="off-pin"] [data-expand-device]'), null);
    el('[data-body-device="off-pin"]').click();
    assert.equal(host.expandedDeviceId, null);

    // Escape collapses offline drawer and restores focus to its toggle
    escape();
    assert.equal(host.isOfflineDrawerExpanded, false);
    assert.equal(document.querySelector("[data-offline-drawer-grid]"), null);

    // Online <-> offline transition changes structure fingerprint and forces full render instead of stale patch
    const beforeFp = cloudPanelStructureFingerprint(host);
    host.devices = devices.map((d) =>
      d.id === "off-2" ? makeSimplePlug("off-2", "玄关插座", { isOnline: true, isOn: true }) : d,
    );
    const afterFp = cloudPanelStructureFingerprint(host);
    assert.notEqual(beforeFp, afterFp);
    assert.equal(patchCloudPresentation(host), false);
    host.render();
    assert.equal(document.querySelectorAll(".cc-group [data-tile-id]").length, 2);
    assert.equal(text(".cc-offline-drawer-badge"), "2 台");

    // hideOfflineDevices hides the bottom offline drawer completely
    host.settings.hideOfflineDevices = true;
    host.render();
    assert.equal(document.querySelector("[data-offline-drawer]"), null);
  });

  it("renders zh-Hans, zh-Hant, and en copy cleanly without raw keys", () => {
    const sample = [
      makeLight("1", "Living Lamp", { isOnline: false }),
      makeLight("2", "Desk Plug", { isOnline: false }),
      makeLight("3", "Study Fan", { isOnline: false }),
    ];

    setLanguage("zh-Hans");
    assert.equal(deviceAdjustAriaLabel("吸顶灯", false), "调节 吸顶灯");
    assert.equal(deviceAdjustAriaLabel("吸顶灯", true), "收起 吸顶灯 详细控制");
    assert.equal(formatOfflineDrawerTitle(), "离线或未通电");
    assert.equal(formatLongTailExpandTitle(4), "展开其余 4 台设备");
    assert.equal(formatLongTailCollapseTitle(), "收起其余设备");
    assert.equal(formatBrowseByRoomTitle(), "按房间找");

    setLanguage("zh-Hant");
    assert.equal(deviceAdjustAriaLabel("吸頂燈", false), "調節 吸頂燈");
    assert.equal(deviceAdjustAriaLabel("吸頂燈", true), "收起 吸頂燈 詳細控制");
    assert.equal(formatOfflineDrawerTitle(), "離線或未通電");
    assert.equal(formatOfflineDrawerBadge(3), "3 台");
    assert.equal(formatLongTailExpandTitle(4), "展開其餘 4 台設備");
    assert.equal(formatBrowseByRoomTitle(), "按房間找");

    setLanguage("en");
    assert.equal(deviceAdjustAriaLabel("Ceiling Light", false), "Adjust Ceiling Light");
    assert.equal(deviceAdjustAriaLabel("Ceiling Light", true), "Collapse Ceiling Light controls");
    assert.equal(formatOfflineDrawerTitle(), "Offline or Unpowered");
    assert.equal(formatOfflineDrawerSummary(sample), "Living Lamp, Desk Plug and 1 more offline");
    assert.equal(formatLongTailExpandTitle(4), "Show 4 More Devices");
    assert.equal(formatLongTailCollapseTitle(), "Show Less");
    assert.equal(formatBrowseByRoomTitle(), "By Room");
  });
});
