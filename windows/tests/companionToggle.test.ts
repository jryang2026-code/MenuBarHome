import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  buildCompanionConfigText,
  enqueueIncomingOpenUrl,
  getActiveRaycastBridgeTokenForHost,
  getCompanionNotice,
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

function installTauriStub(): void {
  tauriCalls = [];
  nativeGeneration = 0;
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (cmd: string, args?: Record<string, unknown>) => {
      tauriCalls.push({ cmd, args });
      if (cmd === "is_workstation_locked") return false;
      if (cmd === "drain_pending_open_urls") return [];
      if (cmd === "set_companion_integration") {
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

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
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
});
