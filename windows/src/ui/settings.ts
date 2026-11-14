import { assistantEndpointIdentity, inferAssistantPreset, resolveHabitSharing, type HabitEntry } from "../core/assistant.js";
import { normalizeCameraStreamQualityMap } from "../core/cameraQuality.js";
import { parseCachedHAHome } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import type { SmartDevice } from "../core/models.js";
import {
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_HEIGHTS,
  emptyLayoutPrefs,
  DEFAULT_PANEL_OPACITY,
  normalizeGlobalShortcut,
  normalizePanelOpacity,
  type PanelHeight,
} from "./panelPrefs.js";
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

export function loadSettings(): LoadedSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY) ?? localStorage.getItem(LEGACY_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<PersistedSettings> & Record<string, unknown>;
      const cachedDevicesVersion =
        typeof parsed.cachedDevicesVersion === "number" ? parsed.cachedDevicesVersion : 0;
      const rawHaToken = typeof parsed.haToken === "string" ? parsed.haToken : "";
      const rawApiKey = typeof parsed.openRouterApiKey === "string" ? parsed.openRouterApiKey : "";
      const hasLegacyCredentials =
        (parsed.miSession !== undefined && parsed.miSession !== null) || rawHaToken !== "" || rawApiKey !== "";
      const miSession = parseMiSession(parsed.miSession);
      const mode: ConnectionMode = parsed.connectionMode === "demo" || parsed.connectionMode === "xiaomiCloud" || parsed.connectionMode === "homeAssistant"
        ? parsed.connectionMode
        : miSession ? "xiaomiCloud" : "demo";
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
      const settings: PersistedSettings = {
        connectionMode: mode,
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
        hasCompletedOnboarding: parsed.hasCompletedOnboarding ?? Boolean(miSession),
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
        cachedHAHome: parseCachedHAHome(parsed.cachedHAHome),
        cachedModelTypes:
          parsed.cachedModelTypes && typeof parsed.cachedModelTypes === "object"
            ? parsed.cachedModelTypes
            : {},
        appearance:
          parsed.appearance === "light" || parsed.appearance === "dark"
            ? parsed.appearance
            : "system",
        panelHeight: PANEL_HEIGHTS.some((h) => h.id === parsed.panelHeight) ? (parsed.panelHeight as PanelHeight) : "standard",
        panelOpacity: normalizePanelOpacity(parsed.panelOpacity),
        climatePanel: parsed.climatePanel ?? true,
        showQuickActionsBar: parsed.showQuickActionsBar ?? true,
        enableGrokBall: parsed.enableGrokBall ?? false,
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
      };
      return {
        settings,
        hasLegacyCredentials,
      };
    }
  } catch {
    return {
      settings: buildDefaultSettings(),
      hasLegacyCredentials: false,
    };
  }
  return {
    settings: buildDefaultSettings(),
    hasLegacyCredentials: false,
  };
}

function buildDefaultSettings(): PersistedSettings {
  return {
    connectionMode: "demo",
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
    panelHeight: "standard",
    panelOpacity: DEFAULT_PANEL_OPACITY,
    climatePanel: true,
    showQuickActionsBar: true,
    enableGrokBall: false,
    layout: emptyLayoutPrefs(),
    selectedHomeId: null,
    interfaceLanguage: "system",
    temperatureUnit: "system",
    enableGlobalHotkey: true,
    globalHotkey: DEFAULT_GLOBAL_SHORTCUT,
    launchAtLogin: false,
    blockControlWhileLocked: true,
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
    localStorage.setItem(STORAGE_KEY, JSON.stringify(sanitizeSettingsForStorage(settings)));
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
