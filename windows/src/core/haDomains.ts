import { deviceCategory } from "./assistant/deviceCategory.js";
import { speechLocale } from "./i18n.js";
import { DEVICE_PROFILES, matchesMiotFacetPattern, type DeviceProfiles } from "./miCloud/facets.js";
import type {
  ApplianceAction,
  ApplianceFanLevel,
  ApplianceLight,
  CoverSpec,
  DeviceCommand,
  DeviceKind,
  FacetControl,
  FacetKind,
  FacetOption,
  FacetRange,
  FacetTarget,
  SmartDevice,
} from "./models.js";

export type HARow = Record<string, unknown>;

export interface HAState {
  readonly entityId: string;
  readonly state: string;
  readonly attributes: HARow;
}

export function haText(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

export function haNumber(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

export function haRoundedInt(value: unknown): number | null {
  const num = haNumber(value);
  if (num === null) return null;
  const rounded = Math.round(num);
  return Number.isSafeInteger(rounded) ? rounded : null;
}

export function haIntFeatures(value: unknown): number | null {
  const num = haNumber(value);
  if (num === null) return null;
  const truncated = Math.trunc(num);
  return Number.isSafeInteger(truncated) ? truncated : null;
}

export function haStrings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

export function isHAStateAvailable(state: HAState | undefined): boolean {
  return state !== undefined && state.state !== "unavailable" && state.state !== "unknown";
}

export function haTr(zh: string, en: string): string {
  return speechLocale().toLowerCase().startsWith("en") ? en : zh;
}

export function haLockStatusText(state: HAState | undefined): string {
  if (!state || !isHAStateAvailable(state)) {
    return haTr("锁状态未知", "Lock status unknown");
  }
  switch (state.state.toLowerCase()) {
    case "locked":
      return haTr("已上锁", "Locked");
    case "unlocked":
    case "open":
      return haTr("已开锁", "Unlocked");
    case "locking":
      return haTr("正在上锁", "Locking");
    case "unlocking":
      return haTr("正在开锁", "Unlocking");
    case "jammed":
      return haTr("门锁卡住", "Jammed");
    default:
      return haTr("锁状态未知", "Lock status unknown");
  }
}

export function haCoverSubtype(deviceClass: string | null, name: string): CoverSpec["subtype"] {
  const rawClass = (deviceClass ?? "").trim().toLowerCase();
  switch (rawClass) {
    case "curtain":
    case "blind":
    case "shade":
    case "shutter":
    case "awning":
    case "damper":
      return "curtain";
    case "window":
      return "window-opener";
    case "garage":
    case "gate":
    case "door":
      return "garage-door";
    default:
      break;
  }
  const lower = name.toLowerCase();
  if (name.includes("晾衣") || name.includes("晒衣") || lower.includes("airer")) {
    return "clothes-airer";
  }
  if (
    name.includes("帘") ||
    lower.includes("curtain") ||
    lower.includes("blind") ||
    lower.includes("shade") ||
    lower.includes("shutter")
  ) {
    return "curtain";
  }
  if (name.includes("车库") || name.includes("大门") || lower.includes("garage") || lower.includes("gate")) {
    return "garage-door";
  }
  if (name.includes("窗") || lower.includes("window")) {
    return "window-opener";
  }
  return "window-opener";
}

const HA_BRIGHTNESS_COLOR_MODES = new Set([
  "brightness",
  "color_temp",
  "hs",
  "xy",
  "rgb",
  "rgbw",
  "rgbww",
  "white",
]);

// Home Assistant's `light.turn_on` emulates `color_temp_kelvin` on any colour-capable light
// (`color_temperature_to_hs` / `_to_rgbww`), so these modes all accept a colour temperature.
const HA_COLOR_TEMP_COLOR_MODES = new Set(["color_temp", "hs", "xy", "rgb", "rgbw", "rgbww"]);

// Legacy `supported_features` bits: SUPPORT_BRIGHTNESS, SUPPORT_COLOR_TEMP, SUPPORT_COLOR, SUPPORT_WHITE_VALUE.
const HA_LEGACY_SUPPORT_BRIGHTNESS = 1;
const HA_LEGACY_SUPPORT_COLOR_TEMP = 2;
const HA_LEGACY_SUPPORT_COLOR = 16;
const HA_LEGACY_SUPPORT_WHITE_VALUE = 128;

export function haLightCapabilityFlags(a: HARow): {
  readonly brightnessWritable?: false;
  readonly colorWritable?: false;
} {
  const hasColorTempAttr =
    haNumber(a.color_temp_kelvin) !== null ||
    haNumber(a.min_color_temp_kelvin) !== null ||
    haNumber(a.max_color_temp_kelvin) !== null ||
    haNumber(a.color_temp) !== null ||
    haNumber(a.min_mireds) !== null ||
    haNumber(a.max_mireds) !== null;
  if (Array.isArray(a.supported_color_modes)) {
    const colorModes = haStrings(a.supported_color_modes)
      .map((mode) => mode.trim().toLowerCase())
      .filter(Boolean);
    const brightnessWritable = colorModes.some((mode) => HA_BRIGHTNESS_COLOR_MODES.has(mode));
    const colorWritable = colorModes.some((mode) => HA_COLOR_TEMP_COLOR_MODES.has(mode));
    return {
      ...(brightnessWritable ? {} : { brightnessWritable: false as const }),
      ...(colorWritable ? {} : { colorWritable: false as const }),
    };
  }
  const colorMode = typeof a.color_mode === "string" ? a.color_mode.trim().toLowerCase() : "";
  const rawFeatures = haNumber(a.supported_features);
  let brightnessWritable: boolean;
  let colorWritable: boolean;
  if (colorMode === "onoff") {
    brightnessWritable = false;
    colorWritable = false;
  } else if (colorMode.length > 0 && colorMode !== "unknown") {
    brightnessWritable = HA_BRIGHTNESS_COLOR_MODES.has(colorMode);
    colorWritable = HA_COLOR_TEMP_COLOR_MODES.has(colorMode) || hasColorTempAttr;
  } else if (rawFeatures !== null) {
    const features = Math.trunc(rawFeatures);
    brightnessWritable =
      (features &
        (HA_LEGACY_SUPPORT_BRIGHTNESS |
          HA_LEGACY_SUPPORT_COLOR_TEMP |
          HA_LEGACY_SUPPORT_COLOR |
          HA_LEGACY_SUPPORT_WHITE_VALUE)) !==
        0 ||
      haNumber(a.brightness) !== null ||
      hasColorTempAttr;
    colorWritable =
      (features & (HA_LEGACY_SUPPORT_COLOR_TEMP | HA_LEGACY_SUPPORT_COLOR)) !== 0 || hasColorTempAttr;
  } else {
    // Nothing advertised either way (legacy integration, light off): keep the controls rather
    // than hide them on a guess.
    brightnessWritable = true;
    colorWritable = true;
  }
  return {
    ...(brightnessWritable ? {} : { brightnessWritable: false as const }),
    ...(colorWritable ? {} : { colorWritable: false as const }),
  };
}

export function buildCoverKind(
  coverState: HAState,
  entities: readonly HARow[],
  deviceName: string,
  batteryReading: number | null,
  claimed: Set<string>,
): { kind: DeviceKind; online: boolean } {
  claimed.add(coverState.entityId);
  const a = coverState.attributes;
  const coverEntry = entities.find((entry) => haText(entry.entity_id) === coverState.entityId);
  const friendlyName =
    typeof a.friendly_name === "string"
      ? a.friendly_name
      : haText(coverEntry?.name, haText(coverEntry?.original_name));
  const nameForInference = !deviceName || deviceName === "智能设备" ? friendlyName : deviceName;
  const rawPos = haRoundedInt(a.current_position);
  const roundedPos = rawPos !== null ? Math.max(0, Math.min(100, rawPos)) : null;
  const stateLower = coverState.state.toLowerCase();
  const positionPercent =
    roundedPos !== null
      ? roundedPos
      : stateLower === "open"
        ? 100
        : stateLower === "closed"
          ? 0
          : null;
  const features = haIntFeatures(a.supported_features);
  const bat = batteryReading ?? haNumber(a.battery_level) ?? haNumber(a.battery);
  const batteryPercent =
    bat !== null && Number.isSafeInteger(Math.round(bat)) ? Math.round(bat) : null;
  return {
    online: isHAStateAvailable(coverState),
    kind: {
      kind: "cover",
      entityId: coverState.entityId,
      subtype: haCoverSubtype(typeof a.device_class === "string" ? a.device_class : null, nameForInference),
      positionPercent,
      positionWritable: features !== null ? (features & 4) !== 0 : roundedPos !== null,
      openDescription: features !== null ? ((features & 1) !== 0 ? "Open" : null) : "Open",
      closeDescription: features !== null ? ((features & 2) !== 0 ? "Close" : null) : "Close",
      pauseDescription: features !== null ? ((features & 8) !== 0 ? "Pause" : null) : "Pause",
      batteryPercent,
      faultText: null,
      motion: stateLower === "opening" ? "opening" : stateLower === "closing" ? "closing" : "stopped",
    },
  };
}

export type HABinaryAlertKind = "leak" | "smoke" | "gas" | "contact" | "motion";

export function haBinarySensorKind(
  entity: HARow,
  states: ReadonlyMap<string, HAState>,
  allowObjectIdFallback = false,
): HABinaryAlertKind | null {
  const entityId = haText(entity.entity_id);
  if (!entityId.startsWith("binary_sensor.")) return null;
  if (entity.disabled_by != null || entity.hidden_by != null) return null;
  const category = haText(entity.entity_category).toLowerCase();
  if (category === "config" || category === "diagnostic") return null;
  const devClass = haText(states.get(entityId)?.attributes.device_class).trim().toLowerCase();
  switch (devClass) {
    case "moisture":
      return "leak";
    case "smoke":
      return "smoke";
    case "gas":
    case "co":
    case "carbon_monoxide":
      return "gas";
    case "door":
    case "window":
    case "opening":
    case "garage_door":
      return "contact";
    case "motion":
    case "occupancy":
    case "presence":
    case "vibration":
      return "motion";
    default:
      break;
  }
  if (!allowObjectIdFallback || devClass.length > 0) return null;
  const objectId = (entityId.split(".")[1] ?? "").toLowerCase();
  if (/(?:^|_)(?:water_leak|leak|moisture|flood)(?:_|$)/.test(objectId)) return "leak";
  if (/(?:^|_)(?:smoke)(?:_|$)/.test(objectId)) return "smoke";
  if (/(?:^|_)(?:gas|methane|carbon_monoxide)(?:_|$)/.test(objectId)) return "gas";
  if (/(?:^|_)(?:door|window|contact|magnet)(?:_|$)/.test(objectId)) return "contact";
  if (/(?:^|_)(?:motion|occupancy|presence|pir)(?:_|$)/.test(objectId)) return "motion";
  return null;
}

export function haBinarySensorStatusText(kind: HABinaryAlertKind, state: HAState | undefined): string {
  if (!state || !isHAStateAvailable(state)) {
    return haTr("状态未知", "Status unknown");
  }
  const active = state.state.toLowerCase() === "on";
  switch (kind) {
    case "leak":
      return active ? haTr("检测到漏水", "Leak detected") : haTr("正常", "Dry");
    case "smoke":
      return active ? haTr("检测到烟雾", "Smoke detected") : haTr("正常", "Clear");
    case "gas":
      return active ? haTr("检测到燃气", "Gas detected") : haTr("正常", "Clear");
    case "contact":
      return active ? haTr("已打开", "Open") : haTr("已关闭", "Closed");
    case "motion":
      return active ? haTr("有人", "Detected") : haTr("无人", "Clear");
  }
}

export function buildHumidifierKind(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
): { kind: DeviceKind; online: boolean } | null {
  const entry = entities.find((item) => haText(item.entity_id).startsWith("humidifier."));
  const humId = entry ? haText(entry.entity_id) : "";
  const st = humId ? states.get(humId) : undefined;
  if (!humId || !st) return null;

  const a = st.attributes;
  const online = isHAStateAvailable(st);
  const features = haIntFeatures(a.supported_features);
  const modes = haStrings(a.available_modes);
  const currentMode = typeof a.mode === "string" && a.mode.trim() !== "" ? a.mode : null;
  const targetHumidity = haRoundedInt(a.target_humidity) ?? haRoundedInt(a.humidity);
  const minH = haRoundedInt(a.min_humidity) ?? 0;
  const maxH = haRoundedInt(a.max_humidity) ?? 100;
  const step = Math.max(1, haRoundedInt(a.target_humidity_step) ?? 1);

  const humiditySensor = entities.find((item) => {
    const eid = haText(item.entity_id);
    return eid.startsWith("sensor.") && states.get(eid)?.attributes.device_class === "humidity";
  });
  const humiditySensorId = humiditySensor ? haText(humiditySensor.entity_id) : null;
  const humiditySensorState = humiditySensorId ? states.get(humiditySensorId) : undefined;
  const currentHumidity =
    haNumber(a.current_humidity) ??
    (isHAStateAvailable(humiditySensorState) ? haNumber(humiditySensorState?.state) : null);

  const tempSensor = entities.find((item) => {
    const eid = haText(item.entity_id);
    return eid.startsWith("sensor.") && states.get(eid)?.attributes.device_class === "temperature";
  });
  const tempSensorId = tempSensor ? haText(tempSensor.entity_id) : null;
  const tempSensorState = tempSensorId ? states.get(tempSensorId) : undefined;
  const currentTemp = isHAStateAvailable(tempSensorState) ? haNumber(tempSensorState?.state) : null;

  const modeWritable = online && (features !== null ? (features & 2) !== 0 && modes.length > 0 : modes.length > 0);
  claimed.add(humId);
  if (humiditySensorId) claimed.add(humiditySensorId);
  if (tempSensorId && currentTemp !== null) claimed.add(tempSensorId);

  const statusParts: string[] = [];
  if (currentHumidity !== null) statusParts.push(`${Math.round(currentHumidity)}%`);
  if (targetHumidity !== null) {
    statusParts.push(haTr(`目标 ${targetHumidity}%`, `Target ${targetHumidity}%`));
  }
  const statusText = statusParts.length > 0 ? statusParts.join(" · ") : null;

  return {
    online,
    kind: {
      kind: "appliance",
      entityId: humId,
      isOn: online && st.state === "on",
      powerPresent: true,
      powerWritable: online,
      currentMode,
      availableModes: modes,
      modeWritable,
      targetTemperature: null,
      currentTemperature: currentTemp,
      minTemp: minH,
      maxTemp: maxH,
      step,
      temperatureWritable: false,
      statusText,
      faultText: null,
      remainingMinutes: null,
      startAction: null,
      pauseAction: null,
      stopAction: null,
      powerEntityId: humId,
      modeEntityId: humId,
      temperatureEntityId: humId,
      light: null,
      fanLevel: null,
      currentHumidity,
      symbolName: "humidity.fill",
      roomReading: true,
      heats: false,
    },
  };
}

export function buildWaterHeaterKind(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
): { kind: DeviceKind; online: boolean } | null {
  const entry = entities.find((item) => haText(item.entity_id).startsWith("water_heater."));
  const whId = entry ? haText(entry.entity_id) : "";
  const st = whId ? states.get(whId) : undefined;
  if (!whId || !st) return null;

  const a = st.attributes;
  const online = isHAStateAvailable(st);
  const modes = haStrings(a.operation_list);
  const currentMode =
    typeof a.operation_mode === "string" && a.operation_mode.trim() !== "" ? a.operation_mode : null;
  const target = haNumber(a.temperature);
  const tempSensor = entities.find((item) => {
    const eid = haText(item.entity_id);
    return eid.startsWith("sensor.") && states.get(eid)?.attributes.device_class === "temperature";
  });
  const tempSensorId = tempSensor ? haText(tempSensor.entity_id) : null;
  const tempSensorState = tempSensorId ? states.get(tempSensorId) : undefined;
  const current =
    haNumber(a.current_temperature) ??
    (isHAStateAvailable(tempSensorState) ? haNumber(tempSensorState?.state) : null);
  const minTemp = haNumber(a.min_temp) ?? 30;
  const maxTemp = haNumber(a.max_temp) ?? 60;
  const rawStep = haNumber(a.target_temp_step) ?? 1;
  const step = rawStep > 0 ? rawStep : 1;

  claimed.add(whId);
  if (tempSensorId && current !== null) claimed.add(tempSensorId);

  return {
    online,
    kind: {
      kind: "appliance",
      entityId: whId,
      isOn: online && st.state.toLowerCase() !== "off",
      powerPresent: true,
      powerWritable: online,
      currentMode,
      availableModes: modes,
      modeWritable: online && modes.length > 0,
      targetTemperature: target,
      currentTemperature: current,
      minTemp,
      maxTemp,
      step,
      temperatureWritable: online && target !== null,
      statusText: null,
      faultText: null,
      remainingMinutes: null,
      startAction: null,
      pauseAction: null,
      stopAction: null,
      powerEntityId: whId,
      modeEntityId: whId,
      temperatureEntityId: whId,
      light: null,
      fanLevel: null,
      currentHumidity: null,
      symbolName: "water.waves",
      roomReading: false,
      heats: true,
    },
  };
}

export function buildValveKind(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
): { kind: DeviceKind; online: boolean } | null {
  const entry = entities.find((item) => {
    const eid = haText(item.entity_id);
    const category = haText(item.entity_category).toLowerCase();
    return eid.startsWith("valve.") && category !== "config" && category !== "diagnostic";
  });
  const valveId = entry ? haText(entry.entity_id) : "";
  const st = valveId ? states.get(valveId) : undefined;
  if (!valveId || !st) return null;

  const a = st.attributes;
  const online = isHAStateAvailable(st);
  const stateLower = st.state.toLowerCase();
  const features = haIntFeatures(a.supported_features);
  const openWritable = features !== null ? (features & 1) !== 0 : true;
  const closeWritable = features !== null ? (features & 2) !== 0 : true;
  const canStop = features !== null ? (features & 8) !== 0 : false;
  const rawPos = haRoundedInt(a.current_position);
  const isOpen =
    online &&
    (stateLower === "open" ||
      stateLower === "opening" ||
      (rawPos !== null && rawPos > 0 && stateLower !== "closed" && stateLower !== "closing"));
  const devClass = typeof a.device_class === "string" ? a.device_class.trim().toLowerCase() : "";

  let statusText: string | null = null;
  if (stateLower === "opening") {
    statusText = haTr("正在打开", "Opening");
  } else if (stateLower === "closing") {
    statusText = haTr("正在关闭", "Closing");
  } else if (rawPos !== null && rawPos > 0 && rawPos < 100) {
    statusText = haTr(`开 ${rawPos}%`, `Open ${rawPos}%`);
  }

  claimed.add(valveId);

  return {
    online,
    kind: {
      kind: "appliance",
      entityId: valveId,
      isOn: isOpen,
      powerPresent: true,
      powerWritable: online && (isOpen ? closeWritable : openWritable),
      currentMode: null,
      availableModes: [],
      modeWritable: false,
      targetTemperature: null,
      currentTemperature: null,
      minTemp: 0,
      maxTemp: 100,
      step: 1,
      temperatureWritable: false,
      statusText,
      faultText: null,
      remainingMinutes: null,
      startAction: null,
      pauseAction: null,
      stopAction: canStop ? { kind: "stop", entityId: `${valveId}#stop` } : null,
      powerEntityId: valveId,
      modeEntityId: valveId,
      temperatureEntityId: valveId,
      light: null,
      fanLevel: null,
      currentHumidity: null,
      symbolName: devClass === "gas" ? "flame" : "drop.fill",
      roomReading: false,
      heats: true,
    },
  };
}

export function buildMediaPlayerKind(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
): { kind: DeviceKind; online: boolean } | null {
  const entry = entities.find((item) => haText(item.entity_id).startsWith("media_player."));
  const mediaId = entry ? haText(entry.entity_id) : "";
  const st = mediaId ? states.get(mediaId) : undefined;
  if (!mediaId || !st) return null;

  const a = st.attributes;
  const online = isHAStateAvailable(st);
  const eids = entities.map((item) => haText(item.entity_id));
  const volDouble = haNumber(a.volume_level) ?? 0.2;
  const volPct = Math.max(0, Math.min(100, haRoundedInt(volDouble * 100) ?? 20));
  const features = haIntFeatures(a.supported_features);
  // MediaPlayerEntityFeature: VOLUME_SET = 4, VOLUME_MUTE = 8.
  const volumeWritable = online && (features !== null ? (features & 4) !== 0 : true);
  const supportsMute = features !== null ? (features & 8) !== 0 : typeof a.is_volume_muted === "boolean";

  const muteSw = eids.find((eid) => eid.startsWith("switch.") && eid.includes("mute")) ?? null;
  const sleepSw = eids.find((eid) => eid.startsWith("switch.") && eid.includes("sleep_mode")) ?? null;
  const ttsNotify = eids.find((eid) => eid.startsWith("notify.") && eid.includes("play_text")) ?? null;
  const dirNotify =
    eids.find((eid) => eid.startsWith("notify.") && eid.includes("execute_text_directive")) ?? null;
  const playMusicBtn = eids.find((eid) => eid.startsWith("button.") && eid.includes("play_music")) ?? null;
  const stopAlarmBtn = eids.find((eid) => eid.startsWith("button.") && eid.includes("stop_alarm")) ?? null;
  const turnOnBtn = eids.find((eid) => eid.startsWith("button.") && eid.includes("turn_on")) ?? null;

  for (const id of [mediaId, muteSw, sleepSw, ttsNotify, dirNotify, playMusicBtn, stopAlarmBtn, turnOnBtn]) {
    if (id) claimed.add(id);
  }

  const isMuted = muteSw ? states.get(muteSw)?.state === "on" : Boolean(a.is_volume_muted);
  const isSleepMode = sleepSw ? states.get(sleepSw)?.state === "on" : false;
  const muteSwitchEntityId = muteSw ?? (supportsMute ? `${mediaId}#mute` : null);
  const rawState = st.state.toLowerCase();
  const state: "idle" | "playing" | "paused" =
    rawState === "playing" ? "playing" : rawState === "paused" ? "paused" : "idle";

  return {
    online,
    kind: {
      kind: "speaker",
      mediaEntityId: mediaId,
      state,
      volumePercent: volPct,
      isMuted,
      muteSwitchEntityId,
      sleepModeEntityId: sleepSw,
      isSleepMode,
      volumeWritable,
    },
  };
}

export function buildBinarySensorKind(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
  batteryReading: number | null,
  batteryEntityId: string | null,
  allowObjectIdFallback = false,
): { kind: DeviceKind; online: boolean } | null {
  const matched: Array<{ entityId: string; alertKind: HABinaryAlertKind }> = [];
  for (const entity of entities) {
    const kind = haBinarySensorKind(entity, states, allowObjectIdFallback);
    const entityId = haText(entity.entity_id);
    if (kind && states.has(entityId)) {
      matched.push({ entityId, alertKind: kind });
    }
  }
  if (matched.length === 0) return null;

  for (const item of matched) claimed.add(item.entityId);
  if (batteryEntityId) claimed.add(batteryEntityId);

  const online = matched.some((item) => isHAStateAvailable(states.get(item.entityId)));
  // Alarming ("on") observations take priority on the card subtitle so an active leak/smoke/open state shows first.
  const activeItem =
    matched.find((item) => states.get(item.entityId)?.state.toLowerCase() === "on") ??
    matched.find((item) => isHAStateAvailable(states.get(item.entityId))) ??
    matched[0]!;
  const statusText = haBinarySensorStatusText(activeItem.alertKind, states.get(activeItem.entityId));

  return {
    online,
    kind: {
      kind: "sensor",
      temperature: null,
      humidity: null,
      battery: batteryReading,
      statusText,
    },
  };
}

export function claimSafetyBinarySensors(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: Set<string>,
): void {
  for (const entity of entities) {
    if (haBinarySensorKind(entity, states, false) !== null) {
      claimed.add(haText(entity.entity_id));
    }
  }
}

export function auxiliaryEntitiesForCover(
  cover: HARow,
  allCovers: readonly HARow[],
  nonCoverEntities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
): HARow[] {
  const coverId = haText(cover.entity_id);
  const coverTokensById = new Map<string, Set<string>>();
  for (const entry of allCovers) {
    const eid = haText(entry.entity_id);
    const stem = eid.slice("cover.".length).toLowerCase();
    coverTokensById.set(eid, new Set(stem.split("_").filter(Boolean)));
  }
  const tokenSets = [...coverTokensById.values()];
  const commonTokens = new Set<string>(tokenSets[0] ?? []);
  for (const next of tokenSets.slice(1)) {
    for (const token of [...commonTokens]) {
      if (!next.has(token)) commonTokens.delete(token);
    }
  }
  const uniqueCoverTokens = new Map<string, Set<string>>();
  for (const [eid, tokens] of coverTokensById) {
    uniqueCoverTokens.set(
      eid,
      new Set([...tokens].filter((token) => !commonTokens.has(token))),
    );
  }

  const labelOf = (entry: HARow): string => {
    const eid = haText(entry.entity_id);
    const raw =
      (typeof entry.name === "string" && entry.name.trim() !== "" ? entry.name : null) ??
      (typeof states.get(eid)?.attributes.friendly_name === "string"
        ? (states.get(eid)!.attributes.friendly_name as string)
        : null) ??
      (typeof entry.original_name === "string" ? entry.original_name : "");
    return raw.trim().toLowerCase();
  };

  const matches = (candidateCover: HARow, aux: HARow): boolean => {
    const candId = haText(candidateCover.entity_id);
    const coverStem = candId.slice("cover.".length).toLowerCase();
    const auxId = haText(aux.entity_id);
    const dot = auxId.indexOf(".");
    const auxStem = (dot >= 0 ? auxId.slice(dot + 1) : auxId).toLowerCase();
    if (coverStem.length > 0 && auxStem.includes(coverStem)) return true;

    const distinguishing = uniqueCoverTokens.get(candId);
    if (distinguishing && distinguishing.size > 0) {
      const auxTokens = new Set(auxStem.split("_").filter(Boolean));
      if ([...distinguishing].every((token) => auxTokens.has(token))) return true;
    }

    const coverUid = haText(candidateCover.unique_id).toLowerCase();
    const auxUid = haText(aux.unique_id).toLowerCase();
    if (coverUid.length > 0 && auxUid.length > 0 && (auxUid.includes(coverUid) || coverUid.includes(auxUid))) {
      return true;
    }

    const coverLabel = labelOf(candidateCover);
    const auxLabel = labelOf(aux);
    if (coverLabel.length > 0 && auxLabel.length > 0 && auxLabel.includes(coverLabel)) {
      return true;
    }
    return false;
  };

  const isBatterySensor = (entity: HARow): boolean => {
    const eid = haText(entity.entity_id);
    if (!eid.startsWith("sensor.")) return false;
    const devClass = states.get(eid)?.attributes.device_class;
    if (typeof devClass === "string") return devClass === "battery";
    return eid.includes("battery_level");
  };

  const batteryCount = nonCoverEntities.filter(isBatterySensor).length;
  const matched: HARow[] = [];
  const shared: HARow[] = [];

  for (const aux of nonCoverEntities) {
    const matchingCovers = allCovers.filter((cand) => matches(cand, aux));
    if (matchingCovers.length === 1) {
      if (haText(matchingCovers[0]!.entity_id) === coverId) matched.push(aux);
      continue;
    }
    if (matchingCovers.some((cand) => haText(cand.entity_id) === coverId)) {
      matched.push(aux);
      continue;
    }
    if (matchingCovers.length === 0) {
      if (isBatterySensor(aux) && batteryCount > 1) continue;
      shared.push(aux);
    }
  }
  return [...matched, ...shared];
}

// MARK: - HAFacets (`更多设置`)

const ISO_TIMESTAMP_STATE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;
const MAINTENANCE_BUTTON_ID = /(?:^|_)(?:reboot|restart|reset|identify|calibrate)(?:_|$)/;
const LOW_RISK_HA_TOKENS = new Set(["led", "indicator", "buzzer", "mute", "display", "screen"]);
const LOW_RISK_HA_SUBSTRINGS = ["night-light", "child-lock", "physical-controls-locked", "auto-off"];

function isHighRiskHADevice(device: SmartDevice): boolean {
  const category = deviceCategory(device);
  if (category === "heater" || category === "plug") return true;
  if (device.kind.kind === "appliance") return device.kind.heats;
  if (device.kind.kind === "cover") return device.kind.subtype !== "curtain";
  if (device.kind.kind === "climate") return device.name.includes("热水器");
  return false;
}

function isLowRiskHAFacetName(name: string, facetsProfile: DeviceProfiles["facets"]): boolean {
  for (const pattern of facetsProfile.lowRiskWrites) {
    if (
      matchesMiotFacetPattern(name, [pattern]) ||
      matchesMiotFacetPattern(name, [`*-${pattern}`])
    ) {
      return true;
    }
  }
  const tokens = name.split("-").filter(Boolean);
  if (tokens.some((token) => LOW_RISK_HA_TOKENS.has(token))) return true;
  return LOW_RISK_HA_SUBSTRINGS.some((sub) => name.includes(sub));
}

function buildSyntheticPrimaryHAFacets(
  device: SmartDevice,
  states: ReadonlyMap<string, HAState>,
): FacetControl[] {
  const out: FacetControl[] = [];
  const k = device.kind;

  if (k.kind === "appliance" && k.entityId.startsWith("humidifier.")) {
    const humId = k.entityId;
    const st = states.get(humId);
    if (st) {
      const a = st.attributes;
      const online = isHAStateAvailable(st);
      const features = haIntFeatures(a.supported_features);
      const targetHumidity = haRoundedInt(a.target_humidity) ?? haRoundedInt(a.humidity);
      const minH = haRoundedInt(a.min_humidity) ?? 0;
      const maxH = haRoundedInt(a.max_humidity) ?? 100;
      const step = Math.max(1, haRoundedInt(a.target_humidity_step) ?? 1);
      const supportsTargetHumidity = features !== null ? (features & 1) !== 0 : targetHumidity !== null;
      if (supportsTargetHumidity && targetHumidity !== null && maxH > minH) {
        out.push({
          id: `${humId}#target_humidity`,
          kind: "slider",
          name: "target-humidity",
          title: null,
          serviceName: "humidifier",
          unit: "percentage",
          scale: null,
          value: targetHumidity,
          options: [],
          range: { min: minH, max: maxH, step },
          isWritable: online,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: `${humId}#target_humidity`, piid: 0 },
        });
      }
    }
  } else if (k.kind === "appliance" && k.entityId.startsWith("valve.")) {
    const valveId = k.entityId;
    const st = states.get(valveId);
    if (st) {
      const a = st.attributes;
      const online = isHAStateAvailable(st);
      const features = haIntFeatures(a.supported_features);
      const rawPos = haRoundedInt(a.current_position);
      if (features !== null && (features & 4) !== 0 && rawPos !== null) {
        out.push({
          id: `${valveId}#position`,
          kind: "slider",
          name: "valve-position",
          title: haTr("开度", "Position"),
          serviceName: haText(a.device_class).toLowerCase() === "gas" ? "gas-valve" : "water-valve",
          unit: "percentage",
          scale: null,
          value: Math.max(0, Math.min(100, rawPos)),
          options: [],
          range: { min: 0, max: 100, step: 1 },
          isWritable: online,
          writesByDefault: false,
          isConfirmedWrite: true,
          isHighValue: true,
          target: { kind: "property", entityId: `${valveId}#position`, piid: 0 },
        });
      }
    }
  } else if (k.kind === "speaker" && k.mediaEntityId.startsWith("media_player.")) {
    const mediaId = k.mediaEntityId;
    const st = states.get(mediaId);
    if (st) {
      const a = st.attributes;
      const online = isHAStateAvailable(st);
      const stateLower = st.state.toLowerCase();
      const features = haIntFeatures(a.supported_features);
      if (features === null || (features & (1 | 16384)) !== 0) {
        out.push({
          id: `${mediaId}#play_pause`,
          kind: "toggle",
          name: "play-pause",
          title: haTr("播放", "Play"),
          serviceName: "speaker",
          unit: null,
          scale: null,
          value: k.state === "playing",
          options: [],
          range: null,
          isWritable: online,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: `${mediaId}#play_pause`, piid: 0 },
        });
      }
      if ((features !== null && (features & (128 | 256)) !== 0) || stateLower === "off" || stateLower === "standby") {
        out.push({
          id: `${mediaId}#power`,
          kind: "toggle",
          name: "on",
          title: null,
          serviceName: "speaker",
          unit: null,
          scale: null,
          value: online && stateLower !== "off" && stateLower !== "standby",
          options: [],
          range: null,
          isWritable: online,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: `${mediaId}#power`, piid: 0 },
        });
      }
      const sourceList = haStrings(a.source_list);
      if (sourceList.length > 0 && (features === null || (features & 2048) !== 0)) {
        const currentSource = typeof a.source === "string" ? a.source : "";
        const selectedIdx = Math.max(0, sourceList.indexOf(currentSource));
        out.push({
          id: `${mediaId}#source`,
          kind: "select",
          name: "source",
          title: haTr("音源", "Source"),
          serviceName: "speaker",
          unit: null,
          scale: null,
          value: selectedIdx,
          options: sourceList.map((label, idx) => ({ value: idx, label })),
          range: null,
          isWritable: online,
          writesByDefault: true,
          isHighValue: true,
          target: { kind: "property", entityId: `${mediaId}#source`, piid: 0 },
        });
      }
    }
  }

  return out;
}

