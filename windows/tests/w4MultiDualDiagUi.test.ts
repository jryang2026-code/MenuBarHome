import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { assertMissing } from "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { signOutXiaomiAccount } from "../src/ui/appLifecycle.js";
import {
  getHostDualSourceCoordinator,
  getHostDualSourceState,
  getHostMiAccountsStore,
  isDualSourceEnabled,
  refreshDevices,
  setHostDualSourceEnabled,
  setHostHAInvokeOverride,
} from "../src/ui/cloudRefresh.js";
import {
  CONNECTIONS_DIAG_SEARCH_ANCHORS,
  CUSTOM_HOME_TITLE_STORAGE_KEY,
  addOrUpdateMiAccountOnHost,
  bindConnectionsAndDiagEvents,
  effectivePanelHomeTitle,
  getHostUnsupportedScanner,
  isConnectionsAndDiagModalOpen,
  openConnectionsAndDiagModal,
  readCustomHomeTitle,
  renderConnectionsAndDiagSection,
  resolveHostMiAccounts,
} from "../src/ui/connectionsAndDiagView.js";
import { hasPendingMiVaultDeletion } from "../src/ui/speechGuard.js";
import { searchSettings } from "../src/ui/settingsSearch.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import {
  MiotSpecResolver,
  maskedMiUserId,
  parseMiotDeviceSpec,
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  type MiSession,
} from "../src/core/miCloudClient.js";
import {
  CredentialVault,
  miAccountSessionCredentialName,
  type SecureInvoke,
} from "../src/core/secureStore.js";
import {
  makeMiAccount,
  markAccountSessionRejected,
} from "../src/core/miAccountsStore.js";
import { PINNED_DEVICE_SOURCES_STORAGE_KEY } from "../src/core/dualSourceProvider.js";
import {
  GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL,
  appDiagnosticsLog,
  assertZeroSensitiveLeaks,
} from "../src/core/diagnosticsAndScanner.js";
import type { SmartDevice } from "../src/core/models.js";

const SECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";

const SESSION_CN_PRIMARY: MiSession = {
  userId: "100200300",
  cUserId: "c-100200300",
  ssecurity: SECURITY,
  serviceToken: "tok-cn-primary-w4",
  passToken: "pass-should-strip-cn",
  region: "cn",
};

const SESSION_SG_SECONDARY: MiSession = {
  userId: "550066007",
  cUserId: "c-550066007",
  ssecurity: SECURITY,
  serviceToken: "tok-sg-secondary-w4",
  passToken: "pass-should-strip-sg",
  region: "sg",
};

const LIGHT_MODEL = "yeelink.light.lamp4";
const PLUG_MODEL = "chuangmi.plug.v3";
const CAMERA_MODEL = "isa.camera.hlc7";
const VALVE_READONLY_MODEL = "aqara.valve.v1";
const SG_UNSUPPORTED_MODEL = "lumi.sensor+v2";

const LIGHT_SPEC_RAW = {
  type: "urn:miot-spec-v2:device:light:0000A001:yeelink-lamp4:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:light:00007802:yeelink-lamp4:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:on:00000006:yeelink-lamp4:1",
          format: "bool",
          access: ["read", "write"],
        },
        {
          iid: 2,
          type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-lamp4:1",
          format: "uint8",
          access: ["read", "write"],
          valueRange: [1, 100, 1],
        },
      ],
      actions: [],
    },
  ],
};

const PLUG_SPEC_RAW = {
  type: "urn:miot-spec-v2:device:outlet:0000A002:chuangmi-v3:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:switch:0000780C:chuangmi-v3:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:on:00000006:chuangmi-v3:1",
          format: "bool",
          access: ["read", "write"],
        },
      ],
      actions: [],
    },
  ],
};

const VALVE_SPEC_NO_CONTROLLABLE_RAW = {
  type: "urn:miot-spec-v2:device:valve:0000A0B4:aqara-v1:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:electronic-valve:0000784E:aqara-v1:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:fault:00000009:aqara-v1:1",
          format: "uint8",
          access: ["notify"],
        },
      ],
      actions: [],
    },
  ],
};

function makeInMemorySecureStore(initial: Record<string, string> = {}): {
  invoke: SecureInvoke;
  data: Map<string, string>;
  deletes: string[];
} {
  const data = new Map<string, string>(Object.entries(initial));
  const deletes: string[] = [];
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") {
      return ((data.get(name) ?? null) as unknown) as T | null;
    }
    if (cmd === "secure_store_set") {
      data.set(name, String(args["value"] ?? ""));
      return null;
    }
    if (cmd === "secure_store_delete") {
      deletes.push(name);
      data.delete(name);
      return null;
    }
    return null;
  };
  return { invoke, data, deletes };
}

function decryptMiPayload(body: string, ssecurity = SECURITY): Record<string, unknown> {
  const fields = new URLSearchParams(body);
  const nonce = fields.get("_nonce") ?? "";
  const data = fields.get("data") ?? "";
  const plain = MiCloudCrypto.decryptResponse(data, MiCloudCrypto.signedNonce(ssecurity, nonce));
  return JSON.parse(plain) as Record<string, unknown>;
}

function okMi(result: unknown): HttpResponse {
  return { status: 200, headers: {}, body: JSON.stringify({ code: 0, message: "ok", result }) };
}

