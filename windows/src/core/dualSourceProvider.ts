import { HomeAssistantSynthesizer, type HAInvoke } from "./homeAssistant.js";
import type { ExecuteOptions, HomeProvider } from "./homeProvider.js";
import { currentLanguage, resolveLanguage, type AppLanguage, type LanguagePreference,
} from "./i18n.js";
import type { AccountScopedHomeOption, AccountScopedSmartDevice,
} from "./miAccountsStore.js";
import { parseMiotActionAddress, parseMiotAddress } from "./miCloud/spec.js";
import type { MiDeviceRecord } from "./miCloudClient.js";
import { deviceEnvironmentReading, environmentReadingPriority, type ConnectionStatus, type DeviceCommand,
  type DeviceKind, type EnvironmentReading, type FacetControl, type HomeBackend, type HomeScene, type RoomCategory,
  type SmartDevice, type SynthesizedHome,
} from "./models.js";

function tr3(zhHans: string, zhHant: string, en: string, params?: Readonly<Record<string, string | number>>,
  preference?: LanguagePreference): string { const lang: AppLanguage = preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : resolveLanguage(currentLanguage(), []);
  const template = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans; if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole);
}

function defaultStorage(): Storage | null { try { return typeof localStorage !== "undefined" ? localStorage : null;
  } catch { return null;
  }
}

export const PINNED_DEVICE_SOURCES_STORAGE_KEY = "menumijia.windows.pinnedDeviceSources.v1";
export const CANONICAL_DEVICE_REGISTRY_STORAGE_KEY = "menumijia.windows.canonicalDeviceIds.v1";
export const ROOM_IDENTITY_REGISTRY_STORAGE_KEY = "menumijia.windows.roomIdentities.v1";
export const DUAL_SOURCE_ENABLED_STORAGE_KEY = "menumijia.windows.dualSourceEnabled.v1";

export type DeviceKindTag = DeviceKind["kind"];

export interface DeviceSourceIdentity { readonly dids: readonly string[];
  readonly macAddresses: readonly string[];
  readonly uniqueIds: readonly string[];
  readonly model: string;
  readonly name: string;
  readonly roomName: string;
  readonly kindTag: DeviceKindTag;
}

function sortedUnique(values: readonly string[]): string[] {
  return [...new Set(values.filter((v) => v.length > 0))].sort(); } 
function normalizeDisplayRoomName(raw: string): string { const trimmed = raw.trim();
  if (trimmed === "" ||
    trimmed === "默认房间" ||
    trimmed === "未分配" ||
    trimmed.toLowerCase() === "default" ||
    trimmed.toLowerCase() === "unassigned"
  ) { return "全屋";
  }
  return trimmed; } export function isRoomUnassigned(roomName: string): boolean { const name = roomName.trim();
  const lower = name.toLowerCase(); return (name === "" ||
    name === "全屋" ||
    name === "默认房间" ||
    name === "未分配" ||
    lower === "all rooms" ||
    lower === "default room" ||
    lower === "unassigned"
  );
}

export const DeviceIdentityNormalizer = {
  isDidLike(token: string): boolean { const value = token.trim().toLowerCase();
    if (!value) return false; if (value.startsWith("blt.") ||
      value.startsWith("group.") ||
      value.startsWith("miot.")
    ) { return true;
    }
    const dotIdx = value.indexOf("."); const head = dotIdx >= 0 ? value.slice(0, dotIdx) : value;
    return head.length >= 6 && /^\d+$/.test(head); }, 
    didCandidates(rawValues: readonly string[]): string[] { const candidates: string[] = [];
    for (const raw of rawValues) { const value = raw.trim().toLowerCase();
      if (!value) continue; if (this.isDidLike(value)) { candidates.push(value); }
      const groupMatch = /(?:^|[_:])group[_.]([a-z0-9]+)/i.exec(value);
      if (groupMatch?.[1]) { candidates.push(`group.${groupMatch[1].toLowerCase()}`); }
      const parts = value.split(/[_ :]+/);
      for (const part of parts) { if (this.isDidLike(part)) { candidates.push(part);
        }
      }
    }
    return sortedUnique(candidates); }, 
    macAddress(raw: string): string | null { const trimmed = raw.trim();
    if (!trimmed) return null; const isFormattedMac = /^[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}$/.test(trimmed) ||
      /^[0-9a-fA-F]{4}(?:\.[0-9a-fA-F]{4}){2}$/.test(trimmed) ||
      /^[0-9a-fA-F]{12}$/.test(trimmed);
    if (!isFormattedMac) return null; const hex = trimmed.replace(/[^0-9a-fA-F]/g, "").toLowerCase();
    if (hex.length !== 12) return null; if (hex === "000000000000" || hex === "ffffffffffff") return null; return hex;
  }, 
  normalizedRoomName(raw: string): string { return normalizeDisplayRoomName(raw).trim().toLowerCase();
  }, 
  normalizedToken(raw: string): string { return raw
      .toLowerCase()
      .replace(/[\s\p{P}\p{S}]+/gu, "");
  }, 
  sortedUnique,
} as const;

export function makeDeviceSourceIdentity(input: { readonly dids?: readonly string[];
  readonly macAddresses?: readonly string[];
  readonly uniqueIds?: readonly string[];
  readonly model?: string;
  readonly name?: string;
  readonly roomName?: string;
  readonly kindTag?: DeviceKindTag;
}): DeviceSourceIdentity { return {
    dids: sortedUnique((input.dids ?? []).map((v) => v.trim().toLowerCase())),
    macAddresses: sortedUnique((input.macAddresses ?? [])
        .map((v) => DeviceIdentityNormalizer.macAddress(v))
        .filter((v): v is string => v !== null)),
    uniqueIds: sortedUnique((input.uniqueIds ?? []).map((v) => v.trim().toLowerCase())),
    model: (input.model ?? "").trim(),
    name: (input.name ?? "").trim(),
    roomName: (input.roomName ?? "").trim(),
    kindTag: input.kindTag ?? "sensor",
  };
}

function stripTrackSuffix(deviceId: string): string { return deviceId.replace(/\.s\d+$/, "");
}

export function extractMiDeviceIdentities(records: readonly MiDeviceRecord[], synthesized: SynthesizedHome,
): Record<string, DeviceSourceIdentity> { const byDid = new Map<string, MiDeviceRecord>();
  for (const rec of records) { if (!byDid.has(rec.did)) byDid.set(rec.did, rec);
  }
  const out: Record<string, DeviceSourceIdentity> = {}; for (const device of synthesized.devices) { const rec =
      byDid.get(device.id) ?? byDid.get(stripTrackSuffix(device.id));
    const did = rec?.did ?? stripTrackSuffix(device.id);
    const macs = rec && !rec.splitParentDid && rec.mac ? [rec.mac] : []; out[device.id] = makeDeviceSourceIdentity({
      dids: did ? [did] : [],
      macAddresses: macs,
      model: rec?.model ?? device.model,
      name: device.name,
      roomName: device.roomName,
      kindTag: device.kind.kind,
    });
  }
  return out; } function readTuplePairs(raw: unknown): Array<[string, string]> { if (!Array.isArray(raw)) return [];
  const pairs: Array<[string, string]> = []; for (const item of raw) { if (Array.isArray(item) && item.length >= 2) {
      const k = typeof item[0] === "string" ? item[0] : ""; const v = typeof item[1] === "string" ? item[1] : "";
      if (k && v) pairs.push([k, v]);
    } else if (item && typeof item === "object") { const obj = item as Record<string, unknown>;
      const k = typeof obj["domain"] === "string" ? obj["domain"] : typeof obj["type"] === "string" ? obj["type"] : "";
      const v = typeof obj["id"] === "string" ? obj["id"] : typeof obj["value"] === "string" ? obj["value"] : "";
      if (k && v) pairs.push([k, v]); } } return pairs; } 
