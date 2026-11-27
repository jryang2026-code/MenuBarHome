import type {
  DeviceIntent,
  EnvironmentReading,
  HomeScene,
  SmartDevice,
} from "../models.js";
import { deviceAcceptsControlWrites, isActiveDevice, isDeviceActiveOn } from "../models.js";
import { deviceHeadInstruction, proactiveHeadInstruction } from "./actionPolicy.js";
import type { AssistantContext } from "./context.js";
import { buildEnvironmentSummary, buildTimeSummary, EMPTY_ASSISTANT_CONTEXT } from "./context.js";
import { mergeDesktopAmbientIntoEnvironment, normalizeDesktopAmbientContext, type DesktopAmbientContext } from "./desktopContext.js";
import {
  deviceCategory,
  isAssistantControllable,
  isHumidifierAppliance,
  isValveDevice,
} from "./deviceCategory.js";
import type {
  CommandMention,
  HabitEntry,
  HabitLastAction,
  HabitSequenceEntry,
  HabitSharing,
} from "./habits.js";
import { shareHabitSentence } from "./habits.js";
import {
  cleanPromptField,
  estimatedPromptTokens,
  PROMPT_ACTIVE_STATE_LIMIT,
  PROMPT_CONTEXT_LIMIT,
  PROMPT_DATA_NOTICE,
  PROMPT_NAME_LIMIT,
  PROMPT_OPTION_LIMIT,
  PROMPT_STATE_LIMIT,
  sanitizePromptText,
} from "./promptText.js";

/** Builds the ambient context macOS sends: time, indoor readings, running devices, habits. */
export function buildAssistantContext(options: {
  readonly now: Date;
  readonly readings: readonly EnvironmentReading[];
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly sharing: HabitSharing;
  readonly memory: {
    readonly entries: readonly HabitEntry[];
    readonly sequences?: readonly HabitSequenceEntry[];
    readonly lastAction?: HabitLastAction | null;
  };
  readonly phrases: readonly { readonly phrase: string; readonly intents: readonly DeviceIntent[] }[];
  readonly mention: CommandMention;
  readonly desktopContext?: Partial<DesktopAmbientContext> | null;
}): AssistantContext {
  const active = options.devices
    .filter((device) => device.isOnline && isActiveDevice(device))
    .map((device) => {
      const name = cleanPromptField(device.name, PROMPT_NAME_LIMIT);
      const state = cleanPromptField(catalogStateSummary(device), PROMPT_ACTIVE_STATE_LIMIT);
      return `${name}(${state})`;
    });
  const habitSummary = shareHabitSentence({
    sharing: options.sharing,
    memory: options.memory,
    phrases: options.phrases,
    devices: options.devices,
    scenes: options.scenes,
    mention: options.mention,
    now: options.now,
  });
  const desktop = normalizeDesktopAmbientContext(options.desktopContext);
  return {
    timeSummary: cleanPromptField(buildTimeSummary(options.now)),
    environmentSummary: cleanPromptField(mergeDesktopAmbientIntoEnvironment(buildEnvironmentSummary(options.readings), desktop)),
    activeDevicesSummary: cleanPromptField(active.length > 0 ? active.join("、") : "全屋设备均关闭"),
    habitSummary: cleanPromptField(habitSummary),
    desktopContext: desktop,
  };
}

/** Category used in the model catalog; sensors are not assistant-controllable. */
export function assistantDeviceCategory(device: SmartDevice): string | null {
  const cat = deviceCategory(device);
  return isAssistantControllable(cat) ? cat : null;
}

