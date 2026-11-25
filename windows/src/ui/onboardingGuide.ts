import {
  ASSISTANT_PROVIDER_PRESETS,
  ModelIntentResolver,
  assistantEndpointIdentity,
  inferAssistantPreset,
  type AssistantConfig,
  type AssistantProviderPresetInfo,
} from "../core/assistant.js";
import { DUAL_SOURCE_ENABLED_STORAGE_KEY, type DualSourceCoordinator } from "../core/dualSourceProvider.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { t, tr3 } from "../core/i18n.js";
import { hasSecondaryMiAccountsInIndex } from "../core/miAccountsStore.js";
import {
  MI_CLOUD_REGIONS,
  maskedMiUserId,
  normalizeMiCloudRegion,
  type QRLoginTicket,
} from "../core/miCloudClient.js";
import { ALL_OFF_HOLD_MS, SF_ICONS, UNDO_BANNER_MULTI_DEVICE_THRESHOLD, UNDO_BANNER_SECONDS, UNDO_BANNER_SECONDS_MULTI } from "./appConstants.js";
import type { ConnectionMode, QrLoginPhase } from "./appTypes.js";
import { demoDevices, demoScenes } from "./demo.js";
import { isPlainHttpRemoteEndpoint, normalizeHaEndpoint } from "./haEndpoint.js";
import {
  cancelHomeAssistantDiscovery,
  discoverHomeAssistantOnLan,
  haDiscoveryFailureStatus,
  renderHaDiscoveredCandidates,
  resolveHaDiscoveryOutcome,
  type HaDiscoveredInstance,
} from "./haDiscovery.js";
import {
  haCacheIfEnabled,
  isHostHaEnabled,
  setHostDualSourceEnabled,
  type DualSourceInspectableHost,
  type DualSourceMutableHost,
} from "./cloudRefresh.js";
import type { SettingsEventsHost } from "./settingsEvents.js";
import { switchSource } from "./sourceSwitch.js";
import { bindDeviceTypeSelectionEvents, deviceTypeSelectionIsAvailable, renderDeviceTypeSelectionSection } from "./deviceTypeSelectionView.js";
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

interface OnboardingSessionState {
  selectedMode: ConnectionMode | null;
  haURLDraft: string;
  haTokenDraft: string;
  haDiscovering: boolean;
  haDiscoverGeneration: number;
  haDiscovered: readonly HaDiscoveredInstance[];
  haDiscoverStatus: { text: string; isError: boolean } | null;
  haConnectError: string | null;
  haConnecting: boolean;
  haConnectGeneration: number;
  /** Undo for the in-flight HA verification, replayed when the guide closes before it settles. */
  haPendingRollback: (() => void) | null;
  haConnectedCount: number | null;
  addingSecondPlatform: boolean;
  assistantDraft: AssistantDraftState;
  statusNote: { text: string; isError: boolean } | null;
}

const onboardingSessionByHost = new WeakMap<object, OnboardingSessionState>();

function cancelOnboardingHaDiscovery(session: OnboardingSessionState): void {
  session.haDiscoverGeneration += 1;
  if (!session.haDiscovering) return;
  session.haDiscovering = false;
  cancelHomeAssistantDiscovery();
}

export function clearOnboardingSession(host: object): void {
  const existing = onboardingSessionByHost.get(host);
  if (existing) {
    cancelOnboardingHaDiscovery(existing);
  }
  onboardingSessionByHost.delete(host);
}

/**
 * Rebuilds the guide and then moves focus to `selector` (P2-8, #293). The sheet is rewritten as a
 * whole, so the pressed radio or a revealed step must be re-focused *after* the render: the panel
 * pipeline restores the pre-render focus target during the render itself.
 */
function renderGuideFocused(host: OnboardingRenderViewHost, selector: string): void {
  host.render();
  host.root.querySelector<HTMLElement>(selector)?.focus({ preventScroll: true });
}

/**
 * One polite live region that outlives every guide rebuild (P2-9, #293).
 *
 * `mountOnboardingGuide` replaces `sheet.innerHTML` on each state change, so a `role="status"` node
 * created by that markup is brand new each time: screen readers announce a region when its *content*
 * changes, and a freshly inserted node with text already inside is not reliably announced. This node
 * is mounted once beside the panel root instead, and only its `textContent` changes afterwards.
 */
const guideAnnouncerByRoot = new WeakMap<HTMLElement, HTMLElement>();
const guideAnnouncementTimerByNode = new WeakMap<HTMLElement, number>();

function guideAnnouncer(root: HTMLElement): HTMLElement {
  const existing = guideAnnouncerByRoot.get(root);
  if (existing?.isConnected) return existing;
  const doc = root.ownerDocument;
  const node = doc.createElement("p");
  node.className = "cc-visually-hidden";
  node.setAttribute("data-onboarding-announcer", "");
  node.setAttribute("role", "status");
  node.setAttribute("aria-live", "polite");
  node.setAttribute("aria-atomic", "true");
  (root.parentElement ?? doc.body).appendChild(node);
  guideAnnouncerByRoot.set(root, node);
  return node;
}

function cancelGuideAnnouncementTimer(node: HTMLElement): void {
  const timer = guideAnnouncementTimerByNode.get(node);
  if (timer === undefined) return;
  window.clearTimeout(timer);
  guideAnnouncementTimerByNode.delete(node);
}

/** Writes a message into the persistent announcer; repeated text is cleared first so it re-announces. */
function announceGuideStatus(host: OnboardingRenderViewHost, message: string): void {
  if (host.activeSheet !== "onboarding") return;
  const node = guideAnnouncer(host.root);
  cancelGuideAnnouncementTimer(node);
  if (node.textContent === message) {
    node.textContent = "";
    const timer = window.setTimeout(() => {
      guideAnnouncementTimerByNode.delete(node);
      if (node.isConnected && host.activeSheet === "onboarding") node.textContent = message;
    }, 0);
    guideAnnouncementTimerByNode.set(node, timer);
    return;
  }
  node.textContent = message;
}

function clearGuideAnnouncement(host: OnboardingRenderViewHost): void {
  const node = guideAnnouncerByRoot.get(host.root);
  if (!node) return;
  cancelGuideAnnouncementTimer(node);
  node.textContent = "";
}

