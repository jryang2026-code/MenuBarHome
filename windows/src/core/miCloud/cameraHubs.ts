import { speechLocale } from "../i18n.js";
import type { DeviceKind, SmartDevice } from "../models.js";
import { MiCloudClient, type MiDeviceRecord, type MiRoom } from "./client.js";
import { asIdString, MiCloudError } from "./session.js";

/** Locale-aware inline text helper for camera gateway / HUD labels (`i18n.ts` stays untouched). */
export function cameraTr(zh: string, en: string): string {
  return speechLocale().toLowerCase().startsWith("en") ? en : zh;
}

/**
 * Battery cameras that pair with an indoor gateway instead of exposing their own LAN P2P listener.
 * Mirrors macOS `CameraHubCatalog`.
 */
export const CameraHubCatalog = {
  hubModel(model: string): string | null {
    const normalized = model.trim().toLowerCase();
    if (normalized.startsWith("mxiang.camera.mwc11")) {
      return "mxiang.camera.mwc10";
    }
    return null;
  },

  isHub(model: string): boolean {
    return model.trim().toLowerCase().startsWith("mxiang.camera.mwc10");
  },
} as const;

export interface CameraRecordMetadata {
  readonly did: string;
  readonly model: string;
  readonly isOnline?: boolean;
  readonly localIp?: string | null;
  readonly localip?: string | null;
  readonly parentDid?: string | null;
  readonly parent_id?: string | null;
  readonly extra?: Record<string, unknown> | null;
}

export function extractRecordLocalIp(record: CameraRecordMetadata | Record<string, unknown> | null | undefined): string {
  if (!record) return "";
  const rec = record as Record<string, unknown>;
  const camel = typeof rec["localIp"] === "string" ? rec["localIp"].trim() : "";
  if (camel) return camel;
  const lower = typeof rec["localip"] === "string" ? rec["localip"].trim() : "";
  return lower;
}

export function extractRecordParentDid(record: CameraRecordMetadata | Record<string, unknown> | null | undefined): string {
  if (!record) return "";
  const rec = record as Record<string, unknown>;
  for (const key of ["parentDid", "parent_id"]) {
    const val = rec[key];
    if (typeof val === "string" && val.trim()) return val.trim();
    if (typeof val === "number" && Number.isFinite(val)) return String(Math.trunc(val));
  }
  const extra = rec["extra"];
  if (extra && typeof extra === "object") {
    const ext = extra as Record<string, unknown>;
    for (const key of ["parentDid", "parent_id", "parentId"]) {
      const val = ext[key];
      if (typeof val === "string" && val.trim()) return val.trim();
      if (typeof val === "number" && Number.isFinite(val)) return String(Math.trunc(val));
    }
  }
  return "";
}

function recordIsOnline(record: CameraRecordMetadata | Record<string, unknown>): boolean {
  const online = (record as Record<string, unknown>)["isOnline"];
  return typeof online === "boolean" ? online : true;
}

function matchesHubPrefix(model: string, hubPrefix: string): boolean {
  return model.trim().toLowerCase().startsWith(hubPrefix);
}

/**
 * Validates and normalizes an RFC 1918 private IPv4 LAN address (`10/8`, `172.16/12`, `192.168/16`).
 * Returns `null` when malformed or outside private LAN space.
 */
export function parsePrivateLanIpv4(raw: string): string | null {
  const trimmed = raw.trim();
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(trimmed);
  if (!match) return null;
  const octets: number[] = [];
  for (let i = 1; i <= 4; i += 1) {
    const part = match[i]!;
    if (part.length > 1 && part.startsWith("0")) return null;
    const value = Number(part);
    if (!Number.isInteger(value) || value < 0 || value > 255) return null;
    octets.push(value);
  }
  const [a, b, c, d] = octets as [number, number, number, number];
  const isPrivate =
    a === 2 * 5 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168);
  if (!isPrivate) return null;
  return `${a}.${b}.${c}.${d}`;
}

export interface CameraHubResolution<T> {
  readonly hub: T | null;
  readonly reason: "not_required" | "matched" | "missing_hub" | "offline_hub" | "ambiguous_hub";
}

