import { currentLanguage } from "./i18n.js";
import type { SmartDevice } from "./models.js";

export const GROUP_COVER_IGNORE_WINDOW_MS = 60_000;

export type RoomAutoGroupKind = "light" | "cover" | "plug" | "fan" | "climate";

const KIND_ORDER: readonly RoomAutoGroupKind[] = ["light", "cover", "plug", "fan", "climate"];

/** Circular mean of hue angles in degrees, normalized to [0, 360). */
export function circularHueMean(hues: readonly number[]): number | null {
  let sumSin = 0;
  let sumCos = 0;
  let count = 0;
  for (const hue of hues) {
    if (!Number.isFinite(hue)) continue;
    const rad = (hue * Math.PI) / 180;
    sumSin += Math.sin(rad);
    sumCos += Math.cos(rad);
    count += 1;
  }
  if (count === 0 || Math.hypot(sumSin, sumCos) <= 1e-9) return null;
  let deg = (Math.atan2(sumSin, sumCos) * 180) / Math.PI;
  if (deg < 0) deg += 360;
  return deg >= 360 - 1e-9 ? 0 : deg;
}

export interface RoomAutoGroup {
  readonly id: string;
  readonly roomId: string;
  readonly roomName: string;
  readonly kind: RoomAutoGroupKind;
  readonly deviceIds: readonly string[];
  readonly count: number;
  readonly isAnyOn: boolean;
  readonly activeCount: number;
  readonly averageBrightness: number | null;
  readonly averageHueDegrees: number | null;
  readonly averageCoverPosition: number | null;
  readonly supportsBrightnessControl: boolean;
  readonly label: string;
  readonly statusSummary: string | null;
}

function groupKindOf(device: SmartDevice): RoomAutoGroupKind | null {
  const k = device.kind;
  switch (k.kind) {
    case "light":
      return k.powerWritable !== false || k.brightnessWritable !== false ? "light" : null;
    case "cover":
      return k.positionWritable || (k.openDescription !== null && k.closeDescription !== null) ? "cover" : null;
    case "plug":
      return k.powerWritable !== false && !k.switchEntityId.startsWith("button.") ? "plug" : null;
    case "fan":
      return k.powerWritable !== false ? "fan" : null;
    case "climate":
      return k.powerWritable !== false ? "climate" : null;
    default:
      return null;
  }
}

function isMemberActive(device: SmartDevice, kind: RoomAutoGroupKind): boolean {
  const k = device.kind;
  if (kind === "light" && k.kind === "light") return k.isOn;
  if (kind === "plug" && k.kind === "plug") return k.isOn;
  if (kind === "fan" && k.kind === "fan") return k.isOn;
  if (kind === "climate" && k.kind === "climate") return k.isOn && k.hvacMode !== "off";
  if (kind === "cover" && k.kind === "cover") return (k.positionPercent ?? 0) > 0;
  return false;
}

function formatGroupLabel(roomName: string, kind: RoomAutoGroupKind, count: number): string {
  const prefix = roomName.trim();
  const isEn = currentLanguage() === "en";
  const unit = isEn
    ? kind === "light" ? "lights" : kind === "cover" ? "covers" : kind === "plug" ? "plugs" : kind === "fan" ? "fans" : "ACs"
    : kind === "light" ? "盏灯" : kind === "cover" ? "个窗帘" : kind === "plug" ? "个插座" : kind === "fan" ? "台风扇" : "台空调";
  return prefix ? `${prefix} ${count} ${unit}` : `${count} ${unit}`;
}

/** Groups controllable online devices in a room by kind whenever >= 2 share a kind. */
export function buildRoomAutoGroups(
  roomId: string,
  roomName: string,
  devices: readonly SmartDevice[],
): RoomAutoGroup[] {
  const buckets = new Map<RoomAutoGroupKind, SmartDevice[]>();
  for (const device of devices) {
    if (device.roomId !== roomId || !device.isOnline) continue;
    const kind = groupKindOf(device);
    if (!kind) continue;
    const list = buckets.get(kind);
    if (list) list.push(device);
    else buckets.set(kind, [device]);
  }
  const result: RoomAutoGroup[] = [];
  for (const kind of KIND_ORDER) {
    const members = buckets.get(kind);
    if (!members || members.length < 2) continue;
    const activeMembers = members.filter((d) => isMemberActive(d, kind));
    const isAnyOn = activeMembers.length > 0;
    let averageBrightness: number | null = null;
    let averageHueDegrees: number | null = null;
    let supportsBrightnessControl = false;
    if (kind === "light") {
      const source = isAnyOn ? activeMembers : members;
      const brights: number[] = [];
      const hues: number[] = [];
      for (const dev of source) {
        if (dev.kind.kind !== "light") continue;
        if (dev.kind.brightnessPercent !== null) brights.push(dev.kind.brightnessPercent);
        if (typeof dev.kind.hueDegrees === "number") hues.push(dev.kind.hueDegrees);
      }
      if (isAnyOn && brights.length > 0) {
        averageBrightness = Math.round(brights.reduce((a, b) => a + b, 0) / brights.length);
      }
      averageHueDegrees = circularHueMean(hues);
      supportsBrightnessControl = members.some((d) => d.kind.kind === "light" && d.kind.brightnessWritable !== false);
    }
    let averageCoverPosition: number | null = null;
    if (kind === "cover") {
      const positions = members
        .map((d) => (d.kind.kind === "cover" ? d.kind.positionPercent : null))
        .filter((p): p is number => p !== null);
      if (positions.length > 0) {
        averageCoverPosition = Math.round(positions.reduce((a, b) => a + b, 0) / positions.length);
      }
    }
    const statusSummary =
      kind === "light"
        ? isAnyOn ? (averageBrightness !== null ? `${averageBrightness}%` : `${activeMembers.length}/${members.length}`) : null
        : kind === "cover"
          ? averageCoverPosition !== null ? `${averageCoverPosition}%` : (isAnyOn ? `${activeMembers.length}/${members.length}` : null)
          : isAnyOn ? `${activeMembers.length}/${members.length}` : null;
    result.push({
      id: `${roomId}:${kind}`,
      roomId,
      roomName,
      kind,
      deviceIds: members.map((d) => d.id),
      count: members.length,
      isAnyOn,
      activeCount: activeMembers.length,
      averageBrightness,
      averageHueDegrees,
      averageCoverPosition,
      supportsBrightnessControl,
      label: formatGroupLabel(roomName, kind, members.length),
      statusSummary,
    });
  }
  return result;
}
