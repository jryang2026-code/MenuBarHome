import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { assertMissing } from "./dom.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  UserHabitMemory,
  forgetHabitItem,
  listReadableHabits,
  type HabitEntry,
  type HabitSequenceEntry,
} from "../src/core/assistant.js";
import { setLanguage } from "../src/core/i18n.js";
import type { HomeScene, SmartDevice } from "../src/core/models.js";
import {
  MI_SESSION_EXPIRED_STORAGE_KEY,
  persistMiSessionExpired,
} from "../src/core/pollingPolicy.js";
import { serializeMiSession } from "../src/core/secureStore.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { hasPendingMiVaultDeletion } from "../src/ui/speechGuard.js";
import {
  createInitialAssistantDraftState,
  importAmbientAssistantKey,
  resolveAssistantDraftForSave,
  selectAssistantPresetDraft,
  updateAssistantBaseURLDraft,
} from "../src/ui/onboardingGuide.js";
import { loadSettings, readAskWhenUnsure } from "../src/ui/settings.js";
import { probeAssistantConnection } from "../src/ui/settingsEvents.js";
import {
  SettingsSearchSelection,
  UNRESTRICTED_SETTINGS_AVAILABILITY,
  clearSettingsHighlight,
  searchSettings,
  settingsSearchEntries,
} from "../src/ui/settingsSearch.js";

let dom: Window;

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

function type(selector: string, value: string): void {
  const input = field(selector);
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function toggle(selector: string, checked: boolean): void {
  const input = field(selector);
  input.checked = checked;
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

async function waitFor(ready: () => boolean, message: string): Promise<void> {
  const deadline = performance.now() + 2000;
  while (!ready()) {
    if (performance.now() >= deadline) assert.fail(message);
    await setImmediate();
  }
}

function startDemoApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...extraSettings,
    }),
  );
  return new MenuMijiaWindowsApp(element("#app"));
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Wave 2 · A16 Settings Full-Text Anchor Search", () => {
  it("indexes 35+ anchors and attaches every reachable anchor in the rendered Settings DOM", async () => {
    startDemoApp({ cloudConsentEndpoints: ["openrouter.ai"] });
    await click("#btn-settings");

    const entries = settingsSearchEntries({
      hasCloudConsentEndpoints: true,
      hasAvailableUpdate: false,
    });
    assert.ok(entries.length >= 35, `expected >= 35 anchors, got ${entries.length}`);

    for (const entry of entries) {
      const target = document.querySelector(`[data-settings-anchor="${entry.anchor}"]`);
      assert.ok(target, `Anchor "${entry.anchor}" is missing [data-settings-anchor] in Settings DOM`);
    }
  });

  it("matches Chinese, Traditional Chinese, English, pinyin, and colloquial synonyms", () => {
    const cases: ReadonlyArray<readonly [string, string]> = [
      ["开机", "launchAtLogin"],
      ["自启", "launchAtLogin"],
      ["startup", "launchAtLogin"],
      ["kaiji", "launchAtLogin"],
      ["密钥", "assistantAPIKey"],
      ["token", "haToken"],
      ["key", "assistantAPIKey"],
      ["全关", "allOffDevices"],
      ["all off", "allOffDevices"],
      ["语音", "voiceControl"],
      ["mic", "voiceControl"],
      ["锁屏", "blockControlWhileLocked"],
      ["lock", "blockControlWhileLocked"],
      ["代理", "assistantBaseURL"],
      ["url", "haServerAddress"],
      ["习惯", "habitMemory"],
      ["habit", "habitMemory"],
      ["更新", "softwareUpdate"],
      ["update", "softwareUpdate"],
      ["新手引导", "setupGuide"],
      ["吊销", "signOut"],
    ];

    for (const [query, expectedAnchor] of cases) {
      const outcome = searchSettings(query, UNRESTRICTED_SETTINGS_AVAILABILITY);
      assert.ok(
        outcome.hits.some((hit) => hit.anchor === expectedAnchor),
        `Query "${query}" did not match expected anchor "${expectedAnchor}"; got [${outcome.hits.map((h) => h.anchor).join(", ")}]`,
      );
    }

    const updateWaiting = searchSettings("更新", {
      hasCloudConsentEndpoints: false,
      hasAvailableUpdate: true,
    });
    assert.equal(
      updateWaiting.hits.find((h) => h.anchor === "softwareUpdate")?.tab,
      "general",
    );

    const blockedConsent = searchSettings("撤销授权", {
      hasCloudConsentEndpoints: false,
      hasAvailableUpdate: false,
    });
    assert.equal(blockedConsent.hits.length, 0);
    assert.equal(blockedConsent.blocked?.anchor, "cloudConsent");
    assert.equal(blockedConsent.blocked?.reason, "noCloudConsent");
  });

  it("switches category tab, clears search occlusion, and highlights target row on click or Enter", async () => {
    const app = startDemoApp();
    await click("#btn-settings");
    assert.equal(app.settingsTab, "general");

    type("#settings-search-input", "锁屏");
    const resultsEl = element("#settings-search-results");
    assert.equal(resultsEl.hidden, false);
    assert.ok(resultsEl.querySelector('[data-settings-search-hit="blockControlWhileLocked"]'));

    await click('[data-settings-search-hit="blockControlWhileLocked"]');
    assert.equal(app.settingsTab, "system");
    assert.equal(element('[data-settings-panel="system"]').hidden, false);
    assert.equal(field("#settings-search-input").value, "");
    assert.equal(element("#settings-search-results").hidden, true);

    const highlighted = element('[data-settings-anchor="blockControlWhileLocked"]');
    assert.equal(highlighted.getAttribute("data-settings-highlighted"), "blockControlWhileLocked");
    assert.ok(highlighted.classList.contains("is-search-highlighted"));

    type("#settings-search-input", "habit");
    const input = field("#settings-search-input");
    input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    await setImmediate();

    assert.equal(app.settingsTab, "assistant");
    assert.equal(element("#settings-search-results").hidden, true);
    clearSettingsHighlight(app.root);

    assert.equal(SettingsSearchSelection.moved(null, 1, 3), 0);
    assert.equal(SettingsSearchSelection.moved(0, 1, 3), 1);
    assert.equal(SettingsSearchSelection.moved(2, 1, 3), 2);
    assert.equal(SettingsSearchSelection.commitIndex(null, 3), 0);
    assert.equal(SettingsSearchSelection.clamped(5, 2), 1);
  });
});

