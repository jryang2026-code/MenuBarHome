import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";

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
      properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:chuangmi-81ac1:1", format: "bool", access: ["read", "write"] }],
      actions: [],
    },
    {
      iid: STREAM_SIID,
      type: "urn:miot-spec-v2:service:camera-stream-for-google-home:00007863:chuangmi-81ac1:1",
      properties: [],
      actions: [
        { iid: START_HLS_AIID, type: "urn:miot-spec-v2:action:start-hls-stream:00002849:chuangmi-81ac1:1", in: [], out: [] },
        { iid: STOP_STREAM_AIID, type: "urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-81ac1:1", in: [], out: [] },
      ],
    },
  ],
};

interface CloudStop { readonly token: string; readonly siid: number; readonly aiid: number; readonly afterHlsReturned: boolean; }
interface BridgeStop { readonly did: string; readonly afterBridgeReturned: boolean; }

let dom: Window;

async function until(predicate: () => boolean, label: string): Promise<void> {
  for (let step = 0; step < 80; step += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(label);
}

function serviceTokenFrom(args: Record<string, unknown>): string {
  const headers = (args["headers"] ?? {}) as Record<string, unknown>;
  const cookie = String(headers["Cookie"] ?? headers["cookie"] ?? "");
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
  const { siid, aiid } = payload.params ?? {};
  return typeof siid === "number" && typeof aiid === "number" ? { siid, aiid } : null;
}

async function mountCamera(options: { readonly holdHls: boolean; readonly holdBridge: boolean; readonly holdStop?: boolean }) {
  const cloudStops: CloudStop[] = [];
  const bridgeStops: BridgeStop[] = [];
  let hlsReturned = false, bridgeReturned = false, deviceListCalls = 0;
  let releaseHls = () => {}, releaseBridge = (_s: string) => {}, releaseStop = () => {};
  let markHls = () => {}, markBridge = () => {}, markStop = () => {};
  const hlsGate = new Promise<void>((r) => { releaseHls = r; });
  const bridgeGate = new Promise<string>((r) => { releaseBridge = r; });
  const stopGate = new Promise<void>((r) => { releaseStop = r; });
  const whenHlsRequested = new Promise<void>((r) => { markHls = r; });
  const whenBridgeRequested = new Promise<void>((r) => { markBridge = r; });
  const whenStopRequested = new Promise<void>((r) => { markStop = r; });

  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (name === "go2rtc_endpoint") return { origin: "http://127.0.0.1:43123" };
    if (name === "go2rtc_jpeg_frame") return "aGVsbG8";
    if (name === "bridge_hls_camera_stream") {
      markBridge();
      const streamName = options.holdBridge ? await bridgeGate : `cam_mjpeg_${CAMERA_ID.replace(/[^A-Za-z0-9_]/g, "")}`;
      bridgeReturned = true;
      return streamName;
    }
    if (name === "stop_xiaomi_camera_bridge") {
      bridgeStops.push({ did: String(args["did"] ?? ""), afterBridgeReturned: bridgeReturned });
      return undefined;
    }
    if (name === "start_xiaomi_camera_bridge") return "cam_h264_camlive|cam_mjpeg_camlive";
    if (name !== "native_http") return undefined;

    const url = String(args["url"] ?? "");
    const ok = (body: unknown) => ({ status: 200, headers: {}, body: JSON.stringify(body) });
    if (url.includes("/instance?")) return ok(CAMERA_SPEC);
    if (url.includes("/instances?")) return ok({ instances: [{ model: "chuangmi.camera.81ac1", type: CAMERA_SPEC.type }] });
    if (url.includes("device_list")) {
      deviceListCalls += 1;
      return ok({ code: 0, result: { list: [{ did: CAMERA_ID, name: "客厅摄像机", model: "chuangmi.camera.81ac1", isOnline: true, localip: "192.0.2.40", spec_type: CAMERA_SPEC.type }], has_more: false } });
    }
    if (url.includes("homeroom/")) return ok({ code: 0, result: { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "客厅", dids: [CAMERA_ID] }] }] } });
    if (url.includes("miotspec/prop/")) return ok({ code: 0, result: [{ did: CAMERA_ID, siid: 2, piid: 1, code: 0, value: true }] });
    if (!url.includes("miotspec/action")) return ok({ code: 0, result: {} });

    const call = actionCall(args);
    if (call?.siid === STREAM_SIID && call.aiid === START_HLS_AIID) {
      markHls();
      if (options.holdHls) await hlsGate;
      hlsReturned = true;
      return ok({ code: 0, result: { out: [HLS_URL] } });
    }
    if (call?.siid === STREAM_SIID && call.aiid === STOP_STREAM_AIID) {
      markStop();
      if (options.holdStop) await stopGate;
      cloudStops.push({ token: serviceTokenFrom(args), siid: call.siid, aiid: call.aiid, afterHlsReturned: hlsReturned });
    }
    return ok({ code: 0, result: { code: 0, out: [] } });
  };

  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miSession: { userId: "100", cUserId: "c100", ssecurity: SECURITY, serviceToken: SERVICE_TOKEN, passToken: "", region: "cn" },
      cachedModelTypes: { "chuangmi.camera.81ac1": CAMERA_SPEC.type },
      cachedXiaomiDevices: [{
        id: CAMERA_ID, name: "客厅摄像机", roomId: "room_living", roomName: "客厅", model: "chuangmi.camera.81ac1", isOnline: true,
        kind: { kind: "camera", entityId: `miot:${CAMERA_ID}:2`, isOn: true, nightShot: "Auto", availableNightShots: ["Off", "On", "Auto"], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null, powerWritable: true },
      }],
    }),
  );

  const app = new MenuMijiaWindowsApp(element("#app"));
  app.assistantKeysByPreset = { openrouter_jev: "sk-keep-provider" };
  app.settings.openRouterApiKey = "sk-keep-provider";
  app.cameraLive.cameraSameSessionCooldownMs = 0;
  app.cameraLive.cameraFrameRetryMs = 0;
  await until(() => deviceListCalls > 0 && !app.isSyncingCloud, "cloud refresh did not finish");
  return { app, cloudStops, bridgeStops, get hlsReturned() { return hlsReturned; }, get bridgeReturned() { return bridgeReturned; }, releaseHls, releaseBridge, releaseStop, whenHlsRequested, whenBridgeRequested, whenStopRequested };
}

