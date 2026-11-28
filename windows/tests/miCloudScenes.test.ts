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
import { decodeMiScenes, refreshMiScenes, sceneOwnerUid } from "../src/core/miCloud/scenes.js";
import { MiCloudClient, type MiRoom } from "../src/core/miCloudClient.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { finishMiSceneConfirmation } from "../src/ui/sceneConfirmation.js";
import { setHostDualSourceEnabled, setHostHAInvokeOverride } from "../src/ui/cloudRefresh.js";
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
  const deadline = performance.now() + 5_000;
  while (performance.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
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

describe("Mi scene owner resolution (#451)", () => {
  interface SceneOwnerCorpus {
    readonly sessionUserId: string;
    readonly result: Record<string, unknown>;
    readonly expectedSceneRequests: readonly { homeId: string; ownerUid: string }[];
  }

  it("runs the shared corpus: owned homes without uid fall back, shared homes without uid stay skipped", async () => {
    const corpus = JSON.parse(
      readFileSync(new URL("../../Tests/Fixtures/mi_cloud_scene_homes_golden.json", import.meta.url), "utf8"),
    ) as SceneOwnerCorpus;
    const rooms: MiRoom[] = MiCloudClient.parseRooms(corpus.result);
    const requested: Array<{ homeId: string; ownerUid: string }> = [];
    const client = {
      manualScenes: async (homeId: string, ownerUid: string) => {
        requested.push({ homeId, ownerUid });
        return [];
      },
    };

    const snapshot = await refreshMiScenes(client, rooms, corpus.sessionUserId, undefined, 0);

    // The corpus also pins the negative case: home-2003 (shared, no uid) is never queried.
    assert.deepEqual(requested, corpus.expectedSceneRequests);
    assert.deepEqual(snapshot, { refreshedAt: 0, scenes: [] });
  });

  it("resolves the owner per home: own uid wins, owned falls back, shared stays skipped", () => {
    assert.equal(sceneOwnerUid({ ownerUid: "7" }, "42"), "7");
    assert.equal(sceneOwnerUid({}, "42"), "42");
    assert.equal(sceneOwnerUid({ ownerUid: "" }, "42"), "42");
    assert.equal(sceneOwnerUid({ isSharedHome: true }, "42"), null);
    assert.equal(sceneOwnerUid({ isSharedHome: true, ownerUid: "9" }, "42"), "9");
    assert.equal(sceneOwnerUid({}, ""), null);
  });
});

describe("Mi cloud scenes stay scoped to the selected home", () => {
  it("drops the previous home's scene (and a cloud-deleted scene) after a home switch", async () => {
    const app = await mountApp();
    assert.deepEqual(sceneNames(app), ["回家"]);

    app.selectHome("home-b");
    // The switch drops the old home's scene rows at once; the home gate must refuse the id anyway.
    assert.equal(
      app.scenes.some((scene) => scene.entityId === sceneEntityId("home-a", "11")),
      false,
      "the previous home's scene rows are cleared synchronously on switch",
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

  it("reports a declined scene confirmation as cancelled, not as a failed write", async () => {
    const app = await mountApp();
    const bannerBefore = app.replyBanner;

    const running = app.executeIntents(
      [{ targetId: sceneEntityId("home-a", "11"), operation: { kind: "activateScene" } }],
      "执行回家场景",
      "测试",
    );
    await waitFor(() => app.pendingHighRisk !== null, "the scene confirmation to arm");
    finishMiSceneConfirmation(app, false);

    assert.equal(await running, false);
    assert.equal(runSceneCalls, 0);
    assert.notEqual(app.replyBanner?.isError, true, "a deliberate cancel must not surface a failure banner");
    assert.equal(app.replyBanner?.text, bannerBefore?.text);
    assert.equal(app.replyBanner?.text.includes("设备未响应"), false);
  });
});

describe("Home Assistant scene rows", () => {
  it("replaces script rows on every refresh instead of duplicating them", async () => {
    const app = await mountApp();
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, false);
    let states: Array<{ entity_id: string; state: string; attributes: Record<string, unknown> }> = [
      { entity_id: "script.evening", state: "on", attributes: { friendly_name: "晚间脚本" } },
    ];
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return { areas: [], devices: [], entities: [], states } as unknown as T;
      }
      return null as unknown as T;
    });

    await app.refreshHADevices(false);
    await app.refreshHADevices(false);
    assert.equal(
      app.scenes.filter((scene) => scene.id === "script.evening").length,
      1,
      "a poll must replace the script row instead of appending a copy",
    );
    assert.ok(
      app.scenes.some((scene) => scene.sourceBackend === "xiaomiCloud"),
      "an HA refresh keeps the Xiaomi scene rows",
    );

    states = [];
    await app.refreshHADevices(false);
    assert.equal(
      app.scenes.some((scene) => scene.id === "script.evening"),
      false,
      "a script removed in Home Assistant must disappear",
    );
  });
});
