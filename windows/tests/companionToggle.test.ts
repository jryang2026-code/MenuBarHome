import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, element, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  COMPANION_REGISTRATION_TIMEOUT_MS,
  buildCompanionConfigText,
  enqueueIncomingOpenUrl,
  getActiveRaycastBridgeTokenForHost,
  getCompanionNotice,
  getLatestRaycastSnapshotForHost,
  hasPendingUrlConfirmation,
  setRaycastIntegrationEnabled,
} from "../src/ui/speechGuard.js";

interface TauriCall {
  readonly cmd: string;
  readonly args?: Record<string, unknown>;
}

const SNAPSHOT_PATH = "C:\\Users\\me\\AppData\\Local\\MenuBarMijia\\raycast-snapshot.json";

let dom: Window;
let tauriCalls: TauriCall[] = [];
let nativeGeneration = 0;
let clipboardText: string | null = null;
let failSnapshotDeletion = false;
/** When set, a registration of that direction never settles until the test resolves it. */
let hangRegistrationFor: "enable" | "disable" | null = null;
let hungRegistrationResolvers: Array<(generation: number) => void> = [];

function installTauriStub(): void {
  tauriCalls = [];
  nativeGeneration = 0;
  failSnapshotDeletion = false;
  hangRegistrationFor = null;
  hungRegistrationResolvers = [];
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (cmd: string, args?: Record<string, unknown>) => {
      tauriCalls.push({ cmd, args });
      if (cmd === "is_workstation_locked") return false;
      if (cmd === "drain_pending_open_urls") return [];
      if (cmd === "set_companion_integration") {
        if (args?.enabled === false && failSnapshotDeletion) throw new Error("snapshot is in use");
        const hangDirection = args?.enabled === true ? "enable" : "disable";
        if (hangRegistrationFor === hangDirection) {
          return new Promise<number>((resolve) => {
            hungRegistrationResolvers.push(resolve);
          });
        }
        nativeGeneration += 1;
        return nativeGeneration;
      }
      if (cmd === "companion_status") {
        return {
          enabled: true,
          snapshotPath: SNAPSHOT_PATH,
          snapshotExists: true,
          snapshotModifiedMs: Date.now(),
          forwardingReady: true,
        };
      }
      return null;
    },
  };
}

async function flushAsync(): Promise<void> {
  for (let i = 0; i < 6; i += 1) await setImmediate();
}

function startDemoApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, ...extraSettings }),
  );
  return new MenuMijiaWindowsApp(element("#app"));
}

