import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import {
  getHostDualSourceState, getHostMiAccountsState, refreshDevices, setHostDeviceSourcePin,
  setHostDualSourceEnabled, setHostHAInvokeOverride, setHostMiAccounts,
} from "../src/ui/cloudRefresh.js";
import { setLanguage } from "../src/core/i18n.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import {
  MiotSpecResolver, parseMiotDeviceSpec, type HttpRequest, type HttpResponse,
  type HttpTransport, type MiDeviceRecord, type MiSession,
} from "../src/core/miCloudClient.js";
import {
  CredentialVault, WIN32_CRED_MAX_BLOB_BYTES, assertCredentialBlobWithinLimit, credentialBlobByteLength,
  miAccountSessionCredentialName, sanitizeSettingsForStorage, type SecureInvoke,
} from "../src/core/secureStore.js";
import {
  MI_ACCOUNTS_EXPIRED_STORAGE_KEY, MI_ACCOUNTS_INDEX_STORAGE_KEY, MiAccountScope, MiAccountsStore,
  executeMultiAccountMiotCommand, formatAccountTokenNotice, getAccountTokenStatus,
  hasSecondaryMiAccountsInIndex, makeMiAccount, markAccountSessionRejected, miAccountId, refreshMiAccountsConcurrently,
} from "../src/core/miAccountsStore.js";
import {
  CanonicalDeviceRegistry, CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, DUAL_SOURCE_ENABLED_STORAGE_KEY, DeviceDeduplicator, DeviceIdentityNormalizer, DeviceSourcePinStorage,
  DualSourceCoordinator, DualSourceHomeProvider, PINNED_DEVICE_SOURCES_STORAGE_KEY, ROOM_IDENTITY_REGISTRY_STORAGE_KEY, RoomIdentityRegistry, commandTargetBackend,
  currentSourceMenuTitle, extractHADeviceIdentities, extractMiDeviceIdentities, offlineFallbackBadgeText,
} from "../src/core/dualSourceProvider.js";
import { clearHostSessionAndDualSourceState } from "../src/ui/appLifecycle.js";
import { homeProviderFor } from "../src/ui/commandDispatch.js";
import {
  DIAGNOSTICS_RING_BUFFER_CAPACITY, DIAGNOSTICS_RING_STORAGE_KEY, DiagnosticsLog, DiagnosticsReportBuilder,
  GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL, UnsupportedDeviceCollector, UnsupportedDeviceFeedbackURL,
  UnsupportedDeviceScanner, appDiagnosticsLog, assertZeroSensitiveLeaks, deriveCameraDiagnostics,
  derivePollingBackoffDiagnostics, findSensitiveLeaks, summarizeMiotSpec, summarizeModelCounts,
} from "../src/core/diagnosticsAndScanner.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import type { CameraSpec, SmartDevice, SynthesizedHome } from "../src/core/models.js";

const SECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";

const SESSION_CN_PRIMARY: MiSession = {
  userId: "100200300",
  cUserId: "c-100200300",
  ssecurity: SECURITY,
  serviceToken: "tok-cn-primary-alpha",
  passToken: "should-be-stripped-pass-1",
  region: "cn",
};

const SESSION_SG_SECONDARY: MiSession = {
  userId: "550066007",
  cUserId: "c-550066007",
  ssecurity: SECURITY,
  serviceToken: "tok-sg-secondary-beta",
  passToken: "should-be-stripped-pass-2",
  region: "sg",
};

const SESSION_FAMILY_CN: MiSession = {
  userId: "998877665",
  cUserId: "c-998877665",
  ssecurity: SECURITY,
  serviceToken: "tok-cn-family-gamma",
  passToken: "should-be-stripped-pass-3",
  region: "cn",
};

const LIGHT_MODEL = "yeelink.light.lamp4";
const COOKER_MODEL = "chunmi.cooker.normal2";
const SPEAKER_MODEL = "xiaomi.wifispeaker.lx06";
const CAMERA_MODEL = "isa.camera.hlc7";
const VALVE_READONLY_MODEL = "aqara.valve.v1";
const UNKNOWN_GADGET_MODEL = "acme.unknown.mystery1";

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

const VALVE_SPEC_NO_CONTROLLABLE_RAW = {
  type: "urn:miot-spec-v2:device:valve:0000A0B4:aqara-v1:1",
  services: [
    {
      iid: 1,
      type: "urn:miot-spec-v2:service:device-information:00007801:aqara-v1:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:manufacturer:00000001:aqara-v1:1",
          format: "string",
          access: ["read"],
        },
      ],
      actions: [],
    },
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

function makeInMemoryInvoke(options: {
  initial?: Record<string, string>;
  failOnSet?: Set<string>;
  failOnDelete?: Set<string>;
} = {}): {
  invoke: SecureInvoke;
  data: Map<string, string>;
  writes: Array<[string, string]>;
  deletes: string[];
} {
  const data = new Map<string, string>(Object.entries(options.initial ?? {}));
  const writes: Array<[string, string]> = [];
  const deletes: string[] = [];
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") {
      return ((data.get(name) ?? null) as unknown) as T | null;
    }
    if (cmd === "secure_store_set") {
      if (options.failOnSet?.has(name)) {
        throw new Error(`simulated set failure for ${name}`);
      }
      const value = String(args["value"] ?? "");
      writes.push([name, value]);
      data.set(name, value);
      return null;
    }
    if (cmd === "secure_store_delete") {
      if (options.failOnDelete?.has(name)) {
        throw new Error(`simulated delete failure for ${name}`);
      }
      deletes.push(name);
      data.delete(name);
      return null;
    }
    return null;
  };
  return { invoke, data, writes, deletes };
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

function cookieHeaderAccount(req: HttpRequest): { userId: string; serviceToken: string; host: string; path: string } {
  const url = new URL(req.url);
  const cookie = req.headers?.["Cookie"] ?? req.headers?.["cookie"] ?? "";
  const userMatch = /userId=([^;\s]+)/.exec(cookie);
  const tokMatch = /serviceToken=([^;\s]+)/.exec(cookie);
  return {
    userId: userMatch?.[1] ?? "",
    serviceToken: tokMatch?.[1] ?? "",
    host: url.host,
    path: url.pathname.replace(/^\/app\//, ""),
  };
}

let dom: Window | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
  appDiagnosticsLog.clear();
});

afterEach(async () => {
  if (dom) {
    await closeTestWindow(dom);
    dom = null;
  }
});

