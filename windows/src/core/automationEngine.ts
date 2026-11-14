import { inverseCommands } from "./commandEffects.js";
import type { LanguagePreference } from "./i18n.js";
import {
  isDeviceActiveOn,
  type DeviceCommand,
  type DeviceIntent,
  type FacetControl,
  type HomeScene,
  type SmartDevice,
} from "./models.js";
import { planQuickAction, type QuickActionId } from "./quickActions.js";
import {
  defaultSafetyStorage,
  extractSensorObservations,
  tr3,
  type KeyValueStorageLike,
  type SensorAlertKind,
  type SensorObservation,
} from "./safetyAndHealth.js";

export type AutomationTrigger =
  | "away" | "back" | "screenLocked" | "screenUnlocked" | "displaySleep" | "displayWake"
  | "lidClosedSleep" | "systemSleep" | "systemWake" | "powerConnected" | "powerDisconnected"
  | "batteryBelowThreshold" | "powerSaverChanged" | "wifiNetworkJoined" | "wifiNetworkLeft"
  | "cameraInUse" | "cameraNotInUse" | "microphoneInUse" | "microphoneNotInUse"
  | "externalDisplayConnected" | "externalDisplayDisconnected" | "focusModeEnabled"
  | "focusModeDisabled" | "calendarMeetingStartingSoon" | "lateNightUsage"
  | "scheduledTime" | "sensorThreshold";

export const AUTOMATION_TRIGGERS: readonly AutomationTrigger[] = [
  "away", "back", "screenLocked", "screenUnlocked", "displaySleep", "displayWake",
  "lidClosedSleep", "systemSleep", "systemWake", "powerConnected", "powerDisconnected",
  "batteryBelowThreshold", "powerSaverChanged", "wifiNetworkJoined", "wifiNetworkLeft",
  "cameraInUse", "cameraNotInUse", "microphoneInUse", "microphoneNotInUse",
  "externalDisplayConnected", "externalDisplayDisconnected", "focusModeEnabled",
  "focusModeDisabled", "calendarMeetingStartingSoon", "lateNightUsage",
  "scheduledTime", "sensorThreshold",
] as const;

const TRIGGER_SET: ReadonlySet<string> = new Set(AUTOMATION_TRIGGERS);
const QUICK_ACTION_SET: ReadonlySet<string> = new Set<QuickActionId>(["lightsOff", "softNightLight", "climateSleepOff"]);

export function isAutomationTrigger(value: unknown): value is AutomationTrigger {
  return typeof value === "string" && TRIGGER_SET.has(value);
}

export type AutomationPermission = "location" | "focus" | "calendar";

export function automationRequiredPermission(trigger: AutomationTrigger): AutomationPermission | null {
  if (trigger === "wifiNetworkJoined" || trigger === "wifiNetworkLeft") return "location";
  if (trigger === "focusModeEnabled" || trigger === "focusModeDisabled") return "focus";
  if (trigger === "calendarMeetingStartingSoon") return "calendar";
  return null;
}

const TRIGGER_TITLES: Readonly<Record<AutomationTrigger, readonly [string, string, string]>> = {
  away: ["离开（锁屏 / 息屏 / 睡眠）", "離開（鎖屏 / 息屏 / 睡眠）", "Away (lock, display off, sleep)"],
  back: ["回来（解锁 / 唤醒）", "回來（解鎖 / 喚醒）", "Back (unlock, wake)"],
  screenLocked: ["锁屏（未休眠）", "鎖屏（未休眠）", "Screen locked (not asleep)"],
  screenUnlocked: ["屏幕解锁", "螢幕解鎖", "Screen unlocked"],
  displaySleep: ["显示器息屏", "顯示器息屏", "Display asleep"],
  displayWake: ["显示器亮屏", "顯示器亮屏", "Display woke up"],
  lidClosedSleep: ["合盖休眠", "闔蓋休眠", "Sleep after lid close"],
  systemSleep: ["系统休眠", "系統休眠", "System sleep"],
  systemWake: ["系统唤醒", "系統喚醒", "System wake"],
  powerConnected: ["接通电源", "接通電源", "Power connected"],
  powerDisconnected: ["断开电源", "中斷電源", "Power disconnected"],
  batteryBelowThreshold: ["电量低于阈值", "電量低於閾值", "Battery below threshold"],
  powerSaverChanged: ["节电模式变化", "節電模式變化", "Power saver changed"],
  wifiNetworkJoined: ["连接 Wi-Fi", "連線 Wi-Fi", "Wi-Fi network joined"],
  wifiNetworkLeft: ["离开 Wi-Fi", "離開 Wi-Fi", "Wi-Fi network left"],
  cameraInUse: ["摄像头开始使用（会议中）", "攝影機開始使用（會議中）", "Camera in use"],
  cameraNotInUse: ["摄像头停止使用", "攝影機停止使用", "Camera no longer in use"],
  microphoneInUse: ["麦克风开始使用（通话中）", "麥克風開始使用（通話中）", "Microphone in use"],
  microphoneNotInUse: ["麦克风停止使用", "麥克風停止使用", "Microphone no longer in use"],
  externalDisplayConnected: ["接入外接显示器", "接入外接顯示器", "External display connected"],
  externalDisplayDisconnected: ["断开外接显示器", "中斷外接顯示器", "External display disconnected"],
  focusModeEnabled: ["专注模式开启", "專注模式開啟", "Focus mode on"],
  focusModeDisabled: ["专注模式关闭", "專注模式關閉", "Focus mode off"],
  calendarMeetingStartingSoon: ["日历会议即将开始", "行事曆會議即將開始", "Calendar meeting starting soon"],
  lateNightUsage: ["深夜使用电脑", "深夜使用電腦", "Late-night computer use"],
  scheduledTime: ["定时触发", "定時觸發", "Scheduled time"],
  sensorThreshold: ["传感器状态联动", "感測器狀態聯動", "Sensor state linkage"],
};

export function automationTriggerTitle(trigger: AutomationTrigger, preference?: LanguagePreference): string {
  const [zhHans, zhHant, en] = TRIGGER_TITLES[trigger];
  return tr3(zhHans, zhHant, en, undefined, preference);
}

export interface LateNightWindow {
  readonly startHour: number;
  readonly endHour: number;
}

export function createLateNightWindow(startHour = 23, endHour = 6): LateNightWindow {
  return {
    startHour: Math.min(23, Math.max(0, Math.trunc(startHour))),
    endHour: Math.min(23, Math.max(0, Math.trunc(endHour))),
  };
}

export function lateNightWindowContains(window: LateNightWindow, timestampMs: number): boolean {
  if (window.startHour === window.endHour) return false;
  const hour = new Date(timestampMs).getHours();
  return window.startHour < window.endHour
    ? hour >= window.startHour && hour < window.endHour
    : hour >= window.startHour || hour < window.endHour;
}

export function lateNightAnchorKey(window: LateNightWindow, timestampMs: number): string | null {
  if (!lateNightWindowContains(window, timestampMs)) return null;
  const anchor = new Date(timestampMs);
  const hour = anchor.getHours();
  anchor.setHours(0, 0, 0, 0);
  if (window.startHour > window.endHour && hour < window.endHour) anchor.setDate(anchor.getDate() - 1);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return `${anchor.getFullYear()}-${pad(anchor.getMonth() + 1)}-${pad(anchor.getDate())}`;
}

export type SensorThresholdMetric = "temperature" | "humidity" | "battery" | "powerWatts" | "pm25" | "alarm";
export type SensorThresholdComparison = "gt" | "gte" | "lt" | "lte";

export interface SensorThresholdCondition {
  readonly deviceId: string;
  readonly metric: SensorThresholdMetric;
  readonly comparison?: SensorThresholdComparison;
  readonly threshold?: number;
  readonly alertKind?: SensorAlertKind;
}

export interface ScheduledTimeConfig {
  readonly hour: number;
  readonly minute: number;
  readonly weekdays?: readonly number[];
}

export interface AutomationTriggerOptions {
  readonly batteryThresholdPercent: number;
  readonly powerSaverEnabled?: boolean;
  readonly wifiSSID: string | null;
  readonly lateNightWindow: LateNightWindow;
  readonly calendarLeadMinutes: number;
  readonly scheduledTime?: ScheduledTimeConfig | null;
  readonly sensorCondition?: SensorThresholdCondition | null;
}

