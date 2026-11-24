import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";

test("main panel signals panel_ready once after first render; standalone settings does not", async () => {
  const invoked: string[] = [];
  const win = new Window({ url: "http://tauri.localhost/" });
  const prevWindow = (globalThis as Record<string, unknown>).window;
  const prevDocument = (globalThis as Record<string, unknown>).document;
  const prevLocalStorage = (globalThis as Record<string, unknown>).localStorage;
  const prevRAF = (globalThis as Record<string, unknown>).requestAnimationFrame;

  (globalThis as Record<string, unknown>).window = win;
  (globalThis as Record<string, unknown>).document = win.document;
  (globalThis as Record<string, unknown>).localStorage = win.localStorage;
  (globalThis as Record<string, unknown>).requestAnimationFrame = (cb: FrameRequestCallback) => {
    cb(0);
    return 1;
  };
  (win as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (cmd: string) => {
      invoked.push(cmd);
      if (cmd === "panel_is_visible") return false;
      if (cmd === "win_theme_state") return null;
      return null;
    },
  };

  try {
    const rawRoot = win.document.createElement("div");
    win.document.body.appendChild(rawRoot);
    const app = new MenuMijiaWindowsApp(rawRoot as unknown as HTMLElement);
    await new Promise((resolve) => setTimeout(resolve, 10));
    app.dispose();

    assert.equal(
      invoked.filter((cmd) => cmd === "panel_ready").length,
      1,
      `expected main panel to invoke panel_ready once, saw: ${invoked.join(", ")}`,
    );

    invoked.length = 0;
    (win as unknown as Record<string, unknown>).__MENUMIJIA_WINDOW_MODE__ = "settings";
    const rawSettingsRoot = win.document.createElement("div");
    win.document.body.appendChild(rawSettingsRoot);
    const settingsApp = new MenuMijiaWindowsApp(rawSettingsRoot as unknown as HTMLElement);
    await new Promise((resolve) => setTimeout(resolve, 10));
    settingsApp.dispose();

    assert.equal(
      invoked.filter((cmd) => cmd === "panel_ready").length,
      0,
      "standalone settings window must not invoke panel_ready",
    );
  } finally {
    (globalThis as Record<string, unknown>).window = prevWindow;
    (globalThis as Record<string, unknown>).document = prevDocument;
    (globalThis as Record<string, unknown>).localStorage = prevLocalStorage;
    (globalThis as Record<string, unknown>).requestAnimationFrame = prevRAF;
  }
});
