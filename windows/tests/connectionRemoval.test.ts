import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { retryConnectionRemovalOnHost } from "../src/ui/connectionsAndDiagView.js";
import { refreshDevices, getHostMiAccountsStore } from "../src/ui/cloudRefresh.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  CONNECTION_REMOVAL_STORAGE_KEY,
  beginConnectionRemoval,
  clearConnectionRemovals,
  completeConnectionRemoval,
  connectionRemovalCredentialNames,
  executeConnectionRemoval,
  findConnectionRemoval,
  haConnectionRemovalScope,
  miConnectionRemovalScope,
  markConnectionRemovalStage,
  readConnectionRemovalState,
  type ConnectionRemovalVaultPort,
} from "../src/core/connectionRemoval.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  filterEnabledMiAccounts,
  miAccountScope,
  resolveMiAccountSelectionState,
} from "../src/core/miAccountControl.js";
import { CredentialVault, type SecureInvoke } from "../src/core/secureStore.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import type { HttpTransport, MiSession } from "../src/core/miCloudClient.js";
import {
  acquireHaTransportLease,
  beginHaScopeDisable,
  resetHaTransportGateForTests,
  setHaStopDrainTimeoutMsForTests,
  waitForHaScopeDrained,
} from "../src/core/haTransportGate.js";

const SEC = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SESS_A: MiSession = { userId: "10001", cUserId: "c1", ssecurity: SEC, serviceToken: "tok-a", passToken: "", region: "cn" };
const SESS_B: MiSession = { userId: "20002", cUserId: "c2", ssecurity: SEC, serviceToken: "tok-b", passToken: "", region: "sg" };
const ACC_A = makeMiAccount(SESS_A).id;
const ACC_B = makeMiAccount(SESS_B).id;
const SLOT_B = `mi_session_${makeMiAccount(SESS_B).slotId}`;
const HA_URL = "https://ha.connection-removal.test:8123";
const HA_SCOPE = haConnectionRemovalScope(HA_URL)!;

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (key: string) => map.get(key) ?? null,
    key: (index: number) => [...map.keys()][index] ?? null,
    removeItem: (key: string) => void map.delete(key),
    setItem: (key: string, value: string) => void map.set(key, `${value}`),
  };
}

function makePort(overrides: Partial<ConnectionRemovalVaultPort> = {}): {
  port: ConnectionRemovalVaultPort;
  data: Map<string, string>;
  deleted: string[];
} {
  const data = new Map<string, string>();
  const deleted: string[] = [];
  const port: ConnectionRemovalVaultPort = {
    deleteCredentialSlots: async (names) => {
      for (const name of names) {
        if (name === "mi_session_boom") throw new Error("simulated delete failure");
        data.delete(name);
        deleted.push(name);
      }
    },
    readPrimarySession: async () => null,
    didLastPrimarySessionReadFail: () => false,
    ...overrides,
  };
  return { port, data, deleted };
}

function makeSecure(): {
  invoke: SecureInvoke;
  data: Map<string, string>;
  calls: Array<{ cmd: string; args: Record<string, unknown> }>;
  failOnDelete: Set<string>;
} {
  const data = new Map<string, string>();
  const failOnDelete = new Set<string>();
  const calls: Array<{ cmd: string; args: Record<string, unknown> }> = [];
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T | null> => {
    calls.push({ cmd, args });
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") return ((data.get(name) ?? null) as unknown) as T;
    if (cmd === "secure_store_set") {
      data.set(name, String(args["value"] ?? ""));
      return null;
    }
    if (cmd === "secure_store_delete") {
      if (failOnDelete.has(name)) throw new Error(`simulated delete failure for ${name}`);
      data.delete(name);
      return null;
    }
    if (cmd === "secure_store_list_mi_account_slots") {
      return [...data.keys()].filter((key) => key.startsWith("mi_session_")).map((key) => key.slice(11)) as unknown as T;
    }
    return null;
  };
  return { invoke, data, calls, failOnDelete };
}

const okMi = (result: unknown) => ({ status: 200, headers: {}, body: JSON.stringify({ code: 0, message: "ok", result }) });
const reqUser = (req: { headers?: Record<string, string> }) =>
  /userId=([^;\s]+)/.exec(req.headers?.["Cookie"] ?? req.headers?.["cookie"] ?? "")?.[1] ?? "";

