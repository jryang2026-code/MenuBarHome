import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MiCloudClient } from "../src/core/miCloudClient.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { CameraLiveController } from "../src/ui/cameraLive.js";

import { DEVICE_CATEGORY_IDS } from "../src/core/capabilityManifest.js";

let dom: Window;

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) assert.fail("Timed out waiting for camera live UI state");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

interface MockCameraDevice {
  readonly did: string;
  readonly name: string;
  readonly model: string;
  readonly roomName?: string;
  readonly homeId?: string;
  readonly isSharedHome?: boolean;
  readonly ownerUid?: string;
  readonly omitFromUnfilteredList?: boolean;
  readonly localip?: string;
  readonly isOnline?: boolean;
  readonly parent_id?: string;
}

function makeCameraMiotSpec(modelSlug = "isa-500dh") {
  return {
    type: `urn:miot-spec-v2:device:camera:0000A01C:${modelSlug}:1`,
    services: [
      {
        iid: 2,
        type: `urn:miot-spec-v2:service:camera-control:0000782F:${modelSlug}:1`,
        properties: [
          {
            iid: 1,
            type: `urn:miot-spec-v2:property:on:00000006:${modelSlug}:1`,
            format: "bool",
            access: ["read", "write"],
          },
        ],
        actions: [],
      },
      {
        iid: 9,
        type: `urn:miot-spec-v2:service:p2p-stream:00007881:${modelSlug}:1`,
        properties: [],
        actions: [
          {
            iid: 1,
            type: `urn:miot-spec-v2:action:start-p2p-stream:00002839:${modelSlug}:1`,
            in: [],
            out: [],
          },
          {
            iid: 2,
            type: `urn:miot-spec-v2:action:stop-stream:00002822:${modelSlug}:1`,
            in: [],
            out: [],
          },
        ],
      },
    ],
  };
}