describe("B6: secureStore multi-account slots & 2-phase credential migration guard (ADR-0010)", () => {
  it("isolates secondary Xiaomi accounts in mi_session_<slotId> slots, strips passToken, and enforces 2560B limit", async () => {
    const { invoke, data } = makeInMemoryInvoke();
    const vault = new CredentialVault(invoke);

    const sanitized = sanitizeSettingsForStorage({
      miSession: SESSION_CN_PRIMARY,
      miAccounts: [SESSION_CN_PRIMARY, SESSION_SG_SECONDARY],
      haToken: "secret-ha",
      openRouterApiKey: "sk-secret",
      connectionMode: "xiaomiCloud",
    });
    assert.equal("miAccounts" in sanitized, false, "miAccounts stripped before localStorage write");
    assert.equal("miSession" in sanitized, false);

    await vault.savePrimaryMiSession(SESSION_CN_PRIMARY);
    const sgAcc = makeMiAccount(SESSION_SG_SECONDARY);
    await vault.saveMiAccountSlot(sgAcc.slotId, SESSION_SG_SECONDARY);

    const primaryRaw = data.get("mi_session") ?? "";
    const sgSlotKey = miAccountSessionCredentialName(sgAcc.slotId);
    const sgRaw = data.get(sgSlotKey) ?? "";

    assert.ok(primaryRaw !== "" && !primaryRaw.includes("should-be-stripped"), "passToken stripped on primary");
    assert.ok(sgRaw !== "" && !sgRaw.includes("should-be-stripped"), "passToken stripped on secondary slot");
    assert.ok(credentialBlobByteLength(primaryRaw) < 400, "each slot stays far under 2560B");
    assert.ok(credentialBlobByteLength(sgRaw) < 400);

    const hugeToken = "x".repeat(WIN32_CRED_MAX_BLOB_BYTES + 100);
    assert.throws(
      () => assertCredentialBlobWithinLimit(hugeToken, sgSlotKey),
      /exceeds Win32 CRED_MAX_CREDENTIAL_BLOB_SIZE/,
    );
    await assert.rejects(
      () => vault.saveMiAccountSlot("overflow_slot", { ...SESSION_SG_SECONDARY, serviceToken: hugeToken }),
      /exceeds Win32 CRED_MAX_CREDENTIAL_BLOB_SIZE/,
    );

    for (let i = 1; i <= 5; i += 1) {
      const s: MiSession = {
        userId: `7000000${i}`,
        cUserId: `c-7000000${i}`,
        ssecurity: SECURITY,
        serviceToken: "t".repeat(700) + String(i),
        passToken: "",
        region: "cn",
      };
      const acc = makeMiAccount(s);
      await vault.saveMiAccountSlot(acc.slotId, s);
    }
    assert.equal((await vault.loadPrimaryMiSession())?.userId, SESSION_CN_PRIMARY.userId);
    assert.equal((await vault.loadMiAccountSlot(sgAcc.slotId))?.userId, SESSION_SG_SECONDARY.userId);
  });

  it("preserves the 4-step two-phase legacy assistant_api_key migration guard when secondary Xiaomi slots exist", async () => {
    const sgAcc = makeMiAccount(SESSION_SG_SECONDARY);
    const { invoke: failingInvoke, data: failingData } = makeInMemoryInvoke({
      initial: {
        assistant_api_key: "sk-legacy-precious-key",
        [miAccountSessionCredentialName(sgAcc.slotId)]: JSON.stringify({
          ...SESSION_SG_SECONDARY,
          passToken: "",
        }),
      },
      failOnSet: new Set(["assistant_api_key_openrouter_jev"]),
    });
    const failingVault = new CredentialVault(failingInvoke);

    const loaded1 = await failingVault.load("openrouter_jev");
    assert.equal(loaded1.assistantApiKeys?.["openrouter_jev"], "sk-legacy-precious-key");
    assert.equal(failingVault.hasLegacyAssistantKey(), true);
    assert.equal(failingData.get("assistant_api_key"), "sk-legacy-precious-key");
    assert.ok(failingData.has(miAccountSessionCredentialName(sgAcc.slotId)), "secondary Xiaomi slot untouched");

    const { invoke: okInvoke, data: okData } = makeInMemoryInvoke({
      initial: Object.fromEntries(failingData.entries()),
    });
    const okVault = new CredentialVault(okInvoke);
    await okVault.load("openrouter_jev");
    await okVault.persist({
      miSession: SESSION_CN_PRIMARY,
      haToken: "ha-tok",
      assistantApiKey: "sk-legacy-precious-key",
      assistantApiKeys: { openrouter_jev: "sk-legacy-precious-key" },
    });
    assert.equal(okData.has("assistant_api_key"), false);
    assert.equal(okData.get("assistant_api_key_openrouter_jev"), "sk-legacy-precious-key");
    assert.ok(okData.has(miAccountSessionCredentialName(sgAcc.slotId)), "secondary Xiaomi slot still intact");
  });

  it("revokes all secondary mi_session_<slotId> slots and index on deleteMiSession / clearAll (fail-closed)", async () => {
    const failOnDelete = new Set<string>();
    const { invoke, data } = makeInMemoryInvoke({ failOnDelete });
    const vault = new CredentialVault(invoke);
    const store = new MiAccountsStore(vault, localStorage);
    const r1 = await store.upsertAccount(SESSION_CN_PRIMARY);
    const r2 = await store.upsertAccount(SESSION_SG_SECONDARY);
    const r3 = await store.upsertAccount(SESSION_FAMILY_CN);
    markAccountSessionRejected(SESSION_SG_SECONDARY, true, { isPrimary: false, storage: localStorage });
    const sgSlotKey = miAccountSessionCredentialName(r2.account.slotId);
    const famSlotKey = miAccountSessionCredentialName(r3.account.slotId);
    assert.equal(hasSecondaryMiAccountsInIndex(), true);
    assert.ok(localStorage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY) !== null);

    failOnDelete.add(sgSlotKey);
    await assert.rejects(() => store.clearAll(), /simulated delete failure/);
    assert.ok(localStorage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY) !== null, "index retained after clearAll failure");
    assert.ok(data.has(sgSlotKey), "failed secondary slot still tracked for retry");
    await assert.rejects(() => vault.deleteMiSession(), /simulated delete failure/);
    assert.ok(localStorage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY) !== null, "index retained after deleteMiSession failure");

    failOnDelete.clear();
    await vault.deleteMiSession();
    assert.equal(data.has("mi_session"), false);
    assert.equal(data.has(miAccountSessionCredentialName(r1.account.slotId)), false);
    assert.equal(data.has(sgSlotKey), false);
    assert.equal(data.has(famSlotKey), false);
    assert.equal(localStorage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);
    assert.equal(localStorage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), null);
    assert.equal(hasSecondaryMiAccountsInIndex(), false);
    assert.equal(store.getAccounts().length, 0, "stale in-memory cachedAccounts invalidated on external deleteMiSession");
    assert.deepEqual(await store.load(), []);
  });
});

