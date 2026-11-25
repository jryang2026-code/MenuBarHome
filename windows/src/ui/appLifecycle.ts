import { finishPanelComposition, handlePanelKey } from "./panelKeyboard.js";
import { handleSettingsSheetEscape } from "./settingsEvents.js";
import { switchSource } from "./sourceSwitch.js";
import { processScheduledCommands, scheduledCommandIdentity } from "./scheduledCommands.js";
import { ScheduledCommandStore, isScheduledCommandsEnabled } from "../core/scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { resetLocalMiIOHealth } from "../core/miCloud/localMiIO.js";
import { t } from "../core/i18n.js";
import { isHostAttachedToActiveWindow, type OptimisticLockRootLike } from "../core/optimisticLock.js";
import {
  UPDATE_RELEASES_PAGE,
  UPDATE_RELEASES_URL,
  UPDATE_STORAGE_KEY,
  checkForUpdate,
  isNewerVersion,
  loadOrCreateUpdateInstallId,
  parseUpdateState,
  serializeUpdateState,
} from "../core/updateChecker.js";
import { credentialsFromSettings, hasCredentials } from "../core/secureStore.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import {
  assistantEndpointIdentity,
  inferAssistantPreset,
  isProactiveSuggestionsEnabled,
} from "../core/assistant.js";
import { applyFreshInstallFeatureSwitches, isEventAutomationEnabled } from "../core/freshInstallDefaults.js";
import { setLanguage, resolveLanguage } from "../core/i18n.js";
import { applyTemperatureUnit } from "../core/temperature.js";
import { cloudRefreshDue, cloudRefreshIntervalMs } from "../core/pollingPolicy.js";
import { notePanelInteraction, pollingDecayInputs } from "./pollingSchedule.js";
import {
  MAX_CUSTOM_HOTKEY_BINDINGS,
  decodeHotkeyTargetKey,
  executeCustomHotkeyBinding,
  normalizeCustomHotkeyBindings,
  validateCustomHotkeyShortcut,
  type HotkeyBinding,
} from "./hotkeyBindings.js";
import { quickActionTitle } from "../core/quickActions.js";
import { normalizeGlobalShortcut, recordShortcutFromKeyEvent, tr3 } from "./panelPrefs.js";
import { APP_VERSION } from "./appConstants.js";
import { invokeTauriVoid } from "./transport.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { loadSettings, stripCredentialFieldsFromStoredCopies, evaluateLegacyOnboardingMigration, writeSettingsForStorage } from "./settings.js";
import { normalizeSettingsTab, type SettingsTab } from "./settingsViews.js";
import {
  clearSettingsHighlight,
  highlightSettingsAnchor,
  normalizeSettingsAnchor,
  type SettingsAnchor,
} from "./settingsSearch.js";
import {
  clearHostActivitiesOnSignOut,
  collapseActivityStackOnHide,
  dispatchSystemContextEvent,
  getHostActivityCenter,
  isFullPanelHost,
  nextBackgroundActivityCadenceMs,
  notifyDisplayPowerChanged,
  notifyFocusModeChanged,
  notifyMediaCaptureChanged,
  notifyPanelWakeLifecycle,
  notifySystemSleep,
  notifySystemWake,
  syncSystemEventWatchers,
  tickSafetyHealthAndAutomation,
} from "./activityStackView.js";
import { proactiveHasConsumer } from "./proactive.js";
import { appDiagnosticsLog } from "../core/diagnosticsAndScanner.js";
import {
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY,
  DUAL_SOURCE_ENABLED_STORAGE_KEY,
  PINNED_DEVICE_SOURCES_STORAGE_KEY,
  ROOM_IDENTITY_REGISTRY_STORAGE_KEY,
} from "../core/dualSourceProvider.js";
import {
  clearAccountRateLimitBackoff,
  hasCorruptMiAccountIndex,
  hasSecondaryMiAccountsInIndex,
  makeMiAccount,
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
  readAccountIndex,
} from "../core/miAccountsStore.js";
import type { MiSession } from "../core/miCloudClient.js";
import { AutomationRuleStore } from "../core/automationEngine.js";
import { removeDisconnectedHaFromSelection, removeSignedOutMiAccountFromSelection, revalidateAfterMiAccountReenable } from "../core/miAccountControl.js";
import { clearHaScopeLifecycle, getHaScopeLifecyclePhase, haConnectionScope, syncHaNativeConnection } from "../core/haTransportGate.js";
import {
  haConnectionRemovalScope,
  isConnectionRemovalPending,
  miConnectionRemovalScope,
} from "../core/connectionRemoval.js";
import { clearCachedXiaomiTopology, clearPersistedMiSessionExpired } from "../core/pollingPolicy.js";
import {
  buildHostCapabilityContext,
  haCacheIfEnabled,
  isDualSourceEnabled,
  isHostHaEnabled,
  isHostMiSessionEnabled,
  resolveEnabledMiAccountsForHost,
  resolveHostMiSelectionState,
  type DualSourceInspectableHost,
} from "./cloudRefresh.js";
import { finishAllMiAccountsSignedOutOnHost } from "./connectionsAndDiagView.js";
import {
  clearUpdateProgress,
  didMiExpiryKindChange,
  dismissPendingUrlConfirmation,
  hasPendingMiVaultDeletion,
  hasPendingUrlConfirmation,
  isUndoHoverPaused,
  resumeUndoHoverPause,
  runWithScheduledTimerTickExemption,
  setPendingMiVaultDeletion,
  shouldKeepPopoverPinned,
} from "./speechGuard.js";

export { dispatchSystemContextEvent };

  /**
   * First run after this version: move the plaintext copy into the Windows Credential
   * Manager, then rewrite localStorage without secrets (#28). Later runs read only the
   * credential store, so an upgrade needs no QR login again.
   */
export function initializeCredentials(
  host: MenuMijiaWindowsApp,
  options: { readonly overwriteExisting?: boolean } = {},
): Promise<void> {
    const initialKey = host.settings.openRouterApiKey.trim();
    const initialIdentity = assistantEndpointIdentity(host.settings.assistantBaseURL);
    if (initialKey !== "" && initialIdentity !== null && initialIdentity === host.settings.assistantKeyEndpoint) {
      const preset = inferAssistantPreset(host.settings.assistantBaseURL);
      host.assistantKeysByPreset[preset.id] = initialKey;
    }
    if (host.loadedSettings.hasLegacyCredentials) {
      // Rewrite the plaintext copy first so a credential-manager failure can never
      // leave tokens in localStorage. The in-memory settings keep the login alive.
      writeSettingsForStorage(host.settings);
      stripCredentialFieldsFromStoredCopies();
      void persistCredentials(host);
      host.timerCredentialsReady = true;
      return Promise.resolve();
    }
    // A stale pre-1.0 copy can still hold secrets even when the v2 copy is clean (#28).
    stripCredentialFieldsFromStoredCopies();
    return hydrateCredentials(host, options);
  }

const hydratingHosts = new WeakSet<MenuMijiaWindowsApp>();
const pendingPersistDuringHydration = new WeakSet<MenuMijiaWindowsApp>();

export function hasAnyConnectedOrSelectedDataSource(host: Pick<MenuMijiaWindowsApp, "settings"> & Partial<DualSourceInspectableHost>): boolean {
  const s = host.settings;
  return (
    s.miSession !== null ||
    (host.miAccountsOverride?.length ?? 0) > 0 ||
    (host.multiAccountState?.accounts?.length ?? 0) > 0 ||
    hasSecondaryMiAccountsInIndex() ||
    homeAssistantIdentity(s.haBaseURL, s.haToken) !== null ||
    s.cachedHAHome !== null ||
    s.cachedXiaomiDevices.length > 0 ||
    isDualSourceEnabled(host as DualSourceInspectableHost)
  );
}

export async function retryIdentityMigration(host: MenuMijiaWindowsApp): Promise<void> {
  const prevSettingsError = host.loadedSettings.settingsReadError;
  if (prevSettingsError) {
    const reloaded = loadSettings();
    host.loadedSettings = reloaded;
    if (!reloaded.settingsReadError) {
      host.settings = reloaded.settings;
      if (host.identityMigrationDiagnostic === prevSettingsError) {
        host.identityMigrationDiagnostic = null;
      }
    }
  }
  if (host.identityMigrationDiagnostic === "corrupt_mi_accounts_index" && !hasCorruptMiAccountIndex()) {
    host.identityMigrationDiagnostic = null;
  }
  if (host.identityMigrationDiagnostic === "credential_vault_read_failed") {
    host.identityMigrationDiagnostic = null;
  }
  await hydrateCredentials(host);
  resolveHostMiSelectionState(host);
  host.render();
}