export function extractHADeviceIdentities(rawSnapshot: unknown, synthesized: SynthesizedHome,
): Record<string, DeviceSourceIdentity> { const devicesById = new Map<string, Record<string, unknown>>();
  const entitiesByDeviceId = new Map<string, Array<Record<string, unknown>>>();
  const entitiesByEntityId = new Map<string, Record<string, unknown>>(); 
  if (rawSnapshot && typeof rawSnapshot === "object" && !Array.isArray(rawSnapshot)) {
    const snap = rawSnapshot as Record<string, unknown>;
    if (Array.isArray(snap["devices"])) { for (const dev of snap["devices"]) {
        if (dev && typeof dev === "object" && !Array.isArray(dev)) { const rec = dev as Record<string, unknown>;
          if (typeof rec["id"] === "string" && rec["id"]) { devicesById.set(rec["id"], rec); } } } }
    if (Array.isArray(snap["entities"])) { for (const ent of snap["entities"]) {
        if (ent && typeof ent === "object" && !Array.isArray(ent)) { const rec = ent as Record<string, unknown>;
          const entityId = typeof rec["entity_id"] === "string" ? rec["entity_id"] : "";
          if (entityId) entitiesByEntityId.set(entityId, rec);
          if (rec["disabled_by"] != null || rec["hidden_by"] != null) continue;
          const devId = typeof rec["device_id"] === "string" ? rec["device_id"] : "";
          if (devId) { const list = entitiesByDeviceId.get(devId) ?? []; list.push(rec);
            entitiesByDeviceId.set(devId, list);
          }
        }
      }
    }
  }

  const out: Record<string, DeviceSourceIdentity> = {};
  for (const device of synthesized.devices) { const hashIdx = device.id.indexOf("#");
    const baseId = hashIdx >= 0 ? device.id.slice(0, hashIdx) : device.id;
    const splitEntityId = hashIdx >= 0 ? device.id.slice(hashIdx + 1) : null; const registry = devicesById.get(baseId);
    const entities = splitEntityId
      ? [entitiesByEntityId.get(splitEntityId)].filter((e): e is Record<string, unknown> => Boolean(e))
      : registry
        ? (entitiesByDeviceId.get(baseId) ?? [])
        : [entitiesByEntityId.get(device.id)].filter((e): e is Record<string, unknown> => Boolean(e));

    const rawDidValues: string[] = []; const rawMacValues: string[] = [];
    if (registry) { for (const [domainRaw, idValue] of readTuplePairs(registry["identifiers"])) {
        const domain = domainRaw.toLowerCase();
        if (domain.includes("xiaomi") || domain === "miio" || domain === "miot") { rawDidValues.push(idValue);
        } else if (domain === "mac") { rawMacValues.push(idValue);
        }
      }
      for (const [connType, connValue] of readTuplePairs(registry["connections"])) {
        if (connType.toLowerCase() === "mac") { rawMacValues.push(connValue); } } } const uniqueIds: string[] = [];
    for (const ent of entities) { const uid = typeof ent["unique_id"] === "string" ? ent["unique_id"].trim() : "";
      if (uid) { uniqueIds.push(uid); rawDidValues.push(uid); } }
    if (!registry && DeviceIdentityNormalizer.isDidLike(baseId)) { rawDidValues.push(baseId); } 
    out[device.id] = makeDeviceSourceIdentity({
      dids: DeviceIdentityNormalizer.didCandidates(rawDidValues),
      macAddresses: rawMacValues,
      uniqueIds,
      model: device.model,
      name: device.name,
      roomName: device.roomName,
      kindTag: device.kind.kind,
    });
  }
  return out; } 

export class CanonicalDeviceRegistry { public readonly assignments: Record<string, string>;

  constructor(initial: Readonly<Record<string, string>> = {}) { this.assignments = { ...initial };
  }

  canonicalId(forKeys: readonly string[]): string | null { for (const key of forKeys) {
      const id = this.assignments[key]; if (typeof id === "string" && id.length > 0) return id; } return null; } 
  assign(canonicalId: string, toKeys: readonly string[]): void { if (!canonicalId) return;
    for (const key of toKeys) { if (key) this.assignments[key] = canonicalId;
    }
  }

  clone(): CanonicalDeviceRegistry { return new CanonicalDeviceRegistry(this.assignments);
  }

  static load(storage: Storage | null = defaultStorage()): CanonicalDeviceRegistry {
    if (!storage) return new CanonicalDeviceRegistry();
    try { const raw = storage.getItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY);
      if (!raw) return new CanonicalDeviceRegistry(); const parsed: unknown = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) { return new CanonicalDeviceRegistry(); }
      const clean: Record<string, string> = {};
      for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
        if (k && typeof v === "string" && v) clean[k] = v; } return new CanonicalDeviceRegistry(clean);
    } catch { return new CanonicalDeviceRegistry();
    }
  }

  save(storage: Storage | null = defaultStorage()): void { if (!storage) return;
    try { if (Object.keys(this.assignments).length === 0) { storage.removeItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY);
      } else { storage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, JSON.stringify(this.assignments));
      }
    } catch {
    }
  }
}

export class RoomIdentityRegistry { public readonly idsByName: Record<string, string>;
  public readonly displayNames: Record<string, string>;

  constructor(idsByName: Readonly<Record<string, string>> = {}, displayNames: Readonly<Record<string, string>> = {},
  ) { this.idsByName = { ...idsByName };
    this.displayNames = { ...displayNames };
  }

  clone(): RoomIdentityRegistry { return new RoomIdentityRegistry(this.idsByName, this.displayNames);
  }

  static load(storage: Storage | null = defaultStorage()): RoomIdentityRegistry {
    if (!storage) return new RoomIdentityRegistry();
    try { const raw = storage.getItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY);
      if (!raw) return new RoomIdentityRegistry(); const parsed: unknown = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) { return new RoomIdentityRegistry(); }
      const obj = parsed as Record<string, unknown>; const toStringRecord = (val: unknown): Record<string, string> => {
        if (!val || typeof val !== "object" || Array.isArray(val)) return {}; const res: Record<string, string> = {};
        for (const [k, v] of Object.entries(val as Record<string, unknown>)) {
          if (k && typeof v === "string" && v) res[k] = v; } return res; };
      return new RoomIdentityRegistry(toStringRecord(obj["idsByName"]), toStringRecord(obj["displayNames"]));
    } catch { return new RoomIdentityRegistry();
    }
  }

  save(storage: Storage | null = defaultStorage()): void { if (!storage) return;
    try { if (Object.keys(this.idsByName).length === 0 &&
        Object.keys(this.displayNames).length === 0
      ) { storage.removeItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY);
      } else { storage.setItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY, JSON.stringify({
            idsByName: this.idsByName,
            displayNames: this.displayNames,
          }));
      }
    } catch {
    }
  }
}

export function homeBackendShortTitle(backend: HomeBackend, preference?: LanguagePreference,
): string { if (backend === "homeAssistant") return "Home Assistant";
  return tr3("米家云端", "米家雲端", "Xiaomi Cloud", undefined, preference); } 
export function offlineFallbackBadgeText(preference?: LanguagePreference): string {
  return tr3("离线，临时兜底", "離線，暫時兜底", "Offline, fallback", undefined, preference); } 
export function currentSourceMenuTitle(activeBackend: HomeBackend, pinnedBackend: HomeBackend | null | undefined,
  fallbackActive: boolean, preference?: LanguagePreference,
): string { const activeTitle = homeBackendShortTitle(activeBackend, preference);
  if (pinnedBackend && pinnedBackend !== activeBackend && fallbackActive) {
    const pinnedTitle = homeBackendShortTitle(pinnedBackend, preference); return tr3("当前来源：{active}（{pinned}离线，临时兜底）",
      "目前來源：{active}（{pinned}離線，暫時兜底）", "Current source: {active} ({pinned} offline, fallback)",
      { active: activeTitle, pinned: pinnedTitle }, preference);
  }
  return tr3("当前来源：{active}", "目前來源：{active}", "Current source: {active}", { active: activeTitle }, preference); } 
function isValidHomeBackend(raw: unknown): raw is HomeBackend { return raw === "homeAssistant" || raw === "xiaomiCloud";
}

export class DeviceSourcePinBox { private pins: Record<string, HomeBackend>;

