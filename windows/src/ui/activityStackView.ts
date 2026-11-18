import {
  AutomationEngine,
  type AutomationRule,
  DoorbellCameraCoordinator,
  DoorbellDetector,
  getAutomationUndoRunId,
  wifiDispatchDecisionForObservation,
  wifiPollObservationFromProbe,
  type DoorbellCoordinatorScheduler,
  type DoorbellResponse,
  type DoorbellRing,
  type EngineWifiReading,
  type HASnapshotLike,
  type RecordedAutomationRun,
  type SystemContextEvent,
  type WindowsWifiProbeResult,
  type WindowsWifiProbeState,
} from "../core/automationEngine.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { speechLocale, t } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import {
  OfflineHistory,
  SafetyMonitor,
  WeeklyHealthReportSchedule,
  buildWeeklyHealthReport,
  defaultSafetyStorage,
  loadSensorAlertPolicy,
  renderWeeklyHealthMarkdown,
  tr3,
  weeklyHealthNotificationSummary,
  type HealthClimateRange,
  type HealthEnergyDayTotal,
  type HealthEnergyDeviceTotal,
  type KeyValueStorageLike,
  type RecordedSafetyAlert,
  type SafetyAlert,
  type SensorAlertPolicy,
  type SensorObservation,
  type WeeklyHealthReport,
} from "../core/safetyAndHealth.js";
import { ManualControlPolicy } from "../core/assistant.js";
import { isSwitchMarkedAsLight } from "../core/switchLightMarks.js";
import { getScopedEnergyHistory } from "../core/energyHistory.js";
import { resolveSensorHistoryScope, sharedSensorHistoryStore } from "../core/sensorHistory.js";
import { isDeviceActiveOn, type DeviceCommand, type FacetControl, type SmartDevice } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { ReplyBannerState } from "./appTypes.js";
import { SF_ICONS } from "./appConstants.js";
import { filterSafetyAlertsByGuardPrefs, loadSafetyGuardPrefs } from "./automationSettingsView.js";
import { getHostDualSourceState, getHostMiAccountsState, isDualSourceEnabled } from "./cloudRefresh.js";
import { energyScopeForHost } from "./energySettingsView.js";
import { withAliases } from "./panelPrefs.js";
import {
  isUndoHoverPaused,
  recordUndoKindSnapshots,
  rejectIfControlBlockedWhileLocked,
} from "./speechGuard.js";
import { proactiveSignature, renderProactiveInlinePill } from "./proactive.js";
import { cancelScheduledCommands } from "./scheduledCommands.js";
import { isWorkstationLocked } from "./transport.js";
import {
  SYSTEM_CONTEXT_POLL_INTERVAL_MS,
  planSystemSignalTransition,
  readNativeSystemSignals,
  resolveSystemSignalBaseline,
  triggerUsesSystemSignal,
  type SystemSignalBaseline,
} from "./systemContextPoll.js";
import { computeUndoAvailability, undoTrackerFor } from "./undoTracker.js";

export const MAX_RECENT_SAFETY_ALERTS = 10;
export const MAX_RECENT_AUTOMATION_RUNS = 10;

export interface DesktopNotificationRecord {
  readonly id: string;
  readonly title: string;
  readonly body: string;
  readonly channel: "tauri" | "web" | "panel-only";
  readonly timestampMs: number;
}

export interface WeeklyReportNoticeCard {
  readonly id: string;
  readonly slotMs: number;
  readonly scope: string;
  readonly summary: string;
  readonly report: WeeklyHealthReport;
  readonly createdAtMs: number;
}

export interface ActivityFeedItem {
  readonly id: string;
  readonly kind: "miExpiry" | "weeklyReport" | "safety" | "doorbell" | "automation";
  readonly badge: string;
  readonly title: string;
  readonly subtitle: string;
  readonly tone: "warning" | "danger" | "accent" | "neutral";
  readonly actionLabel?: string;
  readonly actionAttr?: string;
  readonly actionValue?: string;
  readonly actionElementId?: string;
  readonly isMiExpiryNotice?: boolean;
}

export interface HostActivityCenter {
  readonly storage: KeyValueStorageLike;
  scopeKey: string;
  lastSourceRevision: number;
  hasObservedNonEmptyDevices: boolean;
  isExpanded: boolean;
  recentSafetyAlerts: RecordedSafetyAlert[];
  recentAutomationRuns: RecordedAutomationRun[];
  weeklyReportCard: WeeklyReportNoticeCard | null;
  readonly dismissedActivityIds: Set<string>;
  readonly dispatchedNotifications: DesktopNotificationRecord[];
  readonly safetyMonitor: SafetyMonitor;
  readonly offlineHistory: OfflineHistory;
  readonly automationEngine: AutomationEngine;
  readonly doorbellDetector: DoorbellDetector;
  doorbellCoordinator: DoorbellCameraCoordinator;
  sensorPolicyOverride: SensorAlertPolicy | null;
  observationsOverride: Readonly<Record<string, readonly SensorObservation[]>> | null;
  lastEvaluatedAtMs: number;
  lockPollInFlight: boolean;
  lastSampledLockState: boolean | null;
  systemSignalBaseline: SystemSignalBaseline | null;
  lastSystemPollAtMs: number;
  systemPollInFlight: boolean;
  /** `lastSampledLockState` 每次值翻转递增：用于作废在探针/规则执行期间被后续
   * 翻转超越的锁屏回调（布尔值检查区分不了「解锁又上锁」的两次翻转）。 */
  lockSampleGeneration: number;
  lastClipboardMarkdown: string | null;
  pendingHighRiskUndoRunId?: string | null;
  dismissedProactiveSignature?: string | null;
  /** Wi-Fi 轮询（约 10 秒一次）：最近一次派发的确定读数与探针状态。 */
  wifiPollInFlight: boolean;
  lastWifiPollAtMs: number;
  lastWifiReading: EngineWifiReading | null;
  lastWifiProbeState: WindowsWifiProbeState | null;
  /**
   * 探针发起序号与最近一次已应用探针的序号：锁屏实时探针与周期轮询可能并发，
   * 只应用「发起序号更新」的结果，避免先发起、后返回的旧读数覆盖新读数并制造
   * 假的 joined/left 转换。
   */
  wifiProbeSeq: number;
  wifiAppliedSeq: number;
}

type HostWithActivity = MenuMijiaWindowsApp & {
  activityCenter?: HostActivityCenter | null;
  activityWindowLifecycleBound?: boolean;
};

export function isFullPanelHost(host: unknown): host is MenuMijiaWindowsApp {
  if (!host || typeof host !== "object") return false;
  const candidate = host as Partial<MenuMijiaWindowsApp>;
  return (
    Array.isArray(candidate.devices) &&
    candidate.settings !== undefined &&
    typeof candidate.settings === "object" &&
    typeof candidate.queueBackgroundRender === "function"
  );
}

function aliasedHostDevices(host: MenuMijiaWindowsApp): SmartDevice[] {
  const prefs = host.layout ?? host.settings?.layout;
  const base = prefs ? withAliases(prefs, host.devices) : [...host.devices];
  const staleIds = getHostMiAccountsState(host)?.merged?.staleDeviceIds;
  if (!staleIds || staleIds.size === 0) return base;
  const dualRoutes = isDualSourceEnabled(host) ? getHostDualSourceState(host)?.routes : undefined;
  return base.map((dev) => {
    if (dev.telemetryStale) return dev;
    const route = dualRoutes?.[dev.id];
    const backend = route?.backend ?? dev.sourceBackend;
    if (backend === "homeAssistant") return dev;
    const miId = backend === "xiaomiCloud" ? (route?.sourceDeviceId ?? dev.id) : dev.id;
    return staleIds.has(miId) ? { ...dev, telemetryStale: true } : dev;
  });
}

function deviceTelemetrySignature(devices: readonly SmartDevice[]): string {
  return devices
    .map((d) => `${d.id}:${d.isOnline ? 1 : 0}:${d.kind.kind === "plug" ? (d.kind.powerWatts ?? "") : ""}`)
    .join("|");
}

function isLiveSnapshotReadyForTelemetry(host: MenuMijiaWindowsApp): boolean {
  const mode = host.settings.connectionMode;
  if (mode === "demo" || host.devices.length === 0) return false;
  if (host.valuesAreStale) return false;
  if (mode === "homeAssistant" && Boolean(host.haConnectionError)) return false;
  if (mode === "xiaomiCloud" && Boolean(host.miSessionExpired)) return false;

  const hostWithTimer = host as MenuMijiaWindowsApp & {
    readonly timerSnapshot?: { readonly sourceRevision?: number };
  };
  if ((hostWithTimer.timerSnapshot?.sourceRevision ?? -1) !== (host.sourceRevision ?? 0)) {
    const cached =
      mode === "xiaomiCloud"
        ? host.settings.cachedXiaomiDevices
        : host.settings.cachedHAHome?.home?.devices;
    if (
      Array.isArray(cached) &&
      cached.length > 0 &&
      deviceTelemetrySignature(cached) === deviceTelemetrySignature(host.devices)
    ) {
      return false;
    }
  }
  return true;
}

export function computeActivityScopeKey(
  host: {
    readonly settings: MenuMijiaWindowsApp["settings"];
    readonly miAccountsOverride?: MenuMijiaWindowsApp["miAccountsOverride"] | undefined;
    readonly multiAccountState?: MenuMijiaWindowsApp["multiAccountState"] | undefined;
    readonly dualSourceEnabledOverride?: boolean | null | undefined;
  },
): string {
  const s = host.settings;
  const mode = s.connectionMode;
  if (mode === "demo") {
    return `demo:${s.selectedHomeId ?? "all"}`;
  }
  const fullHost = host as MenuMijiaWindowsApp;
  const accounts = host.miAccountsOverride ?? getHostMiAccountsState(fullHost)?.accounts ?? [];
  const accountIds = accounts.map((a) => a.id.trim()).filter(Boolean);
  const multiSuffix = accountIds.length > 1 ? `:${accountIds.join("+")}` : "";
  const userId = s.miSession?.userId ?? (accountIds[0] ?? "signed-out");
  const region = normalizeMiCloudRegion(s.miSession?.region ?? s.miCloudRegion ?? "cn");
  const homeId = s.selectedHomeId ?? "all";
  const miKey = `mi:${userId}:${region}:${homeId}${multiSuffix}`;
  const haKey = `ha:${homeAssistantIdentity(s.haBaseURL ?? "", s.haToken ?? "") ?? "unconfigured"}`;
  if (isDualSourceEnabled(fullHost)) {
    return `dual:${miKey}|${haKey}`;
  }
  if (mode === "xiaomiCloud") {
    return miKey;
  }
  if (mode === "homeAssistant") {
    return haKey;
  }
  return `demo:${s.selectedHomeId ?? "all"}`;
}

function createHostActivityCenter(
  host: MenuMijiaWindowsApp,
  storage: KeyValueStorageLike = defaultSafetyStorage(),
  doorbellScheduler?: DoorbellCoordinatorScheduler,
): HostActivityCenter {
  const scopeKey = computeActivityScopeKey(host);
  return {
    storage,
    scopeKey,
    lastSourceRevision: host.sourceRevision ?? 0,
    hasObservedNonEmptyDevices: host.devices.length > 0,
    isExpanded: false,
    recentSafetyAlerts: [],
    recentAutomationRuns: [],
    weeklyReportCard: null,
    dismissedActivityIds: new Set<string>(),
    dispatchedNotifications: [],
    safetyMonitor: new SafetyMonitor(storage, scopeKey),
    offlineHistory: new OfflineHistory(storage),
    automationEngine: new AutomationEngine(storage),
    doorbellDetector: new DoorbellDetector(),
    doorbellCoordinator: new DoorbellCameraCoordinator(doorbellScheduler),
    sensorPolicyOverride: null,
    observationsOverride: null,
    lastEvaluatedAtMs: 0,
    lockPollInFlight: false,
    lastSampledLockState: null,
    systemSignalBaseline: null,
    lastSystemPollAtMs: 0,
    systemPollInFlight: false,
    lockSampleGeneration: 0,
    lastClipboardMarkdown: null,
    pendingHighRiskUndoRunId: null,
    dismissedProactiveSignature: null,
    wifiPollInFlight: false,
    lastWifiPollAtMs: 0,
    lastWifiReading: null,
    lastWifiProbeState: null,
    wifiProbeSeq: 0,
    wifiAppliedSeq: 0,
  };
}

export function getHostActivityCenter(
  host: MenuMijiaWindowsApp,
  options?: {
    readonly storage?: KeyValueStorageLike;
    readonly doorbellScheduler?: DoorbellCoordinatorScheduler;
  },
): HostActivityCenter {
  const hostWithActivity = host as HostWithActivity;
  let center = hostWithActivity.activityCenter ?? undefined;
  if (!center) {
    center = createHostActivityCenter(host, options?.storage, options?.doorbellScheduler);
    hostWithActivity.activityCenter = center;
    return center;
  }
  if (options?.doorbellScheduler) {
    center.doorbellCoordinator = new DoorbellCameraCoordinator(options.doorbellScheduler);
  }
  syncSingleOwnerLifecycle(host, center);
  return center;
}

export function syncSingleOwnerLifecycle(
  host: MenuMijiaWindowsApp,
  center = (host as HostWithActivity).activityCenter ?? undefined,
): boolean {
  if (!center) return false;
  const currentScope = computeActivityScopeKey(host);
  const currentRev = host.sourceRevision ?? 0;
  if (center.scopeKey === currentScope && center.lastSourceRevision === currentRev) {
    return false;
  }

  center.scopeKey = currentScope;
  center.lastSourceRevision = currentRev;
  center.hasObservedNonEmptyDevices = host.devices.length > 0;
  clearCenterActivities(center);
  return true;
}