export function createAutomationTriggerOptions(
  partial: Partial<{
    readonly batteryThresholdPercent: number;
    readonly powerSaverEnabled: boolean;
    readonly wifiSSID: string | null;
    readonly lateNightStartHour: number;
    readonly lateNightEndHour: number;
    readonly lateNightWindow: LateNightWindow;
    readonly calendarLeadMinutes: number;
    readonly scheduledTime: ScheduledTimeConfig | null;
    readonly sensorCondition: SensorThresholdCondition | null;
  }> = {},
): AutomationTriggerOptions {
  const rawBattery = partial.batteryThresholdPercent ?? 20;
  const rawLead = partial.calendarLeadMinutes ?? 1;
  const trimmedSSID = partial.wifiSSID?.trim() ?? "";
  const window = partial.lateNightWindow
    ? createLateNightWindow(partial.lateNightWindow.startHour, partial.lateNightWindow.endHour)
    : createLateNightWindow(partial.lateNightStartHour ?? 23, partial.lateNightEndHour ?? 6);
  return {
    batteryThresholdPercent: Math.min(100, Math.max(1, Math.trunc(rawBattery))),
    ...(typeof partial.powerSaverEnabled === "boolean" ? { powerSaverEnabled: partial.powerSaverEnabled } : {}),
    wifiSSID: trimmedSSID === "" ? null : trimmedSSID,
    lateNightWindow: window,
    calendarLeadMinutes: Math.min(60, Math.max(1, Math.trunc(rawLead))),
    ...(partial.scheduledTime ? { scheduledTime: partial.scheduledTime } : {}),
    ...(partial.sensorCondition ? { sensorCondition: partial.sensorCondition } : {}),
  };
}

export const WIFI_SSID_LIMIT = 20;

export type AutomationWiFiCondition =
  | { readonly kind: "any" }
  | { readonly kind: "inAny"; readonly ssids: readonly string[] }
  | { readonly kind: "notIn"; readonly ssids: readonly string[] };

export function normalizeWiFiSSIDs(ssids: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of ssids) {
    if (typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
    if (out.length >= WIFI_SSID_LIMIT) break;
  }
  return out;
}

export type AutomationWiFiEvaluationStatus =
  | "satisfied" | "not-authorized" | "no-network" | "network-not-listed" | "network-excluded" | "empty-list";

export interface AutomationWiFiEvaluation {
  readonly status: AutomationWiFiEvaluationStatus;
  readonly isSatisfied: boolean;
  readonly ssid?: string;
}

export function evaluateWiFiCondition(
  condition: AutomationWiFiCondition,
  wifiSSID: string | null | undefined,
  isAuthorized = true,
): AutomationWiFiEvaluation {
  if (condition.kind === "any") return { status: "satisfied", isSatisfied: true };
  if (!isAuthorized) return { status: "not-authorized", isSatisfied: false };
  const ssid = wifiSSID?.trim() ?? "";
  if (!ssid) return { status: "no-network", isSatisfied: false };
  const list = normalizeWiFiSSIDs(condition.ssids);
  if (list.length === 0) return { status: "empty-list", isSatisfied: false };
  if (condition.kind === "inAny") {
    return list.includes(ssid)
      ? { status: "satisfied", isSatisfied: true, ssid }
      : { status: "network-not-listed", isSatisfied: false, ssid };
  }
  return list.includes(ssid)
    ? { status: "network-excluded", isSatisfied: false, ssid }
    : { status: "satisfied", isSatisfied: true, ssid };
}

export interface AutomationConditions {
  readonly wifi: AutomationWiFiCondition;
}

export function createAutomationConditions(wifi: AutomationWiFiCondition = { kind: "any" }): AutomationConditions {
  if (wifi.kind === "inAny") return { wifi: { kind: "inAny", ssids: normalizeWiFiSSIDs(wifi.ssids) } };
  if (wifi.kind === "notIn") return { wifi: { kind: "notIn", ssids: normalizeWiFiSSIDs(wifi.ssids) } };
  return { wifi: { kind: "any" } };
}

export type AutomationAction =
  | { readonly kind: "quickAction"; readonly quickAction: QuickActionId }
  | { readonly kind: "devices"; readonly deviceIds: readonly string[]; readonly isOn: boolean }
  | { readonly kind: "scene"; readonly sceneId: string };

export function automationActionIntents(action: AutomationAction): DeviceIntent[] {
  if (action.kind === "quickAction") return [];
  if (action.kind === "devices") {
    return action.deviceIds.map((id) => ({ targetId: id, operation: { kind: "power", isOn: action.isOn } }));
  }
  return [{ targetId: action.sceneId, operation: { kind: "activateScene" } }];
}

export function summarizeAutomationAction(
  action: AutomationAction,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  preference?: LanguagePreference,
): string {
  switch (action.kind) {
    case "quickAction": {
      const title =
        action.quickAction === "lightsOff"
          ? tr3("全屋关灯", "全屋關燈", "All Lights Off", undefined, preference)
          : action.quickAction === "softNightLight"
            ? tr3("柔和夜灯", "柔和夜燈", "Soft Night Light", undefined, preference)
            : tr3("关温控风扇", "關溫控風扇", "Sleep Climate Off", undefined, preference);
      return tr3("快捷动作：{title}", "捷徑動作：{title}", "Quick action: {title}", { title }, preference);
    }
    case "devices": {
      const names = action.deviceIds
        .map((id) => devices.find((d) => d.id === id)?.name)
        .filter((n): n is string => Boolean(n));
      const verb = action.isOn
        ? tr3("打开", "打開", "Turn on", undefined, preference)
        : tr3("关闭", "關閉", "Turn off", undefined, preference);
      if (names.length === 0) {
        return tr3("{verb} {count} 台设备", "{verb} {count} 台設備", "{verb} {count} device(s)", { verb, count: action.deviceIds.length }, preference);
      }
      const sep = tr3("、", "、", ", ", undefined, preference);
      const shown = names.slice(0, 3).join(sep);
      const remainder = names.length - Math.min(names.length, 3);
      if (remainder > 0) {
        return tr3("{verb}{shown} 等 {total} 台", "{verb}{shown} 等 {total} 台", "{verb} {shown} and {more} more", { verb, shown, total: names.length, more: remainder }, preference);
      }
      return tr3("{verb}{shown}", "{verb}{shown}", "{verb} {shown}", { verb, shown }, preference);
    }
    case "scene": {
      const name = scenes.find((s) => s.id === action.sceneId)?.name ?? action.sceneId;
      return tr3("场景：{name}", "場景：{name}", "Scene: {name}", { name }, preference);
    }
  }
}

export interface AutomationRule {
  readonly id: string;
  readonly isEnabled: boolean;
  readonly trigger: AutomationTrigger;
  readonly action: AutomationAction;
  readonly triggerOptions: AutomationTriggerOptions;
  readonly conditions: AutomationConditions;
}

let fallbackRuleCounter = 1;
function makeRuleId(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `auto-rule-${Date.now()}-${fallbackRuleCounter++}`;
}

export function createAutomationRule(args: {
  readonly id?: string;
  readonly trigger: AutomationTrigger;
  readonly action: AutomationAction;
  readonly isEnabled?: boolean;
  readonly triggerOptions?: Partial<Parameters<typeof createAutomationTriggerOptions>[0]>;
  readonly conditions?: AutomationConditions;
}): AutomationRule {
  return {
    id: args.id?.trim() ? args.id.trim() : makeRuleId(),
    isEnabled: args.isEnabled ?? true,
    trigger: args.trigger,
    action: args.action,
    triggerOptions: createAutomationTriggerOptions(args.triggerOptions),
    conditions: args.conditions ? createAutomationConditions(args.conditions.wifi) : createAutomationConditions(),
  };
}

export const AUTOMATION_POLICY = {
  triggerCooldownMs: 60 * 1000,
  nightlyCooldownMs: 24 * 60 * 60 * 1000,
  undoWindowMs: 5 * 60 * 1000,
} as const;

