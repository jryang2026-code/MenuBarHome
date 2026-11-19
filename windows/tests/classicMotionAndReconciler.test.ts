import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { APPLE_SPRINGS, buildSpringTranslateKeyframes, formatSpringCssLinear, sampleSpringProgress } from "../src/ui/motionSpring.js";
import { syncSlidingTabIndicators } from "../src/ui/reconciler.js";
import { showSettingsTab } from "../src/ui/settingsEvents.js";
import { SCENARIOS, evaluateSnapshot } from "../scripts/verify-flyout-layout.mjs";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const result = document.querySelector<T>(selector);
  assert.ok(result, `Missing ${selector}`);
  return result;
}

function makeRect(left: number, top: number, width: number, height: number): DOMRect {
  return { x: left, y: top, left, top, width, height, right: left + width, bottom: top + height, toJSON: () => ({}) } as DOMRect;
}

beforeEach(() => { dom = mountTestWindow(); });
afterEach(async () => { app?.dispose(); app = null; await closeTestWindow(dom); });

describe("Apple Spring Physics, Reconciler Motion Upgrades & Dual-Theme CDP Snapshot Gate", () => {
  it("converges analytical spring samples and translate3d keyframes within physical overshoot bounds", () => {
    assert.deepEqual(APPLE_SPRINGS.snappy, { responseSec: 0.26, dampingFraction: 0.94, durationMs: 280 });
    assert.deepEqual(APPLE_SPRINGS.control, { responseSec: 0.24, dampingFraction: 0.86, durationMs: 280 });
    assert.deepEqual(APPLE_SPRINGS.reveal, { responseSec: 0.34, dampingFraction: 0.86, durationMs: 380 });
    assert.deepEqual(APPLE_SPRINGS.glassLens, { responseSec: 0.20, dampingFraction: 0.88, durationMs: 220 });
    assert.deepEqual(APPLE_SPRINGS.stack, { responseSec: 0.38, dampingFraction: 0.84, durationMs: 420 });
    assert.deepEqual(APPLE_SPRINGS.orbBounce, { responseSec: 0.30, dampingFraction: 0.68, durationMs: 360 });

    for (const [name, spec] of Object.entries(APPLE_SPRINGS)) {
      const samples = sampleSpringProgress(spec, 17);
      assert.equal(samples.length, 17);
      assert.equal(samples[0], 0);
      assert.equal(samples[samples.length - 1], 1);
      const peak = Math.max(...samples);
      if (name === "orbBounce") assert.ok(peak > 1.03 && peak < 1.15);
      else if (name === "snappy") assert.ok(peak <= 1.01);
      else assert.ok(peak >= 1 && peak <= 1.02);
      const cssLinear = formatSpringCssLinear(spec, 17);
      assert.ok(cssLinear.startsWith("linear(0, ") && cssLinear.endsWith(", 1)"));
      assert.equal(/\bease\b/i.test(cssLinear), false);
    }
    const frames = buildSpringTranslateKeyframes(-80, 120, APPLE_SPRINGS.reveal, 17);
    assert.equal(frames[0]?.transform, "translate3d(-80px, 120px, 0)");
    assert.equal(frames[frames.length - 1]?.transform, "translate3d(0px, 0px, 0)");
  });

  it("FLIP-animates sibling tiles and groups with APPLE_SPRINGS.reveal in classic while skipping sibling FLIP on fluent subpage", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    const proto = window.HTMLElement.prototype as HTMLElement & { animate?: typeof HTMLElement.prototype.animate };
    const origAnimate = proto.animate, origGetRect = proto.getBoundingClientRect;
    const recorded: Array<{ el: HTMLElement; keyframes: Keyframe[]; options: KeyframeAnimationOptions }> = [];
    const activeGroupTransform = new Map<HTMLElement, { dx: number; dy: number }>();

    proto.animate = function captureAnimate(keyframes, options) {
      const frames = (Array.isArray(keyframes) ? keyframes : []) as Keyframe[];
      const el = this as HTMLElement;
      recorded.push({ el, keyframes: frames, options: (typeof options === "object" && options ? options : {}) as KeyframeAnimationOptions });
      if (el.classList.contains("cc-group")) {
        const m = String(frames[0]?.transform ?? "").match(/translate3d\(([-\d.]+)px,\s*([-\d.]+)px/);
        if (m) activeGroupTransform.set(el, { dx: Number(m[1]), dy: Number(m[2]) });
      }
      return {} as Animation;
    };
    proto.getBoundingClientRect = function mockFlipRect() {
      const el = this as HTMLElement;
      const expanded = Boolean(document.querySelector('[data-tile-id="light.living_ceiling"].is-expanded'));
      const parentGroup = el.hasAttribute("data-tile-id") ? el.closest<HTMLElement>(".cc-group") : null;
      const groupOffset = parentGroup ? activeGroupTransform.get(parentGroup) : undefined;
      const ox = groupOffset?.dx ?? 0, oy = groupOffset?.dy ?? 0;
      if (el.dataset.tileId === "light.living_ceiling") return makeRect(14 + ox, 120 + oy, expanded ? 412 : 202, expanded ? 220 : 72);
      if (el.dataset.tileId === "light.study_desk") return makeRect(14 + ox, (expanded ? 348 : 200) + oy, 202, 72);
      if (el.dataset.tileId === "plug.entry_socket") return makeRect(14 + ox, (expanded ? 548 : 408) + oy, 202, 72);
      if (el.classList.contains("cc-group")) {
        const idx = Array.from(document.querySelectorAll(".cc-group")).indexOf(el);
        return idx > 0 ? makeRect(14, expanded ? 520 : 380, 412, 140) : makeRect(14, 96, 412, expanded ? 340 : 200);
      }
      return makeRect(14 + ox, 14 + oy, 200, 60);
    };

    try {
      app = new MenuMijiaWindowsApp(element("#app"));
      app.layout.pinnedDeviceIds = ["light.living_ceiling", "light.study_desk"];
      app.render();
      recorded.length = 0;
      activeGroupTransform.clear();

      element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
      await setImmediate();

      const siblingAnim = recorded.find((r) => r.el.dataset.tileId === "light.study_desk");
      assert.ok(siblingAnim);
      assert.equal(siblingAnim.options.duration, APPLE_SPRINGS.reveal.durationMs);
      assert.equal(siblingAnim.options.easing, "linear");
      assert.equal(siblingAnim.keyframes[0]?.transform, "translate3d(0px, -148px, 0)");
      assert.ok(recorded.some((r) => r.el.classList.contains("cc-group") && r.options.duration === APPLE_SPRINGS.reveal.durationMs));
      assert.equal(recorded.some((r) => r.el.dataset.tileId === "plug.entry_socket"), false);

      app.expandedDeviceId = null;
      app.settings.panelTheme = "fluent";
      app.render();
      recorded.length = 0;

      element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
      await setImmediate();
      assert.ok(document.querySelector(".cc-tile.is-subpage"));
      assert.equal(recorded.some((r) => r.el.hasAttribute("data-tile-id") && !r.el.classList.contains("is-subpage")), false);
    } finally {
      proto.animate = origAnimate!;
      proto.getBoundingClientRect = origGetRect;
    }
  });

  it("retains an inert .cc-expander-grid.is-collapsed clone on classic collapse and removes on transitionend or 420ms safety timeout", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    app = new MenuMijiaWindowsApp(element("#app"));
    const tile = element('[data-tile-id="light.living_ceiling"]');

    element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
    await setImmediate();
    element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
    await setImmediate();

    const ghostExpander = tile.querySelector<HTMLElement>(":scope > .cc-expander-grid.is-collapsed");
    assert.ok(ghostExpander);
    assert.equal(ghostExpander.getAttribute("data-exit-ghost"), "true");
    assert.equal(ghostExpander.style.transition, "");
    assert.equal(ghostExpander.hasAttribute("inert"), true);
    assert.equal(ghostExpander.getAttribute("aria-hidden"), "true");
    assert.equal(ghostExpander.querySelector("[id], [data-brightness]"), null);
    const cssText = readFileSync(new URL("../src/ui/styles.css", import.meta.url), "utf8");
    assert.match(cssText, /\.cc-expander-grid:not\(\.is-collapsed\):not\(\[data-exit-ghost\]\)/);
    assert.match(cssText, /#app\[data-panel-theme="classic"\] \.cc-expander-grid:not\(\.is-collapsed\):not\(\[data-exit-ghost\]\)/);

    ghostExpander.dispatchEvent(Object.assign(new window.Event("transitionend", { bubbles: true }), { propertyName: "opacity" }));
    assert.ok(tile.querySelector(":scope > .cc-expander-grid.is-collapsed"));

    ghostExpander.dispatchEvent(Object.assign(new window.Event("transitionend", { bubbles: true }), { propertyName: "grid-template-rows" }));
    assert.equal(tile.querySelector(".cc-expander-grid"), null);

    element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
    await setImmediate();
    element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
    await setImmediate();
    assert.ok(tile.querySelector(":scope > .cc-expander-grid.is-collapsed"));
    await new Promise((resolve) => setTimeout(resolve, 450));
    assert.equal(tile.querySelector(".cc-expander-grid"), null);
  });

  it("updates --tab-x and --tab-w via syncSlidingTabIndicators across room, kind, and settings tab tracks", () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    app = new MenuMijiaWindowsApp(element("#app"));
    app.openSettingsSheet("general");

    const roomTrack = element<HTMLElement>(".cc-room-bar .cc-room-scroll");
    Array.from(roomTrack.querySelectorAll<HTMLElement>(".cc-room-pill")).forEach((pill, i) => {
      Object.defineProperty(pill, "offsetLeft", { value: i * 64 + 4, configurable: true });
      Object.defineProperty(pill, "offsetWidth", { value: 56, configurable: true });
    });
    roomTrack.querySelectorAll<HTMLElement>(".cc-room-pill")[1]?.click();
    assert.equal(roomTrack.getAttribute("data-sliding-indicator"), "ready");
    assert.equal(roomTrack.style.getPropertyValue("--tab-x"), "68px");
    assert.equal(roomTrack.style.getPropertyValue("--tab-w"), "56px");

    const settingsTrack = element<HTMLElement>(".cc-settings-tabs");
    Array.from(settingsTrack.querySelectorAll<HTMLElement>(".cc-seg-pill")).forEach((pill, i) => {
      Object.defineProperty(pill, "offsetLeft", { value: i * 96, configurable: true });
      Object.defineProperty(pill, "offsetWidth", { value: 90, configurable: true });
    });
    showSettingsTab(app.root, "assistant");
    assert.equal(settingsTrack.style.getPropertyValue("--tab-x"), "192px");
    assert.equal(settingsTrack.style.getPropertyValue("--tab-w"), "90px");

    const kindTrack = document.createElement("div");
    kindTrack.className = "cc-room-scroll cc-kind-scroll";
    kindTrack.innerHTML = '<button class="cc-room-pill is-kind">灯</button><button class="cc-room-pill is-kind is-active">空调</button>';
    const activeKind = kindTrack.querySelector<HTMLElement>(".is-active")!;
    Object.defineProperty(activeKind, "offsetLeft", { value: 52, configurable: true });
    Object.defineProperty(activeKind, "offsetWidth", { value: 48, configurable: true });
    syncSlidingTabIndicators(kindTrack);
    assert.equal(kindTrack.style.getPropertyValue("--tab-x"), "52px");
    assert.equal(kindTrack.style.getPropertyValue("--tab-w"), "48px");
  });

  it("animates origin-aware .cc-sheet from trigger DOMRect using APPLE_SPRINGS.snappy in classic and --ease-decelerate in fluent", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    const proto = window.HTMLElement.prototype as HTMLElement & { animate?: typeof HTMLElement.prototype.animate };
    const origAnimate = proto.animate, origGetRect = proto.getBoundingClientRect;
    const sheetCalls: Array<{ keyframes: Keyframe[]; options: KeyframeAnimationOptions }> = [];

    proto.animate = function captureSheetAnimate(keyframes, options) {
      if ((this as HTMLElement).classList.contains("cc-settings-sheet")) {
        sheetCalls.push({ keyframes: (Array.isArray(keyframes) ? keyframes : []) as Keyframe[], options: (typeof options === "object" && options ? options : {}) as KeyframeAnimationOptions });
      }
      return {} as Animation;
    };
    proto.getBoundingClientRect = function mockOriginRect() {
      const el = this as HTMLElement;
      if (el.id === "btn-settings") return makeRect(400, 620, 32, 32);
      if (el.classList.contains("cc-settings-sheet")) return makeRect(36, 60, 400, 560);
      return makeRect(16, 16, 440, 648);
    };

    try {
      app = new MenuMijiaWindowsApp(element("#app"));
      sheetCalls.length = 0;
      element<HTMLButtonElement>("#btn-settings").click();
      await setImmediate();
      assert.equal(sheetCalls[0]?.options.duration, APPLE_SPRINGS.snappy.durationMs);
      assert.equal(sheetCalls[0]?.options.easing, "linear");
      assert.equal(sheetCalls[0]?.keyframes[0]?.transform, "translate3d(32.4px, 53.28px, 0) scale(0.94)");
      assert.equal(sheetCalls[0]?.keyframes[sheetCalls[0].keyframes.length - 1]?.transform, "translate3d(0px, 0px, 0) scale(1)");

      element<HTMLButtonElement>("#btn-close-settings").click();
      await setImmediate();
      app.settings.panelTheme = "fluent";
      app.render();
      sheetCalls.length = 0;
      element<HTMLButtonElement>("#btn-settings").click();
      await setImmediate();
      assert.equal(sheetCalls[0]?.options.easing, "cubic-bezier(0, 0, 0, 1)");
      assert.equal(sheetCalls[0]?.keyframes[0]?.transform, "translate3d(32.4px, 53.28px, 0) scale(0.94)");
    } finally {
      proto.animate = origAnimate!;
      proto.getBoundingClientRect = origGetRect;
    }
  });

  it("validates both fluent (412px) and classic (472px) flyout layout snapshots in evaluateSnapshot", () => {
    const fluentScenarios = SCENARIOS.filter((s: { panelTheme?: string }) => s.panelTheme !== "classic");
    const classicScenarios = SCENARIOS.filter((s: { panelTheme?: string }) => s.panelTheme === "classic");
    assert.equal(fluentScenarios.length, 10);
    assert.equal(classicScenarios.length, 10);

    const fluentSub = fluentScenarios.find((s: { view: string }) => s.view === "subpage")!;
    assert.deepEqual(evaluateSnapshot({
      scenarioId: fluentSub.id, locationScenario: fluentSub.id, readyState: "complete", schemeLight: fluentSub.appearance === "light",
      isNativeHost: true, isParked: false, errors: [],
      appRect: { left: 0, top: 0, right: 412, bottom: fluentSub.height, width: 412, height: fluentSub.height },
      popoverRect: { left: 16, top: 16, right: 396, bottom: fluentSub.height - 16, width: 380, height: fluentSub.height - 32 },
      islands: [{ className: "win-island win-island--bottom", left: 16, top: 180, right: 396, bottom: fluentSub.height - 16, width: 380, height: 460 }],
      documentElementScrollWidth: 412, chromeLabels: [], scrollAreaHeight: 260,
      subpage: { mounted: true, hiddenControls: { "#command-input": { width: 0, height: 0, display: "none" } }, visibleSiblingTileCount: 0, backButton: { left: 28, top: 196, right: 60, bottom: 228, width: 32, height: 32 } },
    }, fluentSub), []);

    const classicDrawer = classicScenarios.find((s: { view: string }) => s.view === "drawer")!;
    const validClassic = {
      scenarioId: classicDrawer.id, locationScenario: classicDrawer.id, readyState: "complete", panelThemeAttr: "classic",
      isUnifiedPopover: true, schemeLight: classicDrawer.appearance === "light", isNativeHost: true, isParked: false, errors: [],
      appRect: { left: 0, top: 0, right: 472, bottom: classicDrawer.height, width: 472, height: classicDrawer.height },
      popoverRect: { left: 16, top: 16, right: 456, bottom: classicDrawer.height - 16, width: 440, height: classicDrawer.height - 32 },
      islandDomCount: 0, islands: [], liquidSliders: [{ left: 30, top: 320, right: 440, bottom: 348, width: 410, height: 28 }],
      documentElementScrollWidth: 472, scrollAreaOverflowX: false, chromeLabels: [], scrollAreaHeight: 280,
      drawer: { mounted: true, isExpanded: true, subpageCount: 0, visibleSiblingTileCount: 8 },
    };
    assert.deepEqual(evaluateSnapshot(validClassic, classicDrawer), []);
    const broken = evaluateSnapshot({ ...validClassic, islandDomCount: 2, liquidSliders: [{ left: 30, top: 320, right: 440, bottom: 338, width: 410, height: 18 }], drawer: { mounted: true, isExpanded: true, subpageCount: 1, visibleSiblingTileCount: 0 } }, classicDrawer);
    assert.equal(["zero .win-island", ">= 24px", ".is-subpage", "sibling tiles"].every((token) => broken.some((m: string) => m.includes(token))), true);
  });
});
