import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";

const stylesPath = resolve(process.cwd(), "src/ui/styles.css");
const stylesCss = readFileSync(stylesPath, "utf8");

interface CssTokenSpec {
  readonly name: string;
  readonly expectedValue: string;
}

const FLUENT_ROOT_TOKENS: readonly CssTokenSpec[] = [
  { name: "--r-flyout", expectedValue: "12px" },
  { name: "--r-card", expectedValue: "8px" },
  { name: "--r-control", expectedValue: "4px" },
  { name: "--r-pill", expectedValue: "999px" },
  { name: "--dur-instant", expectedValue: "0ms" },
  { name: "--dur-ultra-fast", expectedValue: "50ms" },
  { name: "--dur-faster", expectedValue: "83ms" },
  { name: "--dur-exit-short", expectedValue: "150ms" },
  { name: "--dur-fast", expectedValue: "167ms" },
  { name: "--dur-normal", expectedValue: "250ms" },
  { name: "--dur-banner-in", expectedValue: "300ms" },
  { name: "--dur-slow", expectedValue: "333ms" },
  { name: "--ease-decelerate", expectedValue: "cubic-bezier(0, 0, 0, 1)" },
  { name: "--ease-decelerate-max", expectedValue: "cubic-bezier(0.1, 0.9, 0.2, 1)" },
  { name: "--ease-accelerate", expectedValue: "cubic-bezier(1, 0, 1, 1)" },
  { name: "--ease-point-to-point", expectedValue: "cubic-bezier(0.55, 0.55, 0, 1)" },
  { name: "--ease-standard", expectedValue: "cubic-bezier(0.33, 0, 0.67, 1)" },
  { name: "--ease-linear", expectedValue: "cubic-bezier(0, 0, 1, 1)" },
  { name: "--flyout-travel", expectedValue: "36px" },
  { name: "--win-smoke-bg", expectedValue: "rgba(0, 0, 0, 0.302)" },
];

const REMOVED_KEYFRAMES: readonly string[] = [
  "win-subpage-in",
  "win-fade",
  "win-sheet-in",
  "win-jiggle",
];

const GHOST_SURFACE_SELECTORS: readonly string[] = [
  ".cc-sheet-ghost",
  ".cc-settings-sheet-ghost",
  ".cc-camera-live-sheet-ghost",
  ".cc-sheet-body-ghost",
  ".cc-menu-ghost",
  ".cc-prompt-ghost",
  ".cc-tile-ghost",
  ".is-subpage-ghost",
  ".win-notif-card-ghost",
  ".cc-live-banner-ghost",
];

const REQUIRED_UX_SELECTORS: readonly string[] = [
  '#app[data-backdrop="acrylic"] > .cc-popover',
  ".cc-slider-thumb-badge",
  ".win-slider-tooltip",
  ".cc-expander-grid",
  ".cc-expander-grid.is-collapsed",
  ".cc-expander-clip",
  ".cc-tile.is-waiting",
  ".cc-tile.is-caution-armed",
  ".cc-tile.is-popped",
  ".cc-edit-done-chip",
  ".cc-conn-card.is-active-mode",
  ".cc-conn-active-badge",
  "details.cc-conn-secondary",
  "summary.cc-conn-secondary-summary",
  ".cc-settings-save-hint",
  ".cc-btn-ghost-danger",
];

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

