import {
  AUTOMATION_TRIGGERS,
  AutomationRuleStore,
  AutomationTriggerDeduper,
  automationRequiredPermission,
  automationTriggerTitle,
  clampDoorbellPopupSeconds,
  createAutomationConditions,
  createAutomationRule,
  executeAutomationRule,
  isAutomationTrigger,
  normalizeWiFiSSIDs,
  summarizeAutomationAction,
  type AutomationAction,
  type AutomationRule,
  type AutomationTrigger,
  type AutomationWiFiCondition,
  type RecordedAutomationRun,
  type SensorThresholdComparison,
  type SensorThresholdCondition,
  type SensorThresholdMetric,
} from "../core/automationEngine.js";
import type { QuickActionId } from "../core/quickActions.js";
import { demoScenes } from "./demo.js";
import { getScopedEnergyHistory, type EnergyScopeSource } from "../core/energyHistory.js";
import { currentLanguage, resolveLanguage, type AppLanguage, type LanguagePreference } from "../core/i18n.js";
import type { DeviceCommand, FacetControl, HomeScene, SmartDevice } from "../core/models.js";
import {
  SENSOR_ALERT_KINDS,
  WEEKLY_HEALTH_CONSTANTS,
  buildWeeklyHealthReport,
  defaultSafetyStorage,
  loadSensorAlertPolicy,
  renderWeeklyHealthMarkdown,
  saveSensorAlertPolicy,
  sensorAlertIsHazard,
  sensorAlertSettingsTitle,
  type HealthClimateRange,
  type KeyValueStorageLike,
  type SafetyAlert,
  type SensorAlertKind,
  type WeeklyHealthReport,
} from "../core/safetyAndHealth.js";
import { sharedSensorHistoryStore } from "../core/sensorHistory.js";
import {
  MAX_RECENT_AUTOMATION_RUNS,
  computeActivityScopeKey,
  executeAutomationCardUndo,
  getHostActivityCenter,
  isFullPanelHost,
  type HostActivityCenter,
} from "./activityStackView.js";
import {
  recordUndoKindSnapshots,
  rejectIfControlBlockedWhileLocked,
} from "./speechGuard.js";
import type { PersistedSettings, ReplyBannerState } from "./appTypes.js";
import { withAliases, type LayoutPrefs } from "./panelPrefs.js";
import type { SettingsViewContext } from "./settingsViews.js";

export const SAFETY_GUARD_PREFS_KEY = "menumijia.windows.safetyGuardPrefs.v1";

export const DOORBELL_POPUP_SECOND_OPTIONS = [30, 60, 120, 300] as const;

export interface SafetyGuardPreferences {
  readonly enableSafetyAlerts: boolean;
  readonly longRunningPlug: boolean;
  readonly longRunningClimate: boolean;
  readonly favoriteOffline: boolean;
  readonly lowBattery: boolean;
  readonly doorbellAutoPopup: boolean;
  readonly doorbellPopupSeconds: number;
  readonly doorbellChime: boolean;
  readonly enableWeeklyHealthReport: boolean;
}

export const DEFAULT_SAFETY_GUARD_PREFS: SafetyGuardPreferences = {
  enableSafetyAlerts: true,
  longRunningPlug: true,
  longRunningClimate: true,
  favoriteOffline: true,
  lowBattery: true,
  doorbellAutoPopup: true,
  doorbellPopupSeconds: 60,
  doorbellChime: false,
  enableWeeklyHealthReport: true,
};

export interface NewRuleDraftState {
  formOpen: boolean;
  trigger: AutomationTrigger;
  lateNightStartHour: number;
  lateNightEndHour: number;
  scheduleHour: number;
  scheduleMinute: number;
  scheduleWeekdays: Set<number>;
  sensorDeviceId: string;
  sensorMetric: SensorThresholdMetric;
  sensorComparison: SensorThresholdComparison;
  sensorThreshold: number;
  sensorAlertKind: SensorAlertKind;
  batteryThreshold: number;
  triggerWifiSSID: string;
  calendarLeadMinutes: number;
  wifiKind: "any" | "inAny" | "notIn";
  wifiSSIDsText: string;
  actionKind: "quickAction" | "devices" | "scene";
  quickAction: QuickActionId;
  devicesPowerOn: boolean;
  selectedDeviceIds: Set<string>;
  selectedSceneId: string;
}

export interface HostAutoSafetySession {
  readonly draft: NewRuleDraftState;
  healthReportPreviewMarkdown: string | null;
  lastScopeKey: string | null;
  lastSourceRevision: number | null;
}

export interface AutoSafetySettingsHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  devices: SmartDevice[];
  scenes: HomeScene[];
  readonly layout: LayoutPrefs;
  activeSheet: "none" | "onboarding" | "settings";
  replyBanner: ReplyBannerState | null;
  readonly sourceRevision?: number;
  readonly deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly miAccountsOverride?: readonly import("../core/miAccountsStore.js").MiAccount[] | null;
  readonly multiAccountState?: import("./cloudRefresh.js").HostMultiAccountState | null;
  readonly dualSourceEnabledOverride?: boolean | null;
  autoSafetySession?: HostAutoSafetySession;
  activityCenter?: HostActivityCenter | null;
  applyCommand?(cmd: DeviceCommand, silent?: boolean): Promise<boolean>;
  activateScene?(entityId: string): Promise<boolean>;
  render(): void;
}

function effectiveLanguage(pref?: LanguagePreference): AppLanguage {
  if (pref && pref !== "system") {
    return resolveLanguage(pref, []);
  }
  const navLangs =
    typeof window !== "undefined" && Array.isArray(window.navigator?.languages)
      ? window.navigator.languages
      : [];
  return resolveLanguage(pref ?? currentLanguage(), navLangs);
}

function uiText(
  lang: AppLanguage,
  zhHans: string,
  zhHant: string,
  en: string,
  vars?: Record<string, string | number>,
): string {
  let out = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      out = out.replaceAll(`{${k}}`, String(v));
    }
  }
  return out;
}

function createDefaultDraft(): NewRuleDraftState {
  return {
    formOpen: true,
    trigger: "away",
    lateNightStartHour: 23,
    lateNightEndHour: 5,
    scheduleHour: 8,
    scheduleMinute: 0,
    scheduleWeekdays: new Set<number>(),
    sensorDeviceId: "",
    sensorMetric: "temperature",
    sensorComparison: "gt",
    sensorThreshold: 28,
    sensorAlertKind: "smoke",
    batteryThreshold: 20,
    triggerWifiSSID: "",
    calendarLeadMinutes: 5,
    wifiKind: "any",
    wifiSSIDsText: "",
    actionKind: "quickAction",
    quickAction: "lightsOff",
    devicesPowerOn: false,
    selectedDeviceIds: new Set<string>(),
    selectedSceneId: "",
  };
}

export function createDefaultHostAutoSafetySession(): HostAutoSafetySession {
  return {
    draft: createDefaultDraft(),
    healthReportPreviewMarkdown: null,
    lastScopeKey: null,
    lastSourceRevision: null,
  };
}

export function syncAutoSafetySessionScope(
  session: HostAutoSafetySession,
  scopeKey: string,
  sourceRevision: number | undefined,
): void {
  const rev = sourceRevision ?? 0;
  if (
    session.lastScopeKey !== null &&
    (session.lastScopeKey !== scopeKey ||
      (session.lastSourceRevision !== null && session.lastSourceRevision !== rev))
  ) {
    session.healthReportPreviewMarkdown = null;
    session.draft.selectedDeviceIds.clear();
  }
  session.lastScopeKey = scopeKey;
  session.lastSourceRevision = rev;
}

export function getHostAutoSafetySession(host: AutoSafetySettingsHost): HostAutoSafetySession {
  if (!host.autoSafetySession) {
    host.autoSafetySession = createDefaultHostAutoSafetySession();
  }
  syncAutoSafetySessionScope(
    host.autoSafetySession,
    computeActivityScopeKey(host),
    host.sourceRevision,
  );
  return host.autoSafetySession;
}

function resolveHostActivityCenter(host: AutoSafetySettingsHost): HostActivityCenter | null {
  if (isFullPanelHost(host)) {
    return getHostActivityCenter(host);
  }
  return host.activityCenter ?? null;
}