  constructor(initial: Readonly<Record<string, HomeBackend>> = {}) { this.pins = { ...initial };
  }

  get(): Record<string, HomeBackend> { return { ...this.pins };
  }

  getPin(deviceId: string): HomeBackend | null { return this.pins[deviceId] ?? null;
  }

  set(next: Readonly<Record<string, HomeBackend>>): void { const clean: Record<string, HomeBackend> = {};
    for (const [id, backend] of Object.entries(next)) { if (id && isValidHomeBackend(backend)) clean[id] = backend;
    }
    this.pins = clean;
  }
}

export class DeviceSourcePinStorage { private readonly box: DeviceSourcePinBox;
  private readonly onRecompute?: () => void;

  constructor(private readonly storage: Storage | null = defaultStorage(),
    options: { readonly initial?: Readonly<Record<string, HomeBackend>>;
      readonly onRecompute?: () => void;
    } = {}) { const loaded = options.initial ?? DeviceSourcePinStorage.load(storage);
    this.box = new DeviceSourcePinBox(loaded);
    this.onRecompute = options.onRecompute;
  }

  static load(storage: Storage | null = defaultStorage()): Record<string, HomeBackend> { if (!storage) return {};
    try { const raw = storage.getItem(PINNED_DEVICE_SOURCES_STORAGE_KEY);
      if (!raw) return {}; const parsed: unknown = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
      const out: Record<string, HomeBackend> = {};
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        if (key && isValidHomeBackend(value)) { out[key] = value; } } return out; } catch { return {}; } } 
  static save(pins: Readonly<Record<string, HomeBackend>>, storage: Storage | null = defaultStorage(),
  ): void { if (!storage) return;
    const clean: Record<string, HomeBackend> = {};
    for (const [key, value] of Object.entries(pins)) { if (key && isValidHomeBackend(value)) { clean[key] = value;
      }
    }
    try { if (Object.keys(clean).length === 0) { storage.removeItem(PINNED_DEVICE_SOURCES_STORAGE_KEY);
      } else { storage.setItem(PINNED_DEVICE_SOURCES_STORAGE_KEY, JSON.stringify(clean));
      }
    } catch {
    }
  }

  getAll(): Record<string, HomeBackend> { return this.box.get();
  }

  get(deviceId: string): HomeBackend | null { return this.box.getPin(deviceId);
  }

    pin(deviceId: string, backend: HomeBackend | null): Record<string, HomeBackend> {
    if (!deviceId) return this.box.get(); const next = this.box.get(); if (backend === null) { delete next[deviceId];
    } else if (isValidHomeBackend(backend)) { next[deviceId] = backend;
    }
    this.box.set(next);
    DeviceSourcePinStorage.save(next, this.storage);
    this.onRecompute?.();
    return this.box.get(); } setAll(next: Readonly<Record<string, HomeBackend>>): void { this.box.set(next);
    DeviceSourcePinStorage.save(this.box.get(), this.storage);
    this.onRecompute?.();
  }
}

export interface DualSourceInputSnapshot { readonly home: SynthesizedHome;
  readonly identities?: Readonly<Record<string, DeviceSourceIdentity>>;
  readonly lightGroupOwners?: ReadonlyMap<string, string> | Readonly<Record<string, string>>;
  readonly homes?: readonly AccountScopedHomeOption[];
  readonly accountStatuses?: Readonly<Record<string, ConnectionStatus>>;
}

export interface DeviceMergeRoute { readonly backend: HomeBackend;
  readonly sourceDeviceId: string;
  readonly sourceDevice: AccountScopedSmartDevice;
  readonly alternateBackend: HomeBackend | null;
  readonly alternateDevice: AccountScopedSmartDevice | null;
  readonly pinnedBackend: HomeBackend | null;
    readonly fallbackActive: boolean;
    readonly fallbackLabel: string | null;
    readonly menuTitle: string;
}

export interface MergedSmartDevice extends AccountScopedSmartDevice { readonly sourceBackend?: HomeBackend;
  readonly pinnedBackend?: HomeBackend | null;
  readonly fallbackActive?: boolean;
  readonly fallbackLabel?: string | null;
}

export interface DeviceMergeResult {
  readonly home: Omit<SynthesizedHome, "devices"> & { readonly devices: MergedSmartDevice[] };
  readonly routes: Readonly<Record<string, DeviceMergeRoute>>;
  readonly deviceBackends: Readonly<Record<string, HomeBackend>>;
  readonly pairedDeviceIds: ReadonlySet<string>;
  readonly activeBackends: ReadonlySet<HomeBackend>;
  readonly canonical: CanonicalDeviceRegistry;
  readonly rooms: RoomIdentityRegistry;
  readonly haCanonicalIds: Readonly<Record<string, string>>;
  readonly miCanonicalIds: Readonly<Record<string, string>>;
  readonly lightGroupOwners: Map<string, string>;
  readonly homes: readonly AccountScopedHomeOption[];
  readonly accountStatuses: Readonly<Record<string, ConnectionStatus>>;
}

interface Candidate { readonly backend: HomeBackend;
  device: AccountScopedSmartDevice;
  readonly identity: DeviceSourceIdentity | null;
}

interface DraftCard { readonly winner: Candidate;
  readonly other: Candidate | null;
  readonly strongKeys: readonly string[];
  readonly fallbackKeys: readonly string[];
  readonly defaultPairedCanonical: string | null;
}

interface ResolvedCard { winner: Candidate;
  other: Candidate | null;
  readonly canonicalKeys: readonly string[];
  readonly chosenCanonical: string | null;
  readonly hadStaleCanonicalConflict: boolean;
}

class PairingState { readonly pairedHA = new Set<number>();
  readonly pairedMi = new Set<number>();
  readonly miIndexForHA = new Map<number, number>();

  pair(haIndex: number, miIndex: number): void { this.pairedHA.add(haIndex);
    this.pairedMi.add(miIndex);
    this.miIndexForHA.set(haIndex, miIndex);
  }
}

function sharesDID(a: DeviceSourceIdentity, b: DeviceSourceIdentity): boolean {
  if (a.dids.length === 0 || b.dids.length === 0) return false; const setB = new Set(b.dids);
  return a.dids.some((did) => setB.has(did)); } 
function sharesMAC(a: DeviceSourceIdentity, b: DeviceSourceIdentity): boolean {
  if (a.macAddresses.length === 0 || b.macAddresses.length === 0) return false; const setB = new Set(b.macAddresses);
  return a.macAddresses.some((mac) => setB.has(mac)); } 
function modelFallbackKey(identity: DeviceSourceIdentity): string | null {
  const token = DeviceIdentityNormalizer.normalizedToken(identity.model); if (!token) return null;
  const room = DeviceIdentityNormalizer.normalizedRoomName(identity.roomName);
  return `fallback-model:${room}|${token}|${identity.kindTag}`; } 
function nameFallbackKey(identity: DeviceSourceIdentity): string | null {
  const token = DeviceIdentityNormalizer.normalizedToken(identity.name); if (!token) return null;
  const room = DeviceIdentityNormalizer.normalizedRoomName(identity.roomName);
  return `fallback-name:${room}|${token}|${identity.kindTag}`; } 
function fallbackKeyCounts(candidates: readonly Candidate[]): Record<string, number> {
  const counts: Record<string, number> = {}; for (const c of candidates) { if (!c.identity) continue;
    const mk = modelFallbackKey(c.identity); if (mk) counts[mk] = (counts[mk] ?? 0) + 1;
    const nk = nameFallbackKey(c.identity); if (nk) counts[nk] = (counts[nk] ?? 0) + 1; } return counts; } 
function uniqueFallbackKeys(identity: DeviceSourceIdentity | null, haCounts: Readonly<Record<string, number>>,
  miCounts: Readonly<Record<string, number>>): string[] { if (!identity) return [];
  const keys: string[] = []; const mk = modelFallbackKey(identity);
  if (mk && (haCounts[mk] ?? 0) <= 1 && (miCounts[mk] ?? 0) <= 1) { keys.push(mk); }
  const nk = nameFallbackKey(identity); if (nk && (haCounts[nk] ?? 0) <= 1 && (miCounts[nk] ?? 0) <= 1) { keys.push(nk);
  }
  return keys; } 
