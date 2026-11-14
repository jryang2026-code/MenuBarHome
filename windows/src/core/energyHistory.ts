import { homeAssistantIdentity } from "./homeAssistant.js";
import { normalizeMiCloudRegion } from "./miCloudClient.js";
import type { SmartDevice } from "./models.js";

export const ENERGY_RETENTION_DAYS = 31;
export const ENERGY_TOP_DEVICE_LIMIT = 6;
export const MAX_ENERGY_COUNTER_KWH = 1_000_000_000;
export const MAX_SINGLE_DELTA_KWH = 500;
export const MAX_ELECTRICITY_PRICE_PER_KWH = 10_000;

export const ENERGY_HISTORY_KEY_PREFIX = "menumijia.windows.energyHistory.v1";
export const ENERGY_PRICE_STORAGE_KEY = "menumijia.windows.energyPrice.v1";

export interface EnergyStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export interface EnergyScopeSource {
  readonly connectionMode: "demo" | "xiaomiCloud" | "homeAssistant";
  readonly miSession?: { readonly userId: string; readonly region: string } | null;
  readonly haBaseURL?: string;
  readonly haToken?: string;
}

export interface EnergyDayTotal {
  readonly dayKey: string;
  readonly day: Date;
  readonly kwh: number;
  readonly isObserved: boolean;
}

export interface EnergyDeviceTotal {
  readonly deviceId: string;
  readonly name: string;
  readonly roomName: string;
  readonly kwh: number;
  readonly share: number;
  readonly barFraction: number;
}

export type ElectricityPriceApplyResult =
  | { readonly action: "saved"; readonly pricePerKwh: number }
  | { readonly action: "cleared"; readonly pricePerKwh: null }
  | { readonly action: "kept"; readonly pricePerKwh: number | null };

interface EnergyBucketRecord {
  dayKey: string;
  perDevice: Record<string, number>;
}

interface EnergyHistoryStored {
  recordingStartedAtMs: number | null;
  baselines: Record<string, number>;
  lastSampleAtMs: Record<string, number>;
  names: Record<string, string>;
  rooms: Record<string, string>;
  observedDays: string[];
  buckets: EnergyBucketRecord[];
}

export interface EnergyHistoryOptions {
  readonly scope?: string;
  readonly storage?: EnergyStorageLike;
  readonly storageKey?: string;
  readonly priceStorageKey?: string;
}

function emptyStored(): EnergyHistoryStored {
  return {
    recordingStartedAtMs: null,
    baselines: {},
    lastSampleAtMs: {},
    names: {},
    rooms: {},
    observedDays: [],
    buckets: [],
  };
}

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

export function localDayKey(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

export function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0);
}

export function addLocalDays(day: Date, offsetDays: number): Date {
  return new Date(day.getFullYear(), day.getMonth(), day.getDate() + offsetDays, 0, 0, 0, 0);
}

export function parseLocalDayKey(dayKey: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dayKey);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) return null;
  const parsed = new Date(year, month - 1, day, 0, 0, 0, 0);
  if (!Number.isFinite(parsed.getTime()) || localDayKey(parsed) !== dayKey) return null;
  return parsed;
}

function isSameLocalDayMs(aMs: number, bMs: number): boolean {
  return localDayKey(new Date(aMs)) === localDayKey(new Date(bMs));
}

const fallbackMemoryMap = new Map<string, string>();
const fallbackMemoryStorage: EnergyStorageLike = {
  getItem: (k) => fallbackMemoryMap.get(k) ?? null,
  setItem: (k, v) => {
    fallbackMemoryMap.set(k, v);
  },
  removeItem: (k) => {
    fallbackMemoryMap.delete(k);
  },
};

function resolveActiveStorage(explicit: EnergyStorageLike | null): EnergyStorageLike {
  if (explicit) return explicit;
  if (typeof localStorage !== "undefined") return localStorage;
  return fallbackMemoryStorage;
}

