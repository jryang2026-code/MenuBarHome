import type { SensorAlertKind } from "./safetyAndHealth.js";

/**
 * The two levels every alert surface agrees on (deep-dive R16 §1.5). macOS
 * `AlertSeverity.swift` mirrors this table; both ends read
 * `Tests/Fixtures/alert_severity_golden.json`.
 *
 * A lock is a security alarm rather than a door/window notice — it already notifies at high
 * priority — so it stays `alert`. `sensorAlertIsHazard` remains the separate 24/7 axis: a lock
 * alert still honors the away-only switch and does not fire on its first sample.
 */
export type AlertSeverity = "alert" | "warning";

export const ALERT_SEVERITIES: readonly AlertSeverity[] = ["alert", "warning"] as const;

/** The single kind-to-severity table shared with macOS. */
export function sensorAlertSeverity(kind: SensorAlertKind): AlertSeverity {
  switch (kind) {
    case "smoke":
    case "gas":
    case "leak":
    case "lock":
      return "alert";
    case "contact":
    case "motion":
    case "vibration":
      return "warning";
  }
}

/** `alert` sorts before `warning` where the activity stack orders rows. */
export function alertSeverityRank(severity: AlertSeverity): number {
  return severity === "alert" ? 0 : 1;
}
