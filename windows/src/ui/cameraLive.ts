import { t } from "../core/i18n.js";
import {
  DEFAULT_CAMERA_STREAM_QUALITY,
  normalizeCameraStreamQuality,
  type CameraStreamQuality,
} from "../core/cameraQuality.js";
import {
  CameraHubCatalog,
  parsePrivateLanIpv4,
  resolveLiveCameraTarget,
  type CachedCameraTopology,
} from "../core/miCloud/cameraHubs.js";
import {
  MiCloudClient,
  type HttpTransport,
  type MiSession,
  type MiotSpecResolver,
} from "../core/miCloudClient.js";
import type { CameraLens, SmartDevice } from "../core/models.js";
import { getCachedXiaomiTopology, miAccountId } from "../core/pollingPolicy.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
import type { PersistedSettings } from "./appTypes.js";
import { computeQuarterTurnScale, renderCameraLiveModalView } from "./cameraLiveModalView.js";
import {
  getHostDualSourceState,
  getHostMiAccountsState,
  isDualSourceEnabled,
  isHostHaEnabled,
  isHostMiSessionEnabled,
  resolveHostMiSelectionState,
} from "./cloudRefresh.js";
import { controlTargetRejectionMessage } from "../core/capabilityReferenceVerdict.js";
import { haConnectionScope, resolveDisabledHaDeviceByEntity } from "../core/miAccountControl.js";
import { waitForCameraFrameGap } from "./dom.js";
import { writeSettingsForStorage } from "./settings.js";
import { hasPendingUrlConfirmation, rejectIfControlBlockedWhileLocked } from "./speechGuard.js";
import { invokeTauriVoid } from "./transport.js";
import { tr3 } from "./undoTracker.js";

export type CameraRotationDeg = 0 | 90 | 180 | 270;

export interface Go2RtcSupervisorStatus {
  readonly state: "stopped" | "running" | "backingOff" | "circuitOpen" | string;
  readonly consecutiveFailures: number;
  readonly recentFailures: number;
  readonly nextRetryMs: number | null;
  readonly lastExitCode?: number | null;
  readonly lastError?: string | null;
}

export function isGo2RtcCircuitOpenError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err ?? "");
  return /熔断|circuit\s*open|circuitopen/i.test(message);
}

export function isGo2RtcBackingOffError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err ?? "");
  return /退避重启|backing\s*off|backingoff/i.test(message);
}

export function formatGo2RtcSupervisorDiagnostics(
  status: Go2RtcSupervisorStatus | null,
  redact: (raw: string) => string,
): string[] {
  if (!status || typeof status.state !== "string") {
    return ["go2rtcSupervisorState: unavailable"];
  }
  const lines = [
    `go2rtcSupervisorState: ${status.state}`,
    `go2rtcConsecutiveFailures: ${Number.isFinite(status.consecutiveFailures) ? status.consecutiveFailures : 0}`,
    `go2rtcRecentFailures: ${Number.isFinite(status.recentFailures) ? status.recentFailures : 0}`,
    `go2rtcNextRetryMs: ${typeof status.nextRetryMs === "number" && Number.isFinite(status.nextRetryMs) ? status.nextRetryMs : "none"}`,
  ];
  if (typeof status.lastExitCode === "number" && Number.isFinite(status.lastExitCode)) {
    lines.push(`go2rtcLastExitCode: ${status.lastExitCode}`);
  }
  if (typeof status.lastError === "string" && status.lastError.trim().length > 0) {
    lines.push(`go2rtcLastError: ${redact(status.lastError.trim())}`);
  }
  return lines;
}

/**
 * Builds a go2rtc HTTP stream URL (`/api/stream.mp4`, `/api/stream.m3u8`, `/api/stream.mjpeg`).
 * Muted previews add `&audio=0` so audio is not requested until the user explicitly opts in (#445, P1-2).
 */
export function buildGo2RtcStreamUrl(
  origin: string,
  streamName: string,
  options?: { readonly format?: "mp4" | "m3u8" | "mjpeg"; readonly audioEnabled?: boolean },
): string {
  const cleanOrigin = origin.trim().replace(/\/+$/, "");
  const format = options?.format ?? "m3u8";
  const audioEnabled = Boolean(options?.audioEnabled);
  const encodedSrc = encodeURIComponent(streamName);
  switch (format) {
    case "mp4":
      return audioEnabled
        ? `${cleanOrigin}/api/stream.mp4?src=${encodedSrc}&mp4=all`
        : `${cleanOrigin}/api/stream.mp4?src=${encodedSrc}&mp4&audio=0`;
    case "m3u8":
      return audioEnabled
        ? `${cleanOrigin}/api/stream.m3u8?src=${encodedSrc}`
        : `${cleanOrigin}/api/stream.m3u8?src=${encodedSrc}&video=all&audio=0`;
    case "mjpeg":
      return `${cleanOrigin}/api/stream.mjpeg?src=${encodedSrc}`;
  }
}

/**
 * Applies the muted-preview (`audio=0`) vs listen-only (`audio` requested) parameter to a
 * `xiaomi://` or go2rtc HTTP stream URL (`stream.mp4` / `stream.m3u8`).
 */
export function withGo2RtcAudioQuery(rawUrl: string, audioEnabled: boolean): string {
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return rawUrl;
  }
  const protocol = parsed.protocol.toLowerCase();
  if (protocol === "xiaomi:") {
    parsed.searchParams.set("audio", audioEnabled ? "1" : "0");
    return parsed.toString();
  }
  if (protocol !== "http:" && protocol !== "https:") return rawUrl;
  const path = parsed.pathname.toLowerCase();
  if (!path.endsWith("/api/stream.mp4") && !path.endsWith("/api/stream.m3u8")) {
    return rawUrl;
  }
  if (audioEnabled) {
    if (parsed.searchParams.get("audio") === "0") {
      parsed.searchParams.delete("audio");
    }
    if (path.endsWith("/api/stream.m3u8") && parsed.searchParams.get("video") === "all") {
      parsed.searchParams.delete("video");
    }
    if (path.endsWith("/api/stream.mp4") && parsed.searchParams.get("mp4") === "") {
      parsed.searchParams.set("mp4", "all");
    }
  } else {
    if (path.endsWith("/api/stream.m3u8") && !parsed.searchParams.has("video")) {
      parsed.searchParams.set("video", "all");
    }
    parsed.searchParams.set("audio", "0");
  }
  return parsed.toString();
}

export function normalizeCameraRotation(value: unknown): CameraRotationDeg {
  return value === 90 || value === 180 || value === 270 ? value : 0;
}

export function nextCameraRotation(deg: CameraRotationDeg): CameraRotationDeg {
  switch (deg) {
    case 0:
      return 90;
    case 90:
      return 180;
    case 180:
      return 270;
    case 270:
      return 0;
  }
}

interface CameraBridgeBinding {
  readonly did: string;
  readonly channel: number;
  readonly subdid: string | null;
  /** Set when the stream is a locally registered HLS bridge rather than a Xiaomi P2P session. */
  readonly localHls?: boolean;
}

/** One cloud start. Identity is the lease, so a later start for the same device is a different entry. */
interface RetainedCloudStream {
  readonly session: MiSession;
}

export interface CameraLiveHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  readonly devices: readonly SmartDevice[];
  readonly transport: HttpTransport;
  readonly specResolver: MiotSpecResolver;
  readonly endpointSubmission: Promise<unknown>;
  readonly prompt?: unknown;
  readonly ctxMenu?: unknown;
  readonly isRecordingHotkey?: boolean;
  readonly activeSheet?: string;
  replyBanner: { text: string; source: string; isError?: boolean } | null;
  render(): void;
  escapeHtml(value: string): string;
  saveSettings(): void;
  shouldKeepPopoverPinned(): boolean;
  onCameraFrameCaptured?(cameraId: string | null, jpegBase64: string): void;
  readonly pipeline?: {
    readonly cameraStandby: {
      resumeFromStandby(root: HTMLElement): void;
      enterWarmStandby(root: HTMLElement): void;
      cancel(): void;
    };
  };
  readonly miAccountsOverride?: readonly import("../core/miAccountsStore.js").MiAccount[] | null;
  readonly dualSourceEnabledOverride?: boolean | null;
  readonly multiAccountState?: import("./cloudRefresh.js").HostMultiAccountState | null;
  readonly dualSourceCoordinator?: import("../core/dualSourceProvider.js").DualSourceCoordinator | null;
}

export class CameraLiveController {
  private categoryEnabled = true;
  private nativeOperation: Promise<unknown> | null = null;
  private negotiationAbort: AbortController | null = null;
  private readonly negotiations = new Set<Promise<void>>();
  private categoryRelease: Promise<void> | null = null;
  private lastDisabledToken = -1;

  public get cameraCategoryEnabled(): boolean {
    return this.categoryEnabled;
  }

  public setCameraCategoryEnabled(enabled: boolean): void {
    if (this.categoryEnabled === enabled) return;
    this.categoryEnabled = enabled;
    if (enabled) {
      void this.runNativeCameraOperation("resume_camera_runtime");
      return;
    }

    const cancellation = window.__TAURI_INTERNALS__?.invoke("cancel_camera_preparation")
      .catch((error: unknown) => console.error("[tauri] cancel_camera_preparation failed", error));
    this.ownedStreamOrigin = null;
    const closing = this.activeLiveCameraId !== null;
    this.closeCameraLiveView(false);
    this.lastDisabledToken = this.liveCameraToken;
    this.cameraBridgeBindings.clear();
    const release = Promise.allSettled([...this.negotiations, ...this.pendingCameraReleases.values()])
      .then(() => Promise.allSettled([...this.pendingCameraReleases.values()]))
      .then(() => {});
    this.categoryRelease = release;
    void release.then(() => {
      if (this.categoryRelease === release) this.categoryRelease = null;
    });
    void this.runNativeCameraOperation("stop_camera_runtime", undefined, undefined, cancellation);
    if (closing) this.host.render();
  }

  private runNativeCameraOperation<T>(
    command: string,
    payload?: Record<string, unknown>,
    token?: number,
    after?: Promise<unknown>,
  ): Promise<T | undefined> {
    const run = async () => {
      if (after) await after;
      if (token !== undefined && (!this.categoryEnabled || token !== this.liveCameraToken)) return;
      return window.__TAURI_INTERNALS__?.invoke<T>(command, payload);
    };
    const result = this.nativeOperation ? this.nativeOperation.then(run, run) : run();
    const settled = result.catch((error: unknown) => {
      console.error(`[tauri] ${command} failed`, error);
    });
    this.nativeOperation = settled;
    void settled.then(() => {
      if (this.nativeOperation === settled) this.nativeOperation = null;
    });
    return token === undefined ? settled.then(() => undefined) : result;
  }

