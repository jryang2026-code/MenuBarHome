import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import {
  isPortraitDoorbellCamera,
  sanitizePinnedSwitchIds,
  shouldAutoOpenCameraPipOnEvent,
  type CameraPipSnapshot,
} from "../src/core/cameraPip.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { CameraPipWindowApp } from "../src/ui/cameraPipWindow.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

let dom: Window;

function makeCamera(overrides: Partial<SmartDevice> = {}): SmartDevice {
  return {
    id: "cam.1",
    name: "Living Room Camera",
    roomId: "room.living",
    roomName: "Living Room",
    model: "isa.camera.hlc7",
    isOnline: true,
    kind: {
      kind: "camera",
      entityId: "camera.living",
      isOn: true,
      nightShot: "auto",
      availableNightShots: ["auto", "on", "off"],
      motionDetectionEntityId: "switch.living_motion",
      isMotionDetectionOn: true,
      streamEntityId: null,
    },
    ...overrides,
  };
}

describe("Windows independent camera PiP window & 3:4 portrait doorbell (P1-2 PR A)", () => {
  beforeEach(() => {
    dom = mountTestWindow();
  });

  afterEach(() => {
    closeTestWindow(dom);
  });

  it("identifies doorbell/cateye models and quarter-turned cameras as 3:4 portrait", () => {
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "isa.camera.hlc7" }), 0), false);
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "isa.camera.hlc7" }), 90), true);
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "isa.camera.hlc7" }), 270), true);
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "madv.cateye.mjj2" }), 0), true);
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "xiaomi.doorbell.3s" }), 0), true);
    assert.equal(isPortraitDoorbellCamera(makeCamera({ model: "lumi.camera.g400" }), 0), true);
    assert.equal(
      isPortraitDoorbellCamera(makeCamera({ model: "generic.cam", name: "入户门铃" }), 0),
      true,
    );
  });

  it("opens a detached PiP window when supported, keeps main popover unpinned, and stops stream on PiP close", async () => {
    const calls: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    (globalThis.window as unknown as { __TAURI_INTERNALS__: { invoke: Function } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        calls.push({ cmd, args });
        if (cmd === "open_camera_pip_window") return true;
        return null;
      },
    };

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    const doorbell = makeCamera({
      id: "cam.doorbell",
      name: "入户门铃",
      model: "xiaomi.doorbell.3s",
    });
    app.devices = [doorbell];

    app.cameraLive.openCameraLiveView(doorbell.id);
    await setImmediate();

    assert.equal(app.cameraLive.isDetachedPipActive, true);
    assert.equal(root.querySelector(".cc-camera-live-sheet"), null);

    const openCall = calls.find((c) => c.cmd === "open_camera_pip_window");
    assert.ok(openCall, "open_camera_pip_window should be invoked");
    assert.equal(openCall.args?.cameraId, "cam.doorbell");
    assert.equal(openCall.args?.isPortrait, true);

    const syncCall = calls.find((c) => c.cmd === "sync_camera_pip_state");
    assert.ok(syncCall, "sync_camera_pip_state should push state to PiP window");
    const parsed = JSON.parse(String(syncCall.args?.payloadJson)) as CameraPipSnapshot;
    assert.equal(parsed.isPortrait, true);
    assert.equal(parsed.cameraId, "cam.doorbell");

    // Closing the PiP window notifies main and cleanly closes the camera stream.
    window.dispatchEvent(new window.CustomEvent("menumijia:camera-pip-closed"));
    await setImmediate();
    assert.equal(app.cameraLive.activeLiveCameraId, null);
    assert.equal(app.cameraLive.isDetachedPipActive, false);
    assert.ok(
      calls.some((c) => c.cmd === "stop_xiaomi_camera_bridge"),
      "closing PiP must stop the camera bridge",
    );

    app.dispose();
  });

  it("CameraPipWindowApp renders 3:4 portrait layout, pumps MJPEG frames, drags header, and dispatches close", async () => {
    const calls: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    const snapshot: CameraPipSnapshot = {
      cameraId: "cam.doorbell",
      name: "Front Doorbell",
      roomName: "Entry",
      isPortrait: true,
      mediaKind: "frames",
      mjpegSrc: "cam_mjpeg_doorbell",
      streamURL: "cam_mjpeg_doorbell",
      isOn: true,
      powerWritable: true,
      isNight: false,
      nightShot: "auto",
      availableNightShots: ["auto", "on"],
      motionDetectionEntityId: "switch.motion",
      isMotionDetectionOn: true,
      rotation: 0,
      muted: true,
      error: null,
      showingURLInput: false,
      customURL: "",
      showManualIpFallback: false,
      savedManualIp: "",
      draftManualIp: "",
      manualIpError: null,
      showQualityBar: false,
      quality: "hd",
      lenses: [],
      activeLensChannel: 0,
      playableCameras: [],
      autoCloseRemainingSeconds: 18,
      autoOpenOnEvent: true,
      pinnedSwitches: [{ id: "light.entry", name: "玄关灯", isOn: false, isOnline: true }],
      availablePinSwitches: [{ id: "light.entry", name: "玄关灯", isOn: false, isOnline: true }],
    };
    let frameCount = 0;
    (globalThis.window as unknown as { __TAURI_INTERNALS__: { invoke: Function } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        calls.push({ cmd, args });
        if (cmd === "get_camera_pip_state") return JSON.stringify(snapshot);
        if (cmd === "go2rtc_jpeg_frame") {
          frameCount += 1;
          return frameCount === 1 ? "AA==" : "AA==";
        }
        return null;
      },
    };

    const root = document.getElementById("app")!;
    const pipApp = new CameraPipWindowApp(root);
    await setImmediate();
    await new Promise((r) => setTimeout(r, 20));

    assert.ok(document.documentElement.classList.contains("is-camera-pip-window"));
    assert.ok(root.querySelector(".cc-camera-stage.is-portrait"), "doorbell stage should have is-portrait");
    const img = root.querySelector<HTMLImageElement>("#cc-camera-live-img");
    assert.ok(img?.src.startsWith("data:image/jpeg;base64,"), "PiP should pump go2rtc_jpeg_frame");

    const dragHandle = root.querySelector<HTMLElement>(".cc-pip-drag-handle")!;
    dragHandle.dispatchEvent(new window.MouseEvent("mousedown", { button: 0, bubbles: true }));
    assert.ok(calls.some((c) => c.cmd === "start_camera_pip_drag"));

    root.querySelector<HTMLButtonElement>("#btn-close-camera-live")!.click();
    const closeAction = calls.find(
      (c) => c.cmd === "camera_pip_action" && String(c.args?.actionJson).includes('"type":"close"'),
    );
    assert.ok(closeAction, "close button should send close action to main");

    // Visible countdown badge & pinned switch button render and dispatch actions.
    assert.ok(root.querySelector("#btn-pip-cancel-countdown")?.textContent?.includes("18s"));
    root.querySelector<HTMLButtonElement>("[data-pip-pinned-switch='light.entry']")!.click();
    assert.ok(
      calls.some(
        (c) =>
          c.cmd === "camera_pip_action" &&
          String(c.args?.actionJson).includes('"type":"togglePinnedSwitch"'),
      ),
      "clicking pinned switch should dispatch togglePinnedSwitch action",
    );

    pipApp.dispose();
  });

  it("enforces OFF-by-default per-camera auto-open, Focus/DND policy (#475), non-focus-stealing countdown, and max-2 pinned switches", async () => {
    // Pure policy checks: OFF by default, doorbell never suppressed by Focus, motion suppressed by Focus.
    assert.equal(
      shouldAutoOpenCameraPipOnEvent({
        eventKind: "doorbell",
        cameraOptIn: false,
        isLocked: false,
        isFocusActive: false,
      }),
      false,
    );
    assert.equal(
      shouldAutoOpenCameraPipOnEvent({
        eventKind: "doorbell",
        cameraOptIn: true,
        isLocked: false,
        isFocusActive: true,
      }),
      true,
    );
    assert.equal(
      shouldAutoOpenCameraPipOnEvent({
        eventKind: "motion",
        cameraOptIn: true,
        isLocked: false,
        isFocusActive: true,
      }),
      false,
    );
    assert.equal(
      shouldAutoOpenCameraPipOnEvent({
        eventKind: "doorbell",
        cameraOptIn: true,
        isLocked: true,
        isFocusActive: false,
      }),
      false,
    );
    assert.deepEqual(sanitizePinnedSwitchIds(["a", "b", "c", "a"]), ["a", "b"]);

    const calls: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    (globalThis.window as unknown as { __TAURI_INTERNALS__: { invoke: Function } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        calls.push({ cmd, args });
        if (cmd === "open_camera_pip_window") return true;
        return null;
      },
    };

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    const cam = makeCamera({ id: "cam.entry", name: "入户门铃", model: "xiaomi.doorbell.3s" });
    const light1: SmartDevice = {
      id: "light.entry",
      name: "玄关灯",
      roomId: "room.entry",
      roomName: "玄关",
      model: "yeelink.light.color",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "light.entry",
        isOn: false,
        brightnessPercent: 50,
        colorTempKelvin: null,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    };
    const plug1: SmartDevice = {
      id: "plug.porch",
      name: "门口插座",
      roomId: "room.entry",
      roomName: "玄关",
      model: "cuco.plug.cp1",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "switch.porch",
        isOn: false,
        powerWatts: null,
        childLockEntityId: null,
        isChildLocked: false,
      },
    };
    const light2: SmartDevice = {
      ...light1,
      id: "light.hall",
      name: "过道灯",
    };
    app.devices = [cam, light1, plug1, light2];

    // Default is OFF -> does not auto-open.
    assert.equal(
      app.cameraLive.handleCameraEventForAutoOpen({
        cameraId: cam.id,
        kind: "doorbell",
        isLocked: false,
        isFocusActive: false,
      }),
      false,
    );

    // Opt in per camera -> doorbell auto-opens even in Focus mode, top-right, without stealing focus.
    app.cameraLive.setCameraAutoOpen(cam.id, true);
    assert.equal(
      app.cameraLive.handleCameraEventForAutoOpen({
        cameraId: cam.id,
        kind: "doorbell",
        isLocked: false,
        isFocusActive: true,
        dismissSeconds: 20,
      }),
      true,
    );
    await setImmediate();
    const openCall = calls.find((c) => c.cmd === "open_camera_pip_window");
    assert.equal(openCall?.args?.forceTopRight, true);
    assert.equal(openCall?.args?.stealFocus, false);
    assert.equal(app.cameraLive.autoCloseRemainingSeconds, 20);

    // Manual interaction cancels the auto-close countdown.
    app.cameraLive.handlePipAction({ type: "interact" });
    assert.equal(app.cameraLive.autoCloseRemainingSeconds, null);

    // Pinning 3 switches caps at 2 (FIFO replacement) and routes toggles through app.toggleDevice.
    app.cameraLive.toggleCameraPinnedSwitch(cam.id, light1.id);
    app.cameraLive.toggleCameraPinnedSwitch(cam.id, plug1.id);
    app.cameraLive.toggleCameraPinnedSwitch(cam.id, light2.id);
    assert.deepEqual(
      app.cameraLive.pinnedSwitchesForCamera(cam.id).map((d) => d.id),
      [plug1.id, light2.id],
    );

    const toggled: string[] = [];
    const origToggle = app.toggleDevice.bind(app);
    app.toggleDevice = (dev: SmartDevice) => {
      toggled.push(dev.id);
      return origToggle(dev);
    };
    app.cameraLive.handlePipAction({ type: "togglePinnedSwitch", deviceId: light2.id });
    assert.deepEqual(toggled, [light2.id]);

    app.dispose();
  });
});
