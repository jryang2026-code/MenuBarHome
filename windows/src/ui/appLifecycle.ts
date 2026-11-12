import { finishPanelComposition, handlePanelKey } from "./panelKeyboard.js";
import { processScheduledCommands } from "./scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import {
  UPDATE_RELEASES_PAGE,
  UPDATE_RELEASES_URL,
  UPDATE_STORAGE_KEY,
  checkForUpdate,
  isNewerVersion,
  parseUpdateState,
  serializeUpdateState,
} from "../core/updateChecker.js";
import { credentialsFromSettings, hasCredentials } from "../core/secureStore.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import { assistantEndpointIdentity, inferAssistantPreset } from "../core/assistant.js";
import { setLanguage, resolveLanguage } from "../core/i18n.js";
import { applyTemperatureUnit } from "../core/temperature.js";
import { cloudRefreshDue } from "../core/models.js";
import { normalizeGlobalShortcut, recordShortcutFromKeyEvent } from "./panelPrefs.js";
import { APP_VERSION } from "./appConstants.js";
import { trText } from "../core/quickActions.js";
import { invokeTauriVoid } from "./transport.js";
import { stripCredentialFieldsFromStoredCopies, writeSettingsForStorage } from "./settings.js";
import type { SettingsTab } from "./settingsViews.js";
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

  /**
   * First run after this version: move the plaintext copy into the Windows Credential
   * Manager, then rewrite localStorage without secrets (#28). Later runs read only the
   * credential store, so an upgrade needs no QR login again.
   */
export function initializeCredentials(host: MenuMijiaWindowsApp): void {
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
      return;
    }
    // A stale pre-1.0 copy can still hold secrets even when the v2 copy is clean (#28).
    stripCredentialFieldsFromStoredCopies();
    void hydrateCredentials(host);
  }

export async function hydrateCredentials(host: MenuMijiaWindowsApp): Promise<void> {
    try {
      const activePreset = inferAssistantPreset(host.settings.assistantBaseURL).id;
      const legacyOwnerEndpoint = host.settings.assistantLegacyKeyEndpoint ?? host.settings.assistantKeyEndpoint;
      const credentials = await host.credentialVault.load(activePreset, legacyOwnerEndpoint);
      if (!host.credentialVault.hasLegacyAssistantKey() && host.settings.assistantLegacyKeyEndpoint !== null) {
        host.settings.assistantLegacyKeyEndpoint = null;
        writeSettingsForStorage(host.settings);
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
      const effectiveCredentials = pendingSignOut ? { ...credentials, miSession: null } : credentials;
      if (!hasCredentials(effectiveCredentials)) {
        if (pendingSignOut) host.render();
        return;
      }
      if (effectiveCredentials.assistantApiKeys) {
        host.assistantKeysByPreset = { ...effectiveCredentials.assistantApiKeys, ...host.assistantKeysByPreset };
      }
      const current = credentialsFromSettings(host.settings, host.assistantKeysByPreset);
      if (!current.miSession && effectiveCredentials.miSession) host.settings.miSession = effectiveCredentials.miSession;
      if (current.haToken === "" && effectiveCredentials.haToken !== "") host.settings.haToken = effectiveCredentials.haToken;
      const currentEndpoint = assistantEndpointIdentity(host.settings.assistantBaseURL);
      const boundCustomEndpoint =
        host.settings.assistantCustomKeyEndpoint ?? host.settings.assistantKeyEndpoint ?? currentEndpoint;
      const activeSlotKey =
        activePreset === "custom"
          ? currentEndpoint !== null && currentEndpoint === boundCustomEndpoint
            ? host.assistantKeysByPreset.custom?.trim() ?? ""
            : ""
          : host.assistantKeysByPreset[activePreset]?.trim() ?? effectiveCredentials.assistantApiKey;
      if (host.settings.openRouterApiKey.trim() === "" && activeSlotKey !== "") {
        host.settings.openRouterApiKey = activeSlotKey;
        if (activePreset !== "custom") {
          host.settings.assistantKeyEndpoint = currentEndpoint;
        } else {
          host.settings.assistantCustomKeyEndpoint ??= boundCustomEndpoint;
          host.settings.assistantKeyEndpoint ??= host.settings.assistantCustomKeyEndpoint;
        }
      }
      if (host.settings.miSession) {
        host.settings.hasCompletedOnboarding = true;
        host.settings.miCloudRegion = normalizeMiCloudRegion(host.settings.miSession.region);
        if (host.activeSheet === "onboarding") host.activeSheet = "none";
      }
      submitServiceEndpoints(host);
      writeSettingsForStorage(host.settings);
      if (host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession) {
        void host.refreshDevices(true);
      }
      if (host.settings.connectionMode === "homeAssistant") {
        const cache = host.settings.cachedHAHome;
        if (cache?.identity === homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken)) {
          host.devices = structuredClone(cache.home.devices);
          host.scenes = structuredClone(cache.home.scenes);
          host.environmentReadings = structuredClone(cache.home.environmentReadings);
          host.deviceFacets = structuredClone(cache.home.deviceFacets ?? {});
        }
      }
      host.render();
      if (host.settings.connectionMode === "homeAssistant") void host.refreshHADevices();
    } catch {
      if (host.settings.connectionMode === "homeAssistant") {
        host.haConnectionError = "Home Assistant credentials could not be loaded. Check Windows Credential Manager.";
        host.render();
      }
    } finally {
      host.timerCredentialsReady = true;
    }
  }

