import { currentLanguage, t, type AppLanguage } from "../core/i18n.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  forgetHabitItem,
  inferAssistantPreset,
  isLocalNetworkEndpoint,
  listReadableHabits,
  parseAssistantEndpoint,
  shareHabitSentence,
  type AssistantConfig,
  type HabitLastAction,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion, type HttpTransport } from "../core/miCloudClient.js";
import {
  joinsAllOffByDefault,
  type AssistantSuggestion,
  type EnvironmentReading,
  type FacetControl,
  type HomeScene,
  type SmartDevice,
} from "../core/models.js";
import {
  assistantApiKeyCredentialName,
  credentialsFromSettings,
  secureStoreDelete,
} from "../core/secureStore.js";
import {
  clearCachedXiaomiTopology,
  clearPersistedMiSessionExpired,
  clearXiaomiRateLimitBackoff,
} from "../core/pollingPolicy.js";
import { withAliases, type HomeOption, type LayoutPrefs } from "./panelPrefs.js";
import type { ConnectionMode, PendingHighRiskConfirmation, PersistedSettings, ReplyBannerState } from "./appTypes.js";
import { demoDevices, demoScenes } from "./demo.js";
import { submitServiceEndpoints } from "./appLifecycle.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import {
  importAmbientAssistantKey,
  mountOnboardingGuide,
  presetSupportsEnvKeyImport,
  type OnboardingRenderViewHost,
} from "./onboardingGuide.js";
import { writeAskWhenUnsure, writeSettingsForStorage } from "./settings.js";
import {
  SettingsSearchSelection,
  clearSettingsHighlight,
  highlightSettingsAnchor,
  resolveSettingsAnchorTab,
  searchSettings,
  type SettingsAnchor,
} from "./settingsSearch.js";
import { setPendingMiVaultDeletion, setRaycastIntegrationEnabled } from "./speechGuard.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import type { SettingsTab } from "./settingsViews.js";
import type { GitHubRelease } from "../core/updateChecker.js";

function tr3(zhHans: string, zhHant: string, en: string, lang: AppLanguage = currentLanguage()): string {
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

export interface SettingsEventsHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  readonly cameraLive: {
    readonly activeLiveCameraId: string | null;
    readonly liveCameraKeepAliveTimer: number | null;
    closeCameraLiveView(): void;
  };
  assistantKeysByPreset: Record<string, string>;
  devices: SmartDevice[];
  scenes: HomeScene[];
  environmentReadings: EnvironmentReading[];
  homes: HomeOption[];
  readonly layout: LayoutPrefs;
  activeSheet: "none" | "onboarding" | "settings";
  settingsTab: SettingsTab;
  availableUpdate: GitHubRelease | null;
  aiProactiveSignature: string | null;
  aiProactiveSuggestions: AssistantSuggestion[] | null;
  cloudValuesStale: boolean;
  /** 更多设置 rows from the latest snapshot; a backend switch drops them (#5). */
  deviceFacets: Readonly<Record<string, readonly FacetControl[]>>;
  /** A high-risk write armed by its first tap; a backend switch disarms it. */
  pendingHighRisk: PendingHighRiskConfirmation | null;
  clearPendingHighRisk(): void;
  groupOwnerByMemberDid: Map<string, string>;
  hotkeyNeedsHint: boolean;
  isRecordingHotkey: boolean;
  localControlRevision: number;
  pendingCloudConsent: { utterance: string; endpoint: string } | null;
  replyBanner: ReplyBannerState | null;
  selectRoom(roomId: string | null, roomName?: string): void;
  habitSequences(): readonly HabitSequenceEntry[];
  lastHabitAction(): HabitLastAction | null;
  checkForAppUpdate(manual: boolean): Promise<void>;
  handleNaturalCommand(raw: string, fromScheduled?: boolean): Promise<void>;
  invalidateSourceControl(): void;
  openSettingsSheet(tab?: SettingsTab): void;
  openUpdatePage(): void;
  refreshDevices(silent?: boolean): Promise<void>;
  refreshHADevices(silent?: boolean): Promise<void>;
  render(): void;
  saveSettings(force?: boolean): void;
  shouldKeepPopoverPinned(): boolean;
  signOutXiaomiAccount(): void;
  startUpdateInstall(): Promise<void>;
  startXiaomiQRLogin(): Promise<void>;
  syncKeyFieldWithEndpoint(apiKeyEl: HTMLInputElement, baseURL: string): void;
  apiKeyFor?(baseURL: string): string;
  escapeHtml?(value: string): string;
}

interface SettingsUiSessionState {
  launchAtLoginSynced: boolean;
  habitItemsExpanded: boolean;
  searchQuery: string;
  searchSelectedIndex: number | null;
  aiTestStatus: { text: string; state: "idle" | "testing" | "ok" | "error" } | null;
  envImportStatus: { text: string; isError: boolean } | null;
}

const settingsSessionByHost = new WeakMap<object, SettingsUiSessionState>();

function getSettingsSession(host: object): SettingsUiSessionState {
  let state = settingsSessionByHost.get(host);
  if (!state) {
    state = {
      launchAtLoginSynced: false,
      habitItemsExpanded: false,
      searchQuery: "",
      searchSelectedIndex: null,
      aiTestStatus: null,
      envImportStatus: null,
    };
    settingsSessionByHost.set(host, state);
  }
  return state;
}

