import {
  CAMERA_STREAM_QUALITIES,
  type CameraStreamQuality,
} from "../core/cameraQuality.js";
import type { CameraPipAction, CameraPipSnapshot } from "../core/cameraPip.js";
import { t } from "../core/i18n.js";
import { cameraLensLabel } from "../core/miCloud/cameraLens.js";
import { localizeNightShot } from "../core/models.js";
import { CAMERA_QUALITY_TITLES, SF_ICONS } from "./appConstants.js";
import { computeQuarterTurnScale } from "./cameraLiveModalView.js";
import { waitForCameraFrameGap } from "./dom.js";
import { invokeTauriVoid } from "./transport.js";
import { tr3 } from "./undoTracker.js";

const PIP_ACTIVE_FRAME_GAP_MS = 45;
const PIP_IDLE_FRAME_GAP_MS = 250;
const PIP_MAX_IDLE_FRAME_GAP_MS = 500;
const PIP_RETRY_GAP_MS = 800;

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function nextFrameGapMs(isNewFrame: boolean, unchangedCount: number, elapsedMs: number): number {
  if (!isNewFrame) {
    const step = Math.max(0, unchangedCount - 1) * 75;
    return Math.min(PIP_MAX_IDLE_FRAME_GAP_MS, PIP_IDLE_FRAME_GAP_MS + step);
  }
  if (elapsedMs <= PIP_ACTIVE_FRAME_GAP_MS) {
    return Math.max(12, Math.round(PIP_ACTIVE_FRAME_GAP_MS - elapsedMs));
  }
  return Math.min(PIP_IDLE_FRAME_GAP_MS, Math.max(12, Math.round(elapsedMs * 0.35)));
}

/**
 * Standalone always-on-top PiP window UI (`window.__MENUMIJIA_WINDOW_MODE__ === "camera-pip"`).
 * Renders state snapshots pushed from the main window and pumps `go2rtc_jpeg_frame` directly
 * into a persistent `<img>` without duplicating app polling or session state.
 */
export class CameraPipWindowApp {
  private snapshot: CameraPipSnapshot | null = null;
  private activeMjpegSrc: string | null = null;
  private pumpAbort: AbortController | null = null;
  private imgEl: HTMLImageElement | null = null;
  private reportedFirstFrameForSrc: string | null = null;
  private showingWatchConfig = false;
  private readonly disposers: Array<() => void> = [];

  constructor(private readonly root: HTMLElement) {
    const doc = root.ownerDocument;
    const win = doc?.defaultView;
    doc?.documentElement?.classList.add("is-camera-pip-window");

    if (win) {
      const onState = (event: Event) => {
        const detail = (event as CustomEvent<string>).detail;
        this.applyRawSnapshot(detail);
      };
      const onKeyDown = (event: KeyboardEvent) => {
        if (event.key === "Escape") {
          event.preventDefault();
          this.sendAction({ type: "close" });
        }
      };
      win.addEventListener("menumijia:camera-pip-state", onState);
      win.addEventListener("keydown", onKeyDown, true);
      this.disposers.push(() => {
        win.removeEventListener("menumijia:camera-pip-state", onState);
        win.removeEventListener("keydown", onKeyDown, true);
      });
    }

    this.render();
    void this.hydrateInitialSnapshot();
  }

  public dispose(): void {
    this.stopPump();
    for (const stop of this.disposers.splice(0)) stop();
  }

  private async hydrateInitialSnapshot(): Promise<void> {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    try {
      const raw = await invoke<string | null>("get_camera_pip_state");
      if (raw) this.applyRawSnapshot(raw);
    } catch {
      // Ignore if main has not published state yet.
    }
  }

  public applyRawSnapshot(raw: string): void {
    try {
      const parsed = JSON.parse(raw) as CameraPipSnapshot;
      if (!parsed || typeof parsed.cameraId !== "string") return;
      this.applySnapshot(parsed);
    } catch {
      // Ignore malformed payloads.
    }
  }

  public applySnapshot(next: CameraPipSnapshot): void {
    this.snapshot = next;
    this.syncMjpegPump(next);
    this.render();
    this.attachPersistentMedia();
  }

  private sendAction(action: CameraPipAction): void {
    invokeTauriVoid("camera_pip_action", { actionJson: JSON.stringify(action) });
  }

  private stopPump(): void {
    this.pumpAbort?.abort();
    this.pumpAbort = null;
    this.activeMjpegSrc = null;
  }

