import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudError, type HttpTransport, type MiSession } from "../src/core/miCloud/session.js";
import { parseMiotDeviceSpec, type MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import {
  SPEAKER_TEXT_MAX_LENGTH,
  buildSpeakerTextCommand,
  normalizeSpeakerText,
  resolveSpeakerActionIds,
} from "../src/core/miCloud/speakerActions.js";
import { MiotCommandMapper } from "../src/core/miCloud/command.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import type { FacetControl, SmartDevice } from "../src/core/models.js";
import {
  cancelDelayedReadBack,
  isOptimisticallyLocked,
  lockOptimistic,
} from "../src/core/optimisticLock.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import {
  ECHO_READ_BACK_DELAY_MS,
  MIOT_PROPERTY_UNSUPPORTED_CODE,
  applyCommand,
  cancelEchoReadBack,
  filterSupportedLightEffects,
  hasPendingEchoReadBack,
  isLightEffectUnsupported,
  scheduleEchoReadBack,
} from "../src/ui/commandDispatch.js";

const soundProFixtureRaw = JSON.parse(
  readFileSync(resolve(process.cwd(), "../Tests/Fixtures/miot/xiaomi.wifispeaker.l17a.json"), "utf8"),
) as unknown;

function loadSoundProSpec(): MiotDeviceSpec {
  const spec = parseMiotDeviceSpec(soundProFixtureRaw);
  assert.ok(spec, "xiaomi.wifispeaker.l17a fixture must parse");
  return spec;
}

const TEST_MI_SESSION: MiSession = {
  userId: "10001",
  serviceToken: "test-service-token",
  ssecurity: Buffer.alloc(16, 7).toString("base64"),
  passToken: "",
  cUserId: "c_10001",
  region: "cn",
};

function stubMiCloudRuntime(
  app: MenuMijiaWindowsApp,
  specsByModel: Readonly<Record<string, MiotDeviceSpec>>,
  transport: HttpTransport,
): void {
  const mockResolver: Pick<
    MenuMijiaWindowsApp["specResolver"],
    "resolve" | "resolveForDevices" | "exportCachedSpecs" | "exportKnownModelTypes"
  > = {
    resolve: async (rec: { readonly model: string }) => specsByModel[rec.model]!,
    resolveForDevices: async () => ({ ...specsByModel }),
    exportCachedSpecs: () => ({ ...specsByModel }),
    exportKnownModelTypes: () => ({}),
  };
  const runtimeApp = app as unknown as {
    transport: HttpTransport;
    specResolver: typeof mockResolver;
  };
  runtimeApp.transport = transport;
  runtimeApp.specResolver = mockResolver;
}

function decodeMiFormParams(body: string): { path: string; dataJson: Record<string, unknown> } {
  const form = new URLSearchParams(body);
  const nonce = form.get("_nonce") ?? "";
  const dataEnc = form.get("data") ?? "";
  const signed = MiCloudCrypto.signedNonce(TEST_MI_SESSION.ssecurity, nonce);
  const decrypted = MiCloudCrypto.decryptResponse(dataEnc, signed);
  return {
    path: "",
    dataJson: JSON.parse(decrypted) as Record<string, unknown>,
  };
}

function encodeMiResponse(_body: string, payload: unknown): string {
  return JSON.stringify(payload);
}

let dom: Window | null = null;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

