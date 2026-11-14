import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import {
  MiCloudClient,
  MiCloudError,
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  type MiSession,
} from "../src/core/miCloudClient.js";

const SETTINGS_KEY = STORAGE_KEY;
const SECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
const MODEL = "yeelink.light.ceiling22";

const SESSION: MiSession = {
  userId: "100",
  cUserId: "",
  ssecurity: SECURITY,
  serviceToken: "tok",
  passToken: "",
  region: "cn",
};

const SPEC = {
  type: "urn:miot-spec-v2:device:light:0000A001:sync-test:1",
  services: [{
    iid: 2,
    type: "urn:miot-spec-v2:service:light:00007802:sync-test:1",
    properties: [
      { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:sync-test:1", format: "bool", access: ["read", "write"] },
    ],
    actions: [],
  }],
};

/** The signed request body the client built, so a test can assert what it actually sent. */
function requestPayload(body: string): Record<string, unknown> {
  const fields = new URLSearchParams(body);
  const nonce = fields.get("_nonce") ?? "";
  const data = fields.get("data") ?? "";
  assert.ok(nonce !== "" && data !== "", "the request must be an encrypted form body");
  const plain = MiCloudCrypto.decryptResponse(data, MiCloudCrypto.signedNonce(SECURITY, nonce));
  return JSON.parse(plain) as Record<string, unknown>;
}

/** A cloud answer the client accepts as-is: plain JSON with `code: 0` and the payload in `result`. */
function ok(result: unknown): HttpResponse {
  return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
}

function apiPath(url: string): string {
  return new URL(url).pathname.replace(/^\/app\//, "");
}

interface CloudApi {
  /** Decrypted payload of the last request to `path`; fails when the path was never called. */
  call(path: string): Record<string, unknown>;
  /** Every path the client asked for, in order. */
  readonly paths: string[];
}

function recordingTransport(respond: (path: string) => unknown): { transport: HttpTransport; api: CloudApi } {
  const calls: Array<{ path: string; payload: Record<string, unknown> }> = [];
  const transport = async (req: HttpRequest): Promise<HttpResponse> => {
    const path = apiPath(req.url);
    calls.push({ path, payload: req.body ? requestPayload(req.body) : {} });
    return ok(respond(path));
  };
  return {
    transport,
    api: {
      get paths() {
        return calls.map((call) => call.path);
      },
      call: (path) => {
        const found = [...calls].reverse().find((call) => call.path === path);
        assert.ok(found, `no request reached ${path}`);
        return found.payload;
      },
    },
  };
}

describe("Mi Cloud response decoding (#76)", () => {
  it("rejects a 200 body that carries neither a code nor a usable message", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse("{}", 200, "signed"),
      (err: unknown) => err instanceof MiCloudError && err.kind === "badResponse",
    );
  });

  it("reports the HTTP status of a gateway error body instead of a parse failure", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse(JSON.stringify({ error: "Bad Gateway" }), 502, "signed"),
      (err: unknown) => err instanceof MiCloudError && err.kind === "http" && err.code === 502,
    );
  });

  it("treats an auth word in a code-less body as a dead session", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse(JSON.stringify({ error: "invalid_token" }), 200, "signed"),
      (err: unknown) => err instanceof MiCloudError && err.kind === "sessionExpired",
    );
  });

  it("surfaces the API code of a non-zero answer", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse(JSON.stringify({ code: -8, message: "bad" }), 400, "signed"),
      (err: unknown) => err instanceof MiCloudError && err.kind === "api" && err.code === -8,
    );
  });

  it("keeps a 500 a transport failure even when the body claims code 0", () => {
    assert.throws(
      () => MiCloudClient.decodeResponse(JSON.stringify({ code: 0 }), 500, "signed"),
      (err: unknown) => err instanceof MiCloudError && err.kind === "http" && err.code === 500,
    );
  });
});

