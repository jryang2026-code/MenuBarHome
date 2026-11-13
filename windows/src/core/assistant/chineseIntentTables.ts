import type { IntentOperation, SmartDevice } from "../models.js";
import type { IntentCategory } from "./deviceCategory.js";

export const CONSUMED_MARKER = "\u001f";

export interface RoomScope {
  readonly id: string;
  readonly name: string;
}

export const CN_POWER_VERBS: Readonly<Record<string, boolean>> = {
  打开: true, 开启: true, 开: true,
  关闭: false, 关掉: false, 关上: false, 熄灭: false, 熄掉: false, 关: false,
};

export const CN_BRIGHTNESS_WORDS: Readonly<Record<string, number>> = {
  调暗: 20, 变暗: 20, 最暗: 10,
  调亮: 100, 变亮: 100, 最亮: 100,
};

export const CN_COLOR_TEMPERATURE_WORDS: Readonly<Record<string, number>> = {
  暖光: 2700, 暖色: 2700, 黄光: 2700,
  自然光: 4000,
  白光: 6500, 冷光: 6500,
};

export const CN_LIGHT_EFFECT_WORDS: Readonly<Record<string, string>> = {
  月光模式: "Night", 月光灯: "Night", 月光: "Night",
  夜灯模式: "Night", 夜灯: "Night",
  日光模式: "Day", 日光灯: "Day", 日光: "Day",
};

export const CN_BRIGHTNESS_STEP_WORDS: Readonly<Record<string, number>> = {
  暗一点: -20, 暗一些: -20, 暗点: -20,
  亮一点: 20, 亮一些: 20, 亮点: 20,
};

export const CN_TEMPERATURE_STEP_WORDS: Readonly<Record<string, number>> = {
  高一点: 1, 高一些: 1, 低一点: -1, 低一些: -1,
  热一点: 1, 冷一点: -1, 凉快一点: -1,
};

export const CN_FAN_SPEED_WORDS: Readonly<Record<string, string>> = {
  高档: "high", 三档: "high", 高速: "high", 大风: "high", 最大风: "high", 强风: "high",
  风速调高: "high", 风速调大: "high", 风速最大: "high",
  中档: "medium", 二档: "medium", 中速: "medium", 风速调中: "medium",
  低档: "low", 一档: "low", 低速: "low", 小风: "low", 微风: "low", 最小风: "low",
  风速调低: "low", 风速调小: "low", 风速最小: "low",
  自动风: "auto", 自动档: "auto", 风速自动: "auto",
  睡眠模式: "sleep", 睡眠档: "sleep", 静音模式: "sleep", 静音档: "sleep",
  最爱模式: "favorite", 最爱档: "favorite", 最爱: "favorite",
};

export const CN_OSCILLATION_WORDS: Readonly<Record<string, boolean>> = {
  摇头: true, 摆头: true, 摆风: true,
  停止摇头: false, 关闭摇头: false, 关掉摇头: false, 不要摇头: false, 别摇头: false, 不摇头: false,
  停止摆头: false, 关闭摆头: false, 关掉摆头: false, 不要摆头: false, 别摆头: false, 不摆头: false,
  停止摆风: false, 关闭摆风: false, 关掉摆风: false, 不要摆风: false, 别摆风: false, 不摆风: false,
};

export const CN_HVAC_MODE_WORDS: Readonly<Record<string, string>> = {
  制冷: "cool", 制热: "heat", 除湿: "dry", 送风: "fan_only", 自动: "auto",
};

export const CN_SCOPE_WORDS = ["全部", "所有", "全屋", "全家", "家里", "整个家"];

export const CN_CATEGORY_WORDS: Readonly<Record<string, IntentCategory>> = {
  灯: "light", 灯光: "light", 电灯: "light",
  空调: "climate",
  暖气: "heater", 电暖器: "heater", 电暖气: "heater", 取暖器: "heater", 暖风机: "heater",
  风扇: "fan", 电风扇: "fan", 电扇: "fan",
  空气净化器: "airPurifier", 净化器: "airPurifier", 空净: "airPurifier",
  新风机: "airPurifier", 新风: "airPurifier", 加湿器: "airPurifier",
  除湿机: "dehumidifier", 香氛机: "diffuser",
  插座: "plug",
  扫地机: "vacuum", 扫地机器人: "vacuum",
  电视: "tv", 电视机: "tv",
  摄像头: "camera", 摄像机: "camera", 监控: "camera",
};

