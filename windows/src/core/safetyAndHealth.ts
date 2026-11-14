import {
  currentLanguage,
  resolveLanguage,
  type AppLanguage,
  type LanguagePreference,
} from "./i18n.js";
import {
  isDeviceActiveOn,
  type DeviceCommand,
  type FacetControl,
  type SmartDevice,
} from "./models.js";
import { formatTemperature } from "./temperature.js";

export interface KeyValueStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

class MemoryStorage implements KeyValueStorageLike {
  private readonly map = new Map<string, string>();
  public getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  public setItem(key: string, value: string): void {
    this.map.set(key, value);
  }
  public removeItem(key: string): void {
    this.map.delete(key);
  }
}

const fallbackStorage = new MemoryStorage();

export function defaultSafetyStorage(): KeyValueStorageLike {
  try {
    if (typeof globalThis.localStorage !== "undefined" && globalThis.localStorage !== null) {
      return globalThis.localStorage;
    }
  } catch {
  }
  return fallbackStorage;
}

function fillTemplate(
  template: string,
  params?: Readonly<Record<string, string | number>>,
): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole,
  );
}

export function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  params?: Readonly<Record<string, string | number>>,
  preference?: LanguagePreference,
): string {
  const lang: AppLanguage =
    preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : currentLanguage();
  const chosen = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  return fillTemplate(chosen, params);
}

export type SensorAlertKind = "smoke" | "gas" | "leak" | "contact" | "motion" | "vibration" | "lock";

export const SENSOR_ALERT_KINDS: readonly SensorAlertKind[] = [
  "smoke", "gas", "leak", "contact", "motion", "vibration", "lock",
] as const;

export interface SensorObservation {
  readonly kind: SensorAlertKind;
  readonly sourceId: string;
  readonly alarming: boolean;
  readonly reportedAtMs?: number | null;
}

export interface SensorAlertPolicy {
  readonly enabled: Partial<Record<SensorAlertKind, boolean>>;
  readonly onlyWhenAway: boolean;
  readonly includesAway: boolean;
}

export const SENSOR_POLICY_STORAGE_KEY = "safety_sensor_policy_v1";

export function sensorAlertEnabledByDefault(kind: SensorAlertKind): boolean {
  switch (kind) {
    case "smoke":
    case "gas":
    case "leak":
    case "lock":
      return true;
    case "contact":
    case "motion":
    case "vibration":
      return false;
  }
}

export function sensorAlertIsHazard(kind: SensorAlertKind): boolean {
  return kind === "smoke" || kind === "gas" || kind === "leak";
}

export function sensorAlertHonorsAwayLimit(kind: SensorAlertKind): boolean {
  return !sensorAlertIsHazard(kind);
}

export function sensorAlertNotifiesOnFirstSample(kind: SensorAlertKind): boolean {
  return sensorAlertIsHazard(kind);
}

export function sensorAlertSettingsTitle(
  kind: SensorAlertKind,
  preference?: LanguagePreference,
): string {
  switch (kind) {
    case "smoke":
      return tr3("烟雾告警", "煙霧告警", "Smoke", undefined, preference);
    case "gas":
      return tr3("燃气告警", "燃氣告警", "Gas", undefined, preference);
    case "leak":
      return tr3("水浸漏水告警", "水浸漏水告警", "Water leak", undefined, preference);
    case "contact":
      return tr3("门窗打开", "門窗打開", "Door and window", undefined, preference);
    case "motion":
      return tr3("人体移动", "人體移動", "Motion", undefined, preference);
    case "vibration":
      return tr3("异动震动", "異動震動", "Vibration / Tamper", undefined, preference);
    case "lock":
      return tr3("门锁异常", "門鎖異常", "Door lock alert", undefined, preference);
  }
}

export function sensorAlertNotificationTitle(
  kind: SensorAlertKind,
  deviceName: string,
  preference?: LanguagePreference,
): string {
  const p = { name: deviceName };
  switch (kind) {
    case "smoke":
      return tr3("{name} 烟雾告警", "{name} 煙霧告警", "{name} Smoke Alert", p, preference);
    case "gas":
      return tr3("{name} 燃气告警", "{name} 燃氣告警", "{name} Gas Alert", p, preference);
    case "leak":
      return tr3("{name} 浸水告警", "{name} 浸水告警", "{name} Water Leak", p, preference);
    case "contact":
      return tr3("{name} 已打开", "{name} 已打開", "{name} Opened", p, preference);
    case "motion":
      return tr3("{name} 检测到移动", "{name} 偵測到移動", "{name} Motion Detected", p, preference);
    case "vibration":
      return tr3("{name} 检测到震动异动", "{name} 偵測到震動異動", "{name} Vibration Detected", p, preference);
    case "lock":
      return tr3("{name} 门锁异常告警", "{name} 門鎖異常告警", "{name} Lock Alert", p, preference);
  }
}

export function createDefaultSensorAlertPolicy(includesAway = false): SensorAlertPolicy {
  const enabled: Partial<Record<SensorAlertKind, boolean>> = {};
  for (const kind of SENSOR_ALERT_KINDS) {
    enabled[kind] = sensorAlertEnabledByDefault(kind);
  }
  return {
    enabled,
    onlyWhenAway: false,
    includesAway,
  };
}

export function sensorPolicyAllows(policy: SensorAlertPolicy, kind: SensorAlertKind): boolean {
  const isEnabled = policy.enabled[kind] ?? sensorAlertEnabledByDefault(kind);
  if (!isEnabled) return false;
  if (sensorAlertHonorsAwayLimit(kind) && policy.onlyWhenAway) {
    return policy.includesAway;
  }
  return true;
}

export function loadSensorAlertPolicy(
  storage: KeyValueStorageLike = defaultSafetyStorage(),
  includesAway = false,
): SensorAlertPolicy {
  const base = createDefaultSensorAlertPolicy(includesAway);
  try {
    const raw = storage.getItem(SENSOR_POLICY_STORAGE_KEY);
    if (!raw) return base;
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const enabledRaw =
      parsed.enabled && typeof parsed.enabled === "object" && !Array.isArray(parsed.enabled)
        ? (parsed.enabled as Record<string, unknown>)
        : {};
    const enabled: Partial<Record<SensorAlertKind, boolean>> = { ...base.enabled };
    for (const kind of SENSOR_ALERT_KINDS) {
      if (typeof enabledRaw[kind] === "boolean") {
        enabled[kind] = enabledRaw[kind] as boolean;
      }
    }
    return {
      enabled,
      onlyWhenAway: typeof parsed.onlyWhenAway === "boolean" ? parsed.onlyWhenAway : false,
      includesAway,
    };
  } catch {
    return base;
  }
}

export function saveSensorAlertPolicy(
  policy: Omit<SensorAlertPolicy, "includesAway"> & { readonly includesAway?: boolean },
  storage: KeyValueStorageLike = defaultSafetyStorage(),
): void {
  try {
    storage.setItem(
      SENSOR_POLICY_STORAGE_KEY,
      JSON.stringify({
        enabled: policy.enabled,
        onlyWhenAway: policy.onlyWhenAway,
      }),
    );
  } catch {
  }
}

