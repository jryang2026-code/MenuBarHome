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

    // Also verify the openExternalUrlConfirmPrompt high-risk branch stops when focusDeviceFromUrl reports unsaved-settings or source-changed with distinct messages.
    let modalCalls = 0;
    let modalRevealCalls = 0;
    let singleExecCalls = 0;
    let focusResult: "focused" | "unsaved-settings" | "source-changed" = "unsaved-settings";
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
      focusDeviceFromUrl: () => focusResult,
    };

    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_hr_modal_blocked&token=${token}`,
      mockHost,
    );
    assert.equal(modalCalls, 0, "Must not open high-risk modal prompt when focusDeviceFromUrl is blocked");
    assert.equal(singleExecCalls, 0, "Must not execute high-risk command when focusDeviceFromUrl is blocked");
    assert.equal(modalRevealCalls, 1, "Must still reveal panel when focusDeviceFromUrl is blocked by unsaved settings");
    assert.equal(toastResults.at(-1)?.isError, true);
    assert.match(toastResults.at(-1)?.message ?? "", /未保存/);
    assert.equal(recordedFbs.at(-1)?.isError, true);
    assert.match(recordedFbs.at(-1)?.message ?? "", /未保存/);

    focusResult = "source-changed";
    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_hr_source_changed&token=${token}`,
      mockHost,
    );
    assert.equal(modalCalls, 0);
    assert.equal(singleExecCalls, 0);
    assert.equal(modalRevealCalls, 1, "Source-changed failure must not reveal panel for unsaved settings");
    assert.equal(toastResults.at(-1)?.isError, true);
    assert.match(toastResults.at(-1)?.message ?? "", /数据源已切换/);
    assert.doesNotMatch(toastResults.at(-1)?.message ?? "", /未保存/);
    assert.notEqual(toastResults.at(-1)?.message, toastResults.at(-2)?.message);
  });

  it("reports data-source change instead of unsaved settings when sourceRevision changes before focusDeviceFromUrl runs", async () => {
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
    // `onOpenURL` reads `host.devices` twice in `resolveTarget` (before and after lock check)
    // and then once in `isDeviceVisibleInPanel` before calling `host.focusDeviceFromUrl`.
    // Advance `sourceRevision` on that third read so `focusDeviceFromUrl` observes `!revisionStillMatches()`.
    const realDevices = app.devices;
    const baseRevision = app.sourceRevision;
    let bumpedRevision = baseRevision;
    Object.defineProperty(app, "sourceRevision", {
      configurable: true,
      get() {
        return bumpedRevision;
      },
    });
    let reads = 0;
    Object.defineProperty(app, "devices", {
      configurable: true,
      get() {
        reads += 1;
        if (reads === 3) {
          bumpedRevision = baseRevision + 1;
        }
        return realDevices;
      },
    });

    await enqueueIncomingOpenUrl(
      app,
      "menumijia://focus?device=light.living_ceiling&id=req_focus_source_changed",
    );
    await flushAsync();

    assert.equal(app.expandedDeviceId, null);
    assert.equal(revealCalls, 0, "Source change must not reveal panel");
    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /数据源已切换/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /未保存/);

    const fb = getLatestRaycastSnapshotForHost(app).lastCommandFeedback;
    assert.equal(fb?.requestId, "req_focus_source_changed");
    assert.equal(fb?.isError, true);
    assert.match(fb?.message ?? "", /数据源已切换/);
    assert.doesNotMatch(fb?.message ?? "", /未保存/);
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

describe("Audit #35: layoutGestures locks active gesture to initiating pointerId", () => {
  function pointerEvent(
    type: string,
    init: MouseEventInit & { pointerId?: number } = {},
  ): MouseEvent {
    const ev = new window.MouseEvent(type, { bubbles: true, button: 0, ...init });
    Object.defineProperty(ev, "pointerId", {
      value: init.pointerId ?? 1,
      configurable: true,
    });
    return ev;
  }

  it("ignores secondary pointer events during long-press, prevents stale 450ms timer from acting on a later press, and allows a new gesture after the initiator finishes", async () => {
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

      // Pointer 1 presses tile A.
      tileA.dispatchEvent(pointerEvent("pointerdown", { pointerId: 1, clientX: 20, clientY: 30 }));
      assert.equal(scheduled.length, 1);
      const timerA1 = scheduled[0]!;
      assert.equal(timerA1.cleared, false);

      // Pointer 2 presses tile B while pointer 1 is still active: must be ignored.
      tileB.dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 140, clientY: 60 }));
      assert.equal(scheduled.length, 1, "second pointerdown must not schedule a new press timer");
      assert.equal(timerA1.cleared, false, "second pointerdown must not cancel pointer 1 timer");

      // Pointer 2 move/up/cancel must not affect pointer 1.
      window.dispatchEvent(pointerEvent("pointermove", { pointerId: 2, clientX: 200, clientY: 200 }));
      window.dispatchEvent(pointerEvent("pointerup", { pointerId: 2, clientX: 200, clientY: 200 }));
      window.dispatchEvent(pointerEvent("pointercancel", { pointerId: 2 }));
      assert.equal(timerA1.cleared, false);
      assert.equal(app.pointerIsDown, true);

      // Pointer 1 releases before 450ms, clearing timerA1.
      window.dispatchEvent(pointerEvent("pointerup", { pointerId: 1, clientX: 20, clientY: 30 }));
      assert.equal(timerA1.cleared, true);
      assert.equal(app.pointerIsDown, false);

      // After pointer 1 ends, pointer 2 can start a new gesture on tile B.
      tileB.dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 140, clientY: 60 }));
      assert.equal(scheduled.length, 2, "new gesture can start after initiator ends");
      const timerB2 = scheduled[1]!;

      // Even if the stale timerA1 callback fires late, it must not act on the new press.
      timerA1.fn();
      assert.equal(app.isEditingLayout, false, "stale timer must not affect subsequent press");
      assert.equal(app.draggingId, null);

      // The active timerB2 enters editing mode and drags tile B.
      timerB2.fn();
      assert.equal(app.isEditingLayout, true);
      assert.equal(app.draggingId, "light.study_desk");

      window.dispatchEvent(pointerEvent("pointerup", { pointerId: 2, clientX: 140, clientY: 60 }));
      assert.equal(app.draggingId, null);
    } finally {
      Object.defineProperty(window, "setTimeout", { configurable: true, value: origSetTimeout });
      Object.defineProperty(window, "clearTimeout", { configurable: true, value: origClearTimeout });
    }
  });

  it("keeps first-finger card drag alive when a second finger presses, moves, or releases, and allows a new drag after the first finger ends", async () => {
    const app = startDemoApp();
    await flushAsync();

    const tileASelector = '[data-tile-id="light.living_ceiling"]';
    const tileBSelector = '[data-tile-id="light.study_desk"]';
    element(tileASelector).dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 80 }));
    await click("[data-start-editing]");
    assert.equal(app.isEditingLayout, true);

    // First finger (pointerId 1) starts dragging tile A.
    element(tileASelector).dispatchEvent(pointerEvent("pointerdown", { pointerId: 1, clientX: 40, clientY: 40 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 1, clientX: 80, clientY: 50 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 1, clientX: 120, clientY: 60 }));
    await flushAsync();
    assert.equal(app.draggingId, "light.living_ceiling");
    assert.deepEqual(
      { x: app.dragPointer?.x, y: app.dragPointer?.y },
      { x: 120, y: 60 },
    );

    // Second finger (pointerId 2) presses tile B, background, and excluded input, then moves and releases.
    element(tileBSelector).dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 200, clientY: 60 }));
    element(".cc-devices-grid").dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 5, clientY: 5 }));
    element("#command-input").dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 20, clientY: 10 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 2, clientX: 300, clientY: 300 }));
    window.dispatchEvent(pointerEvent("pointerup", { pointerId: 2, clientX: 300, clientY: 300 }));
    window.dispatchEvent(pointerEvent("pointercancel", { pointerId: 2 }));
    await flushAsync();

    assert.equal(app.draggingId, "light.living_ceiling", "second finger must not cancel first finger drag");
    assert.deepEqual(
      { x: app.dragPointer?.x, y: app.dragPointer?.y },
      { x: 120, y: 60 },
      "second finger move must not move first finger dragPointer",
    );

    // First finger continues moving and finishes normally.
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 1, clientX: 160, clientY: 80 }));
    assert.deepEqual(
      { x: app.dragPointer?.x, y: app.dragPointer?.y },
      { x: 160, y: 80 },
    );
    window.dispatchEvent(pointerEvent("pointerup", { pointerId: 1, clientX: 160, clientY: 80 }));
    await flushAsync();
    assert.equal(app.draggingId, null);
    assert.equal(app.dragPointer, null);

    // Once first finger has ended, a new gesture on tile B works normally.
    element(tileBSelector).dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 60, clientY: 60 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 2, clientX: 140, clientY: 90 }));
    await flushAsync();
    assert.equal(app.draggingId, "light.study_desk");
    window.dispatchEvent(pointerEvent("pointerup", { pointerId: 2, clientX: 140, clientY: 90 }));
    await flushAsync();
    assert.equal(app.draggingId, null);
  });

  it("keeps first-finger brightness dim preview, commits on first-finger release, and suppresses the post-dim click even when a second finger interferes", async () => {
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

    const executedCommands: Array<{ command: unknown; summary: string }> = [];
    app.executeSingleCommand = async (_dev, command, summary) => {
      executedCommands.push({ command, summary });
    };

    const tileSelector = '[data-tile-id="rw-light"]';
    const tile = element(tileSelector);
    tile.getBoundingClientRect = () =>
      ({
        left: 0,
        top: 0,
        right: 200,
        bottom: 80,
        width: 200,
        height: 80,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      }) as DOMRect;
    const fill = () => document.querySelector(`${tileSelector} .cc-tile-fill`)?.getAttribute("style") ?? "";

    // First finger (pointerId 1) starts dimming to 75%.
    tile.dispatchEvent(pointerEvent("pointerdown", { pointerId: 1, clientX: 20, clientY: 40 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 1, clientX: 150, clientY: 42 }));
    await flushAsync();
    assert.deepEqual(app.dimPreview, { id: "rw-light", percent: 75 });
    assert.equal(app.suppressNextClick, true);
    assert.match(fill(), /width:75%/);

    // Second finger (pointerId 2) presses, moves to 10%, and releases: must be ignored.
    element(".cc-devices-grid").dispatchEvent(pointerEvent("pointerdown", { pointerId: 2, clientX: 5, clientY: 5 }));
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 2, clientX: 20, clientY: 42 }));
    window.dispatchEvent(pointerEvent("pointerup", { pointerId: 2, clientX: 20, clientY: 42 }));
    await flushAsync();

    assert.deepEqual(app.dimPreview, { id: "rw-light", percent: 75 }, "second finger must not alter dimPreview");
    assert.equal(app.suppressNextClick, true, "second finger must not clear suppressNextClick");
    assert.equal(executedCommands.length, 0, "second finger release must not commit brightness early");

    // First finger adjusts to 90% and releases: commits 90% brightness.
    window.dispatchEvent(pointerEvent("pointermove", { pointerId: 1, clientX: 180, clientY: 42 }));
    window.dispatchEvent(pointerEvent("pointerup", { pointerId: 1, clientX: 180, clientY: 42 }));
    await flushAsync();

    assert.equal(app.dimPreview, null);
    assert.equal(executedCommands.length, 1, "first finger release must commit brightness");
    assert.deepEqual(executedCommands[0]?.command, {
      kind: "setLightBrightness",
      entityId: "miot:rw-light:2",
      percent: 90,
    });
    assert.equal(app.suppressNextClick, true, "suppressNextClick must remain armed for the trailing click");

    // Trailing click from first finger release must be swallowed and must NOT toggle the light.
    element(tileSelector).click();
    await flushAsync();
    assert.equal(app.suppressNextClick, false);
    assert.equal(executedCommands.length, 1, "trailing click after dim must not toggle light power");
  });
});


