import { WINDOWS_TRIGGER_SOURCES, type AutomationTrigger, type SystemContextEventKind } from "../core/automationEngine.js";
import {
  readNativeExternalDisplayCount,
  readNativeFocusModeStatus,
  readNativeSystemPower,
} from "./transport.js";

/**
 * Windows system-signal sampling for power, external displays, and the slow focus/fullscreen
 * fallback.
 *
 * macOS keeps one `MacContextSnapshot` poll (10 s, `MacContextObserver.refreshInterval`) and lets
 * `MacContextAutomation.events` decide what changed. Windows uses the same cadence and the same
 * "the previous sample is the baseline" rule for power (`GetSystemPowerStatus`), external displays
 * (`QueryDisplayConfig`), and the ≥ 5 s fallback for `SHQueryUserNotificationState` (primary
 * fullscreen transitions are pushed immediately on `EVENT_SYSTEM_FOREGROUND`). Sleep, display
 * power, and camera/microphone usage are pushed from `system_events.rs` (power callbacks and
 * `CapabilityAccessManager` registry change notifications) and are never tight-polled here.
 *
 * A first sample never fires a rule. `AutomationEngine.primePowerBaseline` /
 * `primeExternalDisplayBaseline` / `primeFocusModeBaseline` seed the engine from it, mirroring
 * macOS, where a nil previous snapshot returns no events — so booting the app on battery power
 * must not run "power disconnected" rules.
 */

/** Same cadence as `MacContextObserver.refreshInterval` (also satisfies the ≥ 5 s focus fallback). */
export const SYSTEM_CONTEXT_POLL_INTERVAL_MS = 10_000;

export type SystemSignalKind = Extract<
  SystemContextEventKind,
  "powerChanged" | "externalDisplayChanged" | "mediaCaptureChanged" | "focusModeChanged"
>;

export interface SystemPowerSample {
  readonly hasBattery: boolean;
  /** `null` while Windows reports an unknown AC line status; never guessed. */
  readonly onExternalPower: boolean | null;
  /** `null` on a desktop (no battery) or while the charge level is unknown. */
  readonly batteryPercent: number | null;
}

export interface NativeSystemSignals {
  /** `null` when the native call was skipped or failed; the previous sample stays in effect. */
  readonly power: SystemPowerSample | null;
  readonly externalDisplayCount: number | null;
  readonly focusMode?: boolean | null;
}

export interface SystemSignalBaseline {
  readonly power: {
    readonly onExternalPower: boolean;
    readonly batteryPercent: number | null;
  } | null;
  readonly externalDisplayCount: number | null;
  readonly focusMode?: boolean | null;
}

export interface SystemSignalTransition {
  /** Non-null only when the AC state or the charge level actually changed. */
  readonly power: {
    readonly onExternalPower: boolean;
    readonly batteryPercent: number | null;
  } | null;
  /** Non-null only when the external display count actually changed. */
  readonly externalDisplayCount: number | null;
  /** Non-null only when the fullscreen/presentation/quiet-hours state actually changed. */
  readonly focusMode?: boolean | null;
}

const TRIGGER_SOURCES: Readonly<Record<string, readonly SystemContextEventKind[] | undefined>> =
  WINDOWS_TRIGGER_SOURCES;

/** Whether an enabled rule waits for this native signal (drives whether we sample/watch at all). */
export function triggerUsesSystemSignal(trigger: AutomationTrigger, kind: SystemSignalKind): boolean {
  const kinds = TRIGGER_SOURCES[trigger];
  return kinds ? kinds.includes(kind) : false;
}

export interface SystemSignalRuleLike {
  readonly trigger: AutomationTrigger;
  readonly isEnabled?: boolean;
}

export interface SystemSignalNeed {
  readonly power: boolean;
  readonly externalDisplayCount: boolean;
  readonly mediaCapture: boolean;
  readonly focusMode: boolean;
}

/**
 * Determines which native Windows system signals have at least one enabled automation rule
 * waiting for them.
 */