export interface OnboardingRenderViewHost extends SettingsEventsHost {
  readonly qrStatusText?: string;
  /** Explicit QR-login outcome (Nit-5, #293); the guide never parses the status copy. */
  readonly qrPhase?: QrLoginPhase;
  /** Set while startup credential hydration has not settled; the sheet is a loading state (P2-6). */
  readonly onboardingAwaitingCredentials?: boolean;
  dualSourceCoordinator?: DualSourceCoordinator | null;
  dualSourceEnabledOverride?: boolean | null;
  submitServiceEndpoints?(force?: boolean): void;
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

function hasConnectedMi(host: OnboardingRenderViewHost): boolean {
  return host.settings.miSession !== null || hasSecondaryMiAccountsInIndex();
}

function hasConnectedHA(host: OnboardingRenderViewHost): boolean {
  return homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken) !== null;
}

function ensureSession(host: OnboardingRenderViewHost): OnboardingSessionState {
  const existing = onboardingSessionByHost.get(host);
  if (existing) return existing;
  let initialMode: ConnectionMode | null = null;
  if (host.settings.connectionMode === "demo") {
    initialMode = "demo";
  } else if (host.settings.connectionMode === "homeAssistant" && hasConnectedHA(host)) {
    initialMode = "homeAssistant";
  } else if (host.settings.connectionMode === "xiaomiCloud" && hasConnectedMi(host)) {
    initialMode = "xiaomiCloud";
  }
  const created: OnboardingSessionState = {
    selectedMode: initialMode,
    haURLDraft: host.settings.haBaseURL,
    haTokenDraft: host.settings.haToken,
    haDiscovering: false,
    haDiscoverGeneration: 0,
    haDiscovered: [],
    haDiscoverStatus: null,
    haConnectError: null,
    haConnecting: false,
    haConnectGeneration: 0,
    haPendingRollback: null,
    haConnectedCount: null,
    addingSecondPlatform: false,
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

function mapHaErrorToPlainLanguage(rawError: string): string {
  if (/authentication rejected|401|unauthorized/i.test(rawError)) {
    return t("专属连接钥匙无效或已过期。设备还未同步。请检查令牌并重新连接。");
  }
  if (rawError.includes("not been approved") || rawError.includes("未授权的网络来源")) {
    return t("明文 HTTP 连接已被拒绝。设备还未同步。请改用 HTTPS 或在提示中允许此地址。");
  }
  // P2-13 (#293): the native layer already reports these as distinct strings, so the guide can tell
  // a timeout from a failed host lookup without inventing new error classes or network probes.
  if (/timed out|timeout|operation timed out/i.test(rawError)) {
    return t("连接超时。设备还未同步。请确认家庭服务器已开机并在同一网络，然后重试。");
  }
  if (/address lookup failed|dns/i.test(rawError)) {
    return t("找不到这个地址对应的主机。设备还未同步。请检查地址拼写，或改用局域网 IP 地址。");
  }
  // `authenticated()` wraps both the TLS upgrade and the WebSocket HTTP upgrade of
  // `tungstenite::client_tls` into the one string "Home Assistant handshake failed", so this error
  // can be a certificate problem, a 404/5xx from a wrong path or reverse proxy, or a proxy that does
  // not forward the Upgrade header. Never claim which one it was, and never suggest falling back to
  // plaintext: the generic copy names both checks instead.
  if (/handshake failed/i.test(rawError) && !/authentication handshake failed/i.test(rawError)) {
    return t("安全连接或 WebSocket 握手未能完成。设备还未同步。请确认地址指向 Home Assistant 根路径（反向代理需转发 WebSocket Upgrade）、证书有效且系统时间正确。");
  }
  return t("无法访问此地址。设备还未同步。请确认电脑和家庭服务器在同一网络，或修改地址。");
}

function switchConnectionModeInOnboarding(
  host: OnboardingRenderViewHost,
  mode: ConnectionMode,
  options: { readonly allowNetworkRefresh?: boolean } = {},
): void {
  if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
    host.cameraLive.closeCameraLiveView();
  }
  if (mode === "demo" && host.settings.connectionMode !== "demo") {
    const prev = host.settings.connectionMode;
    if ((prev === "xiaomiCloud" && hasConnectedMi(host)) || (prev === "homeAssistant" && hasConnectedHA(host))) {
      host.settings.preDemoConnectionMode = prev;
    }
  } else if (mode !== "demo") {
    host.settings.preDemoConnectionMode = null;
  }
  switchSource(host, "onboarding-connection-mode");
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
    host.devices = host.demoDevicesForEnabledTypes?.() ?? demoDevices();
    host.scenes = demoScenes();
  } else if (mode === "xiaomiCloud") {
    host.devices = structuredClone(host.settings.cachedXiaomiDevices);
    host.scenes = [];
    if (options.allowNetworkRefresh && host.settings.miSession) {
      void host.refreshDevices(false);
    }
  } else if (mode === "homeAssistant") {
    const inspectable = host as unknown as DualSourceInspectableHost & { readonly settings: typeof host.settings };
    const cache = haCacheIfEnabled(inspectable, { requireIdentityMatch: true });
    host.devices = cache ? structuredClone(cache.home.devices) : [];
    host.scenes = cache ? structuredClone(cache.home.scenes) : [];
    host.environmentReadings = cache ? structuredClone(cache.home.environmentReadings) : [];
    host.deviceFacets = cache ? structuredClone(cache.home.deviceFacets ?? {}) : {};
    if (options.allowNetworkRefresh && isHostHaEnabled(inspectable) && hasConnectedHA(host)) {
      void host.refreshHADevices(false);
    }
  }
  host.saveSettings();
}

/** Leaves demo mode: restores prior real platform if one was connected, else opens onboarding platform picker. */
export function leaveDemoHome(host: OnboardingRenderViewHost): void {
  const prior = host.settings.preDemoConnectionMode;
  if (prior === "xiaomiCloud" && hasConnectedMi(host)) {
    switchConnectionModeInOnboarding(host, "xiaomiCloud", { allowNetworkRefresh: true });
    host.render();
    return;
  }
  if (prior === "homeAssistant" && hasConnectedHA(host)) {
    switchConnectionModeInOnboarding(host, "homeAssistant", { allowNetworkRefresh: true });
    host.render();
    return;
  }
  switchConnectionModeInOnboarding(host, "xiaomiCloud", { allowNetworkRefresh: false });
  clearOnboardingSession(host);
  host.activeSheet = "onboarding";
  invokeTauriVoid("set_pin_popover", { pin: true });
  host.render();
}

function applyAssistantDraftToHost(host: OnboardingRenderViewHost, session: OnboardingSessionState): boolean {
  const resolved = resolveAssistantDraftForSave(session.assistantDraft);
  if (!resolved) return false;
  const prevBaseURL = host.settings.assistantBaseURL;
  const prevModel = host.settings.assistantModel;
  const prevApiKey = host.settings.openRouterApiKey;
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
  // A provider change through onboarding invalidates requests still in flight (P5a-W #3).
  if (
    host.settings.assistantBaseURL !== prevBaseURL ||
    host.settings.assistantModel !== prevModel ||
    host.settings.openRouterApiKey !== prevApiKey
  ) {
    host.advanceAssistantEpoch?.();
  }
  return true;
}

