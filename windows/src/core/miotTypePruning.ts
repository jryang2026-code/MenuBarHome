import { deviceCategoryForDevice, DEVICE_CATEGORY_IDS, type DeviceCategoryID } from "./capabilityManifest.js";
import {
  partitionCapabilityDevices, SENSOR_ALERT_TO_SAFETY_SIGNAL,
  type CapabilityIndexedDevice, type CapabilitySelection, type DeviceSetPartition, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import { inferFallbackSpec, type MiotDeviceSpec } from "./miCloud/spec.js";
import { MiotSynthesizer } from "./miCloud/synthesis.js";
import type { MiDeviceRecord, MiotPropKey } from "./miCloud/client.js";
import { SENSOR_ALERT_KINDS, sensorAlertEnabledByDefault, type SensorAlertKind, type SensorAlertPolicy } from "./safetyAndHealth.js";

/**
 * The desktop-alert signals a closed device category still reads for, per `architecture.md` §D.
 * Only alerts the user can switch on and off are listed: long-run, high-power, offline and low
 * battery have no per-kind switch yet, so there is nothing to retain for them without a setting.
 */
const CATEGORY_SAFETY_SIGNALS: Readonly<Partial<Record<DeviceCategoryID, readonly SafetySignalKind[]>>> = {
  // Mi smoke, gas, leak, contact, motion, vibration and lock sensors all synthesize a `sensor` card
  // whose alert labels come from its own card properties.
  sensor: SENSOR_ALERT_KINDS.map((kind) => SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]),
  // A generic card has no builder: its state, including alert labels, is every readable facet
  // property, so it cannot be split into "alert-only" reads.
  generic: SENSOR_ALERT_KINDS.map((kind) => SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]),
};