function lightState(app: MenuMijiaWindowsApp, id: string): boolean {
  const kind = app.devices.find((d) => d.id === id)!.kind;
  return kind.kind === "light" ? kind.isOn : false;
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  installTauriStub();
  clipboardText = null;
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => { clipboardText = text; } },
  });
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("P6a-W · companion switch-off and revocation", () => {
  it("refuses a revoked token outright, even with direct link control on, and only the new token runs", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: true });
    await flushAsync();
    const oldToken = getActiveRaycastBridgeTokenForHost(app)!;
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const initialOn = lightState(app, light.id);
    const link = (token: string) =>
      `menumijia://power?device=${encodeURIComponent(light.id)}&on=${!initialOn}&token=${token}`;

    setRaycastIntegrationEnabled(app, false);
    await enqueueIncomingOpenUrl(app, link(oldToken));
    assert.match(app.replyBanner?.text ?? "", /CLI \/ MCP 集成已关闭/);
    assert.equal(lightState(app, light.id), initialOn, "an off integration runs no companion command");
    assert.equal(hasPendingUrlConfirmation(app), false, "a companion command is never downgraded to a prompt");

    setRaycastIntegrationEnabled(app, true);
    const newToken = getActiveRaycastBridgeTokenForHost(app)!;
    assert.notEqual(newToken, oldToken);
    await enqueueIncomingOpenUrl(app, link(oldToken));
    assert.match(app.replyBanner?.text ?? "", /令牌已失效/);
    assert.equal(lightState(app, light.id), initialOn, "reopening does not revive the old token");

    await enqueueIncomingOpenUrl(app, link(newToken));
    assert.equal(lightState(app, light.id), !initialOn, "the current token still controls the device");
  });

  it("drops every link queued before a switch, so reopening cannot run them", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: false });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const initialOn = lightState(app, light.id);

    const parked = enqueueIncomingOpenUrl(app, `menumijia://power?device=${encodeURIComponent(light.id)}&on=${!initialOn}`);
    await flushAsync();
    assert.equal(hasPendingUrlConfirmation(app), true, "the first link holds the queue on its prompt");
    const queued = enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=${encodeURIComponent(light.id)}&on=${!initialOn}&id=req_queued&token=${token}`,
    );
    await flushAsync();

    setRaycastIntegrationEnabled(app, false);
    setRaycastIntegrationEnabled(app, true);
    await parked;
    await queued;
    await flushAsync();

    assert.equal(hasPendingUrlConfirmation(app), false, "switching off withdraws the prompt");
    assert.equal(lightState(app, light.id), initialOn, "neither link from the ended run touched the device");
    assert.match(app.replyBanner?.text ?? "", /已取消之前排队的外部链接/);
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback, undefined);
  });

  it("registers each switch with the native host and stamps snapshot writes with its generation", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    await flushAsync();
    const registrations = () => tauriCalls.filter((c) => c.cmd === "set_companion_integration");
    const writes = () => tauriCalls.filter((c) => c.cmd === "write_raycast_snapshot");
    assert.deepEqual(registrations().map((c) => c.args?.enabled), [true]);
    assert.ok(writes().length > 0);
    assert.ok(writes().every((c) => c.args?.generation === 1), "startup writes carry the first generation");

    setRaycastIntegrationEnabled(app, false);
    setRaycastIntegrationEnabled(app, true);
    await flushAsync();
    assert.deepEqual(registrations().map((c) => c.args?.enabled), [true, false, true]);
    assert.equal(writes().at(-1)?.args?.generation, 3, "the reopened run writes under its own generation");
  });

  it("copies a token-free config, checks the connection and disconnects from Settings", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    element("#btn-settings").click();
    await flushAsync();

    element("#btn-companion-copy-config").click();
    await flushAsync();
    assert.ok(clipboardText);
    assert.equal(clipboardText.includes(token), false, "the bridge token never reaches the clipboard");
    const config = JSON.parse(clipboardText) as { mcpServers: { menubarhome: { env: Record<string, string> } } };
    assert.equal(config.mcpServers.menubarhome.env.MENUBARMIJIA_SNAPSHOT_PATH, SNAPSHOT_PATH);
    assert.match(element("#settings-companion-notice").textContent ?? "", /已复制 MCP 配置/);

    element("#btn-companion-detect").click();
    await flushAsync();
    const detected = getCompanionNotice(app)?.lines.join("\n") ?? "";
    assert.match(detected, /设备快照已导出/);
    assert.match(detected, /链接转发正常/);
    assert.equal(getCompanionNotice(app)?.isError, false);

    element("#btn-companion-disconnect").click();
    await flushAsync();
    assert.equal(app.settings.enableRaycastIntegration, false);
    assert.equal(getActiveRaycastBridgeTokenForHost(app), undefined);
    assert.equal(tauriCalls.filter((c) => c.cmd === "set_companion_integration").at(-1)?.args?.enabled, false);
    assert.match(element("#settings-companion-notice").textContent ?? "", /已断开/);
    assert.equal(document.querySelector("#btn-companion-disconnect"), null, "nothing left to disconnect");
  });

  it("speaks all three languages and leaves the path out when it is unknown", () => {
    assert.equal(buildCompanionConfigText(null).includes("MENUBARMIJIA_SNAPSHOT_PATH"), false);
    setLanguage("zh-Hant");
    assert.match(buildCompanionConfigText(null), /原始碼目錄/);
    setLanguage("en");
    assert.match(buildCompanionConfigText(SNAPSHOT_PATH), /source folder/);
  });

  it("keeps standalone Settings disconnected and offers a retry when the native snapshot deletion fails", async () => {
    window.history.replaceState(null, "", "?window=settings&tab=safety");
    const app = startDemoApp({ enableRaycastIntegration: true });
    assert.equal(app.isStandaloneSettingsWindow, true);

    failSnapshotDeletion = true;
    element("#btn-companion-disconnect").click();
    await flushAsync();
    assert.equal(app.settings.enableRaycastIntegration, false);
    assert.equal(getCompanionNotice(app)?.isError, true);
    assert.match(element("#settings-companion-notice").textContent ?? "", /重试/);
    assert.doesNotMatch(element("#settings-companion-notice").textContent ?? "", /快照已删除/);

    failSnapshotDeletion = false;
    element("#btn-companion-disconnect").click();
    await flushAsync();
    assert.match(element("#settings-companion-notice").textContent ?? "", /快照已删除/);
    assert.equal(document.querySelector("#btn-companion-disconnect"), null);
  });

  it("withdraws an external link's high-risk confirmation without turning on the plug", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    const index = app.devices.findIndex((d) => d.kind.kind === "plug" && d.isOnline);
    const plug = app.devices[index]!;
    assert.equal(plug.kind.kind, "plug");
    app.devices[index] = { ...plug, kind: { ...plug.kind, isOn: false } };
    await enqueueIncomingOpenUrl(app, `menumijia://power?device=${encodeURIComponent(plug.id)}&on=true&token=${token}`);

    const selector = `[data-high-risk-confirm="${plug.id}"]`;
    const confirm = element(selector);
    await setRaycastIntegrationEnabled(app, false);
    assert.equal(document.querySelector(selector), null);
    confirm.click();
    await flushAsync();
    const current = app.devices.find((device) => device.id === plug.id)?.kind;
    assert.equal(current?.kind === "plug" && current.isOn, false);
  });

  for (const enabledOnStartup of [false, true]) {
    it(`keeps native integration off without a secure token (startup enabled: ${enabledOnStartup})`, async () => {
      const originalCrypto = Object.getOwnPropertyDescriptor(globalThis, "crypto")!;
      Object.defineProperty(globalThis, "crypto", { value: undefined, configurable: true });
      try {
        const app = startDemoApp({ enableRaycastIntegration: enabledOnStartup });
        if (!enabledOnStartup) await setRaycastIntegrationEnabled(app, true);
        await flushAsync();

        const registrations = tauriCalls.filter((call) => call.cmd === "set_companion_integration");
        assert.ok(registrations.length > 0);
        assert.ok(registrations.every((call) => call.args?.enabled === false));
        assert.equal(tauriCalls.some((call) => call.cmd === "write_raycast_snapshot"), false);
        assert.equal(app.settings.enableRaycastIntegration, false);
      } finally {
        Object.defineProperty(globalThis, "crypto", originalCrypto);
      }
    });
  }

  it("clears old command feedback both when disconnecting and when reconnecting", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const link = (id: string) => `menumijia://power?device=${encodeURIComponent(light.id)}&on=false&token=${token}&id=${id}`;
    const lastRequest = () => getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.requestId;

    await enqueueIncomingOpenUrl(app, link("old-run"));
    assert.equal(lastRequest(), "old-run");
    await setRaycastIntegrationEnabled(app, false);
    assert.equal(lastRequest(), undefined);

    await enqueueIncomingOpenUrl(app, link("while-disabled"));
    assert.equal(lastRequest(), "while-disabled");
    await setRaycastIntegrationEnabled(app, true);
    assert.equal(lastRequest(), undefined);
  });
});

