import { MiCloudClient } from "./miCloud/client.js";
import { normalizeMiCloudRegion, type HttpTransport, type MiSession } from "./miCloud/session.js";
import { miotShortName, type MiotDeviceSpec } from "./miCloud/spec.js";
import type { FacetControl, SmartDevice } from "./models.js";
import { toCelsius } from "./temperature.js";

export type SensorHistoryWindow = "24h" | "7d";
export type SensorMetricKind = "temperature" | "humidity" | "pm25" | "illuminance";

export const ALL_SENSOR_METRICS: readonly SensorMetricKind[] = [
  "temperature",
  "humidity",
  "pm25",
  "illuminance",
];

export const SENSOR_HISTORY_STORAGE_KEY = "menumijia.sensorHistory.v1";
export const SENSOR_RETENTION_HOURS = 48;
export const SENSOR_RETENTION_DAYS = 14;
export const SENSOR_CLOUD_FETCH_COOLDOWN_MS = 5 * 60 * 1000;

export function windowBucketCount(window: SensorHistoryWindow): number {
  return window === "24h" ? 24 : 7;
}

export interface SensorHistorySample {
  readonly timestamp: number | Date;
  readonly temperature?: number | null;
  readonly minTemperature?: number | null;
  readonly maxTemperature?: number | null;
  readonly humidity?: number | null;
  readonly minHumidity?: number | null;
  readonly maxHumidity?: number | null;
  readonly pm25?: number | null;
  readonly minPm25?: number | null;
  readonly maxPm25?: number | null;
  readonly illuminance?: number | null;
  readonly minIlluminance?: number | null;
  readonly maxIlluminance?: number | null;
}

export interface SensorMetricRange {
  readonly min: number;
  readonly max: number;
}

export interface SensorHistoryPoint {
  readonly bucketStartMs: number;
  readonly temperature: number | null;
  readonly minTemperature: number | null;
  readonly maxTemperature: number | null;
  readonly humidity: number | null;
  readonly minHumidity: number | null;
  readonly maxHumidity: number | null;
  readonly pm25: number | null;
  readonly minPm25: number | null;
  readonly maxPm25: number | null;
  readonly illuminance: number | null;
  readonly minIlluminance: number | null;
  readonly maxIlluminance: number | null;
  readonly isObserved: boolean;
}

export interface SensorMetricSummary {
  readonly min: number;
  readonly max: number;
  readonly average: number;
  readonly latest: number;
  readonly observedCount: number;
}

export interface SensorMetricValues {
  readonly temperature: number | null;
  readonly humidity: number | null;
  readonly pm25: number | null;
  readonly illuminance: number | null;
}

interface MetricAccumulator {
  sum: number;
  count: number;
  min: number | null;
  max: number | null;
}

interface StoredBucketRecord {
  bucketStartMs: number;
  metrics: Partial<Record<SensorMetricKind, MetricAccumulator>>;
}

interface SensorHistoryPersisted {
  version: 1;
  hourlyByDevice: Record<string, StoredBucketRecord[]>;
  dailyByDevice: Record<string, StoredBucketRecord[]>;
  cloudSyncedDevices: string[];
}

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem?(key: string): void;
}

class MemoryStorage implements StorageLike {
  private readonly map = new Map<string, string>();
  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.map.set(key, value);
  }
  removeItem(key: string): void {
    this.map.delete(key);
  }
}

const fallbackMemoryStorage = new MemoryStorage();

function defaultStorage(): StorageLike {
  try {
    if (typeof globalThis.localStorage !== "undefined" && globalThis.localStorage !== null) {
      return globalThis.localStorage;
    }
  } catch {
    return fallbackMemoryStorage;
  }
  return fallbackMemoryStorage;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

const METRIC_BOUNDS: Readonly<Record<SensorMetricKind, readonly [number, number]>> = {
  temperature: [-50, 100],
  humidity: [0, 100],
  pm25: [0, 1000],
  illuminance: [0, 200_000],
};

export function sanitizeMetricValue(metric: SensorMetricKind, value: unknown): number | null {
  const [lo, hi] = METRIC_BOUNDS[metric];
  if (typeof value !== "number" || !Number.isFinite(value) || value < lo || value > hi) {
    return null;
  }
  return round1(value);
}

export const sanitizeTemperature = (value: unknown): number | null =>
  sanitizeMetricValue("temperature", value);
export const sanitizeHumidity = (value: unknown): number | null =>
  sanitizeMetricValue("humidity", value);
export const sanitizePm25 = (value: unknown): number | null =>
  sanitizeMetricValue("pm25", value);
export const sanitizeIlluminance = (value: unknown): number | null =>
  sanitizeMetricValue("illuminance", value);

export function pointMetricValue(point: SensorHistoryPoint, metric: SensorMetricKind): number | null {
  return point[metric];
}

export function pointMetricRange(
  point: SensorHistoryPoint,
  metric: SensorMetricKind,
): SensorMetricRange | null {
  const pairs: Record<SensorMetricKind, readonly [number | null, number | null]> = {
    temperature: [point.minTemperature ?? point.temperature, point.maxTemperature ?? point.temperature],
    humidity: [point.minHumidity ?? point.humidity, point.maxHumidity ?? point.humidity],
    pm25: [point.minPm25 ?? point.pm25, point.maxPm25 ?? point.pm25],
    illuminance: [point.minIlluminance ?? point.illuminance, point.maxIlluminance ?? point.illuminance],
  };
  const [lo, hi] = pairs[metric];
  if (lo === null || hi === null || !Number.isFinite(lo) || !Number.isFinite(hi)) return null;
  return { min: Math.min(lo, hi), max: Math.max(lo, hi) };
}

export function startOfLocalHourMs(input: number | Date): number {
  const d = input instanceof Date ? input : new Date(input);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), 0, 0, 0).getTime();
}

export function startOfLocalDayMs(input: number | Date): number {
  const d = input instanceof Date ? input : new Date(input);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0).getTime();
}

function addLocalHoursMs(hourStartMs: number, deltaHours: number): number {
  const d = new Date(hourStartMs);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours() + deltaHours, 0, 0, 0).getTime();
}

function addLocalDaysMs(dayStartMs: number, deltaDays: number): number {
  const d = new Date(dayStartMs);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + deltaDays, 0, 0, 0, 0).getTime();
}

function isSameLocalHour(lhsMs: number, rhsMs: number): boolean {
  return Math.abs(startOfLocalHourMs(lhsMs) - startOfLocalHourMs(rhsMs)) < 1000;
}

function isSameLocalDay(lhsMs: number, rhsMs: number): boolean {
  return startOfLocalDayMs(lhsMs) === startOfLocalDayMs(rhsMs);
}

function toTimestampMs(input: number | Date): number | null {
  const ms = input instanceof Date ? input.getTime() : input;
  return typeof ms === "number" && Number.isFinite(ms) && ms > 0 ? ms : null;
}

function accumulatorAverage(acc: MetricAccumulator | undefined): number | null {
  return acc && acc.count > 0 && Number.isFinite(acc.sum) ? round1(acc.sum / acc.count) : null;
}

