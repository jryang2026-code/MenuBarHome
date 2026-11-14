import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoAction } from "./appTypes.js";
import type { HabitRecordingReceipt } from "../core/assistant.js";
import { currentLanguage, resolveLanguage, t } from "../core/i18n.js";
import {
  classifyControlFailure,
  controlFailureUserMessage,
  isCancellationError,
} from "../core/controlFailure.js";
import { HomeAssistantClient, homeAssistantCommand } from "../core/homeAssistant.js";
import {
  DemoHomeProvider,
  HomeAssistantProvider,
  MiCloudProvider,
  PowerReadBackError,
  type HomeProvider,
} from "../core/homeProvider.js";
import {
  MiCloudClient,
  MiCloudError,
  MiotSynthesizer,
  type MiDeviceRecord,
  type MiRoom,
  type MiotPropKey,
} from "../core/miCloudClient.js";
import { facetTitle, facetValue } from "../core/miotFacetText.js";
import type {
  DeviceCommand,
  DeviceKind,
  FacetControl,
  SmartDevice,
} from "../core/models.js";
import { applyCommandToDevices } from "../core/commandEffects.js";
import {
  applyHAExtendedCommandEffect,
  claimDeviceWrite,
  COVER_OPTIMISTIC_LOCK_DURATION_MS,
  isHostAttachedToActiveWindow,
  lockOptimistic,
  mergeHomeSnapshotRespectingLocks,
  OPTIMISTIC_LOCK_DURATION_MS,
  ownsDeviceWrite,
  peekDeviceWriteSeq,
  READ_BACK_BUSY_RETRY_LIMIT,
  READ_BACK_BUSY_RETRY_MS,
  READ_BACK_DELAY_MS,
  restoreOptimisticLock,
  scheduleDelayedReadBack,
  snapshotOptimisticLock,
  syncDirectCommandToFacets,
  type DeviceWriteClaim,
  type OptimisticLockSnapshot,
} from "../core/optimisticLock.js";
import { localizeEffect } from "./panelPrefs.js";

export const MIOT_PROPERTY_UNSUPPORTED_CODE = -704002000;

export const ECHO_READ_BACK_DELAY_MS = 2_200;

const UNDO_EXPIRY_MS = 10 * 60 * 1000;

const customApplyCommandByHost = new WeakMap<
  object,
  (command: DeviceCommand, readBackPower?: boolean) => Promise<boolean>
>();

export function setCustomApplyCommand(
  host: MenuMijiaWindowsApp,
  fn: (command: DeviceCommand, readBackPower?: boolean) => Promise<boolean>,
): void {
  customApplyCommandByHost.set(host, fn);
}

export function getHostApplyCommand(
  host: MenuMijiaWindowsApp,
): (command: DeviceCommand, readBackPower?: boolean) => Promise<boolean> {
  const custom = customApplyCommandByHost.get(host);
  if (!custom) {
    return (command: DeviceCommand, readBackPower = false) =>
      applyCommand(host, command, readBackPower);
  }
  return (command: DeviceCommand, readBackPower = false) => {
    const targetDeviceId = deviceOwningEntityId(
      host.devices,
      host.deviceFacets ?? {},
      command.entityId,
    );
    const seqBefore = targetDeviceId !== null ? peekDeviceWriteSeq(host, targetDeviceId) : 0;
    const promise = custom.call(host, command, readBackPower);
    if (targetDeviceId !== null && peekDeviceWriteSeq(host, targetDeviceId) === seqBefore) {
      claimDeviceWrite(host, targetDeviceId);
    }
    return promise;
  };
}

function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  params?: Record<string, string | number>,
): string {
  const lang = resolveLanguage(currentLanguage(), []);
  let template = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  if (params) {
    for (const [key, val] of Object.entries(params)) {
      template = template.replaceAll(`{${key}}`, String(val));
    }
  }
  return template;
}

function renderHostImmediate(host: MenuMijiaWindowsApp): void {
  if (typeof host.render === "function") {
    host.render();
  } else if (typeof host.queueBackgroundRender === "function") {
    host.queueBackgroundRender();
  }
}

function withReadPower(command: DeviceCommand, isOn: boolean): DeviceCommand {
  switch (command.kind) {
    case "setLightPower":
    case "setClimatePower":
    case "setFanPower":
    case "setSwitch":
      return { ...command, isOn };
    default:
      return command;
  }
}

function isAdjustmentCommand(command: DeviceCommand): boolean {
  switch (command.kind) {
    case "setLightBrightness":
    case "setLightColorTemp":
    case "setClimateTemperature":
    case "setFanPercentage":
    case "setNumberValue":
    case "mediaSetVolume":
      return true;
    case "setMiotProperty":
      return typeof command.value === "number";
    default:
      return false;
  }
}

