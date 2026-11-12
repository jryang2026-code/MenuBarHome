import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { CameraLiveController } from "../src/ui/cameraLive.js";

let dom: Window;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing control ${selector}`);
  return found;
}

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
  frame?: (src: string) => Promise<string>;
  bridgeResult?: (args: Record<string, unknown>) => string | Promise<string>;
}) {
  const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
  const spec = makeCameraMiotSpec();
  const bridgeCalls: Array<Record<string, unknown>> = [];
  const stopBridgeCalls: Array<Record<string, unknown>> = [];
  const vendorDids: string[] = [];
  const frameSrcs: string[] = [];
  const p2pStartsByDid = new Map<string, number>();
  const p2pStopsByDid = new Map<string, number>();

  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (name === "start_xiaomi_camera_bridge") {
      bridgeCalls.push(args);
      if (options.bridgeResult) return options.bridgeResult(args);
      const did = String(args["did"] ?? "").replace(/[^A-Za-z0-9_]/g, "");
      const sub = typeof args["subdid"] === "string" ? args["subdid"].replace(/[^A-Za-z0-9_]/g, "") : "";
      const key = sub ? `${did}_${sub}` : did;
      const ch = typeof args["channel"] === "number" && args["channel"] > 0 ? `_c${args["channel"]}` : "";
      return `cam_h264_${key}${ch}|cam_mjpeg_${key}${ch}`;
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
    if (url.includes("device_list")) {
      result = {
        list: options.devices.map((d) => ({
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
      const roomMap = new Map<string, string[]>();
      for (const d of options.devices) {
        const rm = d.roomName ?? "客厅";
        const arr = roomMap.get(rm) ?? [];
        arr.push(d.did);
        roomMap.set(rm, arr);
      }
      result = {
        homelist: [
          {
            id: "1",
            name: "家",
            dids: [],
            roomlist: Array.from(roomMap.entries()).map(([name, dids], idx) => ({
              id: String(idx + 10),
              name,
              dids,
            })),
          },
        ],
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
    stopBridgeCalls,
    vendorDids,
    frameSrcs,
    p2pStartsByDid,
    p2pStopsByDid,
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
    await waitFor(() => ctx.bridgeCalls.length === 3);

    ctx.frameSrcs.length = 0;
    releaseChannel1Bridge!("cam_h264_camrace_c1|cam_mjpeg_camrace_c1");
    await new Promise((resolve) => setTimeout(resolve, 60));

    assert.equal(ctx.frameSrcs.includes("cam_mjpeg_camrace_c1"), false);
    assert.equal(ctx.app.cameraLive.liveCameraStreamURL, "cam_mjpeg_camrace");
  });
});
