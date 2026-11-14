import {
  auxiliaryEntitiesForCover,
  buildBinarySensorKind,
  buildCoverKind,
  buildHAFacets,
  buildHumidifierKind,
  buildMediaPlayerKind,
  buildValveKind,
  buildWaterHeaterKind,
  cachedDeviceFacets,
  cachedExtendedKind,
  claimSafetyBinarySensors,
  haBinarySensorKind,
  haLightCapabilityFlags,
  haLockStatusText,
  haNumber as number,
  haRoundedInt,
  haStrings as strings,
  haText as text,
  isHAStateAvailable,
  mapHAFacetCommand,
  type HABinaryAlertKind,
  type HARow as Row,
  type HAState,
} from "./haDomains.js";
import { sha256 } from "./miCloudCrypto.js";
import {
  deviceEnvironmentReading,
  environmentReadingPriority,
  type CoverSpec,
  type DeviceCommand,
  type DeviceKind,
  type FacetControl,
  type SensorSafetyObservationSpec,
  type SensorSpec,
  type SmartDevice,
  type SynthesizedHome,
} from "./models.js";

interface HASnapshot {
  areas: Row[];
  devices: Row[];
  entities: Row[];
  states: HAState[];
}
export interface HaServiceCall {
  domain: string;
  service: string;
  entity_id: string;
  data: Row;
}
export type HAInvoke = <T>(
  command: string,
  args: Record<string, unknown>,
) => Promise<T>;

function object(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid Home Assistant object");
  return Object.fromEntries(Object.entries(value));
}
function rows(value: unknown): Row[] {
  if (!Array.isArray(value)) throw new Error("Invalid Home Assistant list");
  return value.map(object);
}

/** `clock` and `block` contain the letters "lock" but are not door locks. */
function isLockModel(model: string): boolean {
  const lower = model.toLowerCase();
  if (lower.includes(".lock.") || lower.startsWith("lock.") || lower.endsWith(".lock")) return true;
  if (lower.includes("clock") || lower.includes("block")) return false;
  return lower.includes("lock");
}

function decode(value: unknown): HASnapshot {
  const raw = object(value);
  return {
    areas: rows(raw.areas),
    devices: rows(raw.devices),
    entities: rows(raw.entities),
    states: rows(raw.states).map((state) => {
      if (
        typeof state.entity_id !== "string" ||
        typeof state.state !== "string"
      )
        throw new Error("Invalid Home Assistant state");
      return {
        entityId: state.entity_id,
        state: state.state,
        attributes: object(state.attributes),
      };
    }),
  };
}

function requiredText(value: unknown): string {
  if (typeof value !== "string") throw new Error("Invalid cached text");
  return value;
}
function requiredNumber(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Invalid cached number");
  return value;
}
function requiredBoolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Invalid cached boolean");
  return value;
}
function nullableText(value: unknown): string | null {
  return value === null ? null : requiredText(value);
}
function nullableNumber(value: unknown): number | null {
  return value === null ? null : requiredNumber(value);
}
function nullableBoolean(value: unknown): boolean | null {
  return value === null ? null : requiredBoolean(value);
}
function requiredStrings(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error("Invalid cached string list");
  return value.map(requiredText);
}

function requiredCoverSubtype(value: unknown): CoverSpec["subtype"] {
  if (value === "curtain" || value === "window-opener" || value === "garage-door" || value === "clothes-airer") {
    return value;
  }
  throw new Error("Invalid cached cover subtype");
}

function requiredCoverMotion(value: unknown): CoverSpec["motion"] {
  if (value === "stopped" || value === "opening" || value === "closing") {
    return value;
  }
  throw new Error("Invalid cached cover motion");
}

function requiredSensorAlertKind(value: unknown): NonNullable<SensorSpec["alertKind"]> {
  if (
    value === "smoke" ||
    value === "gas" ||
    value === "leak" ||
    value === "contact" ||
    value === "motion" ||
    value === "vibration" ||
    value === "lock"
  ) {
    return value;
  }
  throw new Error("Invalid cached sensor alert kind");
}

function resolveHASafetyAlertKind(
  entities: readonly Row[],
  states: ReadonlyMap<string, HAState>,
  allowObjectIdFallback: boolean,
): NonNullable<SensorSpec["alertKind"]> | undefined {
  const readable: Array<{ entityId: string; alertKind: HABinaryAlertKind }> = [];
  for (const entity of entities) {
    const kind = haBinarySensorKind(entity, states, allowObjectIdFallback);
    const entityId = text(entity.entity_id);
    if (kind !== null && states.has(entityId)) readable.push({ entityId, alertKind: kind });
  }
  if (readable.length === 0) return undefined;
  const active =
    readable.find((item) => states.get(item.entityId)?.state.toLowerCase() === "on") ??
    readable.find((item) => isHAStateAvailable(states.get(item.entityId))) ??
    readable[0]!;
  return active.alertKind;
}

function resolveHASafetyObservations(
  entities: readonly Row[],
  states: ReadonlyMap<string, HAState>,
  allowObjectIdFallback: boolean,
): SensorSafetyObservationSpec[] {
  const out: SensorSafetyObservationSpec[] = [];
  for (const entity of entities) {
    const kind = haBinarySensorKind(entity, states, allowObjectIdFallback);
    const entityId = text(entity.entity_id);
    const st = entityId ? states.get(entityId) : undefined;
    if (kind !== null && st && isHAStateAvailable(st)) {
      out.push({ entityId, kind, alarming: st.state.toLowerCase() === "on" });
    }
  }
  return out;
}

function requiredSafetyObservations(value: unknown): SensorSafetyObservationSpec[] {
  if (!Array.isArray(value)) throw new Error("Invalid cached safety observations");
  return value.map((item) => {
    const rec = object(item);
    return {
      entityId: requiredText(rec.entityId),
      kind: requiredSensorAlertKind(rec.kind),
      alarming: requiredBoolean(rec.alarming),
    };
  });
}

