import type { HaRemoteProfile, MediaPlaybackState, TvRemoteKey } from "./models.js";
import { HA_REMOTE_PROFILES, TV_REMOTE_KEYS } from "./models.js";

/** HA `MediaPlayerEntityFeature` bits (matches macOS `MediaPlaybackState`). */
export const MEDIA_FEATURE = { pause: 1, seek: 2, previousTrack: 16, nextTrack: 32, play: 16384 } as const;

type Attrs = Readonly<Record<string, unknown>>;

function text(attrs: Attrs, key: string): string | null {
  const raw = attrs[key];
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed ? trimmed : null;
}

function seconds(attrs: Attrs, key: string): number | null {
  const raw = attrs[key];
  return typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? raw : null;
}

export function playbackHasContent(p: MediaPlaybackState): boolean {
  if (p.state === "off") return false;
  return p.title !== null || p.appName !== null || p.state === "playing" || p.state === "paused";
}

/** Builds Now Playing from a `media_player.*` state; null when there is nothing to show. */
export function playbackFromHomeAssistant(state: string, attrs: Attrs): MediaPlaybackState | null {
  const lower = state.toLowerCase();
  const status: MediaPlaybackState["state"] =
    lower === "playing" ? "playing"
      : lower === "paused" ? "paused"
        : lower === "buffering" ? "buffering"
          : ["off", "standby", "unavailable", "unknown"].includes(lower) ? "off"
            : "idle";
  const rawFeatures = attrs.supported_features;
  const features = typeof rawFeatures === "number" && Number.isFinite(rawFeatures) ? Math.trunc(rawFeatures) : 0;
  const updatedRaw = attrs.media_position_updated_at;
  const updatedAt = typeof updatedRaw === "string" ? Date.parse(updatedRaw) : NaN;
  const playback: MediaPlaybackState = {
    state: status,
    title: text(attrs, "media_title"),
    subtitle: text(attrs, "media_artist") ?? text(attrs, "media_series_title") ?? text(attrs, "media_album_name"),
    appName: text(attrs, "app_name"),
    artworkURL: text(attrs, "entity_picture"),
    durationSec: seconds(attrs, "media_duration"),
    positionSec: seconds(attrs, "media_position"),
    positionUpdatedAt: Number.isFinite(updatedAt) ? updatedAt : null,
    playbackRate: status === "playing" ? 1 : 0,
    canPlayPause: (features & (MEDIA_FEATURE.pause | MEDIA_FEATURE.play)) !== 0,
    canSeek: (features & MEDIA_FEATURE.seek) !== 0,
    canSkipTrack: (features & (MEDIA_FEATURE.nextTrack | MEDIA_FEATURE.previousTrack)) !== 0,
  };
  return playbackHasContent(playback) ? playback : null;
}

export type ProgressStyle = "seekable" | "readOnly" | "hidden";

/** Never invents a bar: no known duration means no bar at all. */
export function progressStyle(p: MediaPlaybackState): ProgressStyle {
  if (p.durationSec === null || p.durationSec <= 0 || p.positionSec === null) return "hidden";
  return p.canSeek ? "seekable" : "readOnly";
}

/** `clamp(anchor + elapsed × rate, 0, duration)`; only a playing item advances. */
export function extrapolatedPosition(p: MediaPlaybackState, nowMs: number): number | null {
  if (p.positionSec === null) return null;
  let position = p.positionSec;
  if (p.state === "playing" && p.positionUpdatedAt !== null) {
    position += Math.max(0, (nowMs - p.positionUpdatedAt) / 1000) * p.playbackRate;
  }
  const upper = p.durationSec !== null && p.durationSec > 0 ? p.durationSec : Number.MAX_VALUE;
  return Math.min(Math.max(position, 0), upper);
}

export const SEEK_HOLD_MS = 2000;

/** Keeps a dragged seek bar from snapping back to the TV's stale position while the seek lands. */
export class MediaSeekGuard {
  isDragging = false;
  previewSec: number | null = null;
  pendingTargetSec: number | null = null;
  pendingUntil: number | null = null;

  beginDrag(positionSec: number): void {
    this.isDragging = true;
    this.previewSec = positionSec;
  }

  updateDrag(positionSec: number): void {
    if (this.isDragging) this.previewSec = positionSec;
  }

  /** Ends the drag and returns the single seek target to send. */
  endDrag(nowMs: number): number | null {
    if (!this.isDragging || this.previewSec === null) return null;
    const target = this.previewSec;
    this.isDragging = false;
    this.previewSec = null;
    this.pendingTargetSec = target;
    this.pendingUntil = nowMs + SEEK_HOLD_MS;
    return target;
  }

  displayedPosition(remote: number | null, nowMs: number): number | null {
    if (this.isDragging) return this.previewSec;
    if (this.pendingTargetSec !== null && this.pendingUntil !== null && nowMs < this.pendingUntil) {
      return this.pendingTargetSec;
    }
    return remote;
  }
}

