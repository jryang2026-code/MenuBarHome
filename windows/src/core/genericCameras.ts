import { isLocalNetworkEndpoint } from "./assistant/provider.js";
import type { SmartDevice } from "./models.js";

export type GenericCameraKind = "rtsp" | "onvif" | "isapi" | "dahua" | "tapo";
export type GenericCameraProfile = "main" | "sub";
export const GENERIC_CAMERA_KINDS: readonly GenericCameraKind[] = ["rtsp", "onvif", "isapi", "dahua", "tapo"] as const;
export const GENERIC_CAMERA_DEVICE_ID_PREFIX = "generic-camera:";

/** Shared contract (`Shared/genericCameraSources.schema.json`). Credentials live only in Windows Credential Manager (`generic-camera:<id>`). */
export interface GenericCameraConfig {
  readonly id: string;
  readonly name: string;
  readonly kind: GenericCameraKind;
  readonly host: string;
  readonly port?: number;
  readonly path?: string;
  readonly channel?: number;
  readonly mainStream?: string;
  readonly subStream?: string;
}

export interface GenericCameraCredentials {
  readonly username?: string;
  readonly password?: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isGenericCameraKind(v: unknown): v is GenericCameraKind {
  return typeof v === "string" && (GENERIC_CAMERA_KINDS as readonly string[]).includes(v);
}

export function isValidGenericCameraId(id: string): boolean {
  return UUID_RE.test(id);
}

export const genericCameraDeviceId = (id: string): string => `${GENERIC_CAMERA_DEVICE_ID_PREFIX}${id}`;
export const isGenericCameraDeviceId = (deviceId: string): boolean => deviceId.startsWith(GENERIC_CAMERA_DEVICE_ID_PREFIX);

export function genericCameraIdFromDeviceId(deviceId: string): string | null {
  if (!isGenericCameraDeviceId(deviceId)) return null;
  const raw = deviceId.slice(GENERIC_CAMERA_DEVICE_ID_PREFIX.length);
  return isValidGenericCameraId(raw) ? raw : null;
}

export const normalizeGenericCameraHost = (raw: string): string => raw.trim().replace(/^\[|\]$/g, "").replace(/\.$/, "").toLowerCase();

export function isPrivateOrLocalCameraHost(rawHost: string): boolean {
  const host = normalizeGenericCameraHost(rawHost);
  if (!host || /[\s\x00-\x1f/@?#]/.test(host)) return false;
  return isLocalNetworkEndpoint({ scheme: "http", host, port: null });
}

/** RFC 3986 percent-encoding matching Rust `camera_stream::urlencoding_simple`. */
export function encodeCameraCredentialComponent(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`);
}

/** Builds the read-only go2rtc source string matching `Tests/Fixtures/generic_camera_sources_golden.json`. Never log with real credentials. */
export function buildGenericCameraSourceUrl(
  config: GenericCameraConfig,
  profile: GenericCameraProfile = "main",
  credentials: GenericCameraCredentials | "placeholder" = "placeholder",
): string {
  const selector = profile === "sub" ? config.subStream : config.mainStream;
  const cleanHost = normalizeGenericCameraHost(config.host);
  const host = cleanHost.includes(":") ? `[${cleanHost}]` : cleanHost;
  const user = credentials === "placeholder" ? "{user}" : encodeCameraCredentialComponent(credentials.username ?? "");
  const pass = credentials === "placeholder" ? "{pass}" : encodeCameraCredentialComponent(credentials.password ?? "");
  const userinfo = user || pass ? `${user}:${pass}@` : "";
  const ch = config.channel ?? 1;
  const isSub = profile === "sub";

  switch (config.kind) {
    case "rtsp": {
      const suffix = selector ?? config.mainStream ?? config.path ?? "/";
      return `rtsp://${userinfo}${host}:${config.port ?? 554}${suffix}#backchannel=0`;
    }
    case "onvif": {
      const subtype = selector ?? (isSub ? "1" : "");
      return `onvif://${userinfo}${host}:${config.port ?? 80}${subtype ? `?subtype=${subtype}` : ""}#backchannel=0`;
    }
    case "isapi":
      return `rtsp://${userinfo}${host}:${config.port ?? 554}${selector ?? `/Streaming/Channels/${ch}${isSub ? "02" : "01"}`}#backchannel=0`;
    case "dahua":
      return `rtsp://${userinfo}${host}:${config.port ?? 554}${selector ?? `/cam/realmonitor?channel=${ch}&subtype=${isSub ? 1 : 0}`}#backchannel=0`;
    case "tapo": {
      const authority = config.port === undefined ? host : `${host}:${config.port}`;
      const query = new URLSearchParams();
      if ((selector ?? (isSub ? "1" : "0")) === "1") query.set("subtype", "1");
      if (ch > 1) query.set("channel", String(ch - 1));
      return `tapo://${pass}@${authority}${query.size ? `?${query}` : ""}`;
    }
  }
}

export function redactGenericCameraUrl(input: string): string {
  return input.replace(/((?:rtsp|rtsps|onvif|tapo|http|https):\/\/)([^/\s?#]+)@/gi, "$1***@");
}

function sanitizeStreamSelector(kind: GenericCameraKind, raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  switch (kind) {
    case "rtsp":
    case "isapi":
    case "dahua":
      return /^\/(?!\/)[^#\\\s\x00-\x1f]*$/.test(value) ? value.slice(0, 1024) : undefined;
    case "onvif":
      return /^[A-Za-z0-9._~-]{1,128}$/.test(value) ? value : undefined;
    case "tapo":
      return value === "0" || value === "1" ? value : undefined;
  }
}

export function sanitizeGenericCameraConfig(raw: unknown): GenericCameraConfig | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const id = typeof obj.id === "string" ? obj.id.trim() : "";
  const name = typeof obj.name === "string" ? obj.name.trim() : "";
  const host = typeof obj.host === "string" ? obj.host.trim() : "";
  if (!isValidGenericCameraId(id) || !name || !isGenericCameraKind(obj.kind) || !host || /[\s\x00-\x1f/@?#]/.test(host)) {
    return null;
  }
  const port = typeof obj.port === "number" && Number.isInteger(obj.port) && obj.port >= 1 && obj.port <= 65535 ? obj.port : undefined;
  const rawPath = typeof obj.path === "string" ? obj.path.trim() : "";
  const path = obj.kind === "rtsp" && rawPath
    ? sanitizeStreamSelector("rtsp", rawPath.startsWith("/") ? rawPath : `/${rawPath}`)?.slice(0, 512)
    : undefined;
  const channel = typeof obj.channel === "number" && Number.isInteger(obj.channel) && obj.channel >= 1 && obj.channel <= 999 ? obj.channel : undefined;
  const mainStream = sanitizeStreamSelector(obj.kind, obj.mainStream);
  const subStream = sanitizeStreamSelector(obj.kind, obj.subStream);
  return {
    id,
    name: name.slice(0, 120),
    kind: obj.kind,
    host: host.slice(0, 255),
    ...(port !== undefined ? { port } : {}),
    ...(path !== undefined ? { path } : {}),
    ...(channel !== undefined ? { channel } : {}),
    ...(mainStream !== undefined ? { mainStream } : {}),
    ...(subStream !== undefined ? { subStream } : {}),
  };
}

export function sanitizeGenericCamerasList(raw: unknown): GenericCameraConfig[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: GenericCameraConfig[] = [];
  for (const item of raw) {
    const clean = sanitizeGenericCameraConfig(item);
    if (clean && !seen.has(clean.id)) {
      seen.add(clean.id);
      out.push(clean);
    }
  }
  return out;
}

export function genericCameraToSmartDevice(config: GenericCameraConfig, roomLabel = "通用摄像机"): SmartDevice {
  const devId = genericCameraDeviceId(config.id);
  return {
    id: devId,
    name: config.name,
    roomId: "generic-cameras",
    roomName: roomLabel,
    model: `generic.camera.${config.kind}`,
    isOnline: true,
    kind: {
      kind: "camera",
      entityId: devId,
      isOn: true,
      powerWritable: false,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
      streamEntityId: null,
    },
  };
}

export function generateGenericCameraId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const h = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
  return `${h()}${h()}-${h()}-4${h().slice(1)}-8${h().slice(1)}-${h()}${h()}${h()}`;
}