function escapeHtmlFallback(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeForHost(host: SettingsEventsHost, raw: string): string {
  return typeof host.escapeHtml === "function" ? host.escapeHtml(raw) : escapeHtmlFallback(raw);
}

function storedKeyForURL(host: SettingsEventsHost, baseURL: string): string {
  if (typeof host.apiKeyFor === "function") {
    return host.apiKeyFor(baseURL);
  }
  const preset = inferAssistantPreset(baseURL);
  if (preset.id !== "custom") {
    return host.assistantKeysByPreset[preset.id] ?? "";
  }
  const endpoint = assistantEndpointIdentity(baseURL);
  if (endpoint && host.settings.assistantCustomKeyEndpoint === endpoint) {
    return host.assistantKeysByPreset["custom"] ?? "";
  }
  return "";
}

export async function syncLaunchAtLoginFromSystem(host: SettingsEventsHost): Promise<boolean> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return host.settings.launchAtLogin;
  try {
    const actual = await invoke<unknown>("get_launch_at_login");
    if (typeof actual === "boolean" && actual !== host.settings.launchAtLogin) {
      host.settings.launchAtLogin = actual;
      host.saveSettings();
      const box = host.root.querySelector<HTMLInputElement>("#settings-launch-at-login");
      if (box) {
        box.checked = actual;
        box.defaultChecked = actual;
      }
    }
    return host.settings.launchAtLogin;
  } catch {
    return host.settings.launchAtLogin;
  }
}

export function hasUnsavedSettingsChanges(host: SettingsEventsHost): boolean {
  const root = host.root;
  if (!root.querySelector(".cc-settings-sheet")) return false;

  const normalizeHaUrl = (raw: string): string => {
    let endpoint = raw.trim();
    if (endpoint && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(endpoint)) {
      endpoint = `http://${endpoint}`;
    }
    return endpoint.replace(/\/api\/websocket\/?$/i, "").replace(/\/+$/, "");
  };

  const haUrl = root.querySelector<HTMLInputElement>("#settings-ha-url");
  if (haUrl && normalizeHaUrl(haUrl.value) !== normalizeHaUrl(host.settings.haBaseURL)) {
    return true;
  }

  const haToken = root.querySelector<HTMLInputElement>("#settings-ha-token");
  if (haToken && haToken.value.trim() !== host.settings.haToken.trim()) {
    return true;
  }

  const baseEl = root.querySelector<HTMLInputElement>("#settings-base-url");
  if (baseEl && baseEl.value.trim() !== host.settings.assistantBaseURL.trim()) {
    return true;
  }

  const modelEl = root.querySelector<HTMLInputElement>("#settings-model");
  if (modelEl && modelEl.value.trim() !== host.settings.assistantModel.trim()) {
    return true;
  }

  const apiKeyEl = root.querySelector<HTMLInputElement>("#settings-api-key");
  if (apiKeyEl) {
    const activeBase = baseEl ? baseEl.value : host.settings.assistantBaseURL;
    const savedKey = storedKeyForURL(host, activeBase);
    if (apiKeyEl.value.trim() !== savedKey.trim()) {
      return true;
    }
  }

  const habitEl = root.querySelector<HTMLInputElement>("#settings-habit");
  if (habitEl && habitEl.checked !== host.settings.habitLearningEnabled) {
    return true;
  }

  const habitShareEl = root.querySelector<HTMLInputElement>("#settings-habit-share");
  if (habitShareEl && habitShareEl.checked !== host.settings.habitShareEnabled) {
    return true;
  }

  return false;
}

export async function probeAssistantConnection(
  config: AssistantConfig & { readonly haUrl?: string },
  transport?: HttpTransport,
): Promise<{ readonly ok: boolean; readonly latencyMs: number | null; readonly message: string }> {
  const trimmedBase = config.baseURL.trim();
  if (!trimmedBase) {
    return {
      ok: false,
      latencyMs: null,
      message: tr3(
        "请先填写 AI 服务地址",
        "請先填寫 AI 服務位址",
        "Please enter an AI endpoint URL first",
      ),
    };
  }
  const parsed = parseAssistantEndpoint(trimmedBase);
  if (!parsed) {
    return {
      ok: false,
      latencyMs: null,
      message: tr3(
        "AI 服务地址格式无效，请检查 URL",
        "AI 服務位址格式無效，請檢查 URL",
        "Invalid AI endpoint URL format",
      ),
    };
  }
  if (!endpointAllowsSendingSecrets(trimmedBase)) {
    return {
      ok: false,
      latencyMs: null,
      message: tr3(
        "非本机地址必须使用 HTTPS，已拦截明文请求",
        "非本機位址必須使用 HTTPS，已攔截明文請求",
        "Remote AI endpoints must use HTTPS; unencrypted request blocked",
      ),
    };
  }
  if (!isLocalNetworkEndpoint(parsed) && config.apiKey.trim() === "") {
    return {
      ok: false,
      latencyMs: null,
      message: tr3(
        "请先填写 API Key 后再测试连接",
        "請先填寫 API Key 後再測試連線",
        "Please enter an API Key before testing the connection",
      ),
    };
  }

  const probeDevice: SmartDevice = {
    id: "probe_study_light",
    name: "书房灯",
    roomId: "shu_fang",
    roomName: "书房",
    model: "yeelink.light.ceiling20",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "light.probe_study",
      isOn: false,
      brightnessPercent: 100,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: ["Day", "Night"],
    },
  };

  const preset = inferAssistantPreset(trimmedBase);
  const model = config.model.trim() || preset.defaultModel || "gpt-4o-mini";
  const effectiveTransport = transport ?? createTransport();
  const resolver = new ModelIntentResolver(
    {
      baseURL: trimmedBase,
      model,
      apiKey: config.apiKey.trim(),
    },
    effectiveTransport,
  );

  const start = performance.now();
  try {
    const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
    if (!transport && invoke) {
      await invoke("set_service_endpoints", {
        assistantUrl: trimmedBase,
        haUrl: (config.haUrl ?? "").trim(),
      });
    }
    await resolver.resolve("打开书房灯", [probeDevice], []);
    const latencyMs = Math.max(1, Math.round(performance.now() - start));
    const label = preset.id === "custom" ? tr3("自定义", "自訂", "Custom") : preset.shortTitle;
    return {
      ok: true,
      latencyMs,
      message: tr3(
        `连接成功（${label} · ${latencyMs} ms）`,
        `連線成功（${label} · ${latencyMs} ms）`,
        `Connected (${label} · ${latencyMs} ms)`,
      ),
    };
  } catch (err: unknown) {
    const reason = err instanceof Error && err.message.trim() ? err.message.trim() : String(err);
    return {
      ok: false,
      latencyMs: null,
      message: reason,
    };
  }
}

