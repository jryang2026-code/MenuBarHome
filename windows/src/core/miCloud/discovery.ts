import type { MiCloudClient, MiDeviceRecord, MiRoom } from "./client.js";
import { MiCloudError } from "./session.js";

// Which devices and rooms an account has, across its own and shared homes. The Windows side of
// `Sources/MijiaCore/MiCloud/MiCloudDiscovery.swift`.

type DiscoveryClient = Pick<MiCloudClient, "deviceList" | "homeRooms" | "devicesByDids" | "homeDevices">;

export interface MiDiscoveryOptions {
  /** Room dids no lookup has resolved. Kept by the caller across refreshes and updated in place. */
  readonly unresolvedDids: Set<string>;
  /** Ask again for dids an earlier refresh gave up on. */
  readonly retryUnresolved: boolean;
  /** Rooms from the last room read that answered for this connection, or null when there is none. */
  readonly cachedRooms: () => readonly MiRoom[] | null;
  /** Called with the rooms of a room read that answered, so a later failed read can fall back to them. */
  readonly onRoomsRead: (rooms: MiRoom[]) => void;
}

export interface MiHomeDiscovery {
  readonly devices: MiDeviceRecord[];
  readonly rooms: MiRoom[];
  /** Why the room read failed, or null when it answered. `rooms` then come from the cache. */
  readonly roomsError: unknown;
}

export async function discoverMiHome(
  client: DiscoveryClient,
  options: MiDiscoveryOptions,
): Promise<MiHomeDiscovery> {
  const [listedDevices, roomResult] = await Promise.all([
    client.deviceList(),
    client.homeRooms().then(
      (rooms) => ({ rooms, error: null as unknown }),
      (error: unknown) => ({ rooms: [] as MiRoom[], error }),
    ),
  ]);
  const roomsError = roomResult.error;
  // A dead session makes every later call fail the same way, so report it even when the device
  // list answered from cache (#76).
  if (roomsError instanceof MiCloudError && roomsError.kind === "sessionExpired") {
    throw roomsError;
  }
  // A shared home's devices live behind its own listing, so an empty list plus a failed room
  // read would otherwise render as a real empty account (#76).
  if (listedDevices.length === 0 && roomsError) throw roomsError;
  let effectiveRooms: MiRoom[];
  if (roomsError === null) {
    effectiveRooms = roomResult.rooms;
    options.onRoomsRead(roomResult.rooms);
  } else {
    effectiveRooms = [...(options.cachedRooms() ?? [])];
  }
  // Shared-home dids resolve first so `home_device_list` only runs for a home still missing
  // devices, which keeps a normal account to the two requests it always made.
  let lookupError: unknown = null;
  const recordLookupError = (err: unknown): void => {
    if (lookupError === null) lookupError = err;
  };
  const withShared = await withSharedHomeDevices(
    client,
    listedDevices,
    effectiveRooms,
    options.unresolvedDids,
    options.retryUnresolved,
    recordLookupError,
  );
  const completed = await withHomeDeviceLists(
    client,
    withShared,
    effectiveRooms,
    options.unresolvedDids,
    recordLookupError,
  );
  if (completed.devices.length === 0 && lookupError !== null) throw lookupError;
  return { devices: completed.devices, rooms: completed.rooms, roomsError };
}

/** Looks up the dids a room names but the device list left out, which a shared home does (#76). */
export async function withSharedHomeDevices(
  client: Pick<MiCloudClient, "devicesByDids">,
  listed: MiDeviceRecord[],
  rooms: MiRoom[],
  unresolvedDids: Set<string>,
  retryUnresolved: boolean,
  onLookupError?: (err: unknown) => void,
): Promise<MiDeviceRecord[]> {
  if (retryUnresolved) unresolvedDids.clear();
  const listedDids = new Set(listed.map((d) => d.did));
  const missing = [...new Set(rooms.flatMap((r) => r.dids))]
    .filter((did) => !listedDids.has(did) && !unresolvedDids.has(did))
    .sort();
  if (missing.length === 0) return listed;
  try {
    const extra = (await client.devicesByDids(missing)).filter((d) => !listedDids.has(d.did));
    const found = new Set(extra.map((d) => d.did));
    for (const did of missing) if (!found.has(did)) unresolvedDids.add(did);
    return [...listed, ...extra];
  } catch (err) {
    if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
    onLookupError?.(err);
    return listed;
  }
}

