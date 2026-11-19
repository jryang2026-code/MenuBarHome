import { AutomationRuleStore } from "../core/automationEngine.js";
import type { CapabilityDeactivationVerdict } from "../core/capabilityReferenceVerdict.js";
import { currentLanguage, resolveLanguage, t, type AppLanguage, type LanguagePreference } from "../core/i18n.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  applyPauseItemsFromVerdict,
  filterEnabledMiAccounts,
  haConnectionScope,
  miAccountScope,
  previewHaConnectionDisable,
  previewMiAccountDisable,
  queueMiAccountReenableFromLogin,
  removeDisconnectedHaFromSelection,
  removeSignedOutMiAccountFromSelection,
  resolveDeviceMiAccountOwner,
  resolveSceneMiAccountOwner,
  revalidateAfterMiAccountReenable,
  snapshotDisabledHaDevice,
  snapshotDisabledHaScene,
  snapshotDisabledMiDevice,
  snapshotDisabledMiScene,
  writeMiAccountSelectionMutation,
  type HostCapabilityContextInput,
} from "../core/miAccountControl.js";
import {
  abandonHungHaScopeInFlight,
  beginHaScopeDisable,
  clearHaScopeLifecycle,
  getHaScopeLifecyclePhase,
  isHaNativeCancelReady,
  isHaScopeDisabledInStorage,
  isHaScopeStopTimedOut,
  requestHaScopeEnableAfterDrain,
} from "../core/haTransportGate.js";
import { MI_CLOUD_REGIONS, MiAccountLogin, maskedMiUserId, miCloudRegionLabel, normalizeMiCloudRegion, type HttpTransport, type MiSession, type MiotSpecResolver, type QRLoginTicket } from "../core/miCloudClient.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { CredentialVault, credentialsFromSettings, secureStoreDelete, sessionWithoutPassToken } from "../core/secureStore.js";
import { MiAccountScope, MiAccountsStore, clearAccountRateLimitBackoff, formatAccountTokenNotice, getAccountTokenStatus, hasCorruptMiAccountIndex, hasSecondaryMiAccountsInIndex, makeMiAccount, mergeMiAccountSnapshots, miAccountId, type MiAccount, type MiAccountTokenStatus } from "../core/miAccountsStore.js";
import { cancelDelayedReadBack, type OptimisticLockHost } from "../core/optimisticLock.js";
import { clearCachedXiaomiTopology, clearXiaomiRateLimitBackoff, getXiaomiBackoffUntilMs } from "../core/pollingPolicy.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY, ScheduledCommandStore } from "../core/scheduledCommands.js";
import { DiagnosticsReportBuilder, UnsupportedDeviceScanner, appDiagnosticsLog, deriveCameraDiagnostics, derivePollingBackoffDiagnostics, formatSpecSummaryText, summarizeModelCounts, type ScanUnsupportedOptions, type UnsupportedDevice } from "../core/diagnosticsAndScanner.js";
import type { DeviceMergeRoute, DualSourceCoordinator } from "../core/dualSourceProvider.js";
import { environmentReadingPriority, type EnvironmentReading, type FacetControl, type HomeBackend, type HomeScene, type SmartDevice } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { clearHostActivitiesOnSignOut, isFullPanelHost } from "./activityStackView.js";
import { APP_VERSION, SF_ICONS } from "./appConstants.js";
import type { PendingHighRiskConfirmation, PersistedSettings, ReplyBannerState } from "./appTypes.js";
import { adoptRecoveredPrimarySession, buildHostCapabilityContext, canUseDualSource, collectHostKnownScenes, getHostDualSourceState, getHostHaLifecyclePhase, getHostMiAccountsState, getHostMiAccountsStore, isDualSourceEnabled, isHostHaEnabled, recomputeHostDualSource, resolveHostMiSelectionState, setHostDeviceSourcePin, setHostDualSourceEnabled, setHostMiAccounts, type HostMultiAccountState } from "./cloudRefresh.js";
import { cancelEchoReadBack } from "./commandDispatch.js";
import { applyOrder, type HomeOption, type LayoutPrefs } from "./panelPrefs.js";
import { markTimerSnapshotReady, scheduledCommandIdentity } from "./scheduledCommands.js";
import { switchHome, switchSource, type SourceSwitchHost } from "./sourceSwitch.js";
import { isPlainHttpRemoteEndpoint, type SettingsTab, type SettingsViewContext } from "./settingsViews.js";
import { dismissPendingUrlConfirmation, hasPendingMiVaultDeletion, hasPendingUrlConfirmation, setPendingMiVaultDeletion } from "./speechGuard.js";
import { createTransport, invokeTauriVoid } from "./transport.js";

export const CUSTOM_HOME_TITLE_STORAGE_KEY = "menumijia.windows.customHomeTitle.v1";

type MiRegionCode = ReturnType<typeof normalizeMiCloudRegion>;
type ScannerHAInvoke = NonNullable<ScanUnsupportedOptions["haInvoke"]>;

function activeLanguage(preference?: LanguagePreference): AppLanguage {
  if (preference && preference !== "system") return resolveLanguage(preference, []);
  const cur = currentLanguage();
  if (cur !== "zh-Hans") return cur;
  const navLangs =
    typeof window !== "undefined" && Array.isArray(window.navigator?.languages)
      ? window.navigator.languages
      : [];
  return resolveLanguage(preference ?? cur, navLangs);
}

export function tr3(
  zhHans: string,
  zhHant: string,
  en: string,
  lang: AppLanguage = activeLanguage(),
): string {
  return lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
}

function escapeFallback(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export type ConnectionsDiagAnchorId =
  | "miMultiAccounts"
  | "haDisconnect"
  | "dualSourceFusion"
  | "dashboardTitle"
  | "scanUnsupportedDevices"
  | "copyDiagnostics";

interface ConnectionsDiagSearchAnchorSpec {
  readonly anchor: ConnectionsDiagAnchorId;
  readonly tab: SettingsTab;
  readonly section: readonly [string, string, string];
  readonly title: readonly [string, string, string];
  readonly synonyms: readonly string[];
}

const SEC_CONNECTION: readonly [string, string, string] = ["家居连接", "家居連線", "Connections"];
const SEC_DIAGNOSTICS: readonly [string, string, string] = ["诊断与隐私", "診斷與隱私", "Diagnostics & Privacy"];
const SEC_GENERAL: readonly [string, string, string] = ["常规", "常規", "General"];

export const CONNECTIONS_DIAG_SEARCH_ANCHORS: readonly ConnectionsDiagSearchAnchorSpec[] = [
  {
    anchor: "miMultiAccounts",
    tab: "connection",
    section: SEC_CONNECTION,
    title: ["米家多账号管理", "米家多帳號管理", "Xiaomi Multi-Account"],
    synonyms: [
      "多账号",
      "多帳號",
      "添加账号",
      "添加更多米家账号",
      "新增更多米家帳號",
      "新增帳號",
      "副账号",
      "跨地区",
      "单账号退出",
      "multi account",
      "add account",
      "add more xiaomi accounts",
      "secondary account",
      "sign out",
      "duozhanghao",
    ],
  },
  {
    anchor: "haDisconnect",
    tab: "connection",
    section: SEC_CONNECTION,
    title: ["断开 Home Assistant 连接", "中斷 Home Assistant 連線", "Disconnect Home Assistant"],
    synonyms: [
      "断开连接",
      "中斷連線",
      "清除令牌",
      "回退米家",
      "退出 ha",
      "disconnect",
      "home assistant",
      "clear token",
      "duankai",
    ],
  },
  {
    anchor: "dualSourceFusion",
    tab: "connection",
    section: SEC_CONNECTION,
    title: ["Home Assistant 与米家双源融合", "Home Assistant 與米家雙源融合", "Dual-Source Fusion"],
    synonyms: [
      "双源",
      "雙源",
      "同时连接多个家居平台",
      "同時連接多個家居平台",
      "相同设备自动合并",
      "融合",
      "去重",
      "并行",
      "锁源",
      "数据源锁定",
      "临时兜底",
      "dual source",
      "connect multiple home platforms",
      "merge",
      "deduplicate",
      "fallback",
      "shuangyuan",
    ],
  },
  {
    anchor: "dashboardTitle",
    tab: "general",
    section: SEC_GENERAL,
    title: ["面板标题", "面板標題", "Dashboard Title"],
    synonyms: [
      "标题",
      "標題",
      "家庭名称",
      "自定义标题",
      "顶部标题",
      "别名",
      "dashboard title",
      "custom title",
      "home name",
      "header",
      "biaoti",
    ],
  },
  {
    anchor: "scanUnsupportedDevices",
    tab: "connection",
    section: SEC_DIAGNOSTICS,
    title: ["扫描未能显示的设备", "掃描未能顯示的裝置", "Scan Unsupported Devices"],
    synonyms: [
      "未显示",
      "不支持",
      "未识别",
      "扫描设备",
      "跳过",
      "适配反馈",
      "型号",
      "unsupported",
      "skipped devices",
      "scan",
      "missing device",
      "github issue",
      "saomiao",
    ],
  },
  {
    anchor: "copyDiagnostics",
    tab: "connection",
    section: SEC_DIAGNOSTICS,
    title: ["复制脱敏诊断报告", "複製去識別化診斷報告", "Copy Diagnostics Report"],
    synonyms: [
      "诊断",
      "診斷",
      "脱敏",
      "报告",
      "日志",
      "排障",
      "复制诊断",
      "markdown",
      "diagnostics",
      "report",
      "redact",
      "privacy",
      "debug",
      "zhenduan",
    ],
  },
];

type ConnDiagModalSection = "accounts" | "title" | "scanner" | "diagnostics";

interface AddAccountQrState {
  open: boolean;
  phase: "idle" | "loading" | "waiting" | "failed";
  region: MiRegionCode;
  ticket: QRLoginTicket | null;
  statusText: string;
  generation: number;
}

export interface HostConnDiagSession {
  readonly scanner: UnsupportedDeviceScanner;
  lastContextKey: string | null;
  hydratedVaultOnce: boolean;
  hydratingVault: boolean;
  modalSection: ConnDiagModalSection | null;
  titleDraft: string | null;
  diagMarkdownPreview: string | null;
  diagCopied: boolean;
  haScannerInvokeOverride: ScannerHAInvoke | null;
  readonly signingOutAccountIds: Set<string>;
  signOutChain: Promise<boolean>;
  readonly addQr: AddAccountQrState;
  pendingDisablePreview: {
    readonly accountId: string;
    readonly verdict: CapabilityDeactivationVerdict;
    readonly generation: number;
  } | null;
  disableErrorByAccountId: Record<string, string>;
  pendingHaDisablePreview: {
    readonly scope: string;
    readonly verdict: CapabilityDeactivationVerdict;
    readonly generation: number;
  } | null;
  haDisableError: string | null;
}

export interface ConnectionsAndDiagHost extends SourceSwitchHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  devices: SmartDevice[];
  scenes: HomeScene[];
  environmentReadings: EnvironmentReading[];
  homes: HomeOption[];
  readonly layout: LayoutPrefs;
  activeSheet: "none" | "onboarding" | "settings";
  settingsTab: SettingsTab;
  assistantKeysByPreset: Record<string, string>;
  cloudValuesStale: boolean;
  deviceFacets: Readonly<Record<string, readonly FacetControl[]>>;
  /** A high-risk write armed by its first tap; a backend switch disarms it. */
  pendingHighRisk: PendingHighRiskConfirmation | null;
  groupOwnerByMemberDid: Map<string, string>;
  replyBanner: ReplyBannerState | null;
  selectRoom(roomId: string | null, roomName?: string): void;
  refreshDevices(silent?: boolean): Promise<void>;
  refreshHADevices(silent?: boolean): Promise<void>;
  render(): void;
  saveSettings(force?: boolean): void;
  shouldKeepPopoverPinned(): boolean;
  escapeHtml?(value: string): string;
  readonly cameraLive?: {
    readonly activeLiveCameraId: string | null;
    readonly liveCameraKeepAliveTimer: number | null;
    closeCameraLiveView(): void;
    closeXiaomiCameraLiveView?(accountId?: string): void;
    activeLiveCameraUsesXiaomiCloud?(accountId?: string): boolean;
    closeHomeAssistantCameraLiveView?(): boolean;
    activeLiveCameraUsesHomeAssistant?(): boolean;
    retargetActiveLiveCamera?(deviceId: string): boolean;
    discardRetainedCloudSessions?(): void;
  };
  readonly credentialVault?: CredentialVault;
  readonly transport?: HttpTransport;
  readonly specResolver?: MiotSpecResolver;
  miSessionExpired?: boolean;
  homeTitle?: string;
  isHomeMenuOpen?: boolean;
  ctxMenu?: unknown;
  prompt?: unknown;
  expandedDeviceId?: string | null;
  waitingDeviceIds?: Set<string>;
  miAccountsStore?: MiAccountsStore | null;
  miAccountsOverride?: readonly MiAccount[] | null;
  dualSourceEnabledOverride?: boolean | null;
  haDisableUiEnabled?: boolean;
  multiAccountState?: HostMultiAccountState | null;
  dualSourceCoordinator?: DualSourceCoordinator | null;
  connDiagSession?: HostConnDiagSession;
}

export function isHostHaDisableUiEnabled(host?: ConnectionsAndDiagHost): boolean {
  return host?.haDisableUiEnabled !== undefined ? host.haDisableUiEnabled : isHaNativeCancelReady();
}

type ConnectionsAndDiagViewContext =
  | SettingsViewContext
  | {
      readonly settings: PersistedSettings;
      readonly devices: readonly SmartDevice[];
      readonly host?: ConnectionsAndDiagHost;
      escapeHtml?(value: string): string;
    };

export function createDefaultHostConnDiagSession(region?: string): HostConnDiagSession {
  return {
    scanner: new UnsupportedDeviceScanner(),
    lastContextKey: null,
    hydratedVaultOnce: false,
    hydratingVault: false,
    modalSection: null,
    titleDraft: null,
    diagMarkdownPreview: null,
    diagCopied: false,
    haScannerInvokeOverride: null,
    signingOutAccountIds: new Set<string>(),
    signOutChain: Promise.resolve(false),
    addQr: {
      open: false,
      phase: "idle",
      region: normalizeMiCloudRegion(region),
      ticket: null,
      statusText: "",
      generation: 0,
    },
    pendingDisablePreview: null,
    disableErrorByAccountId: {},
    pendingHaDisablePreview: null,
    haDisableError: null,
  };
}

function getHostConnDiagSession(host: ConnectionsAndDiagHost): HostConnDiagSession {
  if (!host.connDiagSession) {
    host.connDiagSession = createDefaultHostConnDiagSession(host.settings.miCloudRegion);
  }
  return host.connDiagSession;
}

function isHostAttached(host: ConnectionsAndDiagHost): boolean {
  return typeof document !== "undefined" && Boolean(host.root?.isConnected);
}

export function getHostUnsupportedScanner(host: ConnectionsAndDiagHost): UnsupportedDeviceScanner {
  return getHostConnDiagSession(host).scanner;
}

function resetHostUnsupportedScanner(host: ConnectionsAndDiagHost): void {
  const session = getHostConnDiagSession(host);
  session.scanner.reset();
  session.diagMarkdownPreview = null;
  session.diagCopied = false;
}

export function readCustomHomeTitle(settings: PersistedSettings): string {
  if (typeof settings.customHomeTitle === "string") return settings.customHomeTitle.trim();
  try {
    if (typeof localStorage !== "undefined") {
      return localStorage.getItem(CUSTOM_HOME_TITLE_STORAGE_KEY)?.trim() ?? "";
    }
  } catch {
  }
  return "";
}

function writeCustomHomeTitle(host: ConnectionsAndDiagHost, rawTitle: string): string {
  const normalized = rawTitle.trim();
  host.settings.customHomeTitle = normalized;
  getHostConnDiagSession(host).titleDraft = null;
  try {
    if (typeof localStorage !== "undefined") {
      if (normalized !== "") localStorage.setItem(CUSTOM_HOME_TITLE_STORAGE_KEY, normalized);
      else localStorage.removeItem(CUSTOM_HOME_TITLE_STORAGE_KEY);
    }
  } catch {
  }
  host.saveSettings();
  // The title is applied, so the render must not capture the typed text as an unsaved draft.
  const titleInput = host.root.querySelector<HTMLInputElement>("#settings-custom-home-title");
  if (titleInput) titleInput.value = titleInput.defaultValue;
  host.render();
  return normalized;
}

function defaultPanelHomeTitle(host: ConnectionsAndDiagHost): string {
  if (typeof host.homeTitle === "string" && host.homeTitle.trim() !== "") return host.homeTitle;
  const selected = host.homes.find((item) => item.id === host.settings.selectedHomeId);
  const lang = activeLanguage(host.settings.interfaceLanguage);
  if (selected) return selected.name;
  return host.homes.length > 1
    ? tr3("全部家庭", "全部家庭", "All Homes", lang)
    : tr3("我的米家", "我的米家", "My Home", lang);
}

export function effectivePanelHomeTitle(host: ConnectionsAndDiagHost): string {
  const custom = readCustomHomeTitle(host.settings);
  return custom !== "" ? custom : defaultPanelHomeTitle(host);
}

export function resolveHostMiAccounts(host: ConnectionsAndDiagHost): MiAccount[] {
  const store = getHostMiAccountsStore(host);
  const storeAccounts = store.getAccounts();
  const pendingDelete = hasPendingMiVaultDeletion();
  if (pendingDelete || (!host.settings.miSession && !hasSecondaryMiAccountsInIndex())) {
    setHostMiAccounts(host, null);
    if (!pendingDelete && storeAccounts.length > 0) {
      void store.load()
        .then(async (loaded) => {
          await adoptRecoveredPrimarySession(host, store, loaded);
        })
        .catch(() => {});
    }
    return [];
  }
  const multiStateAccounts = getHostMiAccountsState(host)?.accounts ?? [];
  const baseList = storeAccounts.length > 0 ? [...storeAccounts] : [...multiStateAccounts];
  if (host.settings.miSession) {
    const primaryAcc = makeMiAccount(host.settings.miSession);
    const existingIdx = baseList.findIndex((item) => item.id === primaryAcc.id);
    if (existingIdx >= 0) baseList[existingIdx] = { ...baseList[existingIdx]!, session: primaryAcc.session };
    else baseList.unshift(primaryAcc);
  }
  return baseList;
}

