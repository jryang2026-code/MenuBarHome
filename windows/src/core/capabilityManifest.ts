import sharedManifestJson from "../../../Shared/capability-manifest.json";
import { isHumidifierCardShape, isValveCardShape } from "./assistant/deviceCategory.js";
import { deviceCardShape, type DeviceCardShape, type DeviceKind, type HomeBackend, type SmartDevice } from "./models.js";

export const CAPABILITY_KINDS = ["connection", "feature", "deviceCategory"] as const;
export type CapabilityKind = (typeof CAPABILITY_KINDS)[number];
export const CAPABILITY_STARTUP_POLICIES = ["whenConfigured", "onDemand", "backgroundWhenEnabled", "readPlanWhenEnabled"] as const;
export type CapabilityStartupPolicy = (typeof CAPABILITY_STARTUP_POLICIES)[number];
export const CAPABILITY_PLATFORMS = ["macos", "windows"] as const;
export type CapabilityPlatform = (typeof CAPABILITY_PLATFORMS)[number];
export const CAPABILITY_SUPPORT_STATUSES = ["supported", "partial", "unsupported"] as const;
export type CapabilitySupportStatus = (typeof CAPABILITY_SUPPORT_STATUSES)[number];
export const CAPABILITY_MATRIX_COVERAGES = ["mapped", "baselineUnlisted"] as const;
export type CapabilityMatrixCoverage = (typeof CAPABILITY_MATRIX_COVERAGES)[number];

export const CONNECTION_CAPABILITY_IDS = ["xiaomi-cloud", "home-assistant"] as const;
export type ConnectionCapabilityID = (typeof CONNECTION_CAPABILITY_IDS)[number];
export const FEATURE_IDS = [
  "voice-input", "ai-assistant", "proactive-suggestions", "companion-integration",
  "event-automation", "grokball", "sensor-history", "plug-energy", "camera-live",
] as const;
export type FeatureID = (typeof FEATURE_IDS)[number];
export const DEVICE_CATEGORY_IDS = [
  "light", "plug", "climate", "fan", "cover", "appliance", "fridge",
  "vacuum", "speaker", "tv", "camera", "sensor", "valve", "generic",
] as const;
export type DeviceCategoryID = (typeof DEVICE_CATEGORY_IDS)[number];

export type CapabilityID = ConnectionCapabilityID | FeatureID | DeviceCategoryID;
export const ALL_CAPABILITY_IDS: readonly CapabilityID[] = [...CONNECTION_CAPABILITY_IDS, ...FEATURE_IDS, ...DEVICE_CATEGORY_IDS];
export const BASELINE_UNLISTED_DEVICE_CATEGORIES: ReadonlySet<DeviceCategoryID> = new Set(["light", "vacuum", "tv"]);

export const CAPABILITY_EXPECTED_KIND = {
  "xiaomi-cloud": "connection", "home-assistant": "connection",
  "voice-input": "feature", "ai-assistant": "feature", "proactive-suggestions": "feature",
  "companion-integration": "feature", "event-automation": "feature", grokball: "feature",
  "sensor-history": "feature", "plug-energy": "feature", "camera-live": "feature",
  light: "deviceCategory", plug: "deviceCategory", climate: "deviceCategory", fan: "deviceCategory",
  cover: "deviceCategory", appliance: "deviceCategory", fridge: "deviceCategory", vacuum: "deviceCategory",
  speaker: "deviceCategory", tv: "deviceCategory", camera: "deviceCategory", sensor: "deviceCategory",
  valve: "deviceCategory", generic: "deviceCategory",
} as const satisfies Record<CapabilityID, CapabilityKind>;

export const CONNECTION_TO_HOME_BACKEND = {
  "xiaomi-cloud": "xiaomiCloud", "home-assistant": "homeAssistant",
} as const satisfies Record<ConnectionCapabilityID, HomeBackend>;

export const HOME_BACKEND_TO_CONNECTION = {
  xiaomiCloud: "xiaomi-cloud", homeAssistant: "home-assistant",
} as const satisfies Record<HomeBackend, ConnectionCapabilityID>;

export const connectionCapabilityForMode = (mode: HomeBackend | "demo"): ConnectionCapabilityID | null =>
  mode === "demo" ? null : HOME_BACKEND_TO_CONNECTION[mode];

export const DEVICE_KIND_TO_CATEGORY = {
  light: "light", plug: "plug", climate: "climate", fan: "fan", humidifier: "fan",
  cover: "cover", appliance: "appliance", fridge: "fridge", vacuum: "vacuum",
  speaker: "speaker", tv: "tv", camera: "camera", sensor: "sensor", generic: "generic",
} as const satisfies Record<DeviceKind["kind"], DeviceCategoryID>;