export async function hydrateCredentials(
  host: MenuMijiaWindowsApp,
  options: { readonly overwriteExisting?: boolean } = {},
): Promise<void> {
    hydratingHosts.add(host);
    try {
      const activePreset = inferAssistantPreset(host.settings.assistantBaseURL).id;
      const legacyOwnerEndpoint = host.settings.assistantLegacyKeyEndpoint ?? host.settings.assistantKeyEndpoint;
      const credentials = await host.credentialVault.load(activePreset, legacyOwnerEndpoint);
      if (host.credentialVault.didLastCredentialLoadFail()) {
        throw new Error("credential_vault_read_failed");
      }
      if (host.identityMigrationDiagnostic === "credential_vault_read_failed") {
        host.identityMigrationDiagnostic = null;
      }
      if (!host.credentialVault.hasLegacyAssistantKey() && host.settings.assistantLegacyKeyEndpoint !== null) {
        host.settings.assistantLegacyKeyEndpoint = null;
        if (!host.loadedSettings.settingsReadError) writeSettingsForStorage(host.settings);
      }
      const pendingSignOut = !host.settings.miSession && hasPendingMiVaultDeletion();
      if (pendingSignOut) {
        try {
          await host.credentialVault.deleteMiSession();
          setPendingMiVaultDeletion(false);
        } catch {
          // Keep pendingSignOut flag so the user is not auto-signed back in and can still retry.
        }
      }
      const effectiveCredentials = pendingSignOut
        ? { ...credentials, miSession: null }
        : credentials;
      if (!hasCredentials(effectiveCredentials)) {
        if (pendingSignOut) host.render();
        return;
      }
      const allowOverwrite = options.overwriteExisting === true && !pendingPersistDuringHydration.has(host);
      const prevVaultMiUserId = host.settings.miSession?.userId ?? null;
      const prevVaultHaToken = host.settings.haToken.trim();
      if (effectiveCredentials.assistantApiKeys) {
        host.assistantKeysByPreset = allowOverwrite
          ? { ...effectiveCredentials.assistantApiKeys }
          : { ...effectiveCredentials.assistantApiKeys, ...host.assistantKeysByPreset };
      }
      const current = credentialsFromSettings(host.settings, host.assistantKeysByPreset);
      // P2c-W: a connection whose removal is still incomplete must never be revived by re-adopting
      // its credential. The record only clears once the OS credential store confirms the slot is gone.
      const adoptedMiSession = effectiveCredentials.miSession;
      const miRemovalPending =
        adoptedMiSession !== null &&
        isConnectionRemovalPending(miConnectionRemovalScope(makeMiAccount(adoptedMiSession).id));
      if ((allowOverwrite || !current.miSession) && adoptedMiSession && !miRemovalPending) {
        host.settings.miSession = adoptedMiSession;
      }
      const adoptedHaScope = effectiveCredentials.haToken.trim() === "" ? null : haConnectionScope(host.settings.haBaseURL, effectiveCredentials.haToken);
      const haRemovalPending = isConnectionRemovalPending(haConnectionRemovalScope(adoptedHaScope));
      if ((allowOverwrite || current.haToken === "") && effectiveCredentials.haToken !== "" && !haRemovalPending) {
        host.settings.haToken = effectiveCredentials.haToken;
      }
      if (
        allowOverwrite &&
        !host.isStandaloneSettingsWindow &&
        ((host.settings.miSession?.userId ?? null) !== prevVaultMiUserId ||
          host.settings.haToken.trim() !== prevVaultHaToken)
      ) {
        switchSource(host, "settings-sync-credential-changed");
      }
      const currentEndpoint = assistantEndpointIdentity(host.settings.assistantBaseURL);
      const boundCustomEndpoint =
        host.settings.assistantCustomKeyEndpoint ?? host.settings.assistantKeyEndpoint ?? currentEndpoint;
      const activeSlotKey =
        activePreset === "custom"
          ? currentEndpoint !== null && currentEndpoint === boundCustomEndpoint
            ? host.assistantKeysByPreset.custom?.trim() ?? ""
            : ""
          : host.assistantKeysByPreset[activePreset]?.trim() ?? effectiveCredentials.assistantApiKey;
      if ((allowOverwrite || host.settings.openRouterApiKey.trim() === "") && activeSlotKey !== "") {
        host.settings.openRouterApiKey = activeSlotKey;
        if (activePreset !== "custom") {
          host.settings.assistantKeyEndpoint = currentEndpoint;
        } else {
          host.settings.assistantCustomKeyEndpoint ??= boundCustomEndpoint;
          host.settings.assistantKeyEndpoint ??= host.settings.assistantCustomKeyEndpoint;
        }
      }
      const hasConfiguredHA = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken) !== null;
      const migration = evaluateLegacyOnboardingMigration(host.loadedSettings, {
        hasVaultMiSession: Boolean(host.settings.miSession),
        hasVaultHaToken: Boolean(host.settings.haToken.trim()),
      });
      if (host.settings.miSession) {
        host.settings.miCloudRegion = normalizeMiCloudRegion(host.settings.miSession.region);
      }
      if (host.settings.miSession || hasConfiguredHA || !migration.shouldShowOnboarding) {
        host.settings.hasCompletedOnboarding = true;
        if (host.activeSheet === "onboarding") host.activeSheet = "none";
      }
      submitServiceEndpoints(host);
      if (!host.loadedSettings.settingsReadError) {
        writeSettingsForStorage(host.settings);
      }
      if (host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession) {
        if (!isHostMiSessionEnabled(host, host.settings.miSession) && !hasSecondaryMiAccountsInIndex()) {
          host.devices = [];
        } else if (!host.isStandaloneSettingsWindow) {
          void host.refreshDevices(true);
        }
      }
      if (host.settings.connectionMode === "homeAssistant") {
        const cache = haCacheIfEnabled(host, { requireIdentityMatch: true });
        if (cache) {
          host.devices = structuredClone(cache.home.devices);
          host.scenes = structuredClone(cache.home.scenes);
          host.environmentReadings = structuredClone(cache.home.environmentReadings);
          host.deviceFacets = structuredClone(cache.home.deviceFacets ?? {});
        } else if (!isHostHaEnabled(host)) {
          host.devices = [];
          host.scenes = [];
          host.environmentReadings = [];
          host.deviceFacets = {};
        }
      }
      host.render();
      if (!host.isStandaloneSettingsWindow && host.settings.connectionMode === "homeAssistant" && hasConfiguredHA && isHostHaEnabled(host)) {
        void host.refreshHADevices();
      }
    } catch {
      host.identityMigrationDiagnostic = "credential_vault_read_failed";
      appDiagnosticsLog.record({
        category: "auth",
        summary: "Identity migration fell back to legacy mode: credential vault read failed (retryable).",
      });
      // Uncertain identity read: fall back to legacy startup without popping onboarding or sealing migration.
      if (host.activeSheet === "onboarding") {
        host.activeSheet = "none";
      }
      if (host.settings.connectionMode === "homeAssistant") {
        host.haConnectionError = "Home Assistant credentials could not be loaded. Check Windows Credential Manager.";
      }
      host.render();
    } finally {
      hydratingHosts.delete(host);
      host.timerCredentialsReady = true;
      // P2-6 (#293): the guide was mounted as a loading state because the credential store had not
      // been read yet. Settlement — including the no-credentials and vault-failure paths — decides
      // now whether the full guide or the panel is shown, so nothing flashes in between.
      if (host.onboardingAwaitingCredentials) {
        host.onboardingAwaitingCredentials = false;
        host.render();
      }
      if (!host.identityMigrationDiagnostic && !host.loadedSettings.settingsReadError) {
        const selection = resolveHostMiSelectionState(host);
        // P5b-W: a brand-new install takes the switches the shared manifest asks for. P4a-W's
        // install mode decides that — an upgrade (`legacyPreserved`/`explicit`) and an uncertain
        // identity read keep the values they already have. The resolved values stay in memory: no
        // extra settings write, so the fresh-install evidence is not consumed by this feature.
        applyFreshInstallFeatureSwitches(host.settings, selection);
      }
      if (pendingPersistDuringHydration.has(host)) {
        pendingPersistDuringHydration.delete(host);
        void persistCredentials(host);
      }
      // Every caller — including `retryIdentityMigration`, which replaces `host.settings` from
      // storage just before this — reaches this point, so the DOM event consumers follow the
      // settled `eventAutomationEnabled` (a startup default, a reloaded value, or the fresh-install
      // switch `applyFreshInstallFeatureSwitches` just wrote) instead of the value bound at startup.
      syncAutomationLifecycle(host);
    }
  }

