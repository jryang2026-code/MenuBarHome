import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, element, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudChannelWriteBatcher } from "../src/core/miCloud/channelWriteBatcher.js";
import { MiCloudClient, type MiotPropWrite } from "../src/core/miCloud/client.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { claimDeviceWrite } from "../src/core/optimisticLock.js";
import { miSessionFingerprint, storeCachedXiaomiTopology } from "../src/core/pollingPolicy.js";
import { setChannelWriteBatcherForTesting, waitForSliderMailboxIdle } from "../src/ui/commandDispatch.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";

async function waitUntil(predicate: () => boolean, label: string, maxTicks = 300): Promise<void> {
  for (let i = 0; i < maxTicks; i += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(`Timed out waiting for: ${label}`);
}

const mkLight = (id: string, brightness: number, colorTemp: number): SmartDevice => ({
  id, name: id, roomId: "room", roomName: "Room", model: "ha.light", isOnline: true, sourceBackend: "homeAssistant",
  kind: {
    kind: "light", entityId: `light.${id}`, isOn: true, brightnessPercent: brightness, colorTempKelvin: colorTemp,
    minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [],
  },
});

const mkCover = (id: string, pos: number, subtype: "window-opener" | "garage-door"): SmartDevice => ({
  id, name: id, roomId: "room", roomName: "Room", model: "ha.cover", isOnline: true, sourceBackend: "homeAssistant",
  kind: {
    kind: "cover", entityId: `cover.${id}`, subtype, positionPercent: pos, motion: "stopped", positionWritable: true,
    openDescription: null, closeDescription: null, pauseDescription: null, batteryPercent: null, faultText: null,
  },
});

function mountMoodApp(devices: SmartDevice[]): MenuMijiaWindowsApp {
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: { invoke: async () => false } });
  const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  app.settings.connectionMode = "homeAssistant";
  app.settings.haBaseURL = "http://homeassistant.local:8123";
  app.refreshDevices = async () => {};
  app.devices = structuredClone(devices);
  return app;
}