function addMetricSample(
  bucket: StoredBucketRecord,
  metric: SensorMetricKind,
  rawVal: unknown,
  rawMin?: unknown,
  rawMax?: unknown,
  replace = false,
): boolean {
  const val = sanitizeMetricValue(metric, rawVal);
  if (val === null) return false;
  const lo = sanitizeMetricValue(metric, rawMin) ?? val;
  const hi = sanitizeMetricValue(metric, rawMax) ?? val;
  const minVal = Math.min(lo, hi);
  const maxVal = Math.max(lo, hi);

  const existing = bucket.metrics[metric];
  const prevAvg = accumulatorAverage(existing);
  const prevMin = existing?.min ?? null;
  const prevMax = existing?.max ?? null;

  if (!existing || replace || existing.count <= 0) {
    bucket.metrics[metric] = { sum: val, count: 1, min: minVal, max: maxVal };
  } else {
    existing.sum += val;
    existing.count += 1;
    existing.min = existing.min === null ? minVal : Math.min(existing.min, minVal);
    existing.max = existing.max === null ? maxVal : Math.max(existing.max, maxVal);
  }

  const next = bucket.metrics[metric]!;
  const nextAvg = accumulatorAverage(next);
  const epsilon = metric === "temperature" ? 0.05 : 0.2;
  return (
    prevAvg === null ||
    nextAvg === null ||
    Math.abs(nextAvg - prevAvg) >= epsilon ||
    prevMin !== next.min ||
    prevMax !== next.max
  );
}

function mergeBucketReplacingMetrics(target: StoredBucketRecord, incoming: StoredBucketRecord): boolean {
  let changed = false;
  for (const metric of ALL_SENSOR_METRICS) {
    const inc = incoming.metrics[metric];
    if (!inc || inc.count <= 0) continue;
    const cur = target.metrics[metric];
    if (
      !cur ||
      accumulatorAverage(cur) !== accumulatorAverage(inc) ||
      cur.min !== inc.min ||
      cur.max !== inc.max ||
      cur.count !== inc.count
    ) {
      changed = true;
    }
    target.metrics[metric] = { sum: inc.sum, count: inc.count, min: inc.min, max: inc.max };
  }
  return changed;
}

function bucketHasAnyMetric(bucket: StoredBucketRecord): boolean {
  return ALL_SENSOR_METRICS.some((m) => Boolean(bucket.metrics[m] && bucket.metrics[m]!.count > 0));
}

function bucketToPoint(bucket: StoredBucketRecord): SensorHistoryPoint {
  const temp = accumulatorAverage(bucket.metrics.temperature);
  const hum = accumulatorAverage(bucket.metrics.humidity);
  const pm25 = accumulatorAverage(bucket.metrics.pm25);
  const lux = accumulatorAverage(bucket.metrics.illuminance);
  return {
    bucketStartMs: bucket.bucketStartMs,
    temperature: temp,
    minTemperature: bucket.metrics.temperature?.min ?? temp,
    maxTemperature: bucket.metrics.temperature?.max ?? temp,
    humidity: hum,
    minHumidity: bucket.metrics.humidity?.min ?? hum,
    maxHumidity: bucket.metrics.humidity?.max ?? hum,
    pm25,
    minPm25: bucket.metrics.pm25?.min ?? pm25,
    maxPm25: bucket.metrics.pm25?.max ?? pm25,
    illuminance: lux,
    minIlluminance: bucket.metrics.illuminance?.min ?? lux,
    maxIlluminance: bucket.metrics.illuminance?.max ?? lux,
    isObserved: temp !== null || hum !== null || pm25 !== null || lux !== null,
  };
}

function emptyPoint(bucketStartMs: number): SensorHistoryPoint {
  return {
    bucketStartMs,
    temperature: null,
    minTemperature: null,
    maxTemperature: null,
    humidity: null,
    minHumidity: null,
    maxHumidity: null,
    pm25: null,
    minPm25: null,
    maxPm25: null,
    illuminance: null,
    minIlluminance: null,
    maxIlluminance: null,
    isObserved: false,
  };
}

function sanitizeStoredBucket(raw: unknown): StoredBucketRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const rec = raw as Record<string, unknown>;
  const bucketStartMs = typeof rec.bucketStartMs === "number" ? rec.bucketStartMs : Number.NaN;
  if (!Number.isFinite(bucketStartMs) || bucketStartMs <= 0) return null;
  const rawMetrics =
    rec.metrics && typeof rec.metrics === "object" ? (rec.metrics as Record<string, unknown>) : {};
  const metrics: Partial<Record<SensorMetricKind, MetricAccumulator>> = {};
  for (const metric of ALL_SENSOR_METRICS) {
    const entry = rawMetrics[metric];
    if (!entry || typeof entry !== "object") continue;
    const acc = entry as Record<string, unknown>;
    const count = typeof acc.count === "number" && Number.isInteger(acc.count) ? acc.count : 0;
    const sum = typeof acc.sum === "number" ? acc.sum : Number.NaN;
    if (count <= 0 || !Number.isFinite(sum)) continue;
    const avg = sanitizeMetricValue(metric, sum / count);
    if (avg === null) continue;
    const min = sanitizeMetricValue(metric, acc.min) ?? avg;
    const max = sanitizeMetricValue(metric, acc.max) ?? avg;
    metrics[metric] = { sum, count, min: Math.min(min, max), max: Math.max(min, max) };
  }
  const candidate: StoredBucketRecord = { bucketStartMs, metrics };
  return bucketHasAnyMetric(candidate) ? candidate : null;
}

function decodeBucketMap(raw: unknown, limit: number): Record<string, StoredBucketRecord[]> {
  const out: Record<string, StoredBucketRecord[]> = {};
  if (!raw || typeof raw !== "object") return out;
  for (const [devKey, list] of Object.entries(raw as Record<string, unknown>)) {
    if (!Array.isArray(list)) continue;
    const clean = list
      .map(sanitizeStoredBucket)
      .filter((b): b is StoredBucketRecord => b !== null)
      .sort((a, b) => a.bucketStartMs - b.bucketStartMs)
      .slice(-limit);
    if (clean.length > 0) out[devKey] = clean;
  }
  return out;
}

function decodeStored(storage: StorageLike, key: string): SensorHistoryPersisted {
  try {
    const raw = storage.getItem(key);
    if (!raw) return { version: 1, hourlyByDevice: {}, dailyByDevice: {}, cloudSyncedDevices: [] };
    const parsed = JSON.parse(raw) as Record<string, unknown> | null;
    if (!parsed || typeof parsed !== "object") {
      return { version: 1, hourlyByDevice: {}, dailyByDevice: {}, cloudSyncedDevices: [] };
    }
    return {
      version: 1,
      hourlyByDevice: decodeBucketMap(parsed.hourlyByDevice, SENSOR_RETENTION_HOURS),
      dailyByDevice: decodeBucketMap(parsed.dailyByDevice, SENSOR_RETENTION_DAYS),
      cloudSyncedDevices: Array.isArray(parsed.cloudSyncedDevices)
        ? parsed.cloudSyncedDevices.filter((x): x is string => typeof x === "string")
        : [],
    };
  } catch {
    return { version: 1, hourlyByDevice: {}, dailyByDevice: {}, cloudSyncedDevices: [] };
  }
}

function extractFacetNumeric(facet: FacetControl): number | null {
  let num: number | null = null;
  if (typeof facet.value === "number" && Number.isFinite(facet.value)) {
    num = facet.value;
  } else if (typeof facet.value === "string") {
    const trimmed = facet.value.trim();
    if (trimmed !== "" && /^-?\d+(?:\.\d+)?$/.test(trimmed)) {
      const parsed = Number(trimmed);
      if (Number.isFinite(parsed)) num = parsed;
    }
  }
  if (num === null) return null;
  const scale = typeof facet.scale === "number" && Number.isFinite(facet.scale) && facet.scale > 0 ? facet.scale : 1;
  return num * scale;
}

