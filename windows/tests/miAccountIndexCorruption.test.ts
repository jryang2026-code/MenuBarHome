import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { renderConnectionsAndDiagSection } from "../src/ui/connectionsAndDiagView.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import {
  MI_ACCOUNTS_INDEX_RECOVERY_STORAGE_KEY,
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
  MiAccountsStore,
  hasCorruptMiAccountIndex,
  hasPendingMiAccountIndexRecovery,
  hasPendingMiAccountSignOut,
  hasSecondaryMiAccountsInIndex,
  makeMiAccount,
  miAccountId,
  readAccountIndex,
  readAccountIndexState,
} from "../src/core/miAccountsStore.js";
import { hasMultipleMiAccountsForHost } from "../src/ui/cloudRefresh.js";
import {
  CredentialVault,
  miAccountSessionCredentialName,
  secureStoreListMiAccountSlots,
  type SecureInvoke,
} from "../src/core/secureStore.js";

const SESSION_PRIMARY: MiSession = {
  userId: "100200300",
  cUserId: "c-primary",
  ssecurity: "ssecurity-primary",
  serviceToken: "service-token-primary",
  passToken: "",
  region: "cn",
};

const SESSION_SG: MiSession = {
  userId: "550066007",
  cUserId: "c-sg",
  ssecurity: "ssecurity-sg",
  serviceToken: "service-token-sg",
  passToken: "",
  region: "sg",
};

const SESSION_FAMILY: MiSession = {
  userId: "998877665",
  cUserId: "c-family",
  ssecurity: "ssecurity-family",
  serviceToken: "service-token-family",
  passToken: "",
  region: "cn",
};

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length(): number {
      return map.size;
    },
    clear(): void {
      map.clear();
    },
    getItem(key: string): string | null {
      return map.get(key) ?? null;
    },
    key(index: number): string | null {
      return [...map.keys()][index] ?? null;
    },
    removeItem(key: string): void {
      map.delete(key);
    },
    setItem(key: string, value: string): void {
      map.set(key, `${value}`);
    },
  };
}

interface CredentialFixtureOptions {
  supportsSlotScan: boolean;
  readonly failOnGet?: ReadonlySet<string>;
  readonly phantomSlots?: readonly string[];
}

function makeCredentialFixture(options: CredentialFixtureOptions): {
  invoke: SecureInvoke;
  data: Map<string, string>;
} {
  const data = new Map<string, string>();
  const invoke: SecureInvoke = async <T>(
    cmd: string,
    args: Record<string, unknown>,
  ): Promise<T | null> => {
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") {
      if (options.failOnGet?.has(name)) throw new Error(`simulated read failure for ${name}`);
      return ((data.get(name) ?? null) as unknown) as T | null;
    }
    if (cmd === "secure_store_set") {
      data.set(name, String(args["value"] ?? ""));
      return null;
    }
    if (cmd === "secure_store_delete") {
      data.delete(name);
      return null;
    }
    if (cmd === "secure_store_list_mi_account_slots") {
      if (!options.supportsSlotScan) return null;
      const slots = [...data.keys()]
        .filter((key) => key.startsWith("mi_session_"))
        .map((key) => key.slice("mi_session_".length));
      for (const slot of options.phantomSlots ?? []) {
        if (!slots.includes(slot)) slots.push(slot);
      }
      return slots as unknown as T;
    }
    return null;
  };
  return { invoke, data };
}

async function seedStore(store: MiAccountsStore, sessions: readonly MiSession[]): Promise<void> {
  for (const session of sessions) await store.upsertAccount(session);
}

const expectedIds = (sessions: readonly MiSession[]): string[] => sessions.map((s) => miAccountId(s));

