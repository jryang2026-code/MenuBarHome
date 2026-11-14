import { t } from "../core/i18n.js";
import {
  CAMERA_STREAM_QUALITIES,
  DEFAULT_CAMERA_STREAM_QUALITY,
} from "../core/cameraQuality.js";
import { CameraHubCatalog, cameraTr } from "../core/miCloud/cameraHubs.js";
import { cameraLensLabel } from "../core/miCloud/cameraLens.js";
import { localizeNightShot } from "../core/models.js";
import { CAMERA_QUALITY_TITLES, SF_ICONS } from "./appConstants.js";
import type { CameraLiveController } from "./cameraLive.js";
import { tr3 } from "./undoTracker.js";

export function computeQuarterTurnScale(
  el: HTMLImageElement | HTMLVideoElement,
  stage: HTMLElement | null,
): number {
  const elW = el.clientWidth;
  const elH = el.clientHeight;
  const stageW = stage?.clientWidth ?? 0;
  const stageH = stage?.clientHeight ?? 0;
  if (elW > 0 && elH > 0) {
    const boxW = stageW > 0 ? stageW : elW;
    const boxH = stageH > 0 ? stageH : elH;
    return Number(Math.min(boxW / elH, boxH / elW).toFixed(4));
  }
  const intrinsicW =
    el.tagName === "VIDEO" ? (el as HTMLVideoElement).videoWidth : (el as HTMLImageElement).naturalWidth;
  const intrinsicH =
    el.tagName === "VIDEO" ? (el as HTMLVideoElement).videoHeight : (el as HTMLImageElement).naturalHeight;
  if (intrinsicW > 0 && intrinsicH > 0) {
    return Number(Math.min(intrinsicW / intrinsicH, intrinsicH / intrinsicW).toFixed(4));
  }
  return 0.5625;
}