function clearCenterActivities(center: HostActivityCenter): void {
  center.isExpanded = false;
  center.recentSafetyAlerts = [];
  center.recentAutomationRuns = [];
  center.weeklyReportCard = null;
  center.dismissedActivityIds.clear();
  center.doorbellCoordinator.clearAll();
  center.doorbellDetector.reset();
  center.safetyMonitor.resetSessionState(center.scopeKey);
  center.automationEngine.resetTransientState();
  center.lastSampledLockState = null;
  // A backend switch re-primes both sampled signals so the new scope's first sample never
  // looks like a power or display transition.
  center.systemSignalBaseline = null;
  center.lastSystemPollAtMs = 0;
  // 会话/家庭切换即作废在途的锁屏回调：代际递增后，任何挂起中的旧回调
  // 都不得对新会话派发过时的 lockChanged。
  center.lockSampleGeneration += 1;
  center.pendingHighRiskUndoRunId = null;
  center.dismissedProactiveSignature = null;
}

export function clearHostActivitiesOnSignOut(host: unknown): void {
  if (!isFullPanelHost(host)) return;
  const center = (host as HostWithActivity).activityCenter;
  if (!center) return;
  center.safetyMonitor.resetSessionState();
  center.scopeKey = computeActivityScopeKey(host);
  center.lastSourceRevision = host.sourceRevision ?? 0;
  center.hasObservedNonEmptyDevices = false;
  center.offlineHistory.clear();
  clearCenterActivities(center);
}

export function collapseActivityStackOnHide(host: unknown): boolean {
  if (!isFullPanelHost(host)) return false;
  const center = (host as HostWithActivity).activityCenter;
  if (!center) return false;
  center.pendingHighRiskUndoRunId = null;
  if (!center.isExpanded) return false;
  center.isExpanded = false;
  return true;
}

export function pruneOrphanedDeviceActivities(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
): boolean {
  const center = getHostActivityCenter(host);
  let changed = false;

  const validRuns = center.recentAutomationRuns.filter(
    (run) => run.scope === center.scopeKey && run.expiresAtMs > nowMs,
  );
  if (validRuns.length !== center.recentAutomationRuns.length) {
    center.recentAutomationRuns = validRuns;
    changed = true;
  }

  if (host.devices.length > 0) {
    center.hasObservedNonEmptyDevices = true;
  }
  if (!center.hasObservedNonEmptyDevices && host.devices.length === 0) {
    return changed;
  }

  const presentIds = new Set(host.devices.map((d) => d.id));
  const keptSafety: RecordedSafetyAlert[] = [];
  for (const entry of center.recentSafetyAlerts) {
    if (entry.scope !== center.scopeKey || !presentIds.has(entry.alert.deviceId)) {
      center.dismissedActivityIds.delete(`safety:${entry.alert.id}`);
      center.dismissedActivityIds.delete(entry.alert.id);
      changed = true;
    } else {
      keptSafety.push(entry);
    }
  }
  if (keptSafety.length !== center.recentSafetyAlerts.length) {
    center.recentSafetyAlerts = keptSafety;
  }

  for (const dismissedId of [...center.dismissedActivityIds]) {
    const raw = dismissedId.startsWith("safety:") ? dismissedId.slice(7) : dismissedId;
    if (raw.startsWith("longrun:") || raw.startsWith("battery:")) {
      const devId = raw.slice(raw.indexOf(":") + 1);
      if (!presentIds.has(devId)) {
        center.dismissedActivityIds.delete(dismissedId);
      }
    } else if (raw.startsWith("offline:")) {
      const rest = raw.slice("offline:".length);
      const lastColon = rest.lastIndexOf(":");
      const devId = lastColon > 0 ? rest.slice(0, lastColon) : rest;
      if (!presentIds.has(devId)) {
        center.dismissedActivityIds.delete(dismissedId);
      }
    }
  }

  if (center.doorbellCoordinator.pruneMissingDevices(presentIds)) {
    changed = true;
  }

  if (changed && buildActivityFeed(host, nowMs).length <= 1) {
    center.isExpanded = false;
  }
  return changed;
}

export async function dispatchDesktopNotification(
  host: MenuMijiaWindowsApp,
  payload: { readonly id: string; readonly title: string; readonly body: string },
  nowMs = Date.now(),
): Promise<DesktopNotificationRecord> {
  const center = getHostActivityCenter(host);
  let channel: DesktopNotificationRecord["channel"] = "panel-only";

  try {
    const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
    if (typeof invoke === "function") {
      try {
        await invoke("send_desktop_notification", {
          title: payload.title,
          body: payload.body,
        });
        channel = "tauri";
      } catch {
        try {
          const granted = await invoke<boolean>("plugin:notification|is_permission_granted");
          if (granted) {
            await invoke("plugin:notification|notify", {
              options: { title: payload.title, body: payload.body },
            });
            channel = "tauri";
          }
        } catch {
        }
      }
    }

    if (channel === "panel-only" && typeof globalThis.Notification === "function") {
      let permission = globalThis.Notification.permission;
      if (permission === "default" && typeof globalThis.Notification.requestPermission === "function") {
        try {
          permission = await globalThis.Notification.requestPermission();
        } catch {
          permission = globalThis.Notification.permission;
        }
      }
      if (permission === "granted") {
        new globalThis.Notification(payload.title, {
          body: payload.body,
          silent: false,
        });
        channel = "web";
      }
    }
  } catch {
    channel = "panel-only";
  }

  const record: DesktopNotificationRecord = {
    id: payload.id,
    title: payload.title,
    body: payload.body,
    channel,
    timestampMs: nowMs,
  };
  center.dispatchedNotifications.unshift(record);
  if (center.dispatchedNotifications.length > 20) {
    center.dispatchedNotifications.length = 20;
  }
  return record;
}

export function recordSafetyAlerts(
  host: MenuMijiaWindowsApp,
  alerts: readonly SafetyAlert[],
  nowMs = Date.now(),
): boolean {
  if (alerts.length === 0) return false;
  const center = getHostActivityCenter(host);
  const scope = center.scopeKey;

  for (const alert of alerts) {
    center.dismissedActivityIds.delete(`safety:${alert.id}`);
    center.dismissedActivityIds.delete(alert.id);

    const entry: RecordedSafetyAlert = { alert, scope, dateMs: nowMs };
    center.recentSafetyAlerts = [
      entry,
      ...center.recentSafetyAlerts.filter((existing) => existing.alert.id !== alert.id),
    ].slice(0, MAX_RECENT_SAFETY_ALERTS);

    if (alert.priority === "high") {
      void dispatchDesktopNotification(
        host,
        { id: alert.id, title: alert.title, body: alert.body },
        nowMs,
      );
    }
  }
  return true;
}

function buildReportEnergyAndClimateInputs(
  host: MenuMijiaWindowsApp,
  aliased: readonly SmartDevice[],
  nowMs: number,
): {
  readonly dailyEnergy: readonly HealthEnergyDayTotal[];
  readonly energyByDevice: readonly HealthEnergyDeviceTotal[];
  readonly climate: Readonly<Record<string, HealthClimateRange>>;
} {
  const nowDate = new Date(nowMs);
  const energyHistory = getScopedEnergyHistory(energyScopeForHost(host));
  const dailyEnergy: HealthEnergyDayTotal[] = energyHistory
    .dailyTotals(14, nowDate)
    .map((day) => ({ kwh: day.kwh, isObserved: day.isObserved }));
  const energyByDevice: HealthEnergyDeviceTotal[] = energyHistory
    .deviceTotals(7, aliased, nowDate)
    .map((entry) => ({
      id: entry.deviceId,
      name: entry.roomName.trim() ? `${entry.roomName} · ${entry.name}` : entry.name,
      kwh: entry.kwh,
    }));

  const sensorStore = sharedSensorHistoryStore();
  const accounts = host.miAccountsOverride ?? getHostMiAccountsState(host)?.accounts ?? [];
  sensorStore.setConnectionScope(
    resolveSensorHistoryScope({
      connectionMode: host.settings.connectionMode,
      haBaseURL: host.settings.haBaseURL ?? "",
      miSession: host.settings.miSession ?? null,
      dualSourceEnabled: isDualSourceEnabled(host),
      activeAccountIds: accounts.map((a) => a.id),
    }),
  );
  const climate: Record<string, HealthClimateRange> = {};
  for (const dev of aliased) {
    const temp = sensorStore.summary(dev.id, "7d", "temperature", nowMs);
    const hum = sensorStore.summary(dev.id, "7d", "humidity", nowMs);
    if (temp || hum) {
      climate[dev.id] = {
        ...(temp ? { temperature: { min: temp.min, max: temp.max } } : {}),
        ...(hum ? { humidity: { min: hum.min, max: hum.max } } : {}),
      };
    }
  }
  return { dailyEnergy, energyByDevice, climate };
}

export function deliverWeeklyHealthReport(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
  options?: {
    readonly report?: WeeklyHealthReport;
    readonly storage?: KeyValueStorageLike;
  },
): WeeklyReportNoticeCard {
  const center = getHostActivityCenter(host, { storage: options?.storage });
  const slotMs = WeeklyHealthReportSchedule.latestSlotMs(nowMs);
  const aliased = aliasedHostDevices(host);
  const inputs = options?.report ? null : buildReportEnergyAndClimateInputs(host, aliased, nowMs);
  const report =
    options?.report ??
    buildWeeklyHealthReport({
      devices: aliased,
      dailyEnergy: inputs?.dailyEnergy,
      energyByDevice: inputs?.energyByDevice,
      climate: inputs?.climate,
      offlineHistory: center.offlineHistory,
      nowMs,
    });
  const summary = weeklyHealthNotificationSummary(report, host.settings.interfaceLanguage);
  const id = `notice:weeklyHealth:${slotMs}`;
  center.dismissedActivityIds.delete(id);
  const card: WeeklyReportNoticeCard = {
    id,
    slotMs,
    scope: center.scopeKey,
    summary,
    report,
    createdAtMs: nowMs,
  };
  center.weeklyReportCard = card;
  WeeklyHealthReportSchedule.markDelivered(nowMs, options?.storage ?? center.storage);
  return card;
}

export async function copyWeeklyHealthMarkdown(host: MenuMijiaWindowsApp, nowMs = Date.now()): Promise<string> {
  const center = getHostActivityCenter(host);
  const aliased = aliasedHostDevices(host);
  const inputs = center.weeklyReportCard?.report
    ? null
    : buildReportEnergyAndClimateInputs(host, aliased, nowMs);
  const report =
    center.weeklyReportCard?.report ??
    buildWeeklyHealthReport({
      devices: aliased,
      dailyEnergy: inputs?.dailyEnergy,
      energyByDevice: inputs?.energyByDevice,
      climate: inputs?.climate,
      offlineHistory: center.offlineHistory,
      nowMs,
    });
  const markdown = renderWeeklyHealthMarkdown(report, host.settings.interfaceLanguage);
  center.lastClipboardMarkdown = markdown;

  try {
    if (typeof globalThis.navigator?.clipboard?.writeText === "function") {
      await globalThis.navigator.clipboard?.writeText(markdown);
    }
  } catch {
  }

  host.replyBanner = {
    text: tr3(
      "已复制家庭健康周报 Markdown",
      "已複製家庭健康週報 Markdown",
      "Copied Weekly Home Health Report Markdown",
      undefined,
      host.settings.interfaceLanguage,
    ),
    source: tr3("健康周报", "健康週報", "Health Report", undefined, host.settings.interfaceLanguage),
  };
  host.render();
  return markdown;
}

export async function executeSafetyTurnOffAction(
  host: MenuMijiaWindowsApp,
  alertId: string,
): Promise<boolean> {
  if (await rejectIfControlBlockedWhileLocked(host)) {
    return false;
  }

  const center = getHostActivityCenter(host);
  const recorded = center.recentSafetyAlerts.find((r) => r.alert.id === alertId);
  const pref = host.settings.interfaceLanguage;
  if (!recorded || !recorded.alert.turnOffCommand) {
    return false;
  }

  const currentScope = computeActivityScopeKey(host);
  const aliased = aliasedHostDevices(host);
  const targetDevice = aliased.find((d) => d.id === recorded.alert.deviceId);
  if (recorded.scope !== currentScope || !targetDevice) {
    center.recentSafetyAlerts = center.recentSafetyAlerts.filter((r) => r.alert.id !== alertId);
    center.dismissedActivityIds.delete(`safety:${alertId}`);
    host.replyBanner = {
      text: tr3(
        "该提醒已不适用于当前家居，未关闭设备",
        "該提醒已不適用於目前家居，未關閉設備",
        "This alert no longer applies to the current home; no device was turned off",
        undefined,
        pref,
      ),
      source: tr3("安全守护", "安全守護", "Safety Guard", undefined, pref),
      isError: true,
    };
    host.render();
    return false;
  }

  const ok = await host.applyCommand(recorded.alert.turnOffCommand);
  if (ok) {
    center.recentSafetyAlerts = center.recentSafetyAlerts.filter((r) => r.alert.id !== alertId);
    center.dismissedActivityIds.add(`safety:${alertId}`);
    if (buildActivityFeed(host).length <= 1) {
      center.isExpanded = false;
    }
    host.replyBanner = {
      text: tr3(
        "已关闭「{name}」",
        "已關閉「{name}」",
        "Turned off \"{name}\"",
        { name: targetDevice.name },
        pref,
      ),
      source: tr3("安全守护", "安全守護", "Safety Guard", undefined, pref),
    };
    host.render();
    return true;
  }

  host.render();
  return false;
}