beforeEach(() => {
  setLanguage("zh-Hans");
  dom = mountTestWindow();
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

describe("Wave 2 A4: Xiaomi XiaoAi speaker TTS & silent directive synthesis and command mapping", () => {
  it("synthesizes ttsActionId and directiveActionId on Sound Pro without altering polled requiredProps", () => {
    const spec = loadSoundProSpec();
    const record = {
      did: "sp_pro",
      name: "客厅小爱音箱",
      model: "xiaomi.wifispeaker.l17a",
      isOnline: true,
      specType: spec.type,
    };
    const values = new Map<string, unknown>([
      ["sp_pro.2.1", 37],
      ["sp_pro.2.2", true],
      ["sp_pro.3.1", 1],
      ["sp_pro.7.3", false],
    ]);
    const home = MiotSynthesizer.synthesize([record], [], { [record.model]: spec }, values);
    assert.equal(home.devices.length, 1);
    const kind = home.devices[0]!.kind;
    assert.equal(kind.kind, "speaker");
    if (kind.kind !== "speaker") return;

    assert.equal(kind.ttsActionId, "miot-action:sp_pro:7:3");
    assert.equal(kind.directiveActionId, "miot-action:sp_pro:7:4");
    assert.equal(kind.volumePercent, 37);
    assert.equal(kind.isMuted, true);
    assert.equal(kind.state, "playing");

    const required = MiotSynthesizer.requiredProps(record, spec).map((k) => `${k.did}.${k.siid}.${k.piid}`);
    assert.ok(!required.includes("sp_pro.7.1"));
    assert.ok(!required.includes("sp_pro.7.2"));
  });

  it("supports speaker-service fallback, single-param directive, and 0-param text directive specs", () => {
    const speakerServiceSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:speaker:0000A015:xiaomi-mini:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:speaker:0000781C:xiaomi-mini:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:volume:00000013:xiaomi-mini:1", format: "uint8", access: ["read", "write"], valueRange: [0, 100, 1] },
            { iid: 5, type: "urn:miot-spec-v2:property:text-content:000000FA:xiaomi-mini:1", format: "string", access: [] },
          ],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:play-text:00002841:xiaomi-mini:1", in: [5] },
            { iid: 2, type: "urn:miot-spec-v2:action:execute-text-directive:00002842:xiaomi-mini:1", in: [] },
          ],
        },
      ],
    };

    const resolved = resolveSpeakerActionIds("sp_mini", speakerServiceSpec);
    assert.deepEqual(resolved, {
      ttsActionId: "miot-action:sp_mini:2:1",
      directiveActionId: "miot-action:sp_mini:2:2",
    });

    const ttsWrite = MiotCommandMapper.map(
      buildSpeakerTextCommand(resolved.ttsActionId!, "  欢迎回家  "),
      speakerServiceSpec,
    );
    assert.deepEqual(ttsWrite, {
      kind: "action",
      call: { did: "sp_mini", siid: 2, aiid: 1, inputs: ["欢迎回家"] },
    });

    const zeroInDirectiveWrite = MiotCommandMapper.map(
      buildSpeakerTextCommand(resolved.directiveActionId!, " \t关掉卧室灯\n "),
      speakerServiceSpec,
    );
    assert.deepEqual(zeroInDirectiveWrite, {
      kind: "action",
      call: { did: "sp_mini", siid: 2, aiid: 2, inputs: ["关掉卧室灯"] },
    });
  });

  it("trims whitespace, populates silent-execution, and rejects empty or oversized text", () => {
    const spec = loadSoundProSpec();
    const ttsCmd = buildSpeakerTextCommand("miot-action:sp_pro:7:3", "  早上好，今天晴天  ");
    assert.deepEqual(MiotCommandMapper.map(ttsCmd, spec), {
      kind: "action",
      call: { did: "sp_pro", siid: 7, aiid: 3, inputs: ["早上好，今天晴天"] },
    });

    const silentDirectiveCmd = buildSpeakerTextCommand("miot-action:sp_pro:7:4", " 打开客厅空调 ");
    assert.deepEqual(MiotCommandMapper.map(silentDirectiveCmd, spec), {
      kind: "action",
      call: { did: "sp_pro", siid: 7, aiid: 4, inputs: ["打开客厅空调", true] },
    });

    const audibleDirectiveCmd = buildSpeakerTextCommand("miot-action:sp_pro:7:4", "查询天气", {
      silent: false,
    });
    assert.deepEqual(MiotCommandMapper.map(audibleDirectiveCmd, spec), {
      kind: "action",
      call: { did: "sp_pro", siid: 7, aiid: 4, inputs: ["查询天气", false] },
    });

    assert.throws(() => normalizeSpeakerText("   \n\t  "), /empty/i);
    assert.throws(
      () => normalizeSpeakerText("测".repeat(SPEAKER_TEXT_MAX_LENGTH + 1)),
      /maximum length/i,
    );
    assert.throws(
      () =>
        MiotCommandMapper.map(
          { kind: "pressButton", entityId: "miot-action:sp_pro:7:4", arguments: ["   "] },
          spec,
        ),
      /empty/i,
    );

    const incompatible: MiotDeviceSpec = {
      ...spec,
      services: spec.services.map((s) =>
        s.iid === 7
          ? {
              ...s,
              actions: s.actions.map((a) => (a.iid === 4 ? { ...a, in: [2, 1] } : a)),
            }
          : s,
      ),
    };
    assert.throws(
      () =>
        MiotCommandMapper.map(
          { kind: "pressButton", entityId: "miot-action:sp_pro:7:4", arguments: ["打开灯"] },
          incompatible,
        ),
      /Unsupported speaker action inputs/,
    );
  });
});