function cachedKind(value: unknown): DeviceKind {
  const k = object(value);
  switch (k.kind) {
    case "light": return { kind: "light", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), brightnessPercent: nullableNumber(k.brightnessPercent), colorTempKelvin: nullableNumber(k.colorTempKelvin), minKelvin: requiredNumber(k.minKelvin), maxKelvin: requiredNumber(k.maxKelvin), currentEffect: nullableText(k.currentEffect), availableEffects: requiredStrings(k.availableEffects), ...(k.brightnessWritable !== undefined ? { brightnessWritable: requiredBoolean(k.brightnessWritable) } : {}), ...(k.colorWritable !== undefined ? { colorWritable: requiredBoolean(k.colorWritable) } : {}) };
    case "climate": return { kind: "climate", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), hvacMode: requiredText(k.hvacMode), availableModes: requiredStrings(k.availableModes), targetTemperature: requiredNumber(k.targetTemperature), currentTemperature: nullableNumber(k.currentTemperature), minTemp: requiredNumber(k.minTemp), maxTemp: requiredNumber(k.maxTemp), step: requiredNumber(k.step), fanMode: nullableText(k.fanMode), availableFanModes: requiredStrings(k.availableFanModes), ...(k.swingMode !== undefined ? { swingMode: nullableText(k.swingMode) } : {}), ...(k.availableSwingModes !== undefined ? { availableSwingModes: requiredStrings(k.availableSwingModes) } : {}) };
    case "fan": return { kind: "fan", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), percentage: nullableNumber(k.percentage), presetMode: nullableText(k.presetMode), availablePresetModes: requiredStrings(k.availablePresetModes), isOscillating: nullableBoolean(k.isOscillating), pm25Density: nullableNumber(k.pm25Density ?? null), airQuality: nullableText(k.airQuality ?? null), temperature: nullableNumber(k.temperature ?? null), humidity: nullableNumber(k.humidity ?? null), filterLifePercent: nullableNumber(k.filterLifePercent ?? null) };
    case "plug": return { kind: "plug", switchEntityId: requiredText(k.switchEntityId), isOn: requiredBoolean(k.isOn), powerWatts: nullableNumber(k.powerWatts), energyKwh: nullableNumber(k.energyKwh ?? null), childLockEntityId: nullableText(k.childLockEntityId), isChildLocked: requiredBoolean(k.isChildLocked) };
    case "fridge": return { kind: "fridge", modeEntityId: nullableText(k.modeEntityId), currentMode: requiredText(k.currentMode), availableModes: requiredStrings(k.availableModes), fridgeCurrentTemp: nullableNumber(k.fridgeCurrentTemp), fridgeTargetTemp: requiredNumber(k.fridgeTargetTemp), fridgeTargetEntityId: nullableText(k.fridgeTargetEntityId), freezerCurrentTemp: nullableNumber(k.freezerCurrentTemp), freezerTargetTemp: requiredNumber(k.freezerTargetTemp), freezerTargetEntityId: nullableText(k.freezerTargetEntityId) };
    case "vacuum": return { kind: "vacuum", entityId: requiredText(k.entityId), status: requiredText(k.status), battery: nullableNumber(k.battery), modeEntityId: nullableText(k.modeEntityId), currentMode: nullableText(k.currentMode), availableModes: requiredStrings(k.availableModes) };
    case "camera": return { kind: "camera", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), nightShot: nullableText(k.nightShot), availableNightShots: requiredStrings(k.availableNightShots), motionDetectionEntityId: nullableText(k.motionDetectionEntityId), isMotionDetectionOn: nullableBoolean(k.isMotionDetectionOn), streamEntityId: nullableText(k.streamEntityId), snapshotPath: null };
    case "cover": return { kind: "cover", entityId: requiredText(k.entityId), subtype: requiredCoverSubtype(k.subtype), positionPercent: nullableNumber(k.positionPercent), positionWritable: requiredBoolean(k.positionWritable), openDescription: nullableText(k.openDescription), closeDescription: nullableText(k.closeDescription), pauseDescription: nullableText(k.pauseDescription), batteryPercent: nullableNumber(k.batteryPercent), faultText: nullableText(k.faultText), motion: requiredCoverMotion(k.motion) };
    case "sensor": return { kind: "sensor", temperature: nullableNumber(k.temperature), humidity: nullableNumber(k.humidity), battery: nullableNumber(k.battery), ...(k.statusText !== undefined && k.statusText !== null ? { statusText: requiredText(k.statusText) } : {}), ...(k.alertKind !== undefined && k.alertKind !== null ? { alertKind: requiredSensorAlertKind(k.alertKind) } : {}), ...(k.safetyObservations !== undefined ? { safetyObservations: requiredSafetyObservations(k.safetyObservations) } : {}) };
    default: return cachedExtendedKind(k);
  }
}

export function parseCachedHAHome(value: unknown): { identity: string; home: SynthesizedHome } | null {
  try {
    const cache = object(value);
    const home = object(cache.home);
    const deviceFacets = cachedDeviceFacets(home.deviceFacets);
    return {
      identity: requiredText(cache.identity),
      home: {
        devices: rows(home.devices).map((d) => ({ id: requiredText(d.id), name: requiredText(d.name), roomId: requiredText(d.roomId), roomName: requiredText(d.roomName), model: requiredText(d.model), isOnline: requiredBoolean(d.isOnline), kind: cachedKind(d.kind) })),
        rooms: rows(home.rooms).map((r) => ({ id: requiredText(r.id), name: requiredText(r.name), deviceCount: requiredNumber(r.deviceCount) })),
        environmentReadings: rows(home.environmentReadings).map((r) => ({ id: requiredText(r.id), label: requiredText(r.label), roomName: requiredText(r.roomName), temperature: nullableNumber(r.temperature), humidity: nullableNumber(r.humidity), battery: nullableNumber(r.battery) })),
        scenes: rows(home.scenes).map((s) => ({ id: requiredText(s.id), name: requiredText(s.name), entityId: requiredText(s.entityId) })),
        ...(deviceFacets !== undefined ? { deviceFacets } : {}),
      },
    };
  } catch {
    return null;
  }
}

