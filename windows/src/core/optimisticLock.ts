import { speechLocale } from "./i18n.js";
import type { CoverSpec, DeviceCommand, FacetControl, SmartDevice } from "./models.js";

export const OPTIMISTIC_LOCK_DURATION_MS = 3_000;
export const READ_BACK_DELAY_MS = 800;

export interface OptimisticLockHost {
  readonly sourceRevision: number;
  readonly devices: readonly SmartDevice[];
  readonly deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly settings?: { readonly connectionMode?: string };
  readonly root?: { readonly isConnected?: boolean };
  refreshDevices?: (silent?: boolean) => Promise<void>;
}

export interface ReadBackTicket {
  readonly ticketId: number;
  readonly deviceId: string;
  readonly sourceRevision: number;
  readonly isCancelled: () => boolean;
  readonly cancel: () => void;
}

interface DeviceLockEntry {
  expiresAtMs: number;
  revision: number;
  coverOriginPosition: number | null;
  baselineDevice: SmartDevice | null;
  baselineFacets: readonly FacetControl[] | undefined;
}

interface PendingTicketEntry {
  readonly ticketId: number;
  readonly timer: ReturnType<typeof setTimeout>;
  readonly cancel: () => void;
}

interface HostOptimisticState {
  sourceRevision: number;
  readonly locks: Map<string, DeviceLockEntry>;
  nextTicketId: number;
  readonly activeTickets: Map<string, PendingTicketEntry>;
}

const hostStates = new WeakMap<object, HostOptimisticState>();

function ensureHostState(host: OptimisticLockHost): HostOptimisticState {
  let state = hostStates.get(host);
  if (!state) {
    state = {
      sourceRevision: host.sourceRevision,
      locks: new Map(),
      nextTicketId: 0,
      activeTickets: new Map(),
    };
    hostStates.set(host, state);
    return state;
  }
  if (state.sourceRevision !== host.sourceRevision) {
    for (const pending of state.activeTickets.values()) {
      pending.cancel();
    }
    state.activeTickets.clear();
    state.locks.clear();
    state.sourceRevision = host.sourceRevision;
  }
  return state;
}

/**
 * Locks `deviceId` on `host` for `durationMs` (default 3000ms) so background polls keep the
 * optimistic local row until confirmed or expired. Automatically invalidated when
 * `host.sourceRevision` changes.
 */
export function lockOptimistic(
  host: OptimisticLockHost,
  deviceId: string,
  durationMs = OPTIMISTIC_LOCK_DURATION_MS,
  options?: {
    readonly nowMs?: number;
    readonly coverOriginPosition?: number | null;
    readonly baselineDevice?: SmartDevice | null;
    readonly baselineFacets?: readonly FacetControl[];
  },
): number {
  const state = ensureHostState(host);
  if (durationMs <= 0) {
    state.locks.delete(deviceId);
    return 0;
  }
  const nowMs = options?.nowMs ?? Date.now();
  const prev = state.locks.get(deviceId);
  const prevActive = prev !== undefined && nowMs < prev.expiresAtMs;
  const revision = (prev?.revision ?? 0) + 1;
  let coverOriginPosition: number | null;
  if (prevActive && prev.coverOriginPosition !== null) {
    coverOriginPosition = prev.coverOriginPosition;
  } else if (options?.coverOriginPosition !== undefined) {
    coverOriginPosition = options.coverOriginPosition;
  } else {
    const existing = host.devices.find((item) => item.id === deviceId);
    coverOriginPosition = existing?.kind.kind === "cover" ? existing.kind.positionPercent : null;
  }
  const baselineDevice =
    prevActive && prev.baselineDevice !== null
      ? prev.baselineDevice
      : options?.baselineDevice !== undefined
        ? options.baselineDevice
        : null;
  const baselineFacets =
    prevActive && prev.baselineFacets !== undefined
      ? prev.baselineFacets
      : options?.baselineFacets;
  state.locks.set(deviceId, {
    expiresAtMs: nowMs + durationMs,
    revision,
    coverOriginPosition,
    baselineDevice,
    baselineFacets,
  });
  return revision;
}

export function isOptimisticallyLocked(
  host: OptimisticLockHost,
  deviceId: string,
  nowMs = Date.now(),
): boolean {
  const state = ensureHostState(host);
  const entry = state.locks.get(deviceId);
  if (!entry) return false;
  if (nowMs >= entry.expiresAtMs) {
    state.locks.delete(deviceId);
    return false;
  }
  return true;
}

