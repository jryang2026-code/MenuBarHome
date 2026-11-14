import {
  ASSISTANT_PROVIDER_PRESETS,
  ModelIntentResolver,
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  inferAssistantPreset,
  parseAssistantEndpoint,
  type AssistantConfig,
  type AssistantProviderPresetInfo,
} from "../core/assistant.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { currentLanguage, t, type AppLanguage } from "../core/i18n.js";
import { MI_CLOUD_REGIONS, maskedMiUserId, normalizeMiCloudRegion } from "../core/miCloudClient.js";
import { SF_ICONS } from "./appConstants.js";
import type { ConnectionMode } from "./appTypes.js";
import { demoDevices, demoScenes } from "./demo.js";
import type { SettingsEventsHost } from "./settingsEvents.js";
import { invokeTauriVoid } from "./transport.js";

export type AssistantProviderPresetId = string;
type AssistantProviderPreset = AssistantProviderPresetInfo;

export const PROVIDER_ENV_VARS: Readonly<Record<AssistantProviderPresetId, readonly string[]>> = {
  openrouter_jev: ["OPENROUTER_API_KEY"],
  native_jev: ["TYPESAFE_API_KEY", "JEV_API_KEY"],
  deepseek: ["DEEPSEEK_API_KEY"],
  siliconflow: ["SILICONFLOW_API_KEY"],
  dashscope: ["DASHSCOPE_API_KEY"],
  zhipu_glm: ["ZHIPU_API_KEY", "GLM_API_KEY"],
  moonshot_kimi: ["MOONSHOT_API_KEY", "KIMI_API_KEY"],
  openai: ["OPENAI_API_KEY"],
  gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
  groq: ["GROQ_API_KEY"],
  ollama: [],
  custom: [],
};

export function presetSupportsEnvKeyImport(presetId: AssistantProviderPresetId): boolean {
  return (PROVIDER_ENV_VARS[presetId]?.length ?? 0) > 0;
}

export interface ImportedEnvKeyResult {
  readonly envName: string;
  readonly apiKey: string;
}

export type EnvVarReader = (name: string) => string | undefined | Promise<string | undefined>;

function defaultReadEnvVar(name: string): string | undefined | Promise<string | undefined> {
  const proc = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process;
  const fromProcess = proc?.env?.[name];
  if (typeof fromProcess === "string" && fromProcess.trim() !== "") {
    return fromProcess.trim();
  }
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (invoke) {
    return invoke<unknown>("get_env_var", { name })
      .then((val) => (typeof val === "string" && val.trim() !== "" ? val.trim() : undefined))
      .catch(() => undefined);
  }
  return undefined;
}

export async function importAmbientAssistantKey(
  presetId: AssistantProviderPresetId,
  readEnv: EnvVarReader = defaultReadEnvVar,
): Promise<ImportedEnvKeyResult | null> {
  const candidates = PROVIDER_ENV_VARS[presetId] ?? [];
  for (const envName of candidates) {
    try {
      const raw = await readEnv(envName);
      if (typeof raw === "string" && raw.trim() !== "") {
        return { envName, apiKey: raw.trim() };
      }
    } catch {
      continue;
    }
  }
  return null;
}

export interface AssistantDraftState {
  readonly selectedPreset: AssistantProviderPresetId;
  readonly showsCustomEndpointFields: boolean;
  readonly baseURL: string;
  readonly model: string;
  readonly apiKey: string;
}

function findPreset(id: AssistantProviderPresetId): AssistantProviderPreset {
  return (
    ASSISTANT_PROVIDER_PRESETS.find((p) => p.id === id) ??
    ASSISTANT_PROVIDER_PRESETS[0]!
  );
}

export function createInitialAssistantDraftState(
  baseURL: string,
  model: string,
  storedKeyForURL: (url: string) => string,
): AssistantDraftState {
  const inferred = inferAssistantPreset(baseURL);
  return {
    selectedPreset: inferred.id,
    showsCustomEndpointFields: inferred.id === "custom",
    baseURL,
    model,
    apiKey: storedKeyForURL(baseURL),
  };
}

