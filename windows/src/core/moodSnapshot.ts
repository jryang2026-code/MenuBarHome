import { IntentValidator } from "./assistant/intent.js";
import { inverseCommands } from "./commandEffects.js";
import type { DeviceCommand, DeviceIntent, IntentOperation, SmartDevice } from "./models.js";
import { defaultStorage } from "./pollingPolicy.js";

export const MOOD_SNAPSHOTS_STORAGE_KEY = "menumijia.windows.localMoodSnapshots.v1";
export const MOOD_SNAPSHOT_VERSION = 1 as const;
export const MOOD_SNAPSHOT_LIMIT = 32;

export type MoodStorageLike = Pick<Storage, "getItem" | "setItem">;

export interface MoodTarget {
  readonly deviceId: string;
  readonly name: string;
  readonly sourceScope: string;
  readonly entityId: string;
  readonly power?: boolean;
  readonly brightness?: number;
  readonly colorTemperature?: number;
  readonly coverPosition?: number;
  readonly targetTemperature?: number;
  readonly hvacMode?: string;
}

export interface MoodSnapshot {
  readonly id: string;
  readonly name: string;
  readonly createdAt: string;
  readonly targets: readonly MoodTarget[];
}

export interface MoodSnapshotFile {
  readonly version: typeof MOOD_SNAPSHOT_VERSION;
  readonly moods: readonly MoodSnapshot[];
}

export type MoodField =
  | { readonly kind: "power"; readonly value: boolean }
  | { readonly kind: "hvacMode"; readonly value: string }
  | { readonly kind: "brightness"; readonly value: number }
  | { readonly kind: "colorTemperature"; readonly value: number }
  | { readonly kind: "targetTemperature"; readonly value: number }
  | { readonly kind: "coverPosition"; readonly value: number };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SOURCE_SCOPE_RE = /^(ha:|mi:|demo$)/;
const ALLOWED_TARGET_KEYS = new Set([
  "deviceId", "name", "sourceScope", "entityId",
  "power", "brightness", "colorTemperature", "coverPosition", "targetTemperature", "hvacMode",
]);
const ALLOWED_MOOD_KEYS = new Set(["id", "name", "createdAt", "targets"]);

