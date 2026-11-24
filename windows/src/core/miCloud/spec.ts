import { currentLanguage } from "../i18n.js";
import type { MiDeviceRecord } from "./client.js";
import fallbackSpecs from "./fallbackSpecs.json";
import type { HttpTransport } from "./session.js";
import { applySpecPatches, SPEC_PATCHES, type SpecPatchesDocument } from "./specPatches.js";
import {
  applyMultiLanguage,
  MULTI_LANGUAGE_CACHE_TTL_MS,
  multiLanguageCacheKey,
  parseMultiLanguageDocument,
  type SpecMultiLanguage,
} from "./specLocalization.js";

export interface MiotValueListItem {
  readonly value: number;
  readonly description: string;
}

export interface MiotProperty {
  readonly iid: number;
  readonly type: string;
  readonly description?: string;
  readonly format: string;
  readonly access: readonly string[];
  readonly valueRange?: readonly number[];
  readonly valueList?: readonly MiotValueListItem[];
  readonly unit?: string;
  readonly comment?: string;
}

export interface MiotAction {
  readonly iid: number;
  readonly type: string;
  readonly description?: string;
  readonly in?: readonly number[];
}

export interface MiotService {
  readonly iid: number;
  readonly type: string;
  readonly description?: string;
  readonly properties: readonly MiotProperty[];
  readonly actions: readonly MiotAction[];
}

export interface MiotDeviceSpec {
  readonly type: string;
  readonly description?: string;
  readonly services: readonly MiotService[];
}

/**
 * An `electronic-valve` is a mains breaker only when it meters electric power (#265). A water or
 * gas shut-off valve shares the service and stays unsupported. Mirrors `MiotSynthesizer.isMainsBreaker`.
 */
export function isMainsBreaker(spec: MiotDeviceSpec): boolean {
  return (
    spec.services.some((s) => miotShortName(s.type) === "electronic-valve") &&
    spec.services.some(
      (s) =>
        miotShortName(s.type) === "power-consumption" &&
        s.properties.some((p) => miotShortName(p.type) === "electric-power"),
    )
  );
}

export function miotShortName(urn: string): string {
  const parts = urn.split(":");
  return parts[3] ?? urn;
}

export function makeMiotAddress(did: string, siid: number): string {
  return `miot:${did}:${siid}`;
}

export function parseMiotAddress(entityId: string): { did: string; siid: number } | null {
  if (!entityId.startsWith("miot:")) return null;
  const clean = entityId.split("#")[0] ?? entityId;
  const rest = clean.slice("miot:".length);
  const sep = rest.lastIndexOf(":");
  if (sep <= 0) return null;
  const did = rest.slice(0, sep);
  const siid = Number(rest.slice(sep + 1));
  if (!Number.isSafeInteger(siid)) return null;
  return { did, siid };
}

/** A no-argument MIoT action address: `miot-action:<did>:<siid>:<aiid>` (macOS `MiotAddress.makeAction`). */
export function makeMiotActionAddress(did: string, siid: number, aiid: number): string {
  return `miot-action:${did}:${siid}:${aiid}`;
}

export function parseMiotActionAddress(entityId: string): { did: string; siid: number; aiid: number } | null {
  const prefix = "miot-action:";
  if (!entityId.startsWith(prefix)) return null;
  const parts = entityId.slice(prefix.length).split(":");
  if (parts.length < 3) return null;
  const aiid = Number(parts[parts.length - 1]);
  const siid = Number(parts[parts.length - 2]);
  const did = parts.slice(0, -2).join(":");
  if (!did || !Number.isSafeInteger(siid) || !Number.isSafeInteger(aiid)) return null;
  return { did, siid, aiid };
}

export function hvacModeFromDescription(desc: string): string | null {
  switch (desc.trim().toLowerCase()) {
    case "cool":
    case "cooling":
    case "cold":
      return "cool";
    case "heat":
    case "heating":
    case "warm":
      return "heat";
    case "dry":
    case "dehumidify":
    case "dehumidification":
    case "dehumidifier":
      return "dry";
    case "fan":
    case "fan only":
    case "fan-only":
    case "fan_only":
    case "wind":
    case "ventilate":
      return "fan_only";
    case "auto":
    case "automatic":
    case "smart":
      return "auto";
    default:
      return null;
  }
}