async function ensureHostMiAccountsHydrated(host: ConnectionsAndDiagHost): Promise<MiAccount[]> {
  const session = getHostConnDiagSession(host);
  const store = getHostMiAccountsStore(host);
  if (store.getAccounts().length > 1) {
    session.hydratedVaultOnce = true;
    return resolveHostMiAccounts(host);
  }
  if (session.hydratingVault) return resolveHostMiAccounts(host);
  session.hydratingVault = true;
  try {
    const beforeIds = resolveHostMiAccounts(host).map((a) => a.id).join(",");
    const beforeReadState = store.getAccountsReadState();
    const loaded = await store.load();
    await adoptRecoveredPrimarySession(host, store, loaded);
    session.hydratedVaultOnce = true;
    if (
      (beforeIds !== loaded.map((a) => a.id).join(",") || beforeReadState !== store.getAccountsReadState()) &&
      isHostAttached(host)
    ) {
      syncConnectionContextWatcher(host);
      host.render();
    }
    return loaded.length > 0 ? loaded : resolveHostMiAccounts(host);
  } finally {
    session.hydratingVault = false;
  }
}

function revalidateHostAfterAccountRemoval(
  host: ConnectionsAndDiagHost,
  remainingAccounts: readonly MiAccount[],
): void {
  const fallbackStorage = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
  const scheduledCommandStore =
    (host as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore ??
    new ScheduledCommandStore(fallbackStorage);
  revalidateAfterMiAccountReenable({
    context: buildHostCapabilityContext(host, remainingAccounts),
    scheduledCommandStore,
    activeTimerIdentity:
      remainingAccounts.length === 0 && host.settings.connectionMode === "xiaomiCloud"
        ? null
        : scheduledCommandIdentity(host.settings),
    ruleStore: new AutomationRuleStore(),
  });
}

export async function addOrUpdateMiAccountOnHost(
  host: ConnectionsAndDiagHost,
  rawSession: MiSession,
  options: { readonly triggerRefresh?: boolean } = {},
): Promise<MiAccount[]> {
  const store = getHostMiAccountsStore(host);
  const cleanSession = sessionWithoutPassToken(rawSession);

  if (store.getAccounts().length === 0) await store.load();
  if (host.settings.miSession && store.getAccounts().length === 0) {
    await store.upsertAccount(sessionWithoutPassToken(host.settings.miSession));
  }
  const result = await store.upsertAccount(cleanSession);
  setHostMiAccounts(host, null);
  const fallbackStorage = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
  const scheduledCommandStore =
    (host as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore ??
    new ScheduledCommandStore(fallbackStorage);
  queueMiAccountReenableFromLogin(miAccountId(cleanSession), {
    scheduledCommandStore,
    ruleStore: new AutomationRuleStore(),
  });
  getHostConnDiagSession(host).pendingDisablePreview = null;
  delete getHostConnDiagSession(host).disableErrorByAccountId[miAccountId(cleanSession)];

  setPendingMiVaultDeletion(false);
  switchSource(host, "mi-account-added");
  if (result.primarySessionKnown) {
    const primary = result.accounts[0]?.session ?? cleanSession;
    host.settings.miSession = primary;
    host.settings.miCloudRegion = normalizeMiCloudRegion(primary.region);
  }
  host.miSessionExpired = false;
  if (host.settings.connectionMode === "demo") {
    host.settings.connectionMode = "xiaomiCloud";
    host.devices = [];
    host.scenes = [];
  }
  host.settings.hasCompletedOnboarding = true;
  resetHostUnsupportedScanner(host);
  host.saveSettings();

  const lang = activeLanguage(host.settings.interfaceLanguage);
  const masked = maskedMiUserId(cleanSession.userId);
  const n = result.accounts.length;
  host.replyBanner = {
    text: tr3(
      `已连接米家账号 ${masked}（共 ${n} 个账号）`,
      `已連接米家帳號 ${masked}（共 ${n} 個帳號）`,
      `Connected Xiaomi account ${masked} (${n} signed in)`,
      lang,
    ),
    source: tr3("多账号管理", "多帳號管理", "Accounts", lang),
  };
  host.render();
  if (options.triggerRefresh !== false) await host.refreshDevices(false);
  return result.accounts;
}

export type SetMiAccountEnabledOutcome =
  | { readonly status: "applied" }
  | { readonly status: "requiresPauseConfirmation"; readonly verdict: CapabilityDeactivationVerdict }
  | { readonly status: "blocked"; readonly verdict: CapabilityDeactivationVerdict | null };

function computeDisablePreviewGeneration(
  context: HostCapabilityContextInput,
  scheduledCommandStore: ScheduledCommandStore,
  ruleStore: AutomationRuleStore,
): number {
  const parts: string[] = [
    [...context.state.selection.enabledConnectionScopes].sort().join(","),
    [...context.state.pausedQuickActionIds].sort().join(","),
    context.devices.map((d) => `${d.id}:${d.name}:${d.sourceBackend ?? ""}`).join("|"),
    context.scenes.map((s) => `${s.id}:${s.name}:${s.accountId ?? ""}:${s.sourceBackend ?? ""}`).join("|"),
  ];
  for (const [identity, queue] of [...scheduledCommandStore.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    if (
      queue.scheduledCommands.length === 0 &&
      queue.missedScheduledCommands.length === 0 &&
      (queue.pausedScheduledCommands?.length ?? 0) === 0
    ) {
      continue;
    }
    const ser = (list: readonly { readonly id: string; readonly command: string; readonly intents?: readonly { readonly targetId: string }[]; readonly sourceScopes?: readonly string[] }[]) =>
      list.map((i) => `${i.id}:${i.command}:${(i.intents ?? []).map((t) => t.targetId).join(",")}:${(i.sourceScopes ?? []).join(",")}`).join(";");
    const serPaused = (queue.pausedScheduledCommands ?? []).map((p) => `${p.command.id}:${p.originalPartition}:${p.sourceScopes.join(",")}:${p.pausedCapabilities.join(",")}`).join(";");
    parts.push(`${identity}#${ser(queue.scheduledCommands)}#${ser(queue.missedScheduledCommands)}#${serPaused}`);
  }
  for (const r of ruleStore.load()) {
    parts.push(`rule:${r.id}:${r.isEnabled}:${r.trigger}:${JSON.stringify(r.action)}`);
  }
  const raw = parts.join("\n");
  let hash = 0x811c9dc5;
  for (let i = 0; i < raw.length; i += 1) {
    hash ^= raw.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

function formatDisableBlockedMessage(verdict: CapabilityDeactivationVerdict | null, lang: AppLanguage): string {
  if (verdict?.blockingReasons.some((r) => r.kind === "unresolvedReferenceOwnership")) {
    return tr3(
      "部分定时或自动化功能关联的设备归属尚未确认，暂无法停用此连接。请先刷新同步设备，或取消相关定时与自动化后再试。",
      "部分定時或自動化功能關聯的裝置歸屬尚未確認，暫無法停用此連線。請先重新整理同步裝置，或取消相關定時與自動化後再試。",
      "Some timers or automations reference devices whose connection is not yet confirmed. Refresh to sync devices or update those items, then try again.",
      lang,
    );
  }
  if (verdict?.blockingReasons.some((r) => r.kind === "stalePreviewGeneration")) {
    return tr3(
      "待暂停的定时或自动化功能刚刚发生变化，请重新确认下方预览后再停用此连接。",
      "待暫停的定時或自動化功能剛剛發生變化，請重新確認下方預覽後再停用此連線。",
      "Affected timers or automations changed; please review the updated preview below and confirm again.",
      lang,
    );
  }
  return tr3(
    "本地连接或功能设置暂时无法保存，未停用此连接且未修改定时与自动化。请检查磁盘空间或重启应用后再试。",
    "本地連線或功能設定暫時無法儲存，未停用此連線且未修改定時與自動化。請檢查磁碟空間或重啟應用後再試。",
    "Could not save connection or feature settings; nothing was paused or turned off. Check disk space or restart the app and try again.",
    lang,
  );
}

function formatReenablePersistErrorMessage(lang: AppLanguage): string {
  return tr3(
    "本地连接或功能设置暂时无法保存，未能重新开启此连接。请检查磁盘空间或重启应用后再试。",
    "本地連線或功能設定暫時無法儲存，未能重新開啟此連線。請檢查磁碟空間或重啟應用後再試。",
    "Could not save connection or feature settings; this connection stays turned off. Check disk space or restart the app and try again.",
    lang,
  );
}

function readRawStorageItem(key: string): string | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage.getItem(key) : null;
  } catch {
    return null;
  }
}

function restoreRawStorageItem(key: string, prevValue: string | null): void {
  try {
    if (typeof localStorage !== "undefined") {
      if (prevValue === null) localStorage.removeItem(key);
      else localStorage.setItem(key, prevValue);
    }
  } catch {}
}

export async function setMiAccountEnabledOnHost(
  host: ConnectionsAndDiagHost,
  accountId: string,
  enabled: boolean,
  options: { readonly confirmPause?: boolean; readonly expectedGeneration?: number; readonly currentGeneration?: number; readonly nowMs?: number } = {},
): Promise<SetMiAccountEnabledOutcome> {
  const session = getHostConnDiagSession(host), store = getHostMiAccountsStore(host);
  let allAccounts = resolveHostMiAccounts(host);
  if (!allAccounts.some((acc) => acc.id === accountId) && store.getAccounts().length === 0 && !hasPendingMiVaultDeletion()) {
    await store.load();
    allAccounts = resolveHostMiAccounts(host);
  }
  const fallbackStorage = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
  const scheduledCommandStore = (host as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore ?? new ScheduledCommandStore(fallbackStorage);
  const ruleStore = new AutomationRuleStore();

  if (enabled) {
    session.pendingDisablePreview = null;
    delete session.disableErrorByAccountId[accountId];
    const targetScope = miAccountScope(accountId);
    if (host.settings.connectionMode === "demo") {
      const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
        ...prev,
        disabledAccountIds: prev.disabledAccountIds.filter((id) => miAccountScope(id) !== targetScope),
        pendingRevalidationAccountIds: prev.pendingRevalidationAccountIds.filter((id) => miAccountScope(id) !== targetScope),
        knownDisabledDevices: prev.knownDisabledDevices.filter((d) => miAccountScope(d.accountId) !== targetScope),
        knownDisabledScenes: prev.knownDisabledScenes.filter((s) => miAccountScope(s.accountId) !== targetScope),
      }) });
      if (!wrote) {
        const lang = activeLanguage(host.settings.interfaceLanguage);
        const msg = formatReenablePersistErrorMessage(lang);
        session.disableErrorByAccountId[accountId] = msg;
        host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
        host.render();
        return { status: "blocked", verdict: null };
      }
      resetHostUnsupportedScanner(host);
      revalidateAfterMiAccountReenable({
        context: buildHostCapabilityContext(host, resolveHostMiAccounts(host)), scheduledCommandStore,
        activeTimerIdentity: scheduledCommandIdentity(host.settings), ruleStore,
        ...(options.nowMs !== undefined ? { nowMs: options.nowMs } : {}),
      });
      host.render();
      return { status: "applied" };
    }
    const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
      ...prev,
      disabledAccountIds: prev.disabledAccountIds.filter((id) => miAccountScope(id) !== targetScope),
      pendingRevalidationAccountIds: [...new Set([...prev.pendingRevalidationAccountIds, targetScope])],
    }) });
    if (!wrote) {
      const lang = activeLanguage(host.settings.interfaceLanguage);
      const msg = formatReenablePersistErrorMessage(lang);
      session.disableErrorByAccountId[accountId] = msg;
      host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
      host.render();
      return { status: "blocked", verdict: null };
    }
    resetHostUnsupportedScanner(host);
    if (isDualSourceEnabled(host) || host.settings.connectionMode === "xiaomiCloud") {
      switchHome(host);
      host.render();
      const hostWithReenableTs = host as ConnectionsAndDiagHost & { pendingReenableNowMs?: number };
      if (options.nowMs !== undefined) hostWithReenableTs.pendingReenableNowMs = options.nowMs;
      try {
        await host.refreshDevices(false);
      } finally {
        delete hostWithReenableTs.pendingReenableNowMs;
      }
    }
    host.render();
    return { status: "applied" };
  }

  const context = buildHostCapabilityContext(host, allAccounts);
  if (context.state.disabledAccountIds.has(miAccountScope(accountId))) {
    session.pendingDisablePreview = null;
    delete session.disableErrorByAccountId[accountId];
    host.render();
    return { status: "applied" };
  }
  const currentGen = options.currentGeneration ?? computeDisablePreviewGeneration(context, scheduledCommandStore, ruleStore);
  const expectedGen = options.expectedGeneration !== undefined
    ? options.expectedGeneration
    : options.confirmPause && session.pendingDisablePreview?.accountId === accountId
      ? session.pendingDisablePreview.generation
      : null;
  let verdict = previewMiAccountDisable({
    accountId, context, scheduledCommandStore, activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore, expectedGeneration: expectedGen, currentGeneration: currentGen,
    languagePreference: host.settings.interfaceLanguage,
  });
  if (
    options.confirmPause &&
    options.expectedGeneration === undefined &&
    verdict.blockingReasons.some((r) => r.kind === "stalePreviewGeneration")
  ) {
    const freshVerdict = previewMiAccountDisable({
      accountId, context, scheduledCommandStore, activeTimerIdentity: scheduledCommandIdentity(host.settings),
      ruleStore, currentGeneration: currentGen, languagePreference: host.settings.interfaceLanguage,
    });
    if (freshVerdict.disposition === "requiresPauseConfirmation") {
      session.pendingDisablePreview = { accountId, verdict: freshVerdict, generation: currentGen };
      delete session.disableErrorByAccountId[accountId];
      const lang = activeLanguage(host.settings.interfaceLanguage);
      host.replyBanner = {
        text: formatDisableBlockedMessage(verdict, lang),
        source: tr3("连接管理", "連線管理", "Connections", lang),
        isError: true,
      };
      host.render();
      return { status: "requiresPauseConfirmation", verdict: freshVerdict };
    }
    verdict = freshVerdict;
  }
  if (verdict.disposition === "blocked") {
    session.pendingDisablePreview = null;
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(verdict, lang);
    session.disableErrorByAccountId[accountId] = msg;
    host.replyBanner = {
      text: msg,
      source: tr3("连接管理", "連線管理", "Connections", lang),
      isError: true,
    };
    host.render();
    return { status: "blocked", verdict };
  }
  if (verdict.disposition === "requiresPauseConfirmation" && !options.confirmPause) {
    session.pendingDisablePreview = { accountId, verdict, generation: currentGen };
    delete session.disableErrorByAccountId[accountId];
    host.render();
    return { status: "requiresPauseConfirmation", verdict };
  }

  session.pendingDisablePreview = null;
  const wasDualSource = isDualSourceEnabled(host);
  const isXiaomiSnapshot = wasDualSource || host.settings.connectionMode === "xiaomiCloud";
  const dualRoutes = wasDualSource ? host.dualSourceCoordinator?.getLastMerged()?.routes : undefined;
  const deviceOwners = getHostMiAccountsState(host)?.merged?.deviceOwners;
  const ownerOf = (dev: SmartDevice): string | null => resolveDeviceMiAccountOwner({
    device: dev,
    accounts: allAccounts,
    connectionMode: host.settings.connectionMode,
    dualSourceEnabled: wasDualSource,
    disabledAccountIds: context.state.disabledAccountIds,
    disablingAccountId: accountId,
    ...(deviceOwners ? { deviceOwners } : {}),
    ...(dualRoutes?.[dev.id] ? { dualRoute: dualRoutes[dev.id]! } : {}),
  });
  const cachedOwnerOf = (dev: SmartDevice): string | null => resolveDeviceMiAccountOwner({
    device: dev,
    accounts: allAccounts,
    connectionMode: "xiaomiCloud",
    dualSourceEnabled: false,
    disabledAccountIds: context.state.disabledAccountIds,
    disablingAccountId: accountId,
    ...(deviceOwners ? { deviceOwners } : {}),
  });
  const haActiveForAlternate = isHostHaEnabled(host);
  const hasHaAlternate = (dev: SmartDevice): boolean => {
    if (!haActiveForAlternate) return false;
    const route = dualRoutes?.[dev.id];
    return route ? route.backend === "homeAssistant" || (route.alternateBackend === "homeAssistant" && route.alternateDevice !== null) : wasDualSource && dev.sourceBackend === "homeAssistant";
  };

  const expectedEnabledAfter = allAccounts.filter(
    (acc) => acc.id !== accountId && !context.state.disabledAccountIds.has(miAccountScope(acc.id)),
  );
  const previewNextChildren =
    expectedEnabledAfter.length > 0 && host.multiAccountState
      ? (() => {
          const copy = { ...host.multiAccountState.children };
          delete copy[accountId];
          return copy;
        })()
      : null;
  const previewNextMerged =
    previewNextChildren && expectedEnabledAfter.length > 0
      ? mergeMiAccountSnapshots(expectedEnabledAfter, previewNextChildren)
      : null;
  const survivingSceneIds = previewNextMerged ? new Set(previewNextMerged.home.scenes.map((s) => s.id)) : null;
  const sceneOwnerOf = (sc: HomeScene): string | null =>
    resolveSceneMiAccountOwner({
      scene: sc,
      accounts: allAccounts,
      connectionMode: host.settings.connectionMode,
      dualSourceEnabled: wasDualSource,
      haBaseURL: host.settings.haBaseURL,
      haToken: host.settings.haToken,
    });

  const ownedDevices = isXiaomiSnapshot ? host.devices.filter((d) => ownerOf(d) === accountId) : [];
  const snapshots = isXiaomiSnapshot
    ? ownedDevices
        .filter((d) => !hasHaAlternate(d))
        .map((d) => snapshotDisabledMiDevice(d, accountId, host.deviceFacets[d.id] ?? []))
    : host.settings.cachedXiaomiDevices
        .filter((d) => cachedOwnerOf(d) === accountId)
        .map((d) => snapshotDisabledMiDevice(d, accountId));
  const ownedScenes = isXiaomiSnapshot
    ? collectHostKnownScenes(host).filter((s) => sceneOwnerOf(s) === accountId && !(survivingSceneIds?.has(s.id)))
    : [];
  const sceneSnapshots = ownedScenes.map((s) => snapshotDisabledMiScene(s, accountId));
  const newlyPausedQaIds = verdict.itemsToPause.filter((i) => i.kind === "quickAction").map((i) => i.id);
  const prevRawSelection = readRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
  const prevRawTimers = readRawStorageItem(SCHEDULED_COMMANDS_STORAGE_KEY);
  const prevRawRules = readRawStorageItem(AutomationRuleStore.storageKey);
  const timerSnapshot = scheduledCommandStore.snapshotQueues();
  const prevRules = ruleStore.load();
  const targetScope = miAccountScope(accountId);

  const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
    ...prev,
    disabledAccountIds: [...new Set([...prev.disabledAccountIds, accountId])],
    pendingRevalidationAccountIds: prev.pendingRevalidationAccountIds.filter((id) => miAccountScope(id) !== targetScope),
    pausedQuickActionIds: [...new Set([...prev.pausedQuickActionIds, ...newlyPausedQaIds])],
    knownDisabledDevices: [...prev.knownDisabledDevices.filter((d) => miAccountScope(d.accountId) !== targetScope && !snapshots.some((s) => s.id === d.id)), ...snapshots],
    knownDisabledScenes: [...prev.knownDisabledScenes.filter((s) => miAccountScope(s.accountId) !== targetScope && !sceneSnapshots.some((snap) => snap.id === s.id)), ...sceneSnapshots],
  }) });
  if (!wrote) {
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(null, lang);
    session.disableErrorByAccountId[accountId] = msg;
    host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
    host.render();
    return { status: "blocked", verdict };
  }
  const pauseRes = applyPauseItemsFromVerdict({
    verdict,
    scheduledCommandStore,
    ruleStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    activeConnectionScopes: context.state.selection.enabledConnectionScopes,
  });
  if (!pauseRes.ok) {
    try { scheduledCommandStore.restoreQueues(timerSnapshot); } catch {}
    try { ruleStore.save(prevRules); } catch {}
    restoreRawStorageItem(SCHEDULED_COMMANDS_STORAGE_KEY, prevRawTimers);
    restoreRawStorageItem(AutomationRuleStore.storageKey, prevRawRules);
    restoreRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, prevRawSelection);
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(null, lang);
    session.disableErrorByAccountId[accountId] = msg;
    host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
    host.render();
    return { status: "blocked", verdict };
  }
  delete session.disableErrorByAccountId[accountId];

  const removedIds = new Set(ownedDevices.filter((d) => !hasHaAlternate(d)).map((d) => d.id));
  if (host.cameraLive?.activeLiveCameraId) {
    host.cameraLive.closeXiaomiCameraLiveView?.(accountId);
    const camId = host.cameraLive.activeLiveCameraId;
    if (camId && (removedIds.has(camId) || MiAccountScope.isOwned(camId, accountId))) host.cameraLive.closeCameraLiveView();
  }
  for (const dev of ownedDevices) {
    const rawDid = MiAccountScope.localId(dev.id);
    for (const id of rawDid !== dev.id ? [dev.id, rawDid] : [dev.id]) {
      cancelDelayedReadBack(host as unknown as OptimisticLockHost, id);
      cancelEchoReadBack(host as unknown as MenuMijiaWindowsApp, id);
    }
  }

  clearAccountRateLimitBackoff(accountId);
  const targetAccount = allAccounts.find((acc) => acc.id === accountId);
  const enabledAfter = filterEnabledMiAccounts(allAccounts, resolveHostMiSelectionState(host, allAccounts));
  if (enabledAfter.length === 0 || (host.settings.miSession && miAccountId(host.settings.miSession) === accountId) || (targetAccount && getXiaomiBackoffUntilMs(host, targetAccount.session) !== null)) {
    clearXiaomiRateLimitBackoff(host);
    clearCachedXiaomiTopology(host);
  }
  if (host.settings.selectedHomeId && MiAccountScope.isOwned(host.settings.selectedHomeId, accountId)) {
    host.settings.selectedHomeId = null;
  }

  const nextChildren = previewNextChildren;
  const nextMerged = previewNextMerged;
  const survivingById = nextMerged
    ? new Map(nextMerged.home.devices.map((d) => [d.id, d] as const))
    : undefined;

  const hadTimerSnapshot = Boolean((host as { readonly timerSnapshot?: { readonly identity: string; readonly sourceRevision: number } | null }).timerSnapshot);
  if (isXiaomiSnapshot) {
    switchSource(host, "mi-account-disabled");
    host.clearPendingHighRisk();
  }
  resetHostUnsupportedScanner(host);
  const nextDual = wasDualSource
    ? (host.dualSourceCoordinator?.removeXiaomiAccount(accountId, host.settings.interfaceLanguage, {
        remainingEnabledCount: enabledAfter.length,
        reason: "disabled",
        ...(survivingById ? { survivingDevices: survivingById } : {}),
        ...(nextMerged?.home.deviceFacets ? { survivingDeviceFacets: nextMerged.home.deviceFacets } : {}),
        ...(nextMerged ? { survivingReadings: nextMerged.home.environmentReadings } : {}),
      }) ?? null)
    : null;
  if (isXiaomiSnapshot && host.waitingDeviceIds) {
    for (const id of removedIds) host.waitingDeviceIds.delete(id);
  }

  const removedSceneIds = new Set(ownedScenes.map((s) => s.id));
  if (nextDual) {
    host.homes = applyOrder(host.homes.map((h) => h.id), nextDual.homes);
    host.groupOwnerByMemberDid = new Map(nextDual.lightGroupOwners);
    host.devices = applyOrder(host.devices.map((d) => d.id), nextDual.home.devices);
    host.deviceFacets = nextDual.home.deviceFacets ?? {};
    host.scenes = nextDual.home.scenes.filter((s) => !removedSceneIds.has(s.id));
    const prio = new Map(host.devices.map((d) => [d.id, environmentReadingPriority(d.kind)]));
    host.environmentReadings = applyOrder(host.environmentReadings.map((r) => r.id), nextDual.home.environmentReadings).sort((a, b) => (prio.get(a.id) ?? 0) - (prio.get(b.id) ?? 0));
    reconcileActiveCameraAfterDeviceRestore(host, dualRoutes);
  } else if (enabledAfter.length === 0 && ((!wasDualSource && host.settings.connectionMode === "xiaomiCloud") || (wasDualSource && !haActiveForAlternate))) {
    host.devices = []; host.scenes = []; host.environmentReadings = []; host.homes = [];
    host.groupOwnerByMemberDid = new Map(); host.deviceFacets = {}; host.cloudValuesStale = false; host.selectRoom(null);
  } else if (isXiaomiSnapshot) {
    host.devices = host.devices
      .filter((d) => !removedIds.has(d.id))
      .map((d) => survivingById?.get(d.id) ?? d);
    const survivingReadingById = nextMerged
      ? new Map(nextMerged.home.environmentReadings.map((r) => [r.id, r] as const))
      : null;
    host.environmentReadings = host.environmentReadings
      .filter((r) => !removedIds.has(r.id))
      .map((r) => survivingReadingById?.get(r.id) ?? r);
    const nextFacets = { ...host.deviceFacets };
    for (const id of removedIds) delete nextFacets[id];
    if (nextMerged?.home.deviceFacets && survivingById) {
      for (const id of survivingById.keys()) {
        const updated = nextMerged.home.deviceFacets[id];
        if (updated && updated.length > 0) nextFacets[id] = updated;
      }
    }
    host.deviceFacets = nextFacets;
    if (nextMerged) {
      host.homes = applyOrder(host.homes.map((h) => h.id), nextMerged.homes);
      host.groupOwnerByMemberDid = new Map(nextMerged.lightGroupOwners);
    } else {
      host.homes = host.homes.filter((h) => !MiAccountScope.isOwned(h.id, accountId));
    }
    host.scenes = host.scenes.filter(
      (s) =>
        !removedSceneIds.has(s.id) &&
        s.accountId !== accountId &&
        !MiAccountScope.isOwned(s.id, accountId) &&
        !MiAccountScope.isOwned(s.entityId, accountId),
    );
  }

  if (enabledAfter.length === 0) {
    host.settings.cachedXiaomiDevices = []; host.multiAccountState = null;
  } else {
    host.settings.cachedXiaomiDevices = host.settings.cachedXiaomiDevices
      .filter((d) => survivingById?.has(d.id) || (d.accountId !== accountId && !MiAccountScope.isOwned(d.id, accountId) && !removedIds.has(d.id)))
      .map((d) => survivingById?.get(d.id) ?? d);
    if (nextChildren && nextMerged) {
      host.multiAccountState = { accounts: allAccounts, children: nextChildren, merged: nextMerged };
    }
  }
  const maybeListCut = (host as { readonly listCut?: { readonly kind: string; readonly roomId?: string } }).listCut;
  if (isXiaomiSnapshot && maybeListCut?.kind === "room" && maybeListCut.roomId && MiAccountScope.isOwned(maybeListCut.roomId, accountId)) {
    host.selectRoom(null);
  }
  if (isXiaomiSnapshot && host.expandedDeviceId && (removedIds.has(host.expandedDeviceId) || !host.devices.some((d) => d.id === host.expandedDeviceId))) {
    host.expandedDeviceId = null;
  }
  const hasRemainingActiveSource =
    enabledAfter.length > 0 ||
    (wasDualSource && haActiveForAlternate) ||
    (host.settings.connectionMode === "homeAssistant" && haActiveForAlternate) ||
    host.settings.connectionMode === "demo";
  if (isXiaomiSnapshot && hadTimerSnapshot && hasRemainingActiveSource && "timerSnapshot" in host) {
    markTimerSnapshotReady(host as unknown as MenuMijiaWindowsApp);
  }
  host.saveSettings();
  host.render();
  return { status: "applied" };
}