export function buildHAFacets(
  entities: readonly HARow[],
  states: ReadonlyMap<string, HAState>,
  claimed: ReadonlySet<string>,
  device: SmartDevice,
  profiles: DeviceProfiles = DEVICE_PROFILES,
): FacetControl[] {
  const syntheticControls = buildSyntheticPrimaryHAFacets(device, states);
  const controls: FacetControl[] = [];
  for (const entity of entities) {
    const entityId = haText(entity.entity_id);
    if (!entityId || claimed.has(entityId)) continue;
    if (entity.disabled_by != null || entity.hidden_by != null) continue;
    const state = states.get(entityId);
    if (!state) continue;
    const built = buildSingleHAFacet(entity, state, device, profiles);
    if (built) controls.push(built);
  }
  let remaining = Math.max(0, profiles.facets.maxVisible);
  for (let i = 0; i < controls.length && remaining > 0; i += 1) {
    const control = controls[i]!;
    if (!control.isWritable) continue;
    if (matchesMiotFacetPattern(control.name, profiles.facets.highValue)) {
      controls[i] = { ...control, isHighValue: true };
      remaining -= 1;
    }
  }
  return [...syntheticControls, ...controls];
}

function buildSingleHAFacet(
  entity: HARow,
  state: HAState,
  device: SmartDevice,
  profiles: DeviceProfiles,
): FacetControl | null {
  const entityId = haText(entity.entity_id);
  const dot = entityId.indexOf(".");
  if (dot <= 0) return null;
  const domain = entityId.slice(0, dot);
  const objectId = entityId.slice(dot + 1);
  if (!objectId) return null;

  const semantic = typeof entity.translation_key === "string" ? entity.translation_key.trim() : "";
  const rawName = semantic.length > 0 ? semantic : objectId;
  const name = rawName.replaceAll("_", "-");
  const objectName = objectId.replaceAll("_", "-");
  const category = haText(entity.entity_category).toLowerCase();
  if (category === "config") return null;

  if (
    matchesMiotFacetPattern(name, profiles.noise.properties) ||
    matchesMiotFacetPattern(objectName, profiles.noise.properties)
  ) {
    return null;
  }

  const writable =
    domain === "switch" ||
    domain === "input_boolean" ||
    domain === "select" ||
    domain === "number" ||
    domain === "button";
  if (!writable && domain !== "sensor" && domain !== "binary_sensor") {
    // `text.*` and primary-card domains stay strictly out of 更多设置.
    return null;
  }
  if (writable && category === "diagnostic") return null;

  const stateLower = state.state.toLowerCase();
  if (domain === "button") {
    if (stateLower === "unavailable") return null;
    const devClass = haText(state.attributes.device_class).toLowerCase();
    if (devClass === "restart" || devClass === "update" || devClass === "identify") return null;
    if (MAINTENANCE_BUTTON_ID.test(objectId.toLowerCase())) return null;
  } else if (!isHAStateAvailable(state)) {
    return null;
  }

  const highRiskDevice = isHighRiskHADevice(device);
  const highRiskType = matchesMiotFacetPattern(device.model, profiles.facets.highRiskTypes);
  const writesByDefault =
    writable && !highRiskDevice && !highRiskType && isLowRiskHAFacetName(name, profiles.facets);

  const rawFriendly = typeof state.attributes.friendly_name === "string" ? state.attributes.friendly_name.trim() : "";
  const title = rawFriendly.length > 0 ? rawFriendly : null;

  const make = (
    kind: FacetKind,
    value: unknown,
    options: readonly FacetOption[] = [],
    range: FacetRange | null = null,
    unit: string | null = null,
    target: FacetTarget | null = null,
  ): FacetControl => ({
    id: entityId,
    kind,
    name,
    title,
    serviceName: domain === "input_boolean" ? "switch" : domain,
    unit,
    scale: null,
    value,
    options,
    range,
    isWritable: writable,
    writesByDefault,
    isHighValue: false,
    target,
  });

  switch (domain) {
    case "switch":
    case "input_boolean": {
      if (stateLower !== "on" && stateLower !== "off") return null;
      return make("toggle", stateLower === "on", [], null, null, {
        kind: "property",
        entityId,
        piid: 0,
      });
    }
    case "select": {
      const options = haStrings(state.attributes.options);
      if (options.length === 0) return null;
      const selectedIdx = Math.max(0, options.indexOf(state.state));
      return make(
        "select",
        selectedIdx,
        options.map((label, idx) => ({ value: idx, label })),
        null,
        null,
        { kind: "property", entityId, piid: 0 },
      );
    }
    case "number": {
      const min = haNumber(state.attributes.min) ?? 0;
      const max = haNumber(state.attributes.max) ?? 100;
      const rawStep = haNumber(state.attributes.step) ?? 1;
      if (!(max > min)) return null;
      const step = rawStep > 0 ? rawStep : 1;
      const value = haNumber(state.state) ?? min;
      return make("slider", value, [], { min, max, step }, null, {
        kind: "property",
        entityId,
        piid: 0,
      });
    }
    case "button":
      return make("button", null, [], null, null, { kind: "action", entityId });
    case "sensor": {
      const devClass = haText(state.attributes.device_class).toLowerCase();
      if (devClass === "timestamp" || ISO_TIMESTAMP_STATE.test(state.state)) return null;
      const num = haNumber(state.state);
      const unit =
        typeof state.attributes.unit_of_measurement === "string"
          ? state.attributes.unit_of_measurement
          : null;
      return make("reading", num !== null ? num : state.state, [], null, unit, null);
    }
    case "binary_sensor": {
      const val = stateLower === "on" ? true : stateLower === "off" ? false : state.state;
      return make("reading", val);
    }
    default:
      return null;
  }
}

