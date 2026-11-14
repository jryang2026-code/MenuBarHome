import { haRoundedInt } from "./haDomains.js";
import { speechLocale } from "./i18n.js";
import type { CoverSpec, DeviceCommand, FacetControl, SmartDevice } from "./models.js";

export const OPTIMISTIC_LOCK_DURATION_MS = 3_000;
/** A cover is write-only: its position is reported only after the motor moves (macOS `coverOptimisticLockDuration`). */
export const COVER_OPTIMISTIC_LOCK_DURATION_MS = 8_000;
export const READ_BACK_DELAY_MS = 800;
/** How long a delayed read-back waits before trying again while a background sync owns the wire. */
export const READ_BACK_BUSY_RETRY_MS = 250;
/** Attempts a delayed read-back makes while a background sync is running before it gives up. */
export const READ_BACK_BUSY_RETRY_LIMIT = 40;
/** How long a fired read-back's confirmation snapshot may stand in for a locked row. */
export const READ_BACK_CONFIRM_WINDOW_MS = 5_000;

export interface OptimisticLockWindowLike {
  readonly closed?: boolean;
  setTimeout?: (handler: () => void, timeout?: number) => number | ReturnType<typeof setTimeout>;
  clearTimeout?: (id: number | undefined) => void;
}

export interface OptimisticLockRootLike {
  readonly isConnected?: boolean;
  readonly ownerDocument?: {
    readonly defaultView?: OptimisticLockWindowLike | null;
  } | null;
}

export interface OptimisticLockHost {
  readonly sourceRevision: number;
  readonly devices: readonly SmartDevice[];
  readonly deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  readonly settings?: { readonly connectionMode?: string };
  readonly root?: OptimisticLockRootLike;
  /** A background sync already owns the wire, so a read-back must wait instead of burning its ticket. */
  readonly isSyncingCloud?: boolean;
  refreshDevices?: (silent?: boolean) => Promise<void>;
}

export function isHostAttachedToActiveWindow(host: OptimisticLockHost): boolean {
  const root = host.root;
  if (!root) return true;
  if (root.isConnected === false) return false;
  if (root.ownerDocument !== undefined) {
    const doc = root.ownerDocument;
    if (!doc) return false;
    const win = doc.defaultView;
    if (!win || win.closed === true) return false;
    const activeDoc = (globalThis as { document?: unknown }).document;
    if (activeDoc !== undefined && activeDoc !== doc) return false;
    const activeWin = (globalThis as { window?: unknown }).window;
    if (activeWin !== undefined && activeWin !== win) return false;
  }
  return true;
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
  /** Kind fields this lock cycle wrote, so an equal-to-baseline value still needs confirmation. */
  dirtyFields: Set<string>;
  /** 更多设置 facet ids this lock cycle wrote, for the same reason. */
  dirtyFacetIds: Set<string>;
}

/** What a failed write puts back: the lock it displaced, if that lock was still unexpired. */
export interface OptimisticLockSnapshot {
  readonly expiresAtMs: number;
  readonly coverOriginPosition: number | null;
  readonly dirtyFields: readonly string[];
  readonly dirtyFacetIds: readonly string[];
}

/** One command's claim on a device row; a newer claim makes every older answer stale. */
export interface DeviceWriteClaim {
  readonly deviceId: string;
  readonly writeSeq: number;
  readonly sourceRevision: number;
}

interface PendingTicketEntry {
  readonly ticketId: number;
  readonly timer: unknown;
  readonly cancel: () => void;
}

interface ReadBackConfirmation {
  /** The lock revision the read-back was started under; a newer write invalidates the answer. */
  readonly revision: number;
  /** When this answer stops standing in for the locked row (`READ_BACK_CONFIRM_WINDOW_MS` later). */
  readonly expiresAtMs: number;
}