export type SetHaConnectionEnabledOutcome = SetMiAccountEnabledOutcome;

export function retryTimedOutHaStopOnHost(host: ConnectionsAndDiagHost): void {
  const haScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  if (!haScope) return;
  abandonHungHaScopeInFlight(haScope);
  const session = getHostConnDiagSession(host);
  session.haDisableError = null;
  host.render();
}

export async function setHaConnectionEnabledOnHost(
  host: ConnectionsAndDiagHost,
  enabled: boolean,
  options: { readonly confirmPause?: boolean; readonly expectedGeneration?: number; readonly currentGeneration?: number; readonly nowMs?: number } = {},
): Promise<SetHaConnectionEnabledOutcome> {
  const session = getHostConnDiagSession(host);
  const haScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  if (!haScope) {
    session.pendingHaDisablePreview = null;
    session.haDisableError = null;
    host.render();
    return { status: "applied" };
  }
  const fallbackStorage = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
  const scheduledCommandStore = (host as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore ?? new ScheduledCommandStore(fallbackStorage);
  const ruleStore = new AutomationRuleStore();
  const allAccounts = resolveHostMiAccounts(host);

  if (enabled) {
    session.pendingHaDisablePreview = null;
    session.haDisableError = null;
    if (isHaScopeStopTimedOut(haScope)) {
      abandonHungHaScopeInFlight(haScope);
    }
    const prevRawSelection = readRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
    const handleDrainTimeout = (): SetHaConnectionEnabledOutcome => {
      restoreRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, prevRawSelection);
      const lang = activeLanguage(host.settings.interfaceLanguage);
      const msg = tr3(
        "Home Assistant 仍在等待上一轮请求结束，请点击重试或稍后再启用。",
        "Home Assistant 仍在等待上一輪請求結束，請點擊重試或稍後再啟用。",
        "Home Assistant is still waiting for an in-flight request to finish. Retry stopping or try re-enabling again.",
        lang,
      );
      session.haDisableError = msg;
      host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
      host.render();
      return { status: "blocked", verdict: null };
    };
    if (host.settings.connectionMode === "demo" && !isDualSourceEnabled(host)) {
      const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
        ...prev,
        disabledHaScopes: prev.disabledHaScopes.filter((s) => (haConnectionScope(s) ?? s) !== haScope),
        pendingRevalidationHaScopes: prev.pendingRevalidationHaScopes.filter((s) => (haConnectionScope(s) ?? s) !== haScope),
        knownDisabledHaDevices: prev.knownDisabledHaDevices.filter((d) => d.scope !== haScope),
        knownDisabledHaScenes: prev.knownDisabledHaScenes.filter((s) => s.scope !== haScope),
      }) });
      if (!wrote) {
        const lang = activeLanguage(host.settings.interfaceLanguage);
        const msg = formatReenablePersistErrorMessage(lang);
        session.haDisableError = msg;
        host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
        host.render();
        return { status: "blocked", verdict: null };
      }
      resetHostUnsupportedScanner(host);
      const drainRes = await new Promise<{ readonly ready: boolean; readonly timedOut: boolean }>((resolve) => {
        requestHaScopeEnableAfterDrain(haScope, (ready, meta) => {
          resolve({ ready, timedOut: Boolean(meta?.timedOut) });
        });
      });
      if (drainRes.timedOut) return handleDrainTimeout();
      revalidateAfterMiAccountReenable({
        context: buildHostCapabilityContext(host, resolveHostMiAccounts(host)),
        scheduledCommandStore,
        activeTimerIdentity: scheduledCommandIdentity(host.settings),
        ruleStore,
        ...(options.nowMs !== undefined ? { nowMs: options.nowMs } : {}),
      });
      host.render();
      return { status: "applied" };
    }

    const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
      ...prev,
      disabledHaScopes: prev.disabledHaScopes.filter((s) => (haConnectionScope(s) ?? s) !== haScope),
      pendingRevalidationHaScopes: [...new Set([...prev.pendingRevalidationHaScopes, haScope])],
    }) });
    if (!wrote) {
      const lang = activeLanguage(host.settings.interfaceLanguage);
      const msg = formatReenablePersistErrorMessage(lang);
      session.haDisableError = msg;
      host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
      host.render();
      return { status: "blocked", verdict: null };
    }
    resetHostUnsupportedScanner(host);
    host.render();
    const drainRes = await new Promise<{ readonly ready: boolean; readonly timedOut: boolean }>((resolve) => {
      requestHaScopeEnableAfterDrain(haScope, (ready, meta) => {
        resolve({ ready, timedOut: Boolean(meta?.timedOut) });
      });
    });
    if (drainRes.timedOut) return handleDrainTimeout();
    if (!drainRes.ready || !isHostHaEnabled(host)) {
      host.render();
      return { status: "applied" };
    }
    const maybeApp = host as unknown as Partial<MenuMijiaWindowsApp>;
    if (typeof maybeApp.submitServiceEndpoints === "function") {
      maybeApp.submitServiceEndpoints(false);
    } else {
      invokeTauriVoid("set_service_endpoints", {
        assistantUrl: host.settings.assistantBaseURL?.trim?.() ?? "",
        haUrl: host.settings.haBaseURL.trim(),
      });
    }
    if (isDualSourceEnabled(host) || host.settings.connectionMode === "homeAssistant") {
      switchHome(host);
      host.render();
      const hostWithReenableTs = host as ConnectionsAndDiagHost & { pendingReenableNowMs?: number };
      if (options.nowMs !== undefined) hostWithReenableTs.pendingReenableNowMs = options.nowMs;
      try {
        if (isDualSourceEnabled(host)) {
          await host.refreshDevices(false);
        } else {
          await host.refreshHADevices(false);
        }
      } finally {
        delete hostWithReenableTs.pendingReenableNowMs;
      }
    }
    host.render();
    return { status: "applied" };
  }

  const context = buildHostCapabilityContext(host, allAccounts);
  if (context.state.disabledHaScopes.has(haScope)) {
    session.pendingHaDisablePreview = null;
    session.haDisableError = null;
    host.render();
    return { status: "applied" };
  }
  const currentGen = options.currentGeneration ?? computeDisablePreviewGeneration(context, scheduledCommandStore, ruleStore);
  const expectedGen = options.expectedGeneration !== undefined
    ? options.expectedGeneration
    : options.confirmPause && session.pendingHaDisablePreview?.scope === haScope
      ? session.pendingHaDisablePreview.generation
      : null;
  let verdict = previewHaConnectionDisable({
    haScope,
    context,
    scheduledCommandStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore,
    expectedGeneration: expectedGen,
    currentGeneration: currentGen,
    languagePreference: host.settings.interfaceLanguage,
  });
  if (
    options.confirmPause &&
    options.expectedGeneration === undefined &&
    verdict.blockingReasons.some((r) => r.kind === "stalePreviewGeneration")
  ) {
    const freshVerdict = previewHaConnectionDisable({
      haScope,
      context,
      scheduledCommandStore,
      activeTimerIdentity: scheduledCommandIdentity(host.settings),
      ruleStore,
      currentGeneration: currentGen,
      languagePreference: host.settings.interfaceLanguage,
    });
    if (freshVerdict.disposition === "requiresPauseConfirmation") {
      session.pendingHaDisablePreview = { scope: haScope, verdict: freshVerdict, generation: currentGen };
      session.haDisableError = null;
      const lang = activeLanguage(host.settings.interfaceLanguage);
      host.replyBanner = {
        text: formatDisableBlockedMessage(verdict, lang),
        source: tr3("连接管理", "連線管理", "Connections", lang),
        isError: true,
      };
      host.render();
      return { status: "requiresPauseConfirmation", verdict: freshVerdict };
    }
    verdict = freshVerdict;
  }
  if (verdict.disposition === "blocked") {
    session.pendingHaDisablePreview = null;
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(verdict, lang);
    session.haDisableError = msg;
    host.replyBanner = {
      text: msg,
      source: tr3("连接管理", "連線管理", "Connections", lang),
      isError: true,
    };
    host.render();
    return { status: "blocked", verdict };
  }
  if (verdict.disposition === "requiresPauseConfirmation" && !options.confirmPause) {
    session.pendingHaDisablePreview = { scope: haScope, verdict, generation: currentGen };
    session.haDisableError = null;
    host.render();
    return { status: "requiresPauseConfirmation", verdict };
  }

  session.pendingHaDisablePreview = null;
  const wasDualSource = isDualSourceEnabled(host);
  const isHaActiveMode = wasDualSource || host.settings.connectionMode === "homeAssistant";
  const dualRoutes = wasDualSource ? host.dualSourceCoordinator?.getLastMerged()?.routes : undefined;
  const deviceOwners = getHostMiAccountsState(host)?.merged?.deviceOwners;
  const currentHAIdentity = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken);
  const matchedCachedHa =
    currentHAIdentity !== null && host.settings.cachedHAHome?.identity === currentHAIdentity
      ? host.settings.cachedHAHome
      : null;

  const miOwnerOf = (dev: SmartDevice): string | null =>
    resolveDeviceMiAccountOwner({
      device: dev,
      accounts: allAccounts,
      connectionMode: host.settings.connectionMode,
      dualSourceEnabled: wasDualSource,
      disabledAccountIds: context.state.disabledAccountIds,
      ...(deviceOwners ? { deviceOwners } : {}),
      ...(dualRoutes?.[dev.id] ? { dualRoute: dualRoutes[dev.id]! } : {}),
    });
  const hasEnabledMiOwner = (dev: SmartDevice): boolean => {
    const owner = miOwnerOf(dev);
    return Boolean(owner && !context.state.disabledAccountIds.has(miAccountScope(owner)));
  };
  const isHaRepresented = (dev: SmartDevice): boolean => {
    const route = dualRoutes?.[dev.id];
    if (route) {
      return route.backend === "homeAssistant" || (route.alternateBackend === "homeAssistant" && route.alternateDevice !== null);
    }
    return dev.sourceBackend === "homeAssistant" || dev.id.startsWith("ha:");
  };
  const sceneOwnerOf = (sc: HomeScene): string | null =>
    resolveSceneMiAccountOwner({
      scene: sc,
      accounts: allAccounts,
      connectionMode: host.settings.connectionMode,
      dualSourceEnabled: wasDualSource,
      haBaseURL: host.settings.haBaseURL,
      haToken: host.settings.haToken,
    });

  const disabledHaDevices: SmartDevice[] = [];
  const seenDisabledIds = new Set<string>();
  const addDisabledDevice = (dev: SmartDevice): void => {
    if (seenDisabledIds.has(dev.id)) return;
    seenDisabledIds.add(dev.id);
    disabledHaDevices.push(dev);
  };
  if (wasDualSource) {
    for (const dev of host.devices) {
      if (isHaRepresented(dev) && !hasEnabledMiOwner(dev)) addDisabledDevice(dev);
    }
  } else if (host.settings.connectionMode === "homeAssistant") {
    for (const dev of host.devices) addDisabledDevice(dev);
    for (const dev of matchedCachedHa?.home.devices ?? []) addDisabledDevice(dev);
  } else if (matchedCachedHa) {
    for (const dev of matchedCachedHa.home.devices) addDisabledDevice(dev);
  }

  const haDeviceSnapshots = disabledHaDevices.map((d) =>
    snapshotDisabledHaDevice(
      d,
      haScope,
      host.deviceFacets[d.id] ?? matchedCachedHa?.home.deviceFacets?.[d.id] ?? [],
      host.layout?.aliases?.[d.id] ?? null,
    ),
  );
  const ownedHaScenes = wasDualSource
    ? collectHostKnownScenes(host).filter((s) => sceneOwnerOf(s) === null)
    : host.settings.connectionMode === "homeAssistant"
      ? collectHostKnownScenes(host)
      : [...(matchedCachedHa?.home.scenes ?? [])];
  const haSceneSnapshots = ownedHaScenes.map((s) => snapshotDisabledHaScene(s, haScope));
  const newlyPausedQaIds = verdict.itemsToPause.filter((i) => i.kind === "quickAction").map((i) => i.id);
  const prevRawSelection = readRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
  const prevRawTimers = readRawStorageItem(SCHEDULED_COMMANDS_STORAGE_KEY);
  const prevRawRules = readRawStorageItem(AutomationRuleStore.storageKey);
  const timerSnapshot = scheduledCommandStore.snapshotQueues();
  const prevRules = ruleStore.load();

  const wrote = writeMiAccountSelectionMutation({ mutate: (prev) => ({
    ...prev,
    disabledHaScopes: [...new Set([...prev.disabledHaScopes, haScope])],
    pendingRevalidationHaScopes: prev.pendingRevalidationHaScopes.filter((s) => (haConnectionScope(s) ?? s) !== haScope),
    pausedQuickActionIds: [...new Set([...prev.pausedQuickActionIds, ...newlyPausedQaIds])],
    knownDisabledHaDevices: [
      ...prev.knownDisabledHaDevices.filter((d) => d.scope !== haScope && !haDeviceSnapshots.some((s) => s.id === d.id)),
      ...haDeviceSnapshots,
    ],
    knownDisabledHaScenes: [
      ...prev.knownDisabledHaScenes.filter((s) => s.scope !== haScope && !haSceneSnapshots.some((snap) => snap.id === s.id)),
      ...haSceneSnapshots,
    ],
  }) });
  if (!wrote) {
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(null, lang);
    session.haDisableError = msg;
    host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
    host.render();
    return { status: "blocked", verdict };
  }
  const pauseRes = applyPauseItemsFromVerdict({
    verdict,
    scheduledCommandStore,
    ruleStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    activeConnectionScopes: context.state.selection.enabledConnectionScopes,
  });
  if (!pauseRes.ok) {
    try { scheduledCommandStore.restoreQueues(timerSnapshot); } catch {}
    try { ruleStore.save(prevRules); } catch {}
    restoreRawStorageItem(SCHEDULED_COMMANDS_STORAGE_KEY, prevRawTimers);
    restoreRawStorageItem(AutomationRuleStore.storageKey, prevRawRules);
    restoreRawStorageItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, prevRawSelection);
    const lang = activeLanguage(host.settings.interfaceLanguage);
    const msg = formatDisableBlockedMessage(null, lang);
    session.haDisableError = msg;
    host.replyBanner = { text: msg, source: tr3("连接管理", "連線管理", "Connections", lang), isError: true };
    host.render();
    return { status: "blocked", verdict };
  }
  session.haDisableError = null;

  beginHaScopeDisable(haScope);

  if (host.cameraLive?.activeLiveCameraId || host.cameraLive?.liveCameraKeepAliveTimer) {
    if (host.cameraLive.closeHomeAssistantCameraLiveView) {
      host.cameraLive.closeHomeAssistantCameraLiveView();
    } else if (!wasDualSource && host.settings.connectionMode === "homeAssistant") {
      host.cameraLive.closeCameraLiveView();
    }
  }
  const removedIds = new Set(disabledHaDevices.map((d) => d.id));
  for (const dev of host.devices) {
    if (removedIds.has(dev.id) || isHaRepresented(dev)) {
      cancelDelayedReadBack(host as unknown as OptimisticLockHost, dev.id);
      cancelEchoReadBack(host as unknown as MenuMijiaWindowsApp, dev.id);
    }
  }

  const hadTimerSnapshot = Boolean((host as { readonly timerSnapshot?: { readonly identity: string; readonly sourceRevision: number } | null }).timerSnapshot);
  if (isHaActiveMode) {
    switchSource(host, "ha-disabled");
    host.clearPendingHighRisk();
    (host as { pendingHighRiskUndoAction?: unknown }).pendingHighRiskUndoAction = null;
    if (hasPendingUrlConfirmation(host as unknown as MenuMijiaWindowsApp)) {
      dismissPendingUrlConfirmation(host as unknown as MenuMijiaWindowsApp, false);
    }
  }
  resetHostUnsupportedScanner(host);
  host.haConnectionError = null;

  const enabledMiAfter = filterEnabledMiAccounts(allAccounts, resolveHostMiSelectionState(host, allAccounts));
  const nextDual = wasDualSource
    ? (host.dualSourceCoordinator?.removeHomeAssistant(host.settings.interfaceLanguage, {
        reason: "disabled",
      }) ?? null)
    : null;
  if (isHaActiveMode && host.waitingDeviceIds) {
    for (const id of removedIds) host.waitingDeviceIds.delete(id);
  }

  const removedSceneIds = new Set(ownedHaScenes.map((s) => s.id));
  if (nextDual) {
    host.homes = applyOrder(host.homes.map((h) => h.id), nextDual.homes);
    host.groupOwnerByMemberDid = new Map(nextDual.lightGroupOwners);
    host.devices = applyOrder(host.devices.map((d) => d.id), nextDual.home.devices);
    host.deviceFacets = nextDual.home.deviceFacets ?? {};
    host.scenes = nextDual.home.scenes.filter((s) => !removedSceneIds.has(s.id));
    const prio = new Map(host.devices.map((d) => [d.id, environmentReadingPriority(d.kind)]));
    host.environmentReadings = applyOrder(host.environmentReadings.map((r) => r.id), nextDual.home.environmentReadings).sort((a, b) => (prio.get(a.id) ?? 0) - (prio.get(b.id) ?? 0));
  } else if (!wasDualSource && host.settings.connectionMode === "homeAssistant") {
    host.devices = [];
    host.scenes = [];
    host.environmentReadings = [];
    host.homes = [];
    host.groupOwnerByMemberDid = new Map();
    host.deviceFacets = {};
    host.selectRoom(null);
    host.waitingDeviceIds?.clear();
  } else if (wasDualSource) {
    if (enabledMiAfter.length === 0) {
      host.devices = [];
      host.scenes = [];
      host.environmentReadings = [];
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.deviceFacets = {};
      host.selectRoom(null);
    } else {
      host.devices = host.devices
        .filter((d) => !removedIds.has(d.id))
        .map((d) => {
          const route = dualRoutes?.[d.id];
          if (route?.backend === "homeAssistant" && route.alternateBackend === "xiaomiCloud" && route.alternateDevice) {
            return {
              ...route.alternateDevice,
              id: d.id,
              roomId: d.roomId,
              roomName: d.roomName,
              sourceBackend: "xiaomiCloud",
            };
          }
          return d;
        });
      host.environmentReadings = host.environmentReadings.filter((r) => !removedIds.has(r.id));
      const nextFacets = { ...host.deviceFacets };
      for (const id of removedIds) delete nextFacets[id];
      host.deviceFacets = nextFacets;
      host.scenes = host.scenes.filter((s) => !removedSceneIds.has(s.id));
    }
  }

  if (isHaActiveMode && host.expandedDeviceId && (removedIds.has(host.expandedDeviceId) || !host.devices.some((d) => d.id === host.expandedDeviceId))) {
    host.expandedDeviceId = null;
  }
  const hasRemainingActiveSource =
    (wasDualSource && enabledMiAfter.length > 0) ||
    (!wasDualSource && host.settings.connectionMode === "xiaomiCloud" && enabledMiAfter.length > 0) ||
    host.settings.connectionMode === "demo";
  if (isHaActiveMode && hadTimerSnapshot && hasRemainingActiveSource && "timerSnapshot" in host) {
    markTimerSnapshotReady(host as unknown as MenuMijiaWindowsApp);
  }
  const maybeApp = host as unknown as Partial<MenuMijiaWindowsApp>;
  if (typeof maybeApp.submitServiceEndpoints === "function") {
    maybeApp.submitServiceEndpoints(false);
  } else {
    invokeTauriVoid("set_service_endpoints", {
      assistantUrl: host.settings.assistantBaseURL?.trim?.() ?? "",
      haUrl: "",
    });
  }
  host.saveSettings();
  host.render();
  return { status: "applied" };
}

