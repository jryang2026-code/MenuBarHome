import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { switchSource } from "../src/ui/sourceSwitch.js";
import {
  classifyProactiveSuggestionSource,
  maybeRefreshProactiveInBackground,
} from "../src/ui/proactive.js";
import {
  UNDO_AVAILABILITY_WINDOW_MS,
  UndoAvailabilityTracker,
  computeUndoAvailability,
} from "../src/ui/undoTracker.js";

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
    if (performance.now() >= deadline) {
      assert.fail("Timed out waiting for expected UI state");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
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

describe("Wave 2 — A11 Persistent 10-Minute Undo Pill", () => {
  let app: MenuMijiaWindowsApp | null = null;

  beforeEach(() => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
      }),
    );
  });

  afterEach(async () => {
    app?.dispose();
    app = null;
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("tracks the 10-minute undo window in UndoAvailabilityTracker and fires expiry cleanly", async () => {
    assert.equal(UNDO_AVAILABILITY_WINDOW_MS, 600_000);
    const tracker = new UndoAvailabilityTracker();
    assert.equal(tracker.isAvailable, false);
    assert.equal(tracker.remainingMs(1_000), 0);

    let expiredCount = 0;
    const baseNow = Date.now();
    tracker.syncAction({ summary: "关闭 客厅主灯", expiresAtMs: baseNow + 40 }, baseNow, () => {
      expiredCount += 1;
    });
    assert.equal(tracker.isAvailable, true);
    assert.equal(tracker.summary, "关闭 客厅主灯");
    assert.equal(tracker.remainingMs(baseNow + 15), 25);

    await waitFor(() => expiredCount === 1, 500);
    assert.equal(tracker.isAvailable, false);
    tracker.dispose();
  });

  it("surfaces #btn-header-undo after transient banner collapse, localizes tooltip, executes undo, and clears on source/home/expiry", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline);
    assert.ok(light && light.kind.kind === "light", "expected an online demo light");
    const initialIsOn = light.kind.isOn;

    await app.executeIntents(
      [{ targetId: light.id, operation: { kind: "power", isOn: !initialIsOn } }],
      "切换客厅灯",
      "测试",
    );
    assert.ok(app.lastUndoAction, "undo action should be recorded with a 10-minute expiry");
    assert.ok(
      app.lastUndoAction.expiresAtMs - Date.now() > 500_000,
      "undo action window should span ~10 minutes",
    );

    assert.ok(document.querySelector("#btn-undo"), "transient banner undo button is visible first");
    assertMissing(document.querySelector("#btn-header-undo"));

    app.undoBannerUntilMs = Date.now() - 1;
    app.replyBanner = null;
    app.render();

    assertMissing(document.querySelector("#btn-undo"));
    const headerPill = element<HTMLButtonElement>("#btn-header-undo");
    assert.ok(headerPill.hasAttribute("data-persistent-undo"));
    assert.match(headerPill.textContent ?? "", /↶\s*撤销/);
    assert.match(headerPill.title, /撤销：.*剩余/);

    setLanguage("zh-Hant");
    app.render();
    assert.match(element("#btn-header-undo").title, /撤銷：.*剩餘/);

    setLanguage("en");
    app.render();
    assert.match(element("#btn-header-undo").textContent ?? "", /↶\s*Undo/);
    assert.match(element("#btn-header-undo").title, /Undo: .*left/);

    setLanguage("zh-Hans");
    app.render();

    await click("#btn-header-undo");
    const restored = app.devices.find((d) => d.id === light.id);
    assert.ok(restored && restored.kind.kind === "light");
    assert.equal(restored.kind.isOn, initialIsOn, "clicking #btn-header-undo restores pre-action state");
    assertMissing(document.querySelector("#btn-header-undo"));

    app.lastUndoAction = {
      summary: "关闭 书房台灯",
      steps: [{ deviceId: light.id, commands: [{ kind: "setLightPower", entityId: light.id, isOn: initialIsOn }] }],
      expiresAtMs: Date.now() + 350,
    };
    app.render();
    app.undoBannerUntilMs = Date.now() - 1;
    app.replyBanner = null;
    app.render();
    assert.ok(document.querySelector("#btn-header-undo"));

    await waitFor(() => document.querySelector("#btn-header-undo") === null, 2500);
    assert.equal(computeUndoAvailability(app).isAvailable, false);

    app.lastUndoAction = {
      summary: "关闭 餐厅灯",
      steps: [{ deviceId: light.id, commands: [{ kind: "setLightPower", entityId: light.id, isOn: initialIsOn }] }],
      expiresAtMs: Date.now() + 300_000,
    };
    app.render();
    app.undoBannerUntilMs = Date.now() - 1;
    app.replyBanner = null;
    app.render();
    assert.ok(document.querySelector("#btn-header-undo"));
    app.selectHome("home-2");
    assert.equal(app.lastUndoAction, null);
    assertMissing(document.querySelector("#btn-header-undo"));

    app.lastUndoAction = {
      summary: "关闭 卧室吸顶灯",
      steps: [{ deviceId: light.id, commands: [{ kind: "setLightPower", entityId: light.id, isOn: initialIsOn }] }],
      expiresAtMs: Date.now() + 300_000,
    };
    app.render();
    app.undoBannerUntilMs = Date.now() - 1;
    app.replyBanner = null;
    app.render();
    assert.ok(document.querySelector("#btn-header-undo"));
    switchSource(app, "test-source-switch");
    app.render();
    assertMissing(document.querySelector("#btn-header-undo"));
  });
});