export async function persistCredentials(host: MenuMijiaWindowsApp): Promise<void> {
    if (hydratingHosts.has(host)) {
      pendingPersistDuringHydration.add(host);
      return;
    }
    pendingPersistDuringHydration.delete(host);
    try {
      await host.credentialVault.persist(credentialsFromSettings(host.settings, host.assistantKeysByPreset));
      if (host.settings.miSession) {
        setPendingMiVaultDeletion(false);
      } else if (hasPendingMiVaultDeletion()) {
        await host.credentialVault.deleteMiSession();
        setPendingMiVaultDeletion(false);
        host.queueBackgroundRender();
      }
      if (!host.credentialVault.hasLegacyAssistantKey() && host.settings.assistantLegacyKeyEndpoint !== null) {
        host.settings.assistantLegacyKeyEndpoint = null;
        writeSettingsForStorage(host.settings);
      }
    } catch {
      // The credential manager refused the write; never fall back to plaintext storage.
      host.replyBanner = {
        text: tr3(
          "无法将凭据保存到 Windows 凭据管理器，请检查系统凭据设置。",
          "無法將憑據儲存到 Windows 憑據管理員，請檢查系統憑據設定。",
          "Could not save credentials to Windows Credential Manager; check system settings.",
        ),
        source: t("出错提示"),
        isError: true,
      };
      host.render();
    }
  }

export async function clearHostSessionAndDualSourceState(
  host: Partial<MenuMijiaWindowsApp> & { settings?: { dualSourceEnabled?: boolean } },
  options: { readonly revokeAll?: boolean } = {},
): Promise<void> {
  clearHostActivitiesOnSignOut(host);
  clearAccountRateLimitBackoff();
  const slotIds = readAccountIndex().map((entry) => entry.slotId);
  const store = host.miAccountsStore ?? null;
  host.multiAccountState = null;
  host.miAccountsOverride = null;
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.removeItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
      // Removes the per-fingerprint rejection keys plus the two v1 migration keys.
      clearPersistedMiSessionExpired();
      if (options.revokeAll) {
        localStorage.removeItem(DUAL_SOURCE_ENABLED_STORAGE_KEY);
        localStorage.removeItem(PINNED_DEVICE_SOURCES_STORAGE_KEY);
        localStorage.removeItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY);
        localStorage.removeItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY);
      }
    }
  } catch {
  }
  if (options.revokeAll) {
    appDiagnosticsLog.clear();
    host.dualSourceCoordinator = null;
    host.dualSourceEnabledOverride = null;
    if (host.settings) {
      host.settings.dualSourceEnabled = false;
    }
    clearHaScopeLifecycle(null);
    removeDisconnectedHaFromSelection(null);
  }
  removeSignedOutMiAccountFromSelection(null);
  if (host.connDiagSession) {
    host.connDiagSession.pendingDisablePreview = null;
    host.connDiagSession.disableErrorByAccountId = {};
    if (options.revokeAll) {
      host.connDiagSession.pendingHaDisablePreview = null;
      host.connDiagSession.haDisableError = null;
    }
  }
  const fullSettings = host.settings as MenuMijiaWindowsApp["settings"] | undefined;
  const scheduledCommandStore =
    host.scheduledCommandStore ?? (typeof localStorage !== "undefined" ? new ScheduledCommandStore(localStorage) : null);
  if (fullSettings && typeof fullSettings.connectionMode === "string" && scheduledCommandStore) {
    const inspectableHost = host as unknown as DualSourceInspectableHost;
    revalidateAfterMiAccountReenable({
      context: buildHostCapabilityContext(inspectableHost, []),
      scheduledCommandStore,
      activeTimerIdentity: scheduledCommandIdentity(fullSettings) ?? null,
      ruleStore: new AutomationRuleStore(),
    });
  }
  let signOutError: unknown = null;
  if (store) {
    try {
      await store.clearAll();
    } catch (error) {
      signOutError = error;
    }
  }
  if (host.credentialVault && slotIds.length > 0) {
    try {
      await host.credentialVault.deleteMiSession(slotIds);
    } catch (error) {
      signOutError ??= error;
    }
  }
  if (signOutError && host.replyBanner !== undefined) {
    const detail =
      signOutError instanceof Error && signOutError.message.trim()
        ? ` (${signOutError.message.trim()})`
        : "";
    host.replyBanner = {
      text: `${tr3(
        "退出未完成，部分米家凭据仍保留，请重试",
        "登出未完成，部分米家憑據仍保留，請重試",
        "Sign-out incomplete; some Xiaomi credentials are still stored. Please retry",
      )}${detail}`,
      source: tr3("出错提示", "出錯提示", "Error"),
      isError: true,
    };
    host.render?.();
  }
}

export function signOutXiaomiAccount(host: MenuMijiaWindowsApp): void {
    const hasMultiAccounts =
      (host.miAccountsOverride != null && host.miAccountsOverride.length > 0) ||
      (host.miAccountsStore?.getAccounts().length ?? 0) > 0 ||
      hasSecondaryMiAccountsInIndex();
    const retryOnly =
      !host.settings.miSession &&
      host.settings.cachedXiaomiDevices.length === 0 &&
      !hasMultiAccounts &&
      !isDualSourceEnabled(host);
    if (retryOnly && !hasPendingMiVaultDeletion()) {
      host.cameraLive.discardRetainedCloudSessions();
      return;
    }
    setPendingMiVaultDeletion(true);
    const wasXiaomiMode = host.settings.connectionMode === "xiaomiCloud";
    const wasDualSource = isDualSourceEnabled(host);
    const { transitionedToHASingleSource } = !retryOnly
      ? finishAllMiAccountsSignedOutOnHost(host, {
          wasDualSource,
          wasXiaomiMode,
        })
      : { transitionedToHASingleSource: false };
    host.cameraLive.discardRetainedCloudSessions();
    host.settings.miSession = null;
    host.settings.cachedXiaomiDevices = [];
    host.settings.selectedHomeId = null;
    if (retryOnly) {
      clearCachedXiaomiTopology(host);
    }
    const clearMultiPromise = clearHostSessionAndDualSourceState(host, { revokeAll: false });
    host.miSessionExpired = false;
    host.cloudValuesStale = false;
    host.lastMiCloudSyncFailed = false;
    host.unresolvedRoomDids.clear();
    host.qrTicket = null;
    host.qrPhase = "idle";
    host.qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
    host.replyBanner = {
      text: tr3("已退出米家账号", "已登出米家帳號", "Signed out of Xiaomi Home"),
      source: tr3("账号管理", "帳號管理", "Account"),
    };
    writeSettingsForStorage(host.settings);
    submitServiceEndpoints(host, false);
    if (transitionedToHASingleSource) {
      void host.refreshHADevices(false);
    }
    void (async () => {
      try {
        await clearMultiPromise;
        await host.credentialVault.persist(credentialsFromSettings(host.settings, host.assistantKeysByPreset));
        await host.credentialVault.deleteMiSession();
        setPendingMiVaultDeletion(false);
        host.render();
      } catch (error: unknown) {
        const detail = error instanceof Error && error.message.trim() ? ` (${error.message.trim()})` : "";
        host.replyBanner = {
          text: `${tr3("无法从系统凭据库移除米家登录，请重试", "無法從系統憑據庫移除米家登入，請重試", "Could not remove Xiaomi sign-in from the OS credential vault; please retry")}${detail}`,
          source: t("出错提示"),
          isError: true,
        };
        host.render();
      }
    })();
    host.render();
  }

function hasTauriWindowMetadata(): boolean {
  return (
    typeof window !== "undefined" &&
    Boolean(
      (window as unknown as { __TAURI_INTERNALS__?: { metadata?: unknown } }).__TAURI_INTERNALS__
        ?.metadata,
    )
  );
}

export function saveSettings(host: MenuMijiaWindowsApp, forceSubmitEndpoints = false): void {
    writeSettingsForStorage(host.settings);
    submitServiceEndpoints(host, forceSubmitEndpoints);
    void persistCredentials(host);
    if (hasTauriWindowMetadata()) {
      invokeTauriVoid("notify_settings_changed", {
        sourceLabel: host.isStandaloneSettingsWindow ? "settings" : "main",
      });
    }
  }

  /** OS-preferred languages, read from the WebView's `window.navigator` (#52). */
export function osLanguages(): string[] {
    const languages = window.navigator.languages;
    if (Array.isArray(languages) && languages.length > 0) return [...languages];
    return window.navigator.language ? [window.navigator.language] : [];
  }

  /** Picks the UI language from the saved preference plus the OS languages (#52). */
export function applyInterfaceLanguage(host: MenuMijiaWindowsApp): void {
    setLanguage(resolveLanguage(host.settings.interfaceLanguage, osLanguages()));
  }

  /** Resolves °C/°F from the saved preference plus the OS region; core values stay Celsius (#52). */
export function applyTemperatureSetting(host: MenuMijiaWindowsApp): void {
    const locale = osLanguages()[0] ?? "en";
    applyTemperatureUnit(locale, host.settings.temperatureUnit);
  }

