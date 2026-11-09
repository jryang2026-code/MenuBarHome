import type {
  AssistantSuggestion,
  DeviceIntent,
  FacetControl,
  HomeScene,
  IntentOperation,
  SmartDevice,
} from "../models.js";
import {
  DEVICE_PROFILES,
  MANUAL_CONTROL_FALLBACK_RULES,
  matchesMiotFacetPattern,
  type ManualControlRules,
} from "../miCloud/facets.js";
import { deviceCategory } from "./deviceCategory.js";
import { IntentReply, IntentValidator } from "./intent.js";
import { PROMPT_NAME_LIMIT, sanitizePromptText } from "./promptText.js";

export function deviceHeadInstruction(alias: string): string {
  return `What action should be taken on device ${alias} for this command? Choose none if unrelated.`;
}

export function proactiveHeadInstruction(alias: string): string {
  return `What proactive adjustment for device ${alias}? Select none if current state is already ideal.`;
}

// MARK: - When AI actions may run by themselves (#21)

function readProbability(raw: unknown): number | null {
  let value: number | null = null;
  if (typeof raw === "number") {
    value = raw;
  } else if (typeof raw === "string" && raw.trim() !== "") {
    const text = raw.trim();
    value = text.endsWith("%") ? Number(text.slice(0, -1).trim()) / 100 : Number(text);
  }
  if (value === null || !Number.isFinite(value)) return null;
  if (value > 1) value /= 100;
  return Math.min(Math.max(value, 0), 1);
}

export interface ChosenAction {
  readonly intent: DeviceIntent;
  readonly confidence: number | null;
  readonly primaryChoice: boolean;
}

export interface ModelDecisionPayload {
  readonly actions: readonly ChosenAction[];
}

export interface ModelDecision {
  readonly intents: readonly DeviceIntent[];
  readonly suggestions: readonly AssistantSuggestion[];
}


type ConfirmationHazard =
  | { readonly kind: "anyChangeExceptOff" }
  | { readonly kind: "anyPower" }
  | { readonly kind: "powerOn" }
  | { readonly kind: "powerOnOrHotter"; readonly setpoint: number };

function confirmationHazard(dev: SmartDevice): ConfirmationHazard | null {
  // A water heater whose model and name miss every heater hint is still a heater for the
  // hotter-only rule (#167), and the facet rule reads `spec.heats` the same way.
  if (
    dev.kind.kind === "climate" &&
    dev.name.includes("热水器") &&
    !dev.model.includes("heater") &&
    !dev.model.includes("blanket")
  ) {
    return { kind: "powerOnOrHotter", setpoint: dev.kind.targetTemperature };
  }
  if (dev.kind.kind === "cover") {
    switch (dev.kind.subtype) {
      // A curtain is the ticket's low-risk case; an airer moves like a window opener, and a
      // garage door follows the stricter any-direction rule (macOS ModelActionPolicy).
      case "curtain":
        return null;
      case "window-opener":
      case "clothes-airer":
        return { kind: "powerOn" };
      case "garage-door":
        return { kind: "anyPower" };
    }
  }
  if (dev.kind.kind === "appliance") {
    // Starting a cycle (a wash, a dry) is hazardous even when the appliance does not heat;
    // a hood's plain power switch stays direct (#3, #4).
    if (!dev.kind.heats && dev.kind.startAction === null) return null;
    return { kind: "powerOnOrHotter", setpoint: dev.kind.targetTemperature ?? 0 };
  }
  switch (deviceCategory(dev)) {
    case "heater":
      return { kind: "anyChangeExceptOff" };
    case "plug":
    case "camera":
      return { kind: "anyPower" };
    case "vacuum":
      return { kind: "powerOn" };
    case "climate":
      if (dev.kind.kind !== "climate" || !dev.name.includes("热水器")) return null;
      return { kind: "powerOnOrHotter", setpoint: dev.kind.targetTemperature };
    default:
      return null;
  }
}

