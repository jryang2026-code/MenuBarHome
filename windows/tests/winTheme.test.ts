import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { applyWinThemeToDom, parseWinThemeSnapshot, type WinThemeSnapshot } from "../src/ui/winTheme.js";

function makeSnapshot(overrides: Partial<WinThemeSnapshot> = {}): WinThemeSnapshot {
  return {
    windowsBuild: 22631,
    supportsSystemBackdrop: true,
    appsUseLightTheme: false,
    systemUsesLightTheme: false,
    enableTransparency: true,
    accentDark: {
      accent: "#72d6ff",
      accentHover: "#8ce0ff",
      accentPressed: "#55c7f7",
      textOnAccent: "#0c1117",
    },
    accentLight: {
      accent: "#0067c0",
      accentHover: "#0078d4",
      accentPressed: "#00549e",
      textOnAccent: "#ffffff",
    },
    ...overrides,
  };
}

test("applyWinThemeToDom applies native acrylic only to Classic on supported builds and never to Fluent", () => {
  const win = new Window();
  const docEl = win.document.documentElement as unknown as HTMLElement;
  const root = win.document.createElement("div") as unknown as HTMLElement;
  const snap = makeSnapshot();

  // Classic + Win11 22H2+ -> native acrylic + dark accent palette
  applyWinThemeToDom(root, docEl, snap, {
    panelTheme: "classic",
    effectiveAppearance: "dark",
    isStandaloneSettingsWindow: false,
  });
  assert.equal(root.dataset.nativeBackdrop, "acrylic");
  assert.equal(docEl.dataset.nativeBackdrop, undefined);
  assert.equal(docEl.style.getPropertyValue("--win-accent"), "#72d6ff");
  assert.equal(docEl.style.getPropertyValue("--win-text-on-accent"), "#0c1117");

  // Fluent two-island -> NEVER native acrylic, still gets real system accent
  applyWinThemeToDom(root, docEl, snap, {
    panelTheme: "fluent",
    effectiveAppearance: "light",
    isStandaloneSettingsWindow: false,
  });
  assert.equal(root.dataset.nativeBackdrop, undefined);
  assert.equal(docEl.style.getPropertyValue("--win-accent"), "#0067c0");
  assert.equal(docEl.style.getPropertyValue("--win-text-on-accent"), "#ffffff");

  // Win10 / <22621 or transparency disabled -> falls back cleanly
  applyWinThemeToDom(root, docEl, makeSnapshot({ windowsBuild: 19045, supportsSystemBackdrop: false }), {
    panelTheme: "classic",
    effectiveAppearance: "dark",
    isStandaloneSettingsWindow: false,
  });
  assert.equal(root.dataset.nativeBackdrop, undefined);
});

test("applyWinThemeToDom applies native Mica to standalone settings window only when supported", () => {
  const win = new Window();
  const docEl = win.document.documentElement as unknown as HTMLElement;
  const root = win.document.createElement("div") as unknown as HTMLElement;

  applyWinThemeToDom(root, docEl, makeSnapshot({ supportsSystemBackdrop: true }), {
    panelTheme: "classic",
    effectiveAppearance: "dark",
    isStandaloneSettingsWindow: true,
  });
  assert.equal(docEl.dataset.nativeBackdrop, "mica");
  assert.equal(root.dataset.nativeBackdrop, undefined);

  applyWinThemeToDom(root, docEl, makeSnapshot({ supportsSystemBackdrop: false }), {
    panelTheme: "classic",
    effectiveAppearance: "dark",
    isStandaloneSettingsWindow: true,
  });
  assert.equal(docEl.dataset.nativeBackdrop, undefined);

  // Null snapshot clears injected CSS accent vars so CSS defaults apply
  applyWinThemeToDom(root, docEl, null, {
    panelTheme: "classic",
    effectiveAppearance: "dark",
    isStandaloneSettingsWindow: false,
  });
  assert.equal(docEl.style.getPropertyValue("--win-accent"), "");
});

test("parseWinThemeSnapshot validates IPC payload shape", () => {
  assert.equal(parseWinThemeSnapshot(null), null);
  assert.equal(parseWinThemeSnapshot("bad"), null);
  const parsed = parseWinThemeSnapshot(makeSnapshot());
  assert.equal(parsed?.windowsBuild, 22631);
  assert.equal(parsed?.supportsSystemBackdrop, true);
  assert.equal(parsed?.accentDark?.accent, "#72d6ff");
});
