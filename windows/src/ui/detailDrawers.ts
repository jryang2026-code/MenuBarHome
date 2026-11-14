import { haRoundedInt } from "../core/haDomains.js";
import { currentLanguage, t } from "../core/i18n.js";
import {
  lockedControlIdForAlert,
  showsAdvancedViewOnlyCopy,
} from "../core/miCloud/feedAction.js";
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
} from "../core/models.js";
import { formatTemperature, toCelsius } from "../core/temperature.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
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
        ? host.root.querySelector<HTMLElement>(`#${CSS.escape(facetRowDomId(deviceId, controlId))}`)
        : host.root.querySelector<HTMLElement>(
            `[data-tile-id="${CSS.escape(deviceId)}"] .cc-facet-section`,
          );
      targetEl?.scrollIntoView?.({ block: "nearest", behavior: "smooth" });
      const focusable =
        targetEl?.querySelector<HTMLElement>(
          "button:not([disabled]), input:not([disabled]), select:not([disabled])",
        ) ??
        host.root.querySelector<HTMLElement>(`[data-open-facet-settings="${CSS.escape(deviceId)}"]`) ??
        host.root.querySelector<HTMLElement>(`[data-more-settings-toggle="${CSS.escape(deviceId)}"]`);
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
}
