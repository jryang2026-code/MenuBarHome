import { MiIOUnconfirmedWriteError } from "../core/miCloud/localMiIO.js";
import { MiCloudChannelWriteBatcher } from "../core/miCloud/channelWriteBatcher.js";
import { parseMiotAddress } from "../core/miCloud/spec.js";
import { getCachedXiaomiTopology, miSessionFingerprint } from "../core/pollingPolicy.js";
import { miSceneAccount } from "../core/miCloud/scenes.js";
import { requestMiSceneConfirmation } from "./sceneConfirmation.js";
import { isWorkstationLockBlockingControl } from "./transport.js";
import { recordWorkstationLockBlock } from "./speechGuard.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoAction } from "./appTypes.js";
import {
  ManualControlPolicy,
  isLocalNetworkURL,
  type HabitRecordingReceipt,
} from "../core/assistant.js";
import { t, tr3 } from "../core/i18n.js";
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
  type HomeCommandProvider,
} from "../core/homeProvider.js";
import {
  DualSourceHomeProvider,
  commandTargetBackend,
} from "../core/dualSourceProvider.js";
import { MultiAccountMiCloudProvider, MiAccountScope, miAccountId } from "../core/miAccountsStore.js";
import { appDiagnosticsLog } from "../core/diagnosticsAndScanner.js";
import {
  buildHostCapabilityContext,
  getHostDualSourceState,
  getHostMiAccountsState,
  hasMultipleMiAccountsForHost,
  isDualSourceEnabled,
  isHostHaEnabled,
  isHostMiSessionEnabled,
  resolveEnabledMiAccountsForHost,
} from "./cloudRefresh.js";
import {
  CapabilityGateError,
  evaluateDeviceEntityWriteGate,
  evaluateDeviceEntityWriteGateVerdict,
  haConnectionScope,
  isCapabilityGateError,
  miAccountScope,
} from "../core/miAccountControl.js";
import { isHaBlockedRequestError } from "../core/haTransportGate.js";
import {
  MiCloudClient,
  MiCloudError,
  MiotSynthesizer,
  type MiDeviceRecord,
  type MiRoom,
  type MiSession,
  type MiotPropKey,
} from "../core/miCloudClient.js";
import { facetTitle, facetValue } from "../core/miotFacetText.js";
import type {
  DeviceCommand,
  DeviceIntent,
  DeviceKind,
  FacetControl,
  HomeScene,
  SmartDevice,
} from "../core/models.js";
import { applyCommandToDevices } from "../core/commandEffects.js";
import { GROUP_COVER_IGNORE_WINDOW_MS } from "../core/roomAutoGroup.js";
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
import { localizeEffect, withAliases } from "./panelPrefs.js";

export const MIOT_PROPERTY_UNSUPPORTED_CODE = -704002000;

export const ECHO_READ_BACK_DELAY_MS = 2_200;

export const SLIDER_LAN_MIN_INTERVAL_MS = 100;
export const SLIDER_HIGH_RISK_DEBOUNCE_MS = 180;

const UNDO_EXPIRY_MS = 10 * 60 * 1000;

export interface SliderWriteRequest {
  readonly slotKey: string;
  readonly device: SmartDevice;
  readonly command: DeviceCommand;
  readonly summary: string;
  readonly intent?: DeviceIntent;
  readonly isLiveInput?: boolean;
  readonly isHighRisk?: boolean;
  readonly debounceHighRisk?: boolean;
  readonly execute?: () => Promise<void>;
  readonly onFailure?: () => void;
  /** Re-checked against live state right before a queued write is sent; a message refuses it. */
  readonly revalidateBeforeSend?: () => string | null;
}

interface SliderMailboxTiming {
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  lanIntervalMs: number;
  highRiskDebounceMs: number;
}

interface SliderMailboxSlot {
  inFlight: boolean;
  pending: SliderWriteRequest | null;
  debounceToken: number;
  debounceTimer: { cancel(): void } | null;
  drainPromise: Promise<void> | null;
  startedCount: number;
}

interface SliderMailboxHostState {
  sourceRevision: number;
  homeRevision: number;
  readonly slots: Map<string, SliderMailboxSlot>;
  timing: SliderMailboxTiming;
}

interface HostChannelBatcherState {
  sourceRevision: number;
  homeRevision: number;
  batcher: MiCloudChannelWriteBatcher;
  custom: boolean;
}

const sliderMailboxByHost = new WeakMap<object, SliderMailboxHostState>();
const channelBatcherByHost = new WeakMap<object, HostChannelBatcherState>();

const defaultMailboxSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    const timer = globalThis.setTimeout(resolve, ms);
    (timer as { unref?: () => void } | null)?.unref?.();
  });

function clearSliderMailboxSlots(state: SliderMailboxHostState): void {
  for (const slot of state.slots.values()) {
    slot.pending = null;
    slot.debounceToken += 1;
    slot.debounceTimer?.cancel();
    slot.debounceTimer = null;
  }
  state.slots.clear();
}

function ensureSliderMailboxState(host: MenuMijiaWindowsApp): SliderMailboxHostState {
  let state = sliderMailboxByHost.get(host);
  if (!state) {
    state = {
      sourceRevision: host.sourceRevision,
      homeRevision: host.homeRevision,
      slots: new Map(),
      timing: { now: () => Date.now(), sleep: defaultMailboxSleep, lanIntervalMs: SLIDER_LAN_MIN_INTERVAL_MS, highRiskDebounceMs: SLIDER_HIGH_RISK_DEBOUNCE_MS },
    };
    sliderMailboxByHost.set(host, state);
    return state;
  }
  if (state.sourceRevision !== host.sourceRevision || state.homeRevision !== host.homeRevision) {
    clearSliderMailboxSlots(state);
    state.sourceRevision = host.sourceRevision;
    state.homeRevision = host.homeRevision;
  }
  return state;
}

export function setSliderMailboxTimingForTesting(host: MenuMijiaWindowsApp, overrides: Partial<SliderMailboxTiming>): void {
  const state = ensureSliderMailboxState(host);
  state.timing = { ...state.timing, ...overrides };
}

export function getSliderMailboxStatsForTesting(host: MenuMijiaWindowsApp, slotKey: string) {
  const slot = ensureSliderMailboxState(host).slots.get(slotKey);
  return { inFlight: slot?.inFlight ?? false, hasPending: slot?.pending != null, startedCount: slot?.startedCount ?? 0 };
}

export async function waitForSliderMailboxIdle(host: MenuMijiaWindowsApp, slotKey?: string): Promise<void> {
  const state = ensureSliderMailboxState(host);
  while (true) {
    const promises = slotKey !== undefined
      ? [state.slots.get(slotKey)?.drainPromise].filter((p): p is Promise<void> => Boolean(p))
      : [...state.slots.values()].map((s) => s.drainPromise).filter((p): p is Promise<void> => Boolean(p));
    if (promises.length === 0) return;
    await Promise.allSettled(promises);
  }
}

export function getChannelWriteBatcher(host: MenuMijiaWindowsApp): MiCloudChannelWriteBatcher {
  let entry = channelBatcherByHost.get(host);
  if (!entry) {
    entry = { sourceRevision: host.sourceRevision, homeRevision: host.homeRevision, batcher: new MiCloudChannelWriteBatcher(), custom: false };
    channelBatcherByHost.set(host, entry);
    return entry.batcher;
  }
  if (entry.sourceRevision !== host.sourceRevision || entry.homeRevision !== host.homeRevision) {
    entry.batcher.cancelAll();
    if (!entry.custom) entry.batcher = new MiCloudChannelWriteBatcher();
    entry.sourceRevision = host.sourceRevision;
    entry.homeRevision = host.homeRevision;
  }
  return entry.batcher;
}

export function setChannelWriteBatcherForTesting(host: MenuMijiaWindowsApp, batcher: MiCloudChannelWriteBatcher): void {
  channelBatcherByHost.set(host, { sourceRevision: host.sourceRevision, homeRevision: host.homeRevision, batcher, custom: true });
}

export function cancelPendingControlWrites(host: MenuMijiaWindowsApp): void {
  const mailbox = sliderMailboxByHost.get(host);
  if (mailbox) {
    clearSliderMailboxSlots(mailbox);
    mailbox.sourceRevision = host.sourceRevision;
    mailbox.homeRevision = host.homeRevision;
  }
  const batcherEntry = channelBatcherByHost.get(host);
  if (batcherEntry) {
    batcherEntry.batcher.cancelAll();
    batcherEntry.sourceRevision = host.sourceRevision;
    batcherEntry.homeRevision = host.homeRevision;
  }
}

export function sliderIsHighRisk(host: MenuMijiaWindowsApp, device: SmartDevice): boolean {
  const aliased = withAliases(host.layout, [device]);
  return (
    ManualControlPolicy.requiresConfirmation({ targetId: device.id, operation: { kind: "power", isOn: true } }, aliased) ||
    ManualControlPolicy.requiresConfirmation({ targetId: device.id, operation: { kind: "power", isOn: false } }, aliased)
  );
}

