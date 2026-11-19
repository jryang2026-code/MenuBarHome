import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { DUAL_SOURCE_ENABLED_STORAGE_KEY } from "../src/core/dualSourceProvider.js";
import { loadSharedCapabilityManifest } from "../src/core/capabilityManifest.js";
import {
  resolveCapabilityInstallSelection,
  type CapabilityInstallEvidence,
  type CapabilityInstallResolutionMode,
  type CapabilitySelection,
} from "../src/core/capabilityReferenceVerdict.js";
import { MI_ACCOUNT_CAPABILITY_STORAGE_KEY } from "../src/core/miAccountControl.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY } from "../src/core/scheduledCommands.js";
import { serializeMiSession } from "../src/core/secureStore.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  isDualSourceEnabled,
  resolveHostMiSelectionState,
  setHostDualSourceEnabled,
} from "../src/ui/cloudRefresh.js";
import { resolveConnectionStatus } from "../src/ui/connectionStatus.js";
import {
  detectPersistedLocalData,
  evaluateLegacyOnboardingMigration,
  loadSettings,
} from "../src/ui/settings.js";

let dom: Window;

function el<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  el(selector).click();
  await setImmediate();
}

function typeInput(selector: string, value: string): void {
  const input = el<HTMLInputElement>(selector);
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function readStoredMigrationComplete(): boolean | null {
  const raw = localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
  if (!raw) return null;
  const parsed = JSON.parse(raw) as { migrationComplete?: unknown };
  return typeof parsed.migrationComplete === "boolean" ? parsed.migrationComplete : null;
}

describe("P4a-W / WP4a · First-run 3-card onboarding, on-demand LAN gate, and legacy migration", () => {
  beforeEach(() => {
    dom = mountTestWindow();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    await closeTestWindow(dom);
  });

  it("matches shared Tests/Fixtures/capability_selection_golden.json upgradeCases without altering semantics", () => {
    const manifest = loadSharedCapabilityManifest();
    const corpus = JSON.parse(
      readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/capability_selection_golden.json"), "utf8"),
    ) as {
      upgradeCases: readonly {
        id: string;
        evidence: CapabilityInstallEvidence;
        expectedMode: CapabilityInstallResolutionMode;
        expectedPersistMigrationComplete: boolean;
        expectedRetryDiagnostic: string | null;
        expectedSelection: CapabilitySelection;
      }[];
    };
    assert.ok(corpus.upgradeCases.length >= 4);
    for (const c of corpus.upgradeCases) {
      const actual = resolveCapabilityInstallSelection(c.evidence, manifest);
      assert.equal(actual.mode, c.expectedMode, c.id);
      assert.equal(actual.persistMigrationComplete, c.expectedPersistMigrationComplete, c.id);
      assert.equal(actual.retryDiagnostic, c.expectedRetryDiagnostic, c.id);
      assert.deepEqual(actual.selection, c.expectedSelection, c.id);
    }

    // Fresh install keeps all current device categories enabled by default (pending user ruling).
    const freshLoaded = loadSettings();
    assert.equal(evaluateLegacyOnboardingMigration(freshLoaded).shouldShowOnboarding, true);
    const freshState = resolveHostMiSelectionState({
      settings: freshLoaded.settings,
      loadedSettings: freshLoaded,
      timerCredentialsReady: false,
    });
    assert.equal(freshState.mode, "freshInstall");
    assert.deepEqual(freshState.selection.enabledCategories, corpus.upgradeCases[0]!.expectedSelection.enabledCategories);
    assert.equal(readStoredMigrationComplete(), null, "fresh install must not prematurely seal migrationComplete");
  });

  it("renders 3 platform cards on fresh install with zero automatic LAN or network requests", async () => {
    const tauriCalls: Array<{ name: string; args: Record<string, unknown> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string, args: Record<string, unknown> = {}) => {
          tauriCalls.push({ name, args });
          return null;
        },
      },
      configurable: true,
    });

    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    await setImmediate();

    assert.equal(app.activeSheet, "onboarding");
    assert.ok(document.querySelector('[data-onboarding-card="xiaomiCloud"]'));
    assert.ok(document.querySelector('[data-onboarding-card="homeAssistant"]'));
    assert.ok(document.querySelector('[data-onboarding-card="demo"]'));

    const forbidden = new Set(["native_http", "ha_snapshot", "set_service_endpoints"]);
    assert.deepEqual(
      tauriCalls.filter((c) => forbidden.has(c.name)),
      [],
      "fresh install must not make automatic LAN, HA, or HTTP requests before user action",
    );

    // Selecting Mi card reveals the non-official risk note and expandable region selector without network calls.
    await click('[data-onboarding-card="xiaomiCloud"]');
    assert.ok(document.querySelector("[data-onboarding-mi-warning]"), "Mi card shows non-official risk note");
    assert.ok(document.querySelector("[data-onboarding-mi-region-details]"), "Mi card keeps region selector expandable");

    // Selecting HA card shows manual address entry only (LAN auto-discovery moved to a follow-up host command slice).
    await click('[data-onboarding-card="homeAssistant"]');
    assert.equal(document.querySelector("#btn-onboarding-discover-ha"), null);
    assert.ok(document.querySelector("#onboarding-ha-url"));
    assert.deepEqual(
      tauriCalls.filter((c) => forbidden.has(c.name)),
      [],
      "selecting HA card must not trigger any LAN or HTTP requests",
    );
  });

  it("preserves HA draft on verification error and enables dual-source via setHostDualSourceEnabled when adding Mi as second platform", async () => {
    let failNext = true;
    const haFixture = JSON.parse(readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/ha_snapshot.json"), "utf8")) as unknown;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string) => {
          if (name === "ha_snapshot") {
            if (failNext) throw new Error("401 Unauthorized");
            return haFixture;
          }
          return null;
        },
      },
      configurable: true,
    });

    const app = new MenuMijiaWindowsApp(el("#app"));
    // Simulate a user who previously turned off dual-source in the same session.
    setHostDualSourceEnabled(app, false, { persist: true });
    await setImmediate();

    await click('[data-onboarding-card="homeAssistant"]');
    assert.equal(el("[data-onboarding-ha-http-warning]").hidden, true);
    typeInput("#onboarding-ha-url", "http://203.0.113.5:8123");
    assert.equal(el("[data-onboarding-ha-http-warning]").hidden, false, "remote plaintext HTTP shows warning live");
    typeInput("#onboarding-ha-url", "http://192.168.1.50:8123");
    assert.equal(el("[data-onboarding-ha-http-warning]").hidden, true, "private LAN HTTP stays quiet");
    typeInput("#onboarding-ha-token", "bad-token-123");

    await click("#btn-onboarding-connect-ha");
    await setImmediate();
    assert.match(el("[data-onboarding-ha-error]").textContent ?? "", /专属连接钥匙无效或已过期.*设备还未同步/);
    assert.equal(el<HTMLInputElement>("#onboarding-ha-url").value, "http://192.168.1.50:8123", "draft URL kept on error");
    assert.equal(el<HTMLInputElement>("#onboarding-ha-token").value, "bad-token-123", "draft token kept on error");

    failNext = false;
    await click("#btn-onboarding-connect-ha");
    await setImmediate();
    assert.ok(document.querySelector("[data-onboarding-ha-verified]"));

    const addSecond = el("#btn-onboarding-add-second-platform");
    assert.equal(addSecond.dataset.secondPlatform, "xiaomiCloud");
    await click("#btn-onboarding-add-second-platform");
    assert.ok(document.querySelector("#btn-start-qr"), "navigates to Mi QR step for second platform");
    assert.equal(isDualSourceEnabled(app), false, "does not enable dual-source before connecting second platform");
    let qrStarted = false;
    app.startXiaomiQRLogin = async () => { qrStarted = true; };
    await click("#btn-start-qr");
    assert.equal(qrStarted, true);
    assert.equal(app.dualSourceEnabledOverride, true, "clears prior dualSourceEnabledOverride");
    assert.equal(app.settings.dualSourceEnabled, true);
    assert.equal(localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY), "1");
    app.settings.miSession = {
      userId: "10086",
      cUserId: "c10086",
      passToken: "pt-secret",
      serviceToken: "st-secret",
      ssecurity: "ss-secret",
      region: "cn",
    };
    assert.equal(isDualSourceEnabled(app), true, "dual-source activates immediately once second platform session arrives");
  });

  it("verifies HA token via dual-source refresh when adding HA on top of connected Mi, rolling back on bad token", async () => {
    let failHa = true;
    const haFixture = JSON.parse(readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/ha_snapshot.json"), "utf8")) as {
      states?: unknown[];
    };
    const miDevices = [
      {
        id: "mi-d1",
        name: "客厅吸顶灯",
        roomId: "r1",
        roomName: "客厅",
        model: "yeelink.light.lamp1",
        isOnline: true,
        kind: {
          kind: "light" as const,
          entityId: "mi-d1",
          isOn: true,
          brightnessPercent: 80,
          colorTempKelvin: 4000,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
        },
      },
      {
        id: "mi-d2",
        name: "卧室台灯",
        roomId: "r2",
        roomName: "卧室",
        model: "yeelink.light.lamp2",
        isOnline: true,
        kind: {
          kind: "light" as const,
          entityId: "mi-d2",
          isOn: false,
          brightnessPercent: 50,
          colorTempKelvin: 3500,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
        },
      },
    ];
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedXiaomiDevices: miDevices,
    }));
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string) => {
          if (name === "ha_snapshot") {
            if (failHa) throw new Error("401 Unauthorized");
            return haFixture;
          }
          return null;
        },
      },
      configurable: true,
    });

    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    app.settings.miSession = {
      userId: "10086",
      cUserId: "c10086",
      passToken: "pt-secret",
      serviceToken: "st-secret",
      ssecurity: "ss-secret",
      region: "cn",
    };
    app.devices = miDevices;
    // Simulate a user who previously disabled dual-source in the current session.
    setHostDualSourceEnabled(app, false, { persist: true });
    assert.equal(isDualSourceEnabled(app), false);

    // Open onboarding with Mi connected and add Home Assistant as the second platform.
    app.activeSheet = "onboarding";
    app.render();
    await click('[data-onboarding-card="xiaomiCloud"]');
    await click("#btn-onboarding-add-second-platform");
    assert.ok(document.querySelector("#onboarding-ha-url"));

    typeInput("#onboarding-ha-url", "http://192.168.1.50:8123");
    typeInput("#onboarding-ha-token", "invalid-ha-token");
    await click("#btn-onboarding-connect-ha");
    await setImmediate();
    await setImmediate();

    assert.equal(document.querySelector("[data-onboarding-ha-verified]"), null, "bad token must not report HA connected");
    assert.match(el("[data-onboarding-ha-error]").textContent ?? "", /专属连接钥匙无效或已过期.*设备还未同步/);
    assert.equal(isDualSourceEnabled(app), false, "failed dual-source HA verify must keep dual-source disabled");
    assert.notEqual(localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY), "1");
    assert.equal(app.settings.haToken, "", "failed dual-source HA verify rolls back stored HA token");
    assert.equal(el<HTMLInputElement>("#onboarding-ha-url").value, "http://192.168.1.50:8123", "draft URL preserved");
    assert.equal(el<HTMLInputElement>("#onboarding-ha-token").value, "invalid-ha-token", "draft token preserved");

    // Retry with valid token: succeeds via dual-source refresh and persists dual-source with "1".
    failHa = false;
    typeInput("#onboarding-ha-token", "valid-ha-token");
    await click("#btn-onboarding-connect-ha");
    await setImmediate();
    await setImmediate();

    const verifiedText = el("[data-onboarding-ha-verified]").textContent ?? "";
    const haCount = app.dualSourceCoordinator?.getLastHASnapshot()?.home.devices.length ?? 0;
    assert.ok(haCount > 0, "dual-source coordinator received a real HA snapshot");
    assert.ok(verifiedText.includes(String(haCount)), "verified badge reports actual HA device count");
    assert.equal(isDualSourceEnabled(app), true, "dual-source enabled after verified HA snapshot");
    assert.equal(app.dualSourceEnabledOverride, true, "prior false override cleared via setHostDualSourceEnabled");
    assert.equal(localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY), "1");
  });

  it("resets HA connecting state when a stale verification resolves after sourceEpoch advances", async () => {
    const resolvers: Array<(value: unknown) => void> = [];
    const haFixture = JSON.parse(readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/ha_snapshot.json"), "utf8")) as unknown;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string) => {
          if (name === "ha_snapshot") {
            return await new Promise((resolve) => {
              resolvers.push(resolve);
            });
          }
          return null;
        },
      },
      configurable: true,
    });

    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();

    await click('[data-onboarding-card="homeAssistant"]');
    typeInput("#onboarding-ha-url", "http://192.168.1.50:8123");
    typeInput("#onboarding-ha-token", "valid-token");
    await click("#btn-onboarding-connect-ha");
    assert.equal(el<HTMLButtonElement>("#btn-onboarding-connect-ha").disabled, true);

    // Advance sourceEpoch so capturedToken.isCurrent() returns false when the promise settles.
    app.sourceEpoch.advance("source");
    assert.equal(resolvers.length, 1, "ha_snapshot request started");
    resolvers[0]!(haFixture);
    await setImmediate();
    await setImmediate();

    assert.equal(
      el<HTMLButtonElement>("#btn-onboarding-connect-ha").disabled,
      false,
      "button must not remain permanently disabled after stale verification settles",
    );
  });

  it("supports skip without forcing demo and restores prior mode when leaving demo home", async () => {
    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();

    await click("#btn-skip-onboarding");
    assert.equal(app.activeSheet, "none");
    assert.notEqual(app.settings.connectionMode, "demo");
    assert.match(el(".cc-footer-label").textContent ?? "", /还没连接家居平台/);

    app.openSettingsSheet("general");
    assert.match(el("#btn-reopen-onboarding").textContent ?? "", /继续初始设置/);

    await click("#btn-reopen-onboarding");
    await click('[data-onboarding-card="demo"]');
    await click("#btn-finish-onboarding");
    assert.equal(app.settings.connectionMode, "demo");

    // Leaving demo with no prior real platform returns to onboarding and exits demo mode.
    await click('[data-connection-action="leaveDemo"]');
    assert.equal(app.activeSheet, "onboarding");
    assert.notEqual(app.settings.connectionMode, "demo");

    // When a real platform existed before demo, leaving demo restores it directly.
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://homeassistant.local:8123";
    app.settings.haToken = "live-ha-token";
    app.settings.hasCompletedOnboarding = true;
    app.activeSheet = "onboarding";
    app.render();
    await click('[data-onboarding-card="demo"]');
    await click("#btn-finish-onboarding");
    assert.equal(app.settings.connectionMode, "demo");
    assert.equal(app.settings.preDemoConnectionMode, "homeAssistant");

    await click('[data-connection-action="leaveDemo"]');
    assert.equal(app.settings.connectionMode, "homeAssistant");
    assert.equal(app.activeSheet, "none");
  });

  it("silently migrates legacy Mi, HA, dual-source, demo, cached, and local-data installs without popping onboarding", async () => {
    const scenarios: Array<{ label: string; setup: () => void }> = [
      {
        label: "legacy Mi-only with cached devices (offline)",
        setup: () => localStorage.setItem(STORAGE_KEY, JSON.stringify({
          connectionMode: "xiaomiCloud",
          cachedXiaomiDevices: [{
            id: "d1", name: "客厅灯", roomId: "r1", roomName: "客厅", model: "yeelink.light.lamp1", isOnline: true,
            kind: { kind: "generic", readouts: [], summary: "在线" },
          }],
        })),
      },
      {
        label: "legacy HA-only without explicit hasCompletedOnboarding",
        setup: () => localStorage.setItem(STORAGE_KEY, JSON.stringify({
          haBaseURL: "http://192.168.1.9:8123",
          haToken: "legacy-ha-token",
        })),
      },
      {
        label: "legacy dual-source",
        setup: () => localStorage.setItem(STORAGE_KEY, JSON.stringify({
          connectionMode: "xiaomiCloud",
          dualSourceEnabled: true,
          haBaseURL: "http://192.168.1.9:8123",
        })),
      },
      {
        label: "legacy demo user without explicit hasCompletedOnboarding",
        setup: () => localStorage.setItem(STORAGE_KEY, JSON.stringify({
          connectionMode: "demo",
        })),
      },
      {
        label: "legacy auxiliary local data (scheduled commands only)",
        setup: () => localStorage.setItem(SCHEDULED_COMMANDS_STORAGE_KEY, JSON.stringify([{ id: "t1" }])),
      },
      {
        label: "legacy auxiliary local data (mi capability storage only)",
        setup: () => localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify({
          schemaVersion: 1,
          migrationComplete: true,
          disabledMiAccountIds: [],
        })),
      },
    ];

    for (const scenario of scenarios) {
      localStorage.clear();
      scenario.setup();
      const app = new MenuMijiaWindowsApp(el("#app"));
      await setImmediate();
      assert.equal(app.activeSheet, "none", `${scenario.label}: must not pop onboarding`);
      assert.equal(app.settings.hasCompletedOnboarding, true, `${scenario.label}: marks onboarding complete`);
      const state = resolveHostMiSelectionState(app);
      assert.ok(state.mode === "legacyPreserved" || state.mode === "explicit", `${scenario.label}: migrated cleanly`);
      assert.equal(state.selection.enabledCategories.length, 14, `${scenario.label}: preserves all device categories`);
      assert.equal(readStoredMigrationComplete(), true, `${scenario.label}: seals migrationComplete`);
    }
  });

  it("fails closed when auxiliary localStorage reads throw in detectPersistedLocalData", () => {
    const originalGetItem = localStorage.getItem.bind(localStorage);
    Object.defineProperty(localStorage, "getItem", {
      value: () => {
        throw new Error("storage locked");
      },
      configurable: true,
      writable: true,
    });
    try {
      assert.equal(detectPersistedLocalData(), true, "unreadable auxiliary localStorage must fail closed as persisted data");
    } finally {
      Object.defineProperty(localStorage, "getItem", {
        value: originalGetItem,
        configurable: true,
        writable: true,
      });
    }
  });

  it("quarantines unreadable settings payload before overwriting on saveSettings", async () => {
    localStorage.setItem(STORAGE_KEY, "{not-valid-json");
    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    assert.equal(localStorage.getItem(STORAGE_KEY), "{not-valid-json");

    // Any subsequent saveSettings() backs up the corrupt payload to .unreadable before writing.
    app.saveSettings();
    assert.equal(localStorage.getItem(`${STORAGE_KEY}.unreadable`), "{not-valid-json");
    assert.doesNotThrow(() => JSON.parse(localStorage.getItem(STORAGE_KEY) ?? ""));

    // A second corrupt payload increments the suffix without clobbering the first backup.
    localStorage.setItem(STORAGE_KEY, "still-broken");
    app.saveSettings();
    assert.equal(localStorage.getItem(`${STORAGE_KEY}.unreadable`), "{not-valid-json");
    assert.equal(localStorage.getItem(`${STORAGE_KEY}.unreadable.1`), "still-broken");
  });

  it("surfaces identityMigrationDiagnostic in connectionStatus with trilingual retry action and seals on retry", async () => {
    // 1. Corrupt settings JSON
    localStorage.setItem(STORAGE_KEY, "{not-valid-json");
    const corruptApp = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    assert.equal(corruptApp.activeSheet, "none", "corrupt settings must not pop onboarding");
    assert.equal(corruptApp.identityMigrationDiagnostic, "corrupt_settings_storage");
    assert.equal(readStoredMigrationComplete(), null, "must not seal migrationComplete while settings are unreadable");
    assert.equal(localStorage.getItem(STORAGE_KEY), "{not-valid-json", "must not overwrite unreadable settings payload");
    assert.match(el(".cc-footer-label").textContent ?? "", /本机配置读取失败，可重试/);
    assert.equal(el("#btn-connection-action").dataset.connectionAction, "retryIdentity");

    // Once storage is repaired, clicking the retry action invokes retryIdentityMigration(), clears diagnostic, and seals migration.
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "homeAssistant",
      haBaseURL: "http://homeassistant.local:8123",
      haToken: "repaired-token",
    }));
    await click("#btn-connection-action");
    await setImmediate();
    assert.equal(corruptApp.identityMigrationDiagnostic, null);
    assert.equal(readStoredMigrationComplete(), true);

    // 2. Credential vault read failure (uncertain identity even with empty localStorage)
    localStorage.clear();
    let failVault = true;
    const miSessionPayload = serializeMiSession({
      userId: "10086",
      cUserId: "c10086",
      passToken: "pt-secret",
      serviceToken: "st-secret",
      ssecurity: "ss-secret",
      region: "cn",
    });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string, args: Record<string, unknown> = {}) => {
          if (name === "secure_store_get") {
            if (failVault) throw new Error("Windows Credential Manager locked");
            if (args.name === "mi_session") return miSessionPayload;
          }
          return null;
        },
      },
      configurable: true,
    });

    const vaultApp = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    await setImmediate();
    assert.equal(vaultApp.activeSheet, "none", "vault failure must fall back without popping onboarding");
    assert.equal(vaultApp.identityMigrationDiagnostic, "credential_vault_read_failed");
    assert.equal(readStoredMigrationComplete(), null, "must not seal migrationComplete on vault failure");

    // Verify trilingual footer copy & retryIdentity action.
    assert.equal(resolveConnectionStatus(vaultApp).text, "凭据读取失败，可重试");
    assert.equal(resolveConnectionStatus(vaultApp).action?.kind, "retryIdentity");
    assert.equal(resolveConnectionStatus(vaultApp).action?.label, "重试读取");
    vaultApp.settings.interfaceLanguage = "zh-Hant";
    assert.equal(resolveConnectionStatus(vaultApp).text, "憑據讀取失敗，可重試");
    assert.equal(resolveConnectionStatus(vaultApp).action?.label, "重試讀取");
    vaultApp.settings.interfaceLanguage = "en";
    assert.equal(resolveConnectionStatus(vaultApp).text, "Could not read credentials; retry");
    assert.equal(resolveConnectionStatus(vaultApp).action?.label, "Retry");
    vaultApp.settings.interfaceLanguage = "zh-Hans";
    vaultApp.render();
    assert.match(el(".cc-footer-label").textContent ?? "", /凭据读取失败，可重试/);

    failVault = false;
    await click("#btn-connection-action");
    await setImmediate();
    await setImmediate();
    assert.equal(vaultApp.identityMigrationDiagnostic, null);
    assert.equal(vaultApp.settings.miSession?.userId, "10086");
    assert.equal(readStoredMigrationComplete(), true);
    assert.doesNotMatch(el(".cc-footer-label").textContent ?? "", /凭据读取失败/);
  });
});