function isNonPm25PollutantToken(text: string): boolean {
  return /(?:^|[^a-z0-9])(?:pm10|pm1|pm4|tvoc|voc|hcho|formaldehyde|no2|so2|o3|co2|co|ozone|nitrogen|sulphur|sulfur|volatile_organic|carbon_monoxide|carbon_dioxide)(?:$|[^a-z0-9])/i.test(
    text,
  ) || text.includes("pm10") || text.includes("tvoc") || text.includes("甲醛");
}

function classifyFacetMetric(facet: FacetControl): SensorMetricKind | null {
  const name = facet.name.toLowerCase();
  const title = (facet.title ?? "").toLowerCase();
  const unit = (facet.unit ?? "").toLowerCase();
  if ((name === "temperature" || name.includes("temperature")) && !name.includes("color") && !name.includes("target")) {
    return "temperature";
  }
  if ((name === "relative-humidity" || name === "humidity" || name.includes("humidity")) && !name.includes("target")) {
    return "humidity";
  }
  if (/pm2[._-]?5|pm25/.test(name) || /pm2[._-]?5|pm25/.test(title)) {
    return "pm25";
  }
  if (
    (unit.includes("μg/m³") || unit.includes("µg/m³") || unit.includes("ug/m3")) &&
    !isNonPm25PollutantToken(`${name} ${title}`)
  ) {
    return "pm25";
  }
  if (name.includes("illumin") || unit === "lux" || unit === "lx" || title.includes("光照") || title.includes("illuminance")) {
    return "illuminance";
  }
  return null;
}

export function extractSensorLiveMetrics(
  device: SmartDevice,
  facets: readonly FacetControl[] = [],
): SensorMetricValues {
  let temperature: number | null = null;
  let humidity: number | null = null;
  let pm25: number | null = null;
  let illuminance: number | null = null;

  if (device.kind.kind === "sensor") {
    const spec = device.kind as Extract<SmartDevice["kind"], { kind: "sensor" }> & {
      readonly pm25?: unknown;
      readonly pm25Density?: unknown;
      readonly illuminance?: unknown;
    };
    temperature = sanitizeTemperature(spec.temperature);
    humidity = sanitizeHumidity(spec.humidity);
    pm25 = sanitizePm25(spec.pm25 ?? spec.pm25Density);
    illuminance = sanitizeIlluminance(spec.illuminance);

    const statusText = typeof device.kind.statusText === "string" ? device.kind.statusText : "";
    if (illuminance === null && statusText) {
      const luxMatch = /(?:^|[^\d.-])(\d+(?:\.\d+)?)\s*(?:lx|lux)\b/i.exec(statusText);
      if (luxMatch) illuminance = sanitizeIlluminance(Number(luxMatch[1]));
    }
    if (pm25 === null && statusText) {
      const pmMatch = /pm2\.?5(?:\s*[:：]?\s*)(\d+(?:\.\d+)?)/i.exec(statusText);
      if (pmMatch) pm25 = sanitizePm25(Number(pmMatch[1]));
    }
  } else if (device.kind.kind === "fan") {
    temperature = sanitizeTemperature(device.kind.temperature);
    humidity = sanitizeHumidity(device.kind.humidity);
    pm25 = sanitizePm25(device.kind.pm25Density);
  }

  for (const facet of facets) {
    const metric = classifyFacetMetric(facet);
    if (!metric) continue;
    const raw = extractFacetNumeric(facet);
    if (raw === null) continue;
    if (metric === "temperature" && temperature === null) {
      const u = (facet.unit ?? "").toLowerCase();
      temperature = sanitizeTemperature(u === "°f" || u === "f" ? toCelsius(raw, "fahrenheit") : raw);
    } else if (metric === "humidity" && humidity === null) {
      humidity = sanitizeHumidity(raw);
    } else if (metric === "pm25" && pm25 === null) {
      pm25 = sanitizePm25(raw);
    } else if (metric === "illuminance" && illuminance === null) {
      illuminance = sanitizeIlluminance(raw);
    }
  }

  return { temperature, humidity, pm25, illuminance };
}

export function availableSensorMetrics(
  device: SmartDevice,
  facets: readonly FacetControl[] = [],
  points: readonly SensorHistoryPoint[] = [],
): SensorMetricKind[] {
  const live = extractSensorLiveMetrics(device, facets);
  return ALL_SENSOR_METRICS.filter(
    (metric) => live[metric] !== null || points.some((pt) => pointMetricValue(pt, metric) !== null),
  );
}

export function homeAssistantHistoryScope(baseURL: string): string {
  const trimmed = baseURL.trim();
  if (!trimmed) return "ha:unconfigured";
  try {
    const url = new URL(trimmed);
    const cleanPath = url.pathname.replace(/\/+$/, "").replace(/\/api$/, "");
    return `ha:${url.protocol.toLowerCase()}//${url.host.toLowerCase()}${cleanPath}`;
  } catch {
    return `ha:${trimmed.toLowerCase()}`;
  }
}

export function resolveSensorHistoryScope(settings: {
  readonly connectionMode: "demo" | "xiaomiCloud" | "homeAssistant";
  readonly haBaseURL: string;
  readonly miSession: Pick<MiSession, "userId" | "region"> | null;
  readonly dualSourceEnabled?: boolean;
  readonly activeAccountIds?: readonly string[];
}): string {
  if (settings.connectionMode === "demo") return "demo";
  const haScope = homeAssistantHistoryScope(settings.haBaseURL);
  const accountIds = (settings.activeAccountIds ?? []).map((id) => id.trim()).filter(Boolean);
  const multiSuffix = accountIds.length > 1 ? `:${accountIds.join("+")}` : "";
  const miScope =
    settings.miSession && settings.miSession.userId.trim() !== ""
      ? `mi:${normalizeMiCloudRegion(settings.miSession.region)}:${settings.miSession.userId.trim()}${multiSuffix}`
      : accountIds.length > 0
        ? `mi:accounts:${accountIds.join("+")}`
        : "mi:signed-out";
  if (settings.dualSourceEnabled) {
    return `dual:${miScope}|${haScope}`;
  }
  if (settings.connectionMode === "homeAssistant") return haScope;
  return miScope;
}

export interface RecordSensorOptions {
  readonly now?: number | Date;
  readonly facetsByDevice?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly snapshotKey?: string;
}

interface LastSampleStamp {
  readonly timestampMs: number;
  readonly signature: string;
  readonly snapshotKey: string | null;
}

export class SensorHistoryStore {
  private readonly storage: StorageLike;
  private readonly storageKey: string;
  private stored: SensorHistoryPersisted;
  private activeScope: string;
  private readonly lastCloudFetchAtMs = new Map<string, number>();
  private readonly loadingKeys = new Set<string>();
  private readonly inFlightRequests = new Map<string, Promise<SensorHistorySample[]>>();
  private readonly lastSampleByDevice = new Map<string, LastSampleStamp>();
  private revisionCounter = 0;

  constructor(options?: {
    readonly storage?: StorageLike;
    readonly storageKey?: string;
    readonly connectionScope?: string;
  }) {
    this.storage = options?.storage ?? defaultStorage();
    this.storageKey = options?.storageKey ?? SENSOR_HISTORY_STORAGE_KEY;
    this.activeScope = (options?.connectionScope ?? "default").trim() || "default";
    this.stored = decodeStored(this.storage, this.storageKey);
    if (this.activeScope !== "default") {
      this.migrateUnscopedEntriesIfNeeded(this.activeScope);
    }
  }

  public get connectionScope(): string {
    return this.activeScope;
  }

  public get revision(): number {
    return this.revisionCounter;
  }

