import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import { setLanguage } from "../src/core/i18n.js";
import { MI_ACCOUNTS_INDEX_STORAGE_KEY, makeMiAccount, type MergedMiAccountsSnapshot } from "../src/core/miAccountsStore.js";
import { defaultSafetyStorage, saveSensorAlertPolicy } from "../src/core/safetyAndHealth.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  classicStackForcedExpanded,
  collectUpperStackCards,
  getHostActivityCenter,
  recordSafetyAlerts,
} from "../src/ui/activityStackView.js";
import { patchCloudPresentation } from "../src/ui/cloudRefresh.js";
import { resolveConnectionStatus } from "../src/ui/connectionStatus.js";
import { isVerboseConnectionFooter } from "../src/ui/panelView.js";
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
const press = (key: string): KeyboardEvent => {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
  window.dispatchEvent(event);
  return event;
};
/** Swipe one expanded ordinary reminder the way a browser delivers it: the last element to capture the
 * pointer receives every later event, so a nested row and its group card must not both own one gesture. */
const swipeExpandedRow = (row: HTMLElement, group: HTMLElement, pointerId: number): void => {
  let capture: HTMLElement | null = null;
  for (const card of [row, group]) {
    card.setPointerCapture = () => { capture = card; };
    card.releasePointerCapture = () => { if (capture === card) capture = null; };
  }
  const send = (type: string, clientX: number): void => {
    (capture ?? row).dispatchEvent(new dom.PointerEvent(type, { clientX, clientY: 20, pointerId, bubbles: true }) as unknown as Event);
  };
  send("pointerdown", 200);
  send("pointermove", 380);
  send("pointerup", 390);
};
/** Only the account index proves a secondary Xiaomi login when `miSession` is empty. */
const useIndexedSecondaryMi = (): void => {
  localStorage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify([{ id: "acc-primary" }, { id: "acc-secondary" }]));
};
function startDemo(): MenuMijiaWindowsApp {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, interfaceLanguage: "zh-Hans", panelTheme: "fluent" }));
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
const connectionKind = (kind: string) => (kind === "disconnected" ? { kind, reason: "offline" } : { kind });
/** Dual-source stub: the footer must read each platform plus every Xiaomi account from here, not from globals. */
function useDualSource(
  host: MenuMijiaWindowsApp,
  input: { readonly ha: string; readonly mi: string; readonly accounts?: Readonly<Record<string, string>> },
): void {
  host.settings.haBaseURL = "http://localhost:8123";
  host.settings.haToken = "controlled-token";
  host.dualSourceEnabledOverride = true;
  host.dualSourceCoordinator = {
    getSourceStatuses: () => ({ homeAssistant: connectionKind(input.ha), xiaomiCloud: connectionKind(input.mi) }),
    getLastMerged: () => (input.accounts
      ? { accountStatuses: Object.fromEntries(Object.entries(input.accounts).map(([id, kind]) => [id, connectionKind(kind)])) }
      : null),
  } as unknown as typeof host.dualSourceCoordinator;
}
const badge = (id: "mi" | "ha"): string =>
  el(`[data-connection-source='${id}'] [data-connection-badge]`).getAttribute("data-connection-badge") ?? "";
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
  it("names a single ordinary reminder by its title and counts only the extras", () => {
    const host = startDemo();
    recordSafetyAlerts(host, [offline(1)]);
    host.render();
    assert.equal(text("[data-ordinary-alerts] .cc-ordinary-summary"), "玄关插座已离线");
    assert.doesNotMatch(text("[data-ordinary-alerts] .cc-ordinary-summary"), /等 1 条|and 0 more/);
    recordSafetyAlerts(host, [offline(2)]);
    host.settings.interfaceLanguage = "zh-Hant";
    host.render();
    assert.equal(text("[data-ordinary-alerts] .cc-ordinary-summary"), "玄关插座已离线 等 2 條提醒");
    host.settings.interfaceLanguage = "en";
    host.render();
    assert.equal(text("[data-ordinary-alerts] .cc-ordinary-summary"), "玄关插座已离线 and 1 more");
  });
  it("drops the dead Classic collapse control while two pinned cards force the stack open", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [smoke, longrun]);
    host.render();
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    assert.equal(Boolean(document.querySelector("[data-activity-toggle-expand]")), false, "forced-open Classic cannot offer a collapse pill");
    assert.ok(document.querySelector("[data-activity-clear-all]"), "dismiss all stays available");
    assert.equal(getHostActivityCenter(host).isExpanded, true);
    // One pinned card plus the ordinary capsule still collapses and expands on demand.
    const single: MenuMijiaWindowsApp = host;
    single.settings.panelTheme = "classic";
    recordSafetyAlerts(single, [offline(1)]);
    getHostActivityCenter(single).recentSafetyAlerts = getHostActivityCenter(single).recentSafetyAlerts.filter((row) => row.alert.id !== longrun.id);
    getHostActivityCenter(single).isExpanded = false;
    single.render();
    assert.equal(el("[data-upper-stack]").classList.contains("is-collapsed"), true);
    click("[data-activity-toggle-expand]");
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    assert.ok(document.querySelector("[data-activity-toggle-expand]"));
    assert.ok(document.querySelector("[data-activity-clear-all]"));
    click("[data-activity-toggle-expand]");
    assert.equal(el("[data-upper-stack]").classList.contains("is-collapsed"), true, "collapse works when nothing forces the stack open");
  });
  it("swipes one expanded ordinary reminder without dismissing the whole capsule", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [offline(1), battery]);
    host.render();
    click("[data-ordinary-alerts-toggle]");
    const row = `[data-upper-card-id="safety:${offline(1).id}"]`;
    assert.ok(document.querySelector(row), "the expanded row owns its own swipe target");
    swipeExpandedRow(el<HTMLElement>(row), el<HTMLElement>('[data-upper-card-id="ordinary:alerts"]'), 7);
    assert.equal(document.querySelector(row), null, "the swiped reminder leaves on its own");
    assert.ok(document.querySelector(`[data-upper-card-id="safety:${battery.id}"]`), "the sibling reminder survives");
    assert.ok(document.querySelector('[data-upper-card-id="ordinary:alerts"]'), "one row swipe never dismisses the whole ordinary capsule");
  });
  it("returns focus to the ordinary capsule after both expanding and collapsing", () => {
    const host = startDemo();
    recordSafetyAlerts(host, [offline(1), battery]);
    host.render();
    el<HTMLButtonElement>("[data-ordinary-alerts-toggle]").focus();
    assert.equal(document.activeElement?.hasAttribute("data-ordinary-alerts-toggle"), true);
    click("[data-ordinary-alerts-toggle]");
    assert.equal(el("[data-ordinary-alerts-toggle]").getAttribute("aria-expanded"), "true");
    assert.equal(document.activeElement?.hasAttribute("data-ordinary-alerts-toggle"), true, "expanding keeps focus on the capsule");
    // The render that follows a toggle may mount a fresh button; a collapse must land on the live one
    // instead of inheriting focus from the node it replaced.
    const expanded = el<HTMLButtonElement>("[data-ordinary-alerts-toggle]");
    expanded.remove();
    expanded.click();
    assert.equal(el("[data-ordinary-alerts-toggle]").getAttribute("aria-expanded"), "false");
    assert.equal(document.activeElement?.hasAttribute("data-ordinary-alerts-toggle"), true, "collapsing must not drop focus onto <body>");
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
  it("keeps Home Assistant online while Xiaomi values are stale and per-account data is healthy", () => {
    const host = startDemo();
    useMi(host);
    useDualSource(host, { ha: "connected", mi: "connected", accounts: { acc1: "connected", acc2: "connected" } });
    host.cloudValuesStale = true;
    host.render();
    assert.equal(host.valuesAreStale, true, "valuesAreStale follows the active Xiaomi mode");
    assert.equal(text(".cc-footer-label"), "米家暂不可用，部分设备暂无数据");
    assert.equal(el(".cc-status-dot").classList.contains("is-degraded"), true);
    click("#btn-connection-status");
    assert.equal(badge("ha"), "online", "a stale Xiaomi cache must not degrade Home Assistant");
    assert.equal(text("[data-connection-source='ha'] .cc-conn-state"), "已连接");
    assert.equal(badge("mi"), "degraded");
  });
  it("does not blame Home Assistant for a stale Xiaomi cache in single-source Home Assistant mode", () => {
    const host = startDemo();
    useHA(host);
    host.cloudValuesStale = true;
    host.render();
    assert.equal(resolveConnectionStatus(host).tone, "online");
    assert.equal(text(".cc-footer-label"), "设备同步正常");
    click("#btn-connection-status");
    assert.equal(badge("ha"), "online");
  });
  it("surfaces a partially disconnected Xiaomi account in dual mode", () => {
    const host = startDemo();
    useMi(host);
    useDualSource(host, { ha: "connected", mi: "connected", accounts: { acc1: "connected", acc2: "disconnected" } });
    host.render();
    assert.equal(el(".cc-status-dot").classList.contains("is-degraded"), true);
    assert.equal(text(".cc-footer-label"), "部分米家账号异常 · 部分设备暂无数据");
    assert.equal(text("#btn-connection-action"), "重试连接");
    click("#btn-connection-status");
    assert.equal(badge("mi"), "degraded");
    assert.equal(text("[data-connection-source='mi'] .cc-conn-state"), "部分米家账号异常 · 部分设备暂无数据");
    assert.equal(badge("ha"), "online");
  });
  it("counts an index-only secondary Xiaomi account as a live Mi source", () => {
    const host = startDemo();
    useIndexedSecondaryMi();
    host.settings.connectionMode = "xiaomiCloud";
    host.settings.miSession = null;
    host.render();
    assert.notEqual(resolveConnectionStatus(host).text, "还没连接家居平台", "the footer must not call an indexed secondary login unconnected");
    assert.equal(resolveConnectionStatus(host).text, "设备同步正常");
    click("#btn-connection-status");
    assert.ok(el("[data-connection-source='mi']"), "the Mi source is listed");
    assert.equal(text("[data-connection-source='mi'] .cc-conn-state"), `已连接 · ${host.devices.length} 台设备`);
  });
  it("merges both sources when dual mode is backed only by indexed secondary accounts", () => {
    const host = startDemo();
    useIndexedSecondaryMi();
    host.settings.connectionMode = "xiaomiCloud";
    host.settings.miSession = null;
    useDualSource(host, { ha: "connected", mi: "connected" });
    host.render();
    assert.equal(resolveConnectionStatus(host).tone, "online");
    click("#btn-connection-status");
    assert.equal(badge("mi"), "online");
    assert.equal(badge("ha"), "online");
    assert.equal(text("[data-connection-source='mi'] .cc-conn-state"), "已连接");
  });
  it("keeps the plain-language status in the footer trigger's accessible name", () => {
    const host = startDemo();
    useMi(host);
    assert.equal(el("#btn-connection-status").getAttribute("aria-label"), "设备同步正常 · 连接详情");
    assert.equal(text("#btn-connection-status"), "设备同步正常", "the visible label keeps the status copy alone");
    host.miSessionExpired = true;
    host.render();
    assert.match(el("#btn-connection-status").getAttribute("aria-label") ?? "", /米家登录已过期 · 重新扫码/);
    assert.match(el("#btn-connection-status").getAttribute("aria-label") ?? "", /连接详情/);
    host.settings.interfaceLanguage = "en";
    host.settings.miSession = { userId: "90001234", cUserId: "", ssecurity: "x", serviceToken: "y", passToken: "", region: "cn" };
    host.miSessionExpired = false;
    host.render();
    assert.equal(el("#btn-connection-status").getAttribute("aria-label"), "Devices synced · Connection details");
  });
});