export function mapHAFacetCommand(
  command: DeviceCommand,
  deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>,
): DeviceCommand {
  if (command.kind !== "setMiotProperty") return command;
  if (command.entityId.startsWith("miot:")) {
    throw new Error("setMiotProperty is a Xiaomi-only command");
  }
  const hashIdx = command.entityId.indexOf("#");
  const baseEntityId = hashIdx >= 0 ? command.entityId.slice(0, hashIdx) : command.entityId;
  const subKey = hashIdx >= 0 ? command.entityId.slice(hashIdx + 1) : "";
  const dot = baseEntityId.indexOf(".");
  const domain = dot > 0 ? baseEntityId.slice(0, dot) : "";

  const resolveSelectOption = (): string => {
    let option: string | null = typeof command.value === "string" ? command.value : null;
    if (option === null && typeof command.value === "number" && deviceFacets) {
      const idx = Math.trunc(command.value);
      for (const list of Object.values(deviceFacets)) {
        const matched = list.find(
          (facet) => facet.target?.kind === "property" && facet.target.entityId === command.entityId,
        );
        const found = matched?.options.find((item) => item.value === idx);
        if (found) {
          option = found.label;
          break;
        }
      }
    }
    if (!option) throw new Error(`Invalid Home Assistant select option for ${command.entityId}`);
    return option;
  };

  switch (domain) {
    case "switch":
    case "input_boolean":
      return {
        kind: "setSwitch",
        entityId: baseEntityId,
        isOn: command.value === true || command.value === 1 || command.value === "on",
      };
    case "valve": {
      if (subKey === "position") {
        const num = haNumber(command.value);
        if (num === null) throw new Error(`Invalid Home Assistant numeric value for ${command.entityId}`);
        return { kind: "setNumberValue", entityId: baseEntityId, value: num };
      }
      return {
        kind: "setSwitch",
        entityId: baseEntityId,
        isOn: command.value === true || command.value === 1 || command.value === "on",
      };
    }
    case "media_player": {
      if (subKey === "play_pause") {
        return { kind: "pressButton", entityId: baseEntityId };
      }
      if (subKey === "source") {
        return { kind: "setSelectOption", entityId: baseEntityId, option: resolveSelectOption() };
      }
      if (subKey === "power" || subKey === "mute" || subKey === "") {
        return {
          kind: "setSwitch",
          entityId: subKey === "mute" ? `${baseEntityId}#mute` : baseEntityId,
          isOn: command.value === true || command.value === 1 || command.value === "on",
        };
      }
      throw new Error(`Unsupported Home Assistant media_player facet for ${command.entityId}`);
    }
    case "select":
      return { kind: "setSelectOption", entityId: baseEntityId, option: resolveSelectOption() };
    case "number":
    case "humidifier":
    case "water_heater": {
      const num = haNumber(command.value);
      if (num === null) throw new Error(`Invalid Home Assistant numeric value for ${command.entityId}`);
      return { kind: "setNumberValue", entityId: baseEntityId, value: num };
    }
    default:
      throw new Error(`Unsupported Home Assistant property write for ${command.entityId}`);
  }
}