function confirmationHazardMatches(hazard: ConfirmationHazard, operation: IntentOperation): boolean {
  switch (hazard.kind) {
    case "anyChangeExceptOff":
      if (operation.kind === "power") return operation.isOn;
      if (operation.kind === "hvacMode") return operation.mode !== "off";
      return true;
    case "anyPower":
      return operation.kind === "power";
    case "powerOn":
      return operation.kind === "power" && operation.isOn;
    case "powerOnOrHotter":
      if (operation.kind === "power") return operation.isOn;
      if (operation.kind === "hvacMode") return operation.mode !== "off";
      if (operation.kind === "targetTemperature") return operation.celsius > hazard.setpoint;
      return false;
  }
}

function confidenceBadge(confidences: readonly (number | null)[]): number | null {
  if (confidences.some((value) => value === null)) return null;
  const present = confidences.filter((value): value is number => value !== null);
  if (present.length === 0) return null;
  return Math.min(...present);
}

function decisionSuggestions(
  waiting: readonly ChosenAction[],
  wide: boolean,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  if (waiting.length === 0) return [];
  if (wide) {
    return ModelActionPolicy.chips(
      waiting.map((action) => action.intent),
      confidenceBadge(waiting.map((action) => action.confidence)),
      "confirm",
      devices,
      scenes,
      true,
    );
  }
  const suggestions: AssistantSuggestion[] = [];
  const primary = waiting.filter((action) => action.primaryChoice);
  if (primary.length > 0) {
    suggestions.push(
      ...ModelActionPolicy.chips(
        primary.map((action) => action.intent),
        confidenceBadge(primary.map((action) => action.confidence)),
        "confirm:primary",
        devices,
        scenes,
        true,
      ),
    );
  }
  const order: string[] = [];
  const byTarget = new Map<string, ChosenAction[]>();
  for (const action of waiting) {
    if (action.primaryChoice) continue;
    if (!byTarget.has(action.intent.targetId)) order.push(action.intent.targetId);
    byTarget.set(action.intent.targetId, [...(byTarget.get(action.intent.targetId) ?? []), action]);
  }
  for (const targetId of order) {
    const group = byTarget.get(targetId) ?? [];
    suggestions.push(
      ...ModelActionPolicy.chips(
        group.map((action) => action.intent),
        confidenceBadge(group.map((action) => action.confidence)),
        "confirm",
        devices,
        scenes,
      ),
    );
  }
  return suggestions;
}

/**
 * The plain-language "不确定时先问我" preference (#180). Only the confidence gate changes; hazard
 * rules still ask. Defaults preserve the shipped behaviour on both platforms.
 */
export interface ConfirmationPolicy {
  readonly askWhenUnsure: boolean;
  readonly threshold: number;
}

