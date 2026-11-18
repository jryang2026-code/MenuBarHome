import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { persistCredentials } from "../src/ui/appLifecycle.js";
import { MiAccountsStore, makeMiAccount } from "../src/core/miAccountsStore.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import {
  CredentialVault,
  miAccountSessionCredentialName,
  parseMiSession,
  serializeMiSession,
  type SecureInvoke,
} from "../src/core/secureStore.js";
import {
  MI_SESSION_REJECTED_STORAGE_PREFIX,
  clearPersistedMiSessionExpired,
  isPersistedMiSessionExpired,
  persistMiSessionExpired,
} from "../src/core/pollingPolicy.js";

const NOW = 1_800_000_000_000;

const SESSION_A: MiSession = {
  userId: "88001122",
  cUserId: "c-88001122",
  ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
  serviceToken: "synthetic-service-token-0",
  passToken: "",
  region: "cn",
};

const SESSION_OTHER: MiSession = {
  ...SESSION_A,
  userId: "99003344",
  cUserId: "c-99003344",
  serviceToken: "{{SECRET_gw4n6rtc}}",
};

function rotated(session: MiSession, index: number): MiSession {
  return { ...session, serviceToken: `${session.serviceToken}-r${index}` };
}

function rejectionKeys(storage: Storage = localStorage): string[] {
  const out: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key !== null && key.startsWith(MI_SESSION_REJECTED_STORAGE_PREFIX)) out.push(key);
  }
  return out;
}

interface TestVault {
  readonly vault: CredentialVault;
  readonly data: Map<string, string>;
  readonly failOnSet: Set<string>;
}

function makeVault(initial: Readonly<Record<string, string>> = {}): TestVault {
  const data = new Map<string, string>(Object.entries(initial));
  const failOnSet = new Set<string>();
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") return ((data.get(name) ?? null) as unknown) as T | null;
    if (cmd === "secure_store_set") {
      if (failOnSet.has(name)) throw new Error(`simulated set failure for ${name}`);
      data.set(name, String(args["value"] ?? ""));
      return null;
    }
    if (cmd === "secure_store_delete") {
      data.delete(name);
      return null;
    }
    if (cmd === "secure_store_list_mi_account_slots") {
      const slots = [...data.keys()]
        .filter((key) => key.startsWith("mi_session_"))
        .map((key) => key.slice("mi_session_".length));
      return slots as unknown as T;
    }
    return null;
  };
  return { vault: new CredentialVault(invoke), data, failOnSet };
}

async function flushAsync(): Promise<void> {
  await setImmediate();
  await setImmediate();
  await setImmediate();
}