/**
 * A home shared with this account can list devices the unfiltered endpoint leaves out (#76).
 * `home_device_list` answers per home, so homes whose dids produced nothing are asked directly;
 * a home with no owner uid cannot use it. Rooms the newer listing adds are appended, because the
 * synthesizer places a device by the room that names it.
 */
export async function withHomeDeviceLists(
  client: Pick<MiCloudClient, "homeDevices">,
  listed: MiDeviceRecord[],
  rooms: MiRoom[],
  unresolvedDids: Set<string>,
  onLookupError?: (err: unknown) => void,
): Promise<{ devices: MiDeviceRecord[]; rooms: MiRoom[] }> {
  const ownerByHome = new Map<string, string>();
  for (const room of rooms) {
    const homeId = room.homeId ?? "";
    if (homeId && room.ownerUid && !ownerByHome.has(homeId)) ownerByHome.set(homeId, room.ownerUid);
  }
  if (ownerByHome.size === 0) return { devices: listed, rooms };
  const listedDids = new Set(listed.map((record) => record.did));
  const devices = [...listed];
  const workingRooms = [...rooms];
  for (const [homeId, ownerUid] of ownerByHome) {
    const homeDids = new Set(workingRooms.filter((room) => room.homeId === homeId).flatMap((room) => room.dids));
    const resolved = [...homeDids].filter((did) => listedDids.has(did)).length;
    const unresolved = [...homeDids].some((did) => !listedDids.has(did) && unresolvedDids.has(did));
    // Only ask a home whose devices the list (and the by-did lookup that already ran) left open.
    if (!(homeDids.size === 0 || resolved === 0 || unresolved)) continue;
    let found: MiDeviceRecord[];
    try {
      found = await client.homeDevices(homeId, ownerUid);
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      onLookupError?.(err);
      continue;
    }
    const fresh = found.filter((record) => !listedDids.has(record.did));
    for (const record of fresh) {
      listedDids.add(record.did);
      unresolvedDids.delete(record.did);
    }
    devices.push(...fresh);
    // Devices the home reports but no room names land in the home's room-less bucket, so
    // selecting that home still shows them.
    appendMissingRoomDids(workingRooms, found, homeId);
  }
  return { devices, rooms: workingRooms };
}

/**
 * Adds each device neither named in `homeId` nor covered by a split parent in `homeId` to that
 * home's `home_<id>` bucket, preserving parent-room inheritance for multi-key switch panels.
 */
function appendMissingRoomDids(rooms: MiRoom[], records: readonly MiDeviceRecord[], homeId: string): void {
  if (records.length === 0) return;
  const namedInHome = new Set(rooms.filter((room) => room.homeId === homeId).flatMap((room) => room.dids));
  const seen = new Set<string>();
  const missing: string[] = [];
  for (const record of records) {
    if (namedInHome.has(record.did)) continue;
    if (record.splitParentDid && namedInHome.has(record.splitParentDid)) continue;
    if (seen.has(record.did)) continue;
    seen.add(record.did);
    missing.push(record.did);
  }
  if (missing.length === 0) return;
  const targetId = `home_${homeId}`;
  const sibling = rooms.find((room) => room.homeId === homeId);
  const index = rooms.findIndex((room) => room.id === targetId);
  if (index >= 0) {
    const room = rooms[index];
    if (!room) return;
    rooms[index] = { ...room, dids: [...room.dids, ...missing] };
    return;
  }
  rooms.push({
    id: targetId,
    name: "",
    dids: missing,
    homeId,
    homeName: sibling?.homeName ?? "",
    ...(sibling?.isSharedHome === true ? { isSharedHome: true as const } : {}),
    ...(sibling?.ownerUid ? { ownerUid: sibling.ownerUid } : {}),
  });
}
