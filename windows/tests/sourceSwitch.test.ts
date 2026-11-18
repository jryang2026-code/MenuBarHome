import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { clearCachedXiaomiTopology } from "../src/core/pollingPolicy.js";
import type { HttpResponse, MiSession, MiotDeviceSpec } from "../src/core/miCloudClient.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
}

async function flushAsync(rounds = 4): Promise<void> {
  for (let i = 0; i < rounds; i += 1) await setImmediate();
}

const TEST_SSECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
/** The session that lives in the OS credential store before the QR login. */
const OLD_SESSION: MiSession = {
  userId: "20001",
  cUserId: "c20001",
  ssecurity: TEST_SSECURITY,
  serviceToken: "tok-old",
  passToken: "",
  region: "cn",
};

function jsonResponse(payload: unknown, status = 200): HttpResponse {
  return {
    status,
    headers: {},
    body: JSON.stringify(payload),
  };
}

function decryptMiRequestData(body: string): Record<string, unknown> {
  const params = new URLSearchParams(body);
  const nonce = params.get("_nonce") ?? "";
  const encrypted = params.get("data") ?? "";
  const signed = MiCloudCrypto.signedNonce(TEST_SSECURITY, nonce);
  return JSON.parse(MiCloudCrypto.decryptResponse(encrypted, signed)) as Record<string, unknown>;
}

const LIGHT_SPEC: MiotDeviceSpec = {
  type: "urn:miot-spec-v2:device:light:0002A001:test-qr:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:light:00007802:test-qr:1",
      properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-qr:1", format: "bool", access: ["read", "write"] },
      ],
      actions: [],
    },
  ],
};

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("sourceSwitch — QR login account adoption", () => {
  it("cancels a cloud refresh that started under the old account (stale epoch-token gate)", async () => {
    let deviceListCalls = 0;
    const scanGate: { release?: () => void } = {};
    let releaseMiSessionGate: (() => void) | null = null;
    let miSessionReads = 0;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "secure_store_get") {
            if (args.name === "mi_session") {
              miSessionReads += 1;
              if (miSessionReads === 2) {
                // The constructor's initial refresh is now paused inside MiAccountsStore.load(),
                // right before the epoch-token staleness gate in refreshDevices.
                return await new Promise<string | null>((resolve) => {
                  releaseMiSessionGate = () => resolve(JSON.stringify(OLD_SESSION));
                });
              }
              return JSON.stringify(OLD_SESSION);
            }
            return null;
          }
          if (cmd === "is_workstation_locked") return false;
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("device_list")) {
            deviceListCalls += 1;
            return jsonResponse({
              code: 0,
              result: {
                list: [
                  { did: "dev-new", name: "新账号灯", model: "yeelink.light.a", isOnline: true, spec_type: LIGHT_SPEC.type },
                ],
              },
            });
          }
          if (url.includes("homeroom/gethome")) {
            return jsonResponse({
              code: 0,
              result: {
                homelist: [
                  { id: "home-a", name: "新账号家", roomlist: [{ id: "r-a", name: "客厅", dids: ["dev-new"] }] },
                ],
              },
            });
          }
          if (url.includes("/instance?")) {
            return jsonResponse(LIGHT_SPEC);
          }
          if (url.includes("longPolling/loginUrl")) {
            return jsonResponse({
              qr: "https://account.xiaomi.com/qr.png",
              loginUrl: "https://account.xiaomi.com/login",
              lp: "https://lp.account.xiaomi.com/poll",
              timeout: 60,
            });
          }
          if (url === "https://lp.account.xiaomi.com/poll") {
            await new Promise<void>((resolve) => {
              scanGate.release = resolve;
            });
            return jsonResponse({
              userId: "10086",
              cUserId: "c10086",
              ssecurity: TEST_SSECURITY,
              passToken: "pass",
              location: "https://sts.api.io.mi.com/sts?ticket=1",
            });
          }
          if (url.startsWith("https://sts.api.io.mi.com/sts")) {
            return {
              status: 200,
              headers: { "set-cookie": "serviceToken=tok-new; Path=/" },
              body: "",
            };
          }
          if (url.includes("miotspec/prop/get")) {
            const reqData = decryptMiRequestData(String(args.body ?? ""));
            const params = (reqData.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
            return jsonResponse({
              code: 0,
              result: params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: true })),
            });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "xiaomiCloud", hasCompletedOnboarding: true, miCloudRegion: "cn" }),
    );

    const app = new MenuMijiaWindowsApp(element("#app"));
    for (let i = 0; i < 20 && releaseMiSessionGate === null; i += 1) await setImmediate();
    assert.ok(releaseMiSessionGate, "the constructor's cloud refresh is paused inside the account-store load");

    // Pin the account list so the post-login refresh skips the (gated) credential store and can
    // finish while the pre-login refresh is still parked on the mi_session read.
    app.miAccountsOverride = [makeMiAccount(OLD_SESSION)];

    const qrPromise = app.startXiaomiQRLogin();
    for (let i = 0; i < 20 && scanGate.release === undefined; i += 1) await setImmediate();
    assert.ok(scanGate.release, "QR login is awaiting the scan");
    scanGate.release();
    await flushAsync(6);

    // The QR success path adopted the new account; switchSource advanced the localWrite level too.
    assert.equal(app.settings.miSession?.userId, "10086");
    await qrPromise;

    // The regression must not hide behind a warm topology cache (a session-expiry or sign-out
    // clears it): drop it so a surviving pre-login refresh would have to hit the cloud again.
    clearCachedXiaomiTopology(app);

    // Now the pre-login refresh resumes with no other sync in flight: the epoch-token gate must
    // cancel it before any cloud request happens under the newly adopted account.
    releaseMiSessionGate();
    await flushAsync(8);

    assert.equal(
      deviceListCalls,
      1,
      "only the post-login refresh may talk to the cloud; the refresh that started under the old account must be cancelled at the staleness gate",
    );
    assert.equal(app.devices.length, 1, "the new account's refresh adopted its device");
  });
});