describe("Mi Cloud room and device requests (#76 / #67)", () => {
  it("asks for app_ver 9, keeps every home's owner uid, and merges get_dev_room_page info pages", async () => {
    const pages = [
      {
        homelist: [{
          id: 1,
          name: "我的家",
          uid: "5001",
          dids: ["lamp-0"],
          roomlist: [
            { id: 10, name: "书房", dids: ["lamp-1"] },
            { id: 11, name: "卧室", dids: [] },
          ],
        }],
        has_more: true,
        max_id: "100",
      },
      {
        info: [{
          id: 1,
          dids: ["lamp-0", "lamp-3"],
          roomlist: [
            { id: 10, dids: ["lamp-1", "lamp-2"] },
            { id: 11, dids: ["lamp-4"] },
          ],
        }],
        has_more: false,
      },
    ];
    const { transport, api } = recordingTransport((path) =>
      path === "v2/homeroom/gethome_merged" ? pages[0] : pages[1],
    );

    const rooms = await new MiCloudClient(SESSION, transport).homeRooms();

    assert.deepEqual(api.paths, ["v2/homeroom/gethome_merged", "v2/homeroom/get_dev_room_page"]);
    assert.equal(api.call("v2/homeroom/gethome_merged")["app_ver"], 9);
    assert.deepEqual(api.call("v2/homeroom/get_dev_room_page"), { start_id: "100", limit: 150 });
    assert.deepEqual(
      rooms.map((room) => [room.id, room.homeId, room.ownerUid, room.dids]),
      [
        ["10", "1", "5001", ["lamp-1", "lamp-2"]],
        ["11", "1", "5001", ["lamp-4"]],
        ["home_1", "1", "5001", ["lamp-0", "lamp-3"]],
      ],
    );
  });

  it("replays the shared mi_home_rooms_merged + mi_dev_room_page contract fixtures identically to macOS", () => {
    const readContract = (name: string): Record<string, unknown> =>
      JSON.parse(readFileSync(resolve(process.cwd(), `../Tests/Fixtures/contracts/${name}`), "utf8")) as Record<string, unknown>;
    const initial = MiCloudClient.unwrapResult(readContract("mi_home_rooms_merged.json"));
    const page = MiCloudClient.unwrapResult(readContract("mi_dev_room_page.json"));
    const merged = MiCloudClient.mergeRoomPage(page, MiCloudClient.parseRooms(initial));
    assert.deepEqual(merged, [
      { id: "room-2001", name: "Living Room", dids: ["did-light-0001", "did-plug-0004"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2002", name: "Study", dids: ["did-camera-0003", "did-fan-0006"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002", "did-sensor-0005"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2003", name: "Kitchen", dids: ["did-fridge-0008"], homeId: "home-1002", homeName: "Contract Beach House" },
      { id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true },
      { id: "home_home-1002", name: "", dids: ["did-kettle-0007"], homeId: "home-1002", homeName: "Contract Beach House" },
    ]);
  });

  it("keeps a room-less shared home visible when the cloud names its owner", () => {
    const rooms = MiCloudClient.parseRooms({
      homelist: [],
      share_home_list: [{ id: "8001", name: "爸妈家", uid: "5002", roomlist: [], dids: [] }],
    });
    assert.deepEqual(rooms, [
      { id: "home_8001", name: "", dids: [], homeId: "8001", homeName: "爸妈家", isSharedHome: true, ownerUid: "5002" },
    ]);
    // Without an owner uid there is no pair to ask `home_device_list` with, so nothing is invented.
    assert.deepEqual(
      MiCloudClient.parseRooms({ share_home_list: [{ id: "8002", name: "无主", roomlist: [], dids: [] }] }),
      [],
    );
  });

  it("asks the device list for third-party and split keys, and follows start_did", async () => {
    const pages = [
      { list: [{ did: "lamp-1", name: "台灯", model: MODEL, isOnline: true }], has_more: true, next_start_did: "d2" },
      { list: [{ did: "lamp-2", name: "落地灯", model: MODEL, isOnline: false }] },
    ];
    const { transport, api } = recordingTransport(() => pages.shift());

    const devices = await new MiCloudClient(SESSION, transport).deviceList();

    assert.deepEqual(api.paths, ["v2/home/device_list_page", "v2/home/device_list_page"]);
    assert.equal(api.call("v2/home/device_list_page")["get_third_device"], true);
    assert.equal(api.call("v2/home/device_list_page")["start_did"], "d2");
    assert.deepEqual(devices.map((device) => [device.did, device.name]), [["lamp-1", "台灯"], ["lamp-2", "落地灯"]]);
  });

  it("pages one home's devices through home_device_list by (home id, owner uid)", async () => {
    const pages = [
      { device_info: [{ did: "lamp-1", name: "台灯", model: MODEL, isOnline: true }], has_more: true, max_did: "d2" },
      { device_info: [{ did: "lamp-2", name: "落地灯", model: MODEL, isOnline: true }] },
    ];
    const { transport, api } = recordingTransport(() => pages.shift());

    const devices = await new MiCloudClient(SESSION, transport).homeDevices("7001", "5001");

    assert.deepEqual(api.paths, ["v2/home/home_device_list", "v2/home/home_device_list"]);
    const first = api.call("v2/home/home_device_list");
    assert.equal(first["home_id"], 7001);
    assert.equal(first["home_owner"], 5001);
    assert.equal(first["get_third_device"], true);
    assert.equal(api.call("v2/home/home_device_list")["start_did"], "d2");
    assert.deepEqual(devices.map((device) => device.did), ["lamp-1", "lamp-2"]);
  });
});

let dom: Window;

interface CloudRequest {
  readonly path: string;
  /** Decrypted payload the client sent, so a test can assert which home it asked about. */
  readonly payload: Record<string, unknown>;
}

/** Answers the MIoT spec host so a cloud device can be synthesized, and hands the cloud call back. */
function installInvoke(cloud: (request: CloudRequest) => unknown): void {
  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (name !== "native_http") return undefined;
    const url = String(args["url"] ?? "");
    if (url.startsWith("https://miot-spec.org/miot-spec-v2/instance?")) {
      return { status: 200, headers: {}, body: JSON.stringify(SPEC) };
    }
    if (url.startsWith("https://miot-spec.org/miot-spec-v2/instances?")) {
      return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model: MODEL, type: SPEC.type }] }) };
    }
    const body = typeof args["body"] === "string" ? args["body"] : "";
    return cloud({ path: apiPath(url), payload: body ? requestPayload(body) : {} });
  };
  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
}

