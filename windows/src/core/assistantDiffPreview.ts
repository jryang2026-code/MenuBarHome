import { ManualControlPolicy } from "./assistant.js";
import { t } from "./i18n.js";
import type { DeviceIntent, HomeScene, SmartDevice } from "./models.js";

export interface AssistantDiffPreviewItem {
  readonly targetId: string;
  readonly deviceName: string;
  readonly fromState: string;
  readonly toState: string;
  readonly isHighRisk: boolean;
}

export interface AssistantDiffPreview {
  readonly intents: readonly DeviceIntent[];
  readonly items: readonly AssistantDiffPreviewItem[];
  readonly replyText: string;
  readonly sourceLabel: string;
  readonly utterance: string;
  readonly recordHabits: boolean;
  readonly learnAfterRun: boolean;
  readonly sourceRevision: number;
  readonly hasHighRiskDevice: boolean;
}

/** True when a command touches >= 2 distinct targets or any high-risk device. */
export function requiresDiffPreview(
  intents: readonly DeviceIntent[],
  devices: readonly SmartDevice[],
): boolean {
  if (intents.length === 0) return false;
  const distinctTargets = new Set(intents.map((i) => i.targetId));
  if (distinctTargets.size >= 2) return true;
  return intents.some((intent) => ManualControlPolicy.requiresConfirmation(intent, devices));
}

function summarizeDevice(device: SmartDevice): string {
  const k = device.kind;
  switch (k.kind) {
    case "light":
      if (!k.isOn) return t("关");
      return k.brightnessPercent !== null ? `${t("开")} ${k.brightnessPercent}%` : t("开");
    case "climate":
      return k.isOn && k.hvacMode !== "off" ? `${k.hvacMode} ${k.targetTemperature}°C` : t("关");
    case "fan":
      if (!k.isOn) return t("关");
      return k.percentage !== null ? `${t("开")} ${k.percentage}%` : t("开");
    case "plug":
      return k.isOn ? t("开") : t("关");
    case "cover":
      return k.positionPercent !== null ? `${k.positionPercent}%` : t("已停止");
    case "vacuum":
      return k.status;
    default:
      return t("当前状态");
  }
}

function projectToState(device: SmartDevice, intents: readonly DeviceIntent[]): string {
  const clone: SmartDevice = { ...device, kind: { ...device.kind } };
  for (const intent of intents) {
    const op = intent.operation;
    const k = clone.kind;
    if (k.kind === "light") {
      if (op.kind === "power") k.isOn = op.isOn;
      else if (op.kind === "brightness") { k.isOn = true; k.brightnessPercent = op.percent; }
      else if (op.kind === "colorTemperature") { k.isOn = true; k.colorTempKelvin = op.kelvin; }
      else if (op.kind === "lightEffect") { k.isOn = true; k.currentEffect = op.effect; }
    } else if (k.kind === "plug" && op.kind === "power") {
      k.isOn = op.isOn;
    } else if (k.kind === "fan") {
      if (op.kind === "power") k.isOn = op.isOn;
      else if (op.kind === "fanPercentage") { k.isOn = true; k.percentage = op.percent; }
    } else if (k.kind === "climate") {
      if (op.kind === "power") { k.isOn = op.isOn; k.hvacMode = op.isOn ? (k.hvacMode === "off" ? "cool" : k.hvacMode) : "off"; }
      else if (op.kind === "hvacMode") { k.hvacMode = op.mode; k.isOn = op.mode !== "off"; }
      else if (op.kind === "targetTemperature") { k.isOn = true; k.targetTemperature = op.celsius; }
    } else if (k.kind === "cover" && op.kind === "power") {
      k.positionPercent = op.isOn ? 100 : 0;
    }
  }
  return summarizeDevice(clone);
}

export function buildDiffPreview(args: {
  readonly intents: readonly DeviceIntent[];
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly replyText: string;
  readonly sourceLabel: string;
  readonly utterance: string;
  readonly recordHabits: boolean;
  readonly learnAfterRun: boolean;
  readonly sourceRevision: number;
}): AssistantDiffPreview {
  const byId = new Map(args.devices.map((d) => [d.id, d]));
  const scenesById = new Map(args.scenes.map((s) => [s.id, s]));
  const targetOrder: string[] = [];
  const byTarget = new Map<string, DeviceIntent[]>();
  for (const intent of args.intents) {
    const existing = byTarget.get(intent.targetId);
    if (existing) existing.push(intent);
    else { targetOrder.push(intent.targetId); byTarget.set(intent.targetId, [intent]); }
  }
  const items: AssistantDiffPreviewItem[] = [];
  for (const targetId of targetOrder) {
    const group = byTarget.get(targetId) ?? [];
    if (group.some((i) => i.operation.kind === "activateScene")) {
      items.push({
        targetId,
        deviceName: scenesById.get(targetId)?.name ?? targetId,
        fromState: t("场景"),
        toState: t("执行"),
        isHighRisk: false,
      });
      continue;
    }
    const device = byId.get(targetId);
    if (!device) continue;
    const isHighRisk = group.some((i) => ManualControlPolicy.requiresConfirmation(i, args.devices));
    items.push({
      targetId,
      deviceName: device.name,
      fromState: summarizeDevice(device),
      toState: projectToState(device, group),
      isHighRisk,
    });
  }
  return {
    intents: [...args.intents],
    items,
    replyText: args.replyText,
    sourceLabel: args.sourceLabel,
    utterance: args.utterance,
    recordHabits: args.recordHabits,
    learnAfterRun: args.learnAfterRun,
    sourceRevision: args.sourceRevision,
    hasHighRiskDevice: items.some((i) => i.isHighRisk),
  };
}
