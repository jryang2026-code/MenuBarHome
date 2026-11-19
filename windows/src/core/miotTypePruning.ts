import { deviceCategoryForDevice, DEVICE_CATEGORY_IDS, type DeviceCategoryID } from "./capabilityManifest.js";
import {
  partitionCapabilityDevices, SAFETY_SIGNAL_KINDS, SENSOR_ALERT_TO_SAFETY_SIGNAL,
  type CapabilityIndexedDevice, type CapabilitySelection, type DeviceSetPartition, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import { miotShortName, type MiotDeviceSpec } from "./miCloud/spec.js";
import { MiotSynthesizer } from "./miCloud/synthesis.js";
import type { MiDeviceRecord, MiotPropKey } from "./miCloud/client.js";
import {
  inferSensorAlertKindsFromMetadata, SENSOR_ALERT_KINDS, sensorAlertEnabledByDefault, stripLockNeutralTokens,
  type SensorAlertKind, type SensorAlertPolicy,
} from "./safetyAndHealth.js";

/**
 * Alerts a closed type still keeps reading for, from the host's safety switches. `enableSafetyAlerts`
 * is the master switch, and each long-run / battery alert keeps only its own signal
 * (architecture.md §D, ruling 3).
 */
export interface MiotSafetyPrefs {
  readonly enableSafetyAlerts: boolean;
  readonly longRunningPlug: boolean;
  readonly longRunningClimate: boolean;
  readonly lowBattery: boolean;
}

/** Every safety signal the host is currently evaluating, in the shared vocabulary's own order. */
export function miotSafetySignalsForPrefs(prefs: MiotSafetyPrefs, policy: SensorAlertPolicy): SafetySignalKind[] {
  if (!prefs.enableSafetyAlerts) return [];
  const signals = new Set<SafetySignalKind>(miotSafetySignalsForSensorPolicy(policy));
  if (prefs.longRunningPlug) {
    signals.add("longRunningPlug");
    signals.add("highPower");
  }
  if (prefs.longRunningClimate) signals.add("longRunningClimate");
  if (prefs.lowBattery) signals.add("lowBattery");
  return SAFETY_SIGNAL_KINDS.filter((kind) => signals.has(kind));
}

/** Every sensor-alert signal the host is currently evaluating, in the shared `SafetySignalKind` vocabulary. */
export function miotSafetySignalsForSensorPolicy(policy: SensorAlertPolicy): SafetySignalKind[] {
  return SENSOR_ALERT_KINDS
    .filter((kind: SensorAlertKind) => policy.enabled[kind] ?? sensorAlertEnabledByDefault(kind))
    .map((kind) => SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
}

/**
 * The alert engine's own read surface, one field per entry. Splitting instead of concatenating keeps
 * a property name from suppressing a different field's signal, and brings in the descriptions the
 * evaluator surfaces as facet labels. `identifiesDevice` marks the fields that name the device
 * itself: only those may claim the lock signal, because `direction-lock` or "Physical Control
 * Locked" name a lockout on phones, washers and air purifiers.
 */
function alertMetadataFields(
  record: MiDeviceRecord,
  spec: MiotDeviceSpec,
): { readonly text: string; readonly identifiesDevice: boolean }[] {
  const fields = [record.model, record.name, record.specType ?? "", spec.type, spec.description ?? ""]
    .map((text) => ({ text: stripLockNeutralTokens(text), identifiesDevice: true }));
  for (const service of spec.services) {
    // A service is part of the device's own shape (`lock`, `child-lock`), a property is not.
    fields.push({ text: stripLockNeutralTokens(service.type), identifiesDevice: true });
    fields.push({ text: stripLockNeutralTokens(service.description ?? ""), identifiesDevice: false });
    for (const property of service.properties) {
      fields.push({ text: stripLockNeutralTokens(property.type), identifiesDevice: false });
      fields.push({ text: stripLockNeutralTokens(property.description ?? ""), identifiesDevice: false });
      for (const item of property.valueList ?? []) {
        fields.push({ text: stripLockNeutralTokens(item.description), identifiesDevice: false });
      }
    }
  }
  return fields;
}

/**
 * Which alerts this card could report, from the metadata the alert engine itself reads (model, name,
 * device and service names, property names and value labels) plus the alerts its own card kind can
 * carry. A water-leak sensor therefore keeps only its leak reads, and a device that names no safety
 * signal is pruned completely once its type is off.
 */
function safetySignalsFor(
  record: MiDeviceRecord,
  category: DeviceCategoryID,
  spec: MiotDeviceSpec,
  heats: boolean,
): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>();
  // The actuator alerts read a card's own state, so they follow the card kind, not its labels.
  if (category === "plug") {
    signals.add("longRunningPlug");
    signals.add("highPower");
  } else if (category === "climate" || (category === "appliance" && heats)) {
    signals.add("longRunningClimate");
  }
  if (spec.services.some((service) => miotShortName(service.type) === "battery")) signals.add("lowBattery");
  // A lock device or a lock service is a lock whatever its own properties are called. Recognising it
  // here is what keeps a real lock's signal when the device also publishes `child-lock`.
  if (miotShortName(spec.type) === "lock" || spec.services.some((service) => miotShortName(service.type) === "lock")) {
    signals.add("lock");
  }
  for (const field of alertMetadataFields(record, spec)) {
    for (const kind of inferSensorAlertKindsFromMetadata(field.text)) {
      // "lock" outside a device's own name is a lockout, not a lock: `direction-lock`, `DoorNotLock`.
      if (kind === "lock" && !field.identifiesDevice) continue;
      signals.add(SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
    }
  }
  return SAFETY_SIGNAL_KINDS.filter((kind) => signals.has(kind));
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
    const heats = plan.kind !== null && plan.kind.kind === "appliance" && plan.kind.heats;
    return {
      deviceId: plan.planId,
      name: plan.name,
      category,
      safetySignals: safetySignalsFor(record, category, plan.spec, heats),
      required: plan.required,
      facets: plan.facets,
      // Either layer can raise the alert: a dedicated card reads its state from card properties,
      // while a facet carries the alarm label of a builder-less card. Keep both, and stop them all
      // once the matching alert is switched off.
      safetyReadKeys: [...plan.required, ...plan.facets],
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
  // A split parent is drawn only through its tracks (`MiotSynthesizer.synthesize`), so its own
  // whole-spec plan must not add reads or index entries.
  const splitParents = new Set(
    options.rawDevices.map((record) => record.splitParentDid).filter((did): did is string => !!did),
  );

  const keyIndex = new Map<string, MiotPropKey>();
  const categoryByDeviceId = new Map<string, DeviceCategoryID>();
  const plansByRecord = new Map<MiDeviceRecord, ClassifiedPlan[]>();
  /** No spec yet: the record stays visible and contributes no reads, exactly as before P3a-W. */
  const unprunedDeviceIds = new Set<string>();
  const indexed: CapabilityIndexedDevice[] = [];
  for (const record of options.rawDevices) {
    if (splitParents.has(record.did)) continue;
    // Never fall back to an inferred spec here: `collectMiotPropKeys` reads nothing for such a
    // record, so inventing keys would change the read plan whenever a spec is still missing.
    const spec = options.specs[record.model];
    if (!spec) {
      unprunedDeviceIds.add(record.did);
      continue;
    }
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

  const visibleIds = new Set([...partition.availableDeviceIds, ...unprunedDeviceIds]);
  const safetyIds = new Set(partition.hiddenSafetyRetainedDeviceIds);
  const skippedDeviceIds = new Set<string>();
  const visibleRecords: MiDeviceRecord[] = [];
  const safetyRecords: MiDeviceRecord[] = [];
  for (const record of options.rawDevices) {
    const plans = plansByRecord.get(record);
    if (plans === undefined) {
      // Spec-less record, or a split parent: the former is always drawn, the latter never is.
      if (unprunedDeviceIds.has(record.did)) visibleRecords.push(record);
      continue;
    }
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