function deduplicatedPreservingOrder(keys: readonly string[]): string[] { const seen = new Set<string>();
  const out: string[] = []; for (const k of keys) { if (!seen.has(k)) { seen.add(k); out.push(k); } } return out; } 
function hasDistinctAccountScope(lhs: string, rhs: string): boolean { const lhsSlash = lhs.indexOf("/");
  const rhsSlash = rhs.indexOf("/"); if (lhsSlash < 0 || rhsSlash < 0) return false;
  return lhs.slice(0, lhsSlash) !== rhs.slice(0, rhsSlash); } 
function normalizeOwnersRecord(owners?: ReadonlyMap<string, string> | Readonly<Record<string, string>>,
): Record<string, string> { if (!owners) return {};
  if (owners instanceof Map) { const out: Record<string, string> = {}; for (const [k, v] of owners) out[k] = v;
    return out; } return { ...(owners as Readonly<Record<string, string>>) }; } 
function clampLightGroupDevice<T extends AccountScopedSmartDevice>(device: T,
  memberStates: ReadonlyArray<{ readonly isOnline: boolean; readonly isOn: boolean }>, forceOfflineAndOff = false,
): T { if (device.kind.kind !== "light") return device;
  if (forceOfflineAndOff) { return {
      ...device,
      isOnline: false,
      kind: { ...device.kind, isOn: false },
    };
  }
  if (memberStates.length === 0) return device; const anyOnline = memberStates.some((m) => m.isOnline);
  const anyOnlineAndOn = memberStates.some((m) => m.isOnline && m.isOn); return {
    ...device,
    isOnline: anyOnline,
    kind: { ...device.kind, isOn: anyOnlineAndOn },
  };
}

function reconcilePairedHALightGroups(haCandidates: Candidate[], miCandidates: readonly Candidate[],
  pairing: PairingState, miLightGroupOwners: Readonly<Record<string, string>>,
): void { const ownerEntries = Object.entries(miLightGroupOwners);
  if (ownerEntries.length === 0 || pairing.miIndexForHA.size === 0) return; 
  const memberMiIdsByGroup = new Map<string, string[]>();
  for (const [memberId, groupId] of ownerEntries) { const list = memberMiIdsByGroup.get(groupId) ?? [];
    list.push(memberId);
    memberMiIdsByGroup.set(groupId, list);
  }
  const miIndexById = new Map<string, number>();
  miCandidates.forEach((c, idx) => { if (!miIndexById.has(c.device.id)) miIndexById.set(c.device.id, idx);
  });
  const haIndexForMi = new Map<number, number>();
  for (const [haIdx, miIdx] of pairing.miIndexForHA) { if (!haIndexForMi.has(miIdx)) haIndexForMi.set(miIdx, haIdx);
  }

  for (const [haIdx, miIdx] of pairing.miIndexForHA) { const groupMi = miCandidates[miIdx]?.device;
    const haCandidate = haCandidates[haIdx]; if (!groupMi || !haCandidate || !groupMi.id.startsWith("group.")) continue;
    const memberMiIds = memberMiIdsByGroup.get(groupMi.id); if (!memberMiIds || memberMiIds.length === 0) continue; 
    const haLightMembers: Array<{ isOnline: boolean; isOn: boolean }> = [];
    const miLightMembers: Array<{ isOnline: boolean; isOn: boolean }> = [];
    for (const memberMiId of memberMiIds) { const miMemberIdx = miIndexById.get(memberMiId);
      if (miMemberIdx === undefined) continue; const miMember = miCandidates[miMemberIdx]!.device;
      if (miMember.kind.kind === "light") {
        miLightMembers.push({ isOnline: miMember.isOnline, isOn: miMember.kind.isOn });
      }
      const haMemberIdx = haIndexForMi.get(miMemberIdx);
      if (haMemberIdx !== undefined) { const haMember = haCandidates[haMemberIdx]!.device;
        if (haMember.kind.kind === "light") {
          haLightMembers.push({ isOnline: haMember.isOnline, isOn: haMember.kind.isOn });
        }
      }
    }

    if (haLightMembers.length > 0) { haCandidate.device = clampLightGroupDevice(haCandidate.device, haLightMembers); }
    if (!groupMi.isOnline && miLightMembers.length > 0 && miLightMembers.every((m) => !m.isOnline)) {
      haCandidate.device = clampLightGroupDevice(haCandidate.device, [], true);
    } else if (haLightMembers.length === 0 &&
      groupMi.kind.kind === "light" &&
      !groupMi.kind.isOn &&
      miLightMembers.length > 0 &&
      miLightMembers.filter((m) => m.isOnline).every((m) => !m.isOn)
    ) { haCandidate.device = clampLightGroupDevice(haCandidate.device, miLightMembers);
    }
  }
}

