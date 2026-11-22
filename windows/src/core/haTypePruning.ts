import {
  partitionCapabilityDevices,
  SAFETY_SIGNAL_KINDS, SENSOR_ALERT_TO_SAFETY_SIGNAL,
  type CapabilityIndexedDevice, type CapabilitySelection, type DeviceSetPartition, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import { DEVICE_CATEGORY_IDS, deviceCategoryForDevice, type DeviceCategoryID } from "./capabilityManifest.js";
import { haBinarySensorKind, type HARow, type HAState } from "./haDomains.js";
import { devicePrimaryEntityId, joinsAllOff, type SmartDevice } from "./models.js";

/**
 * Card kinds whose own state carries a battery percentage. The low-battery alert reads that field
 * (`SensorSpec.battery`, `CoverSpec.batteryPercent`, `VacuumSpec.battery`), so only these can carry
 * the signal at all.
 */
const LOW_BATTERY_CATEGORIES: ReadonlySet<DeviceCategoryID> = new Set<DeviceCategoryID>(["sensor", "cover", "vacuum"]);

/**
 * Every alert one Home Assistant card could report, from the shape the synthesizer already built.
 *
 * Home Assistant names its signals explicitly (`binary_sensor.device_class` → `alertKind` /
 * `safetyObservations`), so nothing has to be guessed from free text the way Mi metadata is: a water
 * leak sensor therefore keeps only its leak reads, and a card that names no enabled signal is pruned
 * whole once its type is off.
 *
 * A valve or a plug has no dedicated signal in the shared vocabulary; a valve card is kept only when
 * it also carries an enabled sensor alert on the same device, and its own state never raises one.
 */
export function haSafetySignalsForDevice(device: SmartDevice, starredOffline = false): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>();
  const kind = device.kind;
  // The actuator alerts read a card's own state, so they follow the card kind, not its labels.
  if (kind.kind === "plug") {
    signals.add("longRunningPlug");
    signals.add("highPower");
  } else if (kind.kind === "climate") {
    signals.add("longRunningClimate");
  } else if (kind.kind === "sensor") {
    if (kind.alertKind) signals.add(SENSOR_ALERT_TO_SAFETY_SIGNAL[kind.alertKind]);
    for (const observation of kind.safetyObservations ?? []) {
      signals.add(SENSOR_ALERT_TO_SAFETY_SIGNAL[observation.kind]);
    }
  }
  const battery = kind.kind === "cover"
    ? kind.batteryPercent
    : kind.kind === "sensor" || kind.kind === "vacuum"
      ? kind.battery
      : null;
  if (battery !== null && LOW_BATTERY_CATEGORIES.has(deviceCategoryForDevice(device))) signals.add("lowBattery");
  // A pinned card's offline alert needs nothing but the card itself, so it is the one signal that is
  // attached per device rather than derived from its shape.
  if (starredOffline) signals.add("starredOffline");
  return SAFETY_SIGNAL_KINDS.filter((signal) => signals.has(signal));
}

/**
 * Signals a card's own auxiliary `binary_sensor` rows can still raise. `SafetyMonitor` reads those
 * rows as 更多设置 facets for every card kind (`extractSensorObservations`), so a classic case like a
 * gas shut-off valve whose alert arrives as a facet must keep its card while the gas alert is on.
 * The device class is decisive here, exactly as it is for a sensor card.
 */
export function haAuxiliarySafetySignals(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  allowObjectIdFallback = false,
): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>();
  for (const entity of entities) {
    const kind = haBinarySensorKind(entity, states, allowObjectIdFallback);
    if (kind !== null) signals.add(SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
  }
  return SAFETY_SIGNAL_KINDS.filter((signal) => signals.has(signal));
}

/**
 * One card's own signals, shape-based plus whatever its auxiliary entities can raise. The prune plan
 * and the device-type preview both call this, so the preview names the cards the plan keeps.
 */
export function haCardSafetySignals(
  device: SmartDevice,
  auxiliarySignals: readonly SafetySignalKind[],
  starredOffline = false,
): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>([...haSafetySignalsForDevice(device, starredOffline), ...auxiliarySignals]);
  return SAFETY_SIGNAL_KINDS.filter((signal) => signals.has(signal));
}