const SMOKE_TOKENS = ["smoke", "烟雾", "煙霧", "烟感"];
const GAS_TOKENS = ["gas", "natgas", "燃气", "燃氣", "天然气", "煤气"];
const LEAK_TOKENS = ["water_leak", "water-leak", "submersion", "moisture", "flood", "leak", "水浸", "浸水", "漏水", "溢水"];
const VIBRATION_TOKENS = ["vibration", "tamper", "shake", "tilt", "震动", "振動", "异动", "撬"];
const CONTACT_TOKENS = ["magnet", "contact", "door", "window", "opening", "门窗", "門窗", "门磁", "窗磁"];
const MOTION_TOKENS = ["motion", "occupancy", "presence", "pir", "人体", "人體", "人在", "移动", "移動"];

function inferSensorKindFromMetadata(text: string): SensorAlertKind | null {
  const lower = text.toLowerCase();
  if (SMOKE_TOKENS.some((t) => lower.includes(t))) return "smoke";
  if (GAS_TOKENS.some((t) => lower.includes(t))) return "gas";
  if (LEAK_TOKENS.some((t) => lower.includes(t))) return "leak";
  if (VIBRATION_TOKENS.some((t) => lower.includes(t))) return "vibration";
  if (
    (lower.includes("lock") && !lower.includes("clock") && !lower.includes("block") && !lower.includes("child")) ||
    lower.includes("门锁") ||
    lower.includes("門鎖")
  ) {
    return "lock";
  }
  if (CONTACT_TOKENS.some((t) => lower.includes(t))) return "contact";
  if (MOTION_TOKENS.some((t) => lower.includes(t))) return "motion";
  return null;
}

const CLEAR_STATUS_TOKENS = [
  "normal", "clear", "closed", "locked", "dry", "safe", "no motion", "nobody",
  "unoccupied", "idle", "off", "false", "正常", "安全", "无异常", "無異常",
  "已关闭", "已關閉", "已闭合", "已閉合", "关闭", "關閉", "已上锁", "已上鎖", "已锁", "无人", "無人",
  "无移动", "干燥", "乾燥", "未触发", "未檢測", "未检测",
];

const lastKnownSensorKindByDeviceId = new Map<string, SensorAlertKind>();

const LOCK_ALARM_TOKENS = [
  "unlocked", "jammed", "ajar", "tamper", "forced", "未上锁", "未上鎖",
  "未关好", "虚掩", "撬", "异常", "異常", "告警", "报警",
];

const GENERAL_ALARM_TOKENS = [
  "on", "true", "open", "opened", "detected", "alarm", "alert", "wet", "leak",
  "smoke", "gas", "motion", "occupied", "moving", "vibrat", "tamper", "triggered",
  "告警", "报警", "報警", "异常", "異常", "打开", "打開", "开启", "開啟", "未关",
  "未關", "有人", "移动", "移動", "漏水", "浸水", "水浸", "烟雾", "煙霧", "燃气",
  "燃氣", "震动", "振動", "触发", "觸發",
];

function isStatusTextCleared(status: string): boolean {
  const lower = status.trim().toLowerCase();
  if (!lower) return true;
  return CLEAR_STATUS_TOKENS.some((token) => lower === token || lower.includes(token));
}

function isStatusTextAlarming(kind: SensorAlertKind, status: string): boolean {
  const trimmed = status.trim();
  if (!trimmed) return false;
  const lower = trimmed.toLowerCase();
  if (kind === "lock") {
    return LOCK_ALARM_TOKENS.some((token) => lower.includes(token));
  }
  if (isStatusTextCleared(trimmed)) return false;
  return GENERAL_ALARM_TOKENS.some((token) => lower === token || lower.includes(token));
}

export function extractSensorObservations(
  device: SmartDevice,
  facets: readonly FacetControl[] = [],
  explicitObservations?: readonly SensorObservation[],
): SensorObservation[] {
  if (explicitObservations && explicitObservations.length > 0) {
    return [...explicitObservations];
  }
  if (!device.isOnline) return [];

  const results: SensorObservation[] = [];
  const seenSources = new Set<string>();
  const pushObs = (obs: SensorObservation): void => {
    if (seenSources.has(obs.sourceId)) return;
    seenSources.add(obs.sourceId);
    results.push(obs);
  };

  if (device.kind.kind === "sensor") {
    if (device.kind.safetyObservations && device.kind.safetyObservations.length > 0) {
      for (const item of device.kind.safetyObservations) {
        pushObs({
          kind: item.kind,
          sourceId: `${device.id}:${item.entityId}:${item.kind}`,
          alarming: item.alarming,
        });
      }
    } else {
      const statusText = device.kind.statusText?.trim() ?? "";
      const explicitOrMetaKind =
        device.kind.alertKind ??
        inferSensorKindFromMetadata(`${device.model} ${device.name} ${statusText}`) ??
        null;
      if (explicitOrMetaKind !== null) {
        lastKnownSensorKindByDeviceId.set(device.id, explicitOrMetaKind);
      }
      const inferredKind =
        explicitOrMetaKind ??
        (statusText !== "" && isStatusTextCleared(statusText)
          ? (lastKnownSensorKindByDeviceId.get(device.id) ?? null)
          : null);
      if (inferredKind !== null && statusText !== "") {
        pushObs({
          kind: inferredKind,
          sourceId: `${device.id}:${inferredKind}`,
          alarming: isStatusTextAlarming(inferredKind, statusText),
        });
      }
    }
  } else if (device.kind.kind === "generic" && device.kind.alerts && device.kind.alerts.length > 0) {
    for (let idx = 0; idx < device.kind.alerts.length; idx += 1) {
      const alertText = device.kind.alerts[idx] ?? "";
      const kind = inferSensorKindFromMetadata(`${device.model} ${device.name} ${alertText}`);
      if (kind) {
        pushObs({
          kind,
          sourceId: `${device.id}:generic:${kind}:${idx}`,
          alarming: isStatusTextAlarming(kind, alertText),
        });
      }
    }
  }

  for (const facet of facets) {
    const kind = inferSensorKindFromMetadata(`${facet.serviceName} ${facet.name} ${facet.title ?? ""}`);
    if (!kind) continue;
    let alarming = false;
    if (typeof facet.value === "boolean") {
      alarming = facet.value;
    } else if (typeof facet.value === "number") {
      alarming = facet.value > 0;
    } else if (typeof facet.value === "string") {
      alarming = isStatusTextAlarming(kind, facet.value);
    }
    pushObs({
      kind,
      sourceId: `${device.id}:facet:${facet.id}:${kind}`,
      alarming,
    });
  }

  return results;
}

