import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import {
  MI_ACCOUNTS_INDEX_STORAGE_KEY,
  MiAccountsStore,
  makeMiAccount,
  pruneSingleSessionRejections,
} from "../src/core/miAccountsStore.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import {
  MI_SESSION_REJECTED_RETENTION_MS,
  MI_SESSION_REJECTED_STORAGE_PREFIX,
  clearPersistedMiSessionExpired,
  isPersistedMiSessionExpired,
  miSessionFingerprint,
  miSessionRejectedStorageKey,
  persistMiSessionExpired,
  prunePersistedMiSessionRejections,
} from "../src/core/pollingPolicy.js";
import {
  CredentialVault,
  miAccountSessionCredentialName,
  serializeMiSession,
  type SecureInvoke,
} from "../src/core/secureStore.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = 1_800_000_000_000;

const SESSION_A: MiSession = {
  userId: "88001122",
  cUserId: "c-88001122",
  ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
  serviceToken: "synthetic-service-token-alpha",
  passToken: "",
  region: "cn",
};

/** Same account, rotated token. */
const SESSION_B: MiSession = {
  ...SESSION_A,
  serviceToken: "synthetic-service-token-beta",
};

const SESSION_OTHER: MiSession = {
  ...SESSION_A,
  userId: "99003344",
  cUserId: "c-99003344",
  serviceToken: "synthetic-service-token-gamma",
};

const v2Key = (session: MiSession): string => miSessionRejectedStorageKey(miSessionFingerprint(session));

function rejectedKeys(storage: Storage): string[] {
  const out: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key !== null && key.startsWith(MI_SESSION_REJECTED_STORAGE_PREFIX)) out.push(key);
  }
  return out;
}

function storedTexts(storage: Storage): string[] {
  const out: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key === null) continue;
    out.push(key, storage.getItem(key) ?? "");
  }
  return out;
}

interface TestStorage {
  readonly storage: Storage;
  readonly data: Map<string, string>;
  readonly operations: string[];
  /** Runs `inject` right before this storage's `index`-th recorded operation (0-based). */
  injectBefore(index: number, inject: () => void): void;
}

/** Map-backed Storage that records getItem/setItem/removeItem, so tests can interleave a window. */
function testStorage(initial: Readonly<Record<string, string>> = {}): TestStorage {
  const data = new Map<string, string>(Object.entries(initial));
  const operations: string[] = [];
  const injections = new Map<number, () => void>();
  const before = (label: string): void => {
    const index = operations.length;
    operations.push(label);
    injections.get(index)?.();
  };
  const storage = {
    get length() {
      return data.size;
    },
    clear: () => {
      data.clear();
    },
    getItem: (key: string) => {
      before(`get ${key}`);
      return data.get(key) ?? null;
    },
    key: (index: number) => [...data.keys()][index] ?? null,
    removeItem: (key: string) => {
      before(`remove ${key}`);
      data.delete(key);
    },
    setItem: (key: string, value: string) => {
      before(`set ${key}`);
      data.set(key, value);
    },
  } as unknown as Storage;
  return {
    storage,
    data,
    operations,
    injectBefore: (index, inject) => {
      injections.set(index, inject);
    },
  };
}

function seedStale(harness: TestStorage, sessions: readonly MiSession[], expiredAtMs: number): void {
  for (const session of sessions) {
    harness.data.set(v2Key(session), JSON.stringify({ expiredAtMs }));
  }
}

function rotate(session: MiSession, index: number): MiSession {
  return { ...session, serviceToken: `${session.serviceToken}-rotation-${index}` };
}

interface SeedVaultOptions {
  readonly failPrimaryRead?: boolean;
  readonly failSlotRead?: boolean;
}

function seededVault(
  sessions: readonly MiSession[],
  options: SeedVaultOptions = {},
): { readonly vault: CredentialVault; readonly data: Map<string, string> } {
  const data = new Map<string, string>();
  sessions.forEach((session, index) => {
    const slot = index === 0 ? "mi_session" : miAccountSessionCredentialName(makeMiAccount(session).slotId);
    data.set(slot, serializeMiSession(session));
  });
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") {
      if (name === "mi_session" && options.failPrimaryRead === true) throw new Error("vault locked");
      if (name.startsWith("mi_session_") && options.failSlotRead === true) throw new Error("vault locked");
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
    return null;
  };
  return { vault: new CredentialVault(invoke), data };
}