function parseStoredAction(raw: unknown): AutomationAction | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  if (obj.kind === "quickAction") {
    if (typeof obj.quickAction !== "string" || !QUICK_ACTION_SET.has(obj.quickAction)) return null;
    return { kind: "quickAction", quickAction: obj.quickAction as QuickActionId };
  }
  if (obj.kind === "devices") {
    if (!Array.isArray(obj.deviceIds) || typeof obj.isOn !== "boolean") return null;
    const ids = obj.deviceIds.filter((x): x is string => typeof x === "string" && x.trim() !== "");
    return { kind: "devices", deviceIds: ids, isOn: obj.isOn };
  }
  if (obj.kind === "scene") {
    if (typeof obj.sceneId !== "string" || obj.sceneId.trim() === "") return null;
    return { kind: "scene", sceneId: obj.sceneId };
  }
  return null;
}

function parseStoredWiFiCondition(raw: unknown): AutomationWiFiCondition {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { kind: "any" };
  const obj = raw as Record<string, unknown>;
  const ssids = Array.isArray(obj.ssids)
    ? normalizeWiFiSSIDs(obj.ssids.filter((x): x is string => typeof x === "string"))
    : [];
  if (obj.kind === "inAny") return { kind: "inAny", ssids };
  if (obj.kind === "notIn") return { kind: "notIn", ssids };
  return { kind: "any" };
}

function parseStoredRule(raw: unknown): AutomationRule | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.id !== "string" || obj.id.trim() === "") return null;
  if (typeof obj.isEnabled !== "boolean") return null;
  if (!isAutomationTrigger(obj.trigger)) return null;
  const action = parseStoredAction(obj.action);
  if (!action) return null;

  const optsObj = obj.triggerOptions && typeof obj.triggerOptions === "object" && !Array.isArray(obj.triggerOptions)
    ? (obj.triggerOptions as Record<string, unknown>)
    : {};
  const lateNightObj = optsObj.lateNightWindow && typeof optsObj.lateNightWindow === "object"
    ? (optsObj.lateNightWindow as Record<string, unknown>)
    : null;
  const scheduledRaw = optsObj.scheduledTime && typeof optsObj.scheduledTime === "object"
    ? (optsObj.scheduledTime as Record<string, unknown>)
    : null;
  const scheduledTime: ScheduledTimeConfig | null =
    scheduledRaw && typeof scheduledRaw.hour === "number" && typeof scheduledRaw.minute === "number"
      ? {
          hour: Math.min(23, Math.max(0, Math.trunc(scheduledRaw.hour))),
          minute: Math.min(59, Math.max(0, Math.trunc(scheduledRaw.minute))),
          ...(Array.isArray(scheduledRaw.weekdays)
            ? { weekdays: scheduledRaw.weekdays.filter((d): d is number => typeof d === "number" && d >= 0 && d <= 6) }
            : {}),
        }
      : null;

  const sensorRaw = optsObj.sensorCondition && typeof optsObj.sensorCondition === "object"
    ? (optsObj.sensorCondition as Record<string, unknown>)
    : null;
  const sensorCondition: SensorThresholdCondition | null =
    sensorRaw && typeof sensorRaw.deviceId === "string" && typeof sensorRaw.metric === "string"
      ? {
          deviceId: sensorRaw.deviceId,
          metric: sensorRaw.metric as SensorThresholdMetric,
          ...(typeof sensorRaw.comparison === "string" ? { comparison: sensorRaw.comparison as SensorThresholdComparison } : {}),
          ...(typeof sensorRaw.threshold === "number" ? { threshold: sensorRaw.threshold } : {}),
          ...(typeof sensorRaw.alertKind === "string" ? { alertKind: sensorRaw.alertKind as SensorAlertKind } : {}),
        }
      : null;

  const triggerOptions = createAutomationTriggerOptions({
    batteryThresholdPercent: typeof optsObj.batteryThresholdPercent === "number" ? optsObj.batteryThresholdPercent : 20,
    ...(typeof optsObj.powerSaverEnabled === "boolean" ? { powerSaverEnabled: optsObj.powerSaverEnabled } : {}),
    wifiSSID: typeof optsObj.wifiSSID === "string" ? optsObj.wifiSSID : null,
    lateNightStartHour:
      typeof optsObj.lateNightStartHour === "number"
        ? optsObj.lateNightStartHour
        : typeof lateNightObj?.startHour === "number" ? lateNightObj.startHour : 23,
    lateNightEndHour:
      typeof optsObj.lateNightEndHour === "number"
        ? optsObj.lateNightEndHour
        : typeof lateNightObj?.endHour === "number" ? lateNightObj.endHour : 6,
    calendarLeadMinutes: typeof optsObj.calendarLeadMinutes === "number" ? optsObj.calendarLeadMinutes : 1,
    scheduledTime,
    sensorCondition,
  });

  const condObj = obj.conditions && typeof obj.conditions === "object" && !Array.isArray(obj.conditions)
    ? (obj.conditions as Record<string, unknown>)
    : {};
  const conditions = createAutomationConditions(parseStoredWiFiCondition(condObj.wifi));
  return { id: obj.id, isEnabled: obj.isEnabled, trigger: obj.trigger, action, triggerOptions, conditions };
}

export class AutomationRuleStore {
  public static readonly storageKey = "automation_rules_v1";
  constructor(private readonly storage: KeyValueStorageLike = defaultSafetyStorage()) {}

  public load(): AutomationRule[] {
    try {
      const raw = this.storage.getItem(AutomationRuleStore.storageKey);
      if (!raw) return [];
      const parsed = JSON.parse(raw) as unknown;
      if (!Array.isArray(parsed)) return [];
      return parsed.map(parseStoredRule).filter((r): r is AutomationRule => r !== null);
    } catch {
      return [];
    }
  }

  public save(rules: readonly AutomationRule[]): void {
    try {
      const serializable = rules.map((r) => ({
        id: r.id,
        isEnabled: r.isEnabled,
        trigger: r.trigger,
        action: r.action,
        triggerOptions: {
          batteryThresholdPercent: r.triggerOptions.batteryThresholdPercent,
          ...(r.triggerOptions.powerSaverEnabled !== undefined ? { powerSaverEnabled: r.triggerOptions.powerSaverEnabled } : {}),
          ...(r.triggerOptions.wifiSSID !== null ? { wifiSSID: r.triggerOptions.wifiSSID } : {}),
          lateNightStartHour: r.triggerOptions.lateNightWindow.startHour,
          lateNightEndHour: r.triggerOptions.lateNightWindow.endHour,
          calendarLeadMinutes: r.triggerOptions.calendarLeadMinutes,
          ...(r.triggerOptions.scheduledTime ? { scheduledTime: r.triggerOptions.scheduledTime } : {}),
          ...(r.triggerOptions.sensorCondition ? { sensorCondition: r.triggerOptions.sensorCondition } : {}),
        },
        conditions: r.conditions,
      }));
      this.storage.setItem(AutomationRuleStore.storageKey, JSON.stringify(serializable));
    } catch {
    }
  }
}

export class AutomationTriggerDeduper {
  public static readonly storageKey = "automation_trigger_last_fired_v1";
  constructor(private readonly storage: KeyValueStorageLike = defaultSafetyStorage()) {}

  public lastFireAtMs(key: string): number | null {
    const raw = this.readStamps()[key];
    if (typeof raw !== "number" || !Number.isFinite(raw)) return null;
    return raw < 1e11 ? raw * 1000 : raw;
  }

  public shouldFire(key: string, nowMs = Date.now(), cooldownMs: number = AUTOMATION_POLICY.triggerCooldownMs): boolean {
    const lastMs = this.lastFireAtMs(key);
    if (lastMs !== null && nowMs - lastMs >= 0 && nowMs - lastMs < cooldownMs) return false;
    const stamps = this.readStamps();
    stamps[key] = nowMs / 1000;
    this.writeStamps(stamps);
    return true;
  }

  private readStamps(): Record<string, number> {
    try {
      const raw = this.storage.getItem(AutomationTriggerDeduper.storageKey);
      if (!raw) return {};
      const out: Record<string, number> = {};
      for (const [k, v] of Object.entries(JSON.parse(raw) as Record<string, unknown>)) {
        if (typeof v === "number" && Number.isFinite(v)) out[k] = v;
      }
      return out;
    } catch { return {}; }
  }

