import type { CameraEventKind } from "./cameraEventStore.js";
import type { CameraStreamQuality } from "./cameraQuality.js";
import type { CameraLens, SmartDevice } from "./models.js";

export const MAX_PINNED_CAMERA_SWITCHES = 2;
export const DEFAULT_CAMERA_PIP_AUTO_CLOSE_SECONDS = 30;
const PORTRAIT_DOORBELL_MODEL_RE = /(?:^|[._-])(doorbell|cateye|mjbell|g400)(?:$|[._-\d])/i;
const PORTRAIT_DOORBELL_NAME_RE = /(门铃|門鈴|猫眼|貓眼|\bdoorbell\b)/i;

/**
 * Decides whether a camera event should auto-open the PiP window (P1-2 PR B).
 * - OFF by default (`cameraOptIn` must be true).
 * - Blocked while the workstation is locked.
 * - Focus / Do-Not-Disturb policy (#475): doorbell is NEVER suppressed;
 *   non-doorbell alarm/detection events (`motion`, `person`, `package`) are suppressed while Focus is active.
 */
export function shouldAutoOpenCameraPipOnEvent(args: {
  readonly eventKind: CameraEventKind;
  readonly cameraOptIn: boolean;
  readonly isLocked: boolean;
  readonly isFocusActive: boolean;
}): boolean {
  if (!args.cameraOptIn || args.isLocked) return false;
  if (args.eventKind === "doorbell") return true;
  return !args.isFocusActive;
}

/** Whether a device can be pinned as a quick-toggle button inside the PiP window. */
export function isPinnableCameraSwitch(device: SmartDevice): boolean {
  const k = device.kind.kind;
  return k === "light" || k === "plug" || k === "cover" || k === "fan";
}

/** Deduplicates and clamps pinned switch IDs to at most `MAX_PINNED_CAMERA_SWITCHES` (2). */
export function sanitizePinnedSwitchIds(ids: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of ids) {
    const trimmed = typeof raw === "string" ? raw.trim() : "";
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
    if (out.length >= MAX_PINNED_CAMERA_SWITCHES) break;
  }
  return out;
}

/**
 * Returns true when a camera should default to a 3:4 portrait PiP layout:
 * doorbell / cateye hardware models (which ship upright 3:4 sensors) or a
 * camera explicitly rotated 90°/270°.
 */
export function isPortraitDoorbellCamera(
  device: Pick<SmartDevice, "model" | "name" | "kind">,
  rotationDeg: 0 | 90 | 180 | 270 = 0,
): boolean {
  if (device.kind.kind !== "camera") return false;
  if (rotationDeg === 90 || rotationDeg === 270) return true;
  if (PORTRAIT_DOORBELL_MODEL_RE.test(device.model)) return true;
  if (PORTRAIT_DOORBELL_NAME_RE.test(device.name)) return true;
  return false;
}

export type CameraPipMediaKind =
  | "sleeping"
  | "frames"
  | "image"
  | "loading"
  | "video"
  | "demo"
  | "error";

export interface CameraPipSwitcherItem {
  readonly id: string;
  readonly name: string;
  readonly roomName: string;
  readonly isActiveOnline: boolean;
}

export interface CameraPipPinnedSwitchItem {
  readonly id: string;
  readonly name: string;
  readonly isOn: boolean;
  readonly isOnline: boolean;
}
export interface CameraPipSnapshot {
  readonly cameraId: string;
  readonly name: string;
  readonly roomName: string;
  readonly isPortrait: boolean;
  readonly mediaKind: CameraPipMediaKind;
  readonly mjpegSrc: string | null;
  readonly streamURL: string | null;
  readonly isOn: boolean;
  readonly powerWritable: boolean;
  readonly isNight: boolean;
  readonly nightShot: string | null;
  readonly availableNightShots: readonly string[];
  readonly motionDetectionEntityId: string | null;
  readonly isMotionDetectionOn: boolean;
  readonly rotation: 0 | 90 | 180 | 270;
  readonly muted: boolean;
  readonly error: string | null;
  readonly showingURLInput: boolean;
  readonly customURL: string;
  readonly showManualIpFallback: boolean;
  readonly savedManualIp: string;
  readonly draftManualIp: string;
  readonly manualIpError: string | null;
  readonly showQualityBar: boolean;
  readonly quality: CameraStreamQuality;
  readonly lenses: readonly CameraLens[];
  readonly activeLensChannel: number;
  readonly playableCameras: readonly CameraPipSwitcherItem[];
  readonly autoCloseRemainingSeconds: number | null;
  readonly autoOpenOnEvent: boolean;
  readonly pinnedSwitches: readonly CameraPipPinnedSwitchItem[];
  readonly availablePinSwitches: readonly CameraPipPinnedSwitchItem[];
}

export type CameraPipAction =
  | { readonly type: "close" }
  | { readonly type: "interact" }
  | { readonly type: "reload" }
  | { readonly type: "rotate" }
  | { readonly type: "toggleMute" }
  | { readonly type: "switchCamera"; readonly deviceId: string }
  | { readonly type: "setLens"; readonly deviceId: string; readonly channel: number }
  | { readonly type: "setQuality"; readonly deviceId: string; readonly quality: CameraStreamQuality }
  | { readonly type: "togglePower"; readonly deviceId: string }
  | { readonly type: "toggleMotion"; readonly deviceId: string }
  | { readonly type: "setNightShot"; readonly deviceId: string; readonly mode: string }
  | { readonly type: "togglePinnedSwitch"; readonly deviceId: string }
  | { readonly type: "setAutoOpen"; readonly enabled: boolean }
  | { readonly type: "togglePinSelection"; readonly deviceId: string }
  | { readonly type: "toggleUrlInput" }
  | { readonly type: "saveCustomUrl"; readonly url: string }
  | { readonly type: "saveManualIp"; readonly ip: string }
  | { readonly type: "clearManualIp" }
  | { readonly type: "copyDiag" }
  | { readonly type: "frameCaptured"; readonly cameraId: string; readonly jpegBase64: string };
