import { currentLanguage, resolveLanguage, type AppLanguage } from "../core/i18n.js";
import {
  ENERGY_TOP_DEVICE_LIMIT,
  formatCurrencyCost,
  formatKwhText,
  formatPriceDraftText,
  getScopedEnergyHistory,
  type EnergyDayTotal,
  type EnergyHistory,
  type EnergyScopeSource,
} from "../core/energyHistory.js";
import type { SmartDevice } from "../core/models.js";
import type { ReplyBannerState } from "./appTypes.js";
import { withAliases, type LayoutPrefs } from "./panelPrefs.js";
import type { SettingsTab, SettingsViewContext } from "./settingsViews.js";

function activeLanguage(): AppLanguage {
  return resolveLanguage(currentLanguage(), []);
}

function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  lang: AppLanguage = activeLanguage(),
): string {
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

export interface EnergyTrackableSettings extends EnergyScopeSource {
  readonly cachedXiaomiDevices?: readonly SmartDevice[];
  readonly cachedHAHome?: {
    readonly identity: string;
    readonly home: { readonly devices: readonly SmartDevice[] };
  } | null;
  readonly layout?: LayoutPrefs;
}

export interface HostEnergySession {
  clearedDevicesRef: readonly SmartDevice[] | null;
  clearedSig: string | null;
  priceDraft: string | null;
  priceFeedback: { readonly text: string; readonly isError: boolean } | null;
  confirmingClear: boolean;
}

export interface EnergyTrackableHost {
  readonly root: HTMLElement;
  readonly settings: EnergyTrackableSettings;
  devices: SmartDevice[];
  readonly layout?: LayoutPrefs;
  readonly valuesAreStale?: boolean;
  readonly haConnectionError?: string | null;
  readonly miSessionExpired?: boolean;
  readonly sourceRevision?: number;
  readonly timerSnapshot?: { readonly identity: string; readonly sourceRevision: number } | null;
  readonly lastCloudRefreshAt?: number | null;
  activeSheet?: "none" | "onboarding" | "settings";
  settingsTab?: SettingsTab;
  replyBanner?: ReplyBannerState | null;
  energySession?: HostEnergySession;
  render(): void;
}

let activeHost: EnergyTrackableHost | null = null;

export function createDefaultHostEnergySession(): HostEnergySession {
  return {
    clearedDevicesRef: null,
    clearedSig: null,
    priceDraft: null,
    priceFeedback: null,
    confirmingClear: false,
  };
}

function getHostSession(host: EnergyTrackableHost): HostEnergySession {
  if (!host.energySession) {
    host.energySession = createDefaultHostEnergySession();
  }
  return host.energySession;
}

export function notifyEnergyDevicesMutated(host: EnergyTrackableHost): void {
  const session = getHostSession(host);
  session.clearedDevicesRef = null;
  session.clearedSig = null;
}

function plugCounterSignature(devices: readonly SmartDevice[]): string {
  const parts: string[] = [];
  for (const dev of devices) {
    if (!dev.isOnline || dev.kind.kind !== "plug") continue;
    const kwh = dev.kind.energyKwh;
    if (typeof kwh === "number" && Number.isFinite(kwh) && kwh >= 0) {
      parts.push(`${dev.id}:${kwh}`);
    }
  }
  parts.sort();
  return parts.join("|");
}

function cachedDevicesForMode(settings: EnergyTrackableSettings): readonly SmartDevice[] {
  if (settings.connectionMode === "xiaomiCloud") {
    return settings.cachedXiaomiDevices ?? [];
  }
  if (settings.connectionMode === "homeAssistant") {
    return settings.cachedHAHome?.home.devices ?? [];
  }
  return [];
}

function devicesWithLayoutAliases(
  devices: readonly SmartDevice[],
  layout: LayoutPrefs | undefined,
): readonly SmartDevice[] {
  if (!layout || devices.length === 0) return devices;
  const aliased = withAliases(layout, devices);
  const roomAliases = layout.roomAliases;
  return aliased.map((dev, idx) => {
    const orig = devices[idx]!;
    const trimmedName = dev.name.trim() || orig.name;
    const roomAlias = dev.roomId && roomAliases ? roomAliases[dev.roomId]?.trim() : "";
    const effectiveRoom = roomAlias || dev.roomName;
    if (trimmedName === dev.name && effectiveRoom === dev.roomName) return dev;
    return { ...dev, name: trimmedName, roomName: effectiveRoom };
  });
}

function activeConnectedHost(): EnergyTrackableHost | null {
  if (!activeHost || !activeHost.root.isConnected) {
    activeHost = null;
    return null;
  }
  return activeHost;
}

function recordHostSnapshotIfLive(host: EnergyTrackableHost): void {
  if (!host.root.isConnected) return;
  if (host.valuesAreStale) return;
  if (host.settings.connectionMode === "homeAssistant" && Boolean(host.haConnectionError)) {
    return;
  }
  if (host.settings.connectionMode === "xiaomiCloud" && Boolean(host.miSessionExpired)) {
    return;
  }

  if (host.settings.connectionMode !== "demo") {
    const snapshotReady =
      host.timerSnapshot !== undefined &&
      host.timerSnapshot !== null &&
      host.timerSnapshot.sourceRevision === (host.sourceRevision ?? 0);
    if (!snapshotReady) {
      const cachedSig = plugCounterSignature(cachedDevicesForMode(host.settings));
      if (cachedSig !== "" && cachedSig === plugCounterSignature(host.devices)) {
        return;
      }
    }
  }

  const session = getHostSession(host);
  if (session.clearedDevicesRef !== null) {
    const stillClearedSnapshot =
      host.devices === session.clearedDevicesRef &&
      plugCounterSignature(host.devices) === session.clearedSig;
    if (stillClearedSnapshot) return;
    session.clearedDevicesRef = null;
    session.clearedSig = null;
  }

  const effectiveDevices = devicesWithLayoutAliases(
    host.devices,
    host.layout ?? host.settings.layout,
  );
  getScopedEnergyHistory(host.settings).record(effectiveDevices);
}

export function syncEnergyHostOnRender(host: EnergyTrackableHost): void {
  getHostSession(host);
  activeHost = host;
  recordHostSnapshotIfLive(host);
}

export interface PlugTodayDrawerSummary {
  readonly label: string;
  readonly kwhText: string;
  readonly costText: string | null;
}

function buildPlugTodaySummaryFromHistory(
  history: EnergyHistory,
  deviceId: string,
): PlugTodayDrawerSummary {
  const todayKwh = history.todayKwh(deviceId);
  const label = tr3("今日用电", "今日用電", "Today");
  if (todayKwh === null) {
    return { label, kwhText: "—", costText: null };
  }
  const cost = history.costForKwh(todayKwh);
  return {
    label,
    kwhText: formatKwhText(todayKwh),
    costText: cost !== null ? formatCurrencyCost(cost) : null,
  };
}

export function plugTodaySummaryForDrawer(
  dev: SmartDevice,
  hasCumulativeCounter: boolean,
): PlugTodayDrawerSummary | null {
  const host = activeConnectedHost();
  if (host) {
    recordHostSnapshotIfLive(host);
  }
  const history = getScopedEnergyHistory(host ? host.settings : { connectionMode: "demo" });
  const todayKwh = history.todayKwh(dev.id);
  if (!hasCumulativeCounter && todayKwh === null) {
    return null;
  }
  return buildPlugTodaySummaryFromHistory(history, dev.id);
}

function formatStartedAt(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  const hh = String(date.getHours()).padStart(2, "0");
  const mm = String(date.getMinutes()).padStart(2, "0");
  return `${y}-${m}-${d} ${hh}:${mm}`;
}

function formatDayChartDate(day: Date, isToday: boolean): string {
  const mm = String(day.getMonth() + 1).padStart(2, "0");
  const dd = String(day.getDate()).padStart(2, "0");
  const base = `${mm}-${dd}`;
  return isToday ? `${base} · ${tr3("今天", "今天", "Today")}` : base;
}

function barPercent(kwh: number, maxKwh: number, isObserved: boolean): number {
  if (!isObserved || !Number.isFinite(kwh) || kwh <= 0 || !Number.isFinite(maxKwh) || maxKwh <= 0) {
    return 0;
  }
  const ratio = Math.min(1, Math.max(0, kwh / maxKwh));
  return Math.max(8, Math.round(ratio * 100));
}

function renderSevenDayChart(
  daily: readonly EnergyDayTotal[],
  history: EnergyHistory,
  esc: (v: string) => string,
): string {
  const maxDayKwh = Math.max(...daily.map((d) => (Number.isFinite(d.kwh) ? d.kwh : 0)), 0.0001);
  const columns = daily
    .map((item, idx) => {
      const isToday = idx === daily.length - 1;
      const pct = barPercent(item.kwh, maxDayKwh, item.isObserved);
      const kwhLabel = item.isObserved ? formatKwhText(item.kwh) : "—";
      const dayCost = item.isObserved ? history.costForKwh(item.kwh) : null;
      const costHtml =
        dayCost !== null
          ? `<span data-energy-day-cost="${esc(item.dayKey)}" style="font-size: 9.5px; opacity: 0.72; font-variant-numeric: tabular-nums;">${esc(formatCurrencyCost(dayCost))}</span>`
          : "";
      const dateLabel = formatDayChartDate(item.day, isToday);
      const barBg = item.isObserved
        ? "var(--win-accent)"
        : "rgba(128, 128, 128, 0.18)";
      return `
        <div
          data-energy-day="${esc(item.dayKey)}"
          data-observed="${item.isObserved}"
          style="display: flex; flex-direction: column; align-items: center; gap: 3px; min-width: 0;"
        >
          <span
            data-energy-day-kwh="${esc(item.dayKey)}"
            style="font-size: 9.5px; line-height: 1.15; text-align: center; font-variant-numeric: tabular-nums; opacity: ${item.isObserved ? "0.95" : "0.55"};"
          >${esc(kwhLabel)}</span>
          <div style="width: 100%; max-width: 24px; height: 52px; border-radius: 6px; background: rgba(128, 128, 128, 0.14); display: flex; align-items: flex-end; overflow: hidden;">
            <div
              data-energy-day-bar="${esc(item.dayKey)}"
              data-bar-percent="${pct}"
              style="width: 100%; height: ${pct}%; border-radius: 6px; background: ${barBg}; transition: height 0.18s ease;"
            ></div>
          </div>
          <span
            data-energy-day-date="${esc(item.dayKey)}"
            style="font-size: 9.5px; line-height: 1.15; text-align: center; font-variant-numeric: tabular-nums; opacity: ${isToday ? "1" : "0.75"}; font-weight: ${isToday ? "600" : "400"};"
          >${esc(dateLabel)}</span>
          ${costHtml}
        </div>`;
    })
    .join("");

  return `
    <div id="settings-energy-chart" style="margin-top: 10px;">
      <div style="font-size: 11.5px; font-weight: 600; opacity: 0.85; margin-bottom: 4px;">${esc(
        tr3("近 7 日用电柱状图", "近 7 日用電柱狀圖", "Daily Usage (Last 7 Days)"),
      )}</div>
      <div style="display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 4px; align-items: end; padding: 8px 6px; border-radius: 8px; background: rgba(128, 128, 128, 0.08);">
        ${columns}
      </div>
      <p class="cc-field-hint" style="margin-top: 4px;">${esc(
        tr3(
          "显示「—」表示当天没有采样记录（应用未运行或插座未上报），不代表零用电。",
          "顯示「—」表示當天沒有取樣記錄（應用未執行或插座未回報），不代表零用電。",
          "A “—” means nothing was sampled that day (the app was closed or the plug reported nothing), not zero usage.",
        ),
      )}</p>
    </div>`;
}

function renderTopDevicesSection(
  ctx: SettingsViewContext,
  history: EnergyHistory,
  layout: LayoutPrefs | undefined,
  esc: (v: string) => string,
): string {
  const liveDevices = devicesWithLayoutAliases(ctx.devices, layout);
  const ranking = history.topDevices(7, ENERGY_TOP_DEVICE_LIMIT, liveDevices);
  if (ranking.length === 0) {
    return `
      <div id="settings-energy-ranking" style="margin-top: 10px;">
        <div style="font-size: 11.5px; font-weight: 600; opacity: 0.85; margin-bottom: 4px;">${esc(
          tr3("Top 6 耗电插座排行（近 7 天）", "Top 6 耗電插座排行（近 7 天）", "Top 6 Plugs (Last 7 Days)"),
        )}</div>
        <p class="cc-field-hint" id="settings-energy-ranking-empty" style="margin: 0;">${esc(
          tr3(
            "还没有可排行的用电增量。插座累计电量计数增长后会自动出现在这里。",
            "還沒有可排行的用電增量。插座累計電量計數增長後會自動出現在這裡。",
            "No measured increase yet. Plugs appear here once their cumulative counter grows.",
          ),
        )}</p>
      </div>`;
  }

  const rows = ranking
    .map((item, idx) => {
      const sharePct = Math.round(item.share * 100);
      const barWidthPct = Math.max(4, Math.round(item.barFraction * 100));
      const cost = history.costForKwh(item.kwh);
      const costSuffix = cost !== null ? ` · ${formatCurrencyCost(cost)}` : "";
      const roomSuffix = item.roomName ? ` · ${item.roomName}` : "";
      return `
        <div
          data-energy-rank="${idx + 1}"
          data-energy-rank-device="${esc(item.deviceId)}"
          style="display: flex; flex-direction: column; gap: 3px; padding: 5px 0;"
        >
          <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 8px; font-size: 12px;">
            <span style="min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
              <strong>#${idx + 1}</strong> ${esc(item.name)}${esc(roomSuffix)}
            </span>
            <span style="flex-shrink: 0; font-variant-numeric: tabular-nums; opacity: 0.9;">
              ${esc(formatKwhText(item.kwh))} · ${sharePct}%${esc(costSuffix)}
            </span>
          </div>
          <div style="height: 6px; width: 100%; border-radius: 999px; background: rgba(128, 128, 128, 0.14); overflow: hidden;">
            <div
              data-energy-rank-bar="${esc(item.deviceId)}"
              data-share-percent="${sharePct}"
              style="height: 100%; width: ${barWidthPct}%; border-radius: 999px; background: var(--win-accent);"
            ></div>
          </div>
        </div>`;
    })
    .join("");

  return `
    <div id="settings-energy-ranking" style="margin-top: 10px;">
      <div style="font-size: 11.5px; font-weight: 600; opacity: 0.85; margin-bottom: 4px;">${esc(
        tr3("Top 6 耗电插座排行（近 7 天）", "Top 6 耗電插座排行（近 7 天）", "Top 6 Plugs (Last 7 Days)"),
      )}</div>
      <div style="display: flex; flex-direction: column; gap: 2px;">
        ${rows}
      </div>
    </div>`;
}

export function renderEnergySettingsSection(ctx: SettingsViewContext): string {
  const esc = (raw: string) => ctx.escapeHtml(raw);
  const host = activeConnectedHost();
  if (host && host.settings === ctx.settings) {
    recordHostSnapshotIfLive(host);
  }
  const session = host ? getHostSession(host) : null;
  const history = getScopedEnergyHistory(ctx.settings);

  const daily = history.dailyTotals(7);
  const todayEntry = daily[daily.length - 1];
  const todayObserved = todayEntry?.isObserved ?? false;
  const todayKwh = todayEntry?.kwh ?? 0;
  const todayCost = todayObserved ? history.costForKwh(todayKwh) : null;

  const weekObserved = daily.some((d) => d.isObserved);
  const weekKwh = history.totalKwh(7);
  const weekCost = weekObserved ? history.costForKwh(weekKwh) : null;

  const startedAt = history.recordingStartedAt;
  let statusCopy: string;
  if (startedAt !== null) {
    const startedLabel = tr3(
      `记录开始于 ${formatStartedAt(startedAt)}`,
      `記錄開始於 ${formatStartedAt(startedAt)}`,
      `Recording since ${formatStartedAt(startedAt)}`,
    );
    statusCopy = history.hasMeasuredConsumption
      ? startedLabel
      : `${startedLabel} · ${tr3(
          "已记下基线，等待第一次电量计数增长。",
          "已記下基線，等待第一次電量計數增長。",
          "Baseline stored; waiting for the first counter increase.",
        )}`;
  } else {
    statusCopy = tr3(
      "还没有收到插座的累计电量读数。接入带电量计数的智能插座后会自动开始记录。",
      "還沒有收到插座的累計電量讀數。接入帶電量計數的智慧插座後會自動開始記錄。",
      "No plug counter reading yet. Recording starts automatically once a metering plug reports cumulative kWh.",
    );
  }

  const savedPrice = history.pricePerKwh;
  const canonicalPriceText = formatPriceDraftText(savedPrice);
  const priceInputValue = session?.priceDraft !== null && session?.priceDraft !== undefined
    ? session.priceDraft
    : canonicalPriceText;

  const priceHint =
    savedPrice === null
      ? tr3(
          "金额默认隐藏。填入每度电价后按实测电量折算电费；输入非正数会保留原电价，清空输入框并保存才会清除。",
          "金額預設隱藏。填入每度電價後按實測電量折算電費；輸入非正數會保留原電價，清空輸入框並儲存才會清除。",
          "Cost stays hidden until set. Non-positive input keeps the saved price; clear the field and save to remove it.",
        )
      : tr3(
          `当前电价：¥${canonicalPriceText} / kWh（电费 = 实测电量 × 电价，仅在本机计算）。`,
          `目前電價：¥${canonicalPriceText} / kWh（電費 = 實測電量 × 電價，僅在本機計算）。`,
          `Current tariff: ¥${canonicalPriceText} / kWh (cost = measured kWh × price, calculated locally).`,
        );

  const canClearHistory = startedAt !== null || history.hasMeasuredConsumption;
  const confirmingClear = Boolean(session?.confirmingClear && canClearHistory);

  return `
    <div class="cc-field" id="settings-energy-section" data-settings-anchor="energyHistory">
      <label>${esc(tr3("插座用电统计", "插座用電統計", "Plug Energy"))}</label>
      <p class="cc-field-hint">${esc(
        tr3(
          "仅保存在本机，基于智能插座自身累计电量（kWh）差值记账，绝不用功率估算；首次读数只建立基线，保留最近 31 天。",
          "僅儲存在本機，基於智慧插座自身累計電量（kWh）差值記帳，絕不用功率估算；首次讀數只建立基線，保留最近 31 天。",
          "Stored on this PC only from each plug's cumulative kWh counter — never estimated from wattage. First reading sets baseline; keeps 31 days.",
        ),
      )}</p>
      <p class="cc-field-hint" id="settings-energy-status" style="opacity: 0.85;">${esc(statusCopy)}</p>

      <div
        id="settings-energy-summary"
        style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 8px;"
      >
        <div
          data-energy-summary="today"
          style="padding: 8px 10px; border-radius: 8px; background: rgba(128, 128, 128, 0.09); display: flex; flex-direction: column; gap: 2px;"
        >
          <span style="font-size: 11px; opacity: 0.75;">${esc(tr3("今日用电", "今日用電", "Today"))}</span>
          <strong id="settings-energy-today-kwh" style="font-size: 15px; font-variant-numeric: tabular-nums;">${esc(
            todayObserved ? formatKwhText(todayKwh) : "—",
          )}</strong>
          ${
            todayCost !== null
              ? `<span id="settings-energy-today-cost" style="font-size: 11px; opacity: 0.8; font-variant-numeric: tabular-nums;">${esc(
                  formatCurrencyCost(todayCost),
                )}</span>`
              : ""
          }
        </div>
        <div
          data-energy-summary="week"
          style="padding: 8px 10px; border-radius: 8px; background: rgba(128, 128, 128, 0.09); display: flex; flex-direction: column; gap: 2px;"
        >
          <span style="font-size: 11px; opacity: 0.75;">${esc(tr3("最近 7 天", "最近 7 天", "Last 7 days"))}</span>
          <strong id="settings-energy-week-kwh" style="font-size: 15px; font-variant-numeric: tabular-nums;">${esc(
            weekObserved ? formatKwhText(weekKwh) : "—",
          )}</strong>
          ${
            weekCost !== null
              ? `<span id="settings-energy-week-cost" style="font-size: 11px; opacity: 0.8; font-variant-numeric: tabular-nums;">${esc(
                  formatCurrencyCost(weekCost),
                )}</span>`
              : ""
          }
        </div>
      </div>

      ${renderSevenDayChart(daily, history, esc)}
      ${renderTopDevicesSection(ctx, history, host?.layout ?? ctx.settings.layout, esc)}

      <div id="settings-energy-price-group" style="margin-top: 10px; padding-top: 8px; border-top: 1px solid rgba(128, 128, 128, 0.14);">
        <div class="cc-field-row" style="gap: 6px; flex-wrap: wrap;">
          <label for="settings-energy-price" style="margin: 0;">${esc(
            tr3("电价（每度 / kWh）", "電價（每度 / kWh）", "Price per kWh"),
          )}</label>
          <div style="display: flex; align-items: center; gap: 6px; margin-left: auto;">
            <input
              id="settings-energy-price"
              class="cc-input"
              type="text"
              inputmode="decimal"
              autocomplete="off"
              placeholder="${esc(tr3("未设置", "未設定", "Not set"))}"
              value="${esc(priceInputValue)}"
              style="width: 96px;"
            />
            <button type="button" class="cc-btn-secondary" id="btn-save-energy-price">${esc(
              tr3("保存", "儲存", "Save"),
            )}</button>
            ${
              savedPrice !== null
                ? `<button type="button" class="cc-inline-pill" id="btn-clear-energy-price">${esc(
                    tr3("清除", "清除", "Clear"),
                  )}</button>`
                : ""
            }
          </div>
        </div>
        ${
          session?.priceFeedback
            ? `<p class="cc-field-hint" id="settings-energy-price-feedback" style="margin-top: 4px; color: ${
                session.priceFeedback.isError ? "#e67e22" : "inherit"
              };">${esc(session.priceFeedback.text)}</p>`
            : ""
        }
        <p class="cc-field-hint" id="settings-energy-price-hint" style="margin-top: 4px;">${esc(priceHint)}</p>
      </div>

      <div id="settings-energy-clear-group" style="margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(128, 128, 128, 0.14);">
        <div class="cc-field-row" style="gap: 8px;">
          <p class="cc-field-hint" style="margin: 0; flex: 1;">${esc(
            tr3(
              "清空将删除全部已记录的电量与基线，从下一次读数重新开始累计；电价设置会保留。",
              "清空將刪除全部已記錄的電量與基線，從下一次讀數重新開始累計；電價設定會保留。",
              "Clearing deletes all recorded samples and baselines so the next reading starts fresh; your price is kept.",
            ),
          )}</p>
          <button
            type="button"
            class="cc-btn-danger"
            id="btn-clear-energy-history"
            ${canClearHistory ? "" : "disabled"}
          >${esc(tr3("清空用电统计", "清空用電統計", "Clear Energy History"))}</button>
        </div>
        <div
          id="settings-clear-energy-confirm"
          class="cc-update-row"
          ${confirmingClear ? "" : "hidden"}
          role="alert"
          style="margin-top: 6px; padding: 8px; border-radius: 8px; background: rgba(231, 76, 60, 0.14); gap: 6px; flex-wrap: wrap;"
        >
          <span style="font-size: 12px;">${esc(
            tr3(
              "确认清空全部用电统计记录与基线？此操作不可撤销（已设置的电价会保留）。",
              "確認清空全部用電統計記錄與基線？此操作無法復原（已設定的電價會保留）。",
              "Clear all recorded energy history and baselines? This cannot be undone (your electricity price is kept).",
            ),
          )}</span>
          <div style="display: flex; gap: 6px; margin-left: auto;">
            <button type="button" class="cc-btn-secondary" id="btn-cancel-clear-energy">${esc(
              tr3("取消", "取消", "Cancel"),
            )}</button>
            <button type="button" class="cc-btn-danger" id="btn-confirm-clear-energy">${esc(
              tr3("确认清空", "確認清空", "Clear History"),
            )}</button>
          </div>
        </div>
      </div>
    </div>
  `;
}

export function bindEnergySettingsEvents(host: EnergyTrackableHost): void {
  const session = getHostSession(host);
  if (host.activeSheet !== "settings") {
    session.confirmingClear = false;
    session.priceDraft = null;
    session.priceFeedback = null;
    return;
  }
  if (host.settingsTab !== "system") {
    session.confirmingClear = false;
  }

  const clearConfirmEl = host.root.querySelector<HTMLElement>("#settings-clear-energy-confirm");
  host.root.querySelectorAll<HTMLElement>("[data-settings-tab]").forEach((tabBtn) => {
    tabBtn.addEventListener("click", () => {
      if (tabBtn.dataset.settingsTab !== "system") {
        session.confirmingClear = false;
        if (clearConfirmEl) clearConfirmEl.hidden = true;
      }
    });
  });

  const priceInput = host.root.querySelector<HTMLInputElement>("#settings-energy-price");
  const commitPriceFromInput = (): void => {
    const raw = priceInput ? priceInput.value : "";
    const history = getScopedEnergyHistory(host.settings);
    const outcome = history.applyPriceInput(raw);
    session.priceDraft = null;
    if (outcome.action === "kept") {
      session.priceFeedback = {
        text: tr3(
          "请输入大于 0 的有效电价；输入无效内容已保留原电价设置。",
          "請輸入大於 0 的有效電價；輸入無效內容已保留原電價設定。",
          "Enter a valid positive price; kept your previous price setting.",
        ),
        isError: true,
      };
    } else if (outcome.action === "cleared") {
      session.priceFeedback = null;
    } else {
      session.priceFeedback = null;
    }
    host.render();
  };

  priceInput?.addEventListener("input", () => {
    session.priceDraft = priceInput.value;
    if (session.priceFeedback) {
      session.priceFeedback = null;
    }
  });

  priceInput?.addEventListener("keydown", (event: KeyboardEvent) => {
    if (event.key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
      commitPriceFromInput();
    }
  });

  host.root.querySelector("#btn-save-energy-price")?.addEventListener("click", () => {
    commitPriceFromInput();
  });

  host.root.querySelector("#btn-clear-energy-price")?.addEventListener("click", () => {
    const history = getScopedEnergyHistory(host.settings);
    history.setPricePerKwh(null);
    session.priceDraft = null;
    session.priceFeedback = null;
    host.render();
  });

  host.root.querySelector("#btn-clear-energy-history")?.addEventListener("click", () => {
    session.confirmingClear = true;
    if (clearConfirmEl) clearConfirmEl.hidden = false;
  });

  host.root.querySelector("#btn-cancel-clear-energy")?.addEventListener("click", () => {
    session.confirmingClear = false;
    if (clearConfirmEl) clearConfirmEl.hidden = true;
  });

  host.root.querySelector("#btn-confirm-clear-energy")?.addEventListener("click", () => {
    session.confirmingClear = false;
    session.clearedDevicesRef = host.devices;
    session.clearedSig = plugCounterSignature(host.devices);
    const history = getScopedEnergyHistory(host.settings);
    history.clear();
    host.replyBanner = {
      text: tr3("已清除用电记录", "已清除用電記錄", "Energy history cleared"),
      source: tr3("插座用电统计", "插座用電統計", "Plug Energy"),
    };
    host.render();
  });
}
