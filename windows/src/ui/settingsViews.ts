import {
  ASSISTANT_PROVIDER_PRESETS,
  inferAssistantPreset,
  listReadableHabits,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import { currentLanguage, speechLocale, t, type AppLanguage } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { trText } from "../core/quickActions.js";
import {
  getUpdateProgressForSettings,
  hasPendingMiVaultDeletion,
  type UpdateDownloadProgress,
} from "./speechGuard.js";
import type { GitHubRelease } from "../core/updateChecker.js";
import type { QRLoginTicket } from "../core/miCloudClient.js";
import {
  MI_CLOUD_REGIONS,
  maskedMiUserId,
  miCloudRegionLabel,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import { joinsAllOff, type HomeScene, type SmartDevice } from "../core/models.js";
import {
  APPEARANCES,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  PANEL_HEIGHTS,
  PANEL_OPACITY_MAX,
  PANEL_OPACITY_MIN,
  type PanelAnchor,
} from "./panelPrefs.js";
import type { PersistedSettings } from "./appTypes.js";
import { APP_VERSION, SF_ICONS } from "./appConstants.js";
import { readAskWhenUnsure } from "./settings.js";

function tr3(zhHans: string, zhHant: string, en: string, lang: AppLanguage = currentLanguage()): string {
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

/** The four Settings categories (#78). The value is stored so a re-render keeps the open tab. */
export type SettingsTab = "general" | "connection" | "assistant" | "system";

/** Tab bar order; `title` is the catalog key, so a missing translation would fail i18n.test.ts. */
const SETTINGS_TABS: ReadonlyArray<{ readonly id: SettingsTab; readonly title: string }> = [
  { id: "general", title: "外观与面板" },
  { id: "connection", title: "数据源" },
  { id: "assistant", title: "AI 与习惯" },
  { id: "system", title: "全关与更新" },
];

/**
 * Text fields whose typed text a live re-render must not throw away. The panels all stay in the
 * DOM, so switching tabs already keeps a draft; these ids cover the refresh-driven rebuilds.
 */
const DRAFT_VALUE_IDS: readonly string[] = [
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
  return { values, checks };
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
  const baseEl = root.querySelector<HTMLInputElement>("#settings-base-url");
  if (baseEl) {
    const preset = inferAssistantPreset(baseEl.value);
    root.querySelectorAll<HTMLElement>("[data-ai-preset]").forEach((el) => {
      el.classList.toggle("is-active", el.dataset.aiPreset === preset.id);
    });
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
  readonly availableUpdate: GitHubRelease | null;
  readonly activeTab: SettingsTab;
  readonly apiKeyFor: (baseURL: string) => string;
  readonly habitSequences: () => readonly HabitSequenceEntry[];
  readonly hotkeyNeedsHint: boolean;
  readonly hotkeyRegistrationError: string | null;
  readonly isPollingQR: boolean;
  readonly isRecordingHotkey: boolean;
  readonly panelAnchor: PanelAnchor;
  readonly qrStatusText: string;
  readonly qrTicket: QRLoginTicket | null;
  readonly isCheckingUpdate: boolean;
  readonly isInstallingUpdate: boolean;
  readonly updateStatusMessage: { text: string; isError: boolean } | null;
  readonly updateProgress?: UpdateDownloadProgress | null;
  escapeHtml(value: string): string;
}

  /**
   * Three-zone sheet: a fixed header with the close button, search bar and category tabs, one scrolling
   * body holding all four panels, and a fixed footer with 完成并保存 (#78). Every panel stays in the
   * DOM behind `hidden`, so a typed draft survives a tab switch and 完成并保存 reads every input no
   * matter which tab is open.
   */
  export function renderSettingsModal(ctx: SettingsViewContext): string {
    const searchPlaceholder = tr3(
      "搜索设置项（开机自启 / 密钥 / 全关 / 习惯 / 锁屏…）",
      "搜尋設定項（開機自啟 / 金鑰 / 全關 / 習慣 / 鎖屏…）",
      "Search settings (startup, token, all off, habits, lock…)",
    );
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet cc-settings-sheet" role="dialog" aria-modal="true" aria-label="${t("偏好设置")}">
          <div class="cc-settings-top">
            <div class="cc-sheet-header">
              <strong>${t("偏好设置")}</strong>
              <button class="cc-circle-btn is-small" id="btn-close-settings" title="${t("返回控制中心")}" aria-label="${t("返回控制中心")}">
                ${SF_ICONS.xmark}
              </button>
            </div>

            <div
              id="settings-unsaved-confirm"
              class="cc-update-row"
              hidden
              role="alert"
              style="margin-top: 6px; padding: 6px 8px; border-radius: 8px; background: rgba(230, 126, 34, 0.14); gap: 6px; flex-wrap: wrap;"
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

            <div class="cc-settings-search" style="position: relative; margin: 6px 0;">
              <div style="display: flex; gap: 6px; align-items: center;">
                <input
                  id="settings-search-input"
                  class="cc-input"
                  type="search"
                  autocomplete="off"
                  placeholder="${ctx.escapeHtml(searchPlaceholder)}"
                  aria-label="${ctx.escapeHtml(tr3("搜索偏好设置", "搜尋偏好設定", "Search Preferences"))}"
                  style="flex: 1;"
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
                role="listbox"
                hidden
                style="margin-top: 4px; max-height: 210px; overflow-y: auto; border-radius: 8px; padding: 4px; background: rgba(128, 128, 128, 0.12);"
              ></div>
            </div>

            <div class="cc-segmented-pills is-even cc-settings-tabs" role="tablist" aria-label="${t("设置分类")}">
              ${SETTINGS_TABS.map((tab) => {
                const active = tab.id === ctx.activeTab;
                return `<button type="button" class="cc-seg-pill ${active ? "is-active" : ""}" data-settings-tab="${tab.id}" role="tab" aria-selected="${active}">${ctx.escapeHtml(t(tab.title))}</button>`;
              }).join("")}
            </div>
          </div>

          <div class="cc-sheet-body">
            ${renderSettingsTabPanel(ctx, "general", renderGeneralPanel)}
            ${renderSettingsTabPanel(ctx, "connection", renderConnectionPanel)}
            ${renderSettingsTabPanel(ctx, "assistant", renderAssistantPanel)}
            ${renderSettingsTabPanel(ctx, "system", renderSystemPanel)}
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-danger cc-btn-ghost-danger" id="btn-settings-quit" data-settings-anchor="quitApp">${t("退出 MenuBarHome")}</button>
            <span class="cc-settings-save-hint" data-save-state="clean" title="${ctx.escapeHtml(trText("开关即时生效，地址与密钥点右侧保存", "Toggles apply instantly; click Save for URLs & keys"))}">${ctx.escapeHtml(trText("开关已即时生效", "Toggles auto-save"))}</span>
            <button class="cc-btn-primary" id="btn-save-settings">${t("完成并保存")}</button>
          </div>
        </div>
      </div>
    `;
  }

function renderSettingsTabPanel(
  ctx: SettingsViewContext,
  tabId: SettingsTab,
  renderBody: (ctx: SettingsViewContext) => string,
): string {
  const hidden = ctx.activeTab !== tabId ? "hidden" : "";
  return `<div class="cc-settings-tab-panel" role="tabpanel" data-settings-panel="${tabId}" ${hidden}>${renderBody(ctx)}</div>`;
}

function renderGeneralPanel(ctx: SettingsViewContext): string {
  return `
    ${ctx.availableUpdate ? renderUpdateSection(ctx) : ""}

    <div class="cc-field" data-settings-anchor="appearanceMode">
      <label>${t("外观模式")}</label>
      <div class="cc-segmented-pills is-even">
        ${APPEARANCES.map(
          (a) =>
            `<button class="cc-seg-pill ${ctx.settings.appearance === a.id ? "is-active" : ""}" data-appearance="${a.id}" aria-pressed="${ctx.settings.appearance === a.id}">${ctx.escapeHtml(a.title)}</button>`,
        ).join("")}
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
      <p class="cc-field-hint">${t("壁纸透出导致文字看不清时调高；100% 为不透明。")}</p>
    </div>

    <div class="cc-field" data-settings-anchor="language">
      <label>${t("界面语言 / 语言")}</label>
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

    <div class="cc-field" data-settings-anchor="panelHeight">
      <label>${t("面板高度")}</label>
      <div class="cc-segmented-pills">
        ${PANEL_HEIGHTS.map((h) => `<button class="cc-seg-pill ${ctx.settings.panelHeight === h.id ? "is-active" : ""}" data-panel-height="${h.id}" aria-pressed="${ctx.settings.panelHeight === h.id}">${h.title}</button>`).join("")}
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="panelAnchor">
      <label>${t("面板位置")}</label>
      <div class="cc-segmented-pills">
        ${PANEL_ANCHORS.map((a) => `<button class="cc-seg-pill ${ctx.panelAnchor === a.id ? "is-active" : ""}" data-panel-anchor="${a.id}" aria-pressed="${ctx.panelAnchor === a.id}">${ctx.escapeHtml(a.title)}</button>`).join("")}
      </div>
      <p class="cc-field-hint">${t("拖动面板顶部即可移动，松开后吸附到最近的角落。")}</p>
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="climatePanelModule">
      <label for="settings-climate-panel">${t("空调使用整行控制条")}</label>
      <input id="settings-climate-panel" type="checkbox" ${ctx.settings.climatePanel ? "checked" : ""} />
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="hideOfflineDevices">
      <label for="settings-hide-offline">${t("隐藏离线/未通电的设备")}</label>
      <input id="settings-hide-offline" type="checkbox" ${ctx.settings.hideOfflineDevices ? "checked" : ""} />
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="hideGroupedLights">
      <label for="settings-hide-grouped-lights">${t("灯组内的单灯不重复显示")}</label>
      <input id="settings-hide-grouped-lights" type="checkbox" ${ctx.settings.hideGroupedLights ? "checked" : ""} />
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="quickScenesBar">
      <label for="settings-quick-actions">${t("显示顶部快捷场景栏")}</label>
      <input id="settings-quick-actions" type="checkbox" ${ctx.settings.showQuickActionsBar ? "checked" : ""} />
    </div>

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
    </div>

    <div class="cc-field" data-settings-anchor="voiceControl">
      <label>${ctx.escapeHtml(tr3("语音指令与麦克风", "語音指令與麥克風", "Voice Dictation & Microphone"))}</label>
      <p class="cc-field-hint">${ctx.escapeHtml(
        tr3(
          "点击面板顶部麦克风按钮即可开始语音听写，自动跟随当前界面语言。",
          "點擊面板頂部麥克風按鈕即可開始語音聽寫，自動跟隨目前介面語言。",
          "Click the microphone icon at the top of the panel to dictate commands in your UI language.",
        ),
      )}</p>
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="setupGuide">
      <div>
        <label>${ctx.escapeHtml(tr3("首次设置与新手引导", "首次設定與新手引導", "Setup & Onboarding Guide"))}</label>
        <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
          tr3(
            "随时重新打开三步上手引导，查看连接、快捷键与全关撤销演练。",
            "隨時重新打開三步上手引導，查看連線、快速鍵與全關復原演練。",
            "Reopen the 3-step onboarding guide anytime to review connections, shortcuts, and All Off.",
          ),
        )}</p>
      </div>
      <button type="button" class="cc-btn-secondary" id="btn-reopen-onboarding">${ctx.escapeHtml(
        tr3("重新查看新手引导", "重新查看新手引導", "Reopen Setup Guide"),
      )}</button>
    </div>
  `;
}

function renderHomeAssistantCredentialsBlock(ctx: SettingsViewContext): string {
  return `
    <div class="cc-field">
      <div data-settings-anchor="haServerAddress">
        <label for="settings-ha-url">Home Assistant URL</label>
        <input id="settings-ha-url" class="cc-input" type="url" value="${ctx.escapeHtml(ctx.settings.haBaseURL)}" placeholder="http://homeassistant.local:8123" />
      </div>
      <div data-settings-anchor="haToken" style="margin-top: 6px;">
        <label for="settings-ha-token">Home Assistant access token</label>
        <input id="settings-ha-token" class="cc-input" type="password" autocomplete="off" value="${ctx.escapeHtml(ctx.settings.haToken)}" />
      </div>
    </div>
  `;
}

function renderXiaomiCloudBlock(ctx: SettingsViewContext): string {
  return `
    <div class="cc-field" data-settings-anchor="miCloudRegion">
      <label>${t("云端服务器地区")}</label>
      <select class="cc-input" data-mi-region>
        ${MI_CLOUD_REGIONS.map(
          (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(ctx.settings.miCloudRegion) === region.code ? "selected" : ""}>${ctx.escapeHtml(t(region.label))}</option>`,
        ).join("")}
      </select>
      <p class="cc-field-hint">${ctx.escapeHtml(t("当前选择：{region}。切换后请重新扫码登录该地区的米家账号；已登录会话仍使用登录时的地区。", { region: t(miCloudRegionLabel(ctx.settings.miCloudRegion)) }))}</p>
    </div>

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
  `;
}

function renderConnectionPanel(ctx: SettingsViewContext): string {
  const activeBadge = `<span class="cc-conn-active-badge">${ctx.escapeHtml(trText("当前使用", "Active"))}</span>`;
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
        <strong>${ctx.escapeHtml(t("演示设备预览"))}</strong>
        ${activeBadge}
      </div>
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
        >
          ${t("演示设备预览")}
        </button>
      </div>
    </div>
    ${modeBlocks}
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
  const readableHabits = listReadableHabits({
    entries: ctx.settings.habitEntries,
    sequences: ctx.habitSequences(),
    phrases: ctx.settings.learnedShortcuts.map((s) => ({ phrase: s.phrase, summary: s.reply })),
    devices: ctx.devices,
    scenes: ctx.scenes ?? [],
  });

  return `
    <div class="cc-field" data-settings-anchor="assistantProvider">
      <label>${t("AI 服务商预设（支持 OpenRouter Jev、原生 Jev、DeepSeek、千问、GLM 等）")}</label>
      <div class="cc-segmented-pills" style="flex-wrap: wrap;">
        ${ASSISTANT_PROVIDER_PRESETS.map((preset) => {
          const label =
            preset.id === "custom"
              ? tr3("自定义", "自訂", "Custom")
              : preset.shortTitle;
          return `<button
            type="button"
            class="cc-seg-pill ${currentPreset.id === preset.id ? "is-active" : ""}"
            data-ai-preset="${ctx.escapeHtml(preset.id)}"
          >${ctx.escapeHtml(label)}</button>`;
        }).join("")}
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="assistantBaseURL">
      <label>${t("AI 服务地址（支持 /v1/systemone 与 OpenAI 兼容 /v1/chat/completions）")}</label>
      <input
        id="settings-base-url"
        class="cc-input"
        type="text"
        placeholder="https://openrouter.ai/api/v1"
        value="${ctx.escapeHtml(ctx.settings.assistantBaseURL)}"
      />
    </div>

    <div class="cc-field" data-settings-anchor="assistantModel">
      <label>${t("决策模型（如 ~typesafe/jev-latest、jev-latest、deepseek-chat）")}</label>
      <input
        id="settings-model"
        class="cc-input"
        type="text"
        value="${ctx.escapeHtml(ctx.settings.assistantModel)}"
      />
    </div>

    <div class="cc-field" data-settings-anchor="assistantAPIKey">
      <label>${t("API Key（本机安全保存）")}</label>
      <input
        id="settings-api-key"
        class="cc-input"
        type="password"
        placeholder="${ctx.escapeHtml(currentPreset.keyPlaceholder)}"
        value="${ctx.escapeHtml(ctx.apiKeyFor(ctx.settings.assistantBaseURL))}"
      />
      <div class="cc-update-row" data-settings-anchor="assistantEnvImport" style="margin-top: 6px; gap: 6px; flex-wrap: wrap;">
        <button type="button" class="cc-inline-pill" id="btn-import-env-key">${ctx.escapeHtml(
          tr3(
            "从环境变量导入 API Key",
            "從環境變數匯入 API Key",
            "Import API Key from Environment",
          ),
        )}</button>
        <span id="settings-env-import-status" class="cc-field-hint" style="margin: 0;"></span>
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="assistantTest">
      <div class="cc-update-row" style="gap: 8px; flex-wrap: wrap;">
        <div>
          <label>${ctx.escapeHtml(tr3("连通性检测", "連通性檢測", "Connection Check"))}</label>
          <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
            tr3(
              "向当前配置的 AI 端点发送最小探针，检测响应耗时与密钥有效性。",
              "向目前設定的 AI 端點傳送最小探針，檢測回應耗時與金鑰有效性。",
              "Send a minimal probe to the configured AI endpoint to verify latency and key validity.",
            ),
          )}</p>
        </div>
        <button type="button" class="cc-btn-secondary" id="btn-test-ai-connection">${ctx.escapeHtml(
          tr3("测试 AI 连接", "測試 AI 連線", "Test AI Connection"),
        )}</button>
      </div>
      <div id="settings-ai-test-status" class="cc-field-hint" style="margin-top: 4px;"></div>
    </div>

    <div class="cc-field cc-field-row" data-settings-anchor="askWhenUnsure">
      <div>
        <label for="settings-ask-when-unsure">${ctx.escapeHtml(
          tr3("AI 不确定时先让我确认", "AI 不確定時先讓我確認", "Ask Me When AI Is Unsure"),
        )}</label>
        <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
          tr3(
            "当指令存在歧义或把握度偏低时，先展示候选操作卡片供你确认。",
            "當指令存在歧義或把握度偏低時，先展示候選操作卡片供你確認。",
            "Show confirmation chips instead of acting immediately when an utterance is ambiguous.",
          ),
        )}</p>
      </div>
      <input id="settings-ask-when-unsure" type="checkbox" ${askWhenUnsure ? "checked" : ""} />
    </div>

    ${
      ctx.settings.cloudConsentEndpoints.length > 0
        ? `<div class="cc-field" data-settings-anchor="cloudConsent">
      <label>${t("已允许发送到：{endpoints}", { endpoints: ctx.escapeHtml(ctx.settings.cloudConsentEndpoints.join("、")) })}</label>
      <button type="button" class="cc-btn-secondary" id="btn-revoke-cloud">${t("撤销授权（下次发往云端前再问）")}</button>
    </div>`
        : ""
    }

    <div class="cc-field" data-settings-anchor="habitMemory">
      <label class="cc-checkbox">
        <input type="checkbox" id="settings-habit" ${ctx.settings.habitLearningEnabled ? "checked" : ""} />
        <span>${t("自动记住自然语言习惯（相同表达下次 0ms 本地直达）")}</span>
      </label>
      <div data-settings-anchor="habitShare">
        <label class="cc-checkbox">
          <input type="checkbox" id="settings-habit-share" ${ctx.settings.habitShareEnabled ? "checked" : ""} />
          <span>${t("发送习惯摘要（只包含这句话点名的设备）")}</span>
        </label>
        <label>${t("预览这句话会发送的习惯摘要")}</label>
        <input id="settings-habit-share-sample" class="cc-input" type="text" />
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
        ctx.settings.habitEntries.length > 0 || ctx.habitSequences().length > 0 || readableHabits.length > 0
          ? `<div class="cc-timers-stack">
              <div class="cc-timer-row" style="gap: 6px; flex-wrap: wrap;">
                <span style="flex: 1;">${t("已学习 {count} 条时段习惯、{sequences} 条先后习惯（用于猜你想控）", {
                  count: ctx.settings.habitEntries.length,
                  sequences: ctx.habitSequences().length,
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
  `;
}

/** 全关与更新: what 全关 switches off, companion/security controls, plus the update card when none is waiting on the general tab. */
function renderSystemPanel(ctx: SettingsViewContext): string {
  return `
    <div class="cc-field">
      <label>${t("自动化与安全控制")}</label>
      <div data-settings-anchor="blockControlWhileLocked">
        <div class="cc-field-row" style="margin-top: 4px;">
          <label for="settings-block-while-locked">${t("锁屏时禁止控制设备")}</label>
          <input id="settings-block-while-locked" type="checkbox" ${ctx.settings.blockControlWhileLocked ? "checked" : ""} />
        </div>
        <p class="cc-field-hint">${t("锁屏期间拦截手动与外部链接控制；已设好的定时任务仍按时执行。")}</p>
      </div>

      <div data-settings-anchor="raycast">
        <div class="cc-field-row" style="margin-top: 8px;">
          <label for="settings-raycast-integration">${t("Raycast 与本地 CLI / MCP 集成")}</label>
          <input id="settings-raycast-integration" type="checkbox" ${ctx.settings.enableRaycastIntegration ? "checked" : ""} />
        </div>
        <p class="cc-field-hint">${t("在 %LOCALAPPDATA%\\MenuBarMijia 导出设备快照并签发本机令牌（不含账号凭据）；关闭后立即删除快照并吊销令牌。")}</p>
      </div>

      <div data-settings-anchor="allowURLControl">
        <div class="cc-field-row" style="margin-top: 8px;">
          <label for="settings-allow-direct-url">${t("允许 menumijia:// 外部链接免确认直控")}</label>
          <input id="settings-allow-direct-url" type="checkbox" ${ctx.settings.allowDirectURLControl ? "checked" : ""} />
        </div>
        <p class="cc-field-hint">${t("关闭时，未携带本机令牌的外部网页或快捷方式链接须先在面板中确认；高风险设备与锁屏拦截始终生效。")}</p>
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="advancedDeviceWrites">
      <div class="cc-field-row">
        <label for="settings-allow-advanced-facets">${t("允许写入高级/高风险设备属性")}</label>
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

    <div class="cc-field" data-settings-anchor="allOffDevices">
      <label>${t("「全关」包含哪些设备（插座、扫地机默认不包含）")}</label>
      <div class="cc-timers-stack">
        ${ctx.devices
          .filter((d) => d.kind.kind !== "sensor" && d.kind.kind !== "fridge")
          .map(
            (d) => `
          <label class="cc-checkbox">
            <input type="checkbox" data-alloff-device="${ctx.escapeHtml(d.id)}" ${joinsAllOff(d, ctx.settings.allOffOverrides) ? "checked" : ""} />
            <span>${ctx.escapeHtml(d.name)}${d.roomName ? ` · ${ctx.escapeHtml(d.roomName)}` : ""}</span>
          </label>`,
          )
          .join("")}
      </div>
    </div>

    <div class="cc-field" data-settings-anchor="signOut">
      <div class="cc-field-row">
        <div>
          <label>${ctx.escapeHtml(
            tr3("退出并清除所有账号与密钥", "登出並清除所有帳號與金鑰", "Sign Out & Revoke All Credentials"),
          )}</label>
          <p class="cc-field-hint" style="margin: 2px 0 0 0;">${ctx.escapeHtml(
            tr3(
              "一键清除米家会话、Home Assistant 令牌、全部 AI 服务商 API Key 及本机快照桥接令牌。",
              "一鍵清除米家工作階段、Home Assistant 權杖、全部 AI 服務商 API Key 及本機快照橋接權杖。",
              "Clear Xiaomi session, Home Assistant token, all AI provider API keys, and local bridge tokens at once.",
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
            "确认退出并清除本机保存的所有账号会话、HA 令牌、全部 AI 密钥与本地桥接令牌？此操作不可撤销。",
            "確認登出並清除本機儲存的所有帳號工作階段、HA 權杖、全部 AI 金鑰與本機橋接權杖？此操作無法復原。",
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

    ${!ctx.availableUpdate ? renderUpdateSection(ctx) : ""}
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
    const statusText = ctx.updateStatusMessage?.text ?? (release && hasInstaller ? t("可直接下载并安装，无需打开浏览器") : "");
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
          <span>${t("每天自动检查更新（关闭后不再请求 GitHub）")}</span>
        </label>
      </div>
    `;
  }