async function mountCloudCameraApp(options: {
  devices: readonly MockCameraDevice[];
  selectedHomeId?: string | null;
  frame?: (src: string) => Promise<string>;
  bridgeResult?: (args: Record<string, unknown>) => string | Promise<string>;
  hlsBridgeResult?: (args: Record<string, unknown>) => string | Promise<string>;
}) {
  const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
  const spec = makeCameraMiotSpec();
  const bridgeCalls: Array<Record<string, unknown>> = [];
  const hlsBridgeCalls: Array<Record<string, unknown>> = [];
  const stopBridgeCalls: Array<Record<string, unknown>> = [];
  const vendorDids: string[] = [];
  const frameSrcs: string[] = [];
  const p2pStartsByDid = new Map<string, number>();
  const p2pStopsByDid = new Map<string, number>();
  let runtimeStops = 0;
  let deviceListCalls = 0;
  let homeRoomCalls = 0;

  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (name === "bridge_hls_camera_stream") {
      hlsBridgeCalls.push(args);
      if (options.hlsBridgeResult) return options.hlsBridgeResult(args);
      const did = String(args["did"] ?? "").replace(/[^A-Za-z0-9_]/g, "");
      return `cam_mjpeg_${did}`;
    }
    if (name === "start_xiaomi_camera_bridge") {
      bridgeCalls.push(args);
      if (options.bridgeResult) return options.bridgeResult(args);
      const did = String(args["did"] ?? "").replace(/[^A-Za-z0-9_]/g, "");
      const sub = typeof args["subdid"] === "string" ? args["subdid"].replace(/[^A-Za-z0-9_]/g, "") : "";
      const key = sub ? `${did}_${sub}` : did;
      const ch = typeof args["channel"] === "number" && args["channel"] > 0 ? `_c${args["channel"]}` : "";
      return `cam_h264_${key}${ch}|cam_mjpeg_${key}${ch}`;
    }
    if (name === "stop_camera_runtime") {
      runtimeStops += 1;
      return undefined;
    }
    if (name === "stop_xiaomi_camera_bridge") {
      stopBridgeCalls.push(args);
      return undefined;
    }
    if (name === "go2rtc_jpeg_frame") {
      const src = String(args["src"] ?? "");
      frameSrcs.push(src);
      return options.frame ? options.frame(src) : "aGVsbG8";
    }
    if (name !== "native_http") return undefined;

    const url = String(args["url"] ?? "");
    if (url.includes("/instance?")) {
      return { status: 200, headers: {}, body: JSON.stringify(spec) };
    }
    if (url.includes("/instances?")) {
      const instances = options.devices
        .filter((d) => !d.model.startsWith("mxiang.camera.mwc10"))
        .map((d) => ({ model: d.model, type: spec.type }));
      return { status: 200, headers: {}, body: JSON.stringify({ instances }) };
    }

    const decodeEncryptedBody = (): Record<string, unknown> => {
      const fields = new URLSearchParams(String(args["body"] ?? ""));
      const nonce = fields.get("_nonce") ?? "";
      const encrypted = fields.get("data") ?? "";
      if (!nonce || !encrypted) return {};
      return JSON.parse(
        MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce)),
      ) as Record<string, unknown>;
    };

    let result: unknown = {};
    if (url.includes("home_device_list")) {
      const payload = decodeEncryptedBody();
      const homeId = String(payload["home_id"] ?? "");
      result = {
        device_info: options.devices
          .filter((d) => (d.homeId ?? "1") === homeId)
          .map((d) => ({
            did: d.did,
            name: d.name,
            model: d.model,
            isOnline: d.isOnline ?? true,
            localip: d.localip ?? "",
            ...(d.parent_id ? { parent_id: d.parent_id } : {}),
            spec_type: d.model.startsWith("mxiang.camera.mwc10") ? null : spec.type,
          })),
        has_more: false,
      };
    } else if (url.includes("device_list")) {
      deviceListCalls += 1;
      result = {
        list: options.devices
          .filter((d) => !d.omitFromUnfilteredList)
          .map((d) => ({
            did: d.did,
            name: d.name,
            model: d.model,
            isOnline: d.isOnline ?? true,
            localip: d.localip ?? "",
            ...(d.parent_id ? { parent_id: d.parent_id } : {}),
            spec_type: d.model.startsWith("mxiang.camera.mwc10") ? null : spec.type,
          })),
        has_more: false,
      };
    } else if (url.includes("miss_get_vendor")) {
      const payload = decodeEncryptedBody();
      vendorDids.push(String(payload["did"] ?? ""));
      result = {
        public_key: "device-public",
        sign: "device-sign",
        vendor: { vendor: 4, vendor_params: { p2p_id: "uid-1" } },
      };
    } else if (url.includes("homeroom/")) {
      homeRoomCalls += 1;
      const homes = new Map<
        string,
        { shared: boolean; ownerUid?: string; rooms: Map<string, string[]> }
      >();
      for (const d of options.devices) {
        const hid = d.homeId ?? "1";
        const entry = homes.get(hid) ?? {
          shared: Boolean(d.isSharedHome),
          ownerUid: d.ownerUid,
          rooms: new Map<string, string[]>(),
        };
        if (d.isSharedHome) entry.shared = true;
        if (d.ownerUid) entry.ownerUid = d.ownerUid;
        const rm = d.roomName ?? "客厅";
        const arr = entry.rooms.get(rm) ?? [];
        arr.push(d.did);
        entry.rooms.set(rm, arr);
        homes.set(hid, entry);
      }
      const homelist: Array<Record<string, unknown>> = [];
      const shareHomeList: Array<Record<string, unknown>> = [];
      let roomSeq = 10;
      for (const [hid, info] of homes.entries()) {
        const homeObj: Record<string, unknown> = {
          id: hid,
          name: `家庭 ${hid}`,
          dids: [],
          ...(info.ownerUid ? { uid: info.ownerUid } : {}),
          roomlist: Array.from(info.rooms.entries()).map(([name, dids]) => ({
            id: String(roomSeq++),
            name,
            dids,
          })),
        };
        if (info.shared) shareHomeList.push(homeObj);
        else homelist.push(homeObj);
      }
      result = {
        homelist,
        ...(shareHomeList.length > 0 ? { share_home_list: shareHomeList } : {}),
      };
    } else if (url.includes("miotspec/prop/")) {
      result = options.devices
        .filter((d) => !d.model.startsWith("mxiang.camera.mwc10"))
        .map((d) => ({ did: d.did, siid: 2, piid: 1, code: 0, value: true }));
    } else if (url.includes("miotspec/action")) {
      const payload = decodeEncryptedBody() as { params?: { did?: string; aiid?: number } };
      const did = String(payload.params?.did ?? "");
      if (payload.params?.aiid === 1) {
        p2pStartsByDid.set(did, (p2pStartsByDid.get(did) ?? 0) + 1);
        result = { code: 0, out: [] };
      } else if (payload.params?.aiid === 2) {
        p2pStopsByDid.set(did, (p2pStopsByDid.get(did) ?? 0) + 1);
        result = { code: -1, out: [] };
      }
    }
    return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
  };

  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  const cachedModelTypes: Record<string, string> = {};
  for (const d of options.devices) {
    if (!d.model.startsWith("mxiang.camera.mwc10")) {
      cachedModelTypes[d.model] = spec.type;
    }
  }
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      ...(options.selectedHomeId !== undefined ? { selectedHomeId: options.selectedHomeId } : {}),
      miSession: {
        userId: "100",
        cUserId: "c100",
        ssecurity: security,
        serviceToken: "tok",
        passToken: "",
        region: "cn",
      },
      cachedModelTypes,
    }),
  );

  const app = new MenuMijiaWindowsApp(element("#app"));
  app.cameraLive.cameraFrameGiveUpMs = 2_000;
  app.cameraLive.cameraFrameRetryMs = 10;
  return {
    app,
    bridgeCalls,
    hlsBridgeCalls,
    stopBridgeCalls,
    vendorDids,
    frameSrcs,
    p2pStartsByDid,
    p2pStopsByDid,
    getRuntimeStops: () => runtimeStops,
    getDeviceListCalls: () => deviceListCalls,
    getHomeRoomCalls: () => homeRoomCalls,
  };
}

