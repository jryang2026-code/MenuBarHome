import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount, MiAccountScope, miAccountId } from "../src/core/miAccountsStore.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import type { HttpResponse, MiSession, MiotDeviceSpec } from "../src/core/miCloudClient.js";

const TEST_SSECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SESSION_A: MiSession = {
  userId: "30001",
  cUserId: "c30001",
  ssecurity: TEST_SSECURITY,
  serviceToken: "tokA",
  passToken: "",
  region: "cn",
};
const SESSION_B: MiSession = {
  userId: "30002",
  cUserId: "c30002",
  ssecurity: TEST_SSECURITY,
  serviceToken: "tokB",
  passToken: "",
  region: "de",
};

const SPEC_TYPE = "urn:miot-spec-v2:device:light:0000A001:switch-test:1";
const MODEL = "yeelink.light.switch-test";
const SPEC: MiotDeviceSpec = {
  type: SPEC_TYPE,
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:light:00007802:switch-test:1",
      properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:switch-test:1", format: "bool", access: ["read", "write"] },
      ],
      actions: [],
    },
  ],
};

interface Deferred {
  readonly promise: Promise<void>;
  readonly entered: Promise<void>;
  markEntered(): void;
  release(): void;
}

function makeDeferred(): Deferred {
  let resolvePromise!: () => void;
  let resolveEntered!: () => void;
  const promise = new Promise<void>((resolve) => { resolvePromise = resolve; });
  const entered = new Promise<void>((resolve) => { resolveEntered = resolve; });
  return {
    promise,
    entered,
    markEntered: () => resolveEntered(),
    release: () => resolvePromise(),
  };
}

function jsonResponse(payload: unknown, status = 200): HttpResponse {
  return { status, headers: {}, body: JSON.stringify(payload) };
}

function decryptMiRequestData(body: string): Record<string, unknown> {
  const params = new URLSearchParams(body);
  const nonce = params.get("_nonce") ?? "";
  const encrypted = params.get("data") ?? "";
  const signed = MiCloudCrypto.signedNonce(TEST_SSECURITY, nonce);
  return JSON.parse(MiCloudCrypto.decryptResponse(encrypted, signed)) as Record<string, unknown>;
}

async function flushAsync(rounds = 8): Promise<void> {
  for (let i = 0; i < rounds; i += 1) await setImmediate();
}

