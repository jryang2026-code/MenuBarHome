import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  DEFAULT_PANEL_THEME,
  PANEL_THEMES,
  PANEL_THEME_PROFILES,
  getPanelThemeProfile,
  nextSizeForTheme,
  normalizePanelTheme,
  resolveTilePresentation,
} from "../src/ui/panelTheme.js";
import { loadSettings, writeSettingsForStorage } from "../src/ui/settings.js";
import { hasUnsavedSettingsChanges, hasUnsavedSettingsDraft } from "../src/ui/settingsEvents.js";
import { resolveSettingsAnchorTab, searchSettings } from "../src/ui/settingsSearch.js";
import { buildInactiveTabCacheKey, type SettingsViewContext } from "../src/ui/settingsViews.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function installDom(): void {
  dom = new Window({ url: "http://localhost:5173/" });
  Object.assign(globalThis as Record<string, unknown>, {
    window: dom, document: dom.document, localStorage: dom.localStorage,
    HTMLElement: dom.HTMLElement, HTMLInputElement: dom.HTMLInputElement,
    HTMLSelectElement: dom.HTMLSelectElement, HTMLTextAreaElement: dom.HTMLTextAreaElement,
    HTMLButtonElement: dom.HTMLButtonElement, Element: dom.Element, Node: dom.Node,
    Event: dom.Event, CustomEvent: dom.CustomEvent, KeyboardEvent: dom.KeyboardEvent,
    MouseEvent: dom.MouseEvent, PointerEvent: dom.PointerEvent ?? dom.MouseEvent,
    CSS: { escape: (v: string) => v.replace(/["\\]/g, "\\$&") },
  });
  dom.document.body.innerHTML = `<div id="app"></div>`;
}

describe("PanelTheme profile domain, persistence, Settings UI, and dynamic 472px geometry", () => {
  beforeEach(() => { installDom(); localStorage.clear(); setLanguage("zh-Hans"); });
  afterEach(() => { app = null; try { dom.happyDOM?.cancelAsync?.(); } catch {} });

  it("normalizes unknown values to 'fluent' and exposes 412px Fluent & 472px Classic profiles", () => {
    assert.deepEqual(PANEL_THEMES, ["fluent", "classic"]);
    assert.equal(DEFAULT_PANEL_THEME, "fluent");
    for (const bad of [undefined, null, "", "invalid-theme", 42]) assert.equal(normalizePanelTheme(bad), "fluent");
    assert.equal(normalizePanelTheme("fluent"), "fluent");
    assert.equal(normalizePanelTheme("classic"), "classic");

    const fluent = getPanelThemeProfile("fluent");
    assert.equal(fluent, PANEL_THEME_PROFILES.fluent);
    assert.equal(fluent.mainWidthPx, 380);
    assert.equal(fluent.windowWidthPx, 412);
    assert.equal(fluent.shellLayout, "dualIsland");
    assert.equal(fluent.showsBottomSliderDeck, true);

    const classic = getPanelThemeProfile("classic");
    assert.equal(classic, PANEL_THEME_PROFILES.classic);
    assert.equal(classic.mainWidthPx, 440);
    assert.equal(classic.windowWidthPx, 472);
    assert.equal(classic.shellLayout, "unifiedPopover");
    assert.equal(classic.drawerPresentation, "inlineAccordion");
    assert.equal(classic.tileChrome, "classicBento");
    assert.equal(classic.sliderChrome, "liquidGlassPill");
    assert.equal(classic.tabIndicator, "glassCapsule");
    assert.equal(classic.motionFamily, "appleSpring");
    assert.equal(classic.showsBottomSliderDeck, false);
  });

  it("resolves Bento tile presentations across small, half, hero, full, and panel in both themes", () => {
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "small", isExpanded: false, hasDrawer: true }), { mode: "smallOrb", cssColumnSpan: 3, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "small", isExpanded: false, hasDrawer: true }), { mode: "smallOrb", cssColumnSpan: 3, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false });
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "half", isExpanded: false, hasDrawer: true }), { mode: "fluentCapsule", cssColumnSpan: 4, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false });
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "half", isExpanded: true, hasDrawer: true }), { mode: "fluentSubpage", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: true, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "hero", isExpanded: false, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "full", isExpanded: false, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "fluent", size: "panel", isExpanded: true, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "half", isExpanded: false, hasDrawer: true }), { mode: "bentoCard", cssColumnSpan: 6, cssRowSpan: 1, mountsSubpage: false, spansFullRow: false });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "hero", isExpanded: false, hasDrawer: true }), { mode: "bentoHero", cssColumnSpan: 6, cssRowSpan: 2, mountsSubpage: false, spansFullRow: false });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "full", isExpanded: false, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "panel", isExpanded: false, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(resolveTilePresentation({ theme: "classic", size: "half", isExpanded: true, hasDrawer: true }), { mode: "bentoFull", cssColumnSpan: 12, cssRowSpan: 1, mountsSubpage: false, spansFullRow: true });
    assert.deepEqual(["small", "half", "hero", "full", "panel"].map((s) => nextSizeForTheme(s as "small", "classic")), ["half", "hero", "full", "panel", "small"]);
    assert.deepEqual(["half", "full", "panel"].map((s) => nextSizeForTheme(s as "half", "fluent")), ["full", "panel", "half"]);
  });

  it("persists panelTheme in menumijia.windows.settings.v2 with 'fluent' default and corrupt fallback", () => {
    const initial = loadSettings();
    assert.equal(initial.settings.panelTheme, "fluent");
    writeSettingsForStorage({ ...initial.settings, panelTheme: "classic" });
    assert.equal(loadSettings().settings.panelTheme, "classic");
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...initial.settings, panelTheme: "corrupt-value" }));
    assert.equal(loadSettings().settings.panelTheme, "fluent");
  });

  it("deduplicates set_panel_geometry IPC across boot, theme switches, height changes, DPR, and panel-present", async () => {
    const geometryCalls: Array<{ theme: string; height: number }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: { theme?: string; height?: number }) => {
          if (cmd === "set_panel_geometry" && typeof args?.theme === "string" && typeof args?.height === "number") {
            geometryCalls.push({ theme: args.theme, height: args.height });
            return true;
          }
          if (cmd === "panel_is_visible") return true;
          if (cmd === "panel_placement") return { anchor: "auto" };
          return null;
        },
      },
      configurable: true,
    });

    const root = document.querySelector<HTMLElement>("#app")!;
    app = new MenuMijiaWindowsApp(root);
    await app.panelGeometryUpdates;
    assert.equal(root.dataset.panelTheme, "fluent");
    assert.deepEqual(geometryCalls, [{ theme: "fluent", height: 680 }]);

    app.syncPanelGeometry();
    app.applyPanelHeight();
    await app.panelGeometryUpdates;
    assert.equal(geometryCalls.length, 1);

    app.setPanelTheme("classic");
    await app.panelGeometryUpdates;
    assert.equal(root.dataset.panelTheme, "classic");
    assert.equal(loadSettings().settings.panelTheme, "classic");
    assert.deepEqual(geometryCalls.at(-1), { theme: "classic", height: 680 });
    assert.equal(geometryCalls.length, 2);

    app.setPanelTheme("classic");
    await app.panelGeometryUpdates;
    assert.equal(geometryCalls.length, 2);

    Object.defineProperty(window, "devicePixelRatio", { value: 1.5, configurable: true });
    app.syncPanelGeometry();
    await app.panelGeometryUpdates;
    assert.equal(geometryCalls.length, 3);

    window.dispatchEvent(new window.CustomEvent("menumijia:panel-present", { detail: { edge: "bottom" } }));
    window.dispatchEvent(new window.CustomEvent("menumijia:panel-present", { detail: { edge: "bottom" } }));
    await app.panelGeometryUpdates;
    assert.equal(geometryCalls.length, 4);
  });

  it("toggles panelTheme via Settings UI, invalidates inactive tab cache, and preserves unsaved text drafts", () => {
    const root = document.querySelector<HTMLElement>("#app")!;
    app = new MenuMijiaWindowsApp(root);
    app.openSettingsSheet("connection");

    const haUrlInput = root.querySelector<HTMLInputElement>("#settings-ha-url")!;
    haUrlInput.value = "http://192.168.1.99:8123";
    haUrlInput.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(hasUnsavedSettingsDraft(app), true);

    const fluentTabKey = buildInactiveTabCacheKey(app as unknown as SettingsViewContext, "general");
    app.settings.panelTheme = "classic";
    assert.notEqual(fluentTabKey, buildInactiveTabCacheKey(app as unknown as SettingsViewContext, "general"));
    app.settings.panelTheme = "fluent";

    root.querySelector<HTMLElement>('[data-settings-tab="general"]')!.click();
    const anchorEl = root.querySelector<HTMLElement>('[data-settings-anchor="panelTheme"]')!;
    assert.equal(anchorEl.querySelector('[data-panel-theme="fluent"]')?.getAttribute("aria-pressed"), "true");
    anchorEl.querySelector<HTMLElement>('[data-panel-theme="classic"]')!.click();

    assert.equal(app.settings.panelTheme, "classic");
    assert.equal(root.dataset.panelTheme, "classic");
    assert.equal(loadSettings().settings.panelTheme, "classic");
    assert.equal(loadSettings().settings.haBaseURL, "");
    assert.equal(root.querySelector('[data-panel-theme="classic"]')?.getAttribute("aria-pressed"), "true");
    assert.equal(root.querySelector<HTMLInputElement>("#settings-ha-url")?.value, "http://192.168.1.99:8123");
    assert.equal(hasUnsavedSettingsDraft(app), true);
    assert.equal(hasUnsavedSettingsChanges(app), true);
    assert.equal(root.querySelector(".cc-settings-save-hint")?.getAttribute("data-save-state"), "dirty");
  });

  it("indexes panelTheme in settingsSearch across zh-Hans and en", () => {
    assert.equal(resolveSettingsAnchorTab("panelTheme", false), "general");
    assert.ok(searchSettings("面板风格", undefined, undefined, "zh-Hans").hits.some((h) => h.anchor === "panelTheme" && h.tab === "general"));
    assert.ok(searchSettings("控制中心", undefined, undefined, "zh-Hans").hits.some((h) => h.anchor === "panelTheme"));
    assert.ok(searchSettings("macOS Control Center", undefined, undefined, "en").hits.some((h) => h.anchor === "panelTheme" && h.tab === "general"));
    assert.ok(searchSettings("Panel Style", undefined, undefined, "en").hits.some((h) => h.anchor === "panelTheme"));
  });
});