function mountApp(secure: ReturnType<typeof makeSecure>, transport: HttpTransport): MenuMijiaWindowsApp {
  (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = { invoke: secure.invoke };
  const app = new MenuMijiaWindowsApp(document.getElementById("app")!);
  (app as unknown as { transport: HttpTransport }).transport = transport;
  (app as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secure.invoke);
  app.miAccountsStore = null;
  app.settings.hasCompletedOnboarding = true;
  app.activeSheet = "none";
  app.timerCredentialsReady = true;
  return app;
}

let dom: Window | null = null;
let removeCssEscape: (() => void) | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  removeCssEscape = installCssEscape();
  setLanguage("zh-Hans");
});

afterEach(async () => {
  resetHaTransportGateForTests();
  clearConnectionRemovals();
  localStorage.clear();
  removeCssEscape?.();
  if (dom) await closeTestWindow(dom);
  dom = null;
});

describe("P2c-W retryable connection removal records", () => {
  it("persists the intent before deletion, bumps the owner version on retry, and refuses stale completions", () => {
    const storage = memoryStorage();
    const first = beginConnectionRemoval(
      { kind: "mi", scope: miConnectionRemovalScope(ACC_A), accountId: ACC_A, slotIds: [makeMiAccount(SESS_A).slotId] },
      storage,
    );
    assert.ok(first);
    assert.equal(first.attempts, 1);
    assert.equal(readConnectionRemovalState(storage).records.length, 1);

    const retried = beginConnectionRemoval({ kind: "mi", scope: first.scope, stage: "cleaning" }, storage);
    assert.ok(retried);
    assert.equal(retried.attempts, 2);
    assert.ok(retried.ownerVersion > first.ownerVersion, "a retry must take the record over");
    assert.equal(retried.createdAt, first.createdAt, "retrying keeps the original intent time");
    assert.equal(completeConnectionRemoval(first.scope, first.ownerVersion, storage), false);
    assert.equal(readConnectionRemovalState(storage).records.length, 1, "an older intent must not clear a newer record");
    assert.equal(completeConnectionRemoval(retried.scope, retried.ownerVersion, storage), true);
    assert.equal(readConnectionRemovalState(storage).records.length, 0);
    assert.equal(storage.getItem(CONNECTION_REMOVAL_STORAGE_KEY), null);
  });

  it("keeps unknown fields, ignores inconsistent entries, and quarantines an unreadable payload", () => {
    const storage = memoryStorage();
    storage.setItem(
      CONNECTION_REMOVAL_STORAGE_KEY,
      JSON.stringify({
        schemaVersion: 1,
        ownerVersion: 4,
        futureTopLevel: { keep: true },
        removals: [
          { scope: HA_SCOPE, kind: "ha", ownerVersion: 4, attempts: 1, stage: "failed", futureField: "keep-me" },
          { scope: "mi:other", kind: "ha", ownerVersion: 4 },
          { scope: HA_SCOPE, kind: "mi", ownerVersion: 4 },
        ],
      }),
    );
    const state = readConnectionRemovalState(storage);
    assert.equal(state.records.length, 1);
    assert.equal(state.records[0]!.extra["futureField"], "keep-me");

    beginConnectionRemoval({ kind: "ha", scope: HA_SCOPE, stage: "draining" }, storage);
    const saved = JSON.parse(storage.getItem(CONNECTION_REMOVAL_STORAGE_KEY)!) as Record<string, unknown>;
    assert.deepEqual(saved["futureTopLevel"], { keep: true });
    assert.equal((saved["removals"] as Array<Record<string, unknown>>)[0]!["futureField"], "keep-me");

    storage.setItem(CONNECTION_REMOVAL_STORAGE_KEY, "{not-json");
    const corrupt = readConnectionRemovalState(storage);
    assert.equal(corrupt.readError, true);
    assert.equal(corrupt.records.length, 0);
    clearConnectionRemovals(storage);
    assert.equal(storage.getItem(CONNECTION_REMOVAL_STORAGE_KEY), null);
    assert.equal(storage.getItem(`${CONNECTION_REMOVAL_STORAGE_KEY}.unreadable`), "{not-json");
  });

  it("keeps a pending scope out of the enabled set for both data sources until the removal completes", () => {
    const accounts = [makeMiAccount(SESS_A), makeMiAccount(SESS_B)];
    const enabledBefore = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(enabledBefore.disabledAccountIds.size, 0);

    beginConnectionRemoval({ kind: "mi", scope: miConnectionRemovalScope(ACC_B) });
    beginConnectionRemoval({ kind: "ha", scope: HA_SCOPE });
    const whilePending = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts,
      haBaseURL: HA_URL,
      haToken: "ha-token",
      connectionMode: "homeAssistant",
      hasExistingPreferences: true,
    });
    assert.equal(whilePending.disabledAccountIds.has(miAccountScope(ACC_B)), true);
    assert.equal(whilePending.disabledHaScopes.has(HA_SCOPE), true);
    assert.deepEqual(
      filterEnabledMiAccounts(accounts, whilePending).map((account) => account.id),
      [ACC_A],
      "only the account whose removal is unfinished drops out of the enabled set",
    );

    const miRecord = findConnectionRemoval(miConnectionRemovalScope(ACC_B))!;
    completeConnectionRemoval(miRecord.scope, miRecord.ownerVersion);
    clearConnectionRemovals();
    const after = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(after.disabledAccountIds.size, 0);
    assert.equal(after.disabledHaScopes.size, 0);
  });

  it("deletes only the removed account's slots and never the other account, the HA token or an assistant key", async () => {
    const record = beginConnectionRemoval({
      kind: "mi",
      scope: miConnectionRemovalScope(ACC_B),
      accountId: ACC_B,
      slotIds: [makeMiAccount(SESS_B).slotId],
    })!;
    assert.deepEqual(connectionRemovalCredentialNames(record), [SLOT_B]);
    assert.deepEqual(connectionRemovalCredentialNames({ ...record, ownsPrimarySlot: true }), ["mi_session", SLOT_B]);

    const storage = memoryStorage();
    const { port, data, deleted } = makePort();
    for (const name of ["mi_session", SLOT_B, `mi_session_${makeMiAccount(SESS_A).slotId}`, "ha_token", "assistant_api_key_openrouter_jev"]) {
      data.set(name, "secret");
    }
    const recordWithStorage = beginConnectionRemoval(
      { kind: "mi", scope: miConnectionRemovalScope(ACC_B), accountId: ACC_B, slotIds: [makeMiAccount(SESS_B).slotId] },
      storage,
    )!;
    const outcome = await executeConnectionRemoval(recordWithStorage, port, storage);
    assert.deepEqual(outcome, { status: "completed" });
    assert.deepEqual(deleted, [SLOT_B]);
    assert.equal(data.has(SLOT_B), false);
    assert.equal(data.has(`mi_session_${makeMiAccount(SESS_A).slotId}`), true, "another account's slot must survive");
    assert.equal(data.has("ha_token"), true, "the other data source must survive");
    assert.equal(data.has("assistant_api_key_openrouter_jev"), true, "an assistant key must survive");
    assert.equal(findConnectionRemoval(recordWithStorage.scope, storage), null);

    const haStorage = memoryStorage();
    const haRecord = beginConnectionRemoval({ kind: "ha", scope: HA_SCOPE }, haStorage)!;
    const haPort = makePort();
    haPort.data.set("ha_token", "secret");
    haPort.data.set("mi_session", "secret");
    assert.equal((await executeConnectionRemoval(haRecord, haPort.port, haStorage)).status, "completed");
    assert.deepEqual(haPort.deleted, ["ha_token"]);
    assert.equal(haPort.data.has("mi_session"), true);
  });

  it("keeps the record failed when a slot cannot be deleted and completes on retry", async () => {
    const storage = memoryStorage();
    const slotId = makeMiAccount(SESS_B).slotId;
    const failing = makePort({
      deleteCredentialSlots: async () => {
        throw new Error("credential manager is locked");
      },
    });
    const record = beginConnectionRemoval(
      { kind: "mi", scope: miConnectionRemovalScope(ACC_B), accountId: ACC_B, slotIds: [slotId] },
      storage,
    )!;
    const failed = await executeConnectionRemoval(record, failing.port, storage);
    assert.equal(failed.status, "incomplete");
    assert.match(failed.status === "incomplete" ? failed.reason : "", /locked/);
    const pending = findConnectionRemoval(record.scope, storage);
    assert.equal(pending?.stage, "failed");
    assert.match(pending?.lastError ?? "", /locked/);

    const recovered = makePort();
    recovered.data.set(SLOT_B, "secret");
    const retried = beginConnectionRemoval({ kind: "mi", scope: record.scope }, storage)!;
    assert.equal(retried.attempts, 2);
    assert.equal((await executeConnectionRemoval(retried, recovered.port, storage)).status, "completed");
    assert.equal(recovered.data.has(SLOT_B), false);
    assert.equal(findConnectionRemoval(record.scope, storage), null);
  });

  it("reports an incomplete removal when the record cannot be cleared, and finishes a superseded intent", async () => {
    const base = memoryStorage();
    const lockable = memoryStorage();
    const locked: Storage = {
      ...lockable,
      removeItem: () => {
        throw new Error("storage is locked");
      },
    };
    const record = beginConnectionRemoval(
      { kind: "ha", scope: HA_SCOPE, stage: "cleaning" },
      base,
    )!;
    const port = makePort();
    // Its own document, so clearing it is the only write that can fail.
    const lockedRecord = beginConnectionRemoval({ kind: "ha", scope: `${HA_SCOPE}/locked` }, locked)!;
    const stuck = await executeConnectionRemoval(lockedRecord, port.port, locked);
    assert.equal(stuck.status, "incomplete");
    assert.equal(stuck.status === "incomplete" ? stuck.reason : "", "removal_record_not_cleared");
    assert.ok(findConnectionRemoval(lockedRecord.scope, locked), "the record must stay for a retry");

    // A newer intent owns the record, so the older cleanup reports success without clearing it.
    const supersededPort = makePort();
    const old = beginConnectionRemoval({ kind: "ha", scope: record.scope }, base)!;
    beginConnectionRemoval({ kind: "ha", scope: record.scope }, base);
    assert.deepEqual(await executeConnectionRemoval(old, supersededPort.port, base), { status: "completed" });
    assert.ok(findConnectionRemoval(record.scope, base), "the newer intent keeps its record");
  });

  it("never deletes a primary credential another account was promoted into, and fails closed when it is unreadable", async () => {
    const storage = memoryStorage();
    const rebound = beginConnectionRemoval(
      { kind: "mi", scope: miConnectionRemovalScope(ACC_B), accountId: ACC_B, slotIds: [makeMiAccount(SESS_B).slotId], ownsPrimarySlot: true },
      storage,
    )!;
    const promoted = makePort({
      readPrimarySession: async () => ({ userId: SESS_A.userId, region: SESS_A.region }),
    });
    promoted.data.set("mi_session", "promoted-secret");
    promoted.data.set(SLOT_B, "secret");
    assert.equal((await executeConnectionRemoval(rebound, promoted.port, storage)).status, "completed");
    assert.deepEqual(promoted.deleted, [SLOT_B], "the promoted account's mi_session must not be deleted");
    assert.equal(promoted.data.has("mi_session"), true);

    const unreadable = beginConnectionRemoval(
      { kind: "mi", scope: miConnectionRemovalScope(ACC_A), accountId: ACC_A, slotIds: [makeMiAccount(SESS_A).slotId], ownsPrimarySlot: true },
      storage,
    )!;
    const blind = makePort({ didLastPrimarySessionReadFail: () => true });
    blind.data.set("mi_session", "secret");
    const outcome = await executeConnectionRemoval(unreadable, blind.port, storage);
    assert.equal(outcome.status, "incomplete");
    assert.equal(outcome.status === "incomplete" ? outcome.reason : "", "primary_session_unreadable");
    assert.deepEqual(blind.deleted, [], "an unknown primary owner must block every delete");
    assert.equal(findConnectionRemoval(unreadable.scope, storage)?.stage, "failed");
    markConnectionRemovalStage(unreadable.scope, unreadable.ownerVersion, "cleaning");
  });
});