/** Ecosystem-specific HA `remote.send_command` key tables (mirrors macOS `HARemoteProfile`). */
export const HA_REMOTE_PROFILE_COMMANDS: Readonly<Record<HaRemoteProfile, Readonly<Record<TvRemoteKey, string>>>> = {
  appleTV: { up: "up", down: "down", left: "left", right: "right", select: "select", back: "menu", home: "home", menu: "menu", volumeUp: "volume_up", volumeDown: "volume_down", mute: "mute", source: "top_menu" },
  androidTV: { up: "DPAD_UP", down: "DPAD_DOWN", left: "DPAD_LEFT", right: "DPAD_RIGHT", select: "DPAD_CENTER", back: "BACK", home: "HOME", menu: "MENU", volumeUp: "VOLUME_UP", volumeDown: "VOLUME_DOWN", mute: "MUTE", source: "TV_INPUT" },
  sonyBravia: { up: "Up", down: "Down", left: "Left", right: "Right", select: "Confirm", back: "Return", home: "Home", menu: "Options", volumeUp: "VolumeUp", volumeDown: "VolumeDown", mute: "Mute", source: "Input" },
  roku: { up: "Up", down: "Down", left: "Left", right: "Right", select: "Select", back: "Back", home: "Home", menu: "Info", volumeUp: "VolumeUp", volumeDown: "VolumeDown", mute: "VolumeMute", source: "Input" },
  generic: { up: "UP", down: "DOWN", left: "LEFT", right: "RIGHT", select: "ENTER", back: "BACK", home: "HOME", menu: "MENU", volumeUp: "VOLUME_UP", volumeDown: "VOLUME_DOWN", mute: "MUTE", source: "INPUT" },
};
export const HA_REMOTE_COMMAND: Readonly<Record<TvRemoteKey, string>> = HA_REMOTE_PROFILE_COMMANDS.generic;
export const isHaRemoteProfile = (value: unknown): value is HaRemoteProfile =>
  typeof value === "string" && (HA_REMOTE_PROFILES as readonly string[]).includes(value);

function matchHaRemoteDomain(raw: unknown): HaRemoteProfile | null {
  const domain = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (domain === "apple_tv" || domain === "appletv") return "appleTV";
  if (["androidtv_remote", "androidtv", "android_tv", "android_tv_remote", "google_tv"].includes(domain)) return "androidTV";
  if (["braviatv", "bravia_tv", "sony_bravia", "sony_bravia_psk"].includes(domain)) return "sonyBravia";
  return domain === "roku" ? "roku" : null;
}

/** Deterministically infers an HA `remote.send_command` dialect (mirrors macOS `HARemoteProfile.infer`). */
export function inferHaRemoteProfile(clues: {
  readonly platform?: string | null; readonly manufacturer?: string | null; readonly model?: string | null;
  readonly identifiers?: unknown; readonly entityId?: string | null; readonly friendlyName?: string | null;
}): HaRemoteProfile {
  const byPlatform = matchHaRemoteDomain(clues.platform);
  if (byPlatform) return byPlatform;
  if (Array.isArray(clues.identifiers)) {
    for (const pair of clues.identifiers) {
      const byId = Array.isArray(pair) ? matchHaRemoteDomain(pair[0]) : null;
      if (byId) return byId;
    }
  }
  const mfg = (clues.manufacturer ?? "").toLowerCase();
  const text = `${mfg} ${(clues.model ?? "").toLowerCase()} ${(clues.entityId ?? "").toLowerCase()} ${(clues.friendlyName ?? "").toLowerCase()}`;
  if (text.includes("apple_tv") || text.includes("appletv") || text.includes("apple tv") || (mfg.includes("apple") && text.includes("tv"))) return "appleTV";
  if (["androidtv", "android_tv", "android tv", "google_tv", "google tv", "shield", "chromecast"].some((k) => text.includes(k))) return "androidTV";
  if (text.includes("bravia") || text.includes("sony")) return "sonyBravia";
  return text.includes("roku") ? "roku" : "generic";
}

export const haRemoteCommand = (key: TvRemoteKey, profile: HaRemoteProfile = "generic"): string =>
  HA_REMOTE_PROFILE_COMMANDS[profile][key];

/** MIoT action short names a Xiaomi TV spec may publish for each key (priority order, verified against `miot-spec.org`). */
export const MIOT_REMOTE_ACTION_NAMES: Readonly<Record<TvRemoteKey, readonly string[]>> = {
  up: ["press-up", "up", "key-up"],
  down: ["press-down", "down", "key-down"],
  left: ["press-left", "left", "key-left"],
  right: ["press-right", "right", "key-right"],
  select: ["press-ok", "ok", "confirm", "press-confirm", "select", "enter"],
  back: ["press-back", "back", "return", "press-return"],
  home: ["press-home", "home", "go-home"],
  menu: ["press-menu", "menu", "press-settings"],
  volumeUp: ["press-volume-up", "volume-up", "key-volume-up"],
  volumeDown: ["press-volume-down", "volume-down", "key-volume-down"],
  mute: ["press-mute", "mute", "mute-on", "toggle-mute"],
  source: ["press-source", "press-input", "input", "source", "switch-input"],
};
export const TV_REMOTE_SERVICE_NAMES: readonly string[] = ["remote-control", "television", "stb", "ir-tv-control"];

export function isTvRemoteKey(value: unknown): value is TvRemoteKey {
  return typeof value === "string" && (TV_REMOTE_KEYS as readonly string[]).includes(value);
}

export function formatMediaTime(sec: number): string {
  const total = Math.floor(Math.max(sec, 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}