export function optimisticLockRevision(host: OptimisticLockHost, deviceId: string): number {
  const state = ensureHostState(host);
  return state.locks.get(deviceId)?.revision ?? 0;
}

/**
 * Mirrors macOS `HomeStore.coverTravelTakesOver`: a cover stays locked across intermediate travel
 * and stale pre-command parked snapshots until the reported position reaches the commanded target
 * or stops at a new post-travel position.
 */
export function coverTravelTakesOver(
  originPosition: number | null,
  local: CoverSpec,
  incoming: CoverSpec,
): boolean {
  if (local.positionPercent === null || incoming.positionPercent === null) {
    return incoming.motion === local.motion;
  }
  if (incoming.motion === "stopped") {
    if (incoming.positionPercent === local.positionPercent) return true;
    if (originPosition !== null && incoming.positionPercent === originPosition) return false;
    return true;
  }
  if (local.motion === "stopped") {
    return false;
  }
  return local.motion === "opening"
    ? incoming.positionPercent >= local.positionPercent
    : incoming.positionPercent <= local.positionPercent;
}

function facetsMatchOptimistic(
  localFacets: readonly FacetControl[] | undefined,
  incomingFacets: readonly FacetControl[] | undefined,
  baselineFacets?: readonly FacetControl[],
): boolean {
  if (!localFacets || localFacets.length === 0) return true;
  if (!incomingFacets) return false;
  const incomingById = new Map(incomingFacets.map((facet) => [facet.id, facet]));
  const baselineById = baselineFacets
    ? new Map(baselineFacets.map((facet) => [facet.id, facet]))
    : null;
  for (const local of localFacets) {
    if (!local.isWritable) continue;
    const base = baselineById?.get(local.id);
    if (base && base.value === local.value) continue;
    const incoming = incomingById.get(local.id);
    if (!incoming || incoming.value !== local.value) return false;
  }
  return true;
}

function fieldMatches<T>(localVal: T, incomingVal: T, hasBase: boolean, baseVal: T): boolean {
  if (hasBase && localVal === baseVal) return true;
  return localVal === incomingVal;
}

