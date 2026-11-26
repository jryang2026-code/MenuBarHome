import type { MediaPlaybackState, TvRemoteKey } from "./models.js";
import { TV_REMOTE_KEYS } from "./models.js";

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

/** HA `remote.send_command` names most TV integrations accept. */
export const HA_REMOTE_COMMAND: Readonly<Record<TvRemoteKey, string>> = {
  up: "UP", down: "DOWN", left: "LEFT", right: "RIGHT", select: "ENTER", back: "BACK",
  home: "HOME", menu: "MENU", volumeUp: "VOLUME_UP", volumeDown: "VOLUME_DOWN", mute: "MUTE", source: "INPUT",
};

/** MIoT action short names a Xiaomi TV spec may publish for each key. */
export const MIOT_REMOTE_ACTION_NAMES: Readonly<Record<TvRemoteKey, readonly string[]>> = {
  up: ["up", "press-up", "key-up"],
  down: ["down", "press-down", "key-down"],
  left: ["left", "press-left", "key-left"],
  right: ["right", "press-right", "key-right"],
  select: ["ok", "confirm", "select", "enter", "press-ok"],
  back: ["back", "return", "press-back"],
  home: ["home", "press-home", "go-home"],
  menu: ["menu", "press-menu"],
  volumeUp: ["volume-up"],
  volumeDown: ["volume-down"],
  mute: ["mute-on", "mute"],
  source: ["input", "source", "switch-input"],
};

export const TV_REMOTE_SERVICE_NAMES: readonly string[] = ["remote-control", "television", "stb"];

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