function cloudApp(extra: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    SETTINGS_KEY,
    JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      enableGrokBall: false,
      autoCheckUpdates: false,
      miSession: SESSION,
      cachedModelTypes: { [MODEL]: SPEC.type },
      ...extra,
    }),
  );
  const root = document.querySelector<HTMLElement>("#app");
  assert.ok(root, "Missing #app");
  return new MenuMijiaWindowsApp(root);
}

async function waitFor(ready: () => boolean, message: string): Promise<void> {
  const deadline = performance.now() + 4000;
  while (!ready()) {
    if (performance.now() >= deadline) assert.fail(message);
    await setImmediate();
  }
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("Xiaomi cloud refresh with a broken room list (#76)", () => {
  it("surfaces a failed home_device_list lookup instead of claiming 0 devices", async () => {
    installInvoke(({ path }) => {
      if (path === "v2/home/home_device_list") return { status: 502, headers: {}, body: JSON.stringify({ error: "Bad Gateway" }) };
      if (path.includes("device_list")) return ok({ list: [] });
      return ok({
        homelist: [],
        share_home_list: [{ id: "8001", name: "爸妈家", uid: "5002", roomlist: [], dids: [] }],
      });
    });
    const app = cloudApp();

    await waitFor(() => !app.isSyncingCloud && app.replyBanner !== null, "the refresh never settled");

    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /502/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /暂未发现米家设备/);
    assert.equal(app.devices.length, 0);
  });

  it("reports the failure instead of claiming the account has no devices", async () => {
    installInvoke(({ path }) => {
      if (path.includes("device_list")) return ok({ list: [] });
      return { status: 500, headers: {}, body: "" };
    });
    const app = cloudApp();

    await waitFor(() => !app.isSyncingCloud && app.replyBanner !== null, "the refresh never settled");

    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /米家云同步失败/);
    assert.match(app.replyBanner?.text ?? "", /HTTP 500/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /暂未发现米家设备/);
    assert.equal(app.devices.length, 0);
  });
});

describe("A shared home whose dids the by-did lookup already resolves (#134)", () => {
  it("uses that lookup and never falls back to home_device_list", async () => {
    const homeDeviceListCalls: Array<Record<string, unknown>> = [];
    const lookupDids: unknown[] = [];
    installInvoke(({ path, payload }) => {
      if (path === "v2/home/home_device_list") {
        homeDeviceListCalls.push(payload);
        return ok({ device_info: [{ did: "lamp-2", name: "卧室灯", model: MODEL, isOnline: true }] });
      }
      if (path.includes("device_list")) {
        const asked = payload["dids"];
        if (Array.isArray(asked)) {
          lookupDids.push(...asked);
          // A shared home's devices arrive only when the list is asked for them by did (#134).
          return ok({ list: asked.map((did) => ({ did, name: "卧室灯", model: MODEL, isOnline: true })) });
        }
        return ok({ list: [{ did: "lamp-1", name: "台灯", model: MODEL, isOnline: true }] });
      }
      return ok({
        homelist: [{ id: 1, name: "我的家", uid: 5001, roomlist: [{ id: 10, name: "客厅", dids: ["lamp-1"] }] }],
        share_home_list: [{ id: 2, name: "爸妈家", uid: 5002, roomlist: [{ id: 20, name: "卧室", dids: ["lamp-2"] }] }],
      });
    });
    const app = cloudApp();

    await waitFor(() => !app.isSyncingCloud && app.devices.length > 0, "the refresh never settled");

    assert.deepEqual(lookupDids, ["lamp-2"]);
    assert.equal(app.devices.length, 2);
    assert.equal(app.devices.find((device) => device.id === "lamp-2")?.isSharedHome, true);
    // The by-did lookup already answered for that home, so the per-home request must not run.
    assert.deepEqual(homeDeviceListCalls, []);
  });
});