export async function persistCredentials(host: MenuMijiaWindowsApp): Promise<void> {
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
        text: trText(
          "无法将凭据保存到 Windows 凭据管理器，请检查系统凭据设置。",
          "Could not save credentials to Windows Credential Manager; check system settings.",
        ),
        source: t("出错提示"),
        isError: true,
      };
      host.render();
    }
  }

export function signOutXiaomiAccount(host: MenuMijiaWindowsApp): void {
    const retryOnly = !host.settings.miSession && host.settings.cachedXiaomiDevices.length === 0;
    if (retryOnly && !hasPendingMiVaultDeletion()) return;
    setPendingMiVaultDeletion(true);
    const wasXiaomiMode = host.settings.connectionMode === "xiaomiCloud";
    if (!retryOnly && wasXiaomiMode) {
      host.localControlRevision += 1;
      if (host.cameraLive.activeLiveCameraId !== null || host.cameraLive.liveCameraKeepAliveTimer !== null) {
        host.cameraLive.closeCameraLiveView();
      }
      host.invalidateSourceControl();
      host.devices = [];
      host.scenes = [];
      host.environmentReadings = [];
      host.homes = [];
      host.groupOwnerByMemberDid = new Map();
      host.deviceFacets = {};
      host.expandedDeviceId = null;
      host.waitingDeviceIds.clear();
      host.selectRoom(null);
    }
    host.settings.miSession = null;
    host.settings.cachedXiaomiDevices = [];
    host.settings.selectedHomeId = null;
    host.miSessionExpired = false;
    host.cloudValuesStale = false;
    host.unresolvedRoomDids.clear();
    host.qrTicket = null;
    host.qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
    host.replyBanner = {
      text: trText("已退出米家账号", "Signed out of Xiaomi Home"),
      source: trText("账号管理", "Account"),
    };
    writeSettingsForStorage(host.settings);
    submitServiceEndpoints(host, false);
    void (async () => {
      try {
        await host.credentialVault.persist(credentialsFromSettings(host.settings, host.assistantKeysByPreset));
        await host.credentialVault.deleteMiSession();
        setPendingMiVaultDeletion(false);
        host.render();
      } catch (error: unknown) {
        const detail = error instanceof Error && error.message.trim() ? ` (${error.message.trim()})` : "";
        host.replyBanner = {
          text: `${trText("无法从系统凭据库移除米家登录，请重试", "Could not remove Xiaomi sign-in from the OS credential vault; please retry")}${detail}`,
          source: t("出错提示"),
          isError: true,
        };
        host.render();
      }
    })();
    host.render();
  }

