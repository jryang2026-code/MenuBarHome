import { cancelScheduledCommands, confirmMissedScheduledCommand } from "./scheduledCommands.js";
import {
  IntentReply,
  IntentValidator,
  ManualControlPolicy,
  ModelActionPolicy,
} from "../core/assistant.js";
import {
  type DeviceCommand,
  type DeviceIntent,
  type FacetControl,
  type SmartDevice,
  applianceModeStartsHeating,
  deviceCanTogglePower,
  hasDetailDrawer,
  isDeviceActiveOn,
  localizeApplianceFanLevel,
  localizeApplianceMode,
  localizeHvacMode,
  localizeNightShot,
  localizeFridgeMode,
  localizeSwingMode,
} from "../core/models.js";
import {
  type PanelHeight,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  applyPanelOpacity,
  localizeFanMode,
  nextSize,
  normalizePanelOpacity,
  normalizeTileSize,
  scopedKey,
  withAliases,
} from "./panelPrefs.js";
import { t } from "../core/i18n.js";
import {
  formatTemperature,
  stepCelsius,
  toCelsius,
} from "../core/temperature.js";

import { invokeTauriVoid } from "./transport.js";
import {
  facetActionArguments,
  feedingConfirmationBannerText,
} from "../core/miCloud/feedAction.js";
import {
  bindDetailDrawerEvents,
  coverMotorRequiresConfirmation,
  ensureDrawerLifecycleListeners,
} from "./detailDrawers.js";
import {
  facetWriteEnabled,
  selectedPortionForControl,
} from "./facetViews.js";
import { facetTitle, facetValue } from "../core/miotFacetText.js";

import type { MenuMijiaWindowsApp } from "./app.js";
import { normalizeSearch } from "../core/panelSearch.js";
import { bindPanelInput, finishPanelComposition } from "./panelKeyboard.js";
import { bindRoomOrderEditorEvents } from "./roomOrderEditor.js";

function confirmHighRiskForHost(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  command: DeviceCommand,
  label: string,
  explicit?: { readonly summary: string; readonly intent: DeviceIntent },
  bannerOverride?: string,
): boolean {
  const actionKey = JSON.stringify(command);
  const armed = host.pendingHighRisk;
  if (
    armed &&
    armed.deviceId === deviceId &&
    armed.actionKey === actionKey &&
    armed.sourceRevision === host.sourceRevision &&
    armed.expiresAtMs > Date.now()
  ) {
    host.clearPendingHighRisk();
    return true;
  }
  host.setPendingHighRisk({
    deviceId,
    actionKey,
    expiresAtMs: Date.now() + 8000,
    sourceRevision: host.sourceRevision,
    ...(explicit
      ? { confirm: { command, summary: explicit.summary, intent: explicit.intent } }
      : {}),
  });
  host.replyBanner = {
    text:
      bannerOverride ??
      (explicit
        ? t("「{action}」属于高风险设备，确认后执行", { action: label })
        : t("「{action}」属于高风险设备，再点一次确认执行", { action: label })),
    source: t("需要确认"),
  };
  host.render();
  return false;
}

