import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const result = document.querySelector<T>(selector);
  assert.ok(result, `Missing ${selector}`);
  return result;
}

beforeEach(() => {
  dom = mountTestWindow();
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
  );
});

afterEach(async () => {
  app?.dispose();
  app = null;
  await closeTestWindow(dom);
});

describe("Keyed DOM Reconciler & Fluent Motion Pipeline", () => {
  it("preserves tile and toggle button node identity and updates SVG icons in place across renders", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const tileBefore = element<HTMLElement>('[data-tile-id="light.study_desk"]');
    const toggleBtnBefore = element<HTMLButtonElement>('[data-toggle-device="light.study_desk"]');
    const appearanceBtnBefore = element<HTMLButtonElement>("#btn-toggle-appearance");
    const appearanceSvgBefore = appearanceBtnBefore.querySelector("svg");
    assert.ok(appearanceSvgBefore);
    const svgMarkupBefore = appearanceSvgBefore.innerHTML;

    toggleBtnBefore.click();
    await setImmediate();

    const tileAfter = element<HTMLElement>('[data-tile-id="light.study_desk"]');
    const toggleBtnAfter = element<HTMLButtonElement>('[data-toggle-device="light.study_desk"]');
    assert.ok(tileAfter === tileBefore);
    assert.ok(toggleBtnAfter === toggleBtnBefore);
    assert.equal(toggleBtnAfter.getAttribute("aria-pressed"), "false");

    appearanceBtnBefore.click();
    await setImmediate();

    const appearanceBtnAfter = element<HTMLButtonElement>("#btn-toggle-appearance");
    const appearanceSvgAfter = appearanceBtnAfter.querySelector("svg");
    assert.ok(appearanceBtnAfter === appearanceBtnBefore);
    assert.ok(appearanceSvgAfter === appearanceSvgBefore);
    assert.notEqual(appearanceSvgAfter?.innerHTML, svgMarkupBefore);
  });

  it("aborts previous render listeners via RenderEventScope so surviving controls fire once per click", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    let commandCount = 0;
    app.executeSingleCommand = async () => {
      commandCount += 1;
    };

    for (let i = 0; i < 6; i += 1) {
      app.render();
    }

    const toggleBtn = element<HTMLButtonElement>('[data-toggle-device="light.study_desk"]');
    toggleBtn.click();
    await setImmediate();
    assert.equal(commandCount, 1);
  });

  it("patches drag-to-dim preview in place without replacing .cc-popover children or detaching tiles", () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const popover = element<HTMLElement>(".cc-popover");
    const topIsland = element<HTMLElement>(".win-island--top");
    const bottomIsland = element<HTMLElement>(".win-island--bottom");
    const tile = element<HTMLElement>('[data-tile-id="light.living_ceiling"]');

    let detached = false;
    const nodeProto = (window as unknown as { Node: typeof Node }).Node.prototype;
    const origRemoveChild = nodeProto.removeChild;
    nodeProto.removeChild = function <T extends Node>(child: T): T {
      if ((child as Node) === tile || child.contains(tile)) {
        detached = true;
      }
      return origRemoveChild.call(this, child) as T;
    };

    try {
      app.dimPreview = { id: "light.living_ceiling", percent: 42 };
      app.pipeline.patchDimPreview(app, "light.living_ceiling", 42);
    } finally {
      nodeProto.removeChild = origRemoveChild;
    }

    assert.equal(detached, false);
    assert.ok(element(".cc-popover") === popover);
    assert.ok(element(".win-island--top") === topIsland);
    assert.ok(element(".win-island--bottom") === bottomIsland);
    assert.ok(element('[data-tile-id="light.living_ceiling"]') === tile);
    assert.equal(tile.classList.contains("is-dimming"), true);
    assert.match(
      tile.querySelector(".win-split-pill .cc-tile-fill")?.getAttribute("style") ?? "",
      /width:42%/,
    );
    assert.equal(tile.querySelector(".cc-tile-status")?.textContent, "42%");
  });

  it("mounts sanitized DepartureGhost when WAAPI returns finished Promise, cleans up on resolve, and leaves zero ghosts on bare mocks", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const proto = window.HTMLElement.prototype as HTMLElement & {
      animate?: typeof HTMLElement.prototype.animate;
    };
    const origAnimate = proto.animate;

    const resolvers: Array<() => void> = [];
    proto.animate = function mockPromiseAnimate() {
      const target = this as HTMLElement;
      if (target.hasAttribute("data-exit-ghost")) {
        return {
          finished: new Promise<Animation>((resolve) => {
            resolvers.push(() => resolve({} as Animation));
          }),
          cancel() {},
        } as unknown as Animation;
      }
      return {} as Animation;
    };

    try {
      element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
      await setImmediate();
      assert.ok(document.querySelector(".cc-tile.is-subpage"));

      element<HTMLButtonElement>('.cc-tile.is-subpage [data-expand-device="light.living_ceiling"]').click();
      await setImmediate();

      const subpageGhost = document.querySelector<HTMLElement>("[data-exit-ghost]");
      assert.ok(subpageGhost);
      assert.equal(subpageGhost.hasAttribute("inert"), true);
      assert.equal(subpageGhost.getAttribute("aria-hidden"), "true");
      assert.equal(subpageGhost.hasAttribute("id"), false);
      assert.equal(subpageGhost.hasAttribute("data-tile-id"), false);
      assert.equal(subpageGhost.querySelector("[id]"), null);
      assert.equal(subpageGhost.querySelector("[data-tile-id]"), null);
      assert.equal(subpageGhost.classList.contains("is-subpage-ghost"), true);
      assert.equal(subpageGhost.classList.contains("is-subpage"), false);

      while (resolvers.length > 0) {
        resolvers.shift()?.();
      }
      await setImmediate();
      assert.equal(document.querySelectorAll("[data-exit-ghost]").length, 0);

      element<HTMLButtonElement>("#btn-settings").click();
      await setImmediate();
      assert.ok(document.querySelector(".cc-settings-sheet"));

      element<HTMLButtonElement>("#btn-close-settings").click();
      await setImmediate();

      const sheetGhost = document.querySelector<HTMLElement>("[data-exit-ghost]");
      assert.ok(sheetGhost);
      assert.equal(sheetGhost.classList.contains("cc-settings-sheet-ghost"), true);
      assert.equal(sheetGhost.classList.contains("cc-settings-sheet"), false);

      while (resolvers.length > 0) {
        resolvers.shift()?.();
      }
      await setImmediate();
      assert.equal(document.querySelectorAll("[data-exit-ghost]").length, 0);

      proto.animate = () => ({}) as Animation;
      element<HTMLButtonElement>("#btn-settings").click();
      await setImmediate();
      element<HTMLButtonElement>("#btn-close-settings").click();
      assert.equal(document.querySelectorAll("[data-exit-ghost]").length, 0);
    } finally {
      proto.animate = origAnimate!;
    }
  });

  it("animates camera warm-standby hide without detaching #cc-camera-live-img and cancels cleanly if reopened mid-exit", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    app.cameraLive.cameraStreamURLs = {
      "camera.living_cam": "https://localhost:8443/snapshot.jpg",
    };
    const proto = window.HTMLElement.prototype as HTMLElement & {
      animate?: typeof HTMLElement.prototype.animate;
    };
    const origAnimate = proto.animate;
    const resolvers: Array<() => void> = [];
    let cancelled = 0;

    proto.animate = function mockCameraAnimate() {
      const target = this as HTMLElement;
      if (target.classList.contains("cc-camera-live-sheet")) {
        return {
          finished: new Promise<Animation>((resolve) => {
            resolvers.push(() => resolve({} as Animation));
          }),
          cancel() {
            cancelled += 1;
          },
        } as unknown as Animation;
      }
      return {} as Animation;
    };

    try {
      element<HTMLElement>('[data-body-device="camera.living_cam"]').click();
      await setImmediate();
      resolvers.length = 0;

      const imgBefore = element<HTMLImageElement>("#cc-camera-live-img");
      const backdrop = element<HTMLElement>(".cc-camera-live-sheet").closest<HTMLElement>(
        ".cc-sheet-backdrop",
      )!;
      assert.equal(backdrop.style.display, "");

      element<HTMLButtonElement>("#btn-close-camera-live").click();
      await setImmediate();
      assert.equal(backdrop.style.display, "");
      assert.ok(element("#cc-camera-live-img") === imgBefore);

      element<HTMLElement>('[data-body-device="camera.living_cam"]').click();
      await setImmediate();
      assert.equal(cancelled >= 1, true);
      assert.equal(backdrop.style.display, "");
      assert.ok(element("#cc-camera-live-img") === imgBefore);

      resolvers.length = 0;
      element<HTMLButtonElement>("#btn-close-camera-live").click();
      await setImmediate();
      assert.equal(backdrop.style.display, "");
      while (resolvers.length > 0) {
        resolvers.shift()?.();
      }
      await setImmediate();
      assert.equal(backdrop.style.display, "none");
      assert.ok(element("#cc-camera-live-img") === imgBefore);
    } finally {
      proto.animate = origAnimate!;
    }
  });

  it("restores focus to opener trigger when closing Settings sheet and L2 device subpage, and exits layout edit mode from Top Island chip", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));

    const settingsBtn = element<HTMLButtonElement>("#btn-settings");
    settingsBtn.focus();
    settingsBtn.click();
    await setImmediate();
    assert.equal(app.activeSheet, "settings");

    element<HTMLButtonElement>("#btn-close-settings").click();
    await setImmediate();
    assert.equal(app.activeSheet, "none");
    assert.ok(document.activeElement === element("#btn-settings"));

    const expandBtn = element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]');
    expandBtn.focus();
    expandBtn.click();
    await setImmediate();
    assert.equal(app.expandedDeviceId, "light.living_ceiling");

    element<HTMLButtonElement>('.cc-tile.is-subpage [data-expand-device="light.living_ceiling"]').click();
    await setImmediate();
    assert.equal(app.expandedDeviceId, null);
    assert.ok(
      document.activeElement === element('[data-expand-device="light.living_ceiling"]'),
    );

    app.isEditingLayout = true;
    app.render();
    const doneChip = element<HTMLButtonElement>('.cc-header-controls [data-done-editing="true"]');
    assert.ok(document.querySelector("#btn-done-editing"));
    doneChip.click();
    await setImmediate();
    assert.equal(app.isEditingLayout, false);
  });

  it("deduplicates set_panel_height IPC across repeated menumijia:panel-present events and syncs <html lang>", async () => {
    const heightCalls: number[] = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (cmd: string, args?: { height?: number }) => {
          if (cmd === "set_panel_height" && typeof args?.height === "number") {
            heightCalls.push(args.height);
          }
          if (cmd === "panel_is_visible") return true;
          if (cmd === "panel_backdrop") return "acrylic";
          if (cmd === "panel_placement") return "auto";
          return null;
        },
      },
      configurable: true,
    });

    app = new MenuMijiaWindowsApp(element("#app"));
    await app.panelGeometryUpdates;
    assert.equal(heightCalls.length, 1);

    app.applyPanelHeight();
    await app.panelGeometryUpdates;
    assert.equal(heightCalls.length, 1);

    window.dispatchEvent(new window.CustomEvent("menumijia:panel-present", { detail: { edge: "bottom" } }));
    window.dispatchEvent(new window.CustomEvent("menumijia:panel-present", { detail: { edge: "bottom" } }));
    await app.panelGeometryUpdates;
    assert.equal(heightCalls.length, 2);

    Object.defineProperty(window, "devicePixelRatio", { value: 2, configurable: true });
    app.applyPanelHeight();
    await app.panelGeometryUpdates;
    assert.equal(heightCalls.length, 3);

    app.settings.panelHeight = "tall";
    app.applyPanelHeight();
    await app.panelGeometryUpdates;
    assert.equal(heightCalls.length, 4);

    app.settings.interfaceLanguage = "zh-Hans";
    app.applyInterfaceLanguage();
    assert.equal(document.documentElement.lang, "zh-CN");

    app.settings.interfaceLanguage = "zh-Hant";
    app.applyInterfaceLanguage();
    assert.equal(document.documentElement.lang, "zh-TW");

    app.settings.interfaceLanguage = "en";
    app.applyInterfaceLanguage();
    assert.equal(document.documentElement.lang, "en");

    window.dispatchEvent(new window.CustomEvent("menumijia:activate"));
    assert.ok(document.activeElement === element("#command-input"));

    app.openSettingsSheet("connection");
    const haUrlField = element<HTMLInputElement>("#settings-ha-url");
    haUrlField.focus();
    window.dispatchEvent(new window.CustomEvent("menumijia:activate"));
    assert.equal(document.activeElement, haUrlField);
  });
});
