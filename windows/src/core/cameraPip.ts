import type { CameraStreamQuality } from "./cameraQuality.js";
import type { CameraLens, SmartDevice } from "./models.js";

const PORTRAIT_DOORBELL_MODEL_RE = /(?:^|[._-])(doorbell|cateye|mjbell|g400)(?:$|[._-\d])/i;
const PORTRAIT_DOORBELL_NAME_RE = /(门铃|門鈴|猫眼|貓眼|\bdoorbell\b)/i;

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
}

export type CameraPipAction =
  | { readonly type: "close" }
  | { readonly type: "reload" }
  | { readonly type: "rotate" }
  | { readonly type: "toggleMute" }
  | { readonly type: "switchCamera"; readonly deviceId: string }
  | { readonly type: "setLens"; readonly deviceId: string; readonly channel: number }
  | { readonly type: "setQuality"; readonly deviceId: string; readonly quality: CameraStreamQuality }
  | { readonly type: "togglePower"; readonly deviceId: string }
  | { readonly type: "toggleMotion"; readonly deviceId: string }
  | { readonly type: "setNightShot"; readonly deviceId: string; readonly mode: string }
  | { readonly type: "toggleUrlInput" }
  | { readonly type: "saveCustomUrl"; readonly url: string }
  | { readonly type: "saveManualIp"; readonly ip: string }
  | { readonly type: "clearManualIp" }
  | { readonly type: "copyDiag" }
  | { readonly type: "frameCaptured"; readonly cameraId: string; readonly jpegBase64: string };