describe("Wave 2 · A16 Multi-Step Onboarding Guide & Custom Preset Latch", () => {
  it("preserves custom endpoint fields when typing a recognized host and never wipes saved provider keys", () => {
    const savedKeys: Record<string, string> = {
      "https://openrouter.ai/api/v1": "sk-or-precious",
      "http://localhost:11434/v1": "",
    };
    const lookupKey = (url: string) => savedKeys[url] ?? "";

    const initial = createInitialAssistantDraftState(
      "https://openrouter.ai/api/v1",
      "~typesafe/jev-latest",
      lookupKey,
    );
    assert.equal(initial.selectedPreset, "openrouter_jev");
    assert.equal(initial.showsCustomEndpointFields, false);
    assert.equal(initial.apiKey, "sk-or-precious");

    const customDraft = selectAssistantPresetDraft("custom", initial, lookupKey);
    assert.equal(customDraft.selectedPreset, "custom");
    assert.equal(customDraft.showsCustomEndpointFields, true);
    assert.equal(customDraft.baseURL, "");
    assert.equal(customDraft.model, "gpt-4o-mini");
    assert.equal(customDraft.apiKey, "");

    assert.equal(resolveAssistantDraftForSave(customDraft), null);

    const typedOllama = updateAssistantBaseURLDraft(
      "http://localhost:11434/v1",
      customDraft,
      lookupKey,
    );
    assert.equal(typedOllama.selectedPreset, "ollama");
    assert.equal(typedOllama.showsCustomEndpointFields, true, "latch must stay open while typing");
    assert.equal(typedOllama.model, "qwen2.5:7b");
  });

  it("supports Xiaomi QR / Home Assistant / Demo switching, launch-at-login, AI presets, and reopen from Settings", async () => {
    const invoked: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          invoked.push({ cmd, args });
          return undefined;
        },
      },
      configurable: true,
    });

    localStorage.setItem(STORAGE_KEY, JSON.stringify({}));
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-existing";
    app.settings.openRouterApiKey = "sk-or-existing";
    app.render();
    await setImmediate();

    assert.equal(app.activeSheet, "onboarding");
    assert.ok(document.querySelector(".cc-sheet"));
    assert.ok(document.querySelector(".cc-sheet-footer"));
    assertMissing(document.querySelector(".cc-settings-sheet"));
    assertMissing(document.querySelector(".cc-settings-top"));
    assertMissing(document.querySelector(".cc-sheet-body"));

    await click('[data-onboarding-mode="homeAssistant"]');
    app.devices = [
      {
        id: "light.old_home",
        name: "旧家台灯",
        roomId: "study",
        roomName: "书房",
        model: "ha.light",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "light.old_home",
          isOn: true,
          brightnessPercent: 80,
          colorTempKelvin: 4000,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
        },
      },
    ];
    app.refreshHADevices = async () => {};
    type("#onboarding-ha-url", "192.168.1.50:8123");
    type("#onboarding-ha-token", "ha-long-token");
    await click("#btn-onboarding-connect-ha");
    assert.equal(app.settings.connectionMode, "homeAssistant");
    assert.equal(app.settings.haBaseURL, "http://192.168.1.50:8123");
    assert.equal(app.settings.haToken, "ha-long-token");
    assert.equal(app.devices.length, 0, "connecting a new HA identity clears previous home rows");

    await click('[data-onboarding-mode="demo"]');
    assert.equal(app.settings.connectionMode, "demo");
    assert.ok(document.querySelector("[data-onboarding-demo-banner]"));

    toggle("#onboarding-launch-at-login", true);
    await setImmediate();
    assert.equal(app.settings.launchAtLogin, true);
    assert.ok(invoked.some((c) => c.cmd === "set_launch_at_login" && c.args?.enabled === true));

    await click('[data-onboarding-ai-preset="custom"]');
    assert.ok(document.querySelector("#onboarding-base-url"));
    assert.ok(document.querySelector("#onboarding-model"));

    await click("#btn-onboarding-save-ai");
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-existing");

    type("#onboarding-base-url", "http://localhost:11434/v1");
    assert.ok(document.querySelector("#onboarding-base-url"), "custom URL field stays mounted while typing");
    assert.equal(field("#onboarding-model").value, "qwen2.5:7b");

    await click("#btn-finish-onboarding");
    assert.equal(app.activeSheet, "none");
    assert.equal(app.settings.hasCompletedOnboarding, true);
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-existing");

    await click("#btn-settings");
    await click("#btn-reopen-onboarding");
    assert.equal(app.activeSheet, "onboarding");
    assert.ok(document.querySelector('[data-onboarding-step="1"]'));
  });
});