describe("Wave 2 — A12 Proactive Suggestion Source Icons, Confidence Badges & Layout Weighting", () => {
  let app: MenuMijiaWindowsApp | null = null;

  beforeEach(() => {
    dom = mountTestWindow();
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
      }),
    );
  });

  afterEach(async () => {
    app?.dispose();
    app = null;
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("renders source icons, confidence badges in Top Island notification bar, and drops proactive paint during active gestures (§16)", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline);
    assert.ok(light && light.kind.kind === "light");
    const lightIsOn = light.kind.isOn;
    const climate = app.devices.find((d) => d.kind.kind === "climate" && d.isOnline) ?? light;

    const habitItem = {
      id: "habit:light-1",
      title: "打开客厅主灯",
      confidencePercent: 88,
      intents: [{ targetId: light.id, operation: { kind: "power" as const, isOn: !lightIsOn } }],
    };
    const seqItem = {
      id: "seq:follow-1",
      title: "调暗氛围灯",
      confidencePercent: 76,
      intents: [{ targetId: light.id, operation: { kind: "brightness" as const, percent: 35 } }],
    };
    const envItem = {
      id: "env:cool-1",
      title: "开启制冷",
      confidencePercent: 92,
      intents: [
        {
          targetId: climate.id,
          operation:
            climate.kind.kind === "climate"
              ? ({ kind: "hvacMode" as const, mode: "cool" } as const)
              : ({ kind: "brightness" as const, percent: 60 } as const),
        },
      ],
    };

    assert.equal(classifyProactiveSuggestionSource(app, habitItem).kind, "habit");
    assert.equal(classifyProactiveSuggestionSource(app, seqItem).kind, "sequence");
    assert.equal(classifyProactiveSuggestionSource(app, envItem).kind, "ambient");

    const { proactiveSignature } = await import("../src/ui/proactive.js");
    app.aiProactiveSignature = proactiveSignature(app);
    app.aiProactiveSuggestions = [habitItem, seqItem, envItem];
    app.render();

    assertMissing(document.querySelector(".cc-grok-sidebar"));
    assert.ok(document.querySelector('[data-proactive-bar] [data-grok-source="habit"]'));
    assert.ok(document.querySelector('[data-proactive-bar] [data-grok-source="sequence"]'));
    assert.match(
      document.querySelector('[data-proactive-bar] [data-grok-confidence="88"]')?.textContent ?? "",
      /88%/,
    );

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://127.0.0.1:8123";
    app.settings.haToken = "token";
    app.settings.assistantBaseURL = "http://127.0.0.1:11434/v1";
    app.aiProactiveSignature = null;
    app.pendingCloudRender = false;
    app.pointerIsDown = true;

    let renderCallsDuringGesture = 0;
    const origRender = app.render.bind(app);
    app.render = () => {
      renderCallsDuringGesture += 1;
      origRender();
    };
    (app as unknown as { transport: (req: { body?: string }) => Promise<unknown> }).transport = async () => ({
      status: 200,
      headers: {},
      body: JSON.stringify({ choices: [{ message: { content: "[]" } }] }),
    });

    maybeRefreshProactiveInBackground(app);
    await waitFor(() => app?.isRefreshingProactive === false, 1_000);
    assert.equal(renderCallsDuringGesture, 0, "proactive refresh must drop paint while pointerIsDown");
    assert.equal(app.pendingCloudRender, false, "dropped proactive paint must not queue pendingCloudRender");
  });

  it("boosts layout.pinnedDeviceIds and excludes layout.hiddenDeviceIds across proactive suggestions and background AI context", async () => {
    app = new MenuMijiaWindowsApp(element("#app"));
    const onlineLights = app.devices.filter((d) => d.kind.kind === "light" && d.isOnline);
    assert.ok(onlineLights.length >= 2, "expected at least two online demo lights");
    const firstLight = onlineLights[0]!;
    const pinnedLight = onlineLights[onlineLights.length - 1]!;
    assert.notEqual(firstLight.id, pinnedLight.id);

    app.settings.habitEntries = [];
    app.scenes = [];

    const extLayout = app.layout as typeof app.layout & {
      pinnedDeviceIds?: string[];
      hiddenDeviceIds?: string[];
    };
    extLayout.pinnedDeviceIds = [pinnedLight.id];
    extLayout.hiddenDeviceIds = [];
    app.render();

    const boosted = app.currentProactiveSuggestions();
    assert.ok(boosted.length >= 1);
    assert.equal(
      boosted[0]!.intents[0]?.targetId,
      pinnedLight.id,
      "pinnedDeviceIds promotes the pinned light to the top suggestion",
    );

    const { proactiveSignature } = await import("../src/ui/proactive.js");
    app.aiProactiveSignature = proactiveSignature(app);
    app.aiProactiveSuggestions = [
      {
        id: "habit:hidden-pinned",
        title: "控制已隐藏灯",
        confidencePercent: 95,
        intents: [{ targetId: pinnedLight.id, operation: { kind: "power", isOn: true } }],
      },
    ];
    extLayout.hiddenDeviceIds = [pinnedLight.id];
    app.render();

    const afterHide = app.currentProactiveSuggestions();
    assert.ok(
      afterHide.every((item) => item.intents.every((i) => i.targetId !== pinnedLight.id)),
      "hiddenDeviceIds must never appear in currentProactiveSuggestions",
    );

    let capturedRequestBody = "";
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "http://127.0.0.1:8123";
    app.settings.haToken = "token";
    app.settings.assistantBaseURL = "http://127.0.0.1:11434/v1";
    app.aiProactiveSignature = null;
    (app as unknown as { transport: (req: { body?: string }) => Promise<unknown> }).transport = async (req) => {
      capturedRequestBody = String(req.body ?? "");
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({ choices: [{ message: { content: "[]" } }] }),
      };
    };
    maybeRefreshProactiveInBackground(app);
    await waitFor(() => app?.isRefreshingProactive === false, 1_000);
    assert.ok(capturedRequestBody.length > 0, "background proactive request was sent");
    assert.equal(
      capturedRequestBody.includes(pinnedLight.id),
      false,
      "hiddenDeviceIds must be excluded from background proactive AI context",
    );
  });
});