describe("B6: MiAccountsStore coexistence, <accountId>/ namespacing, shared did dedupe & fault isolation", () => {
  it("adds CN + SG + family accounts without overwriting, updates in place, and promotes accounts[1] two-phase when primary signs out", async () => {
    const { invoke, data, writes, deletes } = makeInMemoryInvoke();
    const vault = new CredentialVault(invoke);
    const store = new MiAccountsStore(vault, localStorage);

    const r1 = await store.upsertAccount(SESSION_CN_PRIMARY);
    assert.equal(r1.added, true);
    assert.equal(r1.accounts.length, 1);

    const r2 = await store.upsertAccount(SESSION_SG_SECONDARY);
    assert.equal(r2.added, true);
    assert.equal(r2.accounts.length, 2);

    const r3 = await store.upsertAccount(SESSION_FAMILY_CN);
    assert.equal(r3.added, true);
    assert.equal(r3.accounts.length, 3);

    const rawIndex = localStorage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY) ?? "";
    assert.ok(!rawIndex.includes(SESSION_CN_PRIMARY.userId));
    assert.ok(!rawIndex.includes(SESSION_SG_SECONDARY.serviceToken));

    const refreshedSg = { ...SESSION_SG_SECONDARY, serviceToken: "tok-sg-rotated-new" };
    const r2Update = await store.upsertAccount(refreshedSg);
    assert.equal(r2Update.added, false);
    assert.equal(r2Update.accounts.length, 3);
    assert.equal(r2Update.account.session.serviceToken, "tok-sg-rotated-new");

    const sgId = miAccountId({ userId: SESSION_SG_SECONDARY.userId, region: "sg" });
    const afterRemoveSg = await store.removeAccount(sgId);
    assert.equal(afterRemoveSg.accounts.length, 2);
    assert.equal(data.has(miAccountSessionCredentialName(r2.account.slotId)), false);

    writes.length = 0;
    deletes.length = 0;
    const primaryId = miAccountId({ userId: SESSION_CN_PRIMARY.userId, region: "cn" });
    const familySlotKey = miAccountSessionCredentialName(r3.account.slotId);
    const afterRemovePrimary = await store.removeAccount(primaryId);
    assert.equal(afterRemovePrimary.accounts.length, 1);
    assert.equal(afterRemovePrimary.accounts[0]?.session.userId, SESSION_FAMILY_CN.userId);
    assert.equal((await vault.loadPrimaryMiSession())?.userId, SESSION_FAMILY_CN.userId);
    assert.equal(data.has(familySlotKey), false);
    assert.equal(writes[0]?.[0], "mi_session", "promoted primary written BEFORE secondary slot deletion");
    assert.ok(deletes.includes(familySlotKey));
  });

  it("tracks per-account serviceToken 3-day expiringSoon & server-rejected expired states independently", () => {
    const nowMs = Date.UTC(2026, 10, 14, 0, 0, 0);
    const twoDaysMs = nowMs + 2 * 24 * 3600 * 1000;
    const twoDaysUtc = new Date(twoDaysMs).toUTCString();
    const tenDaysUtc = new Date(nowMs + 10 * 24 * 3600 * 1000).toUTCString();
    const pastUtc = new Date(nowMs - 3600 * 1000).toUTCString();

    const accSoon = makeMiAccount({
      ...SESSION_CN_PRIMARY,
      serviceToken: `tok-soon; Expires=${twoDaysUtc}; Path=/`,
    });
    const accFresh = makeMiAccount({
      ...SESSION_SG_SECONDARY,
      serviceToken: `tok-fresh; Expires=${tenDaysUtc}; Path=/`,
    });
    const accPast = makeMiAccount({
      ...SESSION_FAMILY_CN,
      serviceToken: `tok-past; Expires=${pastUtc}; Path=/`,
    });

    const stSoon = getAccountTokenStatus(accSoon, nowMs, localStorage);
    assert.equal(stSoon.kind, "expiringSoon");
    if (stSoon.kind === "expiringSoon") {
      assert.equal(stSoon.expiresAtMs, twoDaysMs);
    }
    assert.match(formatAccountTokenNotice(accSoon, stSoon, "zh-Hans") ?? "", /将在 .* 到期/);
    assert.match(formatAccountTokenNotice(accSoon, stSoon, "zh-Hant") ?? "", /將在 .* 到期/);
    assert.match(formatAccountTokenNotice(accSoon, stSoon, "en") ?? "", /expires on/i);

    const accExplicitSoon = makeMiAccount({ ...SESSION_CN_PRIMARY, expiresAt: twoDaysMs });
    assert.equal(getAccountTokenStatus(accExplicitSoon, nowMs, localStorage).kind, "expiringSoon");

    assert.equal(getAccountTokenStatus(accFresh, nowMs, localStorage).kind, "valid");
    assert.equal(getAccountTokenStatus(accPast, nowMs, localStorage).kind, "expired");

    markAccountSessionRejected(accFresh.session, true, { isPrimary: false, storage: localStorage, nowMs });
    assert.equal(getAccountTokenStatus(accFresh, nowMs, localStorage).kind, "expired");
    assert.equal(getAccountTokenStatus(accSoon, nowMs, localStorage).kind, "expiringSoon");
  });

  it("namespaces rooms with <accountId>/, deduplicates shared physical did primary-first, isolates secondary errors, and fails over MIoT commands", async () => {
    const acc1 = makeMiAccount(SESSION_CN_PRIMARY);
    const acc2 = makeMiAccount(SESSION_SG_SECONDARY);
    const acc3Failing = makeMiAccount(SESSION_FAMILY_CN);

    let failAcc3Mode: "http500" | "expired" = "http500";
    let expireAcc1OnSetProps = false;
    const setPropsByUserId: string[] = [];

    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.includes("miot-spec.org")) {
        return { status: 200, headers: {}, body: JSON.stringify(LIGHT_SPEC_RAW) };
      }
      const { userId, path } = cookieHeaderAccount(req);
      const payload = req.body ? decryptMiPayload(req.body) : {};

      if (userId === SESSION_FAMILY_CN.userId) {
        if (failAcc3Mode === "expired") {
          return { status: 401, headers: {}, body: JSON.stringify({ code: 401, message: "invalid_token" }) };
        }
        return { status: 500, headers: {}, body: JSON.stringify({ error: "Internal Server Error" }) };
      }

      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({
          homelist: [
            {
              id: userId === SESSION_CN_PRIMARY.userId ? "home-cn-1" : "home-sg-1",
              name: "我的家",
              roomlist: [
                {
                  id: "room-living",
                  name: "客厅",
                  dids:
                    userId === SESSION_CN_PRIMARY.userId
                      ? ["did-shared-lamp", "did-cn-only"]
                      : ["did-shared-lamp", "did-sg-only"],
                },
              ],
            },
          ],
        });
      }

      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({
            list: [
              { did: "did-shared-lamp", name: "主账号共享吸顶灯", model: LIGHT_MODEL, isOnline: true },
              { did: "did-cn-only", name: "国区台灯", model: LIGHT_MODEL, isOnline: true },
            ],
          });
        }
        return okMi({
          list: [
            { did: "did-shared-lamp", name: "副账号重复吸顶灯", model: LIGHT_MODEL, isOnline: true },
            { did: "did-sg-only", name: "新加坡落地灯", model: LIGHT_MODEL, isOnline: true },
          ],
        });
      }

      if (path === "miotspec/prop/get") {
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(
          params.map((p) => ({
            did: p.did,
            siid: p.siid,
            piid: p.piid,
            code: 0,
            value: p.piid === 1 ? true : 80,
          })),
        );
      }

      if (path === "miotspec/prop/set") {
        if (userId === SESSION_CN_PRIMARY.userId && expireAcc1OnSetProps) {
          return { status: 401, headers: {}, body: JSON.stringify({ code: 401, message: "invalid_token" }) };
        }
        setPropsByUserId.push(userId);
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(params.map((p) => ({ ...p, code: 0 })));
      }

      return okMi({});
    };

    const specResolver = new MiotSpecResolver(transport, {
      [LIGHT_MODEL]: parseMiotDeviceSpec(LIGHT_SPEC_RAW)!,
    });

    const { merged } = await refreshMiAccountsConcurrently({
      accounts: [acc1, acc2, acc3Failing],
      transport,
      specResolver,
      storage: localStorage,
    });

    assert.equal(merged.aggregateStatus.kind, "connected");
    assert.equal(merged.accountStatuses[acc1.id]?.kind, "connected");
    assert.equal(merged.accountStatuses[acc2.id]?.kind, "connected");
    assert.equal(merged.accountStatuses[acc3Failing.id]?.kind, "disconnected");

    const roomIds = merged.home.rooms.map((r) => r.id);
    assert.deepEqual(roomIds, [`${acc1.id}/room_room-living`, `${acc2.id}/room_room-living`]);
    assert.ok(MiAccountScope.isOwned(`${acc1.id}/room_room-living`, acc1.id));
    assert.equal(MiAccountScope.localId(`${acc2.id}/room_room-living`), "room_room-living");

    assert.equal(merged.home.devices.length, 3);
    const sharedLamp = merged.home.devices.find((d) => d.id === "did-shared-lamp");
    const sgLamp = merged.home.devices.find((d) => d.id === "did-sg-only");
    assert.ok(sharedLamp && sgLamp);
    assert.equal(sharedLamp.name, "主账号共享吸顶灯");
    assert.equal(sharedLamp.roomId, `${acc1.id}/room_room-living`);
    assert.equal(sharedLamp.accountId, acc1.id);
    assert.equal(sgLamp.roomId, `${acc2.id}/room_room-living`);
    assert.equal(sgLamp.accountId, acc2.id);
    assert.deepEqual(merged.deviceOwners["did-shared-lamp"], [acc1.id, acc2.id]);

    expireAcc1OnSetProps = true;
    const cmdRes = await executeMultiAccountMiotCommand(
      { kind: "setLightPower", entityId: "miot:did-shared-lamp:2", isOn: false },
      {
        accounts: [acc1, acc2],
        deviceOwners: merged.deviceOwners,
        specsByModel: merged.specsByModel,
        devices: merged.home.devices,
        transport,
        storage: localStorage,
      },
    );
    assert.equal(cmdRes.executedByAccountId, acc2.id);
    assert.deepEqual(setPropsByUserId, [SESSION_SG_SECONDARY.userId]);

    markAccountSessionRejected(acc1.session, false, { isPrimary: true, storage: localStorage });
    failAcc3Mode = "expired";
    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    (app as unknown as { transport: HttpTransport }).transport = transport;
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESSION_CN_PRIMARY;
    setHostMiAccounts(app, [acc1, acc2, acc3Failing]);

    await refreshDevices(app, false);
    assert.equal(app.devices.length, 3);
    assert.equal(app.miSessionExpired, false);
    assert.equal(getHostMiAccountsState(app)?.accounts.length, 3);
    assert.equal(app.roomOptions.length, 2, "two distinct room pills for the two accounts' 客厅");
  });
});

