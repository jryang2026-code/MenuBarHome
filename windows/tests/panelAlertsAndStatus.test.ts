import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import { setLanguage } from "../src/core/i18n.js";
import { defaultSafetyStorage, saveSensorAlertPolicy } from "../src/core/safetyAndHealth.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { getHostActivityCenter, recordSafetyAlerts } from "../src/ui/activityStackView.js";
import { resolveConnectionStatus } from "../src/ui/connectionStatus.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
let dom: Window;
let app: MenuMijiaWindowsApp | null = null;
const el = <T extends HTMLElement = HTMLElement>(selector: string): T => {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
};
const text = (selector: string): string => el(selector).textContent?.trim() ?? "";
const click = (selector: string): void => el<HTMLButtonElement>(selector).click();
const escape = (): void => {
  window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
};
function startDemo(): MenuMijiaWindowsApp {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, interfaceLanguage: "zh-Hans" }));
  app = new MenuMijiaWindowsApp(el("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  return app;
}
function useMi(host: MenuMijiaWindowsApp): void {
  host.settings.connectionMode = "xiaomiCloud";
  host.settings.miSession = { userId: "90001234", cUserId: "", ssecurity: "x", serviceToken: "y", passToken: "", region: "cn" };
  host.render();
}
function useHA(host: MenuMijiaWindowsApp): void {
  host.settings.connectionMode = "homeAssistant";
  host.settings.haBaseURL = "http://localhost:8123";
  host.settings.haToken = "controlled-token";
  host.render();
}
const offline = (seq: number) => ({ id: `offline:plug.entry_socket:${seq}`, deviceId: "plug.entry_socket", category: "offline" as const, priority: "normal" as const, title: "玄关插座已离线", body: "" });
const battery = { id: "battery:sensor.living_env", deviceId: "sensor.living_env", category: "lowBattery" as const, priority: "normal" as const, title: "温湿度计电量低", body: "" };
const smoke = { id: "sensor:smoke:sensor.living_env:1700000000", deviceId: "sensor.living_env", category: "sensor" as const, priority: "high" as const, title: "厨房烟雾告警", body: "" };
const longrun = { id: "longrun:plug.entry_socket", deviceId: "plug.entry_socket", category: "longRun" as const, priority: "high" as const, title: "高功率长开", body: "" };
const sensor = (kind: string) => ({ id: `sensor:${kind}:sensor.living_env:1700000001`, deviceId: "sensor.living_env", category: "sensor" as const, priority: "normal" as const, title: `${kind} alert`, body: "" });

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
});
afterEach(async () => {
  app?.dispose();
  app = null;
  await closeTestWindow(dom);
});

describe("WP5b-1 · activity alert tiering", () => {
  it("pins smoke and long-run while offline and low battery fold into the ordinary capsule", () => {
    const host = startDemo();
    recordSafetyAlerts(host, [offline(1), battery, smoke, longrun]);
    host.render();
    assert.ok(document.querySelector(`[data-activity-card="safety:${smoke.id}"]`), "smoke stays an individual card");
    assert.ok(document.querySelector(`[data-activity-card="safety:${longrun.id}"]`), "long-run stays item-by-item");
    assert.equal(document.querySelector(`[data-activity-card="safety:${offline(1).id}"]`), null);
    assert.match(text("[data-ordinary-alerts] .cc-ordinary-summary"), /等 2 条提醒/);
    assert.equal(el("[data-ordinary-alerts-toggle]").getAttribute("aria-expanded"), "false");
    assert.equal(el("[data-ordinary-list]").hasAttribute("hidden"), true);
    click("[data-ordinary-alerts-toggle]");
    assert.equal(el("[data-ordinary-alerts-toggle]").getAttribute("aria-expanded"), "true");
    assert.ok(document.querySelector(`[data-activity-card="safety:${offline(1).id}"]`));
    click("[data-ordinary-dismiss]");
    assert.equal(document.querySelector("[data-ordinary-alerts]"), null, "one click clears the ordinary capsule");
    assert.ok(document.querySelector(`[data-activity-card="safety:${smoke.id}"]`), "smoke survives the capsule dismissal");
    recordSafetyAlerts(host, [sensor("contact"), sensor("motion"), sensor("lock"), sensor("vibration")]);
    host.render();
    assert.match(text("[data-ordinary-alerts] .cc-ordinary-summary"), /等 3 条提醒/);
    assert.ok(document.querySelector(`[data-activity-card="safety:${sensor("lock").id}"]`), "lock is pinned by default");
    saveSensorAlertPolicy({ enabled: { contact: true, motion: true, vibration: true, lock: true }, onlyWhenAway: false }, defaultSafetyStorage());
    host.render();
    assert.equal(document.querySelector("[data-ordinary-alerts]"), null);
    for (const kind of ["contact", "motion", "lock", "vibration"]) {
      assert.ok(document.querySelector(`[data-activity-card="safety:${sensor(kind).id}"]`));
    }
  });
  it("keeps missed scheduled commands outside the capsule with run and dismiss actions", () => {
    const host = startDemo();
    host.missedScheduledCommands = [{ id: "missed-1", command: "关闭空调", delaySeconds: 300, fireTimestampMs: Date.now() - 60_000, reply: "已设置", intents: [] }];
    recordSafetyAlerts(host, [battery]);
    host.render();
    assert.ok(document.querySelector('[data-run-missed="missed-1"]'));
    assert.ok(document.querySelector('[data-dismiss-missed="missed-1"]'));
    assert.equal(document.querySelector("[data-ordinary-alerts]")?.contains(document.querySelector("[data-run-missed]")), false);
    assert.match(host.root.textContent ?? "", /已错过定时/);
  });
});