describe("Wave 2 — A1 Camera Adaptive Frame Pacing (>5fps), Fast Switch, HUD Mute & Escape", () => {
  let app: MenuMijiaWindowsApp | null = null;

  beforeEach(() => {
    dom = mountTestWindow();
  });

  afterEach(async () => {
    app?.dispose();
    app = null;
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("paces visible new MJPEG frames at ~45ms (~20fps), applies IPC backpressure, and throttles to 250-500ms when static or hidden", async (t) => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
      }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));
    const cam = app.cameraLive;

    assert.equal(cam.cameraActiveFrameGapMs, 45);
    assert.equal(
      cam.computeNextFrameGapMs({ hidden: false, isNewFrame: true, unchangedCount: 0, elapsedMs: 10 }),
      35,
      "subtracts 10ms IPC round-trip from 45ms target budget to maintain ~20fps cadence",
    );
    assert.equal(
      cam.computeNextFrameGapMs({ hidden: false, isNewFrame: true, unchangedCount: 0, elapsedMs: 95 }),
      33,
      "applies dynamic backpressure breathing room when single IPC call already took 95ms",
    );
    const idleGap1 = cam.computeNextFrameGapMs({
      hidden: false,
      isNewFrame: false,
      unchangedCount: 1,
      elapsedMs: 5,
    });
    const idleGap6 = cam.computeNextFrameGapMs({
      hidden: false,
      isNewFrame: false,
      unchangedCount: 6,
      elapsedMs: 5,
    });
    assert.ok(idleGap1 >= 250 && idleGap1 <= 500, `unchanged frame gap (${idleGap1}ms) drops to >=250ms budget`);
    assert.equal(idleGap6, 500, "repeated unchanged frames back off up to the 500ms ceiling");

    const hiddenGap = cam.computeNextFrameGapMs({
      hidden: true,
      isNewFrame: true,
      unchangedCount: 0,
      elapsedMs: 5,
    });
    assert.ok(
      hiddenGap >= 250 && hiddenGap <= 500,
      `hidden warm keep-alive gap (${hiddenGap}ms) stays within 250ms-500ms power-saving band`,
    );

    // happy-dom binds the real setTimeout at import, so the pump's window.setTimeout
    // has to be pointed at the global that t.mock.timers replaces.
    const scheduledDelays: number[] = [];
    const originalSetTimeout = window.setTimeout;
    const originalClearTimeout = window.clearTimeout;
    let perfNow = 0;
    let ipcCostMs = 0;
    t.mock.method(performance, "now", () => perfNow);
    t.mock.timers.enable({ apis: ["setTimeout"] });
    window.setTimeout = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      const delay = Math.max(0, Number(timeout ?? 0));
      scheduledDelays.push(delay);
      return globalThis.setTimeout(handler as () => void, delay, ...(args as []));
    }) as unknown as typeof window.setTimeout;
    window.clearTimeout = ((id?: number) => {
      globalThis.clearTimeout(id as unknown as ReturnType<typeof setTimeout>);
    }) as unknown as typeof window.clearTimeout;

    let seq = 0;
    let polls = 0;
    let mode: "changing" | "static" = "changing";
    const invoke = async (name: string): Promise<unknown> => {
      if (name === "go2rtc_jpeg_frame") {
        perfNow += ipcCostMs;
        polls += 1;
        if (mode === "changing") seq += 1;
        return `ZnJhbWUt${seq}`;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });

    const settle = async (): Promise<void> => {
      for (let step = 0; step < 30; step += 1) await Promise.resolve();
    };
    const latestDelay = (): number => {
      const delay = scheduledDelays.at(-1);
      assert.ok(
        delay !== undefined,
        `frame pump scheduled no gap; delays=[${scheduledDelays.join(", ")}]`,
      );
      return delay;
    };
    const expectNextPollAfter = async (gapMs: number): Promise<void> => {
      const pollsBefore = polls;
      t.mock.timers.tick(gapMs - 1);
      await settle();
      assert.equal(
        polls,
        pollsBefore,
        `polled ${gapMs - 1}ms before the ${gapMs}ms frame gap (delays=[${scheduledDelays.join(", ")}])`,
      );
      t.mock.timers.tick(1);
      await settle();
      assert.equal(
        polls,
        pollsBefore + 1,
        `frame gap ${gapMs}ms did not release the next poll (delays=[${scheduledDelays.join(", ")}])`,
      );
    };

    try {
      cam.activeLiveCameraId = "camera.living_cam";
      cam.liveCameraHidden = false;
      cam.startMjpegTransport("cam_mjpeg_test");
      app.render();
      cam.attachLiveMedia();
      await settle();

      assert.equal(polls, 1);
      assert.equal(seq, 1);
      assert.equal(latestDelay(), 45, "visible changing frames wait the 45ms active budget");

      let pacedMs = 0;
      for (let frame = 2; frame <= 6; frame += 1) {
        const gap = latestDelay();
        assert.equal(gap, 45, `visible changing frame gap was ${gap}ms`);
        pacedMs += gap;
        await expectNextPollAfter(gap);
        assert.equal(seq, frame);
      }
      assert.ok(
        pacedMs < 450,
        `expected 6 distinct frames well under old 5fps (1000ms+) cap, paced ${pacedMs}ms`,
      );

      ipcCostMs = 95;
      await expectNextPollAfter(45);
      assert.equal(
        latestDelay(),
        33,
        "a 95ms IPC round-trip applies backpressure breathing room on the next gap",
      );
      ipcCostMs = 0;

      mode = "static";
      await expectNextPollAfter(33);
      const firstIdleGap = latestDelay();
      assert.ok(
        firstIdleGap >= 250 && firstIdleGap <= 500,
        `unchanged frame gap (${firstIdleGap}ms) drops to >=250ms budget`,
      );
      for (let step = 0; step < 8 && latestDelay() < 500; step += 1) {
        await expectNextPollAfter(latestDelay());
      }
      assert.equal(latestDelay(), 500, "repeated unchanged frames back off up to the 500ms ceiling");

      const gapBeforeHide = latestDelay();
      cam.hideCameraLiveView();
      assert.equal(cam.liveCameraHidden, true);
      assert.ok(cam.liveCameraKeepAliveTimer !== null, "1-minute P2P keep-alive timer remains armed");
      assert.ok(
        scheduledDelays.includes(cam.cameraKeepAliveMs),
        "hide arms the long P2P keep-alive instead of tearing the stream down",
      );
      await expectNextPollAfter(gapBeforeHide);
      const hiddenScheduled = latestDelay();
      assert.ok(
        hiddenScheduled >= 250 && hiddenScheduled <= 500,
        `hidden warm keep-alive gap (${hiddenScheduled}ms) stays within 250ms-500ms power-saving band`,
      );
      const pollsWhileHidden = polls;
      t.mock.timers.tick(Math.min(249, hiddenScheduled - 1));
      await settle();
      assert.equal(
        polls,
        pollsWhileHidden,
        `hidden keep-alive must throttle frame polling (delta=${polls - pollsWhileHidden})`,
      );
      cam.closeCameraLiveView();
    } finally {
      window.setTimeout = originalSetTimeout;
      window.clearTimeout = originalClearTimeout;
      t.mock.timers.reset();
    }
  });

  it("skips the 2500ms same-session cooldown when switching between different cameras, but honours cooldown on same-camera reconnect", async () => {
    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const spec = makeCameraMiotSpec();
    const devices = [
      { did: "cam-a", name: "客厅摄像机", model: "isa.camera.hlc7", localip: "192.168.1.21" },
      { did: "cam-b", name: "玄关摄像机", model: "isa.camera.hlc7", localip: "192.168.1.22" },
    ];
    const stopCalls: string[] = [];
    const startCalls: string[] = [];

    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "start_xiaomi_camera_bridge") {
        const did = String(args["did"] ?? "");
        return `cam_h264_${did}|cam_mjpeg_${did}`;
      }
      if (name === "stop_xiaomi_camera_bridge") return undefined;
      if (name === "go2rtc_jpeg_frame") return "aGVsbG8";
      if (name !== "native_http") return undefined;

      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) return { status: 200, headers: {}, body: JSON.stringify(spec) };
      if (url.includes("/instances?")) {
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({ instances: devices.map((d) => ({ model: d.model, type: spec.type })) }),
        };
      }
      const decodeBody = (): Record<string, unknown> => {
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
          list: devices.map((d) => ({
            did: d.did,
            name: d.name,
            model: d.model,
            isOnline: true,
            localip: d.localip,
            spec_type: spec.type,
          })),
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = {
          homelist: [
            {
              id: "1",
              name: "我的家",
              dids: [],
              roomlist: [{ id: "10", name: "客厅", dids: ["cam-a", "cam-b"] }],
            },
          ],
        };
      } else if (url.includes("miotspec/prop/")) {
        result = devices.map((d) => ({ did: d.did, siid: 2, piid: 1, code: 0, value: true }));
      } else if (url.includes("miss_get_vendor")) {
        result = {
          public_key: "pub",
          sign: "sig",
          vendor: { vendor: 4, vendor_params: { p2p_id: "uid-1" } },
        };
      } else if (url.includes("miotspec/action")) {
        const payload = decodeBody() as { params?: { did?: string; aiid?: number } };
        const did = String(payload.params?.did ?? "");
        if (payload.params?.aiid === 1) {
          startCalls.push(did);
          result = { code: 0, out: [] };
        } else if (payload.params?.aiid === 2) {
          stopCalls.push(did);
          result = { code: 0, out: [] };
        }
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miCloudRegion: "cn",
        miSession: {
          userId: "10001",
          cUserId: "c1",
          serviceToken: "tok",
          ssecurity: security,
          region: "cn",
        },
      }),
    );

    app = new MenuMijiaWindowsApp(element("#app"));
    app.cameraLive.cameraSameSessionCooldownMs = 1_000;
    await waitFor(() => app !== null && app.devices.length === 2, 2_000);

    const tOpenA = performance.now();
    await click('[data-body-device="cam-a"]');
    await waitFor(() => app?.cameraLive.liveCameraMode === "mjpeg", 1_000);
    assert.ok(performance.now() - tOpenA < 850, "initial open skips same-session cooldown");

    const tSwitchB = performance.now();
    await click('[data-cameraswitch="cam-b"]');
    await waitFor(
      () =>
        app?.cameraLive.activeLiveCameraId === "cam-b" &&
        app.cameraLive.liveCameraStreamURL === "cam_mjpeg_cam-b" &&
        app.cameraLive.liveCameraMode === "mjpeg",
      1_000,
    );
    const switchElapsed = performance.now() - tSwitchB;
    assert.ok(
      switchElapsed < 850,
      `switching to a different camera should skip same-session cooldown, took ${Math.round(switchElapsed)}ms`,
    );

    const tReloadB = performance.now();
    await click("#btn-reload-camera-live");
    await waitFor(
      () => startCalls.filter((id) => id === "cam-b").length >= 2 && app?.cameraLive.liveCameraLoading === false,
      2_500,
    );
    const reloadElapsed = performance.now() - tReloadB;
    assert.ok(
      reloadElapsed >= 880,
      `same-camera reconnect must honour cooldown (${Math.round(reloadElapsed)}ms >= ~1000ms)`,
    );
  });

  it("exposes clear HUD mute button for audio-capable streams in Tauri, video-only hover reasons, and closes modal on Escape without hiding panel", async () => {
    const tauriCalls: string[] = [];
    const invoke = async (command: string): Promise<unknown> => {
      tauriCalls.push(command);
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
      }),
    );
    app = new MenuMijiaWindowsApp(element("#app"));
    app.cameraKeepAliveMs = 5_000;

    await click('[data-body-device="camera.living_cam"]');
    const demoBadge = element("#cc-camera-audio-badge");
    assert.equal(demoBadge.textContent, "仅画面");
    assert.equal(demoBadge.dataset.videoOnlyReason, "demo");
    assert.match(demoBadge.title, /演示预览|音视频流/);

    await click("#btn-toggle-camera-url");
    element<HTMLInputElement>("#camera-stream-url-input").value = "https://example.com/camera/live.mp4";
    await click("#btn-save-camera-url");

    const video = element<HTMLVideoElement>("#cc-camera-video");
    const muteBtn = element<HTMLButtonElement>("#cc-camera-mute");
    assert.equal(video.muted, true);
    assert.equal(muteBtn.getAttribute("aria-pressed"), "true");
    assert.match(muteBtn.textContent ?? "", /开启声音/);

    await click("#cc-camera-mute");
    assert.equal(video.muted, false);
    assert.equal(muteBtn.getAttribute("aria-pressed"), "false");
    assert.equal(muteBtn.getAttribute("title"), "关闭声音");
    assert.match(muteBtn.textContent ?? "", /关闭声音/);

    await click("#btn-toggle-camera-url");
    element<HTMLInputElement>("#camera-stream-url-input").value = "https://example.com/camera/snapshot.jpg";
    await click("#btn-save-camera-url");
    const snapBadge = element("#cc-camera-audio-badge");
    assert.equal(snapBadge.textContent, "仅画面");
    assert.equal(snapBadge.dataset.videoOnlyReason, "snapshot");
    assert.match(snapBadge.title, /抓拍|MJPEG/);

    app.ctxMenu = { x: 10, y: 10, roomBar: true };
    app.render();
    assert.equal(app.cameraLive.liveCameraHidden, false);

    const hidePanelBefore = tauriCalls.filter((c) => c === "hide_panel").length;
    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    await setImmediate();

    assert.equal(app.ctxMenu, null, "first Escape closes higher-priority context menu");
    assert.equal(app.cameraLive.liveCameraHidden, false, "first Escape leaves camera modal open");
    assert.equal(tauriCalls.filter((c) => c === "hide_panel").length, hidePanelBefore);

    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    await setImmediate();

    assert.equal(app.cameraLive.liveCameraHidden, true, "second Escape hides the live camera modal back to panel");
    assert.equal(
      element<HTMLElement>(".cc-sheet-backdrop").style.display,
      "none",
      "camera modal backdrop is hidden while warm keep-alive stays armed",
    );
    assert.equal(
      tauriCalls.filter((c) => c === "hide_panel").length,
      hidePanelBefore,
      "Escape on camera modal must not collapse the main panel window",
    );
  });
});