  private writeStamps(stamps: Readonly<Record<string, number>>): void {
    try { this.storage.setItem(AutomationTriggerDeduper.storageKey, JSON.stringify(stamps)); } catch {}
  }
}

export function rulesForTrigger(trigger: AutomationTrigger, rules: readonly AutomationRule[]): AutomationRule[] {
  return rules.filter((r) => r.isEnabled && r.trigger === trigger);
}

export type AwaySignal = "screenLocked" | "screenUnlocked" | "willSleep" | "displayDidSleep";

export type AwayOutcome = "screenLockedOnly" | "lidClosedSleep" | "systemSleep";

export function awayOutcomeTrigger(outcome: AwayOutcome): AutomationTrigger {
  if (outcome === "screenLockedOnly") return "screenLocked";
  return outcome === "lidClosedSleep" ? "lidClosedSleep" : "systemSleep";
}

export class AwayArbitrator {
  public static readonly lockDebounceMs = 2_000;
  public static readonly postSleepSuppressionMs = 3_000;

  private pendingLockAtMs: number | null = null;
  private lastSleepAtMs: number | null = null;

  public get pendingDeadlineMs(): number | null {
    return this.pendingLockAtMs !== null ? this.pendingLockAtMs + AwayArbitrator.lockDebounceMs : null;
  }

  public get hasPendingLock(): boolean {
    return this.pendingLockAtMs !== null;
  }

  public reset(): void {
    this.pendingLockAtMs = null;
    this.lastSleepAtMs = null;
  }

  public ingest(signal: AwaySignal, lidClosed: boolean, nowMs: number): AwayOutcome | null {
    switch (signal) {
      case "screenLocked":
        if (this.recentlySlept(nowMs)) return null;
        if (this.pendingLockAtMs === null) this.pendingLockAtMs = nowMs;
        return null;
      case "willSleep":
        this.lastSleepAtMs = nowMs;
        this.pendingLockAtMs = null;
        return lidClosed ? "lidClosedSleep" : "systemSleep";
      case "displayDidSleep":
        return null;
      case "screenUnlocked":
        this.pendingLockAtMs = null;
        return null;
    }
  }

  public flush(nowMs: number): AwayOutcome | null {
    if (this.pendingLockAtMs === null) return null;
    const elapsed = nowMs - this.pendingLockAtMs;
    if (elapsed >= 0 && elapsed < AwayArbitrator.lockDebounceMs) return null;
    this.pendingLockAtMs = null;
    return this.recentlySlept(nowMs) ? null : "screenLockedOnly";
  }

  private recentlySlept(nowMs: number): boolean {
    if (this.lastSleepAtMs === null) return false;
    const elapsed = nowMs - this.lastSleepAtMs;
    return elapsed >= 0 && elapsed < AwayArbitrator.postSleepSuppressionMs;
  }
}

export interface SystemContextSnapshot {
  readonly isLocked: boolean;
  readonly isDisplayAsleep: boolean;
  readonly isSystemAsleep: boolean;
  readonly lidClosed: boolean;
  readonly onExternalPower: boolean | null;
  readonly batteryPercent: number | null;
  readonly powerSaverEnabled: boolean;
  readonly wifiSSID: string | null;
  readonly wifiAuthorized: boolean;
  readonly cameraInUse: boolean;
  readonly microphoneInUse: boolean;
  readonly externalDisplayCount: number;
  readonly focusModeEnabled: boolean;
}

export function createDefaultSystemContextSnapshot(partial: Partial<SystemContextSnapshot> = {}): SystemContextSnapshot {
  return {
    isLocked: false, isDisplayAsleep: false, isSystemAsleep: false, lidClosed: false,
    onExternalPower: null, batteryPercent: null, powerSaverEnabled: false,
    wifiSSID: null, wifiAuthorized: true, cameraInUse: false, microphoneInUse: false,
    externalDisplayCount: 0, focusModeEnabled: false,
    ...partial,
  };
}

export type SystemContextEvent =
  | { readonly kind: "lockChanged"; readonly isLocked: boolean; readonly lidClosed?: boolean }
  | { readonly kind: "displayPowerChanged"; readonly isAsleep: boolean }
  | { readonly kind: "systemSleep"; readonly lidClosed?: boolean }
  | { readonly kind: "systemWake" }
  | { readonly kind: "panelWake" }
  | { readonly kind: "powerChanged"; readonly onExternalPower?: boolean; readonly batteryPercent?: number | null; readonly powerSaverEnabled?: boolean }
  | { readonly kind: "wifiChanged"; readonly ssid: string | null; readonly isAuthorized?: boolean }
  | { readonly kind: "mediaCaptureChanged"; readonly cameraInUse?: boolean; readonly microphoneInUse?: boolean }
  | { readonly kind: "externalDisplayChanged"; readonly externalDisplayCount: number }
  | { readonly kind: "focusModeChanged"; readonly enabled: boolean }
  | { readonly kind: "calendarMeetingSoon"; readonly eventId: string; readonly startsInMinutes: number }
  | { readonly kind: "tick" };

export interface AutomationUndoStep {
  readonly deviceId: string;
  readonly commands: readonly DeviceCommand[];
}

export interface RecordedAutomationRun {
  readonly id: string;
  readonly ruleId: string;
  readonly trigger: AutomationTrigger;
  readonly triggerTitle: string;
  readonly summary: string;
  readonly steps: readonly AutomationUndoStep[];
  readonly kindSnapshots: ReadonlyMap<string, SmartDevice["kind"]>;
  readonly scope: string;
  readonly firedAtMs: number;
  readonly expiresAtMs: number;
}

export interface AutomationExecutionHost {
  devices: SmartDevice[];
  scenes: HomeScene[];
  deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  lastManuallyUsedLightId?: string | null;
  sourceRevision?: number;
  settings?: {
    readonly connectionMode?: string;
    readonly interfaceLanguage?: LanguagePreference;
  };
  lastUndoAction?: {
    readonly summary: string;
    readonly steps: readonly AutomationUndoStep[];
    readonly expiresAtMs: number;
  } | null;
  replyBanner?: {
    readonly text: string;
    readonly source: string;
    readonly isError?: boolean;
  } | null;
  applyCommand(command: DeviceCommand, silent?: boolean): Promise<boolean>;
  queueBackgroundRender?(): void;
}

function readSensorMetricValue(device: SmartDevice, metric: SensorThresholdMetric): number | null {
  const k = device.kind;
  switch (metric) {
    case "temperature":
      return k.kind === "sensor" ? k.temperature : k.kind === "climate" ? k.currentTemperature : k.kind === "fan" ? (k.temperature ?? null) : k.kind === "appliance" ? k.currentTemperature : null;
    case "humidity":
      return k.kind === "sensor" ? k.humidity : k.kind === "fan" ? (k.humidity ?? null) : k.kind === "appliance" ? k.currentHumidity : null;
    case "battery":
      return k.kind === "sensor" ? k.battery : k.kind === "cover" ? k.batteryPercent : k.kind === "vacuum" ? k.battery : null;
    case "powerWatts":
      return k.kind === "plug" ? k.powerWatts : null;
    case "pm25":
      return k.kind === "fan" ? (k.pm25Density ?? null) : null;
    case "alarm":
      return null;
  }
}

function compareMetric(value: number, comparison: SensorThresholdComparison, threshold: number): boolean {
  if (comparison === "gt") return value > threshold;
  if (comparison === "gte") return value >= threshold;
  if (comparison === "lt") return value < threshold;
  return value <= threshold;
}

