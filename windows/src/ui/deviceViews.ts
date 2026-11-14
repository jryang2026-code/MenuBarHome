import { t } from "../core/i18n.js";
import { IntentReply } from "../core/assistant.js";
import { trText } from "../core/quickActions.js";
import {
  renderApplianceDrawer,
  renderClimateSwingRow,
  renderCoverDrawer,
  renderGenericDrawer,
  renderPlugDrawer,
} from "./detailDrawers.js";
import { renderMoreSettings } from "./facetViews.js";
import {
  deviceCanTogglePower,
  devicePresentsAsActive,
  deviceReadout,
  deviceStatusSummary,
  hasDetailDrawer,
  localizeAirQuality,
  localizeFanPreset,
  localizeFridgeMode,
  localizeNightShot,
  type EnvironmentReading,
  type FacetControl,
  type SmartDevice,
} from "../core/models.js";
import {
  TILE_SIZES,
  comfort,
  localizeEffect,
  localizeFanMode,
  type TileSize,
} from "./panelPrefs.js";
import {
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  displayStep,
  temperatureSymbol,
} from "../core/temperature.js";
import { SF_ICONS } from "./appConstants.js";
import type { PendingHighRiskConfirmation } from "./appTypes.js";

  export function renderSensorCard(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "sensor" }>,
    compact: boolean,
    attrs: string,
    motion: string,
    badge: string,
    selectedRoom: string,
    valuesAreStale: boolean,
    escapeHtml: (value: string) => string,
  ): string {
    const c = comfort(k.temperature, k.humidity);
    const name = dev.name.replace(t("米家智能温湿度计"), t("温湿度计")) || dev.name;
    if (valuesAreStale) {
      const label = t("可能过期");
      return `
        <div class="cc-tile cc-sensor ${compact ? "is-compact" : "is-span-row"} is-stale ${motion}" ${attrs} role="group" aria-label="${escapeHtml(`${name}，${label}`)}">
          ${badge}
          <div class="cc-sensor-top"><span class="cc-sensor-name">${escapeHtml(name)}</span></div>
          <div class="cc-sensor-main"><span class="cc-sensor-temp">${label}</span></div>
        </div>`;
    }
    const temp = k.temperature !== null ? formatTemperatureValue(k.temperature, undefined, 1) : "--";
    const hum = k.humidity !== null ? Math.round(k.humidity) : null;
    const room = selectedRoom === "全部" ? `<span class="cc-sensor-room">${escapeHtml(dev.roomName)}</span>` : "";
    const batteryLabel = k.battery !== null ? t("电量 {percent}%", { percent: k.battery }) : "";
    const sensorAria = `${t("{name}，温度 {temp}", { name, temp: k.temperature !== null ? formatTemperature(k.temperature, undefined, 1) : "--" })}${hum !== null ? t("，湿度 {humidity}%", { humidity: hum }) : ""}${k.battery !== null ? t("，电量 {percent}%", { percent: k.battery }) : ""}${dev.isOnline ? "" : t("，离线")}`;
    if (compact) {
      return `
        <div class="cc-tile cc-sensor is-compact ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
          ${badge}
          <div class="cc-sensor-top">
            <span class="cc-sensor-name">${escapeHtml(name)}</span>
            <span class="cc-comfort is-${c.level}">${c.label}</span>
          </div>
          <div class="cc-sensor-main">
            <span class="cc-sensor-temp">${temp}<small>${temperatureSymbol()}</small></span>
            ${hum !== null ? `<span class="cc-sensor-hum"><span class="cc-icon-inline" aria-hidden="true">${SF_ICONS.dropFill}</span> ${hum}%</span>` : ""}
          </div>
          <div class="cc-hum-bar"><span style="width:${hum ?? 0}%"></span></div>
        </div>`;
    }
    const ring = hum !== null
      ? `<div class="cc-hum-ring" style="--h:${hum}">
          <svg viewBox="0 0 64 64"><circle class="track" cx="32" cy="32" r="27"/><circle class="comfy" cx="32" cy="32" r="27" pathLength="100"/><circle class="val" cx="32" cy="32" r="27" pathLength="100"/></svg>
          <span>${hum}%</span>
        </div>`
      : "";
    return `
      <div class="cc-tile cc-sensor is-span-row ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
        ${badge}
        <div class="cc-sensor-wide">
          <div class="cc-sensor-info">
            <div class="cc-sensor-top"><span class="cc-sensor-name is-strong">${escapeHtml(name)}</span>${room}</div>
            <span class="cc-sensor-temp is-big">${temp}<small>${temperatureSymbol()}</small></span>
            <div class="cc-sensor-meta">
              <span class="cc-comfort is-${c.level}">${c.label}</span>
              ${k.battery !== null ? `<span class="cc-sensor-batt ${k.battery <= 20 ? "is-low" : ""}" role="img" aria-label="${escapeHtml(batteryLabel)}" title="${escapeHtml(batteryLabel)}"><span class="cc-icon-inline" aria-hidden="true">${k.battery <= 20 ? SF_ICONS.batteryLow : SF_ICONS.batteryFull}</span> ${k.battery}%</span>` : ""}
            </div>
          </div>
          ${ring}
        </div>
      </div>`;
  }

  function renderPendingHighRiskRow(
    devId: string,
    pendingHighRisk: PendingHighRiskConfirmation | null,
    escapeHtml: (value: string) => string,
  ): string {
    if (
      !pendingHighRisk ||
      pendingHighRisk.deviceId !== devId ||
      pendingHighRisk.expiresAtMs <= Date.now() ||
      !pendingHighRisk.confirm
    ) {
      return "";
    }
    const action = pendingHighRisk.confirm.promptLabel ?? pendingHighRisk.confirm.summary;
    const promptText =
      pendingHighRisk.confirm.command.kind === "setClimateTemperature"
        ? t("设为 {temp}？", { temp: formatTemperature(pendingHighRisk.confirm.command.temperature) })
        : t("{action}？", { action });
    return `<div class="cc-slider-label">
      <span>${escapeHtml(promptText)}</span>
      <button class="cc-inline-pill" data-high-risk-confirm="${escapeHtml(devId)}">${t("确认执行")}</button>
    </div>`;
  }

  export function renderClimateStrip(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "climate" }>,
    forceOpen: boolean,
    attrs: string,
    motion: string,
    badge: string,
    expandedDeviceId: string | null,
    selectedRoom: string,
    valuesAreStale: boolean,
    waitingDeviceIds: ReadonlySet<string>,
    escapeHtml: (value: string) => string,
    facets: readonly FacetControl[] = [],
    allowAdvancedFacetWrites = false,
    pendingHighRisk: PendingHighRiskConfirmation | null = null,
  ): string {
    const isWaiting = waitingDeviceIds.has(dev.id);
    const readout = deviceReadout(isWaiting, valuesAreStale);
    const running = devicePresentsAsActive(dev, readout === "possiblyStale") && k.hvacMode !== "off";
    const powerWritable = k.powerWritable !== false;
    const temperatureWritable = k.temperatureWritable !== false;
    const canExpand = hasDetailDrawer(dev, facets);
    const open = canExpand && (forceOpen || expandedDeviceId === dev.id);
    const id = escapeHtml(dev.id);
    const hasActiveHighRisk =
      pendingHighRisk !== null &&
      pendingHighRisk.deviceId === dev.id &&
      pendingHighRisk.expiresAtMs > Date.now();
    const isTwoTapArmed = hasActiveHighRisk && pendingHighRisk?.confirm === undefined;
    const modeLabel: Record<string, string> = { cool: t("制冷"), heat: t("制热"), dry: t("除湿"), fan_only: t("送风"), auto: t("自动") };
    const status = readout === "waiting"
      ? t("等待中")
      : readout === "possiblyStale"
        ? t("可能过期")
        : running
          ? [
              modeLabel[k.hvacMode] ?? k.hvacMode,
              k.currentTemperature !== null
                ? t("室温 {temp}", { temp: formatTemperature(k.currentTemperature, undefined, 1) })
                : "",
            ].filter(Boolean).join(" · ")
          : t("已关闭");
    const baseSubtitle = selectedRoom === "全部" ? `${dev.roomName} · ${status}` : status;
    const subtitle = isTwoTapArmed && !open ? trText("再点一次确认", "Tap again to confirm") : baseSubtitle;
    const span = Math.max(k.maxTemp - k.minTemp, 1);
    const progress = Math.min(Math.max((k.targetTemperature - k.minTemp) / span, 0), 1) * 100;
    const modes = (
      k.availableModes.length > 0
        ? k.availableModes
        : !k.entityId.startsWith("miot:") && powerWritable
          ? ["cool", "heat", "dry", "fan_only"]
          : []
    ).filter((m) => m !== "off");
    const unit = getTemperatureUnit();
    const temp = formatTemperatureValue(k.targetTemperature);
    const power = powerWritable
      ? `<button class="cc-climate-power ${running ? "is-on" : ""}" data-toggle-device="${id}" title="${running ? t("关闭空调") : t("打开空调")}" aria-label="${running ? t("关闭 {name}", { name: escapeHtml(dev.name) }) : t("打开 {name}", { name: escapeHtml(dev.name) })}" aria-pressed="${running}">
            <span aria-hidden="true" ${k.hvacMode === "heat" ? "" : "hidden"}>${SF_ICONS.flameFill}</span><span aria-hidden="true" ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </button>`
      : `<span class="cc-climate-power ${running ? "is-on" : ""}" aria-hidden="true">
            <span ${k.hvacMode === "heat" ? "" : "hidden"}>${SF_ICONS.flameFill}</span><span ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </span>`;
    const steps = readout === "possiblyStale"
      ? ""
      : temperatureWritable
      ? `<button class="cc-climate-step" data-acstep="${id}:-1" title="${t("降低温度")}" aria-label="${t("降低目标温度")}">−</button>
          <span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>
          <button class="cc-climate-step" data-acstep="${id}:1" title="${t("升高温度")}" aria-label="${t("升高目标温度")}">＋</button>`
      : `<span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>`;
    return `
      <div class="cc-tile cc-climate is-span-row ${running ? "is-active" : ""} ${isWaiting ? "is-waiting" : ""} ${hasActiveHighRisk ? "is-caution-armed" : ""} ${dev.isOnline ? "" : "is-offline"} ${readout === "possiblyStale" ? "is-stale" : ""} ${motion}" ${attrs}>
        ${badge}
        <div class="cc-climate-strip">
          ${power}
          <button class="cc-climate-name" ${canExpand ? `data-expand-device="${id}"` : ""} aria-label="${escapeHtml(dev.name)}，${escapeHtml(subtitle)}" aria-expanded="${open}">
            <span class="cc-tile-name">${escapeHtml(dev.name)}</span>
            <span class="cc-tile-status">${escapeHtml(subtitle)} ${!canExpand || forceOpen ? "" : `<i class="cc-mini-caret ${open ? "is-open" : ""}">${SF_ICONS.chevronDown}</i>`}</span>
          </button>
          ${steps}
        </div>
        ${readout === "possiblyStale" ? "" : `<div class="cc-climate-gauge" role="progressbar" aria-label="${t("目标温度进度")}" aria-valuemin="${k.minTemp}" aria-valuemax="${k.maxTemp}" aria-valuenow="${k.targetTemperature}"><span style="width:${progress}%;--fill-scale:${(progress / 100).toFixed(3)}"></span></div>`}
        ${!canExpand ? renderPendingHighRiskRow(dev.id, pendingHighRisk, escapeHtml) : ""}
        ${
          open
            ? `<div class="cc-expander-grid"><div class="cc-expander-clip"><div class="cc-climate-more">
                ${renderPendingHighRiskRow(dev.id, pendingHighRisk, escapeHtml)}
                ${modes.length > 0 ? `<div class="cc-segmented-pills is-even">
                  ${modes.map((m) => `<button class="cc-seg-pill ${running && k.hvacMode === m ? "is-active" : ""}" data-acmode="${id}:${escapeHtml(m)}" aria-pressed="${running && k.hvacMode === m}">${escapeHtml(Object.hasOwn(modeLabel, m) ? (modeLabel[m] ?? m) : m)}</button>`).join("")}
                </div>` : ""}
                ${
                  k.availableFanModes.length > 0
                    ? `<div class="cc-segmented-pills"><span class="cc-pill-label">${t("风速")}</span>${k.availableFanModes
                        .map((f) => `<button class="cc-seg-pill ${k.fanMode === f ? "is-active" : ""}" data-acfan="${id}:${escapeHtml(f)}" aria-pressed="${k.fanMode === f}">${escapeHtml(localizeFanMode(f))}</button>`)
                        .join("")}</div>`
                    : ""
                }
                ${renderClimateSwingRow(dev.id, k, escapeHtml)}
                ${renderMoreSettings({ deviceId: dev.id, facets, allowAdvanced: allowAdvancedFacetWrites, isOnline: dev.isOnline, escapeHtml })}
              </div></div></div>`
            : ""
        }
      </div>`;
  }