describe("Wave 2 · A16 Safety Guards (Unsaved Draft, Advanced Facets, Revoke All, Launch-at-Login Readback)", () => {
  it("prompts before closing Settings when unsaved draft edits exist, supporting keep, discard, and save", async () => {
    const app = startDemoApp();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    await click("#btn-close-settings");
    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);

    await click("#btn-cancel-close-settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, true);
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123");

    await click("#btn-close-settings");
    await click("#btn-discard-settings");
    assert.equal(app.activeSheet, "none");
    assert.equal(app.settings.haBaseURL, "");

    await click("#btn-settings");
    type("#settings-ha-url", "http://saved-on-close.local:8123");
    await click("#btn-close-settings");
    await click("#btn-confirm-save-settings");
    assert.equal(app.activeSheet, "none");
    assert.equal(app.settings.haBaseURL, "http://saved-on-close.local:8123");
  });

  it("requires destructive risk confirmation when enabling #settings-allow-advanced-facets", async () => {
    const app = startDemoApp();
    await click("#btn-settings");
    await click('[data-settings-tab="system"]');

    assert.equal(app.settings.allowAdvancedFacetWrites, false);
    toggle("#settings-allow-advanced-facets", true);
    await setImmediate();

    assert.equal(field("#settings-allow-advanced-facets").checked, false);
    assert.equal(app.settings.allowAdvancedFacetWrites, false);
    const confirmBox = element("#settings-advanced-facets-confirm");
    assert.equal(confirmBox.hidden, false);
    assert.match(confirmBox.textContent ?? "", /门锁|水阀|取暖/);

    await click("#btn-cancel-advanced-facets");
    assert.equal(confirmBox.hidden, true);
    assert.equal(app.settings.allowAdvancedFacetWrites, false);

    toggle("#settings-allow-advanced-facets", true);
    await click("#btn-confirm-advanced-facets");
    assert.equal(app.settings.allowAdvancedFacetWrites, true);
    assert.equal(field("#settings-allow-advanced-facets").checked, true);

    toggle("#settings-allow-advanced-facets", false);
    await setImmediate();
    assert.equal(app.settings.allowAdvancedFacetWrites, false);

    setLanguage("en");
    app.settings.interfaceLanguage = "en";
    app.render();
    toggle("#settings-allow-advanced-facets", true);
    assert.equal(element("#btn-cancel-advanced-facets").textContent?.trim(), "Cancel");
  });

  it("revokes all credentials, sessions, AI keys, and local bridge tokens after secondary confirmation", async () => {
    const deletedCredentials: string[] = [];
    let removedSnapshot = false;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "secure_store_delete" && typeof args?.name === "string") {
            deletedCredentials.push(args.name);
          }
          if (cmd === "remove_raycast_snapshot") {
            removedSnapshot = true;
          }
          return undefined;
        },
      },
      configurable: true,
    });

    const app = startDemoApp({
      connectionMode: "homeAssistant",
      haBaseURL: "https://ha.example.com",
      cloudConsentEndpoints: ["openrouter.ai", "api.deepseek.com"],
      enableRaycastIntegration: true,
    });
    const session = {
      userId: "88889999",
      cUserId: "c1",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok",
      passToken: "",
      region: "cn" as const,
    };
    app.settings.miSession = session;
    app.miSessionExpired = true;
    persistMiSessionExpired(session, true);
    assert.ok(localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY));
    app.expandedDeviceId = "demo_light_1";
    app.waitingDeviceIds.add("demo_light_1");
    app.unresolvedRoomDids.add("did_orphan");
    app.settings.haToken = "ha-secret";
    app.settings.openRouterApiKey = "sk-or-123";
    app.assistantKeysByPreset = {
      openrouter_jev: "sk-or-123",
      deepseek: "sk-ds-456",
      custom: "sk-custom-789",
    };

    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    const haUrlInput = element<HTMLInputElement>("#settings-ha-url");
    const haTokenInput = element<HTMLInputElement>("#settings-ha-token");
    haUrlInput.value = "http://192.168.1.99:8123";
    haTokenInput.value = "dirty-ha-token";
    await click('[data-settings-tab="assistant"]');
    const apiKeyInput = element<HTMLInputElement>("#settings-api-key");
    apiKeyInput.value = "dirty-sk-key";
    await click('[data-settings-tab="system"]');

    await click("#btn-revoke-all-credentials");
    assert.equal(element("#settings-revoke-all-confirm").hidden, false);

    await click("#btn-cancel-revoke-all");
    assert.equal(element("#settings-revoke-all-confirm").hidden, true);
    assert.equal(app.settings.haToken, "ha-secret");

    await click("#btn-revoke-all-credentials");
    await click("#btn-confirm-revoke-all");
    await waitFor(
      () =>
        deletedCredentials.includes("mi_session") &&
        deletedCredentials.includes("ha_token") &&
        !hasPendingMiVaultDeletion(),
      "Expected OS credential deletions",
    );

    assert.equal(element<HTMLInputElement>("#settings-ha-url").value, "");
    assert.equal(element<HTMLInputElement>("#settings-ha-token").value, "");
    assert.equal(element<HTMLInputElement>("#settings-api-key").value, "");
    await click("#btn-save-settings");
    assert.equal(app.settings.miSession, null);
    assert.equal(app.miSessionExpired, false);
    assert.equal(localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY), null);
    assert.equal(app.expandedDeviceId, null);
    assert.equal(app.waitingDeviceIds.size, 0);
    assert.equal(app.unresolvedRoomDids.size, 0);
    assert.equal(app.settings.haBaseURL, "");
    assert.equal(app.settings.haToken, "");
    assert.equal(app.settings.openRouterApiKey, "");
    assert.deepEqual(app.assistantKeysByPreset, {});
    assert.deepEqual(app.settings.cloudConsentEndpoints, []);
    assert.equal(app.settings.enableRaycastIntegration, false);
    assert.equal(app.settings.connectionMode, "demo");
    assert.equal(removedSnapshot, true);
    assert.equal(app.replyBanner?.isError ?? false, false);
    for (const preset of ASSISTANT_PROVIDER_PRESETS) {
      assert.ok(
        deletedCredentials.includes(`assistant_api_key_${preset.id}`),
        `Expected deletion of assistant_api_key_${preset.id}`,
      );
    }
  });

  it("surfaces error banner and keeps pending vault deletion guard when OS credential vault refuses deletion", async () => {
    let failDelete = true;
    const retainedVaultSession = serializeMiSession({
      userId: "99887766",
      cUserId: "",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok_retained_revoke",
      passToken: "",
      region: "cn",
    });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "secure_store_get" && args["name"] === "mi_session") {
            return failDelete ? retainedVaultSession : null;
          }
          if (cmd === "secure_store_delete" && args["name"] === "ha_token") {
            if (failDelete) throw new Error("Vault busy");
          }
          return null;
        },
      },
      configurable: true,
    });
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "xiaomiCloud", hasCompletedOnboarding: true }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    assert.ok(app.settings.miSession);
    app.settings.haToken = "ha-tok-fail";

    await click("#btn-settings");
    await click('[data-settings-tab="system"]');
    await click("#btn-revoke-all-credentials");
    await click("#btn-confirm-revoke-all");
    await waitFor(() => app.replyBanner?.isError === true, "Expected vault deletion error banner");

    assert.equal(app.settings.miSession, null);
    assert.equal(app.settings.haToken, "");
    assert.equal(hasPendingMiVaultDeletion(), true);
    assert.match(app.replyBanner?.text ?? "", /Vault busy/);

    document.body.innerHTML = '<div id="app"></div>';
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "xiaomiCloud", hasCompletedOnboarding: true }),
    );
    const restarted = new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    assert.equal(restarted.settings.miSession, null);

    failDelete = false;
    await click("#btn-settings");
    await click('[data-settings-tab="system"]');
    await click("#btn-revoke-all-credentials");
    await click("#btn-confirm-revoke-all");
    await waitFor(() => !hasPendingMiVaultDeletion(), "Expected pending vault deletion to clear");
    assert.equal(restarted.replyBanner?.isError ?? false, false);
  });

  it("reads back real launch-at-login state from Tauri on Settings open and falls back silently on error", async () => {
    let backendMode: "true" | "reject" = "true";
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "get_launch_at_login") {
            if (backendMode === "reject") throw new Error("Command get_launch_at_login not found");
            return true;
          }
          return undefined;
        },
      },
      configurable: true,
    });

    const app = startDemoApp({ launchAtLogin: false });
    await click("#btn-settings");
    await waitFor(() => field("#settings-launch-at-login").checked === true, "System launchAtLogin readback");
    assert.equal(app.settings.launchAtLogin, true);

    await click("#btn-close-settings");
    backendMode = "reject";
    await click("#btn-settings");
    await setImmediate();
    assert.equal(app.settings.launchAtLogin, true);
    assert.equal(app.replyBanner, null, "Unimplemented backend query must not raise an error banner");
  });
});