function displayNameForDevice(host: MenuMijiaWindowsApp, device: SmartDevice | null): string {
  if (!device) return "";
  const alias = host.layout?.aliases?.[device.id]?.trim();
  return alias || device.name;
}

interface HostUnsupportedEffectsState {
  sourceRevision: number;
  readonly byDevice: Map<string, Set<string>>;
}

const unsupportedEffectsByHost = new WeakMap<object, HostUnsupportedEffectsState>();

function ensureUnsupportedEffectsState(host: MenuMijiaWindowsApp): HostUnsupportedEffectsState {
  let state = unsupportedEffectsByHost.get(host);
  if (!state) {
    state = { sourceRevision: host.sourceRevision, byDevice: new Map() };
    unsupportedEffectsByHost.set(host, state);
    return state;
  }
  if (state.sourceRevision !== host.sourceRevision) {
    state.byDevice.clear();
    state.sourceRevision = host.sourceRevision;
  }
  return state;
}

export function getUnsupportedLightEffects(
  host: MenuMijiaWindowsApp,
  deviceId: string,
): ReadonlySet<string> {
  const state = ensureUnsupportedEffectsState(host);
  return state.byDevice.get(deviceId) ?? new Set<string>();
}

export function isLightEffectUnsupported(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  effect: string,
): boolean {
  const set = ensureUnsupportedEffectsState(host).byDevice.get(deviceId);
  if (!set) return false;
  const normalized = effect.trim().toLowerCase();
  for (const item of set) {
    if (item.trim().toLowerCase() === normalized) return true;
  }
  return false;
}

export function filterSupportedLightEffects(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  effects: readonly string[],
): string[] {
  const set = ensureUnsupportedEffectsState(host).byDevice.get(deviceId);
  if (!set || set.size === 0) return [...effects];
  return effects.filter((effect) => !isLightEffectUnsupported(host, deviceId, effect));
}

export function pruneUnsupportedLightEffectsOnHost(host: MenuMijiaWindowsApp): boolean {
  const state = ensureUnsupportedEffectsState(host);
  if (state.byDevice.size === 0) return false;
  let mutated = false;
  for (const dev of host.devices ?? []) {
    if (dev.kind.kind !== "light") continue;
    if (!state.byDevice.has(dev.id)) continue;
    const filtered = filterSupportedLightEffects(host, dev.id, dev.kind.availableEffects);
    const nextCurrent =
      dev.kind.currentEffect && isLightEffectUnsupported(host, dev.id, dev.kind.currentEffect)
        ? null
        : dev.kind.currentEffect;
    if (
      filtered.length !== dev.kind.availableEffects.length ||
      nextCurrent !== dev.kind.currentEffect
    ) {
      dev.kind = {
        ...dev.kind,
        availableEffects: filtered,
        currentEffect: nextCurrent,
      };
      mutated = true;
    }
  }
  return mutated;
}

export function recordUnsupportedLightEffect(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  effect: string,
): void {
  const trimmed = effect.trim();
  if (!trimmed) return;
  const state = ensureUnsupportedEffectsState(host);
  let set = state.byDevice.get(deviceId);
  if (!set) {
    set = new Set<string>();
    state.byDevice.set(deviceId, set);
  }
  set.add(trimmed);
  pruneUnsupportedLightEffectsOnHost(host);
}

export interface CapturedReversibleFacet {
  readonly dev: SmartDevice;
  readonly control: FacetControl;
  readonly entityId: string;
  readonly piid: number;
  readonly restoreValue: boolean | number | string;
  readonly nextValue: unknown;
}

const undoRestoreCommands = new WeakSet<DeviceCommand>();

export function isUndoRestoreCommand(command: DeviceCommand): boolean {
  return undoRestoreCommands.has(command);
}

export function captureReversibleFacetBeforeWrite(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): CapturedReversibleFacet | null {
  if (command.kind !== "setMiotProperty") return null;
  if (undoRestoreCommands.has(command)) return null;
  const facets = host.deviceFacets ?? {};
  for (const [devId, controls] of Object.entries(facets)) {
    const control = controls.find(
      (item) =>
        item.target?.kind === "property" &&
        item.target.entityId === command.entityId &&
        item.target.piid === command.piid,
    );
    if (!control) continue;
    if (control.kind !== "toggle" && control.kind !== "slider" && control.kind !== "select") {
      return null;
    }
    const dev = host.devices.find((item) => item.id === devId);
    if (!dev) return null;

    let restoreValue: boolean | number | string | null = null;
    if (control.kind === "toggle") {
      if (typeof control.value === "boolean") {
        restoreValue = control.value;
      } else if (control.value === 1 || control.value === 0) {
        restoreValue = typeof command.value === "boolean" ? control.value === 1 : control.value;
      }
      if (restoreValue === null) return null;
      const prevBool = restoreValue === true || restoreValue === 1;
      const nextBool = command.value === true || command.value === 1;
      if (prevBool === nextBool) return null;
    } else if (control.kind === "slider") {
      if (typeof control.value !== "number" || !Number.isFinite(control.value)) return null;
      if (typeof command.value === "number" && Math.abs(control.value - command.value) < 1e-9) {
        return null;
      }
      restoreValue = control.value;
    } else {
      if (
        (typeof control.value === "number" && Number.isFinite(control.value)) ||
        (typeof control.value === "string" && control.value !== "")
      ) {
        restoreValue = control.value;
      }
      if (restoreValue === null || restoreValue === command.value) return null;
    }

    return {
      dev,
      control,
      entityId: command.entityId,
      piid: command.piid,
      restoreValue,
      nextValue: command.value,
    };
  }
  return null;
}

