import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

const SECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SERVICE_TOKEN = "tok-live-session";
const CAMERA_ID = "cam-live";
const HLS_URL = "https://example.com/live/index.m3u8";
const STREAM_SIID = 20;
const START_HLS_AIID = 3;
const STOP_STREAM_AIID = 4;

const CAMERA_SPEC = {
  type: "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-81ac1:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-81ac1:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:on:00000006:chuangmi-81ac1:1",
          format: "bool",
          access: ["read", "write"],
        },
      ],
      actions: [],
    },
    {
      iid: STREAM_SIID,
      type: "urn:miot-spec-v2:service:camera-stream-for-google-home:00007863:chuangmi-81ac1:1",
      properties: [],
      actions: [
        {
          iid: START_HLS_AIID,
          type: "urn:miot-spec-v2:action:start-hls-stream:00002849:chuangmi-81ac1:1",
          in: [],
          out: [],
        },
        {
          iid: STOP_STREAM_AIID,
          type: "urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-81ac1:1",
          in: [],
          out: [],
        },
      ],
    },
  ],
};

interface CloudStop {
  readonly token: string;
  readonly siid: number;
  readonly aiid: number;
  readonly afterHlsReturned: boolean;
}

interface BridgeStop {
  readonly did: string;
  readonly afterBridgeReturned: boolean;
}

interface CameraHarness {
  readonly app: MenuMijiaWindowsApp;
  readonly cloudStops: CloudStop[];
  readonly bridgeStops: BridgeStop[];
  hlsReturned: boolean;
  bridgeReturned: boolean;
  releaseHls: () => void;
  releaseBridge: (streamName: string) => void;
  releaseStop: () => void;
  whenHlsRequested: Promise<void>;
  whenBridgeRequested: Promise<void>;
  whenStopRequested: Promise<void>;
}

let dom: Window;

function forceTranscodedHls(): void {
  window.HTMLVideoElement.prototype.canPlayType = () => "";
}

async function until(predicate: () => boolean, label: string): Promise<void> {
  for (let step = 0; step < 80; step += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(label);
}

function serviceTokenFrom(args: Record<string, unknown>): string {
  const headers = args["headers"];
  if (!headers || typeof headers !== "object") return "";
  const record = headers as Record<string, unknown>;
  const cookie = String(record["Cookie"] ?? record["cookie"] ?? "");
  return /(?:^|;\s*)serviceToken=([^;]*)/.exec(cookie)?.[1] ?? "";
}

function actionCall(args: Record<string, unknown>): { siid: number; aiid: number } | null {
  const fields = new URLSearchParams(String(args["body"] ?? ""));
  const nonce = fields.get("_nonce") ?? "";
  const encrypted = fields.get("data") ?? "";
  if (!nonce || !encrypted) return null;
  const payload = JSON.parse(
    MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(SECURITY, nonce)),
  ) as { params?: { siid?: number; aiid?: number } };
  const siid = payload.params?.siid;
  const aiid = payload.params?.aiid;
  if (typeof siid !== "number" || typeof aiid !== "number") return null;
  return { siid, aiid };
}

