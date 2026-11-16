import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

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

function type(selector: string, value: string): void {
  const input = field(selector);
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function pressEscape(): void {
  const event = new window.KeyboardEvent("keydown", {
    key: "Escape",
    bubbles: true,
    cancelable: true,
  });
  window.dispatchEvent(event);
}

function startDemo(): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }),
  );
  return new MenuMijiaWindowsApp(element("#app"));
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Settings Escape keeps an unsaved draft", () => {
  it("shows the same unsaved confirm as the close button when Escape meets a typed Home Assistant address", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    pressEscape();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123");
    assert.equal(app.settings.haBaseURL, "");
  });

  it("shows the unsaved confirm when Escape meets a typed Home Assistant token", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-token", "draft-ha-token");

    pressEscape();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);
    assert.equal(field("#settings-ha-token").value, "draft-ha-token");
    assert.equal(app.settings.haToken, "");
  });

  it("shows the unsaved confirm when Escape meets a typed AI key", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="assistant"]');
    type("#settings-api-key", "sk-draft-key");

    pressEscape();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);
    assert.equal(field("#settings-api-key").value, "sk-draft-key");
    assert.equal(app.settings.openRouterApiKey, "");
  });

  it("still closes Settings on Escape when nothing is unsaved", async () => {
    const app = startDemo();
    await click("#btn-settings");

    pressEscape();

    assert.equal(app.activeSheet, "none");
    assert.equal(document.querySelector("#settings-unsaved-confirm"), null);
  });

  it("keeps editing when Escape dismisses a confirm bar the close button already opened", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-token", "draft-ha-token");
    await click("#btn-close-settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);

    pressEscape();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, true);
    assert.equal(field("#settings-ha-token").value, "draft-ha-token");
    assert.equal(app.settings.haToken, "");
  });

  it("treats a second Escape as keep editing and leaves the draft in place", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    pressEscape();
    assert.equal(element("#settings-unsaved-confirm").hidden, false);

    pressEscape();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, true);
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123");
    assert.equal(app.settings.haBaseURL, "");

    pressEscape();
    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123");
  });

  it("still closes onboarding on Escape", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click("#btn-reopen-onboarding");
    assert.equal(app.activeSheet, "onboarding");

    pressEscape();

    assert.equal(app.activeSheet, "none");
  });
});