export function buildReversibleFacetUndo(
  host: MenuMijiaWindowsApp,
  captured: CapturedReversibleFacet,
  customSummary?: string,
  habitReceipt?: HabitRecordingReceipt | null,
): UndoAction {
  const restoreCommand: DeviceCommand = {
    kind: "setMiotProperty",
    entityId: captured.entityId,
    piid: captured.piid,
    value: captured.restoreValue,
  };
  undoRestoreCommands.add(restoreCommand);
  const summary =
    customSummary ||
    t("已设置{name}的{control}为 {value}", {
      name: displayNameForDevice(host, captured.dev) || captured.dev.name,
      control: facetTitle(captured.control),
      value: facetValue({ ...captured.control, value: captured.nextValue }),
    });
  return {
    summary,
    steps: [{ deviceId: captured.dev.id, commands: [restoreCommand] }],
    expiresAtMs: Date.now() + UNDO_EXPIRY_MS,
    ...(habitReceipt ? { habitReceipt } : {}),
  };
}

export interface EchoReadBackTicket {
  readonly generation: number;
  readonly deviceId: string;
  readonly sourceRevision: number;
  readonly isCancelled: () => boolean;
  readonly cancel: () => void;
}

interface PendingEchoEntry {
  readonly generation: number;
  readonly cancel: () => void;
}

interface HostEchoReadBackState {
  sourceRevision: number;
  readonly generations: Map<string, number>;
  readonly activeTimers: Map<string, PendingEchoEntry>;
}

const echoReadBackStates = new WeakMap<object, HostEchoReadBackState>();

function ensureEchoState(host: MenuMijiaWindowsApp): HostEchoReadBackState {
  let state = echoReadBackStates.get(host);
  if (!state) {
    state = {
      sourceRevision: host.sourceRevision,
      generations: new Map(),
      activeTimers: new Map(),
    };
    echoReadBackStates.set(host, state);
    return state;
  }
  if (state.sourceRevision !== host.sourceRevision) {
    for (const entry of state.activeTimers.values()) {
      entry.cancel();
    }
    state.activeTimers.clear();
    state.generations.clear();
    state.sourceRevision = host.sourceRevision;
  }
  return state;
}

function invalidateEchoReadBackForDevice(host: MenuMijiaWindowsApp, deviceId: string): number {
  const state = ensureEchoState(host);
  const nextGen = (state.generations.get(deviceId) ?? 0) + 1;
  state.generations.set(deviceId, nextGen);
  const existing = state.activeTimers.get(deviceId);
  if (existing) {
    existing.cancel();
    state.activeTimers.delete(deviceId);
  }
  return nextGen;
}

export function cancelEchoReadBack(host: MenuMijiaWindowsApp, deviceId?: string): void {
  const state = ensureEchoState(host);
  if (deviceId !== undefined) {
    invalidateEchoReadBackForDevice(host, deviceId);
    return;
  }
  for (const [id, entry] of state.activeTimers.entries()) {
    state.generations.set(id, (state.generations.get(id) ?? 0) + 1);
    entry.cancel();
  }
  state.activeTimers.clear();
}

export function hasPendingEchoReadBack(host: MenuMijiaWindowsApp, deviceId: string): boolean {
  const state = ensureEchoState(host);
  return state.activeTimers.has(deviceId);
}

function primaryMiotEntityIdForDevice(
  dev: SmartDevice,
  facets?: readonly FacetControl[],
): string | null {
  const k = dev.kind;
  let candidate: string | null = null;
  switch (k.kind) {
    case "plug":
      candidate = k.switchEntityId;
      break;
    case "speaker":
      candidate = k.mediaEntityId;
      break;
    case "fridge":
      candidate = k.modeEntityId ?? k.fridgeTargetEntityId ?? k.freezerTargetEntityId;
      break;
    case "generic":
      candidate =
        k.powerControl?.target?.kind === "property" ? k.powerControl.target.entityId : null;
      break;
    case "sensor":
      candidate = null;
      break;
    default:
      candidate = k.entityId;
      break;
  }
  if (candidate && candidate.startsWith("miot:")) return candidate;
  for (const facet of facets ?? []) {
    if (facet.target?.kind === "property" && facet.target.entityId.startsWith("miot:")) {
      return facet.target.entityId;
    }
  }
  return null;
}