export function submitServiceEndpoints(host: MenuMijiaWindowsApp, force = false): void {
    const assistantUrl = host.settings.assistantBaseURL.trim();
    const haUrl = isHostHaEnabled(host) ? host.settings.haBaseURL.trim() : "";
    const serialized = `${assistantUrl}\n${haUrl}`;
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    const haToken = haUrl && getHaScopeLifecyclePhase(haUrl) === "enabled" ? host.settings.haToken.trim() : "";
    const native = syncHaNativeConnection(haUrl, haToken);
    const sameEndpoints = !force && serialized === host.lastSubmittedEndpoints;
    if (sameEndpoints && !native) return;
    const authorization = sameEndpoints
      ? host.endpointSubmission
      : invoke("set_service_endpoints", { assistantUrl, haUrl });
    host.lastSubmittedEndpoints = serialized;
    host.endpointSubmission = (native ? Promise.all([authorization, native]) : authorization).catch((error: unknown) => {
      host.noteServiceEndpointFailure(error);
    });
  }

  /** Restores the last known release so an update found yesterday still shows after a restart. */
export function restoreUpdateState(host: MenuMijiaWindowsApp): void {
    try {
      host.updateState = parseUpdateState(localStorage.getItem(UPDATE_STORAGE_KEY));
    } catch {
      host.updateState = { lastCheckedAtMs: null, release: null };
    }
    const release = host.updateState.release;
    if (release && isNewerVersion(release.version, APP_VERSION)) {
      host.availableUpdate = release;
      invokeTauriVoid("set_update_available", { version: release.version });
    }
  }

export function saveUpdateState(host: MenuMijiaWindowsApp): void {
    try {
      localStorage.setItem(UPDATE_STORAGE_KEY, serializeUpdateState(host.updateState));
    } catch {
      // Quota errors only cost the "once per day" memory, never the check itself.
    }
  }

  /**
   * Automatic check is skipped outside Tauri (browser preview/tests) because the CSP only
   * allows `native_http`. `manual` is an explicit user action, so it bypasses the daily
   * limit and the auto-check switch (#39).
   */
export async function checkForAppUpdate(host: MenuMijiaWindowsApp, manual: boolean): Promise<void> {
    if (host.settings.connectionMode === "demo") {
      if (manual) {
        const text = tr3(
          "演示模式下不发起联网更新检查，切换真实数据源后再试。",
          "示範模式下不發起聯網更新檢查，切換真實資料來源後再試。",
          "Update checks are disabled in demo mode; switch to a live source first.",
        );
        host.updateStatusMessage = { text, isError: false };
        host.replyBanner = { text, source: t("检查更新") };
        host.render();
      }
      return;
    }
    if (!manual && !window.__TAURI_INTERNALS__?.invoke) return;
    if (!manual && !hasAnyConnectedOrSelectedDataSource(host) && !host.settings.hasCompletedOnboarding) return;
    if (host.isCheckingUpdate || host.isInstallingUpdate) return;
    if (manual) {
      host.isCheckingUpdate = true;
      host.updateStatusMessage = null;
      host.render();
    }
    const result = await checkForUpdate({
      currentVersion: APP_VERSION,
      enabled: manual || host.settings.autoCheckUpdates,
      lastCheckedAtMs: host.updateState.lastCheckedAtMs,
      nowMs: Date.now(),
      force: manual,
      installId: loadOrCreateUpdateInstallId(typeof localStorage !== "undefined" ? localStorage : null),
      requestLatest: () =>
        host.transport({
          url: UPDATE_RELEASES_URL,
          method: "GET",
          headers: {
            Accept: "application/vnd.github+json",
            "User-Agent": "MenuBarHome-Windows",
          },
          timeoutMs: 8000,
        }),
    });
    host.isCheckingUpdate = false;
    if (!result.requested) return;

    // A failed check (offline, rate limit) knows nothing new: keep the release found earlier.
    host.updateState = {
      lastCheckedAtMs: result.checkedAtMs,
      release: result.failed ? host.updateState.release : result.release,
    };
    saveUpdateState(host);
    if (result.updateAvailable && result.release) {
      host.availableUpdate = result.release;
      host.updateStatusMessage = null;
      invokeTauriVoid("set_update_available", { version: result.release.version });
      host.render();
    } else if (!result.failed && host.availableUpdate) {
      // A successful check with no newer release retires yesterday's notice.
      host.availableUpdate = null;
      host.updateStatusMessage = manual
        ? { text: t("已是最新版本 v{version}", { version: APP_VERSION }), isError: false }
        : null;
      invokeTauriVoid("set_update_available", { version: null });
      host.render();
    } else if (manual) {
      const text = result.failed ? t("检查更新失败，请稍后再试") : t("已是最新版本 v{version}", { version: APP_VERSION });
      host.updateStatusMessage = { text, isError: result.failed };
      host.replyBanner = {
        text,
        source: t("检查更新"),
        isError: result.failed,
      };
      host.render();
    }
  }

/** `tab` routes the caller to the category it needs: the QR button to sources, an update to general. */
export function openSettingsSheet(
  host: MenuMijiaWindowsApp,
  tab: SettingsTab = "general",
  anchor?: SettingsAnchor,
): void {
    const normalized = normalizeSettingsTab(tab);
    const normalizedAnchor = normalizeSettingsAnchor(anchor);
    if (!host.isStandaloneSettingsWindow && hasTauriWindowMetadata()) {
      invokeTauriVoid(
        "open_settings_window",
        normalizedAnchor ? { tab: normalized, anchor: normalizedAnchor } : { tab: normalized },
      );
      return;
    }
    host.activeSheet = "settings";
    host.settingsTab = normalized;
    invokeTauriVoid("set_pin_popover", { pin: true });
    host.syncPanelPlacement();
    host.render();
    if (normalizedAnchor) {
      highlightSettingsAnchor(host.root, normalizedAnchor);
    } else {
      clearSettingsHighlight(host.root);
    }
    void host.checkForAppUpdate(false);
  }

export function openUpdatePage(host: MenuMijiaWindowsApp): void {
    invokeTauriVoid("open_release_page", { url: host.availableUpdate?.htmlURL ?? UPDATE_RELEASES_PAGE });
  }

export async function startUpdateInstall(host: MenuMijiaWindowsApp): Promise<void> {
    if (host.isInstallingUpdate || !host.availableUpdate) return;
    if (host.settings.connectionMode === "demo") {
      const text = tr3(
        "演示模式下不发起联网下载，切换真实数据源后再试。",
        "示範模式下不發起聯網下載，切換真實資料來源後再試。",
        "Update downloads are disabled in demo mode; switch to a live source first.",
      );
      host.updateStatusMessage = { text, isError: false };
      host.render();
      return;
    }
    const asset = host.availableUpdate.installerAsset;
    if (!asset) {
      openUpdatePage(host);
      return;
    }
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) {
      openUpdatePage(host);
      return;
    }
    clearUpdateProgress(host);
    host.isInstallingUpdate = true;
    host.updateStatusMessage = {
      text: t("正在下载并校验 v{version} 安装包，完成后将自动启动安装…", { version: host.availableUpdate.version }),
      isError: false,
    };
    host.render();
    try {
      await invoke("install_update", { asset });
      clearUpdateProgress(host);
      host.isInstallingUpdate = false;
      host.render();
    } catch (error) {
      clearUpdateProgress(host);
      host.isInstallingUpdate = false;
      const message =
        typeof error === "string" && error.trim().length > 0
          ? error
          : error instanceof Error && error.message.trim().length > 0
            ? error.message
            : t("下载或校验更新包失败，请重试或手动下载");
      host.updateStatusMessage = { text: message, isError: true };
      host.render();
    }
  }

  /**
   * Synchronizes the Windows global shortcut registration with the current preference (#43),
   * unregistering immediately when disabled (Coding Standard #3) and surfacing conflicts.
   */
export async function applyGlobalHotkey(host: MenuMijiaWindowsApp): Promise<void> {
    const enabled = host.settings.enableGlobalHotkey;
    const shortcut = normalizeGlobalShortcut(host.settings.globalHotkey);
    host.settings.globalHotkey = shortcut;
    if (!enabled) {
      host.hotkeyRegistrationError = null;
    }
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) {
      host.hotkeyRegistrationError = null;
      return;
    }
    try {
      await invoke("set_global_shortcut", { enabled, shortcut });
      host.hotkeyRegistrationError = null;
    } catch {
      host.hotkeyRegistrationError = enabled ? t("这个组合已被其他应用占用，换一个再试。") : null;
    }
    await applyCustomGlobalHotkeys(host);
    if (host.activeSheet === "settings") {
      host.render();
    }
  }