function clearRevokedCredentialInputs(root: HTMLElement): void {
  for (const selector of ["#settings-ha-url", "#settings-ha-token", "#settings-api-key"]) {
    const field = root.querySelector<HTMLInputElement>(selector);
    if (field) {
      field.value = "";
      field.defaultValue = "";
    }
  }
}

export async function signOutAndRevokeAll(host: SettingsEventsHost): Promise<void> {
  setPendingMiVaultDeletion(true);
  if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
    host.cameraLive.closeCameraLiveView();
  }
  host.localControlRevision += 1;
  host.invalidateSourceControl();
  host.clearPendingHighRisk();
  host.pendingCloudConsent = null;

  host.settings.miSession = null;
  host.settings.cachedXiaomiDevices = [];
  host.settings.selectedHomeId = null;
  (host as { miSessionExpired?: boolean }).miSessionExpired = false;
  clearPersistedMiSessionExpired();
  clearCachedXiaomiTopology(host);
  clearXiaomiRateLimitBackoff(host);
  host.cloudValuesStale = false;
  (host as { expandedDeviceId?: string | null }).expandedDeviceId = null;
  (host as { waitingDeviceIds?: Set<string> }).waitingDeviceIds?.clear();
  (host as { unresolvedRoomDids?: Set<string> }).unresolvedRoomDids?.clear();
  (host as { qrTicket?: unknown }).qrTicket = null;
  (host as { qrStatusText?: string }).qrStatusText = t(
    "点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。",
  );

  host.settings.haBaseURL = "";
  host.settings.haToken = "";
  host.settings.cachedHAHome = null;

  host.settings.openRouterApiKey = "";
  host.settings.assistantKeyEndpoint = null;
  host.settings.assistantCustomKeyEndpoint = null;
  host.settings.assistantLegacyKeyEndpoint = null;
  host.assistantKeysByPreset = {};
  host.settings.cloudConsentEndpoints = [];

  const session = getSettingsSession(host);
  session.aiTestStatus = null;
  session.envImportStatus = null;

  host.settings.connectionMode = "demo";
  host.devices = demoDevices();
  host.scenes = demoScenes();
  host.environmentReadings = [];
  host.homes = [];
  host.groupOwnerByMemberDid = new Map();
  host.deviceFacets = {};
  host.selectRoom(null);

  const appHost = host as unknown as MenuMijiaWindowsApp;
  const vault = (host as unknown as Partial<MenuMijiaWindowsApp>).credentialVault;

  setRaycastIntegrationEnabled(appHost, false, { persistSettings: false, render: false });

  const successBanner: ReplyBannerState = {
    text: tr3(
      "已退出所有账号并清除全部密钥与本地桥接令牌",
      "已登出所有帳號並清除全部金鑰與本機橋接權杖",
      "Signed out of all accounts and revoked all API keys and local bridge tokens",
    ),
    source: tr3("安全清理", "安全清理", "Security"),
  };
  host.replyBanner = successBanner;

  writeSettingsForStorage(host.settings);
  if (typeof (host as unknown as Partial<MenuMijiaWindowsApp>).noteServiceEndpointFailure === "function") {
    submitServiceEndpoints(appHost, true);
  } else if (!vault) {
    host.saveSettings(true);
  }
  clearRevokedCredentialInputs(host.root);
  host.render();

  try {
    if (vault) {
      await vault.persist(credentialsFromSettings(host.settings, host.assistantKeysByPreset));
      await vault.deleteMiSession();
    }
    const slotNames = [
      "mi_session" as const,
      "ha_token" as const,
      "assistant_api_key" as const,
      ...ASSISTANT_PROVIDER_PRESETS.map((preset) => assistantApiKeyCredentialName(preset.id)),
    ];
    const results = await Promise.allSettled(slotNames.map((slot) => secureStoreDelete(slot)));
    const failure = results.find(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    if (failure) throw failure.reason;

    setPendingMiVaultDeletion(false);
    host.replyBanner = successBanner;
    clearRevokedCredentialInputs(host.root);
    host.render();
  } catch (error: unknown) {
    const detail = error instanceof Error && error.message.trim() ? ` (${error.message.trim()})` : "";
    host.replyBanner = {
      text: `${tr3(
        "无法从系统凭据库完全清除密钥，请检查系统凭据设置后重试",
        "無法從系統憑據庫完全清除金鑰，請檢查系統憑據設定後重試",
        "Could not remove all credentials from the OS credential vault; please retry",
      )}${detail}`,
      source: t("出错提示"),
      isError: true,
    };
    clearRevokedCredentialInputs(host.root);
    host.render();
  }
}

function closeSettingsSheetImmediate(host: SettingsEventsHost): void {
  clearSettingsHighlight(host.root);
  host.activeSheet = "none";
  host.isRecordingHotkey = false;
  host.hotkeyNeedsHint = false;
  invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
  host.render();
}

