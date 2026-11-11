import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  IntentValidator,
  ModelIntentResolver,
  UserHabitMemory,
  buildAssistantContext,
  buildIntentCatalog,
} from "../src/core/assistant.js";
import { inverseCommands } from "../src/core/commandEffects.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiAccountLogin } from "../src/core/miCloud/accountLogin.js";
import { MI_SESSION_WARNING_LEAD_MS, miSessionExpiryState } from "../src/core/miCloud/session.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import { availableQuickActions } from "../src/core/quickActions.js";
import { CredentialVault, parseMiSession, serializeMiSession } from "../src/core/secureStore.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import type { SpeechRecognitionInstance } from "../src/ui/appTypes.js";
import { assertMissing } from "./dom.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function makeLight(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  isOnline?: boolean;
  isOn?: boolean;
  brightnessPercent?: number | null;
  colorTempKelvin?: number | null;
  availableEffects?: string[];
  brightnessWritable?: boolean;
  colorWritable?: boolean;
} = {}): SmartDevice {
  return {
    id: overrides.id ?? "light.study",
    name: overrides.name ?? "书房吸顶灯",
    roomId: overrides.roomId ?? "room_study",
    roomName: overrides.roomName ?? "书房",
    model: "yeelink.light.ceiling22",
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "light",
      entityId: `light.${overrides.id ?? "study"}`,
      isOn: overrides.isOn ?? true,
      brightnessPercent: overrides.brightnessPercent !== undefined ? overrides.brightnessPercent : 80,
      colorTempKelvin: overrides.colorTempKelvin !== undefined ? overrides.colorTempKelvin : 4200,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: overrides.availableEffects ?? ["Day", "Night", "Reading"],
      brightnessWritable: overrides.brightnessWritable ?? true,
      colorWritable: overrides.colorWritable ?? true,
    },
  };
}

function makeClimate(overrides: {
  id?: string;
  name?: string;
  roomId?: string;
  roomName?: string;
  isOn?: boolean;
  hvacMode?: string;
  availableModes?: readonly string[];
} = {}): SmartDevice {
  return {
    id: overrides.id ?? "climate.bedroom",
    name: overrides.name ?? "主卧空调",
    roomId: overrides.roomId ?? "room_bedroom",
    roomName: overrides.roomName ?? "主卧",
    model: "xiaomi.aircondition.mc5",
    isOnline: true,
    kind: {
      kind: "climate",
      entityId: overrides.id ?? "climate.bedroom",
      isOn: overrides.isOn ?? true,
      hvacMode: overrides.hvacMode ?? "cool",
      availableModes: overrides.availableModes ? [...overrides.availableModes] : ["off", "cool", "heat", "dry", "fan_only", "auto"],
      targetTemperature: 25,
      currentTemperature: 28,
      minTemp: 16,
      maxTemp: 30,
      step: 1,
      fanMode: "auto",
      availableFanModes: ["auto", "low", "high"],
    },
  };
}