function commandsForPowerIntent(device: SmartDevice, isOn: boolean): DeviceCommand[] {
  const k = device.kind;
  switch (k.kind) {
    case "light":
      return k.powerWritable === false ? [] : [{ kind: "setLightPower", entityId: k.entityId, isOn }];
    case "climate":
      return k.powerWritable === false
        ? []
        : [{ kind: "setClimatePower", entityId: k.entityId, isOn, resumeMode: k.hvacMode === "off" ? (k.availableModes.find((m) => m !== "off") ?? "auto") : k.hvacMode }];
    case "fan":
      return k.powerWritable === false ? [] : [{ kind: "setFanPower", entityId: k.entityId, isOn }];
    case "plug":
      return k.powerWritable === false ? [] : [{ kind: "setSwitch", entityId: k.switchEntityId, isOn }];
    case "camera":
      return k.powerWritable === false ? [] : [{ kind: "setSwitch", entityId: k.entityId, isOn }];
    case "appliance":
      return !k.powerPresent || !k.powerWritable ? [] : [{ kind: "setSwitch", entityId: k.powerEntityId, isOn }];
    case "vacuum":
      return k.actionsWritable === false ? [] : [{ kind: "vacuumAction", entityId: k.entityId, action: isOn ? "start" : "returnToBase" }];
    case "cover": {
      const option = isOn ? k.openDescription : k.closeDescription;
      return option ? [{ kind: "setSelectOption", entityId: k.entityId, option }] : [];
    }
    case "generic": {
      const target = k.powerControl?.target;
      if (!target) return [];
      return target.kind === "property"
        ? [{ kind: "setMiotProperty", entityId: target.entityId, piid: target.piid, value: isOn }]
        : [{ kind: "setSwitch", entityId: target.entityId, isOn }];
    }
    case "fridge":
    case "sensor":
    case "speaker":
      return [];
  }
}

export interface ExecuteAutomationRuleOptions {
  readonly nowMs?: number;
  readonly scope?: string;
  readonly displayDevices?: readonly SmartDevice[];
  readonly onUndoRecorded?: (run: RecordedAutomationRun) => void;
  readonly recordUndoKindSnapshots?: (
    action: NonNullable<AutomationExecutionHost["lastUndoAction"]>,
    snapshots: ReadonlyMap<string, SmartDevice["kind"]>,
  ) => void;
}

export async function executeAutomationRule(
  host: AutomationExecutionHost,
  rule: AutomationRule,
  options: ExecuteAutomationRuleOptions = {},
): Promise<RecordedAutomationRun | null> {
  const nowMs = options.nowMs ?? Date.now();
  const scope = options.scope ?? "default";
  const startingRevision = host.sourceRevision ?? 0;
  const preference = host.settings?.interfaceLanguage;
  const steps: AutomationUndoStep[] = [];
  const kindSnapshots = new Map<string, SmartDevice["kind"]>();

  if (rule.action.kind === "quickAction") {
    const planned = planQuickAction(rule.action.quickAction, host.devices, host.lastManuallyUsedLightId ?? null);
    for (const target of planned.targets) {
      if ((host.sourceRevision ?? 0) !== startingRevision) return null;
      let accepted = 0;
      for (const cmd of target.commands) {
        if (await host.applyCommand(cmd, true)) accepted += 1;
        else break;
      }
      if (accepted > 0 && target.restoreCommands.length > 0) {
        steps.push({ deviceId: target.deviceId, commands: target.restoreCommands });
        kindSnapshots.set(target.deviceId, target.previousKind);
      }
    }
  } else if (rule.action.kind === "devices") {
    for (const deviceId of rule.action.deviceIds) {
      if ((host.sourceRevision ?? 0) !== startingRevision) return null;
      const dev = host.devices.find((d) => d.id === deviceId);
      if (!dev || !dev.isOnline || isDeviceActiveOn(dev) === rule.action.isOn) continue;
      const cmds = commandsForPowerIntent(dev, rule.action.isOn);
      if (cmds.length === 0) continue;
      const previousKind = structuredClone(dev.kind);
      const restore = cmds.flatMap((cmd) => inverseCommands(dev, cmd));
      let accepted = 0;
      for (const cmd of cmds) {
        if (await host.applyCommand(cmd, true)) accepted += 1;
        else break;
      }
      if (accepted > 0 && restore.length > 0) {
        steps.push({ deviceId: dev.id, commands: restore });
        kindSnapshots.set(dev.id, previousKind);
      }
    }
  } else if (rule.action.kind === "scene") {
    const targetSceneId = rule.action.sceneId;
    const scene = host.scenes.find((s) => s.id === targetSceneId || s.entityId === targetSceneId);
    await host.applyCommand({ kind: "activateScene", entityId: scene?.entityId ?? targetSceneId }, true);
  }

  if ((host.sourceRevision ?? 0) !== startingRevision) return null;

  const actionSummary = summarizeAutomationAction(rule.action, options.displayDevices ?? host.devices, host.scenes, preference);
  const triggerLabel = automationTriggerTitle(rule.trigger, preference);
  const runSummary = tr3(
    "{trigger} · 已执行「{action}」",
    "{trigger} · 已執行「{action}」",
    "{trigger} · Executed \"{action}\"",
    { trigger: triggerLabel, action: actionSummary },
    preference,
  );
  const expiresAtMs = nowMs + AUTOMATION_POLICY.undoWindowMs;
  const recorded: RecordedAutomationRun = {
    id: `auto-run:${rule.id}:${nowMs}`,
    ruleId: rule.id,
    trigger: rule.trigger,
    triggerTitle: triggerLabel,
    summary: runSummary,
    steps,
    kindSnapshots,
    scope,
    firedAtMs: nowMs,
    expiresAtMs,
  };

  if (steps.length > 0) {
    const undoAction = { summary: runSummary, steps, expiresAtMs };
    options.recordUndoKindSnapshots?.(undoAction, kindSnapshots);
    host.lastUndoAction = undoAction;
  }
  host.replyBanner = {
    text: runSummary,
    source: tr3("状态感知自动化", "狀態感知自動化", "Context Automation", undefined, preference),
  };
  options.onUndoRecorded?.(recorded);
  host.queueBackgroundRender?.();
  return recorded;
}

export class AutomationEngine {
  public readonly store: AutomationRuleStore;
  public readonly deduper: AutomationTriggerDeduper;
  public readonly arbitrator = new AwayArbitrator();
  private context: SystemContextSnapshot = createDefaultSystemContextSnapshot();
  private hasLockBaseline = false;
  private sensorConditionEdge = new Map<string, boolean>();
  private batteryEdgeByRule = new Map<string, boolean>();

  constructor(storage: KeyValueStorageLike = defaultSafetyStorage()) {
    this.store = new AutomationRuleStore(storage);
    this.deduper = new AutomationTriggerDeduper(storage);
  }

  public get snapshot(): SystemContextSnapshot {
    return this.context;
  }

  public resetTransientState(): void {
    this.arbitrator.reset();
    this.hasLockBaseline = false;
    this.sensorConditionEdge.clear();
    this.batteryEdgeByRule.clear();
  }

  public primeLockBaseline(isLocked: boolean): void {
    this.context = { ...this.context, isLocked };
    this.hasLockBaseline = true;
  }