export async function applyCustomGlobalHotkeys(host: MenuMijiaWindowsApp): Promise<void> {
  const bindings = normalizeCustomHotkeyBindings(host.settings.customHotkeyBindings);
  host.settings.customHotkeyBindings = bindings;
  const invoke = window.__TAURI_INTERNALS__?.invoke;
  if (!invoke) {
    host.customHotkeyRegistrationErrors = {};
    return;
  }
  try {
    const errors = await invoke<Record<string, string>>("set_custom_global_shortcuts", {
      bindings: bindings.map((b) => ({ id: b.id, shortcut: b.shortcut })),
    });
    host.customHotkeyRegistrationErrors =
      errors && typeof errors === "object" ? { ...errors } : {};
  } catch {
    host.customHotkeyRegistrationErrors = {};
  }
  if (host.activeSheet === "settings") {
    host.render();
  }
}

export const RESUME_BURST_DEBOUNCE_MS = 180;
export const RESUME_MAX_DELAY_MS = 1_000;
export const RESUME_RECOVERY_COOLDOWN_MS = 2_000;

export interface LifecycleScheduler {
  readonly now: () => number;
  readonly setTimeout: (handler: () => void, delayMs: number) => unknown;
  readonly clearTimeout: (handle: unknown) => void;
  readonly setInterval: (handler: () => void, intervalMs: number) => unknown;
  readonly clearInterval: (handle: unknown) => void;
}

/** Reads timer globals on the target window dynamically so test stubs continue to intercept them. */
export function createWindowLifecycleScheduler(win: Window = window): LifecycleScheduler {
  return {
    now: () => Date.now(),
    setTimeout: (handler, delayMs) => win.setTimeout(handler, delayMs),
    clearTimeout: (handle) => win.clearTimeout(handle as number),
    setInterval: (handler, intervalMs) => win.setInterval(handler, intervalMs),
    clearInterval: (handle) => win.clearInterval(handle as number),
  };
}

export interface LifecycleEventTarget {
  addEventListener(type: string, listener: (event: Event) => void): void;
  removeEventListener(type: string, listener: (event: Event) => void): void;
}

export type ResumeTrigger = "visibility" | "focus" | "online" | "resume" | "network";

export interface ResumeRecoveryHost {
  readonly settings: {
    readonly connectionMode: string;
    readonly miSession: unknown;
    readonly eventAutomationEnabled?: boolean;
  };
  readonly activeSheet: string;
  readonly isSyncingCloud: boolean;
  readonly isPollingQR: boolean;
  readonly lastCloudRefreshAt: number | null;
  /**
   * Epoch ms of the last panel open/close. The idle decay reads it (`pollingSchedule.notePanelInteraction`);
   * a host that does not track it keeps the flat closed-panel interval.
   */
  lastPanelInteractionAtMs?: number | null;
  readonly cloudValuesStale: boolean;
  readonly haConnectionError: string | null;
  readonly root?: OptimisticLockRootLike;
  /** Present on the real panel; the narrow slice keeps lifecycle tests free of a full render pipeline. */
  render?(): void;
  isPanelVisible(): boolean;
  refreshDevices(silent?: boolean): Promise<void>;
}

export interface ResumeRecoveryOptions {
  readonly scheduler?: LifecycleScheduler;
  readonly debounceMs?: number;
  readonly maxDelayMs?: number;
  readonly recoveryCooldownMs?: number;
  readonly isDocumentVisible?: () => boolean;
  readonly isWindowFocused?: () => boolean;
  readonly isNavigatorOnline?: () => boolean;
}

export interface BindLifecycleRecoveryOptions extends ResumeRecoveryOptions {
  readonly window?: LifecycleEventTarget;
  readonly document?: LifecycleEventTarget;
  readonly onPageHide?: () => void;
}

function isLifecycleHostAttached(host: { readonly root?: OptimisticLockRootLike }): boolean {
  return isHostAttachedToActiveWindow({
    sourceRevision: 0,
    devices: [],
    ...(host.root ? { root: host.root } : {}),
  });
}

export function canRefreshDevicesInBackground(host: ResumeRecoveryHost): boolean {
  const dualInspectable = host as ResumeRecoveryHost & DualSourceInspectableHost & {
    readonly miAccountsStore?: import("../core/miAccountsStore.js").MiAccountsStore | null;
  };
  const hasEnabledMi = (): boolean => {
    const accounts =
      dualInspectable.miAccountsOverride ??
      dualInspectable.multiAccountState?.accounts ??
      (host.settings.miSession ? [makeMiAccount(host.settings.miSession as MiSession)] : []);
    if (accounts.length > 0) {
      return resolveEnabledMiAccountsForHost(dualInspectable, accounts).length > 0;
    }
    return hasSecondaryMiAccountsInIndex();
  };
  const hasConfiguredHa = (): boolean => {
    const s = dualInspectable.settings;
    if (typeof s.haBaseURL === "string" || typeof s.haToken === "string") {
      return homeAssistantIdentity(s.haBaseURL ?? "", s.haToken ?? "") !== null;
    }
    return true;
  };
  const hasActiveSource =
    (isDualSourceEnabled(dualInspectable) && ((hasConfiguredHa() && isHostHaEnabled(dualInspectable)) || hasEnabledMi())) ||
    (host.settings.connectionMode === "homeAssistant" && hasConfiguredHa() && isHostHaEnabled(dualInspectable)) ||
    (host.settings.connectionMode === "xiaomiCloud" && hasEnabledMi());
  return (
    hasActiveSource &&
    host.activeSheet === "none" &&
    !host.isSyncingCloud &&
    !host.isPollingQR
  );
}

/**
 * Coalesces `visibilitychange` / `focus` / `online` / `resume` bursts into a single
 * bounded recovery refresh while preventing duplicate backend storms and stale hidden timers.
 */
export class ResumeRecoveryController {
  private readonly scheduler: LifecycleScheduler;
  private readonly debounceMs: number;
  private readonly maxDelayMs: number;
  private readonly recoveryCooldownMs: number;
  private readonly isDocumentVisible: () => boolean;
  private readonly isWindowFocused: () => boolean;
  private readonly isNavigatorOnline: () => boolean;

  private disposed = false;
  private pendingTimer: unknown | null = null;
  private burstStartedAtMs: number | null = null;
  private readonly pendingTriggers = new Set<ResumeTrigger>();
  private lastRecoveryTriggeredAtMs: number | null = null;
  private sawOffline = false;

  constructor(
    private readonly host: ResumeRecoveryHost,
    options: ResumeRecoveryOptions = {},
  ) {
    this.scheduler = options.scheduler ?? createWindowLifecycleScheduler();
    this.debounceMs = Math.max(0, options.debounceMs ?? RESUME_BURST_DEBOUNCE_MS);
    this.maxDelayMs = Math.max(this.debounceMs, options.maxDelayMs ?? RESUME_MAX_DELAY_MS);
    this.recoveryCooldownMs = Math.max(0, options.recoveryCooldownMs ?? RESUME_RECOVERY_COOLDOWN_MS);
    this.isDocumentVisible =
      options.isDocumentVisible ??
      (() => (typeof document === "undefined" ? true : document.visibilityState !== "hidden"));
    this.isWindowFocused =
      options.isWindowFocused ??
      (() => (typeof document === "undefined" ? true : document.hasFocus()));
    this.isNavigatorOnline =
      options.isNavigatorOnline ??
      (() => (typeof navigator === "undefined" || typeof navigator.onLine !== "boolean" ? true : navigator.onLine));
  }

  public get isDisposed(): boolean {
    return this.disposed;
  }

  public get hasPendingFlush(): boolean {
    return this.pendingTimer !== null;
  }

  public noteOffline(): void {
    if (this.disposed) return;
    this.sawOffline = true;
    this.pendingTriggers.delete("visibility");
    this.pendingTriggers.delete("focus");
    this.pendingTriggers.delete("online");
    if (this.host.settings.connectionMode === "xiaomiCloud") {
      this.pendingTriggers.delete("resume");
    }
    if (this.pendingTriggers.size === 0) {
      this.clearPendingTimer();
      this.burstStartedAtMs = null;
    }
  }

  public trigger(kind: ResumeTrigger): void {
    if (this.disposed || !isLifecycleHostAttached(this.host)) return;
    if (kind === "visibility" && !this.isDocumentVisible()) {
      this.pendingTriggers.delete("visibility");
      this.pendingTriggers.delete("focus");
      if (this.pendingTriggers.size === 0) {
        this.clearPendingTimer();
        this.burstStartedAtMs = null;
      }
      return;
    }
    if (kind === "online") {
      if (!this.isNavigatorOnline()) {
        this.sawOffline = true;
        this.pendingTriggers.delete("online");
        if (this.pendingTriggers.size === 0) {
          this.clearPendingTimer();
          this.burstStartedAtMs = null;
        }
        return;
      }
      this.sawOffline = false;
    } else if ((kind === "resume" || kind === "network") && this.isNavigatorOnline()) {
      this.sawOffline = false;
    }

    this.pendingTriggers.add(kind);
    const now = this.scheduler.now();
    if (this.burstStartedAtMs === null) {
      this.burstStartedAtMs = now;
    }
    const maxDeadline = this.burstStartedAtMs + this.maxDelayMs;
    const delay = Math.max(0, Math.min(this.debounceMs, maxDeadline - now));

    this.clearPendingTimer();
    this.pendingTimer = this.scheduler.setTimeout(() => {
      this.flush();
    }, delay);
  }