  public setConnectionScope(scope: string): void {
    const normalized = scope.trim() || "default";
    if (normalized === this.activeScope) return;
    if (this.activeScope === "default" && normalized !== "default") {
      this.migrateUnscopedEntriesIfNeeded(normalized);
    }
    this.activeScope = normalized;
    this.loadingKeys.clear();
    this.revisionCounter += 1;
  }

  public record(devices: readonly SmartDevice[], options?: RecordSensorOptions): boolean {
    const nowMs = toTimestampMs(options?.now ?? Date.now()) ?? Date.now();
    const hourStartMs = startOfLocalHourMs(nowMs);
    const dayStartMs = startOfLocalDayMs(nowMs);
    const facetsMap = options?.facetsByDevice ?? {};
    const snapshotKey = options?.snapshotKey ?? null;
    let shouldPersist = false;

    for (const device of devices) {
      if (!device.isOnline || device.kind.kind !== "sensor") continue;
      const live = extractSensorLiveMetrics(device, facetsMap[device.id] ?? []);
      if (ALL_SENSOR_METRICS.every((m) => live[m] === null)) continue;

      const key = this.scopedKey(device.id);
      const signature = `${live.temperature ?? ""}|${live.humidity ?? ""}|${live.pm25 ?? ""}|${live.illuminance ?? ""}`;
      const prevStamp = this.lastSampleByDevice.get(key);
      if (prevStamp) {
        const sameSnapshot = snapshotKey !== null && prevStamp.snapshotKey === snapshotKey;
        const sameInstant = prevStamp.timestampMs === nowMs;
        if (prevStamp.signature === signature && (sameSnapshot || sameInstant) && isSameLocalHour(prevStamp.timestampMs, nowMs)) {
          continue;
        }
      }
      this.lastSampleByDevice.set(key, { timestampMs: nowMs, signature, snapshotKey });

      shouldPersist = this.upsertLiveBucket(this.stored.hourlyByDevice, key, hourStartMs, isSameLocalHour, live) || shouldPersist;
      shouldPersist = this.upsertLiveBucket(this.stored.dailyByDevice, key, dayStartMs, isSameLocalDay, live) || shouldPersist;
    }

    if (!shouldPersist) return false;
    this.prune(nowMs);
    this.persist();
    this.revisionCounter += 1;
    return true;
  }

  public mergeCloudSamples(
    deviceId: string,
    window: SensorHistoryWindow,
    samples: readonly SensorHistorySample[],
    now: number | Date = Date.now(),
  ): void {
    const nowMs = toTimestampMs(now) ?? Date.now();
    this.lastCloudFetchAtMs.set(this.syncKey(deviceId, window), nowMs);
    if (samples.length === 0) {
      this.revisionCounter += 1;
      return;
    }

    const key = this.scopedKey(deviceId);
    const sameSlot = window === "24h" ? isSameLocalHour : isSameLocalDay;
    const aggregatedIncoming: StoredBucketRecord[] = [];

    for (const sample of samples) {
      const tsMs = toTimestampMs(sample.timestamp);
      if (tsMs === null) continue;
      const bucketStartMs = window === "24h" ? startOfLocalHourMs(tsMs) : startOfLocalDayMs(tsMs);
      const t = sanitizeTemperature(sample.temperature);
      const h = sanitizeHumidity(sample.humidity);
      const p = sanitizePm25(sample.pm25);
      const lx = sanitizeIlluminance(sample.illuminance);
      if (t === null && h === null && p === null && lx === null) continue;

      let bucket = aggregatedIncoming.find((item) => sameSlot(item.bucketStartMs, bucketStartMs));
      if (!bucket) {
        bucket = { bucketStartMs, metrics: {} };
        aggregatedIncoming.push(bucket);
      }
      addMetricSample(bucket, "temperature", t, sample.minTemperature, sample.maxTemperature);
      addMetricSample(bucket, "humidity", h, sample.minHumidity, sample.maxHumidity);
      addMetricSample(bucket, "pm25", p, sample.minPm25, sample.maxPm25);
      addMetricSample(bucket, "illuminance", lx, sample.minIlluminance, sample.maxIlluminance);
    }

    if (aggregatedIncoming.length === 0) {
      this.revisionCounter += 1;
      return;
    }

    let didChange = false;
    const targetMap = window === "24h" ? this.stored.hourlyByDevice : this.stored.dailyByDevice;
    const list = targetMap[key] ?? [];

    for (const incoming of aggregatedIncoming) {
      const existing = list.find((item) => sameSlot(item.bucketStartMs, incoming.bucketStartMs));
      if (existing) {
        if (mergeBucketReplacingMetrics(existing, incoming)) didChange = true;
      } else {
        list.push(incoming);
        didChange = true;
      }
    }
    targetMap[key] = list;

    if (!this.stored.cloudSyncedDevices.includes(key)) {
      this.stored.cloudSyncedDevices.push(key);
      didChange = true;
    }

    if (didChange) {
      this.prune(nowMs);
      this.persist();
    }
    this.revisionCounter += 1;
  }

  public points(
    deviceId: string,
    window: SensorHistoryWindow,
    now: number | Date = Date.now(),
  ): SensorHistoryPoint[] {
    const nowMs = toTimestampMs(now) ?? Date.now();
    const key = this.scopedKey(deviceId);
    const count = windowBucketCount(window);
    const buckets = window === "24h" ? (this.stored.hourlyByDevice[key] ?? []) : (this.stored.dailyByDevice[key] ?? []);
    const anchorMs = window === "24h" ? startOfLocalHourMs(nowMs) : startOfLocalDayMs(nowMs);
    const stepFn = window === "24h" ? addLocalHoursMs : addLocalDaysMs;
    const matchFn = window === "24h" ? isSameLocalHour : isSameLocalDay;

    const result: SensorHistoryPoint[] = [];
    for (let offset = 0; offset < count; offset += 1) {
      const slotMs = stepFn(anchorMs, -(count - 1) + offset);
      const match = buckets.find((b) => matchFn(b.bucketStartMs, slotMs));
      result.push(match ? bucketToPoint({ ...match, bucketStartMs: slotMs }) : emptyPoint(slotMs));
    }
    return result;
  }

  public summary(
    deviceId: string,
    window: SensorHistoryWindow,
    metric: SensorMetricKind,
    now: number | Date = Date.now(),
  ): SensorMetricSummary | null {
    const pts = this.points(deviceId, window, now);
    const values: number[] = [];
    let lo = Number.POSITIVE_INFINITY;
    let hi = Number.NEGATIVE_INFINITY;
    let latest: number | null = null;

    for (const pt of pts) {
      const val = pointMetricValue(pt, metric);
      if (val === null || !Number.isFinite(val)) continue;
      values.push(val);
      latest = val;
      const range = pointMetricRange(pt, metric);
      lo = Math.min(lo, range ? range.min : val);
      hi = Math.max(hi, range ? range.max : val);
    }

    if (values.length === 0 || latest === null || !Number.isFinite(lo) || !Number.isFinite(hi)) return null;
    const average = round1(values.reduce((acc, item) => acc + item, 0) / values.length);
    return { min: lo, max: hi, average, latest, observedCount: values.length };
  }

  public storedBucketCount(deviceId: string, kind: "hourly" | "daily"): number {
    const map = kind === "hourly" ? this.stored.hourlyByDevice : this.stored.dailyByDevice;
    return (map[this.scopedKey(deviceId)] ?? []).length;
  }

  public hasCloudHistory(deviceId: string): boolean {
    return this.stored.cloudSyncedDevices.includes(this.scopedKey(deviceId));
  }

