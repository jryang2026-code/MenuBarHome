import type { PollingDecayInputs } from "../core/pollingPolicy.js";
import { loadSensorAlertPolicy } from "../core/safetyAndHealth.js";
import { safetySignalsForPrefs } from "../core/safetySignalPolicy.js";
import { loadSafetyGuardPrefs } from "./automationSettingsView.js";

/**
 * The panel-interaction clock and the two decay gates, read from the host the timer loop and the
 * resume/recovery controller already hold. Windows mirrors macOS `HomeStore` here:
 * `HomeStore+Backend.swift:setPanelVisible` restarts the clock, and `HomeStore+Backend.swift:updatePollingContext`
 * stamps the two derived gates on every context change.
 */
export interface PollingDecayHost {
  /** Epoch ms of the last panel open/close; `null`/missing keeps the closed-panel interval flat. */
  lastPanelInteractionAtMs?: number | null;
}

/**
 * Restarts the idle clock. Opening or closing the panel is the user touching it, so the 30 min /
 * 2 h stretch never covers a moment the user is here (`HomeStore+Backend.swift:setPanelVisible`).
 */
export function notePanelInteraction(host: PollingDecayHost, nowMs: number = Date.now()): number {
  host.lastPanelInteractionAtMs = nowMs;
  return nowMs;
}

/**
 * An enabled alert is read out of the polled snapshots, so the poll must not slow down for being
 * idle: a leak or smoke reading that arrives four minutes late is a missed alert, not a staler
 * number (ADR-0023 §4). Every enabled safety signal counts — the sensor alert kinds have their own
 * switches below 安全与提醒's master switch, and 长通电 / 低电量 / 常用置顶离线 read the same
 * snapshots the poll refreshes.
 */
export function safetyAlertsRelyOnPolling(): boolean {
  return safetySignalsForPrefs(loadSafetyGuardPrefs(), loadSensorAlertPolicy()).length > 0;
}

/**
 * Windows keeps no polled number on screen outside the panel: the tray icon is the app logo, and its
 * tooltip is painted by Explorer only while the pointer rests on it, then rebuilt from the newest
 * snapshot (`speechGuard.syncDynamicTrayTooltip`). macOS answers the same question from the menu-bar
 * label (`HomeStore+Metrics.swift:menuBarShowsLiveReading`), which the user keeps in sight all day;
 * a Windows tray label added later must return `true` here and stop the stretch the same way.
 */
export function trayShowsLiveReading(): boolean {
  return false;
}

/**
 * The decay inputs for the current host and preferences. Windows has no Low Power Mode equivalent,
 * and a locked workstation is refused by `refreshDevices` itself rather than by the cadence, so
 * `PollingPolicy` only needs the clock and the two gates.
 */
export function pollingDecayInputs(host: PollingDecayHost): PollingDecayInputs {
  return {
    lastPanelInteractionAtMs: host.lastPanelInteractionAtMs ?? null,
    safetyAlertsRelyOnPolling: safetyAlertsRelyOnPolling(),
    menuBarShowsLiveReading: trayShowsLiveReading(),
  };
}