// MARK: - Cached HA Home Validators (Speaker, Appliance, Generic, Facets)

function reqObj(value: unknown): HARow {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid cached HA object");
  }
  return value as HARow;
}
function reqStr(value: unknown): string {
  if (typeof value !== "string") throw new Error("Invalid cached text");
  return value;
}
function reqNum(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Invalid cached number");
  return value;
}
function reqBool(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Invalid cached boolean");
  return value;
}
function nullStr(value: unknown): string | null {
  return value === null || value === undefined ? null : reqStr(value);
}
function nullNum(value: unknown): number | null {
  return value === null || value === undefined ? null : reqNum(value);
}
function reqStrs(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error("Invalid cached string list");
  return value.map(reqStr);
}

function cachedAction(value: unknown): ApplianceAction | null {
  if (value === null || value === undefined) return null;
  const raw = reqObj(value);
  if (raw.kind !== "start" && raw.kind !== "pause" && raw.kind !== "stop") {
    throw new Error("Invalid cached appliance action");
  }
  return { kind: raw.kind, entityId: reqStr(raw.entityId) };
}

function cachedLightSub(value: unknown): ApplianceLight | null {
  if (value === null || value === undefined) return null;
  const raw = reqObj(value);
  return {
    entityId: reqStr(raw.entityId),
    isOn: reqBool(raw.isOn),
    writable: reqBool(raw.writable),
  };
}