/**
 * Resolves the unambiguous online indoor gateway for a battery camera within the same home/room scope,
 * matching macOS `MiCloudProvider.hubRecord`:
 * - Prefers the first room containing `camera.did` that also contains a hub `did`.
 * - Scopes candidate hubs strictly to `cameraRoom.homeId` when non-empty (else `[onlyHub]` if `allHubs.length === 1`,
 *   else `cameraRoom.dids`).
 * - Checks `cameraRoom` hubs first (`> 1` online -> `ambiguous_hub`; `1` online -> match; offline in room -> `offline_hub`),
 *   and across rooms matches only when total hubs in that home (`scoped.length`) is `1`.
 */
export function resolveCameraHub<T extends CameraRecordMetadata>(
  camera: CameraRecordMetadata,
  devices: readonly T[],
  rooms: readonly MiRoom[] = [],
): CameraHubResolution<T> {
  const hubPrefix = CameraHubCatalog.hubModel(camera.model);
  if (!hubPrefix) return { hub: null, reason: "not_required" };

  const allHubs = devices.filter(
    (candidate) => candidate.did !== camera.did && matchesHubPrefix(candidate.model, hubPrefix),
  );
  if (allHubs.length === 0) return { hub: null, reason: "missing_hub" };

  const hubDids = new Set(allHubs.map((hub) => hub.did));
  const cameraRooms = rooms.filter((room) => room.dids.includes(camera.did));
  const cameraRoom =
    cameraRooms.find((room) => room.dids.some((did) => hubDids.has(did))) ?? cameraRooms[0];
  const cameraHomeId = cameraRoom?.homeId?.trim() ?? "";

  const parentDid = extractRecordParentDid(camera);
  if (parentDid) {
    const parentHub = allHubs.find((candidate) => candidate.did === parentDid);
    if (!parentHub) return { hub: null, reason: "missing_hub" };
    const parentHomeIds = new Set(
      rooms
        .filter((room) => room.dids.includes(parentHub.did))
        .map((room) => room.homeId?.trim() ?? "")
        .filter((hid) => hid !== ""),
    );
    const distinctHomeIds = new Set(
      rooms.map((room) => room.homeId?.trim() ?? "").filter((hid) => hid !== ""),
    );
    if (cameraHomeId) {
      const homeDids = new Set(
        rooms.filter((room) => (room.homeId?.trim() ?? "") === cameraHomeId).flatMap((room) => room.dids),
      );
      if ((parentHomeIds.size > 0 && !parentHomeIds.has(cameraHomeId)) || (!homeDids.has(parentHub.did) && distinctHomeIds.size > 1)) {
        return { hub: null, reason: "missing_hub" };
      }
    } else if (parentHomeIds.size > 0 && distinctHomeIds.size > 1) {
      return { hub: null, reason: "missing_hub" };
    }
    if (!recordIsOnline(parentHub)) return { hub: null, reason: "offline_hub" };
    return { hub: parentHub, reason: "matched" };
  }

  let scoped: T[];
  if (cameraRoom && cameraHomeId) {
    const homeDids = new Set(
      rooms.filter((room) => (room.homeId?.trim() ?? "") === cameraHomeId).flatMap((room) => room.dids),
    );
    scoped = allHubs.filter((hub) => homeDids.has(hub.did));
  } else if (allHubs.length === 1) {
    scoped = allHubs;
  } else if (cameraRoom) {
    const roomDids = new Set(cameraRoom.dids);
    scoped = allHubs.filter((hub) => roomDids.has(hub.did));
  } else {
    scoped = [];
  }

  const online = scoped.filter((hub) => recordIsOnline(hub));
  if (cameraRoom) {
    const roomDids = new Set(cameraRoom.dids);
    const allInRoom = scoped.filter((hub) => roomDids.has(hub.did));
    const onlineInRoom = online.filter((hub) => roomDids.has(hub.did));
    if (onlineInRoom.length > 1) return { hub: null, reason: "ambiguous_hub" };
    if (onlineInRoom.length === 1) return { hub: onlineInRoom[0]!, reason: "matched" };
    if (allInRoom.length > 0) return { hub: null, reason: "offline_hub" };
  }

  if (scoped.length === 0) {
    return {
      hub: null,
      reason: allHubs.length > 1 && !cameraRoom ? "ambiguous_hub" : "missing_hub",
    };
  }
  if (scoped.length > 1) {
    return {
      hub: null,
      reason: online.length === 0 ? "offline_hub" : "ambiguous_hub",
    };
  }
  const onlyScoped = scoped[0]!;
  return recordIsOnline(onlyScoped)
    ? { hub: onlyScoped, reason: "matched" }
    : { hub: null, reason: "offline_hub" };
}

