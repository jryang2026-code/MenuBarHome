import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { assertMissing } from "./dom.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { setLanguage } from "../src/core/i18n.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";

const SETTINGS_KEY = STORAGE_KEY;

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing control ${selector}`);
  return found;
}

function field(selector: string): HTMLInputElement {
  return element(selector) as HTMLInputElement;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

/** Types into a field the way a person does: value plus an input event. */
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

function panel(tab: string): HTMLElement {
  return element(`[data-settings-panel="${tab}"]`);
}

/** Waits on `ready`, but fails instead of hanging: an unreleased gate would block `afterEach`. */
async function waitFor(ready: () => boolean, message: string): Promise<void> {
  const deadline = performance.now() + 2000;
  while (!ready()) {
    if (performance.now() >= deadline) assert.fail(message);
    await setImmediate();
  }
}

function visibleTab(): string {
  const shown = [...document.querySelectorAll<HTMLElement>("[data-settings-panel]")]
    .filter((node) => !node.hidden)
    .map((node) => node.dataset.settingsPanel ?? "");
  assert.equal(shown.length, 1, `exactly one panel must be visible, saw ${shown.join(",")}`);
  return shown[0] as string;
}

function selectedTabs(): string[] {
  return [...document.querySelectorAll<HTMLElement>("[data-settings-tab]")]
    .filter((node) => node.getAttribute("aria-selected") === "true")
    .map((node) => node.dataset.settingsTab ?? "");
}

function startDemo(): MenuMijiaWindowsApp {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify({
    connectionMode: "demo",
    hasCompletedOnboarding: true,
  }));
  return new MenuMijiaWindowsApp(element("#app"));
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("Settings sheet three-zone layout (#78)", () => {
  it("keeps the update card on 外观与面板 when a release is waiting", async () => {
    const release = JSON.stringify({
      tag_name: "v1.2.3",
      html_url: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.2.3",
    });
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "native_http" && String(args["url"]).startsWith("https://api.github.com/")) {
        return { status: 200, headers: {}, body: release };
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.removeItem("menumijia.windows.update.v1");
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    await click("#btn-footer-update");
    assert.equal(visibleTab(), "general", "the footer update pill lands where the notice is");
    assert.match(panel("general").textContent ?? "", /发现新版本 v1\.2\.3/);
    assertMissing(panel("system").querySelector("#btn-open-update"));
  });

  it("moves the update card to 全关与更新 when no release is waiting", async () => {
    startDemo();
    await click("#btn-settings");
    assertMissing(panel("general").querySelector("#btn-check-update"));
    assert.ok(panel("system").querySelector("#btn-check-update"), "the manual check lives on the last tab");
  });
});

describe("Settings tab switching (#78)", () => {
  it("shows one panel at a time and marks the pressed tab", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    assert.equal(visibleTab(), "connection");
    assert.deepEqual(selectedTabs(), ["connection"]);
    assert.ok(element('[data-settings-tab="connection"]').classList.contains("is-active"));
    assert.ok(!element('[data-settings-tab="general"]').classList.contains("is-active"));
    assert.equal(panel("general").hidden, true);

    await click('[data-settings-tab="assistant"]');
    assert.equal(visibleTab(), "assistant");
    await click('[data-settings-tab="system"]');
    assert.equal(visibleTab(), "system");
    await click('[data-settings-tab="general"]');
    assert.equal(visibleTab(), "general");
    assert.deepEqual(selectedTabs(), ["general"]);
  });

  it("keeps a typed draft in the connection tab while another tab is open", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://draft.local:8123");
    type("#settings-ha-token", "draft-token");

    await click('[data-settings-tab="general"]');
    assert.equal(field("#settings-ha-url").value, "http://draft.local:8123", "the hidden panel keeps its own text");
    await click('[data-settings-tab="connection"]');
    assert.equal(field("#settings-ha-url").value, "http://draft.local:8123");
    assert.equal(field("#settings-ha-token").value, "draft-token");
  });

  it("keeps the chosen AI preset highlighted and key placeholder aligned after a live re-render", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    await click('[data-ai-preset="deepseek"]');

    app.render();
    await setImmediate();

    assert.equal(field("#settings-base-url").value, "https://api.deepseek.com/v1");
    assert.ok(element('[data-ai-preset="deepseek"]').classList.contains("is-active"));
    assert.ok(!element('[data-ai-preset="openrouter_jev"]').classList.contains("is-active"));
  });

  it("never leaks a newly hydrated provider key into a switched endpoint draft on re-render", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    assert.equal(field("#settings-api-key").value, "");

    // User switches to another endpoint before Credential Manager hydration finishes.
    type("#settings-base-url", "https://custom.example/v1");
    assert.equal(field("#settings-api-key").value, "");

    // Hydration now populates OpenRouter's saved key and triggers a render.
    app.settings.openRouterApiKey = "sk-openrouter-secret";
    app.settings.assistantKeyEndpoint = "openrouter.ai";
    app.assistantKeysByPreset["openrouter_jev"] = "sk-openrouter-secret";
    app.render();
    await setImmediate();

    assert.equal(field("#settings-base-url").value, "https://custom.example/v1");
    assert.equal(field("#settings-api-key").value, "", "OpenRouter's hydrated key must not stay in the custom endpoint draft");

    await click("#btn-save-settings");
    assert.equal(app.settings.assistantBaseURL, "https://custom.example/v1");
    assert.equal(app.settings.openRouterApiKey, "");
  });

  it("lets freshly hydrated credentials populate untouched fields on re-render", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    assert.equal(field("#settings-ha-token").value, "");

    // Simulate async credential-manager hydration arriving while Settings is already open.
    app.settings.haToken = "hydrated-secret-token";
    app.render();
    await setImmediate();

    assert.equal(field("#settings-ha-token").value, "hydrated-secret-token");
  });

  it("keeps a draft across a live re-render that does not come from the fields themselves", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    type("#settings-model", "draft-model-name");
    type("#settings-api-key", "sk-draft");

    // A background refresh rebuilds the panel the way a cloud poll does.
    app.render();
    await setImmediate();
    assert.equal(field("#settings-model").value, "draft-model-name", "a rebuild must not drop typed text");
    assert.equal(field("#settings-api-key").value, "sk-draft");
  });

  it("refreshes the habit share preview after a re-render that kept a sample draft", async () => {
    const hour = new Date().getHours();
    const bucket = hour >= 18 && hour < 23 ? "夜晚" : hour >= 14 && hour < 18 ? "下午" : hour >= 11 && hour < 14 ? "午间" : hour >= 6 && hour < 11 ? "清晨" : "深夜";
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      habitEntries: [{ bucket, targetId: "light.study_desk", operationKey: "power:off", count: 3 }],
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-settings");
    toggle("#settings-habit-share", true);
    type("#settings-habit-share-sample", "书房台灯");
    assert.match(element("#settings-habit-share-preview").textContent ?? "", /关闭书房台灯/);

    app.render();
    await setImmediate();
    assert.equal(field("#settings-habit-share-sample").value, "书房台灯");
    assert.match(
      element("#settings-habit-share-preview").textContent ?? "",
      /关闭书房台灯/,
      "the preview follows the restored draft instead of going blank",
    );
  });

  it("preserves the scroll offset of the scrolling body across a re-render", async () => {
    const app = startDemo();
    await click("#btn-settings");
    const body = element(".cc-sheet-body");
    body.scrollTop = 128;
    app.render();
    await setImmediate();
    assert.equal(element(".cc-sheet-body").scrollTop, 128, "a refresh must not send the reader back to the top");
  });

  it("resets the body scroll when the user picks another category", async () => {
    startDemo();
    await click("#btn-settings");
    element(".cc-sheet-body").scrollTop = 200;
    await click('[data-settings-tab="system"]');
    assert.equal(element(".cc-sheet-body").scrollTop, 0, "a new category starts at its top");
  });
});

describe("Settings category routing (#78)", () => {
  it("opens 数据源 from the empty-state settings button", async () => {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miCloudRegion: "de",
      cachedXiaomiDevices: [],
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-empty-settings");
    assert.equal(app.settingsTab, "connection");
    assert.equal(visibleTab(), "connection");
    assert.ok(panel("connection").querySelector("select[data-mi-region]"));
  });

  it("opens 数据源 from the footer QR pill", async () => {
    // Without a `native_http` stub the login transport falls back to `fetch` and polls
    // account.xiaomi.com for the whole ticket lifetime; the call is only allowed to fail here.
    const invoke = async (name: string): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      return { status: 500, headers: {}, body: "" };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    const app = startDemo();
    await click("#btn-footer-qr");
    assert.equal(app.activeSheet, "settings");
    assert.equal(app.settingsTab, "connection");
    assert.equal(visibleTab(), "connection");
    assert.match(app.qrStatusText, /扫码未完成/, "the failed request settles the sheet instead of polling");
  });

  it("opens 数据源 from an expired-session footer label", async () => {
    const invoke = async (name: string): Promise<unknown> => {
      if (name === "native_http") return { status: 401, headers: {}, body: "" };
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miSession: {
        userId: "12345678",
        cUserId: "",
        ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
        serviceToken: "expired-token",
        passToken: "",
        region: "cn",
      },
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    const deadline = performance.now() + 2000;
    while (!document.querySelector("#btn-footer-health")) {
      if (performance.now() >= deadline) assert.fail("the session never expired");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    await click("#btn-footer-health");
    assert.equal(app.settingsTab, "connection");
    assert.equal(visibleTab(), "connection");
  });

  it("sends the footer update pill to 全关与更新 when no release is waiting at click time", async () => {
    const release = JSON.stringify({
      tag_name: "v1.2.3",
      html_url: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.2.3",
    });
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "native_http" && String(args["url"]).startsWith("https://api.github.com/")) {
        return { status: 200, headers: {}, body: release };
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.removeItem("menumijia.windows.update.v1");
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    assert.ok(document.querySelector("#btn-footer-update"), "the pill is on screen");
    // The pill disappears on the next render once the notice retires; a click before that render
    // must not land on the general tab, which no longer holds the card.
    app.availableUpdate = null;
    await click("#btn-footer-update");
    assert.equal(app.settingsTab, "system");
    assert.equal(visibleTab(), "system");
    assert.ok(panel("system").querySelector("#btn-check-update"));
  });

  it("opens 外观与面板 from the settings gear", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="system"]');
    await click("#btn-close-settings");
    assert.equal(app.activeSheet, "none");
    await click("#btn-settings");
    assert.equal(app.settingsTab, "general");
    assert.equal(visibleTab(), "general");
  });
});

describe("Settings save across tabs (#78)", () => {
  it("saves inputs on an inactive tab", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://inactive.local:8123");
    type("#settings-ha-token", "inactive-token");

    // Save while another category is open: the fields are in the DOM but not visible.
    await click('[data-settings-tab="general"]');
    await click("#btn-save-settings");

    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? "{}") as {
      haBaseURL?: string;
      connectionMode?: string;
    };
    assert.equal(saved.haBaseURL, "http://inactive.local:8123");
  });

  it("saves the AI fields and habit switches set on the assistant tab", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    type("#settings-base-url", "https://api.deepseek.com/v1");
    type("#settings-model", "deepseek-chat");
    type("#settings-api-key", "sk-saved");
    toggle("#settings-habit", false);

    await click('[data-settings-tab="system"]');
    await click("#btn-save-settings");

    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? "{}") as {
      assistantBaseURL?: string;
      assistantModel?: string;
      habitLearningEnabled?: boolean;
    };
    assert.equal(saved.assistantBaseURL, "https://api.deepseek.com/v1");
    assert.equal(saved.assistantModel, "deepseek-chat");
    assert.equal(saved.habitLearningEnabled, false);
  });
});

describe("Settings keeps its tab under a live cloud refresh (#78)", () => {
  it("renders the tabs while a Mi Cloud sync is running", async () => {
    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const model = "yeelink.light.ceiling22";
    const spec = {
      type: "urn:miot-spec-v2:device:light:0000A001:sheet-test:1",
      services: [{
        iid: 2,
        type: "urn:miot-spec-v2:service:light:00007802:sheet-test:1",
        properties: [
          { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:sheet-test:1", format: "bool", access: ["read", "write"] },
        ],
        actions: [],
      }],
    };
    // One held read is enough to keep the sync in flight; later reads answer at once so the test
    // leaves no unresolved promise behind.
    let release: (() => void) | null = null;
    let held = false;
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) return { status: 200, headers: {}, body: JSON.stringify(spec) };
      if (url.includes("/instances?")) return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model, type: spec.type }] }) };
      if (url.includes("miotspec/prop/")) {
        if (!held) {
          held = true;
          await new Promise<void>((resolve) => { release = resolve; });
        }
        return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: [{ did: "lamp-1", siid: 2, piid: 1, code: 0, value: true }] }) };
      }
      const result = url.includes("device_list")
        ? { list: [{ did: "lamp-1", name: "台灯", model, isOnline: true, spec_type: spec.type }] }
        : { homelist: [{ id: "1", name: "家", roomlist: [{ id: "10", name: "书房", dids: ["lamp-1"] }] }] };
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miSession: { userId: "100", cUserId: "", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
      cachedModelTypes: { [model]: spec.type },
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    // The construction refresh walks device list -> rooms -> MIoT specs before it reaches the held
    // property read, so wait for that read to start instead of guessing at a tick count. Releasing a
    // `null` here would leave the lookup blocked forever and hang `closeTestWindow` in afterEach.
    await waitFor(() => release !== null, "prop read never started");
    await click("#btn-settings");
    await click('[data-settings-tab="system"]');
    // A refresh landing mid-edit must not move the reader off the tab under the pointer.
    app.render();
    await setImmediate();
    assert.equal(visibleTab(), "system");
    release!();
    await waitFor(() => !app.isSyncingCloud, "the sync never finished");
    assert.equal(visibleTab(), "system");
  });
});