function cookieHeaderAccount(req: HttpRequest): { userId: string; host: string; path: string } {
  const url = new URL(req.url);
  const cookie = req.headers?.["Cookie"] ?? req.headers?.["cookie"] ?? "";
  const userMatch = /userId=([^;\s]+)/.exec(cookie);
  return {
    userId: userMatch?.[1] ?? "",
    host: url.host,
    path: url.pathname.replace(/^\/app\//, ""),
  };
}

async function settleUi(turns = 6): Promise<void> {
  for (let i = 0; i < turns; i += 1) {
    await Promise.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function createMountedApp(options: {
  transport?: HttpTransport;
  vault?: CredentialVault;
  secureInvoke?: SecureInvoke;
}): MenuMijiaWindowsApp {
  if (options.secureInvoke) {
    (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = {
      invoke: (cmd: string, args: Record<string, unknown> = {}) => options.secureInvoke!(cmd, args),
    };
  }
  const root = document.getElementById("app")!;
  const app = new MenuMijiaWindowsApp(root);
  if (options.transport) {
    (app as unknown as { transport: HttpTransport }).transport = options.transport;
    (app as unknown as { specResolver: MiotSpecResolver }).specResolver = new MiotSpecResolver(
      options.transport,
      {
        [LIGHT_MODEL]: parseMiotDeviceSpec(LIGHT_SPEC_RAW)!,
        [PLUG_MODEL]: parseMiotDeviceSpec(PLUG_SPEC_RAW)!,
      },
    );
  }
  if (options.vault) {
    (app as unknown as { credentialVault: CredentialVault }).credentialVault = options.vault;
  }
  app.settings.hasCompletedOnboarding = true;
  app.activeSheet = "none";
  app.render();
  return app;
}

let dom: Window | null = null;
let removeCssEscape: (() => void) | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  removeCssEscape = installCssEscape();
  setLanguage("zh-Hans");
  appDiagnosticsLog.clear();
});

afterEach(async () => {
  removeCssEscape?.();
  removeCssEscape = null;
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

describe("W4 Contract: zero-conflict exports, search anchors & custom panel top title", () => {
  it("exports CONNECTIONS_DIAG_SEARCH_ANCHORS matching rendered [data-settings-anchor] nodes and supports standalone Settings mounting", () => {
    const app = createMountedApp({});
    const hostDiv = document.createElement("div");
    document.body.appendChild(hostDiv);

    assert.equal(app.settings.connectionMode, "demo");
    assert.equal(app.settings.haBaseURL, "");
    assert.equal(app.settings.haToken, "");
    hostDiv.innerHTML = renderConnectionsAndDiagSection({
      settings: app.settings,
      devices: app.devices,
      escapeHtml: (v) => app.escapeHtml(v),
    });

    assert.equal(CONNECTIONS_DIAG_SEARCH_ANCHORS.length, 6);
    for (const spec of CONNECTIONS_DIAG_SEARCH_ANCHORS) {
      assert.equal(spec.tab, "connection", `Anchor "${spec.anchor}" must target [data-settings-panel="connection"]`);
      const el = hostDiv.querySelector(`[data-settings-anchor="${spec.anchor}"]`);
      assert.ok(el, `default Demo DOM must include [data-settings-anchor="${spec.anchor}"]`);
      assert.equal(spec.title.length, 3);
      assert.equal(spec.section.length, 3);
      assert.ok(spec.synonyms.length >= 5);
    }
    assert.equal(
      hostDiv.querySelector<HTMLButtonElement>("#btn-disconnect-ha")?.disabled,
      true,
      "#btn-disconnect-ha stays disabled in Demo mode when HA is not connected",
    );

    const wrapperApp = Object.assign(Object.create(Object.getPrototypeOf(app)), app, {
      root: hostDiv,
    }) as MenuMijiaWindowsApp;
    bindConnectionsAndDiagEvents(wrapperApp);
    bindConnectionsAndDiagEvents(wrapperApp);
    hostDiv.remove();
  });

  it("opens custom title drawer from top Home menu (even with < 2 homes), persists customHomeTitle, and restores default when blank", async () => {
    const app = createMountedApp({});
    assert.equal(app.homes.length, 0);

    const homeBtn = app.root.querySelector<HTMLButtonElement>("#btn-home-menu");
    assert.ok(homeBtn, "#btn-home-menu should exist even when homes.length < 2");
    assert.equal(app.root.querySelector(".cc-home-title")?.textContent, "我的米家");

    homeBtn.click();
    assert.equal(app.isHomeMenuOpen, true);
    const titleMenuBtn = app.root.querySelector<HTMLButtonElement>('[data-open-conn-diag="title"]');
    assert.ok(titleMenuBtn, "Home menu should expose custom title quick entry");
    titleMenuBtn.click();
    assert.equal(isConnectionsAndDiagModalOpen(app), true);

    const input = app.root.querySelector<HTMLInputElement>("#settings-custom-home-title");
    assert.ok(input);
    input.value = "  智远的数字中枢  ";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    app.root.querySelector<HTMLButtonElement>("#btn-save-custom-home-title")!.click();

    assert.equal(readCustomHomeTitle(app.settings), "智远的数字中枢");
    assert.equal(localStorage.getItem(CUSTOM_HOME_TITLE_STORAGE_KEY), "智远的数字中枢");
    assert.equal(effectivePanelHomeTitle(app), "智远的数字中枢");
    assert.equal(app.root.querySelector(".cc-home-title")?.textContent, "智远的数字中枢");

    const reloadHost = document.createElement("div");
    document.body.appendChild(reloadHost);
    const reloaded = new MenuMijiaWindowsApp(reloadHost);
    reloaded.settings.hasCompletedOnboarding = true;
    reloaded.activeSheet = "none";
    reloaded.render();
    assert.equal(reloaded.root.querySelector(".cc-home-title")?.textContent, "智远的数字中枢");
    reloadHost.remove();

    const resetBtn = app.root.querySelector<HTMLButtonElement>("#btn-reset-custom-home-title");
    assert.ok(resetBtn);
    resetBtn.click();
    assert.equal(readCustomHomeTitle(app.settings), "");
    assert.equal(localStorage.getItem(CUSTOM_HOME_TITLE_STORAGE_KEY), null);
    assert.equal(app.root.querySelector(".cc-home-title")?.textContent, "我的米家");

    const modal = app.root.querySelector<HTMLElement>("#conn-diag-modal")!;
    modal.dispatchEvent(new dom!.KeyboardEvent("keydown", { key: "Escape", bubbles: true }) as unknown as Event);
    assert.equal(isConnectionsAndDiagModalOpen(app), false);
  });

  it("closes #conn-diag-modal ('accounts') on window Escape even when focus is on document.body without invoking hide_panel", () => {
    const invokedCommands: string[] = [];
    const app = createMountedApp({
      secureInvoke: async (cmd: string) => {
        invokedCommands.push(cmd);
        return null;
      },
    });

    app.root.querySelector<HTMLButtonElement>("#btn-home-menu")!.click();
    app.root.querySelector<HTMLButtonElement>('[data-open-conn-diag="accounts"]')!.click();
    assert.equal(isConnectionsAndDiagModalOpen(app), true);

    const modal = app.root.querySelector<HTMLElement>("#conn-diag-modal");
    assert.ok(modal, "#conn-diag-modal should be rendered");
    assert.ok(
      modal.contains(document.activeElement),
      "opening 'accounts' modal should move focus inside #conn-diag-modal",
    );

    document.body.focus();
    assert.equal(document.activeElement, document.body);
    invokedCommands.length = 0;

    window.dispatchEvent(
      new dom!.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }) as unknown as Event,
    );

    assert.equal(isConnectionsAndDiagModalOpen(app), false, "Escape on window must close #conn-diag-modal");
    assertMissing(app.root.querySelector("#conn-diag-modal"));
    assert.equal(
      invokedCommands.includes("hide_panel"),
      false,
      "Escape closing #conn-diag-modal must not leak through to hide_panel",
    );
  });
});

describe("W4 Multi-Account UI: account cards, token health badges, non-overwriting QR add & single-account sign-out", () => {
  it("adds a secondary regional account via QR without overwriting Account #1, renders token badges, and signs out accounts independently", async () => {
    const secure = makeInMemorySecureStore({
      mi_session: JSON.stringify({
        userId: SESSION_CN_PRIMARY.userId,
        cUserId: SESSION_CN_PRIMARY.cUserId,
        ssecurity: SESSION_CN_PRIMARY.ssecurity,
        serviceToken: SESSION_CN_PRIMARY.serviceToken,
        region: "cn",
      }),
    });
    const vault = new CredentialVault(secure.invoke);

    let resolveSgPoll = null as ((resp: HttpResponse) => void) | null;
    const qrStartRegions: string[] = [];

    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.startsWith("https://account.xiaomi.com/longPolling/loginUrl")) {
        qrStartRegions.push(req.url);
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            code: 0,
            qr: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
            loginUrl: "https://account.xiaomi.com/qr/login",
            lp: `https://lp.account.xiaomi.com/poll/${qrStartRegions.length}`,
            timeout: 120,
          }),
        };
      }
      if (req.url.startsWith("https://lp.account.xiaomi.com/poll/")) {
        return new Promise<HttpResponse>((resolve) => {
          resolveSgPoll = resolve;
        });
      }
      if (req.url.startsWith("https://sts.api.io.mi.com/sts")) {
        return {
          status: 200,
          headers: {
            "set-cookie": `serviceToken=${SESSION_SG_SECONDARY.serviceToken}; Max-Age=3600; Path=/`,
          },
          body: "ok",
        };
      }
      if (req.url.includes("miot-spec.org")) {
        return { status: 200, headers: {}, body: JSON.stringify(LIGHT_SPEC_RAW) };
      }

      const { userId, path } = cookieHeaderAccount(req);
      const payload = req.body ? decryptMiPayload(req.body) : {};
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({ homelist: [{ id: "h-cn", name: "北京家", roomlist: [{ id: "r-cn", name: "客厅", dids: ["did-cn-lamp"] }] }] });
        }
        return okMi({ homelist: [{ id: "h-sg", name: "SG Home", roomlist: [{ id: "r-sg", name: "Study", dids: ["did-sg-lamp"] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({ list: [{ did: "did-cn-lamp", name: "北京吸顶灯", model: LIGHT_MODEL, isOnline: true }] });
        }
        return okMi({ list: [{ did: "did-sg-lamp", name: "新加坡台灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(params.map((p) => ({ ...p, code: 0, value: p.piid === 1 ? true : 75 })));
      }
      return okMi({});
    };

    const app = createMountedApp({ transport, vault, secureInvoke: secure.invoke });
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = { ...SESSION_CN_PRIMARY };
    await refreshDevices(app, false);
    assert.equal(app.devices.length, 1);

    app.root.querySelector<HTMLButtonElement>("#btn-home-menu")!.click();
    app.root.querySelector<HTMLButtonElement>('[data-open-conn-diag="accounts"]')!.click();
    assert.equal(isConnectionsAndDiagModalOpen(app), true);

    const cnAcc = makeMiAccount(SESSION_CN_PRIMARY);
    const sgAcc = makeMiAccount(SESSION_SG_SECONDARY);
    let cards = app.root.querySelectorAll("[data-mi-account-card]");
    assert.equal(cards.length, 1);
    assert.equal(cards[0]?.getAttribute("data-mi-account-card"), cnAcc.id);
    assert.equal(
      cards[0]?.querySelector("[data-mi-account-status]")?.getAttribute("data-mi-account-status"),
      "valid",
    );
    assert.ok(cards[0]?.textContent?.includes(maskedMiUserId(SESSION_CN_PRIMARY.userId)));
    assert.ok(cards[0]?.textContent?.includes("状态正常"));

    app.root.querySelector<HTMLButtonElement>("#btn-add-mi-account")!.click();
    await settleUi();
    const regionSelect = app.root.querySelector<HTMLSelectElement>("#conn-diag-add-region");
    assert.ok(regionSelect, "QR add box should render region selector");
    regionSelect.value = "sg";
    regionSelect.dispatchEvent(new Event("change", { bubbles: true }));
    await settleUi();

    assert.ok(app.root.querySelector('#conn-diag-add-qr-box img[alt="Add Xiaomi Account QR"]'));
    assert.ok(resolveSgPoll, "SG long-poll should be waiting for scan");

    resolveSgPoll({
      status: 200,
      headers: {},
      body: JSON.stringify({
        code: 0,
        userId: SESSION_SG_SECONDARY.userId,
        cUserId: SESSION_SG_SECONDARY.cUserId,
        ssecurity: SESSION_SG_SECONDARY.ssecurity,
        passToken: SESSION_SG_SECONDARY.passToken,
        location: "https://sts.api.io.mi.com/sts?ticket=sg1",
      }),
    });
    await settleUi(12);

    cards = app.root.querySelectorAll("[data-mi-account-card]");
    assert.equal(cards.length, 2, "both CN and SG Xiaomi accounts should be rendered");
    assert.equal(app.settings.miSession?.userId, SESSION_CN_PRIMARY.userId, "primary CN account stays primary");
    assert.ok(secure.data.has("mi_session"), "primary Vault slot preserved");
    const sgSlotName = miAccountSessionCredentialName(sgAcc.slotId);
    assert.ok(secure.data.has(sgSlotName), "secondary SG Vault slot written");
    assert.ok(!secure.data.get(sgSlotName)!.includes("passToken"), "passToken stripped before Vault write");

    assert.equal(app.devices.length, 2);

    const sgCard = app.root.querySelector(`[data-mi-account-card="${sgAcc.id}"]`)!;
    assert.equal(
      sgCard.querySelector("[data-mi-account-status]")?.getAttribute("data-mi-account-status"),
      "expiringSoon",
    );
    assert.ok(sgCard.textContent?.includes("即将过期"));
    assert.ok(sgCard.querySelector(`[data-mi-account-rescan="${sgAcc.id}"]`));

    markAccountSessionRejected(SESSION_CN_PRIMARY, true);
    app.render();
    assert.equal(
      app.root.querySelector(`[data-mi-account-card="${cnAcc.id}"] [data-mi-account-status]`)?.textContent,
      "已失效",
    );
    app.settings.interfaceLanguage = "en";
    app.render();
    assert.equal(
      app.root.querySelector(`[data-mi-account-card="${cnAcc.id}"] [data-mi-account-status]`)?.textContent,
      "Expired",
    );
    assert.equal(
      app.root.querySelector(`[data-mi-account-card="${sgAcc.id}"] [data-mi-account-status]`)?.textContent,
      "Expiring Soon",
    );
    app.settings.interfaceLanguage = "zh-Hans";
    app.render();

    const cnDeviceId = app.devices.find((d) => d.name === "北京吸顶灯")!.id;
    app.expandedDeviceId = cnDeviceId;
    app.waitingDeviceIds.add(cnDeviceId);
    app.cameraLive.activeLiveCameraId = cnDeviceId;
    let cameraClosedCount = 0;
    const origCloseCam = app.cameraLive.closeCameraLiveView.bind(app.cameraLive);
    app.cameraLive.closeCameraLiveView = () => {
      cameraClosedCount += 1;
      origCloseCam();
    };

    const signOutCnBtn = app.root.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${cnAcc.id}"]`)!;
    signOutCnBtn.click();
    await settleUi(10);

    assert.equal(cameraClosedCount, 1);
    assert.equal(app.expandedDeviceId, null);
    assert.equal(app.waitingDeviceIds.has(cnDeviceId), false);
    assert.equal(app.settings.miSession?.userId, SESSION_SG_SECONDARY.userId);
    assert.equal(app.settings.miCloudRegion, "sg");
    assert.equal(app.root.querySelectorAll("[data-mi-account-card]").length, 1);
    assert.equal(app.devices.length, 1);
    assert.equal(app.devices[0]?.name, "新加坡台灯");

    const signOutSgBtn = app.root.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${sgAcc.id}"]`)!;
    signOutSgBtn.click();
    await settleUi(10);

    assert.equal(app.settings.miSession, null);
    assert.equal(app.devices.length, 0);
    assert.ok(app.root.querySelector("[data-mi-accounts-empty]"));
  });

  it("clears stale MiAccountsStore memory cache immediately on legacy signOutXiaomiAccount (#btn-signout-mi / signOutAndRevokeAll)", async () => {
    const secure = makeInMemorySecureStore({});
    const vault = new CredentialVault(secure.invoke);
    const app = createMountedApp({ vault, secureInvoke: secure.invoke });

    await addOrUpdateMiAccountOnHost(app, SESSION_CN_PRIMARY, { triggerRefresh: false });
    await addOrUpdateMiAccountOnHost(app, SESSION_SG_SECONDARY, { triggerRefresh: false });
    openConnectionsAndDiagModal(app, "accounts");

    assert.equal(getHostMiAccountsStore(app).getAccounts().length, 2);
    assert.equal(resolveHostMiAccounts(app).length, 2);
    assert.equal(app.root.querySelectorAll("[data-mi-account-card]").length, 2);

    signOutXiaomiAccount(app);
    assert.equal(hasPendingMiVaultDeletion(), true);
    assert.equal(
      resolveHostMiAccounts(app).length,
      0,
      "resolveHostMiAccounts must return [] immediately while Vault deletion is pending",
    );
    assert.equal(app.root.querySelectorAll("[data-mi-account-card]").length, 0);

    await settleUi(10);
    assert.equal(hasPendingMiVaultDeletion(), false);
    assert.equal(getHostMiAccountsStore(app).getAccounts().length, 0);
    assert.equal(resolveHostMiAccounts(app).length, 0);
    assert.equal(app.root.querySelectorAll("[data-mi-account-card]").length, 0);
    assert.ok(app.root.querySelector("[data-mi-accounts-empty]"));
  });
});

describe("W4 Home Assistant Independent Disconnect: fallback to Xiaomi or clean empty reset", () => {
  it("clears HA token from Vault & settings and automatically falls back to Xiaomi single-source when Xiaomi is signed in", async () => {
    const secure = makeInMemorySecureStore({
      ha_token: "ha-long-lived-secret-token",
    });
    const vault = new CredentialVault(secure.invoke);

    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.includes("miot-spec.org")) {
        return { status: 200, headers: {}, body: JSON.stringify(LIGHT_SPEC_RAW) };
      }
      const { path } = cookieHeaderAccount(req);
      const payload = req.body ? decryptMiPayload(req.body) : {};
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: "h1", name: "家", roomlist: [{ id: "r1", name: "书房", dids: ["mi-lamp-1"] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "mi-lamp-1", name: "米家书房灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(params.map((p) => ({ ...p, code: 0, value: p.piid === 1 ? true : 80 })));
      }
      return okMi({});
    };

    const app = createMountedApp({ transport, vault });
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-long-lived-secret-token";
    app.settings.miSession = { ...SESSION_CN_PRIMARY };
    setHostDualSourceEnabled(app, true, { persist: true });

    openConnectionsAndDiagModal(app, "accounts");
    const disconnectBtn = app.root.querySelector<HTMLButtonElement>("#btn-disconnect-ha");
    assert.ok(disconnectBtn && !disconnectBtn.disabled);

    disconnectBtn.click();
    await settleUi(10);

    assert.equal(app.settings.haToken, "");
    assert.equal(secure.data.has("ha_token"), false, "ha_token deleted from OS credential vault");
    assert.equal(app.settings.haBaseURL, "https://ha.example.test:8123", "haBaseURL preserved for easy reconnect");
    assert.equal(isDualSourceEnabled(app), false, "dual-source automatically turned off");
    assert.equal(app.settings.connectionMode, "xiaomiCloud", "automatically switched back to Xiaomi single-source");
    assert.equal(app.devices.length, 1);
    assert.equal(app.devices[0]?.name, "米家书房灯");
  });

  it("clears residual HA devices, scenes, readings, and homes when disconnecting HA with no Xiaomi account signed in", async () => {
    const secure = makeInMemorySecureStore({ ha_token: "ha-only-token" });
    const vault = new CredentialVault(secure.invoke);
    const app = createMountedApp({ vault });

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-only-token";
    app.settings.miSession = null;
    app.devices = [
      {
        id: "ha:light.kitchen",
        name: "HA 厨房灯",
        roomId: "kitchen",
        roomName: "厨房",
        model: LIGHT_MODEL,
        isOnline: true,
        kind: {
          kind: "light",
          entityId: "light.kitchen",
          isOn: true,
          brightnessPercent: 90,
          colorTempKelvin: null,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
        },
      },
    ];
    app.homes = [{ id: "ha", name: "HA Home", deviceCount: 1 }];
    app.render();

    openConnectionsAndDiagModal(app, "accounts");
    app.root.querySelector<HTMLButtonElement>("#btn-disconnect-ha")!.click();
    await settleUi(8);

    assert.equal(app.settings.haToken, "");
    assert.equal(secure.data.has("ha_token"), false);
    assert.equal(app.devices.length, 0, "residual HA devices cleared when no Xiaomi account exists");
    assert.equal(app.homes.length, 0);
  });
});

describe("W4 Dual-Source Context Menu: source pinning & tri-lingual '离线，临时兜底' badge", () => {
  it("toggles dual-source fusion from UI, pins per-card source via right-click menu, and renders '离线，临时兜底' when pinned source goes offline", async () => {
    let miLampOnline = true;

    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.includes("miot-spec.org")) {
        const spec = req.url.includes("chuangmi-v3") ? PLUG_SPEC_RAW : LIGHT_SPEC_RAW;
        return { status: 200, headers: {}, body: JSON.stringify(spec) };
      }
      const { path } = cookieHeaderAccount(req);
      const payload = req.body ? decryptMiPayload(req.body) : {};
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({
          homelist: [
            { id: "h1", name: "家", roomlist: [{ id: "r1", name: "客厅", dids: ["55667788", "99001122"] }] },
          ],
        });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({
          list: [
            { did: "55667788", name: "客厅主灯", model: LIGHT_MODEL, isOnline: miLampOnline },
            { did: "99001122", name: "单源米家插座", model: PLUG_MODEL, isOnline: true },
          ],
        });
      }
      if (path === "miotspec/prop/get") {
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(params.map((p) => ({ ...p, code: 0, value: p.piid === 1 ? true : 55 })));
      }
      return okMi({});
    };

    const haInvoke = async <T>(cmd: string): Promise<T> => {
      assert.equal(cmd, "ha_snapshot");
      return {
        areas: [{ area_id: "a1", name: "客厅" }],
        devices: [
          {
            id: "ha-dev-5566",
            area_id: "a1",
            name: "客厅主灯 HA",
            model: LIGHT_MODEL,
            identifiers: [["xiaomi_home", "cn_55667788"]],
            connections: [],
          },
        ],
        entities: [
          { entity_id: "light.living_5566", device_id: "ha-dev-5566", area_id: null, disabled_by: null, hidden_by: null },
        ],
        states: [
          { entity_id: "light.living_5566", state: "on", attributes: { friendly_name: "客厅主灯 HA", brightness: 204 } },
        ],
      } as unknown as T;
    };

    const app = createMountedApp({ transport });
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = { ...SESSION_CN_PRIMARY };
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-dual-token";
    setHostHAInvokeOverride(app, haInvoke);

    openConnectionsAndDiagModal(app, "accounts");
    const dualCheckbox = app.root.querySelector<HTMLInputElement>("#settings-dual-source-enabled");
    assert.ok(dualCheckbox && !dualCheckbox.disabled);
    dualCheckbox.checked = true;
    dualCheckbox.dispatchEvent(new Event("change", { bubbles: true }));
    await settleUi(10);

    assert.equal(isDualSourceEnabled(app), true);
    assert.equal(app.devices.length, 2, "paired lamp deduplicated into 1 card + 1 unpaired Xiaomi plug");

    const lamp = app.devices.find((d) => d.kind.kind === "light")!;
    const plug = app.devices.find((d) => d.kind.kind === "plug")!;
    assert.ok(lamp && plug);
    assert.equal(lamp.kind.kind === "light" ? lamp.kind.entityId : "", "light.living_5566");

    app.root.querySelector<HTMLButtonElement>("#btn-close-conn-diag-modal")!.click();
    const lampTile = app.root.querySelector<HTMLElement>(`.cc-tile[data-tile-id="${lamp.id}"]`);
    assert.ok(lampTile, "merged lamp tile rendered on dashboard");
    lampTile.dispatchEvent(new dom!.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 80 }) as unknown as Event);

    const autoItem = app.root.querySelector<HTMLButtonElement>('[data-pin-device-source="auto"]');
    const pinHaItem = app.root.querySelector<HTMLButtonElement>('[data-pin-device-source="homeAssistant"]');
    const pinMiItem = app.root.querySelector<HTMLButtonElement>('[data-pin-device-source="xiaomiCloud"]');
    assert.ok(autoItem && pinHaItem && pinMiItem, "context menu shows all 3 data-source pin choices");
    assert.ok(autoItem.textContent?.includes("自动优先（HA）"));
    assert.ok(pinHaItem.textContent?.includes("固定走 Home Assistant"));
    assert.ok(pinMiItem.textContent?.includes("固定走米家云端"));
    assert.ok(autoItem.classList.contains("is-checked"));
    assertMissing(app.root.querySelector('[data-dual-source-fallback="true"]'));

    pinMiItem.click();
    assert.equal(getHostDualSourceCoordinator(app).pinStorage.get(lamp.id), "xiaomiCloud");
    const persistedPins = JSON.parse(localStorage.getItem(PINNED_DEVICE_SOURCES_STORAGE_KEY) ?? "{}") as Record<string, string>;
    assert.equal(persistedPins[lamp.id], "xiaomiCloud");
    const updatedLamp = app.devices.find((d) => d.id === lamp.id)!;
    assert.equal(updatedLamp.kind.kind === "light" ? updatedLamp.kind.entityId : "", "miot:55667788:2");

    const plugTile = app.root.querySelector<HTMLElement>(`.cc-tile[data-tile-id="${plug.id}"]`)!;
    plugTile.dispatchEvent(new dom!.MouseEvent("contextmenu", { bubbles: true, clientX: 60, clientY: 80 }) as unknown as Event);
    assertMissing(app.root.querySelector("[data-pin-device-source]"));
    app.ctxMenu = null;
    app.render();

    miLampOnline = false;
    await refreshDevices(app, false);
    const fallbackRoute = getHostDualSourceState(app)?.routes[lamp.id];
    assert.equal(fallbackRoute?.backend, "homeAssistant");
    assert.equal(fallbackRoute?.pinnedBackend, "xiaomiCloud");
    assert.equal(fallbackRoute?.fallbackActive, true);

    const expectFallbackMenuText = (lang: "zh-Hans" | "zh-Hant" | "en", expectedBadge: string) => {
      app.settings.interfaceLanguage = lang;
      setLanguage(lang);
      app.ctxMenu = { x: 40, y: 40, deviceId: lamp.id };
      app.render();
      const badge = app.root.querySelector<HTMLElement>('[data-dual-source-fallback="true"]');
      const status = app.root.querySelector<HTMLElement>(`[data-dual-source-status="${lamp.id}"]`);
      assert.ok(badge, `fallback badge rendered for ${lang}`);
      assert.equal(badge.textContent?.trim(), expectedBadge);
      assert.ok(status?.textContent?.toLowerCase().includes(expectedBadge.toLowerCase()));
      assert.ok(
        app.root.querySelector('[data-pin-device-source="xiaomiCloud"]')?.classList.contains("is-checked"),
        "user pin remains checked during temporary fallback",
      );
    };

    expectFallbackMenuText("zh-Hans", "离线，临时兜底");
    expectFallbackMenuText("zh-Hant", "離線，暫時兜底");
    expectFallbackMenuText("en", "Offline, fallback");
  });
});