export function selectAssistantPresetDraft(
  newPresetId: AssistantProviderPresetId,
  current: AssistantDraftState,
  storedKeyForURL: (url: string) => string,
): AssistantDraftState {
  const oldPreset = findPreset(current.selectedPreset);
  if (newPresetId === "custom") {
    const nextModel =
      current.model === oldPreset.defaultModel || ModelIntentResolver.isSystemOneModel(current.model)
        ? "gpt-4o-mini"
        : current.model;
    return {
      selectedPreset: "custom",
      showsCustomEndpointFields: true,
      baseURL: "",
      model: nextModel,
      apiKey: "",
    };
  }
  const nextPreset = findPreset(newPresetId);
  return {
    selectedPreset: nextPreset.id,
    showsCustomEndpointFields: false,
    baseURL: nextPreset.defaultBaseURL,
    model: nextPreset.defaultModel,
    apiKey: storedKeyForURL(nextPreset.defaultBaseURL),
  };
}

export function updateAssistantBaseURLDraft(
  newBaseURL: string,
  current: AssistantDraftState,
  storedKeyForURL: (url: string) => string,
): AssistantDraftState {
  const oldPreset = findPreset(current.selectedPreset);
  const oldURL = current.baseURL;
  let nextApiKey = current.apiKey;
  let nextModel = current.model;
  const inferred = inferAssistantPreset(newBaseURL);

  if (
    inferred.id === "custom" &&
    current.selectedPreset === "custom" &&
    assistantEndpointIdentity(newBaseURL) !== assistantEndpointIdentity(oldURL) &&
    (nextApiKey === "" || nextApiKey === storedKeyForURL(oldURL))
  ) {
    nextApiKey = storedKeyForURL(newBaseURL);
  }

  if (inferred.id !== current.selectedPreset) {
    nextApiKey = storedKeyForURL(newBaseURL);
    if (inferred.defaultModel !== "") {
      nextModel = inferred.defaultModel;
    } else if (nextModel === oldPreset.defaultModel || ModelIntentResolver.isSystemOneModel(nextModel)) {
      nextModel = "gpt-4o-mini";
    }
  }

  return {
    selectedPreset: inferred.id,
    showsCustomEndpointFields: current.showsCustomEndpointFields,
    baseURL: newBaseURL,
    model: nextModel,
    apiKey: nextApiKey,
  };
}

export function resolveAssistantDraftForSave(
  state: AssistantDraftState,
): (AssistantConfig & { readonly presetId: AssistantProviderPresetId }) | null {
  const trimmedBase = state.baseURL.trim();
  if (state.selectedPreset === "custom" && trimmedBase === "") {
    return null;
  }
  const preset = findPreset(state.selectedPreset);
  const fallbackBase = preset.defaultBaseURL || "https://openrouter.ai/api/v1";
  const resolvedBase = trimmedBase || fallbackBase;
  const inferred = inferAssistantPreset(resolvedBase);
  const fallbackModel = inferred.defaultModel || preset.defaultModel || "gpt-4o-mini";
  const resolvedModel = state.model.trim() || fallbackModel;
  return {
    baseURL: resolvedBase,
    model: resolvedModel,
    apiKey: state.apiKey.trim(),
    presetId: inferred.id,
  };
}