export function formatTemperatureValue(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/**
 * One-line state summary inside the catalog, mirroring macOS `IntentCatalog.stateSummary`.
 * Kept byte-for-byte compatible in shape (Chinese words and separators) so a prompt built
 * on either platform means the same thing to the model.
 */
export function catalogStateSummary(device: SmartDevice): string {
  if (!device.isOnline) return "离线";
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      const cleanedEffects = kind.availableEffects
        .map((item) => cleanPromptField(item, PROMPT_OPTION_LIMIT))
        .filter(Boolean);
      const effects = cleanedEffects.length > 0 ? ` 可用模式:${cleanedEffects.join("/")}` : "";
      if (!kind.isOn) return `关${effects}`;
      let text = "开";
      if (kind.brightnessPercent !== null) text += ` 亮度${kind.brightnessPercent}%`;
      const currentEffect = kind.currentEffect ? cleanPromptField(kind.currentEffect, PROMPT_OPTION_LIMIT) : "";
      if (currentEffect) text += ` 当前:${currentEffect}`;
      return text + effects;
    }
    case "climate": {
      const modes = kind.availableModes
        .map((item) => cleanPromptField(item, PROMPT_OPTION_LIMIT))
        .filter(Boolean)
        .join("/");
      const range = `${formatTemperatureValue(kind.minTemp)}-${formatTemperatureValue(kind.maxTemp)}°C`;
      const currentMode = cleanPromptField(kind.hvacMode, PROMPT_OPTION_LIMIT);
      const current = kind.isOn && kind.hvacMode !== "off"
        ? `${currentMode} ${formatTemperatureValue(kind.targetTemperature)}°C`
        : "关";
      const fanModes = kind.availableFanModes
        .map((item) => cleanPromptField(item, PROMPT_OPTION_LIMIT))
        .filter(Boolean);
      const fan = fanModes.length > 0 ? ` 可选风速:${fanModes.join("/")}` : "";
      return `${current} 可用模式:${modes} 温度范围:${range}${fan}`;
    }
    case "fan": {
      let text = kind.isOn ? "开" : "关";
      const preset = kind.presetMode ? cleanPromptField(kind.presetMode, PROMPT_OPTION_LIMIT) : "";
      if (kind.isOn && preset) text += ` 风速:${preset}`;
      const presetModes = kind.availablePresetModes
        .map((item) => cleanPromptField(item, PROMPT_OPTION_LIMIT))
        .filter(Boolean);
      if (presetModes.length > 0) text += ` 可选风速:${presetModes.join("/")}`;
      if (kind.isOscillating !== null) text += ` 摇头:${kind.isOscillating ? "开" : "关"}`;
      return text;
    }
    case "plug":
      return kind.isOn ? "开" : "关";
    case "vacuum":
      // macOS VacuumSpec.isCleaning treats both "cleaning" and "on" as 清扫中 (#38).
      return kind.status === "cleaning" || kind.status === "on" ? "清扫中" : "待机";
    case "camera":
      return kind.isOn ? "开" : "关";
    case "tv": {
      if (kind.state === "off" || kind.state === "standby") return "关";
      const src = kind.currentSource ? cleanPromptField(kind.currentSource, PROMPT_OPTION_LIMIT) : "";
      const vol = kind.volumePresent === false ? "" : ` 音量${kind.volumePercent}%`;
      return `开${src ? ` ${src}` : ""}${vol}`;
    }
    case "humidifier": {
      const parts = [kind.isOn ? "开" : "关"];
      if (kind.targetHumidity !== null && Number.isFinite(kind.targetHumidity) && Number.isSafeInteger(Math.round(kind.targetHumidity))) {
        parts.push(`目标湿度${Math.round(kind.targetHumidity)}%`);
      }
      if (kind.currentHumidity !== null && Number.isFinite(kind.currentHumidity) && Number.isSafeInteger(Math.round(kind.currentHumidity))) {
        parts.push(`当前湿度${Math.round(kind.currentHumidity)}%`);
      }
      const currentMode = kind.currentMode ? cleanPromptField(kind.currentMode, PROMPT_OPTION_LIMIT) : "";
      if (currentMode) parts.push(currentMode);
      return parts.join(" ");
    }
    case "fridge":
    case "sensor":
    case "speaker":
      return "";
    case "cover":
      return kind.positionPercent === null ? "未知" : `开${kind.positionPercent}%`;
    case "appliance": {
      if (isValveDevice(device)) {
        return kind.isOn ? "开" : "关";
      }
      if (isHumidifierAppliance(device)) {
        const parts = [kind.isOn ? "开" : "关"];
        const targetMatch = kind.statusText?.match(/(?:目标|Target)\s*(\d+)%/i);
        if (targetMatch?.[1]) parts.push(`目标湿度${targetMatch[1]}%`);
        if (kind.currentHumidity !== null && Number.isFinite(kind.currentHumidity)) {
          parts.push(`当前湿度${Math.round(kind.currentHumidity)}%`);
        }
        const currentMode = kind.currentMode ? cleanPromptField(kind.currentMode, PROMPT_OPTION_LIMIT) : "";
        if (currentMode) parts.push(currentMode);
        return parts.join(" ");
      }
      const parts = [kind.isOn ? "开" : "关"];
      const statusText = kind.statusText ? cleanPromptField(kind.statusText, PROMPT_OPTION_LIMIT) : "";
      if (statusText) parts.push(statusText);
      if (kind.targetTemperature !== null) parts.push(`${formatTemperatureValue(kind.targetTemperature)}°C`);
      return parts.join(" ");
    }
    case "generic": {
      const readouts = kind.readouts
        .map((item) => cleanPromptField(item, PROMPT_OPTION_LIMIT))
        .filter(Boolean);
      return readouts.length > 0 ? readouts.join(" ") : cleanPromptField(kind.typeTitle, PROMPT_OPTION_LIMIT);
    }
  }
}

