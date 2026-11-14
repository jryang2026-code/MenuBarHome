import { haRoundedInt } from "../core/haDomains.js";
import { currentLanguage, resolveLanguage, t } from "../core/i18n.js";
import {
  lockedControlIdForAlert,
  showsAdvancedViewOnlyCopy,
} from "../core/miCloud/feedAction.js";
import {
  SPEAKER_TEXT_MAX_LENGTH,
  buildSpeakerTextCommand,
  normalizeSpeakerText,
  type SpeakerTextMode,
} from "../core/miCloud/speakerActions.js";
import { facetValue, formatReading } from "../core/miotFacetText.js";
import {
  applianceFaultNotice,
  applianceModeStartsHeating,
  localizeApplianceFanLevel,
  localizeApplianceMode,
  localizeApplianceStatus,
  localizeSwingMode,
  type ApplianceSpec,
  type ClimateSpec,
  type CoverSpec,
  type DeviceCommand,
  type DeviceIntent,
  type FacetControl,
  type GenericSpec,
  type PlugSpec,
  type SmartDevice,
  type SpeakerSpec,
} from "../core/models.js";
import { formatTemperature, toCelsius } from "../core/temperature.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
import {
  isLightEffectUnsupported,
  pruneUnsupportedLightEffectsOnHost,
} from "./commandDispatch.js";
import {
  facetRowDomId,
  resetMoreSettingsState,
  revealFacetRow,
  setSelectedPortionForControl,
  syncMoreSettingsHost,
  toggleMoreSettingsExpanded,
  toggleMoreSettingsRest,
} from "./facetViews.js";

const ALERT_TRIANGLE_SVG = `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M8.85 3.4c.51-.9 1.79-.9 2.3 0l6.4 11.3c.5.88-.14 1.97-1.15 1.97H3.6c-1.01 0-1.65-1.09-1.15-1.97l6.4-11.3zM10 7.25a.75.75 0 00-.75.75v3.5a.75.75 0 001.5 0V8a.75.75 0 00-.75-.75zm0 7.25a.85.85 0 100-1.7.85.85 0 000 1.7z"/></svg>`;
const LOCK_SHIELD_SVG = `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M10 2.2l6 2.3v4.7c0 4.2-2.55 7.95-6 9.3-3.45-1.35-6-5.1-6-9.3V4.5l6-2.3zm0 4.3a2 2 0 00-2 2v1h-.5a.75.75 0 00-.75.75v3c0 .41.34.75.75.75h5a.75.75 0 00.75-.75v-3a.75.75 0 00-.75-.75H12v-1a2 2 0 00-2-2zm-1 3v-1a1 1 0 112 0v1H9z"/></svg>`;

export type CoverMotorAction = "open" | "close" | "stop";

/** Mirrors macOS `CoverSpec.snappedPosition`: snap endpoints <3 -> 0 and >97 -> 100. */
export function snapCoverPosition(percent: number): number {
  const clamped = Math.max(0, Math.min(100, Math.round(percent)));
  if (clamped < 3) return 0;
  if (clamped > 97) return 100;
  return clamped;
}

/** Localized label for a cover motor action, mirroring `CoverDetailDrawer.actionTitle`. */
export function coverActionTitle(
  description: string,
  subtype: string | null | undefined,
): string {
  const trimmed = description.trim();
  const isAirer = subtype === "clothes-airer";
  switch (trimmed.toLowerCase()) {
    case "open":
    case "打开":
      return currentLanguage() === "en" ? "Open" : t("打开");
    case "close":
    case "关闭":
      return currentLanguage() === "en" ? "Close" : t("关闭");
    case "up":
    case "raise":
    case "上升":
    case "升起":
      return isAirer ? t("升") : t("升起");
    case "down":
    case "lower":
    case "下降":
    case "降下":
      return isAirer ? t("降") : t("降下");
    case "pause":
    case "stop":
    case "暂停":
    case "停止":
      return isAirer ? t("停") : t("暂停");
    default:
      return trimmed;
  }
}

/** Localized motion status inside the cover drawer, or `null` when stopped. */
export function coverMotionLabel(
  motion: CoverSpec["motion"],
  subtype: string | null | undefined,
): string | null {
  const isAirer = subtype === "clothes-airer";
  if (motion === "opening") return isAirer ? t("上升中") : t("正在打开");
  if (motion === "closing") return isAirer ? t("下降中") : t("正在关闭");
  return null;
}

/**
 * Enforces the 4 cover risk subtypes (`curtain` direct; `window-opener` / `clothes-airer` open
 * confirms; `garage-door` open & close confirm; unknown treated as `window-opener`; stop never asks).
 */
export function coverMotorRequiresConfirmation(
  subtype: string | null | undefined,
  action: CoverMotorAction,
): boolean {
  if (action === "stop") return false;
  if (subtype === "curtain") return false;
  if (
    subtype === "garage-door" ||
    subtype === "garage-or-gate" ||
    subtype === "garageOrGate"
  ) {
    return true;
  }
  return action === "open";
}