  public async dispatchEvent(
    host: AutomationExecutionHost,
    event: SystemContextEvent,
    options: ExecuteAutomationRuleOptions & {
      readonly rules?: readonly AutomationRule[];
      readonly observationsByDeviceId?: Readonly<Record<string, readonly SensorObservation[]>>;
    } = {},
  ): Promise<RecordedAutomationRun[]> {
    const nowMs = options.nowMs ?? Date.now();
    const rules = (options.rules ?? this.store.load()).filter((r) => r.isEnabled);
    const wifiOk = (rule: AutomationRule, ssid = this.context.wifiSSID, auth = this.context.wifiAuthorized): boolean =>
      evaluateWiFiCondition(rule.conditions.wifi, ssid, auth).isSatisfied;

    const matchedRules: AutomationRule[] = [];
    const pushRulesFor = (
      trigger: AutomationTrigger,
      dedupeKey: string = trigger,
      cooldownMs: number = AUTOMATION_POLICY.triggerCooldownMs,
      predicate?: (rule: AutomationRule) => boolean,
    ): void => {
      const candidates = rules.filter((r) => r.trigger === trigger && (predicate ? predicate(r) : true) && wifiOk(r));
      if (candidates.length === 0) return;
      if (!this.deduper.shouldFire(dedupeKey, nowMs, cooldownMs)) return;
      matchedRules.push(...candidates);
    };

    switch (event.kind) {
      case "lockChanged": {
        const lidClosed = event.lidClosed ?? this.context.lidClosed;
        const wasLocked = this.context.isLocked;
        this.context = { ...this.context, isLocked: event.isLocked, lidClosed };
        if (!this.hasLockBaseline) {
          this.hasLockBaseline = true;
          break;
        }
        if (event.isLocked === wasLocked) break;
        if (event.isLocked) {
          pushRulesFor("away");
          const outcome = this.arbitrator.ingest("screenLocked", lidClosed, nowMs);
          if (outcome) pushRulesFor(awayOutcomeTrigger(outcome));
        } else {
          this.arbitrator.ingest("screenUnlocked", lidClosed, nowMs);
          pushRulesFor("back");
          pushRulesFor("screenUnlocked");
        }
        break;
      }

      case "displayPowerChanged": {
        const prev = this.context.isDisplayAsleep;
        this.context = { ...this.context, isDisplayAsleep: event.isAsleep };
        if (event.isAsleep === prev) break;
        if (event.isAsleep) {
          this.arbitrator.ingest("displayDidSleep", this.context.lidClosed, nowMs);
          pushRulesFor("away");
          pushRulesFor("displaySleep");
        } else {
          pushRulesFor("back");
          pushRulesFor("displayWake");
        }
        break;
      }

      case "systemSleep": {
        const lidClosed = event.lidClosed ?? this.context.lidClosed;
        this.context = { ...this.context, isSystemAsleep: true, lidClosed };
        pushRulesFor("away");
        const outcome = this.arbitrator.ingest("willSleep", lidClosed, nowMs);
        if (outcome) pushRulesFor(awayOutcomeTrigger(outcome));
        break;
      }

      case "systemWake": {
        this.context = { ...this.context, isSystemAsleep: false, isDisplayAsleep: false };
        if (!this.context.isLocked) pushRulesFor("back");
        pushRulesFor("systemWake");
        break;
      }

      case "panelWake": {
        if (!this.context.isLocked) this.evaluateLateNightRules(rules, nowMs, matchedRules);
        break;
      }

      case "powerChanged": {
        const prevExternal = this.context.onExternalPower;
        const prevSaver = this.context.powerSaverEnabled;
        const nextExternal = event.onExternalPower !== undefined ? event.onExternalPower : prevExternal;
        const nextBattery = event.batteryPercent !== undefined ? event.batteryPercent : this.context.batteryPercent;
        const nextSaver = event.powerSaverEnabled !== undefined ? event.powerSaverEnabled : prevSaver;
        this.context = { ...this.context, onExternalPower: nextExternal, batteryPercent: nextBattery, powerSaverEnabled: nextSaver };

        if (prevExternal !== null && nextExternal !== null && prevExternal !== nextExternal) {
          pushRulesFor(nextExternal ? "powerConnected" : "powerDisconnected");
        } else if (prevExternal === null && event.onExternalPower !== undefined) {
          pushRulesFor(event.onExternalPower ? "powerConnected" : "powerDisconnected");
        }

        if (event.powerSaverEnabled !== undefined && event.powerSaverEnabled !== prevSaver) {
          for (const rule of rules) {
            if (rule.trigger !== "powerSaverChanged") continue;
            if (rule.triggerOptions.powerSaverEnabled !== undefined && rule.triggerOptions.powerSaverEnabled !== nextSaver) continue;
            if (!wifiOk(rule)) continue;
            if (this.deduper.shouldFire(`powerSaver:${rule.id}:${nextSaver ? 1 : 0}`, nowMs)) matchedRules.push(rule);
          }
        }

        if (nextBattery !== null && nextExternal !== true) {
          for (const rule of rules) {
            if (rule.trigger !== "batteryBelowThreshold") continue;
            const below = nextBattery < rule.triggerOptions.batteryThresholdPercent;
            const prevBelow = this.batteryEdgeByRule.get(rule.id) ?? false;
            this.batteryEdgeByRule.set(rule.id, below);
            if (!below || prevBelow || !wifiOk(rule)) continue;
            if (this.deduper.shouldFire(`battery:${rule.id}:${rule.triggerOptions.batteryThresholdPercent}`, nowMs)) {
              matchedRules.push(rule);
            }
          }
        } else if (nextBattery !== null) {
          for (const rule of rules) {
            if (rule.trigger === "batteryBelowThreshold") {
              this.batteryEdgeByRule.set(rule.id, nextBattery < rule.triggerOptions.batteryThresholdPercent);
            }
          }
        }
        break;
      }

      case "wifiChanged": {
        const prevSSID = this.context.wifiSSID?.trim() || null;
        const nextSSID = event.ssid?.trim() || null;
        const nextAuth = event.isAuthorized ?? this.context.wifiAuthorized;
        this.context = { ...this.context, wifiSSID: nextSSID, wifiAuthorized: nextAuth };

        if (prevSSID === nextSSID) break;
        if (prevSSID !== null && nextSSID !== prevSSID) {
          for (const rule of rules) {
            if (rule.trigger !== "wifiNetworkLeft") continue;
            if (rule.triggerOptions.wifiSSID && rule.triggerOptions.wifiSSID !== prevSSID) continue;
            if (!wifiOk(rule, nextSSID, nextAuth)) continue;
            if (this.deduper.shouldFire(`wifiLeft:${rule.id}:${prevSSID}`, nowMs)) matchedRules.push(rule);
          }
        }
        if (nextSSID !== null && nextSSID !== prevSSID) {
          for (const rule of rules) {
            if (rule.trigger !== "wifiNetworkJoined") continue;
            if (rule.triggerOptions.wifiSSID && rule.triggerOptions.wifiSSID !== nextSSID) continue;
            if (!wifiOk(rule, nextSSID, nextAuth)) continue;
            if (this.deduper.shouldFire(`wifiJoined:${rule.id}:${nextSSID}`, nowMs)) matchedRules.push(rule);
          }
        }
        break;
      }

      case "mediaCaptureChanged": {
        const prevCam = this.context.cameraInUse;
        const prevMic = this.context.microphoneInUse;
        const nextCam = event.cameraInUse ?? prevCam;
        const nextMic = event.microphoneInUse ?? prevMic;
        this.context = { ...this.context, cameraInUse: nextCam, microphoneInUse: nextMic };
        if (nextCam !== prevCam) pushRulesFor(nextCam ? "cameraInUse" : "cameraNotInUse");
        if (nextMic !== prevMic) pushRulesFor(nextMic ? "microphoneInUse" : "microphoneNotInUse");
        break;
      }

      case "externalDisplayChanged": {
        const prevCount = this.context.externalDisplayCount;
        const nextCount = Math.max(0, Math.trunc(event.externalDisplayCount));
        this.context = { ...this.context, externalDisplayCount: nextCount };
        if (nextCount > prevCount) pushRulesFor("externalDisplayConnected");
        else if (nextCount < prevCount) pushRulesFor("externalDisplayDisconnected");
        break;
      }

      case "focusModeChanged": {
        const prev = this.context.focusModeEnabled;
        this.context = { ...this.context, focusModeEnabled: event.enabled };
        if (event.enabled !== prev) pushRulesFor(event.enabled ? "focusModeEnabled" : "focusModeDisabled");
        break;
      }

      case "calendarMeetingSoon": {
        for (const rule of rules) {
          if (rule.trigger !== "calendarMeetingStartingSoon") continue;
          if (event.startsInMinutes > rule.triggerOptions.calendarLeadMinutes || !wifiOk(rule)) continue;
          if (this.deduper.shouldFire(`calendar:${rule.id}:${event.eventId}`, nowMs, AUTOMATION_POLICY.nightlyCooldownMs)) {
            matchedRules.push(rule);
          }
        }
        break;
      }

      case "tick":
        break;
    }

    const flushed = this.arbitrator.flush(nowMs);
    if (flushed) pushRulesFor(awayOutcomeTrigger(flushed));

    if (!this.context.isLocked && !this.context.isSystemAsleep && !this.context.isDisplayAsleep) {
      this.evaluateLateNightRules(rules, nowMs, matchedRules);
    }
    this.evaluateScheduledTimeRules(rules, nowMs, matchedRules);
    this.evaluateSensorThresholdRules(host, rules, nowMs, matchedRules, options.observationsByDeviceId);

    const uniqueRules: AutomationRule[] = [];
    const seenRuleIds = new Set<string>();
    for (const r of matchedRules) {
      if (seenRuleIds.has(r.id)) continue;
      seenRuleIds.add(r.id);
      uniqueRules.push(r);
    }

    const runs: RecordedAutomationRun[] = [];
    for (const rule of uniqueRules) {
      const run = await executeAutomationRule(host, rule, { ...options, nowMs });
      if (run) runs.push(run);
    }
    return runs;
  }