function signOutSingleMiAccountOnHost(
  host: ConnectionsAndDiagHost,
  accountId: string,
): Promise<boolean> {
  const session = getHostConnDiagSession(host);
  if (session.signingOutAccountIds.has(accountId)) {
    return Promise.resolve(false);
  }
  session.signingOutAccountIds.add(accountId);
  const run = session.signOutChain.then(
    () => performSignOutSingleMiAccountOnHost(host, session, accountId),
    () => performSignOutSingleMiAccountOnHost(host, session, accountId),
  );
  session.signOutChain = run.then(
    () => false,
    () => false,
  );
  return run;
}

async function performSignOutSingleMiAccountOnHost(
  host: ConnectionsAndDiagHost,
  session: HostConnDiagSession,
  accountId: string,
): Promise<boolean> {
  const store = getHostMiAccountsStore(host);
  const lang = activeLanguage(host.settings.interfaceLanguage);

  try {
    if (store.getAccounts().length === 0 && !hasPendingMiVaultDeletion()) {
      await store.load();
    }
    if (store.getAccounts().length === 0 && host.settings.miSession) {
      for (const item of resolveHostMiAccounts(host)) await store.upsertAccount(item.session);
    }
    const beforeIds = new Set(store.getAccounts().map((account) => account.id));
    if (beforeIds.size === 0) return false;
    const wasDualSource = isDualSourceEnabled(host);
    const removal = await store.removeAccount(accountId, host.settings.selectedHomeId);
    setHostMiAccounts(host, null);
    // Hidden-account recovery can replace the removed account with a discovered one, keeping the
    // count unchanged; only identity proves the requested account is gone.
    if (!beforeIds.has(accountId) || removal.accounts.some((account) => account.id === accountId)) {
      return false;
    }
    removeSignedOutMiAccountFromSelection(accountId);
    delete session.disableErrorByAccountId[accountId];
    if (session.pendingDisablePreview?.accountId === accountId) {
      session.pendingDisablePreview = null;
    }
    clearAccountRateLimitBackoff(accountId);

    const isXiaomiSnapshot = wasDualSource || host.settings.connectionMode === "xiaomiCloud";
    if (isXiaomiSnapshot) {
      switchSource(host, "mi-account-removed");
      host.clearPendingHighRisk();
    }
    resetHostUnsupportedScanner(host);

    const dualRoutesBeforeRemoval = wasDualSource ? host.dualSourceCoordinator?.getLastMerged()?.routes : undefined;
    const isRouteOwnedByRemovedAccount = (route: DeviceMergeRoute | undefined, dev: SmartDevice): boolean => {
      if (MiAccountScope.isOwned(dev.id, accountId) || dev.accountId === accountId) return true;
      if (!route) return false;
      if (
        route.backend === "xiaomiCloud" &&
        (route.sourceDevice.accountId === accountId || MiAccountScope.isOwned(route.sourceDeviceId, accountId))
      ) {
        return true;
      }
      if (
        route.alternateBackend === "xiaomiCloud" &&
        route.alternateDevice &&
        (route.alternateDevice.accountId === accountId || MiAccountScope.isOwned(route.alternateDevice.id, accountId))
      ) {
        return true;
      }
      return false;
    };
    const hasHomeAssistantRepresentation = (route: DeviceMergeRoute | undefined, dev: SmartDevice): boolean => {
      if (route) {
        return (
          route.backend === "homeAssistant" ||
          (route.alternateBackend === "homeAssistant" && route.alternateDevice !== null)
        );
      }
      return wasDualSource && dev.sourceBackend === "homeAssistant";
    };
    const removedIds = new Set(
      isXiaomiSnapshot
        ? host.devices
            .filter((d) => {
              const route = dualRoutesBeforeRemoval?.[d.id];
              if (!isRouteOwnedByRemovedAccount(route, d)) return false;
              if (hasHomeAssistantRepresentation(route, d)) return false;
              return true;
            })
            .map((d) => d.id)
        : [],
    );
    const activeCamId = host.cameraLive?.activeLiveCameraId;
    if (activeCamId) {
      if (host.cameraLive?.closeXiaomiCameraLiveView) {
        host.cameraLive.closeXiaomiCameraLiveView(accountId);
      } else if (removedIds.has(activeCamId) || MiAccountScope.isOwned(activeCamId, accountId)) {
        host.cameraLive?.closeCameraLiveView();
      }
    }

    if (removal.resetSelectedHome) host.settings.selectedHomeId = null;
    if (removal.primarySessionKnown) {
      host.settings.miSession = removal.primarySession;
      if (removal.primarySession) {
        host.settings.miCloudRegion = normalizeMiCloudRegion(removal.primarySession.region);
      }
    }
    const enabledRemaining = filterEnabledMiAccounts(
      removal.accounts,
      resolveHostMiSelectionState(host, removal.accounts),
    );
    const nextDual =
      wasDualSource && removal.accounts.length > 0
        ? (host.dualSourceCoordinator?.removeXiaomiAccount(accountId, host.settings.interfaceLanguage, {
            remainingEnabledCount: enabledRemaining.length,
            reason: enabledRemaining.length === 0 ? "disabled" : "signedOut",
          }) ?? null)
        : null;

    if (isXiaomiSnapshot && host.waitingDeviceIds) {
      for (const id of removedIds) host.waitingDeviceIds.delete(id);
      if (nextDual) {
        for (const d of host.devices) {
          const prevRoute = dualRoutesBeforeRemoval?.[d.id];
          const nextRoute = nextDual.routes[d.id];
          if (
            isRouteOwnedByRemovedAccount(prevRoute, d) ||
            (prevRoute && (!nextRoute || nextRoute.backend !== prevRoute.backend))
          ) {
            host.waitingDeviceIds.delete(d.id);
          }
        }
      }
    }

    if (nextDual) {
      host.homes = applyOrder(host.homes.map((h) => h.id), nextDual.homes);
      host.groupOwnerByMemberDid = new Map(nextDual.lightGroupOwners);
      host.devices = applyOrder(host.devices.map((d) => d.id), nextDual.home.devices);
      host.deviceFacets = nextDual.home.deviceFacets ?? {};
      host.scenes = [...nextDual.home.scenes];
      const readingPriorityById = new Map(
        host.devices.map((d) => [d.id, environmentReadingPriority(d.kind)]),
      );
      host.environmentReadings = applyOrder(
        host.environmentReadings.map((r) => r.id),
        nextDual.home.environmentReadings,
      ).sort((a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0));
      reconcileActiveCameraAfterDeviceRestore(host, dualRoutesBeforeRemoval);
    } else if (isXiaomiSnapshot) {
      if (removedIds.size > 0) {
        host.devices = host.devices.filter((d) => !removedIds.has(d.id));
        host.environmentReadings = host.environmentReadings.filter((r) => !removedIds.has(r.id));
        const nextFacets = { ...host.deviceFacets };
        for (const id of removedIds) delete nextFacets[id];
        host.deviceFacets = nextFacets;
      }
      host.scenes = host.scenes.filter(
        (s) => s.accountId !== accountId && !MiAccountScope.isOwned(s.id, accountId) && !MiAccountScope.isOwned(s.entityId, accountId),
      );
      if (wasDualSource) {
        const stripRemovedAccountMeta = (dev: SmartDevice): SmartDevice => {
          if (dev.accountId !== accountId) return dev;
          const { accountId: _removedId, accountLabel: _removedLabel, ...rest } = dev;
          return rest;
        };
        host.devices = host.devices.map((d) => {
          const route = dualRoutesBeforeRemoval?.[d.id];
          if (!isRouteOwnedByRemovedAccount(route, d)) return d;
          if (
            route?.backend === "xiaomiCloud" &&
            route.alternateBackend === "homeAssistant" &&
            route.alternateDevice
          ) {
            return stripRemovedAccountMeta({
              ...route.alternateDevice,
              id: d.id,
              roomId: d.roomId,
              roomName: d.roomName,
              sourceBackend: "homeAssistant",
            });
          }
          return stripRemovedAccountMeta(d);
        });
      }
    }

    if (
      isXiaomiSnapshot &&
      host.expandedDeviceId &&
      (removedIds.has(host.expandedDeviceId) ||
        MiAccountScope.isOwned(host.expandedDeviceId, accountId) ||
        (nextDual !== null && !host.devices.some((d) => d.id === host.expandedDeviceId)))
    ) {
      host.expandedDeviceId = null;
    }

    if (removal.accounts.length <= 1) {
      host.multiAccountState = null;
    } else if (host.multiAccountState) {
      const nextChildren = { ...host.multiAccountState.children };
      delete nextChildren[accountId];
      host.multiAccountState = {
        accounts: removal.accounts,
        children: nextChildren,
        merged: mergeMiAccountSnapshots(removal.accounts, nextChildren),
      };
    }

    session.signingOutAccountIds.delete(accountId);
    const hasMoreQueuedSignOuts = session.signingOutAccountIds.size > 0;

    if (removal.accounts.length === 0) {
      const { transitionedToHASingleSource } = finishAllMiAccountsSignedOutOnHost(host, {
        wasDualSource,
        wasXiaomiMode: host.settings.connectionMode === "xiaomiCloud",
        alreadySwitchedSource: isXiaomiSnapshot,
      });
      host.saveSettings();
      if (transitionedToHASingleSource) {
        host.replyBanner = {
          text: tr3(
            "已退出最后一个米家账号，已保留 Home Assistant 连接",
            "已登出最後一個米家帳號，已保留 Home Assistant 連線",
            "Signed out of the last Xiaomi account; kept Home Assistant active",
            lang,
          ),
          source: tr3("多账号管理", "多帳號管理", "Accounts", lang),
        };
        host.render();
        await host.refreshHADevices(false);
      } else {
        host.replyBanner = {
          text: tr3("已退出米家账号", "已登出米家帳號", "Signed out of Xiaomi Home", lang),
          source: tr3("多账号管理", "多帳號管理", "Accounts", lang),
        };
        host.render();
      }
      return true;
    }

    revalidateHostAfterAccountRemoval(host, removal.accounts);
    const rem = removal.accounts.length;
    host.saveSettings();
    host.replyBanner = {
      text: tr3(
        `已移除米家账号（剩余 ${rem} 个账号在线）`,
        `已移除米家帳號（剩餘 ${rem} 個帳號在線）`,
        `Removed Xiaomi account (${rem} remaining)`,
        lang,
      ),
      source: tr3("多账号管理", "多帳號管理", "Accounts", lang),
    };
    host.render();
    if (!hasMoreQueuedSignOuts && host.settings.connectionMode !== "demo") {
      await host.refreshDevices(false);
    }
    return true;
  } catch (error) {
    session.signingOutAccountIds.delete(accountId);
    const detail = error instanceof Error && error.message.trim() ? ` (${error.message.trim()})` : "";
    host.replyBanner = {
      text: `${tr3("无法从系统凭据库移除该米家账号，请重试", "無法從系統憑證庫移除該米家帳號，請重試", "Could not remove Xiaomi account from the OS credential store; please retry", lang)}${detail}`,
      source: tr3("出错提示", "錯誤提示", "Error", lang),
      isError: true,
    };
    host.render();
    return false;
  } finally {
    session.signingOutAccountIds.delete(accountId);
  }
}

