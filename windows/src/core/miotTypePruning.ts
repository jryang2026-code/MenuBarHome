import { deviceCategoryForCardShape, DEVICE_CATEGORY_IDS, type DeviceCategoryID } from "./capabilityManifest.js";
import {
  partitionCapabilityDevices, SAFETY_SIGNAL_KINDS, SENSOR_ALERT_TO_SAFETY_SIGNAL,
  type CapabilityIndexedDevice, type CapabilitySelection, type DeviceSetPartition, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import { miotShortName, type MiotDeviceSpec } from "./miCloud/spec.js";
import { MiotSynthesizer } from "./miCloud/synthesis.js";
import type { MiDeviceRecord, MiotPropKey } from "./miCloud/client.js";
import {
  safetySignalsForPrefs, safetySignalsForSensorPolicy, type SafetySignalPrefs,
} from "./safetySignalPolicy.js";
import { inferSensorAlertKindsFromMetadata, stripLockNeutralTokens } from "./safetyAndHealth.js";
import { deviceCardShapeForKind } from "./models.js";

/**
 * Alerts a closed type still keeps reading for, from the host's safety switches. The mapping itself
 * is shared with the Home Assistant plan (`safetySignalPolicy.ts`); these names stay for the Mi
 * callers that predate it.
 */
export type MiotSafetyPrefs = SafetySignalPrefs;

/** Every safety signal the host is currently evaluating, in the shared vocabulary's own order. */
export const miotSafetySignalsForPrefs = safetySignalsForPrefs;

/** Every sensor-alert signal the host is currently evaluating, in the shared `SafetySignalKind` vocabulary. */
export const miotSafetySignalsForSensorPolicy = safetySignalsForSensorPolicy;

/**
 * The alert engine's own read surface, one field per entry. Splitting instead of concatenating keeps
 * a property name from suppressing a different field's signal, and brings in the descriptions the
 * evaluator surfaces as facet labels. `identifiesDevice` marks the fields that name the device
 * itself: only those may claim the lock signal, because `direction-lock` or "Physical Control
 * Locked" name a lockout on phones, washers and air purifiers.
 *
 * `includeValueLabels` adds a property's `valueList` descriptions. Only a builder-less card renders
 * its properties as facets, so only there do those labels reach the evaluator as facet names; on a
 * card with a builder they are dropdown options (`viomi.hood.c26` labels a fan speed "GasStove").
 */
function alertMetadataFields(
  record: MiDeviceRecord,
  spec: MiotDeviceSpec,
  includeValueLabels: boolean,
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
      if (!includeValueLabels) continue;
      for (const item of property.valueList ?? []) {
        fields.push({ text: stripLockNeutralTokens(item.description), identifiesDevice: false });
      }
    }
  }
  return fields;
}

/**
 * Which alerts this card could report, from the metadata the alert engine itself reads (model, name,
 * device and service names, property names and, on a builder-less card, value labels) plus the
 * alerts its own card kind can carry. A water-leak sensor therefore keeps only its leak reads, and a
 * device that names no safety signal is pruned completely once its type is off.
 */
function safetySignalsFor(
  record: MiDeviceRecord,
  category: DeviceCategoryID,
  spec: MiotDeviceSpec,
  heats: boolean,
  starredOffline: boolean,
): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>();
  // The actuator alerts read a card's own state, so they follow the card kind, not its labels.
  if (category === "plug") {
    signals.add("longRunningPlug");
    signals.add("highPower");
  } else if (category === "climate" || (category === "appliance" && heats)) {
    signals.add("longRunningClimate");
  }
  // The low-battery alert reads the card's own battery field, which only these three kinds publish.
  if (
    LOW_BATTERY_CATEGORIES.has(category) &&
    spec.services.some((service) => miotShortName(service.type) === "battery")
  ) {
    signals.add("lowBattery");
  }
  // A pinned card's offline alert needs nothing but the record itself, so it is the one signal that
  // is attached per device rather than derived from the spec.
  if (starredOffline) signals.add("starredOffline");
  // A lock device or a lock service is a lock whatever its own properties are called. Recognising it
  // here is what keeps a real lock's signal when the device also publishes `child-lock`.
  if (miotShortName(spec.type) === "lock" || spec.services.some((service) => miotShortName(service.type) === "lock")) {
    signals.add("lock");
  }
  // A builder-less card draws every readable property as a facet, so its value labels reach the
  // evaluator; a built card's property values are dropdown options, not labels.
  for (const field of alertMetadataFields(record, spec, category === "generic")) {
    for (const kind of inferSensorAlertKindsFromMetadata(field.text, { wordBoundedShortTokens: true })) {
      // "lock" outside a device's own name is a lockout, not a lock: `direction-lock`, `DoorNotLock`.
      if (kind === "lock" && !field.identifiesDevice) continue;
      signals.add(SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
    }
  }
  return SAFETY_SIGNAL_KINDS.filter((kind) => signals.has(kind));
}

