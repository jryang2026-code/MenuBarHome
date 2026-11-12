import { speechLocale } from "../i18n.js";
import type { DeviceKind } from "../models.js";
import type { MiDeviceRecord, MiRoom } from "./client.js";

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
 * Resolves the unambiguous online indoor gateway for a battery camera within the same home/room scope.
 * Explicit `parentDid` wins; otherwise requires either a single online hub in the home or a single
 * online hub in the camera's own room.
 */
export function resolveCameraHub<T extends CameraRecordMetadata>(
  camera: CameraRecordMetadata,
  devices: readonly T[],
  rooms: readonly MiRoom[] = [],
  roomByDid?: ReadonlyMap<string, MiRoom>,
): CameraHubResolution<T> {
  const hubPrefix = CameraHubCatalog.hubModel(camera.model);
  if (!hubPrefix) return { hub: null, reason: "not_required" };

  const map =
    roomByDid ??
    (() => {
      const built = new Map<string, MiRoom>();
      for (const room of rooms) {
        for (const did of room.dids) {
          if (!built.has(did)) built.set(did, room);
        }
      }
      return built;
    })();

  const distinctHomeIds = new Set<string>();
  for (const room of rooms) {
    const hid = room.homeId?.trim();
    if (hid) distinctHomeIds.add(hid);
  }
  const cameraRoom = map.get(camera.did);
  const cameraHomeId = cameraRoom?.homeId?.trim() ?? "";

  const sameHomeCandidates = devices.filter((candidate) => {
    if (candidate.did === camera.did || !matchesHubPrefix(candidate.model, hubPrefix)) return false;
    const candidateHomeId = map.get(candidate.did)?.homeId?.trim() ?? "";
    if (cameraHomeId && candidateHomeId) {
      return candidateHomeId === cameraHomeId;
    }
    if (distinctHomeIds.size > 1 && (cameraHomeId || candidateHomeId)) {
      return false;
    }
    return true;
  });

  const parentDid = extractRecordParentDid(camera);
  if (parentDid) {
    const parentHub = devices.find(
      (candidate) => candidate.did === parentDid && matchesHubPrefix(candidate.model, hubPrefix),
    );
    if (!parentHub) return { hub: null, reason: "missing_hub" };
    if (!recordIsOnline(parentHub)) return { hub: null, reason: "offline_hub" };
    return { hub: parentHub, reason: "matched" };
  }

  const onlineHubs = sameHomeCandidates.filter((candidate) => recordIsOnline(candidate));
  if (onlineHubs.length === 1) {
    return { hub: onlineHubs[0]!, reason: "matched" };
  }
  if (onlineHubs.length > 1) {
    if (cameraRoom) {
      const roomDids = new Set(cameraRoom.dids);
      const roomHubs = onlineHubs.filter((candidate) => roomDids.has(candidate.did));
      if (roomHubs.length === 1) {
        return { hub: roomHubs[0]!, reason: "matched" };
      }
    }
    return { hub: null, reason: "ambiguous_hub" };
  }

  return {
    hub: null,
    reason: sameHomeCandidates.length > 0 ? "offline_hub" : "missing_hub",
  };
}

/** Attaches `subdid` and `gatewayLocalIp` onto a synthesized battery camera when an unambiguous online hub exists. */
export function attachCameraGateway(
  kind: DeviceKind,
  record: MiDeviceRecord,
  devices: readonly MiDeviceRecord[],
  rooms: readonly MiRoom[],
  roomByDid: ReadonlyMap<string, MiRoom>,
): DeviceKind {
  if (kind.kind !== "camera") return kind;
  if (extractRecordLocalIp(record)) return kind;
  const resolution = resolveCameraHub(record, devices, rooms, roomByDid);
  if (!resolution.hub) return kind;
  const gatewayLocalIp = extractRecordLocalIp(resolution.hub);
  return {
    ...kind,
    subdid: record.did,
    ...(gatewayLocalIp ? { gatewayLocalIp } : {}),
  };
}