function writeIndex(storage: Storage, sessions: readonly MiSession[]): void {
  const entries = sessions.map((session) => {
    const account = makeMiAccount(session);
    return {
      id: account.id,
      slotId: account.slotId,
      region: account.region,
      maskedUserId: account.maskedUserId,
    };
  });
  storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify(entries));
}

describe("Rejected-session retention sweep", () => {
  beforeEach(() => {
    clearPersistedMiSessionExpired(null);
  });

  it("bounds the key count after 100 token rotations", () => {
    const harness = testStorage();
    const sessions: MiSession[] = [];
    for (let index = 0; index < 100; index += 1) {
      const session = rotate(SESSION_A, index);
      sessions.push(session);
      persistMiSessionExpired(session, true, harness.storage, NOW - (99 - index) * DAY_MS);
    }
    assert.equal(rejectedKeys(harness.storage).length, 100);

    const live = sessions[99]!;
    const removed = prunePersistedMiSessionRejections({
      storage: harness.storage,
      liveFingerprints: [miSessionFingerprint(live)],
      nowMs: NOW,
    });

    assert.equal(removed, 70, "every key older than the 30-day window goes");
    const remaining = rejectedKeys(harness.storage);
    assert.equal(remaining.length, 30);
    assert.ok(remaining.length <= MI_SESSION_REJECTED_RETENTION_MS / DAY_MS);
    assert.ok(harness.data.has(v2Key(live)), "the live token keeps its rejection");
    assert.equal(isPersistedMiSessionExpired(live, harness.storage), true);
    assert.equal(isPersistedMiSessionExpired(sessions[0]!, harness.storage), false);
  });

  it("never deletes a live session's key, even with an ancient or zero timestamp", () => {
    const harness = testStorage();
    harness.data.set(v2Key(SESSION_A), JSON.stringify({ expiredAtMs: 0 }));
    harness.data.set(v2Key(SESSION_B), JSON.stringify({ expiredAtMs: 0 }));
    harness.data.set(v2Key(SESSION_OTHER), "not-json");

    const removed = prunePersistedMiSessionRejections({
      storage: harness.storage,
      liveFingerprints: [miSessionFingerprint(SESSION_A)],
      nowMs: NOW,
    });

    assert.equal(removed, 1);
    assert.ok(harness.data.has(v2Key(SESSION_A)));
    assert.equal(isPersistedMiSessionExpired(SESSION_A, harness.storage), true);
    assert.equal(harness.data.has(v2Key(SESSION_B)), false);
    assert.ok(harness.data.has(v2Key(SESSION_OTHER)), "unreadable payload has no provable age");
  });

  it("deletes nothing when the live set cannot be proven complete", () => {
    const harness = testStorage();
    seedStale(harness, [SESSION_A, SESSION_B, SESSION_OTHER], 0);
    harness.data.set("menumijia.windows.settings", "{\"keep\":true}");

    const removed = prunePersistedMiSessionRejections({
      storage: harness.storage,
      liveFingerprints: null,
      nowMs: NOW,
    });

    assert.equal(removed, 0);
    assert.equal(rejectedKeys(harness.storage).length, 3);
    assert.equal(harness.data.get("menumijia.windows.settings"), "{\"keep\":true}");
    assert.equal(
      prunePersistedMiSessionRejections({ storage: null, liveFingerprints: [], nowMs: NOW }),
      0,
    );
  });

  it("keeps a rejection another window writes while the sweep is running", () => {
    const probe = testStorage();
    seedStale(probe, [SESSION_A, SESSION_B], NOW - 31 * DAY_MS);
    prunePersistedMiSessionRejections({
      storage: probe.storage,
      liveFingerprints: [],
      nowMs: NOW,
    });
    const operationCount = probe.operations.length;
    assert.ok(operationCount > 0);

    for (let injectionPoint = 0; injectionPoint < operationCount; injectionPoint += 1) {
      const harness = testStorage();
      seedStale(harness, [SESSION_A, SESSION_B], NOW - 31 * DAY_MS);
      harness.injectBefore(injectionPoint, () => {
        // Another window persists a rejection for its own session mid-sweep.
        harness.data.set(v2Key(SESSION_OTHER), JSON.stringify({ expiredAtMs: NOW }));
      });

      prunePersistedMiSessionRejections({
        storage: harness.storage,
        liveFingerprints: [],
        nowMs: NOW,
      });

      assert.equal(
        isPersistedMiSessionExpired(SESSION_OTHER, harness.storage),
        true,
        `window B's rejection survives injection at operation ${injectionPoint}`,
      );
    }
  });

  it("keeps a fresh rewrite of the exact key being swept", () => {
    const probe = testStorage();
    seedStale(probe, [SESSION_A, SESSION_B], NOW - 31 * DAY_MS);
    prunePersistedMiSessionRejections({ storage: probe.storage, liveFingerprints: [], nowMs: NOW });
    const verificationPoints = probe.operations
      .map((label, index) => (label === `get ${v2Key(SESSION_B)}` ? index : -1))
      .filter((index) => index >= 0);
    assert.ok(verificationPoints.length > 0);

    for (const injectionPoint of verificationPoints) {
      const harness = testStorage();
      seedStale(harness, [SESSION_A, SESSION_B], NOW - 31 * DAY_MS);
      harness.injectBefore(injectionPoint, () => {
        // Another window re-marks the same fingerprint with a fresh rejection.
        harness.data.set(v2Key(SESSION_B), JSON.stringify({ expiredAtMs: NOW }));
      });

      prunePersistedMiSessionRejections({
        storage: harness.storage,
        liveFingerprints: [],
        nowMs: NOW,
      });

      assert.deepEqual(
        JSON.parse(harness.data.get(v2Key(SESSION_B)) ?? "{}"),
        { expiredAtMs: NOW },
        `a rewrite observed by the verification read survives injection at operation ${injectionPoint}`,
      );
    }
  });

  it("does not remove a key whose payload changed between the two reads", () => {
    const data = new Map<string, string>([[v2Key(SESSION_B), JSON.stringify({ expiredAtMs: NOW })]]);
    let reads = 0;
    const storage = {
      get length() {
        return data.size;
      },
      clear: () => data.clear(),
      key: (index: number) => [...data.keys()][index] ?? null,
      getItem: (key: string) => {
        reads += 1;
        // First verification read sees the aged payload; the second sees the fresh rewrite.
        return reads === 1 ? JSON.stringify({ expiredAtMs: 0 }) : data.get(key) ?? null;
      },
      setItem: (key: string, value: string) => {
        data.set(key, value);
      },
      removeItem: (key: string) => {
        data.delete(key);
      },
    } as unknown as Storage;

    const removed = prunePersistedMiSessionRejections({
      storage,
      liveFingerprints: [],
      nowMs: NOW,
    });

    assert.equal(removed, 0);
    assert.deepEqual(JSON.parse(data.get(v2Key(SESSION_B)) ?? "{}"), { expiredAtMs: NOW });
  });

  it("never writes plaintext into storage", () => {
    const harness = testStorage();
    for (let index = 0; index < 5; index += 1) {
      persistMiSessionExpired(rotate(SESSION_A, index), true, harness.storage, NOW - (index + 40) * DAY_MS);
    }
    const live = rotate(SESSION_A, 5);
    persistMiSessionExpired(live, true, harness.storage, NOW);

    prunePersistedMiSessionRejections({
      storage: harness.storage,
      liveFingerprints: [miSessionFingerprint(live)],
      nowMs: NOW,
    });

    for (const text of storedTexts(harness.storage)) {
      assert.equal(text.includes(SESSION_A.userId), false);
      assert.equal(text.includes(SESSION_A.serviceToken), false);
      assert.equal(text.includes(SESSION_A.ssecurity), false);
    }
  });
});

