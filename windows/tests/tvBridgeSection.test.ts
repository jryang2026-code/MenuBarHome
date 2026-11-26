import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice, TvSpec } from "../src/core/models.js";
import { tvBridgeDescriptorMacs, type TVBridgeFrame } from "../src/core/tvBridgePlugin.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { applyCommand } from "../src/ui/commandDispatch.js";
import { DEVICE_CATEGORY_IDS } from "../src/core/capabilityManifest.js";
import {
  TV_BRIDGE_STORAGE_KEY,
  TVBridgeController,
  bindTVBridgeEvents,
  nonHijackingTVBridgeRows,
  renderTVBridgeSettingsSection,
  setTVBridgeControllerForTesting,
  toTVBridgeCommand,
  type TVBridgeSecrets,
  type TVBridgeStorage,
} from "../src/ui/tvBridgeSection.js";

const esc = (raw: string) => raw.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
const ID = "adapter:com.menubarhome.tv-bridge:tv-a";

function memoryStorage(initial: Record<string, string> = {}): TVBridgeStorage & { data: Record<string, string> } {
  const data = { ...initial };
  return { data, getItem: (key) => data[key] ?? null, setItem: (key, value) => { data[key] = value; } };
}

function memorySecrets(): TVBridgeSecrets & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return {
    data,
    get: async (slot) => data.get(slot) ?? null,
    set: async (slot, value) => { data.set(slot, value); },
    delete: async (slot) => { data.delete(slot); },
  };
}

const DEFAULT_ROWS: readonly Record<string, unknown>[] = [{ nativeId: "tv-a", name: "卧室电视", online: true, state: "on", volume: 20, muted: false }];

function recordingInvoke(options: { rows?: readonly Record<string, unknown>[]; startGate?: Promise<void>; failInitialize?: boolean } = {}) {
  const calls: { cmd: string; frame?: TVBridgeFrame; args?: Record<string, unknown> }[] = [];
  /** Held by the next `tv_bridge_start` only, then cleared. */
  const gate: { next: Promise<void> | undefined } = { next: options.startGate };
  const invoke = async (cmd: string, args?: Record<string, unknown>) => {
    const frame = args?.frame as TVBridgeFrame | undefined;
    calls.push({ cmd, frame, args });
    if (cmd === "tv_bridge_start" && gate.next) {
      const held = gate.next;
      gate.next = undefined;
      await held;
    }
    if (cmd !== "tv_bridge_request" || !frame) return null;
    if (frame.method === "initialize" && options.failInitialize) return { jsonrpc: "2.0", id: frame.id, error: { code: -32099, message: "boom" } };
    const result = frame.method === "snapshot"
      ? { capturedAt: "now", devices: options.rows ?? DEFAULT_ROWS }
      : {};
    return { jsonrpc: "2.0", id: frame.id, result };
  };
  const methods = () => calls.map((c) => c.frame?.method ?? c.cmd);
  return { calls, invoke, methods, gate };
}

function tv(id: string, name: string): SmartDevice {
  const kind: TvSpec = { kind: "tv", mediaEntityId: id, state: "on", volumePercent: 10, currentSource: null, availableSources: [], volumeWritable: true };
  return { id, name, roomId: "r", roomName: "客厅", model: "tv", isOnline: true, kind };
}

async function enabledController(options: Parameters<typeof recordingInvoke>[0] & { idleShutdownMs?: number } = {}) {
  const storage = memoryStorage();
  const secrets = memorySecrets();
  const rec = recordingInvoke(options);
  const ctrl = new TVBridgeController({
    storage, secrets, invoke: rec.invoke,
    ...(options.idleShutdownMs === undefined ? {} : { idleShutdownMs: options.idleShutdownMs }),
  });
  ctrl.setEnabled(true);
  ctrl.setBinaryPath("C:\\Tools\\mbh-tv-bridge.exe");
  await ctrl.addDevice({ name: "卧室电视", roomName: "卧室", driver: "kodi_jsonrpc", host: "192.168.1.9" });
  await ctrl.settle();
  return { ctrl, storage, secrets, rec };
}

