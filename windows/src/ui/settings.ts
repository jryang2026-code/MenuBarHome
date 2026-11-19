import { assistantEndpointIdentity, inferAssistantPreset, resolveHabitSharing, type HabitEntry } from "../core/assistant.js";
import { AutomationRuleStore } from "../core/automationEngine.js";
import { normalizeCameraStreamQualityMap } from "../core/cameraQuality.js";
import {
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY,
  DUAL_SOURCE_ENABLED_STORAGE_KEY,
  PINNED_DEVICE_SOURCES_STORAGE_KEY,
  ROOM_IDENTITY_REGISTRY_STORAGE_KEY,
} from "../core/dualSourceProvider.js";
import { homeAssistantIdentity, parseCachedHAHome } from "../core/homeAssistant.js";
import {
  hasCorruptMiAccountIndex,
  hasSecondaryMiAccountsInIndex,
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
} from "../core/miAccountsStore.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import type { SmartDevice } from "../core/models.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY } from "../core/scheduledCommands.js";
import {
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_HEIGHTS,
  emptyLayoutPrefs,
  DEFAULT_PANEL_OPACITY,
  normalizeGlobalShortcut,
  normalizePanelOpacity,
  type PanelHeight,
} from "./panelPrefs.js";
import { DEFAULT_PANEL_THEME, normalizePanelTheme } from "./panelTheme.js";
import { parseMiSession, sanitizeSettingsForStorage } from "../core/secureStore.js";
import { CACHED_DEVICES_VERSION, LEGACY_STORAGE_KEY, STORAGE_KEY } from "./appConstants.js";
import type { ConnectionMode, LoadedSettings, PersistedSettings } from "./appTypes.js";

export function upgradeCachedDevices(devices: SmartDevice[], migrateLegacyFridgeCache: boolean): SmartDevice[] {
  return devices.map((dev) => {
    const m = dev.model.toLowerCase();
    if (
      dev.kind.kind === "plug" &&
      (m.includes("camera") || m.includes("cateye") || m.includes("doorbell"))
    ) {
      return {
        ...dev,
        kind: {
          kind: "camera",
          entityId: dev.kind.switchEntityId,
          isOn: dev.kind.isOn,
          nightShot: "Auto",
          availableNightShots: ["Off", "On", "Auto"],
          motionDetectionEntityId: null,
          isMotionDetectionOn: null,
          streamEntityId: null,
        },
      };
    }
    if (migrateLegacyFridgeCache && dev.kind.kind === "fridge") {
      // A legacy cache can carry ids from the guessed fallback; cloud re-synthesis
      // restores only verified writable targets afterwards (#148).
      return {
        ...dev,
        kind: {
          ...dev.kind,
          modeEntityId: null,
          availableModes: [],
          fridgeTargetEntityId: null,
          freezerTargetEntityId: null,
        },
      };
    }
    return dev;
  });
}

const AUXILIARY_LOCAL_DATA_KEYS = [
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
  DUAL_SOURCE_ENABLED_STORAGE_KEY,
  PINNED_DEVICE_SOURCES_STORAGE_KEY,
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY,
  ROOM_IDENTITY_REGISTRY_STORAGE_KEY,
  SCHEDULED_COMMANDS_STORAGE_KEY,
  AutomationRuleStore.storageKey,
] as const;

function hasCustomLayoutData(layout: unknown): boolean {
  if (!layout || typeof layout !== "object") return false;
  const obj = layout as Record<string, unknown>;
  for (const key of ["aliases", "roomAliases", "sizes", "groupMap"]) {
    const val = obj[key];
    if (val && typeof val === "object" && Object.keys(val as Record<string, unknown>).length > 0) return true;
  }
  for (const key of ["hiddenIds", "pinnedIds", "groups", "roomOrder", "kindOrder"]) {
    if (Array.isArray(obj[key]) && (obj[key] as unknown[]).length > 0) return true;
  }
  return false;
}