/** Mirrors MijiaCore.ModelActionPolicy: guesses below 80% and risky actions wait for a tap. */
export const ModelActionPolicy = {
  AUTO_RUN_THRESHOLD: 0.8,
  SUGGESTION_FLOOR: 0.2,
  maxAutoRunDevices: 3,

  /** probabilities[choice], else confidence, else 0 — a missing number means "not sure". */
  probabilityOf(answer: Record<string, unknown> | undefined, choice: string): number {
    if (!answer) return 0;
    const probs = answer["probabilities"];
    if (probs && typeof probs === "object") {
      const value = readProbability((probs as Record<string, unknown>)[choice]);
      if (value !== null) return value;
    }
    return readProbability(answer["confidence"]) ?? 0;
  },

  decide(
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    payload: ModelDecisionPayload,
    policy: Partial<ConfirmationPolicy> = {}
  ): ModelDecision {
    const askWhenUnsure = policy.askWhenUnsure ?? true;
    const threshold = policy.threshold ?? this.AUTO_RUN_THRESHOLD;
    const unsure = (confidence: number | null): boolean =>
      askWhenUnsure && confidence !== null && confidence < threshold;
    const deviceById = new Map(devices.map((device) => [device.id, device]));
    const seen = new Set<string>();
    const surviving: ChosenAction[] = [];
    for (const action of payload.actions) {
      for (const intent of IntentValidator.sanitize([action.intent], devices, scenes)) {
        const key = JSON.stringify(intent);
        if (seen.has(key)) continue;
        seen.add(key);
        surviving.push({ intent, confidence: action.confidence, primaryChoice: action.primaryChoice });
      }
    }
    const deviceIDs = new Set(surviving.filter((action) => deviceById.has(action.intent.targetId)).map((action) => action.intent.targetId));
    const wide = deviceIDs.size > this.maxAutoRunDevices;
    const judged = surviving.map((action) => {
      if (wide) return { action, confirms: true };
      const device = deviceById.get(action.intent.targetId);
      if (device) {
        const lowConfidence = unsure(action.confidence);
        const confirms =
          device.isSharedHome === true ||
          sanitizePromptText(device.name, PROMPT_NAME_LIMIT) !== device.name ||
          sanitizePromptText(device.roomName, PROMPT_NAME_LIMIT) !== device.roomName ||
          lowConfidence ||
          this.needsConfirmation(action.intent, devices);
        return { action, confirms };
      }
      const scene = scenes.find((item) => item.id === action.intent.targetId);
      if (scene) {
        const lowConfidence = unsure(action.confidence);
        return {
          action,
          confirms: sanitizePromptText(scene.name, PROMPT_NAME_LIMIT) !== scene.name || lowConfidence,
        };
      }
      return {
        action,
        confirms: unsure(action.confidence),
      };
    });
    const waiting = judged.filter((item) => item.confirms).map((item) => item.action);
    return {
      intents: judged.filter((item) => !item.confirms).map((item) => item.action.intent),
      suggestions: decisionSuggestions(waiting, wide, devices, scenes),
    };
  },

  /** A heater change other than off, any plug or camera power change, a vacuum start, or turning a 热水器 on or hotter needs a tap even when the model is sure. */
  needsConfirmation(intent: DeviceIntent, devices: readonly SmartDevice[]): boolean {
    const dev = devices.find((d) => d.id === intent.targetId);
    if (!dev) return false;
    const hazard = confirmationHazard(dev);
    return hazard !== null && confirmationHazardMatches(hazard, intent.operation);
  },

  partition(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[]
  ): { run: DeviceIntent[]; confirm: DeviceIntent[] } {
    const run: DeviceIntent[] = [];
    const confirm: DeviceIntent[] = [];
    for (const intent of intents) {
      (this.needsConfirmation(intent, devices) ? confirm : run).push(intent);
    }
    return { run, confirm };
  },

  /** One chip per device, or one chip for the whole group when `grouped`. */
  chips(
    intents: readonly DeviceIntent[],
    probability: number | null,
    idPrefix: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    grouped = false
  ): AssistantSuggestion[] {
    if (intents.length === 0) return [];
    const percent = probability !== null && probability > 0 ? Math.max(20, Math.min(99, Math.round(probability * 100))) : null;
    const title = (group: readonly DeviceIntent[]) => IntentReply.describe(group, devices, scenes).replace(/^已/, "");
    if (grouped) {
      return [{ id: idPrefix, title: title(intents), confidencePercent: percent, intents: [...intents] }];
    }
    const byTarget = new Map<string, DeviceIntent[]>();
    for (const intent of intents) {
      byTarget.set(intent.targetId, [...(byTarget.get(intent.targetId) ?? []), intent]);
    }
    return [...byTarget.entries()].map(([targetId, group]) => ({
      id: `${idPrefix}:${targetId}`,
      title: title(group),
      confidencePercent: percent,
      intents: group,
    }));
  },

  confirmationReply(ranReply: string | null): string {
    if (!ranReply) return "没把握直接执行，点下面的建议再执行";
    return `${ranReply}；下面的建议要点一下才执行`;
  },
};

/** Manual controls that end a hazard instead of starting one (power off, heat off). */
function deescalatesHazard(operation: IntentOperation): boolean {
  if (operation.kind === "power") return !operation.isOn;
  if (operation.kind === "hvacMode") return operation.mode === "off";
  return false;
}

/** The confirmation table from the shared `deviceProfiles.json`, mirroring `currentRules` (#26). */
const MANUAL_CONTROL_RULES: ManualControlRules =
  DEVICE_PROFILES.manualControlPolicy ?? MANUAL_CONTROL_FALLBACK_RULES;