/**
 * Step 4's All Off reminder, built from the same constants the controls enforce (Nit-6, #293) so a
 * future tweak to the hold or undo duration cannot leave the guide quoting the old numbers.
 */
export function onboardingAllOffTimingCopy(): string {
  return tr3(
    "按住「全关」{hold} 秒确认，可在 {undo} 秒内撤销，{multi} 台起为 {long} 秒。",
    "按住「全關」{hold} 秒確認，可在 {undo} 秒內復原，{multi} 台起為 {long} 秒。",
    "Hold All Off for {hold}s to confirm; Undo stays up for {undo}s ({long}s from {multi} devices).",
    {
      hold: ALL_OFF_HOLD_MS / 1000,
      undo: UNDO_BANNER_SECONDS,
      multi: UNDO_BANNER_MULTI_DEVICE_THRESHOLD,
      long: UNDO_BANNER_SECONDS_MULTI,
    },
  );
}

/** Everything step 2 needs; extracted from `mountOnboardingGuide` so the markup is a pure function (Nit-3). */
export interface OnboardingQrStepView {
  readonly isPolling: boolean;
  /** Explicit login outcome (Nit-5): never inferred from the localized status text. */
  readonly expired: boolean;
  readonly statusText: string;
  readonly ticket: QRLoginTicket | null;
}

export interface OnboardingHaStepView {
  readonly urlDraft: string;
  readonly tokenDraft: string;
  readonly discovering?: boolean;
  readonly discovered?: readonly HaDiscoveredInstance[];
  readonly discoverStatus?: { readonly text: string; readonly isError: boolean } | null;
  readonly connecting: boolean;
  readonly error: string | null;
  readonly connectedCount: number | null;
}

export interface OnboardingConnectStepInput {
  readonly mode: ConnectionMode | null;
  readonly miUserId: string | null;
  readonly miCloudRegion: string;
  readonly qr: OnboardingQrStepView;
  readonly ha: OnboardingHaStepView;
  readonly escapeHtml: (raw: string) => string;
}

export function renderOnboardingConnectStep(input: OnboardingConnectStepInput): string {
  const esc = input.escapeHtml;
  if (input.mode === null) return "";
  if (input.mode === "xiaomiCloud") {
    const { qr } = input;
    const qrLabel = qr.isPolling
      ? t("正在等待手机米家扫码确认...")
      : qr.expired
        ? t("刷新二维码")
        : input.miUserId !== null
          ? t("切换/重新扫码 (已登录 {user})", { user: maskedMiUserId(input.miUserId) })
          : t("获取米家登录二维码");
    return `
      <div class="cc-field" data-onboarding-step="2">
        <p class="cc-onboarding-warning" data-onboarding-mi-warning role="note">
          ${esc(t("使用非官方连接方式。小米可能限制请求或风控账号，登录会过期，到期需重新扫码。凭据安全保存在本机。"))}
        </p>
        <details data-onboarding-mi-region-details class="cc-onboarding-block">
          <summary class="cc-field-hint cc-onboarding-region-summary">${t("云端服务器地区")}</summary>
          <div class="cc-onboarding-block is-compact">
            <select class="cc-input" data-mi-region>
              ${MI_CLOUD_REGIONS.map(
                (region) =>
                  `<option value="${region.code}" ${
                    normalizeMiCloudRegion(input.miCloudRegion) === region.code ? "selected" : ""
                  }>${esc(t(region.label))}</option>`,
              ).join("")}
            </select>
            <p class="cc-field-hint">${t("欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。")}</p>
          </div>
        </details>
        <div class="cc-qr-box cc-onboarding-block">
          <button type="button" class="cc-btn-primary is-full" id="btn-start-qr" ${qr.isPolling ? "disabled" : ""}>
            ${SF_ICONS.qrcode}
            <span>${esc(qrLabel)}</span>
          </button>
          <div class="cc-qr-status">${esc(qr.statusText)}</div>
          ${
            qr.ticket
              ? `<div class="cc-qr-frame"><img src="${esc(qr.ticket.qrImageURL)}" alt="${esc(t("米家登录二维码"))}" /></div>`
              : ""
          }
        </div>
        <div class="cc-onboarding-inline-actions">
          <button type="button" class="cc-inline-pill" id="btn-onboarding-back">${t("返回选平台")}</button>
          <button type="button" class="cc-inline-pill" id="btn-onboarding-skip">${t("稍后设置")}</button>
        </div>
      </div>
    `;
  }
  if (input.mode === "homeAssistant") {
    const { ha } = input;
    const warnPlainHttp = isPlainHttpRemoteEndpoint(ha.urlDraft);
    const discovering = Boolean(ha.discovering);
    const discovered = ha.discovered ?? [];
    const discoverStatus = ha.discoverStatus ?? null;
    const candidatesHtml = renderHaDiscoveredCandidates(discovered, esc, "data-onboarding-ha-candidate");
    return `
      <div class="cc-field" data-onboarding-step="2">
        <p class="cc-field-hint cc-onboarding-hint is-above" data-onboarding-ha-hint>
          ${esc(t("在 Home Assistant 网页设置里查看地址"))}
        </p>
        <label for="onboarding-ha-url">Home Assistant URL</label>
        <div class="cc-onboarding-row">
          <input
            id="onboarding-ha-url"
            class="cc-input"
            type="url"
            placeholder="http://homeassistant.local:8123"
            value="${esc(ha.urlDraft)}"
          />
          <button type="button" class="cc-btn-secondary" id="btn-onboarding-discover-ha" ${discovering ? "disabled" : ""}>
            ${esc(discovering ? t("正在查找…") : t("在局域网中查找"))}
          </button>
        </div>
        ${
          discoverStatus
            ? `<p class="cc-ha-discover-status ${discoverStatus.isError ? "is-error" : ""}" data-onboarding-ha-discover-status role="status">${esc(discoverStatus.text)}</p>`
            : ""
        }
        ${
          candidatesHtml
            ? `<div class="cc-ha-candidates" data-onboarding-ha-candidates>${candidatesHtml}</div>`
            : ""
        }
        <p class="cc-onboarding-warning is-spaced" data-onboarding-ha-http-warning role="note" ${warnPlainHttp ? "" : "hidden"}>
          ${esc(t("令牌将以明文在网络上传输，远程访问建议使用 HTTPS 或 Nabu Casa 地址。"))}
        </p>
        <label for="onboarding-ha-token" class="cc-onboarding-label is-spaced">${t("专属连接钥匙（长期访问令牌）")}</label>
        <p class="cc-field-hint cc-onboarding-hint is-tight" data-onboarding-ha-token-guide>
          ${esc(t("打开 Home Assistant 网页 → 个人资料 → 安全设置 → 创建长期访问令牌。"))}
        </p>
        <div class="cc-onboarding-row">
          <input
            id="onboarding-ha-token"
            class="cc-input"
            type="password"
            autocomplete="off"
            placeholder="${esc(tr3("粘贴 HA 长期访问令牌", "貼上 HA 長期存取權杖", "Paste HA Long-Lived Access Token"))}"
            value="${esc(ha.tokenDraft)}"
          />
          <button type="button" class="cc-btn-primary" id="btn-onboarding-connect-ha" ${ha.connecting ? "disabled" : ""}>
            ${esc(t("连接并验证"))}
          </button>
        </div>
        ${
          ha.error
            ? `<p class="cc-onboarding-warning is-spaced" data-onboarding-ha-error role="alert">${esc(ha.error)}</p>`
            : ha.connectedCount !== null
              ? `<p class="cc-field-hint cc-onboarding-hint is-below" data-onboarding-ha-verified>${esc(t("已连接 Home Assistant · {count} 台设备", { count: ha.connectedCount }))}</p>`
              : ""
        }
        <div class="cc-onboarding-inline-actions">
          <button type="button" class="cc-inline-pill" id="btn-onboarding-back">${t("返回选平台")}</button>
          <button type="button" class="cc-inline-pill" id="btn-onboarding-skip">${t("稍后设置")}</button>
          ${
            ha.error
              ? `<button type="button" class="cc-inline-pill" id="btn-onboarding-use-demo">${t("先逛逛（不连接设备）")}</button>`
              : ""
          }
        </div>
      </div>
    `;
  }
  return `
    <div class="cc-field" data-onboarding-step="2" data-onboarding-demo-banner>
      <p class="cc-sheet-note cc-onboarding-demo-title">${esc(t("示例家庭，不会控制真实设备"))}</p>
      <p class="cc-field-hint cc-onboarding-hint">${esc(t("内置虚拟全屋设备，完全离线、零网络请求。随时可返回连接米家或 Home Assistant。"))}</p>
      <div class="cc-onboarding-inline-actions">
        <button type="button" class="cc-inline-pill" id="btn-onboarding-back">${t("返回选平台")}</button>
      </div>
    </div>
  `;
}

