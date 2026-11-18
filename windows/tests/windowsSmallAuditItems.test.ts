import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { enqueueIncomingOpenUrl } from "../src/ui/speechGuard.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

let dom: Window;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element ${selector}`);
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

async function flushAsync(): Promise<void> {
  await setImmediate();
  await setImmediate();
  await setImmediate();
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
  dom = mountTestWindow({ stubInterval: true });
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

describe("Audit #32: bindAllOffControl scoped in RenderEventScope", () => {
  it("does not duplicate #btn-all-off listeners when silent refresh inserts it and full render follows, while keeping blur/pointerleave cancel", async () => {
    const baseURL = "http://localhost:8123";
    const token = "controlled-token";
    const offFixture = JSON.parse(readFileSync("../Tests/Fixtures/ha_snapshot.json", "utf8")) as {
      areas: Array<Record<string, unknown>>;
      devices: Array<Record<string, unknown>>;
      entities: Array<Record<string, unknown>>;
      states: Array<{ entity_id: string; state: string; attributes?: Record<string, unknown> }>;
    };
    // Make every light start OFF so #btn-all-off is absent on the initial render.
    for (const s of offFixture.states) {
      if (s.entity_id.startsWith("light.")) s.state = "off";
    }
    const onFixture = structuredClone(offFixture);
    for (const s of onFixture.states) {
      if (s.entity_id === "light.study") s.state = "on";
    }

    let currentFixture = offFixture;
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_get") return args.name === "ha_token" ? token : null;
      if (name === "ha_snapshot") return structuredClone(currentFixture);
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        haBaseURL: baseURL,
        hasCompletedOnboarding: true,
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();
    assert.ok(document.querySelector('[data-tile-id="study-light"]'));
    assert.equal(document.querySelector("#btn-all-off"), null);

    // Silent refresh turns light.study ON and patches #btn-all-off into the DOM in place.
    currentFixture = onFixture;
    await app.refreshHADevices(true);
    await flushAsync();

    const insertedBtn = element("#btn-all-off");
    // A subsequent full render morphs #btn-all-off in place and re-runs bindEvents().
    app.render();
    assert.equal(element("#btn-all-off"), insertedBtn, "#btn-all-off should be morphed in place");

    let renderCalls = 0;
    const origRender = app.render.bind(app);
    app.render = () => {
      renderCalls += 1;
      origRender();
    };

    insertedBtn.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    insertedBtn.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, button: 0 }));
    assert.equal(renderCalls, 1, "short press on #btn-all-off must fire only one listener");

    // Verify blur and pointerleave still cancel a pending hold.
    let intentCalls = 0;
    const origExecute = app.executeIntents.bind(app);
    app.executeIntents = async (...args) => {
      intentCalls += 1;
      return origExecute(...args);
    };

    const timeouts: Array<{ id: number; fn: () => void; ms: number; cleared: boolean }> = [];
    let nextId = 1000;
    const origSetTimeout = window.setTimeout.bind(window);
    const origClearTimeout = window.clearTimeout.bind(window);
    Object.defineProperty(window, "setTimeout", {
      configurable: true,
      value: (handler: TimerHandler, ms = 0) => {
        if (ms === 600 && typeof handler === "function") {
          const entry = { id: ++nextId, fn: handler as () => void, ms, cleared: false };
          timeouts.push(entry);
          return entry.id;
        }
        return origSetTimeout(handler, ms);
      },
    });
    Object.defineProperty(window, "clearTimeout", {
      configurable: true,
      value: (id?: number) => {
        const hit = timeouts.find((t) => t.id === id);
        if (hit) hit.cleared = true;
        origClearTimeout(id);
      },
    });

    try {
      const btn = element("#btn-all-off");
      btn.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
      assert.equal(btn.classList.contains("is-holding"), true);
      assert.equal(timeouts.length, 1);
      btn.dispatchEvent(new window.Event("pointerleave"));
      assert.equal(btn.classList.contains("is-holding"), false);
      assert.equal(timeouts[0]!.cleared, true);

      btn.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
      assert.equal(btn.classList.contains("is-holding"), true);
      assert.equal(timeouts.length, 2);
      btn.dispatchEvent(new window.Event("blur"));
      assert.equal(btn.classList.contains("is-holding"), false);
      assert.equal(timeouts[1]!.cleared, true);
      assert.equal(intentCalls, 0);
    } finally {
      Object.defineProperty(window, "setTimeout", { configurable: true, value: origSetTimeout });
      Object.defineProperty(window, "clearTimeout", { configurable: true, value: origClearTimeout });
    }
  });
});

describe("Audit #34: focusDeviceFromUrl respects Settings unsaved changes protection", () => {
  it("shows unsaved confirmation and keeps draft when Settings has unsaved edits", async () => {
    const app = startDemoApp();
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    await enqueueIncomingOpenUrl(app, "menumijia://focus?device=light.living_ceiling");
    await flushAsync();

    assert.equal(app.activeSheet, "settings", "Settings sheet must stay open when unsaved changes exist");
    assert.equal(element("#settings-unsaved-confirm").hidden, false, "Unsaved confirmation bar must be shown");
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123", "Draft input must not be lost");
    assert.equal(app.expandedDeviceId, null, "Must not expand target device while Settings remains open");
  });

  it("closes Settings and focuses the device normally when there are no unsaved edits", async () => {
    const app = startDemoApp();
    await click("#btn-settings");
    assert.equal(app.activeSheet, "settings");

    await enqueueIncomingOpenUrl(app, "menumijia://focus?device=light.living_ceiling");
    await flushAsync();

    assert.equal(app.activeSheet, "none");
    assert.equal(document.querySelector("#settings-unsaved-confirm"), null);
    assert.equal(app.expandedDeviceId, "light.living_ceiling");
    assert.equal(app.panelSearch.selectedDeviceId, "light.living_ceiling");
  });
});

describe("Audit #35: layoutGestures clears prior long-press timer on new pointerdown", () => {
  it("cancels the previous long-press timer on a new pointerdown and prevents a stale timer from dragging the wrong card", async () => {
    const app = startDemoApp();
    await flushAsync();

    const scheduled: Array<{ id: number; fn: () => void; ms: number; cleared: boolean }> = [];
    let nextId = 5000;
    const origSetTimeout = window.setTimeout.bind(window);
    const origClearTimeout = window.clearTimeout.bind(window);

    Object.defineProperty(window, "setTimeout", {
      configurable: true,
      value: (handler: TimerHandler, ms = 0) => {
        if (ms === 450 && typeof handler === "function") {
          const entry = { id: ++nextId, fn: handler as () => void, ms, cleared: false };
          scheduled.push(entry);
          return entry.id;
        }
        return origSetTimeout(handler, ms);
      },
    });
    Object.defineProperty(window, "clearTimeout", {
      configurable: true,
      value: (id?: number) => {
        const hit = scheduled.find((t) => t.id === id);
        if (hit) hit.cleared = true;
        origClearTimeout(id);
      },
    });

    try {
      const tileA = element('[data-tile-id="light.living_ceiling"]');
      const tileB = element('[data-tile-id="light.study_desk"]');

      tileA.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 20, clientY: 30 }));
      assert.equal(scheduled.length, 1);
      const timerA = scheduled[0]!;
      assert.equal(timerA.cleared, false);

      // Second finger presses tile B before tile A is released.
      tileB.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 140, clientY: 60 }));
      assert.equal(timerA.cleared, true, "old long-press timer must be cleared when a new pointerdown starts");
      assert.equal(scheduled.length, 2);
      const timerB = scheduled[1]!;

      // Even if the stale timerA callback runs, it must NOT drag tile A or enter editing mode.
      timerA.fn();
      assert.equal(app.isEditingLayout, false, "stale timer must not enter layout editing mode");
      assert.equal(app.draggingId, null, "stale timer must not start dragging tile A");

      // The active timerB should drag tile B and enter editing mode.
      timerB.fn();
      assert.equal(app.isEditingLayout, true);
      assert.equal(app.draggingId, "light.study_desk");
    } finally {
      Object.defineProperty(window, "setTimeout", { configurable: true, value: origSetTimeout });
      Object.defineProperty(window, "clearTimeout", { configurable: true, value: origClearTimeout });
    }
  });
});