export function renderApplianceDrawer(
  dev: SmartDevice,
  k: ApplianceSpec,
  escapeHtml: (value: string) => string,
): string {
  const id = escapeHtml(dev.id);
  const disabledAttr = dev.isOnline ? "" : ' disabled aria-disabled="true"';
  const rows: string[] = [];

  if (k.faultText && k.faultText.trim() !== "") {
    const notice = applianceFaultNotice(k.faultText);
    rows.push(
      `<div class="cc-appliance-fault" role="status">` +
        `<span class="cc-icon-inline" aria-hidden="true">${ALERT_TRIANGLE_SVG}</span>` +
        `<span class="cc-appliance-fault-text">${escapeHtml(notice.message)}</span>` +
        `<button type="button" class="cc-inline-pill cc-appliance-fault-copy" data-copy-fault="${escapeHtml(notice.copyText)}">${escapeHtml(t("复制代码"))}</button>` +
      `</div>`,
    );
  }

  if (k.temperatureWritable && k.targetTemperature !== null) {
    rows.push(`<div class="cc-segmented-pills">
      <button class="cc-seg-pill" data-appliancetemp="${id}|-1" aria-label="${t("降低目标温度")}"${disabledAttr}>−</button>
      <span class="cc-pill-label">${formatTemperature(k.targetTemperature)}</span>
      <button class="cc-seg-pill" data-appliancetemp="${id}|1" aria-label="${t("升高目标温度")}"${disabledAttr}>＋</button>
    </div>`);
  }

  if (k.modeWritable && k.availableModes.length > 0) {
    if (k.availableModes.length > 4) {
      const activeMode =
        k.currentMode && k.availableModes.includes(k.currentMode) ? k.currentMode : null;
      rows.push(
        `<div class="cc-appliance-mode-row">` +
          `<span class="cc-pill-label">${escapeHtml(t("模式"))}</span>` +
          `<select class="cc-appliance-select" data-appliancemode-select="${id}" aria-label="${escapeHtml(t("模式"))}"${disabledAttr}>` +
            `${activeMode === null ? `<option value="" selected>${escapeHtml(t("未选择"))}</option>` : ""}` +
            `${k.availableModes
              .map(
                (mode) =>
                  `<option value="${escapeHtml(mode)}"${activeMode === mode ? " selected" : ""}>${escapeHtml(localizeApplianceMode(mode))}</option>`,
              )
              .join("")}` +
          `</select>` +
        `</div>`,
      );
    } else {
      rows.push(`<div class="cc-segmented-pills">
        ${k.availableModes
          .map(
            (mode) => `<button class="cc-seg-pill ${k.currentMode === mode ? "is-active" : ""}"
              data-appliancemode="${id}|${escapeHtml(mode)}" aria-pressed="${k.currentMode === mode}"${disabledAttr}>
              ${escapeHtml(localizeApplianceMode(mode))}
            </button>`,
          )
          .join("")}
      </div>`);
    }
  }

  if (k.fanLevel?.writable && k.fanLevel.options.length > 0) {
    rows.push(`<div class="cc-segmented-pills">
      ${k.fanLevel.options
        .map(
          (level) => `<button class="cc-seg-pill ${k.fanLevel?.current === level ? "is-active" : ""}"
            data-appliancefan="${id}|${escapeHtml(level)}" aria-pressed="${k.fanLevel?.current === level}"${disabledAttr}>
            ${escapeHtml(localizeApplianceFanLevel(level))}
          </button>`,
        )
        .join("")}
    </div>`);
  }

  if (k.light?.writable) {
    rows.push(`<div class="cc-segmented-pills">
      <button class="cc-seg-pill ${k.light.isOn ? "is-active" : ""}" data-appliancelight="${id}" aria-pressed="${k.light.isOn}"${disabledAttr}>
        ${k.light.isOn ? t("灯光：开") : t("灯光：关")}
      </button>
    </div>`);
  }

  const roundedHumidity = k.roomReading ? haRoundedInt(k.currentHumidity) : null;
  if (roundedHumidity !== null) {
    rows.push(`<div class="cc-slider-label"><span>${t("湿度")}</span><strong>${roundedHumidity}%</strong></div>`);
  }

  if (k.statusText) {
    rows.push(`<div class="cc-slider-label"><span>${t("状态")}</span><span>${escapeHtml(localizeApplianceStatus(k.statusText))}</span></div>`);
  }

  if (k.remainingMinutes !== null) {
    rows.push(`<div class="cc-slider-label"><span>${t("剩余时间")}</span><span>${t("{minutes} 分钟", { minutes: k.remainingMinutes })}</span></div>`);
  }

  const actions = (
    [
      ["start", k.startAction, t("开始")],
      ["pause", k.pauseAction, t("暂停")],
      ["stop", k.stopAction, t("停止")],
    ] as const
  ).filter(([, action]) => action !== null);
  if (actions.length > 0) {
    rows.push(`<div class="cc-segmented-pills">
      ${actions
        .map(
          ([kind, , label]) =>
            `<button class="cc-seg-pill" data-applianceaction="${id}|${kind}"${disabledAttr}>${label}</button>`,
        )
        .join("")}
    </div>`);
  }

  if (rows.length === 0) return "";
  return `<div class="cc-tile-drawer">${rows.join("")}</div>`;
}

async function writeFaultTextToClipboard(text: string): Promise<void> {
  const nav = typeof window !== "undefined" ? window.navigator : navigator;
  if (nav && nav.clipboard && typeof nav.clipboard.writeText === "function") {
    try {
      await nav.clipboard.writeText(text);
      return;
    } catch {}
  }
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  textarea.style.pointerEvents = "none";
  document.body.appendChild(textarea);
  try {
    textarea.select();
    if (typeof document.execCommand === "function") {
      document.execCommand("copy");
    }
  } finally {
    textarea.remove();
  }
}