  public flush(): void {
    this.pendingTimer = null;
    const triggers = new Set(this.pendingTriggers);
    this.pendingTriggers.clear();
    this.burstStartedAtMs = null;

    if (this.disposed || !isLifecycleHostAttached(this.host)) return;
    if (this.sawOffline || !this.isNavigatorOnline()) {
      triggers.delete("online");
    }
    if (triggers.size === 0 || !canRefreshDevicesInBackground(this.host)) return;

    const hasNetworkChange = triggers.has("network");
    const hasNetworkOrSystemResume = triggers.has("online") || triggers.has("resume") || hasNetworkChange;
    const docVisible = this.isDocumentVisible();
    const winFocused = this.isWindowFocused();

    // A show/focus burst that already hid again before debounce settled needs no refresh.
    if (!hasNetworkOrSystemResume && !docVisible) return;
    if (
      this.host.settings.connectionMode === "xiaomiCloud" &&
      (this.sawOffline || !this.isNavigatorOnline())
    ) {
      return;
    }

    const now = this.scheduler.now();
    if (
      !hasNetworkChange &&
      this.lastRecoveryTriggeredAtMs !== null &&
      now - this.lastRecoveryTriggeredAtMs < this.recoveryCooldownMs
    ) {
      return;
    }

    const isStaleOrErrored = this.host.cloudValuesStale || this.host.haConnectionError !== null;
    if (hasNetworkOrSystemResume) {
      if (
        !hasNetworkChange &&
        !isStaleOrErrored &&
        this.host.lastCloudRefreshAt !== null &&
        now - this.host.lastCloudRefreshAt < this.recoveryCooldownMs
      ) {
        return;
      }
    } else {
      const panelVisible = docVisible && (winFocused || triggers.has("visibility") || this.host.isPanelVisible());
      const due = cloudRefreshDue(
        now,
        this.host.lastCloudRefreshAt,
        panelVisible,
        pollingDecayInputs(this.host),
      );
      if (!due && !isStaleOrErrored) {
        return;
      }
      if (
        isStaleOrErrored &&
        this.host.lastCloudRefreshAt !== null &&
        now - this.host.lastCloudRefreshAt < this.recoveryCooldownMs
      ) {
        return;
      }
    }

    this.lastRecoveryTriggeredAtMs = now;
    void Promise.resolve(this.host.refreshDevices(true)).catch(() => undefined);
  }

  public dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.clearPendingTimer();
    this.pendingTriggers.clear();
    this.burstStartedAtMs = null;
  }

  private clearPendingTimer(): void {
    if (this.pendingTimer !== null) {
      this.scheduler.clearTimeout(this.pendingTimer);
      this.pendingTimer = null;
    }
  }
}

const SUB_MINUTE_SCHEDULE_WINDOW_MS = 60_000;

interface HostLifecycleState {
  disposed: boolean;
  timerIntervalHandle: unknown | null;
  timerTimeoutHandle: unknown | null;
  timerTimeoutDueAtMs: number | null;
  lastTimerTickAtMs: number | null;
  timerScheduler: LifecycleScheduler | null;
  syncTimerSchedule?: () => void;
  keyDisposers: Array<() => void>;
  recoveryController: ResumeRecoveryController | null;
  recoveryDisposers: Array<() => void>;
  syncAutomationListeners?: () => void;
}

const hostLifecycles = new WeakMap<object, HostLifecycleState>();

function ensureLifecycleState(host: object): HostLifecycleState {
  let state = hostLifecycles.get(host);
  if (!state) {
    state = {
      disposed: false,
      timerIntervalHandle: null,
      timerTimeoutHandle: null,
      timerTimeoutDueAtMs: null,
      lastTimerTickAtMs: null,
      timerScheduler: null,
      keyDisposers: [],
      recoveryController: null,
      recoveryDisposers: [],
    };
    hostLifecycles.set(host, state);
  }
  return state;
}

function clearKeyListeners(state: HostLifecycleState): void {
  for (const stop of state.keyDisposers.splice(0)) stop();
}

function clearRecoveryListeners(state: HostLifecycleState): void {
  state.syncAutomationListeners = undefined;
  state.recoveryController?.dispose();
  state.recoveryController = null;
  for (const stop of state.recoveryDisposers.splice(0)) stop();
}

function clearTimerInterval(state: HostLifecycleState, host?: unknown): void {
  const hadTimer = state.timerIntervalHandle !== null || state.timerTimeoutHandle !== null;
  if (state.timerIntervalHandle !== null && state.timerScheduler) {
    state.timerScheduler.clearInterval(state.timerIntervalHandle);
  }
  if (state.timerTimeoutHandle !== null && state.timerScheduler) {
    state.timerScheduler.clearTimeout(state.timerTimeoutHandle);
  }
  state.timerIntervalHandle = null;
  state.timerTimeoutHandle = null;
  state.timerTimeoutDueAtMs = null;
  state.lastTimerTickAtMs = null;
  state.timerScheduler = null;
  state.syncTimerSchedule = undefined;
  if (hadTimer && isFullPanelHost(host)) {
    const center = getHostActivityCenter(host);
    center.systemSignalBaseline = null;
    center.lastSystemPollAtMs = 0;
  }
}

export function syncTimerLoopSchedule(host: object): void {
  hostLifecycles.get(host)?.syncTimerSchedule?.();
}

/** Idempotently cancels all tracked timers, debounce tasks, and global listeners for `host`. */
export function disposeAppLifecycle(host: object): void {
  const state = hostLifecycles.get(host);
  if (!state || state.disposed) return;
  state.disposed = true;
  clearTimerInterval(state, host);
  clearRecoveryListeners(state);
  clearKeyListeners(state);
}

function listen(
  target: LifecycleEventTarget,
  type: string,
  handler: (event: Event) => void,
): () => void {
  target.addEventListener(type, handler);
  return () => target.removeEventListener(type, handler);
}

export function syncAutomationLifecycle(host: object): void {
  const state = hostLifecycles.get(host);
  state?.syncAutomationListeners?.();
  state?.syncTimerSchedule?.();
}

