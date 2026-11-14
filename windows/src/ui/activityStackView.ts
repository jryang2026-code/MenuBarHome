import {
  AutomationEngine,
  DoorbellCameraCoordinator,
  DoorbellDetector,
  type DoorbellCoordinatorScheduler,
  type DoorbellResponse,
  type DoorbellRing,
  type HASnapshotLike,
  type RecordedAutomationRun,
  type SystemContextEvent,
} from "../core/automationEngine.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { speechLocale } from "../core/i18n.js";
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
import { getScopedEnergyHistory } from "../core/energyHistory.js";
import { resolveSensorHistoryScope, sharedSensorHistoryStore } from "../core/sensorHistory.js";
import type { SmartDevice } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
import { getHostMiAccountsState, isDualSourceEnabled } from "./cloudRefresh.js";
import { energyScopeForHost } from "./energySettingsView.js";
import { withAliases } from "./panelPrefs.js";
import {
  recordUndoKindSnapshots,
  rejectIfControlBlockedWhileLocked,
} from "./speechGuard.js";
import { isWorkstationLocked } from "./transport.js";

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
  lastClipboardMarkdown: string | null;
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
  return prefs ? withAliases(prefs, host.devices) : [...host.devices];
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
  host: Pick<MenuMijiaWindowsApp, "settings" | "miAccountsOverride" | "multiAccountState" | "dualSourceEnabledOverride">,
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
    lastClipboardMarkdown: null,
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
  if (!center || !center.isExpanded) return false;
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