describe("Wave 2 · A9 AI Assistant Enhancements (askWhenUnsure, Connection Probe, Env Key Import)", () => {
  it("persists askWhenUnsure to settings.ts and reads it back on reload", async () => {
    const app = startDemoApp();
    assert.equal(readAskWhenUnsure(app.settings), true);

    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    assert.equal(field("#settings-ask-when-unsure").checked, true);

    toggle("#settings-ask-when-unsure", false);
    await setImmediate();
    assert.equal(readAskWhenUnsure(app.settings), false);

    const reloaded = loadSettings();
    assert.equal(readAskWhenUnsure(reloaded.settings), false);
  });

  it("probes the configured AI endpoint and reports latency in ms or concrete error reasons", async () => {
    const okResult = await probeAssistantConnection(
      {
        baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat",
        apiKey: "sk-valid",
      },
      async () => ({
        status: 200,
        headers: {},
        body: JSON.stringify({
          choices: [
            {
              message: {
                content: JSON.stringify({
                  actions: [{ device: "d0", op: "power", value: true }],
                  confidence: 0.95,
                }),
              },
            },
          ],
        }),
      }),
    );
    assert.equal(okResult.ok, true);
    assert.ok((okResult.latencyMs ?? 0) >= 1);
    assert.match(okResult.message, /DeepSeek.*ms/);

    const unauthResult = await probeAssistantConnection(
      {
        baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat",
        apiKey: "sk-bad",
      },
      async () => ({ status: 401, headers: {}, body: "Unauthorized" }),
    );
    assert.equal(unauthResult.ok, false);
    assert.match(unauthResult.message, /API Key 无效/);

    const missingKeyResult = await probeAssistantConnection({
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o-mini",
      apiKey: "",
    });
    assert.equal(missingKeyResult.ok, false);
    assert.match(missingKeyResult.message, /API Key/);

    const insecureResult = await probeAssistantConnection({
      baseURL: "http://api.openai.com/v1",
      model: "gpt-4o-mini",
      apiKey: "sk-plain",
    });
    assert.equal(insecureResult.ok, false);
    assert.match(insecureResult.message, /HTTPS/);

    const invokeOrder: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          invokeOrder.push({ cmd, args });
          if (cmd === "native_http") {
            return {
              status: 200,
              headers: {},
              body: JSON.stringify({
                choices: [
                  {
                    message: {
                      content: JSON.stringify({
                        actions: [{ device: "d0", op: "power", value: true }],
                        confidence: 0.95,
                      }),
                    },
                  },
                ],
              }),
            };
          }
          return undefined;
        },
      },
      configurable: true,
    });

    startDemoApp();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    await click('[data-ai-preset="deepseek"]');
    type("#settings-api-key", "sk-test-deepseek");
    invokeOrder.length = 0;
    await click("#btn-test-ai-connection");
    await waitFor(
      () => element("#settings-ai-test-status").dataset.testState === "ok",
      "Expected AI connection test status to settle to ok",
    );
    assert.match(element("#settings-ai-test-status").textContent ?? "", /DeepSeek.*ms/);
    const authIdx = invokeOrder.findIndex(
      (c) => c.cmd === "set_service_endpoints" && c.args?.assistantUrl === "https://api.deepseek.com/v1",
    );
    const httpIdx = invokeOrder.findIndex((c) => c.cmd === "native_http");
    assert.ok(authIdx >= 0 && authIdx < httpIdx, "Draft endpoint must be authorized before native_http probe");
  });

  it("imports provider API keys from environment variables", async () => {
    const hit = await importAmbientAssistantKey("deepseek", (name) =>
      name === "DEEPSEEK_API_KEY" ? "  sk-env-ds-999  " : undefined,
    );
    assert.deepEqual(hit, { envName: "DEEPSEEK_API_KEY", apiKey: "sk-env-ds-999" });

    const customHit = await importAmbientAssistantKey("custom", () => "sk-never");
    assert.equal(customHit, null);

    let holdEnvLookup = false;
    let releaseEnvLookup = (_val: string): void => {};
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "get_env_var" && args?.name === "OPENROUTER_API_KEY") {
            if (holdEnvLookup) {
              return new Promise<string>((resolve) => {
                releaseEnvLookup = resolve;
              });
            }
            return "sk-or-from-tauri-env";
          }
          return undefined;
        },
      },
      configurable: true,
    });

    startDemoApp();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    await click("#btn-import-env-key");
    await waitFor(
      () => field("#settings-api-key").value === "sk-or-from-tauri-env",
      "Expected API key input to receive imported env key",
    );
    assert.match(element("#settings-env-import-status").textContent ?? "", /OPENROUTER_API_KEY/);

    holdEnvLookup = true;
    await click("#btn-import-env-key");
    await click('[data-ai-preset="deepseek"]');
    type("#settings-api-key", "sk-deepseek-manual");
    releaseEnvLookup("sk-stale-openrouter-key");
    await setImmediate();
    await setImmediate();
    assert.equal(
      field("#settings-api-key").value,
      "sk-deepseek-manual",
      "Stale env lookup from previous provider must not overwrite the newly selected provider's key",
    );
  });
});

