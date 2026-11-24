import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { DUAL_SOURCE_ENABLED_STORAGE_KEY } from "../src/core/dualSourceProvider.js";
import { ALL_OFF_HOLD_MS, UNDO_BANNER_SECONDS, UNDO_BANNER_SECONDS_MULTI } from "../src/ui/appConstants.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { isDualSourceEnabled, setHostDualSourceEnabled } from "../src/ui/cloudRefresh.js";
import {
  identityMigrationPresentation,
  renderConnectionStatus,
  resolveConnectionStatus,
} from "../src/ui/connectionStatus.js";
import {
  isPlainHttpRemoteEndpoint,
  normalizeHaEndpoint,
} from "../src/ui/haEndpoint.js";
import {
  onboardingAllOffTimingCopy,
  renderOnboardingConnectStep,
  type OnboardingConnectStepInput,
} from "../src/ui/onboardingGuide.js";
import { resolveLegacyOnboardingFlag } from "../src/ui/settings.js";

let dom: Window;

const identity = (value: string): string => value;

function el<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  el(selector).click();
  await setImmediate();
}

function connectStepInput(overrides: Partial<OnboardingConnectStepInput> = {}): OnboardingConnectStepInput {
  return {
    mode: "homeAssistant",
    miUserId: null,
    miCloudRegion: "cn",
    qr: { isPolling: false, expired: false, statusText: "", ticket: null },
    ha: { urlDraft: "http://192.168.1.50:8123", tokenDraft: "", connecting: false, error: null, connectedCount: null },
    escapeHtml: identity,
    ...overrides,
  };
}

async function mountApp(): Promise<MenuMijiaWindowsApp> {
  Object.defineProperty(window, "__TAURI_INTERNALS__", {
    value: { invoke: async () => null },
    configurable: true,
  });
  const app = new MenuMijiaWindowsApp(el("#app"));
  await setImmediate();
  await setImmediate();
  return app;
}