  private syncMjpegPump(snap: CameraPipSnapshot): void {
    const targetSrc = snap.mediaKind === "frames" && snap.mjpegSrc ? snap.mjpegSrc : null;
    if (!targetSrc) {
      this.stopPump();
      return;
    }
    if (this.activeMjpegSrc === targetSrc && this.pumpAbort && !this.pumpAbort.signal.aborted) {
      return;
    }
    this.stopPump();
    this.activeMjpegSrc = targetSrc;
    this.reportedFirstFrameForSrc = null;
    const doc = this.root.ownerDocument ?? document;
    const img = this.imgEl ?? doc.createElement("img");
    img.id = "cc-camera-live-img";
    img.alt = snap.name;
    img.addEventListener("load", () => this.applyRotation());
    this.imgEl = img;
    const abort = new AbortController();
    this.pumpAbort = abort;
    void this.pumpFrames(targetSrc, snap.cameraId, img, abort.signal);
  }

  private async pumpFrames(
    src: string,
    cameraId: string,
    img: HTMLImageElement,
    signal: AbortSignal,
  ): Promise<void> {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    let lastJpeg = "";
    let unchangedCount = 0;
    while (!signal.aborted && this.activeMjpegSrc === src) {
      let isNewFrame = false;
      let elapsedMs = 0;
      try {
        const startedAt = performance.now();
        const jpeg = await invoke<string>("go2rtc_jpeg_frame", { src });
        elapsedMs = Math.max(0, performance.now() - startedAt);
        if (signal.aborted || this.activeMjpegSrc !== src) return;
        if (jpeg) {
          isNewFrame = jpeg !== lastJpeg;
          if (isNewFrame) {
            unchangedCount = 0;
            img.src = `data:image/jpeg;base64,${jpeg}`;
            lastJpeg = jpeg;
            if (this.reportedFirstFrameForSrc !== src) {
              this.reportedFirstFrameForSrc = src;
              this.sendAction({ type: "frameCaptured", cameraId, jpegBase64: jpeg });
            }
          } else {
            unchangedCount += 1;
          }
        }
      } catch {
        if (signal.aborted || this.activeMjpegSrc !== src) return;
        await waitForCameraFrameGap(signal, PIP_RETRY_GAP_MS);
        continue;
      }
      await waitForCameraFrameGap(signal, nextFrameGapMs(isNewFrame, unchangedCount, elapsedMs));
    }
  }

  private attachPersistentMedia(): void {
    const snap = this.snapshot;
    if (!snap) return;
    if (snap.mediaKind === "frames" && this.imgEl) {
      const stage = this.root.querySelector<HTMLElement>("#cc-camera-stage");
      if (stage && this.imgEl.parentElement !== stage) {
        stage.replaceChildren(this.imgEl);
      }
    }
    this.applyRotation();
  }

  private applyRotation(): void {
    const snap = this.snapshot;
    if (!snap) return;
    const media = this.root.querySelector<HTMLImageElement | HTMLVideoElement>(
      "#cc-camera-live-img, #cc-camera-video",
    );
    if (!media) return;
    const stage = this.root.querySelector<HTMLElement>(".cc-camera-stage");
    const deg = snap.rotation;
    if (deg === 0) {
      media.style.transform = "";
      return;
    }
    if (deg === 180) {
      media.style.transform = "rotate(180deg)";
      return;
    }
    const scale = computeQuarterTurnScale(media, stage);
    media.style.transform = `rotate(${deg}deg) scale(${scale})`;
  }

