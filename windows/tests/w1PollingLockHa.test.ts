import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { signOutXiaomiAccount } from "../src/ui/appLifecycle.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { isWorkstationLockBlockingControl, isWorkstationLocked } from "../src/ui/transport.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import {
  MiCloudClient,
  MiCloudError,
  MiotSynthesizer,
  parseMiotDeviceSpec,
  type MiSession,
} from "../src/core/miCloudClient.js";
import {
  MI_SESSION_EXPIRED_STORAGE_KEY,
  PollingPolicy,
  describePollingContext,
  getXiaomiBackoffUntilMs,
  isPersistedMiSessionExpired,
  isXiaomiRateLimitError,
  recordXiaomiRateLimit,
  shouldSkipSilentPollForBackoff,
} from "../src/core/pollingPolicy.js";
import { HomeAssistantSynthesizer, haServiceCall, parseCachedHAHome } from "../src/core/homeAssistant.js";
import { cloudRefreshDue, deviceStatusSummary } from "../src/core/models.js";
import { setLanguage } from "../src/core/i18n.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

const SETTINGS_KEY = "menumijia.windows.settings.v2";
const LIGHT_MODEL = "yeelink.light.lamp4";

const SESSION_A: MiSession = {
  userId: "88001122",
  cUserId: "c-88001122",
  ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
  serviceToken: "synthetic-service-token-alpha",
  passToken: "",
  region: "cn",
};

const SESSION_B: MiSession = {
  ...SESSION_A,
  serviceToken: "synthetic-service-token-beta",
};

const LIGHT_SPEC_RAW = {
  type: "urn:miot-spec-v2:device:light:0000A001:yeelink-lamp4:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:light:00007802:yeelink-lamp4:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:on:00000006:yeelink-lamp4:1",
          format: "bool",
          access: ["read", "write"],
        },
        {
          iid: 2,
          type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-lamp4:1",
          format: "uint8",
          access: ["read", "write"],
          valueRange: [1, 100, 1],
        },
      ],
    },
  ],
};

function parseFormBody(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of body.split("&")) {
    const idx = part.indexOf("=");
    if (idx > 0) {
      out[decodeURIComponent(part.slice(0, idx))] = decodeURIComponent(part.slice(idx + 1));
    }
  }
  return out;
}

function decryptMiPayload(body: string, ssecurity = SESSION_A.ssecurity): Record<string, unknown> {
  const form = parseFormBody(body);
  const nonce = form["_nonce"] ?? "";
  const data = form["data"] ?? "";
  const signed = MiCloudCrypto.signedNonce(ssecurity, nonce);
  return JSON.parse(MiCloudCrypto.decryptResponse(data, signed)) as Record<string, unknown>;
}

function okResponse(result: unknown): { status: number; headers: Record<string, string>; body: string } {
  return {
    status: 200,
    headers: {},
    body: JSON.stringify({ code: 0, message: "ok", result }),
  };
}

let dom: Window | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
});

afterEach(async () => {
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

describe("D5: Workstation lock fail-closed control guard (transport.ts)", () => {
  it("fails closed (returns true) when blockControlWhileLocked is enabled and is_workstation_locked throws", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "is_workstation_locked") {
            throw new Error("Win32 desktop probe failed");
          }
          return null;
        },
      },
    });

    assert.equal(
      await isWorkstationLockBlockingControl({ settings: { blockControlWhileLocked: true } }),
      true,
      "IPC error must fail closed when lock-screen guard is enabled",
    );
    assert.equal(
      await isWorkstationLockBlockingControl({ settings: { blockControlWhileLocked: false } }),
      false,
      "disabled guard does not block control",
    );
  });

  it("passes through explicit boolean verdicts and stays non-blocking without __TAURI_INTERNALS__", async () => {
    let locked = true;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => (cmd === "is_workstation_locked" ? locked : null),
      },
    });
    assert.equal(await isWorkstationLockBlockingControl({ settings: { blockControlWhileLocked: true } }), true);
    assert.equal(await isWorkstationLocked(), true);

    locked = false;
    assert.equal(await isWorkstationLockBlockingControl({ settings: { blockControlWhileLocked: true } }), false);
    assert.equal(await isWorkstationLocked(), false);

    Reflect.deleteProperty(window, "__TAURI_INTERNALS__");
    assert.equal(await isWorkstationLockBlockingControl({ settings: { blockControlWhileLocked: true } }), false);
    assert.equal(await isWorkstationLocked(), false);
  });

  it("blocks live device control end-to-end when is_workstation_locked throws", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "is_workstation_locked") throw new Error("IPC channel broken");
          return null;
        },
      },
    });
    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        blockControlWhileLocked: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );
    const root = document.querySelector<HTMLElement>("#app")!;
    const app = new MenuMijiaWindowsApp(root);
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const beforeOn = light.kind.kind === "light" ? light.kind.isOn : false;

    await app.executeSingleCommand(
      light,
      { kind: "setLightPower", entityId: light.kind.kind === "light" ? light.kind.entityId : "", isOn: !beforeOn },
      "切换灯光",
    );

    const afterLight = app.devices.find((d) => d.id === light.id)!;
    assert.equal(afterLight.kind.kind === "light" ? afterLight.kind.isOn : beforeOn, beforeOn);
    assert.equal(app.replyBanner?.isError, true);
  });
});