describe("WP5b-1 · footer wrap threshold", () => {
  it("keeps healthy English copy on one row and wraps only long warnings", () => {
    const host = startDemo();
    useMi(host);
    host.settings.interfaceLanguage = "en";
    host.render();
    assert.equal(text(".cc-footer-label"), "Devices synced");
    assert.equal(el(".cc-footer").classList.contains("is-verbose-status"), false);
    assert.equal(isVerboseConnectionFooter(resolveConnectionStatus(host)), false);
    host.settings.interfaceLanguage = "zh-Hans";
    host.render();
    assert.equal(text(".cc-footer-label"), "设备同步正常");
    assert.equal(el(".cc-footer").classList.contains("is-verbose-status"), false);
    host.cloudValuesStale = true;
    host.settings.interfaceLanguage = "en";
    host.render();
    assert.match(text(".cc-footer-label"), /Xiaomi Home unavailable/);
    assert.equal(el(".cc-footer").classList.contains("is-verbose-status"), true);
    assert.equal(isVerboseConnectionFooter(resolveConnectionStatus(host)), true);
  });
  it("measures visual columns so a long Chinese warning wraps but a short healthy row does not", () => {
    assert.equal(isVerboseConnectionFooter({ tone: "online", icon: "", text: "Devices synced", action: null, sources: [] }), false);
    assert.equal(isVerboseConnectionFooter({ tone: "online", icon: "", text: "设备同步正常", action: null, sources: [] }), false);
    assert.equal(isVerboseConnectionFooter({
      tone: "offline", icon: "", text: "米家暂不可用，部分设备暂无数据", action: { kind: "retry", label: "重试连接" }, sources: [],
    }), true);
    assert.equal(isVerboseConnectionFooter({
      tone: "degraded", icon: "", text: "Xiaomi Home unavailable; some devices have no data", action: { kind: "retry", label: "Retry connection" }, sources: [],
    }), true);
    assert.equal(isVerboseConnectionFooter({
      tone: "degraded", icon: "", text: "设备状态可能过期，正在等待同步", action: { kind: "retry", label: "重试连接" }, sources: [],
    }), true);
    assert.equal(isVerboseConnectionFooter({ tone: "unconfigured", icon: "", text: "还没连接家居平台", action: { kind: "settings", label: "去连接" }, sources: [] }), false);
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
  it("clears the ordinary flag once every reminder is dismissed so Escape still reaches search and hide", () => {
    const host = startDemo();
    useMi(host);
    recordSafetyAlerts(host, [offline(4), battery]);
    host.render();
    const input = el<HTMLInputElement>("#command-input");
    input.value = "灯";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    click("[data-ordinary-alerts-toggle]");
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, true);
    while (document.querySelector("[data-ordinary-list] [data-activity-dismiss]")) {
      click("[data-ordinary-list] [data-activity-dismiss]");
    }
    assert.equal(Boolean(document.querySelector("[data-ordinary-alerts]")), false);
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, false, "an empty capsule cannot stay expanded");
    escape();
    assert.equal(host.panelSearch.query, "", "Escape clears search instead of being swallowed");
    // A stale flag with no mounted capsule toggle must never consume the key either.
    input.value = "灯";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    getHostActivityCenter(host).ordinaryExpanded = true;
    escape();
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, false);
    assert.equal(host.panelSearch.query, "");
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

const miSession = (userId: string, expiresAt?: number) => ({
  userId,
  cUserId: "",
  ssecurity: "x",
  serviceToken: "y",
  passToken: "",
  region: "cn",
  ...(expiresAt === undefined ? {} : { expiresAt }),
});
const missedCommand = (id: string) => ({
  id,
  command: "关闭空调",
  delaySeconds: 300,
  fireTimestampMs: Date.now() - 60_000,
  reply: "已设置",
  intents: [],
});

describe("WP5b-1 · silent refresh keeps the honest footer", () => {
  it("never writes the legacy account summary back over the plain-language status", () => {
    const host = startDemo();
    useMi(host);
    assert.equal(text(".cc-footer-label"), "设备同步正常");
    assert.equal(patchCloudPresentation(host), true);
    assert.equal(text(".cc-footer-label"), "设备同步正常", "a silent patch keeps the plain-language copy");
    assert.doesNotMatch(text(".cc-footer-label"), /米家账号|台设备|Home Assistant ·/);
    assert.ok(el(".cc-status-dot").classList.contains("is-online"));
    assert.equal(document.querySelector("#btn-connection-action"), null);

    // A partially disconnected account also keeps its own copy and its recovery action through the patch.
    useDualSource(host, { ha: "connected", mi: "connected", accounts: { acc1: "connected", acc2: "disconnected" } });
    host.render();
    assert.equal(text(".cc-footer-label"), "部分米家账号异常 · 部分设备暂无数据");
    assert.equal(patchCloudPresentation(host), true);
    assert.equal(text(".cc-footer-label"), "部分米家账号异常 · 部分设备暂无数据");
    assert.ok(el(".cc-status-dot").classList.contains("is-degraded"));
    assert.equal(text("#btn-connection-action"), "重试连接");
  });

  it("re-derives the footer from the live connection state instead of the stale health snapshot", () => {
    const host = startDemo();
    useMi(host);
    useDualSource(host, { ha: "connected", mi: "disconnected" });
    host.render();
    assert.equal(text(".cc-footer-label"), "米家暂不可用，部分设备暂无数据");
    assert.equal(text("#btn-connection-action"), "重试连接");
    // Only the footer copy changes here: the patch rewrites the live status in place.
    useDualSource(host, { ha: "connected", mi: "connected", accounts: { acc1: "connected", acc2: "disconnected" } });
    assert.equal(patchCloudPresentation(host), true);
    assert.equal(text(".cc-footer-label"), "部分米家账号异常 · 部分设备暂无数据");
    assert.ok(el(".cc-status-dot").classList.contains("is-degraded"));
    // A recovery action appearing or disappearing changes the structure: defer to the full render.
    host.dualSourceCoordinator = null;
    host.dualSourceEnabledOverride = null;
    host.settings.haBaseURL = "";
    host.settings.haToken = "";
    assert.equal(patchCloudPresentation(host), false);
    host.queueBackgroundRender();
    assert.equal(text(".cc-footer-label"), "设备同步正常");
    assert.equal(document.querySelector("#btn-connection-action"), null);
    // An open dialog is also owned by the full render, never by an in-place morph.
    click("#btn-connection-status");
    assert.equal(patchCloudPresentation(host), false);
    assert.equal(el("#btn-connection-status").getAttribute("aria-expanded"), "true");
  });
});

describe("WP5b-1 · urgent card order and reachability", () => {
  it("orders pinned alerts, missed timers and the ordinary capsule in both themes", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [offline(1)]);
    host.missedScheduledCommands = [missedCommand("missed-1")];
    host.render();
    const classicIds = collectUpperStackCards(host).map((card) => card.id);
    assert.ok(classicIds.indexOf("missed:timers") >= 0);
    assert.ok(
      classicIds.indexOf("missed:timers") < classicIds.indexOf("ordinary:alerts"),
      "a missed timer never sits behind the foldable capsule",
    );
    // One urgent card still collapses, and the visible top card carries the +N path to the capsule behind it.
    assert.equal(el("[data-upper-stack]").classList.contains("is-collapsed"), true);
    assert.ok(document.querySelector('[data-upper-card-id="missed:timers"]'));
    assert.equal(document.querySelector('[data-upper-card-id="ordinary:alerts"]'), null);
    assert.ok(el('[data-upper-card-id="missed:timers"]').querySelector("[data-activity-toggle-expand]"));
    click("[data-upper-card-id='missed:timers'] [data-activity-toggle-expand]");
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    const mounted = [...document.querySelectorAll<HTMLElement>("[data-upper-stack] [data-upper-card-id]")].map(
      (card) => card.dataset.upperCardId,
    );
    assert.ok(mounted.indexOf("missed:timers") < mounted.indexOf("ordinary:alerts"));

    // Liquid Glass interleaves the same order inside its notification stack.
    host.settings.panelTheme = "fluent";
    recordSafetyAlerts(host, [smoke]);
    host.render();
    const stackChildren = [...el("[data-activity-stack]").children];
    assert.ok(stackChildren.indexOf(el("[data-missed-timers]")) > 0);
    assert.ok(
      stackChildren.indexOf(el("[data-missed-timers]")) < stackChildren.indexOf(el("[data-ordinary-alerts]")),
      "missed timers render between the pinned alerts and the ordinary capsule",
    );
    assert.ok(stackChildren[0]?.querySelector(`[data-activity-card="safety:${smoke.id}"]`));
  });

  it("never folds a pinned safety card behind the HA error or a second urgent card", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [sensor("leak")]);
    host.haConnectionError = "Home Assistant 令牌无效";
    host.render();
    assert.equal(classicStackForcedExpanded(host), true, "the HA error card renders above the pinned safety card");
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    assert.ok(document.querySelector(`[data-upper-card-id="safety:${sensor("leak").id}"]`), "the leak card stays visible");
    assert.equal(document.querySelector("[data-activity-toggle-expand]"), null, "a forced-open stack offers no collapse pill");

    host.haConnectionError = null;
    host.missedScheduledCommands = [missedCommand("missed-2")];
    recordSafetyAlerts(host, [smoke]);
    host.render();
    assert.equal(classicStackForcedExpanded(host), true);
    const ids = [...document.querySelectorAll<HTMLElement>("[data-upper-stack] [data-upper-card-id]")].map(
      (card) => card.dataset.upperCardId,
    );
    assert.ok(ids.includes(`safety:${smoke.id}`));
    assert.ok(ids.indexOf(`safety:${smoke.id}`) < ids.indexOf("missed:timers"), "pinned -> missed timers");
  });

  it("gives the ordinary capsule its own +N control when it leads a collapsed stack", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [offline(1)]);
    host.replyBanner = { text: "已打开书房台灯", source: "米家" };
    host.render();
    assert.equal(el("[data-upper-stack]").classList.contains("is-collapsed"), true);
    const capsuleCard = el('[data-upper-card-id="ordinary:alerts"]');
    const expand = capsuleCard.querySelector<HTMLButtonElement>("[data-activity-toggle-expand]");
    assert.ok(expand, "a collapsed capsule keeps a keyboard path to the cards behind it");
    assert.ok(capsuleCard.querySelector("[data-ordinary-alerts-toggle]"), "the capsule keeps its own toggle");
    expand.click();
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    assert.ok(document.querySelector('[data-upper-card-id="reply:banner"]'));
  });
});