function commitSettingsSave(host: SettingsEventsHost): void {
  const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
  const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
  const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
  const habitEl = host.root.querySelector<HTMLInputElement>("#settings-habit");
  const askUnsureEl = host.root.querySelector<HTMLInputElement>("#settings-ask-when-unsure");
  const haUrl = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
  const haToken = host.root.querySelector<HTMLInputElement>("#settings-ha-token");

  if (haUrl) {
    let endpoint = haUrl.value.trim();
    if (endpoint && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(endpoint)) {
      endpoint = `http://${endpoint}`;
    }
    endpoint = endpoint.replace(/\/api\/websocket\/?$/i, "").replace(/\/+$/, "");
    if (endpoint !== host.settings.haBaseURL) {
      host.invalidateSourceControl();
      host.settings.cachedHAHome = null;
      host.localControlRevision += 1;
      if (host.settings.connectionMode === "homeAssistant") {
        host.devices = [];
        host.scenes = [];
        host.environmentReadings = [];
        host.deviceFacets = {};
      }
    }
    host.settings.haBaseURL = endpoint;
  }

  if (haToken) {
    const token = haToken.value.trim();
    if (token !== host.settings.haToken) {
      host.invalidateSourceControl();
      host.settings.cachedHAHome = null;
      host.localControlRevision += 1;
      if (host.settings.connectionMode === "homeAssistant") {
        host.devices = [];
        host.scenes = [];
        host.environmentReadings = [];
        host.deviceFacets = {};
      }
    }
    host.settings.haToken = token;
  }

  const isCustomPillActive = Boolean(
    host.root.querySelector<HTMLElement>('[data-ai-preset="custom"].is-active'),
  );
  const rawBaseTrimmed = baseEl ? baseEl.value.trim() : host.settings.assistantBaseURL.trim();
  const skipBlankCustomSave = isCustomPillActive && rawBaseTrimmed === "";

  if (!skipBlankCustomSave) {
    if (baseEl) {
      host.settings.assistantBaseURL = rawBaseTrimmed || "https://openrouter.ai/api/v1";
    }
    const inferredPreset = inferAssistantPreset(host.settings.assistantBaseURL);
    if (apiKeyEl) {
      const trimmedKey = apiKeyEl.value.trim();
      host.settings.openRouterApiKey = trimmedKey;
      if (trimmedKey !== "") {
        host.assistantKeysByPreset[inferredPreset.id] = trimmedKey;
      } else {
        delete host.assistantKeysByPreset[inferredPreset.id];
      }
    }
    if (inferredPreset.id === "custom") {
      const customEndpoint = host.settings.openRouterApiKey
        ? assistantEndpointIdentity(host.settings.assistantBaseURL)
        : null;
      host.settings.assistantCustomKeyEndpoint = customEndpoint;
      host.settings.assistantKeyEndpoint = customEndpoint;
    } else {
      host.settings.assistantKeyEndpoint = host.settings.openRouterApiKey
        ? assistantEndpointIdentity(host.settings.assistantBaseURL)
        : null;
    }
    const fallbackModel = inferredPreset.defaultModel || "gpt-4o-mini";
    if (modelEl) {
      host.settings.assistantModel = modelEl.value.trim() || fallbackModel;
    }
  }

  if (askUnsureEl) {
    writeAskWhenUnsure(host.settings, askUnsureEl.checked);
  }
  if (habitEl) {
    host.settings.habitLearningEnabled = habitEl.checked;
  }
  const habitShareEl = host.root.querySelector<HTMLInputElement>("#settings-habit-share");
  if (habitShareEl) {
    host.settings.habitShareEnabled = habitShareEl.checked;
  }

  host.saveSettings(true);
  if (host.settings.connectionMode === "homeAssistant") {
    void host.refreshHADevices();
  }
  closeSettingsSheetImmediate(host);
}