describe("B7: Home Assistant + Xiaomi Cloud dual-source parallel fusion, 3-tier dedupe & offline fallback pin (ADR-0008)", () => {
  function makeLightDevice(overrides: {
    id: string;
    name: string;
    roomId: string;
    roomName: string;
    entityId: string;
    model?: string;
    isOnline?: boolean;
    isOn?: boolean;
  }): SmartDevice {
    return {
      id: overrides.id,
      name: overrides.name,
      roomId: overrides.roomId,
      roomName: overrides.roomName,
      model: overrides.model ?? LIGHT_MODEL,
      isOnline: overrides.isOnline ?? true,
      kind: {
        kind: "light",
        entityId: overrides.entityId,
        isOn: overrides.isOn ?? true,
        brightnessPercent: 75,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        availableEffects: [],
        currentEffect: null,
      },
    };
  }

  it("deduplicates across all 3 hardware tiers (1: explicit did -> 2: normalized MAC -> 3: unique same-room category) and guards ambiguous multi-light rooms", () => {
    assert.equal(DeviceIdentityNormalizer.macAddress("AA:BB:CC:DD:EE:FF"), "aabbccddeeff");
    assert.equal(DeviceIdentityNormalizer.macAddress("aa-bb-cc-dd-ee-ff"), "aabbccddeeff");
    assert.deepEqual(DeviceIdentityNormalizer.didCandidates(["cn_987654321"]), ["987654321"]);

    const haDevices: SmartDevice[] = [
      makeLightDevice({ id: "ha-dev-tier1", name: "Living Lamp HA", roomId: "area-1", roomName: "Living", entityId: "light.living_ha" }),
      makeLightDevice({ id: "ha-dev-tier2", name: "Bedroom Ceiling", roomId: "area-2", roomName: "主卧", entityId: "light.master_ha" }),
      makeLightDevice({ id: "ha-dev-tier3", name: "书房台灯 HA", roomId: "area-3", roomName: "书房", entityId: "light.study_ha", model: LIGHT_MODEL }),
      makeLightDevice({ id: "ha-ambig-1", name: "次卧筒灯左", roomId: "area-4", roomName: "次卧", entityId: "light.guest_1", model: LIGHT_MODEL }),
      makeLightDevice({ id: "ha-ambig-2", name: "次卧筒灯右", roomId: "area-4", roomName: "次卧", entityId: "light.guest_2", model: LIGHT_MODEL }),
    ];

    const miRiceCooker: SmartDevice = {
      id: "did-cooker-only",
      name: "米家智能电饭煲",
      roomId: "mi-kitchen",
      roomName: "厨房",
      model: COOKER_MODEL,
      isOnline: true,
      kind: {
        kind: "appliance",
        entityId: "miot:did-cooker-only:2:1",
        isOn: true,
        powerPresent: false,
        powerWritable: false,
        currentMode: "精煮",
        availableModes: ["精煮", "快煮"],
        modeWritable: true,
        targetTemperature: null,
        currentTemperature: null,
        minTemp: 40,
        maxTemp: 100,
        step: 1,
        temperatureWritable: false,
        statusText: "煮饭中",
        faultText: null,
        remainingMinutes: 18,
        startAction: { kind: "start", entityId: "miot-action:did-cooker-only:2:1" },
        pauseAction: null,
        stopAction: { kind: "stop", entityId: "miot-action:did-cooker-only:2:2" },
        powerEntityId: "",
        modeEntityId: "miot:did-cooker-only:2:2",
        temperatureEntityId: "",
        light: null,
        fanLevel: null,
        currentHumidity: null,
        symbolName: null,
        roomReading: false,
        heats: true,
      },
    };
    const miSpeaker: SmartDevice = {
      id: "did-xiaoai",
      name: "小爱音箱 Pro",
      roomId: "mi-living",
      roomName: "客厅",
      model: SPEAKER_MODEL,
      isOnline: true,
      kind: {
        kind: "speaker",
        mediaEntityId: "miot:did-xiaoai:3:1",
        state: "playing",
        volumePercent: 45,
        isMuted: false,
        muteSwitchEntityId: "miot:did-xiaoai:3:2",
        sleepModeEntityId: null,
        isSleepMode: false,
        volumeWritable: true,
        ttsActionId: "miot-action:did-xiaoai:5:1",
        directiveActionId: "miot-action:did-xiaoai:5:3",
      },
    };
    const haBasicSpeaker: SmartDevice = {
      id: "ha-xiaoai",
      name: "XiaoAi Media Player",
      roomId: "area-1",
      roomName: "客厅",
      model: SPEAKER_MODEL,
      isOnline: true,
      kind: {
        kind: "speaker",
        mediaEntityId: "media_player.xiaoai",
        state: "playing",
        volumePercent: 45,
        isMuted: false,
        muteSwitchEntityId: null,
        sleepModeEntityId: null,
        isSleepMode: false,
        volumeWritable: true,
      },
    };
    const streamlessCamSpec: CameraSpec = {
      kind: "camera",
      entityId: "switch.cam_power",
      isOn: true,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
      streamEntityId: null,
      snapshotPath: null,
    };
    const haStreamlessCamera: SmartDevice = {
      id: "ha-cam-nostream",
      name: "门口摄像机",
      roomId: "area-1",
      roomName: "玄关",
      model: CAMERA_MODEL,
      isOnline: true,
      kind: streamlessCamSpec,
    };
    const miP2PCamera: SmartDevice = {
      ...haStreamlessCamera,
      id: "did-cam-p2p",
      kind: {
        ...streamlessCamSpec,
        entityId: "miot:did-cam-p2p:2:1",
      },
    };

    const allHADevices = [...haDevices, haBasicSpeaker, haStreamlessCamera];
    const miDevices: SmartDevice[] = [
      makeLightDevice({ id: "987654321", name: "客厅吸顶灯", roomId: "mi-r1", roomName: "客厅", entityId: "miot:987654321:2:1" }),
      makeLightDevice({ id: "did-mac-lamp", name: "主卧吸顶灯", roomId: "mi-r2", roomName: "主卧", entityId: "miot:did-mac-lamp:2:1" }),
      makeLightDevice({ id: "did-study-lamp", name: "书房台灯", roomId: "mi-r3", roomName: "书房", entityId: "miot:did-study-lamp:2:1", model: LIGHT_MODEL }),
      makeLightDevice({ id: "did-guest-1", name: "次卧筒灯", roomId: "mi-r4", roomName: "次卧", entityId: "miot:did-guest-1:2:1", model: LIGHT_MODEL }),
      miRiceCooker,
      miSpeaker,
      miP2PCamera,
    ];

    const haSnapshotRaw = {
      areas: [
        { area_id: "area-1", name: "客厅" },
        { area_id: "area-2", name: "主卧" },
        { area_id: "area-3", name: "书房" },
        { area_id: "area-4", name: "次卧" },
      ],
      devices: [
        { id: "ha-dev-tier1", area_id: "area-1", name: "Living Lamp HA", model: LIGHT_MODEL, identifiers: [["xiaomi_home", "cn_987654321"]], connections: [] },
        { id: "ha-dev-tier2", area_id: "area-2", name: "Bedroom Ceiling", model: LIGHT_MODEL, identifiers: [], connections: [["mac", "AA:BB:CC:DD:EE:11"]] },
        { id: "ha-dev-tier3", area_id: "area-3", name: "书房台灯 HA", model: LIGHT_MODEL, identifiers: [], connections: [] },
        { id: "ha-ambig-1", area_id: "area-4", name: "次卧筒灯左", model: LIGHT_MODEL, identifiers: [], connections: [] },
        { id: "ha-ambig-2", area_id: "area-4", name: "次卧筒灯右", model: LIGHT_MODEL, identifiers: [], connections: [] },
        { id: "ha-xiaoai", area_id: "area-1", name: "XiaoAi Media Player", model: SPEAKER_MODEL, identifiers: [["xiaomi_home", "did-xiaoai"]], connections: [] },
        { id: "ha-cam-nostream", area_id: "area-1", name: "门口摄像机", model: CAMERA_MODEL, identifiers: [["xiaomi_home", "did-cam-p2p"]], connections: [] },
      ],
      entities: [],
      states: [],
    };
    const haHome: SynthesizedHome = {
      devices: allHADevices,
      rooms: [],
      environmentReadings: [],
      scenes: [{ id: "scene.movie_night", name: "观影模式", entityId: "scene.movie_night" }],
    };
    const miHome: SynthesizedHome = {
      devices: miDevices,
      rooms: [],
      environmentReadings: [],
      scenes: [],
    };
    const miRawRecords: MiDeviceRecord[] = [
      { did: "987654321", name: "客厅吸顶灯", model: LIGHT_MODEL, specType: null, isOnline: true },
      { did: "did-mac-lamp", name: "主卧吸顶灯", model: LIGHT_MODEL, specType: null, isOnline: true, mac: "aa-bb-cc-dd-ee-11" },
      { did: "did-study-lamp", name: "书房台灯", model: LIGHT_MODEL, specType: null, isOnline: true },
      { did: "did-guest-1", name: "次卧筒灯", model: LIGHT_MODEL, specType: null, isOnline: true },
      { did: "did-cooker-only", name: "米家智能电饭煲", model: COOKER_MODEL, specType: null, isOnline: true },
      { did: "did-xiaoai", name: "小爱音箱 Pro", model: SPEAKER_MODEL, specType: null, isOnline: true },
      { did: "did-cam-p2p", name: "门口摄像机", model: CAMERA_MODEL, specType: null, isOnline: true },
    ];

    const haIdentities = extractHADeviceIdentities(haSnapshotRaw, haHome);
    const miIdentities = extractMiDeviceIdentities(miRawRecords, miHome);

    const res = DeviceDeduplicator.merge({
      homeAssistant: { home: haHome, identities: haIdentities },
      xiaomiCloud: { home: miHome, identities: miIdentities },
      knownPreferenceIds: new Set(["987654321"]),
    });

    assert.equal(res.home.devices.length, 9);
    assert.equal(res.pairedDeviceIds.size, 5);
    assert.equal(res.home.scenes.length, 1, "HA scenes preserved");

    const tier1Card = res.home.devices.find((d) => d.id === "987654321");
    assert.ok(tier1Card);
    assert.equal(res.routes["987654321"]?.backend, "homeAssistant");
    assert.equal(tier1Card.kind.kind === "light" ? tier1Card.kind.entityId : "", "light.living_ha");

    const tier2Cid = res.miCanonicalIds["did-mac-lamp"]!;
    const tier3Cid = res.miCanonicalIds["did-study-lamp"]!;
    assert.equal(tier2Cid, res.haCanonicalIds["ha-dev-tier2"]);
    assert.equal(tier3Cid, res.haCanonicalIds["ha-dev-tier3"]);
    assert.equal(res.routes[tier2Cid]?.backend, "homeAssistant");
    assert.equal(res.routes[tier3Cid]?.backend, "homeAssistant");

    assert.notEqual(res.miCanonicalIds["did-guest-1"], res.haCanonicalIds["ha-ambig-1"]);
    assert.notEqual(res.miCanonicalIds["did-guest-1"], res.haCanonicalIds["ha-ambig-2"]);

    assert.equal(res.routes["did-cooker-only"]?.backend, "xiaomiCloud");
    const speakerCid = res.miCanonicalIds["did-xiaoai"]!;
    assert.equal(res.routes[speakerCid]?.backend, "xiaomiCloud", "XiaoAi TTS beats basic HA media_player");
    const camCid = res.miCanonicalIds["did-cam-p2p"]!;
    assert.equal(res.routes[camCid]?.backend, "xiaomiCloud", "Xiaomi P2P live view beats streamless HA camera");
  });

  it("supports write-through + localStorage per-card source pinning and automatic offline fallback (fallbackActive: true, 离线，临时兜底)", () => {
    const pinStore = new DeviceSourcePinStorage(localStorage);
    const canonical = new CanonicalDeviceRegistry();
    const rooms = new RoomIdentityRegistry();

    const buildSnapshots = (haOnline: boolean, miOnline: boolean) => {
      const haLamp = makeLightDevice({
        id: "ha-lamp-1",
        name: "主灯",
        roomId: "area-1",
        roomName: "客厅",
        entityId: "light.main_lamp",
        isOnline: haOnline,
      });
      const miLamp = makeLightDevice({
        id: "11223344",
        name: "主灯",
        roomId: "mi-1",
        roomName: "客厅",
        entityId: "miot:11223344:2:1",
        isOnline: miOnline,
      });
      const haSnap: SynthesizedHome = { devices: [haLamp], rooms: [], environmentReadings: [], scenes: [] };
      const miSnap: SynthesizedHome = { devices: [miLamp], rooms: [], environmentReadings: [], scenes: [] };
      return {
        ha: {
          home: haSnap,
          identities: extractHADeviceIdentities(
            {
              areas: [{ area_id: "area-1", name: "客厅" }],
              devices: [{ id: "ha-lamp-1", area_id: "area-1", name: "主灯", model: LIGHT_MODEL, identifiers: [["xiaomi_home", "11223344"]], connections: [] }],
              entities: [],
              states: [],
            },
            haSnap,
          ),
        },
        mi: {
          home: miSnap,
          identities: extractMiDeviceIdentities(
            [{ did: "11223344", name: "主灯", model: LIGHT_MODEL, specType: null, isOnline: miOnline }],
            miSnap,
          ),
        },
      };
    };

    const bothOnline = buildSnapshots(true, true);
    const m1 = DeviceDeduplicator.merge({
      homeAssistant: bothOnline.ha,
      xiaomiCloud: bothOnline.mi,
      canonical,
      rooms,
      pinnedBackends: pinStore.getAll(),
    });
    const cid = m1.home.devices[0]!.id;
    assert.equal(m1.routes[cid]?.backend, "homeAssistant");
    assert.equal(m1.routes[cid]?.fallbackActive, false);

    pinStore.pin(cid, "xiaomiCloud");
    assert.equal(DeviceSourcePinStorage.load(localStorage)[cid], "xiaomiCloud");
    assert.ok(localStorage.getItem(PINNED_DEVICE_SOURCES_STORAGE_KEY)?.includes("xiaomiCloud"));

    const m2 = DeviceDeduplicator.merge({
      homeAssistant: bothOnline.ha,
      xiaomiCloud: bothOnline.mi,
      canonical: m1.canonical,
      rooms: m1.rooms,
      pinnedBackends: pinStore.getAll(),
    });
    assert.equal(m2.routes[cid]?.backend, "xiaomiCloud");
    assert.equal(m2.routes[cid]?.pinnedBackend, "xiaomiCloud");
    assert.equal(m2.routes[cid]?.fallbackActive, false);
    assert.equal(m2.home.devices[0]?.kind.kind === "light" ? m2.home.devices[0].kind.entityId : "", "miot:11223344:2:1");

    const miOffline = buildSnapshots(true, false);
    const m3 = DeviceDeduplicator.merge({
      homeAssistant: miOffline.ha,
      xiaomiCloud: miOffline.mi,
      canonical: m2.canonical,
      rooms: m2.rooms,
      pinnedBackends: pinStore.getAll(),
      languagePreference: "zh-Hans",
    });
    const fallbackCard = m3.home.devices[0]!;
    assert.equal(m3.routes[cid]?.backend, "homeAssistant", "temporarily falls back to online HA");
    assert.equal(m3.routes[cid]?.pinnedBackend, "xiaomiCloud", "remembers user's pinned source");
    assert.equal(m3.routes[cid]?.fallbackActive, true);
    assert.equal(fallbackCard.fallbackActive, true);
    assert.equal(fallbackCard.fallbackLabel, "离线，临时兜底");
    assert.equal(offlineFallbackBadgeText("zh-Hant"), "離線，暫時兜底");
    assert.equal(offlineFallbackBadgeText("en"), "Offline, fallback");
    assert.match(currentSourceMenuTitle("homeAssistant", "xiaomiCloud", true, "zh-Hans"), /米家云端离线，临时兜底/);

    const m3OnlyHA = DeviceDeduplicator.merge({
      homeAssistant: miOffline.ha,
      xiaomiCloud: null,
      canonical: m3.canonical,
      rooms: m3.rooms,
      pinnedBackends: pinStore.getAll(),
    });
    assert.equal(m3OnlyHA.routes[cid]?.backend, "homeAssistant");
    assert.equal(m3OnlyHA.routes[cid]?.fallbackActive, true);
    assert.equal(m3OnlyHA.home.devices[0]?.fallbackActive, true);

    const m4 = DeviceDeduplicator.merge({
      homeAssistant: bothOnline.ha,
      xiaomiCloud: bothOnline.mi,
      canonical: m3.canonical,
      rooms: m3.rooms,
      pinnedBackends: pinStore.getAll(),
    });
    assert.equal(m4.routes[cid]?.backend, "xiaomiCloud");
    assert.equal(m4.routes[cid]?.fallbackActive, false);
    assert.equal(m4.home.devices[0]?.fallbackActive, false);
    assert.equal(m4.home.devices[0]?.fallbackLabel, undefined);
  });

  it("integrates DualSourceCoordinator with MenuMijiaWindowsApp refreshDevices and instant pin recomputation", async () => {
    const transport: HttpTransport = async (req: HttpRequest): Promise<HttpResponse> => {
      if (req.url.includes("miot-spec.org")) {
        return { status: 200, headers: {}, body: JSON.stringify(LIGHT_SPEC_RAW) };
      }
      const { path } = cookieHeaderAccount(req);
      const payload = req.body ? decryptMiPayload(req.body) : {};
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: "h1", name: "家", roomlist: [{ id: "r1", name: "客厅", dids: ["55667788"] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "55667788", name: "客厅灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const params = (payload["params"] as Array<{ did: string; siid: number; piid: number }>) ?? [];
        return okMi(params.map((p) => ({ ...p, code: 0, value: p.piid === 1 ? true : 60 })));
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
            name: "客厅灯 HA",
            model: LIGHT_MODEL,
            identifiers: [["xiaomi_home", "cn_55667788"]],
            connections: [],
          },
        ],
        entities: [{ entity_id: "light.living_5566", device_id: "ha-dev-5566", area_id: null, disabled_by: null, hidden_by: null }],
        states: [{ entity_id: "light.living_5566", state: "on", attributes: { friendly_name: "客厅灯 HA", brightness: 200 } }],
      } as unknown as T;
    };

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    (app as unknown as { transport: HttpTransport }).transport = transport;
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESSION_CN_PRIMARY;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-test-secret-token";
    setHostHAInvokeOverride(app, haInvoke);

    await refreshDevices(app, false);
    assert.equal(app.devices.length, 1);
    assert.equal(app.devices[0]?.kind.kind === "light" ? app.devices[0].kind.entityId : "", "miot:55667788:2");
    assert.equal(getHostDualSourceState(app), null);

    setHostDualSourceEnabled(app, true, { persist: true });
    await refreshDevices(app, false);
    assert.equal(app.devices.length, 1);
    const mergedState = getHostDualSourceState(app);
    assert.ok(mergedState);
    const cid = app.devices[0]!.id;
    assert.equal(mergedState.routes[cid]?.backend, "homeAssistant");
    assert.equal(app.devices[0]?.kind.kind === "light" ? app.devices[0].kind.entityId : "", "light.living_5566");

    setHostDeviceSourcePin(app, cid, "xiaomiCloud");
    assert.equal(app.devices[0]?.kind.kind === "light" ? app.devices[0].kind.entityId : "", "miot:55667788:2");
    assert.equal(commandTargetBackend({ kind: "setLightPower", entityId: "miot:55667788:2", isOn: false }), "xiaomiCloud");
    assert.equal(commandTargetBackend({ kind: "setLightPower", entityId: "light.living_5566", isOn: false }), "homeAssistant");
    assert.equal(homeProviderFor(app) instanceof DualSourceHomeProvider, true);

    const coord = new DualSourceCoordinator(localStorage);
    const partial = await coord.refreshParallel({
      fetchHA: async () => {
        throw new Error("HA gateway unreachable");
      },
      fetchMi: async () => ({
        home: { devices: app.devices, rooms: [], environmentReadings: [], scenes: [] },
        identities: {},
      }),
    });
    assert.equal(partial.sourceStatuses.homeAssistant.kind, "disconnected");
    assert.equal(partial.sourceStatuses.xiaomiCloud.kind, "connected");
    assert.equal(partial.merged.home.devices.length, 1);
  });
});

