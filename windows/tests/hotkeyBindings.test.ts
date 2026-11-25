import assert from "node:assert/strict";
import { describe, it, beforeEach, afterEach } from "node:test";
import { Window } from "happy-dom";
import type { HomeScene, SmartDevice } from "../src/core/models.js";
import {
  MAX_CUSTOM_HOTKEY_BINDINGS,
  executeCustomHotkeyBinding,
  isHotkeyBindingTargetAvailable,
  normalizeCustomHotkeyBindings,
  validateCustomHotkeyShortcut,
  type HotkeyBinding,
} from "../src/ui/hotkeyBindings.js";
import { loadSettings, writeSettingsForStorage } from "../src/ui/settings.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";

const LIGHT_DEVICE: SmartDevice = {
  id: "light.study",
  name: "书房台灯",
  roomId: "room.study",
  roomName: "书房",
  model: "yeelink.light.lamp4",
  isOnline: true,
  kind: {
    kind: "light",
    entityId: "light.study",
    isOn: false,
    brightnessPercent: 80,
    colorTempKelvin: null,
    minKelvin: 2700,
    maxKelvin: 6500,
    currentEffect: null,
    availableEffects: [],
    powerWritable: true,
  },
};

const HIGH_RISK_PLUG: SmartDevice = {
  id: "switch.desk_plug",
  name: "书房插座",
  roomId: "room.study",
  roomName: "书房",
  model: "cuco.plug.v3",
  isOnline: true,
  kind: {
    kind: "plug",
    switchEntityId: "switch.desk_plug",
    isOn: false,
    powerWatts: null,
    childLockEntityId: null,
    isChildLocked: false,
    powerWritable: true,
  },
};

const MOVIE_SCENE: HomeScene = {
  id: "scene.movie",
  name: "观影模式",
  entityId: "scene.movie",
};