function decodeValueList(rawList: unknown): MiotValueListItem[] | undefined {
  if (!Array.isArray(rawList)) return undefined;
  const out: MiotValueListItem[] = [];
  for (const item of rawList) {
    if (!item || typeof item !== "object") return undefined;
    const rec = item as Record<string, unknown>;
    const rawVal = rec["value"];
    if (typeof rawVal !== "number" || !Number.isFinite(rawVal)) return undefined;
    const truncated = Math.trunc(rawVal);
    if (!Number.isSafeInteger(truncated)) return undefined;
    out.push({
      value: Object.is(truncated, -0) ? 0 : truncated,
      description: typeof rec["description"] === "string" ? rec["description"] : "",
    });
  }
  return out;
}

export function parseMiotDeviceSpec(raw: unknown): MiotDeviceSpec | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const type = typeof obj["type"] === "string" ? obj["type"] : "";
  const rawServices = Array.isArray(obj["services"]) ? obj["services"] : null;
  if (!type || !rawServices) return null;

  const services: MiotService[] = [];
  for (const s of rawServices) {
    if (!s || typeof s !== "object") continue;
    const sObj = s as Record<string, unknown>;
    const sIid = typeof sObj["iid"] === "number" ? Math.trunc(sObj["iid"]) : NaN;
    const sType = typeof sObj["type"] === "string" ? sObj["type"] : "";
    if (!Number.isSafeInteger(sIid) || !sType) continue;

    const rawProps = Array.isArray(sObj["properties"]) ? sObj["properties"] : [];
    const properties: MiotProperty[] = [];
    for (const p of rawProps) {
      if (!p || typeof p !== "object") continue;
      const pObj = p as Record<string, unknown>;
      const pIid = typeof pObj["iid"] === "number" ? Math.trunc(pObj["iid"]) : NaN;
      const pType = typeof pObj["type"] === "string" ? pObj["type"] : "";
      if (!Number.isSafeInteger(pIid) || !pType) continue;
      const format = typeof pObj["format"] === "string" ? pObj["format"] : "string";
      const access = Array.isArray(pObj["access"])
        ? pObj["access"].filter((a): a is string => typeof a === "string")
        : [];
      const rawRange = pObj["value-range"] ?? pObj["valueRange"];
      const valueRange = Array.isArray(rawRange)
        ? rawRange
            .map((v) => (typeof v === "number" ? v : Number(v)))
            .filter((v) => Number.isFinite(v))
        : undefined;
      const rawList = pObj["value-list"] ?? pObj["valueList"];
      const valueList = decodeValueList(rawList);

      const unit = typeof pObj["unit"] === "string" ? pObj["unit"] : undefined;
      const comment = typeof pObj["comment"] === "string" ? pObj["comment"] : undefined;

      properties.push({
        iid: Object.is(pIid, -0) ? 0 : pIid,
        type: pType,
        ...(typeof pObj["description"] === "string" ? { description: pObj["description"] } : {}),
        format,
        access,
        ...(valueRange ? { valueRange } : {}),
        ...(valueList ? { valueList } : {}),
        ...(unit !== undefined ? { unit } : {}),
        ...(comment !== undefined ? { comment } : {}),
      });
    }

    const rawActions = Array.isArray(sObj["actions"]) ? sObj["actions"] : [];
    const actions: MiotAction[] = [];
    for (const a of rawActions) {
      if (!a || typeof a !== "object") continue;
      const aObj = a as Record<string, unknown>;
      const aIid = typeof aObj["iid"] === "number" ? Math.trunc(aObj["iid"]) : NaN;
      const aType = typeof aObj["type"] === "string" ? aObj["type"] : "";
      const rawIn = Array.isArray(aObj["in"])
        ? aObj["in"]
            .filter((v): v is number => typeof v === "number" && Number.isFinite(v))
            .map((v) => Math.trunc(v))
            .filter((v) => Number.isSafeInteger(v))
            .map((v) => (Object.is(v, -0) ? 0 : v))
        : undefined;
      if (Number.isSafeInteger(aIid) && aType) {
        actions.push({
          iid: Object.is(aIid, -0) ? 0 : aIid,
          type: aType,
          ...(typeof aObj["description"] === "string" ? { description: aObj["description"] } : {}),
          ...(rawIn && rawIn.length > 0 ? { in: rawIn } : {}),
        });
      }
    }

    services.push({
      iid: Object.is(sIid, -0) ? 0 : sIid,
      type: sType,
      ...(typeof sObj["description"] === "string" ? { description: sObj["description"] } : {}),
      properties,
      actions,
    });
  }

  return {
    type,
    ...(typeof obj["description"] === "string" ? { description: obj["description"] } : {}),
    services,
  };
}