export const DeviceDeduplicator = {
    capabilityScore(device: SmartDevice): number { const spec = device.kind;
    switch (spec.kind) { case "light": { let score = 0;
        if (spec.powerWritable !== false) score += 1;
        if (spec.brightnessWritable !== false && spec.brightnessPercent !== null) score += 1;
        if (spec.colorWritable !== false && spec.colorTempKelvin !== null) score += 1;
        if (spec.availableEffects.length > 0) score += 2; return score; } case "climate": { let score = 0;
        if (spec.powerWritable !== false) score += 1; if (spec.temperatureWritable !== false) score += 1;
        if (spec.availableModes.length > 0) score += 1; if (spec.availableFanModes.length > 0) score += 1;
        if ((spec.availableSwingModes?.length ?? 0) > 0) score += 1; if (spec.currentTemperature !== null) score += 1;
        return score; } case "fan": { let score = 0; if (spec.powerWritable !== false) score += 1;
        if (spec.speedWritable !== false && spec.percentage !== null) score += 1;
        if (spec.availablePresetModes.length > 0) score += 1; if (spec.isOscillating !== null) score += 1;
        if (spec.pm25Density != null) score += 1; if (spec.airQuality != null) score += 1;
        if (spec.temperature != null) score += 1; if (spec.humidity != null) score += 1;
        if (spec.filterLifePercent != null) score += 1; return score; } case "plug": { let score = 0;
        if (spec.powerWritable !== false) score += 1; if (spec.powerWatts !== null) score += 1;
        if (spec.energyKwh != null) score += 1; if (spec.childLockEntityId !== null) score += 1; return score; }
      case "vacuum": { let score = 0;
        if (spec.actionsWritable !== false) score += 2; if (spec.modeEntityId !== null) score += 1;
        if (spec.availableModes.length > 0) score += 1; if (spec.battery !== null) score += 1; return score; }
      case "speaker": { let score = 0;
        if (spec.mediaEntityId !== "") score += 1; if (spec.ttsActionId) score += 2;
        if (spec.directiveActionId) score += 2; if (spec.muteSwitchEntityId !== null) score += 1;
        if (spec.sleepModeEntityId !== null) score += 1; return score; } case "camera": { let score = 0;
        if (spec.powerWritable !== false) score += 1; if (spec.availableNightShots.length > 0) score += 1;
        if (spec.motionDetectionEntityId !== null) score += 1; if (spec.streamEntityId !== null) score += 1;
        if (spec.snapshotPath != null && spec.snapshotPath !== "") score += 1; return score; }
      case "fridge": { let score = 0;
        if (spec.modeEntityId !== null) score += 1; if (spec.fridgeTargetEntityId !== null) score += 1;
        if (spec.freezerTargetEntityId !== null) score += 1;
        if (spec.fridgeCurrentTemp !== null || spec.freezerCurrentTemp !== null) score += 1; return score; }
      case "sensor":
        return 0; case "appliance": { let score = 0; if (spec.powerWritable) score += 1;
        if (spec.temperatureWritable) score += 1; if (spec.availableModes.length > 0) score += 1;
        if (spec.currentTemperature !== null) score += 1; if (spec.statusText !== null) score += 1;
        if (spec.startAction !== null || spec.pauseAction !== null || spec.stopAction !== null) { score += 1; }
        if (spec.fanLevel !== null) score += 1; if (spec.light !== null) score += 1; return score; }
      case "generic": { let score = spec.isReadOnly ? 0 : 1;
        score += spec.readouts.length;
        if (spec.powerControl !== null) score += 2; return score; } case "cover": { let score = 0;
        if (spec.openDescription !== null && spec.closeDescription !== null) score += 2;
        if (spec.positionWritable) score += 1; if (spec.batteryPercent !== null) score += 1; return score; } } }, 
  hasLiveView(device: SmartDevice, backend: HomeBackend): boolean { if (device.kind.kind !== "camera") return false;
    if (backend === "xiaomiCloud") return true;
    return (Boolean(device.kind.streamEntityId && device.kind.streamEntityId.trim() !== "") ||
      Boolean(device.kind.snapshotPath && device.kind.snapshotPath.trim() !== "")
    );
  }, 
  merge(options: { readonly homeAssistant?: DualSourceInputSnapshot | null;
    readonly xiaomiCloud?: DualSourceInputSnapshot | null;
    readonly canonical?: CanonicalDeviceRegistry;
    readonly rooms?: RoomIdentityRegistry;
    readonly knownPreferenceIds?: ReadonlySet<string>;
    readonly pinnedBackends?: Readonly<Record<string, HomeBackend>>;
    readonly languagePreference?: LanguagePreference;
  }): DeviceMergeResult { const haInput = options.homeAssistant ?? null;
    const miInput = options.xiaomiCloud ?? null; const knownPrefIds = options.knownPreferenceIds ?? new Set<string>();
    const pinnedBackends = options.pinnedBackends ?? {}; const toCandidates = (input: DualSourceInputSnapshot | null,
      backend: HomeBackend): Candidate[] => { if (!input) return [];
      const statuses = backend === "xiaomiCloud" && input.accountStatuses ? Object.values(input.accountStatuses) : [];
      const allAccountsDisconnected = statuses.length > 0 && statuses.every((s) => s.kind === "disconnected");
      const fallbackIdentities = input.identities ??
        (backend === "homeAssistant"
          ? extractHADeviceIdentities(null, input.home)
          : extractMiDeviceIdentities([], input.home));
      return input.home.devices.map((dev) => {
        const accountStatus = backend === "xiaomiCloud" && dev.accountId && input.accountStatuses
          ? input.accountStatuses[dev.accountId]
          : undefined;
        const accountDisconnected = allAccountsDisconnected || accountStatus?.kind === "disconnected" || dev.telemetryStale === true;
        const effectiveDev = accountDisconnected ? { ...dev, isOnline: false, telemetryStale: true } : dev;
        return {
          backend,
          device: effectiveDev,
          identity: fallbackIdentities[dev.id] ??
            makeDeviceSourceIdentity({
              dids: backend === "xiaomiCloud" ? [stripTrackSuffix(dev.id)] : DeviceIdentityNormalizer.didCandidates([dev.id]),
              model: dev.model,
              name: dev.name,
              roomName: dev.roomName,
              kindTag: dev.kind.kind,
            }),
        };
      });
    };

    const haCandidates = toCandidates(haInput, "homeAssistant");
    const miCandidates = toCandidates(miInput, "xiaomiCloud"); const haFallbackCounts = fallbackKeyCounts(haCandidates);
    const miFallbackCounts = fallbackKeyCounts(miCandidates); const pairing = new PairingState(); 
    const pairByHardwarePass = (predicate: (a: DeviceSourceIdentity, b: DeviceSourceIdentity) => boolean,
    ) => { for (let haIdx = 0; haIdx < haCandidates.length; haIdx += 1) { if (pairing.pairedHA.has(haIdx)) continue;
        const haIdentity = haCandidates[haIdx]!.identity; if (!haIdentity) continue; const matches: number[] = [];
        for (let miIdx = 0; miIdx < miCandidates.length; miIdx += 1) { if (pairing.pairedMi.has(miIdx)) continue;
          const miIdentity = miCandidates[miIdx]!.identity;
          if (miIdentity && predicate(haIdentity, miIdentity)) { matches.push(miIdx); } }
        if (matches.length === 1) { pairing.pair(haIdx, matches[0]!); } } }; pairByHardwarePass(sharesDID);
    pairByHardwarePass(sharesMAC);

    const pairByFallbackGroups = (keyFn: (identity: DeviceSourceIdentity) => string | null,
    ) => { const groups = new Map<string, { ha: number[]; mi: number[] }>();
      for (let haIdx = 0; haIdx < haCandidates.length; haIdx += 1) { if (pairing.pairedHA.has(haIdx)) continue;
        const identity = haCandidates[haIdx]!.identity; const key = identity ? keyFn(identity) : null;
        if (!key) continue; const g = groups.get(key) ?? { ha: [], mi: [] }; g.ha.push(haIdx); groups.set(key, g); }
      for (let miIdx = 0; miIdx < miCandidates.length; miIdx += 1) { if (pairing.pairedMi.has(miIdx)) continue;
        const identity = miCandidates[miIdx]!.identity; const key = identity ? keyFn(identity) : null;
        if (!key) continue; const g = groups.get(key) ?? { ha: [], mi: [] }; g.mi.push(miIdx); groups.set(key, g); }
      for (const groupKey of [...groups.keys()].sort()) { const g = groups.get(groupKey)!;
        if (g.ha.length !== 1 || g.mi.length !== 1) continue; const haIdx = g.ha[0]!; const miIdx = g.mi[0]!;
        if (!pairing.pairedHA.has(haIdx) && !pairing.pairedMi.has(miIdx)) { pairing.pair(haIdx, miIdx); } } }; 
    pairByFallbackGroups(modelFallbackKey);
    pairByFallbackGroups(nameFallbackKey);

    const miGroupOwnersRecord = normalizeOwnersRecord(miInput?.lightGroupOwners);
    reconcilePairedHALightGroups(haCandidates, miCandidates, pairing, miGroupOwnersRecord);

    const preferredCandidate = (ha: Candidate, mi: Candidate): Candidate => { const haDev = ha.device;
      const miDev = mi.device; if (haDev.isOnline !== miDev.isOnline) { return haDev.isOnline ? ha : mi; }
      if (miDev.kind.kind === "appliance" && haDev.kind.kind === "climate") return mi;
      if (haDev.kind.kind === "appliance" && miDev.kind.kind === "climate") return ha;
      const haLive = this.hasLiveView(haDev, "homeAssistant"); const miLive = this.hasLiveView(miDev, "xiaomiCloud");
      if (haLive !== miLive) { return haLive ? ha : mi; } const haScore = this.capabilityScore(haDev);
      const miScore = this.capabilityScore(miDev); if (haScore !== miScore) { return haScore > miScore ? ha : mi; }
      return ha; }; 
    const isAlreadyShownByMiTracks = (haIdentity: DeviceSourceIdentity): boolean => { for (const mi of miCandidates) {
        if (mi.identity && sharesDID(haIdentity, mi.identity)) return true; }
      const curtainTracks = miCandidates.filter((mi) => mi.identity !== null &&
          sharesMAC(haIdentity, mi.identity) &&
          mi.device.kind.kind === "cover" &&
          mi.device.kind.subtype === "curtain");
      if (curtainTracks.length < 2) return false; let sharedDids = new Set(curtainTracks[0]!.identity?.dids ?? []);
      for (let i = 1; i < curtainTracks.length; i += 1) {
        const nextDids = new Set(curtainTracks[i]!.identity?.dids ?? []);
        sharedDids = new Set([...sharedDids].filter((d) => nextDids.has(d)));
      }
      return sharedDids.size > 0; }; const pairStrongKeys = (ha: Candidate, mi: Candidate): string[] => { const keys = [
        `pair:${ha.device.id}|${mi.device.id}`,
        `ha:${ha.device.id}`,
        `mi:${mi.device.id}`,
      ];
      if (ha.identity && mi.identity) { const miDids = new Set(mi.identity.dids);
        for (const did of ha.identity.dids.filter((d) => miDids.has(d)).sort()) { keys.push(`did:${did}`);
        }
        const miMacs = new Set(mi.identity.macAddresses);
        for (const mac of ha.identity.macAddresses.filter((m) => miMacs.has(m)).sort()) { keys.push(`mac:${mac}`);
        }
      }
      return keys; }; const singleStrongKeys = (c: Candidate): string[] => { const keys = [
        c.backend === "homeAssistant" ? `ha:${c.device.id}` : `mi:${c.device.id}`,
      ];
      if (c.identity) { for (const did of c.identity.dids) keys.push(`did:${did}`);
        for (const mac of c.identity.macAddresses) keys.push(`mac:${mac}`);
      }
      return keys; }; const draftCards: DraftCard[] = [];
    for (let haIdx = 0; haIdx < haCandidates.length; haIdx += 1) { const ha = haCandidates[haIdx]!;
      const miIdx = pairing.miIndexForHA.get(haIdx); if (miIdx !== undefined) { const mi = miCandidates[miIdx]!;
        const winner = preferredCandidate(ha, mi); const other = winner.backend === "homeAssistant" ? mi : ha;
        const fallbackKeys = deduplicatedPreservingOrder([
          ...uniqueFallbackKeys(ha.identity, haFallbackCounts, miFallbackCounts),
          ...uniqueFallbackKeys(mi.identity, haFallbackCounts, miFallbackCounts),
        ]);
        const defaultPairedCanonical = knownPrefIds.has(mi.device.id) && !knownPrefIds.has(ha.device.id)
            ? mi.device.id
            : ha.device.id;
        draftCards.push({
          winner,
          other,
          strongKeys: pairStrongKeys(ha, mi),
          fallbackKeys,
          defaultPairedCanonical,
        });
      } else { if (ha.identity && isAlreadyShownByMiTracks(ha.identity)) { continue;
        }
        draftCards.push({
          winner: ha,
          other: null,
          strongKeys: singleStrongKeys(ha),
          fallbackKeys: uniqueFallbackKeys(ha.identity, haFallbackCounts, miFallbackCounts),
          defaultPairedCanonical: null,
        });
      }
    }
    for (let miIdx = 0; miIdx < miCandidates.length; miIdx += 1) { if (pairing.pairedMi.has(miIdx)) continue;
      const mi = miCandidates[miIdx]!; draftCards.push({
        winner: mi,
        other: null,
        strongKeys: singleStrongKeys(mi),
        fallbackKeys: uniqueFallbackKeys(mi.identity, haFallbackCounts, miFallbackCounts),
        defaultPairedCanonical: null,
      });
    }

    const updatedCanonical = (options.canonical ?? new CanonicalDeviceRegistry()).clone();
    const updatedRooms = (options.rooms ?? new RoomIdentityRegistry()).clone(); 
    const cardFallbackCounts: Record<string, number> = {}; const strongClaimedCanonicals = new Set<string>();
    for (const draft of draftCards) { for (const k of draft.fallbackKeys) {
        cardFallbackCounts[k] = (cardFallbackCounts[k] ?? 0) + 1;
      }
      const strongMatch = updatedCanonical.canonicalId(draft.strongKeys);
      if (strongMatch) strongClaimedCanonicals.add(strongMatch); } 
    const memberCardIndicesById = new Map<string, Set<number>>();
    draftCards.forEach((draft, idx) => { const addIdx = (id: string) => {
        const s = memberCardIndicesById.get(id) ?? new Set<number>(); s.add(idx); memberCardIndicesById.set(id, s); };
      addIdx(draft.winner.device.id);
      if (draft.other) addIdx(draft.other.device.id); }); 
    const resolvedCards: ResolvedCard[] = draftCards.map((draft, idx) => {
      const validFallbackKeys = draft.fallbackKeys.filter((k) => cardFallbackCounts[k] === 1);
      const isFreeOfForeignMember = (candidateId: string): boolean => {
        const indices = memberCardIndicesById.get(candidateId); if (!indices) return true;
        for (const otherIdx of indices) { if (otherIdx !== idx) return false;
        }
        return true; }; const rawStrong = updatedCanonical.canonicalId(draft.strongKeys);
      const strongMatch = rawStrong && isFreeOfForeignMember(rawStrong) ? rawStrong : null;
      const rawFallback = rawStrong === null ? updatedCanonical.canonicalId(validFallbackKeys) : null;
      const fallbackMatch = rawFallback &&
        !strongClaimedCanonicals.has(rawFallback) &&
        isFreeOfForeignMember(rawFallback)
          ? rawFallback
          : null;
      const hadStaleCanonicalConflict = (rawStrong !== null && strongMatch === null) ||
        (rawFallback !== null && fallbackMatch === null);
      const defaultPaired = draft.defaultPairedCanonical && isFreeOfForeignMember(draft.defaultPairedCanonical)
          ? draft.defaultPairedCanonical
          : null;
      return {
        winner: draft.winner,
        other: draft.other,
        canonicalKeys: [...draft.strongKeys, ...validFallbackKeys],
        chosenCanonical: strongMatch ?? fallbackMatch ?? defaultPaired,
        hadStaleCanonicalConflict,
      };
    });

    const pairedClaims: Record<string, number> = {}; const unpairedClaims: Record<string, number> = {};
    for (const card of resolvedCards) { if (!card.chosenCanonical) continue;
      if (card.other !== null) { pairedClaims[card.chosenCanonical] = (pairedClaims[card.chosenCanonical] ?? 0) + 1;
      } else { unpairedClaims[card.chosenCanonical] = (unpairedClaims[card.chosenCanonical] ?? 0) + 1;
      }
    }

    const collectRoomIdentities = (home?: SynthesizedHome) => { if (!home) return;
      const recordRoom = (name: string, id: string) => { const key = DeviceIdentityNormalizer.normalizedRoomName(name);
        if (!key) return; if (!updatedRooms.idsByName[key]) updatedRooms.idsByName[key] = id;
        if (!updatedRooms.displayNames[key]) { updatedRooms.displayNames[key] = normalizeDisplayRoomName(name); } };
      for (const room of home.rooms) recordRoom(room.name, room.id);
      for (const dev of home.devices) recordRoom(dev.roomName, dev.roomId);
    };
    collectRoomIdentities(haInput?.home);
    collectRoomIdentities(miInput?.home);

    const mergedDevices: MergedSmartDevice[] = []; const routes: Record<string, DeviceMergeRoute> = {};
    const deviceBackends: Record<string, HomeBackend> = {}; const pairedDeviceIds = new Set<string>();
    const miCanonicalIds: Record<string, string> = {}; const haCanonicalIds: Record<string, string> = {};
    const usedCanonicalIds = new Set<string>(); 
    for (const card of resolvedCards) { const canUseCanonical = card.chosenCanonical
        ? card.other !== null
          ? pairedClaims[card.chosenCanonical] === 1 &&
            !usedCanonicalIds.has(card.chosenCanonical)
          : unpairedClaims[card.chosenCanonical] === 1 &&
            pairedClaims[card.chosenCanonical] === undefined &&
            !usedCanonicalIds.has(card.chosenCanonical)
        : false;

      let canonicalId: string;
      if (card.chosenCanonical && canUseCanonical) { updatedCanonical.assign(card.chosenCanonical, card.canonicalKeys);
        canonicalId = card.chosenCanonical;
      } else if (!usedCanonicalIds.has(card.winner.device.id)) { if ((card.other !== null ||
            card.chosenCanonical !== null ||
            card.hadStaleCanonicalConflict) &&
          card.canonicalKeys.length > 0
        ) { updatedCanonical.assign(card.winner.device.id, card.canonicalKeys);
        }
        canonicalId = card.winner.device.id;
      } else if (card.other && !usedCanonicalIds.has(card.other.device.id)) { canonicalId = card.other.device.id;
      } else { canonicalId = `${card.winner.backend}:${card.winner.device.id}`;
      }
      usedCanonicalIds.add(canonicalId);

      const wasPaired = card.other !== null; const pinned = pinnedBackends[canonicalId] ?? null;
      if (pinned && card.other) { const pairList = [card.winner, card.other];
        const pinnedCandidate = pairList.find((c) => c.backend === pinned &&
            (c.device.isOnline || !card.winner.device.isOnline));
        if (pinnedCandidate && pinnedCandidate.backend !== card.winner.backend) { card.other = card.winner;
          card.winner = pinnedCandidate;
        }
      }

      if (wasPaired) pairedDeviceIds.add(canonicalId); for (const c of [card.winner, card.other]) { if (!c) continue;
        if (c.backend === "xiaomiCloud") miCanonicalIds[c.device.id] = canonicalId;
        if (c.backend === "homeAssistant") haCanonicalIds[c.device.id] = canonicalId; } 
      const winnerDev = card.winner.device; const otherDev = card.other?.device ?? null; let roomId = winnerDev.roomId;
      let roomName = winnerDev.roomName; if (otherDev &&
        isRoomUnassigned(roomName) &&
        !isRoomUnassigned(otherDev.roomName)
      ) { roomId = otherDev.roomId;
        roomName = otherDev.roomName;
      }
      const name = winnerDev.name.trim() === "" && otherDev ? otherDev.name : winnerDev.name;
      const model = winnerDev.model.trim() === "" && otherDev ? otherDev.model : winnerDev.model;
      const accountId = winnerDev.accountId ?? otherDev?.accountId;
      const accountLabel = winnerDev.accountLabel ?? otherDev?.accountLabel; 
      const roomKey = DeviceIdentityNormalizer.normalizedRoomName(roomName);
      if (roomKey) { if (!updatedRooms.idsByName[roomKey]) updatedRooms.idsByName[roomKey] = roomId;
        if (!updatedRooms.displayNames[roomKey]) {
          updatedRooms.displayNames[roomKey] = normalizeDisplayRoomName(roomName);
        }
        const regRoomId = updatedRooms.idsByName[roomKey];
        if (regRoomId && !hasDistinctAccountScope(regRoomId, roomId)) { roomId = regRoomId; }
        const regDisplay = updatedRooms.displayNames[roomKey]; if (regDisplay) roomName = regDisplay; } 
      const pinnedSourceOffline = otherDev !== null
          ? !otherDev.isOnline
          : (pinned === "homeAssistant" && !haInput) || (pinned === "xiaomiCloud" && !miInput);
      const fallbackActive = Boolean(
        pinned && pinned !== card.winner.backend && winnerDev.isOnline && pinnedSourceOffline);
      const fallbackLabel = fallbackActive
        ? offlineFallbackBadgeText(options.languagePreference)
        : null;

      const mergedCard: MergedSmartDevice = {
        id: canonicalId,
        name,
        roomId,
        roomName,
        model,
        isOnline: winnerDev.isOnline,
        kind: winnerDev.kind,
        sourceBackend: card.winner.backend,
        pinnedBackend: pinned,
        fallbackActive,
        ...(fallbackLabel !== null ? { fallbackLabel } : {}),
        ...(winnerDev.isSharedHome !== undefined
          ? { isSharedHome: winnerDev.isSharedHome }
          : {}),
        ...(accountId !== undefined ? { accountId } : {}),
        ...(accountLabel !== undefined ? { accountLabel } : {}),
        ...(winnerDev.telemetryStale ? { telemetryStale: true } : {}),
      };
      mergedDevices.push(mergedCard);

      routes[canonicalId] = {
        backend: card.winner.backend,
        sourceDeviceId: winnerDev.id,
        sourceDevice: winnerDev,
        alternateBackend: card.other?.backend ?? null,
        alternateDevice: otherDev,
        pinnedBackend: pinned,
        fallbackActive,
        fallbackLabel,
        menuTitle: currentSourceMenuTitle(card.winner.backend, pinned, fallbackActive, options.languagePreference),
      };
      deviceBackends[canonicalId] = card.winner.backend;
    }

    const mergedIdsSet = new Set(mergedDevices.map((d) => d.id));
    const translatedGroupOwners = new Map<string, string>();
    for (const [memberRaw, groupRaw] of Object.entries(miGroupOwnersRecord)) {
      const memberCanonical = miCanonicalIds[memberRaw]; const groupCanonical = miCanonicalIds[groupRaw];
      if (memberCanonical &&
        groupCanonical &&
        mergedIdsSet.has(memberCanonical) &&
        mergedIdsSet.has(groupCanonical)
      ) { translatedGroupOwners.set(memberCanonical, groupCanonical);
      }
    }

    if (translatedGroupOwners.size > 0) { const membersByGroup = new Map<string, AccountScopedSmartDevice[]>();
      const byId = new Map(mergedDevices.map((d) => [d.id, d]));
      for (const [memberId, groupId] of translatedGroupOwners) { const m = byId.get(memberId);
        if (!m) continue; const arr = membersByGroup.get(groupId) ?? []; arr.push(m); membersByGroup.set(groupId, arr);
      }
      for (let i = 0; i < mergedDevices.length; i += 1) { const dev = mergedDevices[i]!;
        const members = membersByGroup.get(dev.id); if (!members || dev.kind.kind !== "light") continue;
        const states = members
          .filter((m) => m.kind.kind === "light")
          .map((m) => ({
            isOnline: m.isOnline,
            isOn: m.kind.kind === "light" ? m.kind.isOn : false,
          }));
        if (states.length > 0) { mergedDevices[i] = clampLightGroupDevice(dev, states); } } } 
    const roomOrder = new Map<string, number>();
    const registerOrder = (rawName: string) => { const disp = normalizeDisplayRoomName(rawName);
      if (!roomOrder.has(disp)) roomOrder.set(disp, roomOrder.size); };
    for (const r of haInput?.home.rooms ?? []) registerOrder(r.name);
    for (const r of miInput?.home.rooms ?? []) registerOrder(r.name);
    for (const d of mergedDevices) registerOrder(d.roomName);

    const roomsById = new Map<string, { name: string; count: number }>();
    for (const dev of mergedDevices) { const cur = roomsById.get(dev.roomId);
      if (cur) { cur.count += 1; } else { roomsById.set(dev.roomId, { name: dev.roomName, count: 1 }); } }
    const mergedRooms: RoomCategory[] = [...roomsById.entries()]
      .map(([id, info]) => ({ id, name: info.name, deviceCount: info.count }))
      .sort((a, b) => (roomOrder.get(a.name) ?? 9999) - (roomOrder.get(b.name) ?? 9999));

    const haFacetsByCanonical: Record<string, readonly FacetControl[]> = {};
    for (const [srcId, controls] of Object.entries(haInput?.home.deviceFacets ?? {})) {
      const cid = haCanonicalIds[srcId] ?? srcId; if (mergedIdsSet.has(cid)) haFacetsByCanonical[cid] = controls; }
    const miFacetsByCanonical: Record<string, readonly FacetControl[]> = {};
    for (const [srcId, controls] of Object.entries(miInput?.home.deviceFacets ?? {})) {
      const cid = miCanonicalIds[srcId] ?? srcId; if (mergedIdsSet.has(cid)) miFacetsByCanonical[cid] = controls; }
    const mergedFacets: Record<string, readonly FacetControl[]> = {};
    for (const cid of mergedIdsSet) { const preferred = routes[cid]?.backend === "homeAssistant"
          ? (haFacetsByCanonical[cid] ?? miFacetsByCanonical[cid])
          : (miFacetsByCanonical[cid] ?? haFacetsByCanonical[cid]);
      if (preferred && preferred.length > 0) { mergedFacets[cid] = preferred; } } 
    const mergedReadings: EnvironmentReading[] = [...mergedDevices]
      .sort((a, b) => environmentReadingPriority(a.kind) - environmentReadingPriority(b.kind))
      .flatMap((dev) => { const r = deviceEnvironmentReading(dev);
        return r ? [r] : []; }); const scenes: HomeScene[] = [...(haInput?.home.scenes ?? [])];
    const activeBackends = new Set<HomeBackend>(); if (haInput) activeBackends.add("homeAssistant");
    if (miInput) activeBackends.add("xiaomiCloud"); return {
      home: {
        devices: mergedDevices,
        rooms: mergedRooms,
        environmentReadings: mergedReadings,
        scenes,
        ...(Object.keys(mergedFacets).length > 0 ? { deviceFacets: mergedFacets } : {}),
      },
      routes,
      deviceBackends,
      pairedDeviceIds,
      activeBackends,
      canonical: updatedCanonical,
      rooms: updatedRooms,
      haCanonicalIds,
      miCanonicalIds,
      lightGroupOwners: translatedGroupOwners,
      homes: miInput?.homes ?? [],
      accountStatuses: miInput?.accountStatuses ?? {},
    };
  },
} as const;

