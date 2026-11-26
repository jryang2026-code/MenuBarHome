import { t, tr3 } from "../core/i18n.js";
import { syncSlidingTabIndicators } from "./reconciler.js";
import { trText } from "../core/quickActions.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  forgetHabitItem,
  inferAssistantPreset,
  isAiAssistantEnabled,
  isLocalNetworkEndpoint,
  isProactiveSuggestionsEnabled,
  listReadableHabits,
  parseAssistantEndpoint,
  removeAssistantProviderState,
  shareHabitSentence,
  type AssistantConfig,
  type HabitLastAction,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import { normalizeMiCloudRegion, type HttpRequest, type HttpResponse, type HttpTransport } from "../core/miCloudClient.js";
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
} from "../core/pollingPolicy.js";
import { withAliases, type HomeOption, type LayoutPrefs } from "./panelPrefs.js";
import { normalizePanelTheme } from "./panelTheme.js";
import type { ConnectionMode, PendingHighRiskConfirmation, PersistedSettings, ReplyBannerState } from "./appTypes.js";
import { demoDevices, demoScenes } from "./demo.js";
import { isFullPanelHost, setEventAutomationRunning } from "./activityStackView.js";
import { clearHostSessionAndDualSourceState, submitServiceEndpoints, syncAutomationLifecycle } from "./appLifecycle.js";
import type { CapabilityIndexedDevice } from "../core/capabilityReferenceVerdict.js";
import { applyHaTypePruneSnapshot, applyMiotTypePruneSnapshot, buildHostCapabilityContext, haCacheIfEnabled, isDualSourceEnabled, isHostHaEnabled } from "./cloudRefresh.js";
import { haConnectionScope, removeDisconnectedHaFromSelection, revalidateAfterMiAccountReenable } from "../core/miAccountControl.js";
import { clearConnectionRemovals, pendingConnectionRemovalScopes } from "../core/connectionRemoval.js";
import { clearHaScopeLifecycle } from "../core/haTransportGate.js";
import { AutomationRuleStore } from "../core/automationEngine.js";
import { ScheduledCommandStore } from "../core/scheduledCommands.js";
import { scheduledCommandIdentity, setScheduledCommandsRunning } from "./scheduledCommands.js";
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
import { copyCompanionConfig, detectCompanionIntegration, setCompanionNotice, setPendingMiVaultDeletion, setRaycastIntegrationEnabled } from "./speechGuard.js";
import { switchSource, type SourceSwitchHost } from "./sourceSwitch.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import { bindAutomationSettingsEvents } from "./automationSettingsView.js";
import { bindConnectionsAndDiagEvents, reportProblemOnHost, type ConnectionsAndDiagHost } from "./connectionsAndDiagView.js";
import { bindEnergySettingsEvents } from "./energySettingsView.js";
import { clearGenericCameraRemovalConfirmation } from "./genericCameraSettingsView.js";
import { bindDeviceTypeSelectionEvents, clearDeviceTypeSelectionSession } from "./deviceTypeSelectionView.js";
import { getSettingsTabSpec, normalizeSettingsTab, type SettingsTab } from "./settingsViews.js";
import { normalizeHaEndpoint } from "./haEndpoint.js";
import {
  cancelHomeAssistantDiscovery,
  discoverHomeAssistantOnLan,
  haDiscoveryFailureStatus,
  renderHaDiscoveredCandidates,
  resolveHaDiscoveryOutcome,
  type HaDiscoveredInstance,
} from "./haDiscovery.js";
import type { GitHubRelease } from "../core/updateChecker.js";

export interface SettingsEventsHost extends SourceSwitchHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  readonly cameraLive: {
    readonly activeLiveCameraId: string | null;
    readonly liveCameraKeepAliveTimer: number | null;
    closeCameraLiveView(): void;
    discardRetainedCloudSessions?(): void;
  };
  assistantKeysByPreset: Record<string, string>;
  devices: SmartDevice[];
  /** Off-panel Mi devices of the current snapshot, kept only for enabled safety alerts (P3a-W). */
  safetyRetainedDevices?: SmartDevice[];
  safetyRetainedDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  hiddenMiDevices?: readonly CapabilityIndexedDevice[];
  /** The Home Assistant half of the same snapshot (P3b-W); see `applyHaTypePruneSnapshot`. */
  haTypePruneScope?: string | null;
  safetyRetainedHADevices?: SmartDevice[];
  safetyRetainedHADeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  hiddenHADevices?: readonly CapabilityIndexedDevice[];
  scenes: HomeScene[];
  environmentReadings: EnvironmentReading[];
  homes: HomeOption[];
  readonly layout: LayoutPrefs;
  readonly isStandaloneSettingsWindow?: boolean;
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
  clearPendingHighRisk(options?: { readonly syncPin?: boolean }): void;
  groupOwnerByMemberDid: Map<string, string>;
  hotkeyNeedsHint: boolean;
  isRecordingHotkey: boolean;
  pendingCloudConsent: { utterance: string; endpoint: string } | null;
  replyBanner: ReplyBannerState | null;
  selectRoom(roomId: string | null, roomName?: string): void;
  habitSequences(): readonly HabitSequenceEntry[];
  lastHabitAction(): HabitLastAction | null;
  checkForAppUpdate(manual: boolean): Promise<void>;
  handleNaturalCommand(raw: string, fromScheduled?: boolean): Promise<void>;
  openSettingsSheet(tab?: SettingsTab, anchor?: SettingsAnchor): void;
  openUpdatePage(): void;
  refreshDevices(silent?: boolean): Promise<void>;
  refreshHADevices(silent?: boolean): Promise<void>;
  render(): void;
  saveSettings(force?: boolean): void;
  setPanelTheme?(raw: unknown): void;
  shouldKeepPopoverPinned(): boolean;
  signOutXiaomiAccount(): void;
  startUpdateInstall(): Promise<void>;
  startXiaomiQRLogin(): Promise<void>;
  syncKeyFieldWithEndpoint(apiKeyEl: HTMLInputElement, baseURL: string): void;
  apiKeyFor?(baseURL: string): string;
  escapeHtml?(value: string): string;
  /** Demo sample cards for the stored device types; falls back to the full sample home (P4b-W). */
  demoDevicesForEnabledTypes?(): SmartDevice[];
  /** Invalidates in-flight AI requests after an enable/disable or provider change (P5a-W). */
  advanceAssistantEpoch?(): void;
  /**
   * Invalidates only the in-flight suggestion run after the 主动建议 switch changes (P5b-W);
   * user-initiated commands keep their own `assistantEpoch`.
   */
  advanceProactiveEpoch?(): void;
  /** Current feature-level AI generation; request helpers capture and compare it (P5a-W). */
  readonly assistantEpoch?: number;
  /** False while startup credential hydration is still reading the vault (P5a-W). */
  readonly timerCredentialsReady?: boolean;
}