export function bindSettingsEvents(host: SettingsEventsHost): void {
  mountOnboardingGuide(host as OnboardingRenderViewHost);

  const session = getSettingsSession(host);
  if (host.activeSheet !== "settings") {
    session.launchAtLoginSynced = false;
    session.habitItemsExpanded = false;
    session.searchQuery = "";
    session.searchSelectedIndex = null;
    session.aiTestStatus = null;
    session.envImportStatus = null;
    clearSettingsHighlight(host.root);
  } else if (!session.launchAtLoginSynced) {
    session.launchAtLoginSynced = true;
    void syncLaunchAtLoginFromSystem(host);
  }

  host.root.querySelector("#btn-cloud-allow")?.addEventListener("click", () => {
    const pending = host.pendingCloudConsent;
    if (!pending) return;
    host.pendingCloudConsent = null;
    if (!host.settings.cloudConsentEndpoints.includes(pending.endpoint)) {
      host.settings.cloudConsentEndpoints.push(pending.endpoint);
      host.saveSettings(true);
    }
    void host.handleNaturalCommand(pending.utterance);
  });

  host.root.querySelector("#btn-cloud-decline")?.addEventListener("click", () => {
    host.pendingCloudConsent = null;
    host.replyBanner = { text: t("没有发送。「打开书房灯」这类简单指令不用联网。"), source: t("已取消") };
    host.render();
  });

  if (host.activeSheet === "onboarding") {
    return;
  }

  host.root.querySelectorAll<HTMLInputElement>("[data-alloff-device]").forEach((box) => {
    box.addEventListener("change", () => {
      const id = box.dataset.alloffDevice ?? "";
      const device = host.devices.find((d) => d.id === id);
      if (!device) return;
      if (box.checked === joinsAllOffByDefault(device)) {
        delete host.settings.allOffOverrides[id];
      } else {
        host.settings.allOffOverrides[id] = box.checked;
      }
      host.saveSettings();
      host.render();
    });
  });

  host.root.querySelector("#btn-revoke-cloud")?.addEventListener("click", () => {
    host.settings.cloudConsentEndpoints = [];
    host.saveSettings();
    host.render();
  });

  host.root.querySelectorAll<HTMLSelectElement>("[data-mi-region]").forEach((select) => {
    select.addEventListener("change", () => {
      host.settings.miCloudRegion = normalizeMiCloudRegion(select.value);
      host.saveSettings();
      host.render();
    });
  });

  host.root.querySelector<HTMLInputElement>("#settings-auto-update")?.addEventListener("change", (event) => {
    host.settings.autoCheckUpdates = (event.target as HTMLInputElement).checked;
    host.saveSettings();
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-launch-at-login")?.addEventListener("change", (event) => {
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

  host.root.querySelector<HTMLInputElement>("#settings-block-while-locked")?.addEventListener("change", (event) => {
    host.settings.blockControlWhileLocked = (event.target as HTMLInputElement).checked;
    host.saveSettings();
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-raycast-integration")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    setRaycastIntegrationEnabled(host as unknown as MenuMijiaWindowsApp, checked);
  });

  host.root.querySelector<HTMLInputElement>("#settings-allow-direct-url")?.addEventListener("change", (event) => {
    host.settings.allowDirectURLControl = (event.target as HTMLInputElement).checked;
    host.saveSettings();
    host.render();
  });

  const advBox = host.root.querySelector<HTMLInputElement>("#settings-allow-advanced-facets");
  if (advBox) {
    advBox.checked = host.settings.allowAdvancedFacetWrites;
    advBox.addEventListener("change", () => {
      const confirmEl = host.root.querySelector<HTMLElement>("#settings-advanced-facets-confirm");
      if (advBox.checked && !host.settings.allowAdvancedFacetWrites) {
        advBox.checked = false;
        if (confirmEl) confirmEl.hidden = false;
        return;
      }
      if (!advBox.checked && host.settings.allowAdvancedFacetWrites) {
        if (confirmEl) confirmEl.hidden = true;
        host.settings.allowAdvancedFacetWrites = false;
        host.saveSettings();
        host.render();
      }
    });
  }

  host.root.querySelector("#btn-cancel-advanced-facets")?.addEventListener("click", () => {
    const confirmEl = host.root.querySelector<HTMLElement>("#settings-advanced-facets-confirm");
    if (confirmEl) confirmEl.hidden = true;
    const advBox = host.root.querySelector<HTMLInputElement>("#settings-allow-advanced-facets");
    if (advBox) advBox.checked = false;
  });

  host.root.querySelector("#btn-confirm-advanced-facets")?.addEventListener("click", () => {
    const confirmEl = host.root.querySelector<HTMLElement>("#settings-advanced-facets-confirm");
    if (confirmEl) confirmEl.hidden = true;
    host.settings.allowAdvancedFacetWrites = true;
    host.saveSettings();
    host.render();
  });

  host.root.querySelector("#btn-revoke-all-credentials")?.addEventListener("click", () => {
    const confirmEl = host.root.querySelector<HTMLElement>("#settings-revoke-all-confirm");
    if (confirmEl) confirmEl.hidden = false;
  });

  host.root.querySelector("#btn-cancel-revoke-all")?.addEventListener("click", () => {
    const confirmEl = host.root.querySelector<HTMLElement>("#settings-revoke-all-confirm");
    if (confirmEl) confirmEl.hidden = true;
  });

  host.root.querySelector("#btn-confirm-revoke-all")?.addEventListener("click", () => {
    const confirmEl = host.root.querySelector<HTMLElement>("#settings-revoke-all-confirm");
    if (confirmEl) confirmEl.hidden = true;
    void signOutAndRevokeAll(host);
  });

  host.root.querySelector("#btn-reopen-onboarding")?.addEventListener("click", () => {
    clearSettingsHighlight(host.root);
    host.isRecordingHotkey = false;
    host.hotkeyNeedsHint = false;
    host.activeSheet = "onboarding";
    invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
    host.render();
  });

  host.root.querySelector("#btn-check-update")?.addEventListener("click", () => {
    void host.checkForAppUpdate(true);
  });

  host.root.querySelector("#btn-install-update")?.addEventListener("click", () => {
    void host.startUpdateInstall();
  });

  host.root.querySelector("#btn-open-update")?.addEventListener("click", () => {
    host.openUpdatePage();
  });

  // A release notice lives on the general tab when one is waiting, otherwise on the system tab.
  host.root.querySelector("#btn-footer-update")?.addEventListener("click", () => {
    host.openSettingsSheet(host.availableUpdate ? "general" : "system");
  });

  const searchInput = host.root.querySelector<HTMLInputElement>("#settings-search-input");
  const clearSearchBtn = host.root.querySelector<HTMLElement>("#btn-clear-settings-search");
  const searchResultsEl = host.root.querySelector<HTMLElement>("#settings-search-results");

  const clearSearchUI = () => {
    session.searchQuery = "";
    session.searchSelectedIndex = null;
    if (searchInput) searchInput.value = "";
    if (clearSearchBtn) clearSearchBtn.hidden = true;
    if (searchResultsEl) {
      searchResultsEl.hidden = true;
      searchResultsEl.innerHTML = "";
    }
  };

  const commitAnchorJump = (anchor: SettingsAnchor) => {
    const targetTab = resolveSettingsAnchorTab(anchor, host.availableUpdate !== null);
    host.settingsTab = targetTab;
    showSettingsTab(host.root, targetTab);
    clearSearchUI();
    highlightSettingsAnchor(host.root, anchor);
  };

  const renderSearchDropdown = () => {
    if (!searchInput || !searchResultsEl) return;
    const rawQuery = searchInput.value;
    session.searchQuery = rawQuery;
    const trimmed = rawQuery.trim();
    if (clearSearchBtn) clearSearchBtn.hidden = trimmed === "";
    if (trimmed === "") {
      session.searchSelectedIndex = null;
      searchResultsEl.hidden = true;
      searchResultsEl.innerHTML = "";
      return;
    }

    const outcome = searchSettings(rawQuery, {
      hasCloudConsentEndpoints: host.settings.cloudConsentEndpoints.length > 0,
      hasAvailableUpdate: host.availableUpdate !== null,
    });

    searchResultsEl.hidden = false;
    if (outcome.hits.length > 0) {
      session.searchSelectedIndex = SettingsSearchSelection.clamped(
        session.searchSelectedIndex,
        outcome.hits.length,
      );
      const activeIdx = session.searchSelectedIndex ?? 0;
      searchResultsEl.innerHTML = outcome.hits
        .map((hit, idx) => {
          const selected = idx === activeIdx;
          return `<button
            type="button"
            role="option"
            aria-selected="${selected}"
            data-settings-search-hit="${escapeForHost(host, hit.anchor)}"
            class="cc-seg-pill ${selected ? "is-active" : ""}"
            style="display: flex; width: 100%; justify-content: space-between; align-items: center; text-align: left; padding: 6px 8px; margin-bottom: 2px;"
          >
            <span>${escapeForHost(host, hit.title)}</span>
            <span class="cc-field-hint" style="margin: 0; font-size: 11px;">${escapeForHost(host, hit.section)}</span>
          </button>`;
        })
        .join("");
      searchResultsEl.querySelectorAll<HTMLElement>("[data-settings-search-hit]").forEach((btn) => {
        btn.addEventListener("click", () => {
          const anchor = btn.dataset.settingsSearchHit as SettingsAnchor | undefined;
          if (anchor) commitAnchorJump(anchor);
        });
      });
    } else if (outcome.blocked) {
      session.searchSelectedIndex = null;
      searchResultsEl.innerHTML = `<div class="cc-field-hint" data-settings-search-blocked="${escapeForHost(
        host,
        outcome.blocked.reason,
      )}" style="padding: 6px 8px; margin: 0;">${escapeForHost(host, outcome.blocked.explanation)}</div>`;
    } else {
      session.searchSelectedIndex = null;
      searchResultsEl.innerHTML = `<div class="cc-field-hint" data-settings-search-empty style="padding: 6px 8px; margin: 0;">${escapeForHost(
        host,
        tr3("未找到匹配的设置项", "找不到相符的設定項", "No matching settings found"),
      )}</div>`;
    }
  };

  if (searchInput) {
    if (session.searchQuery !== "") {
      searchInput.value = session.searchQuery;
      renderSearchDropdown();
    }
    searchInput.addEventListener("input", () => {
      clearSettingsHighlight(host.root);
      renderSearchDropdown();
    });
    searchInput.addEventListener("keydown", (event) => {
      if (!searchResultsEl || searchResultsEl.hidden) return;
      const hitButtons = [...searchResultsEl.querySelectorAll<HTMLElement>("[data-settings-search-hit]")];
      if (event.key === "ArrowDown") {
        event.preventDefault();
        session.searchSelectedIndex = SettingsSearchSelection.moved(
          session.searchSelectedIndex,
          1,
          hitButtons.length,
        );
        renderSearchDropdown();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        session.searchSelectedIndex = SettingsSearchSelection.moved(
          session.searchSelectedIndex,
          -1,
          hitButtons.length,
        );
        renderSearchDropdown();
      } else if (event.key === "Enter") {
        const commitIdx = SettingsSearchSelection.commitIndex(
          session.searchSelectedIndex,
          hitButtons.length,
        );
        if (commitIdx !== null) {
          event.preventDefault();
          const targetAnchor = hitButtons[commitIdx]?.dataset.settingsSearchHit as SettingsAnchor | undefined;
          if (targetAnchor) commitAnchorJump(targetAnchor);
        }
      } else if (event.key === "Escape" && searchInput.value.trim() !== "") {
        event.preventDefault();
        event.stopPropagation();
        clearSearchUI();
      }
    });
  }

  clearSearchBtn?.addEventListener("click", () => {
    clearSearchUI();
    searchInput?.focus();
  });

  host.root.querySelectorAll<HTMLElement>("[data-settings-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.settingsTab;
      if (tab !== "general" && tab !== "connection" && tab !== "assistant" && tab !== "system") return;
      clearSettingsHighlight(host.root);
      clearSearchUI();
      if (tab === host.settingsTab) return;
      host.settingsTab = tab;
      showSettingsTab(host.root, tab);
    });
  });

  host.root.querySelector("#btn-start-qr")?.addEventListener("click", () => {
    void host.startXiaomiQRLogin();
  });

  host.root.querySelector("#btn-signout-mi")?.addEventListener("click", () => {
    host.signOutXiaomiAccount();
  });

  host.root.querySelector("#btn-close-settings")?.addEventListener("click", () => {
    if (hasUnsavedSettingsChanges(host)) {
      const unsavedBar = host.root.querySelector<HTMLElement>("#settings-unsaved-confirm");
      if (unsavedBar) {
        unsavedBar.hidden = false;
        return;
      }
    }
    closeSettingsSheetImmediate(host);
  });

  host.root.querySelector("#btn-cancel-close-settings")?.addEventListener("click", () => {
    const unsavedBar = host.root.querySelector<HTMLElement>("#settings-unsaved-confirm");
    if (unsavedBar) unsavedBar.hidden = true;
  });

  host.root.querySelector("#btn-discard-settings")?.addEventListener("click", () => {
    closeSettingsSheetImmediate(host);
  });

  host.root.querySelector("#btn-confirm-save-settings")?.addEventListener("click", () => {
    commitSettingsSave(host);
  });

  host.root.querySelectorAll<HTMLElement>("[data-conn-mode]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const mode = btn.dataset.connMode as ConnectionMode | undefined;
      if (!mode) return;
      if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
        host.cameraLive.closeCameraLiveView();
      }
      host.localControlRevision += 1;
      host.invalidateSourceControl();
      host.environmentReadings = [];
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.deviceFacets = {};
      // An armed high-risk write belongs to the backend it was armed on.
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
      host.render();
    });
  });

  const toggleHabitBtn = host.root.querySelector<HTMLElement>("#btn-toggle-habit-items");
  const habitItemsListEl = host.root.querySelector<HTMLElement>("#settings-habit-items-list");
  const syncHabitDisclosureUI = () => {
    if (!toggleHabitBtn || !habitItemsListEl) return;
    const count = listReadableHabits({
      entries: host.settings.habitEntries,
      sequences: host.habitSequences(),
      phrases: host.settings.learnedShortcuts.map((s) => ({ phrase: s.phrase, summary: s.reply })),
      devices: host.devices,
      scenes: host.scenes,
    }).length;
    habitItemsListEl.hidden = !session.habitItemsExpanded;
    toggleHabitBtn.setAttribute("aria-expanded", String(session.habitItemsExpanded));
    toggleHabitBtn.textContent = session.habitItemsExpanded
      ? tr3("收起列表", "收起清單", "Hide Items")
      : tr3(`逐条查看 (${count})`, `逐條查看 (${count})`, `View Items (${count})`);
  };
  syncHabitDisclosureUI();

  toggleHabitBtn?.addEventListener("click", () => {
    session.habitItemsExpanded = !session.habitItemsExpanded;
    syncHabitDisclosureUI();
  });

  host.root.querySelectorAll<HTMLElement>("[data-forget-habit-id]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const itemId = btn.dataset.forgetHabitId;
      if (!itemId) return;
      const updated = forgetHabitItem(
        {
          entries: host.settings.habitEntries,
          sequences: host.habitSequences(),
          phrases: host.settings.learnedShortcuts,
        },
        itemId,
      );
      if (!updated.removed) return;
      host.settings.habitEntries = updated.entries;
      host.settings.learnedShortcuts = updated.phrases;
      try {
        localStorage.setItem(
          "menumijia.windows.habit.sequences.v1",
          JSON.stringify({
            sequences: updated.sequences,
            lastAction: host.lastHabitAction(),
          }),
        );
      } catch {}
      host.aiProactiveSuggestions = null;
      host.aiProactiveSignature = null;
      host.saveSettings();
      host.render();
    });
  });

  host.root.querySelectorAll<HTMLElement>("[data-del-habit]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = Number(btn.dataset.delHabit);
      if (!Number.isNaN(idx)) {
        host.settings.learnedShortcuts.splice(idx, 1);
        host.saveSettings();
        host.render();
      }
    });
  });

  host.root.querySelector("#btn-clear-habits")?.addEventListener("click", () => {
    session.habitItemsExpanded = false;
    host.settings.habitEntries = [];
    localStorage.removeItem("menumijia.windows.habit.sequences.v1");
    host.aiProactiveSuggestions = null;
    host.aiProactiveSignature = null;
    host.saveSettings();
    host.render();
  });

  host.root.querySelectorAll<HTMLElement>("[data-ai-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const presetId = btn.dataset.aiPreset;
      const preset = ASSISTANT_PROVIDER_PRESETS.find((p) => p.id === presetId);
      if (!preset) return;
      const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
      const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
      const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
      const prevPreset = inferAssistantPreset(baseEl?.value ?? host.settings.assistantBaseURL);

      if (preset.id === "custom") {
        if (baseEl) baseEl.value = "";
        if (
          modelEl &&
          (modelEl.value === prevPreset.defaultModel || ModelIntentResolver.isSystemOneModel(modelEl.value))
        ) {
          modelEl.value = "gpt-4o-mini";
        }
        if (apiKeyEl) {
          apiKeyEl.placeholder = preset.keyPlaceholder;
          apiKeyEl.value = "";
        }
      } else {
        if (baseEl) baseEl.value = preset.defaultBaseURL;
        if (modelEl) modelEl.value = preset.defaultModel;
        if (apiKeyEl) {
          apiKeyEl.placeholder = preset.keyPlaceholder;
          host.syncKeyFieldWithEndpoint(apiKeyEl, preset.defaultBaseURL);
        }
      }

      host.root.querySelectorAll<HTMLElement>("[data-ai-preset]").forEach((el) => {
        el.classList.toggle("is-active", el.dataset.aiPreset === preset.id);
      });
    });
  });

  host.root.querySelector<HTMLInputElement>("#settings-base-url")?.addEventListener("input", (event) => {
    const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
    const target = event.target as HTMLInputElement;
    const inferred = inferAssistantPreset(target.value);
    host.root.querySelectorAll<HTMLElement>("[data-ai-preset]").forEach((el) => {
      el.classList.toggle("is-active", el.dataset.aiPreset === inferred.id);
    });
    if (apiKeyEl) {
      apiKeyEl.placeholder = inferred.keyPlaceholder;
      host.syncKeyFieldWithEndpoint(apiKeyEl, target.value);
    }
  });

  host.root.querySelector<HTMLInputElement>("#settings-ask-when-unsure")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    writeAskWhenUnsure(host.settings, checked);
    host.saveSettings();
  });

  const envStatusEl = host.root.querySelector<HTMLElement>("#settings-env-import-status");
  if (envStatusEl && session.envImportStatus) {
    envStatusEl.textContent = session.envImportStatus.text;
    envStatusEl.style.color = session.envImportStatus.isError ? "#e67e22" : "";
  }
  host.root.querySelector("#btn-import-env-key")?.addEventListener("click", () => {
    const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
    const requestedBaseURL = (baseEl?.value ?? host.settings.assistantBaseURL).trim();
    const preset = inferAssistantPreset(requestedBaseURL);
    const requestedEndpoint = assistantEndpointIdentity(requestedBaseURL);
    const capturedRevision = host.localControlRevision;
    if (!presetSupportsEnvKeyImport(preset.id)) {
      const msg = tr3(
        "当前预设无需或不支持从环境变量自动导入密钥",
        "目前預設無需或不支援從環境變數自動匯入金鑰",
        "This preset does not import keys from environment variables",
      );
      session.envImportStatus = { text: msg, isError: true };
      const statusNode = host.root.querySelector<HTMLElement>("#settings-env-import-status");
      if (statusNode) {
        statusNode.textContent = msg;
        statusNode.style.color = "#e67e22";
      }
      return;
    }
    void (async () => {
      const hit = await importAmbientAssistantKey(preset.id);
      const currentBaseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
      const currentBaseURL = (currentBaseEl?.value ?? host.settings.assistantBaseURL).trim();
      const currentPreset = inferAssistantPreset(currentBaseURL);
      const currentEndpoint = assistantEndpointIdentity(currentBaseURL);
      if (
        getSettingsSession(host) !== session ||
        host.localControlRevision !== capturedRevision ||
        currentPreset.id !== preset.id ||
        currentEndpoint !== requestedEndpoint
      ) {
        return;
      }
      const statusNode = host.root.querySelector<HTMLElement>("#settings-env-import-status");
      const currentApiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
      if (hit) {
        if (currentApiKeyEl) currentApiKeyEl.value = hit.apiKey;
        const msg = tr3(
          `已从 ${hit.envName} 导入密钥（点击底部「完成并保存」生效）`,
          `已從 ${hit.envName} 匯入金鑰（點擊底部「完成並儲存」生效）`,
          `Imported key from ${hit.envName} (click Save to persist)`,
        );
        session.envImportStatus = { text: msg, isError: false };
        if (statusNode) {
          statusNode.textContent = msg;
          statusNode.style.color = "";
        }
      } else {
        const msg = tr3(
          `未在环境变量中找到 ${preset.shortTitle} 的 API Key`,
          `未在環境變數中找到 ${preset.shortTitle} 的 API Key`,
          `No ${preset.shortTitle} API key found in environment variables`,
        );
        session.envImportStatus = { text: msg, isError: true };
        if (statusNode) {
          statusNode.textContent = msg;
          statusNode.style.color = "#e67e22";
        }
      }
    })();
  });

  const aiTestBtn = host.root.querySelector<HTMLButtonElement>("#btn-test-ai-connection");
  const aiTestStatusEl = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
  if (aiTestStatusEl && session.aiTestStatus) {
    aiTestStatusEl.textContent = session.aiTestStatus.text;
    aiTestStatusEl.dataset.testState = session.aiTestStatus.state;
    aiTestStatusEl.style.color = session.aiTestStatus.state === "error" ? "#e67e22" : "";
  }

  aiTestBtn?.addEventListener("click", () => {
    const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
    const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
    const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
    const haUrlEl = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
    const baseURL = baseEl ? baseEl.value : host.settings.assistantBaseURL;
    const model = modelEl ? modelEl.value : host.settings.assistantModel;
    const apiKey = apiKeyEl ? apiKeyEl.value : storedKeyForURL(host, baseURL);
    const haUrl = haUrlEl ? haUrlEl.value : host.settings.haBaseURL;

    const testingText = tr3("正在测试连接…", "正在測試連線…", "Testing connection…");
    session.aiTestStatus = { text: testingText, state: "testing" };
    aiTestBtn.disabled = true;
    const liveStatusEl = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
    if (liveStatusEl) {
      liveStatusEl.textContent = testingText;
      liveStatusEl.dataset.testState = "testing";
      liveStatusEl.style.color = "";
    }

    void (async () => {
      const result = await probeAssistantConnection({ baseURL, model, apiKey, haUrl });
      const state = result.ok ? "ok" : "error";
      session.aiTestStatus = { text: result.message, state };
      const btnNow = host.root.querySelector<HTMLButtonElement>("#btn-test-ai-connection");
      if (btnNow) btnNow.disabled = false;
      const statusNow = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
      if (statusNow) {
        statusNow.textContent = result.message;
        statusNow.dataset.testState = state;
        statusNow.style.color = result.ok ? "" : "#e67e22";
      }
    })();
  });

  const refreshPreview = () => refreshHabitSharePreview(host);
  host.root.querySelector("#settings-habit-share")?.addEventListener("change", refreshPreview);
  host.root.querySelector("#settings-habit-share-sample")?.addEventListener("input", refreshPreview);
  refreshPreview();

  host.root.querySelector("#btn-save-settings")?.addEventListener("click", () => {
    commitSettingsSave(host);
  });
}