export function sliderUsesLAN(host: MenuMijiaWindowsApp, command: DeviceCommand, device?: SmartDevice): boolean {
  const mode = effectiveCommandBackend(host, command);
  if (mode === "demo") return false;
  if (mode === "homeAssistant") return isLocalNetworkURL(host.settings.haBaseURL ?? "");
  const parsed = parseMiotAddress(command.entityId);
  if (!parsed) return false;
  const multiState = getHostMiAccountsState(host);
  const enabledAccounts = resolveEnabledMiAccountsForHost(host, host.miAccountsOverride ?? multiState?.accounts ?? []);
  if (hasMultipleMiAccountsForHost(host) && enabledAccounts.length > 0) {
    const ownerId = multiState?.merged?.deviceOwners[parsed.did]?.[0] ?? device?.accountId ?? null;
    const owner = ownerId ? enabledAccounts.find((a) => a.id === ownerId) : enabledAccounts[0];
    if (owner) return xiaomiClientForHost(host, owner.session).hasLANRoute(parsed.did);
  }
  const session = host.settings.miSession ?? enabledAccounts[0]?.session ?? null;
  return Boolean(session && isHostMiSessionEnabled(host, session) && xiaomiClientForHost(host, session).hasLANRoute(parsed.did));
}

function startSliderDrain(
  host: MenuMijiaWindowsApp,
  state: SliderMailboxHostState,
  slotKey: string,
  slot: SliderMailboxSlot,
  isLan: boolean,
): Promise<void> {
  slot.inFlight = true;
  const capturedSource = state.sourceRevision;
  const capturedHome = state.homeRevision;
  const isCurrent = () => host.sourceRevision === capturedSource && host.homeRevision === capturedHome;
  const run = (async () => {
    try {
      while (slot.pending !== null) {
        if (!isCurrent()) { slot.pending = null; break; }
        const current = slot.pending;
        slot.pending = null;
        const refusal = current.revalidateBeforeSend?.() ?? null;
        if (refusal !== null) {
          host.replyBanner = { text: refusal, source: t("需要确认"), isError: true };
          host.render();
          current.onFailure?.();
          continue;
        }
        const startMs = state.timing.now();
        slot.startedCount += 1;
        const seqBefore = peekDeviceWriteSeq(host, current.device.id);
        const prevBanner = host.replyBanner;
        try {
          await (current.execute
            ? current.execute()
            : host.executeSingleCommand(current.device, current.command, current.summary, current.intent, false, {
                revalidateBeforeSend: current.revalidateBeforeSend,
              }));
          const failed =
            (host.replyBanner !== prevBanner && host.replyBanner?.isError === true) ||
            (!current.execute && peekDeviceWriteSeq(host, current.device.id) === seqBefore);
          if (failed) current.onFailure?.();
        } catch {
          current.onFailure?.();
        }
        if (!isCurrent()) { slot.pending = null; break; }
        if (isLan) {
          const remaining = state.timing.lanIntervalMs - Math.max(0, state.timing.now() - startMs);
          if (remaining > 0) await state.timing.sleep(remaining);
        }
      }
    } finally {
      slot.inFlight = false;
      slot.drainPromise = null;
      if (slot.pending !== null && isCurrent()) void startSliderDrain(host, state, slotKey, slot, isLan);
      else if (slot.pending === null && slot.debounceTimer === null) state.slots.delete(slotKey);
    }
  })();
  slot.drainPromise = run;
  return run;
}

/** Single-slot mailbox per slider field (#506): LAN leading+100ms, cloud single-flight, high-risk no leading edge. */
export function submitSliderWrite(host: MenuMijiaWindowsApp, request: SliderWriteRequest): Promise<void> {
  const state = ensureSliderMailboxState(host);
  const hazardous = request.isHighRisk ?? sliderIsHighRisk(host, request.device);
  const lan = !hazardous && sliderUsesLAN(host, request.command, request.device);
  if (hazardous && request.isLiveInput && !request.debounceHighRisk) return Promise.resolve();

  let slot = state.slots.get(request.slotKey);
  if (!slot) {
    slot = { inFlight: false, pending: null, debounceToken: 0, debounceTimer: null, drainPromise: null, startedCount: 0 };
    state.slots.set(request.slotKey, slot);
  }
  slot.pending = request;

  if (hazardous && request.debounceHighRisk) {
    slot.debounceTimer?.cancel();
    const token = ++slot.debounceToken;
    const { sourceRevision: capturedSource, homeRevision: capturedHome } = state;
    let cancelled = false;
    slot.debounceTimer = { cancel: () => { cancelled = true; } };
    const waitAndDrain = (async () => {
      await state.timing.sleep(state.timing.highRiskDebounceMs);
      if (cancelled || slot.debounceToken !== token || host.sourceRevision !== capturedSource || host.homeRevision !== capturedHome) return;
      slot.debounceTimer = null;
      if (!slot.inFlight && slot.pending !== null) await startSliderDrain(host, state, request.slotKey, slot, false);
    })();
    slot.drainPromise = waitAndDrain;
    return waitAndDrain;
  }

  return slot.inFlight ? (slot.drainPromise ?? Promise.resolve()) : startSliderDrain(host, state, request.slotKey, slot, lan);
}