function cachedFanLevel(value: unknown): ApplianceFanLevel | null {
  if (value === null || value === undefined) return null;
  const raw = reqObj(value);
  return {
    entityId: reqStr(raw.entityId),
    current: nullStr(raw.current),
    options: reqStrs(raw.options),
    writable: reqBool(raw.writable),
  };
}

export function cachedFacetControl(value: unknown): FacetControl {
  const raw = reqObj(value);
  const kind = raw.kind;
  if (
    kind !== "toggle" &&
    kind !== "select" &&
    kind !== "slider" &&
    kind !== "reading" &&
    kind !== "button"
  ) {
    throw new Error("Invalid cached facet kind");
  }
  if (!Array.isArray(raw.options)) throw new Error("Invalid cached facet options");
  const options: FacetOption[] = raw.options.map((opt) => {
    const o = reqObj(opt);
    return { value: reqNum(o.value), label: reqStr(o.label) };
  });
  let range: FacetRange | null = null;
  if (raw.range !== null && raw.range !== undefined) {
    const r = reqObj(raw.range);
    range = { min: reqNum(r.min), max: reqNum(r.max), step: reqNum(r.step) };
  }
  let target: FacetTarget | null = null;
  if (raw.target !== null && raw.target !== undefined) {
    const t = reqObj(raw.target);
    if (t.kind === "property") {
      target = { kind: "property", entityId: reqStr(t.entityId), piid: reqNum(t.piid) };
    } else if (t.kind === "action") {
      target = { kind: "action", entityId: reqStr(t.entityId) };
    } else {
      throw new Error("Invalid cached facet target");
    }
  }
  return {
    id: reqStr(raw.id),
    kind,
    name: reqStr(raw.name),
    title: nullStr(raw.title),
    serviceName: reqStr(raw.serviceName),
    unit: nullStr(raw.unit),
    scale: nullNum(raw.scale),
    value: raw.value ?? null,
    options,
    range,
    isWritable: reqBool(raw.isWritable),
    writesByDefault: reqBool(raw.writesByDefault),
    ...(raw.isConfirmedWrite === true ? { isConfirmedWrite: true as const } : {}),
    isHighValue: reqBool(raw.isHighValue),
    target,
  };
}