export function toggleDeviceForHost(host: MenuMijiaWindowsApp, id: string): void {
  const dev = host.devices.find((d) => d.id === id);
  if (!dev || dev.kind.kind === "sensor" || !deviceCanTogglePower(dev)) return;
  if (dev.kind.kind === "fridge") {
    host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
    host.render();
    return;
  }
  if (host.waitingDeviceIds.has(id)) return;
  // A momentary plug button only fires an activation; macOS always sends `.power(true)`,
  // even when Home Assistant still reports the button as on (#9).
  const isMomentaryPlug =
    dev.kind.kind === "plug" && dev.kind.switchEntityId.startsWith("button.");
  const nextOn = isMomentaryPlug || !isDeviceActiveOn(dev);
  const powerIntent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: nextOn } };
  const cmds = IntentValidator.commandsForIntent(powerIntent, dev);
  const firstCmd = cmds[0];
  if (!firstCmd) return;
  // Every manual toggle goes through the hazard table: a heater, plug, camera, vacuum or
  // generic card asks exactly like macOS `togglePrimary`. Stopping a moving cover is the one
  // cover de-escalation and never asks (#298, #143).
  const stopsMovingCover =
    dev.kind.kind === "cover" &&
    dev.kind.motion !== "stopped" &&
    dev.kind.pauseDescription !== null &&
    firstCmd.kind === "setSelectOption" &&
    firstCmd.option === dev.kind.pauseDescription;
  const hazard =
    dev.kind.kind === "cover"
      ? !stopsMovingCover &&
        coverMotorRequiresConfirmation(dev.kind.subtype, nextOn ? "open" : "close")
      : !stopsMovingCover &&
        ManualControlPolicy.requiresConfirmation(powerIntent, withAliases(host.layout, host.devices));
  if (
    hazard &&
    !confirmHighRiskForHost(host, dev.id, firstCmd, t(nextOn ? "打开{name}" : "关闭{name}", { name: dev.name }))
  ) {
    return;
  }
  host.poppedDeviceId = dev.id;
  const waitsForCloud = host.settings.connectionMode !== "demo";
  if (waitsForCloud) {
    host.waitingDeviceIds.add(id);
    host.render();
  }
  void host.executeSingleCommand(
    dev,
    firstCmd,
    t(nextOn ? "已打开{name}" : "已关闭{name}", { name: dev.name }),
    { targetId: dev.id, operation: { kind: "power", isOn: nextOn } },
    waitsForCloud,
  ).finally(() => {
    if (!waitsForCloud) return;
    host.waitingDeviceIds.delete(id);
    host.render();
  });
}

  export function bindEvents(host: MenuMijiaWindowsApp): void {
    ensureDrawerLifecycleListeners(host);
    host.root.querySelectorAll<HTMLDetailsElement>("details[data-notif-card]").forEach((details) => {
      details.addEventListener("toggle", () => {
        const key = details.dataset.notifCard;
        if (!key) return;
        if (details.open) {
          host.collapsedNotifCards.delete(key);
          details.scrollIntoView?.({ block: "nearest" });
        } else {
          host.collapsedNotifCards.add(key);
        }
      });
    });
    bindPanelInput(host);
    const micBtn = host.root.querySelector<HTMLButtonElement>("#btn-mic");
    micBtn?.addEventListener("click", () => {
      host.toggleVoiceInput();
    });

    host.root.querySelector("#btn-toggle-assistant")?.addEventListener("click", () => {
      host.isShowingAssistantBar = !host.isShowingAssistantBar;
      if (host.isShowingAssistantBar) {
        host.expandedDeviceId = null;
      }
      host.render();
      if (host.isShowingAssistantBar) {
        host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });

    host.bindAllOffControl();

    host.root.querySelector("#btn-done-editing")?.addEventListener("click", () => host.stopEditing());

    host.root.querySelector("#btn-home-menu")?.addEventListener("click", () => {
      host.isHomeMenuOpen = !host.isHomeMenuOpen;
      host.render();
    });
    host.root.querySelectorAll<HTMLElement>("[data-home]").forEach((btn) => {
      btn.addEventListener("click", () => host.selectHome(btn.dataset.home || null));
    });
    host.root.querySelectorAll<HTMLElement>("[data-close-menus]").forEach((el) => {
      el.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        host.isHomeMenuOpen = false;
        host.ctxMenu = null;
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-collapse]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = scopedKey(host.pageKey, btn.dataset.collapse ?? "");
        const set = new Set(host.layout.collapsed);
        if (set.has(key)) set.delete(key); else set.add(key);
        host.layout.collapsed = [...set];
        host.saveLayout();
        host.animateEntrance = !set.has(key);
        host.render();
      });
      btn.addEventListener("contextmenu", (e) => {
        const gid = btn.dataset.groupId;
        if (!gid) return;
        e.preventDefault();
        host.ctxMenu = { x: e.clientX, y: e.clientY, groupId: gid };
        host.render();
      });
    });

    const matchDeviceColonAttr = (raw: string | undefined): { dev: SmartDevice; rest: string } | null => {
      if (!raw) return null;
      let best: SmartDevice | null = null;
      for (const candidate of host.devices) {
        if (
          raw.startsWith(`${candidate.id}:`) &&
          raw.length > candidate.id.length + 1 &&
          (!best || candidate.id.length > best.id.length)
        ) {
          best = candidate;
        }
      }
      return best ? { dev: best, rest: raw.slice(best.id.length + 1) } : null;
    };

    host.root.querySelectorAll<HTMLElement>("[data-set-size]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.setSize ?? "";
        const sep = raw.lastIndexOf(":");
        const id = sep > 0 ? raw.slice(0, sep) : "";
        const size = sep > 0 ? raw.slice(sep + 1) : "";
        if (!id || !size) return;
        host.layout.tileSizes[scopedKey(host.pageKey, id)] = normalizeTileSize(size);
        host.saveLayout();
        host.ctxMenu = null;
        host.render();
      });
    });
    bindRoomOrderEditorEvents(host);
    host.root.querySelectorAll<HTMLElement>("[data-set-group]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.setGroup ?? "";
        const i = raw.lastIndexOf(":");
        const id = raw.slice(0, i);
        const gid = raw.slice(i + 1);
        if (gid) host.layout.groupMap[id] = gid; else delete host.layout.groupMap[id];
        host.saveLayout();
        host.ctxMenu = null;
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-new-group]").forEach((btn) => {
      btn.addEventListener("click", () => host.openPrompt({ kind: "newGroup", deviceId: btn.dataset.newGroup ?? "" }));
    });
    host.root.querySelectorAll<HTMLElement>("[data-rename-device]").forEach((btn) => {
      btn.addEventListener("click", () => host.openPrompt({ kind: "renameDevice", deviceId: btn.dataset.renameDevice ?? "" }));
    });
    host.root.querySelector("[data-start-editing]")?.addEventListener("click", () => {
      host.ctxMenu = null;
      host.startEditing();
    });
    host.root.querySelectorAll<HTMLElement>("[data-group-action]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const [action, gid] = (btn.dataset.groupAction ?? "").split(":");
        if (!gid) return;
        host.ctxMenu = null;
        const groups = host.layout.groups;
        const i = groups.findIndex((g) => g.id === gid);
        if (action === "rename") { host.openPrompt({ kind: "renameGroup", groupId: gid }); return; }
        if (action === "up" && i > 0) [groups[i - 1], groups[i]] = [groups[i]!, groups[i - 1]!];
        if (action === "down" && i >= 0 && i < groups.length - 1) [groups[i + 1], groups[i]] = [groups[i]!, groups[i + 1]!];
        if (action === "delete") {
          host.layout.groups = groups.filter((g) => g.id !== gid);
          for (const [d, g] of Object.entries(host.layout.groupMap)) if (g === gid) delete host.layout.groupMap[d];
        }
        host.saveLayout();
        host.render();
      });
    });

    const promptInput = host.root.querySelector<HTMLInputElement>("#prompt-input");
    if (promptInput && document.activeElement !== promptInput) {
      promptInput.focus();
      promptInput.select();
    }
    promptInput?.addEventListener("keydown", (e) => {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === "Enter") {
        e.preventDefault();
        host.savePrompt(promptInput.value);
      }
      if (e.key === "Escape") { e.stopPropagation(); host.closePrompt(); }
    });
    host.root.querySelector("#btn-prompt-save")?.addEventListener("click", () => host.savePrompt(promptInput?.value ?? ""));
    host.root.querySelector("#btn-prompt-reset")?.addEventListener("click", () => host.savePrompt(""));
    host.root.querySelectorAll<HTMLElement>("[data-prompt-cancel]").forEach((el) => el.addEventListener("click", () => host.closePrompt()));

    host.root.querySelectorAll<HTMLElement>("[data-cycle-size]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.cycleSize);
        if (!dev) return;
        host.layout.tileSizes[scopedKey(host.pageKey, dev.id)] = nextSize(host.tileSize(dev));
        host.saveLayout();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-acstep]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.acstep);
        if (!matched) return;
        const { dev, rest: dir } = matched;
        if (dev.kind.kind !== "climate") return;
        const k = dev.kind;
        const step = stepCelsius(k.step || 1);
        const next = k.targetTemperature + Number(dir) * step;
        // Round to the thermostat's own step so repeated °F taps do not drift off the °C grid.
        const snapped = Math.round(next / step) * step;
        const temperature = Math.min(k.maxTemp, Math.max(k.minTemp, Number(snapped.toFixed(2))));
        const command: DeviceCommand = { kind: "setClimateTemperature", entityId: k.entityId, temperature };
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "targetTemperature", celsius: temperature } };
        // macOS gates every climate write through `allowManualControl`: a heater's new target is
        // hazardous in both directions (#4, #143).
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, t("设为 {temp}", { temp: formatTemperature(temperature) }))
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(temperature) }),
          intent,
        );
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-acfan]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.acfan);
        if (!matched) return;
        const { dev, rest: fanMode } = matched;
        if (dev.kind.kind !== "climate") return;
        const command: DeviceCommand = { kind: "setClimateFanMode", entityId: dev.kind.entityId, fanMode };
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "fanSpeed", speed: fanMode } };
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, `${t("风速")} ${localizeFanMode(fanMode)}`)
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          t("已将{name}风速设为 {speed}", { name: dev.name, speed: localizeFanMode(fanMode) }),
          intent,
        );
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-acswing]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.acswing);
        if (!matched) return;
        const { dev, rest: swingMode } = matched;
        if (!swingMode || dev.kind.kind !== "climate") return;
        const command: DeviceCommand = {
          kind: "setSelectOption",
          entityId: dev.kind.entityId,
          option: swingMode,
        };
        const intent: DeviceIntent = {
          targetId: dev.id,
          operation: { kind: "oscillation", enabled: swingMode.toLowerCase() !== "off" },
        };
        const localized = localizeSwingMode(swingMode);
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, `${t("摆风")} ${localized}`)
        ) {
          return;
        }
        const summary = t("已将{name}摆风设为 {mode}", { name: dev.name, mode: localized });
        void host.executeSingleCommand(dev, command, summary, intent);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-appearance]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.appearance;
        host.settings.appearance =
          value === "light" || value === "dark" ? value : "system";
        host.saveSettings();
        host.render();
      });
    });
    const opacitySlider = host.root.querySelector<HTMLInputElement>("#settings-panel-opacity");
    if (opacitySlider) {
      // Dragging applies live without a re-render (which would drop the drag); releasing saves (#252).
      const applyOpacity = (): void => {
        host.settings.panelOpacity = normalizePanelOpacity(Number(opacitySlider.value));
        applyPanelOpacity(host.root, host.settings.panelOpacity);
        opacitySlider.setAttribute("aria-valuenow", String(host.settings.panelOpacity));
        const label = host.root.querySelector("#settings-panel-opacity-value");
        if (label) label.textContent = `${host.settings.panelOpacity}%`;
      };
      opacitySlider.addEventListener("input", applyOpacity);
      opacitySlider.addEventListener("change", () => {
        applyOpacity();
        host.saveSettings();
      });
    }
    host.root.querySelector("#btn-toggle-appearance")?.addEventListener("click", () => {
      host.settings.appearance = host.effectiveAppearance === "light" ? "dark" : "light";
      host.saveSettings();
      host.render();
    });
    host.root.querySelectorAll<HTMLElement>("[data-interface-language]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.interfaceLanguage;
        host.settings.interfaceLanguage =
          value === "zh-Hans" || value === "zh-Hant" || value === "en" ? value : "system";
        host.applyInterfaceLanguage();
        host.saveSettings();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-temperature-unit]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.temperatureUnit;
        host.settings.temperatureUnit =
          value === "celsius" || value === "fahrenheit" ? value : "system";
        host.applyTemperatureSetting();
        host.saveSettings();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-panel-height]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.settings.panelHeight = btn.dataset.panelHeight as PanelHeight;
        host.saveSettings();
        host.applyPanelHeight();
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-panel-anchor]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const known = PANEL_ANCHORS.find((item) => item.id === btn.dataset.panelAnchor);
        if (!known) return;
        host.panelAnchor = known.id;
        invokeTauriVoid("set_panel_placement", { anchor: known.id });
        host.render();
      });
    });
    host.root.querySelector<HTMLInputElement>("#settings-climate-panel")?.addEventListener("change", (e) => {
      host.settings.climatePanel = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-hide-offline")?.addEventListener("change", (e) => {
      host.settings.hideOfflineDevices = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-hide-grouped-lights")?.addEventListener("change", (e) => {
      host.settings.hideGroupedLights = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-quick-actions")?.addEventListener("change", (e) => {
      host.settings.showQuickActionsBar = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector<HTMLInputElement>("#settings-enable-hotkey")?.addEventListener("change", (e) => {
      host.settings.enableGlobalHotkey = (e.target as HTMLInputElement).checked;
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      host.saveSettings();
      void host.applyGlobalHotkey();
      host.render();
    });

    host.root.querySelector("#btn-record-hotkey")?.addEventListener("click", () => {
      host.isRecordingHotkey = !host.isRecordingHotkey;
      host.hotkeyNeedsHint = false;
      host.render();
    });

    host.root.querySelector("#btn-reset-hotkey")?.addEventListener("click", () => {
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      host.settings.globalHotkey = DEFAULT_GLOBAL_SHORTCUT;
      host.saveSettings();
      void host.applyGlobalHotkey();
      host.render();
    });

    host.root.querySelector("#btn-retry-hotkey")?.addEventListener("click", () => {
      void host.applyGlobalHotkey();
    });

    host.root.querySelector("#btn-hide-panel")?.addEventListener("click", () => {
      invokeTauriVoid("set_pin_popover", { pin: false });
      invokeTauriVoid("hide_panel");
    });

    host.root.querySelector("#btn-quit-app")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    host.root.querySelector("#btn-settings-quit")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    host.root.querySelector("#btn-toggle-grid")?.addEventListener("click", () => {
      host.settings.isCompactGridMode = !host.settings.isCompactGridMode;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-toggle-hide-offline")?.addEventListener("click", () => {
      host.settings.hideOfflineDevices = !host.settings.hideOfflineDevices;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-show-offline")?.addEventListener("click", () => {
      host.settings.hideOfflineDevices = false;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-refresh")?.addEventListener("click", () => {
      if (host.settings.connectionMode === "homeAssistant" || host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession) {
        void host.refreshDevices(false);
      } else {
        host.render();
      }
    });

    // The QR code lives on the sources tab, so signing in lands there instead of on 外观与面板.
    const startQrLogin = () => {
      host.openSettingsSheet("connection");
      void host.startXiaomiQRLogin();
    };
    host.root.querySelector("#btn-footer-qr")?.addEventListener("click", startQrLogin);
    host.root.querySelector("#btn-footer-health")?.addEventListener("click", startQrLogin);
    host.root.querySelector("#btn-dismiss-banner")?.addEventListener("click", () => {
      host.replyBanner = null;
      host.render();
    });

    host.root.querySelector("#btn-empty-resync")?.addEventListener("click", () => {
      void host.refreshDevices(false);
    });

    host.root.querySelector("#btn-empty-settings")?.addEventListener("click", () => {
      host.openSettingsSheet("connection");
    });

    // A home whose devices the cloud hid leaves the panel empty until the user goes back to all homes.
    host.root.querySelector("#btn-empty-all-homes")?.addEventListener("click", () => {
      host.settings.selectedHomeId = null;
      host.selectRoom(null);
      host.saveSettings();
      host.render();
      void host.refreshDevices(false);
    });

    host.root.querySelector("#btn-settings")?.addEventListener("click", () => {
      host.openSettingsSheet();
    });

    host.root.querySelector("#btn-undo")?.addEventListener("click", () => {
      void host.performUndo();
    });

    host.root.querySelectorAll<HTMLElement>("[data-suggestion-id]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const suggestion = host.pendingSuggestions.find((s) => s.id === btn.dataset.suggestionId);
        if (!suggestion) return;
        host.pendingSuggestions = host.pendingSuggestions.filter((s) => s.id !== suggestion.id);
        const aliasedDevices = withAliases(host.layout, host.devices);
        const intents = IntentValidator.sanitize(suggestion.intents, aliasedDevices, host.scenes);
        // Picking a bare-category open candidate is still a manual control on a high-risk device (#274).
        if (
          suggestion.id.startsWith("bare:on:") &&
          intents.some((intent) => ManualControlPolicy.requiresConfirmation(intent, aliasedDevices))
        ) {
          host.pendingSuggestions = ModelActionPolicy.chips(intents, null, "confirm:bare", aliasedDevices, host.scenes, true);
          host.replyBanner = {
            text: t("「{action}」属于高风险设备，再点一次确认执行", {
              action: IntentReply.describe(intents, aliasedDevices, host.scenes).replace(/^已/, ""),
            }),
            source: t("需要确认"),
          };
          host.render();
          return;
        }
        void host.executeIntents(intents, IntentReply.describe(intents, aliasedDevices, host.scenes), t("已确认"), { recordHabits: true });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-run-missed]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const item = host.missedScheduledCommands.find((c) => c.id === btn.dataset.runMissed);
        if (!item) return;
        void confirmMissedScheduledCommand(host, item.id);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-dismiss-missed]").forEach((btn) => {
      btn.addEventListener("click", () => {
        cancelScheduledCommands(host, btn.dataset.dismissMissed);
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cancel-timer]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.cancelTimer;
        cancelScheduledCommands(host, id);
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-scene-cmd]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const cmd = btn.dataset.sceneCmd;
        if (cmd) void host.handleNaturalCommand(cmd);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-ha-scene]").forEach((button) => {
      button.addEventListener("click", () => {
        const scene = host.scenes.find((item) => item.id === button.dataset.haScene);
        if (!scene) return;
        const intents: DeviceIntent[] = [{targetId:scene.id,operation:{kind:"activateScene"}}];
        void host.executeIntents(intents, IntentReply.describe(intents, host.devices, host.scenes), t("0ms 本地直达"), {recordHabits:true});
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-proactive-id]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const suggestion = host.currentProactiveSuggestions().find((s) => s.id === btn.dataset.proactiveId);
        if (!suggestion) return;
        const aliasedDevices = withAliases(host.layout, host.devices);
        const intents = IntentValidator.sanitize(suggestion.intents, aliasedDevices, host.scenes);
        if (intents.length === 0) return;
        host.isShowingAssistantBar = true;
        void host.executeIntents(intents, IntentReply.describe(intents, aliasedDevices, host.scenes), t("猜你想控"), { recordHabits: true });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-open-camera]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.openCamera;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (dev && dev.kind.kind === "camera" && deviceCanTogglePower(dev) && dev.isOnline && !dev.kind.isOn) {
          toggleDeviceForHost(host, id);
        }
        host.cameraLive.openCameraLiveView(id);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-room]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.selectRoom(btn.dataset.roomId ?? null, btn.dataset.room);
        host.animateEntrance = true;
        host.expandedDeviceId = null;
        host.render();
        host.root.querySelector(".cc-room-pill.is-active")?.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-kind]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const tag = host.kindTagFromDataset(btn.dataset.kind);
        if (!tag) return;
        host.selectDeviceKind(tag);
        host.animateEntrance = true;
        host.expandedDeviceId = null;
        host.render();
        host.root.querySelector(`[data-kind="${tag}"]`)?.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
      });
    });

    /**
     * A high-risk manual write asks for one more tap on the same card within a few seconds, and
     * the arm is bound to that exact command: a different high-risk write on the same device
     * re-arms instead of spending the previous tap. The window expires so an old tap can never
     * authorise a later write (macOS 再点一次确认). A control that cannot repeat its value (the
     * climate slider) passes `explicit`, which renders one confirm button for the captured command.
     */
    const confirmHighRisk = (
      deviceId: string,
      command: DeviceCommand,
      label: string,
      explicit?: { readonly summary: string; readonly intent: DeviceIntent },
      bannerOverride?: string,
    ): boolean => confirmHighRiskForHost(host, deviceId, command, label, explicit, bannerOverride);

    host.root.querySelectorAll<HTMLElement>("[data-high-risk-confirm]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.highRiskConfirm;
        const armed = host.pendingHighRisk;
        if (!id || !armed?.confirm || armed.deviceId !== id) return;
        const expired = armed.expiresAtMs <= Date.now();
        const stale = armed.sourceRevision !== host.sourceRevision;
        // Consume before sending: the row must disappear before the network call finishes.
        host.clearPendingHighRisk();
        if (expired) {
          host.replyBanner = { text: t("确认已过期，请重新操作"), source: t("需要确认") };
        }
        host.render();
        if (expired || stale) return;
        const dev = host.devices.find((device) => device.id === id);
        if (!dev) return;
        void host.executeSingleCommand(dev, armed.confirm.command, armed.confirm.summary, armed.confirm.intent);
      });
    });

    /** Three `|`-separated parts, for rows whose value is itself a segment (`id|control|value`). */
    const splitChoice = (raw: string | undefined): [string, string, string] | null => {
      if (!raw) return null;
      const first = raw.indexOf("|");
      const second = first < 0 ? -1 : raw.indexOf("|", first + 1);
      if (first <= 0 || second <= 0) return null;
      return [raw.slice(0, first), raw.slice(first + 1, second), raw.slice(second + 1)];
    };

    const toggleDeviceById = (id: string) => {
      toggleDeviceForHost(host, id);
    };

    host.root.querySelectorAll<HTMLElement>("[data-toggle-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.toggleDevice;
        if (id) toggleDeviceById(id);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-body-device]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.bodyDevice;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev) return;
        const k = dev.kind.kind;
        const writable = deviceCanTogglePower(dev);
        if (k === "camera") {
          if (writable && dev.isOnline && !dev.kind.isOn) {
            toggleDeviceById(id);
          }
          host.cameraLive.openCameraLiveView(id);
        } else if (hasDetailDrawer(dev, host.deviceFacets[id] ?? [])) {
          // macOS card body: after the camera special case the drawer wins, so a vacuum, plug or
          // cover with 更多设置 rows expands instead of running its switch.
          host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
          host.render();
        } else if (writable) {
          toggleDeviceById(id);
        }
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-expand-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.expandDevice ?? null;
        host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-reveal-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.revealDevice ?? null;
        if (!id) return;
        const alreadyVisibleSubpage =
          host.root.querySelector<HTMLElement>(".cc-tile.is-subpage")?.dataset.tileId === id;
        if (alreadyVisibleSubpage) {
          host.expandedDeviceId = null;
          host.render();
          return;
        }
        if (host.isEditingLayout) {
          host.stopEditing();
        }
        if (host.panelSearch.isComposing) {
          finishPanelComposition(host);
        }
        if (!host.presentationDevices.some((d) => d.id === id) && normalizeSearch(host.panelSearch.query)) {
          host.panelSearch.query = "";
          host.panelSearch.selectedDeviceId = null;
          host.panelSearch.explicitSelection = false;
          const searchInput = host.root.querySelector<HTMLInputElement>("#command-input");
          if (searchInput) searchInput.value = "";
        }
        if (!host.presentationDevices.some((d) => d.id === id)) {
          host.selectRoom(null);
        }
        if (!host.presentationDevices.some((d) => d.id === id)) {
          return;
        }
        host.expandedDeviceId = id;
        host.render();
        if (!host.root.querySelector(".cc-tile.is-subpage")) {
          const inlineTile = Array.from(host.root.querySelectorAll<HTMLElement>("[data-tile-id]")).find(
            (tile) => tile.dataset.tileId === id,
          );
          inlineTile?.scrollIntoView?.({ block: "nearest" });
        }
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-lighteffect]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.lighteffect);
        const effect = btn.dataset.effect;
        if (!dev || dev.kind.kind !== "light" || !effect) return;
        void host.executeSingleCommand(
          dev,
          { kind: "setLightEffect", entityId: dev.kind.entityId, effect },
          t("已切换{name}灯光模式", { name: dev.name }),
          { targetId: dev.id, operation: { kind: "lightEffect", effect } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-brightness]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.brightness;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const percent = Number(slider.value);
        void host.executeSingleCommand(
          dev,
          { kind: "setLightBrightness", entityId: dev.kind.entityId, percent },
          t("已将{name}亮度设为 {percent}%", { name: dev.name, percent: percent }),
          { targetId: dev.id, operation: { kind: "brightness", percent } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-colortemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.colortemp;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const kelvin = Number(slider.value);
        void host.executeSingleCommand(
          dev,
          { kind: "setLightColorTemp", entityId: dev.kind.entityId, kelvin },
          t("已将{name}色温设为 {kelvin}K", { name: dev.name, kelvin: kelvin }),
          { targetId: dev.id, operation: { kind: "colorTemperature", kelvin } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-actemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.actemp;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        // The slider works in display units; the command carries Celsius (#52). Clamp to the
        // device's supported Celsius bounds so rounded Fahrenheit limits never exceed [minTemp, maxTemp].
        const rawCelsius = toCelsius(Number(slider.value));
        const clampedCelsius = Math.min(dev.kind.maxTemp, Math.max(dev.kind.minTemp, rawCelsius));
        const temperature = Number(clampedCelsius.toFixed(2));
        const command: DeviceCommand = { kind: "setClimateTemperature", entityId: dev.kind.entityId, temperature };
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "targetTemperature", celsius: temperature } };
        const summary = t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(temperature) });
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, t("设为 {temp}", { temp: formatTemperature(temperature) }), { summary, intent })
        ) {
          return;
        }
        void host.executeSingleCommand(dev, command, summary, intent);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-acmode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.acmode);
        if (!matched) return;
        const { dev, rest: hvacMode } = matched;
        if (!hvacMode || dev.kind.kind !== "climate") return;
        const command: DeviceCommand = { kind: "setClimateMode", entityId: dev.kind.entityId, hvacMode };
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "hvacMode", mode: hvacMode } };
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, t("切换到{mode}", { mode: localizeHvacMode(hvacMode) }))
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          t("已切换{name}模式", { name: dev.name }),
          intent,
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fanpreset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.fanpreset);
        if (!matched) return;
        const { dev, rest: presetMode } = matched;
        if (!presetMode || dev.kind.kind !== "fan") return;
        void host.executeSingleCommand(
          dev,
          { kind: "setFanPresetMode", entityId: dev.kind.entityId, presetMode },
          t("已将{name}设为 {speed}", { name: dev.name, speed: IntentReply.fanSpeedLabel(presetMode) }),
          { targetId: dev.id, operation: { kind: "fanSpeed", speed: presetMode } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-fanpercent]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.fanpercent;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        const percent = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
        void host.executeSingleCommand(
          dev,
          { kind: "setFanPercentage", entityId: dev.kind.entityId, percent },
          t("已将{name}风速设为 {speed}", { name: dev.name, speed: `${percent}%` }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fanosc]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.fanosc;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        const nextOsc = !dev.kind.isOscillating;
        void host.executeSingleCommand(
          dev,
          { kind: "setFanOscillating", entityId: dev.kind.entityId, oscillating: nextOsc },
          t("已{action}{name}摇头", { action: nextOsc ? t("开启") : t("关闭"), name: dev.name }),
          { targetId: dev.id, operation: { kind: "oscillation", enabled: nextOsc } },
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-camera-live]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.cameraLive;
        if (id) host.cameraLive.openCameraLiveView(id);
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-volume]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const dev = host.devices.find((d) => d.id === slider.dataset.volume);
        if (!dev || dev.kind.kind !== "speaker" || !dev.kind.volumeWritable) return;
        const percent = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
        void host.executeSingleCommand(
          dev,
          { kind: "mediaSetVolume", entityId: dev.kind.mediaEntityId, level: percent / 100 },
          t("已将{name}音量设为 {percent}%", { name: dev.name, percent }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-speakermute]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.speakermute);
        if (!dev || dev.kind.kind !== "speaker" || !dev.kind.muteSwitchEntityId) return;
        const next = !dev.kind.isMuted;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.muteSwitchEntityId, isOn: next },
          t("已{action}{name}静音", { action: next ? t("开启") : t("关闭"), name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-speakersleep]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.speakersleep);
        if (!dev || dev.kind.kind !== "speaker" || !dev.kind.sleepModeEntityId) return;
        const next = !dev.kind.isSleepMode;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.sleepModeEntityId, isOn: next },
          t("已{action}{name}睡眠模式", { action: next ? t("开启") : t("关闭"), name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cameramotion]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.cameramotion;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "camera" || !dev.kind.motionDetectionEntityId) return;
        const nextMotion = !dev.kind.isMotionDetectionOn;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.motionDetectionEntityId, isOn: nextMotion },
          t("已{action}{name}移动侦测", { action: nextMotion ? t("开启") : t("关闭"), name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cameranight]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.cameranight);
        if (!matched) return;
        const { dev, rest: mode } = matched;
        if (!mode || dev.kind.kind !== "camera") return;
        void host.executeSingleCommand(
          dev,
          { kind: "setSelectOption", entityId: dev.kind.entityId, option: mode },
          t("已将{name}设为{mode}", { name: dev.name, mode: localizeNightShot(mode) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fridgemode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.fridgemode);
        if (!matched) return;
        const { dev, rest: mode } = matched;
        if (!mode || dev.kind.kind !== "fridge" || !dev.kind.modeEntityId) return;
        void host.executeSingleCommand(
          dev,
          { kind: "setSelectOption", entityId: dev.kind.modeEntityId, option: mode },
          t("已将{name}设为{mode}", { name: dev.name, mode: localizeFridgeMode(mode) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fridgestep]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const matched = matchDeviceColonAttr(btn.dataset.fridgestep);
        if (!matched) return;
        const { dev, rest } = matched;
        const [zone, deltaStr] = rest.split(":");
        const delta = Number(deltaStr);
        if (!zone || !Number.isFinite(delta) || dev.kind.kind !== "fridge") return;
        const isFreezer = zone === "freezer";
        const entityId = isFreezer ? dev.kind.freezerTargetEntityId : dev.kind.fridgeTargetEntityId;
        if (!entityId) return;
        const next = isFreezer
          ? Math.max(-24, Math.min(-15, dev.kind.freezerTargetTemp + delta))
          : Math.max(2, Math.min(8, dev.kind.fridgeTargetTemp + delta));
        void host.executeSingleCommand(
          dev,
          { kind: "setNumberValue", entityId, value: next },
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(next) }),
        );
      });
    });

    /** The `deviceId|value` pair every drawer control encodes. */
    const splitControlId = (raw: string | undefined): [string, string] | null => {
      if (!raw) return null;
      const sep = raw.indexOf("|");
      if (sep <= 0) return null;
      return [raw.slice(0, sep), raw.slice(sep + 1)];
    };

    const applianceFor = (id: string) => {
      const dev = host.devices.find((d) => d.id === id);
      return dev && dev.kind.kind === "appliance" ? dev : null;
    };

    host.root.querySelectorAll<HTMLElement>("[data-appliancetemp]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.appliancetemp);
        if (!pair) return;
        const [id, delta] = pair;
        const dev = applianceFor(id);
        if (!dev || dev.kind.kind !== "appliance") return;
        const spec = dev.kind;
        if (!spec.temperatureWritable || spec.targetTemperature === null) return;
        // One tap moves one degree in Fahrenheit, the spec's own step in Celsius (macOS parity).
        const step = stepCelsius(spec.step > 0 ? spec.step : 1);
        const raw = spec.targetTemperature + Number(delta) * step;
        const next = Math.min(spec.maxTemp, Math.max(spec.minTemp, Number((Math.round(raw / step) * step).toFixed(2))));
        if (next === spec.targetTemperature) return;
        const command: DeviceCommand = {
          kind: "setClimateTemperature",
          entityId: spec.temperatureEntityId,
          temperature: next,
        };
        if (
          spec.heats &&
          next > spec.targetTemperature &&
          !confirmHighRisk(dev.id, command, t("设为 {temp}", { temp: formatTemperature(next) }))
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(next) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-appliancemode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.appliancemode);
        if (!pair) return;
        const [id, mode] = pair;
        const dev = applianceFor(id);
        if (!dev || dev.kind.kind !== "appliance" || !dev.kind.modeWritable) return;
        const command: DeviceCommand = { kind: "setSelectOption", entityId: dev.kind.modeEntityId, option: mode };
        // Picking a heat mode from standby starts the heater, so it asks like the power button.
        if (
          dev.kind.heats &&
          !dev.kind.isOn &&
          applianceModeStartsHeating(mode) &&
          !confirmHighRisk(dev.id, command, t("切换到{mode}", { mode: localizeApplianceMode(mode) }))
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          t("已将{name}设为{mode}", { name: dev.name, mode: localizeApplianceMode(mode) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-appliancefan]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.appliancefan);
        if (!pair) return;
        const [id, level] = pair;
        const dev = applianceFor(id);
        if (!dev || dev.kind.kind !== "appliance" || !dev.kind.fanLevel?.writable) return;
        void host.executeSingleCommand(
          dev,
          { kind: "setClimateFanMode", entityId: dev.kind.fanLevel.entityId, fanMode: level },
          t("已将{name}风速调为 {level}", { name: dev.name, level: localizeApplianceFanLevel(level) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-appliancelight]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.appliancelight;
        if (!id) return;
        const dev = applianceFor(id);
        if (!dev || dev.kind.kind !== "appliance" || !dev.kind.light?.writable) return;
        const isOn = !dev.kind.light.isOn;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.light.entityId, isOn },
          isOn ? t("已打开{name}的灯光", { name: dev.name }) : t("已关闭{name}的灯光", { name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-applianceaction]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.applianceaction);
        if (!pair) return;
        const [id, kind] = pair;
        const dev = applianceFor(id);
        if (!dev || dev.kind.kind !== "appliance") return;
        const action =
          kind === "start"
            ? dev.kind.startAction
            : kind === "pause"
              ? dev.kind.pauseAction
              : dev.kind.stopAction;
        if (!action) return;
        const command: DeviceCommand = { kind: "pressButton", entityId: action.entityId };
        // Starting a cycle is the hazardous direction; pausing and stopping wind it down.
        if (kind === "start" && !confirmHighRisk(dev.id, command, t("开始{name}", { name: dev.name }))) return;
        void host.executeSingleCommand(
          dev,
          command,
          action.kind === "start"
            ? t("已开始{name}", { name: dev.name })
            : action.kind === "pause"
              ? t("已暂停{name}", { name: dev.name })
              : t("已停止{name}", { name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-vacuumaction]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.vacuumaction);
        if (!pair) return;
        const [id, action] = pair;
        if (action !== "start" && action !== "pause" && action !== "returnToBase") return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "vacuum") return;
        const command: DeviceCommand = { kind: "vacuumAction", entityId: dev.kind.entityId, action };
        // macOS `performVacuumAction`: starting is the hazardous direction, pausing and docking
        // wind it down. Stopping a moving vacuum never fights a dialog.
        const intent: DeviceIntent = {
          targetId: dev.id,
          operation: { kind: "power", isOn: action === "start" },
        };
        if (
          ManualControlPolicy.requiresConfirmation(intent, host.devices) &&
          !confirmHighRisk(dev.id, command, t("开始清扫"))
        ) {
          return;
        }
        void host.executeSingleCommand(
          dev,
          command,
          action === "start"
            ? t("已开始清扫{name}", { name: dev.name })
            : action === "pause"
              ? t("已暂停{name}", { name: dev.name })
              : t("已回充{name}", { name: dev.name }),
        );
      });
    });

    /** The 更多设置 row a write came from, or null when the cache is stale. */
    const facetFor = (deviceId: string, controlId: string): { dev: SmartDevice; control: FacetControl } | null => {
      const dev = host.devices.find((d) => d.id === deviceId);
      const control = host.deviceFacets[deviceId]?.find((item) => item.id === controlId);
      return dev && control ? { dev, control } : null;
    };

    bindDetailDrawerEvents(host, {
      splitControlId,
      splitChoice,
      facetFor,
      confirmHighRisk,
    });

    const writeFacet = (deviceId: string, controlId: string, value: unknown) => {
      const found = facetFor(deviceId, controlId);
      if (!found) return;
      const { dev, control } = found;
      if (!facetWriteEnabled(control, host.settings.allowAdvancedFacetWrites, dev.isOnline)) return;
      const target = control.target;
      if (!target) return;
      const isFeedAction =
        target.kind === "action" &&
        (control.portionArgumentIndex !== undefined ||
          control.fedToday !== undefined ||
          control.name.toLowerCase() === "pet-food-out");
      const portion =
        target.kind === "action" && (control.arguments?.length ?? 0) > 0
          ? selectedPortionForControl(deviceId, control)
          : null;
      const args = target.kind === "action" ? facetActionArguments(control, portion) : undefined;
      const command: DeviceCommand =
        target.kind === "action"
          ? {
              kind: "pressButton",
              entityId: target.entityId,
              ...(args && args.length > 0 ? { arguments: args } : {}),
            }
          : { kind: "setMiotProperty", entityId: target.entityId, piid: target.piid, value };
      const bannerOverride = isFeedAction
        ? feedingConfirmationBannerText(dev.name, control, portion)
        : undefined;
      if (
        ManualControlPolicy.facetRequiresConfirmation(control, value, dev) &&
        !confirmHighRisk(dev.id, command, facetTitle(control), undefined, bannerOverride)
      ) {
        return;
      }
      if (target.kind === "action") {
        const summary =
          isFeedAction && portion !== null
            ? t("已向{name}投喂 {count}", {
                name: dev.name,
                count: t("{count} 份", { count: portion }),
              })
            : t("已执行{name}的{control}", { name: dev.name, control: facetTitle(control) });
        void host.executeSingleCommand(dev, command, summary);
        return;
      }
      void host.executeSingleCommand(
        dev,
        command,
        t("已设置{name}的{control}为 {value}", {
          name: dev.name,
          control: facetTitle(control),
          value: facetValue({ ...control, value }),
        }),
      );
    };

    host.root.querySelectorAll<HTMLElement>("[data-facet-toggle]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.facetToggle);
        if (!pair) return;
        const [id, controlId] = pair;
        const found = facetFor(id, controlId);
        if (!found) return;
        const isOn = found.control.value === true || found.control.value === 1;
        writeFacet(id, controlId, isOn ? false : true);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-facet-select]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const choice = splitChoice(btn.dataset.facetSelect);
        if (!choice) return;
        const [deviceId, controlId, rawValue] = choice;
        const value = Number(rawValue);
        if (!Number.isFinite(value)) return;
        writeFacet(deviceId, controlId, value);
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-facet-number]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const pair = splitControlId(slider.dataset.facetNumber);
        if (!pair) return;
        const value = Number(slider.value);
        if (!Number.isFinite(value)) return;
        writeFacet(pair[0], pair[1], value);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-facet-action]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pair = splitControlId(btn.dataset.facetAction);
        if (!pair) return;
        writeFacet(pair[0], pair[1], null);
      });
    });

    host.cameraLive.bindEvents();

    host.bindSettingsEvents();

    syncAllRanges(host.root);
    bindDeckEvents(host);
  }

  function syncRangeFill(slider: HTMLInputElement): void {
    const min = Number(slider.min || 0);
    const max = Number(slider.max || 100);
    const val = Number(slider.value || 0);
    const pct = max > min ? Math.max(0, Math.min(100, ((val - min) / (max - min)) * 100)) : 0;
    slider.style.setProperty("--val", `${pct}%`);
  }

  function syncAllRanges(scope: ParentNode): void {
    scope.querySelectorAll<HTMLInputElement>("input.cc-range").forEach((slider) => {
      if (!slider.hasAttribute("data-deck-brightness") && !slider.hasAttribute("data-deck-volume")) {
        syncRangeFill(slider);
      }
      slider.addEventListener("input", () => {
        syncRangeFill(slider);
      });
    });
  }

  export function bindDeckEvents(host: MenuMijiaWindowsApp): void {
    const deck = host.root.querySelector<HTMLElement>(".win-slider-deck");
    if (!deck) return;

    deck.querySelectorAll<HTMLInputElement>("input.cc-range").forEach((slider) => {
      slider.addEventListener("input", () => {
        syncRangeFill(slider);
        const valLabel = slider.closest(".win-slider-row")?.querySelector(".win-deck-val");
        if (valLabel) valLabel.textContent = `${Math.round(Number(slider.value))}%`;
      });
    });

    deck.querySelectorAll<HTMLInputElement>("[data-deck-brightness]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.deckBrightness;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light" || dev.kind.brightnessWritable === false) return;
        const percent = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
        void host.executeSingleCommand(
          dev,
          { kind: "setLightBrightness", entityId: dev.kind.entityId, percent },
          t("已将{name}亮度设为 {percent}%", { name: dev.name, percent }),
          { targetId: dev.id, operation: { kind: "brightness", percent } },
        );
      });
    });

    deck.querySelectorAll<HTMLInputElement>("[data-deck-volume]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.deckVolume;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "speaker" || !dev.kind.volumeWritable) return;
        const percent = Math.max(0, Math.min(100, Math.round(Number(slider.value))));
        void host.executeSingleCommand(
          dev,
          { kind: "mediaSetVolume", entityId: dev.kind.mediaEntityId, level: percent / 100 },
          t("已将{name}音量设为 {percent}%", { name: dev.name, percent }),
        );
      });
    });

    deck.querySelectorAll<HTMLElement>("[data-deck-toggle]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.deckToggle;
        if (!id) return;
        toggleDeviceForHost(host, id);
      });
    });

    deck.querySelectorAll<HTMLElement>("[data-deck-mute]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.deckMute;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "speaker" || !dev.kind.muteSwitchEntityId) return;
        const next = !dev.kind.isMuted;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.muteSwitchEntityId, isOn: next },
          t("已{action}{name}静音", { action: next ? t("开启") : t("关闭"), name: dev.name }),
        );
      });
    });

    deck.querySelectorAll<HTMLElement>("[data-deck-expand]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.deckExpand;
        if (!id) return;
        host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
        host.render();
        if (host.expandedDeviceId === id && !host.root.querySelector(".cc-tile.is-subpage")) {
          const inlineTile = Array.from(host.root.querySelectorAll<HTMLElement>("[data-tile-id]")).find(
            (tile) => tile.dataset.tileId === id,
          );
          inlineTile?.scrollIntoView?.({ block: "nearest" });
        }
      });
    });
  }