/** `Double(String)` decimal forms: sign, digits, an optional dot, an optional exponent. */
const DECIMAL_NUMBER = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;
/** `Double(String)` hex floats take a lowercase `0x`, an optional dot and an optional `p` exponent. */
const HEX_NUMBER = /^([+-]?)0x([0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP]([+-]?\d+))?$/;
const INFINITY_NUMBER = /^[+-]?inf(?:inity)?$/i;
const NAN_NUMBER = /^[+-]?nan$/i;

/**
 * The string forms Swift `Double(String)` accepts. `Number()` is looser in both directions: it
 * trims whitespace, reads `0b101`/`0o17`, turns `""` into 0, and rejects the hex floats Swift
 * takes. A facet value that does not parse has to fall through the hazard table exactly as macOS
 * does, so the grammar is spelled out rather than delegated.
 */
function doubleFromString(text: string): number | null {
  if (INFINITY_NUMBER.test(text)) return text.startsWith("-") ? -Infinity : Infinity;
  if (NAN_NUMBER.test(text)) return NaN;
  if (DECIMAL_NUMBER.test(text)) return Number(text);
  const hex = HEX_NUMBER.exec(text);
  if (!hex) return null;
  const [, sign = "", body = "", exponent] = hex;
  const [whole = "", fraction = ""] = body.split(".");
  const value = Number.parseInt(`${whole}${fraction}`, 16) / 16 ** fraction.length;
  return (sign === "-" ? -value : value) * 2 ** Number(exponent ?? 0);
}

/** A number the value can carry, or null (macOS `JSONValue.doubleValue`). */
function doubleValue(value: unknown): number | null {
  if (typeof value === "number") return value;
  return typeof value === "string" ? doubleFromString(value) : null;
}

/** A rounded integer the JSON value can carry, or null (macOS `JSONValue.intValue`). */
function intValue(value: unknown): number | null {
  const number = doubleValue(value);
  if (number === null) return null;
  const rounded = Math.sign(number) * Math.round(Math.abs(number));
  return Number.isSafeInteger(rounded) ? rounded : null;
}

/** MIoT booleans occasionally arrive as 0/1 (macOS `JSONValue.miotBool`). */
function miotBool(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  const number = doubleValue(value);
  return number === null ? null : number !== 0;
}

/** The option label the write selects, or the raw string (macOS facet `selectedMode`). */
function selectedModeLabel(control: FacetControl, next: unknown): string | null {
  const selected = intValue(next);
  if (selected !== null) {
    const option = control.options.find((item) => item.value === selected);
    if (option) return option.label;
  }
  return typeof next === "string" ? next : null;
}

/** Exactly "off" ignoring case, the only option that ends a hazard (macOS `caseInsensitiveCompare`). */
function selectedModeIsOff(selected: string | null): boolean {
  return selected !== null && selected.toLowerCase() === "off";
}

function requiresOperationConfirmation(device: SmartDevice, operation: IntentOperation): boolean {
  return ManualControlPolicy.requiresConfirmation({ targetId: device.id, operation }, [device]);
}

/**
 * The manual-control hazard rule, mirroring MijiaCore.ManualControlPolicy. A person switching a
 * device off is making the home safer, so it stays direct unlike the model hazard table (#143).
 * Closing a cover is not automatically de-escalating: a garage door closing is itself hazardous,
 * so every cover operation goes through the subtype hazard table. An unknown target is low risk.
 */
