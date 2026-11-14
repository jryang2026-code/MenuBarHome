import type {
  AssistantSuggestion,
  DeviceCommand,
  DeviceIntent,
  HomeScene,
  IntentOperation,
  IntentPlan,
  SmartDevice,
} from "../models.js";
import { deviceAcceptsControlWrites, isDeviceActiveOn } from "../models.js";
import {
  buildDevicePhrases,
  chineseRoomDeviceIds,
  CN_BRIGHTNESS_STEP_WORDS,
  CN_BRIGHTNESS_WORDS,
  CN_CATEGORY_WORDS,
  CN_COLOR_TEMPERATURE_WORDS,
  CN_FAN_SPEED_WORDS,
  CN_FILLERS,
  CN_HVAC_MODE_WORDS,
  CN_LIGHT_EFFECT_WORDS,
  CN_OSCILLATION_WORDS,
  CN_POWER_VERBS,
  CN_ROOM_ALIASES,
  CN_SCOPE_WORDS,
  CN_TEMPERATURE_STEP_WORDS,
  CONSUMED_MARKER,
  consumeChinesePhrase,
  disambiguateRoomDevices,
  extractChineseNumericOps,
  longestFirst,
  normalizeChineseUtterance,
  spokenChineseNumber,
  strippedSceneText,
  toSimplifiedChinese,
} from "./chineseIntentTables.js";
import { deviceCategory, isAssistantControllable, type IntentCategory } from "./deviceCategory.js";

// MARK: - Spoken Delay & Undo Phrases

export interface ParsedDelay {
  readonly seconds: number;
  readonly remainder: string;
}

function spokenNumber(s: string): number | null {
  return spokenChineseNumber(s);
}

const CN_DELAY_NUMBER = "([0-9]+|[零一二两三四五六七八九十]+|半)";
const CN_DELAY_UNIT = "(个半|个)?(秒钟|秒|分钟|分|小时|钟头)(半)?";
const CN_DELAY_LEADING = new RegExp(`^(过|等)?${CN_DELAY_NUMBER}\\s*${CN_DELAY_UNIT}(以后|之后|后)?`);
const CN_DELAY_TRAILING = new RegExp(`[，,\\s]*${CN_DELAY_NUMBER}\\s*${CN_DELAY_UNIT}(以后|之后|后)$`);

function chineseDelaySeconds(m: RegExpExecArray, g: number): number | null {
  const rawNumber = m[g];
  const unitWord = m[g + 2];
  if (!rawNumber || !unitWord) return null;
  const unitSeconds = unitWord.startsWith("秒") ? 1 : unitWord.startsWith("分") ? 60 : 3600;
  let value = rawNumber === "半" ? 0.5 : spokenNumber(rawNumber);
  if (value === null) return null;
  if (m[g + 1] === "个半" || m[g + 3] === "半") value += 0.5;
  return value * unitSeconds;
}

function stripDelayMatch(text: string, m: RegExpExecArray): string {
  const rest = text.slice(0, m.index) + text.slice(m.index + m[0].length);
  return rest.replace(/^[，,。\s]+|[，,。\s]+$/g, "");
}

const CN_CANCEL_PHRASES = [
  "取消定时", "取消倒计时", "定时取消", "倒计时取消",
  "定时都取消", "取消所有定时", "取消全部定时",
  "不要定时", "不要倒计时",
  "撤销定时", "撤回定时", "清除定时", "清除倒计时",
  "取消刚才的定时", "取消刚才设的定时", "撤销刚才的定时", "撤回刚才的定时",
];

const EN_CANCEL_PHRASES = [
  "cancel timer", "cancel timers", "cancel all timers", "cancel the timer", "cancel that timer",
  "clear timer", "clear timers", "clear all timers",
  "stop timer", "stop timers", "stop all timers",
  "undo timer", "undo timers", "undo the timer", "undo that timer",
];

function buildDelay(val: number | null, unitMultiplier: number, remainder: string): ParsedDelay | null {
  const rem = remainder.trim();
  if (val === null || !Number.isFinite(val) || val <= 0 || !rem) return null;
  const seconds = Math.round(val * unitMultiplier);
  if (seconds <= 0 || seconds > 86400) return null;
  return { seconds, remainder: rem };
}

function englishUnitMultiplier(unitRaw: string): number {
  const u = unitRaw.toLowerCase();
  return u.startsWith("h") ? 3600 : u.startsWith("m") ? 60 : 1;
}