function buildSingleDeviceMiRecord(
  dev: SmartDevice,
  facets?: readonly FacetControl[],
): MiDeviceRecord {
  const splitMatch = /^(.+)\.s(\d+)$/.exec(dev.id);
  if (splitMatch) {
    return {
      did: dev.id,
      name: dev.name,
      model: dev.model,
      isOnline: dev.isOnline,
      specType: null,
      splitParentDid: splitMatch[1]!,
      splitSiid: Number(splitMatch[2]!),
    };
  }
  const primaryEntity = primaryMiotEntityIdForDevice(dev, facets);
  if (primaryEntity) {
    const addrMatch = /^miot:([^:]+):(\d+)$/.exec(primaryEntity);
    if (addrMatch) {
      const addrDid = addrMatch[1]!;
      const addrSiid = Number(addrMatch[2]!);
      if (addrDid !== dev.id && Number.isInteger(addrSiid) && addrSiid > 0) {
        return {
          did: dev.id,
          name: dev.name,
          model: dev.model,
          isOnline: dev.isOnline,
          specType: null,
          splitParentDid: addrDid,
          splitSiid: addrSiid,
        };
      }
    }
  }
  return {
    did: dev.id,
    name: dev.name,
    model: dev.model,
    isOnline: dev.isOnline,
    specType: null,
  };
}

function dedupeMiotPropKeys(keys: readonly MiotPropKey[]): MiotPropKey[] {
  const out: MiotPropKey[] = [];
  const seen = new Set<string>();
  for (const key of keys) {
    const id = `${key.did}.${key.siid}.${key.piid}`;
    if (seen.has(id)) continue;
    seen.add(id);
    out.push(key);
  }
  return out;
}