beforeEach(() => {
  dom = mountTestWindow();
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("CameraLiveController dual-lens, gateway, manual IP, rotation & multi-camera HUD", () => {
  it("cancels camera standby and serializes a rapid disable and reopen with a pending bridge", async (test) => {
    let finishStart!: (result: string) => void;
    const firstStart = new Promise<string>((resolve) => { finishStart = resolve; });
    let starts = 0;
    const ctx = await mountCloudCameraApp({
      devices: [{
        did: "cam-disable",
        name: "客厅摄像机",
        model: "isa.camera.500dh",
        localip: "192.168.1.50",
      }],
      bridgeResult: () => {
        starts += 1;
        if (starts === 1) return firstStart;
        assert.equal(ctx.getRuntimeStops(), 1);
        return "cam_h264_camdisable|cam_mjpeg_camdisable";
      },
    });
    const id = "cam-disable";
    const live = ctx.app.cameraLive;
    ctx.app.settings.interfaceLanguage = "zh-Hans";
    await waitFor(() => ctx.app.devices.some((device) => device.id === id));
    live.cameraSameSessionCooldownMs = 0;
    live.openCameraLiveView(id);
    await waitFor(() => starts === 1);
    const originalSetTimeout = window.setTimeout.bind(window);
    let expiredStandby: (() => void) | undefined;
    const timerMock = test.mock.method(window, "setTimeout", (callback: () => void, delay?: number) => {
      if (delay === 120_000) expiredStandby = callback;
      return originalSetTimeout(callback, delay);
    });
    live.hideCameraLiveView();
    timerMock.mock.restore();
    assert.ok(expiredStandby);
    const keepWarm = live.liveCameraKeepAliveTimer;
    assert.notEqual(keepWarm, null);

    const withoutCamera = DEVICE_CATEGORY_IDS.filter((category) => category !== "camera");
    assert.equal(ctx.app.setEnabledDeviceCategories(withoutCamera), true);
    assert.equal(live.liveCameraKeepAliveTimer, null);
    assert.equal(live.activeLiveCameraId, null);
    assert.equal(live.liveCameraImgEl, null);
    assert.equal(ctx.getRuntimeStops(), 0);
    assert.equal(ctx.app.devices.some((device) => device.id === id), false);
    assert.equal(ctx.app.hiddenDevices.some((device) => device.id === id && device.category === "camera"), true);

    live.openCameraLiveView(id);
    assert.equal(ctx.app.replyBanner?.text, "该设备类型已关闭");
    expiredStandby();
    assert.equal(starts, 1);
    assert.equal(ctx.frameSrcs.length, 0);
    assert.equal(ctx.app.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS), true);
    live.openCameraLiveView(id);
    assert.equal(starts, 1);

    finishStart("cam_h264_camdisable|cam_mjpeg_camdisable");
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_camdisable"));
    assert.equal(starts, 2);
    assert.equal(ctx.getRuntimeStops(), 1);
    assert.equal(live.activeLiveCameraId, id);
    assert.equal(live.liveCameraKeepAliveTimer, null);
    live.closeCameraLiveView();
  });

  it("renders dual-lens pills, persists channel per camera, and switches channels cleanly", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-dual",
          name: "客厅双摄",
          model: "isa.camera.500dh",
          localip: "192.168.1.50",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-dual"]') !== null);
    await click('[data-body-device="cam-dual"]');
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_camdual"));

    const pills = Array.from(document.querySelectorAll<HTMLElement>("[data-cameralens]"));
    assert.equal(pills.length, 2);
    assert.equal(pills[0]?.textContent?.trim(), "广角");
    assert.equal(pills[1]?.textContent?.trim(), "长焦");
    assert.equal(pills[0]?.classList.contains("is-active"), true);
    assert.equal("channel" in (ctx.bridgeCalls[0] ?? {}), false);

    // Switch to telephoto lens (channel 1)
    await click('[data-cameralens="cam-dual"][data-cameralens-channel="1"]');
    await waitFor(() => ctx.bridgeCalls.length === 2 && ctx.frameSrcs.includes("cam_mjpeg_camdual_c1"));
    assert.deepEqual(ctx.stopBridgeCalls[0], { did: "cam-dual" });
    assert.equal(ctx.bridgeCalls[1]?.["channel"], 1);

    const savedChannels = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_CHANNELS_STORAGE_KEY) ?? "{}",
    ) as Record<string, number>;
    assert.equal(savedChannels["cam-dual"], 1);

    // Switching back to wide lens (channel 0) tears down channel 1
    await click('[data-cameralens="cam-dual"][data-cameralens-channel="0"]');
    await waitFor(() => ctx.bridgeCalls.length === 3);
    assert.deepEqual(ctx.stopBridgeCalls[1], { did: "cam-dual", channel: 1 });
    assert.equal("channel" in (ctx.bridgeCalls[2] ?? {}), false);
  });

  it("routes battery cameras through their online indoor hub with subdid and supports manual LAN IP save & clear", async () => {
    let hubCloudIp = "";
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-mwc11",
          name: "庭院电池摄像机",
          model: "mxiang.camera.mwc11",
          roomName: "庭院",
          localip: "",
        },
        {
          did: "hub-mwc10",
          name: "室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "庭院",
          get localip() {
            return hubCloudIp;
          },
        } as MockCameraDevice,
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-mwc11"]') !== null);
    await click('[data-body-device="cam-mwc11"]');

    // Neither camera nor hub has a cloud LAN IP yet -> manual LAN IP fallback appears
    await waitFor(() => document.querySelector("#camera-local-ip-input") !== null);
    assert.equal(ctx.bridgeCalls.length, 0);
    assertMissing(document.querySelector("#btn-clear-camera-ip"));

    // RFC 5737 TEST-NET-1 (192.0.2.10) is not a private LAN IP and must be rejected
    const input = element<HTMLInputElement>("#camera-local-ip-input");
    input.value = "192.0.2.10";
    await click("#btn-save-camera-ip");
    assert.ok(document.querySelector(".cc-camera-ip-error"));
    assert.equal(localStorage.getItem(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY), null);
    assert.equal(ctx.bridgeCalls.length, 0);

    // Valid private LAN IP saves to menubarmijia.cameraLocalIPs and bridges via hub-mwc10 + subdid
    const validInput = element<HTMLInputElement>("#camera-local-ip-input");
    validInput.value = "192.168.1.88";
    await click("#btn-save-camera-ip");
    await waitFor(() => ctx.bridgeCalls.length === 1 && ctx.frameSrcs.includes("cam_mjpeg_hubmwc10_cammwc11"));

    assert.equal(ctx.vendorDids[0], "hub-mwc10");
    assert.equal(ctx.bridgeCalls[0]?.["did"], "hub-mwc10");
    assert.equal(ctx.bridgeCalls[0]?.["model"], "mxiang.camera.mwc10");
    assert.equal(ctx.bridgeCalls[0]?.["localIp"], "192.168.1.88");
    assert.equal(ctx.bridgeCalls[0]?.["subdid"], "cam-mwc11");
    const savedIps = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY) ?? "{}",
    ) as Record<string, string>;
    assert.equal(savedIps["cam-mwc11"], "192.168.1.88");

    // Clearing the manual LAN IP removes it from storage, tears down the hub subdid bridge, and returns to empty-IP state
    const stopsBeforeClear = ctx.stopBridgeCalls.length;
    await click("#btn-clear-camera-ip");
    await waitFor(() => document.querySelector("#camera-local-ip-input") !== null);
    assert.deepEqual(ctx.stopBridgeCalls[stopsBeforeClear], { did: "hub-mwc10", subdid: "cam-mwc11" });
    const clearedIps = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY) ?? "{}",
    ) as Record<string, string>;
    assert.equal("cam-mwc11" in clearedIps, false);

    // When the hub later reports its own cloud localip, reconnect works automatically without manual IP
    hubCloudIp = "172.16.12.9";
    await click("#btn-reload-camera-live");
    await waitFor(() => ctx.bridgeCalls.length === 2);
    assert.equal(ctx.bridgeCalls[1]?.["localIp"], "172.16.12.9");
    assert.equal(ctx.bridgeCalls[1]?.["subdid"], "cam-mwc11");
  });

  it("cycles 90° rotation with aspect-fit scaling and preserves the exact persistent <img> element", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-rot",
          name: "书房摄像机",
          model: "chuangmi.camera.81ac1",
          localip: "192.168.1.51",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-rot"]') !== null);
    await click('[data-body-device="cam-rot"]');
    await waitFor(() => document.querySelector("#cc-camera-live-img") !== null);
    assertMissing(document.querySelector(".cc-camera-switcher"));

    const initialImg = element<HTMLImageElement>("#cc-camera-live-img");
    const initialStage = initialImg.parentElement;
    assert.ok(initialStage);
    let detachCount = 0;
    const origRemove = initialImg.remove.bind(initialImg);
    initialImg.remove = () => {
      detachCount += 1;
      origRemove();
    };

    assert.equal(initialImg.style.transform, "");

    await click("#btn-rotate-camera-live");
    assert.equal(element("#cc-camera-live-img"), initialImg);
    assert.equal(detachCount, 0);
    assert.match(initialImg.style.transform, /^rotate\(90deg\) scale\(/);

    await click("#btn-rotate-camera-live");
    assert.equal(element("#cc-camera-live-img"), initialImg);
    assert.equal(initialImg.style.transform, "rotate(180deg)");

    await click("#btn-rotate-camera-live");
    assert.equal(element("#cc-camera-live-img"), initialImg);
    assert.match(initialImg.style.transform, /^rotate\(270deg\) scale\(/);

    const stored270 = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_ROTATIONS_STORAGE_KEY) ?? "{}",
    ) as Record<string, number>;
    assert.equal(stored270["cam-rot"], 270);

    // Even a full host.render() keeps the same <img> instance and preserves its rotation
    ctx.app.render();
    assert.equal(element("#cc-camera-live-img"), initialImg);
    assert.match(initialImg.style.transform, /^rotate\(270deg\) scale\(/);

    await click("#btn-rotate-camera-live");
    assert.equal(element("#cc-camera-live-img"), initialImg);
    assert.equal(initialImg.style.transform, "");
    assert.equal(detachCount, 0);
  });

  it("renders a multi-camera HUD switcher when >= 2 cameras exist and tears down the previous camera on switch", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-a",
          name: "玄关摄像机",
          model: "chuangmi.camera.81ac1",
          roomName: "玄关",
          localip: "192.168.1.60",
        },
        {
          did: "cam-b",
          name: "阳台摄像机",
          model: "chuangmi.camera.81ac1",
          roomName: "阳台",
          localip: "192.168.1.61",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    await click('[data-body-device="cam-a"]');
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_cama"));

    const switcherButtons = Array.from(document.querySelectorAll<HTMLElement>("[data-cameraswitch]"));
    assert.equal(switcherButtons.length, 2);
    assert.equal(switcherButtons[0]?.classList.contains("is-active"), true);
    assert.equal(switcherButtons[1]?.classList.contains("is-active"), false);

    // Switch directly to cam-b from the HUD without closing the sheet
    await click('[data-cameraswitch="cam-b"]');
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_camb"));

    assert.deepEqual(ctx.stopBridgeCalls[0], { did: "cam-a" });
    assert.ok((ctx.p2pStopsByDid.get("cam-a") ?? 0) >= 2, "switching cameras must release cam-a's P2P session");
    assert.equal(ctx.app.cameraLive.activeLiveCameraId, "cam-b");
    assert.equal(
      element('[data-cameraswitch="cam-b"]').classList.contains("is-active"),
      true,
    );
  });

  it("guards rapid lens switches with liveCameraToken so a superseded channel negotiation cannot take over", async () => {
    let releaseChannel1Bridge: ((val: string) => void) | null = null;
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-race",
          name: "门厅双摄",
          model: "isa.camera.500dh",
          localip: "192.168.1.70",
        },
      ],
      bridgeResult: (args) => {
        if (args["channel"] === 1) {
          return new Promise<string>((resolve) => {
            releaseChannel1Bridge = resolve;
          });
        }
        return "cam_h264_camrace|cam_mjpeg_camrace";
      },
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-race"]') !== null);
    await click('[data-body-device="cam-race"]');
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_camrace"));

    // Click telephoto (channel 1), wait until start_xiaomi_camera_bridge is in-flight, then immediately switch back to wide (channel 0)
    await click('[data-cameralens="cam-race"][data-cameralens-channel="1"]');
    await waitFor(() => releaseChannel1Bridge !== null);
    await click('[data-cameralens="cam-race"][data-cameralens-channel="0"]');
    assert.equal(ctx.bridgeCalls.length, 2);

    ctx.frameSrcs.length = 0;
    releaseChannel1Bridge!("cam_h264_camrace_c1|cam_mjpeg_camrace_c1");
    await waitFor(() => ctx.bridgeCalls.length === 3 && ctx.frameSrcs.includes("cam_mjpeg_camrace"));

    assert.equal(ctx.frameSrcs.includes("cam_mjpeg_camrace_c1"), false);
    assert.equal(ctx.app.cameraLive.liveCameraStreamURL, "cam_mjpeg_camrace");
  });

  it("preserves manual LAN IP draft across background renders and consumes bridge bindings when switching to custom HLS", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-mwc11",
          name: "车库电池摄像机",
          model: "mxiang.camera.mwc11",
          roomName: "车库",
          localip: "",
        },
        {
          did: "hub-mwc10",
          name: "车库室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "车库",
          localip: "",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-mwc11"]') !== null);
    await click('[data-body-device="cam-mwc11"]');
    await waitFor(() => document.querySelector("#camera-local-ip-input") !== null);

    // Typing an in-progress draft survives background host.render()
    const draftInput = element<HTMLInputElement>("#camera-local-ip-input");
    draftInput.value = "192.168.50.";
    draftInput.dispatchEvent(new window.Event("input", { bubbles: true }));
    ctx.app.render();
    assert.equal(element<HTMLInputElement>("#camera-local-ip-input").value, "192.168.50.");

    // Save valid IP -> starts hub subdid bridge
    const readyInput = element<HTMLInputElement>("#camera-local-ip-input");
    readyInput.value = "192.168.50.88";
    readyInput.dispatchEvent(new window.Event("input", { bubbles: true }));
    await click("#btn-save-camera-ip");
    await waitFor(() => ctx.frameSrcs.includes("cam_mjpeg_hubmwc10_cammwc11"));

    // Switch to custom HLS stream URL -> tears down hub subdid bridge AND consumes binding
    await click("#btn-toggle-camera-url");
    const urlInput = element<HTMLInputElement>("#camera-stream-url-input");
    assert.equal(
      urlInput.getAttribute("placeholder"),
      "http://192.168.1.10:1984/api/stream.m3u8?src=cam",
      "the example must be a LAN address; unapproved loopback URLs are rejected by the native layer",
    );
    const urlHint = element("#camera-stream-url-hint").textContent ?? "";
    assert.match(urlHint, /127\.0\.0\.1/);
    assert.match(urlHint, /go2rtc/);
    urlInput.value = "http://192.168.50.10:8080/live/cam.m3u8";
    await click("#btn-save-camera-url");
    await waitFor(() => ctx.hlsBridgeCalls.length === 1 && ctx.frameSrcs.includes("cam_mjpeg_cammwc11"));
    assert.deepEqual(ctx.stopBridgeCalls.at(-1), { did: "hub-mwc10", subdid: "cam-mwc11" });

    // Closing the custom HLS stream now stops { did: "cam-mwc11" }, NOT stale { did: "hub-mwc10", subdid }
    ctx.app.cameraLive.closeCameraLiveView();
    assert.deepEqual(ctx.stopBridgeCalls.at(-1), { did: "cam-mwc11" });
  });

  it("isolates multi-home hubs across rooms and avoids hijacking another home's hub", async () => {
    // 2-home account: home-a has cam-a (yard) + hub-a (hall), home-b has hub-b (living)
    const ctx = await mountCloudCameraApp({
      selectedHomeId: "home-a",
      devices: [
        {
          did: "cam-a",
          name: "一楼院子电池机",
          model: "mxiang.camera.mwc11",
          roomName: "院子",
          homeId: "home-a",
          localip: "",
        },
        {
          did: "hub-a",
          name: "一楼大厅室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "大厅",
          homeId: "home-a",
          localip: "192.168.1.91",
        },
        {
          did: "hub-b",
          name: "别墅客厅室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "客厅",
          homeId: "home-b",
          localip: "192.168.2.91",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    await click('[data-body-device="cam-a"]');
    await waitFor(() => ctx.bridgeCalls.length === 1 && ctx.frameSrcs.includes("cam_mjpeg_huba_cama"));
    assert.equal(ctx.bridgeCalls[0]?.["did"], "hub-a");
    assert.equal(ctx.bridgeCalls[0]?.["localIp"], "192.168.1.91");
    assert.equal(ctx.bridgeCalls[0]?.["subdid"], "cam-a");
  });

  it("falls back to synthesized gatewayDid/gatewayModel on shared homes omitted from deviceList (#76)", async () => {
    const ctx = await mountCloudCameraApp({
      selectedHomeId: "home-shared",
      devices: [
        {
          did: "hub-own",
          name: "自家室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "客厅",
          homeId: "home-own",
          localip: "192.168.1.22",
        },
        {
          did: "cam-shared",
          name: "父母家院子摄像机",
          model: "mxiang.camera.mwc11",
          roomName: "院子",
          homeId: "home-shared",
          isSharedHome: true,
          ownerUid: "888",
          omitFromUnfilteredList: true,
          localip: "",
        },
        {
          did: "hub-shared",
          name: "父母家室内网关",
          model: "mxiang.camera.mwc10",
          roomName: "院子",
          homeId: "home-shared",
          isSharedHome: true,
          ownerUid: "888",
          omitFromUnfilteredList: true,
          localip: "",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-shared"]') !== null);
    await click('[data-body-device="cam-shared"]');

    // Shared home camera falls back to synthesized hub-shared (never hijacking hub-own and never failing with missing_hub)
    await waitFor(() => document.querySelector("#camera-local-ip-input") !== null);
    assert.equal(ctx.bridgeCalls.length, 0);

    const input = element<HTMLInputElement>("#camera-local-ip-input");
    input.value = "192.168.31.66";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    await click("#btn-save-camera-ip");
    await waitFor(() => ctx.bridgeCalls.length === 1 && ctx.frameSrcs.includes("cam_mjpeg_hubshared_camshared"));
    assert.equal(ctx.bridgeCalls[0]?.["did"], "hub-shared");
    assert.equal(ctx.bridgeCalls[0]?.["model"], "mxiang.camera.mwc10");
    assert.equal(ctx.bridgeCalls[0]?.["localIp"], "192.168.31.66");
    assert.equal(ctx.bridgeCalls[0]?.["subdid"], "cam-shared");
  });

  it("clears stale liveCameraStreamURL and renders error state when HLS bridge fails or returns empty mjpegName", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-hls",
          name: "玄关摄像机",
          model: "isa.camera.hlc7",
          localip: "192.168.1.50",
        },
      ],
      hlsBridgeResult: () => "",
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-hls"]') !== null);
    await click('[data-body-device="cam-hls"]');
    await waitFor(() => ctx.bridgeCalls.length === 1);

    await click("#btn-toggle-camera-url");
    const input = element<HTMLInputElement>("#camera-stream-url-input");
    input.value = "http://192.168.1.50:8080/live/index.m3u8";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    await click("#btn-save-camera-url");

    await waitFor(() => ctx.hlsBridgeCalls.length === 1 && !ctx.app.cameraLive.liveCameraLoading);
    assert.equal(ctx.app.cameraLive.liveCameraStreamURL, null);
    assert.ok(ctx.app.cameraLive.liveCameraError);
    assert.ok(document.querySelector(".cc-camera-stage.is-error"));
    assertMissing(document.querySelector("#cc-camera-video"), "video#cc-camera-video");
  });

  it("releases active Xiaomi P2P session when saving a custom stream URL", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-p2p-url",
          name: "客厅摄像机",
          model: "isa.camera.hlc7",
          localip: "192.168.1.50",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-p2p-url"]') !== null);
    await click('[data-body-device="cam-p2p-url"]');
    await waitFor(() => ctx.bridgeCalls.length === 1);
    const stopsBefore = ctx.p2pStopsByDid.get("cam-p2p-url") ?? 0;

    await click("#btn-toggle-camera-url");
    const input = element<HTMLInputElement>("#camera-stream-url-input");
    input.value = "http://192.168.1.50:8080/live.mp4";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    await click("#btn-save-camera-url");

    await waitFor(() => (ctx.p2pStopsByDid.get("cam-p2p-url") ?? 0) > stopsBefore);
    assert.equal(ctx.app.cameraLive.liveCameraStreamURL, "http://192.168.1.50:8080/live.mp4");
  });

  it("does not release the newly connected P2P session when a superseded same-camera negotiation rejects", async () => {
    let rejectFirstBridge: (err: Error) => void = () => {};
    let bridgeCallCount = 0;
    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-reconnect",
          name: "客厅摄像机",
          model: "isa.camera.hlc7",
          localip: "192.168.1.50",
        },
      ],
      bridgeResult: () => {
        bridgeCallCount += 1;
        if (bridgeCallCount === 1) {
          return new Promise<string>((_resolve, reject) => {
            rejectFirstBridge = reject;
          });
        }
        return "cam_h264_camreconnect|cam_mjpeg_camreconnect";
      },
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-reconnect"]') !== null);
    await click('[data-body-device="cam-reconnect"]');
    await waitFor(() => ctx.bridgeCalls.length === 1);

    await click("#btn-reload-camera-live");
    assert.equal(ctx.bridgeCalls.length, 1);
    rejectFirstBridge(new Error("late bridge failure"));
    await waitFor(() => ctx.bridgeCalls.length === 2 && !ctx.app.cameraLive.liveCameraLoading);
    const stopsAfterSecondConnect = ctx.p2pStopsByDid.get("cam-reconnect") ?? 0;
    await setImmediate();
    await setImmediate();

    assert.equal(ctx.p2pStopsByDid.get("cam-reconnect") ?? 0, stopsAfterSecondConnect);
    assert.equal(ctx.app.cameraLive.liveCameraError, null);
    assert.equal(ctx.app.cameraLive.liveCameraStreamURL, "cam_mjpeg_camreconnect");
  });

  it("retains parentDid on MiDeviceRecord and reuses cached topology without re-fetching device_list or homeroom", async () => {
    const parsed = MiCloudClient.parseDeviceRecord({
      did: "cam-child",
      name: "子摄像机",
      model: "mxiang.camera.mwc11",
      isOnline: true,
      parent_id: "hub-parent",
      localip: "",
    });
    assert.equal(parsed?.parentDid, "hub-parent");

    const ctx = await mountCloudCameraApp({
      devices: [
        {
          did: "cam-cached",
          name: "室外电池机",
          model: "mxiang.camera.mwc11",
          parent_id: "hub-cached",
          localip: "",
        },
        {
          did: "hub-cached",
          name: "室内网关",
          model: "mxiang.camera.mwc10",
          localip: "192.168.1.92",
        },
      ],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-cached"]') !== null);
    const deviceListBefore = ctx.getDeviceListCalls();
    const homeRoomBefore = ctx.getHomeRoomCalls();

    await click('[data-body-device="cam-cached"]');
    await waitFor(() => ctx.bridgeCalls.length === 1);

    assert.equal(ctx.bridgeCalls[0]?.["did"], "hub-cached");
    assert.equal(ctx.bridgeCalls[0]?.["localIp"], "192.168.1.92");
    assert.equal(ctx.bridgeCalls[0]?.["subdid"], "cam-cached");
    assert.equal(ctx.getDeviceListCalls(), deviceListBefore);
    assert.equal(ctx.getHomeRoomCalls(), homeRoomBefore);
  });

  it("stops the locally registered bridge after a sign-out retarget renames the live-view card (#254)", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [{ did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", roomName: "客厅" }],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    const ctrl = ctx.app.cameraLive;
    ctrl.activeLiveCameraId = "cam-a";

    const bridged = await ctrl.bridgeHlsStreamToMjpeg("cam-a", "http://192.168.50.10:8080/live/cam.m3u8");
    assert.equal(bridged, true);
    assert.equal(ctx.hlsBridgeCalls[0]?.["did"], "cam-a");

    // The restored HA card keeps the same physical camera under another id.
    const source = ctx.app.devices.find((d) => d.id === "cam-a")!;
    ctx.app.devices = [...ctx.app.devices, { ...source, id: "ha-cam-a" }];
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);
    assert.equal(ctrl.activeLiveCameraId, "ha-cam-a");

    ctrl.stopLiveTransport();
    assert.deepEqual(
      ctx.stopBridgeCalls.at(-1),
      { did: "cam-a" },
      "teardown must stop the stream registered under the old card id, not the new one",
    );
  });

  it("restarts a still-connecting live view when a sign-out retarget renames its card (#254)", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [{ did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", roomName: "客厅" }],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    const ctrl = ctx.app.cameraLive;
    const source = ctx.app.devices.find((d) => d.id === "cam-a")!;
    ctx.app.devices = [...ctx.app.devices, { ...source, id: "ha-cam-a" }];

    let reconnects = 0;
    ctrl.reconnectCameraLiveView = () => {
      reconnects += 1;
    };

    ctrl.activeLiveCameraId = "cam-a";
    ctrl.liveCameraLoading = true;
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);
    assert.equal(reconnects, 1, "a start that was still negotiating must be restarted under the new id");

    // A stream whose MJPEG pump is already running (even before the first JPEG attaches img) keeps playing.
    const pumpingAbort = new AbortController();
    ctrl.activeLiveCameraId = "cam-a";
    ctrl.liveCameraLoading = true;
    ctrl.liveCameraImgEl = null;
    ctrl.liveCameraAbort = pumpingAbort;
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);
    assert.equal(reconnects, 1, "an already-pumping MJPEG stream must not be restarted before its first frame");
    assert.equal(pumpingAbort.signal.aborted, false);
    ctrl.liveCameraAbort = null;

    // A stream that is already attached keeps playing; retargeting only renames its card.
    ctrl.activeLiveCameraId = "cam-a";
    ctrl.liveCameraLoading = true;
    ctrl.liveCameraImgEl = document.createElement("img");
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);
    assert.equal(reconnects, 1);
  });

  it("preserves an in-flight custom stream URL when a sign-out retarget restarts pre-transport negotiation (#254)", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [{ did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", roomName: "客厅" }],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    const ctrl = ctx.app.cameraLive;
    const source = ctx.app.devices.find((d) => d.id === "cam-a")!;
    ctx.app.devices = [...ctx.app.devices, { ...source, id: "ha-cam-a" }];

    let releaseEndpointGate: (() => void) | null = null;
    ctx.app.endpointSubmission = new Promise<void>((resolve) => {
      releaseEndpointGate = resolve;
    });
    ctx.app.settings.connectionMode = "homeAssistant";

    const customHls = "http://192.168.50.10:8080/live/custom-cam.m3u8";
    ctrl.activeLiveCameraId = "cam-a";
    void ctrl.playCustomCameraUrl("cam-a", customHls);
    await waitFor(() => ctrl.liveCameraLoading && ctrl.liveCameraStreamURL === customHls);

    // Retarget while HLS negotiation is still waiting pre-transport: the restart under the restored HA
    // card id must keep the in-flight custom URL instead of dropping it (#254).
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);
    assert.equal(ctrl.activeLiveCameraId, "ha-cam-a");
    assert.equal(ctrl.liveCameraStreamURL, customHls);

    releaseEndpointGate!();
    await waitFor(() => ctx.hlsBridgeCalls.some((call) => call["did"] === "ha-cam-a"));
    const restartedCall = ctx.hlsBridgeCalls.find((call) => call["did"] === "ha-cam-a");
    assert.equal(restartedCall?.["hlsUrl"], customHls);
  });

  it("carries saved per-camera live state over when a sign-out retarget renames the card (#254)", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [{ did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", roomName: "客厅" }],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    const ctrl = ctx.app.cameraLive;
    const customUrl = "http://192.168.50.10:1984/snapshot.jpg?src=cam";
    ctrl.activeLiveCameraId = "cam-a";
    ctrl.rotateActiveCamera();
    ctrl.setCameraLensChannel("cam-a", 1);
    ctrl.setCameraStreamQuality("cam-a", "hd");
    ctrl.cameraLocalIPs = { ...ctrl.cameraLocalIPs, "cam-a": "192.168.50.88" };
    ctrl.cameraStreamURLs = { ...ctrl.cameraStreamURLs, "cam-a": customUrl };
    ctx.app.settings.cameraStreamURLs = { ...ctrl.cameraStreamURLs };
    assert.equal(ctrl.cameraRotation("cam-a"), 90);

    const source = ctx.app.devices.find((d) => d.id === "cam-a")!;
    ctx.app.devices = [...ctx.app.devices, { ...source, id: "ha-cam-a" }];
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);

    assert.equal(ctrl.cameraRotation("ha-cam-a"), 90, "a saved turn must survive the rename");
    assert.equal(ctrl.cameraChannels["ha-cam-a"], 1, "the selected lens must survive the rename");
    assert.equal(ctrl.cameraLocalIPs["ha-cam-a"], "192.168.50.88");
    assert.equal(ctrl.cameraStreamQualities["ha-cam-a"], "hd");
    assert.equal(ctrl.cameraStreamURLs["ha-cam-a"], customUrl);

    // Copied rather than moved: a later dual-source re-enable still finds them under the canonical id.
    assert.equal(ctrl.cameraRotation("cam-a"), 90);
    assert.equal(ctrl.cameraStreamURLs["cam-a"], customUrl);

    // Both stores are persisted, so a reload after sign-out keeps them on the restored card.
    const savedRotations = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_ROTATIONS_STORAGE_KEY) ?? "{}",
    ) as Record<string, unknown>;
    assert.equal(savedRotations["ha-cam-a"], 90);
    const savedChannels = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_CHANNELS_STORAGE_KEY) ?? "{}",
    ) as Record<string, unknown>;
    assert.equal(savedChannels["ha-cam-a"], 1);
    const savedIPs = JSON.parse(
      localStorage.getItem(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY) ?? "{}",
    ) as Record<string, unknown>;
    assert.equal(savedIPs["ha-cam-a"], "192.168.50.88");
    const savedSettings = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as {
      cameraStreamURLs?: Record<string, string>;
      cameraStreamQualities?: Record<string, string>;
    };
    assert.equal(savedSettings.cameraStreamURLs?.["ha-cam-a"], customUrl);
    assert.equal(savedSettings.cameraStreamQualities?.["ha-cam-a"], "hd");
  });

  it("keeps the custom stream URL reachable by Reload after a sign-out retarget (#254)", async () => {
    const ctx = await mountCloudCameraApp({
      devices: [{ did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", roomName: "客厅" }],
    });
    await waitFor(() => document.querySelector('[data-body-device="cam-a"]') !== null);
    const ctrl = ctx.app.cameraLive;
    const customUrl = "http://192.168.50.10:1984/snapshot.jpg?src=cam";
    ctrl.activeLiveCameraId = "cam-a";
    ctrl.cameraStreamURLs = { ...ctrl.cameraStreamURLs, "cam-a": customUrl };
    ctx.app.settings.cameraStreamURLs = { ...ctrl.cameraStreamURLs };

    const source = ctx.app.devices.find((d) => d.id === "cam-a")!;
    ctx.app.devices = [...ctx.app.devices, { ...source, id: "ha-cam-a" }];
    assert.equal(ctrl.retargetActiveLiveCamera("ha-cam-a"), true);

    ctrl.reconnectCameraLiveView();
    assert.equal(
      ctrl.liveCameraStreamURL,
      customUrl,
      "Reload must keep using the custom URL saved on the paired card",
    );
  });

});