export function renderCoverDrawer(
  dev: SmartDevice,
  k: CoverSpec,
  escapeHtml: (value: string) => string,
): string {
  const id = escapeHtml(dev.id);
  const disabledAttr = dev.isOnline ? "" : ' disabled aria-disabled="true"';
  const rows: string[] = [];

  const motion = coverMotionLabel(k.motion, k.subtype);
  if (motion) {
    rows.push(`<div class="cc-slider-label cc-cover-motion"><span>${escapeHtml(motion)}</span></div>`);
  }
  if (k.faultText && k.faultText.trim() !== "") {
    rows.push(`<div class="cc-appliance-fault">${escapeHtml(k.faultText)}</div>`);
  }
  if (k.positionWritable) {
    const pos = Math.max(0, Math.min(100, Math.round(k.positionPercent ?? 0)));
    const label = k.subtype === "clothes-airer" ? t("升降高度") : t("开合位置");
    rows.push(`<div class="cc-slider-group">
      <div class="cc-slider-label">
        <span>${label}</span>
        <strong>${pos}%</strong>
      </div>
      <input class="cc-range is-blue" type="range" min="0" max="100" step="1" value="${pos}"
        data-coverpos="${id}" aria-label="${label}" aria-valuemin="0" aria-valuemax="100"
        aria-valuenow="${pos}" aria-valuetext="${pos}%"${disabledAttr} />
    </div>`);
  }

  const motorButtons: string[] = [];
  if (k.openDescription) {
    const active = k.motion === "opening";
    motorButtons.push(
      `<button class="cc-seg-pill ${active ? "is-active" : ""}" data-covermotor="${id}|open|${escapeHtml(k.openDescription)}" aria-pressed="${active}"${disabledAttr}>${escapeHtml(coverActionTitle(k.openDescription, k.subtype))}</button>`,
    );
  }
  if (k.pauseDescription) {
    motorButtons.push(
      `<button class="cc-seg-pill" data-covermotor="${id}|stop|${escapeHtml(k.pauseDescription)}"${disabledAttr}>${escapeHtml(coverActionTitle(k.pauseDescription, k.subtype))}</button>`,
    );
  }
  if (k.closeDescription) {
    const active = k.motion === "closing";
    motorButtons.push(
      `<button class="cc-seg-pill ${active ? "is-active" : ""}" data-covermotor="${id}|close|${escapeHtml(k.closeDescription)}" aria-pressed="${active}"${disabledAttr}>${escapeHtml(coverActionTitle(k.closeDescription, k.subtype))}</button>`,
    );
  }

  if (motorButtons.length > 0 || k.batteryPercent !== null) {
    const battery =
      k.batteryPercent !== null
        ? `<span class="cc-cover-battery ${k.batteryPercent <= 20 ? "is-low" : ""}"><span class="cc-icon-inline" aria-hidden="true">${k.batteryPercent <= 20 ? SF_ICONS.batteryLow : SF_ICONS.batteryFull}</span> ${escapeHtml(t("电量 {percent}%", { percent: k.batteryPercent }))}</span>`
        : "";
    rows.push(`<div class="cc-cover-actions">
      ${motorButtons.length > 0 ? `<div class="cc-segmented-pills">${motorButtons.join("")}</div>` : ""}
      ${battery}
    </div>`);
  }

  if (rows.length === 0) return "";
  return `<div class="cc-tile-drawer">${rows.join("")}</div>`;
}

export function renderPlugDrawer(
  dev: SmartDevice,
  k: PlugSpec,
  escapeHtml: (value: string) => string,
): string {
  const id = escapeHtml(dev.id);
  const hasPower = k.powerWatts !== null && Number.isFinite(k.powerWatts);
  const hasEnergy =
    k.energyKwh !== undefined &&
    k.energyKwh !== null &&
    Number.isFinite(k.energyKwh) &&
    k.energyKwh >= 0;
  const rows: string[] = [];

  if (hasPower || hasEnergy) {
    const cells: string[] = [];
    if (hasPower) {
      const watts = Number.isInteger(k.powerWatts!)
        ? `${Math.round(k.powerWatts!)} W`
        : `${k.powerWatts!.toFixed(1)} W`;
      cells.push(`<div class="cc-plug-metric">
        <span class="cc-plug-metric-label">${t("实时功率")}</span>
        <strong class="cc-plug-metric-val">${watts}</strong>
      </div>`);
    }
    if (hasEnergy) {
      cells.push(`<div class="cc-plug-metric">
        <span class="cc-plug-metric-label">${t("累计电量")}</span>
        <strong class="cc-plug-metric-val">${k.energyKwh!.toFixed(2)} kWh</strong>
      </div>`);
    }
    rows.push(`<div class="cc-plug-metrics">${cells.join("")}</div>`);
  }

  if (k.childLockEntityId !== null) {
    const disabledAttr = dev.isOnline ? "" : ' disabled aria-disabled="true"';
    rows.push(`<div class="cc-segmented-pills">
      <button class="cc-seg-pill ${k.isChildLocked ? "is-active" : ""}" data-pluglock="${id}" aria-pressed="${k.isChildLocked}"${disabledAttr}>
        ${k.isChildLocked ? t("按键锁：开") : t("按键锁：关")}
      </button>
    </div>`);
  }

  if (rows.length === 0) return "";
  return `<div class="cc-tile-drawer">${rows.join("")}</div>`;
}

export function renderGenericDrawer(
  dev: SmartDevice,
  k: GenericSpec,
  facets: readonly FacetControl[],
  allowAdvanced: boolean,
  escapeHtml: (value: string) => string,
): string {
  const id = escapeHtml(dev.id);
  const rows: string[] = [];

  for (const alert of k.alerts ?? []) {
    const lockedId = lockedControlIdForAlert(alert, facets, allowAdvanced);
    const jumpTarget =
      lockedId !== null
        ? `${id}|${escapeHtml(lockedId)}`
        : facets.length > 0
          ? `${id}|`
          : null;
    rows.push(`<div class="cc-generic-alert" role="status">
      <span class="cc-icon-inline" aria-hidden="true">${ALERT_TRIANGLE_SVG}</span>
      <span class="cc-generic-alert-text">${escapeHtml(alert)}</span>
      ${
        jumpTarget !== null
          ? `<button class="cc-inline-pill" data-facet-reveal="${jumpTarget}">${t("去处理")}</button>`
          : ""
      }
    </div>`);
  }

  if (k.isReadOnly) {
    rows.push(`<div class="cc-generic-note">
      <span class="cc-icon-inline" aria-hidden="true">${LOCK_SHIELD_SVG}</span>
      <span>${t("该设备只向云端开放读数，不能从这里控制。")}</span>
    </div>`);
  } else if (k.powerControl === null && showsAdvancedViewOnlyCopy(facets, allowAdvanced)) {
    rows.push(`<div class="cc-generic-note">
      <span class="cc-icon-inline" aria-hidden="true">${LOCK_SHIELD_SVG}</span>
      <span>${t("为安全起见，这类设备默认只能查看。需要调整时，在下方「更多设置」里开启。")}</span>
    </div>`);
  }

  if (rows.length === 0) return "";
  return `<div class="cc-tile-drawer">${rows.join("")}</div>`;
}

