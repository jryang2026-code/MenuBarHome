import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, element, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudClient } from "../src/core/miCloud/client.js";
import { miSessionFingerprint, storeCachedXiaomiTopology } from "../src/core/pollingPolicy.js";
import { getFieldWriteEpoch, mergeHomeSnapshotRespectingLocks } from "../src/core/optimisticLock.js";
import {
  getSliderMailboxStatsForTesting,
  setSliderMailboxTimingForTesting,
  sliderUsesLAN,
  submitSliderWrite,
  waitForSliderMailboxIdle,
} from "../src/ui/commandDispatch.js";
import type { SmartDevice } from "../src/core/models.js";

class SleepGate {
  private waiters: Array<() => void> = [];
  public parkCount = 0;
  get waiting(): number { return this.waiters.length; }
  sleep(): Promise<void> {
    this.parkCount += 1;
    return new Promise((resolve) => { this.waiters.push(resolve); });
  }
  release(): void { this.waiters.shift()?.(); }
}

async function waitUntil(predicate: () => boolean, label: string, maxTicks = 200): Promise<void> {
  for (let i = 0; i < maxTicks; i += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(`Timed out waiting for: ${label}`);
}

const makeLight = (id = "lamp", brightnessPercent = 10): SmartDevice => ({
  id, name: "Lamp", roomId: "room", roomName: "Room", model: "light", isOnline: true,
  kind: {
    kind: "light", entityId: `light.${id}`, isOn: true, brightnessPercent,
    colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500,
    availableEffects: [], currentEffect: null, brightnessWritable: true,
  },
});

const makeGarageCover = (id = "garage", positionPercent = 10): SmartDevice => ({
  id, name: "Garage", roomId: "room", roomName: "Room", model: "garage", isOnline: true,
  kind: {
    kind: "cover", entityId: `cover.${id}`, subtype: "garage-door", positionPercent,
    motion: "stopped", positionWritable: true,
    openDescription: null, closeDescription: null, pauseDescription: null, batteryPercent: null, faultText: null,
  },
});

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

function mountHAApp(haBaseURL: string, devices: SmartDevice[]) {
  const executed: Array<{ domain: string; service: string; entity_id: string; data: Record<string, unknown> }> = [];
  let holdNext = false;
  const held: Array<() => void> = [];
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
    connectionMode: "homeAssistant", hasCompletedOnboarding: true, autoCheckUpdates: false, haBaseURL, haToken: "tok",
  }));
  const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  app.devices = structuredClone(devices);
  app.render();
  return {
    app, executed,
    holdNextExecute: () => { holdNext = true; },
    releaseExecute: () => { const fn = held.shift(); assert.ok(fn); fn(); },
    heldCount: () => held.length,
  };
}