export function saveSettings(host: MenuMijiaWindowsApp, forceSubmitEndpoints = false): void {
    writeSettingsForStorage(host.settings);
    submitServiceEndpoints(host, forceSubmitEndpoints);
    void persistCredentials(host);
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
    const haUrl = host.settings.haBaseURL.trim();
    const serialized = `${assistantUrl}\n${haUrl}`;
    if (!force && serialized === host.lastSubmittedEndpoints) return;
    host.lastSubmittedEndpoints = serialized;
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    host.endpointSubmission = invoke("set_service_endpoints", {
      assistantUrl,
      haUrl,
    }).catch((error: unknown) => {
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
        const text = trText(
          "演示模式下不发起联网更新检查，切换真实数据源后再试。",
          "Update checks are disabled in demo mode; switch to a live source first.",
        );
        host.updateStatusMessage = { text, isError: false };
        host.replyBanner = { text, source: t("检查更新") };
        host.render();
      }
      return;
    }
    if (!manual && !window.__TAURI_INTERNALS__?.invoke) return;
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

    host.updateState = { lastCheckedAtMs: result.checkedAtMs, release: result.release };
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
export function openSettingsSheet(host: MenuMijiaWindowsApp, tab: SettingsTab = "general"): void {
    host.activeSheet = "settings";
    host.settingsTab = tab;
    invokeTauriVoid("set_pin_popover", { pin: true });
    host.syncPanelPlacement();
    host.render();
    void host.checkForAppUpdate(false);
  }

export function openUpdatePage(host: MenuMijiaWindowsApp): void {
    invokeTauriVoid("open_release_page", { url: host.availableUpdate?.htmlURL ?? UPDATE_RELEASES_PAGE });
  }

export async function startUpdateInstall(host: MenuMijiaWindowsApp): Promise<void> {
    if (host.isInstallingUpdate || !host.availableUpdate) return;
    if (host.settings.connectionMode === "demo") {
      const text = trText(
        "演示模式下不发起联网下载，切换真实数据源后再试。",
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
    if (host.activeSheet === "settings") {
      host.render();
    }
  }

export function bindGlobalKeys(host: MenuMijiaWindowsApp): void {
    window.addEventListener("blur", () => finishPanelComposition(host));
    window.addEventListener("keydown", (e) => {
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
          host.isRecordingHotkey = false;
          host.hotkeyNeedsHint = false;
          host.settings.globalHotkey = outcome.shortcut;
          host.saveSettings();
          void host.applyGlobalHotkey();
          host.render();
        }
        return;
      }

      if (handlePanelKey(host, e)) return;

      if (e.key === "Escape") {
        if (host.isGrokBallStageExpanded) {
          host.setGrokBallStageExpanded(false);
          return;
        }
        if (host.cameraLive.activeLiveCameraId !== null && !host.cameraLive.liveCameraHidden) {
          host.cameraLive.hideCameraLiveView();
          return;
        }
        if (hasPendingUrlConfirmation(host)) {
          dismissPendingUrlConfirmation(host, false);
          return;
        }
        if (host.activeSheet !== "none") {
          host.activeSheet = "none";
          host.isRecordingHotkey = false;
          host.hotkeyNeedsHint = false;
          invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });
          host.render();
        } else {
          resumeUndoHoverPause(host);
          invokeTauriVoid("hide_panel");
        }
      } else if (e.key === "/" && !e.ctrlKey && !e.metaKey && !e.altKey && document.activeElement?.tagName !== "INPUT") {
        e.preventDefault();
        host.isShowingAssistantBar = true;
        host.render();
        host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });
  }

export function startTimerLoop(host: MenuMijiaWindowsApp): void {
    window.setInterval(() => {
      if (host.pendingCloudRender && !host.hasBlockingPanelInteraction()) {
        host.render();
      }

      host.maybeRefreshProactiveInBackground();

      const now = Date.now();
      host.syncGrokBallEmotion();
      // An expired undo row is a background change: defer its paint past a gesture. Scheduled
      // commands that just ran may render at once (CODING_STANDARDS.md section 16).
      let undoExpired = false;
      if (!isUndoHoverPaused(host) && host.lastUndoAction && host.lastUndoAction.expiresAtMs <= now) {
        host.lastUndoAction = null;
        undoExpired = true;
      }
      const miExpiryChanged = didMiExpiryKindChange(host, now);

      if (runWithScheduledTimerTickExemption(() => processScheduledCommands(host, now))) {
        host.render();
      } else if (undoExpired || miExpiryChanged) {
        host.queueBackgroundRender();
      }

      if (
        (host.settings.connectionMode === "homeAssistant" || host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession) &&
        host.activeSheet === "none" &&
        !host.isSyncingCloud &&
        !host.isPollingQR &&
        cloudRefreshDue(now, host.lastCloudRefreshAt, host.isPanelVisible())
      ) {
        void host.refreshDevices(true);
      }
    }, 1000);
  }
