import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { AutomationRuleStore, createAutomationRule } from "../src/core/automationEngine.js";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { ScheduledCommandStore } from "../src/core/scheduledCommands.js";
import { serializeMiSession } from "../src/core/secureStore.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { openSettingsSheet, saveSettings } from "../src/ui/appLifecycle.js";
import { patchCloudPresentation } from "../src/ui/cloudRefresh.js";
import { DEFAULT_PANEL_THEME, PANEL_THEMES, normalizePanelTheme } from "../src/ui/panelTheme.js";
import { scheduledCommandIdentity } from "../src/ui/scheduledCommands.js";
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

  it("renders macOS Classic main panel header, All-Off stack, spotlight mic, 快捷 capsule + 3 room tools, and 3 footer actions", () => {
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

    // Room bar keeps the 3 right tools (reorder, active grid toggle, offline toggle) in macOS
    // order, plus the W2A-9b 快捷 capsule that folds the quick strip and For You cards.
    const toolIds = [...document.querySelectorAll<HTMLElement>(".cc-room-tools > button")].map((b) => b.id);
    assert.deepEqual(toolIds, ["btn-quick-drawer-toggle", "btn-room-order-editor", "btn-toggle-grid", "btn-toggle-hide-offline"]);
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
      invoked.some((c) => c.cmd === "open_settings_window" && c.args?.tab === "safety" && c.args?.anchor === undefined),
      true,
    );
    assert.equal(app.activeSheet, "none");

    invoked.length = 0;
    openSettingsSheet(app, "connection", "miCloudRegion");
    assert.equal(
      invoked.some(
        (c) =>
          c.cmd === "open_settings_window" &&
          c.args?.tab === "connection" &&
          c.args?.anchor === "miCloudRegion",
      ),
      true,
    );

    invoked.length = 0;
    openSettingsSheet(app, "connection", "unknownAnchor" as never);
    assert.equal(
      invoked.some(
        (c) =>
          c.cmd === "open_settings_window" &&
          c.args?.tab === "connection" &&
          c.args?.anchor === undefined,
      ),
      true,
    );

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

  it("preserves and rehydrates CredentialVault tokens in standalone settings across cross-window sync", async () => {
    const win = window as unknown as Record<string, unknown>;
    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    const vault = new Map<string, string>([
      [
        "mi_session",
        serializeMiSession({
          userId: "99887766",
          cUserId: "",
          ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
          serviceToken: "live-mi-token",
          passToken: "",
          region: "cn",
        }),
      ],
      ["ha_token", "live-ha-token"],
      ["assistant_api_key_deepseek", "sk-live-ds"],
    ]);
    const deleted: string[] = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        metadata: { currentWindow: { label: "settings" } },
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          const name = String(args.name ?? "");
          if (cmd === "secure_store_get") return vault.get(name) ?? null;
          if (cmd === "secure_store_set") {
            vault.set(name, String(args.value ?? ""));
            return null;
          }
          if (cmd === "secure_store_delete") {
            deleted.push(name);
            vault.delete(name);
            return null;
          }
          return null;
        },
      },
      configurable: true,
    });

    seedSettings({
      connectionMode: "homeAssistant",
      haBaseURL: "http://ha.local:8123",
      assistantBaseURL: "https://api.deepseek.com/v1",
      assistantKeyEndpoint: "api.deepseek.com",
    });

    app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    app.refreshHADevices = async () => {};
    await setImmediate();
    await setImmediate();

    assert.equal(app.settings.miSession?.userId, "99887766");
    assert.equal(app.settings.haToken, "live-ha-token");
    assert.equal(app.settings.openRouterApiKey, "sk-live-ds");

    // Simulate main window writing stripped localStorage & emitting cross-window sync.
    writeSettingsForStorage({ ...app.settings, panelOpacity: 0.88 });
    window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));
    await setImmediate();
    await setImmediate();

    // Toggling an unrelated preference in standalone Settings must not wipe vault credentials.
    app.settings.panelTheme = "fluent";
    saveSettings(app);
    await setImmediate();
    await setImmediate();

    assert.equal(deleted.length, 0);
    assert.ok(vault.get("mi_session")?.includes("99887766"));
    assert.equal(vault.get("ha_token"), "live-ha-token");
    assert.equal(app.settings.miSession?.userId, "99887766");
    assert.equal(app.settings.haToken, "live-ha-token");
  });

  it("guards native close requests in standalone settings via menumijia:request-close-settings", async () => {
    const win = window as unknown as Record<string, unknown>;
    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    const invoked: string[] = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        metadata: { currentWindow: { label: "settings" } },
        invoke: async (cmd: string) => {
          invoked.push(cmd);
          return null;
        },
      },
      configurable: true,
    });
    seedSettings();
    app = new MenuMijiaWindowsApp(element("#app"));

    // Clean close request closes the native window immediately.
    window.dispatchEvent(new window.CustomEvent("menumijia:request-close-settings"));
    assert.equal(invoked.includes("close_settings_window"), true);

    // Dirty edits intercept native close and surface #settings-unsaved-confirm instead.
    invoked.length = 0;
    element('[data-settings-tab="connection"]').click();
    const haInput = element<HTMLInputElement>("#settings-ha-url");
    haInput.value = "http://dirty.local:8123";
    haInput.dispatchEvent(new window.Event("input", { bubbles: true }));

    window.dispatchEvent(new window.CustomEvent("menumijia:request-close-settings"));
    assert.equal(invoked.includes("close_settings_window"), false);
    assert.equal(element("#settings-unsaved-confirm").hidden, false);

    // Discarding closes the native window cleanly.
    element("#btn-discard-settings").click();
    assert.equal(invoked.includes("close_settings_window"), true);
  });

  it("synchronizes eventAutomationEnabled lifecycle on main window when toggled from standalone settings", async () => {
    const ruleStore = new AutomationRuleStore();
    ruleStore.save([
      createAutomationRule({
        id: "r-sleep-parity",
        trigger: "systemSleep",
        action: { kind: "devices", deviceIds: ["light.living_ceiling"], isOn: false },
      }),
    ]);

    seedSettings({ eventAutomationEnabled: false });
    app = new MenuMijiaWindowsApp(element("#app"));
    const livingBefore = app.devices.find((d) => d.id === "light.living_ceiling");
    assert.equal(livingBefore?.kind.kind === "light" && livingBefore.kind.isOn, true);

    // While automation is disabled, system-sleep must not execute the rule.
    window.dispatchEvent(new window.CustomEvent("menumijia:system-sleep"));
    await setImmediate();
    await setImmediate();
    const livingWhileDisabled = app.devices.find((d) => d.id === "light.living_ceiling");
    assert.equal(livingWhileDisabled?.kind.kind === "light" && livingWhileDisabled.kind.isOn, true);

    // Simulate standalone Settings turning eventAutomationEnabled on and notifying main.
    writeSettingsForStorage({ ...app.settings, eventAutomationEnabled: true });
    window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));
    await setImmediate();

    window.dispatchEvent(new window.CustomEvent("menumijia:system-sleep"));
    await setImmediate();
    await setImmediate();
    const livingAfterEnable = app.devices.find((d) => d.id === "light.living_ceiling");
    assert.equal(livingAfterEnable?.kind.kind === "light" && livingAfterEnable.kind.isOn, false);
  });

  it("preserves main-window timers and rules when standalone settings toggles automation or schedules", () => {
    const win = window as unknown as Record<string, unknown>;
    const sharedStorage = localStorage;

    // Seed a stored enabled automation rule under a live source while standalone Settings has no timerSnapshot.
    const ruleStore = new AutomationRuleStore();
    ruleStore.save([
      createAutomationRule({
        id: "r-live-keep",
        trigger: "systemSleep",
        action: { kind: "devices", deviceIds: ["light.living_ceiling"], isOn: false },
      }),
    ]);

    const mainContainer = document.createElement("div");
    mainContainer.id = "main-host";
    document.body.appendChild(mainContainer);
    seedSettings({
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha.local:8123",
      haToken: "ha-tok",
      eventAutomationEnabled: false,
      scheduledCommandsEnabled: true,
    });
    const mainApp = new MenuMijiaWindowsApp(mainContainer);
    app = mainApp;

    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    const settingsContainer = document.createElement("div");
    settingsContainer.id = "settings-host";
    document.body.appendChild(settingsContainer);
    const settingsApp = new MenuMijiaWindowsApp(settingsContainer);

    try {
      // Main adds a timer after Settings is already open (Settings in-memory store stays stale).
      const futureMs = Date.now() + 60_000;
      const demoIdentity = scheduledCommandIdentity({ ...mainApp.settings, connectionMode: "demo" });
      const liveIdentity = scheduledCommandIdentity(mainApp.settings);
      assert.ok(liveIdentity);
      mainApp.scheduledCommands.push({
        id: "timer-added-on-main",
        command: "关闭客厅灯",
        reply: "1分钟后关闭客厅灯",
        delaySeconds: 60,
        fireTimestampMs: futureMs,
        intents: [{ targetId: "light.living_ceiling", operation: { kind: "power", isOn: false } }],
      });
      mainApp.scheduledCommandStore.persist();

      // Switch standalone Settings to safety tab and toggle automation on + schedules off.
      settingsContainer.querySelector<HTMLElement>('[data-settings-tab="safety"]')?.click();
      const autoToggle = settingsContainer.querySelector<HTMLInputElement>("#settings-event-automation-enabled")!;
      const timerToggle = settingsContainer.querySelector<HTMLInputElement>("#settings-scheduled-commands-enabled")!;
      autoToggle.checked = true;
      autoToggle.dispatchEvent(new window.Event("change"));
      timerToggle.checked = false;
      timerToggle.dispatchEvent(new window.Event("change"));

      // Enabling automation in standalone Settings without a live snapshot must not wipe enabled rules.
      const storedRulesAfter = new AutomationRuleStore().load();
      assert.equal(storedRulesAfter.find((r) => r.id === "r-live-keep")?.isEnabled, true);

      // Disabling schedules in standalone Settings must not overwrite timers added on main.
      window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));
      const verifyStore = new ScheduledCommandStore(sharedStorage);
      assert.ok(demoIdentity !== liveIdentity);
      const pausedEntries = verifyStore.entries().find(([id]) => id === liveIdentity)?.[1].pausedScheduledCommands ?? [];
      assert.deepEqual(
        pausedEntries.map((entry) => entry.command.id),
        ["timer-added-on-main"],
      );
    } finally {
      settingsApp.dispose();
      settingsContainer.remove();
      mainContainer.remove();
    }
  });

  it("invalidates main source-bound state when standalone settings changes source identity", () => {
    seedSettings({ connectionMode: "demo" });
    app = new MenuMijiaWindowsApp(element("#app"));
    const revBefore = app.sourceRevision;
    app.lastUndoAction = {
      summary: "old",
      steps: [],
      expiresAtMs: Date.now() + 60_000,
    };

    writeSettingsForStorage({
      ...app.settings,
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha.local:8123",
    });
    window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));

    assert.equal(app.sourceRevision > revBefore, true);
    assert.equal(app.lastUndoAction, null);
  });

  it("keeps companion registration and snapshot writes on main while forwarding settings toggles", async () => {
    const win = window as unknown as Record<string, unknown>;
    const mainInvoked: string[] = [];
    const settingsInvoked: string[] = [];
    let currentInvoked = mainInvoked;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        metadata: { currentWindow: { label: "main" } },
        invoke: async (cmd: string) => {
          currentInvoked.push(cmd);
          return cmd === "set_companion_integration" ? 1 : null;
        },
      },
      configurable: true,
    });

    seedSettings({ enableRaycastIntegration: true });
    const mainContainer = document.createElement("div");
    document.body.appendChild(mainContainer);
    const mainApp = new MenuMijiaWindowsApp(mainContainer);
    app = mainApp;
    await setImmediate();
    await setImmediate();
    assert.equal(mainInvoked.includes("set_companion_integration"), true);
    assert.equal(mainInvoked.includes("write_raycast_snapshot"), true);

    // Opening standalone Settings must NOT re-register companion or write its own bridgeToken snapshot.
    currentInvoked = settingsInvoked;
    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    const settingsContainer = document.createElement("div");
    document.body.appendChild(settingsContainer);
    const settingsApp = new MenuMijiaWindowsApp(settingsContainer);
    try {
      await setImmediate();
      await setImmediate();
      assert.equal(settingsInvoked.includes("set_companion_integration"), false);
      assert.equal(settingsInvoked.includes("write_raycast_snapshot"), false);

      // Settings can confirm native cleanup before showing the result.
      settingsContainer.querySelector<HTMLElement>('[data-settings-tab="safety"]')?.click();
      const raycastToggle = settingsContainer.querySelector<HTMLInputElement>("#settings-raycast-integration")!;
      raycastToggle.checked = false;
      raycastToggle.dispatchEvent(new window.Event("change"));
      await setImmediate();
      assert.equal(settingsInvoked.includes("set_companion_integration"), true);
      assert.equal(settingsInvoked.includes("write_raycast_snapshot"), false);

      currentInvoked = mainInvoked;
      window.dispatchEvent(new window.CustomEvent("menumijia:settings-sync"));
      await setImmediate();
      assert.equal(mainInvoked.filter((call) => call === "set_companion_integration").length, 2);
    } finally {
      settingsApp.dispose();
      settingsContainer.remove();
      mainContainer.remove();
    }
  });

  it("preserves classicStatusSummaryText in .cc-subtitle after incremental patchCloudPresentation", () => {
    seedSettings({ panelTheme: "classic" });
    app = new MenuMijiaWindowsApp(element("#app"));
    app.devices = [activeLight("l1", "客厅主灯")];
    app.environmentReadings = [
      { id: "env-1", label: "温湿度计", roomName: "客厅", temperature: 24.5, humidity: 52, battery: null },
    ];
    app.render();

    const expectedSubtitle = app.classicStatusSummaryText;
    assert.notEqual(expectedSubtitle, app.statusSummaryText);
    assert.equal(element(".cc-subtitle").textContent, expectedSubtitle);

    patchCloudPresentation(app);
    assert.equal(element(".cc-subtitle").textContent, expectedSubtitle);
  });

  it("highlights and expands standalone settings anchor on mount and when already open, ignoring unknown anchors", async () => {
    const win = window as unknown as Record<string, unknown>;
    win.__MENUMIJIA_WINDOW_MODE__ = "settings";
    win.__MENUMIJIA_SETTINGS_TAB__ = "connection";
    win.__MENUMIJIA_SETTINGS_ANCHOR__ = "miCloudRegion";
    seedSettings({ connectionMode: "homeAssistant" });

    try {
      app = new MenuMijiaWindowsApp(element("#app"));
      assert.equal(app.isStandaloneSettingsWindow, true);
      assert.equal(app.settingsTab, "connection");

      const regionEl = document.querySelector<HTMLElement>('[data-settings-anchor="miCloudRegion"]');
      const xiaomiDetails = document.querySelector<HTMLDetailsElement>('details[data-conn-section="xiaomiCloud"]');
      assert.equal(regionEl?.getAttribute("data-settings-highlighted"), "miCloudRegion");
      assert.equal(xiaomiDetails?.open, true);

      // Async credential hydration triggers a post-mount re-render; active highlight and expansion stay intact.
      await setImmediate();
      assert.equal(
        document.querySelector<HTMLElement>('[data-settings-anchor="miCloudRegion"]')?.getAttribute("data-settings-highlighted"),
        "miCloudRegion",
      );
      assert.equal(document.querySelector<HTMLDetailsElement>('details[data-conn-section="xiaomiCloud"]')?.open, true);

      // Already open: switches tab and highlights new anchor.
      window.dispatchEvent(
        new window.CustomEvent("menumijia:select-settings-tab", {
          detail: { tab: "general", anchor: "panelTheme" },
        }),
      );
      assert.equal(app.settingsTab, "general");
      assert.equal(
        document.querySelector<HTMLElement>('[data-settings-anchor="panelTheme"]')?.getAttribute("data-settings-highlighted"),
        "panelTheme",
      );
      assertMissing(document.querySelector('[data-settings-highlighted="miCloudRegion"]'));

      // Already open with anchor only (no explicit tab): resolves target tab, expands <details>, highlights anchor.
      window.dispatchEvent(
        new window.CustomEvent("menumijia:select-settings-tab", {
          detail: { tab: null, anchor: "miAccount" },
        }),
      );
      assert.equal(app.settingsTab, "connection");
      assert.equal(
        document.querySelector<HTMLElement>('[data-settings-anchor="miAccount"]')?.getAttribute("data-settings-highlighted"),
        "miAccount",
      );
      assert.equal(document.querySelector<HTMLDetailsElement>('details[data-conn-section="xiaomiCloud"]')?.open, true);

      // Unknown anchor clears highlight and falls back to normal tab switch.
      window.dispatchEvent(
        new window.CustomEvent("menumijia:select-settings-tab", {
          detail: { tab: "about", anchor: "unknownAnchor" },
        }),
      );
      assert.equal(app.settingsTab, "about");
      assertMissing(document.querySelector("[data-settings-highlighted]"));

      // Cold mount with unknown anchor behaves like normal mount without highlight.
      app.dispose();
      app = null;
      document.documentElement.classList.remove("is-settings-window");
      document.body.innerHTML = '<div id="app"></div>';
      win.__MENUMIJIA_SETTINGS_TAB__ = "safety";
      win.__MENUMIJIA_SETTINGS_ANCHOR__ = "nonExistentAnchor";

      app = new MenuMijiaWindowsApp(element("#app"));
      assert.equal(app.settingsTab, "safety");
      assertMissing(document.querySelector("[data-settings-highlighted]"));
    } finally {
      delete win.__MENUMIJIA_WINDOW_MODE__;
      delete win.__MENUMIJIA_SETTINGS_TAB__;
      delete win.__MENUMIJIA_SETTINGS_ANCHOR__;
      document.documentElement.classList.remove("is-settings-window");
    }
  });
});
