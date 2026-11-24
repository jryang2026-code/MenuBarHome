import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import {
  PANEL_QUICK_DRAWER_STORAGE_KEY,
  readPanelQuickDrawerExpanded,
  togglePanelQuickDrawerExpanded,
  writePanelQuickDrawerExpanded,
} from "../src/ui/panelQuickDrawer.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

const SETTINGS_KEY = "menumijia.windows.settings.v2";

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value); },
    removeItem: (key: string) => { values.delete(key); },
    get: (key: string) => values.get(key) ?? null,
    has: (key: string) => values.has(key),
  };
}

function startDemoApp(panelTheme: "fluent" | "classic" = "fluent", extra: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify({
    connectionMode: "demo",
    hasCompletedOnboarding: true,
    panelTheme,
    ...extra,
  }));
  app = new MenuMijiaWindowsApp(element("#app"));
  app.render();
  return app;
}

function pressCtrlK(): void {
  window.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "k",
    ctrlKey: true,
    bubbles: true,
    cancelable: true,
  }));
}

beforeEach(() => {
  dom = mountTestWindow();
  localStorage.removeItem(PANEL_QUICK_DRAWER_STORAGE_KEY);
});

afterEach(async () => {
  app?.dispose();
  app = null;
  await closeTestWindow(dom);
});

describe("Panel quick drawer fold (W2A-9b / P1-3)", () => {
  it("starts folded and remembers the last expanded state under the Windows key namespace", () => {
    const storage = memoryStorage();
    assert.equal(readPanelQuickDrawerExpanded(storage), false);

    assert.equal(togglePanelQuickDrawerExpanded(storage), true);
    assert.equal(storage.get(PANEL_QUICK_DRAWER_STORAGE_KEY), "1");
    assert.equal(readPanelQuickDrawerExpanded(storage), true);

    assert.equal(togglePanelQuickDrawerExpanded(storage), false);
    assert.equal(storage.has(PANEL_QUICK_DRAWER_STORAGE_KEY), false);
    assert.equal(readPanelQuickDrawerExpanded(storage), false);

    writePanelQuickDrawerExpanded(true, storage);
    assert.equal(readPanelQuickDrawerExpanded(storage), true);
    writePanelQuickDrawerExpanded(false, storage);
    assert.equal(readPanelQuickDrawerExpanded(storage), false);
  });

  it("renders one accessible 快捷 capsule in both Fluent and Classic shells, folded by default", () => {
    for (const panelTheme of ["fluent", "classic"] as const) {
      app?.dispose();
      app = null;
      localStorage.removeItem(PANEL_QUICK_DRAWER_STORAGE_KEY);
      startDemoApp(panelTheme);

      const toggle = element<HTMLButtonElement>("#btn-quick-drawer-toggle");
      assert.equal(toggle.getAttribute("aria-expanded"), "false");
      assert.match(toggle.getAttribute("aria-label") ?? "", /快捷操作与为你推荐/);
      assert.match(toggle.getAttribute("title") ?? "", /Ctrl\+K/);
      assert.equal(element("#app").dataset.quickDrawer, "collapsed");
      assert.equal(document.querySelectorAll("#btn-quick-drawer-toggle").length, 1);
    }
  });

  it("toggles with Ctrl+K, keeps focus on the capsule, and restores the persisted state on a new app instance", () => {
    startDemoApp();
    const collapsed = element<HTMLButtonElement>("#btn-quick-drawer-toggle");
    assert.equal(collapsed.getAttribute("aria-expanded"), "false");

    pressCtrlK();
    assert.equal(localStorage.getItem(PANEL_QUICK_DRAWER_STORAGE_KEY), "1");
    let toggle = element<HTMLButtonElement>("#btn-quick-drawer-toggle");
    assert.equal(toggle.getAttribute("aria-expanded"), "true");
    assert.equal(element("#app").dataset.quickDrawer, "expanded");
    assert.equal(document.activeElement?.id, "btn-quick-drawer-toggle");

    app?.dispose();
    app = null;
    startDemoApp();
    toggle = element<HTMLButtonElement>("#btn-quick-drawer-toggle");
    assert.equal(toggle.getAttribute("aria-expanded"), "true");

    pressCtrlK();
    assert.equal(localStorage.getItem(PANEL_QUICK_DRAWER_STORAGE_KEY), null);
    toggle = element<HTMLButtonElement>("#btn-quick-drawer-toggle");
    assert.equal(toggle.getAttribute("aria-expanded"), "false");
    assert.equal(document.activeElement?.id, "btn-quick-drawer-toggle");
  });

  it("does not steal Ctrl+K from form fields", () => {
    startDemoApp();
    element<HTMLInputElement>("#command-input").focus();
    pressCtrlK();
    assert.equal(localStorage.getItem(PANEL_QUICK_DRAWER_STORAGE_KEY), null);
    assert.equal(element<HTMLButtonElement>("#btn-quick-drawer-toggle").getAttribute("aria-expanded"), "false");
  });

  it("keeps a previously hidden quick bar hidden even when the drawer is expanded", () => {
    localStorage.setItem(PANEL_QUICK_DRAWER_STORAGE_KEY, "1");
    startDemoApp("fluent", { showQuickActionsBar: false });
    assert.equal(element<HTMLButtonElement>("#btn-quick-drawer-toggle").getAttribute("aria-expanded"), "true");
    assert.equal(document.querySelector(".cc-quick-strip"), null);
  });
});