export interface IntentCatalog {
  readonly text: string;
  readonly aliasDevices: ReadonlyArray<{ readonly alias: string; readonly device: SmartDevice }>;
  readonly criteriaByAlias: Readonly<Record<string, string>>;
  readonly aliasToIds: ReadonlyMap<string, readonly string[]>;
  readonly textFitting: (maxEstimatedTokens: number, mention?: string, preferredDeviceIds?: ReadonlySet<string>) => string;
}

export const CHAT_CATALOG_TOKEN_BUDGET = 3600;

function jsonSchemaFormat(name: string, arrayKey: string, ops: readonly string[], extra: { confidence?: boolean; reply?: boolean }): Record<string, unknown> {
  const itemProps: Record<string, unknown> = { device: { type: "string" }, op: { type: "string", enum: [...ops] }, value: { type: ["string", "number", "boolean", "null"] } };
  const itemReq = ["device", "op", "value"];
  if (extra.confidence) { itemProps["confidence"] = { type: "number" }; itemReq.push("confidence"); }
  const props: Record<string, unknown> = { [arrayKey]: { type: "array", items: { type: "object", properties: itemProps, required: itemReq, additionalProperties: false } } };
  const req = [arrayKey];
  if (extra.reply) { props["reply"] = { type: "string" }; req.push("reply"); }
  return { type: "json_schema", json_schema: { name, strict: true, schema: { type: "object", properties: props, required: req, additionalProperties: false } } };
}

export const INTENT_PLAN_RESPONSE_FORMAT = jsonSchemaFormat(
  "smart_home_intent_plan", "actions",
  ["power", "brightness", "brightness_step", "color_temp", "effect", "hvac_mode", "temperature", "temperature_step", "fan_speed", "fan_percentage", "cover_position", "oscillation", "scene"],
  { reply: true },
);

export const PROACTIVE_RESPONSE_FORMAT = jsonSchemaFormat(
  "smart_home_proactive_suggestions", "suggestions",
  ["power", "brightness", "color_temp", "effect", "hvac_mode", "temperature", "fan_speed", "fan_percentage", "cover_position", "oscillation", "scene"],
  { confidence: true },
);

function matchedCatalogNames(mention: string, names: readonly string[], claimed: Array<[number, number]> = []): { names: Set<string>; ranges: Array<[number, number]> } {
  if (!mention) return { names: new Set(), ranges: claimed };
  const lower = mention.toLowerCase(), ranges = [...claimed], matched = new Set<string>();
  for (const name of [...new Set(names.filter(Boolean))].sort((a, b) => b.length - a.length)) {
    const needle = name.toLowerCase();
    for (let from = 0; from <= lower.length - needle.length; ) {
      const idx = lower.indexOf(needle, from);
      if (idx < 0) break;
      const end = idx + needle.length;
      if (!ranges.some(([s, e]) => idx < e && s < end)) { ranges.push([idx, end]); matched.add(name); }
      from = end;
    }
  }
  return { names: matched, ranges };
}

