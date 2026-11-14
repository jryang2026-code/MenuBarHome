import type { MiSession } from "../core/miCloud/session.js";
import { inferFallbackSpec } from "../core/miCloud/spec.js";
import { hasDetailDrawer, type FacetControl, type SmartDevice } from "../core/models.js";
import {
  availableSensorMetrics,
  extractSensorLiveMetrics,
  fetchHomeAssistantSensorHistory,
  fetchMiCloudSensorHistory,
  pointMetricRange,
  pointMetricValue,
  resolveHomeAssistantSensorEntityIds,
  resolveMiotSensorPropertyKeys,
  resolveSensorHistoryScope,
  sharedSensorHistoryStore,
  type SensorHistoryPoint,
  type SensorHistoryStore,
  type SensorHistoryWindow,
  type SensorMetricKind,
} from "../core/sensorHistory.js";
import {
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  temperatureSymbol,
  toDisplayTemperature,
  type TemperatureUnit,
} from "../core/temperature.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import {
  getHostDualSourceState,
  getHostMiAccountsState,
  isDualSourceEnabled,
} from "./cloudRefresh.js";
import { seedDemoSensorHistory } from "./demo.js";
import { comfort, tr3 } from "./panelPrefs.js";

export interface CubicPoint {
  readonly x: number;
  readonly y: number;
  readonly slotIndex: number;
}

const SVG_WIDTH = 320;
const SVG_HEIGHT = 112;
const PLOT_LEFT = 8;
const PLOT_RIGHT = 312;
const PLOT_TOP = 12;
const PLOT_BOTTOM = 98;
const PLOT_WIDTH = PLOT_RIGHT - PLOT_LEFT;
const PLOT_HEIGHT = PLOT_BOTTOM - PLOT_TOP;

export interface SensorHistoryUiState {
  scopeKey: string | null;
  lastExpandedId: string | null;
  lastRecordedDevicesRef: readonly SmartDevice[] | null;
  recordedBatchSeq: number;
  isSyncingHost: boolean;
  readonly windowByDevice: Map<string, SensorHistoryWindow>;
  readonly metricByDevice: Map<string, SensorMetricKind>;
  readonly hoveredSlotByDevice: Map<string, number>;
}

export function createSensorHistoryUiState(): SensorHistoryUiState {
  return {
    scopeKey: null,
    lastExpandedId: null,
    lastRecordedDevicesRef: null,
    recordedBatchSeq: 0,
    isSyncingHost: false,
    windowByDevice: new Map<string, SensorHistoryWindow>(),
    metricByDevice: new Map<string, SensorMetricKind>(),
    hoveredSlotByDevice: new Map<string, number>(),
  };
}

function getHostSensorHistoryUi(host: MenuMijiaWindowsApp): SensorHistoryUiState {
  if (!host.sensorHistoryUi) {
    host.sensorHistoryUi = createSensorHistoryUiState();
  }
  return host.sensorHistoryUi;
}

export function resetSensorHistoryUiState(
  target?: SensorHistoryUiState | { readonly sensorHistoryUi?: SensorHistoryUiState } | null,
): void {
  if (!target) return;
  const state =
    "windowByDevice" in target ? target : (target.sensorHistoryUi ?? null);
  if (!state) return;
  state.windowByDevice.clear();
  state.metricByDevice.clear();
  state.hoveredSlotByDevice.clear();
  state.lastExpandedId = null;
  state.lastRecordedDevicesRef = null;
}

function clamp(value: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, value));
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

export function buildSmoothCubicBezierPath(points: ReadonlyArray<{ readonly x: number; readonly y: number }>): string {
  if (points.length === 0) return "";
  const first = points[0]!;
  if (points.length === 1) {
    return `M ${round2(first.x)} ${round2(first.y)}`;
  }
  const cmds: string[] = [`M ${round2(first.x)} ${round2(first.y)}`];
  const tension = 0.2;
  for (let i = 0; i < points.length - 1; i += 1) {
    const p0 = points[Math.max(0, i - 1)]!;
    const p1 = points[i]!;
    const p2 = points[i + 1]!;
    const p3 = points[Math.min(points.length - 1, i + 2)]!;
    const minX = Math.min(p1.x, p2.x);
    const maxX = Math.max(p1.x, p2.x);
    const cp1x = round2(clamp(p1.x + (p2.x - p0.x) * tension, minX, maxX));
    const cp1y = round2(clamp(p1.y + (p2.y - p0.y) * tension, PLOT_TOP, PLOT_BOTTOM));
    const cp2x = round2(clamp(p2.x - (p3.x - p1.x) * tension, minX, maxX));
    const cp2y = round2(clamp(p2.y - (p3.y - p1.y) * tension, PLOT_TOP, PLOT_BOTTOM));
    cmds.push(`C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${round2(p2.x)} ${round2(p2.y)}`);
  }
  return cmds.join(" ");
}

function buildRangeBandPath(
  upper: ReadonlyArray<{ readonly x: number; readonly y: number }>,
  lower: ReadonlyArray<{ readonly x: number; readonly y: number }>,
): string {
  if (upper.length < 2 || upper.length !== lower.length) return "";
  const topCurve = buildSmoothCubicBezierPath(upper);
  const reversedLower = [...lower].reverse();
  const bottomCurve = buildSmoothCubicBezierPath(reversedLower).replace(/^M\s+/, "L ");
  return `${topCurve} ${bottomCurve} Z`;
}

function metricLabel(metric: SensorMetricKind): string {
  switch (metric) {
    case "temperature":
      return tr3("温度", "溫度", "Temp");
    case "humidity":
      return tr3("湿度", "濕度", "Humidity");
    case "pm25":
      return "PM2.5";
    case "illuminance":
      return tr3("光照", "光照", "Lux");
  }
}

function metricAccentColor(metric: SensorMetricKind, latestRaw: number | null): string {
  switch (metric) {
    case "temperature":
      return "#ff9500";
    case "humidity":
      return "#32ade6";
    case "pm25":
      return latestRaw !== null && latestRaw > 75 ? "#ff9f0a" : "#30d158";
    case "illuminance":
      return "#ffd60a";
  }
}

