import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount, miAccountId } from "../src/core/miAccountsStore.js";
import { decodeMiScenes } from "../src/core/miCloud/scenes.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { finishMiSceneConfirmation } from "../src/ui/sceneConfirmation.js";
import type { HttpResponse, MiSession, MiotDeviceSpec } from "../src/core/miCloudClient.js";

const TEST_SSECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SESSION: MiSession = {
  userId: "20001",
  cUserId: "c20001",
  ssecurity: TEST_SSECURITY,
  serviceToken: "tok",
  passToken: "",
  region: "cn",
};
const ACCOUNT_ID = miAccountId(SESSION);

const SPEC_TYPE = "urn:miot-spec-v2:device:light:0000A001:scene-test:1";
const MODEL = "yeelink.light.scene-test";
const SPEC: MiotDeviceSpec = {
  type: SPEC_TYPE,
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:light:00007802:scene-test:1",
      properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:scene-test:1", format: "bool", access: ["read", "write"] },
      ],
      actions: [],
    },
  ],
};

const HOMES = [
  { id: "home-a", name: "A 家", uid: SESSION.userId, roomlist: [{ id: "room-a", name: "客厅", dids: ["dev-a"] }] },
  { id: "home-b", name: "B 家", uid: SESSION.userId, roomlist: [{ id: "room-b", name: "卧室", dids: ["dev-b"] }] },
];
const DEVICES = [
  { did: "dev-a", name: "A 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
  { did: "dev-b", name: "B 灯", model: MODEL, isOnline: true, spec_type: SPEC_TYPE },
];

/** Mutated by a test to model a scene list that changed in the cloud. */
let sceneCatalog: Record<string, Array<{ scene_id: string; scene_name?: string; name?: string }>>;
let runSceneCalls = 0;

let dom: Window;

async function flushAsync(rounds = 6): Promise<void> {
  for (let i = 0; i < rounds; i += 1) await setImmediate();
}

async function waitFor(predicate: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(`timed out waiting for ${label}`);
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

function installCloudBackend(): void {
  Object.defineProperty(window, "__TAURI_INTERNALS__", {
    configurable: true,
    value: {
      invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
        if (cmd === "is_workstation_locked") return false;
        if (cmd === "secure_store_get") return null;
        if (cmd !== "native_http") return null;
        const url = String(args.url ?? "");
        if (url.includes("homeroom/gethome_merged")) {
          return jsonResponse({ code: 0, result: { homelist: HOMES } });
        }
        if (url.includes("home/device_list_page")) {
          return jsonResponse({ code: 0, result: { list: DEVICES } });
        }
        if (url.includes("/instance?")) {
          return jsonResponse(SPEC);
        }
        if (url.includes("miotspec/prop/get")) {
          const request = decryptMiRequestData(String(args.body ?? ""));
          const params = (request.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
          return jsonResponse({
            code: 0,
            result: params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: true })),
          });
        }
        if (url.includes("AppSceneService/GetSimpleSceneList")) {
          const request = decryptMiRequestData(String(args.body ?? ""));
          const homeId = String(request.home_id ?? "");
          return jsonResponse({ code: 0, result: { manual_scene_info_list: sceneCatalog[homeId] ?? [] } });
        }
        if (url.includes("AppSceneService/NewRunScene")) {
          runSceneCalls += 1;
          return jsonResponse({ code: 0, result: {} });
        }
        return jsonResponse({ code: 0, result: {} });
      },
    },
  });
}

function sceneEntityId(homeId: string, sceneId: string): string {
  return `${ACCOUNT_ID}/mi-scene:${homeId}:${sceneId}`;
}

async function mountApp(): Promise<MenuMijiaWindowsApp> {
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
  app.miAccountsOverride = [makeMiAccount(SESSION)];
  app.settings.miSession = SESSION;
  app.settings.connectionMode = "xiaomiCloud";
  app.settings.selectedHomeId = "home-a";
  await app.refreshDevices(false);
  await flushAsync();
  return app;
}

function sceneNames(app: MenuMijiaWindowsApp): string[] {
  return app.scenes.map((scene) => scene.name).sort();
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
  sceneCatalog = {
    "home-a": [{ scene_id: "11", scene_name: "回家" }],
    "home-b": [{ scene_id: "21", scene_name: "晚安" }],
  };
  runSceneCalls = 0;
  installCloudBackend();
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Mi cloud scene golden corpus", () => {
  it("decodes Tests/Fixtures/mi_cloud_scenes_golden.json exactly like the Swift decoder", () => {
    const corpus: unknown = JSON.parse(
      readFileSync(new URL("../../Tests/Fixtures/mi_cloud_scenes_golden.json", import.meta.url), "utf8"),
    );
    const scenes = decodeMiScenes(corpus, "home-1", "42");
    assert.deepEqual(scenes.map((scene) => scene.id), ["11", "12", "13", "14", "15"]);
    // `scene_name` wins over `name`; an empty/blank field falls back to the other one.
    assert.deepEqual(scenes.map((scene) => scene.name), ["回家", "晚安", "晨起", "夜读", "新名"]);
  });
});