interface ApplyCommandOptions {
  readonly roomGroupCover?: boolean;
  /** Set only for a scheduled timer fired by its own tick; every other write stays lock-guarded at send time. */
  readonly allowWhileLocked?: boolean;
  /** Re-checked synchronously right before the request leaves; a message refuses the write. */
  readonly revalidateBeforeSend?: () => string | null;
}

/** A write refused by its live-state re-check right before the send; carries the user-facing reason. */
class BeforeSendRefusalError extends Error {}

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
): (
  command: DeviceCommand,
  readBackPower?: boolean,
  userInitiated?: boolean,
  options?: ApplyCommandOptions,
) => Promise<boolean> {
  const custom = customApplyCommandByHost.get(host);
  if (!custom) {
    return (command, readBackPower, userInitiated, options) => applyCommand(host, command, readBackPower, userInitiated, options);
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
    case "setHumidity":
    case "setNumberValue":
    case "mediaSetVolume":
    case "mediaSelectSource":
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

function recordUnsupportedLightEffect(
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

interface CapturedReversibleFacet {
  readonly dev: SmartDevice;
  readonly control: FacetControl;
  readonly entityId: string;
  readonly piid: number;
  readonly restoreValue: boolean | number | string;
  readonly nextValue: unknown;
}

const undoRestoreCommands = new WeakSet<DeviceCommand>();

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

interface EchoReadBackTicket {
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
    case "tv":
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

    const dualActive = isDualSourceEnabled(host);
    const dualBackend = dualActive
      ? (getHostDualSourceState(host)?.deviceBackends[deviceId] ?? "xiaomiCloud")
      : null;
    const isXiaomiDevice = dualActive ? dualBackend === "xiaomiCloud" : mode === "xiaomiCloud";
    const multiState = getHostMiAccountsState(host);
    const accounts = host.miAccountsOverride ?? multiState?.accounts ?? [];
    const mappedAccountId =
      multiState?.merged?.deviceOwners[deviceId]?.[0] ??
      currentDev.accountId ??
      null;
    const matchedAccount = mappedAccountId
      ? accounts.find((a) => a.id === mappedAccountId)
      : accounts[0];
    const resolvedSession = matchedAccount?.session ?? host.settings?.miSession ?? null;

    if (isXiaomiDevice && (!resolvedSession || !isHostMiSessionEnabled(host, resolvedSession))) {
      return;
    }

    if (
      isXiaomiDevice &&
      resolvedSession &&
      host.specResolver &&
      typeof host.specResolver.resolve === "function" &&
      typeof host.transport === "function"
    ) {
      const session = resolvedSession;
      const record = buildSingleDeviceMiRecord(currentDev, host.deviceFacets?.[deviceId]);
      const spec = await host.specResolver.resolve(record);
      if (!isStillCurrent() || !isHostMiSessionEnabled(host, session)) return;

      const propKeys = dedupeMiotPropKeys([
        ...MiotSynthesizer.requiredProps(record, spec),
        ...MiotSynthesizer.facetProps(record, spec),
      ]);
      const client = xiaomiClientForHost(host, session);
      const { pollCapturedEpoch } = host.sourceEpoch.capture();
      const values =
        propKeys.length > 0 ? await client.getProps(propKeys) : new Map<string, unknown>();
      if (!isStillCurrent() || !isHostMiSessionEnabled(host, session)) return;

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
        Date.now(),
        new Set([deviceId]),
        pollCapturedEpoch,
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

function coverDeviceForCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): SmartDevice | null {
  if (command.kind !== "setSelectOption" && command.kind !== "setNumberValue") return null;
  const device = host.devices.find(
    (item) => item.kind.kind === "cover" && item.kind.entityId === command.entityId,
  );
  return device ?? null;
}

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

export function effectiveCommandBackend(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): "demo" | "xiaomiCloud" | "homeAssistant" {
  if (host.settings.connectionMode === "demo") return "demo";
  if (isDualSourceEnabled(host)) {
    return commandTargetBackend(command);
  }
  return host.settings.connectionMode;
}

function beginCoverOptimisticWrite(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
  roomGroupCover: boolean,
): CoverOptimisticWrite | null {
  const device = coverDeviceForCommand(host, command);
  if (!device) return null;
  const facets = host.deviceFacets ?? {};
  const priorDevice = structuredClone(device);
  const priorFacets = facets[device.id] ? structuredClone(facets[device.id]!) : undefined;
  const priorLock = snapshotOptimisticLock(host, device.id);
  const originPosition = device.kind.kind === "cover" ? device.kind.positionPercent : null;
  applyCommandToDevices(
    host.devices,
    command,
    effectiveCommandBackend(host, command),
    facets,
  );
  host.sourceEpoch.advance("localWrite");
  lockOptimistic(host, device.id, roomGroupCover ? GROUP_COVER_IGNORE_WINDOW_MS : COVER_OPTIMISTIC_LOCK_DURATION_MS, {
    ignoreCoverMovement: roomGroupCover || undefined,
    writeEpoch: host.sourceEpoch.capture().pollCapturedEpoch,
    coverOriginPosition: originPosition,
    baselineDevice: priorDevice,
    baselineFacets: priorFacets,
  });
  return { deviceId: device.id, originPosition, priorDevice, priorFacets, priorLock };
}

function revertCoverOptimisticWrite(host: MenuMijiaWindowsApp, write: CoverOptimisticWrite): void {
  const device = host.devices.find((item) => item.id === write.deviceId);
  if (device) restoreKindInPlace(device, write.priorDevice);
  restoreOptimisticLock(host, write.deviceId, write.priorLock);
}

function stillOwnsWrite(host: MenuMijiaWindowsApp, claim: DeviceWriteClaim | null): boolean {
  return claim === null || ownsDeviceWrite(host, claim);
}

function isPureSpeakerTextCommand(dev: SmartDevice | null, command: DeviceCommand): boolean {
  if (!dev || dev.kind.kind !== "speaker" || command.kind !== "pressButton") return false;
  return (
    command.entityId === dev.kind.ttsActionId || command.entityId === dev.kind.directiveActionId
  );
}

/**
 * A Mi cloud scene id names its cloud home. Running it from another home would drive rooms the
 * user is not looking at, so a selected home only accepts scenes that belong to it. With no home
 * selected ("all homes") every scene of the snapshot stays runnable.
 */
function miSceneBelongsToSelectedHome(host: MenuMijiaWindowsApp, scene: HomeScene): boolean {
  const selected = host.settings.selectedHomeId;
  const homeId = scene.miScene?.homeId;
  if (!selected || !homeId) return true;
  const rawSelected = MiAccountScope.owner(selected) === null
    ? selected
    : MiAccountScope.localId(selected);
  return homeId === rawSelected;
}

export async function applyCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
  readBackPower = false,
  userInitiated = true,
  options?: ApplyCommandOptions,
): Promise<boolean> {
  const sourceRevision = host.sourceRevision;
  const homeRevision = host.homeRevision;
  const allowWhileLocked = options?.allowWhileLocked === true;
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
  if (host.settings?.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const gateMsg = evaluateDeviceEntityWriteGate({
      targetKind: command.kind === "activateScene" ? "scene" : "device",
      targetIdOrEntityId: command.entityId,
      resolvedActiveDeviceId: targetDeviceId,
      context: buildHostCapabilityContext(host),
      rejectUnknown: true,
      languagePreference: host.settings?.interfaceLanguage,
    });
    if (gateMsg !== null) {
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      renderHostImmediate(host);
      return false;
    }
  }
  if (command.kind === "activateScene" && miSceneAccount(command.entityId) !== null) {
    const scene = host.scenes.find((row) => row.entityId === command.entityId && row.miScene);
    if (
      !scene ||
      !miSceneBelongsToSelectedHome(host, scene) ||
      sourceRevision !== host.sourceRevision ||
      homeRevision !== host.homeRevision
    ) {
      return false;
    }
    if (await isWorkstationLockBlockingControl(host)) {
      recordWorkstationLockBlock(host);
      return false;
    }
    if (!(await requestMiSceneConfirmation(host, scene, command))) {
      // Cancel, the 8 s expiry and a home/source switch behind the prompt are deliberate
      // cancellations. The batch runner recognizes this banner and restores the previous one,
      // so a declined scene is not reported as a failed write.
      host.replyBanner = {
        text: tr3("操作已取消", "操作已取消", "Action cancelled"),
        source: t("已取消"),
        isError: true,
      };
      return false;
    }
    if (await isWorkstationLockBlockingControl(host)) {
      recordWorkstationLockBlock(host);
      return false;
    }
    if (sourceRevision !== host.sourceRevision ||
        homeRevision !== host.homeRevision || !miSceneBelongsToSelectedHome(host, scene) ||
        !host.scenes.some((row) => row.entityId === scene.entityId && row.miScene &&
          row.miScene.ownerUid === scene.miScene?.ownerUid)) return false;
  }
  if (targetDeviceId !== null) {
    invalidateEchoReadBackForDevice(host, targetDeviceId);
  }
  const targetDev =
    targetDeviceId !== null ? (host.devices.find((d) => d.id === targetDeviceId) ?? null) : null;
  if (targetDev && !targetDev.isOnline) {
    const text = controlFailureUserMessage(null, {
      deviceName: displayNameForDevice(host, targetDev),
      isDeviceOnline: false,
      languagePreference: host.settings.interfaceLanguage,
    });
    host.replyBanner = { text: text ?? t("控制失败"), source: t("控制失败"), isError: true };
    renderHostImmediate(host);
    return false;
  }
  const claim = targetDeviceId !== null ? claimDeviceWrite(host, targetDeviceId) : null;
  const roomGroupCover = options?.roomGroupCover === true;
  const coverWrite = beginCoverOptimisticWrite(host, command, roomGroupCover);
  const effectiveMode = effectiveCommandBackend(host, command);

  try {
    if (effectiveMode === "homeAssistant") {
      command = homeAssistantCommand(command, host.devices, host.deviceFacets);
    }
    const readPower = await dispatchCloudCommand(
      host, command, readBackPower, originalCommand.entityId, userInitiated, allowWhileLocked,
      options?.revalidateBeforeSend,
    );
    if (typeof readPower === "boolean") command = withReadPower(command, readPower);
  } catch (error) {
    if (sourceRevision !== host.sourceRevision) return false;
    const revertedCover = Boolean(coverWrite && stillOwnsWrite(host, claim));
    if (coverWrite && revertedCover) revertCoverOptimisticWrite(host, coverWrite);
    if (error instanceof BeforeSendRefusalError) {
      host.replyBanner = { text: error.message, source: t("需要确认"), isError: true };
      host.render();
      return false;
    }
    if (error instanceof MiIOUnconfirmedWriteError && targetDeviceId !== null && stillOwnsWrite(host, claim)) {
      scheduleDelayedReadBack(host, targetDeviceId, READ_BACK_DELAY_MS);
    }

    if (isCapabilityGateError(error) || isHaBlockedRequestError(error)) {
      const gateText =
        controlFailureUserMessage(error, {
          languagePreference: host.settings?.interfaceLanguage,
        }) ?? (error instanceof Error ? error.message : String(error));
      host.replyBanner = {
        text: gateText,
        source: t("控制失败"),
        isError: true,
      };
      renderHostImmediate(host);
      return false;
    }

    const classified = classifyControlFailure(error, { isDeviceOnline: targetDev?.isOnline });
    if (classified?.isCancellation || isCancellationError(error)) {
      if (revertedCover) {
        renderHostImmediate(host);
      }
      return false;
    }

    appDiagnosticsLog.record({
      error,
      category:
        classified?.kind === "sessionExpired" ||
        (error instanceof MiCloudError && error.kind === "sessionExpired")
          ? "auth"
          : "command",
    });

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
        languagePreference: host.settings?.interfaceLanguage,
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
  host.sourceEpoch.advance("localWrite");
  const writeEpoch = host.sourceEpoch.capture().pollCapturedEpoch;
  if (coverWrite) {
    const device = host.devices.find((item) => item.id === coverWrite.deviceId);
    if (device) restoreKindInPlace(device, coverWrite.priorDevice);
  }
  const cameraChanges = applyCommandToDevices(
    host.devices,
    command,
    effectiveMode,
    facets,
  );
  if (originalCommand.kind === "setMiotProperty" && originalCommand !== command) {
    applyCommandToDevices(
      host.devices,
      originalCommand,
      effectiveMode,
      facets,
    );
  }
  if (effectiveMode === "homeAssistant") {
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
      const isGroupCover = roomGroupCover && coverWrite?.deviceId === dev.id;
      const duration = isGroupCover ? GROUP_COVER_IGNORE_WINDOW_MS
        : dev.kind.kind === "cover" ? COVER_OPTIMISTIC_LOCK_DURATION_MS : OPTIMISTIC_LOCK_DURATION_MS;
      lockOptimistic(
        host,
        dev.id,
        duration,
        {
          writeEpoch,
          coverOriginPosition: prior.coverOrigin,
          ignoreCoverMovement: isGroupCover || undefined,
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
    case "tv":
      return [
        kind.mediaEntityId,
        kind.muteSwitchEntityId,
        kind.turnOnButtonId,
        kind.powerOnActionId,
        kind.powerOffActionId,
        kind.remoteEntityId,
        ...Object.values(kind.miotRemoteActions ?? {}),
      ].includes(entityId);
    case "humidifier":
      return kind.entityId === entityId;
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

async function dispatchCloudCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
  readBackPower: boolean,
  originalEntityId: string,
  userInitiated: boolean,
  allowWhileLocked: boolean,
  revalidateBeforeSend?: () => string | null,
): Promise<boolean | null> {
  const sourceRevision = host.sourceRevision;
  const homeRevision = host.homeRevision;
  const isMiotChannelSwitch =
    !readBackPower && command.kind === "setSwitch" && parseMiotAddress(command.entityId) !== null;
  const provider = homeProviderFor(host);
  const beforeSend = () => {
    if (sourceRevision !== host.sourceRevision || homeRevision !== host.homeRevision) {
      throw new Error("Connection source changed");
    }
    if (host.settings?.connectionMode !== "demo" || isDualSourceEnabled(host)) {
      const currentTargetId = deviceOwningEntityId(
        host.devices,
        host.deviceFacets ?? {},
        originalEntityId,
      );
      const gateFailure = evaluateDeviceEntityWriteGateVerdict({
        targetKind: command.kind === "activateScene" ? "scene" : "device",
        targetIdOrEntityId: originalEntityId,
        resolvedActiveDeviceId: currentTargetId,
        context: buildHostCapabilityContext(host),
        rejectUnknown: true,
        languagePreference: host.settings?.interfaceLanguage,
      });
      if (gateFailure !== null) {
        throw new CapabilityGateError(gateFailure.reason, host.settings?.interfaceLanguage);
      }
    }
    const refusal = revalidateBeforeSend?.() ?? null;
    if (refusal !== null) throw new BeforeSendRefusalError(refusal);
  };
  // The lock can engage while the command waits (spec lookup, HA connection, LAN attempt), so it
  // is re-checked after those waits and right before the first request; a refusal is recorded so
  // a manual run of a missed timer goes back to the missed list.
  const lockedOut = async (): Promise<boolean> => {
    if (allowWhileLocked || !(await isWorkstationLockBlockingControl(host))) return false;
    recordWorkstationLockBlock(host);
    return true;
  };
  const lockGate = async (): Promise<void> => {
    if (await lockedOut()) {
      throw new DOMException("Control blocked while workstation is locked", "AbortError");
    }
  };
  const stillAllowed = isMiotChannelSwitch
    ? async (): Promise<boolean> => {
        if (sourceRevision !== host.sourceRevision || homeRevision !== host.homeRevision) {
          return false;
        }
        if (await lockedOut()) return false;
        if (host.miSessionExpired && effectiveCommandBackend(host, command) === "xiaomiCloud") {
          return false;
        }
        try {
          beforeSend();
          return true;
        } catch {
          return false;
        }
      }
    : undefined;
  try {
    return await provider.execute(command, {
      readBackPower,
      userInitiated,
      beforeSend,
      stillAllowed,
      // Attached only while the lock guard is on, so an unguarded send gains no extra awaits.
      ...(!allowWhileLocked && host.settings?.blockControlWhileLocked ? { beforeSendAsync: lockGate } : {}),
      beforeFallback: async () => {
        await lockGate();
        beforeSend();
      },
    });
  } catch (error) {
    if (!(error instanceof PowerReadBackError)) throw error;
    if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
    throw error.reason;
  }
}

function xiaomiClientForHost(host: MenuMijiaWindowsApp, session: MiSession): MiCloudClient {
  const client = new MiCloudClient(session, host.transport);
  const fingerprint = miSessionFingerprint(session);
  const child = getHostMiAccountsState(host)?.children[miAccountId(session)];
  if (child?.status.kind === "connected" && miSessionFingerprint(child.account.session) === fingerprint) {
    return client.withLAN(child.rawDevices, child.allRooms);
  }
  const cached = getCachedXiaomiTopology(host);
  if (cached?.sessionFingerprint === fingerprint && cached.sourceRevision === host.sourceRevision &&
      cached.selectedHomeId === (host.settings.selectedHomeId ?? null)) {
    return client.withLAN(cached.rawDevices, cached.allRooms);
  }
  return client;
}

function buildXiaomiHomeProvider(host: MenuMijiaWindowsApp): HomeCommandProvider {
  const deviceForEntity = (entityId: string): SmartDevice | undefined => {
    const deviceId = deviceOwningEntityId(host.devices, host.deviceFacets, entityId);
    return host.devices.find((device) => device.id === deviceId);
  };
  const sceneForEntity = (entityId: string) => host.scenes.find((scene) => scene.entityId === entityId);
  // The entity id alone only names the account; the provider must also refuse a scene of a home
  // the user has already left (a two-tap confirm or a URL command can outlive the switch).
  const sceneForEntityInSelectedHome = (entityId: string) => {
    const scene = sceneForEntity(entityId);
    return scene && miSceneBelongsToSelectedHome(host, scene) ? scene : undefined;
  };
  const multiState = getHostMiAccountsState(host);
  const accounts = host.miAccountsOverride ?? multiState?.accounts ?? [];
  const enabledAccounts = resolveEnabledMiAccountsForHost(host, accounts);
  const channelBatcher = getChannelWriteBatcher(host);
  if (hasMultipleMiAccountsForHost(host) && accounts.length > 0) {
    return new MultiAccountMiCloudProvider({
      accounts: enabledAccounts,
      deviceOwners: multiState?.merged?.deviceOwners ?? {},
      specsByModel: multiState?.merged?.specsByModel ?? {},
      devices: host.devices,
      specResolver: host.specResolver,
      deviceForEntity,
      sceneForEntity: sceneForEntityInSelectedHome,
      transport: host.transport,
      clientForSession: (session) => xiaomiClientForHost(host, session),
      channelBatcher,
    });
  }
  const session = host.settings.miSession ?? accounts[0]?.session ?? null;
  if (!session) throw new Error(t("请先扫码登录米家"));
  if (!isHostMiSessionEnabled(host, session)) {
    throw new CapabilityGateError(
      {
        code: "connectionScopeDisabled",
        connection: "xiaomi-cloud",
        scope: miAccountScope(miAccountId(session)),
      },
      host.settings.interfaceLanguage,
    );
  }
  return new MiCloudProvider({
    client: xiaomiClientForHost(host, session),
    specResolver: host.specResolver,
    deviceForEntity,
    sceneForEntity: (entityId) => miSceneAccount(entityId) === miAccountId(session)
      ? sceneForEntityInSelectedHome(entityId) : undefined,
    channelBatcher,
    accountKey: miAccountId(session),
  });
}

function buildHomeAssistantProvider(host: MenuMijiaWindowsApp): HomeAssistantProvider {
  if (!isHostHaEnabled(host)) {
    throw new CapabilityGateError(
      {
        code: "connectionDisabled",
        connection: "home-assistant",
        scope: haConnectionScope(host.settings.haBaseURL, host.settings.haToken) ?? "home-assistant",
      },
      host.settings.interfaceLanguage,
    );
  }
  return new HomeAssistantProvider(
    new HomeAssistantClient(
      host.settings.haBaseURL,
      host.settings.haToken,
      host.haInvokeOverride ?? undefined,
    ),
    host.endpointSubmission,
  );
}

/** The provider for the backend the panel is connected to right now (ADR-0020). */
export function homeProviderFor(host: MenuMijiaWindowsApp): HomeCommandProvider {
  if (host.settings.connectionMode === "demo") return new DemoHomeProvider();
  if (isDualSourceEnabled(host)) {
    let cachedMiProvider: HomeCommandProvider | null = null;
    let cachedHaProvider: HomeCommandProvider | null = null;
    return new DualSourceHomeProvider({
      miProvider: {
        execute: (command, options) => {
          cachedMiProvider ??= buildXiaomiHomeProvider(host);
          return cachedMiProvider.execute(command, options);
        },
      },
      haProvider: {
        execute: (command, options) => {
          cachedHaProvider ??= buildHomeAssistantProvider(host);
          return cachedHaProvider.execute(command, options);
        },
      },
      routes: getHostDualSourceState(host)?.routes,
      deviceIdForEntity: (entityId) => deviceOwningEntityId(host.devices, host.deviceFacets, entityId),
    });
  }
  if (host.settings.connectionMode === "homeAssistant") {
    return buildHomeAssistantProvider(host);
  }
  return buildXiaomiHomeProvider(host);
}

export function markCloudValuesStale(host: MenuMijiaWindowsApp): void {
  if (
    (host.settings.connectionMode === "xiaomiCloud" || isDualSourceEnabled(host)) &&
    host.devices.length > 0
  ) {
    host.cloudValuesStale = true;
  }
}

export function markCloudValuesFresh(host: MenuMijiaWindowsApp): void {
  if (host.settings.connectionMode === "xiaomiCloud" || isDualSourceEnabled(host)) {
    host.cloudValuesStale = false;
  }
}