function deviceMatchesOptimistic(
  local: SmartDevice,
  incoming: SmartDevice,
  localFacets?: readonly FacetControl[],
  incomingFacets?: readonly FacetControl[],
  baselineDevice?: SmartDevice | null,
  baselineFacets?: readonly FacetControl[],
): boolean {
  if (!facetsMatchOptimistic(localFacets, incomingFacets, baselineFacets)) return false;
  const a = local.kind;
  const b = incoming.kind;
  if (a.kind !== b.kind) return false;
  const base = baselineDevice && baselineDevice.kind.kind === a.kind ? baselineDevice.kind : null;
  switch (a.kind) {
    case "light": {
      if (b.kind !== "light") return false;
      const bk = base?.kind === "light" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        (a.brightnessPercent === null ||
          fieldMatches(
            a.brightnessPercent,
            b.brightnessPercent,
            bk !== null,
            bk?.brightnessPercent ?? null,
          )) &&
        (a.colorTempKelvin === null ||
          fieldMatches(
            a.colorTempKelvin,
            b.colorTempKelvin,
            bk !== null,
            bk?.colorTempKelvin ?? null,
          )) &&
        fieldMatches(a.currentEffect, b.currentEffect, bk !== null, bk?.currentEffect ?? null)
      );
    }
    case "climate": {
      if (b.kind !== "climate") return false;
      const bk = base?.kind === "climate" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        fieldMatches(a.hvacMode, b.hvacMode, bk !== null, bk?.hvacMode ?? a.hvacMode) &&
        fieldMatches(
          a.targetTemperature,
          b.targetTemperature,
          bk !== null,
          bk?.targetTemperature ?? a.targetTemperature,
        ) &&
        fieldMatches(a.fanMode, b.fanMode, bk !== null, bk?.fanMode ?? null) &&
        fieldMatches(a.swingMode ?? null, b.swingMode ?? null, bk !== null, bk?.swingMode ?? null)
      );
    }
    case "fan": {
      if (b.kind !== "fan") return false;
      const bk = base?.kind === "fan" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        (a.percentage === null ||
          fieldMatches(a.percentage, b.percentage, bk !== null, bk?.percentage ?? null)) &&
        fieldMatches(a.presetMode, b.presetMode, bk !== null, bk?.presetMode ?? null) &&
        fieldMatches(a.isOscillating, b.isOscillating, bk !== null, bk?.isOscillating ?? null)
      );
    }
    case "plug": {
      if (b.kind !== "plug") return false;
      const bk = base?.kind === "plug" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        fieldMatches(a.isChildLocked, b.isChildLocked, bk !== null, bk?.isChildLocked ?? a.isChildLocked)
      );
    }
    case "fridge": {
      if (b.kind !== "fridge") return false;
      const bk = base?.kind === "fridge" ? base : null;
      return (
        fieldMatches(a.currentMode, b.currentMode, bk !== null, bk?.currentMode ?? a.currentMode) &&
        fieldMatches(
          a.fridgeTargetTemp,
          b.fridgeTargetTemp,
          bk !== null,
          bk?.fridgeTargetTemp ?? a.fridgeTargetTemp,
        ) &&
        fieldMatches(
          a.freezerTargetTemp,
          b.freezerTargetTemp,
          bk !== null,
          bk?.freezerTargetTemp ?? a.freezerTargetTemp,
        )
      );
    }
    case "vacuum": {
      if (b.kind !== "vacuum") return false;
      const bk = base?.kind === "vacuum" ? base : null;
      return (
        fieldMatches(a.status, b.status, bk !== null, bk?.status ?? a.status) &&
        fieldMatches(a.currentMode, b.currentMode, bk !== null, bk?.currentMode ?? null)
      );
    }
    case "camera": {
      if (b.kind !== "camera") return false;
      const bk = base?.kind === "camera" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        fieldMatches(a.nightShot, b.nightShot, bk !== null, bk?.nightShot ?? null) &&
        fieldMatches(
          a.isMotionDetectionOn,
          b.isMotionDetectionOn,
          bk !== null,
          bk?.isMotionDetectionOn ?? null,
        )
      );
    }
    case "speaker": {
      if (b.kind !== "speaker") return false;
      const bk = base?.kind === "speaker" ? base : null;
      return (
        fieldMatches(a.state, b.state, bk !== null, bk?.state ?? a.state) &&
        fieldMatches(a.volumePercent, b.volumePercent, bk !== null, bk?.volumePercent ?? a.volumePercent) &&
        fieldMatches(a.isMuted, b.isMuted, bk !== null, bk?.isMuted ?? a.isMuted) &&
        fieldMatches(a.isSleepMode, b.isSleepMode, bk !== null, bk?.isSleepMode ?? a.isSleepMode)
      );
    }
    case "appliance": {
      if (b.kind !== "appliance") return false;
      const bk = base?.kind === "appliance" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        fieldMatches(a.currentMode, b.currentMode, bk !== null, bk?.currentMode ?? null) &&
        fieldMatches(
          a.targetTemperature,
          b.targetTemperature,
          bk !== null,
          bk?.targetTemperature ?? null,
        ) &&
        fieldMatches(a.statusText, b.statusText, bk !== null, bk?.statusText ?? null) &&
        fieldMatches(a.light?.isOn ?? null, b.light?.isOn ?? null, bk !== null, bk?.light?.isOn ?? null) &&
        fieldMatches(
          a.fanLevel?.current ?? null,
          b.fanLevel?.current ?? null,
          bk !== null,
          bk?.fanLevel?.current ?? null,
        )
      );
    }
    case "generic": {
      if (b.kind !== "generic") return false;
      const bk = base?.kind === "generic" ? base : null;
      return (
        fieldMatches(a.isOn, b.isOn, bk !== null, bk?.isOn ?? a.isOn) &&
        fieldMatches(
          a.powerControl?.value ?? null,
          b.powerControl?.value ?? null,
          bk !== null,
          bk?.powerControl?.value ?? null,
        )
      );
    }
    case "sensor":
      return b.kind === "sensor" && (a.statusText ?? null) === (b.statusText ?? null);
    case "cover":
      return b.kind === "cover" && coverTravelTakesOver(null, a, b);
  }
}