/**
 * True when restoring `step` would escalate the hazard of its device. A facet row carries the
 * meaning of its own restore (an auxiliary switch turned back on, a mode restored away from off),
 * so it is judged by the same table the original tap used, mirroring macOS `confirmUndoTargets`.
 * A cover restore is judged by the direction it actually moves: a garage door returning to its
 * close word or to position 0 is as hazardous as one returning to open, while a curtain restore
 * and a window opener closing stay direct.
 */
export function doesUndoStepActivateHighRiskDevice(
  step: { readonly deviceId: string; readonly commands: readonly DeviceCommand[] },
  devices: readonly SmartDevice[],
  kindSnapshots?: ReadonlyMap<string, SmartDevice["kind"]>,
  facetsById?: Readonly<Record<string, readonly FacetControl[]>>,
): boolean {
  const dev = devices.find((d) => d.id === step.deviceId);
  if (!dev) return false;
  const facets = facetsById?.[dev.id] ?? [];
  if (step.commands.some((cmd) => facetRestoreNeedsConfirmation(dev, cmd, facets, devices))) return true;
  if (!ManualControlPolicy.requiresConfirmation({ targetId: dev.id, operation: { kind: "power", isOn: true } }, devices)) {
    return false;
  }
  const snapKind = kindSnapshots?.get(step.deviceId);
  if (snapKind && !isDeviceActiveOn(dev) && isDeviceActiveOn({ ...dev, kind: snapKind })) return true;
  const coverRestoreNeedsConfirmation = (restoredOpen: boolean): boolean =>
    ManualControlPolicy.requiresConfirmation(
      { targetId: dev.id, operation: { kind: "power", isOn: restoredOpen } },
      devices,
    );
  return step.commands.some((cmd) => {
    switch (cmd.kind) {
      case "setSwitch":
        if (dev.kind.kind === "plug" && dev.kind.childLockEntityId === cmd.entityId) return false;
        if (dev.kind.kind === "appliance" && dev.kind.light?.entityId === cmd.entityId) return false;
        return cmd.isOn;
      case "setClimatePower":
        return cmd.isOn;
      case "setClimateMode":
        return cmd.hvacMode.trim().toLowerCase() !== "off";
      case "setSelectOption":
        if (dev.kind.kind === "camera" || dev.kind.kind === "fridge") return false;
        if (dev.kind.kind === "cover") {
          return coverRestoreNeedsConfirmation(cmd.option === dev.kind.openDescription);
        }
        return cmd.option.trim().toLowerCase() !== "off";
      case "setNumberValue":
        return dev.kind.kind === "cover" && coverRestoreNeedsConfirmation(cmd.value > 0);
      case "vacuumAction":
        return cmd.action === "start";
      case "pressButton":
        return dev.kind.kind === "appliance" ? dev.kind.startAction?.entityId === cmd.entityId : true;
      case "setMiotProperty":
        // Backstop only: a matching facet row was judged above, so this catches the cover position
        // restore an older snapshot can carry without one. A high-risk card with no row at all is
        // already refused (or approved) by `facetRestoreNeedsConfirmation`; the direction rule is
        // the same as the position write above.
        return dev.kind.kind === "cover" && typeof cmd.value === "number" && coverRestoreNeedsConfirmation(cmd.value > 0);
      default:
        return false;
    }
  });
}

/** The hazard a facet restore carries, judged by the table the original write used. */
function facetRestoreNeedsConfirmation(
  dev: SmartDevice,
  cmd: DeviceCommand,
  facets: readonly FacetControl[],
  devices: readonly SmartDevice[],
): boolean {
  if (cmd.kind !== "setMiotProperty") return false;
  const control = facets.find(
    (item) =>
      item.target?.kind === "property" &&
      item.target.entityId === cmd.entityId &&
      item.target.piid === cmd.piid,
  );
  if (control) return ManualControlPolicy.facetRequiresConfirmation(control, cmd.value, dev);
  // No row explains this property: only the device-level hazard can speak.
  return ManualControlPolicy.requiresConfirmation({ targetId: dev.id, operation: { kind: "power", isOn: true } }, devices);
}

type HighRiskUndoRestoreDirection = "open" | "close" | "restore";

function classifyHighRiskUndoStepDirection(
  step: { readonly deviceId: string; readonly commands: readonly DeviceCommand[] },
  devices: readonly SmartDevice[],
  kindSnapshots?: ReadonlyMap<string, SmartDevice["kind"]>,
  facetsById?: Readonly<Record<string, readonly FacetControl[]>>,
): HighRiskUndoRestoreDirection {
  const dev = devices.find((d) => d.id === step.deviceId);
  if (!dev) return "restore";
  const facets = facetsById?.[dev.id] ?? [];
  const directions = new Set<HighRiskUndoRestoreDirection>();
  const coverRestoreNeedsConfirmation = (restoredOpen: boolean): boolean =>
    ManualControlPolicy.requiresConfirmation(
      { targetId: dev.id, operation: { kind: "power", isOn: restoredOpen } },
      devices,
    );

  for (const cmd of step.commands) {
    if (facetRestoreNeedsConfirmation(dev, cmd, facets, devices)) {
      if (cmd.kind === "setMiotProperty") {
        if (dev.kind.kind === "cover" && typeof cmd.value === "number") {
          directions.add(cmd.value > 0 ? "open" : "close");
          continue;
        }
        if (dev.kind.kind === "cover" && typeof cmd.value === "string") {
          const normalized = cmd.value.trim().toLowerCase();
          if (cmd.value === dev.kind.closeDescription || normalized === "close") {
            directions.add("close");
            continue;
          }
          if (cmd.value === dev.kind.openDescription || normalized === "open") {
            directions.add("open");
            continue;
          }
        }
        const control = facets.find(
          (item) =>
            item.target?.kind === "property" &&
            item.target.entityId === cmd.entityId &&
            item.target.piid === cmd.piid,
        );
        if (!control) {
          directions.add("open");
          continue;
        }
        if (
          cmd.value === false ||
          cmd.value === 0 ||
          (typeof cmd.value === "string" && cmd.value.trim().toLowerCase() === "off")
        ) {
          directions.add("close");
        } else if (cmd.value === true || cmd.value === 1) {
          directions.add("open");
        } else {
          directions.add("restore");
        }
      }
      continue;
    }
    switch (cmd.kind) {
      case "setSwitch":
        if (dev.kind.kind === "plug" && dev.kind.childLockEntityId === cmd.entityId) break;
        if (dev.kind.kind === "appliance" && dev.kind.light?.entityId === cmd.entityId) break;
        if (cmd.isOn) directions.add("open");
        break;
      case "setClimatePower":
        if (cmd.isOn) directions.add("open");
        break;
      case "setClimateMode":
        if (cmd.hvacMode.trim().toLowerCase() !== "off") directions.add("open");
        break;
      case "setSelectOption":
        if (dev.kind.kind === "camera" || dev.kind.kind === "fridge") break;
        if (dev.kind.kind === "cover") {
          const restoredOpen = cmd.option === dev.kind.openDescription;
          if (coverRestoreNeedsConfirmation(restoredOpen)) {
            if (cmd.option === dev.kind.closeDescription) {
              directions.add("close");
            } else if (restoredOpen) {
              directions.add("open");
            } else {
              directions.add("restore");
            }
          }
          break;
        }
        if (cmd.option.trim().toLowerCase() !== "off") directions.add("open");
        break;
      case "setNumberValue":
        if (dev.kind.kind === "cover" && coverRestoreNeedsConfirmation(cmd.value > 0)) {
          directions.add(cmd.value > 0 ? "open" : "close");
        }
        break;
      case "vacuumAction":
        if (cmd.action === "start") directions.add("open");
        break;
      case "pressButton":
        if (dev.kind.kind === "appliance" ? dev.kind.startAction?.entityId === cmd.entityId : true) {
          directions.add("open");
        }
        break;
      case "setMiotProperty":
        if (dev.kind.kind === "cover" && typeof cmd.value === "number" && coverRestoreNeedsConfirmation(cmd.value > 0)) {
          directions.add(cmd.value > 0 ? "open" : "close");
        }
        break;
    }
  }

  const snapKind = kindSnapshots?.get(step.deviceId);
  if (directions.size === 0 && snapKind && !isDeviceActiveOn(dev) && isDeviceActiveOn({ ...dev, kind: snapKind })) {
    directions.add("open");
  }
  return mergeHighRiskUndoDirections(directions);
}

function mergeHighRiskUndoDirections(
  directions: Iterable<HighRiskUndoRestoreDirection>,
): HighRiskUndoRestoreDirection {
  const unique = new Set(directions);
  if (unique.size === 1) {
    return [...unique][0]!;
  }
  return "restore";
}

export function partitionUndoStepsByHighRiskConfirmation<
  T extends { readonly deviceId: string; readonly commands: readonly DeviceCommand[] },
>(
  host: MenuMijiaWindowsApp,
  steps: readonly T[],
  options: { readonly kindSnapshots?: ReadonlyMap<string, SmartDevice["kind"]>; readonly isArmed: boolean; readonly arm: () => void; readonly disarm: () => void },
): { readonly approvedSteps: T[]; readonly skippedHighRiskSteps: T[]; readonly abortedAllHighRisk: boolean; readonly armedPromptText?: string } {
  const aliased = aliasedHostDevices(host);
  const pref = host.settings.interfaceLanguage;
  const highRiskSet = new Set(
    steps.filter((s) =>
      doesUndoStepActivateHighRiskDevice(s, aliased, options.kindSnapshots, host.deviceFacets),
    ),
  );
  if (highRiskSet.size === 0 || (typeof host.manualControlConfirmationHandler !== "function" && options.isArmed)) {
    options.disarm();
    return { approvedSteps: [...steps], skippedHighRiskSteps: [], abortedAllHighRisk: false };
  }
  const directionForDevice = (deviceId: string): HighRiskUndoRestoreDirection =>
    mergeHighRiskUndoDirections(
      steps
        .filter((s) => s.deviceId === deviceId && highRiskSet.has(s))
        .map((s) => classifyHighRiskUndoStepDirection(s, aliased, options.kindSnapshots, host.deviceFacets)),
    );
  const handler = host.manualControlConfirmationHandler;
  if (typeof handler === "function") {
    options.disarm();
    const decisions = new Map<string, boolean>();
    const approvedSteps: T[] = [];
    const skippedHighRiskSteps: T[] = [];
    const declinedNames: string[] = [];
    for (const step of steps) {
      if (!highRiskSet.has(step)) {
        approvedSteps.push(step);
        continue;
      }
      let allowed = decisions.get(step.deviceId);
      if (allowed === undefined) {
        const name = aliased.find((d) => d.id === step.deviceId)?.name ?? step.deviceId;
        const direction = directionForDevice(step.deviceId);
        const prompt =
          direction === "close"
            ? {
                title: tr3("确定要恢复关闭「{name}」吗？", "確定要恢復關閉「{name}」嗎？", 'Restore "{name}" to closed?', { name }, pref),
                message: tr3("撤销操作将关闭高风险设备「{name}」，请确认现场安全。", "撤銷操作將關閉高風險設備「{name}」，請確認現場安全。", 'Undoing will close high-risk device "{name}". Please confirm it is safe.', { name }, pref),
                confirmTitle: tr3("恢复关闭", "恢復關閉", "Restore Closed", undefined, pref),
                cancelTitle: tr3("跳过", "跳過", "Skip", undefined, pref),
              }
            : direction === "open"
              ? {
                  title: tr3("确定要恢复开启「{name}」吗？", "確定要恢復開啟「{name}」嗎？", 'Restore "{name}" to ON?', { name }, pref),
                  message: tr3("撤销操作将重新开启高风险设备「{name}」，请确认现场安全。", "撤銷操作將重新開啟高風險設備「{name}」，請確認現場安全。", 'Undoing will turn high-risk device "{name}" back on. Please confirm it is safe.', { name }, pref),
                  confirmTitle: tr3("恢复开启", "恢復開啟", "Restore ON", undefined, pref),
                  cancelTitle: tr3("跳过", "跳過", "Skip", undefined, pref),
                }
              : {
                  title: tr3("确定要恢复「{name}」之前的状态吗？", "確定要恢復「{name}」之前的狀態嗎？", 'Restore "{name}" to its previous state?', { name }, pref),
                  message: tr3("撤销操作将恢复高风险设备「{name}」之前的状态，请确认现场安全。", "撤銷操作將恢復高風險設備「{name}」之前的狀態，請確認現場安全。", 'Undoing will restore high-risk device "{name}" to its previous state. Please confirm it is safe.', { name }, pref),
                  confirmTitle: tr3("确认恢复", "確認恢復", "Confirm Restore", undefined, pref),
                  cancelTitle: tr3("跳过", "跳過", "Skip", undefined, pref),
                };
        allowed = handler(prompt);
        decisions.set(step.deviceId, allowed);
        if (!allowed) declinedNames.push(name);
      }
      (allowed ? approvedSteps : skippedHighRiskSteps).push(step);
    }
    const names = declinedNames.join(pref === "en" ? ", " : "、");
    return {
      approvedSteps,
      skippedHighRiskSteps,
      abortedAllHighRisk: approvedSteps.length === 0,
      ...(declinedNames.length > 0 ? { armedPromptText: tr3("已取消恢复高风险设备「{names}」", "已取消恢復高風險設備「{names}」", 'Skipped restoring high-risk device "{names}"', { names }, pref) } : {}),
    };
  }
  options.arm();
  const seenIds = new Set<string>();
  const highRiskNames: string[] = [];
  const highRiskDirections: HighRiskUndoRestoreDirection[] = [];
  for (const step of steps) {
    if (!highRiskSet.has(step) || seenIds.has(step.deviceId)) continue;
    seenIds.add(step.deviceId);
    highRiskNames.push(aliased.find((d) => d.id === step.deviceId)?.name ?? step.deviceId);
    highRiskDirections.push(directionForDevice(step.deviceId));
  }
  const names = highRiskNames.join(pref === "en" ? ", " : "、");
  const batchDirection = mergeHighRiskUndoDirections(highRiskDirections);
  const armedPromptText =
    batchDirection === "close"
      ? tr3("撤销将关闭高风险设备「{names}」，再点一次「撤销」确认执行", "撤銷將關閉高風險設備「{names}」，再點一次「撤銷」確認執行", 'Undo will close high-risk device "{names}"; click Undo again to confirm', { names }, pref)
      : batchDirection === "open"
        ? tr3("撤销将重新开启高风险设备「{names}」，再点一次「撤销」确认执行", "撤銷將重新開啟高風險設備「{names}」，再點一次「撤銷」確認執行", 'Undo will turn high-risk device "{names}" back on; click Undo again to confirm', { names }, pref)
        : tr3("撤销将恢复高风险设备「{names}」之前的状态，再点一次「撤销」确认执行", "撤銷將恢復高風險設備「{names}」之前的狀態，再點一次「撤銷」確認執行", 'Undo will restore high-risk device "{names}" to its previous state; click Undo again to confirm', { names }, pref);
  const approvedSteps = steps.filter((s) => !highRiskSet.has(s));
  const skippedHighRiskSteps = steps.filter((s) => highRiskSet.has(s));
  return { approvedSteps, skippedHighRiskSteps, abortedAllHighRisk: approvedSteps.length === 0, armedPromptText };
}

