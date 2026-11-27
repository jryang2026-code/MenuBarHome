import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ASSISTANT_PROVIDER_PRESETS, buildIntentCatalog, IntentValidator, LocalIntentParser,
  ManualControlPolicy, ModelActionPolicy, ModelIntentResolver,
} from "../src/core/assistant.js";
import type { HttpTransport } from "../src/core/miCloudClient.js";
import type { SmartDevice } from "../src/core/models.js";

const fan: SmartDevice = {
  id: "dev_fan", name: "客厅风扇", roomId: "living", roomName: "客厅", model: "dmaker.fan.p5", isOnline: true,
  kind: { kind: "fan", entityId: "fan.living", isOn: true, percentage: 30, presetMode: "Level1", availablePresetModes: ["Level1", "Level2", "Level3"], isOscillating: false, powerWritable: true, speedWritable: true, swingWritable: true },
};
const deskLamp: SmartDevice = {
  id: "dev_lamp", name: "书房台灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true,
  kind: { kind: "light", entityId: "light.study_desk", isOn: false, brightnessPercent: 50, colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [] },
};
const cover = (id: string, name: string, subtype: "curtain" | "garage-door" | "window-opener" | "clothes-airer", pos = 0): SmartDevice => ({
  id, name, roomId: "living", roomName: "客厅", model: "lumi.curtain.v1", isOnline: true,
  kind: { kind: "cover", entityId: `cover.${id}`, subtype, positionPercent: pos, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause", batteryPercent: null, faultText: null, motion: "stopped" },
});

describe("AI core coverage: fan_percentage, cover, pinyin/diagnostics, schema & token budget", () => {
  it("resolves fan_percentage/cover_position, enforces cover safety gates, and excludes covers from all_devices", () => {
    const curtain = cover("c1", "客厅窗帘", "curtain"), garage = cover("c2", "车库门", "garage-door", 50);
    const opener = cover("c3", "阳台开窗器", "window-opener", 50), airer = cover("c4", "阳台晾衣架", "clothes-airer", 50);
    const all = [fan, deskLamp, curtain, garage, opener, airer];
    const catalog = buildIntentCatalog(all, []);
    assert.ok(catalog.aliasToIds.has("d3") && !catalog.aliasToIds.get("all_devices")?.includes("c1"));
    assert.match(ModelIntentResolver.systemPrompt(catalog), /fan_percentage.*cover_position/);

    const plan = ModelIntentResolver.planFromChat(
      JSON.stringify({ actions: [{ device: "d1", op: "fan_percentage", value: 65 }, { device: "d3", op: "cover_position", value: 50 }], reply: "已调节" }),
      catalog, all, [],
    );
    assert.deepEqual(plan.intents, [{ targetId: "dev_fan", operation: { kind: "fanPercentage", percent: 65 } }, { targetId: "c1", operation: { kind: "coverPosition", percent: 50 } }]);
    assert.deepEqual(IntentValidator.commandsForIntent(plan.intents[1]!, curtain), [{ kind: "setNumberValue", entityId: "cover.c1", value: 50 }]);

    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c1", operation: { kind: "coverPosition", percent: 50 } }, all), false);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c2", operation: { kind: "coverPosition", percent: 0 } }, all), true);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c2", operation: { kind: "coverPosition", percent: 50 } }, all), true);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c3", operation: { kind: "coverPosition", percent: 50 } }, all), true);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c3", operation: { kind: "coverPosition", percent: 0 } }, all), false);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c4", operation: { kind: "coverPosition", percent: 50 } }, all), true);
    assert.equal(ModelActionPolicy.needsConfirmation({ targetId: "c4", operation: { kind: "coverPosition", percent: 0 } }, all), false);
    assert.equal(ManualControlPolicy.requiresConfirmation({ targetId: "c2", operation: { kind: "coverPosition", percent: 0 } }, all), true);
    assert.equal(LocalIntentParser.parse("关闭所有设备", all, [])?.intents.some((i) => i.targetId === "c1" || i.targetId === "c2"), false);
  });

  it("matches pinyin/homophones, emits 3-way miss diagnostics, trims 45+ catalogs, and falls back on 400 response_format", async () => {
    const curtain = cover("c1", "客厅窗帘", "curtain");
    const devs = [fan, deskLamp, curtain];
    assert.deepEqual(LocalIntentParser.parse("打开 sftd", devs, [])?.intents, [{ targetId: "dev_lamp", operation: { kind: "power", isOn: true } }]);
    assert.deepEqual(LocalIntentParser.parse("turn on shufangtaideng", devs, [])?.intents, [{ targetId: "dev_lamp", operation: { kind: "power", isOn: true } }]);
    assert.deepEqual(LocalIntentParser.parse("打开书房台等", devs, [])?.intents, [{ targetId: "dev_lamp", operation: { kind: "power", isOn: true } }]);
    assert.deepEqual(LocalIntentParser.parse("把客厅窗连开到50%", devs, [])?.intents, [{ targetId: "c1", operation: { kind: "coverPosition", percent: 50 } }]);
    assert.deepEqual(LocalIntentParser.parseWithDiagnostic("打开厨房灯", devs, []), { kind: "missed", reason: "unknownDevice" });
    assert.deepEqual(LocalIntentParser.parseWithDiagnostic("打开火星投影仪", devs, []), { kind: "missed", reason: "unknownDevice" });
    assert.deepEqual(LocalIntentParser.parseWithDiagnostic("客厅窗帘亮度50%", devs, []), { kind: "missed", reason: "unsupportedAction" });
    assert.deepEqual(LocalIntentParser.parseWithDiagnostic("书房台灯调到26度", devs, []), { kind: "missed", reason: "unsupportedAction" });
    assert.deepEqual(LocalIntentParser.parseWithDiagnostic("我要睡觉了", devs, []), { kind: "missed", reason: "unrecognizedPhrasing" });

    const many: SmartDevice[] = Array.from({ length: 48 }, (_, i) => ({
      id: `d_${i + 1}`, name: `备用台灯${i + 1}`, roomId: `r_${i % 6}`, roomName: `房间${i % 6}`, model: "yeelink.light.lamp4", isOnline: true,
      kind: { kind: "light", entityId: `light.d_${i + 1}`, isOn: false, brightnessPercent: 50, colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [] },
    }));
    many.push(cover("cov_bed", "主卧窗帘", "curtain"));
    const catalog = buildIntentCatalog(many, []);
    const trimmed = catalog.textFitting(900, "把主卧窗帘开到50%");
    assert.ok(trimmed.includes("主卧窗帘") && trimmed.length < catalog.text.length);

    const bodies: Array<Record<string, unknown>> = [];
    const transport: HttpTransport = async (req) => {
      const parsed = JSON.parse(req.body ?? "{}") as Record<string, unknown>;
      bodies.push(parsed);
      if ("response_format" in parsed) return { status: 400, headers: {}, body: '{"error":{"message":"response_format json_schema unsupported"}}' };
      if ("temperature" in parsed) return { status: 400, headers: {}, body: '{"error":{"message":"invalid temperature"}}' };
      return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content: '{"actions":[{"device":"d1","op":"fan_percentage","value":45}],"reply":"已调速"}' } }] }) };
    };
    const resolver = new ModelIntentResolver({ baseURL: "http://localhost:11434/v1", model: "qwen3:8b", apiKey: "" }, transport);
    const plan = await resolver.resolve("把风扇吹柔一点", [fan], []);
    assert.equal(bodies.length, 3);
    assert.ok("response_format" in bodies[0]! && !("response_format" in bodies[1]!) && !("temperature" in bodies[2]!));
    assert.deepEqual(plan.intents, [{ targetId: "dev_fan", operation: { kind: "fanPercentage", percent: 45 } }]);
    assert.equal(ASSISTANT_PROVIDER_PRESETS.find((p) => p.id === "ollama")?.defaultModel, "qwen3:8b");
  });
});