export function renderClimateSwingRow(
  deviceId: string,
  k: ClimateSpec,
  escapeHtml: (value: string) => string,
): string {
  const modes = k.availableSwingModes ?? [];
  if (modes.length === 0) return "";
  const id = escapeHtml(deviceId);
  return `<div class="cc-segmented-pills">
    <span class="cc-pill-label">${t("摆风")}</span>
    ${modes
      .map(
        (mode) =>
          `<button class="cc-seg-pill ${k.swingMode === mode ? "is-active" : ""}" data-acswing="${id}:${escapeHtml(mode)}" aria-pressed="${k.swingMode === mode}">${escapeHtml(localizeSwingMode(mode))}</button>`,
      )
      .join("")}
  </div>`;
}

/**
 * Updates a drawer range slider's displayed value (`%`, `K`, `°C`/`°F`, or formatted facet text)
 * live during drag (`input`) without dispatching network writes (`change`).
 */
export function updateLiveSliderReadout(
  slider: HTMLInputElement,
  findControl: (deviceId: string, controlId: string) => FacetControl | null,
): void {
  const setGroupReadout = (formatted: string, ariaNow: string): void => {
    const label = slider.closest(".cc-slider-group")?.querySelector<HTMLElement>(".cc-slider-label strong");
    if (label) label.textContent = formatted;
    slider.setAttribute("aria-valuenow", ariaNow);
    slider.setAttribute("aria-valuetext", formatted);
  };

  if (slider.dataset.brightness !== undefined) {
    const pct = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
    setGroupReadout(`${pct}%`, String(pct));
    return;
  }
  if (slider.dataset.colortemp !== undefined) {
    const kelvin = Math.round(Number(slider.value));
    setGroupReadout(`${kelvin}K`, String(kelvin));
    return;
  }
  if (slider.dataset.actemp !== undefined) {
    const raw = Number(slider.value);
    let celsius = toCelsius(raw);
    const minC = slider.dataset.minC !== undefined ? Number(slider.dataset.minC) : NaN;
    const maxC = slider.dataset.maxC !== undefined ? Number(slider.dataset.maxC) : NaN;
    if (Number.isFinite(minC)) celsius = Math.max(minC, celsius);
    if (Number.isFinite(maxC)) celsius = Math.min(maxC, celsius);
    const formatted = formatTemperature(Number(celsius.toFixed(2)));
    setGroupReadout(formatted, slider.value);
    return;
  }
  if (slider.dataset.fanpercent !== undefined) {
    const pct = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
    setGroupReadout(`${pct}%`, String(pct));
    return;
  }
  if (slider.dataset.volume !== undefined) {
    const pct = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
    setGroupReadout(`${pct}%`, String(pct));
    return;
  }
  if (slider.dataset.coverpos !== undefined) {
    const pct = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
    setGroupReadout(`${pct}%`, String(pct));
    return;
  }
  const facetKey = slider.dataset.facetNumber;
  if (facetKey !== undefined) {
    const sep = facetKey.indexOf("|");
    const deviceId = sep > 0 ? facetKey.slice(0, sep) : "";
    const controlId = sep > 0 ? facetKey.slice(sep + 1) : "";
    const numeric = Number(slider.value);
    if (!Number.isFinite(numeric)) return;
    const control = deviceId && controlId ? findControl(deviceId, controlId) : null;
    const formatted = control
      ? facetValue({ ...control, value: numeric })
      : formatReading(numeric);
    const valueEl = slider.closest(".cc-facet-row")?.querySelector<HTMLElement>(".cc-facet-value");
    if (valueEl) valueEl.textContent = formatted;
    slider.setAttribute("aria-valuenow", formatReading(numeric));
    slider.setAttribute("aria-valuetext", formatted);
  }
}

const boundDrawerLifecycleHosts = new WeakSet<MenuMijiaWindowsApp>();

export function ensureDrawerLifecycleListeners(host: MenuMijiaWindowsApp): void {
  syncMoreSettingsHost(host);
  if (boundDrawerLifecycleHosts.has(host)) return;
  boundDrawerLifecycleHosts.add(host);
  const flushDeferredAfterRelease = (): void => {
    window.setTimeout(() => {
      if (!host.root.isConnected) return;
      if (!host.pointerIsDown && host.pendingCloudRender) {
        host.queueBackgroundRender();
      }
    }, 0);
  };
  window.addEventListener("pointerup", flushDeferredAfterRelease);
  window.addEventListener("pointercancel", flushDeferredAfterRelease);
  window.addEventListener("blur", () => {
    if (!host.root.isConnected) return;
    resetMoreSettingsState();
    flushDeferredAfterRelease();
  });
  document.addEventListener("visibilitychange", () => {
    if (!host.root.isConnected) return;
    if (document.visibilityState === "hidden") {
      resetMoreSettingsState();
    }
  });
}

export interface DetailDrawerBindCallbacks {
  readonly splitControlId: (raw: string | undefined) => [string, string] | null;
  readonly splitChoice: (raw: string | undefined) => [string, string, string] | null;
  readonly facetFor: (deviceId: string, controlId: string) => { dev: SmartDevice; control: FacetControl } | null;
  readonly confirmHighRisk: (deviceId: string, command: DeviceCommand, actionLabel: string) => boolean;
}

/**
 * Binds live slider drag readouts + gesture guard, cover / plug drawer controls, and MoreSettings
 * 2-stage folding / alert reveal / portion selection.
 */
