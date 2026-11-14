import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudError } from "../src/core/miCloud/session.js";
import {
  MIOT_DEVICE_OFFLINE_CODE,
  classifyControlFailure,
  controlFailureUserMessage,
  isCancellationError,
} from "../src/core/controlFailure.js";
import {
  RunningBatch,
  cancelRunningBatch,
  executeIntents,
  executeSingleCommand,
  getRunningBatch,
} from "../src/ui/intentExecution.js";
import {
  executeDirectAskPreset,
  onOpenURL,
  type AppURLCommandHost,
} from "../src/core/appUrlCommand.js";
import {
  buildRaycastSnapshot,
  resolveRaycastVisibleDevices,
  type RaycastCommandFeedback,
} from "../src/core/raycastSnapshot.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function makeLight(
  id: string,
  name: string,
  overrides: Partial<SmartDevice> & { isOn?: boolean } = {},
): SmartDevice {
  const { isOn = true, ...rest } = overrides;
  return {
    id,
    name,
    roomId: "room_study",
    roomName: "书房",
    model: "yeelink.light.lamp4",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: `light.${id}`,
      isOn,
      brightnessPercent: 80,
      colorTempKelvin: 4500,
      minKelvin: 2700,
      maxKelvin: 6500,
      availableEffects: ["Reading", "Night"],
      currentEffect: null,
      powerWritable: true,
      brightnessWritable: true,
      colorWritable: true,
    },
    ...rest,
  };
}

function makeVacuum(
  id = "vac.main",
  name = "石头扫地机",
  status: "docked" | "cleaning" | "paused" = "docked",
): SmartDevice {
  return {
    id,
    name,
    roomId: "room_living",
    roomName: "客厅",
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: `vacuum.${id}`,
      status,
      battery: 92,
      modeEntityId: null,
      currentMode: "Balanced",
      availableModes: ["Silent", "Balanced", "Turbo"],
      actionsWritable: true,
    },
  };
}

function makeCover(
  id = "cover.living",
  name = "客厅窗帘",
  subtype: "curtain" | "garage-door" = "curtain",
): SmartDevice {
  return {
    id,
    name,
    roomId: "room_living",
    roomName: "客厅",
    model: "lumi.curtain.v1",
    isOnline: true,
    kind: {
      kind: "cover",
      entityId: `cover.${id}`,
      subtype,
      positionPercent: 0,
      positionWritable: true,
      motion: "stopped",
      openDescription: "Open",
      closeDescription: "Close",
      pauseDescription: "Pause",
      batteryPercent: null,
      faultText: null,
    },
  };
}

function makeFan(id = "fan.living", name = "客厅风扇"): SmartDevice {
  return {
    id,
    name,
    roomId: "room_living",
    roomName: "客厅",
    model: "zhimi.fan.za5",
    isOnline: true,
    kind: {
      kind: "fan",
      entityId: `fan.${id}`,
      isOn: true,
      percentage: 30,
      presetMode: "Auto",
      availablePresetModes: ["Auto", "Sleep", "Favorite"],
      isOscillating: false,
      swingWritable: true,
      powerWritable: true,
      speedWritable: true,
    },
  };
}

function makeHighRiskHeater(id = "plug.heater", name = "卧室电暖器"): SmartDevice {
  return {
    id,
    name,
    roomId: "room_bedroom",
    roomName: "卧室",
    model: "zhimi.heater.ma2",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn: false,
      powerWatts: 0,
      energyKwh: 0.4,
      childLockEntityId: null,
      isChildLocked: false,
      powerWritable: true,
    },
  };
}

let dom: Window | null = null;

function mountApp(): MenuMijiaWindowsApp {
  dom = mountTestWindow();
  installCssEscape();
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (cmd: string) => {
      if (cmd === "is_workstation_locked") return false;
      if (cmd === "drain_pending_open_urls") return [];
      return null;
    },
  };
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      enableRaycastIntegration: true,
    }),
  );
  const root = document.querySelector<HTMLElement>("#app");
  assert.ok(root);
  return new MenuMijiaWindowsApp(root);
}