export function detectPersistedLocalData(parsed?: Partial<PersistedSettings> & Record<string, unknown>): boolean {
  if (parsed) {
    if (
      parseMiSession(parsed.miSession) !== null ||
      (typeof parsed.haBaseURL === "string" && parsed.haBaseURL.trim() !== "") ||
      (typeof parsed.haToken === "string" && parsed.haToken.trim() !== "") ||
      parseCachedHAHome(parsed.cachedHAHome) !== null ||
      (Array.isArray(parsed.cachedXiaomiDevices) && parsed.cachedXiaomiDevices.length > 0) ||
      parsed.dualSourceEnabled === true ||
      (Array.isArray(parsed.learnedShortcuts) && parsed.learnedShortcuts.length > 0) ||
      (Array.isArray(parsed.habitEntries) && parsed.habitEntries.length > 0) ||
      (typeof parsed.openRouterApiKey === "string" && parsed.openRouterApiKey.trim() !== "") ||
      (typeof parsed.assistantKeyEndpoint === "string" && parsed.assistantKeyEndpoint.trim() !== "") ||
      (parsed.allOffOverrides && typeof parsed.allOffOverrides === "object" && Object.keys(parsed.allOffOverrides).length > 0) ||
      (parsed.cameraStreamURLs && typeof parsed.cameraStreamURLs === "object" && Object.keys(parsed.cameraStreamURLs as Record<string, unknown>).length > 0) ||
      hasCustomLayoutData(parsed.layout)
    ) {
      return true;
    }
  }
  try {
    if (typeof localStorage === "undefined") return false;
    for (const key of AUXILIARY_LOCAL_DATA_KEYS) {
      const raw = localStorage.getItem(key);
      if (!raw) continue;
      const trimmed = raw.trim();
      if (trimmed === "" || trimmed === "false" || trimmed === "[]" || trimmed === "{}") continue;
      return true;
    }
  } catch {
    return false;
  }
  return false;
}

export interface LegacyMigrationDecision {
  readonly shouldShowOnboarding: boolean;
  readonly isLegacyStraightThrough: boolean;
  readonly identityReadFailure: string | null;
}

export function evaluateLegacyOnboardingMigration(
  loaded: LoadedSettings,
  options: {
    readonly hasVaultMiSession?: boolean;
    readonly hasVaultHaToken?: boolean;
    readonly hasSecondaryMiAccounts?: boolean;
    readonly identityReadFailure?: string | null;
  } = {},
): LegacyMigrationDecision {
  const readFailure =
    loaded.settingsReadError ??
    options.identityReadFailure ??
    (hasCorruptMiAccountIndex() ? "corrupt_mi_accounts_index" : null);
  if (readFailure) {
    return {
      shouldShowOnboarding: false,
      isLegacyStraightThrough: true,
      identityReadFailure: readFailure,
    };
  }
  const s = loaded.settings;
  const hasRealSource =
    s.miSession !== null ||
    Boolean(options.hasVaultMiSession) ||
    Boolean(options.hasSecondaryMiAccounts ?? hasSecondaryMiAccountsInIndex()) ||
    homeAssistantIdentity(s.haBaseURL, s.haToken) !== null ||
    Boolean(s.haBaseURL.trim() && options.hasVaultHaToken) ||
    s.cachedHAHome !== null ||
    s.cachedXiaomiDevices.length > 0 ||
    s.dualSourceEnabled === true;

  if (loaded.hasExplicitOnboardingFlag) {
    if (s.hasCompletedOnboarding || hasRealSource) {
      return { shouldShowOnboarding: false, isLegacyStraightThrough: hasRealSource && !s.hasCompletedOnboarding, identityReadFailure: null };
    }
    return { shouldShowOnboarding: true, isLegacyStraightThrough: false, identityReadFailure: null };
  }
  if (hasRealSource || loaded.hasPersistedLocalData || (loaded.hasPersistedSettings && s.hasCompletedOnboarding)) {
    return { shouldShowOnboarding: false, isLegacyStraightThrough: true, identityReadFailure: null };
  }
  return { shouldShowOnboarding: true, isLegacyStraightThrough: false, identityReadFailure: null };
}