/** Attaches `subdid` and gateway metadata onto a synthesized battery camera when an unambiguous online hub exists. */
export function attachCameraGateway(
  kind: DeviceKind,
  record: MiDeviceRecord,
  devices: readonly MiDeviceRecord[],
  rooms: readonly MiRoom[],
): DeviceKind {
  if (kind.kind !== "camera") return kind;
  if (extractRecordLocalIp(record)) return kind;
  const resolution = resolveCameraHub(record, devices, rooms);
  if (!resolution.hub) return kind;
  const gatewayLocalIp = extractRecordLocalIp(resolution.hub);
  return {
    ...kind,
    subdid: record.did,
    gatewayDid: resolution.hub.did,
    gatewayModel: resolution.hub.model,
    ...(gatewayLocalIp ? { gatewayLocalIp } : {}),
  };
}

/** Builds fallback room hints from synthesized host devices stamped with `selectedHomeId` when `homeRooms()` is empty. */
export function buildHostRoomHints(
  hostDevices: readonly SmartDevice[],
  selectedHomeId?: string | null,
): MiRoom[] {
  const homeId = selectedHomeId?.trim() ?? "";
  const byRoom = new Map<string, { name: string; dids: string[]; isSharedHome: boolean }>();
  const otherDids: string[] = [];
  let anyShared = false;
  for (const item of hostDevices) {
    if (item.isSharedHome) anyShared = true;
    if (item.roomId === "other") {
      otherDids.push(item.id);
      continue;
    }
    const entry = byRoom.get(item.roomId) ?? {
      name: item.roomName,
      dids: [],
      isSharedHome: Boolean(item.isSharedHome),
    };
    entry.dids.push(item.id);
    if (item.isSharedHome) entry.isSharedHome = true;
    byRoom.set(item.roomId, entry);
  }
  const rooms: MiRoom[] = Array.from(byRoom.entries()).map(([id, info]) => ({
    id,
    name: info.name,
    dids: info.dids,
    ...(homeId ? { homeId } : {}),
    ...(info.isSharedHome ? { isSharedHome: true as const } : {}),
  }));
  if (homeId && otherDids.length > 0) {
    rooms.push({
      id: `home_${homeId}`,
      name: "",
      dids: otherDids,
      homeId,
      ...(anyShared ? { isSharedHome: true as const } : {}),
    });
  }
  return rooms;
}

function parseCameraMetadataItem(item: unknown): CameraRecordMetadata | null {
  if (!item || typeof item !== "object") return null;
  const rec = item as Record<string, unknown>;
  const did = asIdString(rec["did"]);
  const model = typeof rec["model"] === "string" ? rec["model"].trim() : "";
  if (!did || !model) return null;
  return {
    did,
    model,
    isOnline: typeof rec["isOnline"] === "boolean" ? rec["isOnline"] : true,
    localip: typeof rec["localip"] === "string" ? rec["localip"] : null,
    localIp: typeof rec["localIp"] === "string" ? rec["localIp"] : null,
    parent_id: asIdString(rec["parent_id"]),
    parentDid: asIdString(rec["parentDid"]),
    extra: rec["extra"] && typeof rec["extra"] === "object" ? (rec["extra"] as Record<string, unknown>) : null,
  };
}

function parseCameraMetadataResponse(result: unknown): CameraRecordMetadata[] {
  if (!result || typeof result !== "object") return [];
  const list = (result as Record<string, unknown>)["list"];
  if (!Array.isArray(list)) return [];
  const out: CameraRecordMetadata[] = [];
  for (const item of list) {
    const parsed = parseCameraMetadataItem(item);
    if (parsed) out.push(parsed);
  }
  return out;
}