/** Card kinds whose own state carries a battery percentage (`extractBatteryPercent`). */
const LOW_BATTERY_CATEGORIES: ReadonlySet<DeviceCategoryID> = new Set<DeviceCategoryID>(["sensor", "cover", "vacuum"]);

export interface MiotTypePruneOptions {
  readonly rawDevices: readonly MiDeviceRecord[];
  readonly specs: Readonly<Record<string, MiotDeviceSpec>>;
  /** Host selection: enabled categories plus the enabled connection scopes (one per Mi account). */
  readonly selection: CapabilitySelection;
  /** Connection scope these records belong to, e.g. `mi:<accountId>`. */
  readonly connectionScope: string;
  /** Signals whose alerts are on; a closed category keeps the reads those alerts need. */
  readonly safetySignals: readonly SafetySignalKind[];
  /**
   * Pinned card ids. `starredOffline` needs the record's `isOnline` only, so a closed card this
   * alone keeps is synthesized from topology with no reads at all.
   */
  readonly starredDeviceIds?: readonly string[];
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
  /**
   * Every classified card's own signals, drawn or not. The device-type preview reads this so it
   * names the same retained cards this plan would keep once a type is closed.
   */
  readonly safetySignalsByDeviceId: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

interface ClassifiedPlan {
  readonly deviceId: string;
  readonly name: string;
  readonly category: DeviceCategoryID;
  readonly safetySignals: readonly SafetySignalKind[];
  /** The offline alert is on and a pinned id names this very card. */
  readonly starredOffline: boolean;
  readonly required: readonly MiotPropKey[];
  readonly facets: readonly MiotPropKey[];
  readonly safetyReadKeys: readonly MiotPropKey[];
}

const propId = (key: MiotPropKey): string => `${key.did}|${key.siid}|${key.piid}`;

/** `MiAccountScope`'s own vocabulary, kept local to avoid a module cycle with the account store. */
const scopedOwner = (scopedId: string): string | null => {
  const slash = scopedId.indexOf("/");
  return slash >= 0 ? scopedId.slice(0, slash) : null;
};
const scopedLocalId = (scopedId: string): string => {
  const slash = scopedId.indexOf("/");
  return slash >= 0 ? scopedId.slice(slash + 1) : scopedId;
};
/** The connection scope of an account id, in the same vocabulary the selection stores. */
const scopeOfAccount = (accountId: string): string => (accountId.startsWith("mi:") ? accountId : `mi:${accountId}`);

/**
 * The pinned ids that name this account's cards, in the bare form a plan's device id takes. The
 * panel stores the id it drew — `<accountId>/<did>` on a multi-account host, the bare did
 * otherwise — and a namespace owner whose scope is another account is a different device that
 * happens to share the raw did.
 */
function starredIdsForScope(
  starredDeviceIds: readonly string[],
  connectionScope: string,
): string[] {
  const ids: string[] = [];
  for (const starred of starredDeviceIds) {
    const owner = scopedOwner(starred);
    if (owner !== null && scopeOfAccount(owner) !== connectionScope) continue;
    const localId = scopedLocalId(starred);
    if (!ids.includes(localId)) ids.push(localId);
  }
  return ids;
}

function classifyRecord(
  record: MiDeviceRecord,
  spec: MiotDeviceSpec,
  isStarredDeviceId: (planId: string) => boolean,
): ClassifiedPlan[] {
  return MiotSynthesizer.planReadKeys(record, spec).map((plan) => {
    // The value-free builder already produced the card kind, so classify that card shape instead of
    // a stand-in `SmartDevice`: the same call the HA plan makes, and no invented room or id. No
    // builder at all means the facet layer draws a generic card, which is also the type the user sees.
    const category = plan.kind === null
      ? "generic" as const
      : deviceCategoryForCardShape(
          deviceCardShapeForKind(plan.kind, { id: plan.planId, model: record.model, name: plan.name }),
        );
    const heats = plan.kind !== null && plan.kind.kind === "appliance" && plan.kind.heats;
    const starredOffline = isStarredDeviceId(plan.planId);
    return {
      deviceId: plan.planId,
      name: plan.name,
      category,
      safetySignals: safetySignalsFor(record, category, plan.spec, heats, starredOffline),
      starredOffline,
      required: plan.required,
      facets: plan.facets,
      // Either layer can raise the alert: a dedicated card reads its state from card properties,
      // while a facet carries the alarm label of a builder-less card. Keep both, and stop them all
      // once the matching alert is switched off.
      safetyReadKeys: [...plan.required, ...plan.facets],
    };
  });
}

function indexedDevice(
  plan: ClassifiedPlan,
  sourceScope: string,
  keepsSignalReads: boolean,
): CapabilityIndexedDevice {
  const readKeys = [...plan.required, ...plan.facets].map(propId);
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
    // A card the offline alert alone keeps needs no read: its record is synthesized for `isOnline`
    // and nothing else. Both fields empty is what makes `partitionCapabilityDevices` add no keys,
    // because it falls back from an empty `safetyReadKeys` to `readKeys`.
    readKeys: keepsSignalReads ? readKeys : [],
    safetyReadKeys: keepsSignalReads ? plan.safetyReadKeys.map(propId) : [],
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
 * Whether this round draws none of one type's cards for one Mi scope. A scope that is unknown,
 * still migrating or fully enabled prunes nothing, so every type counts as drawn there — the same
 * fail-closed rule the read plan follows.
 */
export function miotRoundClosesCategory(
  selection: CapabilitySelection,
  connectionScope: string,
  category: DeviceCategoryID,
): boolean {
  const prunes =
    selection.enabledConnections.includes("xiaomi-cloud") &&
    selection.enabledConnectionScopes.includes(connectionScope) &&
    !DEVICE_CATEGORY_IDS.every((id) => selection.enabledCategories.includes(id));
  return prunes && !selection.enabledCategories.includes(category);
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
  /** Only a real selection prunes; an unknown scope or a full selection keeps every read. */
  const pruning = sourceEnabled && !everyCategoryEnabled;
  const enabledSignals = new Set(options.safetySignals);
  const starredAlertOn = enabledSignals.has("starredOffline");
  // The partition's star check compares a device id, so the pinned ids have to be in the same bare
  // form this account's plan ids take.
  const starredDeviceIds = starredAlertOn
    ? starredIdsForScope(options.starredDeviceIds ?? [], options.connectionScope)
    : [];
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
    const plans = classifyRecord(
      record,
      spec,
      (planId) => starredAlertOn && starredDeviceIds.includes(planId),
    );
    plansByRecord.set(record, plans);
    for (const plan of plans) {
      categoryByDeviceId.set(plan.deviceId, plan.category);
      // A closed card that only its pinned-offline alert keeps reads nothing, because `isOnline` is
      // already on the record. Every other kept card keeps the reads some enabled alert needs.
      const starredOnly =
        pruning &&
        !options.selection.enabledCategories.includes(plan.category) &&
        plan.starredOffline &&
        !plan.safetySignals.some((kind) => kind !== "starredOffline" && enabledSignals.has(kind));
      indexed.push(indexedDevice(plan, options.connectionScope, !starredOnly));
      for (const key of [...plan.required, ...plan.facets, ...plan.safetyReadKeys]) keyIndex.set(propId(key), key);
    }
  }

  const partition = partitionCapabilityDevices(
    indexed,
    pruning ? options.selection : unprunedSelection(options.connectionScope),
    {
      enabledSignals: options.safetySignals,
      ...(starredAlertOn ? { starredDeviceIds } : {}),
    },
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
  const safetySignalsByDeviceId = Object.fromEntries(indexed.map((device) => [device.id, device.safetySignals]));

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
    safetySignalsByDeviceId,
  };
}