/**
 * Short aliases for controllable devices (d1…dN, never truncated) plus scene aliases and
 * the room/all-light/whole-home shortcuts macOS offers the model (#33 / #38).
 */
export function buildIntentCatalog(
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentCatalog {
  const aliasDevices: Array<{ alias: string; device: SmartDevice }> = [];
  const aliasToIds = new Map<string, string[]>();
  const criteriaByAlias: Record<string, string> = {};
  const allLightIds: string[] = [];
  const allDeviceIds: string[] = [];
  const roomLights = new Map<string, { roomName: string; ids: string[] }>();
  const aliasById = new Map<string, string>();
  const deviceRows: Array<Record<string, unknown>> = [];

  for (const device of devices) {
    const category = assistantDeviceCategory(device);
    if (category === null || !deviceAcceptsControlWrites(device)) continue;
    const alias = `d${aliasDevices.length + 1}`;
    const state = sanitizePromptText(catalogStateSummary(device), PROMPT_STATE_LIMIT);
    aliasDevices.push({ alias, device });
    aliasToIds.set(alias, [device.id]);
    aliasById.set(device.id, alias);
    if (!aliasToIds.has(device.id)) aliasToIds.set(device.id, [device.id]);
    if (category !== "valve" && category !== "cover") {
      allDeviceIds.push(device.id);
    }
    if (category === "light" && device.roomName) {
      allLightIds.push(device.id);
      const roomKey = device.roomId || device.roomName;
      const existing = roomLights.get(roomKey);
      if (existing) {
        existing.ids.push(device.id);
      } else {
        roomLights.set(roomKey, { roomName: device.roomName, ids: [device.id] });
      }
    } else if (category === "light") {
      allLightIds.push(device.id);
    }
    criteriaByAlias[alias] = `${category}; ${state}`;
    const row: Record<string, unknown> = {
      id: alias,
      name: sanitizePromptText(device.name, PROMPT_NAME_LIMIT),
      room: sanitizePromptText(device.roomName, PROMPT_NAME_LIMIT),
      category,
      state,
    };
    if (device.isSharedHome === true) row["shared"] = true;
    deviceRows.push(row);
  }

  let groupIndex = 0;
  const groupRows: Array<{ id: string; room: string; members: string[] }> = [];
  for (const { roomName, ids } of roomLights.values()) {
    if (ids.length < 2) continue;
    groupIndex += 1;
    const alias = `room_lights:${groupIndex}`;
    aliasToIds.set(alias, ids);
    criteriaByAlias[alias] = `灯组 ${ids.length}盏`;
    groupRows.push({
      id: alias,
      room: sanitizePromptText(roomName, PROMPT_NAME_LIMIT),
      members: ids.map((id) => aliasById.get(id) ?? id),
    });
  }
  if (allLightIds.length >= 2) {
    aliasToIds.set("all_lights", allLightIds);
    criteriaByAlias["all_lights"] = `全屋所有灯具 (${allLightIds.length}盏)`;
  }
  if (allDeviceIds.length >= 2) {
    aliasToIds.set("all_devices", allDeviceIds);
    criteriaByAlias["all_devices"] = `全屋所有可控设备 (${allDeviceIds.length}台)`;
  }

  const sceneRows = scenes.map((scene, index) => {
    const alias = `s${index + 1}`;
    aliasToIds.set(alias, [scene.id]);
    if (!aliasToIds.has(scene.id)) aliasToIds.set(scene.id, [scene.id]);
    criteriaByAlias[alias] = "场景";
    return { id: alias, name: sanitizePromptText(scene.name, PROMPT_NAME_LIMIT) };
  });

  const text = `${PROMPT_DATA_NOTICE}\n${JSON.stringify({ devices: deviceRows, groups: groupRows, scenes: sceneRows })}`;
  const textFitting = (maxEstimatedTokens: number, mention = "", preferredDeviceIds: ReadonlySet<string> = new Set()): string => {
    const clean = sanitizePromptText(mention, PROMPT_CONTEXT_LIMIT);
    const dMeta = deviceRows.map((r, i) => ({ alias: String(r["id"]), name: String(r["name"]), room: String(r["room"]), deviceId: aliasDevices[i]!.device.id, row: JSON.stringify(r) }));
    const gMeta = groupRows.map((r) => ({ room: r.room, members: r.members, ids: aliasToIds.get(r.id) ?? [], row: JSON.stringify(r) }));
    const sMeta = sceneRows.map((r) => ({ alias: r.id, name: r.name, row: JSON.stringify(r) }));
    const dm = matchedCatalogNames(clean, dMeta.map((d) => d.name));
    const sm = matchedCatalogNames(clean, sMeta.map((s) => s.name), dm.ranges);
    const rm = matchedCatalogNames(clean, dMeta.map((d) => d.room), sm.ranges);
    const devA = new Set(dMeta.filter((d) => dm.names.has(d.name)).map((d) => d.alias));
    const roomA = new Set(dMeta.filter((d) => d.room && rm.names.has(d.room)).map((d) => d.alias));
    const sceneA = new Set(sMeta.filter((s) => sm.names.has(s.name)).map((s) => s.alias));
    const cands: Array<{ row: string; p: number; o: number }> = [];
    let o = 0;
    for (const d of dMeta) cands.push({ row: d.row, p: devA.has(d.alias) ? 0 : roomA.has(d.alias) ? 2 : preferredDeviceIds.has(d.deviceId) ? 3 : 4, o: o++ });
    for (const g of gMeta) cands.push({ row: g.row, p: g.room && rm.names.has(g.room) ? 1 : g.members.some((m) => devA.has(m)) ? 2 : g.ids.some((id) => preferredDeviceIds.has(id)) ? 3 : 4, o: o++ });
    for (const s of sMeta) cands.push({ row: s.row, p: sceneA.has(s.alias) ? 0 : 4, o: o++ });
    cands.sort((a, b) => a.p - b.p || a.o - b.o);
    let used = estimatedPromptTokens(`${PROMPT_DATA_NOTICE}\n{"devices":[],"groups":[],"scenes":[]}`);
    const picked = new Set<string>();
    for (const c of cands) {
      const cost = estimatedPromptTokens(c.row) + 1;
      if (used + cost <= maxEstimatedTokens) { used += cost; picked.add(c.row); }
    }
    return `${PROMPT_DATA_NOTICE}\n{"devices":[${dMeta.filter((d) => picked.has(d.row)).map((d) => d.row).join(",")}],"groups":[${gMeta.filter((g) => picked.has(g.row)).map((g) => g.row).join(",")}],"scenes":[${sMeta.filter((s) => picked.has(s.row)).map((s) => s.row).join(",")}]}`;
  };
  return { text, aliasDevices, criteriaByAlias, aliasToIds, textFitting };
}

/** Operations offered to the model, matching macOS `opCriteria` (#38). */
export function systemOneOpCriteria(): Record<string, string> {
  return {
    power_on: "打开设备电源",
    power_off: "关闭设备电源",
    effect_night: "切换月光/夜灯模式 (Night)",
    effect_day: "切换日光模式 (Day)",
    bri_20: "调暗灯光 (亮度 20%)",
    bri_50: "中等亮度 (亮度 50%)",
    bri_100: "调亮/最亮灯光 (亮度 100%)",
    bri_down_20: "相对调暗一点 (-20%)",
    bri_up_20: "相对调亮一点 (+20%)",
    ct_2700: "暖光/黄光 (色温 2700K)",
    ct_4000: "自然光/冷光 (色温 4000K)",
    ct_6500: "白光/日光 (色温 6500K)",
    hvac_cool: "空调制冷模式",
    hvac_heat: "空调制热模式",
    hvac_dry: "空调除湿模式",
    hvac_fan: "空调送风模式",
    hvac_auto: "空调自动模式",
    temp: "仅调节空调温度",
    temp_up_2: "空调温度相对调高 2°C",
    temp_down_2: "空调温度相对调低 2°C",
    fan_low: "风速调为低档/一档",
    fan_medium: "风速调为中档/二档",
    fan_high: "风速调为高档/三档",
    fan_auto: "风速调为自动档",
    osc_on: "开启风扇摇头/摆风",
    osc_off: "停止风扇摇头/摆风",
    scene: "执行智能场景",
  };
}

export function systemOneTempCriteria(): Record<string, string> {
  const criteria: Record<string, string> = { none: "不指定具体温度" };
  for (let celsius = 18; celsius <= 28; celsius += 1) {
    criteria[String(celsius)] = `${celsius}°C`;
  }
  return criteria;
}

/** Per-device decision head choices, mirroring macOS `deviceSpecificCriteria` (#38). */
export function deviceSpecificCriteria(device: SmartDevice): Record<string, string> {
  const criteria: Record<string, string> = {
    none: "保持不变，不操作此设备",
    power_on: "打开此设备",
    power_off: "关闭此设备",
  };
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "day")) {
        criteria["effect_day"] = "切换为日光模式（专注照明）";
      }
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "night")) {
        criteria["effect_night"] = "切换为月光/夜灯模式（柔和助眠）";
      }
      criteria["bri_20"] = "调暗灯光 (20%)";
      criteria["bri_100"] = "调亮灯光 (100%)";
      if (kind.isOn) {
        criteria["bri_down_20"] = "再暗一点 (-20%)";
        criteria["bri_up_20"] = "再亮一点 (+20%)";
      }
      break;
    }
    case "climate": {
      if (kind.availableModes.includes("cool")) {
        criteria["cool_24"] = "开启制冷 24°C（快速降温）";
        criteria["cool_25"] = "开启制冷 25°C";
        criteria["cool_26"] = "开启制冷 26°C（舒适恒温）";
      }
      if (kind.availableModes.includes("heat")) {
        criteria["heat_22"] = "开启制热 22°C";
        criteria["heat_24"] = "开启制热 24°C";
      }
      if (kind.availableModes.includes("dry")) {
        criteria["hvac_dry"] = "开启除湿模式";
      }
      if (kind.isOn) {
        criteria["temp_up_2"] = "温度相对调高 2°C";
        criteria["temp_down_2"] = "温度相对调低 2°C";
      }
      break;
    }
    case "fan": {
      if (kind.availablePresetModes.length > 0) {
        criteria["fan_low"] = "风速调为低档";
        criteria["fan_medium"] = "风速调为中档";
        criteria["fan_high"] = "风速调为高档";
      }
      criteria["osc_on"] = "开启摇头";
      criteria["osc_off"] = "停止摇头";
      break;
    }
    case "plug":
    case "vacuum":
    case "camera":
    case "tv":
    case "humidifier":
    case "sensor":
      break;
  }
  return criteria;
}