export const DEVICE_CATEGORY_PRIMARY_KIND_TAG = {
  light: "light", plug: "plug", climate: "climate", fan: "fan", cover: "cover",
  appliance: "appliance", fridge: "fridge", vacuum: "vacuum", speaker: "speaker",
  tv: "tv", camera: "camera", sensor: "sensor", valve: "appliance", generic: "generic",
} as const satisfies Record<DeviceCategoryID, DeviceKind["kind"]>;

/**
 * Which card kinds each category can be drawn from. `fan` also covers the humidifier card and an
 * appliance card whose humidifier service is drawn as one, and `valve` is an appliance card whose
 * hints say valve — so this is a reachability table, not a lookup; `deviceCategoryForCardShape`
 * resolves those overlaps (valve before humidifier before plain appliance).
 */
export const DEVICE_CATEGORY_CARD_KINDS = {
  light: ["light"], plug: ["plug"], climate: ["climate"], fan: ["fan", "humidifier", "appliance"],
  cover: ["cover"], appliance: ["appliance"], fridge: ["fridge"], vacuum: ["vacuum"],
  speaker: ["speaker"], tv: ["tv"], camera: ["camera"], sensor: ["sensor"],
  valve: ["appliance"], generic: ["generic"],
} as const satisfies Record<DeviceCategoryID, readonly DeviceKind["kind"][]>;

/**
 * The approved card types P3c-W pins in the shared corpus, i.e. everything except the camera, whose
 * own teardown and recovery package is P3c-CW. The mapping still answers `camera` for a camera card
 * (a camera is a camera); this list only scopes the type-mapping assertions.
 */
export const NON_CAMERA_DEVICE_CATEGORY_IDS: readonly DeviceCategoryID[] =
  DEVICE_CATEGORY_IDS.filter((id) => id !== "camera");

export const DEVICE_CATEGORY_PRESET_IDS = ["allSupportedTypes", "lightAndSwitch"] as const;
export type DeviceCategoryPresetID = (typeof DEVICE_CATEGORY_PRESET_IDS)[number];

/**
 * The selection presets both platforms offer (P3c-W). `allSupportedTypes` is the manifest's own
 * category list; `lightAndSwitch` is 「只用灯和开关」 — a wall switch that drives a lamp is drawn as
 * a plug card, so both ids are in it. A preset is a list of categories, never of names or models.
 * Both ends must return the same lists; the shared corpus
 * `Tests/Fixtures/capability_selection_golden.json` (`deviceTypeMapping.presets`) pins them.
 */
export const DEVICE_CATEGORY_PRESETS = {
  allSupportedTypes: DEVICE_CATEGORY_IDS,
  lightAndSwitch: ["light", "plug"],
} as const satisfies Record<DeviceCategoryPresetID, readonly DeviceCategoryID[]>;

/**
 * The one place a card becomes a device type. Reads only the card's shape
 * (`models.ts:DeviceCardShape`), never a value, so an empty snapshot classifies like the next one.
 *
 * An appliance card is the one kind that can be two categories: a valve first (a HA `valve.*`
 * entity, a valve model, or a valve name on a card without target temperature or modes), then a
 * humidifier service drawn as a fan. Everything else follows its card kind.
 */
export function deviceCategoryForCardShape(card: DeviceCardShape): DeviceCategoryID {
  if (card.kind === "appliance") {
    if (isValveCardShape(card)) return "valve";
    if (isHumidifierCardShape(card)) return "fan";
  }
  return DEVICE_KIND_TO_CATEGORY[card.kind];
}

export function deviceCategoryForDevice(device: SmartDevice): DeviceCategoryID {
  return deviceCategoryForCardShape(deviceCardShape(device));
}

export interface CapabilityPlatformAvailability { readonly macos: CapabilitySupportStatus; readonly windows: CapabilitySupportStatus; }
export interface CapabilityMatrixMapping { readonly coverage: CapabilityMatrixCoverage; readonly rowIds: readonly string[]; }
export interface CapabilityManifestEntry {
  readonly id: CapabilityID; readonly kind: CapabilityKind; readonly dependsOn: readonly CapabilityID[];
  readonly defaultOnFreshInstall: boolean; readonly startupPolicy: CapabilityStartupPolicy;
  readonly platforms: CapabilityPlatformAvailability; readonly capabilityMatrix: CapabilityMatrixMapping;
}
export type CapabilityManifestErrorCode =
  | "invalid_json_structure" | "unsupported_schema_version" | "unexpected_keys" | "unknown_capability_id"
  | "duplicate_capability_id" | "kind_mismatch" | "missing_capabilities" | "duplicate_dependency"
  | "dependency_cycle" | "unsupported_dependency_platform" | "invalid_default_dependency" | "invalid_matrix_mapping";