export function renderCameraLiveModalView(ctrl: CameraLiveController): string {
  const dev = ctrl.host.devices.find((d) => d.id === ctrl.activeLiveCameraId);
  if (!dev || dev.kind.kind !== "camera") return "";
  const k = dev.kind;
  const id = ctrl.host.escapeHtml(dev.id);
  const customURL = ctrl.cameraStreamURLs[dev.id] ?? "";
  const savedManualIp = ctrl.cameraLocalIPs[dev.id] ?? "";
  const isNight = k.nightShot?.toLowerCase() === "on";
  const motionOn = Boolean(k.isMotionDetectionOn);
  const rotation = ctrl.cameraRotation(dev.id);
  const playableCameras = ctrl.host.devices.filter(
    (item) => item.kind.kind === "camera" && (item.id === dev.id || !CameraHubCatalog.isHub(item.model)),
  );

  let viewportHtml = "";
  let mediaKind: "sleeping" | "frames" | "image" | "loading" | "video" | "demo" | "error";
  if (!k.isOn) {
    mediaKind = "sleeping";
  } else if (ctrl.liveCameraMode) {
    mediaKind = "frames";
  } else if (ctrl.liveCameraLoading) {
    mediaKind = "loading";
  } else if (ctrl.liveCameraStreamURL && ctrl.isOwnedGo2rtcApiUrl(ctrl.liveCameraStreamURL)) {
    mediaKind = "loading";
  } else if (ctrl.liveCameraStreamURL && /^https?:/i.test(ctrl.liveCameraStreamURL)) {
    mediaKind = /\.(jpg|jpeg|png)|snapshot|camera_proxy|frame\.jpeg|mjpeg/i.test(ctrl.liveCameraStreamURL)
      ? "image"
      : "video";
  } else if (ctrl.host.settings.connectionMode === "demo") {
    mediaKind = "demo";
  } else {
    mediaKind = "error";
  }
  if (mediaKind === "sleeping") {
    const canWake = k.powerWritable !== false;
    viewportHtml = `
      <div class="cc-camera-stage is-sleeping">
        <strong>${t("摄像机处于物理休眠状态")}</strong>
        ${
          canWake
            ? `<p>${t("镜头已遮蔽，点击下方唤醒后即可查看实时画面")}</p>
        <button class="cc-btn-primary" data-toggle-device="${id}">${t("唤醒镜头并观看")}</button>`
            : ""
        }
      </div>
    `;
  } else if (mediaKind === "frames") {
    viewportHtml = `<div class="cc-camera-stage" id="cc-camera-stage"></div>`;
  } else if (mediaKind === "image") {
    const safeURL = ctrl.host.escapeHtml(ctrl.liveCameraStreamURL ?? "");
    const source = ctrl.liveCameraRawMediaEl ? "" : ` src="${safeURL}"`;
    viewportHtml = `<div class="cc-camera-stage"><img id="cc-camera-live-img"${source} alt="${ctrl.host.escapeHtml(dev.name)}" style="max-width:100%;border-radius:10px;" /></div>`;
  } else if (mediaKind === "loading") {
    viewportHtml = `
      <div class="cc-camera-stage" style="padding:28px 16px;text-align:center;">
        <strong>${t("正在握手并连接摄像机实时画面…")}</strong>
      </div>
    `;
  } else if (mediaKind === "video") {
    const safeURL = ctrl.host.escapeHtml(ctrl.liveCameraStreamURL ?? "");
    const source = ctrl.liveCameraRawMediaEl ? "" : ` src="${safeURL}"`;
    viewportHtml = `<div class="cc-camera-stage"><video id="cc-camera-video"${source} controls autoplay${ctrl.liveCameraMuted ? " muted" : ""} playsinline preload="auto" style="width:100%;border-radius:10px;background:#090d16;"></video></div>`;
  } else if (mediaKind === "demo") {
    viewportHtml = `
      <div class="cc-camera-stage is-demo" style="padding:18px;border-radius:12px;background:${isNight ? "linear-gradient(135deg,#072219,#03110c)" : "linear-gradient(135deg,#10233d,#091224)"};color:#fff;text-align:center;">
        <div style="display:flex;justify-content:space-between;width:100%;gap:12px;font-size:11px;opacity:0.85;margin-bottom:16px;">
          <span>● ${isNight ? "LIVE · IR NIGHT 2K" : "LIVE · 2K HDR · 25fps"}</span>
          <span>${ctrl.host.escapeHtml(dev.roomName)}</span>
        </div>
        <div style="padding:20px 8px;">
          <div style="width:36px;height:36px;margin:0 auto 10px;color:${isNight ? "#4ade80" : "#38bdf8"};">${SF_ICONS.videoFill}</div>
          <strong style="display:block;font-size:14px;margin-bottom:4px;">${ctrl.host.escapeHtml(dev.name)} · ${t("实时看护小窗预览")}</strong>
          <small style="opacity:0.76;">${motionOn ? t("AI 移动与看护侦测中 · 画面正常") : t("实时画面流已就绪 · 窗口已置顶")}</small>
        </div>
      </div>
    `;
  } else {
    const showManualIpFallback =
      ctrl.host.settings.connectionMode === "xiaomiCloud" &&
      !customURL &&
      (ctrl.liveCameraNeedsManualIp || Boolean(savedManualIp) || Boolean(ctrl.liveCameraLocalIpError));
    const ipDraft = ctrl.liveCameraDraftIp ?? savedManualIp;
    viewportHtml = `
      <div class="cc-camera-stage is-error" style="padding:16px;text-align:center;">
        <p style="margin-bottom:10px;">${ctrl.host.escapeHtml(ctrl.liveCameraError ?? t("可配置本地 go2rtc / HLS 流地址观看实时画面"))}</p>
        <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;">
          <button class="cc-btn-secondary" data-toggle-camera-url="1">${t("填写 go2rtc / HLS 流地址")}</button>
          <button class="cc-btn-secondary" id="btn-copy-camera-diag">${t("复制诊断")}</button>
        </div>
        ${
          showManualIpFallback
            ? `<div class="cc-camera-ip-box">
                <label for="camera-local-ip-input">${cameraTr("手动填写局域网 IP（云端未返回时备用）", "Manual LAN IP fallback")}</label>
                <div class="cc-camera-ip-row">
                  <input id="camera-local-ip-input" class="cc-input" type="text" value="${ctrl.host.escapeHtml(ipDraft)}" placeholder="192.168.1.50" />
                  <button type="button" class="cc-btn-primary" id="btn-save-camera-ip">${cameraTr("保存 IP", "Save IP")}</button>
                  ${
                    savedManualIp
                      ? `<button type="button" class="cc-btn-secondary" id="btn-clear-camera-ip">${cameraTr("清除 IP", "Clear IP")}</button>`
                      : ""
                  }
                </div>
                ${
                  ctrl.liveCameraLocalIpError
                    ? `<small class="cc-camera-ip-error" role="alert">${ctrl.host.escapeHtml(ctrl.liveCameraLocalIpError)}</small>`
                    : ""
                }
              </div>`
            : ""
        }
      </div>
    `;
  }

  const muteLabel = t(ctrl.liveCameraMuted ? "开启声音" : "关闭声音");
  const videoOnlyReason =
    mediaKind === "frames"
      ? ctrl.liveCameraStreamURL?.startsWith("mbh_hls_")
        ? {
            code: "hls-mjpeg",
            tip: tr3(
              "当前 HLS 流由本地桥接转码为 MJPEG 实时帧输出，仅传画面不含音轨",
              "目前 HLS 串流由本機橋接轉碼為 MJPEG 即時影格輸出，僅傳畫面不含音訊",
              "Current HLS stream is transcoded locally to MJPEG frames (video only, no audio track)",
            ),
          }
        : {
            code: "p2p-mjpeg",
            tip: tr3(
              "当前米家 P2P / 本地 MJPEG 桥接仅传输实时画面帧，不含音频流",
              "目前米家 P2P / 本機 MJPEG 橋接僅傳輸即時畫面影格，不含音訊串流",
              "Current Mi Home P2P / local MJPEG bridge delivers live video frames only (no audio track)",
            ),
          }
      : mediaKind === "image"
        ? {
            code: "snapshot",
            tip: tr3(
              "当前地址为静态抓拍或 MJPEG 图像流，仅含画面不含音轨",
              "目前位址為靜態抓拍或 MJPEG 影像串流，僅含畫面不含音訊",
              "Current source is a snapshot or MJPEG image stream (video only, no audio track)",
            ),
          }
        : mediaKind === "demo"
          ? {
              code: "demo",
              tip: tr3(
                "当前为演示预览画面，连接真实音视频流后可开启声音",
                "目前為展示預覽畫面，連線真實影音串流後可開啟聲音",
                "Demo preview has no audio; connect a live AV stream to enable sound",
              ),
            }
          : null;
  const audioControl =
    mediaKind === "video"
      ? `<button type="button" class="cc-seg-pill ${!ctrl.liveCameraMuted ? "is-active" : ""}" id="cc-camera-mute" data-camera-audio="toggle" title="${ctrl.host.escapeHtml(muteLabel)}" aria-label="${ctrl.host.escapeHtml(muteLabel)}" aria-pressed="${ctrl.liveCameraMuted}" style="display:inline-flex;align-items:center;gap:4px;"><span data-camera-mute-icon style="width:13px;height:13px;display:inline-flex;align-items:center;justify-content:center;">${ctrl.liveCameraMuted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave}</span><span data-camera-mute-text>${ctrl.host.escapeHtml(muteLabel)}</span></button>`
      : videoOnlyReason
        ? `<span class="cc-pill-label" id="cc-camera-audio-badge" data-video-only-reason="${videoOnlyReason.code}" title="${ctrl.host.escapeHtml(videoOnlyReason.tip)}" aria-label="${ctrl.host.escapeHtml(`${t("仅画面")} · ${videoOnlyReason.tip}`)}" style="cursor:help;">${t("仅画面")}</span>`
        : "";

  const rotateLabel = ctrl.rotateButtonTitle(rotation);
  const activeLensChannel = ctrl.selectedCameraChannel(dev);
  const hasDualLenses =
    ctrl.host.settings.connectionMode === "xiaomiCloud" && !customURL && (k.lenses?.length ?? 0) > 1;

  return `
    <div class="cc-sheet-backdrop" ${ctrl.liveCameraHidden ? 'style="display:none"' : ""}>
      <div class="cc-sheet cc-camera-live-sheet" role="dialog" aria-modal="true" tabindex="-1" aria-label="${ctrl.host.escapeHtml(dev.name)} ${t("实时画面")}">
        <div class="cc-sheet-header">
          <strong>${ctrl.host.escapeHtml(dev.name)} · ${t("实时画面小窗")}</strong>
          <div style="display:flex;gap:6px;align-items:center;">
            ${audioControl}
            <button type="button" class="cc-circle-btn is-small cc-rotate-btn ${rotation !== 0 ? "is-active" : ""}" id="btn-rotate-camera-live" data-rotation="${rotation}" title="${ctrl.host.escapeHtml(rotateLabel)}" aria-label="${ctrl.host.escapeHtml(rotateLabel)}" aria-pressed="${rotation !== 0}">90°</button>
            <button class="cc-circle-btn is-small" id="btn-reload-camera-live" title="${t("重新连接")}" aria-label="${t("重新连接")}">${SF_ICONS.arrowClockwise}</button>
            <button class="cc-circle-btn is-small" id="btn-toggle-camera-url" title="${t("配置流地址")}" aria-label="${t("配置流地址")}">${SF_ICONS.link}</button>
            <button class="cc-circle-btn is-small" id="btn-close-camera-live" title="${t("关闭画面")}" aria-label="${t("关闭画面")}">
              ${SF_ICONS.xmark}
            </button>
          </div>
        </div>
        ${
          playableCameras.length >= 2
            ? `<div class="cc-camera-switcher" role="tablist" aria-label="${cameraTr("切换摄像机", "Switch camera")}">
                ${playableCameras
                  .map((cam) => {
                    const selected = cam.id === dev.id;
                    const camId = ctrl.host.escapeHtml(cam.id);
                    const dotClass =
                      cam.isOnline && cam.kind.kind === "camera" && cam.kind.isOn ? "is-online" : "is-muted";
                    return `<button type="button" role="tab" class="cc-seg-pill cc-camera-switch-pill ${selected ? "is-active" : ""}" data-cameraswitch="${camId}" aria-selected="${selected}" title="${ctrl.host.escapeHtml(`${cam.roomName} · ${cam.name}`)}">
                      <span class="cc-camera-switch-dot ${dotClass}"></span>
                      <span class="cc-camera-switch-name">${ctrl.host.escapeHtml(cam.name)}</span>
                    </button>`;
                  })
                  .join("")}
              </div>`
            : ""
        }
        ${
          ctrl.liveCameraShowingURLInput
            ? `<div class="cc-field" style="margin-bottom:10px;">
                <input id="camera-stream-url-input" class="cc-input" type="text" value="${ctrl.host.escapeHtml(customURL)}" placeholder="http://127.0.0.1:<port>/api/stream.m3u8?src=camera" />
                <div style="display:flex;gap:6px;margin-top:6px;">
                  <button class="cc-btn-primary" id="btn-save-camera-url">${t("连接流地址")}</button>
                </div>
              </div>`
            : ""
        }
        ${viewportHtml}
        ${
          hasDualLenses
            ? `<div class="cc-segmented-pills cc-camera-lens-pills" style="margin-top:10px;">
                <span class="cc-pill-label">${cameraTr("镜头", "Lens")}</span>
                ${k.lenses!
                  .map((lens) => {
                    const selected = activeLensChannel === lens.channel;
                    return `<button type="button" class="cc-seg-pill ${selected ? "is-active" : ""}" data-cameralens="${id}" data-cameralens-channel="${lens.channel}" aria-pressed="${selected}">
                      ${ctrl.host.escapeHtml(cameraLensLabel(lens))}
                    </button>`;
                  })
                  .join("")}
              </div>`
            : ""
        }
        ${
          ctrl.host.settings.connectionMode === "xiaomiCloud" && !customURL && ctrl.liveCameraQualityApplies && !ctrl.liveCameraLoading
            ? `<div class="cc-segmented-pills" style="margin-top:10px;">
                <span class="cc-pill-label">${t("画质")}</span>
                ${CAMERA_STREAM_QUALITIES.map((quality) => {
                  const selected = (ctrl.cameraStreamQualities[dev.id] ?? DEFAULT_CAMERA_STREAM_QUALITY) === quality;
                  return `<button class="cc-seg-pill ${selected ? "is-active" : ""}" data-cameraquality="${id}" data-cameraquality-value="${quality}" aria-pressed="${selected}">
                    ${t(CAMERA_QUALITY_TITLES[quality])}
                  </button>`;
                }).join("")}
                ${
                  mediaKind !== "error" && savedManualIp
                    ? `<button type="button" class="cc-seg-pill" id="btn-clear-camera-ip" title="${cameraTr("清除手动局域网 IP", "Clear manual LAN IP")}">
                        IP ${ctrl.host.escapeHtml(savedManualIp)} ×
                      </button>`
                    : ""
                }
              </div>`
            : ""
        }
        <div class="cc-segmented-pills" style="margin-top:12px;">
          ${k.powerWritable === false ? "" : `<button class="cc-seg-pill ${!k.isOn ? "is-active" : ""}" data-toggle-device="${id}" aria-pressed="${!k.isOn}">
            ${k.isOn ? t("镜头休眠") : t("唤醒镜头")}
          </button>`}
          ${
            k.motionDetectionEntityId
              ? `<button class="cc-seg-pill ${motionOn ? "is-active" : ""}" data-cameramotion="${id}" aria-pressed="${motionOn}">
                  ${motionOn ? t("移动侦测：开") : t("移动侦测：关")}
                </button>`
              : ""
          }
          ${k.availableNightShots
            .map(
              (mode) => `<button class="cc-seg-pill ${k.nightShot === mode ? "is-active" : ""}" data-cameranight="${id}:${ctrl.host.escapeHtml(mode)}" aria-pressed="${k.nightShot === mode}">
                ${ctrl.host.escapeHtml(localizeNightShot(mode))}
              </button>`
            )
            .join("")}
        </div>
      </div>
    </div>
  `;
}