describe("P2c-W host removal: retryable cleanup and no restart of a removed connection", () => {
  it("keeps a failed Xiaomi removal retryable, makes zero requests for it after a restart, and clears it on retry", async () => {
    const secure = makeSecure();
    const requests: Array<{ user: string; path: string }> = [];
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req);
      const path = new URL(req.url).pathname.replace(/^\/(?:app\/)?/, "");
      requests.push({ user, path });
      if (path === "v2/homeroom/gethome_merged") {
        const hid = user === "10001" ? "9101" : "9202";
        return okMi({ homelist: [{ id: hid, name: `Home-${user}`, roomlist: [{ id: `r-${hid}`, name: "客厅", dids: [hid] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: user === "10001" ? "101" : "202", name: `灯-${user}`, model: "yeelink.light.lamp4", isOnline: true }] });
      }
      return okMi({});
    };

    const app = mountApp(secure, transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    assert.equal(requests.some((entry) => entry.user === SESS_B.userId), true, "both accounts sync before removal");

    const slotB = makeMiAccount(SESS_B).slotId;
    secure.data.set(`mi_session_${slotB}`, JSON.stringify(SESS_B));
    secure.data.set("mi_session", JSON.stringify(SESS_A));
    secure.data.set("ha_token", "ha-token");
    secure.data.set("assistant_api_key_openrouter_jev", "sk-keep");
    secure.failOnDelete.add(`mi_session_${slotB}`);

    app.openSettingsSheet("connection");
    const removeBBtn = document.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${ACC_B}"]`);
    assert.ok(removeBBtn, "expected the account removal entry");
    removeBBtn.click();
    for (let i = 0; i < 40 && (app.connDiagSession?.signingOutAccountIds.size ?? 0) > 0; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    assert.match(app.replyBanner?.text ?? "", /未完成移除 · 重试/);
    assert.equal(secure.data.has(`mi_session_${slotB}`), true, "the rejected credential is still real");
    assert.equal(secure.data.has("ha_token"), true, "the other data source must survive");
    assert.equal(secure.data.has("assistant_api_key_openrouter_jev"), true, "assistant keys must survive");
    assert.ok(findConnectionRemoval(miConnectionRemovalScope(ACC_B)), "the removal record must persist for a retry");

    // Restart: the untouched slot is still in the credential store, so only the record can keep the
    // removed account from reconnecting.
    requests.length = 0;
    const bootRoot = document.createElement("div");
    document.body.appendChild(bootRoot);
    const coldApp = new MenuMijiaWindowsApp(bootRoot);
    try {
      (coldApp as unknown as { transport: HttpTransport }).transport = transport;
      (coldApp as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secure.invoke);
      coldApp.miAccountsStore = null;
      await new Promise((resolve) => setTimeout(resolve, 0));
      await coldApp.refreshDevices(false);
      assert.deepEqual(
        requests.filter((entry) => entry.user === SESS_B.userId),
        [],
        "a restart must not reconnect the account whose removal is unfinished",
      );
      assert.equal(coldApp.settings.miSession === null || coldApp.settings.miSession.userId === SESS_A.userId, true);

      // The interrupted removal is visible in Settings with an actionable retry (P2c-W).
      coldApp.openSettingsSheet("connection");
      const retryBtn = coldApp.root.querySelector<HTMLButtonElement>("[data-connection-removal-retry]");
      assert.ok(retryBtn, "expected a retry control for the unfinished removal");

      // Retry finishes the cleanup, and the removed account never comes back.
      secure.failOnDelete.delete(`mi_session_${slotB}`);
      retryBtn.click();
      for (let i = 0; i < 40 && findConnectionRemoval(miConnectionRemovalScope(ACC_B)) !== null; i += 1) {
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
      assert.equal(findConnectionRemoval(miConnectionRemovalScope(ACC_B)), null);
      assert.equal(secure.data.has(`mi_session_${slotB}`), false);
      assert.equal(findConnectionRemoval(miConnectionRemovalScope(ACC_B)), null);
      requests.length = 0;
      await coldApp.refreshDevices(false);
      assert.deepEqual(requests.filter((entry) => entry.user === SESS_B.userId), []);
    } finally {
      coldApp.dispose();
      bootRoot.remove();
    }
  });

  it("keeps a failed Home Assistant removal retryable and never resubmits the removed endpoint after a restart", async () => {
    const secure = makeSecure();
    const calls: Array<{ cmd: string; args: Record<string, unknown> }> = [];
    const invoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T | null> => {
      calls.push({ cmd, args });
      return secure.invoke<T>(cmd, args);
    };
    (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = { invoke };
    const transport: HttpTransport = async () => okMi({});
    const app = mountApp(secure, transport);
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-token";
    app.settings.cachedHAHome = null;
    secure.data.set("ha_token", "ha-token");
    secure.data.set("mi_session", JSON.stringify(SESS_A));
    secure.failOnDelete.add("ha_token");

    const removed = await (await import("../src/ui/connectionsAndDiagView.js")).disconnectHomeAssistantOnHost(app);
    assert.equal(removed, false);
    assert.match(app.replyBanner?.text ?? "", /未完成移除 · 重试/);
    assert.equal(app.settings.haToken, "", "the removed connection must not stay usable in settings");
    assert.equal(secure.data.get("ha_token"), "ha-token", "the rejected token is still real");
    assert.ok(findConnectionRemoval(HA_SCOPE));
    assert.equal(JSON.parse(secure.data.get("mi_session") ?? "{}")["userId"], SESS_A.userId, "the Xiaomi credential must survive");

    calls.length = 0;
    const bootRoot = document.createElement("div");
    document.body.appendChild(bootRoot);
    const coldApp = new MenuMijiaWindowsApp(bootRoot);
    try {
      (coldApp as unknown as { transport: HttpTransport }).transport = transport;
      (coldApp as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secure.invoke);
      coldApp.miAccountsStore = null;
      await new Promise((resolve) => setTimeout(resolve, 0));
      await coldApp.refreshHADevices(false);
      assert.equal(calls.some((call) => call.cmd === "ha_snapshot"), false, "the removed HA scope must not be read after a restart");
      for (const call of calls.filter((entry) => entry.cmd === "set_service_endpoints")) {
        assert.equal(String(call.args["haUrl"] ?? ""), "", "the removed HA endpoint must not be resubmitted");
      }
      assert.equal(coldApp.settings.haToken, "", "a restart must not adopt the credential of an unfinished removal");

      secure.failOnDelete.delete("ha_token");
      assert.equal(await retryConnectionRemovalOnHost(coldApp, HA_SCOPE), true);
      assert.equal(secure.data.has("ha_token"), false);
      assert.equal(findConnectionRemoval(HA_SCOPE), null);
    } finally {
      coldApp.dispose();
      bootRoot.remove();
    }
  });

  it("waits for an in-flight Home Assistant transport before the token is deleted, and reports a stop timeout", async () => {
    const lease = acquireHaTransportLease(HA_URL, { token: "ha-token" });
    assert.ok(lease);
    beginHaScopeDisable(HA_URL);
    setHaStopDrainTimeoutMsForTests(10);
    const timedOut = await waitForHaScopeDrained(HA_URL);
    assert.deepEqual(timedOut, { drained: false, timedOut: true }, "a hung stop must not be mistaken for a drained one");
    lease.release();
    assert.deepEqual(await waitForHaScopeDrained(HA_URL), { drained: true, timedOut: false });
    setHaStopDrainTimeoutMsForTests(null);
  });

  it("refuses to rebind a Home Assistant scope whose removal is still unfinished", async () => {
    beginConnectionRemoval({ kind: "ha", scope: HA_SCOPE, stage: "failed" });
    const app = mountApp(makeSecure(), async () => okMi({}));
    app.openSettingsSheet("connection");
    const url = document.querySelector<HTMLInputElement>("#settings-ha-url");
    const token = document.querySelector<HTMLInputElement>("#settings-ha-token");
    const save = document.querySelector<HTMLButtonElement>("#btn-save-settings");
    assert.ok(url && token && save, "expected the Home Assistant connection form");
    url.value = HA_URL;
    url.dispatchEvent(new window.Event("input", { bubbles: true }));
    token.value = "fresh-token";
    token.dispatchEvent(new window.Event("input", { bubbles: true }));
    save.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.match(app.replyBanner?.text ?? "", /还没移除完/);
    assert.equal(app.settings.haToken, "", "a refused rebind must not store the new token");

    // Home Assistant has one credential slot, so a *different* endpoint must be refused as well:
    // the pending removal owns that shared slot until it finishes.
    url.value = "https://other-ha.connection-removal.test:8123";
    url.dispatchEvent(new window.Event("input", { bubbles: true }));
    token.value = "other-token";
    token.dispatchEvent(new window.Event("input", { bubbles: true }));
    save.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.match(app.replyBanner?.text ?? "", /Home Assistant 连接还没移除完/);
    assert.equal(app.settings.haBaseURL, "", "a refused endpoint change must not be stored");
    assert.equal(findConnectionRemoval(HA_SCOPE)?.stage, "failed", "the retry record stays authoritative");
    app.dispose();
  });

  it("drops stale removal records when the user signs out of everything", () => {
    beginConnectionRemoval({ kind: "mi", scope: miConnectionRemovalScope(ACC_A) });
    beginConnectionRemoval({ kind: "ha", scope: HA_SCOPE });
    assert.equal(readConnectionRemovalState().records.length, 2);
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify({ schemaVersion: 1, migrationComplete: true }));
    clearConnectionRemovals();
    assert.equal(readConnectionRemovalState().records.length, 0);
    assert.equal(
      resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true })
        .disabledAccountIds.size,
      0,
      "a finished wipe must not leave any scope disabled by an old removal",
    );
  });
});