export function commandTargetBackend(command: DeviceCommand): HomeBackend { const entityId = command.entityId;
  if (command.kind === "setMiotProperty" ||
    parseMiotAddress(entityId) !== null ||
    parseMiotActionAddress(entityId) !== null
  ) { return "xiaomiCloud";
  }
  return "homeAssistant"; } export async function fetchHASnapshotWithIdentities(baseURL: string, token: string,
  invoke: HAInvoke = async (command, args) => {
    if (typeof window === "undefined" || !window.__TAURI_INTERNALS__?.invoke) {
      throw new Error("Home Assistant requires the Windows app");
    }
    return window.__TAURI_INTERNALS__.invoke(command, args); }): Promise<{ readonly rawSnapshot: unknown;
  readonly home: SynthesizedHome;
  readonly identities: Record<string, DeviceSourceIdentity>;
}> { const rawSnapshot = await invoke<unknown>("ha_snapshot", {
    baseUrl: baseURL,
    token,
  });
  const home = HomeAssistantSynthesizer.synthesize(rawSnapshot);
  const identities = extractHADeviceIdentities(rawSnapshot, home); return { rawSnapshot, home, identities }; } 
export interface DualSourceRefreshOutcome { readonly merged: DeviceMergeResult;
  readonly sourceStatuses: Readonly<Record<HomeBackend, ConnectionStatus>>;
  readonly haError: string | null;
  readonly miError: string | null;
}