export function energyScopeKey(source: EnergyScopeSource): string {
  switch (source.connectionMode) {
    case "demo":
      return "demo";
    case "xiaomiCloud": {
      const userId = source.miSession?.userId?.trim() ?? "";
      if (!userId) return "xiaomiCloud:signedOut";
      const region = normalizeMiCloudRegion(source.miSession?.region ?? "cn");
      return JSON.stringify(["xiaomiCloud", userId, region]);
    }
    case "homeAssistant": {
      const token = source.haToken?.trim() ?? "";
      const baseURL = source.haBaseURL?.trim() ?? "";
      if (!token || !baseURL) return "homeAssistant:unconfigured";
      const identity = homeAssistantIdentity(baseURL, token);
      return identity ? JSON.stringify(["homeAssistant", identity]) : "homeAssistant:unconfigured";
    }
  }
}

export function energyStorageKeyForScope(scope: string): string {
  return `${ENERGY_HISTORY_KEY_PREFIX}.${scope || "default"}`;
}

function sanitizePriceValue(value: number | null | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 || value > MAX_ELECTRICITY_PRICE_PER_KWH) {
    return null;
  }
  return value;
}

function sumPositiveFinite(values: Iterable<number>): number {
  let total = 0;
  for (const value of values) {
    if (Number.isFinite(value) && value > 0) {
      total += value;
    }
  }
  return total;
}

function sanitizeStored(raw: unknown): EnergyHistoryStored {
  if (!raw || typeof raw !== "object") return emptyStored();
  const obj = raw as Record<string, unknown>;
  const result = emptyStored();

  if (typeof obj.recordingStartedAtMs === "number" && Number.isFinite(obj.recordingStartedAtMs) && obj.recordingStartedAtMs > 0) {
    result.recordingStartedAtMs = obj.recordingStartedAtMs;
  }

  if (obj.baselines && typeof obj.baselines === "object") {
    for (const [deviceId, val] of Object.entries(obj.baselines as Record<string, unknown>)) {
      if (
        deviceId &&
        typeof val === "number" &&
        Number.isFinite(val) &&
        val >= 0 &&
        val <= MAX_ENERGY_COUNTER_KWH
      ) {
        result.baselines[deviceId] = val;
      }
    }
  }

  if (obj.lastSampleAtMs && typeof obj.lastSampleAtMs === "object") {
    for (const [deviceId, val] of Object.entries(obj.lastSampleAtMs as Record<string, unknown>)) {
      if (deviceId && typeof val === "number" && Number.isFinite(val) && val > 0) {
        result.lastSampleAtMs[deviceId] = val;
      }
    }
  }

  if (obj.names && typeof obj.names === "object") {
    for (const [deviceId, val] of Object.entries(obj.names as Record<string, unknown>)) {
      if (deviceId && typeof val === "string" && val.trim() !== "") {
        result.names[deviceId] = val.trim();
      }
    }
  }

  if (obj.rooms && typeof obj.rooms === "object") {
    for (const [deviceId, val] of Object.entries(obj.rooms as Record<string, unknown>)) {
      if (deviceId && typeof val === "string") {
        result.rooms[deviceId] = val.trim();
      }
    }
  }

  const mergedBuckets = new Map<string, Record<string, number>>();
  if (Array.isArray(obj.buckets)) {
    for (const item of obj.buckets) {
      if (!item || typeof item !== "object") continue;
      const rec = item as Record<string, unknown>;
      const dayKey = typeof rec.dayKey === "string" ? rec.dayKey : "";
      if (!parseLocalDayKey(dayKey)) continue;
      const perDeviceRaw = rec.perDevice;
      if (!perDeviceRaw || typeof perDeviceRaw !== "object") continue;
      let target = mergedBuckets.get(dayKey);
      for (const [deviceId, val] of Object.entries(perDeviceRaw as Record<string, unknown>)) {
        if (!deviceId || typeof val !== "number" || !Number.isFinite(val) || val <= 0) continue;
        if (!target) {
          target = {};
          mergedBuckets.set(dayKey, target);
        }
        target[deviceId] = (target[deviceId] ?? 0) + val;
      }
    }
  }

  const sortedDayKeys = [...mergedBuckets.keys()].sort();
  const keptDayKeys = sortedDayKeys.slice(-ENERGY_RETENTION_DAYS);
  result.buckets = keptDayKeys.map((dayKey) => ({
    dayKey,
    perDevice: mergedBuckets.get(dayKey)!,
  }));

  const observedSet = new Set<string>();
  if (Array.isArray(obj.observedDays)) {
    for (const entry of obj.observedDays) {
      if (typeof entry === "string" && parseLocalDayKey(entry)) {
        observedSet.add(entry);
      }
    }
  }
  const sortedObserved = [...observedSet].sort();
  result.observedDays = sortedObserved.slice(-ENERGY_RETENTION_DAYS);

  return result;
}