describe("Fine-grained controlFailure classification (#1)", () => {
  afterEach(() => {
    setLanguage("zh-Hans");
    if (dom) {
      closeTestWindow(dom);
      dom = null;
    }
  });

  it("classifies offline, 429 rate-limit, 401/403/code-3 auth expiry, network timeout, and Mijia rejection in zh-Hans & en", () => {
    setLanguage("zh-Hans");
    const miOffline = new MiCloudError("api", "设备未响应或离线", MIOT_DEVICE_OFFLINE_CODE);
    assert.deepEqual(classifyControlFailure(miOffline), {
      kind: "deviceOffline",
      isCancellation: false,
    });
    assert.match(
      controlFailureUserMessage(miOffline, { deviceName: "书房台灯" }) ?? "",
      /书房台灯 操作未生效：.*离线/,
    );
    assert.equal(classifyControlFailure(new Error("Entity is unavailable"))?.kind, "deviceOffline");
    assert.equal(classifyControlFailure(new Error("device offline"))?.kind, "deviceOffline");
    assert.equal(
      classifyControlFailure(new Error("HTTP 500"), { isDeviceOnline: false })?.kind,
      "deviceOffline",
    );

    const rateErr = new MiCloudError("http", "米家云服务 HTTP 429", 429);
    assert.equal(classifyControlFailure(rateErr, { isDeviceOnline: false })?.kind, "rateLimited");
    assert.match(
      controlFailureUserMessage("Too Many Requests", { deviceName: "客厅主灯", adjustment: true }) ?? "",
      /客厅主灯 调节未生效：.*频繁/,
    );

    assert.equal(
      classifyControlFailure(new MiCloudError("sessionExpired", "米家登录已过期"))?.kind,
      "sessionExpired",
    );
    assert.equal(
      classifyControlFailure(new MiCloudError("api", "auth err", 3))?.kind,
      "sessionExpired",
    );
    assert.equal(
      classifyControlFailure(new MiCloudError("notLoggedIn", "未登录米家"))?.kind,
      "signedOut",
    );
    assert.equal(
      classifyControlFailure(Object.assign(new Error("Home Assistant HTTP 401"), { status: 401 }))?.kind,
      "tokenRejected",
    );
    assert.equal(
      classifyControlFailure(Object.assign(new Error("Forbidden"), { statusCode: 403 }))?.kind,
      "tokenRejected",
    );
    assert.match(
      controlFailureUserMessage(new MiCloudError("api", "code 3", 3), { deviceName: "吸顶灯" }) ?? "",
      /设置/,
    );

    assert.equal(classifyControlFailure(new Error("request timeout after 8000ms"))?.kind, "network");
    assert.equal(
      classifyControlFailure(Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" }))?.kind,
      "network",
    );
    assert.equal(classifyControlFailure(new TypeError("Failed to fetch"))?.kind, "network");
    assert.equal(classifyControlFailure(new Error("HTTP 504 Gateway Timeout"))?.kind, "network");
    assert.match(
      controlFailureUserMessage(new Error("ECONNREFUSED"), { deviceName: "阳台插座" }) ?? "",
      /网络/,
    );

    const rejected = new MiCloudError("api", "设备未响应或离线", -704030013);
    assert.deepEqual(classifyControlFailure(rejected), {
      kind: "deviceRejected",
      code: -704030013,
      isCancellation: false,
    });
    assert.match(
      controlFailureUserMessage(rejected, { deviceName: "浴霸" }) ?? "",
      /-704030013/,
    );
    assert.equal(classifyControlFailure(new Error("HTTP 500")), null);
    assert.equal(
      controlFailureUserMessage(new Error("HTTP 500"), {
        deviceName: "书房灯",
        fallback: "HTTP 500",
      }),
      "HTTP 500",
    );

    setLanguage("en");
    assert.match(
      controlFailureUserMessage(miOffline, { deviceName: "Study Lamp" }) ?? "",
      /Study Lamp action failed: .*offline/i,
    );
    assert.match(
      controlFailureUserMessage(rateErr, { deviceName: "Study Lamp", adjustment: true }) ?? "",
      /Study Lamp adjustment failed: .*too many requests/i,
    );
    assert.match(
      controlFailureUserMessage(Object.assign(new Error("401"), { status: 401 }), {
        deviceName: "Study Lamp",
      }) ?? "",
      /Settings/,
    );
    assert.match(
      controlFailureUserMessage(new Error("ETIMEDOUT"), { deviceName: "Study Lamp" }) ?? "",
      /network/i,
    );
  });

  it("marks slider debounce / AbortError / cancelled errors as isCancellation and silently ignores them in intentExecution", async () => {
    const abortDom = new DOMException("The operation was aborted.", "AbortError");
    assert.equal(isCancellationError(abortDom), true);
    assert.deepEqual(classifyControlFailure(abortDom), {
      kind: "cancelled",
      isCancellation: true,
    });
    assert.equal(controlFailureUserMessage(abortDom, { deviceName: "书房台灯" }), null);
    assert.equal(isCancellationError(new Error("Request cancelled by newer slider write")), true);

    const app = mountApp();
    const lamp = makeLight("l1", "书房台灯");
    app.devices = [lamp];
    app.replyBanner = null;

    app.applyCommand = async () => {
      throw abortDom;
    };
    await executeSingleCommand(
      app,
      lamp,
      { kind: "setLightBrightness", entityId: "light.l1", percent: 45 },
      "亮度 45%",
    );
    assert.equal(app.replyBanner, null);

    app.applyCommand = async () => {
      app.replyBanner = { text: "AbortError: signal is aborted", source: "控制失败", isError: true };
      return false;
    };
    await executeSingleCommand(
      app,
      lamp,
      { kind: "setLightBrightness", entityId: "light.l1", percent: 55 },
      "亮度 55%",
    );
    assert.equal(app.replyBanner, null);

    const okOnAbort = await executeIntents(
      app,
      [{ targetId: "l1", operation: { kind: "brightness", percent: 30 } }],
      "已调光",
      "Jev SystemOne",
    );
    assert.equal(okOnAbort, false);
    assert.equal(app.replyBanner, null);

    app.applyCommand = async () => {
      app.replyBanner = { text: "米家云服务 HTTP 429", source: "控制失败", isError: true };
      return false;
    };
    const okOn429 = await executeIntents(
      app,
      [{ targetId: "l1", operation: { kind: "brightness", percent: 30 } }],
      "已调光",
      "Jev SystemOne",
    );
    assert.equal(okOn429, false);
    const banner429 = app.replyBanner as MenuMijiaWindowsApp["replyBanner"];
    assert.equal(banner429?.isError, true);
    assert.match(banner429?.text ?? "", /书房台灯 调节未生效：.*频繁/);
  });
});

describe("A11 RunningBatch mid-flight undo & preemption (#2)", () => {
  beforeEach(() => {
    setLanguage("zh-Hans");
  });

  afterEach(() => {
    if (dom) {
      closeTestWindow(dom);
      dom = null;
    }
  });

  it("halts an in-flight All Off batch immediately on performUndo and only restores devices whose commands were sent", async () => {
    const app = mountApp();
    const l1 = makeLight("l1", "灯一", { isOn: true });
    const l2 = makeLight("l2", "灯二", { isOn: true });
    const l3 = makeLight("l3", "灯三", { isOn: true });
    const l4 = makeLight("l4", "灯四", { isOn: true });
    app.devices = [l1, l2, l3, l4];

    const l2OffGate = deferred<boolean>();
    const sentCommands: Array<{ entityId: string; isOn: boolean }> = [];

    app.applyCommand = async (cmd) => {
      if (cmd.kind === "setLightPower") {
        sentCommands.push({ entityId: cmd.entityId, isOn: cmd.isOn });
        if (cmd.entityId === "light.l2" && cmd.isOn === false) {
          return l2OffGate.promise;
        }
      }
      return true;
    };

    const batchPromise = app.executeIntents(
      [
        { targetId: "l1", operation: { kind: "power", isOn: false } },
        { targetId: "l2", operation: { kind: "power", isOn: false } },
        { targetId: "l3", operation: { kind: "power", isOn: false } },
        { targetId: "l4", operation: { kind: "power", isOn: false } },
      ],
      "已关闭 4 台开启中的设备",
      "一键全关",
    );

    await setImmediate();
    const running = getRunningBatch(app);
    assert.ok(running, "Expected RunningBatch to be active while l2 is in flight");
    assert.equal(running.isStopped, false);
    assert.deepEqual(sentCommands, [
      { entityId: "light.l1", isOn: false },
      { entityId: "light.l2", isOn: false },
    ]);

    const undoPromise = app.performUndo();
    await setImmediate();
    assert.equal(running.isStopped, true);
    assert.equal(running.stopReason, "undo");

    l2OffGate.resolve(true);
    await Promise.all([batchPromise, undoPromise]);

    const l3Calls = sentCommands.filter((c) => c.entityId === "light.l3");
    const l4Calls = sentCommands.filter((c) => c.entityId === "light.l4");
    assert.deepEqual(l3Calls, []);
    assert.deepEqual(l4Calls, []);

    const restoreTargets = sentCommands
      .filter((c) => c.isOn === true)
      .map((c) => c.entityId)
      .sort();
    assert.deepEqual(restoreTargets, ["light.l1", "light.l2"]);
    assert.match(app.replyBanner?.text ?? "", /已撤销/);
  });

  it("excludes failed devices AND unreached devices from the mid-batch undo snapshot, and preempts on a new batch", async () => {
    const app = mountApp();
    const l1 = makeLight("l1", "灯一", { isOn: true });
    const l2 = makeLight("l2", "灯二", { isOn: true });
    const l3 = makeLight("l3", "灯三", { isOn: true });
    const l4 = makeLight("l4", "灯四", { isOn: true });
    app.devices = [l1, l2, l3, l4];

    const l3Gate = deferred<boolean>();
    const sent: Array<{ entityId: string; isOn: boolean }> = [];

    app.applyCommand = async (cmd) => {
      if (cmd.kind === "setLightPower") {
        sent.push({ entityId: cmd.entityId, isOn: cmd.isOn });
        if (cmd.entityId === "light.l2" && !cmd.isOn) {
          return false; // l2 failed!
        }
        if (cmd.entityId === "light.l3" && !cmd.isOn) {
          return l3Gate.promise;
        }
      }
      return true;
    };

    const firstBatch = app.executeIntents(
      [
        { targetId: "l1", operation: { kind: "power", isOn: false } },
        { targetId: "l2", operation: { kind: "power", isOn: false } },
        { targetId: "l3", operation: { kind: "power", isOn: false } },
        { targetId: "l4", operation: { kind: "power", isOn: false } },
      ],
      "全关测试",
      "一键全关",
    );

    await setImmediate();
    await setImmediate();
    const activeBatch = getRunningBatch(app);
    assert.ok(activeBatch);
    assert.equal(activeBatch.failedDeviceIds.has("l2"), true);
    assert.equal(activeBatch.steps.some((s) => s.deviceId === "l2"), false);
    assert.equal(activeBatch.steps.some((s) => s.deviceId === "l4"), false);

    assert.equal(cancelRunningBatch(app, "cancelled"), true);
    l3Gate.resolve(true);
    await firstBatch;

    assert.equal(sent.some((c) => c.entityId === "light.l4"), false);
    assert.deepEqual(
      (app.lastUndoAction?.steps ?? []).map((s) => s.deviceId).sort(),
      ["l1", "l3"],
    );

    const customBatch = new RunningBatch({ summary: "第一批", sourceRevision: app.sourceRevision });
    const holdFirst = deferred<boolean>();
    const secondSent: string[] = [];
    app.applyCommand = async (cmd) => {
      secondSent.push(`${cmd.kind}:${cmd.entityId}`);
      if (cmd.entityId === "light.l1") return holdFirst.promise;
      return true;
    };
    const p1 = executeIntents(
      app,
      [
        { targetId: "l1", operation: { kind: "power", isOn: false } },
        { targetId: "l4", operation: { kind: "power", isOn: false } },
      ],
      "第一批",
      "一键全关",
      { batch: customBatch },
    );
    await setImmediate();
    assert.equal(customBatch.isStopped, false);

    const p2 = executeIntents(
      app,
      [{ targetId: "l3", operation: { kind: "power", isOn: false } }],
      "第二批",
      "一键全关",
    );
    assert.equal(customBatch.isStopped, true);
    assert.equal(customBatch.stopReason, "preempted");
    holdFirst.resolve(true);
    await Promise.all([p1, p2]);
    assert.equal(secondSent.includes("setLightPower:light.l4"), false);
    assert.equal(secondSent.includes("setLightPower:light.l3"), true);
  });
});

describe("A15 Companion URL high-risk confirm, Zero-AI presets, group folding & Raycast Windows (#3)", () => {
  beforeEach(() => {
    setLanguage("zh-Hans");
  });

  function createMockUrlHost(opts: {
    devices: SmartDevice[];
    token?: string;
    confirmHighRiskResult?: boolean;
    withHighRiskModal?: boolean;
  }): {
    host: AppURLCommandHost;
    executedSingle: Array<{ deviceId: string; command: DeviceCommand; summary: string }>;
    appliedCommands: DeviceCommand[];
    naturalInputs: string[];
    feedbacks: Array<Omit<RaycastCommandFeedback, "completedAt">>;
    highRiskModalCalls: Array<{ deviceId: string; actionLabel: string; commandLabel: string }>;
  } {
    const token = opts.token ?? "a".repeat(64);
    const executedSingle: Array<{ deviceId: string; command: DeviceCommand; summary: string }> = [];
    const appliedCommands: DeviceCommand[] = [];
    const naturalInputs: string[] = [];
    const feedbacks: Array<Omit<RaycastCommandFeedback, "completedAt">> = [];
    const highRiskModalCalls: Array<{ deviceId: string; actionLabel: string; commandLabel: string }> = [];

    let pendingHighRisk: AppURLCommandHost["pendingHighRisk"] = null;
    let replyBanner: AppURLCommandHost["replyBanner"] = null;

    const host: AppURLCommandHost = {
      devices: opts.devices,
      scenes: [],
      sourceRevision: 1,
      settings: {
        enableRaycastIntegration: true,
        allowDirectURLControl: false,
        blockControlWhileLocked: true,
      },
      layout: { aliases: {}, roomAliases: {} },
      get pendingHighRisk() {
        return pendingHighRisk;
      },
      get replyBanner() {
        return replyBanner;
      },
      pendingConsent: null,
      expandedDeviceId: null,
      getActiveRaycastBridgeToken: () => token,
      isControlBlockedByScreenLock: async () => false,
      requestExternalUrlConfirmation: async () => false,
      ...(opts.withHighRiskModal
        ? {
            openExternalUrlConfirmPrompt: async (args: {
              device: SmartDevice;
              actionLabel: string;
              commandLabel: string;
            }) => {
              highRiskModalCalls.push({
                deviceId: args.device.id,
                actionLabel: args.actionLabel,
                commandLabel: args.commandLabel,
              });
              return opts.confirmHighRiskResult ?? false;
            },
          }
        : {}),
      revealPanelForExternalUrl: async () => {},
      setPendingHighRisk: (next) => {
        pendingHighRisk = next;
      },
      clearPendingHighRisk: () => {
        pendingHighRisk = null;
      },
      showExternalToast: (message, isError) => {
        replyBanner = { text: message, source: "URL", isError };
      },
      recordRaycastCommandFeedback: (fb) => {
        feedbacks.push(fb);
      },
      executeSingleCommand: async (device, command, summary) => {
        executedSingle.push({ deviceId: device.id, command, summary });
        replyBanner = { text: summary, source: "实时控制", isError: false };
      },
      applyCommand: async (command) => {
        appliedCommands.push(command);
        return true;
      },
      handleNaturalCommand: async (rawInput) => {
        naturalInputs.push(rawInput);
        replyBanner = { text: `AI:${rawInput}`, source: "本地规则", isError: false };
      },
      executeBuiltInSceneFromUrl: async () => ({ message: "ok", isError: false }),
      focusDeviceFromUrl: (id) => {
        host.expandedDeviceId = id;
      },
    };

    return {
      host,
      executedSingle,
      appliedCommands,
      naturalInputs,
      feedbacks,
      highRiskModalCalls,
    };
  }

  it("opens in-panel confirm prompt for high-risk devices with valid bridgeToken (executes on confirm, cancels on reject, preserves legacy fallback)", async () => {
    const token = "b".repeat(64);
    const heater = makeHighRiskHeater();

    const confirmed = createMockUrlHost({
      devices: [heater],
      token,
      withHighRiskModal: true,
      confirmHighRiskResult: true,
    });
    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_ok&token=${token}`,
      confirmed.host,
    );
    assert.equal(confirmed.highRiskModalCalls.length, 1);
    assert.equal(confirmed.highRiskModalCalls[0]?.deviceId, "plug.heater");
    assert.equal(confirmed.executedSingle.length, 1);
    assert.deepEqual(confirmed.executedSingle[0]?.command, {
      kind: "setSwitch",
      entityId: "switch.plug.heater",
      isOn: true,
    });
    assert.equal(confirmed.feedbacks.at(-1)?.requestId, "req_ok");
    assert.equal(confirmed.feedbacks.at(-1)?.isError, false);

    const cancelled = createMockUrlHost({
      devices: [heater],
      token,
      withHighRiskModal: true,
      confirmHighRiskResult: false,
    });
    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_cancel&token=${token}`,
      cancelled.host,
    );
    assert.equal(cancelled.highRiskModalCalls.length, 1);
    assert.equal(cancelled.executedSingle.length, 0);
    assert.equal(cancelled.feedbacks.at(-1)?.requestId, "req_cancel");
    assert.equal(cancelled.feedbacks.at(-1)?.isError, true);
    assert.match(cancelled.feedbacks.at(-1)?.message ?? "", /已取消/);

    const legacy = createMockUrlHost({
      devices: [heater],
      token,
      withHighRiskModal: false,
    });
    await onOpenURL(
      `menumijia://power?device=plug.heater&on=true&id=req_legacy&token=${token}`,
      legacy.host,
    );
    assert.equal(legacy.executedSingle.length, 0);
    assert.ok(legacy.host.pendingHighRisk);
    assert.equal(legacy.feedbacks.at(-1)?.isError, true);
    assert.match(legacy.feedbacks.at(-1)?.message ?? "", /高风险设备/);
  });

  it("executes Zero-AI companion ask presets locally (moonlight/night light, vacuum dock/pause/start, cover, fan) and falls back otherwise", async () => {
    const token = "c".repeat(64);
    const lamp = makeLight("lamp.study", "书房台灯");
    const vac = makeVacuum("vac.robo", "石头扫地机", "cleaning");
    const curtain = makeCover("cover.living", "客厅窗帘", "curtain");
    const fan = makeFan("fan.living", "客厅风扇");

    const ctx = createMockUrlHost({
      devices: [lamp, vac, curtain, fan],
      token,
      withHighRiskModal: true,
      confirmHighRiskResult: true,
    });

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("把书房台灯设为柔和月光模式")}&id=ask_moon&token=${token}`,
      ctx.host,
    );
    assert.equal(ctx.naturalInputs.length, 0);
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "setLightBrightness",
      entityId: "light.lamp.study",
      percent: 15,
    });
    assert.deepEqual(ctx.appliedCommands.at(-1), {
      kind: "setLightColorTemp",
      entityId: "light.lamp.study",
      kelvin: 2700,
    });
    assert.equal(ctx.feedbacks.at(-1)?.isError, false);

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("让石头扫地机回充")}&id=ask_dock_zh&token=${token}`,
      ctx.host,
    );
    assert.equal(ctx.naturalInputs.length, 0);
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "vacuumAction",
      entityId: "vacuum.vac.robo",
      action: "returnToBase",
    });
    assert.equal(ctx.feedbacks.at(-1)?.isError, false);

    const enRes = await executeDirectAskPreset("dock 石头扫地机", ctx.host);
    assert.equal(enRes.handled, true);
    assert.equal(enRes.isError, false);

    const roborockOnly = createMockUrlHost({
      devices: [makeVacuum("vac.g20", "Roborock G20", "cleaning"), lamp],
      token,
    });
    for (const phrase of ["dock", "回充", "让扫地机器人回充"]) {
      await onOpenURL(
        `menumijia://ask?text=${encodeURIComponent(phrase)}&id=bare_${encodeURIComponent(phrase)}&token=${token}`,
        roborockOnly.host,
      );
      assert.equal(roborockOnly.naturalInputs.length, 0);
      assert.deepEqual(roborockOnly.executedSingle.at(-1)?.command, {
        kind: "vacuumAction",
        entityId: "vacuum.vac.g20",
        action: "returnToBase",
      });
    }
    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("柔和夜灯模式")}&id=bare_moon&token=${token}`,
      roborockOnly.host,
    );
    assert.equal(roborockOnly.naturalInputs.length, 0);
    assert.equal(roborockOnly.executedSingle.at(-1)?.deviceId, "lamp.study");

    const twoLights = createMockUrlHost({
      devices: [lamp, makeLight("lamp.bed", "床头灯")],
      token,
    });
    const multiLightRes = await executeDirectAskPreset("柔和夜灯模式", twoLights.host);
    assert.equal(multiLightRes.handled, false);

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("暂停石头扫地机")}&id=ask_pause&token=${token}`,
      ctx.host,
    );
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "vacuumAction",
      entityId: "vacuum.vac.robo",
      action: "pause",
    });

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("启动石头扫地机")}&id=ask_start&token=${token}`,
      ctx.host,
    );
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "vacuumAction",
      entityId: "vacuum.vac.robo",
      action: "start",
    });

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("把客厅窗帘开到50%")}&id=ask_cover&token=${token}`,
      ctx.host,
    );
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "setNumberValue",
      entityId: "cover.cover.living",
      value: 50,
    });

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("把客厅风扇设为睡眠模式")}&id=ask_fan&token=${token}`,
      ctx.host,
    );
    assert.deepEqual(ctx.executedSingle.at(-1)?.command, {
      kind: "setFanPresetMode",
      entityId: "fan.fan.living",
      presetMode: "Sleep",
    });
    assert.equal(ctx.naturalInputs.length, 0);

    await onOpenURL(
      `menumijia://ask?text=${encodeURIComponent("10分钟后关闭书房台灯")}&id=ask_timer&token=${token}`,
      ctx.host,
    );
    assert.deepEqual(ctx.naturalInputs, ["10分钟后关闭书房台灯"]);
  });

  it("folds grouped member lights in buildRaycastSnapshot only when hideGroupedLights is enabled and the owning group is visible & online", () => {
    const group = makeLight("group.living", "客厅灯组", {
      roomId: "r_living",
      roomName: "客厅",
      isOnline: true,
    });
    const m1 = makeLight("light.m1", "筒灯左", {
      roomId: "r_living",
      roomName: "客厅",
      isOnline: true,
    });
    const m2 = makeLight("light.m2", "筒灯右", {
      roomId: "r_living",
      roomName: "客厅",
      isOnline: true,
    });
    const solo = makeLight("light.solo", "书房台灯", {
      roomId: "r_study",
      roomName: "书房",
      isOnline: true,
    });
    const owners = { "light.m1": "group.living", "light.m2": "group.living" };
    const baseInput = {
      connectionMode: "xiaomiCloud",
      selectedHomeId: "home_1",
      connectionSummary: "米家已连接",
      bridgeToken: "d".repeat(64),
      isStale: false,
      devices: [group, m1, m2, solo],
      rooms: [
        { id: "r_living", name: "客厅", deviceCount: 3 },
        { id: "r_study", name: "书房", deviceCount: 1 },
      ],
      scenes: [],
      environmentReadings: [],
    };

    const foldedSnap = buildRaycastSnapshot({
      ...baseInput,
      hideGroupedLights: true,
      lightGroupOwners: owners,
    });
    assert.deepEqual(
      foldedSnap.devices.map((d) => d.id),
      ["group.living", "light.solo"],
    );

    const unfoldedSnap = buildRaycastSnapshot({
      ...baseInput,
      hideGroupedLights: false,
      lightGroupOwners: owners,
    });
    assert.deepEqual(
      unfoldedSnap.devices.map((d) => d.id),
      ["group.living", "light.m1", "light.m2", "light.solo"],
    );

    const offlineGroup = { ...group, isOnline: false };
    const offlineGroupSnap = buildRaycastSnapshot({
      ...baseInput,
      devices: [offlineGroup, m1, m2, solo],
      hideGroupedLights: true,
      lightGroupOwners: owners,
    });
    assert.deepEqual(
      offlineGroupSnap.devices.map((d) => d.id),
      ["group.living", "light.m1", "light.m2", "light.solo"],
    );

    const hiddenGroupVisible = resolveRaycastVisibleDevices({
      devices: [group, m1, m2, solo],
      hiddenIds: ["group.living"],
      hideGroupedLights: true,
      lightGroupMembers: new Map([["group.living", ["light.m1", "light.m2"]]]),
    });
    assert.deepEqual(
      hiddenGroupVisible.map((d) => d.id),
      ["light.m1", "light.m2", "light.solo"],
    );
  });

  it("declares both macOS and Windows in raycast/package.json platforms", () => {
    const pkgPath = fileURLToPath(new URL("../../raycast/package.json", import.meta.url));
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { platforms?: string[] };
    assert.deepEqual(pkg.platforms, ["macOS", "Windows"]);
  });
});