export function formatAlertClockLabel(timestampMs: number): string {
  const d = new Date(timestampMs);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export type SafetyAlertCategory = "longRun" | "offline" | "lowBattery" | "sensor";

export interface SafetyAlert {
  readonly id: string;
  readonly deviceId: string;
  readonly title: string;
  readonly body: string;
  readonly category: SafetyAlertCategory;
  readonly sensorKind?: SensorAlertKind;
  readonly priority: "high" | "normal";
  readonly turnOffCommand?: DeviceCommand;
}

export interface RecordedSafetyAlert {
  readonly alert: SafetyAlert;
  readonly scope: string;
  readonly dateMs: number;
}

export function evaluateSensorAlerts(
  devices: readonly SmartDevice[],
  ledger: Readonly<Record<string, boolean>>,
  nowMs: number,
  policy: SensorAlertPolicy,
  options: {
    readonly deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
    readonly observationsByDeviceId?: Readonly<Record<string, readonly SensorObservation[]>>;
    readonly language?: LanguagePreference;
  } = {},
): { readonly alerts: SafetyAlert[]; readonly ledger: Record<string, boolean> } {
  const nextLedger: Record<string, boolean> = { ...ledger };
  const alerts: SafetyAlert[] = [];

  for (const device of devices) {
    const observations = extractSensorObservations(
      device,
      options.deviceFacets?.[device.id] ?? [],
      options.observationsByDeviceId?.[device.id],
    );
    for (const obs of observations) {
      const previous = Object.prototype.hasOwnProperty.call(nextLedger, obs.sourceId)
        ? nextLedger[obs.sourceId]
        : undefined;
      nextLedger[obs.sourceId] = obs.alarming;
      const firstSample = previous === undefined && sensorAlertNotifiesOnFirstSample(obs.kind);
      const rose = obs.alarming && (previous === false || firstSample);
      if (!rose || !sensorPolicyAllows(policy, obs.kind)) continue;

      const detectedAtMs = obs.reportedAtMs ?? nowMs;
      const clock = formatAlertClockLabel(detectedAtMs);
      const roomLabel = device.roomName.trim() || tr3("未分配房间", "未分配房間", "Unassigned", undefined, options.language);
      alerts.push({
        id: `sensor:${obs.kind}:${obs.sourceId}:${Math.floor(detectedAtMs / 1000)}`,
        deviceId: device.id,
        title: sensorAlertNotificationTitle(obs.kind, device.name, options.language),
        body: tr3(
          "「{name}」（{room}）于 {clock} 触发",
          "「{name}」（{room}）於 {clock} 觸發",
          "\"{name}\" ({room}) triggered at {clock}",
          { name: device.name, room: roomLabel, clock },
          options.language,
        ),
        category: "sensor",
        sensorKind: obs.kind,
        priority: sensorAlertIsHazard(obs.kind) || obs.kind === "lock" ? "high" : "normal",
      });
    }
  }

  return { alerts, ledger: nextLedger };
}

function extractBatteryPercent(device: SmartDevice): number | null {
  switch (device.kind.kind) {
    case "sensor":
      return device.kind.battery;
    case "cover":
      return device.kind.batteryPercent;
    case "vacuum":
      return device.kind.battery;
    default:
      return null;
  }
}

export class SafetyMonitor {
  public static readonly longRunningPlugMinimumWatts = 300;
  public static readonly longRunningPlugMs = 45 * 60 * 1000;
  public static readonly longRunningClimateMs = 4 * 60 * 60 * 1000;
  public static readonly lowBatteryThresholdPercent = 15;
  public static readonly lowBatteryCooldownMs = 24 * 60 * 60 * 1000;
  public static readonly lowBatteryAlertedAtKey = "safety_low_battery_alerted_at_v1";
  public static readonly sensorEdgeKey = "safety_sensor_edge_v1";

  private readonly storage: KeyValueStorageLike;
  private activeScope: string;
  private previousOnlineDeviceIds = new Set<string>();
  private hasEvaluatedSnapshot = false;
  private lowBatteryAlertedAtMs: Record<string, number> = {};
  private activeSinceByDeviceId = new Map<string, number>();
  private longRunAlertedForSession = new Set<string>();
  private sensorEdge: Record<string, boolean> = {};

  constructor(storage: KeyValueStorageLike = defaultSafetyStorage(), scope = "default") {
    this.storage = storage;
    this.activeScope = scope.trim() || "default";
    this.lowBatteryAlertedAtMs = this.loadNumberMap(SafetyMonitor.lowBatteryAlertedAtKey);
    this.sensorEdge = this.loadBooleanMap(this.currentSensorEdgeStorageKey());
  }

  private currentSensorEdgeStorageKey(): string {
    return this.activeScope === "default"
      ? SafetyMonitor.sensorEdgeKey
      : `${SafetyMonitor.sensorEdgeKey}:${this.activeScope}`;
  }

  public setScope(scope: string): void {
    const normalized = scope.trim() || "default";
    if (normalized === this.activeScope) return;
    this.activeScope = normalized;
    this.sensorEdge = this.loadBooleanMap(this.currentSensorEdgeStorageKey());
    this.previousOnlineDeviceIds.clear();
    this.hasEvaluatedSnapshot = false;
    this.activeSinceByDeviceId.clear();
    this.longRunAlertedForSession.clear();
  }

  public resetSessionState(nextScope?: string): void {
    this.previousOnlineDeviceIds.clear();
    this.hasEvaluatedSnapshot = false;
    this.activeSinceByDeviceId.clear();
    this.longRunAlertedForSession.clear();
    if (nextScope !== undefined) {
      const normalized = nextScope.trim() || "default";
      this.activeScope = normalized;
      this.sensorEdge = this.loadBooleanMap(this.currentSensorEdgeStorageKey());
    } else {
      this.sensorEdge = {};
      try {
        this.storage.removeItem(this.currentSensorEdgeStorageKey());
      } catch {
      }
    }
  }

  public evaluate(args: {
    readonly devices: readonly SmartDevice[];
    readonly favorites: ReadonlySet<string>;
    readonly sensorPolicy: SensorAlertPolicy;
    readonly nowMs?: number;
    readonly scope?: string;
    readonly deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
    readonly observationsByDeviceId?: Readonly<Record<string, readonly SensorObservation[]>>;
    readonly language?: LanguagePreference;
  }): SafetyAlert[] {
    if (args.scope !== undefined) {
      this.setScope(args.scope);
    }
    const nowMs = args.nowMs ?? Date.now();
    const emitted: SafetyAlert[] = [];
    const presentIds = new Set(args.devices.map((d) => d.id));

    for (const id of [...this.activeSinceByDeviceId.keys()]) {
      if (!presentIds.has(id)) this.activeSinceByDeviceId.delete(id);
    }
    for (const id of [...this.longRunAlertedForSession]) {
      if (!presentIds.has(id)) this.longRunAlertedForSession.delete(id);
    }

    for (const dev of args.devices) {
      const roomLabel = dev.roomName.trim() || tr3("当前家庭", "目前家庭", "Home", undefined, args.language);

      if (this.hasEvaluatedSnapshot && args.favorites.has(dev.id)) {
        if (this.previousOnlineDeviceIds.has(dev.id) && !dev.isOnline) {
          emitted.push({
            id: `offline:${dev.id}:${Math.floor(nowMs / 1000)}`,
            deviceId: dev.id,
            title: tr3("{name} 已离线", "{name} 已離線", "{name} Offline", { name: dev.name }, args.language),
            body: tr3(
              "{room}的「{name}」刚刚断开连接或断电。",
              "{room}的「{name}」剛剛中斷連線或斷電。",
              "\"{name}\" in {room} just went offline or lost power.",
              { name: dev.name, room: roomLabel },
              args.language,
            ),
            category: "offline",
            priority: "normal",
          });
        }
      }

      const bat = extractBatteryPercent(dev);
      if (dev.isOnline && bat !== null && bat > 0 && bat < SafetyMonitor.lowBatteryThresholdPercent) {
        const lastAlertMs = this.lowBatteryAlertedAtMs[dev.id];
        if (
          lastAlertMs === undefined ||
          nowMs - lastAlertMs >= SafetyMonitor.lowBatteryCooldownMs ||
          nowMs < lastAlertMs
        ) {
          this.lowBatteryAlertedAtMs[dev.id] = nowMs;
          this.persistNumberMap(SafetyMonitor.lowBatteryAlertedAtKey, this.lowBatteryAlertedAtMs);
          const roundedBat = Math.round(bat);
          emitted.push({
            id: `battery:${dev.id}`,
            deviceId: dev.id,
            title: tr3(
              "{name} 电量低 ({bat}%)",
              "{name} 電量低 ({bat}%)",
              "{name} Low Battery ({bat}%)",
              { name: dev.name, bat: roundedBat },
              args.language,
            ),
            body: tr3(
              "请及时为{room}的「{name}」更换电池或充电。",
              "請及時為{room}的「{name}」更換電池或充電。",
              "Please replace or recharge the battery for \"{name}\" ({room}).",
              { name: dev.name, room: roomLabel },
              args.language,
            ),
            category: "lowBattery",
            priority: "normal",
          });
        }
      }

      if (isDeviceActiveOn(dev)) {
        let startedAtMs = this.activeSinceByDeviceId.get(dev.id);
        if (startedAtMs === undefined) {
          startedAtMs = nowMs;
          this.activeSinceByDeviceId.set(dev.id, nowMs);
        }
        const elapsedMs = Math.max(0, nowMs - startedAtMs);
        const kind = dev.kind;

        if (
          kind.kind === "plug" &&
          kind.powerWritable !== false &&
          elapsedMs >= SafetyMonitor.longRunningPlugMs &&
          (kind.powerWatts ?? 0) > SafetyMonitor.longRunningPlugMinimumWatts &&
          !this.longRunAlertedForSession.has(dev.id)
        ) {
          this.longRunAlertedForSession.add(dev.id);
          const watts = Math.round(kind.powerWatts ?? 0);
          emitted.push({
            id: `longrun:${dev.id}`,
            deviceId: dev.id,
            title: tr3("{name} 已开启超过 45 分钟", "{name} 已開啟超過 45 分鐘", "{name} On for Over 45m", { name: dev.name }, args.language),
            body: tr3("当前功率 {watts}W，如需关闭可直接点击通知按钮。", "目前功率 {watts}W，如需關閉可直接點擊通知按鈕。", "Drawing {watts}W. Click the notification action to turn it off.", { watts }, args.language),
            category: "longRun",
            priority: "high",
            turnOffCommand: { kind: "setSwitch", entityId: kind.switchEntityId, isOn: false },
          });
        } else if (
          kind.kind === "climate" &&
          kind.powerWritable !== false &&
          elapsedMs >= SafetyMonitor.longRunningClimateMs &&
          !this.longRunAlertedForSession.has(dev.id)
        ) {
          this.longRunAlertedForSession.add(dev.id);
          const tempLabel = formatTemperature(kind.targetTemperature);
          emitted.push({
            id: `longrun:${dev.id}`,
            deviceId: dev.id,
            title: tr3("{name} 已连续运行 4 小时", "{name} 已連續運作 4 小時", "{name} Running for 4 Hours", { name: dev.name }, args.language),
            body: tr3("当前设定 {temp}，请确认是否仍需开启。", "目前設定 {temp}，請確認是否仍需開啟。", "Target temp {temp}. Check if you still need it running.", { temp: tempLabel }, args.language),
            category: "longRun",
            priority: "high",
            turnOffCommand: { kind: "setClimatePower", entityId: kind.entityId, isOn: false, resumeMode: kind.hvacMode },
          });
        } else if (
          kind.kind === "appliance" &&
          kind.heats &&
          kind.powerPresent &&
          kind.powerWritable &&
          elapsedMs >= SafetyMonitor.longRunningClimateMs &&
          !this.longRunAlertedForSession.has(dev.id)
        ) {
          this.longRunAlertedForSession.add(dev.id);
          const tempLabel = kind.targetTemperature !== null ? formatTemperature(kind.targetTemperature) : "";
          emitted.push({
            id: `longrun:${dev.id}`,
            deviceId: dev.id,
            title: tr3("{name} 已连续运行 4 小时", "{name} 已連續運作 4 小時", "{name} Running for 4 Hours", { name: dev.name }, args.language),
            body: tempLabel
              ? tr3("当前设定 {temp}，请确认是否仍需开启。", "目前設定 {temp}，請確認是否仍需開啟。", "Target temp {temp}. Check if you still need it running.", { temp: tempLabel }, args.language)
              : tr3("取暖/加热设备已持续开启较长时间，请确认用火用电安全。", "取暖/加熱設備已持續開啟較長時間，請確認用電安全。", "Heating appliance has been running continuously; please verify safety.", undefined, args.language),
            category: "longRun",
            priority: "high",
            turnOffCommand: { kind: "setSwitch", entityId: kind.powerEntityId, isOn: false },
          });
        }
      } else {
        this.activeSinceByDeviceId.delete(dev.id);
        this.longRunAlertedForSession.delete(dev.id);
      }
    }

    const evaluated = evaluateSensorAlerts(args.devices, this.sensorEdge, nowMs, args.sensorPolicy, {
      deviceFacets: args.deviceFacets,
      observationsByDeviceId: args.observationsByDeviceId,
      language: args.language,
    });
    if (!shallowEqualBooleanMap(evaluated.ledger, this.sensorEdge)) {
      this.sensorEdge = evaluated.ledger;
      this.persistBooleanMap(this.currentSensorEdgeStorageKey(), this.sensorEdge);
    }
    emitted.push(...evaluated.alerts);

    this.previousOnlineDeviceIds = new Set(args.devices.filter((d) => d.isOnline).map((d) => d.id));
    this.hasEvaluatedSnapshot = true;
    return emitted;
  }

  private loadNumberMap(key: string): Record<string, number> {
    try {
      const raw = this.storage.getItem(key);
      if (!raw) return {};
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const out: Record<string, number> = {};
      for (const [k, v] of Object.entries(parsed)) {
        if (typeof v === "number" && Number.isFinite(v)) {
          out[k] = v < 1e11 ? v * 1000 : v;
        }
      }
      return out;
    } catch {
      return {};
    }
  }

  private persistNumberMap(key: string, map: Readonly<Record<string, number>>): void {
    try {
      const secondsMap: Record<string, number> = {};
      for (const [k, ms] of Object.entries(map)) {
        secondsMap[k] = Math.floor(ms / 1000);
      }
      this.storage.setItem(key, JSON.stringify(secondsMap));
    } catch {
    }
  }

  private loadBooleanMap(key: string): Record<string, boolean> {
    try {
      const raw = this.storage.getItem(key);
      if (!raw) return {};
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const out: Record<string, boolean> = {};
      for (const [k, v] of Object.entries(parsed)) {
        if (typeof v === "boolean") out[k] = v;
      }
      return out;
    } catch {
      return {};
    }
  }

  private persistBooleanMap(key: string, map: Readonly<Record<string, boolean>>): void {
    try {
      this.storage.setItem(key, JSON.stringify(map));
    } catch {
    }
  }
}

function shallowEqualBooleanMap(
  a: Readonly<Record<string, boolean>>,
  b: Readonly<Record<string, boolean>>,
): boolean {
  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  if (keysA.length !== keysB.length) return false;
  for (const k of keysA) {
    if (a[k] !== b[k]) return false;
  }
  return true;
}

export function localStartOfDayMs(timestampMs: number): number {
  const d = new Date(timestampMs);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function addLocalDaysMs(dayStartMs: number, deltaDays: number): number {
  const d = new Date(dayStartMs);
  d.setDate(d.getDate() + deltaDays);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export interface OfflineOutageSpan {
  readonly startMs: number;
  endMs: number;
  ongoing: boolean;
}

export interface OfflineDeviceLedgerSummary {
  readonly deviceId: string;
  readonly daysOffline: number;
  readonly outageCount: number;
  readonly offlineDurationMs: number;
}

export class OfflineHistory {
  public static readonly retentionDays = 14;
  public static readonly storageKey = "offline_day_history_v1";
  public static readonly spansStorageKey = "offline_outage_spans_v1";

  private readonly storage: KeyValueStorageLike;
  private daysByDevice = new Map<string, Set<number>>();
  private spansByDevice = new Map<string, OfflineOutageSpan[]>();

  constructor(storage: KeyValueStorageLike = defaultSafetyStorage()) {
    this.storage = storage;
    this.load();
  }

  public record(devices: readonly SmartDevice[], nowMs = Date.now()): void {
    const todayMs = localStartOfDayMs(nowMs);
    let changed = this.trim(nowMs);

    for (const dev of devices) {
      if (!dev.isOnline) {
        let daySet = this.daysByDevice.get(dev.id);
        if (!daySet) {
          daySet = new Set<number>();
          this.daysByDevice.set(dev.id, daySet);
        }
        if (!daySet.has(todayMs)) {
          daySet.add(todayMs);
          changed = true;
        }

        let spans = this.spansByDevice.get(dev.id);
        if (!spans) {
          spans = [];
          this.spansByDevice.set(dev.id, spans);
        }
        const last = spans[spans.length - 1];
        if (last && last.ongoing) {
          if (nowMs > last.endMs) {
            last.endMs = nowMs;
            changed = true;
          }
        } else {
          spans.push({ startMs: nowMs, endMs: nowMs, ongoing: true });
          changed = true;
        }
      } else {
        const spans = this.spansByDevice.get(dev.id);
        const last = spans?.[spans.length - 1];
        if (last && last.ongoing) {
          if (nowMs > last.endMs) {
            last.endMs = nowMs;
          }
          last.ongoing = false;
          changed = true;
        }
      }
    }

    if (changed) {
      this.persist();
    }
  }

  public offlineDays(dayCount = 7, nowMs = Date.now()): Record<string, number> {
    const clamped = Math.min(Math.max(Math.trunc(dayCount), 1), OfflineHistory.retentionDays);
    const todayMs = localStartOfDayMs(nowMs);
    const firstMs = addLocalDaysMs(todayMs, -(clamped - 1));
    const out: Record<string, number> = {};
    for (const [deviceId, set] of this.daysByDevice.entries()) {
      let count = 0;
      for (const dayMs of set) {
        if (dayMs >= firstMs && dayMs <= todayMs) count += 1;
      }
      if (count > 0) out[deviceId] = count;
    }
    return out;
  }

  public deviceSummaries(
    dayCount = OfflineHistory.retentionDays,
    nowMs = Date.now(),
  ): Record<string, OfflineDeviceLedgerSummary> {
    const clamped = Math.min(Math.max(Math.trunc(dayCount), 1), OfflineHistory.retentionDays);
    const todayMs = localStartOfDayMs(nowMs);
    const windowStartMs = addLocalDaysMs(todayMs, -(clamped - 1));
    const daysMap = this.offlineDays(clamped, nowMs);
    const allIds = new Set<string>([...Object.keys(daysMap), ...this.spansByDevice.keys()]);
    const result: Record<string, OfflineDeviceLedgerSummary> = {};

    for (const id of allIds) {
      const daysOffline = daysMap[id] ?? 0;
      const spans = this.spansByDevice.get(id) ?? [];
      let outageCount = 0;
      let offlineDurationMs = 0;
      for (const span of spans) {
        const effectiveEnd = span.ongoing ? Math.max(span.endMs, nowMs) : span.endMs;
        if (effectiveEnd < windowStartMs || span.startMs > nowMs) continue;
        outageCount += 1;
        const clippedStart = Math.max(span.startMs, windowStartMs);
        const clippedEnd = Math.min(effectiveEnd, nowMs);
        if (clippedEnd > clippedStart) {
          offlineDurationMs += clippedEnd - clippedStart;
        }
      }
      if (daysOffline > 0 || outageCount > 0) {
        result[id] = {
          deviceId: id,
          daysOffline,
          outageCount,
          offlineDurationMs,
        };
      }
    }
    return result;
  }

  public clear(): void {
    this.daysByDevice.clear();
    this.spansByDevice.clear();
    try {
      this.storage.removeItem(OfflineHistory.storageKey);
      this.storage.removeItem(OfflineHistory.spansStorageKey);
    } catch {
    }
  }

  private trim(nowMs: number): boolean {
    const todayMs = localStartOfDayMs(nowMs);
    const cutoffMs = addLocalDaysMs(todayMs, -(OfflineHistory.retentionDays - 1));
    let changed = false;

    for (const [id, set] of [...this.daysByDevice.entries()]) {
      for (const dayMs of [...set]) {
        if (dayMs < cutoffMs) {
          set.delete(dayMs);
          changed = true;
        }
      }
      if (set.size === 0) {
        this.daysByDevice.delete(id);
        changed = true;
      }
    }

    for (const [id, spans] of [...this.spansByDevice.entries()]) {
      const kept: OfflineOutageSpan[] = [];
      for (const span of spans) {
        const effectiveEnd = span.ongoing ? Math.max(span.endMs, nowMs) : span.endMs;
        if (effectiveEnd < cutoffMs) {
          changed = true;
          continue;
        }
        if (span.startMs < cutoffMs) {
          kept.push({ startMs: cutoffMs, endMs: effectiveEnd, ongoing: span.ongoing });
          changed = true;
        } else {
          kept.push(span);
        }
      }
      if (kept.length === 0) {
        this.spansByDevice.delete(id);
        changed = true;
      } else {
        this.spansByDevice.set(id, kept);
      }
    }
    return changed;
  }

  private load(): void {
    try {
      const rawDays = this.storage.getItem(OfflineHistory.storageKey);
      if (rawDays) {
        const parsed = JSON.parse(rawDays) as Record<string, unknown>;
        for (const [id, list] of Object.entries(parsed)) {
          if (!Array.isArray(list)) continue;
          const set = new Set<number>();
          for (const entry of list) {
            if (typeof entry === "number" && Number.isFinite(entry)) {
              const ms = entry < 1e11 ? entry * 1000 : entry;
              set.add(localStartOfDayMs(ms));
            }
          }
          if (set.size > 0) this.daysByDevice.set(id, set);
        }
      }
    } catch {
      this.daysByDevice.clear();
    }

    try {
      const rawSpans = this.storage.getItem(OfflineHistory.spansStorageKey);
      if (rawSpans) {
        const parsed = JSON.parse(rawSpans) as Record<string, unknown>;
        for (const [id, list] of Object.entries(parsed)) {
          if (!Array.isArray(list)) continue;
          const spans: OfflineOutageSpan[] = [];
          for (const item of list) {
            if (!item || typeof item !== "object") continue;
            const obj = item as Record<string, unknown>;
            if (typeof obj.startMs === "number" && typeof obj.endMs === "number") {
              spans.push({
                startMs: obj.startMs,
                endMs: Math.max(obj.startMs, obj.endMs),
                ongoing: Boolean(obj.ongoing),
              });
            }
          }
          if (spans.length > 0) this.spansByDevice.set(id, spans);
        }
      }
    } catch {
      this.spansByDevice.clear();
    }
  }

  private persist(): void {
    try {
      const serializedDays: Record<string, number[]> = {};
      for (const [id, set] of this.daysByDevice.entries()) {
        serializedDays[id] = [...set].map((ms) => Math.floor(ms / 1000)).sort((a, b) => a - b);
      }
      this.storage.setItem(OfflineHistory.storageKey, JSON.stringify(serializedDays));

      const serializedSpans: Record<string, OfflineOutageSpan[]> = {};
      for (const [id, spans] of this.spansByDevice.entries()) {
        serializedSpans[id] = spans;
      }
      this.storage.setItem(OfflineHistory.spansStorageKey, JSON.stringify(serializedSpans));
    } catch {
    }
  }
}

export interface HealthEnergyDayTotal {
  readonly kwh: number;
  readonly isObserved: boolean;
}

export interface HealthEnergyDeviceTotal {
  readonly id?: string;
  readonly name: string;
  readonly kwh: number;
}

export interface HealthSensorMetricSummary {
  readonly min: number;
  readonly max: number;
}

export interface HealthClimateRange {
  readonly temperature?: HealthSensorMetricSummary | null;
  readonly humidity?: HealthSensorMetricSummary | null;
}

export type HealthClimateWarning =
  | { readonly kind: "tooHumid"; readonly value: number }
  | { readonly kind: "tooDry"; readonly value: number }
  | { readonly kind: "tooHot"; readonly value: number }
  | { readonly kind: "tooCold"; readonly value: number };

export interface HealthRoomClimate {
  readonly deviceName: string;
  readonly roomName: string;
  readonly range: HealthClimateRange;
  readonly warnings: readonly HealthClimateWarning[];
}

export type HealthMaintenanceItem =
  | { readonly kind: "filter"; readonly percent: number }
  | { readonly kind: "battery"; readonly percent: number };

export interface HealthMaintenance {
  readonly deviceName: string;
  readonly roomName: string;
  readonly item: HealthMaintenanceItem;
}

export interface HealthOfflineDevice {
  readonly deviceId: string;
  readonly deviceName: string;
  readonly roomName: string;
  readonly daysOffline: number | null;
  readonly outageCount: number;
  readonly offlineDurationMs: number;
  readonly isOfflineNow: boolean;
}

export interface HealthStandbyConsumer {
  readonly deviceId: string;
  readonly deviceName: string;
  readonly roomName: string;
  readonly powerWatts: number;
}

export interface HealthEnergySummary {
  readonly thisWeekKwh: number;
  readonly lastWeekKwh: number | null;
  readonly changePercent: number | null;
  readonly topConsumers: readonly HealthEnergyDeviceTotal[];
}

export interface WeeklyHealthReport {
  readonly energy: HealthEnergySummary | null;
  readonly climate: readonly HealthRoomClimate[];
  readonly maintenance: readonly HealthMaintenance[];
  readonly offlineDevices: readonly HealthOfflineDevice[];
  readonly standbyConsumers: readonly HealthStandbyConsumer[];
  readonly unreliableRooms: readonly string[];
}

export const WEEKLY_HEALTH_CONSTANTS = {
  humidityMin: 30.0,
  humidityMax: 70.0,
  temperatureMin: 16.0,
  temperatureMax: 30.0,
  batteryThreshold: 20,
  filterThreshold: 10,
  topConsumerCount: 3,
  frequentOfflineDays: 2,
  standbyWattsThreshold: 1.0,
  unreliableRoomDeviceCount: 2,
  unreliableRoomOfflineDays: 3,
} as const;

function collectClimateWarnings(range: HealthClimateRange): HealthClimateWarning[] {
  const warnings: HealthClimateWarning[] = [];
  if (range.humidity) {
    if (range.humidity.max > WEEKLY_HEALTH_CONSTANTS.humidityMax) warnings.push({ kind: "tooHumid", value: range.humidity.max });
    if (range.humidity.min < WEEKLY_HEALTH_CONSTANTS.humidityMin) warnings.push({ kind: "tooDry", value: range.humidity.min });
  }
  if (range.temperature) {
    if (range.temperature.max > WEEKLY_HEALTH_CONSTANTS.temperatureMax) warnings.push({ kind: "tooHot", value: range.temperature.max });
    if (range.temperature.min < WEEKLY_HEALTH_CONSTANTS.temperatureMin) warnings.push({ kind: "tooCold", value: range.temperature.min });
  }
  return warnings;
}

function collectMaintenanceForDevice(dev: SmartDevice): HealthMaintenance | null {
  if (!dev.isOnline) return null;
  const k = dev.kind;
  if (k.kind === "fan" && k.filterLifePercent != null && k.filterLifePercent <= WEEKLY_HEALTH_CONSTANTS.filterThreshold) {
    return { deviceName: dev.name, roomName: dev.roomName, item: { kind: "filter", percent: Math.round(k.filterLifePercent) } };
  }
  if (k.kind === "sensor" && k.battery != null && k.battery > 0 && k.battery <= WEEKLY_HEALTH_CONSTANTS.batteryThreshold) {
    return { deviceName: dev.name, roomName: dev.roomName, item: { kind: "battery", percent: Math.round(k.battery) } };
  }
  if (k.kind === "cover" && k.batteryPercent != null && k.batteryPercent > 0 && k.batteryPercent <= WEEKLY_HEALTH_CONSTANTS.batteryThreshold) {
    return { deviceName: dev.name, roomName: dev.roomName, item: { kind: "battery", percent: Math.round(k.batteryPercent) } };
  }
  if (k.kind === "vacuum" && k.battery != null && k.battery >= 0 && k.battery <= WEEKLY_HEALTH_CONSTANTS.batteryThreshold) {
    return { deviceName: dev.name, roomName: dev.roomName, item: { kind: "battery", percent: Math.round(k.battery) } };
  }
  return null;
}

export function buildWeeklyHealthReport(args: {
  readonly devices: readonly SmartDevice[];
  readonly dailyEnergy?: readonly HealthEnergyDayTotal[];
  readonly energyByDevice?: readonly HealthEnergyDeviceTotal[];
  readonly climate?: Readonly<Record<string, HealthClimateRange>>;
  readonly offlineDays?: Readonly<Record<string, number>>;
  readonly offlineLedger?: Readonly<Record<string, OfflineDeviceLedgerSummary>>;
  readonly offlineHistory?: OfflineHistory;
  readonly nowMs?: number;
}): WeeklyHealthReport {
  const nowMs = args.nowMs ?? Date.now();
  const offlineDays = args.offlineDays ?? (args.offlineHistory ? args.offlineHistory.offlineDays(7, nowMs) : {});
  const offlineLedger = args.offlineLedger ?? (args.offlineHistory ? args.offlineHistory.deviceSummaries(14, nowMs) : {});

  let energy: HealthEnergySummary | null = null;
  const dailyEnergy = args.dailyEnergy ?? [];
  const thisWeek = dailyEnergy.slice(-7);
  const lastWeek = dailyEnergy.slice(0, Math.max(0, dailyEnergy.length - 7)).slice(-7);
  if (thisWeek.some((d) => d.isObserved)) {
    const thisWeekKwh = thisWeek.reduce((sum, d) => sum + d.kwh, 0);
    const lastWeekKwh = lastWeek.some((d) => d.isObserved) ? lastWeek.reduce((sum, d) => sum + d.kwh, 0) : null;
    const changePercent = lastWeekKwh !== null && lastWeekKwh > 0 ? ((thisWeekKwh - lastWeekKwh) / lastWeekKwh) * 100 : null;
    energy = {
      thisWeekKwh,
      lastWeekKwh,
      changePercent,
      topConsumers: (args.energyByDevice ?? []).slice(0, WEEKLY_HEALTH_CONSTANTS.topConsumerCount),
    };
  }

  const climateMap = args.climate ?? {};
  const climate: HealthRoomClimate[] = [];
  for (const dev of args.devices) {
    const range = climateMap[dev.id];
    if (!range || (!range.temperature && !range.humidity)) continue;
    climate.push({ deviceName: dev.name, roomName: dev.roomName, range, warnings: collectClimateWarnings(range) });
  }

  const maintenanceIndexed: { entry: HealthMaintenance; idx: number }[] = [];
  args.devices.forEach((dev, idx) => {
    const item = collectMaintenanceForDevice(dev);
    if (item) maintenanceIndexed.push({ entry: item, idx });
  });
  maintenanceIndexed.sort((a, b) => (a.entry.item.percent !== b.entry.item.percent ? a.entry.item.percent - b.entry.item.percent : a.idx - b.idx));
  const maintenance = maintenanceIndexed.map((x) => x.entry);

  const offlineDevices: HealthOfflineDevice[] = [];
  for (const dev of args.devices) {
    const days = offlineDays[dev.id];
    const ledger = offlineLedger[dev.id];
    const outageCount = ledger?.outageCount ?? (days ?? (!dev.isOnline ? 1 : 0));
    const offlineDurationMs = ledger?.offlineDurationMs ?? 0;
    if (!dev.isOnline || (days ?? 0) >= WEEKLY_HEALTH_CONSTANTS.frequentOfflineDays || outageCount >= WEEKLY_HEALTH_CONSTANTS.frequentOfflineDays) {
      offlineDevices.push({
        deviceId: dev.id,
        deviceName: dev.name,
        roomName: dev.roomName,
        daysOffline: days ?? (ledger && ledger.daysOffline > 0 ? ledger.daysOffline : null),
        outageCount,
        offlineDurationMs,
        isOfflineNow: !dev.isOnline,
      });
    }
  }

  const standbyConsumers: HealthStandbyConsumer[] = [];
  for (const dev of args.devices) {
    if (dev.isOnline && dev.kind.kind === "plug" && !dev.kind.isOn && dev.kind.powerWatts !== null && dev.kind.powerWatts >= WEEKLY_HEALTH_CONSTANTS.standbyWattsThreshold) {
      standbyConsumers.push({ deviceId: dev.id, deviceName: dev.name, roomName: dev.roomName, powerWatts: dev.kind.powerWatts });
    }
  }
  standbyConsumers.sort((a, b) => (a.powerWatts !== b.powerWatts ? b.powerWatts - a.powerWatts : a.roomName !== b.roomName ? a.roomName.localeCompare(b.roomName) : a.deviceName.localeCompare(b.deviceName)));

  const roomCounts = new Map<string, number>();
  for (const dev of args.devices) {
    const room = dev.roomName.trim();
    if (!room) continue;
    const days = offlineDays[dev.id] ?? 0;
    const outages = offlineLedger[dev.id]?.outageCount ?? 0;
    if (!dev.isOnline || days >= WEEKLY_HEALTH_CONSTANTS.unreliableRoomOfflineDays || outages >= WEEKLY_HEALTH_CONSTANTS.unreliableRoomOfflineDays) {
      roomCounts.set(room, (roomCounts.get(room) ?? 0) + 1);
    }
  }
  const unreliableRooms = [...roomCounts.entries()]
    .filter(([, count]) => count >= WEEKLY_HEALTH_CONSTANTS.unreliableRoomDeviceCount)
    .map(([room]) => room)
    .sort((a, b) => a.localeCompare(b));

  return { energy, climate, maintenance, offlineDevices, standbyConsumers, unreliableRooms };
}

function formatReportNumber(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  return Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1);
}

function formatReportKwh(value: number): string {
  return `${formatReportNumber(value)} kWh`;
}

function formatSignedPercent(percent: number): string {
  const rounded = Math.round(percent);
  return rounded > 0 ? `+${rounded}%` : `${rounded}%`;
}

function formatOfflineDuration(durationMs: number, preference?: LanguagePreference): string {
  if (durationMs <= 0) return "";
  const totalMinutes = Math.max(1, Math.round(durationMs / 60_000));
  if (totalMinutes < 60) {
    return tr3("累计 {min} 分钟", "累計 {min} 分鐘", "{min}m total", { min: totalMinutes }, preference);
  }
  const hText = formatReportNumber(Math.round((totalMinutes / 60) * 10) / 10);
  return tr3("累计 {hours} 小时", "累計 {hours} 小時", "{hours}h total", { hours: hText }, preference);
}

export function weeklyHealthNotificationSummary(
  report: WeeklyHealthReport,
  preference?: LanguagePreference,
): string {
  const parts: string[] = [];
  if (report.energy) {
    const kwh = formatReportKwh(report.energy.thisWeekKwh);
    const change =
      report.energy.changePercent !== null
        ? tr3("（比上周 {delta}）", "（比上週 {delta}）", " ({delta} vs last week)", { delta: formatSignedPercent(report.energy.changePercent) }, preference)
        : "";
    parts.push(tr3("本周用电 {kwh}{change}", "本週用電 {kwh}{change}", "Energy {kwh}{change}", { kwh, change }, preference));
  }
  const warningRooms = report.climate.filter((c) => c.warnings.length > 0).length;
  if (warningRooms > 0) {
    parts.push(tr3("{count} 处温湿度异常", "{count} 處溫濕度異常", "{count} climate alerts", { count: warningRooms }, preference));
  }
  if (report.maintenance.length > 0) {
    parts.push(tr3("{count} 台待更换", "{count} 台待更換", "{count} need replacing", { count: report.maintenance.length }, preference));
  }
  if (report.offlineDevices.length > 0) {
    parts.push(tr3("{count} 台离线", "{count} 台離線", "{count} offline", { count: report.offlineDevices.length }, preference));
  }
  if (report.standbyConsumers.length > 0) {
    parts.push(tr3("待机耗电 {count} 台", "待機耗電 {count} 台", "{count} on standby", { count: report.standbyConsumers.length }, preference));
  }
  if (parts.length === 0) {
    return tr3("本周一切正常", "本週一切正常", "All clear this week", undefined, preference);
  }
  return parts.join(" · ");
}

function renderStandbyLines(
  standbyConsumers: readonly HealthStandbyConsumer[],
  preference?: LanguagePreference,
): string[] {
  return standbyConsumers.map((consumer) => {
    const location = consumer.roomName.trim() ? `${consumer.roomName} · ${consumer.deviceName}` : consumer.deviceName;
    const watts = consumer.powerWatts.toFixed(1);
    return tr3(
      "- 待机耗电提醒：{location} (关闭状态仍消耗 {watts} W)",
      "- 待機耗電提醒：{location} (關閉狀態仍消耗 {watts} W)",
      "- Standby power alert: {location} (drawing {watts} W while off)",
      { location, watts },
      preference,
    );
  });
}

function describeClimateWarning(warning: HealthClimateWarning, preference?: LanguagePreference): string {
  const v = formatReportNumber(warning.value);
  switch (warning.kind) {
    case "tooHumid":
      return tr3("最高湿度 {v}%，偏潮", "最高濕度 {v}%，偏潮", "humidity peaked at {v}%", { v }, preference);
    case "tooDry":
      return tr3("最低湿度 {v}%，偏干", "最低濕度 {v}%，偏乾", "humidity fell to {v}%", { v }, preference);
    case "tooHot":
      return tr3("最高 {v}°C，偏热", "最高 {v}°C，偏熱", "peaked at {v}°C", { v }, preference);
    case "tooCold":
      return tr3("最低 {v}°C，偏冷", "最低 {v}°C，偏冷", "fell to {v}°C", { v }, preference);
  }
}

export function renderWeeklyHealthMarkdown(
  report: WeeklyHealthReport,
  preference?: LanguagePreference,
): string {
  const lang: AppLanguage =
    preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : currentLanguage();
  const isEn = lang === "en";
  const colon = isEn ? ": " : "：";
  const comma = isEn ? ", " : "，";
  const listSep = isEn ? ", " : "、";

  const lines: string[] = [
    tr3("# 家庭健康周报", "# 家庭健康週報", "# Weekly Home Health Report", undefined, lang),
    "",
  ];

  if (report.energy) {
    lines.push(tr3("## 用电", "## 用電", "## Energy", undefined, lang));
    let total = tr3("本周 {kwh}", "本週 {kwh}", "This week {kwh}", { kwh: formatReportKwh(report.energy.thisWeekKwh) }, lang);
    if (report.energy.changePercent !== null) {
      total += tr3("，比上周 {delta}", "，比上週 {delta}", ", {delta} vs last week", { delta: formatSignedPercent(report.energy.changePercent) }, lang);
    }
    lines.push(total);
    if (report.energy.topConsumers.length > 0) {
      lines.push("");
      lines.push(tr3("耗电最多：", "耗電最多：", "Top consumers:", undefined, lang));
      for (const item of report.energy.topConsumers) {
        lines.push(`- ${item.name}${colon}${formatReportKwh(item.kwh)}`);
      }
    }
    if (report.standbyConsumers.length > 0) {
      lines.push("");
      lines.push(...renderStandbyLines(report.standbyConsumers, lang));
    }
    lines.push("");
  } else if (report.standbyConsumers.length > 0) {
    lines.push(tr3("## 用电", "## 用電", "## Energy", undefined, lang));
    lines.push(...renderStandbyLines(report.standbyConsumers, lang));
    lines.push("");
  }

  if (report.climate.length > 0) {
    lines.push(tr3("## 温湿度", "## 溫濕度", "## Temperature & Humidity", undefined, lang));
    for (const room of report.climate) {
      const parts: string[] = [];
      if (room.range.temperature) {
        parts.push(`${formatReportNumber(room.range.temperature.min)}–${formatReportNumber(room.range.temperature.max)}°C`);
      }
      if (room.range.humidity) {
        parts.push(`${formatReportNumber(room.range.humidity.min)}–${formatReportNumber(room.range.humidity.max)}%`);
      }
      let line = `- ${room.roomName} · ${room.deviceName}${colon}${parts.join(comma)}`;
      if (room.warnings.length > 0) {
        const desc = room.warnings.map((w) => describeClimateWarning(w, lang)).join(listSep);
        line += isEn ? ` (${desc})` : `（${desc}）`;
      }
      lines.push(line);
    }
    lines.push("");
  }

  if (report.maintenance.length > 0) {
    lines.push(tr3("## 需要更换", "## 需要更換", "## Needs Replacing", undefined, lang));
    for (const m of report.maintenance) {
      const what =
        m.item.kind === "battery"
          ? tr3("电池 {p}%", "電池 {p}%", "battery {p}%", { p: m.item.percent }, lang)
          : tr3("滤芯 {p}%", "濾芯 {p}%", "filter {p}%", { p: m.item.percent }, lang);
      lines.push(`- ${m.roomName} · ${m.deviceName}${colon}${what}`);
    }
    lines.push("");
  }

  if (report.offlineDevices.length > 0) {
    lines.push(tr3("## 离线设备", "## 離線設備", "## Offline Devices", undefined, lang));
    for (const device of report.offlineDevices) {
      const durationText = formatOfflineDuration(device.offlineDurationMs, lang);
      const extraParts: string[] = [];
      if (device.outageCount > 0) {
        extraParts.push(tr3("掉线 {count} 次", "斷線 {count} 次", "{count} outages", { count: device.outageCount }, lang));
      }
      if (durationText) extraParts.push(durationText);
      const suffixDetail = extraParts.length > 0 ? `${comma}${extraParts.join(comma)}` : "";

      const note = device.isOfflineNow
        ? tr3("（现在离线{detail}）", "（現在離線{detail}）", " (offline now{detail})", { detail: suffixDetail }, lang)
        : tr3("（本周 {days} 天出现离线{detail}）", "（本週 {days} 天出現離線{detail}）", " (dropped offline on {days} days{detail})", { days: device.daysOffline ?? 0, detail: suffixDetail }, lang);
      lines.push(`- ${device.roomName} · ${device.deviceName}${note}`);
    }
    if (report.unreliableRooms.length > 0) {
      const rooms = report.unreliableRooms.join(listSep);
      lines.push(tr3("- 建议排查网络/网关信号的房间：{rooms}", "- 建議排查網路/網關訊號的房間：{rooms}", "- Rooms recommended for Wi-Fi/gateway check: {rooms}", { rooms }, lang));
    }
    lines.push("");
  }

  if (
    report.energy === null &&
    report.climate.length === 0 &&
    report.maintenance.length === 0 &&
    report.offlineDevices.length === 0 &&
    report.standbyConsumers.length === 0 &&
    report.unreliableRooms.length === 0
  ) {
    lines.push(tr3("本周一切正常", "本週一切正常", "All clear this week", undefined, lang));
    lines.push("");
  }

  return lines.join("\n");
}

export class WeeklyHealthReportSchedule {
  public static readonly weekday = 0;
  public static readonly hour = 20;
  public static readonly catchUpWindowMs = 2 * 24 * 60 * 60 * 1000;
  public static readonly deliveredAtStorageKey = "weekly_health_report_delivered_at_v1";

  public static latestSlotMs(nowMs: number): number {
    const d = new Date(nowMs);
    const dayOfWeek = d.getDay();
    const candidate = new Date(nowMs);
    candidate.setDate(d.getDate() - dayOfWeek);
    candidate.setHours(WeeklyHealthReportSchedule.hour, 0, 0, 0);
    if (candidate.getTime() > nowMs) {
      candidate.setDate(candidate.getDate() - 7);
      candidate.setHours(WeeklyHealthReportSchedule.hour, 0, 0, 0);
    }
    return candidate.getTime();
  }

  public static isDue(nowMs: number, lastDeliveredAtMs: number | null): boolean {
    const slotMs = WeeklyHealthReportSchedule.latestSlotMs(nowMs);
    if (slotMs > nowMs) return false;
    if (nowMs - slotMs >= WeeklyHealthReportSchedule.catchUpWindowMs) return false;
    const delivered = lastDeliveredAtMs ?? Number.NEGATIVE_INFINITY;
    return delivered < slotMs;
  }

  public static loadLastDeliveredAtMs(
    storage: KeyValueStorageLike = defaultSafetyStorage(),
  ): number | null {
    try {
      const raw = storage.getItem(WeeklyHealthReportSchedule.deliveredAtStorageKey);
      if (!raw) return null;
      const num = Number(raw);
      return Number.isFinite(num) ? num : null;
    } catch {
      return null;
    }
  }

  public static markDelivered(
    nowMs: number,
    storage: KeyValueStorageLike = defaultSafetyStorage(),
  ): void {
    try {
      storage.setItem(WeeklyHealthReportSchedule.deliveredAtStorageKey, String(nowMs));
    } catch {
    }
  }
}