export function homeAssistantIdentity(baseURL: string, token: string): string | null {
  try {
    const trimmed = baseURL.trim();
    if (!trimmed || trimmed.includes("\\")) return null;
    // A raw control character (`\t`, `\n`, `\0`) smuggles a second origin past a naive comparison
    // and is not part of any URL a person types, so the identity refuses it outright.
    if (/[\x00-\x1f\x7f]/.test(trimmed)) return null;
    if (/%2e|%2f|%5c/i.test(trimmed)) return null;
    const schemeEnd = trimmed.indexOf("://");
    if (schemeEnd > 0) {
      const afterHostSlash = trimmed.indexOf("/", schemeEnd + 3);
      if (afterHostSlash >= 0) {
        const rawPath = trimmed.slice(afterHostSlash).split(/[?#]/, 1)[0] ?? "";
        if (rawPath.split("/").some((seg) => seg === "." || seg === "..")) return null;
      }
    }
    const url = new URL(trimmed);
    if (
      (url.protocol !== "http:" && url.protocol !== "https:") ||
      url.username ||
      url.password ||
      !url.hostname ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    if (/%2e|%2f|%5c/i.test(url.pathname)) return null;
    const segments = url.pathname.split("/").filter(Boolean);
    if (segments.some((seg) => seg === "." || seg === "..")) return null;
    // Only the real `/api` suffix is stripped: a subpath that happens to end in `/API` is a
    // reverse proxy's own prefix, and folding its case would rewrite the address it lives at.
    const normalizedSegments =
      segments.length > 0 && segments[segments.length - 1] === "api"
        ? segments.slice(0, -1)
        : segments;
    const basePath = normalizedSegments.length > 0 ? `/${normalizedSegments.join("/")}` : "";
    const digest = sha256(new TextEncoder().encode(token));
    return `${url.origin}${basePath}|${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  } catch {
    return null;
  }
}

export function homeAssistantCommand(
  command: DeviceCommand,
  devices: readonly SmartDevice[],
  deviceFacets?: Readonly<Record<string, readonly FacetControl[]>>,
): DeviceCommand {
  if (command.kind === "setMiotProperty") {
    return mapHAFacetCommand(command, deviceFacets);
  }
  if (command.kind !== "setClimatePower" || !command.isOn) return command;
  const device = devices.find((entry) => entry.kind.kind === "climate" && entry.kind.entityId === command.entityId);
  if (!device || device.kind.kind !== "climate") throw new Error("Home Assistant climate not found");
  const k = device.kind;
  const resumeMode = [k.hvacMode, command.resumeMode, ...k.availableModes].find(
    (mode) => mode !== "off" && mode !== "unknown" && mode !== "unavailable" && k.availableModes.includes(mode),
  );
  if (!resumeMode) throw new Error("Home Assistant climate has no supported resume mode");
  return { ...command, resumeMode };
}

function cleanHADeviceName(name: string, roomName: string): string {
  let cleanName = name
    .trim()
    .replace(/^(?:直流变频循环扇|米家踢脚线电暖器|Yeelight LED 彩光灯带)\s*/, "")
    .replace(/(?:  灯|  电暖器|  风扇|  音箱|  电视|  开关 开关|  窗帘)$/, "")
    .trim();
  if (cleanName === "吸顶灯" && roomName !== "全屋") {
    cleanName = `${roomName}吸顶灯`;
  }
  return cleanName || name.trim();
}

function buildKind(
  entities: Row[],
  states: Map<string, HAState>,
  model: string,
  deviceName: string,
  claimed: Set<string>,
  allowBinaryFallback = false,
): { kind: DeviceKind; online: boolean } | null {
  const find = (
    domain: string,
    predicate: (entity: Row) => boolean = () => true,
  ) => {
    const entity = entities.find(
      (entry) =>
        text(entry.entity_id).startsWith(`${domain}.`) && predicate(entry),
    );
    return entity ? states.get(text(entity.entity_id)) : undefined;
  };
  const findByTranslationOrSubstring = (
    domain: string,
    translationKeys: readonly string[],
    legacyContains: string,
  ) =>
    find(domain, (entry) => translationKeys.includes(text(entry.translation_key))) ??
    find(domain, (entry) => text(entry.entity_id).includes(legacyContains));

  const sensor = (metric: string) =>
    find("sensor", (entry) => {
      const state = states.get(text(entry.entity_id));
      const entityId = text(entry.entity_id);
      const tKey = text(entry.translation_key);
      if (metric === "air_quality") {
        return state?.attributes.device_class === "aqi" || state?.attributes.device_class === "air_quality" || tKey === "air_quality" || entityId.includes("air_quality");
      }
      if (state?.attributes.device_class === metric) return true;
      if (metric === "power") {
        if (state?.attributes.device_class === "energy") return false;
        return entityId.includes("electric_power") || (entityId.includes("power") && !entityId.includes("power_consumption"));
      }
      if (metric === "energy") {
        if (state?.attributes.device_class === "power") return false;
        return entityId.includes("power_consumption") || entityId.includes("energy");
      }
      if (metric === "pm25") {
        return /pm2[._]?5|pm25/.test(tKey) || /pm2[._]?5|pm25/.test(entityId);
      }
      if (metric === "filter_life") {
        return tKey.includes("filter_life") || entityId.includes("filter_life");
      }
      if (metric === "temperature") {
        return (tKey.includes("temperature") || entityId.includes("temperature")) && !entityId.includes("color_temperature");
      }
      return tKey.includes(metric) || entityId.includes(metric);
    });
  const claimSensor = (metric: string): HAState | undefined => {
    const found = sensor(metric);
    if (found) claimed.add(found.entityId);
    return found;
  };
  const reading = (metric: string, claim = false) =>
    number((claim ? claimSensor(metric) : sensor(metric))?.state);
  const sensorText = (metric: string, claim = false) => {
    const found = claim ? claimSensor(metric) : sensor(metric);
    return found && found.state !== "unknown" && found.state !== "unavailable" ? found.state : null;
  };
  const powerSwitch = find(
    "switch",
    (entry) =>
      !/motion|indicator|watermark|wdr|tracking|distortion/.test(
        text(entry.entity_id),
      ),
  );
  let state: HAState | undefined;
  let kind: DeviceKind;
  if ((state = find("climate"))) {
    claimed.add(state.entityId);
    const a = state.attributes;
    const modes = strings(a.hvac_modes);
    const swingMode = typeof a.swing_mode === "string" ? a.swing_mode : undefined;
    const swingModes = strings(a.swing_modes);
    kind = {
      kind: "climate",
      entityId: state.entityId,
      isOn: state.state !== "off" && state.state !== "unknown" && state.state !== "unavailable",
      hvacMode: state.state,
      availableModes: modes.length > 0 ? modes : ["cool", "heat", "dry", "fan_only", "off"],
      targetTemperature: number(a.temperature) ?? number(a.target_temp_low) ?? number(a.current_temperature) ?? 26,
      currentTemperature: number(a.current_temperature),
      minTemp: number(a.min_temp) ?? 16,
      maxTemp: number(a.max_temp) ?? 30,
      step: number(a.target_temp_step) ?? 1,
      fanMode: typeof a.fan_mode === "string" ? a.fan_mode : null,
      availableFanModes: strings(a.fan_modes),
      ...(swingMode !== undefined ? { swingMode } : {}),
      ...(swingModes.length > 0 ? { availableSwingModes: swingModes } : {}),
    };
  } else if (
    (state = find(
      "light",
      (entry) =>
        entry.entity_category !== "config" &&
        !text(entry.entity_id).endsWith("_indicator_light"),
    ))
  ) {
    claimed.add(state.entityId);
    const a = state.attributes,
      brightness = number(a.brightness),
      brightnessPct =
        brightness === null ? null : haRoundedInt((brightness / 255) * 100);
    kind = {
      kind: "light",
      entityId: state.entityId,
      isOn: state.state === "on",
      brightnessPercent:
        brightnessPct === null
          ? null
          : Math.max(1, Math.min(100, brightnessPct)),
      colorTempKelvin: haRoundedInt(a.color_temp_kelvin),
      minKelvin: haRoundedInt(a.min_color_temp_kelvin) ?? 2700,
      maxKelvin: haRoundedInt(a.max_color_temp_kelvin) ?? 6500,
      currentEffect: typeof a.effect === "string" ? a.effect : null,
      availableEffects: strings(a.effect_list),
      ...haLightCapabilityFlags(a),
    };
  } else if ((state = find("fan"))) {
    claimed.add(state.entityId);
    const a = state.attributes;
    kind = {
      kind: "fan",
      entityId: state.entityId,
      isOn: state.state === "on",
      percentage: haRoundedInt(a.percentage),
      presetMode: typeof a.preset_mode === "string" ? a.preset_mode : null,
      availablePresetModes: strings(a.preset_modes),
      isOscillating: typeof a.oscillating === "boolean" ? a.oscillating : null,
      temperature: reading("temperature", true) ?? number(a.temperature),
      humidity: reading("humidity", true) ?? number(a.humidity),
      pm25Density: reading("pm25", true) ?? number(a.pm25),
      airQuality: sensorText("air_quality", true) ?? (typeof a.air_quality === "string" ? a.air_quality : null),
      filterLifePercent: reading("filter_life", true) ?? number(a.filter_life_remaining),
    };
  } else if (entities.some((e) => text(e.entity_id).startsWith("humidifier."))) {
    return buildHumidifierKind(entities, states, claimed);
  } else if (entities.some((e) => text(e.entity_id).startsWith("water_heater."))) {
    return buildWaterHeaterKind(entities, states, claimed);
  } else if ((state = find("vacuum"))) {
    claimed.add(state.entityId);
    const mode = find("select", (entry) =>
      text(entry.translation_key) === "mode" || text(entry.entity_id).includes("mode"),
    );
    if (mode) claimed.add(mode.entityId);
    kind = {
      kind: "vacuum",
      entityId: state.entityId,
      status: state.state,
      battery: reading("battery", true) ?? number(state.attributes.battery_level),
      modeEntityId: mode?.entityId ?? null,
      currentMode: mode && mode.state !== "unknown" && mode.state !== "unavailable" ? mode.state : null,
      availableModes: strings(mode?.attributes.options),
    };
  } else if (
    model.includes("fridge") ||
    entities.some(
      (e) => text(e.entity_id).includes("midjd6") || text(e.translation_key) === "temperature_p_3",
    )
  ) {
    const mode = findByTranslationOrSubstring("select", ["mode"], "mode");
    const fridgeTemp = findByTranslationOrSubstring("sensor", ["temperature_p_3"], "temperature_p_3");
    const freezerTemp = findByTranslationOrSubstring("sensor", ["temperature_p_4"], "temperature_p_4");
    const fridgeTarget = findByTranslationOrSubstring("number", ["target_temperature_p_3"], "target_temperature_p_3");
    const freezerTarget = findByTranslationOrSubstring("number", ["target_temperature_p_4"], "target_temperature_p_4");
    for (const item of [mode, fridgeTemp, freezerTemp, fridgeTarget, freezerTarget]) {
      if (item) claimed.add(item.entityId);
    }
    const fCur = number(fridgeTemp?.state);
    const zCur = number(freezerTemp?.state);
    const fTgt = number(fridgeTarget?.state) ?? 4;
    const zTgt = number(freezerTarget?.state) ?? -18;
    const online = Boolean((mode && mode.state !== "unavailable" && mode.state !== "unknown") || fCur !== null);
    const modeOpts = strings(mode?.attributes.options);
    return {
      kind: {
        kind: "fridge",
        modeEntityId: mode?.entityId ?? null,
        currentMode: mode && mode.state !== "unavailable" && mode.state !== "unknown" ? mode.state : "手动",
        availableModes: modeOpts.length > 0 ? modeOpts : ["手动", "智能", "速冷", "速冻", "假日"],
        fridgeCurrentTemp: fCur,
        fridgeTargetTemp: fTgt,
        fridgeTargetEntityId: fridgeTarget?.entityId ?? null,
        freezerCurrentTemp: zCur,
        freezerTargetTemp: zTgt,
        freezerTargetEntityId: freezerTarget?.entityId ?? null,
      },
      online,
    };
  } else if (
    (state =
      find("camera") ??
      (model.includes("camera") || model.includes("cateye") || model.includes("doorbell")
        ? powerSwitch
        : undefined))
  ) {
    const camera = find("camera");
    const power = powerSwitch;
    const motion = find("switch", (entry) =>
      text(entry.entity_id).includes("motion"),
    );
    const night = find("select", (entry) =>
      /night|ir_mode/.test(text(entry.entity_id)),
    );
    for (const item of [camera, power, motion, night]) {
      if (item) claimed.add(item.entityId);
    }
    const powerId = power?.entityId ?? state.entityId;
    kind = {
      kind: "camera",
      entityId: night ? `${powerId}|${night.entityId}` : powerId,
      isOn: power ? power.state === "on" : state.state !== "off",
      nightShot: night && night.state !== "unknown" && night.state !== "unavailable" ? night.state : null,
      availableNightShots: strings(night?.attributes.options),
      motionDetectionEntityId: motion?.entityId ?? null,
      isMotionDetectionOn: motion ? motion.state === "on" : null,
      streamEntityId: camera?.entityId ?? null,
      snapshotPath:
        typeof camera?.attributes.entity_picture === "string"
          ? camera.attributes.entity_picture
          : typeof camera?.attributes.access_token === "string" && camera.entityId
            ? `/api/camera_proxy/${camera.entityId}?token=${camera.attributes.access_token}`
            : null,
    };
  } else if (
    (state = find(
      "cover",
      (entry) => entry.entity_category !== "config" && entry.entity_category !== "diagnostic",
    ))
  ) {
    return buildCoverKind(state, entities, deviceName, reading("battery", true), claimed);
  } else if (
    entities.some(
      (entry) =>
        text(entry.entity_id).startsWith("valve.") &&
        entry.entity_category !== "config" &&
        entry.entity_category !== "diagnostic",
    )
  ) {
    return buildValveKind(entities, states, claimed);
  } else if (
    // Companion switch.* entities must not hide the real lock state.
    isLockModel(model) ||
    entities.some((entry) => text(entry.entity_id).startsWith("lock."))
  ) {
    const lockState = find("lock");
    if (lockState) claimed.add(lockState.entityId);
    const battery = claimSensor("battery");
    const batteryFresh = isHAStateAvailable(battery);
    const lockFresh = isHAStateAvailable(lockState);
    return {
      kind: {
        kind: "sensor",
        temperature: null,
        humidity: null,
        battery: number(battery?.state),
        statusText: haLockStatusText(lockFresh ? lockState : undefined),
        alertKind: "lock",
      },
      online: lockFresh || batteryFresh,
    };
  } else if (
    !entities.some((entry) => text(entry.entity_id).startsWith("media_player.")) &&
    (state = find(
      "switch",
      (entry) =>
        entry.entity_category !== "config" &&
        entry.entity_category !== "diagnostic" &&
        (states.get(text(entry.entity_id))?.attributes.device_class === "outlet" ||
          (!/(?:^|_)(?:physical_controls_locked|child_lock|indicator|mute|sleep_mode)(?:_|$)/.test(
            text(entry.entity_id).split(".")[1] ?? "",
          ) &&
            (model.includes("plug") || (!sensor("temperature") && !sensor("humidity"))))),
    ))
  ) {
    claimed.add(state.entityId);
    const lock = find("switch", (entry) =>
      /child_lock|physical_controls_locked/.test(text(entry.entity_id)),
    );
    if (lock) claimed.add(lock.entityId);
    kind = {
      kind: "plug",
      switchEntityId: state.entityId,
      isOn: state.state === "on",
      powerWatts: reading("power", true),
      energyKwh: reading("energy", true),
      childLockEntityId: lock?.entityId ?? null,
      isChildLocked: lock?.state === "on",
    };
  } else if (entities.some((entry) => text(entry.entity_id).startsWith("media_player."))) {
    return buildMediaPlayerKind(entities, states, claimed);
  } else if (
    entities.length === 1 &&
    (state = find(
      "input_boolean",
      (entry) => entry.entity_category !== "config" && entry.entity_category !== "diagnostic",
    ))
  ) {
    claimed.add(state.entityId);
    kind = {
      kind: "plug",
      switchEntityId: state.entityId,
      isOn: state.state === "on",
      powerWatts: null,
      energyKwh: null,
      childLockEntityId: null,
      isChildLocked: false,
    };
  } else {
    const temperature = sensor("temperature"),
      humidity = sensor("humidity");
    state =
      [temperature, humidity].find((entry) => isHAStateAvailable(entry)) ??
      temperature ??
      humidity;
    if (state) {
      if (temperature) claimed.add(temperature.entityId);
      if (humidity) claimed.add(humidity.entityId);
      // macOS `applyingSafetyObservations` keeps a leak/smoke/contact watch on the same card as the
      // thermometer instead of dropping it, so the alert text rides along and the entities are
      // claimed out of 更多设置 (a read-only alarm row there would be noise).
      const safetyStatus = claimSafetyBinarySensors(entities, states, claimed);
      const alertKind = resolveHASafetyAlertKind(entities, states, false);
      const safetyObservations = resolveHASafetyObservations(entities, states, false);
      kind = {
        kind: "sensor",
        temperature: number(temperature?.state),
        humidity: number(humidity?.state),
        battery: reading("battery", true),
        ...(safetyStatus !== null ? { statusText: safetyStatus } : {}),
        ...(alertKind ? { alertKind } : {}),
        ...(safetyObservations.length > 0 ? { safetyObservations } : {}),
      };
    } else {
      const batState = sensor("battery");
      const binaryBuilt = buildBinarySensorKind(
        entities,
        states,
        claimed,
        number(batState?.state),
        batState?.entityId ?? null,
        allowBinaryFallback,
      );
      if (binaryBuilt) {
        const alertKind = resolveHASafetyAlertKind(entities, states, allowBinaryFallback);
        const safetyObservations = resolveHASafetyObservations(entities, states, allowBinaryFallback);
        return binaryBuilt.kind.kind === "sensor" && (alertKind || safetyObservations.length > 0)
          ? {
              ...binaryBuilt,
              kind: {
                ...binaryBuilt.kind,
                ...(alertKind ? { alertKind } : {}),
                ...(safetyObservations.length > 0 ? { safetyObservations } : {}),
              },
            }
          : binaryBuilt;
      }

      const primaryButtons = entities.filter((entry) => {
        const entityId = text(entry.entity_id);
        if (!entityId.startsWith("button.") || entry.entity_category != null) return false;
        const devClass = states.get(entityId)?.attributes.device_class;
        if (devClass === "restart" || devClass === "update" || devClass === "identify") return false;
        const objectId = entityId.slice("button.".length);
        return !/(?:^|_)(?:reboot|restart|reset|identify|calibrate)(?:_|$)/.test(objectId);
      });
      const buttonEntity =
        primaryButtons.find((entry) => text(entry.entity_id).includes("wake_on_lan")) ??
        primaryButtons[0];
      const buttonState = buttonEntity ? states.get(text(buttonEntity.entity_id)) : undefined;
      if (!buttonState) return null;
      claimed.add(buttonState.entityId);
      return {
        kind: {
          kind: "plug",
          switchEntityId: buttonState.entityId,
          isOn: false,
          powerWatts: null,
          energyKwh: null,
          childLockEntityId: null,
          isChildLocked: false,
        },
        online: buttonState.state !== "unavailable",
      };
    }
  }
  return {
    kind,
    online: isHAStateAvailable(state),
  };
}

export class HomeAssistantSynthesizer {
  static synthesize(raw: unknown): SynthesizedHome {
    const snapshot = decode(raw);
    const states = new Map(
      snapshot.states.map((state) => [state.entityId, state]),
    );
    const registered = new Set(
      snapshot.devices.map((device) => text(device.id)).filter(Boolean),
    );
    const disabledDeviceIds = new Set(
      snapshot.devices
        .filter((device) => device.disabled_by != null)
        .map((device) => text(device.id))
        .filter(Boolean),
    );

    // CODING_STANDARDS.md §1: Record EVERY entity registry `entity_id` into `seenEntityIds`
    // (and `seenSceneEntityIds`) BEFORE skipping `disabled_by != null || hidden_by != null`
    // so disabled/hidden entities NEVER leak back through the `states` fallback pass.
    const seenEntityIds = new Set<string>();
    const seenSceneEntityIds = new Set<string>();
    const groups = new Map<string, Row[]>();
    const standaloneEntities: Row[] = [];
    const registryScenes: Array<{ id: string; entityId: string; name: string }> = [];

    const nonEmpty = (value: unknown, fallback = ""): string =>
      typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;

    for (const entity of snapshot.entities) {
      const entityId = text(entity.entity_id);
      if (!entityId) continue;
      seenEntityIds.add(entityId);
      const isSceneOrScript = /^(scene|script)\./.test(entityId);
      if (isSceneOrScript) {
        seenSceneEntityIds.add(entityId);
      }
      if (entity.disabled_by != null || entity.hidden_by != null) continue;
      const devId = text(entity.device_id);
      if (devId && disabledDeviceIds.has(devId)) continue;

      if (isSceneOrScript) {
        const sceneState = states.get(entityId);
        if (sceneState && isHAStateAvailable(sceneState)) {
          registryScenes.push({
            id: entityId,
            entityId,
            name: nonEmpty(
              entity.name,
              nonEmpty(entity.original_name, nonEmpty(sceneState.attributes.friendly_name, entityId)),
            ),
          });
        }
        continue;
      }

      if (devId && registered.has(devId)) {
        groups.set(devId, [...(groups.get(devId) ?? []), entity]);
      } else {
        standaloneEntities.push(entity);
      }
    }

    const devices: SmartDevice[] = [];
    const deviceFacets: Record<string, FacetControl[]> = {};
    const roomIds: Record<string, string> = {
      客厅: "ke_ting",
      书房: "shu_fang",
      卧室: "wo_shi",
      主卧: "zhu_wo",
      次卧: "ci_wo",
      小卧室: "xiao_wo_shi",
      厨房: "chu_fang",
      阳台: "yang_tai",
    };

    const resolveRoom = (areaId: string): { roomId: string; roomName: string } => {
      const rawRoomName = text(
        snapshot.areas.find((area) => area.area_id === areaId)?.name,
        "全屋",
      ).trim();
      const roomName = !rawRoomName || rawRoomName === "默认房间" ? "全屋" : rawRoomName;
      return {
        roomId: areaId || roomIds[roomName] || "other",
        roomName,
      };
    };

    const appendSingle = (
      id: string,
      cleanName: string,
      roomId: string,
      roomName: string,
      model: string,
      entities: Row[],
      allowBinaryFallback: boolean,
    ) => {
      const claimed = new Set<string>();
      const built = buildKind(entities, states, model, cleanName, claimed, allowBinaryFallback);
      if (!built) return;
      const card: SmartDevice = {
        id,
        name: cleanName,
        roomId,
        roomName,
        model,
        isOnline: built.online,
        kind: built.kind,
      };
      devices.push(card);
      const facets = buildHAFacets(entities, states, claimed, card);
      if (facets.length > 0) {
        deviceFacets[card.id] = facets;
      }
    };

    const append = (
      id: string,
      rawName: string,
      areaId: string,
      model: string,
      entities: Row[],
      allowBinaryFallback = false,
    ) => {
      const { roomId, roomName } = resolveRoom(areaId);
      const cleanName = cleanHADeviceName(rawName, roomName);
      const activeCovers = entities.filter((entity) => {
        const eid = text(entity.entity_id);
        return (
          eid.startsWith("cover.") &&
          entity.entity_category !== "config" &&
          entity.entity_category !== "diagnostic" &&
          states.has(eid)
        );
      });
      if (activeCovers.length > 1) {
        const probeClaimed = new Set<string>();
        const probe = buildKind(entities, states, model, cleanName, probeClaimed, allowBinaryFallback);
        if (probe?.kind.kind === "cover") {
          const nonCoverEntities = entities.filter((e) => !text(e.entity_id).startsWith("cover."));
          for (const coverEnt of activeCovers) {
            const coverId = text(coverEnt.entity_id);
            const trackId = `${id}#${coverId}`;
            const coverState = states.get(coverId);
            const rawTrackName = nonEmpty(
              coverEnt.name,
              nonEmpty(
                coverState?.attributes.friendly_name,
                nonEmpty(coverEnt.original_name, rawName),
              ),
            );
            const trackName = cleanHADeviceName(rawTrackName, roomName);
            const trackAux = auxiliaryEntitiesForCover(
              coverEnt,
              activeCovers,
              nonCoverEntities,
              states,
            );
            appendSingle(
              trackId,
              trackName,
              roomId,
              roomName,
              model,
              [coverEnt, ...trackAux],
              allowBinaryFallback,
            );
          }
          return;
        }
      }
      appendSingle(id, cleanName, roomId, roomName, model, entities, allowBinaryFallback);
    };

    for (const device of snapshot.devices) {
      const id = text(device.id),
        entities = groups.get(id) ?? [],
        model = text(device.model);
      if (
        device.disabled_by != null ||
        model === "hyperDLNA" ||
        model.startsWith("Apple TV") ||
        model.startsWith("lumi.gateway")
      ) {
        continue;
      }
      append(
        id,
        nonEmpty(device.name_by_user, nonEmpty(device.name, "智能设备")),
        text(
          device.area_id,
          text(entities.find((entity) => entity.area_id)?.area_id),
        ),
        model,
        entities,
        false,
      );
    }

    for (const entity of standaloneEntities) {
      const entityId = text(entity.entity_id);
      const state = states.get(entityId);
      if (!state) continue;
      append(
        entityId,
        nonEmpty(
          entity.name,
          nonEmpty(entity.original_name, nonEmpty(state.attributes.friendly_name, entityId)),
        ),
        text(entity.area_id),
        "",
        [entity],
        true,
      );
    }

    for (const state of snapshot.states) {
      if (seenEntityIds.has(state.entityId)) continue;
      append(
        state.entityId,
        nonEmpty(state.attributes.friendly_name, state.entityId),
        "",
        "",
        [{ entity_id: state.entityId }],
        true,
      );
    }

    const fallbackScenes = snapshot.states
      .filter(
        (state) =>
          /^(scene|script)\./.test(state.entityId) &&
          !seenSceneEntityIds.has(state.entityId) &&
          isHAStateAvailable(state),
      )
      .map((state) => ({
        id: state.entityId,
        entityId: state.entityId,
        name: nonEmpty(state.attributes.friendly_name, state.entityId),
      }));

    const scenes = [...registryScenes, ...fallbackScenes];
    const rooms = [...new Set(devices.map((device) => device.roomId))].map(
      (id) => ({
        id,
        name:
          devices.find((device) => device.roomId === id)?.roomName ?? "全屋",
        deviceCount: devices.filter((device) => device.roomId === id).length,
      }),
    );
    return {
      devices,
      rooms,
      scenes,
      environmentReadings: [...devices]
        .sort((a, b) => environmentReadingPriority(a.kind) - environmentReadingPriority(b.kind))
        .flatMap((device) => {
          const reading = deviceEnvironmentReading(device);
          return reading ? [reading] : [];
        }),
      ...(Object.keys(deviceFacets).length > 0 ? { deviceFacets } : {}),
    };
  }
}