async function mountCamera(options: {
  readonly holdHls: boolean;
  readonly holdBridge: boolean;
  readonly holdStop?: boolean;
}): Promise<CameraHarness> {
  const cloudStops: CloudStop[] = [];
  const bridgeStops: BridgeStop[] = [];
  let hlsReturned = false;
  let bridgeReturned = false;
  let deviceListCalls = 0;
  let releaseHls = (): void => {};
  let releaseBridge = (_streamName: string): void => {};
  const hlsGate = new Promise<void>((resolve) => {
    releaseHls = resolve;
  });
  const bridgeGate = new Promise<string>((resolve) => {
    releaseBridge = resolve;
  });
  let markHlsRequested = (): void => {};
  let markBridgeRequested = (): void => {};
  let markStopRequested = (): void => {};
  let releaseStop = (): void => {};
  const whenHlsRequested = new Promise<void>((resolve) => {
    markHlsRequested = resolve;
  });
  const whenBridgeRequested = new Promise<void>((resolve) => {
    markBridgeRequested = resolve;
  });
  const whenStopRequested = new Promise<void>((resolve) => {
    markStopRequested = resolve;
  });
  const stopGate = new Promise<void>((resolve) => {
    releaseStop = resolve;
  });

  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (name === "go2rtc_endpoint") return { origin: "http://127.0.0.1:43123" };
    if (name === "go2rtc_jpeg_frame") return "aGVsbG8";
    if (name === "bridge_hls_camera_stream") {
      markBridgeRequested();
      const streamName = options.holdBridge ? await bridgeGate : `cam_mjpeg_${CAMERA_ID.replace(/[^A-Za-z0-9_]/g, "")}`;
      bridgeReturned = true;
      return streamName;
    }
    if (name === "stop_xiaomi_camera_bridge") {
      bridgeStops.push({
        did: String(args["did"] ?? ""),
        afterBridgeReturned: bridgeReturned,
      });
      return undefined;
    }
    if (name === "start_xiaomi_camera_bridge") return "cam_h264_camlive|cam_mjpeg_camlive";
    if (name !== "native_http") return undefined;

    const url = String(args["url"] ?? "");
    if (url.includes("/instance?")) {
      return { status: 200, headers: {}, body: JSON.stringify(CAMERA_SPEC) };
    }
    if (url.includes("/instances?")) {
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({ instances: [{ model: "chuangmi.camera.81ac1", type: CAMERA_SPEC.type }] }),
      };
    }
    if (url.includes("device_list")) {
      deviceListCalls += 1;
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({
          code: 0,
          result: {
            list: [{
              did: CAMERA_ID,
              name: "客厅摄像机",
              model: "chuangmi.camera.81ac1",
              isOnline: true,
              localip: "192.0.2.40",
              spec_type: CAMERA_SPEC.type,
            }],
            has_more: false,
          },
        }),
      };
    }
    if (url.includes("homeroom/")) {
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({
          code: 0,
          result: { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "客厅", dids: [CAMERA_ID] }] }] },
        }),
      };
    }
    if (url.includes("miotspec/prop/")) {
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({
          code: 0,
          result: [{ did: CAMERA_ID, siid: 2, piid: 1, code: 0, value: true }],
        }),
      };
    }
    if (!url.includes("miotspec/action")) {
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: {} }) };
    }

    const call = actionCall(args);
    if (call?.siid === STREAM_SIID && call.aiid === START_HLS_AIID) {
      markHlsRequested();
      if (options.holdHls) await hlsGate;
      hlsReturned = true;
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({ code: 0, result: { out: [HLS_URL] } }),
      };
    }
    if (call?.siid === STREAM_SIID && call.aiid === STOP_STREAM_AIID) {
      markStopRequested();
      if (options.holdStop) await stopGate;
      cloudStops.push({
        token: serviceTokenFrom(args),
        siid: call.siid,
        aiid: call.aiid,
        afterHlsReturned: hlsReturned,
      });
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: { code: 0, out: [] } }) };
    }
    return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: { code: 0, out: [] } }) };
  };

  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miSession: {
        userId: "100",
        cUserId: "c100",
        ssecurity: SECURITY,
        serviceToken: SERVICE_TOKEN,
        passToken: "",
        region: "cn",
      },
      cachedModelTypes: { "chuangmi.camera.81ac1": CAMERA_SPEC.type },
      cachedXiaomiDevices: [{
        id: CAMERA_ID,
        name: "客厅摄像机",
        roomId: "room_living",
        roomName: "客厅",
        model: "chuangmi.camera.81ac1",
        isOnline: true,
        kind: {
          kind: "camera",
          entityId: `miot:${CAMERA_ID}:2`,
          isOn: true,
          nightShot: "Auto",
          availableNightShots: ["Off", "On", "Auto"],
          motionDetectionEntityId: null,
          isMotionDetectionOn: null,
          streamEntityId: null,
          powerWritable: true,
        },
      }],
    }),
  );

  const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  app.assistantKeysByPreset = { openrouter_jev: "sk-keep-provider" };
  app.settings.openRouterApiKey = "sk-keep-provider";
  app.cameraLive.cameraSameSessionCooldownMs = 0;
  app.cameraLive.cameraFrameRetryMs = 0;
  await until(() => deviceListCalls > 0 && !app.isSyncingCloud, "cloud refresh did not finish");
  const harness: CameraHarness = {
    app,
    cloudStops,
    bridgeStops,
    get hlsReturned() {
      return hlsReturned;
    },
    set hlsReturned(value: boolean) {
      hlsReturned = value;
    },
    get bridgeReturned() {
      return bridgeReturned;
    },
    set bridgeReturned(value: boolean) {
      bridgeReturned = value;
    },
    releaseHls,
    releaseBridge,
    releaseStop,
    whenHlsRequested,
    whenBridgeRequested,
    whenStopRequested,
  };
  return harness;
}

async function settleReleases(app: MenuMijiaWindowsApp): Promise<void> {
  await Promise.all([...app.cameraLive.pendingCameraReleases.values()]);
  for (let step = 0; step < 12; step += 1) await setImmediate();
}