interface HostOptimisticState {
  sourceRevision: number;
  readonly locks: Map<string, DeviceLockEntry>;
  /**
   * Per-device lock revision. Only `lockOptimistic` bumps it and a source reset clears it; adopting
   * a reported row clears the lock but leaves the revision, so the send that made it still owns it
   * (`standards-store-locks-timers.md` §14).
   */
  readonly revisions: Map<string, number>;
  /** Per-device write sequence, bumped by every command that addresses the row. */
  readonly writeSeqs: Map<string, number>;
  /** Device → lock revision whose read-back is in flight and may replace the locked row. */
  readonly readBackInFlight: Map<string, ReadBackConfirmation>;
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
      revisions: new Map(),
      writeSeqs: new Map(),
      readBackInFlight: new Map(),
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
    state.revisions.clear();
    state.writeSeqs.clear();
    state.readBackInFlight.clear();
    state.sourceRevision = host.sourceRevision;
  }
  return state;
}

/** One value's identity for "did this field change" comparisons; object values compare by content. */
function fieldSnapshot(value: unknown): string {
  return value === undefined ? "\u0000undefined" : JSON.stringify(value) ?? "\u0000unserializable";
}

/** The `kind` fields `current` changed away from `baseline`. */
function changedKindFields(baseline: SmartDevice, current: SmartDevice): string[] {
  if (baseline.kind.kind !== current.kind.kind) return [];
  const before = baseline.kind as unknown as Record<string, unknown>;
  const after = current.kind as unknown as Record<string, unknown>;
  const changed: string[] = [];
  for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (fieldSnapshot(before[key]) !== fieldSnapshot(after[key])) changed.push(key);
  }
  return changed;
}

/** The writable facet ids whose local value `current` changed away from `baseline`. */
function changedFacetIds(
  baseline: readonly FacetControl[] | undefined,
  current: readonly FacetControl[] | undefined,
): string[] {
  if (!baseline || !current) return [];
  const before = new Map(baseline.map((facet) => [facet.id, facet.value]));
  const changed: string[] = [];
  for (const facet of current) {
    if (!facet.isWritable) continue;
    if (fieldSnapshot(before.get(facet.id)) !== fieldSnapshot(facet.value)) changed.push(facet.id);
  }
  return changed;
}

/**
 * Locks `deviceId` on `host` for `durationMs` (default 3000ms) so background polls keep the
 * optimistic local row until confirmed or expired. Automatically invalidated when
 * `host.sourceRevision` changes.
 *
 * `baselineDevice` / `baselineFacets` are the rows the write is about to change. Every field they
 * differ from joins the lock's dirty set, which is what later snapshots must confirm — a value that
 * was written and then written back to the baseline still counts as dirty (§14).
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
  const revision = (state.revisions.get(deviceId) ?? 0) + 1;
  state.revisions.set(deviceId, revision);
  let coverOriginPosition: number | null;
  if (prevActive && prev.coverOriginPosition !== null) {
    coverOriginPosition = prev.coverOriginPosition;
  } else if (options?.coverOriginPosition !== undefined) {
    coverOriginPosition = options.coverOriginPosition;
  } else {
    const existing = host.devices.find((item) => item.id === deviceId);
    coverOriginPosition = existing?.kind.kind === "cover" ? existing.kind.positionPercent : null;
  }
  const dirtyFields = new Set<string>(prevActive ? prev.dirtyFields : []);
  const dirtyFacetIds = new Set<string>(prevActive ? prev.dirtyFacetIds : []);
  const current = host.devices.find((item) => item.id === deviceId);
  if (options?.baselineDevice && current) {
    for (const key of changedKindFields(options.baselineDevice, current)) dirtyFields.add(key);
  }
  for (const id of changedFacetIds(options?.baselineFacets, host.deviceFacets?.[deviceId])) {
    dirtyFacetIds.add(id);
  }
  state.locks.set(deviceId, {
    expiresAtMs: nowMs + durationMs,
    revision,
    coverOriginPosition,
    dirtyFields,
    dirtyFacetIds,
  });
  return revision;
}

/**
 * The lock this row holds now, for a write that must put it back when its send fails. `null` when
 * the row is not locked, which is what an unsuccessful write releases.
 */
export function snapshotOptimisticLock(
  host: OptimisticLockHost,
  deviceId: string,
  nowMs = Date.now(),
): OptimisticLockSnapshot | null {
  const state = ensureHostState(host);
  const entry = state.locks.get(deviceId);
  if (!entry || nowMs >= entry.expiresAtMs) return null;
  return {
    expiresAtMs: entry.expiresAtMs,
    coverOriginPosition: entry.coverOriginPosition,
    dirtyFields: [...entry.dirtyFields],
    dirtyFacetIds: [...entry.dirtyFacetIds],
  };
}

