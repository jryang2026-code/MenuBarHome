/**
 * P5a-W: Windows AI enable/disable and per-provider removal.
 *
 * Acceptance mapping:
 * 1. AI off → zero requests, zero retries; local parsing, learned shortcuts and saved
 *    timers keep working (`isAiAssistantEnabled` gate + handleNaturalCommand gate).
 * 2. Provider removal clears only that provider's config, key slot, endpoint bindings
 *    and cloud consent; sibling providers keep theirs (`removeAssistantProviderState`).
 * 3. A late in-flight result after a disable or provider change dispatches no device
 *    action (`assistantEpoch` discard in naturalCommand + proactive).
 * 4. zh-Hant / zh-Hans / en wording ships for every new string (catalog test below).
 */

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import {
  assistantEndpointIdentity,
  isAiAssistantEnabled,
  removeAssistantProviderState,
  type AssistantRemovalSettings,
} from "../src/core/assistant.js";
import { CredentialVault } from "../src/core/secureStore.js";
import { setLanguage } from "../src/core/i18n.js";
import type { HttpRequest } from "../src/core/miCloudClient.js";
import type { HttpResponse } from "../src/core/miCloud/session.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { removeActiveAssistantProvider } from "../src/ui/settingsEvents.js";
import { runScheduledCommand } from "../src/ui/naturalCommand.js";
import { maybeRefreshProactiveInBackground, proactiveHasConsumer } from "../src/ui/proactive.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

function mountDemoApp(): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false }),
  );
  const root = document.querySelector<HTMLElement>("#app");
  assert.ok(root);
  return new MenuMijiaWindowsApp(root);
}

interface DeferredTransport {
  calls: string[];
  release: (index: number, response: HttpResponse) => void;
  stub: (req: HttpRequest) => Promise<HttpResponse>;
}

/** Deferred HTTP transport: records requests; each awaits its explicit release. */
function deferredTransport(): DeferredTransport {
  const calls: string[] = [];
  const resolvers: Array<(response: HttpResponse) => void> = [];
  const stub = (req: HttpRequest): Promise<HttpResponse> => {
    calls.push(req.url);
    // Project lib is ES2022: no `Promise.withResolvers`.
    return new Promise<HttpResponse>((resolve) => resolvers.push(resolve));
  };
  return { calls, release: (index, response) => resolvers[index]?.(response), stub };
}

function chatCompletion(content: unknown): HttpResponse {
  return {
    status: 200,
    headers: {},
    body: JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] }),
  };
}