export function bindLifecycleRecovery(
  host: ResumeRecoveryHost,
  options: BindLifecycleRecoveryOptions = {},
): () => void {
  const state = ensureLifecycleState(host);
  clearRecoveryListeners(state);
  state.disposed = false;

  const ownerWin = (options.window ??
    host.root?.ownerDocument?.defaultView ??
    window) as LifecycleEventTarget;
  const ownerDoc = (options.document ??
    host.root?.ownerDocument ??
    document) as LifecycleEventTarget;

  const controller = new ResumeRecoveryController(host, options);
  state.recoveryController = controller;

  const onVisibilityChange = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    if ((ownerDoc as { readonly visibilityState?: string }).visibilityState === "hidden") {
      // Clearing the flags is not enough: the mounted dialog/expanded list must leave the DOM too.
      if (collapseActivityStackOnHide(host)) host.render?.();
    } else {
      notifyPanelWakeLifecycle(host);
    }
    // Showing or hiding the panel is the user touching it: the idle clock restarts here, so the
    // closed-panel stretch never covers a moment the user is here (`setPanelVisible` on macOS).
    notePanelInteraction(host);
    state.syncTimerSchedule?.();
    controller.trigger("visibility");
  };
  const onFocus = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    notePanelInteraction(host);
    state.syncTimerSchedule?.();
    controller.trigger("focus");
  };
  const onOnline = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    controller.trigger("online");
  };
  const onOffline = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    controller.noteOffline();
  };
  const onResume = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    resetLocalMiIOHealth();
    notifyPanelWakeLifecycle(host);
    state.syncTimerSchedule?.();
    controller.trigger("resume");
  };
  const onNetworkChanged = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    resetLocalMiIOHealth();
    state.syncTimerSchedule?.();
    controller.trigger("network");
  };
  const onPageHide = () => {
    if (options.onPageHide) {
      options.onPageHide();
    } else {
      disposeAppLifecycle(host);
    }
  };
  // Native power callbacks (`system_events.rs`) forward suspend, resume and console-display
  // changes as DOM events; a 10 s poll cannot see any of them in time.
  const onSystemSleep = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    notifySystemSleep(host);
  };
  const onSystemWake = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    notifySystemWake(host);
  };
  const onDisplayPower = (event: Event) => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    const detail = (event as CustomEvent<{ readonly asleep?: unknown } | null>).detail;
    notifyDisplayPowerChanged(host, detail?.asleep === true);
  };
  const onMediaCapture = (event: Event) => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    const detail = (
      event as CustomEvent<{ readonly cameraInUse?: unknown; readonly microphoneInUse?: unknown } | null>
    ).detail;
    if (!detail) return;
    const cameraInUse = typeof detail.cameraInUse === "boolean" ? detail.cameraInUse : undefined;
    const microphoneInUse =
      typeof detail.microphoneInUse === "boolean" ? detail.microphoneInUse : undefined;
    if (cameraInUse === undefined && microphoneInUse === undefined) return;
    notifyMediaCaptureChanged(host, {
      ...(cameraInUse !== undefined ? { cameraInUse } : {}),
      ...(microphoneInUse !== undefined ? { microphoneInUse } : {}),
    });
  };
  const onFocusMode = (event: Event) => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    const detail = (event as CustomEvent<{ readonly enabled?: unknown } | null>).detail;
    if (typeof detail?.enabled !== "boolean") return;
    notifyFocusModeChanged(host, detail.enabled);
  };

  const automationDisposers: Array<() => void> = [];
  const stopAutomationListeners = () => {
    for (const stop of automationDisposers.splice(0)) stop();
  };
  state.syncAutomationListeners = () => {
    if (!isEventAutomationEnabled(host.settings)) {
      stopAutomationListeners();
    } else if (automationDisposers.length === 0) {
      automationDisposers.push(
        listen(ownerWin, "menumijia:system-sleep", onSystemSleep),
        listen(ownerWin, "menumijia:system-wake", onSystemWake),
        listen(ownerWin, "menumijia:display-power", onDisplayPower),
        listen(ownerWin, "menumijia:media-capture", onMediaCapture),
        listen(ownerWin, "menumijia:focus-mode", onFocusMode),
      );
    }
    void syncSystemEventWatchers(host);
  };
  state.syncAutomationListeners();
  state.recoveryDisposers.push(
    stopAutomationListeners,
    listen(ownerDoc, "visibilitychange", onVisibilityChange),
    listen(ownerDoc, "resume", onResume),
    listen(ownerWin, "focus", onFocus),
    listen(ownerWin, "online", onOnline),
    listen(ownerWin, "offline", onOffline),
    listen(ownerWin, "menumijia:resume", onResume),
    listen(ownerWin, "menumijia:network-changed", onNetworkChanged),
    listen(ownerWin, "pagehide", onPageHide),
  );

  return () => {
    clearRecoveryListeners(state);
  };
}