describe("WP5b-1 · per-login expiry and dual-source partial failures", () => {
  it("keeps a healthy secondary Xiaomi login usable when the primary cookie lapsed", () => {
    const host = startDemo();
    host.settings.connectionMode = "xiaomiCloud";
    const primary = makeMiAccount(miSession("90001234", Date.now() - 60_000));
    const secondary = makeMiAccount(miSession("90005678"));
    host.settings.miSession = primary.session;
    host.miAccountsOverride = [primary, secondary];
    host.render();
    const status = resolveConnectionStatus(host);
    assert.equal(status.tone, "degraded", "one dead login is not a dead platform");
    assert.equal(status.action?.kind, "retry");
    assert.equal(text(".cc-footer-label"), "部分米家账号异常 · 部分设备暂无数据");
    assert.ok(el(".cc-status-dot").classList.contains("is-degraded"));
    click("#btn-connection-status");
    assert.equal(badge("mi"), "degraded");
  });

  it("treats a rejected session reported by the merged snapshot as expired", () => {
    const host = startDemo();
    host.settings.connectionMode = "xiaomiCloud";
    const primary = makeMiAccount(miSession("90001234"));
    const secondary = makeMiAccount(miSession("90005678"));
    host.settings.miSession = primary.session;
    host.multiAccountState = {
      accounts: [primary, secondary],
      merged: {
        accountTokenStatuses: {
          [primary.id]: { kind: "expired", source: "rejected" },
          [secondary.id]: { kind: "expired", source: "rejected" },
        },
        accountStatuses: { [primary.id]: { kind: "disconnected", reason: "expired" }, [secondary.id]: { kind: "disconnected", reason: "expired" } },
      } as unknown as MergedMiAccountsSnapshot,
      children: {},
    };
    host.render();
    const status = resolveConnectionStatus(host);
    assert.equal(status.tone, "offline");
    assert.equal(status.action?.kind, "qr");
    assert.equal(text(".cc-footer-label"), "米家登录已过期 · 重新扫码");
    click("#btn-connection-status");
    assert.equal(badge("mi"), "reauth");
  });

  it("reports a partial dual-source outage as degraded with the failing side's recovery", () => {
    const host = startDemo();
    host.settings.connectionMode = "xiaomiCloud";
    const expired = makeMiAccount(miSession("90001234", Date.now() - 60_000));
    host.settings.miSession = expired.session;
    host.miAccountsOverride = [expired];
    useDualSource(host, { ha: "connected", mi: "connected" });
    host.render();
    let status = resolveConnectionStatus(host);
    assert.equal(status.tone, "degraded", "Home Assistant still serves devices");
    assert.equal(status.action?.kind, "qr");
    assert.equal(text(".cc-footer-label"), "米家登录已过期 · 重新扫码");
    click("#btn-connection-status");
    assert.equal(badge("ha"), "online");
    assert.equal(badge("mi"), "reauth");

    // A rejected Home Assistant credential degrades the same way, but keeps its own settings entry point.
    const live = makeMiAccount(miSession("90001234"));
    host.settings.miSession = live.session;
    host.miAccountsOverride = [live];
    host.haConnectionError = "Home Assistant authentication rejected";
    host.render();
    status = resolveConnectionStatus(host);
    assert.equal(status.tone, "degraded");
    assert.equal(status.action?.kind, "settings");
    assert.equal(text(".cc-footer-label"), "Home Assistant 凭据或地址需更新");
    assert.equal(badge("mi"), "online");

    // A declined plaintext endpoint is the same partial outage, not a total disconnect.
    host.haConnectionError = "Home Assistant endpoint has not been approved";
    host.render();
    status = resolveConnectionStatus(host);
    assert.equal(status.tone, "degraded");
    assert.equal(status.action?.kind, "settings");
    assert.equal(text(".cc-footer-label"), "Home Assistant 未连接（已拒绝明文 http）");
  });

  it("names both platforms when neither source can serve devices", () => {
    const host = startDemo();
    host.settings.connectionMode = "xiaomiCloud";
    const expired = makeMiAccount(miSession("90001234", Date.now() - 60_000));
    host.settings.miSession = expired.session;
    host.miAccountsOverride = [expired];
    useDualSource(host, { ha: "connected", mi: "connected" });
    host.haConnectionError = "Home Assistant authentication rejected";
    host.render();
    const status = resolveConnectionStatus(host);
    assert.equal(status.tone, "offline");
    assert.equal(text(".cc-footer-label"), "米家与 Home Assistant 均不可用");
    assert.equal(text("#btn-connection-action"), "查看连接");
    click("#btn-connection-status");
    assert.equal(badge("mi"), "reauth");
    assert.equal(badge("ha"), "reauth");
    assert.match(text("[data-connection-source='mi'] .cc-conn-state"), /过期/);
    assert.match(text("[data-connection-source='ha'] .cc-conn-state"), /凭据/);
  });
});