/**
 * Puts back what `snapshotOptimisticLock` saved. The revision keeps climbing — a restored lock is
 * still this write's, and no earlier send may take the row back (§14).
 */
export function restoreOptimisticLock(
  host: OptimisticLockHost,
  deviceId: string,
  snapshot: OptimisticLockSnapshot | null,
): void {
  const state = ensureHostState(host);
  if (!snapshot) {
    state.locks.delete(deviceId);
    return;
  }
  state.locks.set(deviceId, {
    expiresAtMs: snapshot.expiresAtMs,
    revision: state.revisions.get(deviceId) ?? 0,
    coverOriginPosition: snapshot.coverOriginPosition,
    dirtyFields: new Set(snapshot.dirtyFields),
    dirtyFacetIds: new Set(snapshot.dirtyFacetIds),
  });
}

/**
 * Records that this command is now the newest write to `deviceId`, before its request goes out.
 * A later command claims the row again, so the older answer must not overwrite it.
 */
export function claimDeviceWrite(host: OptimisticLockHost, deviceId: string): DeviceWriteClaim {
  const state = ensureHostState(host);
  const writeSeq = (state.writeSeqs.get(deviceId) ?? 0) + 1;
  state.writeSeqs.set(deviceId, writeSeq);
  return { deviceId, writeSeq, sourceRevision: host.sourceRevision };
}

export function peekDeviceWriteSeq(host: OptimisticLockHost, deviceId: string): number {
  const state = ensureHostState(host);
  return state.writeSeqs.get(deviceId) ?? 0;
}

export function currentDeviceWriteClaim(host: OptimisticLockHost, deviceId: string): DeviceWriteClaim {
  const state = ensureHostState(host);
  return {
    deviceId,
    writeSeq: state.writeSeqs.get(deviceId) ?? 0,
    sourceRevision: host.sourceRevision,
  };
}

/** True while no newer command has claimed `claim`'s row and the data source is unchanged. */
export function ownsDeviceWrite(host: OptimisticLockHost, claim: DeviceWriteClaim): boolean {
  if (claim.sourceRevision !== host.sourceRevision) return false;
  const state = ensureHostState(host);
  return (state.writeSeqs.get(claim.deviceId) ?? 0) === claim.writeSeq;
}

export interface UndoActionBatch {
  readonly isStopped: boolean;
  readonly isFinished: boolean;
  stop(reason?: string): void;
  waitForInFlight(): Promise<void>;
  recordWriteClaim(deviceId: string, claim: DeviceWriteClaim): void;
  ownsDeviceWrite(host: OptimisticLockHost, deviceId: string): boolean;
  applyRestoreCommand(
    host: OptimisticLockHost & {
      applyCommand(command: DeviceCommand, readBackPower?: boolean): Promise<boolean>;
    },
    deviceId: string,
    command: DeviceCommand,
  ): Promise<boolean>;
}

const undoActionBatches = new WeakMap<object, UndoActionBatch>();

export function registerUndoActionBatch(action: object, batch: UndoActionBatch): void {
  undoActionBatches.set(action, batch);
}

export function getRegisteredUndoActionBatch(
  action: object | null | undefined,
): UndoActionBatch | null {
  return action ? undoActionBatches.get(action) ?? null : null;
}

export class MultiCommandPresetBatch implements UndoActionBatch {
  private stopped = false;
  private finished = false;
  private readonly inFlightPromises = new Set<Promise<void>>();
  private readonly writeClaimsByDevice = new Map<string, DeviceWriteClaim>();

  public get isStopped(): boolean {
    return this.stopped;
  }

  public get isFinished(): boolean {
    return this.finished;
  }

  public stop(): void {
    this.stopped = true;
  }

  public markFinished(): void {
    this.finished = true;
  }

  public async trackInFlight<T>(fn: () => Promise<T>): Promise<T> {
    let settle!: () => void;
    const gate = new Promise<void>((resolve) => {
      settle = resolve;
    });
    this.inFlightPromises.add(gate);
    try {
      return await fn();
    } finally {
      this.inFlightPromises.delete(gate);
      settle();
    }
  }

