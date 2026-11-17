import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { renderConnectionsAndDiagSection } from "../src/ui/connectionsAndDiagView.js";
import { hasMultipleMiAccountsForHost } from "../src/ui/cloudRefresh.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import {
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
  MiAccountsStore,
  hasCorruptMiAccountIndex,
  hasSecondaryMiAccountsInIndex,
  makeMiAccount,
  miAccountId,
  readAccountIndex,
  readAccountIndexState,
} from "../src/core/miAccountsStore.js";
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
  readonly failOnGet?: Set<string>;
  readonly failOnDelete?: Set<string>;
  readonly phantomSlots?: readonly string[];
}

function makeCredentialFixture(options: CredentialFixtureOptions): {
  invoke: SecureInvoke;
  data: Map<string, string>;
  /** Number of enumeration calls, so tests can prove polling never rescans. */
  listCalls: () => number;
} {
  const data = new Map<string, string>();
  let listCalls = 0;
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
      if (options.failOnDelete?.has(name)) throw new Error(`simulated delete failure for ${name}`);
      data.delete(name);
      return null;
    }
    if (cmd === "secure_store_list_mi_account_slots") {
      listCalls += 1;
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
  return { invoke, data, listCalls: () => listCalls };
}

async function seedStore(store: MiAccountsStore, sessions: readonly MiSession[]): Promise<void> {
  for (const session of sessions) await store.upsertAccount(session);
}

const expectedIds = (sessions: readonly MiSession[]): string[] => sessions.map((s) => miAccountId(s));
const slotName = (session: MiSession): string => miAccountSessionCredentialName(makeMiAccount(session).slotId);

