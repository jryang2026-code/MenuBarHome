/**
 * 设备类型选择 (P4b-W): the user's persisted answer to "which of the delivered device types should
 * the panel draw?".
 *
 * The choice is a plain list of `DeviceCategoryID`s, stored next to the connection selection
 * (`haTransportGate.ts:CAPABILITY_SELECTION_STORAGE_KEY`, read by
 * `miAccountControl.ts:resolveMiAccountSelectionState` as `extraFields.enabledCategories`), so the
 * Mi/HA pruning plans (P3a-W, P3b-W) and the host write gate see one value (architecture.md §D).
 * Nothing here decides what stays read for an alert: that is `partitionCapabilityDevices` in the
 * shared verdict module, and this module only answers what the user will see before confirming.
 *
 * Three modes, one meaning per mode:
 * - `allSupportedTypes` 全部已支持类型 — the fresh-install and pre-P4b-W behaviour, nothing hidden.
 * - `lightAndSwitch` 只用灯和开关 — `DEVICE_CATEGORY_PRESETS.lightAndSwitch`, the one preset the
 *   shared corpus pins (`allSupportedTypes` is the manifest's own category order).
 * - `custom` 自己选 — the user's own list, e.g. lights + covers but no sensors.
 *
 * A missing stored value means "the user never chose", which resolves to all types — an upgrade keeps
 * exactly what it showed before. A stored value that cannot be read resolves to `null`, and every
 * caller keeps the value it already has (fail-closed; architecture.md §B upgrade path).
 */