  public isLoading(deviceId: string, window: SensorHistoryWindow): boolean {
    return this.loadingKeys.has(this.syncKey(deviceId, window));
  }

  public setLoading(loading: boolean, deviceId: string, window: SensorHistoryWindow): void {
    const key = this.syncKey(deviceId, window);
    if (loading) this.loadingKeys.add(key);
    else this.loadingKeys.delete(key);
    this.revisionCounter += 1;
  }

  public shouldFetchCloud(
    deviceId: string,
    window: SensorHistoryWindow,
    now: number | Date = Date.now(),
    cooldownMs = SENSOR_CLOUD_FETCH_COOLDOWN_MS,
  ): boolean {
    const key = this.syncKey(deviceId, window);
    if (this.loadingKeys.has(key) || this.inFlightRequests.has(key)) return false;
    const nowMs = toTimestampMs(now) ?? Date.now();
    const lastMs = this.lastCloudFetchAtMs.get(key);
    return lastMs === undefined || nowMs - lastMs >= cooldownMs;
  }

  public async fetchAndMerge(
    deviceId: string,
    window: SensorHistoryWindow,
    fetcher: () => Promise<readonly SensorHistorySample[]>,
    options?: {
      readonly force?: boolean;
      readonly now?: number | Date;
      readonly cooldownMs?: number;
    },
  ): Promise<SensorHistorySample[]> {
    const nowMs = toTimestampMs(options?.now ?? Date.now()) ?? Date.now();
    const syncKey = this.syncKey(deviceId, window);
    const existing = this.inFlightRequests.get(syncKey);
    if (existing) return existing;
    if (!options?.force && !this.shouldFetchCloud(deviceId, window, nowMs, options?.cooldownMs)) {
      return [];
    }

    const requestScope = this.activeScope;
    this.setLoading(true, deviceId, window);

    const task = (async (): Promise<SensorHistorySample[]> => {
      try {
        const samples = [...(await fetcher())];
        if (this.activeScope === requestScope) {
          this.setLoading(false, deviceId, window);
          this.mergeCloudSamples(deviceId, window, samples, nowMs);
        }
        return samples;
      } catch {
        if (this.activeScope === requestScope) {
          this.setLoading(false, deviceId, window);
        }
        return [];
      } finally {
        this.inFlightRequests.delete(syncKey);
      }
    })();

    this.inFlightRequests.set(syncKey, task);
    return task;
  }

  public clear(): void {
    this.stored = { version: 1, hourlyByDevice: {}, dailyByDevice: {}, cloudSyncedDevices: [] };
    this.lastCloudFetchAtMs.clear();
    this.loadingKeys.clear();
    this.inFlightRequests.clear();
    this.lastSampleByDevice.clear();
    this.persist();
    this.revisionCounter += 1;
  }

  private upsertLiveBucket(
    map: Record<string, StoredBucketRecord[]>,
    key: string,
    bucketStartMs: number,
    sameSlot: (a: number, b: number) => boolean,
    live: SensorMetricValues,
  ): boolean {
    const list = map[key] ?? [];
    let bucket = list.find((b) => sameSlot(b.bucketStartMs, bucketStartMs));
    let changed = false;
    if (!bucket) {
      bucket = { bucketStartMs, metrics: {} };
      list.push(bucket);
      changed = true;
    }
    for (const metric of ALL_SENSOR_METRICS) {
      if (addMetricSample(bucket, metric, live[metric])) changed = true;
    }
    map[key] = list;
    return changed;
  }

  private scopedKey(deviceId: string): string {
    return !this.activeScope || this.activeScope === "default"
      ? deviceId
      : `${this.activeScope}::${deviceId}`;
  }

  private syncKey(deviceId: string, window: SensorHistoryWindow): string {
    return `${this.scopedKey(deviceId)}|${window}`;
  }

  private migrateBucketMap(
    map: Record<string, StoredBucketRecord[]>,
    scope: string,
    sameSlot: (a: number, b: number) => boolean,
    limit: number,
  ): boolean {
    let migrated = false;
    for (const bareKey of Object.keys(map)) {
      if (bareKey.includes("::")) continue;
      const legacy = map[bareKey];
      delete map[bareKey];
      if (!legacy) continue;
      const targetKey = `${scope}::${bareKey}`;
      const existing = map[targetKey];
      if (existing) {
        for (const b of legacy) {
          if (!existing.some((e) => sameSlot(e.bucketStartMs, b.bucketStartMs))) existing.push(b);
        }
        existing.sort((a, b) => a.bucketStartMs - b.bucketStartMs);
        map[targetKey] = existing.slice(-limit);
      } else {
        map[targetKey] = legacy;
      }
      migrated = true;
    }
    return migrated;
  }

  private migrateUnscopedEntriesIfNeeded(scope: string): void {
    if (!scope || scope === "default") return;
    let didMigrate = this.migrateBucketMap(this.stored.hourlyByDevice, scope, isSameLocalHour, SENSOR_RETENTION_HOURS);
    didMigrate = this.migrateBucketMap(this.stored.dailyByDevice, scope, isSameLocalDay, SENSOR_RETENTION_DAYS) || didMigrate;

    const synced = new Set<string>();
    for (const key of this.stored.cloudSyncedDevices) {
      if (!key.includes("::")) {
        synced.add(`${scope}::${key}`);
        didMigrate = true;
      } else {
        synced.add(key);
      }
    }
    this.stored.cloudSyncedDevices = [...synced];
    if (didMigrate) this.persist();
  }

  private pruneBucketMap(
    map: Record<string, StoredBucketRecord[]>,
    cutoffMs: number,
    limit: number,
    alignDay: boolean,
  ): void {
    for (const [devKey, buckets] of Object.entries(map)) {
      const trimmed = buckets
        .filter((b) => (alignDay ? startOfLocalDayMs(b.bucketStartMs) : b.bucketStartMs) >= cutoffMs && bucketHasAnyMetric(b))
        .sort((a, b) => a.bucketStartMs - b.bucketStartMs)
        .slice(-limit);
      if (trimmed.length === 0) delete map[devKey];
      else map[devKey] = trimmed;
    }
  }

  private prune(nowMs: number): void {
    const hourCutoffMs = addLocalHoursMs(startOfLocalHourMs(nowMs), -(SENSOR_RETENTION_HOURS - 1));
    const dayCutoffMs = addLocalDaysMs(startOfLocalDayMs(nowMs), -(SENSOR_RETENTION_DAYS - 1));
    this.pruneBucketMap(this.stored.hourlyByDevice, hourCutoffMs, SENSOR_RETENTION_HOURS, false);
    this.pruneBucketMap(this.stored.dailyByDevice, dayCutoffMs, SENSOR_RETENTION_DAYS, true);
  }

  private persist(): void {
    try {
      this.storage.setItem(this.storageKey, JSON.stringify(this.stored));
    } catch {
      return;
    }
  }
}

export interface MetricSamplePoint {
  readonly timestampMs: number;
  readonly value: number;
  readonly minValue: number;
  readonly maxValue: number;
}

export type MiotSensorPropertyKeys = Partial<Record<SensorMetricKind, string | null>>;