describe("Rejected-session sweep at startup and in MiAccountsStore", () => {
  beforeEach(() => {
    clearPersistedMiSessionExpired(null);
  });

  it("sweeps a single-account startup only when the index lists no other account", () => {
    const harness = testStorage();
    seedStale(harness, [SESSION_A, SESSION_B, SESSION_OTHER], 0);

    assert.equal(pruneSingleSessionRejections(SESSION_A, { storage: harness.storage, nowMs: NOW }), 2);
    assert.ok(harness.data.has(v2Key(SESSION_A)), "the live session keeps its rejection");
    assert.equal(harness.data.has(v2Key(SESSION_B)), false, "a rotated-away token is swept");
    assert.equal(
      harness.data.has(v2Key(SESSION_OTHER)),
      false,
      "a fingerprint the readable index does not save is aged out like any other orphan",
    );
  });

  it("skips the startup sweep when the index is unreadable", () => {
    const harness = testStorage({ [MI_ACCOUNTS_INDEX_STORAGE_KEY]: "not-json" });
    seedStale(harness, [SESSION_A, SESSION_B], 0);

    assert.equal(pruneSingleSessionRejections(SESSION_A, { storage: harness.storage, nowMs: NOW }), 0);
    assert.equal(rejectedKeys(harness.storage).length, 2);
  });

  it("skips the startup sweep when the index hides rows it cannot parse", () => {
    const harness = testStorage();
    harness.data.set(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify([{ id: "" }, { slotId: "x" }]));
    seedStale(harness, [SESSION_B], 0);

    assert.equal(pruneSingleSessionRejections(SESSION_A, { storage: harness.storage, nowMs: NOW }), 0);
    assert.ok(harness.data.has(v2Key(SESSION_B)));
  });

  it("skips the startup sweep when a second saved account exists", () => {
    const harness = testStorage();
    writeIndex(harness.storage, [SESSION_A, SESSION_OTHER]);
    seedStale(harness, [SESSION_B, SESSION_OTHER], 0);

    assert.equal(pruneSingleSessionRejections(SESSION_A, { storage: harness.storage, nowMs: NOW }), 0);
    assert.ok(harness.data.has(v2Key(SESSION_OTHER)), "the other live account keeps its rejection");
    assert.ok(harness.data.has(v2Key(SESSION_B)));
  });

  it("sweeps after a complete account load and keeps every live account's key", async () => {
    const now = Date.now();
    const harness = testStorage();
    const { vault } = seededVault([SESSION_A, SESSION_OTHER]);
    writeIndex(harness.storage, [SESSION_A, SESSION_OTHER]);
    const staleOld = [rotate(SESSION_A, 0), rotate(SESSION_OTHER, 0), SESSION_B];
    seedStale(harness, staleOld, now - 31 * DAY_MS);
    harness.data.set(v2Key(SESSION_OTHER), JSON.stringify({ expiredAtMs: 0 }));
    harness.data.set(v2Key(SESSION_A), JSON.stringify({ expiredAtMs: now }));

    const store = new MiAccountsStore(vault, harness.storage);
    const accounts = await store.load();
    assert.equal(accounts.length, 2);

    assert.ok(harness.data.has(v2Key(SESSION_A)), "primary's live key is kept");
    assert.ok(harness.data.has(v2Key(SESSION_OTHER)), "secondary's live key is kept");
    for (const session of staleOld) {
      assert.equal(harness.data.has(v2Key(session)), false, "rotated tokens older than retention go");
    }
  });

  it("does not sweep when the primary credential cannot be read", async () => {
    const harness = testStorage();
    const { vault } = seededVault([SESSION_A, SESSION_OTHER], { failPrimaryRead: true });
    writeIndex(harness.storage, [SESSION_A, SESSION_OTHER]);
    seedStale(harness, [rotate(SESSION_A, 0), rotate(SESSION_OTHER, 0)], 0);
    harness.data.set(v2Key(SESSION_OTHER), JSON.stringify({ expiredAtMs: 0 }));

    await new MiAccountsStore(vault, harness.storage).load();

    assert.equal(rejectedKeys(harness.storage).length, 3, "an incomplete live set deletes nothing");
    assert.ok(harness.data.has(v2Key(SESSION_OTHER)), "the readable secondary keeps its rejection");
  });

  it("does not sweep when a secondary slot cannot be read", async () => {
    const harness = testStorage();
    const { vault } = seededVault([SESSION_A, SESSION_OTHER], { failSlotRead: true });
    writeIndex(harness.storage, [SESSION_A, SESSION_OTHER]);
    seedStale(harness, [rotate(SESSION_A, 0), rotate(SESSION_OTHER, 0)], 0);

    await new MiAccountsStore(vault, harness.storage).load();

    assert.equal(rejectedKeys(harness.storage).length, 2);
  });

  it("does not sweep when the account index cannot be parsed", async () => {
    const harness = testStorage({ [MI_ACCOUNTS_INDEX_STORAGE_KEY]: "not-json" });
    const { vault } = seededVault([SESSION_A]);
    seedStale(harness, [rotate(SESSION_A, 0)], 0);

    await new MiAccountsStore(vault, harness.storage).load();

    assert.equal(rejectedKeys(harness.storage).length, 1);
  });
});