export function scheduleEchoReadBack(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  claim: DeviceWriteClaim | null,
  delayMs = ECHO_READ_BACK_DELAY_MS,
): EchoReadBackTicket {
  const state = ensureEchoState(host);
  const generation = invalidateEchoReadBackForDevice(host, deviceId);
  const capturedRevision = host.sourceRevision;
  const ownerWin = host.root?.ownerDocument?.defaultView ?? null;
  const useOwnerWinTimers =
    ownerWin !== null &&
    typeof ownerWin.setTimeout === "function" &&
    typeof ownerWin.clearTimeout === "function";

  let cancelled = false;
  let timer: unknown;
  let busyRetriesLeft = READ_BACK_BUSY_RETRY_LIMIT;

  const isStillCurrent = (): boolean =>
    !cancelled &&
    host.sourceRevision === capturedRevision &&
    isHostAttachedToActiveWindow(host) &&
    state.generations.get(deviceId) === generation &&
    stillOwnsWrite(host, claim);

  const arm = (waitMs: number, handler: () => void): void => {
    timer = useOwnerWinTimers
      ? ownerWin.setTimeout!(handler, waitMs)
      : globalThis.setTimeout(handler, waitMs);
    (timer as { unref?: () => void } | null)?.unref?.();
  };

  const cancel = (): void => {
    if (cancelled) return;
    cancelled = true;
    if (useOwnerWinTimers) {
      ownerWin.clearTimeout!(timer as number | undefined);
    } else {
      globalThis.clearTimeout(timer as ReturnType<typeof setTimeout>);
    }
    if (state.activeTimers.get(deviceId)?.generation === generation) {
      state.activeTimers.delete(deviceId);
    }
  };

  const executeSingleDeviceReadBack = async (): Promise<void> => {
    if (!isStillCurrent()) return;
    const mode = host.settings?.connectionMode;
    if (mode === "demo") return;

    const currentDev = host.devices.find((d) => d.id === deviceId);
    if (!currentDev) return;

    if (
      mode === "xiaomiCloud" &&
      host.settings?.miSession &&
      host.specResolver &&
      typeof host.specResolver.resolve === "function" &&
      host.transport
    ) {
      const session = host.settings.miSession;
      const record = buildSingleDeviceMiRecord(currentDev, host.deviceFacets?.[deviceId]);
      const spec = await host.specResolver.resolve(record);
      if (!isStillCurrent() || host.settings?.miSession !== session) return;

      const propKeys = dedupeMiotPropKeys([
        ...MiotSynthesizer.requiredProps(record, spec),
        ...MiotSynthesizer.facetProps(record, spec),
      ]);
      const client = new MiCloudClient(session, host.transport);
      const values =
        propKeys.length > 0 ? await client.getProps(propKeys) : new Map<string, unknown>();
      if (!isStillCurrent() || host.settings?.miSession !== session) return;

      const latestExisting = host.devices.find((d) => d.id === deviceId);
      if (!latestExisting) return;

      const rawRoomId = latestExisting.roomId.startsWith("room_")
        ? latestExisting.roomId.slice(5)
        : latestExisting.roomId;
      const syntheticRooms: MiRoom[] =
        latestExisting.roomId !== "other"
          ? [
              {
                id: rawRoomId,
                name: latestExisting.roomName,
                dids: [record.splitParentDid ?? record.did],
                ...(latestExisting.isSharedHome ? { isSharedHome: true as const } : {}),
              },
            ]
          : [];

      const singleHome = MiotSynthesizer.synthesize(
        [record],
        syntheticRooms,
        { [record.model]: spec },
        values,
      );
      const synthesized = singleHome.devices.find((d) => d.id === deviceId);
      if (!synthesized || !isStillCurrent()) return;

      const patchedKind: DeviceKind =
        latestExisting.kind.kind === "camera" && synthesized.kind.kind === "camera"
          ? {
              ...synthesized.kind,
              ...(latestExisting.kind.subdid !== undefined
                ? { subdid: latestExisting.kind.subdid }
                : {}),
              ...(latestExisting.kind.gatewayDid !== undefined
                ? { gatewayDid: latestExisting.kind.gatewayDid }
                : {}),
              ...(latestExisting.kind.gatewayModel !== undefined
                ? { gatewayModel: latestExisting.kind.gatewayModel }
                : {}),
              ...(latestExisting.kind.gatewayLocalIp !== undefined
                ? { gatewayLocalIp: latestExisting.kind.gatewayLocalIp }
                : {}),
            }
          : synthesized.kind;

      const patchedDevice: SmartDevice = {
        ...synthesized,
        kind: patchedKind,
        name: latestExisting.name,
        roomId: latestExisting.roomId,
        roomName: latestExisting.roomName,
        ...(latestExisting.isSharedHome ? { isSharedHome: true } : {}),
      };

      if (latestExisting.kind.kind !== "cover") {
        lockOptimistic(host, deviceId, 0);
      }

      const nextIncomingDevices = host.devices.map((d) =>
        d.id === deviceId ? patchedDevice : d,
      );
      const nextIncomingFacets: Record<string, readonly FacetControl[]> = {
        ...(host.deviceFacets ?? {}),
      };
      const updatedFacets = singleHome.deviceFacets?.[deviceId];
      if (updatedFacets && updatedFacets.length > 0) {
        nextIncomingFacets[deviceId] = updatedFacets;
      } else {
        delete nextIncomingFacets[deviceId];
      }

      const merged = mergeHomeSnapshotRespectingLocks(
        host,
        nextIncomingDevices,
        nextIncomingFacets,
      );
      host.devices = merged.devices;
      host.deviceFacets = merged.deviceFacets;
      pruneUnsupportedLightEffectsOnHost(host);
      if (typeof host.queueBackgroundRender === "function") {
        host.queueBackgroundRender();
      }
      return;
    }

    if (typeof host.refreshDevices === "function") {
      if (currentDev.kind.kind !== "cover") {
        lockOptimistic(host, deviceId, 0);
      }
      await host.refreshDevices(true);
    }
  };

  const onTimer = (): void => {
    if (!isStillCurrent()) {
      cancel();
      return;
    }
    const active = state.activeTimers.get(deviceId);
    if (!active || active.generation !== generation) return;
    if (host.settings?.connectionMode === "demo") {
      state.activeTimers.delete(deviceId);
      return;
    }
    if (host.isSyncingCloud === true && busyRetriesLeft > 0) {
      busyRetriesLeft -= 1;
      arm(READ_BACK_BUSY_RETRY_MS, onTimer);
      return;
    }
    state.activeTimers.delete(deviceId);
    void executeSingleDeviceReadBack().catch(() => {});
  };

  arm(delayMs, onTimer);
  state.activeTimers.set(deviceId, { generation, cancel });

  return {
    generation,
    deviceId,
    sourceRevision: capturedRevision,
    isCancelled: () => !isStillCurrent(),
    cancel,
  };
}

/**
 * A cover command shown before its send. A cover is write-only — macOS locks it before the send so
 * a pre-command parked snapshot cannot drop the commanded travel (`HomeStore+Controls.swift:
 * togglePrimary`), and again after success, which bumps the revision.
 */
interface CoverOptimisticWrite {
  readonly deviceId: string;
  /** The position the motor started from; a snapshot parked there is pre-command, not confirmation. */
  readonly originPosition: number | null;
  readonly priorDevice: SmartDevice;
  readonly priorFacets: readonly FacetControl[] | undefined;
  readonly priorLock: OptimisticLockSnapshot | null;
}

/** The cover card a motor (`setSelectOption`) or position (`setNumberValue`) command addresses. */
export function coverDeviceForCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): SmartDevice | null {
  if (command.kind !== "setSelectOption" && command.kind !== "setNumberValue") return null;
  const device = host.devices.find(
    (item) => item.kind.kind === "cover" && item.kind.entityId === command.entityId,
  );
  return device ?? null;
}