describe("WP5b-1 · honest plain-language footer status", () => {
  it("maps healthy, partial dual-source, demo and unconnected states to honest copy", () => {
    const host = startDemo();
    useMi(host);
    assert.equal(resolveConnectionStatus(host).text, "设备同步正常");
    assert.equal(el("#btn-connection-status").getAttribute("aria-expanded"), "false");
    assert.equal(document.querySelector("#btn-connection-action"), null);
    host.settings.haBaseURL = "http://localhost:8123";
    host.settings.haToken = "controlled-token";
    host.dualSourceEnabledOverride = true;
    host.dualSourceCoordinator = {
      getSourceStatuses: () => ({ homeAssistant: { kind: "connected" }, xiaomiCloud: { kind: "disconnected", reason: "offline" } }),
      getLastMerged: () => null,
    } as unknown as typeof host.dualSourceCoordinator;
    host.render();
    assert.equal(text(".cc-footer-label"), "米家暂不可用，部分设备暂无数据");
    assert.equal(text("#btn-connection-action"), "重试连接");
    host.dualSourceCoordinator = null;
    host.dualSourceEnabledOverride = null;
    host.settings.connectionMode = "demo";
    host.render();
    assert.equal(resolveConnectionStatus(host).text, "示例家庭，不会控制真实设备");
    assert.equal(text("#btn-connection-action"), "连接真实家庭");
    click("#btn-connection-status");
    assert.ok(el("[data-connection-source='demo']"));
    click("[data-close-connection-details]");
    host.settings.connectionMode = "xiaomiCloud";
    host.settings.miSession = null;
    host.settings.haBaseURL = "";
    host.settings.haToken = "";
    host.render();
    assert.equal(resolveConnectionStatus(host).text, "还没连接家居平台");
    assert.equal(text("#btn-connection-action"), "去连接");
  });
  it("names expired Xiaomi and Home Assistant credentials and localizes status copy", () => {
    const host = startDemo();
    host.settings.interfaceLanguage = "zh-Hant";
    host.render();
    assert.equal(text("#btn-connection-status"), "範例家庭，不會控制真實裝置");
    host.settings.interfaceLanguage = "en";
    host.render();
    assert.equal(text("#btn-connection-status"), "Demo home; won't control real devices");
    assert.equal(text("#btn-connection-action"), "Connect a real home");
    host.settings.interfaceLanguage = "zh-Hans";
    useMi(host);
    host.miSessionExpired = true;
    host.render();
    assert.equal(resolveConnectionStatus(host).text, "米家登录已过期 · 重新扫码");
    assert.equal(text("#btn-connection-action"), "重新扫码");
    useHA(host);
    host.haConnectionError = "Home Assistant authentication rejected";
    host.render();
    assert.equal(resolveConnectionStatus(host).text, "Home Assistant 凭据或地址需更新");
    assert.equal(text("#btn-connection-action"), "查看连接");
  });
});

describe("WP5b-1 · keyboard-reachable details and Escape routing", () => {
  it("opens the details card by click and Enter and lists platform states, retry and settings", () => {
    const host = startDemo();
    useMi(host);
    const trigger = el<HTMLButtonElement>("#btn-connection-status");
    trigger.click();
    assert.equal(trigger.getAttribute("aria-expanded"), "true");
    assert.ok(el("[data-connection-source='mi']"));
    assert.ok(el("[data-connection-retry]"));
    assert.ok(el("[data-connection-settings]"));
    assert.equal(document.activeElement?.hasAttribute("data-close-connection-details"), true);
    click("[data-close-connection-details]");
    assert.equal(document.querySelector("#cc-connection-details"), null);
    assert.equal(document.activeElement?.id, "btn-connection-status");
    trigger.focus();
    trigger.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    assert.equal(el("#cc-connection-details").getAttribute("role"), "dialog");
    trigger.dispatchEvent(new window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
    assert.equal(document.querySelector("#cc-connection-details"), null);
  });
  it("routes Escape through the connection card, then the ordinary capsule, then search and hide", () => {
    const host = startDemo();
    useMi(host);
    recordSafetyAlerts(host, [offline(3), battery]);
    host.render();
    const input = el<HTMLInputElement>("#command-input");
    input.value = "灯";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    click("#btn-connection-status");
    escape();
    assert.equal(host.connectionDetailsOpen, false);
    assert.equal(document.querySelector("#cc-connection-details"), null);
    assert.equal(document.activeElement?.id, "btn-connection-status");
    assert.equal(host.panelSearch.query, "灯", "the first Escape does not clear the search");
    click("[data-ordinary-alerts-toggle]");
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, true);
    escape();
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, false);
    assert.equal(host.panelSearch.query, "灯");
    assert.equal(document.activeElement?.hasAttribute("data-ordinary-alerts-toggle"), true);
    escape();
    assert.equal(host.panelSearch.query, "");
    click("#btn-connection-status");
    click("[data-ordinary-alerts-toggle]");
    click("#btn-hide-panel");
    assert.equal(host.connectionDetailsOpen, false);
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, false);
    assert.equal(document.querySelector("#cc-connection-details"), null);
    assert.equal(el("[data-ordinary-list]").hasAttribute("hidden"), true);
  });
});
