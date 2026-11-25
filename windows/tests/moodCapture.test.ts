import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import {
  decodeMoodSnapshotFile, encodeMoodSnapshotFile, loadMoodSnapshots, moodTargetFields,
  MOOD_SNAPSHOTS_STORAGE_KEY, MOOD_SNAPSHOT_LIMIT, type MoodSnapshotFile,
} from "../src/core/moodSnapshot.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { setHostDualSourceEnabled } from "../src/ui/cloudRefresh.js";
import {
  decodeHotkeyTargetKey, encodeHotkeyTargetKey, executeCustomHotkeyBinding,
  isHotkeyBindingTargetAvailable, normalizeCustomHotkeyBindings, type HotkeyBinding,
} from "../src/ui/hotkeyBindings.js";
import { writeSettingsForStorage } from "../src/ui/settings.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "../..");
const GOLDEN_PATH = path.join(REPO_ROOT, "Tests/Fixtures/mood_snapshot_golden.json");
const SCHEMA_PATH = path.join(REPO_ROOT, "Tests/Fixtures/mood_snapshot.schema.json");

function validateAgainstMoodSchema(payload: unknown): void {
  const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8"));
  const root = payload as Record<string, unknown>;
  assert.deepEqual(Object.keys(root).sort(), [...schema.required].sort());
  assert.equal(root.version, schema.properties.version.const);
  const moods = root.moods as Array<Record<string, unknown>>;
  assert.ok(Array.isArray(moods) && moods.length <= schema.properties.moods.maxItems);
  const tSchema = schema.properties.moods.items.properties.targets.items;
  const scopeRe = new RegExp(tSchema.properties.sourceScope.pattern);
  const allowed = new Set(Object.keys(tSchema.properties));
  for (const m of moods) {
    assert.deepEqual(Object.keys(m).sort(), [...schema.properties.moods.items.required].sort());
    assert.match(m.id as string, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    assert.ok(typeof m.name === "string" && m.name.length >= 1 && Number.isFinite(Date.parse(m.createdAt as string)));
    const targets = m.targets as Array<Record<string, unknown>>;
    assert.ok(Array.isArray(targets) && targets.length >= 1);
    for (const t of targets) {
      assert.ok(Object.keys(t).length >= tSchema.minProperties && Object.keys(t).every((k) => allowed.has(k)));
      for (const req of tSchema.required as string[]) assert.ok(typeof t[req] === "string" && (t[req] as string).length >= 1);
      assert.match(t.sourceScope as string, scopeRe);
      if (t.power !== undefined) assert.equal(typeof t.power, "boolean");
      if (t.brightness !== undefined) assert.ok(Number.isInteger(t.brightness) && (t.brightness as number) >= 1 && (t.brightness as number) <= 100);
      if (t.colorTemperature !== undefined) assert.ok(Number.isInteger(t.colorTemperature) && (t.colorTemperature as number) >= 1);
      if (t.coverPosition !== undefined) assert.ok(Number.isInteger(t.coverPosition) && (t.coverPosition as number) >= 0 && (t.coverPosition as number) <= 100);
      if (t.targetTemperature !== undefined) assert.ok(typeof t.targetTemperature === "number" && Number.isFinite(t.targetTemperature as number));
      if (t.hvacMode !== undefined) assert.ok(typeof t.hvacMode === "string" && (t.hvacMode as string).length >= 1);
    }
  }
}

const mkLight = (o: { id?: string; name?: string; roomId?: string; isOn?: boolean; brightness?: number | null; colorTemp?: number | null; isOnline?: boolean; telemetryStale?: boolean; sourceBackend?: SmartDevice["sourceBackend"]; accountId?: string } = {}): SmartDevice => ({
  id: o.id ?? "desk-light", name: o.name ?? "Desk light", roomId: o.roomId ?? "room-study", roomName: o.roomId === "room-living" ? "Living" : "Study",
  model: "yeelink.light.mono1", isOnline: o.isOnline ?? true, telemetryStale: o.telemetryStale, sourceBackend: o.sourceBackend, accountId: o.accountId,
  kind: { kind: "light", entityId: `light.${o.id ?? "desk-light"}`, isOn: o.isOn ?? true, brightnessPercent: o.brightness === undefined ? 45 : o.brightness, colorTempKelvin: o.colorTemp === undefined ? 3200 : o.colorTemp, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [] },
});

const mkClimate = (o: { id?: string; name?: string; model?: string; isOn?: boolean; hvacMode?: string; availableModes?: string[]; targetTemperature?: number; temperatureWritable?: boolean; powerWritable?: boolean } = {}): SmartDevice => ({
  id: o.id ?? "study-ac", name: o.name ?? "Study AC", roomId: "room-study", roomName: "Study", model: o.model ?? "ha.climate",
  isOnline: true, sourceBackend: "homeAssistant",
  kind: { kind: "climate", entityId: `climate.${o.id ?? "study-ac"}`, isOn: o.isOn ?? true, hvacMode: o.hvacMode ?? "cool", availableModes: o.availableModes ?? ["off", "cool", "heat", "auto"], fanMode: null, availableFanModes: [], swingMode: null, availableSwingModes: [], targetTemperature: o.targetTemperature ?? 25, minTemp: 16, maxTemp: 30, step: 1, currentTemperature: 26, powerWritable: o.powerWritable, temperatureWritable: o.temperatureWritable },
});

const mkCover = (id = "garage", pos = 80, subtype: "garage-door" | "curtain" = "garage-door"): SmartDevice => ({
  id, name: "Garage Door", roomId: "room-study", roomName: "Study", model: "ha.cover", isOnline: true, sourceBackend: "homeAssistant",
  kind: { kind: "cover", entityId: `cover.${id}`, subtype, positionPercent: pos, motion: "stopped", openDescription: "open", closeDescription: "close", pauseDescription: null, positionWritable: true, batteryPercent: null, faultText: null },
});

describe("Windows Mood Snapshot capture, replay, safety gates & hotkeys (W2B-6b)", () => {
  let domWindow: Window;
  let origW: typeof globalThis.window;
  let origD: typeof globalThis.document;
  let origS: typeof globalThis.localStorage;

  beforeEach(() => {
    domWindow = new Window({ url: "http://localhost/" });
    origW = globalThis.window; origD = globalThis.document; origS = globalThis.localStorage;
    Object.defineProperty(globalThis, "window", { value: domWindow, configurable: true, writable: true });
    Object.defineProperty(globalThis, "document", { value: domWindow.document, configurable: true, writable: true });
    Object.defineProperty(globalThis, "localStorage", { value: domWindow.localStorage, configurable: true, writable: true });
  });

  afterEach(async () => {
    await new Promise((r) => setTimeout(r, 0));
    Object.defineProperty(globalThis, "window", { value: origW, configurable: true, writable: true });
    Object.defineProperty(globalThis, "document", { value: origD, configurable: true, writable: true });
    Object.defineProperty(globalThis, "localStorage", { value: origS, configurable: true, writable: true });
    void domWindow.close();
  });

  it("loads golden fixture and round-trips against mood_snapshot.schema.json", () => {
    const goldenRaw = fs.readFileSync(GOLDEN_PATH, "utf8");
    const decoded = decodeMoodSnapshotFile(goldenRaw);
    assert.ok(decoded !== null && decoded.version === 1 && decoded.moods.length === 1);
    assert.deepEqual(moodTargetFields(decoded.moods[0]!.targets[0]!), [{ kind: "power", value: true }, { kind: "brightness", value: 40 }, { kind: "colorTemperature", value: 3200 }]);
    const reencoded: MoodSnapshotFile = JSON.parse(encodeMoodSnapshotFile(decoded));
    validateAgainstMoodSchema(reencoded);
    assert.deepEqual(reencoded, JSON.parse(goldenRaw));
  });

  it("captures writable fields per room across Mi and HA, skips non-writable/stale/offline, and enforces 32-mood FIFO cap", () => {
    const root = document.createElement("div"); document.body.appendChild(root);
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://homeassistant.local:8123";
    const miSession = { userId: "42", region: "cn", serviceToken: "t", ssecurity: "s", cUserId: "", passToken: "" };
    const miAccount = makeMiAccount(miSession);
    app.settings.miSession = miSession; app.miAccountsOverride = [miAccount];
    setHostDualSourceEnabled(app, true);

    const btnPlug: SmartDevice = { id: "btn-plug", name: "Button", roomId: "room-study", roomName: "Study", model: "ha.button", isOnline: true, sourceBackend: "homeAssistant", kind: { kind: "plug", switchEntityId: "button.door", isOn: false, powerWatts: null, childLockEntityId: null, isChildLocked: false, powerWritable: true } };
    app.devices = [
      mkLight({ id: "desk", sourceBackend: "xiaomiCloud", accountId: miAccount.id, brightness: 40, colorTemp: 3200 }),
      mkClimate({ id: "ac", targetTemperature: 25 }),
      mkClimate({ id: "ac-ro", availableModes: [], temperatureWritable: false, powerWritable: false }),
      mkLight({ id: "off", isOnline: false, sourceBackend: "xiaomiCloud", accountId: miAccount.id }),
      mkLight({ id: "stale", telemetryStale: true, sourceBackend: "xiaomiCloud", accountId: miAccount.id }),
      btnPlug,
      mkLight({ id: "living", roomId: "room-living", sourceBackend: "xiaomiCloud", accountId: miAccount.id }),
    ];

    assert.equal(app.captureMood("   ", "room-study"), false);
    assert.equal(app.captureMood("Reading", "room-study"), true);
    assert.deepEqual(app.moods[0]?.targets.map((t) => t.deviceId), ["desk", "ac"]);
    assert.equal(app.moods[0]?.targets[0]?.sourceScope, miAccount.id);
    assert.equal(app.moods[0]?.targets[1]?.sourceScope, "ha:http://homeassistant.local:8123");
    validateAgainstMoodSchema(JSON.parse(localStorage.getItem(MOOD_SNAPSHOTS_STORAGE_KEY) ?? "{}"));
    assert.equal(loadMoodSnapshots().length, 1);

    for (let i = 1; i <= MOOD_SNAPSHOT_LIMIT + 3; i++) assert.equal(app.captureMood(`Mood ${i}`, "room-study"), true);
    assert.equal(app.moods.length, MOOD_SNAPSHOT_LIMIT);
    assert.equal(app.moods[0]?.name, `Mood ${MOOD_SNAPSHOT_LIMIT + 3}`);
    app.dispose();
  });

  it("replays mood via hotkey with single batch confirmation, skips offline devices, and supports cover/light undo", async () => {
    const root = document.createElement("div"); document.body.appendChild(root);
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://homeassistant.local:8123";

    const heater = mkClimate({ id: "heater", name: "Space Heater", model: "zhimi.heater.mc2", hvacMode: "heat", availableModes: ["off", "heat"], targetTemperature: 26 });
    const fan: SmartDevice = { id: "offline-fan", name: "Offline Fan", roomId: "room-study", roomName: "Study", model: "dmaker.fan.p18", isOnline: true, sourceBackend: "homeAssistant", kind: { kind: "fan", entityId: "fan.offline", isOn: true, isOscillating: null, percentage: null, presetMode: null, availablePresetModes: [] } };
    app.devices = [mkLight({ id: "desk", name: "Desk", sourceBackend: "homeAssistant", isOn: true, brightness: 40, colorTemp: 3200 }), mkCover("garage", 80), heater, fan];
    app.lastCoverPositions["garage"] = 80;
    assert.equal(app.captureMood("Movie Night", "room-study"), true);
    const mood = app.moods[0]!;

    app.devices = [
      mkLight({ id: "desk", name: "Desk", sourceBackend: "homeAssistant", isOn: false, brightness: 90, colorTemp: 5000 }),
      mkCover("garage", 20),
      mkClimate({ id: "heater", name: "Space Heater", model: "zhimi.heater.mc2", isOn: false, hvacMode: "off", availableModes: ["off", "heat"], targetTemperature: 20 }),
      { ...fan, isOnline: false },
    ];
    app.lastCoverPositions["garage"] = 20;

    const sent: DeviceCommand[] = [];
    const confirmPrompts: string[] = [];
    app.applyCommand = async (cmd) => { sent.push(cmd); return true; };
    app.manualControlConfirmationHandler = (p) => { confirmPrompts.push(p.message); return true; };

    const binding: HotkeyBinding = { id: "hk-mood", target: { kind: "mood", moodId: mood.id }, targetLabel: mood.name, shortcut: "Ctrl+Alt+M" };
    assert.deepEqual(decodeHotkeyTargetKey(encodeHotkeyTargetKey(binding.target)), binding.target);
    assert.equal(isHotkeyBindingTargetAvailable(binding, app.devices, app.scenes, app.moods), true);
    app.settings.customHotkeyBindings = normalizeCustomHotkeyBindings([binding]);

    const outcome = await executeCustomHotkeyBinding(app, "hk-mood");
    assert.equal(outcome.status, "executed");
    assert.equal(confirmPrompts.length, 1);
    assert.ok(confirmPrompts[0]!.includes("Garage Door") && confirmPrompts[0]!.includes("Space Heater"));
    assert.ok(app.replyBanner?.text.includes("Offline Fan") && app.replyBanner.isError);
    assert.ok(sent.some((c) => c.kind === "setNumberValue" && c.entityId === "cover.garage" && c.value === 80));
    assert.ok(!sent.some((c) => "entityId" in c && c.entityId === "fan.offline"));

    const beforeUndo = sent.length;
    await app.performUndo();
    const undoCmds = sent.slice(beforeUndo);
    assert.ok(undoCmds.some((c) => c.kind === "setNumberValue" && c.entityId === "cover.garage" && c.value === 20));
    assert.ok(undoCmds.some((c) => c.kind === "setLightBrightness" && c.percent === 90));
    app.dispose();
  });

  it("blocks replay under workstation lock and cancels without writes when batch confirmation is declined", async () => {
    let locked = true;
    Object.defineProperty(domWindow, "__TAURI_INTERNALS__", { value: { invoke: async (cmd: string) => (cmd === "is_workstation_locked" ? locked : undefined) }, configurable: true, writable: true });
    const root = document.createElement("div"); document.body.appendChild(root);
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "homeAssistant"; app.settings.haBaseURL = "http://homeassistant.local:8123"; app.settings.blockControlWhileLocked = true;
    app.devices = [mkCover("garage", 80)];
    assert.equal(app.captureMood("Open Garage", "room-study"), true);
    const moodId = app.moods[0]!.id;
    app.devices = [mkCover("garage", 0)]; app.lastCoverPositions["garage"] = 0;

    const sent: DeviceCommand[] = []; let prompts = 0;
    app.applyCommand = async (cmd) => { sent.push(cmd); return true; };
    app.manualControlConfirmationHandler = () => { prompts += 1; return false; };

    assert.equal((await app.applyMood(moodId)).status, "blocked");
    assert.equal(prompts, 0); assert.equal(sent.length, 0);
    locked = false;
    assert.equal((await app.applyMood(moodId)).status, "cancelled");
    assert.equal(prompts, 1); assert.equal(sent.length, 0);
    app.dispose();
  });

  it("blocks replay when device category is disabled or Mi session is expired", async () => {
    const root = document.createElement("div"); document.body.appendChild(root);
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "xiaomiCloud";
    const miSession = { userId: "42", region: "cn", serviceToken: "t", ssecurity: "s", cUserId: "", passToken: "" };
    const account = makeMiAccount(miSession);
    app.settings.miSession = miSession; app.miAccountsOverride = [account];
    app.devices = [mkLight({ id: "desk", sourceBackend: "xiaomiCloud", accountId: account.id, brightness: 50, colorTemp: 3000 })];
    writeSettingsForStorage(app.settings);

    assert.equal(app.captureMood("Warm Desk", "room-study"), true);
    const moodId = app.moods[0]!.id;
    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => { sent.push(cmd); return true; };

    app.miSessionExpired = true;
    assert.equal((await app.applyMood(moodId)).status, "blocked");
    assert.equal(sent.length, 0);

    app.miSessionExpired = false;
    assert.equal(app.setEnabledDeviceCategories(["climate", "cover", "plug", "fan"]), true);
    assert.equal((await app.applyMood(moodId)).status, "failed");
    assert.equal(sent.length, 0);
    app.dispose();
  });

  it("renders mood strip next to quick actions and supports UI capture + settings hotkey dropdown", () => {
    const root = document.createElement("div"); document.body.appendChild(root);
    const app = new MenuMijiaWindowsApp(root);
    app.settings.connectionMode = "demo"; app.settings.showQuickActionsBar = true;
    app.devices = [mkLight({ id: "desk", name: "Desk Light", sourceBackend: "demo" as never })];
    app.render();

    root.querySelector<HTMLButtonElement>("#btn-mood-capture")!.click();
    const input = root.querySelector<HTMLInputElement>("#mood-capture-name")!;
    const form = root.querySelector<HTMLFormElement>("#mood-capture-form")!;
    input.value = "Focus";
    form.dispatchEvent(new domWindow.Event("submit", { cancelable: true }) as unknown as Event);
    assert.equal(app.moods[0]?.name, "Focus");
    assert.ok(root.querySelector(`[data-mood-apply="${app.moods[0]!.id}"]`) !== null);

    app.activeSheet = "settings"; app.settingsTab = "general"; app.isAddingCustomHotkey = true;
    app.render();
    const select = root.querySelector<HTMLSelectElement>("#select-custom-hotkey-target");
    assert.ok(select !== null);
    assert.ok(Array.from(select.options).some((opt) => opt.value === encodeHotkeyTargetKey({ kind: "mood", moodId: app.moods[0]!.id })));
    app.dispose();
  });
});
