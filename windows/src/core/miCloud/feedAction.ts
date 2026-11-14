import { currentLanguage, setLanguage, speechLocale, t } from "../i18n.js";
import { facetAlertText, facetValue, humanizedFacetName } from "../miotFacetText.js";
import type { FacetArgument, FacetControl, FacetRange } from "../models.js";
import { isMiotAlertLabel, matchesMiotFacetPattern, type DeviceOverride } from "./facets.js";

/**
 * Feeding action portion bounds, default argument resolution, and 更多设置 write-lock / alert-reveal
 * helpers (#7), mirroring macOS `MiotFacetRange`, `MiotFacetEngine.controls`, and `MiotFacetText`.
 */

/**
 * Maximum entries a portion picker expands. Shipped feeders top out at 30 (`binuo.feeder.y1`);
 * 64 leaves room for wider specs while bounding malformed cloud ranges (§11).
 */
export const MAXIMUM_PORTION_OPTIONS = 64;

function integralPortionBounds(range: FacetRange | null | undefined): { lower: number; upper: number } | null {
  if (!range) return null;
  const { min, max, step } = range;
  if (!Number.isFinite(min) || !Number.isFinite(max) || !Number.isFinite(step) || step <= 0) {
    return null;
  }
  const lower = Math.ceil(min);
  const upper = Math.floor(max);
  if (!Number.isSafeInteger(lower) || !Number.isSafeInteger(upper) || lower > upper) {
    return null;
  }
  return { lower, upper };
}

/** Whole portions inside `range.min...range.max`, capped at `maxCount`, or `[]` when unusable. */
export function validPortionOptions(
  range: FacetRange | null | undefined,
  maxCount: number = MAXIMUM_PORTION_OPTIONS,
): number[] {
  if (!Number.isFinite(maxCount) || maxCount <= 0) return [];
  const bounds = integralPortionBounds(range);
  if (!bounds) return [];
  const options: number[] = [];
  const limit = Math.trunc(maxCount);
  for (let portion = bounds.lower; portion <= bounds.upper && options.length < limit; portion += 1) {
    options.push(portion);
  }
  return options;
}

/** `requested` clamped into `range`, or `null` when the range itself is unusable. */
export function clampRangePortion(
  range: FacetRange | null | undefined,
  requested?: number | null,
): number | null {
  const bounds = integralPortionBounds(range);
  if (!bounds) return null;
  const target =
    typeof requested === "number" && Number.isFinite(requested) ? Math.round(requested) : bounds.lower;
  return Math.min(bounds.upper, Math.max(bounds.lower, target));
}

export function portionRangeForControl(control: FacetControl): FacetRange | null {
  const index = control.portionArgumentIndex;
  const args = control.arguments ?? [];
  if (typeof index !== "number" || index < 0 || index >= args.length) return null;
  return args[index]?.range ?? null;
}

export function portionOptionsForControl(
  control: FacetControl,
  maxCount: number = MAXIMUM_PORTION_OPTIONS,
): number[] {
  return validPortionOptions(portionRangeForControl(control), maxCount);
}

/** Shared clamp used by the portion picker, confirmation copy, and MIoT action builder (#7). */
export function clampedPortionForControl(control: FacetControl, requested?: number | null): number {
  const fromRange = clampRangePortion(portionRangeForControl(control), requested);
  if (fromRange !== null) return fromRange;
  if (typeof requested === "number" && Number.isFinite(requested) && requested >= 1) {
    const rounded = Math.round(requested);
    if (Number.isSafeInteger(rounded)) return rounded;
  }
  return 1;
}

/** First input argument carrying a numeric range, matching macOS `portionArgumentIndex(in:)`. */
export function findPortionArgumentIndex(argumentsList: readonly FacetArgument[]): number | null {
  const index = argumentsList.findIndex((arg) => arg.range !== undefined);
  return index >= 0 ? index : null;
}

/**
 * Fallback value for a non-portion input argument: prefers an app/remote enum option so remote
 * feeding is not logged as a physical button press, otherwise uses the first option or `range.min`.
 */
export function defaultActionArgument(argument: FacetArgument): number {
  const options = argument.options;
  if (options && options.length > 0) {
    const preferred = ["remote", "app", "net", "cloud", "远程", "应用", "云端"];
    const chosen =
      options.find((option) =>
        preferred.some((word) => option.label.toLowerCase().includes(word)),
      ) ?? options[0]!;
    return chosen.value;
  }
  const min = argument.range?.min;
  return typeof min === "number" && Number.isFinite(min) ? min : 0;
}

/** Input values in spec order for a facet action; empty for a plain no-argument action. */
export function facetActionArguments(
  control: FacetControl,
  portion?: number | null,
): number[] {
  const args = control.arguments ?? [];
  if (args.length === 0) return [];
  return args.map((arg, index) => {
    if (index === control.portionArgumentIndex) {
      return clampRangePortion(arg.range, portion) ?? clampedPortionForControl(control, portion);
    }
    return defaultActionArgument(arg);
  });
}