describe("Mi cloud scenes stay scoped to the selected home", () => {
  it("drops the previous home's scene (and a cloud-deleted scene) after a home switch", async () => {
    const app = await mountApp();
    assert.deepEqual(sceneNames(app), ["回家"]);

    app.selectHome("home-b");
    // The refresh has not landed yet, so the old scene row is still in `host.scenes`; the home
    // gate must refuse it anyway.
    assert.ok(
      app.scenes.some((scene) => scene.entityId === sceneEntityId("home-a", "11")),
      "the stale row is still present at this point, making the gate assertion meaningful",
    );
    const staleRun = app.applyCommand({ kind: "activateScene", entityId: sceneEntityId("home-a", "11") });
    await flushAsync(2);
    assert.equal(app.pendingHighRisk, null, "a scene of the home the user left must not even arm a confirmation");
    assert.equal(await staleRun, false);
    assert.equal(runSceneCalls, 0, "a scene of the home the user left must never reach the cloud");

    await waitFor(() => sceneNames(app).join() === "晚安", "home B's scene list");
    assert.equal(
      app.scenes.some((scene) => scene.entityId === sceneEntityId("home-a", "11")),
      false,
      "the previous home's scene must be replaced, not retained",
    );

    // Same home, but the scene was deleted in the cloud: the next round must not resurrect it.
    sceneCatalog["home-b"] = [];
    app.selectHome("home-a");
    await waitFor(() => sceneNames(app).join() === "回家", "home A's scene list again");
    app.selectHome("home-b");
    await waitFor(() => app.scenes.length === 0, "the deleted scene to disappear");

    const deletedRun = app.applyCommand({ kind: "activateScene", entityId: sceneEntityId("home-b", "21") });
    await flushAsync(2);
    assert.equal(app.pendingHighRisk, null, "a scene deleted in the cloud must not arm a confirmation");
    assert.equal(await deletedRun, false);
    assert.equal(runSceneCalls, 0);
  });

  it("cancels a pending scene confirmation on a home switch, so confirming runs nothing", async () => {
    const app = await mountApp();
    const entityId = sceneEntityId("home-a", "11");

    const running = app.applyCommand({ kind: "activateScene", entityId });
    await waitFor(() => app.pendingHighRisk !== null, "the scene confirmation to arm");

    app.selectHome("home-b");
    assert.equal(app.pendingHighRisk, null, "a home switch disarms the previous home's confirmation");

    // A click that arrives after the switch must resolve false instead of running the old scene.
    finishMiSceneConfirmation(app, true);
    assert.equal(await running, false);
    assert.equal(runSceneCalls, 0);

    await waitFor(() => sceneNames(app).join() === "晚安", "home B's scene list");
  });

  it("clears an armed Mi scene confirmation when a single command is dispatched", async () => {
    const app = await mountApp();
    const running = app.applyCommand({ kind: "activateScene", entityId: sceneEntityId("home-a", "11") });
    await waitFor(() => app.pendingHighRisk !== null, "the scene confirmation to arm");

    const light = app.devices.find((device) => device.id === "dev-a");
    assert.ok(light && light.kind.kind === "light");
    app.applyCommand = async () => true;
    await app.executeSingleCommand(light, { kind: "setLightPower", entityId: light.kind.entityId, isOn: false }, "关闭");

    assert.equal(app.pendingHighRisk, null, "the control tap owns the next command");
    finishMiSceneConfirmation(app, true);
    assert.equal(await running, false);
    assert.equal(runSceneCalls, 0);
  });

  it("clears an armed Mi scene confirmation when another intent batch starts", async () => {
    const app = await mountApp();
    const running = app.applyCommand({ kind: "activateScene", entityId: sceneEntityId("home-a", "11") });
    await waitFor(() => app.pendingHighRisk !== null, "the scene confirmation to arm");

    const light = app.devices.find((device) => device.id === "dev-a");
    assert.ok(light);
    app.applyCommand = async () => true;
    await app.executeIntents([{ targetId: light.id, operation: { kind: "power", isOn: false } }], "关闭", "测试");

    assert.equal(app.pendingHighRisk, null, "a newer batch preempts the pending scene approval");
    finishMiSceneConfirmation(app, true);
    assert.equal(await running, false);
    assert.equal(runSceneCalls, 0);
  });
});