describe("Windows per-device / per-scene global hotkey bindings (P1-6)", () => {
  let domWindow: Window;
  let origWindow: typeof globalThis.window;
  let origDocument: typeof globalThis.document;
  let origLocalStorage: typeof globalThis.localStorage;

  beforeEach(() => {
    domWindow = new Window({ url: "http://localhost/" });
    origWindow = globalThis.window;
    origDocument = globalThis.document;
    origLocalStorage = globalThis.localStorage;
    Object.defineProperty(globalThis, "window", { value: domWindow, configurable: true, writable: true });
    Object.defineProperty(globalThis, "document", { value: domWindow.document, configurable: true, writable: true });
    Object.defineProperty(globalThis, "localStorage", { value: domWindow.localStorage, configurable: true, writable: true });
  });

  afterEach(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
    Object.defineProperty(globalThis, "window", { value: origWindow, configurable: true, writable: true });
    Object.defineProperty(globalThis, "document", { value: origDocument, configurable: true, writable: true });
    Object.defineProperty(globalThis, "localStorage", { value: origLocalStorage, configurable: true, writable: true });
    void domWindow.close();
  });

  it("persists bindings round-trip and enforces the 8-binding cap", () => {
    const bindings: HotkeyBinding[] = Array.from({ length: 10 }, (_, idx) => ({
      id: `hk-${idx}`,
      target:
        idx % 2 === 0
          ? { kind: "devicePower" as const, deviceId: `dev-${idx}` }
          : { kind: "scene" as const, sceneId: `scene-${idx}` },
      targetLabel: `Target ${idx}`,
      shortcut: `Ctrl+Alt+${idx}`,
    }));

    const loaded0 = loadSettings();
    loaded0.settings.customHotkeyBindings = bindings;
    writeSettingsForStorage(loaded0.settings);

    const reloaded = loadSettings().settings.customHotkeyBindings ?? [];
    assert.equal(reloaded.length, MAX_CUSTOM_HOTKEY_BINDINGS);
    assert.equal(reloaded[0]?.id, "hk-0");
    assert.deepEqual(reloaded[0]?.target, { kind: "devicePower", deviceId: "dev-0" });
    assert.deepEqual(reloaded[1]?.target, { kind: "scene", sceneId: "scene-1" });
    assert.equal(normalizeCustomHotkeyBindings("not-an-array").length, 0);
  });

  it("detects conflicts against panel hotkey, existing bindings, system shortcuts, and bare letters", () => {
    const existing: HotkeyBinding[] = [
      {
        id: "b-1",
        target: { kind: "devicePower", deviceId: LIGHT_DEVICE.id },
        targetLabel: LIGHT_DEVICE.name,
        shortcut: "Ctrl+Alt+1",
      },
    ];

    assert.equal(
      validateCustomHotkeyShortcut("Alt+M", {
        panelShortcut: "Alt+M",
        existingBindings: existing,
      })?.kind,
      "panelHotkey",
    );

    assert.equal(
      validateCustomHotkeyShortcut("Ctrl+Alt+1", {
        panelShortcut: "Alt+M",
        existingBindings: existing,
      })?.kind,
      "existingBinding",
    );

    // Re-recording the same binding excludes itself.
    assert.equal(
      validateCustomHotkeyShortcut("Ctrl+Alt+1", {
        panelShortcut: "Alt+M",
        existingBindings: existing,
        excludingBindingId: "b-1",
      }),
      null,
    );

    // Known Windows system shortcuts are blocked.
    for (const sys of ["Alt+F4", "Super+L", "Ctrl+C", "Alt+Tab"]) {
      assert.equal(
        validateCustomHotkeyShortcut(sys, {
          panelShortcut: "Alt+M",
          existingBindings: existing,
        })?.kind,
        "systemShortcut",
        `Expected ${sys} to conflict as systemShortcut`,
      );
    }

    // Bare letter is invalid.
    assert.equal(
      validateCustomHotkeyShortcut("A", {
        panelShortcut: "Alt+M",
        existingBindings: existing,
      })?.kind,
      "invalid",
    );

    // Distinct valid chord passes.
    assert.equal(
      validateCustomHotkeyShortcut("Ctrl+Alt+2", {
        panelShortcut: "Alt+M",
        existingBindings: existing,
      }),
      null,
    );
  });

  function makeApp(options: { locked?: boolean } = {}) {
    const root = document.createElement("div");
    document.body.appendChild(root);
    const invoked: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    (window as unknown as { __TAURI_INTERNALS__: { invoke: (cmd: string, args?: Record<string, unknown>) => Promise<unknown> } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd, args) => {
        invoked.push({ cmd, args });
        if (cmd === "is_workstation_locked") return Boolean(options.locked);
        if (cmd === "panel_is_visible") return false;
        return null;
      },
    };
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "demo";
    app.settings.blockControlWhileLocked = true;
    app.devices = [structuredClone(LIGHT_DEVICE), structuredClone(HIGH_RISK_PLUG)];
    app.scenes = [structuredClone(MOVIE_SCENE)];
    return { app, invoked };
  }

  it("toggles a low-risk bound device through the same panel control path", async () => {
    const { app } = makeApp({ locked: false });
    const executed: unknown[] = [];
    app.executeSingleCommand = async (_dev, cmd) => {
      executed.push(cmd);
    };
    app.settings.customHotkeyBindings = [
      {
        id: "hk-light",
        target: { kind: "devicePower", deviceId: LIGHT_DEVICE.id },
        targetLabel: LIGHT_DEVICE.name,
        shortcut: "Ctrl+Alt+1",
      },
    ];

    const outcome = await executeCustomHotkeyBinding(app, "hk-light");
    assert.equal(outcome.status, "executed");
    assert.equal(executed.length, 1);
    app.dispose();
  });

  it("blocks device, scene, and quick action hotkeys while the workstation is locked", async () => {
    const { app } = makeApp({ locked: true });
    let commandCalls = 0;
    app.executeSingleCommand = async () => {
      commandCalls += 1;
    };
    app.executeIntents = async () => {
      commandCalls += 1;
      return true;
    };
    app.handleNaturalCommand = async () => {
      commandCalls += 1;
    };
    app.settings.customHotkeyBindings = [
      { id: "hk-dev", target: { kind: "devicePower", deviceId: LIGHT_DEVICE.id }, targetLabel: LIGHT_DEVICE.name, shortcut: "Ctrl+Alt+1" },
      { id: "hk-scene", target: { kind: "scene", sceneId: MOVIE_SCENE.id }, targetLabel: MOVIE_SCENE.name, shortcut: "Ctrl+Alt+2" },
      { id: "hk-quick", target: { kind: "quickAction", actionId: "lightsOff" }, targetLabel: "全屋关灯", shortcut: "Ctrl+Alt+3" },
    ];

    assert.equal((await executeCustomHotkeyBinding(app, "hk-dev")).status, "blocked");
    assert.equal((await executeCustomHotkeyBinding(app, "hk-scene")).status, "blocked");
    assert.equal((await executeCustomHotkeyBinding(app, "hk-quick")).status, "blocked");
    assert.equal(commandCalls, 0);
    app.dispose();
  });

  it("high-risk device bound to a hotkey always asks and never silently executes", async () => {
    const { app } = makeApp({ locked: false });
    let commandCalls = 0;
    app.executeSingleCommand = async () => {
      commandCalls += 1;
    };
    app.settings.customHotkeyBindings = [
      {
        id: "hk-plug",
        target: { kind: "devicePower", deviceId: HIGH_RISK_PLUG.id },
        targetLabel: HIGH_RISK_PLUG.name,
        shortcut: "Ctrl+Alt+2",
      },
    ];

    const first = await executeCustomHotkeyBinding(app, "hk-plug");
    assert.equal(first.status, "needsConfirmation");
    assert.ok(app.pendingHighRisk !== null, "Expected pendingHighRisk confirmation to be armed");
    assert.equal(commandCalls, 0);

    // Pressing the hotkey a second time must STILL ask and never silently execute.
    const second = await executeCustomHotkeyBinding(app, "hk-plug");
    assert.equal(second.status, "needsConfirmation");
    assert.equal(commandCalls, 0);
    app.dispose();
  });

  it("treats missing device or scene targets as unavailable and executes nothing", async () => {
    const { app } = makeApp({ locked: false });
    let commandCalls = 0;
    app.executeSingleCommand = async () => {
      commandCalls += 1;
    };
    app.executeIntents = async () => {
      commandCalls += 1;
      return true;
    };
    const missingDev: HotkeyBinding = {
      id: "hk-missing-dev",
      target: { kind: "devicePower", deviceId: "light.deleted" },
      targetLabel: "已删除台灯",
      shortcut: "Ctrl+Alt+3",
    };
    const missingScene: HotkeyBinding = {
      id: "hk-missing-scene",
      target: { kind: "scene", sceneId: "scene.deleted" },
      targetLabel: "已删除场景",
      shortcut: "Ctrl+Alt+4",
    };
    app.settings.customHotkeyBindings = [missingDev, missingScene];

    assert.equal(isHotkeyBindingTargetAvailable(missingDev, app.devices, app.scenes), false);
    assert.equal(isHotkeyBindingTargetAvailable(missingScene, app.devices, app.scenes), false);
    assert.equal((await executeCustomHotkeyBinding(app, "hk-missing-dev")).status, "unavailable");
    assert.equal((await executeCustomHotkeyBinding(app, "hk-missing-scene")).status, "unavailable");
    assert.equal(commandCalls, 0);
    app.dispose();
  });

  it("executes a bound scene hotkey through executeIntents", async () => {
    const { app } = makeApp({ locked: false });
    const capturedIntents: unknown[] = [];
    app.executeIntents = async (intents) => {
      capturedIntents.push(...intents);
      return true;
    };
    app.settings.customHotkeyBindings = [
      {
        id: "hk-scene",
        target: { kind: "scene", sceneId: MOVIE_SCENE.id },
        targetLabel: MOVIE_SCENE.name,
        shortcut: "Ctrl+Alt+5",
      },
    ];

    const outcome = await executeCustomHotkeyBinding(app, "hk-scene");
    assert.equal(outcome.status, "executed");
    assert.equal(capturedIntents.length, 1);
    app.dispose();
  });
});