async function fetchCameraMetadataPaged(
  client: MiCloudClient,
  dids?: readonly string[],
): Promise<CameraRecordMetadata[]> {
  const records: CameraRecordMetadata[] = [];
  let startDid = "";
  for (let page = 0; page < 20; page += 1) {
    const data: Record<string, unknown> = {
      get_split_device: true,
      support_smart_home: true,
      get_third_device: true,
      limit: 200,
    };
    if (dids) data["dids"] = dids;
    if (startDid) data["start_did"] = startDid;
    const res = await client.request("v2/home/device_list_page", data);
    records.push(...parseCameraMetadataResponse(res));
    const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
    const next = asIdString(obj["next_start_did"]) ?? "";
    if (obj["has_more"] !== true || !next || next === startDid) break;
    startDid = next;
  }
  const seen = new Set<string>();
  return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
}

async function fetchCameraMetadataList(client: MiCloudClient): Promise<CameraRecordMetadata[]> {
  const byDid = new Map<string, CameraRecordMetadata>();
  const merge = (items: readonly CameraRecordMetadata[]) => {
    for (const item of items) {
      const prev = byDid.get(item.did);
      if (!prev || (!extractRecordLocalIp(prev) && extractRecordLocalIp(item))) {
        byDid.set(item.did, item);
      }
    }
  };

  if (typeof client.request === "function") {
    try {
      merge(await fetchCameraMetadataPaged(client));
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      const legacy = await client.request("home/device_list", {
        getVirtualModel: true,
        getHuamiDevices: 1,
        get_split_device: false,
        support_smart_home: true,
      });
      merge(parseCameraMetadataResponse(legacy));
    }
  }

  if (
    typeof client.deviceList === "function" &&
    (typeof client.request !== "function" || client.deviceList !== MiCloudClient.prototype.deviceList)
  ) {
    const listed = await client.deviceList();
    merge(
      listed.map((r) => ({
        did: r.did,
        model: r.model,
        isOnline: r.isOnline,
        localIp: extractRecordLocalIp(r as unknown as Record<string, unknown>) || null,
        parentDid: extractRecordParentDid(r as unknown as Record<string, unknown>) || null,
      })),
    );
  }

  return Array.from(byDid.values());
}

export interface LiveCameraBridgeTarget {
  readonly bridgeDid: string;
  readonly bridgeModel: string;
  readonly subdid: string | null;
  readonly cloudLocalIp: string;
  readonly hubBlockedReason: string | null;
}

/**
 * Resolves live camera bridge target (`bridgeDid`, `bridgeModel`, `subdid`, `cloudLocalIp`) using
 * paged cloud device metadata + `client.homeRooms()`, isolating multi-home hubs and falling back
 * to synthesized `gatewayDid` / `gatewayModel` / `gatewayLocalIp` for shared-home cameras (#76).
 */