export function loadSettings(): LoadedSettings {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORAGE_KEY) ?? localStorage.getItem(LEGACY_STORAGE_KEY);
  } catch {
    return {
      settings: buildDefaultSettings(),
      hasLegacyCredentials: false,
      hasPersistedSettings: false,
      hasExplicitOnboardingFlag: false,
      hasPersistedLocalData: false,
      settingsReadError: "settings_storage_read_error",
    };
  }
  try {
    if (raw) {
      const parsedRaw: unknown = JSON.parse(raw);
      if (!parsedRaw || typeof parsedRaw !== "object" || Array.isArray(parsedRaw)) {
        return {
          settings: buildDefaultSettings(),
          hasLegacyCredentials: false,
          hasPersistedSettings: true,
          hasExplicitOnboardingFlag: false,
          hasPersistedLocalData: true,
          settingsReadError: "corrupt_settings_storage",
        };
      }
      const parsed = parsedRaw as Partial<PersistedSettings> & Record<string, unknown>;
      const cachedDevicesVersion =
        typeof parsed.cachedDevicesVersion === "number" ? parsed.cachedDevicesVersion : 0;
      const rawHaToken = typeof parsed.haToken === "string" ? parsed.haToken : "";
      const rawApiKey = typeof parsed.openRouterApiKey === "string" ? parsed.openRouterApiKey : "";
      const hasLegacyCredentials =
        (parsed.miSession !== undefined && parsed.miSession !== null) || rawHaToken !== "" || rawApiKey !== "";
      const miSession = parseMiSession(parsed.miSession);
      const cachedHAHome = parseCachedHAHome(parsed.cachedHAHome);
      const hasHaHints =
        (typeof parsed.haBaseURL === "string" && parsed.haBaseURL.trim() !== "") ||
        rawHaToken !== "" ||
        cachedHAHome !== null;
      const hasExplicitOnboardingFlag = typeof parsed.hasCompletedOnboarding === "boolean";
      const hasPersistedLocalData = detectPersistedLocalData(parsed);
      const hasPersistedSettings = Object.keys(parsed).length > 0;
      const hasLegacyDataSource =
        miSession !== null ||
        hasHaHints ||
        (Array.isArray(parsed.cachedXiaomiDevices) && parsed.cachedXiaomiDevices.length > 0) ||
        parsed.dualSourceEnabled === true ||
        hasSecondaryMiAccountsInIndex();
      const mode: ConnectionMode = parsed.connectionMode === "demo" || parsed.connectionMode === "xiaomiCloud" || parsed.connectionMode === "homeAssistant"
        ? parsed.connectionMode
        : miSession
          ? "xiaomiCloud"
          : hasHaHints
            ? "homeAssistant"
            : hasExplicitOnboardingFlag && parsed.hasCompletedOnboarding === true
              ? "demo"
              : "xiaomiCloud";
      const habitShare = resolveHabitSharing(parsed.habitShareEnabled);
      if (habitShare.persistOff) {
        writeSettingsForStorage({ ...parsed, habitShareEnabled: false });
      }
      const resolvedKeyEndpoint =
        parsed.assistantKeyEndpoint !== undefined
          ? parsed.assistantKeyEndpoint
          : parsed.openRouterApiKey
            ? assistantEndpointIdentity(parsed.assistantBaseURL ?? "https://openrouter.ai/api/v1")
            : null;
      const assistantCustomKeyEndpoint =
        typeof parsed.assistantCustomKeyEndpoint === "string" || parsed.assistantCustomKeyEndpoint === null
          ? parsed.assistantCustomKeyEndpoint
          : resolvedKeyEndpoint && inferAssistantPreset(`https://${resolvedKeyEndpoint}`).id === "custom"
            ? resolvedKeyEndpoint
            : null;
      const assistantLegacyKeyEndpoint =
        typeof parsed.assistantLegacyKeyEndpoint === "string" || parsed.assistantLegacyKeyEndpoint === null
          ? parsed.assistantLegacyKeyEndpoint
          : resolvedKeyEndpoint;
      const askWhenUnsure = typeof parsed.askWhenUnsure === "boolean" ? parsed.askWhenUnsure : true;
      const hasCompletedOnboarding = hasExplicitOnboardingFlag
        ? (parsed.hasCompletedOnboarding as boolean)
        : hasLegacyDataSource ||
          hasPersistedLocalData ||
          (hasPersistedSettings && (parsed.connectionMode === "xiaomiCloud" || parsed.connectionMode === "homeAssistant"));
      const preDemoConnectionMode =
        parsed.preDemoConnectionMode === "xiaomiCloud" || parsed.preDemoConnectionMode === "homeAssistant"
          ? parsed.preDemoConnectionMode
          : null;
      const settings: PersistedSettings = {
        connectionMode: mode,
        ...(preDemoConnectionMode ? { preDemoConnectionMode } : {}),
        ...(typeof parsed.dualSourceEnabled === "boolean"
          ? { dualSourceEnabled: parsed.dualSourceEnabled }
          : {}),
        miSession,
        miCloudRegion: normalizeMiCloudRegion(parsed.miCloudRegion ?? miSession?.region),
        autoCheckUpdates: parsed.autoCheckUpdates ?? true,
        haBaseURL: parsed.haBaseURL ?? "",
        haToken: rawHaToken,
        assistantBaseURL: parsed.assistantBaseURL ?? "https://openrouter.ai/api/v1",
        openRouterApiKey: rawApiKey,
        assistantKeyEndpoint: resolvedKeyEndpoint,
        assistantCustomKeyEndpoint,
        assistantLegacyKeyEndpoint,
        cloudConsentEndpoints: Array.isArray(parsed.cloudConsentEndpoints)
          ? parsed.cloudConsentEndpoints.filter((e): e is string => typeof e === "string")
          : [],
        allOffOverrides:
          parsed.allOffOverrides && typeof parsed.allOffOverrides === "object"
            ? Object.fromEntries(
                Object.entries(parsed.allOffOverrides).filter((entry): entry is [string, boolean] => typeof entry[1] === "boolean"),
              )
            : {},
        assistantModel: parsed.assistantModel ?? "~typesafe/jev-latest",
        askWhenUnsure,
        habitLearningEnabled: parsed.habitLearningEnabled ?? true,
        habitShareEnabled: habitShare.sharing === "on",
        learnedShortcuts: parsed.learnedShortcuts ?? [],
        habitEntries: Array.isArray(parsed.habitEntries)
          ? parsed.habitEntries.filter(
              (e): e is HabitEntry =>
                typeof e?.bucket === "string" &&
                typeof e?.targetId === "string" &&
                typeof e?.operationKey === "string" &&
                typeof e?.count === "number",
            )
          : [],
        hasCompletedOnboarding,
        isCompactGridMode: parsed.isCompactGridMode ?? true,
        hideOfflineDevices: typeof parsed.hideOfflineDevices === "boolean" ? parsed.hideOfflineDevices : false,
        hideGroupedLights: typeof parsed.hideGroupedLights === "boolean" ? parsed.hideGroupedLights : true,
        allowAdvancedFacetWrites:
          typeof parsed.allowAdvancedFacetWrites === "boolean" ? parsed.allowAdvancedFacetWrites : false,
        cachedXiaomiDevices: Array.isArray(parsed.cachedXiaomiDevices)
          ? upgradeCachedDevices(
              parsed.cachedXiaomiDevices,
              cachedDevicesVersion < CACHED_DEVICES_VERSION,
            )
          : [],
        cachedDevicesVersion: Math.max(cachedDevicesVersion, CACHED_DEVICES_VERSION),
        cachedHAHome,
        cachedModelTypes:
          parsed.cachedModelTypes && typeof parsed.cachedModelTypes === "object"
            ? parsed.cachedModelTypes
            : {},
        appearance:
          parsed.appearance === "light" || parsed.appearance === "dark"
            ? parsed.appearance
            : "system",
        panelTheme: normalizePanelTheme(parsed.panelTheme),
        panelHeight: PANEL_HEIGHTS.some((h) => h.id === parsed.panelHeight) ? (parsed.panelHeight as PanelHeight) : "standard",
        panelOpacity: normalizePanelOpacity(parsed.panelOpacity),
        climatePanel: parsed.climatePanel ?? true,
        showQuickActionsBar: parsed.showQuickActionsBar ?? true,
        interfaceLanguage:
          parsed.interfaceLanguage === "zh-Hans" ||
          parsed.interfaceLanguage === "zh-Hant" ||
          parsed.interfaceLanguage === "en"
            ? parsed.interfaceLanguage
            : "system",
        temperatureUnit:
          parsed.temperatureUnit === "celsius" || parsed.temperatureUnit === "fahrenheit"
            ? parsed.temperatureUnit
            : "system",
        enableGlobalHotkey: typeof parsed.enableGlobalHotkey === "boolean" ? parsed.enableGlobalHotkey : true,
        globalHotkey: normalizeGlobalShortcut(parsed.globalHotkey),
        launchAtLogin: typeof parsed.launchAtLogin === "boolean" ? parsed.launchAtLogin : false,
        blockControlWhileLocked:
          typeof parsed.blockControlWhileLocked === "boolean" ? parsed.blockControlWhileLocked : true,
        // Only an explicit `false` turns voice off: older settings files have no key at all and
        // must keep the mic entry they had before the switch existed.
        voiceInputEnabled:
          typeof parsed.voiceInputEnabled === "boolean" ? parsed.voiceInputEnabled : true,
        enableRaycastIntegration:
          typeof parsed.enableRaycastIntegration === "boolean" ? parsed.enableRaycastIntegration : false,
        allowDirectURLControl:
          typeof parsed.allowDirectURLControl === "boolean" ? parsed.allowDirectURLControl : false,
        cameraStreamURLs:
          parsed.cameraStreamURLs && typeof parsed.cameraStreamURLs === "object"
            ? Object.fromEntries(
                Object.entries(parsed.cameraStreamURLs as Record<string, unknown>).filter(
                  (entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].trim().length > 0,
                ),
              )
            : {},
        cameraStreamQualities: normalizeCameraStreamQualityMap(parsed.cameraStreamQualities),
        layout: { ...emptyLayoutPrefs(), ...(parsed.layout ?? {}) },
        selectedHomeId: parsed.selectedHomeId ?? null,
        ...(typeof parsed.customHomeTitle === "string"
          ? { customHomeTitle: parsed.customHomeTitle.trim() }
          : {}),
      };
      return {
        settings,
        hasLegacyCredentials,
        hasPersistedSettings,
        hasExplicitOnboardingFlag,
        hasPersistedLocalData,
        settingsReadError: null,
      };
    }
  } catch {
    return {
      settings: buildDefaultSettings(),
      hasLegacyCredentials: false,
      hasPersistedSettings: true,
      hasExplicitOnboardingFlag: false,
      hasPersistedLocalData: true,
      settingsReadError: "corrupt_settings_storage",
    };
  }
  const hasAuxiliaryLocalData = detectPersistedLocalData();
  const defaults = buildDefaultSettings();
  if (hasAuxiliaryLocalData) {
    defaults.hasCompletedOnboarding = true;
  }
  return {
    settings: defaults,
    hasLegacyCredentials: false,
    hasPersistedSettings: false,
    hasExplicitOnboardingFlag: false,
    hasPersistedLocalData: hasAuxiliaryLocalData,
    settingsReadError: null,
  };
}