  private render(): void {
    const snap = this.snapshot;
    if (!snap) {
      this.root.innerHTML = `
        <div class="cc-pip-shell">
          <div class="cc-sheet-header cc-pip-drag-handle">
            <strong>${t("实时画面小窗")}</strong>
            <button type="button" class="cc-circle-btn is-small" id="btn-close-camera-live" title="${t("关闭画面")}" aria-label="${t("关闭画面")}">${SF_ICONS.xmark}</button>
          </div>
          <div class="cc-camera-stage" style="padding:28px 16px;text-align:center;">
            <strong>${t("正在握手并连接摄像机实时画面…")}</strong>
          </div>
        </div>
      `;
      this.bindEvents();
      return;
    }

    const id = escapeHtml(snap.cameraId);
    const portraitClass = snap.isPortrait ? " is-portrait" : "";
    let viewportHtml = "";
    if (snap.mediaKind === "sleeping") {
      viewportHtml = `
        <div class="cc-camera-stage is-sleeping${portraitClass}">
          <strong>${t("摄像机处于物理休眠状态")}</strong>
          ${
            snap.powerWritable
              ? `<p>${t("镜头已遮蔽，点击下方唤醒后即可查看实时画面")}</p>
                 <button type="button" class="cc-btn-primary" data-pip-power="${id}">${t("唤醒镜头并观看")}</button>`
              : ""
          }
        </div>
      `;
    } else if (snap.mediaKind === "frames") {
      viewportHtml = `<div class="cc-camera-stage${portraitClass}" id="cc-camera-stage"></div>`;
    } else if (snap.mediaKind === "image") {
      viewportHtml = `<div class="cc-camera-stage${portraitClass}"><img id="cc-camera-live-img" src="${escapeHtml(snap.streamURL ?? "")}" alt="${escapeHtml(snap.name)}" /></div>`;
    } else if (snap.mediaKind === "loading") {
      viewportHtml = `
        <div class="cc-camera-stage${portraitClass}" style="padding:28px 16px;text-align:center;">
          <strong>${t("正在握手并连接摄像机实时画面…")}</strong>
        </div>
      `;
    } else if (snap.mediaKind === "video") {
      viewportHtml = `<div class="cc-camera-stage${portraitClass}"><video id="cc-camera-video" src="${escapeHtml(snap.streamURL ?? "")}" controls autoplay${snap.muted ? " muted" : ""} playsinline preload="auto"></video></div>`;
    } else if (snap.mediaKind === "demo") {
      viewportHtml = `
        <div class="cc-camera-stage is-demo${portraitClass}" style="padding:18px;background:${snap.isNight ? "linear-gradient(135deg,#072219,#03110c)" : "linear-gradient(135deg,#10233d,#091224)"};color:#fff;text-align:center;">
          <div style="display:flex;justify-content:space-between;width:100%;gap:12px;font-size:11px;opacity:0.85;margin-bottom:16px;">
            <span>● ${snap.isNight ? "LIVE · IR NIGHT 2K" : "LIVE · 2K HDR · 25fps"}</span>
            <span>${escapeHtml(snap.roomName)}</span>
          </div>
          <div style="padding:20px 8px;">
            <div style="width:36px;height:36px;margin:0 auto 10px;color:${snap.isNight ? "#4ade80" : "#38bdf8"};">${SF_ICONS.videoFill}</div>
            <strong style="display:block;font-size:14px;margin-bottom:4px;">${escapeHtml(snap.name)} · ${t("实时看护小窗预览")}</strong>
            <small style="opacity:0.76;">${snap.isMotionDetectionOn ? t("AI 移动与看护侦测中 · 画面正常") : t("实时画面流已就绪 · 窗口已置顶")}</small>
          </div>
        </div>
      `;
    } else {
      viewportHtml = `
        <div class="cc-camera-stage is-error${portraitClass}" style="padding:16px;text-align:center;">
          <p style="margin-bottom:10px;">${escapeHtml(snap.error ?? t("可配置本地 go2rtc / HLS 流地址观看实时画面"))}</p>
          <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;">
            <button type="button" class="cc-btn-secondary" data-pip-url-toggle="1">${t("填写 go2rtc / HLS 流地址")}</button>
            <button type="button" class="cc-btn-secondary" id="btn-copy-camera-diag">${t("复制诊断")}</button>
          </div>
          ${
            snap.showManualIpFallback
              ? `<div class="cc-camera-ip-box">
                  <label for="camera-local-ip-input">${tr3("手动填写局域网 IP（云端未返回时备用）", "手動填寫區域網 IP（雲端未傳回時備用）", "Manual LAN IP fallback")}</label>
                  <div class="cc-camera-ip-row">
                    <input id="camera-local-ip-input" class="cc-input" type="text" value="${escapeHtml(snap.draftManualIp)}" placeholder="192.168.1.50" />
                    <button type="button" class="cc-btn-primary" id="btn-save-camera-ip">${tr3("保存 IP", "儲存 IP", "Save IP")}</button>
                    ${snap.savedManualIp ? `<button type="button" class="cc-btn-secondary" id="btn-clear-camera-ip">${tr3("清除 IP", "清除 IP", "Clear IP")}</button>` : ""}
                  </div>
                  ${snap.manualIpError ? `<small class="cc-camera-ip-error" role="alert">${escapeHtml(snap.manualIpError)}</small>` : ""}
                </div>`
              : ""
          }
        </div>
      `;
    }

    const muteLabel = t(snap.muted ? "开启声音" : "关闭声音");
    const audioControl =
      snap.mediaKind === "video"
        ? `<button type="button" class="cc-seg-pill ${!snap.muted ? "is-active" : ""}" id="cc-camera-mute" aria-pressed="${snap.muted}">${escapeHtml(muteLabel)}</button>`
        : `<span class="cc-pill-label" id="cc-camera-audio-badge">${t("仅画面")}</span>`;

    const countdownBadge =
      typeof snap.autoCloseRemainingSeconds === "number" && snap.autoCloseRemainingSeconds > 0
        ? `<button type="button" class="cc-pip-countdown" id="btn-pip-cancel-countdown" title="${tr3("点击取消自动关闭并保持打开", "點擊取消自動關閉並保持開啟", "Click to cancel auto-close")}">${snap.autoCloseRemainingSeconds}s</button>`
        : "";
    const pinnedIdSet = new Set(snap.pinnedSwitches.map((sw) => sw.id));

    this.root.innerHTML = `
      <div class="cc-pip-shell${portraitClass}" role="dialog" aria-label="${escapeHtml(snap.name)} ${t("实时画面")}">
        <div class="cc-sheet-header cc-pip-drag-handle">
          <div style="display:flex;align-items:center;gap:6px;min-width:0;">
            <strong class="cc-pip-title">${escapeHtml(snap.name)}</strong>
            ${countdownBadge}
          </div>
          <div class="cc-pip-header-actions">
            ${audioControl}
            <button type="button" class="cc-circle-btn is-small cc-rotate-btn ${snap.rotation !== 0 ? "is-active" : ""}" id="btn-rotate-camera-live" data-rotation="${snap.rotation}" aria-pressed="${snap.rotation !== 0}">90°</button>
            <button type="button" class="cc-circle-btn is-small ${this.showingWatchConfig ? "is-active" : ""}" id="btn-pip-watch-config" title="${tr3("弹窗与关联开关设置", "彈窗與關聯開關設定", "Auto-open & pinned switches")}" aria-label="${tr3("弹窗与关联开关设置", "彈窗與關聯開關設定", "Auto-open & pinned switches")}" aria-pressed="${this.showingWatchConfig}">${SF_ICONS.sliderHorizontal}</button>
            <button type="button" class="cc-circle-btn is-small" id="btn-reload-camera-live" title="${t("重新连接")}" aria-label="${t("重新连接")}">${SF_ICONS.arrowClockwise}</button>
            <button type="button" class="cc-circle-btn is-small" id="btn-toggle-camera-url" title="${t("配置流地址")}" aria-label="${t("配置流地址")}">${SF_ICONS.link}</button>
            <button type="button" class="cc-circle-btn is-small" id="btn-close-camera-live" title="${t("关闭画面")}" aria-label="${t("关闭画面")}">${SF_ICONS.xmark}</button>
          </div>
        </div>
        ${
          this.showingWatchConfig
            ? `<div class="cc-pip-watch-config">
                <label class="cc-pip-config-row">
                  <input type="checkbox" id="chk-pip-auto-open" ${snap.autoOpenOnEvent ? "checked" : ""} />
                  <span>${tr3("门铃/告警时自动在右上角弹出小窗", "門鈴/告警時自動在右上角彈出小窗", "Auto-open at top-right on doorbell/alarm")}</span>
                </label>
                ${
                  snap.availablePinSwitches.length > 0
                    ? `<div class="cc-pip-pin-picker">
                        <span class="cc-pill-label">${tr3("钉选关联开关（最多 2 个）", "釘選關聯開關（最多 2 個）", "Pin switches (max 2)")}</span>
                        <div class="cc-segmented-pills">
                          ${snap.availablePinSwitches
                            .map(
                              (sw) => `<button type="button" class="cc-seg-pill ${pinnedIdSet.has(sw.id) ? "is-active" : ""}" data-pip-pin-select="${escapeHtml(sw.id)}" aria-pressed="${pinnedIdSet.has(sw.id)}">${escapeHtml(sw.name)}</button>`,
                            )
                            .join("")}
                        </div>
                      </div>`
                    : ""
                }
              </div>`
            : ""
        }
        ${
          snap.playableCameras.length >= 2
            ? `<div class="cc-camera-switcher" role="tablist" aria-label="${tr3("切换摄像机", "切換攝影機", "Switch camera")}">
                ${snap.playableCameras
                  .map(
                    (cam) => `<button type="button" role="tab" class="cc-seg-pill cc-camera-switch-pill ${cam.id === snap.cameraId ? "is-active" : ""}" data-cameraswitch="${escapeHtml(cam.id)}" aria-selected="${cam.id === snap.cameraId}">
                      <span class="cc-camera-switch-dot ${cam.isActiveOnline ? "is-online" : "is-muted"}"></span>
                      <span class="cc-camera-switch-name">${escapeHtml(cam.name)}</span>
                    </button>`,
                  )
                  .join("")}
              </div>`
            : ""
        }
        ${
          snap.showingURLInput
            ? `<div class="cc-field" style="margin-bottom:4px;">
                <input id="camera-stream-url-input" class="cc-input" type="text" value="${escapeHtml(snap.customURL)}" placeholder="http://192.168.1.10:1984/api/stream.m3u8?src=cam" />
                <div style="display:flex;gap:6px;margin-top:6px;">
                  <button type="button" class="cc-btn-primary" id="btn-save-camera-url">${t("连接流地址")}</button>
                </div>
              </div>`
            : ""
        }
        ${viewportHtml}
        ${
          snap.lenses.length > 1
            ? `<div class="cc-segmented-pills cc-camera-lens-pills">
                <span class="cc-pill-label">${tr3("镜头", "鏡頭", "Lens")}</span>
                ${snap.lenses
                  .map(
                    (lens) => `<button type="button" class="cc-seg-pill ${snap.activeLensChannel === lens.channel ? "is-active" : ""}" data-cameralens="${id}" data-cameralens-channel="${lens.channel}" aria-pressed="${snap.activeLensChannel === lens.channel}">${escapeHtml(cameraLensLabel(lens))}</button>`,
                  )
                  .join("")}
              </div>`
            : ""
        }
        ${
          snap.showQualityBar
            ? `<div class="cc-segmented-pills">
                <span class="cc-pill-label">${t("画质")}</span>
                ${CAMERA_STREAM_QUALITIES.map(
                  (q) => `<button type="button" class="cc-seg-pill ${snap.quality === q ? "is-active" : ""}" data-cameraquality="${id}" data-cameraquality-value="${q}" aria-pressed="${snap.quality === q}">${t(CAMERA_QUALITY_TITLES[q])}</button>`,
                ).join("")}
                ${
                  snap.mediaKind !== "error" && snap.savedManualIp
                    ? `<button type="button" class="cc-seg-pill" id="btn-clear-camera-ip">IP ${escapeHtml(snap.savedManualIp)} ×</button>`
                    : ""
                }
              </div>`
            : ""
        }
        ${
          snap.pinnedSwitches.length > 0
            ? `<div class="cc-segmented-pills cc-pip-pinned-switches">
                ${snap.pinnedSwitches
                  .map(
                    (sw) => `<button type="button" class="cc-seg-pill ${sw.isOn ? "is-active" : ""}" data-pip-pinned-switch="${escapeHtml(sw.id)}" aria-pressed="${sw.isOn}" ${sw.isOnline ? "" : "disabled"}>${escapeHtml(sw.name)}</button>`,
                  )
                  .join("")}
              </div>`
            : ""
        }
        <div class="cc-segmented-pills cc-pip-footer">
          ${snap.powerWritable ? `<button type="button" class="cc-seg-pill ${!snap.isOn ? "is-active" : ""}" data-pip-power="${id}" aria-pressed="${!snap.isOn}">${snap.isOn ? t("镜头休眠") : t("唤醒镜头")}</button>` : ""}
          ${snap.motionDetectionEntityId ? `<button type="button" class="cc-seg-pill ${snap.isMotionDetectionOn ? "is-active" : ""}" data-pip-motion="${id}" aria-pressed="${snap.isMotionDetectionOn}">${snap.isMotionDetectionOn ? t("移动侦测：开") : t("移动侦测：关")}</button>` : ""}
          ${snap.availableNightShots
            .map(
              (mode) => `<button type="button" class="cc-seg-pill ${snap.nightShot === mode ? "is-active" : ""}" data-pip-night="${id}:${escapeHtml(mode)}" aria-pressed="${snap.nightShot === mode}">${escapeHtml(localizeNightShot(mode))}</button>`,
            )
            .join("")}
        </div>
      </div>
    `;
    this.bindEvents();
  }