describe("W0-8 · onboarding address normalization, QR state and remaining guide polish (#293)", () => {
  beforeEach(() => {
    dom = mountTestWindow();
    installCssEscape();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    await closeTestWindow(dom);
  });

  it("normalizes HA addresses the same way for the guide, Settings and the save path (P2-10)", () => {
    assert.equal(normalizeHaEndpoint("192.168.1.50:8123"), "http://192.168.1.50:8123", "a bare host is http");
    assert.equal(normalizeHaEndpoint("  homeassistant.local:8123/  "), "http://homeassistant.local:8123");
    assert.equal(
      normalizeHaEndpoint("http://192.168.1.50:8123/api/websocket"),
      "http://192.168.1.50:8123",
      "the HA UI's /api/websocket suffix is not part of the base URL",
    );
    assert.equal(normalizeHaEndpoint("https://ha.example.com/api/websocket/"), "https://ha.example.com");
    assert.equal(normalizeHaEndpoint("https://ha.example.com/ha/"), "https://ha.example.com/ha", "only trailing slashes drop");
    assert.equal(normalizeHaEndpoint(""), "", "an empty draft stays empty");
  });

  it("flags plaintext only for public hosts and treats IPv6, .local and RFC1918 as local (P2-10)", () => {
    const cases: readonly { readonly url: string; readonly remote: boolean }[] = [
      { url: "192.168.1.50:8123", remote: false },
      { url: "192.168.1.20:8123/api/websocket", remote: false },
      { url: "172.31.255.254", remote: false },
      { url: "homeassistant.local:8123", remote: false },
      { url: "HOMEASSISTANT.LOCAL:8123/api/websocket", remote: false },
      { url: "[fd00::1]:8123", remote: false, },
      { url: "[::1]:8123", remote: false },
      { url: "203.0.113.5:8123", remote: true },
      { url: "http://[2001:db8::1]:8123", remote: true },
      { url: "https://203.0.113.5:8123", remote: false },
      { url: "https://homeassistant.example.com", remote: false },
      { url: "", remote: false },
      { url: "not a url", remote: false },
    ];
    for (const item of cases) {
      assert.equal(isPlainHttpRemoteEndpoint(item.url), item.remote, item.url);
    }
  });

  it("renders step 2 as a pure function with no inline styles and an accurate plaintext warning (Nit-1/Nit-2/Nit-3)", () => {
    assert.equal(renderOnboardingConnectStep(connectStepInput({ mode: null })), "", "no step before a platform is chosen");

    const remote = renderOnboardingConnectStep(
      connectStepInput({ ha: { urlDraft: "http://203.0.113.5:8123", tokenDraft: "", connecting: false, error: null, connectedCount: null } }),
    );
    assert.match(remote, /data-onboarding-ha-http-warning/);
    assert.doesNotMatch(remote, /data-onboarding-ha-http-warning[^>]*hidden/, "a public plaintext address warns");

    const lan = renderOnboardingConnectStep(connectStepInput());
    assert.match(lan, /data-onboarding-ha-http-warning[^>]*hidden/, "a LAN address stays quiet");
    for (const html of [remote, lan]) {
      assert.doesNotMatch(html, /style="/, "step 2 uses CSS classes, not inline styles");
    }

    const qr = renderOnboardingConnectStep(connectStepInput({ mode: "xiaomiCloud" }));
    assert.match(qr, /id="btn-start-qr"/);
    assert.doesNotMatch(qr, /style="/, "the QR step uses CSS classes, not inline styles");

    const demo = renderOnboardingConnectStep(connectStepInput({ mode: "demo" }));
    assert.match(demo, /data-onboarding-demo-banner/);
    assert.doesNotMatch(demo, /style="/, "the demo banner uses CSS classes, not inline styles");
  });

  it("labels the QR button from the explicit login phase, never from the status text (Nit-5)", async () => {
    const app = await mountApp();
    assert.equal(app.activeSheet, "onboarding");
    await click('[data-onboarding-mode="xiaomiCloud"]');

    assert.match(el("#btn-start-qr").textContent ?? "", /获取米家登录二维码/, "a fresh code offers to fetch");

    app.qrPhase = "expired";
    app.qrStatusText = "点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。";
    app.render();
    await setImmediate();
    assert.match(el("#btn-start-qr").textContent ?? "", /刷新二维码/, "the expired phase refreshes the label");

    // The old implementation sniffed `超时|过期|expired` out of the translated copy. Status text that
    // mentions expiry must no longer matter while the phase says the flow is idle.
    app.qrPhase = "idle";
    app.qrStatusText = "二维码已过期，请重新获取";
    app.render();
    await setImmediate();
    assert.doesNotMatch(
      el("#btn-start-qr").textContent ?? "",
      /刷新二维码/,
      "localized copy is not a state machine",
    );

    app.isPollingQR = true;
    app.render();
    await setImmediate();
    assert.match(el("#btn-start-qr").textContent ?? "", /正在等待手机米家扫码确认/);
    assert.equal(el<HTMLButtonElement>("#btn-start-qr").disabled, true, "the button stays disabled while polling");
  });

  it("builds the All Off timing copy from the constants that enforce it (Nit-6)", () => {
    const hans = onboardingAllOffTimingCopy();
    assert.match(hans, new RegExp(`${ALL_OFF_HOLD_MS / 1000} 秒`));
    assert.match(hans, new RegExp(`${UNDO_BANNER_SECONDS} 秒内撤销`));
    assert.match(hans, new RegExp(`3 台起为 ${UNDO_BANNER_SECONDS_MULTI} 秒`));

    setLanguage("zh-Hant");
    const hant = onboardingAllOffTimingCopy();
    assert.match(hant, new RegExp(`${ALL_OFF_HOLD_MS / 1000} 秒`));
    assert.match(hant, new RegExp(`${UNDO_BANNER_SECONDS} 秒內復原`));

    setLanguage("en");
    const en = onboardingAllOffTimingCopy();
    assert.match(en, new RegExp(`Hold All Off for ${ALL_OFF_HOLD_MS / 1000}s`));
    assert.match(en, new RegExp(`for ${UNDO_BANNER_SECONDS}s`));
    assert.match(en, new RegExp(`\\(${UNDO_BANNER_SECONDS_MULTI}s from 3 devices\\)`));
  });

  it("keeps the guide's own sections free of inline styles (Nit-1/Nit-2)", async () => {
    await mountApp();
    assert.equal(document.querySelector(".cc-settings-sheet"), null);
    for (const selector of [
      ".cc-sheet-header",
      '[data-onboarding-step="1"]',
      '[data-onboarding-step="4"]',
      "[data-onboarding-ai-section]",
      ".cc-sheet-footer",
    ]) {
      assert.doesNotMatch(el(selector).outerHTML, /style="/, `${selector} is styled by class only`);
    }
  });

  it("resolves the legacy onboarding flag through one named rule (Nit-7)", () => {
    const base = {
      hasExplicitFlag: false,
      storedFlag: false,
      hasLegacyDataSource: false,
      hasPersistedLocalData: false,
      hasPersistedSettings: false,
      storedConnectionMode: undefined as unknown,
    };
    assert.equal(resolveLegacyOnboardingFlag({ ...base, hasExplicitFlag: true, storedFlag: true }), true);
    assert.equal(
      resolveLegacyOnboardingFlag({ ...base, hasExplicitFlag: true, storedFlag: false, hasLegacyDataSource: true }),
      false,
      "an explicit flag always wins",
    );
    assert.equal(resolveLegacyOnboardingFlag({ ...base, hasLegacyDataSource: true }), true);
    assert.equal(resolveLegacyOnboardingFlag({ ...base, hasPersistedLocalData: true }), true);
    for (const mode of ["xiaomiCloud", "homeAssistant", "demo"]) {
      assert.equal(
        resolveLegacyOnboardingFlag({ ...base, hasPersistedSettings: true, storedConnectionMode: mode }),
        true,
        mode,
      );
    }
    assert.equal(
      resolveLegacyOnboardingFlag({ ...base, hasPersistedSettings: true, storedConnectionMode: undefined }),
      false,
      "an empty persisted payload is still a fresh install",
    );
    assert.equal(resolveLegacyOnboardingFlag({ ...base, hasPersistedSettings: true, storedConnectionMode: "bogus" }), false);
  });

  it("names the identity-migration source in all three languages from one owner (Nit-8)", async () => {
    const app = await mountApp();
    app.identityMigrationDiagnostic = "corrupt_settings_storage";

    setLanguage("zh-Hans");
    assert.deepEqual(identityMigrationPresentation(app), {
      text: "本机配置读取失败，可重试",
      sourceName: "本机配置",
      sourceStatus: "无法读取已保存配置 · 请重试",
      retryLabel: "重试读取",
    });

    setLanguage("zh-Hant");
    assert.equal(identityMigrationPresentation(app)?.text, "本機設定讀取失敗，可重試");
    assert.equal(identityMigrationPresentation(app)?.sourceName, "本機設定");

    setLanguage("en");
    assert.equal(identityMigrationPresentation(app)?.text, "Could not read local settings; retry");
    assert.equal(identityMigrationPresentation(app)?.sourceStatus, "Could not read saved settings · retry");

    setLanguage("zh-Hans");
    app.identityMigrationDiagnostic = "credential_vault_read_failed";
    assert.equal(identityMigrationPresentation(app)?.sourceName, "本机凭据库");
    assert.equal(identityMigrationPresentation(app)?.text, "凭据读取失败，可重试");

    // The footer and its detail card share that label: with the popover open the retry button reads
    // "重试读取", not the generic "重试连接".
    app.activeSheet = "none";
    app.connectionDetailsOpen = true;
    app.render();
    await setImmediate();
    assert.match(el("[data-connection-retry]").textContent ?? "", /重试读取/);
    assert.match(renderConnectionStatus(app), /重试读取/);

    app.identityMigrationDiagnostic = null;
    assert.match(renderConnectionStatus(app), /重试连接/);
  });

  it("lets a demo home still offer the identity retry when settings or the vault failed (Nit-1 comment)", async () => {
    const app = await mountApp();
    app.settings.connectionMode = "demo";
    app.identityMigrationDiagnostic = "credential_vault_read_failed";
    app.activeSheet = "none";
    app.render();
    await setImmediate();

    const failed = resolveConnectionStatus(app);
    assert.equal(failed.action?.kind, "retryIdentity", "the read failure outranks demo mode");
    assert.equal(failed.sources.length, 1);
    assert.equal(failed.sources[0]?.id, "identity");
    assert.match(el(".cc-footer-label").textContent ?? "", /凭据读取失败/);

    app.identityMigrationDiagnostic = null;
    app.render();
    await setImmediate();
    assert.equal(resolveConnectionStatus(app).action?.kind, "leaveDemo", "a healthy demo home keeps its leave action");
  });

  it("never re-enables dual-source the user turned off while a QR scan was in flight (Nit-4 race)", async () => {
    const app = await mountApp();
    app.settings.haBaseURL = "http://192.168.1.50:8123";
    app.settings.haToken = "ha-token";
    app.render();
    await setImmediate();

    await click("#btn-onboarding-add-second-platform");
    assert.ok(document.querySelector("#btn-start-qr"));
    app.startXiaomiQRLogin = async () => {
      // The user changes their mind in Settings while the scan/refresh is still running.
      setHostDualSourceEnabled(app, false, { persist: true });
      app.settings.miSession = {
        userId: "10086",
        cUserId: "c10086",
        passToken: "pt-secret",
        serviceToken: "st-secret",
        ssecurity: "ss-secret",
        region: "cn",
      };
    };
    await click("#btn-start-qr");
    await setImmediate();

    assert.equal(isDualSourceEnabled(app), false, "the newer user choice wins");
    assert.equal(localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY), null);
  });

  it("restores preDemoConnectionMode when an HA attempt made from demo fails (Nit-2 comment)", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: {
        invoke: async (name: string) => {
          if (name === "ha_snapshot") throw new Error("401 Unauthorized");
          return null;
        },
      },
      configurable: true,
    });
    const app = new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    await setImmediate();

    app.settings.miSession = {
      userId: "10086",
      cUserId: "c10086",
      passToken: "pt-secret",
      serviceToken: "st-secret",
      ssecurity: "ss-secret",
      region: "cn",
    };
    app.settings.connectionMode = "demo";
    app.settings.preDemoConnectionMode = "xiaomiCloud";
    app.activeSheet = "onboarding";
    app.render();
    await setImmediate();

    await click('[data-onboarding-mode="homeAssistant"]');
    const url = el<HTMLInputElement>("#onboarding-ha-url");
    url.value = "http://192.168.1.50:8123";
    url.dispatchEvent(new window.Event("input", { bubbles: true }));
    const token = el<HTMLInputElement>("#onboarding-ha-token");
    token.value = "bad-token";
    token.dispatchEvent(new window.Event("input", { bubbles: true }));
    await click("#btn-onboarding-connect-ha");
    await setImmediate();
    await setImmediate();

    assert.ok(document.querySelector("[data-onboarding-ha-error]"), "the failed attempt is reported");
    assert.equal(app.settings.connectionMode, "demo", "rollback returns to the demo home");
    assert.equal(
      app.settings.preDemoConnectionMode,
      "xiaomiCloud",
      "leaving demo can still find the Mi login it came from",
    );
  });
});