export function formatKwhText(kwh: number): string {
  if (!Number.isFinite(kwh) || kwh <= 0) return "0.00 kWh";
  if (kwh < 0.01) return "<0.01 kWh";
  return `${kwh.toFixed(2)} kWh`;
}

export function formatCurrencyCost(cost: number, currencySymbol = "¥"): string {
  const safe = Number.isFinite(cost) && cost >= 0 ? cost : 0;
  return `≈ ${currencySymbol}${safe.toFixed(2)}`;
}

export function formatPriceDraftText(pricePerKwh: number | null): string {
  if (pricePerKwh === null || !Number.isFinite(pricePerKwh) || pricePerKwh <= 0) return "";
  const fixed2 = pricePerKwh.toFixed(2);
  if (Math.abs(Number(fixed2) - pricePerKwh) < 1e-6) {
    return fixed2;
  }
  return String(Number(pricePerKwh.toFixed(4)));
}

export class EnergyHistory {
  public static readonly retentionDays = ENERGY_RETENTION_DAYS;
  public static readonly topDeviceLimit = ENERGY_TOP_DEVICE_LIMIT;

  private readonly explicitStorage: EnergyStorageLike | null;
  public readonly scope: string;
  public readonly storageKey: string;
  public readonly priceStorageKey: string;

  private stored: EnergyHistoryStored = emptyStored();
  private cachedPricePerKwh: number | null = null;
  private lastStorageRef: EnergyStorageLike | null = null;
  private lastRawHistory: string | null | undefined = undefined;
  private lastRawPrice: string | null | undefined = undefined;

  public constructor(options: EnergyHistoryOptions = {}) {
    this.explicitStorage = options.storage ?? null;
    this.scope = options.scope ?? "default";
    this.storageKey = options.storageKey ?? energyStorageKeyForScope(this.scope);
    this.priceStorageKey = options.priceStorageKey ?? ENERGY_PRICE_STORAGE_KEY;
    this.syncFromStorage();
  }

  private activeStorage(): EnergyStorageLike {
    return resolveActiveStorage(this.explicitStorage);
  }

  private syncFromStorage(): void {
    const storage = this.activeStorage();
    if (storage !== this.lastStorageRef) {
      this.lastStorageRef = storage;
      this.lastRawHistory = undefined;
      this.lastRawPrice = undefined;
    }
    let rawHistory: string | null = null;
    let rawPrice: string | null = null;
    try {
      rawHistory = storage.getItem(this.storageKey);
      rawPrice = storage.getItem(this.priceStorageKey);
    } catch {
      rawHistory = null;
      rawPrice = null;
    }

    if (rawHistory !== this.lastRawHistory) {
      this.lastRawHistory = rawHistory;
      if (!rawHistory) {
        this.stored = emptyStored();
      } else {
        try {
          this.stored = sanitizeStored(JSON.parse(rawHistory) as unknown);
        } catch {
          this.stored = emptyStored();
        }
      }
    }

    if (rawPrice !== this.lastRawPrice) {
      this.lastRawPrice = rawPrice;
      if (!rawPrice) {
        this.cachedPricePerKwh = null;
      } else {
        const parsed = Number(rawPrice);
        this.cachedPricePerKwh = sanitizePriceValue(parsed);
      }
    }
  }

  private persistHistory(): void {
    try {
      const storage = this.activeStorage();
      const encoded = JSON.stringify(this.stored);
      storage.setItem(this.storageKey, encoded);
      this.lastStorageRef = storage;
      this.lastRawHistory = encoded;
    } catch {
      return;
    }
  }

  public get recordingStartedAt(): Date | null {
    this.syncFromStorage();
    const ms = this.stored.recordingStartedAtMs;
    return ms !== null && Number.isFinite(ms) ? new Date(ms) : null;
  }

  public get hasMeasuredConsumption(): boolean {
    this.syncFromStorage();
    return this.stored.buckets.some((bucket) =>
      Object.values(bucket.perDevice).some((v) => Number.isFinite(v) && v > 0),
    );
  }

