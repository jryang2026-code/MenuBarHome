import type { DeviceKind, SmartDevice } from "../core/models.js";
import {
  applyKindOrder,
  applyRoomOrder,
  hiddenDeviceIds,
  layoutForDevices,
  type LayoutPrefs,
} from "./panelPrefs.js";

export type DeviceKindTag = DeviceKind["kind"];

export type DeviceListCut =
  | { readonly kind: "all" }
  | { readonly kind: "room"; readonly roomId: string; readonly roomName: string }
  | { readonly kind: "deviceKind"; readonly tag: DeviceKindTag };

/** A room button: identity plus the display name, which two homes may share. */
export interface RoomOption {
  readonly id: string;
  readonly name: string;
}

export interface ListCutFilterOptions {
  readonly layout?: LayoutPrefs;
  readonly hiddenIds?: Iterable<string>;
  readonly includeHidden?: boolean;
  readonly kindOrder?: readonly string[];
  readonly roomAliases?: Readonly<Record<string, string>>;
}

export const KIND_RANK: Record<DeviceKindTag, number> = {
  climate: 0,
  light: 1,
  plug: 2,
  fan: 3,
  vacuum: 4,
  fridge: 5,
  speaker: 6,
  camera: 7,
  sensor: 8,
  cover: 9,
  appliance: 10,
  generic: 11,
};

export const KIND_CHIP: Record<
  DeviceKindTag,
  { readonly title: string; readonly hint?: string }
> = {
  climate: { title: "空调", hint: "也包括电暖器、温控器和电热毯" },
  light: { title: "灯" },
  plug: { title: "插座", hint: "也包括开关、香薰，以及带开关的小家电" },
  fan: { title: "风扇", hint: "也包括净化器、新风、加湿器和除湿器" },
  vacuum: { title: "扫地机" },
  fridge: { title: "冰箱" },
  speaker: { title: "音箱" },
  camera: { title: "摄像机" },
  sensor: { title: "传感器", hint: "也包括没有开关的小家电" },
  cover: { title: "门窗" },
  appliance: { title: "家电", hint: "也包括热水器、浴霸、油烟机与洗衣烘干洗碗机" },
  generic: { title: "通用", hint: "没有专用卡片、但仍有可用控件的设备" },
};

function resolveHiddenSet(
  devices: readonly SmartDevice[],
  options?: ListCutFilterOptions,
): ReadonlySet<string> | null {
  if (options?.includeHidden) return null;
  if (options?.hiddenIds !== undefined) {
    const set = new Set(options.hiddenIds);
    return set.size > 0 ? set : null;
  }
  const layout = options?.layout ?? layoutForDevices(devices);
  if (!layout) return null;
  const ids = hiddenDeviceIds(layout);
  return ids.length > 0 ? new Set(ids) : null;
}

function visible(
  devices: readonly SmartDevice[],
  hideOffline: boolean,
  hiddenSet: ReadonlySet<string> | null,
): SmartDevice[] {
  return devices.filter((dev) => {
    if (hiddenSet?.has(dev.id)) return false;
    if (hideOffline && !dev.isOnline) return false;
    return true;
  });
}

export function filterByListCut(
  devices: readonly SmartDevice[],
  cut: DeviceListCut,
  hideOffline: boolean,
  options?: ListCutFilterOptions,
): SmartDevice[] {
  const hiddenSet = resolveHiddenSet(devices, options);
  const layout = options?.roomAliases !== undefined ? null : (options?.layout ?? layoutForDevices(devices));
  const roomAliases = options?.roomAliases ?? layout?.roomAliases;
  const filtered = visible(devices, hideOffline, hiddenSet).filter((dev) => {
    if (cut.kind === "room") return dev.roomId === cut.roomId;
    if (cut.kind === "deviceKind") return dev.kind.kind === cut.tag;
    return true;
  });
  if (!roomAliases || Object.keys(roomAliases).length === 0) return filtered;
  return filtered.map((dev) => {
    const alias = dev.roomId ? roomAliases[dev.roomId]?.trim() : undefined;
    return alias && alias !== dev.roomName ? { ...dev, roomName: alias } : dev;
  });
}

export function memberGroupOwners(
  membersByGroup: ReadonlyMap<string, readonly string[]>,
): Map<string, string> {
  const owners = new Map<string, string>();
  for (const [groupDid, memberDids] of membersByGroup) {
    for (const did of memberDids) {
      if (!owners.has(did)) owners.set(did, groupDid);
    }
  }
  return owners;
}

/**
 * Hides member lights only while their owning group card is itself on screen;
 * a group filtered out by room/kind/offline leaves its members visible.
 */
export function foldGroupedLights(
  devices: readonly SmartDevice[],
  owners: ReadonlyMap<string, string>,
): SmartDevice[] {
  if (owners.size === 0) return [...devices];
  const listed = new Set(devices.map((device) => device.id));
  return devices.filter((device) => {
    const owner = owners.get(device.id);
    return owner === undefined || !listed.has(owner);
  });
}

export function kindChips(
  devices: readonly SmartDevice[],
  cut: DeviceListCut,
  hideOffline: boolean,
  options?: ListCutFilterOptions,
): DeviceKindTag[] {
  const hiddenSet = resolveHiddenSet(devices, options);
  const tags = new Set(visible(devices, hideOffline, hiddenSet).map((dev) => dev.kind.kind));
  if (cut.kind === "deviceKind") tags.add(cut.tag);
  const layout = options?.kindOrder !== undefined ? null : (options?.layout ?? layoutForDevices(devices));
  const customKindOrder = options?.kindOrder ?? layout?.kindOrder;
  return applyKindOrder(customKindOrder, [...tags], KIND_RANK);
}

/** Applies saved `roomOrder` and local `roomAliases` to `RoomOption[]`. */
export function orderAndAliasRooms(
  rooms: readonly RoomOption[],
  prefs: Pick<LayoutPrefs, "roomOrder" | "roomAliases"> | null | undefined,
): RoomOption[] {
  return applyRoomOrder(prefs, rooms);
}

export function showsKindRow(chips: readonly DeviceKindTag[], cut: DeviceListCut): boolean {
  return cut.kind === "deviceKind" || chips.length >= 2;
}