function tr3(zhHans: string, zhHant: string, en: string, lang: AppLanguage = currentLanguage()): string {
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

interface OnboardingSessionState {
  selectedMode: ConnectionMode;
  haURLDraft: string;
  haTokenDraft: string;
  assistantDraft: AssistantDraftState;
  statusNote: { text: string; isError: boolean } | null;
}

const onboardingSessionByHost = new WeakMap<object, OnboardingSessionState>();

export function clearOnboardingSession(host: object): void {
  onboardingSessionByHost.delete(host);
}

export interface OnboardingRenderViewHost extends SettingsEventsHost {
  readonly isPollingQR?: boolean;
  readonly qrStatusText?: string;
  readonly qrTicket?: { readonly qrImageURL: string } | null;
  apiKeyFor?(baseURL: string): string;
  escapeHtml?(value: string): string;
}

function escapeHtmlFallback(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function storedKeyForHost(host: OnboardingRenderViewHost, url: string): string {
  if (typeof host.apiKeyFor === "function") {
    return host.apiKeyFor(url);
  }
  const preset = inferAssistantPreset(url);
  if (preset.id !== "custom") {
    return host.assistantKeysByPreset[preset.id] ?? "";
  }
  const endpoint = assistantEndpointIdentity(url);
  if (endpoint && host.settings.assistantCustomKeyEndpoint === endpoint) {
    return host.assistantKeysByPreset["custom"] ?? "";
  }
  return "";
}

function ensureSession(host: OnboardingRenderViewHost): OnboardingSessionState {
  const existing = onboardingSessionByHost.get(host);
  if (existing) return existing;
  const initialMode: ConnectionMode =
    host.settings.connectionMode === "homeAssistant" ||
    host.settings.connectionMode === "xiaomiCloud" ||
    host.settings.connectionMode === "demo"
      ? host.settings.connectionMode
      : "xiaomiCloud";
  const created: OnboardingSessionState = {
    selectedMode: initialMode,
    haURLDraft: host.settings.haBaseURL,
    haTokenDraft: host.settings.haToken,
    assistantDraft: createInitialAssistantDraftState(
      host.settings.assistantBaseURL,
      host.settings.assistantModel,
      (url) => storedKeyForHost(host, url),
    ),
    statusNote: null,
  };
  onboardingSessionByHost.set(host, created);
  return created;
}

function isPlainHttpRemoteURL(rawURL: string): boolean {
  const trimmed = rawURL.trim();
  if (!trimmed) return false;
  const withScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed) ? trimmed : `http://${trimmed}`;
  const parsed = parseAssistantEndpoint(withScheme);
  if (!parsed) return false;
  return !endpointAllowsSendingSecrets(withScheme);
}

function switchConnectionModeInOnboarding(host: OnboardingRenderViewHost, mode: ConnectionMode): void {
  if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
    host.cameraLive.closeCameraLiveView();
  }
  host.localControlRevision += 1;
  host.invalidateSourceControl();
  host.environmentReadings = [];
  host.homes = [];
  host.groupOwnerByMemberDid = new Map();
  host.deviceFacets = {};
  host.clearPendingHighRisk();
  host.replyBanner = null;
  host.settings.connectionMode = mode;
  if (mode !== "xiaomiCloud") host.cloudValuesStale = false;
  host.selectRoom(null);
  if (mode === "demo") {
    host.devices = demoDevices();
    host.scenes = demoScenes();
  } else if (mode === "xiaomiCloud") {
    host.devices = structuredClone(host.settings.cachedXiaomiDevices);
    host.scenes = [];
    if (host.settings.miSession) {
      void host.refreshDevices(false);
    }
  } else if (mode === "homeAssistant") {
    const cache = host.settings.cachedHAHome;
    const matches = cache?.identity === homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken);
    host.devices = matches && cache ? structuredClone(cache.home.devices) : [];
    host.scenes = matches && cache ? structuredClone(cache.home.scenes) : [];
    host.environmentReadings = matches && cache ? structuredClone(cache.home.environmentReadings) : [];
    if (host.settings.haBaseURL && host.settings.haToken) {
      void host.refreshHADevices(false);
    }
  }
  host.saveSettings();
}

function applyAssistantDraftToHost(host: OnboardingRenderViewHost, session: OnboardingSessionState): boolean {
  const resolved = resolveAssistantDraftForSave(session.assistantDraft);
  if (!resolved) return false;
  host.settings.assistantBaseURL = resolved.baseURL;
  host.settings.assistantModel = resolved.model;
  host.settings.openRouterApiKey = resolved.apiKey;
  if (resolved.apiKey !== "") {
    host.assistantKeysByPreset[resolved.presetId] = resolved.apiKey;
  } else {
    delete host.assistantKeysByPreset[resolved.presetId];
  }
  const endpoint = resolved.apiKey ? assistantEndpointIdentity(resolved.baseURL) : null;
  if (resolved.presetId === "custom") {
    host.settings.assistantCustomKeyEndpoint = endpoint;
    host.settings.assistantKeyEndpoint = endpoint;
  } else {
    host.settings.assistantKeyEndpoint = endpoint;
  }
  return true;
}