export class CapabilityManifestError extends Error {
  constructor(readonly code: CapabilityManifestErrorCode, message: string) {
    super(message);
    this.name = "CapabilityManifestError";
  }
}

export interface CapabilityManifest {
  readonly schemaVersion: number;
  readonly hostCoreCapabilityMatrixIds: readonly string[];
  readonly entries: readonly CapabilityManifestEntry[];
  entryFor(id: CapabilityID): CapabilityManifestEntry;
}

const ROOT_KEYS = new Set(["schemaVersion", "hostCoreCapabilityMatrixIds", "capabilities"]);
const ENTRY_KEYS = new Set(["id", "kind", "dependsOn", "defaultOnFreshInstall", "startupPolicy", "platforms", "capabilityMatrix"]);
const PLATFORM_KEYS = new Set<string>(CAPABILITY_PLATFORMS);
const MATRIX_KEYS = new Set(["coverage", "rowIds"]);

function ensure(cond: unknown, code: CapabilityManifestErrorCode, msg: string): asserts cond {
  if (!cond) throw new CapabilityManifestError(code, msg);
}
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isOneOf = <T extends string>(v: unknown, list: readonly T[]): v is T => typeof v === "string" && (list as readonly string[]).includes(v);
const isCapID = (raw: string): raw is CapabilityID => Object.hasOwn(CAPABILITY_EXPECTED_KIND, raw);

function checkKeys(obj: Record<string, unknown>, allowed: ReadonlySet<string>, scope: string): void {
  const extra = Object.keys(obj).filter((k) => !allowed.has(k)).sort();
  ensure(extra.length === 0, "unexpected_keys", `${scope} unexpected keys: ${extra.join(", ")}`);
}

function parseStrings(v: unknown, field: string): string[] {
  ensure(Array.isArray(v), "invalid_json_structure", `${field} must be an array`);
  return v.map((item) => {
    ensure(typeof item === "string" && item.length > 0, "invalid_json_structure", `${field} requires non-empty strings`);
    return item;
  });
}

export function parseCapabilityManifestJson(jsonText: string): CapabilityManifest {
  let raw: unknown;
  try { raw = JSON.parse(jsonText); }
  catch (err) { throw new CapabilityManifestError("invalid_json_structure", err instanceof Error ? err.message : String(err)); }
  return parseCapabilityManifest(raw);
}