import {
  CAPABILITY_EXPECTED_KIND, DEVICE_CATEGORY_IDS, DEVICE_CATEGORY_PRESETS,
  type CapabilityID, type DeviceCategoryID, type FeatureID,
} from "./capabilityManifest.js";
import {
  type AffectedReferenceItem, type CapabilityDeactivationVerdict, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import { tr3 } from "./safetyAndHealth.js";
import type { LanguagePreference } from "./i18n.js";

export const DEVICE_CATEGORY_SELECTION_MODES = ["allSupportedTypes", "lightAndSwitch", "custom"] as const;
export type DeviceCategorySelectionMode = (typeof DEVICE_CATEGORY_SELECTION_MODES)[number];

/** Every delivered device type, in the manifest's order — the order the picker lists them in. */
export const DELIVERED_DEVICE_CATEGORY_IDS: readonly DeviceCategoryID[] = DEVICE_CATEGORY_IDS;

const effectivePref = (pref?: LanguagePreference): LanguagePreference | undefined =>
  pref && pref !== "system" ? pref : undefined;

/** Category order is the manifest's, so two selections of the same types compare equal. */
function inCategoryOrder(ids: Iterable<DeviceCategoryID>): DeviceCategoryID[] {
  const set = new Set(ids);
  return DEVICE_CATEGORY_IDS.filter((id) => set.has(id));
}

export function sameDeviceCategories(
  a: readonly DeviceCategoryID[],
  b: readonly DeviceCategoryID[],
): boolean {
  const left = inCategoryOrder(a), right = inCategoryOrder(b);
  return left.length === right.length && left.every((id, index) => right[index] === id);
}

/**
 * Reads a stored selection. `null` means "unreadable — keep the value the app already has": an empty
 * or unknown-only list would hide every card, which is not a state the picker can produce, so it is
 * treated as corruption rather than as a choice.
 */
export function normalizeDeviceCategorySelection(raw: unknown): DeviceCategoryID[] | null {
  if (!Array.isArray(raw)) return null;
  const known = new Set<DeviceCategoryID>();
  for (const item of raw) {
    if (typeof item !== "string") return null;
    if ((DEVICE_CATEGORY_IDS as readonly string[]).includes(item)) known.add(item as DeviceCategoryID);
  }
  return known.size === 0 ? null : inCategoryOrder(known);
}

/** The mode that describes a set: a preset when it matches one exactly, otherwise the user's list. */
export function deviceCategorySelectionMode(
  categories: readonly DeviceCategoryID[],
): DeviceCategorySelectionMode {
  const normalized = inCategoryOrder(categories);
  for (const id of ["allSupportedTypes", "lightAndSwitch"] as const) {
    if (sameDeviceCategories(normalized, DEVICE_CATEGORY_PRESETS[id])) return id;
  }
  return "custom";
}

/**
 * Effective categories of one mode. `customCategories` is ignored by the presets; a custom list that
 * cannot be read falls back to all types so a half-built mode can never hide everything.
 */
export function deviceCategorySelectionFor(
  mode: DeviceCategorySelectionMode,
  customCategories: readonly DeviceCategoryID[],
): DeviceCategoryID[] {
  if (mode === "custom") {
    return normalizeDeviceCategorySelection(customCategories) ?? inCategoryOrder(DEVICE_CATEGORY_IDS);
  }
  return inCategoryOrder(DEVICE_CATEGORY_PRESETS[mode]);
}

/** Toggles one category inside a custom list, keeping the manifest's order. */
export function toggleDeviceCategory(
  categories: readonly DeviceCategoryID[],
  id: DeviceCategoryID,
): DeviceCategoryID[] {
  return inCategoryOrder(
    categories.includes(id) ? categories.filter((item) => item !== id) : [...categories, id],
  );
}

export const DEVICE_CATEGORY_LABELS = {
  light: ["灯", "燈", "Lights"],
  plug: ["插座与开关", "插座與開關", "Plugs & Switches"],
  climate: ["空调与温控", "空調與溫控", "Climate"],
  fan: ["风扇、净化与加湿", "風扇、淨化與加濕", "Fans, Purifiers & Humidifiers"],
  cover: ["窗帘与门", "窗簾與門", "Covers & Doors"],
  appliance: ["家电", "家電", "Appliances"],
  fridge: ["冰箱", "冰箱", "Fridges"],
  vacuum: ["扫地机", "掃地機", "Robot Vacuums"],
  speaker: ["音箱", "音箱", "Speakers"],
  tv: ["电视", "電視", "TVs"],
  camera: ["摄像机", "攝影機", "Cameras"],
  sensor: ["传感器", "感測器", "Sensors"],
  valve: ["阀门", "閥門", "Valves"],
  generic: ["其他设备", "其他裝置", "Other Devices"],
} as const satisfies Record<DeviceCategoryID, readonly [string, string, string]>;

/** One label per device type in the current UI language. */
export function deviceCategoryLabel(id: DeviceCategoryID, preference?: LanguagePreference): string {
  const [zhHans, zhHant, en] = DEVICE_CATEGORY_LABELS[id];
  return tr3(zhHans, zhHant, en, undefined, effectivePref(preference));
}

export const DEVICE_CATEGORY_SELECTION_MODE_LABELS = {
  allSupportedTypes: ["全部已支持类型", "全部已支援類型", "All Supported Types"],
  lightAndSwitch: ["只用灯和开关", "只用燈和開關", "Only Lights & Switches"],
  custom: ["自己选", "自己選", "Choose Myself"],
} as const satisfies Record<DeviceCategorySelectionMode, readonly [string, string, string]>;

export function deviceCategorySelectionModeLabel(
  mode: DeviceCategorySelectionMode,
  preference?: LanguagePreference,
): string {
  const [zhHans, zhHant, en] = DEVICE_CATEGORY_SELECTION_MODE_LABELS[mode];
  return tr3(zhHans, zhHant, en, undefined, effectivePref(preference));
}

export const FEATURE_LABELS = {
  "voice-input": ["语音输入", "語音輸入", "Voice input"],
  "ai-assistant": ["AI 一句话控制", "AI 一句話控制", "AI commands"],
  "proactive-suggestions": ["主动建议", "主動建議", "Proactive suggestions"],
  "companion-integration": ["外部快捷工具联动", "外部捷徑工具聯動", "Companion integration"],
  "event-automation": ["电脑状态自动化", "電腦狀態自動化", "Context automation"],
  grokball: ["桌面智能陪伴球", "桌面智慧陪伴球", "GrokBall"],
  "sensor-history": ["温湿度历史", "溫濕度歷史", "Sensor history"],
  "plug-energy": ["插座用电", "插座用電", "Plug energy"],
  "camera-live": ["摄像机实况", "攝影機實況", "Camera live view"],
} as const satisfies Record<FeatureID, readonly [string, string, string]>;

export const CONNECTION_LABELS = {
  "xiaomi-cloud": ["米家", "米家", "Xiaomi Home"],
  "home-assistant": ["Home Assistant", "Home Assistant", "Home Assistant"],
} as const satisfies Record<"xiaomi-cloud" | "home-assistant", readonly [string, string, string]>;

/** Any capability's user-facing name, so a cascade names what turns off instead of "子功能". */
export function capabilityDisplayLabel(id: CapabilityID, preference?: LanguagePreference): string {
  const pref = effectivePref(preference);
  switch (CAPABILITY_EXPECTED_KIND[id]) {
    case "feature": {
      const [zhHans, zhHant, en] = FEATURE_LABELS[id as FeatureID];
      return tr3(zhHans, zhHant, en, undefined, pref);
    }
    case "connection": {
      const [zhHans, zhHant, en] = CONNECTION_LABELS[id as keyof typeof CONNECTION_LABELS];
      return tr3(zhHans, zhHant, en, undefined, pref);
    }
    case "deviceCategory": return deviceCategoryLabel(id as DeviceCategoryID, pref);
  }
}

export const SAFETY_SIGNAL_LABELS = {
  leak: ["漏水", "漏水", "Leak"],
  smoke: ["烟雾", "煙霧", "Smoke"],
  gas: ["燃气", "燃氣", "Gas"],
  contact: ["门窗", "門窗", "Door/Window"],
  motion: ["人体移动", "人體移動", "Motion"],
  vibration: ["震动", "震動", "Vibration"],
  lock: ["门锁", "門鎖", "Locks"],
  doorbell: ["门铃", "門鈴", "Doorbell"],
  lowBattery: ["低电量", "低電量", "Low Battery"],
  longRunningPlug: ["插座长开", "插座長開", "Plug Left On"],
  longRunningClimate: ["空调长开", "空調長開", "Climate Left On"],
  highPower: ["高功率", "高功率", "High Power"],
  starredOffline: ["星标离线", "星標離線", "Starred Offline"],
} as const satisfies Record<SafetySignalKind, readonly [string, string, string]>;

export function safetySignalLabel(kind: SafetySignalKind, preference?: LanguagePreference): string {
  const [zhHans, zhHant, en] = SAFETY_SIGNAL_LABELS[kind];
  return tr3(zhHans, zhHant, en, undefined, effectivePref(preference));
}

/** How the picker names one affected timer, automation or quick action. */
export function affectedReferenceKindLabel(
  kind: AffectedReferenceItem["kind"],
  preference?: LanguagePreference,
): string {
  const pref = effectivePref(preference);
  switch (kind) {
    case "waitingTimer": return tr3("等待中的定时", "等待中的定時", "Waiting timer", undefined, pref);
    case "missedTimer": return tr3("错过的定时", "錯過的定時", "Missed timer", undefined, pref);
    case "foreignTimer": return tr3("其他来源的定时", "其他來源的定時", "Timer from another source", undefined, pref);
    case "automationRule": return tr3("自动化规则", "自動化規則", "Automation rule", undefined, pref);
    case "quickAction": return tr3("快捷动作", "捷徑動作", "Quick action", undefined, pref);
  }
}

export interface DeviceTypeSelectionCard {
  readonly id: string;
  readonly name: string;
  readonly category: DeviceCategoryID;
}

export interface DeviceTypeSelectionPreview {
  readonly currentCategories: readonly DeviceCategoryID[];
  readonly proposedCategories: readonly DeviceCategoryID[];
  /** Cards drawn today that this selection hides. */
  readonly hiddenCards: readonly DeviceTypeSelectionCard[];
  /**
   * Hidden cards whose signal an enabled alert still reads. They never become a card, a search hit,
   * an AI target or a control entry; only the alert evaluator sees them (architecture.md §D).
   */
  readonly retainedSafetyCards: readonly DeviceTypeSelectionCard[];
  /** The enabled alert signals the retained cards carry — what still fires after hiding. */
  readonly retainedSafetySignals: readonly SafetySignalKind[];
  /** Timers, enabled automations and quick actions that point at a card this would hide. */
  readonly affectedReferences: readonly AffectedReferenceItem[];
  /** The full P2b verdict: disposition, soft notices, blocking reasons, preserved preferences. */
  readonly verdict: CapabilityDeactivationVerdict;
}

