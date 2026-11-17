import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import "./dom.js";
import { sha256 } from "../src/core/miCloudCrypto.js";
import {
  MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
  getAccountTokenStatus,
  markAccountSessionRejected,
  miAccountId,
} from "../src/core/miAccountsStore.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import {
  MI_SESSION_EXPIRED_STORAGE_KEY,
  MI_SESSION_EXPIRY_LOCK_NAME,
  isPersistedMiSessionExpired,
  miSessionFingerprint,
  persistMiSessionExpired,
} from "../src/core/pollingPolicy.js";

const SESSION_A: MiSession = {
  userId: "88001122",
  cUserId: "c-88001122",
  ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
  serviceToken: "synthetic-service-token-alpha",
  passToken: "",
  region: "cn",
};

const SESSION_B: MiSession = {
  ...SESSION_A,
  serviceToken: "synthetic-service-token-beta",
};

/** A second Xiaomi account with its own userId, so it gets its own account id. */
const SESSION_OTHER: MiSession = {
  ...SESSION_A,
  userId: "99003344",
  cUserId: "c-99003344",
  serviceToken: "synthetic-service-token-gamma",
};

function hex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return out;
}

/** The exact value v1 builds wrote: `userId|region|sha256(serviceToken)`. */
function legacyFingerprint(session: MiSession): string {
  const tokenHash = hex(sha256(new TextEncoder().encode(session.serviceToken)));
  return `${session.userId.trim()}|${session.region}|${tokenHash}`;
}

function readJSON(key: string): Record<string, unknown> {
  const raw = localStorage.getItem(key);
  assert.ok(raw, `expected ${key} to be persisted`);
  return JSON.parse(raw) as Record<string, unknown>;
}

/**
 * Storage stub whose first read of `key` is immediately followed by "another window" persisting
 * `afterFirstRead`, so a migration that replays its stale snapshot is deterministically exposed.
 */
function interleavingStorage(
  key: string,
  initial: string,
  afterFirstRead: string,
): { storage: Storage; current: () => string | null; writes: string[] } {
  let value: string | null = initial;
  let reads = 0;
  const writes: string[] = [];
  const storage = {
    get length() {
      return value === null ? 0 : 1;
    },
    clear: () => {
      value = null;
    },
    getItem: (name: string) => {
      if (name !== key) return null;
      const snapshot = value;
      reads += 1;
      if (reads === 1) value = afterFirstRead;
      return snapshot;
    },
    key: () => null,
    removeItem: (name: string) => {
      if (name === key) value = null;
    },
    setItem: (name: string, next: string) => {
      if (name !== key) return;
      value = next;
      writes.push(next);
    },
  } as unknown as Storage;
  return { storage, current: () => value, writes };
}

interface DeferredLockManager {
  readonly locks: LockManager;
  readonly names: string[];
  /** Runs every queued `request` callback, then flushes their promises. */
  flush: () => Promise<void>;
}