describe("W4 Scanner & Diagnostics UI: cross-account scan, context-switch auto-clear & zero-leak Markdown export", () => {
  it("scans skipped devices across all signed-in Xiaomi accounts, exports zero-leak Markdown to clipboard, and clears scan results when switching source/account", async () => {
    const fakeLan10 = ["10", "21", "32", "43"].join(".");
    const fakeLan192 = ["192", "168", "50", "88"].join(".");
    const fakeJwt = [
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
      "eyJzdWIiOiIxMDAyMDAzMDAiLCJuYW1lIjoiU2VjcmV0In0",
      "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    ].join(".");
    const secretHomeName = "绝密顶层公寓名称";
    const secretCustomTitle = "王总的私人豪宅面板";

    const secure = makeInMemorySecureStore();
    const vault = new CredentialVault(secure.invoke);

    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.includes("miot-spec.org")) {
        if (req.url.includes("aqara-v1")) {
          return { status: 200, headers: {}, body: JSON.stringify(VALVE_SPEC_NO_CONTROLLABLE_RAW) };
        }
        if (req.url.includes("yeelink-lamp4")) {
          return { status: 200, headers: {}, body: JSON.stringify(LIGHT_SPEC_RAW) };
        }
        return { status: 404, headers: {}, body: "{}" };
      }
      const { userId, path } = cookieHeaderAccount(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({
            has_more: false,
            homelist: [
              { id: "home-secret-cn", name: secretHomeName, roomlist: [{ id: "r1", name: "厨房", dids: ["did-cn-valve"] }] },
            ],
          });
        }
        return okMi({
          has_more: false,
          homelist: [
            { id: "home-secret-sg", name: "SG Private Villa", roomlist: [{ id: "r2", name: "Hall", dids: ["did-sg-sensor"] }] },
          ],
        });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({
            list: [
              {
                did: "did-cn-valve",
                name: `${secretHomeName} 燃气机械阀 ${fakeLan192}`,
                model: VALVE_READONLY_MODEL,
                spec_type: VALVE_SPEC_NO_CONTROLLABLE_RAW.type,
                ip: fakeLan192,
                mac: "AA:BB:CC:DD:EE:11",
                isOnline: true,
              },
            ],
          });
        }
        return okMi({
          list: [
            {
              did: "did-sg-sensor",
              name: "走廊多合一传感器",
              model: SG_UNSUPPORTED_MODEL,
              isOnline: true,
            },
          ],
        });
      }
      return okMi({ home_info: { dlist: [] } });
    };

    let clipboardText = "";
    if (navigator.clipboard) {
      navigator.clipboard.writeText = async (text: string) => {
        clipboardText = text;
      };
    }
    (document as unknown as { execCommand?: (cmd: string) => boolean }).execCommand = (cmd: string) => {
      if (cmd === "copy") {
        const areas = document.body.querySelectorAll("textarea");
        clipboardText = areas[areas.length - 1]?.value ?? "";
      }
      return true;
    };

    const app = createMountedApp({ transport, vault, secureInvoke: secure.invoke });
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = { ...SESSION_CN_PRIMARY };
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESSION_CN_PRIMARY);
    await store.upsertAccount(SESSION_SG_SECONDARY);

    const sampleDevices: SmartDevice[] = [
      {
        id: "did-cam-secret-9988",
        name: "玄关双摄摄像机",
        roomId: "r1",
        roomName: "玄关",
        model: CAMERA_MODEL,
        isOnline: true,
        kind: {
          kind: "camera",
          entityId: "miot:did-cam-secret-9988:2:1",
          streamEntityId: null,
          isOn: true,
          nightShot: "auto",
          availableNightShots: ["auto", "off"],
          isMotionDetectionOn: true,
          motionDetectionEntityId: null,
          lenses: [
            { role: "main", channel: 0, label: "全景" },
            { role: "secondary", channel: 1, label: "特写" },
          ],
        },
      },
      {
        id: "ha:camera.yard_secret",
        name: "院子摄像机",
        roomId: "r2",
        roomName: "院子",
        model: "rtsp.cam.v2",
        isOnline: true,
        kind: {
          kind: "camera",
          entityId: "camera.yard_secret",
          streamEntityId: "camera.yard_secret",
          isOn: true,
          nightShot: null,
          availableNightShots: [],
          isMotionDetectionOn: null,
          motionDetectionEntityId: null,
        },
      },
    ];
    app.devices = sampleDevices;
    app.homes = [{ id: "home-secret-cn", name: secretHomeName, deviceCount: 2 }];

    openConnectionsAndDiagModal(app, "title");
    const titleInput = app.root.querySelector<HTMLInputElement>("#settings-custom-home-title")!;
    titleInput.value = secretCustomTitle;
    app.root.querySelector<HTMLButtonElement>("#btn-save-custom-home-title")!.click();

    appDiagnosticsLog.record({
      summary: `POST https://${fakeLan192}:8123/api failed (gw=${fakeLan10}, mac=AA:BB:CC:DD:EE:11, Bearer ${fakeJwt}, serviceToken=${SESSION_CN_PRIMARY.serviceToken}, did=did-cam-secret-9988, home=${secretHomeName})`,
      category: "miCloud",
      statusCode: 502,
      forbiddenLiterals: [secretHomeName, secretCustomTitle],
    });

    app.root.querySelector<HTMLButtonElement>("#btn-scan-unsupported-devices")!.click();
    await settleUi(12);

    const rows = app.root.querySelectorAll<HTMLElement>("[data-unsupported-device-row]");
    assert.equal(rows.length, 2, "unsupported devices from both CN and SG accounts rendered");
    const renderedModels = Array.from(rows).map((r) => r.getAttribute("data-unsupported-device-row")).sort();
    assert.deepEqual(renderedModels, [SG_UNSUPPORTED_MODEL, VALVE_READONLY_MODEL].sort());

    const listHtml = app.root.querySelector("#conn-diag-unsupported-list")!.innerHTML;
    assert.ok(!listHtml.includes(secretHomeName), "home name stripped from unsupported device row");
    assert.ok(!listHtml.includes(fakeLan192), "private IP stripped from unsupported device row");
    assert.ok(listHtml.includes("valve"), "MIoT spec summary rendered for valve");

    const issueLinks = app.root.querySelectorAll<HTMLAnchorElement>("[data-feedback-issue-url]");
    assert.equal(issueLinks.length, 2);
    for (const link of Array.from(issueLinks)) {
      const href = link.getAttribute("href") ?? "";
      assert.ok(href.startsWith(`${GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL}?`));
      assertZeroSensitiveLeaks(href, { allowGitHubIssueURL: true });
      assert.ok(!href.includes(secretHomeName));
      assert.ok(!href.includes(SESSION_CN_PRIMARY.userId));
    }
    const openedUrls: string[] = [];
    window.__TAURI_INTERNALS__ = {
      invoke: async <T>(cmd: string, args?: Record<string, unknown>): Promise<T> => {
        if (cmd === "open_release_page" && typeof args?.["url"] === "string") {
          openedUrls.push(args["url"]);
        }
        return null as unknown as T;
      },
    };
    issueLinks[0]!.click();
    assert.equal(openedUrls.length, 1);
    assert.equal(openedUrls[0], issueLinks[0]!.getAttribute("href"));
    delete window.__TAURI_INTERNALS__;

    app.root.querySelector<HTMLButtonElement>("#btn-copy-diagnostics-report")!.click();
    await settleUi(6);

    assert.ok(clipboardText.includes("## MenuBarHome 诊断信息"));
    assert.ok(clipboardText.includes("stream_mode=`xiaomi_p2p_mjpeg`"));
    assert.ok(clipboardText.includes("stream_mode=`ha_hls_bridge_mjpeg`"));
    assert.ok(clipboardText.includes(VALVE_READONLY_MODEL));
    assert.ok(clipboardText.includes(SG_UNSUPPORTED_MODEL));
    assertZeroSensitiveLeaks(clipboardText);
    for (const forbidden of [
      secretHomeName,
      secretCustomTitle,
      fakeLan10,
      fakeLan192,
      fakeJwt,
      SESSION_CN_PRIMARY.serviceToken,
      SESSION_SG_SECONDARY.serviceToken,
      SESSION_CN_PRIMARY.userId,
      SESSION_SG_SECONDARY.userId,
      "did-cam-secret-9988",
      "AA:BB:CC:DD:EE:11",
    ]) {
      assert.ok(!clipboardText.includes(forbidden), `diagnostics Markdown must not leak: ${forbidden}`);
    }

    const preview = app.root.querySelector<HTMLTextAreaElement>("#conn-diag-markdown-preview");
    assert.ok(preview && preview.value === clipboardText);
    assert.ok(app.root.querySelector("#conn-diag-copied-badge"));

    assert.equal(getHostUnsupportedScanner(app).devices.length, 2);
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://other-ha.example.test:8123";
    app.render();

    assert.equal(getHostUnsupportedScanner(app).devices.length, 0, "stale scan results cleared on source switch");
    assertMissing(app.root.querySelector("#conn-diag-unsupported-list"));
    assertMissing(app.root.querySelector("#conn-diag-markdown-preview"));
  });

  it("mounts interactively inside real openSettingsSheet('connection') and jumps via Settings full-text search", async () => {
    let clipboardText = "";
    (navigator as unknown as { clipboard?: unknown }).clipboard = {
      writeText: async (text: string) => {
        clipboardText = text;
      },
    };

    const app = createMountedApp({});

    for (const [query, anchor] of [
      ["多账号", "miMultiAccounts"],
      ["断开连接", "haDisconnect"],
      ["双源融合", "dualSourceFusion"],
      ["面板标题", "dashboardTitle"],
      ["扫描未能显示的设备", "scanUnsupportedDevices"],
      ["复制脱敏诊断报告", "copyDiagnostics"],
    ] as const) {
      const outcome = searchSettings(query);
      const hit = outcome.hits.find((h) => h.anchor === anchor);
      assert.ok(hit, `Expected searchSettings("${query}") to match "${anchor}"`);
      assert.equal(hit.tab, "connection");
    }

    app.openSettingsSheet("general");
    assert.equal(app.settingsTab, "general");

    const searchInput = app.root.querySelector<HTMLInputElement>("#settings-search-input");
    assert.ok(searchInput);
    searchInput.value = "复制脱敏诊断报告";
    searchInput.dispatchEvent(new Event("input", { bubbles: true }));
    await settleUi(2);

    const searchHit = app.root.querySelector<HTMLElement>('[data-settings-search-hit="copyDiagnostics"]');
    assert.ok(searchHit, "Settings search dropdown renders copyDiagnostics hit");
    searchHit.click();
    await settleUi(2);

    assert.equal(app.settingsTab, "connection");
    const highlighted = app.root.querySelector<HTMLElement>('[data-settings-anchor="copyDiagnostics"]');
    assert.ok(highlighted);
    assert.equal(highlighted.getAttribute("data-settings-highlighted"), "copyDiagnostics");

    app.openSettingsSheet("connection");
    const connPanel = app.root.querySelector<HTMLElement>('[data-settings-panel="connection"]');
    assert.ok(connPanel);
    for (const spec of CONNECTIONS_DIAG_SEARCH_ANCHORS) {
      assert.ok(
        connPanel.querySelector(`[data-settings-anchor="${spec.anchor}"]`),
        `[data-settings-panel="connection"] must contain [data-settings-anchor="${spec.anchor}"]`,
      );
    }

    const titleInput = app.root.querySelector<HTMLInputElement>('[data-settings-panel="connection"] #settings-custom-home-title');
    assert.ok(titleInput);
    titleInput.value = "书房控制中心";
    titleInput.dispatchEvent(new Event("input", { bubbles: true }));
    app.root.querySelector<HTMLButtonElement>('[data-settings-panel="connection"] #btn-save-custom-home-title')!.click();
    await settleUi(2);
    assert.equal(readCustomHomeTitle(app.settings), "书房控制中心");
    assert.equal(effectivePanelHomeTitle(app), "书房控制中心");

    app.root.querySelector<HTMLButtonElement>('[data-settings-panel="connection"] #btn-copy-diagnostics-report')!.click();
    await settleUi(4);
    assert.ok(clipboardText.includes("## MenuBarHome 诊断信息"));
    assert.ok(app.root.querySelector('[data-settings-panel="connection"] #conn-diag-markdown-preview'));
  });
});