function makeVacuum(status: string): SmartDevice {
  return {
    id: "vacuum.main",
    name: "扫拖机器人",
    roomId: "room_living",
    roomName: "客厅",
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: "vacuum.main",
      status,
      battery: 92,
      modeEntityId: null,
      currentMode: null,
      availableModes: [],
    },
  };
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("Real-mode built-in QuickActions & bidirectional undo (#1)", () => {
  it("renders built-in QuickActions in xiaomiCloud and homeAssistant modes (with HA scenes) scoped to controllable devices", () => {
    const light = makeLight({ id: "l1", roomId: "study", roomName: "书房", isOn: false });
    const ac = makeClimate({ id: "c1", roomId: "bed", roomName: "主卧", isOn: true });
    assert.deepEqual(
      availableQuickActions([light, ac]).map((a) => a.id),
      ["lightsOff", "softNightLight", "climateSleepOff"],
    );
    assert.deepEqual(
      availableQuickActions([makeLight({ brightnessWritable: false, colorWritable: false })]).map(
        (a) => a.id,
      ),
      ["lightsOff"],
    );

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        hasCompletedOnboarding: true,
        showQuickActionsBar: true,
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.devices = [light, ac];
    app.scenes = [{ id: "scene.movie", name: "观影模式", entityId: "scene.movie" }];
    app.render();

    const sceneCmds = [...document.querySelectorAll<HTMLElement>("[data-scene-cmd]")].map(
      (el) => el.dataset.sceneCmd,
    );
    assert.deepEqual(sceneCmds, ["quick:lightsOff", "quick:softNightLight", "quick:climateSleepOff"]);
    assert.ok(document.querySelector('[data-ha-scene="scene.movie"]'));

    // Scoping to the study room hides climateSleepOff because the AC lives in the bedroom.
    app.selectRoom("study", "书房");
    app.render();
    const studyCmds = [...document.querySelectorAll<HTMLElement>("[data-scene-cmd]")].map(
      (el) => el.dataset.sceneCmd,
    );
    assert.deepEqual(studyCmds, ["quick:lightsOff", "quick:softNightLight"]);
  });

  it("executes softNightLight on a previously-off preferred light and restores its exact pre-action state on undo", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: {
          userId: "88880001",
          cUserId: "",
          ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
          serviceToken: "tok",
          passToken: "",
          region: "cn",
        },
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const firstOff = makeLight({
      id: "l1",
      name: "客厅主灯",
      isOn: false,
      brightnessPercent: 90,
      colorTempKelvin: 5600,
    });
    const preferredOff = makeLight({
      id: "l2",
      name: "床头夜灯",
      isOn: false,
      brightnessPercent: 65,
      colorTempKelvin: 4800,
    });
    app.devices = [firstOff, preferredOff];
    app.lastManuallyUsedLightId = "l2";

    const sent: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      sent.push(cmd);
      const target = app.devices.find((d) => d.kind.kind === "light" && d.kind.entityId === cmd.entityId);
      if (target && target.kind.kind === "light") {
        if (cmd.kind === "setLightBrightness") {
          target.kind = { ...target.kind, isOn: true, brightnessPercent: cmd.percent };
        } else if (cmd.kind === "setLightColorTemp") {
          target.kind = { ...target.kind, isOn: true, colorTempKelvin: cmd.kelvin };
        } else if (cmd.kind === "setLightPower") {
          target.kind = { ...target.kind, isOn: cmd.isOn };
        }
      }
      return true;
    };
    app.render();

    await click('[data-scene-cmd="quick:softNightLight"]');
    await setImmediate();

    assert.deepEqual(sent, [
      { kind: "setLightBrightness", entityId: "light.l2", percent: 15 },
      { kind: "setLightColorTemp", entityId: "light.l2", kelvin: 2700 },
    ]);
    assert.ok(app.devices[1]!.kind.kind === "light" && app.devices[1]!.kind.isOn);
    assert.equal(app.devices[1]!.kind.brightnessPercent, 15);
    assert.ok(document.querySelector("#btn-undo"));

    sent.length = 0;
    await click("#btn-undo");
    await setImmediate();

    assert.deepEqual(sent, [{ kind: "setLightPower", entityId: "light.l2", isOn: false }]);
    assert.ok(app.devices[1]!.kind.kind === "light");
    assert.equal(app.devices[1]!.kind.isOn, false);
    assert.equal(app.devices[1]!.kind.brightnessPercent, 65);
    assert.equal(app.devices[1]!.kind.colorTempKelvin, 4800);
  });
});

