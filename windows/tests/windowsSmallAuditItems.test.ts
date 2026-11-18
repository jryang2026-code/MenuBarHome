import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { onOpenURL, type AppURLCommandHost } from "../src/core/appUrlCommand.js";
import {
  enqueueIncomingOpenUrl,
  getActiveRaycastBridgeTokenForHost,
  getLatestRaycastSnapshotForHost,
} from "../src/ui/speechGuard.js";
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
  it("shows unsaved confirmation, keeps draft, reveals panel, and reports incomplete status when Settings has unsaved edits", async () => {
    let revealCalls = 0;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (name: string) => {
          if (name === "show_panel_for_url") revealCalls += 1;
          return null;
        },
      },
    });

    const app = startDemoApp({ enableRaycastIntegration: true });
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    await enqueueIncomingOpenUrl(
      app,
      "menumijia://focus?device=light.living_ceiling&id=req_focus_unsaved",
    );
    await flushAsync();

    assert.equal(app.activeSheet, "settings", "Settings sheet must stay open when unsaved changes exist");
    assert.equal(element("#settings-unsaved-confirm").hidden, false, "Unsaved confirmation bar must be shown");
    assert.equal(field("#settings-ha-url").value, "http://unsaved-ha.local:8123", "Draft input must not be lost");
    assert.equal(app.expandedDeviceId, null, "Must not expand target device while Settings remains open");
    assert.equal(revealCalls, 1, "Must still reveal panel so user sees the unsaved confirmation bar");
    assert.equal(app.replyBanner?.isError, true, "Reply banner must indicate focus did not complete");
    assert.match(app.replyBanner?.text ?? "", /未保存/, "Reply banner must explain unsaved settings");
    assert.doesNotMatch(app.replyBanner?.text ?? "", /已定位/, "Must not falsely claim device was focused");

    const fb = getLatestRaycastSnapshotForHost(app).lastCommandFeedback;
    assert.equal(fb?.requestId, "req_focus_unsaved");
    assert.equal(fb?.command, "focus:light.living_ceiling");
    assert.equal(fb?.isError, true, "Raycast feedback must mark blocked focus as error");
    assert.match(fb?.message ?? "", /未保存/);
    assert.doesNotMatch(fb?.message ?? "", /已定位/);
  });

  it("blocks high-risk confirmation paths (both panel arming and modal prompt) when Settings has unsaved edits", async () => {
    let revealCalls = 0;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (name: string) => {
          if (name === "show_panel_for_url") revealCalls += 1;
          return null;
        },
      },
    });

    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: true });
    app.devices.push({
      id: "plug.heater",
      name: "卧室取暖器",
      roomId: "bedroom",
      roomName: "主卧",
      model: "zhimi.heater.ma2",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "switch.plug.heater",
        isOn: false,
        powerWatts: 0,
        childLockEntityId: null,
        isChildLocked: false,
      },
    });
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    let appliedCount = 0;
    app.applyCommand = async () => {
      appliedCount += 1;
      return true;
    };

    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    type("#settings-ha-url", "http://unsaved-ha.local:8123");

    await enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=plug.heater&on=true&id=req_hr_unsaved&token=${token}`,
    );
    await flushAsync();

    assert.equal(app.activeSheet, "settings");
    assert.equal(element("#settings-unsaved-confirm").hidden, false);
    assert.equal(app.pendingHighRisk, null, "Must not arm pendingHighRisk while Settings blocks close");
    assert.equal(appliedCount, 0, "Must not send high-risk device command");
    assert.equal(revealCalls, 1, "Must still reveal panel so user sees unsaved confirmation bar");
    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /未保存/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /请在面板中确认/);

    const fb = getLatestRaycastSnapshotForHost(app).lastCommandFeedback;
    assert.equal(fb?.requestId, "req_hr_unsaved");
    assert.equal(fb?.isError, true);
    assert.match(fb?.message ?? "", /未保存/);
    assert.doesNotMatch(fb?.message ?? "", /请在面板中确认/);

    // Also verify the openExternalUrlConfirmPrompt high-risk branch (~line 668) stops when focusDeviceFromUrl returns false.
    let modalCalls = 0;
    let modalRevealCalls = 0;
    let singleExecCalls = 0;
    const recordedFbs: Array<{ message: string; isError: boolean }> = [];
    const toastResults: Array<{ message: string; isError: boolean }> = [];
    const mockHost: AppURLCommandHost = {
      devices: app.devices,
      scenes: [],
      sourceRevision: 1,
      settings: {
        enableRaycastIntegration: true,
        allowDirectURLControl: true,
        blockControlWhileLocked: false,
      },
      layout: { aliases: {} },
      pendingHighRisk: null,
      replyBanner: null,
      pendingConsent: null,
      expandedDeviceId: null,
      getActiveRaycastBridgeToken: () => token,
      isControlBlockedByScreenLock: async () => false,
      requestExternalUrlConfirmation: async () => true,
      openExternalUrlConfirmPrompt: async () => {
        modalCalls += 1;
        return true;
      },
      revealPanelForExternalUrl: async () => {
        modalRevealCalls += 1;
      },
      setPendingHighRisk: () => {},
      clearPendingHighRisk: () => {},
      showExternalToast: (message, isError) => {
        toastResults.push({ message, isError });
      },
      recordRaycastCommandFeedback: (entry) => {
        recordedFbs.push({ message: entry.message, isError: entry.isError });
      },
      executeSingleCommand: async () => {
        singleExecCalls += 1;
      },
      applyCommand: async () => {
        singleExecCalls += 1;
        return true;
      },
      handleNaturalCommand: async () => {},
      executeBuiltInSceneFromUrl: async () => ({ message: "ok", isError: false }),
      focusDeviceFromUrl: () => false,
    };

    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_hr_modal_blocked&token=${token}`,
      mockHost,
    );
    assert.equal(modalCalls, 0, "Must not open high-risk modal prompt when focusDeviceFromUrl is blocked");
    assert.equal(singleExecCalls, 0, "Must not execute high-risk command when focusDeviceFromUrl is blocked");
    assert.equal(modalRevealCalls, 1, "Must still reveal panel when focusDeviceFromUrl is blocked");
    assert.equal(toastResults.at(-1)?.isError, true);
    assert.match(toastResults.at(-1)?.message ?? "", /未保存/);
    assert.equal(recordedFbs.at(-1)?.isError, true);
    assert.match(recordedFbs.at(-1)?.message ?? "", /未保存/);
  });

  it("closes Settings and focuses the device normally when there are no unsaved edits", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    await click("#btn-settings");
    assert.equal(app.activeSheet, "settings");

    await enqueueIncomingOpenUrl(
      app,
      "menumijia://focus?device=light.living_ceiling&id=req_focus_clean",
    );
    await flushAsync();

    assert.equal(app.activeSheet, "none");
    assert.equal(document.querySelector("#settings-unsaved-confirm"), null);
    assert.equal(app.expandedDeviceId, "light.living_ceiling");
    assert.equal(app.panelSearch.selectedDeviceId, "light.living_ceiling");
    assert.equal(Boolean(app.replyBanner?.isError), false);
    assert.match(app.replyBanner?.text ?? "", /已定位到/);
    const fb = getLatestRaycastSnapshotForHost(app).lastCommandFeedback;
    assert.equal(fb?.requestId, "req_focus_clean");
    assert.equal(fb?.isError, false);
    assert.match(fb?.message ?? "", /已定位到/);
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

  it("cancels an active card drag completely when a second finger presses the background or an excluded control", async () => {
    const app = startDemoApp();
    await flushAsync();

    const selector = '[data-tile-id="light.living_ceiling"]';
    element(selector).dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 80 }));
    await click("[data-start-editing]");
    assert.equal(app.isEditingLayout, true);

    const startDrag = async (): Promise<void> => {
      element(selector).dispatchEvent(
        new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 40, clientY: 40 }),
      );
      window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 120, clientY: 60 }));
      window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 160, clientY: 80 }));
      await flushAsync();
      assert.equal(app.draggingId, "light.living_ceiling");
      assert.ok(app.dragPointer);
      assert.equal(element(selector).classList.contains("is-dragging"), true);
      assert.notEqual(element(selector).style.translate, "");
    };

    // Case 1: second finger presses panel background.
    await startDrag();
    element(".cc-devices-grid").dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 5, clientY: 5 }),
    );
    await flushAsync();

    assert.equal(app.draggingId, null, "background pointerdown must clear draggingId");
    assert.equal(app.dragPointer, null, "background pointerdown must clear dragPointer");
    assert.equal(element(selector).classList.contains("is-dragging"), false, "card must leave is-dragging class");
    assert.equal(element(selector).style.translate, "", "card must clear drag translate");

    // Subsequent moves and both releases must keep the card unstuck.
    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 220, clientY: 120 }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await flushAsync();
    assert.equal(app.draggingId, null);
    assert.equal(app.dragPointer, null);
    assert.equal(element(selector).classList.contains("is-dragging"), false);

    // Case 2: second finger presses an excluded control (search input).
    await startDrag();
    element("#command-input").dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 20, clientY: 10 }),
    );
    await flushAsync();

    assert.equal(app.draggingId, null, "excluded-control pointerdown must clear draggingId");
    assert.equal(app.dragPointer, null, "excluded-control pointerdown must clear dragPointer");
    assert.equal(element(selector).classList.contains("is-dragging"), false);
    assert.equal(element(selector).style.translate, "");

    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await flushAsync();
    assert.equal(app.draggingId, null);
  });

  it("cancels an active dim preview without sending a command when a second finger presses background or excluded controls", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        isCompactGridMode: false,
        cachedXiaomiDevices: [
          {
            id: "rw-light",
            name: "客厅吸顶灯",
            roomId: "r1",
            roomName: "客厅",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: {
              kind: "light",
              entityId: "miot:rw-light:2",
              isOn: true,
              brightnessPercent: 40,
              colorTempKelvin: 4000,
              minKelvin: 2700,
              maxKelvin: 6500,
              currentEffect: null,
              availableEffects: [],
              powerWritable: true,
              brightnessWritable: true,
              colorWritable: false,
            },
          },
        ],
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();

    let commandCalls = 0;
    const origExecuteSingleCommand = app.executeSingleCommand.bind(app);
    app.executeSingleCommand = async (...args) => {
      commandCalls += 1;
      return origExecuteSingleCommand(...args);
    };

    const tileSelector = '[data-tile-id="rw-light"]';
    const fill = () => document.querySelector(`${tileSelector} .cc-tile-fill`)?.getAttribute("style") ?? "";

    const startDimPreview = async (): Promise<void> => {
      element(tileSelector).dispatchEvent(
        new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 10, clientY: 40 }),
      );
      window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 180, clientY: 42 }));
      await flushAsync();
      assert.deepEqual(app.dimPreview, { id: "rw-light", percent: 100 });
      assert.match(fill(), /width:100%/);
    };

    // Case 1: second finger presses panel background.
    await startDimPreview();
    element(".cc-devices-grid").dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 5, clientY: 5 }),
    );
    await flushAsync();

    assert.equal(app.dimPreview, null, "background pointerdown must clear dimPreview");
    assert.equal(app.suppressNextClick, false, "background pointerdown must clear suppressNextClick");
    assert.match(fill(), /width:40%/, "tile fill must revert to real brightness");

    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 200, clientY: 42 }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await flushAsync();
    assert.equal(app.dimPreview, null);
    assert.equal(commandCalls, 0, "cancelled dim preview must not send a brightness command");
    assert.doesNotMatch(document.body.textContent ?? "", /已将|控制失败/);

    // Case 2: second finger presses an excluded inline slider wrapper (which stops bubble propagation).
    const excludedTarget = element(`${tileSelector} [data-inline-slider-wrap]`);
    await startDimPreview();
    excludedTarget.dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 30, clientY: 50 }),
    );
    await flushAsync();

    assert.equal(app.dimPreview, null, "excluded-control pointerdown must clear dimPreview");
    assert.match(fill(), /width:40%/, "tile fill must revert to real brightness");

    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await flushAsync();
    assert.equal(app.dimPreview, null);
    assert.equal(commandCalls, 0, "cancelled dim preview must not send a brightness command");
  });

  it("clears prior drag or dim preview when a second finger presses another tile", async () => {
    const app = startDemoApp();
    await flushAsync();

    const tileA = '[data-tile-id="light.living_ceiling"]';
    const tileB = '[data-tile-id="light.study_desk"]';

    element(tileA).dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 80 }));
    await click("[data-start-editing]");

    element(tileA).dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 40, clientY: 40 }),
    );
    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 120, clientY: 60 }));
    await flushAsync();
    assert.equal(app.draggingId, "light.living_ceiling");

    // Second finger presses tile B while tile A is being dragged.
    element(tileB).dispatchEvent(
      new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 200, clientY: 60 }),
    );
    await flushAsync();
    assert.equal(app.draggingId, null, "pressing tile B must clear tile A draggingId");
    assert.equal(app.dragPointer, null, "pressing tile B must clear tile A dragPointer");
    assert.equal(element(tileA).classList.contains("is-dragging"), false);

    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await flushAsync();
    assert.equal(app.draggingId, null);
  });
});