function toDisplayMetricNumber(rawValue: number, metric: SensorMetricKind, tempUnit: TemperatureUnit): number {
  if (metric === "temperature") {
    return Math.round(toDisplayTemperature(rawValue, tempUnit) * 10) / 10;
  }
  return Math.round(rawValue * 10) / 10;
}

export function formatSensorMetricValue(
  rawValue: number | null,
  metric: SensorMetricKind,
  tempUnit: TemperatureUnit = getTemperatureUnit(),
): string {
  if (rawValue === null || !Number.isFinite(rawValue)) return "--";
  switch (metric) {
    case "temperature":
      return formatTemperature(rawValue, tempUnit, 1);
    case "humidity":
      return `${Math.round(rawValue)}%`;
    case "pm25":
      return `${Math.round(rawValue)} μg/m³`;
    case "illuminance":
      return `${Math.round(rawValue)} lx`;
  }
}

function formatAxisBound(rawValue: number, metric: SensorMetricKind, tempUnit: TemperatureUnit): string {
  if (!Number.isFinite(rawValue)) return "";
  switch (metric) {
    case "temperature":
      return `${formatTemperatureValue(rawValue, tempUnit, 1)}${temperatureSymbol(tempUnit)}`;
    case "humidity":
      return `${Math.round(rawValue)}%`;
    case "pm25":
      return `${Math.round(rawValue)}`;
    case "illuminance":
      return `${Math.round(rawValue)} lx`;
  }
}

function metricComfortBadge(
  metric: SensorMetricKind,
  latestValue: number | null,
  liveTemp: number | null,
  liveHum: number | null,
): { readonly label: string; readonly level: string } | null {
  if (metric === "temperature" || metric === "humidity") {
    const tVal = metric === "temperature" ? (latestValue ?? liveTemp) : liveTemp;
    const hVal = metric === "humidity" ? (latestValue ?? liveHum) : liveHum;
    if (tVal === null && hVal === null) return null;
    return comfort(tVal, hVal);
  }
  if (metric === "pm25" && latestValue !== null) {
    if (latestValue <= 35) return { level: "comfy", label: tr3("空气优", "空氣優", "Good Air") };
    if (latestValue <= 75) return { level: "dry", label: tr3("空气良", "空氣良", "Moderate") };
    return { level: "warm", label: tr3("轻度污染", "輕度污染", "Elevated") };
  }
  if (metric === "illuminance" && latestValue !== null) {
    if (latestValue < 40) return { level: "cool", label: tr3("微光", "微光", "Dim") };
    if (latestValue <= 800) return { level: "comfy", label: tr3("柔和", "柔和", "Comfortable") };
    return { level: "warm", label: tr3("明亮", "明亮", "Bright") };
  }
  return null;
}

