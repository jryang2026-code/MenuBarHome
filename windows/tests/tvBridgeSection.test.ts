import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice, TvSpec } from "../src/core/models.js";
import type { TVBridgeFrame } from "../src/core/tvBridgePlugin.js";
import {
  TV_BRIDGE_STORAGE_KEY,
  TVBridgeController,
  bindTVBridgeEvents,
  nonHijackingTVBridgeRows,
  renderTVBridgeSettingsSection,
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

function recordingInvoke() {
  const calls: { cmd: string; frame?: TVBridgeFrame; args?: Record<string, unknown> }[] = [];
  const invoke = async (cmd: string, args?: Record<string, unknown>) => {
    const frame = args?.frame as TVBridgeFrame | undefined;
    calls.push({ cmd, frame, args });
    if (cmd !== "tv_bridge_request" || !frame) return null;
    const result = frame.method === "snapshot"
      ? { capturedAt: "now", devices: [{ nativeId: "tv-a", name: "卧室电视", online: true, state: "on", volume: 20, muted: false }] }
      : {};
    return { jsonrpc: "2.0", id: frame.id, result };
  };
  const methods = () => calls.map((c) => c.frame?.method ?? c.cmd);
  return { calls, invoke, methods };
}

function tv(id: string, name: string): SmartDevice {
  const kind: TvSpec = { kind: "tv", mediaEntityId: id, state: "on", volumePercent: 10, currentSource: null, availableSources: [], volumeWritable: true };
  return { id, name, roomId: "r", roomName: "客厅", model: "tv", isOnline: true, kind };
}

async function enabledController() {
  const storage = memoryStorage();
  const secrets = memorySecrets();
  const rec = recordingInvoke();
  const ctrl = new TVBridgeController({ storage, secrets, invoke: rec.invoke });
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
    assert.deepEqual(rec.methods(), ["tv_bridge_start", "initialize", "snapshot"]);
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
});