  private evaluateLateNightRules(rules: readonly AutomationRule[], nowMs: number, out: AutomationRule[]): void {
    for (const rule of rules) {
      if (rule.trigger !== "lateNightUsage") continue;
      const anchorKey = lateNightAnchorKey(rule.triggerOptions.lateNightWindow, nowMs);
      if (!anchorKey) continue;
      if (!evaluateWiFiCondition(rule.conditions.wifi, this.context.wifiSSID, this.context.wifiAuthorized).isSatisfied) continue;
      if (this.deduper.shouldFire(`lateNight:${rule.id}:${anchorKey}`, nowMs, AUTOMATION_POLICY.nightlyCooldownMs)) {
        out.push(rule);
      }
    }
  }

  private evaluateScheduledTimeRules(rules: readonly AutomationRule[], nowMs: number, out: AutomationRule[]): void {
    const d = new Date(nowMs);
    const hour = d.getHours();
    const minute = d.getMinutes();
    const weekday = d.getDay();
    const pad = (n: number): string => String(n).padStart(2, "0");
    const dateKey = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

    for (const rule of rules) {
      if (rule.trigger !== "scheduledTime") continue;
      const sched = rule.triggerOptions.scheduledTime;
      if (!sched || sched.hour !== hour || sched.minute !== minute) continue;
      if (sched.weekdays && sched.weekdays.length > 0 && !sched.weekdays.includes(weekday)) continue;
      if (!evaluateWiFiCondition(rule.conditions.wifi, this.context.wifiSSID, this.context.wifiAuthorized).isSatisfied) continue;
      if (this.deduper.shouldFire(`sched:${rule.id}:${dateKey}:${pad(sched.hour)}:${pad(sched.minute)}`, nowMs, AUTOMATION_POLICY.nightlyCooldownMs)) {
        out.push(rule);
      }
    }
  }

  private evaluateSensorThresholdRules(
    host: AutomationExecutionHost,
    rules: readonly AutomationRule[],
    nowMs: number,
    out: AutomationRule[],
    observationsByDeviceId?: Readonly<Record<string, readonly SensorObservation[]>>,
  ): void {
    for (const rule of rules) {
      if (rule.trigger !== "sensorThreshold") continue;
      const cond = rule.triggerOptions.sensorCondition;
      if (!cond) continue;
      const dev = host.devices.find((d) => d.id === cond.deviceId);
      if (!dev || !dev.isOnline) continue;

      let active = false;
      if (cond.metric === "alarm") {
        const observations = extractSensorObservations(dev, host.deviceFacets?.[dev.id] ?? [], observationsByDeviceId?.[dev.id]);
        active = observations.some((obs) => obs.alarming && (!cond.alertKind || obs.kind === cond.alertKind));
      } else {
        const val = readSensorMetricValue(dev, cond.metric);
        if (val === null || cond.threshold === undefined) continue;
        active = compareMetric(val, cond.comparison ?? "gte", cond.threshold);
      }

      const edgeKey = `${rule.id}:${cond.deviceId}:${cond.metric}`;
      const previous = this.sensorConditionEdge.get(edgeKey) ?? false;
      this.sensorConditionEdge.set(edgeKey, active);
      if (!active || previous) continue;

      if (!evaluateWiFiCondition(rule.conditions.wifi, this.context.wifiSSID, this.context.wifiAuthorized).isSatisfied) continue;
      if (this.deduper.shouldFire(`sensor:${edgeKey}`, nowMs)) out.push(rule);
    }
  }
}

export interface DoorbellRing {
  readonly deviceId: string;
  readonly entityId: string;
  readonly firedAt: string;
  readonly key: string;
}

export function createDoorbellRing(deviceId: string, entityId: string, firedAt: string): DoorbellRing {
  return { deviceId, entityId, firedAt, key: `${entityId}@${firedAt}` };
}

export interface DoorbellResponse {
  readonly cameraDeviceId: string | null;
  readonly playsChime: boolean;
  readonly dismissAfterSeconds: number;
}

export interface HASnapshotLike {
  readonly areas?: readonly Record<string, unknown>[];
  readonly devices?: readonly Record<string, unknown>[];
  readonly entities?: readonly Record<string, unknown>[];
  readonly states: readonly Record<string, unknown>[];
}

export function isDoorbellEventState(entityId: string, attributes: Readonly<Record<string, unknown>>): boolean {
  return entityId.startsWith("event.") && attributes.device_class === "doorbell";
}

export function doorbellPressTimestamp(
  entityId: string,
  stateValue: string,
  attributes: Readonly<Record<string, unknown>>,
): string | null {
  if (!isDoorbellEventState(entityId, attributes)) return null;
  const trimmed = stateValue.trim();
  return trimmed === "" || trimmed === "unknown" || trimmed === "unavailable" ? null : trimmed;
}

export class DoorbellDetector {
  private lastTimestamps = new Map<string, string>();
  private hasPrimedBaseline = false;

  public get isPrimed(): boolean {
    return this.hasPrimedBaseline;
  }

  public reset(): void {
    this.lastTimestamps.clear();
    this.hasPrimedBaseline = false;
  }

  public ingestHASnapshot(snapshot: HASnapshotLike, devices: readonly SmartDevice[] = []): DoorbellRing[] {
    const disabledDeviceIds = new Set<string>();
    const haDeviceArea = new Map<string, string>();
    for (const devRow of snapshot.devices ?? []) {
      const id = typeof devRow.id === "string" ? devRow.id : null;
      if (!id) continue;
      if (devRow.disabled_by !== undefined && devRow.disabled_by !== null) disabledDeviceIds.add(id);
      if (typeof devRow.area_id === "string" && devRow.area_id) haDeviceArea.set(id, devRow.area_id);
    }

    const entityDeviceMap = new Map<string, string>();
    const entityAreaMap = new Map<string, string>();
    const suppressedEntities = new Set<string>();
    const cameraCardByHaDevice = new Map<string, string>();

    for (const entRow of snapshot.entities ?? []) {
      const entityId = typeof entRow.entity_id === "string" ? entRow.entity_id : null;
      if (!entityId) continue;
      const disabled = entRow.disabled_by !== undefined && entRow.disabled_by !== null;
      const hidden = entRow.hidden_by !== undefined && entRow.hidden_by !== null;
      const devId = typeof entRow.device_id === "string" ? entRow.device_id : null;
      if (disabled || hidden || (devId !== null && disabledDeviceIds.has(devId))) {
        suppressedEntities.add(entityId);
        continue;
      }
      if (devId) {
        entityDeviceMap.set(entityId, devId);
        if (entityId.startsWith("camera.")) {
          const matchingCard = devices.find(
            (d) =>
              d.kind.kind === "camera" &&
              (d.kind.entityId === entityId || d.kind.streamEntityId === entityId || d.id === `ha:${devId}` || d.id === devId),
          );
          if (matchingCard) cameraCardByHaDevice.set(devId, matchingCard.id);
        }
      }
      const areaId =
        typeof entRow.area_id === "string" && entRow.area_id ? entRow.area_id : devId ? (haDeviceArea.get(devId) ?? null) : null;
      if (areaId) entityAreaMap.set(entityId, areaId);
    }

    const rings: DoorbellRing[] = [];
    for (const rawState of snapshot.states ?? []) {
      const entityId =
        typeof rawState.entity_id === "string" ? rawState.entity_id : typeof rawState.entityId === "string" ? rawState.entityId : null;
      const stateValue = typeof rawState.state === "string" ? rawState.state : null;
      if (!entityId || stateValue === null || suppressedEntities.has(entityId)) continue;

      const attrs =
        rawState.attributes && typeof rawState.attributes === "object" && !Array.isArray(rawState.attributes)
          ? (rawState.attributes as Record<string, unknown>)
          : {};
      const timestamp = doorbellPressTimestamp(entityId, stateValue, attrs);
      if (timestamp === null) continue;

      const previous = this.lastTimestamps.get(entityId);
      this.lastTimestamps.set(entityId, timestamp);
      if (!this.hasPrimedBaseline || previous === timestamp) continue;

      const haDevId = entityDeviceMap.get(entityId) ?? null;
      const areaId = entityAreaMap.get(entityId) ?? null;
      const resolvedDeviceId = this.resolveTargetCameraDeviceId(entityId, haDevId, areaId, cameraCardByHaDevice, devices);
      rings.push(createDoorbellRing(resolvedDeviceId, entityId, timestamp));
    }

    this.hasPrimedBaseline = true;
    return rings;
  }