  private bindEvents(): void {
    this.root.querySelector<HTMLElement>(".cc-pip-shell")?.addEventListener("mousedown", () => {
      if (this.snapshot?.autoCloseRemainingSeconds != null) {
        this.sendAction({ type: "interact" });
      }
    });
    this.root.querySelector("#btn-pip-cancel-countdown")?.addEventListener("click", () => {
      this.sendAction({ type: "interact" });
    });
    this.root.querySelector("#btn-pip-watch-config")?.addEventListener("click", () => {
      this.showingWatchConfig = !this.showingWatchConfig;
      this.render();
      this.attachPersistentMedia();
    });
    this.root.querySelector<HTMLInputElement>("#chk-pip-auto-open")?.addEventListener("change", (event) => {
      const checked = (event.target as HTMLInputElement).checked;
      this.sendAction({ type: "setAutoOpen", enabled: checked });
    });
    this.root.querySelectorAll<HTMLElement>("[data-pip-pin-select]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.pipPinSelect ?? "";
        if (deviceId) this.sendAction({ type: "togglePinSelection", deviceId });
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-pip-pinned-switch]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.pipPinnedSwitch ?? "";
        if (deviceId) this.sendAction({ type: "togglePinnedSwitch", deviceId });
      });
    });
    this.root.querySelector<HTMLElement>(".cc-pip-drag-handle")?.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest("button, input, a, select")) return;
      invokeTauriVoid("start_camera_pip_drag");
    });
    this.root.querySelector("#btn-close-camera-live")?.addEventListener("click", () => {
      this.sendAction({ type: "close" });
    });
    this.root.querySelector("#btn-reload-camera-live")?.addEventListener("click", () => {
      this.sendAction({ type: "reload" });
    });
    this.root.querySelector("#btn-rotate-camera-live")?.addEventListener("click", () => {
      this.sendAction({ type: "rotate" });
    });
    this.root.querySelector("#cc-camera-mute")?.addEventListener("click", () => {
      this.sendAction({ type: "toggleMute" });
    });
    this.root.querySelectorAll<HTMLElement>("#btn-toggle-camera-url, [data-pip-url-toggle]").forEach((btn) => {
      btn.addEventListener("click", () => this.sendAction({ type: "toggleUrlInput" }));
    });
    this.root.querySelector("#btn-save-camera-url")?.addEventListener("click", () => {
      const input = this.root.querySelector<HTMLInputElement>("#camera-stream-url-input");
      this.sendAction({ type: "saveCustomUrl", url: input?.value.trim() ?? "" });
    });
    this.root.querySelector("#btn-save-camera-ip")?.addEventListener("click", () => {
      const input = this.root.querySelector<HTMLInputElement>("#camera-local-ip-input");
      this.sendAction({ type: "saveManualIp", ip: input?.value.trim() ?? "" });
    });
    this.root.querySelector("#btn-clear-camera-ip")?.addEventListener("click", () => {
      this.sendAction({ type: "clearManualIp" });
    });
    this.root.querySelector("#btn-copy-camera-diag")?.addEventListener("click", () => {
      this.sendAction({ type: "copyDiag" });
    });
    this.root.querySelectorAll<HTMLElement>("[data-cameraswitch]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameraswitch ?? "";
        if (deviceId) this.sendAction({ type: "switchCamera", deviceId });
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-cameralens]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameralens ?? "";
        const channel = Number(btn.dataset.cameralensChannel ?? "0");
        if (deviceId && Number.isFinite(channel)) {
          this.sendAction({ type: "setLens", deviceId, channel });
        }
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-cameraquality]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameraquality ?? "";
        const quality = btn.dataset.cameraqualityValue as CameraStreamQuality | undefined;
        if (deviceId && quality) this.sendAction({ type: "setQuality", deviceId, quality });
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-pip-power]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.pipPower ?? "";
        if (deviceId) this.sendAction({ type: "togglePower", deviceId });
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-pip-motion]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.pipMotion ?? "";
        if (deviceId) this.sendAction({ type: "toggleMotion", deviceId });
      });
    });
    this.root.querySelectorAll<HTMLElement>("[data-pip-night]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.pipNight ?? "";
        const idx = raw.lastIndexOf(":");
        if (idx > 0) {
          this.sendAction({
            type: "setNightShot",
            deviceId: raw.slice(0, idx),
            mode: raw.slice(idx + 1),
          });
        }
      });
    });
  }
}