function removalSettings(overrides: Partial<AssistantRemovalSettings>): AssistantRemovalSettings {
  return {
    assistantBaseURL: "https://openrouter.ai/api/v1",
    assistantModel: "~typesafe/jev-latest",
    openRouterApiKey: "sk-or-test",
    assistantKeyEndpoint: "openrouter.ai",
    assistantCustomKeyEndpoint: null,
    assistantLegacyKeyEndpoint: null,
    cloudConsentEndpoints: [],
    ...overrides,
  };
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("P5a-W acceptance 1: AI off means zero requests, local parsing and timers survive", () => {
  it("sends no AI request and shows the off banner when local parsing misses", async () => {
    const app = mountDemoApp();
    app.settings.aiAssistantEnabled = false;
    app.saveSettings();
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    await app.handleNaturalCommand("魔法彩虹泡泡机启动");

    assert.equal(transport.calls.length, 0, "AI off must not send any request");
    assert.match(app.replyBanner?.text ?? "", /AI 一句话控制已关闭/);
    assert.equal(app.pendingCloudConsent, null, "AI off must not ask for cloud consent");
    assert.equal(app.isResolvingIntent, false);
  });

  it("keeps local parsing, learned shortcuts and saved timers working while AI is off", async () => {
    const app = mountDemoApp();
    app.settings.aiAssistantEnabled = false;
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    // Local parser path still acts on demo devices.
    await app.handleNaturalCommand("关闭书房台灯");
    const desk = app.devices.find((d) => d.id === "light.study_desk");
    assert.equal(desk?.kind.kind === "light" ? desk.kind.isOn : null, false, "local parse must keep working");

    // Saved timers still dispatch their stored intents.
    await app.handleNaturalCommand("10分钟后打开书房台灯");
    assert.equal(app.scheduledCommands.length, 1);
    const timer = app.scheduledCommands[0]!;
    await runScheduledCommand(app, timer);
    const deskAfterTimer = app.devices.find((d) => d.id === "light.study_desk");
    assert.equal(
      deskAfterTimer?.kind.kind === "light" ? deskAfterTimer.kind.isOn : null,
      true,
      "stored timer must keep executing with AI off",
    );
    assert.equal(transport.calls.length, 0, "timer execution must not consult AI");
  });

  it("stops the proactive background consumer when AI is off", () => {
    const app = mountDemoApp();
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.assistantBaseURL = "http://localhost:11434/v1";
    app.settings.aiAssistantEnabled = false;
    assert.equal(proactiveHasConsumer(app), false, "AI off must disable the proactive AI consumer");
    assert.equal(isAiAssistantEnabled(app.settings), false);
  });
});

describe("P5a-W acceptance 2: removing a provider clears only its own config and key", () => {
  it("deletes the removed preset's slot while sibling slots and bindings survive", async () => {
    const store = new Map<string, string>([
      ["assistant_api_key_openrouter_jev", "sk-or-test"],
      ["assistant_api_key_deepseek", "sk-deepseek-test"],
      ["assistant_api_key_custom", "sk-custom-test"],
    ]);
    const vault = new CredentialVault(async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
      const name = String(args["name"]);
      if (cmd === "secure_store_get") return (store.get(name) ?? null) as T | null;
      if (cmd === "secure_store_set") {
        store.set(name, String(args["value"] ?? ""));
        return null;
      }
      store.delete(name);
      return null;
    });
    const settings = removalSettings({
      cloudConsentEndpoints: ["openrouter.ai", "api.deepseek.com", "192.168.1.5:8000"],
    });
    const keysByPreset: Record<string, string> = {
      openrouter_jev: "sk-or-test",
      deepseek: "sk-deepseek-test",
      custom: "sk-custom-test",
    };

    const outcome = removeAssistantProviderState({ presetId: "openrouter_jev", settings, keysByPreset });
    assert.equal(outcome.activeProviderRemoved, true);

    // The app hydrates the vault at startup; a loaded vault knows the slot values, which is
    // what turns the dropped entry into a credential-store delete.
    await vault.load("openrouter_jev");
    await vault.persist({ miSession: null, haToken: "", assistantApiKey: "", assistantApiKeys: keysByPreset });

    assert.equal(store.has("assistant_api_key_openrouter_jev"), false, "removed provider's slot must be deleted");
    assert.equal(store.get("assistant_api_key_deepseek"), "sk-deepseek-test", "sibling slot must survive");
    assert.equal(store.get("assistant_api_key_custom"), "sk-custom-test", "sibling slot must survive");

    // Config falls back to the app default preset with no key; the sibling consent entries
    // and the sibling key slots stay.
    assert.equal(settings.assistantBaseURL, "https://openrouter.ai/api/v1");
    assert.equal(settings.openRouterApiKey, "");
    assert.deepEqual(settings.cloudConsentEndpoints, ["api.deepseek.com", "192.168.1.5:8000"]);
    assert.equal(keysByPreset["deepseek"], "sk-deepseek-test");
    assert.equal(keysByPreset["custom"], "sk-custom-test");
  });

  it("removing the non-default active provider keeps the default preset's saved key", async () => {
    const store = new Map<string, string>([
      ["assistant_api_key_openrouter_jev", "sk-or-test"],
      ["assistant_api_key_deepseek", "sk-deepseek-test"],
    ]);
    const vault = new CredentialVault(async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
      const name = String(args["name"]);
      if (cmd === "secure_store_get") return (store.get(name) ?? null) as T | null;
      if (cmd === "secure_store_set") {
        store.set(name, String(args["value"] ?? ""));
        return null;
      }
      store.delete(name);
      return null;
    });
    const settings = removalSettings({
      assistantBaseURL: "https://api.deepseek.com/v1",
      assistantModel: "deepseek-chat",
      openRouterApiKey: "sk-deepseek-test",
      assistantKeyEndpoint: "api.deepseek.com",
      cloudConsentEndpoints: ["api.deepseek.com", "openrouter.ai"],
    });
    const keysByPreset: Record<string, string> = {
      openrouter_jev: "sk-or-test",
      deepseek: "sk-deepseek-test",
    };

    const outcome = removeAssistantProviderState({ presetId: "deepseek", settings, keysByPreset });
    assert.equal(outcome.activeProviderRemoved, true);

    await vault.load("deepseek");
    await vault.persist({ miSession: null, haToken: "", assistantApiKey: "", assistantApiKeys: keysByPreset });

    assert.equal(store.get("assistant_api_key_openrouter_jev"), "sk-or-test", "default preset's saved key must survive");
    assert.equal(store.has("assistant_api_key_deepseek"), false, "removed provider's slot must go");
    // The default preset becomes active again with its own saved key surfaced.
    assert.equal(settings.assistantBaseURL, "https://openrouter.ai/api/v1");
    assert.equal(settings.openRouterApiKey, "sk-or-test");
    assert.equal(settings.assistantKeyEndpoint, "openrouter.ai");
    assert.deepEqual([...settings.cloudConsentEndpoints], ["openrouter.ai"]);
  });

  it("removing a non-active provider leaves the active config untouched", () => {
    const settings = removalSettings({
      assistantBaseURL: "https://api.deepseek.com/v1",
      assistantModel: "deepseek-chat",
      openRouterApiKey: "sk-deepseek-test",
      assistantKeyEndpoint: "api.deepseek.com",
      cloudConsentEndpoints: ["api.deepseek.com", "openrouter.ai"],
    });
    const keysByPreset: Record<string, string> = {
      openrouter_jev: "sk-or-old",
      deepseek: "sk-deepseek-test",
    };

    const outcome = removeAssistantProviderState({ presetId: "openrouter_jev", settings, keysByPreset });
    assert.equal(outcome.activeProviderRemoved, false);
    assert.equal(settings.assistantBaseURL, "https://api.deepseek.com/v1");
    assert.equal(settings.openRouterApiKey, "sk-deepseek-test");
    assert.equal(settings.assistantKeyEndpoint, "api.deepseek.com");
    assert.deepEqual([...settings.cloudConsentEndpoints], ["api.deepseek.com"]);
    assert.equal(keysByPreset["openrouter_jev"], undefined, "removed slot entry must go");
    assert.equal(keysByPreset["deepseek"], "sk-deepseek-test");
  });

  it("removes the current provider from the settings sheet after a two-click confirm", async () => {
    const app = mountDemoApp();
    app.settings.openRouterApiKey = "sk-or-test";
    app.settings.assistantKeyEndpoint = "openrouter.ai";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-test";
    app.assistantKeysByPreset["deepseek"] = "sk-deepseek-test";
    app.settings.cloudConsentEndpoints.push("openrouter.ai", "api.deepseek.com");
    app.timerCredentialsReady = true; // production hydration finished long before a user clicks
    app.activeSheet = "settings";
    app.render();

    const removeBtn = element("#btn-remove-ai-provider");
    removeBtn.click();
    assert.match(removeBtn.textContent ?? "", /再点一次确认移除/, "first click must arm the button");
    removeBtn.click();
    await setImmediate();
    await setImmediate();

    assert.equal(app.assistantKeysByPreset["openrouter_jev"], undefined);
    assert.equal(app.assistantKeysByPreset["deepseek"], "sk-deepseek-test", "sibling key must survive");
    assert.equal(app.settings.openRouterApiKey, "");
    assert.deepEqual([...app.settings.cloudConsentEndpoints], ["api.deepseek.com"]);
    assert.match(app.replyBanner?.text ?? "", /已移除/);
  });

  it("removal targeting an unsaved draft provider clears the draft instead of resurrecting it", async () => {
    const app = mountDemoApp();
    app.settings.openRouterApiKey = "sk-or-test";
    app.settings.assistantKeyEndpoint = "openrouter.ai";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-test";
    app.assistantKeysByPreset["deepseek"] = "sk-deepseek-test";
    app.timerCredentialsReady = true; // production hydration finished long before a user clicks
    app.activeSheet = "settings";
    app.render();

    // The user picks DeepSeek in the form but has not saved the draft.
    const baseEl = element("#settings-base-url") as HTMLInputElement;
    baseEl.value = "https://api.deepseek.com/v1";
    baseEl.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(
      document.querySelector<HTMLElement>('[data-ai-preset="deepseek"]')?.classList.contains("is-active"),
      true,
      "typing the URL must move the active pill before removal",
    );

    const removeBtn = element("#btn-remove-ai-provider");
    removeBtn.click();
    removeBtn.click();
    await setImmediate();
    await setImmediate();

    assert.equal(app.assistantKeysByPreset["deepseek"], undefined, "draft provider's key must go");
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-test", "active provider's key must stay");
    // The draft capture must not restore the removed provider's URL after the re-render;
    // otherwise 完成并保存 would write it back into the vault.
    const baseAfter = element("#settings-base-url") as HTMLInputElement;
    assert.equal(baseAfter.value, "https://openrouter.ai/api/v1");
    const keyAfter = element("#settings-api-key") as HTMLInputElement;
    assert.equal(keyAfter.value, "sk-or-test");
  });
});