function buildHAStateFromDualRoutes(
  host: ConnectionsAndDiagHost,
  dualRoutes: Readonly<Record<string, DeviceMergeRoute>>,
): {
  readonly devices: SmartDevice[];
  readonly environmentReadings: EnvironmentReading[];
  readonly deviceFacets: Record<string, readonly FacetControl[]>;
} {
  const nextDevices: SmartDevice[] = [];
  const keepIds = new Set<string>();
  const seenIds = new Set<string>();
  for (const dev of host.devices) {
    seenIds.add(dev.id);
    const route = dualRoutes[dev.id];
    if (route?.backend === "homeAssistant") {
      nextDevices.push({
        ...route.sourceDevice,
        id: dev.id,
        roomId: dev.roomId,
        roomName: dev.roomName,
        sourceBackend: "homeAssistant",
      });
      keepIds.add(dev.id);
    } else if (route?.alternateBackend === "homeAssistant" && route.alternateDevice) {
      nextDevices.push({
        ...route.alternateDevice,
        id: dev.id,
        roomId: dev.roomId,
        roomName: dev.roomName,
        sourceBackend: "homeAssistant",
      });
      keepIds.add(dev.id);
    } else if (!route && dev.sourceBackend === "homeAssistant") {
      nextDevices.push(dev);
      keepIds.add(dev.id);
    }
  }
  for (const [id, route] of Object.entries(dualRoutes)) {
    if (seenIds.has(id)) continue;
    if (route.backend === "homeAssistant") {
      nextDevices.push({ ...route.sourceDevice, id, sourceBackend: "homeAssistant" });
      keepIds.add(id);
    } else if (route.alternateBackend === "homeAssistant" && route.alternateDevice) {
      nextDevices.push({ ...route.alternateDevice, id, sourceBackend: "homeAssistant" });
      keepIds.add(id);
    }
  }
  const environmentReadings = host.environmentReadings.filter((r) => keepIds.has(r.id));
  const deviceFacets: Record<string, readonly FacetControl[]> = {};
  for (const [id, controls] of Object.entries(host.deviceFacets)) {
    if (keepIds.has(id)) deviceFacets[id] = controls;
  }
  return { devices: nextDevices, environmentReadings, deviceFacets };
}

/**
 * Sign-out restores raw Home Assistant cards, so a live view opened under a paired card's canonical
 * id keeps an id the device list no longer has (#254). Follow the camera to the HA card that
 * replaced it while its stream stays open; close the view when no card is left to show it.
 */
function reconcileActiveCameraAfterDeviceRestore(
  host: ConnectionsAndDiagHost,
  dualRoutes: Readonly<Record<string, DeviceMergeRoute>> | undefined,
): void {
  const activeId = host.cameraLive?.activeLiveCameraId ?? null;
  if (!activeId) return;
  if (host.devices.some((d) => d.id === activeId)) return;
  const route = dualRoutes?.[activeId];
  const haCandidates = [
    route?.backend === "homeAssistant" ? route.sourceDeviceId : null,
    route?.alternateBackend === "homeAssistant" ? (route.alternateDevice?.id ?? null) : null,
  ];
  for (const candidateId of haCandidates) {
    if (!candidateId) continue;
    const dev = host.devices.find((d) => d.id === candidateId && d.kind.kind === "camera");
    if (dev && host.cameraLive?.retargetActiveLiveCamera?.(dev.id)) return;
  }
  host.cameraLive?.closeCameraLiveView();
}

export function finishAllMiAccountsSignedOutOnHost(
  host: ConnectionsAndDiagHost,
  options: {
    readonly wasDualSource: boolean;
    readonly wasXiaomiMode: boolean;
    readonly alreadySwitchedSource?: boolean;
  },
): { readonly transitionedToHASingleSource: boolean } {
  const { wasDualSource, wasXiaomiMode, alreadySwitchedSource = false } = options;
  if (wasDualSource || wasXiaomiMode) {
    if (host.cameraLive?.closeXiaomiCameraLiveView) {
      host.cameraLive.closeXiaomiCameraLiveView();
    } else if (host.cameraLive?.activeLiveCameraId || host.cameraLive?.liveCameraKeepAliveTimer) {
      host.cameraLive.closeCameraLiveView();
    }
    if (!alreadySwitchedSource) {
      switchSource(host, "sign-out-xiaomi-account");
    }
    host.clearPendingHighRisk();
    resetHostUnsupportedScanner(host);
    host.waitingDeviceIds?.clear();
  }
  host.cameraLive?.discardRetainedCloudSessions?.();
  host.settings.cachedXiaomiDevices = [];
  host.miSessionExpired = false;
  host.cloudValuesStale = false;
  clearCachedXiaomiTopology(host);
  clearXiaomiRateLimitBackoff(host);
  clearAccountRateLimitBackoff();
  removeSignedOutMiAccountFromSelection(null);
  if (host.connDiagSession) {
    host.connDiagSession.pendingDisablePreview = null;
    host.connDiagSession.disableErrorByAccountId = {};
  }

  const currentHAIdentity = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken);
  const hasHA = currentHAIdentity !== null;
  const dualCoordinator = wasDualSource ? host.dualSourceCoordinator : null;
  const rawHASnapshot = dualCoordinator?.getLastHASnapshot?.() ?? null;
  const matchesCurrentHASnapshot =
    rawHASnapshot !== null &&
    currentHAIdentity !== null &&
    (rawHASnapshot.identity === undefined || rawHASnapshot.identity === currentHAIdentity);
  const currentHASnapshot = matchesCurrentHASnapshot ? rawHASnapshot : null;
  const snapshotIdentityMismatched =
    rawHASnapshot !== null &&
    rawHASnapshot.identity !== undefined &&
    rawHASnapshot.identity !== currentHAIdentity;
  const lastMerged = snapshotIdentityMismatched ? null : (dualCoordinator?.getLastMerged() ?? null);
  const dualRoutes = lastMerged?.routes;
  setHostDualSourceEnabled(host, false, { persist: true });

  if (hasHA && (wasDualSource || host.settings.connectionMode === "homeAssistant")) {
    const haEnabled = isHostHaEnabled(host);
    host.settings.connectionMode = "homeAssistant";
    if (!haEnabled) {
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.selectRoom(null);
      host.devices = [];
      host.scenes = [];
      host.environmentReadings = [];
      host.deviceFacets = {};
      host.expandedDeviceId = null;
      if (host.cameraLive?.activeLiveCameraId || host.cameraLive?.liveCameraKeepAliveTimer) {
        host.cameraLive.closeCameraLiveView();
      }
      revalidateHostAfterAccountRemoval(host, []);
      return { transitionedToHASingleSource: false };
    }
    if (wasDualSource) {
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.selectRoom(null);
      const cache = host.settings.cachedHAHome;
      const matchesCache = cache?.identity === currentHAIdentity;
      const routeDerivedHA = dualRoutes ? buildHAStateFromDualRoutes(host, dualRoutes) : null;
      if (currentHASnapshot) {
        host.devices = structuredClone(currentHASnapshot.home.devices);
        host.scenes = structuredClone(currentHASnapshot.home.scenes);
        host.environmentReadings = structuredClone(currentHASnapshot.home.environmentReadings);
        host.deviceFacets = structuredClone(currentHASnapshot.home.deviceFacets ?? {});
      } else if (routeDerivedHA && routeDerivedHA.devices.length > 0) {
        host.devices = routeDerivedHA.devices;
        if (lastMerged) {
          host.scenes = structuredClone(lastMerged.home.scenes);
        }
        host.environmentReadings = routeDerivedHA.environmentReadings;
        host.deviceFacets = routeDerivedHA.deviceFacets;
      } else if (matchesCache && cache) {
        host.devices = structuredClone(cache.home.devices);
        host.scenes = structuredClone(cache.home.scenes);
        host.environmentReadings = structuredClone(cache.home.environmentReadings);
        host.deviceFacets = structuredClone(cache.home.deviceFacets ?? {});
      } else if (dualRoutes || snapshotIdentityMismatched) {
        host.devices = [];
        host.scenes = [];
        host.environmentReadings = [];
        host.deviceFacets = {};
      } else {
        host.devices = host.devices.filter((d) => d.sourceBackend !== "xiaomiCloud");
        const keepIds = new Set(host.devices.map((d) => d.id));
        host.environmentReadings = host.environmentReadings.filter((r) => keepIds.has(r.id));
        const nextFacets: Record<string, readonly FacetControl[]> = {};
        for (const [id, controls] of Object.entries(host.deviceFacets)) {
          if (keepIds.has(id)) nextFacets[id] = controls;
        }
        host.deviceFacets = nextFacets;
      }
      if (host.expandedDeviceId && !host.devices.some((d) => d.id === host.expandedDeviceId)) {
        host.expandedDeviceId = null;
      }
      reconcileActiveCameraAfterDeviceRestore(host, dualRoutes);
    }
    revalidateHostAfterAccountRemoval(host, []);
    return { transitionedToHASingleSource: wasDualSource };
  }

  if (wasXiaomiMode || wasDualSource) {
    host.expandedDeviceId = null;
    host.devices = [];
    host.scenes = [];
    host.environmentReadings = [];
    host.homes = [];
    host.groupOwnerByMemberDid = new Map();
    host.deviceFacets = {};
    host.selectRoom(null);
    if (isFullPanelHost(host)) clearHostActivitiesOnSignOut(host);
    reconcileActiveCameraAfterDeviceRestore(host, dualRoutes);
  }
  revalidateHostAfterAccountRemoval(host, []);
  return { transitionedToHASingleSource: false };
}

export async function disconnectHomeAssistantOnHost(host: ConnectionsAndDiagHost): Promise<boolean> {
  const lang = activeLanguage(host.settings.interfaceLanguage);
  const oldHaScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);

  try {
    if (host.credentialVault) {
      await host.credentialVault.load();
      await host.credentialVault.persist(
        credentialsFromSettings({ ...host.settings, haToken: "" }, host.assistantKeysByPreset),
      );
    } else {
      await secureStoreDelete("ha_token");
    }
  } catch (error) {
    const detail = error instanceof Error && error.message.trim() ? ` (${error.message.trim()})` : "";
    host.replyBanner = {
      text: `${tr3("无法清除系统凭据库中的 Home Assistant 令牌，请重试", "無法清除系統憑證庫中的 Home Assistant 權杖，請重試", "Could not clear Home Assistant token from the OS credential store; please retry", lang)}${detail}`,
      source: "Home Assistant",
      isError: true,
    };
    host.render();
    return false;
  }

  if (host.cameraLive?.activeLiveCameraId || host.cameraLive?.liveCameraKeepAliveTimer) {
    if (host.cameraLive.closeHomeAssistantCameraLiveView) {
      host.cameraLive.closeHomeAssistantCameraLiveView();
    } else {
      host.cameraLive.closeCameraLiveView();
    }
  }
  host.expandedDeviceId = null;
  host.waitingDeviceIds?.clear();
  switchSource(host, "ha-disconnected");
  host.clearPendingHighRisk();
  (host as { pendingHighRiskUndoAction?: unknown }).pendingHighRiskUndoAction = null;

  clearHaScopeLifecycle(oldHaScope);
  removeDisconnectedHaFromSelection(oldHaScope);
  if (host.connDiagSession) {
    host.connDiagSession.pendingHaDisablePreview = null;
    host.connDiagSession.haDisableError = null;
  }

  host.settings.haToken = "";
  host.settings.cachedHAHome = null;
  host.haConnectionError = null;
  setHostDualSourceEnabled(host, false, { persist: true });
  resetHostUnsupportedScanner(host);
  revalidateHostAfterAccountRemoval(host, resolveHostMiAccounts(host));

  const tokenField = host.root.querySelector<HTMLInputElement>("#settings-ha-token");
  if (tokenField) {
    tokenField.value = "";
    tokenField.defaultValue = "";
  }

  const hasMi = resolveHostMiAccounts(host).length > 0 || hasSecondaryMiAccountsInIndex();
  if (host.settings.connectionMode !== "demo") {
    if (hasMi) {
      host.settings.connectionMode = "xiaomiCloud";
      host.devices = structuredClone(host.settings.cachedXiaomiDevices);
      host.scenes = [];
      host.environmentReadings = [];
      host.deviceFacets = {};
      host.groupOwnerByMemberDid = new Map();
      host.selectRoom(null);
      host.replyBanner = {
        text: tr3(
          "已断开 Home Assistant，已自动切回米家云端",
          "已中斷 Home Assistant，已自動切回米家雲端",
          "Disconnected from Home Assistant; switched back to Xiaomi Cloud",
          lang,
        ),
        source: "Home Assistant",
      };
      host.saveSettings();
      host.render();
      await host.refreshDevices(false);
      return true;
    }
    host.devices = [];
    host.scenes = [];
    host.environmentReadings = [];
    host.homes = [];
    host.deviceFacets = {};
    host.groupOwnerByMemberDid = new Map();
    host.selectRoom(null);
    if (isFullPanelHost(host)) clearHostActivitiesOnSignOut(host);
  }

  host.replyBanner = {
    text: tr3("已断开 Home Assistant 连接", "已中斷 Home Assistant 連線", "Disconnected from Home Assistant", lang),
    source: "Home Assistant",
  };
  host.saveSettings();
  host.render();
  return true;
}

async function toggleDualSourceOnHost(
  host: ConnectionsAndDiagHost,
  enabled: boolean,
): Promise<void> {
  if (enabled && host.settings.connectionMode === "demo") {
    const hasHA = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken) !== null;
    const hasMi = resolveHostMiAccounts(host).length > 0 || hasSecondaryMiAccountsInIndex();
    if (hasHA && hasMi) host.settings.connectionMode = "xiaomiCloud";
  }
  setHostDualSourceEnabled(host, enabled, { persist: true });
  resetHostUnsupportedScanner(host);
  host.saveSettings();
  host.render();
  if (host.settings.connectionMode === "demo") return;
  if (!enabled && host.settings.connectionMode === "homeAssistant") await host.refreshHADevices(false);
  else await host.refreshDevices(false);
}

function cancelAddAccountQrFlow(host: ConnectionsAndDiagHost, shouldRender = false): void {
  const session = getHostConnDiagSession(host);
  if (!session.addQr.open && session.addQr.phase === "idle") return;
  session.addQr.generation += 1;
  session.addQr.open = false;
  session.addQr.phase = "idle";
  session.addQr.ticket = null;
  session.addQr.statusText = "";
  invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
  if (shouldRender && isHostAttached(host)) host.render();
}