  public get pricePerKwh(): number | null {
    this.syncFromStorage();
    return this.cachedPricePerKwh;
  }

  public get electricityPricePerKwh(): number | null {
    return this.pricePerKwh;
  }

  public set electricityPricePerKwh(value: number | null) {
    this.setPricePerKwh(value);
  }

  public setPricePerKwh(value: number | null): void {
    this.syncFromStorage();
    const sanitized = sanitizePriceValue(value);
    this.cachedPricePerKwh = sanitized;
    try {
      const storage = this.activeStorage();
      this.lastStorageRef = storage;
      if (sanitized !== null) {
        const encoded = String(sanitized);
        storage.setItem(this.priceStorageKey, encoded);
        this.lastRawPrice = encoded;
      } else {
        storage.removeItem(this.priceStorageKey);
        this.lastRawPrice = null;
      }
    } catch {
      return;
    }
  }

  public applyPriceInput(rawInput: string): ElectricityPriceApplyResult {
    this.syncFromStorage();
    const trimmed = rawInput.trim();
    if (trimmed === "") {
      this.setPricePerKwh(null);
      return { action: "cleared", pricePerKwh: null };
    }
    const normalized = trimmed.replace(/,/g, ".");
    if (/^[+]?(?:\d+\.?\d*|\.\d+)$/.test(normalized)) {
      const parsed = Number(normalized);
      const valid = sanitizePriceValue(parsed);
      if (valid !== null) {
        this.setPricePerKwh(valid);
        return { action: "saved", pricePerKwh: valid };
      }
    }
    return { action: "kept", pricePerKwh: this.cachedPricePerKwh };
  }

  public record(devices: readonly SmartDevice[], now: Date = new Date()): void {
    const nowMs = now.getTime();
    if (!Number.isFinite(nowMs) || nowMs <= 0) return;

    this.syncFromStorage();
    let shouldPersist = false;
    let observedCounter = false;

    for (const device of devices) {
      if (!device.isOnline || device.kind.kind !== "plug") continue;
      const reading = device.kind.energyKwh;
      if (
        typeof reading !== "number" ||
        !Number.isFinite(reading) ||
        reading < 0 ||
        reading > MAX_ENERGY_COUNTER_KWH
      ) {
        continue;
      }
      observedCounter = true;

      const trimmedName = device.name.trim();
      if (trimmedName !== "" && this.stored.names[device.id] !== trimmedName) {
        this.stored.names[device.id] = trimmedName;
        shouldPersist = true;
      }
      const trimmedRoom = (device.roomName ?? "").trim();
      if ((this.stored.rooms[device.id] ?? "") !== trimmedRoom) {
        this.stored.rooms[device.id] = trimmedRoom;
        shouldPersist = true;
      }

      const lastSeenMs = this.stored.lastSampleAtMs[device.id];
      if (lastSeenMs !== undefined && nowMs <= lastSeenMs) {
        continue;
      }
      this.stored.lastSampleAtMs[device.id] = nowMs;

      if (lastSeenMs === undefined || !isSameLocalDayMs(lastSeenMs, nowMs)) {
        shouldPersist = true;
      }

      const baseline = this.stored.baselines[device.id];
      if (baseline === undefined) {
        this.stored.baselines[device.id] = reading;
        if (this.stored.recordingStartedAtMs === null) {
          this.stored.recordingStartedAtMs = nowMs;
        }
        shouldPersist = true;
        continue;
      }

      if (baseline !== reading) {
        this.stored.baselines[device.id] = reading;
        shouldPersist = true;
      }

      if (reading < baseline) {
        continue;
      }

      const delta = reading - baseline;
      if (!Number.isFinite(delta) || delta <= 0) {
        continue;
      }

      if (delta > MAX_SINGLE_DELTA_KWH) {
        continue;
      }

      if (lastSeenMs === undefined || !this.isInsideRetentionWindow(lastSeenMs, now)) {
        continue;
      }

      this.addDelta(delta, device.id, new Date(lastSeenMs));
      shouldPersist = true;
    }

    if (observedCounter) {
      const todayKey = localDayKey(now);
      if (!this.stored.observedDays.includes(todayKey)) {
        this.stored.observedDays.push(todayKey);
        shouldPersist = true;
      }
    }