describe("AI /chat/completions context, multi-device JEV & suggestion chips (#2)", () => {
  it("passes AssistantContext into /chat/completions system prompt and parses chat: suggestion chips", async () => {
    const devices = [
      makeLight({ id: "light.study", name: "书房吸顶灯", isOn: true, brightnessPercent: 80 }),
      makeClimate({ id: "climate.bedroom", name: "主卧空调", isOn: false, hvacMode: "off" }),
    ];
    let capturedBody: Record<string, unknown> | null = null;
    const resolver = new ModelIntentResolver(
      {
        baseURL: "http://localhost:1234/v1",
        model: "qwen-local",
        apiKey: "",
      },
      async (req) => {
        capturedBody = JSON.parse(req.body ?? "{}") as Record<string, unknown>;
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            choices: [
              {
                message: {
                  content: JSON.stringify({
                    reply: "已为您调暗书房灯",
                    actions: [{ device: "d1", op: "brightness", value: 30 }],
                    suggestions: [
                      { device: "d2", op: "power", value: true, confidence: 0.64 },
                      { device: "d1", op: "power", value: false, confidence: 0.7 },
                    ],
                  }),
                },
              },
            ],
          }),
        };
      },
    );

    const context = buildAssistantContext({
      now: new Date("2026-07-15T21:30:00+08:00"),
      readings: [{ id: "env1", label: "主卧温湿度", roomName: "主卧", temperature: 30.2, humidity: 66, battery: null }],
      devices,
      scenes: [],
      sharing: "on",
      memory: new UserHabitMemory([
        { bucket: "夜晚", targetId: "light.study", operationKey: "brightness:30", count: 5 },
      ]),
      phrases: [],
      mention: { kind: "utterance", text: "准备看书，主卧有点热" },
    });

    const plan = await resolver.resolve("准备看书，主卧有点热", devices, [], context);
    assert.ok(capturedBody);
    const messages = capturedBody["messages"] as Array<{ role: string; content: string }>;
    const systemPrompt = messages[0]?.content ?? "";
    assert.match(systemPrompt, /当前环境与习惯：/);
    assert.match(systemPrompt, /30\.2/);
    assert.match(systemPrompt, /书房吸顶灯/);

    assert.equal(plan.intents.length, 1);
    assert.equal(plan.intents[0]?.targetId, "light.study");
    // d1 is excluded from suggestions because it already auto-executed; d2 surfaces as a chat: chip.
    assert.equal(plan.suggestions.length, 1);
    assert.equal(plan.suggestions[0]?.id, "chat:climate.bedroom:0");
    assert.equal(plan.suggestions[0]?.confidencePercent, 64);
  });

  it("parses multi-device JEV dev_d1..dev_dN headers, skips fallback power:on, and emits jev: chips", () => {
    const d1 = makeLight({ id: "l1", name: "客厅主灯", isOn: false, availableEffects: ["Day", "Night"] });
    const d2 = makeClimate({ id: "c1", name: "客厅空调", isOn: false, hvacMode: "off" });
    const d3 = makeLight({ id: "l2", name: "走廊灯", isOn: false });
    const devices = [d1, d2, d3];
    const catalog = buildIntentCatalog(devices, []);

    const plan = ModelIntentResolver.planFromSystemOne(
      JSON.stringify({
        answers: {
          target: { choice: "d1", probabilities: { d1: 0.92, none: 0.08 } },
          op: { choice: "effect_night", probabilities: { effect_night: 0.9 } },
          temp: { choice: "none", probabilities: { none: 1 } },
          dev_d2: { choice: "cool_25", probabilities: { cool_25: 0.85, none: 0.15 } },
          dev_d3: { choice: "power_on", probabilities: { power_on: 0.62, none: 0.38 } },
        },
      }),
      catalog,
      devices,
      [],
    );

    assert.deepEqual(plan.intents, [
      { targetId: "l1", operation: { kind: "lightEffect", effect: "Night" } },
      { targetId: "c1", operation: { kind: "hvacMode", mode: "cool" } },
      { targetId: "c1", operation: { kind: "targetTemperature", celsius: 25 } },
    ]);
    // d3's fallback power_on (when primary op is effect_night) is held back as a jev: chip instead of auto-executing.
    assert.equal(plan.suggestions.length, 1);
    assert.equal(plan.suggestions[0]?.id, "jev:l2:power_on");
    assert.equal(plan.suggestions[0]?.confidencePercent, 62);
  });

  it("normalizes Chinese light-effect aliases, HVAC mode aliases, and unknown brightness step base 100", () => {
    const lamp = makeLight({
      isOn: true,
      brightnessPercent: null,
      availableEffects: ["Day", "Night"],
    });
    assert.deepEqual(
      IntentValidator.normalize({ kind: "lightEffect", effect: "月光" }, lamp),
      { kind: "lightEffect", effect: "Night" },
    );
    assert.deepEqual(
      IntentValidator.normalize({ kind: "lightEffect", effect: "日光模式" }, lamp),
      { kind: "lightEffect", effect: "Day" },
    );
    // HA lights advertising literal "Moonlight" / "Daylight" keep their advertised effect names.
    const haLamp = makeLight({
      isOn: true,
      availableEffects: ["Moonlight", "Daylight"],
    });
    assert.deepEqual(
      IntentValidator.normalize({ kind: "lightEffect", effect: "Moonlight" }, haLamp),
      { kind: "lightEffect", effect: "Moonlight" },
    );
    assert.deepEqual(
      IntentValidator.normalize({ kind: "lightEffect", effect: "Daylight" }, haLamp),
      { kind: "lightEffect", effect: "Daylight" },
    );
    assert.deepEqual(
      IntentValidator.normalize({ kind: "brightnessStep", delta: -20 }, lamp),
      { kind: "brightness", percent: 80 },
    );

    const ac = makeClimate({ isOn: true, hvacMode: "cool" });
    assert.deepEqual(
      IntentValidator.normalize({ kind: "hvacMode", mode: "fan" }, ac),
      { kind: "hvacMode", mode: "fan_only" },
    );
    assert.deepEqual(
      IntentValidator.normalize({ kind: "hvacMode", mode: "heat_cool" }, ac),
      { kind: "hvacMode", mode: "auto" },
    );
    const haAc = makeClimate({
      isOn: true,
      hvacMode: "cool",
      availableModes: ["off", "cool", "heat_cool", "fan"],
    });
    assert.deepEqual(
      IntentValidator.normalize({ kind: "hvacMode", mode: "fan" }, haAc),
      { kind: "hvacMode", mode: "fan" },
    );
    assert.deepEqual(
      IntentValidator.normalize({ kind: "hvacMode", mode: "heat_cool" }, haAc),
      { kind: "hvacMode", mode: "heat_cool" },
    );
  });
});