beforeEach(() => {
  dom = mountTestWindow();
  forceTranscodedHls();
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("camera streams stop after Xiaomi logout", () => {
  it("stops a cloud HLS stream that starts after logout, using the session captured when it started", async () => {
    const live = await mountCamera({ holdHls: true, holdBridge: false });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;

    live.app.signOutXiaomiAccount();
    await settleReleases(live.app);
    assert.equal(live.app.settings.miSession, null);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
    live.releaseHls();
    await settleReleases(live.app);

    const lateStops = live.cloudStops.filter((stop) => stop.afterHlsReturned);
    assert.ok(
      lateStops.length > 0,
      "start-hls-stream completed after logout and no stop-stream followed",
    );
    assert.equal(lateStops.at(-1)?.token, SERVICE_TOKEN);
    assert.equal(lateStops.at(-1)?.siid, STREAM_SIID);
    assert.equal(lateStops.at(-1)?.aiid, STOP_STREAM_AIID);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
    assert.equal(live.app.assistantKeysByPreset["openrouter_jev"], "sk-keep-provider");
    assert.equal(live.app.settings.openRouterApiKey, "sk-keep-provider");
  });

  it("stops the local HLS bridge that finishes registering after logout", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: true });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenBridgeRequested;

    live.app.signOutXiaomiAccount();
    await settleReleases(live.app);
    assert.equal(live.app.settings.miSession, null);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
    live.releaseBridge("cam_mjpeg_camlive");
    await settleReleases(live.app);

    const lateStops = live.bridgeStops.filter((stop) => stop.afterBridgeReturned);
    assert.ok(
      lateStops.length > 0,
      "bridge_hls_camera_stream finished after logout and the local stream was left running",
    );
    assert.equal(lateStops.at(-1)?.did, CAMERA_ID);
    assert.equal(live.app.assistantKeysByPreset["openrouter_jev"], "sk-keep-provider");
    assert.equal(live.app.settings.openRouterApiKey, "sk-keep-provider");
  });

  it("stops an open cloud stream when logout has already cleared the session store", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: false });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;
    await live.whenBridgeRequested;
    await until(() => live.hlsReturned && live.bridgeReturned, "camera stream did not start");
    await settleReleases(live.app);
    const stopsBeforeClear = live.cloudStops.length;

    live.app.settings.miSession = null;
    live.app.miAccountsOverride = null;
    live.app.multiAccountState = null;
    live.app.cameraLive.closeCameraLiveView();
    await settleReleases(live.app);

    assert.ok(
      live.cloudStops.length > stopsBeforeClear,
      "release after the session store was cleared did not send stop-stream",
    );
    assert.equal(live.cloudStops.at(-1)?.token, SERVICE_TOKEN);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
    assert.equal(live.app.assistantKeysByPreset["openrouter_jev"], "sk-keep-provider");
  });

  it("drops the retained cloud session once release finishes", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: false });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;
    await live.whenBridgeRequested;
    await until(() => live.hlsReturned && live.bridgeReturned, "camera stream did not start");
    await settleReleases(live.app);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, SERVICE_TOKEN);

    live.app.cameraLive.closeCameraLiveView();
    await settleReleases(live.app);

    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
  });

  it("stops with the re-login session while the previous stream session is still retained", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: false });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;
    await live.whenBridgeRequested;
    await until(() => live.hlsReturned && live.bridgeReturned, "camera stream did not start");
    await settleReleases(live.app);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, SERVICE_TOKEN);

    const nextToken = "tok-relogin-session";
    live.app.settings.miSession = null;
    live.app.miAccountsOverride = [];
    live.app.multiAccountState = null;
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, SERVICE_TOKEN);
    live.app.settings.miSession = {
      userId: "200",
      cUserId: "c200",
      ssecurity: SECURITY,
      serviceToken: nextToken,
      passToken: "",
      region: "cn",
    };
    const stopsBefore = live.cloudStops.length;
    live.app.cameraLive.closeCameraLiveView();
    await settleReleases(live.app);

    assert.ok(
      live.cloudStops.length > stopsBefore,
      "release after re-login did not send stop-stream",
    );
    assert.equal(live.cloudStops.at(-1)?.token, nextToken);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
  });

  it("keeps a newer cloud session when an older release finishes", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: false, holdStop: true });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;
    await live.whenBridgeRequested;
    await until(() => live.hlsReturned && live.bridgeReturned, "camera stream did not start");
    await settleReleases(live.app);

    live.app.cameraLive.closeCameraLiveView();
    await live.whenStopRequested;
    const nextToken = "tok-replacement-session";
    live.app.settings.miSession = {
      userId: "200",
      cUserId: "c200",
      ssecurity: SECURITY,
      serviceToken: nextToken,
      passToken: "",
      region: "cn",
    };
    live.app.miAccountsOverride = [];
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, nextToken);

    live.releaseStop();
    await settleReleases(live.app);
    await until(
      () => live.app.cameraLive.liveCameraStreamURL !== null && !live.app.cameraLive.liveCameraLoading,
      "replacement stream did not start",
    );
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, nextToken);
  });
});
