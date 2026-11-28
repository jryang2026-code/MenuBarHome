import { sensorAlertSeverity, type AlertSeverity } from "./alertSeverity.js";
import { t } from "./i18n.js";
import type { DeviceKind, SmartDevice } from "./models.js";
import type { SafetyAlert, SensorAlertKind } from "./safetyAndHealth.js";
import type { TemperatureUnit } from "./temperature.js";

/** Fixed display order for the first-screen "我家现在" summary capsule row (R16 §1.3). */
export type HomeSummaryCapsuleKind = "alerts" | "lightsOn" | "doorsOpen" | "indoorTemp";

export interface HomeSummaryCapsule {
  readonly kind: HomeSummaryCapsuleKind;
  readonly count: number;
  readonly temperatureCelsius: number | null;
  readonly alertSeverity: AlertSeverity | null;
  readonly targetDeviceIds: readonly string[];
  readonly filterTag: DeviceKind["kind"] | null;
}

export interface HomeSummary {
  readonly capsules: readonly HomeSummaryCapsule[];
  readonly isEmpty: boolean;
}

const VALID_SENSOR_ALERT_KINDS: ReadonlySet<string> = new Set([
  "smoke",
  "gas",
  "leak",
  "contact",
  "motion",
  "vibration",
  "lock",
]);

function parseAlertSeverity(alert: Pick<SafetyAlert, "id">): AlertSeverity | null {
  if (!alert.id.startsWith("sensor:")) return null;
  const rest = alert.id.slice("sensor:".length);
  const colon = rest.indexOf(":");
  if (colon <= 0) return null;
  const rawKind = rest.slice(0, colon);
  if (!VALID_SENSOR_ALERT_KINDS.has(rawKind)) return null;
  return sensorAlertSeverity(rawKind as SensorAlertKind);
}

function roundHalfAwayFromZero(value: number): number {
  return value < 0 ? -Math.round(-value) : Math.round(value);
}