export class DualSourceCoordinator { public canonical: CanonicalDeviceRegistry;
  public rooms: RoomIdentityRegistry;
  public readonly pinStorage: DeviceSourcePinStorage;
  private lastHA: DualSourceInputSnapshot | null = null;
  private lastMi: DualSourceInputSnapshot | null = null;
  private lastKnownPrefIds: ReadonlySet<string> = new Set();
  private lastMerged: DeviceMergeResult | null = null;
  private sourceStatuses: Record<HomeBackend, ConnectionStatus> = {
    homeAssistant: { kind: "connecting" },
    xiaomiCloud: { kind: "connecting" },
  };

  constructor(private readonly storage: Storage | null = defaultStorage(),
    options: { readonly onRecompute?: (merged: DeviceMergeResult) => void;
    } = {}) { this.canonical = CanonicalDeviceRegistry.load(storage);
    this.rooms = RoomIdentityRegistry.load(storage);
    this.pinStorage = new DeviceSourcePinStorage(storage, {
      onRecompute: () => { const recomputed = this.recompute();
        if (recomputed) options.onRecompute?.(recomputed); },
    });
  }

  getLastMerged(): DeviceMergeResult | null { return this.lastMerged;
  }

  getSourceStatuses(): Readonly<Record<HomeBackend, ConnectionStatus>> { return { ...this.sourceStatuses };
  }