export const ManualControlPolicy = {
  requiresConfirmation(intent: DeviceIntent, devices: readonly SmartDevice[]): boolean {
    const device = devices.find((d) => d.id === intent.targetId);
    if (!device) return false;
    if (deescalatesHazard(intent.operation) && device.kind.kind !== "cover") return false;
    return ModelActionPolicy.needsConfirmation(intent, devices);
  },

  /**
   * True when a 更多设置 write needs a second tap, mirroring
   * `MijiaCore.ManualControlPolicy.facetRequiresConfirmation`. The whitelist controls availability;
   * confirmation follows the meaning of the write, so an off direction stays direct unless the
   * device or service is strictly high risk. Branches stay in the macOS order.
   */
  facetRequiresConfirmation(
    control: FacetControl,
    next: unknown,
    device: SmartDevice,
    rules: ManualControlRules = MANUAL_CONTROL_RULES,
  ): boolean {
    // A physical consequence has no value to read back, so a button or action always asks.
    if (control.kind === "button") return true;
    if (control.target?.kind === "action") return true;

    const service = control.serviceName.toLowerCase();
    const name = control.name.toLowerCase();
    const tokens = name.split("-").filter((token) => token !== "");
    const isMode = name === "mode" || name.endsWith("-mode");
    const isTargetTemperature =
      name === "target-temperature" || name.endsWith("-target-temperature");
    const isPower = ["on", "power", "power-switch"].includes(name) || name.endsWith("-power");
    const coverServices = ["curtain", "window-opener", "airer", "clothes-airer", "garage-door"];
    // A cover's `mode` calibrates or re-zeroes the motor, so it always asks (#5).
    if (isMode && (device.kind.kind === "cover" || coverServices.includes(service))) return true;

    const deviceType = device.kind.kind === "generic" ? device.kind.deviceType : "";
    if (
      matchesMiotFacetPattern(deviceType, rules.strictlyHighRisk) ||
      matchesMiotFacetPattern(service, rules.strictlyHighRisk)
    ) {
      return true;
    }

    // Indicator, sound and child-lock controls never move the appliance's main function.
    const lowRiskTokens = new Set(rules.lowRiskTokens);
    const lowRiskHA =
      tokens.some((token) => lowRiskTokens.has(token)) ||
      name.includes("night-light") ||
      name.includes("child-lock") ||
      name.includes("physical-controls-locked") ||
      name.includes("auto-off");
    if (rules.lowRiskServices.includes(service) || lowRiskHA) return false;

    // A Home Assistant auxiliary switch uses the `switch` domain with a device-specific object id,
    // so it follows the power hazard table rather than a MIoT property short name. This also keeps
    // a heater switch's off direction direct.
    if (service === "switch") {
      const isOn = miotBool(next);
      if (isOn !== null) return requiresOperationConfirmation(device, { kind: "power", isOn });
    }

    const selectedMode = selectedModeLabel(control, next);

    if (deviceCategory(device) === "heater") {
      if (isPower) {
        const isOn = miotBool(next);
        if (isOn !== null) return isOn;
      }
      if (isMode) return !selectedModeIsOff(selectedMode);
      return true;
    }

    const heatingService = rules.heatingService.includes(service);
    if (isPower) {
      const isOn = miotBool(next);
      if (isOn !== null) {
        if (heatingService) return isOn;
        if (device.kind.kind !== "generic") {
          return requiresOperationConfirmation(device, { kind: "power", isOn });
        }
      }
    }

    const waterHeater =
      device.kind.kind === "appliance"
        ? device.kind.heats
        : device.kind.kind === "climate"
          ? device.name.includes("热水器")
          : false;
    if (isTargetTemperature) {
      const requested = doubleValue(next);
      if (requested !== null && (heatingService || waterHeater)) {
        const current = doubleValue(control.value);
        if (current !== null) return requested > current;
        if (heatingService) return true;
        return requiresOperationConfirmation(device, {
          kind: "targetTemperature",
          celsius: requested,
        });
      }
    }
    if (isMode && (heatingService || waterHeater)) return !selectedModeIsOff(selectedMode);

    // Data-driven high-risk types and services (#6). Generic facets outside the low-risk whitelist
    // belong here too: enabling advanced writes is not itself the confirmation. The heating rules
    // above keep their off and cool-down directions direct.
    const highRisk =
      matchesMiotFacetPattern(deviceType, DEVICE_PROFILES.facets.highRiskTypes) ||
      matchesMiotFacetPattern(service, DEVICE_PROFILES.facets.highRiskServices) ||
      (device.kind.kind === "generic" && !control.writesByDefault);
    if (highRisk) {
      const isOff =
        (isPower && miotBool(next) === false) ||
        (isMode && selectedModeIsOff(selectedMode));
      return !isOff;
    }
    return false;
  },
};