describe("TV bridge section", () => {
  let win: Window;
  let restoreCss: () => void;

  beforeEach(() => {
    win = mountTestWindow();
    restoreCss = installCssEscape();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    restoreCss();
    await closeTestWindow(win);
  });

  it("is off by default and makes zero IPC calls, even when the panel shows or hides", async () => {
    const rec = recordingInvoke();
    const ctrl = new TVBridgeController({ storage: memoryStorage(), secrets: memorySecrets(), invoke: rec.invoke });
    assert.equal(ctrl.enabled, false);
    ctrl.onPanelShown();
    ctrl.onPanelHidden();
    await ctrl.refresh();
    await assert.rejects(ctrl.execute({ kind: "mediaPlayPause", entityId: ID }));
    await ctrl.dispose();
    await ctrl.settle();
    assert.deepEqual(rec.calls, []);
    assert.equal(ctrl.panelDevices.length, 0);
    assert.match(renderTVBridgeSettingsSection(ctrl, esc), /data-tvbridge-toggle (?!checked)/);
  });

  it("renders the settings card with all eight drivers and default port hints", () => {
    const ctrl = new TVBridgeController({ storage: memoryStorage(), secrets: memorySecrets(), invoke: null });
    ctrl.setEnabled(true);
    const html = renderTVBridgeSettingsSection(ctrl, esc);
    assert.equal((html.match(/<option /g) ?? []).length, 8);
    assert.match(html, /data-port="6095"/);
    assert.match(html, /data-port="3001"/);
    assert.match(html, /data-tvbridge-status="missingBinary"/);
  });

  it("stores pairing secrets in their own slot and never in the saved config", async () => {
    const storage = memoryStorage();
    const secrets = memorySecrets();
    const ctrl = new TVBridgeController({ storage, secrets, invoke: null });
    ctrl.setEnabled(true);
    assert.equal(await ctrl.addDevice({ name: "Sony", roomName: "", driver: "sony_bravia", host: "192.168.1.2", secret: "psk-sony-1234" }), true);
    assert.equal(await ctrl.addDevice({ name: "Kodi", roomName: "", driver: "kodi_jsonrpc", host: "192.168.1.3", secret: "ignored" }), true);
    const saved = storage.data[TV_BRIDGE_STORAGE_KEY] ?? "";
    assert.doesNotMatch(saved, /psk-sony-1234/);
    assert.doesNotMatch(saved, /ignored/);
    const [sony, kodi] = ctrl.config.devices;
    assert.equal(secrets.data.get(sony!.credentialSlot!), "psk-sony-1234");
    assert.equal(kodi!.credentialSlot, undefined);
    await ctrl.removeDevice(sony!.nativeId);
    assert.equal(secrets.data.size, 0);
  });

  it("persists the add form through delegated events without the secret", async () => {
    const storage = memoryStorage();
    const ctrl = new TVBridgeController({ storage, secrets: memorySecrets(), invoke: null });
    ctrl.setEnabled(true);
    const root = win.document.createElement("div") as unknown as HTMLElement;
    win.document.body.appendChild(root as never);
    root.innerHTML = renderTVBridgeSettingsSection(ctrl, esc);
    bindTVBridgeEvents(root, ctrl);
    const form = root.querySelector<HTMLFormElement>("[data-tvbridge-form]")!;
    (form.elements.namedItem("name") as HTMLInputElement).value = "LG";
    (form.elements.namedItem("host") as HTMLInputElement).value = "192.168.1.5";
    const driver = form.elements.namedItem("driver") as HTMLSelectElement;
    driver.value = "lg_webos";
    driver.dispatchEvent(new win.Event("change", { bubbles: true }) as unknown as Event);
    const secret = form.elements.namedItem("secret") as HTMLInputElement;
    assert.equal(secret.hidden, false);
    secret.value = "lg-client-key";
    form.dispatchEvent(new win.Event("submit", { bubbles: true, cancelable: true }) as unknown as Event);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(ctrl.config.devices[0]?.driver, "lg_webos");
    assert.doesNotMatch(storage.data[TV_BRIDGE_STORAGE_KEY] ?? "", /lg-client-key/);
  });

  it("keeps a built-in TV with the same id or name; the bridge never takes it over", () => {
    const builtIn = tv("media_player.tv", "客厅 电视");
    const rows = nonHijackingTVBridgeRows([tv("adapter:com.menubarhome.tv-bridge:a", "客厅电视"), tv(ID, "卧室电视")], [builtIn]);
    assert.deepEqual(rows.map((d) => d.id), [ID]);
  });

  it("snapshots once a TV is added and routes drawer commands to control.execute", async () => {
    const { ctrl, rec } = await enabledController();
    // The panel is closed while the bridge starts, so it is told so right away (and may stop when idle).
    assert.deepEqual(rec.methods(), ["tv_bridge_start", "initialize", "host.contextChanged", "snapshot"]);
    const row = ctrl.panelDevices[0]!;
    assert.equal(row.id, ID);
    assert.equal(row.kind.kind === "tv" && row.kind.muteSwitchEntityId, `${ID}#mute`);

    assert.deepEqual(toTVBridgeCommand({ kind: "setSwitch", entityId: `${ID}#mute`, isOn: true }), { deviceId: ID, command: { kind: "setMute", isMuted: true } });
    assert.deepEqual(toTVBridgeCommand({ kind: "setSwitch", entityId: ID, isOn: false }), { deviceId: ID, command: { kind: "power", isOn: false } });
    assert.deepEqual(toTVBridgeCommand({ kind: "remoteSendKey", entityId: ID, key: "up" }), { deviceId: ID, command: { kind: "remoteKey", key: "up" } });
    assert.equal(toTVBridgeCommand({ kind: "mediaPlayPause", entityId: "media_player.tv" }), null);

    await ctrl.execute({ kind: "mediaSeek", entityId: ID, positionSec: 42 });
    await ctrl.settle();
    const exec = rec.calls.find((c) => c.frame?.method === "control.execute")!;
    const params = exec.frame!.params as { nativeId: string; verb: string; args: { position: number } };
    assert.equal(params.nativeId, "tv-a");
    assert.equal(params.verb, "media.seek");
    assert.equal(params.args.position, 42);
  });

  it("sleeps on hide, shuts down on dispose and on switch-off", async () => {
    const { ctrl, rec } = await enabledController();
    ctrl.onPanelHidden();
    await ctrl.settle();
    assert.equal(rec.methods().at(-1), "host.contextChanged");
    await ctrl.dispose();
    assert.deepEqual(rec.methods().slice(-2), ["shutdown", "tv_bridge_shutdown"]);

    const second = await enabledController();
    second.ctrl.setEnabled(false);
    await second.ctrl.settle();
    assert.deepEqual(second.rec.methods().slice(-2), ["shutdown", "tv_bridge_shutdown"]);
    assert.equal(second.ctrl.panelDevices.length, 0);
    assert.equal(second.ctrl.status, "disabled");
  });

  it("shows a friendly hint instead of throwing when the native command is missing", async () => {
    const ctrl = new TVBridgeController({
      storage: memoryStorage(), secrets: memorySecrets(),
      invoke: async () => { throw new Error("command tv_bridge_start not found"); },
    });
    ctrl.setEnabled(true);
    ctrl.setBinaryPath("C:\\mbh-tv-bridge.exe");
    await ctrl.addDevice({ name: "TV", roomName: "", driver: "kodi_jsonrpc", host: "192.168.1.9" });
    await ctrl.settle();
    assert.equal(ctrl.status, "failed");
    assert.match(ctrl.error ?? "", /更新应用/);
  });

  it("keeps a built-in TV with the same MAC under another name; the bridge card never doubles it", async () => {
    assert.deepEqual(tvBridgeDescriptorMacs({ nativeId: "a", name: "x", identity: { macAddresses: ["AA:BB:CC:DD:EE:FF"] }, macAddress: "aa-bb-cc-dd-ee-ff" }), ["aabbccddeeff"]);
    const living = tv("media_player.living", "客厅大屏");
    const miot = tv("miot_112233445566", "卧室电视");
    const bySame = tv("adapter:com.menubarhome.tv-bridge:a", "Sony KD-65");
    const byId = tv("adapter:com.menubarhome.tv-bridge:b", "Bedroom LG");
    const unique = tv("adapter:com.menubarhome.tv-bridge:c", "书房电视");
    const macs: Record<string, string[]> = { [bySame.id]: ["AA:BB:CC:DD:EE:FF"], [byId.id]: ["11-22-33-44-55-66"], [unique.id]: ["010203040506"] };
    const rows = nonHijackingTVBridgeRows([bySame, byId, unique], [living, miot], {
      macsFor: (row) => macs[row.id] ?? [],
      builtInIdentifiers: (d) => (d.id === living.id ? [d.id, "aa:bb:cc:dd:ee:ff"] : [d.id]),
    });
    assert.deepEqual(rows.map((d) => d.id), [unique.id]);

    const { ctrl } = await enabledController({ rows: [{ nativeId: "tv-a", name: "Sony KD-65", online: true, identity: { macAddresses: ["11:22:33:44:55:66"] } }] });
    assert.deepEqual(ctrl.macsFor(ID), ["112233445566"]);
    assert.deepEqual(nonHijackingTVBridgeRows(ctrl.panelDevices, [miot], { macsFor: (row) => ctrl.macsFor(row.id) }), []);
  });

  it("runs bridge writes through the capability gate: a closed TV type sends no tv_bridge_request", async () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false }));
    const { ctrl, rec } = await enabledController();
    setTVBridgeControllerForTesting(ctrl);
    try {
      const root = win.document.querySelector("#app") as unknown as HTMLElement;
      const app = new MenuMijiaWindowsApp(root);
      app.settings.connectionMode = "homeAssistant";
      assert.ok(app.devices.some((d) => d.id === ID), "the bridged TV joins the panel rows");

      assert.equal(app.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS.filter((id) => id !== "tv")), true);
      const before = rec.calls.length;
      assert.equal(await applyCommand(app, { kind: "mediaPlayPause", entityId: ID }), false);
      assert.equal(rec.calls.slice(before).filter((c) => c.cmd === "tv_bridge_request").length, 0);
      assert.equal(app.replyBanner?.isError, true);

      assert.equal(app.setEnabledDeviceCategories([...DEVICE_CATEGORY_IDS]), true);
      assert.equal(await applyCommand(app, { kind: "mediaPlayPause", entityId: ID }), true);
      assert.equal(rec.calls.slice(before).filter((c) => c.frame?.method === "control.execute").length, 1);
    } finally {
      setTVBridgeControllerForTesting(null);
    }
  });

  it("re-checks right before the write and sends nothing once the switch is off", async () => {
    const { ctrl, rec } = await enabledController();
    await assert.rejects(ctrl.execute({ kind: "mediaPlayPause", entityId: ID }, async () => {
      ctrl.setEnabled(false);
      return true;
    }));
    await ctrl.settle();
    assert.equal(rec.calls.filter((c) => c.frame?.method === "control.execute").length, 0);
  });

  it("stops an idle bridge after the panel hides, and reopening cancels the timer", async () => {
    const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
    const { ctrl, rec } = await enabledController({ idleShutdownMs: 5 });
    ctrl.onPanelShown();
    await ctrl.settle();
    ctrl.onPanelHidden();
    await ctrl.settle();
    ctrl.onPanelShown();
    await wait(25);
    await ctrl.settle();
    assert.ok(!rec.methods().includes("tv_bridge_shutdown"), "reopening must cancel the idle stop");

    ctrl.onPanelHidden();
    await ctrl.settle();
    await wait(25);
    await ctrl.settle();
    assert.deepEqual(rec.methods().slice(-2), ["shutdown", "tv_bridge_shutdown"]);
  });

  it("shuts the process down when the switch goes off mid-start or initialize fails, and keeps no rows", async () => {
    let release!: () => void;
    const startGate = new Promise<void>((resolve) => { release = resolve; });
    const rec = recordingInvoke({ startGate });
    const ctrl = new TVBridgeController({ storage: memoryStorage(), secrets: memorySecrets(), invoke: rec.invoke });
    ctrl.setEnabled(true);
    ctrl.setBinaryPath("C:\\Tools\\mbh-tv-bridge.exe");
    const adding = ctrl.addDevice({ name: "卧室电视", roomName: "", driver: "kodi_jsonrpc", host: "192.168.1.9" });
    await adding;
    assert.equal(rec.methods().at(-1), "tv_bridge_start");
    ctrl.setEnabled(false);
    release();
    await ctrl.settle();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(rec.methods().at(-1), "tv_bridge_shutdown");
    assert.ok(!rec.methods().includes("snapshot"));
    assert.equal(ctrl.panelDevices.length, 0);
    assert.equal(ctrl.status, "disabled");

    const failed = await enabledController({ failInitialize: true });
    assert.deepEqual(failed.rec.methods(), ["tv_bridge_start", "initialize", "tv_bridge_shutdown"]);
    assert.equal(failed.ctrl.panelDevices.length, 0);
    assert.equal(failed.ctrl.status, "failed");
  });

  it("cancels a bridge write when the source or home changes while the bridge is starting", async () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false }));
    const { ctrl, rec } = await enabledController();
    setTVBridgeControllerForTesting(ctrl);
    try {
      const root = win.document.querySelector("#app") as unknown as HTMLElement;
      const app = new MenuMijiaWindowsApp(root);
      app.settings.connectionMode = "homeAssistant";
      await ctrl.dispose();
      let release!: () => void;
      rec.gate.next = new Promise<void>((resolve) => { release = resolve; });
      const before = rec.calls.length;
      const writing = applyCommand(app, { kind: "mediaPlayPause", entityId: ID });
      while (!rec.calls.slice(before).some((c) => c.cmd === "tv_bridge_start")) await new Promise((r) => setTimeout(r, 0));
      app.sourceEpoch.advance("home");
      release();
      assert.equal(await writing, false);
      await ctrl.settle();
      assert.equal(rec.calls.slice(before).filter((c) => c.frame?.method === "control.execute").length, 0);
    } finally {
      setTVBridgeControllerForTesting(null);
    }
  });

  it("arms the idle stop when the panel closed while the bridge was still starting", async () => {
    let release!: () => void;
    const rec = recordingInvoke({ startGate: new Promise<void>((resolve) => { release = resolve; }) });
    const ctrl = new TVBridgeController({ storage: memoryStorage(), secrets: memorySecrets(), invoke: rec.invoke, idleShutdownMs: 5 });
    ctrl.onPanelShown();
    ctrl.setEnabled(true);
    ctrl.setBinaryPath("C:\\Tools\\mbh-tv-bridge.exe");
    await ctrl.addDevice({ name: "卧室电视", roomName: "", driver: "kodi_jsonrpc", host: "192.168.1.9" });
    ctrl.onPanelHidden();
    release();
    await ctrl.settle();
    assert.ok(rec.methods().includes("host.contextChanged"));
    await new Promise((resolve) => setTimeout(resolve, 25));
    await ctrl.settle();
    assert.deepEqual(rec.methods().slice(-2), ["shutdown", "tv_bridge_shutdown"]);
  });

  it("never lets a stale stop kill the process a quick re-enable started", async () => {
    let release!: () => void;
    const rec = recordingInvoke({ startGate: new Promise<void>((resolve) => { release = resolve; }) });
    const ctrl = new TVBridgeController({ storage: memoryStorage(), secrets: memorySecrets(), invoke: rec.invoke });
    ctrl.onPanelShown();
    ctrl.setEnabled(true);
    ctrl.setBinaryPath("C:\\Tools\\mbh-tv-bridge.exe");
    await ctrl.addDevice({ name: "卧室电视", roomName: "", driver: "kodi_jsonrpc", host: "192.168.1.9" });
    ctrl.setEnabled(false);
    ctrl.setEnabled(true);
    release();
    await ctrl.settle();
    const methods = rec.methods();
    assert.equal(methods.filter((m) => m === "tv_bridge_start").length, 2, methods.join(","));
    assert.ok(methods.indexOf("tv_bridge_shutdown") > methods.indexOf("tv_bridge_start"), methods.join(","));
    assert.ok(methods.lastIndexOf("tv_bridge_shutdown") < methods.lastIndexOf("tv_bridge_start"), methods.join(","));
    assert.equal(methods.at(-1), "snapshot");
    assert.equal(ctrl.status, "running");
    assert.equal(ctrl.panelDevices.length, 1);
  });
});