export function bindGlobalKeys(
  host: MenuMijiaWindowsApp,
  options: { readonly window?: LifecycleEventTarget } = {},
): () => void {
  const state = ensureLifecycleState(host);
  clearKeyListeners(state);
  state.disposed = false;

  const ownerWin = (options.window ??
    host.root.ownerDocument?.defaultView ??
    window) as LifecycleEventTarget;

  const onBlur = () => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    // The tray popover hides when it loses focus, so blur is the panel closing (`setPanelVisible(false)`).
    notePanelInteraction(host);
    finishPanelComposition(host);
    state.syncTimerSchedule?.();
  };

  const onKeyDown = (event: Event) => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    const e = event as KeyboardEvent;
    if (host.isRecordingHotkey) {
      e.preventDefault();
      e.stopPropagation();
      const outcome = recordShortcutFromKeyEvent(e);
      if (outcome.kind === "cancel") {
        host.isRecordingHotkey = false;
        host.hotkeyNeedsHint = false;
        host.render();
      } else if (outcome.kind === "invalid") {
        host.hotkeyNeedsHint = true;
        host.render();
      } else if (outcome.kind === "recorded") {
        const conflict = validateCustomHotkeyShortcut(outcome.shortcut, {
          panelShortcut: host.settings.globalHotkey,
          checkPanelConflict: false,
          existingBindings: normalizeCustomHotkeyBindings(host.settings.customHotkeyBindings),
        });
        if (conflict) {
          host.hotkeyRegistrationError = conflict.message;
          host.hotkeyNeedsHint = false;
          host.render();
          return;
        }
        host.isRecordingHotkey = false;
        host.hotkeyNeedsHint = false;
        host.hotkeyRegistrationError = null;
        host.settings.globalHotkey = outcome.shortcut;
        host.saveSettings();
        void host.applyGlobalHotkey();
        host.render();
      }
      return;
    }

    if (host.isRecordingCustomHotkeyId !== null) {
      e.preventDefault();
      e.stopPropagation();
      const outcome = recordShortcutFromKeyEvent(e);
      if (outcome.kind === "cancel") {
        host.isRecordingCustomHotkeyId = null;
        host.customHotkeyConflictError = null;
        host.render();
      } else if (outcome.kind === "invalid") {
        host.customHotkeyConflictError = tr3(
          "需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。",
          "需要至少一個 Ctrl / Alt / Shift / Win，或單按 F1–F20。",
          "Use at least one of Ctrl / Alt / Shift / Win, or a single F1–F20 key.",
        );
        host.render();
      } else if (outcome.kind === "recorded") {
        const recordingId = host.isRecordingCustomHotkeyId;
        const existing = normalizeCustomHotkeyBindings(host.settings.customHotkeyBindings);
        const conflict = validateCustomHotkeyShortcut(outcome.shortcut, {
          panelShortcut: host.settings.globalHotkey,
          checkPanelConflict: true,
          existingBindings: existing,
          excludingBindingId: recordingId === "__new__" ? null : recordingId,
        });
        if (conflict) {
          host.customHotkeyConflictError = conflict.message;
          host.render();
          return;
        }
        if (recordingId === "__new__") {
          const target = decodeHotkeyTargetKey(host.newCustomHotkeyTargetKey);
          if (target && existing.length < MAX_CUSTOM_HOTKEY_BINDINGS) {
            const label =
              target.kind === "devicePower"
                ? (host.devices.find((d) => d.id === target.deviceId)?.name ?? target.deviceId)
                : target.kind === "scene"
                  ? (host.scenes.find((s) => s.id === target.sceneId)?.name ?? target.sceneId)
                  : quickActionTitle(target.actionId);
            const nextBinding: HotkeyBinding = {
              id: `hk-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
              target,
              targetLabel: label,
              shortcut: outcome.shortcut,
            };
            host.settings.customHotkeyBindings = [...existing, nextBinding];
            host.isAddingCustomHotkey = false;
          }
        } else {
          host.settings.customHotkeyBindings = existing.map((b) =>
            b.id === recordingId ? { ...b, shortcut: outcome.shortcut } : b,
          );
        }
        host.isRecordingCustomHotkeyId = null;
        host.customHotkeyConflictError = null;
        host.saveSettings();
        void applyCustomGlobalHotkeys(host);
        host.render();
      }
      return;
    }

    if (handlePanelKey(host, e)) return;

    if (e.key === "Escape") {
      if (host.prompt !== null) {
        e.preventDefault();
        host.closePrompt();
        return;
      }
      if (hasPendingUrlConfirmation(host)) {
        e.preventDefault();
        dismissPendingUrlConfirmation(host, false);
        return;
      }
      if (host.ctxMenu !== null || host.isHomeMenuOpen) {
        e.preventDefault();
        host.ctxMenu = null;
        host.isHomeMenuOpen = false;
        invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
        host.render();
        return;
      }
      if (
        host.cameraLive.activeLiveCameraId !== null &&
        !host.cameraLive.liveCameraHidden &&
        !host.cameraLive.isDetachedPipActive
      ) {
        e.preventDefault();
        host.cameraLive.hideCameraLiveView();
        return;
      }
      if (host.activeSheet === "settings") {
        e.preventDefault();
        handleSettingsSheetEscape(host);
        return;
      }
      if (host.activeSheet !== "none") {
        e.preventDefault();
        host.activeSheet = "none";
        host.isRecordingHotkey = false;
        host.hotkeyNeedsHint = false;
        invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
        host.render();
        return;
      }
      if (host.isEditingLayout) {
        e.preventDefault();
        host.stopEditing();
        return;
      }
      if (host.pendingHighRisk !== null) {
        e.preventDefault();
        host.clearPendingHighRisk();
        host.render();
        return;
      }
      if (host.expandedDeviceId !== null) {
        e.preventDefault();
        host.expandedDeviceId = null;
        host.render();
        return;
      }
      if (collapseActivityStackOnHide(host)) host.render();
      resumeUndoHoverPause(host);
      invokeTauriVoid("hide_panel", { returnFocus: true });
    } else if (e.key === "/" && !e.ctrlKey && !e.metaKey && !e.altKey && document.activeElement?.tagName !== "INPUT") {
      e.preventDefault();
      host.isShowingAssistantBar = true;
      host.render();
      host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
    }
  };

  const onCustomHotkey = (event: Event) => {
    if (state.disposed || !isLifecycleHostAttached(host)) return;
    const detail = (event as CustomEvent<{ id?: unknown }>).detail;
    const id = typeof detail?.id === "string" ? detail.id : "";
    if (!id) return;
    void executeCustomHotkeyBinding(host, id);
  };

  state.keyDisposers.push(
    listen(ownerWin, "blur", onBlur),
    listen(ownerWin, "keydown", onKeyDown),
    listen(ownerWin, "menumijia:custom-hotkey", onCustomHotkey),
  );

  return () => {
    clearKeyListeners(state);
  };
}

function nextScheduledCommandDelayMs(host: MenuMijiaWindowsApp, nowMs: number): number | null {
  if (!isScheduledCommandsEnabled(host.settings)) {
    return host.scheduledCommandStore?.hasWaitingTimers() ? 0 : null;
  }
  if (host.scheduledCommandStore?.hasFeaturePause()) {
    return 0;
  }
  const items = Array.isArray(host.scheduledCommands) ? host.scheduledCommands : [];
  let minDelayMs: number | null = null;
  for (const item of items) {
    const delayMs = Math.max(0, item.fireTimestampMs - nowMs);
    if (minDelayMs === null || delayMs < minDelayMs) {
      minDelayMs = delayMs;
    }
  }
  return minDelayMs;
}

function needsFastTimerInterval(host: MenuMijiaWindowsApp, nowMs: number): boolean {
  if (host.isPanelVisible()) return true;
  if (!isUndoHoverPaused(host) && host.lastUndoAction && host.lastUndoAction.expiresAtMs > nowMs) {
    return true;
  }
  const schedDelayMs = nextScheduledCommandDelayMs(host, nowMs);
  return schedDelayMs !== null && schedDelayMs <= SUB_MINUTE_SCHEDULE_WINDOW_MS;
}

function canScheduleBackgroundCloudRefresh(host: ResumeRecoveryHost): boolean {
  if (!host.isSyncingCloud) return canRefreshDevicesInBackground(host);
  return canRefreshDevicesInBackground({ ...host, isSyncingCloud: false });
}

function nextHiddenWakeTargetMs(
  host: MenuMijiaWindowsApp,
  state: HostLifecycleState,
  nowMs: number,
  intervalMs: number,
): number | null {
  let targetMs: number | null = null;
  const schedDelayMs = nextScheduledCommandDelayMs(host, nowMs);
  if (schedDelayMs !== null) {
    targetMs = nowMs + Math.max(1, schedDelayMs);
  }
  if (canScheduleBackgroundCloudRefresh(host)) {
    // The wake target follows the same interval the due check uses, so an idle closed panel is woken
    // at 120 s / 300 s instead of every 60 s once nothing on screen still depends on the poll.
    const pollIntervalMs = cloudRefreshIntervalMs(nowMs, host.isPanelVisible(), pollingDecayInputs(host));
    const anchorMs =
      host.lastCloudRefreshAt !== null && nowMs - host.lastCloudRefreshAt < pollIntervalMs
        ? host.lastCloudRefreshAt
        : state.lastTimerTickAtMs !== null && nowMs - state.lastTimerTickAtMs < pollIntervalMs
          ? state.lastTimerTickAtMs
          : host.isSyncingCloud
            ? nowMs
            : null;
    const pollTargetMs =
      anchorMs !== null ? anchorMs + pollIntervalMs : nowMs + intervalMs;
    if (targetMs === null || pollTargetMs < targetMs) {
      targetMs = pollTargetMs;
    }
  }
  const activityCadenceMs = nextBackgroundActivityCadenceMs(host);
  if (activityCadenceMs !== null) {
    const activityAnchorMs =
      state.lastTimerTickAtMs !== null && nowMs - state.lastTimerTickAtMs < activityCadenceMs
        ? state.lastTimerTickAtMs
        : nowMs;
    const activityTargetMs = activityAnchorMs + activityCadenceMs;
    if (targetMs === null || activityTargetMs < targetMs) {
      targetMs = activityTargetMs;
    }
  }
  return targetMs;
}

function instrumentHostTimerProperties(host: object, state: HostLifecycleState): void {
  for (const key of ["lastUndoAction", "scheduledCommands"] as const) {
    const desc = Object.getOwnPropertyDescriptor(host, key);
    if (!desc || !desc.configurable || !desc.writable || !("value" in desc)) continue;
    let currentValue = desc.value;
    Object.defineProperty(host, key, {
      configurable: true,
      enumerable: desc.enumerable,
      get() {
        return currentValue;
      },
      set(next) {
        currentValue = next;
        state.syncTimerSchedule?.();
      },
    });
  }
}

export function startTimerLoop(
  host: MenuMijiaWindowsApp,
  options: { readonly scheduler?: LifecycleScheduler; readonly intervalMs?: number } = {},
): () => void {
  const state = ensureLifecycleState(host);
  clearTimerInterval(state, host);
  state.disposed = false;
  instrumentHostTimerProperties(host, state);

  const ownerWin = host.root.ownerDocument?.defaultView ?? window;
  const scheduler = options.scheduler ?? createWindowLifecycleScheduler(ownerWin);
  const intervalMs = Math.max(1, options.intervalMs ?? 1000);
  state.timerScheduler = scheduler;

  const runTimerTick = (): void => {
    if (state.disposed || !isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }

    if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
      host.render();
    }

    if (isProactiveSuggestionsEnabled(host.settings) && proactiveHasConsumer(host)) {
      host.maybeRefreshProactiveInBackground();
    }

    const now = scheduler.now();
    state.lastTimerTickAtMs = now;
    // An expired undo row is a background change: defer its paint past a gesture. Scheduled
    // commands that just ran may render at once (CODING_STANDARDS.md section 16).
    let undoExpired = false;
    if (!isUndoHoverPaused(host) && host.lastUndoAction && host.lastUndoAction.expiresAtMs <= now) {
      host.lastUndoAction = null;
      undoExpired = true;
    }
    const miExpiryChanged = didMiExpiryKindChange(host, now);
    const activityChanged = tickSafetyHealthAndAutomation(host, now);

    if (runWithScheduledTimerTickExemption(() => processScheduledCommands(host, now))) {
      host.render();
    } else if (undoExpired || miExpiryChanged || activityChanged) {
      host.queueBackgroundRender();
    }

    if (
      canRefreshDevicesInBackground(host) &&
      cloudRefreshDue(now, host.lastCloudRefreshAt, host.isPanelVisible(), pollingDecayInputs(host))
    ) {
      void Promise.resolve(host.refreshDevices(true)).finally(() => {
        syncTimerSchedule();
      });
    }

    syncTimerSchedule();
  };

  const onWakeTimeout = (): void => {
    state.timerTimeoutHandle = null;
    state.timerTimeoutDueAtMs = null;
    runTimerTick();
  };

  const syncTimerSchedule = (): void => {
    if (state.disposed || state.timerScheduler !== scheduler) return;
    if (!isLifecycleHostAttached(host)) {
      disposeAppLifecycle(host);
      return;
    }
    const now = scheduler.now();
    if (needsFastTimerInterval(host, now)) {
      if (state.timerTimeoutHandle !== null) {
        scheduler.clearTimeout(state.timerTimeoutHandle);
        state.timerTimeoutHandle = null;
        state.timerTimeoutDueAtMs = null;
      }
      if (state.timerIntervalHandle === null) {
        state.timerIntervalHandle = scheduler.setInterval(runTimerTick, intervalMs);
      }
      return;
    }
    if (state.timerIntervalHandle !== null) {
      scheduler.clearInterval(state.timerIntervalHandle);
      state.timerIntervalHandle = null;
    }
    const targetMs = nextHiddenWakeTargetMs(host, state, now, intervalMs);
    if (targetMs === null) {
      if (state.timerTimeoutHandle !== null) {
        scheduler.clearTimeout(state.timerTimeoutHandle);
        state.timerTimeoutHandle = null;
        state.timerTimeoutDueAtMs = null;
      }
      return;
    }
    if (state.timerTimeoutHandle !== null && state.timerTimeoutDueAtMs === targetMs) {
      return;
    }
    if (state.timerTimeoutHandle !== null) {
      scheduler.clearTimeout(state.timerTimeoutHandle);
    }
    state.timerTimeoutDueAtMs = targetMs;
    state.timerTimeoutHandle = scheduler.setTimeout(onWakeTimeout, Math.max(1, targetMs - now));
  };

  state.syncTimerSchedule = syncTimerSchedule;
  syncTimerSchedule();

  return () => {
    clearTimerInterval(state, host);
  };
}