export async function resolveLiveCameraTarget(
  client: MiCloudClient,
  dev: SmartDevice,
  hostDevices: readonly SmartDevice[],
  selectedHomeId?: string | null,
): Promise<LiveCameraBridgeTarget> {
  const camSpec = dev.kind.kind === "camera" ? dev.kind : null;
  const requiresHub = CameraHubCatalog.hubModel(dev.model) !== null;

  const [initialMetadata, cloudRooms] = await Promise.all([
    fetchCameraMetadataList(client),
    client.homeRooms().catch((err: unknown) => {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      return [] as MiRoom[];
    }),
  ]);
  const rooms = cloudRooms.length > 0 ? cloudRooms : buildHostRoomHints(hostDevices, selectedHomeId);

  const byDid = new Map<string, CameraRecordMetadata>(initialMetadata.map((item) => [item.did, item]));
  const wasListed = byDid.has(dev.id);

  // Shared-home devices are omitted from unfiltered device_list; ask by did when missing (#134).
  if (typeof client.request === "function") {
    const wantedDids = new Set<string>();
    if (!byDid.has(dev.id)) wantedDids.add(dev.id);
    if (requiresHub && camSpec?.gatewayDid && !byDid.has(camSpec.gatewayDid)) {
      wantedDids.add(camSpec.gatewayDid);
    }
    if (!wasListed) {
      const camHomeIds = new Set(
        rooms
          .filter((r) => r.dids.includes(dev.id))
          .map((r) => r.homeId?.trim() ?? "")
          .filter((hid) => hid !== ""),
      );
      for (const room of rooms) {
        if (camHomeIds.has(room.homeId?.trim() ?? "")) {
          for (const did of room.dids) {
            if (!byDid.has(did)) wantedDids.add(did);
          }
        }
      }
    }
    if (wantedDids.size > 0) {
      const extra = await fetchCameraMetadataPaged(client, Array.from(wantedDids).slice(0, 150)).catch(
        (err: unknown) => {
          if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
          return [] as CameraRecordMetadata[];
        },
      );
      for (const item of extra) {
        if (!byDid.has(item.did) || (!extractRecordLocalIp(byDid.get(item.did)) && extractRecordLocalIp(item))) {
          byDid.set(item.did, item);
        }
      }
    }
  }

  const metadataList = Array.from(byDid.values());
  const rawDev = byDid.get(dev.id);
  const ownCloudIp = extractRecordLocalIp(rawDev);

  if (!requiresHub || ownCloudIp) {
    return {
      bridgeDid: dev.id,
      bridgeModel: dev.model,
      subdid: camSpec?.subdid ?? null,
      cloudLocalIp: ownCloudIp || (camSpec?.gatewayLocalIp ?? "").trim(),
      hubBlockedReason: null,
    };
  }

  const camMeta: CameraRecordMetadata = rawDev ?? {
    did: dev.id,
    model: dev.model,
    isOnline: dev.isOnline,
  };
  const resolution = resolveCameraHub(camMeta, metadataList, rooms);
  if (resolution.hub) {
    return {
      bridgeDid: resolution.hub.did,
      bridgeModel: resolution.hub.model,
      subdid: camSpec?.subdid ?? dev.id,
      cloudLocalIp: extractRecordLocalIp(resolution.hub) || (camSpec?.gatewayLocalIp ?? "").trim(),
      hubBlockedReason: null,
    };
  }

  const inSharedRoom = Boolean(dev.isSharedHome) || rooms.some((r) => r.isSharedHome && r.dids.includes(dev.id));
  if (
    (!rawDev || inSharedRoom) &&
    resolution.reason === "missing_hub" &&
    camSpec?.gatewayDid &&
    camSpec.gatewayModel
  ) {
    const listedGateway = byDid.get(camSpec.gatewayDid);
    if (listedGateway && !recordIsOnline(listedGateway)) {
      return {
        bridgeDid: dev.id,
        bridgeModel: dev.model,
        subdid: null,
        cloudLocalIp: "",
        hubBlockedReason: cameraTr(
          "配对的室内网关当前离线，请检查网关电源与网络后重试",
          "The paired indoor gateway is offline; check its power and network, then retry",
        ),
      };
    }
    return {
      bridgeDid: camSpec.gatewayDid,
      bridgeModel: listedGateway?.model ?? camSpec.gatewayModel,
      subdid: camSpec.subdid ?? dev.id,
      cloudLocalIp: extractRecordLocalIp(listedGateway) || (camSpec.gatewayLocalIp ?? "").trim(),
      hubBlockedReason: null,
    };
  }

  const hubBlockedReason =
    resolution.reason === "offline_hub"
      ? cameraTr(
          "配对的室内网关当前离线，请检查网关电源与网络后重试",
          "The paired indoor gateway is offline; check its power and network, then retry",
        )
      : resolution.reason === "ambiguous_hub"
        ? cameraTr(
            "检测到多个同型号室内网关，请将摄像机与对应网关放入同一房间后重试",
            "Multiple indoor gateways found; place the camera and its gateway in the same room and retry",
          )
        : cameraTr(
            "该电池摄像机需通过配对的室内网关连接，当前未找到可用室内网关",
            "This battery camera connects through its paired indoor gateway, which could not be found",
          );

  return {
    bridgeDid: dev.id,
    bridgeModel: dev.model,
    subdid: null,
    cloudLocalIp: "",
    hubBlockedReason,
  };
}