export function cachedExtendedKind(k: HARow): DeviceKind {
  switch (k.kind) {
    case "speaker": {
      if (k.state !== "idle" && k.state !== "playing" && k.state !== "paused") {
        throw new Error("Invalid cached speaker state");
      }
      return {
        kind: "speaker",
        mediaEntityId: reqStr(k.mediaEntityId),
        state: k.state,
        volumePercent: reqNum(k.volumePercent),
        isMuted: reqBool(k.isMuted),
        muteSwitchEntityId: nullStr(k.muteSwitchEntityId),
        sleepModeEntityId: nullStr(k.sleepModeEntityId),
        isSleepMode: reqBool(k.isSleepMode),
        volumeWritable: reqBool(k.volumeWritable),
      };
    }
    case "appliance":
      return {
        kind: "appliance",
        entityId: reqStr(k.entityId),
        isOn: reqBool(k.isOn),
        powerPresent: reqBool(k.powerPresent),
        powerWritable: reqBool(k.powerWritable),
        currentMode: nullStr(k.currentMode),
        availableModes: reqStrs(k.availableModes),
        modeWritable: reqBool(k.modeWritable),
        targetTemperature: nullNum(k.targetTemperature),
        currentTemperature: nullNum(k.currentTemperature),
        minTemp: reqNum(k.minTemp),
        maxTemp: reqNum(k.maxTemp),
        step: reqNum(k.step),
        temperatureWritable: reqBool(k.temperatureWritable),
        statusText: nullStr(k.statusText),
        faultText: nullStr(k.faultText),
        remainingMinutes: nullNum(k.remainingMinutes),
        startAction: cachedAction(k.startAction),
        pauseAction: cachedAction(k.pauseAction),
        stopAction: cachedAction(k.stopAction),
        powerEntityId: reqStr(k.powerEntityId),
        modeEntityId: reqStr(k.modeEntityId),
        temperatureEntityId: reqStr(k.temperatureEntityId),
        light: cachedLightSub(k.light),
        fanLevel: cachedFanLevel(k.fanLevel),
        currentHumidity: nullNum(k.currentHumidity),
        symbolName: nullStr(k.symbolName),
        roomReading: reqBool(k.roomReading),
        heats: reqBool(k.heats),
      };
    case "generic":
      return {
        kind: "generic",
        deviceType: reqStr(k.deviceType),
        typeTitle: reqStr(k.typeTitle),
        isOn: reqBool(k.isOn),
        powerControl:
          k.powerControl === null || k.powerControl === undefined
            ? null
            : cachedFacetControl(k.powerControl),
        isReadOnly: reqBool(k.isReadOnly),
        readouts: reqStrs(k.readouts),
        ...(k.alerts !== undefined ? { alerts: reqStrs(k.alerts) } : {}),
        symbolName: nullStr(k.symbolName),
      };
    default:
      throw new Error("Invalid cached device kind");
  }
}

export function cachedDeviceFacets(
  value: unknown,
): Readonly<Record<string, readonly FacetControl[]>> | undefined {
  if (value === undefined) return undefined;
  const raw = reqObj(value);
  const out: Record<string, FacetControl[]> = {};
  for (const [deviceId, list] of Object.entries(raw)) {
    if (!Array.isArray(list)) throw new Error("Invalid cached device facets list");
    out[deviceId] = list.map(cachedFacetControl);
  }
  return out;
}