function finiteCmdNumber(value: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error("Non-finite Home Assistant command value");
  }
  return Object.is(value, -0) ? 0 : value;
}

export function haServiceCall(command: DeviceCommand): HaServiceCall {
  const [powerEntityId = "", selectEntityId] = command.entityId.split("|");
  const rawTarget =
    command.kind === "setSelectOption" && selectEntityId
      ? selectEntityId
      : powerEntityId;
  const hashIdx = rawTarget.indexOf("#");
  const suffix = hashIdx >= 0 ? rawTarget.slice(hashIdx + 1) : "";
  const entity_id = hashIdx >= 0 ? rawTarget.slice(0, hashIdx) : rawTarget;
  const domain = entity_id.split(".")[0] ?? "";
  if (domain === "lock") {
    throw new Error("Home Assistant lock entities are read-only");
  }
  const call = (service: string, data: Row = {}): HaServiceCall => ({
    domain,
    service,
    entity_id,
    data,
  });
  switch (command.kind) {
    case "setLightPower":
    case "setFanPower":
    case "setSwitch":
      if (domain === "button") return call("press");
      if (domain === "valve") return call(command.isOn ? "open_valve" : "close_valve");
      if (domain === "media_player" && suffix === "mute") {
        return call("volume_mute", { is_volume_muted: command.isOn });
      }
      return call(command.isOn ? "turn_on" : "turn_off");
    case "setLightBrightness":
      return call("turn_on", { brightness_pct: finiteCmdNumber(command.percent) });
    case "setLightColorTemp":
      return call("turn_on", { color_temp_kelvin: finiteCmdNumber(command.kelvin) });
    case "setLightEffect":
      return call("turn_on", { effect: command.effect });
    case "setClimatePower":
      return call("set_hvac_mode", {
        hvac_mode: command.isOn ? command.resumeMode : "off",
      });
    case "setClimateMode":
      return call("set_hvac_mode", { hvac_mode: command.hvacMode });
    case "setClimateTemperature":
      return call("set_temperature", { temperature: finiteCmdNumber(command.temperature) });
    case "setClimateFanMode":
      return call("set_fan_mode", { fan_mode: command.fanMode });
    case "setFanPercentage":
      return call("set_percentage", { percentage: finiteCmdNumber(command.percent) });
    case "setFanPresetMode":
      return call("set_preset_mode", { preset_mode: command.presetMode });
    case "setFanOscillating":
      return call("oscillate", { oscillating: command.oscillating });
    case "setSelectOption": {
      if (domain === "climate") {
        return call("set_swing_mode", { swing_mode: command.option });
      }
      if (domain === "humidifier") {
        return call("set_mode", { mode: command.option });
      }
      if (domain === "water_heater") {
        return call("set_operation_mode", { operation_mode: command.option });
      }
      if (domain === "media_player") {
        return call("select_source", { source: command.option });
      }
      if (domain === "cover") {
        const lower = command.option.trim().toLowerCase();
        if (lower === "open" || lower === "up" || lower === "raise" || lower === "打开") {
          return call("open_cover");
        }
        if (lower === "close" || lower === "down" || lower === "lower" || lower === "关闭") {
          return call("close_cover");
        }
        if (lower === "pause" || lower === "stop" || lower === "暂停") {
          return call("stop_cover");
        }
        throw new Error(`Unsupported cover motor option: ${command.option}`);
      }
      if (domain === "valve") {
        const lower = command.option.trim().toLowerCase();
        if (lower === "open" || lower === "打开") return call("open_valve");
        if (lower === "close" || lower === "关闭") return call("close_valve");
        if (lower === "pause" || lower === "stop" || lower === "暂停" || lower === "停止") {
          return call("stop_valve");
        }
        throw new Error(`Unsupported valve option: ${command.option}`);
      }
      return call("select_option", { option: command.option });
    }
    case "setNumberValue": {
      const val = finiteCmdNumber(command.value);
      if (domain === "cover") {
        return call("set_cover_position", {
          position: Math.max(0, Math.min(100, Math.round(val))),
        });
      }
      if (domain === "valve") {
        return call("set_valve_position", {
          position: Math.max(0, Math.min(100, Math.round(val))),
        });
      }
      if (domain === "humidifier") {
        return call("set_humidity", {
          humidity: Math.max(0, Math.min(100, Math.round(val))),
        });
      }
      if (domain === "water_heater") {
        return call("set_temperature", { temperature: val });
      }
      if (domain === "media_player") {
        const level = val > 1 ? val / 100 : val;
        return call("volume_set", { volume_level: Math.max(0, Math.min(1, level)) });
      }
      return call("set_value", { value: val });
    }
    case "vacuumAction":
      return call(
        command.action === "returnToBase" ? "return_to_base" : command.action,
      );
    case "mediaSetVolume": {
      const level = finiteCmdNumber(command.level);
      return call("volume_set", { volume_level: Math.max(0, Math.min(1, level)) });
    }
    case "pressButton":
      if (domain === "valve") return call("stop_valve");
      if (domain === "media_player") return call("media_play_pause");
      return call("press");
    case "setMiotProperty":
      if (!command.entityId.startsWith("miot:")) {
        return haServiceCall(mapHAFacetCommand(command));
      }
      // A generic MIoT property write has no Home Assistant entity behind it.
      throw new Error("setMiotProperty is a Xiaomi-only command");
    case "activateScene":
      if (domain === "button") return call("press");
      return call("turn_on");
  }
}