export const CN_ROOM_ALIASES: Readonly<Record<string, readonly string[]>> = {
  卧室: ["卧室", "主卧"], 主卧: ["主卧", "卧室"],
  次卧: ["次卧", "小卧室"], 小卧室: ["小卧室", "次卧"],
  客厅: ["客厅"], 书房: ["书房"], 厨房: ["厨房"], 阳台: ["阳台"], 餐厅: ["餐厅"],
  卫生间: ["卫生间", "浴室"], 浴室: ["浴室", "卫生间"],
};

export const CN_FILLERS = [
  "请", "帮我", "帮忙", "麻烦", "给我", "把", "将", "给", "一下", "一点", "一些",
  "吧", "了", "的", "呢", "啊", "呀", "都", "里", "模式",
  "再", "稍微", "稍", "更", "温度", "风速", "亮度", "色温",
  "调到", "调成", "调为", "调至", "设为", "设成", "设置为", "设置成", "设置", "调节", "调", "到", "为",
  "切换为", "切换到", "切到", "切为", "切成", "切换", "切", "改成", "改为",
];

const CN_SCENE_VERBS = ["执行", "启动", "打开", "开启", "激活", "切换到", "切换", "进入", "运行"].sort(
  (a, b) => Array.from(b).length - Array.from(a).length,
);
const CN_SCENE_SUFFIXES = ["场景", "模式"];
const CN_IGNORABLE_REGEX = /[\s，。！？、；：,!?;:~～"'“”‘’]+/g;

export function normalizeChineseUtterance(utterance: string): string {
  return utterance.replace(CN_IGNORABLE_REGEX, "").replace(/^\.+|\.+$/g, "");
}

export function strippedSceneText(raw: string): string {
  let s = normalizeChineseUtterance(raw);
  for (const verb of CN_SCENE_VERBS) {
    if (s.startsWith(verb)) {
      s = s.slice(verb.length);
      break;
    }
  }
  for (const suffix of CN_SCENE_SUFFIXES) {
    if (s.endsWith(suffix) && s.length > suffix.length) {
      s = s.slice(0, -suffix.length);
    }
  }
  return s;
}

export function longestFirst(words: Iterable<string>): string[] {
  return Array.from(new Set(words)).sort((a, b) => {
    const lenDiff = Array.from(b).length - Array.from(a).length;
    return lenDiff !== 0 ? lenDiff : a < b ? -1 : a > b ? 1 : 0;
  });
}

export function consumeChinesePhrase(phrase: string, state: { rest: string }): boolean {
  if (!phrase || !state.rest.includes(phrase)) return false;
  state.rest = state.rest.replaceAll(phrase, CONSUMED_MARKER);
  return true;
}

const CN_STEP_DIGITS: Readonly<Record<string, number>> = {
  一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10,
};

function spokenStepNumber(s: string): number | null {
  if (/^[0-9]+$/.test(s)) return Number(s);
  return CN_STEP_DIGITS[s] ?? null;
}

export function extractChineseNumericOps(state: { rest: string }): IntentOperation[] {
  const ops: IntentOperation[] = [];
  const stepRegex = /(调高|调低|升高|降低|升|降|高|低)(\d{1,2}|[一二两三四五六七八九十])(?:度|℃|°C|°)/gi;
  let stepMatched = false;
  for (const m of state.rest.matchAll(stepRegex)) {
    const direction = m[1] ?? "";
    const amount = spokenStepNumber(m[2] ?? "");
    if (amount !== null) {
      const sign = direction.includes("高") || direction.includes("升") ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      stepMatched = true;
    }
  }
  if (stepMatched) {
    state.rest = state.rest.replace(stepRegex, CONSUMED_MARKER);
  }

  const numericPatterns: ReadonlyArray<readonly [RegExp, (val: number) => IntentOperation]> = [
    [/(\d{4})[kK]/g, (v) => ({ kind: "colorTemperature", kelvin: Math.round(v) })],
    [/亮度(?:调到|调至|调为|设为|设置为|到|为)?(\d{1,3})(?:%|％)?/g, (v) => ({ kind: "brightness", percent: Math.round(v) })],
    [/(\d{1,3})(?:%|％)/g, (v) => ({ kind: "brightness", percent: Math.round(v) })],
    [/(\d{1,2}(?:\.\d)?)(?:度|℃|°C|°)/gi, (v) => ({ kind: "targetTemperature", celsius: v })],
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
      state.rest = state.rest.replace(regex, CONSUMED_MARKER);
    }
  }
  return ops;
}