/**
 * Switches the visible Settings panel without a re-render. All four panels stay mounted behind
 * `hidden`, so typed drafts and the scroll offset of the body survive the switch (#78).
 */
export function showSettingsTab(root: HTMLElement, tab: SettingsTab): void {
  root.querySelectorAll<HTMLElement>("[data-settings-tab]").forEach((button) => {
    const active = button.dataset.settingsTab === tab;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-selected", String(active));
  });
  root.querySelectorAll<HTMLElement>("[data-settings-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.settingsPanel !== tab;
  });
  const body = root.querySelector<HTMLElement>(".cc-sheet-body");
  if (body) body.scrollTop = 0;
}

/** Recomputes the habit-share preview from the current switch and sample text. */
export function refreshHabitSharePreview(host: SettingsEventsHost): void {
  const shareEl = host.root.querySelector<HTMLInputElement>("#settings-habit-share");
  const sampleEl = host.root.querySelector<HTMLInputElement>("#settings-habit-share-sample");
  const preview = host.root.querySelector<HTMLElement>("#settings-habit-share-preview");
  if (!shareEl || !sampleEl || !preview) return;
  const sentence = shareHabitSentence({
    sharing: shareEl.checked ? "on" : "off",
    memory: new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()),
    phrases: host.settings.learnedShortcuts.map((shortcut) => ({
      phrase: shortcut.phrase,
      intents: shortcut.intents,
    })),
    devices: withAliases(host.layout, host.devices),
    scenes: host.scenes,
    mention: { kind: "utterance", text: sampleEl.value },
    now: new Date(),
  });
  preview.textContent = sentence.length > 0 ? sentence : t("不会发送习惯摘要");
}