export async function executeAutomationCardUndo(
  host: MenuMijiaWindowsApp,
  runId: string,
  nowMs = Date.now(),
): Promise<boolean> {
  if (await rejectIfControlBlockedWhileLocked(host)) return false;

  const center = getHostActivityCenter(host);
  const pref = host.settings.interfaceLanguage;
  const run = center.recentAutomationRuns.find((r) => r.id === runId);
  if (!run) return false;

  const startingRevision = host.sourceRevision ?? 0;
  const startingScope = computeActivityScopeKey(host);
  if (run.scope !== startingScope || run.expiresAtMs <= nowMs) {
    center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
    if (center.pendingHighRiskUndoRunId === runId) center.pendingHighRiskUndoRunId = null;
    host.replyBanner = {
      text: tr3("撤销窗口已过期或家庭已切换", "撤銷視窗已過期或家庭已切換", "Undo window expired or home changed", undefined, pref),
      source: tr3("状态感知自动化", "狀態感知自動化", "Context Automation", undefined, pref),
      isError: true,
    };
    host.render();
    return false;
  }

  const confirmation = partitionUndoStepsByHighRiskConfirmation(host, run.steps, {
    kindSnapshots: run.kindSnapshots,
    isArmed: center.pendingHighRiskUndoRunId === runId,
    arm: () => { center.pendingHighRiskUndoRunId = runId; },
    disarm: () => { if (center.pendingHighRiskUndoRunId === runId) center.pendingHighRiskUndoRunId = null; },
  });
  if (confirmation.abortedAllHighRisk) {
    host.replyBanner = {
      text: confirmation.armedPromptText ?? tr3("需要确认后才能恢复高风险设备", "需要確認後才能恢復高風險設備", "Confirm before restoring high-risk devices", undefined, pref),
      source: tr3("需要确认", "需要確認", "Confirmation Required", undefined, pref),
    };
    host.render();
    return false;
  }

  const isUndoContextValid = (): boolean =>
    (host.sourceRevision ?? 0) === startingRevision &&
    computeActivityScopeKey(host) === startingScope &&
    getHostActivityCenter(host) === center &&
    center.recentAutomationRuns.some((r) => r.id === runId && r.scope === startingScope);

  let allOk = true;
  for (const step of [...confirmation.approvedSteps].reverse()) {
    if (!isUndoContextValid()) return false;
    if (!host.devices.some((d) => d.id === step.deviceId)) {
      allOk = false;
      continue;
    }
    for (const cmd of step.commands) {
      if (!isUndoContextValid()) return false;
      if (!host.devices.some((d) => d.id === step.deviceId)) {
        allOk = false;
        break;
      }
      const ok = await host.applyCommand(cmd, true);
      if (!isUndoContextValid()) return false;
      if (!ok) {
        allOk = false;
      } else {
        const dev = host.devices.find((d) => d.id === step.deviceId);
        const prevKind = run.kindSnapshots.get(step.deviceId);
        if (dev && prevKind) {
          dev.kind = structuredClone(prevKind);
        }
      }
    }
  }

  if (!isUndoContextValid()) return false;

  const hasPendingArmedRest =
    confirmation.skippedHighRiskSteps.length > 0 && center.pendingHighRiskUndoRunId === runId;
  if (hasPendingArmedRest) {
    center.recentAutomationRuns = center.recentAutomationRuns.map((r) =>
      r.id === runId ? { ...r, steps: confirmation.skippedHighRiskSteps } : r,
    );
    if (host.lastUndoAction && getAutomationUndoRunId(host.lastUndoAction) === runId) {
      const nextUndo = { ...host.lastUndoAction, steps: confirmation.skippedHighRiskSteps };
      recordUndoKindSnapshots(nextUndo, run.kindSnapshots);
      host.lastUndoAction = nextUndo;
    }
    host.replyBanner = {
      text: confirmation.armedPromptText ?? run.summary,
      source: tr3("需要确认", "需要確認", "Confirmation Required", undefined, pref),
    };
    host.render();
    return allOk;
  }

  center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
  if (host.lastUndoAction && getAutomationUndoRunId(host.lastUndoAction) === runId) {
    host.lastUndoAction = null;
  }
  if (buildActivityFeed(host, nowMs).length <= 1) {
    center.isExpanded = false;
  }
  host.replyBanner = {
    text: allOk
      ? tr3(
          "已撤销自动化操作：{summary}",
          "已撤銷自動化操作：{summary}",
          "Undid automation: {summary}",
          { summary: run.summary },
          pref,
        )
      : tr3(
          "部分设备撤销失败，请检查设备在线状态",
          "部分設備撤銷失敗，請檢查設備連線狀態",
          "Some devices failed to undo; please check connectivity",
          undefined,
          pref,
        ),
    source: tr3("状态感知自动化", "狀態感知自動化", "Context Automation", undefined, pref),
    ...(allOk ? {} : { isError: true }),
  };
  host.render();
  return allOk;
}

export function claimDoorbellWindowForUser(host: MenuMijiaWindowsApp): void {
  const center = getHostActivityCenter(host);
  center.doorbellCoordinator.claimDoorbellWindowForUser();
}

export async function ingestHostHASnapshotForDoorbell(
  host: MenuMijiaWindowsApp,
  snapshot: HASnapshotLike,
  options: {
    readonly nowMs?: number;
    readonly isLocked?: boolean;
    readonly autoPopup?: boolean;
    readonly popupSeconds?: number;
    readonly playChime?: boolean;
  } = {},
): Promise<DoorbellResponse[]> {
  const startingRevision = host.sourceRevision ?? 0;
  const startingScope = computeActivityScopeKey(host);
  const center = getHostActivityCenter(host);
  const aliased = aliasedHostDevices(host);
  const rings: DoorbellRing[] = center.doorbellDetector.ingestHASnapshot(snapshot, aliased);
  if (rings.length === 0) return [];

  const isLocked = options.isLocked ?? (await isWorkstationLocked());
  if (
    (host.sourceRevision ?? 0) !== startingRevision ||
    computeActivityScopeKey(host) !== startingScope ||
    (host as HostWithActivity).activityCenter !== center ||
    center.scopeKey !== startingScope ||
    center.lastSourceRevision !== startingRevision
  ) {
    syncSingleOwnerLifecycle(host);
    return [];
  }
  const nowMs = options.nowMs ?? Date.now();
  for (const ring of rings) {
    center.dismissedActivityIds.delete(`doorbell:${ring.key}`);
  }

  const guardPrefs = loadSafetyGuardPrefs(center.storage);
  const responses = center.doorbellCoordinator.handleRings({
    rings,
    devices: aliased,
    cameraLive: host.cameraLive,
    isLocked,
    scope: center.scopeKey,
    nowMs,
    autoPopup: options.autoPopup ?? guardPrefs.doorbellAutoPopup,
    popupSeconds: options.popupSeconds ?? guardPrefs.doorbellPopupSeconds,
    playChime: options.playChime ?? guardPrefs.doorbellChime,
  });

  for (const ring of rings) {
    const camName =
      aliased.find((d) => d.id === ring.deviceId)?.name ??
      tr3("门口门铃", "門口門鈴", "Doorbell", undefined, host.settings.interfaceLanguage);
    void dispatchDesktopNotification(
      host,
      {
        id: `doorbell:${ring.key}`,
        title: tr3(
          "{name} 有人按铃",
          "{name} 有人按鈴",
          "{name} Doorbell Rang",
          { name: camName },
          host.settings.interfaceLanguage,
        ),
        body: tr3(
          "点击面板查看门口实时画面",
          "點擊面板查看門口即時畫面",
          "Open the panel to view live doorway video",
          undefined,
          host.settings.interfaceLanguage,
        ),
      },
      nowMs,
    );
  }

  host.queueBackgroundRender();
  return responses;
}

export async function dispatchSystemContextEvent(
  host: MenuMijiaWindowsApp,
  event: SystemContextEvent,
  nowMs = Date.now(),
): Promise<RecordedAutomationRun[]> {
  const center = getHostActivityCenter(host);
  const runs = await center.automationEngine.dispatchEvent(host, event, {
    nowMs,
    scope: center.scopeKey,
    displayDevices: aliasedHostDevices(host),
    observationsByDeviceId: center.observationsOverride ?? undefined,
    recordUndoKindSnapshots,
    onUndoRecorded: (run) => {
      center.dismissedActivityIds.delete(`auto:${run.id}`);
      center.recentAutomationRuns = [
        run,
        ...center.recentAutomationRuns.filter((r) => r.id !== run.id),
      ].slice(0, MAX_RECENT_AUTOMATION_RUNS);
    },
  });
  return runs;
}

/**
 * Polls the two Windows signals that the native layer can only report by sampling — AC/battery
 * (`GetSystemPowerStatus`) and the external display count (`QueryDisplayConfig`) — and dispatches
 * an engine event when either actually changed. macOS runs the same shape from
 * `MacContextObserver` (10 s) into `MacContextAutomation`; sleep and display power are pushed from
 * `system_events.rs` instead, because a poll cannot observe them in time.
 *
 * The first sample only primes the engine (see `AutomationEngine.primePowerBaseline`), so booting
 * on battery never runs a "power disconnected" rule. Returns whether a rule actually ran.
 */
export async function pollSystemContextSignals(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
  /** The caller's enabled-rule snapshot; reusing it avoids a second rule-store parse per tick. */
  enabledRules?: readonly AutomationRule[],
): Promise<boolean> {
  if (typeof window === "undefined" || !window.__TAURI_INTERNALS__?.invoke) return false;
  const center = getHostActivityCenter(host);
  if (center.systemPollInFlight) return false;
  if (
    center.lastSystemPollAtMs > 0 &&
    nowMs - center.lastSystemPollAtMs < SYSTEM_CONTEXT_POLL_INTERVAL_MS
  ) {
    return false;
  }
  const rules = enabledRules ?? center.automationEngine.store.load().filter((r) => r.isEnabled);
  const needsPower = rules.some((r) => triggerUsesSystemSignal(r.trigger, "powerChanged"));
  const needsDisplay = rules.some((r) => triggerUsesSystemSignal(r.trigger, "externalDisplayChanged"));
  if (!needsPower && !needsDisplay) return false;

  center.lastSystemPollAtMs = nowMs;
  center.systemPollInFlight = true;
  try {
    const signals = await readNativeSystemSignals({
      power: needsPower,
      externalDisplayCount: needsDisplay,
    });
    if (!isFullPanelHost(host)) return false;
    const previous = center.systemSignalBaseline;
    const transition = planSystemSignalTransition(previous, signals);
    const baseline = resolveSystemSignalBaseline(previous, signals);
    center.systemSignalBaseline = baseline;
    if (baseline.power !== null && previous?.power == null) {
      center.automationEngine.primePowerBaseline(
        baseline.power.onExternalPower,
        baseline.power.batteryPercent,
      );
    }
    if (baseline.externalDisplayCount !== null && previous?.externalDisplayCount == null) {
      center.automationEngine.primeExternalDisplayBaseline(baseline.externalDisplayCount);
    }

    let fired = false;
    if (transition.power !== null) {
      const runs = await dispatchSystemContextEvent(
        host,
        {
          kind: "powerChanged",
          onExternalPower: transition.power.onExternalPower,
          batteryPercent: transition.power.batteryPercent,
        },
        nowMs,
      );
      fired = fired || runs.length > 0;
    }
    if (transition.externalDisplayCount !== null) {
      const runs = await dispatchSystemContextEvent(
        host,
        {
          kind: "externalDisplayChanged",
          externalDisplayCount: transition.externalDisplayCount,
        },
        nowMs,
      );
      fired = fired || runs.length > 0;
    }
    if (fired) host.queueBackgroundRender();
    return fired;
  } finally {
    center.systemPollInFlight = false;
  }
}