interface SettingsUiSessionState {
  launchAtLoginSynced: boolean;
  habitItemsExpanded: boolean;
  searchQuery: string;
  searchSelectedIndex: number | null;
  aiTestStatus: { text: string; state: "idle" | "testing" | "ok" | "error" } | null;
  envImportStatus: { text: string; isError: boolean } | null;
  haDiscovering: boolean;
  haDiscoverGeneration: number;
  haDiscoverResults: readonly HaDiscoveredInstance[];
  haDiscoverStatus: { text: string; isError: boolean } | null;
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
      haDiscovering: false,
      haDiscoverGeneration: 0,
      haDiscoverResults: [],
      haDiscoverStatus: null,
    };
    settingsSessionByHost.set(host, state);
  }
  return state;
}

function cancelSettingsHaDiscovery(session: SettingsUiSessionState, clearResults: boolean): void {
  session.haDiscoverGeneration += 1;
  if (session.haDiscovering) {
    session.haDiscovering = false;
    cancelHomeAssistantDiscovery();
  }
  if (clearResults) {
    session.haDiscoverResults = [];
    session.haDiscoverStatus = null;
  }
}

function escapeSettingsHtml(host: SettingsEventsHost, raw: string): string {
  const hostEscape = (host as { escapeHtml?: (value: string) => string }).escapeHtml;
  if (typeof hostEscape === "function") return hostEscape(raw);
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function syncSettingsHaDiscoveryUi(host: SettingsEventsHost, session: SettingsUiSessionState): void {
  const discoverBtn = host.root.querySelector<HTMLButtonElement>("#btn-settings-discover-ha");
  if (discoverBtn) {
    discoverBtn.disabled = session.haDiscovering;
    discoverBtn.textContent = session.haDiscovering ? t("正在查找…") : t("在局域网中查找");
  }
  const statusEl = host.root.querySelector<HTMLElement>("#settings-ha-discover-status");
  if (statusEl) {
    if (session.haDiscoverStatus) {
      statusEl.hidden = false;
      statusEl.textContent = session.haDiscoverStatus.text;
      statusEl.classList.toggle("is-error", session.haDiscoverStatus.isError);
    } else {
      statusEl.hidden = true;
      statusEl.textContent = "";
      statusEl.classList.remove("is-error");
    }
  }
  const candidatesEl = host.root.querySelector<HTMLElement>("#settings-ha-candidates");
  if (candidatesEl) {
    if (session.haDiscoverResults.length > 0) {
      candidatesEl.hidden = false;
      candidatesEl.innerHTML = renderHaDiscoveredCandidates(
        session.haDiscoverResults,
        (value) => escapeSettingsHtml(host, value),
        "data-settings-ha-candidate",
      );
    } else {
      candidatesEl.hidden = true;
      candidatesEl.innerHTML = "";
    }
  }
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

  const haUrl = root.querySelector<HTMLInputElement>("#settings-ha-url");
  if (haUrl && normalizeHaEndpoint(haUrl.value) !== normalizeHaEndpoint(host.settings.haBaseURL)) {
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
  config: AssistantConfig & {
    readonly haUrl?: string;
    readonly restoreAssistantUrl?: string;
    readonly restoreHaUrl?: string;
    readonly resolveRestoreEndpoints?: () => {
      readonly assistantUrl: string;
      readonly haUrl: string;
    };
  },
  transport?: HttpTransport,
  /** Wraps every HTTP attempt (initial call and in-resolver retries); see P5a-W #1/#3. */
  gate?: (request: HttpRequest) => Promise<HttpResponse>,
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
  const baseTransport = transport ?? createTransport();
  const effectiveTransport: HttpTransport = gate ? (request) => gate(request) : baseTransport;
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
    const shouldAuthorizeDraft = !transport && Boolean(invoke);
    const activeHaUrl = (config.haUrl ?? "").trim();
    if (shouldAuthorizeDraft && invoke) {
      await invoke("set_service_endpoints", {
        assistantUrl: trimmedBase,
        haUrl: activeHaUrl,
      });
    }
    try {
      await resolver.resolve("打开书房灯", [probeDevice], []);
    } finally {
      if (
        shouldAuthorizeDraft &&
        invoke &&
        (config.resolveRestoreEndpoints !== undefined ||
          config.restoreAssistantUrl !== undefined ||
          config.restoreHaUrl !== undefined)
      ) {
        const currentSaved = config.resolveRestoreEndpoints?.();
        const savedAssistant = (
          currentSaved?.assistantUrl ??
          config.restoreAssistantUrl ??
          trimmedBase
        ).trim();
        const savedHa = (currentSaved?.haUrl ?? config.restoreHaUrl ?? activeHaUrl).trim();
        if (savedAssistant !== trimmedBase || savedHa !== activeHaUrl) {
          await invoke("set_service_endpoints", {
            assistantUrl: savedAssistant,
            haUrl: savedHa,
          }).catch(() => {});
        }
      }
    }
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

/**
 * Removes the provider currently shown in the AI settings form (P5a-W acceptance #2):
 * its saved key slot is deleted from the credential vault, its endpoint bindings and
 * cloud-send consent are cleared, and — when it is the configured provider — the config
 * falls back to the app default preset. Other providers' key slots and bindings stay.
 */
export async function removeActiveAssistantProvider(host: SettingsEventsHost): Promise<void> {
  // Removal targets what the form currently shows: the provider picker, which its own
  // changes and the URL input keep in sync. The URL draft alone is ambiguous — an empty
  // custom draft must mean "remove Custom", not fall back to the saved provider.
  const selectedPresetId = host.root.querySelector<HTMLSelectElement>("#settings-ai-provider")?.value || undefined;
  const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
  const draftBase = (baseEl?.value ?? "").trim();
  const presetId =
    selectedPresetId ?? inferAssistantPreset(draftBase !== "" ? draftBase : host.settings.assistantBaseURL).id;
  // Startup hydration may still be reading the vault: mutating before it finishes lets
  // hydrateCredentials merge the removed key back and re-persist it on save. Wait (bounded)
  // for the hydration flag before touching provider state.
  const hydrationDeadline = Date.now() + 5000;
  while (host.timerCredentialsReady === false && Date.now() < hydrationDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  // Snapshot for the vault-failure rollback: after a failed persist the retry must target
  // the same provider, not whatever the default-preset fallback re-activation shows.
  const rollback = {
    assistantBaseURL: host.settings.assistantBaseURL,
    assistantModel: host.settings.assistantModel,
    openRouterApiKey: host.settings.openRouterApiKey,
    assistantKeyEndpoint: host.settings.assistantKeyEndpoint,
    assistantCustomKeyEndpoint: host.settings.assistantCustomKeyEndpoint,
    assistantLegacyKeyEndpoint: host.settings.assistantLegacyKeyEndpoint,
    cloudConsentEndpoints: [...host.settings.cloudConsentEndpoints],
    removedKey: host.assistantKeysByPreset[presetId],
  };
  // Mutates the saved settings and the in-memory key map in place; the vault persist below
  // turns the dropped preset entry into a credential-store delete.
  removeAssistantProviderState({
    presetId,
    settings: host.settings,
    keysByPreset: host.assistantKeysByPreset,
  });
  // Advance before any await: a model result landing during the vault persist must not
  // dispatch against the just-removed configuration (P5a-W #3).
  host.advanceAssistantEpoch?.();

  // MenuMijiaWindowsApp always carries the vault; the structural settings host does not name it.
  const vault = (host as Partial<MenuMijiaWindowsApp>).credentialVault;
  if (vault) {
    try {
      await vault.persist(credentialsFromSettings(host.settings, host.assistantKeysByPreset));
    } catch {
      host.settings.assistantBaseURL = rollback.assistantBaseURL;
      host.settings.assistantModel = rollback.assistantModel;
      host.settings.openRouterApiKey = rollback.openRouterApiKey;
      host.settings.assistantKeyEndpoint = rollback.assistantKeyEndpoint;
      host.settings.assistantCustomKeyEndpoint = rollback.assistantCustomKeyEndpoint;
      host.settings.assistantLegacyKeyEndpoint = rollback.assistantLegacyKeyEndpoint;
      host.settings.cloudConsentEndpoints = rollback.cloudConsentEndpoints;
      if (rollback.removedKey !== undefined) {
        host.assistantKeysByPreset[presetId] = rollback.removedKey;
      }
      host.replyBanner = {
        text: t("无法从系统凭据库移除该服务商的密钥，请重试"),
        source: t("出错提示"),
        isError: true,
      };
      host.render();
      return;
    }
  }
  host.saveSettings();

  host.replyBanner = {
    text: t("已移除本机保存的该服务商配置与密钥"),
    source: t("AI 一句话控制"),
  };
  // Drop the removed provider's typed draft (base URL / model / key): the draft capture
  // would otherwise restore it after the re-render and a later save would re-write the
  // removed key into the vault — the revoke-all path clears credential inputs the same way.
  for (const selector of ["#settings-base-url", "#settings-model", "#settings-api-key"]) {
    const field = host.root.querySelector<HTMLInputElement>(selector);
    if (field) {
      field.value = "";
      field.defaultValue = "";
    }
  }
  host.render();
}

export async function signOutAndRevokeAll(host: SettingsEventsHost): Promise<void> {
  setPendingMiVaultDeletion(true);
  // Revoke-all supersedes any single-connection removal: everything is being wiped here, and a
  // stale record would keep a later sign-in disabled by the removal overlay (P2c-W).
  clearConnectionRemovals();
  if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
    host.cameraLive.closeCameraLiveView();
  }
  host.cameraLive.discardRetainedCloudSessions?.();
  switchSource(host, "settings-sign-out-revoke-all");
  host.clearPendingHighRisk();
  host.pendingCloudConsent = null;

  applyMiotTypePruneSnapshot(host, null);
  host.settings.miSession = null;
  host.settings.cachedXiaomiDevices = [];
  host.settings.selectedHomeId = null;
  (host as { miSessionExpired?: boolean }).miSessionExpired = false;
  clearPersistedMiSessionExpired();
  clearCachedXiaomiTopology(host);
  host.cloudValuesStale = false;
  (host as { expandedDeviceId?: string | null }).expandedDeviceId = null;
  (host as { waitingDeviceIds?: Set<string> }).waitingDeviceIds?.clear();
  (host as { unresolvedRoomDids?: Set<string> }).unresolvedRoomDids?.clear();
  (host as { qrTicket?: unknown }).qrTicket = null;
  (host as { qrPhase?: string }).qrPhase = "idle";
  (host as { qrStatusText?: string }).qrStatusText = t(
    "点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。",
  );

  const oldHaScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  clearHaScopeLifecycle(oldHaScope);
  removeDisconnectedHaFromSelection(null);

  host.settings.haBaseURL = "";
  host.settings.haToken = "";
  host.settings.cachedHAHome = null;
  applyHaTypePruneSnapshot(host, null);

  host.settings.openRouterApiKey = "";
  host.settings.assistantKeyEndpoint = null;
  host.settings.assistantCustomKeyEndpoint = null;
  host.settings.assistantLegacyKeyEndpoint = null;
  host.assistantKeysByPreset = {};
  host.settings.cloudConsentEndpoints = [];
  host.advanceAssistantEpoch?.();

  const session = getSettingsSession(host);
  session.aiTestStatus = null;
  session.envImportStatus = null;
  cancelSettingsHaDiscovery(session, true);

  host.settings.connectionMode = "demo";
  host.devices = host.demoDevicesForEnabledTypes?.() ?? demoDevices();
  host.scenes = demoScenes();
  host.environmentReadings = [];
  host.homes = [];
  host.groupOwnerByMemberDid = new Map();
  host.deviceFacets = {};
  host.selectRoom(null);

  const appHost = host as unknown as MenuMijiaWindowsApp;
  const vault = (host as unknown as Partial<MenuMijiaWindowsApp>).credentialVault;
  const revokeMultiAndDualPromise = clearHostSessionAndDualSourceState(appHost, { revokeAll: true });

  void setRaycastIntegrationEnabled(appHost, false, { persistSettings: false, render: false });

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
    await revokeMultiAndDualPromise;
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
  clearGenericCameraRemovalConfirmation(host);
  cancelSettingsHaDiscovery(getSettingsSession(host), true);
  syncSettingsSaveHint(host, "reset");
  clearSettingsHighlight(host.root);
  const hasRealTauriWindow =
    typeof window !== "undefined" &&
    Boolean((window as { __TAURI_INTERNALS__?: { metadata?: unknown } }).__TAURI_INTERNALS__?.metadata);
  if (host.isStandaloneSettingsWindow && hasRealTauriWindow) {
    invokeTauriVoid("close_settings_window");
    return;
  }
  host.activeSheet = "none";
  host.isRecordingHotkey = false;
  host.hotkeyNeedsHint = false;
  invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
  host.render();
}

function settingsUnsavedConfirm(host: SettingsEventsHost): HTMLElement | null {
  return host.root.querySelector<HTMLElement>("#settings-unsaved-confirm");
}

function keepEditingSettings(host: SettingsEventsHost): boolean {
  const unsavedBar = settingsUnsavedConfirm(host);
  if (!unsavedBar || unsavedBar.hidden) return false;
  unsavedBar.hidden = true;
  return true;
}

export function requestCloseSettingsSheet(host: SettingsEventsHost): boolean {
  if (hasUnsavedSettingsChanges(host)) {
    const unsavedBar = settingsUnsavedConfirm(host);
    if (unsavedBar) {
      unsavedBar.hidden = false;
      return false;
    }
  }
  closeSettingsSheetImmediate(host);
  return true;
}

export function handleSettingsSheetEscape(host: SettingsEventsHost): void {
  if (keepEditingSettings(host)) return;
  requestCloseSettingsSheet(host);
}

function commitSettingsSave(host: SettingsEventsHost): void {
  const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
  const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
  const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
  const habitEl = host.root.querySelector<HTMLInputElement>("#settings-habit");
  const askUnsureEl = host.root.querySelector<HTMLInputElement>("#settings-ask-when-unsure");
  const haUrl = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
  const haToken = host.root.querySelector<HTMLInputElement>("#settings-ha-token");

  const prevHaScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  // Provider config comparison for the in-flight AI invalidation (P5a-W #3).
  const prevAssistantBaseURL = host.settings.assistantBaseURL;
  const prevAssistantModel = host.settings.assistantModel;
  const prevOpenRouterApiKey = host.settings.openRouterApiKey;
  const prevAssistantKeyEndpoint = host.settings.assistantKeyEndpoint;
  const prevAssistantCustomKeyEndpoint = host.settings.assistantCustomKeyEndpoint;

  // P2c-W: Home Assistant uses one credential slot, so an unfinished removal owns it no matter
  // which endpoint the form is saving. Storing a new token now would be deleted by the retry.
  if (haToken && haToken.value.trim() !== "" && pendingConnectionRemovalScopes("ha").length > 0) {
    host.replyBanner = {
      text: tr3(
        "有一个 Home Assistant 连接还没移除完，请先重试清理再保存连接",
        "有一個 Home Assistant 連線還沒移除完，請先重試清理再儲存連線",
        "A Home Assistant removal is still unfinished; retry the cleanup before saving this connection",
      ),
      source: tr3("连接管理", "連線管理", "Connections"),
      isError: true,
    };
    host.render();
    return;
  }

  if (haUrl) {
    const endpoint = normalizeHaEndpoint(haUrl.value);
    if (endpoint !== host.settings.haBaseURL) {
      switchSource(host, "settings-ha-endpoint-changed");
      host.settings.cachedHAHome = null;
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
      switchSource(host, "settings-ha-token-changed");
      host.settings.cachedHAHome = null;
      if (host.settings.connectionMode === "homeAssistant") {
        host.devices = [];
        host.scenes = [];
        host.environmentReadings = [];
        host.deviceFacets = {};
      }
    }
    host.settings.haToken = token;
  }

  const nextHaScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  const nextHaToken = host.settings.haToken.trim();
  const appHost = host as unknown as MenuMijiaWindowsApp;
  if (prevHaScope && (prevHaScope !== nextHaScope || nextHaToken === "")) {
    clearHaScopeLifecycle(prevHaScope);
    removeDisconnectedHaFromSelection(prevHaScope);
    const maybeConnSession = (host as { connDiagSession?: { pendingHaDisablePreview: unknown; haDisableError: unknown } }).connDiagSession;
    if (maybeConnSession) {
      maybeConnSession.pendingHaDisablePreview = null;
      maybeConnSession.haDisableError = null;
    }
    const fallbackStorage = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
    const scheduledCommandStore =
      (appHost as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore ??
      new ScheduledCommandStore(fallbackStorage);
    revalidateAfterMiAccountReenable({
      context: buildHostCapabilityContext(appHost),
      scheduledCommandStore,
      activeTimerIdentity: scheduledCommandIdentity(host.settings) ?? null,
      ruleStore: new AutomationRuleStore(),
    });
  }

  const isCustomPillActive =
    host.root.querySelector<HTMLSelectElement>("#settings-ai-provider")?.value === "custom";
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

  if (
    host.settings.assistantBaseURL !== prevAssistantBaseURL ||
    host.settings.assistantModel !== prevAssistantModel ||
    host.settings.openRouterApiKey !== prevOpenRouterApiKey ||
    host.settings.assistantKeyEndpoint !== prevAssistantKeyEndpoint ||
    host.settings.assistantCustomKeyEndpoint !== prevAssistantCustomKeyEndpoint
  ) {
    // A provider switch or key change must discard results still in flight (P5a-W #3).
    host.advanceAssistantEpoch?.();
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
  if (host.settings.connectionMode === "homeAssistant" && isHostHaEnabled(appHost)) {
    void host.refreshHADevices();
  }
  closeSettingsSheetImmediate(host);
}

const settingsSaveModeByHost = new WeakMap<SettingsEventsHost, "clean" | "dirty" | "saved">();

export function hasUnsavedSettingsDraft(host: SettingsEventsHost): boolean {
  const root = host.root;
  const haUrl = root.querySelector<HTMLInputElement>("#settings-ha-url");
  if (haUrl && haUrl.value !== host.settings.haBaseURL) return true;
  const haToken = root.querySelector<HTMLInputElement>("#settings-ha-token");
  if (haToken && haToken.value !== host.settings.haToken) return true;
  const baseUrl = root.querySelector<HTMLInputElement>("#settings-base-url");
  if (baseUrl && baseUrl.value !== host.settings.assistantBaseURL) return true;
  const model = root.querySelector<HTMLInputElement>("#settings-model");
  if (model && model.value !== host.settings.assistantModel) return true;
  const apiKey = root.querySelector<HTMLInputElement>("#settings-api-key");
  if (apiKey && apiKey.value !== apiKey.defaultValue) return true;
  const habit = root.querySelector<HTMLInputElement>("#settings-habit");
  if (habit && habit.checked !== host.settings.habitLearningEnabled) return true;
  const habitShare = root.querySelector<HTMLInputElement>("#settings-habit-share");
  if (habitShare && habitShare.checked !== host.settings.habitShareEnabled) return true;
  return false;
}

export function syncSettingsSaveHint(
  host: SettingsEventsHost,
  trigger?: "draft" | "auto-saved" | "reset",
): void {
  const dirty = host.activeSheet === "settings" && hasUnsavedSettingsDraft(host);
  if (trigger === "reset" || host.activeSheet !== "settings") {
    settingsSaveModeByHost.set(host, "clean");
  } else if (dirty) {
    settingsSaveModeByHost.set(host, "dirty");
  } else if (trigger === "auto-saved") {
    settingsSaveModeByHost.set(host, "saved");
  } else if (trigger === "draft") {
    settingsSaveModeByHost.set(host, "clean");
  }
  const hint = host.root.querySelector<HTMLElement>(".cc-settings-save-hint");
  if (!hint) return;
  const mode = dirty ? "dirty" : (settingsSaveModeByHost.get(host) ?? "clean");
  hint.dataset.saveState = mode;
  hint.textContent =
    mode === "dirty"
      ? trText("有未保存文本", "Unsaved text")
      : mode === "saved"
        ? trText("已自动保存", "Auto-saved")
        : trText("开关已即时生效", "Toggles auto-save");
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
    cancelSettingsHaDiscovery(session, true);
    clearSettingsHighlight(host.root);
  } else if (!session.launchAtLoginSynced) {
    session.launchAtLoginSynced = true;
    void syncLaunchAtLoginFromSystem(host);
  }

  syncSettingsSaveHint(host);
  // A closed sheet ends the device-type draft (CODING_STANDARDS §13): reopening Settings starts from
  // the stored selection, not from an abandoned preview.
  if (host.activeSheet === "none") clearDeviceTypeSelectionSession(host);

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
    bindAutomationSettingsEvents(host);
    return;
  }

  host.root.querySelectorAll<HTMLElement>("[data-panel-theme]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const raw = btn.dataset.panelTheme;
      syncSettingsSaveHint(host, "auto-saved");
      if (typeof host.setPanelTheme === "function") {
        host.setPanelTheme(raw);
      } else {
        const next = normalizePanelTheme(raw);
        host.settings.panelTheme = next;
        host.root.dataset.panelTheme = next;
        host.saveSettings();
        host.render();
      }
      syncSettingsSaveHint(host, "auto-saved");
    });
  });

  host.root.querySelectorAll<HTMLInputElement>("[data-alloff-device]").forEach((box) => {
    box.addEventListener("change", () => {
      const id = box.dataset.alloffDevice ?? "";
      const device = host.devices.find((d) => d.id === id);
      if (!device || device.kind.kind === "cover") return;
      if (box.checked === joinsAllOffByDefault(device)) {
        delete host.settings.allOffOverrides[id];
      } else {
        host.settings.allOffOverrides[id] = box.checked;
      }
      syncSettingsSaveHint(host, "auto-saved");
      host.saveSettings();
      host.render();
    });
  });

  host.root.querySelector("#btn-revoke-cloud")?.addEventListener("click", () => {
    host.settings.cloudConsentEndpoints = [];
    syncSettingsSaveHint(host, "auto-saved");
    host.saveSettings();
    host.render();
  });

  host.root.querySelectorAll<HTMLSelectElement>("[data-mi-region]").forEach((select) => {
    select.addEventListener("change", () => {
      host.settings.miCloudRegion = normalizeMiCloudRegion(select.value);
      syncSettingsSaveHint(host, "auto-saved");
      host.saveSettings();
      host.render();
    });
  });

  host.root.querySelector<HTMLInputElement>("#settings-auto-update")?.addEventListener("change", (event) => {
    host.settings.autoCheckUpdates = (event.target as HTMLInputElement).checked;
    syncSettingsSaveHint(host, "auto-saved");
    host.saveSettings();
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-launch-at-login")?.addEventListener("change", (event) => {
    const enabled = (event.target as HTMLInputElement).checked;
    host.settings.launchAtLogin = enabled;
    syncSettingsSaveHint(host, "auto-saved");
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
    syncSettingsSaveHint(host, "auto-saved");
    host.saveSettings();
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-raycast-integration")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    syncSettingsSaveHint(host, "auto-saved");
    void setRaycastIntegrationEnabled(host as unknown as MenuMijiaWindowsApp, checked);
    syncSettingsSaveHint(host, "auto-saved");
  });

  const companionHost = host as unknown as MenuMijiaWindowsApp;
  host.root.querySelector<HTMLButtonElement>("#btn-companion-copy-config")?.addEventListener("click", () => {
    void copyCompanionConfig(companionHost).then((copied) => {
      setCompanionNotice(
        companionHost,
        [
          copied
            ? tr3(
                "已复制 MCP 配置（不含令牌）。把 args 里的路径换成你电脑上 scripts\\mijia-mcp 的位置，再粘贴到 Claude、Cursor 等工具的配置里。",
                "已複製 MCP 設定（不含權杖）。把 args 裡的路徑換成你電腦上 scripts\\mijia-mcp 的位置，再貼到 Claude、Cursor 等工具的設定裡。",
                "Copied the MCP config (no token). Point args at scripts\\mijia-mcp on this PC, then paste it into Claude, Cursor or a similar tool.",
              )
            : tr3("无法写入剪贴板，请稍后重试。", "無法寫入剪貼簿，請稍後重試。", "Could not write to the clipboard; try again."),
        ],
        !copied,
      );
      host.render();
    });
  });
  host.root.querySelector<HTMLButtonElement>("#btn-companion-detect")?.addEventListener("click", (event) => {
    const button = event.currentTarget as HTMLButtonElement;
    button.disabled = true;
    void detectCompanionIntegration(companionHost).finally(() => host.render());
  });
  host.root.querySelector<HTMLButtonElement>("#btn-companion-disconnect")?.addEventListener("click", () => {
    syncSettingsSaveHint(host, "auto-saved");
    void setRaycastIntegrationEnabled(companionHost, false, { announceDisconnect: true });
  });

  host.root.querySelector<HTMLInputElement>("#settings-allow-direct-url")?.addEventListener("change", (event) => {
    host.settings.allowDirectURLControl = (event.target as HTMLInputElement).checked;
    syncSettingsSaveHint(host, "auto-saved");
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
        syncSettingsSaveHint(host, "auto-saved");
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
    syncSettingsSaveHint(host, "auto-saved");
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

  // A release notice lives on the general tab when one is waiting, otherwise on the about tab.
  host.root.querySelector("#btn-footer-update")?.addEventListener("click", () => {
    host.openSettingsSheet(host.availableUpdate ? "general" : "about");
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

  host.root.querySelector("#btn-about-open-update-general")?.addEventListener("click", () => {
    commitAnchorJump("softwareUpdate");
  });
  host.root.querySelector("#btn-about-jump-scanner")?.addEventListener("click", () => {
    commitAnchorJump("scanUnsupportedDevices");
  });
  host.root.querySelector("#btn-about-jump-diagnostics")?.addEventListener("click", () => {
    commitAnchorJump("copyDiagnostics");
  });
  host.root.querySelector("#btn-about-report-problem")?.addEventListener("click", () => {
    // The settings host is the app object, which is also the diagnostics host (#29).
    void reportProblemOnHost(host as unknown as ConnectionsAndDiagHost);
  });

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
      const rawTab = btn.dataset.settingsTab;
      if (
        rawTab !== "general" &&
        rawTab !== "connection" &&
        rawTab !== "assistant" &&
        rawTab !== "safety" &&
        rawTab !== "about" &&
        rawTab !== "system"
      ) {
        return;
      }
      const tab = normalizeSettingsTab(rawTab);
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
    requestCloseSettingsSheet(host);
  });

  host.root.querySelector("#btn-cancel-close-settings")?.addEventListener("click", () => {
    keepEditingSettings(host);
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
      switchSource(host, "settings-connection-mode");
      host.environmentReadings = [];
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.deviceFacets = {};
      host.clearPendingHighRisk();
      invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
      host.replyBanner = null;
      host.settings.connectionMode = mode;
      if (mode !== "xiaomiCloud") host.cloudValuesStale = false;
      // Leaving Mi behind must also drop the alert-only devices and hidden index entries it left in
      // the panel; the refresh paths only rewrite them while a Mi source is still selected (P3a-W).
      if (mode !== "xiaomiCloud" && !isDualSourceEnabled(host)) applyMiotTypePruneSnapshot(host, null);
      // Symmetrically, the Home Assistant alert-only cards and hidden entries belong to the endpoint
      // this switch is leaving (P3b-W).
      if (mode !== "homeAssistant" && !isDualSourceEnabled(host)) applyHaTypePruneSnapshot(host, null);
      host.selectRoom(null);
      if (mode === "demo") {
        host.devices = host.demoDevicesForEnabledTypes?.() ?? demoDevices();
        host.scenes = demoScenes();
      } else if (mode === "xiaomiCloud") {
        host.devices = structuredClone(host.settings.cachedXiaomiDevices);
        host.scenes = [];
        if (host.settings.miSession) {
          void host.refreshDevices(false);
        }
      } else if (mode === "homeAssistant") {
        const inspectable = host as unknown as MenuMijiaWindowsApp;
        const cache = haCacheIfEnabled(inspectable, { requireIdentityMatch: true });
        host.devices = cache ? structuredClone(cache.home.devices) : [];
        host.scenes = cache ? structuredClone(cache.home.scenes) : [];
        host.environmentReadings = cache ? structuredClone(cache.home.environmentReadings) : [];
        host.deviceFacets = cache ? structuredClone(cache.home.deviceFacets ?? {}) : {};
        if (isHostHaEnabled(inspectable) && host.settings.haBaseURL && host.settings.haToken) {
          void host.refreshHADevices(false);
        }
      }
      syncSettingsSaveHint(host, "auto-saved");
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

  const providerSelect = host.root.querySelector<HTMLSelectElement>("#settings-ai-provider");
  providerSelect?.addEventListener("change", () => {
    const presetId = providerSelect.value;
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
      // Custom needs 服务地址 and 模型, which live under 高级.
      const advanced = host.root.querySelector<HTMLDetailsElement>('details[data-conn-section="assistantAdvanced"]');
      if (advanced) advanced.open = true;
    } else {
      if (baseEl) baseEl.value = preset.defaultBaseURL;
      if (modelEl) modelEl.value = preset.defaultModel;
      if (apiKeyEl) {
        apiKeyEl.placeholder = preset.keyPlaceholder;
        host.syncKeyFieldWithEndpoint(apiKeyEl, preset.defaultBaseURL);
      }
    }

    syncSettingsSaveHint(host, "draft");
  });

  const removeProviderBtn = host.root.querySelector<HTMLButtonElement>("#btn-remove-ai-provider");
  if (removeProviderBtn) {
    let armed = false;
    let disarmTimer: number | undefined;
    removeProviderBtn.addEventListener("click", () => {
      if (!armed) {
        armed = true;
        removeProviderBtn.textContent = t("再点一次确认移除");
        clearTimeout(disarmTimer);
        disarmTimer = window.setTimeout(() => {
          armed = false;
          disarmTimer = undefined;
          if (removeProviderBtn.isConnected) removeProviderBtn.textContent = t("移除此服务商");
        }, 4000);
        return;
      }
      clearTimeout(disarmTimer);
      disarmTimer = undefined;
      armed = false;
      removeProviderBtn.textContent = t("移除此服务商");
      void removeActiveAssistantProvider(host);
    });
  }

  host.root.querySelector<HTMLInputElement>("#settings-base-url")?.addEventListener("input", (event) => {
    const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
    const target = event.target as HTMLInputElement;
    const inferred = inferAssistantPreset(target.value);
    const providerEl = host.root.querySelector<HTMLSelectElement>("#settings-ai-provider");
    if (providerEl) providerEl.value = inferred.id;
    if (apiKeyEl) {
      apiKeyEl.placeholder = inferred.keyPlaceholder;
      host.syncKeyFieldWithEndpoint(apiKeyEl, target.value);
    }
    syncSettingsSaveHint(host, "draft");
  });

  for (const selector of ["#settings-ha-url", "#settings-ha-token", "#settings-model", "#settings-api-key"]) {
    host.root.querySelector<HTMLInputElement>(selector)?.addEventListener("input", () => {
      syncSettingsSaveHint(host, "draft");
    });
  }
  host.root.querySelector<HTMLInputElement>("#settings-habit")?.addEventListener("change", () => {
    syncSettingsSaveHint(host, "draft");
  });

  host.root.querySelector<HTMLInputElement>("#settings-ask-when-unsure")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    writeAskWhenUnsure(host.settings, checked);
    syncSettingsSaveHint(host, "auto-saved");
    host.saveSettings();
  });

  host.root.querySelector<HTMLInputElement>("#settings-ai-enabled")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    if (isAiAssistantEnabled(host.settings) === checked) return;
    host.settings.aiAssistantEnabled = checked;
    host.saveSettings();
    // Flipping the switch mid-request must discard the in-flight result (P5a-W #3).
    host.advanceAssistantEpoch?.();
    syncSettingsSaveHint(host, "auto-saved");
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-proactive-enabled")?.addEventListener("change", (event) => {
    const checked = (event.target as HTMLInputElement).checked;
    if (isProactiveSuggestionsEnabled(host.settings) === checked) return;
    host.settings.proactiveSuggestionsEnabled = checked;
    host.saveSettings();
    // Closing 主动建议 drops a suggestion run that is still in flight (P5b-W); switching it back
    // on lets the next shared tick start a fresh one. Commands and timers are not affected.
    if (!checked) host.advanceProactiveEpoch?.();
    syncSettingsSaveHint(host, "auto-saved");
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-event-automation-enabled")?.addEventListener("change", (event) => {
    if (!isFullPanelHost(host)) return;
    const toggle = event.target as HTMLInputElement;
    if (host.isStandaloneSettingsWindow) {
      host.settings.eventAutomationEnabled = toggle.checked;
      host.saveSettings();
      syncSettingsSaveHint(host, "auto-saved");
      host.render();
      return;
    }
    if (!setEventAutomationRunning(host, toggle.checked)) {
      toggle.checked = false;
      host.replyBanner = {
        text: tr3("无法保存暂停的规则，自动化仍处于关闭状态", "無法儲存暫停的規則，自動化仍處於關閉狀態", "Could not save paused rules. Automation is still off."),
        source: t("控制失败"),
        isError: true,
      };
      host.render();
      return;
    }
    syncAutomationLifecycle(host);
    host.saveSettings();
    syncSettingsSaveHint(host, "auto-saved");
    host.render();
  });

  host.root.querySelector<HTMLInputElement>("#settings-scheduled-commands-enabled")?.addEventListener("change", (event) => {
    if (!isFullPanelHost(host)) return;
    const toggle = event.target as HTMLInputElement;
    if (host.isStandaloneSettingsWindow) {
      host.settings.scheduledCommandsEnabled = toggle.checked;
      host.saveSettings();
      syncSettingsSaveHint(host, "auto-saved");
      host.render();
      return;
    }
    if (!setScheduledCommandsRunning(host, toggle.checked)) {
      // The paused entries could not be written, so the switch stays on: a timer that is still
      // waiting must not look parked while it can fire.
      toggle.checked = true;
      host.replyBanner = {
        text: t("无法保存暂停的定时，定时任务仍处于开启状态"),
        source: t("控制失败"),
        isError: true,
      };
      host.render();
      return;
    }
    host.saveSettings();
    syncSettingsSaveHint(host, "auto-saved");
    host.render();
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
    const capturedToken = host.sourceEpoch.capture();
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
        !capturedToken.isCurrent() ||
        currentPreset.id !== preset.id ||
        currentEndpoint !== requestedEndpoint
      ) {
        return;
      }
      const statusNode = host.root.querySelector<HTMLElement>("#settings-env-import-status");
      const currentApiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
      if (hit) {
        if (currentApiKeyEl) currentApiKeyEl.value = hit.apiKey;
        syncSettingsSaveHint(host, "draft");
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
    const aiTestStatusGate = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
    if (!isAiAssistantEnabled(host.settings)) {
      // AI off (P5a-W): the probe is an AI request too, so it must not send.
      const offText = tr3(
        "AI 一句话控制已关闭，测试连接不可用",
        "AI 一句話控制已關閉，測試連線不可用",
        "AI command control is off; the connection check is unavailable",
      );
      session.aiTestStatus = { text: offText, state: "error" };
      if (aiTestStatusGate) {
        aiTestStatusGate.textContent = offText;
        aiTestStatusGate.dataset.testState = "error";
        aiTestStatusGate.style.color = "#e67e22";
      }
      return;
    }
    const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
    const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
    const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
    const baseURL = baseEl ? baseEl.value : host.settings.assistantBaseURL;
    const model = modelEl ? modelEl.value : host.settings.assistantModel;
    const apiKey = apiKeyEl ? apiKeyEl.value : storedKeyForURL(host, baseURL);
    const savedAssistantUrl = host.settings.assistantBaseURL;
    const savedHaUrl = host.settings.haBaseURL;
    if (baseURL.trim() !== savedAssistantUrl.trim()) {
      (host as { lastSubmittedEndpoints?: string }).lastSubmittedEndpoints = "";
    }

    const testingText = tr3("正在测试连接…", "正在測試連線…", "Testing connection…");
    session.aiTestStatus = { text: testingText, state: "testing" };
    aiTestBtn.disabled = true;
    const liveStatusEl = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
    if (liveStatusEl) {
      liveStatusEl.textContent = testingText;
      liveStatusEl.dataset.testState = "testing";
      liveStatusEl.style.color = "";
    }
    // Gate every probe attempt: a disable (or provider change) while the probe runs must
    // stop the initial POST and any in-resolver retry (P5a-W #1/#3). The gate wraps each
    // attempt while the probe keeps its draft-endpoint authorization flow.
    const probeEpoch = host.assistantEpoch;
    const liveProbeTransport = createTransport();
    const probeGate = (request: HttpRequest): Promise<HttpResponse> => {
      if (host.assistantEpoch !== probeEpoch || !isAiAssistantEnabled(host.settings)) {
        return Promise.reject(new Error("assistant request superseded"));
      }
      return liveProbeTransport(request);
    };

    void (async () => {
      const result = await probeAssistantConnection({
        baseURL,
        model,
        apiKey,
        haUrl: savedHaUrl,
        restoreAssistantUrl: savedAssistantUrl,
        restoreHaUrl: savedHaUrl,
        resolveRestoreEndpoints: () => ({
          assistantUrl: host.settings.assistantBaseURL,
          haUrl: host.settings.haBaseURL,
        }),
      }, undefined, probeGate);
      const state = result.ok ? "ok" : "error";
      const message = result.ok || result.message !== "assistant request superseded"
        ? result.message
        : tr3(
            "AI 已关闭或服务商已切换，测试中止",
            "AI 已關閉或服務商已切換，測試中止",
            "AI was disabled or the provider changed; the check was aborted",
          );
      session.aiTestStatus = { text: message, state };
      const btnNow = host.root.querySelector<HTMLButtonElement>("#btn-test-ai-connection");
      if (btnNow) btnNow.disabled = false;
      const statusNow = host.root.querySelector<HTMLElement>("#settings-ai-test-status");
      if (statusNow) {
        statusNow.textContent = message;
        statusNow.dataset.testState = state;
        statusNow.style.color = result.ok ? "" : "#e67e22";
      }
    })();
  });

  const refreshPreview = () => {
    refreshHabitSharePreview(host);
    syncSettingsSaveHint(host, "draft");
  };
  host.root.querySelector("#settings-habit-share")?.addEventListener("change", refreshPreview);
  host.root.querySelector("#settings-habit-share-sample")?.addEventListener("input", () => {
    refreshHabitSharePreview(host);
  });
  refreshHabitSharePreview(host);
  bindEnergySettingsEvents(host);
  bindAutomationSettingsEvents(host);
  bindConnectionsAndDiagEvents(host);
  bindDeviceTypeSelectionEvents(host);

  syncSettingsHaDiscoveryUi(host, session);

  host.root.querySelector<HTMLButtonElement>("#btn-settings-discover-ha")?.addEventListener("click", () => {
    if (session.haDiscovering) return;
    const gen = ++session.haDiscoverGeneration;
    session.haDiscovering = true;
    session.haDiscoverResults = [];
    session.haDiscoverStatus = { text: t("正在查找…"), isError: false };
    syncSettingsHaDiscoveryUi(host, session);
    const capturedToken = host.sourceEpoch.capture();
    void discoverHomeAssistantOnLan()
      .then((found) => {
        if (
          getSettingsSession(host) !== session ||
          host.activeSheet !== "settings" ||
          session.haDiscoverGeneration !== gen ||
          !capturedToken.isCurrent()
        ) {
          return;
        }
        session.haDiscovering = false;
        const outcome = resolveHaDiscoveryOutcome(found);
        session.haDiscoverResults = outcome.results;
        session.haDiscoverStatus = outcome.status;
        syncSettingsHaDiscoveryUi(host, session);
      })
      .catch(() => {
        if (
          getSettingsSession(host) !== session ||
          host.activeSheet !== "settings" ||
          session.haDiscoverGeneration !== gen ||
          !capturedToken.isCurrent()
        ) {
          return;
        }
        session.haDiscovering = false;
        session.haDiscoverResults = [];
        session.haDiscoverStatus = haDiscoveryFailureStatus();
        syncSettingsHaDiscoveryUi(host, session);
      });
  });

  host.root.querySelector<HTMLElement>("#settings-ha-candidates")?.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    const btn = target?.closest<HTMLButtonElement>("[data-settings-ha-candidate]");
    const pickedUrl = btn?.dataset.settingsHaCandidate?.trim();
    if (!pickedUrl) return;
    const haInput = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
    if (!haInput) return;
    haInput.value = pickedUrl;
    haInput.dispatchEvent(new Event("input", { bubbles: true }));
    session.haDiscoverStatus = { text: t("已填入地址：{url}", { url: pickedUrl }), isError: false };
    syncSettingsHaDiscoveryUi(host, session);
    haInput.focus({ preventScroll: true });
  });

  host.root.querySelector("#btn-save-settings")?.addEventListener("click", () => {
    commitSettingsSave(host);
  });
}