  public static readonly CAMERA_CHANNELS_STORAGE_KEY = "menubarmijia.cameraChannels";
  public static readonly CAMERA_ROTATIONS_STORAGE_KEY = "menubarmijia.cameraRotations";
  public static readonly CAMERA_LOCAL_IPS_STORAGE_KEY = "menubarmijia.cameraLocalIPs";

  constructor(public readonly host: CameraLiveHost) {
    this.cameraStreamURLs = { ...(host.settings.cameraStreamURLs ?? {}) };
    this.cameraStreamQualities = { ...(host.settings.cameraStreamQualities ?? {}) };
    this.cameraChannels = loadPersistedCameraChannels();
    this.cameraRotations = loadPersistedCameraRotations();
    this.cameraLocalIPs = loadPersistedCameraLocalIPs();
  }

  public activeLiveCameraId: string | null = null;
  private activeLiveCameraSnapshot: SmartDevice | null = null;
  /**
   * The camera frees a used P2P session on its own schedule (measured: a fresh
   * session streams fine, but one that carried video needs well over a minute
   * before it can be re-negotiated). Closing the live modal therefore only
   * HIDES it and keeps the whole chain hot; full teardown happens when the
   * panel closes, the device errors, or after this long with nobody watching.
   */
  public liveCameraHidden = false;
  public liveCameraKeepAliveTimer: number | null = null;
  public static readonly CAMERA_KEEP_ALIVE_MS = 120_000;
  /** Tests pin this short to watch the teardown without waiting two minutes. */
  cameraKeepAliveMs = CameraLiveController.CAMERA_KEEP_ALIVE_MS;
  public static readonly CAMERA_FRAME_GIVE_UP_MS = 20_000;
  public static readonly CAMERA_ACTIVE_FRAME_GAP_MS = 45;
  public static readonly CAMERA_IDLE_FRAME_GAP_MS = 250;
  public static readonly CAMERA_HIDDEN_FRAME_GAP_MS = 400;
  public static readonly CAMERA_MAX_IDLE_FRAME_GAP_MS = 500;
  public static readonly CAMERA_SAME_SESSION_COOLDOWN_MS = 2_500;
  cameraFrameGiveUpMs = CameraLiveController.CAMERA_FRAME_GIVE_UP_MS;
  cameraFrameRetryMs = 800;
  cameraActiveFrameGapMs = CameraLiveController.CAMERA_ACTIVE_FRAME_GAP_MS;
  cameraIdleFrameGapMs = CameraLiveController.CAMERA_IDLE_FRAME_GAP_MS;
  cameraHiddenFrameGapMs = CameraLiveController.CAMERA_HIDDEN_FRAME_GAP_MS;
  cameraSameSessionCooldownMs = CameraLiveController.CAMERA_SAME_SESSION_COOLDOWN_MS;
  public liveCameraStreamURL: string | null = null;
  public liveCameraLoading = false;
  public liveCameraError: string | null = null;
  public liveCameraShowingURLInput = false;
  public liveCameraNeedsManualIp = false;
  public liveCameraLocalIpError: string | null = null;
  public liveCameraDraftIp: string | null = null;
  public cameraStreamURLs: Record<string, string> = {};
  /** Per-camera Xiaomi stream quality; `hd` matches the macOS default (#193). */
  public cameraStreamQualities: Record<string, CameraStreamQuality> = {};
  public cameraChannels: Record<string, number> = {};
  public cameraRotations: Record<string, CameraRotationDeg> = {};
  public cameraLocalIPs: Record<string, string> = {};
  /** The live picture arrives as MJPEG frames in a persistent `<img>`, which never restarts on re-render. */
  public liveCameraMode: "mjpeg" | null = null;
  /** Only a raw `<video>` element can carry audio; it starts muted like the macOS HLS player (#29). */
  public liveCameraMuted = true;
  /** Detected from active `<video>` metadata (`null` if unknown / unsupported by WebView). */
  public liveCameraHasAudioTrack: boolean | null = null;
  public liveCameraQualityApplies = true;
  public liveCameraImgEl: HTMLImageElement | null = null;
  public liveCameraRawMediaEl: HTMLImageElement | HTMLVideoElement | null = null;
  public liveCameraAbort: AbortController | null = null;
  public ownedStreamOrigin: string | null = null;
  public liveCameraToken = 0;
  public readonly pendingCameraReleases = new Map<string, Promise<void>>();
  /** Session that started the in-flight or open cloud stream. Released with that stream, not kept across logout. */
  private readonly cloudStreamSessions = new Map<string, RetainedCloudStream>();
  private readonly cameraBridgeBindings = new Map<string, CameraBridgeBinding>();
  private readonly recentP2PSessionActivityMs = new Map<string, number>();
  private reconnectingP2PSessionId: string | null = null;
  private escapeKeyDisposer: (() => void) | null = null;

  private resolveCameraSource(dev: SmartDevice): {
    readonly backend: "xiaomiCloud" | "homeAssistant" | "demo";
    readonly sourceDev: SmartDevice;
    readonly miSession: MiSession | null;
    readonly accountId: string | null;
  } {
    // Both lookups stay behind the dual-source gate: a refresh that lands after sign-out can still
    // publish its routes into the coordinator, and a stale Xiaomi route must never decide how an
    // HA-native card streams once dual-source mode has ended (#254).
    const route = isDualSourceEnabled(this.host)
      ? (getHostDualSourceState(this.host)?.routes[dev.id] ??
        this.host.dualSourceCoordinator?.getLastMerged()?.routes[dev.id])
      : undefined;
    const sourceDev = route?.sourceDevice ?? dev;
    const backend: "xiaomiCloud" | "homeAssistant" | "demo" =
      route?.backend ??
      (dev.sourceBackend === "xiaomiCloud" || dev.sourceBackend === "homeAssistant"
        ? dev.sourceBackend
        : this.host.settings.connectionMode);
    if (backend !== "xiaomiCloud") {
      return { backend, sourceDev, miSession: null, accountId: null };
    }
    const accounts = this.host.miAccountsOverride ?? getHostMiAccountsState(this.host)?.accounts ?? [];
    const scopedSourceAccountId = sourceDev.id.includes("/") ? sourceDev.id.slice(0, sourceDev.id.indexOf("/")) : null;
    const scopedDevAccountId = dev.id.includes("/") ? dev.id.slice(0, dev.id.indexOf("/")) : null;
    const targetAccountId =
      sourceDev.accountId ??
      dev.accountId ??
      scopedSourceAccountId ??
      scopedDevAccountId ??
      (this.host.settings.miSession ? miAccountId(this.host.settings.miSession) : null) ??
      accounts[0]?.id ??
      null;
    if (targetAccountId) {
      const matched = accounts.find(
        (acc) => acc.id === targetAccountId || acc.session.userId === targetAccountId,
      );
      if (matched) return { backend, sourceDev, miSession: matched.session, accountId: matched.id };
    }
    return {
      backend,
      sourceDev,
      miSession: this.host.settings.miSession ?? accounts[0]?.session ?? null,
      accountId: targetAccountId,
    };
  }

  private resolveCachedCameraTopology(dev: SmartDevice, sourceDev: SmartDevice): CachedCameraTopology | null {
    const accountsState = getHostMiAccountsState(this.host);
    const merged = accountsState?.merged;
    const targetAccountId = sourceDev.accountId ?? dev.accountId ?? null;
    if (merged && targetAccountId) {
      const accounts = this.host.miAccountsOverride ?? accountsState?.accounts ?? [];
      const matched = accounts.find(
        (acc) => acc.id === targetAccountId || acc.session.userId === targetAccountId,
      );
      const accountKey = matched?.id ?? targetAccountId;
      const allDevices = merged.allDevicesByAccount[accountKey];
      const allRooms = merged.allRoomsByAccount[accountKey];
      if (allDevices && allDevices.length > 0) {
        return { allDevices, allRooms: allRooms ?? [] };
      }
    }
    const cached = getCachedXiaomiTopology(this.host);
    if (cached && cached.allDevices.length > 0) {
      return { allDevices: cached.allDevices, allRooms: cached.allRooms };
    }
    return null;
  }

  private p2pSessionKeyForDevice(dev: SmartDevice): string {
    const bound = this.cameraBridgeBindings.get(dev.id);
    if (bound?.did) return bound.did;
    const { sourceDev } = this.resolveCameraSource(dev);
    if (sourceDev.kind.kind === "camera" && sourceDev.kind.gatewayDid) return sourceDev.kind.gatewayDid;
    return sourceDev.id;
  }

  /** A locally registered HLS bridge is not a Xiaomi stream, even though teardown stops it the same way. */
  private hasXiaomiCameraBridge(deviceId: string): boolean {
    const binding = this.cameraBridgeBindings.get(deviceId);
    return binding !== undefined && binding.localHls !== true;
  }

  private hasHigherPriorityOverlayOpen(): boolean {
    return (
      (this.host.prompt !== undefined && this.host.prompt !== null) ||
      (this.host.ctxMenu !== undefined && this.host.ctxMenu !== null) ||
      Boolean(this.host.isRecordingHotkey) ||
      (typeof this.host.activeSheet === "string" && this.host.activeSheet !== "none") ||
      hasPendingUrlConfirmation(this.host as unknown as MenuMijiaWindowsApp)
    );
  }