/**
 * Copies `source.kind` back onto `target.kind` without replacing the device object, so a view or a
 * caller still holding that row sees the restored values.
 */
function restoreKindInPlace(target: SmartDevice, source: SmartDevice): void {
  const kind = target.kind as unknown as Record<string, unknown>;
  const from = source.kind as unknown as Record<string, unknown>;
  for (const key of Object.keys(kind)) {
    if (!(key in from)) delete kind[key];
  }
  for (const [key, value] of Object.entries(from)) {
    kind[key] = typeof value === "object" && value !== null ? structuredClone(value) : value;
  }
}

/**
 * Shows a cover command before it goes out and locks the row for the length of its travel. The
 * previous row, facets and lock are kept so a refused send can put them back.
 */
function beginCoverOptimisticWrite(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): CoverOptimisticWrite | null {
  const device = coverDeviceForCommand(host, command);
  if (!device) return null;
  const facets = host.deviceFacets ?? {};
  const priorDevice = structuredClone(device);
  const priorFacets = facets[device.id] ? structuredClone(facets[device.id]!) : undefined;
  const priorLock = snapshotOptimisticLock(host, device.id);
  const originPosition = device.kind.kind === "cover" ? device.kind.positionPercent : null;
  applyCommandToDevices(host.devices, command, host.settings.connectionMode, facets);
  lockOptimistic(host, device.id, COVER_OPTIMISTIC_LOCK_DURATION_MS, {
    coverOriginPosition: originPosition,
    baselineDevice: priorDevice,
    baselineFacets: priorFacets,
  });
  return { deviceId: device.id, originPosition, priorDevice, priorFacets, priorLock };
}

/** Puts back a refused cover send: the row it displaced, and the lock it displaced. */
function revertCoverOptimisticWrite(host: MenuMijiaWindowsApp, write: CoverOptimisticWrite): void {
  const device = host.devices.find((item) => item.id === write.deviceId);
  if (device) restoreKindInPlace(device, write.priorDevice);
  restoreOptimisticLock(host, write.deviceId, write.priorLock);
}

/** True when no newer command has taken the row this command addresses. */
function stillOwnsWrite(host: MenuMijiaWindowsApp, claim: DeviceWriteClaim | null): boolean {
  return claim === null || ownsDeviceWrite(host, claim);
}

function isPureSpeakerTextCommand(dev: SmartDevice | null, command: DeviceCommand): boolean {
  if (!dev || dev.kind.kind !== "speaker" || command.kind !== "pressButton") return false;
  return (
    command.entityId === dev.kind.ttsActionId || command.entityId === dev.kind.directiveActionId
  );
}

