import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { shouldKeepPopoverPinned } from "../src/ui/speechGuard.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

let dom: Window;

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) {
      assert.fail("Timed out waiting for expected UI state");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
}

function startDemoApp(overrides: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...overrides,
    }),
  );
  return new MenuMijiaWindowsApp(element("#app"));
}

function dispatchWindowKey(
  key: string,
  init: KeyboardEventInit = {},
): KeyboardEvent {
  const event = new window.KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...init,
  });
  window.dispatchEvent(event);
  return event;
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
  await closeTestWindow(dom);
});

describe("Fluent UX & Interaction Holistic Contract", () => {
  it("Escape closes open home menu or context menu without invoking hide_panel", () => {
    const tauriCalls: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          tauriCalls.push({ cmd, args });
          return null;
        },
      },
      configurable: true,
    });

    const app = startDemoApp();
    app.isHomeMenuOpen = true;
    app.render();

    const escHome = dispatchWindowKey("Escape");
    assert.equal(escHome.defaultPrevented, true);
    assert.equal(app.isHomeMenuOpen, false);
    assert.equal(
      tauriCalls.some((call) => call.cmd === "hide_panel"),
      false,
    );

    app.ctxMenu = { x: 24, y: 36, deviceId: "ceiling_light" };
    app.render();

    const escCtx = dispatchWindowKey("Escape");
    assert.equal(escCtx.defaultPrevented, true);
    assert.equal(app.ctxMenu, null);
    assert.equal(
      tauriCalls.some((call) => call.cmd === "hide_panel"),
      false,
    );
  });

  it("Escape exits layout editing mode without invoking hide_panel", () => {
    const tauriCalls: string[] = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string) => {
          tauriCalls.push(cmd);
          return null;
        },
      },
      configurable: true,
    });

    const app = startDemoApp();
    app.startEditing();
    assert.equal(app.isEditingLayout, true);
    tauriCalls.length = 0;

    const escEdit = dispatchWindowKey("Escape");
    assert.equal(escEdit.defaultPrevented, true);
    assert.equal(app.isEditingLayout, false);
    assert.equal(tauriCalls.includes("hide_panel"), false);
  });

  it("Tab does not hijack room pills when a button is focused, cycles room pills from body, and traps focus in modals", () => {
    const app = startDemoApp();
    const initialRoom = app.selectedRoom;

    const settingsBtn = element<HTMLButtonElement>("#btn-settings");
    settingsBtn.focus();
    assert.equal(document.activeElement, settingsBtn);

    const tabOnHeaderBtn = dispatchWindowKey("Tab");
    assert.equal(tabOnHeaderBtn.defaultPrevented, false);
    assert.equal(app.selectedRoom, initialRoom);

    const tileBtn = element<HTMLButtonElement>("[data-toggle-device]");
    tileBtn.focus();
    assert.equal(document.activeElement, tileBtn);

    const tabOnTileBtn = dispatchWindowKey("Tab");
    assert.equal(tabOnTileBtn.defaultPrevented, false);
    assert.equal(app.selectedRoom, initialRoom);

    document.body.focus();
    const tabOnBody = dispatchWindowKey("Tab");
    assert.equal(tabOnBody.defaultPrevented, true);
    assert.notEqual(app.selectedRoom, initialRoom);

    app.openSettingsSheet();
    const sheet = element(".cc-settings-sheet");
    const quitBtn = element<HTMLButtonElement>("#btn-settings-quit");
    const saveBtn = element<HTMLButtonElement>("#btn-save-settings");
    const closeBtn = element<HTMLButtonElement>("#btn-close-settings");
    assert.ok(sheet.contains(quitBtn));
    saveBtn.focus();
    const wrapForward = dispatchWindowKey("Tab");
    assert.equal(wrapForward.defaultPrevented, true);
    assert.equal(document.activeElement, closeBtn);

    closeBtn.focus();
    const wrapBackward = dispatchWindowKey("Tab", { shiftKey: true });
    assert.equal(wrapBackward.defaultPrevented, true);
    assert.equal(document.activeElement, saveBtn);
  });

  it("Alt+ArrowLeft inside an L2 subpage exits L2 and restores focus to the opener button", () => {
    const app = startDemoApp();
    const expandBtn = element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]');
    expandBtn.focus();
    expandBtn.click();

    assert.equal(app.expandedDeviceId, "light.living_ceiling");
    assert.ok(document.querySelector(".cc-tile.is-subpage"));

    const altLeft = dispatchWindowKey("ArrowLeft", { altKey: true });
    assert.equal(altLeft.defaultPrevented, true);
    assert.equal(app.expandedDeviceId, null);
    assert.equal(document.querySelector(".cc-tile.is-subpage"), null);

    const restoredBtn = element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]');
    assert.equal(document.activeElement, restoredBtn);
  });

  it("shouldKeepPopoverPinned tracks menus and high-risk arming, and #btn-hide-panel awaits set_pin_popover(false) before hide_panel", async () => {
    const callOrder: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    let resolveUnpin: (() => void) | null = null;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "set_pin_popover" || cmd === "hide_panel") {
            callOrder.push({ cmd, args });
          }
          if (cmd === "set_pin_popover" && args?.pin === false) {
            return new Promise<void>((resolve) => {
              resolveUnpin = resolve;
            });
          }
          return Promise.resolve(null);
        },
      },
      configurable: true,
    });

    const app = startDemoApp();
    assert.equal(shouldKeepPopoverPinned(app), false);

    app.isHomeMenuOpen = true;
    assert.equal(shouldKeepPopoverPinned(app), true);
    app.isHomeMenuOpen = false;

    app.ctxMenu = { x: 10, y: 10, deviceId: "light.living_ceiling" };
    assert.equal(shouldKeepPopoverPinned(app), true);
    app.ctxMenu = null;

    app.setPendingHighRisk({
      deviceId: "heater",
      actionKey: "power:on",
      expiresAtMs: Date.now() + 8000,
      sourceRevision: app.sourceRevision,
    });
    assert.equal(shouldKeepPopoverPinned(app), true);

    callOrder.length = 0;
    element("#btn-hide-panel").click();
    await setImmediate();

    assert.equal(callOrder.length, 1);
    assert.deepEqual(callOrder[0], { cmd: "set_pin_popover", args: { pin: false } });
    assert.ok(resolveUnpin);
    const finishUnpin: () => void = resolveUnpin;
    finishUnpin();
    await setImmediate();

    assert.equal(callOrder.length, 2);
    assert.equal(callOrder[1]?.cmd, "hide_panel");

    callOrder.length = 0;
    app.setPendingHighRisk({
      deviceId: "heater",
      actionKey: "power:on",
      expiresAtMs: Date.now() + 30,
      sourceRevision: app.sourceRevision,
    });
    assert.deepEqual(callOrder, [{ cmd: "set_pin_popover", args: { pin: true } }]);

    await waitFor(() => app.pendingHighRisk === null, 2000);
    assert.equal(shouldKeepPopoverPinned(app), false);
    assert.deepEqual(callOrder.at(-1), { cmd: "set_pin_popover", args: { pin: false } });
  });

  it("renders .is-waiting on waiting tiles and shows local high-risk caution without mounting [data-high-risk-confirm] on collapsed heater", () => {
    const app = startDemoApp();
    app.devices.push({
      id: "heater",
      name: "电暖器",
      roomId: "room_living",
      roomName: "客厅",
      model: "zhimi.heater.za2",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "miot:heater:2",
        isOn: false,
        hvacMode: "off",
        availableModes: ["heat", "off"],
        targetTemperature: 22,
        currentTemperature: 18,
        minTemp: 16,
        maxTemp: 28,
        step: 1,
        fanMode: null,
        availableFanModes: [],
      },
    });
    app.waitingDeviceIds.add("light.living_ceiling");
    app.render();

    const waitingTile = element('[data-tile-id="light.living_ceiling"]');
    assert.equal(waitingTile.classList.contains("is-waiting"), true);

    app.waitingDeviceIds.delete("light.living_ceiling");
    app.render();

    const heaterToggle = element<HTMLButtonElement>('[data-toggle-device="heater"]');
    heaterToggle.click();

    const heaterTile = element('[data-tile-id="heater"]');
    assert.equal(heaterTile.classList.contains("is-caution-armed"), true);
    assert.match(heaterTile.querySelector(".cc-tile-status")?.textContent ?? "", /再点一次确认/);
    assert.equal(document.querySelector('[data-high-risk-confirm="heater"]'), null);
  });

  it("mounts .cc-slider-thumb-badge.is-visible during slider input and maps vertical wheel on .cc-room-scroll to scrollLeft", () => {
    const app = startDemoApp();
    app.expandedDeviceId = "light.living_ceiling";
    app.render();

    const brightnessSlider = element<HTMLInputElement>('input[data-brightness="light.living_ceiling"]');
    brightnessSlider.value = "73";
    brightnessSlider.dispatchEvent(new window.Event("input", { bubbles: true }));

    const badge = brightnessSlider.parentElement?.querySelector<HTMLElement>(".cc-slider-thumb-badge");
    assert.ok(badge);
    assert.equal(badge.classList.contains("is-visible"), true);
    assert.equal(badge.textContent, "73%");

    brightnessSlider.dispatchEvent(new window.Event("pointerup", { bubbles: true }));
    assert.equal(badge.classList.contains("is-visible"), false);

    app.expandedDeviceId = null;
    app.render();

    const roomStrip = element<HTMLElement>(".cc-room-scroll");
    Object.defineProperty(roomStrip, "scrollWidth", { value: 480, configurable: true });
    Object.defineProperty(roomStrip, "clientWidth", { value: 200, configurable: true });
    roomStrip.scrollLeft = 10;

    const wheelEvent = new window.WheelEvent("wheel", {
      deltaY: 45,
      deltaX: 0,
      bubbles: true,
      cancelable: true,
    });
    roomStrip.dispatchEvent(wheelEvent);
    assert.equal(wheelEvent.defaultPrevented, true);
    assert.equal(roomStrip.scrollLeft, 55);
  });

  it("orders active connectionMode credentials first with .is-active-mode, updates .cc-settings-save-hint, and preserves 3-zone layout", () => {
    const app = startDemoApp({ connectionMode: "homeAssistant" });
    app.openSettingsSheet("connection");

    const sheet = element(".cc-settings-sheet");
    assert.deepEqual(
      [...sheet.children].map((child) =>
        child.className.split(" ").find((cls) => ["cc-settings-top", "cc-sheet-body", "cc-sheet-footer"].includes(cls)),
      ),
      ["cc-settings-top", "cc-sheet-body", "cc-sheet-footer"],
    );

    const connPanel = element('[data-settings-panel="connection"]');
    const firstActiveCard = connPanel.querySelector<HTMLElement>(".cc-conn-card.is-active-mode");
    assert.ok(firstActiveCard);
    assert.equal(firstActiveCard.dataset.connSection, "homeAssistant");
    assert.ok(firstActiveCard.querySelector("#settings-ha-url"));

    const secondaryDetails = connPanel.querySelector<HTMLDetailsElement>("details.cc-conn-secondary");
    assert.ok(secondaryDetails);
    assert.equal(secondaryDetails.dataset.connSection, "xiaomiCloud");
    assert.ok(secondaryDetails.querySelector("select[data-mi-region]"));
    assert.ok(secondaryDetails.querySelector("#btn-start-qr"));

    const quitBtn = element("#btn-settings-quit");
    assert.equal(quitBtn.classList.contains("cc-btn-ghost-danger"), true);

    const saveHint = element(".cc-settings-save-hint");
    assert.equal(saveHint.dataset.saveState, "clean");

    const haUrlInput = element<HTMLInputElement>("#settings-ha-url");
    haUrlInput.value = "http://192.168.1.50:8123";
    haUrlInput.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(element(".cc-settings-save-hint").dataset.saveState, "dirty");

    const hideOfflineBox = element<HTMLInputElement>("#settings-hide-offline");
    hideOfflineBox.checked = !hideOfflineBox.checked;
    hideOfflineBox.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.equal(element(".cc-settings-save-hint").dataset.saveState, "saved");

    element<HTMLButtonElement>('[data-conn-mode="xiaomiCloud"]').click();
    const updatedConnPanel = element('[data-settings-panel="connection"]');
    const miActiveCard = updatedConnPanel.querySelector<HTMLElement>(".cc-conn-card.is-active-mode");
    assert.ok(miActiveCard);
    assert.equal(miActiveCard.dataset.connSection, "xiaomiCloud");
    const haSecondaryDetails = updatedConnPanel.querySelector<HTMLDetailsElement>("details.cc-conn-secondary");
    assert.ok(haSecondaryDetails);
    assert.equal(haSecondaryDetails.dataset.connSection, "homeAssistant");
    assert.equal(haSecondaryDetails.open, false);
    assert.ok(haSecondaryDetails.querySelector("#settings-ha-url"));

    const searchInput = element<HTMLInputElement>("#settings-search-input");
    searchInput.value = "Home Assistant URL";
    searchInput.dispatchEvent(new window.Event("input", { bubbles: true }));
    element<HTMLButtonElement>('[data-settings-search-hit="haServerAddress"]').click();
    assert.equal(haSecondaryDetails.open, true);
  });
});