export function resolveMiotSensorPropertyKeys(
  spec: MiotDeviceSpec | null | undefined,
  facets: readonly FacetControl[] = [],
): MiotSensorPropertyKeys {
  const out: Partial<Record<SensorMetricKind, string | null>> = {};
  if (spec) {
    for (const svc of spec.services) {
      if (miotShortName(svc.type) === "device-information") continue;
      for (const prop of svc.properties) {
        if (!prop.access.includes("read") && !prop.access.includes("notify")) continue;
        const propShort = miotShortName(prop.type);
        const key = `${svc.iid}.${prop.iid}`;
        if (propShort === "temperature" && !out.temperature) out.temperature = key;
        else if (propShort === "relative-humidity" && !out.humidity) out.humidity = key;
        else if ((propShort === "pm2.5-density" || propShort === "pm25") && !out.pm25) out.pm25 = key;
        else if (propShort === "illumination" && !out.illuminance) out.illuminance = key;
      }
    }
  }
  for (const facet of facets) {
    if (!/^\d+\.\d+$/.test(facet.id)) continue;
    const metric = classifyFacetMetric(facet);
    if (metric && !out[metric]) out[metric] = facet.id;
  }
  return out;
}

export function decodeLittleEndianFloat32Hex(hex: string): number | null {
  if (hex.length !== 8 || !/^[0-9a-fA-F]{8}$/.test(hex)) return null;
  const bytes = new Uint8Array(4);
  for (let i = 0; i < 4; i += 1) bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  const f = new DataView(bytes.buffer).getFloat32(0, true);
  return Number.isFinite(f) ? round1(f) : null;
}

export function decodeLittleEndianInt16Hex(hex: string): number | null {
  if (hex.length !== 4 || hex === "1000" || !/^[0-9a-fA-F]{4}$/.test(hex)) return null;
  const suffix = hex.slice(2).toLowerCase();
  if (!/[a-fA-F]/.test(hex) && suffix !== "00" && suffix !== "01" && suffix !== "02" && suffix !== "03") {
    return null;
  }
  const bytes = new Uint8Array([Number.parseInt(hex.slice(0, 2), 16), Number.parseInt(hex.slice(2, 4), 16)]);
  const raw = new DataView(bytes.buffer).getInt16(0, true);
  return Number.isFinite(raw) ? raw / 10 : null;
}

interface ExtractedHistoryNumber {
  readonly value: number;
  readonly isPreScaled: boolean;
}

function extractMiHistoryRawNumbers(raw: unknown, key: string): ExtractedHistoryNumber[] {
  if (typeof raw === "number") {
    return Number.isFinite(raw) ? [{ value: raw, isPreScaled: Math.round(raw) !== raw }] : [];
  }
  if (Array.isArray(raw)) {
    return raw.flatMap((item) => extractMiHistoryRawNumbers(item, key));
  }
  if (raw !== null && typeof raw === "object") {
    const obj = raw as Record<string, unknown>;
    const primary = obj.avg ?? obj.value ?? obj.temp ?? obj.temperature ?? obj.humidity ?? obj.pm25 ?? obj.lux ?? obj.illuminance;
    return primary !== undefined ? extractMiHistoryRawNumbers(primary, key) : [];
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim().replace(/^"+|"+$/g, "").trim();
    if (!trimmed) return [];
    if ((trimmed.startsWith("[") && trimmed.endsWith("]")) || (trimmed.startsWith("{") && trimmed.endsWith("}"))) {
      try {
        return extractMiHistoryRawNumbers(JSON.parse(trimmed), key);
      } catch {
        void 0;
      }
    }
    const lowerKey = key.toLowerCase();
    if (lowerKey === "4c01" || lowerKey === "4c08") {
      const f32 = decodeLittleEndianFloat32Hex(trimmed);
      if (f32 !== null) return [{ value: f32, isPreScaled: true }];
    }
    if ((lowerKey === "4100" || lowerKey === "4102" || lowerKey === "1004" || lowerKey === "1006") && !trimmed.includes(".")) {
      const i16 = decodeLittleEndianInt16Hex(trimmed);
      if (i16 !== null) return [{ value: i16, isPreScaled: true }];
    }
    if (/^[+-]?\d+(?:\.\d+)?$/.test(trimmed)) {
      const d = Number(trimmed);
      if (Number.isFinite(d)) return [{ value: d, isPreScaled: trimmed.includes(".") || Math.round(d) !== d }];
    }
    const fallbackF32 = decodeLittleEndianFloat32Hex(trimmed);
    if (fallbackF32 !== null) return [{ value: fallbackF32, isPreScaled: true }];
  }
  return [];
}

function decodeMiHistoryValues(raw: unknown, key: string, metric: SensorMetricKind): number[] {
  const lowerKey = key.toLowerCase();
  const usesTenths = lowerKey === "4100" || lowerKey === "4102" || lowerKey === "1004" || lowerKey === "1006";
  const out: number[] = [];
  for (const item of extractMiHistoryRawNumbers(raw, key)) {
    if (!Number.isFinite(item.value)) continue;
    const adjusted = usesTenths && !item.isPreScaled ? item.value / 10 : item.value;
    const clean = sanitizeMetricValue(metric, adjusted);
    if (clean !== null) out.push(clean);
  }
  return out;
}

function parseRawTimestampSeconds(raw: unknown): number | null {
  const num =
    typeof raw === "number" && Number.isFinite(raw)
      ? raw
      : typeof raw === "string" && /^\d+(?:\.\d+)?$/.test(raw.trim())
        ? Number(raw.trim())
        : Number.NaN;
  if (!Number.isFinite(num) || num <= 0) return null;
  return num > 10_000_000_000 ? num / 1000 : num;
}

export function parseMiCloudHistoryPoints(
  result: unknown,
  key: string,
  metric: SensorMetricKind,
): MetricSamplePoint[] {
  let items: unknown[] | null = null;
  if (Array.isArray(result)) items = result;
  else if (result !== null && typeof result === "object") {
    const obj = result as Record<string, unknown>;
    const candidate = obj.list ?? obj.data ?? obj.result;
    if (Array.isArray(candidate)) items = candidate;
  }
  if (!items) return [];

  const points: MetricSamplePoint[] = [];
  for (const entry of items) {
    if (!entry || typeof entry !== "object") continue;
    const rec = entry as Record<string, unknown>;
    const seconds = parseRawTimestampSeconds(rec.time ?? rec.timestamp);
    if (seconds === null || rec.value === undefined) continue;
    const decoded = decodeMiHistoryValues(rec.value, key, metric);
    if (decoded.length === 0) continue;
    let minValue = Math.min(...decoded);
    let maxValue = Math.max(...decoded);
    const avg = round1(decoded.reduce((a, b) => a + b, 0) / decoded.length);
    if (rec.value !== null && typeof rec.value === "object" && !Array.isArray(rec.value)) {
      const valObj = rec.value as Record<string, unknown>;
      const explicitMin = valObj.min !== undefined ? decodeMiHistoryValues(valObj.min, key, metric)[0] : undefined;
      const explicitMax = valObj.max !== undefined ? decodeMiHistoryValues(valObj.max, key, metric)[0] : undefined;
      if (explicitMin !== undefined) minValue = Math.min(minValue, explicitMin);
      if (explicitMax !== undefined) maxValue = Math.max(maxValue, explicitMax);
    }
    points.push({
      timestampMs: Math.round(seconds * 1000),
      value: avg,
      minValue: Math.min(minValue, maxValue),
      maxValue: Math.max(minValue, maxValue),
    });
  }
  points.sort((a, b) => a.timestampMs - b.timestampMs);
  return points;
}

const STAT_DEFAULT_KEYS: Readonly<Record<SensorMetricKind, readonly string[]>> = {
  temperature: ["2.1"],
  humidity: ["2.2"],
  pm25: ["3.4", "2.4"],
  illuminance: ["2.1"],
};