async function waitFor(predicate: () => boolean, label: string): Promise<void> {
  const deadline = performance.now() + 5_000;
  while (performance.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for ${label}`);
}

let dom: Window;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Windows Mi home switch fast path", () => {
  it("clears old devices immediately, fetches new home at once, publishes device list before getProps finishes, and drops stale old-home responses", async () => {
    const homes = [
      { id: "home-a", name: "A 家", uid: SESSION_A.userId, roomlist: [{ id: "room-a", name: "客厅", dids: ["dev-a"] }] },
      { id: "home-b", name: "B 家", uid: SESSION_A.userId, roomlist: [{ id: "room-b", name: "卧室", dids: ["dev-b"] }] },
    ];
    const devices = [
      { did: "dev-a", name: "A 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
      { did: "dev-b", name: "B 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
    ];
    const propGates = new Map<string, Deferred>();
    let homeRoomsCalls = 0;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd === "secure_store_get") return null;
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("homeroom/gethome_merged")) {
            homeRoomsCalls += 1;
            return jsonResponse({ code: 0, result: { homelist: homes } });
          }
          if (url.includes("home/device_list_page")) {
            return jsonResponse({ code: 0, result: { list: devices } });
          }
          if (url.includes("/instance?")) {
            return jsonResponse(SPEC);
          }
          if (url.includes("miotspec/prop/get")) {
            const request = decryptMiRequestData(String(args.body ?? ""));
            const params = (request.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
            for (const p of params) {
              const gate = propGates.get(p.did);
              if (gate) {
                gate.markEntered();
                await gate.promise;
              }
            }
            return jsonResponse({
              code: 0,
              result: params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: true })),
            });
          }
          if (url.includes("AppSceneService/GetSimpleSceneList")) {
            return jsonResponse({ code: 0, result: { manual_scene_info_list: [] } });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miCloudRegion: "cn",
        selectedHomeId: "home-a",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.settings.miSession = SESSION_A;
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.selectedHomeId = "home-a";
    await app.refreshDevices(false);
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);

    // Park an in-flight home-a refresh inside getProps, and park home-b's getProps as well.
    const homeAGate = makeDeferred();
    const homeBGate = makeDeferred();
    propGates.set("dev-a", homeAGate);
    propGates.set("dev-b", homeBGate);

    const staleRefresh = app.refreshDevices(false);
    await homeAGate.entered;
    const callsBeforeSwitch = homeRoomsCalls;

    // Switch to home-b while home-a's getProps is parked.
    app.selectHome("home-b");

    // Synchronously: old devices cleared, switching loading shown (not empty-home warning).
    assert.equal(app.devices.length, 0);
    assert.equal(app.isSwitchingHome, true);
    assert.ok(document.querySelector("#switching-home-loading"), "shows switching-home loading state");
    assert.equal(document.querySelector("#empty-selected-home"), null, "must not flash empty-home warning while switching");

    // Home B fetches immediately without waiting for homeAGate, and publishes its device list before homeBGate resolves.
    await homeBGate.entered;
    await waitFor(() => app.devices.map((d) => d.id).join() === "dev-b", "stage-1 home-b device list");
    assert.ok(homeRoomsCalls > callsBeforeSwitch, "switching triggers immediate fetch");
    assert.equal(app.isSwitchingHome, false);
    const stage1Light = app.devices[0]!;
    assert.equal(stage1Light.kind.kind === "light" && stage1Light.kind.isOn, false, "stage-1 list arrives before getProps");

    // Release stale home-a response while home-b is still loading props — must be discarded.
    propGates.delete("dev-a");
    homeAGate.release();
    await staleRefresh;
    await flushAsync();
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-b"], "stale old-home response must not overwrite new home");

    // Release home-b getProps and verify live property value updates.
    propGates.delete("dev-b");
    homeBGate.release();
    await waitFor(
      () => app.devices[0]?.kind.kind === "light" && app.devices[0].kind.isOn === true,
      "stage-2 home-b live power state",
    );
    app.dispose();
  });

  it("restores cached home snapshot synchronously when switching back while still refreshing in background", async () => {
    const homes = [
      { id: "home-a", name: "A 家", uid: SESSION_A.userId, roomlist: [{ id: "room-a", name: "客厅", dids: ["dev-a"] }] },
      { id: "home-b", name: "B 家", uid: SESSION_A.userId, roomlist: [{ id: "room-b", name: "卧室", dids: ["dev-b"] }] },
    ];
    const devices = [
      { did: "dev-a", name: "A 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
      { did: "dev-b", name: "B 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
    ];
    let homeRoomsGate: Deferred | null = null;
    let powerA = true;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd === "secure_store_get") return null;
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("homeroom/gethome_merged")) {
            if (homeRoomsGate) {
              homeRoomsGate.markEntered();
              await homeRoomsGate.promise;
            }
            return jsonResponse({ code: 0, result: { homelist: homes } });
          }
          if (url.includes("home/device_list_page")) {
            return jsonResponse({ code: 0, result: { list: devices } });
          }
          if (url.includes("/instance?")) {
            return jsonResponse(SPEC);
          }
          if (url.includes("miotspec/prop/get")) {
            const request = decryptMiRequestData(String(args.body ?? ""));
            const params = (request.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
            return jsonResponse({
              code: 0,
              result: params.map((p) => ({
                did: p.did,
                siid: p.siid,
                piid: p.piid,
                code: 0,
                value: p.did === "dev-a" ? powerA : true,
              })),
            });
          }
          if (url.includes("AppSceneService/GetSimpleSceneList")) {
            return jsonResponse({ code: 0, result: { manual_scene_info_list: [] } });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miCloudRegion: "cn",
        selectedHomeId: "home-a",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.settings.miSession = SESSION_A;
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.selectedHomeId = "home-a";
    await app.refreshDevices(false);
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);

    app.selectHome("home-b");
    await waitFor(
      () => app.devices.map((d) => d.id).join() === "dev-b" && !app.isSyncingCloud,
      "home-b full sync",
    );

    // Park the next refresh for home-a and toggle dev-a off in the cloud.
    powerA = false;
    homeRoomsGate = makeDeferred();
    app.selectHome("home-a");

    // Cached snapshot appears synchronously without flashing empty/loading.
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);
    assert.equal(app.isSwitchingHome, false);
    assert.equal(app.devices[0]!.kind.kind === "light" && app.devices[0]!.kind.isOn, true);

    // Background refresh still runs immediately and updates live state to false.
    await homeRoomsGate.entered;
    const gate = homeRoomsGate;
    homeRoomsGate = null;
    gate.release();
    await waitFor(
      () => app.devices[0]?.kind.kind === "light" && app.devices[0].kind.isOn === false,
      "refreshed home-a power state",
    );
    app.dispose();
  });

  it("multi-account cross-account home switch clears old devices and publishes new account device list before getProps finishes", async () => {
    const accA = makeMiAccount(SESSION_A);
    const accB = makeMiAccount(SESSION_B);
    const propGates = new Map<string, Deferred>();

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd === "secure_store_get") return null;
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          const isDe = url.includes("de.api.io.mi.com");
          if (url.includes("homeroom/gethome_merged")) {
            return jsonResponse({
              code: 0,
              result: {
                homelist: isDe
                  ? [{ id: "home-b", name: "B 家", uid: SESSION_B.userId, roomlist: [{ id: "room-b", name: "卧室", dids: ["dev-b"] }] }]
                  : [{ id: "home-a", name: "A 家", uid: SESSION_A.userId, roomlist: [{ id: "room-a", name: "客厅", dids: ["dev-a"] }] }],
              },
            });
          }
          if (url.includes("home/device_list_page")) {
            return jsonResponse({
              code: 0,
              result: {
                list: isDe
                  ? [{ did: "dev-b", name: "B 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE }]
                  : [{ did: "dev-a", name: "A 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE }],
              },
            });
          }
          if (url.includes("/instance?")) {
            return jsonResponse(SPEC);
          }
          if (url.includes("miotspec/prop/get")) {
            const request = decryptMiRequestData(String(args.body ?? ""));
            const params = (request.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
            for (const p of params) {
              const gate = propGates.get(p.did);
              if (gate) {
                gate.markEntered();
                await gate.promise;
              }
            }
            return jsonResponse({
              code: 0,
              result: params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: true })),
            });
          }
          if (url.includes("AppSceneService/GetSimpleSceneList")) {
            return jsonResponse({ code: 0, result: { manual_scene_info_list: [] } });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    const homeAScoped = MiAccountScope.id("home-a", miAccountId(SESSION_A));
    const homeBScoped = MiAccountScope.id("home-b", miAccountId(SESSION_B));

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miCloudRegion: "cn",
        selectedHomeId: homeAScoped,
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.miAccountsOverride = [accA, accB];
    app.settings.miSession = SESSION_A;
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.selectedHomeId = homeAScoped;
    await app.refreshDevices(false);
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);

    const accBGate = makeDeferred();
    propGates.set("dev-b", accBGate);

    app.selectHome(homeBScoped);
    assert.equal(app.devices.length, 0);
    assert.equal(app.isSwitchingHome, true);

    await accBGate.entered;
    await waitFor(() => app.devices.map((d) => d.id).join() === "dev-b", "multi-account stage-1 dev-b");
    assert.equal(app.isSwitchingHome, false);

    propGates.delete("dev-b");
    accBGate.release();
    await waitFor(
      () => app.devices[0]?.kind.kind === "light" && app.devices[0].kind.isOn === true,
      "multi-account stage-2 live state",
    );
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-b"]);
    app.dispose();
  });
});