export interface SystemOneRequest {
  readonly body: {
    readonly model: string;
    readonly state: Record<string, unknown>;
    readonly questions: Record<string, unknown>;
  };
  readonly catalog: IntentCatalog;
}

/**
 * Builds the Jev `/v1/systemone` body with the same keys and per-device heads as macOS
 * `ModelIntentResolver.makeSystemOneRequest` (#38). Shared fixture:
 * Tests/Fixtures/ai_request_golden.json.
 */
export function buildSystemOneRequestBody(options: {
  readonly model: string;
  readonly utterance: string;
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly context?: AssistantContext;
}): SystemOneRequest {
  const catalog = buildIntentCatalog(options.devices, options.scenes);
  const context = options.context ?? EMPTY_ASSISTANT_CONTEXT;

  const targetCriteria: Record<string, string> = { ...catalog.criteriaByAlias, none: "无匹配设备或场景" };
  const questions: Record<string, unknown> = {
    target: {
      type: "choice",
      instructions: "Select the primary target device, room light group, or scene id for the command",
      criteria: targetCriteria,
    },
    op: {
      type: "choice",
      instructions: "Select the primary operation to perform on the target",
      criteria: systemOneOpCriteria(),
    },
    temp: {
      type: "choice",
      instructions: "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
      criteria: systemOneTempCriteria(),
    },
  };

  for (const { alias, device } of catalog.aliasDevices) {
    questions[`dev_${alias}`] = {
      type: "choice",
      instructions: deviceHeadInstruction(alias),
      criteria: deviceSpecificCriteria(device),
    };
  }

  const state: Record<string, unknown> = {
    catalog: catalog.text,
    command: options.utterance,
  };
  const time = cleanPromptField(context.timeSummary);
  const environment = cleanPromptField(mergeDesktopAmbientIntoEnvironment(context.environmentSummary, context.desktopContext));
  const activeDevices = cleanPromptField(context.activeDevicesSummary);
  const habits = cleanPromptField(context.habitSummary);
  if (time) state["time"] = time;
  if (environment) state["environment"] = environment;
  if (activeDevices) state["active_devices"] = activeDevices;
  if (habits) state["user_habits"] = habits;

  return {
    body: { model: options.model, state, questions },
    catalog,
  };
}