export async function applyCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
  readBackPower = false,
): Promise<boolean> {
  const sourceRevision = host.sourceRevision;
  const originalCommand = command;
  const wasUndoRestore = undoRestoreCommands.has(originalCommand);
  const capturedFacet = wasUndoRestore
    ? null
    : captureReversibleFacetBeforeWrite(host, originalCommand);

  const targetDeviceId = deviceOwningEntityId(
    host.devices,
    host.deviceFacets ?? {},
    command.entityId,
  );
  if (targetDeviceId !== null) {
    invalidateEchoReadBackForDevice(host, targetDeviceId);
  }
  const targetDev =
    targetDeviceId !== null ? (host.devices.find((d) => d.id === targetDeviceId) ?? null) : null;
  const claim = targetDeviceId !== null ? claimDeviceWrite(host, targetDeviceId) : null;
  const coverWrite = beginCoverOptimisticWrite(host, command);

  try {
    if (host.settings.connectionMode === "homeAssistant") {
      command = homeAssistantCommand(command, host.devices, host.deviceFacets);
    }
    const readPower = await dispatchCloudCommand(host, command, readBackPower);
    if (typeof readPower === "boolean") command = withReadPower(command, readPower);
  } catch (error) {
    if (sourceRevision !== host.sourceRevision) return false;
    const revertedCover = Boolean(coverWrite && stillOwnsWrite(host, claim));
    if (coverWrite && revertedCover) revertCoverOptimisticWrite(host, coverWrite);

    const classified = classifyControlFailure(error, { isDeviceOnline: targetDev?.isOnline });
    if (classified?.isCancellation || isCancellationError(error)) {
      if (revertedCover) {
        renderHostImmediate(host);
      }
      return false;
    }

    if (
      classified?.kind === "sessionExpired" ||
      (error instanceof MiCloudError && error.kind === "sessionExpired")
    ) {
      host.miSessionExpired = true;
    }

    const devName = displayNameForDevice(host, targetDev);
    if (
      originalCommand.kind === "setLightEffect" &&
      targetDev?.kind.kind === "light" &&
      classified?.kind === "deviceRejected" &&
      classified.code === MIOT_PROPERTY_UNSUPPORTED_CODE
    ) {
      recordUnsupportedLightEffect(host, targetDev.id, originalCommand.effect);
      const effectLabel = localizeEffect(originalCommand.effect);
      host.replyBanner = {
        text: tr3(
          "{name}暂不支持「{effect}」灯效，已自动隐藏该选项",
          "{name}暫不支援「{effect}」燈效，已自動隱藏該選項",
          '{name} does not support the "{effect}" lighting effect; hidden automatically',
          { name: devName || targetDev.name, effect: effectLabel },
        ),
        source: t("控制失败"),
        isError: true,
      };
      renderHostImmediate(host);
      return false;
    }

    const rawFallback = error instanceof Error ? error.message : String(error);
    const formattedMessage =
      controlFailureUserMessage(error, {
        deviceName: devName,
        isDeviceOnline: targetDev?.isOnline,
        adjustment: isAdjustmentCommand(originalCommand),
        fallback: rawFallback,
      }) ?? rawFallback;
    host.replyBanner = {
      text: formattedMessage,
      source: t("控制失败"),
      isError: true,
    };
    renderHostImmediate(host);
    return false;
  }

  if (sourceRevision !== host.sourceRevision) return false;
  if (!stillOwnsWrite(host, claim)) return true;

  const facets = host.deviceFacets ?? {};
  const beforeById = new Map(
    host.devices.map((dev) => [
      dev.id,
      {
        snapshot: JSON.stringify([dev.kind, facets[dev.id] ?? null]),
        coverOrigin: dev.kind.kind === "cover" ? dev.kind.positionPercent : null,
        baselineDevice: structuredClone(dev),
        baselineFacets: facets[dev.id] ? structuredClone(facets[dev.id]) : undefined,
      },
    ]),
  );
  if (coverWrite) {
    beforeById.set(coverWrite.deviceId, {
      snapshot: JSON.stringify([coverWrite.priorDevice.kind, coverWrite.priorFacets ?? null]),
      coverOrigin: coverWrite.originPosition,
      baselineDevice: structuredClone(coverWrite.priorDevice),
      baselineFacets: coverWrite.priorFacets
        ? structuredClone(coverWrite.priorFacets)
        : undefined,
    });
  }
  host.localControlRevision += 1;
  if (coverWrite) {
    const device = host.devices.find((item) => item.id === coverWrite.deviceId);
    if (device) restoreKindInPlace(device, coverWrite.priorDevice);
  }
  const cameraChanges = applyCommandToDevices(
    host.devices,
    command,
    host.settings.connectionMode,
    facets,
  );
  if (originalCommand.kind === "setMiotProperty" && originalCommand !== command) {
    applyCommandToDevices(
      host.devices,
      originalCommand,
      host.settings.connectionMode,
      facets,
    );
  }
  if (host.settings.connectionMode === "homeAssistant") {
    applyHAExtendedCommandEffect(host.devices, command);
  }
  syncDirectCommandToFacets(facets, command, host.devices);
  pruneUnsupportedLightEffectsOnHost(host);

  for (const change of cameraChanges) {
    if (host.cameraLive?.activeLiveCameraId !== change.deviceId || host.cameraLive?.liveCameraHidden) {
      continue;
    }
    if (change.isOn) {
      host.cameraLive.reconnectCameraLiveView();
    } else {
      host.cameraLive.stopLiveTransport();
      host.cameraLive.liveCameraLoading = false;
    }
  }

  const modifiedIds = new Set<string>();
  for (const dev of host.devices) {
    const prior = beforeById.get(dev.id);
    const after = JSON.stringify([dev.kind, facets[dev.id] ?? null]);
    if (prior && after !== prior.snapshot) {
      modifiedIds.add(dev.id);
      lockOptimistic(
        host,
        dev.id,
        dev.kind.kind === "cover" ? COVER_OPTIMISTIC_LOCK_DURATION_MS : OPTIMISTIC_LOCK_DURATION_MS,
        {
          coverOriginPosition: prior.coverOrigin,
          baselineDevice: prior.baselineDevice,
          baselineFacets: prior.baselineFacets,
        },
      );
      scheduleDelayedReadBack(host, dev.id, READ_BACK_DELAY_MS);
      const idClaim = claim && claim.deviceId === dev.id ? claim : null;
      scheduleEchoReadBack(host, dev.id, idClaim, ECHO_READ_BACK_DELAY_MS);
    }
  }
  const isMomentaryTrigger =
    command.kind === "pressButton" ||
    (command.kind === "setSwitch" && command.entityId.startsWith("button."));
  if (modifiedIds.size === 0 && isMomentaryTrigger) {
    const baseEntityId = command.entityId.split("#")[0] ?? command.entityId;
    const ownerId = deviceOwningEntityId(host.devices, facets, baseEntityId);
    const ownerDev = ownerId ? (host.devices.find((d) => d.id === ownerId) ?? null) : null;
    if (ownerId && !isPureSpeakerTextCommand(ownerDev, originalCommand)) {
      scheduleDelayedReadBack(host, ownerId, READ_BACK_DELAY_MS);
      const idClaim = claim && claim.deviceId === ownerId ? claim : null;
      scheduleEchoReadBack(host, ownerId, idClaim, ECHO_READ_BACK_DELAY_MS);
    }
  }

  if (capturedFacet) {
    host.lastUndoAction = buildReversibleFacetUndo(host, capturedFacet);
  }

  return true;
}