export async function executeAutomationCardUndo(
  host: MenuMijiaWindowsApp,
  runId: string,
  nowMs = Date.now(),
): Promise<boolean> {
  if (await rejectIfControlBlockedWhileLocked(host)) {
    return false;
  }

  const center = getHostActivityCenter(host);
  const pref = host.settings.interfaceLanguage;
  const run = center.recentAutomationRuns.find((r) => r.id === runId);
  if (!run) return false;

  const startingRevision = host.sourceRevision ?? 0;
  const startingScope = computeActivityScopeKey(host);
  if (run.scope !== startingScope || run.expiresAtMs <= nowMs) {
    center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
    host.replyBanner = {
      text: tr3(
        "撤销窗口已过期或家庭已切换",
        "撤銷視窗已過期或家庭已切換",
        "Undo window expired or home changed",
        undefined,
        pref,
      ),
      source: tr3("状态感知自动化", "狀態感知自動化", "Context Automation", undefined, pref),
      isError: true,
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
  for (const step of [...run.steps].reverse()) {
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

  center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
  if (host.lastUndoAction && host.lastUndoAction.summary === run.summary) {
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
  const center = getHostActivityCenter(host);
  const aliased = aliasedHostDevices(host);
  const rings: DoorbellRing[] = center.doorbellDetector.ingestHASnapshot(snapshot, aliased);
  if (rings.length === 0) return [];

  const isLocked = options.isLocked ?? (await isWorkstationLocked());
  const nowMs = options.nowMs ?? Date.now();
  for (const ring of rings) {
    center.dismissedActivityIds.delete(`doorbell:${ring.key}`);
  }

  const responses = center.doorbellCoordinator.handleRings({
    rings,
    devices: aliased,
    cameraLive: host.cameraLive,
    isLocked,
    scope: center.scopeKey,
    nowMs,
    autoPopup: options.autoPopup,
    popupSeconds: options.popupSeconds,
    playChime: options.playChime,
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

export function notifyPanelWakeLifecycle(host: unknown, nowMs = Date.now()): void {
  if (!isFullPanelHost(host)) return;
  void dispatchSystemContextEvent(host, { kind: "panelWake" }, nowMs);
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
        center.lastSampledLockState = locked;
        if (previous === null) {
          center.automationEngine.primeLockBaseline(locked);
          return;
        }
        if (locked !== previous) {
          const runs = await dispatchSystemContextEvent(
            host,
            { kind: "lockChanged", isLocked: locked },
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

  if (isLiveSnapshotReadyForTelemetry(host)) {
    const aliased = aliasedHostDevices(host);
    const effectivePolicy: SensorAlertPolicy = {
      ...baseSensorPolicy,
      includesAway: baseSensorPolicy.includesAway || isLockedSnapshot,
    };
    const favorites = new Set<string>([
      ...(host.layout?.pinnedDeviceIds ?? []),
      ...(host.settings.layout?.pinnedDeviceIds ?? []),
    ]);
    const newAlerts = center.safetyMonitor.evaluate({
      devices: aliased,
      favorites,
      sensorPolicy: effectivePolicy,
      nowMs,
      scope: center.scopeKey,
      deviceFacets: host.deviceFacets,
      observationsByDeviceId: center.observationsOverride ?? undefined,
      language: host.settings.interfaceLanguage,
    });
    if (recordSafetyAlerts(host, newAlerts, nowMs)) {
      needsRender = true;
    }

    center.offlineHistory.record(aliased, nowMs);

    const lastDelivered = WeeklyHealthReportSchedule.loadLastDeliveredAtMs(center.storage);
    if (WeeklyHealthReportSchedule.isDue(nowMs, lastDelivered)) {
      deliverWeeklyHealthReport(host, nowMs, { storage: center.storage });
      needsRender = true;
    }
  }

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

  if (items.length <= 1) {
    center.isExpanded = false;
  }
  return items;
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
  options: {
    readonly stackCount: number;
    readonly showStackControls: boolean;
  },
): string {
  const pref = host.settings.interfaceLanguage;
  const miAttr = item.isMiExpiryNotice ? " data-mi-expiry-warning" : "";
  const toneClass = item.tone === "danger" ? " is-error" : item.tone === "warning" ? " is-warning" : "";
  const role = item.tone === "danger" ? "alert" : "status";
  const actionButton = item.actionLabel
    ? item.actionElementId
      ? `<button type="button" class="cc-inline-pill" id="${host.escapeHtml(item.actionElementId)}">${host.escapeHtml(item.actionLabel)}</button>`
      : `<button type="button" class="cc-inline-pill" ${item.actionAttr}="${host.escapeHtml(item.actionValue ?? "")}">${host.escapeHtml(item.actionLabel)}</button>`
    : "";

  const stackBadgeButton =
    options.showStackControls && options.stackCount > 1
      ? `<button type="button" class="cc-inline-pill" data-activity-toggle-expand="1" aria-expanded="false" title="${host.escapeHtml(tr3("展开全部 {count} 条提醒", "展開全部 {count} 條提醒", "Expand all {count} activities", { count: options.stackCount }, pref))}">+${options.stackCount - 1}</button>`
      : "";

  const dismissLabel = host.escapeHtml(
    tr3("划掉此条提醒", "劃掉此條提醒", "Dismiss activity", undefined, pref),
  );
  const dismissButton = `<button type="button" class="cc-inline-pill" data-activity-dismiss="${host.escapeHtml(item.id)}" aria-label="${dismissLabel}" title="${dismissLabel}">×</button>`;

  const clearAllLabel = host.escapeHtml(
    tr3("清空全部提醒", "清空全部提醒", "Clear all activities", undefined, pref),
  );
  const clearAllButton =
    options.showStackControls && options.stackCount > 1
      ? `<button type="button" class="cc-inline-pill" data-activity-clear-all="1" aria-label="${clearAllLabel}" title="${clearAllLabel}">${host.escapeHtml(tr3("清空", "清空", "Clear", undefined, pref))}</button>`
      : "";

  const textBody = item.subtitle
    ? `${host.escapeHtml(item.title)} · <span style="opacity:0.84;">${host.escapeHtml(item.subtitle)}</span>`
    : host.escapeHtml(item.title);

  return `<div class="win-notif-card cc-feedback-card${toneClass}" role="${role}" data-activity-card="${host.escapeHtml(item.id)}" data-activity-kind="${item.kind}"${miAttr}>
    <div class="cc-feedback-row" style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
      <span class="cc-feedback-badge">${host.escapeHtml(item.badge)}</span>
      <span class="cc-feedback-text" style="flex:1;min-width:120px;">${textBody}</span>
      ${actionButton}
      ${stackBadgeButton}
      ${clearAllButton}
      ${dismissButton}
    </div>
  </div>`;
}

export function renderActivityStack(
  host: MenuMijiaWindowsApp,
  nowMs = Date.now(),
): string {
  const center = getHostActivityCenter(host);
  const items = buildActivityFeed(host, nowMs);
  if (items.length === 0) return "";

  const pref = host.settings.interfaceLanguage;
  if (items.length === 1) {
    return `<section class="cc-activity-stack" data-activity-stack data-activity-count="1" data-activity-expanded="false">
      ${renderSingleActivityRow(host, items[0]!, { stackCount: 1, showStackControls: false })}
    </section>`;
  }

  if (!center.isExpanded) {
    const top = items[0]!;
    return `<section class="cc-activity-stack is-collapsed" data-activity-stack data-activity-count="${items.length}" data-activity-expanded="false" style="position:relative;">
      ${renderSingleActivityRow(host, top, { stackCount: items.length, showStackControls: true })}
      <div class="cc-activity-deck-shadow" data-activity-deck aria-hidden="true" style="height:4px;margin:0 10px 4px;border-radius:0 0 var(--r-card, 8px) var(--r-card, 8px);opacity:0.45;border-bottom:1px solid currentColor;"></div>
    </section>`;
  }

  const countTitle = tr3(
    "{count} 条家庭动态",
    "{count} 條家庭動態",
    "{count} Home Activities",
    { count: items.length },
    pref,
  );
  const collapseLabel = tr3("收起", "收起", "Collapse", undefined, pref);
  const clearAllText = tr3("全部忽略", "全部忽略", "Dismiss All", undefined, pref);

  return `<section class="cc-activity-stack is-expanded" data-activity-stack data-activity-count="${items.length}" data-activity-expanded="true">
    <div class="cc-activity-stack-header" style="display:flex;align-items:center;justify-content:space-between;padding:2px 6px 4px;font-size:12px;opacity:0.86;">
      <strong style="display:inline-flex;align-items:center;gap:4px;">${SF_ICONS.sparkles}<span>${host.escapeHtml(countTitle)}</span></strong>
      <div style="display:inline-flex;gap:6px;">
        <button type="button" class="cc-inline-pill" data-activity-toggle-expand="1" aria-expanded="true">${host.escapeHtml(collapseLabel)}</button>
        <button type="button" class="cc-inline-pill" data-activity-clear-all="1">${host.escapeHtml(clearAllText)}</button>
      </div>
    </div>
    <div class="cc-activity-stack-list" style="display:flex;flex-direction:column;gap:6px;">
      ${items.map((item) => renderSingleActivityRow(host, item, { stackCount: items.length, showStackControls: false })).join("")}
    </div>
  </section>`;
}

export function dismissActivityById(host: MenuMijiaWindowsApp, activityId: string): void {
  const center = getHostActivityCenter(host);
  center.dismissedActivityIds.add(activityId);

  if (activityId.startsWith("safety:")) {
    const rawId = activityId.slice("safety:".length);
    center.recentSafetyAlerts = center.recentSafetyAlerts.filter((r) => r.alert.id !== rawId);
  } else if (activityId.startsWith("doorbell:")) {
    const key = activityId.slice("doorbell:".length);
    center.doorbellCoordinator.dismissRingKey(key);
  } else if (activityId.startsWith("auto:")) {
    const runId = activityId.slice("auto:".length);
    center.recentAutomationRuns = center.recentAutomationRuns.filter((r) => r.id !== runId);
  } else if (center.weeklyReportCard?.id === activityId) {
    center.weeklyReportCard = null;
  }

  if (buildActivityFeed(host).length <= 1) {
    center.isExpanded = false;
  }
}

export function dismissAllActivities(host: MenuMijiaWindowsApp): void {
  const center = getHostActivityCenter(host);
  const currentFeed = buildActivityFeed(host);
  for (const item of currentFeed) {
    center.dismissedActivityIds.add(item.id);
  }
  center.recentSafetyAlerts = [];
  center.recentAutomationRuns = [];
  center.weeklyReportCard = null;
  center.doorbellCoordinator.clearAll();
  center.isExpanded = false;
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

  for (const btn of host.root.querySelectorAll<HTMLButtonElement>("[data-activity-dismiss]")) {
    if (btn.closest("[data-exit-ghost]")) continue;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.activityDismiss;
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
