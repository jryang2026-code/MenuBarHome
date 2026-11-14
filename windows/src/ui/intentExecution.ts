import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import {
  IntentValidator,
  UserHabitMemory,
  type HabitLastAction,
  type HabitRecordingReceipt,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import {
  MIOT_DEVICE_OFFLINE_CODE,
  classifyControlFailure,
  controlFailureUserMessage,
  isCancellationError,
} from "../core/controlFailure.js";
import {
  isDeviceActiveOn,
  type DeviceCommand,
  type DeviceIntent,
  type SmartDevice,
} from "../core/models.js";
import type { UndoAction, UndoStep } from "./appTypes.js";
import { inverseCommands } from "../core/commandEffects.js";
import { trText } from "../core/quickActions.js";

export type BatchStopReason = "undo" | "preempted" | "sourceChanged" | "cancelled";

export interface ExecuteIntentsOptions {
  readonly recordHabits?: boolean;
  /**
   * Maximum number of per-device batches in flight simultaneously within a phase.
   * Bulk actions ("一键全关" / quick actions) default to `1` so mid-batch undo halts before the
   * very next device (`HomeStore+Undo.swift` parity); general multi-device intents default to `2`.
   */
  readonly concurrency?: number;
  readonly batch?: RunningBatch;
}

let nextBatchSeq = 1;

/**
 * Cancellable token for an in-flight multi-device batch (`HomeStore.RunningBatch` parity).
 * Tracks which devices actually had commands dispatched (excluding refused/failed ones) so an
 * interruption via Undo or a newer batch halts remaining devices immediately and never sends
 * restore commands to devices whose turn had not arrived.
 */
export class RunningBatch {
  public readonly id: string;
  public readonly summary: string;
  public readonly sourceRevision: number;
  private stopped = false;
  private finished = false;
  private stopReasonValue: BatchStopReason | null = null;
  private readonly attemptedIds = new Set<string>();
  private readonly succeededIds = new Set<string>();
  private readonly failedIds = new Set<string>();
  private readonly acceptedCountByDevice = new Map<string, number>();
  private readonly liveSteps: UndoStep[] = [];
  private trackedUndoAction: UndoAction | null = null;
  private readonly stopListeners = new Set<(reason: BatchStopReason) => void>();
  private readonly inFlightPromises = new Set<Promise<void>>();

  constructor(args: { readonly summary: string; readonly sourceRevision: number; readonly id?: string }) {
    this.id = args.id ?? `batch_${nextBatchSeq++}`;
    this.summary = args.summary;
    this.sourceRevision = args.sourceRevision;
  }

  public get isStopped(): boolean {
    return this.stopped;
  }

  public get isFinished(): boolean {
    return this.finished;
  }

  public get stopReason(): BatchStopReason | null {
    return this.stopReasonValue;
  }

  public get attemptedDeviceIds(): ReadonlySet<string> {
    return this.attemptedIds;
  }

  public get succeededDeviceIds(): ReadonlySet<string> {
    return this.succeededIds;
  }

  public get failedDeviceIds(): ReadonlySet<string> {
    return this.failedIds;
  }

  public get steps(): readonly UndoStep[] {
    return this.liveSteps;
  }

  public stop(reason: BatchStopReason = "cancelled"): void {
    if (this.stopped) return;
    this.stopped = true;
    this.stopReasonValue = reason;
    for (const listener of [...this.stopListeners]) {
      try {
        listener(reason);
      } catch {}
    }
  }

  public onStop(listener: (reason: BatchStopReason) => void): () => void {
    if (this.stopped && this.stopReasonValue) {
      listener(this.stopReasonValue);
      return () => {};
    }
    this.stopListeners.add(listener);
    return () => {
      this.stopListeners.delete(listener);
    };
  }

  public hasDeviceFailed(deviceId: string): boolean {
    return this.failedIds.has(deviceId);
  }

  public recordAttempt(deviceId: string, inverses: readonly DeviceCommand[]): UndoStep | null {
    if (this.stopped) return null;
    this.attemptedIds.add(deviceId);
    if (inverses.length === 0) return null;
    const step: UndoStep = { deviceId, commands: [...inverses] };
    this.liveSteps.unshift(step);
    return step;
  }

  public recordSuccess(deviceId: string): void {
    this.attemptedIds.add(deviceId);
    this.succeededIds.add(deviceId);
    this.acceptedCountByDevice.set(deviceId, (this.acceptedCountByDevice.get(deviceId) ?? 0) + 1);
  }

  public recordFailure(deviceId: string, attemptedStep: UndoStep | null, isCancelled = false): void {
    if (!isCancelled) {
      this.failedIds.add(deviceId);
    }
    if (attemptedStep) {
      const idx = this.liveSteps.indexOf(attemptedStep);
      if (idx >= 0) {
        this.liveSteps.splice(idx, 1);
      }
    }
    if ((this.acceptedCountByDevice.get(deviceId) ?? 0) === 0) {
      this.attemptedIds.delete(deviceId);
    }
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

  public ownsUndoAction(action: UndoAction | null): boolean {
    return action !== null && (action === this.trackedUndoAction || action.steps === this.liveSteps);
  }

  public ensureLiveUndoAction(canUndo: boolean): UndoAction | null {
    if (!canUndo || this.liveSteps.length === 0) {
      this.trackedUndoAction = null;
      return null;
    }
    if (!this.trackedUndoAction) {
      this.trackedUndoAction = {
        summary: this.summary,
        steps: this.liveSteps,
        expiresAtMs: Date.now() + 10 * 60 * 1000,
      };
    }
    return this.trackedUndoAction;
  }

  public markFinished(): void {
    this.finished = true;
    this.stopListeners.clear();
  }
}

const runningBatchByHost = new WeakMap<object, RunningBatch>();

export function getRunningBatch(host: object): RunningBatch | null {
  const batch = runningBatchByHost.get(host) ?? null;
  return batch && !batch.isFinished ? batch : null;
}

export function cancelRunningBatch(host: object, reason: BatchStopReason = "cancelled"): boolean {
  const batch = getRunningBatch(host);
  if (!batch || batch.isStopped) return false;
  batch.stop(reason);
  return true;
}

function syncHostLiveUndo(host: MenuMijiaWindowsApp, batch: RunningBatch, canUndo: boolean): void {
  if (
    batch.isStopped ||
    batch.sourceRevision !== host.sourceRevision ||
    runningBatchByHost.get(host) !== batch
  ) {
    return;
  }
  const prev = host.lastUndoAction;
  const live = batch.ensureLiveUndoAction(canUndo);
  if (live) {
    if (!batch.ownsUndoAction(host.lastUndoAction)) {
      host.lastUndoAction = live;
      if (prev === null && typeof host.render === "function") {
        host.render();
      }
    }
  } else if (prev && batch.ownsUndoAction(prev)) {
    host.lastUndoAction = null;
  }
}

function deviceDisplayName(host: MenuMijiaWindowsApp, device: SmartDevice): string {
  const alias = host.layout?.aliases?.[device.id]?.trim();
  return alias || device.name;
}

function isAdjustmentCommand(command: DeviceCommand): boolean {
  switch (command.kind) {
    case "setLightBrightness":
    case "setLightColorTemp":
    case "setLightEffect":
    case "setClimateTemperature":
    case "setClimateMode":
    case "setClimateFanMode":
    case "setFanPercentage":
    case "setFanPresetMode":
    case "setFanOscillating":
    case "setNumberValue":
    case "mediaSetVolume":
    case "setMiotProperty":
      return true;
    default:
      return false;
  }
}

function isSequentialBulkSource(sourceLabel: string): boolean {
  const normalized = sourceLabel.trim().toLowerCase();
  return (
    sourceLabel === t("一键全关") ||
    sourceLabel === t("0ms 本地直达") ||
    normalized === "一键全关" ||
    normalized === "all off" ||
    normalized === "turn all off" ||
    normalized === "0ms 本地直达" ||
    normalized === "instant local"
  );
}

function formatAppliedCommandFailure(
  rawErrorOrBanner: unknown,
  deviceName: string,
  isDeviceOnline: boolean,
  adjustment: boolean,
  defaultFallback: string,
): string {
  const rawText =
    typeof rawErrorOrBanner === "string"
      ? rawErrorOrBanner.trim()
      : rawErrorOrBanner instanceof Error
        ? rawErrorOrBanner.message.trim()
        : "";
  const classified = classifyControlFailure(rawErrorOrBanner, { isDeviceOnline });
  if (!classified) {
    return rawText || defaultFallback;
  }
  return (
    controlFailureUserMessage(rawErrorOrBanner, {
      deviceName,
      isDeviceOnline,
      adjustment,
      fallback: rawText || defaultFallback,
    }) ?? (rawText || defaultFallback)
  );
}

export async function executeIntents(
  host: MenuMijiaWindowsApp,
  intents: readonly DeviceIntent[],
  replyText: string,
  sourceLabel: string,
  options: ExecuteIntentsOptions = {},
): Promise<boolean> {
  const sourceRevision = host.sourceRevision;
  const commands: Array<{ deviceId: string; command: DeviceCommand; intentIndex: number }> = [];
  const candidateIntents: Array<{ intent: DeviceIntent; commandCount: number; succeededCount: number }> = [];
  let failed = 0;
  let cancelledCount = 0;
  let failureMessage = "";

  for (const intent of intents) {
    if (intent.operation.kind === "activateScene") {
      const scene = host.scenes.find((s) => s.id === intent.targetId);
      if (scene) {
        const intentIndex = candidateIntents.length;
        candidateIntents.push({ intent, commandCount: 1, succeededCount: 0 });
        commands.push({
          deviceId: scene.id,
          command: { kind: "activateScene", entityId: scene.entityId },
          intentIndex,
        });
      }
      continue;
    }
    const dev = host.devices.find((d) => d.id === intent.targetId);
    if (!dev) continue;
    if (!dev.isOnline) {
      failed += 1;
      const name = deviceDisplayName(host, dev);
      failureMessage =
        controlFailureUserMessage(
          { code: MIOT_DEVICE_OFFLINE_CODE },
          { deviceName: name, isDeviceOnline: false },
        ) ?? `${name} (${t("离线")})`;
      continue;
    }
    const intentCommands = IntentValidator.commandsForIntent(intent, dev);
    if (intentCommands.length === 0) {
      failed += 1;
      failureMessage = t("无法找到指令对应的设备");
      continue;
    }
    const intentIndex = candidateIntents.length;
    candidateIntents.push({ intent, commandCount: intentCommands.length, succeededCount: 0 });
    for (const command of intentCommands) {
      commands.push({ deviceId: dev.id, command, intentIndex });
    }
  }

  const previousBatch = getRunningBatch(host);
  if (previousBatch && previousBatch !== options.batch) {
    previousBatch.stop("preempted");
  }

  const runningBatch =
    options.batch ?? new RunningBatch({ summary: replyText, sourceRevision });
  runningBatchByHost.set(host, runningBatch);

  let succeeded = 0;
  let canUndo = true;

  interface TargetBatch {
    readonly key: string;
    readonly items: Array<{ readonly deviceId: string; readonly command: DeviceCommand; readonly intentIndex: number }>;
  }
  const phases: TargetBatch[][] = [];
  let currentPhase: TargetBatch[] = [];
  let batchByDeviceId = new Map<string, TargetBatch>();
  for (let i = 0; i < commands.length; i += 1) {
    const item = commands[i]!;
    if (item.command.kind === "activateScene") {
      // Scene activations may mutate arbitrary devices; treat them as ordering barriers.
      if (currentPhase.length > 0) {
        phases.push(currentPhase);
        currentPhase = [];
        batchByDeviceId = new Map();
      }
      phases.push([{ key: `scene:${i}:${item.deviceId}`, items: [item] }]);
      continue;
    }
    let targetBatch = batchByDeviceId.get(item.deviceId);
    if (!targetBatch) {
      targetBatch = { key: `device:${item.deviceId}`, items: [] };
      batchByDeviceId.set(item.deviceId, targetBatch);
      currentPhase.push(targetBatch);
    }
    targetBatch.items.push(item);
  }
  if (currentPhase.length > 0) {
    phases.push(currentPhase);
  }

  const maxConcurrency = Math.max(
    1,
    Math.trunc(options.concurrency ?? (isSequentialBulkSource(sourceLabel) ? 1 : 2)),
  );

  try {
    for (const phase of phases) {
      if (runningBatch.isStopped) break;
      if (sourceRevision !== host.sourceRevision) {
        runningBatch.stop("sourceChanged");
        return false;
      }

      let nextIndex = 0;
      const runTargetBatch = async (targetBatch: TargetBatch): Promise<void> => {
        for (const { deviceId, command, intentIndex } of targetBatch.items) {
          if (runningBatch.isStopped) return;
          if (sourceRevision !== host.sourceRevision) {
            runningBatch.stop("sourceChanged");
            return;
          }

          // Scenes have no device row and no inverse; they simply run and count as applied (#113).
          if (command.kind === "activateScene") {
            const prevBanner = host.replyBanner;
            try {
              const ok = await host.applyCommand(command);
              if (ok) {
                succeeded += 1;
                const entry = candidateIntents[intentIndex];
                if (entry) entry.succeededCount += 1;
              } else {
                const rawBanner =
                  host.replyBanner !== prevBanner && host.replyBanner?.isError
                    ? host.replyBanner.text
                    : undefined;
                if (rawBanner !== undefined && isCancellationError(rawBanner)) {
                  host.replyBanner = prevBanner;
                  cancelledCount += 1;
                } else {
                  failed += 1;
                  failureMessage = formatAppliedCommandFailure(
                    rawBanner,
                    "",
                    true,
                    false,
                    "设备未响应",
                  );
                }
              }
            } catch (err) {
              if (isCancellationError(err)) {
                host.replyBanner = prevBanner;
                cancelledCount += 1;
              } else {
                failed += 1;
                failureMessage = formatAppliedCommandFailure(
                  err,
                  "",
                  true,
                  false,
                  err instanceof Error ? err.message : String(err),
                );
              }
            }
            continue;
          }

          const device = host.devices.find((d) => d.id === deviceId);
          if (!device) {
            failed += 1;
            failureMessage = t("设备列表已更新，请重新执行");
            continue;
          }

          const isMomentaryButton =
            command.kind === "setSwitch" && command.entityId.startsWith("button.");
          const inverses = isMomentaryButton ? [] : inverseCommands(device, command);
          if (!isMomentaryButton && inverses.length === 0) {
            canUndo = false;
          }

          const attemptedStep = runningBatch.recordAttempt(deviceId, inverses);
          syncHostLiveUndo(host, runningBatch, canUndo);

          const prevBanner = host.replyBanner;
          const devName = deviceDisplayName(host, device);
          const adjustment = isAdjustmentCommand(command);

          await runningBatch.trackInFlight(async () => {
            try {
              const ok = await host.applyCommand(command);
              if (sourceRevision !== host.sourceRevision) {
                runningBatch.stop("sourceChanged");
                return;
              }
              if (ok) {
                succeeded += 1;
                runningBatch.recordSuccess(deviceId);
                const entry = candidateIntents[intentIndex];
                if (entry) entry.succeededCount += 1;
                if (
                  device.kind.kind === "light" &&
                  (command.kind !== "setLightPower" || command.isOn)
                ) {
                  host.lastManuallyUsedLightId = device.id;
                }
                syncHostLiveUndo(host, runningBatch, canUndo);
              } else {
                const rawBanner =
                  host.replyBanner !== prevBanner && host.replyBanner?.isError
                    ? host.replyBanner.text
                    : undefined;
                if (rawBanner !== undefined && isCancellationError(rawBanner)) {
                  runningBatch.recordFailure(deviceId, attemptedStep, true);
                  host.replyBanner = prevBanner;
                  cancelledCount += 1;
                  syncHostLiveUndo(host, runningBatch, canUndo);
                } else {
                  runningBatch.recordFailure(deviceId, attemptedStep, false);
                  failed += 1;
                  failureMessage = formatAppliedCommandFailure(
                    rawBanner,
                    devName,
                    device.isOnline,
                    adjustment,
                    "设备未响应",
                  );
                  syncHostLiveUndo(host, runningBatch, canUndo);
                }
              }
            } catch (err) {
              if (sourceRevision !== host.sourceRevision) {
                runningBatch.stop("sourceChanged");
                return;
              }
              if (isCancellationError(err)) {
                runningBatch.recordFailure(deviceId, attemptedStep, true);
                host.replyBanner = prevBanner;
                cancelledCount += 1;
                syncHostLiveUndo(host, runningBatch, canUndo);
              } else {
                runningBatch.recordFailure(deviceId, attemptedStep, false);
                failed += 1;
                failureMessage = formatAppliedCommandFailure(
                  err,
                  devName,
                  device.isOnline,
                  adjustment,
                  err instanceof Error ? err.message : String(err),
                );
                syncHostLiveUndo(host, runningBatch, canUndo);
              }
            }
          });
        }
      };

      const workerCount = Math.min(maxConcurrency, phase.length);
      const workers = Array.from({ length: workerCount }, async () => {
        while (!runningBatch.isStopped) {
          const idx = nextIndex;
          if (idx >= phase.length) return;
          nextIndex += 1;
          const targetBatch = phase[idx];
          if (!targetBatch) return;
          await runTargetBatch(targetBatch);
        }
      });
      await Promise.allSettled(workers);

      if (sourceRevision !== host.sourceRevision) {
        runningBatch.stop("sourceChanged");
        return false;
      }
      if (runningBatch.isStopped) break;
    }

    if (runningBatch.isStopped) {
      if (runningBatch.stopReason === "cancelled" && runningBatchByHost.get(host) === runningBatch) {
        const finalSteps = [...runningBatch.steps];
        host.lastUndoAction =
          canUndo && finalSteps.length > 0
            ? {
                summary: replyText,
                steps: finalSteps,
                expiresAtMs: Date.now() + 10 * 60 * 1000,
              }
            : null;
        if (typeof host.render === "function") host.render();
      }
      return false;
    }

    const finalSteps = [...runningBatch.steps];
    if (succeeded > 0) {
      const succeededIntents = candidateIntents
        .filter((entry) => entry.succeededCount === entry.commandCount && entry.commandCount > 0)
        .map((entry) => entry.intent);
      // Only explicit user asks train habits, and only for intents that actually succeeded (#34/#113/#116).
      const habitReceipt =
        options.recordHabits && succeededIntents.length > 0
          ? recordHabits(host, succeededIntents)
          : null;
      // Scene activations have no inverse: an undo action must exist only when at least one
      // device step is restorable, otherwise Undo would report success without doing anything
      // (Codex #116 re-review).
      host.lastUndoAction =
        canUndo && finalSteps.length > 0
          ? {
              summary: replyText,
              steps: finalSteps,
              expiresAtMs: Date.now() + 10 * 60 * 1000,
              habitReceipt: habitReceipt ?? undefined,
            }
          : null;
    } else if (host.lastUndoAction && runningBatch.ownsUndoAction(host.lastUndoAction)) {
      host.lastUndoAction = null;
    }

    if (succeeded === 0 && failed === 0) {
      if (cancelledCount > 0) {
        return false;
      }
      host.replyBanner = {
        text: t("无法找到指令对应的设备"),
        source: t("控制失败"),
        isError: true,
      };
      if (typeof host.render === "function") host.render();
      return false;
    }

    host.replyBanner =
      failed > 0
        ? {
            text: t("已执行 {ok} 项，{failed} 项失败。{message}", {
              ok: succeeded,
              failed,
              message: failureMessage,
            }),
            source: t("控制失败"),
            isError: true,
          }
        : { text: replyText, source: sourceLabel };
    if (typeof host.render === "function") host.render();
    return failed === 0;
  } finally {
    runningBatch.markFinished();
    if (runningBatchByHost.get(host) === runningBatch) {
      runningBatchByHost.delete(host);
    }
  }
}

export async function executeSingleCommand(
  host: MenuMijiaWindowsApp,
  device: SmartDevice,
  command: DeviceCommand,
  summary: string,
  intent?: DeviceIntent,
  readBackPower = false,
): Promise<void> {
  const sourceRevision = host.sourceRevision;
  const inverses = inverseCommands(device, command);
  const prevBanner = host.replyBanner;
  const devName = deviceDisplayName(host, device);
  const adjustment = isAdjustmentCommand(command);

  let applied = false;
  try {
    applied = await host.applyCommand(command, readBackPower);
  } catch (err) {
    if (isCancellationError(err)) {
      host.replyBanner = prevBanner;
      return;
    }
    const msg =
      controlFailureUserMessage(err, {
        deviceName: devName,
        isDeviceOnline: device.isOnline,
        adjustment,
        fallback: err instanceof Error ? err.message : String(err),
      }) ?? trText("操作未生效", "Action failed");
    host.replyBanner = { text: msg, source: t("控制失败"), isError: true };
    if (typeof host.render === "function") host.render();
    return;
  }

  if (!applied) {
    const rawBanner =
      host.replyBanner !== prevBanner && host.replyBanner?.isError
        ? host.replyBanner.text
        : undefined;
    if (rawBanner !== undefined && isCancellationError(rawBanner)) {
      host.replyBanner = prevBanner;
      if (typeof host.render === "function") host.render();
      return;
    }
    if (rawBanner !== undefined) {
      const classified = classifyControlFailure(rawBanner, { isDeviceOnline: device.isOnline });
      if (classified && !classified.isCancellation) {
        const formatted = controlFailureUserMessage(rawBanner, {
          deviceName: devName,
          isDeviceOnline: device.isOnline,
          adjustment,
          fallback: rawBanner,
        });
        if (formatted) {
          host.replyBanner = {
            text: formatted,
            source: host.replyBanner?.source ?? t("控制失败"),
            isError: true,
          };
          if (typeof host.render === "function") host.render();
        }
      }
    }
    return;
  }

  if (sourceRevision !== host.sourceRevision) return;
  // Momentary buttons (Wake-on-LAN) complete without reporting an on/off state to compare.
  const isMomentaryButton = command.kind === "setSwitch" && command.entityId.startsWith("button.");
  // A cover motor write has no boolean power to read back; the accepted write is the
  // confirmation and applyCommand has already moved the card's optimistic position/motion.
  const isCoverMotorWrite = command.kind === "setSelectOption" && device.kind.kind === "cover";
  if (
    readBackPower &&
    !isMomentaryButton &&
    !isCoverMotorWrite &&
    !readBackMatches(host, device.id, intent)
  ) {
    host.replyBanner = { text: t("未能读回设备状态"), source: t("控制失败"), isError: true };
    if (typeof host.render === "function") host.render();
    return;
  }
  if (device.kind.kind === "light" && (command.kind !== "setLightPower" || command.isOn)) {
    host.lastManuallyUsedLightId = device.id;
  }
  const habitReceipt = intent ? recordHabits(host, [intent]) : null;
  host.lastUndoAction =
    inverses.length > 0
      ? {
          summary,
          steps: [{ deviceId: device.id, commands: inverses }],
          expiresAtMs: Date.now() + 10 * 60 * 1000,
          habitReceipt: habitReceipt ?? undefined,
        }
      : null;
  host.replyBanner = { text: summary, source: t("实时控制") };
  if (typeof host.render === "function") host.render();
}

export function readBackMatches(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  intent?: DeviceIntent,
): boolean {
  if (!intent || intent.operation.kind !== "power") return true;
  const current = host.devices.find((item) => item.id === deviceId);
  return current !== undefined && isDeviceActiveOn(current) === intent.operation.isOn;
}

/** Records manual card actions into the habit memory for the current time bucket (#113). */
export function recordHabits(
  host: MenuMijiaWindowsApp,
  intents: readonly DeviceIntent[],
): HabitRecordingReceipt | null {
  if (!host.settings.habitLearningEnabled || intents.length === 0) return null;
  const memory = new UserHabitMemory(
    host.settings.habitEntries,
    host.habitSequences(),
    host.lastHabitAction(),
  );
  const receipt = memory.record(intents, host.devices, host.scenes, new Date());
  if (receipt) saveHabitMemory(host, memory);
  return receipt;
}

/** Sequence entries and lastAction persist alongside the entries (ADR-0009). */
export function habitSequences(): HabitSequenceEntry[] {
  const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as {
      sequences?: HabitSequenceEntry[];
      lastAction?: HabitLastAction | null;
    };
    return Array.isArray(parsed.sequences) ? parsed.sequences : [];
  } catch {
    return [];
  }
}

export function lastHabitAction(): HabitLastAction | null {
  const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as { lastAction?: HabitLastAction | null };
    return parsed.lastAction ?? null;
  } catch {
    return null;
  }
}

export function saveHabitMemory(host: MenuMijiaWindowsApp, memory: UserHabitMemory): void {
  host.settings.habitEntries = [...memory.entries];
  host.saveSettings();
  try {
    localStorage.setItem(
      "menumijia.windows.habit.sequences.v1",
      JSON.stringify({
        sequences: memory.sequences,
        lastAction: memory.lastAction,
      }),
    );
  } catch {
    // Quota errors only cost the sequence context, never the entries.
  }
}

export function unrecordHabits(host: MenuMijiaWindowsApp, receipt: HabitRecordingReceipt): void {
  const memory = new UserHabitMemory(
    host.settings.habitEntries,
    host.habitSequences(),
    host.lastHabitAction(),
  );
  memory.unrecord(receipt);
  saveHabitMemory(host, memory);
}