describe("Split switch keys discovered via home_device_list", () => {
  it("keeps the parent panel's named room instead of moving split keys into 全屋", async () => {
    installInvoke(({ path, payload }) => {
      if (path === "v2/home/home_device_list") {
        return ok({
          device_info: [
            { did: "100", name: "双键开关", model: MODEL, isOnline: true },
            { did: "100.s2", name: "筒灯", model: MODEL, isOnline: true, extra: { split: { parentId: "100", moduleId: 2 } } },
          ],
        });
      }
      if (path.includes("device_list")) {
        if (Array.isArray(payload["dids"])) return ok({ list: [] });
        return ok({ list: [{ did: "100", name: "双键开关", model: MODEL, isOnline: true }] });
      }
      return ok({
        homelist: [{ id: "1", name: "我的家", uid: "5001", roomlist: [{ id: "10", name: "客厅", dids: ["100", "ghost"] }] }],
      });
    });
    const app = cloudApp();

    await waitFor(
      () => app.devices.some((d) => d.id === "100.s2"),
      "the split key never reached the panel",
    );
    assert.equal(app.devices.find((d) => d.id === "100.s2")?.roomName, "客厅");
  });
});

describe("Xiaomi cloud devices of a room-less shared home (#67)", () => {
  it("finds them through home_device_list and shows them", async () => {
    const homeCalls: Record<string, unknown>[] = [];
    installInvoke(({ path, payload }) => {
      if (path === "v2/home/home_device_list") {
        homeCalls.push(payload);
        return ok({ device_info: [{ did: "lamp-9", name: "床头灯", model: MODEL, isOnline: true }] });
      }
      if (path.includes("device_list")) return ok({ list: [] });
      return ok({
        homelist: [],
        // The unfiltered list omits a home another account shared, and the home names no room.
        share_home_list: [{ id: "8001", name: "爸妈家", uid: "5002", roomlist: [], dids: [] }],
      });
    });
    const app = cloudApp();

    await waitFor(
      () => document.querySelector('[data-body-device="lamp-9"]') !== null,
      "the shared home's device never reached the panel",
    );
    assert.equal(app.devices.length, 1);
    assert.equal(app.devices[0]?.name, "床头灯");
    assert.equal(app.devices[0]?.isSharedHome, true);
    assert.deepEqual(app.homes.map((home) => [home.id, home.name]), [["8001", "爸妈家"]]);
    assert.equal(app.replyBanner?.isError, undefined);
    assert.match(app.replyBanner?.text ?? "", /已同步 1 台真实米家设备/);
    // One request, carrying the pair the endpoint needs, for the only home the account has.
    assert.equal(homeCalls.length, 1);
    assert.equal(homeCalls[0]?.["home_id"], 8001);
    assert.equal(homeCalls[0]?.["home_owner"], 5002);
  });
});

describe("A selected home the cloud reports as empty (#67)", () => {
  it("offers 显示全部家庭 and brings the other home's devices back", async () => {
    const homeDeviceListCalls: Array<Record<string, unknown>> = [];
    installInvoke(({ path, payload }) => {
      if (path === "v2/home/home_device_list") {
        homeDeviceListCalls.push(payload);
        return ok({ device_info: [] });
      }
      if (path.includes("device_list")) {
        return ok({ list: [{ did: "lamp-1", name: "台灯", model: MODEL, isOnline: true }] });
      }
      return ok({
        homelist: [
          { id: 1, name: "我的家", uid: 5001, roomlist: [{ id: 10, name: "客厅", dids: ["lamp-1"] }] },
          { id: 2, name: "空房", uid: 5001, roomlist: [{ id: 20, name: "书房", dids: [] }] },
        ],
      });
    });
    const app = cloudApp({ selectedHomeId: "2" });

    await waitFor(
      () => document.querySelector("#empty-selected-home") !== null,
      "the empty selected home never rendered its way back",
    );
    assertMissing(document.querySelector('[data-body-device="lamp-1"]'));
    assert.deepEqual(app.homes.map((home) => [home.id, home.deviceCount]), [["1", 1], ["2", 0]]);

    (document.querySelector<HTMLElement>("#btn-empty-all-homes") as HTMLElement).click();
    assert.equal(app.settings.selectedHomeId, null);

    await waitFor(
      () => document.querySelector('[data-body-device="lamp-1"]') !== null,
      "the other home's device never came back",
    );
    assertMissing(document.querySelector("#empty-selected-home"));
    assert.equal(app.devices.length, 1);
    // Home 2 names no dids, so `home_device_list` is the only way to learn it has none; home 1
    // resolved its did from the device list and is never asked.
    assert.ok(homeDeviceListCalls.length > 0);
    assert.deepEqual(
      [...new Set(homeDeviceListCalls.map((call) => call["home_id"]))],
      [2],
    );
  });
});