const STAT_EXTRA_KEYS: Readonly<Record<SensorMetricKind, readonly string[]>> = {
  temperature: ["4c01"],
  humidity: ["4c08"],
  pm25: [],
  illuminance: ["4107", "1007"],
};

const DATA_EXTRA_KEYS: Readonly<Record<SensorMetricKind, readonly string[]>> = {
  temperature: ["4c01", "4100", "1004", "temperature"],
  humidity: ["4c08", "4102", "1006", "humidity", "relative-humidity"],
  pm25: ["pm2.5-density", "pm25"],
  illuminance: ["4107", "1007", "illumination", "illuminance"],
};

function candidateKeysForStatistics(miotKey: string | null | undefined, metric: SensorMetricKind): string[] {
  const base = miotKey && miotKey.trim() !== "" ? [miotKey.trim()] : [...STAT_DEFAULT_KEYS[metric]];
  return [...new Set([...base, ...STAT_EXTRA_KEYS[metric]])];
}

function candidateKeysForDeviceData(miotKey: string | null | undefined, metric: SensorMetricKind): string[] {
  const clean = miotKey?.trim();
  const base = clean ? [clean, `prop.${clean}`] : [];
  return [...new Set([...base, ...DATA_EXTRA_KEYS[metric]])];
}

export function combineMetricSampleSeries(
  seriesByMetric: Partial<Record<SensorMetricKind, readonly MetricSamplePoint[]>>,
): SensorHistorySample[] {
  const samples: SensorHistorySample[] = [];
  for (const pt of seriesByMetric.temperature ?? []) {
    samples.push({ timestamp: pt.timestampMs, temperature: pt.value, minTemperature: pt.minValue, maxTemperature: pt.maxValue });
  }
  for (const pt of seriesByMetric.humidity ?? []) {
    samples.push({ timestamp: pt.timestampMs, humidity: pt.value, minHumidity: pt.minValue, maxHumidity: pt.maxValue });
  }
  for (const pt of seriesByMetric.pm25 ?? []) {
    samples.push({ timestamp: pt.timestampMs, pm25: pt.value, minPm25: pt.minValue, maxPm25: pt.maxValue });
  }
  for (const pt of seriesByMetric.illuminance ?? []) {
    samples.push({ timestamp: pt.timestampMs, illuminance: pt.value, minIlluminance: pt.minValue, maxIlluminance: pt.maxValue });
  }
  return samples;
}

const resolvedMiRouteCache = new Map<
  string,
  { readonly kind: "statistics" | "deviceData"; readonly key: string; readonly group?: string }
>();

async function querySingleMiMetricSeries(
  client: Pick<MiCloudClient, "request">,
  userId: string,
  did: string,
  metric: SensorMetricKind,
  miotKey: string | null | undefined,
  window: SensorHistoryWindow,
  timeStart: number,
  timeEnd: number,
): Promise<MetricSamplePoint[]> {
  const cacheId = `${did}|${metric}|${window}`;
  const runRoute = async (route: {
    readonly kind: "statistics" | "deviceData";
    readonly key: string;
    readonly group?: string;
  }): Promise<MetricSamplePoint[]> => {
    try {
      const result =
        route.kind === "statistics"
          ? await client.request("v2/user/statistics", {
              did,
              key: route.key,
              data_type: window === "24h" ? "stat_hour_v3" : "stat_day_v3",
              time_start: timeStart,
              time_end: timeEnd,
              limit: window === "24h" ? 48 : 14,
            })
          : await client.request("user/get_user_device_data", {
              uid: userId,
              did,
              type: "prop",
              key: route.key,
              time_start: timeStart,
              time_end: timeEnd,
              limit: route.group === "raw" ? 200 : 48,
              ...(route.group ? { group: route.group } : {}),
            });
      return parseMiCloudHistoryPoints(result, route.key, metric);
    } catch {
      return [];
    }
  };

  const cached = resolvedMiRouteCache.get(cacheId);
  if (cached) {
    const pts = await runRoute(cached);
    if (pts.length > 0) return pts;
    resolvedMiRouteCache.delete(cacheId);
  }

  for (const key of candidateKeysForStatistics(miotKey, metric)) {
    const route = { kind: "statistics" as const, key };
    const pts = await runRoute(route);
    if (pts.length > 0) {
      resolvedMiRouteCache.set(cacheId, route);
      return pts;
    }
  }

  for (const group of [window === "24h" ? "hour" : "day", "raw"] as const) {
    for (const key of candidateKeysForDeviceData(miotKey, metric)) {
      const route = { kind: "deviceData" as const, key, group };
      const pts = await runRoute(route);
      if (pts.length > 0) {
        resolvedMiRouteCache.set(cacheId, route);
        return pts;
      }
    }
  }
  return [];
}

export async function fetchMiCloudSensorHistory(options: {
  readonly session: MiSession;
  readonly transport: HttpTransport;
  readonly did: string;
  readonly window: SensorHistoryWindow;
  readonly metrics?: readonly SensorMetricKind[];
  readonly propertyKeys?: MiotSensorPropertyKeys;
  readonly now?: number | Date;
}): Promise<SensorHistorySample[]> {
  const nowMs = toTimestampMs(options.now ?? Date.now()) ?? Date.now();
  const timeEnd = Math.floor(nowMs / 1000);
  const timeStart = Math.max(0, timeEnd - (options.window === "24h" ? 25 * 3600 : 8 * 86400));
  const client = new MiCloudClient(options.session, options.transport);
  const metrics = options.metrics && options.metrics.length > 0 ? options.metrics : (["temperature", "humidity"] as const);
  const keys = options.propertyKeys ?? {};

  const entries = await Promise.all(
    metrics.map(async (metric) => [
      metric,
      await querySingleMiMetricSeries(client, options.session.userId, options.did, metric, keys[metric], options.window, timeStart, timeEnd),
    ] as const),
  );
  return combineMetricSampleSeries(Object.fromEntries(entries));
}

function inferHAMetricFromMeta(
  entityId: string,
  attributes: Record<string, unknown> | null,
): { metric: SensorMetricKind; unit: string } | null {
  const devClass = typeof attributes?.device_class === "string" ? attributes.device_class.toLowerCase() : "";
  const unit = typeof attributes?.unit_of_measurement === "string" ? attributes.unit_of_measurement.trim() : "";
  const lowerUnit = unit.toLowerCase();
  const lowerId = entityId.toLowerCase();

  if (devClass === "temperature" || unit === "°C" || unit === "°F" || lowerUnit === "c" || lowerUnit === "f" || (lowerId.includes("temperature") && !lowerId.includes("color_temperature"))) {
    return { metric: "temperature", unit };
  }
  if (devClass === "humidity" || lowerId.includes("humidity")) return { metric: "humidity", unit };
  if (
    devClass === "pm25" ||
    /pm2[._-]?5|pm25/.test(lowerId) ||
    (devClass === "" &&
      !isNonPm25PollutantToken(lowerId) &&
      (lowerUnit.includes("µg/m³") || lowerUnit.includes("μg/m³") || lowerUnit.includes("ug/m3")))
  ) {
    return { metric: "pm25", unit };
  }
  if (devClass === "illuminance" || lowerUnit === "lx" || lowerUnit === "lux" || lowerId.includes("illuminance") || lowerId.includes("illumination") || /\blux\b/.test(lowerId)) {
    return { metric: "illuminance", unit };
  }
  return null;
}