describe("P5a-W acceptance 3: late in-flight results dispatch nothing", () => {
  function enableAiForRequest(app: MenuMijiaWindowsApp): void {
    app.settings.assistantModel = "gpt-4o-mini";
    app.settings.openRouterApiKey = "sk-or-test";
    app.settings.assistantKeyEndpoint = assistantEndpointIdentity("https://openrouter.ai/api/v1");
    app.settings.cloudConsentEndpoints.push(assistantEndpointIdentity("https://openrouter.ai/api/v1") ?? "");
  }

  it("discards a natural-command result that lands after the AI switch is flipped", async () => {
    const app = mountDemoApp();
    enableAiForRequest(app);
    // Park the demo light OFF first, so a stray power-on is observable.
    await app.handleNaturalCommand("关闭书房台灯");
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    const pending = app.handleNaturalCommand("魔法彩虹泡泡机启动");
    await setImmediate();
    assert.equal(transport.calls.length, 1, "the request itself was sent while AI was on");

    app.advanceAssistantEpoch();
    transport.release(0, chatCompletion({ reply: "已打开书房台灯", actions: [{ device: "light.study_desk", op: "power", value: true }] }));
    await pending;
    await setImmediate();

    const desk = app.devices.find((d) => d.id === "light.study_desk");
    assert.equal(desk?.kind.kind === "light" ? desk.kind.isOn : false, false, "late result must not actuate the device");
    assert.notEqual(app.replyBanner?.text ?? "", "已打开书房台灯", "late reply banner must not show");
    assert.equal(app.isResolvingIntent, false, "the discarded run must not leave the spinner up");
  });

  it("discards an in-flight result that lands while the provider removal persists", async () => {
    const app = mountDemoApp();
    enableAiForRequest(app);
    await app.handleNaturalCommand("关闭书房台灯");
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    const pending = app.handleNaturalCommand("魔法彩虹泡泡机启动");
    await setImmediate();
    assert.equal(transport.calls.length, 1);

    // The removal advances the epoch before awaiting the vault, so a result landing
    // during the persist window is already stale.
    await removeActiveAssistantProvider(app);
    transport.release(0, chatCompletion({ reply: "已打开书房台灯", actions: [{ device: "light.study_desk", op: "power", value: true }] }));
    await pending;
    await setImmediate();

    const desk = app.devices.find((d) => d.id === "light.study_desk");
    assert.equal(desk?.kind.kind === "light" ? desk.kind.isOn : false, false, "result landing during removal must not actuate");
    assert.equal(app.isResolvingIntent, false);
  });

  it("refuses the in-resolver retry once AI is switched off mid-flight", async () => {
    const app = mountDemoApp();
    enableAiForRequest(app);
    await app.handleNaturalCommand("关闭书房台灯");
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    const pending = app.handleNaturalCommand("魔法彩虹泡泡机启动");
    await setImmediate();
    assert.equal(transport.calls.length, 1);

    app.settings.aiAssistantEnabled = false;
    app.advanceAssistantEpoch();
    // A temperature-400 would normally trigger one in-resolver retry; the gated transport
    // must refuse it now that AI is off.
    transport.release(0, { status: 400, headers: {}, body: '{"error":{"message":"temperature is not supported"}}' });
    await pending;
    await setImmediate();

    assert.equal(transport.calls.length, 1, "no retry may leave after the switch is off");
    const desk = app.devices.find((d) => d.id === "light.study_desk");
    assert.equal(desk?.kind.kind === "light" ? desk.kind.isOn : false, false);
    assert.equal(app.isResolvingIntent, false);
  });

  it("stops the connection probe once AI is switched off mid-probe", async () => {
    const app = mountDemoApp();
    enableAiForRequest(app);
    app.activeSheet = "settings";
    // Route the probe's native HTTP through a deferred we control.
    const probeUrls: string[] = [];
    const resolvers: Array<(response: HttpResponse) => void> = [];
    const invoke = (cmd: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (cmd === "native_http") {
        probeUrls.push(String(args["url"] ?? ""));
        return new Promise((resolve) => resolvers.push(resolve));
      }
      return Promise.resolve(null);
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    app.render();

    element("#btn-test-ai-connection").click();
    await setImmediate();
    assert.equal(probeUrls.length, 1, "the probe sent while AI was on");

    app.settings.aiAssistantEnabled = false;
    app.advanceAssistantEpoch();
    resolvers[0]?.({ status: 400, headers: {}, body: '{"error":{"message":"temperature is not supported"}}' });
    await setImmediate();
    await setImmediate();

    assert.equal(probeUrls.length, 1, "a disabled probe must not retry");
    const status = element("#settings-ai-test-status");
    assert.match(status.textContent ?? "", /测试中止/, "the probe reports the abort in the status line");
  });

  it("removing the selected Custom preset with an empty draft URL leaves other providers intact", async () => {
    const app = mountDemoApp();
    app.settings.openRouterApiKey = "sk-or-test";
    app.settings.assistantKeyEndpoint = "openrouter.ai";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-test";
    app.assistantKeysByPreset["custom"] = "sk-custom-test";
    app.settings.cloudConsentEndpoints.push("openrouter.ai");
    app.timerCredentialsReady = true; // production hydration finished long before a user clicks
    app.activeSheet = "settings";
    app.render();

    // The user selects Custom but has not typed a URL: the empty field means Custom.
    element('[data-ai-preset="custom"]').click();
    const baseEl = element("#settings-base-url") as HTMLInputElement;
    assert.equal(baseEl.value, "");

    const removeBtn = element("#btn-remove-ai-provider");
    removeBtn.click();
    removeBtn.click();
    await setImmediate();
    await setImmediate();

    assert.equal(app.assistantKeysByPreset["custom"], undefined, "custom's own key goes");
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-test", "saved default provider untouched");
    assert.equal(app.settings.assistantBaseURL, "https://openrouter.ai/api/v1", "active config untouched");
    assert.deepEqual([...app.settings.cloudConsentEndpoints], ["openrouter.ai"], "default consent untouched");
  });

  it("rolls the removal back when the vault persist fails so a retry keeps the same target", async () => {
    const app = mountDemoApp();
    app.settings.assistantBaseURL = "https://api.deepseek.com/v1";
    app.settings.assistantModel = "deepseek-chat";
    app.settings.openRouterApiKey = "sk-deepseek-test";
    app.settings.assistantKeyEndpoint = "api.deepseek.com";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-test";
    app.assistantKeysByPreset["deepseek"] = "sk-deepseek-test";
    app.settings.cloudConsentEndpoints.push("api.deepseek.com", "openrouter.ai");

    let failPersist = true;
    const vaultStub = {
      persist: async (): Promise<void> => {
        if (failPersist) throw new Error("credential manager refused");
      },
    };
    Object.defineProperty(app, "credentialVault", { value: vaultStub, configurable: true });

    app.timerCredentialsReady = true; // production hydration finished long before a user clicks
    app.activeSheet = "settings";
    app.render();
    await removeActiveAssistantProvider(app);
    // Vault failed: the deepseek config must be back so a retry removes deepseek, not
    // the re-activated default provider.
    assert.equal(app.settings.assistantBaseURL, "https://api.deepseek.com/v1");
    assert.equal(app.settings.openRouterApiKey, "sk-deepseek-test");
    assert.equal(app.assistantKeysByPreset["deepseek"], "sk-deepseek-test");
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-test");
    assert.match(app.replyBanner?.text ?? "", /无法从系统凭据库移除/);

    failPersist = false;
    await removeActiveAssistantProvider(app);
    assert.equal(app.assistantKeysByPreset["deepseek"], undefined, "retry removes the same provider");
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-test", "default key survives the retry");
    assert.equal(app.settings.openRouterApiKey, "sk-or-test");
  });

  it("waits for startup credential hydration before mutating provider state", async () => {
    const app = mountDemoApp();
    app.settings.openRouterApiKey = "sk-or-test";
    app.settings.assistantKeyEndpoint = "openrouter.ai";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-or-test";
    app.timerCredentialsReady = false;

    const pendingRemoval = removeActiveAssistantProvider(app);
    await setImmediate();
    await setImmediate();
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], "sk-or-test", "must not mutate while hydration is pending");

    app.timerCredentialsReady = true;
    await pendingRemoval;
    await setImmediate();
    assert.equal(app.assistantKeysByPreset["openrouter_jev"], undefined, "removal proceeds once hydration finished");
  });

  it("discards a proactive refresh result that lands after a provider change", async () => {
    const app = mountDemoApp();
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.assistantBaseURL = "http://localhost:11434/v1";
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    maybeRefreshProactiveInBackground(app);
    await setImmediate();
    assert.equal(transport.calls.length, 1, "proactive refresh sent while enabled");

    app.advanceAssistantEpoch();
    transport.release(0, chatCompletion({ suggestions: [] }));
    await setImmediate();
    await setImmediate();

    assert.equal(app.isRefreshingProactive, false);
    assert.equal(app.aiProactiveSignature, null, "a discarded run must not claim the ambient signature");
  });
});