let dom: Window;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  localStorage.clear();
  clearPersistedMiSessionExpired(localStorage);
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("Replaced-token rejection retirement", () => {
  it("drops the replaced token's key on every multi-account rotation", async () => {
    const { vault } = makeVault();
    const store = new MiAccountsStore(vault, localStorage);
    const tokens = Array.from({ length: 40 }, (_, index) => rotated(SESSION_A, index));
    await store.upsertAccount(tokens[0]!);
    await store.upsertAccount(SESSION_OTHER);
    persistMiSessionExpired(SESSION_OTHER, true, localStorage, NOW);

    for (let index = 1; index < tokens.length; index += 1) {
      const previous = tokens[index - 1]!;
      persistMiSessionExpired(previous, true, localStorage, NOW);
      assert.equal(isPersistedMiSessionExpired(previous, localStorage), true);

      await store.upsertAccount(tokens[index]!);

      assert.equal(
        isPersistedMiSessionExpired(previous, localStorage),
        false,
        `rotation ${index} retires the replaced token's marker`,
      );
      assert.equal(
        isPersistedMiSessionExpired(SESSION_OTHER, localStorage),
        true,
        "another account's live rejection is never touched",
      );
    }

    assert.equal(rejectionKeys().length, 1, "40 rotations leave one live marker, not 40");
  });

  it("drops only the replaced secondary slot's key and leaves the primary credential alone", async () => {
    const { vault, data } = makeVault();
    const store = new MiAccountsStore(vault, localStorage);
    await store.upsertAccount(SESSION_A);
    await store.upsertAccount(SESSION_OTHER);
    persistMiSessionExpired(SESSION_OTHER, true, localStorage, NOW);
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);

    const nextSecondary = rotated(SESSION_OTHER, 1);
    await store.upsertAccount(nextSecondary);

    assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, localStorage), false);
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), true, "primary marker intact");
    assert.equal(parseMiSession(data.get("mi_session"))?.serviceToken, SESSION_A.serviceToken);
    assert.equal(
      parseMiSession(data.get(miAccountSessionCredentialName(makeMiAccount(nextSecondary).slotId)))
        ?.serviceToken,
      nextSecondary.serviceToken,
    );
  });

  it("keeps the replaced key when the vault write fails", async () => {
    const { vault, data, failOnSet } = makeVault();
    const store = new MiAccountsStore(vault, localStorage);
    await store.upsertAccount(SESSION_A);
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);

    failOnSet.add("mi_session");
    await assert.rejects(() => store.upsertAccount(rotated(SESSION_A, 1)));

    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), true, "a failed write retires nothing");
    assert.equal(parseMiSession(data.get("mi_session"))?.serviceToken, SESSION_A.serviceToken);
  });

  it("keeps the replaced secondary key when the slot write fails", async () => {
    const { vault, failOnSet } = makeVault();
    const store = new MiAccountsStore(vault, localStorage);
    await store.upsertAccount(SESSION_A);
    await store.upsertAccount(SESSION_OTHER);
    persistMiSessionExpired(SESSION_OTHER, true, localStorage, NOW);

    failOnSet.add(miAccountSessionCredentialName(makeMiAccount(SESSION_OTHER).slotId));
    await assert.rejects(() => store.upsertAccount(rotated(SESSION_OTHER, 1)));

    assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, localStorage), true);
  });

  it("retires the old primary token when the single-session credential is replaced", async () => {
    const { vault, data } = makeVault({ mi_session: serializeMiSession(SESSION_A) });
    await vault.load();
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);
    persistMiSessionExpired(SESSION_OTHER, true, localStorage, NOW);

    const next = rotated(SESSION_A, 1);
    await vault.persist({ miSession: next, haToken: "", assistantApiKey: "" });

    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), false);
    assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, localStorage), true);
    assert.equal(parseMiSession(data.get("mi_session"))?.serviceToken, next.serviceToken);
  });

  it("retires nothing when the primary write fails, then retires on a successful retry", async () => {
    const { vault, failOnSet } = makeVault({ mi_session: serializeMiSession(SESSION_A) });
    await vault.load();
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);
    const next = rotated(SESSION_A, 1);

    failOnSet.add("mi_session");
    await assert.rejects(() => vault.persist({ miSession: next, haToken: "", assistantApiKey: "" }));
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), true);

    failOnSet.delete("mi_session");
    await vault.persist({ miSession: next, haToken: "", assistantApiKey: "" });
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), false);
  });

  it("still retires when a sibling credential write fails after the primary write lands", async () => {
    const { vault, data, failOnSet } = makeVault({ mi_session: serializeMiSession(SESSION_A) });
    await vault.load();
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);
    const next = rotated(SESSION_A, 1);

    failOnSet.add("ha_token");
    await assert.rejects(() => vault.persist({ miSession: next, haToken: "ha-token", assistantApiKey: "" }));

    assert.equal(parseMiSession(data.get("mi_session"))?.serviceToken, next.serviceToken);
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), false);
  });

  it("keeps account-removal and sign-out clearing behavior", async () => {
    const { vault } = makeVault();
    const store = new MiAccountsStore(vault, localStorage);
    await store.upsertAccount(SESSION_A);
    await store.upsertAccount(SESSION_OTHER);
    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);
    persistMiSessionExpired(SESSION_OTHER, true, localStorage, NOW);

    await store.removeAccount(makeMiAccount(SESSION_OTHER).id);
    assert.equal(isPersistedMiSessionExpired(SESSION_OTHER, localStorage), false);
    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), true);

    await store.clearAll();
    assert.equal(rejectionKeys().length, 0, "sign-out still clears every rejection key");
  });

  it("retires the previous login through the persistCredentials route", async () => {
    const vaultStore = new Map<string, string>([["mi_session", serializeMiSession(SESSION_A)]]);
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          const name = String(args["name"] ?? "");
          if (cmd === "secure_store_get") return vaultStore.get(name) ?? null;
          if (cmd === "secure_store_set") {
            vaultStore.set(name, String(args["value"] ?? ""));
            return null;
          }
          if (cmd === "secure_store_delete") {
            vaultStore.delete(name);
            return null;
          }
          return null;
        },
      },
    });
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }));
    const app = new MenuMijiaWindowsApp(document.querySelector("#app") as HTMLElement);
    await flushAsync();
    assert.equal(app.settings.miSession?.serviceToken, SESSION_A.serviceToken);

    persistMiSessionExpired(SESSION_A, true, localStorage, NOW);
    const next = rotated(SESSION_A, 1);
    app.settings.miSession = next;
    await persistCredentials(app);

    assert.equal(isPersistedMiSessionExpired(SESSION_A, localStorage), false);
    assert.equal(parseMiSession(vaultStore.get("mi_session"))?.serviceToken, next.serviceToken);
  });

  it("never enumerates storage to find rejection keys outside sign-out", () => {
    const source = (path: string): string => readFileSync(new URL(path, import.meta.url), "utf8");
    const polling = source("../src/core/pollingPolicy.ts");
    const enumeration = polling.indexOf("storage.key(");
    assert.equal(polling.split("storage.key(").length - 1, 1, "only the sign-out clear may enumerate keys");
    assert.ok(
      polling.slice(0, enumeration).includes("export function clearPersistedMiSessionExpired("),
      "the single enumeration belongs to the sign-out clear",
    );
    for (const file of [
      "../src/core/miAccountsStore.ts",
      "../src/core/secureStore.ts",
      "../src/ui/appLifecycle.ts",
    ]) {
      const text = source(file);
      assert.equal(text.includes("storage.key("), false, `${file} must not enumerate storage`);
      assert.equal(text.includes(`MI_SESSION_REJECTED_STORAGE_PREFIX`), false, `${file} must not scan the prefix`);
    }
  });
});