describe("Continuous control mailbox (slider coalescing & writeEpoch parity with #506)", () => {
  for (const lan of [true, false]) {
    for (const inputCount of [4, 50]) {
      it(`drag keeps one follow-up and advances writeEpoch (lan=${lan}, inputs=${inputCount})`, async () => {
        const lamp = makeLight("lamp", 10);
        const { app, executed, holdNextExecute, releaseExecute, heldCount } = mountHAApp(
          lan ? "http://homeassistant.local:8123" : "https://ha.example.test",
          [lamp],
        );
        await setImmediate();
        const sleepGate = new SleepGate();
        let fakeNow = 10_000;
        setSliderMailboxTimingForTesting(app, {
          now: () => fakeNow,
          sleep: async (ms) => { assert.equal(ms, 100); await sleepGate.sleep(); fakeNow += ms; },
        });
        assert.equal(sliderUsesLAN(app, { kind: "setLightBrightness", entityId: "light.lamp", percent: 11 }, lamp), lan);

        holdNextExecute();
        const send = (percent: number) => submitSliderWrite(app, {
          slotKey: "lamp.brightness", device: app.devices[0]!,
          command: { kind: "setLightBrightness", entityId: "light.lamp", percent },
          summary: `亮度 ${percent}%`, intent: { targetId: "lamp", operation: { kind: "brightness", percent } },
          isLiveInput: lan,
        });
        void send(11);
        await waitUntil(() => executed.length === 1 && heldCount() === 1, "first write in flight");

        const lastValue = 10 + inputCount;
        for (let v = 12; v <= lastValue; v += 1) void send(v);
        assert.equal(executed.length, 1);
        assert.deepEqual(getSliderMailboxStatsForTesting(app, "lamp.brightness"), {
          inFlight: true, hasPending: true, startedCount: 1,
        });

        if (!lan) holdNextExecute();
        releaseExecute();
        await waitUntil(() => getFieldWriteEpoch(app, "lamp", "brightnessPercent") !== undefined, "first epoch");
        const firstEpoch = getFieldWriteEpoch(app, "lamp", "brightnessPercent")!;

        if (lan) {
          await waitUntil(() => sleepGate.waiting === 1, "LAN 100 ms cooldown");
          assert.equal(executed.length, 1);
          sleepGate.release();
          await waitUntil(() => sleepGate.parkCount === 2 && sleepGate.waiting === 1, "LAN post-followup cooldown");
          sleepGate.release();
        } else {
          await waitUntil(() => executed.length === 2 && heldCount() === 1, "follow-up in flight");
          releaseExecute();
        }
        await waitForSliderMailboxIdle(app, "lamp.brightness");

        assert.deepEqual(executed.map((c) => c.data.brightness_pct), [11, lastValue]);
        const finalEpoch = getFieldWriteEpoch(app, "lamp", "brightnessPercent")!;
        assert.ok(finalEpoch > firstEpoch);

        const merged = mergeHomeSnapshotRespectingLocks(
          app, [makeLight("lamp", 10)], undefined, Date.now() + 10_000, undefined, firstEpoch,
        );
        assert.equal(merged.devices[0]?.kind.kind === "light" && merged.devices[0].kind.brightnessPercent, lastValue);
      });
    }
  }

  it("detects LAN route for miIO LAN-eligible devices from cached Xiaomi topology (#478)", () => {
    const token = "0123456789abcdef0123456789abcdef";
    const session = { userId: "1", cUserId: "", region: "cn", ssecurity: "s", serviceToken: "t", passToken: "p" };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: { invoke: async () => null } });
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "xiaomiCloud", hasCompletedOnboarding: true, autoCheckUpdates: false, miSession: session,
    }));
    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    const raw = MiCloudClient.parseDeviceRecord({
      did: "1001", model: "yeelink.light.lamp4", localip: "192.168.1.42", pid: 0, token,
    })!;
    storeCachedXiaomiTopology(app, {
      sessionFingerprint: miSessionFingerprint(session), sourceRevision: app.sourceRevision,
      selectedHomeId: null, allDevices: [raw], allRooms: [], rawDevices: [raw], rooms: [],
      specs: {}, membersByGroup: new Map(),
    });
    assert.equal(sliderUsesLAN(app, { kind: "setLightBrightness", entityId: "miot:1001:2", percent: 50 }), true);
    assert.equal(sliderUsesLAN(app, { kind: "setLightBrightness", entityId: "miot:9999:2", percent: 50 }), false);
  });

  it("high-risk LAN control has no leading edge on drag and keeps confirmation/debounce", async () => {
    const garage = makeGarageCover("garage", 10);
    const { app, executed } = mountHAApp("http://homeassistant.local:8123", [garage]);
    await setImmediate();
    app.expandedDeviceId = "garage";
    app.render();

    const slider = element<HTMLInputElement>('[data-coverpos="garage"]');
    for (const val of ["25", "50", "70"]) {
      slider.value = val;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    }
    await setImmediate();
    assert.equal(executed.length, 0, "no leading edge on high-risk drag");

    slider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(executed.length, 0, "first change arms confirmation");
    assert.match(app.replyBanner?.text ?? "", /再点一次确认执行/);

    const sleepGate = new SleepGate();
    setSliderMailboxTimingForTesting(app, { sleep: () => sleepGate.sleep() });
    const pending = submitSliderWrite(app, {
      slotKey: "garage.coverpos", device: garage,
      command: { kind: "setNumberValue", entityId: "cover.garage", value: 70 },
      summary: "车库门 70%", isLiveInput: true, debounceHighRisk: true,
    });
    await waitUntil(() => sleepGate.waiting === 1, "high-risk debounce armed");
    assert.equal(executed.length, 0);
    sleepGate.release();
    await pending;
    assert.equal(executed.length, 1);
    assert.equal(executed[0]?.data.position, 70);
  });
});
