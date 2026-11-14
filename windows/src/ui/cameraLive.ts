import { t } from "../core/i18n.js";
import {
  DEFAULT_CAMERA_STREAM_QUALITY,
  normalizeCameraStreamQuality,
  type CameraStreamQuality,
} from "../core/cameraQuality.js";
import {
  CameraHubCatalog,
  cameraTr,
  parsePrivateLanIpv4,
  resolveLiveCameraTarget,
} from "../core/miCloud/cameraHubs.js";
import {
  MiCloudClient,
  type HttpTransport,
  type MiotSpecResolver,
} from "../core/miCloudClient.js";
import type { CameraLens, SmartDevice } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
import type { PersistedSettings } from "./appTypes.js";
import { computeQuarterTurnScale, renderCameraLiveModalView } from "./cameraLiveModalView.js";
import { waitForCameraFrameGap } from "./dom.js";
import { hasPendingUrlConfirmation } from "./speechGuard.js";
import { invokeTauriVoid } from "./transport.js";

export type CameraRotationDeg = 0 | 90 | 180 | 270;

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
}

export interface CameraLiveHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  readonly devices: readonly SmartDevice[];
  readonly transport: HttpTransport;
  readonly specResolver: MiotSpecResolver;
  readonly endpointSubmission: Promise<unknown>;
  readonly isGrokBallStageExpanded?: boolean;
  readonly prompt?: unknown;
  readonly ctxMenu?: unknown;
  readonly isRecordingHotkey?: boolean;
  readonly activeSheet?: string;
  replyBanner: { text: string; source: string; isError?: boolean } | null;
  render(): void;
  escapeHtml(value: string): string;
  saveSettings(): void;
  shouldKeepPopoverPinned(): boolean;
}

export class CameraLiveController {
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
  /** Target frame interval (~20fps ceiling) when visible and receiving fresh frames. */
  cameraActiveFrameGapMs = CameraLiveController.CAMERA_ACTIVE_FRAME_GAP_MS;
  /** Power-saving interval when consecutive frames are unchanged. */
  cameraIdleFrameGapMs = CameraLiveController.CAMERA_IDLE_FRAME_GAP_MS;
  /** Background keep-alive interval while the live modal is hidden. */
  cameraHiddenFrameGapMs = CameraLiveController.CAMERA_HIDDEN_FRAME_GAP_MS;
  /** Cooldown before re-negotiating the SAME camera's single P2P session; skipped on cross-camera switch. */
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
  public liveCameraQualityApplies = true;
  public liveCameraImgEl: HTMLImageElement | null = null;
  public liveCameraRawMediaEl: HTMLImageElement | HTMLVideoElement | null = null;
  public liveCameraAbort: AbortController | null = null;
  public ownedStreamOrigin: string | null = null;
  public liveCameraToken = 0;
  public readonly pendingCameraReleases = new Map<string, Promise<void>>();
  private readonly cameraBridgeBindings = new Map<string, CameraBridgeBinding>();
  private readonly recentP2PSessionActivityMs = new Map<string, number>();
  private reconnectingP2PSessionId: string | null = null;
  private escapeKeyDisposer: (() => void) | null = null;

  private p2pSessionKeyForDevice(dev: SmartDevice): string {
    const bound = this.cameraBridgeBindings.get(dev.id);
    if (bound?.did) return bound.did;
    if (dev.kind.kind === "camera" && dev.kind.gatewayDid) return dev.kind.gatewayDid;
    return dev.id;
  }