/** `PBT_APMSUSPEND` from `system_events.rs`: Windows is about to suspend. */
export function notifySystemSleep(host: unknown, nowMs = Date.now()): void {
  if (!isFullPanelHost(host)) return;
  void dispatchSystemContextEvent(host, { kind: "systemSleep" }, nowMs).then((runs) => {
    if (runs.length > 0) host.queueBackgroundRender();
  });
}

/** `PBT_APMRESUMEAUTOMATIC` / `PBT_APMRESUMESUSPEND` from `system_events.rs`. */
export function notifySystemWake(host: unknown, nowMs = Date.now()): void {
  if (!isFullPanelHost(host)) return;
  void dispatchSystemContextEvent(host, { kind: "systemWake" }, nowMs).then((runs) => {
    if (runs.length > 0) host.queueBackgroundRender();
  });
}

/** `GUID_CONSOLE_DISPLAY_STATE` change from `system_events.rs` (0 = off, 1 = on, 2 = dimmed). */
export function notifyDisplayPowerChanged(
  host: unknown,
  isAsleep: boolean,
  nowMs = Date.now(),
): void {
  if (!isFullPanelHost(host)) return;
  void dispatchSystemContextEvent(host, { kind: "displayPowerChanged", isAsleep }, nowMs).then(
    (runs) => {
      if (runs.length > 0) host.queueBackgroundRender();
    },
  );
}

export function notifyPanelWakeLifecycle(host: unknown, nowMs = Date.now()): void {
  if (!isFullPanelHost(host)) return;
  void dispatchSystemContextEvent(host, { kind: "panelWake" }, nowMs);
}

/** Wi-Fi 轮询节奏，对照 macOS `MacContextObserver` 的 10 秒上下文轮询。 */
const WIFI_POLL_INTERVAL_MS = 10_000;

/**
 * 与 tick 派发同一道快照就绪门槛（`tickSafetyHealthAndAutomation` 的 tick 分支）：
 * 应用启动早期设备来自 `cachedXiaomiDevices` / `cachedHAHome` 且不一定带
 * `telemetryStale` 标记，Wi-Fi 观察的派发会顺带评估 sensorThreshold 等规则，
 * 不设门槛就会拿旧缓存测温/告警触发自动化。门槛未达标时只记录读数、暂缓
 * 派发（快照就绪后的下一次探针自然补上）。
 */
function wifiObservationDispatchAllowed(host: MenuMijiaWindowsApp, center: HostActivityCenter): boolean {
  const enabledRules = center.automationEngine.store.load().filter((rule) => rule.isEnabled);
  return (
    (enabledRules.length > 0 &&
      (host.settings.connectionMode === "demo" || isLiveSnapshotReadyForTelemetry(host) || host.devices.length === 0)) ||
    center.automationEngine.arbitrator.hasPendingLock
  );
}

/**
 * 应用一次 Wi-Fi 探针读数：记录探针状态（设置界面「无权限」引导的数据源），
 * 并在读数变化时经 `dispatchSystemContextEvent` 派发 `wifiChanged`。
 * 「无法知晓」的读数会以 SSID 置空 + 不可信派发（引擎立即按不可信判定），但连续
 * 相同的「无法知晓」读数不重复派发。
 *
 * `seq` 是探针发起时的序号：不大于已应用序号的探针结果不参与派发与基线更新
 * （周期轮询与锁屏实时探针可能并发，先发起的读数可能后返回，不能覆盖更新的
 * 读数或制造假的 joined/left 转换），但仍返回其自身读数——锁屏分支需要锁屏
 * 时刻的真实网络，而不是 fail-closed 占位。
 *
 * 返回本次探针读到的读数；在代际失效或宿主不可用时返回 null（锁屏分支回退
 * 不可信读数，且随后的代际检查会丢弃整个过时事件）。
 */
async function observeAndDispatchWifi(
  host: MenuMijiaWindowsApp,
  center: HostActivityCenter,
  probe: WindowsWifiProbeResult | null | undefined,
  nowMs: number,
  seq: number,
  generation: number,
): Promise<EngineWifiReading | null> {
  // 会话有效性先于一切应用（写 SSID、派发 wifiChanged、写锁屏快照之前）：
  // 家庭切换 / 会话重置递增代际后，在途探针的结果绝不能跨会话生效。
  if (generation !== center.lockSampleGeneration) return null;
  const observation = wifiPollObservationFromProbe(probe);
  if (!isFullPanelHost(host)) return observation.reading;
  const superseded = seq <= center.wifiAppliedSeq;
  if (superseded) return observation.reading;
  center.lastWifiProbeState = observation.state;
  center.wifiAppliedSeq = Math.max(center.wifiAppliedSeq, seq);
  const decision = wifiDispatchDecisionForObservation(observation, center.lastWifiReading);
  const reading = decision ? decision.reading : center.lastWifiReading;
  if (!decision) return reading;
  if (!wifiObservationDispatchAllowed(host, center)) return reading;
  center.lastWifiReading = decision.reading;
  await dispatchSystemContextEvent(
    host,
    { kind: "wifiChanged", ssid: decision.reading.ssid, isAuthorized: decision.reading.isAuthorized },
    nowMs,
  );
  return decision.reading;
}

/**
 * 轮询当前 WLAN 连接（`wifi_current` 命令由 `windows/src-tauri/src/wifi.rs` 提供）。
 * 探针失败（IPC 异常）与「无法知晓」返回同样按不可信读数派发，与 macOS
 * 「无法知晓 ≠ 未连接」的语义一致。
 */
async function pollAndDispatchWifi(
  host: MenuMijiaWindowsApp,
  center: HostActivityCenter,
  nowMs: number,
): Promise<void> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (typeof invoke !== "function" || center.wifiPollInFlight) return;
  if (nowMs - center.lastWifiPollAtMs < WIFI_POLL_INTERVAL_MS) return;
  center.wifiPollInFlight = true;
  center.lastWifiPollAtMs = nowMs;
  try {
    const seq = ++center.wifiProbeSeq;
    const generation = center.lockSampleGeneration;
    let probe: WindowsWifiProbeResult | null = null;
    try {
      probe = await invoke<WindowsWifiProbeResult>("wifi_current");
    } catch {
      probe = null;
    }
    await observeAndDispatchWifi(host, center, probe, nowMs, seq, generation);
  } catch {
    center.lastWifiProbeState = "unknown";
  } finally {
    center.wifiPollInFlight = false;
  }
}

export function tickSafetyHealthAndAutomation(
  host: unknown,
  nowMs = Date.now(),
): boolean {
  if (!isFullPanelHost(host)) return false;

  const center = getHostActivityCenter(host);
  let needsRender = pruneOrphanedDeviceActivities(host, nowMs);

  const enabledRules = center.automationEngine.store.load().filter((r) => r.isEnabled);
  const baseSensorPolicy =
    center.sensorPolicyOverride ??
    loadSensorAlertPolicy(center.storage, center.lastSampledLockState ?? false);
  const needsLockSampling =
    typeof window !== "undefined" &&
    Boolean(window.__TAURI_INTERNALS__?.invoke) &&
    (enabledRules.length > 0 || baseSensorPolicy.onlyWhenAway);

  if (needsLockSampling && !center.lockPollInFlight) {
    center.lockPollInFlight = true;
    void isWorkstationLocked()
      .then(async (locked) => {
        center.lockPollInFlight = false;
        if (!isFullPanelHost(host)) return;
        const previous = center.lastSampledLockState;
        if (previous === null) {
          center.automationEngine.primeLockBaseline(locked);
          center.lastSampledLockState = locked;
          // 重新建立基线意味着此前的会话/重置已作废：递增代际，让任何在途的
          // 旧锁屏回调失效，不得对新的会话派发过时的 lockChanged。
          center.lockSampleGeneration += 1;
          return;
        }
        if (locked !== previous) {
          // 记录翻转代际：探针与规则执行都可能耗时，等待期间可能发生「解锁又
          // 上锁」等后续翻转。代际不一致说明本回调已被超越——继续派发会把过时
          // 的 lockChanged 压在更新的事件之后（布尔值检查区分不了同值的两次
          // 翻转），作废并交由下一次轮询按最新状态派发。
          center.lastSampledLockState = locked;
          center.lockSampleGeneration += 1;
          const myGeneration = center.lockSampleGeneration;
          if (center.lockSampleGeneration !== myGeneration) return;
          let lockWifi: EngineWifiReading | undefined;
          if (locked) {
            // 锁上的瞬间补一次实时 Wi-Fi 探针（对照 macOS 在锁屏信号时刻的实时
            // 读取），让 #9 的锁屏快照拿到最新网络而不是最多 10 秒前的轮询缓存；
            // 读数随 lockChanged 事件直接带给引擎，避免与并发轮询写入共享上下文
            // 产生竞争。探针失败（IPC 异常）与轮询路径一致按「无法知晓」失_close：
            // 传 null 探针得到不可信读数并派发，不把旧轮询的授权 SSID 带进锁屏
            // 快照。
            const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
            if (typeof invoke === "function") {
              // 发起序号在探针发出前递增：锁屏探针必然晚于任何在途周期探针，
              // 其结果不会被后返回的旧读数覆盖。
              const seq = ++center.wifiProbeSeq;
              let probe: WindowsWifiProbeResult | null = null;
              try {
                probe = await invoke<WindowsWifiProbeResult>("wifi_current");
              } catch {
                probe = null;
              }
              const applied = await observeAndDispatchWifi(host, center, probe, nowMs, seq, myGeneration).catch(() => null);
              lockWifi =
                applied ? { ssid: applied.ssid, isAuthorized: applied.isAuthorized } : { ssid: null, isAuthorized: false };
            }
          }
          if (center.lockSampleGeneration !== myGeneration) return;
          const runs = await dispatchSystemContextEvent(
            host,
            { kind: "lockChanged", isLocked: locked, ...(lockWifi ? { wifi: lockWifi } : {}) },
            nowMs,
          );
          if (runs.length > 0) {
            host.queueBackgroundRender();
          }
        }
      })
      .catch(() => {
        center.lockPollInFlight = false;
      });
  }

  const isLockedSnapshot = center.lastSampledLockState ?? false;

  void pollAndDispatchWifi(host, center, nowMs);

  if (isLiveSnapshotReadyForTelemetry(host)) {
    const aliased = aliasedHostDevices(host);
    const guardPrefs = loadSafetyGuardPrefs(center.storage);
    const effectivePolicy: SensorAlertPolicy = {
      ...baseSensorPolicy,
      includesAway: baseSensorPolicy.includesAway || isLockedSnapshot,
    };
    const rawFavorites = new Set<string>([
      ...(host.layout?.pinnedDeviceIds ?? []),
      ...(host.settings.layout?.pinnedDeviceIds ?? []),
    ]);
    const favorites =
      guardPrefs.enableSafetyAlerts && guardPrefs.favoriteOffline ? rawFavorites : new Set<string>();
    const rawAlerts = center.safetyMonitor.evaluate({
      devices: aliased,
      favorites,
      sensorPolicy: effectivePolicy,
      nowMs,
      scope: center.scopeKey,
      deviceFacets: host.deviceFacets,
      observationsByDeviceId: center.observationsOverride ?? undefined,
      language: host.settings.interfaceLanguage,
    });
    const newAlerts = filterSafetyAlertsByGuardPrefs(rawAlerts, aliased, guardPrefs);
    if (recordSafetyAlerts(host, newAlerts, nowMs)) {
      needsRender = true;
    }

    center.offlineHistory.record(aliased, nowMs);

    if (guardPrefs.enableWeeklyHealthReport) {
      const lastDelivered = WeeklyHealthReportSchedule.loadLastDeliveredAtMs(center.storage);
      if (WeeklyHealthReportSchedule.isDue(nowMs, lastDelivered)) {
        deliverWeeklyHealthReport(host, nowMs, { storage: center.storage });
        needsRender = true;
      }
    }
  }

  // Power and external-display sampling runs on the macOS 10 s cadence inside the 1 s tick.
  void pollSystemContextSignals(host, nowMs, enabledRules);

  if (
    (enabledRules.length > 0 && (host.settings.connectionMode === "demo" || isLiveSnapshotReadyForTelemetry(host) || host.devices.length === 0)) ||
    center.automationEngine.arbitrator.hasPendingLock
  ) {
    void dispatchSystemContextEvent(host, { kind: "tick" }, nowMs);
  }
  center.lastEvaluatedAtMs = nowMs;

  return needsRender;
}