describe("Concurrent multi-device intent execution & vacuum undo (#2)", () => {
  it("dispatches multi-device intents concurrently via Promise.allSettled and populates vacuum undo", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const l1 = makeLight({ id: "l1", name: "书房灯", isOn: true });
    const vac = makeVacuum("docked");
    app.devices = [l1, vac];

    assert.deepEqual(
      inverseCommands(vac, { kind: "vacuumAction", entityId: "vacuum.main", action: "start" }),
      [{ kind: "vacuumAction", entityId: "vacuum.main", action: "returnToBase" }],
    );
    assert.deepEqual(
      inverseCommands(makeVacuum("cleaning"), {
        kind: "vacuumAction",
        entityId: "vacuum.main",
        action: "returnToBase",
      }),
      [{ kind: "vacuumAction", entityId: "vacuum.main", action: "start" }],
    );

    const secondStarted = deferred<void>();
    const releaseFirst = deferred<void>();
    const startedOrder: string[] = [];

    app.applyCommand = async (cmd) => {
      startedOrder.push(cmd.entityId);
      if (cmd.entityId === "light.l1") {
        // Would deadlock under serial for..of if vacuum.main had not started concurrently!
        await secondStarted.promise;
        await releaseFirst.promise;
      } else if (cmd.entityId === "vacuum.main") {
        secondStarted.resolve();
      }
      return true;
    };

    const execPromise = app.executeIntents(
      [
        { targetId: "l1", operation: { kind: "power", isOn: false } },
        { targetId: "vacuum.main", operation: { kind: "power", isOn: true } },
      ],
      "已联动书房灯与扫地机",
      "Jev SystemOne",
    );

    await secondStarted.promise;
    assert.deepEqual(startedOrder, ["light.l1", "vacuum.main"]);
    releaseFirst.resolve();

    const ok = await execPromise;
    assert.equal(ok, true);
    assert.ok(app.lastUndoAction);
    assert.equal(app.lastUndoAction.steps.length, 2);
    assert.deepEqual(app.lastUndoAction.steps[0]?.commands, [
      { kind: "vacuumAction", entityId: "vacuum.main", action: "returnToBase" },
    ]);
  });
});