async function settleReleases(app: MenuMijiaWindowsApp): Promise<void> {
  await Promise.all([...app.cameraLive.pendingCameraReleases.values()]);
  for (let step = 0; step < 12; step += 1) await setImmediate();
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  window.HTMLVideoElement.prototype.canPlayType = () => "";
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
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
    assert.ok(lateStops.length > 0);
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
    assert.ok(lateStops.length > 0);
    assert.equal(lateStops.at(-1)?.did, CAMERA_ID);
    assert.equal(live.app.assistantKeysByPreset["openrouter_jev"], "sk-keep-provider");
    assert.equal(live.app.settings.openRouterApiKey, "sk-keep-provider");
  });

  it("stops an open cloud stream when logout cleared the session store and drops the retained session on release", async () => {
    const live = await mountCamera({ holdHls: false, holdBridge: false });
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    await live.whenHlsRequested;
    await live.whenBridgeRequested;
    await until(() => live.hlsReturned && live.bridgeReturned, "camera stream did not start");
    await settleReleases(live.app);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, SERVICE_TOKEN);
    const stopsBeforeClear = live.cloudStops.length;

    live.app.settings.miSession = null;
    live.app.miAccountsOverride = null;
    live.app.multiAccountState = null;
    live.app.cameraLive.closeCameraLiveView();
    await settleReleases(live.app);

    assert.ok(live.cloudStops.length > stopsBeforeClear);
    assert.equal(live.cloudStops.at(-1)?.token, SERVICE_TOKEN);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID), null);
    assert.equal(live.app.assistantKeysByPreset["openrouter_jev"], "sk-keep-provider");
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
    live.app.settings.miSession = { userId: "200", cUserId: "c200", ssecurity: SECURITY, serviceToken: nextToken, passToken: "", region: "cn" };
    live.app.miAccountsOverride = [];
    live.app.multiAccountState = null;
    const stopsBefore = live.cloudStops.length;
    live.app.cameraLive.closeCameraLiveView();
    await settleReleases(live.app);

    assert.ok(live.cloudStops.length > stopsBefore);
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
    live.app.settings.miSession = { userId: "200", cUserId: "c200", ssecurity: SECURITY, serviceToken: nextToken, passToken: "", region: "cn" };
    live.app.miAccountsOverride = [];
    live.app.cameraLive.openCameraLiveView(CAMERA_ID);
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, nextToken);

    live.releaseStop();
    await settleReleases(live.app);
    await until(() => live.app.cameraLive.liveCameraStreamURL !== null && !live.app.cameraLive.liveCameraLoading, "replacement stream did not start");
    assert.equal(live.app.cameraLive.retainedCloudStreamSession(CAMERA_ID)?.serviceToken, nextToken);
  });
});