  public async waitForInFlight(): Promise<void> {
    while (this.inFlightPromises.size > 0) {
      await Promise.allSettled([...this.inFlightPromises]);
    }
  }

  public recordWriteClaim(deviceId: string, claim: DeviceWriteClaim): void {
    this.writeClaimsByDevice.set(deviceId, claim);
  }

  public ownsDeviceWrite(host: OptimisticLockHost, deviceId: string): boolean {
    const claim = this.writeClaimsByDevice.get(deviceId);
    return claim === undefined || ownsDeviceWrite(host, claim);
  }

  public async applyRestoreCommand(
    host: OptimisticLockHost & {
      applyCommand(command: DeviceCommand, readBackPower?: boolean): Promise<boolean>;
    },
    deviceId: string,
    command: DeviceCommand,
  ): Promise<boolean> {
    const seqBefore = peekDeviceWriteSeq(host, deviceId);
    const sendPromise = host.applyCommand(command);
    const restoreClaim =
      peekDeviceWriteSeq(host, deviceId) === seqBefore
        ? claimDeviceWrite(host, deviceId)
        : currentDeviceWriteClaim(host, deviceId);
    this.recordWriteClaim(deviceId, restoreClaim);
    return sendPromise;
  }
}

export interface PresetCommandRunnerArgs {
  readonly host: {
    readonly sourceRevision: number;
    readonly devices: readonly SmartDevice[];
    readonly replyBanner: { readonly text: string; readonly isError?: boolean } | null;
    readonly lockHost?: object;
    executeSingleCommand(
      device: SmartDevice,
      command: DeviceCommand,
      summary: string,
      intent: unknown,
    ): Promise<void>;
    applyCommand(command: DeviceCommand): Promise<boolean>;
    updateUndoCommandsForDevice?(
      deviceId: string,
      commands: readonly DeviceCommand[],
      previousKind: SmartDevice["kind"],
    ): void;
  };
  readonly device: SmartDevice;
  readonly commands: readonly DeviceCommand[];
  readonly intent: unknown;
  readonly summary: string;
  readonly preSnapshot: SmartDevice;
  readonly computeInverses: (command: DeviceCommand) => DeviceCommand[];
  readonly mergeInverses: (steps: readonly (readonly DeviceCommand[])[]) => DeviceCommand[];
  readonly failureFallbackText: () => string;
}