describe("A2: PollingPolicy cadence, 20-round topology split, 429 backoff, lock pause & session expiry", () => {
  it("matches macOS PollingPolicy intervals and rate-limit backoff schedule", () => {
    assert.equal(
      PollingPolicy.intervalMs({ panelVisible: true, systemActive: true, lowPower: false }),
      6_000,
    );
    assert.equal(
      PollingPolicy.intervalMs({ panelVisible: true, systemActive: true, lowPower: true }),
      6_000,
    );
    assert.equal(
      PollingPolicy.intervalMs({ panelVisible: false, systemActive: true, lowPower: false }),
      60_000,
    );
    assert.equal(
      PollingPolicy.intervalMs({ panelVisible: false, systemActive: true, lowPower: true }),
      180_000,
    );
    assert.equal(
      PollingPolicy.intervalMs({ panelVisible: true, systemActive: false, lowPower: false }),
      null,
    );
    assert.equal(describePollingContext({ panelVisible: false, systemActive: false, lowPower: false }), "paused (asleep or locked)");
    assert.equal(describePollingContext({ panelVisible: false, systemActive: true, lowPower: true }), "panel closed, low power");

    assert.deepEqual(
      [1, 2, 3, 4, 5, 6, 10].map((hit) => PollingPolicy.rateLimitBackoffMs(hit)),
      [60_000, 120_000, 240_000, 480_000, 900_000, 900_000, 900_000],
    );

    const host = {};
    const baseNow = 1_000_000;
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow), 60_000);
    assert.equal(shouldSkipSilentPollForBackoff(host, SESSION_A, baseNow + 59_999), true);
    assert.equal(shouldSkipSilentPollForBackoff(host, SESSION_A, baseNow + 60_000), false);
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow + 60_000), 120_000);
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow + 180_000), 240_000);
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow + 420_000), 480_000);
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow + 900_000), 900_000);
    assert.equal(recordXiaomiRateLimit(host, SESSION_A, baseNow + 1_800_000), 900_000);
  });

  it("decodes HTTP 429 as rate-limit error even when body contains non-zero JSON code", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse(JSON.stringify({ code: -1, message: "too many requests" }), 429, "AQID"),
      (err: unknown) =>
        err instanceof MiCloudError && err.kind === "http" && err.code === 429 && isXiaomiRateLimitError(err),
    );
    assert.throws(
      () => MiCloudClient.decodeResponse("", 429, "AQID"),
      (err: unknown) =>
        err instanceof MiCloudError && err.kind === "http" && err.code === 429 && isXiaomiRateLimitError(err),
    );
  });

  it("throttles silent Xiaomi polls to getProps-only for 19 rounds and refreshes full topology on round 20, manual refresh, or home switch", async () => {
    let deviceListCalls = 0;
    let homeRoomCalls = 0;
    let lightGroupCalls = 0;
    let propGetCalls = 0;
    let currentBrightness = 35;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd !== "native_http") return null;
          const url = String(args["url"] ?? "");
          if (url.includes("miot-spec.org/miot-spec-v2/instance")) {
            return okResponse(LIGHT_SPEC_RAW);
          }
          const body = String(args["body"] ?? "");
          if (url.includes("device_list")) {
            deviceListCalls += 1;
            return okResponse({
              list: [
                { did: "lamp-a", name: "客厅吸顶灯", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type },
                { did: "group.living", name: "客厅灯组", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type },
                { did: "lamp-b", name: "次卧台灯", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type },
              ],
            });
          }
          if (url.includes("homeroom/gethome")) {
            homeRoomCalls += 1;
            return okResponse({
              homelist: [
                { id: "home-1", name: "主家", roomlist: [{ id: "r-1", name: "客厅", dids: ["lamp-a", "group.living"] }] },
                { id: "home-2", name: "分家", roomlist: [{ id: "r-2", name: "次卧", dids: ["lamp-b"] }] },
              ],
            });
          }
          if (url.includes("groupv2/query_status")) {
            lightGroupCalls += 1;
            return okResponse([{ group_did: "group.living", status: "1", member_ship: { "lamp-a": "1" } }]);
          }
          if (url.includes("miotspec/prop/get")) {
            propGetCalls += 1;
            const payload = decryptMiPayload(body);
            const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
            return okResponse(
              params.map((p) => ({
                did: p.did,
                siid: p.siid,
                piid: p.piid,
                code: 0,
                value: p.piid === 1 ? true : currentBrightness,
              })),
            );
          }
          return okResponse({});
        },
      },
    });

    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
        selectedHomeId: "home-1",
        miSession: SESSION_A,
        cachedModelTypes: { [LIGHT_MODEL]: LIGHT_SPEC_RAW.type },
      }),
    );

    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    while (app.isSyncingCloud || app.devices.length === 0) {
      await setImmediate();
    }

    assert.equal(deviceListCalls, 1, "initial load fetches deviceList once");
    assert.equal(homeRoomCalls, 1, "initial load fetches homeRooms once");
    assert.equal(lightGroupCalls, 1, "initial load fetches lightGroupMembers once");
    assert.equal(propGetCalls, 1, "initial load fetches getProps once");

    currentBrightness = 82;
    for (let round = 1; round <= 19; round += 1) {
      await app.refreshDevices(true);
      assert.equal(deviceListCalls, 1, `round ${round} skips deviceList`);
      assert.equal(homeRoomCalls, 1, `round ${round} skips homeRooms`);
      assert.equal(lightGroupCalls, 1, `round ${round} skips lightGroupMembers`);
      assert.equal(propGetCalls, 1 + round, `round ${round} calls getProps`);
    }
    const lamp = app.devices.find((d) => d.id === "lamp-a")!;
    assert.equal(lamp.kind.kind === "light" ? lamp.kind.brightnessPercent : null, 82);

    await app.refreshDevices(true);
    assert.equal(deviceListCalls, 2, "20th silent poll refreshes deviceList");
    assert.equal(homeRoomCalls, 2, "20th silent poll refreshes homeRooms");
    assert.equal(lightGroupCalls, 2, "20th silent poll refreshes lightGroupMembers");
    assert.equal(propGetCalls, 21);

    await app.refreshDevices(true);
    assert.equal(deviceListCalls, 2, "21st silent poll reuses refreshed topology");
    assert.equal(propGetCalls, 22);

    await app.refreshDevices(false);
    assert.equal(deviceListCalls, 3, "manual refresh forces full topology fetch");

    app.settings.selectedHomeId = "home-2";
    await app.refreshDevices(true);
    assert.equal(deviceListCalls, 4, "home switch forces full topology fetch");
    assert.deepEqual(app.devices.map((d) => d.id), ["lamp-b"]);
  });

  it("skips silent polls during 429 backoff or workstation lock, allows manual refresh to clear backoff, and resumes on unlock", async () => {
    let return429 = false;
    let workstationLocked = false;
    let httpCalls = 0;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return workstationLocked;
          if (cmd !== "native_http") return null;
          const url = String(args["url"] ?? "");
          if (url.includes("miot-spec.org")) return okResponse(LIGHT_SPEC_RAW);
          httpCalls += 1;
          if (return429) {
            return { status: 429, headers: {}, body: JSON.stringify({ code: -1, message: "too many requests" }) };
          }
          if (url.includes("device_list")) {
            return okResponse({
              list: [{ did: "lamp-1", name: "书房灯", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type }],
            });
          }
          if (url.includes("homeroom/gethome")) {
            return okResponse({
              homelist: [{ id: "1", name: "家", roomlist: [{ id: "10", name: "书房", dids: ["lamp-1"] }] }],
            });
          }
          if (url.includes("miotspec/prop/get")) {
            return okResponse([{ did: "lamp-1", siid: 2, piid: 1, code: 0, value: true }]);
          }
          return okResponse({});
        },
      },
    });

    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
        miSession: SESSION_A,
        cachedModelTypes: { [LIGHT_MODEL]: LIGHT_SPEC_RAW.type },
      }),
    );

    const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    while (app.isSyncingCloud || app.devices.length === 0) {
      await setImmediate();
    }

    return429 = true;
    const before429 = httpCalls;
    await app.refreshDevices(true);
    assert.equal(httpCalls, before429 + 1);
    const backoffUntil = getXiaomiBackoffUntilMs(app, SESSION_A);
    assert.ok(backoffUntil !== null && backoffUntil > Date.now() + 50_000, "60s backoff armed");

    await app.refreshDevices(true);
    assert.equal(httpCalls, before429 + 1, "silent poll skipped during active 429 backoff");

    return429 = false;
    await app.refreshDevices(false);
    assert.equal(getXiaomiBackoffUntilMs(app, SESSION_A), null, "successful refresh clears 429 backoff");

    const beforeLockCalls = httpCalls;
    workstationLocked = true;
    await app.refreshDevices(true);
    assert.equal(httpCalls, beforeLockCalls, "locked workstation skips silent cloud poll");
    assert.equal(app.lastCloudRefreshAt, null);
    assert.equal(cloudRefreshDue(Date.now(), app.lastCloudRefreshAt, false), true, "due immediately upon unlock/open");

    workstationLocked = false;
    await app.refreshDevices(true);
    assert.equal(httpCalls, beforeLockCalls + 1, "unlocked workstation resumes polling immediately");
    assert.ok(app.lastCloudRefreshAt !== null);
  });

  it("parses and validates localIp & mac in parseDeviceRecord and attaches gatewayLocalIp without extra list fetch", () => {
    const parsed = MiCloudClient.parseDeviceList({
      list: [
        {
          did: "hub-1",
          name: "室内网关",
          model: "mxiang.camera.mwc10",
          isOnline: true,
          localip: "192.0.2.88",
          mac: "aa-bb-cc-11-22-33",
        },
        {
          did: "cam-1",
          name: "室外电池机",
          model: "mxiang.camera.mwc11",
          isOnline: true,
          localip: "0.0.0.0",
          mac: "00:00:00:00:00:00",
        },
        {
          did: "bad-meta",
          name: "异常元数据设备",
          model: LIGHT_MODEL,
          isOnline: true,
          localip: "999.168.01.5",
          mac: "not-a-mac",
        },
      ],
    });

    assert.equal(parsed[0]?.localIp, "192.0.2.88");
    assert.equal(parsed[0]?.mac, "AA:BB:CC:11:22:33");
    assert.equal(parsed[1]?.localIp, undefined, "rejects 0.0.0.0");
    assert.equal(parsed[1]?.mac, undefined, "rejects all-zero MAC");
    assert.equal(parsed[2]?.localIp, undefined, "rejects malformed IPv4");
    assert.equal(parsed[2]?.mac, undefined, "rejects malformed MAC");

    const cameraSpec = parseMiotDeviceSpec({
      type: "urn:miot-spec-v2:device:camera:0000A01C:mxiang-mwc11:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:mxiang-mwc11:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:mxiang-mwc11:1", format: "bool", access: ["read", "write"] },
          ],
        },
      ],
    });
    assert.ok(cameraSpec);
    const home = MiotSynthesizer.synthesize(
      parsed,
      [{ id: "r1", name: "玄关", dids: ["hub-1", "cam-1"], homeId: "h1" }],
      { "mxiang.camera.mwc11": cameraSpec },
      new Map([["cam-1.2.1", true]]),
    );
    const cam = home.devices.find((d) => d.id === "cam-1");
    assert.ok(cam && cam.kind.kind === "camera");
    assert.equal(cam.kind.gatewayDid, "hub-1");
    assert.equal(cam.kind.gatewayLocalIp, "192.0.2.88");
  });

  it("persists 401 / code 3 miSessionExpired in localStorage without leaking secrets, skips dead session on restart, and clears on recovery or sign-out", async () => {
    let authRejected = true;
    let cloudHttpCalls = 0;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd !== "native_http") return null;
          const url = String(args["url"] ?? "");
          if (url.includes("miot-spec.org")) return okResponse(LIGHT_SPEC_RAW);
          cloudHttpCalls += 1;
          if (authRejected) {
            return { status: 200, headers: {}, body: JSON.stringify({ code: 3, message: "auth err" }) };
          }
          if (url.includes("device_list")) {
            return okResponse({
              list: [{ did: "lamp-1", name: "台灯", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type }],
            });
          }
          if (url.includes("homeroom/gethome")) {
            return okResponse({
              homelist: [{ id: "1", name: "家", roomlist: [{ id: "10", name: "客厅", dids: ["lamp-1"] }] }],
            });
          }
          return okResponse([{ did: "lamp-1", siid: 2, piid: 1, code: 0, value: true }]);
        },
      },
    });

    const seedSessionSettings = (session: MiSession) => {
      localStorage.setItem(
        SETTINGS_KEY,
        JSON.stringify({
          connectionMode: "xiaomiCloud",
          hasCompletedOnboarding: true,
          enableGrokBall: false,
          autoCheckUpdates: false,
          miSession: session,
          cachedModelTypes: { [LIGHT_MODEL]: LIGHT_SPEC_RAW.type },
        }),
      );
    };

    seedSessionSettings(SESSION_A);
    const firstApp = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    while (firstApp.isSyncingCloud || !firstApp.miSessionExpired) {
      await setImmediate();
    }

    assert.equal(firstApp.miSessionExpired, true);
    assert.equal(isPersistedMiSessionExpired(SESSION_A), true);
    const rawPersisted = localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY) ?? "";
    assert.ok(rawPersisted.length > 0);
    assert.equal(rawPersisted.includes(SESSION_A.serviceToken), false, "never persists plaintext serviceToken");
    assert.equal(rawPersisted.includes(SESSION_A.ssecurity), false, "never persists plaintext ssecurity");

    firstApp.dispose();
    await closeTestWindow(dom!);
    dom = mountTestWindow({ stubInterval: true });
    localStorage.setItem(MI_SESSION_EXPIRED_STORAGE_KEY, rawPersisted);
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd !== "native_http") return null;
          const url = String(args["url"] ?? "");
          if (url.includes("miot-spec.org")) return okResponse(LIGHT_SPEC_RAW);
          cloudHttpCalls += 1;
          if (authRejected) {
            return { status: 401, headers: {}, body: "" };
          }
          if (url.includes("device_list")) {
            return okResponse({
              list: [{ did: "lamp-1", name: "台灯", model: LIGHT_MODEL, isOnline: true, spec_type: LIGHT_SPEC_RAW.type }],
            });
          }
          if (url.includes("homeroom/gethome")) {
            return okResponse({
              homelist: [{ id: "1", name: "家", roomlist: [{ id: "10", name: "客厅", dids: ["lamp-1"] }] }],
            });
          }
          return okResponse([{ did: "lamp-1", siid: 2, piid: 1, code: 0, value: true }]);
        },
      },
    });
    seedSessionSettings(SESSION_A);
    cloudHttpCalls = 0;

    const restartedApp = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    await setImmediate();
    await restartedApp.refreshDevices(true);
    assert.equal(restartedApp.miSessionExpired, true, "restores expired flag across restart");
    assert.equal(cloudHttpCalls, 0, "does not hammer dead Xiaomi endpoints on startup or silent poll");
    assert.match(document.querySelector("#btn-footer-health")?.textContent ?? "", /登录已过期/);

    assert.equal(isPersistedMiSessionExpired(SESSION_B), false);

    authRejected = false;
    await restartedApp.refreshDevices(false);
    assert.equal(restartedApp.miSessionExpired, false);
    assert.equal(isPersistedMiSessionExpired(SESSION_A), false);

    restartedApp.miSessionExpired = true;
    assert.equal(isPersistedMiSessionExpired(SESSION_A), true);
    signOutXiaomiAccount(restartedApp);
    assert.equal(isPersistedMiSessionExpired(SESSION_A), false);
    assert.equal(localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY), null);
  });
});