export function bindDetailDrawerEvents(
  host: MenuMijiaWindowsApp,
  callbacks: DetailDrawerBindCallbacks,
): void {
  const { splitControlId, splitChoice, facetFor, confirmHighRisk } = callbacks;

  host.root
    .querySelectorAll<HTMLInputElement>(
      "input[type=\"range\"][data-brightness], input[type=\"range\"][data-colortemp], input[type=\"range\"][data-actemp], input[type=\"range\"][data-fanpercent], input[type=\"range\"][data-volume], input[type=\"range\"][data-coverpos], input[type=\"range\"][data-facet-number]",
    )
    .forEach((slider) => {
      slider.addEventListener("pointerdown", () => {
        host.pointerIsDown = true;
      });
      slider.addEventListener("input", () => {
        host.pointerIsDown = true;
        updateLiveSliderReadout(
          slider,
          (devId, ctrlId) => host.deviceFacets[devId]?.find((item) => item.id === ctrlId) ?? null,
        );
      });
      slider.addEventListener(
        "change",
        () => {
          host.pointerIsDown = false;
          queueMicrotask(() => {
            if (!host.pointerIsDown && host.pendingCloudRender) {
              host.queueBackgroundRender();
            }
          });
        },
        { capture: true },
      );
    });

  host.root.querySelectorAll<HTMLInputElement>("[data-coverpos]").forEach((slider) => {
    slider.addEventListener("change", () => {
      const id = slider.dataset.coverpos;
      if (!id) return;
      const dev = host.devices.find((d) => d.id === id);
      if (!dev || dev.kind.kind !== "cover" || !dev.kind.positionWritable || !dev.isOnline) return;
      const clamped = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
      const displayed = snapCoverPosition(clamped);
      const command: DeviceCommand = { kind: "setNumberValue", entityId: dev.kind.entityId, value: clamped };
      const summary = t("已将{name}位置设为 {percent}%", { name: dev.name, percent: displayed });
      void host.executeSingleCommand(dev, command, summary);
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-covermotor]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const choice = splitChoice(btn.dataset.covermotor);
      if (!choice) return;
      const [id, rawAction, description] = choice;
      if (rawAction !== "open" && rawAction !== "close" && rawAction !== "stop") return;
      const dev = host.devices.find((d) => d.id === id);
      if (!dev || dev.kind.kind !== "cover" || !dev.isOnline || !description) return;
      const command: DeviceCommand = {
        kind: "setSelectOption",
        entityId: dev.kind.entityId,
        option: description,
      };
      const actionLabel = coverActionTitle(description, dev.kind.subtype);
      if (
        coverMotorRequiresConfirmation(dev.kind.subtype, rawAction) &&
        !confirmHighRisk(dev.id, command, t("{action}{name}", { action: actionLabel, name: dev.name }))
      ) {
        return;
      }
      const intent: DeviceIntent | undefined =
        rawAction === "stop"
          ? undefined
          : { targetId: dev.id, operation: { kind: "power", isOn: rawAction === "open" } };
      const summary =
        rawAction === "stop"
          ? t("已暂停{name}", { name: dev.name })
          : rawAction === "open"
            ? t("已打开{name}", { name: dev.name })
            : t("已关闭{name}", { name: dev.name });
      void host.executeSingleCommand(dev, command, summary, intent);
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-pluglock]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.pluglock;
      if (!id) return;
      const dev = host.devices.find((d) => d.id === id);
      if (!dev || dev.kind.kind !== "plug" || !dev.kind.childLockEntityId || !dev.isOnline) return;
      const nextLocked = !dev.kind.isChildLocked;
      const command: DeviceCommand = {
        kind: "setSwitch",
        entityId: dev.kind.childLockEntityId,
        isOn: nextLocked,
      };
      void host.executeSingleCommand(
        dev,
        command,
        t("已{action}{name}按键锁", { action: nextLocked ? t("开启") : t("关闭"), name: dev.name }),
      );
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-more-settings-toggle]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.moreSettingsToggle;
      if (!id) return;
      toggleMoreSettingsExpanded(id);
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-more-settings-rest]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = btn.dataset.moreSettingsRest;
      if (!id) return;
      toggleMoreSettingsRest(id);
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-open-facet-settings]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      host.openSettingsSheet("system");
      host.root.querySelector<HTMLElement>("#settings-allow-advanced-facets")?.focus();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-facet-reveal]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const raw = btn.dataset.facetReveal ?? "";
      const sep = raw.indexOf("|");
      const deviceId = sep >= 0 ? raw.slice(0, sep) : raw;
      const controlId = sep >= 0 ? raw.slice(sep + 1) : "";
      if (!deviceId) return;
      revealFacetRow(deviceId, controlId, host.deviceFacets[deviceId] ?? []);
      host.render();
      const targetEl = controlId
        ? host.root.querySelector<HTMLElement>(`#${cssEscape(facetRowDomId(deviceId, controlId))}`)
        : host.root.querySelector<HTMLElement>(
            `[data-tile-id="${cssEscape(deviceId)}"] .cc-facet-section`,
          );
      targetEl?.scrollIntoView?.({ block: "nearest", behavior: "smooth" });
      const focusable =
        targetEl?.querySelector<HTMLElement>(
          "button:not([disabled]), input:not([disabled]), select:not([disabled])",
        ) ??
        host.root.querySelector<HTMLElement>(`[data-open-facet-settings="${cssEscape(deviceId)}"]`) ??
        host.root.querySelector<HTMLElement>(`[data-more-settings-toggle="${cssEscape(deviceId)}"]`);
      focusable?.focus({ preventScroll: true });
    });
  });

  host.root.querySelectorAll<HTMLSelectElement>("[data-facet-portion]").forEach((select) => {
    select.addEventListener("change", () => {
      const pair = splitControlId(select.dataset.facetPortion);
      if (!pair) return;
      const found = facetFor(pair[0], pair[1]);
      if (!found) return;
      setSelectedPortionForControl(pair[0], found.control, Number(select.value));
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLSelectElement>("[data-appliancemode-select]").forEach((select) => {
    select.addEventListener("change", () => {
      const id = select.dataset.appliancemodeSelect;
      const mode = select.value;
      if (!id || !mode) return;
      const dev = host.devices.find((d) => d.id === id);
      if (!dev || !dev.isOnline || dev.kind.kind !== "appliance" || !dev.kind.modeWritable) return;
      const command: DeviceCommand = { kind: "setSelectOption", entityId: dev.kind.modeEntityId, option: mode };
      if (
        dev.kind.heats &&
        !dev.kind.isOn &&
        applianceModeStartsHeating(mode) &&
        !confirmHighRisk(dev.id, command, t("切换到{mode}", { mode: localizeApplianceMode(mode) }))
      ) {
        if (select.isConnected) {
          select.value =
            dev.kind.currentMode && dev.kind.availableModes.includes(dev.kind.currentMode)
              ? dev.kind.currentMode
              : "";
        }
        return;
      }
      void host.executeSingleCommand(
        dev,
        command,
        t("已将{name}设为{mode}", { name: dev.name, mode: localizeApplianceMode(mode) }),
      );
    });
  });

  host.root.querySelectorAll<HTMLButtonElement>("[data-copy-fault]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const text = btn.dataset.copyFault ?? "";
      if (!text) return;
      void writeFaultTextToClipboard(text).then(() => {
        if (!btn.isConnected) return;
        btn.textContent = t("已复制");
        btn.dataset.copied = "true";
        window.setTimeout(() => {
          if (!btn.isConnected) return;
          btn.textContent = t("复制代码");
          delete btn.dataset.copied;
        }, 1500);
      });
    });
  });

  filterUnsupportedLightEffectPills(host);
  mountAndBindSpeakerCommandBars(host);
  bindCollapsedInlineSliders(host);
}