export function loadSafetyGuardPrefs(
  storage: KeyValueStorageLike = defaultSafetyStorage(),
): SafetyGuardPreferences {
  try {
    const raw = storage.getItem(SAFETY_GUARD_PREFS_KEY);
    if (!raw) return { ...DEFAULT_SAFETY_GUARD_PREFS };
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ...DEFAULT_SAFETY_GUARD_PREFS };
    }
    const b = (key: keyof SafetyGuardPreferences): boolean =>
      typeof parsed[key] === "boolean" ? (parsed[key] as boolean) : (DEFAULT_SAFETY_GUARD_PREFS[key] as boolean);
    return {
      enableSafetyAlerts: b("enableSafetyAlerts"),
      longRunningPlug: b("longRunningPlug"),
      longRunningClimate: b("longRunningClimate"),
      favoriteOffline: b("favoriteOffline"),
      lowBattery: b("lowBattery"),
      doorbellAutoPopup: b("doorbellAutoPopup"),
      doorbellPopupSeconds:
        typeof parsed.doorbellPopupSeconds === "number" && Number.isFinite(parsed.doorbellPopupSeconds)
          ? clampDoorbellPopupSeconds(parsed.doorbellPopupSeconds)
          : DEFAULT_SAFETY_GUARD_PREFS.doorbellPopupSeconds,
      doorbellChime: b("doorbellChime"),
      enableWeeklyHealthReport: b("enableWeeklyHealthReport"),
    };
  } catch {
    return { ...DEFAULT_SAFETY_GUARD_PREFS };
  }
}

export function saveSafetyGuardPrefs(
  patch: Partial<SafetyGuardPreferences>,
  storage: KeyValueStorageLike = defaultSafetyStorage(),
): SafetyGuardPreferences {
  const current = loadSafetyGuardPrefs(storage);
  const next: SafetyGuardPreferences = {
    ...current,
    ...patch,
    doorbellPopupSeconds:
      patch.doorbellPopupSeconds !== undefined
        ? clampDoorbellPopupSeconds(patch.doorbellPopupSeconds)
        : current.doorbellPopupSeconds,
  };
  try {
    storage.setItem(SAFETY_GUARD_PREFS_KEY, JSON.stringify(next));
  } catch {
  }
  return next;
}

export function filterSafetyAlertsByGuardPrefs(
  alerts: readonly SafetyAlert[],
  devices: readonly SmartDevice[],
  prefs: SafetyGuardPreferences,
): SafetyAlert[] {
  return alerts.filter((alert) => {
    if (alert.category === "sensor") return true;
    if (!prefs.enableSafetyAlerts) return false;
    if (alert.category === "offline") return prefs.favoriteOffline;
    if (alert.category === "lowBattery") return prefs.lowBattery;
    if (alert.category === "longRun") {
      const dev = devices.find((d) => d.id === alert.deviceId);
      return dev?.kind.kind === "plug" ? prefs.longRunningPlug : prefs.longRunningClimate;
    }
    return true;
  });
}

function pruneDisabledSafetyAlertsFromCenter(
  center: HostActivityCenter,
  devices: readonly SmartDevice[],
  prefs: SafetyGuardPreferences,
): void {
  center.recentSafetyAlerts = center.recentSafetyAlerts.filter((rec) => {
    const a = rec.alert;
    if (a.category === "sensor") return true;
    if (!prefs.enableSafetyAlerts) return false;
    if (a.category === "offline") return prefs.favoriteOffline;
    if (a.category === "lowBattery") return prefs.lowBattery;
    if (a.category === "longRun") {
      const dev = devices.find((d) => d.id === a.deviceId);
      return dev?.kind.kind === "plug" ? prefs.longRunningPlug : prefs.longRunningClimate;
    }
    return true;
  });
}

function aliasedDevicesFor(devices: readonly SmartDevice[], layout: LayoutPrefs | undefined): SmartDevice[] {
  if (!layout || devices.length === 0) return [...devices];
  const aliased = withAliases(layout, devices);
  const roomAliases = layout.roomAliases;
  return aliased.map((dev, idx) => {
    const orig = devices[idx]!;
    const trimmedName = dev.name.trim() || orig.name;
    const roomAlias = dev.roomId && roomAliases ? roomAliases[dev.roomId]?.trim() : "";
    const effectiveRoom = roomAlias || dev.roomName;
    return trimmedName === dev.name && effectiveRoom === dev.roomName
      ? dev
      : { ...dev, name: trimmedName, roomName: effectiveRoom };
  });
}

function resolveScenesForContext(ctx: SettingsViewContext): readonly HomeScene[] {
  if (ctx.scenes) return ctx.scenes;
  if (ctx.settings.connectionMode === "homeAssistant") return ctx.settings.cachedHAHome?.home.scenes ?? [];
  if (ctx.settings.connectionMode === "demo") return demoScenes();
  return [];
}

function isDeviceControllableForRule(device: SmartDevice): boolean {
  const k = device.kind;
  switch (k.kind) {
    case "light":
    case "climate":
    case "fan":
    case "plug":
    case "camera":
      return k.powerWritable !== false;
    case "appliance":
      return Boolean(k.powerPresent && k.powerWritable);
    case "vacuum":
      return k.actionsWritable !== false;
    case "cover":
      return Boolean(k.openDescription || k.closeDescription);
    case "generic":
      return Boolean(k.powerControl?.target);
    case "fridge":
    case "sensor":
    case "speaker":
      return false;
  }
}

export function generateLiveWeeklyHealthReport(
  source: {
    readonly settings: PersistedSettings & EnergyScopeSource;
    readonly devices: readonly SmartDevice[];
    readonly layout?: LayoutPrefs;
  },
  storage: KeyValueStorageLike = defaultSafetyStorage(),
  offlineHistory?: import("../core/safetyAndHealth.js").OfflineHistory,
  nowMs = Date.now(),
): WeeklyHealthReport {
  const aliased = aliasedDevicesFor(source.devices, source.layout ?? source.settings.layout);
  const nowDate = new Date(nowMs);
  const energyHistory = getScopedEnergyHistory(source.settings);
  const dailyEnergy = energyHistory.dailyTotals(14, nowDate).map((d) => ({ kwh: d.kwh, isObserved: d.isObserved }));
  const energyByDevice = energyHistory
    .topDevices(7, WEEKLY_HEALTH_CONSTANTS.topConsumerCount, aliased, nowDate)
    .map((item) => ({ id: item.deviceId, name: item.name, kwh: item.kwh }));

  const sensorStore = sharedSensorHistoryStore();
  const climate: Record<string, HealthClimateRange> = {};
  for (const dev of aliased) {
    const tempSum = sensorStore.summary(dev.id, "7d", "temperature", nowMs);
    const humSum = sensorStore.summary(dev.id, "7d", "humidity", nowMs);
    if (tempSum || humSum) {
      climate[dev.id] = {
        temperature: tempSum ? { min: tempSum.min, max: tempSum.max } : null,
        humidity: humSum ? { min: humSum.min, max: humSum.max } : null,
      };
    }
  }

  return buildWeeklyHealthReport({
    devices: aliased,
    dailyEnergy,
    energyByDevice,
    climate,
    ...(offlineHistory ? { offlineHistory } : {}),
    nowMs,
  });
}

export async function generateAndCopyWeeklyHealthMarkdown(
  host: AutoSafetySettingsHost,
  nowMs = Date.now(),
): Promise<string> {
  const session = getHostAutoSafetySession(host);
  const center = resolveHostActivityCenter(host);
  const storage = center?.storage ?? defaultSafetyStorage();
  const lang = effectiveLanguage(host.settings.interfaceLanguage);
  const report = generateLiveWeeklyHealthReport(host, storage, center?.offlineHistory, nowMs);
  const markdown = renderWeeklyHealthMarkdown(report, lang);

  session.healthReportPreviewMarkdown = markdown;
  if (center) center.lastClipboardMarkdown = markdown;
  try {
    if (typeof globalThis.navigator?.clipboard?.writeText === "function") {
      await globalThis.navigator.clipboard.writeText(markdown);
    }
  } catch {
  }

  host.replyBanner = {
    text: uiText(
      lang,
      "已生成并复制家庭健康周报 Markdown",
      "已產生並複製家庭健康週報 Markdown",
      "Generated and copied Weekly Home Health Report Markdown",
    ),
    source: uiText(lang, "健康周报", "健康週報", "Health Report"),
  };
  host.render();
  return markdown;
}

function triggerIconSvg(trigger: AutomationTrigger): string {
  if (
    trigger === "away" ||
    trigger === "screenLocked" ||
    trigger === "lidClosedSleep" ||
    trigger === "systemSleep" ||
    trigger === "displaySleep"
  ) {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`;
  }
  if (
    trigger === "back" ||
    trigger === "screenUnlocked" ||
    trigger === "systemWake" ||
    trigger === "displayWake"
  ) {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2"/></svg>`;
  }
  if (trigger === "lateNightUsage") {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.79A9 9 0 1 1 11.21 3a7 7 0 0 0 9.79 9.79z"/></svg>`;
  }
  if (trigger === "scheduledTime" || trigger === "calendarMeetingStartingSoon") {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>`;
  }
  if (trigger === "sensorThreshold") {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12h4l3-7 4 14 3-7h4"/></svg>`;
  }
  if (
    trigger === "cameraInUse" ||
    trigger === "cameraNotInUse" ||
    trigger === "microphoneInUse" ||
    trigger === "microphoneNotInUse"
  ) {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="6" width="14" height="12" rx="2"/><path d="m22 8-6 4 6 4V8z"/></svg>`;
  }
  if (trigger === "wifiNetworkJoined" || trigger === "wifiNetworkLeft") {
    return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><circle cx="12" cy="20" r="1"/></svg>`;
  }
  return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 2 3 14h8l-1 8 10-12h-8l1-8z"/></svg>`;
}