  private syncModalEscapeListener(): void {
    const shouldListen = this.activeLiveCameraId !== null && !this.liveCameraHidden;
    if (!shouldListen) {
      this.escapeKeyDisposer?.();
      this.escapeKeyDisposer = null;
      return;
    }
    if (this.escapeKeyDisposer) return;
    const ownerWin = this.host.root.ownerDocument?.defaultView ?? window;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.key !== "Escape") return;
      if (this.activeLiveCameraId === null || this.liveCameraHidden || !this.host.root.isConnected) {
        this.syncModalEscapeListener();
        return;
      }
      if (this.hasHigherPriorityOverlayOpen()) return;
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      this.hideCameraLiveView();
    };
    ownerWin.addEventListener("keydown", onKeyDown, true);
    this.escapeKeyDisposer = () => {
      ownerWin.removeEventListener("keydown", onKeyDown, true);
    };
  }

  public openCameraLiveView(
    deviceId: string,
    options?: { readonly alreadyCountedLockBlock?: boolean },
  ): void {
    if (!this.categoryEnabled) {
      this.host.replyBanner = {
        text: controlTargetRejectionMessage(
          { code: "categoryDisabled", disabledCategory: "camera" },
          this.host.settings.interfaceLanguage,
        ),
        source: t("控制失败"),
        isError: true,
      };
      this.host.render();
      return;
    }
    const dev = this.host.devices.find((d) => d.id === deviceId);
    if (!dev) {
      const state = resolveHostMiSelectionState(this.host);
      const disabledHaSnap = resolveDisabledHaDeviceByEntity(deviceId, state.knownDisabledHaDevices);
      if (disabledHaSnap) {
        const msg = controlTargetRejectionMessage(
          { code: "connectionScopeDisabled", connection: "home-assistant", scope: disabledHaSnap.scope },
          this.host.settings.interfaceLanguage,
        );
        this.host.replyBanner = { text: msg, source: t("控制失败"), isError: true };
        this.host.render();
      }
      return;
    }
    if (dev.kind.kind !== "camera") return;
    if (this.resolveCameraSource(dev).backend === "homeAssistant" && !isHostHaEnabled(this.host)) {
      const scope = haConnectionScope(this.host.settings.haBaseURL, this.host.settings.haToken) ?? "ha:disabled";
      const msg = controlTargetRejectionMessage(
        { code: "connectionScopeDisabled", connection: "home-assistant", scope },
        this.host.settings.interfaceLanguage,
      );
      this.host.replyBanner = { text: msg, source: t("控制失败"), isError: true };
      this.host.render();
      return;
    }
    // Opening is idempotent even before the first frame or while cloud negotiation is
    // pending. Only the explicit reconnect action may replace this camera's session.
    if (this.activeLiveCameraId === deviceId) {
      this.host.pipeline?.cameraStandby.resumeFromStandby(this.host.root);
      this.liveCameraHidden = false;
      this.clearCameraKeepAlive();
      this.syncModalEscapeListener();
      invokeTauriVoid("set_pin_popover", { pin: true });
      if (options?.alreadyCountedLockBlock) {
        this.liveCameraLoading = false;
        this.liveCameraError = t("屏幕已锁定，已拦截设备控制指令");
      } else if (
        dev.kind.isOn &&
        !this.liveCameraImgEl &&
        !this.liveCameraRawMediaEl &&
        !this.liveCameraLoading &&
        !this.liveCameraError
      ) {
        // A power-on while hidden skips the reconnect, so this is the first chance to start it.
        this.reconnectCameraLiveView();
      }
      this.host.render();
      return;
    }
    if (this.activeLiveCameraId !== null && this.activeLiveCameraId !== deviceId) {
      this.teardownActiveCameraForSwitch();
    }
    this.host.pipeline?.cameraStandby.cancel();
    this.reconnectingP2PSessionId = null;
    this.activeLiveCameraId = dev.id;
    this.activeLiveCameraSnapshot = dev;
    this.liveCameraMuted = true;
    this.liveCameraHasAudioTrack = null;
    this.liveCameraQualityApplies = true;
    this.liveCameraHidden = false;
    this.clearCameraKeepAlive();
    this.syncModalEscapeListener();
    this.liveCameraError = null;
    this.liveCameraShowingURLInput = false;
    this.liveCameraNeedsManualIp = false;
    this.liveCameraLocalIpError = null;
    this.liveCameraDraftIp = null;
    this.liveCameraStreamURL = this.cameraStreamURLs[dev.id]
      ? this.normalizeWindowsCameraStreamUrl(this.cameraStreamURLs[dev.id]!)
      : this.resolveHaCameraStreamUrl(dev);
    this.liveCameraLoading = false;
    invokeTauriVoid("set_pin_popover", { pin: true });
    if (options?.alreadyCountedLockBlock) {
      this.liveCameraError = t("屏幕已锁定，已拦截设备控制指令");
    } else if (dev.kind.isOn && this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (dev.kind.isOn && !this.liveCameraStreamURL && this.resolveCameraSource(dev).backend === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    } else if (!dev.kind.isOn && this.host.settings.blockControlWhileLocked && window.__TAURI_INTERNALS__?.invoke) {
      void (async () => {
        if (this.activeLiveCameraId !== dev.id) return;
        await rejectIfControlBlockedWhileLocked(this.host, {
          beforeRender: () => {
            if (this.activeLiveCameraId === dev.id) {
              this.liveCameraLoading = false;
              this.liveCameraError = t("屏幕已锁定，已拦截设备控制指令");
            }
          },
        });
      })();
    }
    this.host.render();
  }

  private teardownActiveCameraForSwitch(): void {
    const closingId = this.activeLiveCameraId;
    const closingDev = closingId
      ? this.host.devices.find((d) => d.id === closingId) ??
        (this.activeLiveCameraSnapshot?.id === closingId ? this.activeLiveCameraSnapshot : undefined)
      : undefined;
    const closingIsXiaomi = closingDev ? this.resolveCameraSource(closingDev).backend === "xiaomiCloud" : false;
    if (closingDev && closingIsXiaomi) {
      this.recentP2PSessionActivityMs.set(this.p2pSessionKeyForDevice(closingDev), Date.now());
    }
    this.clearCameraKeepAlive();
    this.liveCameraHidden = false;
    this.stopLiveTransport();
    this.activeLiveCameraId = null;
    this.activeLiveCameraSnapshot = null;
    this.syncModalEscapeListener();
    if (closingId && closingIsXiaomi && closingDev) {
      void this.releaseCameraP2PSession(closingDev, this.liveCameraToken);
    }
  }

  public resolveHaCameraStreamUrl(dev: SmartDevice): string | null {
    if (!isHostHaEnabled(this.host)) return null;
    const { backend, sourceDev } = this.resolveCameraSource(dev);
    if (backend !== "homeAssistant" || sourceDev.kind.kind !== "camera") return null;
    const rawPath = sourceDev.kind.snapshotPath?.trim() ?? "";
    if (!rawPath) return null;
    const streamPath = rawPath.replace(/^\/api\/camera_proxy\//i, "/api/camera_proxy_stream/");
    if (/^https?:\/\//i.test(streamPath)) return streamPath;
    const rawBase = this.host.settings.haBaseURL.trim().replace(/\/+$/, "");
    const base = /^\/api(?:\/|$)/i.test(streamPath)
      ? rawBase.replace(/\/api$/i, "")
      : rawBase;
    if (!base) return null;
    return `${base}${streamPath.startsWith("/") ? "" : "/"}${streamPath}`;
  }

  /** Hides the modal but keeps the stream hot, so reopening is instant (#97). */
  public hideCameraLiveView(): void {
    if (this.activeLiveCameraId === null) return;
    this.liveCameraHidden = true;
    this.syncModalEscapeListener();
    invokeTauriVoid("set_pin_popover", { pin: this.host.shouldKeepPopoverPinned() });
    this.clearCameraKeepAlive();
    const timer = window.setTimeout(() => {
      if (this.liveCameraKeepAliveTimer !== timer) return;
      this.liveCameraKeepAliveTimer = null;
      // Nobody came back within the keep-alive window: release the camera's
      // single P2P session so the phone app (or the next open) can use it.
      if (this.liveCameraHidden) this.closeCameraLiveView();
    }, this.cameraKeepAliveMs);
    this.liveCameraKeepAliveTimer = timer;
    this.host.render();
    this.host.pipeline?.cameraStandby.enterWarmStandby(this.host.root);
  }

  public clearCameraKeepAlive(): void {
    if (this.liveCameraKeepAliveTimer !== null) {
      window.clearTimeout(this.liveCameraKeepAliveTimer);
      window.clearInterval(this.liveCameraKeepAliveTimer);
      this.liveCameraKeepAliveTimer = null;
    }
  }

  public closeCameraLiveView(render = true): void {
    this.host.pipeline?.cameraStandby.cancel();
    const closingId = this.activeLiveCameraId;
    const closingDev = closingId
      ? this.host.devices.find((d) => d.id === closingId) ??
        (this.activeLiveCameraSnapshot?.id === closingId ? this.activeLiveCameraSnapshot : undefined)
      : undefined;
    const closingIsXiaomi = closingDev ? this.resolveCameraSource(closingDev).backend === "xiaomiCloud" : false;
    if (closingDev && closingIsXiaomi) {
      this.recentP2PSessionActivityMs.set(this.p2pSessionKeyForDevice(closingDev), Date.now());
    }
    this.reconnectingP2PSessionId = null;
    this.clearCameraKeepAlive();
    this.liveCameraHidden = false;
    const wasNegotiating = this.negotiationAbort !== null;
    this.stopLiveTransport();
    this.activeLiveCameraId = null;
    this.activeLiveCameraSnapshot = null;
    this.syncModalEscapeListener();
    this.liveCameraMuted = true;
    this.liveCameraHasAudioTrack = null;
    this.liveCameraQualityApplies = true;
    this.liveCameraStreamURL = null;
    this.liveCameraLoading = false;
    this.liveCameraError = null;
    this.liveCameraShowingURLInput = false;
    this.liveCameraNeedsManualIp = false;
    this.liveCameraLocalIpError = null;
    this.liveCameraDraftIp = null;
    if (closingId && closingIsXiaomi && closingDev) {
      const retained = this.cloudStreamSessions.get(closingId);
      if (this.categoryEnabled) {
        void this.releaseCameraP2PSession(closingDev, this.liveCameraToken);
      } else if (!wasNegotiating && retained) {
        void this.releaseCameraP2PSession(closingDev, this.liveCameraToken, false, retained.session, retained, true);
      }
    }
    invokeTauriVoid("set_pin_popover", { pin: this.host.shouldKeepPopoverPinned() });
    if (render) this.host.render();
  }

  public activeLiveCameraUsesXiaomiCloud(accountId?: string): boolean {
    const activeId = this.activeLiveCameraId;
    if (!activeId) return false;
    if (accountId && activeId.startsWith(`${accountId}/`)) return true;
    const dev =
      this.host.devices.find((d) => d.id === activeId) ??
      (this.activeLiveCameraSnapshot?.id === activeId ? this.activeLiveCameraSnapshot : undefined);
    if (!dev) {
      return this.host.settings.connectionMode === "xiaomiCloud" || this.cloudStreamSessions.has(activeId) || this.hasXiaomiCameraBridge(activeId);
    }
    const resolved = this.resolveCameraSource(dev);
    if (resolved.backend !== "xiaomiCloud") {
      return this.cloudStreamSessions.has(activeId) || this.hasXiaomiCameraBridge(activeId);
    }
    if (!accountId) return true;
    const owner = dev.accountId ?? resolved.sourceDev.accountId ?? resolved.accountId ?? null;
    return owner === accountId || resolved.sourceDev.id.startsWith(`${accountId}/`);
  }

  /**
   * Per-camera live state is keyed by device id, so a card that changes id would otherwise lose its
   * saved turn, lens, manual IP, custom stream URL and quality (#254). Entries are copied, not moved:
   * a later dual-source re-enable still finds them under the paired card's canonical id.
   */
  private carryOverCameraLiveState(fromId: string, toId: string): void {
    const copy = <T>(record: Record<string, T>): Record<string, T> | null => {
      const value = record[fromId];
      if (value === undefined || record[toId] !== undefined) return null;
      return { ...record, [toId]: value };
    };
    const channels = copy(this.cameraChannels);
    if (channels) {
      this.cameraChannels = channels;
      savePersistedRecord(CameraLiveController.CAMERA_CHANNELS_STORAGE_KEY, channels);
    }
    const rotations = copy(this.cameraRotations);
    if (rotations) {
      this.cameraRotations = rotations;
      savePersistedRecord(CameraLiveController.CAMERA_ROTATIONS_STORAGE_KEY, rotations);
    }
    const localIps = copy(this.cameraLocalIPs);
    if (localIps) {
      this.cameraLocalIPs = localIps;
      savePersistedRecord(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY, localIps);
    }
    const streamUrls = copy(this.cameraStreamURLs);
    if (streamUrls) this.cameraStreamURLs = streamUrls;
    const qualities = copy(this.cameraStreamQualities);
    if (qualities) this.cameraStreamQualities = qualities;
    if (streamUrls || qualities) {
      this.host.settings.cameraStreamURLs = { ...this.cameraStreamURLs };
      this.host.settings.cameraStreamQualities = { ...this.cameraStreamQualities };
      writeSettingsForStorage(this.host.settings);
    }
  }

  /**
   * Follows an open live view to the card that replaced it: ending dual-source mode restores raw
   * Home Assistant ids, so a stream opened under a paired card's canonical id would otherwise keep
   * an id the device list no longer has (#254). The transport keeps running: it already points at
   * this camera's frame source.
   */
  public retargetActiveLiveCamera(deviceId: string): boolean {
    const previousId = this.activeLiveCameraId;
    if (previousId === null) return false;
    const dev = this.host.devices.find((d) => d.id === deviceId);
    if (!dev || dev.kind.kind !== "camera") return false;
    if (previousId === dev.id) return true;
    this.carryOverCameraLiveState(previousId, dev.id);
    const pendingStart =
      this.liveCameraLoading &&
      !this.liveCameraAbort &&
      !this.liveCameraImgEl &&
      !this.liveCameraRawMediaEl;
    const preservedStreamUrl =
      this.cameraStreamURLs[dev.id] ?? (pendingStart ? this.liveCameraStreamURL : null);
    // Teardown reads the bridge binding by the active id, so the binding has to move with the view.
    const bridge = this.cameraBridgeBindings.get(previousId);
    if (bridge) {
      this.cameraBridgeBindings.delete(previousId);
      this.cameraBridgeBindings.set(dev.id, bridge);
    }
    this.activeLiveCameraId = dev.id;
    this.activeLiveCameraSnapshot = dev;
    this.syncModalEscapeListener();
    // Pre-transport negotiation (`liveCameraAbort === null`) compares `activeLiveCameraId` and would
    // bail out after the rename; once `startMjpegTransport` is pumping (`liveCameraAbort !== null`),
    // the frame loop checks only `liveCameraToken` and must keep running (#254).
    if (pendingStart) {
      this.reconnectCameraLiveView(preservedStreamUrl);
      return true;
    }
    this.host.render();
    return true;
  }

  public closeXiaomiCameraLiveView(accountId?: string): void {
    if (this.activeLiveCameraId !== null) {
      if (this.activeLiveCameraUsesXiaomiCloud(accountId)) {
        this.closeCameraLiveView();
      }
      return;
    }
    if (!accountId && this.liveCameraKeepAliveTimer !== null) {
      this.closeCameraLiveView();
    }
  }

  public activeLiveCameraUsesHomeAssistant(): boolean {
    const activeId = this.activeLiveCameraId;
    if (!activeId) return false;
    const dev =
      this.host.devices.find((d) => d.id === activeId) ??
      (this.activeLiveCameraSnapshot?.id === activeId ? this.activeLiveCameraSnapshot : undefined);
    if (!dev) {
      return (
        activeId.startsWith("ha:") ||
        activeId.startsWith("camera.") ||
        (!isDualSourceEnabled(this.host) && this.host.settings.connectionMode === "homeAssistant")
      );
    }
    if (this.activeLiveCameraUsesXiaomiCloud()) return false;
    return this.resolveCameraSource(dev).backend === "homeAssistant";
  }

  public closeHomeAssistantCameraLiveView(): boolean {
    if (this.activeLiveCameraId !== null && this.activeLiveCameraUsesHomeAssistant()) {
      this.closeCameraLiveView();
      return true;
    }
    return false;
  }

  /**
   * Tells the camera to drop its single P2P session. Serialized with the next
   * negotiation for the same camera so a delayed stop-stream never kills a
   * freshly reopened stream (#97).
   */
  public releaseCameraP2PSession(
    dev: SmartDevice,
    releaseToken = this.liveCameraToken,
    allowActiveCamera = false,
    sessionOverride?: MiSession | null,
    retainedLease?: RetainedCloudStream,
    categoryTeardown = false,
  ): Promise<void> {
    const { backend, sourceDev, miSession } = this.resolveCameraSource(dev);
    const dropLease = retainedLease ?? this.cloudStreamSessions.get(dev.id) ?? null;
    // The signed-in store session owns a later release. The retained session is only
    // the fallback after logout clears the store; a caller can still pin the session
    // that actually started an in-flight stream.
    const session = sessionOverride ?? miSession ?? dropLease?.session ?? null;
    if (backend !== "xiaomiCloud" || !session || !isHostMiSessionEnabled(this.host, session)) {
      this.dropRetainedCloudStream(dev.id, dropLease);
      return Promise.resolve();
    }
    const run = (async () => {
      try {
        const spec = await this.host.specResolver.resolve({
          did: sourceDev.id,
          name: sourceDev.name,
          model: sourceDev.model,
          isOnline: sourceDev.isOnline,
          specType: null,
        });
        if (!categoryTeardown && (this.liveCameraToken !== releaseToken || (!allowActiveCamera && this.activeLiveCameraId === dev.id))) return;
        const p2pSvc = spec.services.find((s) => s.actions.some((a) => a.type.includes("stop-stream")));
        const stopAct = p2pSvc?.actions.find((a) => a.type.includes("stop-stream"));
        if (!p2pSvc || !stopAct) return;
        const client = new MiCloudClient(session, this.host.transport);
        await client
          .callAction({ did: sourceDev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .catch(() => {});
      } catch {
        // Best effort only; the bridge teardown below already freed local resources.
      }
    })();
    const tracked = run.finally(() => {
      if (this.pendingCameraReleases.get(dev.id) === tracked) {
        this.pendingCameraReleases.delete(dev.id);
      }
      this.dropRetainedCloudStream(dev.id, dropLease);
    });
    this.pendingCameraReleases.set(dev.id, tracked);
    return tracked;
  }

  /** Session retained for a cloud stream that has not been released yet. */
  public retainedCloudStreamSession(deviceId: string): MiSession | null {
    return this.cloudStreamSessions.get(deviceId)?.session ?? null;
  }

  /** Drops every retained cloud session. Call after logout has already dispatched releases. */
  public discardRetainedCloudSessions(): void {
    this.cloudStreamSessions.clear();
  }

  private dropRetainedCloudStream(deviceId: string, retained: RetainedCloudStream | null): void {
    if (retained !== null && this.cloudStreamSessions.get(deviceId) === retained) {
      this.cloudStreamSessions.delete(deviceId);
    }
  }

  private buildStopBridgePayload(cameraId: string): Record<string, unknown> {
    const binding = this.cameraBridgeBindings.get(cameraId);
    const did = binding?.did ?? cameraId;
    const channel = binding?.channel ?? 0;
    const subdid = binding?.subdid ?? null;
    return {
      did,
      ...(channel > 0 ? { channel } : {}),
      ...(subdid ? { subdid } : {}),
    };
  }

  /** Drops the MJPEG image, any pending negotiation, and the backend stream bridge/reader. */
  public stopLiveTransport(): void {
    this.liveCameraToken += 1;
    this.negotiationAbort?.abort();
    this.negotiationAbort = null;
    this.liveCameraAbort?.abort();
    this.liveCameraAbort = null;
    this.liveCameraImgEl?.remove();
    this.liveCameraImgEl = null;
    if (this.liveCameraRawMediaEl?.tagName === "VIDEO") {
      const video = this.liveCameraRawMediaEl as HTMLVideoElement;
      video.pause();
      video.removeAttribute("src");
      video.load();
    } else {
      this.liveCameraRawMediaEl?.removeAttribute("src");
    }
    this.liveCameraRawMediaEl?.remove();
    this.liveCameraRawMediaEl = null;
    this.liveCameraHasAudioTrack = null;
    this.liveCameraMode = null;
    if (this.activeLiveCameraId) {
      const stopPayload = this.buildStopBridgePayload(this.activeLiveCameraId);
      this.cameraBridgeBindings.delete(this.activeLiveCameraId);
      if (this.categoryEnabled) void this.runNativeCameraOperation("stop_xiaomi_camera_bridge", stopPayload);
    }
  }

  public cameraRotation(deviceId: string | null = this.activeLiveCameraId): CameraRotationDeg {
    if (!deviceId) return 0;
    return normalizeCameraRotation(this.cameraRotations[deviceId]);
  }

  public rotateActiveCamera(): void {
    const id = this.activeLiveCameraId;
    if (!id) return;
    const next = nextCameraRotation(this.cameraRotation(id));
    this.cameraRotations = { ...this.cameraRotations, [id]: next };
    savePersistedRecord(CameraLiveController.CAMERA_ROTATIONS_STORAGE_KEY, this.cameraRotations);
    this.applyRotationToLiveMedia();
    this.syncCameraRotateControl();
  }

  public applyRotationToLiveMedia(): void {
    const el =
      this.liveCameraImgEl ??
      this.liveCameraRawMediaEl ??
      this.host.root.querySelector<HTMLImageElement | HTMLVideoElement>("#cc-camera-live-img, #cc-camera-video");
    if (!el) return;
    const deg = this.cameraRotation(this.activeLiveCameraId);
    el.dataset.rotation = String(deg);
    if (deg === 0) {
      el.style.transform = "";
      return;
    }
    if (deg === 180) {
      el.style.transform = "rotate(180deg)";
      return;
    }
    const stage = el.parentElement ?? this.host.root.querySelector<HTMLElement>(".cc-camera-stage");
    const scale = computeQuarterTurnScale(el, stage);
    el.style.transform = `rotate(${deg}deg) scale(${scale})`;
  }

  /** Puts the live element back after `render()` rebuilds the panel markup. */
  public attachLiveMedia(): void {
    const stage = this.host.root.querySelector<HTMLElement>(".cc-camera-stage");
    if (!stage) return;
    const el = this.liveCameraImgEl;
    if (el) {
      if (el.parentElement !== stage) stage.replaceChildren(el);
      this.applyRotationToLiveMedia();
      return;
    }
    const rawMedia = stage.querySelector<HTMLImageElement | HTMLVideoElement>("#cc-camera-live-img, #cc-camera-video");
    if (!rawMedia) return;
    if (this.liveCameraRawMediaEl) {
      if (this.liveCameraRawMediaEl !== rawMedia) {
        rawMedia.replaceWith(this.liveCameraRawMediaEl);
      }
      this.applyRotationToLiveMedia();
      return;
    }
    this.liveCameraRawMediaEl = rawMedia;
    if (rawMedia.tagName === "VIDEO") {
      const updateVideoOnly = (hasAudio: boolean) => {
        if (this.liveCameraHasAudioTrack === hasAudio) return;
        this.liveCameraHasAudioTrack = hasAudio;
        if (!hasAudio) {
          (rawMedia as HTMLVideoElement).muted = true;
          this.liveCameraMuted = true;
        }
        this.host.render();
      };
      rawMedia.addEventListener("loadedmetadata", () => {
        if (this.liveCameraRawMediaEl !== rawMedia) return;
        this.applyRotationToLiveMedia();
        const tracks = (rawMedia as HTMLVideoElement & { audioTracks?: { readonly length: number } }).audioTracks;
        if (tracks !== undefined && typeof tracks.length === "number") {
          updateVideoOnly(tracks.length > 0);
        }
      });
      rawMedia.addEventListener("timeupdate", () => {
        if (this.liveCameraRawMediaEl !== rawMedia) return;
        const video = rawMedia as HTMLVideoElement & {
          webkitAudioDecodedByteCount?: number;
          webkitVideoDecodedByteCount?: number;
        };
        if (typeof video.webkitAudioDecodedByteCount !== "number") return;
        if (video.webkitAudioDecodedByteCount > 0) {
          updateVideoOnly(true);
        } else if (
          !video.muted &&
          typeof video.webkitVideoDecodedByteCount === "number" &&
          video.webkitVideoDecodedByteCount > 0 &&
          video.currentTime >= 0.5
        ) {
          updateVideoOnly(false);
        }
      });
      rawMedia.addEventListener("volumechange", () => {
        if (this.liveCameraRawMediaEl !== rawMedia) return;
        const video = rawMedia as HTMLVideoElement;
        this.liveCameraMuted = video.muted || video.volume === 0;
        this.syncCameraMuteControl();
      });
    } else {
      rawMedia.addEventListener("load", () => {
        if (this.liveCameraRawMediaEl === rawMedia) this.applyRotationToLiveMedia();
      });
    }
    this.applyRotationToLiveMedia();
  }

  public startMjpegTransport(name: string): void {
    this.liveCameraAbort?.abort();
    this.liveCameraImgEl?.remove();
    this.liveCameraImgEl = null;
    this.liveCameraMode = null;
    this.liveCameraLoading = true;
    const img = document.createElement("img");
    img.id = "cc-camera-live-img";
    img.alt = "";
    img.style.cssText = "max-width:100%;border-radius:10px;";
    img.addEventListener("load", () => {
      if (this.liveCameraImgEl === img) this.applyRotationToLiveMedia();
    });
    const abort = new AbortController();
    this.liveCameraAbort = abort;
    void this.pumpAuthenticatedMjpeg(name, img, this.liveCameraToken, abort.signal);
  }

  public ownedGo2rtcOrigin(origin: string): boolean {
    const match = /^http:\/\/127\.0\.0\.1:(\d+)$/.exec(origin);
    if (!match) return false;
    const port = Number(match[1]);
    return port > 0 && port !== 1984 && port !== 8554 && port !== 8555;
  }

  public async refreshOwnedGo2rtcOrigin(): Promise<void> {
    const token = this.liveCameraToken;
    try {
      const endpoint = await this.runNativeCameraOperation<{ origin: string }>("go2rtc_endpoint", undefined, token);
      if (token === this.liveCameraToken) {
        this.ownedStreamOrigin = endpoint && this.ownedGo2rtcOrigin(endpoint.origin) ? endpoint.origin : null;
      }
    } catch {
      if (token === this.liveCameraToken) this.ownedStreamOrigin = null;
    }
  }

  public computeNextFrameGapMs(options: {
    readonly isNewFrame: boolean;
    readonly unchangedCount: number;
    readonly hidden: boolean;
    readonly elapsedMs: number;
  }): number {
    if (options.hidden) {
      return Math.max(0, this.cameraHiddenFrameGapMs);
    }
    if (!options.isNewFrame) {
      const baseIdle = Math.max(0, this.cameraIdleFrameGapMs);
      const step = Math.max(0, options.unchangedCount - 1) * 75;
      return Math.min(CameraLiveController.CAMERA_MAX_IDLE_FRAME_GAP_MS, baseIdle + step);
    }
    const target = Math.max(0, this.cameraActiveFrameGapMs);
    if (target === 0) return 0;
    const elapsed = Math.max(0, options.elapsedMs);
    if (elapsed <= target) {
      return Math.max(Math.min(12, target), Math.round(target - elapsed));
    }
    return Math.min(Math.max(target, this.cameraIdleFrameGapMs), Math.max(12, Math.round(elapsed * 0.35)));
  }

  public async pumpAuthenticatedMjpeg(
    name: string,
    img: HTMLImageElement,
    token: number,
    signal: AbortSignal,
  ): Promise<void> {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    let failureStarted: number | null = null;
    let lastJpeg = "";
    let unchangedCount = 0;
    while (token === this.liveCameraToken && !signal.aborted) {
      let isNewFrame = false;
      let elapsedMs = 0;
      try {
        const startedAt = performance.now();
        const jpeg = await invoke<string>("go2rtc_jpeg_frame", { src: name });
        elapsedMs = Math.max(0, performance.now() - startedAt);
        if (token !== this.liveCameraToken || signal.aborted) return;
        if (!jpeg) throw new Error(t("go2rtc 未返回画面"));
        isNewFrame = jpeg !== lastJpeg;
        if (isNewFrame) {
          unchangedCount = 0;
          img.src = `data:image/jpeg;base64,${jpeg}`;
          lastJpeg = jpeg;
          this.host.onCameraFrameCaptured?.(this.activeLiveCameraId, jpeg);
        } else {
          unchangedCount += 1;
        }
        failureStarted = null;
        if (this.liveCameraImgEl !== img) {
          this.liveCameraImgEl = img;
          this.liveCameraMode = "mjpeg";
          this.liveCameraLoading = false;
          this.liveCameraError = null;
          this.host.render();
          this.attachLiveMedia();
        }
      } catch (err) {
        if (token !== this.liveCameraToken || signal.aborted) return;
        if (isGo2RtcCircuitOpenError(err)) {
          this.failLivePicture(token, liveFrameFailureText(err));
          return;
        }
        if (isGo2RtcBackingOffError(err)) {
          failureStarted = null;
          await waitForCameraFrameGap(signal, this.cameraFrameRetryMs);
          continue;
        }
        failureStarted ??= Date.now();
        if (Date.now() - failureStarted >= this.cameraFrameGiveUpMs) {
          this.failLivePicture(token, liveFrameFailureText(err));
          return;
        }
        await waitForCameraFrameGap(signal, this.cameraFrameRetryMs);
        continue;
      }
      const nextGapMs = this.computeNextFrameGapMs({
        isNewFrame,
        unchangedCount,
        hidden: this.liveCameraHidden,
        elapsedMs,
      });
      await waitForCameraFrameGap(signal, nextGapMs);
    }
  }

  public failLivePicture(token: number, reason: string): void {
    if (token !== this.liveCameraToken || this.activeLiveCameraId === null) return;
    this.liveCameraAbort?.abort();
    this.liveCameraAbort = null;
    this.liveCameraImgEl?.remove();
    this.liveCameraImgEl = null;
    this.liveCameraMode = null;
    this.liveCameraLoading = false;
    const lead = t("实时画面连接失败，请点右上角重新连接");
    const detail = reason.trim();
    this.liveCameraError = detail.length > 0 && detail !== lead ? `${lead} ${detail}` : lead;
    this.host.render();
  }

  /**
   * WebView2/Chromium has no built-in HLS (.m3u8) demuxer. Local go2rtc playlists
   * map directly onto go2rtc's native MJPEG endpoint (`/api/stream.mjpeg`), while
   * remote `.m3u8` playlists are transcoded to MJPEG through `bridge_hls_camera_stream`.
   */
  public normalizeWindowsCameraStreamUrl(rawUrl: string): string {
    return rawUrl.trim().replace(/^(https?):\/\/localhost:(\d+)(\/|$)/i, "$1://127.0.0.1:$2$3");
  }

  public async playCustomCameraUrl(devId: string, playable: string): Promise<void> {
    const token = this.liveCameraToken;
    const normalized = this.normalizeWindowsCameraStreamUrl(playable);
    this.liveCameraStreamURL = normalized;
    this.liveCameraLoading = true;
    await this.refreshOwnedGo2rtcOrigin();
    if (this.liveCameraToken !== token || this.activeLiveCameraId !== devId) return;
    const ownedSrc = this.ownedGo2rtcStreamName(normalized);
    if (ownedSrc) {
      this.liveCameraStreamURL = ownedSrc;
      this.liveCameraError = null;
      this.liveCameraLoading = false;
      this.startMjpegTransport(ownedSrc);
      this.host.render();
      this.attachLiveMedia();
      return;
    }
    this.liveCameraLoading = false;
    this.liveCameraStreamURL = normalized;
    if (this.needsHlsTranscodeBridge(normalized)) {
      void this.bridgeHlsStreamToMjpeg(devId, normalized);
    } else {
      this.host.render();
    }
  }

  public isOwnedGo2rtcApiUrl(url: string): boolean {
    const origin = this.ownedStreamOrigin;
    if (!origin) return false;
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return false;
    }
    if (`${parsed.protocol}//${parsed.host}`.toLowerCase() !== origin.toLowerCase()) return false;
    return parsed.pathname === "/api" || parsed.pathname.startsWith("/api/");
  }

  public ownedGo2rtcStreamName(url: string): string | null {
    if (!this.isOwnedGo2rtcApiUrl(url)) return null;
    let src: string | null;
    try {
      src = new URL(url).searchParams.get("src");
    } catch {
      return null;
    }
    if (!src || !/^[A-Za-z0-9_]+$/.test(src)) return null;
    return src;
  }

  public needsHlsTranscodeBridge(url: string): boolean {
    if (!window.__TAURI_INTERNALS__?.invoke) return false;
    if (this.isOwnedGo2rtcApiUrl(url)) return false;
    if (/\.m3u8(\?|$|#)/i.test(url)) {
      const probe = document.createElement("video");
      const canPlayNative =
        typeof probe.canPlayType === "function" &&
        Boolean(
          probe.canPlayType("application/vnd.apple.mpegurl") ||
            probe.canPlayType("application/x-mpegURL"),
        );
      return !canPlayNative;
    }
    if (
      !/\/api\/camera_proxy/i.test(url) &&
      (/\.(mp4|webm|ogv|ogg|mov|jpg|jpeg|png)(\?|$|#)/i.test(url) ||
        /snapshot|frame\.jpeg|mjpeg/i.test(url))
    ) {
      return false;
    }
    return /^https?:\/\//i.test(url);
  }

  public async bridgeHlsStreamToMjpeg(did: string, hlsUrl: string): Promise<boolean> {
    if (!this.categoryEnabled || !window.__TAURI_INTERNALS__?.invoke) return false;
    const token = this.liveCameraToken;
    this.liveCameraLoading = true;
    this.host.render();
    try {
      if (
        this.host.settings.connectionMode === "homeAssistant" ||
        isDualSourceEnabled(this.host)
      ) {
        await this.host.endpointSubmission;
        if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) return false;
      }
      const mjpegName = await this.runNativeCameraOperation<string>("bridge_hls_camera_stream", {
        did,
        hlsUrl,
      }, token);
      if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) {
        // stopLiveTransport can run before this registration; stop the stream this call just created.
        if (token >= this.lastDisabledToken && mjpegName && this.activeLiveCameraId !== did) {
          void this.runNativeCameraOperation("stop_xiaomi_camera_bridge", { did });
        }
        return false;
      }
      if (mjpegName) {
        // Registration is keyed by this id, so teardown (and a retarget to another card id) has to
        // send the same one back to the backend (#254).
        this.cameraBridgeBindings.set(did, { did, channel: 0, subdid: null, localHls: true });
        this.liveCameraStreamURL = mjpegName;
        this.liveCameraError = null;
        this.liveCameraLoading = false;
        this.startMjpegTransport(mjpegName);
        this.host.render();
        this.attachLiveMedia();
        return true;
      }
      this.liveCameraStreamURL = null;
      this.liveCameraError = t("本地视频桥接未返回可用流，请检查网络后重试");
      this.liveCameraLoading = false;
      this.host.render();
    } catch (err) {
      if (this.liveCameraToken === token && this.activeLiveCameraId === did) {
        this.liveCameraStreamURL = null;
        this.liveCameraError = err instanceof Error ? err.message : String(err);
        this.liveCameraLoading = false;
        this.host.render();
      }
    }
    return false;
  }

  public setCameraStreamQuality(deviceId: string, quality: CameraStreamQuality): void {
    this.cameraStreamQualities = { ...this.cameraStreamQualities, [deviceId]: quality };
    this.host.settings.cameraStreamQualities = { ...this.cameraStreamQualities };
    this.host.saveSettings();
  }

  public selectedCameraLens(dev: SmartDevice): CameraLens | null {
    if (dev.kind.kind !== "camera") return null;
    const lenses = dev.kind.lenses;
    if (!lenses || lenses.length <= 1) return null;
    const saved = this.cameraChannels[dev.id];
    return lenses.find((lens) => lens.channel === saved) ?? lenses[0] ?? null;
  }

  public selectedCameraChannel(dev: SmartDevice): number {
    return this.selectedCameraLens(dev)?.channel ?? 0;
  }

  public setCameraLensChannel(deviceId: string, channel: number): void {
    const normalized = Math.max(0, Math.trunc(channel));
    this.cameraChannels = { ...this.cameraChannels, [deviceId]: normalized };
    savePersistedRecord(CameraLiveController.CAMERA_CHANNELS_STORAGE_KEY, this.cameraChannels);
  }

  public commitCameraLocalIp(): void {
    const id = this.activeLiveCameraId;
    if (!id) return;
    const input = this.host.root.querySelector<HTMLInputElement>("#camera-local-ip-input");
    const raw = input?.value ?? "";
    this.liveCameraDraftIp = raw;
    const parsed = parsePrivateLanIpv4(raw);
    if (!parsed) {
      this.liveCameraLocalIpError = tr3(
        "请输入有效的局域网私有 IPv4 地址（192.168.x.x / 172.16-31.x.x / 10.x.x.x）",
        "請輸入有效的區域網私有 IPv4 位址（192.168.x.x / 172.16-31.x.x / 10.x.x.x）",
        "Enter a valid private IPv4 LAN address (192.168.x.x / 172.16-31.x.x / 10.x.x.x)",
      );
      this.host.render();
      return;
    }
    this.liveCameraLocalIpError = null;
    this.liveCameraDraftIp = null;
    this.cameraLocalIPs = { ...this.cameraLocalIPs, [id]: parsed };
    savePersistedRecord(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY, this.cameraLocalIPs);
    this.reconnectCameraLiveView();
  }

  public clearCameraLocalIp(deviceId = this.activeLiveCameraId): void {
    if (!deviceId) return;
    const next = { ...this.cameraLocalIPs };
    delete next[deviceId];
    this.cameraLocalIPs = next;
    this.liveCameraLocalIpError = null;
    this.liveCameraDraftIp = null;
    savePersistedRecord(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY, this.cameraLocalIPs);
    if (deviceId === this.activeLiveCameraId) {
      this.reconnectCameraLiveView();
    }
  }

  public reconnectCameraLiveView(streamUrlOverride?: string | null): void {
    const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
    if (!dev || dev.kind.kind !== "camera") return;
    if (this.resolveCameraSource(dev).backend === "xiaomiCloud") {
      this.reconnectingP2PSessionId = this.p2pSessionKeyForDevice(dev);
    }
    this.stopLiveTransport();
    this.liveCameraQualityApplies = true;
    const rawStreamUrl = this.cameraStreamURLs[dev.id] ?? streamUrlOverride ?? null;
    this.liveCameraStreamURL = rawStreamUrl
      ? this.normalizeWindowsCameraStreamUrl(rawStreamUrl)
      : this.resolveHaCameraStreamUrl(dev);
    this.liveCameraError = null;
    this.liveCameraLoading = false;
    if (this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (!this.liveCameraStreamURL && this.resolveCameraSource(dev).backend === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    }
    this.host.render();
  }

  public resolveCloudCameraStream(dev: SmartDevice): Promise<void> {
    const token = this.liveCameraToken;
    const prepare = async () => {
      if (this.categoryRelease) await this.categoryRelease;
      if (!this.categoryEnabled || token !== this.liveCameraToken) return;
      await this.negotiateCloudCameraStream(dev);
    };
    const pending = prepare().finally(() => this.negotiations.delete(pending));
    this.negotiations.add(pending);
    return pending;
  }

  private async negotiateCloudCameraStream(dev: SmartDevice): Promise<void> {
    const { backend, sourceDev, miSession: session } = this.resolveCameraSource(dev);
    if (dev.kind.kind !== "camera" || backend !== "xiaomiCloud" || !session || !isHostMiSessionEnabled(this.host, session)) return;
    if (CameraHubCatalog.isHub(sourceDev.model)) {
      this.liveCameraQualityApplies = false;
      this.liveCameraNeedsManualIp = false;
      this.liveCameraLoading = false;
      this.liveCameraError = tr3(
        "室内网关本身不提供画面，请打开其配对的室外摄像机观看",
        "室內網關本身不提供畫面，請開啟其配對的室外攝影機觀看",
        "The indoor gateway has no camera feed of its own; open its paired battery camera instead",
      );
      this.host.render();
      return;
    }

    const channel = this.selectedCameraChannel(dev);
    const requiresHub = CameraHubCatalog.hubModel(sourceDev.model) !== null;
    const retained: RetainedCloudStream = { session };
    this.cloudStreamSessions.set(dev.id, retained);
    this.liveCameraLoading = true;
    this.liveCameraNeedsManualIp = false;
    this.host.render();
    // Closing/hiding bumps liveCameraToken via stopLiveTransport or full teardown;
    // a negotiation that outlives its modal must not start a bridge afterwards.
    const token = this.liveCameraToken;
    const negotiation = new AbortController();
    this.negotiationAbort = negotiation;
    const hasCustomUrl = () => Boolean(this.cameraStreamURLs[dev.id]);
    const stale = () =>
      this.liveCameraToken !== token ||
      this.activeLiveCameraId !== dev.id ||
      hasCustomUrl() ||
      !isHostMiSessionEnabled(this.host, session);
    const wasDisabled = () => token < this.lastDisabledToken;
    const shouldReleaseStaleCloudSession = () =>
      wasDisabled() || this.activeLiveCameraId !== dev.id || hasCustomUrl();
    let startedP2PSession = false;
    let startedCloudStream = false;
    let streamRemainsOpen = false;
    let releaseArmed = false;
    let failureReason: string | null = null;
    const releaseIfStarted = (releaseToken = token) => {
      if (!startedP2PSession && !startedCloudStream) return;
      startedP2PSession = false;
      startedCloudStream = false;
      releaseArmed = true;
      void this.releaseCameraP2PSession(dev, releaseToken, true, session, retained, wasDisabled());
    };
    const abandonIfStale = (): boolean => {
      if (!stale()) return false;
      if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
      return true;
    };
    try {
      if (this.host.settings.blockControlWhileLocked && window.__TAURI_INTERNALS__?.invoke) {
        if (
          await rejectIfControlBlockedWhileLocked(this.host, {
            beforeRender: () => {
              if (!stale()) {
                this.liveCameraLoading = false;
                this.liveCameraError = t("屏幕已锁定，已拦截设备控制指令");
              }
            },
          })
        ) {
          return;
        }
        if (stale()) return;
      }
      const pendingRelease = this.pendingCameraReleases.get(dev.id);
      if (pendingRelease) {
        await pendingRelease;
        if (stale()) return;
      }
      const spec = await this.host.specResolver.resolve({
        did: sourceDev.id,
        name: sourceDev.name,
        model: sourceDev.model,
        isOnline: sourceDev.isOnline,
        specType: null,
      });
      if (stale()) return;
      const client = new MiCloudClient(session, this.host.transport);

      // 1. Try cloud HLS action on primary standalone lens if supported by the model
      const streamSvc =
        !requiresHub && channel === 0
          ? (spec.services.find((s) => s.actions.some((a) => a.type.includes("start-hls-stream"))) ?? null)
          : null;
      const act = streamSvc?.actions.find((a) => a.type.includes("start-hls-stream"));
      if (streamSvc && act) {
        // macOS parity (MiCloudProvider.resolveCameraStream): the documented action carries
        // typed inputs; try the bare call, then the codec-index variant, and treat every
        // failure as "no cloud HLS" so the P2P bridge below still runs (#97).
        for (const inputs of [[], [1]]) {
          if (abandonIfStale()) return;
          try {
            const res = await client.callAction({
              did: sourceDev.id,
              siid: streamSvc.iid,
              aiid: act.iid,
              inputs,
            });
            startedCloudStream = true;
            if (abandonIfStale()) return;
            const rawJson = JSON.stringify(res ?? {});
            const urlMatch = /https?:\/\/[^\s"'\\]+/i.exec(rawJson);
            if (urlMatch?.[0]) {
              const playable = this.normalizeWindowsCameraStreamUrl(urlMatch[0]);
              if (this.needsHlsTranscodeBridge(playable)) {
                this.liveCameraQualityApplies = false;
                const bridged = await this.bridgeHlsStreamToMjpeg(dev.id, playable);
                if (abandonIfStale()) return;
                if (bridged) {
                  streamRemainsOpen = true;
                  return;
                }
                this.liveCameraQualityApplies = true;
                // Bridging failed: fall through to P2P below instead of assigning an unplayable .m3u8.
                break;
              }
              if (!/\.m3u8(\?|$|#)/i.test(playable) || !window.__TAURI_INTERNALS__?.invoke) {
                this.liveCameraQualityApplies = false;
                this.liveCameraStreamURL = playable;
                this.liveCameraError = null;
                this.liveCameraLoading = false;
                streamRemainsOpen = true;
                this.host.render();
                return;
              }
            }
          } catch {
            if (abandonIfStale()) return;
            // Cloud HLS rejected (bad inputs / 403 / offline): fall back to P2P.
          }
        }
      }

      if (abandonIfStale()) return;
      // 2. Release any previous P2P session, then wake a fresh one (siid=9 p2p-stream service)
      const sessionKey = this.p2pSessionKeyForDevice(dev);
      const isSameSessionReconnect = this.reconnectingP2PSessionId === sessionKey;
      if (isSameSessionReconnect) {
        this.reconnectingP2PSessionId = null;
      }
      const lastSessionAt = this.recentP2PSessionActivityMs.get(sessionKey);
      const recentlyUsedSameSession =
        lastSessionAt !== undefined &&
        Date.now() - lastSessionAt < Math.max(this.cameraKeepAliveMs, this.cameraSameSessionCooldownMs);
      const needsSameSessionCooldown =
        isSameSessionReconnect || Boolean(pendingRelease) || recentlyUsedSameSession;

      const p2pSvc = spec.services.find((s) => s.actions.some((a) => a.type.includes("start-p2p-stream")));
      const stopAct = p2pSvc?.actions.find((a) => a.type.includes("stop-stream"));
      const p2pAct = p2pSvc?.actions.find((a) => a.type.includes("start-p2p-stream"));
      if (p2pSvc && stopAct) {
        const released = await client
          .callAction({ did: sourceDev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
        if (abandonIfStale()) return;
        if (released && needsSameSessionCooldown && this.cameraSameSessionCooldownMs > 0) {
          await waitForCameraFrameGap(negotiation.signal, this.cameraSameSessionCooldownMs);
          if (abandonIfStale()) return;
        }
      }
      if (abandonIfStale()) return;
      if (p2pSvc && p2pAct) {
        startedP2PSession = await client
          .callAction({ did: sourceDev.id, siid: p2pSvc.iid, aiid: p2pAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
        if (startedP2PSession) {
          this.recentP2PSessionActivityMs.set(sessionKey, Date.now());
        }
      }
      if (stale()) {
        if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
        return;
      }

      // 3. Negotiate MISS CS2/TUTK P2P keys & start native Tauri bridge
      if (window.__TAURI_INTERNALS__?.invoke) {
        const target = await resolveLiveCameraTarget(
          client,
          sourceDev,
          this.host.devices,
          this.host.settings.selectedHomeId,
          this.resolveCachedCameraTopology(dev, sourceDev),
        );
        if (stale()) {
          if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
          return;
        }
        const { bridgeDid, bridgeModel, subdid, cloudLocalIp, hubBlockedReason } = target;

        if (hubBlockedReason) {
          failureReason = hubBlockedReason;
        } else {
          this.cameraBridgeBindings.set(dev.id, { did: bridgeDid, channel, subdid });
          const manualLocalIp = this.cameraLocalIPs[dev.id] ?? "";
          const effectiveLocalIp = cloudLocalIp || manualLocalIp;
          this.liveCameraNeedsManualIp = !cloudLocalIp;
          if (effectiveLocalIp) {
            const kp = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
            const spki = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey));
            const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
            const clientPublic = Array.from(spki.slice(-32)).map((b) => b.toString(16).padStart(2, "0")).join("");
            const clientPrivate = Array.from(pkcs8.slice(-32)).map((b) => b.toString(16).padStart(2, "0")).join("");

            if (abandonIfStale()) return;
            const vendorRes = (await client.request("v2/device/miss_get_vendor", {
              did: bridgeDid,
              app_pubkey: clientPublic,
              support_vendors: "TUTK_CS2_MTP",
            })) as Record<string, unknown> | null;
            if (stale()) {
              if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
              return;
            }
            const vendorObj = (vendorRes?.["vendor"] as Record<string, unknown> | undefined) ?? {};
            const vendorId = Number(vendorObj["vendor"] ?? 4);
            const vendorName = vendorId === 1 ? "tutk" : vendorId === 4 ? "cs2" : String(vendorId);
            const vendorParams = (vendorObj["vendor_params"] as Record<string, unknown> | undefined) ?? {};
            const p2pUid = typeof vendorParams["p2p_id"] === "string" ? vendorParams["p2p_id"] : null;
            const devicePublic = typeof vendorRes?.["public_key"] === "string" ? vendorRes["public_key"] : "";
            const sign = typeof vendorRes?.["sign"] === "string" ? vendorRes["sign"] : "";

            if (devicePublic && sign) {
              if (stale()) {
                if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
                return;
              }
              this.liveCameraQualityApplies = true;
              const bridge = await this.runNativeCameraOperation<string>("start_xiaomi_camera_bridge", {
                did: bridgeDid,
                model: bridgeModel,
                localIp: effectiveLocalIp,
                clientPublic,
                clientPrivate,
                devicePublic,
                sign,
                vendor: vendorName,
                uid: p2pUid,
                quality: this.cameraStreamQualities[dev.id] ?? DEFAULT_CAMERA_STREAM_QUALITY,
                ...(channel > 0 ? { channel } : {}),
                ...(subdid ? { subdid } : {}),
                // Windows P2P renders MJPEG frames via go2rtc_jpeg_frame (`p2p-mjpeg`, video-only),
                // so keep audio suppressed (`audio=0`) on the bridge stream.
                audioEnabled: false,
              }, token);
              if (stale()) {
                // The close path already tore down once; this late start re-created a
                // relay and stream registrations that nothing else will reclaim. Undo
                // them — unless the same camera was re-opened, in which case the new
                // negotiation's own stop_bridge replaces them and must not be killed.
                if (shouldReleaseStaleCloudSession()) {
                  if (!wasDisabled()) void this.runNativeCameraOperation("stop_xiaomi_camera_bridge", {
                    did: bridgeDid,
                    ...(channel > 0 ? { channel } : {}),
                    ...(subdid ? { subdid } : {}),
                  });
                  releaseIfStarted(this.liveCameraToken);
                }
                return;
              }
              this.recentP2PSessionActivityMs.set(bridgeDid, Date.now());
              const [h264Name, mjpegName] = (bridge ?? "").split("|");
              if (mjpegName) {
                this.liveCameraStreamURL = mjpegName;
                this.liveCameraError = null;
                this.liveCameraLoading = false;
                this.startMjpegTransport(mjpegName);
                streamRemainsOpen = true;
                this.host.render();
                this.attachLiveMedia();
                return;
              }
              if (h264Name) {
                this.liveCameraQualityApplies = false;
                releaseIfStarted();
                this.liveCameraStreamURL = h264Name;
                this.liveCameraError = t("实时画面连接失败，请点右上角重新连接");
                this.liveCameraLoading = false;
                this.host.render();
                return;
              }
              failureReason = t("本地视频桥接未返回可用流，请检查网络后重试");
            } else {
              failureReason = t("该摄像机型号暂不支持自动获取局域网 P2P 密钥，可在下方填写本地 go2rtc / HLS 流地址观看");
            }
          } else {
            failureReason = t("未获取到摄像机局域网 IP，请确认电脑与摄像机处于同一局域网");
          }
        }
      }

      releaseIfStarted();
      this.liveCameraQualityApplies = false;
      this.liveCameraError = failureReason ?? t("米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址观看实时画面");
    } catch (err) {
      if (stale()) {
        if (shouldReleaseStaleCloudSession()) releaseIfStarted(this.liveCameraToken);
      } else {
        releaseIfStarted();
        this.liveCameraQualityApplies = false;
        this.liveCameraError = err instanceof Error ? err.message : String(err);
      }
    } finally {
      if (this.negotiationAbort === negotiation) this.negotiationAbort = null;
      if (!streamRemainsOpen && !releaseArmed) this.dropRetainedCloudStream(dev.id, retained);
    }
    if (stale()) return;
    this.liveCameraLoading = false;
    this.host.render();
  }

  public renderCameraLiveModal(): string {
    return renderCameraLiveModalView(this);
  }

  public async commitCameraStreamUrl(): Promise<void> {
    const id = this.activeLiveCameraId;
    if (!id) return;
    const input = this.host.root.querySelector<HTMLInputElement>("#camera-stream-url-input");
    const val = input?.value.trim() ?? "";
    const dev = this.host.devices.find((d) => d.id === id) ??
      (this.activeLiveCameraSnapshot?.id === id ? this.activeLiveCameraSnapshot : undefined);
    const isXiaomiCamera = dev ? this.resolveCameraSource(dev).backend === "xiaomiCloud" : false;
    const hadCustomUrl = Boolean(this.cameraStreamURLs[id]);
    if (val) this.cameraStreamURLs[id] = val;
    else delete this.cameraStreamURLs[id];
    this.host.settings.cameraStreamURLs = { ...this.cameraStreamURLs };
    this.host.saveSettings();
    this.stopLiveTransport();
    const token = this.liveCameraToken;
    if (dev && isXiaomiCamera && (val || (!hadCustomUrl && dev.kind.kind === "camera" && !dev.kind.isOn))) {
      void this.releaseCameraP2PSession(dev, token, true);
    }
    await this.refreshOwnedGo2rtcOrigin();
    const stillViewing = this.liveCameraToken === token && this.activeLiveCameraId === id;
    if (!stillViewing) return;
    if (val) {
      const playable = this.normalizeWindowsCameraStreamUrl(val);
      this.liveCameraStreamURL = playable;
      this.liveCameraError = null;
      this.liveCameraLoading = false;
      const ownedSrc = this.ownedGo2rtcStreamName(playable);
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn && ownedSrc) {
        this.liveCameraStreamURL = ownedSrc;
        this.startMjpegTransport(ownedSrc);
      } else if (dev && dev.kind.kind === "camera" && dev.kind.isOn && this.needsHlsTranscodeBridge(playable)) {
        void this.bridgeHlsStreamToMjpeg(id, playable);
      }
    } else {
      this.liveCameraStreamURL = dev ? this.resolveHaCameraStreamUrl(dev) : null;
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn) {
        if (this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
          void this.bridgeHlsStreamToMjpeg(id, this.liveCameraStreamURL);
        } else if (!this.liveCameraStreamURL && isXiaomiCamera) {
          void this.resolveCloudCameraStream(dev);
        }
      }
    }
    this.liveCameraShowingURLInput = false;
    this.host.render();
    if (this.liveCameraMode === "mjpeg") this.attachLiveMedia();
  }

  bindEvents(): void {
    this.syncModalEscapeListener();
    this.host.root.querySelector<HTMLElement>(".cc-camera-live-sheet")?.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !this.liveCameraHidden && !this.hasHigherPriorityOverlayOpen()) {
        event.preventDefault();
        event.stopPropagation();
        this.hideCameraLiveView();
      }
    });
    this.host.root.querySelector("#btn-close-camera-live")?.addEventListener("click", () => {
      this.hideCameraLiveView();
    });

    this.host.root.querySelector("#btn-reload-camera-live")?.addEventListener("click", () => {
      this.reconnectCameraLiveView();
    });

    this.host.root.querySelector("#btn-rotate-camera-live")?.addEventListener("click", () => {
      this.rotateActiveCamera();
    });

    // Toggle in place: a re-render would rebuild the <video> element and restart playback.
    this.host.root.querySelector("#cc-camera-mute")?.addEventListener("click", () => {
      const muted = !this.liveCameraMuted;
      const video = this.host.root.querySelector<HTMLVideoElement>("#cc-camera-video");
      if (video) {
        video.muted = muted;
        // A native control can mute or zero the volume on its own, and unmuting alone leaves a
        // zero volume silent, so restore an audible level when turning sound on.
        if (!muted && video.volume === 0) video.volume = 1;
      }
      this.liveCameraMuted = muted;
      this.syncCameraMuteControl();
    });

    this.host.root.querySelectorAll<HTMLElement>("[data-cameraswitch]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const targetId = btn.dataset.cameraswitch ?? "";
        if (!targetId || targetId === this.activeLiveCameraId) return;
        this.openCameraLiveView(targetId);
      });
    });

    this.host.root.querySelectorAll<HTMLElement>("[data-cameralens]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameralens ?? "";
        const dev = this.host.devices.find((d) => d.id === deviceId);
        if (!dev || dev.kind.kind !== "camera") return;
        const channel = Number(btn.dataset.cameralensChannel ?? "0");
        if (!Number.isFinite(channel) || channel === this.selectedCameraChannel(dev)) return;
        this.setCameraLensChannel(deviceId, channel);
        this.reconnectCameraLiveView();
      });
    });

    this.host.root.querySelectorAll<HTMLElement>("[data-cameraquality]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameraquality ?? "";
        const dev = this.host.devices.find((d) => d.id === deviceId);
        if (!dev || dev.kind.kind !== "camera") return;
        const quality = normalizeCameraStreamQuality(btn.dataset.cameraqualityValue);
        if (quality === (this.cameraStreamQualities[deviceId] ?? DEFAULT_CAMERA_STREAM_QUALITY)) return;
        this.setCameraStreamQuality(deviceId, quality);
        this.reconnectCameraLiveView();
      });
    });

    this.attachLiveMedia();

    this.host.root.querySelectorAll<HTMLElement>("#btn-toggle-camera-url, [data-toggle-camera-url]").forEach((btn) => {
      btn.addEventListener("click", () => {
        this.liveCameraShowingURLInput = !this.liveCameraShowingURLInput;
        this.host.render();
      });
    });

    this.host.root.querySelector("#btn-copy-camera-diag")?.addEventListener("click", () => {
      const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
      if (!dev || dev.kind.kind !== "camera") return;
      const isOn = dev.kind.isOn;
      const redact = (raw: string) =>
        raw
          .replace(/https?:\/\/[^\s"'<>]+/gi, "<redacted-url>")
          .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "<redacted-ip>")
          .replace(/\b[0-9a-fA-F]{24,}\b/g, "<redacted-token>");
      const writeReport = (supervisorStatus: Go2RtcSupervisorStatus | null) => {
        const report = [
          "MenuBarHome Camera Diagnostics (Windows)",
          `model: ${dev.model}`,
          `online: ${dev.isOnline}`,
          `isOn: ${isOn}`,
          `connectionMode: ${this.host.settings.connectionMode}`,
          `hasCustomURL: ${Boolean(this.cameraStreamURLs[dev.id])}`,
          `hasManualIP: ${Boolean(this.cameraLocalIPs[dev.id])}`,
          `channel: ${this.selectedCameraChannel(dev)}`,
          ...formatGo2RtcSupervisorDiagnostics(supervisorStatus, redact),
          `error: ${redact(this.liveCameraError ?? "none")}`,
        ].join("\n");
        void navigator.clipboard?.writeText(report).catch(() => {});
        this.host.replyBanner = { text: t("已复制脱敏诊断信息"), source: t("摄像机诊断") };
        this.host.render();
      };
      const invoke = window.__TAURI_INTERNALS__?.invoke;
      if (!invoke) {
        writeReport(null);
        return;
      }
      void invoke<Go2RtcSupervisorStatus>("go2rtc_supervisor_status")
        .then((status) => writeReport(status && typeof status === "object" ? status : null))
        .catch(() => writeReport(null));
    });

    this.host.root.querySelector("#btn-save-camera-url")?.addEventListener("click", () => {
      void this.commitCameraStreamUrl();
    });

    this.host.root.querySelector("#btn-save-camera-ip")?.addEventListener("click", () => {
      this.commitCameraLocalIp();
    });

    const ipInput = this.host.root.querySelector<HTMLInputElement>("#camera-local-ip-input");
    ipInput?.addEventListener("input", () => {
      this.liveCameraDraftIp = ipInput.value;
    });
    ipInput?.addEventListener("keydown", (event) => {
      if (event.isComposing || event.keyCode === 229) return;
      if (event.key === "Enter") {
        event.preventDefault();
        this.commitCameraLocalIp();
      }
    });

    this.host.root.querySelectorAll<HTMLElement>("#btn-clear-camera-ip").forEach((btn) => {
      btn.addEventListener("click", () => {
        this.clearCameraLocalIp();
      });
    });
  }

  public rotateButtonTitle(rotation: CameraRotationDeg): string {
    return rotation === 0
      ? tr3("旋转画面 90°", "旋轉畫面 90°", "Rotate video 90°")
      : tr3("旋转画面 90°（当前 {rotation}°）", "旋轉畫面 90°（目前 {rotation}°）", "Rotate video 90° (currently {rotation}°)", { rotation });
  }

  private syncCameraRotateControl(): void {
    const button = this.host.root.querySelector<HTMLElement>("#btn-rotate-camera-live");
    if (!button) return;
    const rotation = this.cameraRotation(this.activeLiveCameraId);
    const label = this.rotateButtonTitle(rotation);
    button.dataset.rotation = String(rotation);
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(rotation !== 0));
    button.classList.toggle("is-active", rotation !== 0);
  }

  private syncCameraMuteControl(): void {
    const button = this.host.root.querySelector<HTMLElement>("#cc-camera-mute");
    if (!button) return;
    const label = t(this.liveCameraMuted ? "开启声音" : "关闭声音");
    const icon = button.querySelector<HTMLElement>("[data-camera-mute-icon]");
    const text = button.querySelector<HTMLElement>("[data-camera-mute-text]");
    if (icon) {
      icon.innerHTML = this.liveCameraMuted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave;
    } else {
      button.innerHTML = this.liveCameraMuted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave;
    }
    if (text) text.textContent = label;
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(this.liveCameraMuted));
    button.classList.toggle("is-active", !this.liveCameraMuted);
  }
}