describe("WP5b-1 · hide, Escape and focus guards", () => {
  it("drops ghost dialog DOM when the window blurs or the panel hides", () => {
    const host = startDemo();
    useMi(host);
    recordSafetyAlerts(host, [offline(1), battery]);
    host.render();
    click("#btn-connection-status");
    click("[data-ordinary-alerts-toggle]");
    assert.ok(document.querySelector("#cc-connection-details"));
    assert.equal(el("[data-ordinary-list]").hasAttribute("hidden"), false);
    window.dispatchEvent(new window.Event("blur"));
    assert.equal(host.connectionDetailsOpen, false);
    assert.equal(document.querySelector("#cc-connection-details"), null, "the dialog leaves the DOM, not just the flag");
    assert.equal(getHostActivityCenter(host).ordinaryExpanded, false);
    assert.equal(el("[data-ordinary-list]").hasAttribute("hidden"), true);
  });

  it("collapses a manually expanded Classic stack on Escape before search and hide", () => {
    const host = startDemo();
    host.settings.panelTheme = "classic";
    recordSafetyAlerts(host, [offline(1)]);
    host.replyBanner = { text: "已打开书房台灯", source: "米家" };
    host.render();
    const input = el<HTMLInputElement>("#command-input");
    input.value = "灯";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    click("[data-upper-card-id='ordinary:alerts'] [data-activity-toggle-expand]");
    assert.equal(el("[data-upper-stack]").classList.contains("is-expanded"), true);
    escape();
    assert.equal(getHostActivityCenter(host).isExpanded, false, "Escape closes the reminder stack first");
    assert.equal(el("[data-upper-stack]").classList.contains("is-collapsed"), true);
    assert.equal(host.panelSearch.query, "灯", "search stays until the stack is closed");
    assert.ok(document.activeElement?.hasAttribute("data-activity-toggle-expand"));
    escape();
    assert.equal(host.panelSearch.query, "");

    // A forced-open safety stack is not something one Escape may hide.
    host.replyBanner = null;
    recordSafetyAlerts(host, [smoke, longrun]);
    host.settings.panelTheme = "classic";
    host.render();
    assert.equal(classicStackForcedExpanded(host), true);
    escape();
    assert.equal(getHostActivityCenter(host).isExpanded, true);
  });

  it("keeps the connection dialog's focus and shortcuts while it is open", () => {
    const host = startDemo();
    useMi(host);
    click("#btn-connection-status");
    assert.equal(document.activeElement?.hasAttribute("data-close-connection-details"), true);
    const typed = press("b");
    assert.equal(typed.defaultPrevented, false, "typing never steals focus into the search field");
    assert.equal(document.activeElement?.hasAttribute("data-close-connection-details"), true);
    assert.equal(host.panelSearch.query, "");
    // A background refresh defers instead of re-rendering over the dialog.
    host.queueBackgroundRender();
    assert.equal(host.pendingCloudRender, true);
    assert.ok(document.querySelector("#cc-connection-details"));
    // Clicking elsewhere in the panel dismisses it.
    el<HTMLElement>(".cc-scroll-area").click();
    assert.equal(host.connectionDetailsOpen, false);
    assert.equal(document.querySelector("#cc-connection-details"), null);
    host.pendingCloudRender = false;
  });
});