/** Proactive per-device decision heads; mirrors macOS `makeProactiveSystemOneRequest` (#113). */
export function buildProactiveSystemOneRequestBody(options: {
  readonly model: string;
  readonly devices: readonly SmartDevice[];
  readonly context: AssistantContext;
  readonly catalog: IntentCatalog;
}): SystemOneRequest {
  const questions: Record<string, unknown> = {};
  for (const { alias, device } of options.catalog.aliasDevices) {
    questions[`dev_${alias}`] = {
      type: "choice",
      instructions: proactiveHeadInstruction(alias),
      criteria: deviceSpecificCriteria(device),
    };
  }

  const state: Record<string, unknown> = {
    catalog: options.catalog.text,
    time: cleanPromptField(options.context.timeSummary),
    environment: cleanPromptField(mergeDesktopAmbientIntoEnvironment(options.context.environmentSummary, options.context.desktopContext)),
    active_devices: cleanPromptField(options.context.activeDevicesSummary),
    user_habits: cleanPromptField(options.context.habitSummary),
  };

  return {
    body: { model: options.model, state, questions },
    catalog: options.catalog,
  };
}

/** Proactive chat prompt; mirrors macOS `makeProactiveChatRequest` (#113). */
export function buildProactiveChatRequestBody(
  model: string,
  context: AssistantContext,
  catalog: IntentCatalog,
  maxCatalogTokens = CHAT_CATALOG_TOKEN_BUDGET,
): Record<string, unknown> {
  const environment = cleanPromptField(mergeDesktopAmbientIntoEnvironment(context.environmentSummary, context.desktopContext));
  const preferred = new Set<string>([
    ...(context.favoriteDeviceIds ?? []),
    ...catalog.aliasDevices.filter(({ device }) => device.isOnline && isDeviceActiveOn(device)).map(({ device }) => device.id),
  ]);
  const system = [
    "你是智能家居主动建议引擎。根据当前时间、室内温湿度、桌面情境、开启中的设备与用户习惯，推荐最多 3 个最值得立即执行的设备调整建议，只输出 JSON，不要解释。",
    catalog.textFitting(maxCatalogTokens, "", preferred),
    'schema: {"suggestions":[{"device":"id","op":"power|brightness|color_temp|effect|hvac_mode|temperature|fan_speed|fan_percentage|cover_position|oscillation|scene","value":...,"confidence":85}]}',
    "规则：confidence 为 20-99 的整数置信度；如果当前环境已处于理想状态无需操作，输出 {\"suggestions\":[]}。只能使用上面列出的 id。",
  ].join("\n");
  const userState = `时间：${cleanPromptField(context.timeSummary)}\n环境：${environment}\n开启中：${cleanPromptField(context.activeDevicesSummary)}\n习惯：${cleanPromptField(context.habitSummary)}`;
  return {
    model: model.trim(),
    messages: [
      { role: "system", content: system },
      { role: "user", content: userState },
    ],
    temperature: 0,
    max_tokens: 600,
    stream: false,
    response_format: PROACTIVE_RESPONSE_FORMAT,
  };
}