export function systemSignalNeed(rules: readonly SystemSignalRuleLike[]): SystemSignalNeed {
  let power = false;
  let externalDisplayCount = false;
  let mediaCapture = false;
  let focusMode = false;
  for (const rule of rules) {
    if (rule.isEnabled === false) continue;
    if (!power && triggerUsesSystemSignal(rule.trigger, "powerChanged")) {
      power = true;
    }
    if (!externalDisplayCount && triggerUsesSystemSignal(rule.trigger, "externalDisplayChanged")) {
      externalDisplayCount = true;
    }
    if (!mediaCapture && triggerUsesSystemSignal(rule.trigger, "mediaCaptureChanged")) {
      mediaCapture = true;
    }
    if (!focusMode && triggerUsesSystemSignal(rule.trigger, "focusModeChanged")) {
      focusMode = true;
    }
    if (power && externalDisplayCount && mediaCapture && focusMode) break;
  }
  return { power, externalDisplayCount, mediaCapture, focusMode };
}

const EMPTY_BASELINE: SystemSignalBaseline = {
  power: null,
  externalDisplayCount: null,
  focusMode: null,
};

function resolvePower(
  previous: SystemSignalBaseline["power"],
  next: SystemPowerSample | null,
): SystemSignalBaseline["power"] {
  const onExternalPower = next?.onExternalPower ?? previous?.onExternalPower ?? null;
  if (onExternalPower === null) return null;
  return {
    onExternalPower,
    batteryPercent: next ? next.batteryPercent : (previous?.batteryPercent ?? null),
  };
}

/** The baseline to keep for the next poll; an unavailable native value keeps the last known one. */
export function resolveSystemSignalBaseline(
  previous: SystemSignalBaseline | null,
  next: NativeSystemSignals,
): SystemSignalBaseline {
  const base = previous ?? EMPTY_BASELINE;
  const focusMode = next.focusMode ?? base.focusMode ?? null;
  return {
    power: resolvePower(base.power, next.power),
    externalDisplayCount: next.externalDisplayCount ?? base.externalDisplayCount,
    ...(focusMode !== null ? { focusMode } : {}),
  };
}

/**
 * What to dispatch for one sample. Anything that cannot be compared against a real previous
 * sample (first poll, a failed native call) produces no event at all.
 */
export function planSystemSignalTransition(
  previous: SystemSignalBaseline | null,
  next: NativeSystemSignals,
): SystemSignalTransition {
  const base = previous ?? EMPTY_BASELINE;
  const resolvedPower = resolvePower(base.power, next.power);
  const powerChanged =
    next.power !== null &&
    base.power !== null &&
    resolvedPower !== null &&
    (resolvedPower.onExternalPower !== base.power.onExternalPower ||
      resolvedPower.batteryPercent !== base.power.batteryPercent);
  const displayChanged =
    next.externalDisplayCount !== null &&
    base.externalDisplayCount !== null &&
    next.externalDisplayCount !== base.externalDisplayCount;
  const nextFocus = next.focusMode ?? null;
  const prevFocus = base.focusMode ?? null;
  const focusChanged = nextFocus !== null && prevFocus !== null && nextFocus !== prevFocus;
  return {
    power: powerChanged ? resolvedPower : null,
    externalDisplayCount: displayChanged ? next.externalDisplayCount : null,
    ...(focusChanged ? { focusMode: nextFocus } : {}),
  };
}

/** Reads only the signals a rule actually waits for, so an idle rule set costs no native calls. */
export async function readNativeSystemSignals(need: {
  readonly power: boolean;
  readonly externalDisplayCount: boolean;
  readonly focusMode?: boolean;
}): Promise<NativeSystemSignals> {
  const [power, externalDisplayCount, focusMode] = await Promise.all([
    need.power ? readNativeSystemPower() : Promise.resolve(null),
    need.externalDisplayCount ? readNativeExternalDisplayCount() : Promise.resolve(null),
    need.focusMode ? readNativeFocusModeStatus() : Promise.resolve(null),
  ]);
  return { power, externalDisplayCount, ...(focusMode !== null ? { focusMode } : {}) };
}