export function mergeHomeSnapshotRespectingLocks(
  host: OptimisticLockHost,
  incomingDevices: readonly SmartDevice[],
  incomingFacets: Readonly<Record<string, readonly FacetControl[]>> | undefined,
  nowMs = Date.now(),
): {
  devices: SmartDevice[];
  deviceFacets: Record<string, FacetControl[]>;
} {
  const state = ensureHostState(host);
  const incomingIds = new Set(incomingDevices.map((device) => device.id));
  for (const lockedId of [...state.locks.keys()]) {
    if (!incomingIds.has(lockedId)) {
      state.locks.delete(lockedId);
    }
  }
  for (const [ticketDevId, pending] of [...state.activeTickets.entries()]) {
    if (!incomingIds.has(ticketDevId)) {
      pending.cancel();
      state.activeTickets.delete(ticketDevId);
    }
  }

  const existingById = new Map(host.devices.map((device) => [device.id, device]));
  const localFacetsById = host.deviceFacets ?? {};
  const mergedDevices: SmartDevice[] = [];
  const mergedFacets: Record<string, FacetControl[]> = {};

  const adoptIncomingFacets = (id: string) => {
    const list = incomingFacets?.[id];
    if (list && list.length > 0) {
      mergedFacets[id] = list.map((item) => ({ ...item }));
    }
  };
  const keepLocalFacets = (id: string) => {
    const list = localFacetsById[id] ?? incomingFacets?.[id];
    if (list && list.length > 0) {
      mergedFacets[id] = list.map((item) => ({ ...item }));
    }
  };

  for (const incoming of incomingDevices) {
    const lock = state.locks.get(incoming.id);
    const local = existingById.get(incoming.id);
    if (!lock || nowMs >= lock.expiresAtMs || !local) {
      state.locks.delete(incoming.id);
      mergedDevices.push(incoming);
      adoptIncomingFacets(incoming.id);
      continue;
    }

    if (local.kind.kind === "cover" && incoming.kind.kind === "cover") {
      if (coverTravelTakesOver(lock.coverOriginPosition, local.kind, incoming.kind)) {
        state.locks.delete(incoming.id);
        mergedDevices.push(incoming);
        adoptIncomingFacets(incoming.id);
      } else {
        mergedDevices.push(local);
        keepLocalFacets(incoming.id);
      }
      continue;
    }

    if (
      deviceMatchesOptimistic(
        local,
        incoming,
        localFacetsById[incoming.id],
        incomingFacets?.[incoming.id],
        lock.baselineDevice,
        lock.baselineFacets,
      )
    ) {
      state.locks.delete(incoming.id);
      mergedDevices.push(incoming);
      adoptIncomingFacets(incoming.id);
    } else {
      mergedDevices.push(local);
      keepLocalFacets(incoming.id);
    }
  }

  return { devices: mergedDevices, deviceFacets: mergedFacets };
}

export function mergeSnapshotRespectingLocks(
  host: OptimisticLockHost,
  incomingDevices: readonly SmartDevice[],
  nowMs = Date.now(),
): SmartDevice[] {
  return mergeHomeSnapshotRespectingLocks(host, incomingDevices, host.deviceFacets, nowMs).devices;
}

/**
 * Schedules a non-blocking 800ms delayed read-back verification (`ReadBackTicket`).
 * Supersedes any earlier ticket for `deviceId` and cancels automatically on `sourceRevision` change.
 */
export function scheduleDelayedReadBack(
  host: OptimisticLockHost,
  deviceId: string,
  delayMs = READ_BACK_DELAY_MS,
  onReadBack?: () => void | Promise<void>,
): ReadBackTicket {
  const state = ensureHostState(host);
  const prior = state.activeTickets.get(deviceId);
  if (prior) {
    prior.cancel();
    state.activeTickets.delete(deviceId);
  }

  const ticketId = ++state.nextTicketId;
  const capturedRevision = host.sourceRevision;
  let cancelled = false;

  const cancel = () => {
    if (cancelled) return;
    cancelled = true;
    globalThis.clearTimeout(timer);
    if (state.activeTickets.get(deviceId)?.ticketId === ticketId) {
      state.activeTickets.delete(deviceId);
    }
  };

  const timer = globalThis.setTimeout(() => {
    if (cancelled) return;
    if (host.sourceRevision !== capturedRevision) {
      cancel();
      return;
    }
    const current = state.activeTickets.get(deviceId);
    if (!current || current.ticketId !== ticketId) return;
    state.activeTickets.delete(deviceId);
    if (host.settings?.connectionMode === "demo") return;
    if (host.root && host.root.isConnected === false) return;
    if (onReadBack) {
      void Promise.resolve(onReadBack()).catch(() => {});
      return;
    }
    if (typeof host.refreshDevices === "function") {
      void host.refreshDevices(true).catch(() => {});
    }
  }, delayMs);

  (timer as unknown as { unref?: () => void })?.unref?.();

  state.activeTickets.set(deviceId, { ticketId, timer, cancel });

  return {
    ticketId,
    deviceId,
    sourceRevision: capturedRevision,
    isCancelled: () => cancelled || host.sourceRevision !== capturedRevision,
    cancel,
  };
}