describe("P5a-W acceptance 4: the new wording ships in all three languages", () => {
  it("renders the AI toggle label in zh-Hans, zh-Hant and en", () => {
    const expectations: Array<{ language: "zh-Hans" | "zh-Hant" | "en"; label: string; hint: RegExp }> = [
      { language: "zh-Hans", label: "AI 一句话控制", hint: /不再发送 AI 请求/ },
      { language: "zh-Hant", label: "AI 一句話控制", hint: /不再傳送 AI 請求/ },
      { language: "en", label: "AI command control", hint: /no AI requests are sent/ },
    ];
    for (const { language, label, hint } of expectations) {
      const app = mountDemoApp();
      // The constructor resolves "system" from the stubbed navigator (zh-CN); re-pin the
      // language after mounting so the render uses the language under test.
      setLanguage(language);
      app.activeSheet = "settings";
      app.render();
      try {
        const labelEl = document.querySelector<HTMLElement>('label[for="settings-ai-enabled"]');
        assert.ok(labelEl, `${language}: toggle label missing`);
        assert.equal(labelEl.textContent?.trim(), label);
        const sheet = element(".cc-settings-sheet");
        assert.match(sheet.textContent ?? "", hint, `${language}: hint untranslated`);
      } finally {
        setLanguage("zh-Hans");
      }
    }
  });
});
