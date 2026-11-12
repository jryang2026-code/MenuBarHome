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

/** Model substrings that disqualify a `plug` card from being treated as a switched light. */
const SWITCHED_LIGHT_EXCLUDED_MODELS = [
  ".diffuser.",
  "kettle",
  "waterdispenser",
  "cooker",
  "fryer",
  "oven",
  "microwave",
  "healthpot",
  "heater",
  "blanket",
  "bhf_light",
  "ptc",
  "steril",
  "germicid",
  "disinfect",
  "mosquito",
  "inskil",
  "valve",
  "lock",
] as const;

/** Name substrings (never bare "暖") that disqualify a `plug` card from switched-light classification. */
const SWITCHED_LIGHT_EXCLUDED_NAME_SUBSTRINGS = [
  "插座",
  "插排",
  "排插",
  "插线板",
  "转换器",
  "power strip",
  "powerstrip",
  "smart plug",
  "smartplug",
  "杀菌",
  "消毒",
  "紫外",
  "臭氧",
  "浴霸",
  "取暖",
  "电暖",
  "暖风",
  "暖气",
  "暖灯",
  "加热",
  "发热",
  "电热",
  "热水",
  "保温",
  "烤",
  "红外",
  "灭蚊",
  "驱蚊",
  "诱蚊",
  "捕蚊",
  "指示灯",
  "信号灯",
  "车库",
  "门锁",
  "阀门",
  "水壶",
  "饮水",
  "饭煲",
  "电锅",
  "炸锅",
  "烤箱",
  "微波",
  "养生壶",
  "晾衣",
  "开窗",
  "摄像",
  "监控",
  "扫地",
  "路由",
  "网关",
] as const;

const SWITCHED_LIGHT_EXCLUDED_ASCII_WORDS = new Set([
  "plug",
  "plugs",
  "outlet",
  "outlets",
  "socket",
  "sockets",
  "uv",
  "ultraviolet",
  "germicidal",
  "sterilizer",
  "steriliser",
  "sterilization",
  "sterilisation",
  "disinfect",
  "disinfection",
  "ozone",
  "heat",
  "heater",
  "heating",
  "warmer",
  "warming",
  "infrared",
  "ir",
  "ptc",
  "bath",
  "mosquito",
  "insect",
  "bug",
  "zapper",
  "indicator",
  "garage",
  "lock",
  "valve",
  "kettle",
  "cooker",
  "oven",
  "fryer",
  "microwave",
  "camera",
  "vacuum",
  "router",
  "gateway",
]);

const SWITCHED_LIGHT_POSITIVE_ASCII_WORDS = new Set([
  "light",
  "lights",
  "lighting",
  "lamp",
  "lamps",
  "bulb",
  "bulbs",
  "downlight",
  "downlights",
  "spotlight",
  "spotlights",
  "lightstrip",
  "lightstrips",
  "chandelier",
  "sconce",
  "lantern",
  "pendant",
]);

/**
 * True when a writable `plug` (smart wall switch / relay) semantically represents a room light,
 * matching macOS `SmartDevice.isSwitchedLight`.
 */
export function isSwitchedLightDevice(dev: SmartDevice): boolean {
  if (
    dev.kind.kind !== "plug" ||
    dev.kind.powerWritable === false ||
    dev.kind.switchEntityId.startsWith("button.")
  ) {
    return false;
  }

  const lowerModel = dev.model.toLowerCase();
  if (SWITCHED_LIGHT_EXCLUDED_MODELS.some((hint) => lowerModel.includes(hint))) {
    return false;
  }

  const lowerName = dev.name.trim().toLowerCase();
  const asciiWords = new Set(lowerName.split(/[^a-z]+/).filter(Boolean));
  if (SWITCHED_LIGHT_EXCLUDED_NAME_SUBSTRINGS.some((sub) => lowerName.includes(sub))) {
    return false;
  }
  for (const word of asciiWords) {
    if (SWITCHED_LIGHT_EXCLUDED_ASCII_WORDS.has(word)) return false;
  }

  if (lowerName.includes("灯") || lowerName.includes("照明")) {
    return true;
  }
  for (const word of asciiWords) {
    if (SWITCHED_LIGHT_POSITIVE_ASCII_WORDS.has(word)) return true;
  }
  return false;
}

export function deviceCategory(dev: SmartDevice): IntentCategory {
  if (dev.kind.kind === "light") return "light";
  if (dev.kind.kind === "climate") return isHeaterDevice(dev) ? "heater" : "climate";
  if (dev.kind.kind === "fan" && dev.model.includes(".derh.")) return "dehumidifier";
  if (dev.kind.kind === "plug" && dev.model.includes(".diffuser.")) return "diffuser";
  if (dev.kind.kind === "plug" && isSwitchedLightDevice(dev)) return "light";
  if (dev.kind.kind === "fan") return isAirPurifierDevice(dev) ? "airPurifier" : "fan";
  if (dev.kind.kind === "plug") return "plug";
  if (dev.kind.kind === "vacuum") return "vacuum";
  if (dev.kind.kind === "camera") return "camera";
  return "other";
}

export function isAssistantControllable(cat: IntentCategory): boolean {
  return cat !== "other";
}