function bindCollapsedInlineSliders(host: MenuMijiaWindowsApp): void {
  host.root.querySelectorAll<HTMLElement>("[data-inline-slider-wrap]").forEach((wrap) => {
    wrap.addEventListener("pointerdown", (e) => {
      host.pointerIsDown = true;
      e.stopPropagation();
    });
    wrap.addEventListener("click", (e) => {
      e.stopPropagation();
    });
  });

  host.root
    .querySelectorAll<HTMLInputElement>('input[type="range"][data-inline-slider]')
    .forEach((slider) => {
      slider.addEventListener("pointerdown", () => {
        host.pointerIsDown = true;
      });
      slider.addEventListener("click", (e) => {
        e.stopPropagation();
      });
      slider.addEventListener("input", () => {
        host.pointerIsDown = true;
        const min = Number(slider.min || "0");
        const max = Number(slider.max || "100");
        const pct = Math.max(min, Math.min(max, Math.round(Number(slider.value))));
        slider.setAttribute("aria-valuenow", String(pct));
        slider.setAttribute("aria-valuetext", `${pct}%`);
        const wrap = slider.closest<HTMLElement>(".cc-inline-slider-wrap");
        const valEl = wrap?.querySelector<HTMLElement>(".cc-inline-slider-val");
        if (valEl) valEl.textContent = `${pct}%`;
        if (slider.dataset.inlineBrightness) {
          const tile = slider.closest<HTMLElement>("[data-tile-id]");
          const fillEl = tile?.querySelector<HTMLElement>(".cc-tile-fill");
          if (fillEl) fillEl.style.width = `${pct}%`;
        }
      });
      slider.addEventListener("change", () => {
        host.pointerIsDown = false;
        queueMicrotask(() => {
          if (!host.pointerIsDown && host.pendingCloudRender) {
            host.queueBackgroundRender();
          }
        });
        const id = slider.dataset.inlineSlider ?? "";
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || !dev.isOnline) return;
        if (
          slider.dataset.inlineBrightness &&
          dev.kind.kind === "light" &&
          dev.kind.brightnessWritable !== false
        ) {
          const percent = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
          void host.executeSingleCommand(
            dev,
            { kind: "setLightBrightness", entityId: dev.kind.entityId, percent },
            t("已将{name}亮度设为 {percent}%", { name: dev.name, percent }),
            { targetId: dev.id, operation: { kind: "brightness", percent } },
          );
          return;
        }
        if (slider.dataset.inlineCoverpos && dev.kind.kind === "cover" && dev.kind.positionWritable) {
          const clamped = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
          const displayed = snapCoverPosition(clamped);
          const command: DeviceCommand = {
            kind: "setNumberValue",
            entityId: dev.kind.entityId,
            value: clamped,
          };
          const summary = t("已将{name}位置设为 {percent}%", {
            name: dev.name,
            percent: displayed,
          });
          void host.executeSingleCommand(dev, command, summary);
          return;
        }
        if (
          slider.dataset.inlineFanpercent &&
          dev.kind.kind === "fan" &&
          dev.kind.speedWritable !== false
        ) {
          const percent = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
          void host.executeSingleCommand(
            dev,
            { kind: "setFanPercentage", entityId: dev.kind.entityId, percent },
            t("已将{name}风速设为 {speed}", { name: dev.name, speed: `${percent}%` }),
          );
          return;
        }
        if (slider.dataset.inlineVolume && dev.kind.kind === "speaker" && dev.kind.volumeWritable) {
          const percent = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
          void host.executeSingleCommand(
            dev,
            { kind: "mediaSetVolume", entityId: dev.kind.mediaEntityId, level: percent / 100 },
            t("已将{name}音量设为 {percent}%", { name: dev.name, percent }),
          );
        }
      });
    });
}

function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  params?: Record<string, string | number>,
): string {
  const lang = resolveLanguage(currentLanguage(), []);
  let template = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  if (params) {
    for (const [key, val] of Object.entries(params)) {
      template = template.replaceAll(`{${key}}`, String(val));
    }
  }
  return template;
}

function cssEscape(raw: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
    return CSS.escape(raw);
  }
  return raw.replace(/([^\w-])/g, "\\$1");
}