  private resolveTargetCameraDeviceId(
    entityId: string,
    haDeviceId: string | null,
    areaId: string | null,
    cameraCardByHaDevice: ReadonlyMap<string, string>,
    devices: readonly SmartDevice[],
  ): string {
    if (haDeviceId) {
      const mapped = cameraCardByHaDevice.get(haDeviceId);
      if (mapped) return mapped;
      const direct = devices.find((d) => d.id === `ha:${haDeviceId}` || d.id === haDeviceId);
      if (direct) return direct.id;
    }
    if (areaId) {
      const sameRoomCam = devices.find(
        (d) => d.kind.kind === "camera" && (d.roomId === areaId || d.roomId === `ha_area:${areaId}`),
      );
      if (sameRoomCam) return sameRoomCam.id;
    }
    const slug = entityId.replace(/^event\./, "").replace(/_doorbell.*$/, "");
    const bySlug = devices.find((d) => d.kind.kind === "camera" && (d.kind.entityId.includes(slug) || d.id.includes(slug)));
    if (bySlug) return bySlug.id;
    const onlyCam = devices.filter((d) => d.kind.kind === "camera");
    if (onlyCam.length === 1) return onlyCam[0]!.id;
    return haDeviceId ? `ha:${haDeviceId}` : entityId;
  }
}

export interface DoorbellCameraViewLike {
  activeLiveCameraId: string | null;
  liveCameraHidden: boolean;
  openCameraLiveView(id: string): void;
  hideCameraLiveView(): void;
}

export interface RecordedDoorbellRing {
  readonly ring: DoorbellRing;
  readonly scope: string;
  readonly dateMs: number;
}

export interface DoorbellCoordinatorScheduler {
  setTimeout(handler: () => void, delayMs: number): ReturnType<typeof setTimeout>;
  clearTimeout(handle: ReturnType<typeof setTimeout>): void;
}

const defaultDoorbellScheduler: DoorbellCoordinatorScheduler = {
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (h) => globalThis.clearTimeout(h),
};

export function clampDoorbellPopupSeconds(seconds: number): number {
  if (!Number.isFinite(seconds)) return 60;
  return Math.min(300, Math.max(15, Math.round(seconds)));
}

export class DoorbellCameraCoordinator {
  public static readonly maxRecentRings = 20;

  private handledRingKeys = new Set<string>();
  private recentRingsList: RecordedDoorbellRing[] = [];
  private autoCloseTimer: ReturnType<typeof setTimeout> | null = null;
  private doorbellOwnedCameraId: string | null = null;
  private doorbellOwnsClose = false;

  constructor(private readonly scheduler: DoorbellCoordinatorScheduler = defaultDoorbellScheduler) {}

  public get recentRings(): readonly RecordedDoorbellRing[] {
    return this.recentRingsList;
  }

  public get isAutoDismissArmed(): boolean {
    return this.doorbellOwnsClose && this.autoCloseTimer !== null;
  }

  public get ownedCameraId(): string | null {
    return this.doorbellOwnsClose ? this.doorbellOwnedCameraId : null;
  }

  public claimDoorbellWindowForUser(): void {
    this.clearAutoCloseTimer();
    this.doorbellOwnsClose = false;
    this.doorbellOwnedCameraId = null;
  }

  public clearAll(): void {
    this.claimDoorbellWindowForUser();
    this.handledRingKeys.clear();
    this.recentRingsList = [];
  }

  public pruneMissingDevices(presentDeviceIds: ReadonlySet<string>): boolean {
    const before = this.recentRingsList.length;
    this.recentRingsList = this.recentRingsList.filter((entry) => presentDeviceIds.has(entry.ring.deviceId));
    if (this.doorbellOwnedCameraId && !presentDeviceIds.has(this.doorbellOwnedCameraId)) {
      this.claimDoorbellWindowForUser();
    }
    return this.recentRingsList.length !== before;
  }

  public dismissRingKey(key: string): void {
    this.recentRingsList = this.recentRingsList.filter((r) => r.ring.key !== key);
  }

  public handleRings(args: {
    readonly rings: readonly DoorbellRing[];
    readonly devices: readonly SmartDevice[];
    readonly cameraLive: DoorbellCameraViewLike;
    readonly isLocked: boolean;
    readonly scope: string;
    readonly nowMs?: number;
    readonly autoPopup?: boolean;
    readonly playChime?: boolean;
    readonly popupSeconds?: number;
  }): DoorbellResponse[] {
    const nowMs = args.nowMs ?? Date.now();
    const autoPopup = args.autoPopup ?? true;
    const playChime = args.playChime ?? false;
    const dismissSeconds = clampDoorbellPopupSeconds(args.popupSeconds ?? 60);
    const responses: DoorbellResponse[] = [];

    for (const ring of args.rings) {
      if (this.handledRingKeys.has(ring.key)) continue;
      this.handledRingKeys.add(ring.key);
      this.recentRingsList = [
        { ring, scope: args.scope, dateMs: nowMs },
        ...this.recentRingsList.filter((r) => r.ring.key !== ring.key),
      ].slice(0, DoorbellCameraCoordinator.maxRecentRings);

      const camDevice = args.devices.find((d) => d.id === ring.deviceId && d.kind.kind === "camera");
      const canAutoOpen = Boolean(camDevice) && autoPopup && !args.isLocked;
      let openedCameraId: string | null = null;

      if (canAutoOpen && camDevice) {
        const isModalVisible = args.cameraLive.activeLiveCameraId !== null && !args.cameraLive.liveCameraHidden;
        if (!isModalVisible) {
          openedCameraId = camDevice.id;
          args.cameraLive.openCameraLiveView(camDevice.id);
          this.armAutoClose(args.cameraLive, camDevice.id, dismissSeconds * 1000);
        } else if (
          args.cameraLive.activeLiveCameraId === camDevice.id &&
          this.doorbellOwnsClose &&
          this.doorbellOwnedCameraId === camDevice.id
        ) {
          openedCameraId = camDevice.id;
          this.armAutoClose(args.cameraLive, camDevice.id, dismissSeconds * 1000);
        }
      }

      responses.push({
        cameraDeviceId: openedCameraId,
        playsChime: playChime && !args.isLocked,
        dismissAfterSeconds: dismissSeconds,
      });
    }
    return responses;
  }

  private armAutoClose(cameraLive: DoorbellCameraViewLike, cameraId: string, delayMs: number): void {
    this.clearAutoCloseTimer();
    this.doorbellOwnsClose = true;
    this.doorbellOwnedCameraId = cameraId;
    this.autoCloseTimer = this.scheduler.setTimeout(() => {
      this.autoCloseTimer = null;
      const shouldHide =
        this.doorbellOwnsClose &&
        this.doorbellOwnedCameraId === cameraId &&
        cameraLive.activeLiveCameraId === cameraId &&
        !cameraLive.liveCameraHidden;
      this.doorbellOwnsClose = false;
      this.doorbellOwnedCameraId = null;
      if (shouldHide) cameraLive.hideCameraLiveView();
    }, delayMs);
    if (typeof this.autoCloseTimer === "object" && this.autoCloseTimer !== null && "unref" in this.autoCloseTimer) {
      (this.autoCloseTimer as { unref(): void }).unref();
    }
  }

  private clearAutoCloseTimer(): void {
    if (this.autoCloseTimer !== null) {
      this.scheduler.clearTimeout(this.autoCloseTimer);
      this.autoCloseTimer = null;
    }
  }
}
