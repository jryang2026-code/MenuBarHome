import "./dom.js";
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import {
  type AssistantContext,
  buildIntentCatalog,
  DelayPhrase,
  IntentValidator,
  LocalIntentParser,
  ModelIntentResolver,
  UndoPhrase,
} from "../src/core/assistant.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

const emptyCtx: AssistantContext = {
  timeSummary: "",
  environmentSummary: "",
  activeDevicesSummary: "",
  habitSummary: "",
};

function makeLight(overrides: Partial<SmartDevice> & { isOn?: boolean } = {}): SmartDevice {
  const { isOn = false, kind, ...rest } = overrides;
  return {
    id: "dev_light",
    name: "书房吸顶灯",
    roomId: "study",
    roomName: "书房",
    model: "yeelink.light.ceiling20",
    isOnline: true,
    kind: kind ?? {
      kind: "light",
      entityId: `light.${rest.id ?? "dev_light"}`,
      isOn,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: ["Day", "Night"],
    },
    ...rest,
  };
}

describe("Assistant cross-platform parity & hardening (F16, F18, F19, F20, F30h, F39, F40, F41)", () => {
  it("F16 & F19: timer cancel vs undo mutual exclusion and leftover-seconds delay formatting", () => {
    assert.equal(DelayPhrase.isCancel("撤销定时"), true);
    assert.equal(DelayPhrase.isCancel("取消刚才的定时"), true);
    assert.equal(DelayPhrase.isCancel("不要定时"), true);
    assert.equal(DelayPhrase.isCancel("undo timer"), true);
    assert.equal(UndoPhrase.isUndo("撤销定时"), false);
    assert.equal(UndoPhrase.isUndo("取消刚才的定时"), false);
    assert.equal(UndoPhrase.isUndo("undo timer"), false);
    assert.equal(UndoPhrase.isUndo("撤销"), true);

    assert.equal(DelayPhrase.formatDelay(30), "30 秒");
    assert.equal(DelayPhrase.formatDelay(90), "1 分钟 30 秒");
    assert.equal(DelayPhrase.formatDelay(600), "10 分钟");
    assert.equal(DelayPhrase.formatDelay(3600), "1 小时");
    assert.equal(DelayPhrase.formatDelay(3630), "1 小时 30 秒");
    assert.equal(DelayPhrase.formatDelay(3690), "1 小时 1 分钟 30 秒");
    assert.equal(DelayPhrase.formatDelay(5400), "1 小时 30 分钟");
  });

  it("F18: buildIntentCatalog and LocalIntentParser separate same-named rooms from distinct roomIds", () => {
    const cn1 = makeLight({ id: "cn_l1", name: "吸顶灯", roomId: "account-cn/ke_ting", roomName: "客厅", isOn: true });
    const de1 = makeLight({ id: "de_l1", name: "吸顶灯", roomId: "account-de/ke_ting", roomName: "客厅", isOn: true });

    const singlePerHome = buildIntentCatalog([cn1, de1], []);
    assert.equal(singlePerHome.aliasToIds.get("room_lights:1"), undefined);

    const cn2 = makeLight({ id: "cn_l2", name: "落地灯", roomId: "account-cn/ke_ting", roomName: "客厅", isOn: true });
    const de2 = makeLight({ id: "de_l2", name: "落地灯", roomId: "account-de/ke_ting", roomName: "客厅", isOn: true });
    const pairPerHome = buildIntentCatalog([cn1, cn2, de1, de2], []);
    assert.deepEqual(pairPerHome.aliasToIds.get("room_lights:1"), ["cn_l1", "cn_l2"]);
    assert.deepEqual(pairPerHome.aliasToIds.get("room_lights:2"), ["de_l1", "de_l2"]);

    assert.equal(LocalIntentParser.parse("关客厅的灯", [cn1, de1], []), null);
    const scoped = LocalIntentParser.parse("关客厅的灯", [cn1, de1], [], {
      panelRoom: { id: "account-cn/ke_ting", name: "客厅" },
    });
    assert.deepEqual(scoped?.intents, [{ targetId: "cn_l1", operation: { kind: "power", isOn: false } }]);
  });

  it("F20: chat suggestions preserve all group targets and deduplicate identical group intents", async () => {
    const studyCeiling = makeLight({ id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "study", roomName: "书房" });
    const studyDesk = makeLight({ id: "dev_study_desk", name: "书房台灯", roomId: "study", roomName: "书房" });
    const devices = [studyCeiling, studyDesk];
    const resolver = new ModelIntentResolver(
      { baseURL: "http://localhost:1234/v1", model: "local-chat", apiKey: "" },
      async () => ({
        status: 200,
        headers: {},
        body: JSON.stringify({
          choices: [
            {
              message: {
                content: JSON.stringify({
                  suggestions: [
                    { device: "room_lights:1", op: "power", value: true, confidence: 88 },
                    { device: "room_lights:1", op: "power", value: true, confidence: 72 },
                  ],
                }),
              },
            },
          ],
        }),
      }),
    );

    const suggestions = await resolver.recommendProactiveSuggestions(devices, [], emptyCtx);
    assert.deepEqual(suggestions, [
      {
        id: "chat:dev_study_ceiling:0",
        title: "打开书房吸顶灯 等 2 台",
        confidencePercent: 88,
        intents: [
          { targetId: "dev_study_ceiling", operation: { kind: "power", isOn: true } },
          { targetId: "dev_study_desk", operation: { kind: "power", isOn: true } },
        ],
      },
    ]);
  });

  it("F30h, F39 & F40: offline bare-category reply, FanSpeedMatcher parity, and consuming parser safety", () => {
    const offLight = makeLight({ id: "off_1", isOnline: false, isOn: true });
    assert.deepEqual(LocalIntentParser.parse("关灯", [offLight], []), {
      intents: [],
      reply: "灯当前离线",
      source: "local",
      suggestions: [],
    });

    const purifier: SmartDevice = {
      id: "dev_purifier",
      name: "空气净化器",
      roomId: "study",
      roomName: "书房",
      model: "zhimi.airp.rma3",
      isOnline: true,
      kind: {
        kind: "fan",
        entityId: "fan.purifier",
        isOn: true,
        percentage: 50,
        presetMode: "Auto",
        availablePresetModes: ["Auto", "Sleep", "Favorite"],
        isOscillating: null,
      },
    };
    assert.equal(IntentValidator.normalize({ kind: "fanSpeed", speed: "high" }, purifier), null);
    assert.deepEqual(IntentValidator.normalize({ kind: "hvacMode", mode: "auto" }, purifier), {
      kind: "fanSpeed",
      speed: "Auto",
    });

    const fan4: SmartDevice = {
      id: "dev_fan4",
      name: "客厅风扇",
      roomId: "living",
      roomName: "客厅",
      model: "dmaker.fan.p15",
      isOnline: true,
      kind: {
        kind: "fan",
        entityId: "fan.p15",
        isOn: true,
        percentage: null,
        presetMode: "Level1",
        availablePresetModes: ["Auto", "Level1", "Level2", "Level3", "Level4"],
        isOscillating: false,
      },
    };
    assert.deepEqual(IntentValidator.normalize({ kind: "fanSpeed", speed: "medium" }, fan4), {
      kind: "fanSpeed",
      speed: "Level3",
    });

    // IntentValidator.sanitize deduplicates identical normalized intents.
    const deduped = IntentValidator.sanitize(
      [
        { targetId: "dev_fan4", operation: { kind: "fanSpeed", speed: "medium" } },
        { targetId: "dev_fan4", operation: { kind: "fanSpeed", speed: "Level3" } },
      ],
      [fan4],
      [],
    );
    assert.equal(deduped.length, 1);
  });

  it("F41: extractFirstJSONObject and chat/SystemOne decoders resist non-JSON braces, <think>, and non-array fields", async () => {
    assert.equal(
      ModelIntentResolver.extractFirstJSONObject('Note {not json} result: {"reply":"ok","actions":[]} trailing {x}'),
      '{"reply":"ok","actions":[]}',
    );
    assert.equal(
      ModelIntentResolver.extractFirstJSONObject('<think>{"actions":[{"device":"d99"}]}</think>\n{"actions":[],"reply":"done"}'),
      '{"actions":[],"reply":"done"}',
    );
    // Fallback when model puts valid JSON inside <think> and nothing after </think>.
    assert.equal(
      ModelIntentResolver.extractFirstJSONObject('<think>{"actions":[],"reply":"inside"}</think>'),
      '{"actions":[],"reply":"inside"}',
    );
    assert.equal(ModelIntentResolver.extractFirstJSONObject('{"actions":[{"device":"d1"'), null);

    const d1 = makeLight({ id: "l1", name: "书房灯" });
    const catalog = buildIntentCatalog([d1], []);

    // Non-array suggestions/actions must degrade cleanly instead of throwing TypeError (.forEach).
    const nonArrayProactive = new ModelIntentResolver(
      { baseURL: "http://localhost:1234/v1", model: "local-chat", apiKey: "" },
      async () => ({
        status: 200,
        headers: {},
        body: JSON.stringify({ choices: [{ message: { content: '{"suggestions":"none"}' } }] }),
      }),
    );
    assert.deepEqual(await nonArrayProactive.recommendProactiveSuggestions([d1], [], emptyCtx), []);

    const resolver = new ModelIntentResolver(
      { baseURL: "http://localhost:1234/v1", model: "local-chat", apiKey: "" },
      async () => ({
        status: 200,
        headers: {},
        body: JSON.stringify({
          choices: [
            {
              message: {
                content: 'Note {bad} {"actions":{"not":"array"},"suggestions":"nope","reply":"当前无需操作"}',
              },
            },
          ],
        }),
      }),
    );
    const plan = await resolver.resolve("看看", [d1], []);
    assert.deepEqual(plan.intents, []);
    assert.deepEqual(plan.suggestions, []);
    assert.equal(plan.reply, "当前无需操作");

    // Empty string value or unit-suffixed numbers in chat actions.
    const unitResolver = new ModelIntentResolver(
      { baseURL: "http://localhost:1234/v1", model: "local-chat", apiKey: "" },
      async () => ({
        status: 200,
        headers: {},
        body: JSON.stringify({
          choices: [
            {
              message: {
                content: JSON.stringify({
                  actions: [
                    { device: "d1", op: "brightness", value: "" },
                    { device: "d1", op: "brightness", value: "65%" },
                  ],
                  reply: "已调光",
                }),
              },
            },
          ],
        }),
      }),
    );
    const unitPlan = await unitResolver.resolve("调到65%", [d1], []);
    assert.deepEqual(unitPlan.intents, [{ targetId: "l1", operation: { kind: "brightness", percent: 65 } }]);

    // Extreme SystemOne probability clamps to 99.
    const extremePlan = ModelIntentResolver.planFromSystemOne(
      '{"answers":{"target":{"choice":"none","confidence":0.5},"op":{"choice":"power_on","confidence":0.5},"temp":{"choice":"none","confidence":0.5},"dev_d1":{"choice":"none","probabilities":{"none":0.55,"power_on":1e300},"confidence":0.55}}}',
      catalog,
      [d1],
      [],
    );
    assert.equal(extremePlan.suggestions[0]?.confidencePercent, 99);
  });
});