describe("Fluent 2 & WinUI 3 CSS Motion, Surface & Accessibility Contracts", () => {
  it("defines all 60Hz frame-aligned motion durations, WinUI 3 splines, flyout travel, and concentric corner radii in :root", () => {
    for (const token of FLUENT_ROOT_TOKENS) {
      const escapedName = token.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const escapedValue = token.expectedValue.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const pattern = new RegExp(`${escapedName}:\\s*${escapedValue}\\s*;`);
      assert.match(stylesCss, pattern, `Expected ${token.name}: ${token.expectedValue}`);
    }
  });

  it("removes dead and non-native keyframes and eliminates bare ease transitions", () => {
    for (const deadName of REMOVED_KEYFRAMES) {
      assert.equal(
        stylesCss.includes(deadName),
        false,
        `Unexpected dead keyframe reference: ${deadName}`,
      );
    }

    assert.equal(
      /\btransition\b[^;]*\bease\b(?![-a-z])/i.test(stylesCss),
      false,
      "Expected zero bare ease transitions in styles.css",
    );
    assert.equal(
      /\btransition\b[^;]*\bease-(?:in|out|in-out)\b/i.test(stylesCss),
      false,
      "Expected zero generic ease-in/out transitions in styles.css",
    );
    assert.match(
      stylesCss,
      /\.cc-popover\.is-editing\s+\.cc-tile:not\(\.is-dragging\):not\(\.is-resizing\)\s*\{[^}]*border-color:\s*color-mix\(in srgb,\s*var\(--win-accent\)\s*48%,\s*var\(--win-card-stroke\)\)/s,
    );
  });

  it("uses compact 36px directional taskbar-edge flyout travel and continuous opacity ramp", () => {
    assert.match(
      stylesCss,
      /#app\[data-flyout-edge="bottom"\]\s*\{\s*--flyout-dx:\s*0px;\s*--flyout-dy:\s*var\(--flyout-travel\);\s*\}/,
    );
    assert.match(
      stylesCss,
      /#app\[data-flyout-edge="top"\]\s*\{\s*--flyout-dx:\s*0px;\s*--flyout-dy:\s*calc\(-1\s*\*\s*var\(--flyout-travel\)\);\s*\}/,
    );
    assert.match(
      stylesCss,
      /#app\[data-flyout-edge="right"\]\s*\{\s*--flyout-dx:\s*var\(--flyout-travel\);\s*--flyout-dy:\s*0px;\s*\}/,
    );
    assert.match(
      stylesCss,
      /#app\[data-flyout-edge="left"\]\s*\{\s*--flyout-dx:\s*calc\(-1\s*\*\s*var\(--flyout-travel\)\);\s*--flyout-dy:\s*0px;\s*\}/,
    );
    assert.match(
      stylesCss,
      /@keyframes\s+win-flyout-enter\s*\{[\s\S]*?translate3d\(var\(--flyout-dx,\s*0px\),\s*var\(--flyout-dy,\s*36px\),\s*0\)[\s\S]*?50%\s*\{\s*opacity:\s*0\.92;\s*\}/,
    );
    assert.match(
      stylesCss,
      /@keyframes\s+win-flyout-exit\s*\{[\s\S]*?calc\(var\(--flyout-dy,\s*36px\)\s*\*\s*0\.75\)/,
    );
    assert.equal(stylesCss.includes("calc(100% + var(--panel-inset"), false);
  });

  it("maintains DepartureGhost selector parity, GPU-composited --fill-scale rules, and Expander 0fr->1fr grid rules", () => {
    for (const selector of GHOST_SURFACE_SELECTORS) {
      assert.equal(
        stylesCss.includes(selector),
        true,
        `Missing DepartureGhost surface selector ${selector}`,
      );
    }

    for (const selector of REQUIRED_UX_SELECTORS) {
      assert.equal(stylesCss.includes(selector), true, `Missing required UX selector ${selector}`);
    }

    assert.match(
      stylesCss,
      /\.cc-tile-fill\[style\*="--fill-scale"\],\s*\.cc-climate-gauge span\[style\*="--fill-scale"\]\s*\{[^}]*width:\s*100%\s*!important;[^}]*transform:\s*scaleX\(var\(--fill-scale,\s*1\)\);/s,
    );
    assert.match(
      stylesCss,
      /\.cc-tile\.is-dimming\s+\.cc-tile-fill\s*\{\s*transition:\s*none\s*!important;\s*\}/,
    );
    assert.match(stylesCss, /@starting-style\s*\{\s*\.cc-expander-grid:not\(\.is-collapsed\)/s);
  });

  it("enforces unclipped WinUI dual-stroke :focus-visible, Segoe UI Variable opsz ramp, and reduced-motion spin gating", () => {
    assert.match(
      stylesCss,
      /:focus-visible\s*\{\s*outline:\s*2px solid transparent;\s*outline-offset:\s*-2px;\s*box-shadow:\s*inset 0 0 0 2px var\(--win-focus-outer\),\s*inset 0 0 0 3px var\(--win-focus-inner\);/s,
    );
    assert.match(stylesCss, /font-variation-settings:\s*"opsz"\s*10\.5/);
    assert.match(stylesCss, /font-variation-settings:\s*"opsz"\s*8/);
    assert.match(stylesCss, /font-variation-settings:\s*"opsz"\s*36/);

    const declarationBlocks = stylesCss.match(/\{[^{}]*\}/g) ?? [];
    for (const block of declarationBlocks) {
      const opszIndex = block.indexOf("font-variation-settings");
      const weightIndex = block.indexOf("font-weight");
      if (opszIndex !== -1 && weightIndex !== -1) {
        assert.equal(
          opszIndex < weightIndex,
          true,
          `Expected font-variation-settings before font-weight in block: ${block}`,
        );
      }
    }

    assert.equal(/\bfont-size:\s*(?:10|11(?:\.5)?)px\b/.test(stylesCss), false);
    assert.equal(stylesCss.includes("0.01ms"), false);
    assert.match(
      stylesCss,
      /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{[\s\S]*?\.is-spinning svg,[\s\S]*?animation:\s*none\s*!important;/,
    );
  });

  it("wires WinUI 3 ToggleSwitch knob stretch, SliderInnerThumb GPU scale, SplitButton hairline, SelectorBar pill, and Light contrast", () => {
    assert.match(
      stylesCss,
      /input\[type="checkbox"\]:hover:not\(:disabled\)::after\s*\{\s*width:\s*14px;\s*height:\s*14px;\s*\}/,
    );
    assert.match(
      stylesCss,
      /input\[type="checkbox"\]:active:not\(:disabled\)::after\s*\{\s*width:\s*17px;\s*height:\s*14px;\s*\}/,
    );
    assert.match(
      stylesCss,
      /\.cc-range::-webkit-slider-thumb\s*\{[\s\S]*?border:\s*1px solid var\(--win-thumb-stroke\);[\s\S]*?transform:\s*scale\(1\);/,
    );
    assert.match(
      stylesCss,
      /\.cc-range:hover:not\(:disabled\)::-webkit-slider-thumb\s*\{\s*transform:\s*scale\(1\.14\);\s*\}/,
    );
    assert.match(
      stylesCss,
      /\.cc-range:active:not\(:disabled\)::-webkit-slider-thumb\s*\{\s*transform:\s*scale\(0\.82\);\s*\}/,
    );
    assert.match(
      stylesCss,
      /\.win-pill-expand::before\s*\{[\s\S]*?height:\s*56%;[\s\S]*?width:\s*1px;/,
    );
    assert.match(
      stylesCss,
      /\.cc-room-pill::after,\s*\.cc-settings-tabs\s+\.cc-seg-pill::after\s*\{[\s\S]*?width:\s*16px;\s*height:\s*3px;[\s\S]*?var\(--ease-point-to-point\)/,
    );
    assert.match(
      stylesCss,
      /\.cc-spotlight-bar:focus-within\s*\{[\s\S]*?box-shadow:\s*inset 0 -2px 0 0 var\(--win-accent\);/,
    );
    assert.equal(stylesCss.includes("rgba(0, 95, 184, 0.16)"), true);
    assert.equal(stylesCss.includes("rgba(255, 255, 255, 0.26)"), true);
  });

  it("renders and updates floating .cc-slider-thumb-badge and GPU --fill-scale in live DOM", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));

    app.dimPreview = { id: "light.living_ceiling", percent: 42 };
    app.pipeline.patchDimPreview(app, "light.living_ceiling", 42);
    const fillEl = element<HTMLElement>(
      '[data-tile-id="light.living_ceiling"] .win-split-pill .cc-tile-fill',
    );
    assert.equal(fillEl.getAttribute("style"), "width:42%;--fill-scale:0.420");

    element<HTMLButtonElement>('[data-expand-device="light.living_ceiling"]').click();
    await setImmediate();

    const slider = element<HTMLInputElement>(
      '.cc-tile.is-subpage input.cc-range[data-brightness="light.living_ceiling"]',
    );
    app.pipeline.updateSliderThumbBadge(slider, "65%", true);

    const badge = element<HTMLElement>(".cc-tile.is-subpage .cc-slider-thumb-badge");
    assert.equal(badge.classList.contains("is-visible"), true);
    assert.equal(badge.textContent, "65%");
    assert.ok(badge.style.left.endsWith("%"));

    app.pipeline.updateSliderThumbBadge(slider, "65%", false);
    assert.equal(badge.classList.contains("is-visible"), false);
  });
});