/** Every sensor-alert signal the host is currently evaluating, in the shared `SafetySignalKind` vocabulary. */
export function miotSafetySignalsForSensorPolicy(policy: SensorAlertPolicy): SafetySignalKind[] {
  return SENSOR_ALERT_KINDS
    .filter((kind: SensorAlertKind) => policy.enabled[kind] ?? sensorAlertEnabledByDefault(kind))
    .map((kind) => SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
}

export interface MiotTypePruneOptions {
  readonly rawDevices: readonly MiDeviceRecord[];
  readonly specs: Readonly<Record<string, MiotDeviceSpec>>;
  /** Host selection: enabled categories plus the enabled connection scopes (one per Mi account). */
  readonly selection: CapabilitySelection;
  /** Connection scope these records belong to, e.g. `mi:<accountId>`. */
  readonly connectionScope: string;
  /** Signals whose alerts are on; a closed category keeps the reads those alerts need. */
  readonly safetySignals: readonly SafetySignalKind[];
}

export interface MiotTypePrunePlan {
  /** The shared partition verdict, so both platforms answer "visible or retained" the same way. */
  readonly partition: DeviceSetPartition;
  /** The round's whole read plan: every visible card plus every retained safety signal. */
  readonly readKeys: readonly MiotPropKey[];
  readonly visibleDeviceIds: ReadonlySet<string>;
  readonly safetyRetainedDeviceIds: ReadonlySet<string>;
  readonly skippedDeviceIds: ReadonlySet<string>;
  readonly categoryByDeviceId: ReadonlyMap<string, DeviceCategoryID>;
  /** Records to synthesize into cards, and records kept only for alert evaluation. */
  readonly visibleRecords: readonly MiDeviceRecord[];
  readonly safetyRecords: readonly MiDeviceRecord[];
  /**
   * Index entries for every card this round does not draw. The host needs them to answer
   * "该设备类型已关闭" instead of "设备不存在" when an old link, AI intent or timer points at one,
   * and to keep the identity index unpruned (architecture.md §D).
   */
  readonly hiddenIndexedDevices: readonly CapabilityIndexedDevice[];
}

interface ClassifiedPlan {
  readonly deviceId: string;
  readonly name: string;
  readonly category: DeviceCategoryID;
  readonly safetySignals: readonly SafetySignalKind[];
  readonly required: readonly MiotPropKey[];
  readonly facets: readonly MiotPropKey[];
  readonly safetyReadKeys: readonly MiotPropKey[];
}

const propId = (key: MiotPropKey): string => `${key.did}|${key.siid}|${key.piid}`;

function classifyRecord(record: MiDeviceRecord, spec: MiotDeviceSpec): ClassifiedPlan[] {
  return MiotSynthesizer.planReadKeys(record, spec).map((plan) => {
    // `deviceCategoryForDevice` also splits valves and humidifiers out of `appliance`, so it needs a
    // device shape; the value-free builder already produced the card kind for it. No builder at all
    // means the facet layer draws a generic card, which is also the type the user sees.
    const category = plan.kind === null
      ? "generic" as const
      : deviceCategoryForDevice({
          id: plan.planId, name: plan.name, roomId: "other", roomName: "",
          model: record.model, isOnline: record.isOnline, kind: plan.kind,
        });
    return {
      deviceId: plan.planId,
      name: plan.name,
      category,
      safetySignals: CATEGORY_SAFETY_SIGNALS[category] ?? [],
      required: plan.required,
      facets: plan.facets,
      // A hidden card only needs the reads its alert comes from. A card without a builder has no
      // card properties at all, so its facet reads are the alert source.
      safetyReadKeys: plan.required.length > 0 ? plan.required : plan.facets,
    };
  });
}

function indexedDevice(plan: ClassifiedPlan, sourceScope: string): CapabilityIndexedDevice {
  return {
    id: plan.deviceId,
    name: plan.name,
    category: plan.category,
    connection: "xiaomi-cloud",
    sourceScope,
    isSourceAvailable: true,
    upstreamHiddenOrDisabled: false,
    participatesInAllOff: false,
    safetySignals: plan.safetySignals,
    readKeys: [...plan.required, ...plan.facets].map(propId),
    safetyReadKeys: plan.safetyReadKeys.map(propId),
  };
}

/** Selection that prunes nothing, for sources whose scope is not enabled or still being migrated. */
function unprunedSelection(connectionScope: string): CapabilitySelection {
  return {
    enabledConnections: ["xiaomi-cloud"],
    enabledConnectionScopes: [connectionScope],
    enabledFeatures: [],
    enabledCategories: [...DEVICE_CATEGORY_IDS],
  };
}

/**
 * Splits one account's raw Mi records into the cards to synthesize, the safety signals a closed
 * category must keep, and the records to skip entirely — and returns the single read plan for the
 * round, so LAN/cloud batching, dual source and multi-account all poll the same keys.
 *
 * A closed category must never hide a device just because its spec is missing, its scope is not
 * enabled yet, or the account is mid-migration: those paths stay unpruned.
 */
export function buildMiotTypePrunePlan(options: MiotTypePruneOptions): MiotTypePrunePlan {
  const sourceEnabled =
    options.selection.enabledConnections.includes("xiaomi-cloud") &&
    options.selection.enabledConnectionScopes.includes(options.connectionScope);
  const everyCategoryEnabled = DEVICE_CATEGORY_IDS.every((id) => options.selection.enabledCategories.includes(id));

  const keyIndex = new Map<string, MiotPropKey>();
  const categoryByDeviceId = new Map<string, DeviceCategoryID>();
  const plansByRecord = new Map<MiDeviceRecord, ClassifiedPlan[]>();
  const indexed: CapabilityIndexedDevice[] = [];
  for (const record of options.rawDevices) {
    const spec = options.specs[record.model] ?? inferFallbackSpec(record);
    const plans = classifyRecord(record, spec);
    plansByRecord.set(record, plans);
    for (const plan of plans) {
      categoryByDeviceId.set(plan.deviceId, plan.category);
      indexed.push(indexedDevice(plan, options.connectionScope));
      for (const key of [...plan.required, ...plan.facets, ...plan.safetyReadKeys]) keyIndex.set(propId(key), key);
    }
  }

  const partition = partitionCapabilityDevices(
    indexed,
    sourceEnabled && !everyCategoryEnabled ? options.selection : unprunedSelection(options.connectionScope),
    { enabledSignals: options.safetySignals },
  );

  const visibleIds = new Set(partition.availableDeviceIds);
  const safetyIds = new Set(partition.hiddenSafetyRetainedDeviceIds);
  const skippedDeviceIds = new Set<string>();
  const visibleRecords: MiDeviceRecord[] = [];
  const safetyRecords: MiDeviceRecord[] = [];
  for (const [record, plans] of plansByRecord) {
    const ids = plans.map((plan) => plan.deviceId);
    if (ids.some((id) => visibleIds.has(id))) {
      visibleRecords.push(record);
    } else if (ids.some((id) => safetyIds.has(id))) {
      safetyRecords.push(record);
    } else {
      for (const id of ids) skippedDeviceIds.add(id);
    }
  }

  const readKeys: MiotPropKey[] = [];
  for (const id of partition.readPlanKeys) {
    const key = keyIndex.get(id);
    if (key !== undefined) readKeys.push(key);
  }
  const hiddenIndexedDevices = indexed.filter((device) => !visibleIds.has(device.id));

  return {
    partition,
    readKeys,
    visibleDeviceIds: visibleIds,
    safetyRetainedDeviceIds: safetyIds,
    skippedDeviceIds,
    categoryByDeviceId,
    visibleRecords,
    safetyRecords,
    hiddenIndexedDevices,
  };
}