function formatSlotTimeLabel(bucketStartMs: number, window: SensorHistoryWindow, isLast: boolean): string {
  const d = new Date(bucketStartMs);
  if (window === "24h") {
    const hh = String(d.getHours()).padStart(2, "0");
    if (isLast) return `${hh}:00 · ${tr3("当前时段", "目前時段", "Current hr")}`;
    return `${d.getMonth() + 1}/${d.getDate()} ${hh}:00`;
  }
  if (isLast) {
    return `${d.getMonth() + 1}/${d.getDate()} · ${tr3("今天", "今天", "Today")}`;
  }
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

function formatAxisTickLabel(bucketStartMs: number, window: SensorHistoryWindow, isLast: boolean): string {
  const d = new Date(bucketStartMs);
  if (window === "24h") {
    return isLast ? tr3("现在", "現在", "Now") : `${String(d.getHours()).padStart(2, "0")}:00`;
  }
  return isLast ? tr3("今天", "今天", "Today") : `${d.getMonth() + 1}/${d.getDate()}`;
}

function sensorSnapshotSignature(devices: readonly SmartDevice[]): string {
  return devices
    .filter((d) => d.kind.kind === "sensor")
    .map((d) => {
      const k = d.kind as Extract<SmartDevice["kind"], { kind: "sensor" }>;
      return `${d.id}:${d.isOnline ? 1 : 0}:${k.temperature ?? ""}:${k.humidity ?? ""}:${k.statusText ?? ""}`;
    })
    .join("|");
}

function canRecordLiveHostSensors(host: MenuMijiaWindowsApp): boolean {
  if (host.valuesAreStale) return false;
  const dual = isDualSourceEnabled(host);
  if (!dual && host.settings.connectionMode === "homeAssistant" && Boolean(host.haConnectionError)) {
    return false;
  }
  if (!dual && host.settings.connectionMode === "xiaomiCloud" && Boolean(host.miSessionExpired)) {
    return false;
  }
  if (
    host.settings.connectionMode !== "demo" &&
    (host.timerSnapshot?.sourceRevision ?? -1) !== host.sourceRevision
  ) {
    const cachedList =
      host.settings.connectionMode === "xiaomiCloud"
        ? host.settings.cachedXiaomiDevices
        : (host.settings.cachedHAHome?.home.devices ?? []);
    const cachedSig = sensorSnapshotSignature(cachedList);
    if (cachedSig !== "" && cachedSig === sensorSnapshotSignature(host.devices)) {
      return false;
    }
  }
  return true;
}

export function hasPlottableSensorMetrics(
  dev: SmartDevice,
  facets: readonly FacetControl[] = [],
  store: SensorHistoryStore = sharedSensorHistoryStore(),
): boolean {
  if (dev.kind.kind !== "sensor") return false;
  const live = extractSensorLiveMetrics(dev, facets);
  if (
    live.temperature !== null ||
    live.humidity !== null ||
    live.pm25 !== null ||
    live.illuminance !== null
  ) {
    return true;
  }
  const pts24 = store.points(dev.id, "24h");
  if (pts24.some((pt) => pt.isObserved)) return true;
  const pts7d = store.points(dev.id, "7d");
  return pts7d.some((pt) => pt.isObserved);
}

export function selectedSensorWindow(
  deviceId: string,
  state?: SensorHistoryUiState,
): SensorHistoryWindow {
  return state?.windowByDevice.get(deviceId) ?? "24h";
}

export function structuralSensorHistoryKey(host: MenuMijiaWindowsApp): string {
  const expandedId = host.expandedDeviceId;
  if (!expandedId) return "";
  const dev = host.devices.find((d) => d.id === expandedId);
  if (!dev || dev.kind.kind !== "sensor") return "";
  const ui = getHostSensorHistoryUi(host);
  const store = sharedSensorHistoryStore();
  const window = selectedSensorWindow(dev.id, ui);
  const metric = ui.metricByDevice.get(dev.id) ?? "default";
  return `${dev.id}:${window}:${metric}:${store.revision}:${store.isLoading(dev.id, window) ? 1 : 0}`;
}

async function discoverHASensorEntitiesViaSnapshot(
  host: MenuMijiaWindowsApp,
  dev: SmartDevice,
  facets: readonly FacetControl[],
): Promise<string[]> {
  const direct = resolveHomeAssistantSensorEntityIds(dev, facets);
  const rawId = dev.id.startsWith("ha:") ? dev.id.slice(3) : dev.id;
  if (rawId.startsWith("sensor.")) return direct;
  const invoke =
    host.haInvokeOverride ??
    (typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined);
  if (!invoke) return direct;
  try {
    const raw = await invoke<Record<string, unknown>>("ha_snapshot", {
      baseUrl: host.settings.haBaseURL,
      token: host.settings.haToken,
    });
    const entities = Array.isArray(raw?.entities)
      ? (raw.entities as ReadonlyArray<{
          readonly entity_id?: unknown;
          readonly device_id?: unknown;
          readonly disabled_by?: unknown;
          readonly hidden_by?: unknown;
        }>)
      : [];
    return resolveHomeAssistantSensorEntityIds(dev, facets, entities);
  } catch {
    return direct;
  }
}

export function extractRawMiCloudDid(deviceId: string): string {
  const slashIdx = deviceId.indexOf("/");
  const afterSlash = slashIdx >= 0 ? deviceId.slice(slashIdx + 1) : deviceId;
  return afterSlash.startsWith("mi:") ? afterSlash.slice(3) : afterSlash;
}

function resolveMiSessionForDevice(
  host: MenuMijiaWindowsApp,
  device: SmartDevice,
  rawDid: string,
): MiSession | null {
  const multiState = getHostMiAccountsState(host);
  const accounts = host.miAccountsOverride ?? multiState?.accounts ?? [];
  if (accounts.length > 0) {
    const candidateAccountIds: string[] = [];
    if (device.accountId) candidateAccountIds.push(device.accountId);
    const ownersByDevId = multiState?.merged?.deviceOwners[device.id];
    if (ownersByDevId) candidateAccountIds.push(...ownersByDevId);
    const ownersByRawDid = multiState?.merged?.deviceOwners[rawDid];
    if (ownersByRawDid) candidateAccountIds.push(...ownersByRawDid);
    const slashIdx = device.id.indexOf("/");
    if (slashIdx > 0 && !device.id.startsWith("ha:")) {
      const rawPrefix = device.id.slice(0, slashIdx);
      candidateAccountIds.push(rawPrefix);
      if (rawPrefix.startsWith("mi:") && rawPrefix.split(":").length > 3) {
        candidateAccountIds.push(rawPrefix.slice(3));
      }
    }
    for (const candidateId of candidateAccountIds) {
      const matched = accounts.find(
        (acc) =>
          acc.id === candidateId ||
          acc.session.userId === candidateId ||
          acc.id.endsWith(`:${candidateId}`),
      );
      if (matched) return matched.session;
    }
  }
  return host.settings.miSession ?? accounts[0]?.session ?? null;
}

function resolveHostHistoryScope(host: MenuMijiaWindowsApp): string {
  const multiState = getHostMiAccountsState(host);
  const accounts = host.miAccountsOverride ?? multiState?.accounts ?? [];
  return resolveSensorHistoryScope({
    connectionMode: host.settings.connectionMode,
    haBaseURL: host.settings.haBaseURL,
    miSession: host.settings.miSession,
    dualSourceEnabled: isDualSourceEnabled(host),
    activeAccountIds: accounts.map((a) => a.id),
  });
}

function isLiveSensorTelemetryDevice(
  dev: SmartDevice,
  staleIds?: ReadonlySet<string>,
  dualRoutes?: Readonly<Record<string, { readonly backend: string; readonly sourceDeviceId: string }>>,
): boolean {
  if (dev.telemetryStale) return false;
  const route = dualRoutes?.[dev.id];
  const backend = route?.backend ?? dev.sourceBackend;
  if (backend === "homeAssistant") return true;
  if (backend === "xiaomiCloud") return !staleIds?.has(route?.sourceDeviceId ?? dev.id);
  return !staleIds?.has(dev.id);
}

function triggerRemoteHistoryFetchIfNeeded(
  host: MenuMijiaWindowsApp,
  dev: SmartDevice,
  window: SensorHistoryWindow,
  store: SensorHistoryStore,
): void {
  const staleIds = getHostMiAccountsState(host)?.merged?.staleDeviceIds;
  const dualActive = isDualSourceEnabled(host);
  const dualState = dualActive ? getHostDualSourceState(host) : null;
  if (
    !dev.isOnline ||
    !isLiveSensorTelemetryDevice(dev, staleIds, dualState?.routes) ||
    host.valuesAreStale ||
    dev.kind.kind !== "sensor"
  ) {
    return;
  }
  if (host.settings.connectionMode === "demo") return;
  if (!store.shouldFetchCloud(dev.id, window)) return;

  const requestScope = store.connectionScope;
  const dualRoute = dualState?.routes[dev.id] ?? null;

  const effectiveBackend: "xiaomiCloud" | "homeAssistant" =
    dualRoute?.backend ??
    dualState?.deviceBackends[dev.id] ??
    dev.sourceBackend ??
    (dev.id.startsWith("ha:") || dev.id.startsWith("sensor.")
      ? "homeAssistant"
      : dev.id.startsWith("mi:") || (dev.id.includes("/") && !dev.id.startsWith("ha:"))
        ? "xiaomiCloud"
        : host.settings.connectionMode === "homeAssistant"
          ? "homeAssistant"
          : "xiaomiCloud");

  const sourceDev = dualRoute?.sourceDevice ?? dev;
  const facets =
    host.deviceFacets[dev.id] ??
    host.deviceFacets[sourceDev.id] ??
    [];

  if (effectiveBackend === "xiaomiCloud") {
    if (!dualActive && Boolean(host.miSessionExpired)) return;
    const rawDid = extractRawMiCloudDid(
      dualRoute?.sourceDeviceId ?? sourceDev.id,
    );
    const miSession = resolveMiSessionForDevice(host, sourceDev, rawDid);
    if (!miSession) return;
    const multiSpecs = getHostMiAccountsState(host)?.merged?.specsByModel;
    const cachedSpec =
      multiSpecs?.[sourceDev.model] ??
      host.specResolver.exportCachedSpecs()[sourceDev.model] ??
      inferFallbackSpec({ model: sourceDev.model, name: sourceDev.name });
    const propertyKeys = resolveMiotSensorPropertyKeys(cachedSpec, facets);
    const metrics = availableSensorMetrics(dev, facets, store.points(dev.id, window));
    void store
      .fetchAndMerge(dev.id, window, () =>
        fetchMiCloudSensorHistory({
          session: miSession,
          transport: host.transport,
          did: rawDid,
          window,
          metrics: metrics.length > 0 ? metrics : ["temperature", "humidity"],
          propertyKeys,
        }),
      )
      .finally(() => {
        if (host.root.isConnected && store.connectionScope === requestScope) {
          host.queueBackgroundRender();
        }
      });
    return;
  }

  if (
    effectiveBackend === "homeAssistant" &&
    (dualActive || !host.haConnectionError) &&
    host.settings.haBaseURL.trim() !== "" &&
    host.settings.haToken.trim() !== ""
  ) {
    const baseURL = host.settings.haBaseURL;
    const token = host.settings.haToken;
    void store
      .fetchAndMerge(dev.id, window, async () => {
        const entityIds = await discoverHASensorEntitiesViaSnapshot(host, sourceDev, facets);
        if (entityIds.length === 0) return [];
        return fetchHomeAssistantSensorHistory({
          baseURL,
          token,
          transport: host.transport,
          entityIds,
          window,
        });
      })
      .finally(() => {
        if (host.root.isConnected && store.connectionScope === requestScope) {
          host.queueBackgroundRender();
        }
      });
  }
}

export function syncSensorHistoryHost(host?: MenuMijiaWindowsApp): void {
  if (!host) return;
  const ui = getHostSensorHistoryUi(host);
  if (ui.isSyncingHost) return;
  ui.isSyncingHost = true;
  try {
    if (!host.root.isConnected) {
      ui.hoveredSlotByDevice.clear();
      return;
    }

    const store = sharedSensorHistoryStore();
    const scope = resolveHostHistoryScope(host);
    if (ui.scopeKey !== null && ui.scopeKey !== scope) {
      resetSensorHistoryUiState(ui);
    }
    ui.scopeKey = scope;
    store.setConnectionScope(scope);

    if (ui.lastExpandedId && ui.lastExpandedId !== host.expandedDeviceId) {
      ui.hoveredSlotByDevice.delete(ui.lastExpandedId);
    }
    ui.lastExpandedId = host.expandedDeviceId;

    if (host.settings.connectionMode === "demo") {
      if (ui.lastRecordedDevicesRef !== host.devices) {
        ui.lastRecordedDevicesRef = host.devices;
        seedDemoSensorHistory(host.devices, {
          store,
          facetsByDevice: host.deviceFacets,
        });
      }
    } else if (
      ui.lastRecordedDevicesRef !== host.devices &&
      canRecordLiveHostSensors(host)
    ) {
      ui.lastRecordedDevicesRef = host.devices;
      ui.recordedBatchSeq += 1;
      const staleIds = getHostMiAccountsState(host)?.merged?.staleDeviceIds;
      const dualRoutes = isDualSourceEnabled(host) ? getHostDualSourceState(host)?.routes : undefined;
      const liveDevices = host.devices.filter((d) =>
        isLiveSensorTelemetryDevice(d, staleIds, dualRoutes),
      );
      if (liveDevices.length > 0) {
        store.record(liveDevices, {
          facetsByDevice: host.deviceFacets,
          snapshotKey: `${scope}#${ui.recordedBatchSeq}`,
        });
      }
    }

    if (host.expandedDeviceId && !host.valuesAreStale) {
      const expandedDev = host.devices.find((d) => d.id === host.expandedDeviceId);
      const staleIds = getHostMiAccountsState(host)?.merged?.staleDeviceIds;
      const dualRoutes = isDualSourceEnabled(host) ? getHostDualSourceState(host)?.routes : undefined;
      if (
        expandedDev &&
        expandedDev.kind.kind === "sensor" &&
        isLiveSensorTelemetryDevice(expandedDev, staleIds, dualRoutes)
      ) {
        triggerRemoteHistoryFetchIfNeeded(
          host,
          expandedDev,
          selectedSensorWindow(expandedDev.id, ui),
          store,
        );
      }
    }
  } finally {
    ui.isSyncingHost = false;
  }
}

function computePlotGeometry(
  points: readonly SensorHistoryPoint[],
  metric: SensorMetricKind,
  tempUnit: TemperatureUnit,
): {
  readonly slotXs: readonly number[];
  readonly observedCoords: readonly CubicPoint[];
  readonly upperCoords: readonly CubicPoint[];
  readonly lowerCoords: readonly CubicPoint[];
  readonly hasBand: boolean;
  readonly rawDomainMin: number;
  readonly rawDomainMax: number;
  readonly linePath: string;
  readonly areaPath: string;
  readonly bandPath: string;
} {
  const n = Math.max(1, points.length);
  const slotXs = points.map((_, idx) =>
    n <= 1 ? PLOT_LEFT + PLOT_WIDTH / 2 : round2(PLOT_LEFT + (idx / (n - 1)) * PLOT_WIDTH),
  );

  let rawMin = Number.POSITIVE_INFINITY;
  let rawMax = Number.NEGATIVE_INFINITY;
  let maxSpread = 0;

  for (const pt of points) {
    const val = pointMetricValue(pt, metric);
    if (val === null || !Number.isFinite(val)) continue;
    const range = pointMetricRange(pt, metric);
    const lo = range ? range.min : val;
    const hi = range ? range.max : val;
    rawMin = Math.min(rawMin, lo);
    rawMax = Math.max(rawMax, hi);
    maxSpread = Math.max(maxSpread, hi - lo);
  }

  if (!Number.isFinite(rawMin) || !Number.isFinite(rawMax)) {
    rawMin = 0;
    rawMax = 10;
  }

  const minRawSpan =
    metric === "temperature" ? 1.6 : metric === "humidity" ? 6 : metric === "pm25" ? 8 : 24;
  const rawSpan = Math.max(rawMax - rawMin, minRawSpan);
  const pad = rawSpan * 0.16;
  let rawDomainMin = rawMin - pad;
  let rawDomainMax = rawMax + pad;
  if (metric !== "temperature") {
    rawDomainMin = Math.max(0, rawDomainMin);
  }
  if (metric === "humidity" && rawMax <= 100) {
    rawDomainMax = Math.min(100, Math.max(rawDomainMin + minRawSpan, rawDomainMax));
  }

  const dispMin = toDisplayMetricNumber(rawDomainMin, metric, tempUnit);
  const dispMax = toDisplayMetricNumber(rawDomainMax, metric, tempUnit);
  const dispSpan = Math.max(0.5, dispMax - dispMin);

  const yForRaw = (raw: number): number => {
    const disp = toDisplayMetricNumber(raw, metric, tempUnit);
    const ratio = clamp((disp - dispMin) / dispSpan, 0, 1);
    return round2(PLOT_BOTTOM - ratio * PLOT_HEIGHT);
  };

  const observedCoords: CubicPoint[] = [];
  const upperCoords: CubicPoint[] = [];
  const lowerCoords: CubicPoint[] = [];

  points.forEach((pt, idx) => {
    const val = pointMetricValue(pt, metric);
    if (val === null || !Number.isFinite(val)) return;
    const x = slotXs[idx]!;
    const y = yForRaw(val);
    observedCoords.push({ x, y, slotIndex: idx });
    const range = pointMetricRange(pt, metric);
    upperCoords.push({ x, y: yForRaw(range ? range.max : val), slotIndex: idx });
    lowerCoords.push({ x, y: yForRaw(range ? range.min : val), slotIndex: idx });
  });

  const linePath = buildSmoothCubicBezierPath(observedCoords);
  const areaPath =
    observedCoords.length >= 2
      ? `${linePath} L ${observedCoords[observedCoords.length - 1]!.x} ${PLOT_BOTTOM} L ${observedCoords[0]!.x} ${PLOT_BOTTOM} Z`
      : "";
  const hasBand = observedCoords.length >= 2 && maxSpread >= (metric === "temperature" ? 0.25 : 1);
  const bandPath = hasBand ? buildRangeBandPath(upperCoords, lowerCoords) : "";

  return {
    slotXs,
    observedCoords,
    upperCoords,
    lowerCoords,
    hasBand,
    rawDomainMin,
    rawDomainMax,
    linePath,
    areaPath,
    bandPath,
  };
}

export function renderSensorHistorySection(
  dev: SmartDevice,
  facets: readonly FacetControl[] = [],
  escapeHtml: (value: string) => string,
  state?: SensorHistoryUiState,
): string {
  const store = sharedSensorHistoryStore();
  if (store.connectionScope === "default") {
    store.record([dev], { facetsByDevice: { [dev.id]: facets } });
  }

  const window = selectedSensorWindow(dev.id, state);
  const points24 = store.points(dev.id, "24h");
  const points7d = store.points(dev.id, "7d");
  const points = window === "24h" ? points24 : points7d;
  const metrics = availableSensorMetrics(dev, facets, [...points24, ...points7d]);
  if (metrics.length === 0) return "";

  const preferredMetric = state?.metricByDevice.get(dev.id);
  const activeMetric: SensorMetricKind =
    preferredMetric && metrics.includes(preferredMetric) ? preferredMetric : metrics[0]!;

  const tempUnit = getTemperatureUnit();
  const summary = store.summary(dev.id, window, activeMetric);
  const live = extractSensorLiveMetrics(dev, facets);
  const currentRaw = live[activeMetric] ?? summary?.latest ?? null;
  const comfortInfo = metricComfortBadge(activeMetric, currentRaw, live.temperature, live.humidity);
  const isLoading = store.isLoading(dev.id, window);
  const isDemo = store.connectionScope === "demo";
  const hasCloud = store.hasCloudHistory(dev.id);

  const sourceLabel = isLoading
    ? tr3("正在同步历史…", "正在同步歷史…", "Syncing…")
    : isDemo
      ? tr3("演示趋势", "示範趨勢", "Demo trend")
      : hasCloud
        ? tr3("云端+本机", "雲端+本機", "Cloud + local")
        : tr3("本机记录", "本機記錄", "Local log");

  const defaultTimeLabel = tr3("当前读数", "目前讀數", "Current");
  const defaultValueLabel = formatSensorMetricValue(currentRaw, activeMetric, tempUnit);
  const defaultSubLabel = summary
    ? `${tr3("最高", "最高", "High")} ${formatSensorMetricValue(summary.max, activeMetric, tempUnit)} · ${tr3("最低", "最低", "Low")} ${formatSensorMetricValue(summary.min, activeMetric, tempUnit)} · ${tr3("均值", "均值", "Avg")} ${formatSensorMetricValue(summary.average, activeMetric, tempUnit)}`
    : tr3("暂无历史样本", "暫無歷史樣本", "No samples yet");

  const geom = computePlotGeometry(points, activeMetric, tempUnit);
  const accent = metricAccentColor(activeMetric, currentRaw);
  const idEsc = escapeHtml(dev.id);
  const safeDomId = `${dev.id.replace(/[^a-zA-Z0-9_-]/g, "_")}_${activeMetric}_${window}`;
  const latestCoord =
    geom.observedCoords.length > 0 ? geom.observedCoords[geom.observedCoords.length - 1]! : null;

  const yMaxLabel = summary ? formatAxisBound(summary.max, activeMetric, tempUnit) : formatAxisBound(geom.rawDomainMax, activeMetric, tempUnit);
  const yMinLabel = summary ? formatAxisBound(summary.min, activeMetric, tempUnit) : formatAxisBound(geom.rawDomainMin, activeMetric, tempUnit);

  const coordBySlot = new Map<number, CubicPoint>();
  for (const c of geom.observedCoords) coordBySlot.set(c.slotIndex, c);

  const hitColumns = points
    .map((pt, idx) => {
      const cx = geom.slotXs[idx]!;
      const prevX = idx === 0 ? PLOT_LEFT : (geom.slotXs[idx - 1]! + cx) / 2;
      const nextX = idx === points.length - 1 ? PLOT_RIGHT : (cx + geom.slotXs[idx + 1]!) / 2;
      const colW = Math.max(4, round2(nextX - prevX));
      const val = pointMetricValue(pt, activeMetric);
      const coord = coordBySlot.get(idx);
      const timeText = formatSlotTimeLabel(pt.bucketStartMs, window, idx === points.length - 1);
      const valText =
        val !== null
          ? formatSensorMetricValue(val, activeMetric, tempUnit)
          : tr3("未记录", "未記錄", "No data");
      const range = pointMetricRange(pt, activeMetric);
      const subText =
        val !== null && range && Math.abs(range.max - range.min) >= (activeMetric === "temperature" ? 0.2 : 1)
          ? `${tr3("范围", "範圍", "Range")} ${formatSensorMetricValue(range.min, activeMetric, tempUnit)} – ${formatSensorMetricValue(range.max, activeMetric, tempUnit)}`
          : defaultSubLabel;
      return `<rect data-sensor-slot="${idx}" data-slot-x="${cx}" data-slot-y="${coord ? coord.y : ""}" data-slot-observed="${coord ? "1" : "0"}" data-slot-time="${escapeHtml(timeText)}" data-slot-value="${escapeHtml(valText)}" data-slot-sub="${escapeHtml(subText)}" x="${round2(prevX)}" y="0" width="${colW}" height="${SVG_HEIGHT}" fill="transparent" style="cursor:crosshair" />`;
    })
    .join("");

  const tickIndices =
    window === "24h"
      ? [0, 6, 12, 18, Math.max(0, points.length - 1)]
      : points.map((_, idx) => idx);
  const uniqueTickIndices = [...new Set(tickIndices)].filter((idx) => idx < points.length);
  const ticksHtml = uniqueTickIndices
    .map(
      (idx) =>
        `<span data-sensor-tick="${idx}">${escapeHtml(formatAxisTickLabel(points[idx]!.bucketStartMs, window, idx === points.length - 1))}</span>`,
    )
    .join("");

  const singlePointSvg =
    geom.observedCoords.length === 1 && latestCoord
      ? `<line x1="${PLOT_LEFT}" y1="${latestCoord.y}" x2="${PLOT_RIGHT}" y2="${latestCoord.y}" stroke="${accent}" stroke-opacity="0.45" stroke-width="1.5" stroke-dasharray="4 3" />`
      : "";

  return `
    <div class="cc-tile-drawer cc-sensor-history" data-sensor-history-drawer="${idEsc}" style="margin-top:10px;padding-top:10px;border-top:1px solid var(--win-divider);display:flex;flex-direction:column;gap:8px;cursor:default;">
      <div class="cc-sensor-history-controls" style="display:flex;align-items:center;justify-content:space-between;gap:6px;flex-wrap:wrap;">
        <div class="cc-segmented-pills" role="group" aria-label="${escapeHtml(tr3("时间范围", "時間範圍", "Time range"))}">
          <button type="button" class="cc-seg-pill ${window === "24h" ? "is-active" : ""}" data-sensor-window="${idEsc}:24h" aria-pressed="${window === "24h"}">${escapeHtml(tr3("24小时", "24小時", "24h"))}</button>
          <button type="button" class="cc-seg-pill ${window === "7d" ? "is-active" : ""}" data-sensor-window="${idEsc}:7d" aria-pressed="${window === "7d"}">${escapeHtml(tr3("7天", "7天", "7d"))}</button>
        </div>
        ${
          metrics.length > 1
            ? `<div class="cc-segmented-pills" role="group" aria-label="${escapeHtml(tr3("传感器指标", "感測器指標", "Sensor metric"))}">
                ${metrics
                  .map(
                    (m) =>
                      `<button type="button" class="cc-seg-pill ${activeMetric === m ? "is-active" : ""}" data-sensor-metric="${idEsc}:${m}" aria-pressed="${activeMetric === m}">${escapeHtml(metricLabel(m))}</button>`,
                  )
                  .join("")}
              </div>`
            : `<span style="font-size:11px;color:var(--text-secondary);font-weight:500;">${escapeHtml(metricLabel(activeMetric))}</span>`
        }
      </div>

      <div class="cc-sensor-history-summary" data-sensor-hover-readout="${idEsc}" data-default-time="${escapeHtml(defaultTimeLabel)}" data-default-value="${escapeHtml(defaultValueLabel)}" data-default-sub="${escapeHtml(defaultSubLabel)}" style="display:flex;flex-direction:column;gap:3px;">
        <div style="display:flex;align-items:baseline;justify-content:space-between;gap:8px;">
          <div style="display:flex;align-items:baseline;gap:6px;flex-wrap:wrap;">
            <span data-sensor-readout-time style="font-size:11px;color:var(--text-secondary);">${escapeHtml(defaultTimeLabel)}</span>
            <strong data-sensor-readout-value style="font-size:15px;font-weight:650;color:var(--text-primary);">${escapeHtml(defaultValueLabel)}</strong>
            ${comfortInfo ? `<span class="cc-comfort is-${escapeHtml(comfortInfo.level)}" data-sensor-comfort-hint>${escapeHtml(comfortInfo.label)}</span>` : ""}
          </div>
          <span data-sensor-source-badge style="font-size:10.5px;color:var(--text-tertiary);white-space:nowrap;">${escapeHtml(sourceLabel)}</span>
        </div>
        <div data-sensor-readout-sub style="font-size:11px;color:var(--text-secondary);line-height:1.35;">${escapeHtml(defaultSubLabel)}</div>
      </div>

      <div class="cc-sensor-history-chart-wrap" style="position:relative;border-radius:var(--r-control);background:rgba(127,127,138,0.08);padding:6px 6px 4px;">
        <svg class="cc-sensor-history-svg" data-sensor-plot="${idEsc}" data-sensor-metric-active="${activeMetric}" data-sensor-window-active="${window}" viewBox="0 0 ${SVG_WIDTH} ${SVG_HEIGHT}" width="100%" height="112" preserveAspectRatio="none" role="img" aria-label="${escapeHtml(`${dev.name} ${metricLabel(activeMetric)} ${window === "24h" ? tr3("24小时趋势", "24小時趨勢", "24h trend") : tr3("7天趋势", "7天趨勢", "7d trend")}`)}" style="display:block;width:100%;height:112px;overflow:visible;">
          <defs>
            <linearGradient id="sensor-grad-${escapeHtml(safeDomId)}" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color="${accent}" stop-opacity="0.34" />
              <stop offset="100%" stop-color="${accent}" stop-opacity="0.02" />
            </linearGradient>
          </defs>
          <line x1="${PLOT_LEFT}" y1="${PLOT_TOP}" x2="${PLOT_RIGHT}" y2="${PLOT_TOP}" stroke="currentColor" stroke-opacity="0.1" stroke-width="0.8" stroke-dasharray="2 3" />
          <line x1="${PLOT_LEFT}" y1="${round2((PLOT_TOP + PLOT_BOTTOM) / 2)}" x2="${PLOT_RIGHT}" y2="${round2((PLOT_TOP + PLOT_BOTTOM) / 2)}" stroke="currentColor" stroke-opacity="0.08" stroke-width="0.8" stroke-dasharray="2 3" />
          <line x1="${PLOT_LEFT}" y1="${PLOT_BOTTOM}" x2="${PLOT_RIGHT}" y2="${PLOT_BOTTOM}" stroke="currentColor" stroke-opacity="0.12" stroke-width="0.8" />
          ${geom.bandPath ? `<path class="cc-sensor-band" data-sensor-band-path d="${geom.bandPath}" fill="${accent}" fill-opacity="0.14" stroke="none" />` : ""}
          ${geom.areaPath ? `<path class="cc-sensor-area" data-sensor-area-path d="${geom.areaPath}" fill="url(#sensor-grad-${escapeHtml(safeDomId)})" stroke="none" />` : ""}
          ${geom.observedCoords.length >= 2 ? `<path class="cc-sensor-line" data-sensor-line-path d="${geom.linePath}" fill="none" stroke="${accent}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />` : singlePointSvg}
          ${latestCoord ? `<circle class="cc-sensor-latest-dot" cx="${latestCoord.x}" cy="${latestCoord.y}" r="3.4" fill="${accent}" stroke="rgba(255,255,255,0.88)" stroke-width="1.3" />` : ""}
          <line data-sensor-scrubber x1="0" y1="${PLOT_TOP - 2}" x2="0" y2="${PLOT_BOTTOM}" stroke="${accent}" stroke-opacity="0.65" stroke-width="1.1" stroke-dasharray="2 2" hidden />
          <circle data-sensor-hover-dot cx="0" cy="0" r="4.3" fill="${accent}" stroke="#ffffff" stroke-width="1.6" hidden />
          ${hitColumns}
        </svg>
        <span data-sensor-y-max style="position:absolute;top:5px;right:9px;font-size:9.5px;color:var(--text-tertiary);pointer-events:none;">${escapeHtml(yMaxLabel)}</span>
        <span data-sensor-y-min style="position:absolute;bottom:6px;right:9px;font-size:9.5px;color:var(--text-tertiary);pointer-events:none;">${escapeHtml(yMinLabel)}</span>
      </div>

      <div class="cc-sensor-history-ticks" data-sensor-x-axis style="display:flex;align-items:center;justify-content:space-between;font-size:10px;color:var(--text-tertiary);padding:0 2px;">
        ${ticksHtml}
      </div>
    </div>
  `;
}

function applySlotHover(drawer: HTMLElement, slotRect: Element | null): void {
  const readout = drawer.querySelector<HTMLElement>("[data-sensor-hover-readout]");
  const timeEl = readout?.querySelector<HTMLElement>("[data-sensor-readout-time]");
  const valEl = readout?.querySelector<HTMLElement>("[data-sensor-readout-value]");
  const subEl = readout?.querySelector<HTMLElement>("[data-sensor-readout-sub]");
  const scrubber = drawer.querySelector<SVGElement>("[data-sensor-scrubber]");
  const dot = drawer.querySelector<SVGElement>("[data-sensor-hover-dot]");

  if (!slotRect || !readout) {
    if (readout && timeEl && valEl && subEl) {
      timeEl.textContent = readout.dataset.defaultTime ?? "";
      valEl.textContent = readout.dataset.defaultValue ?? "";
      subEl.textContent = readout.dataset.defaultSub ?? "";
    }
    scrubber?.setAttribute("hidden", "");
    dot?.setAttribute("hidden", "");
    return;
  }

  const slotX = slotRect.getAttribute("data-slot-x") ?? "0";
  const slotY = slotRect.getAttribute("data-slot-y") ?? "";
  const isObserved = slotRect.getAttribute("data-slot-observed") === "1";
  if (timeEl) timeEl.textContent = slotRect.getAttribute("data-slot-time") ?? "";
  if (valEl) valEl.textContent = slotRect.getAttribute("data-slot-value") ?? "";
  if (subEl) subEl.textContent = slotRect.getAttribute("data-slot-sub") ?? "";

  if (scrubber) {
    scrubber.setAttribute("x1", slotX);
    scrubber.setAttribute("x2", slotX);
    scrubber.removeAttribute("hidden");
  }
  if (dot) {
    if (isObserved && slotY !== "") {
      dot.setAttribute("cx", slotX);
      dot.setAttribute("cy", slotY);
      dot.removeAttribute("hidden");
    } else {
      dot.setAttribute("hidden", "");
    }
  }
}

function findElementWithAttr(start: EventTarget | null, attr: string, boundary?: Element): Element | null {
  let cur = start as Element | null;
  while (cur) {
    if (typeof cur.hasAttribute === "function" && cur.hasAttribute(attr)) return cur;
    if (boundary && cur === boundary) break;
    cur = cur.parentElement;
  }
  return null;
}

function resolveSlotFromEvent(svg: SVGElement, e: Event): Element | null {
  const slots = Array.from(svg.querySelectorAll("[data-sensor-slot]"));
  if (slots.length === 0) return null;
  const targetSlot = findElementWithAttr(e.target, "data-sensor-slot", svg);
  if (e.type === "mouseover" && targetSlot) return targetSlot;
  const clientX = (e as { readonly clientX?: unknown }).clientX;
  if (typeof clientX === "number" && Number.isFinite(clientX)) {
    const box = svg.getBoundingClientRect();
    if (box.width > 1 && clientX >= box.left - 2 && clientX <= box.right + 2) {
      const ratio = clamp((clientX - box.left) / box.width, 0, 1);
      const idx = Math.round(ratio * (slots.length - 1));
      return slots[idx] ?? targetSlot;
    }
  }
  return targetSlot;
}

function closestHtmlTarget(target: EventTarget | null, selector: string): Element | null {
  let cur = target as Element | null;
  while (cur && typeof cur.closest !== "function") {
    cur = cur.parentElement;
  }
  return cur ? cur.closest(selector) : null;
}

export function bindSensorHistoryEvents(host: MenuMijiaWindowsApp): void {
  syncSensorHistoryHost(host);
  const ui = getHostSensorHistoryUi(host);

  host.root
    .querySelectorAll<HTMLElement>("[data-sensor-history-drawer]:not([data-exit-ghost])")
    .forEach((drawer) => {
      if (drawer.closest("[data-exit-ghost]")) return;
      drawer.addEventListener("pointerdown", (e) => {
        if (!host.isEditingLayout) e.stopPropagation();
      });
      drawer.addEventListener("click", (e) => {
        if (!host.isEditingLayout) e.stopPropagation();
      });
    });

  host.root
    .querySelectorAll<HTMLElement>("[data-sensor-card]:not([data-exit-ghost])")
    .forEach((card) => {
      if (card.closest("[data-exit-ghost]")) return;
      card.addEventListener("click", (e) => {
        if (host.isEditingLayout || host.suppressNextClick || host.valuesAreStale) return;
        if (
          closestHtmlTarget(
            e.target,
            ".cc-resize-handle, .cc-pin-star, [data-sensor-history-drawer], [data-toggle-device], [data-expand-device]",
          )
        ) {
          return;
        }
        const id = card.dataset.sensorCard;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        const facets = host.deviceFacets[id] ?? [];
        if (!dev || !hasPlottableSensorMetrics(dev, facets)) return;
        if (closestHtmlTarget(e.target, "[data-body-device]") && hasDetailDrawer(dev, facets)) return;
        host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
        ui.hoveredSlotByDevice.delete(id);
        syncSensorHistoryHost(host);
        host.render();
      });
    });

  host.root
    .querySelectorAll<HTMLButtonElement>("[data-sensor-window]:not([data-exit-ghost])")
    .forEach((btn) => {
      if (btn.closest("[data-exit-ghost]")) return;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const raw = btn.dataset.sensorWindow ?? "";
        const sep = raw.lastIndexOf(":");
        if (sep <= 0) return;
        const id = raw.slice(0, sep);
        const win = raw.slice(sep + 1);
        if (win !== "24h" && win !== "7d") return;
        ui.windowByDevice.set(id, win);
        ui.hoveredSlotByDevice.delete(id);
        syncSensorHistoryHost(host);
        host.render();
      });
    });

  host.root
    .querySelectorAll<HTMLButtonElement>("[data-sensor-metric]:not([data-exit-ghost])")
    .forEach((btn) => {
      if (btn.closest("[data-exit-ghost]")) return;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const raw = btn.dataset.sensorMetric ?? "";
        const sep = raw.lastIndexOf(":");
        if (sep <= 0) return;
        const id = raw.slice(0, sep);
        const metric = raw.slice(sep + 1) as SensorMetricKind;
        if (
          metric !== "temperature" &&
          metric !== "humidity" &&
          metric !== "pm25" &&
          metric !== "illuminance"
        ) {
          return;
        }
        ui.metricByDevice.set(id, metric);
        ui.hoveredSlotByDevice.delete(id);
        host.render();
      });
    });

  host.root
    .querySelectorAll<SVGElement>("[data-sensor-plot]:not([data-exit-ghost])")
    .forEach((svg) => {
      if (svg.closest("[data-exit-ghost]")) return;
      const drawer = findElementWithAttr(svg, "data-sensor-history-drawer") as HTMLElement | null;
      if (!drawer) return;
      const devId = svg.getAttribute("data-sensor-plot") ?? "";
      const onScrub = (e: Event) => {
        const slot = resolveSlotFromEvent(svg, e);
        if (!slot) return;
        const slotIdx = Number(slot.getAttribute("data-sensor-slot") ?? "-1");
        if (Number.isInteger(slotIdx) && slotIdx >= 0 && devId) {
          ui.hoveredSlotByDevice.set(devId, slotIdx);
        }
        applySlotHover(drawer, slot);
      };
      const onLeave = () => {
        if (devId) ui.hoveredSlotByDevice.delete(devId);
        applySlotHover(drawer, null);
      };
      svg.addEventListener("pointermove", onScrub);
      svg.addEventListener("mousemove", onScrub);
      svg.addEventListener("mouseover", onScrub);
      svg.addEventListener("pointerleave", onLeave);
      svg.addEventListener("mouseleave", onLeave);
    });
}