export function buildActivityFeed(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
): ActivityFeedItem[] {
  const center = getHostActivityCenter(host);
  pruneOrphanedDeviceActivities(host, nowMs);
  const pref = host.settings.interfaceLanguage;
  const items: ActivityFeedItem[] = [];

  if (
    host.settings.connectionMode === "xiaomiCloud" &&
    host.settings.miSession &&
    !host.miSessionExpired
  ) {
    const expiry = miSessionExpiryState(host.settings.miSession, nowMs);
    if (expiry.kind === "expiringSoon") {
      const noticeId = `notice:miExpiringSoon:${expiry.expiresAtMs}`;
      if (!center.dismissedActivityIds.has(noticeId)) {
        const dateText = new Intl.DateTimeFormat(speechLocale(), {
          month: "short",
          day: "numeric",
        }).format(new Date(expiry.expiresAtMs));
        items.push({
          id: noticeId,
          kind: "miExpiry",
          badge: tr3("即将过期", "即將過期", "Expiring Soon", undefined, pref),
          title: tr3(
            "米家登录将在 {date} 到期",
            "米家登入將在 {date} 到期",
            "Xiaomi Home sign-in expires {date}",
            { date: dateText },
            pref,
          ),
          subtitle: "",
          tone: "warning",
          actionLabel: tr3("重新扫码", "重新掃碼", "Re-scan", undefined, pref),
          actionElementId: "btn-footer-qr",
          isMiExpiryNotice: true,
        });
      }
    }
  }

  const aliased = aliasedHostDevices(host);
  const presentIds = new Set(aliased.map((d) => d.id));
  for (const entry of center.doorbellCoordinator.recentRings) {
    if (entry.scope !== center.scopeKey || !presentIds.has(entry.ring.deviceId)) continue;
    const itemId = `doorbell:${entry.ring.key}`;
    if (center.dismissedActivityIds.has(itemId)) continue;
    const dev = aliased.find((d) => d.id === entry.ring.deviceId);
    const camName = dev?.name ?? entry.ring.entityId;
    items.push({
      id: itemId,
      kind: "doorbell",
      badge: tr3("门铃按响", "門鈴按響", "Doorbell", undefined, pref),
      title: tr3(
        "{name} 刚刚有人按门铃",
        "{name} 剛剛有人按門鈴",
        "Someone rang {name}",
        { name: camName },
        pref,
      ),
      subtitle: dev?.roomName ?? "",
      tone: "accent",
      actionLabel: tr3("查看画面", "查看畫面", "View Live", undefined, pref),
      actionAttr: "data-activity-open-doorbell",
      actionValue: entry.ring.key,
    });
  }

  for (const recorded of center.recentSafetyAlerts) {
    if (recorded.scope !== center.scopeKey) continue;
    if (center.hasObservedNonEmptyDevices && !presentIds.has(recorded.alert.deviceId)) continue;
    const itemId = `safety:${recorded.alert.id}`;
    if (
      center.dismissedActivityIds.has(itemId) ||
      center.dismissedActivityIds.has(recorded.alert.id)
    ) {
      continue;
    }
    const isDanger = recorded.alert.priority === "high";
    items.push({
      id: itemId,
      kind: "safety",
      badge:
        recorded.alert.category === "sensor"
          ? tr3("安防告警", "安防告警", "Security Alert", undefined, pref)
          : tr3("安全守护", "安全守護", "Safety Guard", undefined, pref),
      title: recorded.alert.title,
      subtitle: recorded.alert.body,
      tone: isDanger ? "danger" : "warning",
      ...(recorded.alert.turnOffCommand
        ? {
            actionLabel: tr3("立即关闭", "立即關閉", "Turn Off Now", undefined, pref),
            actionAttr: "data-activity-safety-off",
            actionValue: recorded.alert.id,
          }
        : {}),
    });
  }

  for (const run of center.recentAutomationRuns) {
    if (run.scope !== center.scopeKey || run.expiresAtMs <= nowMs) continue;
    const itemId = `auto:${run.id}`;
    if (center.dismissedActivityIds.has(itemId)) continue;
    const remainingSec = Math.max(1, Math.ceil((run.expiresAtMs - nowMs) / 1000));
    const remainingMin = Math.ceil(remainingSec / 60);
    const timeNote =
      remainingSec >= 60
        ? tr3(
            "{min} 分钟内可撤销",
            "{min} 分鐘內可撤銷",
            "Undo within {min}m",
            { min: remainingMin },
            pref,
          )
        : tr3(
            "{sec} 秒内可撤销",
            "{sec} 秒內可撤銷",
            "Undo within {sec}s",
            { sec: remainingSec },
            pref,
          );
    items.push({
      id: itemId,
      kind: "automation",
      badge: tr3("自动执行", "自動執行", "Automation", undefined, pref),
      title: run.summary,
      subtitle: timeNote,
      tone: "neutral",
      ...(run.steps.length > 0
        ? {
            actionLabel: tr3("撤销", "撤銷", "Undo", undefined, pref),
            actionAttr: "data-activity-auto-undo",
            actionValue: run.id,
          }
        : {}),
    });
  }

  if (center.weeklyReportCard && center.weeklyReportCard.scope === center.scopeKey) {
    const card = center.weeklyReportCard;
    if (!center.dismissedActivityIds.has(card.id)) {
      items.push({
        id: card.id,
        kind: "weeklyReport",
        badge: tr3("健康周报", "健康週報", "Weekly Health", undefined, pref),
        title: tr3(
          "家庭健康周报已生成",
          "家庭健康週報已產生",
          "Weekly Home Health Report Ready",
          undefined,
          pref,
        ),
        subtitle: card.summary,
        tone: "accent",
        actionLabel: tr3("复制 Markdown", "複製 Markdown", "Copy Markdown", undefined, pref),
        actionAttr: "data-activity-copy-health",
        actionValue: card.id,
      });
    }
  }

  if (items.length <= 1 && host.settings.panelTheme !== "classic") {
    center.isExpanded = false;
  }
  return items;
}

export const StackedCardGeometry = {
  maxVisible: 3,
  peekReservePx: 15,
  dismissDistanceFraction: 0.4,
  dismissVelocityPxPerSec: 800,
  backplateTransform(depth: number): { readonly scale: number; readonly scaleX: number; readonly offsetY: number; readonly opacity: number } {
    const clamped = Math.min(Math.max(Math.trunc(depth), 0), 2);
    if (clamped === 0) return { scale: 1, scaleX: 1, offsetY: 0, opacity: 1 };
    if (clamped === 1) return { scale: 0.94, scaleX: 0.94, offsetY: 8, opacity: 0.78 };
    return { scale: 0.88, scaleX: 0.88, offsetY: 15, opacity: 0.55 };
  },
  rubberBand(translationPx: number, widthPx: number): number {
    return widthPx <= 0 ? 0 : (translationPx * widthPx * 0.55) / (widthPx + 0.55 * Math.abs(translationPx));
  },
  shouldDismiss(gesture: { readonly translationPx: number; readonly predictedTranslationPx?: number; readonly velocityPxPerSec: number; readonly widthPx: number }): boolean {
    const width = Math.max(1, gesture.widthPx);
    const predicted = gesture.predictedTranslationPx ?? gesture.translationPx + gesture.velocityPxPerSec * 0.12;
    return Math.abs(gesture.translationPx) > width * 0.4 || Math.abs(predicted) > width * 0.4 || Math.abs(gesture.velocityPxPerSec) > 800;
  },
} as const;

export type UpperStackCardKind =
  | "consent" | "voice" | "haError" | "miExpiry" | "doorbell" | "safety" | "automation"
  | "weeklyReport" | "undo" | "reply" | "suggestions" | "missedTimers" | "proactive" | "timers";

export interface UpperStackCard {
  readonly id: string;
  readonly kind: UpperStackCardKind;
  readonly isDismissible: boolean;
  readonly html: string;
}

export function structuralActivityStackKey(host: MenuMijiaWindowsApp): string {
  const center = getHostActivityCenter(host);
  const items = buildActivityFeed(host);
  if (items.length === 0) return "";
  return `${center.isExpanded ? 1 : 0}:${items.map((item) => `${item.id}:${item.title}:${item.subtitle}:${item.actionValue ?? ""}`).join("|")}`;
}

function renderSingleActivityRow(
  host: MenuMijiaWindowsApp,
  item: ActivityFeedItem,
  options: { readonly stackCount: number; readonly showStackControls: boolean; readonly isDismissible?: boolean },
): string {
  const pref = host.settings.interfaceLanguage;
  const center = getHostActivityCenter(host);
  const isDismissible = options.isDismissible ?? !(item.kind === "automation" && item.actionValue && center.pendingHighRiskUndoRunId === item.actionValue);
  const miAttr = item.isMiExpiryNotice ? " data-mi-expiry-warning" : "";
  const toneClass = item.tone === "danger" ? " is-error" : item.tone === "warning" ? " is-warning" : "";
  const role = item.tone === "danger" ? "alert" : "status";
  const actionButton = item.actionLabel
    ? item.actionElementId
      ? `<button type="button" class="cc-inline-pill" id="${host.escapeHtml(item.actionElementId)}">${host.escapeHtml(item.actionLabel)}</button>`
      : `<button type="button" class="cc-inline-pill" ${item.actionAttr}="${host.escapeHtml(item.actionValue ?? "")}">${host.escapeHtml(item.actionLabel)}</button>`
    : "";
  const stackBadgeButton = options.showStackControls && options.stackCount > 1
    ? `<button type="button" class="cc-inline-pill cc-stack-expand-pill" data-activity-toggle-expand="1" data-upper-toggle-expand="1" aria-expanded="false" title="${host.escapeHtml(tr3("展开全部 {count} 条提醒", "展開全部 {count} 條提醒", "Expand all {count} activities", { count: options.stackCount }, pref))}">+${options.stackCount - 1}</button>`
    : "";
  const dismissLabel = host.escapeHtml(tr3("划掉此条提醒", "劃掉此條提醒", "Dismiss activity", undefined, pref));
  const dismissButton = isDismissible
    ? `<button type="button" class="cc-inline-pill" data-activity-dismiss="${host.escapeHtml(item.id)}" data-upper-dismiss="${host.escapeHtml(item.id)}" aria-label="${dismissLabel}" title="${dismissLabel}">×</button>`
    : "";
  const clearAllLabel = host.escapeHtml(tr3("清空全部提醒", "清空全部提醒", "Clear all activities", undefined, pref));
  const clearAllButton = options.showStackControls && options.stackCount > 1
    ? `<button type="button" class="cc-inline-pill" data-activity-clear-all="1" data-upper-clear-all="1" aria-label="${clearAllLabel}" title="${clearAllLabel}">${host.escapeHtml(tr3("清空", "清空", "Clear", undefined, pref))}</button>`
    : "";
  const textBody = item.subtitle
    ? `${host.escapeHtml(item.title)} · <span style="opacity:0.84;">${host.escapeHtml(item.subtitle)}</span>`
    : host.escapeHtml(item.title);
  return `<div class="win-notif-card cc-feedback-card${toneClass}" role="${role}" data-activity-card="${host.escapeHtml(item.id)}" data-upper-card-id="${host.escapeHtml(item.id)}" data-activity-kind="${item.kind}" data-upper-kind="${item.kind}" data-upper-dismissible="${isDismissible ? "true" : "false"}"${miAttr}>
    <div class="cc-feedback-row" style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
      <span class="cc-feedback-badge">${host.escapeHtml(item.badge)}</span>
      <span class="cc-feedback-text" style="flex:1;min-width:120px;">${textBody}</span>
      ${actionButton}${stackBadgeButton}${clearAllButton}${dismissButton}
    </div>
  </div>`;
}

function renderPeekBackplates(totalCount: number): string {
  const visibleDepth = Math.min(totalCount, StackedCardGeometry.maxVisible);
  if (visibleDepth <= 1) return "";
  const plates: string[] = [];
  for (let depth = visibleDepth - 1; depth >= 1; depth -= 1) {
    const tf = StackedCardGeometry.backplateTransform(depth);
    plates.push(`<div class="cc-stack-backplate" data-stack-peek="${depth}" aria-hidden="true" style="--peek-scale:${tf.scaleX};--peek-offset-y:${tf.offsetY}px;--peek-opacity:${tf.opacity};transform:translateY(${tf.offsetY}px) scaleX(${tf.scaleX});opacity:${tf.opacity};"></div>`);
  }
  return plates.join("");
}

export function renderActivityStack(host: MenuMijiaWindowsApp, nowMs = Date.now()): string {
  const center = getHostActivityCenter(host);
  const items = buildActivityFeed(host, nowMs);
  if (items.length === 0) return "";
  const pref = host.settings.interfaceLanguage;
  if (items.length === 1) {
    return `<section class="cc-activity-stack" data-activity-stack data-activity-count="1" data-activity-expanded="false">${renderSingleActivityRow(host, items[0]!, { stackCount: 1, showStackControls: false })}</section>`;
  }
  if (!center.isExpanded) {
    return `<section class="cc-activity-stack is-collapsed" data-activity-stack data-activity-count="${items.length}" data-activity-expanded="false" style="position:relative;">
      ${renderPeekBackplates(items.length)}
      ${renderSingleActivityRow(host, items[0]!, { stackCount: items.length, showStackControls: true })}
      <div class="cc-activity-deck-shadow" data-activity-deck aria-hidden="true" style="height:4px;margin:0 10px 4px;border-radius:0 0 var(--r-card, 8px) var(--r-card, 8px);opacity:0.45;border-bottom:1px solid currentColor;"></div>
    </section>`;
  }
  const countTitle = tr3("{count} 条家庭动态", "{count} 條家庭動態", "{count} Home Activities", { count: items.length }, pref);
  const collapseLabel = tr3("收起", "收起", "Collapse", undefined, pref);
  const clearAllText = tr3("全部忽略", "全部忽略", "Dismiss All", undefined, pref);
  return `<section class="cc-activity-stack is-expanded" data-activity-stack data-activity-count="${items.length}" data-activity-expanded="true">
    <div class="cc-activity-stack-header" style="display:flex;align-items:center;justify-content:space-between;padding:2px 6px 4px;font-size:12px;opacity:0.86;">
      <strong style="display:inline-flex;align-items:center;gap:4px;">${SF_ICONS.sparkles}<span>${host.escapeHtml(countTitle)}</span></strong>
      <div style="display:inline-flex;gap:6px;">
        <button type="button" class="cc-inline-pill" data-activity-toggle-expand="1" data-upper-toggle-expand="1" aria-expanded="true">${host.escapeHtml(collapseLabel)}</button>
        <button type="button" class="cc-inline-pill" data-activity-clear-all="1" data-upper-clear-all="1">${host.escapeHtml(clearAllText)}</button>
      </div>
    </div>
    <div class="cc-activity-stack-list" style="display:flex;flex-direction:column;gap:6px;">
      ${items.map((item) => renderSingleActivityRow(host, item, { stackCount: items.length, showStackControls: false })).join("")}
    </div>
  </section>`;
}

