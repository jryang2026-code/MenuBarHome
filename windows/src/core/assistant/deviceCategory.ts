import type { SmartDevice } from "../models.js";

export type IntentCategory = "light" | "climate" | "heater" | "fan" | "airPurifier" | "dehumidifier" | "diffuser" | "plug" | "vacuum" | "tv" | "camera" | "other";


export function isAirPurifierDevice(dev: SmartDevice): boolean {
  if (dev.kind.kind !== "fan") return false;
  const m = dev.model.toLowerCase();
  return (
    m.includes("airp") ||
    m.includes("purifier") ||
    m.includes("airfresh") ||
    m.includes("humidifier") ||
    dev.name.includes("净化") ||
    dev.name.includes("空净") ||
    dev.name.includes("新风") ||
    dev.name.includes("加湿") ||
    dev.kind.pm25Density != null ||
    dev.kind.airQuality != null ||
    dev.kind.filterLifePercent != null
  );
}

/** The four name words `MijiaCore.IntentDeviceCategory` reads on a climate card. */
const HEATER_NAME_HINTS = ["电暖", "暖气", "取暖", "暖风"];

/**
 * True for the climate cards macOS calls a heater: a heating model, or one of those four words in
 * the name. 冷暖 alone is an air conditioner, not a heater.
 */
export function isHeaterDevice(dev: SmartDevice): boolean {
  if (dev.kind.kind !== "climate") return false;
  return (
    dev.model.includes("heater") ||
    dev.model.includes("blanket") ||
    HEATER_NAME_HINTS.some((hint) => dev.name.includes(hint))
  );
}

export function deviceCategory(dev: SmartDevice): IntentCategory {
  if (dev.kind.kind === "light") return "light";
  if (dev.kind.kind === "climate") return isHeaterDevice(dev) ? "heater" : "climate";
  if (dev.kind.kind === "fan" && dev.model.includes(".derh.")) return "dehumidifier";
  if (dev.kind.kind === "plug" && dev.model.includes(".diffuser.")) return "diffuser";
  if (dev.kind.kind === "fan") return isAirPurifierDevice(dev) ? "airPurifier" : "fan";
  if (dev.kind.kind === "plug") return "plug";
  if (dev.kind.kind === "vacuum") return "vacuum";
  if (dev.kind.kind === "camera") return "camera";
  return "other";
}

export function isAssistantControllable(cat: IntentCategory): boolean {
  return cat !== "other";
}