function parseHAHistoryTimestampMs(rec: Record<string, unknown>): number | null {
  const raw = rec.last_changed ?? rec.last_updated ?? rec.lu ?? rec.lc ?? rec.timestamp;
  if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
    return raw > 10_000_000_000 ? Math.round(raw) : Math.round(raw * 1000);
  }
  if (typeof raw === "string" && raw.trim() !== "") {
    const trimmed = raw.trim();
    if (/^\d+(?:\.\d+)?$/.test(trimmed)) {
      const n = Number(trimmed);
      return Number.isFinite(n) && n > 0 ? (n > 10_000_000_000 ? Math.round(n) : Math.round(n * 1000)) : null;
    }
    const parsed = Date.parse(trimmed);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  }
  return null;
}

export function parseHomeAssistantHistoryResponse(
  payload: unknown,
  entityMetricHints?: Readonly<Record<string, SensorMetricKind>>,
): SensorHistorySample[] {
  let seriesList: unknown[][] = [];
  if (Array.isArray(payload)) {
    seriesList = payload.length > 0 && Array.isArray(payload[0]) ? (payload as unknown[][]) : [payload];
  } else if (payload !== null && typeof payload === "object") {
    for (const [eid, rows] of Object.entries(payload as Record<string, unknown>)) {
      if (Array.isArray(rows)) {
        seriesList.push(rows.map((r) => (r && typeof r === "object" ? { entity_id: eid, ...(r as Record<string, unknown>) } : r)));
      }
    }
  }

  const samples: SensorHistorySample[] = [];
  for (const series of seriesList) {
    if (!Array.isArray(series) || series.length === 0) continue;
    let entityId = "";
    let stickyAttrs: Record<string, unknown> | null = null;

    for (const item of series) {
      if (!item || typeof item !== "object") continue;
      const rec = item as Record<string, unknown>;
      if (typeof rec.entity_id === "string" && rec.entity_id !== "") entityId = rec.entity_id;
      const attrs =
        rec.attributes && typeof rec.attributes === "object" && !Array.isArray(rec.attributes)
          ? (rec.attributes as Record<string, unknown>)
          : rec.a && typeof rec.a === "object" && !Array.isArray(rec.a)
            ? (rec.a as Record<string, unknown>)
            : null;
      if (attrs) stickyAttrs = attrs;

      const rawState = rec.state ?? rec.s;
      if (typeof rawState !== "string" && typeof rawState !== "number") continue;
      const textState = String(rawState).trim();
      if (!textState || textState === "unavailable" || textState === "unknown") continue;
      const numVal = Number(textState);
      if (!Number.isFinite(numVal)) continue;

      const tsMs = parseHAHistoryTimestampMs(rec);
      if (tsMs === null) continue;

      const inferred = inferHAMetricFromMeta(entityId, stickyAttrs);
      const metric = (entityId && entityMetricHints ? entityMetricHints[entityId] : undefined) ?? inferred?.metric ?? null;
      if (!metric) continue;

      const unit = inferred?.unit ?? (typeof stickyAttrs?.unit_of_measurement === "string" ? stickyAttrs.unit_of_measurement : "");
      const normalized =
        metric === "temperature" && (unit.trim() === "°F" || unit.trim().toLowerCase() === "f")
          ? toCelsius(numVal, "fahrenheit")
          : numVal;
      const clean = sanitizeMetricValue(metric, normalized);
      if (clean === null) continue;

      samples.push({ timestamp: tsMs, [metric]: clean });
    }
  }

  samples.sort((a, b) => (toTimestampMs(a.timestamp) ?? 0) - (toTimestampMs(b.timestamp) ?? 0));
  return samples;
}

export function resolveHomeAssistantSensorEntityIds(
  device: SmartDevice,
  facets: readonly FacetControl[] = [],
  haEntities?: ReadonlyArray<{
    readonly entity_id?: unknown;
    readonly device_id?: unknown;
    readonly disabled_by?: unknown;
    readonly hidden_by?: unknown;
  }>,
): string[] {
  const ids = new Set<string>();
  const rawWithSplit = device.id.startsWith("ha:") ? device.id.slice(3) : device.id;
  const hashIdx = rawWithSplit.indexOf("#");
  const rawId = hashIdx >= 0 ? rawWithSplit.slice(0, hashIdx) : rawWithSplit;
  const splitEntityId = hashIdx >= 0 ? rawWithSplit.slice(hashIdx + 1) : null;
  if (rawId.startsWith("sensor.")) {
    ids.add(rawId);
    if (device.kind.kind === "sensor" && device.kind.humidity !== null && /temperature/i.test(rawId)) {
      ids.add(rawId.replace(/temperature/gi, "humidity"));
    }
    if (device.kind.kind === "sensor" && device.kind.temperature !== null && /humidity/i.test(rawId)) {
      ids.add(rawId.replace(/humidity/gi, "temperature"));
    }
  }
  if (splitEntityId && splitEntityId.startsWith("sensor.")) {
    ids.add(splitEntityId);
  }
  for (const facet of facets) {
    if (facet.target?.kind === "property" && facet.target.entityId.startsWith("sensor.")) {
      ids.add(facet.target.entityId);
    } else if (facet.id.startsWith("sensor.")) {
      ids.add(facet.id);
    }
  }
  if (haEntities) {
    for (const entry of haEntities) {
      if (entry.disabled_by != null || entry.hidden_by != null) continue;
      if (entry.device_id === rawId && typeof entry.entity_id === "string" && entry.entity_id.startsWith("sensor.")) {
        ids.add(entry.entity_id);
      }
    }
  }
  return [...ids];
}

export async function fetchHomeAssistantSensorHistory(options: {
  readonly baseURL: string;
  readonly token: string;
  readonly transport: HttpTransport;
  readonly entityIds: readonly string[];
  readonly window: SensorHistoryWindow;
  readonly entityMetricHints?: Readonly<Record<string, SensorMetricKind>>;
  readonly now?: number | Date;
}): Promise<SensorHistorySample[]> {
  const base = options.baseURL.trim().replace(/\/+$/, "").replace(/\/api$/, "");
  const token = options.token.trim();
  const entityIds = [...new Set(options.entityIds.map((e) => e.trim()).filter(Boolean))];
  if (!base || !token || entityIds.length === 0) return [];

  const nowMs = toTimestampMs(options.now ?? Date.now()) ?? Date.now();
  const spanMs = options.window === "24h" ? 25 * 3600 * 1000 : 8 * 86400 * 1000;
  const startIso = new Date(Math.max(0, nowMs - spanMs)).toISOString();
  const endIso = new Date(nowMs).toISOString();
  const url = `${base}/api/history/period/${encodeURIComponent(startIso)}?filter_entity_id=${encodeURIComponent(entityIds.join(","))}&end_time=${encodeURIComponent(endIso)}&minimal_response`;

  try {
    const resp = await options.transport({
      url,
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      timeoutMs: 15_000,
    });
    if (resp.status < 200 || resp.status >= 300) return [];
    return parseHomeAssistantHistoryResponse(JSON.parse(resp.body), options.entityMetricHints);
  } catch {
    return [];
  }
}

let sharedStore: SensorHistoryStore | null = null;
let sharedStoreBacking: StorageLike | null = null;

export function sharedSensorHistoryStore(): SensorHistoryStore {
  const currentBacking = defaultStorage();
  if (!sharedStore || sharedStoreBacking !== currentBacking) {
    sharedStoreBacking = currentBacking;
    sharedStore = new SensorHistoryStore({ storage: currentBacking });
  }
  return sharedStore;
}

export function resetSharedSensorHistoryStoreForTests(): void {
  sharedStore = null;
  sharedStoreBacking = null;
  resolvedMiRouteCache.clear();
}