  private hasHigherPriorityOverlayOpen(): boolean {
    return (
      Boolean(this.host.isGrokBallStageExpanded) ||
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

  public openCameraLiveView(deviceId: string): void {
    const dev = this.host.devices.find((d) => d.id === deviceId);
    if (!dev || dev.kind.kind !== "camera") return;
    // Opening is idempotent even before the first frame or while cloud negotiation is
    // pending. Only the explicit reconnect action may replace this camera's session.
    if (this.activeLiveCameraId === deviceId) {
      this.liveCameraHidden = false;
      this.clearCameraKeepAlive();
      this.syncModalEscapeListener();
      invokeTauriVoid("set_pin_popover", { pin: true });
      // A power-on while hidden skips the reconnect, so this is the first chance to start it.
      if (dev.kind.isOn && !this.liveCameraImgEl && !this.liveCameraRawMediaEl && !this.liveCameraLoading && !this.liveCameraError) {
        this.reconnectCameraLiveView();
      }
      this.host.render();
      return;
    }
    if (this.activeLiveCameraId !== null && this.activeLiveCameraId !== deviceId) {
      this.teardownActiveCameraForSwitch();
    }
    this.reconnectingP2PSessionId = null;
    this.activeLiveCameraId = dev.id;
    this.activeLiveCameraSnapshot = dev;
    this.liveCameraMuted = true;
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
    if (dev.kind.isOn && this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (dev.kind.isOn && this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
      void this.bridgeHlsStreamToMjpeg(dev.id, this.liveCameraStreamURL);
    } else if (dev.kind.isOn && !this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    }
    this.host.render();
  }

  private teardownActiveCameraForSwitch(): void {
    const closingId = this.activeLiveCameraId;
    const closingDev = closingId
      ? this.host.devices.find((d) => d.id === closingId) ??
        (this.activeLiveCameraSnapshot?.id === closingId ? this.activeLiveCameraSnapshot : undefined)
      : undefined;
    if (closingDev && this.host.settings.connectionMode === "xiaomiCloud") {
      this.recentP2PSessionActivityMs.set(this.p2pSessionKeyForDevice(closingDev), Date.now());
    }
    this.clearCameraKeepAlive();
    this.liveCameraHidden = false;
    this.stopLiveTransport();
    this.activeLiveCameraId = null;
    this.activeLiveCameraSnapshot = null;
    this.syncModalEscapeListener();
    if (closingId && this.host.settings.connectionMode === "xiaomiCloud" && closingDev) {
      void this.releaseCameraP2PSession(closingDev, this.liveCameraToken);
    }
  }

  public resolveHaCameraStreamUrl(dev: SmartDevice): string | null {
    if (this.host.settings.connectionMode !== "homeAssistant" || dev.kind.kind !== "camera") return null;
    const rawPath = dev.kind.snapshotPath?.trim() ?? "";
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
    this.liveCameraKeepAliveTimer = window.setTimeout(() => {
      this.liveCameraKeepAliveTimer = null;
      // Nobody came back within the keep-alive window: release the camera's
      // single P2P session so the phone app (or the next open) can use it.
      if (this.liveCameraHidden) this.closeCameraLiveView();
    }, this.cameraKeepAliveMs);
    this.host.render();
  }

  public clearCameraKeepAlive(): void {
    if (this.liveCameraKeepAliveTimer !== null) {
      window.clearTimeout(this.liveCameraKeepAliveTimer);
      this.liveCameraKeepAliveTimer = null;
    }
  }

  public closeCameraLiveView(): void {
    const closingId = this.activeLiveCameraId;
    const closingDev = closingId
      ? this.host.devices.find((d) => d.id === closingId) ??
        (this.activeLiveCameraSnapshot?.id === closingId ? this.activeLiveCameraSnapshot : undefined)
      : undefined;
    if (closingDev && this.host.settings.connectionMode === "xiaomiCloud") {
      this.recentP2PSessionActivityMs.set(this.p2pSessionKeyForDevice(closingDev), Date.now());
    }
    this.reconnectingP2PSessionId = null;
    this.clearCameraKeepAlive();
    this.liveCameraHidden = false;
    this.stopLiveTransport();
    this.activeLiveCameraId = null;
    this.activeLiveCameraSnapshot = null;
    this.syncModalEscapeListener();
    this.liveCameraMuted = true;
    this.liveCameraQualityApplies = true;
    this.liveCameraStreamURL = null;
    this.liveCameraLoading = false;
    this.liveCameraError = null;
    this.liveCameraShowingURLInput = false;
    this.liveCameraNeedsManualIp = false;
    this.liveCameraLocalIpError = null;
    this.liveCameraDraftIp = null;
    if (closingId && this.host.settings.connectionMode === "xiaomiCloud" && closingDev) {
      void this.releaseCameraP2PSession(closingDev, this.liveCameraToken);
    }
    invokeTauriVoid("set_pin_popover", { pin: this.host.shouldKeepPopoverPinned() });
    this.host.render();
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
  ): Promise<void> {
    const session = this.host.settings.miSession;
    if (!session) return Promise.resolve();
    const run = (async () => {
      try {
        const spec = await this.host.specResolver.resolve({
          did: dev.id,
          name: dev.name,
          model: dev.model,
          isOnline: dev.isOnline,
          specType: null,
        });
        if (this.liveCameraToken !== releaseToken || (!allowActiveCamera && this.activeLiveCameraId === dev.id)) return;
        const p2pSvc = spec.services.find((s) => s.actions.some((a) => a.type.includes("stop-stream")));
        const stopAct = p2pSvc?.actions.find((a) => a.type.includes("stop-stream"));
        if (!p2pSvc || !stopAct) return;
        const client = new MiCloudClient(session, this.host.transport);
        await client
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .catch(() => {});
      } catch {
        // Best effort only; the bridge teardown below already freed local resources.
      }
    })();
    const tracked = run.finally(() => {
      if (this.pendingCameraReleases.get(dev.id) === tracked) {
        this.pendingCameraReleases.delete(dev.id);
      }
    });
    this.pendingCameraReleases.set(dev.id, tracked);
    return tracked;
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
    this.liveCameraMode = null;
    if (this.activeLiveCameraId) {
      const stopPayload = this.buildStopBridgePayload(this.activeLiveCameraId);
      this.cameraBridgeBindings.delete(this.activeLiveCameraId);
      invokeTauriVoid("stop_xiaomi_camera_bridge", stopPayload);
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
      rawMedia.addEventListener("loadedmetadata", () => {
        if (this.liveCameraRawMediaEl === rawMedia) this.applyRotationToLiveMedia();
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
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    try {
      const endpoint = await invoke<{ origin: string }>("go2rtc_endpoint");
      this.ownedStreamOrigin = this.ownedGo2rtcOrigin(endpoint.origin) ? endpoint.origin : null;
    } catch {
      this.ownedStreamOrigin = null;
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
    await this.refreshOwnedGo2rtcOrigin();
    if (this.liveCameraToken !== token || this.activeLiveCameraId !== devId) return;
    const normalized = this.normalizeWindowsCameraStreamUrl(playable);
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
    if (!/\/api\/camera_proxy/i.test(url) && /\.(mp4|webm|ogv|ogg|mov)(\?|$|#)/i.test(url)) {
      return false;
    }
    return /^https?:\/\//i.test(url);
  }

  public async bridgeHlsStreamToMjpeg(did: string, hlsUrl: string): Promise<boolean> {
    if (!window.__TAURI_INTERNALS__?.invoke) return false;
    const token = this.liveCameraToken;
    this.liveCameraLoading = true;
    this.host.render();
    try {
      if (this.host.settings.connectionMode === "homeAssistant") {
        await this.host.endpointSubmission;
        if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) return false;
      }
      const mjpegName = await window.__TAURI_INTERNALS__.invoke<string>("bridge_hls_camera_stream", {
        did,
        hlsUrl,
      });
      if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) return false;
      if (mjpegName) {
        this.liveCameraStreamURL = mjpegName;
        this.liveCameraError = null;
        this.liveCameraLoading = false;
        this.startMjpegTransport(mjpegName);
        this.host.render();
        this.attachLiveMedia();
        return true;
      }
      this.liveCameraLoading = false;
      this.host.render();
    } catch (err) {
      if (this.liveCameraToken === token && this.activeLiveCameraId === did) {
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
      this.liveCameraLocalIpError = cameraTr(
        "请输入有效的局域网私有 IPv4 地址（192.168.x.x / 172.16-31.x.x / 10.x.x.x）",
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

  public reconnectCameraLiveView(): void {
    const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
    if (!dev || dev.kind.kind !== "camera") return;
    if (this.host.settings.connectionMode === "xiaomiCloud") {
      this.reconnectingP2PSessionId = this.p2pSessionKeyForDevice(dev);
    }
    this.stopLiveTransport();
    this.liveCameraQualityApplies = true;
    this.liveCameraStreamURL = this.cameraStreamURLs[dev.id]
      ? this.normalizeWindowsCameraStreamUrl(this.cameraStreamURLs[dev.id]!)
      : this.resolveHaCameraStreamUrl(dev);
    this.liveCameraError = null;
    this.liveCameraLoading = false;
    if (this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
      void this.bridgeHlsStreamToMjpeg(dev.id, this.liveCameraStreamURL);
    } else if (!this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    }
    this.host.render();
  }

  public async resolveCloudCameraStream(dev: SmartDevice): Promise<void> {
    if (dev.kind.kind !== "camera" || !this.host.settings.miSession) return;
    if (CameraHubCatalog.isHub(dev.model)) {
      this.liveCameraQualityApplies = false;
      this.liveCameraNeedsManualIp = false;
      this.liveCameraLoading = false;
      this.liveCameraError = cameraTr(
        "室内网关本身不提供画面，请打开其配对的室外摄像机观看",
        "The indoor gateway has no camera feed of its own; open its paired battery camera instead",
      );
      this.host.render();
      return;
    }

    const channel = this.selectedCameraChannel(dev);
    const requiresHub = CameraHubCatalog.hubModel(dev.model) !== null;
    this.liveCameraLoading = true;
    this.liveCameraNeedsManualIp = false;
    this.host.render();
    // Closing/hiding bumps liveCameraToken via stopLiveTransport or full teardown;
    // a negotiation that outlives its modal must not start a bridge afterwards.
    const token = this.liveCameraToken;
    const stale = () => this.liveCameraToken !== token || this.activeLiveCameraId !== dev.id;
    let startedP2PSession = false;
    let failureReason: string | null = null;
    const releaseIfStarted = () => {
      if (startedP2PSession) {
        startedP2PSession = false;
        void this.releaseCameraP2PSession(dev, token, true);
      }
    };
    try {
      const pendingRelease = this.pendingCameraReleases.get(dev.id);
      if (pendingRelease) {
        await pendingRelease;
        if (stale()) return;
      }
      const spec = await this.host.specResolver.resolve({
        did: dev.id,
        name: dev.name,
        model: dev.model,
        isOnline: dev.isOnline,
        specType: null,
      });
      if (stale()) return;
      const client = new MiCloudClient(this.host.settings.miSession, this.host.transport);

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
          if (stale()) return;
          try {
            const res = await client.callAction({
              did: dev.id,
              siid: streamSvc.iid,
              aiid: act.iid,
              inputs,
            });
            if (stale()) return;
            const rawJson = JSON.stringify(res ?? {});
            const urlMatch = /https?:\/\/[^\s"'\\]+/i.exec(rawJson);
            if (urlMatch?.[0]) {
              const playable = this.normalizeWindowsCameraStreamUrl(urlMatch[0]);
              if (this.needsHlsTranscodeBridge(playable)) {
                this.liveCameraQualityApplies = false;
                const bridged = await this.bridgeHlsStreamToMjpeg(dev.id, playable);
                if (stale()) return;
                if (bridged) {
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
                this.host.render();
                return;
              }
            }
          } catch {
            if (stale()) return;
            // Cloud HLS rejected (bad inputs / 403 / offline): fall back to P2P.
          }
        }
      }

      if (stale()) return;
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
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
        if (stale()) return;
        // Re-negotiating the SAME camera's single P2P session needs a cooldown so the firmware
        // finishes freeing the slot; switching to a different camera (distinct P2P session) skips it.
        if (released && needsSameSessionCooldown && this.cameraSameSessionCooldownMs > 0) {
          await new Promise((resolve) => setTimeout(resolve, this.cameraSameSessionCooldownMs));
          if (stale()) return;
        }
      }
      if (stale()) return;
      if (p2pSvc && p2pAct) {
        startedP2PSession = await client
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: p2pAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
        if (startedP2PSession) {
          this.recentP2PSessionActivityMs.set(sessionKey, Date.now());
        }
      }
      if (stale()) {
        if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
        return;
      }

      // 3. Negotiate MISS CS2/TUTK P2P keys & start native Tauri bridge
      if (window.__TAURI_INTERNALS__?.invoke) {
        const target = await resolveLiveCameraTarget(
          client,
          dev,
          this.host.devices,
          this.host.settings.selectedHomeId,
        );
        if (stale()) {
          if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
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

            const vendorRes = (await client.request("v2/device/miss_get_vendor", {
              did: bridgeDid,
              app_pubkey: clientPublic,
              support_vendors: "TUTK_CS2_MTP",
            })) as Record<string, unknown> | null;
            if (stale()) {
              if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
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
                if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
                return;
              }
              this.liveCameraQualityApplies = true;
              const bridge = await window.__TAURI_INTERNALS__.invoke<string>("start_xiaomi_camera_bridge", {
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
              });
              if (stale()) {
                // The close path already tore down once; this late start re-created a
                // relay and stream registrations that nothing else will reclaim. Undo
                // them — unless the same camera was re-opened, in which case the new
                // negotiation's own stop_bridge replaces them and must not be killed.
                if (this.activeLiveCameraId !== dev.id) {
                  invokeTauriVoid("stop_xiaomi_camera_bridge", {
                    did: bridgeDid,
                    ...(channel > 0 ? { channel } : {}),
                    ...(subdid ? { subdid } : {}),
                  });
                  releaseIfStarted();
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
      releaseIfStarted();
      if (!stale()) {
        this.liveCameraQualityApplies = false;
        this.liveCameraError = err instanceof Error ? err.message : String(err);
      }
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
    this.stopLiveTransport();
    const token = this.liveCameraToken;
    await this.refreshOwnedGo2rtcOrigin();
    const stillViewing = this.liveCameraToken === token && this.activeLiveCameraId === id;
    if (val) this.cameraStreamURLs[id] = val;
    else delete this.cameraStreamURLs[id];
    this.host.settings.cameraStreamURLs = { ...this.cameraStreamURLs };
    this.host.saveSettings();
    if (!stillViewing) return;
    if (val) {
      const playable = this.normalizeWindowsCameraStreamUrl(val);
      this.liveCameraStreamURL = playable;
      this.liveCameraError = null;
      this.liveCameraLoading = false;
      const dev = this.host.devices.find((d) => d.id === id);
      const ownedSrc = this.ownedGo2rtcStreamName(playable);
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn && ownedSrc) {
        this.liveCameraStreamURL = ownedSrc;
        this.startMjpegTransport(ownedSrc);
      } else if (dev && dev.kind.kind === "camera" && dev.kind.isOn && this.needsHlsTranscodeBridge(playable)) {
        void this.bridgeHlsStreamToMjpeg(id, playable);
      }
    } else {
      const dev = this.host.devices.find((d) => d.id === id);
      this.liveCameraStreamURL = dev ? this.resolveHaCameraStreamUrl(dev) : null;
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn) {
        if (this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
          void this.bridgeHlsStreamToMjpeg(id, this.liveCameraStreamURL);
        } else if (!this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
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
      const redact = (raw: string) =>
        raw
          .replace(/https?:\/\/[^\s"'<>]+/gi, "<redacted-url>")
          .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "<redacted-ip>")
          .replace(/\b[0-9a-fA-F]{24,}\b/g, "<redacted-token>");
      const report = [
        "MenuBarHome Camera Diagnostics (Windows)",
        `model: ${dev.model}`,
        `online: ${dev.isOnline}`,
        `isOn: ${dev.kind.isOn}`,
        `connectionMode: ${this.host.settings.connectionMode}`,
        `hasCustomURL: ${Boolean(this.cameraStreamURLs[dev.id])}`,
        `hasManualIP: ${Boolean(this.cameraLocalIPs[dev.id])}`,
        `channel: ${this.selectedCameraChannel(dev)}`,
        `error: ${redact(this.liveCameraError ?? "none")}`,
      ].join("\n");
      void navigator.clipboard?.writeText(report).catch(() => {});
      this.host.replyBanner = { text: t("已复制脱敏诊断信息"), source: t("摄像机诊断") };
      this.host.render();
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
      ? cameraTr("旋转画面 90°", "Rotate video 90°")
      : cameraTr(`旋转画面 90°（当前 ${rotation}°）`, `Rotate video 90° (currently ${rotation}°)`);
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