let dom: Window;
beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});
afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Windows control write safety gates (H-01 / H-10 / H-03 / H-04)", () => {
  it("H-01: a manual write to device A while slow B is still applying keeps A out of the mood undo", async () => {
    const app = mountMoodApp([mkLight("a", 40, 3200), mkLight("b", 40, 3200)]);
    assert.equal(app.captureMood("Read", "room"), true);
    const moodId = app.moods[0]!.id;
    app.devices = [mkLight("a", 90, 5000), mkLight("b", 90, 5000)];

    const sent: DeviceCommand[] = [];
    const held: Array<() => void> = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      if (cmd.entityId === "light.b") await new Promise<void>((r) => { held.push(r); });
      return true;
    };

    const run = app.applyMood(moodId);
    await waitUntil(() => held.length === 1, "slow B write in flight");
    // The user takes A over mid-flight and publishes their own undo banner.
    claimDeviceWrite(app, "a");
    const manualUndo = { summary: "manual A", steps: [{ deviceId: "a", commands: [] }], expiresAtMs: Date.now() + 8_000 };
    app.lastUndoAction = manualUndo;
    while (held.length > 0) { held.shift()!(); await setImmediate(); }
    assert.equal((await run).status, "executed");

    assert.equal(app.lastUndoAction, manualUndo, "the mood must not overwrite the newer undo banner");
  });

  it("H-01: a device taken over after the mood finished receives no stale restore on Undo", async () => {
    const app = mountMoodApp([mkLight("a", 40, 3200), mkLight("b", 40, 3200)]);
    assert.equal(app.captureMood("Read", "room"), true);
    const moodId = app.moods[0]!.id;
    app.devices = [mkLight("a", 90, 5000), mkLight("b", 90, 5000)];

    const sent: DeviceCommand[] = [];
    const held: Array<() => void> = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      if (cmd.entityId === "light.b") await new Promise<void>((r) => { held.push(r); });
      return true;
    };
    const run = app.applyMood(moodId);
    await waitUntil(() => held.length === 1, "slow B write in flight");
    claimDeviceWrite(app, "a"); // A taken over mid-flight, no new undo banner
    while (held.length > 0) { held.shift()!(); await setImmediate(); }
    assert.equal((await run).status, "executed");
    assert.ok(app.lastUndoAction, "mood still publishes undo for B");
    assert.deepEqual(app.lastUndoAction!.steps.map((s) => s.deviceId), ["b"]);

    const before = sent.length;
    app.applyCommand = async (cmd) => { sent.push(cmd); return true; };
    await app.performUndo();
    const undo = sent.slice(before);
    assert.ok(undo.length > 0 && undo.every((c) => c.entityId === "light.b"), "only B is restored");

    // Taking B over after publication also drops it from a later undo.
    const app2 = mountMoodApp([mkLight("a", 40, 3200), mkLight("b", 40, 3200)]);
    assert.equal(app2.captureMood("Read", "room"), true);
    app2.devices = [mkLight("a", 90, 5000), mkLight("b", 90, 5000)];
    const sent2: DeviceCommand[] = [];
    app2.applyCommand = async (cmd) => { sent2.push(cmd); return true; };
    assert.equal((await app2.applyMood(app2.moods[0]!.id)).status, "executed");
    claimDeviceWrite(app2, "a");
    const before2 = sent2.length;
    await app2.performUndo();
    const undo2 = sent2.slice(before2);
    assert.ok(undo2.length > 0 && undo2.every((c) => c.entityId === "light.b"));
    app.dispose();
    app2.dispose();
  });

  it("H-10: undo restores the plan-time cover baseline, not a value refreshed behind the confirmation", async () => {
    const app = mountMoodApp([mkCover("garage", 100, "garage-door")]);
    app.lastCoverPositions["garage"] = 100;
    assert.equal(app.captureMood("Open", "room"), true);
    const moodId = app.moods[0]!.id;
    app.devices = [mkCover("garage", 0, "garage-door")];
    app.lastCoverPositions["garage"] = 0;

    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => { sent.push(cmd); return true; };
    app.manualControlConfirmationHandler = () => {
      app.devices = [mkCover("garage", 80, "garage-door")];
      app.lastCoverPositions["garage"] = 80;
      return true;
    };
    assert.equal((await app.applyMood(moodId)).status, "executed");
    assert.ok(sent.some((c) => c.kind === "setNumberValue" && c.value === 100));

    app.manualControlConfirmationHandler = () => true;
    const before = sent.length;
    await app.performUndo();
    await app.performUndo(); // second tap confirms the high-risk restore when armed
    const restores = sent.slice(before).filter((c) => c.kind === "setNumberValue");
    assert.equal(restores.length, 1);
    assert.equal((restores[0] as { value: number }).value, 0);
    app.dispose();
  });

  it("H-03: screen locking after the entry check sends zero LAN and zero cloud channel writes", async () => {
    const did = "101";
    const spec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:outlet:0000A002:test:1",
      services: [2, 3].map((siid) => ({
        iid: siid, type: "urn:miot-spec-v2:service:outlet:00007805:test:1", actions: [],
        properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test:1", format: "bool", access: ["read", "write"] }],
      })),
    };
    const plug: SmartDevice = {
      id: `${did}.s2`, name: "Outlet", roomId: "room", roomName: "Room", model: "test.switch.strip", isOnline: true,
      kind: { kind: "plug", switchEntityId: `miot:${did}:2`, isOn: true, powerWatts: null, energyKwh: null, childLockEntityId: null, isChildLocked: false, powerWritable: true },
    };
    let locked = false;
    let lockChecks = 0;
    const lanWrites: string[] = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd.startsWith("miio_")) { lanWrites.push(cmd); return null; }
          if (cmd !== "is_workstation_locked") return null;
          lockChecks += 1;
          const value = locked;
          locked = true; // the screen locks right after the entry check returned "unlocked"
          return value;
        },
      },
    });
    const session = { userId: "test", cUserId: "test", region: "cn", ssecurity: "test", serviceToken: "test", passToken: "test" };
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud", hasCompletedOnboarding: true, autoCheckUpdates: false,
      blockControlWhileLocked: true, miSession: session,
    }));
    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    app.refreshDevices = async () => {};
    app.devices = [structuredClone(plug)];
    app.specResolver.resolve = async () => spec;
    const raw = MiCloudClient.parseDeviceRecord({
      did, model: "test.switch.strip", localip: "192.168.1.42", pid: 0, token: "0123456789abcdef0123456789abcdef",
    })!;
    storeCachedXiaomiTopology(app, {
      sessionFingerprint: miSessionFingerprint(session), sourceRevision: app.sourceRevision,
      selectedHomeId: null, allDevices: [raw], allRooms: [], rawDevices: [raw], rooms: [],
      specs: {}, membersByGroup: new Map(),
    });

    const writes: MiotPropWrite[][] = [];
    const origRequest = MiCloudClient.prototype.request;
    MiCloudClient.prototype.request = async function (api: string, data: unknown): Promise<unknown> {
      if (api === "miotspec/prop/set") {
        const params = (data as { params: MiotPropWrite[] }).params;
        writes.push(params);
        return params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0 }));
      }
      return origRequest.call(this, api, data);
    };
    setChannelWriteBatcherForTesting(app, new MiCloudChannelWriteBatcher({ sleep: async () => {} }));
    try {
      await app.executeSingleCommand(app.devices[0]!, { kind: "setSwitch", entityId: `miot:${did}:2`, isOn: false }, "关闭插座");
      await setImmediate();
      assert.ok(lockChecks >= 2, "lock is re-checked at send time");
      assert.equal(writes.length, 0, "zero cloud writes after the screen locked");
      assert.equal(lanWrites.length, 0, "zero LAN writes after the screen locked");
    } finally {
      MiCloudClient.prototype.request = origRequest;
      app.dispose();
    }
  });

  it("H-04: a queued closing write that would now open a window opener is refused at drain time", async () => {
    const executed: Array<{ entity_id: string; data: Record<string, unknown> }> = [];
    const held: Array<() => void> = [];
    let holdNext = false;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}): Promise<unknown> => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd === "ha_execute") {
            executed.push(args.command as typeof executed[number]);
            if (holdNext) { holdNext = false; await new Promise<void>((r) => { held.push(r); }); }
            return null;
          }
          return cmd === "ha_snapshot" ? { areas: [], devices: [], entities: [], states: [] } : null;
        },
      },
    });
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "homeAssistant", hasCompletedOnboarding: true, autoCheckUpdates: false,
      haBaseURL: "https://ha.example.test", haToken: "tok",
    }));
    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    app.refreshDevices = async () => {};
    app.refreshHADevices = async () => {};
    app.devices = [mkCover("win", 100, "window-opener")];
    app.expandedDeviceId = "win";
    app.render();
    await setImmediate();

    let externalPositionAfterWrite: number | null = null;
    const original = app.executeSingleCommand.bind(app);
    app.executeSingleCommand = async (...args: Parameters<typeof original>) => {
      await original(...args);
      const live = app.devices.find((d) => d.id === "win")!;
      if (externalPositionAfterWrite !== null && live.kind.kind === "cover") live.kind.positionPercent = externalPositionAfterWrite;
    };

    holdNext = true;
    let slider = element<HTMLInputElement>('[data-coverpos="win"]');
    slider.value = "80";
    slider.dispatchEvent(new Event("change", { bubbles: true }));
    await waitUntil(() => executed.length === 1 && held.length === 1, "80% (closing) write in flight");

    app.render();
    slider = element<HTMLInputElement>('[data-coverpos="win"]');
    slider.value = "50";
    slider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(executed.length, 1, "50% is queued behind the in-flight write");

    // An external controller closes the window to 20%; the refresh lands right after the
    // in-flight write settles and before the queued 50% drains.
    externalPositionAfterWrite = 20;
    held.shift()!();
    await waitForSliderMailboxIdle(app, "win.coverpos");

    assert.deepEqual(executed.map((c) => c.data.position), [80], "no unconfirmed opening write is sent");
    assert.match(app.replyBanner?.text ?? "", /会打开/);
    app.dispose();
  });
});