/** Web Locks stub that holds callbacks until `flush()`, leaving an await gap for the test. */
function deferredLockManager(): DeferredLockManager {
  const queue: Array<() => void> = [];
  const names: string[] = [];
  const locks = {
    request: (name: string, callback: () => unknown) => {
      names.push(name);
      return new Promise((resolve, reject) => {
        queue.push(() => {
          try {
            resolve(callback());
          } catch (error) {
            reject(error);
          }
        });
      });
    },
  } as unknown as LockManager;
  return {
    locks,
    names,
    flush: async () => {
      while (queue.length > 0) queue.shift()?.();
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

/** Installs a `navigator.locks` value (or `undefined` for the no-Web-Locks fallback). */
function installNavigatorLocks(locks: unknown): () => void {
  const nav = globalThis.navigator as Navigator;
  const own = Object.getOwnPropertyDescriptor(nav, "locks");
  Object.defineProperty(nav, "locks", { configurable: true, value: locks });
  return () => {
    if (own) Object.defineProperty(nav, "locks", own);
    else Reflect.deleteProperty(nav, "locks");
  };
}

describe("Xiaomi session fingerprint privacy", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("hashes the whole identity so the plaintext userId never reaches localStorage", () => {
    const fingerprint = miSessionFingerprint(SESSION_A);
    assert.notEqual(fingerprint, legacyFingerprint(SESSION_A));
    assert.equal(fingerprint.includes(SESSION_A.userId), false);
    assert.equal(fingerprint.includes(SESSION_A.serviceToken), false);
    assert.equal(fingerprint.includes("|"), false);

    persistMiSessionExpired(SESSION_A, true, localStorage, 1_700_000_000_000);
    const raw = localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY) ?? "";
    assert.ok(raw.length > 0);
    assert.equal(raw.includes(SESSION_A.userId), false, "never persists the plaintext Xiaomi userId");
    assert.equal(raw.includes(SESSION_A.serviceToken), false, "never persists plaintext serviceToken");
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), true);
    assert.equal(isPersistedMiSessionExpired(SESSION_B, localStorage), false, "a rotated token is a new session");
  });

  it("migrates a v1 plaintext record in place without letting a rejected session look valid", () => {
    localStorage.setItem(
      MI_SESSION_EXPIRED_STORAGE_KEY,
      JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1234 }),
    );

    assert.equal(
      isPersistedMiSessionExpired(SESSION_A, localStorage),
      true,
      "a session rejected before the upgrade must stay rejected",
    );
    const record = readJSON(MI_SESSION_EXPIRED_STORAGE_KEY);
    assert.equal(record["fingerprint"], miSessionFingerprint(SESSION_A));
    assert.equal(record["expiredAtMs"], 1234);
    assert.equal(
      (localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY) ?? "").includes(SESSION_A.userId),
      false,
      "the upgrade scrubs the plaintext userId",
    );
    assert.equal(isPersistedMiSessionExpired(SESSION_B, localStorage), false);
  });

  it("upgrades a legacy record for another session without matching the current one", () => {
    localStorage.setItem(
      MI_SESSION_EXPIRED_STORAGE_KEY,
      JSON.stringify({ fingerprint: legacyFingerprint(SESSION_B), expiredAtMs: 42 }),
    );

    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), false);
    assert.equal(readJSON(MI_SESSION_EXPIRED_STORAGE_KEY)["fingerprint"], miSessionFingerprint(SESSION_B));
    assert.equal(isPersistedMiSessionExpired(SESSION_B, localStorage), true);
  });

  it("migrates the multi-account expiry map and keeps the rejected verdict", () => {
    const accountId = miAccountId(SESSION_A);
    localStorage.setItem(
      MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
      JSON.stringify({ [accountId]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 4567 } }),
    );

    assert.deepEqual(
      getAccountTokenStatus(SESSION_A, 1_000, localStorage),
      { kind: "expired", source: "rejected", expiredAtMs: 4567 },
    );
    const map = readJSON(MI_ACCOUNTS_EXPIRED_STORAGE_KEY) as Record<string, Record<string, unknown>>;
    assert.equal(map[accountId]?.["fingerprint"], miSessionFingerprint(SESSION_A));
    assert.equal(map[accountId]?.["expiredAtMs"], 4567);
    assert.equal(
      JSON.stringify(map).includes(SESSION_A.userId),
      false,
      "the account expiry map holds no plaintext userId",
    );
    assert.notEqual(
      getAccountTokenStatus(SESSION_B, 1_000, localStorage).kind,
      "expired",
      "a rotated token is not the rejected session",
    );
  });

  it("keeps the rejected verdict when the upgrade rewrite itself fails", () => {
    const accountId = miAccountId(SESSION_A);
    const legacySingle = JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 77 });
    const legacyMap = JSON.stringify({
      [accountId]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 4567 },
    });
    const readOnlyStorage = (values: Readonly<Record<string, string>>): Storage =>
      ({
        length: Object.keys(values).length,
        clear: () => {},
        getItem: (key: string) => values[key] ?? null,
        key: () => null,
        removeItem: () => {},
        setItem: () => {
          throw new Error("quota exceeded");
        },
      }) as unknown as Storage;

    const single = readOnlyStorage({ [MI_SESSION_EXPIRED_STORAGE_KEY]: legacySingle });
    assert.equal(
      isPersistedMiSessionExpired(SESSION_A, single),
      true,
      "a failed migration write must not turn a rejected session into a valid one",
    );
    assert.equal(isPersistedMiSessionExpired(SESSION_B, single), false);

    const accounts = readOnlyStorage({ [MI_ACCOUNTS_EXPIRED_STORAGE_KEY]: legacyMap });
    assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, accounts), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 4567,
    });
  });

  it("keeps marking and clearing accounts with the v2 fingerprint", () => {
    markAccountSessionRejected(SESSION_A, true, { isPrimary: false, storage: localStorage, nowMs: 9000 });
    const map = readJSON(MI_ACCOUNTS_EXPIRED_STORAGE_KEY) as Record<string, Record<string, unknown>>;
    const record = map[miAccountId(SESSION_A)];
    assert.equal(record?.["fingerprint"], miSessionFingerprint(SESSION_A));
    assert.deepEqual(getAccountTokenStatus(SESSION_A, 9000, localStorage), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 9000,
    });

    markAccountSessionRejected(SESSION_A, false, { isPrimary: false, storage: localStorage });
    assert.equal(localStorage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), null);
    assert.equal(getAccountTokenStatus(SESSION_A, 9000, localStorage).kind, "valid");
  });
});