export async function runTrackedDevicePresetCommands(
  args: PresetCommandRunnerArgs,
): Promise<{ readonly message: string; readonly isError: boolean }> {
  const {
    host,
    device: dev,
    commands,
    intent,
    summary,
    preSnapshot,
    computeInverses,
    mergeInverses,
    failureFallbackText,
  } = args;
  interface InlineUndoAction {
    readonly summary: string;
    readonly steps: ReadonlyArray<{ readonly deviceId: string; readonly commands: readonly DeviceCommand[] }>;
    readonly expiresAtMs: number;
  }
  const lockHost = ((host.lockHost ?? host) as unknown) as OptimisticLockHost & {
    lastUndoAction?: InlineUndoAction | null;
  };
  const startRevision = host.sourceRevision;
  const presetBatch = commands.length > 1 ? new MultiCommandPresetBatch() : null;
  const appliedInverses: DeviceCommand[][] = [];
  let trackedUndoAction: InlineUndoAction | null = null;
  try {
    for (let i = 0; i < commands.length; i += 1) {
      if (presetBatch?.isStopped || host.sourceRevision !== startRevision) break;
      const cmd = commands[i]!;
      if (i === 0) {
        const prevBanner = host.replyBanner;
        const prevUndo = lockHost.lastUndoAction;
        const seqBefore = peekDeviceWriteSeq(lockHost, dev.id);
        const execPromise = host.executeSingleCommand(dev, cmd, summary, intent);
        if (presetBatch) {
          const claim =
            peekDeviceWriteSeq(lockHost, dev.id) === seqBefore
              ? claimDeviceWrite(lockHost, dev.id)
              : currentDeviceWriteClaim(lockHost, dev.id);
          presetBatch.recordWriteClaim(dev.id, claim);
        }
        await (presetBatch ? presetBatch.trackInFlight(() => execPromise) : execPromise);
        if (host.replyBanner !== prevBanner && host.replyBanner?.isError) {
          return { message: host.replyBanner.text, isError: true };
        }
        const firstInverses = computeInverses(cmd);
        appliedInverses.push(firstInverses);
        trackedUndoAction =
          lockHost.lastUndoAction && lockHost.lastUndoAction !== prevUndo
            ? lockHost.lastUndoAction
            : null;
        if (trackedUndoAction && presetBatch) {
          registerUndoActionBatch(trackedUndoAction, presetBatch);
        }
        if (typeof host.updateUndoCommandsForDevice === "function" && firstInverses.length > 0) {
          host.updateUndoCommandsForDevice(dev.id, firstInverses, preSnapshot.kind);
        }
      } else {
        let ok = false;
        const runSubsequent = async (): Promise<void> => {
          const seqBefore = peekDeviceWriteSeq(lockHost, dev.id);
          const sendPromise = host.applyCommand(cmd);
          if (presetBatch) {
            const claim =
              peekDeviceWriteSeq(lockHost, dev.id) === seqBefore
                ? claimDeviceWrite(lockHost, dev.id)
                : currentDeviceWriteClaim(lockHost, dev.id);
            presetBatch.recordWriteClaim(dev.id, claim);
          }
          ok = await sendPromise;
          if (!ok || host.sourceRevision !== startRevision) return;
          appliedInverses.push(computeInverses(cmd));
          const merged = mergeInverses(appliedInverses);
          if (merged.length > 0 && (!presetBatch || presetBatch.ownsDeviceWrite(lockHost, dev.id))) {
            if (trackedUndoAction) {
              const mutableSteps = trackedUndoAction.steps as Array<{
                deviceId: string;
                commands: readonly DeviceCommand[];
              }>;
              for (let s = 0; s < mutableSteps.length; s += 1) {
                if (mutableSteps[s]!.deviceId === dev.id) {
                  mutableSteps[s] = { deviceId: dev.id, commands: merged };
                }
              }
            }
            if (typeof host.updateUndoCommandsForDevice === "function") {
              host.updateUndoCommandsForDevice(dev.id, merged, preSnapshot.kind);
            }
          }
        };
        await (presetBatch ? presetBatch.trackInFlight(runSubsequent) : runSubsequent());
        if (!ok) {
          return {
            message: host.replyBanner?.text ?? failureFallbackText(),
            isError: true,
          };
        }
      }
    }
  } finally {
    presetBatch?.markFinished();
  }
  return { message: summary, isError: false };
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

/**
 * The revision of the send that owns `deviceId`. Adopting a reported row clears the lock but keeps
 * this value, so a later answer from an earlier send is still recognised as stale (§14).
 */
export function optimisticLockRevision(host: OptimisticLockHost, deviceId: string): number {
  const state = ensureHostState(host);
  return state.revisions.get(deviceId) ?? 0;
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

/**
 * True while every facet this lock cycle wrote already reports the local value. A facet the user
 * never touched — the colour temperature beside a power toggle, say — does not block the adoption
 * of a reported row, so the lock clears as soon as the write it protects is visible.
 */
function facetsMatchOptimistic(
  localFacets: readonly FacetControl[] | undefined,
  incomingFacets: readonly FacetControl[] | undefined,
  dirtyFacetIds: ReadonlySet<string>,
): boolean {
  if (dirtyFacetIds.size === 0) return true;
  if (!incomingFacets) return false;
  const localById = new Map((localFacets ?? []).map((facet) => [facet.id, facet.value]));
  const incomingById = new Map(incomingFacets.map((facet) => [facet.id, facet.value]));
  for (const id of dirtyFacetIds) {
    if (!localById.has(id)) continue;
    if (fieldSnapshot(incomingById.get(id)) !== fieldSnapshot(localById.get(id))) return false;
  }
  return true;
}

/**
 * True while the reported row agrees with every kind field this lock cycle wrote.
 *
 * Equality with the first baseline is deliberately NOT the test: `off -> on -> off` ends back on
 * the baseline value, so a rule of "unchanged from the baseline is fine" would accept the stale
 * `on` snapshot and drop the lock mid-write. `dirtyFields` records what was written instead. A
 * lock that never recorded which fields it changed (`dirtyFields` empty) keeps the older, stricter
 * rule: every field must agree before the reported row replaces the row on screen.
 */
function fieldsMatchOptimistic(
  local: SmartDevice["kind"],
  incoming: SmartDevice["kind"],
  dirtyFields: ReadonlySet<string>,
): boolean {
  const a = local as unknown as Record<string, unknown>;
  const b = incoming as unknown as Record<string, unknown>;
  const fields =
    dirtyFields.size > 0
      ? dirtyFields
      : new Set([...Object.keys(a), ...Object.keys(b)].filter((key) => key !== "kind"));
  for (const field of fields) {
    if (field === "kind") continue;
    if (fieldSnapshot(a[field]) !== fieldSnapshot(b[field])) return false;
  }
  return true;
}

function deviceMatchesOptimistic(
  local: SmartDevice,
  incoming: SmartDevice,
  localFacets: readonly FacetControl[] | undefined,
  incomingFacets: readonly FacetControl[] | undefined,
  lock: DeviceLockEntry,
): boolean {
  if (local.kind.kind !== incoming.kind.kind) return false;
  if (!facetsMatchOptimistic(localFacets, incomingFacets, lock.dirtyFacetIds)) return false;
  return fieldsMatchOptimistic(local.kind, incoming.kind, lock.dirtyFields);
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
      state.readBackInFlight.delete(incoming.id);
      mergedDevices.push(incoming);
      adoptIncomingFacets(incoming.id);
      continue;
    }

    if (local.kind.kind === "cover" && incoming.kind.kind === "cover") {
      // A cover is write-only: only its own travel confirms the command, and a snapshot cannot
      // stand in for it (`standards-store-locks-timers.md` §14).
      state.readBackInFlight.delete(incoming.id);
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

    // A read-back this write started is the snapshot that decides whether the send landed, so it is
    // adopted even when an unrelated field has moved on since the lock was taken. A write that took
    // the row after that read-back went out invalidates the answer instead (§14).
    const confirmation = state.readBackInFlight.get(incoming.id);
    const readBackDecides =
      confirmation !== undefined &&
      nowMs <= confirmation.expiresAtMs &&
      confirmation.revision === lock.revision &&
      confirmation.revision === (state.revisions.get(incoming.id) ?? 0);
    if (readBackDecides) state.readBackInFlight.delete(incoming.id);

    if (
      readBackDecides ||
      deviceMatchesOptimistic(
        local,
        incoming,
        localFacetsById[incoming.id],
        incomingFacets?.[incoming.id],
        lock,
      )
    ) {
      state.locks.delete(incoming.id);
      state.readBackInFlight.delete(incoming.id);
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
 * Schedules a non-blocking delayed read-back verification (`ReadBackTicket`).
 * Supersedes any earlier ticket for `deviceId` and cancels automatically on `sourceRevision` change.
 *
 * When the timer fires while a background sync already owns the wire, the read-back is re-armed
 * `READ_BACK_BUSY_RETRY_MS` later instead of burning its one attempt, up to
 * `READ_BACK_BUSY_RETRY_LIMIT` times. Before the request actually goes out, the current lock
 * revision is recorded in `readBackInFlight` so that the snapshot this read-back pulls back is
 * allowed to replace the optimistic row it was sent to check — unless a newer write raised the
 * revision in the meantime, in which case the answer belongs to the older write and is ignored.
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
  const ownerWin = host.root?.ownerDocument?.defaultView ?? null;
  const useOwnerWinTimers =
    ownerWin !== null &&
    typeof ownerWin.setTimeout === "function" &&
    typeof ownerWin.clearTimeout === "function";
  let cancelled = false;
  let timer: unknown;
  let busyRetriesLeft = READ_BACK_BUSY_RETRY_LIMIT;

  const arm = (waitMs: number, handler: () => void) => {
    timer = useOwnerWinTimers
      ? ownerWin.setTimeout!(handler, waitMs)
      : globalThis.setTimeout(handler, waitMs);
    (timer as { unref?: () => void } | null)?.unref?.();
  };

  const cancel = () => {
    if (cancelled) return;
    cancelled = true;
    if (useOwnerWinTimers) {
      ownerWin.clearTimeout!(timer as number | undefined);
    } else {
      globalThis.clearTimeout(timer as ReturnType<typeof setTimeout>);
    }
    if (state.activeTickets.get(deviceId)?.ticketId === ticketId) {
      state.activeTickets.delete(deviceId);
    }
  };

  const runReadBack = () => {
    if (cancelled) return;
    if (host.sourceRevision !== capturedRevision || !isHostAttachedToActiveWindow(host)) {
      cancel();
      return;
    }
    const current = state.activeTickets.get(deviceId);
    if (!current || current.ticketId !== ticketId) return;
    if (host.settings?.connectionMode === "demo") {
      state.activeTickets.delete(deviceId);
      return;
    }
    // A sync already on the wire would swallow this attempt, so wait for it rather than lose it.
    if (host.isSyncingCloud === true && busyRetriesLeft > 0) {
      busyRetriesLeft -= 1;
      arm(READ_BACK_BUSY_RETRY_MS, runReadBack);
      return;
    }
    state.activeTickets.delete(deviceId);
    // This read-back is the snapshot that decides whether the send landed, so it may replace the
    // locked row. Recorded before the request goes out: a newer write that raises the revision
    // while it is in flight turns the answer into an older write's answer.
    const revision = state.revisions.get(deviceId);
    if (revision !== undefined && state.locks.has(deviceId)) {
      state.readBackInFlight.set(deviceId, {
        revision,
        expiresAtMs: Date.now() + READ_BACK_CONFIRM_WINDOW_MS,
      });
    }
    if (onReadBack) {
      void Promise.resolve(onReadBack()).catch(() => {});
      return;
    }
    if (typeof host.refreshDevices === "function") {
      void host.refreshDevices(true).catch(() => {});
    }
  };

  arm(delayMs, runReadBack);

  state.activeTickets.set(deviceId, { ticketId, timer, cancel });

  return {
    ticketId,
    deviceId,
    sourceRevision: capturedRevision,
    isCancelled: () =>
      cancelled || host.sourceRevision !== capturedRevision || !isHostAttachedToActiveWindow(host),
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
  devices?: readonly SmartDevice[],
): string[] {
  const updatedDeviceIds: string[] = [];
  for (const [devId, controls] of Object.entries(deviceFacets)) {
    let touched = false;
    for (const control of controls) {
      if (control.target?.kind !== "property") continue;
      const targetId = control.target.entityId;
      if (targetId === command.entityId) {
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
        continue;
      }
      if (
        command.kind === "setNumberValue" &&
        (targetId === `${command.entityId}#target_humidity` ||
          targetId === `${command.entityId}#position`)
      ) {
        const nextVal = Math.max(0, Math.min(100, Math.round(command.value)));
        if (control.value !== nextVal) {
          control.value = nextVal;
          touched = true;
        }
      } else if (command.kind === "setSwitch" && targetId === `${command.entityId}#power`) {
        if (control.value !== command.isOn) {
          control.value = command.isOn;
          touched = true;
        }
      } else if (
        command.kind === "setSwitch" &&
        !command.isOn &&
        targetId === `${command.entityId}#play_pause`
      ) {
        if (control.value !== false) {
          control.value = false;
          touched = true;
        }
      } else if (command.kind === "pressButton" && targetId === `${command.entityId}#play_pause`) {
        const dev = devices?.find((d) => d.id === devId);
        const nextVal =
          dev?.kind.kind === "speaker"
            ? dev.kind.state === "playing"
            : !(control.value === true || control.value === 1);
        if (control.value !== nextVal) {
          control.value = nextVal;
          touched = true;
        }
      } else if (command.kind === "setSelectOption" && targetId === `${command.entityId}#source`) {
        const match = control.options.find((opt) => opt.label === command.option);
        const nextVal = match ? match.value : command.option;
        if (control.value !== nextVal) {
          control.value = nextVal;
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
          const roundedCurrent = haRoundedInt(k.currentHumidity);
          if (roundedCurrent !== null) parts.push(`${roundedCurrent}%`);
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
      } else if (command.kind === "pressButton") {
        k.state = k.state === "playing" ? "paused" : "playing";
      } else if (command.kind === "setSwitch" && !command.isOn) {
        k.state = "idle";
      }
    }
  }
}
