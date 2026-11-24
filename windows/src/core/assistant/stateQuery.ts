import { t } from "../i18n.js";
import { deviceEnvironmentReading, isDeviceActiveOn, type IntentPlan, type SmartDevice } from "../models.js";
import { normalizeSearch, searchEntries, searchMatches } from "../panelSearch.js";
import { normalizeChineseUtterance } from "./chineseIntentTables.js";
import { deviceCategory } from "./deviceCategory.js";
import { IntentReply } from "./intent.js";

type QueryKind = "status" | "contact" | "temperature" | "setpoint" | "humidity" | "fanSpeed"
  | "activeLights" | "lightCount" | "anyActive" | "unsupported";
interface StateQuery {
  readonly kind: QueryKind;
  readonly target: string;
}

const patterns: ReadonlyArray<readonly [QueryKind, RegExp]> = [
  ["activeLights", /^(?:现在哪些|哪些)(灯)(?:开着|亮着)$/],
  ["lightCount", /^(?:现在)?有几(?:个|盏)(灯)(?:开着|亮着)$/],
  ["anyActive", /^(?:家里|全屋)?有没有(设备)开着$/],
  ["contact", /^(.+?)(?:关好|关上)(?:了)?(?:吗|没有|没)$/],
  ["setpoint", /^(.+?)(?:现在)?(?:设置|设定|设为)(?:了|是)?(?:多少度|几度)$/],
  ["temperature", /^(.+?)(?:现在)?(?:室温|温度)(?:是)?(?:多少(?:度)?|几度)$/],
  ["humidity", /^(.+?)(?:现在)?湿度(?:是)?多少$/],
  ["temperature", /^(.+?)(?:现在)?(?:是)?(?:多少度|几度)$/],
  ["fanSpeed", /^(.+?)(?:现在)?(?:风速|在|是)?几档$/],
  ["status", /^(.+?)(?:现在)?(?:开着|亮着|关着|打开了|关闭了|开了|关了)(?:吗|没有|没)$/],
  ["status", /^(.+?)(?:现在)?(?:是什么状态|什么状态)$/],
];

export function removingPoliteWrappers(text: string): string {
  return text.replace(/^(?:请问一下|请问|请|帮我|麻烦你|麻烦|能不能|能否|可以|谢谢|我想要|那个(?=麻烦))+/, "")
    .replace(/谢谢$/, "");
}

export function isPoliteActionQuestion(text: string): boolean {
  const action = removingPoliteWrappers(text);
  return action.endsWith("吗") && /^(?:请问(?:一下)?|请)?(?:可以|能不能|能否)/.test(text)
    && /^(?:把|将|打开|开启|关闭|关掉|关上|开|关|调|设|切)/.test(action);
}

export function parseStateQuery(utterance: string): StateQuery | null {
  const text = normalizeChineseUtterance(utterance);
  const polite = removingPoliteWrappers(text);
  const asksWhether = polite.includes("是不是");
  const question = polite.replaceAll("是不是", "");
  for (const [kind, pattern] of patterns) {
    const target = pattern.exec(question)?.[1];
    if (target) return { kind, target };
  }
  if (asksWhether) {
    const target = /^(.+?)(?:开着|亮着|关着|打开了|关闭了|开了|关了)$/.exec(question)?.[1];
    if (target) return { kind: "status", target };
  }
  const statusWords = "开着|亮着|关着|开了|关了|关好|关上|什么状态|温度|湿度|几度|几档";
  const mixedStatusQuestion = new RegExp(`(?:${statusWords})(?:了)?(?:吗|没有|没)`);
  const unsupported = (asksWhether && new RegExp(statusWords).test(question))
    || mixedStatusQuestion.test(question) || /扫地(?:机|机器人)在哪$/.test(question);
  return unsupported ? { kind: "unsupported", target: "" } : null;
}

function isMomentaryButton(device: SmartDevice): boolean {
  return device.kind.kind === "plug" && device.kind.switchEntityId.startsWith("button.");
}

function shortList(entries: readonly string[]): string {
  const first = entries.slice(0, 3).join(t("；"));
  return entries.length > 3 ? t("{list} 等 {count} 台", { list: first, count: entries.length }) : first;
}