/** Attaches formatted `fedToday` from a matching reading onto feeding controls (#7). */
export function attachFedToday(
  controls: FacetControl[],
  feeding: DeviceOverride["feeding"] | undefined,
): void {
  if (!feeding) return;
  const reading = controls.find(
    (control) =>
      control.kind === "reading" &&
      control.value !== null &&
      control.value !== undefined &&
      matchesMiotFacetPattern(control.name, feeding.fedToday),
  );
  if (!reading) return;
  const text = facetValue(reading);
  if (!text || text === "—") return;
  for (const control of controls) {
    if (control.isConfirmedWrite || control.portionArgumentIndex != null) {
      control.fedToday = text;
    }
  }
}

/** Confirmation banner copy for a feeding action, carrying portion count and `fedToday` (#7). */
export function feedingConfirmationBannerText(
  deviceName: string,
  control: FacetControl,
  portion?: number | null,
): string {
  const count = t("{count} 份", { count: clampedPortionForControl(control, portion) });
  if (control.fedToday) {
    return t("「{name}」将投喂 {count}，今日已投喂 {fed}。投喂后无法撤销，再点一次确认执行", {
      name: deviceName,
      count,
      fed: control.fedToday,
    });
  }
  return t("「{name}」将投喂 {count}。该设备未上报今日已投喂份数；投喂后无法撤销，再点一次确认执行", {
    name: deviceName,
    count,
  });
}

/** True when a writable facet stays locked until `allowAdvancedFacetWrites` is turned on. */
export function isAdvancedWriteLocked(control: FacetControl, allowsAdvancedWrites: boolean): boolean {
  if (!control.isWritable || allowsAdvancedWrites) return false;
  return !control.writesByDefault && !control.isConfirmedWrite;
}

/** True when every writable facet on the device is still locked behind advanced writes. */
export function showsAdvancedViewOnlyCopy(
  controls: readonly FacetControl[],
  allowsAdvancedWrites: boolean,
): boolean {
  const writable = controls.filter((control) => control.isWritable);
  if (writable.length === 0) return false;
  return writable.every((control) => isAdvancedWriteLocked(control, allowsAdvancedWrites));
}

function relatedControlName(name: string): string {
  for (const suffix of ["-status", "-alarm", "-fault"]) {
    if (name.endsWith(suffix)) return name.slice(0, -suffix.length);
  }
  return name;
}

function alertMatchesControl(alert: string, control: FacetControl): boolean {
  if (control.kind !== "reading") return false;
  const raw = control.value;
  const numeric = typeof raw === "number" ? raw : typeof raw === "string" && raw.trim() ? Number(raw) : NaN;
  const code = Math.sign(numeric) * Math.round(Math.abs(numeric));
  if (!Number.isSafeInteger(code)) return false;
  const option = control.options.find((item) => item.value === code);
  if (!option || !isMiotAlertLabel(option.label)) return false;
  const saved = currentLanguage();
  try {
    for (const lang of ["zh-Hans", "zh-Hant", "en"] as const) {
      setLanguage(lang);
      if (facetAlertText(control, option.label) === alert) return true;
    }
  } finally {
    setLanguage(saved);
  }
  return alert.endsWith(`：${option.label}`);
}

/**
 * Locked control id that addresses `alert`, or `null` when no locked control matches so the alert
 * banner never renders a dead-end `去处理` button (mirrors `MiotFacetText.lockedControlID`).
 */
export function lockedControlIdForAlert(
  alert: string,
  controls: readonly FacetControl[],
  allowsAdvancedWrites: boolean,
): string | null {
  const source = controls.find((control) => alertMatchesControl(alert, control));
  if (!source) return null;
  const stem = relatedControlName(source.name);
  const locked = controls.filter((control) => isAdvancedWriteLocked(control, allowsAdvancedWrites));
  const exact = locked.find((control) => control.name === stem);
  if (exact) return exact.id;
  const serviceSwitch = locked.find(
    (control) => control.serviceName === source.serviceName && control.name === "on",
  );
  return serviceSwitch?.id ?? null;
}

const SERVICE_TITLES: Readonly<Record<string, string>> = {
  "fan-control": "风扇",
  environment: "环境",
  "fresh-air": "新风",
  "floor-heat": "地暖",
  other: "其他",
  setting: "设置",
  setmode: "遥控设置",
  light: "灯光",
  "indicator-light": "指示灯",
  "physical-controls-locked": "按键锁",
  "memory-card-management": "存储卡",
  "motion-detection": "移动侦测",
  "p2p-stream": "视频流",
  speaker: "扬声器",
  "cockpit-service": "车载服务",
  "air-purifier": "净化器",
  "air-fresh": "新风",
  custom: "自定义",
  battery: "电池",
  vacuum: "扫地机",
  "zone-state-one": "播放分区",
  "device-state": "设备状态",
  "device-control": "按键",
  "play-control": "播放",
  television: "电视",
  "message-router": "消息",
  "power-consumption": "功耗",
  "ptz-control": "云台",
  feeder: "喂食器",
  "pet-feeder": "喂食器",
  "fish-tank": "鱼缸",
};

/** Localized service suffix for disambiguating duplicate facet labels (`模式 · 风扇`). */
export function facetServiceTitle(serviceName: string): string {
  if (speechLocale() !== "en-US") {
    const chinese = SERVICE_TITLES[serviceName];
    if (chinese) return t(chinese);
  }
  return humanizedFacetName(serviceName);
}
