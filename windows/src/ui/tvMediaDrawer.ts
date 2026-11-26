import { t } from "../core/i18n.js";
import {
  extrapolatedPosition,
  formatMediaTime,
  isTvRemoteKey,
  MediaSeekGuard,
  playbackHasContent,
  progressStyle,
} from "../core/mediaPlayback.js";
import type { DeviceCommand, MediaPlaybackState, SmartDevice, TvRemoteKey, TvSpec } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";

const ICON = {
  play: `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M6.5 3.9a.9.9 0 011.36-.77l8.4 5.1a.9.9 0 010 1.54l-8.4 5.1a.9.9 0 01-1.36-.77V3.9z"/></svg>`,
  pause: `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><rect x="5" y="3.5" width="3.5" height="13" rx="1"/><rect x="11.5" y="3.5" width="3.5" height="13" rx="1"/></svg>`,
  previous: `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M10 5.2a.7.7 0 00-1.1-.58L3.3 9.42a.7.7 0 000 1.16l5.6 4.8a.7.7 0 001.1-.58V5.2zm7 0a.7.7 0 00-1.1-.58l-5.6 4.8a.7.7 0 000 1.16l5.6 4.8a.7.7 0 001.1-.58V5.2z"/></svg>`,
  next: `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M10 5.2a.7.7 0 011.1-.58l5.6 4.8a.7.7 0 010 1.16l-5.6 4.8a.7.7 0 01-1.1-.58V5.2zm-7 0a.7.7 0 011.1-.58l5.6 4.8a.7.7 0 010 1.16l-5.6 4.8A.7.7 0 013 14.8V5.2z"/></svg>`,
  back: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7.5 5L4 8.5 7.5 12"/><path d="M4.5 8.5h7a4 4 0 010 8H9"/></svg>`,
  menu: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="M4 6h12M4 10h12M4 14h12"/></svg>`,
  plus: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M10 4.5v11M4.5 10h11"/></svg>`,
  minus: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M4.5 10h11"/></svg>`,
  tv: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><rect x="2.5" y="4" width="15" height="10" rx="1.6"/><path d="M7 17h6" stroke-linecap="round"/></svg>`,
} as const;

const seekGuards = new Map<string, MediaSeekGuard>();
const expandedPads = new Set<string>();

function guardFor(deviceId: string): MediaSeekGuard {
  let guard = seekGuards.get(deviceId);
  if (!guard) {
    guard = new MediaSeekGuard();
    seekGuards.set(deviceId, guard);
  }
  return guard;
}

export function tvDrawerHasMedia(k: TvSpec): boolean {
  return (k.playback ? playbackHasContent(k.playback) : false) || k.supportsRemotePad === true;
}

function remoteKeyAvailable(k: TvSpec, key: TvRemoteKey): boolean {
  return Boolean(k.remoteEntityId) || Boolean(k.miotRemoteActions?.[key]);
}

function renderNowPlaying(dev: SmartDevice, p: MediaPlaybackState, escapeHtml: (value: string) => string): string {
  const id = escapeHtml(dev.id);
  const playing = p.state === "playing";
  const title = p.title ?? p.appName ?? t("正在播放");
  const style = progressStyle(p);
  const duration = p.durationSec ?? 0;
  const position = guardFor(dev.id).displayedPosition(extrapolatedPosition(p, Date.now()), Date.now()) ?? 0;
  const transport = [
    p.canSkipTrack ? `<button class="cc-tv-transport" data-tvmedia="${id}|previous" aria-label="${t("上一个")}" title="${t("上一个")}">${ICON.previous}</button>` : "",
    p.canPlayPause ? `<button class="cc-tv-transport is-primary" data-tvmedia="${id}|playPause" aria-label="${playing ? t("暂停") : t("播放")}" title="${playing ? t("暂停") : t("播放")}">${playing ? ICON.pause : ICON.play}</button>` : "",
    p.canSkipTrack ? `<button class="cc-tv-transport" data-tvmedia="${id}|next" aria-label="${t("下一个")}" title="${t("下一个")}">${ICON.next}</button>` : "",
  ].join("");
  const subtitle = p.subtitle ? `<span class="cc-tv-np-sub">${escapeHtml(p.subtitle)}</span>` : "";
  const app = p.appName && p.title ? `<span class="cc-tv-np-app">${escapeHtml(p.appName)}</span>` : "";
  const fraction = duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0;
  const progress = style === "hidden"
    ? ""
    : `<div class="cc-tv-progress ${style === "seekable" ? "is-seekable" : "is-readonly"}" data-tv-progress="${id}">
        ${style === "seekable"
          ? `<input type="range" class="cc-tv-seek" data-tvseek="${id}" min="0" max="${duration}" step="any" value="${position}" style="--tv-progress:${(fraction * 100).toFixed(3)}%" aria-label="${t("播放进度")}" aria-valuetext="${formatMediaTime(position)} / ${formatMediaTime(duration)}">`
          : `<div class="cc-tv-track" role="progressbar" aria-label="${t("播放进度")}" aria-valuemin="0" aria-valuemax="${Math.round(duration)}" aria-valuenow="${Math.round(position)}"><div class="cc-tv-fill" style="width:${(fraction * 100).toFixed(3)}%"></div></div>`}
        <div class="cc-tv-times"><span data-tv-elapsed>${formatMediaTime(position)}</span><span data-tv-remaining>-${formatMediaTime(Math.max(0, duration - position))}</span></div>
      </div>`;
  return `<div class="cc-tv-nowplaying">
      <div class="cc-tv-np-row">
        <div class="cc-tv-artwork" aria-hidden="true">${ICON.tv}</div>
        <div class="cc-tv-np-text">
          <span class="cc-tv-np-title" title="${escapeHtml(title)}">${escapeHtml(title)}</span>
          <span class="cc-tv-np-meta">${subtitle}${app}</span>
        </div>
        <div class="cc-tv-transport-row">${transport}</div>
      </div>
      ${progress}
    </div>`;
}

function renderRemotePad(dev: SmartDevice, k: TvSpec, escapeHtml: (value: string) => string): string {
  const id = escapeHtml(dev.id);
  const open = expandedPads.has(dev.id);
  const key = (name: TvRemoteKey, cls: string, label: string, icon: string): string =>
    `<button class="${cls}" data-tvremote="${id}|${name}" aria-label="${label}" title="${label}"${remoteKeyAvailable(k, name) ? "" : " disabled"}>${icon}</button>`;
  return `<div class="cc-tv-remote ${open ? "is-open" : ""}">
      <button class="cc-tv-remote-toggle" data-tvremote-toggle="${id}" aria-expanded="${open}">
        <span>${t("遥控器")}</span>${SF_ICONS.chevronRight}
      </button>
      ${open ? `<div class="cc-tv-remote-body">
        <div class="cc-tv-dpad">
          ${key("up", "cc-tv-dpad-key is-up", t("上"), SF_ICONS.chevronUp)}
          ${key("left", "cc-tv-dpad-key is-left", t("左"), SF_ICONS.chevronLeft)}
          ${key("select", "cc-tv-dpad-ok", t("确认"), "OK")}
          ${key("right", "cc-tv-dpad-key is-right", t("右"), SF_ICONS.chevronRight)}
          ${key("down", "cc-tv-dpad-key is-down", t("下"), SF_ICONS.chevronDown)}
        </div>
        <div class="cc-tv-remote-col">
          ${key("back", "cc-seg-pill cc-tv-side-key", t("返回"), ICON.back)}
          ${key("home", "cc-seg-pill cc-tv-side-key", t("主页"), SF_ICONS.houseFill)}
          ${key("menu", "cc-seg-pill cc-tv-side-key", t("菜单"), ICON.menu)}
        </div>
        <div class="cc-tv-remote-col">
          ${key("volumeUp", "cc-seg-pill cc-tv-side-key", t("音量加"), ICON.plus)}
          ${key("mute", "cc-seg-pill cc-tv-side-key", t("静音"), SF_ICONS.speakerSlash)}
          ${key("volumeDown", "cc-seg-pill cc-tv-side-key", t("音量减"), ICON.minus)}
        </div>
      </div>` : ""}
    </div>`;
}

/** Empty when the TV reports neither Now Playing nor a remote, so existing drawers are unchanged. */
export function renderTvMediaSection(dev: SmartDevice, k: TvSpec, escapeHtml: (value: string) => string): string {
  const parts: string[] = [];
  if (k.playback && playbackHasContent(k.playback)) parts.push(renderNowPlaying(dev, k.playback, escapeHtml));
  if (k.supportsRemotePad) parts.push(renderRemotePad(dev, k, escapeHtml));
  return parts.join("");
}

function liveTv(host: MenuMijiaWindowsApp, deviceId: string): { dev: SmartDevice; k: TvSpec } | null {
  const dev = host.devices.find((d) => d.id === deviceId);
  if (!dev || !dev.isOnline || dev.kind.kind !== "tv") return null;
  return { dev, k: dev.kind };
}

function splitPair(raw: string | undefined): [string, string] | null {
  if (!raw) return null;
  const at = raw.lastIndexOf("|");
  return at > 0 ? [raw.slice(0, at), raw.slice(at + 1)] : null;
}

function updateProgressElement(host: MenuMijiaWindowsApp, el: HTMLElement, now: number): boolean {
  const live = el.dataset.tvProgress ? liveTv(host, el.dataset.tvProgress) : null;
  const p = live?.k.playback;
  if (!live || !p || !p.durationSec) return false;
  const guard = guardFor(live.dev.id);
  const position = guard.displayedPosition(extrapolatedPosition(p, now), now) ?? 0;
  const fraction = Math.min(1, Math.max(0, position / p.durationSec));
  const seek = el.querySelector<HTMLInputElement>("input.cc-tv-seek");
  if (seek && !guard.isDragging) {
    seek.value = String(position);
    seek.style.setProperty("--tv-progress", `${(fraction * 100).toFixed(3)}%`);
    seek.setAttribute("aria-valuetext", `${formatMediaTime(position)} / ${formatMediaTime(p.durationSec)}`);
  }
  const fill = el.querySelector<HTMLElement>(".cc-tv-fill");
  if (fill) fill.style.width = `${(fraction * 100).toFixed(3)}%`;
  const elapsed = el.querySelector<HTMLElement>("[data-tv-elapsed]");
  const remaining = el.querySelector<HTMLElement>("[data-tv-remaining]");
  if (elapsed) elapsed.textContent = formatMediaTime(position);
  if (remaining) remaining.textContent = `-${formatMediaTime(Math.max(0, p.durationSec - position))}`;
  return p.state === "playing" || guard.pendingTargetSec !== null;
}

const tickers = new WeakMap<MenuMijiaWindowsApp, number>();

/** Ticks only while a bar is on screen, the window is visible and something is moving (#208). */
function ensureProgressTicker(host: MenuMijiaWindowsApp): void {
  if (tickers.has(host)) return;
  const tick = (): void => {
    const bars = host.root.querySelectorAll<HTMLElement>("[data-tv-progress]");
    let moving = false;
    if (document.visibilityState === "visible") {
      const now = Date.now();
      bars.forEach((el) => { if (updateProgressElement(host, el, now)) moving = true; });
    }
    if (!moving) {
      window.clearInterval(tickers.get(host));
      tickers.delete(host);
    }
  };
  tickers.set(host, window.setInterval(tick, 250));
}

function send(host: MenuMijiaWindowsApp, dev: SmartDevice, command: DeviceCommand, summary: string): void {
  void host.executeSingleCommand(dev, command, summary);
}

export function bindTvMediaEvents(host: MenuMijiaWindowsApp): void {
  host.root.querySelectorAll<HTMLButtonElement>("[data-tvmedia]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const pair = splitPair(btn.dataset.tvmedia);
      const live = pair ? liveTv(host, pair[0]) : null;
      const p = live?.k.playback;
      if (!pair || !live || !p) return;
      const entityId = live.k.mediaEntityId;
      if (pair[1] === "playPause" && p.canPlayPause) {
        send(host, live.dev, { kind: "mediaPlayPause", entityId }, t("已切换{name}播放状态", { name: live.dev.name }));
      } else if (pair[1] === "next" && p.canSkipTrack) {
        send(host, live.dev, { kind: "mediaNextTrack", entityId }, t("{name}已切到下一个", { name: live.dev.name }));
      } else if (pair[1] === "previous" && p.canSkipTrack) {
        send(host, live.dev, { kind: "mediaPreviousTrack", entityId }, t("{name}已切到上一个", { name: live.dev.name }));
      }
    });
  });

  host.root.querySelectorAll<HTMLInputElement>("input[data-tvseek]").forEach((slider) => {
    const deviceId = slider.dataset.tvseek ?? "";
    const guard = guardFor(deviceId);
    const preview = (): void => {
      const value = Number(slider.value);
      if (!Number.isFinite(value)) return;
      if (guard.isDragging) guard.updateDrag(value);
      else guard.beginDrag(value);
      const max = Number(slider.max) || 1;
      slider.style.setProperty("--tv-progress", `${((value / max) * 100).toFixed(3)}%`);
      const wrap = slider.closest<HTMLElement>("[data-tv-progress]");
      const elapsed = wrap?.querySelector<HTMLElement>("[data-tv-elapsed]");
      const remaining = wrap?.querySelector<HTMLElement>("[data-tv-remaining]");
      if (elapsed) elapsed.textContent = formatMediaTime(value);
      if (remaining) remaining.textContent = `-${formatMediaTime(Math.max(0, max - value))}`;
    };
    slider.addEventListener("pointerdown", (e) => {
      e.stopPropagation();
      host.pointerIsDown = true;
      guard.beginDrag(Number(slider.value));
    });
    slider.addEventListener("click", (e) => e.stopPropagation());
    // Dragging only previews; the network sees one seek on release.
    slider.addEventListener("input", preview);
    slider.addEventListener("change", () => {
      host.pointerIsDown = false;
      const target = guard.endDrag(Date.now());
      const live = liveTv(host, deviceId);
      const p = live?.k.playback;
      if (target === null || !live || !p || !p.canSeek || !p.durationSec) return;
      const positionSec = Math.min(Math.max(target, 0), p.durationSec);
      send(host, live.dev, { kind: "mediaSeek", entityId: live.k.mediaEntityId, positionSec },
        t("已将{name}跳转到 {time}", { name: live.dev.name, time: formatMediaTime(positionSec) }));
      ensureProgressTicker(host);
    });
  });

  host.root.querySelectorAll<HTMLButtonElement>("[data-tvremote-toggle]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.tvremoteToggle ?? "";
      if (expandedPads.has(id)) expandedPads.delete(id);
      else expandedPads.add(id);
      host.render?.();
    });
  });

  host.root.querySelectorAll<HTMLButtonElement>("[data-tvremote]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const pair = splitPair(btn.dataset.tvremote);
      const live = pair ? liveTv(host, pair[0]) : null;
      if (!pair || !live || !live.k.supportsRemotePad || !isTvRemoteKey(pair[1])) return;
      const key = pair[1];
      const entityId = live.k.miotRemoteActions?.[key] ?? live.k.remoteEntityId ?? null;
      if (!entityId) return;
      send(host, live.dev, { kind: "remoteSendKey", entityId, key }, t("已向{name}发送遥控按键", { name: live.dev.name }));
    });
  });

  if (host.root.querySelector("[data-tv-progress]")) ensureProgressTicker(host);
}
