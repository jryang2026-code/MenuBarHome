import { t } from "../core/i18n.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  UserHabitMemory,
  assistantEndpointIdentity,
  inferAssistantPreset,
  shareHabitSentence,
  type HabitLastAction,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import { joinsAllOffByDefault, type AssistantSuggestion, type EnvironmentReading, type FacetControl, type HomeScene, type SmartDevice } from "../core/models.js";
import { withAliases, type HomeOption, type LayoutPrefs } from "./panelPrefs.js";
import type { ConnectionMode, PendingHighRiskConfirmation, PersistedSettings, ReplyBannerState } from "./appTypes.js";
import { demoDevices, demoScenes } from "./demo.js";
import { invokeTauriVoid } from "./transport.js";
import type { SettingsTab } from "./settingsViews.js";
import type { GitHubRelease } from "../core/updateChecker.js";

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
}

export function bindSettingsEvents(host: SettingsEventsHost): void {
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

    host.root.querySelectorAll<HTMLElement>("[data-settings-tab]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const tab = btn.dataset.settingsTab;
        if (tab !== "general" && tab !== "connection" && tab !== "assistant" && tab !== "system") return;
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

    const closeOnboarding = () => {
      const keyInput = host.root.querySelector<HTMLInputElement>("#onboarding-api-key");
      if (keyInput && keyInput.value.trim()) {
        const trimmed = keyInput.value.trim();
        const preset = inferAssistantPreset(host.settings.assistantBaseURL);
        const endpoint = assistantEndpointIdentity(host.settings.assistantBaseURL);
        host.settings.openRouterApiKey = trimmed;
        host.assistantKeysByPreset[preset.id] = trimmed;
        host.settings.assistantKeyEndpoint = endpoint;
        if (preset.id === "custom") {
          host.settings.assistantCustomKeyEndpoint = endpoint;
        }
      }
      host.settings.hasCompletedOnboarding = true;
      host.saveSettings();
      host.activeSheet = "none";
      invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
      host.render();
    };

    host.root.querySelector("#btn-close-onboarding")?.addEventListener("click", closeOnboarding);
    host.root.querySelector("#btn-close-onboarding-alt")?.addEventListener("click", closeOnboarding);
    host.root.querySelector("#btn-finish-onboarding")?.addEventListener("click", closeOnboarding);

    host.root.querySelector("#btn-close-settings")?.addEventListener("click", () => {
      host.activeSheet = "none";
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
      host.render();
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
        if (!preset || !preset.defaultBaseURL) return;
        const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
        const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
        const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
        if (baseEl) baseEl.value = preset.defaultBaseURL;
        if (modelEl) modelEl.value = preset.defaultModel;
        if (apiKeyEl) {
          apiKeyEl.placeholder = preset.keyPlaceholder;
          host.syncKeyFieldWithEndpoint(apiKeyEl, preset.defaultBaseURL);
        }
        host.root.querySelectorAll<HTMLElement>("[data-ai-preset]").forEach((el) => {
          el.classList.toggle("is-active", el.dataset.aiPreset === preset.id);
        });
      });
    });

    host.root.querySelector<HTMLInputElement>("#settings-base-url")?.addEventListener("input", (event) => {
      const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
      const target = event.target as HTMLInputElement;
      if (apiKeyEl) host.syncKeyFieldWithEndpoint(apiKeyEl, target.value);
    });

    const refreshPreview = () => refreshHabitSharePreview(host);
    host.root.querySelector("#settings-habit-share")?.addEventListener("change", refreshPreview);
    host.root.querySelector("#settings-habit-share-sample")?.addEventListener("input", refreshPreview);
    refreshPreview();

    host.root.querySelector("#btn-save-settings")?.addEventListener("click", () => {
      const baseEl = host.root.querySelector<HTMLInputElement>("#settings-base-url");
      const apiKeyEl = host.root.querySelector<HTMLInputElement>("#settings-api-key");
      const modelEl = host.root.querySelector<HTMLInputElement>("#settings-model");
      const habitEl = host.root.querySelector<HTMLInputElement>("#settings-habit");
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
          if (host.settings.connectionMode === "homeAssistant") { host.devices = []; host.scenes = []; host.environmentReadings = []; }
        }
        host.settings.haBaseURL = endpoint;
      }
      if (haToken) {
        const token = haToken.value.trim();
        if (token !== host.settings.haToken) {
          host.invalidateSourceControl();
          host.settings.cachedHAHome = null;
          host.localControlRevision += 1;
          if (host.settings.connectionMode === "homeAssistant") { host.devices = []; host.scenes = []; host.environmentReadings = []; }
        }
        host.settings.haToken = token;
      }
      if (baseEl) host.settings.assistantBaseURL = baseEl.value.trim() || "https://openrouter.ai/api/v1";
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
      if (modelEl) host.settings.assistantModel = modelEl.value.trim() || fallbackModel;
      if (habitEl) host.settings.habitLearningEnabled = habitEl.checked;
      const habitShareEl = host.root.querySelector<HTMLInputElement>("#settings-habit-share");
      if (habitShareEl) host.settings.habitShareEnabled = habitShareEl.checked;
      host.saveSettings(true);
      if (host.settings.connectionMode === "homeAssistant") void host.refreshHADevices();
      host.activeSheet = "none";
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      invokeTauriVoid("set_pin_popover", { pin: host.shouldKeepPopoverPinned() });
      host.render();
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