export type DevicePhraseEntry =
  | { readonly phrase: string; readonly kind: "full"; readonly ids: readonly string[] }
  | { readonly phrase: string; readonly kind: "base"; readonly ids: readonly string[] };

export function buildDevicePhrases(devices: readonly SmartDevice[]): DevicePhraseEntry[] {
  const full = new Map<string, string[]>();
  const base = new Map<string, string[]>();
  for (const dev of devices) {
    if (!dev.name) continue;
    const fullIds = full.get(dev.name) ?? [];
    fullIds.push(dev.id);
    full.set(dev.name, fullIds);
    if (dev.roomName && dev.name.startsWith(dev.roomName)) {
      const stripped = dev.name.slice(dev.roomName.length);
      if (Array.from(stripped).length >= 2 && !(stripped in CN_CATEGORY_WORDS)) {
        const baseIds = base.get(stripped) ?? [];
        baseIds.push(dev.id);
        base.set(stripped, baseIds);
      }
    }
  }
  const phrases: DevicePhraseEntry[] = [];
  for (const [phrase, ids] of full) {
    phrases.push({ phrase, kind: "full", ids });
  }
  for (const [phrase, ids] of base) {
    if (!full.has(phrase)) {
      phrases.push({ phrase, kind: "base", ids });
    }
  }
  return phrases.sort((a, b) => Array.from(b.phrase).length - Array.from(a.phrase).length);
}

/**
 * When two homes/accounts share a display room name (e.g. two 客厅 with distinct roomIds),
 * narrow to the panel's selected roomId or refuse ambiguous cross-home execution (ADR-0010).
 */
export function disambiguateRoomDevices(
  matched: readonly SmartDevice[],
  panelRoom: RoomScope | null,
): string[] {
  const roomIdsByName = new Map<string, Set<string>>();
  for (const dev of matched) {
    if (!dev.roomName || !dev.roomId) continue;
    let ids = roomIdsByName.get(dev.roomName);
    if (!ids) {
      ids = new Set<string>();
      roomIdsByName.set(dev.roomName, ids);
    }
    ids.add(dev.roomId);
  }
  let hasCollision = false;
  for (const ids of roomIdsByName.values()) {
    if (ids.size > 1) {
      hasCollision = true;
      break;
    }
  }
  if (!hasCollision) return matched.map((dev) => dev.id);
  if (panelRoom && panelRoom.id && matched.some((dev) => dev.roomId === panelRoom.id)) {
    return matched.filter((dev) => dev.roomId === panelRoom.id).map((dev) => dev.id);
  }
  return [];
}

/**
 * Returns `null` when `word` matched at least one device whose room name collides across
 * distinct `roomId`s without a matching `panelRoom` (refuses partial cross-account execution).
 */
export function chineseRoomDeviceIds(
  word: string,
  devices: readonly SmartDevice[],
  panelRoom: RoomScope | null,
): string[] | null {
  const exact = devices.filter((dev) => dev.roomName === word);
  if (exact.length > 0) {
    const resolved = disambiguateRoomDevices(exact, panelRoom);
    return resolved.length === 0 ? null : resolved;
  }
  const aliases = CN_ROOM_ALIASES[word] ?? [word];
  const matched = devices.filter((dev) => aliases.some((a) => dev.roomName.includes(a)));
  if (matched.length === 0) return [];
  const resolved = disambiguateRoomDevices(matched, panelRoom);
  return resolved.length === 0 ? null : resolved;
}