export function cancelDelayedReadBack(host: OptimisticLockHost, deviceId?: string): void {
  const state = ensureHostState(host);
  if (deviceId !== undefined) {
    const entry = state.activeTickets.get(deviceId);
    if (entry) {
      entry.cancel();
      state.activeTickets.delete(deviceId);
    }
    return;
  }
  for (const entry of state.activeTickets.values()) {
    entry.cancel();
  }
  state.activeTickets.clear();
}

export function hasPendingReadBack(host: OptimisticLockHost, deviceId: string): boolean {
  const state = ensureHostState(host);
  return state.activeTickets.has(deviceId);
}

/**
 * Syncs direct HA entity commands (`setSwitch`, `setSelectOption`, `setNumberValue`) back onto
 * matching `FacetControl` rows in `deviceFacets` so both `setMiotProperty` and direct entity
 * commands keep `更多设置` rows optimistic immediately.
 */
export function syncDirectCommandToFacets(
  deviceFacets: Readonly<Record<string, readonly FacetControl[]>>,
  command: DeviceCommand,
): string[] {
  const updatedDeviceIds: string[] = [];
  for (const [devId, controls] of Object.entries(deviceFacets)) {
    let touched = false;
    for (const control of controls) {
      if (control.target?.kind !== "property" || control.target.entityId !== command.entityId) {
        continue;
      }
      if (command.kind === "setSwitch") {
        if (control.value !== command.isOn) {
          control.value = command.isOn;
          touched = true;
        }
      } else if (command.kind === "setSelectOption") {
        const match = control.options.find((opt) => opt.label === command.option);
        const nextVal = match ? match.value : command.option;
        if (control.value !== nextVal) {
          control.value = nextVal;
          touched = true;
        }
      } else if (command.kind === "setNumberValue") {
        if (control.value !== command.value) {
          control.value = command.value;
          touched = true;
        }
      }
    }
    if (touched) updatedDeviceIds.push(devId);
  }
  return updatedDeviceIds;
}

/**
 * Applies optimistic mutations for HA-specific domain commands (`humidifier.*`, `valve.*`,
 * `media_player.*`) that `applyCommandToDevices` does not handle natively.
 */
export function applyHAExtendedCommandEffect(
  devices: SmartDevice[],
  command: DeviceCommand,
): void {
  const isEn = speechLocale().toLowerCase().startsWith("en");
  const tr = (zh: string, en: string) => (isEn ? en : zh);
  for (let i = 0; i < devices.length; i += 1) {
    const dev = devices[i]!;
    const k = dev.kind;
    if (k.kind === "appliance") {
      if (k.entityId === command.entityId && command.entityId.startsWith("humidifier.")) {
        if (command.kind === "setNumberValue") {
          const pct = Math.max(0, Math.min(100, Math.round(command.value)));
          const parts: string[] = [];
          if (k.currentHumidity !== null) parts.push(`${Math.round(k.currentHumidity)}%`);
          parts.push(tr(`目标 ${pct}%`, `Target ${pct}%`));
          dev.kind = { ...k, statusText: parts.join(" · ") };
        }
      } else if (k.entityId === command.entityId && command.entityId.startsWith("valve.")) {
        if (command.kind === "setNumberValue") {
          const pct = Math.max(0, Math.min(100, Math.round(command.value)));
          const statusText = pct > 0 && pct < 100 ? tr(`开 ${pct}%`, `Open ${pct}%`) : null;
          dev.kind = { ...k, isOn: pct > 0, statusText };
        } else if (command.kind === "setSelectOption") {
          const lower = command.option.trim().toLowerCase();
          if (lower === "open" || lower === "打开") {
            dev.kind = { ...k, isOn: true, statusText: tr("正在打开", "Opening") };
          } else if (lower === "close" || lower === "关闭") {
            dev.kind = { ...k, isOn: false, statusText: tr("正在关闭", "Closing") };
          } else if (lower === "pause" || lower === "stop" || lower === "暂停" || lower === "停止") {
            dev.kind = { ...k, statusText: null };
          }
        }
      }
    } else if (k.kind === "speaker" && k.mediaEntityId === command.entityId) {
      if (command.kind === "setNumberValue") {
        const pct =
          command.value <= 1
            ? Math.max(0, Math.min(100, Math.round(command.value * 100)))
            : Math.max(0, Math.min(100, Math.round(command.value)));
        k.volumePercent = pct;
      } else if (command.kind === "setSwitch") {
        k.state = command.isOn ? "playing" : "idle";
      }
    }
  }
}