describe("Wave 2 A4: Speaker dual-mode drawer UI & Xiaomi Cloud action dispatch", () => {
  async function mountSpeakerApp(devices: SmartDevice[], specsByModel: Record<string, MiotDeviceSpec>) {
    const actionCalls: Array<Record<string, unknown>> = [];
    const transport: HttpTransport = async (req) => {
      const { dataJson } = decodeMiFormParams(req.body ?? "");
      if (req.url.endsWith("/miotspec/action")) {
        const params = dataJson.params as Record<string, unknown>;
        actionCalls.push(params);
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", { code: 0, result: { code: 0, out: [] } }),
        };
      }
      return {
        status: 200,
        headers: {},
        body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
      };
    };

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: devices,
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, specsByModel, transport);
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = structuredClone(devices);
    app.render();
    await setImmediate();
    return { app, actionCalls };
  }

  it("renders toggleable Speak/Command pills, submits via Enter & Send button, clears input, and localizes in 3 languages", async () => {
    const spec = loadSoundProSpec();
    const speakerDev: SmartDevice = {
      id: "sp_pro",
      name: "客厅小爱",
      roomId: "room_living",
      roomName: "客厅",
      model: "xiaomi.wifispeaker.l17a",
      isOnline: true,
      kind: {
        kind: "speaker",
        mediaEntityId: "miot:sp_pro:2",
        state: "idle",
        volumePercent: 35,
        isMuted: false,
        muteSwitchEntityId: "miot:sp_pro:2",
        sleepModeEntityId: "miot:sp_pro:7",
        isSleepMode: false,
        volumeWritable: true,
        ttsActionId: "miot-action:sp_pro:7:3",
        directiveActionId: "miot-action:sp_pro:7:4",
      },
    };

    const { app, actionCalls } = await mountSpeakerApp([speakerDev], {
      "xiaomi.wifispeaker.l17a": spec,
    });

    app.expandedDeviceId = "sp_pro";
    app.render();

    const ttsPill = element<HTMLButtonElement>('[data-speaker-mode="sp_pro|tts"]');
    const directivePill = element<HTMLButtonElement>('[data-speaker-mode="sp_pro|directive"]');
    const input = element<HTMLInputElement>('[data-speaker-input="sp_pro"]');
    const sendBtn = element<HTMLButtonElement>('[data-speaker-send="sp_pro"]');

    assert.equal(ttsPill.textContent, "播报");
    assert.equal(directivePill.textContent, "指令");
    assert.equal(ttsPill.classList.contains("is-active"), true);
    assert.equal(sendBtn.disabled, true);

    directivePill.click();
    assert.equal(directivePill.classList.contains("is-active"), true);
    assert.equal(ttsPill.classList.contains("is-active"), false);

    input.focus();
    input.value = "  把书房灯关掉  ";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(sendBtn.disabled, false);

    input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    await setImmediate();
    await setImmediate();

    assert.equal(actionCalls.length, 1);
    assert.deepEqual(actionCalls[0], {
      did: "sp_pro",
      siid: 7,
      aiid: 4,
      in: ["把书房灯关掉", true],
    });
    const refreshedInput = element<HTMLInputElement>('[data-speaker-input="sp_pro"]');
    assert.equal(refreshedInput.value, "", "input box must clear after Enter submit");
    assert.match(app.replyBanner?.text ?? "", /已向客厅小爱下发指令：「把书房灯关掉」/);

    setLanguage("en");
    app.render();
    const ttsPillEn = element<HTMLButtonElement>('[data-speaker-mode="sp_pro|tts"]');
    ttsPillEn.click();
    const inputEn = element<HTMLInputElement>('[data-speaker-input="sp_pro"]');
    const sendBtnEn = element<HTMLButtonElement>('[data-speaker-send="sp_pro"]');
    assert.equal(ttsPillEn.textContent, "Speak");
    assert.equal(sendBtnEn.textContent, "Send");

    inputEn.value = "  Dinner is ready  ";
    inputEn.dispatchEvent(new window.Event("input", { bubbles: true }));
    sendBtnEn.click();
    await setImmediate();
    await setImmediate();

    assert.equal(actionCalls.length, 2);
    assert.deepEqual(actionCalls[1], {
      did: "sp_pro",
      siid: 7,
      aiid: 3,
      in: ["Dinner is ready"],
    });
    assert.equal(element<HTMLInputElement>('[data-speaker-input="sp_pro"]').value, "");
    assert.equal(app.replyBanner?.text, '客厅小爱 announced: "Dinner is ready"');

    setLanguage("zh-Hant");
    app.render();
    assert.equal(element('[data-speaker-mode="sp_pro|tts"]').textContent, "播報");
    assert.equal(element('[data-speaker-send="sp_pro"]').textContent, "發送");

    cancelDelayedReadBack(app);
    cancelEchoReadBack(app);
  });

  it("renders a fixed single-mode badge when only ttsActionId is available, even on read-only volume speakers", async () => {
    const spec = loadSoundProSpec();
    const ttsOnlySpeaker: SmartDevice = {
      id: "sp_tts_only",
      name: "卧室音箱",
      roomId: "room_bed",
      roomName: "卧室",
      model: "xiaomi.wifispeaker.l17a",
      isOnline: true,
      kind: {
        kind: "speaker",
        mediaEntityId: "miot:sp_tts_only:2",
        state: "idle",
        volumePercent: 20,
        isMuted: false,
        muteSwitchEntityId: null,
        sleepModeEntityId: null,
        isSleepMode: false,
        volumeWritable: false,
        ttsActionId: "miot-action:sp_tts_only:7:3",
        directiveActionId: null,
      },
    };

    const { app, actionCalls } = await mountSpeakerApp(
      [{ ...ttsOnlySpeaker, isOnline: false }],
      {
        "xiaomi.wifispeaker.l17a": spec,
      },
    );

    element('[data-body-device="sp_tts_only"]').click();
    const fixedBadge = element<HTMLButtonElement>('[data-speaker-mode-fixed="sp_tts_only|tts"]');
    assert.equal(fixedBadge.disabled, true);
    assert.equal(document.querySelectorAll("[data-speaker-mode]").length, 0);

    app.devices = [{ ...ttsOnlySpeaker, isOnline: true }];
    const input = element<HTMLInputElement>('[data-speaker-input="sp_tts_only"]');
    input.disabled = false;
    input.value = "晚安";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(element<HTMLButtonElement>('[data-speaker-send="sp_tts_only"]').disabled, false);
    element<HTMLButtonElement>('[data-speaker-send="sp_tts_only"]').click();
    await setImmediate();
    await setImmediate();

    assert.equal(actionCalls.length, 1);
    assert.deepEqual(actionCalls[0], {
      did: "sp_tts_only",
      siid: 7,
      aiid: 3,
      in: ["晚安"],
    });

    cancelDelayedReadBack(app);
    cancelEchoReadBack(app);
  });
});