    if (!shouldPersist) return;
    this.prune(now);
    this.persistHistory();
  }

  private addDelta(delta: number, deviceId: string, at: Date): void {
    const dayKey = localDayKey(at);
    const existing = this.stored.buckets.find((b) => b.dayKey === dayKey);
    if (existing) {
      existing.perDevice[deviceId] = (existing.perDevice[deviceId] ?? 0) + delta;
    } else {
      this.stored.buckets.push({
        dayKey,
        perDevice: { [deviceId]: delta },
      });
    }
  }

  private isInsideRetentionWindow(sampleMs: number, now: Date): boolean {
    const today = startOfLocalDay(now);
    const cutoff = addLocalDays(today, -(ENERGY_RETENTION_DAYS - 1));
    const sampleDay = startOfLocalDay(new Date(sampleMs));
    return sampleDay.getTime() >= cutoff.getTime() && sampleDay.getTime() <= today.getTime();
  }

  private prune(now: Date): void {
    const today = startOfLocalDay(now);
    const cutoff = addLocalDays(today, -(ENERGY_RETENTION_DAYS - 1));
    const cutoffKey = localDayKey(cutoff);
    const cutoffMs = cutoff.getTime();

    this.stored.buckets = this.stored.buckets
      .filter((bucket) => bucket.dayKey >= cutoffKey)
      .sort((a, b) => (a.dayKey < b.dayKey ? -1 : a.dayKey > b.dayKey ? 1 : 0));

    this.stored.observedDays = [...new Set(this.stored.observedDays)]
      .filter((dayKey) => dayKey >= cutoffKey)
      .sort();

    const activeIds = new Set<string>();
    for (const bucket of this.stored.buckets) {
      for (const id of Object.keys(bucket.perDevice)) {
        activeIds.add(id);
      }
    }
    for (const [id, seenMs] of Object.entries(this.stored.lastSampleAtMs)) {
      if (seenMs >= cutoffMs) {
        activeIds.add(id);
      }
    }

    for (const id of Object.keys(this.stored.baselines)) {
      if (!activeIds.has(id)) delete this.stored.baselines[id];
    }
    for (const id of Object.keys(this.stored.lastSampleAtMs)) {
      if (!activeIds.has(id)) delete this.stored.lastSampleAtMs[id];
    }
    for (const id of Object.keys(this.stored.names)) {
      if (!activeIds.has(id)) delete this.stored.names[id];
    }
    for (const id of Object.keys(this.stored.rooms)) {
      if (!activeIds.has(id)) delete this.stored.rooms[id];
    }
  }

  public dailyTotals(dayCount = 7, now: Date = new Date()): EnergyDayTotal[] {
    this.syncFromStorage();
    const count = Math.min(Math.max(Math.trunc(dayCount) || 1, 1), ENERGY_RETENTION_DAYS);
    const today = startOfLocalDay(now);
    const first = addLocalDays(today, -(count - 1));
    const bucketByKey = new Map(this.stored.buckets.map((b) => [b.dayKey, b]));
    const observedSet = new Set(this.stored.observedDays);

    const out: EnergyDayTotal[] = [];
    for (let offset = 0; offset < count; offset++) {
      const day = addLocalDays(first, offset);
      const dayKey = localDayKey(day);
      const bucket = bucketByKey.get(dayKey);
      const kwh = bucket ? sumPositiveFinite(Object.values(bucket.perDevice)) : 0;
      const isObserved = bucket !== undefined || observedSet.has(dayKey);
      out.push({ dayKey, day, kwh, isObserved });
    }
    return out;
  }

  public todayTotalKwh(now: Date = new Date()): number {
    return this.dailyTotals(1, now)[0]?.kwh ?? 0;
  }

  public isTodayObserved(now: Date = new Date()): boolean {
    return this.dailyTotals(1, now)[0]?.isObserved ?? false;
  }

  public totalKwh(dayCount = 7, now: Date = new Date()): number {
    return sumPositiveFinite(this.dailyTotals(dayCount, now).map((d) => d.kwh));
  }

