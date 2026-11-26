import {
  ASSISTANT_PROVIDER_PRESETS,
  inferAssistantPreset,
  isAiAssistantEnabled,
  isProactiveSuggestionsEnabled,
  listReadableHabits,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import { speechLocale, t, tr3 } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { quickActionTitle, trText } from "../core/quickActions.js";
import {
  MAX_CUSTOM_HOTKEY_BINDINGS,
  allQuickActionIds,
  encodeHotkeyTargetKey,
  isHotkeyBindingTargetAvailable,
  normalizeCustomHotkeyBindings,
  resolvedHotkeyBindingLabel,
} from "./hotkeyBindings.js";
import {
  getUpdateProgressForSettings,
  hasPendingMiVaultDeletion,
  isSpeechRecognitionSupported,
  isVoiceInputEnabled,
  type CompanionNotice,
  type UpdateDownloadProgress,
} from "./speechGuard.js";
import { isPlainHttpRemoteEndpoint } from "./haEndpoint.js";
import type { GitHubRelease } from "../core/updateChecker.js";
import type { MoodSnapshot } from "../core/moodSnapshot.js";
import type { QRLoginTicket } from "../core/miCloudClient.js";
import {
  MI_CLOUD_REGIONS,
  maskedMiUserId,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import { deviceCanTogglePower, joinsAllOff, type HomeScene, type SmartDevice } from "../core/models.js";
import { isScheduledCommandsEnabled } from "../core/scheduledCommands.js";
import {
  APPEARANCES,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  PANEL_HEIGHTS,
  PANEL_OPACITY_MAX,
  PANEL_OPACITY_MIN,
  hiddenDeviceIds,
  roomDisplayName,
  type LayoutPrefs,
  type PanelAnchor,
} from "./panelPrefs.js";
import type { EnergyScopeSource } from "../core/energyHistory.js";
import type { HostActivityCenter } from "./activityStackView.js";
import type { PersistedSettings } from "./appTypes.js";
import { APP_VERSION, SF_ICONS } from "./appConstants.js";
import { renderAutomationAndSafetySettingsSections, type HostAutoSafetySession } from "./automationSettingsView.js";
import {
  readCustomHomeTitle,
  renderConnectionsAndDiagSection,
  renderCustomHomeTitleField,
  type ConnectionsAndDiagHost,
} from "./connectionsAndDiagView.js";
import { renderEnergySettingsSection, type HostEnergySession } from "./energySettingsView.js";
import { getDdcDisplayController, renderDdcSettingsSection } from "./ddcDisplaySection.js";
import { readAskWhenUnsure } from "./settings.js";

/** The five Settings categories aligned with macOS System Settings. */
export type SettingsTab = "general" | "connection" | "assistant" | "safety" | "about";

export function normalizeSettingsTab(raw: unknown): SettingsTab {
  switch (raw) {
    case "connection":
    case "assistant":
    case "safety":
    case "about":
      return raw;
    case "system":
      return "safety";
    default:
      return "general";
  }
}

export interface SettingsTabSpec {
  readonly id: SettingsTab;
  readonly title: string;
  readonly icon: string;
  readonly color: string;
  readonly subtitle: () => string;
}

/** Tab bar order; `title` is the catalog key, so a missing translation would fail i18n.test.ts. */
const SETTINGS_TABS: ReadonlyArray<SettingsTabSpec> = [
  {
    id: "general",
    title: "常规",
    icon: SF_ICONS.sliderHorizontal,
    color: "#737885",
    subtitle: () =>
      tr3(
        "托盘外观、设备卡片、面板主题与快捷键。",
        "托盤外觀、裝置卡片、面板主題與快速鍵。",
        "Appearance, device cards, panel theme, and shortcuts.",
      ),
  },
  {
    id: "connection",
    title: "家居连接",
    icon: SF_ICONS.globe,
    color: "#007aff",
    subtitle: () =>
      tr3(
        "连接 Home Assistant 与米家云端，管理多账号与设备扫描。",
        "連接 Home Assistant 與米家雲端，管理多帳號與裝置掃描。",
        "Connect Home Assistant and Xiaomi Cloud, manage accounts, and scan devices.",
      ),
  },
  {
    id: "assistant",
    title: "AI 助手",
    icon: SF_ICONS.sparkles,
    color: "#705ce6",
    subtitle: () =>
      tr3(
        "配置 AI 服务与建议偏好",
        "設定 AI 服務與建議偏好",
        "AI service and suggestion preferences",
      ),
  },
  {
    id: "safety",
    title: "安全与提醒",
    icon: SF_ICONS.shieldCheck,
    color: "#219e6b",
    subtitle: () =>
      tr3(
        "锁屏控制、守护提醒、用电统计、定时与全关范围。",
        "鎖定螢幕控制、守護提醒、用電統計、定時與全關範圍。",
        "Lock-screen protection, alerts, energy, schedules, and All Off scope.",
      ),
  },
  {
    id: "about",
    title: "关于与诊断",
    icon: SF_ICONS.activityPulse,
    color: "#999ea8",
    subtitle: () =>
      tr3(
        "软件更新、当前版本、排障入口、重置与退出应用。",
        "軟體更新、目前版本、排障入口、重設與結束應用。",
        "Updates, app version, diagnostics shortcuts, sign out, and quitting.",
      ),
  },
];

export function getSettingsTabSpec(tab: SettingsTab): SettingsTabSpec {
  const normalized = normalizeSettingsTab(tab);
  return SETTINGS_TABS.find((spec) => spec.id === normalized) ?? SETTINGS_TABS[0]!;
}

/**
 * Text fields whose typed text a live re-render must not throw away. The panels all stay in the
 * DOM, so switching tabs already keeps a draft; these ids cover the refresh-driven rebuilds.
 */
const DRAFT_VALUE_IDS: readonly string[] = [
  "settings-custom-home-title",
  "settings-ha-url",
  "settings-ha-token",
  "settings-base-url",
  "settings-model",
  "settings-api-key",
  "settings-habit-share-sample",
];

/** Switches whose flipped state is a draft until 完成并保存 reads it. */
const DRAFT_CHECK_IDS: readonly string[] = ["settings-habit", "settings-habit-share"];

export interface SettingsDraft {
  readonly values: ReadonlyArray<readonly [string, string]>;
  readonly checks: ReadonlyArray<readonly [string, boolean]>;
  readonly openConnSections?: ReadonlyArray<string>;
  readonly unsavedConfirmOpen?: boolean;
}

/** Captures the drafts of an open Settings sheet; `null` when no settings sheet is mounted. */
export function captureSettingsDraft(root: HTMLElement): SettingsDraft | null {
  if (!root.querySelector(".cc-settings-sheet")) return null;
  const values: Array<readonly [string, string]> = [];
  for (const id of DRAFT_VALUE_IDS) {
    const field = root.querySelector<HTMLInputElement>(`#${id}`);
    if (field && field.value !== field.defaultValue) values.push([id, field.value]);
  }
  const checks: Array<readonly [string, boolean]> = [];
  for (const id of DRAFT_CHECK_IDS) {
    const field = root.querySelector<HTMLInputElement>(`#${id}`);
    if (field && field.checked !== field.defaultChecked) checks.push([id, field.checked]);
  }
  const openConnSections: string[] = [];
  root.querySelectorAll<HTMLDetailsElement>("details.cc-conn-secondary[data-conn-section]").forEach((details) => {
    if (details.open && details.dataset.connSection) {
      openConnSections.push(details.dataset.connSection);
    }
  });
  const unsavedBar = root.querySelector<HTMLElement>("#settings-unsaved-confirm");
  const unsavedConfirmOpen = Boolean(unsavedBar && !unsavedBar.hidden);
  return { values, checks, openConnSections, unsavedConfirmOpen };
}

/**
 * Puts the drafts back after a re-render. Returns true when the habit-share sample carried text and
 * the preview under it therefore has to be recomputed.
 */
export function restoreSettingsDraft(
  root: HTMLElement,
  draft: SettingsDraft | null,
  syncKeyField?: (apiKeyEl: HTMLInputElement, baseURL: string) => void,
): boolean {
  if (!draft) return false;
  const hasKeyDraft = draft.values.some(([id]) => id === "settings-api-key");
  for (const [id, value] of draft.values) {
    const field = root.querySelector<HTMLInputElement>(`#${id}`);
    if (field) field.value = value;
  }
  for (const [id, checked] of draft.checks) {
    const field = root.querySelector<HTMLInputElement>(`#${id}`);
    if (field) field.checked = checked;
  }
  for (const section of draft.openConnSections ?? []) {
    const details = root.querySelector<HTMLDetailsElement>(
      `details.cc-conn-secondary[data-conn-section="${section}"]`,
    );
    if (details) details.open = true;
  }
  const unsavedBar = root.querySelector<HTMLElement>("#settings-unsaved-confirm");
  if (unsavedBar) {
    unsavedBar.hidden = !draft.unsavedConfirmOpen;
  }
  const haUrlEl = root.querySelector<HTMLInputElement>("#settings-ha-url");
  if (haUrlEl) {
    const warnEl = root.querySelector<HTMLElement>("[data-ha-plaintext-warning]");
    if (warnEl) {
      warnEl.hidden = !isPlainHttpRemoteEndpoint(haUrlEl.value);
    }
    const fillBtn = root.querySelector<HTMLButtonElement>("#btn-fill-default-ha");
    if (fillBtn) {
      fillBtn.disabled = haUrlEl.value.trim().length > 0;
    }
  }
  const baseEl = root.querySelector<HTMLInputElement>("#settings-base-url");
  if (baseEl) {
    const preset = inferAssistantPreset(baseEl.value);
    const providerEl = root.querySelector<HTMLSelectElement>("#settings-ai-provider");
    if (providerEl) providerEl.value = preset.id;
    const restoreDefaultsBtn = root.querySelector<HTMLButtonElement>("#btn-restore-ai-provider-defaults");
    if (restoreDefaultsBtn) restoreDefaultsBtn.hidden = preset.id === "custom";
    const apiKeyEl = root.querySelector<HTMLInputElement>("#settings-api-key");
    if (apiKeyEl) {
      apiKeyEl.placeholder = preset.keyPlaceholder;
      if (!hasKeyDraft && syncKeyField) {
        syncKeyField(apiKeyEl, baseEl.value);
      }
    }
  }
  return (draft.values.find(([id]) => id === "settings-habit-share-sample")?.[1] ?? "") !== "";
}

export interface SettingsViewContext {
  readonly settings: PersistedSettings;
  readonly devices: readonly SmartDevice[];
  readonly scenes?: readonly HomeScene[];
  readonly moods?: readonly MoodSnapshot[];
  readonly availableUpdate: GitHubRelease | null;
  readonly activeTab: SettingsTab;
  readonly apiKeyFor: (baseURL: string) => string;
  readonly habitSequences: () => readonly HabitSequenceEntry[];
  readonly hotkeyNeedsHint: boolean;
  readonly hotkeyRegistrationError: string | null;
  readonly isPollingQR: boolean;
  readonly isRecordingHotkey: boolean;
  readonly isRecordingCustomHotkeyId?: string | null;
  readonly customHotkeyConflictError?: string | null;
  readonly customHotkeyRegistrationErrors?: Readonly<Record<string, string>>;
  readonly isAddingCustomHotkey?: boolean;
  readonly newCustomHotkeyTargetKey?: string;
  readonly panelAnchor: PanelAnchor;
  readonly qrStatusText: string;
  readonly qrTicket: QRLoginTicket | null;
  readonly isCheckingUpdate: boolean;
  readonly isInstallingUpdate: boolean;
  readonly updateStatusMessage: { text: string; isError: boolean } | null;
  readonly updateProgress?: UpdateDownloadProgress | null;
  readonly energyScope?: EnergyScopeSource;
  readonly energySession?: HostEnergySession;
  readonly autoSafetySession?: HostAutoSafetySession;
  readonly activityCenter?: HostActivityCenter | null;
  readonly sourceRevision?: number;
  readonly connDiagHost?: ConnectionsAndDiagHost;
  readonly layout?: LayoutPrefs;
  /**
   * The device-type block (P4b-W). `html` re-reads the host's live selection and references, so it is
   * built on demand; `key` makes an inactive-tab cache notice when the draft changed.
   */
  readonly deviceTypes?: { readonly key: string; readonly html: () => string };
  /** The last 复制配置 / 检测接入 / 断开 result for the companion integration (P6a-W). */
  readonly companionNotice?: CompanionNotice | null;
  escapeHtml(value: string): string;
}

  /**
   * Two-column macOS System Settings layout inside `.cc-settings-sheet`: translucent left rail
   * (search + 5 colored category rows) beside the scrollable detail pane and bottom save bar.
   * Every panel stays mounted behind `hidden`, so drafts survive tab switches.
   */
  export function renderSettingsModal(ctx: SettingsViewContext): string {
    const activeTab = normalizeSettingsTab(ctx.activeTab);
    const activeSpec = getSettingsTabSpec(activeTab);
    const searchPlaceholder = tr3(
      "搜索设置",
      "搜尋設定",
      "Search",
    );
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet cc-settings-sheet" role="dialog" aria-modal="true" aria-label="${ctx.escapeHtml(tr3("设置", "設定", "Settings"))}">
          <button class="cc-circle-btn is-small cc-settings-close-btn" id="btn-close-settings" title="${t("返回控制中心")}" aria-label="${t("返回控制中心")}">
            ${SF_ICONS.xmark}
          </button>

          <div class="cc-settings-shell">
            <aside class="cc-settings-sidebar">
              <div class="cc-settings-search">
                <div class="cc-settings-search-box">
                  <span class="cc-settings-search-icon" aria-hidden="true">${SF_ICONS.search}</span>
                  <input
                    id="settings-search-input"
                    class="cc-settings-search-input"
                    type="search"
                    autocomplete="off"
                    placeholder="${ctx.escapeHtml(searchPlaceholder)}"
                    aria-label="${ctx.escapeHtml(tr3("搜索设置", "搜尋設定", "Search Settings"))}"
                  />
                  <button
                    type="button"
                    class="cc-inline-pill"
                    id="btn-clear-settings-search"
                    hidden
                    aria-label="${ctx.escapeHtml(tr3("清空搜索", "清空搜尋", "Clear Search"))}"
                  >${ctx.escapeHtml(tr3("清空", "清空", "Clear"))}</button>
                </div>
                <div
                  id="settings-search-results"
                  class="cc-settings-search-results"
                  role="listbox"
                  hidden
                ></div>
              </div>

              <div class="cc-settings-nav cc-settings-tabs" role="tablist" aria-orientation="vertical" aria-label="${t("设置分类")}">
                ${SETTINGS_TABS.map((tab) => {
                  const active = tab.id === activeTab;
                  return `<button type="button" class="cc-settings-nav-item ${active ? "is-active" : ""}" data-settings-tab="${tab.id}" role="tab" aria-selected="${active}"><span class="cc-settings-icon-tile" style="--tile-bg: ${tab.color}" aria-hidden="true">${tab.icon}</span><span class="cc-settings-nav-label">${ctx.escapeHtml(t(tab.title))}</span>${tab.id === "about" && ctx.availableUpdate ? '<span class="cc-settings-nav-dot" aria-hidden="true"></span>' : ""}</button>`;
                }).join("")}
              </div>
            </aside>

            <div class="cc-settings-main">
              <div class="cc-settings-pane-header" data-settings-pane-header>
                <span class="cc-settings-icon-tile is-large" id="settings-pane-icon" style="--tile-bg: ${activeSpec.color}" aria-hidden="true">${activeSpec.icon}</span>
                <div class="cc-settings-pane-copy">
                  <h2 class="cc-settings-pane-title" id="settings-pane-title">${ctx.escapeHtml(t(activeSpec.title))}</h2>
                  <p class="cc-settings-pane-subtitle" id="settings-pane-subtitle">${ctx.escapeHtml(activeSpec.subtitle())}</p>
                </div>
              </div>

              <div
                id="settings-unsaved-confirm"
                class="cc-update-row cc-settings-unsaved-bar"
                hidden
                role="alert"
              >
                <span style="font-size: 12px;">${ctx.escapeHtml(
                  tr3(
                    "有未保存的设置修改，是否保存？",
                    "有未儲存的設定修改，是否儲存？",
                    "You have unsaved settings changes. Save before closing?",
                  ),
                )}</span>
                <div style="display: flex; gap: 6px; margin-left: auto;">
                  <button type="button" class="cc-btn-secondary" id="btn-cancel-close-settings">${ctx.escapeHtml(
                    tr3("继续编辑", "繼續編輯", "Keep Editing"),
                  )}</button>
                  <button type="button" class="cc-btn-danger" id="btn-discard-settings">${ctx.escapeHtml(
                    tr3("放弃未保存修改", "放棄未儲存修改", "Discard Changes"),
                  )}</button>
                  <button type="button" class="cc-btn-primary" id="btn-confirm-save-settings">${ctx.escapeHtml(
                    tr3("保存并关闭", "儲存並關閉", "Save & Close"),
                  )}</button>
                </div>
              </div>

              <div class="cc-sheet-body cc-settings-detail">
                ${renderSettingsTabPanel(ctx, "general", renderGeneralPanel, activeTab)}
                ${renderSettingsTabPanel(ctx, "connection", renderConnectionPanel, activeTab)}
                ${renderSettingsTabPanel(ctx, "assistant", renderAssistantPanel, activeTab)}
                ${renderSettingsTabPanel(ctx, "safety", renderSafetyPanel, activeTab)}
                ${renderSettingsTabPanel(ctx, "about", renderAboutPanel, activeTab)}
              </div>

              <div class="cc-sheet-footer">
                <span class="cc-settings-save-hint" data-save-state="clean" title="${ctx.escapeHtml(trText("开关即时生效，地址与密钥点右侧保存", "Toggles apply instantly; click Save for URLs & keys"))}">${ctx.escapeHtml(trText("开关已即时生效", "Toggles auto-save"))}</span>
                <button class="cc-btn-primary" id="btn-save-settings">${t("完成并保存")}</button>
              </div>
            </div>
          </div>
        </div>
      </div>
    `;
  }

const inactiveTabHtmlCache = new Map<SettingsTab, { key: string; html: string }>();

export function buildInactiveTabCacheKey(ctx: SettingsViewContext, tabId: SettingsTab): string | null {
  if (tabId === "general") {
    const layout = ctx.layout ?? ctx.settings.layout;
    return JSON.stringify([
      t("外观模式"), ctx.availableUpdate, ctx.isCheckingUpdate, ctx.isInstallingUpdate, ctx.updateStatusMessage,
      ctx.updateProgress ?? getUpdateProgressForSettings(ctx.settings), ctx.settings.autoCheckUpdates,
      ctx.settings.appearance, ctx.settings.panelTheme, ctx.settings.panelOpacity, ctx.settings.interfaceLanguage,
      ctx.settings.temperatureUnit, ctx.settings.panelHeight, ctx.panelAnchor, ctx.settings.climatePanel,
      ctx.settings.isCompactGridMode, ctx.settings.hideOfflineDevices, ctx.settings.hideGroupedLights, ctx.settings.showQuickActionsBar, ctx.settings.showHomeSummaryRow,
      ctx.deviceTypes?.key,
      ctx.settings.launchAtLogin, ctx.settings.enableGlobalHotkey, ctx.settings.globalHotkey,
      ctx.settings.customHotkeyBindings, ctx.isRecordingCustomHotkeyId, ctx.customHotkeyConflictError,
      ctx.customHotkeyRegistrationErrors, ctx.isAddingCustomHotkey, ctx.newCustomHotkeyTargetKey,
      (ctx.moods ?? []).map((m) => [m.id, m.name]),
      ctx.isRecordingHotkey, ctx.hotkeyNeedsHint, ctx.hotkeyRegistrationError,
      readCustomHomeTitle(ctx.settings), ctx.connDiagHost?.connDiagSession?.titleDraft,
      ctx.connDiagHost?.homeTitle, ctx.settings.selectedHomeId, ctx.connDiagHost?.homes.map((h) => [h.id, h.name]),
      hiddenDeviceIds(layout), layout?.aliases, layout?.roomAliases, ctx.devices.map((d) => [d.id, d.name, d.roomId, d.roomName]),
    ]);
  }
  if (tabId === "assistant") {
    return JSON.stringify([
      t("服务商"),
      ctx.settings.assistantBaseURL, ctx.settings.assistantModel, ctx.apiKeyFor(ctx.settings.assistantBaseURL),
      readAskWhenUnsure(ctx.settings), ctx.settings.cloudConsentEndpoints, ctx.settings.habitLearningEnabled,
      ctx.settings.habitShareEnabled, ctx.settings.learnedShortcuts, ctx.settings.habitEntries,
      ctx.habitSequences(), ctx.devices.map((d) => [d.id, d.name]), (ctx.scenes ?? []).map((s) => [s.id, s.name]),
    ]);
  }
  return null;
}

function renderSettingsTabPanel(
  ctx: SettingsViewContext,
  tabId: SettingsTab,
  renderBody: (ctx: SettingsViewContext) => string,
  activeTab: SettingsTab = normalizeSettingsTab(ctx.activeTab),
): string {
  const hidden = activeTab !== tabId ? "hidden" : "";
  const cacheKey = buildInactiveTabCacheKey(ctx, tabId);
  if (activeTab !== tabId && cacheKey !== null) {
    const cached = inactiveTabHtmlCache.get(tabId);
    if (cached && cached.key === cacheKey) {
      return `<div class="cc-settings-tab-panel" role="tabpanel" data-settings-panel="${tabId}" ${hidden}>${cached.html}</div>`;
    }
  }
  const innerHtml = renderBody(ctx);
  if (cacheKey !== null) {
    inactiveTabHtmlCache.set(tabId, { key: cacheKey, html: innerHtml });
  }
  return `<div class="cc-settings-tab-panel" role="tabpanel" data-settings-panel="${tabId}" ${hidden}>${innerHtml}</div>`;
}

function renderCustomHotkeyBindingsSection(ctx: SettingsViewContext): string {
  const bindings = normalizeCustomHotkeyBindings(ctx.settings.customHotkeyBindings);
  const scenes = ctx.scenes ?? [];
  const moods = ctx.moods ?? [];
  const toggleableDevices = ctx.devices.filter((d) => deviceCanTogglePower(d));
  const regErrors = ctx.customHotkeyRegistrationErrors ?? {};
  const recordingId = ctx.isRecordingCustomHotkeyId ?? null;
  const isAdding = Boolean(ctx.isAddingCustomHotkey);

  const rowsHtml = bindings
    .map((binding) => {
      const available = isHotkeyBindingTargetAvailable(binding, ctx.devices, scenes, moods);
      const label = resolvedHotkeyBindingLabel(binding, ctx.devices, scenes, moods);
      const isRec = recordingId === binding.id;
      const err = regErrors[binding.id];
      return `<div class="cc-custom-hotkey-row" style="margin-top: 6px;">
        <div class="cc-update-row">
          <span style="display:flex;align-items:center;gap:6px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
            <span${available ? "" : ' style="opacity:0.65;"'}>${ctx.escapeHtml(label)}</span>
            ${available ? "" : `<span class="cc-field-hint" style="color:#e67e22;margin:0;">${ctx.escapeHtml(tr3("已失效", "已失效", "Unavailable"))}</span>`}
          </span>
          <div style="display:flex;gap:6px;align-items:center;flex-shrink:0;">
            <button type="button" class="cc-seg-pill ${isRec ? "is-active" : ""}" data-custom-hotkey-record="${ctx.escapeHtml(binding.id)}" aria-pressed="${isRec}">${isRec ? t("按下组合…") : ctx.escapeHtml(binding.shortcut)}</button>
            <button type="button" class="cc-btn-secondary" data-custom-hotkey-remove="${ctx.escapeHtml(binding.id)}" title="${ctx.escapeHtml(tr3("移除此热键", "移除此熱鍵", "Remove hotkey"))}">×</button>
          </div>
        </div>
        ${err ? `<p class="cc-field-hint" style="color:#e67e22;margin:2px 0 0;">${ctx.escapeHtml(err)}</p>` : ""}
      </div>`;
    })
    .join("");

  let addHtml = "";
  if (isAdding) {
    const selectedKey =
      ctx.newCustomHotkeyTargetKey ||
      (toggleableDevices[0]
        ? encodeHotkeyTargetKey({ kind: "devicePower", deviceId: toggleableDevices[0].id })
        : scenes[0]
          ? encodeHotkeyTargetKey({ kind: "scene", sceneId: scenes[0].id })
          : moods[0]
            ? encodeHotkeyTargetKey({ kind: "mood", moodId: moods[0].id })
            : encodeHotkeyTargetKey({ kind: "quickAction", actionId: "lightsOff" }));
    const deviceOpts = toggleableDevices
      .map((d) => {
        const val = encodeHotkeyTargetKey({ kind: "devicePower", deviceId: d.id });
        return `<option value="${ctx.escapeHtml(val)}" ${val === selectedKey ? "selected" : ""}>${ctx.escapeHtml(d.name)}</option>`;
      })
      .join("");
    const sceneOpts = scenes
      .map((s) => {
        const val = encodeHotkeyTargetKey({ kind: "scene", sceneId: s.id });
        return `<option value="${ctx.escapeHtml(val)}" ${val === selectedKey ? "selected" : ""}>${ctx.escapeHtml(s.name)}</option>`;
      })
      .join("");
    const moodOpts = moods
      .map((m) => {
        const val = encodeHotkeyTargetKey({ kind: "mood", moodId: m.id });
        return `<option value="${ctx.escapeHtml(val)}" ${val === selectedKey ? "selected" : ""}>${ctx.escapeHtml(m.name)}</option>`;
      })
      .join("");
    const quickOpts = allQuickActionIds()
      .map((id) => {
        const val = encodeHotkeyTargetKey({ kind: "quickAction", actionId: id });
        return `<option value="${ctx.escapeHtml(val)}" ${val === selectedKey ? "selected" : ""}>${ctx.escapeHtml(quickActionTitle(id))}</option>`;
      })
      .join("");
    const isRecNew = recordingId === "__new__";
    addHtml = `<div class="cc-update-row" style="margin-top:8px;gap:6px;">
      <select id="select-custom-hotkey-target" class="cc-input" style="flex:1;min-width:0;">
        ${deviceOpts ? `<optgroup label="${ctx.escapeHtml(tr3("设备开关", "裝置開關", "Device Power"))}">${deviceOpts}</optgroup>` : ""}
        ${sceneOpts ? `<optgroup label="${ctx.escapeHtml(tr3("场景", "場景", "Scenes"))}">${sceneOpts}</optgroup>` : ""}
        ${moodOpts ? `<optgroup label="${ctx.escapeHtml(tr3("氛围", "氛圍", "Moods"))}">${moodOpts}</optgroup>` : ""}
        <optgroup label="${ctx.escapeHtml(tr3("快捷操作", "快捷操作", "Quick Actions"))}">${quickOpts}</optgroup>
      </select>
      <button type="button" class="cc-seg-pill ${isRecNew ? "is-active" : ""}" id="btn-record-new-custom-hotkey" aria-pressed="${isRecNew}">${isRecNew ? t("按下组合…") : ctx.escapeHtml(tr3("录制快捷键", "錄製快捷鍵", "Record Key"))}</button>
      <button type="button" class="cc-btn-secondary" id="btn-cancel-new-custom-hotkey">${t("取消")}</button>
    </div>`;
  }

  return `<div style="margin-top:10px;padding-top:10px;border-top:1px solid rgba(128,128,128,0.16);">
    <div class="cc-update-row">
      <span>${ctx.escapeHtml(tr3("单设备 / 场景全局热键", "單裝置 / 場景全域快捷鍵", "Device & Scene Global Hotkeys"))} <span class="cc-field-hint" style="margin:0;">${bindings.length}/${MAX_CUSTOM_HOTKEY_BINDINGS}</span></span>
      ${!isAdding && bindings.length < MAX_CUSTOM_HOTKEY_BINDINGS ? `<button type="button" class="cc-btn-secondary" id="btn-add-custom-hotkey">${ctx.escapeHtml(tr3("+ 添加热键", "+ 新增熱鍵", "+ Add Hotkey"))}</button>` : ""}
    </div>
    ${rowsHtml}
    ${addHtml}
    ${ctx.customHotkeyConflictError ? `<p class="cc-field-hint" id="custom-hotkey-conflict-msg" style="color:#e67e22;margin:6px 0 0;">${ctx.escapeHtml(ctx.customHotkeyConflictError)}</p>` : ""}
  </div>`;
}

function renderGeneralHiddenDevicesRestore(ctx: SettingsViewContext): string {
  const layout = ctx.layout ?? ctx.settings.layout;
  const hiddenIds = new Set(hiddenDeviceIds(layout));
  if (hiddenIds.size === 0) return "";
  const hiddenList = ctx.devices.filter((d) => hiddenIds.has(d.id));
  if (hiddenList.length === 0) return "";
  return `
    <div class="cc-hidden-devices-restore" style="margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(128, 128, 128, 0.14); display: flex; flex-direction: column; gap: 6px;">
      <div class="cc-field-row" style="flex-wrap: wrap;">
        <span class="cc-field-hint" style="margin: 0;">${ctx.escapeHtml(
          tr3(
            `已手动隐藏 ${hiddenList.length} 台设备`,
            `已手動隱藏 ${hiddenList.length} 台裝置`,
            `${hiddenList.length} manually hidden device(s)`,
          ),
        )}</span>
        ${
          hiddenList.length > 1
            ? `<button type="button" class="cc-inline-pill" id="btn-settings-unhide-all-devices">${ctx.escapeHtml(
                tr3("全部恢复显示", "全部恢復顯示", "Unhide All"),
              )}</button>`
            : ""
        }
      </div>
      <div style="display: flex; flex-direction: column; gap: 4px;">
        ${hiddenList
          .map((dev) => {
            const id = ctx.escapeHtml(dev.id);
            const name = ctx.escapeHtml(layout?.aliases?.[dev.id] ?? dev.name);
            const room = ctx.escapeHtml(roomDisplayName(layout, dev.roomId, dev.roomName));
            return `<div class="cc-field-row" style="padding: 4px 8px; border-radius: 6px; background: rgba(128, 128, 128, 0.08);">
              <span style="min-width: 0; overflow: hidden; text-overflow: ellipsis;">${name}${room ? ` · ${room}` : ""}</span>
              <button type="button" class="cc-inline-pill" data-unhide-device="${id}">${ctx.escapeHtml(
                tr3("恢复显示", "恢復顯示", "Restore"),
              )}</button>
            </div>`;
          })
          .join("")}
      </div>
    </div>`;
}

function renderGeneralPanel(ctx: SettingsViewContext): string {
  return `
    ${ctx.availableUpdate ? renderUpdateSection(ctx) : ""}

    <section class="cc-settings-group" data-general-section="basicDisplay">
      <div class="cc-group-title cc-settings-section-caption">${ctx.escapeHtml(
        tr3("基础显示", "基礎顯示", "Basic Display"),
      )}</div>
      <div class="cc-settings-group-card">
        <div class="cc-field" data-settings-anchor="appearanceMode">
          <label>${t("外观模式")}</label>
          <div class="cc-segmented-pills is-even">
            ${APPEARANCES.map(
              (a) =>
                `<button class="cc-seg-pill ${ctx.settings.appearance === a.id ? "is-active" : ""}" data-appearance="${a.id}" aria-pressed="${ctx.settings.appearance === a.id}">${ctx.escapeHtml(a.title)}</button>`,
            ).join("")}
          </div>
        </div>

        <div class="cc-field" data-settings-anchor="language">
          <label>${t("界面语言")}</label>
          <div class="cc-segmented-pills">
            ${([["system", t("跟随系统")], ["zh-Hans", t("简体中文")], ["zh-Hant", t("繁體中文")], ["en", "English"]] as const)
              .map(
                ([value, label]) =>
                  `<button class="cc-seg-pill ${ctx.settings.interfaceLanguage === value ? "is-active" : ""}" data-interface-language="${value}" aria-pressed="${ctx.settings.interfaceLanguage === value}">${ctx.escapeHtml(label)}</button>`,
              )
              .join("")}
          </div>
        </div>

        <div class="cc-field" data-settings-anchor="temperatureUnit">
          <label>${t("温度单位")}</label>
          <div class="cc-segmented-pills">
            ${([["system", t("跟随系统")], ["celsius", t("摄氏度 (°C)")], ["fahrenheit", t("华氏度 (°F)")]] as const)
              .map(
                ([value, label]) =>
                  `<button class="cc-seg-pill ${ctx.settings.temperatureUnit === value ? "is-active" : ""}" data-temperature-unit="${value}" aria-pressed="${ctx.settings.temperatureUnit === value}">${ctx.escapeHtml(label)}</button>`,
              )
              .join("")}
          </div>
        </div>
        ${renderCustomHomeTitleField(ctx)}
      </div>
    </section>

    <section class="cc-settings-group" data-general-section="interaction">
      <div class="cc-group-title cc-settings-section-caption">${ctx.escapeHtml(
        tr3("交互", "互動", "Interaction"),
      )}</div>
      <div class="cc-settings-group-card">
        <div class="cc-field cc-field-row" data-settings-anchor="quickScenesBar">
          <label for="settings-quick-actions">${t("显示顶部快捷场景栏")}</label>
          <input id="settings-quick-actions" type="checkbox" ${ctx.settings.showQuickActionsBar ? "checked" : ""} />
        </div>

        <div class="cc-field cc-field-row" data-settings-anchor="homeSummaryRow">
          <label for="settings-home-summary-row">${t("面板顶部显示「我家现在」摘要行")}</label>
          <input id="settings-home-summary-row" type="checkbox" ${ctx.settings.showHomeSummaryRow ? "checked" : ""} />
        </div>

        <div class="cc-field cc-field-row" data-settings-anchor="voiceControl">
          <div>
            <label for="settings-voice-input">${t("语音输入")}</label>
            ${
              isSpeechRecognitionSupported()
                ? ""
                : `<p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
                    tr3("此电脑暂不支持语音识别", "此電腦暫不支援語音辨識", "Speech recognition isn't available on this PC"),
                  )}</p>`
            }
          </div>
          <input id="settings-voice-input" type="checkbox" ${isVoiceInputEnabled(ctx.settings) ? "checked" : ""} />
        </div>
      </div>
    </section>

    <section class="cc-settings-group" data-general-section="startupShortcuts">
      <div class="cc-group-title cc-settings-section-caption">${ctx.escapeHtml(
        tr3("启动与快捷键", "啟動與快速鍵", "Startup & Shortcuts"),
      )}</div>
      <div class="cc-settings-group-card">
        <div class="cc-field cc-field-row" data-settings-anchor="launchAtLogin">
          <label for="settings-launch-at-login">${t("开机自动启动")}</label>
          <input id="settings-launch-at-login" type="checkbox" ${ctx.settings.launchAtLogin ? "checked" : ""} />
        </div>

        <div class="cc-field" data-settings-anchor="globalHotkey">
          <div class="cc-field-row">
            <label for="settings-enable-hotkey">${t("启用全局呼出快捷键")}</label>
            <input id="settings-enable-hotkey" type="checkbox" ${ctx.settings.enableGlobalHotkey ? "checked" : ""} />
          </div>
          ${
            ctx.settings.enableGlobalHotkey
              ? `<div class="cc-update-row" style="margin-top: 6px;">
                   <span>${t("呼出面板的快捷键")}</span>
                   <div style="display: flex; gap: 6px; align-items: center;">
                     <button
                       type="button"
                       class="cc-seg-pill ${ctx.isRecordingHotkey ? "is-active" : ""}"
                       id="btn-record-hotkey"
                       title="${t("点击后按下新的组合；Esc 取消")}"
                       aria-pressed="${ctx.isRecordingHotkey}"
                     >${ctx.isRecordingHotkey ? t("按下组合…") : ctx.escapeHtml(ctx.settings.globalHotkey)}</button>
                     ${
                       ctx.settings.globalHotkey !== DEFAULT_GLOBAL_SHORTCUT
                         ? `<button type="button" class="cc-btn-secondary" id="btn-reset-hotkey">${t("恢复 Alt+M")}</button>`
                         : ""
                     }
                   </div>
                 </div>`
              : ""
          }
          ${
            ctx.settings.enableGlobalHotkey && (ctx.isRecordingHotkey || ctx.hotkeyNeedsHint)
              ? `<p class="cc-field-hint" id="hotkey-record-hint">${t("需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。Esc 取消。")}</p>`
              : ""
          }
          ${
            ctx.settings.enableGlobalHotkey && ctx.hotkeyRegistrationError
              ? `<div class="cc-update-row" id="hotkey-conflict-row" style="margin-top: 6px;">
                   <span class="cc-field-hint" style="color: #e67e22; margin: 0;">${ctx.escapeHtml(ctx.hotkeyRegistrationError)}</span>
                   <button type="button" class="cc-btn-secondary" id="btn-retry-hotkey">${t("重试")}</button>
                 </div>`
              : ""
          }
          ${renderCustomHotkeyBindingsSection(ctx)}
        </div>
      </div>
    </section>

    <section class="cc-settings-group" data-general-section="deviceVisibility">
      <div class="cc-group-title cc-settings-section-caption">${ctx.escapeHtml(
        tr3("设备可见性", "裝置可見性", "Device Visibility"),
      )}</div>
      <div class="cc-settings-group-card">
        <div class="cc-field" data-settings-anchor="hideOfflineDevices">
          <div class="cc-field-row">
            <label for="settings-hide-offline">${t("隐藏离线/未通电的设备")}</label>
            <input id="settings-hide-offline" type="checkbox" ${ctx.settings.hideOfflineDevices ? "checked" : ""} />
          </div>
          ${renderGeneralHiddenDevicesRestore(ctx)}
        </div>
      </div>
    </section>

    ${ctx.deviceTypes?.html() ?? ""}

    <details class="cc-conn-secondary" data-conn-section="advancedDisplay" data-general-section="advancedDisplay">
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(
        tr3("高级显示", "進階顯示", "Advanced Display"),
      )}</summary>
      <div class="cc-settings-group-card">
        <div class="cc-field" data-settings-anchor="panelTheme">
          <label>${t("面板风格")}</label>
          <div class="cc-segmented-pills is-even">
            <button type="button" class="cc-seg-pill ${ctx.settings.panelTheme === "classic" ? "is-active" : ""}" data-panel-theme="classic" aria-pressed="${ctx.settings.panelTheme === "classic"}">${ctx.escapeHtml(t("macOS 控制中心"))}</button>
            <button type="button" class="cc-seg-pill ${ctx.settings.panelTheme === "fluent" ? "is-active" : ""}" data-panel-theme="fluent" aria-pressed="${ctx.settings.panelTheme === "fluent"}">${ctx.escapeHtml(t("Win11 双岛"))}</button>
          </div>
        </div>

        <div class="cc-field" data-settings-anchor="panelHeight">
          <label>${t("面板高度")}</label>
          <div class="cc-segmented-pills">
            ${PANEL_HEIGHTS.map((h) => `<button class="cc-seg-pill ${ctx.settings.panelHeight === h.id ? "is-active" : ""}" data-panel-height="${h.id}" aria-pressed="${ctx.settings.panelHeight === h.id}">${h.title}</button>`).join("")}
          </div>
        </div>

        <div class="cc-field" data-settings-anchor="panelOpacity">
          <div class="cc-slider-label">
            <label for="settings-panel-opacity">${t("面板不透明度")}</label>
            <strong id="settings-panel-opacity-value">${ctx.settings.panelOpacity}%</strong>
          </div>
          <div class="cc-opacity-row">
            <input id="settings-panel-opacity" class="cc-range" type="range" min="${PANEL_OPACITY_MIN}" max="${PANEL_OPACITY_MAX}" step="1" value="${ctx.settings.panelOpacity}" aria-valuemin="${PANEL_OPACITY_MIN}" aria-valuemax="${PANEL_OPACITY_MAX}" aria-valuenow="${ctx.settings.panelOpacity}" />
            <span class="cc-opacity-preview" aria-hidden="true"><span class="cc-opacity-preview-panel">Aa</span></span>
          </div>
        </div>

        <div class="cc-field" data-settings-anchor="panelAnchor">
          <label>${t("面板位置")}</label>
          <div class="cc-segmented-pills">
            ${PANEL_ANCHORS.map((a) => `<button class="cc-seg-pill ${ctx.panelAnchor === a.id ? "is-active" : ""}" data-panel-anchor="${a.id}" aria-pressed="${ctx.panelAnchor === a.id}">${ctx.escapeHtml(a.title)}</button>`).join("")}
          </div>
        </div>

        <div class="cc-field cc-field-row" data-settings-anchor="compactGridMode">
          <label for="settings-compact-grid">${ctx.escapeHtml(
            tr3("紧凑双列分体磁贴", "緊湊雙列分體磁貼", "Compact 2-column split tiles"),
          )}</label>
          <input id="settings-compact-grid" type="checkbox" ${ctx.settings.isCompactGridMode ? "checked" : ""} />
        </div>

        <div class="cc-field cc-field-row" data-settings-anchor="climatePanelModule">
          <label for="settings-climate-panel">${t("空调使用整行控制条")}</label>
          <input id="settings-climate-panel" type="checkbox" ${ctx.settings.climatePanel ? "checked" : ""} />
        </div>

        <div class="cc-field cc-field-row" data-settings-anchor="hideGroupedLights">
          <label for="settings-hide-grouped-lights">${t("灯组内的单灯不重复显示")}</label>
          <input id="settings-hide-grouped-lights" type="checkbox" ${ctx.settings.hideGroupedLights ? "checked" : ""} />
        </div>
      </div>
    </details>

    <div class="cc-settings-group-card">
      <div class="cc-field cc-field-row" data-settings-anchor="setupGuide">
        <label>${ctx.escapeHtml(tr3("首次设置与新手引导", "首次設定與新手引導", "Setup & Onboarding Guide"))}</label>
        <button type="button" class="cc-btn-secondary" id="btn-reopen-onboarding">${ctx.escapeHtml(
          Boolean(ctx.settings.miSession) || Boolean(ctx.settings.haBaseURL.trim() && ctx.settings.haToken.trim())
            ? tr3("重新查看新手引导", "重新查看新手引導", "Reopen Setup Guide")
            : t("继续初始设置"),
        )}</button>
      </div>
    </div>
  `;
}

function renderHomeAssistantCredentialsBlock(ctx: SettingsViewContext): string {
  const warnPlainHttp = isPlainHttpRemoteEndpoint(ctx.settings.haBaseURL);
  const hasHaUrl = ctx.settings.haBaseURL.trim().length > 0;
  return `
    <div class="cc-field">
      <div data-settings-anchor="haServerAddress">
        <div class="cc-field-row" style="flex-wrap: wrap; margin-bottom: 4px;">
          <label for="settings-ha-url" style="margin: 0;">${ctx.escapeHtml(
            tr3("Home Assistant 地址 (URL)", "Home Assistant 位址 (URL)", "Home Assistant URL"),
          )}</label>
          <div class="cc-ha-url-actions">
            <button type="button" class="cc-inline-pill" id="btn-settings-discover-ha">${ctx.escapeHtml(
              t("在局域网中查找"),
            )}</button>
            <button type="button" class="cc-inline-pill" id="btn-fill-default-ha" ${hasHaUrl ? "disabled" : ""}>${ctx.escapeHtml(
              tr3("填入常用地址", "填入常用位址", "Fill Default Address"),
            )}</button>
          </div>
        </div>
        <input id="settings-ha-url" class="cc-input" type="url" value="${ctx.escapeHtml(ctx.settings.haBaseURL)}" placeholder="http://homeassistant.local:8123" />
        <p class="cc-ha-discover-status" id="settings-ha-discover-status" role="status" hidden></p>
        <div class="cc-ha-candidates" id="settings-ha-candidates" hidden></div>
        <p
          class="cc-field-hint"
          data-ha-plaintext-warning
          ${warnPlainHttp ? "" : "hidden"}
          style="margin: 4px 0 0; font-size: 12px; color: #e67e22;"
        >${ctx.escapeHtml(
          tr3(
            "当前为明文 HTTP，建议改用 HTTPS",
            "目前為明文 HTTP，建議改用 HTTPS",
            "This is plain HTTP; switch to HTTPS",
          ),
        )}</p>
      </div>
      <div data-settings-anchor="haToken" style="margin-top: 6px;">
        <label for="settings-ha-token">${ctx.escapeHtml(
          tr3(
            "访问密钥 (Access Token)",
            "存取金鑰 (Access Token)",
            "Access Token",
          ),
        )}</label>
        <input id="settings-ha-token" class="cc-input" type="password" autocomplete="off" value="${ctx.escapeHtml(ctx.settings.haToken)}" />
        <p class="cc-field-hint" style="margin: 4px 0 0;">${ctx.escapeHtml(
          tr3(
            "在 HA「个人资料 → 安全」底部创建",
            "在 HA「個人資料 → 安全」底部建立",
            "Create one at the bottom of Profile → Security in HA",
          ),
        )}</p>
      </div>
    </div>
  `;
}

function renderXiaomiCloudBlock(ctx: SettingsViewContext): string {
  return `
    <p class="cc-field-hint" data-mi-unofficial-warning style="margin: 0; font-size: 12px; color: #e67e22;">${ctx.escapeHtml(
      tr3(
        "非官方直连，可能被小米限流或风控，到期需重扫",
        "非官方直連，可能被小米限流或風控，到期需重掃",
        "Unofficial connection: Xiaomi may rate-limit or flag it; rescan when it expires",
      ),
    )}</p>

    <div class="cc-qr-box" data-settings-anchor="miAccount">
      <button class="cc-btn-primary is-full" id="btn-start-qr" ${ctx.isPollingQR ? "disabled" : ""}>
        ${SF_ICONS.qrcode}
        <span>
          ${
            ctx.settings.miSession
              ? t("切换/重新扫码 (已登录 {user})", { user: maskedMiUserId(ctx.settings.miSession.userId) })
              : t("获取米家登录二维码")
          }
        </span>
      </button>
      ${renderMiSessionNoteAndSignOut(ctx)}
      <div class="cc-qr-status">${ctx.escapeHtml(ctx.qrStatusText)}</div>
      ${
        ctx.qrTicket
          ? `<div class="cc-qr-frame"><img src="${ctx.escapeHtml(ctx.qrTicket.qrImageURL)}" alt="Xiaomi QR" /></div>`
          : ""
      }
    </div>

    <details class="cc-conn-secondary" data-conn-section="miRegionAdvanced" ${normalizeMiCloudRegion(ctx.settings.miCloudRegion) !== "cn" ? "open" : ""}>
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(tr3("高级", "進階", "Advanced"))}</summary>
      <div class="cc-field" data-settings-anchor="miCloudRegion">
        <label>${t("云端服务器地区")}</label>
        <select class="cc-input" data-mi-region>
          ${MI_CLOUD_REGIONS.map(
            (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(ctx.settings.miCloudRegion) === region.code ? "selected" : ""}>${ctx.escapeHtml(t(region.label))}</option>`,
          ).join("")}
        </select>
        <p class="cc-field-hint">${ctx.escapeHtml(t("切换地区需重新扫码"))}</p>
      </div>
    </details>
  `;
}

function renderConnectionPanel(ctx: SettingsViewContext): string {
  const activeBadge = `<span class="cc-conn-active-badge">${ctx.escapeHtml(trText("当前使用", "Active"))}</span>`;
  const demoHint = tr3(
    "示例家庭，不会控制真实设备",
    "範例家庭，不會控制真實裝置",
    "Demo home — does not control real devices",
  );
  const demoEntryLabel = tr3("先逛逛示例家庭", "先逛逛範例家庭", "Explore Demo Home");
  const modeBlocks =
    ctx.settings.connectionMode === "homeAssistant"
      ? `
    <div class="cc-conn-card is-active-mode" data-conn-section="homeAssistant">
      <div class="cc-conn-card-header">
        <strong>Home Assistant</strong>
        ${activeBadge}
      </div>
      ${renderHomeAssistantCredentialsBlock(ctx)}
    </div>
    <details class="cc-conn-secondary" data-conn-section="xiaomiCloud">
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(trText("备用数据源：米家云真实设备", "Secondary source: Xiaomi Cloud"))}</summary>
      ${renderXiaomiCloudBlock(ctx)}
    </details>`
      : ctx.settings.connectionMode === "xiaomiCloud"
        ? `
    <div class="cc-conn-card is-active-mode" data-conn-section="xiaomiCloud">
      <div class="cc-conn-card-header">
        <strong>${ctx.escapeHtml(t("米家云真实设备"))}</strong>
        ${activeBadge}
      </div>
      ${renderXiaomiCloudBlock(ctx)}
    </div>
    <details class="cc-conn-secondary" data-conn-section="homeAssistant">
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(trText("备用数据源：Home Assistant", "Secondary source: Home Assistant"))}</summary>
      ${renderHomeAssistantCredentialsBlock(ctx)}
    </details>`
        : `
    <div class="cc-conn-card is-active-mode" data-conn-section="demo">
      <div class="cc-conn-card-header">
        <strong>${ctx.escapeHtml(demoEntryLabel)}</strong>
        ${activeBadge}
      </div>
      <p class="cc-field-hint" style="margin: 0;">${ctx.escapeHtml(demoHint)}</p>
    </div>
    ${renderHomeAssistantCredentialsBlock(ctx)}
    ${renderXiaomiCloudBlock(ctx)}`;

  return `
    <div class="cc-field" data-settings-anchor="dataSource">
      <label>${t("设备数据源")}</label>
      <div class="cc-segmented-pills">
        <button
          class="cc-seg-pill ${ctx.settings.connectionMode === "xiaomiCloud" ? "is-active" : ""}"
          data-conn-mode="xiaomiCloud"
        >
          ${t("米家云真实设备")}
        </button>
        <button class="cc-seg-pill ${ctx.settings.connectionMode === "homeAssistant" ? "is-active" : ""}" data-conn-mode="homeAssistant">Home Assistant</button>
        <button
          class="cc-seg-pill ${ctx.settings.connectionMode === "demo" ? "is-active" : ""}"
          data-conn-mode="demo"
          data-settings-anchor="demoMode"
          title="${ctx.escapeHtml(demoHint)}"
        >
          ${ctx.escapeHtml(demoEntryLabel)}
        </button>
      </div>
    </div>
    ${modeBlocks}
    ${renderConnectionsAndDiagSection(ctx)}
  `;
}

function renderMiSessionNoteAndSignOut(ctx: SettingsViewContext): string {
  if (!ctx.settings.miSession) {
    if (!hasPendingMiVaultDeletion()) return "";
    return `<button type="button" class="cc-btn-secondary is-full" id="btn-signout-mi" ${ctx.isPollingQR ? "disabled" : ""}>${ctx.escapeHtml(t("重试退出米家登录"))}</button>`;
  }
  const expiry = miSessionExpiryState(ctx.settings.miSession);
  let expiryHint = "";
  if (expiry.kind === "expiringSoon") {
    const dateText = new Intl.DateTimeFormat(speechLocale(), {
      month: "short",
      day: "numeric",
    }).format(new Date(expiry.expiresAtMs));
    expiryHint = `<div class="cc-qr-status" data-mi-settings-expiry>${ctx.escapeHtml(t("米家登录将在 {date} 到期", { date: dateText }))}</div>`;
  } else if (expiry.kind === "expired") {
    expiryHint = `<div class="cc-qr-status" data-mi-settings-expiry>${ctx.escapeHtml(t("米家登录已过期 · 点此扫码"))}</div>`;
  }
  return `${expiryHint}<button type="button" class="cc-btn-secondary is-full" id="btn-signout-mi" ${ctx.isPollingQR ? "disabled" : ""}>${ctx.escapeHtml(t("退出米家登录"))}</button>`;
}

/** AI 与习惯: the decision model endpoint and everything the app learns from the user. */
function renderAssistantPanel(ctx: SettingsViewContext): string {
  const currentPreset = inferAssistantPreset(ctx.settings.assistantBaseURL);
  const askWhenUnsure = readAskWhenUnsure(ctx.settings);
  const sequences = ctx.habitSequences();
  const readableHabits = listReadableHabits({
    entries: ctx.settings.habitEntries,
    sequences,
    phrases: ctx.settings.learnedShortcuts.map((s) => ({ phrase: s.phrase, summary: s.reply })),
    devices: ctx.devices,
    scenes: ctx.scenes ?? [],
  });

  const aiEnabled = isAiAssistantEnabled(ctx.settings);
  const advancedOpen =
    currentPreset.id === "custom" ||
    ctx.settings.assistantBaseURL.trim() === "" ||
    ctx.settings.assistantModel.trim() === "";

  return `
    <div class="cc-field cc-field-row">
      <div>
        <label for="settings-ai-enabled">${t("启用 AI 助手")}</label>
        <p class="cc-field-hint" id="settings-ai-off-hint" style="margin: 2px 0 0 0;" ${aiEnabled ? "hidden" : ""}>${t("仅本地解析，密钥保留")}</p>
      </div>
      <input id="settings-ai-enabled" type="checkbox" ${aiEnabled ? "checked" : ""} />
    </div>

    <div class="cc-field" data-settings-anchor="assistantProvider">
      <label for="settings-ai-provider">${t("服务商")}</label>
      <select id="settings-ai-provider" class="cc-input">
        ${ASSISTANT_PROVIDER_PRESETS.map((preset) => {
          const label =
            preset.id === "custom"
              ? tr3("自定义", "自訂", "Custom")
              : preset.shortTitle;
          return `<option value="${ctx.escapeHtml(preset.id)}" data-ai-preset="${ctx.escapeHtml(preset.id)}" ${currentPreset.id === preset.id ? "selected" : ""}>${ctx.escapeHtml(label)}</option>`;
        }).join("")}
      </select>
    </div>

    <div class="cc-field" data-settings-anchor="assistantAPIKey">
      <label for="settings-api-key">API Key</label>
      <input
        id="settings-api-key"
        class="cc-input"
        type="password"
        placeholder="${ctx.escapeHtml(currentPreset.keyPlaceholder)}"
        value="${ctx.escapeHtml(ctx.apiKeyFor(ctx.settings.assistantBaseURL))}"
      />
    </div>

    <div class="cc-field" data-settings-anchor="assistantTest">
      <button type="button" class="cc-btn-secondary" id="btn-test-ai-connection">${ctx.escapeHtml(
        tr3("测试连接", "測試連線", "Test Connection"),
      )}</button>
      <div id="settings-ai-test-status" class="cc-field-hint" style="margin-top: 4px;"></div>
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="proactiveSuggestions">
      <label for="settings-proactive-enabled">${t("主动建议")}</label>
      <input id="settings-proactive-enabled" type="checkbox" ${isProactiveSuggestionsEnabled(ctx.settings) ? "checked" : ""} />
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="askWhenUnsure">
      <div>
        <label for="settings-ask-when-unsure">${ctx.escapeHtml(
          tr3("不确定时先问我", "不確定時先問我", "Ask Me When Unsure"),
        )}</label>
        <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
          tr3("高风险操作仍需确认", "高風險操作仍需確認", "High-risk actions still ask first"),
        )}</p>
      </div>
      <input id="settings-ask-when-unsure" type="checkbox" ${askWhenUnsure ? "checked" : ""} />
    </div>

    <p class="cc-field-hint" data-ai-cloud-notice>${ctx.escapeHtml(
      tr3(
        "本机听不懂的指令和主动建议，会连同设备名和状态发给 AI 服务；密钥存在本机",
        "本機聽不懂的指令和主動建議，會連同裝置名稱和狀態傳給 AI 服務；金鑰存在本機",
        "Commands this PC can't parse, and proactive suggestions, send device names and states to the AI service; keys are stored on this PC and sent only to that service",
      ),
    )}</p>

    ${
      ctx.settings.cloudConsentEndpoints.length > 0
        ? `<div class="cc-field" data-settings-anchor="cloudConsent">
      <label>${t("已允许发送到：{endpoints}", { endpoints: ctx.escapeHtml(ctx.settings.cloudConsentEndpoints.join("、")) })}</label>
      <button type="button" class="cc-btn-secondary" id="btn-revoke-cloud">${t("撤销授权")}</button>
    </div>`
        : ""
    }

    <details class="cc-conn-secondary" data-conn-section="assistantAdvanced" ${advancedOpen ? "open" : ""}>
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(tr3("高级", "進階", "Advanced"))}</summary>

    <div class="cc-field" data-settings-anchor="assistantBaseURL">
      <label for="settings-base-url">${t("服务地址")}</label>
      <input
        id="settings-base-url"
        class="cc-input"
        type="text"
        placeholder="https://openrouter.ai/api/v1"
        value="${ctx.escapeHtml(ctx.settings.assistantBaseURL)}"
      />
    </div>

    <div class="cc-field" data-settings-anchor="assistantModel">
      <label for="settings-model">${t("模型")}</label>
      <input
        id="settings-model"
        class="cc-input"
        type="text"
        value="${ctx.escapeHtml(ctx.settings.assistantModel)}"
      />
    </div>

    <div class="cc-field">
      <div class="cc-update-row" data-settings-anchor="assistantEnvImport" style="gap: 6px; flex-wrap: wrap;">
        <button type="button" class="cc-inline-pill" id="btn-import-env-key">${ctx.escapeHtml(
          tr3("从本机环境导入 Key", "從本機環境匯入 Key", "Import Key from Environment"),
        )}</button>
        <span id="settings-env-import-status" class="cc-field-hint" style="margin: 0;"></span>
      </div>
      <div class="cc-update-row" style="margin-top: 6px; gap: 6px; flex-wrap: wrap;">
        <button type="button" class="cc-inline-pill" id="btn-restore-ai-provider-defaults" ${currentPreset.id === "custom" ? "hidden" : ""}>${ctx.escapeHtml(
          tr3("恢复服务商默认值", "恢復服務商預設值", "Restore Provider Defaults"),
        )}</button>
        <button type="button" class="cc-inline-pill" id="btn-remove-ai-provider">${t("移除此服务商")}</button>
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="habitMemory">
      <label class="cc-checkbox">
        <input type="checkbox" id="settings-habit" ${ctx.settings.habitLearningEnabled ? "checked" : ""} />
        <span>${t("学习使用习惯")}</span>
      </label>
      <div data-settings-anchor="habitShare">
        <label class="cc-checkbox">
          <input type="checkbox" id="settings-habit-share" ${ctx.settings.habitShareEnabled ? "checked" : ""} />
          <span>${t("向 AI 附带习惯摘要")}</span>
        </label>
        <input id="settings-habit-share-sample" class="cc-input" type="text" aria-label="${ctx.escapeHtml(t("预览习惯摘要"))}" placeholder="${ctx.escapeHtml(t("输入一句话，预览附带的摘要"))}" />
        <div id="settings-habit-share-preview">${t("不会发送习惯摘要")}</div>
      </div>
      ${
        ctx.settings.learnedShortcuts.length > 0
          ? `<div class="cc-timers-stack">
              ${ctx.settings.learnedShortcuts
                .map(
                  (s, idx) => `
                <div class="cc-timer-row">
                  <span>「${ctx.escapeHtml(s.phrase)}」→ ${ctx.escapeHtml(s.reply)}</span>
                  <button class="cc-inline-pill" data-del-habit="${idx}">${t("删除")}</button>
                </div>
              `,
                )
                .join("")}
            </div>`
          : ""
      }
      ${
        ctx.settings.habitEntries.length > 0 || sequences.length > 0 || readableHabits.length > 0
          ? `<div class="cc-timers-stack">
              <div class="cc-timer-row" style="gap: 6px; flex-wrap: wrap;">
                <span style="flex: 1;">${t("已学习 {count} 条习惯", {
                  count: ctx.settings.habitEntries.length + sequences.length,
                })}</span>
                <div style="display: flex; gap: 6px; align-items: center;">
                  <button
                    type="button"
                    class="cc-inline-pill"
                    id="btn-toggle-habit-items"
                    aria-expanded="false"
                    aria-controls="settings-habit-items-list"
                  >${ctx.escapeHtml(
                    tr3(
                      `逐条查看 (${readableHabits.length})`,
                      `逐條查看 (${readableHabits.length})`,
                      `View Items (${readableHabits.length})`,
                    ),
                  )}</button>
                  <button type="button" class="cc-inline-pill" id="btn-clear-habits">${t("清空")}</button>
                </div>
              </div>
              <div id="settings-habit-items-list" hidden style="display: flex; flex-direction: column; gap: 4px; margin-top: 4px;">
                ${readableHabits
                  .map(
                    (item) => `
                  <div class="cc-timer-row" data-habit-item-row="${ctx.escapeHtml(item.id)}">
                    <span>${ctx.escapeHtml(item.text)}</span>
                    <button
                      type="button"
                      class="cc-inline-pill"
                      data-forget-habit-id="${ctx.escapeHtml(item.id)}"
                      title="${ctx.escapeHtml(tr3("忘掉这一条", "忘掉這一條", "Forget this habit"))}"
                    >${t("删除")}</button>
                  </div>`,
                  )
                  .join("")}
              </div>
            </div>`
          : ""
      }
    </div>
    </details>
  `;
}

/** 复制配置, 检测接入 and 断开 for Raycast / CLI / MCP, plus what a companion can reach on this PC (P6a-W). */
function renderCompanionControls(ctx: SettingsViewContext): string {
  const enabled = ctx.settings.enableRaycastIntegration;
  const notice = ctx.companionNotice;
  const noticeHtml = notice
    ? `<p class="cc-field-hint" id="settings-companion-notice" role="status"${notice.isError ? ' style="color: #e74c3c;"' : ""}>${notice.lines.map((line) => ctx.escapeHtml(line)).join("<br />")}</p>`
    : `<p class="cc-field-hint" id="settings-companion-notice" role="status" hidden></p>`;
  return `
        ${enabled ? `<p class="cc-field-hint">${ctx.escapeHtml(tr3(
          "仅本机可读，不共享账号凭据",
          "僅本機可讀，不共享帳號憑證",
          "Readable on this PC only; account credentials are never shared",
        ))}</p>` : ""}
        <div class="cc-field-row" style="margin-top: 6px; gap: 6px; flex-wrap: wrap; justify-content: flex-start;">
          <button type="button" class="cc-btn-secondary" id="btn-companion-copy-config">${ctx.escapeHtml(tr3("复制配置", "複製設定", "Copy Config"))}</button>
          <button type="button" class="cc-btn-secondary" id="btn-companion-detect">${ctx.escapeHtml(tr3("检测接入", "檢測接入", "Check Connection"))}</button>
          ${enabled || notice?.retryDisconnect ? `<button type="button" class="cc-btn-secondary" id="btn-companion-disconnect">${ctx.escapeHtml(enabled
            ? tr3("断开", "中斷連線", "Disconnect")
            : tr3("重试删除快照", "重試刪除快照", "Retry Snapshot Deletion"))}</button>` : ""}
        </div>
        ${noticeHtml}`;
}

/** 安全与提醒: lock-screen blocking, scheduled commands, companion links, high-risk writes, energy, automation/alerts, and All Off scope. */
function renderSafetyPanel(ctx: SettingsViewContext): string {
  const allOffCandidates = ctx.devices.filter(
    (d) => d.kind.kind !== "sensor" && d.kind.kind !== "fridge" && d.kind.kind !== "cover",
  );
  return `
    <div class="cc-settings-group-card">
      <div class="cc-field">
        <label>${t("自动化与安全控制")}</label>
        <div data-settings-anchor="blockControlWhileLocked">
          <div class="cc-field-row" style="margin-top: 4px;">
            <label for="settings-block-while-locked">${t("锁屏时禁止控制设备")}</label>
            <input id="settings-block-while-locked" type="checkbox" ${ctx.settings.blockControlWhileLocked ? "checked" : ""} />
          </div>
          <p class="cc-field-hint">${t("不影响定时任务与自动化规则")}</p>
        </div>

        <div data-settings-anchor="scheduledCommands">
          <div class="cc-field-row" style="margin-top: 8px;">
            <label for="settings-scheduled-commands-enabled">${t("运行定时任务")}</label>
            <input id="settings-scheduled-commands-enabled" type="checkbox" ${isScheduledCommandsEnabled(ctx.settings) ? "checked" : ""} />
          </div>
          <p class="cc-field-hint">${t("关闭后暂停执行，过期不补发")}</p>
        </div>

      </div>

      <details class="cc-conn-secondary" data-conn-section="safetyAdvanced">
        <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(tr3("高级", "進階", "Advanced"))}</summary>
        <div class="cc-field" data-settings-anchor="raycast">
          <div class="cc-field-row" style="margin-top: 8px;">
            <label for="settings-raycast-integration">${t("Raycast / CLI / MCP 集成")}</label>
            <input id="settings-raycast-integration" type="checkbox" ${ctx.settings.enableRaycastIntegration ? "checked" : ""} />
          </div>
          ${renderCompanionControls(ctx)}
        </div>

        <div class="cc-field" data-settings-anchor="allowURLControl">
          <div class="cc-field-row" style="margin-top: 8px;">
            <label for="settings-allow-direct-url">${t("允许外部链接直控（跳过确认）")}</label>
            <input id="settings-allow-direct-url" type="checkbox" ${ctx.settings.allowDirectURLControl ? "checked" : ""} />
          </div>
          <p class="cc-field-hint">${t("链接直接执行；高风险设备仍会确认，锁屏拦截照常")}</p>
        </div>
      </details>

      <div class="cc-field" data-settings-anchor="advancedDeviceWrites">
        <div class="cc-field-row">
          <div>
            <label for="settings-allow-advanced-facets">${t("允许「更多设置」写入次要控件")}</label>
            <p class="cc-field-hint" style="margin: 2px 0 0 0;">${t("解锁「更多设置」里默认只读的控件")}</p>
          </div>
          <input id="settings-allow-advanced-facets" type="checkbox" ${ctx.settings.allowAdvancedFacetWrites ? "checked" : ""} />
        </div>
        <div
          id="settings-advanced-facets-confirm"
          class="cc-update-row"
          hidden
          role="alert"
          style="margin-top: 6px; padding: 8px; border-radius: 8px; background: rgba(231, 76, 60, 0.14); gap: 6px; flex-wrap: wrap;"
        >
          <span style="font-size: 12px;">${ctx.escapeHtml(
            tr3(
              "高风险提示：开启后「更多设置」将允许写入电取暖、门锁、水阀、童锁等次要控件，误操作可能引发安全或财产风险。确认开启？",
              "高風險提示：開啟後「更多設定」將允許寫入電暖器、門鎖、水閥、兒童鎖等次要控制項，誤操作可能引發安全或財產風險。確認開啟？",
              "High-risk warning: Enabling secondary controls allows writes to heaters, door locks, water valves, and child locks. Enable anyway?",
            ),
          )}</span>
          <div style="display: flex; gap: 6px; margin-left: auto;">
            <button type="button" class="cc-btn-secondary" id="btn-cancel-advanced-facets">${t("取消")}</button>
            <button type="button" class="cc-btn-danger" id="btn-confirm-advanced-facets">${ctx.escapeHtml(
              tr3("确认开启", "確認開啟", "Enable Risky Writes"),
            )}</button>
          </div>
        </div>
      </div>
    </div>

    ${renderEnergySettingsSection(ctx)}
    ${renderDdcSettingsSection(getDdcDisplayController(), (raw) => ctx.escapeHtml(raw))}
    ${renderAutomationAndSafetySettingsSections(ctx)}

    <div class="cc-settings-group-card">
      <div class="cc-field" data-settings-anchor="allOffDevices">
        <label>${t("「全关」包含的设备")}</label>
        <p class="cc-field-hint" style="margin: 2px 0 4px 0;">${t("插座、扫地机等默认不参与")}</p>
        <details class="cc-conn-secondary" data-conn-section="allOffDevices">
        <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(t("已包含 {count} 台设备", {
          count: allOffCandidates.filter((d) => joinsAllOff(d, ctx.settings.allOffOverrides) && deviceCanTogglePower(d)).length,
        }))}</summary>
        <div class="cc-timers-stack">
          ${allOffCandidates
            .map(
              (d) => `
            <label class="cc-checkbox">
              <input type="checkbox" data-alloff-device="${ctx.escapeHtml(d.id)}" ${joinsAllOff(d, ctx.settings.allOffOverrides) ? "checked" : ""} />
              <span>${ctx.escapeHtml(d.name)}${d.roomName ? ` · ${ctx.escapeHtml(d.roomName)}` : ""}</span>
            </label>`,
            )
            .join("")}
        </div>
        </details>
      </div>
    </div>
  `;
}

/** 关于与诊断: updates & version, diagnostics/scanner shortcuts, sign out & revoke all, and quit app. */
function renderAboutPanel(ctx: SettingsViewContext): string {
  const quitHint = tr3(
    "完全退出后，托盘图标和快捷键都会停止",
    "完全退出後，系統匣圖示和快速鍵都會停止",
    "After quitting completely, the tray icon and global shortcut will stop.",
  );
  return `
    ${
      !ctx.availableUpdate
        ? renderUpdateSection(ctx)
        : `<div class="cc-settings-group-card">
            <div class="cc-field cc-field-row" data-settings-anchor="aboutVersion">
              <div>
                <label>${ctx.escapeHtml(t("发现新版本 v{version}", { version: ctx.availableUpdate.version }))}</label>
                <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(t("当前版本 v{version}", { version: APP_VERSION }))}</p>
              </div>
              <button type="button" class="cc-btn-primary" id="btn-about-open-update-general">${ctx.escapeHtml(
                tr3("前往更新", "前往更新", "View Update"),
              )}</button>
            </div>
          </div>`
    }

    <div class="cc-settings-group-card">
      <div class="cc-field">
        <label>${ctx.escapeHtml(tr3("诊断与排障工具", "診斷與排障工具", "Diagnostics & Troubleshooting"))}</label>
        <p class="cc-field-hint" style="margin: 2px 0 6px 0;">${ctx.escapeHtml(
          tr3("不含账号、密钥与设备 ID", "不含帳號、金鑰與裝置 ID", "No accounts, keys or device IDs"),
        )}</p>
        <div style="display: flex; gap: 6px; flex-wrap: wrap;">
          <button type="button" class="cc-btn-secondary" id="btn-about-jump-scanner">${ctx.escapeHtml(
            tr3("扫描未能显示的设备", "掃描未能顯示的裝置", "Scan Hidden Devices"),
          )}</button>
          <button type="button" class="cc-btn-secondary" id="btn-about-jump-diagnostics">${ctx.escapeHtml(
            tr3("复制脱敏诊断报告", "複製去識別化診斷報告", "Copy Diagnostics Report"),
          )}</button>
        </div>
      </div>

      <div class="cc-field">
        <div class="cc-field-row">
          <label>${ctx.escapeHtml(tr3("反馈问题", "回饋問題", "Report a Problem"))}</label>
          <button type="button" class="cc-btn-primary" id="btn-about-report-problem">${ctx.escapeHtml(
            tr3("反馈问题", "回饋問題", "Report a Problem"),
          )}</button>
        </div>
      </div>
    </div>

    <details class="cc-conn-secondary" data-conn-section="aboutAdvanced">
      <summary class="cc-conn-secondary-summary">${ctx.escapeHtml(tr3("高级", "進階", "Advanced"))}</summary>
    <div class="cc-settings-group-card">
      <div class="cc-field" data-settings-anchor="signOut">
        <div class="cc-field-row">
          <div>
            <label>${ctx.escapeHtml(
              tr3("退出并清除所有账号与密钥", "登出並清除所有帳號與金鑰", "Sign Out & Revoke All Credentials"),
            )}</label>
            <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
              tr3(
                "退出米家，清除 HA、AI 与本机集成密钥，回到示例家庭",
                "登出米家，清除 HA、AI 與本機整合金鑰，回到範例家庭",
                "Signs out of Xiaomi and clears HA, AI and local-integration keys, then returns to the demo home",
              ),
            )}</p>
          </div>
          <button type="button" class="cc-btn-danger" id="btn-revoke-all-credentials">${ctx.escapeHtml(
            tr3("退出并清除全部", "登出並清除全部", "Sign Out & Clear All"),
          )}</button>
        </div>
        <div
          id="settings-revoke-all-confirm"
          class="cc-update-row"
          hidden
          role="alert"
          style="margin-top: 6px; padding: 8px; border-radius: 8px; background: rgba(231, 76, 60, 0.14); gap: 6px; flex-wrap: wrap;"
        >
          <span style="font-size: 12px;">${ctx.escapeHtml(
            tr3(
              "确认退出并清除本机保存的所有账号会话、HA 密钥、全部 AI 密钥与本地桥接密钥？此操作不可撤销。",
              "確認登出並清除本機儲存的所有帳號工作階段、HA 金鑰、全部 AI 金鑰與本機橋接金鑰？此操作無法復原。",
              "Sign out and permanently delete all saved Xiaomi sessions, HA tokens, AI API keys, and local bridge tokens?",
            ),
          )}</span>
          <div style="display: flex; gap: 6px; margin-left: auto;">
            <button type="button" class="cc-btn-secondary" id="btn-cancel-revoke-all">${ctx.escapeHtml(
              tr3("取消", "取消", "Cancel"),
            )}</button>
            <button type="button" class="cc-btn-danger" id="btn-confirm-revoke-all">${ctx.escapeHtml(
              tr3("确认清除全部", "確認清除全部", "Revoke Everything"),
            )}</button>
          </div>
        </div>
      </div>
    </div>
    </details>

    <div class="cc-settings-group-card">
      <div class="cc-field cc-field-row" data-settings-anchor="quitApp">
        <label>${t("退出 MenuBarHome")}</label>
        <button class="cc-btn-danger cc-btn-ghost-danger" id="btn-settings-quit" data-settings-anchor="quitApp" title="${ctx.escapeHtml(quitHint)}">${t("退出 MenuBarHome")}</button>
      </div>
    </div>
  `;
}

function defaultEscapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatInlineReleaseNotes(escapedLine: string): string {
  return escapedLine
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

/**
 * Renders GitHub release notes Markdown headings, bullet lists, inline code, and paragraphs
 * safely after HTML-escaping every line upfront so raw HTML/scripts can never execute.
 */
export function renderReleaseNotesMarkdown(
  rawNotes: string,
  escapeFn: (value: string) => string = defaultEscapeHtml,
): string {
  const safeEscape = (value: string) => escapeFn(value).replace(/'/g, "&#39;");
  const lines = rawNotes.replace(/\r\n?/g, "\n").split("\n");
  const blocks: string[] = [];
  let listItems: string[] = [];

  const flushList = () => {
    if (listItems.length === 0) return;
    blocks.push(`<ul class="cc-md-list">${listItems.join("")}</ul>`);
    listItems = [];
  };

  for (const rawLine of lines) {
    const trimmed = rawLine.trim();
    if (!trimmed) {
      flushList();
      continue;
    }
    const headingMatch = /^(#{1,3})\s+(.+)$/.exec(trimmed);
    if (headingMatch) {
      flushList();
      const level = headingMatch[1]!.length;
      const tag = level === 1 ? "h4" : level === 2 ? "h5" : "h6";
      const content = formatInlineReleaseNotes(safeEscape(headingMatch[2]!.trim()));
      blocks.push(`<${tag} class="cc-md-heading">${content}</${tag}>`);
      continue;
    }
    const bulletMatch = /^[-*+]\s+(.+)$/.exec(trimmed);
    if (bulletMatch) {
      const content = formatInlineReleaseNotes(safeEscape(bulletMatch[1]!.trim()));
      listItems.push(`<li>${content}</li>`);
      continue;
    }
    flushList();
    blocks.push(`<p class="cc-md-p">${formatInlineReleaseNotes(safeEscape(trimmed))}</p>`);
  }
  flushList();
  return blocks.join("");
}

function formatBytesMegabytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0.0 MB";
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function renderUpdateDownloadProgress(
  progress: UpdateDownloadProgress | null,
  escapeHtml: (value: string) => string,
): string {
  if (!progress || progress.downloadedBytes <= 0) return "";
  const hasTotal = progress.totalBytes > 0 && progress.totalBytes >= progress.downloadedBytes;
  const percent = hasTotal
    ? Math.min(100, Math.round((progress.downloadedBytes / progress.totalBytes) * 100))
    : null;
  const sizePart = hasTotal
    ? `${formatBytesMegabytes(progress.downloadedBytes)} / ${formatBytesMegabytes(progress.totalBytes)} (${percent}%)`
    : formatBytesMegabytes(progress.downloadedBytes);
  const speedPart =
    progress.bytesPerSec > 0 ? ` · ${formatBytesMegabytes(progress.bytesPerSec)}/s` : "";
  return `
    <div class="cc-update-progress" data-update-progress>
      <progress max="100" ${percent !== null ? `value="${percent}"` : ""} style="width: 100%; height: 6px;"></progress>
      <div class="cc-field-hint">${escapeHtml(`${sizePart}${speedPart}`)}</div>
    </div>`;
}

  export function renderUpdateSection(ctx: SettingsViewContext): string {
    const release = ctx.availableUpdate;
    const hasInstaller = Boolean(release?.installerAsset);
    const notes = release?.notes?.trim() ?? "";
    const statusText = ctx.updateStatusMessage?.text ?? "";
    const activeProgress = ctx.isInstallingUpdate
      ? (ctx.updateProgress ?? getUpdateProgressForSettings(ctx.settings))
      : null;
    return `
      <div class="cc-field cc-update-card ${release ? "is-available" : ""}" data-settings-anchor="softwareUpdate">
        <label>${release ? t("发现新版本 v{version}", { version: release.version }) : t("软件更新")}</label>
        <div class="cc-update-row" data-settings-anchor="aboutVersion">
          <span>${t("当前版本 v{version}", { version: APP_VERSION })}</span>
          <div class="cc-update-actions">
            ${
              release
                ? `${
                    hasInstaller
                      ? `<button type="button" class="cc-btn-primary" id="btn-install-update" ${ctx.isInstallingUpdate ? "disabled" : ""}>${ctx.isInstallingUpdate ? t("正在更新…") : t("立即更新")}</button>`
                      : ""
                  }
                  <button type="button" class="cc-btn-secondary" id="btn-open-update">${
                    hasInstaller ? t("手动下载") : t("有新版本 v{version}，点击查看", { version: release.version })
                  }</button>`
                : `<button type="button" class="cc-btn-secondary" id="btn-check-update" ${ctx.isCheckingUpdate ? "disabled" : ""}>${ctx.isCheckingUpdate ? t("检查中…") : t("立即检查")}</button>`
            }
          </div>
        </div>
        ${
          statusText
            ? `<div class="cc-update-status ${ctx.updateStatusMessage?.isError ? "is-error" : ""}">${ctx.escapeHtml(statusText)}</div>`
            : ""
        }
        ${renderUpdateDownloadProgress(activeProgress, (v) => ctx.escapeHtml(v))}
        ${notes ? `<div class="cc-update-notes">${renderReleaseNotesMarkdown(notes, (v) => ctx.escapeHtml(v))}</div>` : ""}
        <label class="cc-checkbox" style="margin-top: 6px;">
          <input type="checkbox" id="settings-auto-update" ${ctx.settings.autoCheckUpdates ? "checked" : ""} />
          <span>${t("自动检查更新")}</span>
        </label>
      </div>
    `;
  }