export interface HADoorbellRing {
  readonly deviceId: string;
  readonly entityId: string;
  readonly firedAt: string;
}

export class HAHomeSnapshotReadError extends Error {
  constructor(public readonly reason: "rejected" | "invalidResponse") {
    super(
      reason === "rejected"
        ? "Home Assistant refused to read devices or registries"
        : "Home Assistant returned invalid device or registry data",
    );
    this.name = "HAHomeSnapshotReadError";
  }
}

function isOptionalStringField(value: unknown): boolean {
  return value === undefined || value === null || typeof value === "string";
}

function isPlainObject(value: unknown): value is Row {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function doorbellTimestamp(state: HAState): string | null {
  if (
    !state.entityId.startsWith("event.") ||
    state.attributes.device_class !== "doorbell" ||
    state.state === "" ||
    state.state === "unknown" ||
    state.state === "unavailable"
  ) {
    return null;
  }
  return state.state;
}

export class HAHomeSnapshot {
  private areas: Row[] = [];
  private devices: Row[] = [];
  private entities: Row[] = [];
  private states = new Map<string, HAState>();
  private readonly pendingInitialResults = new Set<number>([1, 2, 3, 4]);
  private rings: HADoorbellRing[] = [];
  private readonly doorbellTimestamps = new Map<string, string>();

  takeDoorbellRings(): HADoorbellRing[] {
    const out = this.rings;
    this.rings = [];
    return out;
  }

  receive(message: unknown, isRefreshStatesResult = false): SynthesizedHome | null {
    if (!isPlainObject(message)) return null;

    if (message.type === "result") {
      const id = haRoundedInt(message.id);
      if (id === null) return null;
      const inInitial = id >= 1 && id <= 4;
      const inRefreshRange = id >= 1000 && id <= 9999;
      if (!inInitial && !inRefreshRange && !isRefreshStatesResult) return null;
      if (message.success !== true) {
        throw new HAHomeSnapshotReadError("rejected");
      }
      if (!("result" in message) || message.result === undefined) {
        throw new HAHomeSnapshotReadError("invalidResponse");
      }
      if (id === 1) {
        this.areas = HAHomeSnapshot.decodeAreaEntries(message.result);
      } else if (id === 2) {
        this.devices = HAHomeSnapshot.decodeDeviceEntries(message.result);
      } else if (id === 3) {
        this.entities = HAHomeSnapshot.decodeEntityEntries(message.result);
      } else if (id === 4 || inRefreshRange || isRefreshStatesResult) {
        if (!Array.isArray(message.result)) {
          throw new HAHomeSnapshotReadError("invalidResponse");
        }
        const nextStates = new Map<string, HAState>();
        for (const entry of message.result) {
          const parsed = HAHomeSnapshot.parseState(entry);
          if (!parsed) throw new HAHomeSnapshotReadError("invalidResponse");
          nextStates.set(parsed.entityId, parsed);
          const ts = doorbellTimestamp(parsed);
          if (ts !== null) this.doorbellTimestamps.set(parsed.entityId, ts);
        }
        this.states = nextStates;
      } else {
        return null;
      }
      this.pendingInitialResults.delete(id);
    } else if (
      message.type === "event" &&
      isPlainObject(message.event) &&
      message.event.event_type === "state_changed" &&
      isPlainObject(message.event.data)
    ) {
      const data = message.event.data;
      if ("new_state" in data && data.new_state !== null && data.new_state !== undefined) {
        const parsed = HAHomeSnapshot.parseState(data.new_state);
        if (!parsed) return null;
        const ts = doorbellTimestamp(parsed);
        if (ts !== null && ts !== this.doorbellTimestamps.get(parsed.entityId)) {
          this.doorbellTimestamps.set(parsed.entityId, ts);
          if (this.pendingInitialResults.size === 0 && this.isActiveEntity(parsed.entityId)) {
            const ent = this.entities.find((e) => e.entity_id === parsed.entityId);
            const deviceId = typeof ent?.device_id === "string" && ent.device_id ? ent.device_id : parsed.entityId;
            this.rings.push({ deviceId, entityId: parsed.entityId, firedAt: ts });
          }
        }
        this.states.set(parsed.entityId, parsed);
      } else if (data.new_state === null) {
        const oldState = isPlainObject(data.old_state) ? data.old_state : null;
        const entityId =
          typeof data.entity_id === "string"
            ? data.entity_id
            : typeof oldState?.entity_id === "string"
              ? oldState.entity_id
              : null;
        if (!entityId || !this.states.delete(entityId)) {
          return null;
        }
        this.doorbellTimestamps.delete(entityId);
      } else {
        return null;
      }
    } else {
      return null;
    }

    if (this.pendingInitialResults.size > 0) return null;
    return HomeAssistantSynthesizer.synthesize({
      areas: this.areas,
      devices: this.devices,
      entities: this.entities,
      states: [...this.states.values()].map((st) => ({
        entity_id: st.entityId,
        state: st.state,
        attributes: st.attributes,
      })),
    });
  }

  private isActiveEntity(entityId: string): boolean {
    const entry = this.entities.find((e) => e.entity_id === entityId);
    if (!entry) return true;
    if (entry.disabled_by != null || entry.hidden_by != null) return false;
    if (typeof entry.device_id === "string") {
      const dev = this.devices.find((d) => d.id === entry.device_id);
      if (dev && dev.disabled_by != null) return false;
    }
    return true;
  }

  private static decodeAreaEntries(value: unknown): Row[] {
    if (!Array.isArray(value)) throw new HAHomeSnapshotReadError("invalidResponse");
    return value.map((item) => {
      if (!isPlainObject(item) || typeof item.area_id !== "string" || typeof item.name !== "string") {
        throw new HAHomeSnapshotReadError("invalidResponse");
      }
      return { ...item };
    });
  }

  private static decodeDeviceEntries(value: unknown): Row[] {
    if (!Array.isArray(value)) throw new HAHomeSnapshotReadError("invalidResponse");
    const optStrings = [
      "area_id",
      "name",
      "name_by_user",
      "manufacturer",
      "model",
      "disabled_by",
      "serial_number",
      "configuration_url",
    ];
    return value.map((item) => {
      if (!isPlainObject(item) || typeof item.id !== "string") {
        throw new HAHomeSnapshotReadError("invalidResponse");
      }
      for (const k of optStrings) {
        if (!isOptionalStringField(item[k])) throw new HAHomeSnapshotReadError("invalidResponse");
      }
      return { ...item };
    });
  }

  private static decodeEntityEntries(value: unknown): Row[] {
    if (!Array.isArray(value)) throw new HAHomeSnapshotReadError("invalidResponse");
    const optStrings = [
      "device_id",
      "area_id",
      "name",
      "original_name",
      "platform",
      "entity_category",
      "disabled_by",
      "hidden_by",
      "unique_id",
      "translation_key",
    ];
    return value.map((item) => {
      if (!isPlainObject(item) || typeof item.entity_id !== "string") {
        throw new HAHomeSnapshotReadError("invalidResponse");
      }
      for (const k of optStrings) {
        if (!isOptionalStringField(item[k])) throw new HAHomeSnapshotReadError("invalidResponse");
      }
      return { ...item };
    });
  }

  private static parseState(value: unknown): HAState | null {
    if (!isPlainObject(value) || typeof value.entity_id !== "string" || typeof value.state !== "string") {
      return null;
    }
    const attributes = isPlainObject(value.attributes) ? { ...value.attributes } : {};
    return {
      entityId: value.entity_id,
      state: value.state,
      attributes,
    };
  }
}

export class HomeAssistantClient {
  public lastRawSnapshot: unknown = null;
  constructor(
    private readonly baseURL: string,
    private readonly token: string,
    private readonly invoke: HAInvoke = async (command, args) => {
      if (!window.__TAURI_INTERNALS__?.invoke)
        throw new Error("Home Assistant requires the Windows app");
      return window.__TAURI_INTERNALS__.invoke(command, args);
    },
  ) {}
  async snapshot(): Promise<SynthesizedHome> {
    const raw = await this.invoke<unknown>("ha_snapshot", {
      baseUrl: this.baseURL,
      token: this.token,
    });
    this.lastRawSnapshot = raw;
    return HomeAssistantSynthesizer.synthesize(raw);
  }
  async execute(command: DeviceCommand): Promise<void> {
    await this.invoke("ha_execute", {
      baseUrl: this.baseURL,
      token: this.token,
      command: haServiceCall(command),
    });
  }
}