  public todayKwh(deviceId: string, now: Date = new Date()): number | null {
    this.syncFromStorage();
    const todayKey = localDayKey(now);
    const bucket = this.stored.buckets.find((b) => b.dayKey === todayKey);
    const bucketKwh = bucket?.perDevice[deviceId];
    if (typeof bucketKwh === "number" && Number.isFinite(bucketKwh) && bucketKwh >= 0) {
      return bucketKwh;
    }
    const baseline = this.stored.baselines[deviceId];
    const lastSeenMs = this.stored.lastSampleAtMs[deviceId];
    if (
      baseline === undefined ||
      lastSeenMs === undefined ||
      !isSameLocalDayMs(lastSeenMs, now.getTime())
    ) {
      return null;
    }
    return 0;
  }

  public deviceTotals(
    dayCount = 7,
    liveDevices: readonly SmartDevice[] = [],
    now: Date = new Date(),
  ): EnergyDeviceTotal[] {
    this.syncFromStorage();
    const count = Math.min(Math.max(Math.trunc(dayCount) || 1, 1), ENERGY_RETENTION_DAYS);
    const today = startOfLocalDay(now);
    const firstKey = localDayKey(addLocalDays(today, -(count - 1)));
    const todayKey = localDayKey(today);

    const perDevice = new Map<string, number>();
    for (const bucket of this.stored.buckets) {
      if (bucket.dayKey < firstKey || bucket.dayKey > todayKey) continue;
      for (const [deviceId, kwh] of Object.entries(bucket.perDevice)) {
        if (!Number.isFinite(kwh) || kwh <= 0) continue;
        perDevice.set(deviceId, (perDevice.get(deviceId) ?? 0) + kwh);
      }
    }

    if (perDevice.size === 0) return [];

    const liveById = new Map<string, SmartDevice>();
    for (const dev of liveDevices) {
      if (!liveById.has(dev.id)) {
        liveById.set(dev.id, dev);
      }
    }

    const rawEntries: Array<{ deviceId: string; name: string; roomName: string; kwh: number }> = [];
    for (const [deviceId, kwh] of perDevice.entries()) {
      if (!Number.isFinite(kwh) || kwh <= 0) continue;
      const live = liveById.get(deviceId);
      const name = live?.name.trim() || this.stored.names[deviceId] || deviceId;
      const roomName = (live?.roomName ?? "").trim() || this.stored.rooms[deviceId] || "";
      rawEntries.push({ deviceId, name, roomName, kwh });
    }

    rawEntries.sort((a, b) => {
      if (a.kwh !== b.kwh) return b.kwh - a.kwh;
      return a.name.localeCompare(b.name);
    });

    const totalWindowKwh = sumPositiveFinite(rawEntries.map((item) => item.kwh));
    const maxKwh = rawEntries[0]?.kwh ?? 0;

    return rawEntries.map((item) => ({
      deviceId: item.deviceId,
      name: item.name,
      roomName: item.roomName,
      kwh: item.kwh,
      share: totalWindowKwh > 0 ? Math.min(1, Math.max(0, item.kwh / totalWindowKwh)) : 0,
      barFraction: maxKwh > 0 ? Math.min(1, Math.max(0, item.kwh / maxKwh)) : 0,
    }));
  }

  public topDevices(
    dayCount = 7,
    limit = ENERGY_TOP_DEVICE_LIMIT,
    liveDevices: readonly SmartDevice[] = [],
    now: Date = new Date(),
  ): EnergyDeviceTotal[] {
    return this.deviceTotals(dayCount, liveDevices, now).slice(0, Math.max(0, Math.trunc(limit)));
  }

  public costForKwh(kwh: number): number | null {
    const price = this.pricePerKwh;
    if (price === null || !Number.isFinite(kwh) || kwh < 0) return null;
    const cost = kwh * price;
    return Number.isFinite(cost) ? cost : null;
  }

  public totalCost(dayCount = 7, now: Date = new Date()): number | null {
    return this.costForKwh(this.totalKwh(dayCount, now));
  }

  public clear(): void {
    this.syncFromStorage();
    this.stored = emptyStored();
    this.persistHistory();
  }
}

const scopedHistoryRegistry = new Map<string, EnergyHistory>();

export function getScopedEnergyHistory(source: EnergyScopeSource): EnergyHistory {
  const scope = energyScopeKey(source);
  let instance = scopedHistoryRegistry.get(scope);
  if (!instance) {
    instance = new EnergyHistory({ scope });
    scopedHistoryRegistry.set(scope, instance);
  }
  return instance;
}