interface UpperCardFactory {
  readonly id: string;
  readonly kind: UpperStackCardKind;
  readonly isDismissible: boolean;
  readonly render: (opts: { readonly stackCount: number; readonly showStackControls: boolean }) => string;
}

/**
 * #104: returns the aliased wall-switch device when an active, current-revision primary-power
 * `pendingHighRisk` confirmation should offer «这是灯，以后不再询问». Shared by Fluent `liveBanner`
 * and Classic `reply:banner` so both themes apply identical eligibility rules.
 */
export function primaryPowerSwitchLightMarkDevice(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
): SmartDevice | null {
  const armed = host.pendingHighRisk;
  if (
    !armed ||
    !armed.primaryPower ||
    armed.expiresAtMs <= nowMs ||
    armed.sourceRevision !== host.sourceRevision
  ) {
    return null;
  }
  const prefs = host.layout ?? host.settings?.layout;
  const aliased = prefs ? withAliases(prefs, host.devices) : host.devices;
  const device = aliased.find((d) => d.id === armed.deviceId);
  if (!device || isSwitchMarkedAsLight(device.id)) return null;
  return ManualControlPolicy.wallSwitchMayControlLight(device) ? device : null;
}

/** Wall-switch rename guidance under a confirmation, kept when the reply merges into the undo card (#104). */
function feedbackHint(host: MenuMijiaWindowsApp, reply: ReplyBannerState | null, overrideHint?: string | null): string {
  const text = overrideHint ?? reply?.hint;
  return text ? `<p class="cc-feedback-hint">${host.escapeHtml(text)}</p>` : "";
}