function miotStatusRank(rawStatus: unknown): number {
  if (typeof rawStatus !== "string") return 2;
  const trimmed = rawStatus.trim().toLowerCase();
  if (!trimmed) return 2;
  if (trimmed === "released") return 3;
  if (trimmed === "preview") return 1;
  return 0;
}

export function parseMiotInstanceIndex(raw: unknown): Record<string, string> {
  if (!raw || typeof raw !== "object") return {};
  const instances = (raw as Record<string, unknown>)["instances"];
  if (!Array.isArray(instances)) return {};

  const best = new Map<string, { rank: number; version: number; type: string }>();
  for (const item of instances) {
    if (!item || typeof item !== "object") continue;
    const rec = item as Record<string, unknown>;
    const model = typeof rec["model"] === "string" ? rec["model"] : "";
    const type = typeof rec["type"] === "string" ? rec["type"] : "";
    const version = typeof rec["version"] === "number" ? rec["version"] : 0;
    if (!model || !type) continue;
    const rank = miotStatusRank(rec["status"]);
    const prev = best.get(model);
    if (!prev || rank > prev.rank || (rank === prev.rank && version > prev.version)) {
      best.set(model, { rank, version, type });
    }
  }

  const out: Record<string, string> = {};
  for (const [model, info] of best.entries()) {
    out[model] = info.type;
  }
  return out;
}

interface FallbackSpecRule {
  readonly id: string;
  readonly modelAny?: readonly string[];
  readonly modelSuffix?: readonly string[];
  readonly nameAny?: readonly string[];
  readonly spec: MiotDeviceSpec;
}

const FALLBACK_SPEC_DOCUMENT = fallbackSpecs as {
  readonly rules: readonly FallbackSpecRule[];
  readonly fallback: { readonly id: string; readonly spec: MiotDeviceSpec };
};

/**
 * Guessed specs are read-only until a released model spec replaces them (#154).
 * The model/name table lives in `fallbackSpecs.json` so adding a pattern is data.
 */
export function inferFallbackSpec(record: Pick<MiDeviceRecord, "model" | "name">): MiotDeviceSpec {
  const model = record.model.toLowerCase();
  const name = record.name.toLowerCase();
  for (const rule of FALLBACK_SPEC_DOCUMENT.rules) {
    const matchesModel = rule.modelAny?.some((token) => model.includes(token)) ?? false;
    const matchesSuffix = rule.modelSuffix?.some((token) => model.endsWith(token)) ?? false;
    const matchesName = rule.nameAny?.some((token) => name.includes(token)) ?? false;
    if (matchesModel || matchesSuffix || matchesName) return structuredClone(rule.spec);
  }
  return structuredClone(FALLBACK_SPEC_DOCUMENT.fallback.spec);
}

/**
 * True for the guessed, read-only table above: it tags every URN with `fallback` as the vendor
 * segment. A cached guess must be retried instead of trusted forever (#30).
 */
export function isFallbackSpec(spec: MiotDeviceSpec): boolean {
  return spec.type.split(":")[5] === "fallback";
}

export class MiotSpecResolver {
  static readonly indexCacheVersion = 2;