describe("P6a-W · companion registration cannot park the switch queue", () => {
  it("releases a hung enable after the bounded wait so the disconnect still reaches the native host", async (t) => {
    const app = startDemoApp({ enableRaycastIntegration: false });
    await flushAsync();
    t.mock.timers.enable({ apis: ["setTimeout"] });
    try {
      const registrations = () => tauriCalls.filter((c) => c.cmd === "set_companion_integration");
      hangRegistrationFor = "enable";
      const enabling = setRaycastIntegrationEnabled(app, true);
      await flushAsync();
      assert.deepEqual(registrations().map((c) => c.args?.enabled), [false, true], "the enable is in flight");

      hangRegistrationFor = null;
      const disabling = setRaycastIntegrationEnabled(app, false);
      await flushAsync();
      assert.deepEqual(
        registrations().map((c) => c.args?.enabled),
        [false, true],
        "a hung enable still blocks the disconnect before the bound expires",
      );

      t.mock.timers.tick(COMPANION_REGISTRATION_TIMEOUT_MS);
      await flushAsync();
      assert.deepEqual(
        registrations().map((c) => c.args?.enabled),
        [false, true, false],
        "the disconnect reaches the native host once the hung enable times out",
      );
      assert.equal(await disabling, true, "the disconnect still confirms removal");
      assert.equal(await enabling, false, "the timed-out enable never reports a registration");
      assert.equal(getActiveRaycastBridgeTokenForHost(app), undefined, "the token is revoked");
    } finally {
      t.mock.timers.reset();
    }
  });

  it("treats a timed-out registration as a failed disconnect that offers the retry notice", async (t) => {
    const app = startDemoApp({ enableRaycastIntegration: true });
    await flushAsync();
    t.mock.timers.enable({ apis: ["setTimeout"] });
    try {
      hangRegistrationFor = "disable";
      const disconnecting = setRaycastIntegrationEnabled(app, false);
      await flushAsync();
      t.mock.timers.tick(COMPANION_REGISTRATION_TIMEOUT_MS);
      await flushAsync();

      assert.equal(await disconnecting, false, "an unconfirmed disable does not claim success");
      assert.equal(getCompanionNotice(app)?.isError, true);
      assert.equal(getCompanionNotice(app)?.retryDisconnect, true, "the retry affordance stays available");
    } finally {
      t.mock.timers.reset();
    }
  });

  it("keeps normal ordering and drops a late generation from a timed-out call", async (t) => {
    const app = startDemoApp({ enableRaycastIntegration: false });
    await flushAsync();
    t.mock.timers.enable({ apis: ["setTimeout"] });
    try {
      const registrations = () => tauriCalls.filter((c) => c.cmd === "set_companion_integration");
      const writes = () => tauriCalls.filter((c) => c.cmd === "write_raycast_snapshot");

      // A call that settles normally still serializes the queue: the disable waits for it.
      hangRegistrationFor = "enable";
      const enabling = setRaycastIntegrationEnabled(app, true);
      await flushAsync();
      hangRegistrationFor = null;
      const disabling = setRaycastIntegrationEnabled(app, false);
      await flushAsync();
      assert.deepEqual(registrations().map((c) => c.args?.enabled), [false, true], "the disable is still queued");
      hungRegistrationResolvers.forEach((resolve) => resolve(1));
      await flushAsync();
      assert.deepEqual(registrations().map((c) => c.args?.enabled), [false, true, false], "the disable ran after it");
      assert.equal(await enabling, false, "the earlier enable lost its epoch to the newer switch");
      assert.equal(await disabling, true);

      // A generation arriving after the timeout belongs to a superseded run and never reaches a write.
      hangRegistrationFor = "enable";
      const timedOut = setRaycastIntegrationEnabled(app, true);
      await flushAsync();
      t.mock.timers.tick(COMPANION_REGISTRATION_TIMEOUT_MS);
      await flushAsync();
      assert.equal(await timedOut, false, "the timed-out enable reports no registration");
      hungRegistrationResolvers.forEach((resolve) => resolve(99));
      hangRegistrationFor = null;
      await flushAsync();
      assert.ok(writes().every((c) => c.args?.generation !== 99), "a late generation is never used for a write");

      assert.equal(await setRaycastIntegrationEnabled(app, true), true, "a later run still registers normally");
      await flushAsync();
      assert.ok(writes().length > 0);
      assert.ok(writes().every((c) => c.args?.generation !== 99), "the newer run owns the snapshot writes");
    } finally {
      t.mock.timers.reset();
    }
  });
});