const pad2 = (n: number): string => String(Math.max(0, Math.trunc(n))).padStart(2, "0");
const comparisonSymbol = (c: SensorThresholdComparison): string =>
  c === "gt" ? ">" : c === "gte" ? "≥" : c === "lt" ? "<" : "≤";

function weekdayShortLabel(day: number, lang: AppLanguage): string {
  const idx = ((day % 7) + 7) % 7;
  const table =
    lang === "en"
      ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      : lang === "zh-Hant"
        ? ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]
        : ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  return table[idx]!;
}

function metricLabel(metric: SensorThresholdMetric, lang: AppLanguage): string {
  switch (metric) {
    case "temperature":
      return uiText(lang, "温度 (°C)", "溫度 (°C)", "Temperature (°C)");
    case "humidity":
      return uiText(lang, "湿度 (%)", "濕度 (%)", "Humidity (%)");
    case "battery":
      return uiText(lang, "电量 (%)", "電量 (%)", "Battery (%)");
    case "powerWatts":
      return uiText(lang, "功率 (W)", "功率 (W)", "Power (W)");
    case "pm25":
      return uiText(lang, "PM2.5", "PM2.5", "PM2.5");
    case "alarm":
      return uiText(lang, "安防告警状态", "安防告警狀態", "Security Alarm");
  }
}