  private readonly specByModel = new Map<string, MiotDeviceSpec>();
  private readonly specByType = new Map<string, MiotDeviceSpec>();
  private readonly inFlightByType = new Map<string, Promise<MiotDeviceSpec | null>>();
  /// Versioned key (`v1:<urn>`) and 30-day lifetime mirror the macOS disk cache (#480).
  private readonly translationsByKey = new Map<string, { document: SpecMultiLanguage; fetchedAt: number }>();
  private readonly multiLanguageInFlight = new Map<string, Promise<void>>();
  private readonly urnByModel = new Map<string, string>();
  /// Models served by the guessed table; every resolve() retries the upstream instance (#30).
  private readonly fallbackModels = new Set<string>();
  private typeIndex: Record<string, string> | null = null;
  private indexPromise: Promise<Record<string, string>> | null = null;

  constructor(
    private readonly transport: HttpTransport,
    initialModelSpecs?: Readonly<Record<string, MiotDeviceSpec>>,
    initialModelTypes?: Readonly<Record<string, string>>,
    private readonly patches: SpecPatchesDocument = SPEC_PATCHES,
    private readonly nowMs: () => number = () => Date.now(),
    private readonly multiLanguageMaxAgeMs: number = MULTI_LANGUAGE_CACHE_TTL_MS,
  ) {
    if (initialModelSpecs) {
      for (const [m, s] of Object.entries(initialModelSpecs)) {
        this.specByModel.set(m, applySpecPatches(s, m, this.patches));
        if (isFallbackSpec(s)) this.fallbackModels.add(m);
      }
    }
    if (initialModelTypes && Object.keys(initialModelTypes).length > 0) {
      this.typeIndex = { ...initialModelTypes };
    }
  }

  exportCachedSpecs(): Record<string, MiotDeviceSpec> {
    const out: Record<string, MiotDeviceSpec> = {};
    for (const [k, v] of this.specByModel.entries()) {
      out[k] = v;
    }
    return out;
  }

  exportKnownModelTypes(models: readonly string[]): Record<string, string> {
    if (!this.typeIndex) return {};
    const out: Record<string, string> = {};
    for (const m of models) {
      const t = this.typeIndex[m];
      if (t) out[m] = t;
    }
    return out;
  }

  async resolveForDevices(devices: readonly MiDeviceRecord[]): Promise<Record<string, MiotDeviceSpec>> {
    const needsIndex = devices.some(
      (d) => !this.specByModel.has(d.model) && (!d.specType || d.specType.trim() === ""),
    );
    if (needsIndex) {
      await this.loadTypeIndex().catch(() => ({}));
    }

    await Promise.all(
      devices.map(async (dev) => {
        await this.resolve(dev);
      }),
    );

    return this.exportCachedSpecs();
  }

  async resolve(device: MiDeviceRecord): Promise<MiotDeviceSpec> {
    const existing = this.specByModel.get(device.model);
    if (existing && !this.fallbackModels.has(device.model)) return existing;

    let urn = device.specType && device.specType.trim() !== "" ? device.specType.trim() : null;
    if (!urn) {
      const idx = await this.loadTypeIndex().catch(() => ({} as Record<string, string>));
      urn = idx[device.model] ?? null;
    }

    if (urn) {
      this.urnByModel.set(device.model, urn);
      const fetched = await this.fetchInstance(urn);
      if (fetched) {
        const entry = this.translationsByKey.get(multiLanguageCacheKey(urn));
        const translations = entry && this.nowMs() - entry.fetchedAt < this.multiLanguageMaxAgeMs
          ? entry.document
          : undefined;
        const localized = applyMultiLanguage(fetched, translations, currentLanguage());
        // Patches run last so Shared/specPatches.json still beats official translations (#480).
        const patched = applySpecPatches(localized, device.model, this.patches);
        this.fallbackModels.delete(device.model);
        this.specByModel.set(device.model, patched);
        return patched;
      }
    }

    // Keep the fallback the previous attempt returned; a later refresh tries the network again.
    if (existing) return existing;
    const fallback = applySpecPatches(inferFallbackSpec(device), device.model, this.patches);
    this.specByModel.set(device.model, fallback);
    this.fallbackModels.add(device.model);
    return fallback;
  }

  private async fetchTypeIndexStatus(status: "all" | "released"): Promise<Record<string, string> | null> {
    try {
      const resp = await this.transport({
        url: `https://miot-spec.org/miot-spec-v2/instances?status=${status}`,
        method: "GET",
        timeoutMs: 45000,
      });
      if (resp.status === 200) {
        const parsed = parseMiotInstanceIndex(JSON.parse(resp.body));
        if (Object.keys(parsed).length > 0) return parsed;
      }
    } catch {
      // network fallback
    }
    return null;
  }