function loadRawStorageMap(key: string): Record<string, unknown> {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function savePersistedRecord(key: string, record: Readonly<Record<string, unknown>>): void {
  try {
    globalThis.localStorage?.setItem(key, JSON.stringify(record));
  } catch {
    // Ignore quota or sandboxed storage errors.
  }
}

function loadPersistedCameraChannels(): Record<string, number> {
  const raw = loadRawStorageMap(CameraLiveController.CAMERA_CHANNELS_STORAGE_KEY);
  const out: Record<string, number> = {};
  for (const [id, value] of Object.entries(raw)) {
    if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
      out[id] = Math.trunc(value);
    }
  }
  return out;
}

function loadPersistedCameraRotations(): Record<string, CameraRotationDeg> {
  const raw = loadRawStorageMap(CameraLiveController.CAMERA_ROTATIONS_STORAGE_KEY);
  const out: Record<string, CameraRotationDeg> = {};
  for (const [id, value] of Object.entries(raw)) {
    if (value === 0 || value === 90 || value === 180 || value === 270) {
      out[id] = value;
    }
  }
  return out;
}

function loadPersistedCameraLocalIPs(): Record<string, string> {
  const raw = loadRawStorageMap(CameraLiveController.CAMERA_LOCAL_IPS_STORAGE_KEY);
  const out: Record<string, string> = {};
  for (const [id, value] of Object.entries(raw)) {
    if (typeof value === "string") {
      const valid = parsePrivateLanIpv4(value);
      if (valid) out[id] = valid;
    }
  }
  return out;
}

function liveFrameFailureText(err: unknown): string {
  const text = typeof err === "string" ? err : err instanceof Error ? err.message : "";
  const trimmed = text.trim();
  return trimmed || t("go2rtc 未返回画面");
}