describe("Mi account index corruption (#228)", () => {
  const corruptValues: ReadonlyArray<readonly [string, string]> = [
    ["invalid JSON", '{"accounts":'],
    ["object instead of an array", JSON.stringify({ accounts: [] })],
    ["only unusable entries", JSON.stringify([{ id: 42 }, null, "row", { slotId: "" }])],
  ];

  for (const [label, corruptValue] of corruptValues) {
    it(`keeps cached secondary accounts and never rewrites the index for ${label}`, async () => {
      const storage = memoryStorage();
      const { invoke } = makeCredentialFixture({ supportsSlotScan: false });
      const store = new MiAccountsStore(new CredentialVault(invoke), storage);
      const sessions = [SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY];
      await seedStore(store, sessions);

      storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, corruptValue);
      assert.equal(readAccountIndexState(storage).status, "corrupt");
      assert.equal(hasCorruptMiAccountIndex(storage), true);

      for (let attempt = 0; attempt < 2; attempt += 1) {
        const accounts = await store.load();
        assert.deepEqual(accounts.map((account) => account.id), expectedIds(sessions));
      }
      assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), corruptValue);
      assert.equal(store.getAccountIndexRepair(), "unrecovered");
    });
  }

  it("rebuilds the index from credential slots, primary first and deduplicated", async () => {
    const storage = memoryStorage();
    const fixture = makeCredentialFixture({ supportsSlotScan: true });
    const seeded = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    const sessions = [SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY];
    await seedStore(seeded, sessions);

    const primary = makeMiAccount(SESSION_PRIMARY);
    // A stale duplicate slot for the primary, e.g. left behind by an older promotion.
    await new CredentialVault(fixture.invoke).saveMiAccountSlot(primary.slotId, SESSION_PRIMARY);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "not-json");

    const store = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    const accounts = await store.load();

    assert.equal(store.getAccountIndexRepair(), "rebuilt");
    assert.equal(accounts.length, sessions.length);
    assert.equal(accounts[0]?.id, primary.id, "primary account stays first");
    assert.equal(new Set(accounts.map((account) => account.id)).size, accounts.length);
    assert.deepEqual([...accounts.map((account) => account.id)].sort(), expectedIds(sessions).sort());

    const entries = readAccountIndex(storage);
    assert.deepEqual(entries.map((entry) => entry.id), accounts.map((account) => account.id));
    assert.equal(readAccountIndexState(storage).status, "ok");
    assert.equal(hasSecondaryMiAccountsInIndex(storage), true);
    assert.equal(
      fixture.data.has(miAccountSessionCredentialName(primary.slotId)),
      false,
      "the duplicate primary slot credential is deleted after deduplication",
    );
  });

  it("keeps a cached account whose slot read fails instead of dropping it", async () => {
    const storage = memoryStorage();
    const sgSlotName = miAccountSessionCredentialName(makeMiAccount(SESSION_SG).slotId);
    const { invoke } = makeCredentialFixture({
      supportsSlotScan: true,
      failOnGet: new Set([sgSlotName]),
    });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const sessions = [SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY];
    await seedStore(store, sessions);

    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "not-json");
    const accounts = await store.load();

    assert.deepEqual(
      accounts.map((account) => account.id).sort(),
      expectedIds(sessions).sort(),
      "the unreadable slot survives from the in-memory cache",
    );
    assert.equal(store.getAccountIndexRepair(), "unrecovered");
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), "not-json");
  });

  it("keeps recovery pending across a re-login and merges the next successful scan", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: true };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    // Cold start while enumeration is broken: only the primary credential is reachable.
    options.supportsSlotScan = false;
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const first = await store.load();
    assert.deepEqual(first.map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(store.getAccountIndexRepair(), "unrecovered");
    assert.equal(hasPendingMiAccountIndexRecovery(storage), true);

    // The user follows the warning and signs the primary back in. The rewritten index only knows
    // the accounts in this window's cache, so it must keep the recovery marker.
    await store.upsertAccount(SESSION_PRIMARY);
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(hasPendingMiAccountIndexRecovery(storage), true);

    options.supportsSlotScan = true;
    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    const recovered = await cold.load();
    assert.deepEqual(
      recovered.map((account) => account.id).sort(),
      [miAccountId(SESSION_PRIMARY), miAccountId(SESSION_SG)].sort(),
      "the cold window retries the scan and finds the secondary account",
    );
    assert.equal(hasPendingMiAccountIndexRecovery(storage), false);
    assert.deepEqual(
      readAccountIndex(storage).map((entry) => entry.id),
      recovered.map((account) => account.id),
    );
  });

  it("keeps a cached account whose enumerated slot reads as null", async () => {
    const storage = memoryStorage();
    const sg = makeMiAccount(SESSION_SG);
    const { invoke, data } = makeCredentialFixture({
      supportsSlotScan: true,
      phantomSlots: [sg.slotId],
    });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
    data.delete(miAccountSessionCredentialName(sg.slotId));
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "not-json");

    const accounts = await store.load();
    assert.deepEqual(
      accounts.map((account) => account.id).sort(),
      [miAccountId(SESSION_PRIMARY), sg.id].sort(),
    );
    assert.equal(store.getAccountIndexRepair(), "unrecovered");
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), "not-json");
  });

  it("keeps a cached account whose enumerated slot holds unparseable content", async () => {
    const storage = memoryStorage();
    const sg = makeMiAccount(SESSION_SG);
    const { invoke, data } = makeCredentialFixture({ supportsSlotScan: true });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
    data.set(miAccountSessionCredentialName(sg.slotId), "{not-a-session");
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "not-json");

    const accounts = await store.load();
    assert.deepEqual(
      accounts.map((account) => account.id).sort(),
      [miAccountId(SESSION_PRIMARY), sg.id].sort(),
    );
    assert.equal(store.getAccountIndexRepair(), "unrecovered");
  });

  it("removes every slot of a signed-out account so it cannot resurrect after recovery", async () => {
    const storage = memoryStorage();
    const { invoke, data } = makeCredentialFixture({ supportsSlotScan: true });
    const vault = new CredentialVault(invoke);
    const store = new MiAccountsStore(vault, storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
    const primary = makeMiAccount(SESSION_PRIMARY);
    // Leftover duplicate slot from an earlier failed cleanup.
    await vault.saveMiAccountSlot(primary.slotId, SESSION_PRIMARY);

    const removal = await store.removeAccount(primary.id);
    assert.deepEqual(removal.accounts.map((account) => account.id), [miAccountId(SESSION_SG)]);
    assert.equal(data.has(miAccountSessionCredentialName(primary.slotId)), false);

    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");
    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    const recovered = await cold.load();
    assert.deepEqual(recovered.map((account) => account.id), [miAccountId(SESSION_SG)]);
    assert.equal(recovered.some((account) => account.id === primary.id), false);
  });

  it("does not wipe hidden secondary credentials when the visible primary is removed", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: false };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const cold = await store.load();
    assert.deepEqual(cold.map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);

    // Enumeration recovers before the user removes the visible primary.
    options.supportsSlotScan = true;
    const removal = await store.removeAccount(miAccountId(SESSION_PRIMARY));
    assert.deepEqual(
      removal.accounts.map((account) => account.id),
      [miAccountId(SESSION_SG)],
      "the hidden secondary is discovered before deciding this is the last account",
    );
    assert.equal(removal.primarySession?.userId, SESSION_SG.userId);
    assert.equal(
      (await new CredentialVault(invoke).loadPrimaryMiSession())?.userId,
      SESSION_SG.userId,
      "the secondary credential is promoted, not deleted",
    );
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), [miAccountId(SESSION_SG)]);
    assert.equal(hasPendingMiAccountIndexRecovery(storage), false);
  });

  it("aborts sign-out when slot enumeration fails instead of leaving orphan credentials", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: false });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);

    await assert.rejects(
      () => store.removeAccount(miAccountId(SESSION_PRIMARY)),
      /无法枚举小米账号凭据/,
    );
    assert.deepEqual(store.getAccounts().map((account) => account.id), expectedIds([SESSION_PRIMARY, SESSION_SG]));
    assert.equal(readAccountIndex(storage).length, 2);
  });

  it("clears the recovery state and warning after a full sign-out", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: false };
    const { invoke } = makeCredentialFixture(options);
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");
    await store.load();
    assert.equal(store.getAccountIndexRepair(), "unrecovered");
    assert.equal(hasPendingMiAccountIndexRecovery(storage), true);

    options.supportsSlotScan = true;
    await store.clearAll();
    assert.equal(store.getAccountIndexRepair(), "none");
    assert.equal(hasPendingMiAccountIndexRecovery(storage), false);
    assert.equal(hasPendingMiAccountSignOut(storage), false);
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);
  });

  it("keeps a failed full sign-out pending and wipes hidden slots before recovery", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: false };
    const { invoke, data } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    const sgSlotName = miAccountSessionCredentialName(makeMiAccount(SESSION_SG).slotId);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await store.load();
    await assert.rejects(() => store.clearAll(), /无法枚举小米账号凭据/);
    assert.equal(hasPendingMiAccountSignOut(storage), true);
    assert.ok(data.has(sgSlotName), "a failed scan must not delete a partial set");

    options.supportsSlotScan = true;
    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual(await cold.load(), [], "the retried sign-out reports no accounts");
    assert.equal(hasPendingMiAccountSignOut(storage), false);
    assert.equal(data.has("mi_session"), false);
    assert.equal(data.has(sgSlotName), false);
    assert.deepEqual(await cold.load(), [], "the signed-out secondary never resurrects");
  });

  it("leaves a fresh install untouched and reports no repair", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: true });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);

    assert.deepEqual(await store.load(), []);
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);
    assert.equal(store.getAccountIndexRepair(), "none");
    assert.equal(readAccountIndexState(storage).status, "missing");
  });

  it("keeps a readable index unchanged and never enters the repair path", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: false });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const sessions = [SESSION_PRIMARY, SESSION_SG];
    await seedStore(store, sessions);
    const before = storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);

    const accounts = await store.load();
    assert.deepEqual(accounts.map((account) => account.id), expectedIds(sessions));
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), before);
    assert.equal(store.getAccountIndexRepair(), "none");
  });

  it("keeps valid entries of a partially damaged index and only flags a fully unusable one", () => {
    const storage = memoryStorage();
    const sg = makeMiAccount(SESSION_SG);
    storage.setItem(
      MI_ACCOUNTS_INDEX_STORAGE_KEY,
      JSON.stringify([
        { id: sg.id, slotId: sg.slotId, region: "sg", maskedUserId: sg.maskedUserId },
        { id: 7 },
        null,
      ]),
    );
    assert.equal(readAccountIndexState(storage).status, "ok");
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), [sg.id]);

    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "[]");
    assert.equal(readAccountIndexState(storage).status, "ok");
    assert.deepEqual(readAccountIndex(storage), []);
  });

  it("hydrates a partially damaged index whose only valid entry is a secondary account", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: false });
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);

    const sg = makeMiAccount(SESSION_SG);
    storage.setItem(
      MI_ACCOUNTS_INDEX_STORAGE_KEY,
      JSON.stringify([
        { id: 42 },
        { id: sg.id, slotId: sg.slotId, region: sg.region, maskedUserId: sg.maskedUserId },
      ]),
    );
    assert.equal(readAccountIndexState(storage).status, "ok");
    assert.equal(
      hasSecondaryMiAccountsInIndex(storage),
      true,
      "the raw length still triggers hydration after partial damage",
    );

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await store.load();
    assert.deepEqual(accounts.map((account) => account.id), [miAccountId(SESSION_PRIMARY), sg.id]);
    assert.equal(readAccountIndex(storage).length, 2);
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY)?.includes('"id":42'), false);
  });

  it("treats a missing enumeration command as unknown and normalizes scanned slot ids", async () => {
    assert.equal(await secureStoreListMiAccountSlots(async () => null), null);
    assert.equal(
      await secureStoreListMiAccountSlots(async () => {
        throw new Error("no such command");
      }),
      null,
    );
    const slots = await secureStoreListMiAccountSlots(
      async <T>(_cmd: string, _args: Record<string, unknown>): Promise<T | null> =>
        (["mi_cn_ab", "mi:sg:cd", "", 7, "mi_cn_ab"] as unknown) as T,
    );
    assert.deepEqual(slots, ["mi_cn_ab", "sg_cd"]);
  });

  it("renders a non-silent warning when a corrupt index could not be rebuilt", async () => {
    const dom: Window = mountTestWindow({ stubInterval: true });
    try {
      setLanguage("en");
      const options: CredentialFixtureOptions = { supportsSlotScan: false };
      const { invoke } = makeCredentialFixture(options);
      const store = new MiAccountsStore(new CredentialVault(invoke), localStorage);
      await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
      localStorage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");
      await store.load();
      assert.equal(store.getAccountIndexRepair(), "unrecovered");

      const app = new MenuMijiaWindowsApp(document.getElementById("app")!);
      Object.assign(app, { miAccountsStore: store });
      // App construction applies the saved interface language; pin English for the copy assertion.
      setLanguage("en");
      const html = renderConnectionsAndDiagSection({
        settings: app.settings,
        devices: app.devices,
        escapeHtml: (value: string) => app.escapeHtml(value),
        host: app,
      });
      assert.ok(html.includes("data-mi-accounts-index-warning"));
      assert.ok(
        html.includes("The Xiaomi account index is corrupted"),
        "English catalog text is rendered, so the warning is never silent",
      );

      const refreshHost = { settings: {} };
      assert.equal(hasMultipleMiAccountsForHost(refreshHost), true, "a corrupt index forces a store load");
      localStorage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify([{ id: miAccountId(SESSION_PRIMARY) }]));
      localStorage.setItem(MI_ACCOUNTS_INDEX_RECOVERY_STORAGE_KEY, "1");
      assert.equal(
        hasMultipleMiAccountsForHost(refreshHost),
        true,
        "a pending recovery keeps the multi-account refresh path",
      );

      options.supportsSlotScan = true;
      await store.clearAll();
      const clearedHtml = renderConnectionsAndDiagSection({
        settings: app.settings,
        devices: app.devices,
        escapeHtml: (value: string) => app.escapeHtml(value),
        host: app,
      });
      assert.equal(clearedHtml.includes("data-mi-accounts-index-warning"), false);
    } finally {
      await closeTestWindow(dom);
    }
  });
});