describe("Wave 2 A4: Xiaomi Light -704002000 unsupported effect dynamic memory & drawer filtering", () => {
  it("records -704002000 per device, hides only the rejected effect pill across refreshes, and shows a friendly notice", async () => {
    const lightSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:yeelink-lamp:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:yeelink-lamp:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-lamp:1", format: "bool", access: ["read", "write"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:mode:00000008:yeelink-lamp:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Day" },
                { value: 1, description: "Flow" },
                { value: 2, description: "Reading" },
              ],
            },
          ],
          actions: [],
        },
      ],
    };

    const lights: SmartDevice[] = [
      {
        id: "lamp_a",
        name: "书房台灯",
        roomId: "room_study",
        roomName: "书房",
        model: "yeelink.light.lamp",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "miot:lamp_a:2",
          isOn: true,
          brightnessPercent: 80,
          colorTempKelvin: 4000,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: "Day",
          availableEffects: ["Day", "Flow", "Reading"],
        },
      },
      {
        id: "lamp_b",
        name: "客厅灯带",
        roomId: "room_living",
        roomName: "客厅",
        model: "yeelink.light.lamp",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "miot:lamp_b:2",
          isOn: true,
          brightnessPercent: 60,
          colorTempKelvin: 4000,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: ["Day", "Flow", "Reading"],
        },
      },
    ];

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: lights,
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, { "yeelink.light.lamp": lightSpec }, async (req) => {
      if (req.url.endsWith("/miotspec/prop/set")) {
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", {
            code: 0,
            result: [
              { did: "lamp_a", siid: 2, piid: 1, code: 0 },
              { did: "lamp_a", siid: 2, piid: 2, code: MIOT_PROPERTY_UNSUPPORTED_CODE },
            ],
          }),
        };
      }
      return {
        status: 200,
        headers: {},
        body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
      };
    });
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = structuredClone(lights);
    app.expandedDeviceId = "lamp_a";
    app.render();

    assert.equal(document.querySelectorAll('[data-lighteffect="lamp_a"]').length, 3);

    element<HTMLButtonElement>('[data-lighteffect="lamp_a"][data-effect="Flow"]').click();
    await setImmediate();
    await setImmediate();

    assert.equal(isLightEffectUnsupported(app, "lamp_a", "Flow"), true);
    assert.equal(isLightEffectUnsupported(app, "lamp_b", "Flow"), false);
    assert.deepEqual(filterSupportedLightEffects(app, "lamp_a", ["Day", "Flow", "Reading"]), [
      "Day",
      "Reading",
    ]);

    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /书房台灯暂不支持「.+」灯效，已自动隐藏该选项/);
    const remainingEffects = Array.from(
      document.querySelectorAll<HTMLElement>('[data-lighteffect="lamp_a"]'),
    ).map((el) => el.dataset.effect);
    assert.deepEqual(remainingEffects, ["Day", "Reading"]);

    app.devices = structuredClone(lights);
    app.expandedDeviceId = "lamp_a";
    app.render();
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>('[data-lighteffect="lamp_a"]')).map(
        (el) => el.dataset.effect,
      ),
      ["Day", "Reading"],
    );

    app.expandedDeviceId = "lamp_b";
    app.render();
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>('[data-lighteffect="lamp_b"]')).map(
        (el) => el.dataset.effect,
      ),
      ["Day", "Flow", "Reading"],
    );
  });
});