function uniqueOrdered(ids: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const id of ids) {
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

/**
 * Pure home-level summary aggregation mirrored from `Sources/MijiaCore/HomeSummary.swift`.
 * Both ends share `Tests/Fixtures/home_summary_golden.json`.
 */
export function computeHomeSummary(options: {
  readonly devices: readonly SmartDevice[];
  readonly alerts: readonly Pick<SafetyAlert, "id" | "deviceId">[];
  readonly lightMarkedSwitchIds?: ReadonlySet<string>;
}): HomeSummary {
  const { devices, alerts, lightMarkedSwitchIds } = options;
  const capsules: HomeSummaryCapsule[] = [];

  // 1. Active alerts (highest severity from shared AlertSeverity table drives color).
  if (alerts.length > 0) {
    const seenAlertIds = new Set<string>();
    const uniqueAlerts: Array<Pick<SafetyAlert, "id" | "deviceId">> = [];
    for (const alert of alerts) {
      if (seenAlertIds.has(alert.id)) continue;
      seenAlertIds.add(alert.id);
      uniqueAlerts.push(alert);
    }
    if (uniqueAlerts.length > 0) {
      const hasCritical = uniqueAlerts.some((alert) => parseAlertSeverity(alert) === "alert");
      const severity: AlertSeverity = hasCritical ? "alert" : "warning";
      const deviceIds = uniqueOrdered(uniqueAlerts.map((a) => a.deviceId));
      capsules.push({
        kind: "alerts",
        count: uniqueAlerts.length,
        temperatureCelsius: null,
        alertSeverity: severity,
        targetDeviceIds: deviceIds,
        filterTag: null,
      });
    }
  }

  // 2. Lights currently on (online lights + online plugs marked as lights).
  const lightDeviceIds: string[] = [];
  let hasNativeLight = false;
  for (const device of devices) {
    if (!device.isOnline) continue;
    if (device.kind.kind === "light" && device.kind.isOn) {
      lightDeviceIds.push(device.id);
      hasNativeLight = true;
    } else if (
      device.kind.kind === "plug" &&
      device.kind.isOn &&
      lightMarkedSwitchIds?.has(device.id)
    ) {
      lightDeviceIds.push(device.id);
    }
  }
  if (lightDeviceIds.length > 0) {
    capsules.push({
      kind: "lightsOn",
      count: lightDeviceIds.length,
      temperatureCelsius: null,
      alertSeverity: null,
      targetDeviceIds: lightDeviceIds,
      filterTag: hasNativeLight ? "light" : "plug",
    });
  }

  // 3. Doors / windows / covers currently open.
  const doorDeviceIds: string[] = [];
  let hasCover = false;
  for (const device of devices) {
    if (!device.isOnline) continue;
    let isOpen = false;
    if (device.kind.kind === "cover" && (device.kind.positionPercent ?? 0) > 0) {
      isOpen = true;
      hasCover = true;
    } else if (
      device.kind.kind === "sensor" &&
      (device.kind.safetyObservations ?? []).some((obs) => obs.kind === "contact" && obs.alarming)
    ) {
      isOpen = true;
    }
    if (isOpen) {
      doorDeviceIds.push(device.id);
    }
  }
  if (doorDeviceIds.length > 0) {
    capsules.push({
      kind: "doorsOpen",
      count: doorDeviceIds.length,
      temperatureCelsius: null,
      alertSeverity: null,
      targetDeviceIds: doorDeviceIds,
      filterTag: hasCover ? "cover" : "sensor",
    });
  }

  // 4. Indoor temperature (average of online sensor temperatures; fallback to climate/fan).
  const sensorTemps: Array<{ id: string; value: number }> = [];
  const fallbackTemps: Array<{ id: string; value: number; tag: DeviceKind["kind"] }> = [];
  for (const device of devices) {
    if (!device.isOnline) continue;
    if (device.kind.kind === "sensor" && typeof device.kind.temperature === "number" && Number.isFinite(device.kind.temperature)) {
      sensorTemps.push({ id: device.id, value: device.kind.temperature });
    } else if (
      device.kind.kind === "climate" &&
      typeof device.kind.currentTemperature === "number" &&
      Number.isFinite(device.kind.currentTemperature)
    ) {
      fallbackTemps.push({ id: device.id, value: device.kind.currentTemperature, tag: "climate" });
    } else if (
      device.kind.kind === "fan" &&
      typeof device.kind.temperature === "number" &&
      Number.isFinite(device.kind.temperature)
    ) {
      fallbackTemps.push({ id: device.id, value: device.kind.temperature, tag: "fan" });
    }
  }
  if (sensorTemps.length > 0) {
    const avg = sensorTemps.reduce((sum, entry) => sum + entry.value, 0) / sensorTemps.length;
    capsules.push({
      kind: "indoorTemp",
      count: sensorTemps.length,
      temperatureCelsius: avg,
      alertSeverity: null,
      targetDeviceIds: sensorTemps.map((entry) => entry.id),
      filterTag: "sensor",
    });
  } else if (fallbackTemps.length > 0) {
    const avg = fallbackTemps.reduce((sum, entry) => sum + entry.value, 0) / fallbackTemps.length;
    capsules.push({
      kind: "indoorTemp",
      count: fallbackTemps.length,
      temperatureCelsius: avg,
      alertSeverity: null,
      targetDeviceIds: fallbackTemps.map((entry) => entry.id),
      filterTag: fallbackTemps[0]!.tag,
    });
  }

  return {
    capsules,
    isEmpty: capsules.length === 0,
  };
}

export function formatHomeSummaryCapsuleTitle(
  capsule: HomeSummaryCapsule,
  temperatureUnit: TemperatureUnit = "celsius",
): string {
  switch (capsule.kind) {
    case "alerts":
      return capsule.count === 1
        ? t("1 条告警")
        : t("{count} 条告警", { count: capsule.count });
    case "lightsOn":
      return capsule.count === 1
        ? t("1 盏灯开着")
        : t("{count} 盏灯开着", { count: capsule.count });
    case "doorsOpen":
      return capsule.count === 1
        ? t("1 处门窗开着")
        : t("{count} 处门窗开着", { count: capsule.count });
    case "indoorTemp": {
      if (capsule.temperatureCelsius === null) return "";
      const displayValue =
        temperatureUnit === "fahrenheit"
          ? (capsule.temperatureCelsius * 9) / 5 + 32
          : capsule.temperatureCelsius;
      // Same precision as the header reading, so 25.8° up top never sits beside a rounded 26°.
      const celsius = capsule.temperatureCelsius;
      const text =
        temperatureUnit === "celsius" && Math.abs(celsius - Math.round(celsius)) >= 0.05
          ? displayValue.toFixed(1)
          : String(roundHalfAwayFromZero(displayValue));
      // Several sensors: say it is an average, so it does not read as contradicting the header's one room.
      return capsule.count > 1
        ? t("室内均温 {temp}°", { temp: text })
        : t("室内 {temp}°", { temp: text });
    }
  }
}