export function mountOnboardingGuide(host: OnboardingRenderViewHost): void {
  if (host.activeSheet !== "onboarding") {
    clearOnboardingSession(host);
    clearGuideAnnouncement(host);
    return;
  }
  const sheet = host.root.querySelector<HTMLElement>(".cc-sheet:not(.cc-settings-sheet)");
  if (!sheet) return;

  const esc = (v: string) => (typeof host.escapeHtml === "function" ? host.escapeHtml(v) : escapeHtmlFallback(v));
  // P2-9 (#293): mount the persistent live region before any content can change, so the first
  // announcement is a text change to an existing node rather than a freshly inserted one.
  guideAnnouncer(host.root);
  // P2-6 (#293): startup credential hydration is still reading the vault, so a returning user whose
  // Mi session or HA token lives there would look like a fresh install. Keep the sheet as a minimal
  // loading state — no session, no card selection, no focus target — until it settles.
  if (host.onboardingAwaitingCredentials) {
    sheet.innerHTML = `
      <div class="cc-sheet-header">
        <div class="cc-sheet-badge">${esc(t("首次设置 · MenuBarHome"))}</div>
      </div>
      <div class="cc-onboarding-scroll cc-onboarding-loading" data-onboarding-loading>
        <h2 class="cc-sheet-title">${esc(t("正在读取已保存的连接…"))}</h2>
        <p class="cc-sheet-desc">${esc(
          t("读取本机凭据后即可继续，已连接过米家或 Home Assistant 的电脑不会重新出现引导。"),
        )}</p>
      </div>
    `;
    announceGuideStatus(host, t("正在读取已保存的连接…"));
    return;
  }
  const session = ensureSession(host);
  const draft = session.assistantDraft;
  const activePreset = findPreset(draft.selectedPreset);
  const miConnected = hasConnectedMi(host);
  const haConnected = hasConnectedHA(host);
  const hotkeyText = host.settings.globalHotkey || "Alt+M";
  const supportsEnvImport = presetSupportsEnvKeyImport(draft.selectedPreset) && draft.apiKey.trim() === "";
  const secondPlatformTarget: Exclude<ConnectionMode, "demo"> | null =
    miConnected && !haConnected
      ? "homeAssistant"
      : haConnected && !miConnected
        ? "xiaomiCloud"
        : null;
  const connectStep = renderOnboardingConnectStep({
    mode: session.selectedMode,
    miUserId: host.settings.miSession?.userId ?? null,
    miCloudRegion: host.settings.miCloudRegion,
    qr: {
      isPolling: Boolean(host.isPollingQR),
      expired: host.qrPhase === "expired",
      statusText: host.qrStatusText ?? "",
      ticket: host.qrTicket ?? null,
    },
    ha: {
      urlDraft: session.haURLDraft,
      tokenDraft: session.haTokenDraft,
      discovering: session.haDiscovering,
      discovered: session.haDiscovered,
      discoverStatus: session.haDiscoverStatus,
      connecting: session.haConnecting,
      error: session.haConnectError,
      connectedCount: session.haConnectedCount,
    },
    escapeHtml: esc,
  });


  sheet.innerHTML = `
    <div class="cc-sheet-header">
      <div class="cc-sheet-badge">${esc(t("首次设置 · MenuBarHome"))}</div>
      <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="${t("关闭引导")}" aria-label="${t("关闭引导")}">
        ${SF_ICONS.xmark}
      </button>
    </div>

    <div class="cc-onboarding-scroll">
      <h2 class="cc-sheet-title">${esc(t("你家用哪个平台管理智能设备？"))}</h2>
      <p class="cc-sheet-desc">${esc(t("先选择家庭平台，未连接前不会自动扫描局域网或发起网络请求。"))}</p>

      <div class="cc-field" data-onboarding-step="1">
        <div
          class="cc-onboarding-cards"
          role="radiogroup"
          aria-label="${esc(t("你家用哪个平台管理智能设备？"))}"
          data-onboarding-mode-group
        >
          <button
            type="button"
            role="radio"
            class="cc-onboarding-card ${session.selectedMode === "xiaomiCloud" ? "is-active" : ""}"
            data-onboarding-card="xiaomiCloud"
            data-onboarding-mode="xiaomiCloud"
            aria-checked="${session.selectedMode === "xiaomiCloud"}"
            tabindex="${session.selectedMode === "xiaomiCloud" || session.selectedMode === null ? "0" : "-1"}"
          >
            <span class="cc-onboarding-card-title">
              <span>${esc(t("米家"))}</span>
              ${miConnected ? `<span class="cc-inline-pill">${esc(t("已连接"))}</span>` : ""}
            </span>
            <span class="cc-onboarding-card-desc">${esc(t("手机米家 App 扫码直连，支持多账号与局域网优先"))}</span>
          </button>
          <button
            type="button"
            role="radio"
            class="cc-onboarding-card ${session.selectedMode === "homeAssistant" ? "is-active" : ""}"
            data-onboarding-card="homeAssistant"
            data-onboarding-mode="homeAssistant"
            aria-checked="${session.selectedMode === "homeAssistant"}"
            tabindex="${session.selectedMode === "homeAssistant" ? "0" : "-1"}"
          >
            <span class="cc-onboarding-card-title">
              <span>Home Assistant</span>
              ${haConnected ? `<span class="cc-inline-pill">${esc(t("已连接"))}</span>` : ""}
            </span>
            <span class="cc-onboarding-card-desc">${esc(t("局域网本地连接，适合自建家庭服务器"))}</span>
          </button>
          <button
            type="button"
            role="radio"
            class="cc-onboarding-card ${session.selectedMode === "demo" ? "is-active" : ""}"
            data-onboarding-card="demo"
            data-onboarding-mode="demo"
            aria-checked="${session.selectedMode === "demo"}"
            tabindex="${session.selectedMode === "demo" ? "0" : "-1"}"
          >
            <span class="cc-onboarding-card-title">
              <span>${esc(t("先逛逛（不连接设备）"))}</span>
            </span>
            <span class="cc-onboarding-card-desc">${esc(t("离线示例家庭，零网络请求，随时可连接真实平台"))}</span>
          </button>
        </div>
        ${
          secondPlatformTarget
            ? `<div class="cc-onboarding-block">
                <button type="button" class="cc-inline-pill" id="btn-onboarding-add-second-platform" data-second-platform="${secondPlatformTarget}">
                  ${esc(t("继续添加 {platform}（启用双源）", { platform: secondPlatformTarget === "homeAssistant" ? "Home Assistant" : t("米家") }))}
                </button>
              </div>`
            : ""
        }
      </div>

      ${connectStep}

      ${
        deviceTypeSelectionIsAvailable(host)
          ? `<div class="cc-field" data-onboarding-step="3" data-onboarding-device-types>
              <label class="cc-onboarding-label">${esc(tr3("选设备类型与功能", "選裝置類型與功能", "Device Types"))}</label>
              <p class="cc-field-hint cc-onboarding-hint is-tight">${esc(
                tr3(
                  "默认显示全部已支持类型。只想看灯和开关，或自己逐类挑选，都在这里改。",
                  "預設顯示全部已支援類型。只想看燈和開關，或自己逐類挑選，都在這裡改。",
                  "Every supported type is shown by default. Keep only lights and switches, or pick each type, here.",
                ),
              )}</p>
              ${renderDeviceTypeSelectionSection(host, { showHeading: false })}
            </div>`
          : ""
      }

      <div class="cc-field" data-onboarding-step="4">
        <label class="cc-onboarding-label">${esc(t("快捷操作与托盘提示"))}</label>
        <p class="cc-field-hint cc-onboarding-tip">• ${esc(t("点击右下角系统托盘图标或按 {hotkey} 随时呼出面板。", { hotkey: hotkeyText }))}</p>
        <p class="cc-field-hint cc-onboarding-tip">• ${esc(t("磁贴左侧一键开关，右侧展开精细调节。"))}</p>
        <p class="cc-field-hint cc-onboarding-tip">• ${esc(onboardingAllOffTimingCopy())}</p>

        <div class="cc-field-row cc-onboarding-block">
          <div>
            <label for="onboarding-launch-at-login">${t("开机自动启动")}</label>
            <p class="cc-field-hint cc-onboarding-hint is-below">${esc(
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

      <div class="cc-field" data-onboarding-ai-section>
        <label class="cc-onboarding-label">${esc(t("可选：AI 一句话控制"))}</label>
        <div class="cc-segmented-pills cc-onboarding-preset-pills">
          ${ASSISTANT_PROVIDER_PRESETS.map((preset) => {
            const isSelected = draft.selectedPreset === preset.id;
            const label = preset.id === "custom" ? tr3("自定义", "自訂", "Custom") : preset.shortTitle;
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
            ? `<div id="onboarding-custom-endpoint-fields" class="cc-onboarding-stack">
                <input id="onboarding-base-url" class="cc-input" type="text" placeholder="${esc(tr3("输入自定义接口地址，如 https://api.example.com/v1", "輸入自訂介面位址，如 https://api.example.com/v1", "Custom endpoint URL, e.g. https://api.example.com/v1"))}" aria-label="${esc(tr3("AI 服务地址", "AI 服務位址", "AI Endpoint URL"))}" value="${esc(draft.baseURL)}" />
                <input id="onboarding-model" class="cc-input" type="text" placeholder="gpt-4o-mini" aria-label="${esc(tr3("决策模型", "決策模型", "Decision Model"))}" value="${esc(draft.model)}" />
              </div>`
            : ""
        }
        <div class="cc-onboarding-row">
          <input id="onboarding-api-key" class="cc-input" type="password" autocomplete="off" placeholder="${esc(activePreset.keyPlaceholder)}" value="${esc(draft.apiKey)}" />
          <button type="button" class="cc-btn-secondary" id="btn-onboarding-save-ai">${esc(tr3("保存 AI", "儲存 AI", "Save AI"))}</button>
        </div>
        ${
          supportsEnvImport
            ? `<div class="cc-onboarding-block is-compact"><button type="button" class="cc-inline-pill" id="btn-onboarding-import-env">${esc(tr3("从环境变量导入 Key", "從環境變數匯入 Key", "Import Key from Env"))}</button></div>`
            : ""
        }
        ${
          session.statusNote
            ? `<p class="cc-field-hint cc-onboarding-status-note ${session.statusNote.isError ? "is-error" : ""}" id="onboarding-status-note">${esc(session.statusNote.text)}</p>`
            : ""
        }
      </div>
    </div>

    <div class="cc-sheet-footer">
      <button type="button" class="cc-btn-secondary" id="btn-skip-onboarding">${t("稍后设置")}</button>
      <button type="button" class="cc-btn-primary" id="btn-finish-onboarding">${t("进入控制中心")}</button>
    </div>
  `;

  sheet.querySelectorAll<HTMLElement>("[data-onboarding-mode]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const mode = btn.dataset.onboardingMode as ConnectionMode | undefined;
      if (!mode) return;
      if (mode !== "homeAssistant") {
        cancelOnboardingHaDiscovery(session);
      }
      session.selectedMode = mode;
      session.addingSecondPlatform = false;
      session.statusNote = null;
      session.haConnectError = null;
      if (mode === "demo") {
        switchConnectionModeInOnboarding(host, "demo");
      }
      // P2-8 (#293): the whole sheet is rebuilt, so the pressed radio has to be re-focused by hand.
      renderGuideFocused(host, `[data-onboarding-mode="${mode}"]`);
    });
  });

  // P2-8/P2-9 (#293): a radiogroup is expected to answer the arrow keys, not just clicks.
  sheet.querySelector<HTMLElement>("[data-onboarding-mode-group]")?.addEventListener("keydown", (event) => {
    const key = event.key;
    if (!["ArrowDown", "ArrowRight", "ArrowUp", "ArrowLeft", "Home", "End"].includes(key)) return;
    const radios = Array.from(sheet.querySelectorAll<HTMLElement>("[data-onboarding-mode]"));
    if (radios.length === 0) return;
    const current = radios.findIndex((radio) => radio.getAttribute("aria-checked") === "true");
    const forward = key === "ArrowDown" || key === "ArrowRight";
    const next =
      key === "Home"
        ? 0
        : key === "End"
          ? radios.length - 1
          : current < 0
            ? forward
              ? 0
              : radios.length - 1
            : (current + (forward ? 1 : -1) + radios.length) % radios.length;
    event.preventDefault();
    event.stopPropagation();
    radios[next]?.click();
  });

  sheet.querySelector<HTMLElement>("#btn-onboarding-add-second-platform")?.addEventListener("click", (event) => {
    const target = (event.currentTarget as HTMLElement).dataset.secondPlatform as Exclude<ConnectionMode, "demo"> | undefined;
    if (!target) return;
    session.selectedMode = target;
    session.addingSecondPlatform = true;
    session.haConnectError = null;
    // The step the user just asked for is the new focus target, not the removed card.
    renderGuideFocused(host, `[data-onboarding-step="2"] input, [data-onboarding-step="2"] button`);
  });

  sheet.querySelector("#btn-onboarding-back")?.addEventListener("click", () => {
    cancelOnboardingHaDiscovery(session);
    session.selectedMode = null;
    session.addingSecondPlatform = false;
    session.haConnectError = null;
    renderGuideFocused(host, "[data-onboarding-mode]");
  });

  sheet.querySelector("#btn-onboarding-use-demo")?.addEventListener("click", () => {
    cancelOnboardingHaDiscovery(session);
    session.selectedMode = "demo";
    session.haConnectError = null;
    switchConnectionModeInOnboarding(host, "demo");
    renderGuideFocused(host, "[data-onboarding-demo-banner] button");
  });

  sheet.querySelectorAll<HTMLSelectElement>("[data-mi-region]").forEach((select) => {
    select.addEventListener("change", () => {
      host.settings.miCloudRegion = normalizeMiCloudRegion(select.value);
      host.saveSettings();
      host.render();
    });
  });

  sheet.querySelector("#btn-start-qr")?.addEventListener("click", () => {
    const wantsDualSource = session.addingSecondPlatform || hasConnectedHA(host);
    if (wantsDualSource) {
      // Nit-4 (#293 comment): switching the merge pipeline on before the scan is what puts the code
      // on screen, but the *persisted* choice waits for a real Mi session below. A scan the user
      // abandons must not leave "dual source is on" in storage with only one platform connected.
      setHostDualSourceEnabled(host as unknown as DualSourceMutableHost, true, { persist: false });
    }
    const hadMiBefore = hasConnectedMi(host);
    void host.startXiaomiQRLogin().finally(() => {
      if (!wantsDualSource) return;
      const hasMiNow = hasConnectedMi(host);
      if (!hasMiNow && !hadMiBefore) return;
      // The scan plus its refresh can take a while; a user who turned dual-source off in Settings
      // meanwhile owns the newer choice, so this deferred write must not switch it back on.
      const dualHost = host as unknown as DualSourceMutableHost;
      if (dualHost.dualSourceEnabledOverride !== true || host.settings.dualSourceEnabled !== true) return;
      setHostDualSourceEnabled(dualHost, true, { persist: true });
      host.saveSettings();
    });
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-ha-url")?.addEventListener("input", (event) => {
    session.haURLDraft = (event.target as HTMLInputElement).value;
    const warnEl = sheet.querySelector<HTMLElement>("[data-onboarding-ha-http-warning]");
    if (warnEl) warnEl.hidden = !isPlainHttpRemoteEndpoint(session.haURLDraft);
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-ha-token")?.addEventListener("input", (event) => {
    session.haTokenDraft = (event.target as HTMLInputElement).value;
  });

  sheet.querySelector("#btn-onboarding-discover-ha")?.addEventListener("click", () => {
    if (session.haDiscovering) return;
    const gen = ++session.haDiscoverGeneration;
    session.haDiscovering = true;
    session.haDiscovered = [];
    session.haDiscoverStatus = { text: t("正在查找…"), isError: false };
    const capturedToken = host.sourceEpoch.capture();
    host.render();
    announceGuideStatus(host, t("正在查找…"));
    void discoverHomeAssistantOnLan()
      .then((found) => {
        if (
          onboardingSessionByHost.get(host) !== session ||
          host.activeSheet !== "onboarding" ||
          session.selectedMode !== "homeAssistant" ||
          session.haDiscoverGeneration !== gen ||
          !capturedToken.isCurrent()
        ) {
          return;
        }
        session.haDiscovering = false;
        const outcome = resolveHaDiscoveryOutcome(found);
        session.haDiscovered = outcome.results;
        session.haDiscoverStatus = outcome.status;
        host.render();
        announceGuideStatus(host, outcome.status.text);
      })
      .catch(() => {
        if (
          onboardingSessionByHost.get(host) !== session ||
          host.activeSheet !== "onboarding" ||
          session.selectedMode !== "homeAssistant" ||
          session.haDiscoverGeneration !== gen ||
          !capturedToken.isCurrent()
        ) {
          return;
        }
        session.haDiscovering = false;
        session.haDiscovered = [];
        session.haDiscoverStatus = haDiscoveryFailureStatus();
        host.render();
        announceGuideStatus(host, session.haDiscoverStatus.text);
      });
  });

  sheet.querySelectorAll<HTMLButtonElement>("[data-onboarding-ha-candidate]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const pickedUrl = btn.dataset.onboardingHaCandidate?.trim();
      if (!pickedUrl) return;
      session.haURLDraft = pickedUrl;
      session.haDiscoverStatus = { text: t("已填入地址：{url}", { url: pickedUrl }), isError: false };
      renderGuideFocused(host, "#onboarding-ha-url");
      const urlInput = sheet.querySelector<HTMLInputElement>("#onboarding-ha-url");
      if (urlInput && urlInput.value !== pickedUrl) {
        urlInput.value = pickedUrl;
      }
      const warnEl = sheet.querySelector<HTMLElement>("[data-onboarding-ha-http-warning]");
      if (warnEl) warnEl.hidden = !isPlainHttpRemoteEndpoint(pickedUrl);
      announceGuideStatus(host, session.haDiscoverStatus.text);
    });
  });

  sheet.querySelector("#btn-onboarding-connect-ha")?.addEventListener("click", () => {
    cancelOnboardingHaDiscovery(session);
    const endpoint = normalizeHaEndpoint(session.haURLDraft);
    const token = session.haTokenDraft.trim();
    if (!endpoint || !token) {
      session.haConnectError = t("请填写完整的 Home Assistant 地址与专属连接钥匙。");
      host.render();
      return;
    }
    const prevIdentity = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken);
    const nextIdentity = homeAssistantIdentity(endpoint, token);
    const identityChanged =
      host.settings.connectionMode !== "homeAssistant" ||
      endpoint !== host.settings.haBaseURL ||
      token !== host.settings.haToken ||
      prevIdentity !== nextIdentity;
    const shouldEnableDual = session.addingSecondPlatform || hasConnectedMi(host);
    const dualHost = host as unknown as DualSourceMutableHost;
    const prevHaBaseURL = host.settings.haBaseURL;
    const prevHaToken = host.settings.haToken;
    const prevCachedHAHome = host.settings.cachedHAHome;
    const prevConnectionMode = host.settings.connectionMode;
    const prevPreDemoConnectionMode = host.settings.preDemoConnectionMode ?? null;
    const prevDualEnabled = host.settings.dualSourceEnabled;
    const prevDualOverride = dualHost.dualSourceEnabledOverride;
    const hadPersistedDualKey = (() => {
      try {
        return typeof localStorage !== "undefined" && localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY) === "1";
      } catch {
        return false;
      }
    })();
    /** Puts back the credentials this attempt replaced, so an unverified token never stays stored. */
    const restoreHaCredentials = (): void => {
      host.settings.haBaseURL = prevHaBaseURL;
      host.settings.haToken = prevHaToken;
      host.settings.cachedHAHome = prevCachedHAHome;
      host.settings.connectionMode = prevConnectionMode;
      // Nit-2 (#293 comment): a failed attempt from demo must not lose the platform demo came from,
      // or "connect a real home" would forget a still-connected Mi/HA login.
      host.settings.preDemoConnectionMode = prevPreDemoConnectionMode;
      host.haConnectionError = null;
    };
    /** Undoes the dual-source write; only meaningful when this attempt was the one enabling it. */
    const restoreDualSource = (): void => {
      if (!shouldEnableDual) return;
      if (prevDualEnabled === undefined) delete host.settings.dualSourceEnabled;
      else host.settings.dualSourceEnabled = prevDualEnabled;
      dualHost.dualSourceEnabledOverride = prevDualOverride ?? null;
      host.dualSourceCoordinator?.reset();
      try {
        if (typeof localStorage !== "undefined") {
          if (hadPersistedDualKey) localStorage.setItem(DUAL_SOURCE_ENABLED_STORAGE_KEY, "1");
          else localStorage.removeItem(DUAL_SOURCE_ENABLED_STORAGE_KEY);
        }
      } catch {
        // Ignore storage failures during rollback.
      }
    };
    /** Full undo of the attempt; skipped when a later connect already wrote different credentials. */
    const rollbackAttempt = (): void => {
      if (host.settings.haBaseURL !== endpoint || host.settings.haToken !== token) return;
      // The non-dual path persists the attempt before verifying, so only a previously working HA
      // (or a dual-source attempt, which must never leave an unverified token behind) is restored.
      if (shouldEnableDual || prevIdentity !== null) restoreHaCredentials();
      restoreDualSource();
      host.saveSettings(true);
    };

    const connectGen = ++session.haConnectGeneration;
    session.haURLDraft = endpoint;
    session.haConnectError = null;
    session.haConnecting = true;
    session.haPendingRollback = rollbackAttempt;
    session.haConnectedCount = null;
    switchSource(host, "onboarding-ha-endpoint");
    host.settings.cachedHAHome = null;
    if (identityChanged && !shouldEnableDual) {
      host.devices = [];
      host.scenes = [];
      host.environmentReadings = [];
      host.deviceFacets = {};
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      (host as { expandedDeviceId?: string | null }).expandedDeviceId = null;
      (host as { waitingDeviceIds?: Set<string> }).waitingDeviceIds?.clear();
      host.selectRoom(null);
    }
    host.settings.haBaseURL = endpoint;
    host.settings.haToken = token;
    host.settings.preDemoConnectionMode = null;
    if (shouldEnableDual) {
      if (host.settings.connectionMode === "demo") {
        host.settings.connectionMode = "xiaomiCloud";
      }
      host.dualSourceCoordinator?.reset();
      setHostDualSourceEnabled(dualHost, true, { persist: false });
      host.submitServiceEndpoints?.(true);
    } else {
      host.settings.connectionMode = "homeAssistant";
      host.saveSettings(true);
    }
    session.selectedMode = "homeAssistant";
    session.statusNote = { text: t("正在连接并验证 Home Assistant…"), isError: false };
    const capturedToken = host.sourceEpoch.capture();
    host.render();
    announceGuideStatus(host, t("正在连接并验证 Home Assistant…"));
    const refreshPromise = shouldEnableDual ? host.refreshDevices(false) : host.refreshHADevices(false);
    void Promise.resolve(refreshPromise)
      .then(() => {
        if (onboardingSessionByHost.get(host) !== session || !capturedToken.isCurrent()) {
          if (session.haConnectGeneration === connectGen) {
            session.haConnecting = false;
            session.haPendingRollback = null;
            if (onboardingSessionByHost.get(host) === session) host.render();
          }
          return;
        }
        session.haConnecting = false;
        session.haPendingRollback = null;
        const err = typeof host.haConnectionError === "string" ? host.haConnectionError.trim() : "";
        const verifiedHaHome = shouldEnableDual
          ? (() => {
              const snap = host.dualSourceCoordinator?.getLastHASnapshot() ?? null;
              return err === "" && snap !== null && snap.identity === nextIdentity ? snap.home : null;
            })()
          : err === "" && host.settings.cachedHAHome?.identity === nextIdentity
            ? host.settings.cachedHAHome.home
            : null;
        if (verifiedHaHome) {
          if (shouldEnableDual) {
            setHostDualSourceEnabled(dualHost, true, { persist: true });
            host.saveSettings(true);
            session.addingSecondPlatform = false;
          }
          session.haConnectError = null;
          session.haConnectedCount = verifiedHaHome.devices.length;
          session.statusNote = null;
          host.render();
          announceGuideStatus(host, t("已连接 Home Assistant · {count} 台设备", { count: session.haConnectedCount }));
          return;
        }
        rollbackAttempt();
        session.haConnectError = err
          ? mapHaErrorToPlainLanguage(err)
          : t("无法访问此地址。设备还未同步。请确认电脑和家庭服务器在同一网络，或修改地址。");
        session.statusNote = null;
        host.render();
        announceGuideStatus(host, session.haConnectError);
      })
      .catch(() => {
        if (onboardingSessionByHost.get(host) !== session || !capturedToken.isCurrent()) {
          if (session.haConnectGeneration === connectGen) {
            session.haConnecting = false;
            session.haPendingRollback = null;
            if (onboardingSessionByHost.get(host) === session) host.render();
          }
          return;
        }
        session.haConnecting = false;
        session.haPendingRollback = null;
        rollbackAttempt();
        session.haConnectError = t("无法访问此地址。设备还未同步。请确认电脑和家庭服务器在同一网络，或修改地址。");
        session.statusNote = null;
        host.render();
        announceGuideStatus(host, session.haConnectError);
      });
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
      .then(() => host.render())
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
    const updated = session.assistantDraft;
    const preset = findPreset(updated.selectedPreset);
    sheet.querySelectorAll<HTMLElement>("[data-onboarding-ai-preset]").forEach((pill) => {
      const active = pill.dataset.onboardingAiPreset === updated.selectedPreset;
      pill.classList.toggle("is-active", active);
      pill.setAttribute("aria-pressed", String(active));
    });
    const modelEl = sheet.querySelector<HTMLInputElement>("#onboarding-model");
    if (modelEl && modelEl.value !== updated.model) modelEl.value = updated.model;
    const keyEl = sheet.querySelector<HTMLInputElement>("#onboarding-api-key");
    if (keyEl) {
      keyEl.placeholder = preset.keyPlaceholder;
      if (keyEl.value !== updated.apiKey) keyEl.value = updated.apiKey;
    }
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-model")?.addEventListener("input", (event) => {
    session.assistantDraft = { ...session.assistantDraft, model: (event.target as HTMLInputElement).value };
  });

  sheet.querySelector<HTMLInputElement>("#onboarding-api-key")?.addEventListener("input", (event) => {
    session.assistantDraft = { ...session.assistantDraft, apiKey: (event.target as HTMLInputElement).value };
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
      announceGuideStatus(host, session.statusNote.text);
      return;
    }
    host.saveSettings(true);
    session.statusNote = {
      text: tr3("已保存 AI 助手配置", "已儲存 AI 助手設定", "AI assistant configuration saved"),
      isError: false,
    };
    host.render();
    announceGuideStatus(host, session.statusNote.text);
  });

  sheet.querySelector("#btn-onboarding-import-env")?.addEventListener("click", () => {
    const requestedPreset = session.assistantDraft.selectedPreset;
    const requestedBaseURL = session.assistantDraft.baseURL.trim();
    const capturedToken = host.sourceEpoch.capture();
    void (async () => {
      const hit = await importAmbientAssistantKey(requestedPreset);
      if (
        onboardingSessionByHost.get(host) !== session ||
        !capturedToken.isCurrent() ||
        session.assistantDraft.selectedPreset !== requestedPreset ||
        session.assistantDraft.baseURL.trim() !== requestedBaseURL
      ) {
        return;
      }
      if (hit) {
        session.assistantDraft = { ...session.assistantDraft, apiKey: hit.apiKey };
        session.statusNote = {
          text: tr3(`已从环境变量 ${hit.envName} 导入密钥`, `已從環境變數 ${hit.envName} 匯入金鑰`, `Imported API key from ${hit.envName}`),
          isError: false,
        };
      } else {
        session.statusNote = {
          text: tr3("未在环境变量中检测到对应服务商的 API Key", "未在環境變數中偵測到對應服務商的 API Key", "No matching API key found in environment variables"),
          isError: true,
        };
      }
      host.render();
      announceGuideStatus(host, session.statusNote.text);
    })();
  });

  /** Closing the guide with a verification still in flight must not persist that unverified HA. */
  const abandonPendingHaVerification = (): void => {
    if (!session.haConnecting) return;
    session.haConnecting = false;
    const rollback = session.haPendingRollback;
    session.haPendingRollback = null;
    rollback?.();
  };

  const completeAndClose = (markCompleted: boolean) => {
    abandonPendingHaVerification();
    const keyInput = sheet.querySelector<HTMLInputElement>("#onboarding-api-key");
    if (keyInput) session.assistantDraft = { ...session.assistantDraft, apiKey: keyInput.value };
    const baseInput = sheet.querySelector<HTMLInputElement>("#onboarding-base-url");
    if (baseInput) session.assistantDraft = { ...session.assistantDraft, baseURL: baseInput.value };
    const modelInput = sheet.querySelector<HTMLInputElement>("#onboarding-model");
    if (modelInput) session.assistantDraft = { ...session.assistantDraft, model: modelInput.value };

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

    if (markCompleted) {
      host.settings.hasCompletedOnboarding = true;
    }
    host.saveSettings(hasConnectedMi(host) || hasConnectedHA(host));
    clearOnboardingSession(host);
    host.activeSheet = "none";
    invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
    host.render();
  };

  sheet.querySelector("#btn-close-onboarding")?.addEventListener("click", () => completeAndClose(true));
  sheet.querySelector("#btn-finish-onboarding")?.addEventListener("click", () => completeAndClose(true));
  sheet.querySelector("#btn-skip-onboarding")?.addEventListener("click", () => completeAndClose(true));
  sheet.querySelector("#btn-onboarding-skip")?.addEventListener("click", () => completeAndClose(true));
  // Step 4 (P4b-W): the same block Settings renders, bound to the same handlers, so the guide and the
  // settings page cannot drift apart.
  bindDeviceTypeSelectionEvents(host as unknown as Parameters<typeof bindDeviceTypeSelectionEvents>[0]);
}