describe("Wave 2 · Habit Memory Per-Item Viewing & Single-Item Deletion", () => {
  const sampleDevices: readonly SmartDevice[] = [
    {
      id: "light.study_desk",
      name: "书房台灯",
      roomId: "study",
      roomName: "书房",
      model: "yeelink.light.lamp4",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "light.study_desk",
        isOn: false,
        brightnessPercent: 80,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    },
    {
      id: "climate.bedroom",
      name: "主卧空调",
      roomId: "bedroom",
      roomName: "主卧",
      model: "xiaomi.aircondition.mc5",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "climate.bedroom",
        isOn: false,
        currentTemperature: 27,
        targetTemperature: 25,
        minTemp: 16,
        maxTemp: 30,
        step: 1,
        hvacMode: "cool",
        availableModes: ["off", "cool", "heat"],
        fanMode: null,
        availableFanModes: [],
      },
    },
  ];
  const sampleScenes: readonly HomeScene[] = [];

  it("formats readable habits across zh-Hans, zh-Hant, and en and forgets individual entries/phrases/sequences", () => {
    const entries: HabitEntry[] = [
      {
        bucket: "夜晚",
        dayType: "weekday",
        targetId: "light.study_desk",
        operationKey: "power:on",
        count: 5,
      },
      {
        bucket: "午间",
        targetId: "climate.bedroom",
        operationKey: "temp:26",
        count: 2,
      },
    ];
    const sequences: HabitSequenceEntry[] = [
      {
        afterKey: "light.study_desk|power:on",
        targetId: "climate.bedroom",
        operationKey: "power:on",
        count: 3,
      },
    ];
    const phrases = [{ phrase: "准备看书", summary: "打开书房台灯", count: 4 }];

    const zhHansItems = listReadableHabits({
      entries,
      sequences,
      phrases,
      devices: sampleDevices,
      scenes: sampleScenes,
      lang: "zh-Hans",
    });
    assert.equal(zhHansItems.length, 4);
    assert.match(zhHansItems[0]!.text, /夜晚常做（工作日）：.*书房台灯.*5 次/);
    assert.match(zhHansItems[2]!.text, /口头禅「准备看书」/);
    assert.match(zhHansItems[3]!.text, /之后常做：.*主卧空调.*3 次/);

    const zhHantItems = listReadableHabits({
      entries,
      sequences,
      phrases,
      devices: sampleDevices,
      scenes: sampleScenes,
      lang: "zh-Hant",
    });
    assert.match(zhHantItems[1]!.text, /午間常做/);
    assert.match(zhHantItems[2]!.text, /口頭禪/);

    const enItems = listReadableHabits({
      entries,
      sequences,
      phrases,
      devices: sampleDevices,
      scenes: sampleScenes,
      lang: "en",
    });
    assert.match(enItems[0]!.text, /Evening \(Weekdays\): .*5x/);
    assert.match(enItems[3]!.text, /After ".*": .*3x/);

    const memory = new UserHabitMemory(entries, sequences);
    assert.equal(memory.readableItems(sampleDevices, sampleScenes).length, 3);
    assert.equal(memory.forget("e|夜晚|weekday|light.study_desk|power:on"), true);
    assert.equal(memory.entries.length, 1);
    assert.equal(memory.sequences.length, 1);

    const afterSeqForget = forgetHabitItem(
      { entries: memory.entries, sequences: memory.sequences, phrases },
      "s|light.study_desk|power:on|climate.bedroom|power:on",
    );
    assert.equal(afterSeqForget.removed, true);
    assert.equal(afterSeqForget.sequences.length, 0);
    assert.equal(afterSeqForget.entries.length, 1);

    const afterLegacyForget = forgetHabitItem(
      afterSeqForget,
      "e|午间|climate.bedroom|temp:26",
    );
    assert.equal(afterLegacyForget.removed, true);
    assert.equal(afterLegacyForget.entries.length, 0);
  });

  it("expands habit items in Settings and deletes a single habit without clearing others", async () => {
    localStorage.setItem(
      "menumijia.windows.habit.sequences.v1",
      JSON.stringify({
        sequences: [
          {
            afterKey: "light.study_desk|power:on",
            targetId: "light.living_ceiling",
            operationKey: "power:off",
            count: 2,
          },
        ],
        lastAction: null,
      }),
    );

    const app = startDemoApp({
      habitEntries: [
        {
          bucket: "夜晚",
          dayType: "weekday",
          targetId: "light.study_desk",
          operationKey: "power:on",
          count: 4,
        },
        {
          bucket: "清晨",
          dayType: "weekend",
          targetId: "light.living_ceiling",
          operationKey: "power:off",
          count: 2,
        },
      ],
    });

    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');

    const toggleBtn = element("#btn-toggle-habit-items");
    const listEl = element("#settings-habit-items-list");
    assert.equal(listEl.hidden, true);
    assert.equal(toggleBtn.getAttribute("aria-expanded"), "false");

    await click("#btn-toggle-habit-items");
    assert.equal(element("#settings-habit-items-list").hidden, false);
    assert.equal(element("#btn-toggle-habit-items").getAttribute("aria-expanded"), "true");
    assert.equal(document.querySelectorAll("[data-forget-habit-id]").length, 3);

    await click('[data-forget-habit-id="e|夜晚|weekday|light.study_desk|power:on"]');
    assert.equal(app.settings.habitEntries.length, 1);
    assert.equal(app.settings.habitEntries[0]?.targetId, "light.living_ceiling");
    assert.equal(app.habitSequences().length, 1, "sequence habit stays intact");
    assert.equal(element("#settings-habit-items-list").hidden, false, "list stays expanded after item delete");
    assert.equal(document.querySelectorAll("[data-forget-habit-id]").length, 2);

    await click('[data-forget-habit-id="s|light.study_desk|power:on|light.living_ceiling|power:off"]');
    assert.equal(app.habitSequences().length, 0);
    assert.equal(app.settings.habitEntries.length, 1);

    await click("#btn-clear-habits");
    assert.equal(app.settings.habitEntries.length, 0);
    assertMissing(document.querySelector("#btn-clear-habits"));
  });
});