async function startAddAccountQrFlow(host: ConnectionsAndDiagHost): Promise<void> {
  const session = getHostConnDiagSession(host);
  const lang = activeLanguage(host.settings.interfaceLanguage);
  const generation = ++session.addQr.generation;
  const transport = host.transport ?? createTransport();

  session.addQr.open = true;
  session.addQr.phase = "loading";
  session.addQr.ticket = null;
  session.addQr.statusText = tr3(
    "正在获取新账号安全二维码…",
    "正在取得新帳號安全 QR Code…",
    "Fetching QR code for additional Xiaomi account…",
    lang,
  );
  invokeTauriVoid("set_pin_popover", { pin: true });
  host.render();

  try {
    const login = new MiAccountLogin(transport, session.addQr.region);
    const ticket = await login.start();
    if (session.addQr.generation !== generation || !isHostAttached(host)) return;
    session.addQr.phase = "waiting";
    session.addQr.ticket = ticket;
    session.addQr.statusText = tr3(
      "请用手机「米家 App → 我的 → 右上角扫一扫」登录另一个账号（不会覆盖已登录账号）",
      "請用手機「米家 App → 我的 → 右上角掃一掃」登入另一個帳號（不會覆蓋已登入帳號）",
      "Scan with the Mi Home app to add another account (existing accounts stay signed in)",
      lang,
    );
    host.render();

    const scannedSession = await login.waitForScan(ticket);
    if (session.addQr.generation !== generation || !isHostAttached(host)) return;
    session.addQr.open = false;
    session.addQr.phase = "idle";
    session.addQr.ticket = null;
    session.addQr.statusText = "";
    await addOrUpdateMiAccountOnHost(host, scannedSession);
  } catch (error) {
    if (session.addQr.generation !== generation || !isHostAttached(host)) return;
    const message = error instanceof Error ? error.message : String(error);
    session.addQr.phase = "failed";
    session.addQr.ticket = null;
    session.addQr.statusText = tr3(
      `扫码未完成：${message}`,
      `掃碼未完成：${message}`,
      `QR sign-in incomplete: ${message}`,
      lang,
    );
    host.render();
  } finally {
    if (session.addQr.generation === generation && isHostAttached(host)) {
      invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
    }
  }
}

function resolveScannerHAInvoke(host: ConnectionsAndDiagHost): ScannerHAInvoke | undefined {
  const override = getHostConnDiagSession(host).haScannerInvokeOverride;
  if (override) return override;
  const tauriInvoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!tauriInvoke) return undefined;
  return <T>(cmd: string, args: Record<string, unknown>) => tauriInvoke<T>(cmd, args);
}

function buildUnsupportedScanOptions(
  host: ConnectionsAndDiagHost,
  accountsOverride?: readonly MiAccount[],
): ScanUnsupportedOptions {
  const haInvoke = resolveScannerHAInvoke(host);
  const rawAccounts = accountsOverride ? [...accountsOverride] : resolveHostMiAccounts(host);
  const miAccounts = filterEnabledMiAccounts(rawAccounts, resolveHostMiSelectionState(host, rawAccounts));
  return {
    connectionMode: host.settings.connectionMode,
    dualSourceEnabled: isDualSourceEnabled(host),
    miAccounts,
    transport: host.transport ?? createTransport(),
    ...(host.specResolver ? { specResolver: host.specResolver } : {}),
    haBaseURL: host.settings.haBaseURL,
    haToken: host.settings.haToken,
    haDisabled: !isHostHaEnabled(host),
    ...(haInvoke ? { haInvoke } : {}),
    languagePreference: host.settings.interfaceLanguage,
  };
}

function syncConnectionContextWatcher(host: ConnectionsAndDiagHost): void {
  const session = getHostConnDiagSession(host);
  const options = buildUnsupportedScanOptions(host);
  const nextKey = UnsupportedDeviceScanner.contextKey(options);
  if (session.lastContextKey !== null && session.lastContextKey !== nextKey) {
    session.scanner.reset();
    session.diagMarkdownPreview = null;
    session.diagCopied = false;
    if (host.settings.connectionMode === "demo") cancelAddAccountQrFlow(host, false);
  }
  session.lastContextKey = nextKey;
  session.scanner.invalidateIfContextChanged(options);
}

export async function runUnsupportedDevicesScanOnHost(
  host: ConnectionsAndDiagHost,
): Promise<readonly UnsupportedDevice[]> {
  const session = getHostConnDiagSession(host);
  const store = getHostMiAccountsStore(host);
  if (store.getAccounts().length === 0) await store.load();
  const accounts = resolveHostMiAccounts(host);
  const options = buildUnsupportedScanOptions(host, accounts);
  session.lastContextKey = UnsupportedDeviceScanner.contextKey(options);
  const scanPromise = session.scanner.scan(options);
  host.render();
  const outcome = await scanPromise;
  if (isHostAttached(host)) host.render();
  return outcome.devices;
}

function collectForbiddenLiterals(
  host: ConnectionsAndDiagHost,
  accounts: readonly MiAccount[],
): string[] {
  const literals: string[] = [
    host.settings.haBaseURL,
    host.settings.haToken,
    host.settings.openRouterApiKey,
    host.settings.assistantBaseURL,
    readCustomHomeTitle(host.settings),
  ];
  for (const acc of accounts) {
    literals.push(
      acc.id,
      acc.session.userId,
      acc.session.cUserId,
      acc.session.serviceToken,
      acc.session.ssecurity,
    );
  }
  for (const home of host.homes) literals.push(home.name, home.id);
  for (const dev of host.devices) literals.push(dev.id);
  return literals.map((item) => item.trim()).filter((item) => item.length >= 2);
}

function buildDesensitizedDiagnosticsMarkdown(host: ConnectionsAndDiagHost): string {
  syncConnectionContextWatcher(host);
  const session = getHostConnDiagSession(host);
  const lang = activeLanguage(host.settings.interfaceLanguage);
  const accounts = resolveHostMiAccounts(host);
  const dualActive = isDualSourceEnabled(host);
  const dualState = getHostDualSourceState(host);
  const miState = getHostMiAccountsState(host);

  const backendTitle =
    host.settings.connectionMode === "demo"
      ? tr3("离线演示", "離線展示", "Offline Demo", lang)
      : dualActive
        ? tr3(
            "Home Assistant + 米家云端双源融合",
            "Home Assistant + 米家雲端雙源融合",
            "Home Assistant + Xiaomi Cloud Dual-Source",
            lang,
          )
        : host.settings.connectionMode === "homeAssistant"
          ? "Home Assistant"
          : tr3("米家云端直连", "米家雲端直連", "Xiaomi Cloud Direct", lang);

  const regions = accounts.map((a) => a.region);
  const miHomeCount =
    session.scanner.miHomeCount ??
    (miState?.merged ? miState.merged.homes.length : host.homes.length > 0 ? host.homes.length : null);
  const osLabel =
    typeof navigator !== "undefined" && /Windows NT 10\.0/i.test(navigator.userAgent ?? "")
      ? "Windows 10/11"
      : "Windows";

  return DiagnosticsReportBuilder.markdown({
    appVersion: APP_VERSION,
    osVersion: osLabel,
    language: lang,
    languagePreference: host.settings.interfaceLanguage,
    backendTitle,
    ...(regions.length > 0 ? { miCloudRegions: regions, miAccountCount: accounts.length } : {}),
    ...(miHomeCount !== null ? { miHomeCount } : {}),
    ...(session.scanner.miSharedHomeCount !== null
      ? { miSharedHomeCount: session.scanner.miSharedHomeCount }
      : {}),
    isMiHomeFiltered: host.settings.selectedHomeId !== null,
    deviceCount: host.devices.length,
    onlineDeviceCount: host.devices.filter((d) => d.isOnline).length,
    hiddenDeviceCount: (host.settings.layout.hiddenDeviceIds ?? []).length,
    models: summarizeModelCounts(host.devices),
    unsupported: session.scanner.devices,
    cameras: deriveCameraDiagnostics(host.devices, {
      defaultBackend: host.settings.connectionMode,
      deviceBackends: {
        ...Object.fromEntries(
          host.devices.flatMap((d) => {
            const sb = d.sourceBackend;
            if (sb === "homeAssistant" || sb === "xiaomiCloud") return [[d.id, sb] as const];
            if (d.kind.kind === "camera" && d.kind.entityId.startsWith("camera.")) {
              return [[d.id, "homeAssistant"] as const];
            }
            return [];
          }),
        ),
        ...(dualState ? dualState.deviceBackends : {}),
      },
      activeLiveCameraId: host.cameraLive?.activeLiveCameraId ?? null,
    }),
    pollingBackoff: derivePollingBackoffDiagnostics({
      host,
      primarySession: host.settings.miSession,
      sessionExpired: Boolean(host.miSessionExpired),
      isDemo: host.settings.connectionMode === "demo",
    }),
    errorSnapshots: appDiagnosticsLog.getSnapshots(),
    forbiddenLiterals: collectForbiddenLiterals(host, accounts),
  });
}

async function writeTextToClipboard(text: string): Promise<boolean> {
  try {
    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
  }
  try {
    if (typeof document !== "undefined") {
      const area = document.createElement("textarea");
      area.value = text;
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      const copied = typeof document.execCommand === "function" ? document.execCommand("copy") : true;
      area.remove();
      return copied;
    }
  } catch {
  }
  return false;
}

async function copyDiagnosticsReportOnHost(host: ConnectionsAndDiagHost): Promise<string> {
  const session = getHostConnDiagSession(host);
  const lang = activeLanguage(host.settings.interfaceLanguage);
  const markdown = buildDesensitizedDiagnosticsMarkdown(host);
  session.diagMarkdownPreview = markdown;
  session.diagCopied = await writeTextToClipboard(markdown);
  host.replyBanner = {
    text: tr3(
      "已复制脱敏诊断报告到剪贴板",
      "已複製去識別化診斷報告至剪貼簿",
      "Copied desensitized diagnostics report to clipboard",
      lang,
    ),
    source: tr3("诊断信息", "診斷資訊", "Diagnostics", lang),
  };
  if (isHostAttached(host)) host.render();
  return markdown;
}

export function isConnectionsAndDiagModalOpen(host: ConnectionsAndDiagHost): boolean {
  if (host.activeSheet !== "none" || host.prompt != null) return false;
  return getHostConnDiagSession(host).modalSection !== null;
}

export function openConnectionsAndDiagModal(
  host: ConnectionsAndDiagHost,
  section: ConnDiagModalSection = "accounts",
): void {
  const session = getHostConnDiagSession(host);
  host.isHomeMenuOpen = false;
  host.ctxMenu = null;
  host.prompt = null;
  session.modalSection = section;
  invokeTauriVoid("set_pin_popover", { pin: true });
  host.render();

  const anchorMap: Record<ConnDiagModalSection, string> = {
    accounts: "#conn-diag-accounts-section",
    title: "#settings-custom-home-title",
    scanner: "#conn-diag-scanner-section",
    diagnostics: "#conn-diag-diagnostics-section",
  };
  const target = host.root.querySelector<HTMLElement>(anchorMap[section]);
  for (let cur = target?.parentElement ?? null; cur; cur = cur.parentElement) {
    if (cur.tagName === "DETAILS") {
      (cur as HTMLDetailsElement).open = true;
      cur.setAttribute("open", "");
    }
  }
  if (section === "title" && target?.tagName === "INPUT") {
    target.focus({ preventScroll: true });
  } else {
    target?.scrollIntoView?.({ block: "nearest" });
    (
      host.root.querySelector<HTMLElement>("#btn-close-conn-diag-modal") ??
      host.root.querySelector<HTMLElement>("#conn-diag-modal")
    )?.focus?.({ preventScroll: true });
  }
}

export function closeConnectionsAndDiagModal(host: ConnectionsAndDiagHost): void {
  const session = getHostConnDiagSession(host);
  if (session.modalSection === null) return;
  session.modalSection = null;
  session.titleDraft = null;
  cancelAddAccountQrFlow(host, false);
  invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
  host.render();
}

function renderTokenBadge(
  acc: MiAccount,
  status: MiAccountTokenStatus,
  disconnectReason: string | null,
  lang: AppLanguage,
  esc: (v: string) => string,
): { badgeHtml: string; noticeHtml: string; needsRescan: boolean } {
  const isExpired = status.kind === "expired" || Boolean(disconnectReason);
  const isExpiring = !isExpired && status.kind === "expiringSoon";
  const badgeText = isExpired
    ? tr3("已失效", "已失效", "Expired", lang)
    : isExpiring
      ? tr3("即将过期", "即將到期", "Expiring Soon", lang)
      : tr3("状态正常", "狀態正常", "Active", lang);
  const badgeColor = isExpired ? "#e74c3c" : isExpiring ? "#e67e22" : "#2ecc71";
  const badgeBg = isExpired
    ? "rgba(231,76,60,0.16)"
    : isExpiring
      ? "rgba(230,126,34,0.16)"
      : "rgba(46,204,113,0.16)";
  const noticeText = disconnectReason ?? formatAccountTokenNotice(acc, status, lang);
  const statusKind = isExpired ? "expired" : isExpiring ? "expiringSoon" : "valid";
  return {
    badgeHtml: `<span class="cc-inline-pill" data-mi-account-status="${esc(statusKind)}" style="font-size:11px;padding:2px 7px;color:${badgeColor};background:${badgeBg};border:1px solid ${badgeColor}33;">${esc(badgeText)}</span>`,
    noticeHtml: noticeText
      ? `<p class="cc-field-hint" style="margin:4px 0 0;color:${badgeColor};">${esc(noticeText)}</p>`
      : "",
    needsRescan: isExpired || isExpiring,
  };
}

function resolveHostFromContext(ctx: ConnectionsAndDiagViewContext): ConnectionsAndDiagHost | undefined {
  if ("host" in ctx && ctx.host) return ctx.host;
  if ("connDiagHost" in ctx && ctx.connDiagHost) return ctx.connDiagHost;
  return undefined;
}

export function renderCustomHomeTitleField(ctx: ConnectionsAndDiagViewContext): string {
  const esc = ctx.escapeHtml ? (v: string) => ctx.escapeHtml!(v) : escapeFallback;
  const host = resolveHostFromContext(ctx);
  const lang = activeLanguage(ctx.settings.interfaceLanguage);
  const session = host ? getHostConnDiagSession(host) : null;
  const customTitleValue = session?.titleDraft ?? readCustomHomeTitle(ctx.settings);
  const defaultTitlePlaceholder = host ? defaultPanelHomeTitle(host) : tr3("我的米家", "我的米家", "My Home", lang);
  return `
    <div class="cc-field" id="conn-diag-title-section" data-settings-anchor="dashboardTitle">
      <label for="settings-custom-home-title">${esc(tr3("自定义面板顶部标题", "自訂面板頂部標題", "Custom Panel Header Title", lang))}</label>
      <div style="display:flex;gap:6px;align-items:center;">
        <input id="settings-custom-home-title" class="cc-input" type="text" autocomplete="off" placeholder="${esc(defaultTitlePlaceholder)}" value="${esc(customTitleValue)}" style="flex:1;" />
        <button type="button" class="cc-btn-secondary" id="btn-save-custom-home-title">${esc(tr3("应用", "套用", "Apply", lang))}</button>
        ${readCustomHomeTitle(ctx.settings) !== "" ? `<button type="button" class="cc-inline-pill" id="btn-reset-custom-home-title">${esc(tr3("恢复默认", "恢復預設", "Reset", lang))}</button>` : ""}
      </div>
      <p class="cc-field-hint" style="margin-top:4px;">${esc(tr3("留空并点击应用将恢复默认家庭名称。", "留空並點擊套用將恢復預設家庭名稱。", "Leave blank and apply to restore the default home name.", lang))}</p>
    </div>`;
}

