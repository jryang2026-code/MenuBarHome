import {
  SAFETY_SIGNAL_KINDS, SENSOR_ALERT_TO_SAFETY_SIGNAL, type SafetySignalKind,
} from "./capabilityReferenceVerdict.js";
import {
  SENSOR_ALERT_KINDS, sensorAlertEnabledByDefault, type SensorAlertKind, type SensorAlertPolicy,
} from "./safetyAndHealth.js";

/**
 * "安全与提醒" as the type selection reads it. Both sources answer the same question — which alerts
 * a closed device type must keep reading for — so the mapping lives here once instead of once per
 * platform (architecture.md §D, ruling 3).
 *
 * `enableSafetyAlerts` is the master switch of 安全与提醒's own block — the long-run, low-battery and
 * pinned-offline alerts — and each of those keeps only its own signal. The sensor alerts below it are
 * a separate block with their own switches, so a smoke or lock alert keeps its reads while the
 * master switch is off.
 */
export interface SafetySignalPrefs {
  readonly enableSafetyAlerts: boolean;
  readonly longRunningPlug: boolean;
  readonly longRunningClimate: boolean;
  readonly lowBattery: boolean;
  readonly favoriteOffline: boolean;
}

/** Every safety signal the host is currently evaluating, in the shared vocabulary's own order. */
export function safetySignalsForPrefs(prefs: SafetySignalPrefs, policy: SensorAlertPolicy): SafetySignalKind[] {
  const signals = new Set<SafetySignalKind>(safetySignalsForSensorPolicy(policy));
  if (prefs.enableSafetyAlerts) {
    if (prefs.longRunningPlug) {
      signals.add("longRunningPlug");
      signals.add("highPower");
    }
    if (prefs.longRunningClimate) signals.add("longRunningClimate");
    if (prefs.lowBattery) signals.add("lowBattery");
    if (prefs.favoriteOffline) signals.add("starredOffline");
  }
  return SAFETY_SIGNAL_KINDS.filter((kind) => signals.has(kind));
}

/** Every sensor-alert signal the host is currently evaluating, in the shared `SafetySignalKind` vocabulary. */
export function safetySignalsForSensorPolicy(policy: SensorAlertPolicy): SafetySignalKind[] {
  return SENSOR_ALERT_KINDS
    .filter((kind: SensorAlertKind) => policy.enabled[kind] ?? sensorAlertEnabledByDefault(kind))
    .map((kind) => SENSOR_ALERT_TO_SAFETY_SIGNAL[kind]);
}