function measurement(value: number | null | undefined, unit: string): string | null {
  if (value == null || !Number.isFinite(value)) return null;
  return (Number.isInteger(value) ? String(value) : value.toFixed(1)) + unit;
}

function deviceStatus(query: StateQuery, device: SmartDevice): string | null {
  if (!device.isOnline) return query.kind === "temperature" || query.kind === "humidity" ? null : t("离线");
  const kind = device.kind;
  switch (query.kind) {
    case "status": {
      if (kind.kind === "light" && kind.isOn && kind.brightnessPercent != null) {
        return t("开着，亮度 {percent}%", { percent: kind.brightnessPercent });
      }
      const active = kind.kind === "climate" ? kind.isOn && kind.hvacMode !== "off" : isDeviceActiveOn(device);
      return active ? t("开着") : t("关着");
    }
    case "contact":
      return kind.kind === "sensor" && kind.safetyObservations?.some((o) => o.kind === "contact" && o.alarming)
        ? t("已打开") : t("关好");
    case "temperature":
      return measurement(deviceEnvironmentReading(device)?.temperature, "°C");
    case "humidity":
      return measurement(deviceEnvironmentReading(device)?.humidity, "%");
    case "setpoint": {
      const value = kind.kind === "climate" ? measurement(kind.targetTemperature, "°C") : null;
      return value === null ? null : t("设定 {value}", { value });
    }
    case "fanSpeed":
      if (kind.kind !== "fan") return null;
      if (!kind.isOn) return t("关着");
      if (kind.presetMode) return IntentReply.fanSpeedLabel(kind.presetMode);
      return kind.percentage == null ? null : t("风速 {percent}%", { percent: kind.percentage });
    default:
      return null;
  }
}

export function answerStateQuery(query: StateQuery, devices: readonly SmartDevice[]): IntentPlan | null {
  const { kind, target } = query;
  if (kind === "unsupported") return null;
  let reply: string;
  if (kind === "activeLights" || kind === "lightCount" || kind === "anyActive") {
    const active = devices.filter((d) => d.isOnline && d.kind.kind !== "cover" && !isMomentaryButton(d)
      && (d.kind.kind === "climate" ? d.kind.isOn && d.kind.hvacMode !== "off" : isDeviceActiveOn(d))
      && (kind === "anyActive" || deviceCategory(d) === "light"));
    if (kind === "lightCount") reply = t("现在有 {count} 盏灯开着", { count: active.length });
    else if (kind === "anyActive") reply = active.length
      ? t("家里有 {count} 台设备开着", { count: active.length }) : t("家里没有设备开着");
    else reply = active.length ? t("{list} 开着", { list: shortList(active.map((d) => d.name)) }) : t("没有灯开着");
  } else {
    const eligible = devices.filter((d) => {
      if (d.kind.kind === "cover" || isMomentaryButton(d)) return false;
      if (kind === "contact") return d.kind.kind === "sensor" && d.kind.safetyObservations?.some((o) => o.kind === "contact");
      if (kind === "status") return d.kind.kind !== "sensor" && d.kind.kind !== "fridge";
      if (kind === "fanSpeed") return d.kind.kind === "fan";
      if (kind === "setpoint") return d.kind.kind === "climate";
      return true;
    });
    const byId = new Map(eligible.map((d) => [d.id, d]));
    const entries = searchEntries(eligible);
    const normalized = normalizeSearch(target);
    if (!normalized) return null;
    const exact = entries.filter((entry) => [entry.name, entry.pinyin, entry.initials].includes(normalized));
    let matches = exact.length ? exact : searchMatches(target, entries);
    if (!matches.length && target.endsWith("灯") && target.length > 1) {
      const lights = eligible.filter((d) => deviceCategory(d) === "light");
      matches = searchMatches(target.slice(0, -1), searchEntries(lights));
    }
    const statuses = matches.flatMap(({ deviceId }) => {
      const device = byId.get(deviceId);
      if (!device) return [];
      const status = deviceStatus(query, device);
      return status === null ? [] : [t("{name}：{status}", { name: device.name, status })];
    });
    if (!statuses.length) return null;
    reply = shortList(statuses);
  }
  return { intents: [], reply, source: "local", suggestions: [] };
}