function escapeAttr(raw: string): string {
  return raw
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function speakerInputPlaceholder(mode: SpeakerTextMode): string {
  return mode === "directive"
    ? tr3("输入小爱静默指令…", "輸入小愛靜默指令…", "Enter silent command for XiaoAi…")
    : tr3("输入小爱播报文字…", "輸入小愛播報文字…", "Enter text for XiaoAi to announce…");
}

export function resolveSpeakerDrawerMode(
  spec: SpeakerSpec,
  preferred?: SpeakerTextMode,
): SpeakerTextMode | null {
  const hasTts = Boolean(spec.ttsActionId);
  const hasDirective = Boolean(spec.directiveActionId);
  if (!hasTts && !hasDirective) return null;
  if (hasTts && hasDirective) return preferred ?? "tts";
  return hasTts ? "tts" : "directive";
}

export function renderSpeakerCommandBar(
  dev: SmartDevice,
  k: SpeakerSpec,
  escapeHtml: (value: string) => string = escapeAttr,
  options?: { readonly mode?: SpeakerTextMode; readonly draft?: string },
): string {
  const activeMode = resolveSpeakerDrawerMode(k, options?.mode);
  if (!activeMode) return "";
  const id = escapeHtml(dev.id);
  const canSwitch = Boolean(k.ttsActionId && k.directiveActionId);
  const draft = options?.draft ?? "";
  const disabledAttr = dev.isOnline ? "" : ' disabled aria-disabled="true"';
  const sendDisabled = !dev.isOnline || draft.trim().length === 0;
  const placeholder = speakerInputPlaceholder(activeMode);
  const speakLabel = escapeHtml(tr3("播报", "播報", "Speak"));
  const directiveLabel = escapeHtml(tr3("指令", "指令", "Command"));
  const sendLabel = escapeHtml(tr3("发送", "發送", "Send"));

  const modePills = canSwitch
    ? `<div class="cc-segmented-pills" data-speaker-mode-group="${id}">` +
      `<button type="button" class="cc-seg-pill ${activeMode === "tts" ? "is-active" : ""}" data-speaker-mode="${id}|tts" aria-pressed="${activeMode === "tts"}"${disabledAttr}>${speakLabel}</button>` +
      `<button type="button" class="cc-seg-pill ${activeMode === "directive" ? "is-active" : ""}" data-speaker-mode="${id}|directive" aria-pressed="${activeMode === "directive"}"${disabledAttr}>${directiveLabel}</button>` +
      `</div>`
    : `<div class="cc-segmented-pills" data-speaker-mode-group="${id}">` +
      `<button type="button" class="cc-seg-pill is-active" data-speaker-mode-fixed="${id}|${activeMode}" aria-pressed="true" disabled>${activeMode === "tts" ? speakLabel : directiveLabel}</button>` +
      `</div>`;

  const inputRow =
    `<div class="cc-speaker-command-row" data-speaker-command-bar="${id}" style="display:flex;gap:6px;align-items:center;">` +
    `<input type="text" class="cc-speaker-input" data-speaker-input="${id}" maxlength="${SPEAKER_TEXT_MAX_LENGTH}" value="${escapeHtml(draft)}" placeholder="${escapeHtml(placeholder)}" aria-label="${escapeHtml(placeholder)}" style="flex:1;min-width:0;padding:5px 9px;border-radius:8px;border:1px solid rgba(255,255,255,0.14);background:rgba(255,255,255,0.06);color:inherit;font-size:12px;outline:none;"${disabledAttr} />` +
    `<button type="button" class="cc-seg-pill is-active" data-speaker-send="${id}"${sendDisabled ? ' disabled aria-disabled="true"' : ""}>${sendLabel}</button>` +
    `</div>`;

  return `${modePills}${inputRow}`;
}

interface HostSpeakerDrawerState {
  sourceRevision: number;
  readonly modes: Map<string, SpeakerTextMode>;
  readonly drafts: Map<string, string>;
}

const speakerDrawerStates = new WeakMap<MenuMijiaWindowsApp, HostSpeakerDrawerState>();

function ensureSpeakerDrawerState(host: MenuMijiaWindowsApp): HostSpeakerDrawerState {
  let state = speakerDrawerStates.get(host);
  if (!state) {
    state = {
      sourceRevision: host.sourceRevision,
      modes: new Map(),
      drafts: new Map(),
    };
    speakerDrawerStates.set(host, state);
    return state;
  }
  if (state.sourceRevision !== host.sourceRevision) {
    state.modes.clear();
    state.drafts.clear();
    state.sourceRevision = host.sourceRevision;
  }
  return state;
}

function filterUnsupportedLightEffectPills(host: MenuMijiaWindowsApp): void {
  pruneUnsupportedLightEffectsOnHost(host);
  host.root.querySelectorAll<HTMLElement>("[data-lighteffect]").forEach((btn) => {
    const devId = btn.dataset.lighteffect;
    const effect = btn.dataset.effect;
    if (!devId || !effect) return;
    if (!isLightEffectUnsupported(host, devId, effect)) return;
    const pillGroup = btn.closest<HTMLElement>(".cc-segmented-pills");
    const drawer = btn.closest<HTMLElement>(".cc-tile-drawer");
    btn.remove();
    if (pillGroup && pillGroup.querySelectorAll("button").length === 0) {
      pillGroup.remove();
    }
    if (drawer && drawer.children.length === 0) {
      drawer.remove();
    }
  });
}

function mountAndBindSpeakerCommandBars(host: MenuMijiaWindowsApp): void {
  const state = ensureSpeakerDrawerState(host);
  for (const dev of host.devices) {
    if (dev.kind.kind !== "speaker") continue;
    const spec = dev.kind;
    if (!spec.ttsActionId && !spec.directiveActionId) continue;

    const tile = host.root.querySelector<HTMLElement>(`[data-tile-id="${cssEscape(dev.id)}"]`);
    if (!tile) continue;

    let drawer = tile.querySelector<HTMLElement>(".cc-tile-drawer");
    if (!drawer) {
      const isPanel = tile.classList.contains("size-panel") || tile.dataset.size === "panel";
      const isOpen = isPanel || host.expandedDeviceId === dev.id;
      if (!isOpen) continue;
      drawer = document.createElement("div");
      drawer.className = "cc-tile-drawer";
      const facetSection = tile.querySelector(".cc-facet-section");
      if (facetSection) {
        tile.insertBefore(drawer, facetSection);
      } else {
        tile.appendChild(drawer);
      }
    }
    if (drawer.querySelector(`[data-speaker-command-wrap="${cssEscape(dev.id)}"]`)) continue;

    const currentMode = resolveSpeakerDrawerMode(spec, state.modes.get(dev.id));
    if (!currentMode) continue;
    state.modes.set(dev.id, currentMode);
    const currentDraft = state.drafts.get(dev.id) ?? "";

    const wrap = document.createElement("div");
    wrap.className = "cc-speaker-command-wrap";
    wrap.dataset.speakerCommandWrap = dev.id;
    wrap.style.display = "flex";
    wrap.style.flexDirection = "column";
    wrap.style.gap = "6px";
    wrap.innerHTML = renderSpeakerCommandBar(dev, spec, escapeAttr, {
      mode: currentMode,
      draft: currentDraft,
    });
    drawer.appendChild(wrap);

    const inputEl = wrap.querySelector<HTMLInputElement>(`[data-speaker-input="${cssEscape(dev.id)}"]`);
    const sendBtn = wrap.querySelector<HTMLButtonElement>(`[data-speaker-send="${cssEscape(dev.id)}"]`);
    if (!inputEl || !sendBtn) continue;

    wrap.querySelectorAll<HTMLButtonElement>("[data-speaker-mode]").forEach((modeBtn) => {
      modeBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        const raw = modeBtn.dataset.speakerMode ?? "";
        const sep = raw.indexOf("|");
        const modeVal = sep >= 0 ? raw.slice(sep + 1) : "";
        if (modeVal !== "tts" && modeVal !== "directive") return;
        const resolved = resolveSpeakerDrawerMode(spec, modeVal);
        if (!resolved) return;
        state.modes.set(dev.id, resolved);
        wrap.querySelectorAll<HTMLButtonElement>("[data-speaker-mode]").forEach((pill) => {
          const pillMode = (pill.dataset.speakerMode ?? "").split("|")[1];
          const active = pillMode === resolved;
          pill.classList.toggle("is-active", active);
          pill.setAttribute("aria-pressed", String(active));
        });
        const nextPlaceholder = speakerInputPlaceholder(resolved);
        inputEl.placeholder = nextPlaceholder;
        inputEl.setAttribute("aria-label", nextPlaceholder);
      });
    });

    const syncSendDisabled = (): void => {
      const disabled = !dev.isOnline || inputEl.value.trim().length === 0;
      sendBtn.disabled = disabled;
      if (disabled) {
        sendBtn.setAttribute("aria-disabled", "true");
      } else {
        sendBtn.removeAttribute("aria-disabled");
      }
    };

    inputEl.addEventListener("click", (e) => {
      e.stopPropagation();
    });

    inputEl.addEventListener("input", () => {
      state.drafts.set(dev.id, inputEl.value);
      syncSendDisabled();
    });

    let submitting = false;
    const submitSpeakerInput = async (): Promise<void> => {
      if (submitting || !dev.isOnline) return;
      const rawValue = inputEl.value;
      if (rawValue.trim().length === 0) return;

      let trimmed: string;
      try {
        trimmed = normalizeSpeakerText(rawValue);
      } catch {
        host.replyBanner = {
          text: tr3(
            "输入内容不能超过 {max} 个字符",
            "輸入內容不能超過 {max} 個字元",
            "Text cannot exceed {max} characters",
            { max: SPEAKER_TEXT_MAX_LENGTH },
          ),
          source: t("控制失败"),
          isError: true,
        };
        host.render();
        return;
      }

      const activeMode = resolveSpeakerDrawerMode(spec, state.modes.get(dev.id));
      const actionId =
        activeMode === "directive" ? spec.directiveActionId : spec.ttsActionId;
      if (!activeMode || !actionId) {
        host.replyBanner = {
          text: tr3(
            "该音箱不支持此指令通道",
            "該音箱不支援此指令通道",
            "This speaker does not support that channel",
          ),
          source: t("控制失败"),
          isError: true,
        };
        host.render();
        return;
      }

      const command = buildSpeakerTextCommand(
        actionId,
        trimmed,
        activeMode === "directive" ? { silent: true } : undefined,
      );
      const summary =
        activeMode === "directive"
          ? tr3(
              "已向{name}下发指令：「{text}」",
              "已向{name}下發指令：「{text}」",
              'Sent command to {name}: "{text}"',
              { name: dev.name, text: trimmed },
            )
          : tr3(
              "{name}已播报：「{text}」",
              "{name}已播報：「{text}」",
              '{name} announced: "{text}"',
              { name: dev.name, text: trimmed },
            );

      submitting = true;
      state.drafts.delete(dev.id);
      inputEl.value = "";
      syncSendDisabled();

      try {
        await host.executeSingleCommand(dev, command, summary);
        if (host.replyBanner?.isError) {
          state.drafts.set(dev.id, rawValue);
          const liveInput = host.root.querySelector<HTMLInputElement>(
            `[data-speaker-input="${cssEscape(dev.id)}"]`,
          );
          if (liveInput) {
            liveInput.value = rawValue;
            const liveSend = host.root.querySelector<HTMLButtonElement>(
              `[data-speaker-send="${cssEscape(dev.id)}"]`,
            );
            if (liveSend && dev.isOnline && rawValue.trim().length > 0) {
              liveSend.disabled = false;
              liveSend.removeAttribute("aria-disabled");
            }
          }
        }
      } finally {
        submitting = false;
      }
    };

    inputEl.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter" && !e.isComposing) {
        e.preventDefault();
        void submitSpeakerInput();
      }
    });

    sendBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      void submitSpeakerInput();
    });
  }
}