    async refreshParallel(options: { readonly fetchHA: () => Promise<DualSourceInputSnapshot>;
    readonly fetchMi: () => Promise<DualSourceInputSnapshot>;
    readonly knownPreferenceIds?: ReadonlySet<string>;
    readonly languagePreference?: LanguagePreference;
  }): Promise<DualSourceRefreshOutcome> { if (options.knownPreferenceIds) {
      this.lastKnownPrefIds = options.knownPreferenceIds;
    }

    const [haSettled, miSettled] = await Promise.allSettled([
      options.fetchHA(),
      options.fetchMi(),
    ]);

    let haError: string | null = null; let miError: string | null = null; 
    if (haSettled.status === "fulfilled") { this.lastHA = haSettled.value;
      this.sourceStatuses.homeAssistant = { kind: "connected" };
    } else { haError =
        haSettled.reason instanceof Error
          ? haSettled.reason.message
          : String(haSettled.reason);
      this.lastHA = null;
      this.sourceStatuses.homeAssistant = {
        kind: "disconnected",
        reason: haError,
      };
    }

    if (miSettled.status === "fulfilled") {
      const statuses = Object.values(miSettled.value.accountStatuses ?? {});
      const allDisconnected = statuses.length > 0 && statuses.every((s) => s.kind === "disconnected");
      if (allDisconnected) {
        const firstDisc = statuses.find(
          (s): s is Extract<ConnectionStatus, { readonly kind: "disconnected" }> => s.kind === "disconnected",
        );
        miError = firstDisc?.reason ?? "Xiaomi Cloud disconnected";
        this.lastMi = null;
        this.sourceStatuses.xiaomiCloud = {
          kind: "disconnected",
          reason: miError,
        };
      } else {
        this.lastMi = miSettled.value;
        this.sourceStatuses.xiaomiCloud = { kind: "connected" };
      }
    } else { miError =
        miSettled.reason instanceof Error
          ? miSettled.reason.message
          : String(miSettled.reason);
      this.lastMi = null;
      this.sourceStatuses.xiaomiCloud = {
        kind: "disconnected",
        reason: miError,
      };
    }

    if (!this.lastHA && !this.lastMi) {
      throw new Error(haError ?? miError ?? "Both Home Assistant and Xiaomi Cloud failed");
    }

    const merged = this.mergeCurrent(options.languagePreference); return {
      merged,
      sourceStatuses: { ...this.sourceStatuses },
      haError,
      miError,
    };
  }

    recompute(languagePreference?: LanguagePreference): DeviceMergeResult | null {
    if (!this.lastHA && !this.lastMi) return null; return this.mergeCurrent(languagePreference); } 
    async execute(command: DeviceCommand, executors: { readonly executeHA: (command: DeviceCommand) => Promise<void>;
      readonly executeMi: (command: DeviceCommand) => Promise<void>;
    }): Promise<HomeBackend> { const backend = commandTargetBackend(command);
    if (backend === "xiaomiCloud") { await executors.executeMi(command); } else { await executors.executeHA(command); }
    return backend; } private mergeCurrent(languagePreference?: LanguagePreference): DeviceMergeResult {
    const merged = DeviceDeduplicator.merge({
      homeAssistant: this.lastHA,
      xiaomiCloud: this.lastMi,
      canonical: this.canonical,
      rooms: this.rooms,
      knownPreferenceIds: this.lastKnownPrefIds,
      pinnedBackends: this.pinStorage.getAll(),
      languagePreference,
    });
    this.canonical = merged.canonical;
    this.rooms = merged.rooms;
    this.canonical.save(this.storage);
    this.rooms.save(this.storage);
    this.lastMerged = merged;
    return merged; } } 
export class DualSourceHomeProvider implements HomeProvider {
  constructor(
    private readonly dependencies: {
      readonly haProvider: HomeProvider;
      readonly miProvider: HomeProvider;
      readonly routes?: Readonly<Record<string, DeviceMergeRoute>>;
      readonly deviceIdForEntity?: (entityId: string) => string | null;
    },
  ) {}

  targetBackendFor(command: DeviceCommand): HomeBackend {
    const { routes, deviceIdForEntity } = this.dependencies;
    if (routes && deviceIdForEntity) {
      const deviceId = deviceIdForEntity(command.entityId);
      const routed = deviceId ? routes[deviceId]?.backend : undefined;
      if (routed && commandTargetBackend(command) === routed) return routed;
    }
    return commandTargetBackend(command);
  }

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<boolean | null> {
    const backend = this.targetBackendFor(command);
    if (backend === "xiaomiCloud") {
      return this.dependencies.miProvider.execute(command, options);
    }
    return this.dependencies.haProvider.execute(command, options);
  }
}