describe("Proactive favorites/aliases, collapsed assistant bar & missed timers (#2)", () => {
  it("applies favoriteIds and custom aliases in proactive suggestions and surfaces chips when GrokBall is off or collapsed", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.devices = [
      makeLight({ id: "l1", name: "原始灯名", isOn: false }),
      makeLight({ id: "l2", name: "次要灯", isOn: false }),
    ];
    app.layout.aliases["l1"] = "老杨阅读灯";
    app.layout.groups = [{ id: "g_fav", name: "常用置顶" }];
    app.layout.groupMap["l1"] = "g_fav";
    app.isShowingAssistantBar = true;
    app.render();

    const barChips = [...document.querySelectorAll<HTMLElement>("[data-proactive-bar] [data-proactive-id]")];
    assert.ok(barChips.length > 0);
    assert.equal(barChips[0]?.dataset.proactiveId, "fav:l1:on");
    assert.match(barChips[0]?.textContent ?? "", /老杨阅读灯/);

    // Expanding GrokBall moves proactive pills to .cc-grok-stage without duplicating them in assistantExtras.
    app.settings.enableGrokBall = true;
    app.isGrokBallStageExpanded = true;
    app.render();
    assertMissing(document.querySelector("[data-proactive-bar]"));
    assert.ok(document.querySelector(".cc-grok-stage [data-proactive-id]"));
  });

  it("keeps missedScheduledCommands visible even when !isShowingAssistantBar", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.isShowingAssistantBar = false;
    app.missedScheduledCommands = [
      {
        id: "missed-1",
        command: "关闭主卧空调",
        delaySeconds: 600,
        fireTimestampMs: Date.now() - 30_000,
        reply: "10分钟后：关闭主卧空调",
        intents: [{ targetId: "climate.bedroom", operation: { kind: "power", isOn: false } }],
      },
    ];
    app.render();

    const runBtn = document.querySelector<HTMLElement>('[data-run-missed="missed-1"]');
    assert.ok(runBtn, "missed timer action must remain visible while assistant bar is collapsed");
    assert.match(document.body.textContent ?? "", /已错过定时：关闭主卧空调/);
  });
});

