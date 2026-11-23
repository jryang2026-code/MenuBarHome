import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { patchCloudPresentation } from "../src/ui/cloudRefresh.js";
import { getCachedUnsupportedDeviceCountOnHost } from "../src/ui/connectionsAndDiagView.js";
import { renderUnsupportedDevicesQuietRow, unsupportedDevicesQuietRowText } from "../src/ui/panelView.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function makeLight(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomName: "客厅",
    roomId: "room-living",
    isOnline: true,
    sourceBackend: "homeAssistant",
    model: "yeelink.light.color4",
    kind: {
      kind: "light",
      entityId: `light.${id}`,
      isOn: true,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function makeHaSnapshotWithUnsupported(unsupportedCount: number): Record<string, unknown> {
  const areas: Array<Record<string, unknown>> = [
    { area_id: "living", name: "客厅" },
  ];
  const devices: Array<Record<string, unknown>> = [
    { id: "dev-supported", name: "客厅灯", model: "yeelink.light.color4", area_id: "living" },
  ];
  const entities: Array<Record<string, unknown>> = [
    { entity_id: "light.supported", device_id: "dev-supported" },
  ];
  const states: Array<Record<string, unknown>> = [
    { entity_id: "light.supported", state: "on", attributes: { friendly_name: "客厅灯" } },
  ];
  for (let i = 1; i <= unsupportedCount; i += 1) {
    const devId = `dev-unsupported-${i}`;
    const entId = `lawn_mower.bot_${i}`;
    devices.push({ id: devId, name: `未支持设备 ${i}`, model: `vendor.bot.${i}`, area_id: "living" });
    entities.push({ entity_id: entId, device_id: devId });
    states.push({ entity_id: entId, state: "docked", attributes: { friendly_name: `未支持设备 ${i}` } });
  }
  return { areas, devices, entities, states };
}

describe("Unsupported devices quiet row (#15)", () => {
  beforeEach(async () => {
    dom = await mountTestWindow();
    installCssEscape();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    setLanguage("zh-Hans");
    app?.dispose();
    app = null;
    await closeTestWindow(dom);
  });

  it("stays hidden when count is 0 or no cached scan exists, and never triggers a network scan", async () => {
    let haCalls = 0;
    const root = document.getElementById("app")!;
    app = new MenuMijiaWindowsApp(root);
    Object.defineProperty(app, "transport", {
      value: async () => {
        throw new Error("transport must not be called when rendering quiet row");
      },
      configurable: true,
    });
    app.settings.hasCompletedOnboarding = true;
    app.activeSheet = "none";
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.local:8123";
    app.settings.haToken = "token-secret-1234";
    app.devices = [makeLight("supported", "客厅灯")];
    app.render();

    assert.equal(getCachedUnsupportedDeviceCountOnHost(app), 0);
    assert.equal(renderUnsupportedDevicesQuietRow(app), "");
    assert.equal(document.querySelector("[data-unsupported-devices-row]"), null);
    assert.equal(haCalls, 0);

    // Render must not trigger or populate the scanner.
    const scanner = app.connDiagSession?.scanner;
    assert.equal(scanner?.lastScannedAtMs ?? null, null, "render must not trigger a scan");
    assert.equal(scanner?.devices.length ?? 0, 0);

    const { runUnsupportedDevicesScanOnHost } = await import("../src/ui/connectionsAndDiagView.js");
    const session = (await import("../src/ui/connectionsAndDiagView.js")).createDefaultHostConnDiagSession();
    session.haScannerInvokeOverride = async <T>() => {
      haCalls += 1;
      return makeHaSnapshotWithUnsupported(0) as T;
    };
    app.connDiagSession = session;
    await runUnsupportedDevicesScanOnHost(app);
    assert.equal(haCalls, 1);
    assert.equal(getCachedUnsupportedDeviceCountOnHost(app), 0);
    assert.equal(document.querySelector("[data-unsupported-devices-row]"), null);

    // Re-rendering never triggers another scan.
    app.render();
    assert.equal(haCalls, 1);
  });

  it("renders localized text for count 1 and N, invalidates on context change, and opens Settings on click", async () => {
    const root = document.getElementById("app")!;
    app = new MenuMijiaWindowsApp(root);
    app.settings.hasCompletedOnboarding = true;
    app.activeSheet = "none";
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.local:8123";
    app.settings.haToken = "token-secret-1234";
    app.devices = [makeLight("supported", "客厅灯")];

    const { createDefaultHostConnDiagSession, runUnsupportedDevicesScanOnHost } = await import(
      "../src/ui/connectionsAndDiagView.js"
    );
    let scanCountTarget = 1;
    let haCalls = 0;
    const session = createDefaultHostConnDiagSession();
    session.haScannerInvokeOverride = async <T>() => {
      haCalls += 1;
      return makeHaSnapshotWithUnsupported(scanCountTarget) as T;
    };
    app.connDiagSession = session;

    // Count = 1
    await runUnsupportedDevicesScanOnHost(app);
    assert.equal(haCalls, 1);
    assert.equal(getCachedUnsupportedDeviceCountOnHost(app), 1);

    setLanguage("zh-Hans");
    app.render();
    assert.equal(
      document.querySelector("#btn-unsupported-devices-row .cc-unsupported-quiet-label")?.textContent?.trim(),
      "1 台设备暂不支持显示",
    );

    setLanguage("zh-Hant");
    assert.equal(unsupportedDevicesQuietRowText(1), "1 臺裝置暫不支援顯示");

    setLanguage("en");
    assert.equal(unsupportedDevicesQuietRowText(1), "1 device not supported yet");

    // Count = 3
    scanCountTarget = 3;
    await runUnsupportedDevicesScanOnHost(app);
    assert.equal(haCalls, 2);
    assert.equal(getCachedUnsupportedDeviceCountOnHost(app), 3);

    setLanguage("zh-Hans");
    app.render();
    assert.equal(
      document.querySelector("#btn-unsupported-devices-row .cc-unsupported-quiet-label")?.textContent?.trim(),
      "3 台设备暂不支持显示",
    );
    assert.equal(patchCloudPresentation(app), true, "patchCloudPresentation keeps row when count matches");
    assert.equal(haCalls, 2, "rendering and DOM patching never trigger extra scans");

    setLanguage("zh-Hant");
    app.render();
    assert.equal(
      document.querySelector("#btn-unsupported-devices-row .cc-unsupported-quiet-label")?.textContent?.trim(),
      "3 臺裝置暫不支援顯示",
    );

    setLanguage("en");
    app.render();
    assert.equal(
      document.querySelector("#btn-unsupported-devices-row .cc-unsupported-quiet-label")?.textContent?.trim(),
      "3 devices not supported yet",
    );

    // Clicking opens Settings on the connection tab and highlights scanUnsupportedDevices.
    const rowBtn = document.querySelector<HTMLButtonElement>("#btn-unsupported-devices-row");
    assert.ok(rowBtn, "quiet row button should exist");
    rowBtn.click();
    assert.equal(app.activeSheet, "settings");
    assert.equal(app.settingsTab, "connection");
    const anchorEl = document.querySelector<HTMLElement>('[data-settings-anchor="scanUnsupportedDevices"]');
    assert.ok(anchorEl, "scanUnsupportedDevices section should exist in settings");
    assert.equal(anchorEl.getAttribute("data-settings-highlighted"), "scanUnsupportedDevices");
    assert.equal(anchorEl.closest("details")?.open, true);

    // Switching back to panel and changing HA URL hides the stale cached count without scanning.
    app.activeSheet = "none";
    app.settings.haBaseURL = "https://other-ha.example.local:8123";
    assert.equal(getCachedUnsupportedDeviceCountOnHost(app), 0);
    assert.equal(patchCloudPresentation(app), false, "patchCloudPresentation falls back when cached count drops to 0");
    app.render();
    assert.equal(document.querySelector("[data-unsupported-devices-row]"), null);
    assert.equal(haCalls, 2);
  });
});