function formatClockHhMm(timestampMs: number): string {
  const d = new Date(timestampMs);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function summarizeRuleDetails(
  rule: AutomationRule,
  devices: readonly SmartDevice[],
  deduper: AutomationTriggerDeduper,
  recentRuns: readonly RecordedAutomationRun[],
  lang: AppLanguage,
): string {
  const parts: string[] = [];
  const opts = rule.triggerOptions;
  if (rule.trigger === "lateNightUsage") {
    parts.push(
      uiText(lang, "时段 {start}:00–{end}:00", "時段 {start}:00–{end}:00", "Window {start}:00–{end}:00", {
        start: pad2(opts.lateNightWindow.startHour),
        end: pad2(opts.lateNightWindow.endHour),
      }),
    );
  } else if (rule.trigger === "scheduledTime" && opts.scheduledTime) {
    const timeStr = `${pad2(opts.scheduledTime.hour)}:${pad2(opts.scheduledTime.minute)}`;
    const days = opts.scheduledTime.weekdays ?? [];
    const dayLabel =
      days.length === 0
        ? uiText(lang, "每天", "每天", "Daily")
        : [...days]
            .sort((a, b) => a - b)
            .map((d) => weekdayShortLabel(d, lang))
            .join(lang === "en" ? ", " : "、");
    parts.push(`${dayLabel} ${timeStr}`);
  } else if (rule.trigger === "sensorThreshold" && opts.sensorCondition) {
    const cond = opts.sensorCondition;
    const devName = devices.find((d) => d.id === cond.deviceId)?.name ?? cond.deviceId;
    parts.push(
      cond.metric === "alarm"
        ? `${devName} · ${sensorAlertSettingsTitle(cond.alertKind ?? "smoke", lang)}`
        : `${devName} · ${metricLabel(cond.metric, lang)} ${comparisonSymbol(cond.comparison ?? "gt")} ${cond.threshold ?? 0}`,
    );
  } else if (rule.trigger === "batteryBelowThreshold") {
    parts.push(uiText(lang, "电量 < {pct}%", "電量 < {pct}%", "Battery < {pct}%", { pct: opts.batteryThresholdPercent }));
  } else if ((rule.trigger === "wifiNetworkJoined" || rule.trigger === "wifiNetworkLeft") && opts.wifiSSID) {
    parts.push(`SSID: ${opts.wifiSSID}`);
  } else if (rule.trigger === "calendarMeetingStartingSoon") {
    parts.push(uiText(lang, "提前 {min} 分钟", "提前 {min} 分鐘", "{min}m before", { min: opts.calendarLeadMinutes }));
  }

  const wifi = rule.conditions.wifi;
  if (wifi.kind === "inAny" && wifi.ssids.length > 0) {
    parts.push(
      uiText(lang, "仅在 Wi-Fi: {list}", "僅在 Wi-Fi: {list}", "Only on Wi-Fi: {list}", {
        list: wifi.ssids.join(", "),
      }),
    );
  } else if (wifi.kind === "notIn" && wifi.ssids.length > 0) {
    parts.push(
      uiText(lang, "排除 Wi-Fi: {list}", "排除 Wi-Fi: {list}", "Except Wi-Fi: {list}", {
        list: wifi.ssids.join(", "),
      }),
    );
  }

  const recentRun = recentRuns.find((r) => r.ruleId === rule.id);
  const lastFiredMs = recentRun?.firedAtMs ?? deduper.lastFireAtMs(rule.id);
  if (lastFiredMs !== null) {
    parts.push(
      uiText(lang, "最近触发 {time}", "最近觸發 {time}", "Last fired {time}", {
        time: formatClockHhMm(lastFiredMs),
      }),
    );
  }
  return parts.join(" · ");
}

function permissionHintText(trigger: AutomationTrigger, lang: AppLanguage): string | null {
  const perm = automationRequiredPermission(trigger);
  if (perm === "location") {
    return uiText(
      lang,
      "读取当前 Wi-Fi 名称在部分系统配置下可能需要定位权限。",
      "讀取目前 Wi-Fi 名稱在部分系統設定下可能需要定位權限。",
      "Reading Wi-Fi SSIDs may require Location permission on some systems.",
    );
  }
  if (perm === "focus") {
    return uiText(
      lang,
      "跟随系统专注/勿扰状态变化自动触发。",
      "跟隨系統專注/勿擾狀態變化自動觸發。",
      "Fires when system Focus / Do Not Disturb changes.",
    );
  }
  if (perm === "calendar") {
    return uiText(
      lang,
      "在日历日程开始前自动联动室内灯光或空调。",
      "在行事曆行程開始前自動聯動室內燈光或空調。",
      "Runs shortly before scheduled calendar meetings begin.",
    );
  }
  return null;
}

function renderTriggerOptionsEditor(
  draft: NewRuleDraftState,
  devices: readonly SmartDevice[],
  lang: AppLanguage,
  esc: (v: string) => string,
): string {
  const permHint = permissionHintText(draft.trigger, lang);
  const permHtml = permHint ? `<p class="cc-field-hint" id="settings-auto-permission-hint">${esc(permHint)}</p>` : "";

  if (draft.trigger === "lateNightUsage") {
    const hourOpts = (sel: number) =>
      Array.from({ length: 24 }, (_, h) => `<option value="${h}" ${h === sel ? "selected" : ""}>${pad2(h)}:00</option>`).join("");
    return `<div class="cc-field-row" style="margin-top: 6px; gap: 8px; flex-wrap: wrap;">
      <label for="settings-auto-latenight-start">${esc(uiText(lang, "深夜时段", "深夜時段", "Late-night window"))}</label>
      <div style="display: flex; align-items: center; gap: 6px;">
        <select id="settings-auto-latenight-start" class="cc-select" style="width: auto;">${hourOpts(draft.lateNightStartHour)}</select>
        <span>–</span>
        <select id="settings-auto-latenight-end" class="cc-select" style="width: auto;">${hourOpts(draft.lateNightEndHour)}</select>
      </div>
    </div>${permHtml}`;
  }

  if (draft.trigger === "scheduledTime") {
    const hourOpts = Array.from({ length: 24 }, (_, h) => `<option value="${h}" ${h === draft.scheduleHour ? "selected" : ""}>${pad2(h)}</option>`).join("");
    const minOpts = Array.from({ length: 60 }, (_, m) => `<option value="${m}" ${m === draft.scheduleMinute ? "selected" : ""}>${pad2(m)}</option>`).join("");
    const weekdayChecks = [1, 2, 3, 4, 5, 6, 0]
      .map(
        (day) =>
          `<label class="cc-checkbox" style="display: inline-flex; width: auto; margin-right: 6px;"><input type="checkbox" data-auto-weekday="${day}" ${draft.scheduleWeekdays.has(day) ? "checked" : ""} /><span>${esc(weekdayShortLabel(day, lang))}</span></label>`,
      )
      .join("");
    return `<div style="margin-top: 6px;">
      <div class="cc-field-row" style="gap: 8px;">
        <label for="settings-auto-schedule-hour">${esc(uiText(lang, "触发时间", "觸發時間", "Trigger time"))}</label>
        <div style="display: flex; align-items: center; gap: 4px;">
          <select id="settings-auto-schedule-hour" class="cc-select" style="width: auto;">${hourOpts}</select>
          <span>:</span>
          <select id="settings-auto-schedule-minute" class="cc-select" style="width: auto;">${minOpts}</select>
        </div>
      </div>
      <div style="margin-top: 4px; display: flex; flex-wrap: wrap; gap: 2px;">${weekdayChecks}</div>
      <p class="cc-field-hint">${esc(uiText(lang, "不勾选星期则默认每天触发。", "不勾選星期則預設每天觸發。", "Leave weekdays unchecked to run every day."))}</p>
    </div>`;
  }

  if (draft.trigger === "sensorThreshold") {
    const activeSensorId =
      draft.sensorDeviceId && devices.some((d) => d.id === draft.sensorDeviceId)
        ? draft.sensorDeviceId
        : (devices[0]?.id ?? "");
    const devOpts =
      devices.length > 0
        ? devices
            .map(
              (d) =>
                `<option value="${esc(d.id)}" ${d.id === activeSensorId ? "selected" : ""}>${esc(d.name)}${d.roomName ? ` · ${esc(d.roomName)}` : ""}</option>`,
            )
            .join("")
        : `<option value="">${esc(uiText(lang, "当前家庭暂无设备", "目前家庭暫無設備", "No devices in current home"))}</option>`;
    const metricOpts = (["temperature", "humidity", "battery", "powerWatts", "pm25", "alarm"] as const)
      .map((m) => `<option value="${m}" ${m === draft.sensorMetric ? "selected" : ""}>${esc(metricLabel(m, lang))}</option>`)
      .join("");
    const compOpts = (["gt", "gte", "lt", "lte"] as const)
      .map((c) => `<option value="${c}" ${c === draft.sensorComparison ? "selected" : ""}>${esc(comparisonSymbol(c))}</option>`)
      .join("");
    const alertKindOpts = SENSOR_ALERT_KINDS.map(
      (k) => `<option value="${k}" ${k === draft.sensorAlertKind ? "selected" : ""}>${esc(sensorAlertSettingsTitle(k, lang))}</option>`,
    ).join("");
    return `<div style="margin-top: 6px; display: flex; flex-direction: column; gap: 6px;">
      <div class="cc-field-row" style="gap: 8px;">
        <label for="settings-auto-sensor-device">${esc(uiText(lang, "监控设备", "監控設備", "Source device"))}</label>
        <select id="settings-auto-sensor-device" class="cc-select" ${devices.length === 0 ? "disabled" : ""}>${devOpts}</select>
      </div>
      <div class="cc-field-row" style="gap: 8px; flex-wrap: wrap;">
        <label for="settings-auto-sensor-metric">${esc(uiText(lang, "满足条件", "滿足條件", "Condition"))}</label>
        <div style="display: flex; align-items: center; gap: 6px; flex-wrap: wrap;">
          <select id="settings-auto-sensor-metric" class="cc-select" style="width: auto;">${metricOpts}</select>
          ${
            draft.sensorMetric === "alarm"
              ? `<select id="settings-auto-sensor-alert-kind" class="cc-select" style="width: auto;">${alertKindOpts}</select>`
              : `<select id="settings-auto-sensor-comparison" class="cc-select" style="width: auto;">${compOpts}</select><input id="settings-auto-sensor-threshold" class="cc-input" type="number" step="any" value="${esc(String(draft.sensorThreshold))}" style="width: 82px;" />`
          }
        </div>
      </div>
    </div>`;
  }

  if (draft.trigger === "batteryBelowThreshold") {
    return `<div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
      <label for="settings-auto-battery-threshold">${esc(uiText(lang, "电脑电量低于 (%)", "電腦電量低於 (%)", "Battery below (%)"))}</label>
      <input id="settings-auto-battery-threshold" class="cc-input" type="number" min="1" max="100" value="${draft.batteryThreshold}" style="width: 82px;" />
    </div>`;
  }

  if (draft.trigger === "wifiNetworkJoined" || draft.trigger === "wifiNetworkLeft") {
    return `<div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
      <label for="settings-auto-trigger-ssid">${esc(uiText(lang, "指定 Wi-Fi 名称（可选）", "指定 Wi-Fi 名稱（可選）", "Target Wi-Fi SSID (optional)"))}</label>
      <input id="settings-auto-trigger-ssid" class="cc-input" type="text" value="${esc(draft.triggerWifiSSID)}" placeholder="${esc(uiText(lang, "留空匹配任意 Wi-Fi", "留空匹配任意 Wi-Fi", "Blank matches any Wi-Fi"))}" style="max-width: 190px;" />
    </div>${permHtml}`;
  }

  if (draft.trigger === "calendarMeetingStartingSoon") {
    return `<div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
      <label for="settings-auto-calendar-lead">${esc(uiText(lang, "提前分钟数", "提前分鐘數", "Minutes before start"))}</label>
      <input id="settings-auto-calendar-lead" class="cc-input" type="number" min="1" max="60" value="${draft.calendarLeadMinutes}" style="width: 82px;" />
    </div>${permHtml}`;
  }

  return permHtml;
}

export function renderAutomationAndSafetySettingsSections(ctx: SettingsViewContext): string {
  const esc = (v: string) => ctx.escapeHtml(v);
  const center = ctx.activityCenter ?? null;
  const storage = center?.storage ?? defaultSafetyStorage();
  const lang = effectiveLanguage(ctx.settings.interfaceLanguage);
  const aliasedDevices = aliasedDevicesFor(ctx.devices, ctx.layout ?? ctx.settings.layout);
  const scenes = resolveScenesForContext(ctx);

  const ruleStore = center?.automationEngine.store ?? new AutomationRuleStore(storage);
  const deduper = center?.automationEngine.deduper ?? new AutomationTriggerDeduper(storage);
  const rules = ruleStore.load();
  const scopeKey = center?.scopeKey ?? computeActivityScopeKey({ settings: ctx.settings });
  const scopedRuns = (center?.recentAutomationRuns ?? []).filter((r) => r.scope === scopeKey);

  const session = ctx.autoSafetySession ?? null;
  if (session) {
    syncAutoSafetySessionScope(session, scopeKey, ctx.sourceRevision);
  }
  const draft = session?.draft ?? createDefaultDraft();
  const controllableDevices = aliasedDevices.filter(isDeviceControllableForRule);
  const effectiveSceneId =
    draft.selectedSceneId && scenes.some((s) => s.id === draft.selectedSceneId)
      ? draft.selectedSceneId
      : (scenes[0]?.id ?? "");
  const effectiveSensorDeviceId =
    draft.sensorDeviceId && aliasedDevices.some((d) => d.id === draft.sensorDeviceId)
      ? draft.sensorDeviceId
      : (aliasedDevices[0]?.id ?? "");

  const parsedWifiSSIDs = normalizeWiFiSSIDs(draft.wifiSSIDsText.split(/[,\n，]/));
  const wifiInvalid = draft.wifiKind !== "any" && parsedWifiSSIDs.length === 0;
  const actionInvalid =
    (draft.actionKind === "devices" && draft.selectedDeviceIds.size === 0) ||
    (draft.actionKind === "scene" && !effectiveSceneId);
  const triggerInvalid = draft.trigger === "sensorThreshold" && !effectiveSensorDeviceId;
  const canAddRule = !wifiInvalid && !actionInvalid && !triggerInvalid;

  const safetyPrefs = loadSafetyGuardPrefs(storage);
  const sensorPolicy = loadSensorAlertPolicy(storage);
  const previewMarkdown =
    session?.healthReportPreviewMarkdown ??
    (center?.weeklyReportCard && center.weeklyReportCard.scope === scopeKey
      ? renderWeeklyHealthMarkdown(center.weeklyReportCard.report, lang)
      : null);

  const rulesHtml =
    rules.length === 0
      ? `<p class="cc-field-hint" id="settings-auto-rules-empty" style="margin: 4px 0 8px 0;">${esc(
          uiText(
            lang,
            "暂未创建自动化规则。可在下方选择锁屏离开、解锁回来、深夜用机、定时或传感器条件快速添加。",
            "暫未建立自動化規則。可在下方選擇鎖屏離開、解鎖回來、深夜用機、定時或感測器條件快速新增。",
            "No automation rules yet. Add rules below for lock/away, unlock/back, late-night PC use, schedules, or sensor triggers.",
          ),
        )}</p>`
      : `<div id="settings-auto-rules-list" class="cc-timers-stack" style="margin: 6px 0 8px 0;">
        ${rules
          .map((rule) => {
            const titleText = `${automationTriggerTitle(rule.trigger, lang)} → ${summarizeAutomationAction(rule.action, aliasedDevices, scenes, lang)}`;
            const details = summarizeRuleDetails(rule, aliasedDevices, deduper, scopedRuns, lang);
            return `<div class="cc-update-row" data-auto-rule-row="${esc(rule.id)}" style="padding: 7px 8px; border-radius: 8px; background: rgba(128, 128, 128, 0.08); gap: 8px; align-items: center; flex-wrap: wrap;">
            <div style="display: flex; align-items: flex-start; gap: 7px; flex: 1 1 200px; min-width: 0;">
              <span style="margin-top: 2px; opacity: ${rule.isEnabled ? "0.9" : "0.45"};">${triggerIconSvg(rule.trigger)}</span>
              <div style="min-width: 0;">
                <div style="font-size: 12.5px; font-weight: 600; opacity: ${rule.isEnabled ? "1" : "0.55"}; word-break: break-word;">${esc(titleText)}</div>
                ${details ? `<div class="cc-field-hint" style="margin: 2px 0 0 0;">${esc(details)}</div>` : ""}
              </div>
            </div>
            <div style="display: flex; align-items: center; gap: 6px; margin-left: auto;">
              <input type="checkbox" data-auto-rule-toggle="${esc(rule.id)}" aria-label="${esc(uiText(lang, "启用规则", "啟用規則", "Enable rule"))}" ${rule.isEnabled ? "checked" : ""} />
              <button type="button" class="cc-btn-secondary" data-auto-rule-run="${esc(rule.id)}">${esc(uiText(lang, "立即试运行", "立即試運行", "Run Now"))}</button>
              <button type="button" class="cc-btn-secondary" data-auto-rule-delete="${esc(rule.id)}">${esc(uiText(lang, "删除", "刪除", "Delete"))}</button>
            </div>
          </div>`;
          })
          .join("")}
      </div>`;

  const recentRunsHtml =
    scopedRuns.length > 0
      ? `<div id="settings-auto-recent-runs" style="margin: 4px 0 8px 0;">
        <div style="font-size: 11.5px; font-weight: 600; opacity: 0.82; margin-bottom: 4px;">${esc(uiText(lang, "最近触发记录（5 分钟内可撤销）", "最近觸發記錄（5 分鐘內可撤銷）", "Recent Automation Runs (5m Undo)"))}</div>
        <div class="cc-timers-stack">
          ${scopedRuns
            .slice(0, 3)
            .map(
              (run) => `<div class="cc-update-row" data-auto-recent-run="${esc(run.id)}" style="font-size: 12px; gap: 6px;">
            <span>${esc(`${formatClockHhMm(run.firedAtMs)} · ${run.triggerTitle} → ${run.summary}`)}</span>
            <button type="button" class="cc-btn-secondary" data-auto-run-undo="${esc(run.id)}">${esc(uiText(lang, "撤销", "撤銷", "Undo"))}</button>
          </div>`,
            )
            .join("")}
        </div>
      </div>`
      : "";

  const triggerOptionsHtml = AUTOMATION_TRIGGERS.map(
    (tr) => `<option value="${tr}" ${tr === draft.trigger ? "selected" : ""}>${esc(automationTriggerTitle(tr, lang))}</option>`,
  ).join("");
  const sensorAlertTogglesHtml = SENSOR_ALERT_KINDS.map((kind) => {
    const checked = sensorPolicy.enabled[kind] ?? false;
    const hazardBadge = sensorAlertIsHazard(kind)
      ? ` <span style="font-size: 11px; opacity: 0.68;">(${esc(uiText(lang, "24h 全天候", "24h 全天候", "24/7 always on"))})</span>`
      : "";
    return `<label class="cc-checkbox"><input type="checkbox" id="settings-sensor-alert-${kind}" data-sensor-alert-kind="${kind}" ${checked ? "checked" : ""} /><span>${esc(sensorAlertSettingsTitle(kind, lang))}${hazardBadge}</span></label>`;
  }).join("");
  const doorbellSecOptionsHtml = DOORBELL_POPUP_SECOND_OPTIONS.map(
    (sec) => `<option value="${sec}" ${sec === safetyPrefs.doorbellPopupSeconds ? "selected" : ""}>${esc(uiText(lang, "{sec} 秒", "{sec} 秒", "{sec}s", { sec }))}</option>`,
  ).join("");

  const actionControlsHtml =
    draft.actionKind === "quickAction"
      ? `<div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
        <label for="settings-auto-quick-action">${esc(uiText(lang, "快捷预设", "捷徑預設", "Quick preset"))}</label>
        <select id="settings-auto-quick-action" class="cc-select">
          <option value="lightsOff" ${draft.quickAction === "lightsOff" ? "selected" : ""}>${esc(uiText(lang, "全屋关灯", "全屋關燈", "All Lights Off"))}</option>
          <option value="softNightLight" ${draft.quickAction === "softNightLight" ? "selected" : ""}>${esc(uiText(lang, "柔和夜灯（30% 暖光）", "柔和夜燈（30% 暖光）", "Soft Night Light (30% warm)"))}</option>
          <option value="climateSleepOff" ${draft.quickAction === "climateSleepOff" ? "selected" : ""}>${esc(uiText(lang, "关闭温控与风扇", "關閉溫控與風扇", "Turn Off Climate & Fans"))}</option>
        </select>
      </div>`
      : draft.actionKind === "devices"
        ? `<div style="margin-top: 6px;">
          <div class="cc-field-row" style="gap: 8px; margin-bottom: 4px;">
            <label for="settings-auto-devices-power">${esc(uiText(lang, "目标状态", "目標狀態", "Target state"))}</label>
            <select id="settings-auto-devices-power" class="cc-select" style="width: auto;">
              <option value="off" ${!draft.devicesPowerOn ? "selected" : ""}>${esc(uiText(lang, "关闭所选设备", "關閉所選設備", "Turn Off Selected"))}</option>
              <option value="on" ${draft.devicesPowerOn ? "selected" : ""}>${esc(uiText(lang, "打开所选设备", "打開所選設備", "Turn On Selected"))}</option>
            </select>
          </div>
          ${
            controllableDevices.length > 0
              ? `<div class="cc-timers-stack" id="settings-auto-devices-list">${controllableDevices
                  .map(
                    (d) =>
                      `<label class="cc-checkbox"><input type="checkbox" data-auto-target-device="${esc(d.id)}" ${draft.selectedDeviceIds.has(d.id) ? "checked" : ""} /><span>${esc(d.name)}${d.roomName ? ` · ${esc(d.roomName)}` : ""}</span></label>`,
                  )
                  .join("")}</div>`
              : `<p class="cc-field-hint">${esc(uiText(lang, "当前家庭暂无可控设备。", "目前家庭暫無可控設備。", "No controllable devices in the current home."))}</p>`
          }
        </div>`
        : `<div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
          <label for="settings-auto-scene-id">${esc(uiText(lang, "目标场景", "目標場景", "Target scene"))}</label>
          <select id="settings-auto-scene-id" class="cc-select" ${scenes.length === 0 ? "disabled" : ""}>
            ${
              scenes.length > 0
                ? scenes.map((s) => `<option value="${esc(s.id)}" ${s.id === effectiveSceneId ? "selected" : ""}>${esc(s.name)}</option>`).join("")
                : `<option value="">${esc(uiText(lang, "当前家庭暂无可用场景", "目前家庭暫無可用場景", "No scenes available in current home"))}</option>`
            }
          </select>
        </div>`;

  return `
    <div class="cc-field" data-settings-anchor="automationRules" id="settings-automation-section">
      <div class="cc-field-row">
        <label>${esc(uiText(lang, "本机状态自动化规则", "本機狀態自動化規則", "PC Context Automation Rules"))}</label>
        <button type="button" class="cc-btn-secondary" id="btn-toggle-auto-form">${esc(
          draft.formOpen
            ? uiText(lang, "＋ 新建自动化规则", "＋ 新增自動化規則", "+ New Automation Rule")
            : uiText(lang, "＋ 展开新建规则", "＋ 展開新增規則", "+ Expand Rule Builder"),
        )}</button>
      </div>
      <p class="cc-field-hint">${esc(uiText(lang, "根据电脑锁屏离开、解锁回来、深夜用机、定时、传感器状态、会议摄像头/麦克风占用或低电量自动控制当前家庭设备。", "根據電腦鎖屏離開、解鎖回來、深夜用機、定時、感測器狀態、會議攝影機/麥克風佔用或低電量自動控制目前家庭設備。", "Run home actions automatically on PC lock/away, unlock/back, late-night usage, schedules, sensor states, camera/mic meetings, or battery thresholds."))}</p>
      ${rulesHtml}
      ${recentRunsHtml}
      <div id="settings-auto-form" ${draft.formOpen ? "" : "hidden"} style="margin-top: 8px; padding: 10px; border-radius: 8px; background: rgba(128, 128, 128, 0.07);">
        <div style="font-size: 12px; font-weight: 600; margin-bottom: 6px;">${esc(uiText(lang, "＋ 新建自动化规则", "＋ 新增自動化規則", "+ New Automation Rule"))}</div>
        <div class="cc-field-row" style="gap: 8px;">
          <label for="settings-auto-trigger">${esc(uiText(lang, "当本机发生", "當本機發生", "When PC / Sensor"))}</label>
          <select id="settings-auto-trigger" class="cc-select">${triggerOptionsHtml}</select>
        </div>
        ${renderTriggerOptionsEditor(draft, aliasedDevices, lang, esc)}
        <div class="cc-field-row" style="margin-top: 8px; gap: 8px;">
          <label for="settings-auto-wifi-kind">${esc(uiText(lang, "Wi-Fi 附加条件", "Wi-Fi 附加條件", "Wi-Fi condition"))}</label>
          <select id="settings-auto-wifi-kind" class="cc-select">
            <option value="any" ${draft.wifiKind === "any" ? "selected" : ""}>${esc(uiText(lang, "不限 Wi-Fi 网络", "不限 Wi-Fi 網路", "Any Wi-Fi network"))}</option>
            <option value="inAny" ${draft.wifiKind === "inAny" ? "selected" : ""}>${esc(uiText(lang, "仅在指定 Wi-Fi 下生效", "僅在指定 Wi-Fi 下生效", "Only on specified Wi-Fi"))}</option>
            <option value="notIn" ${draft.wifiKind === "notIn" ? "selected" : ""}>${esc(uiText(lang, "排除指定 Wi-Fi", "排除指定 Wi-Fi", "Except on specified Wi-Fi"))}</option>
          </select>
        </div>
        ${
          draft.wifiKind !== "any"
            ? `<div style="margin-top: 6px;">
              <input id="settings-auto-wifi-ssids" class="cc-input" type="text" value="${esc(draft.wifiSSIDsText)}" placeholder="${esc(uiText(lang, "输入 Wi-Fi 名称（多个用逗号分隔，如 Home_5G, Study）", "輸入 Wi-Fi 名稱（多個用逗號分隔）", "Wi-Fi SSIDs, comma-separated (e.g. Home_5G, Office)"))}" />
              ${wifiInvalid ? `<p class="cc-field-hint" id="settings-auto-wifi-hint" style="color: #e67e22;">${esc(uiText(lang, "请至少填写一个 Wi-Fi 名称（SSID）后再保存。", "請至少填寫一個 Wi-Fi 名稱（SSID）後再儲存。", "Enter at least one Wi-Fi SSID to save this condition."))}</p>` : ""}
            </div>`
            : ""
        }
        <div class="cc-field-row" style="margin-top: 8px; gap: 8px;">
          <label for="settings-auto-action-kind">${esc(uiText(lang, "执行动作", "執行動作", "Perform action"))}</label>
          <select id="settings-auto-action-kind" class="cc-select">
            <option value="quickAction" ${draft.actionKind === "quickAction" ? "selected" : ""}>${esc(uiText(lang, "快捷家居动作", "捷徑家居動作", "Quick Home Action"))}</option>
            <option value="devices" ${draft.actionKind === "devices" ? "selected" : ""}>${esc(uiText(lang, "指定设备开关", "指定設備開關", "Control Specific Devices"))}</option>
            <option value="scene" ${draft.actionKind === "scene" ? "selected" : ""}>${esc(uiText(lang, "激活家庭场景", "啟動家庭場景", "Activate Home Scene"))}</option>
          </select>
        </div>
        ${actionControlsHtml}
        <div style="display: flex; justify-content: flex-end; gap: 6px; margin-top: 10px;">
          <button type="button" class="cc-btn-primary" id="btn-add-auto-rule" ${canAddRule ? "" : "disabled"}>${esc(uiText(lang, "保存自动化规则", "儲存自動化規則", "Save Automation Rule"))}</button>
        </div>
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="safetyAlerts" id="settings-safety-guard-section">
      <div class="cc-field-row">
        <label for="settings-safety-master">${esc(uiText(lang, "主动安全守护与低电量提醒", "主動安全守護與低電量提醒", "Active Safety Guard & Low Battery Alerts"))}</label>
        <input id="settings-safety-master" type="checkbox" ${safetyPrefs.enableSafetyAlerts ? "checked" : ""} />
      </div>
      <p class="cc-field-hint">${esc(uiText(lang, "监测大功率用电器长开、空调取暖连续运行、置顶常用设备掉线与电池低电量，并在面板顶部提供一键关闭。", "監測大功率電器長開、空調取暖連續運作、置頂常用設備斷線與電池低電量，並在面板頂部提供一鍵關閉。", "Watch for long-running high-wattage plugs, 4h climate/heaters, pinned device outages, and batteries below 15%."))}</p>
      <div class="cc-timers-stack" style="margin-top: 6px;">
        <label class="cc-checkbox"><input id="settings-safety-plug" type="checkbox" ${safetyPrefs.longRunningPlug ? "checked" : ""} ${safetyPrefs.enableSafetyAlerts ? "" : "disabled"} /><span>${esc(uiText(lang, "大功率插座长开提醒（>300W 连续 45 分钟）", "大功率插座長開提醒（>300W 連續 45 分鐘）", "High-power plug running >45 min (>300W)"))}</span></label>
        <label class="cc-checkbox"><input id="settings-safety-climate" type="checkbox" ${safetyPrefs.longRunningClimate ? "checked" : ""} ${safetyPrefs.enableSafetyAlerts ? "" : "disabled"} /><span>${esc(uiText(lang, "温控与取暖设备长开提醒（连续运行 4 小时）", "溫控與取暖設備長開提醒（連續運作 4 小時）", "Climate & heater running >4 hours"))}</span></label>
        <label class="cc-checkbox"><input id="settings-safety-offline" type="checkbox" ${safetyPrefs.favoriteOffline ? "checked" : ""} ${safetyPrefs.enableSafetyAlerts ? "" : "disabled"} /><span>${esc(uiText(lang, "常用置顶设备离线提醒", "常用置頂設備離線提醒", "Pinned favorite device offline alert"))}</span></label>
        <label class="cc-checkbox"><input id="settings-safety-low-battery" type="checkbox" ${safetyPrefs.lowBattery ? "checked" : ""} ${safetyPrefs.enableSafetyAlerts ? "" : "disabled"} /><span>${esc(uiText(lang, "低电量提醒（电量 < 15%，每 24 小时最多一次）", "低電量提醒（電量 < 15%，每 24 小時最多一次）", "Low battery alert (<15%, 24h cooldown)"))}</span></label>
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="sensorAlerts" id="settings-sensor-alerts-section">
      <label>${esc(uiText(lang, "安防传感器告警", "安防感測器告警", "Security Sensor Alerts"))}</label>
      <p class="cc-field-hint">${esc(uiText(lang, "监测烟感、燃气、水浸、门窗、人体移动、震动与门锁异常边沿变化；烟雾/燃气/水浸在首次采样异常时立即告警。", "監測煙感、燃氣、水浸、門窗、人體移動、震動與門鎖異常邊沿變化；煙霧/燃氣/水浸在首次取樣異常時立即告警。", "Edge-triggered alerts for smoke, gas, water leak, contact, motion, vibration, and door lock anomalies."))}</p>
      <div class="cc-timers-stack" style="margin-top: 6px;">${sensorAlertTogglesHtml}</div>
      <div class="cc-field-row" style="margin-top: 8px;">
        <label for="settings-sensor-only-away">${esc(uiText(lang, "门窗、移动与震动仅在离开或锁屏时提醒", "門窗、移動與震動僅在離開或鎖屏時提醒", "Notify door/motion/vibration only when away or locked"))}</label>
        <input id="settings-sensor-only-away" type="checkbox" ${sensorPolicy.onlyWhenAway ? "checked" : ""} />
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="doorbellAutoView" id="settings-doorbell-section">
      <label>${esc(uiText(lang, "Home Assistant 门铃响铃联动", "Home Assistant 門鈴響鈴聯動", "Home Assistant Doorbell Auto-Popup"))}</label>
      <div class="cc-field-row" style="margin-top: 4px;">
        <label for="settings-doorbell-auto-popup">${esc(uiText(lang, "门铃响铃时自动弹出门口实时画面", "門鈴響鈴時自動彈出門口即時畫面", "Auto-open live camera view on doorbell ring"))}</label>
        <input id="settings-doorbell-auto-popup" type="checkbox" ${safetyPrefs.doorbellAutoPopup ? "checked" : ""} />
      </div>
      <div class="cc-field-row" style="margin-top: 6px;">
        <label for="settings-doorbell-chime">${esc(uiText(lang, "响铃时播放桌面提示音（锁屏时静音）", "響鈴時播放桌面提示音（鎖屏時靜音）", "Play chime on doorbell ring (muted while locked)"))}</label>
        <input id="settings-doorbell-chime" type="checkbox" ${safetyPrefs.doorbellChime ? "checked" : ""} />
      </div>
      <div class="cc-field-row" style="margin-top: 6px; gap: 8px;">
        <label for="settings-doorbell-seconds">${esc(uiText(lang, "无交互自动收起秒数", "無互動自動收起秒數", "Auto-close after inactivity"))}</label>
        <select id="settings-doorbell-seconds" class="cc-select" style="width: auto;" ${safetyPrefs.doorbellAutoPopup ? "" : "disabled"}>${doorbellSecOptionsHtml}</select>
      </div>
      <p class="cc-field-hint">${esc(uiText(lang, "锁屏或正在手动查看摄像头画面时不抢占窗口；点击弹窗后自动取消倒计时并保持常驻。", "鎖屏或正在手動查看攝影機畫面時不搶佔視窗；點擊彈窗後自動取消倒數並保持常駐。", "Never interrupts locked screens or active manual camera views; any interaction keeps the view open."))}</p>
    </div>

    <div class="cc-field" data-settings-anchor="weeklyReport" id="settings-weekly-report-section">
      <div class="cc-field-row">
        <label for="settings-weekly-report-enabled">${esc(uiText(lang, "每周日家庭健康周报", "每週日家庭健康週報", "Weekly Home Health Report (Sundays)"))}</label>
        <input id="settings-weekly-report-enabled" type="checkbox" ${safetyPrefs.enableWeeklyHealthReport ? "checked" : ""} />
      </div>
      <p class="cc-field-hint">${esc(uiText(lang, "每周日 20:00 汇总全屋用电变化、房间温湿度越界、插座待机耗电、滤芯与电池寿命及设备掉线诊断。", "每週日 20:00 彙整全屋用電變化、房間溫濕度越界、插座待機耗電、濾芯與電池壽命及設備斷線診斷。", "Every Sunday at 20:00, summarizes weekly energy trends, room climate, standby power, filter/battery life, and offline diagnostics."))}</p>
      <div class="cc-update-row" style="margin-top: 8px; gap: 6px; flex-wrap: wrap;">
        <button type="button" class="cc-btn-secondary" id="btn-generate-copy-health-report">${esc(uiText(lang, "生成 / 复制 Markdown 健康周报", "產生 / 複製 Markdown 健康週報", "Generate & Copy Markdown Health Report"))}</button>
        ${previewMarkdown !== null ? `<button type="button" class="cc-btn-secondary" id="btn-clear-health-report-preview">${esc(uiText(lang, "收起预览", "收起預覽", "Hide Preview"))}</button>` : ""}
      </div>
      ${
        previewMarkdown !== null
          ? `<div id="settings-health-report-preview" style="margin-top: 8px; padding: 8px 10px; border-radius: 8px; background: rgba(128, 128, 128, 0.09); max-height: 210px; overflow-y: auto;">
            <pre id="settings-health-report-markdown" style="margin: 0; white-space: pre-wrap; word-break: break-word; font-size: 11.5px; line-height: 1.45;">${esc(previewMarkdown)}</pre>
          </div>`
          : ""
      }
    </div>
  `;
}

function buildActionFromDraft(draft: NewRuleDraftState, scenes: readonly HomeScene[]): AutomationAction | null {
  if (draft.actionKind === "quickAction") return { kind: "quickAction", quickAction: draft.quickAction };
  if (draft.actionKind === "devices") {
    const ids = [...draft.selectedDeviceIds].filter((id) => id.trim() !== "");
    return ids.length === 0 ? null : { kind: "devices", deviceIds: ids, isOn: draft.devicesPowerOn };
  }
  const sceneId =
    draft.selectedSceneId && scenes.some((s) => s.id === draft.selectedSceneId)
      ? draft.selectedSceneId
      : (scenes[0]?.id ?? "");
  return sceneId ? { kind: "scene", sceneId } : null;
}

function buildSensorConditionFromDraft(
  draft: NewRuleDraftState,
  devices: readonly SmartDevice[],
): SensorThresholdCondition | null {
  if (draft.trigger !== "sensorThreshold") return null;
  const deviceId =
    draft.sensorDeviceId && devices.some((d) => d.id === draft.sensorDeviceId)
      ? draft.sensorDeviceId
      : (devices[0]?.id ?? "");
  if (!deviceId) return null;
  if (draft.sensorMetric === "alarm") return { deviceId, metric: "alarm", alertKind: draft.sensorAlertKind };
  return {
    deviceId,
    metric: draft.sensorMetric,
    comparison: draft.sensorComparison,
    threshold: Number.isFinite(draft.sensorThreshold) ? draft.sensorThreshold : 28,
  };
}

const isInputEl = (el: unknown): el is HTMLInputElement =>
  Boolean(el && typeof el === "object" && (el as HTMLElement).tagName === "INPUT");
const isSelectEl = (el: unknown): el is HTMLSelectElement =>
  Boolean(el && typeof el === "object" && (el as HTMLElement).tagName === "SELECT");

export function bindAutomationSettingsEvents(host: AutoSafetySettingsHost): void {
  const session = getHostAutoSafetySession(host);
  if (host.activeSheet !== "settings") {
    session.healthReportPreviewMarkdown = null;
    return;
  }

  const center = resolveHostActivityCenter(host);
  const storage = center?.storage ?? defaultSafetyStorage();
  const ruleStore = center?.automationEngine.store ?? new AutomationRuleStore(storage);
  const draft = session.draft;
  const lang = effectiveLanguage(host.settings.interfaceLanguage);
  const aliasedDevices = aliasedDevicesFor(host.devices, host.layout);

  const autoSection = host.root.querySelector<HTMLElement>("#settings-automation-section");
  autoSection?.addEventListener("change", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target || target.closest("[data-exit-ghost]")) return;
    if (isInputEl(target) && target.dataset.autoRuleToggle) {
      const ruleId = target.dataset.autoRuleToggle;
      ruleStore.save(ruleStore.load().map((r) => (r.id === ruleId ? { ...r, isEnabled: target.checked } : r)));
      host.render();
      return;
    }
    if (target.id === "settings-auto-trigger" && isSelectEl(target) && isAutomationTrigger(target.value)) {
      draft.trigger = target.value;
      host.render();
      return;
    }
    if (target.id === "settings-auto-latenight-start" && isSelectEl(target)) draft.lateNightStartHour = Number(target.value) || 0;
    else if (target.id === "settings-auto-latenight-end" && isSelectEl(target)) draft.lateNightEndHour = Number(target.value) || 0;
    else if (target.id === "settings-auto-schedule-hour" && isSelectEl(target)) draft.scheduleHour = Number(target.value) || 0;
    else if (target.id === "settings-auto-schedule-minute" && isSelectEl(target)) draft.scheduleMinute = Number(target.value) || 0;
    else if (isInputEl(target) && target.dataset.autoWeekday !== undefined) {
      const day = Number(target.dataset.autoWeekday);
      if (Number.isInteger(day) && day >= 0 && day <= 6) {
        if (target.checked) draft.scheduleWeekdays.add(day);
        else draft.scheduleWeekdays.delete(day);
      }
    } else if (target.id === "settings-auto-sensor-device" && isSelectEl(target)) draft.sensorDeviceId = target.value;
    else if (target.id === "settings-auto-sensor-metric" && isSelectEl(target)) {
      draft.sensorMetric = target.value as SensorThresholdMetric;
      host.render();
    } else if (target.id === "settings-auto-sensor-comparison" && isSelectEl(target)) {
      draft.sensorComparison = target.value as SensorThresholdComparison;
    } else if (target.id === "settings-auto-sensor-alert-kind" && isSelectEl(target)) {
      draft.sensorAlertKind = target.value as SensorAlertKind;
    } else if (target.id === "settings-auto-wifi-kind" && isSelectEl(target)) {
      draft.wifiKind = target.value as "any" | "inAny" | "notIn";
      host.render();
    } else if (target.id === "settings-auto-action-kind" && isSelectEl(target)) {
      draft.actionKind = target.value as "quickAction" | "devices" | "scene";
      host.render();
    } else if (target.id === "settings-auto-quick-action" && isSelectEl(target)) {
      draft.quickAction = target.value as QuickActionId;
    } else if (target.id === "settings-auto-devices-power" && isSelectEl(target)) {
      draft.devicesPowerOn = target.value === "on";
    } else if (isInputEl(target) && target.dataset.autoTargetDevice) {
      if (target.checked) draft.selectedDeviceIds.add(target.dataset.autoTargetDevice);
      else draft.selectedDeviceIds.delete(target.dataset.autoTargetDevice);
      host.render();
    } else if (target.id === "settings-auto-scene-id" && isSelectEl(target)) {
      draft.selectedSceneId = target.value;
    }
  });

  const handleDraftInput = (event: Event) => {
    const target = event.target;
    if (!isInputEl(target) || target.closest("[data-exit-ghost]")) return;
    if (target.id === "settings-auto-wifi-ssids") {
      draft.wifiSSIDsText = target.value;
      const valid = normalizeWiFiSSIDs(draft.wifiSSIDsText.split(/[,\n，]/)).length > 0;
      const addBtn = host.root.querySelector<HTMLButtonElement>("#btn-add-auto-rule");
      const hintEl = host.root.querySelector<HTMLElement>("#settings-auto-wifi-hint");
      if (hintEl) hintEl.hidden = valid;
      if (addBtn) {
        const actionInvalid =
          (draft.actionKind === "devices" && draft.selectedDeviceIds.size === 0) ||
          (draft.actionKind === "scene" && host.scenes.length === 0);
        addBtn.disabled = !valid || actionInvalid;
      }
    } else if (target.id === "settings-auto-battery-threshold") {
      const parsed = Number(target.value);
      if (Number.isFinite(parsed)) draft.batteryThreshold = Math.min(100, Math.max(1, Math.trunc(parsed)));
    } else if (target.id === "settings-auto-trigger-ssid") {
      draft.triggerWifiSSID = target.value;
    } else if (target.id === "settings-auto-calendar-lead") {
      const parsed = Number(target.value);
      if (Number.isFinite(parsed)) draft.calendarLeadMinutes = Math.min(60, Math.max(1, Math.trunc(parsed)));
    } else if (target.id === "settings-auto-sensor-threshold") {
      const parsed = Number(target.value);
      if (Number.isFinite(parsed)) draft.sensorThreshold = parsed;
    }
  };
  autoSection?.addEventListener("input", handleDraftInput);
  autoSection?.addEventListener("change", handleDraftInput);

  autoSection?.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLButtonElement>("button");
    if (!btn || btn.closest("[data-exit-ghost]")) return;

    if (btn.id === "btn-toggle-auto-form") {
      draft.formOpen = !draft.formOpen;
      host.render();
      return;
    }

    const deleteId = btn.dataset.autoRuleDelete;
    if (deleteId) {
      ruleStore.save(ruleStore.load().filter((r) => r.id !== deleteId));
      host.replyBanner = {
        text: uiText(lang, "已删除自动化规则", "已刪除自動化規則", "Deleted automation rule"),
        source: uiText(lang, "状态感知自动化", "狀態感知自動化", "Context Automation"),
      };
      host.render();
      return;
    }

    const runId = btn.dataset.autoRuleRun;
    if (runId) {
      const rule = ruleStore.load().find((r) => r.id === runId);
      if (!rule || typeof host.applyCommand !== "function") return;
      void (async () => {
        if (isFullPanelHost(host) && (await rejectIfControlBlockedWhileLocked(host))) return;
        const execHost = host as AutoSafetySettingsHost & {
          applyCommand(cmd: DeviceCommand, silent?: boolean): Promise<boolean>;
        };
        const run = await executeAutomationRule(execHost, rule, {
          scope: center?.scopeKey ?? computeActivityScopeKey(host),
          displayDevices: aliasedDevices,
          recordUndoKindSnapshots,
          onUndoRecorded: (recorded) => {
            if (!center) return;
            center.dismissedActivityIds.delete(`auto:${recorded.id}`);
            center.recentAutomationRuns = [
              recorded,
              ...center.recentAutomationRuns.filter((r) => r.id !== recorded.id),
            ].slice(0, MAX_RECENT_AUTOMATION_RUNS);
          },
        });
        if (!run) {
          host.replyBanner = {
            text: uiText(
              lang,
              "试运行未匹配到需变更状态的设备",
              "試運行未匹配到需變更狀態的設備",
              "Dry-run matched no devices needing a state change",
            ),
            source: uiText(lang, "状态感知自动化", "狀態感知自動化", "Context Automation"),
          };
        }
        host.render();
      })();
      return;
    }

    const undoRunId = btn.dataset.autoRunUndo;
    if (undoRunId && isFullPanelHost(host)) {
      void executeAutomationCardUndo(host, undoRunId);
      return;
    }

    if (btn.id === "btn-add-auto-rule") {
      const action = buildActionFromDraft(draft, host.scenes);
      if (!action) return;
      let wifiCond: AutomationWiFiCondition = { kind: "any" };
      if (draft.wifiKind !== "any") {
        const ssids = normalizeWiFiSSIDs(draft.wifiSSIDsText.split(/[,\n，]/));
        if (ssids.length === 0) return;
        wifiCond = { kind: draft.wifiKind, ssids };
      }
      const sensorCond = buildSensorConditionFromDraft(draft, aliasedDevices);
      if (draft.trigger === "sensorThreshold" && !sensorCond) return;
      const scheduledTime =
        draft.trigger === "scheduledTime"
          ? {
              hour: draft.scheduleHour,
              minute: draft.scheduleMinute,
              ...(draft.scheduleWeekdays.size > 0
                ? { weekdays: [...draft.scheduleWeekdays].sort((a, b) => a - b) }
                : {}),
            }
          : null;
      const created = createAutomationRule({
        trigger: draft.trigger,
        action,
        isEnabled: true,
        triggerOptions: {
          batteryThresholdPercent: draft.batteryThreshold,
          wifiSSID:
            draft.trigger === "wifiNetworkJoined" || draft.trigger === "wifiNetworkLeft"
              ? draft.triggerWifiSSID
              : null,
          lateNightStartHour: draft.lateNightStartHour,
          lateNightEndHour: draft.lateNightEndHour,
          calendarLeadMinutes: draft.calendarLeadMinutes,
          scheduledTime,
          sensorCondition: sensorCond,
        },
        conditions: createAutomationConditions(wifiCond),
      });
      ruleStore.save([...ruleStore.load(), created]);
      draft.selectedDeviceIds.clear();
      host.replyBanner = {
        text: uiText(
          lang,
          "已保存自动化规则：{summary}",
          "已儲存自動化規則：{summary}",
          "Saved automation rule: {summary}",
          {
            summary: summarizeAutomationAction(created.action, aliasedDevices, host.scenes, lang),
          },
        ),
        source: uiText(lang, "状态感知自动化", "狀態感知自動化", "Context Automation"),
      };
      host.render();
    }
  });

  host.root.querySelector("#settings-safety-guard-section")?.addEventListener("change", (event) => {
    const target = event.target;
    if (!isInputEl(target) || target.closest("[data-exit-ghost]")) return;
    const patch: Partial<SafetyGuardPreferences> =
      target.id === "settings-safety-master"
        ? { enableSafetyAlerts: target.checked }
        : target.id === "settings-safety-plug"
          ? { longRunningPlug: target.checked }
          : target.id === "settings-safety-climate"
            ? { longRunningClimate: target.checked }
            : target.id === "settings-safety-offline"
              ? { favoriteOffline: target.checked }
              : target.id === "settings-safety-low-battery"
                ? { lowBattery: target.checked }
                : {};
    if (Object.keys(patch).length === 0) return;
    const saved = saveSafetyGuardPrefs(patch, storage);
    if (center) pruneDisabledSafetyAlertsFromCenter(center, aliasedDevices, saved);
    host.render();
  });

  host.root.querySelector("#settings-sensor-alerts-section")?.addEventListener("change", (event) => {
    const target = event.target;
    if (!isInputEl(target) || target.closest("[data-exit-ghost]")) return;
    const current = loadSensorAlertPolicy(storage);
    const kindAttr = target.dataset.sensorAlertKind as SensorAlertKind | undefined;
    if (kindAttr && SENSOR_ALERT_KINDS.includes(kindAttr)) {
      saveSensorAlertPolicy(
        { enabled: { ...current.enabled, [kindAttr]: target.checked }, onlyWhenAway: current.onlyWhenAway },
        storage,
      );
      host.render();
    } else if (target.id === "settings-sensor-only-away") {
      saveSensorAlertPolicy({ enabled: current.enabled, onlyWhenAway: target.checked }, storage);
      host.render();
    }
  });

  host.root.querySelector("#settings-doorbell-section")?.addEventListener("change", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target || target.closest("[data-exit-ghost]")) return;
    if (isInputEl(target) && target.id === "settings-doorbell-auto-popup") {
      saveSafetyGuardPrefs({ doorbellAutoPopup: target.checked }, storage);
      host.render();
    } else if (isInputEl(target) && target.id === "settings-doorbell-chime") {
      saveSafetyGuardPrefs({ doorbellChime: target.checked }, storage);
      host.render();
    } else if (isSelectEl(target) && target.id === "settings-doorbell-seconds") {
      saveSafetyGuardPrefs({ doorbellPopupSeconds: clampDoorbellPopupSeconds(Number(target.value)) }, storage);
      host.render();
    }
  });

  const weeklySection = host.root.querySelector<HTMLElement>("#settings-weekly-report-section");
  weeklySection?.addEventListener("change", (event) => {
    const target = event.target;
    if (isInputEl(target) && !target.closest("[data-exit-ghost]") && target.id === "settings-weekly-report-enabled") {
      const saved = saveSafetyGuardPrefs({ enableWeeklyHealthReport: target.checked }, storage);
      if (!saved.enableWeeklyHealthReport && center) center.weeklyReportCard = null;
      host.render();
    }
  });
  weeklySection?.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLButtonElement>("button");
    if (!btn || btn.closest("[data-exit-ghost]")) return;
    if (btn.id === "btn-generate-copy-health-report") void generateAndCopyWeeklyHealthMarkdown(host);
    else if (btn.id === "btn-clear-health-report-preview") {
      session.healthReportPreviewMarkdown = null;
      host.render();
    }
  });
}