export function renderConnectionsAndDiagSection(
  ctx: ConnectionsAndDiagViewContext,
  options: { readonly includeDashboardTitle?: boolean } = {},
): string {
  const esc = ctx.escapeHtml ? (v: string) => ctx.escapeHtml!(v) : escapeFallback;
  const host = resolveHostFromContext(ctx);
  const lang = activeLanguage(ctx.settings.interfaceLanguage);
  const includeDashboardTitle = options.includeDashboardTitle ?? !("activeTab" in ctx);

  if (host) {
    syncConnectionContextWatcher(host);
    const s = getHostConnDiagSession(host);
    if (!s.hydratedVaultOnce && !s.hydratingVault && (hasSecondaryMiAccountsInIndex() || hasCorruptMiAccountIndex())) {
      void ensureHostMiAccountsHydrated(host);
    }
  }

  const session = host ? getHostConnDiagSession(host) : null;
  const accounts: MiAccount[] = host
    ? resolveHostMiAccounts(host)
    : ctx.settings.miSession
      ? [makeMiAccount(ctx.settings.miSession)]
      : [];
  const multiState = host ? getHostMiAccountsState(host) : null;

  const hasHAConfigured = homeAssistantIdentity(ctx.settings.haBaseURL, ctx.settings.haToken) !== null;
  const hasMiConfigured = accounts.length > 0 || hasSecondaryMiAccountsInIndex();
  const dualSupported = host
    ? canUseDualSource(host) || (hasHAConfigured && hasMiConfigured)
    : hasHAConfigured && hasMiConfigured;
  const dualChecked = host ? isDualSourceEnabled(host) : Boolean(ctx.settings.dualSourceEnabled);
  const dualState = host ? getHostDualSourceState(host) : null;

  const scanner = session?.scanner ?? null;
  const unsupportedDevices = scanner?.devices ?? [];
  const isScanning = scanner?.isScanning ?? false;
  const scanError = scanner?.errorMessage ?? null;
  const lastScannedAtMs = scanner?.lastScannedAtMs ?? null;

  const accountsPartial = host?.miAccountsStore?.getAccountsReadState() === "partial";
  const accountIndexWarningHtml = accountsPartial
    ? `<p class="cc-field-hint" data-mi-accounts-index-warning style="margin:4px 0 8px;color:#e67e22;">${esc(t("部分小米账号暂时无法读取；其他账号仍可正常使用，稍后重启或重新登录可重试。"))}</p>`
    : "";

  const selectionState = host ? resolveHostMiSelectionState(host, accounts) : null;
  const disabledSet = selectionState?.disabledAccountIds ?? new Set<string>();

  const accountCardsHtml =
    accounts.length === 0
      ? `<p class="cc-field-hint" data-mi-accounts-empty style="margin:4px 0 8px;">${esc(tr3("尚未登录米家账号。可点击下方按钮扫码添加首个或多个跨地区账号。", "尚未登入米家帳號。可點擊下方按鈕掃碼新增首個或多個跨地區帳號。", "No Xiaomi account signed in yet. Scan below to add one or multiple regional accounts.", lang))}</p>`
      : accounts
          .map((acc, index) => {
            const isEnabled = !disabledSet.has(acc.id);
            const rawStatus = getAccountTokenStatus(acc);
            const effectiveStatus: MiAccountTokenStatus =
              index === 0 && Boolean(host?.miSessionExpired) && rawStatus.kind !== "expired"
                ? { kind: "expired", source: "rejected" }
                : rawStatus;
            const childSnap = multiState?.children[acc.id];
            const disconnectReason =
              !isEnabled
                ? null
                : childSnap?.status.kind === "disconnected" && childSnap.status.reason
                  ? childSnap.status.reason
                  : effectiveStatus.kind === "expired" && miSessionExpiryState(acc.session).kind !== "expired"
                    ? tr3("米家登录已失效，请重新扫码", "米家登入已失效，請重新掃碼", "Xiaomi session expired; please rescan", lang)
                    : null;
            const { badgeHtml: activeBadgeHtml, noticeHtml, needsRescan } = renderTokenBadge(
              acc,
              effectiveStatus,
              disconnectReason,
              lang,
              esc,
            );
            const badgeHtml = isEnabled
              ? activeBadgeHtml
              : `<span class="cc-inline-pill" data-mi-account-status="disabled" style="font-size:11px;padding:2px 7px;color:#8a8f98;background:rgba(128,128,128,0.16);border:1px solid rgba(128,128,128,0.28);">${esc(tr3("已停用", "已停用", "Turned Off", lang))}</span>`;
            const preview = session?.pendingDisablePreview?.accountId === acc.id ? session.pendingDisablePreview.verdict : null;
            const previewSep = lang === "en" ? ", " : "、";
            const previewShown = preview
              ? preview.itemsToPause.slice(0, 4).map((item) => item.name).join(previewSep)
              : "";
            const previewSummary = preview && preview.itemsToPause.length > 4
              ? tr3(`${previewShown} 等`, `${previewShown} 等`, `${previewShown}, etc.`, lang)
              : previewShown;
            const disableErr = session?.disableErrorByAccountId[acc.id] ?? null;
            const disableErrHtml = disableErr
              ? `<p class="cc-field-hint" data-mi-account-disable-error="${esc(acc.id)}" style="margin:6px 0 0;color:#e74c3c;">${esc(disableErr)}</p>`
              : "";
            const previewHtml = preview
              ? `<div data-mi-account-pause-preview="${esc(acc.id)}" style="margin-top:8px;padding:8px;border-radius:8px;background:rgba(230,126,34,0.12);border:1px solid rgba(230,126,34,0.28);">
                  <p class="cc-field-hint" style="margin:0 0 6px;">${esc(tr3(`停用此账号会影响 ${preview.itemsToPause.length} 项定时、自动化或快捷动作（${previewSummary}）。暂停后不会执行，重新启用时恢复重验。`, `停用此帳號會影響 ${preview.itemsToPause.length} 項定時、自動化或捷徑動作（${previewSummary}）。暫停後不會執行，重新啟用時恢復重驗。`, `Turning off this account affects ${preview.itemsToPause.length} timer(s), automation(s), or quick action(s) (${previewSummary}). They stay paused until re-enabled.`, lang))}</p>
                  <div style="display:flex;gap:6px;justify-content:flex-end;">
                    <button type="button" class="cc-btn-secondary" data-mi-account-cancel-disable="${esc(acc.id)}" style="padding:3px 9px;font-size:11.5px;">${esc(tr3("保持开启", "保持開啟", "Keep On", lang))}</button>
                    <button type="button" class="cc-btn-primary" data-mi-account-confirm-disable="${esc(acc.id)}" style="padding:3px 9px;font-size:11.5px;">${esc(tr3("暂停这些项并关闭", "暫停這些項並關閉", "Pause & Turn Off", lang))}</button>
                  </div>
                </div>`
              : "";
            return `<div class="cc-settings-account-card" data-mi-account-card="${esc(acc.id)}" style="padding:8px 10px;margin-bottom:6px;border-radius:10px;background:rgba(128,128,128,0.08);border:1px solid rgba(128,128,128,0.14);">
              <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
                <strong style="font-size:12.5px;">${esc(acc.displayName)}</strong>
                <span class="cc-inline-pill" style="font-size:11px;padding:1px 6px;">${esc(miCloudRegionLabel(acc.region))} (${esc(acc.region)})</span>
                ${badgeHtml}
                <div style="margin-left:auto;display:flex;gap:8px;align-items:center;">
                  <label style="display:inline-flex;align-items:center;gap:4px;margin:0;font-size:11.5px;cursor:pointer;">
                    <span>${esc(tr3("连接", "連線", "Connected", lang))}</span>
                    <input type="checkbox" data-mi-account-enabled="${esc(acc.id)}" ${isEnabled && !preview ? "checked" : ""} />
                  </label>
                  ${isEnabled && needsRescan ? `<button type="button" class="cc-inline-pill" data-mi-account-rescan="${esc(acc.id)}" data-mi-account-region="${esc(acc.region)}">${esc(tr3("重新扫码", "重新掃碼", "Rescan", lang))}</button>` : ""}
                  <button type="button" class="cc-btn-danger" data-mi-account-signout="${esc(acc.id)}"${session && session.signingOutAccountIds.size > 0 ? " disabled" : ""} style="padding:3px 9px;font-size:11.5px;">${esc(tr3("退出", "登出", "Sign Out", lang))}</button>
                </div>
              </div>
              ${noticeHtml}
              ${disableErrHtml}
              ${previewHtml}
            </div>`;
          })
          .join("");

  const addQr = session?.addQr;
  const addQrBusy = addQr?.phase === "loading" || addQr?.phase === "waiting";
  const addQrHtml = addQr?.open
    ? `<div id="conn-diag-add-qr-box" class="cc-qr-box" style="margin-top:8px;padding:10px;border-radius:10px;background:rgba(128,128,128,0.08);">
        <div class="cc-field-row" style="gap:8px;margin-bottom:8px;">
          <label for="conn-diag-add-region" style="margin:0;font-size:12px;">${esc(tr3("新账号所属地区", "新帳號所屬地區", "Account Region", lang))}</label>
          <select id="conn-diag-add-region" class="cc-input" style="width:auto;margin-left:auto;">
            ${MI_CLOUD_REGIONS.map((reg) => `<option value="${esc(reg.code)}" ${addQr.region === reg.code ? "selected" : ""}>${esc(reg.label)} (${esc(reg.code)})</option>`).join("")}
          </select>
        </div>
        ${addQr.ticket ? `<div class="cc-qr-frame" style="margin:6px auto;"><img src="${esc(addQr.ticket.qrImageURL)}" alt="Add Xiaomi Account QR" /></div>` : ""}
        ${addQr.statusText ? `<div class="cc-qr-status" id="conn-diag-add-qr-status">${esc(addQr.statusText)}</div>` : ""}
        <div style="display:flex;gap:6px;justify-content:flex-end;margin-top:8px;">
          <button type="button" class="cc-btn-secondary" id="btn-cancel-add-mi-qr">${esc(tr3("取消", "取消", "Cancel", lang))}</button>
          <button type="button" class="cc-btn-primary" id="btn-start-add-mi-qr" ${addQrBusy ? "disabled" : ""}>${esc(addQrBusy ? tr3("等待扫码确认…", "等待掃碼確認…", "Waiting for scan…", lang) : tr3("获取登录二维码", "取得登入 QR Code", "Get QR Code", lang))}</button>
        </div>
      </div>`
    : "";

  const pairedCount = dualState ? dualState.pairedDeviceIds.size : 0;
  const dualHint =
    dualChecked && pairedCount > 0
      ? tr3(
          `双源融合运行中 · 已自动配对去重 ${pairedCount} 台同体设备（右键卡片可锁定单设备数据源）`,
          `雙源融合執行中 · 已自動配對去重 ${pairedCount} 台同體裝置（右鍵卡片可鎖定單一裝置資料來源）`,
          `Dual-source active · ${pairedCount} paired device(s) deduplicated (right-click a card to pin source)`,
          lang,
        )
      : dualSupported
        ? tr3(
            "开启后同屏合并 HA 与米家设备并按 DID/MAC 自动去重；右键合并卡片可固定优先源。",
            "開啟後同屏合併 HA 與米家裝置並依 DID/MAC 自動去重；右鍵合併卡片可固定優先來源。",
            "Merges HA and Xiaomi devices on one dashboard with automatic DID/MAC deduplication.",
            lang,
          )
        : tr3(
            "需同时配置 Home Assistant 地址/令牌并登录至少一个米家账号后可开启。",
            "需同時設定 Home Assistant 位址/權杖並登入至少一個米家帳號後可開啟。",
            "Configure both Home Assistant URL/token and at least one Xiaomi account to enable.",
            lang,
          );

  return `
    <div id="connections-and-diag-root" style="display:flex;flex-direction:column;gap:12px;">
      ${renderHaDisconnectRowHtml(ctx, host, session, esc)}

      <details class="cc-conn-secondary" data-conn-section="advancedConnectionOptions">
        <summary class="cc-conn-secondary-summary">${esc(tr3("高级连接选项", "進階連線選項", "Advanced Connection Options", lang))}</summary>
        <div style="display:flex;flex-direction:column;gap:12px;">
          <div class="cc-field" id="conn-diag-accounts-section" data-settings-anchor="miMultiAccounts">
            <div class="cc-field-row" style="margin-bottom:6px;">
              <label style="margin:0;font-weight:600;">${esc(tr3("连接 · 米家多账号管理", "連線 · 米家多帳號管理", "Connections · Xiaomi Multi-Account", lang))}</label>
              <span class="cc-field-hint" style="margin:0;">${esc(tr3(`已登录 ${accounts.length} 个账号`, `已登入 ${accounts.length} 個帳號`, `${accounts.length} signed in`, lang))}</span>
            </div>
            ${accountCardsHtml}
            ${accountIndexWarningHtml}
            <div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:4px;">
              <button type="button" class="cc-btn-secondary" id="btn-add-mi-account">${esc(tr3("＋ 添加更多米家账号", "＋ 新增更多米家帳號", "+ Add More Xiaomi Accounts", lang))}</button>
            </div>
            ${addQrHtml}
          </div>

          <div class="cc-field" id="conn-diag-dual-ha-section" data-settings-anchor="dualSourceFusion">
            <label class="cc-switch-row" for="settings-dual-source-enabled">
              <span>${esc(tr3("同时连接多个家居平台（相同设备自动合并）", "同時連接多個家居平台（相同裝置自動合併）", "Connect Multiple Home Platforms Simultaneously (Auto-Merge Identical Devices)", lang))}</span>
              <input id="settings-dual-source-enabled" type="checkbox" ${dualChecked ? "checked" : ""} ${dualSupported || dualChecked ? "" : "disabled"} />
            </label>
            <p class="cc-field-hint" style="margin-top:4px;">${esc(dualHint)}</p>
          </div>
          ${includeDashboardTitle ? renderCustomHomeTitleField(ctx) : ""}
        </div>
      </details>

      <details class="cc-conn-secondary" data-conn-section="diagnosticsAndScanner">
        <summary class="cc-conn-secondary-summary">${esc(tr3("设备扫描与排障信息", "裝置掃描與排障資訊", "Device Scan & Diagnostics", lang))}</summary>
        <div style="display:flex;flex-direction:column;gap:12px;">
          <div class="cc-field" id="conn-diag-scanner-section" data-settings-anchor="scanUnsupportedDevices">
            <div class="cc-field-row" style="gap:8px;flex-wrap:wrap;">
              <label style="margin:0;font-weight:600;">${esc(tr3("未能显示在面板的设备", "未能顯示在面板的裝置", "Devices Not Shown in Panel", lang))}</label>
              <button type="button" class="cc-btn-secondary" id="btn-scan-unsupported-devices" style="margin-left:auto;" ${isScanning ? "disabled" : ""}>${esc(isScanning ? tr3("正在扫描…", "正在掃描…", "Scanning…", lang) : tr3("扫描未能显示的设备", "掃描未能顯示的裝置", "Scan Hidden Devices", lang))}</button>
            </div>
            <p class="cc-field-hint" style="margin-top:4px;">${esc(tr3("遍历所有已登录米家账号及活跃后端，列出未识别型号与跳过原因，并提供零隐私泄露的适配反馈链接。", "遍歷所有已登入米家帳號及活躍後端，列出未識別型號與略過原因，並提供零隱私洩漏的適配回饋連結。", "Scans all signed-in Xiaomi accounts and active backends for skipped models with desensitized GitHub feedback links.", lang))}</p>
            ${scanError ? `<p class="cc-field-hint" id="conn-diag-scan-error" style="color:#e67e22;margin-top:4px;">${esc(scanError)}</p>` : ""}
            ${!isScanning && lastScannedAtMs !== null && unsupportedDevices.length === 0 && !scanError ? `<p class="cc-field-hint" id="conn-diag-scan-empty" style="color:#2ecc71;margin-top:4px;">${esc(tr3("未发现未能显示的设备", "未發現未能顯示的裝置", "No skipped devices found", lang))}</p>` : ""}
            ${
              unsupportedDevices.length > 0
                ? `<div id="conn-diag-unsupported-list" style="display:flex;flex-direction:column;gap:6px;margin-top:6px;">
                    ${unsupportedDevices
                      .map((item) => {
                        const specLine = item.specSummary ? formatSpecSummaryText(item.specSummary) : "";
                        const modelText = item.model || tr3("未知型号", "未知型號", "Unknown model", lang);
                        return `<div data-unsupported-device-row="${esc(item.model)}" style="padding:7px 9px;border-radius:8px;background:rgba(128,128,128,0.08);display:flex;align-items:flex-start;gap:8px;flex-wrap:wrap;">
                          <div style="flex:1;min-width:160px;">
                            <div style="font-size:12px;font-weight:600;">${esc(item.name)}</div>
                            <div class="cc-field-hint" style="margin:2px 0 0;"><code>${esc(modelText)}</code> · ${esc(item.reasonText)}${specLine ? ` · ${esc(specLine)}` : ""}</div>
                          </div>
                          ${item.feedbackURL ? `<a class="cc-inline-pill" data-feedback-issue-url="${esc(item.feedbackURL)}" href="${esc(item.feedbackURL)}" target="_blank" rel="noopener noreferrer" style="text-decoration:none;align-self:center;">${esc(tr3("提交适配反馈（GitHub Issue）", "提交適配回饋（GitHub Issue）", "Report on GitHub", lang))}</a>` : ""}
                        </div>`;
                      })
                      .join("")}
                  </div>`
                : ""
            }
          </div>

          <div class="cc-field" id="conn-diag-diagnostics-section" data-settings-anchor="copyDiagnostics">
            <div class="cc-field-row" style="gap:8px;flex-wrap:wrap;">
              <label style="margin:0;font-weight:600;">${esc(tr3("脱敏诊断报告", "去識別化診斷報告", "Desensitized Diagnostics", lang))}</label>
              <div style="margin-left:auto;display:flex;gap:6px;align-items:center;">
                ${session?.diagCopied ? `<span id="conn-diag-copied-badge" class="cc-field-hint" style="margin:0;color:#2ecc71;">${esc(tr3("已复制", "已複製", "Copied", lang))}</span>` : ""}
                <button type="button" class="cc-btn-primary" id="btn-copy-diagnostics-report">${esc(tr3("复制脱敏诊断报告", "複製去識別化診斷報告", "Copy Diagnostics Report", lang))}</button>
              </div>
            </div>
            <p class="cc-field-hint" style="margin-top:4px;">${esc(tr3("导出含版本、后端、设备型号计数、摄像机流模式、轮询退避与错误计数的 Markdown 摘要，绝不包含令牌、DID、IP/MAC 或家庭名称。", "匯出含版本、後端、裝置型號計數、攝影機串流模式、輪詢退避與錯誤計數的 Markdown 摘要，絕不包含權杖、DID、IP/MAC 或家庭名稱。", "Exports Markdown with version, backend, model counts, camera stream modes, and error counts — zero tokens, DIDs, IPs/MACs, or home names.", lang))}</p>
            ${session?.diagMarkdownPreview ? `<textarea id="conn-diag-markdown-preview" class="cc-input" readonly rows="7" style="margin-top:6px;width:100%;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:11px;resize:vertical;">${esc(session.diagMarkdownPreview)}</textarea>` : ""}
          </div>
        </div>
      </details>
    </div>`;
}

export function renderConnectionsAndDiagModal(host: ConnectionsAndDiagHost): string {
  if (!isConnectionsAndDiagModalOpen(host)) return "";
  const esc = host.escapeHtml ? (v: string) => host.escapeHtml!(v) : escapeFallback;
  const lang = activeLanguage(host.settings.interfaceLanguage);
  return `
    <div class="cc-sheet-backdrop" id="conn-diag-modal-backdrop">
      <div class="cc-sheet" id="conn-diag-modal" tabindex="-1" role="dialog" aria-modal="true" aria-label="${esc(tr3("多账号、双源与诊断", "多帳號、雙源與診斷", "Accounts, Dual-Source & Diagnostics", lang))}" style="max-height:86vh;display:flex;flex-direction:column;">
        <div class="cc-sheet-header">
          <div class="cc-sheet-badge">${esc(tr3("多账号 · 双源融合 · 诊断中心", "多帳號 · 雙源融合 · 診斷中心", "Accounts · Dual-Source · Diagnostics", lang))}</div>
          <button type="button" class="cc-circle-btn is-small" id="btn-close-conn-diag-modal" aria-label="${esc(tr3("关闭", "關閉", "Close", lang))}">${SF_ICONS.xmark}</button>
        </div>
        <div class="cc-sheet-body" style="overflow-y:auto;padding-right:2px;">
          ${renderConnectionsAndDiagSection({ settings: host.settings, devices: host.devices, host, escapeHtml: esc }, { includeDashboardTitle: true })}
        </div>
      </div>
    </div>`;
}

function bindElementListener<E extends HTMLElement, K extends keyof HTMLElementEventMap>(
  node: E | null | undefined,
  type: K,
  handler: (el: E, event: HTMLElementEventMap[K]) => void,
): void {
  if (!node) return;
  node.addEventListener(type, (rawEvent) => {
    const evTarget = rawEvent.target as HTMLElement | null;
    if (evTarget?.closest?.("[data-exit-ghost]")) return;
    handler(node, rawEvent as HTMLElementEventMap[K]);
  });
}