describe("A3: Home Assistant speaker black-hole fix & camera motion fallbacks (haDomains.ts)", () => {
  it("exposes play_music, stop_alarm, and turn_on speaker buttons in 更多设置 while keeping notify excluded and mute/sleep claimed", () => {
    const home = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [{ id: "speaker_dev", area_id: "living", name: "小爱音箱 Pro", model: "xiaomi.wifispeaker.lx06" }],
      entities: [
        { entity_id: "media_player.xiaoai_pro", device_id: "speaker_dev" },
        { entity_id: "switch.xiaoai_pro_mute", device_id: "speaker_dev" },
        { entity_id: "switch.xiaoai_pro_sleep_mode", device_id: "speaker_dev" },
        { entity_id: "notify.xiaoai_pro_play_text", device_id: "speaker_dev" },
        { entity_id: "notify.xiaoai_pro_execute_text_directive", device_id: "speaker_dev" },
        { entity_id: "button.xiaoai_pro_play_music", device_id: "speaker_dev" },
        { entity_id: "button.xiaoai_pro_stop_alarm", device_id: "speaker_dev" },
        { entity_id: "button.xiaoai_pro_turn_on", device_id: "speaker_dev" },
      ],
      states: [
        {
          entity_id: "media_player.xiaoai_pro",
          state: "playing",
          attributes: { volume_level: 0.45, supported_features: 4 | 8 },
        },
        { entity_id: "switch.xiaoai_pro_mute", state: "off", attributes: { friendly_name: "静音" } },
        { entity_id: "switch.xiaoai_pro_sleep_mode", state: "on", attributes: { friendly_name: "睡眠模式" } },
        { entity_id: "notify.xiaoai_pro_play_text", state: "unknown", attributes: {} },
        { entity_id: "notify.xiaoai_pro_execute_text_directive", state: "unknown", attributes: {} },
        { entity_id: "button.xiaoai_pro_play_music", state: "unknown", attributes: { friendly_name: "播放音乐" } },
        { entity_id: "button.xiaoai_pro_stop_alarm", state: "unknown", attributes: { friendly_name: "关闭闹钟" } },
        { entity_id: "button.xiaoai_pro_turn_on", state: "unknown", attributes: { friendly_name: "唤醒音箱" } },
      ],
    });

    const speaker = home.devices.find((d) => d.id === "speaker_dev");
    assert.ok(speaker && speaker.kind.kind === "speaker");
    assert.equal(speaker.kind.muteSwitchEntityId, "switch.xiaoai_pro_mute");
    assert.equal(speaker.kind.sleepModeEntityId, "switch.xiaoai_pro_sleep_mode");

    const facets = home.deviceFacets?.["speaker_dev"] ?? [];
    const facetIds = facets.map((f) => f.id);
    assert.ok(facetIds.includes("button.xiaoai_pro_play_music"));
    assert.ok(facetIds.includes("button.xiaoai_pro_stop_alarm"));
    assert.ok(facetIds.includes("button.xiaoai_pro_turn_on"));
    assert.equal(facetIds.includes("switch.xiaoai_pro_mute"), false, "mute switch remains claimed on SpeakerSpec");
    assert.equal(facetIds.includes("switch.xiaoai_pro_sleep_mode"), false, "sleep switch remains claimed on SpeakerSpec");
    assert.equal(facetIds.some((id) => id.startsWith("notify.")), false, "notify.* entities stay out of Facets");

    for (const btnId of [
      "button.xiaoai_pro_play_music",
      "button.xiaoai_pro_stop_alarm",
      "button.xiaoai_pro_turn_on",
    ]) {
      const btnFacet = facets.find((f) => f.id === btnId);
      assert.ok(btnFacet);
      assert.equal(btnFacet.kind, "button");
      assert.equal(btnFacet.isWritable, true);
      assert.deepEqual(btnFacet.target, { kind: "action", entityId: btnId });
      assert.deepEqual(haServiceCall({ kind: "pressButton", entityId: btnId }), {
        domain: "button",
        service: "press",
        entity_id: btnId,
        data: {},
      });
    }
  });

  it("falls back to camera.attributes.motion_detection, associated motion binary_sensor, and writable input_boolean", () => {
    const home = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "entry", name: "玄关" }],
      devices: [
        { id: "cam_attr", area_id: "entry", name: "门厅摄像机", model: "chuangmi.camera.v1" },
        { id: "cam_bin", area_id: "entry", name: "走廊摄像机", model: "chuangmi.camera.v2" },
        { id: "cam_input", area_id: "entry", name: "阳台摄像机", model: "chuangmi.camera.v3" },
      ],
      entities: [
        { entity_id: "camera.entry_cam", device_id: "cam_attr" },
        { entity_id: "camera.hall_cam", device_id: "cam_bin" },
        { entity_id: "binary_sensor.hall_cam_motion", device_id: "cam_bin" },
        { entity_id: "camera.balcony_cam", device_id: "cam_input" },
        { entity_id: "input_boolean.balcony_cam_motion_detection", device_id: "cam_input" },
      ],
      states: [
        {
          entity_id: "camera.entry_cam",
          state: "streaming",
          attributes: { motion_detection: true },
        },
        {
          entity_id: "camera.hall_cam",
          state: "idle",
          attributes: {},
        },
        {
          entity_id: "binary_sensor.hall_cam_motion",
          state: "on",
          attributes: { device_class: "motion", friendly_name: "移动侦测状态" },
        },
        {
          entity_id: "camera.balcony_cam",
          state: "idle",
          attributes: { motion_detection: false },
        },
        {
          entity_id: "input_boolean.balcony_cam_motion_detection",
          state: "on",
          attributes: { friendly_name: "移动侦测开关" },
        },
      ],
    });

    const camAttr = home.devices.find((d) => d.id === "cam_attr");
    assert.ok(camAttr && camAttr.kind.kind === "camera");
    assert.equal(camAttr.kind.isMotionDetectionOn, true);
    assert.equal(camAttr.kind.motionDetectionEntityId, null);
    assert.match(deviceStatusSummary(camAttr), /侦测开/);
    const attrFacets = home.deviceFacets?.["cam_attr"] ?? [];
    const motionReading = attrFacets.find((f) => f.id === "camera.entry_cam#motion");
    assert.ok(motionReading);
    assert.equal(motionReading.kind, "reading");
    assert.equal(motionReading.value, true);

    const camBin = home.devices.find((d) => d.id === "cam_bin");
    assert.ok(camBin && camBin.kind.kind === "camera");
    assert.equal(camBin.kind.isMotionDetectionOn, true);
    assert.equal(camBin.kind.motionDetectionEntityId, null);
    assert.match(deviceStatusSummary(camBin), /侦测开/);
    assert.ok((home.deviceFacets?.["cam_bin"] ?? []).some((f) => f.id === "binary_sensor.hall_cam_motion"));

    const camInput = home.devices.find((d) => d.id === "cam_input");
    assert.ok(camInput && camInput.kind.kind === "camera");
    assert.equal(camInput.kind.motionDetectionEntityId, "input_boolean.balcony_cam_motion_detection");
    assert.equal(camInput.kind.isMotionDetectionOn, true);
    assert.equal(
      (home.deviceFacets?.["cam_input"] ?? []).some((f) => f.id === "input_boolean.balcony_cam_motion_detection"),
      false,
      "claimed input_boolean is not duplicated in 更多设置",
    );
    assert.deepEqual(
      haServiceCall({ kind: "setSwitch", entityId: camInput.kind.motionDetectionEntityId!, isOn: false }),
      {
        domain: "input_boolean",
        service: "turn_off",
        entity_id: "input_boolean.balcony_cam_motion_detection",
        data: {},
      },
    );

    assert.ok(parseCachedHAHome({ identity: "http://localhost:8123|abc", home }) !== null);
  });
});