describe("F16 Windows app naturalCommand undo-timer dispatch order", () => {
  let dom: Window;
  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        enableGrokBall: false,
        autoCheckUpdates: false,
      }),
    );
  });
  afterEach(async () => {
    await closeTestWindow(dom);
  });

  it("cancels pending timer on 撤销定时 without undoing the last device command", async () => {
    const root = document.querySelector<HTMLElement>("#app");
    assert.ok(root);
    const instance = new MenuMijiaWindowsApp(root);

    await instance.handleNaturalCommand("关闭书房台灯");
    const deskAfterClose = instance.devices.find((d) => d.id === "light.study_desk");
    assert.equal(deskAfterClose?.kind.kind === "light" ? deskAfterClose.kind.isOn : null, false);
    assert.ok(instance.lastUndoAction);

    await instance.handleNaturalCommand("10分钟后打开书房台灯");
    assert.equal(instance.scheduledCommands.length, 1);

    await instance.handleNaturalCommand("撤销定时");
    assert.equal(instance.scheduledCommands.length, 0);
    const deskAfterCancelTimer = instance.devices.find((d) => d.id === "light.study_desk");
    assert.equal(deskAfterCancelTimer?.kind.kind === "light" ? deskAfterCancelTimer.kind.isOn : null, false);
    assert.ok(instance.lastUndoAction, "device undo state must remain available after cancelling timer");

    await instance.handleNaturalCommand("撤销");
    const deskAfterUndo = instance.devices.find((d) => d.id === "light.study_desk");
    assert.equal(deskAfterUndo?.kind.kind === "light" ? deskAfterUndo.kind.isOn : null, true);
  });
});