describe("B9: Multi-account unsupported device scanner & zero-leak Markdown diagnostics exporter (ADR-0015)", () => {
  it("scans unsupported devices across multiple Xiaomi accounts (including shared homes & paginated rooms), attaches sanitized MIoT spec summaries, and builds clean GitHub feedback URLs", async () => {
    const acc1 = makeMiAccount(SESSION_CN_PRIMARY);
    const acc2 = makeMiAccount(SESSION_SG_SECONDARY);
    const fakeLanIp = ["10", "88", "77", "66"].join(".");

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
      const payload = req.body ? decryptMiPayload(req.body) : {};

      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({
            has_more: true,
            max_id: "page2-cursor",
            homelist: [
              {
                id: "home-own-1",
                name: "机密家庭名称一号",
                roomlist: [{ id: "r-1", name: "厨房", dids: ["did-supported-lamp", "did-valve-ro"] }],
              },
            ],
            share_home_list: [
              {
                id: "home-shared-99",
                name: "父母共享秘密别墅",
                uid: 44556677,
                roomlist: [{ id: "r-shared", name: "阳台", dids: ["did-shared-mystery"] }],
              },
            ],
          });
        }
        return okMi({
          has_more: false,
          homelist: [
            {
              id: "home-sg-2",
              name: "Singapore Secret Condo",
              roomlist: [{ id: "r-sg", name: "Study", dids: ["did-shared-mystery", "did-sg-plus"] }],
            },
          ],
        });
      }

      if (path === "v2/homeroom/get_dev_room_page") {
        return okMi({
          has_more: false,
          info: [
            {
              id: "home-own-1",
              roomlist: [{ id: "r-2-paged", name: "次卧分页房间", dids: ["did-wall-parent"] }],
            },
          ],
        });
      }

      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        const requestedDids = payload["dids"] as string[] | undefined;
        if (requestedDids) {
          return okMi({
            list: requestedDids.includes("did-shared-mystery")
              ? [
                  {
                    did: "did-shared-mystery",
                    name: `神秘晾衣架 ${fakeLanIp}`,
                    model: UNKNOWN_GADGET_MODEL,
                    mac: "AA:BB:CC:11:22:33",
                    ip: fakeLanIp,
                    isOnline: true,
                  },
                ]
              : [],
          });
        }
        if (userId === SESSION_CN_PRIMARY.userId) {
          return okMi({
            list: [
              { did: "did-supported-lamp", name: "吸顶灯", model: LIGHT_MODEL, isOnline: true },
              {
                did: "did-valve-ro",
                name: "机密家庭名称一号 燃气切断阀",
                model: VALVE_READONLY_MODEL,
                spec_type: VALVE_SPEC_NO_CONTROLLABLE_RAW.type,
                mac: "DE:AD:BE:EF:00:11",
                ip: fakeLanIp,
                isOnline: true,
              },
              { did: "did-wall-parent", name: "双键开关母体", model: UNKNOWN_GADGET_MODEL, isOnline: true },
              {
                did: "did-wall-parent.s2",
                name: "左键灯",
                model: LIGHT_MODEL,
                extra: { split: { parentId: "did-wall-parent", moduleId: 2 } },
                isOnline: true,
              },
            ],
          });
        }
        return okMi({
          list: [
            {
              did: "did-sg-plus",
              name: "Gateway+Sensor",
              model: "lumi.sensor+v2",
              isOnline: true,
            },
          ],
        });
      }

      return okMi({ home_info: { dlist: [] } });
    };

    const specResolver = new MiotSpecResolver(transport, {
      [LIGHT_MODEL]: parseMiotDeviceSpec(LIGHT_SPEC_RAW)!,
    });

    const scanner = new UnsupportedDeviceScanner();
    const scanResult = await scanner.scan({
      connectionMode: "xiaomiCloud",
      miAccounts: [acc1, acc2],
      transport,
      specResolver,
      languagePreference: "zh-Hans",
    });

    assert.equal(scanResult.miHomeCount, 3);
    assert.equal(scanResult.miSharedHomeCount, 1);
    assert.deepEqual(
      scanResult.devices.map((d) => d.model).sort(),
      [UNKNOWN_GADGET_MODEL, "lumi.sensor+v2", VALVE_READONLY_MODEL].sort(),
    );

    const valve = scanResult.devices.find((d) => d.model === VALVE_READONLY_MODEL)!;
    assert.equal(valve.reason, "noControllableItems");
    assert.ok(valve.specSummary, "raw MIoT spec summary attached");
    assert.equal(valve.specSummary.deviceType, "valve");
    assert.equal(valve.specSummary.propertyCount, 1);
    assert.equal(valve.specSummary.writablePropertyCount, 0);
    assert.ok(!valve.name.includes("机密家庭名称一号"), "home name stripped from device label");

    const plusDevice = scanResult.devices.find((d) => d.model === "lumi.sensor+v2")!;
    assert.equal(plusDevice.reason, "unknownModel");
    assert.ok(plusDevice.feedbackURL?.startsWith(`${GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL}?`));
    assert.ok(plusDevice.feedbackURL?.includes("template=unsupported_device.yml"));
    assert.ok(plusDevice.feedbackURL?.includes("platform=Windows"));
    assert.ok(plusDevice.feedbackURL?.includes("lumi.sensor%2Bv2"), "`+` encoded as `%2B`");

    for (const item of scanResult.devices) {
      assert.ok(item.feedbackURL);
      assertZeroSensitiveLeaks(item.feedbackURL, { allowGitHubIssueURL: true });
      assert.ok(!item.feedbackURL.includes(item.id));
      assert.ok(!item.feedbackURL.includes(fakeLanIp));
      assert.ok(!item.feedbackURL.includes(SESSION_CN_PRIMARY.userId));
      assert.ok(!item.feedbackURL.includes("父母共享秘密别墅"));
    }

    const haRaw = {
      areas: [],
      devices: [
        { id: "ha-disabled-1", name: "Disabled Plug", model: "plug.v1", disabled_by: "user" },
        { id: "ha-dup-1", name: "Apple TV", model: "Apple TV 4K" },
        { id: "ha-unsup-1", name: "Lawn Mower", model: "gardena.mower.x1" },
      ],
      entities: [{ entity_id: "lawn_mower.yard", device_id: "ha-unsup-1", disabled_by: null, hidden_by: null }],
      states: [{ entity_id: "lawn_mower.yard", state: "docked", attributes: {} }],
    };
    const haSkipped = UnsupportedDeviceCollector.homeAssistant(
      haRaw,
      HomeAssistantSynthesizer.synthesize(haRaw),
    );
    assert.equal(haSkipped.find((d) => d.id === "ha-disabled-1")?.feedbackURL, null);
    assert.equal(haSkipped.find((d) => d.id === "ha-dup-1")?.feedbackURL, null);
    const mowerUrl = haSkipped.find((d) => d.id === "ha-unsup-1")?.feedbackURL;
    assert.ok(mowerUrl?.includes("backend=Home%20Assistant"));

    scanner.invalidateIfContextChanged({ connectionMode: "homeAssistant", haBaseURL: "https://other.local:8123" });
    assert.equal(scanner.devices.length, 0);
    assert.equal(scanner.lastScannedAtMs, null);
  });

  it("caps DiagnosticsLog ring buffer at 50 entries and exports 100% desensitized Markdown reports with zero Token or private IP leaks", async () => {
    const fakeJwt = [
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
      "eyJzdWIiOiI5OTg4Nzc2NjU1IiwibmFtZSI6IlNlY3JldCJ9",
      "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    ].join(".");
    const fakeLan10 = ["10", "10", "1", "4"].join(".");
    const fakeLan192 = ["192", "168", "31", "205"].join(".");
    const fakeLan172 = ["172", "16", "12", "9"].join(".");
    const fakeMac = "AA:BB:CC:DD:EE:99";
    const fakeHomeName = "王五的私密庄园";

    const log = new DiagnosticsLog(localStorage, DIAGNOSTICS_RING_BUFFER_CAPACITY);

    const baseTs = Date.UTC(2026, 10, 14, 8, 30, 0);
    for (let i = 1; i <= 65; i += 1) {
      log.record({
        summary: `Request #${i} to https://${fakeLan192}:8123/api failed (ip=${fakeLan10}, gw=${fakeLan172}, mac=${fakeMac}, Authorization: Bearer ${fakeJwt}, serviceToken=tok_secret_${i}, did=miot:9988776655:2:1, home=${fakeHomeName})`,
        category: i % 3 === 0 ? "rateLimit" : i % 2 === 0 ? "homeAssistant" : "miCloud",
        statusCode: i % 3 === 0 ? 429 : 502,
        timestampMs: baseTs + i * 1000,
        forbiddenLiterals: [fakeHomeName],
      });
    }

    assert.equal(log.count(), 50);
    const snapshots = log.getSnapshots();
    assert.equal(snapshots[0]?.timestampMs, baseTs + 16 * 1000);
    assert.equal(snapshots[49]?.timestampMs, baseTs + 65 * 1000);
    for (const snap of snapshots) {
      assert.deepEqual(findSensitiveLeaks(snap.summary), []);
      assert.ok(!snap.summary.includes(fakeHomeName));
    }

    const persistedRaw = localStorage.getItem(DIAGNOSTICS_RING_STORAGE_KEY) ?? "";
    assert.ok(!persistedRaw.includes("summary"));
    assert.ok(!persistedRaw.includes(fakeLan10));

    const sampleDevices: SmartDevice[] = [
      {
        id: "did-cam-1",
        name: "玄关摄像机",
        roomId: "r1",
        roomName: "玄关",
        model: CAMERA_MODEL,
        isOnline: true,
        kind: {
          kind: "camera",
          entityId: "miot:did-cam-1:2:1",
          streamEntityId: null,
          isOn: true,
          nightShot: "auto",
          availableNightShots: ["auto", "off"],
          isMotionDetectionOn: true,
          motionDetectionEntityId: "miot:did-cam-1:5:1",
          lenses: [
            { role: "main", channel: 0, label: "固定镜头" },
            { role: "secondary", channel: 1, label: "云台镜头" },
          ],
        },
      },
      {
        id: "ha-cam-2",
        name: "车库摄像机",
        roomId: "r2",
        roomName: "车库",
        model: "aqara.camera.g3",
        isOnline: true,
        kind: {
          kind: "camera",
          entityId: "camera.garage_g3",
          streamEntityId: "camera.garage_g3",
          isOn: true,
          nightShot: null,
          availableNightShots: [],
          isMotionDetectionOn: null,
          motionDetectionEntityId: null,
        },
      },
    ];

    const cameras = deriveCameraDiagnostics(sampleDevices, {
      deviceBackends: { "did-cam-1": "xiaomiCloud", "ha-cam-2": "homeAssistant" },
    });
    assert.deepEqual(cameras, [
      {
        model: CAMERA_MODEL,
        streamMode: "xiaomi_p2p_mjpeg",
        audioSupport: "none_mjpeg",
        lensCount: 2,
        isOnline: true,
      },
      {
        model: "aqara.camera.g3",
        streamMode: "ha_hls_bridge_mjpeg",
        audioSupport: "none_mjpeg",
        lensCount: 1,
        isOnline: true,
      },
    ]);

    const pollingBackoff = derivePollingBackoffDiagnostics({
      accountBackoffUntilMs: [baseTs + 42_000],
      cadenceMs: 5_000,
      nowMs: baseTs,
    });
    assert.equal(pollingBackoff.active, true);
    assert.equal(pollingBackoff.remainingSeconds, 42);

    const valveSpec = parseMiotDeviceSpec(VALVE_SPEC_NO_CONTROLLABLE_RAW)!;
    const reportZh = DiagnosticsReportBuilder.markdown({
      appVersion: "1.2.0",
      buildNumber: "120",
      osVersion: "Windows 11 24H2",
      languagePreference: "zh-Hans",
      backendTitle: `HA + 米家双源 (${fakeLan192})`,
      miCloudRegions: ["cn", "sg"],
      miAccountCount: 2,
      miHomeCount: 3,
      miSharedHomeCount: 1,
      isMiHomeFiltered: true,
      deviceCount: 12,
      onlineDeviceCount: 11,
      hiddenDeviceCount: 1,
      models: summarizeModelCounts(sampleDevices),
      unsupported: [
        {
          id: "9988776655",
          name: `${fakeHomeName} 燃气切断阀`,
          model: VALVE_READONLY_MODEL,
          reason: "noControllableItems",
          reasonText: "该设备没有向云端开放可控项",
          specSummary: summarizeMiotSpec(valveSpec),
          feedbackURL: UnsupportedDeviceFeedbackURL.make({
            id: "9988776655",
            name: "燃气切断阀",
            model: VALVE_READONLY_MODEL,
            reason: "noControllableItems",
            specSummary: summarizeMiotSpec(valveSpec),
          }),
        },
      ],
      cameras,
      pollingBackoff,
      errorSnapshots: log.getSnapshots(),
      extraSettings: [`custom_endpoint=http://${fakeLan10}:8123`, `token=${fakeJwt}`],
      forbiddenLiterals: [fakeHomeName, SESSION_CN_PRIMARY.serviceToken],
    });

    assertZeroSensitiveLeaks(reportZh);
    assert.deepEqual(findSensitiveLeaks(reportZh), []);
    for (const secret of [fakeJwt, fakeLan10, fakeLan192, fakeLan172, fakeMac, fakeHomeName, "9988776655"]) {
      assert.ok(!reportZh.includes(secret), `must never leak ${secret}`);
    }
    assert.match(reportZh, /## MenuBarHome 诊断信息/);
    assert.match(reportZh, /版本: 1\.2\.0 \(120\)/);
    assert.match(reportZh, /语言: zh-Hans/);
    assert.match(reportZh, /米家地区: cn, sg \(已登录 2 个账号\)/);
    assert.match(reportZh, /米家家庭: 3 \(共享 1\) · 已筛选单个家庭/);
    assert.match(reportZh, /限流退避中（剩余 42 秒）/);
    assert.match(reportZh, /`isa\.camera\.hlc7`: stream_mode=`xiaomi_p2p_mjpeg`, audio_support=`none_mjpeg`, lenses=2/);
    assert.match(reportZh, /`aqara\.camera\.g3`: stream_mode=`ha_hls_bridge_mjpeg`, audio_support=`none_mjpeg`/);
    assert.match(reportZh, /`aqara\.valve\.v1` — 该设备没有向云端开放可控项 · type=`valve`/);
    assert.match(reportZh, /50 次（最近一次 2026-11-14 08:31 UTC）/);

    const reportEn = DiagnosticsReportBuilder.markdown({
      appVersion: "1.2.0",
      languagePreference: "en",
      backendTitle: "Xiaomi Cloud",
      deviceCount: 2,
      onlineDeviceCount: 2,
      hiddenDeviceCount: 0,
      models: summarizeModelCounts(sampleDevices),
      cameras,
      errorSnapshots: log.getSnapshots(),
    });
    assertZeroSensitiveLeaks(reportEn);
    assert.match(reportEn, /## MenuBarHome Diagnostics/);
    assert.match(reportEn, /### Camera Diagnostics/);

    const root = document.getElementById("app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.settings.dualSourceEnabled = true;
    localStorage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify([{ slotId: "s1", accountId: "mi:cn:1", region: "cn", label: null }]));
    localStorage.setItem(DUAL_SOURCE_ENABLED_STORAGE_KEY, "1");
    localStorage.setItem(PINNED_DEVICE_SOURCES_STORAGE_KEY, '{"dev1":"xiaomiCloud"}');
    localStorage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, '{"entries":[]}');
    localStorage.setItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY, '{"entries":[]}');
    appDiagnosticsLog.record({ summary: "test-diag-entry", category: "network" });
    await clearHostSessionAndDualSourceState(app, { revokeAll: true });
    assert.equal(app.settings.dualSourceEnabled, false);
    assert.equal(localStorage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);
    assert.equal(localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY), null);
    assert.equal(localStorage.getItem(PINNED_DEVICE_SOURCES_STORAGE_KEY), null);
    assert.equal(localStorage.getItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY), null);
    assert.equal(localStorage.getItem(ROOM_IDENTITY_REGISTRY_STORAGE_KEY), null);
    assert.equal(appDiagnosticsLog.count(), 0);
  });
});