/** The card's own detailed controls; 更多设置 is appended by `renderDeviceDrawer` (#5). */
function renderPrimaryDrawer(
  dev: SmartDevice,
  escapeHtml: (value: string) => string,
  pendingHighRisk: PendingHighRiskConfirmation | null = null,
  facets: readonly FacetControl[] = [],
  allowAdvanced = false,
): string {
    const k = dev.kind;
    if (k.kind === "light") {
      const showBrightness = k.brightnessWritable !== false;
      const showColor = k.colorWritable !== false;
      if (!showBrightness && !showColor && k.availableEffects.length === 0) return "";
      const bri = k.brightnessPercent ?? 80;
      const ct = k.colorTempKelvin ?? 4000;
      return `
        <div class="cc-tile-drawer">
          ${showBrightness ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("亮度")}</span>
              <strong>${bri}%</strong>
            </div>
            <input class="cc-range is-amber" type="range" min="1" max="100" value="${bri}" data-brightness="${escapeHtml(dev.id)}" aria-label="${t("亮度")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${bri}" />
          </div>` : ""}
          ${showColor ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("色温")}</span>
              <strong>${ct}K</strong>
            </div>
            <input class="cc-range is-kelvin" type="range" min="${k.minKelvin}" max="${k.maxKelvin}" step="100" value="${ct}" data-colortemp="${escapeHtml(dev.id)}" aria-label="${t("色温")}" aria-valuemin="${k.minKelvin}" aria-valuemax="${k.maxKelvin}" aria-valuenow="${ct}" />
          </div>` : ""}
          ${k.availableEffects.length > 0 ? `
            <div class="cc-segmented-pills">
              ${k.availableEffects.map((effect) => `
                <button class="cc-seg-pill ${k.currentEffect === effect ? "is-active" : ""}"
                  data-lighteffect="${escapeHtml(dev.id)}" data-effect="${escapeHtml(effect)}"
                  aria-pressed="${k.currentEffect === effect}">
                  ${escapeHtml(localizeEffect(effect))}
                </button>
              `).join("")}
            </div>
          ` : ""}
        </div>
      `;
    }
    if (k.kind === "climate") {
      const showTemp = k.temperatureWritable !== false;
      const showModes = k.availableModes.some((mode) => mode !== "off") || (!k.entityId.startsWith("miot:") && k.powerWritable !== false);
      const showFan = k.availableFanModes.length > 0;
      const showSwing = (k.availableSwingModes?.length ?? 0) > 0;
      if (!showTemp && !showModes && !showFan && !showSwing) return "";
      // The confirmation belongs to this card and to the captured command, never to the current
      // slider value; the timer removes the state when its window closes.
      const confirmTemperature =
        pendingHighRisk &&
        pendingHighRisk.deviceId === dev.id &&
        pendingHighRisk.expiresAtMs > Date.now() &&
        pendingHighRisk.confirm?.command.kind === "setClimateTemperature"
          ? pendingHighRisk.confirm.command.temperature
          : null;
      const allModes: ReadonlyArray<{ readonly code: string; readonly label: string }> = [
        { code: "cool", label: t("制冷") },
        { code: "heat", label: t("制热") },
        { code: "dry", label: t("除湿") },
        { code: "fan_only", label: t("送风") },
        { code: "auto", label: t("自动") },
      ];
      const modes =
        k.availableModes.length > 0
          ? allModes.filter((m) => k.availableModes.includes(m.code))
          : allModes;
      return `
        <div class="cc-tile-drawer">
          ${showTemp ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("目标温度")}</span>
              <strong>${formatTemperature(k.targetTemperature)}</strong>
            </div>
            <input class="cc-range is-blue" type="range" min="${formatTemperatureValue(k.minTemp)}" max="${formatTemperatureValue(k.maxTemp)}" step="${displayStep(k.step)}" value="${formatTemperatureValue(k.targetTemperature)}" data-actemp="${escapeHtml(dev.id)}" data-min-c="${k.minTemp}" data-max-c="${k.maxTemp}" aria-label="${t("目标温度")}" aria-valuemin="${formatTemperatureValue(k.minTemp)}" aria-valuemax="${formatTemperatureValue(k.maxTemp)}" aria-valuetext="${formatTemperature(k.targetTemperature)}" />
          </div>` : ""}
          ${confirmTemperature !== null ? `<div class="cc-slider-label">
            <span>${t("设为 {temp}？", { temp: formatTemperature(confirmTemperature) })}</span>
            <button class="cc-inline-pill" data-high-risk-confirm="${escapeHtml(dev.id)}">${t("确认执行")}</button>
          </div>` : renderPendingHighRiskRow(dev.id, pendingHighRisk, escapeHtml)}
          ${showModes ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (m) => `
              <button class="cc-seg-pill ${k.hvacMode === m.code ? "is-active" : ""}" data-acmode="${escapeHtml(dev.id)}:${m.code}">
                ${m.label}
              </button>
            `,
              )
              .join("")}
          </div>` : ""}
          ${showFan ? `<div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("风速")}</span>
            ${k.availableFanModes
              .map(
                (fanMode) => `<button class="cc-seg-pill ${k.fanMode === fanMode ? "is-active" : ""}" data-acfan="${escapeHtml(dev.id)}:${escapeHtml(fanMode)}" aria-pressed="${k.fanMode === fanMode}">${escapeHtml(localizeFanMode(fanMode))}</button>`,
              )
              .join("")}
          </div>` : ""}
          ${showSwing ? renderClimateSwingRow(dev.id, k, escapeHtml) : ""}
        </div>
      `;
    }
    if (k.kind === "fan") {
      const modes =
        k.availablePresetModes.length > 0
          ? k.availablePresetModes
          : k.powerWritable === false
            ? []
            : ["Level 1", "Level 2", "Level 3", "Level 4"];
      const telemetryParts: string[] = [];
      if (k.pm25Density !== undefined && k.pm25Density !== null) {
        const aq = localizeAirQuality(k.airQuality, k.pm25Density);
        telemetryParts.push(`${t("空气质量")} PM2.5 ${k.pm25Density}${aq ? ` (${aq})` : ""}`);
      } else if (k.airQuality) {
        const aq = localizeAirQuality(k.airQuality, null);
        if (aq) telemetryParts.push(`${t("空气质量")} ${aq}`);
      }
      if (k.temperature !== undefined && k.temperature !== null && k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${t("温湿度")} ${formatTemperature(k.temperature, undefined, 1)} · ${Math.round(k.humidity)}%`);
      } else if (k.temperature !== undefined && k.temperature !== null) {
        telemetryParts.push(formatTemperature(k.temperature, undefined, 1));
      } else if (k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${Math.round(k.humidity)}%`);
      }
      if (k.filterLifePercent !== undefined && k.filterLifePercent !== null) {
        telemetryParts.push(`${t("滤芯余量")} ${k.filterLifePercent}%`);
      }
      return `
        <div class="cc-tile-drawer">
          ${
            telemetryParts.length > 0
              ? `<div class="cc-slider-label"><span>${escapeHtml(telemetryParts.join(" · "))}</span></div>`
              : ""
          }
          ${
            k.speedWritable !== false && k.percentage !== null
              ? `<div class="cc-slider-group">
                  <div class="cc-slider-label">
                    <span>${t("风速")}</span>
                    <strong>${k.percentage}%</strong>
                  </div>
                  <input class="cc-range is-blue" type="range" min="1" max="100" value="${Math.max(1, k.percentage)}" data-fanpercent="${escapeHtml(dev.id)}" aria-label="${t("风速")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${Math.max(1, k.percentage)}" />
                </div>`
              : ""
          }
          ${
            modes.length > 0 || (k.swingWritable !== false && k.isOscillating !== null)
              ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (preset) => `
              <button class="cc-seg-pill ${k.presetMode === preset ? "is-active" : ""}" data-fanpreset="${escapeHtml(dev.id)}:${escapeHtml(preset)}" aria-pressed="${k.presetMode === preset}">
                ${escapeHtml(localizeFanPreset(IntentReply.fanSpeedLabel(preset)))}
              </button>
            `,
              )
              .join("")}
            ${
              k.swingWritable !== false && k.isOscillating !== null
                ? `<button class="cc-seg-pill ${k.isOscillating ? "is-active" : ""}" data-fanosc="${escapeHtml(dev.id)}" aria-pressed="${k.isOscillating}">
                    ${k.isOscillating ? t("摇头 开") : t("摇头 关")}
                  </button>`
                : ""
            }
          </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "speaker") {
      const id = escapeHtml(dev.id);
      return `
        <div class="cc-tile-drawer">
          ${k.volumeWritable ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("音量")}</span>
              <strong>${k.volumePercent}%</strong>
            </div>
            <input class="cc-range" type="range" min="0" max="100" value="${k.volumePercent}" data-volume="${id}" aria-label="${t("音量")}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${k.volumePercent}" />
          </div>` : ""}
          ${k.muteSwitchEntityId || k.sleepModeEntityId ? `<div class="cc-segmented-pills">
            ${k.muteSwitchEntityId ? `<button class="cc-seg-pill ${k.isMuted ? "is-active" : ""}" data-speakermute="${id}" aria-pressed="${k.isMuted}">
              ${k.isMuted ? t("静音：开") : t("静音：关")}
            </button>` : ""}
            ${k.sleepModeEntityId ? `<button class="cc-seg-pill ${k.isSleepMode ? "is-active" : ""}" data-speakersleep="${id}" aria-pressed="${k.isSleepMode}">
              ${k.isSleepMode ? t("睡眠模式：开") : t("睡眠模式：关")}
            </button>` : ""}
          </div>` : ""}
        </div>
      `;
    }
    if (k.kind === "camera") {
      if (k.powerWritable === false && k.availableNightShots.length === 0 && !k.motionDetectionEntityId) return "";
      const id = escapeHtml(dev.id);
      const motionOn = Boolean(k.isMotionDetectionOn);
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <button class="cc-seg-pill is-active" data-camera-live="${id}">
              ${t("放大实时画面")}
            </button>
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
          </div>
          ${
            k.availableNightShots.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableNightShots
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.nightShot === mode ? "is-active" : ""}" data-cameranight="${id}:${escapeHtml(mode)}" aria-pressed="${k.nightShot === mode}">
                        ${escapeHtml(localizeNightShot(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "appliance") {
      return renderApplianceDrawer(dev, k, escapeHtml);
    }
    if (k.kind === "vacuum") {
      // macOS vacuumDrawer: start / pause / dock, with the reported status picked.
      if (k.actionsWritable === false) return "";
      const id = escapeHtml(dev.id);
      const status = k.status.toLowerCase();
      const actions = [
        ["start", t("开始清扫"), status === "cleaning"],
        ["pause", t("暂停"), status === "paused"],
        ["returnToBase", t("回充"), status === "returning"],
      ] as const;
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            ${actions
              .map(
                ([action, label, selected]) =>
                  `<button class="cc-seg-pill ${selected ? "is-active" : ""}" data-vacuumaction="${id}|${action}" aria-pressed="${selected}">${label}</button>`,
              )
              .join("")}
          </div>
        </div>
      `;
    }
    if (k.kind === "fridge") {
      const id = escapeHtml(dev.id);
      const fridgeStep = k.fridgeTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:fridge:-1" aria-label="${t("降低冷藏室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:fridge:1" aria-label="${t("升高冷藏室温度")}">＋</button>`
        : "";
      const freezerStep = k.freezerTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:freezer:-1" aria-label="${t("降低冷冻室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:freezer:1" aria-label="${t("升高冷冻室温度")}">＋</button>`
        : "";
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷藏室")} (${formatTemperature(k.fridgeTargetTemp)})</span>
            ${fridgeStep}
          </div>
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷冻室")} (${formatTemperature(k.freezerTargetTemp)})</span>
            ${freezerStep}
          </div>
          ${
            k.availableModes.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableModes
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.currentMode === mode ? "is-active" : ""}" data-fridgemode="${id}:${escapeHtml(mode)}" aria-pressed="${k.currentMode === mode}">
                        ${escapeHtml(localizeFridgeMode(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "cover") {
      return renderCoverDrawer(dev, k, escapeHtml);
    }
    if (k.kind === "plug") {
      return renderPlugDrawer(dev, k, escapeHtml);
    }
    if (k.kind === "generic") {
      return renderGenericDrawer(dev, k, facets, allowAdvanced, escapeHtml);
    }
    return "";
  }

/** Detailed controls plus the 更多设置 rows (#5); empty when the card has nothing to expand. */
export function renderDeviceDrawer(
  dev: SmartDevice,
  escapeHtml: (value: string) => string,
  facets: readonly FacetControl[] = [],
  allowAdvanced = false,
  pendingHighRisk: PendingHighRiskConfirmation | null = null,
): string {
  const primary = renderPrimaryDrawer(dev, escapeHtml, pendingHighRisk, facets, allowAdvanced);
  const extraConfirm =
    dev.kind.kind !== "climate" || primary === ""
      ? renderPendingHighRiskRow(dev.id, pendingHighRisk, escapeHtml)
      : "";
  const inner =
    primary +
    (extraConfirm ? `<div class="cc-tile-drawer">${extraConfirm}</div>` : "") +
    renderMoreSettings({
      deviceId: dev.id,
      facets,
      allowAdvanced,
      isOnline: dev.isOnline,
      escapeHtml,
    });
  return inner ? `<div class="cc-expander-grid"><div class="cc-expander-clip">${inner}</div></div>` : "";
}

function devicePaletteClass(dev: SmartDevice): string {
  switch (dev.kind.kind) {
    case "light":
      return "palette-amber";
    case "climate":
    case "fridge":
      return "palette-blue";
    case "fan":
      return "palette-mint";
    case "plug":
      return "palette-green";
    case "vacuum":
      return "palette-indigo";
    case "camera":
      return "palette-blue";
    case "sensor":
      return "palette-teal";
    case "cover":
      return "palette-teal";
    case "speaker":
      return "palette-indigo";
    case "appliance":
      return "palette-blue";
    case "generic":
      return "palette-teal";
  }
}

const DEVICE_ICONS = {
  lightbulbOutline: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2.5a5.3 5.3 0 00-3.4 9.37c.88.74 1.4 1.56 1.4 2.53v.6h4v-.6c0-.97.52-1.79 1.4-2.53A5.3 5.3 0 0010 2.5zM8.3 17.3h3.4"/></svg>`,
  lightStrip: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M3 6.5c3-2 5 2 8 0s4-2 6 0"/><path d="M3 12.5c3-2 5 2 8 0s4-2 6 0"/><circle cx="5" cy="9.5" r="0.9" fill="currentColor" stroke="none"/><circle cx="10" cy="9.5" r="0.9" fill="currentColor" stroke="none"/><circle cx="15" cy="9.5" r="0.9" fill="currentColor" stroke="none"/></svg>`,
  acUnit: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4.5h12a1.8 1.8 0 011.8 1.8v3.2A1.8 1.8 0 0116 11.3H4a1.8 1.8 0 01-1.8-1.8V6.3A1.8 1.8 0 014 4.5zM5 9.2h10M6 13.5c0 1.4-.8 2.2-1.5 2.7M10 13.5v3M14 13.5c0 1.4.8 2.2 1.5 2.7"/></svg>`,
  heaterVertical: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="2.5" width="11" height="14" rx="2"/><path d="M7.5 5.5v8M10 5.5v8M12.5 5.5v8M6.5 18h7"/></svg>`,
  bedDouble: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 11.5h15v4h-15z"/><path d="M3.5 11.5V6.5a1.5 1.5 0 011.5-1.5h10a1.5 1.5 0 011.5 1.5v5"/><path d="M5.5 9h3.5M11 9h3.5M2.5 15.5v2M17.5 15.5v2"/></svg>`,
  dehumidifier: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M7.8 3.2c2.3 2.6 4 4.7 4 6.7a4 4 0 11-8 0c0-2 1.7-4.1 4-6.7z"/><path d="M13.5 7.5h4M13.5 11h4M13.5 14.5h3"/></svg>`,
  humidifier: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="9" width="11" height="8" rx="2.2"/><path d="M7.5 6.8c0-1.1 1-1.6 1-2.7M10.5 6.8c0-1.1 1-1.6 1-2.7M13.2 6.8c0-1.1.8-1.6.8-2.7M7 13h6"/></svg>`,
  wind: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M3 7.5h9.5a2 2 0 10-1.8-2.8"/><path d="M3 10.8h12.2a2.1 2.1 0 11-1.9 3"/><path d="M3 14h6.5"/></svg>`,
  airPurifier: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2.5" width="10" height="15" rx="2.2"/><circle cx="10" cy="7.5" r="2.1"/><path d="M7.5 12.5h5M7.5 14.8h5"/></svg>`,
  diffuser: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 10.5h7l1.2 5.2a1.5 1.5 0 01-1.46 1.8H6.76a1.5 1.5 0 01-1.46-1.8l1.2-5.2z"/><path d="M8.5 8.5h3v2h-3zM9 6.2c0-1.1 1.2-1.5 1.2-2.7M11.6 6.5c0-.9.9-1.3.9-2.3"/></svg>`,
  desktopComputer: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="15" height="10" rx="1.6"/><path d="M7 16.8h6M10 13.5v3.3"/></svg>`,
  coffeeCup: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h9.5v4.2a4.3 4.3 0 01-4.3 4.3H8.3A4.3 4.3 0 014 12.2V8z"/><path d="M13.5 9h1.3a2 2 0 010 4h-1.3M3.5 18h11M7.2 5.6c0-.9.8-1.3.8-2.2M10.2 5.6c0-.9.8-1.3.8-2.2"/></svg>`,
  wallSwitch: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="13" height="13" rx="2.2"/><path d="M10 6v8M7.2 6.5v7M12.8 6.5v7"/></svg>`,
  refrigerator: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="2.2" width="11" height="15.6" rx="2"/><path d="M4.5 9.2h11M7.2 5.2v2.2M7.2 11.4v3"/></svg>`,
  robotVacuum: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><circle cx="10" cy="10" r="7.2"/><circle cx="10" cy="8.2" r="1.7"/><path d="M6.2 13.2a5.2 5.2 0 007.6 0"/></svg>`,
  cameraSleep: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4.8 5h6.8a2 2 0 012 2v6a2 2 0 01-2 2H4.8a2 2 0 01-2-2V7a2 2 0 012-2zM13.6 8.3l3.6-2v7.4l-3.6-2M4.5 4.2l11 11.6"/></svg>`,
  doorbell: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="5.2" y="2.5" width="9.6" height="15" rx="2.8"/><circle cx="10" cy="7.3" r="1.8"/><circle cx="10" cy="13.2" r="1.1" fill="currentColor" stroke="none"/></svg>`,
  lockShield: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 2.2l6 2.3v4.7c0 4.2-2.55 7.95-6 9.3-3.45-1.35-6-5.1-6-9.3V4.5l6-2.3zm0 4.3a2 2 0 00-2 2v1h-.5a.75.75 0 00-.75.75v3c0 .41.34.75.75.75h5a.75.75 0 00.75-.75v-3a.75.75 0 00-.75-.75H12v-1a2 2 0 00-2-2zm-1 3v-1a1 1 0 112 0v1H9z"/></svg>`,
  kettle: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 6.5h7.5l1 9a1.5 1.5 0 01-1.5 1.7H6a1.5 1.5 0 01-1.5-1.7l1-9z"/><path d="M4 7.5l1.7-.8M13.2 8.2h1.8a2 2 0 010 4.2h-1.3M7.5 4.5h3.5"/></svg>`,
  ovenFryer: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3.5" width="14" height="13" rx="2"/><rect x="5.5" y="8" width="9" height="6" rx="1"/><circle cx="7" cy="5.8" r="0.8" fill="currentColor" stroke="none"/><circle cx="10" cy="5.8" r="0.8" fill="currentColor" stroke="none"/><circle cx="13" cy="5.8" r="0.8" fill="currentColor" stroke="none"/></svg>`,
  riceCooker: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h12v4.5a3.5 3.5 0 01-3.5 3.5h-5A3.5 3.5 0 014 13.5V9z"/><path d="M3 9h14M6.5 9V7.3a3.5 3.5 0 017 0V9M8.5 12.5h3"/></svg>`,
  motionSensor: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><circle cx="9.5" cy="4.3" r="1.5" fill="currentColor" stroke="none"/><path d="M6.5 9.2l2.5-1.7 2.2 1.8 2 1M8.8 7.5l-.8 4.2 2.6 2.2.8 3.3M8 11.7l-2.3 3.8"/><path d="M15 5.8a4.2 4.2 0 010 5.6"/></svg>`,
  magnetSensor: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3.5" width="5" height="13" rx="1.6"/><rect x="11.5" y="5.5" width="4.5" height="9" rx="1.5"/><path d="M9.5 8.5h1.5M9.5 11.5h1.5"/></svg>`,
  waterLeak: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3c2.4 2.7 4 4.8 4 6.8a4 4 0 11-8 0c0-2 1.6-4.1 4-6.8z"/><path d="M3.5 15.8c1.8 1.2 4 1.8 6.5 1.8s4.7-.6 6.5-1.8"/></svg>`,
  smokeDetector: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4.5h12l-1.4 3.2H5.4L4 4.5z"/><path d="M7.2 10.5c-.8 1.2.8 2.2 0 3.5M10 10.5c-.8 1.2.8 2.2 0 3.5M12.8 10.5c-.8 1.2.8 2.2 0 3.5"/></svg>`,
  radarSensor: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round"><circle cx="10" cy="10" r="1.8" fill="currentColor" stroke="none"/><path d="M6.5 6.5a5 5 0 000 7M13.5 6.5a5 5 0 010 7M4 4a8.5 8.5 0 000 12M16 4a8.5 8.5 0 010 12"/></svg>`,
  curtainOpen: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 4h15M3.5 4v12c2.2-.6 3.5-2.5 3.8-5.5L4 9.5M16.5 4v12c-2.2-.6-3.5-2.5-3.8-5.5L16 9.5"/></svg>`,
  curtainClosed: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 4h15M3.8 4h5.6v12H3.8zM10.6 4h5.6v12h-5.6zM6.6 4v12M13.4 4v12"/></svg>`,
  windowOpener: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3.5" width="14" height="13" rx="1.6"/><path d="M10 3.5v13M10 5.5l4.5 1.8v5.4L10 14.5"/></svg>`,
  garageDoor: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 8L10 3.2 17.5 8v8.8h-15V8z"/><rect x="5.2" y="9.2" width="9.6" height="7.6"/><path d="M5.2 11.7h9.6M5.2 14.2h9.6"/></svg>`,
  clothesAirer: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M10 6.5a1.6 1.6 0 111.5-2.1c.2.8-.5 1.4-1.5 2.1zm0 0L3 12.2a1 1 0 00.63 1.78h12.74A1 1 0 0017 12.2L10 6.5z"/><path d="M6.5 14v2.5M13.5 14v2.5"/></svg>`,
  washer: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="2.5" width="13" height="15" rx="2"/><path d="M3.5 6.2h13"/><circle cx="6.2" cy="4.4" r="0.7" fill="currentColor" stroke="none"/><circle cx="10" cy="11.8" r="3.5"/><path d="M7.3 11.8c1-.9 2-.9 2.7 0s1.7.9 2.7 0"/></svg>`,
  dryer: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="2.5" width="13" height="15" rx="2"/><path d="M3.5 6.2h13"/><circle cx="10" cy="11.8" r="3.5"/><path d="M9 10.2c-.6.8.6 1.6 0 2.6M11 10.2c-.6.8.6 1.6 0 2.6"/></svg>`,
  dishwasher: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="2.5" width="13" height="15" rx="2"/><path d="M3.5 6.2h13M6.2 13.8h7.6"/><circle cx="8.3" cy="10.8" r="1.8"/><circle cx="11.9" cy="10.8" r="1.8"/></svg>`,
  waterHeater: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="4.8" y="2.5" width="10.4" height="13" rx="2.4"/><path d="M10 6.5c1.5 1.8 2.4 3 2.4 4.2a2.4 2.4 0 11-4.8 0c0-1.2.9-2.4 2.4-4.2z"/><path d="M8 15.5v2M12 15.5v2"/></svg>`,
  bathHeater: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3.5" width="14" height="5" rx="1.5"/><path d="M6.2 11c-.5 1.3.5 2.4 0 3.8M10 11c-.5 1.3.5 2.4 0 3.8M13.8 11c-.5 1.3.5 2.4 0 3.8"/></svg>`,
  rangeHood: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 3h5v4.5l4.5 3.8v2.2H3v-2.2l4.5-3.8V3z"/><path d="M7 16c0 .9-.5 1.5-.5 2M10 16v2M13 16c0 .9.5 1.5.5 2"/></svg>`,
  fishTank: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 10c2.2-3 5.2-4.2 8.8-3.2 1.2.3 2.3 1.2 3.2 3.2-.9 2-2 2.9-3.2 3.2-3.6 1-6.6-.2-8.8-3.2z"/><path d="M3.5 10L1.8 7.5v5L3.5 10z"/><circle cx="12.2" cy="9.4" r="0.8" fill="currentColor" stroke="none"/></svg>`,
  petPaw: `<svg viewBox="0 0 20 20" fill="currentColor"><circle cx="6" cy="7.2" r="1.6"/><circle cx="8.8" cy="5" r="1.6"/><circle cx="12.2" cy="5.2" r="1.6"/><circle cx="14.5" cy="7.8" r="1.5"/><path d="M10 9.2c-2.6 0-4.6 2-4.6 4.1 0 1.5 1.2 2.5 2.7 2.5.8 0 1.4-.3 1.9-.3s1.1.3 1.9.3c1.5 0 2.7-1 2.7-2.5 0-2.1-2-4.1-4.6-4.1z"/></svg>`,
  television: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="15" height="10" rx="1.6"/><path d="M6.5 17h7"/></svg>`,
  applianceDial: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3" width="13" height="14" rx="2.4"/><circle cx="10" cy="10.5" r="3.4"/><path d="M10 10.5l1.8-1.8M7 5.8h6"/></svg>`,
} as const;

function applianceOrGenericIcon(
  symbolName: string | null | undefined,
  model: string,
  name: string,
  fallback: string,
): string {
  const sym = (symbolName ?? "").toLowerCase();
  const haystack = `${model} ${name}`.toLowerCase();
  if (sym.includes("washer") || haystack.includes("washer") || haystack.includes("洗衣")) {
    return DEVICE_ICONS.washer;
  }
  if (
    sym.includes("dryer") ||
    haystack.includes("dryer") ||
    haystack.includes("干衣") ||
    haystack.includes("乾衣") ||
    haystack.includes("烘干") ||
    haystack.includes("烘乾")
  ) {
    return DEVICE_ICONS.dryer;
  }
  if (sym.includes("dishwasher") || haystack.includes("dishwasher") || haystack.includes("洗碗")) {
    return DEVICE_ICONS.dishwasher;
  }
  if (
    haystack.includes("hood") ||
    haystack.includes("油烟机") ||
    haystack.includes("油煙機") ||
    haystack.includes("烟机")
  ) {
    return DEVICE_ICONS.rangeHood;
  }
  if (haystack.includes("bath") || haystack.includes("浴霸") || sym.includes("sun.max")) {
    return DEVICE_ICONS.bathHeater;
  }
  if (
    haystack.includes("water-heater") ||
    haystack.includes("waterheater") ||
    haystack.includes("boiler") ||
    haystack.includes("热水器") ||
    haystack.includes("熱水器") ||
    haystack.includes("壁挂炉") ||
    haystack.includes("壁掛爐") ||
    sym === "water.waves"
  ) {
    return DEVICE_ICONS.waterHeater;
  }
  if (
    sym.includes("bed") ||
    haystack.includes("blanket") ||
    haystack.includes("mattress") ||
    haystack.includes("水暖毯") ||
    haystack.includes("电热毯") ||
    haystack.includes("電熱毯") ||
    haystack.includes("床垫")
  ) {
    return DEVICE_ICONS.bedDouble;
  }
  if (
    sym.includes("heater") ||
    haystack.includes("heater") ||
    haystack.includes("取暖") ||
    haystack.includes("电暖")
  ) {
    return DEVICE_ICONS.heaterVertical;
  }
  if (sym === "wind" || haystack.includes("airfresh") || haystack.includes("新风") || haystack.includes("新風")) {
    return DEVICE_ICONS.wind;
  }
  if (sym.includes("humidity") || haystack.includes("dehumid") || haystack.includes("除湿") || haystack.includes("除溼")) {
    return DEVICE_ICONS.dehumidifier;
  }
  if (sym.includes("humidifier") || haystack.includes("humidifier") || haystack.includes("加湿") || haystack.includes("加溼")) {
    return DEVICE_ICONS.humidifier;
  }
  if (
    sym.includes("mug") ||
    haystack.includes("kettle") ||
    haystack.includes("health-pot") ||
    haystack.includes("waterdispenser") ||
    haystack.includes("水壶") ||
    haystack.includes("水壺") ||
    haystack.includes("养生壶") ||
    haystack.includes("養生壺") ||
    haystack.includes("饮水") ||
    haystack.includes("飲水")
  ) {
    return DEVICE_ICONS.kettle;
  }
  if (
    sym.includes("frying") ||
    haystack.includes("fryer") ||
    haystack.includes("oven") ||
    haystack.includes("microwave") ||
    haystack.includes("炸锅") ||
    haystack.includes("炸鍋") ||
    haystack.includes("烤箱") ||
    haystack.includes("微波炉") ||
    haystack.includes("微波爐")
  ) {
    return DEVICE_ICONS.ovenFryer;
  }
  if (haystack.includes("cooker") || haystack.includes("饭煲") || haystack.includes("飯煲") || haystack.includes("电锅")) {
    return DEVICE_ICONS.riceCooker;
  }
  if (sym.includes("cup.and") || haystack.includes("coffee") || haystack.includes("咖啡")) {
    return DEVICE_ICONS.coffeeCup;
  }
  if (sym.includes("fish") || haystack.includes("fish") || haystack.includes("鱼缸") || haystack.includes("魚缸")) {
    return DEVICE_ICONS.fishTank;
  }
  if (
    sym.includes("pawprint") ||
    haystack.includes("feeder") ||
    haystack.includes("litter") ||
    haystack.includes("喂食") ||
    haystack.includes("餵食") ||
    haystack.includes("猫砂") ||
    haystack.includes("貓砂") ||
    haystack.includes("宠物") ||
    haystack.includes("寵物")
  ) {
    return DEVICE_ICONS.petPaw;
  }
  if (sym.includes("lock") || haystack.includes(".lock.") || haystack.includes("门锁") || haystack.includes("門鎖")) {
    return DEVICE_ICONS.lockShield;
  }
  if (sym === "wifi" || haystack.includes("router") || haystack.includes("gateway") || haystack.includes("路由")) {
    return SF_ICONS.wifi;
  }
  if (sym === "tv" || sym.includes("projector") || haystack.includes("television") || haystack.includes("电视") || haystack.includes("投影")) {
    return DEVICE_ICONS.television;
  }
  if (sym.includes("flame")) {
    return SF_ICONS.flameFill;
  }
  if (sym.includes("drop")) {
    return SF_ICONS.dropFill;
  }
  return fallback;
}

/**
 * Semantic inline SVG icon for every device family, sensor/cover subtype, and appliance profile,
 * aligned with macOS `SmartDevice.sfSymbolName` (`SmartDevice+Presentation.swift:9-95`).
 */
export function deviceSvgIcon(dev: SmartDevice): string {
  const model = dev.model.toLowerCase();
  const name = dev.name.toLowerCase();
  const k = dev.kind;
  switch (k.kind) {
    case "light":
      if (model.includes("strip") || name.includes("灯带") || name.includes("燈帶")) {
        return DEVICE_ICONS.lightStrip;
      }
      return k.isOn ? SF_ICONS.lightbulbFill : DEVICE_ICONS.lightbulbOutline;
    case "climate":
      if (model.includes("blanket") || name.includes("水暖毯") || name.includes("电热毯") || name.includes("電熱毯")) {
        return DEVICE_ICONS.bedDouble;
      }
      if (model.includes("heater") || name.includes("取暖") || name.includes("电暖") || name.includes("電暖")) {
        return DEVICE_ICONS.heaterVertical;
      }
      return k.isOn ? SF_ICONS.snowflake : DEVICE_ICONS.acUnit;
    case "fan":
      if (model.includes(".derh.") || model.includes("dehumid") || name.includes("除湿") || name.includes("除溼")) {
        return DEVICE_ICONS.dehumidifier;
      }
      if (model.includes("humidifier") || name.includes("加湿") || name.includes("加溼")) {
        return DEVICE_ICONS.humidifier;
      }
      if (model.includes("airfresh") || model.includes("air-fresh") || name.includes("新风") || name.includes("新風")) {
        return DEVICE_ICONS.wind;
      }
      if (
        model.includes("airp") ||
        model.includes("purifier") ||
        name.includes("净化") ||
        name.includes("淨化") ||
        k.pm25Density != null ||
        k.airQuality != null ||
        k.filterLifePercent != null
      ) {
        return DEVICE_ICONS.airPurifier;
      }
      return SF_ICONS.fanbladesFill;
    case "plug":
      if (model.includes(".diffuser.") || name.includes("香薰") || name.includes("香氛")) {
        return DEVICE_ICONS.diffuser;
      }
      if (k.switchEntityId.startsWith("button.")) {
        if (
          k.switchEntityId.includes("wake_on_lan") ||
          name.includes("电脑") ||
          name.includes("電腦") ||
          name.includes("pc") ||
          name.includes("mac")
        ) {
          return DEVICE_ICONS.desktopComputer;
        }
        return SF_ICONS.power;
      }
      if (name.includes("咖啡") || model.includes("coffee")) {
        return DEVICE_ICONS.coffeeCup;
      }
      if (name.includes("灯") || name.includes("燈")) {
        return k.isOn ? SF_ICONS.lightbulbFill : DEVICE_ICONS.lightbulbOutline;
      }
      if (model.includes(".switch.") || name.includes("开关") || name.includes("開關")) {
        return DEVICE_ICONS.wallSwitch;
      }
      return SF_ICONS.powerplugFill;
    case "fridge":
      return DEVICE_ICONS.refrigerator;
    case "vacuum":
      return DEVICE_ICONS.robotVacuum;
    case "speaker":
      return k.isMuted ? SF_ICONS.speakerSlash : SF_ICONS.speakerFill;
    case "camera":
      if (
        model.includes("doorbell") ||
        model.includes("cateye") ||
        name.includes("门铃") ||
        name.includes("門鈴") ||
        name.includes("猫眼") ||
        name.includes("貓眼")
      ) {
        return DEVICE_ICONS.doorbell;
      }
      return k.isOn ? SF_ICONS.videoFill : DEVICE_ICONS.cameraSleep;
    case "sensor": {
      const status = (k.statusText ?? "").toLowerCase();
      if (name.includes("门锁") || name.includes("門鎖") || model.includes(".lock.")) {
        return DEVICE_ICONS.lockShield;
      }
      if (
        model.includes("kettle") ||
        model.includes("waterdispenser") ||
        model.includes("health-pot") ||
        name.includes("水壶") ||
        name.includes("水壺") ||
        name.includes("养生壶") ||
        name.includes("養生壺") ||
        name.includes("饮水") ||
        name.includes("飲水")
      ) {
        return DEVICE_ICONS.kettle;
      }
      if (
        model.includes("fryer") ||
        model.includes("oven") ||
        model.includes("microwave") ||
        name.includes("炸锅") ||
        name.includes("炸鍋") ||
        name.includes("烤箱") ||
        name.includes("微波炉")
      ) {
        return DEVICE_ICONS.ovenFryer;
      }
      if (model.includes("cooker") || name.includes("饭煲") || name.includes("飯煲") || name.includes("电锅")) {
        return DEVICE_ICONS.riceCooker;
      }
      if (
        model.includes("motion") ||
        model.includes("occupancy") ||
        name.includes("人体") ||
        name.includes("人體") ||
        name.includes("存在") ||
        name.includes("移动") ||
        status.includes("移动") ||
        status.includes("motion")
      ) {
        return DEVICE_ICONS.motionSensor;
      }
      if (
        model.includes("magnet") ||
        model.includes("contact") ||
        name.includes("门磁") ||
        name.includes("門磁") ||
        name.includes("门窗") ||
        name.includes("門窗") ||
        status.includes("已闭合") ||
        status.includes("門窗") ||
        status.includes("contact")
      ) {
        return DEVICE_ICONS.magnetSensor;
      }
      if (
        model.includes("submersion") ||
        model.includes("waterleak") ||
        model.includes("leak") ||
        name.includes("水浸") ||
        name.includes("漏水") ||
        status.includes("浸水") ||
        status.includes("漏水") ||
        status.includes("leak")
      ) {
        return DEVICE_ICONS.waterLeak;
      }
      if (model.includes("smoke") || name.includes("烟雾") || name.includes("煙霧") || status.includes("烟雾")) {
        return DEVICE_ICONS.smokeDetector;
      }
      if (model.includes("gas") || name.includes("燃气") || name.includes("燃氣") || name.includes("天然气")) {
        return SF_ICONS.flameFill;
      }
      if (
        model.includes("illumination") ||
        name.includes("光照") ||
        name.includes("光线") ||
        status.endsWith(" lx") ||
        status.includes("光照")
      ) {
        return SF_ICONS.sunMaxFill;
      }
      if (k.temperature !== null || k.humidity !== null) {
        return SF_ICONS.sensorFill;
      }
      return DEVICE_ICONS.radarSensor;
    }
    case "cover":
      if (k.subtype === "clothes-airer") return DEVICE_ICONS.clothesAirer;
      if (k.subtype === "garage-door") return DEVICE_ICONS.garageDoor;
      if (k.subtype === "window-opener") return DEVICE_ICONS.windowOpener;
      return (k.positionPercent ?? 0) > 0 ? DEVICE_ICONS.curtainOpen : DEVICE_ICONS.curtainClosed;
    case "appliance":
      return applianceOrGenericIcon(k.symbolName, dev.model, dev.name, DEVICE_ICONS.applianceDial);
    case "generic":
      return applianceOrGenericIcon(k.symbolName, `${dev.model} ${k.deviceType}`, dev.name, SF_ICONS.grid2x2);
  }
}

export interface DeviceTileViewState {
  readonly span: number;
  readonly index: number;
  readonly size: Exclude<TileSize, "auto">;
  readonly animateEntrance: boolean;
  readonly poppedDeviceId: string | null;
  readonly draggingId: string | null;
  readonly isEditingLayout: boolean;
  readonly selectedRoom: string;
  readonly valuesAreStale: boolean;
  readonly expandedDeviceId: string | null;
  readonly pendingHighRisk: PendingHighRiskConfirmation | null;
  readonly waitingDeviceIds: ReadonlySet<string>;
  readonly dimPreview: { readonly id: string; readonly percent: number } | null;
  readonly deviceFacets: Readonly<Record<string, readonly FacetControl[]>>;
  readonly allowAdvancedFacetWrites: boolean;
  readonly escapeHtml: (value: string) => string;
}

export function renderDeviceTile(dev: SmartDevice, state: DeviceTileViewState): string {
  const size = state.size;
  const escape = state.escapeHtml;
  const attrs = `data-tile-id="${escape(dev.id)}" style="grid-column: span ${state.span}; --i: ${Math.min(state.index, 12)}; --jd: -${Math.round((performance.now() + (state.index * 137) % 560) % 560)}ms"`;
  const motion = `${state.animateEntrance ? "is-entering" : ""} ${state.poppedDeviceId === dev.id ? "is-popped" : ""} ${state.draggingId === dev.id ? "is-dragging" : ""}`;
  const sizeTitle = TILE_SIZES.find((item) => item.id === size)?.title ?? "";
  const badge = state.isEditingLayout
    ? `<button class="cc-resize-handle" data-resize-handle="${escape(dev.id)}" data-cycle-size="${escape(dev.id)}" data-tile-size="${size}" title="${t("切换卡片大小")}：${sizeTitle}" aria-label="${t("切换卡片大小")}，${sizeTitle}"><svg class="cc-resize-arc" viewBox="0 0 28 28" aria-hidden="true"><path d="M 22 10 A 12 12 0 0 1 10 22" /></svg></button>`
    : "";
  if (dev.kind.kind === "sensor" && (dev.kind.temperature !== null || dev.kind.humidity !== null)) {
    return renderSensorCard(dev, dev.kind, state.span < 6, attrs, motion, badge, state.selectedRoom, state.valuesAreStale, escape);
  }
  if (dev.kind.kind === "climate" && size !== "half") {
    return renderClimateStrip(dev, dev.kind, size === "panel", attrs, motion, badge, state.expandedDeviceId, state.selectedRoom, state.valuesAreStale, state.waitingDeviceIds, escape, state.deviceFacets[dev.id] ?? [], state.allowAdvancedFacetWrites, state.pendingHighRisk);
  }
  const isExpanded = state.expandedDeviceId === dev.id || size === "panel";
  const isWaiting = state.waitingDeviceIds.has(dev.id);
  const readout = deviceReadout(isWaiting, state.valuesAreStale);
  const isOn = devicePresentsAsActive(dev, readout === "possiblyStale");
  const kind = dev.kind.kind;
  const palette = devicePaletteClass(dev);
  const svg = deviceSvgIcon(dev);
  const writable = deviceCanTogglePower(dev);
  const hasDrawer = hasDetailDrawer(dev, state.deviceFacets[dev.id] ?? []);
  const hasActiveHighRisk =
    state.pendingHighRisk !== null &&
    state.pendingHighRisk.deviceId === dev.id &&
    state.pendingHighRisk.expiresAtMs > Date.now();
  const isTwoTapArmed = hasActiveHighRisk && state.pendingHighRisk?.confirm === undefined;
  const subtitle =
    state.selectedRoom === "全部"
      ? `${dev.roomName} · ${deviceStatusSummary(dev)}`
      : deviceStatusSummary(dev);

  const dim = state.dimPreview?.id === dev.id ? state.dimPreview.percent : null;
  const fill = kind === "light" && !isExpanded
    ? dim ?? (isOn && dev.kind.kind === "light" ? dev.kind.brightnessPercent ?? 100 : 0)
    : 0;
  const capsuleFill = kind === "light" && !isExpanded && dim !== null ? dim : 0;
  const shownSubtitle = readout === "waiting"
    ? t("等待中")
    : readout === "possiblyStale"
      ? t("可能过期")
      : dim !== null
        ? t("亮度 {percent}%", { percent: dim })
        : isTwoTapArmed && !isExpanded
          ? trText("再点一次确认", "Tap again to confirm")
          : subtitle;
  const staleClass = readout === "possiblyStale" ? "is-stale" : "";
  const isSubpage = state.expandedDeviceId === dev.id && size !== "panel" && hasDrawer;
  const isCapsule = state.span < 6 && !isExpanded;

  if (isCapsule) {
    return `
      <div class="cc-tile is-capsule ${palette} ${isOn ? "is-active" : ""} ${isWaiting ? "is-waiting" : ""} ${hasActiveHighRisk ? "is-caution-armed" : ""} ${dim !== null ? "is-dimming" : ""} ${dev.isOnline ? "" : "is-offline"} ${staleClass} ${kind === "light" ? "is-light" : ""} ${motion}" ${attrs}>
        ${badge}
        <div class="cc-tile-header win-capsule-stack">
          <div class="win-split-pill ${hasDrawer ? "has-expand" : ""}">
            ${capsuleFill > 0 ? `<span class="cc-tile-fill" style="width:${capsuleFill}%;--fill-scale:${(capsuleFill / 100).toFixed(3)}"></span>` : ""}
            ${
              dev.kind.kind === "generic" && dev.kind.isReadOnly
                ? `<span class="cc-readonly-badge">${t("只读")}</span>`
                : ""
            }
            ${
              writable
                ? `<button
              class="cc-tile-orb win-pill-toggle"
              data-toggle-device="${escape(dev.id)}"
              title="${kind === "sensor" ? escape(dev.name) : t("点击直接切换开关")}"
              aria-label="${escape(t("{name} 开关", { name: dev.name }))}"
              aria-pressed="${isOn}"
            >
              ${svg}
            </button>`
                : `<span class="cc-tile-orb win-pill-toggle" title="${escape(dev.name)}" aria-hidden="true">${svg}</span>`
            }
            ${
              hasDrawer
                ? `<button
                    class="cc-tile-chevron win-pill-expand"
                    data-expand-device="${escape(dev.id)}"
                    title="${t("展开详细控制")}"
                    aria-label="${t("展开")} ${escape(t("{name} 详细控制", { name: dev.name }))}"
                    aria-expanded="false"
                  >
                    ${SF_ICONS.chevronRight}
                  </button>`
                : ""
            }
          </div>
          <button
            class="cc-tile-body win-pill-caption"
            data-body-device="${escape(dev.id)}"
            title="${kind === "camera" ? t("点击放大打开摄像机实时画面") : hasDrawer ? t("点击展开精细调节") : t("点击切换开关")}"
            aria-label="${escape(dev.name)}，${escape(shownSubtitle)}"
            aria-pressed="${isOn}"
          >
            <div class="cc-tile-name">${escape(dev.name)}</div>
            <div class="cc-tile-status" title="${escape(shownSubtitle)}">${escape(shownSubtitle)}</div>
          </button>
        </div>
        ${!hasDrawer ? renderPendingHighRiskRow(dev.id, state.pendingHighRisk, escape) : ""}
      </div>
    `;
  }

  if (isSubpage) {
    return `
      <div class="cc-tile is-expanded is-subpage is-span-row ${palette} ${isOn ? "is-active" : ""} ${isWaiting ? "is-waiting" : ""} ${hasActiveHighRisk ? "is-caution-armed" : ""} ${dev.isOnline ? "" : "is-offline"} ${staleClass} ${kind === "light" ? "is-light" : ""} ${motion}" ${attrs}>
        ${badge}
        <div class="cc-tile-header win-subpage-header">
          <button
            class="cc-tile-chevron win-subpage-back is-open"
            data-expand-device="${escape(dev.id)}"
            title="${t("收起详细控制")}"
            aria-label="${t("收起")} ${escape(t("{name} 详细控制", { name: dev.name }))}"
            aria-expanded="true"
          >
            ${SF_ICONS.chevronLeft}
          </button>
          <button
            class="cc-tile-body win-subpage-title"
            data-body-device="${escape(dev.id)}"
            title="${t("点击收起精细调节")}"
            aria-label="${escape(dev.name)}，${escape(shownSubtitle)}"
            aria-pressed="${isOn}"
          >
            <div class="cc-tile-name">${escape(dev.name)}</div>
            <div class="cc-tile-status" title="${escape(shownSubtitle)}">${escape(shownSubtitle)}</div>
          </button>
          ${
            dev.kind.kind === "generic" && dev.kind.isReadOnly
              ? `<span class="cc-readonly-badge">${t("只读")}</span>`
              : ""
          }
          ${
            writable
              ? `<button
            class="cc-tile-orb win-subpage-power"
            data-toggle-device="${escape(dev.id)}"
            title="${t("点击直接切换开关")}"
            aria-label="${escape(t("{name} 开关", { name: dev.name }))}"
            aria-pressed="${isOn}"
          >
            ${svg}
          </button>`
              : `<span class="cc-tile-orb win-subpage-power" title="${escape(dev.name)}" aria-hidden="true">${svg}</span>`
          }
        </div>
        ${renderDeviceDrawer(dev, escape, state.deviceFacets[dev.id] ?? [], state.allowAdvancedFacetWrites, state.pendingHighRisk)}
      </div>
    `;
  }

  return `
      <div class="cc-tile is-span-row ${palette} ${isOn ? "is-active" : ""} ${isWaiting ? "is-waiting" : ""} ${hasActiveHighRisk ? "is-caution-armed" : ""} ${isExpanded ? "is-expanded" : ""} ${dev.isOnline ? "" : "is-offline"} ${staleClass} ${kind === "light" ? "is-light" : ""} ${motion}" ${attrs}>
        ${fill > 0 ? `<span class="cc-tile-fill" style="width:${fill}%;--fill-scale:${(fill / 100).toFixed(3)}"></span>` : ""}
        ${badge}
        <div class="cc-tile-header">
          ${
            dev.kind.kind === "generic" && dev.kind.isReadOnly
              ? `<span class="cc-readonly-badge">${t("只读")}</span>`
              : ""
          }
          ${
            writable
              ? `<button
            class="cc-tile-orb"
            data-toggle-device="${escape(dev.id)}"
            title="${kind === "sensor" ? escape(dev.name) : t("点击直接切换开关")}"
            aria-label="${escape(t("{name} 开关", { name: dev.name }))}"
            aria-pressed="${isOn}"
          >
            ${svg}
          </button>`
              : `<span class="cc-tile-orb" title="${escape(dev.name)}" aria-hidden="true">${svg}</span>`
          }

          <button
            class="cc-tile-body"
            data-body-device="${escape(dev.id)}"
            title="${kind === "camera" ? t("点击放大打开摄像机实时画面") : hasDrawer ? t("点击展开精细调节") : t("点击切换开关")}"
            aria-label="${escape(dev.name)}，${escape(shownSubtitle)}"
            aria-pressed="${isOn}"
          >
            <div class="cc-tile-name">${escape(dev.name)}</div>
            <div class="cc-tile-status" title="${escape(shownSubtitle)}">${escape(shownSubtitle)}</div>
          </button>

          ${
            hasDrawer && size !== "panel"
              ? `<button
                  class="cc-tile-chevron ${isExpanded ? "is-open" : ""}"
                  data-expand-device="${escape(dev.id)}"
                  title="${isExpanded ? t("收起详细控制") : t("展开详细控制")}"
                  aria-label="${isExpanded ? t("收起") : t("展开")} ${escape(t("{name} 详细控制", { name: dev.name }))}"
                  aria-expanded="${isExpanded}"
                >
                  ${SF_ICONS.chevronRight}
                </button>`
              : ""
          }
        </div>
        ${
          isExpanded && hasDrawer
            ? renderDeviceDrawer(dev, escape, state.deviceFacets[dev.id] ?? [], state.allowAdvancedFacetWrites, state.pendingHighRisk)
            : ""
        }
        ${
          !hasDrawer
            ? renderPendingHighRiskRow(dev.id, state.pendingHighRisk, escape)
            : ""
        }
      </div>
    `;
}

export function renderEnvironmentStrip(options: {
  readonly readings: readonly EnvironmentReading[];
  readonly watts: number;
  readonly valuesAreStale: boolean;
  readonly escapeHtml: (value: string) => string;
}): string {
  if (options.valuesAreStale) {
    return `<div class="cc-env-strip"><div class="cc-env-chip"><span class="cc-env-label">${t("可能过期")}</span></div></div>`;
  }
  const envChips = options.readings;
  const watts = options.watts;
  if (envChips.length === 0 && watts < 1) return "";
  return `
      <div class="cc-env-strip">
        ${envChips
          .map(
            (env) => `
          <div class="cc-env-chip">
            <span class="cc-env-icon">${SF_ICONS.sensorFill}</span>
            <span class="cc-env-label">${options.escapeHtml(env.label)}</span>
            ${env.temperature !== null ? `<strong class="cc-env-val">${formatTemperature(env.temperature, undefined, 1)}</strong>` : ""}
            ${env.humidity !== null ? `<span class="cc-env-hum">· ${Math.round(env.humidity)}%</span>` : ""}
          </div>
        `,
          )
          .join("")}
        ${
          watts >= 1
            ? `
          <div class="cc-env-chip is-power">
            <span class="cc-env-icon">${SF_ICONS.boltFill}</span>
            <strong class="cc-env-val">${Math.round(watts)}W</strong>
          </div>
        `
            : ""
        }
      </div>
    `;
}