function buildDefaultSettings(): PersistedSettings {
  return {
    connectionMode: "xiaomiCloud",
    miSession: null,
    miCloudRegion: "cn",
    autoCheckUpdates: true,
    haBaseURL: "",
    haToken: "",
    assistantBaseURL: "https://openrouter.ai/api/v1",
    openRouterApiKey: "",
    assistantKeyEndpoint: null,
    assistantCustomKeyEndpoint: null,
    assistantLegacyKeyEndpoint: null,
    cloudConsentEndpoints: [],
    allOffOverrides: {},
    assistantModel: "~typesafe/jev-latest",
    askWhenUnsure: true,
    habitLearningEnabled: true,
    habitShareEnabled: false,
    learnedShortcuts: [],
    habitEntries: [],
    hasCompletedOnboarding: false,
    isCompactGridMode: true,
    hideOfflineDevices: false,
    hideGroupedLights: true,
    allowAdvancedFacetWrites: false,
    cachedXiaomiDevices: [],
    cachedDevicesVersion: CACHED_DEVICES_VERSION,
    cachedHAHome: null,
    cachedModelTypes: {},
    appearance: "system",
    panelTheme: DEFAULT_PANEL_THEME,
    panelHeight: "standard",
    panelOpacity: DEFAULT_PANEL_OPACITY,
    climatePanel: true,
    showQuickActionsBar: true,
    layout: emptyLayoutPrefs(),
    selectedHomeId: null,
    interfaceLanguage: "system",
    temperatureUnit: "system",
    enableGlobalHotkey: true,
    globalHotkey: DEFAULT_GLOBAL_SHORTCUT,
    launchAtLogin: false,
    blockControlWhileLocked: true,
    voiceInputEnabled: true,
    enableRaycastIntegration: false,
    allowDirectURLControl: false,
    cameraStreamURLs: {},
    cameraStreamQualities: {},
  };
}

export function readAskWhenUnsure(settings: { readonly askWhenUnsure?: boolean }): boolean {
  return typeof settings.askWhenUnsure === "boolean" ? settings.askWhenUnsure : true;
}

export function writeAskWhenUnsure(settings: { askWhenUnsure?: boolean }, enabled: boolean): void {
  settings.askWhenUnsure = enabled;
}

/** Writes settings without credentials; secrets belong to the Windows Credential Manager (#28). */
export function writeSettingsForStorage(settings: object): void {
  try {
    const normalized =
      "panelTheme" in settings
        ? { ...settings, panelTheme: normalizePanelTheme((settings as { panelTheme?: unknown }).panelTheme) }
        : settings;
    localStorage.setItem(STORAGE_KEY, JSON.stringify(sanitizeSettingsForStorage(normalized)));
  } catch {
    return;
  }
}

export function stripCredentialFieldsFromStoredCopies(): void {
  for (const key of [STORAGE_KEY, LEGACY_STORAGE_KEY]) {
    const raw = localStorage.getItem(key);
    if (!raw) continue;
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      localStorage.setItem(key, JSON.stringify(sanitizeSettingsForStorage(parsed)));
    } catch {
      continue;
    }
  }
}