describe("session expiry writes across windows", () => {
  const accountA = miAccountId(SESSION_A);
  const accountB = miAccountId(SESSION_OTHER);

  beforeEach(() => {
    localStorage.clear();
  });

  it("drops a single-session migration when another window persisted a newer rejection", async () => {
    const newer = JSON.stringify({ fingerprint: miSessionFingerprint(SESSION_B), expiredAtMs: 2_000 });
    const { storage, current, writes } = interleavingStorage(
      MI_SESSION_EXPIRED_STORAGE_KEY,
      JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_000 }),
      newer,
    );
    const locks = deferredLockManager();
    const restore = installNavigatorLocks(locks.locks);
    try {
      assert.equal(isPersistedMiSessionExpired(SESSION_A, storage), true);
      assert.equal(current(), newer, "window B's rejection landed after A's read");
      assert.deepEqual(locks.names, [MI_SESSION_EXPIRY_LOCK_NAME]);
      await locks.flush();
      assert.equal(current(), newer, "the stale migration must not overwrite the newer rejection");
      assert.equal(writes.length, 0, "a dropped migration writes nothing");
      assert.equal(isPersistedMiSessionExpired(SESSION_B, storage), true, "B's rejection still stands");
      assert.equal(isPersistedMiSessionExpired(SESSION_A, storage), false);
    } finally {
      restore();
    }
  });

  it("merges the account map so a rejection another window added survives the migration", async () => {
    const legacy = legacyFingerprint(SESSION_A);
    const legacyMap = JSON.stringify({ [accountA]: { fingerprint: legacy, expiredAtMs: 1_000 } });
    const newerMap = JSON.stringify({
      [accountA]: { fingerprint: legacy, expiredAtMs: 1_000 },
      [accountB]: { fingerprint: miSessionFingerprint(SESSION_OTHER), expiredAtMs: 2_000 },
    });
    const { storage, current } = interleavingStorage(MI_ACCOUNTS_EXPIRED_STORAGE_KEY, legacyMap, newerMap);
    const locks = deferredLockManager();
    const restore = installNavigatorLocks(locks.locks);
    try {
      assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, storage), {
        kind: "expired",
        source: "rejected",
        expiredAtMs: 1_000,
      });
      await locks.flush();
    } finally {
      restore();
    }
    const stored = JSON.parse(current() ?? "{}") as Record<string, Record<string, unknown>>;
    assert.equal(stored[accountA]?.["fingerprint"], miSessionFingerprint(SESSION_A), "legacy entry upgraded");
    assert.equal(stored[accountA]?.["expiredAtMs"], 1_000);
    assert.equal(stored[accountB]?.["fingerprint"], miSessionFingerprint(SESSION_OTHER), "B's new rejection kept");
    assert.equal(stored[accountB]?.["expiredAtMs"], 2_000);
    assert.deepEqual(getAccountTokenStatus(SESSION_OTHER, 1_000, storage), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 2_000,
    });
  });

  it("serializes explicit rejection writes behind the cross-window lock", async () => {
    const locks = deferredLockManager();
    const restore = installNavigatorLocks(locks.locks);
    try {
      const pending = markAccountSessionRejected(SESSION_A, true, {
        isPrimary: false,
        storage: localStorage,
        nowMs: 500,
      });
      assert.equal(localStorage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), null, "not written before the lock");
      await locks.flush();
      await pending;
    } finally {
      restore();
    }
    assert.deepEqual(getAccountTokenStatus(SESSION_A, 500, localStorage), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 500,
    });
  });

  it("falls back to the synchronous merge when navigator.locks is unavailable", () => {
    const restore = installNavigatorLocks(undefined);
    try {
      // Interleaved single-session record: the CAS must keep window B's newer rejection.
      const interleaved = interleavingStorage(
        MI_SESSION_EXPIRED_STORAGE_KEY,
        JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_000 }),
        JSON.stringify({ fingerprint: miSessionFingerprint(SESSION_B), expiredAtMs: 2_000 }),
      );
      assert.equal(isPersistedMiSessionExpired(SESSION_A, interleaved.storage), true);
      assert.deepEqual(JSON.parse(interleaved.current() ?? "{}"), {
        fingerprint: miSessionFingerprint(SESSION_B),
        expiredAtMs: 2_000,
      });
      assert.equal(interleaved.writes.length, 0);

      // Undisturbed legacy record: migrated in place, synchronously.
      const clean = interleavingStorage(
        MI_SESSION_EXPIRED_STORAGE_KEY,
        JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_000 }),
        JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_000 }),
      );
      assert.equal(isPersistedMiSessionExpired(SESSION_A, clean.storage), true);
      assert.deepEqual(JSON.parse(clean.current() ?? "{}"), {
        fingerprint: miSessionFingerprint(SESSION_A),
        expiredAtMs: 1_000,
      });
      assert.equal(clean.writes.length, 1);

      // Interleaved account map: the merge keeps window B's new account rejection.
      const legacy = legacyFingerprint(SESSION_A);
      const map = interleavingStorage(
        MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
        JSON.stringify({ [accountA]: { fingerprint: legacy, expiredAtMs: 1_000 } }),
        JSON.stringify({
          [accountA]: { fingerprint: legacy, expiredAtMs: 1_000 },
          [accountB]: { fingerprint: miSessionFingerprint(SESSION_OTHER), expiredAtMs: 2_000 },
        }),
      );
      assert.equal(getAccountTokenStatus(SESSION_A, 1_000, map.storage).kind, "expired");
      const stored = JSON.parse(map.current() ?? "{}") as Record<string, Record<string, unknown>>;
      assert.equal(stored[accountB]?.["fingerprint"], miSessionFingerprint(SESSION_OTHER));
      assert.equal(stored[accountA]?.["fingerprint"], miSessionFingerprint(SESSION_A));
    } finally {
      restore();
    }
  });

  it("keeps the fail-closed verdict when the cross-window lock rejects", async () => {
    const legacySingle = JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_234 });
    const single = interleavingStorage(MI_SESSION_EXPIRED_STORAGE_KEY, legacySingle, legacySingle);
    const legacyMap = JSON.stringify({
      [accountA]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_234 },
    });
    const map = interleavingStorage(MI_ACCOUNTS_EXPIRED_STORAGE_KEY, legacyMap, legacyMap);
    const restore = installNavigatorLocks({
      request: () => Promise.reject(new Error("lock denied")),
    } as unknown as LockManager);
    try {
      assert.equal(isPersistedMiSessionExpired(SESSION_A, single.storage), true);
      assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, map.storage), {
        kind: "expired",
        source: "rejected",
        expiredAtMs: 1_234,
      });
      await new Promise((resolve) => setImmediate(resolve));
    } finally {
      restore();
    }
    assert.equal(single.current(), legacySingle, "a denied lock leaves the legacy record alone");
    assert.equal(isPersistedMiSessionExpired(SESSION_A, single.storage), true);
  });

  it("does not let an older rejection overwrite a newer record from another window", () => {
    const restore = installNavigatorLocks(undefined);
    try {
      const newer = JSON.stringify({ fingerprint: miSessionFingerprint(SESSION_B), expiredAtMs: 5_000 });
      const single = interleavingStorage(MI_SESSION_EXPIRED_STORAGE_KEY, newer, newer);
      void persistMiSessionExpired(SESSION_A, true, single.storage, 1_000);
      assert.equal(single.current(), newer, "a stale expiry timestamp must not replace the newer record");
      assert.equal(single.writes.length, 0);

      void persistMiSessionExpired(SESSION_A, true, single.storage, 6_000);
      assert.deepEqual(JSON.parse(single.current() ?? "{}"), {
        fingerprint: miSessionFingerprint(SESSION_A),
        expiredAtMs: 6_000,
      });
      assert.equal(single.writes.length, 1);
    } finally {
      restore();
    }
  });

  it("a primary recovery cannot clear a rejection another window persisted meanwhile", async () => {
    const newer = JSON.stringify({ fingerprint: miSessionFingerprint(SESSION_B), expiredAtMs: 4_000 });
    let value: string | null = null;
    const storage = {
      getItem: (name: string) => (name === MI_SESSION_EXPIRED_STORAGE_KEY ? value : null),
      setItem: (name: string, next: string) => {
        if (name === MI_SESSION_EXPIRED_STORAGE_KEY) value = next;
      },
      removeItem: (name: string) => {
        if (name === MI_SESSION_EXPIRED_STORAGE_KEY) value = null;
      },
      clear: () => {
        value = null;
      },
      key: () => null,
      get length() {
        return value === null ? 0 : 1;
      },
    } as unknown as Storage;
    const locks = deferredLockManager();
    const restore = installNavigatorLocks(locks.locks);
    try {
      const pending = markAccountSessionRejected(SESSION_A, false, {
        isPrimary: true,
        storage,
      });
      await locks.flush();
      storage.setItem(MI_SESSION_EXPIRED_STORAGE_KEY, newer);
      await locks.flush();
      await pending;
    } finally {
      restore();
    }
    assert.equal(value, newer, "B's rejection survives A's primary recovery");
    assert.equal(isPersistedMiSessionExpired(SESSION_B, storage), true);
  });
});
