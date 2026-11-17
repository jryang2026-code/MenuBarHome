import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import "./dom.js";
import { sha256 } from "../src/core/miCloudCrypto.js";
import {
  MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
  getAccountTokenStatus,
  makeMiAccount,
  markAccountSessionRejected,
  miAccountId,
  refreshMiAccountsConcurrently,
} from "../src/core/miAccountsStore.js";
import {
  MiCloudError,
  type HttpTransport,
  type MiSession,
  type MiotSpecResolver,
} from "../src/core/miCloudClient.js";
import {
  MI_SESSION_EXPIRED_STORAGE_KEY,
  MI_SESSION_REJECTED_STORAGE_PREFIX,
  clearPersistedMiSessionExpired,
  isPersistedMiSessionExpired,
  miSessionFingerprint,
  miSessionRejectedStorageKey,
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

/** Same account (same userId/region), rotated token: the two sessions share an account id. */
const SESSION_B: MiSession = {
  ...SESSION_A,
  serviceToken: "synthetic-service-token-beta",
};

/** A different Xiaomi account. */
const SESSION_OTHER: MiSession = {
  ...SESSION_A,
  userId: "99003344",
  cUserId: "c-99003344",
  serviceToken: "synthetic-service-token-gamma",
};

/** Serialized rejection "another window" writes for `SESSION_OTHER`. */
const WINDOW_B_RECORD = JSON.stringify({ expiredAtMs: 2_000 });

const v2Key = (session: MiSession): string => miSessionRejectedStorageKey(miSessionFingerprint(session));

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

function storedTexts(storage: Storage = localStorage): string[] {
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
  /** Runs `inject` right before this storage's `index`-th operation (0-based). */
  injectBefore(index: number, inject: () => void): void;
}

/** Map-backed Storage that records every operation, so a test can interleave another window. */
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

function failingWriteStorage(): TestStorage {
  const harness = testStorage();
  const storage = {
    ...harness.storage,
    get length() {
      return harness.storage.length;
    },
    getItem: (key: string) => harness.storage.getItem(key),
    key: (index: number) => harness.storage.key(index),
    removeItem: (key: string) => harness.storage.removeItem(key),
    setItem: () => {
      throw new Error("quota exceeded");
    },
  } as unknown as Storage;
  return { ...harness, storage };
}

/** Writes `SESSION_OTHER`'s rejection the way another window would: one dedicated key. */
function writeWindowBRejection(harness: TestStorage): void {
  harness.data.set(v2Key(SESSION_OTHER), WINDOW_B_RECORD);
}

describe("Mi session rejection storage", () => {
  beforeEach(() => {
    localStorage.clear();
    clearPersistedMiSessionExpired();
  });

  it("stores one key per rejected fingerprint and never persists a plaintext userId", () => {
    persistMiSessionExpired(SESSION_A, true, localStorage, 1_700_000_000_000);
    const raw = localStorage.getItem(v2Key(SESSION_A)) ?? "";
    assert.deepEqual(JSON.parse(raw), { expiredAtMs: 1_700_000_000_000 });
    assert.ok(v2Key(SESSION_A).startsWith(MI_SESSION_REJECTED_STORAGE_PREFIX));
    assert.equal(v2Key(SESSION_A).includes(SESSION_A.userId), false);
    assert.equal(isPersistedMiSessionExpired(SESSION_A), true);
    assert.equal(isPersistedMiSessionExpired(SESSION_B), false, "a rotated token is a new session");
    for (const text of storedTexts()) {
      assert.equal(text.includes(SESSION_A.userId), false, "no plaintext userId anywhere in storage");
      assert.equal(text.includes(SESSION_A.serviceToken), false, "no plaintext serviceToken anywhere");
      assert.equal(text.includes(SESSION_A.ssecurity), false, "no plaintext ssecurity anywhere");
    }
  });

  it("migrates the v1 single record to its own key, then removes the v1 key", () => {
    localStorage.setItem(
      MI_SESSION_EXPIRED_STORAGE_KEY,
      JSON.stringify({ fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_234 }),
    );

    assert.equal(isPersistedMiSessionExpired(SESSION_A), true, "still rejected right after the upgrade");
    assert.equal(localStorage.getItem(MI_SESSION_EXPIRED_STORAGE_KEY), null);
    assert.deepEqual(JSON.parse(localStorage.getItem(v2Key(SESSION_A)) ?? "{}"), { expiredAtMs: 1_234 });
    assert.equal(isPersistedMiSessionExpired(SESSION_B), false);
    assert.equal(storedTexts().some((text) => text.includes(SESSION_A.userId)), false);
  });

  it("migrates the v1 account map to per-fingerprint keys", () => {
    localStorage.setItem(
      MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
      JSON.stringify({
        [miAccountId(SESSION_A)]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 4_567 },
      }),
    );

    assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 4_567,
    });
    assert.equal(localStorage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), null);
    assert.deepEqual(JSON.parse(localStorage.getItem(v2Key(SESSION_A)) ?? "{}"), { expiredAtMs: 4_567 });
    assert.notEqual(getAccountTokenStatus(SESSION_B, 1_000).kind, "expired", "rotated token is not in the map");
  });

  it("keeps the v1 key and the rejected verdict when a migration write fails, then finishes later", () => {
    const harness = testStorage({
      [MI_ACCOUNTS_EXPIRED_STORAGE_KEY]: JSON.stringify({
        [miAccountId(SESSION_A)]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_234 },
      }),
    });
    const failing = {
      get length() {
        return harness.storage.length;
      },
      clear: () => harness.storage.clear(),
      getItem: (key: string) => harness.storage.getItem(key),
      key: (index: number) => harness.storage.key(index),
      removeItem: (key: string) => harness.storage.removeItem(key),
      setItem: () => {
        throw new Error("quota exceeded");
      },
    } as unknown as Storage;

    assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, failing), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 1_234,
    });
    assert.ok(harness.data.has(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), "v1 key retained after a failed write");
    assert.equal(harness.data.has(v2Key(SESSION_A)), false);

    assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, harness.storage), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 1_234,
    });
    assert.equal(harness.data.has(MI_ACCOUNTS_EXPIRED_STORAGE_KEY), false, "v1 key removed once migration lands");
    assert.deepEqual(JSON.parse(harness.data.get(v2Key(SESSION_A)) ?? "{}"), { expiredAtMs: 1_234 });
  });

  it("marks and clears one session without touching another session's key", () => {
    markAccountSessionRejected(SESSION_A, true, { isPrimary: true, storage: localStorage, nowMs: 9_000 });
    markAccountSessionRejected(SESSION_B, true, { isPrimary: false, storage: localStorage, nowMs: 9_500 });
    markAccountSessionRejected(SESSION_OTHER, true, { isPrimary: false, storage: localStorage, nowMs: 9_700 });

    assert.deepEqual(getAccountTokenStatus(SESSION_A, 9_000), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 9_000,
    });
    assert.ok(localStorage.getItem(v2Key(SESSION_B)), "B keeps its own key");

    markAccountSessionRejected(SESSION_A, false, { isPrimary: true, storage: localStorage });
    assert.equal(isPersistedMiSessionExpired(SESSION_A), false);
    assert.equal(isPersistedMiSessionExpired(SESSION_B), true, "A's recovery must not clear B's key");
    assert.equal(isPersistedMiSessionExpired(SESSION_OTHER), true);

    clearPersistedMiSessionExpired();
    assert.equal(isPersistedMiSessionExpired(SESSION_B), false);
    assert.equal(localStorage.length, 0, "sign-out removes every rejection key");
  });

  it("keeps the in-memory rejection when the write fails, and forgets it on recovery", () => {
    const harness = failingWriteStorage();
    assert.equal(isPersistedMiSessionExpired(SESSION_A, harness.storage), false);

    persistMiSessionExpired(SESSION_A, true, harness.storage, 1_000);
    assert.equal(harness.data.size, 0, "nothing reached storage");
    assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, harness.storage), {
      kind: "expired",
      source: "rejected",
      expiredAtMs: 1_000,
    });

    persistMiSessionExpired(SESSION_A, false, harness.storage);
    assert.equal(isPersistedMiSessionExpired(SESSION_A, harness.storage), false);
  });

  it("stops silent polling after a server rejection even when persistence fails", async () => {
    const harness = failingWriteStorage();
    let requests = 0;
    const transport: HttpTransport = async () => {
      requests += 1;
      throw new MiCloudError("sessionExpired", "synthetic expired session");
    };
    const options = {
      accounts: [makeMiAccount(SESSION_A)],
      transport,
      specResolver: {} as MiotSpecResolver,
      storage: harness.storage,
      silent: true,
    };

    const first = await refreshMiAccountsConcurrently(options);
    assert.equal(first.merged.accountTokenStatuses[miAccountId(SESSION_A)]?.kind, "expired");
    const requestsAfterFirst = requests;
    assert.ok(requestsAfterFirst > 0, "the first poll reached the cloud");

    const second = await refreshMiAccountsConcurrently(options);
    assert.equal(requests, requestsAfterFirst, "a rejected session is not polled again");
    assert.equal(second.merged.accountTokenStatuses[miAccountId(SESSION_A)]?.kind, "expired");
  });

  // The migration writes only per-fingerprint keys, so a concurrent rejection must survive at every
  // possible interleaving point. The loop injects it before each storage operation in turn.
  it("keeps a concurrent rejection at every step of the v1 single-record migration", () => {
    const setup = (): TestStorage =>
      testStorage({
        [MI_SESSION_EXPIRED_STORAGE_KEY]: JSON.stringify({
          fingerprint: legacyFingerprint(SESSION_A),
          expiredAtMs: 1_000,
        }),
      });
    const run = (harness: TestStorage): void => {
      assert.equal(isPersistedMiSessionExpired(SESSION_A, harness.storage), true);
    };

    const probe = setup();
    isPersistedMiSessionExpired(SESSION_A, probe.storage);
    const steps = probe.operations.length;
    assert.ok(steps >= 3, `the migration touched storage (${steps} operations)`);

    for (let index = 0; index < steps; index += 1) {
      const harness = setup();
      harness.injectBefore(index, () => writeWindowBRejection(harness));
      run(harness);
      assert.equal(
        harness.data.get(v2Key(SESSION_OTHER)),
        WINDOW_B_RECORD,
        `another window's rejection survived the injection at step ${index}`,
      );
      assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, harness.storage), true, `step ${index}`);
    }
  });

  it("keeps a concurrent rejection at every step of the v1 account-map migration", () => {
    const setup = (): TestStorage =>
      testStorage({
        [MI_ACCOUNTS_EXPIRED_STORAGE_KEY]: JSON.stringify({
          [miAccountId(SESSION_A)]: { fingerprint: legacyFingerprint(SESSION_A), expiredAtMs: 1_000 },
        }),
      });
    const run = (harness: TestStorage): void => {
      assert.deepEqual(getAccountTokenStatus(SESSION_A, 1_000, harness.storage), {
        kind: "expired",
        source: "rejected",
        expiredAtMs: 1_000,
      });
    };

    const probe = setup();
    run(probe);
    const steps = probe.operations.length;
    assert.ok(steps >= 3, `the migration touched storage (${steps} operations)`);

    for (let index = 0; index < steps; index += 1) {
      const harness = setup();
      harness.injectBefore(index, () => writeWindowBRejection(harness));
      run(harness);
      assert.equal(
        harness.data.get(v2Key(SESSION_OTHER)),
        WINDOW_B_RECORD,
        `another window's rejection survived the injection at step ${index}`,
      );
      assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, harness.storage), true, `step ${index}`);
    }
  });
});