function renderHaDisconnectRowHtml(
  ctx: ConnectionsAndDiagViewContext,
  host: ConnectionsAndDiagHost | undefined,
  session: HostConnDiagSession | null,
  esc: (v: string) => string,
): string {
  const lang = activeLanguage(ctx.settings.interfaceLanguage);
  const hasHAToken = ctx.settings.haToken.trim() !== "";
  const hasHAUrl = ctx.settings.haBaseURL.trim() !== "";
  const hasHAConfigured = homeAssistantIdentity(ctx.settings.haBaseURL, ctx.settings.haToken) !== null;
  const dualChecked = host ? isDualSourceEnabled(host) : Boolean(ctx.settings.dualSourceEnabled);
  const currentHaScope = haConnectionScope(ctx.settings.haBaseURL, ctx.settings.haToken);
  const haPhase = host ? getHostHaLifecyclePhase(host) : getHaScopeLifecyclePhase(currentHaScope);
  const haEnabled = host ? isHostHaEnabled(host) : !isHaScopeDisabledInStorage(currentHaScope);
  const haPreview =
    currentHaScope && session?.pendingHaDisablePreview?.scope === currentHaScope
      ? session.pendingHaDisablePreview.verdict
      : null;
  const haPreviewSep = lang === "en" ? ", " : "、";
  const haPreviewShown = haPreview
    ? haPreview.itemsToPause.slice(0, 4).map((item) => item.name).join(haPreviewSep)
    : "";
  const haPreviewSummary =
    haPreview && haPreview.itemsToPause.length > 4
      ? tr3(`${haPreviewShown} 等`, `${haPreviewShown} 等`, `${haPreviewShown}, etc.`, lang)
      : haPreviewShown;
  const haDisableErr = session?.haDisableError ?? null;
  const haDisableUiEnabled = isHostHaDisableUiEnabled(host);
  const haCheckboxBusy = haPhase === "stopping" || haPhase === "stop_timeout";
  const showHaStatusRow = hasHAConfigured && (haDisableUiEnabled || !haEnabled || haPhase !== "enabled");
  const haStatusBadgeHtml = showHaStatusRow
    ? haPhase === "stop_timeout"
      ? `<span class="cc-inline-pill" data-ha-connection-status="stop_timeout" style="font-size:11px;padding:2px 7px;color:#e67e22;background:rgba(230,126,34,0.16);border:1px solid rgba(230,126,34,0.36);">${esc(tr3("还在停止 · 重试", "還在停止 · 重試", "Still stopping · Retry", lang))}</span>`
      : haPhase === "stopping"
        ? `<span class="cc-inline-pill" data-ha-connection-status="stopping" style="font-size:11px;padding:2px 7px;color:#e67e22;background:rgba(230,126,34,0.14);border:1px solid rgba(230,126,34,0.32);">${esc(tr3("正在停止", "正在停止", "Stopping", lang))}</span>`
        : !haEnabled || haPhase === "disabled"
          ? `<span class="cc-inline-pill" data-ha-connection-status="disabled" style="font-size:11px;padding:2px 7px;color:#8a8f98;background:rgba(128,128,128,0.16);border:1px solid rgba(128,128,128,0.28);">${esc(tr3("已停用", "已停用", "Turned Off", lang))}</span>`
          : `<span class="cc-inline-pill" data-ha-connection-status="enabled" style="font-size:11px;padding:2px 7px;color:#2ecc71;background:rgba(46,204,113,0.12);border:1px solid rgba(46,204,113,0.28);">${esc(tr3("状态正常", "狀態正常", "Active", lang))}</span>`
    : "";
  const haDisableErrHtml = haDisableErr
    ? `<p class="cc-field-hint" data-ha-disable-error style="margin:6px 0 0;width:100%;color:#e74c3c;">${esc(haDisableErr)}</p>`
    : "";
  const haPreviewHtml = haPreview
    ? `<div data-ha-pause-preview style="margin-top:8px;width:100%;padding:8px;border-radius:8px;background:rgba(230,126,34,0.12);border:1px solid rgba(230,126,34,0.28);">
        <p class="cc-field-hint" style="margin:0 0 6px;">${esc(tr3(`停用 Home Assistant 会影响 ${haPreview.itemsToPause.length} 项定时、自动化或快捷动作（${haPreviewSummary}）。暂停后不会执行，重新启用时恢复重验。`, `停用 Home Assistant 會影響 ${haPreview.itemsToPause.length} 項定時、自動化或捷徑動作（${haPreviewSummary}）。暫停後不會執行，重新啟用時恢復重驗。`, `Turning off Home Assistant affects ${haPreview.itemsToPause.length} timer(s), automation(s), or quick action(s) (${haPreviewSummary}). They stay paused until re-enabled.`, lang))}</p>
        <div style="display:flex;gap:6px;justify-content:flex-end;">
          <button type="button" class="cc-btn-secondary" data-ha-cancel-disable style="padding:3px 9px;font-size:11.5px;">${esc(tr3("保持开启", "保持開啟", "Keep On", lang))}</button>
          <button type="button" class="cc-btn-primary" data-ha-confirm-disable style="padding:3px 9px;font-size:11.5px;">${esc(tr3("暂停这些项并关闭", "暫停這些項並關閉", "Pause & Turn Off", lang))}</button>
        </div>
      </div>`
    : "";
  const haDisconnectHint = hasHAToken
    ? haPhase === "stop_timeout"
      ? tr3(
          "Home Assistant 还在停止：上一轮请求长时间未返回，可点击「还在停止 · 重试」完成停用或直接重新启用。",
          "Home Assistant 還在停止：上一輪請求長時間未返回，可點擊「還在停止 · 重試」完成停用或直接重新啟用。",
          "Home Assistant is still stopping: an earlier request has not returned. Click 'Still stopping · Retry' to finish stopping or re-enable directly.",
          lang,
        )
      : haPhase === "stopping"
        ? tr3(
            "Home Assistant 正在停止：等待在途请求结束后完成停用。",
            "Home Assistant 正在停止：等待在途請求結束後完成停用。",
            "Home Assistant is stopping: waiting for in-flight requests to settle.",
            lang,
          )
        : !haEnabled
          ? tr3(
              "Home Assistant 已停用 · 重新启用后恢复同步并重验受影响的定时与自动化（服务器地址与令牌已保留）。",
              "Home Assistant 已停用 · 重新啟用後恢復同步並重驗受影響的定時與自動化（伺服器位址與權杖已保留）。",
              "Home Assistant is turned off · Re-enable to resume sync and revalidate paused items (URL & token kept).",
              lang,
            )
          : tr3(
              "独立断开 Home Assistant：清除 HA 令牌并自动切回米家单源（未登录米家时清空残留设备）。",
              "獨立中斷 Home Assistant：清除 HA 權杖並自動切回米家單源（未登入米家時清空殘留裝置）。",
              "Disconnect HA independently: clears HA token and falls back to Xiaomi Cloud (or clears devices if signed out).",
              lang,
            )
    : hasHAUrl
      ? tr3(
          "Home Assistant 令牌未连接（保留服务器地址以便后续重连）。",
          "Home Assistant 權杖未連線（保留伺服器位址以便後續重連）。",
          "Home Assistant token disconnected (server URL kept for reconnecting).",
          lang,
        )
      : tr3("当前未连接 Home Assistant。", "目前未連線 Home Assistant。", "Home Assistant is not connected.", lang);

  return `<div class="cc-field" id="conn-diag-ha-disconnect-row" data-settings-anchor="haDisconnect" style="display:flex;flex-direction:column;gap:6px;">
        ${
          showHaStatusRow
            ? `<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
                <strong style="font-size:12.5px;">Home Assistant</strong>
                ${haStatusBadgeHtml}
                <div style="margin-left:auto;display:flex;gap:8px;align-items:center;">
                  ${
                    haDisableUiEnabled
                      ? `<label style="display:inline-flex;align-items:center;gap:4px;margin:0;font-size:11.5px;cursor:${haCheckboxBusy ? "not-allowed" : "pointer"};">
                          <span>${esc(tr3("连接", "連線", "Connected", lang))}</span>
                          <input type="checkbox" data-ha-connection-enabled ${haEnabled && !haCheckboxBusy ? "checked" : ""} ${haCheckboxBusy ? "disabled" : ""} />
                        </label>`
                      : ""
                  }
                  ${haPhase === "stop_timeout" ? `<button type="button" class="cc-inline-pill" data-ha-stop-retry>${esc(tr3("还在停止 · 重试", "還在停止 · 重試", "Still stopping · Retry", lang))}</button>` : ""}
                  ${!haEnabled && haPhase !== "stopping" ? `<button type="button" class="cc-inline-pill" data-ha-reenable>${esc(tr3("重新启用", "重新啟用", "Re-enable", lang))}</button>` : ""}
                </div>
              </div>`
            : ""
        }
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <span class="cc-field-hint" style="margin:0;flex:1;">${esc(haDisconnectHint)}</span>
          <button type="button" class="cc-btn-danger" id="btn-disconnect-ha" ${hasHAToken || ctx.settings.connectionMode === "homeAssistant" || dualChecked ? "" : "disabled"}>${esc(tr3("断开连接", "中斷連線", "Disconnect", lang))}</button>
        </div>
        ${haDisableErrHtml}
        ${haPreviewHtml}
      </div>`;
}

function bindHaDisconnectRowScope(host: ConnectionsAndDiagHost, scopeRoot: ParentNode): void {
  const session = getHostConnDiagSession(host);
  const onClick = (sel: string, fn: () => void) =>
    bindElementListener(scopeRoot.querySelector<HTMLButtonElement>(sel), "click", () => fn());

  const haEnabledBox = scopeRoot.querySelector<HTMLInputElement>("[data-ha-connection-enabled]");
  if (haEnabledBox) {
    haEnabledBox.checked = haEnabledBox.hasAttribute("checked");
    bindElementListener(haEnabledBox, "change", (el) => {
      if (el.disabled) return;
      void setHaConnectionEnabledOnHost(host, el.checked);
    });
  }
  onClick("[data-ha-stop-retry]", () => {
    retryTimedOutHaStopOnHost(host);
  });
  onClick("[data-ha-reenable]", () => {
    void setHaConnectionEnabledOnHost(host, true);
  });
  onClick("[data-ha-confirm-disable]", () => {
    void setHaConnectionEnabledOnHost(host, false, { confirmPause: true });
  });
  onClick("[data-ha-cancel-disable]", () => {
    session.pendingHaDisablePreview = null;
    host.render();
  });
  onClick("#btn-disconnect-ha", () => void disconnectHomeAssistantOnHost(host));
}

export function syncHaDisconnectRowOnHost(host: ConnectionsAndDiagHost): void {
  const existingRow = host.root.querySelector<HTMLElement>("#conn-diag-ha-disconnect-row");
  if (!existingRow) return;
  const session = getHostConnDiagSession(host);
  const hostEsc = host.escapeHtml;
  const esc = hostEsc ? (v: string) => hostEsc.call(host, v) : escapeFallback;
  const wrapper = document.createElement("div");
  wrapper.innerHTML = renderHaDisconnectRowHtml(
    { settings: host.settings, devices: host.devices, host, escapeHtml: esc },
    host,
    session,
    esc,
  );
  const nextRow = wrapper.firstElementChild as HTMLElement | null;
  if (!nextRow) return;
  existingRow.replaceWith(nextRow);
  bindHaDisconnectRowScope(host, nextRow);
}

export function bindConnectionsAndDiagEvents(host: ConnectionsAndDiagHost): void {
  const session = getHostConnDiagSession(host);
  syncConnectionContextWatcher(host);
  if (host.activeSheet === "none" && !isConnectionsAndDiagModalOpen(host) && session.addQr.open) {
    cancelAddAccountQrFlow(host, false);
  }
  const onClick = (sel: string, fn: () => void) =>
    bindElementListener(host.root.querySelector<HTMLButtonElement>(sel), "click", () => fn());

  bindHaDisconnectRowScope(host, host.root);

  host.root.querySelectorAll<HTMLInputElement>("[data-mi-account-enabled]").forEach((box) => {
    box.checked = box.hasAttribute("checked");
    bindElementListener(box, "change", (el) => {
      const targetAccountId = el.dataset.miAccountEnabled;
      if (!targetAccountId) return;
      void setMiAccountEnabledOnHost(host, targetAccountId, el.checked);
    });
  });
  host.root.querySelectorAll<HTMLButtonElement>("[data-mi-account-confirm-disable]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      const targetAccountId = el.dataset.miAccountConfirmDisable;
      if (!targetAccountId) return;
      void setMiAccountEnabledOnHost(host, targetAccountId, false, { confirmPause: true });
    });
  });
  host.root.querySelectorAll<HTMLButtonElement>("[data-mi-account-cancel-disable]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      const targetAccountId = el.dataset.miAccountCancelDisable;
      if (!targetAccountId) return;
      if (session.pendingDisablePreview?.accountId === targetAccountId) {
        session.pendingDisablePreview = null;
      }
      host.render();
    });
  });
  host.root.querySelectorAll<HTMLButtonElement>("[data-mi-account-signout]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      const targetAccountId = el.dataset.miAccountSignout;
      if (!targetAccountId || el.disabled) return;
      el.disabled = true;
      void signOutSingleMiAccountOnHost(host, targetAccountId);
    });
  });
  host.root.querySelectorAll<HTMLButtonElement>("[data-mi-account-rescan]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      session.addQr.region = normalizeMiCloudRegion(el.dataset.miAccountRegion);
      session.addQr.open = true;
      void startAddAccountQrFlow(host);
    });
  });
  onClick("#btn-add-mi-account", () => {
    session.addQr.open = true;
    session.addQr.region = normalizeMiCloudRegion(host.settings.miCloudRegion);
    void startAddAccountQrFlow(host);
  });
  bindElementListener(host.root.querySelector<HTMLSelectElement>("#conn-diag-add-region"), "change", (sel) => {
    session.addQr.region = normalizeMiCloudRegion(sel.value);
    if (session.addQr.open) void startAddAccountQrFlow(host);
  });
  onClick("#btn-start-add-mi-qr", () => void startAddAccountQrFlow(host));
  onClick("#btn-cancel-add-mi-qr", () => cancelAddAccountQrFlow(host, true));
  bindElementListener(
    host.root.querySelector<HTMLInputElement>("#settings-dual-source-enabled"),
    "change",
    (box) => {
      void toggleDualSourceOnHost(host, box.checked);
    },
  );
  const titleInput = host.root.querySelector<HTMLInputElement>("#settings-custom-home-title");
  bindElementListener(titleInput, "input", (input) => {
    session.titleDraft = input.value;
  });
  bindElementListener(titleInput, "keydown", (input, event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
      writeCustomHomeTitle(host, input.value);
    }
  });
  onClick("#btn-save-custom-home-title", () => {
    writeCustomHomeTitle(
      host,
      host.root.querySelector<HTMLInputElement>("#settings-custom-home-title")?.value ?? "",
    );
  });
  onClick("#btn-reset-custom-home-title", () => writeCustomHomeTitle(host, ""));
  onClick("#btn-scan-unsupported-devices", () => void runUnsupportedDevicesScanOnHost(host));
  host.root.querySelectorAll<HTMLAnchorElement>("[data-feedback-issue-url]").forEach((link) => {
    bindElementListener(link, "click", (el, event) => {
      const url = el.dataset.feedbackIssueUrl;
      const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
      if (url && invoke) {
        event.preventDefault();
        invokeTauriVoid("open_release_page", { url });
      }
    });
  });
  onClick("#btn-copy-diagnostics-report", () => void copyDiagnosticsReportOnHost(host));
  const haUrlInput = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
  const syncHaUrlControls = (val: string) => {
    const warnEl = host.root.querySelector<HTMLElement>("[data-ha-plaintext-warning]");
    if (warnEl) warnEl.hidden = !isPlainHttpRemoteEndpoint(val);
    const fillBtn = host.root.querySelector<HTMLButtonElement>("#btn-fill-default-ha");
    if (fillBtn) fillBtn.disabled = val.trim().length > 0;
  };
  bindElementListener(haUrlInput, "input", (input) => {
    syncHaUrlControls(input.value);
  });
  onClick("#btn-fill-default-ha", () => {
    const input = host.root.querySelector<HTMLInputElement>("#settings-ha-url");
    if (!input || input.value.trim().length > 0) return;
    input.value = "http://homeassistant.local:8123";
    syncHaUrlControls(input.value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

export function bindConnectionsAndDiagPanelEvents(host: ConnectionsAndDiagHost): void {
  host.root.querySelectorAll<HTMLButtonElement>("[data-open-conn-diag]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      const raw = el.dataset.openConnDiag;
      const section: ConnDiagModalSection =
        raw === "title" || raw === "scanner" || raw === "diagnostics" ? raw : "accounts";
      openConnectionsAndDiagModal(host, section);
      if (section === "diagnostics") void copyDiagnosticsReportOnHost(host);
    });
  });
  host.root.querySelectorAll<HTMLButtonElement>("[data-pin-device-source]").forEach((btn) => {
    bindElementListener(btn, "click", (el) => {
      const deviceId = el.dataset.pinDeviceId;
      const choice = el.dataset.pinDeviceSource;
      if (!deviceId || !choice) return;
      const backend: HomeBackend | null =
        choice === "homeAssistant" || choice === "xiaomiCloud" ? choice : null;
      host.ctxMenu = null;
      if (isFullPanelHost(host) && isDualSourceEnabled(host)) {
        setHostDeviceSourcePin(host, deviceId, backend);
        recomputeHostDualSource(host);
      }
      host.render();
    });
  });
  bindElementListener(
    host.root.querySelector<HTMLButtonElement>("#btn-close-conn-diag-modal"),
    "click",
    () => closeConnectionsAndDiagModal(host),
  );
  bindElementListener(
    host.root.querySelector<HTMLElement>("#conn-diag-modal-backdrop"),
    "pointerdown",
    (backdrop, event) => {
      if (event.target === backdrop) {
        event.preventDefault();
        closeConnectionsAndDiagModal(host);
      }
    },
  );
  bindElementListener(
    host.root.querySelector<HTMLElement>("#conn-diag-modal"),
    "keydown",
    (_modal, event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        closeConnectionsAndDiagModal(host);
      }
    },
  );
}