export const DelayPhrase = {
  isCancel(utterance: string): boolean {
    const lower = utterance.toLowerCase().trim();
    if (EN_CANCEL_PHRASES.some((p) => lower.includes(p))) return true;
    const compact = toSimplifiedChinese(utterance).replace(/[\s，。！？、,.!?了吧]/g, "");
    return CN_CANCEL_PHRASES.some((p) => compact.includes(p));
  },

  extract(utterance: string): ParsedDelay | null {
    const trimmed = utterance.trim();
    const enLead = /^(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b[,\s]*(.+)$/i.exec(trimmed);
    if (enLead) {
      return buildDelay(Number(enLead[1]), englishUnitMultiplier(enLead[2] ?? ""), enLead[3] ?? "");
    }
    const enTrail = /^(.+?)[,\s]+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\s*$/i.exec(trimmed);
    if (enTrail) {
      return buildDelay(Number(enTrail[2]), englishUnitMultiplier(enTrail[3] ?? ""), enTrail[1] ?? "");
    }
    const simplified = toSimplifiedChinese(trimmed);
    const leading = CN_DELAY_LEADING.exec(simplified);
    if (leading) {
      // Without 过 / 等 in front or 后 behind, "10分钟" is not a delay ("10分钟关灯" is left alone).
      const seconds = leading[1] !== undefined || leading[6] !== undefined ? chineseDelaySeconds(leading, 2) : null;
      if (seconds !== null) return buildDelay(seconds, 1, stripDelayMatch(trimmed, leading));
    }
    const trailing = CN_DELAY_TRAILING.exec(simplified);
    if (trailing) {
      const seconds = chineseDelaySeconds(trailing, 1);
      if (seconds !== null) return buildDelay(seconds, 1, stripDelayMatch(trimmed, trailing));
    }
    return null;
  },

  formatDelay(seconds: number): string {
    const clamped = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0;
    if (clamped < 60) return `${clamped} 秒`;
    const hours = Math.floor(clamped / 3600);
    const minutes = Math.floor((clamped % 3600) / 60);
    const secs = clamped % 60;
    const parts: string[] = [];
    if (hours > 0) parts.push(`${hours} 小时`);
    if (minutes > 0) parts.push(`${minutes} 分钟`);
    if (secs > 0) parts.push(`${secs} 秒`);
    return parts.join(" ");
  },
};

const CN_UNDO_KEYWORDS = ["撤销", "撤回", "还原", "恢复原样", "恢复原状", "恢复刚才", "取消刚才", "刚才不算"];
const EN_UNDO_SET = new Set(["undo", "revert", "undo that", "revert that", "cancel that"]);
const CN_TIMER_EXCLUDE = ["定时", "倒计时"];
const EN_TIMER_EXCLUDE_REGEX = /\b(timers?|countdowns?)\b/i;

export const UndoPhrase = {
  isUndo(utterance: string): boolean {
    if (DelayPhrase.isCancel(utterance)) return false;
    const lower = utterance.toLowerCase().replace(/^[，。！？、,.!?\s]+|[，。！？、,.!?\s]+$/g, "");
    if (EN_TIMER_EXCLUDE_REGEX.test(lower)) return false;
    if (EN_UNDO_SET.has(lower)) return true;
    const compact = toSimplifiedChinese(utterance).replace(/[\s，。！？、,.!?]/g, "");
    if (compact.length > 10) return false;
    if (CN_TIMER_EXCLUDE.some((w) => compact.includes(w))) return false;
    return CN_UNDO_KEYWORDS.some((w) => compact.includes(w));
  },
};

// MARK: - Intent Validation & Normalization

type FanSpeedLevel = "low" | "medium" | "high" | "auto" | "sleep" | "favorite";

const FAN_SPOKEN_LEVELS: ReadonlyArray<readonly [FanSpeedLevel, readonly string[]]> = [
  ["auto", ["auto", "自动"]],
  ["sleep", ["sleep", "睡眠", "silent", "静音"]],
  ["favorite", ["favorite", "favourite", "最爱", "manual", "手动"]],
  ["high", ["high", "高", "大", "强", "max", "最大", "strong"]],
  ["medium", ["medium", "middle", "mid", "中"]],
  ["low", ["low", "低", "小", "弱", "min", "最小", "微"]],
];

const FAN_OPTION_HINTS: Readonly<Record<FanSpeedLevel, readonly string[]>> = {
  auto: ["auto", "自动"],
  sleep: ["sleep", "睡眠", "silent", "静音"],
  favorite: ["favorite", "favourite", "最爱", "manual", "手动"],
  high: ["high", "strong", "高", "强"],
  medium: ["medium", "middle", "mid", "中"],
  low: ["low", "低", "弱"],
};

const FAN_NON_LEVEL_HINTS = [
  "auto", "自动", "sleep", "睡眠", "silent", "静音",
  "natural", "nature", "自然", "smart", "智能",
  "favorite", "favourite", "最爱",
];

/** 1:1 port of `FanSpeedMatcher.match` (`CommandIntent.swift`). */
export function matchFanSpeed(raw: string, options: readonly string[]): string | null {
  const wanted = raw.trim();
  if (!wanted || options.length === 0) return null;
  const exact = options.find((opt) => opt.toLowerCase() === wanted.toLowerCase());
  if (exact !== undefined) return exact;

  const lowered = wanted.toLowerCase();
  const levelEntry = FAN_SPOKEN_LEVELS.find(([, words]) =>
    words.some((w) => lowered === w || lowered.startsWith(w)),
  );
  if (!levelEntry) return null;
  const level = levelEntry[0];
  const hints = FAN_OPTION_HINTS[level];
  const named = options.find((opt) => {
    const optLower = opt.toLowerCase();
    return hints.some((h) => optLower.includes(h));
  });
  if (named !== undefined) return named;

  const levels = options.filter((opt) => {
    const optLower = opt.toLowerCase();
    return !FAN_NON_LEVEL_HINTS.some((h) => optLower.includes(h));
  });
  if (levels.length === 0) return null;
  switch (level) {
    case "low":
      return levels[0] ?? null;
    case "high":
      return levels[levels.length - 1] ?? null;
    case "medium":
      return levels[Math.floor(levels.length / 2)] ?? null;
    case "auto":
    case "sleep":
    case "favorite":
      return null;
  }
}

const HVAC_MODE_ALIASES: Readonly<Record<string, string>> = {
  fan: "fan_only",
  fanonly: "fan_only",
  heat_cool: "auto",
};

const LIGHT_EFFECT_ALIASES: Readonly<Record<string, string>> = {
  moonlight: "Night",
  night: "Night",
  月光: "Night",
  月光模式: "Night",
  夜灯: "Night",
  夜灯模式: "Night",
  daylight: "Day",
  day: "Day",
  日光: "Day",
  日光模式: "Day",
};

export const IntentValidator = {
  normalize(op: IntentOperation, device: SmartDevice): IntentOperation | null {
    const k = device.kind;
    switch (op.kind) {
      case "power": {
        if (k.kind === "plug") {
          if (k.powerWritable === false) return null;
          if (k.switchEntityId.startsWith("button.") && !op.isOn) {
            return null;
          }
          return op;
        }
        if (k.kind === "light" || k.kind === "climate" || k.kind === "fan" || k.kind === "camera") {
          return k.powerWritable === false ? null : op;
        }
        if (k.kind === "appliance") {
          return k.powerPresent && k.powerWritable ? op : null;
        }
        if (k.kind === "vacuum") return k.actionsWritable === false ? null : op;
        return null;
      }
      case "brightness": {
        if (k.kind !== "light" || k.brightnessWritable === false || !Number.isFinite(op.percent)) return null;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(op.percent))) };
      }
      case "brightnessStep": {
        if (k.kind !== "light" || k.brightnessWritable === false || !Number.isFinite(op.delta)) return null;
        const base = k.isOn ? (k.brightnessPercent ?? 100) : 0;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(base + op.delta))) };
      }
      case "colorTemperature": {
        if (k.kind !== "light" || k.colorWritable === false || !Number.isFinite(op.kelvin) || op.kelvin <= 0) return null;
        return {
          kind: "colorTemperature",
          kelvin: Math.max(k.minKelvin, Math.min(k.maxKelvin, Math.round(op.kelvin))),
        };
      }
      case "lightEffect": {
        if (k.kind !== "light") return null;
        const trimmed = op.effect.trim();
        const direct = k.availableEffects.find((e) => e.toLowerCase() === trimmed.toLowerCase());
        if (direct) return { kind: "lightEffect", effect: direct };
        const canonical = LIGHT_EFFECT_ALIASES[trimmed.toLowerCase()] ?? LIGHT_EFFECT_ALIASES[trimmed];
        if (!canonical) return null;
        const matched = k.availableEffects.find((e) => e.toLowerCase() === canonical.toLowerCase());
        return matched ? { kind: "lightEffect", effect: matched } : null;
      }
      case "hvacMode": {
        if (k.kind === "climate") {
          if (k.availableModes.length === 0) return null;
          const lowered = op.mode.trim().toLowerCase();
          const direct = k.availableModes.find((m) => m.toLowerCase() === lowered);
          if (direct) return { kind: "hvacMode", mode: direct };
          const canonical = HVAC_MODE_ALIASES[lowered] ?? lowered;
          const matched = k.availableModes.find((m) => m.toLowerCase() === canonical);
          if (matched) return { kind: "hvacMode", mode: matched };
          if (canonical === "off") return { kind: "hvacMode", mode: "off" };
          // HA climate entities expose "heat_cool" where users say "auto".
          if (canonical === "auto") {
            const heatCool = k.availableModes.find((m) => m.toLowerCase() === "heat_cool");
            if (heatCool) return { kind: "hvacMode", mode: heatCool };
          }
          return null;
        }
        // 「自动模式」 parses as hvacMode(auto); on a fan that means its Auto preset (#98).
        if (k.kind === "fan" && op.mode.toLowerCase() === "auto") {
          const matched = matchFanSpeed("auto", k.availablePresetModes);
          return matched ? { kind: "fanSpeed", speed: matched } : null;
        }
        return null;
      }
      case "targetTemperature": {
        if (k.kind !== "climate" || k.temperatureWritable === false || !Number.isFinite(op.celsius)) return null;
        const clamped = Math.max(k.minTemp, Math.min(k.maxTemp, op.celsius));
        return { kind: "targetTemperature", celsius: clamped };
      }
      case "temperatureStep": {
        if (k.kind !== "climate" || k.temperatureWritable === false || !Number.isFinite(op.delta)) return null;
        const next = Math.max(k.minTemp, Math.min(k.maxTemp, k.targetTemperature + op.delta));
        return { kind: "targetTemperature", celsius: next };
      }
      case "fanSpeed": {
        const list =
          k.kind === "fan"
            ? k.availablePresetModes
            : k.kind === "climate"
              ? k.availableFanModes
              : null;
        if (!list || list.length === 0) return null;
        const matched = matchFanSpeed(op.speed, list);
        return matched ? { kind: "fanSpeed", speed: matched } : null;
      }
      case "oscillation": {
        if (k.kind !== "fan" || k.swingWritable === false || k.isOscillating === null) return null;
        return op;
      }
      case "activateScene":
        return null;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },

  sanitize(
    raw: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): DeviceIntent[] {
    const devMap = new Map(devices.map((d) => [d.id, d]));
    const sceneSet = new Set(scenes.map((s) => s.id));
    const seen = new Set<string>();
    const out: DeviceIntent[] = [];
    for (const intent of raw) {
      if (intent.operation.kind === "activateScene") {
        if (sceneSet.has(intent.targetId)) {
          const key = `scene:${intent.targetId}`;
          if (!seen.has(key)) {
            seen.add(key);
            out.push(intent);
          }
        }
        continue;
      }
      const dev = devMap.get(intent.targetId);
      if (!dev) continue;
      const norm = this.normalize(intent.operation, dev);
      if (norm) {
        const normalized: DeviceIntent = { targetId: dev.id, operation: norm };
        const key = `${normalized.targetId}:${JSON.stringify(normalized.operation)}`;
        if (!seen.has(key)) {
          seen.add(key);
          out.push(normalized);
        }
      }
    }
    return out;
  },

  commandsForIntent(intent: DeviceIntent, device: SmartDevice): DeviceCommand[] {
    const k = device.kind;
    const op = intent.operation;
    switch (op.kind) {
      case "power": {
        if (k.kind === "light")
          return k.powerWritable === false ? [] : [{ kind: "setLightPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "climate")
          return k.powerWritable === false
            ? []
            : [{ kind: "setClimatePower", entityId: k.entityId, isOn: op.isOn, resumeMode: "cool" }];
        if (k.kind === "fan")
          return k.powerWritable === false ? [] : [{ kind: "setFanPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "plug") {
          if (k.powerWritable === false) return [];
          if (k.switchEntityId.startsWith("button.")) {
            return op.isOn ? [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: true }] : [];
          }
          return [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: op.isOn }];
        }
        if (k.kind === "camera")
          return k.powerWritable === false ? [] : [{ kind: "setSwitch", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "vacuum")
          return k.actionsWritable === false
            ? []
            : [{ kind: "vacuumAction", entityId: k.entityId, action: op.isOn ? "start" : "returnToBase" }];
        if (k.kind === "cover") {
          if (k.motion !== "stopped" && k.pauseDescription) {
            return [{ kind: "setSelectOption", entityId: k.entityId, option: k.pauseDescription }];
          }
          const option = op.isOn ? k.openDescription : k.closeDescription;
          return option ? [{ kind: "setSelectOption", entityId: k.entityId, option }] : [];
        }
        if (k.kind === "appliance") {
          // The card's switch addresses the service that actually carries power (#300, #4).
          return k.powerPresent && k.powerWritable
            ? [{ kind: "setSwitch", entityId: k.powerEntityId, isOn: op.isOn }]
            : [];
        }
        if (k.kind === "generic") {
          const target = k.powerControl?.target;
          if (!target) return [];
          return target.kind === "property"
            ? [{ kind: "setMiotProperty", entityId: target.entityId, piid: target.piid, value: op.isOn }]
            : [{ kind: "pressButton", entityId: target.entityId }];
        }
        return [];
      }
      case "brightness":
        return k.kind === "light" && k.brightnessWritable !== false
          ? [{ kind: "setLightBrightness", entityId: k.entityId, percent: op.percent }]
          : [];
      case "colorTemperature":
        return k.kind === "light" && k.colorWritable !== false
          ? [{ kind: "setLightColorTemp", entityId: k.entityId, kelvin: op.kelvin }]
          : [];
      case "lightEffect":
        return k.kind === "light" ? [{ kind: "setLightEffect", entityId: k.entityId, effect: op.effect }] : [];
      case "hvacMode":
        return k.kind === "climate" && k.availableModes.length > 0
          ? [{ kind: "setClimateMode", entityId: k.entityId, hvacMode: op.mode }]
          : [];
      case "targetTemperature":
        return k.kind === "climate" && k.temperatureWritable !== false
          ? [{ kind: "setClimateTemperature", entityId: k.entityId, temperature: op.celsius }]
          : [];
      case "fanSpeed":
        if (k.kind === "fan" && k.availablePresetModes.length > 0)
          return [{ kind: "setFanPresetMode", entityId: k.entityId, presetMode: op.speed }];
        if (k.kind === "climate" && k.availableFanModes.length > 0)
          return [{ kind: "setClimateFanMode", entityId: k.entityId, fanMode: op.speed }];
        return [];
      case "oscillation":
        return k.kind === "fan" && k.swingWritable !== false
          ? [{ kind: "setFanOscillating", entityId: k.entityId, oscillating: op.enabled }]
          : [];
      case "brightnessStep":
      case "temperatureStep":
      case "activateScene":
        return [];
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

export const IntentReply = {
  fanSpeedLabel(speed: string): string {
    const m = /^level\s*([0-9]+)$/i.exec(speed.trim());
    if (m?.[1]) return `${m[1]} 档`;
    const map: Record<string, string> = {
      low: "低档",
      medium: "中档",
      high: "高档",
      auto: "自动",
      sleep: "睡眠",
      silent: "静音",
      favorite: "最爱",
      favourite: "最爱",
      manual: "手动",
    };
    return map[speed.toLowerCase()] ?? speed;
  },

  describe(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): string {
    if (intents.length === 0) return "未找到可执行的设备操作";
    const devMap = new Map(devices.map((d) => [d.id, d.name]));
    const sceneMap = new Map(scenes.map((s) => [s.id, s.name]));

    const firstOp = intents[0]?.operation;
    if (
      firstOp &&
      intents.every((i) => JSON.stringify(i.operation) === JSON.stringify(firstOp))
    ) {
      const names = intents
        .map((i) => devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId)
        .join("、");
      return this.describeOp(firstOp, names);
    }

    const parts = intents.map((i) => {
      const name = devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId;
      return this.describeOp(i.operation, name).replace(/^已/, "");
    });
    return `已${parts.join("，")}`;
  },

  describeOp(op: IntentOperation, targetNames: string): string {
    switch (op.kind) {
      case "power":
        return `已${op.isOn ? "打开" : "关闭"}${targetNames}`;
      case "brightness":
        return `已${targetNames}亮度调至 ${op.percent}%`;
      case "colorTemperature":
        return `已${targetNames}色温调至 ${op.kelvin}K`;
      case "lightEffect": {
        const label =
          op.effect.toLowerCase() === "night"
            ? "月光模式"
            : op.effect.toLowerCase() === "day"
              ? "日光模式"
              : op.effect;
        return `已${targetNames}切换为${label}`;
      }
      case "hvacMode": {
        const map: Record<string, string> = {
          cool: "制冷",
          heat: "制热",
          dry: "除湿",
          fan_only: "送风",
          auto: "自动",
          off: "关闭",
        };
        return `已${targetNames}设为${map[op.mode] ?? op.mode}模式`;
      }
      case "targetTemperature":
        return `已${targetNames}设为 ${op.celsius}°C`;
      case "fanSpeed":
        return `已${targetNames}风速调为 ${this.fanSpeedLabel(op.speed)}`;
      case "oscillation":
        return `已${targetNames}${op.enabled ? "开启摇头" : "停止摇头"}`;
      case "activateScene":
        return `已执行${targetNames}`;
      case "brightnessStep":
      case "temperatureStep":
        return `已调节${targetNames}`;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

// MARK: - 0ms Local Intent Parser


function isRelativeOp(op: IntentOperation): boolean {
  return op.kind === "brightnessStep" || op.kind === "temperatureStep";
}

function impliedCategories(ops: readonly IntentOperation[]): Set<IntentCategory> | null {
  for (const op of ops) {
    switch (op.kind) {
      case "brightness":
      case "brightnessStep":
      case "colorTemperature":
      case "lightEffect":
        return new Set(["light"]);
      case "hvacMode":
      case "targetTemperature":
      case "temperatureStep":
        return new Set(["climate", "heater"]);
      case "fanSpeed":
        return new Set(["fan", "airPurifier", "climate"]);
      case "oscillation":
        return new Set(["fan"]);
      case "power":
      case "activateScene":
        continue;
    }
  }
  return null;
}

function dispatchRank(op: IntentOperation): number {
  switch (op.kind) {
    case "power": return 0;
    case "hvacMode": return 1;
    case "targetTemperature":
    case "temperatureStep": return 2;
    case "lightEffect": return 3;
    case "brightness":
    case "brightnessStep": return 4;
    case "colorTemperature": return 5;
    case "activateScene": return 6;
    case "fanSpeed": return 7;
    case "oscillation": return 8;
  }
}

function reconcileOps(ops: readonly IntentOperation[]): IntentOperation[] | null {
  if (ops.length === 0) return null;
  const byRank = new Map<number, IntentOperation>();
  for (const op of ops) {
    const rank = dispatchRank(op);
    const existing = byRank.get(rank);
    if (existing && JSON.stringify(existing) !== JSON.stringify(op)) return null;
    byRank.set(rank, op);
  }
  const p = byRank.get(0);
  if (p?.kind === "power" && !p.isOn && byRank.size > 1) return null;
  if (p?.kind === "power" && p.isOn && (byRank.has(1) || byRank.has(3) || byRank.has(4) || byRank.has(5))) {
    byRank.delete(0);
  }
  return Array.from(byRank.keys())
    .sort((a, b) => a - b)
    .map((k) => byRank.get(k)!);
}

function buildPlanFromCandidates(
  candidates: readonly SmartDevice[],
  mustAcceptIds: ReadonlySet<string>,
  ops: readonly IntentOperation[],
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentPlan | null {
  const intents: DeviceIntent[] = [];
  for (const dev of candidates) {
    const normOps = ops
      .map((o) => IntentValidator.normalize(o, dev))
      .filter((o): o is IntentOperation => o !== null);
    if (normOps.length !== ops.length) {
      if (mustAcceptIds.has(dev.id)) return null;
      continue;
    }
    for (const no of normOps) {
      intents.push({ targetId: dev.id, operation: no });
    }
  }
  if (intents.length === 0) return null;
  return {
    intents,
    reply: IntentReply.describe(intents, devices, scenes),
    source: "local",
    suggestions: [],
  };
}

// MARK: - Bare Category Commands

export interface BareCategoryRoom {
  readonly id: string;
  readonly name: string;
}

export interface LocalIntentParseOptions {
  readonly panelRoom?: BareCategoryRoom | null;
  readonly usageOrder?: readonly string[];
}

export type BareCategoryResolution =
  | { readonly kind: "none"; readonly room: string | null }
  | { readonly kind: "run"; readonly devices: readonly SmartDevice[] }
  | { readonly kind: "candidates"; readonly devices: readonly SmartDevice[] };

const BARE_CATEGORY_NOUNS: Readonly<Record<IntentCategory, string>> = {
  light: "灯",
  climate: "空调",
  heater: "电暖器",
  fan: "风扇",
  airPurifier: "空气净化器",
  dehumidifier: "除湿机",
  diffuser: "香氛机",
  plug: "插座",
  vacuum: "扫地机",
  tv: "电视",
  camera: "摄像机",
  valve: "阀门",
  other: "设备",
};

export const BARE_CATEGORY_CANDIDATE_LIMIT = 4;

/**
 * Closing answers with the same-category devices that are on, opening with the ones that are off.
 * Opening offers one fewer candidate because widening what runs costs more when it guesses wrong.
 */
type BareCategoryDirection = "close" | "open";

const BARE_CATEGORY_CANDIDATE_LIMITS: Readonly<Record<BareCategoryDirection, number>> = {
  close: BARE_CATEGORY_CANDIDATE_LIMIT,
  open: 3,
};

/**
 * GLOSSARY `BareCategoryCommand`: 「关灯」 looks only at the same-category devices that are on and
 * 「开灯」 only at the ones that are off. One device runs directly; several use the room the panel
 * shows, or wait for a candidate tap. Shared with the macOS `BareCategoryCommand` and pinned by
 * `Tests/Fixtures/intent_golden.json`.
 */
export function resolveBareCategory(
  active: readonly SmartDevice[],
  panelRoom: BareCategoryRoom | null,
  usageOrder: readonly string[] = [],
): BareCategoryResolution {
  if (active.length === 0) return { kind: "none", room: null };
  if (active.length === 1) return { kind: "run", devices: [...active] };
  if (panelRoom && panelRoom.id) {
    const inRoom = active.filter((dev) => dev.roomId === panelRoom.id);
    return inRoom.length > 0
      ? { kind: "run", devices: inRoom }
      : { kind: "none", room: panelRoom.name };
  }
  const rank = new Map(usageOrder.map((id, index) => [id, index]));
  const ranked = active
    .map((device, index) => ({ device, index }))
    .sort((left, right) => {
      const leftRank = rank.get(left.device.id) ?? Number.MAX_SAFE_INTEGER;
      const rightRank = rank.get(right.device.id) ?? Number.MAX_SAFE_INTEGER;
      return leftRank === rightRank ? left.index - right.index : leftRank - rightRank;
    })
    .map((entry) => entry.device);
  return { kind: "candidates", devices: ranked };
}

type BareCategoryOutcome =
  | { readonly plan: IntentPlan }
  | { readonly targetIds: readonly string[] };

function bareCategoryAnswer(
  direction: BareCategoryDirection,
  category: IntentCategory,
  room: string | null,
): string {
  const noun = BARE_CATEGORY_NOUNS[category] ?? "设备";
  const state = direction === "open" ? "都开着" : "都关着";
  return room === null || room.length === 0 ? `${noun}${state}` : `${room}的${noun}${state}`;
}

/** The device is in the state the command would change, but nothing here can change it (a read-only camera). */
function bareCategoryBlockedReply(direction: BareCategoryDirection, category: IntentCategory): string {
  const noun = BARE_CATEGORY_NOUNS[category] ?? "设备";
  return direction === "open" ? `${noun}关着，但无法打开` : `${noun}开着，但无法关闭`;
}

function bareCategoryChoiceReply(direction: BareCategoryDirection, devices: readonly SmartDevice[]): string {
  const state = direction === "open" ? "关着" : "开着";
  return `${state}：${devices.map((dev) => dev.name).join("、")}。请说出房间或设备名`;
}

function bareCategorySuggestions(
  direction: BareCategoryDirection,
  candidates: readonly SmartDevice[],
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  const isOn = direction === "open";
  const prefix = isOn ? "bare:on" : "bare:off";
  const chips: AssistantSuggestion[] = candidates.slice(0, BARE_CATEGORY_CANDIDATE_LIMITS[direction]).map((dev) => {
    const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn } };
    return {
      id: `${prefix}:${dev.id}`,
      title: IntentReply.describe([intent], devices, scenes).replace(/^已/, ""),
      confidencePercent: null,
      intents: [intent],
    };
  });
  chips.push({
    id: `${prefix}:all`,
    title: isOn ? "全部打开" : "全部关掉",
    confidencePercent: null,
    intents: candidates.map((dev) => ({
      targetId: dev.id,
      operation: { kind: "power", isOn } as const,
    })),
  });
  return chips;
}

function bareCategoryOfflineReply(category: IntentCategory, room: string | null): string {
  const noun = BARE_CATEGORY_NOUNS[category] ?? "设备";
  return room === null || room.length === 0 ? `${noun}当前离线` : `${room}的${noun}当前离线`;
}

function bareCategoryOutcome(
  ops: readonly IntentOperation[],
  wanted: ReadonlySet<IntentCategory> | null,
  hasScope: boolean,
  hasRoomWord: boolean,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  options: LocalIntentParseOptions,
): BareCategoryOutcome | null {
  const operation = ops.length === 1 ? ops[0] : undefined;
  if (operation?.kind !== "power" || hasScope || hasRoomWord || wanted === null || wanted.size !== 1) return null;
  const direction: BareCategoryDirection = operation.isOn ? "open" : "close";
  const category = [...wanted][0]!;
  const allControllable = devices.filter((dev) => {
    const deviceCat = deviceCategory(dev);
    return isAssistantControllable(deviceCat) && wanted.has(deviceCat);
  });
  const sameCategory = allControllable.filter((dev) => dev.isOnline);
  const panelRoom = options.panelRoom ?? null;
  if (panelRoom && panelRoom.id) {
    const roomControllable = allControllable.filter((dev) => dev.roomId === panelRoom.id);
    if (roomControllable.length > 0 && roomControllable.every((dev) => !dev.isOnline)) {
      return {
        plan: {
          intents: [],
          reply: bareCategoryOfflineReply(category, panelRoom.name),
          source: "local",
          suggestions: [],
        },
      };
    }
  }
  if (allControllable.length > 0 && sameCategory.length === 0) {
    return {
      plan: {
        intents: [],
        reply: bareCategoryOfflineReply(category, null),
        source: "local",
        suggestions: [],
      },
    };
  }
  // The open rule starts when the home has more than one device of the category: a single one stays
  // unambiguous and keeps the existing direct behavior.
  if (direction === "open" && sameCategory.length <= 1) return null;
  // What is on answers a close and what is off answers an open, even when the device cannot perform
  // the operation (#273 review).
  const affected = sameCategory.filter((dev) =>
    direction === "close" ? isDeviceActiveOn(dev) : !isDeviceActiveOn(dev),
  );
  const switchable = affected.filter((dev) => {
    const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: direction === "open" } };
    return IntentValidator.commandsForIntent(intent, dev).length > 0;
  });
  if (affected.length > 0 && switchable.length === 0) {
    return {
      plan: {
        intents: [],
        reply: bareCategoryBlockedReply(direction, category),
        source: "local",
        suggestions: [],
      },
    };
  }
  const resolution = resolveBareCategory(switchable, panelRoom, options.usageOrder ?? []);
  switch (resolution.kind) {
    case "none":
      return {
        plan: {
          intents: [],
          reply: bareCategoryAnswer(direction, category, resolution.room),
          source: "local",
          suggestions: [],
        },
      };
    case "candidates":
      return {
        plan: {
          intents: [],
          reply: bareCategoryChoiceReply(direction, resolution.devices),
          source: "local",
          suggestions: bareCategorySuggestions(direction, resolution.devices, devices, scenes),
        },
      };
    case "run":
      return { targetIds: resolution.devices.map((dev) => dev.id) };
  }
}

const EN_ROOM_ALIASES: Readonly<Record<string, readonly string[]>> = {
  "master bedroom": ["主卧", "卧室", "master bedroom", "master"],
  "second bedroom": ["次卧", "小卧室", "second bedroom", "guest"],
  "guest room": ["次卧", "小卧室", "guest room"],
  "living room": ["客厅", "living room", "living"],
  "dining room": ["餐厅", "dining room", "dining"],
  "study room": ["书房", "study"],
  study: ["书房", "study"],
  bedroom: ["卧室", "主卧", "bedroom"],
  kitchen: ["厨房", "kitchen"],
  balcony: ["阳台", "balcony"],
  bathroom: ["卫生间", "浴室", "bathroom", "bath"],
  entryway: ["玄关", "entryway", "entry"],
};

const EN_SCOPE_WORDS = [
  "whole home", "entire home", "whole house", "everywhere", "everything", "all", "every",
];

const EN_CATEGORY_WORDS: ReadonlyArray<readonly [string, IntentCategory]> = [
  ["air conditioner", "climate"], ["air conditioning", "climate"],
  ["ceiling lights", "light"], ["ceiling light", "light"],
  ["bedside lamp", "light"], ["desk lamp", "light"], ["table lamp", "light"],
  ["screen bar", "light"], ["light strip", "light"],
  ["robot vacuum", "vacuum"], ["smart plug", "plug"], ["space heater", "heater"],
  ["standing fan", "fan"], ["air purifiers", "airPurifier"], ["air purifier", "airPurifier"],
  ["purifiers", "airPurifier"], ["purifier", "airPurifier"],
  ["fresh air", "airPurifier"], ["humidifiers", "airPurifier"], ["humidifier", "airPurifier"],
  ["lights", "light"], ["light", "light"], ["lamps", "light"], ["lamp", "light"],
  ["climate", "climate"], ["ac", "climate"],
  ["heater", "heater"], ["dehumidifier", "dehumidifier"], ["diffuser", "diffuser"],
  ["fans", "fan"], ["fan", "fan"],
  ["plugs", "plug"], ["plug", "plug"], ["socket", "plug"], ["outlet", "plug"],
  ["vacuum", "vacuum"],
  ["television", "tv"], ["tv", "tv"],
  ["cameras", "camera"], ["camera", "camera"],
  ["water valves", "valve"], ["water valve", "valve"],
  ["gas valves", "valve"], ["gas valve", "valve"],
  ["valves", "valve"], ["valve", "valve"],
];

const EN_FILLERS = [
  "please", "can", "could", "would", "you", "help", "me",
  "the", "my", "a", "an", "in", "at", "to", "by", "for", "into", "of",
  "set", "change", "switch", "adjust", "make", "it", "bit", "little",
  "mode", "room", "temperature", "temp", "brightness", "level", "speed",
].sort((a, b) => b.length - a.length);

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function consumeEnglishPhrase(phrase: string, state: { rest: string }): boolean {
  if (!phrase) return false;
  const escaped = escapeRegex(phrase);
  const isAscii = /^[\x00-\x7f]+$/.test(phrase);
  const pattern = isAscii ? `(?<![a-z0-9])${escaped}(?![a-z0-9])` : escaped;
  const regex = new RegExp(pattern, "g");
  if (!regex.test(state.rest)) return false;
  state.rest = state.rest.replace(new RegExp(pattern, "g"), ` ${CONSUMED_MARKER} `);
  return true;
}

function extractEnglishNumericOps(state: { rest: string }): IntentOperation[] {
  const ops: IntentOperation[] = [];
  const stepRegex = /(?<![a-z])(increase|raise|up|decrease|lower|down)(?:\s+by)?\s+(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)(?![a-z])/g;
  let stepMatched = false;
  for (const m of state.rest.matchAll(stepRegex)) {
    const dir = m[1] ?? "";
    const amount = Number(m[2]);
    if (Number.isFinite(amount)) {
      const sign = dir === "increase" || dir === "raise" || dir === "up" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      stepMatched = true;
    }
  }
  if (stepMatched) {
    state.rest = state.rest.replace(stepRegex, ` ${CONSUMED_MARKER} `);
  }

  const trailingStepRegex = /(?<![a-z0-9])(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)\s+(warmer|hotter|higher|cooler|colder|lower)(?![a-z])/g;
  let trailingStepMatched = false;
  for (const m of state.rest.matchAll(trailingStepRegex)) {
    const amount = Number(m[1]);
    const dir = m[2] ?? "";
    if (Number.isFinite(amount)) {
      const sign = dir === "warmer" || dir === "hotter" || dir === "higher" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      trailingStepMatched = true;
    }
  }
  if (trailingStepMatched) {
    state.rest = state.rest.replace(trailingStepRegex, ` ${CONSUMED_MARKER} `);
  }

  const numericPatterns: ReadonlyArray<readonly [RegExp, (val: number) => IntentOperation]> = [
    [/(?<![a-z0-9])(\d{4})\s*k(?![a-z0-9])/g, (v) => ({ kind: "colorTemperature", kelvin: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,3})\s*(?:%|percent)(?![a-z0-9])/g, (v) => ({ kind: "brightness", percent: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,2}(?:\.\d)?)\s*(?:degrees?\s*celsius|degrees?|deg|℃|°c|°)(?![a-z0-9])/g, (v) => ({ kind: "targetTemperature", celsius: v })],
  ];
  for (const [regex, make] of numericPatterns) {
    let matched = false;
    for (const m of state.rest.matchAll(regex)) {
      const val = Number(m[1]);
      if (Number.isFinite(val)) {
        ops.push(make(val));
        matched = true;
      }
    }
    if (matched) {
      state.rest = state.rest.replace(regex, ` ${CONSUMED_MARKER} `);
    }
  }
  return ops;
}

// MARK: - Chinese Consuming Parser (`LocalIntentParser.swift` parity)

function scenePlan(
  scene: HomeScene,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): IntentPlan {
  const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
  return {
    intents,
    reply: IntentReply.describe(intents, devices, scenes),
    source: "local",
    suggestions: [],
  };
}

function parseChineseDeviceCommand(
  text: string,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  options: LocalIntentParseOptions,
): IntentPlan | null {
  const panelRoom = options.panelRoom ?? null;
  const state = { rest: text };
  const rawOps: IntentOperation[] = extractChineseNumericOps(state);

  const devById = new Map(devices.map((d) => [d.id, d]));
  const explicitGroups: ReadonlyArray<string>[] = [];
  const nameGroups: ReadonlyArray<string>[] = [];
  for (const entry of buildDevicePhrases(devices)) {
    if (!consumeChinesePhrase(entry.phrase, state)) continue;
    if (entry.kind === "full") {
      explicitGroups.push(entry.ids);
    } else {
      nameGroups.push(entry.ids);
    }
  }

  const roomWordSet = new Set<string>(Object.keys(CN_ROOM_ALIASES));
  for (const d of devices) {
    if (d.roomName) roomWordSet.add(toSimplifiedChinese(d.roomName));
  }
  const matchedRooms = longestFirst(roomWordSet).filter((w) => consumeChinesePhrase(w, state));
  const hasScope = longestFirst(CN_SCOPE_WORDS).filter((w) => consumeChinesePhrase(w, state)).length > 0;
  const categories = new Set<IntentCategory>(
    longestFirst(Object.keys(CN_CATEGORY_WORDS))
      .filter((w) => consumeChinesePhrase(w, state))
      .map((w) => CN_CATEGORY_WORDS[w]!),
  );

  for (const word of longestFirst(Object.keys(CN_OSCILLATION_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "oscillation", enabled: CN_OSCILLATION_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_FAN_SPEED_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "fanSpeed", speed: CN_FAN_SPEED_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_BRIGHTNESS_STEP_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "brightnessStep", delta: CN_BRIGHTNESS_STEP_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_TEMPERATURE_STEP_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "temperatureStep", delta: CN_TEMPERATURE_STEP_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_LIGHT_EFFECT_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "lightEffect", effect: CN_LIGHT_EFFECT_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_BRIGHTNESS_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "brightness", percent: CN_BRIGHTNESS_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_COLOR_TEMPERATURE_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "colorTemperature", kelvin: CN_COLOR_TEMPERATURE_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_HVAC_MODE_WORDS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "hvacMode", mode: CN_HVAC_MODE_WORDS[word]! });
  }
  for (const word of longestFirst(Object.keys(CN_POWER_VERBS))) {
    if (consumeChinesePhrase(word, state)) rawOps.push({ kind: "power", isOn: CN_POWER_VERBS[word]! });
  }

  for (const word of longestFirst(CN_FILLERS)) {
    consumeChinesePhrase(word, state);
  }
  if (Array.from(state.rest).some((ch) => ch !== CONSUMED_MARKER)) {
    return null;
  }

  const ops = reconcileOps(rawOps);
  if (!ops) return null;

  const roomDeviceIds = new Set<string>();
  for (const w of matchedRooms) {
    const ids = chineseRoomDeviceIds(w, devices, panelRoom);
    if (ids === null) return null;
    for (const id of ids) roomDeviceIds.add(id);
  }
  const isTurningOff = ops.length === 1 && ops[0]?.kind === "power" && !ops[0].isOn;
  const mustAcceptIds = new Set<string>();
  let candidates: SmartDevice[] = [];

  if (explicitGroups.length > 0 || nameGroups.length > 0) {
    const targetIds: string[] = [];
    for (const group of explicitGroups) {
      const narrowedIds =
        group.length > 1 && matchedRooms.length > 0
          ? group.filter((id) => roomDeviceIds.has(id))
          : group;
      if (narrowedIds.length === 0) return null;
      const resolved = disambiguateRoomDevices(
        narrowedIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined),
        panelRoom,
      );
      if (resolved.length === 0) return null;
      for (const id of resolved) {
        if (!targetIds.includes(id)) targetIds.push(id);
        mustAcceptIds.add(id);
      }
    }
    for (const group of nameGroups) {
      const narrowedIds = matchedRooms.length === 0 ? group : group.filter((id) => roomDeviceIds.has(id));
      const resolved = disambiguateRoomDevices(
        narrowedIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined),
        panelRoom,
      );
      if (resolved.length === 0 || (resolved.length !== 1 && !hasScope)) return null;
      for (const id of resolved) {
        if (!targetIds.includes(id)) targetIds.push(id);
      }
      if (resolved.length === 1 && resolved[0]) mustAcceptIds.add(resolved[0]);
    }
    candidates = targetIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined);
  } else {
    const implied = impliedCategories(ops);
    const wanted = categories.size > 0 ? categories : implied;
    if (wanted === null && !isTurningOff) return null;
    if (!hasScope && matchedRooms.length === 0 && wanted === null) return null;

    const bare = bareCategoryOutcome(
      ops,
      wanted,
      hasScope,
      matchedRooms.length > 0,
      devices,
      scenes,
      options,
    );
    if (bare && "plan" in bare) return bare.plan;
    if (bare) {
      candidates = bare.targetIds
        .map((id) => devById.get(id))
        .filter((d): d is SmartDevice => d !== undefined);
    } else {
      const onlyActive = ops.every(isRelativeOp);
      candidates = devices.filter((dev) => {
        const cat = deviceCategory(dev);
        if (!dev.isOnline || !isAssistantControllable(cat) || !deviceAcceptsControlWrites(dev)) return false;
        if (cat === "valve" && !wanted?.has("valve")) return false;
        if (onlyActive && !isDeviceActiveOn(dev)) return false;
        if (matchedRooms.length > 0 && !roomDeviceIds.has(dev.id)) return false;
        if (wanted && !wanted.has(cat)) return false;
        return true;
      });
      if (!onlyActive && !hasScope && matchedRooms.length === 0 && candidates.length !== 1) {
        return null;
      }
    }
  }

  return buildPlanFromCandidates(candidates, mustAcceptIds, ops, devices, scenes);
}

export const LocalIntentParser = {
  parse(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    options: LocalIntentParseOptions = {},
  ): IntentPlan | null {
    const text = normalizeChineseUtterance(utterance);
    if (!text) return null;

    if (!/[\u4e00-\u9fff]/.test(utterance) && /[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes, options);
    }

    const sceneCore = strippedSceneText(text);
    const exactScene = scenes.find((scene) => scene.name && strippedSceneText(scene.name) === sceneCore);
    if (exactScene) {
      return scenePlan(exactScene, devices, scenes);
    }

    const devicePlan = parseChineseDeviceCommand(text, devices, scenes, options);
    if (devicePlan) return devicePlan;

    if (Array.from(sceneCore).length >= 2) {
      const containing = scenes.filter(
        (scene) => scene.name && strippedSceneText(scene.name).includes(sceneCore),
      );
      if (containing.length === 1 && containing[0]) {
        return scenePlan(containing[0], devices, scenes);
      }
    }

    if (/[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes, options);
    }
    return null;
  },

  parseEnglish(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    options: LocalIntentParseOptions = {},
  ): IntentPlan | null {
    const panelRoom = options.panelRoom ?? null;
    const lower = utterance
      .toLowerCase()
      .replace(/[,!?;:'"“”‘’。，！？、]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (!lower) return null;

    for (const scene of scenes) {
      if (!scene.name) continue;
      const sName = scene.name.toLowerCase();
      if (
        lower === `activate ${sName}` ||
        lower === `run ${sName}` ||
        lower === `start ${sName}` ||
        lower === `${sName} scene`
      ) {
        return scenePlan(scene, devices, scenes);
      }
    }

    const state = { rest: ` ${lower} ` };
    const rawOps: IntentOperation[] = extractEnglishNumericOps(state);

    const explicitGroups: SmartDevice[][] = [];
    const byLowerName = new Map<string, SmartDevice[]>();
    for (const dev of devices) {
      if (!dev.name) continue;
      const devLower = dev.name.toLowerCase();
      const group = byLowerName.get(devLower) ?? [];
      group.push(dev);
      byLowerName.set(devLower, group);
    }
    const sortedLowerNames = Array.from(byLowerName.keys()).sort((a, b) => b.length - a.length);
    for (const devLower of sortedLowerNames) {
      if (consumeEnglishPhrase(devLower, state)) {
        const matched = byLowerName.get(devLower) ?? [];
        if (matched.length > 0) explicitGroups.push(matched);
      }
    }

    const roomKeySet = new Set<string>(Object.keys(EN_ROOM_ALIASES));
    for (const d of devices) {
      if (d.roomName) roomKeySet.add(d.roomName.toLowerCase());
    }
    const allRoomKeys = Array.from(roomKeySet).sort((a, b) => b.length - a.length);
    const matchedRoomKeys: string[] = [];
    for (const roomKey of allRoomKeys) {
      if (consumeEnglishPhrase(roomKey, state)) {
        matchedRoomKeys.push(roomKey);
      }
    }

    let hasScope = false;
    for (const scopeWord of EN_SCOPE_WORDS) {
      if (consumeEnglishPhrase(scopeWord, state)) {
        hasScope = true;
      }
    }

    const oscPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["stop oscillating", false], ["stop oscillation", false], ["stop swing", false],
      ["oscillation off", false], ["swing off", false],
      ["start oscillating", true], ["oscillation on", true], ["swing on", true],
      ["oscillate", true], ["oscillation", true], ["swing", true],
    ];
    for (const [p, val] of oscPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "oscillation", enabled: val });
    }

    const fanPhrases: ReadonlyArray<readonly [string, string]> = [
      ["fan speed high", "high"], ["high fan speed", "high"], ["high speed", "high"], ["max speed", "high"],
      ["fan speed medium", "medium"], ["medium fan speed", "medium"], ["medium speed", "medium"],
      ["fan speed low", "low"], ["low fan speed", "low"], ["low speed", "low"], ["min speed", "low"],
      ["fan speed auto", "auto"], ["auto fan speed", "auto"], ["auto speed", "auto"],
      ["sleep mode", "sleep"], ["favorite mode", "favorite"],
    ];
    for (const [p, val] of fanPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "fanSpeed", speed: val });
    }

    const briStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit darker", -20], ["a little darker", -20], ["a bit dimmer", -20], ["a little dimmer", -20],
      ["dimmer", -20], ["darker", -20],
      ["a bit brighter", 20], ["a little brighter", 20], ["brighter", 20],
    ];
    for (const [p, val] of briStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightnessStep", delta: val });
    }

    const tempStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit warmer", 1], ["a little warmer", 1], ["warmer", 1], ["hotter", 1],
      ["a bit cooler", -1], ["a little cooler", -1], ["cooler", -1], ["colder", -1],
    ];
    for (const [p, val] of tempStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "temperatureStep", delta: val });
    }

    const effectPhrases: ReadonlyArray<readonly [string, string]> = [
      ["moonlight mode", "Night"], ["moonlight", "Night"],
      ["night light mode", "Night"], ["night light", "Night"], ["night mode", "Night"],
      ["daylight mode", "Day"], ["daylight", "Day"], ["day mode", "Day"],
    ];
    for (const [p, val] of effectPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "lightEffect", effect: val });
    }

    const briPhrases: ReadonlyArray<readonly [string, number]> = [
      ["minimum brightness", 10], ["dimmest", 10], ["dim", 20],
      ["maximum brightness", 100], ["max brightness", 100], ["full brightness", 100], ["brightest", 100],
    ];
    for (const [p, val] of briPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightness", percent: val });
    }

    const ctPhrases: ReadonlyArray<readonly [string, number]> = [
      ["warm light", 2700], ["warm white", 2700], ["yellow light", 2700],
      ["natural light", 4000], ["neutral white", 4000],
      ["white light", 6500], ["cool white", 6500], ["cold light", 6500],
    ];
    for (const [p, val] of ctPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "colorTemperature", kelvin: val });
    }

    const hvacPhrases: ReadonlyArray<readonly [string, string]> = [
      ["cooling mode", "cool"], ["cool mode", "cool"], ["cooling", "cool"], ["cool", "cool"],
      ["heating mode", "heat"], ["heat mode", "heat"], ["heating", "heat"], ["heat", "heat"],
      ["dry mode", "dry"], ["dehumidify", "dry"],
      ["fan only mode", "fan_only"], ["fan only", "fan_only"], ["fan mode", "fan_only"],
      ["auto mode", "auto"],
    ];
    for (const [p, val] of hvacPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "hvacMode", mode: val });
    }

    const powerPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["turn on", true], ["switch on", true], ["power on", true], ["enable", true], ["open", true],
      ["turn off", false], ["switch off", false], ["power off", false], ["shut off", false], ["disable", false], ["close", false],
      ["off", false], ["on", true],
    ];
    for (const [p, val] of powerPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "power", isOn: val });
    }

    const categories = new Set<IntentCategory>();
    for (const [phrase, cat] of EN_CATEGORY_WORDS) {
      if (consumeEnglishPhrase(phrase, state)) {
        categories.add(cat);
      }
    }

    for (const filler of EN_FILLERS) {
      consumeEnglishPhrase(filler, state);
    }

    if (state.rest.replaceAll(CONSUMED_MARKER, "").trim().length > 0) {
      return null;
    }

    const ops = reconcileOps(rawOps);
    if (!ops) return null;

    const roomDeviceIds = new Set<string>();
    for (const key of matchedRoomKeys) {
      const aliases = EN_ROOM_ALIASES[key] ?? [key];
      const matched = devices.filter((dev) => {
        const rLower = dev.roomName.toLowerCase();
        return aliases.some((a) => rLower === a.toLowerCase() || rLower.includes(a.toLowerCase()));
      });
      if (matched.length > 0) {
        const resolved = disambiguateRoomDevices(matched, panelRoom);
        if (resolved.length === 0) return null;
        for (const id of resolved) {
          roomDeviceIds.add(id);
        }
      }
    }

    const explicitIds: string[] = [];
    for (const group of explicitGroups) {
      const narrowed =
        group.length > 1 && matchedRoomKeys.length > 0
          ? group.filter((dev) => roomDeviceIds.has(dev.id))
          : group;
      if (narrowed.length === 0) return null;
      const resolved = disambiguateRoomDevices(narrowed, panelRoom);
      if (resolved.length === 0) return null;
      for (const id of resolved) {
        if (!explicitIds.includes(id)) explicitIds.push(id);
      }
    }

    const isTurningOff = ops.length === 1 && ops[0]?.kind === "power" && !ops[0].isOn;
    const mustAcceptIds = new Set<string>(explicitIds);
    let candidates: SmartDevice[] = [];

    if (explicitIds.length > 0) {
      const devById = new Map(devices.map((d) => [d.id, d]));
      candidates = explicitIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined);
    } else {
      const implied = impliedCategories(ops);
      const wanted = categories.size > 0 ? categories : implied;
      if (wanted === null && !isTurningOff) return null;
      if (!hasScope && matchedRoomKeys.length === 0 && wanted === null) return null;

      const bare = bareCategoryOutcome(
        ops,
        wanted,
        hasScope,
        matchedRoomKeys.length > 0,
        devices,
        scenes,
        options,
      );
      if (bare && "plan" in bare) return bare.plan;
      if (bare) {
        const devById = new Map(devices.map((d) => [d.id, d]));
        candidates = bare.targetIds
          .map((id) => devById.get(id))
          .filter((d): d is SmartDevice => d !== undefined);
      } else {
        const onlyActive = ops.every(isRelativeOp);
        candidates = devices.filter((dev) => {
          const cat = deviceCategory(dev);
          if (!dev.isOnline || !isAssistantControllable(cat) || !deviceAcceptsControlWrites(dev)) return false;
          if (cat === "valve" && !wanted?.has("valve")) return false;
          if (onlyActive && !isDeviceActiveOn(dev)) return false;
          if (matchedRoomKeys.length > 0 && !roomDeviceIds.has(dev.id)) return false;
          if (wanted && !wanted.has(cat)) return false;
          return true;
        });
        if (!onlyActive && !hasScope && matchedRoomKeys.length === 0 && candidates.length !== 1) {
          return null;
        }
      }
    }

    return buildPlanFromCandidates(candidates, mustAcceptIds, ops, devices, scenes);
  },
};