export function mountOnboardingGuide(host: OnboardingRenderViewHost): void {
  if (host.activeSheet !== "onboarding") {
    clearOnboardingSession(host);
    return;
  }
  const sheet = host.root.querySelector<HTMLElement>(".cc-sheet:not(.cc-settings-sheet)");
  if (!sheet) return;

  const esc = (v: string) => (typeof host.escapeHtml === "function" ? host.escapeHtml(v) : escapeHtmlFallback(v));
  const session = ensureSession(host);
  const draft = session.assistantDraft;
  const activePreset = findPreset(draft.selectedPreset);
  const hasConnectedHome =
    Boolean(host.settings.miSession) ||
    Boolean(host.settings.haBaseURL.trim() && host.settings.haToken.trim());
  const hotkeyText = host.settings.globalHotkey || "Alt+M";
  const isPollingQR = Boolean(host.isPollingQR);
  const qrStatus = host.qrStatusText ?? "";
  const qrTicket = host.qrTicket ?? null;
  const supportsEnvImport = presetSupportsEnvKeyImport(draft.selectedPreset) && draft.apiKey.trim() === "";

  const renderSourceBody = (): string => {
    if (session.selectedMode === "xiaomiCloud") {
      return `
        <div class="cc-field" style="margin-top: 8px;">
          <label>${t("云端服务器地区")}</label>
          <select class="cc-input" data-mi-region>
            ${MI_CLOUD_REGIONS.map(
              (region) =>
                `<option value="${region.code}" ${
                  normalizeMiCloudRegion(host.settings.miCloudRegion) === region.code ? "selected" : ""
                }>${esc(t(region.label))}</option>`,
            ).join("")}
          </select>
          <p class="cc-field-hint">${t("欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。")}</p>
        </div>
        <div class="cc-qr-box">
          <button type="button" class="cc-btn-primary is-full" id="btn-start-qr" ${isPollingQR ? "disabled" : ""}>
            ${SF_ICONS.qrcode}
            <span>${
              isPollingQR
                ? t("正在等待手机米家扫码确认...")
                : host.settings.miSession
                  ? t("切换/重新扫码 (已登录 {user})", { user: maskedMiUserId(host.settings.miSession.userId) })
                  : t("获取米家登录二维码")
            }</span>
          </button>
          <div class="cc-qr-status">${esc(qrStatus)}</div>
          ${
            qrTicket
              ? `<div class="cc-qr-frame"><img src="${esc(qrTicket.qrImageURL)}" alt="Xiaomi QR" /></div>`
              : ""
          }
        </div>
      `;
    }
    if (session.selectedMode === "homeAssistant") {
      const warnPlainHttp = isPlainHttpRemoteURL(session.haURLDraft);
      return `
        <div class="cc-field" style="margin-top: 8px;">
          <label for="onboarding-ha-url">Home Assistant URL</label>
          <input
            id="onboarding-ha-url"
            class="cc-input"
            type="url"
            placeholder="http://homeassistant.local:8123"
            value="${esc(session.haURLDraft)}"
          />
          ${
            warnPlainHttp
              ? `<p class="cc-field-hint" data-onboarding-ha-http-warning style="color: #e67e22;">${esc(
                  tr3(
                    "令牌将以明文在网络上传输，远程访问建议使用 HTTPS 或 Nabu Casa 地址。",
                    "權杖將以明文在網路上傳輸，遠端存取建議使用 HTTPS 或 Nabu Casa 位址。",
                    "Your token will travel unencrypted. Prefer HTTPS or a Nabu Casa URL for remote access.",
                  ),
                )}</p>`
              : ""
          }
          <label for="onboarding-ha-token">Home Assistant access token</label>
          <div style="display: flex; gap: 6px; align-items: center;">
            <input
              id="onboarding-ha-token"
              class="cc-input"
              type="password"
              autocomplete="off"
              placeholder="${esc(tr3("粘贴 HA 长期访问令牌", "貼上 HA 長期存取權杖", "Paste HA Long-Lived Access Token"))}"
              value="${esc(session.haTokenDraft)}"
              style="flex: 1;"
            />
            <button type="button" class="cc-btn-primary" id="btn-onboarding-connect-ha">
              ${esc(tr3("连接", "連線", "Connect"))}
            </button>
          </div>
        </div>
      `;
    }
    return `
      <div class="cc-field" data-onboarding-demo-banner style="margin-top: 8px;">
        <p class="cc-field-hint" style="margin: 0;">
          ${esc(
            tr3(
              "演示模式已开启：内置虚拟全屋设备，完全离线、零网络请求。随时可切回「米家扫码直连」或「Home Assistant」。",
              "示範模式已開啟：內建虛擬全屋裝置，完全離線、零網路請求。隨時可切回「米家掃碼直連」或「Home Assistant」。",
              "Demo mode is active: built-in virtual home devices, completely offline with zero network requests. Switch to Xiaomi QR or Home Assistant anytime.",
            ),
          )}
        </p>
      </div>
    `;
  };

  sheet.innerHTML = `
    <div class="cc-sheet-header">
      <div class="cc-sheet-badge">${esc(tr3("三步上手 · MenuBarHome", "三步上手 · MenuBarHome", "Three Steps to Start · MenuBarHome"))}</div>
      <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="${t("关闭引导")}" aria-label="${t("关闭引导")}">
        ${SF_ICONS.xmark}
      </button>
    </div>

    <div class="cc-onboarding-scroll" style="overflow-y: auto; max-height: calc(100vh - 150px); padding-right: 2px;">
      <h2 class="cc-sheet-title">${esc(tr3("连接家庭 · 快捷键控全屋", "連接家庭 · 快速鍵控全屋", "Connect Your Home · Control Anywhere"))}</h2>
      <p class="cc-sheet-desc">
        ${esc(
          tr3(
            `选择数据源连接设备 · 按 ${hotkeyText} 秒开搜索与语音 · 一键全关后还能随时撤销。`,
            `選擇資料來源連接裝置 · 按 ${hotkeyText} 秒開搜尋與語音 · 一鍵全關後還能隨時復原。`,
            `Connect your home source · Press ${hotkeyText} to search or speak · Turn all off with one-click Undo.`,
          ),
        )}
      </p>

      <div class="cc-field" data-onboarding-step="1">
        <div class="cc-field-row" style="margin-bottom: 6px;">
          <label style="font-weight: 600;">1. ${esc(tr3("选择设备连接方式", "選擇裝置連接方式", "Choose How to Connect"))}</label>
          <span class="cc-field-hint" style="margin: 0;">${esc(
            hasConnectedHome
              ? tr3("已连接", "已連接", "Connected")
              : tr3("支持随时切换", "支援隨時切換", "Switch anytime"),
          )}</span>
        </div>
        <div class="cc-segmented-pills" role="tablist" aria-label="${esc(tr3("新手引导数据源", "新手引導資料來源", "Onboarding Data Source"))}">
          <button
            type="button"
            class="cc-seg-pill ${session.selectedMode === "xiaomiCloud" ? "is-active" : ""}"
            data-onboarding-mode="xiaomiCloud"
            aria-selected="${session.selectedMode === "xiaomiCloud"}"
          >${esc(tr3("米家扫码直连", "米家掃碼直連", "Xiaomi QR"))}</button>
          <button
            type="button"
            class="cc-seg-pill ${session.selectedMode === "homeAssistant" ? "is-active" : ""}"
            data-onboarding-mode="homeAssistant"
            aria-selected="${session.selectedMode === "homeAssistant"}"
          >Home Assistant</button>
          <button
            type="button"
            class="cc-seg-pill ${session.selectedMode === "demo" ? "is-active" : ""}"
            data-onboarding-mode="demo"
            aria-selected="${session.selectedMode === "demo"}"
          >${esc(tr3("先体验演示模式", "先體驗示範模式", "Try Demo Mode"))}</button>
        </div>
        ${renderSourceBody()}

        <div class="cc-field-row" style="margin-top: 10px;">
          <div>
            <label for="onboarding-launch-at-login">${t("开机自动启动")}</label>
            <p class="cc-field-hint" style="margin: 2px 0 0 0;">${esc(
              tr3(
                "常驻系统托盘，重启电脑后自动就绪。",
                "常駐系統匣，重新啟動電腦後自動就緒。",
                "Stay ready in the system tray automatically after restart.",
              ),
            )}</p>
          </div>
          <input id="onboarding-launch-at-login" type="checkbox" ${host.settings.launchAtLogin ? "checked" : ""} />
        </div>
      </div>

      <div class="cc-field" data-onboarding-step="2">
        <label style="font-weight: 600;">2. ${esc(tr3("AI 助手服务商预设（可选）", "AI 助手服務商預設（選填）", "AI Assistant Provider (Optional)"))}</label>
        <p class="cc-field-hint" style="margin-bottom: 6px;">${esc(
          tr3(
            "日常开关调温本机 0ms 直达；需要跨房间复杂口语指令时再配置 AI 服务。",
            "日常開關調溫本機 0ms 直達；需要跨房間複雜口語指令時再設定 AI 服務。",
            "Everyday commands run locally in 0ms; add an AI provider for complex multi-room phrasing.",
          ),
        )}</p>
        <div class="cc-segmented-pills" style="flex-wrap: wrap; gap: 4px; margin-bottom: 8px;">
          ${ASSISTANT_PROVIDER_PRESETS.map((preset) => {
            const isSelected = draft.selectedPreset === preset.id;
            const label =
              preset.id === "custom"
                ? tr3("自定义", "自訂", "Custom")
                : preset.shortTitle;
            return `<button
              type="button"
              class="cc-seg-pill ${isSelected ? "is-active" : ""}"
              data-onboarding-ai-preset="${esc(preset.id)}"
              aria-pressed="${isSelected}"
            >${esc(label)}</button>`;
          }).join("")}
        </div>

        ${
          draft.showsCustomEndpointFields
            ? `<div id="onboarding-custom-endpoint-fields" style="display: flex; flex-direction: column; gap: 6px; margin-bottom: 8px;">
                <input
                  id="onboarding-base-url"
                  class="cc-input"
                  type="text"
                  placeholder="${esc(tr3("输入自定义接口地址，如 https://api.example.com/v1", "輸入自訂介面位址，如 https://api.example.com/v1", "Custom endpoint URL, e.g. https://api.example.com/v1"))}"
                  aria-label="${esc(tr3("AI 服务地址", "AI 服務位址", "AI Endpoint URL"))}"
                  value="${esc(draft.baseURL)}"
                />
                <input
                  id="onboarding-model"
                  class="cc-input"
                  type="text"
                  placeholder="gpt-4o-mini"
                  aria-label="${esc(tr3("决策模型", "決策模型", "Decision Model"))}"
                  value="${esc(draft.model)}"
                />
              </div>`
            : ""
        }

        <div style="display: flex; gap: 6px; align-items: center;">
          <input
            id="onboarding-api-key"
            class="cc-input"
            type="password"
            autocomplete="off"
            placeholder="${esc(activePreset.keyPlaceholder)}"
            value="${esc(draft.apiKey)}"
            style="flex: 1;"
          />
          <button type="button" class="cc-btn-secondary" id="btn-onboarding-save-ai">
            ${esc(tr3("保存 AI", "儲存 AI", "Save AI"))}
          </button>
        </div>

        ${
          supportsEnvImport
            ? `<div style="margin-top: 6px;">
                <button type="button" class="cc-inline-pill" id="btn-onboarding-import-env">
                  ${esc(tr3("从环境变量导入 Key", "從環境變數匯入 Key", "Import Key from Env"))}
                </button>
              </div>`
            : ""
        }

        ${
          session.statusNote
            ? `<p class="cc-field-hint" id="onboarding-status-note" style="margin-top: 6px; color: ${
                session.statusNote.isError ? "#e67e22" : "inherit"
              };">${esc(session.statusNote.text)}</p>`
            : ""
        }
      </div>

      <div class="cc-field" data-onboarding-step="3">
        <label style="font-weight: 600;">3. ${esc(tr3("快捷搜索与安全全关", "快速搜尋與安全全關", "Quick Search & Safe All Off"))}</label>
        <p class="cc-field-hint" style="margin: 2px 0;">
          • ${esc(
            tr3(
              `按 ${hotkeyText} 呼出面板，直接打字或输入拼音首字母筛选设备，回车立即开关。`,
              `按 ${hotkeyText} 呼出面板，直接打字或輸入拼音首字母篩選裝置，按 Enter 立即開關。`,
              `Press ${hotkeyText} to open the panel, type device names or pinyin initials, and press Enter to toggle.`,
            ),
          )}
        </p>
        <p class="cc-field-hint" style="margin: 2px 0;">
          • ${esc(
            tr3(
              "顶部「全关」默认跳过插座与扫地机，执行后底部弹出一次性「撤销」横幅；随时可在设置里重新打开本引导。",
              "頂部「全關」預設略過插座與掃地機，執行後底部彈出一次性「復原」橫幅；隨時可在設定裡重新打開本引導。",
              "Top All Off skips plugs and vacuums by default and offers one-shot Undo; reopen this guide anytime in Settings.",
            ),
          )}
        </p>
      </div>
    </div>

    <div class="cc-sheet-footer">
      <button type="button" class="cc-btn-secondary" id="btn-close-onboarding-alt">${t("先看演示预览")}</button>
      <button type="button" class="cc-btn-primary" id="btn-finish-onboarding">${t("进入控制中心")}</button>
    </div>
  `;

  sheet.querySelectorAll<HTMLElement>("[data-onboarding-mode]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const mode = btn.dataset.onboardingMode as ConnectionMode | undefined;
      if (!mode) return;
      session.selectedMode = mode;
      session.statusNote = null;
      switchConnectionModeInOnboarding(host, mode);
      host.render();
    });
  });

  sheet.querySelectorAll<HTMLSelectElement>("[data-mi-region]").forEach((select) => {
    select.addEventListener("change", () => {
      host.settings.miCloudRegion = normalizeMiCloudRegion(select.value);
      host.saveSettings();
      host.render();
    });
  });

  sheet.querySelector("#btn-start-qr")?.addEventListener("click", () => {
    void host.startXiaomiQRLogin();
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-ha-url")?.addEventListener("input", (event) => {
    session.haURLDraft = (event.target as HTMLInputElement).value;
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-ha-token")?.addEventListener("input", (event) => {
    session.haTokenDraft = (event.target as HTMLInputElement).value;
  });

  sheet.querySelector("#btn-onboarding-connect-ha")?.addEventListener("click", () => {
    let endpoint = session.haURLDraft.trim();
    if (endpoint && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(endpoint)) {
      endpoint = `http://${endpoint}`;
    }
    endpoint = endpoint.replace(/\/api\/websocket\/?$/i, "").replace(/\/+$/, "");
    const token = session.haTokenDraft.trim();
    if (!endpoint || !token) {
      session.statusNote = {
        text: tr3(
          "请填写完整的 Home Assistant 地址与长期访问令牌",
          "請填寫完整的 Home Assistant 位址與長期存取權杖",
          "Please enter both the Home Assistant URL and Long-Lived Access Token",
        ),
        isError: true,
      };
      host.render();
      return;
    }
    session.haURLDraft = endpoint;
    host.invalidateSourceControl();
    host.settings.cachedHAHome = null;
    host.localControlRevision += 1;
    host.settings.haBaseURL = endpoint;
    host.settings.haToken = token;
    host.settings.connectionMode = "homeAssistant";
    session.selectedMode = "homeAssistant";
    session.statusNote = {
      text: tr3("已保存 Home Assistant 连接配置，正在同步…", "已儲存 Home Assistant 連線設定，正在同步…", "Home Assistant saved; syncing devices…"),
      isError: false,
    };
    host.saveSettings(true);
    void host.refreshHADevices(false);
    host.render();
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-launch-at-login")?.addEventListener("change", (event) => {
    const enabled = (event.target as HTMLInputElement).checked;
    host.settings.launchAtLogin = enabled;
    host.saveSettings();
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) {
      host.render();
      return;
    }
    void invoke("set_launch_at_login", { enabled })
      .then(() => {
        host.render();
      })
      .catch(() => {
        host.settings.launchAtLogin = !enabled;
        host.saveSettings();
        host.replyBanner = {
          text: t("无法修改开机自启设置，请检查系统权限后重试"),
          source: t("控制失败"),
          isError: true,
        };
        host.render();
      });
  });

  sheet.querySelectorAll<HTMLElement>("[data-onboarding-ai-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const presetId = btn.dataset.onboardingAiPreset as AssistantProviderPresetId | undefined;
      if (!presetId) return;
      session.assistantDraft = selectAssistantPresetDraft(
        presetId,
        session.assistantDraft,
        (url) => storedKeyForHost(host, url),
      );
      session.statusNote = null;
      host.render();
    });
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-base-url")?.addEventListener("input", (event) => {
    const nextURL = (event.target as HTMLInputElement).value;
    session.assistantDraft = updateAssistantBaseURLDraft(
      nextURL,
      session.assistantDraft,
      (url) => storedKeyForHost(host, url),
    );
    // Update active pill, model input, and key input in place without re-rendering so focus/caret stay intact!
    const updated = session.assistantDraft;
    const preset = findPreset(updated.selectedPreset);
    sheet.querySelectorAll<HTMLElement>("[data-onboarding-ai-preset]").forEach((pill) => {
      const active = pill.dataset.onboardingAiPreset === updated.selectedPreset;
      pill.classList.toggle("is-active", active);
      pill.setAttribute("aria-pressed", String(active));
    });
    const modelEl = sheet.querySelector<HTMLInputElement>("#onboarding-model");
    if (modelEl && modelEl.value !== updated.model) {
      modelEl.value = updated.model;
    }
    const keyEl = sheet.querySelector<HTMLInputElement>("#onboarding-api-key");
    if (keyEl) {
      keyEl.placeholder = preset.keyPlaceholder;
      if (keyEl.value !== updated.apiKey) {
        keyEl.value = updated.apiKey;
      }
    }
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-model")?.addEventListener("input", (event) => {
    session.assistantDraft = {
      ...session.assistantDraft,
      model: (event.target as HTMLInputElement).value,
    };
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-api-key")?.addEventListener("input", (event) => {
    session.assistantDraft = {
      ...session.assistantDraft,
      apiKey: (event.target as HTMLInputElement).value,
    };
  });

  sheet.querySelector("#btn-onboarding-save-ai")?.addEventListener("click", () => {
    if (!applyAssistantDraftToHost(host, session)) {
      session.statusNote = {
        text: tr3(
          "请先填写自定义 AI 服务地址，已保存的其他服务商密钥未受影响",
          "請先填寫自訂 AI 服務位址，已儲存的其他服務商金鑰未受影響",
          "Enter a custom AI endpoint URL first; previously saved provider keys remain untouched",
        ),
        isError: true,
      };
      host.render();
      return;
    }
    host.saveSettings(true);
    session.statusNote = {
      text: tr3("已保存 AI 助手配置", "已儲存 AI 助手設定", "AI assistant configuration saved"),
      isError: false,
    };
    host.render();
  });

  sheet.querySelector("#btn-onboarding-import-env")?.addEventListener("click", () => {
    void (async () => {
      const hit = await importAmbientAssistantKey(session.assistantDraft.selectedPreset);
      if (hit) {
        session.assistantDraft = {
          ...session.assistantDraft,
          apiKey: hit.apiKey,
        };
        session.statusNote = {
          text: tr3(
            `已从环境变量 ${hit.envName} 导入密钥`,
            `已從環境變數 ${hit.envName} 匯入金鑰`,
            `Imported API key from ${hit.envName}`,
          ),
          isError: false,
        };
      } else {
        session.statusNote = {
          text: tr3(
            "未在环境变量中检测到对应服务商的 API Key",
            "未在環境變數中偵測到對應服務商的 API Key",
            "No matching API key found in environment variables",
          ),
          isError: true,
        };
      }
      host.render();
    })();
  });

  const completeAndClose = (forceDemo: boolean) => {
    const keyInput = sheet.querySelector<HTMLInputElement>("#onboarding-api-key");
    if (keyInput) {
      session.assistantDraft = {
        ...session.assistantDraft,
        apiKey: keyInput.value,
      };
    }
    const baseInput = sheet.querySelector<HTMLInputElement>("#onboarding-base-url");
    if (baseInput) {
      session.assistantDraft = {
        ...session.assistantDraft,
        baseURL: baseInput.value,
      };
    }
    const modelInput = sheet.querySelector<HTMLInputElement>("#onboarding-model");
    if (modelInput) {
      session.assistantDraft = {
        ...session.assistantDraft,
        model: modelInput.value,
      };
    }

    const currentInferred = inferAssistantPreset(host.settings.assistantBaseURL).id;
    const hasAssistantChanges =
      session.assistantDraft.apiKey.trim() !== "" ||
      session.assistantDraft.selectedPreset !== currentInferred ||
      session.assistantDraft.baseURL.trim() !== host.settings.assistantBaseURL.trim() ||
      (session.assistantDraft.model.trim() !== "" &&
        session.assistantDraft.model.trim() !== host.settings.assistantModel.trim());

    if (hasAssistantChanges) {
      applyAssistantDraftToHost(host, session);
    }

    if (forceDemo) {
      switchConnectionModeInOnboarding(host, "demo");
    }

    host.settings.hasCompletedOnboarding = true;
    host.saveSettings(true);
    clearOnboardingSession(host);
    host.activeSheet = "none";
    invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
    host.render();
  };

  sheet.querySelector("#btn-close-onboarding")?.addEventListener("click", () => completeAndClose(false));
  sheet.querySelector("#btn-finish-onboarding")?.addEventListener("click", () => completeAndClose(false));
  sheet.querySelector("#btn-close-onboarding-alt")?.addEventListener("click", () => completeAndClose(true));
}