export function parseCapabilityManifest(raw: unknown): CapabilityManifest {
  ensure(isRecord(raw), "invalid_json_structure", "root must be an object");
  checkKeys(raw, ROOT_KEYS, "root");
  ensure(typeof raw.schemaVersion === "number" && Number.isInteger(raw.schemaVersion), "invalid_json_structure", "schemaVersion integer");
  ensure(raw.schemaVersion === 1, "unsupported_schema_version", `schemaVersion ${raw.schemaVersion}`);
  const hostCoreIds = parseStrings(raw.hostCoreCapabilityMatrixIds, "hostCoreCapabilityMatrixIds");
  ensure(new Set(hostCoreIds).size === hostCoreIds.length, "invalid_matrix_mapping", "duplicate hostCoreCapabilityMatrixIds");
  ensure(Array.isArray(raw.capabilities), "invalid_json_structure", "capabilities must be an array");

  const entries: CapabilityManifestEntry[] = [], byID = new Map<CapabilityID, CapabilityManifestEntry>();
  const seenRaw = new Set<string>(), optionalMatrixIds = new Set<string>();

  raw.capabilities.forEach((item, index) => {
    const scope = `capabilities[${index}]`;
    ensure(isRecord(item), "invalid_json_structure", `${scope} must be an object`);
    checkKeys(item, ENTRY_KEYS, scope);
    ensure(typeof item.id === "string" && item.id.length > 0, "invalid_json_structure", `${scope}.id invalid`);
    ensure(!seenRaw.has(item.id), "duplicate_capability_id", `duplicate ${item.id}`);
    seenRaw.add(item.id);
    ensure(isCapID(item.id), "unknown_capability_id", `unknown ${item.id}`);
    const id = item.id;
    ensure(isOneOf(item.kind, CAPABILITY_KINDS), "invalid_json_structure", `${id}.kind invalid`);
    ensure(item.kind === CAPABILITY_EXPECTED_KIND[id], "kind_mismatch", `${id} kind mismatch`);
    const deps: CapabilityID[] = [], seenDeps = new Set<CapabilityID>();
    for (const rawDep of parseStrings(item.dependsOn, `${id}.dependsOn`)) {
      ensure(isCapID(rawDep), "unknown_capability_id", `unknown dependency ${rawDep}`);
      ensure(!seenDeps.has(rawDep), "duplicate_dependency", `duplicate dependency ${rawDep}`);
      seenDeps.add(rawDep); deps.push(rawDep);
    }
    ensure(typeof item.defaultOnFreshInstall === "boolean", "invalid_json_structure", `${id}.defaultOnFreshInstall boolean`);
    ensure(isOneOf(item.startupPolicy, CAPABILITY_STARTUP_POLICIES), "invalid_json_structure", `${id}.startupPolicy invalid`);
    ensure(isRecord(item.platforms), "invalid_json_structure", `${id}.platforms invalid`);
    checkKeys(item.platforms, PLATFORM_KEYS, `${id}.platforms`);
    ensure(isOneOf(item.platforms.macos, CAPABILITY_SUPPORT_STATUSES) && isOneOf(item.platforms.windows, CAPABILITY_SUPPORT_STATUSES), "invalid_json_structure", `${id}.platforms status`);
    ensure(isRecord(item.capabilityMatrix), "invalid_matrix_mapping", `${id}.capabilityMatrix missing`);
    checkKeys(item.capabilityMatrix, MATRIX_KEYS, `${id}.capabilityMatrix`);
    ensure(isOneOf(item.capabilityMatrix.coverage, CAPABILITY_MATRIX_COVERAGES), "invalid_matrix_mapping", `${id}.capabilityMatrix.coverage`);
    const rowIds = parseStrings(item.capabilityMatrix.rowIds, `${id}.capabilityMatrix.rowIds`);
    ensure(new Set(rowIds).size === rowIds.length, "invalid_matrix_mapping", `${id} duplicate rowIds`);
    if (item.capabilityMatrix.coverage === "mapped") {
      ensure(rowIds.length > 0, "invalid_matrix_mapping", `${id} mapped rowIds empty`);
    } else {
      ensure(item.kind === "deviceCategory" && BASELINE_UNLISTED_DEVICE_CATEGORIES.has(id as DeviceCategoryID) && rowIds.length === 0, "invalid_matrix_mapping", `${id} invalid baselineUnlisted`);
    }
    for (const r of rowIds) optionalMatrixIds.add(r);
    const entry: CapabilityManifestEntry = Object.freeze({
      id, kind: item.kind, dependsOn: Object.freeze(deps), defaultOnFreshInstall: item.defaultOnFreshInstall,
      startupPolicy: item.startupPolicy, platforms: Object.freeze({ macos: item.platforms.macos, windows: item.platforms.windows }),
      capabilityMatrix: Object.freeze({ coverage: item.capabilityMatrix.coverage, rowIds: Object.freeze(rowIds) }),
    });
    entries.push(entry); byID.set(id, entry);
  });

  const missing = ALL_CAPABILITY_IDS.filter((id) => !byID.has(id));
  ensure(missing.length === 0, "missing_capabilities", `missing: ${missing.join(", ")}`);
  ensure(!hostCoreIds.some((id) => optionalMatrixIds.has(id)), "invalid_matrix_mapping", "hostCoreCapabilityMatrixIds overlap");
  validateGraph(entries, byID);
  return Object.freeze({
    schemaVersion: raw.schemaVersion, hostCoreCapabilityMatrixIds: Object.freeze(hostCoreIds), entries: Object.freeze(entries),
    entryFor: (id: CapabilityID) => { const found = byID.get(id); ensure(found, "unknown_capability_id", `missing ${id}`); return found; },
  });
}

function validateGraph(entries: readonly CapabilityManifestEntry[], byID: ReadonlyMap<CapabilityID, CapabilityManifestEntry>): void {
  const states = new Map<CapabilityID, "visiting" | "visited">(), stack: CapabilityID[] = [];
  const dfs = (id: CapabilityID): void => {
    states.set(id, "visiting"); stack.push(id);
    const entry = byID.get(id)!;
    for (const dep of entry.dependsOn) {
      const depEntry = byID.get(dep);
      ensure(depEntry, "unknown_capability_id", `unknown dependency ${dep}`);
      ensure(states.get(dep) !== "visiting", "dependency_cycle", `cycle: ${[...stack.slice(Math.max(0, stack.indexOf(dep))), dep].join(" -> ")}`);
      if (!states.has(dep)) dfs(dep);
      for (const p of CAPABILITY_PLATFORMS) {
        ensure(!(entry.platforms[p] !== "unsupported" && depEntry.platforms[p] === "unsupported"), "unsupported_dependency_platform", `${id} -> ${dep} on ${p}`);
      }
      ensure(!(entry.defaultOnFreshInstall && !depEntry.defaultOnFreshInstall), "invalid_default_dependency", `${id} -> ${dep} default`);
    }
    stack.pop(); states.set(id, "visited");
  };
  for (const entry of entries) if (!states.has(entry.id)) dfs(entry.id);
}

export const loadSharedCapabilityManifest = (): CapabilityManifest => parseCapabilityManifest(sharedManifestJson);