  private async loadTypeIndex(): Promise<Record<string, string>> {
    if (this.typeIndex && Object.keys(this.typeIndex).length > 100) {
      return this.typeIndex;
    }
    if (this.indexPromise) {
      return this.indexPromise;
    }
    this.indexPromise = (async () => {
      const parsed =
        (await this.fetchTypeIndexStatus("all")) ??
        (await this.fetchTypeIndexStatus("released"));
      if (parsed) {
        this.typeIndex = { ...(this.typeIndex ?? {}), ...parsed };
        return this.typeIndex;
      }
      // A failed index fetch must not stay cached as the empty answer, or resolve() keeps
      // returning the fallback even after the network recovers (#30).
      this.indexPromise = null;
      return this.typeIndex ?? {};
    })();
    return this.indexPromise;
  }

  private async fetchInstance(urn: string): Promise<MiotDeviceSpec | null> {
    const cached = this.specByType.get(urn);
    if (cached) return cached;
    const inFlight = this.inFlightByType.get(urn);
    if (inFlight) return inFlight;

    const task = (async (): Promise<MiotDeviceSpec | null> => {
      try {
        const resp = await this.transport({
          url: `https://miot-spec.org/miot-spec-v2/instance?type=${encodeURIComponent(urn)}`,
          method: "GET",
          timeoutMs: 15000,
        });
        if (resp.status !== 200) return null;
        const spec = parseMiotDeviceSpec(JSON.parse(resp.body));
        if (spec && spec.services.length > 0) {
          this.specByType.set(urn, spec);
          // Only fetched alongside a real spec refresh; never blocks that spec on failure.
          void this.refreshMultiLanguage(urn);
          return spec;
        }
      } catch {
        return null;
      }
      return null;
    })();

    this.inFlightByType.set(urn, task);
    try {
      return await task;
    } finally {
      this.inFlightByType.delete(urn);
    }
  }

  private async refreshMultiLanguage(urn: string): Promise<void> {
    const key = multiLanguageCacheKey(urn);
    const cached = this.translationsByKey.get(key);
    if (cached && this.nowMs() - cached.fetchedAt < this.multiLanguageMaxAgeMs) return;
    const inFlight = this.multiLanguageInFlight.get(key);
    if (inFlight) return inFlight;

    const task = (async () => {
      try {
        const resp = await this.transport({
          url: `https://miot-spec.org/instance/v2/multiLanguage?urn=${encodeURIComponent(urn)}`,
          method: "GET",
          timeoutMs: 15000,
        });
        if (resp.status !== 200) return;
        const parsed = parseMultiLanguageDocument(JSON.parse(resp.body));
        if (parsed && Object.keys(parsed.data).length > 0) {
          this.translationsByKey.set(key, { document: parsed, fetchedAt: this.nowMs() });
          this.refreshCachedSpecsForUrn(urn);
        }
      } catch {
        // Optional data: keep a stale entry, or leave raw spec descriptions in place.
      }
    })();

    this.multiLanguageInFlight.set(key, task);
    try {
      await task;
    } finally {
      this.multiLanguageInFlight.delete(key);
    }
  }

  /// Test hook: spec resolution returns before the optional translation completes.
  async waitForMultiLanguageRefresh(urn: string): Promise<void> {
    const pending = this.multiLanguageInFlight.get(multiLanguageCacheKey(urn));
    if (pending) await pending;
  }

  /// Put the newly available labels into specs already cached for this URN.
  private refreshCachedSpecsForUrn(urn: string): void {
    const raw = this.specByType.get(urn);
    const entry = this.translationsByKey.get(multiLanguageCacheKey(urn));
    if (!raw || !entry) return;
    for (const [model, modelUrn] of this.urnByModel) {
      if (modelUrn !== urn) continue;
      const localized = applyMultiLanguage(raw, entry.document, currentLanguage());
      this.specByModel.set(model, applySpecPatches(localized, model, this.patches));
    }
  }
}