export function createMoodId(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID().toUpperCase();
  const bytes = new Uint8Array(16);
  globalThis.crypto?.getRandomValues?.(bytes);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const h = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Integer-second UTC ISO-8601 format matching macOS `ISO8601DateFormatter`. */
export function formatMoodCreatedAt(date: Date = new Date()): string {
  return new Date(Math.floor(date.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

const isObj = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string" && v.length >= 1;
const isInt = (v: unknown, min: number, max: number): v is number =>
  typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;

export function moodTargetHasAnyField(t: MoodTarget): boolean {
  return t.power !== undefined || t.brightness !== undefined || t.colorTemperature !== undefined ||
    t.coverPosition !== undefined || t.targetTemperature !== undefined || t.hvacMode !== undefined;
}

export function canonicalMoodTarget(raw: MoodTarget): MoodTarget | null {
  if (!isStr(raw.deviceId) || !isStr(raw.name) || !SOURCE_SCOPE_RE.test(raw.sourceScope) || !isStr(raw.entityId)) return null;
  const clean: MoodTarget = {
    deviceId: raw.deviceId, name: raw.name, sourceScope: raw.sourceScope, entityId: raw.entityId,
    ...(raw.power !== undefined ? { power: raw.power } : {}),
    ...(raw.brightness !== undefined ? { brightness: raw.brightness } : {}),
    ...(raw.colorTemperature !== undefined ? { colorTemperature: raw.colorTemperature } : {}),
    ...(raw.coverPosition !== undefined ? { coverPosition: raw.coverPosition } : {}),
    ...(raw.targetTemperature !== undefined ? { targetTemperature: raw.targetTemperature } : {}),
    ...(raw.hvacMode !== undefined ? { hvacMode: raw.hvacMode } : {}),
  };
  return moodTargetHasAnyField(clean) ? clean : null;
}

function parseMoodTarget(raw: unknown): MoodTarget | null {
  if (!isObj(raw)) return null;
  const keys = Object.keys(raw);
  if (keys.length < 5 || keys.some((k) => !ALLOWED_TARGET_KEYS.has(k))) return null;
  if (!isStr(raw.deviceId) || !isStr(raw.name) || !isStr(raw.sourceScope) || !SOURCE_SCOPE_RE.test(raw.sourceScope) || !isStr(raw.entityId)) {
    return null;
  }
  if (raw.power !== undefined && typeof raw.power !== "boolean") return null;
  if (raw.brightness !== undefined && !isInt(raw.brightness, 1, 100)) return null;
  if (raw.colorTemperature !== undefined && !isInt(raw.colorTemperature, 1, Number.MAX_SAFE_INTEGER)) return null;
  if (raw.coverPosition !== undefined && !isInt(raw.coverPosition, 0, 100)) return null;
  if (raw.targetTemperature !== undefined && (typeof raw.targetTemperature !== "number" || !Number.isFinite(raw.targetTemperature))) return null;
  if (raw.hvacMode !== undefined && !isStr(raw.hvacMode)) return null;
  return canonicalMoodTarget(raw as unknown as MoodTarget);
}

export function decodeMoodSnapshotFile(raw: string): MoodSnapshotFile | null {
  try {
    const p: unknown = JSON.parse(raw);
    if (!isObj(p) || Object.keys(p).some((k) => k !== "version" && k !== "moods")) return null;
    if (p.version !== MOOD_SNAPSHOT_VERSION || !Array.isArray(p.moods) || p.moods.length > MOOD_SNAPSHOT_LIMIT) return null;
    const moods: MoodSnapshot[] = [];
    for (const m of p.moods) {
      if (!isObj(m) || Object.keys(m).some((k) => !ALLOWED_MOOD_KEYS.has(k))) return null;
      if (!isStr(m.id) || !UUID_RE.test(m.id) || !isStr(m.name) || !isStr(m.createdAt) || !Number.isFinite(Date.parse(m.createdAt))) return null;
      if (!Array.isArray(m.targets) || m.targets.length < 1) return null;
      const targets = m.targets.map(parseMoodTarget);
      if (targets.some((t) => t === null)) return null;
      moods.push({ id: m.id, name: m.name, createdAt: m.createdAt, targets: targets as MoodTarget[] });
    }
    return { version: MOOD_SNAPSHOT_VERSION, moods };
  } catch {
    return null;
  }
}

export function encodeMoodSnapshotFile(file: MoodSnapshotFile): string {
  return JSON.stringify({
    version: MOOD_SNAPSHOT_VERSION,
    moods: file.moods.slice(0, MOOD_SNAPSHOT_LIMIT).map((m) => ({
      id: m.id,
      name: m.name,
      createdAt: m.createdAt,
      targets: m.targets.map(canonicalMoodTarget).filter((t): t is MoodTarget => t !== null),
    })),
  }, null, 2);
}

export function loadMoodSnapshots(storage: MoodStorageLike | null = defaultStorage()): MoodSnapshot[] {
  const raw = storage?.getItem(MOOD_SNAPSHOTS_STORAGE_KEY);
  return raw?.trim() ? [...(decodeMoodSnapshotFile(raw)?.moods ?? [])] : [];
}

export function saveMoodSnapshots(moods: readonly MoodSnapshot[], storage: MoodStorageLike | null = defaultStorage()): MoodSnapshot[] {
  const capped = moods.slice(0, MOOD_SNAPSHOT_LIMIT);
  storage?.setItem(MOOD_SNAPSHOTS_STORAGE_KEY, encodeMoodSnapshotFile({ version: MOOD_SNAPSHOT_VERSION, moods: capped }));
  return [...capped];
}

export function moodTargetFields(target: MoodTarget): MoodField[] {
  const out: MoodField[] = [];
  if (target.power !== undefined && target.hvacMode === undefined) out.push({ kind: "power", value: target.power });
  if (target.hvacMode !== undefined) out.push({ kind: "hvacMode", value: target.hvacMode });
  if (target.power !== false && target.hvacMode !== "off") {
    if (target.brightness !== undefined) out.push({ kind: "brightness", value: target.brightness });
    if (target.colorTemperature !== undefined) out.push({ kind: "colorTemperature", value: target.colorTemperature });
    if (target.targetTemperature !== undefined) out.push({ kind: "targetTemperature", value: target.targetTemperature });
  }
  if (target.coverPosition !== undefined) out.push({ kind: "coverPosition", value: target.coverPosition });
  return out;
}

export function moodEntityIdForDevice(device: SmartDevice): string | null {
  switch (device.kind.kind) {
    case "light":
    case "climate":
    case "fan":
    case "cover":
      return device.kind.entityId || null;
    case "plug":
      return device.kind.switchEntityId || null;
    default:
      return null;
  }
}

function moodCanWriteHvacMode(device: SmartDevice, mode: string): boolean {
  if (device.kind.kind !== "climate" || device.kind.availableModes.length === 0) return false;
  const n = IntentValidator.normalize({ kind: "hvacMode", mode }, device);
  if (!n || n.kind !== "hvacMode" || n.mode.toLowerCase() !== mode.toLowerCase()) return false;
  return mode.toLowerCase() !== "off" || device.kind.availableModes.some((m) => m.toLowerCase() === "off");
}

export function captureMoodTargetForDevice(
  device: SmartDevice,
  sourceScope: string | null,
  options?: { readonly lastCoverPosition?: number | null },
): MoodTarget | null {
  if (!device.isOnline || device.telemetryStale || !sourceScope || !SOURCE_SCOPE_RE.test(sourceScope)) return null;
  const entityId = moodEntityIdForDevice(device);
  if (!entityId) return null;
  const k = device.kind;
  const fields: Partial<MoodTarget> = {};

  if (k.kind === "light") {
    if (k.powerWritable !== false) Object.assign(fields, { power: k.isOn });
    if (k.isOn) {
      if (k.brightnessWritable !== false && k.brightnessPercent !== null && Number.isFinite(k.brightnessPercent)) {
        Object.assign(fields, { brightness: Math.max(1, Math.min(100, Math.round(k.brightnessPercent))) });
      }
      if (k.colorWritable !== false && k.colorTempKelvin !== null && Number.isFinite(k.colorTempKelvin) && Math.round(k.colorTempKelvin) >= 1) {
        Object.assign(fields, { colorTemperature: Math.round(k.colorTempKelvin) });
      }
    }
  } else if (k.kind === "climate") {
    const mode = k.isOn ? k.hvacMode : "off";
    if (moodCanWriteHvacMode(device, mode)) Object.assign(fields, { hvacMode: mode });
    else if (k.powerWritable !== false) Object.assign(fields, { power: k.isOn });
    if (k.isOn && k.temperatureWritable !== false && Number.isFinite(k.targetTemperature)) {
      Object.assign(fields, { targetTemperature: k.targetTemperature });
    }
  } else if (k.kind === "fan") {
    if (k.powerWritable !== false) Object.assign(fields, { power: k.isOn });
  } else if (k.kind === "plug") {
    if (k.powerWritable !== false && !k.switchEntityId.startsWith("button.")) Object.assign(fields, { power: k.isOn });
  } else if (k.kind === "cover" && k.positionWritable === true) {
    const pos = options?.lastCoverPosition ?? (k.motion === "stopped" ? k.positionPercent : null);
    if (pos !== null && Number.isFinite(pos)) Object.assign(fields, { coverPosition: Math.max(0, Math.min(100, Math.round(pos))) });
  } else {
    return null;
  }

  return canonicalMoodTarget({ deviceId: device.id, name: device.name, sourceScope, entityId, ...fields });
}

export function resolveMoodFieldCommand(
  field: MoodField,
  device: SmartDevice,
  reportedCoverPosition: number | null,
): { readonly command: DeviceCommand; readonly restore: readonly DeviceCommand[]; readonly intent: DeviceIntent | null } | null {
  if (field.kind === "coverPosition") {
    if (device.kind.kind !== "cover" || device.kind.positionWritable !== true || !device.kind.entityId) return null;
    const clamped = Math.max(0, Math.min(100, Math.round(field.value)));
    const prior = reportedCoverPosition !== null && Number.isFinite(reportedCoverPosition)
      ? Math.max(0, Math.min(100, Math.round(reportedCoverPosition))) : null;
    return {
      command: { kind: "setNumberValue", entityId: device.kind.entityId, value: clamped },
      restore: prior !== null && prior !== clamped ? [{ kind: "setNumberValue", entityId: device.kind.entityId, value: prior }] : [],
      intent: null,
    };
  }
  if (field.kind === "power" && device.kind.kind === "plug" && device.kind.switchEntityId.startsWith("button.")) return null;
  if (field.kind === "hvacMode" && !moodCanWriteHvacMode(device, field.value)) return null;

  const rawOp: IntentOperation =
    field.kind === "power" ? { kind: "power", isOn: field.value } :
    field.kind === "hvacMode" ? { kind: "hvacMode", mode: field.value } :
    field.kind === "brightness" ? { kind: "brightness", percent: field.value } :
    field.kind === "colorTemperature" ? { kind: "colorTemperature", kelvin: field.value } :
    { kind: "targetTemperature", celsius: field.value };

  const normalized = IntentValidator.normalize(rawOp, device);
  if (!normalized) return null;
  if (rawOp.kind === "power" && (normalized.kind !== "power" || normalized.isOn !== rawOp.isOn)) return null;
  const intent: DeviceIntent = { targetId: device.id, operation: normalized };
  const cmds = IntentValidator.commandsForIntent(intent, device);
  if (cmds.length !== 1) return null;
  return { command: cmds[0]!, restore: inverseCommands(device, cmds[0]!), intent };
}