describe("Mi session Set-Cookie expiry, 3-day warning & Sign Out (#3)", () => {
  it("parses serviceToken Max-Age / Expires, keeps undated sessions valid, and round-trips expiresAt in CredentialVault", async () => {
    const nowMs = Date.UTC(2026, 10, 11, 12, 0, 0);
    const fromMaxAge = MiAccountLogin.parseServiceTokenCookie(
      {
        "Set-Cookie":
          "serviceToken=tok_abc; Path=/; Max-Age=7200; Expires=Wed, 01-Jan-2099 00:00:00 GMT; Secure",
      },
      nowMs,
    );
    assert.deepEqual(fromMaxAge, { token: "tok_abc", expiresAt: nowMs + 7_200_000 });

    const fromExpires = MiAccountLogin.parseServiceTokenCookie(
      {
        "set-cookie": "userId=100; Path=/\nserviceToken=tok_exp; Expires=Thu, 12-Nov-2026 12:00:00 GMT; Path=/",
      },
      nowMs,
    );
    assert.deepEqual(fromExpires, {
      token: "tok_exp",
      expiresAt: Date.UTC(2026, 10, 12, 12, 0, 0),
    });

    // native_http joins repeated Set-Cookie headers with "; " on a single line.
    const fromFlattened = MiAccountLogin.parseServiceTokenCookie(
      {
        "set-cookie":
          "userId=100; Max-Age=60; Path=/; serviceToken=tok_flat; Max-Age=3600; Path=/; cUserId=abc; Max-Age=10",
      },
      nowMs,
    );
    assert.deepEqual(fromFlattened, { token: "tok_flat", expiresAt: nowMs + 3_600_000 });
    assert.deepEqual(
      MiAccountLogin.parseServiceTokenCookie(
        { "set-cookie": "userId=100; Path=/; serviceToken=tok_bare; Path=/" },
        nowMs,
      ),
      { token: "tok_bare" },
    );

    const undated = parseMiSession({
      userId: "100",
      cUserId: "",
      ssecurity: "sec",
      serviceToken: "tok",
      passToken: "",
      region: "cn",
    });
    assert.ok(undated);
    assert.equal(undated.expiresAt, undefined);
    assert.deepEqual(miSessionExpiryState(undated, nowMs), { kind: "valid" });

    const expiringSession = { ...undated, expiresAt: nowMs + MI_SESSION_WARNING_LEAD_MS - 1_000 };
    assert.deepEqual(miSessionExpiryState(expiringSession, nowMs), {
      kind: "expiringSoon",
      expiresAtMs: expiringSession.expiresAt,
    });
    const roundTripped = parseMiSession(JSON.parse(serializeMiSession(expiringSession)));
    assert.equal(roundTripped?.expiresAt, expiringSession.expiresAt);

    const vaultMap = new Map<string, string>();
    const vault = new CredentialVault(async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
      const name = String(args["name"] ?? "");
      if (cmd === "secure_store_get") return (vaultMap.get(name) ?? null) as T | null;
      if (cmd === "secure_store_set") vaultMap.set(name, String(args["value"] ?? ""));
      if (cmd === "secure_store_delete") vaultMap.delete(name);
      return null;
    });
    await vault.persist({ miSession: expiringSession, haToken: "", assistantApiKey: "" });
    const loaded = await vault.load();
    assert.equal(loaded.miSession?.expiresAt, expiringSession.expiresAt);
  });

  it("renders 3-day expiry warning banner and clears memory, localStorage, CredentialVault, and hidden Xiaomi camera streams on Sign Out", async () => {
    const deletedSecrets: string[] = [];
    const bridgeStoppedDids: string[] = [];
    const httpUrls: string[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "secure_store_delete") deletedSecrets.push(String(args["name"] ?? ""));
      if (name === "stop_xiaomi_camera_bridge") bridgeStoppedDids.push(String(args["did"] ?? ""));
      if (name === "native_http") {
        const url = String(args["url"] ?? "");
        httpUrls.push(url);
        return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result: { list: [], homelist: [] } }) };
      }
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });

    const camDevice: SmartDevice = {
      id: "cam-1",
      name: "玄关摄像机",
      roomId: "room_entry",
      roomName: "玄关",
      model: "chuangmi.camera.ipc019",
      isOnline: true,
      kind: {
        kind: "camera",
        entityId: "camera.cam_1",
        isOn: true,
        nightShot: "auto",
        availableNightShots: ["auto", "off", "on"],
        motionDetectionEntityId: null,
        isMotionDetectionOn: null,
        streamEntityId: null,
      },
    };
    const soonMs = Date.now() + 24 * 3600 * 1000;
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        cachedXiaomiDevices: [makeLight({ id: "cached-1" }), camDevice],
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.specResolver.resolve = async () => ({
      type: "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-ipc019:1",
      description: "Camera",
      services: [
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:stream-p2p:00007881:chuangmi-ipc019:1",
          description: "P2P",
          properties: [],
          actions: [
            {
              iid: 2,
              type: "urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-ipc019:1",
              description: "Stop Stream",
              in: [],
              out: [],
            },
          ],
        },
      ],
    });
    app.settings.miSession = {
      userId: "98765432",
      cUserId: "",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok_soon",
      passToken: "",
      region: "cn",
      expiresAt: soonMs,
    };
    app.devices = [makeLight({ id: "cached-1" }), camDevice];
    // Simulate a Xiaomi camera hidden in its 120-second keep-alive window when Sign Out happens.
    const camAbort = new AbortController();
    app.cameraLive.activeLiveCameraId = "cam-1";
    app.cameraLive.liveCameraHidden = true;
    app.cameraLive.liveCameraAbort = camAbort;
    app.cameraLive.liveCameraKeepAliveTimer = window.setTimeout(() => {}, 120_000);
    app.lastManuallyUsedLightId = "cached-1";
    app.lastUndoAction = {
      summary: "已关灯",
      steps: [{ deviceId: "cached-1", commands: [{ kind: "setLightPower", entityId: "light.cached-1", isOn: true }] }],
      expiresAtMs: Date.now() + 60_000,
    };
    app.render();

    assert.ok(document.querySelector("[data-mi-expiry-warning]"), "3-day expiry banner should show");

    httpUrls.length = 0;
    await click("#btn-settings");
    await click('[data-settings-tab="connection"]');
    assert.ok(document.querySelector("#btn-signout-mi"));
    await click("#btn-signout-mi");
    await Promise.all([...app.cameraLive.pendingCameraReleases.values()]);
    await setImmediate();

    assert.equal(app.settings.miSession, null);
    assert.equal(app.devices.length, 0);
    assert.equal(app.settings.cachedXiaomiDevices.length, 0);
    assert.equal(app.lastUndoAction, null);
    assert.equal(app.lastManuallyUsedLightId, null);
    assert.equal(app.cameraLive.activeLiveCameraId, null);
    assert.equal(app.cameraLive.liveCameraHidden, false);
    assert.equal(app.cameraLive.liveCameraKeepAliveTimer, null);
    assert.equal(camAbort.signal.aborted, true);
    assert.deepEqual(bridgeStoppedDids, ["cam-1"]);
    assert.ok(
      httpUrls.some((url) => url.includes("/miotspec/action")),
      "authenticated P2P stop-stream action must fire with captured session before credentials clear",
    );
    assert.ok(deletedSecrets.includes("mi_session"));
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as Record<string, unknown>;
    assert.equal(stored["miSession"], undefined);
    assert.deepEqual(stored["cachedXiaomiDevices"], []);

    // Signing out of a stored Mi session while running in demo/HA mode preserves active source undo state.
    app.settings.connectionMode = "demo";
    app.settings.miSession = {
      userId: "98765432",
      cUserId: "",
      ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
      serviceToken: "tok_again",
      passToken: "",
      region: "cn",
    };
    const demoUndo = {
      summary: "演示模式操作",
      steps: [{ deviceId: "light.study_desk", commands: [{ kind: "setLightPower" as const, entityId: "light.study_desk", isOn: true }] }],
      expiresAtMs: Date.now() + 60_000,
    };
    app.lastUndoAction = demoUndo;
    app.signOutXiaomiAccount();
    assert.equal(app.settings.miSession, null);
    assert.equal(app.lastUndoAction, demoUndo);
  });
});