/**
 * The card that owns a MIoT entity id, or null when none does. A card's own controls and every
 * 更多设置 row count: a plug's auxiliary control lives on a sibling service (#5), so the drawer
 * address must resolve to the card even though the card's main switch has another one.
 */
export function deviceOwningEntityId(
  devices: readonly SmartDevice[],
  facets: Readonly<Record<string, readonly FacetControl[]>>,
  entityId: string,
): string | null {
  const baseEntityId = entityId.split("#")[0] ?? entityId;
  const owner = devices.find((device) => {
    if (
      kindOwnsEntity(device.kind, entityId) ||
      (baseEntityId !== entityId && kindOwnsEntity(device.kind, baseEntityId))
    ) {
      return true;
    }
    return (facets[device.id] ?? []).some(
      (facet) => facet.target?.entityId === entityId || facet.target?.entityId === baseEntityId,
    );
  });
  return owner?.id ?? devices.find((device) => device.id === entityId || device.id === baseEntityId)?.id ?? null;
}

/** The entity ids a card's own controls address, before 更多设置 rows are considered. */
function kindOwnsEntity(kind: DeviceKind, entityId: string): boolean {
  switch (kind.kind) {
    case "plug":
      return kind.switchEntityId === entityId || kind.childLockEntityId === entityId;
    case "camera":
      return kind.entityId === entityId || kind.motionDetectionEntityId === entityId;
    case "fridge":
      return (
        kind.modeEntityId === entityId ||
        kind.fridgeTargetEntityId === entityId ||
        kind.freezerTargetEntityId === entityId
      );
    case "vacuum":
      return kind.entityId === entityId || kind.modeEntityId === entityId;
    case "speaker":
      return [
        kind.mediaEntityId,
        kind.muteSwitchEntityId,
        kind.sleepModeEntityId,
        kind.ttsActionId,
        kind.directiveActionId,
      ].includes(entityId);
    case "appliance":
      return [
        kind.entityId,
        kind.powerEntityId,
        kind.modeEntityId,
        kind.temperatureEntityId,
        kind.light?.entityId,
        kind.fanLevel?.entityId,
        kind.startAction?.entityId,
        kind.pauseAction?.entityId,
        kind.stopAction?.entityId,
      ].includes(entityId);
    case "generic":
      return kind.powerControl?.target?.entityId === entityId;
    case "sensor":
      return false;
    default:
      return kind.entityId === entityId;
  }
}

export async function dispatchCloudCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
  readBackPower = false,
): Promise<boolean | null> {
  const sourceRevision = host.sourceRevision;
  const provider = homeProviderFor(host);
  try {
    return await provider.execute(command, {
      readBackPower,
      beforeSend: () => {
        if (sourceRevision !== host.sourceRevision) throw new Error("Connection source changed");
      },
    });
  } catch (error) {
    if (!(error instanceof PowerReadBackError)) throw error;
    if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
    throw error.reason;
  }
}

/** The provider for the backend the panel is connected to right now (ADR-0020). */
export function homeProviderFor(host: MenuMijiaWindowsApp): HomeProvider {
  if (host.settings.connectionMode === "demo") return new DemoHomeProvider();
  if (host.settings.connectionMode === "homeAssistant") {
    return new HomeAssistantProvider(
      new HomeAssistantClient(host.settings.haBaseURL, host.settings.haToken),
      host.endpointSubmission,
    );
  }
  if (!host.settings.miSession) throw new Error(t("请先扫码登录米家"));
  return new MiCloudProvider({
    client: new MiCloudClient(host.settings.miSession, host.transport),
    specResolver: host.specResolver,
    deviceForEntity: (entityId) => {
      const deviceId = deviceOwningEntityId(host.devices, host.deviceFacets, entityId);
      return host.devices.find((device) => device.id === deviceId);
    },
  });
}

export function markCloudValuesStale(host: MenuMijiaWindowsApp): void {
  if (host.settings.connectionMode === "xiaomiCloud" && host.devices.length > 0) {
    host.cloudValuesStale = true;
  }
}

export function markCloudValuesFresh(host: MenuMijiaWindowsApp): void {
  if (host.settings.connectionMode === "xiaomiCloud") host.cloudValuesStale = false;
}