describe("Wave 2 A11: classifyControlFailure, 2200ms echo read-back, and Facet Undo", () => {
  it("silently swallows cancellation errors and classifies 429, offline, and sessionExpired failures in applyCommand", async () => {
    const lightDev: SmartDevice = {
      id: "lamp_err",
      name: "吸顶灯",
      roomId: "room_living",
      roomName: "客厅",
      model: "yeelink.light.ceiling1",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "miot:lamp_err:2",
        isOn: true,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    };

    const lightSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling1:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:yeelink-ceiling1:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-ceiling1:1", format: "bool", access: ["read", "write"] },
            { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-ceiling1:1", format: "uint8", access: ["read", "write"], valueRange: [1, 100, 1] },
          ],
          actions: [],
        },
      ],
    };

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: [lightDev],
      }),
    );

    let nextError: unknown = null;
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, { "yeelink.light.ceiling1": lightSpec }, async () => {
      throw nextError;
    });
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = structuredClone([lightDev]);
    app.replyBanner = { text: "上一条正常反馈", source: "实时控制" };

    const abortErr = new Error("The operation was aborted");
    abortErr.name = "AbortError";
    nextError = abortErr;
    const cancelledRes = await applyCommand(app, {
      kind: "setLightBrightness",
      entityId: "miot:lamp_err:2",
      percent: 80,
    });
    assert.equal(cancelledRes, false);
    assert.deepEqual(app.replyBanner, { text: "上一条正常反馈", source: "实时控制" });

    nextError = new MiCloudError("http", "HTTP 429", 429);
    await applyCommand(app, {
      kind: "setLightBrightness",
      entityId: "miot:lamp_err:2",
      percent: 80,
    });
    assert.equal(app.replyBanner?.isError, true);
    assert.equal(app.replyBanner?.text, "吸顶灯 调节未生效：请求过于频繁，请稍后再试");

    nextError = new MiCloudError("api", "device offline", -704042011);
    await applyCommand(app, {
      kind: "setLightPower",
      entityId: "miot:lamp_err:2",
      isOn: false,
    });
    assert.equal(app.replyBanner?.text, "吸顶灯 操作未生效：设备当前离线，请等它重新上线后再试");

    app.miSessionExpired = false;
    nextError = new MiCloudError("sessionExpired", "serviceToken expired", 3);
    await applyCommand(app, {
      kind: "setLightPower",
      entityId: "miot:lamp_err:2",
      isOn: false,
    });
    assert.equal(app.miSessionExpired, true);
    assert.equal(app.replyBanner?.text, "吸顶灯 操作未生效：登录已过期，请前往设置重新连接");
  });

  it("performs lightweight single-device 2200ms echo read-back and invalidates stale generations on newer writes", async () => {
    const lightSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling1:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:yeelink-ceiling1:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-ceiling1:1", format: "bool", access: ["read", "write"] },
            { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-ceiling1:1", format: "uint8", access: ["read", "write"], valueRange: [1, 100, 1] },
          ],
          actions: [],
        },
      ],
    };

    const devices: SmartDevice[] = [
      {
        id: "lamp_echo",
        name: "主灯",
        roomId: "room_living",
        roomName: "客厅",
        model: "yeelink.light.ceiling1",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "miot:lamp_echo:2",
          isOn: true,
          brightnessPercent: 20,
          colorTempKelvin: null,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
          colorWritable: false,
        },
      },
      {
        id: "lamp_sibling",
        name: "副灯",
        roomId: "room_living",
        roomName: "客厅",
        model: "yeelink.light.ceiling1",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "miot:lamp_sibling:2",
          isOn: false,
          brightnessPercent: 10,
          colorTempKelvin: null,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
          colorWritable: false,
        },
      },
    ];

    let reportedBrightness = 75;
    let holdGetProps: Promise<void> | null = null;
    const queriedDids: string[][] = [];

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: devices,
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, { "yeelink.light.ceiling1": lightSpec }, async (req) => {
      const { dataJson } = decodeMiFormParams(req.body ?? "");
      if (req.url.endsWith("/miotspec/prop/set")) {
        const params = (dataJson.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", {
            code: 0,
            result: params.map((p) => ({ ...p, code: 0 })),
          }),
        };
      }
      if (req.url.endsWith("/miotspec/prop/get")) {
        const params = (dataJson.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
        queriedDids.push([...new Set(params.map((p) => p.did))]);
        if (holdGetProps) await holdGetProps;
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", {
            code: 0,
            result: [
              { did: "lamp_echo", siid: 2, piid: 1, code: 0, value: true },
              { did: "lamp_echo", siid: 2, piid: 2, code: 0, value: reportedBrightness },
            ],
          }),
        };
      }
      return {
        status: 200,
        headers: {},
        body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
      };
    });
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = structuredClone(devices);

    assert.equal(ECHO_READ_BACK_DELAY_MS, 2200);
    await applyCommand(app, {
      kind: "setLightBrightness",
      entityId: "miot:lamp_echo:2",
      percent: 75,
    });
    assert.equal(hasPendingEchoReadBack(app, "lamp_echo"), true);
    cancelDelayedReadBack(app, "lamp_echo");

    const lampKind = app.devices.find((d) => d.id === "lamp_echo")!.kind;
    if (lampKind.kind === "light") lampKind.brightnessPercent = 20;

    scheduleEchoReadBack(app, "lamp_echo", null, 15);
    await new Promise((r) => setTimeout(r, 45));

    assert.deepEqual(queriedDids, [["lamp_echo"]], "echo read-back must query ONLY the target device");
    const settled = app.devices.find((d) => d.id === "lamp_echo")!.kind;
    assert.equal(settled.kind, "light");
    if (settled.kind === "light") {
      assert.equal(settled.brightnessPercent, 75);
    }

    let releaseInFlight!: () => void;
    holdGetProps = new Promise<void>((r) => {
      releaseInFlight = r;
    });
    reportedBrightness = 75;
    scheduleEchoReadBack(app, "lamp_echo", null, 10);
    await new Promise((r) => setTimeout(r, 25));

    await applyCommand(app, {
      kind: "setLightBrightness",
      entityId: "miot:lamp_echo:2",
      percent: 40,
    });
    cancelEchoReadBack(app, "lamp_echo");
    cancelDelayedReadBack(app, "lamp_echo");

    holdGetProps = null;
    releaseInFlight();
    await new Promise((r) => setTimeout(r, 25));

    const afterNewer = app.devices.find((d) => d.id === "lamp_echo")!.kind;
    assert.equal(afterNewer.kind, "light");
    if (afterNewer.kind === "light") {
      assert.equal(
        afterNewer.brightnessPercent,
        40,
        "stale echo read-back from an older generation must never overwrite a newer command",
      );
    }
  });

  it("pushes reversible Facet writes (toggle, slider, select) onto Undo stack and restores prior value on performUndo", async () => {
    const purifier: SmartDevice = {
      id: "purifier_1",
      name: "卧室净化器",
      roomId: "room_bed",
      roomName: "卧室",
      model: "zhimi.airpurifier.ma4",
      isOnline: true,
      kind: {
        kind: "fan",
        entityId: "miot:purifier_1:2",
        isOn: true,
        percentage: 50,
        presetMode: "Auto",
        availablePresetModes: ["Auto", "Silent"],
        isOscillating: null,
        swingWritable: false,
      },
    };

    const facets: Record<string, FacetControl[]> = {
      purifier_1: [
        {
          id: "3.1",
          kind: "toggle",
          name: "physical-controls-locked",
          title: "童锁",
          serviceName: "physical-controls-locked",
          unit: null,
          scale: null,
          value: false,
          options: [],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: "miot:purifier_1:3", piid: 1 },
        },
        {
          id: "4.1",
          kind: "slider",
          name: "led-brightness",
          title: "屏幕亮度",
          serviceName: "indicator-light",
          unit: "%",
          scale: null,
          value: 30,
          options: [],
          range: { min: 0, max: 100, step: 10 },
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: "miot:purifier_1:4", piid: 1 },
        },
        {
          id: "5.1",
          kind: "select",
          name: "display-mode",
          title: "显示模式",
          serviceName: "screen",
          unit: null,
          scale: null,
          value: 0,
          options: [
            { value: 0, label: "亮屏" },
            { value: 1, label: "微光" },
            { value: 2, label: "息屏" },
          ],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: "miot:purifier_1:5", piid: 1 },
        },
        {
          id: "6.a1",
          kind: "button",
          name: "reset-filter-life",
          title: "复位滤芯",
          serviceName: "filter",
          unit: null,
          scale: null,
          value: null,
          options: [],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "action", entityId: "miot-action:purifier_1:6:1" },
        },
      ],
    };

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        allowAdvancedFacetWrites: true,
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    app.devices = [structuredClone(purifier)];
    app.deviceFacets = structuredClone(facets);
    app.expandedDeviceId = "purifier_1";
    app.render();

    element('[data-more-settings-toggle="purifier_1"]').click();

    element('[data-facet-toggle="purifier_1|3.1"]').click();
    await setImmediate();
    await setImmediate();

    assert.equal(app.deviceFacets.purifier_1![0]!.value, true);
    assert.ok(app.lastUndoAction, "toggle facet write must populate lastUndoAction");
    assert.ok(document.querySelector("#btn-undo"), "Undo button must appear in live banner");

    await app.performUndo();
    assert.equal(app.deviceFacets.purifier_1![0]!.value, false, "performUndo must restore toggle to false");
    assert.equal(app.lastUndoAction, null, "performUndo must consume undo without pushing undo-of-undo");

    const slider = element<HTMLInputElement>('[data-facet-number="purifier_1|4.1"]');
    slider.value = "80";
    slider.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    await setImmediate();

    assert.equal(app.deviceFacets.purifier_1![1]!.value, 80);
    assert.ok(app.lastUndoAction, "slider facet write must populate lastUndoAction");
    await app.performUndo();
    assert.equal(app.deviceFacets.purifier_1![1]!.value, 30, "performUndo must restore slider to 30");
    assert.equal(app.lastUndoAction, null);

    element('[data-facet-select="purifier_1|5.1|2"]').click();
    await setImmediate();
    await setImmediate();

    assert.equal(app.deviceFacets.purifier_1![2]!.value, 2);
    assert.ok(app.lastUndoAction, "select facet write must populate lastUndoAction");
    await app.performUndo();
    assert.equal(app.deviceFacets.purifier_1![2]!.value, 0, "performUndo must restore select option to 0");
    assert.equal(app.lastUndoAction, null);

    await app.executeSingleCommand(
      app.devices[0]!,
      { kind: "pressButton", entityId: "miot-action:purifier_1:6:1" },
      "已执行复位滤芯",
    );
    assert.equal(app.lastUndoAction, null, "momentary button facet must not populate lastUndoAction");
  });

  it("preserves splitParentDid/splitSiid on multi-key wall switches and generic split cards during 2200ms echo read-back", async () => {
    const wallSwitchSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:switch:0000A003:lumi-b2lacn02:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:switch:0000780C:lumi-b2lacn02:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:lumi-b2lacn02:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:switch:0000780C:lumi-b2lacn02:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:lumi-b2lacn02:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
      ],
    };

    const genericSplitSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:fish-tank:0000A0A2:vendor-tank:1",
      services: [
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:fish-tank:00007894:vendor-tank:1",
          properties: [
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:water-pump:000000F1:vendor-tank:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Low" },
                { value: 1, description: "High" },
              ],
            },
          ],
          actions: [],
        },
      ],
    };

    const splitKeyDevice: SmartDevice = {
      id: "split_key_2",
      name: "走廊右健",
      roomId: "room_hall",
      roomName: "玄关",
      model: "lumi.switch.b2lacn02",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "miot:parent_1:3",
        isOn: false,
        powerWatts: null,
        childLockEntityId: null,
        isChildLocked: false,
      },
    };

    const splitGenericDevice: SmartDevice = {
      id: "split_gen_1",
      name: "副缸水泵",
      roomId: "room_hall",
      roomName: "玄关",
      model: "vendor.fishtank.v1",
      isOnline: true,
      kind: {
        kind: "generic",
        deviceType: "fish-tank",
        typeTitle: "鱼缸",
        isOn: false,
        powerControl: null,
        isReadOnly: false,
        readouts: [],
        symbolName: null,
      },
    };

    const getPropsParams: Array<Array<{ did: string; siid: number; piid: number }>> = [];

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: [splitKeyDevice, splitGenericDevice],
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(
      app,
      {
        "lumi.switch.b2lacn02": wallSwitchSpec,
        "vendor.fishtank.v1": genericSplitSpec,
      },
      async (req) => {
        const { dataJson } = decodeMiFormParams(req.body ?? "");
        if (req.url.endsWith("/miotspec/prop/get")) {
          const params = (dataJson.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
          getPropsParams.push(params);
          return {
            status: 200,
            headers: {},
            body: encodeMiResponse(req.body ?? "", {
              code: 0,
              result: params.map((p) => ({
                ...p,
                code: 0,
                value: p.did === "parent_1" ? true : 1,
              })),
            }),
          };
        }
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
        };
      },
    );
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = [structuredClone(splitKeyDevice), structuredClone(splitGenericDevice)];
    app.deviceFacets = {
      split_gen_1: [
        {
          id: "4.2",
          kind: "select",
          name: "water-pump",
          title: "水泵档位",
          serviceName: "fish-tank",
          unit: null,
          scale: null,
          value: 0,
          options: [
            { value: 0, label: "Low" },
            { value: 1, label: "High" },
          ],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: "miot:parent_generic:4", piid: 2 },
        },
      ],
    };

    lockOptimistic(app, "split_gen_1", 10_000);
    scheduleEchoReadBack(app, "split_key_2", null, 15);
    await new Promise((r) => setTimeout(r, 35));
    assert.equal(
      isOptimisticallyLocked(app, "split_gen_1"),
      true,
      "single-device echo read-back for split_key_2 must not clear split_gen_1's optimistic lock",
    );

    scheduleEchoReadBack(app, "split_gen_1", null, 15);
    await new Promise((r) => setTimeout(r, 35));

    assert.deepEqual(getPropsParams[0], [{ did: "parent_1", siid: 3, piid: 1 }]);
    const updatedSplit = app.devices.find((d) => d.id === "split_key_2")!;
    assert.equal(updatedSplit.kind.kind, "plug");
    if (updatedSplit.kind.kind === "plug") {
      assert.equal(
        updatedSplit.kind.switchEntityId,
        "miot:parent_1:3",
        "split key switchEntityId must remain bound to parent_1:3",
      );
      assert.equal(updatedSplit.kind.isOn, true);
    }

    assert.deepEqual(getPropsParams[1], [{ did: "parent_generic", siid: 4, piid: 2 }]);
    const updatedGenFacet = app.deviceFacets.split_gen_1?.[0];
    assert.equal(updatedGenFacet?.target?.entityId, "miot:parent_generic:4");
    assert.equal(updatedGenFacet?.value, 1);
  });

  it("preserves battery/hub camera gateway routing metadata across 2200ms single-device echo read-back", async () => {
    const camSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:camera:0000A01C:isa-hlc8:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:isa-hlc8:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:isa-hlc8:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 5,
          type: "urn:miot-spec-v2:service:motion-detection:0000784F:isa-hlc8:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:motion-detection:00000056:isa-hlc8:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
      ],
    };

    const hubCam: SmartDevice = {
      id: "cam_hub_1",
      name: "门外电池摄像机",
      roomId: "room_entry",
      roomName: "门口",
      model: "isa.camera.hlc8",
      isOnline: true,
      kind: {
        kind: "camera",
        entityId: "miot:cam_hub_1:2",
        isOn: true,
        nightShot: null,
        availableNightShots: [],
        motionDetectionEntityId: "miot:cam_hub_1:5",
        isMotionDetectionOn: false,
        streamEntityId: "miot:cam_hub_1:2",
        subdid: "sub_child_88",
        gatewayDid: "gw_hub_99",
        gatewayModel: "xiaomi.gateway.hub1",
        gatewayLocalIp: "192.168.31.88",
      },
    };

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: [hubCam],
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, { "isa.camera.hlc8": camSpec }, async (req) => {
      if (req.url.endsWith("/miotspec/prop/get")) {
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", {
            code: 0,
            result: [
              { did: "cam_hub_1", siid: 2, piid: 1, code: 0, value: true },
              { did: "cam_hub_1", siid: 5, piid: 1, code: 0, value: true },
            ],
          }),
        };
      }
      return {
        status: 200,
        headers: {},
        body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
      };
    });
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = [structuredClone(hubCam)];

    scheduleEchoReadBack(app, "cam_hub_1", null, 15);
    await new Promise((r) => setTimeout(r, 45));

    const updatedCam = app.devices.find((d) => d.id === "cam_hub_1")!;
    assert.equal(updatedCam.kind.kind, "camera");
    if (updatedCam.kind.kind === "camera") {
      assert.equal(updatedCam.kind.isMotionDetectionOn, true);
      assert.equal(updatedCam.kind.subdid, "sub_child_88");
      assert.equal(updatedCam.kind.gatewayDid, "gw_hub_99");
      assert.equal(updatedCam.kind.gatewayModel, "xiaomi.gateway.hub1");
      assert.equal(updatedCam.kind.gatewayLocalIp, "192.168.31.88");
    }
  });

  it("keeps Facet restoreCommand marked across failed performUndo retries so retry never creates undo-of-undo", async () => {
    const purifierSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-ma4:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:zhimi-ma4:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:zhimi-ma4:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:physical-controls-locked:00007807:zhimi-ma4:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:physical-controls-locked:0000001D:zhimi-ma4:1",
              format: "bool",
              access: ["read", "write"],
            },
          ],
          actions: [],
        },
      ],
    };

    const purifier: SmartDevice = {
      id: "purifier_retry",
      name: "书房净化器",
      roomId: "room_study",
      roomName: "书房",
      model: "zhimi.airpurifier.ma4",
      isOnline: true,
      kind: {
        kind: "fan",
        entityId: "miot:purifier_retry:2",
        isOn: true,
        percentage: 40,
        presetMode: null,
        availablePresetModes: [],
        isOscillating: null,
        swingWritable: false,
      },
    };

    let failSetProps = false;

    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        allowAdvancedFacetWrites: true,
        miSession: TEST_MI_SESSION,
        cachedXiaomiDevices: [purifier],
      }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    app.refreshDevices = async () => {};
    stubMiCloudRuntime(app, { "zhimi.airpurifier.ma4": purifierSpec }, async (req) => {
      const { dataJson } = decodeMiFormParams(req.body ?? "");
      if (req.url.endsWith("/miotspec/prop/set")) {
        if (failSetProps) {
          throw new MiCloudError("http", "HTTP 503", 503);
        }
        const params = (dataJson.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return {
          status: 200,
          headers: {},
          body: encodeMiResponse(req.body ?? "", {
            code: 0,
            result: params.map((p) => ({ ...p, code: 0 })),
          }),
        };
      }
      return {
        status: 200,
        headers: {},
        body: encodeMiResponse(req.body ?? "", { code: 0, result: [] }),
      };
    });
    await setImmediate();
    await setImmediate();
    app.settings.miSession = TEST_MI_SESSION;
    app.devices = [structuredClone(purifier)];
    app.deviceFacets = {
      purifier_retry: [
        {
          id: "3.1",
          kind: "toggle",
          name: "physical-controls-locked",
          title: "童锁",
          serviceName: "physical-controls-locked",
          unit: null,
          scale: null,
          value: false,
          options: [],
          range: null,
          isWritable: true,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: "miot:purifier_retry:3", piid: 1 },
        },
      ],
    };

    await app.executeSingleCommand(
      app.devices[0]!,
      { kind: "setMiotProperty", entityId: "miot:purifier_retry:3", piid: 1, value: true },
      "已开启童锁",
    );
    await setImmediate();
    await setImmediate();

    assert.equal(app.deviceFacets.purifier_retry![0]!.value, true);
    assert.ok(app.lastUndoAction, "initial facet write must arm lastUndoAction");

    failSetProps = true;
    await app.performUndo();
    await setImmediate();
    await setImmediate();
    assert.equal(app.deviceFacets.purifier_retry![0]!.value, true);
    assert.equal(app.replyBanner?.isError, true);
    assert.ok(app.lastUndoAction, "failed Undo must keep restore step for retry");

    failSetProps = false;
    await app.performUndo();
    await setImmediate();
    await setImmediate();
    assert.equal(app.deviceFacets.purifier_retry![0]!.value, false);
    assert.equal(app.lastUndoAction, null, "retried Undo must not generate undo-of-undo");

    cancelDelayedReadBack(app);
    cancelEchoReadBack(app);
  });
});