/**
 * Switches the visible Settings panel without a re-render. All four panels stay mounted behind
 * `hidden`, so typed drafts and the scroll offset of the body survive the switch (#78).
 */
export function showSettingsTab(root: HTMLElement, tab: SettingsTab): void {
  const resolvedTab = normalizeSettingsTab(tab);
  root.querySelectorAll<HTMLElement>("[data-settings-tab]").forEach((button) => {
    const active = button.dataset.settingsTab === resolvedTab;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-selected", String(active));
  });
  root.querySelectorAll<HTMLElement>("[data-settings-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.settingsPanel !== resolvedTab;
  });
  const spec = getSettingsTabSpec(resolvedTab);
  const paneIcon = root.querySelector<HTMLElement>("#settings-pane-icon");
  const paneTitle = root.querySelector<HTMLElement>("#settings-pane-title");
  const paneSubtitle = root.querySelector<HTMLElement>("#settings-pane-subtitle");
  if (paneIcon) {
    paneIcon.innerHTML = spec.icon;
    paneIcon.style.setProperty("--tile-bg", spec.color);
  }
  if (paneTitle) paneTitle.textContent = t(spec.title);
  if (paneSubtitle) paneSubtitle.textContent = spec.subtitle();
  const body = root.querySelector<HTMLElement>(".cc-sheet-body");
  if (body) body.scrollTop = 0;
  syncSlidingTabIndicators(root);
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
