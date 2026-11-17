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