function buildUpperCardFactories(host: MenuMijiaWindowsApp, nowMs = Date.now()): UpperCardFactory[] {
  const center = getHostActivityCenter(host);
  const pref = host.settings.interfaceLanguage;
  const dismissLabel = host.escapeHtml(tr3("划掉此条提醒", "劃掉此條提醒", "Dismiss activity", undefined, pref));
  const clearAllLabel = host.escapeHtml(tr3("清空全部提醒", "清空全部提醒", "Clear all activities", undefined, pref));
  const renderStackBtns = (opts: { readonly stackCount: number; readonly showStackControls: boolean }, cardId: string, isDismissible: boolean, extraDismissId?: string): string => {
    const expandBtn = opts.showStackControls && opts.stackCount > 1 ? `<button type="button" class="cc-inline-pill cc-stack-expand-pill" data-activity-toggle-expand="1" data-upper-toggle-expand="1" aria-expanded="false" title="${host.escapeHtml(tr3("展开全部 {count} 条提醒", "展開全部 {count} 條提醒", "Expand all {count} activities", { count: opts.stackCount }, pref))}">+${opts.stackCount - 1}</button>` : "";
    const clearBtn = opts.showStackControls && opts.stackCount > 1 ? `<button type="button" class="cc-inline-pill" data-activity-clear-all="1" data-upper-clear-all="1" aria-label="${clearAllLabel}" title="${clearAllLabel}">${host.escapeHtml(tr3("清空", "清空", "Clear", undefined, pref))}</button>` : "";
    const dismissBtn = isDismissible ? `<button type="button" class="cc-inline-pill"${extraDismissId ? ` id="${extraDismissId}"` : ""} data-upper-dismiss="${host.escapeHtml(cardId)}" data-activity-dismiss="${host.escapeHtml(cardId)}" aria-label="${dismissLabel}" title="${dismissLabel}">×</button>` : "";
    return `${expandBtn}${clearBtn}${dismissBtn}`;
  };
  const wrapCard = (id: string, kind: UpperStackCardKind, isDismissible: boolean, cls: string, innerRow: (btns: string) => string, extraAttrs = "", role = "status", extraDismissId?: string): UpperCardFactory => ({
    id, kind, isDismissible,
    render: (opts) => `<div class="win-notif-card ${cls}" role="${role}"${extraAttrs} data-upper-card-id="${id}" data-upper-kind="${kind}" data-upper-dismissible="${isDismissible ? "true" : "false"}">${innerRow(renderStackBtns(opts, id, isDismissible, extraDismissId))}</div>`,
  });

  const factories: UpperCardFactory[] = [];
  if (host.pendingCloudConsent) {
    const reply = host.replyBanner;
    factories.push(wrapCard("consent:cloud", "consent", false, "cc-live-banner cc-feedback-card", (btns) => `<div class="cc-feedback-row">${reply ? `<span class="cc-feedback-badge">${host.escapeHtml(reply.source)}</span><span class="cc-feedback-text">${host.escapeHtml(reply.text)}</span>` : ""}<button class="cc-inline-pill" id="btn-cloud-allow">${t("允许并发送")}</button><button class="cc-inline-pill" id="btn-cloud-decline">${t("不用了")}</button>${btns}</div>`));
  } else if (host.isListeningVoice) {
    factories.push(wrapCard("voice:active", "voice", false, "cc-feedback-card", (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">${t("语音控制")}</span><span class="cc-feedback-text">${host.escapeHtml(host.panelSearch.query || t("语音控制"))}</span>${btns}</div>`));
  }
  if (host.haConnectionError) {
    const errText = host.haConnectionError;
    factories.push(wrapCard("ha:error", "haError", false, "cc-feedback-card is-error", (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">Home Assistant</span><span class="cc-feedback-text">${host.escapeHtml(errText)}</span>${btns}</div>`, " data-ha-error", "alert"));
  }

  let replyConsumedByArmedAuto = false;
  for (const item of buildActivityFeed(host, nowMs)) {
    const isArmedHighRisk = item.kind === "automation" && Boolean(center.pendingHighRiskUndoRunId) && (item.actionValue === center.pendingHighRiskUndoRunId || item.id === `auto:${center.pendingHighRiskUndoRunId}`);
    const isDismissible = !isArmedHighRisk;
    const renderedItem = isArmedHighRisk
      ? {
          ...item,
          tone: "warning" as const,
          subtitle: host.replyBanner?.text || item.subtitle,
          actionLabel: tr3("确认撤销", "確認撤銷", "Confirm Undo", undefined, host.settings.interfaceLanguage),
        }
      : item;
    if (isArmedHighRisk && host.replyBanner && !host.replyBanner.isError && host.pendingHighRisk === null) {
      replyConsumedByArmedAuto = true;
    }
    const factory: UpperCardFactory = { id: item.id, kind: item.kind, isDismissible, render: (opts) => renderSingleActivityRow(host, renderedItem, { stackCount: opts.stackCount, showStackControls: opts.showStackControls, isDismissible }) };
    if (isArmedHighRisk) factories.unshift(factory);
    else factories.push(factory);
  }

  const undoState = computeUndoAvailability(host, nowMs);
  const tracker = undoTrackerFor(host);
  if (!undoState.isAvailable || isUndoHoverPaused(host) || !host.lastUndoAction) {
    tracker.syncAction(null, nowMs);
  } else if (tracker.expiresAtMs !== undoState.expiresAtMs || tracker.summary !== undoState.summary) {
    tracker.syncAction(host.lastUndoAction, nowMs, () => {
      if (host.lastUndoAction && host.lastUndoAction.expiresAtMs <= Date.now()) host.lastUndoAction = null;
      host.queueBackgroundRender();
    });
  }

  const autoRunId = host.lastUndoAction ? getAutomationUndoRunId(host.lastUndoAction) : null;
  const isDuplicateAutoUndo = autoRunId !== null && center.recentAutomationRuns.some((r) => r.id === autoRunId && r.expiresAtMs > nowMs);
  const undoDismissKey = host.lastUndoAction ? `undo:${host.lastUndoAction.expiresAtMs}:${host.lastUndoAction.summary}` : "";
  let replyConsumedByUndo = false;
  let manualUndoRendered = false;
  if (undoState.isAvailable && host.lastUndoAction && !isDuplicateAutoUndo && !center.dismissedActivityIds.has(undoDismissKey)) {
    const reply = host.replyBanner;
    const mergeReply = Boolean(reply && !reply.isError && !host.pendingCloudConsent && host.pendingHighRisk === null && !replyConsumedByArmedAuto);
    if (mergeReply) replyConsumedByUndo = true;
    manualUndoRendered = true;
    const badge = mergeReply && reply ? reply.source : t("撤销提示");
    const text = mergeReply && reply ? reply.text : `${host.lastUndoAction.summary} ${t("· 剩余 {remaining}", { remaining: host.formatRemainingMs(Math.max(1000, undoState.remainingMs)) })}`;
    const hint = mergeReply ? feedbackHint(host, reply) : "";
    factories.push(wrapCard("undo:manual", "undo", true, "cc-live-banner cc-feedback-card", (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">${host.escapeHtml(badge)}</span><span class="cc-feedback-text">${host.escapeHtml(text)}</span><button class="cc-inline-pill" id="btn-undo">${t("撤销")}</button>${btns}</div>${hint}`));
  }

  if (host.replyBanner && !host.pendingCloudConsent && !replyConsumedByUndo && !replyConsumedByArmedAuto) {
    const reply = host.replyBanner;
    const hasActiveHighRisk = host.pendingHighRisk !== null && host.pendingHighRisk.expiresAtMs > nowMs;
    const isDismissible = !hasActiveHighRisk;
    const markDevice = primaryPowerSwitchLightMarkDevice(host, nowMs);
    const markPill = markDevice
      ? `<button class="cc-inline-pill" data-mark-switch-light="${host.escapeHtml(markDevice.id)}">${t("这是灯，以后不再询问")}</button>`
      : "";
    const hint = feedbackHint(
      host,
      reply,
      markDevice ? ManualControlPolicy.wallSwitchMarkPromptHint(markDevice) : undefined,
    );
    const replyFactory = wrapCard("reply:banner", "reply", isDismissible, `cc-live-banner cc-feedback-card${reply.isError ? " is-error" : ""}`, (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">${host.escapeHtml(reply.source)}</span><span class="cc-feedback-text">${host.escapeHtml(reply.text)}</span>${markPill}${!manualUndoRendered && host.undoButtonVisible(nowMs) ? `<button class="cc-inline-pill" id="btn-undo">${t("撤销")}</button>` : ""}${btns}</div>${hint}`, "", reply.isError ? "alert" : "status", "btn-dismiss-banner");
    if (hasActiveHighRisk) factories.unshift(replyFactory);
    else factories.push(replyFactory);
  }
  if (host.pendingSuggestions.length > 0) {
    factories.push(wrapCard("suggestions:pending", "suggestions", true, "cc-feedback-card", (btns) => `<div class="cc-feedback-row"><div class="cc-suggestion-row" style="flex:1;">${host.pendingSuggestions.map((item) => `<button class="cc-inline-pill" data-suggestion-id="${host.escapeHtml(item.id)}">${host.escapeHtml(item.title)}${item.confidencePercent !== null ? ` · ${item.confidencePercent}%` : ""}</button>`).join("")}</div>${btns}</div>`));
  }
  if (host.missedScheduledCommands.length > 0) {
    factories.push({
      id: "missed:timers", kind: "missedTimers", isDismissible: true,
      render: (opts) => `<div class="win-notif-card cc-feedback-card is-warning" data-upper-card-id="missed:timers" data-upper-kind="missedTimers" data-upper-dismissible="true"><div class="cc-timers-stack">${host.missedScheduledCommands.map((item) => `<div class="cc-timer-row"><span>${t("已错过定时：{command}（没有自动执行，请确认后运行）", { command: host.escapeHtml(item.command) })}</span><button class="cc-inline-pill" data-run-missed="${host.escapeHtml(item.id)}">${t("立即执行")}</button><button class="cc-inline-pill" data-dismiss-missed="${host.escapeHtml(item.id)}">${t("忽略")}</button></div>`).join("")}</div>${opts.showStackControls && opts.stackCount > 1 ? `<div class="cc-feedback-row">${renderStackBtns(opts, "missed:timers", true)}</div>` : ""}</div>`,
    });
  }
  if (host.pendingSuggestions.length === 0) {
    const items = host.currentProactiveSuggestions();
    if (items.length > 0) {
      const sig = `${proactiveSignature(host)}:${items.map((item) => item.id).join(",")}`;
      if (center.dismissedProactiveSignature !== sig) {
        factories.push(wrapCard("proactive:suggestions", "proactive", true, "cc-feedback-card", (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">${SF_ICONS.sparkles} ${t("猜你想控")}</span><div class="cc-suggestion-row" data-proactive-bar style="flex:1;">${items.map((item) => renderProactiveInlinePill(host, item)).join("")}</div>${btns}</div>`, ' data-notif-card="proactive"'));
      }
    }
  }
  if (host.scheduledCommands.length > 0) {
    factories.push(wrapCard("timers:active", "timers", true, "cc-feedback-card", (btns) => `<div class="cc-feedback-row"><span class="cc-feedback-badge">${SF_ICONS.clock} ${t("定时指令")}</span><div class="cc-timers-stack" style="flex:1;">${host.scheduledCommands.map((item) => `<div class="cc-timer-row"><span>${host.escapeHtml(item.command)} ${t("· 剩余 {remaining}", { remaining: host.formatRemainingMs(item.fireTimestampMs - nowMs) })}</span><button class="cc-inline-pill" data-cancel-timer="${host.escapeHtml(item.id)}">${t("取消")}</button></div>`).join("")}</div>${btns}</div>`, ' data-notif-card="timers"'));
  }
  return factories;
}

export function collectUpperStackCards(host: MenuMijiaWindowsApp, nowMs = Date.now()): UpperStackCard[] {
  const center = getHostActivityCenter(host);
  const factories = buildUpperCardFactories(host, nowMs);
  if (factories.length <= 1) center.isExpanded = false;
  const showCollapsedControls = !center.isExpanded && factories.length > 1;
  return factories.map((f, idx) => ({ id: f.id, kind: f.kind, isDismissible: f.isDismissible, html: f.render({ stackCount: factories.length, showStackControls: showCollapsedControls && idx === 0 }) }));
}

export function renderClassicUnifiedUpperStack(host: MenuMijiaWindowsApp, nowMs = Date.now()): string {
  const center = getHostActivityCenter(host);
  const cards = collectUpperStackCards(host, nowMs);
  if (cards.length === 0) return "";
  const pref = host.settings.interfaceLanguage;
  if (cards.length === 1) return `<section class="cc-upper-stack cc-activity-stack" data-upper-stack data-activity-stack data-activity-count="1" data-activity-expanded="false">${cards[0]!.html}</section>`;
  if (!center.isExpanded) {
    const visibleDepth = Math.min(cards.length, StackedCardGeometry.maxVisible);
    const reservePx = visibleDepth > 1 ? StackedCardGeometry.backplateTransform(visibleDepth - 1).offsetY : 0;
    return `<section class="cc-upper-stack cc-activity-stack is-collapsed" data-upper-stack data-activity-stack data-activity-count="${cards.length}" data-activity-expanded="false" style="position:relative;padding-bottom:${reservePx}px;">${renderPeekBackplates(cards.length)}${cards[0]!.html}</section>`;
  }
  const countTitle = tr3("{count} 条家庭动态", "{count} 條家庭動態", "{count} Home Activities", { count: cards.length }, pref);
  const collapseLabel = tr3("收起", "收起", "Collapse", undefined, pref);
  const clearAllText = tr3("全部忽略", "全部忽略", "Dismiss All", undefined, pref);
  const anyDismissible = cards.some((card) => card.isDismissible);
  return `<section class="cc-upper-stack cc-activity-stack is-expanded" data-upper-stack data-activity-stack data-activity-count="${cards.length}" data-activity-expanded="true"><div class="cc-activity-stack-header" style="display:flex;align-items:center;justify-content:space-between;padding:2px 6px 4px;font-size:12px;opacity:0.86;"><strong style="display:inline-flex;align-items:center;gap:4px;">${SF_ICONS.sparkles}<span>${host.escapeHtml(countTitle)}</span></strong><div style="display:inline-flex;gap:6px;"><button type="button" class="cc-inline-pill" data-activity-toggle-expand="1" data-upper-toggle-expand="1" aria-expanded="true">${host.escapeHtml(collapseLabel)}</button>${anyDismissible ? `<button type="button" class="cc-inline-pill" data-activity-clear-all="1" data-upper-clear-all="1">${host.escapeHtml(clearAllText)}</button>` : ""}</div></div><div class="cc-activity-stack-list" style="display:flex;flex-direction:column;gap:6px;">${cards.map((c) => c.html).join("")}</div></section>`;
}

export const renderUnifiedUpperStack = renderClassicUnifiedUpperStack;

export function dismissActivityById(host: MenuMijiaWindowsApp, activityId: string): void {
  const center = getHostActivityCenter(host);
  const bannerOwnedByPinnedCard =
    Boolean(host.pendingCloudConsent) ||
    host.pendingHighRisk !== null ||
    (Boolean(center.pendingHighRiskUndoRunId) && Boolean(host.replyBanner && !host.replyBanner.isError));
  if (activityId === "undo:manual") {
    if (host.lastUndoAction) center.dismissedActivityIds.add(`undo:${host.lastUndoAction.expiresAtMs}:${host.lastUndoAction.summary}`);
    host.lastUndoAction = null;
    host.undoBannerUntilMs = 0;
    undoTrackerFor(host).syncAction(null);
    if (host.replyBanner && !host.replyBanner.isError && !bannerOwnedByPinnedCard) host.replyBanner = null;
  } else if (activityId === "proactive:suggestions") {
    const items = host.currentProactiveSuggestions();
    center.dismissedProactiveSignature = items.length > 0 ? `${proactiveSignature(host)}:${items.map((i) => i.id).join(",")}` : proactiveSignature(host);
    center.dismissedActivityIds.add("proactive:suggestions");
  } else if (activityId === "reply:banner") {
    if (!bannerOwnedByPinnedCard) host.replyBanner = null;
  } else if (activityId === "suggestions:pending") {
    host.pendingSuggestions = [];
  } else if (activityId === "missed:timers") {
    for (const item of [...host.missedScheduledCommands]) cancelScheduledCommands(host, item.id);
  } else if (activityId === "timers:active") {
    for (const item of [...host.scheduledCommands]) cancelScheduledCommands(host, item.id);
  } else if (activityId.startsWith("auto:")) {
    const runId = activityId.slice("auto:".length);
    if (center.pendingHighRiskUndoRunId === runId) return;
    center.dismissedActivityIds.add(activityId);
    center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
  } else {
    center.dismissedActivityIds.add(activityId);
    if (activityId.startsWith("safety:")) {
      const rawId = activityId.slice("safety:".length);
      center.recentSafetyAlerts = center.recentSafetyAlerts.filter((r) => r.alert.id !== rawId);
    } else if (activityId.startsWith("doorbell:")) {
      center.doorbellCoordinator.dismissRingKey(activityId.slice("doorbell:".length));
    } else if (center.weeklyReportCard?.id === activityId) {
      center.weeklyReportCard = null;
    }
  }
  const remaining = host.settings.panelTheme === "classic" ? collectUpperStackCards(host).length : buildActivityFeed(host).length;
  if (remaining <= 1) center.isExpanded = false;
}

export const dismissUpperStackCard = dismissActivityById;

export function dismissAllActivities(host: MenuMijiaWindowsApp): void {
  const center = getHostActivityCenter(host);
  for (const item of buildActivityFeed(host)) {
    if (item.kind === "automation" && item.actionValue && center.pendingHighRiskUndoRunId === item.actionValue) continue;
    center.dismissedActivityIds.add(item.id);
  }
  center.recentSafetyAlerts = [];
  center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => center.pendingHighRiskUndoRunId === r.id);
  center.weeklyReportCard = null;
  center.doorbellCoordinator.clearAll();
  if (host.settings.panelTheme === "classic") {
    for (const id of ["undo:manual", "proactive:suggestions", "reply:banner", "suggestions:pending", "missed:timers", "timers:active"]) dismissActivityById(host, id);
  }
  center.isExpanded = false;
}

export function bindUnifiedUpperStack(host: MenuMijiaWindowsApp): void {
  const center = getHostActivityCenter(host);
  for (const plate of host.root.querySelectorAll<HTMLElement>(".cc-stack-backplate")) {
    if (plate.closest("[data-exit-ghost]")) continue;
    plate.addEventListener("click", (e) => { e.stopPropagation(); center.isExpanded = true; host.render(); });
  }
  for (const cardEl of host.root.querySelectorAll<HTMLElement>("[data-upper-card-id]")) {
    if (cardEl.closest("[data-exit-ghost]")) continue;
    const cardId = cardEl.dataset.upperCardId ?? cardEl.dataset.activityCard ?? "";
    if (!cardId) continue;
    const isDismissible = cardEl.dataset.upperDismissible !== "false";
    let activePointerId: number | null = null, startX = 0, startY = 0, startTimeMs = 0, lastX = 0, lastTimeMs = 0, velocityPxPerSec = 0, isHorizontalSwipe = false;

    cardEl.addEventListener("pointerdown", (e: PointerEvent) => {
      if ((typeof e.button === "number" && e.button !== 0) || (e.target as Element | null)?.closest?.("button, input, select, a, summary")) return;
      activePointerId = typeof e.pointerId === "number" ? e.pointerId : 1;
      startX = lastX = e.clientX;
      startY = e.clientY;
      startTimeMs = lastTimeMs = e.timeStamp && e.timeStamp > 0 ? e.timeStamp : performance.now();
      velocityPxPerSec = 0;
      isHorizontalSwipe = false;
      try { cardEl.setPointerCapture?.(activePointerId); } catch {}
    });

    cardEl.addEventListener("pointermove", (e: PointerEvent) => {
      if (activePointerId === null) return;
      const dx = e.clientX - startX, dy = e.clientY - startY;
      if (!isHorizontalSwipe) {
        if (Math.abs(dx) < 6 && Math.abs(dy) < 6) return;
        if (Math.abs(dy) > Math.abs(dx)) { activePointerId = null; return; }
        isHorizontalSwipe = true;
        cardEl.setAttribute("data-stack-dragging", "true");
      }
      const now = e.timeStamp && e.timeStamp > 0 ? e.timeStamp : performance.now();
      velocityPxPerSec = (e.clientX - lastX) / Math.max(0.001, (now - lastTimeMs) / 1000);
      lastX = e.clientX;
      lastTimeMs = now;
      const widthPx = cardEl.getBoundingClientRect().width || cardEl.offsetWidth || 396;
      const tx = (isDismissible ? dx : StackedCardGeometry.rubberBand(dx, widthPx)).toFixed(2);
      cardEl.style.transform = `translate3d(${tx}px, 0px, 0px)`;
      cardEl.style.setProperty("--swipe-x", `${tx}px`);
    });

    const finishPointer = (e: PointerEvent, cancelled: boolean): void => {
      if (activePointerId === null) return;
      const dx = e.clientX - startX;
      const now = e.timeStamp && e.timeStamp > 0 ? e.timeStamp : performance.now();
      const idleSinceLastMoveMs = now - lastTimeMs;
      const releaseVelocity = idleSinceLastMoveMs > 80
        ? 0
        : Math.abs(velocityPxPerSec) < 1 && Math.abs(dx) > 0
          ? dx / Math.max(0.008, (now - startTimeMs) / 1000)
          : velocityPxPerSec;
      const widthPx = cardEl.getBoundingClientRect().width || cardEl.offsetWidth || 396;
      const ptrId = activePointerId;
      activePointerId = null;
      cardEl.removeAttribute("data-stack-dragging");
      try { cardEl.releasePointerCapture?.(ptrId); } catch {}
      if (!cancelled && isHorizontalSwipe && isDismissible && StackedCardGeometry.shouldDismiss({ translationPx: dx, velocityPxPerSec: releaseVelocity, widthPx })) {
        dismissUpperStackCard(host, cardId);
        host.render();
        return;
      }
      cardEl.style.transform = "translate3d(0px, 0px, 0px)";
      cardEl.style.setProperty("--swipe-x", "0px");
    };
    cardEl.addEventListener("pointerup", (e: PointerEvent) => finishPointer(e, false));
    cardEl.addEventListener("pointercancel", (e: PointerEvent) => finishPointer(e, true));
  }
}

export function bindActivityStackAfterRender(host: MenuMijiaWindowsApp): void {
  const center = getHostActivityCenter(host);

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-toggle-expand]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      center.isExpanded = !center.isExpanded;
      host.render();
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-dismiss], [data-upper-dismiss]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.upperDismiss ?? btn.dataset.activityDismiss;
      if (!id) return;
      dismissActivityById(host, id);
      host.render();
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-clear-all]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      dismissAllActivities(host);
      host.render();
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-safety-off]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const alertId = btn.dataset.activitySafetyOff;
      if (!alertId) return;
      void executeSafetyTurnOffAction(host, alertId);
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-auto-undo]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const runId = btn.dataset.activityAutoUndo;
      if (!runId) return;
      void executeAutomationCardUndo(host, runId);
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-copy-health]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      void copyWeeklyHealthMarkdown(host);
    });
  }

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-open-doorbell]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const ringKey = btn.dataset.activityOpenDoorbell;
      if (!ringKey) return;
      const matched = center.doorbellCoordinator.recentRings.find((r) => r.ring.key === ringKey);
      if (!matched) return;
      center.doorbellCoordinator.claimDoorbellWindowForUser();
      host.cameraLive.openCameraLiveView(matched.ring.deviceId);
    });
  }

  bindUnifiedUpperStack(host);

  const cameraSheet = host.root.querySelector<HTMLElement>(".cc-camera-live-sheet");
  if (cameraSheet) {
    const onUserInteract = (): void => {
      center.doorbellCoordinator.claimDoorbellWindowForUser();
    };
    cameraSheet.addEventListener("pointerdown", onUserInteract);
    cameraSheet.addEventListener("keydown", onUserInteract);
    cameraSheet.addEventListener("wheel", onUserInteract, { passive: true });
  }

  const hideBtn = host.root.querySelector<HTMLButtonElement>("#btn-hide-panel");
  if (hideBtn) {
    hideBtn.addEventListener("click", () => {
      if (collapseActivityStackOnHide(host)) {
        host.render();
      }
    });
  }

  const hostWithActivity = host as HostWithActivity;
  if (!hostWithActivity.activityWindowLifecycleBound) {
    hostWithActivity.activityWindowLifecycleBound = true;
    const ownerDoc = host.root.ownerDocument ?? document;
    const ownerWin = ownerDoc.defaultView ?? window;
    ownerDoc.addEventListener("visibilitychange", () => {
      if (ownerDoc.visibilityState === "hidden") {
        collapseActivityStackOnHide(host);
      }
    });
    ownerWin.addEventListener("blur", () => {
      collapseActivityStackOnHide(host);
    });
  }
}
