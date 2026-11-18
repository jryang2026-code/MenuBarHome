import { WINDOWS_TRIGGER_SOURCES, type AutomationTrigger, type SystemContextEventKind } from "../core/automationEngine.js";
import { readNativeExternalDisplayCount, readNativeSystemPower } from "./transport.js";

/**
 * Windows system-signal sampling for the power and external-display triggers.
 *
 * macOS keeps one `MacContextSnapshot` poll (10 s, `MacContextObserver.refreshInterval`) and lets
 * `MacContextAutomation.events` decide what changed. Windows uses the same cadence and the same
 * "the previous sample is the baseline" rule, but the two signals come from `system_events.rs`
 * (`GetSystemPowerStatus`, `QueryDisplayConfig`) instead of IOKit. Sleep and display power are
 * *not* sampled here: they are pushed from the native power callbacks in `system_events.rs`,
 * because a 10 s poll cannot observe either before the machine stops running timers.
 *
 * A first sample never fires a rule. `AutomationEngine.primePowerBaseline` /
 * `primeExternalDisplayBaseline` seed the engine from it, mirroring macOS, where a nil previous
 * snapshot returns no events — so booting the app on battery power must not run "power
 * disconnected" rules.
 */

/** Same cadence as `MacContextObserver.refreshInterval`. */
export const SYSTEM_CONTEXT_POLL_INTERVAL_MS = 10_000;

export type SystemSignalKind = Extract<SystemContextEventKind, "powerChanged" | "externalDisplayChanged">;

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
}

export interface SystemSignalBaseline {
  readonly power: {
    readonly onExternalPower: boolean;
    readonly batteryPercent: number | null;
  } | null;
  readonly externalDisplayCount: number | null;
}

export interface SystemSignalTransition {
  /** Non-null only when the AC state or the charge level actually changed. */
  readonly power: {
    readonly onExternalPower: boolean;
    readonly batteryPercent: number | null;
  } | null;
  /** Non-null only when the external display count actually changed. */
  readonly externalDisplayCount: number | null;
}

const TRIGGER_SOURCES: Readonly<Record<string, readonly SystemContextEventKind[] | undefined>> =
  WINDOWS_TRIGGER_SOURCES;

/** Whether an enabled rule waits for this native signal (drives whether we sample at all). */
export function triggerUsesSystemSignal(trigger: AutomationTrigger, kind: SystemSignalKind): boolean {
  const kinds = TRIGGER_SOURCES[trigger];
  return kinds ? kinds.includes(kind) : false;
}

const EMPTY_BASELINE: SystemSignalBaseline = { power: null, externalDisplayCount: null };

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
  return {
    power: resolvePower(base.power, next.power),
    externalDisplayCount: next.externalDisplayCount ?? base.externalDisplayCount,
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
  return {
    power: powerChanged ? resolvedPower : null,
    externalDisplayCount: displayChanged ? next.externalDisplayCount : null,
  };
}

/** Reads only the signals a rule actually waits for, so an idle rule set costs no native calls. */
export async function readNativeSystemSignals(need: {
  readonly power: boolean;
  readonly externalDisplayCount: boolean;
}): Promise<NativeSystemSignals> {
  const [power, externalDisplayCount] = await Promise.all([
    need.power ? readNativeSystemPower() : Promise.resolve(null),
    need.externalDisplayCount ? readNativeExternalDisplayCount() : Promise.resolve(null),
  ]);
  return { power, externalDisplayCount };
}
