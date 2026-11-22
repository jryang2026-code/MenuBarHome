import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { openSettingsSheet, saveSettings } from "../src/ui/appLifecycle.js";
import { DEFAULT_PANEL_THEME, PANEL_THEMES, normalizePanelTheme } from "../src/ui/panelTheme.js";
import { loadSettings, writeSettingsForStorage } from "../src/ui/settings.js";
import { resolveSettingsAnchorTab } from "../src/ui/settingsSearch.js";
import { getSettingsTabSpec, normalizeSettingsTab } from "../src/ui/settingsViews.js";
import { assertMissing } from "./dom.js";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function seedSettings(overrides: Record<string, unknown> = {}): void {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
      ...overrides,
    }),
  );
}

function activeLight(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomId: "room_living",
    roomName: "客厅",
    model: "yeelink.light.ceiling22",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: id,
      isOn: true,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function activeVacuum(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomId: "room_living",
    roomName: "客厅",
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: id,
      status: "cleaning",
      battery: 90,
      modeEntityId: null,
      currentMode: null,
      availableModes: [],
    },
  };
}

describe("macOS v1.4.0 UI parity, 5-tab Settings sidebar & standalone window routing", () => {
  beforeEach(() => {
    dom = mountTestWindow();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    app?.dispose();
    app = null;
    const win = window as unknown as Record<string, unknown>;
    delete win.__MENUMIJIA_WINDOW_MODE__;
    delete win.__MENUMIJIA_SETTINGS_TAB__;
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("defaults panelTheme to 'classic' while retaining 'fluent' as selectable fallback", () => {
    assert.deepEqual(PANEL_THEMES, ["classic", "fluent"]);
    assert.equal(DEFAULT_PANEL_THEME, "classic");
    assert.equal(normalizePanelTheme(undefined), "classic");
    assert.equal(normalizePanelTheme("invalid"), "classic");
    assert.equal(normalizePanelTheme("fluent"), "fluent");
    assert.equal(loadSettings().settings.panelTheme, "classic");
  });

  it("renders macOS Classic main panel header, All-Off stack, spotlight mic, 3 room tools, and 3 footer actions", () => {
    seedSettings();
    app = new MenuMijiaWindowsApp(element("#app"));

    const popover = element("#app > .cc-popover");
    assert.equal(popover.classList.contains("is-unified-popover"), true);
    assert.ok(element(".cc-header .cc-home-emblem.is-active"));

    const homeMenu = element("#btn-home-menu");
    const homeMenuChildren = [...homeMenu.children];
    assert.equal(homeMenuChildren[0]?.classList.contains("cc-home-caret"), true);
    assert.equal(homeMenuChildren[1]?.classList.contains("cc-home-title"), true);

    assert.ok(element(".cc-header .cc-mode-pill.is-demo"));
    assertMissing(document.querySelector(".cc-header .cc-env-strip"));
    assert.match(element(".cc-header .cc-subtitle").textContent ?? "", /^\d+ 台开启/);

    const allOffBtn = element("#btn-all-off");
    assert.equal(allOffBtn.textContent?.trim(), "全关 3 台");
    assert.equal(element(".cc-all-off-caption").textContent?.trim(), "保留 2 台开启（含插座）");

    // When only non-plug active devices (e.g. cleaning vacuum) are retained, omit "（含插座）".
    app.devices = [activeLight("l1", "客厅主灯"), activeVacuum("v1", "扫地机器人")];
    app.render();
    assert.equal(element("#btn-all-off").textContent?.trim(), "全关 1 台");
    assert.equal(element(".cc-all-off-caption").textContent?.trim(), "保留 1 台开启");

    // Non-demo active home hides the header demo badge.
    app.settings.connectionMode = "xiaomiCloud";
    app.render();
    assertMissing(document.querySelector(".cc-header .cc-mode-pill"));

    // Mic lives inside .cc-spotlight-bar; header omits Fluent extras.
    assert.ok(element(".cc-spotlight-bar #btn-mic.cc-spotlight-mic"));
    assertMissing(document.querySelector("#btn-toggle-assistant"));
    assertMissing(document.querySelector("#btn-hide-panel"));

    // Room bar has 3 right tools (reorder, active grid toggle, offline toggle) in macOS order.
    const toolIds = [...document.querySelectorAll<HTMLElement>(".cc-room-tools > button")].map((b) => b.id);
    assert.deepEqual(toolIds, ["btn-room-order-editor", "btn-toggle-grid", "btn-toggle-hide-offline"]);
    assert.equal(element("#btn-toggle-grid").classList.contains("is-active"), true);

    // Classic footer has 3 icon buttons (refresh, settings, quit) and omits #btn-toggle-appearance.
    assertMissing(document.querySelector("#btn-toggle-appearance"));
    const footerIcons = [...document.querySelectorAll<HTMLElement>(".cc-footer-actions > .cc-footer-icon-btn")].map(
      (b) => b.id,
    );
    assert.deepEqual(footerIcons, ["btn-refresh", "btn-settings", "btn-quit-app"]);
  });

  it("renders 5-category Settings sidebar, normalizes legacy 'system' tab, and routes anchors to safety/about", () => {
    assert.equal(normalizeSettingsTab("system"), "safety");
    assert.equal(normalizeSettingsTab("unknown"), "general");
    assert.equal(getSettingsTabSpec("safety").title, "安全与提醒");
    assert.equal(getSettingsTabSpec("about").title, "关于与诊断");

    assert.equal(resolveSettingsAnchorTab("advancedDeviceWrites", false), "safety");
    assert.equal(resolveSettingsAnchorTab("allOffDevices", false), "safety");
    assert.equal(resolveSettingsAnchorTab("signOut", false), "about");
    assert.equal(resolveSettingsAnchorTab("quitApp", false), "about");
    assert.equal(resolveSettingsAnchorTab("aboutVersion", false), "about");
    assert.equal(resolveSettingsAnchorTab("aboutVersion", true), "general");

    seedSettings();
    app = new MenuMijiaWindowsApp(element("#app"));
    app.openSettingsSheet("general");

    const tabIds = [...document.querySelectorAll<HTMLElement>("[data-settings-tab]")].map((b) => b.dataset.settingsTab);
    assert.deepEqual(tabIds, ["general", "connection", "assistant", "safety", "about"]);
    assert.ok(document.querySelector('[data-settings-panel="about"] #btn-settings-quit'));
  });

  it("boots standalone settings window on legacy ?tab=system, skips onboarding, responds to tab events, and syncs across windows", async () => {
    const win = window as unknown as Record<string, unknown>;
    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    win.__MENUMIJIA_SETTINGS_TAB__ = "system";
    seedSettings({ hasCompletedOnboarding: false });

    app = new MenuMijiaWindowsApp(element("#app"));
    assert.equal(app.isStandaloneSettingsWindow, true);
    assert.equal(document.documentElement.classList.contains("is-settings-window"), true);
    assert.equal(app.activeSheet, "settings");
    assert.equal(app.settingsTab, "safety");
    assertMissing(document.querySelector('[data-onboarding-sheet]'));

    window.dispatchEvent(new window.CustomEvent("menumijia:select-settings-tab", { detail: { tab: "about" } }));
    assert.equal(app.settingsTab, "about");
    assert.equal(element("#settings-pane-title").textContent?.trim(), "关于与诊断");

    const invoked: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        metadata: { currentWindow: { label: "main" } },
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          invoked.push({ cmd, args });
          return null;
        },
      },
      configurable: true,
    });

    // Save from standalone window notifies main window with sourceLabel="settings".
    app.settings.panelTheme = "fluent";
    saveSettings(app);
    assert.equal(
      invoked.some((c) => c.cmd === "notify_settings_changed" && c.args?.sourceLabel === "settings"),
      true,
    );

    // Tear down standalone settings window and test main window IPC routing & sync.
    app.dispose();
    app = null;
    delete win.__MENUMIJIA_WINDOW_MODE__;
    delete win.__MENUMIJIA_SETTINGS_TAB__;
    document.documentElement.classList.remove("is-settings-window");
    document.body.innerHTML = '<div id="app"></div>';

    invoked.length = 0;
    seedSettings({ panelTheme: "classic" });
    app = new MenuMijiaWindowsApp(element("#app"));
    assert.equal(app.isStandaloneSettingsWindow, false);
    assert.equal(element("#app").dataset.panelTheme, "classic");

    // With __TAURI_INTERNALS__.metadata present, openSettingsSheet delegates to open_settings_window.
    openSettingsSheet(app, "safety");
    assert.equal(
      invoked.some((c) => c.cmd === "open_settings_window" && c.args?.tab === "safety"),
      true,
    );
    assert.equal(app.activeSheet, "none");

    // Cross-window sync reloads persisted localStorage changes written by standalone settings window.
    writeSettingsForStorage({ ...app.settings, panelTheme: "fluent" });
    window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));
    assert.equal(app.settings.panelTheme, "fluent");
    assert.equal(element("#app").dataset.panelTheme, "fluent");

    // Without __TAURI_INTERNALS__.metadata (pure web / DOM test fallback), openSettingsSheet opens in-DOM.
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          invoked.push({ cmd, args });
          return null;
        },
      },
      configurable: true,
    });
    openSettingsSheet(app, "about");
    await setImmediate();
    assert.equal(app.activeSheet, "settings");
    assert.equal(app.settingsTab, "about");
  });
});