export interface HaTypePruneOptions {
  /** Host selection: enabled categories plus the enabled connection scopes. */
  readonly selection: CapabilitySelection;
  /** This connection's scope, `ha:<normalized endpoint>`; pruning only applies when it is enabled. */
  readonly connectionScope: string;
  /** Signals whose alerts are on; a closed category keeps only these cards. */
  readonly safetySignals: readonly SafetySignalKind[];
  /** Pinned card ids, whose offline alert keeps the card itself. */
  readonly starredDeviceIds?: readonly string[];
  /** 全关 overrides, so a hidden card still reports the all-off membership it had. */
  readonly allOffOverrides?: Readonly<Record<string, boolean>>;
  /**
   * Per-card signals from its auxiliary entities (`haAuxiliarySafetySignals`). The synthesizer has
   * the entity rows; a caller that passes only cards can leave this out.
   */
  readonly auxiliarySignalsByDeviceId?: ReadonlyMap<string, readonly SafetySignalKind[]>;
}

export interface HaTypePrunePlan {
  /** The shared partition verdict, so both platforms answer "visible or retained" the same way. */
  readonly partition: DeviceSetPartition;
  readonly visibleDeviceIds: ReadonlySet<string>;
  readonly safetyRetainedDeviceIds: ReadonlySet<string>;
  readonly hiddenDeviceIds: ReadonlySet<string>;
  readonly categoryByDeviceId: ReadonlyMap<string, DeviceCategoryID>;
  /**
   * Index entries for every card this round does not draw. The host needs them to answer
   * "该设备类型已关闭" instead of "设备不存在" when an old link, AI intent or timer points at one,
   * and to keep the identity index unpruned (architecture.md §D).
   */
  readonly hiddenIndexedDevices: readonly CapabilityIndexedDevice[];
}

/**
 * Whether this round prunes at all. A full selection, or a connection scope that is off or not yet
 * migrated, keeps every card and every state exactly as before P3b-W.
 */
export function haTypePruningActive(selection: CapabilitySelection, connectionScope: string): boolean {
  return selection.enabledConnections.includes("home-assistant")
    && selection.enabledConnectionScopes.includes(connectionScope)
    && !DEVICE_CATEGORY_IDS.every((id) => selection.enabledCategories.includes(id));
}

function indexedDevice(
  device: SmartDevice,
  options: HaTypePruneOptions,
  starred: boolean,
): CapabilityIndexedDevice {
  const entityId = devicePrimaryEntityId(device) ?? device.id;
  const readKeys = [entityId];
  return {
    id: device.id,
    name: device.name,
    category: deviceCategoryForDevice(device),
    connection: "home-assistant",
    sourceScope: options.connectionScope,
    isSourceAvailable: true,
    upstreamHiddenOrDisabled: false,
    participatesInAllOff: joinsAllOff(device, options.allOffOverrides ?? {}),
    safetySignals: haCardSafetySignals(device, options.auxiliarySignalsByDeviceId?.get(device.id) ?? [], starred),
    readKeys,
    safetyReadKeys: readKeys,
  };
}

/**
 * Splits one Home Assistant snapshot's cards into the ones to draw, the ones a closed category keeps
 * for its enabled alerts, and the ones to drop — and keeps the dropped cards' identity entries.
 *
 * The Home Assistant link itself is unchanged: `ha_snapshot` is one WebSocket round of registries
 * plus `get_states`, which has no per-domain form, so the saving is on this side (no facets, no
 * environment readings, no card) rather than on the wire (architecture.md §D).
 */
export function buildHaTypePrunePlan(
  options: HaTypePruneOptions & { readonly devices: readonly SmartDevice[] },
): HaTypePrunePlan {
  const enabledSignals = new Set(options.safetySignals);
  const starredIds = enabledSignals.has("starredOffline") ? new Set(options.starredDeviceIds ?? []) : new Set<string>();
  const indexed = options.devices.map((device) => indexedDevice(device, options, starredIds.has(device.id)));
  const partition = partitionCapabilityDevices(indexed, options.selection, {
    enabledSignals: options.safetySignals,
    ...(starredIds.size > 0 ? { starredDeviceIds: [...starredIds] } : {}),
  });
  const visibleDeviceIds = new Set(partition.availableDeviceIds);
  const safetyRetainedDeviceIds = new Set(partition.hiddenSafetyRetainedDeviceIds);
  const categoryByDeviceId = new Map<string, DeviceCategoryID>();
  for (const entry of indexed) categoryByDeviceId.set(entry.id, entry.category);
  const hiddenDeviceIds = new Set(
    indexed.map((entry) => entry.id).filter((id) => !visibleDeviceIds.has(id)),
  );
  return {
    partition,
    visibleDeviceIds,
    safetyRetainedDeviceIds,
    hiddenDeviceIds,
    categoryByDeviceId,
    hiddenIndexedDevices: indexed.filter((entry) => !visibleDeviceIds.has(entry.id)),
  };
}