describe("Demo offline guard, credential error banner, mic pin guard & hover pause (#3)", () => {
  it("skips GitHub update network requests in demo mode and surfaces credential persistence failures", async () => {
    let httpCalls = 0;
    let rejectSecretWrite = false;
    const invoke = async (name: string): Promise<unknown> => {
      if (name === "native_http") {
        httpCalls += 1;
        return { status: 200, headers: {}, body: "{}" };
      }
      if (name === "secure_store_set" && rejectSecretWrite) {
        throw new Error("Vault locked");
      }
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.removeItem("menumijia.windows.update.v1");
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.equal(httpCalls, 0, "startup auto-check must not hit network in demo mode");

    await app.checkForAppUpdate(true);
    assert.equal(httpCalls, 0, "manual check must not hit network in demo mode");
    assert.match(app.updateStatusMessage?.text ?? "", /演示模式/);

    rejectSecretWrite = true;
    app.settings.haToken = "secret-ha-token";
    app.saveSettings();
    await setImmediate();
    await setImmediate();

    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /凭据/);
    const storedRaw = localStorage.getItem(STORAGE_KEY) ?? "";
    assert.doesNotMatch(storedRaw, /secret-ha-token/);
  });

  it("pins popover while speech recognition is active and unpins on end/error/abort unless a sheet keeps it pinned", async () => {
    const pinCalls: boolean[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "set_pin_popover") pinCalls.push(Boolean(args["pin"]));
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });

    let activeInstance: SpeechRecognitionInstance | null = null;
    class FakeSpeechRecognition implements SpeechRecognitionInstance {
      lang = "";
      interimResults = false;
      continuous = false;
      onresult: SpeechRecognitionInstance["onresult"] = null;
      onerror: SpeechRecognitionInstance["onerror"] = null;
      onend: SpeechRecognitionInstance["onend"] = null;
      start(): void {
        // set_pin_popover(true) must ALREADY have fired before start() triggers OS mic permission UI!
        assert.equal(pinCalls.at(-1), true);
        activeInstance = this;
      }
      stop(): void {
        this.onend?.();
      }
    }
    window.SpeechRecognition = FakeSpeechRecognition;

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));

    await click("#btn-mic");
    assert.equal(app.isListeningVoice, true);
    assert.deepEqual(pinCalls, [true]);

    activeInstance!.onerror?.({ error: "not-allowed" });
    assert.equal(app.isListeningVoice, false);
    assert.deepEqual(pinCalls, [true, false]);

    // If a sheet opens while dictating, ending speech must keep the popover pinned for the sheet.
    pinCalls.length = 0;
    await click("#btn-mic");
    app.openSettingsSheet();
    activeInstance!.onend?.();
    assert.equal(app.isListeningVoice, false);
    assert.equal(pinCalls.at(-1), true);
  });

  it("pauses undo countdown while pointer hovers .cc-live-banner and always resumes on leave or blur", async () => {
    const realNow = Date.now;
    let fakeNow = 1_700_000_000_000;
    Date.now = () => fakeNow;
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
      );
      const app = new MenuMijiaWindowsApp(element("#app"));
      app.replyBanner = { text: "已关闭书房吸顶灯", source: "实时控制" };
      app.lastUndoAction = {
        summary: "已关闭书房吸顶灯",
        steps: [
          {
            deviceId: "light.study_desk",
            commands: [{ kind: "setLightPower", entityId: "light.study_desk", isOn: true }],
          },
        ],
        expiresAtMs: fakeNow + 10 * 60 * 1000,
      };
      app.render();
      assert.ok(document.querySelector("#btn-undo"));

      // Advance 4 seconds (6s left on 10s banner), then hover .cc-live-banner.
      fakeNow += 4_000;
      const banner = element(".cc-live-banner");
      banner.dispatchEvent(new window.Event("pointerenter"));

      // Stay hovered for 12 minutes (past both the 10s banner and the 10m undo window!).
      fakeNow += 12 * 60 * 1000;
      app.render();
      assert.ok(document.querySelector("#btn-undo"), "undo button stays visible while banner is hovered");

      // Leaving the banner shifts deadlines to fakeNow + remaining (6s banner, 9m56s action).
      element(".cc-live-banner").dispatchEvent(new window.Event("pointerleave"));
      fakeNow += 5_000;
      assert.equal(app.undoButtonVisible(fakeNow), true, "still within remaining 6s after leave");
      fakeNow += 2_000;
      assert.equal(app.undoButtonVisible(fakeNow), false, "expires once remaining 6s elapses");
      assert.ok(app.lastUndoAction && app.lastUndoAction.expiresAtMs > fakeNow);

      // Re-hovering and losing window focus (blur) also resumes the countdown cleanly.
      app.lastUndoAction = {
        summary: "第二次操作",
        steps: [
          {
            deviceId: "light.study_desk",
            commands: [{ kind: "setLightPower", entityId: "light.study_desk", isOn: true }],
          },
        ],
        expiresAtMs: fakeNow + 10 * 60 * 1000,
      };
      app.render();
      element(".cc-live-banner").dispatchEvent(new window.Event("pointerenter"));
      fakeNow += 20_000;
      window.dispatchEvent(new window.Event("blur"));
      assert.equal(app.undoButtonVisible(fakeNow + 5_000), true);
      assert.equal(app.undoButtonVisible(fakeNow + 11_000), false);
    } finally {
      Date.now = realNow;
    }
  });
});