describe("Mi account index corruption (#228)", () => {
  const corruptValues: ReadonlyArray<readonly [string, string]> = [
    ["invalid JSON", '{"accounts":'],
    ["object instead of an array", JSON.stringify({ accounts: [] })],
    ["only unusable entries", JSON.stringify([{ id: 42 }, null, "row", { slotId: "" }])],
  ];

  for (const [label, corruptValue] of corruptValues) {
    it(`keeps cached accounts and the corrupt value for ${label}`, async () => {
      const storage = memoryStorage();
      const { invoke } = makeCredentialFixture({ supportsSlotScan: false });
      const store = new MiAccountsStore(new CredentialVault(invoke), storage);
      const sessions = [SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY];
      await seedStore(store, sessions);

      storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, corruptValue);
      assert.equal(readAccountIndexState(storage).status, "corrupt");

      for (let attempt = 0; attempt < 2; attempt += 1) {
        const accounts = await store.load();
        assert.deepEqual(accounts.map((account) => account.id), expectedIds(sessions));
      }
      assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), corruptValue);
      assert.equal(store.getAccountsReadState(), "partial");
    });
  }

  it("enumerates additively on the first load and appends discovered accounts", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: true });
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY]);
    const vault = new CredentialVault(invoke);
    await vault.saveMiAccountSlot(makeMiAccount(SESSION_SG).slotId, SESSION_SG);
    await vault.saveMiAccountSlot(makeMiAccount(SESSION_FAMILY).slotId, SESSION_FAMILY);

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await store.load();

    assert.equal(accounts[0]?.id, miAccountId(SESSION_PRIMARY), "the primary credential stays first");
    assert.deepEqual(
      accounts.map((account) => account.id).sort(),
      expectedIds([SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY]).sort(),
    );
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), accounts.map((account) => account.id));
    assert.equal(store.getAccountsReadState(), "complete");
  });

  it("does not rewrite an index that already matches the enumeration", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: true });
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    const pretty = JSON.stringify(readAccountIndex(storage), null, 2);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, pretty);

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await store.load();
    assert.deepEqual(accounts.map((account) => account.id), expectedIds([SESSION_PRIMARY, SESSION_SG]));
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), pretty);
  });

  it("recovers an omitted secondary account on a later cold start once enumeration works (M1)", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: true };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    options.supportsSlotScan = false;
    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual((await cold.load()).map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(cold.getAccountsReadState(), "partial");
    await cold.upsertAccount(SESSION_PRIMARY);
    assert.equal(readAccountIndex(storage).length, 1);

    options.supportsSlotScan = true;
    const nextBoot = new MiAccountsStore(new CredentialVault(invoke), storage);
    const recovered = await nextBoot.load();
    assert.deepEqual(
      recovered.map((account) => account.id).sort(),
      expectedIds([SESSION_PRIMARY, SESSION_SG]).sort(),
      "the next cold start enumerates and finds the secondary account",
    );
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), recovered.map((account) => account.id));
  });

  it("does not lose an account whose enumerated slot read fails; a later cold start recovers it", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = {
      supportsSlotScan: true,
      failOnGet: new Set([slotName(SESSION_SG)]),
    };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    const partial = await cold.load();
    assert.deepEqual(partial.map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(cold.getAccountsReadState(), "partial");
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), "{broken");

    options.failOnGet?.clear();
    const nextBoot = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual(
      (await nextBoot.load()).map((account) => account.id).sort(),
      expectedIds([SESSION_PRIMARY, SESSION_SG]).sort(),
    );
  });

  it("keeps a cached account whose enumerated slot holds unparseable content", async () => {
    const storage = memoryStorage();
    const { invoke, data } = makeCredentialFixture({ supportsSlotScan: true });
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    data.set(slotName(SESSION_SG), "{not-a-session");
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const cold = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await cold.load();
    assert.deepEqual(accounts.map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(cold.getAccountsReadState(), "partial");
  });

  it("does not wipe an unread account's credential when removing the visible primary", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = {
      supportsSlotScan: true,
      failOnGet: new Set([slotName(SESSION_SG)]),
    };
    const { invoke, data } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual((await store.load()).map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(store.getAccountsReadState(), "partial");

    const removal = await store.removeAccount(miAccountId(SESSION_PRIMARY));
    assert.deepEqual(removal.accounts, []);
    assert.equal(data.has(slotName(SESSION_SG)), true, "the unread secondary credential survives");

    options.failOnGet?.clear();
    const nextBoot = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual(
      (await nextBoot.load()).map((account) => account.id),
      [miAccountId(SESSION_SG)],
      "the surviving credential surfaces on the next load",
    );
  });

  it("removes a secondary account without enumerating the credential store (#4)", async () => {
    const storage = memoryStorage();
    const fixture = makeCredentialFixture({ supportsSlotScan: false });
    const store = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
    const scansBefore = fixture.listCalls();

    const removal = await store.removeAccount(miAccountId(SESSION_SG));
    assert.deepEqual(removal.accounts.map((account) => account.id), [miAccountId(SESSION_PRIMARY)]);
    assert.equal(fixture.data.has(slotName(SESSION_SG)), false);
    assert.equal(fixture.listCalls(), scansBefore, "removal must not trigger a new enumeration");
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), [miAccountId(SESSION_PRIMARY)]);
  });

  it("also deletes duplicate slots seen by the last enumeration (#4)", async () => {
    const storage = memoryStorage();
    const fixture = makeCredentialFixture({ supportsSlotScan: true });
    const vault = new CredentialVault(fixture.invoke);
    const seeded = new MiAccountsStore(vault, storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    const duplicate = `${makeMiAccount(SESSION_SG).slotId}_old`;
    await vault.saveMiAccountSlot(duplicate, SESSION_SG);

    const store = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    await store.load();
    await store.removeAccount(miAccountId(SESSION_SG));

    assert.equal(fixture.data.has(slotName(SESSION_SG)), false);
    assert.equal(fixture.data.has(miAccountSessionCredentialName(duplicate)), false);
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), [miAccountId(SESSION_PRIMARY)]);
  });

  it("accepts a login after a failed enumeration instead of blocking it (#3)", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: false };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await store.load();
    const added = await store.upsertAccount(SESSION_FAMILY);
    assert.equal(added.added, true);
    assert.deepEqual(
      added.accounts.map((account) => account.id),
      expectedIds([SESSION_PRIMARY, SESSION_FAMILY]),
    );

    options.supportsSlotScan = true;
    const nextBoot = new MiAccountsStore(new CredentialVault(invoke), storage);
    assert.deepEqual(
      (await nextBoot.load()).map((account) => account.id).sort(),
      expectedIds([SESSION_PRIMARY, SESSION_SG, SESSION_FAMILY]).sort(),
    );
  });

  it("keeps a login persisted while enumeration was failing (#5)", async () => {
    const storage = memoryStorage();
    const options: CredentialFixtureOptions = { supportsSlotScan: false };
    const { invoke } = makeCredentialFixture(options);
    const seeded = new MiAccountsStore(new CredentialVault(invoke), storage);
    await seedStore(seeded, [SESSION_PRIMARY, SESSION_SG]);
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    await store.load();
    // Models the QR login path saving a new primary while the earlier enumeration failed.
    await new CredentialVault(invoke).savePrimaryMiSession(SESSION_FAMILY);

    options.supportsSlotScan = true;
    const nextBoot = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await nextBoot.load();
    assert.equal(accounts[0]?.session.userId, SESSION_FAMILY.userId);
    assert.ok(accounts.some((account) => account.id === miAccountId(SESSION_SG)));
  });

  it("reports a failed full sign-out and lets the user retry (#2)", async () => {
    const storage = memoryStorage();
    const failOnDelete = new Set([slotName(SESSION_SG)]);
    const fixture = makeCredentialFixture({ supportsSlotScan: true, failOnDelete });
    const store = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);

    await assert.rejects(() => store.clearAll(), /simulated delete failure/);
    assert.equal(fixture.data.has(slotName(SESSION_SG)), true, "the failed credential is still real");
    assert.notEqual(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);

    failOnDelete.clear();
    await store.clearAll();
    assert.equal(fixture.data.has("mi_session"), false);
    assert.equal(fixture.data.has(slotName(SESSION_SG)), false);
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);

    const nextBoot = new MiAccountsStore(new CredentialVault(fixture.invoke), storage);
    assert.deepEqual(await nextBoot.load(), []);
  });

  it("leaves a fresh install untouched and reports a complete read", async () => {
    const storage = memoryStorage();
    const { invoke } = makeCredentialFixture({ supportsSlotScan: true });
    const store = new MiAccountsStore(new CredentialVault(invoke), storage);

    assert.deepEqual(await store.load(), []);
    assert.equal(storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY), null);
    assert.equal(store.getAccountsReadState(), "complete");
    assert.equal(readAccountIndexState(storage).status, "missing");
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
    assert.equal(hasSecondaryMiAccountsInIndex(storage), true);

    const store = new MiAccountsStore(new CredentialVault(invoke), storage);
    const accounts = await store.load();
    assert.deepEqual(accounts.map((account) => account.id), [miAccountId(SESSION_PRIMARY), sg.id]);
    assert.deepEqual(readAccountIndex(storage).map((entry) => entry.id), accounts.map((account) => account.id));
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

  it("renders a non-blocking notice while some credentials cannot be read", async () => {
    const dom: Window = mountTestWindow({ stubInterval: true });
    try {
      setLanguage("en");
      const options: CredentialFixtureOptions = { supportsSlotScan: false };
      const { invoke } = makeCredentialFixture(options);
      const store = new MiAccountsStore(new CredentialVault(invoke), localStorage);
      await seedStore(store, [SESSION_PRIMARY, SESSION_SG]);
      localStorage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, "{broken");
      await store.load();
      assert.equal(store.getAccountsReadState(), "partial");

      const app = new MenuMijiaWindowsApp(document.getElementById("app")!);
      Object.assign(app, { miAccountsStore: store });
      setLanguage("en");
      const html = renderConnectionsAndDiagSection({
        settings: app.settings,
        devices: app.devices,
        escapeHtml: (value: string) => app.escapeHtml(value),
        host: app,
      });
      assert.ok(html.includes("data-mi-accounts-index-warning"));
      assert.ok(html.includes("Some Xiaomi accounts cannot be read right now"));

      const refreshHost = { settings: {} };
      assert.equal(hasMultipleMiAccountsForHost(refreshHost), true, "a corrupt index forces a store load");

      await store.clearAll();
      const clearedHtml = renderConnectionsAndDiagSection({
        settings: app.settings,
        devices: app.devices,
        escapeHtml: (value: string) => app.escapeHtml(value),
        host: app,
      });
      assert.equal(clearedHtml.includes("data-mi-accounts-index-warning"), false);
      assert.equal(hasMultipleMiAccountsForHost(refreshHost), false);
      assert.equal(hasCorruptMiAccountIndex(localStorage), false);
    } finally {
      await closeTestWindow(dom);
    }
  });
});
